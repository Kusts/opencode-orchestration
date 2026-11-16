# F2 Shadow Report — 2026-10-21 (issue #99, PLAN §4)

Protocolo shadow MÍNIMO: prova de protocolo (1 workflow × 3 runs), não benchmark.

## Protocolo

- Harness novo: `scripts/v3/lib/OrchestrationModelRouterShadow.tests.ps1` (único arquivo de código tocado; criado, nenhum existente modificado).
- Lib usada (somente leitura/construção): `scripts/v3/lib/OrchestrationModelRouting.ps1`
  (`New-ModelRoutingRequest`, `New-ModelRoutingResult`, `Test-ModelRoutingEnvelope`).
- Shadow SOMENTE loga a proposta (Write-Output + arquivo em TEMP, removido ao fim).
  O despacho real usa sempre o baseline; nada é ativado, aplicado ou enviado:
  sem chamada de modelo, sem rede, sem escrita em config/registry, sem flag.
- Experimento controlado (comparação com efeito) segue FORA deste escopo — exige
  autorização explícita e não foi executado nem proposto aqui.

## Workflow × runs

Workflow único trivial: role `coder`, classe `trivial`, risco `LOW`,
candidatos `cheap-baseline, cheap-alt`, fallback `cheap-baseline`.

| Run | Proposta (shadow) | reason | confidence | Envelope |
|-----|-------------------|--------|------------|----------|
| F2-SHADOW-RUN-1 | `cheap-baseline` | BASELINE_SUFFICIENT | 0.90 | aceito, `denied=false`, igual ao fallback |
| F2-SHADOW-RUN-2 | `cheap-baseline` | FALLBACK_DETERMINISTIC | 0.75 | aceito, `denied=false`, igual ao fallback |
| F2-SHADOW-RUN-3 | `cheap-baseline` | BASELINE_SUFFICIENT | 0.60 | aceito, `denied=false`, igual ao fallback |

## Custos e baseline

- Orçamentos por run (3 orçamentos): `max_escalations_subtask ≤ 1`,
  `max_above_baseline_per_objective ≤ 2`, `max_paid_calls = 0` (esperado 0 em shadow — confirmado).
- Consumo observado: escalations consumidas 0/3, picks acima do baseline 0/3,
  chamadas pagas 0. Resumo: b=0/c=0.
- Baseline intocado: `selected == fallback == cheap-baseline` nos 3 runs;
  contador de ações de caminho real do harness = 0.

## Sem promoção

Este relato NÃO contém claim causal (nenhuma afirmação de que o router causa
melhora, nenhuma generalização além das 3 runs logadas) e NÃO pede promoção:
nenhuma ativação de flag, nenhum experimento controlado, nenhuma mudança de
despacho. Próximo passo eventual (fora deste escopo) dependeria de autorização
explícita do operador.
