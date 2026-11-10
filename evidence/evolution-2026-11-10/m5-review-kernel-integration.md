# M5 — Integração de review ancorado e reparo localizado no Kernel

**Data:** 2026-11-10
**HEAD:** `54a9d3c` + alterações locais desta rodada

## Entregue

### #200 — findings ancorados no registro de review

- `Set-OrchestrationTaskReview` aceita `-FindingsJson` opcional.
- `ConvertTo-TaskKernelReviewFindings` valida JSON não confiável com limites
  (50 findings, 256 KiB, mensagem 2000 chars), usa a lib de âncoras e persiste
  `finding_id`, `file`, `line`, `commit_sha`, `severity`, `message`, `owner`,
  `owner_reason`, `file_sha256` e `anchor`.
- `approved` com findings é recusado (`REVIEW_FINDINGS_ON_APPROVED`).
- CLI `task-kernel.ps1 -Action review` ganhou `-FindingsFile` / `-FindingsJson`
  (mutuamente exclusivos, arquivo lido como UTF-8).

### #103 — reparo localizado composto com o finding persistido

- O finding persistido no Kernel é consumido por
  `Resolve-OrchestrationLocalizedRepair`; o Planner decide
  `LOCAL_REPAIR`/`REPLAN`/`ESCALATE` com a mesma Task, sem reiniciar etapas.
- Nenhum controlador, estado ou autorização novo: o Kernel continua dono do
  estado; o Planner continua dono da decisão.

## Validação

| Suíte | Resultado |
|---|---|
| `OrchestrationReviewIntegration.tests.ps1` | 14/0 PASS (persistência, owner, approved+findings, JSON inválido, path inválido, limite, composição com reparo) |
| `OrchestrationTaskKernel.tests.ps1` | 114/114 PASS |
| `OrchestrationTaskKernelCorrelation.tests.ps1` | 34/0 PASS |
| `OrchestrationTaskKernelModelProof.tests.ps1` | 169/169 PASS |
| `OrchestrationTaskKernelTrustedPaths.tests.ps1` | 8/0 PASS |
| `package-consistency` | 17/17 PASS |

## E2E vivo (2026-11-10)

Task `m5-e2e-review-20261110`, root `ses_e38f4d36…`, run `run-m5-e2e`.

1. **Coder** (`ses_e38bf33d…`, `openai/gpt-6-luna`) criou
   `scratchpad/m5-e2e/ratio.ps1` e `test.ps1`; teste 10/2=5 e 5/0=$null
   passou (exit 0).
2. **Reviewer T3** (`ses_e38be56e…`, `claude-agent/sonnet`) encontrou 2
   defeitos reais:
   - F1: parâmetros `[int]` coagiam `$null` para 0 (`Get-Ratio $null 5` = 0);
   - F2: o teste não cobria entrada nula/ausente.
   Findings ancorados em `scratchpad/m5-e2e/ratio.ps1:1` e
   `scratchpad/m5-e2e/test.ps1:9`, commit `54a9d3c`, persistidos no Kernel via
   `review changes_required` (revision 8).
3. **Coder** (`ses_e38bd6cf…`, `openai/gpt-6-luna`) corrigiu `ratio.ps1` para
   `[object]` + checagem de `$null`, e ampliou o teste para cinco casos
   (10/2, 5/0, $null/5, 5/$null, sem argumentos). Teste exit 0.
4. **Reviewer** aprovou (revision 12).
5. **Gate de conclusão:** `complete` recusou corretamente com
   `COMPLETION_GATE_FAILED` porque a Task descartável não foi criada com
   `-VerifierProfiles` (sem plano de verificação kernel-executed) e sem
   `OrchestrationCompliance`. É o fail-closed esperado, não um defeito.

### Achado real do E2E

O review aprovado **sobrescrevia** o review anterior com findings. Corrigido:
`review_history`/`security_review_history` preservam as rodadas anteriores
(bounded em 20) e o teste de integração passou a exigir o anchor histórico
(17/17).

### DONE completo (prova adicional)

Task `m5-done-proof6-20261110` (criada com `-VerifierProfiles criterion-smoke`
e `-BaseRevision acc13b2`):

1. `record-result candidate_pass` com `criterion:0` (revision 2);
2. `verify-run` → `verified_pass`, `verification_source=kernel-executed`
   (revision 3);
3. `review approved` (revision 4);
4. transições `PLANNING → IMPLEMENTING → VALIDATING → REVIEWING`;
5. `complete` com `OrchestrationCompliance=COMPLIANT` → **state DONE**
   (revision 9).

Isso fecha o caminho `review approved → verify → DONE` que a Task descartável
do E2E não conseguia completar por falta de plano de verificação.

### Limites

- Nenhuma duplicação de execução: cada worker foi registrado uma vez; o
  reviewer não foi gravado como worker result para não violar a independência.
- O perfil `criterion-smoke` é um verificador determinístico de fumaça; não
  substitui a suíte real do projeto.
- O prompt padrão do reviewer ainda não emite o schema de findings; o E2E
  usou instrução explícita.
- Nenhuma flag, permissão, credencial ou produção foi alterada.

