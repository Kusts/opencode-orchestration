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

- `scripts/v3/lib/OrchestrationMergeMediated.ps1` — `Invoke-OrchestrationMergeMediated`: valida repo/PR/SHA, exige `Authority.authorized -is [bool] $true`, `production_authorized -is [bool] $true`, `credential_scope` (igualdade exata lower-case `github:merge:<owner/repo>`, sem segredos), bools estritos (string LLM nunca autoriza), pin `PIN_CURRENT` quando fornecido (zero calls senão), elegibilidade + readiness no SHA exato, idempotência `merge|repo|pr|sha` (dry-run não bloqueia real; real após dry-run executa; `CONFIRMED` faz replay), `DryRun` persiste intent e retorna `DRYRUN_OK` sem Executor, real executa via gate injetado + `VerifyFn` pós-estado, timeout/exceção/`UNKNOWN→RECONCILE`, recibo só com ids (sem segredos), `SOFT_ADVISORY`, nunca `DONE`/`verified_pass`.
- `scripts/v3/lib/OrchestrationMergeMediated.tests.ps1` — 12/12 (RED antes do wiring, GREEN após) → 43/43 no HEAD 5a41671 → 45/45 no closure (T28 scope caixa-alta, T29 goal-id com segredo; ver §7).

## 2b. Correcao final PR175 (2026-10-30, sem merge real)
- `OrchestrationMergeMediated` 45/45 (PS5.1+pwsh; 43/43 no HEAD 5a41671 + T28/T29 no closure): canonica 5 checks, scope exato lower-case `github:merge:<repo>` (caixa alta rejeitada, T28), ids do recibo sem segredos (T29), `pr_head_sha` vs `merge_commit_sha` separados, `merge` unico metodo, `AUTHORITY_EXPIRED`, grants drift real, timeout-efetivo reconciliado, reconciliacao remota sem re-executar.
- Regressoes: `delivery-gate` 14/14, `interop-pipeline` 8/8, `OrchestrationDelivery` 112 asserts, `external-action-gate` 30/30, `external-action-boundary` 17/17, `test-package-consistency` 16/16, `git diff --check` limpo.
- Duplicacao removida: `Test-MMMirrorEligibility`, `Get-MMMirrorReadiness`, fallback permissivo excluidos; `OrchestrationDelivery.ps1` fonte unica.
- `Provision bun` (PR174): infra `npm install -g bun` flaky, sem alteracao do CI nesta rodada.

## 3. Provas reais

- **6A (operacional, sem merge):** branch `test/etapa6-6a-probe` (`3189f9d`) → PR #174 → `github-await observe` no SHA exato: primeiro `CHECKS_PENDING` (6 checks `IN_PROGRESS`), depois `REPAIR_REQUIRED` (`check-failed: CI (v2 lane...)`). Causa: step `Provision bun` (infra), não o conteúdo do probe. PR fechado sem merge (`state=CLOSED`, `mergedAt=null`; comentário `issuecomment-6532045506`). Decisão: `READY_FOR_MERGE` **negado** com justificativa — CI verde ≠ merge autorizado; review interno ≠ aprovação humana; sem reuso de checks de SHA antigo.
- **6B (dry-run mediado):** `DRYRUN_OK` com recibo `dry_run=true`, chave `merge|kusts/opencode-orchestration|174|<sha>`, replay `IDEMPOTENT_REPLAY` sem re-execução; snapshot pendente → `REMEDIATE` (bloqueia, sem recibo); string LLM → nunca autoriza. Sem merge real nesta rodada.
- **Suítes:** `OrchestrationMergeMediated` 45/45 (PS5.1+pwsh), `delivery-gate` 14/14, `interop-pipeline` 8/8, `git diff --check` limpo.

## 4. Negativos (§8) — cobertura

