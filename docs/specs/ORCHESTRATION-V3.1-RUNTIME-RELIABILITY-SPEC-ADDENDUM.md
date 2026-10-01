# SPEC ADDENDUM — Orchestration V3.1 Runtime Reliability, Loop Recovery & Jev MCP

**Repository:** `Kusts/opencode-orchestration`  
**Current baseline reviewed:** `master @ 8047c22ce4a8423c12a51b4b1b4ddc3e5755ab04`  
**Revision date:** 2026-09-30  
**Companion:** `ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md`  
**Change class:** `RUNTIME_RELIABILITY` + `BOUNDED_EXECUTION` + `MCP_INTEGRATION`  
**Suggested release:** continue V3.1 / 1.1.x. **Do not create V4.**

## 0. Purpose

This addendum extends the already-implemented V3.1 Kernel Hardening work without redesigning or replacing the existing orchestration.

The existing Task Kernel, CAS, grants, Evidence Contract, deterministic verifier, kernel-authorized DONE, leases, worktrees, runtime adapters and current retry/escalation semantics remain authoritative.

This revision addresses three operational gaps observed after the V3.1 implementation:

1. OpenCode V2 runtime/service port collisions, including a collision with the local AI Memory service;
2. Planner and subagent executions that may remain active indefinitely without consuming the existing retry budget;
3. adding Jev MCP as a bounded, advisory judgment capability without enabling unrestricted generic MCP routing.

The core rule is:

> **No orchestration execution may remain indefinitely active without bounded steps, progress supervision, a deadline, or an explicit recovery/termination path.**

---

## 1. Findings that change the design

### 1.1 The current retry budget is necessary but not sufficient

The current kernel already enforces:

- first failed attempt → reassess/narrow;
- second failed attempt → Debugger;
- third attempt requires new evidence/hypothesis/strategy;
- otherwise → `EXHAUSTED`.

However, this logic only activates **after an attempt returns a failure**.

A worker or Planner that never returns:

- never increments the meaningful failure sequence;
- never reaches Debugger escalation;
- never reaches `EXHAUSTED`;
- can hold the parent session indefinitely.

Therefore V3.1 needs an execution supervision layer **before** retry/escalation.

### 1.2 OpenCode itself cannot be the only protection

Upstream OpenCode reports show multiple variants of indefinite execution:

- child/subagent session stalled while the parent waits;
- repeated identical tool calls for long periods;
- provider stream waiting indefinitely after a tool call;
- permission asks inside non-interactive subagents;
- long-lived V2 server/process instability.

The orchestration package MUST therefore treat native runtime protections as one layer, not the entire reliability model.

### 1.3 Current V2 port conflict has a concrete probable cause

The user's local AI Memory has been using `127.0.0.1:49374`.

Recent OpenCode V2 Windows reports show the managed background service also trying to bind to `127.0.0.1:49374`.

Moving AI Memory to a VPS should remove this specific local listener conflict, but it does not eliminate:

- Windows excluded/reserved port ranges;
- another process occupying the chosen V2 service port;
- stale/zombie listeners;
- future local MCPs introducing another listener conflict.

Therefore runtime startup needs deterministic port ownership diagnostics.

### 1.4 V2 runtime contracts are still moving

The current V3.1 V2 adapter/plugin must be revalidated against the exact pinned V2 runtime before reliability enforcement is enabled.

The implementation MUST NOT assume that:

- plugin event APIs from an older beta are still current;
- public legacy documentation matches V2;
- V2 config schema documentation and runtime behavior are perfectly synchronized.

Every V2 enforcement feature added by this addendum requires an exact-runtime integration test.

---

## 2. Non-goals

This addendum MUST NOT:

- remove OpenCode V1;
- make V2 the only supported runtime;
- introduce deep subagents;
- introduce a new daemon or persistent orchestration database;
- enable generic `mcp_routing` globally;
- let Jev authorize actions;
- let Jev override permissions, grants, Reviewer, Security Reviewer or kernel DONE;
- automatically kill an unknown process merely because it owns a port;
- rewrite already-completed V3.1 phases;
- replace the existing retry/escalation contract with unrestricted autonomous retries.

