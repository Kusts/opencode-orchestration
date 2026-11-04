# Model Router v1.4 — execution and fallback contract

## Canonical mapping

| Tier | Primary | Fallback(s) | Notes |
|---|---|---|---|
| T0 | No LLM | — | Scripts, AST and deterministic checks only |
| T1 | `opencode-go/iceman-contributor-free` | `opencode/mimo-v2.6-flash-free` | OpenCode Console free offers may expire |
| T2 | `opencode-go/muse-spark-1.3-contributor` | `openai/gpt-6-luna`, then `claude-agent/haiku` (capability + proved no-start required) | General T2 chain; Planner `build` is pinned to Luna but classified T2 and does NOT use this generic chain (see Planner section) |
| T3 | `openai/gpt-6.1-terra` | `claude-agent/sonnet` (capability + proved no-start required), then `opencode-go/muse-spark-1.3-contributor` | Same-tier availability substitute first; T2 is a degraded transport recovery, not equivalent capability. DeepSeek Go is BLOCKED (`ZDR_EXPIRED_UNCONFIRMED`) |
| T4 | `openai/gpt-6.1-sol` | `claude-agent/opus` on availability faults (capability + proved no-start); `openai/gpt-6-astra` only after kernel-owned verified Sol non-resolution; `claude-agent/fable` only after a canonical Astra availability failure (allowlisted reason + `NoExecutionStarted=true` + Astra attempted + admissible capability/alias/role; a generic receipt never unlocks Fable); Muse on transport outage | No per-call T4 cost authorization; T3/T4 entry stays kernel-owned. Availability never escalates tier |

The OpenCode Console free DeepSeek is a separate endpoint (`opencode/deepseek-v4.1-flash-free`). DeepSeek V4.1 Flash via OpenCode Go (`opencode-go/deepseek-v4.1-flash`) is BLOCKED as of 2026-11-03: public Go docs show a ZDR agreement valid only through 2026-10-31 and renewal is unconfirmed; the user did NOT authorize use of unverified DeepSeek ZDR. The entry is kept for provenance; the router excludes it (`MODEL_DISABLED`) while other admissible routes remain operational. Training consent (this project, 2026-11-03, `Aceitar treinamento`; no global workspace setting was toggled): Iceman Contributor Free prompts/completions may train the model (no ZDR); Muse Spark Contributor prompts/completions train Meta models (no ZDR) and the OpenCode workspace must have `Allow paid endpoints that train on request data` enabled — that setting is UNVERIFIED/required and was not toggled here, do not claim it is enabled. Honor the effective model data policy and workspace privacy restrictions.

## Provider namespace: do not infer it from price

The routing policy binds **four OpenAI models** directly to the `openai/` provider: Luna (`openai/gpt-6-luna`), Terra (`openai/gpt-6.1-terra`), Sol (`openai/gpt-6.1-sol`) and Astra (`openai/gpt-6-astra`). Do not silently substitute an OpenCode-hosted copy of these models.

The free MiMo fallback belongs to the **OpenCode Console free** provider (`opencode/mimo-v2.6-flash-free`). Despite its *Free* pricing label, Iceman Contributor Free is listed by OpenCode under **OpenCode Go** (`opencode-go/iceman-contributor-free`), not `opencode/`. Muse Spark 1.3 Contributor (`opencode-go/muse-spark-1.3-contributor`) and DeepSeek V4.1 Flash (`opencode-go/deepseek-v4.1-flash`) also use **OpenCode Go**. The disabled legacy `opencode/deepseek-v4.1-flash-free` must not become an implicit fallback.

## Claude Agent provider (`claude-agent`, subscription)

