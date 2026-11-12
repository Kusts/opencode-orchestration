# GitHub event producer contract (#183)

Status: producer contract is executable in tests; the external webhook/Action
does not exist in this scope. #183 remains PARTIAL.

## Envelope

`New-OrchestrationEventEnvelope` in
`scripts/v3/lib/OrchestrationEventCorrelation.ps1:33-71` validates each field
and computes the dedup key.

| Field | Type and constraint | Required | Producer source |
|---|---|---:|---|
| `source` | string; only `github` | yes | derivable |
| `trigger` | string; `issue_comment`, `pull_request_review`, `ci_status`, `push` | yes | derivable |
| `thread` | string; `^(pr|issue|branch):[A-Za-z0-9._/-]{1,120}$`, normalized lowercase | yes | derivable |
| `delivery_id` | string; `^[A-Za-z0-9._:-]{4,160}$` | yes | supplied by upstream delivery; never synthesize |
| `repo` | string; `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$` | yes | derivable |
| `summary` | string; at most 2000 characters | no | derivable |
| `informational_only` | boolean | no | derivable |

Derivable means the producer may map the GitHub event's authoritative fields
and policy into the envelope. `delivery_id` must preserve the upstream's stable
delivery identity. `dedup_key` is lowercase SHA-256 of
`source|repo_lower|delivery_id`; identical delivery identity within a repo
produces the same key, while a different `delivery_id` produces another key.

## Existing consumption paths

1. Validate/route and optionally record a dedup ledger:
   `powershell -NoProfile -File scripts/v3/event-intake.ps1 -EnvelopeFile <path> -SeenFile <ledger> -Record`
   or use `-EnvelopeJson '<json>'`. CLI and ledger behavior are in
   `scripts/v3/event-intake.ps1:10-19,48-52,68-90`.
2. Route GH-WAKE through intake and deliver an event to the owning Task:
   `powershell -NoProfile -File scripts/v3/github-event-bridge.ps1 -EnvelopeFile <path> -TasksDir <tasks-dir> -FlagsPath <flags-path>`
   or `-EnvelopeJson '<json>'`. The bridge uses existing correlation and
   Kernel functions; see `scripts/v3/github-event-bridge.ps1:1-20,23-24,73`.
3. Kernel operations are also available directly:
   `powershell -NoProfile -File scripts/v3/task-kernel.ps1 -Action event-attach -TaskId <id> -ExpectedRevision <revision> -EnvelopeFile <path> -TasksDir <tasks-dir> -FlagsPath <flags-path>`
   and
   `powershell -NoProfile -File scripts/v3/task-kernel.ps1 -Action event-ack -TaskId <id> -DedupKey <sha256> -SessionId <session> -ExpectedRevision <revision> -ResponseSummary <summary> -TasksDir <tasks-dir> -FlagsPath <flags-path>`.
   Required arguments and action dispatch are documented in
   `scripts/v3/task-kernel.ps1:18-19,579-615`.

GH-WAKE does **not** emit an event envelope, fabricate `delivery_id`, or
create a Task on its own. Proactive admission is issue #184 and is off by
default; no-owner events are observed unless explicit admission is enabled.

## Proven robustness invariants

- Field validation fails closed with a field-specific error; see correlation
  validator lines 44-55.
- Delivery dedup is keyed by repository and upstream `delivery_id`; routing
  ignores a seen key (`OrchestrationEventCorrelation.ps1:91-99`).
- Kernel event ack is idempotent; `event-ack` uses the existing
  `Confirm-OrchestrationTaskEvent` path (`task-kernel.ps1:18-19,613-615`).
- Kernel attachment preserves CAS/revision checks, terminal-task handling and
  trusted-path confinement; implementation is in
  `scripts/v3/lib/OrchestrationTaskKernel.ps1:2814-2962`.

## External producer acceptance checklist

- [ ] Map each supported GitHub trigger to the listed canonical `trigger`.
- [ ] Derive a lowercase `pr:`, `issue:`, or `branch:` thread from the event's
  owning object; reject events that cannot map safely.
- [ ] Pass the genuine upstream delivery identifier as `delivery_id`; never
  create a random, timestamp-based, or locally invented substitute.
- [ ] Emit the repository in `owner/name` form and bound `summary` to 2000
  characters; set `informational_only` only from explicit event semantics.
- [ ] Validate via `event-intake.ps1`; persist/reuse its seen ledger so replay
  is ignored, then use the bridge/Kernel path for delivery and acknowledgement.
- [ ] Keep admission disabled unless separately authorized by #184; do not
  add polling, scheduling, Task creation, or a second controller.
- [ ] Exercise malformed fields, duplicate delivery, informational events,
  ambiguous/terminal ownership, CAS conflict, and repeated acknowledgement.
- [ ] Record producer-side runtime evidence before claiming automatic external
  integration complete; until then #183 remains PARTIAL.
