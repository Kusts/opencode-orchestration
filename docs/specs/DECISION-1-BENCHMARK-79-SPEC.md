# DECISION-1 Benchmark — SPEC (issue #79, Microsoft-Decision-1)

> **Header obrigatório (fase SPEC): SEM chamadas pagas nesta fase. SEM mudança de default routing. V2-only. Benchmark real BLOCKED sem credencial Azure paga.**

- Issue: #79 (candidato `Microsoft-Decision-1` como classificador/decision adicional, advisory-only).
- Escopo desta SPEC: SOMENTE definir fixtures, metodologia, métricas, go/no-go e rollback. Nenhum código, nenhum probe `.ps1`, nenhuma alteração de provider/policy/registry/template, nenhuma chamada de API, nenhum commit.
- Estado verificado (RES-79 / INV-79): benchmark #55 NÃO existe como código (0 runners — nada a reutilizar como harness executável); interface #16 existe parcialmente em `scripts/v3/lib/OrchestrationDecisionProvider.ps1:343` (`Invoke-OrchestrationDecision` com seam `-JevProbe`); goldens #30 passam 15/15 em `scripts/v3/lib/OrchestrationGoldenWorkflows.tests.ps1:243`; zero hits `Clef`/`Decision-1` no repo.

## 1. Verified provider specs (links oficiais)

Pesquisador RES-79 confirmou existência oficial. Tabela — única fonte de números permitida nesta SPEC:

| Campo | Valor verificado |
|---|---|
| Model ID | `Microsoft-Decision-1`, v1 |
| API | `POST <endpoint>/providers/microsoft/v1/systemone` |
| Tipos de questão | `noul` / `choice` / `score` |
| Base | Qwen3.5-9B (documentação oficial) |
| Preço | **$0.042 / 1M input tokens; output free** (único número de custo permitido nesta SPEC) |
| Contexto | 32768 tokens |
| Lifecycle | Preview |
| Requisitos | Azure subscription **paga** + Foundry deployment `GlobalStandard` / `DataZoneStandard`. Sem free permanente. Sem credencial = benchmark real BLOCKED. |

URLs oficiais:

- https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision
- https://azure.microsoft.com/en-us/pricing/details/ai-foundry-models/microsoft/
- https://ai.azure.com/catalog/models/Microsoft-Decision-1
- https://commandline.microsoft.com/microsoft-decision-1-model-foundry/
- https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/introducing-microsoft-decision-1-in-microsoft-foundry-for-decision-and-classific/4562742

Regra: nenhum número de latência/custo além do pricing acima pode aparecer em plano ou relatório sem run real anexado.

## 2. Fixtures e metodologia (mesmas de #55, formato canônico)

#55 não possui harness executável (INV-79: 0 runners), portanto esta SPEC **define o formato canônico** sem divergir de `MODEL-ROUTER-vNext-SPEC.md §7` (`docs/specs/MODEL-ROUTER-vNext-SPEC.md:143-148`):

- **Base reutilizada:** casos T13–T22 do DecisionProvider (admissão, recusa de authority, reserva de model-override, filtro de overreach, fallback honesto) + GW-05/GW-06 (`scripts/v3/lib/OrchestrationGoldenWorkflows.tests.ps1:89-101`: probe saudável => `source='jev'`; probe que lança ou nula => `planner-escalation`, nunca bloqueia) via `Invoke-OrchestrationDecision` (`scripts/v3/lib/OrchestrationDecisionProvider.ps1:343-365`, seam `-JevProbe`).
- **3 cenários da issue #79 (adicionais, mesmo envelope):**
  1. `routing` Planner → specialist (alternativas `coder/tester/...`, `risk=low/medium`, state não-vazio);
  2. `ambiguity escalation` (confiança < `min_confidence 0.5` per `source/registry/jev-advisory-policy.json:58-70` => `jev-low-confidence-escalation`);
  3. `safe fallback` (probe nula/throw/timeout => `planner-escalation`, `blocked=false` — padrão GW-06).
- **Regras de execução:** `high-risk` nunca consulta candidato (`OrchestrationDecisionProvider.ps1:446-450`); authority/model-override sempre recusado antes de qualquer shortcut (`:400-436`); candidato é advisory-only, filtrado pelo grant-gate local (`:574-583`), nunca decide sozinho; `default routing` = baseline determinístico atual, intacto em todos os runs.
- **Reprodutibilidade:** cada run registra `run_id`, fixture hash, `evidence_refs` (ou `NO_EVIDENCE_YET`), envelope completo (`source/reason/confidence/blocked`); `≥ 3 runs` por fixture (§3).

