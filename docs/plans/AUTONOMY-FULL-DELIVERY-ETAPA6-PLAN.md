# ETAPA 6 — PLAN (fatia 6A/6B, primeira execução)

Vinculado a `AUTONOMY-FULL-DELIVERY-ETAPA6-SPEC.md` + vNEXT §§3–12.

## Ordem (vertical, RED→GREEN→prova→review)
1. Matriz contratos/gaps (feita via 3 explorers; validar nesta sessão por leitura direta).
2. Testes RED `scripts/v3/lib/OrchestrationMergeMediated.tests.ps1` para o adaptador ausente (falha antes do wiring).
3. Implementar `scripts/v3/lib/OrchestrationMergeMediated.ps1` (mínimoIDS: validação → pin → elegibilidade → readiness SHA exato → `PRODUCTION_AUTHORIZED`/`CREDENTIAL_SCOPE` → persist → revalidar → executar/dry-run → verificar → recibo idempotente).
4. GREEN com estado persistido (store em memória/arquivo injetado; sem segredos em log/recibo).
5. Prova 6A real isolada: branch `test/etapa6-<sha-curto>`, alteração mínima (ex.: `docs/plans/etapa6-proof.md` ou arquivo em `evidence/`), commit+push, `gh pr create`, `github-await.ps1 -GraphQLSnapshotFile` ou `gh api` → snapshot → readiness; registrar PR, SHA, checks, decisão `READY_FOR_MERGE` ou bloqueio justificado. Não mergear.
6. Prova 6B dry-run: `Invoke-OrchestrationMergeMediated -DryRun` no PR de prova (ou fixture), com `VerifyFn` consultando `gh`; demonstrar audit log, idempotência (2ª chamada sem re-execução) e timeout→`RECONCILE`.
7. `coder→tester→reviewer` (+`security-reviewer` por tocar grants/autorização). Corrigir findings antes de avançar.
8. Abrir PR `feat/full-delivery-etapa-6` (esta branch) com código+testes+evidência, sem push direto na master, sem merge real nesta rodada.

## Comandos (PS 5.1 e PS7)
- Preflight: `powershell -NoProfile -File scripts\v3\orchestration-preflight.ps1 -Objective "..." -TaskType ... -Domain ... -Risk ... -ReadWrite ...`
- Foco: `powershell -NoProfile -File scripts\v3\lib\OrchestrationMergeMediated.tests.ps1` (e `pwsh` equivalente).
- Regressão: `powershell -NoProfile -File scripts\test-package-consistency.ps1`; `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1` (ou subconjunto afetado + `git diff --check`).
- GH real: `gh pr create --title ... --body ...`, `gh pr view <n> --json number,headRefOid,state,mergeable,reviewDecision`, `gh api ...`, `powershell -NoProfile -File scripts\v3\github-await.ps1 ...`.

## Donegates por fatia (primeira execução)
- 6A: `ETAPA_6A_READY` se PR+CI+findings+`READY_FOR_MERGE`/bloqueio evidenciado; senão `BLOCKED_UPSTREAM` com causa.
- 6B: dry-run auditável + replay idempotente + timeout→reconcile; sem merge real → não alegar `ETAPA_6B_READY` pleno, registrar parcial.
- 6C: sem staging autorizado → `NEEDS_USER_AUTHORITY`, só contrato + testes (sem efeito).
- 6D: sem wake no host → `BLOCKED_UPSTREAM`, Goal retomável mantido.
- 6E: prova até o gate autorizado; sem simular efeito.

## Riscos e limites
- `runtime_grant_enforcement` OFF-HOLD → efeitos externos só via executor confiável + ambiente controlado; recibos `SOFT_ADVISORY`.
- LLM nunca representa autorização/confirmação; `human_confirmed` bool + identidade + `Authority.authorized` bool são o mínimo, não string.
- Preservar worktree sujo de outros workstreams; nada de `Meu TED`; nada de deploy produtivo.

## Correcao final PR175 (2026-10-30, sem merge real, PR mantido aberto)
- RED→GREEN por fatia: merge commit com SHAs distintos, `squash`/`rebase` bloqueados, merge remoto confirmado sem re-executar, timeout apos efeito => `EXECUTED` reconciliado; scopes leitura/outro-repo/generico e auth expirada bloqueados; grants drift real sem efeito; restart via arquivo + remoto sem re-executar.
- Comandos desta rodada: foco `OrchestrationMergeMediated.tests.ps1` 20/20 (PS5.1+pwsh); regressoes `delivery-gate` 14/14, `interop-pipeline` 8/8, `OrchestrationDelivery` 112 asserts, `external-action-gate` 30/30, `external-action-boundary` 17/17, `test-package-consistency` 16/16, `git diff --check` limpo.
- `Provision bun` do PR174 investigado separadamente como infra (`npm install -g bun` flaky), sem alterar fluxo geral do CI sem reproduzir causa.
- Proximo: 6C-6E. Prova 6B plena ENTREGUE 2026-10-31 em alvo descartavel autorizado (`ETAPA_6B_READY`, ver ACCEPTANCE §7.3).
