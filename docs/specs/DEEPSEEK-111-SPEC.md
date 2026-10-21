# DeepSeek V4.1 Flash 1017 por papel — SPEC benchmark (issue #111)

> **Header obrigatório (fase SPEC): SEM chamadas pagas nesta fase. SEM paid switch. SEM hardcode de model ID / endpoint / preço em código, policy, registry, template ou agente. V2-only. Default routing intacto. Permissões/DONE intactos.**

- Issue: #111 (candidato `DeepSeek V4.1 Flash` snapshot `1017` por papel: explorer/researcher como 1º piloto read-only; coder/tester/docs como 2ª onda se budget off-peak; domain só com benchmark próprio; advisory sem troca; strong nunca rebaixado salvo pré-triagem).
- Escopo desta SPEC: SOMENTE definir snapshots/aliases, providers, pricing, fixtures, metodologia, métricas, comparação por papel, go/no-go e rollback. Nenhum código, nenhum probe `.ps1`, nenhuma alteração de provider/policy/registry/template/agente, nenhuma chamada de API (paga ou não), nenhum download de pesos, nenhum commit, nenhum toque no GitHub ou em `docs/specs/INDEX.md`.
- Estado verificado (RES-111, usar como fato nesta SPEC sem re-pesquisa): snapshot `deepseek-flash` → `1017` (aliases antigos aposentados — nunca usar alias mutável); provider direto DeepSeek `api.deepseek.com` (compat OpenAI/Anthropic) + terceiros (OpenRouter e equivalentes) + pesos HF sob MIT; preço oficial **off-peak** `$0.15/M miss / $0.003/M hit / $0.60/M out`, **peak 2x** (seg–sex `01:00–04:00` e `06:00–10:00 UTC`, exceto feriados CN); ctx `1M`, max out `384K`, concorrência `2500`; tools JSON/tool-calls/Responses/Anthropic/prefix/FIM non-thinking/vision; rótulo MoE `763B`; benchmarks oficiais com cautela (self-reported até reprodução); Search&Fetch `$0.75/1k`; preços/ctx de terceiros voláteis (reler no dia, nunca herdar tabela do direto).

## 1. Verified model specs (links oficiais — única fonte de números permitida)

Tabela — únicos números permitidos nesta SPEC (todo o resto é `BLOCKED`/`DERIVADO` até run real):

| Campo | Valor verificado (RES-111) |
|---|---|
| Snapshot pinado | `1017` (sucessor de `deepseek-flash`; aliases antigos aposentados — proibido usar alias mutável) |
| Provider direto | `api.deepseek.com` (interfaces OpenAI / Anthropic) |
| Terceiros | OpenRouter e equivalentes — preços/ctx próprios, voláteis; reler no dia, nunca reutilizar tabela do direto |
| Pesos abertos | Hugging Face, licença MIT |
| Preço oficial off-peak (direto) | `$0.15/M` cache-miss input / `$0.003/M` cache-hit input / `$0.60/M` output |
| Preço peak (direto) | `2x` do off-peak em seg–sex `01:00–04:00` e `06:00–10:00 UTC`, exceto feriados CN |
| Contexto direto | `1M` input; max out `384K`; concorrência `2500` |
| Tools (direto) | JSON mode / tool-calls / Responses API / Anthropic-compat / prefix completion / FIM (non-thinking) / vision |
| Arquitetura (rótulo) | MoE `763B` (rótulo — sem claim de ativos/VRAM sem run) |
| Search&Fetch | `$0.75/1k` chamadas (quando usado — contabilizar separado, nunca embutir no token-price) |
| Benchmarks oficiais | self-reported (`SELF_REPORTED_UNVALIDATED`) até reprodução local com `≥ 3 runs` |

Regras: nenhum número de latência/tok-s/custo além do pricing acima pode aparecer em plano ou relatório sem run real anexado; peak/off-peak e feriado CN verificados no dia de cada run (janela UTC registrada por run); terceiros com pricing+ctx lidos no dia por provider; somente snapshot pinado `1017` + endpoint + digest/revisão retornada nos runs (nunca alias, nunca "latest"); benchmarks do vendor NUNCA sustentam go/no-go sozinhos.

## 2. Fixtures e metodologia (Golden Workflows #30 + DecisionProvider T13–T22)

Mesmo padrão de `DECISION-1-BENCHMARK-79-SPEC.md` e `MODEL-ROUTER-vNext-SPEC.md §7`:

- **Base reutilizada:** mesmos Golden Workflows #30 (GW-TRIVIAL / GW-MULTI / GW-RECOVERY / GW-GITHUB / GW-ADVISORY — curto, SPEC+PLAN longo, failure→recovery, rotation, reuse, Jev-fallback, bloqueio seguro) + casos DecisionProvider T13–T22 onde aplicável (admissão, recusa de authority, reserva de model-override, filtro de overreach, fallback honesto).
- **Classes de tarefa por papel:** explorer/researcher = repo-nav + leitura (read-only); coder = small-fix + tool use; tester = assurance a jusante (validação independente); docs = escrita técnica avaliável; domain (frontend/backend/database/ai-agent/automation/infra) = SOMENTE fixtures do próprio domínio; advisory (requirements-analyst/architect/engineering-advisor/skeptic/product-designer) = sem troca nesta SPEC (fora do benchmark); strong (reviewer/debugger/security-reviewer/architect) = nunca rebaixado (só pré-triagem fora do gate — §4.1).
- **Braços:** baseline atual (default routing determinístico) vs candidato `1017` via provider declarado por run (direto OU um terceiro nomeado — nunca misturar providers no mesmo pareamento); mesmos tasks até DONE, preservando permissões/DONE.
- **Ordem por ondas:** onda 1 = explorer/researcher read-only; onda 2 = coder/tester/docs SOMENTE se a onda 1 couber no budget off-peak aprovado; domain = SOMENTE com benchmark próprio do domínio; advisory = sem runs; strong = sem substituição.
- **Runs pareados:** `≥ 3 runs` pareados por fixture (mesma fixture, mesmos runs nos 2 braços); cada run registra `run_id`, fixture hash, snapshot `1017` + endpoint + digest/revisão retornada, provider, janela peak/off-peak UTC + feriado CN (quando direto), pricing lido no dia, cache-hit/miss quando observável, `evidence_refs` (ou `NO_EVIDENCE_YET`), envelope completo (`source/reason/confidence/blocked`), comandos exatos, permissões/DONE verificados.
- **Regras de execução:** `high-risk` nunca consulta candidato; authority/model-override sempre recusado antes de qualquer shortcut; candidato nunca decide sozinho (coder/tester/docs com review + DONE independentes); `default routing` = baseline atual, intacto em todos os runs; sem delegar policy/autorização ao candidato.
- **Sem hardcode:** nenhum ID/endpoint/preço desta SPEC entra em código, policy, registry, template ou prompt de agente; runs resolvem via config de ambiente por run explícito opt-in; o que vale é o registrado por run, não o copiado desta tabela.
- **Sem pago sem autorização:** nenhuma chamada paga sem autorização explícita por ambiente (padrão `MODEL-ROUTER-vNext-SPEC.md:156`); preferência por janela off-peak; Search&Fetch desligado salvo fixture que o exija (custo separado); sem terceiros com markup sem orçamento aprovado.

## 3. Comparação custo / qualidade / latência (com IC onde viável)

Métricas obrigatórias por run e por braço (tabela — sem valores nesta SPEC, só runs reais futuros preenchem):

| Dimensão | Métrica |
|---|---|
| Qualidade | `pass rate` vs **gold labels independentes** (expectativa pré-registrada por fixture, sem consultar candidato) com denominadores explícitos; `false-success rate` (claim sem DONE verificado = falha); calibração prevista vs observada |
| Custo | `tokens-to-DONE`; `cost-to-DONE` (tokens × preço pinado do dia por provider e janela + Search&Fetch quando usado + wall-clock reportado separado + retries + escalations — padrão MODEL-ROUTER §7); cache-hit/miss separado quando observável; erros/retries contabilizados; pricing relido no dia |
| Latência | `p50/p95` por chamada candidato vs baseline; latência candidato medida separada do despacho; nunca bloqueia (fallback determinístico); concorrência `2500` do direto NÃO é claim de latência |
| Decisão | `source/reason/confidence/blocked` por chamada; taxa de escalation honesta |
| Falhas | erros, timeouts, truncamento ctx (`1M` direto vs limite do terceiro usado), degradação tool-calls/FIM/vision por provider |
| Privacidade | zero treino / retenção conforme provider declarado por run (verificação binária passa/falha; terceiros = política do terceiro, nunca herdada do direto) |
| Primária | **`cost-to-DONE` na mesma moeda e mesma janela/provider** (todos os componentes convertidos pelo pricing do dia); wall-clock exclusivamente separado (`p50/p95`), sem somar tempo + dinheiro; tarefas sem DONE contam como falha com custo incorrido, sem alegar economia — **somente demonstrável em experimento controlado até DONE (§4); shadow/replay nunca mede `cost-to-DONE` causal** |

- Estatística: `≥ 3 runs` pareados; média + IC (ex. t-Student ou bootstrap) onde n permitir; n pequeno => range honesto, sem alegar significância. Promoção vale somente pela comparação pareada agregada de §4.2, nunca por contagem de runs.
- Vendor numbers e benchmarks oficiais: qualquer comparação contra número do vendor é rotulada `SELF_REPORTED_UNVALIDATED` até reprodução com `≥ 3 runs`.
- Terceiros: comparação válida SOMENTE dentro do mesmo provider e mesma janela; trocar provider ou janela invalida o pareamento (novo experimento).
- Protocolo shadow (sem credencial paga) — estritamente observacional: runs reais marcados `BLOCKED_NEEDS_CREDS`/dentro de budget aprovado; permitido apenas replay offline com probes sintéticas locais para validar formato/métricas, rotulados `SYNTHETIC_FORMAT_ONLY`. Replays NÃO contam como evidência do candidato, NÃO medem `cost-to-DONE` causal, e **shadow nunca promove**.

