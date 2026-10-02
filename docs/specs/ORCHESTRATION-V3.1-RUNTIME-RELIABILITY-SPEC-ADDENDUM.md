# SPEC ADDENDUM — Orchestration V3.1 Persistent Adaptive Engineering & Runtime Reliability

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** `master @ 4a996b29659967312d7ba3abbfbfb6003ce0bec1`
**Revision date:** 2026-10-01
**Companion:** `ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md`
**Plan:** `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md`
**Change class:** `RUNTIME_RELIABILITY` + `PERSISTENT_ORCHESTRATION` + `ADAPTIVE_EXECUTION` + `EFFICIENCY_HARDENING` + `MCP_INTEGRATION`
**Release line:** continue V3.1 / 1.1.x. **Do not create V4 solely for this program.**

## 0. Status and scope of this revision

This revision supersedes the unimplemented design of the previous Runtime Reliability addendum from Phase 26 onward.

Phases 21–25 are already implemented or partially implemented and remain the baseline:

- P21: frozen reliability baseline;
- P22: deterministic V2 port/process preflight, partial HOLDs preserved;
- P23: canonical execution budgets, record-only;
- P24: V2 plugin/session-lifecycle migration and exact-runtime evidence, partial HOLDs preserved;
- P25: watchdog shadow implementation, no interruption enforcement yet.

This revision does **not** rewrite those phases. It redesigns the remaining program so reliability, persistence, efficiency and agent behavior are solved together.

The target end-state is:

> The user opens OpenCode, states the objective, and the Planner automatically performs orchestration, capability selection, Jev consultation when justified, bounded execution, validation, recovery and cross-session continuation. Human input is requested only at explicit authority, risk, irreversibility or product-decision boundaries.

---

# 1. Primary objectives

The system MUST evolve from a configured set of subagents into a persistent engineering control plane while preserving the existing V3.1 Task Kernel and dual-runtime model.

The program has eight primary outcomes.

### O1 — Always-on orchestration

The user MUST NOT need to repeatedly say:

- use subagents;
- use the Planner;
- use Jev;
- use skills;
- use AI Memory;
- review/test this;
- continue the previous orchestration.

The global/runtime bootstrap and Planner policy determine those choices automatically.

### O2 — Bounded execution

No Planner turn, worker, MCP call or recovery attempt may remain indefinitely active without:

- a step budget;
- a wall-clock budget;
- a no-progress budget;
- loop/stall detection;
- or an explicit interruption/recovery path.

### O3 — Persistent work across OpenCode sessions

A task MUST be durable independently of any OpenCode session.

A task can survive:

- TUI close;
- process restart;
- session replacement;
- compaction;
- child-session loss;
- parent-session replacement.

### O4 — Minimum sufficient engineering

Agents MUST prefer the smallest correct intervention that satisfies the current objective and acceptance criteria.

The system MUST actively discourage:

- bonus work;
- speculative abstraction;
- unrelated refactors;
- unnecessary new modules;
- broad changes not justified by the objective;
- redoing valid work/evidence.

### O5 — Evidence reuse and differential validation

Valid evidence MUST be reusable until invalidated.

Tester and Reviewer MUST evaluate gaps and risks instead of mechanically repeating Coder work.

### O6 — Adaptive execution

The Planner MUST choose the execution mode from the shape, risk, uncertainty and continuity requirements of the task rather than applying one fixed pipeline.

Supported semantic modes:

1. deterministic workflow;
2. persistent specialist;
3. one-shot subagent.

### O7 — Jev as bounded judgment, not authority

Jev MUST be persistently available to the Planner but invoked only at explicit decision boundaries.

Jev never grants authority, writes DONE or replaces deterministic verification.

### O8 — Measurable orchestration evolution

The system SHOULD learn from repeated operational evidence through controlled evolution:

`telemetry → candidate improvement → eval → shadow → promotion`

No prompt/policy is automatically rewritten from one anecdote.

---

# 2. Existing invariants that remain authoritative

This revision preserves:

- one Planner (`build`) as control plane;
- 19 current workers; no new role is required merely for this program;
- shallow hierarchy;
- workers cannot create subagents;
- Task Kernel as authoritative task-state owner;
- CAS for persistent task mutations;
- execution grants by intersection;
- Evidence Contract;
- deterministic verifier;
- kernel-authorized DONE;
- write leases and task worktrees;
- V1 and V2 runtime adapters;
- V1 first-class support;
- exact-runtime evidence before enforcement claims;
- generic `mcp_routing` disabled;
- no secret committed to the repository;
- no automatic killing of unknown processes;
- no unrestricted retry loop;
- no new always-on daemon or database in this release.

