# Model Router v1.4 — execution and fallback contract

## Canonical mapping

| Tier | Primary | Fallback(s) | Notes |
|---|---|---|---|
| T0 | No LLM | — | Scripts, AST and deterministic checks only |
| T1 | `opencode-go/iceman-contributor-free` | `opencode/mimo-v2.6-flash-free` | OpenCode Console free offers may expire |
| T2 | `opencode-go/muse-spark-1.3-contributor` | `openai/gpt-6-luna` | Planner is pinned to Luna but classified T2 |
| T3 | `openai/gpt-6.1-terra` | `opencode-go/muse-spark-1.3-contributor`, then `opencode-go/deepseek-v4.1-flash` | Fallback to T2 is a degraded transport recovery, not equivalent capability |
| T4 | `openai/gpt-6.1-sol` | `openai/gpt-6-astra` on verified Sol non-resolution; Muse/DeepSeek Go on transport outage | No per-call T4 cost authorization; requires verified T3 failure |

The OpenCode Console free DeepSeek is a separate endpoint (`opencode/deepseek-v4.1-flash-free`). The requested v1.4 fallback uses the **Go** endpoint and is not a free-model claim. Muse Contributor and Iceman Contributor may submit request content for training under their service terms. Honor the effective model data policy and workspace privacy restrictions.

## Provider namespace: do not infer it from price

The routing policy binds **four OpenAI models** directly to the `openai/` provider: Luna (`openai/gpt-6-luna`), Terra (`openai/gpt-6.1-terra`), Sol (`openai/gpt-6.1-sol`) and Astra (`openai/gpt-6-astra`). Do not silently substitute an OpenCode-hosted copy of these models.

The free MiMo fallback belongs to the **OpenCode Console free** provider (`opencode/mimo-v2.6-flash-free`). Despite its *Free* pricing label, Iceman Contributor Free is listed by OpenCode under **OpenCode Go** (`opencode-go/iceman-contributor-free`), not `opencode/`. Muse Spark 1.3 Contributor (`opencode-go/muse-spark-1.3-contributor`) and DeepSeek V4.1 Flash (`opencode-go/deepseek-v4.1-flash`) also use **OpenCode Go**. The disabled legacy `opencode/deepseek-v4.1-flash-free` must not become an implicit fallback.

Provider verification: compare `provider`, `model_id`, and actual executed provider in post-execution evidence. A shared model name never authorizes switching API/account/provider. Keep model access and regional/privacy restrictions enforced by the actual provider.

Official catalogs: https://opencode.ai/v2/docs/console/models/ and https://opencode.ai/v2/docs/console/go/.

## Planner / Tester / Jev

- Planner `build` is stable on `openai/gpt-6-luna` at *operational* T2 using the dedicated `MODEL_PLANNER` token. Do not silently remap Planner to general T2 Muse.
- Tester can use deterministic T0, lightweight T1 when eligible, and T2 for LLM-assisted test authoring. T3/T4 are prohibited for Tester.
- Jev remains advisory-only; no ability to grant, select expensive models, mutate task state, or emit DONE.
- `DIRECT_VERIFIED` is *not* no-cost deterministic T0 if the Planner LLM executes the work. Attribute tokens/cost to the Planner model.

## Distinguish transport failure from capability failure

