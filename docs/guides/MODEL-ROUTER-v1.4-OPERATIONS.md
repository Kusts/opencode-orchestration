# Model Router v1.4 — execution and fallback contract

## Canonical mapping

| Tier | Primary | Fallback(s) | Notes |
|---|---|---|---|
| T0 | No LLM | — | Scripts, AST and deterministic checks only |
| T1 | `opencode-go/iceman-contributor-free` | `opencode/mimo-v2.6-flash-free` | OpenCode Console free offers may expire; same-tier only, never upgrades to higher tier |
| T2 | `opencode-go/muse-spark-1.3-contributor` | `claude-agent/haiku` (capability + proved no-start required), then `openai/gpt-6-luna` | Static candidate order only: Muse -> Haiku -> Luna; productive fallback is HOLD. Transport exhaustion never upgrades to higher tier. Planner `build` is Luna T2 fixed (no automatic build fallback configured). |
| T3 | `claude-agent/sonnet` | Candidate order: `openai/gpt-6.1-terra`, then Muse/DeepSeek only for roles admissible to T2 | Sonnet/Terra are static candidates, not executable availability fallbacks; productive transport routing is HOLD. A verified functional failure of executed Sonnet may authorize T4 Opus via the Task Kernel. Engineering-advisor remains T3-only (no T2). DeepSeek Go remains BLOCKED (`ZDR_EXPIRED_UNCONFIRMED`). |
| T4 | `claude-agent/opus` | Candidate order: `openai/gpt-6.1-sol`; Astra exceptional after kernel-owned Opus failure proof; Fable remains HOLD pending model-specific proof | Opus/Sol are static candidates, not executable transport fallback. T4 selection follows verified T3 proof without manual per-call approval. Astra/Fable retain exceptional proof gates. Availability never escalates tier. |

DeepSeek V4.1 Flash via OpenCode Go (`opencode-go/deepseek-v4.1-flash`) is BLOCKED as of 2026-11-04: public Go docs show a ZDR agreement valid only through 2026-10-31 and renewal is unconfirmed; the router excludes it (`MODEL_DISABLED`, `ZDR_EXPIRED_UNCONFIRMED`) while other admissible routes remain operational. The entry is kept for provenance. Honor the effective model data policy and workspace privacy restrictions.

## Provider namespace: do not infer it from price

The routing policy binds **four OpenAI models** directly to the `openai/` provider: Luna (`openai/gpt-6-luna`), Terra (`openai/gpt-6.1-terra`), Sol (`openai/gpt-6.1-sol`) and Astra (`openai/gpt-6-astra`). Do not silently substitute an OpenCode-hosted copy of these models.

The free MiMo fallback belongs to the **OpenCode Console free** provider (`opencode/mimo-v2.6-flash-free`). Despite its *Free* pricing label, Iceman Contributor Free is listed by OpenCode under **OpenCode Go** (`opencode-go/iceman-contributor-free`), not `opencode/`. Muse Spark 1.3 Contributor (`opencode-go/muse-spark-1.3-contributor`) also uses **OpenCode Go**. The disabled legacy `opencode/deepseek-v4.1-flash-free` must not become an implicit fallback. The blocked `opencode-go/deepseek-v4.1-flash` must not become an implicit fallback either.

## Claude Agent provider (`claude-agent`, subscription)

Four dispatch aliases are registered in the single policy file and the dispatch ID **is** the alias itself: `claude-agent/haiku` (T2), `claude-agent/sonnet` (T3), `claude-agent/opus` (T4) and `claude-agent/fable` (T4, gated). Each entry additionally records `catalog_inventory_id` — an exact ID merely LISTED in the local `opencode models` CLI inventory — strictly as catalog listing/provenance: the policy publishes **no** alias->concrete mapping, carries **no** `resolved_model` field, and the router never compares `catalog_inventory_id`.