Where this revision conflicts with the previous unimplemented P26+ text, this revision wins.

---

# 3. Non-goals

This program MUST NOT:

- create V4 merely because the behavior is broader;
- replace OpenCode with a custom harness;
- copy OpenRig, Paperclip, Strands, AX or another framework wholesale;
- require Kubernetes, Agent Substrate or a new server control plane;
- make OpenCode V2 the only supported runtime;
- claim V1/V2 behavioral parity where the runtime capability differs;
- enable arbitrary MCP auto-discovery with execution authority;
- let the capability registry automatically install or authorize unknown tools;
- convert every task into a large SDLC ceremony;
- require Tester and Reviewer for every low-risk edit;
- make Jev a mandatory network call for every task;
- use AI Memory as the authoritative task-state store;
- use chat history as authoritative task state;
- persist raw secret-bearing tool output as evidence;
- auto-modify agent policy from telemetry without evaluation and explicit promotion.

---

# 4. Canonical architecture

```text
                         USER OBJECTIVE
                               |
                               v
                    Persistent Planner `build`
                               |
                      orchestration preflight
                               |
                +--------------+---------------+
                |                              |
                v                              v
          Task Kernel                    Capability Health
       durable task state              skills / MCP / runtime
                |                              |
                +---------------+--------------+
                                |
                         Execution Router
                                |
              +-----------------+------------------+
              |                 |                  |
              v                 v                  v
       Deterministic       Persistent         One-shot
         Workflow          Specialist         Subagent
              |                 |                  |
              +-----------------+------------------+
                                |
                     bounded execution layer
                     watchdog / loop guard
                                |
                         Evidence Store
                                |
                     Validation Router
                 reuse / tester / reviewer /
                    security / verifier
                                |
                     Completion Gate
                                |
                              DONE
                                |
                +---------------+---------------+
                |                               |
                v                               v
         AI Memory / learnings            Evolution signals
```

The semantic control plane remains runtime-neutral. OpenCode V2 capabilities are used through the V2 adapter, never by leaking V2-specific assumptions into the canonical kernel.

---

# 5. Persistent bootstrap

## 5.1 Default entrypoint

For an installed orchestration profile:

- `default_agent` MUST resolve to the Planner `build`;
- the global `AGENTS.md` MUST contain persistent delegation/orchestration authority;
- the orchestration plugin MUST bootstrap automatically;
- required capability descriptors MUST be discoverable at startup;
- the user is not required to restate orchestration instructions per session.

## 5.2 Planner bootstrap contract

At the first meaningful user turn of a root session, the Planner SHOULD receive or reconstruct:

- project/workspace identity;
- runtime generation and exact version;
- healthy/unhealthy capabilities;
- active/detached tasks for the project;
- current task binding, if one exists;
- pending human decisions;
- recent valid evidence summaries;
- Jev availability;
- AI Memory availability;
- applicable skills;
- current feature-flag state.

Bootstrap MUST be bounded and MUST NOT block normal work indefinitely because an optional capability is unavailable.

## 5.3 Persistent Jev availability

Jev SHOULD be configured globally/at runtime so the Planner can invoke it without per-session user setup.

Availability is not equivalent to mandatory invocation.

---

# 6. Task, Run, Seat and Session model

The system MUST separate durable work from runtime sessions.

## 6.1 Task

A Task is the durable unit already owned by the Task Kernel.

It survives runtime/session lifecycle changes.

## 6.2 Orchestration Run

A Run is one bounded execution episode for a Task, usually associated with one Planner root session.

Suggested fields:

- `run_id`;
- `task_id`;
- `root_session_id`;
- `runtime_id`;
- `runtime_version`;
- `started_at`;
- `ended_at`;
- `status`;
- `continuation_from_run_id`.

## 6.3 Logical Seat

A Seat is a logical execution identity where continuity matters.

Examples:

- Planner for TASK-123;
- long-running Debugger for TASK-123;
- persistent Coder for one feature.

A Seat MUST NOT be confused with a runtime session ID.

Initial implementation MAY use seats only for Planner and selected persistent specialists.

## 6.4 Runtime Session

A runtime session is disposable execution infrastructure.

Suggested binding:

```json
{
  "seat_id": "task-123:coder",
  "session_id": "ses_x",
  "parent_session_id": "ses_root",
  "runtime": "opencode-v2",
  "binding_status": "attached"
}
```

## 6.5 Execution binding is not task state

Closing/crashing a session MUST NOT force a semantic task state change.

Example:

```text
task.state = IMPLEMENTING
execution_binding = DETACHED
```

