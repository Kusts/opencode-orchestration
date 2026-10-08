<#!
.SYNOPSIS
    PR-2 Objective Runtime Executor: minimal model-independent connector (CORRECTIVE-PLAN Fase 2, opcao B).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Small pure constructors
    plus one explicit single-pass orchestration entry point, fail-closed,
    PS 5.1 compatible, ASCII-only. Never throws on operational paths: every
    failure returns an object with ok=$false and a machine-readable reason.
    No network, no process spawn, no kill, no secret values (credential
    identifiers are names only, never resolved), no flags read or written,
    no DONE and no verified_pass ever issued here (grants_authority=$false
    and done_approved=$false on every envelope). The watchdog is only
    referenced (signal names), never driven.

    The executor CONNECTS GoalKernel / TaskKernel / ObjectiveController /
    AdapterContract / GoalCheckpoint and NEVER duplicates Planner reasoning:
    it never synthesizes a next_move (it only forwards the controller
    output while recording the consumed prior move), never decides content,
    and advances exactly one event per call:

      Event -> Read Goal -> Acquire ownership (CAS revision + lease +
      fencing generation) -> Check policy/budget (envelope
      User∩Project∩Runtime∩Grants; worker/task exhaustion => replan, only
      Goal hard budget is terminal and persisted) -> Persist DispatchIntent
      (before the effect) -> Execute via AdapterContract + TaskKernel
      (real dispatch = kernel start-attempt; native HOLD ops => typed
      fallback, never presumed spawn) -> Collect result -> Settle Task
      (kernel) -> Verify/Review gate (kernel-only, never self-attested) ->
      Checkpoint -> Get next_move (ObjectiveController) -> Execute next_move.

    Event-driven only: accepted types are task-settled, wave-barrier,
    worker-result, checkpoint, external-reconciled and session-reconciled.
    One call processes exactly one event; there is no busy polling and no
    unbounded loop (only the bounded store-lock retry, mirroring the
    GoalKernel idiom).

    Idempotency: stable key goal_id + work_item_id + action_revision. On
    resume/duplicate: check exists -> active? -> result? -> safe repeat?
    External effects always require reconciliation (exactly-once is never
    presumed); a duplicate event yields exactly one logical dispatch.

    Concurrency: a single mutator per Goal. A stale owner is rejected
    fail-closed; every mutation is atomic under the store lock; a crash
    between dispatch and settlement leaves state PENDING plus mandatory
    reconciliation on resume (a missing session is never a failure).

    D1 (ARC-PR2-01, HOLD ENFORCED by construction, GoalKernel gate pending):
    this ledger is a diary of effects and recovery, NOT an authority.
    Productive acquisition (a GoalKernel-side ownership that alone authorizes productive effects) stays HOLD until the GoalKernel extension with its gate lands; what this file acquires locally is valid only for the restricted diary/recovery path and never produces productive effects by itself. Effect seams (DispatchImpl / SettleImpl
    / ReconcileImpl) are TEST-ONLY declared: they are invoked ONLY when
    the caller passes the explicit -TestCallback switch (harness only).
    Without -TestCallback every effect seam returns held/unavailable
    typed and is never invoked (spy 0 calls by construction), so there
    is no productive TOCTOU window to exploit. Diary/ownership local
    state exists only for restricted recovery (reconcile/replay), never
    as a productive authorization. Unproven DispatchImpl/SettleImpl
    callbacks are blocked pre-call, and ok/dispatched/self-declared
    envelopes never prove a commit: only a durable receipt (destination
    + action + task/run + generation + result, bound to the proof and
    the dispatch original, operation-scoped) advances the protocol.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# R4: dependencies live in module/script scope, not in a caller scope.
# Dot-sourcing here (file load) keeps the sibling commands visible after
# this lib returns, so a clean session that loads ONLY this file still
# resolves GoalKernel / Controller / Checkpoint / AdapterContract.
# Function-level Import-ORLibFile below stays as a bounded fallback.
try {
    foreach ($ORLibName in @('OrchestrationGoalKernel.ps1', 'OrchestrationObjectiveController.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationRuntimeAdapterContract.ps1')) {
        try {
            $ORLibPath = Join-Path $PSScriptRoot $ORLibName
            if (Test-Path -LiteralPath $ORLibPath -PathType Leaf) { . $ORLibPath }
        }
        catch { }
    }
}
catch { }

function Get-OrchestrationObjectiveRuntimeVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-OBJECTIVE-RUNTIME-CONTRACT'
        phase          = 'PR-2'
    }
}

function Get-OrchestrationObjectiveEventTypes {
    [CmdletBinding()]
    param()
    return @('task-settled', 'wave-barrier', 'worker-result', 'checkpoint', 'external-reconciled', 'session-reconciled')
}

function Get-OrchestrationObjectiveStopReasons {
    [CmdletBinding()]
    param()
    return @('OBJECTIVE_COMPLETED', 'HUMAN_AUTHORITY_REQUIRED', 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE', 'GOAL_HARD_BUDGET_EXHAUSTED', 'POLICY_BLOCKED', 'CANCELLED')
}

function Test-ORGoalIdValue {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,64}$')
    }
    catch { return $false }
}

function Get-ORCanonicalId {
    # D2 canonical identity: Trim + ToLowerInvariant. Routing, file
    # mapping and every comparison use the canonical form; the stored
    # display spelling is preserved untouched. A legacy record whose
    # display differs in case from the requested display (same canonical)
    # is an identity HOLD: never renamed, never merged.
    param([string]$Value)
    try { return (([string]$Value).Trim().ToLowerInvariant()) }
    catch { return '' }
}

function Test-ORIdentityHold {
    # True when both displays are non-empty, canonically equal, but not
    # ordinal-equal: a case-divergent legacy spelling => HOLD.
    param([string]$Stored = '', [string]$Requested = '')
    try {
        $s = [string]$Stored
        $r = [string]$Requested
        if ([string]::IsNullOrWhiteSpace($s) -or [string]::IsNullOrWhiteSpace($r)) { return $false }
        if ((Get-ORCanonicalId $s) -cne (Get-ORCanonicalId $r)) { return $false }
        return ($s -cne $r)
    }
    catch { return $false }
}

function Get-ORFieldValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-ORLongValue {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) { return [long]$Value }
        return $Default
    }
    catch { return $Default }
}

function Get-ORStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

function Get-ORHashHex32 {
    param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            $h = $sha.ComputeHash($bytes)
            $hex = ([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant()
            return $hex.Substring(0, 32)
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-ORNowUtc {
    try { return [DateTime]::UtcNow } catch { return ([DateTime]::MinValue) }
}

function Get-ORLeaseInstant {
    param($Value)
    try {
        if ($null -eq $Value) { return $null }
        if ($Value -is [DateTime]) {
            $dt = [DateTime]$Value
            if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return $null }
            return $dt.ToUniversalTime()
        }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($s, [ref]$parsed)) { return $null }
        if ($parsed.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        return $parsed.ToUniversalTime()
    }
    catch { return $null }
}

function Test-ORAuthAdmitted {
    param($Envelope)
    try {
        if ($null -eq $Envelope) { return $false }
        return [bool](Get-ORFieldValue $Envelope 'admitted' $false)
    }
    catch { return $false }
}

function Import-ORLibFile {
    param([string]$Name)
    try {
        $p = Join-Path $PSScriptRoot ([string]$Name)
        if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
    }
    catch { }
}

function New-ORNoAuthorityEnvelope {
    param([string]$Reason)
    try {
        return [pscustomobject]@{
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
            reason           = [string]$Reason
        }
    }
    catch {
        return [pscustomobject]@{
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
            reason           = 'internal-error'
        }
    }
}

function New-OrchestrationObjectiveEvent {
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$Type = '',
        [string]$WorkItemId = '',
        [long]$ActionRevision = 1,
        $Payload = $null
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-ORGoalIdValue $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; event = $null; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $t = ([string]$Type).Trim().ToLowerInvariant()
        if (@(Get-OrchestrationObjectiveEventTypes) -cnotcontains $t) {
            return [pscustomobject]@{ ok = $false; reason = 'unknown-event'; event = $null; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $wid = ([string]$WorkItemId).Trim()
        if (-not (Test-ORGoalIdValue $wid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-work-item-id'; event = $null; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $rev = Get-ORLongValue $ActionRevision -1
        if ($rev -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-action-revision'; event = $null; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $ev = [ordered]@{
            goal_id         = $gid
            type            = $t
            work_item_id    = $wid
            action_revision = [long]$rev
            payload         = $Payload
        }
        return [pscustomobject]@{ ok = $true; reason = ''; event = $ev; grants_authority = $false; done_approved = $false; verified_pass = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; event = $null; grants_authority = $false; done_approved = $false; verified_pass = $false }
    }
}

function Get-OrchestrationObjectiveIdempotencyKey {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1)
    try {
        # D2: the key is canonical (lowercase); display spellings stay on
        # the record. GoalId/WorkItemId charset is validated on display.
        $gid = ([string]$GoalId).Trim()
        $wid = ([string]$WorkItemId).Trim()
        $rev = Get-ORLongValue $ActionRevision -1
        if ((-not (Test-ORGoalIdValue $gid)) -or (-not (Test-ORGoalIdValue $wid)) -or ($rev -lt 1)) { return '' }
        return ((Get-ORCanonicalId $gid) + '|' + (Get-ORCanonicalId $wid) + '|' + [string]$rev)
    }
    catch { return '' }
}

function New-OrchestrationDispatchIntent {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1)
    try {
        $key = Get-OrchestrationObjectiveIdempotencyKey -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision $ActionRevision
        if ([string]::IsNullOrWhiteSpace($key)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; intent = $null }
        }
        $stamp = Get-ORStamp
        $rec = [ordered]@{
            schema_version  = 1
            key             = $key
            goal_id         = ([string]$GoalId).Trim()
            work_item_id    = ([string]$WorkItemId).Trim()
            action_revision = (Get-ORLongValue $ActionRevision -1)
            state           = 'intended'
            owner           = ''
            generation      = [long]0
            created_at      = $stamp
            updated_at      = $stamp
        }
        return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; intent = $null }
    }
}

function ConvertTo-ORDispatchRecord {
    param($Intent)
    try {
        if ($null -eq $Intent) { return $null }
        if ((-not ($Intent -is [System.Collections.IDictionary])) -and (-not ($Intent -is [pscustomobject]))) { return $null }
        $key = [string](Get-ORFieldValue $Intent 'key' '')
        if ([string]::IsNullOrWhiteSpace($key)) { return $null }
        $gid = [string](Get-ORFieldValue $Intent 'goal_id' '')
        $wid = [string](Get-ORFieldValue $Intent 'work_item_id' '')
        $rev = Get-ORLongValue (Get-ORFieldValue $Intent 'action_revision' $null) -1
        $want = Get-OrchestrationObjectiveIdempotencyKey -GoalId $gid -WorkItemId $wid -ActionRevision $rev
        if ([string]::IsNullOrWhiteSpace($want) -or ($want -cne $key)) { return $null }
        $sv = Get-ORLongValue (Get-ORFieldValue $Intent 'schema_version' $null) -1
        if ($sv -ne 1) { return $null }
        $state = ([string](Get-ORFieldValue $Intent 'state' '')).Trim().ToLowerInvariant()
        # D4 protocol: intended -> dispatched-unknown -> pending -> settled
        # -> checkpointed -> advanced, plus held / reconciled. settled,
        # checkpointed and advanced are distinct diary stages, never
        # aliases. ('dispatched' is a legacy pre-effect spelling.)
        if (@('intended', 'dispatched', 'dispatched-unknown', 'pending', 'settled', 'checkpointed', 'advanced', 'reconciled', 'held') -cnotcontains $state) { return $null }
        $gen = Get-ORLongValue (Get-ORFieldValue $Intent 'generation' $null) -1
        if ($gen -lt 0) { return $null }
        # D3 durable receipt: destination + action + task/run + generation
        # + result. Carried when present; never synthesized here.
        $receipt = Get-ORFieldValue $Intent 'receipt' $null
        if (($null -ne $receipt) -and (-not ($receipt -is [System.Collections.IDictionary])) -and (-not ($receipt -is [pscustomobject]))) { $receipt = $null }
        # F3/F5 diary payloads: settlement receipt (persisted atomically
        # with the settled transition), persisted next_move (replayed on
        # advanced duplicates), and the goal-revision origin of the
        # effect (distinguished from the live revision for N->N+1).
        $sReceipt = Get-ORFieldValue $Intent 'settlement_receipt' $null
        if (($null -ne $sReceipt) -and (-not ($sReceipt -is [System.Collections.IDictionary])) -and (-not ($sReceipt -is [pscustomobject]))) { $sReceipt = $null }
        $nMove = Get-ORFieldValue $Intent 'next_move' $null
        $originRev = Get-ORLongValue (Get-ORFieldValue $Intent 'goal_revision_origin' $null) -1
        if ($originRev -lt 1) { $originRev = [long]0 }
        $rec = [ordered]@{
            schema_version  = 1
            key             = $key
            goal_id         = $gid
            work_item_id    = $wid
            goal_id_canon   = (Get-ORCanonicalId $gid)
            work_item_id_canon = (Get-ORCanonicalId $wid)
            action_revision = [long]$rev
            state           = $state
            owner           = [string](Get-ORFieldValue $Intent 'owner' '')
            owner_canon     = (Get-ORCanonicalId ([string](Get-ORFieldValue $Intent 'owner' '')))
            generation      = [long]$gen
            request_hash    = [string](Get-ORFieldValue $Intent 'request_hash' '')
            receipt         = $receipt
            settlement_receipt = $sReceipt
            next_move       = $nMove
            goal_revision_origin = [long]$originRev
            checkpoint_id   = [string](Get-ORFieldValue $Intent 'checkpoint_id' '')
            created_at      = [string](Get-ORFieldValue $Intent 'created_at' '')
            updated_at      = [string](Get-ORFieldValue $Intent 'updated_at' '')
            consumed_from   = [string](Get-ORFieldValue $Intent 'consumed_from' '')
            consumed_at     = [string](Get-ORFieldValue $Intent 'consumed_at' '')
        }
        return $rec
    }
    catch { return $null }
}

function Get-OrchestrationObjectiveRuntimeStoreDir {
    [CmdletBinding()]
    param([string]$StoreDir = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($StoreDir)) { return ([string]$StoreDir) }
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        if ([string]::IsNullOrWhiteSpace($repoRoot)) { return '' }
        $dir = Join-Path (Join-Path $repoRoot 'cache') 'objective-runtime'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($dir)
        }
        return $dir
    }
    catch { return '' }
}