Four dispatch aliases are registered in the single policy file and the dispatch ID **is** the alias itself: `claude-agent/haiku` (T2), `claude-agent/sonnet` (T3), `claude-agent/opus` (T4) and `claude-agent/fable` (T4, gated). Each entry additionally records `catalog_inventory_id` — an exact ID merely LISTED in this account's local `opencode models` CLI inventory (older names Haiku4.5/Sonnet5/Opus5/Fable5) — strictly as catalog listing/provenance: the policy publishes **no** alias->concrete mapping, carries **no** `resolved_model` field, and the router never compares `catalog_inventory_id`. Router validation is limited to the closed dispatch-alias map (`model_id` + `alias`, case-sensitive), failing closed with `CLAUDE_UNKNOWN_ALIAS` / `CLAUDE_ALIAS_MISSING` / `CLAUDE_MODEL_ID_MISSING` / `CLAUDE_ALIAS_MISMATCH` on any tamper. The live OpenCode model tool lists the aliases with display names Haiku 5.5 / Sonnet 5.5 / Opus 5.5 / Fable 5.1 and does NOT state which alias maps to which ID. Real direct Haiku/Sonnet smokes and a real Haiku subagent smoke PASSED after a quota reset — the earlier smoke attempt was quota-blocked *before* the reset, and later calls succeeded. Those passing smokes prove provider + alias + effort `low` (one of the alias-list variants): the real session proved provider + alias, never an ID, because the observed event exposes only the alias. Alias-to-concrete runtime resolution therefore stays UNRESOLVED (`resolution_status: runtime-unverified`) and the quota/catalog discrepancy remains an honest unresolved runtime blocker. If a session event ever reports a concrete ID, post-execution verification must stay `PROOF_ABSENT` / `UNAUTHORIZED_MISMATCH` until the mapping is independently proven — never `EXACT_MATCH` or `AUTHORIZED_FALLBACK` off an unverified ID. Record the alias and the listed inventory ID on every use (the ID as provenance only); never invent other concrete models (no invented 5.5/5.1 IDs). Each alias lists effort variants `low`/`medium`/`high`/`xhigh`/`max` as catalog metadata (`tools.opencode.models`); the passing smoke used the `low` variant. Aliases stay selectable only while the policy's fail-closed dispatch-alias identity check is satisfied; static tests assert the recorded alias identity and gating, never actual version resolution.

1. **Capability gate (no second catalog, no new state machine).** The provider is reject-closed by default: `Resolve-OrchestrationModelFallback` only considers a `claude-agent` model when the dispatcher proves a local authenticated `claude` executable on the worker machine (`-ClaudeAgentProven` / `-WorkerCapabilities`), AND an allowlisted availability reason applies, AND `-NoExecutionStarted $true` is proved pre-execution. Remote workers without the explicit `claude-agent-remote` capability are rejected even when local proof exists. Every condition is necessary; none alone authorizes a substitute. CI machines without proof keep legacy behavior fail-closed. These routes are policy-level only: productive native dispatch stays HOLD (see below). One explicitly verified synthetic session now exists: the TaskKernel bound a real child session recording `provider=claude-agent` / model alias `haiku` at T2 plus a model attempt, and kernel `verify-run` verified a synthetic artifact. That session was manually requested, NOT routed by the productive Model Router, so it does not prove automatic selection or fallback — automatic selection/fallback remains unproven.
2. **Role admissibility.** Haiku serves T2-admissible roles only (build included); reviewer/security-reviewer/architect are never downgraded to Haiku. Sonnet mirrors Terra eligibility; Opus mirrors Sol; Fable mirrors Astra.
3. **Availability never escalates tier.** T3 is a capability escalation, not a transport reaction: entering T3 from a fallback requires an explicit, BOUND incapacity proof (kernel-owned `Get-OrchestrationTaskModelFailureProof -RequiredTier T3`, task + policy hash + canonical model/provider). An availability reason or a caller-supplied string never opens T3 (`T3_ESCALATION_REQUIRES_INCAPACITY_PROOF`), and T4/Astra keep their kernel-owned gates. T3/T4 *availability* recovery is same-tier first (Sonnet for T3, Opus for T4) and only then a T2 downgrade for roles admitted to T2.
4. **Gating.** Fable is reachable only as an Astra availability fallback with proved pre-execution evidence (`FailedModel openai/gpt-6-astra` + allowlisted availability `TriggerReason` + explicit `NoExecutionStarted=true` + Astra in the attempted set + local Claude capability proof plus the exact dispatch-alias identity check (`model_id` + `alias`, `resolution_status: runtime-unverified`), honoring `astra.fallback_candidates` order); never as a primary. A raw non-empty `VerifiedFailureReceipt` plus Astra in the attempted set is NOT proof. `VERIFIED_TASK_FAILURE` with a generic receipt never authorizes Fable (the kernel verifies T3/T4 Sol, never Astra). Astra itself still requires kernel-owned verified Sol non-resolution. Ambiguous failure/timeout without `NoExecutionStarted=true` proof means UNKNOWN/`PROOF_ABSENT`: no replay.
5. **No SDK-level retry on top.** Claude Code retries internally: a failed `claude-agent` model is recorded as attempted and the router advances to the next admissible fallback; the same model is never re-run. The test-only `DispatchExecutor` seam still makes EXACTLY ONE call (no retry, no automatic fallback).
6. **Quota accounting.** Subscription metering may report 0; record usage as UNKNOWN cost, never zero (`zero_cost_on_unknown`). `Resolve-ClaudeAgentUsageCost` maps 0/empty/unparseable reports to `UNKNOWN`.
7. **Context-preserving provider switch.** `New-ClaudeAgentProviderSwitchHandoff` builds the switch payload carrying objective, task id and attempt history (payload only, no dispatch).

