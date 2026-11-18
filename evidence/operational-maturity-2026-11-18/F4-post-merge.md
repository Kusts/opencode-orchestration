# F4 — GitHub post-merge cleanup

Referência: `docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md`.

## Entrega

`scripts/v3/github-post-merge.ps1` oferece CLI Plan/Apply para reconciliar
um PR já mergeado e limpar worktrees/branches comprovadamente elegíveis.
Confirma o estado MERGED, ancestralidade do merge SHA em `origin/<base>` e
checks concluídos verdes (`SUCCESS`, `SKIPPED` ou `NEUTRAL`). Resolve a base
principal por `defaultBranchRef`, `origin/HEAD` ou `origin`.

Apply exige worktree limpo na branch base, faz fetch e `merge --ff-only` e só
remove worktree com ownership, limpeza, ancestralidade, caminhos/branches
canônicos e probe de sessão bem-sucedido. A descoberta automática usa
`orca worktree ps --json` (`result.worktrees[].path`); também aceita
`-SessionProbeCommand`. Ambiguidade, sujeira, divergência, sessão ativa ou
probe falho preservam o alvo. Retorna `removed[]`/`preserved[]`, é idempotente
e exige igualdade entre SHA local e remoto. `-SafeBranchDelete` usa `git
branch -d` e falha com `BRANCH_DELETE_FAILED`; o default legado permanece
inalterado. Squash não remove automaticamente.

## Evidência e validação

- `github-post-merge.tests.ps1`: PASS, 16 assertions, 0 skipped; inclui merge
  com remoção real em repositório descartável, squash, sessão ativa, falhas/
  ambiguidades de probe, sujeira, repetição, PR aberto/checks pendentes e SHA
  divergente. Usa fake `gh` e fake probe; fixtures em `%TEMP%`.
- `OrchestrationOwnership.tests.ps1`: PASS, 82/82.
- `git diff --check`: limpo.
- Tester: PASS. Security-reviewer: APPROVED após correções fail-closed para
  checks pendentes, probe ambíguo, alvo de remoção e SHA; exclusão alterada de
  `git branch -D` para `-d`.
- Nenhum `gh` real com escrita; nenhum merge/push real; nenhuma configuração
  ativa alterada.

## Limites

Descoberta de agentes e smoke Planner→worker do F2 seguem HOLD. Mudança do
schema Orca falha fechado como `SESSION_PROBE_UNAVAILABLE`; permanece janela
TOCTOU. Squash não é removido automaticamente e `BRANCH_DELETE_FAILED`
indica branch não totalmente integrada.