function Get-ORIntentFilePath {
    param([string]$Dir, [string]$GoalId, [string]$WorkItemId, [long]$ActionRevision)
    try {
        # R5 + D2: file name is a hash of the CANONICAL key, never a raw
        # join of the ids. A naive join is ambiguous: ('a__b','c') and
        # ('a','b__c') map to the same file, while case folds ('G2-A' vs
        # 'g2-a') share one file so the stored display spelling can be
        # compared and a case divergence held (never silently merged).
        $key = Get-OrchestrationObjectiveIdempotencyKey -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision $ActionRevision
        if ([string]::IsNullOrWhiteSpace($key)) { return '' }
        $h = Get-ORHashHex32 $key
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $Dir ('intent-' + $h + '.intent.json'))
    }
    catch { return '' }
}

function Get-OROwnerFilePath {
    param([string]$Dir, [string]$GoalId)
    try {
        # D2: owner record keyed by canonical goal identity; the display
        # spelling inside the record decides HOLD vs admit.
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-ORGoalIdValue $gid)) { return '' }
        $h = Get-ORHashHex32 ('owner|' + (Get-ORCanonicalId $gid))
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $Dir ('owner-' + $h + '.owner.json'))
    }
    catch { return '' }
}

function Get-ORAdvanceMarkerPath {
    # D4 diary advance marker: one file per canonical intent key. It
    # records that the advance stage ran; it never authorizes anything.
    param([string]$Dir, [string]$Key)
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($k)) { return '' }
        $h = Get-ORHashHex32 ('advance|' + $k)
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $Dir ('advance-' + $h + '.advance.json'))
    }
    catch { return '' }
}

function Open-ORStoreLock {
    param([string]$Dir, [int]$LockTimeoutMs = 500)
    try {
        $lockPath = Join-Path $Dir '.objective-runtime.lock'
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $LockTimeoutMs))
        do {
            try {
                return ([IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            }
            catch { Start-Sleep -Milliseconds 10 }
        } while ([DateTime]::UtcNow -lt $deadline)
        return $null
    }
    catch { return $null }
}

function Save-OrchestrationDispatchIntent {
    [CmdletBinding()]
    param($Intent = $null, [string]$StoreDir = '', [int]$LockTimeoutMs = 500, [string]$OwnerId = '', [long]$Generation = 0)
    try {
        $rec = ConvertTo-ORDispatchRecord $Intent
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; key = ''; duplicate = $false }
        }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; key = [string]$rec['key']; duplicate = $false }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; key = [string]$rec['key']; duplicate = $false }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; key = [string]$rec['key']; duplicate = $false }
        }
        try {
            $path = Get-ORIntentFilePath -Dir $dir -GoalId ([string]$rec['goal_id']) -WorkItemId ([string]$rec['work_item_id']) -ActionRevision ([long]$rec['action_revision'])
            if ([string]::IsNullOrWhiteSpace($path)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; key = [string]$rec['key']; duplicate = $false }
            }
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                # R5: existence is not a duplicate until the stored canonical
                # key is compared. Same key => idempotent duplicate;
                # different key in the same file => collision, fail closed.
                # R1: when a fencing token is supplied, the writer must still
                # hold ownership under this same lock.
                if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                    $f = Confirm-OROwnershipHeld -Dir $dir -GoalId ([string]$rec['goal_id']) -OwnerId $OwnerId -Generation $Generation
                    if (-not [bool]$f.held) {
                        return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; key = [string]$rec['key']; duplicate = $false }
                    }
                }
                try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
                catch {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; key = [string]$rec['key']; duplicate = $false }
                }
                $stored = ConvertTo-ORDispatchRecord $raw
                if ($null -eq $stored) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; key = [string]$rec['key']; duplicate = $false }
                }
                if ([string]$stored['key'] -cne [string]$rec['key']) {
                    return [pscustomobject]@{ ok = $false; reason = 'key-collision'; key = [string]$rec['key']; duplicate = $false }
                }
                return [pscustomobject]@{ ok = $true; reason = 'duplicate-intent'; key = [string]$rec['key']; duplicate = $true }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                $f = Confirm-OROwnershipHeld -Dir $dir -GoalId ([string]$rec['goal_id']) -OwnerId $OwnerId -Generation $Generation
                if (-not [bool]$f.held) {
                    return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; key = [string]$rec['key']; duplicate = $false }
                }
            }
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; key = [string]$rec['key']; duplicate = $false }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; key = [string]$rec['key']; duplicate = $false }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; key = [string]$rec['key']; duplicate = $false }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; key = ''; duplicate = $false }
    }
}

function Get-OrchestrationDispatchIntent {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1, [string]$StoreDir = '')
    try {
        $key = Get-OrchestrationObjectiveIdempotencyKey -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision $ActionRevision
        if ([string]::IsNullOrWhiteSpace($key)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; intent = $null }
        }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; intent = $null }
        }
        $path = Get-ORIntentFilePath -Dir $dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; intent = $null }
        }
        try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
        }
        $rec = ConvertTo-ORDispatchRecord $raw
        if (($null -eq $rec) -or ([string]$rec['key'] -cne $key)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
    }
}

function Set-OrchestrationDispatchState {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1, [string]$State = '', [string]$StoreDir = '', [int]$LockTimeoutMs = 500, [string]$OwnerId = '', [long]$Generation = 0)
    try {
        $st = ([string]$State).Trim().ToLowerInvariant()
        if (@('intended', 'dispatched', 'dispatched-unknown', 'pending', 'settled', 'checkpointed', 'advanced', 'reconciled', 'held') -cnotcontains $st) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-state'; intent = $null }
        }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; intent = $null }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; intent = $null }
        }
        try {
            $path = Get-ORIntentFilePath -Dir $dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; intent = $null }
            }
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
            }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                $f = Confirm-OROwnershipHeld -Dir $dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
                if (-not [bool]$f.held) {
                    return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; intent = $null }
                }
            }
            # D4 transition guard (diary order, fail-closed): settled,
            # checkpointed, advanced and reconciled are never re-entered
            # through the generic setter (stage CAS functions own them);
            # checkpointed/advanced are never set generically; held is
            # allowed only pre-effect (proven absence of effect or a
            # pre-call block), never out of pending or later stages.
            $cur = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ($cur -cne $st) {
                if ((@('settled', 'checkpointed', 'advanced', 'reconciled') -ccontains $cur)) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null }
                }
                if ((@('checkpointed', 'advanced') -ccontains $st)) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null }
                }
                # 'settled' is owned by the durable-consumption CAS (with
                # the consumed-move marker); the generic setter never
                # settles.
                if ($st -ceq 'settled') {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null }
                }
                if (($st -ceq 'held') -and ((@('pending', 'settled', 'checkpointed', 'advanced', 'reconciled') -ccontains $cur))) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null }
                }
            }
            $rec['state'] = $st
            $rec['updated_at'] = Get-ORStamp
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; intent = $null }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; intent = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'intent-write-failed'; intent = $null }
    }
}

function Confirm-OROwnershipHeld {
    # R1 fencing revalidation: the caller still owns the goal iff the owner
    # file holds the same owner id + generation and the lease is unexpired.
    # Never throws; callers run this under (or right before) the store lock
    # so the check covers the effect that follows.
    param([string]$Dir = '', [string]$GoalId = '', [string]$OwnerId = '', [long]$Generation = 0)
    try {
        $gid = ([string]$GoalId).Trim()
        $oid = ([string]$OwnerId).Trim()
        $gen = Get-ORLongValue $Generation -1
        if ((-not (Test-ORGoalIdValue $gid)) -or [string]::IsNullOrWhiteSpace($oid) -or ($gen -lt 1)) {
            return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
        }
        $path = Get-OROwnerFilePath -Dir $Dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
        }
        try { $current = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
        catch {
            return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
        }
        # D2: the owner file is keyed by canonical goal identity; a stored
        # display spelling that diverges in case is held, not renamed.
        try {
            if (Test-ORIdentityHold ([string](Get-ORFieldValue $current 'goal_id' '')) $gid) {
                return [pscustomobject]@{ held = $false; reason = 'identity-hold-case-divergence' }
            }
        }
        catch { }
        $storedOwner = [string](Get-ORFieldValue $current 'owner_id' '')
        $storedGen = Get-ORLongValue (Get-ORFieldValue $current 'generation' $null) -1
        # D2: owner comparison is canonical (ordinal -ceq on the lowered
        # form). A canonically-equal but ordinally-divergent spelling is a
        # legacy case divergence => identity HOLD, never a silent merge.
        if ((Get-ORCanonicalId $storedOwner) -cne (Get-ORCanonicalId $oid)) {
            return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
        }
        if ($storedOwner -cne $oid) {
            return [pscustomobject]@{ held = $false; reason = 'identity-hold-case-divergence' }
        }
        if ($storedGen -ne $gen) {
            return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
        }
        $exp = Get-ORLeaseInstant (Get-ORFieldValue $current 'expires_at' $null)
        if (($null -ne $exp) -and ((Get-ORNowUtc) -ge $exp)) {
            return [pscustomobject]@{ held = $false; reason = 'owner-lease-expired' }
        }
        return [pscustomobject]@{ held = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ held = $false; reason = 'owner-lost-no-advance' }
    }
}

function Set-ORDispatchSettledCAS {
    # R2 durable consumption with CAS: transitions the intent to 'settled'
    # and stamps the consumed prior-move marker atomically under the store
    # lock. Already-settled with the SAME marker is idempotent success;
    # already-settled with a DIFFERENT marker is a conflict (fail closed).
    # Fencing is revalidated under the same lock when supplied.
    # F3: when -SettlementReceipt is supplied it is persisted atomically
    # with the transition, so a crash right after settlement still
    # recovers the durable receipt (never the dispatch receipt alone).
    # M2: the receipt is MANDATORY and bound -- a null receipt, a
    # missing/empty/incomplete proof (validated by the proof gate before
    # the transition), a receipt that fails the operation-scoped
    # proof-bound gate, or a predecessor outside
    # pending/dispatched-unknown/dispatched (intended->settled direct
    # is prohibited) is rejected fail-closed.
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1, [string]$ConsumedFrom = '', [string]$StoreDir = '', [int]$LockTimeoutMs = 500, [string]$OwnerId = '', [long]$Generation = 0, $SettlementReceipt = $null, $SettleProof = $null)
    try {
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; intent = $null }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; intent = $null }
        }
        try {
            $path = Get-ORIntentFilePath -Dir $dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; intent = $null }
            }
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
            }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                $f = Confirm-OROwnershipHeld -Dir $dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
                if (-not [bool]$f.held) {
                    return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; intent = $null }
                }
            }
            $mark = ([string]$ConsumedFrom).Trim()
            if ([string]$rec['state'] -ceq 'settled') {
                if ([string]$rec['consumed_from'] -ceq $mark) {
                    return [pscustomobject]@{ ok = $true; reason = 'already-settled'; intent = $rec; duplicate = $true }
                }
                return [pscustomobject]@{ ok = $false; reason = 'consume-conflict'; intent = $null }
            }
            # M2: mandatory bound receipt -- null receipt or missing proof
            # never settles.
            if (($null -eq $SettlementReceipt) -or ((-not ($SettlementReceipt -is [System.Collections.IDictionary])) -and (-not ($SettlementReceipt -is [pscustomobject])))) {
                return [pscustomobject]@{ ok = $false; reason = 'settlement-receipt-missing'; intent = $null }
            }
            if (($null -eq $SettleProof) -or ((-not ($SettleProof -is [System.Collections.IDictionary])) -and (-not ($SettleProof -is [pscustomobject])))) {
                return [pscustomobject]@{ ok = $false; reason = 'settlement-proof-missing'; intent = $null }
            }
            # M2 residual (SEC-PR2-05): an empty/incomplete proof (e.g.
            # @{}) passes the type check above but binds nothing, and the
            # receipt gate below skips the proof comparison when the proof
            # carries no destination/action. Validate the proof itself
            # BEFORE the transition: destination/action present and bound
            # to this intent (fencing + idempotency + generation). The
            # fencing owner is enforced against -OwnerId when supplied
            # (same posture as the ownership revalidation above);
            # otherwise the proof must at least carry its own fencing
            # owner while destination/action/idempotency/generation bind.
            $proofOwner = $OwnerId
            if ([string]::IsNullOrWhiteSpace($proofOwner)) {
                $proofOwner = [string](Get-ORFieldValue $SettleProof 'fencing_owner' '')
            }
            $proofGate = Test-OREffectProof -Proof $SettleProof -Key ([string]$rec['key']) -OwnerId $proofOwner -Generation $Generation
            if (($null -eq $proofGate) -or (-not [bool]$proofGate.ok)) {
                $why = 'settlement-proof-invalid'
                try { if (($null -ne $proofGate) -and (-not [string]::IsNullOrWhiteSpace([string]$proofGate.reason))) { $why = [string]$proofGate.reason } } catch { }
                return [pscustomobject]@{ ok = $false; reason = $why; intent = $null }
            }
            # M2: predecessor restriction -- only a post-effect state with
            # a valid receipt settles; intended->settled direct is
            # prohibited (fail closed, never advanced).
            $preSt = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ((@('pending', 'dispatched-unknown', 'dispatched') -cnotcontains $preSt)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null }
            }
            # M2: the receipt must be operation-scoped ('settlement') and
            # bound to the proof and the original intent key/generation;
            # a dispatch receipt never satisfies this gate.
            $srGate = Test-OREffectReceipt -Receipt $SettlementReceipt -Key ([string]$rec['key']) -Generation $Generation -Proof $SettleProof -Operation 'settlement'
            if (($null -eq $srGate) -or (-not [bool]$srGate.ok)) {
                $why = 'settlement-receipt-invalid'
                try { if (($null -ne $srGate) -and (-not [string]::IsNullOrWhiteSpace([string]$srGate.reason))) { $why = [string]$srGate.reason } } catch { }
                return [pscustomobject]@{ ok = $false; reason = $why; intent = $null }
            }
            $rec['state'] = 'settled'
            $rec['consumed_from'] = $mark
            $rec['consumed_at'] = Get-ORStamp
            $rec['updated_at'] = [string]$rec['consumed_at']
            if ($null -ne $SettlementReceipt) {
                if ((($SettlementReceipt -is [System.Collections.IDictionary]) -or ($SettlementReceipt -is [pscustomobject]))) {
                    $rec['settlement_receipt'] = $SettlementReceipt
                }
            }
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; intent = $null }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; intent = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec; duplicate = $false }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; intent = $null }
    }
}