Catalog observation (local `claude-agent`): ids `claude-agent/sonnet`, `claude-agent/opus`, `claude-agent/haiku`, `claude-agent/fable` display names Sonnet 5.5, Opus 5.5, Haiku 5.5, Fable 5.1; all `released=0`, `cost=[]`. Other versioned IDs exist in the same provider but are not proof of mapping from short aliases. **Resolution remains `runtime-unverified`**; do not assert pin or concrete version from catalog alone. A Haiku response must not be treated as proof of an operational pass for Sonnet/Opus routing — routes may be candidates in policy but concrete version is unproven and no Sonnet/Opus inference was executed to test.

Router validation is limited to the closed dispatch-alias map (`model_id` + `alias`, case-sensitive), failing closed with `CLAUDE_UNKNOWN_ALIAS` / `CLAUDE_ALIAS_MISSING` / `CLAUDE_MODEL_ID_MISSING` / `CLAUDE_ALIAS_MISMATCH` on any tamper. Alias-to-concrete runtime resolution therefore stays UNRESOLVED (`resolution_status: runtime-unverified`); if a session event ever reports a concrete ID, post-execution verification must stay `PROOF_ABSENT` / `UNAUTHORIZED_MISMATCH` until the mapping is independently proven — never `EXACT_MATCH` or `AUTHORIZED_FALLBACK` off an unverified ID. Record the alias and the listed inventory ID on every use (the ID as provenance only); never invent other concrete models. Each alias lists effort variants `low`/`medium`/`high`/`xhigh`/`max` as catalog metadata only. Aliases stay selectable only while the policy's fail-closed dispatch-alias identity check is satisfied; static tests assert the recorded alias identity and gating, never actual version resolution.

1. **Claude capability and aliases.** The `claude-agent` provider is reject-closed without local authenticated `claude` capability (or explicit remote capability). Catalog labels do not prove immutable wire model IDs: aliases remain `runtime-unverified`. Capability can filter a candidate, but does not authorize execution.
2. **Fallback HOLD.** The resolver enumerates ordered candidates for audit only; it returns `CandidateModel` as non-authorizing with `FallbackModel=null` and `IsAuthorized=false`. Caller-supplied `NoExecutionStarted` booleans, allowlisted transport classes and catalog presence are not independent proof that an operation did not start. Productive availability fallback remains HOLD for every tier; ambiguous failures/timeouts never replay.
3. **Role admissibility and functional proof.** Researcher/Explorer/Docs Manager start at T1 and may escalate to T2; Tester uses deterministic T0, simple LLM T1 and non-trivial LLM T2. These roles do not use T3/T4 automatically. Engineering-advisor is T3 minimum (Sonnet primary, Terra candidate), and T2 is prohibited. Functional T3 escalation requires a sticky Task Kernel proof for the executed Sonnet primary; T4 proof is for executed Opus and requires prior T3 proof.
4. **Exceptional capacity.** Astra is selected only after a valid Task Kernel proof for Opus and role/policy admissibility. Fable remains HOLD: current persisted proof is primary-tier-bound and does not establish a model-specific failed Astra attempt. Do not convert a generic receipt or availability signal into Astra/Fable incapacity proof.
5. **Single-call execution.** `Invoke-OrchestrationModelExecution` makes exactly ONE call; missing or ambiguous execution evidence yields `PROOF_ABSENT`. The router adds no retry and authorizes no transport fallback. Only the canonical `task-kernel model-select` path can consume functional failure proof.
6. **Quota accounting.** Subscription metering may report 0; record usage as UNKNOWN cost, never zero (`zero_cost_on_unknown`). `Resolve-ClaudeAgentUsageCost` maps 0/empty/unparseable reports to `UNKNOWN`.
7. **Context-preserving provider switch.** `New-ClaudeAgentProviderSwitchHandoff` builds the switch payload carrying objective, task id and attempt history (payload only, no dispatch).

