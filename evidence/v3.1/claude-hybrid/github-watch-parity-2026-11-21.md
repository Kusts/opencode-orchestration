# Paridade `github-watch.ps1` × `gh` nativo — 2026-11-21

**Decisão: REMOVIDO.** O CLI one-shot `scripts/v3/github-watch.ps1` foi removido em favor de `gh` nativo (dados) e de `scripts/v3/github-await.ps1` (camada de decisão), ambos já existentes. Nenhuma garantia usada de fato foi perdida.

## Contexto e varredura de callers

- Baseline: `master@004b567`; branch `Kusts/hy-github-watch`. Script removido: 341 linhas, introduzido em `3816739`; teste removido: 196 linhas.
- Busca por `github-watch`, `Test-GWOwner`, `New-GWRegisterInstruction`, `Write-GWEnvelope`, `New-GWErrorEnvelope`: nenhuma ocorrência fora do próprio script e de seu teste. `install.ps1`, `plugins/`, `templates/`, `.github/` e nomes construídos dinamicamente: zero ocorrências. Não havia chamador produtivo (critério da issue #286). `test-package-consistency.ps1` não assina scripts v3; `run-v3-tests.ps1` descobre `*.tests.ps1` por glob, sem lista fixa.
- `github-await.ps1` é superconjunto: mesmo transporte e mesma classificação (`Get-OrchestrationGitHubReadiness`, `New-OrchestrationGitHubWaitRequest`, envelope `snapshot_only`/zero-autoridade), além de `-PolicyFile`, `transport_detail`, `invocation_proven` e `snapshot` completo. Permanece como fallback existente (issue #270: nativo primeiro, fallback existente só se faltar capacidade).

## Matriz de paridade (comando, saída resumida, classificação nas três PRs)

| # | Comportamento | #302 — mesclada (`9558301e…`) | #303 — aberta (`b59ae7db…`) | #99999 — inexistente | Classificação |
|---|---|---|---|---|---|
| B1 | Estado do PR | watch: `pr_state=MERGED`; `gh pr view 302 --json state` → `MERGED` | watch: `pr_state=OPEN`; `gh pr view 303 --json state` → `OPEN` | watch: `gh-nonzero-exit` (exit 1); `gh pr view 99999 --json state` → exit 1 | PARIDADE |
| B2 | HEAD SHA | watch: `observed_head_sha=9558301e…`; `gh pr view 302 --json headRefOid` → igual | watch: `b59ae7db…`; `gh pr view 303 --json headRefOid` → igual | sem PR → nulo nos dois | PARIDADE |
| B3 | Checks (status/conclusão) | watch: `checks_count=6, checks_complete=true`; `gh pr checks 302` → 6 `pass` (exit 0) | watch: `checks_count=6`; `gh pr checks 303` → 3 `pending` + 3 `pass` (exit 8); `gh api graphql` → 6 contexts, 3 `IN_PROGRESS` | sem PR → nulo nos dois | PARIDADE (dados brutos) |
| B4 | Classificação de prontidão | watch: `value=TERMINAL`, `reasons=[pr-terminal]`; `gh`: nenhum comando equivalente | watch: `value=CHECKS_PENDING`, `reasons=[check-pending:CI (ps51),check-pending:CI (ps7),check-pending:CI (v2 lane, perfil V2 provisionado)]`; `gh`: nenhum | watch: sem `readiness`; `gh`: nenhum | SEM_EQUIVALENTE no `gh`; preservado por `github-await.ps1`/libs |
| B5 | staleness do HEAD vs esperado | watch compara SHA e classifica; `gh`: sem equivalente | watch: HEAD confere; `gh`: sem equivalente | n/a | SEM_EQUIVALENTE no `gh`; preservado por `github-await.ps1`/libs |
| B6 | Envelope JSON limitado, chaves estáveis, sem vazamento de URL/corpo/erro remoto | watch: 1 JSON, 20 chaves, <64 KiB, sem `detailsUrl`; `gh pr view --json` expõe `detailsUrl` | idem; `gh pr checks` expõe URLs | watch: só código `gh-nonzero-exit`; `gh`: mensagem `GraphQL: Could not resolve …` com detalhe | PARCIAL no `gh`; preservado por `github-await.ps1` |
| B7 | Flags zero-autoridade (`grants_authority`, `merge_authority`, `done_approved`, `resume_authorized`, `kernel_mutated` = false) | watch: presentes e false | watch: presentes e false | watch: presentes e false | SEM_EQUIVALENTE no `gh`; preservado por `github-await.ps1` |
| B8 | `wait_request` com depid canônico + `register_instruction` para `task-kernel` | sem `-Owner` → nulo | `-Owner kernel-owner`: `WaitDependencyId=github-ci:v1:kusts/opencode-orchestration:303:b59ae7db…`, `WaitType=external_dependency`, `WaitAction=revalidate-github-ci`; instrução texto com `<TASK_ID>`/`<REVISION>` | nulo | SEM_EQUIVALENTE no `gh`; `wait_request` preservado por `github-await.ps1`; `register_instruction` sem consumidor runtime |
| B9 | Validação estrita de args (exit 2) e códigos estáveis | watch: exit 2 para args inválidos | idem | idem | SEM_EQUIVALENTE no `gh`; preservado por `github-await.ps1` |
| B10 | One-shot (sem loop/sleep/polling/daemon) | watch: uma passagem; `gh pr checks` sem `--watch` também | idem | idem | PARIDADE |
| B11 | Modo fixture offline (`-GraphQLSnapshotFile`) | watch: aceita fixture | idem | idem | SEM_EQUIVALENTE no `gh`; preservado por `github-await.ps1` |

## Comandos executados (todos somente leitura)

```text
gh pr view 302 --repo Kusts/opencode-orchestration --json number,state,title,headRefOid,mergeable,reviewDecision,statusCheckRollup
gh pr checks 302 --repo Kusts/opencode-orchestration
gh pr view 303 --repo Kusts/opencode-orchestration --json number,state,title,headRefOid,mergeable,reviewDecision,statusCheckRollup
gh pr checks 303 --repo Kusts/opencode-orchestration
gh pr view 99999 --repo Kusts/opencode-orchestration --json state
gh api graphql --hostname github.com -f 'query=<query exata de github-await.ps1>' -F owner=Kusts -F name=opencode-orchestration -F number=303
powershell -NoProfile -File scripts/v3/github-watch.ps1 -Repository Kusts/opencode-orchestration -PrNumber 302 -ExpectedHeadSha 9558301ea6d089bc156b7fc3e9df75d19643aeaf
powershell -NoProfile -File scripts/v3/github-watch.ps1 -Repository Kusts/opencode-orchestration -PrNumber 303 -ExpectedHeadSha b59ae7db92ef32f61ee211f58ed9127aea65108f
powershell -NoProfile -File scripts/v3/github-watch.ps1 -Repository Kusts/opencode-orchestration -PrNumber 99999 -ExpectedHeadSha 9558301ea6d089bc156b7fc3e9df75d19643aeaf
powershell -NoProfile -File scripts/v3/github-watch.ps1 -Repository Kusts/opencode-orchestration -PrNumber 303 -ExpectedHeadSha b59ae7db92ef32f61ee211f58ed9127aea65108f -Owner kernel-owner
```

## Decisão e motivo

REMOVIDO, pelos motivos em ordem:
1. Transporte de dados tem paridade completa com `gh` nativo (`gh api graphql`, `gh pr view --json`, `gh pr checks`) — B1, B2, B3, B10.
2. A camada de decisão (B4–B7, B9, B11) não tem equivalente em `gh`, mas é integralmente preservada por `github-await.ps1` + `lib/OrchestrationDelivery.ps1` + `lib/OrchestrationAutonomyWiring.ps1`, que permanecem. Logo nenhuma garantia **usada de fato** é perdida.
3. O único comportamento sem equivalente e sem preservação, `register_instruction` (B8), não tem consumidor runtime — apenas o teste que é removido junto.
4. Não havia chamador produtivo do script (issue #286) e ele é duplicação comprovada de `github-await.ps1` (issue #270).

Fluxo substituto: `gh` nativo para dados brutos; `scripts/v3/github-await.ps1` para classificação de prontidão, `wait_request` e envelope zero-autoridade.

Histórico em `evidence/` e auditorias em `docs/audits/` não foram reescritos.