## 4. Recomendação por papel, go / no-go, rollback, default inalterado

### 4.1 Recomendação explícita por papel (SOMENTE após runs; abaixo o formato, sem valores)

| Papel | Veredito nesta SPEC | Critério futuro para mudar |
|---|---|---|
| Explorer | `BLOCKED_SEM_RUN` — 1º piloto read-only | comparação pareada agregada (§4.2): `cost-to-DONE` total agregado menor com pass rate agregado não inferior, em fixtures repo-nav |
| Researcher | `BLOCKED_SEM_RUN` — 1º piloto read-only | idem Explorer, em fixtures de pesquisa |
| Coder | `BLOCKED_SEM_RUN` — 2ª onda, só se onda 1 couber no budget off-peak | idem + zero false-success + review/DONE independentes preservados |
| Tester | `BLOCKED_SEM_RUN` — 2ª onda, mesma condição; escala é de escopo, não de modelo | idem Coder |
| Docs-manager | `BLOCKED_SEM_RUN` — 2ª onda, mesma condição | idem Coder, em fixtures de escrita técnica |
| Domain (frontend/backend/database/ai-agent/automation/infra) | `BLOCKED_SEM_BENCHMARK_PROPRIO` — sem runs cross-domain | benchmark próprio do domínio + §4.2 integral; sem herança de resultado de outro papel |
| Advisory (requirements-analyst/architect/engineering-advisor/skeptic/product-designer) | `SEM_TROCA` — fora deste benchmark, sem runs | qualquer avaliação futura exige SPEC própria |
| Strong (reviewer/debugger/security-reviewer/architect) | `NUNCA_REBAIXAR` — sem substituição; admitida apenas pré-triagem fora do gate (não conta como review/debug/security/decision) | nenhuma promoção prevista; pré-triagem só com descarte explícito (achado só vale após gate strong real) |

Nenhum papel recebe veredito diferente de bloqueado/sem-troca nesta fase. **Sem auto switch** em qualquer cenário: o candidato nunca se torna default, nunca é selecionado automaticamente por router/policy, e qualquer uso futuro é opt-in explícito por run com gate humano.

### 4.2 Promoção (todos obrigatórios, SOMENTE via experimento controlado separadamente autorizado)

Braços baseline vs candidato nos mesmos tasks até DONE, mesmo provider, mesma janela, preservando permissões/DONE; comparação **pareada agregada**: mesmas fixtures, mesmos runs pareados por fixture/run, somando custo total (`cost-to-DONE` total inclui falhas, retries, escalations e Search&Fetch — sem excluir run desfavorável); promoção exige **redução agregada** de `cost-to-DONE` total **+ não inferioridade agregada** de pass rate (nunca contagem de runs tipo `≥ 2/3`); tratamento de outliers pré-registrado (winsorização com limite declarado antes dos runs, ou análise de sensibilidade com/sem outlier); resultado **inconclusivo** se o IC da diferença agregada cruzar zero ou se 1 regressão extrema anular os ganhos agregados; zero violação de authority/cota/DONE; zero false-success não detectado; pricing/janela/provider pinados por run; promoção via gate humano explícito, **por papel e por onda** (§4.1), nunca global automática. **Promoção BLOCKED até esse experimento existir e ser autorizado.** Troca de provider ou de janela peak/off-peak exige novo experimento.

### 4.3 Reversão (qualquer um)

Violação de authority/cota/DONE; `WRONG/SUBOPTIMAL` recorrente; false-success; custo acima do aprovado (incluindo virada peak ou markup de terceiro no dia); latência p95 estourando budget de forma sistemática sem fallback limpo; degradação tool-calls/FIM/vision sem fallback; truncamento degradando decisão sem fallback; Gateway/logging do provider ligado com dados reais.

### 4.4 Rollback = remover o candidato

Voltar ao baseline determinístico atual, sem debate, sem migração de estado; remover = trocar endpoint + snapshot de volta (compat OpenAI/Anthropic é reversível, sem lock-in de interface além do já contratado); nenhuma dependência permanente de provider/terceiro em nenhum papel.

### 4.5 Default routing, permissões e DONE intactos

O despacho padrão continua o baseline atual em todas as fases; o candidato só aparece como probe explícita opt-in por run, nunca como rota default; **no automatic model switch** — sem paid/silent switch, sem promoção por replay/shadow, sem delegar policy/autorização ao candidato; permissões por papel e gates de DONE/verificação inalterados (nenhum relaxamento para acomodar o candidato); sem paid switch sem aprovação humana explícita; **shadow é observacional e nunca promove**.

## 5. Fora de escopo desta fase

Criar probe `.ps1`, editar provider/policy/registry/template/agente, chamar qualquer API (paga ou não), baixar pesos, habilitar Search&Fetch ou Gateway logging com dados reais, commitar, tocar GitHub ou `docs/specs/INDEX.md`.
