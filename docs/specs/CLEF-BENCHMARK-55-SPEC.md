# Clef Benchmark — SPEC (issue #55, Clef-flash / Clef-omni vs Jev)

> **Header obrigatório (fase SPEC): SEM chamadas pagas nesta fase. SEM paid switch. V2-only. Sem lock-in (interface SystemOne).**

- Issue: #55 (candidatos `Clef-flash` e `Clef-omni` vs Jev como advisors SystemOne, advisory-only).
- Escopo desta SPEC: SOMENTE definir fixtures, metodologia, métricas, go/no-go e rollback. Nenhum código, nenhum probe `.ps1`, nenhuma alteração de provider/policy/registry/template, nenhuma chamada de API (paga ou não), nenhum commit, nenhum toque no GitHub.
- Estado verificado (RES-55): família Clef é drop-in compatível SystemOne/Jev (`state` + questions `noul`/`choice`/`score`, até 64 perguntas; troca = endpoint + ID). Benchmark #55 NÃO existe como código executável (0 runners — nada a reutilizar como harness executável); fixtures #16 (`DecisionRequest`/`DecisionResult` via `Invoke-OrchestrationDecision`, seam `-JevProbe`) + goldens #30 existem como base reutilizável.

## 1. Verified provider specs (links oficiais)

Família Clef confirmada como drop-in SystemOne. Tabela — única fonte de números permitida nesta SPEC (todo o resto é `BLOCKED`/`DERIVADO` até run real):

| Campo | Valor verificado |
|---|---|
| Jev stable | `jev-1.13.0` (alias `jev-latest`), $0.042/M input, ctx 64k / req 32k por questão (opt-in 262k). Output $0 |
| Jev preview | `jev-1.14.0` (14/10, alias `jev-preview`), $0.042/M input, ctx 64k / req 32k por questão (opt-in 262k). Output $0 |
| Clef | `@cf/cloudflare/clef`, $0.24/M input, ctx 65536. Output $0 |
| Clef-flash | `@cf/cloudflare/clef-flash`, $0.038/M input, ctx 24576, hospedado (pesos até 256k). Output $0 |
| Clef-omni | `@cf/cloudflare/clef-omni`, $0.15/M input, ctx 64000 (áudio até 4 clips + vídeo até 2). Output $0 |
| Compat | SystemOne drop-in: `state` + até 64 perguntas `noul`/`choice`/`score`; troca = endpoint + ID |
| Lifecycle | Clef GA via Workers AI; fora da lista paid-only (free: 10k Neurons/dia) |
| Multimodal | Só Clef (Jev texto apenas); Clef-omni: áudio até 4 clips + vídeo até 2 |
| Truncamento | Clef trunca `state`; Jev retorna erro/limite |
| Privacidade | Zero retention padrão, sem treino, só metadados operacionais; AI Gateway logging/cache armazena se habilitado (desligar com dados reais) |
| Pinning | Pinar ID de catálogo + digest observado (`jev-1.13.0`, `jev-1.14.0`, `@cf/cloudflare/clef[-flash/-omni]` + revisão/digest retornado pelo serviço, campo `model`/revisão logado por run); alias `jev-latest` muda sem aviso; ID de catálogo sem digest NÃO é "pin versionado" — quando digest indisponível, registrar limitação explícita + janela temporal + metadados de resposta |
| Pricing | Instável (flash $0.09 → $0.038 + corte de ctx em 8 dias) — reler pricing no dia do run |

URLs oficiais:

- https://blog.cloudflare.com/clef-faster-cheaper-multimodal/ (blog 09/10)
- Changelogs 09/10 e 01/10 (TypeSafe)
- Model pages: clef / clef-flash / clef-omni (TypeSafe)
- Pricing 20/10 (TypeSafe)
- Data-usage 16/10 (TypeSafe)
- https://docs.typesafe.ai/models + páginas legal/help (TypeSafe)

Regras: nenhum número de latência/custo além do pricing acima pode aparecer em plano ou relatório sem run real anexado; pricing relido no dia de cada run (instabilidade documentada do flash); somente ID de catálogo + digest observado nos runs (nunca alias mutável; ID sem digest não é "pin versionado" — vale a regra de limitação + janela temporal + metadados da linha Pinning).

