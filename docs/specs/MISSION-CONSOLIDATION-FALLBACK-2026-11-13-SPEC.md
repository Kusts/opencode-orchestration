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
- Step 4: **DONE for the measured T1 fallback** - normalized error, observed
  no-start, authorized decision, native MiMo success and attempt record.
- Step 5: **PARTIAL** - temporary/live `-Clean` installs and ownership
  boundaries verified; Agent Config full reconciliation is blocked by an
  upstream `Substring` / `ArgumentOutOfRangeException` on the AGENTS.md
  block (105 current lines vs 301 desired). The settings tests pass 36/36,
  and preview reports only permission drift while preserving extras. No change
  was made in the Agent Config repository; fix is recommended upstream.
- Step 6: **DONE** for cache/skills measurement. The cache test observed reuse
  across a model switch only within the same agent/session; do not generalize.
  Native skills loading is lazy; no new platform/flag is proposed.
- #11 and #64 remain **PARTIAL**: real completion journey and completion
  latency were not measured. No DONE-latency claim is made.
- Step 7: **PARTIAL** — real bounded chains measured for explorer T1,
  complex coder T3, high reviewer T3, critical security-reviewer T3 and high
  architect T3 (details in the mission PLAN). T4 Opus→Sol remains a policy
  candidate covered by Router tests, with no real transition; it requires
  T4 selection plus Kernel-owned proof. Astra is exceptional/proof-gated and
  is not claimed executed.

The explicit native `subagent.model` override was empirically observed on
Luna/MiMo calls. Runtime 2.3.0 remains outside
`Test-OrchestrationNativeModelOverrideProof` allowlist (2.2.5/2.2.6/2.0.23).
The allowlist was not changed; pin/allowlist remains a human decision.

Step 5 install evidence, including backup, preserved settings, ownership
manifest and upstream blocker, is recorded in
`evidence/mission-2026-11-13/install-agent-config-validation.json`.

## Target error taxonomy

1. `RATE_LIMIT`; 2. `QUOTA_EXCEEDED`; 3. `PROVIDER_ERROR`; 4. `MODEL_UNAVAILABLE`;
5. `MODEL_ERROR`; 6. `SERVICE_UNAVAILABLE`; 7. `OFFLINE`; 8. `UNKNOWN`.

These labels classify reports only. Neither an error class nor a caller-supplied
`NoExecutionStarted` value proves non-start.

## Acceptance criteria

- Current docs agree with `model-routing-policy.json` 1.5.0, including Luna T1/T2, Sonnet T3, Opus T4, and DeepSeek Go Planner without automatic fallback.
- Declared and effective configuration are separately recorded with redacted, secret-free evidence.
- Fallback cannot be authorized by classification alone; any non-start claim needs independent proof.
- Backlog states remain partial/pending until evidence supports closure.
- No execution code, flags, permissions, templates, or canonical policy is changed by this documentation slice.

## Non-goals

No runtime implementation, installation, provider/auth changes, issue/PR closure,
policy/registry redesign, or claim that blocked model-dependent turns passed.
