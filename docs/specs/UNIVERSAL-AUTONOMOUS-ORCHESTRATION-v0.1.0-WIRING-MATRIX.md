# WIRING MATRIX — Universal Autonomous Orchestration v0.1.0

**Repository:** `Kusts/opencode-orchestration`
**Revision date:** 2026-10-08
**Status:** REVISED-BY-PLANNER (fotografia auditável; evolui com as Fases 1–8 do CORRECTIVE-PLAN)
**Fontes:** CLOSURE-ADDENDUM §2, CORRECTIVE-PLAN §2.

Estágios: `IMPLEMENTED` < `WIRED` < `ACTIVE` < `RUNTIME-PROVEN`; `HOLD` =
decisão explícita. Nenhum número novo é alegado abaixo — só os já
registrados (Enforcement 421/421 isolada, Watchdog 134/134, kernel 75/75,
E2E manifest, lanes 2026-10-05/06).

| Componente | Arquivo(s) | Estágio | Evidência / Teste | Gap para runtime-proven |
|---|---|---|---|---|
| Preflight | `scripts/v3/lib/OrchestrationPreflight.ps1`, `scripts/v3/orchestration-preflight.ps1` | RUNTIME-PROVEN | CLI + DONE gate usados por policy/lanes; E2E manifest | nenhum (manter) |
| PlannerLoop | `scripts/v3/lib/OrchestrationPlannerLoop.ps1` | ACTIVE-parcial | suite PlannerLoop 36; reuse automático; único caller Jev P38-S2 advisory-only | planning-only, never dispatches — executor B (Fase 2) |
| DispatchPipeline | `scripts/v3/lib/OrchestrationDispatchPipeline.ps1` | ACTIVE record-only | suite 201/202; consome plan record com `spawned=false` | não faz spawn — dispatch real (Fase 2) |
| ObjectiveController | `scripts/v3/lib/OrchestrationObjectiveController.ps1` | ACTIVE-cálculo | suite 67; `next_move` puro | não loopea/não executa — wiring ao executor (Fase 4) |
| ObjectiveRunner.harness | `scripts/ci/ObjectiveRunner.harness.ps1` | TEST-HARNESS-NOT-PRODUCT | runner 57 asserts (S1-S5+S7-S8) | test-only por desenho; nunca confundir com produto |
| DecisionProvider | `scripts/v3/lib/OrchestrationDecisionProvider.ps1` | NÃO-CONECTADO | suite dedicada; seam `-JevProbe` | sem transporte real; decidir wiring vs JevAdvisory (Fase 4) |
| JevAdvisory | `scripts/v3/lib/OrchestrationJevAdvisory.ps1` | ADVISORY-ONLY | suite 159/159; P29-S2 transporte; P38-S2 caller wiring; flag `enabled:true shadow:false` | advisory-only por desenho; nunca roteia/concede/DONE |
| EvidenceStore | `scripts/v3/lib/OrchestrationEvidenceStore.ps1` | ACTIVE | provado em lanes; reuse no PlannerLoop | TTL condicional — `ttl` default (Fase 6, AR-10) |
| GoalPromotion | `scripts/v3/lib/OrchestrationGoalPromotion.ps1` | SCORE-ONLY | suite 16; threshold 3 | só pontua — wiring (Fase 5) |
| GoalKernel | `scripts/v3/lib/OrchestrationGoalKernel.ps1` | ACTIVE | suite 87; CAS+lock; store `cache/goal-store` | ciclos reais multi-sessão (Fase 2/3) |
| GoalProgress | `scripts/v3/lib/OrchestrationGoalProgress.ps1` | SCORE-ONLY | suite 22; stagnation/strategy-change | loop-guard no executor (Fase 5) |
| GoalCheckpoint | `scripts/v3/lib/OrchestrationGoalCheckpoint.ps1` | IMPLEMENTED | suite 36; store atômico | nunca tocou sessões reais — resume real (Fases 3/6) |
| SessionReconciler | `scripts/v3/lib/OrchestrationSessionReconciler.ps1` | READ-ONLY | suite 156 asserts; contrato caller-declared `probed=false` | nunca proba/controla; V2 probing HOLD (Fase 3) |
| TaskKernel | `scripts/v3/lib/OrchestrationTaskKernel.ps1`, `scripts/v3/task-kernel.ps1` | RUNTIME-PROVEN | kernel 75/75; provado em lanes reais 2026-10-05/06 | nenhum (âncora do executor) |
| Delivery | `scripts/v3/lib/OrchestrationDelivery.ps1`, `source/registry/delivery-policy.json` | DECISÓRIO-ONLY | suite 60; elegibilidade + state machine | merge/checks com chamador externo (Fase 7) |
| `runtime_grant_enforcement` | `source/registry/capability-flags.json` (`v1:false v2:false`) | OFF-HOLD | fail-open `/shell` 2.0.23 observado; Phase 5 HOLD | prova exact-binary-live (AR-09; sem prazo neste plano) |
| Watchdog | `scripts/v3/lib/OrchestrationRuntimeWatchdog*.ps1` | ATIVO-com-HOLD-residual | Watchdog 134/134; Enforcement 421/421 isolada; ativo desde 2026-10-04 + Job backstop 2026-10-05 | janela gate→`TerminateJobObject`, preempção checagem→chamada, pré-attach só via kill CIM |
| AdapterContract (PR-1) | `scripts/v3/lib/OrchestrationRuntimeAdapterContract.ps1` | ACTIVE-lib | suite 148/148 PASS (2026-10-08); matriz 10 ops × V1/V2 sem VERIFIED | prova exact-binary-live por op × runtime (Fase 1/G1) |
| ObjectiveRuntime (PR-2) | `scripts/v3/lib/OrchestrationObjectiveRuntime.ps1` | ACTIVE-restrito / HOLD-produtivo | suite 175 PASS (2026-10-08); 5 rounds review + security | gate GoalKernel p/ produtivo (Fase 2/G2) |
| PromotionWiring (PR-3) | `scripts/v3/lib/OrchestrationGoalPromotionWiring.ps1` | ACTIVE | suite 29/29 PASS (2026-10-08) | wiring ao executor real (Fase 5/G5) |
| DecisionWiring (PR-4) | `scripts/v3/lib/OrchestrationDecisionWiring.ps1` | ACTIVE | suite 28/28 PASS (2026-10-08); sem rede/spawn/segredo próprios | autoridade consultiva única (Fase 4/G4) |
| ReuseWiring (PR-4) | `scripts/v3/lib/OrchestrationReuseWiring.ps1` | ACTIVE | suite 31/31 PASS (2026-10-08); ttl default por classe (AR-10 parcial) | resume real cross-session (Fases 3/6, G3/G6) |
| AutonomyWiring (PR-5) | `scripts/v3/lib/OrchestrationAutonomyWiring.ps1` | ACTIVE | suite 54/54 PASS (2026-10-08); sem rede/spawn/segredo próprios | executor real + ativações operator-owned (Fases 5–6/G5) |
| ObjectiveTelemetry (PR-6) | `scripts/v3/lib/OrchestrationObjectiveTelemetry.ps1` | TEST-HARNESS-SUPPORT | suporte ao E2E (sem suite própria; não é ACTIVE produtivo) | — |
| CorrectiveE2E (PR-6) | `scripts/v3/lib/OrchestrationCorrectiveE2E.tests.ps1` | TEST-HARNESS | 119 asserts PASS (2026-10-08), E2E-01..E2E-15 harness-level, gates G1–G8 | runtime-real V1/V2/dual/PS5.1/PS7 BLOCKED sem provider (Fase 7/G7) |
| GoalKernel ownership (PR-6b) | `scripts/v3/lib/OrchestrationGoalKernel.ps1`, `scripts/v3/lib/OrchestrationGoalKernelOwnership.tests.ps1` | ACTIVE / HOLD-produtivo | ownership autoritativo (CAS+geração+lease); 115 asserts novas + 103 existentes verdes; AUTHORITY_CHANGE com review+security | produtivo HOLD até ativação operator-owned com evidência (Fase 2/G2) |
| ProductiveActivation (PR-6b) | `scripts/v3/lib/OrchestrationProductiveActivation.ps1` | PRONTO E REVISADO / HOLD default | 133 asserts; bindings pré-efeito + live-only (K1/K2 fechados); review/security finais; opt-in `-Productive` | executor default HOLD; dispatch produtivo só sob opt-in explícito |
| Lane com provider 2026-10-08 | `evidence/v3.1/runtime-reliability/session-lane-2026-10-08/` (62.860B, 9 arq.) + `...-rerun1821/` (21.424B, 4 arq.) + `scripts/ci/session-real-lane-v2.ps1` (`-ModelKeyEnvName` opt-in auditado) | PARCIAL-runtime-real 4/7 | 16/17/19/20 pass-real; 18/21 blocked (model-turn rc=1 sistemático, não flake; kernel-side provado); 22 blocked (V1 install OK + `--help` timeout); probes 7 ambiguous + 1 unsupported (fail-open `/shell`) | pernas completed 18/21 + fresh-turn 22 (provider/model operator-owned) |
| Ativações 2026-10-08 | `source/registry/capability-flags.json` (intocado) | DECISÃO — nada a ligar | watchdog/jev já ON; enforcement OFF (fail-open observado — HOLD); routing OFF (doutrina) | — |
| Tag v0.1.1 | tag anotada → `301ab59` (merge PR #41) | PUBLICADO-PARTIAL | PR #41 MERGED 2026-10-08T17:10:50Z; mensagem da tag com veredito PARTIAL | — |
| CI merge | runs `37807694673` (PR success pós-rerun, flake timing) + `37814554039` (master 5/5) — info Planner | VERDE | gate G0 fechado | — |

Adendo PR-7 (2026-10-08): linhas PR-1–PR-6b acima; estágios `ACTIVE-lib`,
`ACTIVE-restrito/HOLD-produtivo` e `TEST-HARNESS` são desenho/honestidade,
não promoção a runtime-proven. `runtime_grant_enforcement` segue OFF-HOLD,
watchdog segue ATIVO-com-HOLD-residual, flags intocadas (`git diff` no
registry vazio; `skill_routing`/`mcp_routing`/`adaptive_ranking` OFF por
doutrina). Commit `ea8d768` (29 arquivos +12524/-24) + push OK;
PR #41 OPEN com head em `ea8d768`; CI run `37807439121` IN_PROGRESS
(anterior `37775340487` success em `dea2b40`). Distribution GO 21/21
(20 PASS + 1 SKIP live-hook-v2 ambiental); full-V3 72 + 3 DE22307F +
6 SKIP. Runtime-real BLOCKED sem provider (`JEV_API_KEY`/`JEV_BASE_URL`,
`OPENCODE_API_KEY`, `ANTHROPIC_API_KEY` UNSET). Veredito: PARTIAL CLOSURE.

Nota: caminhos de arquivo acima seguem o layout `scripts/v3/lib/` vigente;
se um componente ainda não existir como arquivo próprio, o estágio vale para
a capacidade descrita no addendum, e a Fase correspondente o materializa.

Adendo final (2026-10-08, pós-merge): linhas lane/ativação/tag/CI-merge
acima registram o estado final real — PARTIAL CLOSURE (runtime-real parcial
4/7 + enforcement HOLD + routing OFF); sem alegar FINAL. Detalhe em
CORRECTIVE-PLAN §8 "Estado final".