## 2. Fixtures e metodologia (formato canônico, mesmos fixtures p/ 5 candidatos)

Segue `MODEL-ROUTER-vNext-SPEC.md §7` (`docs/specs/MODEL-ROUTER-vNext-SPEC.md:143-148`) e o formato canônico de `DECISION-1-BENCHMARK-79-SPEC.md §2`:

- **Base reutilizada:** casos T13–T22 do DecisionProvider (admissão, recusa de authority, reserva de model-override, filtro de overreach, fallback honesto) + GW-05/GW-06 (probe saudável => `source='jev'`; probe que lança ou nula => `planner-escalation`, nunca bloqueia) via `Invoke-OrchestrationDecision` (seam `-JevProbe`).
- **Base #30:** goldens `OrchestrationGoldenWorkflows.tests.ps1` (15/15) como harness de formato.
- **5 candidatos, mesmos fixtures:** `jev-1.13.0`, `jev-1.14.0`, `@cf/cloudflare/clef`, `@cf/cloudflare/clef-flash`, `@cf/cloudflare/clef-omni` — cada fixture roda nos 5 braços.
- **Runs pareados:** `≥ 3 runs` pareados por fixture (mesmo `state` + mesmas perguntas por run nos 5 braços); cada run registra `run_id`, fixture hash, ID de catálogo + digest observado (ou limitação explícita + janela temporal + metadados quando digest indisponível), pricing lido no dia, `evidence_refs` (ou `NO_EVIDENCE_YET`), envelope completo (`source/reason/confidence/blocked`).
- **Multimodal só onde o workflow precisa:** braço Clef-omni com áudio/vídeo SOMENTE em fixtures cujo workflow exija multimodal; nos demais, omni roda em modo texto puro (comparabilidade); multimodal nunca é critério de promoção fora da task class que o exige.
- **Regras de execução:** `high-risk` nunca consulta candidato; authority/model-override sempre recusado antes de qualquer shortcut; candidato é advisory-only, filtrado pelo grant-gate local, nunca decide sozinho; `default routing` = baseline determinístico atual, intacto em todos os runs.
- **Truncamento (diferença comportamental conhecida):** fixtures com `state` longo registram o comportamento por braço (Clef trunca vs Jev erro/limite) como métrica de truncamento (§3), sem normalizar artificialmente — a diferença é evidência, não ruído a esconder.

## 3. Comparação custo / qualidade / latência / privacidade / truncamento (com IC onde viável)

Métricas obrigatórias por run e por braço (tabela — sem valores nesta SPEC, só runs reais futuros preenchem):

| Dimensão | Métrica |
|---|---|
| Acurácia | `verified-success-rate` vs **gold labels independentes** (expectativa pré-registrada por fixture, sem consultar candidato) com denominadores explícitos e margem de não inferioridade pré-registrada; `top-1` agreement vs baseline (observacional — concordância NÃO prova correção) |
| Calibração | prevista vs observada por faixa de confiança |
| Abstenção | `abstention rate` (escalation honesta / total) |
| Latência | `p50/p95` por chamada candidato vs `request_budget_seconds: 30` (`jev-advisory-policy.json`); latência candidato medida separada do despacho; nunca bloqueia (fallback determinístico) |
| Custo | `input tokens × preço pinado do dia` (output $0 todos); `cost per accepted` (custo total / decisões `source=candidate` aceitas); erros/retries contabilizados; pricing relido no dia (flash instável) |
| Decisão | `source/reason/confidence/blocked` por chamada; taxa de `planner-escalation` em `safe fallback` |
| Falhas | erros, timeouts, erro/limite Jev vs truncamento Clef (contados separadamente, nunca mesclados) |
| Privacidade | conformidade por run: zero retention padrão confirmado, sem treino, Gateway logging/cache DESLIGADO com dados reais (verificação binária passa/falha) |
| Truncamento | taxa e impacto de truncamento (Clef) vs erro/limite (Jev) em `state` longo; impacto em `verified-success-rate` reportado separadamente |
| Primária | **`cost-to-DONE` = custo monetário total por tarefa na mesma moeda** (input tokens do classificador + execução downstream + retries + escalations, todos convertidos pelo pricing do dia); wall-clock reportado exclusivamente separado (`p50/p95`), sem somar tempo + dinheiro e sem conversão monetária de tempo; tarefas sem DONE contam como falha com o custo incorrido, sem alegar economia — **somente demonstrável em experimento controlado até DONE (§4); shadow/replay nunca mede `cost-to-DONE` nem `verified-success-rate` causal** |