Provider verification: compare `provider`, `model_id`, and actual executed provider in post-execution evidence. A shared model name never authorizes switching API/account/provider. Keep model access and regional/privacy restrictions enforced by the actual provider.

Official catalogs: https://opencode.ai/v2/docs/console/models/ and https://opencode.ai/v2/docs/console/go/.

## Planner / Tester / Jev

- Planner `build` is pinned to `openai/gpt-6-luna` at T2 (fixed). No automatic fallback for build is configured. The global runtime model remains Luna and `agents.build.model` is Luna; other agents do not inherit Haiku. The Planner is the `build` session itself (root run). Workers are native child sessions of that root. Review and DONE stay Planner-owned. The `opencode run` dispatcher was removed; the default route is refused as ROUTE_BLOCKED_ROOT_SESSION because a root session cannot be attributed by the kernel.
- Researcher/Explorer/Docs Manager start at T1; T2 may be escalated when required. Tester uses T0 for deterministic work, T1 for LLM trivial/simple work, T2 for non-trivial test work requiring capacity. None of these four use T3/T4 automatically. Engineering-advisor has minimum T3 (Sonnet primary/Terra fallback), T2 is prohibited.
- Jev remains advisory-only; no ability to grant, select expensive models, mutate task state, or emit DONE.
- `DIRECT_VERIFIED` is *not* no-cost deterministic T0 if the Planner LLM executes the work. Attribute tokens/cost to the Planner model.

## Distinguish transport failure from capability failure

1. Provider/model transport faults (`RATE_LIMIT`, `PROVIDER_ERROR`, `MODEL_UNAVAILABLE`, `MODEL_ERROR`, `SERVICE_UNAVAILABLE`, plus the availability classes `QUOTA_EXCEEDED` and `OFFLINE`) reported by the test-only `DispatchExecutor` seam NEVER authorize retry or fallback. `NoExecutionStarted` received from that seam is an untrusted caller-supplied boolean, NOT proof that no execution started, and a caller-supplied boolean can never prove a negative. The execution wrapper makes exactly ONE dispatch call: a transport-failure signal without an independently observed `Model` yields `PROOF_ABSENT` (`transport-failure-no-proof`, fail-closed hold), never a second call and never `EXECUTED_VERIFIED`. OpenCode 2.2.5 exposes no automatic primary-model fallback that this package relies on. A Luna Planner is a manual configuration change, never a runtime retry. Do not retry unknown failures, missing dispatch telemetry or timeouts of ambiguous outcome.
   - **Fallback resolver (audit/HOLD):** `Resolve-OrchestrationModelFallback` only enumerates candidate order for audit and returns HOLD with `CandidateModel` non-authorizing, `FallbackModel = null`, `IsAuthorized = false`. No-start booleans and errors/timeouts are untrusted; without independent proof there is no replay. `Invoke-OrchestrationModelExecution` follows single-call only. Productive fallback capacity remains HOLD until reliable proof of no-start exists. A deterministic matrix test may report candidate order but performs no dispatch.