---

# PART A — BOUNDED EXECUTION

## 3. Execution budget contract

Every active orchestration attempt MUST have a normalized budget.

Suggested task record extension:

```json
{
  "execution_budget": {
    "profile": "standard",
    "step_budget": 32,
    "wall_clock_seconds": 1200,
    "no_progress_seconds": 300,
    "repeated_action_soft_limit": 3,
    "repeated_action_hard_limit": 5,
    "cycle_repeat_limit": 3,
    "provider_retry_limit": 2
  },
  "execution_runtime": {
    "session_id": null,
    "started_at": null,
    "deadline_at": null,
    "last_progress_at": null,
    "last_progress_revision": 0
  }
}
```

Budgets are policy, not worker-controlled metadata.

A worker MUST NOT widen its own budget.

### 3.1 Initial budget profiles

These are initial measurable defaults and SHOULD be tuned from telemetry after real usage.

| Profile | Typical use | Step budget | Wall clock | No-progress |
|---|---|---:|---:|---:|
| `fast` | trivial/discovery helper | 16 | 10 min | 3 min |
| `standard-read` | Explorer, Researcher, Tester, Reviewer, Docs | 24 | 15 min | 4 min |
| `standard-write` | Coder and domain implementation workers | 32 | 20 min | 5 min |
| `deep` | Debugger, Architect, complex implementation | 40 | 30 min | 6 min |
| `planner-turn` | Planner active orchestration turn | 64 | 60 min | 8 min |

Rules:

- New user input begins a new Planner turn/budget.
- A Planner interactive session has no lifetime timeout merely because the TUI remains open.
- An **active Planner orchestration turn** is bounded.
- A task MAY request a larger profile, but only through Planner/kernel policy.
- Maximum automatic wall-clock extension: 45 minutes for workers and 90 minutes for a Planner turn.
- Larger execution requires explicit user/human approval or decomposition.

### 3.2 Native runtime step limits

Where the runtime provides a native maximum-step field, the renderer SHOULD set it from the canonical budget.

The canonical field remains `execution_budget.step_budget`; runtime-specific configuration is an adapter concern.

For V1 and V2, support MUST be validated on the exact pinned versions before claiming parity.

Native step limits are a **first line of defense**, not a replacement for the watchdog.

---

## 4. Runtime Watchdog

Add a canonical watchdog that supervises active task attempts.

Suggested module:

`RuntimeWatchdog`

Responsibilities:

1. register Planner/worker execution start;
2. bind runtime session ID to task ID;
3. observe progress signals;
4. enforce wall-clock deadline;
5. enforce no-progress deadline;
6. detect repeated-action/cycle stalls;
7. request runtime interrupt/abort when safe and supported;
8. persist structured termination evidence;
9. hand control back to the Task Kernel;
10. never self-authorize task completion.

The watchdog SHOULD live inside the existing orchestration plugin/runtime integration rather than becoming a new external daemon.

---

## 5. Progress model

A task is not considered to be making progress merely because the process is alive.

Meaningful progress includes one or more of:

- new tool call with materially different canonical arguments;
- new tool result;
- new evidence artifact;
- task state revision;
- changed Git diff;
- changed test/validation result;
- new hypothesis;
- new strategy identifier;
- new reviewed finding/resolution;
- explicit runtime status transition.

The following alone do NOT reset the meaningful-progress timer:

- identical repeated tool call;
- identical tool result;
- repeating the same reasoning cycle;
- heartbeat with no state/evidence change;
- retrying the same provider failure without new strategy.

---

## 6. Loop Guard

### 6.1 Canonical action fingerprint

For each tool action, compute a sanitized fingerprint from:

- tool name;
- normalized arguments;
- relevant target path/resource;
- normalized result hash/class when available.

Secrets MUST be redacted before persistence.

### 6.2 Repeated identical action

Initial policy:

- same action fingerprint 3 times without meaningful progress → `STALL_SUSPECTED`;
- same action fingerprint 5 times without meaningful progress → hard stall → interrupt attempt.

Legitimate loops MAY opt into a declared bounded iterator contract, but that contract must include:

- explicit item set/range;
- maximum iterations;
- progress marker.

### 6.3 Short-cycle detection

Detect repeated cycles of 2–4 action fingerprints.

If the same cycle repeats 3 times with no evidence/state delta:

- classify `REPEATED_CYCLE`;
- interrupt the attempt;
- do not silently replay the same strategy.

### 6.4 Runtime-native doom-loop handling

If a runtime offers its own doom-loop/recovery protection, keep it enabled where compatible.

The package MUST NOT treat runtime-native doom-loop detection as sufficient for:

- wall-clock stalls;
- provider stream stalls;
- blocked permission prompts;
- child sessions that stop emitting actions.

---

## 7. Stall taxonomy

Canonical termination/failure classes:

- `HARD_TIMEOUT`
- `NO_PROGRESS`
- `REPEATED_ACTION`
- `REPEATED_CYCLE`
- `PROVIDER_STALL`
- `MCP_TIMEOUT`
- `PERMISSION_DEADLOCK`
- `RUNTIME_UNRESPONSIVE`
- `USER_CANCELLED`

These SHOULD be attempt-result classifications, not new top-level task states.

The canonical task state machine remains unchanged whenever possible.

Recommended telemetry events:

- `STALL_SUSPECTED`
- `WATCHDOG_INTERRUPT_REQUESTED`
- `WATCHDOG_INTERRUPTED`
- `WATCHDOG_INTERRUPT_FAILED`
- `PARTIAL_EVIDENCE_CAPTURED`
- `RECOVERY_PLANNED`
- `STRATEGY_CHANGED`
- `STRATEGY_REJECTED_DUPLICATE`
- `BUDGET_EXCEEDED`

---

# PART B — RECOVERY INSTEAD OF BLIND RETRY

## 8. Recovery Context

After a watchdog interruption, the next attempt MUST receive a bounded Recovery Context.

Example:

```json
{
  "recovery": {
    "failure_class": "REPEATED_ACTION",
    "previous_attempt": 1,
    "previous_strategy_id": "search-by-grep-v1",
    "previous_strategy_fingerprint": "sha256:...",
    "actions_already_tried": [],
    "last_meaningful_evidence": [],
    "partial_artifacts": [],
    "forbidden_repetition": [
      "Do not repeat the same tool+arguments loop"
    ],
    "required_change": "new evidence, hypothesis, decomposition or tool path"
  }
}
```

The next worker MUST know what failed.

Do not solve a stalled attempt by simply resending the original prompt.

---

## 9. Strategy identity

Extend attempt history with:

- `strategy_id`;
- `strategy_fingerprint`;
- `hypothesis`;
- `new_evidence_refs`;
- `recovery_from`;
- `changed_from_previous`.

The Task Kernel MUST reject a retry when:

- the previous attempt ended in a deterministic stall; and
- the proposed strategy fingerprint is materially unchanged; and
- there is no new evidence explaining why the same strategy should now succeed.

Transient infrastructure errors MAY retry the same logical strategy within the provider/infrastructure retry budget.

---

## 10. Recovery ladder

### Attempt 1 fails/stalls

Planner MUST:

- classify failure;
- preserve partial evidence;
- narrow scope or change strategy;
- produce a new `strategy_id`.

### Attempt 2 fails/stalls

Debugger becomes mandatory.

Debugger MUST:

- review both failure traces;
- identify likely root cause;
- propose a materially different strategy;
- state what evidence makes the new strategy different.

### Attempt 3

Allowed only when there is:

- new evidence; or
- new hypothesis; or
- new decomposition; or
- different tool/runtime path.

Otherwise transition to `EXHAUSTED`.

This preserves the current V3.1 retry semantics while making them applicable to previously infinite attempts.

---

# PART C — PLANNER AND SUBAGENT SUPERVISION

