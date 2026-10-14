# ADR — Supervised-Cooperative Lane (resolves B10 for functional proofs)

**Status:** active (operator decision, 2026-10-14).
**Scope:** functional program ORFS only. Does NOT amend
`PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md` and does NOT clear strict G1.

## Context

B10 (`OPERATIONAL-REFINEMENT-FUNCTIONAL-STABILIZATION-PLAN.md`): the native
PLAN forbids converting absence of proof into authorization via cooperative
protocol, while Wave 2 ran in `declared`-compat mode. APIs and run history
are not authorization.

## Decision

A **supervised-cooperative lane** is authorized for functional proofs when ALL
hold:

1. Single Planner session drives; `subagent` (V2) is the only native-tool
   invocation; no PowerShell callback substitutes the tool.
2. Existing libs only (`ObjectiveRuntime`, `NativeDispatch` PREPARE/CLAIM/SETTLE
   candidates, `AutonomousLoop`, `ObjectiveController`, `Goal/TaskKernel`,
   checkpoints, evidence refs); `objective-step.ps1` may assist, never decide.
3. Order `PREPARE → CLAIM pre-effect → native tool → SETTLE candidate →
   verifier → tester/reviewer (policy) → kernel DONE/CAS → ADVANCE`.
4. Worker returns only `candidate_pass|failed|blocked`; `verified_pass` only
   from the allowlisted verifier; approval only from reviewer; DONE only from
   the kernel after `Test-OrchestrationTaskCompletion`.
5. Provenance recorded as `declared` (data, not authority); strict tier never
   claimed; issues #69/#70 stay the strict blockers.
6. TEMP-owned stores; no user/global config touched; flags/grants/pins intact.

## Consequences

- F1 functional claims of kind `RUNTIME_REAL_PASS (cooperative-supervised)`
  are admissible per proof inside this lane; outside it, F1 stays HOLD.
- Any step violating 1–6 fails the proof (BLOCKED), never a silent pass.
- Reversible by operator at any time; strict G1 needs its own proofs.