Provider verification: compare `provider`, `model_id`, and actual executed provider in post-execution evidence. A shared model name never authorizes switching API/account/provider. Keep model access and regional/privacy restrictions enforced by the actual provider.

Provider terms caveat (official Anthropic Agent SDK docs): those docs state that third-party applications offering claude.ai login or claude.ai rate limits require prior approval from Anthropic. The OpenCode docs expose Claude login usage, but this evidence contains no independent Anthropic confirmation for this integration, so account/subscription terms are an operator/vendor-governed risk to monitor — not a legal conclusion.

Official catalogs: https://opencode.ai/v2/docs/console/models/ and https://opencode.ai/v2/docs/console/go/.

## Planner / Tester / Jev

- Planner `build` is stable on `openai/gpt-6-luna` at *operational* T2 using the dedicated `MODEL_PLANNER` token. Do not silently remap Planner to general T2 Muse. The recorded fallback chain is Luna -> `claude-agent/haiku` **only** (T2-only, build-eligible, capability + proved no-start required, exact dispatch-alias identity: `fallback_model_id=claude-agent/haiku` + `fallback_alias=haiku` linked to the entry `model_id`/`alias` with `resolution_status: runtime-unverified`; `fallback_catalog_inventory_id` is local-CLI listing provenance only and is never compared — no concrete mapping is implied); it is reached only on exact canonical Luna failure + allowlisted availability reason + `NoExecutionStarted=true`, otherwise the route exhausts with no generic Muse/DeepSeek substitution, never Sonnet, never T3, never T4. DeepSeek Go is additionally blocked (`ZDR_EXPIRED_UNCONFIRMED`). This route is policy-level until the productive native dispatcher calls it.
- Tester can use deterministic T0, lightweight T1 when eligible, and T2 for LLM-assisted test authoring. T3/T4 are prohibited for Tester.
- Jev remains advisory-only; no ability to grant, select expensive models, mutate task state, or emit DONE.
- `DIRECT_VERIFIED` is *not* no-cost deterministic T0 if the Planner LLM executes the work. Attribute tokens/cost to the Planner model.

## Distinguish transport failure from capability failure

