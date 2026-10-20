<#!
.SYNOPSIS
    S4 limitada: recovery atribuido por sessao substituta (fixture-only).
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1 compatible,
    ASCII-only, no network, no spawn, no secrets. Never throws on
    operational paths: every failure is an envelope with ok=$false and a
    machine-readable reason.

    `Invoke-OrchestrationSettledRecovery` lets a substitute host session
    (descriptor only, never a capability) request recovery of a settlement
    whose advance is ALREADY prepared or terminal, with durable attribution
    of who asked, why, under which authorization and over which proofs.
    The replay itself is delegated to the S3a continuation
    (`Invoke-OrchestrationSettledContinuation`); a missing checkpoint can be
    rebuilt from canonical records. Pending/ambiguous states NEVER replay
    automatically: they become attributed `blocked-manual` (record only,
    zero domain mutation) or refusal.

    Hard rules (see docs/plans/F1-S4-SETTLED-RECOVERY-PLAN.md):
    - no new PREPARE, no worker, no CLAIM, no SETTLE, no ADVANCE call;
    - never calls Controller, verifier, gates, or completion CAS directly;
    - never rebinds a historic session, never acquires/transfers owner;
    - `blocked-manual` mutates no goal/task/receipt/advance record;
    - never fabricates COMPLETE; S3a/ND codes are preserved in cause_reason;
    - executor_calls is always 0.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $SRLibDir = $PSScriptRoot
    foreach ($SRLib in @('OrchestrationGoalKernel.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationNativeDispatch.ps1', 'OrchestrationTaskKernel.ps1', 'OrchestrationAutonomousLoop.ps1')) {
        $SRPath = Join-Path $SRLibDir $SRLib
        if (Test-Path -LiteralPath $SRPath -PathType Leaf) { . $SRPath }
    }
}
catch { }

function Get-SRValue {
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

function New-SREffects {
    param([bool]$DomainMutated = $false, [bool]$AttributionWritten = $false, [bool]$CheckpointWritten = $false)
    return [pscustomobject][ordered]@{
        domain_mutated      = [bool]$DomainMutated
        attribution_written = [bool]$AttributionWritten
        checkpoint_written  = [bool]$CheckpointWritten
    }
}

function New-SREnvelope {
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Action = 'invalid',
        [string]$Reason = '',
        [string]$CauseReason = '',
        [string]$GoalId = '',
        [string]$SettledKey = '',
        [string]$RecoveryRecordRef = '',
        [string]$AssignmentFingerprint = '',
        [string]$NextIdempotencyKey = '',
        [string]$NextReference = '',
        [bool]$Prepared = $false,
        [string]$CheckpointId = '',
        [bool]$CheckpointOk = $false,
        $Effects = $null,
        [bool]$ManualFollowup = $false
    )
    if ($null -eq $Effects) { $Effects = New-SREffects }
    return [pscustomobject][ordered]@{
        ok                    = [bool]$Ok
        action                = ([string]$Action)
        reason                = ([string]$Reason)
        cause_reason          = ([string]$CauseReason)
        goal_id               = ([string]$GoalId)
        settled_key           = ([string]$SettledKey)
        recovery_record_ref   = ([string]$RecoveryRecordRef)
        assignment_fingerprint = ([string]$AssignmentFingerprint)
        next_idempotency_key  = ([string]$NextIdempotencyKey)
        next_reference        = ([string]$NextReference)
        prepared              = [bool]$Prepared
        checkpoint_id         = ([string]$CheckpointId)
        checkpoint_ok         = [bool]$CheckpointOk
        effects               = $Effects
        executor_calls        = 0
        manual_followup_required = [bool]$ManualFollowup
    }
}

function New-SRRefusal {
    [CmdletBinding()]
    param([string]$Reason = '', [string]$Cause = '', [string]$GoalId = '', [string]$SettledKey = '', [string]$Fingerprint = '', [string]$Action = 'blocked', [bool]$ManualFollowup = $false)
    return (New-SREnvelope -Ok $false -Action $Action -Reason $Reason -CauseReason $Cause -GoalId $GoalId -SettledKey $SettledKey -AssignmentFingerprint $Fingerprint -Effects (New-SREffects) -ManualFollowup $ManualFollowup)
}

function Test-SRReasonCode {
    <#
    .SYNOPSIS
        Limited enumeration of substitute-session reason codes.
    .DESCRIPTION
        Pure, never throws. The S4 request carries WHY a substitute asks
        (descriptor). Anything outside the closed list refuses with
        recovery-request-invalid. Never accepts Outcome/approved/verified/
        force: there is no such parameter, and Authorization fields beyond
        goal_id/owner/generation/source are never read as authority.
    #>
    [CmdletBinding()]
    param([string]$ReasonCode = '')
    try {
        $c = ([string]$ReasonCode).Trim()
        if (@('substitute-timeout', 'substitute-crash', 'operator-takeover', 'checkpoint-rebuild') -ccontains $c) {
            return [pscustomobject]@{ ok = $true; reason = ''; reason_code = $c }
        }
        return [pscustomobject]@{ ok = $false; reason = 'recovery-request-invalid'; reason_code = '' }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'recovery-request-invalid'; reason_code = '' } }
}

function Test-SRSubstituteSession {
    <#
    .SYNOPSIS
        Shape check of the substitute session descriptor. Never authenticates.
    #>
    [CmdletBinding()]
    param([string]$SubstituteSessionId = '')
    try {
        $s = ([string]$SubstituteSessionId).Trim()
        if ($s -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            return [pscustomobject]@{ ok = $false; reason = 'recovery-request-invalid' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; session_id = $s }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'recovery-request-invalid' } }
}

function Get-SRNextIntentView {
    <#
    .SYNOPSIS
        Unwraps a NextIntent envelope ({intent} or bare) without trusting it.
    .DESCRIPTION
        Read-only, never throws. NextIntent is a comparison reference only,
        never authority: this returns the view the pending comparator needs
        (key/task/agent/fingerprint) or empty strings when absent/invalid.
    #>
    [CmdletBinding()]
    param($NextIntent = $null)
    try {
        $real = $NextIntent
        if ($null -ne $real) {
            if ($real -is [System.Collections.IDictionary]) {
                if ($real.Contains('intent')) { $real = $real['intent'] }
            }
            else {
                $pp = $real.PSObject.Properties['intent']
                if ($null -ne $pp) { $real = $pp.Value }
            }
        }
        if ($null -eq $real) {
            return [pscustomobject]@{ key = ''; task_id = ''; agent = ''; fingerprint = '' }
        }
        $k = ([string](Get-SRValue $real 'idempotency_key' '')).Trim().ToLowerInvariant()
        if ($k -cnotmatch '^[a-f0-9]{32}$') { $k = '' }
        $fp = ''
        try {
            $fCmd = Get-Command Get-NDIntentFingerprint -ErrorAction SilentlyContinue
            if ($null -ne $fCmd) { $fp = ([string](Get-NDIntentFingerprint -Intent $real)).Trim() }
        }
        catch { $fp = '' }
        return [pscustomobject]@{
            key         = $k
            task_id     = ([string](Get-SRValue $real 'task_id' '')).Trim()
            agent       = ([string](Get-SRValue $real 'agent' '')).Trim()
            fingerprint = $fp
        }
    }
    catch { return [pscustomobject]@{ key = ''; task_id = ''; agent = ''; fingerprint = '' } }
}

