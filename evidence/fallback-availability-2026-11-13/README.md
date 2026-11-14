# Availability fallback evidence (T3 → Terra)

These files are templates. The synthetic `service_unavailable` example is only
for validating parser/decision plumbing; it does **not** prove a real provider
outage, HTTP 429/503, or provider unavailability.

## Canonical T3 selection already observed

The worktree's canonical Kernel store is
`cache/runtime/tasks` (gitignored). Do not override `TasksDir`, `FlagsPath`,
`PolicyPath`, or `CliRepoRoot`.

```powershell
scripts/v3/task-kernel.ps1 -Action create -TaskId fallback-avail-t3-20261113 -Objective "Preparar prova de disponibilidade T3 para fallback ao tier Terra" -TaskType implementation -Risk high -Actor planner -RuntimeGeneration 2 -RuntimeProfile v2 -RuntimeVersion 2.3.0 -VerifierProfiles powershell
scripts/v3/task-kernel.ps1 -Action model-select -TaskId fallback-avail-t3-20261113 -AttemptRole coder -Risk high -ModelComplexity complex -TaskType implementation -RequiresLlm
```

Observed selection was T3, `claude-agent/sonnet`, provider `claude-agent`,
policy hash `c1de89fa3b24ca949bc4e4ba825fc967de2f49b490708a11dccf99e84bda316d`.
`no_dispatch=true`: selection itself did not dispatch a model.

## Synthetic parser/decision exercise

From the repository root, run this to exercise JSON parsing and classification
only. `openai/does-not-exist` is intentionally fictitious. Do not count this
as proof for any provider.

```powershell
scripts/v3/model-fallback.ps1 -Action next -AttemptRole coder -Risk high -Complexity complex -TaskId fallback-avail-t3-20261113 -FailedModel claude-agent/sonnet -FailureJson '@evidence/fallback-availability-2026-11-13/failure-t3.json' -AttemptEvidenceJson '@evidence/fallback-availability-2026-11-13/attempt-evidence-t3.json'
```

Expected classification is `PROVIDER_UNAVAILABLE`; no-start evidence is true
only because the synthetic fixture has `stage=pre_dispatch`, empty
`session_id`, `execution_started=false`, and zero assistant/tool counts. Record
the literal output and exit status when running the exercise.

## Real T3 availability observation procedure (Planner dispatch required)

1. Dispatch a real `coder` subagent using the canonical T3 selection above.
   Preserve the native dispatch/tool error verbatim. A qualifying observed
   dispatch failure must be pre-execution and have no returned `session_id`.
2. Populate `attempt-evidence-t3.json` from actual observed evidence:
   `source=dispatcher` or `provider`, `stage=pre_dispatch`, empty
   `session_id`, `execution_started=false`, `assistant_messages=0`,
   `tool_calls=0`. Do not infer these values if the tool emitted an ID or
   execution may have started.
3. Put the actual error in `failure-t3.json` using fields accepted by
   `ConvertFrom-OrchestrationProviderFailure` (for example a structured
   `code`, `type`, or HTTP `status`). The classifier must identify an
   availability class (`RATE_LIMIT`, `QUOTA_EXCEEDED`, `MODEL_UNAVAILABLE`,
   or `PROVIDER_UNAVAILABLE`).
4. Ask the Planner to run:

   ```powershell
   scripts/v3/model-fallback.ps1 -Action next -AttemptRole coder -Risk high -Complexity complex -TaskId fallback-avail-t3-20261113 -FailedModel claude-agent/sonnet -FailureJson '@evidence/fallback-availability-2026-11-13/failure-t3.json' -AttemptEvidenceJson '@evidence/fallback-availability-2026-11-13/attempt-evidence-t3.json'
   ```

   Continue only if output says `FALLBACK_AUTHORIZED`, `no_start_proof=true`,
   and the authorized candidate is `openai/gpt-6.1-terra`.
5. Planner performs the real fallback dispatch, observes its returned session
   ID, then records it:

   ```powershell
   scripts/v3/model-fallback.ps1 -Action record -AttemptId <attempt_id-from-next> -AttemptRole coder -TaskId fallback-avail-t3-20261113 -Model openai/gpt-6.1-terra -SessionId <real-fallback-session-id>
   ```

The decision proves the policy authorized a candidate based on the supplied
error and evidence, not that a real 429/503 occurred. The subsequent dispatch
and record prove only that the fallback was actually attempted and that its
session ID was recorded; they do not prove provider-wide availability or
successful completion unless separately observed.

## T4 note

Do not fabricate Kernel failure receipts. T4 requires genuine persisted
Kernel-owned failure evidence for the canonical T3 attempt, linked to the same
task and matching current policy/model/provider. `model-proof -RequiredTier T3`
recomputes that proof. Only after that proof and an actual failed T3 attempt
may the Planner evaluate escalation; `model-select` must independently return
T4 for the task. A caller-provided `T3FailureVerified` or
`T3FailureReceipt` is untrusted/ignored.
