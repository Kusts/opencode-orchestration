# IMPLEMENTATION PLAN ADDENDUM — V3.1 Persistent Adaptive Engineering & Runtime Reliability

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** `master @ 4a996b29659967312d7ba3abbfbfb6003ce0bec1`
**Revision date:** 2026-10-01
**Companion SPEC:** `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md`
**Program:** continue V3.1. Do not create V4 solely for this work.

## 0. Plan reset rule

This plan preserves Phases 21–25 exactly as implemented/evidenced and **replaces the old unstarted Phase 26–33 sequence**.

Do not rerun/rewrite completed phases unless regression or new exact-runtime evidence invalidates them.

Current baseline:

- P21 done;
- P22 partial-HOLD;
- P23 done-record-only;
- P24 partial;
- P25 done-shadow;
- P26+ not started.

New remaining program: **P26–P42**.

---

# 1. Global execution rules for every remaining phase

For every phase:

1. inspect current `master` before editing;
2. preserve existing work and user-owned configuration;
3. use existing Task Kernel/CAS/grants/evidence/leases rather than creating parallel machinery;
4. target the smallest coherent implementation slice;
5. run focused tests first;
6. run relevant regression suites;
7. perform independent Reviewer review;
8. run Security Reviewer whenever authority, process control, credentials, MCP, permission or persistence boundaries change;
9. keep exact-runtime claims honest;
10. record HOLD/BLOCKED instead of guessing;
11. keep flags OFF/shadow until that phase's activation gate is met;
12. do not use generic MCP routing;
13. do not create a daemon/database;
14. keep PowerShell 5.1 compatibility where the project already requires it.

A phase is not “done” merely because code exists. It needs evidence + tests + review.

---

# 2. Phases 21–25 — frozen baseline

## P21 — Reliability baseline

Status: **DONE**

Keep current evidence.

## P22 — V2 port/process preflight

Status: **PARTIAL-HOLD**

Do not reopen except when remote AI Memory or exact V2 startup work supplies evidence that closes existing HOLDs.

## P23 — Canonical execution budgets

Status: **DONE-RECORD-ONLY**

Budgets become enforceable in P26.

## P24 — V2 plugin/session lifecycle

Status: **PARTIAL**

Use current exact-runtime findings as input to P26/P31/P32/P40.

## P25 — Runtime Watchdog shadow

Status: **DONE-SHADOW**

This is the starting point for P26.

---

# 3. Phase 26 — Watchdog enforcement, Loop Guard and safe interruption

## Goal

Turn P25 shadow observations into bounded worker/Planner execution without breaking V1 or leaving orphaned V2 work.

## Tasks

1. Implement real enforcement path behind existing/new conservative flags.
2. Bind watchdog instance to:
   - Task ID;
   - attempt number;
   - runtime;
   - session ID;
   - worker/Planner role;
   - execution budget.
3. Enforce:
   - hard deadline;
   - no-progress deadline;
   - repeated-action limit;
   - repeated short-cycle limit;
   - step budget where runtime/native support is proven.
4. Implement safe runtime interruption:
   - V2 exact API/path first;
   - V1 adapter-specific fallback only if proven.
5. Confirm settlement before releasing ownership/lease.
6. Preserve partial evidence and changed paths before cleanup.
7. Add process-tree ownership verification on Windows.
8. Do not kill unknown/unowned PIDs.
9. Add explicit `WATCHDOG_INTERRUPT_FAILED` blocker path.
10. Add external harness timeouts around all reliability tests.

## Required tests

- hung worker;
- no-progress worker;
- repeated identical action;
- A-B cycle repeated three times;
- legitimate bounded iterator not falsely killed;
- Planner turn timeout without killing idle TUI lifetime;
- successful interrupt;
- failed interrupt;
- lease not released before safe settlement;
- sibling completed result retained;
- V1 regressions.

## Stop gate

Do not enable worker enforcement until exact runtime interrupt is proven for the target runtime.

---