Do not invent `BLOCKED` merely because no runtime session is currently attached.

---

# 7. Cross-session continuation

## 7.1 Session Reconciler

On startup/session creation the V2 adapter SHOULD reconcile durable Task Kernel records against native OpenCode session state.

For each bound session:

- still running → reattach supervision where possible;
- completed → recover final messages/evidence;
- interrupted → classify and recover;
- missing → `SESSION_LOST`;
- stale ownership → fail closed and reconcile.

No status is assumed from stale local memory alone.

## 7.2 Continuation Envelope

A replacement Planner MUST receive a compact continuation packet instead of the complete prior transcript.

Minimum content:

```text
TASK_ID
OBJECTIVE
STATE
BASE_REVISION
CURRENT_OWNER
COMPLETED_WORK
CURRENT_WORK
DECISIONS
VALID_EVIDENCE
FAILED_STRATEGIES
ACTIVE_RISKS
PENDING_WAITS
NEXT_MOVE
```

The envelope MUST preserve the product/user intent, not only low-level implementation state.

## 7.3 Native V2 session graph

Where proven on the exact V2 runtime, use native session identifiers and hierarchy (`parentID`/family/root or equivalent public APIs) as execution evidence.

Native sessions are not the source of truth for task state.

## 7.4 V1 behavior

V1 MUST remain supported.

If V1 lacks a proven session graph/rebind primitive:

- Task continuity still works through the Task Kernel;
- a new runtime session is created;
- the Continuation Envelope rehydrates the Planner/worker;
- no false claim of native session resume is made.

---

# 8. Adaptive execution modes

The Planner MUST choose one of three semantic modes per work unit.

## 8.1 Deterministic Workflow

Use when control flow is known and repeatable.

Examples:

- implement → focused verify → review;
- fixed file bundles → parallel review → aggregate;
- deterministic migration checklist;
- SDLC-style staged pipeline.

Transitions SHOULD be kernel/script driven when possible rather than asking the LLM to rediscover the same sequence.

## 8.2 Persistent Specialist

Use when a specialist benefits materially from retained context across turns/runs.

Typical candidates:

- complex Debugger;
- Architect on a long design problem;
- long-running Researcher;
- feature Coder with iterative feedback.

Use sparingly. Persistent context has cost and stale-state risk.

## 8.3 One-shot Subagent

Default delegation for bounded work:

- locate code;
- inspect a diff;
- test one behavior;
- research one question;
- review one bundle.

A one-shot worker returns a structured result and terminates.

## 8.4 Mode-selection inputs

Planner considers:

- uncertainty;
- risk;
- expected duration;
- need for retained context;
- separability;
- cost;
- latency;
- current evidence;
- runtime capability;
- user deadline/constraints.

Team size alone MUST NOT determine execution mode.

---

# 9. Adaptive Engineering Loop for the Planner

For every non-trivial objective:

```text
FRAME
  ↓
REUSE
  ↓
SIMPLICITY GATE
  ↓
RISK / UNCERTAINTY
  ↓
SELECT EXECUTION MODE
  ↓
RESERVE VALIDATION BUDGET
  ↓
DISPATCH MINIMUM SUFFICIENT WORK
  ↓
COLLECT EVIDENCE
  ↓
VALIDATE GAPS
  ↓
COMPLETE OR RECOVER
```

The Planner remains the final strategy owner. Jev, advisors and routers are signals.

---

# 10. Simplicity and change discipline

These are global implementation principles for Coder and domain implementation workers.

## 10.1 Minimum Sufficient Change

Implement the smallest coherent change that satisfies acceptance criteria and safety requirements.

## 10.2 No Bonus Work

An edit must be linked to one of:

- current acceptance criterion;
- confirmed bug/root cause;
- required safety invariant;
- unavoidable prerequisite.

Unrelated improvements are recorded, not implemented.

## 10.3 Reuse Before Create

Before adding:

- helper;
- service;
- abstraction;
- interface;
- module;
- config layer;

inspect whether the project already has a suitable implementation/pattern.

## 10.4 Abstraction by Evidence

A new abstraction requires a concrete reason such as:

- at least two real consumers;
- real external boundary;
- real variation;
- safety/testability requirement;
- demonstrable complexity reduction.

Do not create speculative compatibility/future layers.

## 10.5 Change Budget

Planner SHOULD set an expected blast radius before implementation.

Suggested qualitative classes:

- `LOW`;
- `MEDIUM`;
- `HIGH`.

Worker reports actual changed paths and rationale.

Materially exceeding expected scope requires explanation before completion.

`CHANGE_BUDGET_EXCEEDED` is a review signal, not an automatic failure.