2. T1 Iceman -> MiMo; T2 Muse -> Haiku -> Luna are ordered policy candidates. Technical fallback resolver is audit/HOLD only and does not replay. T1/T2 transport exhaustion never upgrades to a higher tier. DeepSeek Go remains BLOCKED (`ZDR_EXPIRED_UNCONFIRMED`).
2b. `FailureCount` never promotes Coder or engineering-advisor. Coder low/simple stays T2 and complex work selects T3 by role policy. Engineering-advisor is T3 Sonnet primary with Terra candidate, T2 prohibited. The fallback resolver never executes or retries; a functional escalation requires Task Kernel proof.
3. T3 Sonnet -> Terra and T4 Opus -> Sol are static candidate orders/HOLD for transport; neither transport class proves incapacity or authorizes a substitute. T3 capability failure proof is bound to the executed Sonnet primary. T2 downgrade candidates (Muse/DeepSeek) are audit-only and restricted to T2-admissible roles; DeepSeek remains blocked. Reviewers/security fail closed below their minimums; engineering-advisor never uses T2.
4. T3 primary Sonnet -> T4 primary Opus is allowed ONLY via kernel-owned proof: `Get-OrchestrationTaskModelFailureProof -TaskId <id> -RequiredTier T3` must return `ok=true` with matching `policy_hash` and canonical primary Sonnet model/provider. The proof is for the executed tier primary, not a transport candidate. Arbitrary `-T3FailureVerified`, receipts, `FailureCount` or caller text are `DEPRECATED_UNTRUSTED`. The Planner entry point is read-only `task-kernel model-select`.
5. A kernel-owned T4 proof for the executed Opus primary, plus prior T3 proof, allows `task-kernel model-select` to choose Astra when policy/role allow; no per-call manual approval is required. Astra/Fable retain their exceptional gates. Fable remains HOLD because current proof binds to the tier primary and no model-specific failed Astra attempt is available. The Kernel checks T4 proof before prior T3 history so the sticky chain is preserved. Astra remains non-default and actual spend must be recorded.
6. `EXACT_MATCH` / `AUTHORIZED_FALLBACK` proof is required for verified model identity. `PROOF_ABSENT` is not execution proof and must never mark Task Kernel DONE. Maintain provider identity, attempted model set, policy hash and effective tier in trace.

## Kernel-owned flow (Planner-mediated, no parallel executor/plugin/API)

Exact native model arg syntax is `providerID/modelID` (for example `openai/gpt-6.1-sol`), passed as the native `subagent` tool `model` property by the Planner. The CLI and libraries never spawn sessions and never POST to a runtime API.

**Only the `task-kernel model-select` path with proven Task Kernel sticky proof authorizes escalation.** T3 proof uses primary `claude-agent/sonnet`; T4 proof uses primary `claude-agent/opus` and requires a prior T3 proof. Astra/Fable keep exceptional proof gates. The Kernel proves via verify-run `kernel-executed` with model/provider/session/message/run/policy hash.

1. Commit the task verification profile plan BEFORE any model execution: `task-kernel -Action create -TaskId <id> -Objective <text> ... -VerifierProfiles failer [...]` (plan is immutable; `verify-run` executes exactly the committed plan).
2. Planner reads the selection (no dispatch): `task-kernel -Action model-select -TaskId <id> -AttemptRole coder -Risk medium -ModelComplexity complex [-TaskType implementation] [-RequiresLlm]`. Path flags (`-TasksDir`, `-CliRepoRoot`, `-PolicyPath`, `-FlagsPath`) are compat-only: omit them to use the canonical paths derived from the script; any divergent value returns `TRUSTED_PATH_MISMATCH` before IO, never another store/policy. Returns `tier`, `model` (`providerID/modelID`: T4 Opus on a valid T3 primary-failure proof, Astra on a later valid T4 Opus-failure proof), `provider`, `policy_hash`, `policy_version`, `native_model_override_proven` (true only when the CURRENT live local OpenCode server version from bounded read-only `opencode api get /api/info` is exactly in the supported allowlist `2.2.5`/`2.0.23`; TaskKernel `runtime.profile`/`runtime.version` are caller-supplied observability metadata and never authorize the override; unknown/missing live API fails closed with blank `model`/`subagent_model`), and for T4 the kernel `kernel_proof_reference`/`kernel_proof_digest` (T4 ref/digest on the Astra path, never the older T3 ref). Residual assumption: local `/api/info` reaches the same local OpenCode server that receives the Planner's subsequent native `subagent` call; no session/dispatch-endpoint binding is proven.
3. Planner dispatches ONE native subagent with the returned `model` value verbatim in the native `subagent` tool `model` property. Record required evidence refs `session:<child>` + `message:<assistant>` from the observed host session/message.
4. Record the observation without dispatch: `task-kernel -Action model-attempt -TaskId <id> -SessionId <child> -ExpectedRevision <rev>` (persists exact refs + policy hash; no proof params; path flags compat-only as above).
5. Execute the committed plan against the task repo: `task-kernel -Action verify-run -TaskId <id> -ExpectedRevision <rev>` (trusted kernel-executed marks; caller JSON can never yield proof; path flags compat-only as above).
6. Recompute the gate read-only: `task-kernel -Action model-proof -TaskId <id> -RequiredTier T3|T4` (path flags compat-only as above). T3 proof is bound to the executed Sonnet primary and gates `model-select` T4 (Opus); a later valid T4 proof is bound to the executed Opus primary and may select Astra with priority over the head T3 proof. This proves primary incapability only; it does not prove a fallback model failed. `FailureCount`, risk, and receipt text never gate.
7. Test-only `DispatchExecutor` in `Invoke-OrchestrationModelExecution` makes exactly ONE call with no retry and no automatic fallback resolution. A `NoExecutionStarted`/`FailureClass` envelope without an independently observed `Model` is a transport-failure hold (`PROOF_ABSENT` / `transport-failure-no-proof`), never verified execution. Pre-dispatch native fallback is HOLD (unimplemented): keep any native no-child transport failure blocked with no retry. Do not claim T1/T2 fallback E2E from simulations; native real tests are T0-T2 only and do NOT cover fallback (existing real T1/T2 evidence; never rerun paid T3/Sol/Astra).