# 4. Phase 27 — Strategy-aware recovery, typed waits and idempotent recovery

## Goal

Ensure interruption leads to a different bounded strategy rather than blind replay.

## Tasks

1. Extend attempt/recovery records with:
   - strategy ID;
   - strategy fingerprint;
   - hypothesis;
   - new evidence refs;
   - recovery source;
   - changed-from-previous.
2. Implement canonical failure/recovery fingerprint.
3. Reject same deterministic-stall strategy without new evidence.
4. Preserve current rule:
   - second material failure → Debugger;
   - third attempt only with novelty;
   - otherwise `EXHAUSTED`.
5. Add typed wait contract:
   - type;
   - owner;
   - concrete unblock action;
   - fingerprint.
6. Reject prose-only `BLOCKED` transitions.
7. Add idempotent recovery-action identity so rewording does not reset attempts.
8. Add task/work-unit duplicate fingerprint for equivalent active work.
9. Never merge materially distinct objectives automatically.

## Required tests

- same failure wording variants share fingerprint;
- same stalled strategy rejected;
- materially different strategy allowed;
- Debugger required on second failure;
- invalid third attempt → EXHAUSTED;
- typed human wait;
- typed external-dependency wait;
- prose-only block rejected;
- duplicate active work detected;
- distinct scope does not dedupe.

---

# 5. Phase 28 — MCP safety envelope and circuit breaker

## Goal

Make remote/local MCP failure incapable of hanging orchestration.

## Tasks

1. Add canonical MCP request policy.
2. Support:
   - connect/catalog timeout;
   - execution timeout;
   - failure count;
   - circuit cooldown;
   - capability criticality.
3. Defaults:
   - advisory/Jev 30s;
   - memory 60s;
   - general remote 120s.
4. Enforce call timeout in plugin/integration layer if native runtime cannot.
5. Open circuit after two consecutive timeout/network failures in one Planner turn.
6. Return structured unavailable result.
7. Add sanitized MCP telemetry.
8. Keep `mcp_routing` OFF.

## Required tests

- timeout;
- two failures → circuit open;
- open circuit prevents repeated hammering;
- cooldown/rearm;
- optional capability fallback;
- required capability blocker;
- circuit cannot grant/widen authority.

---

# 6. Phase 29 — Jev advisory integration

## Goal

Make Jev persistently available as bounded decision support.

## Tasks

1. Add explicit `jev_advisory` capability/flag, default OFF.
2. Prefer hosted remote Jev transport.
3. Load credentials only from user-owned environment/credential store.
4. Bounded health/catalog probe.
5. Maintain explicit allowed Jev tool set.
6. Normalize 30s request budget.
7. Add Planner trigger policy:
   - route uncertainty;
   - model route uncertainty;
   - consequential tool-call proposal;
   - conflicting research evidence;
   - substantial completion uncertainty;
   - bounded recovery-strategy comparison.
8. Do not call Jev for obvious local tasks.
9. Record Jev output as advisory evidence.
10. Enforce that Jev cannot:
    - grant permission;
    - widen scope;
    - select disallowed model;
    - bypass human approval;
    - override verifier/reviewer/security;
    - write DONE.
11. `JEV_UNAVAILABLE` follows deterministic fallback.
12. Keep generic MCP router disabled.

## Required tests

- healthy;
- missing key;
- bad key;
- timeout;
- circuit open;
- catalog drift;
- Jev says allow + kernel denies → kernel wins;
- Jev says complete + verifier fails → DONE denied;
- trivial task does not call Jev;
- uncertain route calls Jev when flag/policy requires it.

---

# 7. Phase 30 — AI Memory VPS productionization

## Goal

Remove the local AI Memory fixed-listener dependency while preserving optional project continuity.

## Tasks

1. Replace local endpoint assumption with user-owned remote endpoint config.
2. Verify TLS/auth where applicable.
3. Bounded health check.
4. 60s retrieval budget.
5. MCP circuit breaker integration.
6. Define:
   - optional-memory unavailable → continue;
   - explicitly required memory → typed blocker.
