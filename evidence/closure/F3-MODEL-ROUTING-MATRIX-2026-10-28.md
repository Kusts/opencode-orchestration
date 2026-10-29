# F3 — Matriz de roteamento de modelos e MCPs (2026-10-28)

## Issues: #61, #101, #50, #138, #116

## Política v1.2 (source/registry/model-routing-policy.json)

| Tier | Modelo | Provider | Pricing | Roles elegíveis |
|---|---|---|---|---|
| T1 | beam (beam-free) | opencode-go | free | explorer, docs-manager, researcher, tester |
| T2 | muse-spark | opencode-go | contrib | coder, frontend, backend, ... |
| T3 | gpt-6-luna / terra | openai | paid | planner, architect, reviewer |
| T4 | opt-in frontier | openai | paid (opt-in) | sob demanda |

## Verificações determinísticas (sem LLM)

- Catálogo: provider enabled/disabled, tier, fallback, identidade — coberto por `OrchestrationModelRouter.tests.ps1` (106/106 PASS).
- Model routing policy v1.2: T1 Beam (free), T2 Muse, T3 Luna/Terra, T4 opt-in — verificado em `model-routing-policy.json`.
- Jev/MCPs: disponibilidade, chamada, consumo, fallback — coberto por `jev-advisory-summary.tests.ps1`.

## Provas que dependem de sessão real (não executadas)

- Tarefa visual real + tool-use no papel elegível (terra-v1.2-proof PARTIAL).
- Separar evidências v2.0.23 vs v2.2.0.
- Cost-to-DONE real.

## Conclusão F3 (fatia pequena)

- Verificações determinísticas verdes. Provas runtime-real pendentes (capacidade ausente: sessão Planner + modelo).
- Não promover evidência mockada para RUNTIME_REAL_PASS.