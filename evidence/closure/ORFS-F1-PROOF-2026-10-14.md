# ORFS F1 proof — Planner-driven cooperativo supervisionado

## Phase 1

- task id: f1p1
- lane: supervised-cooperative
- plan: [OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md](../../docs/plans/OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md)
- TASK_ID: ORFS-F1P1R-CODER
- scope: Phase 1 proof artifact only; no implementation change.

## Phase 2

- task id: f1p2
- tentativa: a2 (retry de a1; FAIL a1 preservado como histórico na linha retry)
- plan: [OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md](../../docs/plans/OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md)
- retry: a2 (após FAIL a1: link quebrado detectado pelo tester)

## Phase 3

- task id: f1p3
- chain: f1p1 DONE -> f1p2 DONE -> f1p3 (esta fase)
- fault-injection: declarado e recuperado em Phase 2 (a1 FAIL -> a2 PASS)