7. Preserve project scoping rules.
8. Sanitize telemetry.
9. Prove local 49374 is no longer required.
10. Re-run V2 port preflight evidence and close only HOLDs actually proven.

## Required tests

- healthy remote;
- DNS failure;
- connect timeout;
- auth failure;
- 5xx;
- circuit open;
- optional work continues;
- no credential leakage;
- local listener absent/not required.

---

# 8. Phase 31 — Persistent bootstrap and always-on orchestration

## Goal

Make Planner/subagent/capability behavior automatic in every OpenCode session.

## Tasks

1. Verify `default_agent = build` in native V1/V2 renders.
2. Ensure global `AGENTS.md` persistent orchestration authorization is installed/reconciled.
3. Bootstrap plugin automatically on profile start/session.
4. Add bounded bootstrap context:
   - project ID;
   - runtime/version;
   - capability health summary;
   - active/detached tasks;
   - pending waits;
   - Jev status;
   - AI Memory status.
5. Do not block user task on optional capability health failure.
6. Remove any remaining requirement that the user explicitly says “use subagents”.
7. Replace “Jev only when user asks” semantics with policy-triggered automatic advisory use.
8. Add bootstrap compliance telemetry.

## Required tests

- fresh V1 session starts with Planner;
- fresh V2 session starts with Planner;
- non-trivial task delegates without user reminder;
- trivial task remains direct;
- Jev available but not automatically invoked without trigger;
- optional MCP unavailable does not prevent startup.

---

# 9. Phase 32 — Task / Run / Seat / Session persistence model

## Goal

Decouple durable work identity from OpenCode runtime sessions.

## Tasks

1. Extend Task Kernel schema/backward-compatible reads with:
   - orchestration runs;
   - root-session bindings;
   - worker-session bindings;
   - optional logical seat IDs;
   - attached/detached binding status.
2. Keep task state unchanged when a session detaches.
3. Add CAS-protected bind/rebind/detach operations.
4. Define one active execution owner per work unit.
5. Maintain session provenance:
   - runtime;
   - version;
   - parent/root IDs where available.
6. Use plugin persistent storage only as an index/cache if useful.
7. Task Kernel remains source of truth.
8. Legacy task records must remain readable.

## Required tests

- old record compatibility;
- bind;
- rebind;
- detach;
- CAS conflict;
- concurrent bind rejection;
- task stays IMPLEMENTING while execution is DETACHED;
- session index loss can be reconstructed from kernel.

---

# 10. Phase 33 — Session Reconciler and Continuation Envelope

## Goal

Resume orchestration correctly after OpenCode/root-session/process restart.

## Tasks

1. Build V2 Session Reconciler against exact public/native APIs.
2. For every known bound session classify:
   - running;
   - completed;
   - interrupted;
   - missing;
   - stale/ownership mismatch.
3. Recover worker final outputs/evidence where possible.
4. Reattach watchdog to still-active supported sessions.
5. Mark missing session as `SESSION_LOST` attempt result, not arbitrary task state.
6. Build compact Continuation Envelope.
7. Preserve:
   - objective;
   - user/product intent;
   - decisions;
   - valid evidence;
   - failed strategies;
   - active risks;
   - pending waits;
   - next move.
8. Add V1 fallback:
   - fresh session;
   - same durable Task;
   - Continuation Envelope;
   - no fake native resume.
9. Do not depend solely on background-child completion notification.
10. If supported, inject a compact recovered event/result into the new Planner session; otherwise supply on next Planner turn.

## Required tests

- close/reopen root session;
- process restart;
- completed child recovered;
- running child reattached or safely reclassified;
- missing child;
- sibling completion retained;
- task continuity on V1 fresh session;
- envelope remains bounded;
- no transcript dump required.

---

# 11. Phase 34 — Adaptive execution modes

## Goal

Let Planner select deterministic workflow, persistent specialist or one-shot worker by task shape.

## Tasks

