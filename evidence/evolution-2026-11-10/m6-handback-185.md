# M6 #185 — handback e context-only, fatia 1

## Entrega

O Task Kernel agora persiste handback limitado (`session_id`, `summary`, `next_steps`, referência opcional de evento, `context_only` e timestamp), com sequência e histórico dos últimos cinco registros. Uma sessão precisa estar vinculada à Task; handback libera `bindings.active_execution_owner` quando corresponde à sessão, sem alterar o status ou remover runs. Repetições idênticas são idempotentes.

`event-ack -ContextOnly` aceita somente evento `informational_only`; o ack registra `ack_kind=context_only`. Ack convencional registra `ack_kind=response`. A fronteira permanece explícita: o Kernel guarda somente sessão, resumo/next_steps limitados e referência de evento; o histórico completo da conversa permanece fora do Kernel.

Erros tipados de handback: `HANDBACK_SESSION_NOT_BOUND` (sessão não pertence a run `attached`), `HANDBACK_SUMMARY_REQUIRED`, `HANDBACK_CONTENT_TOO_LARGE`, `HANDBACK_CONTEXT_ONLY_REQUIRES_EVENT` (ContextOnly sem dedup key), `EVENT_CONTEXT_ONLY_NOT_ALLOWED` (a referência não é evento informativo), além dos erros compartilhados `EVENT_DEDUP_KEY_INVALID`, `EVENT_NOT_FOUND`, `CAS_CONFLICT`, `ILLEGAL_TRANSITION` e falhas de IO/boundary já existentes. `next_steps` é aparado com `Trim()` antes da validação do limite e da persistência.

## Validação executada

- `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskHandback*'`: 1 suite PASS; 24 asserts PASS, 0 FAIL.
- `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskEvent*'`: 1 suite PASS; 16 asserts PASS, 0 FAIL.
- `pwsh -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskHandback*'`: 1 suite PASS; 24 asserts PASS, 0 FAIL.
- `pwsh -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskEvent*'`: 1 suite PASS; 16 asserts PASS, 0 FAIL.
- `OrchestrationTaskBindings*`: 1/1 suite PASS, 29/29 asserts, both PowerShell hosts.
- `OrchestrationEvent*`: 4/4 suites PASS in both PowerShell hosts (AdmissionIntent, EventCorrelation 11/11, EventBridge 9/9, EventIntake 8/8).
- `powershell -NoProfile -File scripts\test-package-consistency.ps1`: 17 OK / 0 FAIL.
- `git diff --check`: sem erros.

## Hardening pós-revisão

- Remove entradas nulas do `handback_history` legado antes do append; caso de registro antigo testado.
- Só uma sessão de run com `status='attached'` pode gravar; run detached não autoriza handback (achado LOW de security sobre sessão desvinculada).
- `ContextOnly` exige dedup key existente e evento informativo; chave ausente/informação insuficiente ou evento acionável falham sem gravar. Ack context-only em evento já acked como response também falha sem revision bump (achados de revisão sobre fronteira context-only/ordem de validação).
- Aplica `Trim()` em `NextSteps` antes do limite e da persistência.
- Documenta handback como informativo, sem autoridade, e permite que qualquer sessão de run attached substitua o slot atual; o histórico limitado preserva entradas anteriores (achado MAJOR do reviewer sobre legado nulo no histórico corrigido).
- CLI testada por subprocesso: sucesso 0, duplicata 0 com `duplicate=true`, argumentos incompletos 2, CAS obsoleto 3.
- Caso positivo adicional: sessão worker que é o `active_execution_owner` consegue handback e libera seu próprio ownership; o caso worker não-owner permanece coberto separadamente.

## Limites / pendências

Não implementados: #184 fatias 2–6, call-site GH-WAKE, ingest autenticado e qualquer persistência do histórico completo da conversa. Esta fatia não promove #185 além de PARCIAL. Nenhuma flag, permissão, credencial ou ambiente de produção foi alterado.