1. Provider/model transport faults (`RATE_LIMIT`, `PROVIDER_ERROR`, `MODEL_UNAVAILABLE`, `MODEL_ERROR`, `SERVICE_UNAVAILABLE`, plus the availability classes `QUOTA_EXCEEDED` and `OFFLINE`) reported by the test-only `DispatchExecutor` seam NEVER authorize retry or fallback. `NoExecutionStarted` received from that seam is an untrusted caller-supplied boolean, NOT proof that no execution started, and a caller-supplied boolean can never prove a negative. The execution wrapper makes exactly ONE dispatch call: a transport-failure signal without an independently observed `Model` yields `PROOF_ABSENT` (`transport-failure-no-proof`, fail-closed hold), never a second call and never `EXECUTED_VERIFIED`. A real pre-dispatch native fallback does not exist yet (HOLD, unimplemented): do not claim any typed safe pre-execution fallback. The widened availability list is Router policy only — it changes no seam behavior and unlocks no retry. Do not retry unknown failures, missing dispatch telemetry or timeouts of ambiguous outcome.
2. T1: Iceman -> MiMo Free (same-tier only; T1 exhaustion never upgrades). T2: Muse -> Luna -> `claude-agent/haiku` (capability + proved no-start), same-tier only: T2 exhaustion never upgrades to Terra/Sol/Astra and returns `EXHAUSTED_NO_ELIGIBLE_FALLBACK`. DeepSeek Go is BLOCKED (`ZDR_EXPIRED_UNCONFIRMED`) and excluded while other admissible routes stay operational.
2b. `FailureCount` never promotes Coder and never changes engineering-advisor: Coder low/simple stays T2 regardless of `FailureCount`, and Coder T3 requires `Complexity=complex` (role policy). engineering-advisor always selects T3 Terra regardless of risk, complexity or `FailureCount` (decision ROUTER-V14-ADVISOR-T3-ONLY). A failed transport resolver only chooses a lower or same-tier model and never executes or retries by itself; retry or escalation requires a new Planner decision with kernel-owned proof.
3. T3/T4 availability recovery is SAME-TIER first (`claude-agent/sonnet` for T3, `claude-agent/opus` for T4, capability + proved no-start), and only then a downgrade to Muse **for roles admitted to T2** (DeepSeek Go BLOCKED and excluded). Availability NEVER escalates tier: entering T3 from a fallback requires an explicit, bound kernel-owned incapacity proof, so Terra/T3 is never picked on a transport reason. A high/critical Reviewer or Security Reviewer must fail closed rather than downgrade quality below its minimum; reviewers are never downgraded to Haiku. engineering-advisor is not admitted to T2 and fails closed instead of downgrading.
4. T3 capability/non-resolution escalation to Sol is allowed ONLY via kernel-owned proof: `Get-OrchestrationTaskModelFailureProof -TaskId <id> -RequiredTier T3` (task-kernel `model-proof`; path flags compat-only, omit to use canonical paths) must return `ok=true` with matching `policy_hash` and canonical T3 Terra `model`/`provider`. Arbitrary `-T3FailureVerified $true` / `-T3FailureReceipt <text>` / `-FailureCount N` / `-VerifiedFailureReceipt <text>` are `DEPRECATED_UNTRUSTED` and never authorize T4. The Planner entry point is read-only `task-kernel model-select` (no dispatch, no session spawn).
5. Sol -> Astra is **not** the transport fallback and is **not** Planner-approved per call. After a persisted failed Sol attempt, the next read-only `task-kernel model-select` (same `TaskId`) returns Astra (`tier` T4, `model` `openai/gpt-6-astra`) automatically when the kernel-owned T4 (Sol) proof for the exact task is valid (`RequiredTier T4`, which itself requires a prior persisted failed T3 proof plus a failed Sol verifier). The T4 proof check runs BEFORE the head T3 proof (the T3 proof lives in `verification_history` once Sol is the head; a current Sol verification never overwrites/erases it). If the T4 proof is absent/invalid, selection is Sol only when the T3 proof is valid, and never T4 when the T3 proof is absent. If Astra is disabled or the role is not in `eligible_roles`, there is no Astra: fail closed to Sol (when a T3/T4 proof warrants T4) or the previous allowed tier, without bypass. Tier/auth stay explicit (`tier` T4, `authorization_source` `AUTO_ROUTER_POLICY_V14`, evidence `policy:t4-verified-failure-gate`), and the receipt exposes the T4 proof `reference`/`digest` (never the older T3 ref as the current Sol failure). Only a kernel-owned T4 proof **plus** `openai/gpt-6.1-sol` in the attempted-model set authorizes Astra via `Resolve-OrchestrationModelFallback`. Arbitrary receipt text never authorizes Astra. `claude-agent/fable` is NOT part of this kernel path: it is the ordered Astra *availability* fallback and needs its own proved pre-execution evidence (canonical Astra `FailedModel` + allowlisted availability reason + `NoExecutionStarted=true` + Astra attempted + Claude capability/alias/role), so a generic kernel receipt never unlocks Fable. Astra remains non-default and its actual spend must be recorded.
6. `EXACT_MATCH` / `AUTHORIZED_FALLBACK` proof is required for verified model identity. `PROOF_ABSENT` is not execution proof and must never mark Task Kernel DONE. Maintain provider identity, attempted model set, policy hash and effective tier in trace. An incapacity claim without kernel-owned proof authorizes no capability escalation, and never unlocks an availability substitute (`T3_ESCALATION_REQUIRES_INCAPACITY_PROOF`, `CLAUDE_AVAILABILITY_REQUIRED`, `FABLE_REQUIRES_ASTRA_FAILURE`).

## Intended target sequence (NOT a productive flow — binding NOT_PROVEN)