1. Add canonical `execution_mode` decision to Planner/preflight/dispatch evidence.
2. Implement deterministic fallback selection rules.
3. Mode A — deterministic workflow:
   - kernel/script transitions for repeatable control flow;
   - reuse SDLC patterns already validated by the project.
4. Mode B — persistent specialist:
   - stable logical seat;
   - bounded retained context;
   - explicit retirement/hand-off.
5. Mode C — one-shot worker:
   - default for bounded delegation.
6. Mode choice inputs:
   - risk;
   - uncertainty;
   - duration;
   - continuity need;
   - separability;
   - cost;
   - runtime capability.
7. Team size alone cannot choose the mode.
8. Unsupported runtime mode falls back explicitly.

## Required tests

- fixed implementation pipeline → deterministic workflow;
- one code lookup → one-shot;
- long Debugger case → persistent specialist when enabled;
- V1 unsupported persistent primitive → canonical fallback;
- no deeper delegation introduced.

---

# 12. Phase 35 — Evidence reuse and context economy

## Goal

Stop downstream agents from repeating valid work and stop large outputs from flooding Planner context.

## Tasks

1. Define reusable evidence schema:
   - base revision;
   - source fingerprints/diff hash;
   - scope;
   - command/action;
   - environment/runtime;
   - result;
   - assumptions;
   - invalidation conditions.
2. Add evidence validity evaluator.
3. Add evidence reuse query for Planner/Tester/Reviewer.
4. Add invalidation on relevant source/environment/criteria change.
5. Store large raw result out of Planner prompt.
6. Pass compact evidence references.
7. Allow bounded retrieval on demand.
8. Preserve secret redaction and output caps.
9. Add reuse metrics.

## Required tests

- unchanged source → evidence reusable;
- changed relevant file → invalid;
- unrelated file change → evidence remains valid when contract permits;
- changed acceptance criterion → invalid;
- stale base revision behavior;
- large test log not injected into Planner by default;
- evidence reference retrieval works.

---

# 13. Phase 36 — Adaptive validation, deterministic review and security coverage

## Goal

Replace universal duplicate validation with risk/evidence-driven validation.

## Tasks

1. Implement validation levels L0–L3 from SPEC.
2. Change normal-cycle policy:
   - full `coder → tester → reviewer` is L2/L3, not universal.
3. Coder:
   - focused self-validation;
   - fast feedback;
   - cannot mark verified pass.
4. Tester:
   - read evidence first;
   - identify unproven risks;
   - differential validation;
   - repeat an equivalent test only with rationale.
5. Reviewer:
   - receive exact candidate/diff;
   - deterministic file selection;
   - related-file bundles;
   - applicable rule set;
   - reused evidence.
6. Implement bundle parallelism only when independent and budget allows.
7. Security Reviewer:
   - add optional coverage ledger for material audit/review;
   - source-change invalidation;
   - confirmed vs needs-validation separation.
8. Completion policy must require only roles selected by the validation level, while preserving hard risk triggers.

## Required tests

- L1 does not dispatch unnecessary Tester+Reviewer;
- L2 uses independent validation;
- high-risk trigger cannot downgrade to L1;
- Tester skips equivalent valid Coder check;
- Tester runs new edge/integration check;
- Reviewer bundle coverage complete;
- changed source invalidates prior security coverage;
- DONE gate rejects missing policy-required reviewer.

---

# 14. Phase 37 — Simplicity discipline and worker behavior refinement

## Goal

Reduce overengineering, scope creep and unnecessary code generated by LLM workers.

## Tasks

1. Refine Coder and domain-agent contracts with:
   - Minimum Sufficient Change;
   - No Bonus Work;
   - Reuse Before Create;
   - Abstraction by Evidence;
   - explicit Stop Condition.