## 10.6 Stop Conditions

Every worker dispatch MUST include a stop condition.

Examples:

- Explorer: enough mapping to make the next decision;
- Researcher: sufficient evidence to answer the material question;
- Coder: acceptance met + focused checks green;
- Tester: material unproven risks evaluated;
- Reviewer: diff/evidence reviewed and no material finding remains.

Agents MUST NOT continue searching for work after the stop condition is satisfied.

---

# 11. Role-specific methods

The current roles remain; behavior is refined.

| Role | Primary working method |
|---|---|
| Planner | Goal → constraints → reuse → route → evidence → stop |
| Explorer | bounded reconnaissance + blast-radius mapping |
| Researcher | evidence-first research + explicit stop condition |
| Requirements Analyst | observable acceptance criteria; avoid premature solution binding |
| Architect | reversible decisions + ADR-style trade-off record when durable |
| Engineering Advisor | incremental design + cost-of-change |
| Skeptic | YAGNI + premortem + complexity challenge |
| Coder/domain engineers | Minimum Sufficient Change + Reuse Before Create |
| Tester | risk-based differential validation |
| Reviewer | defect-oriented review against exact candidate |
| Debugger | hypothesis-driven debugging; one hypothesis per experiment |
| Security Reviewer | trust-boundary/coverage-ledger driven validation |
| Docs Manager | continuity and durable decision documentation without duplicating state |

Skills refine technique, but do not create a second orchestration system.

---

# 12. Evidence model and reuse

## 12.1 Evidence identity

Reusable evidence SHOULD record:

- evidence ID;
- task/run/worker identity;
- base revision;
- diff hash or relevant source fingerprints;
- scope/files covered;
- command/action;
- environment/runtime;
- result;
- timestamp;
- assumptions;
- invalidation conditions.

## 12.2 Evidence reuse rule

A downstream agent MUST inspect valid evidence before repeating work.

Reuse is allowed only when relevant inputs remain unchanged.

Examples of invalidation:

- relevant source changed;
- environment changed materially;
- test configuration changed;
- base revision no longer matches;
- acceptance criterion changed;
- evidence provenance is incomplete.

## 12.3 Context offload

Large raw outputs SHOULD stay outside the Planner context.

Planner receives compact references:

```text
EVIDENCE E42
kind=test
scope=auth
status=PASS
base=abc123
```

Full content is retrieved only when needed.

This is a context-efficiency mechanism, not evidence deletion.

---

# 13. Validation Router

The system MUST stop treating `Coder → Tester → Reviewer` as a universal ritual.

The Planner selects a validation level from risk/evidence.

## 13.1 Initial levels

### L0 — trivial/direct

- allowed only under existing `TRIVIAL_DIRECT` policy;
- focused deterministic check where applicable.

### L1 — low-risk localized change

Typical route:

`Coder → focused self-validation → verifier/DONE gate`

Independent Reviewer MAY replace Tester where logic-risk justifies it.

### L2 — normal engineering change

Typical route:

`Coder → focused validation → Tester differential validation → Reviewer`

### L3 — high-risk/cross-cutting

Typical route:

`Discovery/specialist → Coder → Tester → Reviewer → Security Reviewer (when triggered) → integration evidence`

Risk, not lines of code, determines level.

## 13.2 Coder validation

Coder validates for fast feedback.

Coder SHOULD execute the smallest checks needed to establish that the implementation is a viable candidate.

Coder does not self-authorize final verification.

## 13.3 Tester differential validation

Tester MUST:

1. inspect Coder evidence;
2. identify what is still unproven;
3. avoid equivalent repetition without a reason;
4. target edge cases, integration, regression or adversarial behavior that can falsify the candidate.

Tester is an independent falsifier, not a duplicate command runner.

### 13.3.1 Tester execution authority (IMPLEMENTED 2026-10-01, reconciled 2026-10-02 — do not reimplement)

In this repository, PowerShell validation runs only through the fixed gateway
`scripts/v3/run-v3-tests.ps1`, with focused `-Name <suite>` selection whose
charset is guarded and fail-closed. Arbitrary PowerShell (`-Command`, `-File`
of another script), alternate shells, wrappers and elevation mechanisms remain
denied; the allowed wildcard exists only after the fixed gateway path. The
Tester MUST NOT broaden that allowlist, and MUST NOT request generic shell
widening.

### 13.3.2 Permission-denial invariant (canonical)

- A denial of the PRIMARY operation ends that route. The Tester MUST NOT
  attempt an equivalent action through another shell, wrapper, interpreter,
  elevation mechanism, alternate command form or other gateway, and MUST NOT
  keep searching indefinitely for another route.
