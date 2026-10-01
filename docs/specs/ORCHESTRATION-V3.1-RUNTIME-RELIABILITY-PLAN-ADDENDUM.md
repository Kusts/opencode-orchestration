# IMPLEMENTATION PLAN ADDENDUM — V3.1 Runtime Reliability, Loop Recovery & Jev MCP

**Repository:** `Kusts/opencode-orchestration`  
**Baseline reviewed:** `master @ 8047c22ce4a8423c12a51b4b1b4ddc3e5755ab04`  
**Revision date:** 2026-09-30  
**Companion SPEC:** `ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md` + reliability addendum  
**Strategy:** continue from completed V3.1 phases; do not reopen completed phases without a regression finding.

## 1. Delivery strategy

Implement this as new phases after the existing V3.1 plan.

Do not rewrite the Task Kernel.

Use the existing:

- canonical runtime abstraction;
- CAS task records;
- attempt history;
- Debugger/Architect escalation;
- grants;
- deterministic verifier;
- kernel-authorized DONE;
- leases/worktrees;
- telemetry conventions;
- conservative feature flags.

Reliability work must first observe, then enforce.

Recommended order:

```text
reproduce + pin
      ↓
port/process preflight
      ↓
canonical budgets
      ↓
V2 plugin/session API revalidation
      ↓
watchdog shadow
      ↓
loop guard shadow
      ↓
worker enforcement
      ↓
kernel recovery strategy
      ↓
MCP safety/circuit breaker
      ↓
AI Memory remote
      ↓
Jev advisory integration
      ↓
Windows V2 E2E + rollout
```

---

## 2. Phase 21 — Freeze reliability baseline and reproduce

### Goal

Capture current failure modes before changing behavior.

### Tasks

1. Record current repository HEAD.
2. Record exact V1 and V2 runtime versions installed/tested.
3. Record exact V2 background service behavior on Windows.
4. Capture sanitized V2 service diagnostics:
   - configured/current service port;
   - service status;
   - relevant OpenCode log error;
   - listener ownership;
   - Windows excluded port ranges.
5. Verify whether local AI Memory is currently listening on `49374`.
6. Reproduce at least one controlled stalled worker case without burning excessive tokens:
   - fake tool that never resolves; or
   - test adapter with a blocked promise/process.
7. Reproduce repeated-action loop through a deterministic test harness rather than relying on a real LLM.
8. Add evidence record under:
   - `evidence/v3.1/runtime-reliability/`
9. Do not enable enforcement.

### Required tests

- baseline V3.1 suites still green;
- V1 smoke;
- V2 exact-pin smoke/status;
- watchdog test fixtures can simulate stall/repetition deterministically.

### Exit criteria

- failures are reproducible without live-model cost;
- port ownership evidence captured;
- exact runtime pins known.

### Suggested commit

`test: freeze V3.1 runtime reliability baseline`

---

## 3. Phase 22 — V2 port conflict and process preflight

### Goal

Prevent opaque V2 startup hangs caused by port/service conflicts.

### Tasks

1. Add `RuntimePortPreflight.ps1`.
2. Detect:
   - intended port;
   - active listener;
   - owning PID/process where possible;
   - Windows excluded port range;
   - expected OpenCode service health.
3. Add normalized outcomes:
   - `PORT_FREE`;
   - `PORT_OWNED_BY_EXPECTED_SERVICE`;
   - `PORT_OCCUPIED_OTHER_PROCESS`;
   - `PORT_WINDOWS_EXCLUDED`;
   - `PORT_STALE_OR_UNKNOWN`;
   - `SERVICE_UNHEALTHY`.
4. Integrate preflight into V2 profile wrapper/start path.
5. Never automatically terminate an unknown PID.
6. If runtime supports persistent service-port configuration:
   - select a verified available port from a configurable pool;
   - persist it per V2 profile;
   - re-check on every start.
7. Add package-owned stale-service cleanup only with ownership proof.
8. Emit actionable diagnostics before the runtime's opaque startup timeout.

### AI Memory migration subtask

1. Move AI Memory endpoint to user-owned remote configuration.
2. Remove requirement for local `127.0.0.1:49374`.
3. Add bounded remote health probe.
4. Confirm local 49374 is released after migration.
5. Do not commit AI Memory credentials.

### Required tests

- free port;
- occupied by AI Memory fixture;
- occupied by unrelated PID;
- Windows excluded range;
- healthy existing OpenCode service;
- stale package-owned service;
- remote AI Memory healthy/unreachable.

### Exit criteria

V2 no longer waits for an opaque service timeout when the cause is detectable locally.

### Suggested commit

`feat: add V2 service port and process preflight`

---

## 4. Phase 23 — Canonical execution budgets and native step limits