function Invoke-ORSettleUnderStoreLock {
    # F2/F3 single-lock settlement (test-only path only): revalidates
    # ownership/lease/generation AND the proof gate, invokes the Settle
    # callback, validates the settlement receipt (operation-scoped,
    # proof-bound), and persists receipt + settled transition atomically
    # while holding the store lock across all four steps (no window).
    # Never throws; a lost lease or failed gate means the callback is
    # never invoked (spy 0 calls). Returns the settled intent on success.
    # M1: the SettleScript seam is TEST-ONLY and declared by the explicit
    # -TestCallback switch; without it the callback is never invoked
    # (held by construction, spy 0). The settlement auth envelope is
    # validated (admitted, operation 'settlement', this work item).
    param([string]$Dir = '', [string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1,
        [string]$Key = '', [string]$OwnerId = '', [long]$Generation = 0, [string]$Mark = 'no-prior-move',
        $SettleProof = $null, $SettleScript = $null, $IntentSnapshot = $null, $DispatchReceipt = $null,
        $Goal = $null, $SettleAuth = $null, [switch]$TestCallback)
    try {
        if (-not [bool]$TestCallback) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:test-callback-absent'; invoked = $false; intent = $null }
        }
        if ([string]::IsNullOrWhiteSpace($Dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; invoked = $false; intent = $null }
        }
        if ($null -eq $SettleScript) {
            return [pscustomobject]@{ ok = $false; reason = 'settlement-pending-reconciliation'; invoked = $false; intent = $null }
        }
        $authOk = $false
        try {
            if ((($SettleAuth -is [System.Collections.IDictionary]) -or ($SettleAuth -is [pscustomobject]))) {
                $adm = [bool](Get-ORFieldValue $SettleAuth 'admitted' $false)
                $aop = ([string](Get-ORFieldValue $SettleAuth 'operation' '')).Trim().ToLowerInvariant()
                $ars = ([string](Get-ORFieldValue $SettleAuth 'resource' '')).Trim()
                if ($adm -and ($aop -ceq 'settlement') -and (-not [string]::IsNullOrWhiteSpace($ars)) -and ($ars -ceq ([string]$WorkItemId).Trim())) { $authOk = $true }
            }
        }
        catch { $authOk = $false }
        if (-not $authOk) {
            return [pscustomobject]@{ ok = $false; reason = 'settlement-auth-denied'; invoked = $false; intent = $null }
        }
        $lock = Open-ORStoreLock -Dir $Dir -LockTimeoutMs 5000
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; invoked = $false; intent = $null }
        }
        try {
            $fence = Confirm-OROwnershipHeld -Dir $Dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
            if (-not [bool]$fence.held) {
                return [pscustomobject]@{ ok = $false; reason = [string]$fence.reason; invoked = $false; intent = $null }
            }
            $pg = Test-OREffectProof -Proof $SettleProof -Key $Key -OwnerId $OwnerId -Generation $Generation
            if (($null -eq $pg) -or (-not [bool]$pg.ok)) {
                $why = 'hold-unproven-effect:settlement-proof-missing'
                try { if (($null -ne $pg) -and (-not [string]::IsNullOrWhiteSpace([string]$pg.reason))) { $why = ('hold-unproven-effect:' + [string]$pg.reason) } } catch { }
                return [pscustomobject]@{ ok = $false; reason = $why; invoked = $false; intent = $null }
            }
            $settle = $null
            try { $settle = & $SettleScript $IntentSnapshot $DispatchReceipt $Goal $SettleAuth }
            catch { $settle = $null }
            $rc = Test-OREffectReceipt -Receipt $settle -Key $Key -Generation $Generation -Proof $SettleProof -Operation 'settlement'
            if (($null -eq $rc) -or (-not [bool]$rc.ok)) {
                $why = 'receipt-missing'
                try { if (($null -ne $rc) -and (-not [string]::IsNullOrWhiteSpace([string]$rc.reason))) { $why = [string]$rc.reason } } catch { }
                return [pscustomobject]@{ ok = $false; reason = $why; invoked = $true; intent = $null }
            }
            $fence2 = Confirm-OROwnershipHeld -Dir $Dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
            if (-not [bool]$fence2.held) {
                return [pscustomobject]@{ ok = $false; reason = [string]$fence2.reason; invoked = $true; intent = $null }
            }
            $path = Get-ORIntentFilePath -Dir $Dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; invoked = $true; intent = $null }
            }
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; invoked = $true; intent = $null }
            }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; invoked = $true; intent = $null }
            }
            $curSt = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ($curSt -ceq 'settled') {
                if ([string]$rec['consumed_from'] -ceq $Mark) {
                    return [pscustomobject]@{ ok = $true; reason = 'already-settled'; invoked = $true; intent = $rec; duplicate = $true }
                }
                return [pscustomobject]@{ ok = $false; reason = 'consume-conflict'; invoked = $true; intent = $null }
            }
            $rec['state'] = 'settled'
            $rec['consumed_from'] = $Mark
            $rec['consumed_at'] = Get-ORStamp
            $rec['updated_at'] = [string]$rec['consumed_at']
            $rec['settlement_receipt'] = $settle
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $Dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; invoked = $true; intent = $null }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; invoked = $true; intent = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; invoked = $true; intent = $rec; duplicate = $false }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'consume-not-durable-no-advance'; invoked = $false; intent = $null }
    }
}

function Get-OrchestrationObjectiveRequestHash {
    # D3 request identity: canonical key + expected goal revision. Same
    # key + same request => the stored original receipt is returned;
    # same key + different request => conflict (fail closed).
    [CmdletBinding()]
    param([string]$Key = '', [long]$ExpectedRevision = 0)
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        $rev = Get-ORLongValue $ExpectedRevision -1
        if ([string]::IsNullOrWhiteSpace($k) -or ($rev -lt 1)) { return '' }
        return (Get-ORHashHex32 ($k + '|' + [string]$rev))
    }
    catch { return '' }
}

function Test-OREffectProof {
    # D3/D6 pre-call gate: a DispatchImpl/SettleImpl callback is invoked
    # in the productive path ONLY with a proof binding fencing
    # (canonical owner + generation) and idempotency (intent key) to the
    # declared destination/action. Absent or malformed proof => HOLD
    # before the call; the callback is never invoked.
    param($Proof, [string]$Key = '', [string]$OwnerId = '', [long]$Generation = 0)
    try {
        if ($null -eq $Proof) { return [pscustomobject]@{ ok = $false; reason = 'effect-proof-missing' } }
        if ((-not ($Proof -is [System.Collections.IDictionary])) -and (-not ($Proof -is [pscustomobject]))) {
            return [pscustomobject]@{ ok = $false; reason = 'effect-proof-malformed' }
        }
        $dst = [string](Get-ORFieldValue $Proof 'destination' '')
        $act = [string](Get-ORFieldValue $Proof 'action' '')
        if ([string]::IsNullOrWhiteSpace($dst) -or [string]::IsNullOrWhiteSpace($act)) {
            return [pscustomobject]@{ ok = $false; reason = 'effect-proof-missing-destination-action' }
        }
        $fOwner = [string](Get-ORFieldValue $Proof 'fencing_owner' '')
        $fGen = Get-ORLongValue (Get-ORFieldValue $Proof 'fencing_generation' $null) -1
        if (((Get-ORCanonicalId $fOwner) -cne (Get-ORCanonicalId $OwnerId)) -or ($fGen -ne (Get-ORLongValue $Generation -1))) {
            return [pscustomobject]@{ ok = $false; reason = 'effect-proof-fencing-mismatch' }
        }
        $idem = [string](Get-ORFieldValue $Proof 'idempotency_key' '')
        if ([string]::IsNullOrWhiteSpace($idem) -or ($idem.Trim().ToLowerInvariant() -cne ([string]$Key).Trim().ToLowerInvariant())) {
            return [pscustomobject]@{ ok = $false; reason = 'effect-proof-idempotency-mismatch' }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'effect-proof-malformed' } }
}

function Test-ORGrantTokenDenied {
    # F7 strict grammar shared probe: true when the Grants string carries
    # any deny (bare or scoped) or any malformed colon token. Bare
    # capability labels without ':' (e.g. 'ops', 'g', 'fs.read') are
    # ignored; any token containing ':' must be a well-formed
    # allow:<op>[:<resource>] or deny[:...], otherwise it denies.
    param([string]$Grants = '')
    try {
        $closedOps = @('dispatch', 'reconcile', 'settlement', 'checkpoint', 'advance', 'terminalize')
        foreach ($t in @([string]$Grants -split '[,;|\s]+')) {
            $tok = ([string]$t).Trim()
            if ([string]::IsNullOrWhiteSpace($tok)) { continue }
            $low = $tok.ToLowerInvariant()
            if (($low -ceq 'deny') -or ($low -ceq 'denied') -or ($low -ceq 'deny-all') -or ($low -ceq 'inconclusive') -or ($low -ceq 'unknown') -or ($low -ceq 'none')) { return $true }
            if ($low.StartsWith('deny:') -or $low.StartsWith('denied:') -or $low.StartsWith('deny-all')) { return $true }
            if ($low.StartsWith('allow:')) {
                $rest = $low.Substring(6)
                $parts = @($rest -split ':')
                $bad = $false
                if ([string]::IsNullOrWhiteSpace($rest)) { $bad = $true }
                elseif (($parts.Count -lt 1) -or ($parts.Count -gt 2)) { $bad = $true }
                elseif ($closedOps -cnotcontains $parts[0]) { $bad = $true }
                elseif (($parts.Count -eq 2) -and (([string]::IsNullOrWhiteSpace($parts[1])) -or ($parts[1] -cnotmatch '^[a-z0-9._:-]+$' -and ($parts[1] -cne '*')))) { $bad = $true }
                if ($bad) { return $true }
                continue
            }
            if ($tok.Contains(':')) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-ORDecisionDenied {
    # F7: a negative caller Decision vetoes any allow, even with a valid
    # grant reference. Covers bare deny tokens and scoped deny: forms.
    param([string]$Decision = '')
    try {
        $d = ([string]$Decision).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($d)) { return $false }
        if (($d -ceq 'deny') -or ($d -ceq 'denied') -or ($d -ceq 'deny-all') -or ($d -ceq 'inconclusive') -or ($d -ceq 'unknown') -or ($d -ceq 'none')) { return $true }
        if ($d.StartsWith('deny:') -or $d.StartsWith('denied:') -or $d.StartsWith('deny-all')) { return $true }
        return $false
    }
    catch { return $false }
}

function Test-OREffectReceipt {
    # D3/F3 commit receipt: destination + action + task/run + generation
    # + result, bound to the canonical intent key. The impl's ok /
    # dispatched flags and any self-declared envelope are NEVER consulted
    # here: they do not prove a commit.
    # F3: when -Proof is supplied the receipt destination/action must
    # equal the proof destination/action (a swapped receipt is rejected);
    # when -Operation is supplied the receipt must carry that operation
    # (a dispatch receipt never satisfies the settlement gate).
    param($Receipt, [string]$Key = '', [long]$Generation = 0, $Proof = $null, [string]$Operation = '')
    try {
        if ($null -eq $Receipt) { return [pscustomobject]@{ ok = $false; reason = 'receipt-missing' } }
        if ((-not ($Receipt -is [System.Collections.IDictionary])) -and (-not ($Receipt -is [pscustomobject]))) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-malformed' }
        }
        $dst = [string](Get-ORFieldValue $Receipt 'destination' '')
        $act = [string](Get-ORFieldValue $Receipt 'action' '')
        if ([string]::IsNullOrWhiteSpace($dst) -or [string]::IsNullOrWhiteSpace($act)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-missing-destination-action' }
        }
        $task = [string](Get-ORFieldValue $Receipt 'task_id' '')
        $run = [string](Get-ORFieldValue $Receipt 'run_id' '')
        if ([string]::IsNullOrWhiteSpace($task) -and [string]::IsNullOrWhiteSpace($run)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-missing-task-run' }
        }
        $rGen = Get-ORLongValue (Get-ORFieldValue $Receipt 'generation' $null) -1
        if ($rGen -ne (Get-ORLongValue $Generation -1)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-generation-mismatch' }
        }
        $res = [string](Get-ORFieldValue $Receipt 'result' '')
        if ([string]::IsNullOrWhiteSpace($res)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-missing-result' }
        }
        $idem = [string](Get-ORFieldValue $Receipt 'idempotency_key' '')
        if ([string]::IsNullOrWhiteSpace($idem) -or ($idem.Trim().ToLowerInvariant() -cne ([string]$Key).Trim().ToLowerInvariant())) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-idempotency-mismatch' }
        }
        $opWant = ([string]$Operation).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($opWant)) {
            $rOp = ([string](Get-ORFieldValue $Receipt 'operation' '')).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($rOp) -or ($rOp -cne $opWant)) {
                return [pscustomobject]@{ ok = $false; reason = 'receipt-operation-mismatch' }
            }
        }
        if ($null -ne $Proof) {
            if ((($Proof -is [System.Collections.IDictionary]) -or ($Proof -is [pscustomobject]))) {
                $pDst = [string](Get-ORFieldValue $Proof 'destination' '')
                $pAct = [string](Get-ORFieldValue $Proof 'action' '')
                if (-not [string]::IsNullOrWhiteSpace($pDst)) {
                    if ($dst -cne $pDst) { return [pscustomobject]@{ ok = $false; reason = 'receipt-destination-mismatch' } }
                }
                if (-not [string]::IsNullOrWhiteSpace($pAct)) {
                    if ($act -cne $pAct) { return [pscustomobject]@{ ok = $false; reason = 'receipt-action-mismatch' } }
                }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'receipt-malformed' } }
}

function Set-ORDispatchReceiptCAS {
    # D3 durable receipt with CAS: stores the commit receipt and moves the
    # intent to 'pending' atomically under the store lock. A stored
    # receipt with the SAME request hash returns the original receipt
    # (idempotent, no new effect); a DIFFERENT request hash on the same
    # key is a conflict (fail closed). Fencing revalidated under lock.
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1, [string]$RequestHash = '', $Receipt = $null, [string]$StoreDir = '', [int]$LockTimeoutMs = 500, [string]$OwnerId = '', [long]$Generation = 0)
    try {
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; intent = $null; duplicate = $false }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; intent = $null; duplicate = $false }
        }
        try {
            $path = Get-ORIntentFilePath -Dir $dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; intent = $null; duplicate = $false }
            }
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null; duplicate = $false }
            }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null; duplicate = $false }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                $f = Confirm-OROwnershipHeld -Dir $dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
                if (-not [bool]$f.held) {
                    return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; intent = $null; duplicate = $false }
                }
            }
            $storedHash = [string]$rec['request_hash']
            $storedReceipt = Get-ORFieldValue $rec 'receipt' $null
            if ($null -ne $storedReceipt) {
                if ((-not [string]::IsNullOrWhiteSpace($storedHash)) -and ($storedHash -ceq [string]$RequestHash)) {
                    return [pscustomobject]@{ ok = $true; reason = 'duplicate-receipt-original'; intent = $rec; duplicate = $true }
                }
                return [pscustomobject]@{ ok = $false; reason = 'receipt-conflict'; intent = $null; duplicate = $false }
            }
            $rec['request_hash'] = [string]$RequestHash
            $rec['receipt'] = $Receipt
            $cur = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ((@('intended', 'dispatched', 'dispatched-unknown') -ccontains $cur)) { $rec['state'] = 'pending' }
            $rec['updated_at'] = Get-ORStamp
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'receipt-not-durable-no-advance'; intent = $null; duplicate = $false }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'receipt-not-durable-no-advance'; intent = $null; duplicate = $false }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec; duplicate = $false }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'receipt-not-durable-no-advance'; intent = $null; duplicate = $false }
    }
}