- AT MOST ONE authority-safe reformulation is permitted, and only when both
  conditions hold: the denial clearly identifies an AUXILIARY presentation or
  filtering stage (`tail`, `head`, `grep`, `findstr`, `Select-Object`) as the
  only denied segment, AND the primary operation is separately authorized. The
  reformulation removes only the auxiliary stage and runs the same primary
  validation unchanged (for example `pnpm test | tail-40` → `pnpm test`). No
  chained output-utility sequence is attempted, and no reformulation may add an
  executable, shell, wrapper, interpreter, privilege or authority.
- When no authorized capability can satisfy the validation requirement, the
  Tester returns the typed blocker `VALIDATION_CAPABILITY_UNAVAILABLE` to the
  Planner, reporting INTENDED VALIDATION; NECESSARY COMMAND/CAPABILITY;
  RESTRICTION FOUND; SAFE ALTERNATIVE.

The Tester distinguishes `TEST FAILED` (validation ran and failed),
`AUXILIARY OUTPUT STAGE DENIED` (auxiliary presentation denied, remove it once)
and `VALIDATION CAPABILITY UNAVAILABLE`. A permission denial is not a
functional defect: it MUST NOT lead to code changes made to make a test pass.

## 13.4 Reviewer deterministic scoping

Before LLM review, deterministic logic SHOULD compute:

- exact diff/candidate;
- files requiring review;
- related-file bundles;
- applicable rule sets;
- valid existing evidence.

Reviewer reviews the exact candidate/bundle.

Do not ask the Reviewer to redesign unrelated architecture.

## 13.5 Security Coverage Ledger

For material security review, track:

- planned units;
- covered units;
- candidate findings;
- confirmed findings;
- needs-validation;
- deferred/out-of-scope;
- reused prior evidence;
- source changes that invalidate prior coverage.

Independent verification remains required for confirmed material findings.

---

# 14. Budget-aware orchestration

The Planner MUST reserve enough budget to finish, not only to explore.

Before fan-out:

1. estimate total execution budget;
2. reserve validation/review requirements;
3. reserve mandatory critic/verifier capacity for high-risk work;
4. allocate the remainder to discovery/implementation.

Do not spend the whole budget on workers and leave no capacity to verify.

Budget dimensions MAY include:

- model/tool steps;
- worker invocations;
- wall clock;
- model tier;
- context/token cost where observable.

---

# 15. Bounded execution, watchdog and loop guard

P23/P25 provide the record/shadow baseline.

P26+ MUST enforce the existing contract.

Canonical failure classes remain:

- `HARD_TIMEOUT`;
- `NO_PROGRESS`;
- `REPEATED_ACTION`;
- `REPEATED_CYCLE`;
- `PROVIDER_STALL`;
- `MCP_TIMEOUT`;
- `PERMISSION_DEADLOCK`;
- `RUNTIME_UNRESPONSIVE`;
- `SESSION_LOST`;
- `USER_CANCELLED`.

Initial loop policy remains:

- repeated identical action 3 times without meaningful progress → `STALL_SUSPECTED`;
- 5 times → interrupt;
- short action cycle length 2–4 repeated 3 times without state/evidence delta → interrupt.

A legitimate iterator must declare a bounded range and progress marker.

---

# 16. Recovery and typed waits

## 16.1 Strategy-aware recovery

A deterministic stall cannot be retried with materially the same strategy unless new evidence explains why it should now work.

Attempt history includes:

- strategy ID/fingerprint;
- hypothesis;
- new evidence;
- recovery source;
- material change from prior attempt.

Second material failure requires Debugger.

Third attempt requires new evidence/hypothesis/decomposition/tool/runtime path; otherwise `EXHAUSTED`.

## 16.2 Typed Wait

`BLOCKED` MUST have a routable wait condition.

Suggested shape:

```json
{
  "wait": {
    "type": "human_decision",
    "owner": "user",
    "action": "choose_database",
    "fingerprint": "sha256:..."
  }
}
```

Possible types:

- `human_decision`;
- `external_dependency`;
- `worker`;
- `review`;
- `approval`;
- `runtime_recovery`.

Free-text “waiting for something” is insufficient.

## 16.3 Recovery fingerprint

Equivalent failure/wait conditions share a canonical fingerprint so rephrasing does not reset retry/recovery counts.

---

# 17. Idempotent work units

Before creating a new task/work unit, compute a bounded identity from:

- objective;
- scope;
- definition/criteria of done;
- project identity.

If an equivalent active work unit exists, Planner SHOULD:

- attach;
- resume;
- reuse;

rather than silently create duplicate work.

No dedupe rule may merge materially distinct objectives merely because descriptions are similar.

---

# 18. MCP safety envelope

All MCP calls are bounded.

Initial execution targets:

| Class | Budget |
|---|---:|
| fast advisory/Jev | 30 s |
| memory/retrieval | 60 s |
| general remote MCP | 120 s |
| long-running | explicit task contract |

Two consecutive timeout/network failures in one orchestration turn SHOULD open a temporary circuit.

Circuit-open behavior is structured and must not become retry spam.

Generic `mcp_routing` remains OFF.

---

# 19. Jev integration

## 19.1 Purpose

Jev is the Planner's decision-escalation layer.

Use when judgment can materially change the route.

## 19.2 Suggested triggers

- route uncertainty;
- model-tier uncertainty;
- consequential tool-call proposal;
- conflicting research evidence;
- completion uncertainty on substantial work;
- optional bounded comparison of recovery strategies.

Do not call Jev for obvious local tasks.

## 19.3 Authority

Jev may advise:

- `route_task`;
- `route_model` among already permitted models;
- tool-call guard;
- research/evidence judgment;
- completion judgment.

Jev cannot:

- execute;
- grant permissions;
- widen scope;
- approve destructive production action;
- replace human approval;
- override deterministic verifier;
- override Security Reviewer;
- write DONE.

## 19.4 Jev evidence

Jev result is recorded as advisory evidence with:

- tool;
- input decision boundary;
- result;
- latency;
- availability;
- task/run/session identity.

`JEV_UNAVAILABLE` falls back safely and never means approval.

---

# 20. Remote AI Memory

AI Memory migration to VPS SHOULD remove the local fixed-port dependency.

Requirements:

- user-owned endpoint/credentials;
- bounded health check;
- retrieval timeout;
- circuit breaker;
- no secret in telemetry;
- optional memory failure does not block unrelated engineering;
- Task Kernel remains authoritative;
- AI Memory stores durable learnings/decisions, not live execution ownership.

---

# 21. Capability health and fallback

Adopt an explicit capability-layer model.

A capability may have:

- preferred provider;
- fallback providers;
- health status;
- platform support;
- cost/risk class;
- authority class.

Example:

```text
code.semantic-discovery
├─ jevgrep        (when supported/healthy)
├─ native search
└─ rg/direct reads
```

## 21.1 Doctor/preflight

Bootstrap SHOULD expose compact health:

```text
Task Kernel       HEALTHY
OpenCode sessions HEALTHY
Jev               HEALTHY
AI Memory         DEGRADED
Jevgrep           UNSUPPORTED_PLATFORM
```

The Planner routes around optional failures.

## 21.2 Jevgrep

Jevgrep MAY be integrated as an optional Explorer capability for unfamiliar codebases.

It MUST NOT replace exact symbol/path search when direct search is sufficient.

Platform/runtime support must be detected; do not assume native Windows support.

Search output is evidence, not truth.

---

# 22. OpenCode V2 native capabilities to exploit

Every item requires exact-runtime validation before enforcement.

## 22.1 Native session hierarchy

Use session/root/family/parent relationships where supported to improve:

- supervision;
- reconciliation;
- provenance;
- continuation.

## 22.2 Session-specific permissions

Translate Dispatch Contract authority into native per-session restrictions when possible.

A child can receive equal or narrower authority, never broader authority.

Invariant:

`WorkerGrant ⊆ PlannerGrant ⊆ User/TaskGrant`

## 22.3 `experimental.policies`

Use only for hard global invariants after exact-runtime validation.

Candidate uses:

- worker subdelegation hard deny;
- force-push/destructive actions;
- protected control-plane resources.

Policies tighten authority only.

## 22.4 Background subagents

Background execution MAY improve wave latency.

Parent MUST NOT depend solely on process-local completion notifications.

Task Kernel + Session Reconciler must recover after restart.

## 22.5 Native step limits

Render from canonical execution budgets where exact version proves the field.

## 22.6 Plugin persistent storage

`ctx.storage` or equivalent MAY store runtime indexes/bindings.

It MUST NOT replace the Task Kernel.

## 22.7 Snapshots

Native snapshots MAY provide auxiliary:

- changed-state evidence;
- recovery provenance;
- rollback assistance.

Git/worktrees remain authoritative for source ownership.

## 22.8 Durable session event log

Experimental event log MAY be used as secondary replay/reconciliation evidence.

It MUST NOT be the sole source of task truth while experimental.

---

# 23. Human exception model

Autonomy is default for local, reversible, authorized engineering.