### Goal

Make every active orchestration attempt finite by contract.

### Tasks

1. Extend canonical task schema with `execution_budget`.
2. Add policy profiles:
   - `fast`;
   - `standard-read`;
   - `standard-write`;
   - `deep`;
   - `planner-turn`.
3. Add role → default budget mapping.
4. Ensure worker cannot widen its budget.
5. Update attempt record with:
   - start;
   - deadline;
   - last progress;
   - budget snapshot.
6. Revalidate exact V1 and V2 support for agent step limits.
7. Render native step limits only where exact-runtime smoke proves the field.
8. Add renderer parity tests.
9. Add budget override validation with upper bounds.
10. Keep feature flag in shadow first.

### Initial defaults

- fast: 16 steps / 10m / 3m no-progress;
- standard-read: 24 / 15m / 4m;
- standard-write: 32 / 20m / 5m;
- deep: 40 / 30m / 6m;
- planner active turn: 64 / 60m / 8m.

### Required tests

- valid/invalid budget;
- worker self-widen rejected;
- renderer output V1;
- renderer output V2;
- user input resets Planner turn budget, not the whole interactive session.

### Suggested commit

`feat: add canonical bounded execution budgets`

---

## 5. Phase 24 — Revalidate and repair V2 plugin/session lifecycle contract

### Goal

Build watchdog enforcement only on verified V2 APIs.

### Why this phase comes before watchdog

The current V2 plugin contains beta-era assumptions and fails open when a surface is unavailable.

A silent no-op lifecycle hook would make a watchdog look installed while not actually supervising sessions.

### Tasks

1. Re-check exact V2 pinned plugin API.
2. Verify the current V2 plugin entrypoint shape.
3. Verify event delivery for:
   - session created;
   - session updated/status;
   - session idle;
   - session error.
4. Verify tool before/after hooks.
5. Verify parent/child identity and parent ID availability.
6. Verify how the plugin can interrupt an active session:
   - direct V2 context session interrupt; or
   - approved SDK/session API.
7. Add feature detection with explicit telemetry.
8. Replace any obsolete event registration mechanism.
9. Ensure missing lifecycle capability produces `WATCHDOG_UNAVAILABLE`, not a false healthy status.
10. Keep fail-safe behavior: plugin failure must not widen authority.

### Required integration tests

On the exact pinned V2 binary:

- plugin loads;
- receives session events;
- receives tool events;
- identifies child session;
- interrupts a synthetic long-running child;
- cleanup settles.

### Suggested commit

`fix: revalidate V2 lifecycle hooks for runtime supervision`

---

## 6. Phase 25 — Watchdog shadow mode

### Goal

Observe hangs and deadlines before killing anything.

### Tasks

1. Add `RuntimeWatchdog`.
2. Register active execution:
   - task ID;
   - attempt;
   - session ID;
   - parent session;
   - role;
   - runtime/profile;
   - budget.
3. Track meaningful progress.
4. Emit:
   - `STALL_SUSPECTED`;
   - `BUDGET_NEAR_LIMIT`;
   - `NO_PROGRESS_SUSPECTED`;
   - `REPEATED_ACTION_SUSPECTED`.
5. In shadow mode:
   - do not interrupt;
   - record what WOULD have happened.
6. Sanitize all stored fingerprints/evidence.
7. Confirm telemetry overhead is bounded.

### Required tests

- active healthy worker never falsely marked stalled;
- synthetic non-returning worker gets shadow timeout;
- long but progressing worker does not hit no-progress;
- secrets not persisted.

### Exit criteria

Shadow data is trustworthy enough to set enforcement thresholds.

### Suggested commit

`feat: add shadow runtime watchdog`

---

## 7. Phase 26 — Loop Guard and hard worker interruption

### Goal

Stop genuinely stuck child executions.

### Tasks

1. Add canonical tool-action fingerprint.
2. Add repeated identical action detector:
   - soft = 3;
   - hard = 5.
3. Add short-cycle detector:
   - cycle length 2–4;
   - hard after 3 repeated cycles without progress.
4. Allow declared bounded iterators to avoid false positives.
5. Add hard wall-clock deadline.
6. Add no-progress deadline.
7. On hard stall:
   - capture partial evidence;
   - request child interrupt;
   - wait bounded time for settlement;
   - record result.
8. Do not release lease/worktree before ownership-safe settlement/cleanup.
9. If interrupt fails:
   - emit `WATCHDOG_INTERRUPT_FAILED`;
   - mark runtime blocker;
   - do not silently spawn another writer in the same scope.

### Required tests

- identical action loop;
- A-B-A-B loop;
- legitimate bounded iteration;
- no-progress stall;
- hard timeout;
- interrupt success;
- interrupt failure;
- lease remains safe during failed cleanup.