The steps below describe the INTENDED target sequence, not the current
productive flow, and prove nothing by themselves. Nothing here is enforced by
the Kernel or by any runtime mechanism: prompt text alone never binds a
selection to a dispatch. The proven API facts in this sequence are that
`task-kernel model-select` is read-only (no dispatch, no session spawn) and
that `task-kernel model-proof` gates T3->Sol / Sol->Astra. Everything between
selection and an executed-model receipt is unproven.

Missing capability (blocks productive use): there is NO G1 binding of the
canonical `model-select` output to the native `subagent` tool call, and NO
trustworthy actual-model event correlated to TaskId + child session + attempt
+ policy hash + receipt. Until that binding and that event exist, productive
execution and the actually executed model stay NOT_PROVEN.

Exact native model arg syntax is `providerID/modelID` (for example
`openai/gpt-6.1-sol`), intended as the native `subagent` tool `model`
property. The CLI and libraries never spawn sessions and never POST to a
runtime API.

1. Commit the task verification profile plan BEFORE any model execution: `task-kernel -Action create -TaskId <id> -Objective <text> ... -VerifierProfiles failer [...]` (plan is immutable; `verify-run` executes exactly the committed plan).
2. Read the selection (no dispatch): `task-kernel -Action model-select -TaskId <id> -AttemptRole coder -Risk medium -ModelComplexity complex [-TaskType implementation] [-RequiresLlm]`. Path flags (`-TasksDir`, `-CliRepoRoot`, `-PolicyPath`, `-FlagsPath`) are compat-only: omit them to use the canonical paths derived from the script; any divergent value returns `TRUSTED_PATH_MISMATCH` before IO, never another store/policy. Returns `tier`, `model` (`providerID/modelID`: Sol `openai/gpt-6.1-sol` on a valid T3 proof, Astra `openai/gpt-6-astra` on a later valid T4 proof), `provider`, `policy_hash`, `policy_version`, `native_model_override_proven` (true only when the CURRENT live local OpenCode server version from bounded read-only `opencode api get /api/info` is exactly in the supported allowlist `2.2.5`/`2.0.23`; TaskKernel `runtime.profile`/`runtime.version` are caller-supplied observability metadata and never authorize the override; unknown/missing live API fails closed with blank `model`/`subagent_model`), and for T4 the kernel `kernel_proof_reference`/`kernel_proof_digest` (T4 ref/digest on the Astra path, never the older T3 ref). Unproven assumption (not a fact): local `/api/info` is assumed to reach the same local OpenCode server that would receive a subsequent native `subagent` call; no session/dispatch-endpoint binding is proven.
3. INTENDED ONLY (unproven, unenforced): dispatch ONE native subagent with the returned `model` value verbatim in the native `subagent` tool `model` property. The refs a future binding would need to correlate are `session:<child>` + `message:<assistant>` from the observed host session/message; today they do not prove which model executed.
4. Record the observation without dispatch: `task-kernel -Action model-attempt -TaskId <id> -SessionId <child> -ExpectedRevision <rev>` (persists exact refs + policy hash; no proof params; path flags compat-only as above).
5. Execute the committed plan against the task repo: `task-kernel -Action verify-run -TaskId <id> -ExpectedRevision <rev>` (trusted kernel-executed marks; caller JSON can never yield proof; path flags compat-only as above).
6. Recompute the gate read-only: `task-kernel -Action model-proof -TaskId <id> -RequiredTier T3|T4` (path flags compat-only as above). T3 proof gates `model-select` T4 (Sol); a later valid T4 proof gates `model-select` T4 (Astra) with priority over the head T3 proof. T4 proof plus attempted Sol gates Astra fallback. `FailureCount`, risk, and receipt text never gate.
7. Test-only `DispatchExecutor` in `Invoke-OrchestrationModelExecution` makes exactly ONE call with no retry and no automatic fallback resolution. A `NoExecutionStarted`/`FailureClass` envelope without an independently observed `Model` is a transport-failure hold (`PROOF_ABSENT` / `transport-failure-no-proof`), never verified execution. Pre-dispatch native fallback is HOLD (unimplemented): keep any native no-child transport failure blocked with no retry. Do not claim T1/T2 fallback E2E from simulations; native real tests are T0-T2 only and do NOT cover fallback (existing real T1/T2 evidence; never rerun paid T3/Sol/Astra).

