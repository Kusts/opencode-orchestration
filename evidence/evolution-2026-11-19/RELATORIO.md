# Evolução — relatório de auditoria de 19/11/2026

## Objetivo

Executar o ciclo de evolução do relatório de auditoria de 19/11/2026 (baseline `8158b51`, commit analisado `82c3ec7`), priorizando simplificação e eficiência sem nova camada de governança.

## Estado

Implementado e validado; atualização final publicada no PR #288. Permanecem pendências de CI/merge, eficiência conclusiva e capacidade externa.

## Alterações

Checkout final: 24 arquivos, 347 inserções e 823 remoções (`git diff --stat`).

- **#287 (P0):** `source/registry/model-routing-policy.json` como fonte única de modelos T1–T4. Router sem catálogo shadow e com falha fechada; templates com tokens `{{MODEL_PLANNER|CHEAP|STRONG|FREE|FRONTIER}}`; install/reconcile derivando da policy; cadeia T3/T4 validada contra a cadeia canônica; adapters e quatro agentes sem modelos fixos; `models.example.jsonc` declarado como derivado.
- **#286 (P0):** removidos `full-delivery-etapa3/4/5-proof.ps1` (551 linhas, zero callers).
- **HY4/Fix:** anchors de `audit-pinned-versions.ps1` reancorados após bumps (2732→2713, 2622→2603); flake do Capability Doctor corrigido com TEMP isolado.
- **Docs:** `docs/OPERATIONAL-STATUS.md` atualizado para 19/11 (F3 rerun em 2.3.0 com HOLD de allow/ask/deny; shell irrestrito nos 19 workers; 93 issues confirmadas no GitHub).

## Validação

- `run-v3-tests.ps1`: 202 PASS / 0 FAIL / 10 SKIP / 212 TOTAL, exit 0 (3402,8s). Antes: 196/212 com sete falhas.
- `test-package-consistency.ps1`: 17 OK / 0 FAIL.
- `audit-pinned-versions.tests.ps1`: PASS no checkout e em cópia com 5 linhas inseridas no Router, comprovando imunidade a deslocamento.
- `OrchestrationCapabilityDoctor.tests.ps1`: 46 assertions; estresse 20/21 com atividade concorrente no TEMP.
- `OrchestrationPlannerModelConfig.tests.ps1`: 66 PASS. `OrchestrationModelRouterV14.tests.ps1`: 100 PASS. `runtime-port-preflight.tests.ps1`: 123/123.
- `runtime-install.tests.ps1`: 136/136 (injeção AST de `Get-PolicyModelDefaults` + policy copiada para o fixture `New-TamperRoot`).
- `live-hook-v2.tests.ps1`: PASS 35 / FAIL 0 / HOLD 1 após cópia do binário v2.3.0 (SHA-256 `38153A142354634C82B5CFE6C00B19DF15A71E6CF8C17EF5F5C1A4CC684A6917`) para o perfil V2; operação fora do repo e reversível.
- `run-distribution-tests.ps1`: 24 PASS / 0 FAIL / 1 SKIP / 25 (antes: 24 PASS / 1 FAIL / 25).
- Eficiência: nova medição em `evidence/v3.1/runtime-reliability/workflow-efficiency-measurements-2026-11-19.json`; baseline de 2026-10-22 preservado (hash idêntico). Custo/tokens de missão não observados permanecem `UNKNOWN`; latência agregada dominada por timeouts de dispatcher/Jev neste ambiente, portanto não é prova de ganho de eficiência.
- CI do PR #288: no 1º commit (`423dd45`), 4 checks verdes, incluindo `ps7` (que falhava nos commits HY4); checks reiniciaram no 2º commit (`89bac36`).
- Prova de aceite #287 em cópia temporária: trocando só a policy, `test/t1` (3), `test/t2` (2), `test/t3` (4), `test/t4` (1) apareceram no AGENTS.md V2; `-ModelsPath` com `custom/x` venceu a policy. Repositório e configuração ativa intactos.
- `git diff --check`: limpo (apenas avisos CRLF→LF).

## Decisões

1. `MODEL_FRONTIER` não resolvido: corrigir `Resolve-Tokens` no install (bug real).
2. Modelo global dos templates: manter literal `opencode-go/hy4-flash-free`; o contrato `pmc-*-global-model-not-planner-token` preserva a separação global vs. Planner. #287 cobre os quatro tiers, não o global. `build.model` continua com `{{MODEL_PLANNER}}`.
3. `POLICY_MISSING` fail-closed vence o defensive catalog; teste V14 atualizado, pois a lista hardcoded removida é coerente com #287.
4. Dívida dos anchors eliminada: resolução por conteúdo estável, não por número de linha (falha fechada se o padrão deixar de ser único).
5. Falha do preflight (102/107) não reproduziu: 123/123 em três execuções; estado anterior era pré-fix.
6. B2 resolvido pelo provisionamento reversível do binário v2.3.0; a suíte foi reexecutada sem mascarar o teste.

## Pendências

- Fase 5 do relatório (pós-merge real e reavaliação de HOLDs de autonomia) depende de provider/PR externo.
- Conclusão dos checks do PR #288 (2º/3º commits) e merge dependem do CI.
- Conclusão causal de eficiência (P2-09) requer runtime V2 vivo e A/B controlado.

## Próximo passo

Aguardar conclusão dos checks do PR #288 e decidir merge; medição de eficiência conclusiva depende de runtime vivo; Fase 5 depende de capacidade externa.
