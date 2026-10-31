# ETAPA 6 — SPEC (fatia 6A/6B, primeira execução)

Vinculado a `docs/plans/AUTONOMY-FULL-DELIVERY-vNEXT.md` §3–§4 (Etapa 6), §§8–12.

## Objetivo
Caminho operacional GitHub Delivery + merge mediado idempotente com decisão auditável, sem merge/deploy real nesta rodada.

## Non-goals desta fatia
- Sem merge real, sem deploy produtivo, sem Meu TED como validação.
- Sem nova máquina de estados, framework ou sistema de permissões concorrente.
- Sem `HOST_ENFORCED`/`TRUSTED_HOST_PROVENANCE` (issues #69/#70 abertas → `SOFT_ADVISORY`).
- 6C/6D/6E completos ficam para fatias seguintes se faltar alvo/autorização (registrar `BLOCKED_UPSTREAM`/`NEEDS_USER_AUTHORITY`, nunca PASS sintético).

## Baseline e contratos reutilizados (não reconstruir)
- `Test-OrchestrationMergeEligibility` (`OrchestrationDelivery.ps1:174`): elegibilidade (policy, checks required, reviewer, security, P1, risk low/medium).
- `Get-OrchestrationGitHubReadiness` (`OrchestrationDelivery.ps1:524`): snapshot `{repository, pr_number, head_sha, commit_sha, observed_at, pr_state, mergeable, review_decision, checks_complete, checks[]:{name,head_sha,status,conclusion}}`; valida SHA exato, idade ≤300s, checks no SHA, review; retorna `READY_FOR_RESUME/CHECKS_PENDING/REVIEW_PENDING/REPAIR_REQUIRED/STALE/TERMINAL/INCONCLUSIVE`, sempre `snapshot_only=true`, sem autoridade.
- `Invoke-OcDeliveryGate` / `Invoke-OcPinnedDeliveryGate` (`OrchestrationDeliveryGateAdapter.ps1:49/101`): mapeia conclusions provider→gate, exige canal `provider-api|ci-system|reviewer-human`, persiste intent (grants+environment snapshot) e delega ao boundary. Merge segue externo (humano/bot) por design.
- `New-OcExternalIntent` / `Invoke-OcExternalActionBoundary` (`OrchestrationExternalActionBoundary.ps1:39/57`): persiste antes do efeito, revalida grants/env, gate, executor injetado; `PASS→EXECUTED` (recibo `SOFT_ADVISORY`), `PENDING→WAIT`, `FAIL→REMEDIATE`, exceção/UNKNOWN→`RECONCILE`. Sem `PRODUCTION_AUTHORIZED`/`CREDENTIAL_SCOPE`.
- `Invoke-OrchestrationDurableResume` / `Test-OrchestrationGitHubResume` / `github-watch|await|resume-reconcile.ps1`: one-shot, sem wake automático (`scheduling_gap` explícito).
- Políticas: `delivery-policy.json` (5 checks required, review internal required, auto_merge allowed com requires, terminal states), `autonomy-policy.json` (`branch_create/worktree_create/commit/pr_open/findings_repair/ci_rerun` auto-authorized; merge/deploy fora), `github-lifecycle-policy.md` (PR obrigatório, merge commit, checks+review, sem direct master).

## Gaps (só conexões faltantes)
1. Sem decisão unificada `READY_FOR_MERGE` ligando elegibilidade + readiness + gate pinado no SHA exato.
2. Sem adaptador de merge mediado: exigir repo/PR, conferir HEAD/policy/risco/checks/autorização, persistir intenção antes do efeito, revalidar remoto imediatamente antes de executar, executar método da política, consultar GitHub depois (`merged`, SHA, estado), recibo ligado a Goal/Task/PR/SHA/policy/autoridade/idempotência, idempotente em replay, timeout→reconciliar antes de retry.
3. `PRODUCTION_AUTHORIZED`/`CREDENTIAL_SCOPE` não exigidos pelo gate/boundary (fail-open por omissão).
4. Sem executor real de coleta snapshot (`gh api`→snapshot) plugado como função reutilizável (hoje só CLI one-shot).
5. Sem wake (6D): one-shot + instrução; sem agendador/evento no host.

## Decisões desta fatia
- Novo `OrchestrationMergeMediated.ps1` (adaptador fino): valida entradas, checa pin, elegibilidade, readiness no SHA exato, `PRODUCTION_AUTHORIZED` (bool) e `CREDENTIAL_SCOPE` (ids, sem valores), persiste intent, revalida, executa via `Executor` injetado (merge real) ou `DryRun` (sem efeito), verifica pós-estado via `VerifyFn`, emite recibo, garante idempotência por chave (`merge|repo|pr|sha`) em store injetado. String da LLM nunca é autorização: só `Authority.authorized -is [bool] -and $true` + grants/environment + (risk medium+ → reviewer + human_confirmed bool) contam.
- Coletor snapshot reutilizável mínimo: construir snapshot para `Get-OrchestrationGitHubReadiness` a partir de `gh api` (PR + commit + checks) sem duplicar validação (a validação permanece no readiness).
- Prova real 6A: branch/teste isolado neste repo, push, PR (draft ou normal), `github-await.ps1` com snapshot real, CI observado; sem merge; fechar PR sem merge ou manter como evidência conforme política.
- Prova 6B: dry-run mediado com decisão auditável (audit log), replay sem duplicar, falha/timeout→`RECONCILE`.

## Aceite (primeira execução)
- `ETAPA_6A_READY` parcial: mudança real → PR criado → CI observado → findings tratados → `READY_FOR_MERGE` ou bloqueio justificado com evidência. CI verde ≠ merge autorizado; review interno ≠ aprovação humana; sem reuso de checks de SHA antigo.
- `ETAPA_6B_READY` parcial: dry-run mediado com decisão auditável + idempotência comprovada; sem merge real nesta rodada.
- Negativos §8 cobertos por RED→GREEN com estado persistido; `6C/6D/6E` registrados como parciais/bloqueados com causa quando sem alvo/autorização.
- `PRODUCTIVE_AUTONOMY_PARTIAL` mantida; sem `HOST_ENFORCED`.

## Correcao final PR175 (2026-10-30, branch feat/full-delivery-etapa-6, base 46f056d)
- P0-A identidade: separa `pr_head_sha` (HEAD autorizado) de `merge_commit_sha` (SHA de integracao do merge commit, metodo `merge` apenas; `squash`/`rebase` => `POLICY_BLOCKED MERGE_METHOD_PROHIBITED`). Verificacao remota exige `merged=true`, repo/PR iguais a intencao autorizada, `merge_commit_sha` SHA40 valido e metodo `merge` quando presente, sem exigir igualdade com o HEAD original. Recibo persiste ambos (`pr_head_sha`, `merge_commit_sha`, `merge_method=merge`). Timeout/excecao apos efeito remoto bem-sucedido reconcilia para `EXECUTED` (`RECONCILED_AFTER_TIMEOUT`, `reconciled=true`) em vez de `RECONCILE` cego.
- P0-B autorizacao exata: `credential_scope` exige igualdade exata `github:merge:<owner/repo>` em lower-case (sem substring `repo`/`merge`/`gh`); leitura, outro repo ou scope generico => `POLICY_BLOCKED CREDENTIAL_SCOPE_INSUFFICIENT`. `author` nao-vazio obrigatorio; `Authority.expires_at|valid_until|expires` passado => `NEEDS_USER_AUTHORITY AUTHORITY_EXPIRED`. Preserva `PRODUCTION_AUTHORIZED` bool e grants/environment snapshot sem config concorrente.
- P1-A canonica unica: removidos `Test-MMMirrorEligibility`, `Get-MMMirrorReadiness` e fallback permissivo de shape; `OrchestrationDelivery.ps1` e canonico (`delivery-policy.json` com `deletion_protected`, `terminal_states`, `security_reviewer_on` nao-vazio). Testes usam policy canonica.
- P1-B provas: grants divergentes via mutacao real entre persist e revalidacao (`GRANTS_DRIFT`, zero executor, sem recibo); idempotencia apos reinicio via persistencia em arquivo + reconciliacao remota (`MERGED` + `VerifyFn`), store em memoria nao sustenta exactly-once entre sessoes.

## Contrato de wiring confiavel (closure 2026-10-31, condicao da security-R3)

- `VerifyFn`/Executor sao pontos de injecao confiaveis: SOMENTE implementacoes que consultam o GitHub diretamente (`gh api`, `EvidenceChannel` `provider-api`) podem ser injetadas; verificador fabricado pelo chamador invalida o recibo (responsabilidade do caller/wiring, nao do adaptador). `Get-MMVerifiedMerge` valida igualdade repo/PR + SHA40 + prova de metodo como backstop interno. Wiring de referencia: `scripts/v3/full-delivery-etapa6-6b-wiring.ps1` (observe+dry-run, sem caminho real; Authority fail-closed pre-gh; claim sem APPROVED real => `EVIDENCE_MISMATCH`).
- Expiry ausente = valida ate revogacao (`authorized=false`) por design; wirings reais DEVEM usar `expires_at` curto. Independencia do revisor (O3.3/O3.4): `Authority.author` ≡ `ReviewerIdentity` => `POLICY_BLOCKED SELF_REVIEW` (observado em prova real, zero efeitos).