Role/privacy/cost notes: Planner `build` stays on Luna (T2) with `MODEL_PLANNER`; engineering-advisor always starts at T3 Terra (no T2; Sol/Astra only via existing kernel-owned proof); role minimums (security-reviewer T3+, reviewer high/critical no T2 downgrade, coder/advisor T4 only via kernel proof) and provider namespaces (section above) are unchanged. T4/Astra spend is exceptional and must be recorded. `DIRECT_VERIFIED` is classifier-approved only (preflight trivial + low-risk + `DIRECT_VERIFIED_*` reason) and is Planner LLM cost, not zero-cost T0. Explicit timeout/failure hold: unknown failures, missing dispatch telemetry, and ambiguous timeouts never authorize retry or escalation; fail closed to `PROOF_ABSENT` / `EXHAUSTED_NO_ELIGIBLE_FALLBACK` / `REJECTED_DOWNGRADE_FORBIDDEN`.

## Native dispatch binding: NOT_PROVEN (`model-select` / G1)

Limitation stated once in `Intended target sequence` above: no G1 binding of
the canonical `model-select` output to the native `subagent` call, and no
trustworthy actual-model event correlated to TaskId + session + attempt +
policy hash + receipt — productive execution and the executed model stay
NOT_PROVEN. Do not simulate the binding with test seams, synthetic receipts,
or caller booleans. Escalations T3->Sol and Sol->Astra stay gated exclusively by
kernel-owned proof (`model-proof` T3/T4, policy above), and ambiguous
timeout/failure never authorizes retry or replay.

## DONE gate scope (UNIVERSAL-DONE-VERIFICATION, P0-207)

`Test-OrchestrationTaskCompletion` / `Complete-OrchestrationTask` enforce
`verification-not-kernel-executed` (plus `verification-untrusted`) for EVERY
Kernel-managed task. DONE requires `verification.status='verified_pass'`
plus `verification_source='kernel-executed'` AND `source='kernel-executed'`
with `verifier_executed=true`, `passed=true` and full criterion coverage
(written only by `Invoke-TaskKernelVerifyRun` against the committed plan);
caller-supplied JSON (`Set-OrchestrationTaskVerification`,
`verification_source='caller-supplied'`) stays readable as UNTRUSTED input
but never completes DONE, and `Complete` returns `COMPLETION_GATE_FAILED`
with no state/revision mutation. The pre-v1.4 caller-supplied completion
contract for plan-less legacy tasks is REMOVED: there is no legacy
exception. A plan-less legacy task lacking an existing valid kernel-executed
proof remains blocked with the concrete existing reasons
(`verification-not-kernel-executed` plus `verification-untrusted`):
caller-supplied input cannot create new trusted proof, and no fresh
`Invoke-TaskKernelVerifyRun` is possible without the committed plan (no
migration or rebind). Such records stay preserved for reading and history
(verification, caller evidence and history remain queryable); the API never
fabricates a plan, a marker, or synthetic proof for them, and ambiguous
timeouts never replay into completion. If an already trustworthy
kernel-executed proof exists on the record, the existing universal gate may
accept it. The remaining gate preconditions are unchanged (candidate_pass, criterion
evidence, review, risk/security, blockers, budgets, watchdog settlement).
No caller-supplied marks ever create T3/T4 proof:
`Get-OrchestrationTaskModelFailureProof` still requires a committed plan
plus kernel-executed marks. The `completion_verification_contract` marker,
when present on older records, is inert provenance, not a gate input.

## Deterministic tests (no inference)

```powershell
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterKernelProof.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterV14.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterClaudeAgent.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterFableGate.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationNativePilotHardening.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouter.tests.ps1
powershell -NoProfile -File tests/v3/OrchestrationDynamicModelRoutingV11.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelExecution.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRoutingEtapa4.tests.ps1
```

## Integration caution

There is NO typed safe pre-execution fallback in `Invoke-OrchestrationModelExecution` (HOLD, unimplemented): no native retry occurs and no caller-supplied `NoExecutionStarted` envelope authorizes one. The v1.4 native fallback requirement stays blocked until a runtime/Kernel-produced no-start receipt can be independently verified and correlated to the request. A caught exception, caller boolean, or unverified typed envelope never authorizes retry. The Task Kernel / full-delivery caller must supply proven T3 and Sol non-resolution receipts for capability escalations. Do not claim end-to-end availability until a real OpenCode V2 dispatch, post-execution model identity and durable task settlement have been demonstrated.
