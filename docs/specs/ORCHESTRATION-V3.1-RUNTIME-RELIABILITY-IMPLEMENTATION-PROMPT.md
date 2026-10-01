# IMPLEMENTATION PROMPT — V3.1 Persistent Adaptive Engineering & Runtime Reliability

Use the existing repository `Kusts/opencode-orchestration` and the existing V3.1 Kernel Hardening SPEC/PLAN as authority. Read the revised reliability SPEC/PLAN addenda (revision 2026-10-01) before changing code.

## Objective

Implement the remaining phases incrementally without rewriting completed V3.1 work.

Primary outcomes:

1. diagnose/prevent OpenCode V2 port/service collisions before an opaque hang;
2. migrate AI Memory assumptions from local `127.0.0.1:49374` to a bounded remote dependency;
3. prevent Planner and subagents from running indefinitely;
4. add canonical step/time/no-progress budgets (P23 record-only becomes enforcement in P26);
5. add watchdog + repeated-action + short-cycle detection with safe interruption;
6. preserve partial evidence and completed sibling results;
7. force a changed strategy after deterministic stalls;
8. keep existing Debugger/Architect escalation and EXHAUSTED semantics;
9. add bounded MCP calls/circuit breaker;
10. integrate Jev MCP as an opt-in advisory source only;
11. make Planner/subagent/capability behavior automatic in every session (persistent bootstrap);
12. decouple durable Task/Run/Seat identity from disposable runtime sessions, with reconciler + continuation envelope;
13. select execution mode (deterministic workflow / persistent specialist / one-shot) by task shape;
14. reuse valid evidence and validate differentially (L0–L3) instead of a universal pipeline;
15. keep V1 fully supported.

## Baseline — do not re-execute

Revision 2026-10-01. Phases 21–25 are the frozen baseline; do not rerun or rewrite them unless regression or new exact-runtime evidence invalidates them:

- P21 done — reliability baseline frozen.
- P22 partial-HOLD — deterministic V2 port/process preflight (REUSE and productive-wrapper HOLDs preserved).
- P23 done-record-only — canonical execution budgets recorded; they become enforceable in P26.
- P24 partial — V2 plugin/session-lifecycle migration with exact-runtime evidence (use as input to P26/P31/P32/P40).
- P25 done-shadow — RuntimeWatchdog shadow implementation; starting point for P26 enforcement.

## Mandatory constraints

- Do NOT create V4.
- Do NOT enable generic MCP routing.
- Do NOT introduce a new daemon/database.
- Do NOT make V2 the only runtime.
- Do NOT kill unknown PIDs.
- Do NOT commit secrets.
- Do NOT let Jev widen authority or declare DONE.
- Do NOT let Jev become an authority source (advisory only; Planner/kernel/verifier keep authority).
- Do NOT let AI Memory become live task-state authority (Task Kernel remains authoritative).
- Do NOT treat OpenCode chat/session history as durable task state.
- Do NOT auto-promote orchestration changes from telemetry (evolution requires eval + shadow + explicit promotion).
- Do NOT claim V2 runtime enforcement without exact-binary integration evidence.
- Do NOT use experimental V2 APIs as authoritative without exact-runtime proof.
- Do NOT retry a deterministic stall with the same strategy and no new evidence.
- Do NOT force Tester/Reviewer for every task (validation is risk/evidence driven, L0–L3).
- Do NOT let low-risk adaptive routing bypass high-risk policy triggers.
- Preserve CAS, DONE gate, grants, leases/worktrees and current security boundaries.

## Execution order

Implement in this order (new P26–P42 program, revision 2026-10-01):

1. Phase 21 — frozen (baseline; do not re-execute).
2. Phase 22 — frozen partial-HOLD (do not reopen except with evidence closing existing HOLDs).
3. Phase 23 — frozen record-only (budgets become enforceable in P26).
4. Phase 24 — frozen partial (input to P26/P31/P32/P40).
5. Phase 25 — frozen shadow (starting point for P26).
6. Phase 26 — watchdog enforcement, Loop Guard and safe interruption.
7. Phase 27 — strategy-aware recovery, typed waits and idempotent recovery.
8. Phase 28 — MCP safety envelope and circuit breaker.
9. Phase 29 — Jev advisory integration.
10. Phase 30 — AI Memory VPS productionization.
11. Phase 31 — persistent bootstrap and always-on orchestration.
12. Phase 32 — Task / Run / Seat / Session persistence model.
13. Phase 33 — Session Reconciler and Continuation Envelope.
14. Phase 34 — adaptive execution modes.
15. Phase 35 — evidence reuse and context economy.
16. Phase 36 — adaptive validation, deterministic review and security coverage.
17. Phase 37 — simplicity discipline and worker behavior refinement.
18. Phase 38 — Planner Adaptive Engineering Loop and budget-aware fan-out.
19. Phase 39 — Capability Doctor, primary/fallback routing and optional Jevgrep.
20. Phase 40 — OpenCode V2 native authority and execution capabilities.
21. Phase 41 — orchestration evolution and eval loop.
22. Phase 42 — full Windows V2 E2E, rollout and release closure.

Deliver in waves; update live program status after each wave:

- Wave A (reliability closure): P26, P27, P28, P29, P30.
- Wave B (persistent orchestration): P31, P32, P33, P34.
- Wave C (efficiency and behavior): P35, P36, P37, P38.
- Wave D (capability/runtime hardening): P39, P40.
- Wave E (learning and closure): P41, P42.

Do not attempt P26–P42 as one giant implementation.

After every phase:

- run targeted tests;
- run relevant V3.1 regression suites;
- have Reviewer inspect findings;
- involve Security Reviewer for process termination, permissions, MCP, secrets, authority, persistence and capability changes;
- do not continue past an unresolved high/critical security finding.

If two implementation attempts on the same defect fail, stop repeating the same fix and route to Debugger with the accumulated evidence.

When an exact V2 contract is uncertain, verify upstream/current runtime behavior before implementing it. Do not encode assumptions from old beta documentation.

At the end, report:

- files changed;
- tests run and results;
- exact V1/V2 binaries tested;
- remaining HOLDs;
- rollout flags that are still OFF;
- known risks;
- whether Windows V2 stall/recovery/persistence/E2E passed.