function Get-SRAssignmentFingerprint {
    <#
    .SYNOPSIS
        Deterministic fingerprint of the recovery assignment (no timestamp).
    .DESCRIPTION
        Pure, never throws. Covers substitute session, owner/generation/
        source, S4 action, reason code, goal/settled key/source task and the
        causal links (receipt ref, evidence, candidate revision, next key,
        next intent fingerprint, original prepare session). The timestamp
        never participates: the same attribution replays deterministically.
    #>
    [CmdletBinding()]
    param(
        [string]$SubstituteSessionId = '',
        [string]$Owner = '',
        [long]$Generation = 0,
        [string]$Source = '',
        [string]$Action = '',
        [string]$ReasonCode = '',
        [string]$GoalId = '',
        [string]$SettledKey = '',
        [string]$SourceTaskId = '',
        [string]$ReceiptRef = '',
        [string]$EvidenceId = '',
        [long]$CandidateRevision = -1,
        [string]$NextKey = '',
        [string]$NextIntentFingerprint = '',
        [string]$OriginalPrepareSessionId = ''
    )
    try {
        $hCmd = Get-Command Get-NativeDispatchHash32 -ErrorAction SilentlyContinue
        if ($null -eq $hCmd) { return '' }
        $material = ('s4-recovery-v1|' + ([string]$SubstituteSessionId) + '|' + ([string]$Owner) + '|' + [string]([long]$Generation) + '|' + ([string]$Source) + '|' + ([string]$Action) + '|' + ([string]$ReasonCode) + '|' + ([string]$GoalId) + '|' + ([string]$SettledKey) + '|' + ([string]$SourceTaskId) + '|' + ([string]$ReceiptRef) + '|' + ([string]$EvidenceId) + '|' + [string]([long]$CandidateRevision) + '|' + ([string]$NextKey) + '|' + ([string]$NextIntentFingerprint) + '|' + ([string]$OriginalPrepareSessionId))
        return (Get-NativeDispatchHash32 $material)
    }
    catch { return '' }
}

function Open-SRRecoveryLock {
    <#
    .SYNOPSIS
        Exclusive per-settled-key recovery lock, distinct from ND locks.
    .DESCRIPTION
        Lock file `.recovery-<key>.lock` inside the advance dir (never the
        ND `.dispatch.lock`, never a task/global lock). Mirrors the ND lock
        discipline: advance-dir identity reasserted inside every attempt,
        lock-path reparse pre-check, FileShare.None, bounded timeout.
        Returns the handle or $null. Refusal reason via -RefusalReason:
        '' means plain contention (caller maps to recovery-lock-busy),
        anything else is an identity/reparse refusal (caller maps to
        recovery-record-uncertain). Never throws.
    #>
    [CmdletBinding()]
    param([string]$AdvanceDir = '', [string]$Ident = '', [string]$Key = '', [int]$LockTimeoutMs = 5000, [ref]$RefusalReason)
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($AdvanceDir) -or ($k -cnotmatch '^[a-f0-9]{32}$')) {
            if ($null -ne $RefusalReason) { $RefusalReason.Value = '' }
            return $null
        }
        $lockPath = Join-Path $AdvanceDir ('.recovery-' + $k + '.lock')
        $ms = [int]$LockTimeoutMs
        if ($ms -lt 0) { $ms = 0 }
        if ($ms -gt 60000) { $ms = 60000 }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($ms)
        do {
            $idChk = $null
            try {
                $idCmd = Get-Command Assert-NDDirIdentity -ErrorAction SilentlyContinue
                if ($null -eq $idCmd) {
                    if ($null -ne $RefusalReason) { $RefusalReason.Value = 'recovery-record-uncertain' }
                    return $null
                }
                $idChk = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
            }
            catch { $idChk = $null }
            if (($null -eq $idChk) -or (-not [bool](Get-SRValue $idChk 'ok' $false))) {
                if ($null -ne $RefusalReason) { $RefusalReason.Value = 'recovery-record-uncertain' }
                return $null
            }
            try {
                $safeCmd = Get-Command Test-NDLockPathOpenSafe -ErrorAction SilentlyContinue
                if (($null -ne $safeCmd) -and (-not (Test-NDLockPathOpenSafe -Path $lockPath))) {
                    if ($null -ne $RefusalReason) { $RefusalReason.Value = 'recovery-record-uncertain' }
                    return $null
                }
                return ([IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            }
            catch { Start-Sleep -Milliseconds 10 }
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($null -ne $RefusalReason) { $RefusalReason.Value = '' }
        return $null
    }
    catch {
        if ($null -ne $RefusalReason) { $RefusalReason.Value = '' }
        return $null
    }
}

function Read-SRRecoveryRecord {
    <#
    .SYNOPSIS
        Reads one recovery record without collapsing states.
    .DESCRIPTION
        Returns @{present, valid, record, reason}. Absence (no file) is
        present=$false. A non-regular/reparse entry, unreadable text,
        non-object JSON, or wrong schema shape is present=$true,
        valid=$false: the caller must preserve and refuse, never treat as
        absent and never overwrite. Correlation (goal/key match) is left to
        the caller, which refuses on mismatch the same way. Never throws.
    #>
    [CmdletBinding()]
    param([string]$AdvanceDir = '', [string]$Key = '')
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($AdvanceDir) -or ($k -cnotmatch '^[a-f0-9]{32}$')) {
            return [pscustomobject]@{ present = $false; valid = $false; record = $null; reason = 'recovery-request-invalid' }
        }
        $path = Join-Path $AdvanceDir ($k + '.recovery.json')
        if (-not (Test-Path -LiteralPath $path)) {
            return [pscustomobject]@{ present = $false; valid = $false; record = $null; reason = '' }
        }
        $rpCmd = Get-Command Test-NDPathWithoutReparsePoint -ErrorAction SilentlyContinue
        if (($null -ne $rpCmd) -and (-not (Test-NDPathWithoutReparsePoint -Path $path))) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $rdCmd = Get-Command Read-NDBoundedFileText -ErrorAction SilentlyContinue
        if ($null -eq $rdCmd) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $rd = Read-NDBoundedFileText -Path $path -MaxBytes 65536
        if (-not [bool](Get-SRValue $rd 'ok' $false)) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $text = ([string](Get-SRValue $rd 'text' ''))
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $rootCmd = Get-Command Test-NDJsonObjectRootText -ErrorAction SilentlyContinue
        if (($null -ne $rootCmd) -and (-not (Test-NDJsonObjectRootText -Text $text))) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $raw = $null
        try { $raw = ConvertFrom-Json $text } catch { $raw = $null }
        if ($null -eq $raw) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $sv = Get-SRValue $raw 'schema_version' $null
        if (($sv -is [array]) -or ([long]$sv -ne 1)) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $fp = Get-SRValue $raw 'assignment_fingerprint' $null
        if (($fp -is [array]) -or (([string]$fp).Trim() -cnotmatch '^[a-f0-9]{32}$')) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        $ph = Get-SRValue $raw 'phase' $null
        if (($ph -is [array]) -or (@('reserved', 'recorded') -cnotcontains ([string]$ph).Trim())) {
            return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' }
        }
        return [pscustomobject]@{ present = $true; valid = $true; record = $raw; reason = '' }
    }
    catch { return [pscustomobject]@{ present = $true; valid = $false; record = $null; reason = 'recovery-record-illegible' } }
}

