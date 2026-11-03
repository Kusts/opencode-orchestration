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

1. Provider/model transport faults (`RATE_LIMIT`, `PROVIDER_ERROR`, `MODEL_UNAVAILABLE`, `MODEL_ERROR`, `SERVICE_UNAVAILABLE`) may trigger fallback **only after the dispatcher asserts `NoExecutionStarted=true`** with an explicit `FailureClass`. The execution wrapper retries up to four total dispatch attempts, never previously attempted models. Do not automatically retry unknown failures, missing dispatch telemetry or timeouts of ambiguous outcome.
2. T1: Iceman -> MiMo Free. T2: Muse -> Luna, then eligible Go fallback when appropriate.
3. T3/T4 transport recovery may downgrade to Muse, then DeepSeek Go **only for roles admitted to T2**. A high/critical Reviewer or Security Reviewer must fail closed rather than downgrade quality below its minimum.
4. T3 capability/non-resolution escalation to Sol is allowed without manual T4 approval only when the caller passes `-T3FailureVerified $true -T3FailureReceipt <receipt>`. The controlling Task Kernel must verify the persisted receipt for the specific task and selected T3 model, not infer this from retry count, risk, subjective model output, or a blank string.
5. Sol -> Astra is **not** the transport fallback. Only `Resolve-OrchestrationModelFallback -TriggerReason VERIFIED_TASK_FAILURE -VerifiedFailureReceipt <receipt>` may route to Astra after Sol is in the attempted-model set. Verify receipt provenance against the Task Kernel before invoking. Astra remains non-default and its actual spend must be recorded.
6. `EXACT_MATCH` / `AUTHORIZED_FALLBACK` proof is required for verified model identity. `PROOF_ABSENT` is not execution proof and must never mark Task Kernel DONE. Maintain provider identity, attempted model set, policy hash and effective tier in trace.

## Deterministic tests (no inference)

```powershell
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouterV14.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRouter.tests.ps1
powershell -NoProfile -File tests/v3/OrchestrationDynamicModelRoutingV11.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelExecution.tests.ps1
powershell -NoProfile -File scripts/v3/lib/OrchestrationModelRoutingEtapa4.tests.ps1
```

## Integration caution

This change adds a typed safe pre-execution fallback in `Invoke-OrchestrationModelExecution`. A real adapter must emit the typed failure envelope; a caught exception without safe no-execution evidence does not authorize a retry. The Task Kernel / full-delivery caller must supply proven T3 and Sol non-resolution receipts for capability escalations. Do not claim end-to-end availability until a real OpenCode V2 dispatch, post-execution model identity and durable task settlement have been demonstrated.