function Set-ORDispatchStageCAS {
    # D4 stage gate: settled -> checkpointed -> advanced, one stage per
    # call, fencing revalidated under the same lock. Anything else is an
    # invalid transition (fail closed); a duplicate of the running stage
    # is idempotent success, never a second effect.
    # F5: when advancing, -NextMove persists the continuation move/move
    # receipt atomically with the 'advanced' transition; a replay of an
    # already-advanced intent returns the persisted move (never null when
    # the transition was durable).
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1, [string]$ToStage = '', [string]$StoreDir = '', [int]$LockTimeoutMs = 500, [string]$OwnerId = '', [long]$Generation = 0, [string]$CheckpointId = '', $NextMove = $null)
    try {
        $want = ([string]$ToStage).Trim().ToLowerInvariant()
        if ((@('checkpointed', 'advanced') -cnotcontains $want)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-stage'; intent = $null; duplicate = $false }
        }
        $need = 'settled'
        if ($want -ceq 'advanced') { $need = 'checkpointed' }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; intent = $null; duplicate = $false }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; intent = $null; duplicate = $false }
        }
        try {
            $path = Get-ORIntentFilePath -Dir $dir -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision (Get-ORLongValue $ActionRevision -1)
            if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'intent-not-found'; intent = $null; duplicate = $false }
            }
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null; duplicate = $false }
            }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; intent = $null; duplicate = $false }
            }
            if (-not [string]::IsNullOrWhiteSpace($OwnerId)) {
                $f = Confirm-OROwnershipHeld -Dir $dir -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
                if (-not [bool]$f.held) {
                    return [pscustomobject]@{ ok = $false; reason = [string]$f.reason; intent = $null; duplicate = $false }
                }
            }
            $cur = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ($cur -ceq $want) {
                return [pscustomobject]@{ ok = $true; reason = 'already-staged'; intent = $rec; duplicate = $true }
            }
            if ($cur -cne $need) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-transition'; intent = $null; duplicate = $false }
            }
            $rec['state'] = $want
            if (($want -ceq 'checkpointed') -and (-not [string]::IsNullOrWhiteSpace($CheckpointId))) {
                $rec['checkpoint_id'] = [string]$CheckpointId
            }
            if (($want -ceq 'advanced') -and ($null -ne $NextMove)) {
                $rec['next_move'] = $NextMove
            }
            $rec['updated_at'] = Get-ORStamp
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'stage-not-durable-no-advance'; intent = $null; duplicate = $false }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'stage-not-durable-no-advance'; intent = $null; duplicate = $false }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; intent = $rec; duplicate = $false }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'stage-not-durable-no-advance'; intent = $null; duplicate = $false }
    }
}

function Test-ORAdvanceMarked {
    # D4 diary advance marker: true only when the marker file for the
    # canonical key exists with the same request hash.
    param([string]$Dir = '', [string]$Key = '', [string]$RequestHash = '')
    try {
        $p = Get-ORAdvanceMarkerPath -Dir $Dir -Key $Key
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) }
        catch { return $false }
        $mk = ([string](Get-ORFieldValue $raw 'key' '')).Trim().ToLowerInvariant()
        if ($mk -cne ([string]$Key).Trim().ToLowerInvariant()) { return $false }
        $mh = [string](Get-ORFieldValue $raw 'request_hash' '')
        if ([string]::IsNullOrWhiteSpace($mh) -or [string]::IsNullOrWhiteSpace([string]$RequestHash)) { return $false }
        return ($mh -ceq [string]$RequestHash)
    }
    catch { return $false }
}

function Save-ORAdvanceMarker {
    # Best-effort diary write (never throws, never authorizes): records
    # that the advance stage ran for this key + request.
    param([string]$Dir = '', [string]$Key = '', [string]$RequestHash = '')
    try {
        $p = Get-ORAdvanceMarkerPath -Dir $Dir -Key $Key
        if ([string]::IsNullOrWhiteSpace($p)) { return $false }
        try {
            if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($Dir) }
        }
        catch { return $false }
        $rec = [ordered]@{
            schema_version = 1
            key            = ([string]$Key).Trim().ToLowerInvariant()
            request_hash   = [string]$RequestHash
            advanced_at    = Get-ORStamp
        }
        $json = ConvertTo-Json -InputObject $rec -Depth 10 -Compress
        $tmp = Join-Path $Dir (('advance-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
        catch { return $false }
        try { Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return $false
        }
        return $true
    }
    catch { return $false }
}

function New-OrchestrationObjectiveOwnership {
    [CmdletBinding()]
    param([string]$OwnerId = '', [long]$Generation = 0)
    try {
        $oid = ([string]$OwnerId).Trim()
        if ([string]::IsNullOrWhiteSpace($oid) -or ($oid.Length -gt 128) -or ($oid -notmatch '^[A-Za-z0-9._:-]{1,128}$')) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; ownership = $null }
        }
        $gen = Get-ORLongValue $Generation -1
        if ($gen -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-generation'; ownership = $null }
        }
        $rec = [ordered]@{ owner_id = $oid; generation = [long]$gen }
        return [pscustomobject]@{ ok = $true; reason = ''; ownership = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; ownership = $null }
    }
}

function Test-OrchestrationObjectiveOwnership {
    [CmdletBinding()]
    param($Current = $null, $Claimant = $null, $Now = $null)
    try {
        if ($null -eq $Current) { return [pscustomobject]@{ ok = $true; reason = 'no-current-owner'; admitted = $true } }
        $curOwner = [string](Get-ORFieldValue $Current 'owner_id' '')
        $curGen = Get-ORLongValue (Get-ORFieldValue $Current 'generation' $null) -1
        $newOwner = [string](Get-ORFieldValue $Claimant 'owner_id' '')
        $newGen = Get-ORLongValue (Get-ORFieldValue $Claimant 'generation' $null) -1
        if ([string]::IsNullOrWhiteSpace($curOwner) -or ($curGen -lt 1)) {
            return [pscustomobject]@{ ok = $true; reason = 'no-current-owner'; admitted = $true }
        }
        if ([string]::IsNullOrWhiteSpace($newOwner) -or ($newGen -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-claimant'; admitted = $false }
        }
        # R1 lease: an unexpired lease keeps mutual exclusion (a different
        # owner is always a conflict, even at a higher generation); an
        # expired lease allows takeover ONLY by a strictly higher
        # generation. A stale generation never continues after a superior
        # one, whatever the owner. Missing/unparseable expires_at means
        # the lease is still active (fail closed, legacy records).
        $nowUtc = $null
        try {
            if ($null -ne $Now) {
                if ($Now -is [DateTime]) { $nowUtc = ([DateTime]$Now).ToUniversalTime() }
                else {
                    $probe = Get-ORLeaseInstant $Now
                    if ($null -ne $probe) { $nowUtc = $probe }
                }
            }
            if ($null -eq $nowUtc) { $nowUtc = Get-ORNowUtc }
        }
        catch { $nowUtc = Get-ORNowUtc }
        $expired = $false
        $expRaw = Get-ORFieldValue $Current 'expires_at' $null
        if ($null -ne $expRaw) {
            $exp = Get-ORLeaseInstant $expRaw
            if (($null -ne $exp) -and ($nowUtc -ge $exp)) { $expired = $true }
        }
        if ($expired) {
            if ($newGen -gt $curGen) {
                return [pscustomobject]@{ ok = $true; reason = 'lease-expired-takeover'; admitted = $true }
            }
            return [pscustomobject]@{ ok = $false; reason = 'owner-obsolete'; admitted = $false }
        }
        if ($newOwner -ceq $curOwner) {
            if ($newGen -lt $curGen) {
                return [pscustomobject]@{ ok = $false; reason = 'owner-obsolete'; admitted = $false }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; admitted = $true }
        }
        # D2: canonically-equal but ordinally-divergent owner spellings
        # are a legacy case divergence => identity HOLD (never merged,
        # never treated as a rival conflict).
        if ((Get-ORCanonicalId $newOwner) -ceq (Get-ORCanonicalId $curOwner)) {
            return [pscustomobject]@{ ok = $false; reason = 'identity-hold-case-divergence'; admitted = $false }
        }
        return [pscustomobject]@{ ok = $false; reason = 'owner-conflict'; admitted = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; admitted = $false }
    }
}

function Acquire-OrchestrationObjectiveOwnership {
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [long]$ExpectedRevision = 0,
        [string]$StoreDir = '',
        [int]$LockTimeoutMs = 500,
        [long]$LeaseTtlMs = 60000,
        [string]$GoalStoreDir = ''
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-ORGoalIdValue $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; ownership = $null }
        }
        $claim = New-OrchestrationObjectiveOwnership -OwnerId $OwnerId -Generation $Generation
        if (-not [bool]$claim.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$claim.reason; ownership = $null }
        }
        $expRev = Get-ORLongValue $ExpectedRevision -1
        if ($expRev -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-expected-revision'; ownership = $null }
        }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; ownership = $null }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; ownership = $null }
        }
        $lock = Open-ORStoreLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; ownership = $null }
        }
        try {
            $path = Get-OROwnerFilePath -Dir $dir -GoalId $gid
            if ([string]::IsNullOrWhiteSpace($path)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; ownership = $null }
            }
            # R1 real CAS: when the goal store is supplied, the expected
            # revision is compared against the REAL loaded goal revision,
            # not only the auxiliary owner file below. Without GoalStoreDir
            # only the auxiliary check applies (declared frontier: callers
            # in the executor always pass it).
            if (-not [string]::IsNullOrWhiteSpace($GoalStoreDir)) {
                $realRev = [long]-1
                $realOk = $false
                try {
                    $getGoalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
                    if ($null -ne $getGoalCmd) {
                        $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
                        if (($null -ne $slot) -and ([bool](Get-ORFieldValue $slot 'ok' $false)) -and ($null -ne (Get-ORFieldValue $slot 'goal' $null))) {
                            $realRev = Get-ORLongValue (Get-ORFieldValue (Get-ORFieldValue $slot 'goal' $null) 'revision' $null) -1
                            $realOk = ($realRev -ge 1)
                        }
                    }
                    else { $realOk = $true; $realRev = $expRev }
                }
                catch { $realOk = $false }
                if (-not $realOk) {
                    return [pscustomobject]@{ ok = $false; reason = 'goal-read-failed'; ownership = $null }
                }
                if ($realRev -ne $expRev) {
                    return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; ownership = $null }
                }
            }
            $current = $null
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try { $current = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
                catch {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-owner-record'; ownership = $null }
                }
                # F4: identity before any admission or write. A stored
                # display spelling that diverges (same canonical goal,
                # different grafia) is HOLD without overwrite, even when
                # owner and revision otherwise match.
                try {
                    if (Test-ORIdentityHold ([string](Get-ORFieldValue $current 'goal_id' '')) $gid) {
                        return [pscustomobject]@{ ok = $false; reason = 'identity-hold-case-divergence'; ownership = $null }
                    }
                }
                catch { }
                # F6: distinguish the effect-origin revision from the live
                # revision. When the real goal revision was verified above
                # (GoalStoreDir supplied), a stored auxiliary revision that
                # differs is NOT a hard conflict: the ownership gate below
                # decides (same-owner advance or expired-lease takeover at
                # the live revision admits; a live rival still denies).
                # Without GoalStoreDir there is no live check, so the
                # auxiliary comparison stays as the only fence.
                $storedRev = Get-ORLongValue (Get-ORFieldValue $current 'goal_revision' $null) -1
                if ($storedRev -ne $expRev) {
                    if ([string]::IsNullOrWhiteSpace($GoalStoreDir)) {
                        $curOwner = [string](Get-ORFieldValue $current 'owner_id' '')
                        $curGen = Get-ORLongValue (Get-ORFieldValue $current 'generation' $null) -1
                        if ((-not [string]::IsNullOrWhiteSpace($curOwner)) -and ($curGen -ge 1)) {
                            return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; ownership = $null }
                        }
                    }
                }
            }
            $gate = Test-OrchestrationObjectiveOwnership -Current $current -Claimant $claim.ownership
            if (-not [bool]$gate.ok) {
                return [pscustomobject]@{ ok = $false; reason = [string]$gate.reason; ownership = $null }
            }
            $stamp = Get-ORStamp
            # R1 lease: verifiable expiry bound to the fencing generation.
            $expiresAt = ''
            try {
                $ttl = [long]$LeaseTtlMs
                if ($ttl -gt 0) { $expiresAt = ([DateTime]::UtcNow.AddMilliseconds($ttl)).ToString('o') }
            }
            catch { $expiresAt = '' }
            $rec = [ordered]@{
                schema_version = 1
                goal_id        = $gid
                owner_id       = [string]$claim.ownership['owner_id']
                generation     = [long]$claim.ownership['generation']
                goal_revision  = [long]$expRev
                acquired_at    = $stamp
                expires_at     = $expiresAt
                lease_ttl_ms   = [long]$LeaseTtlMs
                updated_at     = $stamp
            }
            $json = ConvertTo-Json -InputObject $rec -Depth 20 -Compress
            $tmp = Join-Path $dir (('owner-' + [IO.Path]::GetRandomFileName() + '.tmp'))
            try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'owner-write-failed'; ownership = $null }
            }
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'owner-write-failed'; ownership = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; ownership = $rec }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; ownership = $null }
    }
}

function Test-OrchestrationObjectiveBudget {
    [CmdletBinding()]
    param($Goal = $null, [string]$Scope = 'worker', [bool]$Exhausted = $false)
    try {
        $scope = ([string]$Scope).Trim().ToLowerInvariant()
        if (@('worker', 'task', 'goal-hard') -cnotcontains $scope) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-scope'; decision = 'block'; stop_reason = ''; terminal = $false }
        }
        $rawBudget = Get-ORFieldValue $Goal 'budget' $null
        if ($null -eq $rawBudget) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; decision = 'block'; stop_reason = ''; terminal = $false }
        }
        $soft = Get-ORLongValue (Get-ORFieldValue $rawBudget 'soft_cap' $null) -1
        $hard = Get-ORLongValue (Get-ORFieldValue $rawBudget 'hard_cap' $null) -1
        $spent = Get-ORLongValue (Get-ORFieldValue $rawBudget 'spent' $null) -1
        if (($soft -lt 0) -or ($hard -lt 0) -or ($spent -lt 0)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-budget'; decision = 'block'; stop_reason = ''; terminal = $false }
        }
        if (($hard -gt 0) -and ($spent -ge $hard)) {
            return [pscustomobject]@{ ok = $true; reason = 'goal-hard-budget-exhausted'; decision = 'terminal'; stop_reason = 'GOAL_HARD_BUDGET_EXHAUSTED'; terminal = $true }
        }
        if ($scope -ceq 'goal-hard') {
            if ($Exhausted) {
                return [pscustomobject]@{ ok = $true; reason = 'goal-hard-budget-exhausted'; decision = 'terminal'; stop_reason = 'GOAL_HARD_BUDGET_EXHAUSTED'; terminal = $true }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; decision = 'proceed'; stop_reason = ''; terminal = $false }
        }
        if ($Exhausted) {
            return [pscustomobject]@{ ok = $true; reason = 'scope-exhausted-replan'; decision = 'replan'; stop_reason = ''; terminal = $false }
        }
        if (($soft -gt 0) -and ($spent -ge $soft)) {
            return [pscustomobject]@{ ok = $true; reason = 'soft-cap-reached-replan'; decision = 'replan'; stop_reason = ''; terminal = $false }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; decision = 'proceed'; stop_reason = ''; terminal = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-budget'; decision = 'block'; stop_reason = ''; terminal = $false }
    }
}