1. Provider/model transport faults (`RATE_LIMIT`, `PROVIDER_ERROR`, `MODEL_UNAVAILABLE`, `MODEL_ERROR`, `SERVICE_UNAVAILABLE`) reported by the test-only `DispatchExecutor` seam NEVER authorize retry or fallback. `NoExecutionStarted` received from that seam is an untrusted caller-supplied boolean, NOT proof that no execution started, and a caller-supplied boolean can never prove a negative. The execution wrapper makes exactly ONE dispatch call: a transport-failure signal without an independently observed `Model` yields `PROOF_ABSENT` (`transport-failure-no-proof`, fail-closed hold), never a second call and never `EXECUTED_VERIFIED`. A real pre-dispatch native fallback does not exist yet (HOLD, unimplemented): do not claim any typed safe pre-execution fallback. Do not retry unknown failures, missing dispatch telemetry or timeouts of ambiguous outcome.
2. T1: Iceman -> MiMo Free (same-tier only; T1 exhaustion never upgrades). T2: Muse -> Luna, then eligible Go fallback when appropriate (same-tier only; T2 exhaustion never upgrades to Terra/Sol/Astra and returns `EXHAUSTED_NO_ELIGIBLE_FALLBACK`).
2b. `FailureCount` never promotes Coder and never changes engineering-advisor: Coder low/simple stays T2 regardless of `FailureCount` and Coder T3 requires `Complexity=complex` (role policy); engineering-advisor ALWAYS selects T3 Terra regardless of risk/complexity/`FailureCount` (explicit decision ROUTER-V14-ADVISOR-T3-ONLY; T2 Muse is ineligible per `muse.eligible_roles` and diverges from `role_profiles` default_model=terra/default_tier=T3). A failed transport resolver only chooses a lower (degraded T3/T4 -> admitted T2) or same-tier model and never executes or retries by itself; retry/escalation requires a new Planner decision with kernel-owned proof.
3. T3/T4 transport recovery may downgrade to Muse, then DeepSeek Go **only for roles admitted to T2**. engineering-advisor is NOT admitted to T2 and fails closed instead of downgrading; a high/critical Reviewer or Security Reviewer must fail closed rather than downgrade quality below its minimum.
4. T3 capability/non-resolution escalation to Sol is allowed ONLY via kernel-owned proof: `Get-OrchestrationTaskModelFailureProof -TaskId <id> -RequiredTier T3` (task-kernel `model-proof`; path flags compat-only, omit to use canonical paths) must return `ok=true` with matching `policy_hash` and canonical T3 Terra `model`/`provider`. Arbitrary `-T3FailureVerified $true` / `-T3FailureReceipt <text>` / `-FailureCount N` / `-VerifiedFailureReceipt <text>` are `DEPRECATED_UNTRUSTED` and never authorize T4. The Planner entry point is read-only `task-kernel model-select` (no dispatch, no session spawn).
5. Sol -> Astra is **not** the transport fallback and is **not** Planner-approved per call. After a persisted failed Sol attempt, the next read-only `task-kernel model-select` (same `TaskId`) returns Astra (`tier` T4, `model` `openai/gpt-6-astra`) automatically when the kernel-owned T4 (Sol) proof for the exact task is valid (`RequiredTier T4`, which itself requires a prior persisted failed T3 proof plus a failed Sol verifier). The T4 proof check runs BEFORE the head T3 proof (the T3 proof lives in `verification_history` once Sol is the head; a current Sol verification never overwrites/erases it). If the T4 proof is absent/invalid, selection is Sol only when the T3 proof is valid, and never T4 when the T3 proof is absent. If Astra is disabled or the role is not in `eligible_roles`, there is no Astra: fail closed to Sol (when a T3/T4 proof warrants T4) or the previous allowed tier, without bypass. Tier/auth stay explicit (`tier` T4, `authorization_source` `AUTO_ROUTER_POLICY_V14`, evidence `policy:t4-verified-failure-gate`), and the receipt exposes the T4 proof `reference`/`digest` (never the older T3 ref as the current Sol failure). Only a kernel-owned T4 proof **plus** `openai/gpt-6.1-sol` in the attempted-model set authorizes Astra via `Resolve-OrchestrationModelFallback`. Arbitrary receipt text never authorizes Astra. Astra remains non-default and its actual spend must be recorded.
6. `EXACT_MATCH` / `AUTHORIZED_FALLBACK` proof is required for verified model identity. `PROOF_ABSENT` is not execution proof and must never mark Task Kernel DONE. Maintain provider identity, attempted model set, policy hash and effective tier in trace.

## Kernel-owned flow (Planner-mediated, no parallel executor/plugin/API)

Exact native model arg syntax is `providerID/modelID` (for example `openai/gpt-6.1-sol`), passed as the native `subagent` tool `model` property by the Planner. The CLI and libraries never spawn sessions and never POST to a runtime API.

1. Commit the task verification profile plan BEFORE any model execution: `task-kernel -Action create -TaskId <id> -Objective <text> ... -VerifierProfiles failer [...]` (plan is immutable; `verify-run` executes exactly the committed plan).
2. Planner reads the selection (no dispatch): `task-kernel -Action model-select -TaskId <id> -AttemptRole coder -Risk medium -ModelComplexity complex [-TaskType implementation] [-RequiresLlm]`. Path flags (`-TasksDir`, `-CliRepoRoot`, `-PolicyPath`, `-FlagsPath`) are compat-only: omit them to use the canonical paths derived from the script; any divergent value returns `TRUSTED_PATH_MISMATCH` before IO, never another store/policy. Returns `tier`, `model` (`providerID/modelID`: Sol `openai/gpt-6.1-sol` on a valid T3 proof, Astra `openai/gpt-6-astra` on a later valid T4 proof), `provider`, `policy_hash`, `policy_version`, `native_model_override_proven` (true only when the CURRENT live local OpenCode server version from bounded read-only `opencode api get /api/info` is exactly in the supported allowlist `2.2.5`/`2.0.23`; TaskKernel `runtime.profile`/`runtime.version` are caller-supplied observability metadata and never authorize the override; unknown/missing live API fails closed with blank `model`/`subagent_model`), and for T4 the kernel `kernel_proof_reference`/`kernel_proof_digest` (T4 ref/digest on the Astra path, never the older T3 ref). Residual assumption: local `/api/info` reaches the same local OpenCode server that receives the Planner's subsequent native `subagent` call; no session/dispatch-endpoint binding is proven.
3. Planner dispatches ONE native subagent with the returned `model` value verbatim in the native `subagent` tool `model` property. Record required evidence refs `session:<child>` + `message:<assistant>` from the observed host session/message.
4. Record the observation without dispatch: `task-kernel -Action model-attempt -TaskId <id> -SessionId <child> -ExpectedRevision <rev>` (persists exact refs + policy hash; no proof params; path flags compat-only as above).
5. Execute the committed plan against the task repo: `task-kernel -Action verify-run -TaskId <id> -ExpectedRevision <rev>` (trusted kernel-executed marks; caller JSON can never yield proof; path flags compat-only as above).
6. Recompute the gate read-only: `task-kernel -Action model-proof -TaskId <id> -RequiredTier T3|T4` (path flags compat-only as above). T3 proof gates `model-select` T4 (Sol); a later valid T4 proof gates `model-select` T4 (Astra) with priority over the head T3 proof. T4 proof plus attempted Sol gates Astra fallback. `FailureCount`, risk, and receipt text never gate.
7. Test-only `DispatchExecutor` in `Invoke-OrchestrationModelExecution` makes exactly ONE call with no retry and no automatic fallback resolution. A `NoExecutionStarted`/`FailureClass` envelope without an independently observed `Model` is a transport-failure hold (`PROOF_ABSENT` / `transport-failure-no-proof`), never verified execution. Pre-dispatch native fallback is HOLD (unimplemented): keep any native no-child transport failure blocked with no retry. Do not claim T1/T2 fallback E2E from simulations; native real tests are T0-T2 only and do NOT cover fallback (existing real T1/T2 evidence; never rerun paid T3/Sol/Astra).

