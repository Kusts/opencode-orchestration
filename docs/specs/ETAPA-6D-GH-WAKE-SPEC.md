# ETAPA-6D GH-WAKE SPEC (short)

Real scheduled wake for GitHub CI waits. Single-shot per scheduler tick,
no daemon, no second Planner/Kernel/watchdog, no LLM in the loop.

## Contracts

- GH-OBSERVE (github-await.ps1): read-only `gh api graphql`, fixed query,
  bounded raw-to-snapshot normalizer (Convert-GHARawToSnapshot). Wake reuses
  it via dot-source; fixture file is test-only.
- GH-WAIT (ghwait-*.json via OrchestrationGitHubResume.ps1): durable wait
  with dedup_key (repo+pr+sha+generation), lease, retry budget,
  applied_events idempotency log. Wake never reimplements readiness.
- GH-WAKE (scripts/v3/github-wake.ps1): one pass over WaitsDir per
  invocation. Per wait, in order: task DONE check, duplicate check,
  checkpoint gate, kernel binding gate, live fetch (bounded retry),
  resume decision, and ONLY on RESUME a CAS confirm plus a Kernel
  BLOCKED->IMPLEMENTING unblock referencing the active-wait fingerprint.
  Announces only the next authorized action (task_id + checkpoint_id).
  Never merges, pushes, deploys, completes tasks, issues grants, or stores
  tokens. Authority pins always false except resume_authorized on RESUME.

## Decision table (per wait)

- Task DONE -> HOLD already-done (DONE never reexecuted).
- Event already applied, task still BLOCKED, binding valid, fresh
  observe still RESUME -> RESUME reconciled-pending-unblock (recovers a
  prior tick that confirmed CAS but failed the unblock; exactly one
  BLOCKED->IMPLEMENTING transition, no duplicate Confirm). Event applied
  and revalidation not RESUME (or task left BLOCKED state) ->
  DUPLICATE_NOOP (no kernel write).
- No checkpoint / checkpoint not resumable -> HOLD (no unblock).
- Kernel not BLOCKED or fingerprint diverged -> HOLD (no unblock).
- Transport exhausted (MaxApiAttempts, default 3, linear backoff) or
  schema failure -> HOLD api-failure (no unblock).
- CI green + executor + authz -> RESUME + confirm + unblock + next_action.
- CI green, no executor -> READY (durable observable, no unblock).
- CI red -> TERMINAL diagnostic (no unblock, no confirm).
- CI pending -> KEEP_WAITING. Stale SHA -> TERMINAL head-superseded.
  Closed PR -> TERMINAL pr-terminal. Revoked authz -> TERMINAL.

## Scheduler

Register/Unregister-GitHubWakeSchedule manage one Windows Scheduled Task
via schtasks.exe with an explicit XML definition: TimeTrigger with bounded
Repetition (Interval default 5min, Duration default 12h), ExecutionTimeLimit
(default 5min), DisallowStartIfOnBatteries=false,
StopIfGoingOnBatteries=false, InteractiveToken/LeastPrivilege. Registration is ownership-checked: an existing name whose XML does not
carry this wake script + config as the exact -File/-ConfigFile parameter
pair returns task-name-conflict (fail-closed); -Force replaces only after
that check (replaced-conflict/replaced-owned). Unregister is fail-closed
too: deleting an existing task requires explicit -Force, otherwise
confirmation-required; absent tasks stay idempotent not-found. Battery/location
settings not expressible via schtasks.exe CLI are fixed in the imported XML,
not via the ScheduledTasks module (unavailable on Server Core). Action runs
`powershell -NoProfile -File github-wake.ps1 -ConfigFile <json>` as a
separate process; args persist in the JSON config written by
New-GitHubWakeConfig. No in-memory state crosses ticks.

## Authority and limits

- Kernel is the authority for task state; ghwait files are transport;
  checkpoint + Goal store are the authority for resume context.
- Wake writes at most: wait applied_events (CAS, RESUME only) and one
  Kernel BLOCKED->IMPLEMENTING transition (CAS + fingerprint + trusted
  identity source explicit-cli). Everything else is observation.
- No auto-merge/deploy/DONE; no grant issuance; no secret handling; no
  polling/busy-loop; retry is bounded (max 3 attempts per wait per tick).
- Proof: scripts/v3/full-delivery-etapa6d-proof.ps1 (two real processes,
  normalizer-real fixtures, live transport probe, no fabricated live PR).
  Suite: scripts/v3/github-wake.tests.ps1 (offline, PS 5.1 + pwsh).