function Write-SRRecoveryRecord {
    <#
    .SYNOPSIS
        Atomic publish of one recovery record, never overwriting silently.
    .DESCRIPTION
        Temp file in the same dir + post-write proof read. New publish
        fails when a record already exists. -AllowReservedUpdate rewrites
        ONLY when the current record parses with the expected fingerprint
        in phase reserved (crash/reserve resolution under the same lock).
        Any identity, reparse, shape, or proof failure returns $false and
        leaves the current record untouched. Never throws.
    #>
    [CmdletBinding()]
    param([string]$AdvanceDir = '', [string]$Ident = '', [string]$Key = '', $Record = $null, [switch]$AllowReservedUpdate, [string]$ExpectedFingerprint = '')
    try {
        if ($null -eq $Record) { return $false }
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($AdvanceDir) -or ($k -cnotmatch '^[a-f0-9]{32}$')) { return $false }
        $idCmd = Get-Command Assert-NDDirIdentity -ErrorAction SilentlyContinue
        if ($null -eq $idCmd) { return $false }
        $idPre = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
        if (-not [bool](Get-SRValue $idPre 'ok' $false)) { return $false }
        $path = Join-Path $AdvanceDir ($k + '.recovery.json')
        $rpCmd = Get-Command Test-NDPathWithoutReparsePoint -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $path) {
            if (($null -ne $rpCmd) -and (-not (Test-NDPathWithoutReparsePoint -Path $path))) { return $false }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            if (-not $AllowReservedUpdate) { return $false }
            $cur = Read-SRRecoveryRecord -AdvanceDir $AdvanceDir -Key $k
            if ((-not [bool](Get-SRValue $cur 'present' $false)) -or (-not [bool](Get-SRValue $cur 'valid' $false))) { return $false }
            $curRec = Get-SRValue $cur 'record' $null
            if ($null -eq $curRec) { return $false }
            $curFp = ([string](Get-SRValue $curRec 'assignment_fingerprint' '')).Trim()
            $curPh = ([string](Get-SRValue $curRec 'phase' '')).Trim()
            if (($curFp -cne ([string]$ExpectedFingerprint).Trim()) -or ($curPh -cne 'reserved')) { return $false }
        }
        $json = ConvertTo-Json -InputObject $Record -Depth 12 -Compress
        $tmp = Join-Path $AdvanceDir (('recovery-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
        catch { return $false }
        $idMove = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
        if (-not [bool](Get-SRValue $idMove 'ok' $false)) {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return $false
        }
        try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
        catch {
            $idCatch = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
            if (-not [bool](Get-SRValue $idCatch 'ok' $false)) { return $false }
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return $false
        }
        try {
            $back = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $wantFp = ([string](Get-SRValue $Record 'assignment_fingerprint' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($back) -or ([string]::IsNullOrWhiteSpace($wantFp))) { return $false }
            if ($back.IndexOf($wantFp, [StringComparison]::Ordinal) -lt 0) { return $false }
        }
        catch { return $false }
        return $true
    }
    catch { return $false }
}

function Save-SRRecoveryCheckpoint {
    <#
    .SYNOPSIS
        One checkpoint rebuild from canonical records (projection only).
    .DESCRIPTION
        Delegates to the S3a checkpoint builder (canonical goal record +
        sidecar), falling back to the plain step checkpoint when S3a is
        unavailable. Rebuild never invents a successor: it projects the live
        goal with the recorded advance reference. Returns
        @{ok, checkpoint_id, checkpoint_ok}. Never throws.
    #>
    [CmdletBinding()]
    param($Goal = $null, [string]$CheckpointDir = '', [string]$SettledKey = '', [string]$Move = '', [string]$StopReason = '', [string]$AdvanceRecordRef = '', [string]$NextIdempotencyKey = '', [string]$NextReference = '', [bool]$Prepared = $false)
    try {
        $scCmd = Get-Command Save-SCContinuationCheckpoint -ErrorAction SilentlyContinue
        if ($null -ne $scCmd) {
            $slot = $null
            try {
                $slot = Save-SCContinuationCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir -SettledKey $SettledKey -Move $Move -StopReason $StopReason -AdvanceRecordRef $AdvanceRecordRef -NextIdempotencyKey $NextIdempotencyKey -NextReference $NextReference -Prepared $Prepared
            }
            catch { $slot = $null }
            if ($null -eq $slot) {
                return [pscustomobject]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false }
            }
            return [pscustomobject]@{ ok = [bool](Get-SRValue $slot 'ok' $false); checkpoint_id = ([string](Get-SRValue $slot 'checkpoint_id' '')); checkpoint_ok = [bool](Get-SRValue $slot 'checkpoint_ok' $false) }
        }
        $alCmd = Get-Command Save-ALStepCheckpoint -ErrorAction SilentlyContinue
        if ($null -ne $alCmd) {
            $slot = $null
            try { $slot = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir } catch { $slot = $null }
            if ($null -eq $slot) {
                return [pscustomobject]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false }
            }
            return [pscustomobject]@{ ok = [bool](Get-SRValue $slot 'ok' $false); checkpoint_id = ([string](Get-SRValue $slot 'checkpoint_id' '')); checkpoint_ok = [bool](Get-SRValue $slot 'checkpoint_ok' $false) }
        }
        return [pscustomobject]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false }
    }
    catch { return [pscustomobject]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false } }
}