- Estatística: `≥ 3 runs` pareados; reportar média + IC (ex. t-Student ou bootstrap) onde n permitir; n pequeno => reportar range honesto, sem alegar significância; outliers reportados individualmente (run_id + causa suspeita), nunca silenciosamente descartados.
- **Protocolo shadow (sem credencial paga) — estritamente observacional:** runs reais marcados `BLOCKED_NEEDS_CREDS`/dentro de free allocation; permitido apenas replay offline com probes sintéticas locais (mesmo seam `-JevProbe`, sem rede) para validar formato/métricas — esses replays medem SOMENTE chamadas/concordância de formato e são rotulados `SYNTHETIC_FORMAT_ONLY`. Replays NÃO contam como evidência de qualquer candidato, NÃO medem `cost-to-DONE` nem `verified-success-rate` causal, e **shadow nunca promove** (nenhum gate de promoção pode ser satisfeito em shadow).
- Nenhuma chamada paga sem autorização explícita por ambiente (padrão `MODEL-ROUTER-vNext-SPEC.md:156`); sem Workers Paid/TypeSafe custom; dentro da free allocation (10k Neurons/dia) ou créditos pré-aprovados; sem Gateway logging/cache com dados reais.

## 4. Go / no-go por task class, fallback/rollback, default inalterado

- **Go/no-go por task class (todos obrigatórios por classe, SOMENTE via experimento controlado separadamente autorizado):** braços baseline vs cada candidato nos mesmos tasks, acompanhamento até DONE, preservando permissões/DONE; `cost-to-DONE` menor com `verified-success-rate` não inferior (dentro da margem pré-registrada) em `≥ 2/3 runs` pareados; zero violação de authority/cota/DONE; calibração não pior; `cost per accepted` dentro do orçamento aprovado por ambiente; privacidade passa (Gateway off com dados reais); truncamento sem degradação não compensada por abstention. **Critérios agregados pareados** (não médias soltas entre braços não pareados); outliers documentados; evidência insuficiente (sem golds, sem denominador, sem margem) = **inconclusivo / no-go**, nunca go. Multimodal (omni) só conta como diferencial na task class que exige áudio/vídeo.
- **Reversão (qualquer um):** violação de authority/cota/DONE; `WRONG/SUBOPTIMAL` recorrente; calibração degradada sem abstention compensatória; custo acima do aprovado (incluindo mudança de pricing no dia); latência p95 estourando budget de forma sistemática sem fallback limpo; truncamento degradando decisão sem fallback; Gateway logging/cache ligado com dados reais.
- **Rollback = remover o candidato:** voltar ao baseline determinístico (regras + `planner-escalation`), sem debate, sem migração de estado; remover = trocar endpoint + ID de volta (drop-in reversível, sem lock-in de interface SystemOne); nenhuma dependência de Free permanente.
- **Default routing intacto:** o despacho padrão continua o baseline atual em todas as fases; qualquer candidato só aparece como probe explícita opt-in por run, nunca como rota default; sem delegar policy/autorização ao classificador (advisory-only); sem paid switch sem aprovação humana explícita; **shadow é observacional e nunca promove**.

## 5. Fora de escopo desta fase

Criar probe `.ps1`, editar provider/policy/registry/template, chamar qualquer API (paga ou não), Workers Paid/TypeSafe custom, habilitar Gateway logging/cache com dados reais, commitar, tocar GitHub ou `docs/specs/INDEX.md`.