2. Add Planner `CHANGE_BUDGET` / expected blast radius.
3. Worker reports actual changed paths and rationale.
4. Add `CHANGE_BUDGET_EXCEEDED` signal.
5. Add explicit `NON_GOALS` and `PRESERVE` where useful.
6. Explorer/Researcher receive bounded question/stop conditions.
7. Reviewer detects:
   - unrelated changes;
   - speculative abstractions;
   - duplicated helpers;
   - unjustified compatibility layers.
8. Use Code Craftsman/simple-design principles as technique, not rigid universal metrics.
9. Do not add arbitrary hard limits such as function-line count or TDD-always.

## Required tests/evals

Prompt/eval scenarios for:

- localized bug does not trigger broad refactor;
- existing helper is reused;
- new abstraction with no real consumer is rejected;
- necessary cross-cutting change can exceed initial budget with rationale;
- Explorer stops when enough evidence exists;
- Researcher does not continue searching after question is resolved.

---

# 15. Phase 38 — Planner Adaptive Engineering Loop and budget-aware fan-out

## Goal

Make Planner optimize for sufficient evidence at minimum work/cost.

## Tasks

1. Implement explicit Planner loop:
   - Frame;
   - Reuse;
   - Simplicity Gate;
   - Risk/uncertainty;
   - execution mode;
   - budget reservation;
   - minimum dispatch;
   - validation gaps;
   - complete/recover.
2. Reserve validation/review budget before fan-out.
3. Add role/tool/model escalation rationale.
4. Integrate Jev trigger decisions:
   - `route_task`;
   - `route_model`;
   - guard;
   - research check;
   - completion review.
5. Jev routing remains bounded to already allowed choices.
6. Make parallelism aware of:
   - ownership;
   - budget;
   - shared state;
   - expected latency benefit;
   - synthesis cost.
7. Prevent fan-out merely because capacity exists.
8. Add Planner stop condition: sufficient evidence for current decision.
9. Preserve mandatory useful subagent participation for non-trivial tasks, but do not require a full pipeline.

## Required tests/evals

- small change chooses minimal route;
- ambiguous risky task increases rigor;
- no validation budget → fan-out reduced;
- Jev route changes recommendation but Planner/kernel authority remains;
- lack of information chooses Explorer/Researcher rather than expensive model escalation;
- independent work fan-outs;
- dependent work remains sequential.

---

# 16. Phase 39 — Capability Doctor, primary/fallback routing and optional Jevgrep

## Goal

Make capability availability explicit so Planner routes around unhealthy or unsupported tools automatically.

## Tasks

1. Extend capability descriptor with:
   - health;
   - provider;
   - fallback order;
   - platform support;
   - risk/authority class.
2. Implement bounded `doctor`/bootstrap probe.
3. No health probe may mutate user state unnecessarily.
4. Define explicit fallback for:
   - AI Memory;
   - Jev;
   - semantic code discovery;
   - external research where applicable.
5. Integrate optional `jevgrep`-style semantic discovery:
   - only when installed/supported/healthy;
   - most useful for unfamiliar cross-file questions;
   - exact symbol/path lookup uses cheaper direct search;
   - results are evidence;
   - Windows unsupported state must not break Explorer.
6. Generic automatic installation remains out of scope.
7. Health failure does not grant permission or silently replace a security-sensitive capability.

## Required tests

- healthy primary;
- unhealthy primary → allowed fallback;
- unsupported platform → fallback;
- all optional providers unavailable → structured degraded mode;
- required provider unavailable → typed blocker;
- doctor output sanitized.

---

# 17. Phase 40 — OpenCode V2 native authority and execution capabilities

## Goal

Exploit V2 features only after exact-runtime proof, reducing duplicated orchestration logic where the runtime can enforce it safely.

## Tasks

1. Revalidate current exact V2 API/schema before every feature.
2. Native session hierarchy:
   - root/family/parent provenance.
3. Session-specific permissions:
   - render/apply Dispatch Contract narrowing;
   - child authority cannot exceed Planner/Task grant.
4. `experimental.policies`:
   - evaluate hard-deny invariants;
   - only tighten authority;
   - keep V1 equivalent/fallback.