| Negativo | Onde | Resultado |
|---|---|---|
| CI verde em SHA antigo | teste 1 + probe (head-mismatch) | `RECONCILE`, zero executor |
| Review pendente / changes requested | testes 2–3 + readiness `REVIEW_PENDING` | `REMEDIATE` |
| Autoridade ausente/expirada | teste 4 (+ `production_authorized`) | `NEEDS_USER_AUTHORITY` |
| `CREDENTIAL_SCOPE` incompatível/ausente/com segredo | teste 5 + validação `CREDENTIAL_SCOPE_*` | `POLICY_BLOCKED` |
| Scope leitura / outro repo / generico | testes 5b/5c/5 | `POLICY_BLOCKED CREDENTIAL_SCOPE_INSUFFICIENT`, zero executor |
| Auth expirada | teste 5d (`expires_at` passado) | `NEEDS_USER_AUTHORITY AUTHORITY_EXPIRED` |
| Ambiente/grants divergentes | teste 6 (mutacao real persist-vs-live) | `RECONCILE GRANTS_DRIFT`, zero executor, sem recibo |
| Pin desatualizado | implementação (pin `STALE_BUNDLE_PIN:*`, zero calls) | `POLICY_BLOCKED` (padrão herdado do gate pinado) |
| Falha/timeout merge | teste 7 | `RECONCILE`, sem recibo `CONFIRMED` |
| Timeout apos efeito remoto | teste 7b (`EXECUTOR_EXCEPTION` + `merged=true`) | `EXECUTED RECONCILED_AFTER_TIMEOUT` com `pr_head_sha`+`merge_commit_sha`, `reconciled=true` |
| Remoto mergeado, recibo local ausente | teste 8 | reconcilia sem re-executar |
| Metodo squash/rebase | testes 8b/8c | `POLICY_BLOCKED MERGE_METHOD_PROHIBITED`, zero executor |
| Merge commit com SHAs distintos | teste 8d | `EXECUTED` com `pr_head_sha != merge_commit_sha` persistidos |
| Replay | teste 9 + dry-run replay | `IDEMPOTENT_REPLAY`, 1 execução |
| Reconciliacao remota sem re-executar (store vazio + `MERGED` + `VerifyFn`) | teste 9b (arquivo de intent + `MERGED` + `VerifyFn`) | `EXECUTED` sem re-executar; recibo em arquivo NAO e relido nesta prova (limite registrado no closure §7) |
| Deploy health reprovado / rollback falho | fora desta fatia | `NEEDS_USER_AUTHORITY` (6C sem staging autorizado — só contrato, sem efeito) |
| Credencial indisponível | `CREDENTIAL_SCOPE_MISSING` + `AUTHORITY_*` | bloqueia fail-closed |
| LLM como confirmação externa | teste 10 | string nunca autoriza |
| Operações legítimas não bloqueadas | tester regressão | `delivery-gate` 14/14 + `interop-pipeline` 8/8 verdes |

## 5. Estados de aceite