## 11. Planner supervision

The Planner needs stronger protection without making interactive sessions unusable.

Rules:

- the TUI/session itself may remain open indefinitely;
- an active orchestration turn is bounded;
- native step budget SHOULD be set where supported;
- a Planner no-progress condition is based on orchestration progress, not UI lifetime;
- if the Planner is stalled, capture current child state before interrupting;
- completed child results MUST be retained even if another child stalls;
- after recovery, Planner resumes from preserved evidence instead of redispatching all completed work.

---

## 12. Subagent supervision

Every child execution SHOULD have:

- parent task ID;
- child session ID;
- start timestamp;
- deadline;
- progress timestamp;
- step budget;
- current strategy;
- interruption capability status.

If a child becomes stuck:

1. capture partial evidence;
2. request child interrupt/abort;
3. confirm settlement if runtime supports it;
4. mark attempt with a canonical failure class;
5. release owned lease/worktree only after settlement/ownership verification;
6. start recovery through the kernel.

Parent execution MUST NOT wait forever for a child.

---

## 13. Non-interactive permission policy

A hidden/synchronous subagent MUST NOT enter an unresolvable permission prompt.

Before dispatch:

- compute effective grants/permissions;
- if an action would require interactive approval and no human channel exists:
  - fail/return a structured blocker; or
  - move approval to the Planner before child execution.

Do not leave a worker waiting for a permission prompt that the user cannot see.

---

# PART D — OPENCode V2 PORT AND PROCESS HARDENING

## 14. Port preflight

Before starting/using the V2 managed service on Windows, perform an explicit preflight.

Suggested module:

`RuntimePortPreflight.ps1`

Checks:

1. intended service port;
2. existing TCP listener and owning PID;
3. owning process identity where available;
4. Windows excluded/reserved TCP ranges;
5. expected OpenCode service health;
6. stale package-owned service evidence;
7. profile/runtime ownership.

Diagnostic output MUST distinguish:

- `PORT_FREE`
- `PORT_OWNED_BY_EXPECTED_SERVICE`
- `PORT_OCCUPIED_OTHER_PROCESS`
- `PORT_WINDOWS_EXCLUDED`
- `PORT_STALE_OR_UNKNOWN`
- `SERVICE_UNHEALTHY`

### 14.1 Safety rules

- Never kill an unknown PID automatically.
- Reuse an existing service only after health + identity/ownership verification.
- If a package-owned service is stale, cleanup requires ownership proof.
- Prefer an explicitly selected, persisted, verified port rather than relying on an accidental collision-prone default.
- If the runtime supports a safe `port 0`/auto allocation contract, it MAY be used only when the chosen port can be discovered and persisted reliably.

### 14.2 Current AI Memory migration

AI Memory is being moved to a VPS.

Expected result:

- local listener `127.0.0.1:49374` disappears;
- the specific AI Memory ↔ OpenCode V2 collision should disappear if no other process/reservation owns that port.

The package MUST still validate the actual port before V2 service startup.

---

## 15. Process cleanup

Windows tests MUST verify:

- interrupting a child does not leave a package-owned child process running indefinitely;
- stopping/restarting the V2 profile does not leave an owned listener incorrectly treated as healthy;
- cleanup never terminates an unrelated process;
- process-tree cleanup is bounded;
- failed cleanup is surfaced as a blocker rather than hidden.

CPU/RSS telemetry MAY be captured, but automatic memory-based killing is not required for the first reliability release.

---

# PART E — MCP SAFETY

## 16. MCP request budgets

No MCP call may have an unbounded orchestration wait.

Canonical policy SHOULD support:

- connection/catalog timeout;
- execution timeout;
- consecutive failure threshold;
- temporary circuit-open cooldown;
- per-server override.

Initial orchestration defaults:

| MCP class | Suggested execution budget |
|---|---:|
| fast advisory | 30 s |
| memory/retrieval | 60 s |
| general remote MCP | 120 s |
| explicitly long-running MCP | task contract required |