Human/user input is required for explicit exceptions such as:

- materially ambiguous product decision;
- irreversible/destructive production action;
- external spending/purchase;
- credential creation/rotation/revocation;
- legal/compliance decision;
- scope expansion that changes the requested outcome;
- exhausted recovery budget;
- explicit authority boundary already defined by policy.

A hidden worker must never wait on an invisible interactive permission prompt.

Approval must be resolved before dispatch or surfaced as a typed wait.

---

# 24. Orchestration Evolution Loop

The orchestration system SHOULD be refinable from real usage without prompt accretion.

## 24.1 Signals

Candidate evolution signals include:

- same retry pattern repeated;
- Tester frequently duplicating Coder commands;
- Reviewer findings repeatedly caused by one missing instruction;
- repeated orchestration bypass;
- systematic budget overrun;
- repeated unused agents/capabilities;
- recurrent user correction;
- high false-positive watchdog/validation behavior.

## 24.2 Candidate process

```text
observe
  ↓
generalize root behavior
  ↓
EVOLUTION_CANDIDATE
  ↓
offline/replay evaluation
  ↓
A/B or shadow
  ↓
review
  ↓
explicit promotion
```

One example MUST NOT create one permanent special-case rule.

## 24.3 Evaluation artifacts

Evolution candidate records SHOULD contain:

- problem;
- evidence/sample size;
- proposed policy/prompt change;
- expected effect;
- regression risk;
- evaluation;
- decision;
- rollback.

---

# 25. Observability and efficiency metrics

Add or derive metrics sufficient to evaluate the refinements.

Recommended metrics:

- wall-clock per task;
- time per phase/agent;
- tool calls per worker;
- repeated-action count;
- watchdog interventions;
- retries by fingerprint;
- evidence reused vs recomputed;
- Coder checks vs Tester repeated-equivalent checks;
- changed-file count vs expected change budget;
- Reviewer findings per bundle;
- validation level distribution;
- Jev invocation rate and decision impact;
- MCP circuit-open count;
- cross-session resume success;
- duplicate task/work-unit prevented;
- model-tier escalation rate;
- user-intervention rate;
- task completion after continuation.

Metrics MUST be sanitized and bounded.

---

# 26. Feature flags and rollout

New behavior MUST start conservative.

Suggested semantic flags, exact representation left to current registry conventions:

- `watchdog` — existing;
- `loop_guard`;
- `mcp_safety`;
- `jev_advisory`;
- `persistent_bootstrap`;
- `cross_session_binding`;
- `execution_mode_router`;
- `evidence_reuse`;
- `adaptive_validation`;
- `capability_doctor`;
- `orchestration_evolution`.

Rules:

- new enforcement begins OFF or shadow unless preflight-only and non-invasive;
- activation requires exact-runtime evidence where runtime-specific;
- V1 cannot be disabled to make V2 tests pass;
- no feature flag grants authority.

---

# 27. Acceptance criteria

## Reliability

- **PAE-01:** a hung worker cannot block its parent indefinitely.
- **PAE-02:** repeated identical tool loops are interrupted within configured bounds.
- **PAE-03:** a short repeated cycle without progress is interrupted.
- **PAE-04:** partial evidence survives interruption.
- **PAE-05:** deterministic stall retry with unchanged strategy/no new evidence is rejected.
- **PAE-06:** second material failure requires Debugger.
- **PAE-07:** invalid third attempt becomes `EXHAUSTED`.
- **PAE-08:** unknown PIDs are never killed automatically.
- **PAE-09:** MCP waits are bounded and repeated outage opens a circuit.

## Persistent orchestration

- **PAE-10:** new OpenCode root sessions default to Planner orchestration without user reminders.
- **PAE-11:** Task state survives root-session replacement.
- **PAE-12:** V2 Task↔Run↔Session bindings can be reconstructed after restart.
- **PAE-13:** a completed child result is not lost because another child stalls.
- **PAE-14:** Continuation Envelope resumes work without requiring the entire prior transcript.
- **PAE-15:** V1 can continue the same Task through a fresh session even without native V2 graph features.
- **PAE-16:** closing a session does not falsely mark the Task blocked or failed.

## Efficiency and behavior

- **PAE-17:** Coder receives a stop condition and change scope.
- **PAE-18:** unrelated “bonus” changes are rejected or recorded outside the implementation.
- **PAE-19:** materially exceeded change budget is visible to review.
- **PAE-20:** Tester consumes valid Coder evidence before deciding what to run.
- **PAE-21:** equivalent valid checks are not repeated without rationale.
- **PAE-22:** Reviewer receives the exact candidate/bundle and applicable rules.
- **PAE-23:** low-risk work is not forced through the full L3 pipeline.
- **PAE-24:** high-risk work cannot silently downgrade required independent validation.
- **PAE-25:** fan-out cannot consume reserved validation/review budget.

