# Universal Autonomous Orchestration v0.1.0 — Closure Addendum (v0.1.1 corretiva)

Data: 2026-10-08. HEAD inicial `b945d40ce0` (master, merge PR #34). Branch: `closure/v0.1.1-job44-stable-core`.
CI de referência: master push `37709923028` FAIL (ps51, 1 assertion); PR `37707618318` SUCCESS.
Veredito desta rodada: **PARTIAL CLOSURE** (CI pós-merge corrigida + gaps mapeados; wiring produtivo permanece HOLD honesto).

## 1. Estado inicial
- `VERSION=0.1.0`, tag `v0.1.0` → `2daa6af` (anterior ao merge final `b945d40`). Não reescrever tag publicada.
- PR #34 merged; CI do PR verde; CI da master após merge vermelha em `OrchestrationRuntimeWatchdogEnforcement.tests.ps1` cenário JOB44.
- Issues abertas relevantes: #1, #6, #8/#9/#10, #16, #19, #21, #25, #30 (nenhuma fechada nesta rodada por falta de prova completa).

## 2. Auditoria produtiva — matriz IMPLEMENTED → WIRED → ACTIVE → RUNTIME-PROVEN
| Componente | Estágio | Nota |
|---|---|---|
| Preflight | RUNTIME-PROVEN | CLI + DONE gate, usado por policy/lanes |
| PlannerLoop | ACTIVE (lib) / parcial | planning-only, never dispatches; único caller Jev P38-S2 advisory-only |
| DispatchPipeline | ACTIVE (lib) / parcial | consome plan record; record-only (`spawned=false`); não faz spawn |
| ObjectiveController | ACTIVE como cálculo | função pura `next_move`; não loopea/não executa |
| ObjectiveRunner.harness | TEST HARNESS — NOT PRODUCT | único loop que itera (bounded 20, outcomes sintéticos) |
| DecisionProvider | NÃO-CONECTADO / test-only | seam `-JevProbe`; não toca Loop/JevAdvisory |
| JevAdvisory | ADVISORY-ONLY | flag born-OFF/shadow; transporte env user-owned fail-closed; nunca roteia/concede/DONE |
| EvidenceStore | ACTIVE / provado em lanes | reuse automático no PlannerLoop; TTL só se condição presente (risco reuse indefinido sem ttl) |
| GoalPromotion | SCORE-ONLY, NÃO-CONECTADO | só pontua; wiring pertence a fase posterior |
| GoalKernel | ACTIVE (lib) | CRUD+CAS, store `cache/goal-store`; provado em harness/testes |
| GoalProgress | SCORE-ONLY | delta/estagnação; loop-guard posterior |
| GoalCheckpoint | IMPLEMENTED (store atômico) | consumido pelo harness; nunca toca sessões reais |
| SessionReconciler | READ-ONLY/ADVISORY | nunca proba/controla sessões; V2 probing HOLD |
| TaskKernel | RUNTIME-PROVEN (mais forte) | CAS+lock, DONE só via `Complete-OrchestrationTask`; provado em lanes reais |
| Delivery | DECISÓRIO-ONLY | elegibilidade + state machine; merge/checks com chamador externo |
| Enforcement plugin/adapters V1/V2 | gates kernel+flags+watchdog; adapters = doutrina/policy | sem plugin dedicado; executor vivo é o Planner (caller manual) |
| `runtime_grant_enforcement.v1/v2` | OFF (HOLD Phase 5, fail-open `/shell` 2.0.23) | autorização declarada sem deny runtime; DONE não falsificável pelo worker (gate kernel) |

Contrato `TASK_DONE≠OBJECTIVE_DONE` (SPEC INV-006) existe como texto de plano/contrato; **nenhum loop produtivo consome CONTINUE/RETRY/REPLAN até COMPLETE fora do harness**.

## 3. Causas-raiz
- **JOB44 (Fase F):** `Get-EnforceSettlementShape` era denylist só de `job_*` e concatenava resto `k=v;`. Campos voláteis de observação (`tree_excluded`/`exclusion` do snapshot CIM, `telemetry_file`/`telemetry_written` do writer) divergiram entre runs sequenciais (attach 2 vs refused 0, CI ps51 2026-10-08) sem mudança no que foi morto. Segurança preservada nos asserts per-run (child killed, sentinel intact, refused sem job kill). Não é regressão do fallback CIM-only; é asserção excessivamente estrita sobre observação ambiental nondeterminística. JOB46 passou no mesmo run, confirmando nondeterminismo ambiental.
- **Gaps B/C:** Controller puro + Dispatch record-only + PlannerLoop planning-only + Promotion score-only por construção (fases entregaram libs + harness S1-S8, não executor vivo). SPEC prometeu continuação produtiva e auto-promotion (SPEC §9-15, PLAN Fase 5, ADR GoalLoop event-driven); executor concreto (caller produtivo do Planner em safe boundaries) nunca foi especificado — sem daemon como requisito, mas sem ownership/idempotência/budget verificáveis.
- **D:** DecisionProvider sem transporte real (só `-JevProbe`); JevAdvisory é a camada com probe real mas advisory-only e single-caller. Reuse funciona no PlannerLoop, mas persistência depende de `store_dir` do caller e TTL condicional.
- **E:** Envelope/Stop declarativos; `auto_authorized` amplo sem deny runtime enquanto enforcement for HOLD. Issue #19 permanece aberta.

## 4. Alterações executadas (esta rodada)
- Só `scripts/v3/lib/OrchestrationRuntimeWatchdogEnforcement.tests.ps1`: `Get-EnforceSettlementShape` vira allowlist do núcleo estável (`engaged/interrupted/settlement/classification`); `job_*` segue fora como diferença intencional; `tree_excluded/exclusion/telemetry_file/telemetry_written` fora como observações voláteis documentadas; asserts JOB44/JOB46 renomeados para "stable settlement core identical" + comentários atualizados. Nenhum produtivo, deny, flag ou verifier tocado.
- Validação: `run-v3-tests -Name *Enforcement*` 421/421 fail 0 (184s); `*RuntimeWatchdog.tests*` 134/134; `git diff --check` limpo; `git diff --stat` 1 arquivo. Full 74 suites não rodada (tempo); declarado como residual.
- Review independente: ** indisponível nesta rodada (limite de subagents atingido após 6 delegações: 3 explorers + coder + architect + tester)**. Planner executou review determinístico direto (diff + guards JOB45/46 + grep taskkill/49374). Residual registrado; re-review independente recomendado antes do merge final.

## 5. Diferenças em relação ao PLAN
- PLAN previa harness S1-S8 como fechamento de Fase 15; confirmado como parcial/test-only, não produto.
- Correção JOB44 estreita o comparador cross-run em vez de fixar fixture temporal — decisão documentada: contagem ambiental não é decisão de settlement; segurança segue pinada per-run.

## 6. Segurança
- Nenhum taskkill nas libs; enforcement nunca toca 49374; PID desconhecido recusa sem engajar job; job não amplia autoridade; DONE só via kernel com verification allowlisted. `runtime_grant_enforcement` permanece HOLD explícito com mitigação (gates kernel + watchdog + review). Não ativar flag sem prova runtime-real.

## 7. Testes e provas runtime-real
- Provas executadas: Enforcement isolada + Watchdog base (ambientes Windows PS5.1 local). Golden Workflows e cenários Cenário 1-5 com OpenCode real **não executados nesta rodada** (tempo/orçamento sessão + limite subagents); gates permanecem abertos.
- CI: aguardando run do PR desta branch; critério é verde no HEAD final, não só no PR anterior.

## 8. Issues e versionamento
- Nenhuma issue fechada; #19/#16/#21/#25/#30/#6/#1/#8/#9/#10 reconciliadas como implementadas-parcialmente ou bloqueadas por runtime, nunca como concluídas sem prova.
- Tag `v0.1.0` intocada. Se CI verde + re-review independente aprovar, preparar release corretiva `v0.1.1` (SemVer patch, só fix de teste + addendum).

## 9. Residuais (gates abertos)
1. Re-review independente (reviewer + security-reviewer) da mudança JOB44.
2. Full `run-v3-tests` (74 suites) + distribution + CI verde no HEAD final.
3. Executor produtivo mínimo (opção B do architect): caller do Planner em safe boundaries, ownership CAS por Goal, idempotência (intenção antes do dispatch, chave estável), hard budget persistido + watchdog, ciclo promoção→Goal→TaskKernel→dispatch real→barrier→evidência verificada→progress→checkpoint→next_move, DONE só via kernel. Sem isso, auto-promotion/continuação/checkpoint-resume seguem HOLD.
4. `ttl` default na produção de evidências; padronizar `store_dir` default em operação real; decidir wiring DecisionProvider vs JevAdvisory (uma autoridade consultiva).
5. Cenários runtime-real 1-5 com OpenCode instalado; `runtime_grant_enforcement` segue HOLD até prova exact-binary-live.

## 10. Veredito
**PARTIAL CLOSURE**: CI pós-merge endereçada com causa-raiz e fix validado isoladamente; matriz honesta IMPLEMENTED→RUNTIME-PROVEN produzida; wiring produtivo e auto-promotion documentados como HOLD (não alegar FINAL). Próximo passo: re-review + CI verde + decisão operador sobre executor mínimo (B) ou manter HOLD com follow-ups rastreáveis.