If the exact OpenCode runtime exposes only startup/catalog timeout and not call-execution timeout, the orchestration/plugin layer MUST provide the execution bound.

---

## 17. MCP circuit breaker

For each MCP server:

- 1 transient failure → return structured error;
- 2 consecutive timeout/network failures in one orchestration turn → open circuit temporarily;
- while open, do not repeatedly call the same unavailable MCP;
- record `MCP_CIRCUIT_OPEN`;
- fallback behavior depends on capability criticality.

An unavailable advisory MCP MUST NOT trap Planner/subagents in retries.

---

# PART F — AI MEMORY ON VPS

## 18. Remote AI Memory contract

AI Memory SHOULD be treated as a remote dependency after migration.

Requirements:

- endpoint supplied from user-owned config/env;
- no secret or token committed to repository;
- startup health check is bounded;
- retrieval calls use `memory/retrieval` budget;
- connectivity failure returns `MEMORY_UNAVAILABLE`;
- memory outage does not block unrelated implementation work;
- writes, if supported, follow existing trust/side-effect policy;
- no local fixed listener is required on the developer machine.

The existing memory semantics remain unchanged.

---

# PART G — JEV MCP

## 19. Integration model

Add an MCP server identity:

`jev`

Preferred first integration: the hosted remote Jev MCP endpoint, because:

- it avoids adding another local listener/port;
- it matches the current effort to reduce local service conflicts;
- Jev is naturally an advisory remote decision service.

Credentials MUST be supplied from a local environment/credential store such as `JEV_API_KEY`.

Never commit the key.

---

## 20. Jev authority boundary

Jev is a **consultative judgment service**.

Jev MAY help with:

- guarding a consequential tool-call proposal;
- choosing among bounded task-routing alternatives;
- choosing among models already permitted by existing policy;
- checking whether supplied evidence supports a claim;
- reviewing whether completion evidence looks sufficient;
- bounded alternative decisions.

Jev MUST NOT:

- execute the underlying action;
- grant permissions;
- widen write scope;
- approve a deployment by itself;
- override Security Reviewer;
- override deterministic verification;
- override kernel DONE;
- create an otherwise-disallowed model;
- bypass attempt/retry policy.

Jev output is evidence/advice, not authority.

---

## 21. Jev failure behavior

Jev has an initial call timeout target of 30 seconds.

If Jev is unavailable:

- record `JEV_UNAVAILABLE`;
- do not loop retry indefinitely;
- use at most the MCP transient retry budget;
- continue with existing deterministic policy where safe;
- never interpret Jev unavailability as approval.

---

## 22. Jev routing

Do **not** enable generic `mcp_routing.enabled` solely to add Jev.

Initial implementation SHOULD be explicit and bounded:

- Jev integration flag;
- explicit decision boundaries;
- explicit agents/roles permitted to invoke Jev;
- explicit tool allowlist discovered/validated at startup.

Suggested default callers:

- Planner;
- Engineering Advisor;
- Skeptic;
- Reviewer;
- Security Reviewer for advisory checks only;
- Debugger when comparing bounded hypotheses.

Implementation workers MAY use Jev only when the dispatch contract requests a Jev decision boundary.

---

## 23. Jev completion review

`jev_review_completion` (or the equivalent discovered tool) MAY be called before the kernel completion gate as an additional signal.

It never replaces:

1. deterministic verifier;
2. Reviewer approval;
3. Security Reviewer when triggered;
4. kernel `Complete-OrchestrationTask`.

If Jev says “not complete”, Planner/Reviewer MAY investigate the identified gap.

If Jev says “complete”, the normal DONE gate still runs unchanged.

---

# PART H — V2 PLUGIN/API REVALIDATION

## 24. Exact-runtime plugin contract

Before implementing watchdog enforcement, revalidate the plugin against the exact supported V2 pin.

At minimum prove:

- plugin loads;
- session lifecycle can be observed;
- child vs parent identity can be derived reliably;
- `tool.execute.before`/after equivalent is available;
- runtime session interruption is available to the plugin or through an approved SDK/API path;
- cleanup callback works;
- event subscription shape is current.