## Jev/capabilities

- **PAE-26:** Jev is available persistently but is not called for every task.
- **PAE-27:** Jev cannot grant permission, widen scope or write DONE.
- **PAE-28:** Jev unavailable falls back without infinite retry.
- **PAE-29:** capability doctor reports health/fallback status without granting authority.
- **PAE-30:** optional semantic code discovery falls back when unsupported/unhealthy.

## Cross-session/native V2

- **PAE-31:** V2 session hierarchy/provenance is recorded where exact-runtime support is proven.
- **PAE-32:** session-specific permissions never exceed the canonical Task/Planner grant.
- **PAE-33:** background child completion can be reconciled after parent/runtime restart.
- **PAE-34:** experimental event-log/snapshot features are auxiliary, not authoritative.

## Evolution

- **PAE-35:** no orchestration policy is promoted from one anecdotal failure.
- **PAE-36:** an evolution candidate has evidence, evaluation and rollback.
- **PAE-37:** shadow/A-B evaluation can detect regression before promotion.

## Compatibility

- **PAE-38:** V1 regression suite remains green.
- **PAE-39:** exact pinned V2 real-runtime lane covers watchdog and cross-session scenarios.
- **PAE-40:** no generic MCP routing is required to satisfy this SPEC.

---

# 28. Definition of Done

This expanded V3.1 program is complete only when:

1. P21–P25 evidence remains valid or explicitly superseded by newer evidence.
2. Worker and Planner active execution is bounded.
3. Loop guard interrupts deterministic stalls safely.
4. Recovery is strategy-aware and fingerprinted.
5. Typed waits prevent silent blocked states.
6. Jev and AI Memory are bounded remote dependencies.
7. Planner/subagents/Jev are persistent defaults rather than per-session reminders.
8. Task/Run/Seat/Session separation is implemented.
9. V2 session reconciliation and cross-session continuation are proven.
10. V1 continuity remains functional without false V2 parity claims.
11. three adaptive execution modes exist semantically, with deterministic fallback.
12. evidence reuse and invalidation are implemented.
13. Tester performs differential validation.
14. Reviewer receives deterministic review scope/bundles.
15. Security review can use a coverage ledger for material audits.
16. Minimum Sufficient Change / No Bonus Work / Reuse Before Create are enforced through dispatch/review behavior.
17. validation levels are risk/evidence driven.
18. fan-out is budget-aware.
19. capability health/fallback is observable.
20. optional Jevgrep-style semantic discovery cannot become a hard dependency.
21. V2 native session permissions/policies are used only where exact-runtime validated.
22. orchestration evolution has an evaluated shadow/promotion path.
23. exact V2 Windows E2E covers hangs, loops, restart, cross-session continuation and MCP outages.
24. V1 remains green.
25. Reviewer approves the final program.
26. Security Reviewer has no unresolved high/critical finding.

---

# 29. Non-normative design provenance

The following projects informed patterns in this revision but are not runtime dependencies:

- `mvschwarz/openrig` — durable agent identity, queues, restore/handoff and separation of logical identity from runtime session;
- `PaperclipAI/paperclip` — execution semantics, typed waits, bounded recovery and governance;
- `strands-agents/harness-sdk` — session persistence, context offload, background work, intervention and authority narrowing;
- `revfactory/harness` — workflow vs persistent collaboration vs one-shot delegation and controlled harness evolution;
- previously reviewed SDLC / Claude Agent Kit — deterministic staged workflows, maker/checker, state and recovery;
- `alibaba/open-code-review` — deterministic scope/bundling/rule matching around LLM review;
- `cloudflare/security-audit-skill` — coverage ledger, prior-evidence reuse, strict budget reservation and independent verification;
- `dzhng/jevgrep` — bounded semantic code discovery as evidence;
- `browser-use/jev-ultrafast` — typed actions, state fingerprints, bounded loops and stale-decision protection;
- `Panniantong/Agent-Reach` — capability health, primary/fallback routes and doctor diagnostics;
- `markfulton/ai-employees` — idempotent routines and human intervention at consequential boundaries;
- `builderio/agent-native` — future-facing shared capability contracts;
- `google/ax` + `agent-substrate/substrate` — long-term reference for task/workspace isolation, suspend/resume and sandboxed workloads.

The repository's own canonical policy, Task Kernel and exact OpenCode runtime behavior always outrank these references.
