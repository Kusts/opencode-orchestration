# Plano de Execução — Refinamento Funcional 2026-10-17

**Base:** relatório `OPENCODE ORCHESTRATION — RELATÓRIO DE REFINAMENTO` (HEAD `64972c6`, v0.1.2, V2)
**Estado verificado nesta sessão:** `BASELINE_BLOCKED` (procedural) + `P0-02 FAIL` (`.env` desprotegido)
**Método:** hybrid-development (Structured track) + systematic-debugging para P0-03 + writing-plans
**Preflight:** `DETERMINISTIC_FALLBACK` (`hard_exclusion_infra_mutation`), `task_class=non_trivial`

## 1. Contrato

**Objetivo:** fechar P0 funcional cooperativo sem novo framework, sem segundo Kernel/Planner, sem expansão prematura (P2 em backlog).
**Não-objetivos:** Model Router (#99), Teams (#2), Swarm/Arena (#3/#5), Control Center (#49), VNext (#6/#7), skill/MCP routing, enforcement estrito host-side.
**Aceite global:** Gates 1-6 do relatório com prova runtime-real; veredito honesto `COOPERATIVE_RUNTIME_READY` / `PARTIAL` / `BLOCKED_*` — nunca PASS fictício.

## 2. Baseline confirmado (Etapa A — 2026-10-17)

- HEAD/master/origin/master = `64972c682a26cff82c0d8f43c5e12469b1d5bf31`, branch `master`. Merge local `fix/lane-scenario-isolation-f1` + push (+8s), não PR. Viola `docs/github-lifecycle-policy.md §1/§3`. CI do HEAD: 6/6 success (run 39042589906). Protection efetiva não verificável sem auth (401). `packed-refs` stale (irrelevante, loose prevalece).
- `.gitignore` 22 linhas sem `.env`. `?? .env` untracked, `check-ignore` exit 1, `ls-files` não-tracked. Risco ativo de commit acidental. Fix de 2026-10-15 ficou em `stash@{0}`, não no HEAD.
- Runtime observado: `opencode v2.0.32` vs pin `2.0.23` vs inventário `2.0.29`. Diferença a medir por probes, não por patch.
- Flags: ON `task_kernel,bounded_execution(watch, enforce=false),watchdog,jev_advisory,worktree_isolation`; OFF roteamento/enforcement. Não alterar para fazer teste passar.

## 3. Diagnósticos P0-03/04/05 (sem reimplementar o que funciona)

- **P0-03 RR-E2E-21:** kernel-side provado (replace, preserve, history, no-false-terminal). Gargalo = `substitute-reread-turn` (turno substituto stall/hollow, matcher fail-closed `blocked`). 5 braços falhados (r1/r2/r3/zai-429/luna/deepseek). Conclusão repo: task-shape não converge. Experimentos A-E do relatório não existem como artefato — usar braços como base, 1 variável/execução, sem aumentar timeout sem causa.
- **P0-04 caminho produtivo:** único executor = Planner LLM via `subagent` nativa. `PlannerLoop` planning-only; `AutonomousLoop` produz `dispatch_intent` (`awaits-planner`) ou legado síncrono com `Executor`. Kernel `WorkerResult→Verification→Review→Complete(DONE único)→GoalPersisted(CAS)`. Worker só `candidate_pass|failed|blocked`. Barreira de fases = disciplina F3, não contrato kernel.
- **P0-05 GitHub:** `github-await/watch` read-only → `Get-OrchestrationGitHubReadiness` → `READY_FOR_RESUME/PENDING/TERMINAL/STALE`. Sem watcher/registro/resume automático. Exit 0 = observação, não autorização.
- **P0-06 lifecycle:** recibo pending→settled, CAS/fencing existem; janela releitura→persistência + lock recibo não serializa goal; `pending-ambiguous` exige reconciliação explícita; replay só com `external_idempotent=true`.

## 4. Ordem de execução

### Etapa A — Auditoria + correções imediatas (agora)
1. `P0-02` coder: `.gitignore` += `.env`, `.env.*`, `!.env.example` (+ teste `check-ignore`, `ls-files`, canário). Tester + reviewer. **Sem imprimir valores.**
2. `P0-01` operador: confirmar protection via API autenticada + listar PR de `64972c6` ou registrar break-glass/post-hoc; Planner roda `git status` limpo.
3. Plugin V2 healthcheck + identificar regeneração `ai-memory.ts` (#25) sem tocar user-owned.
4. Atualizar matriz gaps (este arquivo + `evidence/closure/`).

### Etapa B — Recuperação + execução produtiva
5. `P0-03`: F5-D dedicado ao 21 com `-TurnModel` variado, 1 variável/exec, orçamento explícito, captura fase/tool-call/motivo. Manter `blocked` até `substitute-reread-turn=true` (canário+state mesma unidade). Não afrouxar matcher.
6. `P0-04`: prova 3 fases via `objective-step next/settle` + Planner `subagent` real, sem driver manual; evidência IDs (`objective/task/run/session/recibo`) + DONE só por `Complete-OrchestrationTask`.
7. `P0-06` negativos: worker-morre-antes-SETTLE, SETTLE-sem-sessão, double-claim, lease-expirada, geração-antiga, evento-duplicado, cancel-then-result, idempotency-divergente, fase-antes-barreira, sucesso-sem-verificador. `pending` ambíguo nunca auto-repete efeito.

### Etapa C — Esperas externas
8. `P0-05`: contrato durável `(objective/task/run/generation, repo/pr/branch/head_sha, checks/review, cursor, deadline/budget/lease/owner, wait-state)` sem tokens/transcripts. Caller Planner em sessão ativa observa `github-await observe` e ao ver `READY_FOR_RESUME` revalida SHA/checks/lease e invoca próximo step. Testes: verde→continue, vermelho→diagnóstico, review-changes, commit-invalida, 429/offline, duplicado, fora-de-ordem, restart-durante-espera, PR-fechado, cancel, executor-ausente (notifica, sem falso sucesso).

### Etapa D — Integrações
9. P1-01 estabilidade (separar modelo/transporte/TUI/filho/harness; Job Objects; sem kill global), P1-02 Jev/advisor (via `engineering-advisor`, próxima-ação verificável, fallback determinístico), P1-03 MCP S5/S6 mínimo, P1-04 distribuição V2 (probes capabilities, pin CI preservado), P1-05 watchdog/budgets (NO_PROGRESS vs lento, STEER primeiro, kill só com PID+creation+ownership), P1-06 segurança proporcional (A cooperativo / B sensível / C HOLD), P1-07 GW fila (preservar PASS reais, focar GW05/06/08/09/10/11/12/13).

### Etapa E — Fechamento
10. Suites `test-package-consistency`, `run-v3-tests`, `distribution`, F1FIX01/post17gate/F2trail em PS5.1+PS7; CI HEAD final; docs reconciliadas (ARCHITECTURE/INSTALLATION/TROUBLESHOOTING/CHANGELOG); matriz GW15 final; veredito auditável.

## 5. Verificação por frente

Comandos (sem substituir engine real):
```powershell
powershell -NoProfile -File scripts/test-package-consistency.ps1
powershell -NoProfile -File scripts/v3/run-v3-tests.ps1
powershell -NoProfile -File tests/distribution/run-distribution-tests.ps1
```
Runtime-real via parâmetros próprios de cada lane, apenas com opt-in (modelo/cred). Evidência JSON por frente: `work_item,status,base_sha,final_sha,runtime{generation,version,fingerprint},changes,tests,runtime_proofs,remaining_blockers,related_issues,rollback,next_action` — sanitizada.

## 6. Riscos e HOLDs honestos

- `bounded_execution` ON mas `ExecutionBudget enforce=false`; Phase 5 HOLD; `runtime_grant_enforcement.v2` HOLD; barreira fora do kernel; enforcement OFF.
- Não redesenhar Kernel/Dispatch sem defeito provado. Não criar daemon/watcher como segundo control plane.
- Issues #69/#70 impedem claim de enforcement estrito, não operação cooperativa supervisionada.

## 7. Próxima ação concreta

`P0-02` coder agora (menor diff `.gitignore`), depois tester+reviewer; em paralelo operador para P0-01 auth.

## 8. Progresso 2026-10-17 (sessão continuação)

- Branch `fix/gitignore-env-2026-10-17` criada de `64972c6`; master intacto.
- Commit local `ac20738` só `.gitignore` (+3), sem push. Plano segue untracked por decisão.
- Plugin V2 healthcheck PASS (diagnóstico, `invocation_proven=false`); `ai-memory.ts` sem gerador no repo (fonte externa legada, policy proíbe).
- Distribuição V2: template 21 blocos agents; manifest cobre 21; V1 17 blocos.
- Suites: `test-package-consistency` direto 15/1 FAIL ambiental (`Get-FileHash` ausente neste PS5.1) vs isolado 16/16 PASS; `run-v3` parcial verde (6 suites) e `distribution` parcial verde (17 suites), ambas incompletas por timeout 300s do executor. Rodada integral em background (`ETAPA-A-SUITES-FULL`).
- Pendente operador: protection autenticada + PR de `64972c6`/break-glass; provider/modelo para P0-03 e lanes.
- Rodada integral background `ETAPA-A-SUITES-FULL`: V3 98 suites em 2404.5s → PASS 88 / FAIL 4 / SKIP 6, exit 1; distribution 23 suites em 301.2s → PASS 21 / FAIL 1 / SKIP 1, exit 1. 0 assertion funcional falhou: 3 FAILs V3 = assert live-file DE22307F (config viva diverge do canônico, HOLD pré-existente); 1 FAIL V3 = CapabilityShadowSample TIMEOUT 300s com revalidação isolada 73/73 exit 0; 1 FAIL distribution = drift disco-vs-catálogo (`find-skills` extra em `~/.agents/skills`). package-consistency PASS no runner; FAIL direto anterior confirmado ambiental (PSModulePath/Get-FileHash). Nenhuma lane com modelo/cred executada. Veredito funcional VERDE com FAILs ambientais; não alterar código por eles.
- PR #108 aberto (`fix/gitignore-env-2026-10-17` → master, só `.gitignore` +3, OPEN MERGEABLE). Merge pendente de CI verde + revisão (fora do escopo desta sessão).
- PR #108 MERGEADO em `19de04a` (6/6 verde, merge commit, sem bypass). PR #109 aberto e MERGEADO em `fb8d066` (6/6 verde no run 39077167101 pós-update-branch `fa245db`, merge commit, sem bypass). Master remoto = `fb8d066`. PR #110 MERGEADO em `3321967` (6/6 verde).
- P0-03 F5-D braço 6 concluído: H1 REFUTADA. Probe auth ok (rc=0, ~4-7s, sem 401/403/429). Lane 21 completa: RR-E2E-21 `blocked`, turno substituto rc=-1 timeout 180s (step_start + 1 texto + stall — mesma assinatura dos braços timeout-stall; zai-rc=1 é outra família). Chave presente e funcional ⇒ causa é task-shape/provider, não falta de chave. Caveat: lane usa binário do pin 2.0.23 (shim 2.0.32 não se aplicou). Classificação: `BLOCKED_UPSTREAM` (turno do substituto trava downstream da auth em todos os modelos testados); parcial kernel-side segue provado. Retomada só com hipótese nova de prompt-shape (experimentos A-E do relatório), nunca repetindo mesmos parâmetros. Evidência: `evidence/v3.1/runtime-reliability/session-lane-2026-10-18/` (untracked, não sobrescrever).
- P0-06 em andamento: gap-map com 10 casos (1/3/4/5/6/8/10 já cobertos; 7 parcial; 9 harness-only por design). Caso 7 fechado: bloco F8 em `OrchestrationNativeDispatch.tests.ps1` (settle-pós-cancel → task-terminal, 0 calls, recibo byte-idêntico; goal CANCELLED bloqueia) — coder candidate_pass + tester PASS 202/202 + reviewer APPROVED. Caso 2 fechado: bloco [R2c] em `OrchestrationNativeDispatchReceipts.tests.ps1` (releitura settled como idempotent-duplicate, linhagem armazenada, 0 calls) — coder + tester PASS 208/208 + reviewer APPROVED. DECISÃO TÉCNICA (caso 9): barreira permanece disciplina de harness (HOLD declarado no header F3), sem gate no kernel sem defeito provado — não redesenhar por hipótese. Runtime-real (kill de processo, perda real de sessão) fica para lane futura.
- P1-06 em andamento: S1 fechado (bind model/variant/provider imutável em `OrchestrationExecutionBudget.tests.ps1`, +4 asserts, 121/121 via pwsh — coder + tester PASS + reviewer APPROVED). S2 fechado com claim honesto (scope-mismatch em `OrchestrationE2eManifest.tests.ps1`, 259/259 em ambos shells — reviewer exigiu prova de citação forjada; contrato só vincula por scope, claim limitado e documentado — re-tester PASS + re-reviewer APPROVED).
- S5 entregue e aprovado (STEER advisory opt-in + CLOSE-vs-RETRY fail-closed no seam; reviewer+security exigiram dispatcher guard e CLOSE sticky — corrigidos e revalidados: suite 62/62, enforcement 432/432, reviewer APPROVED, security APPROVED). Restantes: S6 e shell/REST seguem HOLD (nível C).
- P1-07 snapshot GW01–GW15 2026-10-18 criado (delta da rodada, matriz normativa intocada; reviewer exigiu exatidão nos números de regressão — corrigido: V3 88/4/6, distribution 21/1/1, FAILs ambientais — re-reviewer APPROVED).
- P1-02 Jev: cadeia advisory-only mapeada (MCP→trigger→DecisionProvider→invoke→envelope→evidência; fallback total sem Jev). Slices sem chave: contador offline (chave JSON + Ordinal, 12/12), matriz triggers×advisor (lacunas L1-L3 honestas), nota de credenciais (só nomes) — coder + tester PASS + reviewer APPROVED após 1 correção (colisão de delimitador).
- S3 fechado (binding sessão-pai + fencing via operação pública: takeover→claim auth antiga recusa sem efeitos; helper isolado documentado como tal — coder + tester PASS 231/231 em ambos shells + reviewer APPROVED após 1 correção).
- S4 fechado (isolamento cross-MCP no gate: sem herança/vazamento, status distintos OK vs MCP_CALL_OK por chamada — coder + tester PASS 216/216 + reviewer APPROVED após 1 correção).
- PR #117 aberto (P1-06 S1–S4, commit `f1853f9`, 4 arquivos só-testes): branch validada localmente (121+259+209+216, 209 = sem F8 que segue no PR #110) — rebase resolvido pós-#110 (F8+S3, 231/231 local, push `ec5f8b1`) — job v2-lane falhou 2x com assinaturas DISTINTAS (1ª: cenário 7 + LiteralPath vazio 7ms; 2ª: F1 path-mismatch x3 178ms, cenário 7 passou) → debugger com hipótese nova (divergência de representação do Process.Path, -cne antes do check de criação) → instrumentação DIAG log-only (hash/comprimento/bool, zero asserts, reviewer APPROVED) commitada e pushada (`fc590ff`, fast-forward, sem force); CI 3º run VERDE 6/6 (run 39151669235); assinatura DIAG do run vencedor: `ord_eq=True + ci_eq=True`, SHAs idênticos (caminho saudável) — 3 assinaturas distintas em 3 máquinas ⇒ flake ambiental, sem bug determinístico; DIAG permanece como telemetria. PR #117 MERGEADO em `9038574` (sem bypass). PR #118 e #120 atualizados pós-#117 (sem conflito) e falharam no ps51 com assinaturas NOVAS e DISTINTAS entre si (118: conversão string após DIAGs saudáveis; 120: 2x NO_PROGRESS, trace exonerando o diff) → instrumentação catch-site sanitizada em ambas (log-only, zero asserts, validada local 432/432 e 443/443) pushada fast-forward; CI decide pela assinatura. PR #118 MERGEADO em `c9e12d8a` (6/6 verde; DIAG do run vencedor todo saudável, sem DIAG-UNEXPECTED — flake confirmado; DIAG permanece como telemetria). PR #120 atualizado pós-#118 sem conflito — CI rodando, merge após verde.
- P1-08 docs: caller P0-05 + STEER/CLOSE documentados em `docs/ARCHITECTURE.md` (+108 aditivo, sem reescrita; HOLDs e status fora-do-master honestos) — docs-manager + reviewer APPROVED. Correções V2 mínimas em README/INSTALLATION/TROUBLESHOOTING (3 comandos canônicos, V1 legado, aviso S5) — reviewer APPROVED; contagem distribution corrigida 13→23 (evidência: 23 arquivos + run 21/1/1). PR #119 (docs: +108 ARCHITECTURE, README/INSTALLATION/TROUBLESHOOTING, CHANGELOG [Unreleased], contagem 23; commits até `8a7aa46` + CHANGELOG — review independente APPROVED) MERGEADO em `e5eff6a` (6/6 verde, sem bypass).
- P1-01 trava PIDs: auditoria achou fallback que resolvia por PID sem revalidar ownership → fail-closed + teste foreign-live (PID 4/pai/49374 recusados, vivos após) — coder + tester PASS 443/0 + 134/0 + reviewer APPROVED + security APPROVED. PR #120 aberta (p1-01-kill-isolation, commit `b0d7b22`, 2 arquivos) — CI pendente.
- P0-04 slice 1 `RUNTIME_FLOW_PASS`: goal `p0-04-slice1` COMPLETED rev11 (ACTIVE→COMPLETED só via `Set-OrchestrationGoalStatePersisted` após gate `allowed=True`); f1/f2/f3 DONE rev9 cada, com worker `candidate_pass` + verification passed + review approved + `Complete-OrchestrationTask` COMPLIANT por fase; avanço f1→f2→f3 sem prompt manual (Planner despachou via subagent nativa a cada intent). Artefatos `docs/p0-04-proof/` untracked, fora do PR.
- P0-05 caller entregue e validado: `scripts/v3/lib/OrchestrationGitHubResume.ps1` (Register/Test/Confirm/List, fail-closed, sem daemon/rede/segredo) + suite `scripts/v3/lib/OrchestrationGitHubResume.tests.ps1` 107/107 PASS via runner; reviewer pediu 3 correções (policy-diverged, filename hash, CAS) + 1 HIGH residual (baseline), todas implementadas e revalidadas (tester PASS + reviewer APPROVED final). Branch `p0-05-github-resume` desde master, commit `dcf7768` (2 arquivos), PR #109 aberto contra master. Só então F5-D 21.