## 3. Comparação custo / qualidade / latência (com IC onde viável)

Métricas obrigatórias por run (tabela — sem valores nesta SPEC, só runs reais futuros preenchem):

| Dimensão | Métrica |
|---|---|
| Qualidade | `verified-success-rate` vs **gold labels independentes** (ver abaixo) com denominadores explícitos e margem de não inferioridade pré-registrada, `top-1` agreement vs baseline (observacional — concordância NÃO prova correção), calibração (prevista vs observada por faixa), `abstention rate` (escalation honesta / total) |
| Latência | `p50/p95` por chamada candidato vs `request_budget_seconds: 30` (`jev-advisory-policy.json:9`); latência candidato medida separada do despacho; nunca bloqueia (fallback determinístico) |
| Custo | `input tokens × $0.042/1M` (output free); `cost per accepted` (custo total / decisões `source=candidate` aceitas); erros/retries contabilizados |
| Primária | **`cost-to-DONE`** (tokens + wall-clock + escalations, padrão MODEL-ROUTER §7) — **somente demonstrável em experimento controlado até DONE (§4); shadow/replay nunca mede `cost-to-DONE` nem `verified-success-rate` causal** |

- **Gold labels independentes (obrigatório para as 3 fixtures adicionais do §2):** cada cenário `routing` / `ambiguity escalation` / `safe fallback` exige expectativa pré-registrada (decisão correta + `blocked`/`escalation` esperados) definida sem consultar o candidato; `verified-success-rate` = acertos verificados / total com denominador explícito por cenário e no agregado; margem de não inferioridade pré-registrada no plano do experimento (ex. `delta ≥ -Xpp`); evidência insuficiente (sem golds, sem denominador, sem margem) = **inconclusivo / no-go**, nunca go.

- Estatística: `≥ 3 runs`; reportar média + IC (ex. t-Student ou bootstrap) onde n permitir; n pequeno => reportar range honesto, sem alegar significância.
- **Protocolo shadow (sem credencial) — estritamente observacional:** runs reais marcados `BLOCKED_NEEDS_CREDS`; permitido apenas replay offline com probes sintéticas locais (mesmo seam `-JevProbe`, sem rede) para validar formato/métricas — esses replays medem SOMENTE chamadas/concordância de formato e são rotulados `SYNTHETIC_FORMAT_ONLY`. Replays NÃO contam como evidência do candidato, NÃO medem `cost-to-DONE` nem `verified-success-rate` causal, e **shadow nunca promove** (nenhum gate de promoção pode ser satisfeito em shadow).
- Nenhuma chamada paga sem autorização explícita por ambiente (padrão `MODEL-ROUTER-vNext-SPEC.md:156`).

## 4. Go / no-go, rollback, default inalterado

- **Promoção (todos obrigatórios, SOMENTE via experimento controlado separadamente autorizado):** braços baseline vs candidato nos mesmos tasks, acompanhamento até DONE, preservando permissões/DONE; `cost-to-DONE` menor com `verified-success-rate` não inferior (dentro da margem pré-registrada) em `≥ 2/3 runs`; zero violação de authority/cota/DONE; calibração não pior; `cost per accepted` dentro do orçamento aprovado por ambiente. **Promoção BLOCKED até esse experimento existir e ser autorizado; shadow/replay não satisfaz nenhum critério de promoção.**
- **Reversão (qualquer um):** violação de authority/cota/DONE; `WRONG/SUBOPTIMAL` recorrente; calibração degradada sem abstention compensatória; custo acima do aprovado; latência p95 estourando budget de forma sistemática sem fallback limpo.
- **Rollback = remover o candidato:** voltar ao baseline determinístico (regras + `planner-escalation`), sem debate, sem migração de estado; nenhuma dependência de Free/Preview permanente.
- **Default routing intacto:** o despacho padrão continua o baseline atual em todas as fases; o candidato só aparece como probe explícita opt-in por run, nunca como rota default; sem delegar policy/autorização ao classificador (advisory-only per `jev-advisory-policy.json:44-56`); sem paid switch sem aprovação humana explícita; **shadow é observacional e nunca promove**.

## 5. Fora de escopo desta fase

Criar probe `.ps1`, editar provider/policy/registry/template, chamar qualquer API (paga ou não), commitar, tocar GitHub ou `docs/specs/INDEX.md`.