### Suggested commit

`feat: enforce bounded worker execution and loop guard`

---

## 8. Phase 27 — Planner supervision

### Goal

Prevent Planner turns from running indefinitely while preserving normal interactive use.

### Tasks

1. Distinguish:
   - open interactive session;
   - active Planner orchestration turn.
2. Apply `planner-turn` budget only while work is active.
3. Track child sessions spawned by Planner.
4. Preserve completed child results.
5. If one child stalls:
   - interrupt only that child first;
   - do not discard successful sibling results.
6. If Planner itself makes no progress:
   - capture current orchestration state;
   - interrupt active turn where supported;
   - recover via Task Kernel.
7. Do not kill the TUI merely because the session remains open.
8. New user message begins a new Planner turn budget.

### Required tests

- long idle TUI does not timeout;
- active Planner tool loop does;
- stuck one-of-N child does not lose N-1 results;
- recovered Planner receives preserved evidence.

### Suggested commit

`feat: add bounded Planner turn supervision`

---

## 9. Phase 28 — Kernel recovery strategy contract

### Goal

Turn a timeout/loop interruption into a deliberate new strategy rather than replaying the same failure.

### Tasks

1. Extend attempts with:
   - `strategy_id`;
   - `strategy_fingerprint`;
   - `hypothesis`;
   - `new_evidence_refs`;
   - `recovery_from`;
   - `changed_from_previous`.
2. Add canonical failure classes.
3. Generate Recovery Context.
4. Reject deterministic-stall retry when:
   - same strategy;
   - no new evidence;
   - no new hypothesis/decomposition.
5. First stall:
   - Planner must change/narrow strategy.
6. Second stall:
   - Debugger required.
7. Architectural uncertainty:
   - Architect.
8. Third attempt:
   - only with novelty;
   - otherwise `EXHAUSTED`.
9. Preserve existing attempt-budget semantics.

### Required tests

- same strategy rejected;
- new strategy allowed;
- transient network retry allowed within infra budget;
- Debugger gate after second failure;
- invalid third attempt → `EXHAUSTED`.

### Suggested commit

`feat: add strategy-aware stall recovery`

---

## 10. Phase 29 — MCP safety envelope and circuit breaker

### Goal

Prevent MCP failures from becoming orchestration hangs.

### Tasks

1. Add canonical per-MCP request policy.
2. Support:
   - catalog/connect timeout;
   - execution timeout;
   - consecutive failures;
   - circuit-open cooldown.
3. Initial execution targets:
   - Jev advisory 30s;
   - AI Memory 60s;
   - general remote MCP 120s.
4. If exact runtime cannot enforce call execution timeout, enforce it in plugin/integration layer.
5. Add MCP circuit breaker:
   - 2 consecutive timeout/network failures in one orchestration turn → temporarily open.
6. Open circuit returns a structured unavailable result.
7. Never repeatedly hammer an unavailable MCP.
8. Keep generic `mcp_routing` disabled.

### Required tests

- MCP call timeout;
- two failures open circuit;
- cooldown behavior;
- healthy call closes/rearms state as designed;
- circuit breaker cannot widen permissions.

### Suggested commit

`feat: add bounded MCP execution and circuit breaker`

---

## 11. Phase 30 — Jev MCP integration

### Goal

Add Jev as an advisory judgment source without making it an authority.

### Preferred transport

Use the hosted remote Jev MCP first.

Reasons:

- no new local listener;
- avoids another local port-conflict source;
- simpler coexistence with V1/V2;
- secret remains in environment/credential store.

### Tasks

1. Add `jev_advisory` feature flag, default OFF.
2. Add a runtime-neutral Jev MCP profile/descriptor.
3. Supply key only from `JEV_API_KEY` or user-owned credential storage.
4. Validate tools dynamically during health/catalog probe.
5. Maintain an explicit allowed Jev tool set.
6. Configure/normalize 30-second advisory budget.
7. Add explicit invocation rules to Planner/selected advisory roles.
8. Suggested decision boundaries:
   - consequential tool-call guard;
   - bounded task routing;
   - bounded model routing within already-allowed models;
   - research evidence check;
   - completion evidence review.
9. Jev result enters Evidence Contract as advisory evidence.
10. Jev result can never:
    - grant permission;
    - widen scope;
    - bypass Security Reviewer;
    - write DONE.
11. `JEV_UNAVAILABLE` must not create a retry loop.
12. Do not enable generic MCP router.

### Required tests

- server healthy;
- bad/missing key;
- 30s timeout fixture;
- unavailable server;
- tool catalog drift;
- Jev says allow but kernel denies → kernel wins;
- Jev says complete but verifier fails → DONE denied;
- Jev unavailable → normal deterministic path remains safe.