- `ETAPA_6A_READY`: **parcial** — PR+CI+findings+decisão justificada comprovados; `READY_FOR_MERGE` negado com evidência (CI falhou por infra). Pleno exige PR verde + review + `READY_FOR_MERGE` afirmado.
- `ETAPA_6B_READY`: **ALCANÇADO 2026-10-31 em alvo descartável autorizado** (prova viva §7: merges mediados reais #1 limpo + #2 timeout-reconciliado, idempotência, reconciliação cross-processo, negativos vivos). Para o repositório principal, nenhum merge real foi executado (correto por design — ver §7).
- Classificacao desta rodada: `6B_DRYRUN_READY` comprovado para o fechamento do PR #175 (mediação confiável: identidade separada, autorização exata, canônica única, 45/45 + negativos; sem merge real neste repo) e `ETAPA_6B_READY` entregue via prova viva em alvo descartável (§7).
- `ETAPA_6C_READY`: **não alegado** — `NEEDS_USER_AUTHORITY` (sem staging autorizado; só contrato+testes, sem efeito, sem segredos).
- `ETAPA_6D_READY`: **não alegado** — `BLOCKED_UPSTREAM` (sem wake no host; Goal retomável via one-shot existente).
- `ETAPA_6_ACCEPTED`: **não alegado** — jornada integrada até o gate autorizado; sem simular efeito.
- Classificação mantida: `PRODUCTIVE_AUTONOMY_PARTIAL`. Issues #69/#70 abertas → sem `HOST_ENFORCED`/`TRUSTED_HOST_PROVENANCE`.

## 6. Limites e continuidade

- Nenhum merge/deploy real no repositório principal nesta execução; merges reais somente no alvo descartável autorizado (prova 6B, §7); probe 6A fechado sem merge; branch de entrega separada (`feat/full-delivery-etapa-6`).
- Próximo: staging descartável autorizado (6C) + agendador/evento para wake (6D) + jornada 6E ponta a ponta; exclusão do repo descartável a critério do operador.

## 7. Closure PR175 (2026-10-31, sem merge real neste repo)

- **CI final pré-closure:** run 41138488143, tentativa 2, HEAD `5a41671`, 6/6 SUCCESS (ps51 48m16s, ps7 33m47s, v2-lane 30m18s, smoke real, smoke v2, linux collector). PR #175 OPEN, `MERGEABLE`, `mergeStateStatus=CLEAN`, `reviewDecision` vazio (nenhuma aprovação externa exigida: `required_approving_review_count=0`); zero threads pendentes; nenhum finding Codex observável via gh.
- **Revisão independente desta sessão (substitui o APPROVED auto-afirmado anterior, sem objeto GitHub observável):** tester `PASS` (45/45 PS5.1+pwsh, consistência 16/16, diff limpo); reviewer R1 `CHANGES_REQUIRED` (P1 scope-caixa, P2 claim-restart) → micro-fixes → R2 `CHANGES_REQUIRED` (T28 ambíguo — refutado por demonstração direta `OLDcode_autoriza=True NEWcode_autoriza=False` + T28 endurecido para caixa-alta total) → R3 `APPROVED`; security R1 `CHANGES_REQUIRED` (HIGH VerifyFn-provenance, MEDIUM receipt-ids) → MEDIUM corrigido em código (GoalId/TaskId sem segredos, T29) → R2 confirma fix + reduz HIGH a contrato de wiring → R3 `APPROVED` com condição (contrato registrado abaixo; caminho terminal real pendente de prova viva — entregue em 7.3).
- **Tratamento dos findings:** P1 scope → código (sem `ToLowerInvariant` no candidato, T28); P2 restart → documental (linha 50: reconciliação remota, recibo em arquivo não relido); SEC-MEDIUM → código (T29, reason `INTENT_CONTEXT_INVALID` reutilizado); SEC-HIGH → contrato + wiring `scripts/v3/full-delivery-etapa6-6b-wiring.ps1` (observe+dry-run, 526 linhas, sem caminho real; Authority fail-closed pré-gh; claim-ReviewerApproved sem APPROVED real → `EVIDENCE_MISMATCH`); expiry ausente = válida até revogação (`authorized=false`) por design — wirings reais DEVEM usar `expires_at` curto. Contrato aceito na R3: `VerifyFn`/Executor somente via `gh api` direto (`provider-api`); verificador fabricado invalida o recibo (responsabilidade do caller/wiring); `Get-MMVerifiedMerge` (repo/PR iguais, SHA40, prova de método) como backstop interno.
- **Diff do closure:** módulo +8/-1, testes +15 (T28/T29), wiring novo, docs (este arquivo + SPEC + CHANGELOG). Nenhum outro arquivo tocado; sem reescrita de histórico; sem deploy.
- **Veredito Fase A:** `MERGE_AUTHORIZED` (merge commit, sem squash/rebase, sem deploy) após CI verde no novo HEAD — ver §8 da lifecycle policy (closure dentro do PR; hash do merge via follow-up docs PR).

### 7.3 Prova 6B viva — `ETAPA_6B_READY` (alvo descartável `Kusts/etapa6-6b-disposable-proof`, autorizações do operador em sessão 2026-10-31)

- Alvo: repo descartável público (privado bloqueou Actions por billing) + PR #1 (`43e708f`, 5/5 checks canônicos verdes) + PR #2 (`5d52e4a`, 5/5 verdes). Checks do alvo são triviais por design (objeto sob prova = mecanismo mediado).
- Cadeia de autoridade (toda registrada em audit): merge real autorizado + review humano in-session de ambos os SHAs + semântica `author='planner'` confirmada. Self-approval via gh impossível (`Can not approve your own pull request`); nenhum review-gh afirmado. Desvio Honesto: `ReviewerApproved=$true` espelha decisão humana in-session (canal `reviewer-human`), não objeto gh.
- Negativos vivos (executor 0): N1 `NEEDS_USER_AUTHORITY`; N2a/N2b `RECONCILE/head-mismatch` (SHAs antigos); `SELF_REVIEW` disparado corretamente ao tentar `author=reviewer=Kusts` (invariante O3.3/O3.4 observado em prova real, zero efeitos); `mergeable=UNKNOWN` transitório → abort fail-closed + retry com poll.
- Efeito remoto confirmado: PR #1 `EXECUTED VERIFY_CONFIRMED`, merge commit `75e8ee3`, parents `[3abf79e, 43e708f]` (2, um==head), método merge; PR #2 (timeout simulado: merge via gh + throw) `EXECUTED RECONCILED_AFTER_TIMEOUT`, `reconciled=true`, merge commit `27890eec`, parents `[75e8ee3, 5d52e4a]`; replays `IDEMPOTENT_REPLAY` (1 execução por PR); reconciliação em processo novo (store vazio, sem Executor) `EXECUTED RECONCILED_REMOTE_MERGED` em ambos; recibos `SOFT_ADVISORY` só com ids (`policy_digest cc3554b7…`). Estado remoto final: ambos `MERGED`, zero pendências. Arquivos de autoridade apagados (`Test-Path=False`); recibos em TEMP como evidência.