function New-OrchestrationObjectiveAuthEnvelope {
    [CmdletBinding()]
    param(
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [bool]$Optional = $false,
        [string]$Operation = '',
        [string]$Resource = '',
        [string]$Decision = ''
    )
    try {
        Import-ORLibFile 'OrchestrationRuntimeAdapterContract.ps1'
        $cmd = Get-Command New-OrchestrationAdapterAuthEnvelope -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            try {
                return (New-OrchestrationAdapterAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Optional ([bool]$Optional) -Operation $Operation -Resource $Resource -Decision $Decision)
            }
            catch { }
        }
        $missing = New-Object System.Collections.ArrayList
        if ([string]::IsNullOrWhiteSpace($User)) { [void]$missing.Add('user') }
        if ([string]::IsNullOrWhiteSpace($Project)) { [void]$missing.Add('project') }
        if ([string]::IsNullOrWhiteSpace($Runtime)) { [void]$missing.Add('runtime') }
        if ([string]::IsNullOrWhiteSpace($Grants)) { [void]$missing.Add('grants') }
        if ($missing.Count -gt 0) {
            return [pscustomobject]@{
                ok                = $false
                admitted          = $false
                reason            = ('POLICY-BLOCKED:missing-' + ($missing -join ','))
                fallback_continue = [bool]$Optional
                operation         = [string]$Operation
                resource          = [string]$Resource
                decision          = [string]$Decision
                explicit_allow    = $false
                grant_ref         = ''
                grants_authority  = $false
                done_approved     = $false
            }
        }
        # S1 fallback mirrors the contract (D5): closed operation set,
        # deny/inconclusive tokens deny, and an explicit 'allow:<op>'
        # grant reference is required. A caller Decision='allow' alone is
        # never a self-grant.
        $opCanon = ([string]$Operation).Trim().ToLowerInvariant()
        $opAlias = @{
            dispatchworker = 'dispatch'; dispatch = 'dispatch';
            reconcileeffect = 'reconcile'; reconcile = 'reconcile';
            waitforsettlement = 'settlement'; settle = 'settlement'; settlement = 'settlement';
            checkpoint = 'checkpoint'; advance = 'advance'; nextmove = 'advance';
            terminalize = 'terminalize'; terminal = 'terminalize'
        }
        if ([string]::IsNullOrWhiteSpace($opCanon) -or (-not $opAlias.ContainsKey($opCanon))) {
            return [pscustomobject]@{
                ok = $false; admitted = $false; reason = 'POLICY-BLOCKED:operation-not-allowed'
                fallback_continue = $false; operation = [string]$Operation; resource = [string]$Resource
                decision = [string]$Decision; explicit_allow = $false; grant_ref = ''
                grants_authority = $false; done_approved = $false
            }
        }
        $opNeed = [string]$opAlias[$opCanon]
        $resCanon = ([string]$Resource).Trim().ToLowerInvariant()
        # F7 strict grammar (mirrors the contract): scoped deny tokens
        # (deny:<op>[:<resource>]) and malformed colon tokens deny the
        # whole envelope; a negative caller Decision vetoes any allow.
        $denied = [bool](Test-ORGrantTokenDenied -Grants ([string]$Grants))
        if (-not $denied) { $denied = [bool](Test-ORDecisionDenied -Decision ([string]$Decision)) }
        if ($denied) {
            return [pscustomobject]@{
                ok                = $false
                admitted          = $false
                reason            = 'POLICY-BLOCKED:grants-deny'
                fallback_continue = $false
                operation         = [string]$Operation
                resource          = [string]$Resource
                decision          = [string]$Decision
                explicit_allow    = $false
                grant_ref         = ''
                grants_authority  = $false
                done_approved     = $false
            }
        }
        $grantRef = ''
        try {
            foreach ($t in @([string]$Grants -split '[,;|\s]+')) {
                $tok = ([string]$t).Trim().ToLowerInvariant()
                if (($tok.Length -le 6) -or (-not $tok.StartsWith('allow:'))) { continue }
                $rest = $tok.Substring(6)
                $parts = @($rest -split ':')
                if (($parts.Count -eq 1) -and ($parts[0] -ceq $opNeed)) { $grantRef = ([string]$t).Trim(); break }
                if (($parts.Count -eq 2) -and ($parts[0] -ceq $opNeed) -and (-not [string]::IsNullOrWhiteSpace($parts[1])) -and (-not [string]::IsNullOrWhiteSpace($resCanon))) {
                    if (($parts[1] -ceq '*') -or ($parts[1] -ceq $resCanon)) { $grantRef = ([string]$t).Trim(); break }
                }
            }
        }
        catch { $grantRef = '' }
        if ([string]::IsNullOrWhiteSpace($grantRef)) {
            $whyNot = 'POLICY-BLOCKED:operation-not-authorized'
            try {
                if (([string]$Decision).Trim().ToLowerInvariant() -ceq 'allow') { $whyNot = 'POLICY-BLOCKED:self-grant-rejected' }
            }
            catch { }
            return [pscustomobject]@{
                ok = $false; admitted = $false; reason = $whyNot
                fallback_continue = $false; operation = [string]$Operation; resource = [string]$Resource
                decision = [string]$Decision; explicit_allow = $false; grant_ref = ''
                grants_authority = $false; done_approved = $false
            }
        }
        return [pscustomobject]@{
            ok                = $true
            admitted          = $true
            reason            = 'intersection-user-project-runtime-grants'
            fallback_continue = $false
            operation         = [string]$Operation
            resource          = [string]$Resource
            decision          = [string]$Decision
            explicit_allow    = $true
            grant_ref         = [string]$grantRef
            grants_authority  = $false
            done_approved     = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok                = $false
            admitted          = $false
            reason            = 'POLICY-BLOCKED:internal-error'
            fallback_continue = [bool]$Optional
            operation         = [string]$Operation
            resource          = [string]$Resource
            decision          = [string]$Decision
            grants_authority  = $false
            done_approved     = $false
        }
    }
}

function Get-OrchestrationObjectiveWatchdogReference {
    [CmdletBinding()]
    param()
    try {
        Import-ORLibFile 'OrchestrationRuntimeAdapterContract.ps1'
        $cmd = Get-Command Get-OrchestrationAdapterWatchdogReference -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            try { return (Get-OrchestrationAdapterWatchdogReference) } catch { }
        }
        return [pscustomobject]@{
            signals         = @('NO_PROGRESS', 'HARD_TIMEOUT')
            mode            = 'referenced-not-driven'
            drives_watchdog = $false
            grants_authority = $false
            done_approved    = $false
        }
    }
    catch {
        return [pscustomobject]@{
            signals         = @('NO_PROGRESS', 'HARD_TIMEOUT')
            mode            = 'referenced-not-driven'
            drives_watchdog = $false
            grants_authority = $false
            done_approved    = $false
        }
    }
}