Do not build reliability enforcement on a hook that silently no-ops.

If a previous beta hook shape differs from the exact stable V2 contract, update only the V2 adapter. Canonical orchestration semantics remain runtime-neutral.

---

# PART I — FLAGS AND ROLLOUT

## 25. New feature flags

Suggested additions:

```json
{
  "bounded_execution": {
    "enabled": false,
    "shadow": true
  },
  "watchdog": {
    "enabled": false,
    "shadow": true
  },
  "loop_guard": {
    "enabled": false,
    "shadow": true
  },
  "port_preflight": {
    "enabled": true
  },
  "mcp_safety": {
    "enabled": false,
    "shadow": true
  },
  "jev_advisory": {
    "enabled": false
  }
}
```

Rollout order:

1. telemetry/shadow;
2. port preflight;
3. native step budgets;
4. watchdog shadow;
5. loop guard shadow;
6. controlled enforcement on workers;
7. Planner enforcement;
8. MCP circuit breaker;
9. Jev opt-in.

---

# PART J — ACCEPTANCE CRITERIA

## 26. Reliability acceptance criteria

### RR-01
A worker that emits no meaningful progress past its configured threshold cannot remain running indefinitely.

### RR-02
A worker that repeats an identical tool+args action beyond the hard threshold is interrupted and classified.

### RR-03
A repeated short cycle is detected without depending on model self-awareness.

### RR-04
A stalled child cannot block the Planner indefinitely.

### RR-05
Completed sibling child results survive another child being interrupted.

### RR-06
Watchdog interruption records partial evidence and failure class.

### RR-07
A deterministic-stall retry with the same strategy fingerprint and no new evidence is rejected.

### RR-08
Second failed/stalled attempt requires Debugger, preserving current V3.1 semantics.

### RR-09
Invalid third attempt transitions to `EXHAUSTED`.

### RR-10
Planner interactive session is not killed merely for being open; only active orchestration turns are bounded.

### RR-11
Port preflight identifies a busy/reserved V2 service port before opaque startup timeout.

### RR-12
Unknown port-owning processes are never automatically killed.

### RR-13
Remote AI Memory outage returns a bounded unavailable result and does not cause infinite orchestration retry.

### RR-14
Jev outage returns bounded `JEV_UNAVAILABLE`.

### RR-15
Jev cannot change permissions, grants, write scopes or DONE status.

### RR-16
Generic MCP routing remains disabled unless separately approved.

### RR-17
V1 remains green.

### RR-18
V2 exact pinned runtime passes real-runtime watchdog/interrupt tests.

### RR-19
Windows process cleanup tests prove no package-owned runaway child remains after watchdog interruption, or surface an explicit cleanup blocker.

### RR-20
All existing V3.1 Kernel/DONE/lease/worktree/security tests remain green.

---

# PART K — DEFINITION OF DONE FOR THIS ADDENDUM

This reliability addendum is complete only when:

1. exact current V1/V2 runtime pins are recorded;
2. the V2 port conflict preflight is implemented and tested on Windows;
3. AI Memory remote configuration is supported without a required local listener;
4. canonical execution budgets exist;
5. native runtime step limits are rendered where proven;
6. watchdog shadow telemetry works;
7. worker hard timeout/no-progress interruption works;
8. repeated-action and short-cycle detection works;
9. partial evidence survives interruption;
10. recovery requires a changed strategy after deterministic stalls;
11. current Debugger/Architect escalation rules remain intact;
12. MCP calls are bounded/circuit-broken;
13. Jev is integrated as an opt-in advisory MCP;
14. Jev cannot bypass any authority boundary;
15. no generic MCP auto-routing is accidentally activated;
16. exact-runtime V2 tests demonstrate the actual plugin/session interrupt contract;
17. Reviewer approves;
18. Security Reviewer has no unresolved high/critical finding;
19. V1 regression suite remains green;
20. V2 Windows end-to-end stall tests remain green.
