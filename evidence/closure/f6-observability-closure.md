# F6 — Encerramento operacional da observabilidade 2G

Data: 2026-10-13. Execução Planner (suites em PS5.1, master 3d7b88a).

## Coletor íntegro

- OrchestrationEvolutionTelemetryProducer: 164/164 exit 0.
- OrchestrationEvolutionLoop: 147/147 exit 0.
- CapabilityOutcomeValidation: 14/14 exit 0.
- CapabilitySkillUtility: 106/107 — 1 FAIL = `opencode.json vivo inalterado (prefixo DE22307F)`, divergência machine-local user-owned PRÉ-EXISTENTE e documentada (TROUBLESHOOTING); corrigir exigiria tocar config instalada do usuário (proibido). Não é defeito do coletor; zero regressão.

## Eventos reais vs lacuna observacional (FATO)

- Reais disponíveis: runs CI (jobs com conclusões), lane PR71 (S1-S4+S8 pass-real + blocked), fixture F3 (147 asserts, contadores por tentativa), chamadas Jev (consulted/usage/elapsed), receipts/settlements kernel-side. Telemetrias fragmentadas por subsistema (McpSafety/Watchdog/Jev JSONLs próprios, caps fail-closed).
- Formalmente AUSENTE: junção canônica seleção→execução→settlement (sem evento por-decisão com score/confidence/envelope + por-execução com prepare/claim/settle/attempt_n). Skill accepted/used/helpful exigem evento nativo ausente → NOT_OBSERVED. Campos que o kernel nunca escreve seguem lidos como cópia, não soma.
- Nenhuma ausência convertida em sucesso: Resolver sem eventos efetivos de seleção/execução não autoriza Active Mode.

## Veredito F6

- `INSUFFICIENT_REAL_WORLD_DATA` para promoção a Active Mode; Active Routing permanece OFF (skill/mcp/adaptive/routing_telemetry OFF intocados).
- Recomendação/produção do Resolver: sem autoridade sobre seleção, grants ou DONE (correlato ao grant-gate do Jev).
- Phase 2G ENCERRADA no nível de evidência alcançado: coletor íntegro e testado; relatório identifica suficientes (suites, runs, lanes, fixtures) vs insuficientes (join canônico, outcomes labelados) vs não observáveis (turns de modelo sem provider).
- Sanitização/retenção: JSONL bounded, cap fail-closed, lock-busy skip honesto — sem regressão.