Role/privacy/cost notes: Planner `build` stays on Luna (T2) with `MODEL_PLANNER`; engineering-advisor is T3 Sonnet primary, Terra candidate, T2 prohibited. Reviewer high/critical and Security Reviewer cannot downgrade to T2. Researcher/Explorer/Docs Manager start T1; Tester preserves T0 and uses T1/T2 as needed, with no automatic T3/T4 route. T4/Opus follows verified T3 primary failure without per-call approval; Astra is exceptional and its actual spend must be recorded. `DIRECT_VERIFIED` is classifier-approved only (preflight trivial + low-risk + `DIRECT_VERIFIED_*` reason) and is Planner LLM cost, not zero-cost T0. Unknown failures, missing dispatch telemetry and ambiguous timeouts never authorize retry or escalation; fail closed. The candidate matrix is static policy, not executable availability fallback.

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
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterHaikuPlanner.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouter.tests.ps1
powershell -NoProfile -File tests/v3/OrchestrationDynamicModelRoutingV11.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelExecution.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRoutingEtapa4.tests.ps1
```

**Current test evidence (observed):** `test-package-consistency` 16/16; `OrchestrationModelRouterMatrix` 35/35; `OrchestrationModelRouter` 107/107; V14 60/60; `OrchestrationModelRouterHaikuPlanner` 52/52 (legacy filename; suite now holds alias+HOLD semantics); `OrchestrationModelRouterModelConfig` 36/36; Kernel `OrchestrationTaskKernelModelProof` 104/104; `OrchestrationModelExecution` 36/36; `OrchestrationModelRouterKernelProof` 7/7. These counts are reported as current evidence/state; do **not** claim they all ran against the final integrated head unless code unchanged—final revalidation is pending. A deterministic matrix test reports candidate order but performs no dispatch.

## Integration caution

There is NO typed safe pre-execution fallback in `Invoke-OrchestrationModelExecution` (HOLD, unimplemented): no native retry occurs and no caller-supplied `NoExecutionStarted` envelope authorizes one. The v1.4 native fallback requirement stays blocked until a runtime/Kernel-produced no-start receipt can be independently verified and correlated to the request. A caught exception, caller boolean, or unverified typed envelope never authorizes retry. The Task Kernel / full-delivery caller must supply proven T3 and Sol non-resolution receipts for capability escalations. Do not claim end-to-end availability until a real OpenCode V2 dispatch, post-execution model identity and durable task settlement have been demonstrated.
