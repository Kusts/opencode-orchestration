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

## Controller handoff (scripts/v3/github-wake-controller.ps1)

The wake tick only unblocks (BLOCKED->IMPLEMENTING) and announces. The
hand to the real controller is a separate single-shot step that never
reimplements dispatch:

- Extended next_action (announce preserved for existing consumers):
  task_id, checkpoint_id, goal_id, wait_dedup_key, generation,
  lease_owner, lease_expires_utc, event_id, kernel_state=IMPLEMENTING,
  idempotency_key (first 32 hex chars of SHA256 over
  "wait_dedup_key:event_id"), announce ("next-action task=<id>
  checkpoint=<id>").
- `Invoke-GHWakeControllerHandoff` (defined in github-wake.ps1): validates
  shape + idempotency binding, finds the wait by dedup_key, checks the
  Kernel binding/fingerprint (post-unblock: task IMPLEMENTING plus
  wait_history fingerprint match), the checkpoint resumable gate, and the
  live lease; then consults the existing controller contract only
  (AutonomousLoop objective step via injected probe, or the read-only
  GoalKernel next-move). Returns dispatched/not-dispatched with a typed
  reason. Never merges, pushes, deploys, completes tasks, issues grants,
  or reads secrets.
- Driver `github-wake-controller.ps1`: single-shot (no loop/sleep/daemon),
  fail-closed (missing checkpoint/binding/lease => HOLD, no spawn),
  idempotent (same event_id => DUPLICATE_NOOP, no replay, task never
  auto-completed). There is no native V2 API for resuming a closed
  session from PS: without an Executor the honest outcome is
  not-dispatched awaits-planner-dispatch — the Planner executes the
  dispatch via subagent. IMPLEMENTING alone is never execution:
  executed=$true appears only when a controller probe confirms a
  dispatch in that invocation.
- Suite: scripts/v3/github-wake-controller.tests.ps1 (offline).

## Scheduler

Register/Unregister-GitHubWakeSchedule manage one Windows Scheduled Task
via schtasks.exe with an explicit XML definition: TimeTrigger with
StartBoundary in local time (Now+2min, format yyyy-MM-ddTHH:mm:ss, no Z
suffix; Scheduler parses StartBoundary as local, UtcNow fired ~3h late on
a UTC-3 host) and bounded Repetition (Interval default 5min, Duration
default 12h), ExecutionTimeLimit (default 5min),
DisallowStartIfOnBatteries=false, StopIfGoingOnBatteries=false,
InteractiveToken/LeastPrivilege. AllowStartIfOnBatteries is absent on
purpose: it is not part of the schtasks XML schema and was rejected on
import (error 29,7), so it was removed; Disallow/StopIfGoing stay as the
correct battery settings. Registration is ownership-checked: an existing name whose XML does not
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

## Prova viva (live tick honesto, REVIEW_PENDING, sem cadeia completa)

- Real tick fired via schtasks.exe on 2026-10-31: task
  ETAPA6D-LIVE-TEST-F53A9C61, tick 2026-10-31T15:59:12Z (LastResult 0),
  transport gh-query live, b_decision KEEP_WAITING (pending),
  b_readiness REVIEW_PENDING (review-required, no approval on PR 181),
  b_attempts 1, b_confirmed false, kernel not-attempted, resumed 0,
  evaluated 1, resume_authorized false, next_action none. Reinvoke in a
  fresh process reproduced the same KEEP_WAITING/REVIEW_PENDING with
  kernel intact (B still BLOCKED rev 3, A still DONE rev 9).
- Correlated IDs: PR 181, HEAD ece501ed0815616902bb57b2050f280d8ee40fbb,
  run 41200510501 (success, headSha match), goal live6d-20261031-155642,
  checkpoint 351e3c0637f4960c,
  dedup_key github-resume:v1:kusts/opencode-orchestration:181:ece501ed0815616902bb57b2050f280d8ee40fbb:1.
  Out files: tick-out.json (scheduled tick) + reinvoke-out.json
  (fresh-process revalidation); raw trail in
  evidence/v3/etapa6d-live/etapa6d-live-proof.jsonl (60 lines).
- No RESUME was fabricated and no full chain is claimed: KEEP_WAITING
  announces no unblock and performs no handoff. ETAPA_6D_READY stays
  BLOCKED until PR 181 gets the required approval plus a re-execution
  that observes RESUME on live transport.

## Objetivo 4 (recuperacao e limites) — cobertura offline

- (a) Sem usuario interativo: XML fixa InteractiveToken/LeastPrivilege, sem
  segredo S4S simulado. HOLD honesto: sem sessao interativa no host, o
  registro real exige logon interativo; DryRun nunca e prova viva.
  Principal divergente recusado pelo owner check (mesmo arquivo de suite).
- (b) Duracao e renovacao: Interval PT5M + Duration PT12H +
  ExecutionTimeLimit PT5M + StopAtDurationEnd + IgnoreNew (sem estados
  paralelos) pinados no XML; renovacao via re-registro idempotente
  (already-registered sem duplicar, replaced-owned apos Force).
- (c) Falha do executor (proof ausente/invalida/futura) => READY
  ready-no-executor, nunca TERMINAL nem RESUME, kernel intacto.
- (d)-(h) ja cobertos, nao duplicados: cancelled, DUPLICATE_NOOP sem
  mutacao, head-superseded, lease-expired, api-failure (ver assert labels
  em github-wake.tests.ps1 e github-wake-controller.tests.ps1).