Role/privacy/cost notes: Planner `build` stays on Luna (T2) with `MODEL_PLANNER`; engineering-advisor always starts at T3 Terra (no T2; Sol/Astra only via existing kernel-owned proof); role minimums (security-reviewer T3+, reviewer high/critical no T2 downgrade, coder/advisor T4 only via kernel proof) and provider namespaces (section above) are unchanged. T4/Astra spend is exceptional and must be recorded. `DIRECT_VERIFIED` is classifier-approved only (preflight trivial + low-risk + `DIRECT_VERIFIED_*` reason) and is Planner LLM cost, not zero-cost T0. Explicit timeout/failure hold: unknown failures, missing dispatch telemetry, and ambiguous timeouts never authorize retry or escalation; fail closed to `PROOF_ABSENT` / `EXHAUSTED_NO_ELIGIBLE_FALLBACK` / `REJECTED_DOWNGRADE_FORBIDDEN`.

## DONE gate scope (ROUTER-V14-SCOPED-DONE-VERIFICATION)

`Test-OrchestrationTaskCompletion` / `Complete-OrchestrationTask` enforce
`verification-not-kernel-executed` ONLY for scoped tasks: the task carries a
committed non-empty `verification_profiles` plan OR any persisted
`model_attempts` (Router v1.4 proof-capable path). Creation stores a sticky
`completion_verification_contract='router-v1.4-kernel'` marker for a planned
task; the first Kernel-recorded model attempt sets the same marker. Clearing
the current plan/attempt arrays through an out-of-band edit therefore does
not reclassify a marked task as legacy. For those tasks DONE
requires `verification.status='verified_pass'` plus
`verification_source='kernel-executed'` and `verifier_executed=true`
(written only by `Invoke-TaskKernelVerifyRun`); caller-supplied JSON
(`Set-OrchestrationTaskVerification`, `verification_source='caller-supplied'`)
never completes DONE and `Complete` returns `COMPLETION_GATE_FAILED` with no
state/revision mutation. Plan-less tasks with no `model_attempts` keep the
pre-v1.4 completion contract for backward compatibility (caller `Set` result
may remain sufficient for DONE). Both paths still require the remaining gate
(candidate_pass, criterion evidence, review, risk/security, blockers,
budgets, watchdog settlement). No caller-supplied marks ever create T3/T4
proof: `Get-OrchestrationTaskModelFailureProof` still requires a committed
plan plus kernel-executed marks. The marker is Kernel-store provenance, not a
cryptographic integrity seal: direct edits to trusted local task files remain
outside the caller/API threat boundary, as with other persisted Kernel fields.

## Deterministic tests (no inference)

```powershell
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterKernelProof.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterV14.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouter.tests.ps1
powershell -NoProfile -File tests/v3/OrchestrationDynamicModelRoutingV11.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelExecution.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRoutingEtapa4.tests.ps1
```

## Integration caution

There is NO typed safe pre-execution fallback in `Invoke-OrchestrationModelExecution` (HOLD, unimplemented): no native retry occurs and no caller-supplied `NoExecutionStarted` envelope authorizes one. The v1.4 native fallback requirement stays blocked until a runtime/Kernel-produced no-start receipt can be independently verified and correlated to the request. A caught exception, caller boolean, or unverified typed envelope never authorizes retry. The Task Kernel / full-delivery caller must supply proven T3 and Sol non-resolution receipts for capability escalations. Do not claim end-to-end availability until a real OpenCode V2 dispatch, post-execution model identity and durable task settlement have been demonstrated.