5. Native step limits from canonical budgets.
6. Background subagents:
   - bounded concurrency;
   - kernel/reconciler handles restart.
7. Plugin storage:
   - runtime index only;
   - rebuildable.
8. Snapshots:
   - auxiliary evidence/recovery.
9. Durable session event log:
   - experimental secondary replay only.
10. Do not enable a feature if exact-binary behavior is not proven.

## Required tests

- permission narrowing;
- no child authority widening;
- policy deny wins over ordinary allow where exact API proves it;
- background child restart reconciliation;
- storage index deletion/rebuild;
- snapshot evidence does not override Git/worktree state;
- event log absence does not break task recovery.

---

# 18. Phase 41 — Orchestration evolution and eval loop

## Goal

Create a safe mechanism to improve the harness from real recurring behavior without rule accretion.

## Tasks

1. Derive evolution signals from sanitized telemetry/evidence.
2. Create `EVOLUTION_CANDIDATE` record:
   - problem;
   - repeated evidence;
   - generalized cause;
   - proposed change;
   - expected effect;
   - risk;
   - rollback.
3. Require minimum repeated evidence/sample threshold configurable by policy.
4. Build replay/offline eval fixtures where possible.
5. Support:
   - baseline;
   - candidate;
   - shadow/A-B comparison.
6. Candidate cannot modify production policy automatically.
7. Require review before promotion.
8. Promote one behavior change at a time when practical.
9. Keep change history and reason.
10. Add rollback to previous policy/prompt version.

## Initial evaluation targets

- Tester duplication rate;
- repeated tool-loop rate;
- average task wall time;
- Reviewer finding rate;
- change-budget exceed rate;
- user intervention rate;
- Jev useful-call rate;
- evidence reuse rate.

## Required tests

- one anecdote does not produce promotable rule;
- repeated evidence creates candidate;
- candidate regression blocks promotion;
- successful shadow can be promoted explicitly;
- rollback restores prior behavior.

---

# 19. Phase 42 — Full Windows V2 E2E, rollout and release closure

## Goal

Prove the complete system in the user's primary failure environment and close the V3.1 program.

## End-to-end scenarios

### Runtime reliability

1. V2 port free.
2. port occupied by unrelated process.
3. excluded/reserved port.
4. worker normal completion.
5. worker hard hang.
6. no-progress stall.
7. repeated identical action.
8. repeated short cycle.
9. interrupt failure.
10. sibling completes while one child hangs.

### MCP

11. Jev healthy.
12. Jev timeout/circuit.
13. AI Memory healthy VPS.
14. AI Memory unavailable optional.
15. AI Memory required dependency blocker.

### Persistence

16. close root session mid-task.
17. restart OpenCode mid-task.
18. completed child recovered after restart.
19. missing child classified.
20. new Planner receives Continuation Envelope.
21. task state preserved across session replacement.
22. V1 fresh-session continuation fallback.

### Adaptive behavior

23. trivial L0.
24. localized L1.
25. normal L2.
26. high-risk L3.
27. Tester reuses Coder evidence.
28. deterministic Reviewer bundles.
29. no-bonus-work scenario.
30. change-budget exceed scenario.
31. budget-aware fan-out.
32. Jev-triggered route decision.
33. Jev not called for obvious task.
34. capability primary→fallback.
35. optional semantic discovery unavailable on Windows.

### Authority

36. worker cannot widen permission.
37. Jev cannot grant.
38. background child cannot subdelegate.
39. V2 policy deny where validated.
40. unknown PID never killed.

## Rollout order

Recommended:

1. port preflight;
2. MCP safety;
3. remote AI Memory;
4. Jev health only;
5. watchdog/loop guard shadow;
6. worker watchdog enforcement;
7. Planner-turn enforcement;
8. persistent bootstrap;
9. Task/Run/Session binding;
10. session reconciler;
11. evidence reuse shadow;
12. adaptive validation shadow;
13. execution-mode router shadow;
14. simplicity/change-budget prompts;
15. Planner adaptive routing;
16. capability doctor/fallback;
17. V2 native permission/policy enforcement;
18. Jev advisory trigger activation;
19. evolution candidates in observation-only mode.

