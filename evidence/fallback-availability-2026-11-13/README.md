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

`no_start_proof=true` is declared from the supplied observed evidence; it is
not an independent proof source. In the recorded run the resolver reason
explicitly retains `HOLD` and says the candidate is audit-only/non-authorizing.
The output and later dispatch record do not prove a real 429/503 or
provider-wide availability.

## T4 note

Do not fabricate Kernel failure receipts. T4 requires genuine persisted
Kernel-owned failure evidence for the canonical T3 attempt, linked to the same
task and matching current policy/model/provider. `model-proof -RequiredTier T3`
recomputes that proof. Only after that proof and an actual failed T3 attempt
may the Planner evaluate escalation; `model-select` must independently return
T4 for the task. A caller-provided `T3FailureVerified` or
`T3FailureReceipt` is untrusted/ignored.

## Real observation: client-side model unavailable

Captured dispatch result is stored in `failure-t3-real.json`, with parser
evidence in `attempt-evidence-t3-real.json`. The Planner observed
`subagent(agent=coder, model=claude-agent/sonnet-availability-probe-nonexistent)`
fail immediately: no `sessionID`, no assistant message, no tool call, and no
execution. The message says the model is not available and suggests checking
the models catalog. This is a **client-side/unlisted requested-model** failure
before execution, not an observed provider 429/503 and not evidence that
provider `claude-agent` is unavailable.

For this tool-originated `tool.execution` result, the parser's correct
`attempt-evidence` source is `tool_error`, with `stage=pre_dispatch`, blank
session ID, `execution_started=false`, and zero counters. This reflects the
observed tool error; it should not be mislabeled as `provider` or `dispatcher`.

The real `model-fallback.ps1 -Action next` invocation returned
`classification=MODEL_UNAVAILABLE`, `status=FALLBACK_AUTHORIZED`,
`next_model=openai/gpt-6.1-terra`, `next_tier=T3`,
`no_start_proof=true`, exit code 0. The resolver's reason also contains
`HOLD: no independent no-start proof in this resolver; CandidateModel is
non-authorizing audit only.` Therefore this output records that the
availability classifier recognized the model-unavailable class and surfaced
the ordered candidate, but **does not itself authorize dispatch**. The Planner
must not treat this client-side invalid/unlisted model observation as proof of
provider unavailability; a real fallback dispatch needs an independently
authorizing path and appropriate evidence.

### Evidence boundary

Proved: the exact requested model was rejected by the native dispatch tool
before a session or execution began, and the local classifier classified its
error as `MODEL_UNAVAILABLE`.

Not proved: an actual HTTP 429 or 503; unavailability of the `claude-agent`
provider; successful execution of the fallback model; T4 escalation or Astra
eligibility. The nonexistent model name is specifically a client-side
availability/catalog case. Do not generalize it to provider health.

## Fallback dispatch recorded and T4 diagnostic

REPORTED successful execution: Planner reported that the real
`openai/gpt-6.1-terra` fallback dispatch succeeded for this task and supplied session
`ses_e2857aea9ffeBN8x6nE16QeLoR`. `model-fallback.ps1 -Action record` returned
success (exit 0) and appended the post-dispatch record to
`model-attempts.jsonl`. The record's `observed_model` remains `UNKNOWN`; the
dispatch success is a Planner report, not independently proved by that record.
The exact resolver JSONL line is embedded as `fallback_decision_log_line` in
`t3-availability-proof.json`.

T4 was checked read-only in `D:\projetos\_wt\orch-proof`, task
`proof-g1-20261113`. `get` showed both persisted T3 and T4 attempts with
`session_outcome=succeeded`. `model-proof -RequiredTier T3` returned
`{"ok":false,"error":"PROOF_STATUS_NOT_FAILED"}` (exit 1), and `model-select`
returned T3 `claude-agent/sonnet` (exit 0). Thus this task does not currently
permit T4 selection; no T4 availability dispatch should be attempted from this
task. The diagnostic did not modify that worktree.

## T4 availability procedure and observed result

This T4 experiment used a separate proof task in this branch:
`fallback-avail-t4-20261113`. The controlled `verify-run` used a proof-local
profile `fallback-availability-fixture` that ran
`powershell -NoProfile -File scratchpad/fallback-verify.ps1`. The ignored
`scratchpad/fallback-fixture.txt` began as `bad`; the worker was instructed
not to change it. Kernel `verify-run` returned
`verification_failed` (`verification_source=kernel-executed`). After recording
the actual T3 child session/message and binding the observed root/worker
sessions, `model-attempt` recorded T3 `claude-agent/sonnet`;
`model-proof -RequiredTier T3` returned:

```text
reference: modelproof:fallback-avail-t4-20261113:T3:2:7
digest:    sha256:ea18967593d40242503a2b5a2460cb1fcfa6e566f15553c444a835c379a8e2d3
```

### Proof-local verifier recreation (not merged)

The verifier profile and script below were local proof artifacts used to
produce the recorded Kernel result. They are not included as an active
verification-policy change in this PR. The `scratchpad/` directory is ignored
by Git. **artefato proof-local, NÃO mergeado; recriar para reproduzir**:

Profile object to add temporarily to this proof checkout's
`source/registry/verification-policy.json`:

```json
{
  "fallback-availability-fixture": {
    "class": "test",
    "command": "powershell -NoProfile -File scratchpad/fallback-verify.ps1",
    "timeout_seconds": 30
  }
}
```

Full contents of `scratchpad/fallback-verify.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$fixturePath = Join-Path (Get-Location) 'scratchpad/fallback-fixture.txt'
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    Write-Error 'fallback fixture missing'
    exit 1
}
$content = [IO.File]::ReadAllText($fixturePath).Trim()
if ($content -ceq 'good') {
    Write-Output 'fixture verified: good'
    exit 0
}
Write-Error ('fixture verification failed: expected good, found ' + $content)
exit 1
```

The subsequent canonical `model-select` returned T4 `claude-agent/opus` with
that proof reference and digest. The intentionally unavailable Opus request
was then observed before execution, with no session:
`claude-agent/opus-availability-probe-nonexistent`. Its native tool error and
pre-dispatch evidence are in `failure-t4-real.json` and
`attempt-evidence-t4-real.json`. The command used was:

```powershell
scripts/v3/model-fallback.ps1 -Action next -AttemptRole coder -Risk high -Complexity complex -TaskId fallback-avail-t4-20261113 -FailedModel claude-agent/opus-availability-probe-nonexistent -FailureJson '@evidence/fallback-availability-2026-11-13/failure-t4-real.json' -AttemptEvidenceJson '@evidence/fallback-availability-2026-11-13/attempt-evidence-t4-real.json' -EvidenceDir 'D:\projetos\_wt\orch-fallback-proof-20261114\evidence\fallback-availability-2026-11-13'
```

Observed decision: `MODEL_UNAVAILABLE`, `FALLBACK_AUTHORIZED`,
`next_tier=T4`, `next_model=openai/gpt-6.1-sol`, exit 0. The reason itself
also contains an audit-only HOLD: “no independent no-start proof in this
resolver; CandidateModel is non-authorizing audit only.” The Planner reported
`no_start_proof=true` from the observed evidence; this is not an independent
no-start proof and does not clear that HOLD. REPORTED successful execution:
the Planner reported that the real Sol dispatch succeeded with response
`T4_FALLBACK_SOL_OK` and session `ses_e284d5e49ffenBXX35BVr1LWaC`;
`-Action record` persisted the dispatch in `model-attempts.jsonl`. Its
`observed_model` is `UNKNOWN`, so model/session success is a Planner report,
not independently proved by that record. The exact resolver JSONL line is
embedded as `fallback_decision_log_line` in `t4-availability-proof.json`.

### Combined proof limits

Observed/Kernel-recorded: pre-execution rejection of each requested unlisted
model without a session; T3/T4 fallback decision outputs and candidates; a
Kernel-owned functional T3 failure proof enabling canonical T4 Opus selection.
Terra and Sol execution are **REPORTED successful execution** by the Planner.
Both `no_start_proof=true` values are based on the supplied observations; both
resolver reasons retain HOLD and mark the candidate audit-only.

Not proven: a real provider HTTP 429/503; unavailability of provider
`claude-agent` (the errors are client-side requested-model/catalog
rejections); Astra eligibility or execution; or automatic retry wiring. Both
fallback resolver reasons carry an audit-only HOLD, so their candidate output
is not independent dispatch authorization. The successful Terra and Sol
dispatches were separately reported by the Planner and recorded with
`observed_model=UNKNOWN`.