function Invoke-ORDefaultDispatch {
    param($Intent, $Goal, $AuthContext)
    try {
        Import-ORLibFile 'OrchestrationRuntimeAdapterContract.ps1'
        $holds = @()
        try {
            $cmd = Get-Command Get-OrchestrationAdapterHoldOperations -ErrorAction SilentlyContinue
            if ($null -ne $cmd) { $holds = @(Get-OrchestrationAdapterHoldOperations) }
        }
        catch { $holds = @() }
        if ($holds -contains 'dispatchWorker') {
            return [pscustomobject]@{
                ok                = $false
                dispatched        = $false
                reason            = 'hold-dispatchWorker:no-proven-api-effect-observable'
                fallback_continue = $true
                grants_authority  = $false
                done_approved     = $false
                verified_pass     = $false
            }
        }
        return [pscustomobject]@{
            ok                = $false
            dispatched        = $false
            reason            = 'hold-dispatchWorker:no-proven-api-effect-observable'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok                = $false
            dispatched        = $false
            reason            = 'hold-dispatchWorker:no-proven-api-effect-observable'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
}

function New-ORBaseResult {
    param($Event)
    try {
        $gid = ''
        $wid = ''
        $rev = [long]0
        try {
            if ($null -ne $Event) {
                if ($Event -is [System.Collections.IDictionary]) {
                    if ($Event.Contains('goal_id')) { $gid = [string]$Event['goal_id'] }
                    if ($Event.Contains('work_item_id')) { $wid = [string]$Event['work_item_id'] }
                    if ($Event.Contains('action_revision')) { $rev = Get-ORLongValue $Event['action_revision'] 0 }
                }
                else {
                    $pg = $Event.PSObject.Properties['goal_id']
                    if ($null -ne $pg) { $gid = [string]$pg.Value }
                    $pw = $Event.PSObject.Properties['work_item_id']
                    if ($null -ne $pw) { $wid = [string]$pw.Value }
                    $pr = $Event.PSObject.Properties['action_revision']
                    if ($null -ne $pr) { $rev = Get-ORLongValue $pr.Value 0 }
                }
            }
        }
        catch { }
        return [ordered]@{
            ok               = $false
            reason           = ''
            goal_id          = $gid
            work_item_id     = $wid
            action_revision  = $rev
            intent_key       = ''
            intent_state     = ''
            receipt          = $null
            dispatched       = $false
            duplicate        = $false
            decision         = ''
            stop_reason      = ''
            fallback         = ''
            task_result      = $null
            settlement       = ''
            verification     = 'kernel-only'
            checkpoint_id    = ''
            consumed_move    = $null
            next_move        = $null
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
        }
    }
    catch {
        return [ordered]@{
            ok               = $false
            reason           = 'internal-error'
            goal_id          = ''
            work_item_id     = ''
            action_revision  = [long]0
            intent_key       = ''
            intent_state     = ''
            receipt          = $null
            dispatched       = $false
            duplicate        = $false
            decision         = ''
            stop_reason      = ''
            fallback         = ''
            task_result      = $null
            settlement       = ''
            verification     = 'kernel-only'
            checkpoint_id    = ''
            consumed_move    = $null
            next_move        = $null
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
        }
    }
}

function Invoke-ORControllerMove {
    # M1: the NextMoveImpl seam is TEST-ONLY and declared by the explicit
    # -TestCallback switch. A supplied impl without the switch is never
    # invoked (unavailable, spy 0); only a null impl falls back to the
    # native move.
    param($Goal, $NextMoveImpl, [switch]$TestCallback)
    try {
        if ($null -ne $NextMoveImpl) {
            if (-not [bool]$TestCallback) { return $null }
            try {
                $m = & $NextMoveImpl $Goal
                if ($null -ne $m) { return $m }
            }
            catch { return $null }
            return $null
        }
        Import-ORLibFile 'OrchestrationGoalKernel.ps1'
        $cmd = Get-Command Get-OrchestrationGoalNextMove -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { return $null }
        try {
            $slot = Get-OrchestrationGoalNextMove -Goal $Goal
            if (($null -ne $slot) -and ([bool]$slot.ok) -and ($null -ne $slot.next_move)) { return $slot.next_move }
        }
        catch { return $null }
        return $null
    }
    catch { return $null }
}

function Invoke-ORCheckpoint {
    # M1: the CheckpointImpl seam is TEST-ONLY and declared by the
    # explicit -TestCallback switch. A supplied impl without the switch
    # is never invoked (unavailable, spy 0); only a null impl falls back
    # to the native checkpoint.
    param($Goal, $CheckpointImpl, [switch]$TestCallback)
    try {
        if ($null -ne $CheckpointImpl) {
            if (-not [bool]$TestCallback) { return '' }
            try {
                $c = & $CheckpointImpl $Goal
                if ($null -eq $c) { return '' }
                $cid = [string](Get-ORFieldValue $c 'checkpoint_id' '')
                if ($null -ne $c.PSObject) {
                    $pp = $c.PSObject.Properties['checkpoint_id']
                    if ($null -ne $pp) { $cid = [string]$pp.Value }
                }
                return $cid
            }
            catch { return '' }
        }
        Import-ORLibFile 'OrchestrationGoalCheckpoint.ps1'
        $cmd = Get-Command New-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue
        if ($null -eq $cmd) { return '' }
        try {
            $rec = New-OrchestrationGoalCheckpoint -GoalRecord $Goal
            if ($null -eq $rec) { return '' }
            return [string]$rec['checkpoint_id']
        }
        catch { return '' }
        return ''
    }
    catch { return '' }
}

function Invoke-ORAdvanceStages {
    # D4 replay-by-stage: runs ONLY the missing stages after settlement
    # (checkpoint, then advance). Never dispatches, never settles: those
    # stages are behind us. Mutates $Base in place; returns $true only
    # when the intent reaches 'advanced'. Every gate denies fail-closed.
    param($Base, $Goal, [string]$GoalId = '', [string]$WorkItemId = '', [long]$ActionRevision = 1,
        [string]$GoalStoreDir = '', [string]$DispatchStoreDir = '', [string]$OwnerId = '', [long]$Generation = 0,
        [long]$ExpectedRevision = 0, [string]$User = '', [string]$Project = '', [string]$Runtime = '',
        [string]$Grants = '', $CheckpointImpl = $null, $NextMoveImpl = $null, [int]$LockTimeoutMs = 500,
        [string]$FromStage = 'settled', [switch]$TestCallback)
    try {
        $dirNow = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir
        $fence2 = Confirm-OROwnershipHeld -Dir $dirNow -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation
        if (-not [bool]$fence2.held) {
            $Base['reason'] = [string]$fence2.reason
            $Base['decision'] = 'settlement-pending'
            return $false
        }
        try {
            if (-not [string]::IsNullOrWhiteSpace($GoalStoreDir)) {
                $reGoal = $null
                $reReadFailed = $false
                try {
                    $reCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
                    if ($null -eq $reCmd) { $reReadFailed = $true }
                    else {
                        $reGoal = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $GoalStoreDir
                        if (($null -eq $reGoal) -or (-not [bool](Get-ORFieldValue $reGoal 'ok' $false)) -or ($null -eq (Get-ORFieldValue $reGoal 'goal' $null))) { $reReadFailed = $true }
                    }
                }
                catch { $reReadFailed = $true }
                if ($reReadFailed) {
                    $Base['reason'] = 'goal-read-failed-no-advance'
                    $Base['decision'] = 'settlement-pending'
                    return $false
                }
                $liveRev = Get-ORLongValue (Get-ORFieldValue (Get-ORFieldValue $reGoal 'goal' $null) 'revision' $null) -1
                if ($liveRev -ne (Get-ORLongValue $ExpectedRevision -1)) {
                    $Base['reason'] = 'revision-changed-no-advance'
                    $Base['decision'] = 'settlement-pending'
                    return $false
                }
                $Goal = (Get-ORFieldValue $reGoal 'goal' $null)
            }
        }
        catch {
            $Base['reason'] = 'goal-read-failed-no-advance'
            $Base['decision'] = 'settlement-pending'
            return $false
        }
        # D4 replay-by-stage: a resume from 'checkpointed' replays ONLY
        # the advance stage (never a new checkpoint, dispatch or
        # settlement); a resume from 'settled' replays checkpoint first.
        $fromCk = (([string]$FromStage).Trim().ToLowerInvariant() -ceq 'checkpointed')
        if (-not $fromCk) {
        # D5: checkpoint owns its decision (separate envelope).
        $ckptAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'checkpoint' -Resource $WorkItemId -Decision 'checkpoint'
        if (($null -eq $ckptAuth) -or (-not [bool](Get-ORFieldValue $ckptAuth 'admitted' $false))) {
            $why = 'POLICY-BLOCKED'
            try { if (($null -ne $ckptAuth) -and (-not [string]::IsNullOrWhiteSpace([string]$ckptAuth.reason))) { $why = [string]$ckptAuth.reason } } catch { }
            $Base['reason'] = $why
            $Base['decision'] = 'checkpoint-blocked'
            return $false
        }
        $cid = Invoke-ORCheckpoint $Goal $CheckpointImpl -TestCallback:$TestCallback
        if ([string]::IsNullOrWhiteSpace($cid)) {
            $Base['reason'] = 'checkpoint-failed-no-advance'
            $Base['decision'] = 'settlement-pending'
            return $false
        }
        $Base['checkpoint_id'] = $cid
        $ckCAS = Set-ORDispatchStageCAS -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision $ActionRevision -ToStage 'checkpointed' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation -CheckpointId $cid
        if (($null -eq $ckCAS) -or (-not [bool]$ckCAS.ok)) {
            $why = 'checkpoint-not-durable-no-advance'
            try { if (($null -ne $ckCAS) -and (-not [string]::IsNullOrWhiteSpace([string]$ckCAS.reason))) { $why = [string]$ckCAS.reason } } catch { }
            $Base['reason'] = $why
            $Base['decision'] = 'settlement-pending'
            return $false
        }
        $Base['intent_state'] = 'checkpointed'
        }
        # D5: advance owns its decision (separate envelope).
        $advAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'advance' -Resource $WorkItemId -Decision 'advance'
        if (($null -eq $advAuth) -or (-not [bool](Get-ORFieldValue $advAuth 'admitted' $false))) {
            $why = 'POLICY-BLOCKED'
            try { if (($null -ne $advAuth) -and (-not [string]::IsNullOrWhiteSpace([string]$advAuth.reason))) { $why = [string]$advAuth.reason } } catch { }
            $Base['reason'] = $why
            $Base['decision'] = 'advance-blocked'
            return $false
        }
        $move = Invoke-ORControllerMove $Goal $NextMoveImpl -TestCallback:$TestCallback
        if ($null -eq $move) {
            $Base['reason'] = 'no-move-available'
            $Base['decision'] = 'advance-pending'
            return $false
        }
        $Base['next_move'] = $move
        $adCAS = Set-ORDispatchStageCAS -GoalId $GoalId -WorkItemId $WorkItemId -ActionRevision $ActionRevision -ToStage 'advanced' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation -NextMove $move
        if (($null -eq $adCAS) -or (-not [bool]$adCAS.ok)) {
            $why = 'advance-not-durable'
            try { if (($null -ne $adCAS) -and (-not [string]::IsNullOrWhiteSpace([string]$adCAS.reason))) { $why = [string]$adCAS.reason } } catch { }
            $Base['reason'] = $why
            $Base['decision'] = 'advance-pending'
            return $false
        }
        $Base['intent_state'] = 'advanced'
        try {
            $dirMark = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir
            $null = Save-ORAdvanceMarker -Dir $dirMark -Key ([string]$Base['intent_key']) -RequestHash ([string](Get-ORFieldValue $Base 'request_hash' ''))
        }
        catch { }
        $Base['ok'] = $true
        $Base['reason'] = 'dispatched'
        $Base['dispatched'] = $true
        $Base['decision'] = 'dispatched'
        return $true
    }
    catch {
        try {
            $Base['reason'] = 'internal-error'
            $Base['decision'] = 'settlement-pending'
        }
        catch { }
        return $false
    }
}

function Invoke-OrchestrationObjectiveEvent {
    # F1: DispatchImpl / SettleImpl are TEST-ONLY seams declared by the
    # explicit -TestCallback switch. Without it they are never invoked
    # (held/unavailable typed by construction); productive effects stay
    # HOLD until the GoalKernel gate lands.
    [CmdletBinding()]
    param(
        $Event = $null,
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [long]$ExpectedRevision = 0,
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [string]$BudgetScope = 'worker',
        [bool]$BudgetExhausted = $false,
        $DispatchImpl = $null,
        $SettleImpl = $null,
        $CheckpointImpl = $null,
        $NextMoveImpl = $null,
        [int]$LockTimeoutMs = 500,
        $DispatchProof = $null,
        $SettleProof = $null,
        [switch]$TestCallback
    )
    try {
        $base = New-ORBaseResult $Event
        if ($null -eq $Event) {
            $base['reason'] = 'invalid-event'
            return ([pscustomobject]$base)
        }
        $gid = [string](Get-ORFieldValue $Event 'goal_id' '')
        $typ = ([string](Get-ORFieldValue $Event 'type' '')).Trim().ToLowerInvariant()
        $wid = [string](Get-ORFieldValue $Event 'work_item_id' '')
        $arev = Get-ORLongValue (Get-ORFieldValue $Event 'action_revision' $null) -1
        if ((-not (Test-ORGoalIdValue $gid)) -or (-not (Test-ORGoalIdValue $wid)) -or ($arev -lt 1)) {
            $base['reason'] = 'invalid-event'
            return ([pscustomobject]$base)
        }
        if (@(Get-OrchestrationObjectiveEventTypes) -cnotcontains $typ) {
            $base['reason'] = 'unknown-event'
            return ([pscustomobject]$base)
        }
        $base['goal_id'] = $gid
        $base['work_item_id'] = $wid
        $base['action_revision'] = [long]$arev
        $key = Get-OrchestrationObjectiveIdempotencyKey -GoalId $gid -WorkItemId $wid -ActionRevision $arev
        if ([string]::IsNullOrWhiteSpace($key)) {
            $base['reason'] = 'invalid-event'
            return ([pscustomobject]$base)
        }
        $base['intent_key'] = $key
        Import-ORLibFile 'OrchestrationGoalKernel.ps1'
        $getGoal = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        if ($null -eq $getGoal) {
            $base['reason'] = 'goal-kernel-unavailable'
            return ([pscustomobject]$base)
        }
        $goalSlot = $null
        try { $goalSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch {
            $base['reason'] = 'goal-read-failed'
            return ([pscustomobject]$base)
        }
        if (($null -eq $goalSlot) -or (-not [bool]$goalSlot.ok) -or ($null -eq $goalSlot.goal)) {
            $why = 'goal-not-found'
            try { if (($null -ne $goalSlot) -and (-not [string]::IsNullOrWhiteSpace([string]$goalSlot.reason))) { $why = [string]$goalSlot.reason } } catch { }
            $base['reason'] = $why
            return ([pscustomobject]$base)
        }
        $goal = $goalSlot.goal
        $state = ([string](Get-ORFieldValue $goal 'state' '')).Trim().ToUpperInvariant()
        if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state) {
            $stop = 'POLICY_BLOCKED'
            if ($state -ceq 'COMPLETED') { $stop = 'OBJECTIVE_COMPLETED' }
            elseif ($state -ceq 'EXHAUSTED') { $stop = 'GOAL_HARD_BUDGET_EXHAUSTED' }
            elseif ($state -ceq 'CANCELLED') { $stop = 'CANCELLED' }
            $base['ok'] = $true
            $base['reason'] = 'goal-terminal'
            $base['decision'] = 'terminal'
            $base['stop_reason'] = $stop
            return ([pscustomobject]$base)
        }
        if (($state -cne 'ACTIVE') -and ($state -cne 'BUDGET_LIMITED')) {
            $base['reason'] = 'goal-not-active'
            return ([pscustomobject]$base)
        }
        # D5: dispatch owns its decision (Operation 'dispatch',
        # Resource = work item). Settlement, checkpoint, advance and
        # terminalization each build their own envelope below; the
        # dispatch envelope is never reused for them.
        $auth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'dispatch' -Resource $wid -Decision 'dispatch'
        if (($null -eq $auth) -or (-not [bool]$auth.admitted)) {
            $why = 'POLICY-BLOCKED'
            try { if (($null -ne $auth) -and (-not [string]::IsNullOrWhiteSpace([string]$auth.reason))) { $why = [string]$auth.reason } } catch { }
            $base['reason'] = $why
            $base['decision'] = 'blocked'
            $base['stop_reason'] = 'POLICY_BLOCKED'
            return ([pscustomobject]$base)
        }
        # R1 real CAS: the expected revision is compared against the REAL
        # loaded goal revision. A stale caller never advances.
        $goalRev = Get-ORLongValue (Get-ORFieldValue $goal 'revision' $null) -1
        if ($goalRev -lt 1) {
            $base['reason'] = 'goal-read-failed'
            $base['decision'] = 'blocked'
            return ([pscustomobject]$base)
        }
        if ($goalRev -ne (Get-ORLongValue $ExpectedRevision -1)) {
            $base['reason'] = 'revision-conflict'
            $base['decision'] = 'blocked'
            return ([pscustomobject]$base)
        }
        $budget = Test-OrchestrationObjectiveBudget -Goal $goal -Scope $BudgetScope -Exhausted ([bool]$BudgetExhausted)
        if (($null -eq $budget) -or (-not [bool]$budget.ok)) {
            $why = 'invalid-budget'
            try { if (($null -ne $budget) -and (-not [string]::IsNullOrWhiteSpace([string]$budget.reason))) { $why = [string]$budget.reason } } catch { }
            $base['reason'] = $why
            $base['decision'] = 'block'
            return ([pscustomobject]$base)
        }
        if ([string]$budget.decision -ceq 'terminal') {
            # R1: terminal persistence requires ownership. The caller must
            # hold the fencing token (owner + generation at this revision);
            # otherwise nothing is persisted and nobody advances.
            # D5: terminalization owns its decision (separate envelope,
            # never the dispatch one).
            $termAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'terminalize' -Resource $wid -Decision 'terminal'
            if (($null -eq $termAuth) -or (-not [bool](Get-ORFieldValue $termAuth 'admitted' $false))) {
                $why = 'POLICY-BLOCKED'
                try { if (($null -ne $termAuth) -and (-not [string]::IsNullOrWhiteSpace([string]$termAuth.reason))) { $why = [string]$termAuth.reason } } catch { }
                $base['reason'] = $why
                $base['decision'] = 'blocked'
                $base['stop_reason'] = 'POLICY_BLOCKED'
                return ([pscustomobject]$base)
            }
            $termOwn = Acquire-OrchestrationObjectiveOwnership -GoalId $gid -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -GoalStoreDir $GoalStoreDir
            if (($null -eq $termOwn) -or (-not [bool]$termOwn.ok)) {
                $why = 'owner-rejected'
                try { if (($null -ne $termOwn) -and (-not [string]::IsNullOrWhiteSpace([string]$termOwn.reason))) { $why = [string]$termOwn.reason } } catch { }
                $base['reason'] = $why
                $base['decision'] = 'blocked'
                return ([pscustomobject]$base)
            }
            $persisted = $false
            try {
                $setState = Get-Command Set-OrchestrationGoalState -ErrorAction SilentlyContinue
                $saveGoal = Get-Command Save-OrchestrationGoal -ErrorAction SilentlyContinue
                if (($null -ne $setState) -and ($null -ne $saveGoal)) {
                    $tr = Set-OrchestrationGoalState -Goal $goal -ToState 'EXHAUSTED'
                    if (($null -ne $tr) -and ([bool]$tr.ok)) {
                        $sv = Save-OrchestrationGoal -Goal $tr.goal -StoreDir $GoalStoreDir
                        if (($null -ne $sv) -and ([bool]$sv.ok)) { $persisted = $true }
                    }
                }
            }
            catch { $persisted = $false }
            $base['ok'] = $true
            if ($persisted) { $base['reason'] = 'goal-hard-budget-exhausted-persisted' }
            else { $base['reason'] = 'goal-hard-budget-exhausted' }
            $base['decision'] = 'terminal'
            $base['stop_reason'] = 'GOAL_HARD_BUDGET_EXHAUSTED'
            return ([pscustomobject]$base)
        }
        if ([string]$budget.decision -ceq 'replan') {
            $base['ok'] = $true
            $base['reason'] = [string]$budget.reason
            $base['decision'] = 'replan'
            return ([pscustomobject]$base)
        }
        $own = Acquire-OrchestrationObjectiveOwnership -GoalId $gid -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -GoalStoreDir $GoalStoreDir
        if (($null -eq $own) -or (-not [bool]$own.ok)) {
            $why = 'owner-rejected'
            try { if (($null -ne $own) -and (-not [string]::IsNullOrWhiteSpace([string]$own.reason))) { $why = [string]$own.reason } } catch { }
            $base['reason'] = $why
            $base['decision'] = 'blocked'
            return ([pscustomobject]$base)
        }
        $existing = Get-OrchestrationDispatchIntent -GoalId $gid -WorkItemId $wid -ActionRevision $arev -StoreDir $DispatchStoreDir
        if (($null -ne $existing) -and ([bool]$existing.ok) -and ($null -ne $existing.intent)) {
            $stored = $existing.intent
            $reqHash = Get-OrchestrationObjectiveRequestHash -Key $key -ExpectedRevision $ExpectedRevision
            # D2: case-divergent legacy spelling on the same canonical key
            # => identity HOLD (no rename, no merge, no new effect).
            if ((Test-ORIdentityHold ([string]$stored['goal_id']) $gid) -or (Test-ORIdentityHold ([string]$stored['work_item_id']) $wid)) {
                $base['ok'] = $false
                $base['reason'] = 'identity-hold-case-divergence'
                $base['decision'] = 'blocked'
                return ([pscustomobject]$base)
            }
            # D3: same key + different request => conflict (fail closed).
            $storedHash = [string](Get-ORFieldValue $stored 'request_hash' '')
            if ((-not [string]::IsNullOrWhiteSpace($storedHash)) -and (-not [string]::IsNullOrWhiteSpace($reqHash)) -and ($storedHash -cne $reqHash)) {
                $base['ok'] = $false
                $base['reason'] = 'receipt-conflict'
                $base['decision'] = 'blocked'
                return ([pscustomobject]$base)
            }
            $base['request_hash'] = [string]$reqHash
            $stNow = ([string](Get-ORFieldValue $stored 'state' '')).Trim().ToLowerInvariant()
            $base['intent_state'] = $stNow
            if ($null -ne (Get-ORFieldValue $stored 'receipt' $null)) {
                $base['receipt'] = (Get-ORFieldValue $stored 'receipt' $null)
                $base['task_result'] = (Get-ORFieldValue $stored 'receipt' $null)
            }
            # D4: a duplicate never ends recovery and never repeats an
            # effect. Terminal diary stages are idempotent no-ops returning
            # the original receipt; incomplete stages report pending so
            # reconciliation (not redispatch) picks them up; settled and
            # checkpointed resume ONLY their missing stages below.
            if (($stNow -ceq 'advanced') -or ($stNow -ceq 'held') -or ($stNow -ceq 'reconciled')) {
                $base['ok'] = $true
                $base['reason'] = 'duplicate-event-one-logical-dispatch'
                $base['duplicate'] = $true
                # F5: replay of an advanced intent returns the persisted
                # continuation move (crash-before-delivery recovery).
                if ($stNow -ceq 'advanced') {
                    try {
                        $pm = Get-ORFieldValue $stored 'next_move' $null
                        if ($null -ne $pm) { $base['next_move'] = $pm }
                    }
                    catch { }
                }
                return ([pscustomobject]$base)
            }
            if (($stNow -ceq 'settled') -or ($stNow -ceq 'checkpointed')) {
                # M2: a settled/checkpointed diary stage without a valid
                # bound settlement receipt (operation-scoped, key- and
                # generation-bound to the original intent) never advances:
                # it is demoted to pending under the store lock with
                # fencing revalidated, for reconciliation (fail closed, no
                # new effect here).
                $srGate = Test-OREffectReceipt -Receipt (Get-ORFieldValue $stored 'settlement_receipt' $null) -Key $key -Generation (Get-ORLongValue (Get-ORFieldValue $stored 'generation' $null) -1) -Operation 'settlement'
                if (($null -eq $srGate) -or (-not [bool]$srGate.ok)) {
                    try {
                        $demDir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir
                        $demLock = Open-ORStoreLock -Dir $demDir -LockTimeoutMs $LockTimeoutMs
                        if ($null -ne $demLock) {
                            try {
                                $demFence = Confirm-OROwnershipHeld -Dir $demDir -GoalId $gid -OwnerId $OwnerId -Generation $Generation
                                if ([bool]$demFence.held) {
                                    $demPath = Get-ORIntentFilePath -Dir $demDir -GoalId $gid -WorkItemId $wid -ActionRevision $arev
                                    if ((-not [string]::IsNullOrWhiteSpace($demPath)) -and (Test-Path -LiteralPath $demPath -PathType Leaf)) {
                                        try { $demRaw = ConvertFrom-Json ([IO.File]::ReadAllText($demPath, [Text.Encoding]::UTF8)) } catch { $demRaw = $null }
                                        $demRec = ConvertTo-ORDispatchRecord $demRaw
                                        if ($null -ne $demRec) {
                                            $demSt = ([string]$demRec['state']).Trim().ToLowerInvariant()
                                            if (($demSt -ceq 'settled') -or ($demSt -ceq 'checkpointed')) {
                                                $demRec['state'] = 'pending'
                                                $demRec['updated_at'] = Get-ORStamp
                                                $demJson = ConvertTo-Json -InputObject $demRec -Depth 20 -Compress
                                                $demTmp = Join-Path $demDir (('intent-' + [IO.Path]::GetRandomFileName() + '.tmp'))
                                                [IO.File]::WriteAllText($demTmp, $demJson, [Text.UTF8Encoding]::new($false))
                                                Move-Item -LiteralPath $demTmp -Destination $demPath -Force -ErrorAction Stop
                                            }
                                        }
                                    }
                                }
                            }
                            catch { }
                            finally { try { $demLock.Dispose() } catch { } }
                        }
                    }
                    catch { }
                    $base['ok'] = $true
                    $base['reason'] = 'settlement-pending-reconciliation'
                    $base['duplicate'] = $true
                    $base['decision'] = 'settlement-pending'
                    $base['settlement'] = 'pending-reconciliation'
                    $base['intent_state'] = 'pending'
                    return ([pscustomobject]$base)
                }
                $base['duplicate'] = $true
                $base['settlement'] = 'settled'
                try {
                    $mark = [string](Get-ORFieldValue $stored 'consumed_from' '')
                    if (-not [string]::IsNullOrWhiteSpace($mark)) { $base['consumed_move'] = $mark }
                }
                catch { }
                try {
                    $cidHave = [string](Get-ORFieldValue $stored 'checkpoint_id' '')
                    if (-not [string]::IsNullOrWhiteSpace($cidHave)) { $base['checkpoint_id'] = $cidHave }
                }
                catch { }
                $null = Invoke-ORAdvanceStages -Base $base -Goal $goal -GoalId $gid -WorkItemId $wid -ActionRevision $arev -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -User $User -Project $Project -Runtime $Runtime -Grants $Grants -CheckpointImpl $CheckpointImpl -NextMoveImpl $NextMoveImpl -LockTimeoutMs $LockTimeoutMs -FromStage $stNow -TestCallback:$TestCallback
                $base['duplicate'] = $true
                return ([pscustomobject]$base)
            }
            $base['ok'] = $true
            $base['reason'] = 'duplicate-event-one-logical-dispatch'
            $base['duplicate'] = $true
            $base['decision'] = 'settlement-pending'
            $base['settlement'] = 'pending-reconciliation'
            return ([pscustomobject]$base)
        }
        $fresh = New-OrchestrationDispatchIntent -GoalId $gid -WorkItemId $wid -ActionRevision $arev
        if (($null -eq $fresh) -or (-not [bool]$fresh.ok)) {
            $base['reason'] = 'invalid-intent'
            return ([pscustomobject]$base)
        }
        # R1: the intent is stamped with the fencing token (owner +
        # generation) so a superseded generation can never settle it later.
        # D3: the request hash binds this exact request to the future
        # receipt (same key + same request => original receipt).
        # F6: the goal-revision origin of the effect is recorded so a
        # later live revision (N+1) is distinguishable on recovery.
        try {
            $fresh.intent['owner'] = ([string]$OwnerId).Trim()
            $fresh.intent['generation'] = (Get-ORLongValue $Generation -1)
            $fresh.intent['request_hash'] = (Get-OrchestrationObjectiveRequestHash -Key $key -ExpectedRevision $ExpectedRevision)
            $fresh.intent['goal_revision_origin'] = (Get-ORLongValue $ExpectedRevision -1)
        }
        catch {
            $base['reason'] = 'invalid-intent'
            return ([pscustomobject]$base)
        }
        $base['request_hash'] = [string]$fresh.intent['request_hash']
        $persist = Save-OrchestrationDispatchIntent -Intent $fresh.intent -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
        if (($null -eq $persist) -or (-not [bool]$persist.ok)) {
            $why = 'intent-write-failed'
            try { if (($null -ne $persist) -and (-not [string]::IsNullOrWhiteSpace([string]$persist.reason))) { $why = [string]$persist.reason } } catch { }
            $base['reason'] = $why
            return ([pscustomobject]$base)
        }
        if ([bool]$persist.duplicate) {
            $base['ok'] = $true
            $base['reason'] = 'duplicate-event-one-logical-dispatch'
            $base['duplicate'] = $true
            return ([pscustomobject]$base)
        }
        # R3: persist the effect-potential state BEFORE the callback, so a
        # crash inside the effect stays reconcilable without repeating it.
        $preEffect = Set-OrchestrationDispatchState -GoalId $gid -WorkItemId $wid -ActionRevision $arev -State 'dispatched-unknown' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
        if (($null -eq $preEffect) -or (-not [bool]$preEffect.ok)) {
            $why = 'intent-write-failed'
            try { if (($null -ne $preEffect) -and (-not [string]::IsNullOrWhiteSpace([string]$preEffect.reason))) { $why = [string]$preEffect.reason } } catch { }
            $base['reason'] = $why
            return ([pscustomobject]$base)
        }
        # R1: the fencing token is revalidated after the lock and before
        # the effect; a lost lease never dispatches.
        $fence = Confirm-OROwnershipHeld -Dir (Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir) -GoalId $gid -OwnerId $OwnerId -Generation $Generation
        if (-not [bool]$fence.held) {
            $base['reason'] = [string]$fence.reason
            $base['decision'] = 'blocked'
            $base['settlement'] = 'pending-reconciliation'
            return ([pscustomobject]$base)
        }
        $dispatch = $null
        $testSeams = [bool]$TestCallback
        if (($null -ne $DispatchImpl) -and (-not $testSeams)) {
            # F1 ENFORCED: productive seam supplied without the explicit
            # test-only declaration => never invoked (held by
            # construction, spy 0 calls). Diary/ownership remain for
            # restricted recovery only.
            $null = Set-OrchestrationDispatchState -GoalId $gid -WorkItemId $wid -ActionRevision $arev -State 'held' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
            $base['ok'] = $true
            $base['reason'] = 'hold-productive-disabled:test-callback-absent'
            $base['fallback'] = 'hold-productive-disabled:test-callback-absent|fallback_continue=false'
            $base['intent_state'] = 'held'
            return ([pscustomobject]$base)
        }
        if (($null -ne $DispatchImpl) -and $testSeams) {
            # D3/D6 pre-call gate: an unproven callback is blocked BEFORE
            # the call (HOLD, proven absence of effect since nothing was
            # invoked). Only a fencing+idempotency-bound proof dispatches.
            $proofGate = Test-OREffectProof -Proof $DispatchProof -Key $key -OwnerId $OwnerId -Generation $Generation
            if (($null -eq $proofGate) -or (-not [bool]$proofGate.ok)) {
                $why = 'hold-unproven-effect:dispatch-proof-missing'
                try { if (($null -ne $proofGate) -and (-not [string]::IsNullOrWhiteSpace([string]$proofGate.reason))) { $why = ('hold-unproven-effect:' + [string]$proofGate.reason) } } catch { }
                $null = Set-OrchestrationDispatchState -GoalId $gid -WorkItemId $wid -ActionRevision $arev -State 'held' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
                $base['ok'] = $true
                $base['reason'] = $why
                $base['fallback'] = ($why + '|fallback_continue=false')
                $base['intent_state'] = 'held'
                return ([pscustomobject]$base)
            }
            try { $dispatch = & $DispatchImpl $fresh.intent $goal $auth }
            catch {
                $dispatch = $null
            }
            if ($null -eq $dispatch) {
                $base['reason'] = 'dispatch-unknown-effect-pending-reconciliation'
                $base['settlement'] = 'pending-reconciliation'
                $base['decision'] = 'settlement-pending'
                $base['dispatched'] = $true
                $base['intent_state'] = 'dispatched-unknown'
                $base['ok'] = $true
                return ([pscustomobject]$base)
            }
            # D3/F3: ok/dispatched flags never prove a commit. Only a
            # valid durable receipt bound to the proof (destination +
            # action) and operation-scoped ('dispatch') moves the
            # protocol; otherwise the effect is unknown and stays
            # reconcilable (never held-away, never advanced).
            $rcGate = Test-OREffectReceipt -Receipt $dispatch -Key $key -Generation $Generation -Proof $DispatchProof -Operation 'dispatch'
            if (($null -eq $rcGate) -or (-not [bool]$rcGate.ok)) {
                $why = 'receipt-missing'
                try { if (($null -ne $rcGate) -and (-not [string]::IsNullOrWhiteSpace([string]$rcGate.reason))) { $why = [string]$rcGate.reason } } catch { }
                $base['reason'] = ('dispatch-unknown-effect-pending-reconciliation:' + $why)
                $base['settlement'] = 'pending-reconciliation'
                $base['decision'] = 'settlement-pending'
                $base['dispatched'] = $true
                $base['intent_state'] = 'dispatched-unknown'
                $base['ok'] = $true
                return ([pscustomobject]$base)
            }
            $rcCAS = Set-ORDispatchReceiptCAS -GoalId $gid -WorkItemId $wid -ActionRevision $arev -RequestHash ([string]$fresh.intent['request_hash']) -Receipt $dispatch -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
            if (($null -eq $rcCAS) -or (-not [bool]$rcCAS.ok)) {
                $why = 'receipt-not-durable-no-advance'
                try { if (($null -ne $rcCAS) -and (-not [string]::IsNullOrWhiteSpace([string]$rcCAS.reason))) { $why = [string]$rcCAS.reason } } catch { }
                if ($why -ceq 'receipt-conflict') {
                    $base['ok'] = $false
                    $base['reason'] = 'receipt-conflict'
                    $base['decision'] = 'blocked'
                    return ([pscustomobject]$base)
                }
                $base['reason'] = $why
                $base['settlement'] = 'pending-reconciliation'
                $base['decision'] = 'settlement-pending'
                $base['dispatched'] = $true
                $base['intent_state'] = 'dispatched-unknown'
                $base['ok'] = $true
                return ([pscustomobject]$base)
            }
            if ([bool]$rcCAS.duplicate) {
                $base['ok'] = $true
                $base['reason'] = 'duplicate-event-one-logical-dispatch'
                $base['duplicate'] = $true
                $base['dispatched'] = $true
                $base['intent_state'] = 'pending'
                $base['receipt'] = (Get-ORFieldValue $rcCAS.intent 'receipt' $null)
                $base['task_result'] = (Get-ORFieldValue $rcCAS.intent 'receipt' $null)
                $base['decision'] = 'settlement-pending'
                $base['settlement'] = 'pending-reconciliation'
                return ([pscustomobject]$base)
            }
            $dispatch = $rcCAS.intent['receipt']
            $base['intent_state'] = 'pending'
        }
        else {
            $dispatch = Invoke-ORDefaultDispatch $fresh.intent $goal $auth
        }
        $dOk = $false
        try { $dOk = [bool](Get-ORFieldValue $dispatch 'ok' $false) } catch { $dOk = $false }
        $dRan = $false
        try { $dRan = [bool](Get-ORFieldValue $dispatch 'dispatched' $false) } catch { $dRan = $false }
        # D3: the flag check below applies ONLY to the default (unproven)
        # path. A custom callback that passed the proof gate and produced
        # a valid durable receipt above is a proven commit: its ok /
        # dispatched flags are informational, never decisive.
        if (($null -eq $DispatchImpl) -and ((-not $dOk) -or (-not $dRan))) {
            $fb = ''
            try { $fb = [string](Get-ORFieldValue $dispatch 'reason' 'dispatch-fallback') } catch { $fb = 'dispatch-fallback' }
            if ([string]::IsNullOrWhiteSpace($fb)) { $fb = 'dispatch-fallback' }
            $null = Set-OrchestrationDispatchState -GoalId $gid -WorkItemId $wid -ActionRevision $arev -State 'held' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
            $base['ok'] = $true
            $base['reason'] = $fb
            $base['fallback'] = $fb
            $base['intent_state'] = 'held'
            try {
                $fc = $dispatch.fallback_continue
                if ($null -ne $fc) { $base['fallback'] = ($fb + '|fallback_continue=' + [string][bool]$fc) }
            }
            catch { }
            return ([pscustomobject]$base)
        }
        $base['task_result'] = $dispatch
        $consumed = $null
        try { $consumed = (Get-ORFieldValue $goal 'next_move' $null) } catch { $consumed = $null }
        $base['consumed_move'] = $consumed
        $mark = 'no-prior-move'
        try {
            if ($null -ne $consumed) {
                $cj = ConvertTo-Json -InputObject $consumed -Depth 20 -Compress
                $mh = Get-ORHashHex32 $cj
                if (-not [string]::IsNullOrWhiteSpace($mh)) { $mark = ('move-' + $mh) }
            }
        }
        catch { $mark = 'no-prior-move' }
        # D5: settlement owns its decision (separate envelope, never the
        # dispatch one). Without an admitted settlement envelope the
        # SettleImpl callback is never invoked.
        $settleAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'settlement' -Resource $wid -Decision 'settlement'
        if (($null -eq $settleAuth) -or (-not [bool](Get-ORFieldValue $settleAuth 'admitted' $false))) {
            $base['reason'] = 'settlement-pending-reconciliation'
            $base['decision'] = 'settlement-pending'
            $base['settlement'] = 'pending-reconciliation'
            $base['dispatched'] = $true
            $base['ok'] = $true
            return ([pscustomobject]$base)
        }
        $base['receipt'] = $dispatch
        $settledNow = $false
        if (($null -ne $SettleImpl) -and (-not $testSeams)) {
            # F1 ENFORCED: settlement seam without test-only declaration
            # is never invoked; the intent waits pending reconciliation.
            $base['reason'] = 'settlement-pending-reconciliation'
            $base['decision'] = 'settlement-pending'
            $base['settlement'] = 'pending-reconciliation'
            $base['dispatched'] = $true
            $base['ok'] = $true
            return ([pscustomobject]$base)
        }
        if (($null -ne $SettleImpl) -and $testSeams) {
            # F2/F3 single-lock settlement: ownership/lease/generation are
            # revalidated immediately before the callback and the
            # settlement receipt (operation-scoped, proof-bound) is
            # persisted atomically with the transition under the same
            # lock -- no window. The dispatch receipt alone never
            # satisfies this gate.
            $dirNow = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir
            $sl = Invoke-ORSettleUnderStoreLock -Dir $dirNow -GoalId $gid -WorkItemId $wid -ActionRevision $arev -Key $key -OwnerId $OwnerId -Generation $Generation -Mark $mark -SettleProof $SettleProof -SettleScript $SettleImpl -IntentSnapshot $fresh.intent -DispatchReceipt $dispatch -Goal $goal -SettleAuth $settleAuth -TestCallback:$TestCallback
            if (($null -ne $sl) -and ([bool]$sl.ok)) {
                $settledNow = $true
                $base['settlement'] = 'settled'
                $base['intent_state'] = 'settled'
            }
            else {
                try {
                    if (($null -ne $sl) -and (-not [string]::IsNullOrWhiteSpace([string]$sl.reason)) -and (([string]$sl.reason).StartsWith('hold-unproven-effect'))) {
                        $base['reason'] = [string]$sl.reason
                        $base['decision'] = 'settlement-pending'
                        $base['settlement'] = 'pending-reconciliation'
                        $base['dispatched'] = $true
                        $base['ok'] = $true
                        return ([pscustomobject]$base)
                    }
                }
                catch { }
            }
        }
        if (-not $settledNow) {
            # R2: failed or absent settlement blocks advancement. The prior
            # move is recorded as consumed, but the controller is NOT
            # consulted and no next_move is issued. The intent stays
            # pending (dispatched-unknown/pending): eligible, idempotent.
            $base['reason'] = 'settlement-pending-reconciliation'
            $base['decision'] = 'settlement-pending'
            $base['settlement'] = 'pending-reconciliation'
            $base['dispatched'] = $true
            $base['ok'] = $true
            return ([pscustomobject]$base)
        }
        # D4 replay-by-stage: checkpoint then advance, no new dispatch and
        # no new settlement from here on.
        $null = Invoke-ORAdvanceStages -Base $base -Goal $goal -GoalId $gid -WorkItemId $wid -ActionRevision $arev -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -User $User -Project $Project -Runtime $Runtime -Grants $Grants -CheckpointImpl $CheckpointImpl -NextMoveImpl $NextMoveImpl -LockTimeoutMs $LockTimeoutMs -TestCallback:$TestCallback
        return ([pscustomobject]$base)
    }
    catch {
        try {
            $base = New-ORBaseResult $Event
            $base['reason'] = 'internal-error'
            return ([pscustomobject]$base)
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'internal-error'; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
    }
}

function Invoke-OrchestrationObjectiveReconcile {
    # F1: ReconcileImpl / SettleImpl are TEST-ONLY seams declared by the
    # explicit -TestCallback switch. Without it no observation and no
    # settlement is ever invoked (held/unavailable by construction).
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [long]$ExpectedRevision = 0,
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        $ReconcileImpl = $null,
        $SettleImpl = $null,
        [int]$LockTimeoutMs = 500,
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [string]$Operation = 'reconcileEffect',
        [string]$Resource = '',
        [string]$Decision = 'reconcile',
        $SettleProof = $null,
        [switch]$TestCallback
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-ORGoalIdValue $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        # D5 coarse facet gate BEFORE anything is touched (missing facet
        # or deny token => nothing happens). Per-intent admission with the
        # explicit allow reference happens inside the loop below.
        $facetMissing = New-Object System.Collections.ArrayList
        if ([string]::IsNullOrWhiteSpace($User)) { [void]$facetMissing.Add('user') }
        if ([string]::IsNullOrWhiteSpace($Project)) { [void]$facetMissing.Add('project') }
        if ([string]::IsNullOrWhiteSpace($Runtime)) { [void]$facetMissing.Add('runtime') }
        if ([string]::IsNullOrWhiteSpace($Grants)) { [void]$facetMissing.Add('grants') }
        if ($facetMissing.Count -gt 0) {
            return [pscustomobject]@{ ok = $false; reason = ('POLICY-BLOCKED:missing-' + ($facetMissing -join ',')); reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $facetDeny = [bool](Test-ORGrantTokenDenied -Grants ([string]$Grants))
        if (-not $facetDeny) { $facetDeny = [bool](Test-ORDecisionDenied -Decision ([string]$Decision)) }
        if ($facetDeny) {
            return [pscustomobject]@{ ok = $false; reason = 'POLICY-BLOCKED:grants-deny'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        # R1 real CAS for reconcile: the expected revision must match the
        # live goal revision before anything is investigated or settled.
        $liveGoal = $null
        if (-not [string]::IsNullOrWhiteSpace($GoalStoreDir)) {
            try {
                $getGoalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
                if ($null -eq $getGoalCmd) {
                    return [pscustomobject]@{ ok = $false; reason = 'goal-kernel-unavailable'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
                }
                $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
                if (($null -eq $slot) -or (-not [bool](Get-ORFieldValue $slot 'ok' $false)) -or ($null -eq (Get-ORFieldValue $slot 'goal' $null))) {
                    $why = 'goal-not-found'
                    try { if (($null -ne $slot) -and (-not [string]::IsNullOrWhiteSpace([string]$slot.reason))) { $why = [string]$slot.reason } } catch { }
                    return [pscustomobject]@{ ok = $false; reason = $why; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
                }
                $liveGoal = (Get-ORFieldValue $slot 'goal' $null)
                $liveRev = Get-ORLongValue (Get-ORFieldValue $liveGoal 'revision' $null) -1
                if ($liveRev -ne (Get-ORLongValue $ExpectedRevision -1)) {
                    return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
                }
                # D4: a terminal Goal still admits reconcile/settlement of a
                # PRIOR effect (settling what already happened); only a NEW
                # dispatch is prohibited (and reconcile never dispatches).
            }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'goal-read-failed'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
            }
        }
        $own = Acquire-OrchestrationObjectiveOwnership -GoalId $gid -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -GoalStoreDir $GoalStoreDir
        if (($null -eq $own) -or (-not [bool]$own.ok)) {
            $why = 'owner-rejected'
            try { if (($null -ne $own) -and (-not [string]::IsNullOrWhiteSpace([string]$own.reason))) { $why = [string]$own.reason } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $dir = Get-OrchestrationObjectiveRuntimeStoreDir -StoreDir $DispatchStoreDir
        if ([string]::IsNullOrWhiteSpace($dir) -or (-not (Test-Path -LiteralPath $dir -PathType Container))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        # R5: hashed file names carry no goal prefix; every intent file is
        # scanned and filtered by the goal_id inside the record (D2:
        # canonical comparison, ordinal -ceq; a case-divergent legacy
        # spelling is an identity HOLD, never a merge).
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.intent.json' -ErrorAction Stop) } catch { $files = @() }
        $recCount = 0
        $setCount = 0
        $holdCount = 0
        $firstDeny = ''
        $admittedAny = $false
        foreach ($f in @($files)) {
            $raw = $null
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } catch { continue }
            $rec = ConvertTo-ORDispatchRecord $raw
            if ($null -eq $rec) { continue }
            if ((Get-ORCanonicalId ([string]$rec['goal_id'])) -cne (Get-ORCanonicalId $gid)) { continue }
            if (Test-ORIdentityHold ([string]$rec['goal_id']) $gid) { $holdCount++; continue }
            # R3: every effect-unknown state is eligible: a crash in
            # 'intended' or 'dispatched-unknown' is investigated here, never
            # repeated. Settled/held/reconciled/checkpointed/advanced
            # intents are never re-entered.
            $st = ([string]$rec['state']).Trim().ToLowerInvariant()
            if ((@('intended', 'dispatched-unknown', 'dispatched', 'pending') -cnotcontains $st)) { continue }
            $wid = [string]$rec['work_item_id']
            $arev = [long]$rec['action_revision']
            # D5: reconcile owns one decision PER INTENT (Resource = the
            # work item). A denied intent is skipped and stays pending.
            $intentAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'reconcile' -Resource $wid -Decision 'reconcile'
            if (($null -eq $intentAuth) -or (-not [bool](Get-ORFieldValue $intentAuth 'admitted' $false))) {
                try {
                    if ([string]::IsNullOrWhiteSpace($firstDeny) -and ($null -ne $intentAuth) -and (-not [string]::IsNullOrWhiteSpace([string]$intentAuth.reason))) { $firstDeny = [string]$intentAuth.reason }
                }
                catch { }
                continue
            }
            $admittedAny = $true
            # F1 ENFORCED: without the explicit test-only declaration the
            # observation seam is never invoked (no effect, stays pending).
            if (-not [bool]$TestCallback) { continue }
            $observed = $null
            if ($null -ne $ReconcileImpl) {
                try { $observed = & $ReconcileImpl $rec $intentAuth }
                catch { $observed = $null }
            }
            if ($null -eq $observed) { continue }
            $obsOk = $false
            try { $obsOk = [bool](Get-ORFieldValue $observed 'ok' $true) } catch { $obsOk = $false }
            if (-not $obsOk) { continue }
            $effect = $false
            try { $effect = [bool](Get-ORFieldValue $observed 'effect_observed' $false) } catch { $effect = $false }
            if (-not $effect) {
                # D4: reconciled ONLY with conclusive destination proof:
                # no effect AND no request capable of effecting it. An
                # unknown or inconclusive observation stays pending.
                $noEffect = $false
                $noCapable = $false
                try { $noEffect = [bool](Get-ORFieldValue $observed 'no_effect_proven' $false) } catch { $noEffect = $false }
                try { $noCapable = [bool](Get-ORFieldValue $observed 'no_capable_request' $false) } catch { $noCapable = $false }
                if ((-not $noEffect) -or (-not $noCapable)) { continue }
                $done = Set-OrchestrationDispatchState -GoalId $gid -WorkItemId $wid -ActionRevision $arev -State 'reconciled' -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -OwnerId $OwnerId -Generation $Generation
                if (($null -ne $done) -and ([bool]$done.ok)) { $recCount++ }
                continue
            }
            $recCount++
            # D5/F2/F3: settlement of the reconciled effect owns its own
            # decision (separate per-intent envelope, never the reconcile
            # one). The single-lock helper revalidates ownership
            # immediately before the callback and persists the
            # operation-scoped, proof-bound settlement receipt atomically
            # with the transition (no window; dispatch receipt alone never
            # satisfies this gate).
            $settleAuth = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'settlement' -Resource $wid -Decision 'settlement'
            if (($null -eq $settleAuth) -or (-not [bool](Get-ORFieldValue $settleAuth 'admitted' $false))) { continue }
            if (-not [bool]$TestCallback) { continue }
            if ($null -ne $SettleImpl) {
                $sl = Invoke-ORSettleUnderStoreLock -Dir $dir -GoalId $gid -WorkItemId $wid -ActionRevision $arev -Key ([string]$rec['key']) -OwnerId $OwnerId -Generation $Generation -Mark 'reconcile-effect-settled' -SettleProof $SettleProof -SettleScript $SettleImpl -IntentSnapshot $rec -DispatchReceipt $observed -Goal $liveGoal -SettleAuth $settleAuth -TestCallback:$TestCallback
                if (($null -ne $sl) -and ([bool]$sl.ok)) { $setCount++ }
            }
        }
        if ((-not $admittedAny) -and (($recCount -eq 0) -and ($setCount -eq 0) -and ($holdCount -eq 0))) {
            $why = 'reconcile-no-admitted-intent'
            if (-not [string]::IsNullOrWhiteSpace($firstDeny)) { $why = $firstDeny }
            return [pscustomobject]@{ ok = $false; reason = $why; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        return [pscustomobject]@{ ok = $true; reason = 'reconciled'; reconciled = $recCount; settled = $setCount; redispatched = 0; holds = $holdCount; grants_authority = $false; done_approved = $false; verified_pass = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
    }
}