No rollout step is enabled merely because the previous step shipped; use evidence.

## Documentation closure

Update:

- main V3.1 SPEC/PLAN status;
- `docs/ARCHITECTURE.md`;
- `AGENTS.md`;
- runtime adapters;
- permission docs;
- troubleshooting;
- CHANGELOG;
- feature flags;
- exact supported runtime matrix;
- AI Memory remote setup;
- Jev setup/authority;
- cross-session semantics;
- validation levels;
- execution modes;
- evolution/eval process.

## Release gate

Program closes only when:

- required PAE acceptance criteria are evidenced;
- exact supported V2 Windows lane is green;
- V1 suite remains green;
- all HIGH/CRITICAL security findings resolved;
- remaining HOLDs are explicitly non-blocking and documented;
- Reviewer approves;
- Security Reviewer approves.

Suggested closure commit:

`docs: close V3.1 persistent adaptive orchestration program`

---

# 20. Dependency map

```text
P26 watchdog enforcement
  └─ P27 recovery/waits

P28 MCP safety
  ├─ P29 Jev
  └─ P30 AI Memory VPS

P31 persistent bootstrap
  └─ P32 Task/Run/Session model
       └─ P33 Session Reconciler
            └─ P34 execution modes

P35 evidence reuse
  └─ P36 adaptive validation
       └─ P38 Planner adaptive loop

P37 simplicity discipline
  └──────────────┘

P39 capability doctor
  └─ supports P38 and P40

P40 V2 native capabilities
  └─ depends on P32/P33 and exact runtime evidence

P41 evolution
  └─ depends on telemetry from P26–P40

P42 full E2E/release
  └─ all prior phases
```

Parallel work is allowed only when write ownership and semantic dependencies are clear.

---

# 21. Suggested checkpoints for the coding agent

Do not attempt P26–P42 as one giant implementation.

Recommended delivery waves:

### Wave A — Reliability closure

- P26
- P27
- P28
- P29
- P30

Outcome: no hangs + bounded MCP + Jev/AI Memory safe.

### Wave B — Persistent OpenCode orchestration

- P31
- P32
- P33
- P34

Outcome: automatic orchestration + cross-session Task continuity + execution modes.

### Wave C — Efficiency and behavior

- P35
- P36
- P37
- P38

Outcome: reuse, differential validation, simplicity and adaptive Planner.

### Wave D — Capability/runtime hardening

- P39
- P40

Outcome: health/fallback and deeper safe use of V2 native capabilities.

### Wave E — Learning and closure

- P41
- P42

Outcome: measured self-improvement pipeline + final release evidence.

After each wave, update live program status before continuing.

---

# 22. Final implementation constraints

- Keep V1 supported.
- Do not create V4 just for this program.
- Do not replace Task Kernel.
- Do not create daemon/database.
- Do not enable generic MCP routing.
- Do not commit credentials.
- Do not kill unknown processes.
- Do not release writer ownership unsafely after interruption.
- Do not retry deterministic stalls with unchanged strategy.
- Do not claim V2 support from mocks/unit tests only.
- Do not use experimental V2 APIs as authoritative without exact-runtime proof.
- Do not force Tester/Reviewer for every task.
- Do not let low-risk adaptive routing bypass high-risk policy triggers.
- Do not let Jev become an authority source.
- Do not let AI Memory become live task-state authority.
- Do not treat OpenCode chat/session history as durable task state.
- Do not auto-promote orchestration changes from telemetry.
- Prefer reuse and the smallest sufficient intervention throughout implementation.

---

# 23. Program Definition of Done

The V3.1 Persistent Adaptive Engineering program is complete only when the companion SPEC Definition of Done and PAE-01–PAE-40 are satisfied with repository evidence, exact-runtime evidence where applicable, independent review and documented residual risk.
