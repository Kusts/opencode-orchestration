# IMPLEMENTATION PROMPT — V3.1 Runtime Reliability + Jev MCP

Use the existing repository `Kusts/opencode-orchestration` and the existing V3.1 Kernel Hardening SPEC/PLAN as authority. Read the new reliability SPEC/PLAN addenda before changing code.

## Objective

Implement the new phases incrementally without rewriting completed V3.1 work.

Primary outcomes:

1. diagnose/prevent OpenCode V2 port/service collisions before an opaque hang;
2. migrate AI Memory assumptions from local `127.0.0.1:49374` to a bounded remote dependency;
3. prevent Planner and subagents from running indefinitely;
4. add canonical step/time/no-progress budgets;
5. add watchdog + repeated-action + short-cycle detection;
6. interrupt stalled child execution safely;
7. preserve partial evidence and completed sibling results;
8. force a changed strategy after deterministic stalls;
9. keep existing Debugger/Architect escalation and EXHAUSTED semantics;
10. add bounded MCP calls/circuit breaker;
11. integrate Jev MCP as an opt-in advisory source only;
12. keep V1 fully supported.

## Mandatory constraints

- Do NOT create V4.
- Do NOT enable generic MCP routing.
- Do NOT introduce a new daemon/database.
- Do NOT make V2 the only runtime.
- Do NOT kill unknown PIDs.
- Do NOT commit secrets.
- Do NOT let Jev widen authority or declare DONE.
- Do NOT claim V2 runtime enforcement without exact-binary integration evidence.
- Do NOT retry a deterministic stall with the same strategy and no new evidence.
- Preserve CAS, DONE gate, grants, leases/worktrees and current security boundaries.

## Execution order

Implement in this order:

1. Phase 21 — freeze/reproduce reliability baseline.
2. Phase 22 — V2 port/process preflight + AI Memory remote preconditions.
3. Phase 23 — canonical execution budgets + native step limits where proven.
4. Phase 24 — exact V2 plugin/session lifecycle revalidation.
5. Phase 25 — watchdog shadow.
6. Phase 26 — loop guard + hard worker interruption.
7. Phase 27 — Planner active-turn supervision.
8. Phase 28 — strategy-aware kernel recovery.
9. Phase 29 — MCP safety + circuit breaker.
10. Phase 30 — Jev advisory MCP.
11. Phase 31 — AI Memory remote productionization.
12. Phase 32 — Windows V2 E2E reliability lane.
13. Phase 33 — controlled rollout/docs.

After every phase:

- run targeted tests;
- run relevant V3.1 regression suites;
- have Reviewer inspect findings;
- involve Security Reviewer for process termination, permissions, MCP, secrets and authority changes;
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
- whether Windows V2 stall/recovery E2E passed.
