# F2-full Shadow Report — 2026-10-21 (issue #99, PLAN §4)

Protocolo shadow COMPLETO: propostas para TODAS as 12 task_classes da matriz, 3 runs cada (36 propostas). Piloto NÃO ampliado — despacho real sempre no baseline.

## Protocolo

- Harness novo: `scripts/v3/lib/OrchestrationModelRouterShadowFull.tests.ps1` (único arquivo de código tocado; criado, nenhum existente modificado). Estende `OrchestrationModelRouterShadow.tests.ps1` (1 workflow × 3 runs) para 12 classes × 3 runs.
- Lib usada (somente leitura/construção): `scripts/v3/lib/OrchestrationModelRouting.ps1`
  (`New-ModelRoutingRequest`, `New-ModelRoutingResult`, `Test-ModelRoutingEnvelope`).
- Shadow SOMENTE loga a proposta (Write-Output + arquivo em TEMP, removido ao fim).
  O despacho real usa sempre o baseline; nada é ativado, aplicado ou enviado:
  sem chamada de modelo, sem rede, sem escrita em config/registry, sem flag.
- Seleção travada no tier cheap (`cheap-baseline`): custo baseline, zero escalação, zero paid.
- Experimento controlado (comparação com efeito) segue FORA deste escopo — exige
  autorização explícita + budget e não foi executado nem proposto aqui.
- Resultado: `OrchestrationModelRouterShadowFull: PASS (344 assertions, 12 classes x 3 runs, shadow-only)`.

## Classes × runs (36 propostas, todas fallback = baseline)

Mapeamento classe → role de despacho (tier cheap). `debugging` e `review` usam
surrogate cheap; seus donos de produção strong-pool são NUNCA-roteáveis sem SPEC própria (ver § Proibidos).

| Classe | Role (shadow) | Runs | Proposta (shadow, 3×) | Envelope |
|---|---|---|---|---|
| implementation | coder | F2-FULL-implementation-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| migration | database-engineer | F2-FULL-migration-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| analysis | explorer | F2-FULL-analysis-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| research | researcher | F2-FULL-research-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| debugging | coder (surrogate) | F2-FULL-debugging-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| validation | tester | F2-FULL-validation-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| review | skeptic (surrogate) | F2-FULL-review-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| documentation | docs-manager | F2-FULL-documentation-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| planning | requirements-analyst | F2-FULL-planning-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| design | product-designer | F2-FULL-design-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| testing | tester | F2-FULL-testing-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |
| trivial | coder | F2-FULL-trivial-RUN-1..3 | `cheap-baseline` | aceito, `denied=false`, igual ao fallback |

Por run: RUN-1 `BASELINE_SUFFICIENT`/0.90, RUN-2 `FALLBACK_DETERMINISTIC`/0.75, RUN-3 `BASELINE_SUFFICIENT`/0.60. Risco `LOW` nos 36; candidatos `cheap-baseline, cheap-alt`; fallback `cheap-baseline`.

## Custos e baseline

- Orçamentos por run (3 orçamentos): `max_escalations_subtask ≤ 1`,
  `max_above_baseline_per_objective ≤ 2`, `max_paid_calls = 0` (esperado 0 em shadow — confirmado nos 36).
- Consumo observado: escalations consumidas 0/36, picks acima do baseline 0/36,
  chamadas pagas 0. Resumo: b=0/c=0.
- Baseline intocado: `selected == fallback == cheap-baseline` nos 36 runs;
  contador de ações de caminho real do harness = 0.

## Proibidos globais (NUNCA-roteáveis sem SPEC própria)

Marcados e respeitados neste shadow (nenhuma proposta os toca):

- `security_sensitive` / credenciais / segredos, `financial mutation`, `production write`
  sem autorização, `destructive/irreversible`, `control-plane`, `MCP execution`
  (herdados de `capability-routing.json:120-126` + SPEC §5).
- Strong pool (`reviewer`, `debugger`, `security-reviewer`, `architect`) e
  `infra_mutation`: NUNCA saem do baseline sem SPEC própria + #78 (PLAN §6).
  Neste shadow, `debugging` e `review` rodaram com surrogate cheap
  (`coder`, `skeptic`) exatamente para não tocar esses donos.

## Conclusão honesta (sem claim causal)

Com o tier travado no cheap, ganho mensurável é impossível: as 36 propostas são
idênticas ao baseline por construção (`selected == fallback`), logo nenhuma
diferença de `cost-to-DONE` pode ser observada ou alegada a partir deste shadow.
O único caminho para ganho é escalação (tier acima do baseline), o que exige
experimento controlado com autorização explícita + budget — fora deste escopo,
não executado, não proposto.

Este relato NÃO contém claim causal (nenhuma afirmação de que o router causa
melhora, nenhuma generalização além das 36 runs logadas) e NÃO pede promoção:
nenhuma ativação de flag, nenhum experimento controlado, nenhuma mudança de
despacho. Próximo passo eventual (fora deste escopo) dependeria de autorização
explícita do operador.
