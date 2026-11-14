# Mission Consolidation & Fallback — SPEC (2026-11-13)

## Objective and scope

Reconcile documentation and backlog against current code, and consolidate the model policy/fallback route without duplicating execution mechanisms. The mission spans: (1) documentation/backlog; (2) model policy/quota; (3) PRs #238/#239/#240 consolidation; (4) error normalization and T1 fallback; (5) Orchestration/Agent Config/`-Clean` integration; (6) cache/skills; (7) T2–T4 routing.

## Principles and ownership

Reuse the existing Model Router, Task Kernel, and OpenCode native dispatch. Do not add a controller, executor, registry, or feature flag. Classification of an error is not proof that execution did not start; retry/fallback requires independent, kernel-accepted proof of non-start.

| Owner | Owned surface |
|---|---|
| Orchestration | 19 worker profiles (`agents/*.md`), `agents` block (mode/model/scoped permissions), enforcement plugin, `skills-core` |
| Agent Config | global `AGENTS.md` text, top-level permissions, MCP, shared skills, other runtimes |
| Operator | `models.jsonc`, credentials and live user configuration |

## Step 4 decision: productive T1 fallback

Fallback must use the native `subagent` tool to create a child session. Error
classification alone is not proof of non-start. The observed native
`tool.execution` error for an unavailable model, with no `sessionID` or child
session, is evidence of non-start for that attempt. Do not implement a parallel
executor through `opencode run` or another CLI route. The Task Kernel remains
the owner of `model-attempt` and `model-proof`; no-start evidence does not bypass
those gates.

Observed T1 fallback evidence: `model-fallback.ps1 -Action next` classified
the unavailable synthetic model as `MODEL_UNAVAILABLE`, observed no child
session, and authorized the ordered same-tier MiMo candidate. Planner then
dispatched native `subagent` MiMo; it succeeded and was recorded with
`model-fallback.ps1 -Action record` as `post_dispatch`. Helper suites passed
39/39, 70/70 and 8/8 in Windows PowerShell 5.1 and pwsh. This is
Planner-mediated, not automatic. The failed primary was synthetic
`openai/does-not-exist`, not a real Luna 429; 429/quota/503 coverage is
synthetic-test-only.

## Measurement status

- Step 2: **DONE** for policy/quota and bounded native model observations;
  installed live-config reconciliation remains Step 5.
- Step 4: **DONE for measured T1/T2 fallbacks** - normalized error, observed
  no-start, authorized decisions, native MiMo/DeepSeek Go success and attempt
  records. Both were Planner-mediated, not automatic.
- Step 5: **DONE** - Agent Config PR #51 (`54f3b9c`) fixes the
  `Substring`/`ArgumentOutOfRange` bug near line 886 using trimmed
  `$lineText`. The fixed preview exited 0; Instructions applied against the
  canonical `C:\Users\walis\agent-config` root; Settings applied with
  `-Force`; previews converged; post-sync install WhatIf reported zero drift.
  `OpenCodeSettingsReconciler` passed 36/36. Full evidence is in
  `evidence/mission-2026-11-13/agent-config-sync-2026-11-13.json`. The PR
  remains open. PS5.1 suite was 91/95 with four pre-existing failures
  (baseline 87/91); pwsh was 95/95.
- Step 6: **DONE** for measurement. The G1/T4 DONE journey includes observed
  cache reads/writes. A one-pair MiMo free A/B measured loading
  `verification-before-completion` via tool versus no skill; the skill body
  is ~2,184 bytes (~546 estimated tokens), while the ~34k input difference
  reflects context resend/cache rather than body size. Native lazy loading
  avoids preloading ~228k estimated body tokens, but a skill load adds a tool
  round-trip. No new platform/flag; `skill_routing` remains OFF.
  #11 remains **PARTIAL** (cache evidenced in DONE but remaining acceptance
  criteria open); #64 remains **PARTIAL** (single MiMo pair, no
  skills-assisted completion journey).
- Step 7: **PARTIAL** - T1 Luna→MiMo and T2 Luna→DeepSeek Go availability
  fallback decisions/child executions were real. For T2, the failed model was
  synthetic `openai/does-not-exist`, not a real Luna provider failure.
  Separately, a real T3→T4 escalation used kernel-owned T3 proof, selected
  Opus, passed verification/review, and reached **DONE**. The T3 failure was
  deliberately induced by prompt and is not evidence of natural incapability.
  T3/T4 availability fallback Sonnet→Terra and Opus→Sol were not executed;
  Astra is exceptional/proof-gated and was not executed. DeepSeek Go proof was
  limited to a trivial, non-sensitive prompt; `sensitive_data_allowed=false`
  and ZDR is `expired-unconfirmed`.

PR consolidation status: #238/#239/#242/#243/#244 **MERGED**; #240
**CLOSED → #243**. Master evidence includes `402dbc0`, `f7a233e`,
`df74e2a`.

The G1/T4 evidence is recorded in
`evidence/mission-2026-11-13/g1-t4-done-proof.json`. The controlled fixture
lives in the separate, ignored proof worktree; Astra was not used and this
T4 event is a kernel-proof escalation, not availability fallback.

The explicit native `subagent.model` override was empirically observed on
Luna/MiMo calls. The allowlist accepts 2.2.5/2.2.6/2.0.23/2.3.0 (PR #244).
The canonical runtime pin remains 2.2.6; bumping it is separate work.

CI V3 suite step timeout is 110 minutes (previously 60), and the three
containing jobs allow 120 minutes (previously 75). The runner canceled runs
near 60 minutes although suites took approximately 48–57 minutes.

Step 5 install evidence, including backup, preserved settings, ownership
manifest and upstream blocker, is recorded in
`evidence/mission-2026-11-13/install-agent-config-validation.json`.
The resolved Agent Config fix and converged sync are recorded in
`evidence/mission-2026-11-13/agent-config-sync-2026-11-13.json`; the earlier
blocker is retained there as history, not current status.

## Target error taxonomy

Exactly eight implemented classes:
`RATE_LIMIT`, `QUOTA_EXCEEDED`, `MODEL_UNAVAILABLE`, `PROVIDER_UNAVAILABLE`,
`PROVIDER_ERROR`, `AUTH_OR_PERMISSION_ERROR`, `REQUEST_INVALID`,
`EXECUTION_UNKNOWN`.

`RATE_LIMIT`, `QUOTA_EXCEEDED`, `MODEL_UNAVAILABLE` and
`PROVIDER_UNAVAILABLE` are eligible for fallback only with observed proof of
non-start. `PROVIDER_ERROR`, `AUTH_OR_PERMISSION_ERROR`, `REQUEST_INVALID` and
`EXECUTION_UNKNOWN` do not authorize fallback. Classification alone and a
caller-supplied `NoExecutionStarted` value never prove non-start.

Legacy Router triggers `MODEL_ERROR`, `SERVICE_UNAVAILABLE` and `OFFLINE` map
to the implemented classes; they are not members of this taxonomy.

## Acceptance criteria

- Current docs agree with `model-routing-policy.json` 1.5.0, including Luna T1/T2, Sonnet T3, Opus T4, and DeepSeek Go Planner without automatic fallback.
- Declared and effective configuration are separately recorded with redacted, secret-free evidence.
- Fallback cannot be authorized by classification alone; any non-start claim needs independent proof.
- Backlog states remain partial/pending until evidence supports closure.
- No execution code, flags, permissions, templates, or canonical policy is changed by this documentation slice.

## Non-goals

No runtime implementation, installation, provider/auth changes, issue/PR closure,
policy/registry redesign, or claim that blocked model-dependent turns passed.
