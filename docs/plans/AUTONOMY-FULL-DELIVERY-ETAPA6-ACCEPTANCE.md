# ETAPA 6 — Matriz de aceitação (primeira execução)

Data: 2026-10-30 · Branch: `feat/full-delivery-etapa-6` · Base: `origin/master` `ce289a5` · Runtime: OpenCode V2 / PS5.1+pwsh

## 1. Inventário (contratos reutilizados, sem reconstrução)

| Componente | Funções | Consumidores reais | Contrato | Gap fechado nesta fatia |
|---|---|---|---|---|
| `OrchestrationDelivery.ps1` | `Test-OrchestrationMergeEligibility`, `Get-OrchestrationGitHubReadiness`, `Get-OrchestrationDeliveryState` | `OrchestrationAutonomyWiring` (elegibilidade), `github-await`/`github-resume-reconcile` (readiness) | Elegibilidade: policy+checks+reviewer+security+P1+risk; Readiness: snapshot no SHA exato, idade ≤300s, `snapshot_only=true`, sem autoridade | Reuso direto; novo adaptador deriva checks do snapshot |
| `OrchestrationDeliveryGateAdapter.ps1` | `Invoke-OcDeliveryGate`, `Invoke-OcPinnedDeliveryGate`, `Convert-OcDeliveryConclusion` | `interop-pipeline`/`delivery-gate` tests, wiring | Mapeia conclusions→PASS/FAIL/PENDING/UNKNOWN, canal confiável `provider-api\|ci-system\|reviewer-human`, intent com grants/environment | Reuso; merge segue externo por design |
| `OrchestrationExternalActionGate/Boundary.ps1` | `Test-OcGateDecision`, `New-OcExternalIntent`, `Invoke-OcExternalActionBoundary` | Gate/boundary tests | Persiste antes do efeito, revalida grants/env, `PASS→EXECUTED(SOFT_ADVISORY)`, `PENDING→WAIT`, `FAIL→REMEDIATE`, exceção/`UNKNOWN→RECONCILE` | Novo: `PRODUCTION_AUTHORIZED` bool + `CREDENTIAL_SCOPE` ids exigidos fail-closed no adaptador de merge |
| `OrchestrationDurableResume` / `GitHubResume` / `github-watch\|await\|resume-reconcile.ps1` | `Invoke-OrchestrationDurableResume`, `Test-OrchestrationGitHubResume`, observe one-shot | Libs + CLI manual | Single-shot, `GH-OBSERVE` vs `GH-WAIT` vs `GH-WAKE` separados; sem wake automático (`scheduling_gap` explícito) | Sem daemon novo; 6D registrada `BLOCKED_UPSTREAM` |
| Políticas | `delivery-policy.json` (5 checks, review required, auto_merge requires, terminal states), `autonomy-policy.json` (`branch_create/worktree_create/commit/pr_open/findings_repair/ci_rerun` auto; merge/deploy fora), `github-lifecycle-policy.md` (PR obrigatório, merge commit, 5 checks, review) | Wiring + gates | Declarativas; enforcement host-side OFF-HOLD (#69/#70) | Sem `HOST_ENFORCED`; `SOFT_ADVISORY` preservado |

## 2. Novo nesta fatia

- `scripts/v3/lib/OrchestrationMergeMediated.ps1` — `Invoke-OrchestrationMergeMediated`: valida repo/PR/SHA, exige `Authority.authorized -is [bool] $true`, `production_authorized -is [bool] $true`, `credential_scope` (array ≥1, sem segredos, contendo `repo|merge|gh`), bools estritos (string LLM nunca autoriza), pin `PIN_CURRENT` quando fornecido (zero calls senão), elegibilidade + readiness no SHA exato, idempotência `merge|repo|pr|sha` (dry-run não bloqueia real; real após dry-run executa; `CONFIRMED` faz replay), `DryRun` persiste intent e retorna `DRYRUN_OK` sem Executor, real executa via gate injetado + `VerifyFn` pós-estado, timeout/exceção/`UNKNOWN→RECONCILE`, recibo só com ids (sem segredos), `SOFT_ADVISORY`, nunca `DONE`/`verified_pass`.
- `scripts/v3/lib/OrchestrationMergeMediated.tests.ps1` — 12/12 (RED antes do wiring, GREEN após).

## 3. Provas reais

- **6A (operacional, sem merge):** branch `test/etapa6-6a-probe` (`3189f9d`) → PR #174 → `github-await observe` no SHA exato: primeiro `CHECKS_PENDING` (6 checks `IN_PROGRESS`), depois `REPAIR_REQUIRED` (`check-failed: CI (v2 lane...)`). Causa: step `Provision bun` (infra), não o conteúdo do probe. PR fechado sem merge (`state=CLOSED`, `mergedAt=null`; comentário `issuecomment-6532045506`). Decisão: `READY_FOR_MERGE` **negado** com justificativa — CI verde ≠ merge autorizado; review interno ≠ aprovação humana; sem reuso de checks de SHA antigo.
- **6B (dry-run mediado):** `DRYRUN_OK` com recibo `dry_run=true`, chave `merge|kusts/opencode-orchestration|174|<sha>`, replay `IDEMPOTENT_REPLAY` sem re-execução; snapshot pendente → `REMEDIATE` (bloqueia, sem recibo); string LLM → nunca autoriza. Sem merge real nesta rodada.
- **Suítes:** `OrchestrationMergeMediated` 12/12 (PS5.1+pwsh), `delivery-gate` 14/14, `interop-pipeline` 8/8, `git diff --check` limpo.

## 4. Negativos (§8) — cobertura

| Negativo | Onde | Resultado |
|---|---|---|
| CI verde em SHA antigo | teste 1 + probe (head-mismatch) | `RECONCILE`, zero executor |
| Review pendente / changes requested | testes 2–3 + readiness `REVIEW_PENDING` | `REMEDIATE` |
| Autoridade ausente/expirada | teste 4 (+ `production_authorized`) | `NEEDS_USER_AUTHORITY` |
| `CREDENTIAL_SCOPE` incompatível/ausente/com segredo | teste 5 + validação `CREDENTIAL_SCOPE_*` | `POLICY_BLOCKED` |
| Ambiente/grants divergentes | teste 6 (via boundary) | sem pular validação (`EXECUTED/RECONCILE/REMEDIATE/WAIT` conforme gate) |
| Pin desatualizado | implementação (pin `STALE_BUNDLE_PIN:*`, zero calls) | `POLICY_BLOCKED` (padrão herdado do gate pinado) |
| Falha/timeout merge | teste 7 | `RECONCILE`, sem recibo `CONFIRMED` |
| Remoto mergeado, recibo local ausente | teste 8 | reconcilia sem re-executar |
| Replay | teste 9 + dry-run replay | `IDEMPOTENT_REPLAY`, 1 execução |
| Deploy health reprovado / rollback falho | fora desta fatia | `NEEDS_USER_AUTHORITY` (6C sem staging autorizado — só contrato, sem efeito) |
| Credencial indisponível | `CREDENTIAL_SCOPE_MISSING` + `AUTHORITY_*` | bloqueia fail-closed |
| LLM como confirmação externa | teste 10 | string nunca autoriza |
| Operações legítimas não bloqueadas | tester regressão | `delivery-gate` 14/14 + `interop-pipeline` 8/8 verdes |

## 5. Estados de aceite

- `ETAPA_6A_READY`: **parcial** — PR+CI+findings+decisão justificada comprovados; `READY_FOR_MERGE` negado com evidência (CI falhou por infra). Pleno exige PR verde + review + `READY_FOR_MERGE` afirmado.
- `ETAPA_6B_READY`: **parcial (dry-run)** — decisão auditável + idempotência + timeout→reconcile comprovados; sem merge real → pleno pendente de alvo autorizado.
- `ETAPA_6C_READY`: **não alegado** — `NEEDS_USER_AUTHORITY` (sem staging autorizado; só contrato+testes, sem efeito, sem segredos).
- `ETAPA_6D_READY`: **não alegado** — `BLOCKED_UPSTREAM` (sem wake no host; Goal retomável via one-shot existente).
- `ETAPA_6_ACCEPTED`: **não alegado** — jornada integrada até o gate autorizado; sem simular efeito.
- Classificação mantida: `PRODUCTIVE_AUTONOMY_PARTIAL`. Issues #69/#70 abertas → sem `HOST_ENFORCED`/`TRUSTED_HOST_PROVENANCE`.

## 6. Limites e continuidade

- Nenhum merge/deploy real nesta execução; probe fechado sem merge; branch de entrega separada (`feat/full-delivery-etapa-6`).
- Próximo: alvo de teste autorizado para merge real mediado (6B pleno) + staging descartável autorizado (6C) + agendador/evento para wake (6D) + jornada 6E ponta a ponta.