### Suggested commit

`feat: add opt-in Jev advisory MCP`

---

## 12. Phase 31 — AI Memory remote productionization

### Goal

Finish AI Memory migration without coupling orchestration reliability to a local port.

### Tasks

1. Replace local endpoint assumption with user-owned remote endpoint.
2. Verify TLS/auth as applicable.
3. Add remote health check.
4. Apply 60-second retrieval budget.
5. Apply circuit breaker.
6. Define failure behavior:
   - retrieval unavailable → continue without memory when safe;
   - required memory dependency → structured blocker;
   - never infinite retry.
7. Validate no secret enters telemetry.
8. Validate no local process/listener is required.

### Required tests

- remote healthy;
- DNS failure;
- connection timeout;
- auth failure;
- server 5xx;
- circuit open;
- orchestration continues without optional memory.

### Suggested commit

`feat: harden remote AI Memory dependency`

---

## 13. Phase 32 — Windows V2 end-to-end reliability lane

### Goal

Prove the exact environment where the user is seeing the failures.

### Scenarios

1. V2 service port free.
2. V2 service port occupied.
3. V2 service port in Windows excluded range.
4. AI Memory remote.
5. Jev remote.
6. one normal worker completes;
7. one worker hangs;
8. one worker repeats identical tool call;
9. one worker enters short cycle;
10. one of multiple children hangs;
11. Planner itself stalls;
12. interrupt succeeds;
13. interrupt/cleanup fails;
14. V1 remains unaffected.

### Assertions

- no scenario waits indefinitely;
- all tests have their own external harness timeout;
- no orphan package-owned process after successful cleanup;
- no unknown PID killed;
- partial sibling results retained;
- Task Kernel remains authoritative.

### Suggested commit

`test: add Windows V2 bounded execution reliability lane`

---

## 14. Phase 33 — Rollout and release hardening

### Goal

Turn reliability features on in controlled order.

### Rollout

1. `port_preflight.enabled = true`
2. step budgets in tested renderers
3. watchdog shadow
4. loop guard shadow
5. worker watchdog enforcement
6. Planner-turn enforcement
7. MCP circuit breaker
8. AI Memory remote
9. Jev opt-in

### Before each enforcement step

- run V1 suite;
- run V2 exact-runtime lane;
- inspect false positives;
- Reviewer;
- Security Reviewer where permissions/process/MCP authority is involved.

### Documentation updates

Update:

- main V3.1 SPEC status;
- main V3.1 PLAN status;
- CHANGELOG;
- troubleshooting:
  - V2 service port collision;
  - Windows excluded ranges;
  - stuck child recovery;
  - watchdog diagnostics;
  - MCP circuit breaker;
  - Jev unavailable;
  - AI Memory remote unavailable.
- architecture docs;
- feature-flag docs.

### Release gate

Do not call this reliability work complete until the exact supported V2 Windows binary passes the stall/recovery lane.

### Suggested commit

`docs: close V3.1 runtime reliability hardening`

---

# 15. Implementation constraints for the coding agent

- Do not create V4.
- Do not reopen completed V3.1 phases unless a regression requires it.
- Do not replace the Task Kernel.
- Do not activate generic MCP routing.
- Do not add a daemon/database.
- Do not silently change user-owned MCP config.
- Do not commit credentials.
- Do not kill unknown processes.
- Do not release a writer lease before interruption/cleanup is ownership-safe.
- Do not retry a deterministic stall with the same strategy.
- Do not claim V2 support from unit tests only.
- V2 enforcement requires exact-binary integration evidence.
- Keep PowerShell 5.1 compatibility where current package scripts require it.
- Every new persistent task mutation requires CAS/staleness coverage.
- Every process-kill path requires ownership and failure-path tests.
- Every Jev decision remains advisory.
- Every timeout/circuit-breaker value should be centralized in policy/config, not scattered literals.

---

# 16. Final Definition of Done

The addendum implementation is done only when:

- V2 port collision is diagnosed before startup hang;
- AI Memory no longer requires local 49374;
- every active task attempt has a canonical budget;
- workers cannot run forever;
- Planner active turns cannot run forever;
- repeated tool loops are detected;
- short cycles are detected;
- partial evidence survives forced interruption;
- recovery requires strategy novelty;
- Debugger escalation still works;
- invalid third attempt becomes `EXHAUSTED`;
- MCP calls are bounded;
- repeated MCP outage is circuit-broken;
- Jev is integrated as opt-in advisory MCP;
- Jev cannot bypass authority boundaries;
- Windows V2 E2E reliability lane is green;
- V1 remains green;
- Reviewer approves;
- Security Reviewer has no unresolved high/critical finding.
