# M6 #185 — handback e context-only, fatia 1

## Entrega

O Task Kernel agora persiste handback limitado (`session_id`, `summary`, `next_steps`, referência opcional de evento, `context_only` e timestamp), com sequência e histórico dos últimos cinco registros. Uma sessão precisa estar vinculada à Task; handback libera `bindings.active_execution_owner` quando corresponde à sessão, sem alterar o status ou remover runs. Repetições idênticas são idempotentes.

`event-ack -ContextOnly` aceita somente evento `informational_only`; o ack registra `ack_kind=context_only`. Ack convencional registra `ack_kind=response`. A fronteira permanece explícita: o Kernel guarda somente sessão, resumo/next_steps limitados e referência de evento; o histórico completo da conversa permanece fora do Kernel.

Erros tipados de handback: `HANDBACK_SESSION_NOT_BOUND`, `HANDBACK_SUMMARY_REQUIRED`, `HANDBACK_CONTENT_TOO_LARGE`, além dos erros compartilhados `EVENT_DEDUP_KEY_INVALID`, `EVENT_NOT_FOUND`, `CAS_CONFLICT`, `ILLEGAL_TRANSITION` e falhas de IO/boundary já existentes.

## Validação executada

- `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskHandback*'`: 1 suite PASS; 15 asserts PASS, 0 FAIL.
- `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskEvent*'`: 1 suite PASS; 15 asserts PASS, 0 FAIL.
- `pwsh -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskHandback*'`: 1 suite PASS; 15 asserts PASS, 0 FAIL.
- `pwsh -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskEvent*'`: 1 suite PASS; 15 asserts PASS, 0 FAIL.
- `powershell -NoProfile -File scripts\test-package-consistency.ps1`: 17 OK / 0 FAIL.
- `git diff --check`: sem erros.

## Limites / pendências

Não implementados: #184 fatias 2–6, call-site GH-WAKE, ingest autenticado e qualquer persistência do histórico completo da conversa. Esta fatia não promove #185 além de PARCIAL. Nenhuma flag, permissão, credencial ou ambiente de produção foi alterado.