function Invoke-OrchestrationSettledRecovery {
    <#
    .SYNOPSIS
        S4 limitada: attributed recovery of a prepared/terminal advance.
    .DESCRIPTION
        Inputs are references (never proofs): GoalId, SettledKey,
        Authorization (explicit, correlated to the same goal), the
        substitute host-session descriptor, and a closed ReasonCode.
        NextIntent is a comparison reference only, never authority.
        `prepared=true` in the output describes existing canonical
        preparation; it never authorizes consumption by the substitute.

        Order (fail-closed): request/session shape -> canonical goal read
        (COMPLETED recognized without mutation) -> live authorization +
        ownership -> canonical advance/receipt reads + classification
        BEFORE any attribution -> recovery lock -> re-read + reserve ->
        allowed action only (S3a replay of prepared/terminal already
        validated; checkpoint rebuild from canonical records;
        blocked-manual as record-only) -> recorded -> release.

        Refusals before attribution write nothing (no domain write, no
        attribution). executor_calls is always 0.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$SettledKey = '',
        $Authorization = $null,
        [string]$SubstituteSessionId = '',
        [string]$ReasonCode = '',
        $NextIntent = $null,
        [string]$CheckpointDir = '',
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 5000
    )
    try {
        $gid = ([string]$GoalId).Trim()
        $sk = ([string]$SettledKey).Trim().ToLowerInvariant()
        if (($gid -cnotmatch '^[A-Za-z0-9._:-]{1,64}$') -or ($sk -cnotmatch '^[a-f0-9]{32}$')) {
            return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'goal-or-key-malformed' -GoalId $gid -SettledKey $sk -Action 'invalid')
        }
        $subChk = Test-SRSubstituteSession -SubstituteSessionId $SubstituteSessionId
        if (-not [bool](Get-SRValue $subChk 'ok' $false)) {
            return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'substitute-session-invalid' -GoalId $gid -SettledKey $sk -Action 'invalid')
        }
        $sub = ([string](Get-SRValue $subChk 'session_id' ''))
        $rcChk = Test-SRReasonCode -ReasonCode $ReasonCode
        if (-not [bool](Get-SRValue $rcChk 'ok' $false)) {
            return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'reason-code-unknown' -GoalId $gid -SettledKey $sk -Action 'invalid')
        }
        $rc = ([string](Get-SRValue $rcChk 'reason_code' ''))
        # Required canonical helpers; missing helpers fail closed before IO.
        $needCmds = @('Get-OrchestrationGoal', 'Test-NativeDispatchAuthorization', 'Get-OrchestrationDispatchReceiptDir', 'Resolve-NDGoalReceiptDir', 'Read-NDReceipt', 'Test-NDReceiptSemanticIntegrity', 'Get-NDAdvanceDir', 'Read-NDAdvanceRecord', 'Read-NDBoundedFileText', 'Test-NDJsonObjectRootText', 'Get-NativeDispatchHash32', 'Get-OrchestrationTask', 'Test-NDCandidateResultMatch', 'Invoke-OrchestrationSettledContinuation')
        foreach ($nc in $needCmds) {
            $c = Get-Command $nc -ErrorAction SilentlyContinue
            if ($null -eq $c) {
                return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'recovery-helper-unavailable' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
        }
        # Canonical goal read: COMPLETED is recognized without mutation and
        # without attribution; anything outside ACTIVE refuses (never resume).
        $gSlot = $null
        try { $gSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $gSlot = $null }
        if (($null -eq $gSlot) -or (-not [bool](Get-SRValue $gSlot 'ok' $false))) {
            $why = 'goal-reread-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-SRValue $gSlot 'reason' ''))) { $why = ('goal-reread-failed:' + [string](Get-SRValue $gSlot 'reason' '')) } } catch { }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $why -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $liveGoal = Get-SRValue $gSlot 'goal' $null
        if ($null -eq $liveGoal) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'goal-reread-failed' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $liveState = (([string](Get-SRValue $liveGoal 'state' '')).Trim().ToUpperInvariant())
        if ($liveState -ceq 'COMPLETED') {
            return (New-SREnvelope -Ok $true -Action 'already-completed' -Reason 'recovery-already-completed' -GoalId $gid -SettledKey $sk -Effects (New-SREffects))
        }
        if ($liveState -cne 'ACTIVE') {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause ('goal-not-active:' + $liveState) -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        # Live authorization + ownership/fencing (explicit allow, correlated
        # goal, live lease). Never trusts owner/generation by presence.
        $authGoal = ''
        try { $authGoal = ([string](Get-SRValue $Authorization 'goal_id' '')).Trim() } catch { $authGoal = '' }
        if ([string]::IsNullOrWhiteSpace($authGoal) -or ($authGoal -cne $gid)) {
            return (New-SRRefusal -Reason 'recovery-authorization-denied' -Cause 'auth-goal-mismatch' -GoalId $gid -SettledKey $sk)
        }
        $authSlot = $null
        try { $authSlot = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir } catch { $authSlot = $null }
        if (($null -eq $authSlot) -or (-not [bool](Get-SRValue $authSlot 'admitted' $false))) {
            $why = 'authorization-denied'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-SRValue $authSlot 'reason' ''))) { $why = ([string](Get-SRValue $authSlot 'reason' '')) } } catch { }
            if ($why -like 'ownership-not-held*') {
                return (New-SRRefusal -Reason 'recovery-ownership-stale' -Cause $why -GoalId $gid -SettledKey $sk)
            }
            return (New-SRRefusal -Reason 'recovery-authorization-denied' -Cause $why -GoalId $gid -SettledKey $sk)
        }
        $authOwner = ([string](Get-SRValue $Authorization 'owner' '')).Trim()
        $authGen = [long]0
        try { $authGen = [long](Get-SRValue $Authorization 'generation' 0) } catch { $authGen = 0 }
        $authSource = ([string](Get-SRValue $Authorization 'source' '')).Trim().ToLowerInvariant()
        # Canonical namespaces: receipt root + goal dir + advance dir.
        $recRoot = ''
        try { $recRoot = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot } catch { $recRoot = '' }
        if ([string]::IsNullOrWhiteSpace($recRoot)) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'receipt-dir-unresolvable' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $rState = $null
        try { $rState = Resolve-NDGoalReceiptDir -RootDir $recRoot -GoalId $gid } catch { $rState = $null }
        if (($null -eq $rState) -or (-not [bool](Get-SRValue $rState 'ok' $false))) {
            $why = 'receipt-dir-unresolvable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-SRValue $rState 'reason' ''))) { $why = ([string](Get-SRValue $rState 'reason' '')) } } catch { }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $why -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $rDir = ([string](Get-SRValue $rState 'dir' ''))
        $rIdent = ([string](Get-SRValue $rState 'created_utc' ''))
        $advState = $null
        try { $advState = Get-NDAdvanceDir -RootDir $recRoot -GoalId $gid } catch { $advState = $null }
        if (($null -eq $advState) -or (-not [bool](Get-SRValue $advState 'ok' $false))) {
            $why = 'advance-dir-unresolvable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-SRValue $advState 'reason' ''))) { $why = ([string](Get-SRValue $advState 'reason' '')) } } catch { }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $why -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $advDir = ([string](Get-SRValue $advState 'dir' ''))
        $advIdent = ([string](Get-SRValue $advState 'ident' ''))
        $advRecPath = Join-Path $advDir ($sk + '.advance.json')
        # Advance read BEFORE attribution. Absence is decided together with
        # the receipt below: settled-or-absent with no advance returns to
        # the normal path (zero PREPARE from S4); a stuck non-settled
        # handoff with no advance is still manual; illegible is preserved.
        $advAbsent = $false
        $advExists = $false
        try { $advExists = Test-Path -LiteralPath $advRecPath } catch { $advExists = $false }
        $adv = $null
        try { $adv = Read-NDAdvanceRecord -AdvanceDir $advDir -Key $sk } catch { $adv = $null }
        if ($null -eq $adv) {
            if (-not $advExists) { $advAbsent = $true }
            else {
                return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'advance-record-unreadable' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
        }
        $advGoal = ''
        $advKey = ''
        $advMove = ''
        $advPrepared = $false
        $advNextKey = ''
        $advNextTask = ''
        $advNextAgent = ''
        $advNextRef = ''
        $advStop = ''
        if (-not $advAbsent) {
            $advGoal = ([string](Get-SRValue $adv 'goal_id' '')).Trim()
            $advKey = ([string](Get-SRValue $adv 'settled_key' '')).Trim().ToLowerInvariant()
            if (($advGoal -cne $gid) -or ($advKey -cne $sk)) {
                return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'advance-record-mismatch' -GoalId $gid -SettledKey $sk -Action 'invalid')
            }
            $advMove = (([string](Get-SRValue $adv 'move' '')).Trim().ToUpperInvariant())
            try { $advPrepared = [bool](Get-SRValue $adv 'prepared' $false) } catch { $advPrepared = $false }
            $advNextKey = ([string](Get-SRValue $adv 'next_idempotency_key' '')).Trim().ToLowerInvariant()
            $advNextTask = ([string](Get-SRValue $adv 'next_task_id' '')).Trim()
            $advNextAgent = ([string](Get-SRValue $adv 'next_agent' '')).Trim()
            $advNextRef = ([string](Get-SRValue $adv 'next_reference' '')).Trim()
            $advStop = ([string](Get-SRValue $adv 'stop_reason' '')).Trim()
        }
        # Receipt read (canonical reader): settled is the only replayable
        # settlement; pending/prepared/claimed are manual; illegible is
        # preserved and refused. Never falls back to creation.
        $read = $null
        try { $read = Read-NDReceipt -Dir $rDir -Key $sk -Expected $rIdent -AllowHandoffPhases } catch { $read = $null }
        if (($null -eq $read) -or (-not [bool](Get-SRValue $read 'ok' $false))) {
            $why = 'receipt-unreadable'
            $present = $false
            try { $present = [bool](Get-SRValue $read 'present' $false) } catch { $present = $false }
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-SRValue $read 'reason' ''))) { $why = ([string](Get-SRValue $read 'reason' '')) } } catch { }
            if (-not $present) {
                if ($advAbsent) {
                    return (New-SRRefusal -Reason 'recovery-no-continuation' -Cause 'advance-record-absent' -GoalId $gid -SettledKey $sk -Action 'no-continuation')
                }
                return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause ('advance-without-settlement:' + $why) -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $why -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $rec = Get-SRValue $read 'receipt' $null
        if ($null -eq $rec) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'receipt-empty' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $recPhase = (([string](Get-SRValue $rec 'phase' '')).Trim().ToLowerInvariant())
        if ($recPhase -cne 'settled') {
            if (($recPhase -ceq 'pending') -or ($recPhase -ceq 'prepared') -or ($recPhase -ceq 'claimed')) {
                $cause = 'receipt-not-settled'
                if ($recPhase -ceq 'pending') { $cause = 'receipt-pending-confirm-manual' }
                if ($recPhase -ceq 'claimed') { $cause = 'receipt-claimed-ambiguous' }
                # Pending/ambiguous: attributed blocked-manual path below.
            }
            else {
                return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause ('receipt-phase:' + $recPhase) -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
        }
        # Correlation: receipt must belong to this goal with a live task.
        $recGoal = ([string](Get-SRValue $rec 'goal_id' '')).Trim()
        if ($recGoal -cne $gid) {
            return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'receipt-goal-mismatch' -GoalId $gid -SettledKey $sk -Action 'invalid')
        }
        $srcTask = ([string](Get-SRValue $rec 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($srcTask)) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'receipt-task-missing' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $recKey = ''
        try { $recKey = ([string](Get-SRValue $rec 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $recKey = '' }
        if ($recKey -cne $sk) {
            return (New-SRRefusal -Reason 'recovery-request-invalid' -Cause 'receipt-key-mismatch' -GoalId $gid -SettledKey $sk -Action 'invalid')
        }
        # Settled-only validation: semantic integrity, live task, the
        # worker_result binding to THIS settlement, and evidence presence.
        # Non-settled receipts (pending/prepared/claimed) skip settlement
        # validation: the settlement never completed, so there is nothing
        # to bind - they go straight to attributed blocked-manual below.
        # Content is revalidated by S3a on any replay; S4 never acts here.
        $evId = ([string](Get-SRValue $rec 'settle_evidence_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($evId)) { $evId = ([string](Get-SRValue $rec 'evidence_id' '')).Trim() }
        $recExpected = [long]-1
        $evMissing = $false
        $evBadCause = ''
        if ($recPhase -ceq 'settled') {
        # Integrity: semantic receipt integrity over goal+key (content must
        # hold; transport damage refuses above, content damage is ambiguous).
        $integ = $null
        try { $integ = Test-NDReceiptSemanticIntegrity -Receipt $rec -GoalId $gid -IdempotencyKey $sk } catch { $integ = $null }
        if (($null -eq $integ) -or (-not [bool](Get-SRValue $integ 'ok' $false))) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'receipt-integrity-invalid' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        # Live task correlation: the task must exist with a worker_result
        # bound to THIS settlement (no inheriting a later approval).
        $taskCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $taskCmd) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'taskkernel-unavailable' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $srcTask -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $task = $null }
        $taskErr = ''
        try {
            if ($null -ne $task) {
                if ($task -is [System.Collections.IDictionary]) { if ($task.Contains('error')) { $taskErr = ([string]$task['error']) } }
                else { $ep = $task.PSObject.Properties['error']; if ($null -ne $ep) { $taskErr = ([string]$ep.Value) } }
            }
        }
        catch { $taskErr = '' }
        if (($null -eq $task) -or (-not [string]::IsNullOrWhiteSpace($taskErr))) {
            $why = 'task-unreadable'
            if ($taskErr -ceq 'NOT_FOUND') { $why = 'task-not-found' }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $why -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $wrk = Get-SRValue $task 'worker_result' $null
        if ($null -eq $wrk) {
            return (New-SRRefusal -Reason 'recovery-settlement-ambiguous' -Cause 'worker-result-missing' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        try { $recExpected = [long](Get-SRValue $rec 'task_expected_revision' -1) } catch { $recExpected = [long]-1 }
        if ($recExpected -lt 1) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'receipt-task-revision-missing' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $wRev = [long]-1
        try { $wRev = [long](Get-SRValue $wrk 'revision' -1) } catch { $wRev = [long]-1 }
        if (($recExpected + 1) -ne $wRev) {
            return (New-SRRefusal -Reason 'recovery-settlement-ambiguous' -Cause 'worker-result-superseded' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        $settleStatus = (([string](Get-SRValue $rec 'settle_status' '')).Trim().ToLowerInvariant())
        $settleRefs = @((Get-SRValue $rec 'settle_claimed_evidence' @()))
        $wrNode = Get-SRValue $rec 'worker_result' $null
        if ([string]::IsNullOrWhiteSpace($settleStatus) -and ($null -ne $wrNode)) {
            $settleStatus = (([string](Get-SRValue $wrNode 'status' '')).Trim().ToLowerInvariant())
        }
        if ((@($settleRefs).Count -eq 0) -and ($null -ne $wrNode)) {
            $settleRefs = @((Get-SRValue $wrNode 'claimed_evidence' @()))
        }
        $wStatus = (([string](Get-SRValue $wrk 'status' '')).Trim().ToLowerInvariant())
        $wRefs = @((Get-SRValue $wrk 'claimed_evidence' @()))
        $match = $false
        try {
            $mCmd = Get-Command Test-NDCandidateResultMatch -ErrorAction SilentlyContinue
            if ($null -ne $mCmd) { $match = [bool](Test-NDCandidateResultMatch -Status $settleStatus -Refs @($settleRefs) -OtherStatus $wStatus -OtherRefs @($wRefs)) }
        }
        catch { $match = $false }
        if (-not $match) {
            return (New-SRRefusal -Reason 'recovery-settlement-ambiguous' -Cause 'worker-result-divergent' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        # Evidence presence (content validated below): missing evidence
        # is manual, never an auto effect.
        $evMissing = [string]::IsNullOrWhiteSpace($evId)
        if (-not $evMissing) {
            $evMissing = $true
            try {
                $evContained = $false
                $ecCmd = Get-Command Test-SCEvidenceIdContained -ErrorAction SilentlyContinue
                if ($null -ne $ecCmd) { $evContained = [bool](Test-SCEvidenceIdContained -EvidenceId $evId) }
                else {
                    if ((-not [IO.Path]::IsPathRooted($evId)) -and ([IO.Path]::GetFileName($evId) -ceq $evId) -and (-not $evId.Contains('..'))) { $evContained = $true }
                }
                if ($evContained -and (-not [string]::IsNullOrWhiteSpace($EvidenceStoreDir))) {
                    $evPath = Join-Path ([string]$EvidenceStoreDir).Trim() ($evId + '.json')
                    if (Test-Path -LiteralPath $evPath -PathType Leaf) { $evMissing = $false }
                }
            }
            catch { $evMissing = $true }
        }
        # Evidence content correlation (read-only): the present file must
        # parse and bind THIS settlement (evidence_id/task_id/run_id).
        # Damaged evidence is manual with a precise cause, never a replay.
        if (-not $evMissing) {
            $evRaw = $null
            try {
                $evRd = Read-NDBoundedFileText -Path $evPath -MaxBytes 1048576
                if ([bool](Get-SRValue $evRd 'ok' $false)) {
                    $evText = ([string](Get-SRValue $evRd 'text' ''))
                    # The bounded reader preserves a leading BOM while
                    # ReadAllText strips it: drop U+FEFF before shape/parse
                    # so a canonical BOM-prefixed record still validates.
                    $evText = $evText.TrimStart([char]0xFEFF)
                    $jrCmd = Get-Command Test-NDJsonObjectRootText -ErrorAction SilentlyContinue
                    $rootOk = $true
                    if ($null -ne $jrCmd) { $rootOk = [bool](Test-NDJsonObjectRootText -Text $evText) }
                    if ($rootOk -and (-not [string]::IsNullOrWhiteSpace($evText))) {
                        try { $evRaw = ConvertFrom-Json $evText } catch { $evRaw = $null }
                    }
                }
            }
            catch { $evRaw = $null }
            if ($null -eq $evRaw) { $evBadCause = 'evidence-unreadable' }
            elseif ((([string](Get-SRValue $evRaw 'evidence_id' '')).Trim() -cne $evId) -or (([string](Get-SRValue $evRaw 'task_id' '')).Trim() -cne $srcTask) -or (([string](Get-SRValue $evRaw 'run_id' '')).Trim().ToLowerInvariant() -cne $sk)) {
                $evBadCause = 'evidence-mismatch'
            }
        }
        }
        # Classification BEFORE any attribution. A stuck non-settled
        # handoff is manual with or without an advance decision; a settled
        # receipt with no advance belongs to the normal path.
        $nextView = Get-SRNextIntentView -NextIntent $NextIntent
        $intended = ''
        $manualCause = ''
        if ($recPhase -cne 'settled') {
            $intended = 'blocked-manual'
            if ($recPhase -ceq 'pending') { $manualCause = 'receipt-pending-confirm-manual' }
            elseif ($recPhase -ceq 'claimed') { $manualCause = 'receipt-claimed-ambiguous' }
            else { $manualCause = 'receipt-not-settled' }
        }
        elseif ($evBadCause -cne '') {
            $intended = 'blocked-manual'
            $manualCause = $evBadCause
        }
        elseif ($advAbsent) {
            return (New-SRRefusal -Reason 'recovery-no-continuation' -Cause 'advance-record-absent' -GoalId $gid -SettledKey $sk -Action 'no-continuation')
        }
        elseif ($evMissing) {
            $intended = 'blocked-manual'
            $manualCause = 'evidence-file-missing'
        }
        elseif ($advPrepared -and ((@('CONTINUE', 'RETRY') -ccontains $advMove))) {
            $intended = 'replay-prepared'
        }
        elseif ((-not $advPrepared) -and ((@('REPLAN', 'BLOCKED', 'COMPLETE') -ccontains $advMove))) {
            $intended = 'replay-terminal'
        }
        elseif ((-not $advPrepared) -and ((@('CONTINUE', 'RETRY') -ccontains $advMove))) {
            # Pending advance: the key never proves the intent (no integral
            # fingerprint, no historic session). Same key + same content is
            # manual; divergent content refuses; automatic ADVANCE is HOLD.
            if ([string]::IsNullOrWhiteSpace([string]$nextView.key)) {
                $intended = 'blocked-manual'
                $manualCause = 'recovery-pending-manual-required'
            }
            elseif (([string]$nextView.key -cne $advNextKey)) {
                return (New-SRRefusal -Reason 'recovery-intent-unproven' -Cause 'pending-key-content-divergent' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
            elseif ((($advNextTask -ne '') -and ([string]$nextView.task_id -cne $advNextTask)) -or (($advNextAgent -ne '') -and ([string]$nextView.agent -cne $advNextAgent))) {
                return (New-SRRefusal -Reason 'recovery-intent-unproven' -Cause 'pending-content-divergent' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
            }
            else {
                $intended = 'blocked-manual'
                $manualCause = 'recovery-pending-manual-required'
            }
        }
        else {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause ('advance-move-unknown:' + $advMove) -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        # Causal links for the attribution (never secrets, never the full
        # Authorization: owner/generation/source only).
        $origPrepSession = ([string](Get-SRValue $rec 'settle_session_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($origPrepSession)) { $origPrepSession = ([string](Get-SRValue $rec 'claim_session_id' '')).Trim() }
        $recRef = Join-Path $rDir ($sk + '.json')
        $proofNextKey = ([string]$nextView.key)
        if ([string]::IsNullOrWhiteSpace($proofNextKey)) { $proofNextKey = $advNextKey }
        $fp = Get-SRAssignmentFingerprint -SubstituteSessionId $sub -Owner $authOwner -Generation $authGen -Source $authSource -Action $intended -ReasonCode $rc -GoalId $gid -SettledKey $sk -SourceTaskId $srcTask -ReceiptRef $recRef -EvidenceId $evId -CandidateRevision $recExpected -NextKey $proofNextKey -NextIntentFingerprint ([string]$nextView.fingerprint) -OriginalPrepareSessionId $origPrepSession
        if ([string]::IsNullOrWhiteSpace($fp)) {
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'assignment-fingerprint-failed' -GoalId $gid -SettledKey $sk -ManualFollowup $true)
        }
        # Recovery lock (dedicated file, bounded wait). Contention refuses
        # busy; identity/reparse divergence refuses uncertain.
        $lockWhy = ''
        $rlock = $null
        try { $rlock = Open-SRRecoveryLock -AdvanceDir $advDir -Ident $advIdent -Key $sk -LockTimeoutMs $LockTimeoutMs -RefusalReason ([ref]$lockWhy) } catch { $rlock = $null }
        if ($null -eq $rlock) {
            if ([string]::IsNullOrWhiteSpace($lockWhy)) {
                return (New-SRRefusal -Reason 'recovery-lock-busy' -Cause 'recovery-lock-timeout' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
            }
            return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause $lockWhy -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
        }
        try {
            # Re-read under the lock: same attribution replays/recorded;
            # divergent attribution never overwrites; reserved re-executes
            # from canonical stores (a crash proves nothing).
            $cur = Read-SRRecoveryRecord -AdvanceDir $advDir -Key $sk
            if ([bool](Get-SRValue $cur 'present' $false)) {
                if (-not [bool](Get-SRValue $cur 'valid' $false)) {
                    return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause ([string](Get-SRValue $cur 'reason' 'recovery-record-illegible')) -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                }
                $curRec = Get-SRValue $cur 'record' $null
                $curGoal = ([string](Get-SRValue $curRec 'goal_id' '')).Trim()
                $curKey = ([string](Get-SRValue $curRec 'settled_key' '')).Trim().ToLowerInvariant()
                if (($curGoal -cne $gid) -or ($curKey -cne $sk)) {
                    return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'recovery-record-mismatch' -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                }
                $curFp = ([string](Get-SRValue $curRec 'assignment_fingerprint' '')).Trim()
                $curPhase = ([string](Get-SRValue $curRec 'phase' '')).Trim()
                if ($curFp -cne $fp) {
                    return (New-SRRefusal -Reason 'recovery-assignment-mismatch' -Cause 'assignment-divergent' -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                }
                if ($curPhase -ceq 'recorded') {
                    $curRes = Get-SRValue $curRec 'result' $null
                    $curAction = ([string](Get-SRValue $curRec 'action' '')).Trim()
                    $rOk = $false
                    try { $rOk = [bool](Get-SRValue $curRes 'ok' $false) } catch { $rOk = $false }
                    $rReason = ([string](Get-SRValue $curRes 'reason' ''))
                    $rCause = ([string](Get-SRValue $curRes 'cause_reason' ''))
                    $rPrep = $false
                    try { $rPrep = [bool](Get-SRValue $curRes 'prepared' $false) } catch { $rPrep = $false }
                    $rNextRef = ([string](Get-SRValue $curRes 'next_reference' ''))
                    $rCkId = ([string](Get-SRValue $curRes 'checkpoint_id' ''))
                    $rCkOk = $false
                    try { $rCkOk = [bool](Get-SRValue $curRes 'checkpoint_ok' $false) } catch { $rCkOk = $false }
                    $rNextK = ([string](Get-SRValue (Get-SRValue $curRec 'proof_refs' $null) 'next_key' ''))
                    $rMan = $false
                    if ($curAction -ceq 'blocked-manual') { $rMan = $true }
                    return (New-SREnvelope -Ok $rOk -Action $curAction -Reason $rReason -CauseReason $rCause -GoalId $gid -SettledKey $sk -RecoveryRecordRef (Join-Path $advDir ($sk + '.recovery.json')) -AssignmentFingerprint $fp -NextIdempotencyKey $rNextK -NextReference $rNextRef -Prepared $rPrep -CheckpointId $rCkId -CheckpointOk $rCkOk -Effects (New-SREffects -DomainMutated ([bool](Get-SRValue (Get-SRValue $curRes 'effects' $null) 'domain_mutated' $false)) -AttributionWritten $true -CheckpointWritten ([bool](Get-SRValue (Get-SRValue $curRes 'effects' $null) 'checkpoint_written' $false))) -ManualFollowup $rMan)
                }
                if ($curPhase -cne 'reserved') {
                    return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'recovery-phase-unknown' -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                }
                # Reserved: fall through and re-execute from canonical
                # stores (interruption never means "it did not run", and it
                # never means "it succeeded" either).
            }
            # Re-read the advance under the lock when the classification
            # relied on one (state may have moved). A blocked-manual
            # without an advance decision has nothing to reassert.
            if (-not $advAbsent) {
                $advRe = $null
                try { $advRe = Read-NDAdvanceRecord -AdvanceDir $advDir -Key $sk } catch { $advRe = $null }
                if ($null -ne $advRe) {
                    $reMove = (([string](Get-SRValue $advRe 'move' '')).Trim().ToUpperInvariant())
                    $rePrep = $false
                    try { $rePrep = [bool](Get-SRValue $advRe 'prepared' $false) } catch { $rePrep = $false }
                    $reGoal = ([string](Get-SRValue $advRe 'goal_id' '')).Trim()
                    $reKey = ([string](Get-SRValue $advRe 'settled_key' '')).Trim().ToLowerInvariant()
                    if (($reGoal -cne $gid) -or ($reKey -cne $sk) -or ($reMove -cne $advMove) -or ($rePrep -ne $advPrepared)) {
                        return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'advance-changed-under-lock' -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                    }
                }
                else {
                    return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'advance-unreadable-under-lock' -GoalId $gid -SettledKey $sk -Fingerprint $fp -ManualFollowup $true)
                }
            }
            $proofRefs = [ordered]@{
                receipt                 = $recRef
                advance                 = $advRecPath
                evidence_id             = $evId
                candidate_revision      = [long]$recExpected
                next_key                = $proofNextKey
                next_intent_fingerprint = ([string]$nextView.fingerprint)
                original_prepare_session_id = $origPrepSession
            }
            $nowIso = ([DateTime]::UtcNow.ToString('o'))
            if ($intended -ceq 'blocked-manual') {
                $resBody = [ordered]@{
                    ok = $true; reason = 'recovery-pending-manual-required'; cause_reason = $manualCause
                    prepared = $false; next_reference = ''; checkpoint_id = ''; checkpoint_ok = $false
                    effects = [ordered]@{ domain_mutated = $false; attribution_written = $true; checkpoint_written = $false }
                }
                if ($manualCause -cne 'recovery-pending-manual-required') {
                    $resBody['reason'] = 'recovery-settlement-ambiguous'
                }
                $record = [ordered]@{
                    schema_version = 1; goal_id = $gid; settled_key = $sk; source_task_id = $srcTask
                    assignment_fingerprint = $fp; substitute_session_id = $sub
                    authorization_owner = $authOwner; authorization_generation = [long]$authGen; authorization_source = $authSource
                    reason_code = $rc; action = 'blocked-manual'; proof_refs = $proofRefs
                    phase = 'reserved'; result = $resBody; created_at = $nowIso; recorded_at = ''
                }
                $isUpdate = [bool](Get-SRValue $cur 'present' $false)
                if ($isUpdate) {
                    if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record -AllowReservedUpdate -ExpectedFingerprint $fp)) {
                        return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'reserve-update-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
                    }
                }
                else {
                    if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record)) {
                        return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'reserve-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
                    }
                }
                $record['phase'] = 'recorded'
                $record['recorded_at'] = ([DateTime]::UtcNow.ToString('o'))
                if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record -AllowReservedUpdate -ExpectedFingerprint $fp)) {
                    return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'record-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
                }
                return (New-SREnvelope -Ok $true -Action 'blocked-manual' -Reason ([string]$resBody['reason']) -CauseReason $manualCause -GoalId $gid -SettledKey $sk -RecoveryRecordRef (Join-Path $advDir ($sk + '.recovery.json')) -AssignmentFingerprint $fp -NextIdempotencyKey $proofNextKey -Prepared $false -Effects (New-SREffects -AttributionWritten $true) -ManualFollowup $true)
            }
            # Replay path: reserve first, then delegate to the S3a
            # continuation (the owner of SETTLE/ADVANCE/PREPARE/COMPLETE).
            # The substitute session is a descriptor: S3a revalidates auth,
            # settlement, gates, and CAS on its own. No NextIntent is
            # forwarded: replay consumes the recorded successor only.
            $resvBody = [ordered]@{
                ok = $false; reason = 'recovery-reserved'; cause_reason = 'reserved-before-replay'
                prepared = $false; next_reference = ''; checkpoint_id = ''; checkpoint_ok = $false
                effects = [ordered]@{ domain_mutated = $false; attribution_written = $true; checkpoint_written = $false }
            }
            $record = [ordered]@{
                schema_version = 1; goal_id = $gid; settled_key = $sk; source_task_id = $srcTask
                assignment_fingerprint = $fp; substitute_session_id = $sub
                authorization_owner = $authOwner; authorization_generation = [long]$authGen; authorization_source = $authSource
                reason_code = $rc; action = $intended; proof_refs = $proofRefs
                phase = 'reserved'; result = $resvBody; created_at = $nowIso; recorded_at = ''
            }
            $isUpdate = [bool](Get-SRValue $cur 'present' $false)
            if ($isUpdate) {
                if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record -AllowReservedUpdate -ExpectedFingerprint $fp)) {
                    return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'reserve-update-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
                }
            }
            else {
                if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record)) {
                    return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'reserve-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
                }
            }
            $sc = $null
            try {
                $sc = Invoke-OrchestrationSettledContinuation -GoalId $gid -SettledKey $sk -Authorization $Authorization -SessionId $sub -CheckpointDir $CheckpointDir -GoalStoreDir $GoalStoreDir -EvidenceStoreDir $EvidenceStoreDir -ReceiptDir $ReceiptDir -TasksDir $TasksDir -FlagsPath $FlagsPath
            }
            catch { $sc = $null }
            $scOk = $false
            $scAction = 'blocked'
            $scReason = 'continuation-unavailable'
            $scCause = 's3a-exception'
            $scPrep = $false
            $scNextKey = ''
            $scNextRef = ''
            $scCkId = ''
            $scCkOk = $false
            $scMove = ''
            $scStop = ''
            $scAdvRef = $advRecPath
            if ($null -ne $sc) {
                try { $scOk = [bool](Get-SRValue $sc 'ok' $false) } catch { $scOk = $false }
                $scAction = ([string](Get-SRValue $sc 'action' 'blocked'))
                $scReason = ([string](Get-SRValue $sc 'reason' 'continuation-unavailable'))
                $scCause = ([string](Get-SRValue $sc 'cause_reason' ''))
                try { $scPrep = [bool](Get-SRValue $sc 'prepared' $false) } catch { $scPrep = $false }
                $scNextKey = ([string](Get-SRValue $sc 'next_idempotency_key' ''))
                $scNextRef = ([string](Get-SRValue $sc 'next_reference' ''))
                $scCkId = ([string](Get-SRValue $sc 'checkpoint_id' ''))
                try { $scCkOk = [bool](Get-SRValue $sc 'checkpoint_ok' $false) } catch { $scCkOk = $false }
                $scMove = ([string](Get-SRValue $sc 'move' ''))
                $scStop = ([string](Get-SRValue $sc 'stop_reason' ''))
                $tmpRef = ([string](Get-SRValue $sc 'advance_record_ref' ''))
                if (-not [string]::IsNullOrWhiteSpace($tmpRef)) { $scAdvRef = $tmpRef }
            }
            # Checkpoint rebuild: only when the replay reports a real effect
            # (prepared/terminal) but no checkpoint. One attempt from live
            # canonical reads; a second failure is recorded honestly, never
            # fabricated.
            if ((($scPrep) -or (($scAction -ceq 'completed') -and $scOk)) -and (-not $scCkOk)) {
                $liveRe = $null
                try {
                    $gsRe = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
                    if (($null -ne $gsRe) -and [bool](Get-SRValue $gsRe 'ok' $false)) { $liveRe = Get-SRValue $gsRe 'goal' $null }
                }
                catch { $liveRe = $null }
                if ($null -ne $liveRe) {
                    $rb = Save-SRRecoveryCheckpoint -Goal $liveRe -CheckpointDir $CheckpointDir -SettledKey $sk -Move $scMove -StopReason $scStop -AdvanceRecordRef $scAdvRef -NextIdempotencyKey $scNextKey -NextReference $scNextRef -Prepared $scPrep
                    if ([bool](Get-SRValue $rb 'checkpoint_ok' $false)) {
                        $scCkId = ([string](Get-SRValue $rb 'checkpoint_id' ''))
                        $scCkOk = $true
                    }
                }
            }
            # Domain accounting: S4 itself never writes domain stores. A
            # replay only re-confirms an already-recorded advance decision
            # (S3a cause 'advance-record-replay'), so the single domain
            # effect attributable to THIS recovery is a COMPLETED CAS the
            # delegation confirmed while the goal was ACTIVE on entry.
            $domainTouched = $false
            if ($scOk -and ($scAction -ceq 'completed') -and ($liveState -ceq 'ACTIVE')) {
                $domainTouched = $true
            }
            $resBody = [ordered]@{
                ok = $scOk; reason = $scReason; cause_reason = $scCause
                prepared = $scPrep; next_reference = $scNextRef; checkpoint_id = $scCkId; checkpoint_ok = $scCkOk
                effects = [ordered]@{ domain_mutated = $domainTouched; attribution_written = $true; checkpoint_written = $scCkOk }
            }
            $record['result'] = $resBody
            $record['phase'] = 'recorded'
            $record['recorded_at'] = ([DateTime]::UtcNow.ToString('o'))
            if (-not (Write-SRRecoveryRecord -AdvanceDir $advDir -Ident $advIdent -Key $sk -Record $record -AllowReservedUpdate -ExpectedFingerprint $fp)) {
                return (New-SRRefusal -Reason 'recovery-record-write-failed' -Cause 'record-failed' -GoalId $gid -SettledKey $sk -Fingerprint $fp)
            }
            $finAction = $intended
            if (-not $scOk) { $finAction = 'blocked' }
            return (New-SREnvelope -Ok $scOk -Action $finAction -Reason $scReason -CauseReason $scCause -GoalId $gid -SettledKey $sk -RecoveryRecordRef (Join-Path $advDir ($sk + '.recovery.json')) -AssignmentFingerprint $fp -NextIdempotencyKey $scNextKey -NextReference $scNextRef -Prepared $scPrep -CheckpointId $scCkId -CheckpointOk $scCkOk -Effects (New-SREffects -DomainMutated $domainTouched -AttributionWritten $true -CheckpointWritten $scCkOk))
        }
        finally {
            try { if ($null -ne $rlock) { $rlock.Dispose() } } catch { }
        }
    }
    catch {
        return (New-SRRefusal -Reason 'recovery-record-uncertain' -Cause 'recovery-internal-error' -GoalId ([string]$GoalId).Trim() -SettledKey ([string]$SettledKey).Trim())
    }
}
