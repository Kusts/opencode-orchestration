<#!
.SYNOPSIS
    F3 Etapa B/C: one-shot GitHub resume reconciler harness (no daemon).
.DESCRIPTION
    Single-shot CLI harness, dot-source safe. For each valid ghwait found
    via Get-OrchestrationGitHubWaits it loads a FRESH offline snapshot
    fixture (SnapshotsDir\<task_id>.snapshot.json), calls
    Test-OrchestrationGitHubResume with live flags, and ONLY on RESUME
    performs Confirm-OrchestrationGitHubResumeApplied (CAS) plus a Kernel
    unblock (Invoke-OrchestrationTaskTransition BLOCKED->IMPLEMENTING
    referencing the active_wait fingerprint). ghwait files are transport;
    the Kernel is the authority (no second store; no writes outside the
    Kernel task record and the ghwait applied_events log).

    READY (no executor) only notifies. Every other decision only records.
    No polling, no sleep, no timer, no retry loop, no watcher, no daemon,
    no scheduler, no service, no network, no gh calls, no merge/deploy,
    no DONE claim, no grant issuance. Never emits a runtime-real
    auto-resume verdict: wake-up needs authorized scheduling/infra

    Fixture layout per wait (keyed by wait task_id, charset [a-z0-9._-]):
      <task_id>.snapshot.json  fresh readiness snapshot (required)
      <task_id>.flags.json     required live evidence, explicit JSON
        bools: lease_alive, owner_alive, authorization_alive,
        executor_present, cancel_requested, github_auth_ok.
        Absent file or absent/non-bool value => HOLD fail-closed
        (flags-missing or flag-invalid-<name>); github_auth_ok
        false => HOLD github-auth-failed. No permissive defaults.
      <task_id>.eventid.txt    optional EventId (default 'evt-<task_id>')

    Exit 0 = reconcile pass completed (per-item decisions may be HOLD/
    KEEP_WAITING/TERMINAL; that is data, not failure). Exit 1 =
    transport/args failure. Stdout carries exactly one JSON envelope.
    PS 5.1 and PS7 compatible. ASCII-only.
#>
param(
    [string]$WaitsDir = '',
    [string]$SnapshotsDir = '',
    [string]$TasksDir = '',
    [string]$FlagsPath = '',
    [string]$PolicyPath = '',
    [string]$NowUtc = '',
    $MaxAgeSeconds = 300,
    [string]$ActorIdentitySource = 'explicit-cli',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

$GRR_LibDir = $null
try { $GRR_LibDir = $PSScriptRoot } catch { $GRR_LibDir = '' }
if ([string]::IsNullOrWhiteSpace([string]$GRR_LibDir)) {
    try { $GRR_LibDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $GRR_LibDir = '' }
}
try {
    $GRR_KernelLib = Join-Path ([string]$GRR_LibDir) 'lib\OrchestrationTaskKernel.ps1'
    if (Test-Path -LiteralPath $GRR_KernelLib -PathType Leaf) { . $GRR_KernelLib }
}
catch { }
try {
    $GRR_ResumeLib = Join-Path ([string]$GRR_LibDir) 'lib\OrchestrationGitHubResume.ps1'
    if (Test-Path -LiteralPath $GRR_ResumeLib -PathType Leaf) { . $GRR_ResumeLib }
}
catch { }
try {
    $GRR_DeliveryLib = Join-Path ([string]$GRR_LibDir) 'lib\OrchestrationDelivery.ps1'
    if (Test-Path -LiteralPath $GRR_DeliveryLib -PathType Leaf) { . $GRR_DeliveryLib }
}
catch { }

function Get-GRRFieldValue {
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

function Resolve-GRRPolicyFile {
    param([string]$PolicyPath = '')
    try {
        if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
            return @{ ok = $true; provided = $false; policy = $null; reason = '' }
        }
        if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
            return @{ ok = $false; provided = $true; policy = $null; reason = 'policy-invalid' }
        }
        $doc = $null
        try { $doc = (ConvertFrom-Json ([IO.File]::ReadAllText($PolicyPath, [Text.Encoding]::UTF8))) }
        catch { return @{ ok = $false; provided = $true; policy = $null; reason = 'policy-invalid' } }
        if ($null -eq $doc) {
            return @{ ok = $false; provided = $true; policy = $null; reason = 'policy-invalid' }
        }
        return @{ ok = $true; provided = $true; policy = $doc; reason = '' }
    }
    catch { return @{ ok = $false; provided = $true; policy = $null; reason = 'policy-invalid' } }
}

function Get-GRRFlagRequiredBool {
    param($Flags, [string]$Name)
    try {
        if ($null -eq $Flags) { return @{ ok = $false; value = $false; reason = ('flag-invalid-' + $Name) } }
        $v = $null
        $present = $false
        if ($Flags -is [System.Collections.IDictionary]) {
            if ($Flags.Contains($Name)) { $v = $Flags[$Name]; $present = $true }
        }
        else {
            $p = $Flags.PSObject.Properties[$Name]
            if ($null -ne $p) { $v = $p.Value; $present = $true }
        }
        if (-not $present) { return @{ ok = $false; value = $false; reason = ('flag-invalid-' + $Name) } }
        if (-not ($v -is [bool])) { return @{ ok = $false; value = $false; reason = ('flag-invalid-' + $Name) } }
        return @{ ok = $true; value = [bool]$v; reason = '' }
    }
    catch { return @{ ok = $false; value = $false; reason = ('flag-invalid-' + $Name) } }
}

function Test-GRRWaitKernelBinding {
    param($Wait, [string]$TasksDir = '')
    try {
        $tid = ''
        try { $tid = ([string](Get-GRRFieldValue $Wait 'task_id' '')).Trim() } catch { $tid = '' }
        if ([string]::IsNullOrWhiteSpace($tid)) {
            return @{ ok = $false; reason = 'invalid-wait-task'; taskFile = ''; revision = 0; fingerprint = '' }
        }
        $taskFile = ''
        try { $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir } catch { $taskFile = '' }
        if ([string]::IsNullOrWhiteSpace([string]$taskFile)) {
            return @{ ok = $false; reason = 'task-unreadable'; taskFile = ''; revision = 0; fingerprint = '' }
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) {
            return @{ ok = $false; reason = 'task-not-found'; taskFile = $taskFile; revision = 0; fingerprint = '' }
        }
        if ([bool]$slot.malformed) {
            return @{ ok = $false; reason = 'task-malformed'; taskFile = $taskFile; revision = 0; fingerprint = '' }
        }
        $rec = $slot.record
        $rev = 0
        try { $rev = [int]$slot.revision } catch { $rev = 0 }
        $state = ''
        try { $state = ([string]$rec['state']).Trim().ToUpperInvariant() } catch { $state = '' }
        if ($state -cne 'BLOCKED') {
            return @{ ok = $false; reason = 'kernel-not-blocked'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $chk = $null
        try { $chk = Test-TaskKernelActiveWait -Record $rec } catch { $chk = $null }
        if (($null -eq $chk) -or ([string]$chk.presence -cne 'valid')) {
            return @{ ok = $false; reason = 'wait-binding-mismatch:no-active-wait'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $aw = $null
        try { $aw = $rec['active_wait'] } catch { $aw = $null }
        if (($null -eq $aw) -or (-not ($aw -is [System.Collections.IDictionary]))) {
            return @{ ok = $false; reason = 'wait-binding-mismatch:no-active-wait'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $awType = ''; $awOwner = ''; $awAction = ''; $awDep = ''; $awFp = ''
        try {
            if ($aw.Contains('type')) { $awType = ([string]$aw['type']).Trim().ToLowerInvariant() }
            if ($aw.Contains('owner')) { $awOwner = ([string]$aw['owner']).Trim() }
            if ($aw.Contains('action')) { $awAction = ([string]$aw['action']).Trim() }
            if ($aw.Contains('dependency_id')) { $awDep = ([string]$aw['dependency_id']).Trim() }
            if ($aw.Contains('fingerprint')) { $awFp = ([string]$aw['fingerprint']).Trim() }
        }
        catch {
            return @{ ok = $false; reason = 'wait-binding-mismatch:active-wait-unreadable'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $wOwner = ([string](Get-GRRFieldValue $Wait 'owner' '')).Trim()
        $wRepo = ([string](Get-GRRFieldValue $Wait 'repository' '')).Trim().ToLowerInvariant()
        $wPr = 0
        try { $wPr = [long](Get-GRRFieldValue $Wait 'pr_number' 0) } catch { $wPr = 0 }
        $wSha = ([string](Get-GRRFieldValue $Wait 'expected_head_sha' '')).Trim().ToLowerInvariant()
        $expDep = ('github-ci:v1:' + $wRepo + ':' + [string]$wPr + ':' + $wSha)
        $expType = 'external_dependency'
        $expAction = 'revalidate-github-ci'
        $expOwnerP = $wOwner; $expActionP = $expAction; $expDepP = $expDep
        try { $expOwnerP = (Protect-TaskKernelText -Text $wOwner) } catch { }
        try { $expActionP = (Protect-TaskKernelText -Text $expAction) } catch { }
        try { $expDepP = (Protect-TaskKernelText -Text $expDep) } catch { }
        if (($awType -cne $expType) -or ($awOwner -cne $expOwnerP) -or ($awAction -cne $expActionP) -or ($awDep -cne $expDepP)) {
            return @{ ok = $false; reason = 'wait-binding-mismatch:fields-diverged'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $fpSlot = $null
        try { $fpSlot = Get-OrchestrationWaitFingerprint -Type $expType -Owner $wOwner -Action $expAction -DependencyId $expDep } catch { $fpSlot = $null }
        if (($null -eq $fpSlot) -or (-not [bool]$fpSlot.ok)) {
            return @{ ok = $false; reason = 'wait-binding-mismatch:fingerprint-derivation'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        $expFp = ([string]$fpSlot.fingerprint)
        if ([string]::IsNullOrWhiteSpace($expFp) -or ($awFp -cne $expFp) -or (([string]$chk.fingerprint) -cne $expFp)) {
            return @{ ok = $false; reason = 'wait-binding-mismatch:fingerprint-diverged'; taskFile = $taskFile; revision = $rev; fingerprint = '' }
        }
        return @{ ok = $true; reason = ''; taskFile = $taskFile; revision = $rev; fingerprint = $expFp }
    }
    catch { return @{ ok = $false; reason = 'internal-error'; taskFile = ''; revision = 0; fingerprint = '' } }
}

function Invoke-GRRKernelUnblock {
    param($TaskId, $Wait, $Bind, [string]$ActorSource = 'explicit-cli', [string]$TasksDir = '', [string]$FlagsPath = '')
    $out = @{ ok = $false; kernel = 'unblock-failed'; kernel_error = ''; mutated = $false }
    try {
        $actor = ([string](Get-GRRFieldValue $Wait 'owner' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) { $actor = ([string](Get-GRRFieldValue $Wait 'lease_owner' '')).Trim() }
        if ([string]::IsNullOrWhiteSpace($actor)) { $actor = 'planner' }
        $tr = $null
        try {
            $tr = Invoke-OrchestrationTaskTransition -TaskId ([string]$TaskId) -ToState 'IMPLEMENTING' `
                -Actor $actor -ExpectedRevision ([int]$Bind.revision) -WaitFingerprint ([string]$Bind.fingerprint) `
                -ActorIdentitySource $ActorSource -TasksDir $TasksDir `
                -FlagsPath $FlagsPath -TelemetryRoot ''
        }
        catch { $tr = $null }
        if (($null -ne $tr) -and [bool](Get-GRRFieldValue $tr 'ok' $false)) {
            $out.ok = $true; $out.kernel = 'unblocked'; $out.mutated = $true
            return $out
        }
        $e = 'transition-failed'
        try {
            $e2 = ([string](Get-GRRFieldValue $tr 'error' ''))
            if (-not [string]::IsNullOrWhiteSpace($e2)) { $e = $e2 }
        }
        catch { }
        $out.kernel_error = $e
        return $out
    }
    catch { $out.kernel_error = 'INTERNAL_ERROR'; return $out }
}

function Read-GRRJsonFile {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $fi = Get-Item -LiteralPath $Path -Force
        if ([long]$fi.Length -le 0 -or [long]$fi.Length -gt 262144) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function Invoke-GitHubResumeReconcile {
    [CmdletBinding()]
    param(
        [string]$WaitsDir = '',
        [string]$SnapshotsDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        $Policy = $null,
        [string]$NowUtc = '',
        $MaxAgeSeconds = 300,
        [string]$ActorIdentitySource = 'explicit-cli'
    )
    $items = New-Object System.Collections.ArrayList
    $anyResume = $false
    $anyKernelWrite = $false
    try {
        if ([string]::IsNullOrWhiteSpace($WaitsDir) -or [string]::IsNullOrWhiteSpace($SnapshotsDir)) {
            return [pscustomobject]@{
                ok = $false; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_FAIL'
                reason = 'invalid-args'; items = @(); kernel_mutated = $false
                grants_authority = $false; done_approved = $false
                merge_authority = $false; resume_authorized = $false
                scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
            }
        }
        $maxAge = 300
        try { $maxAge = [long]$MaxAgeSeconds } catch { $maxAge = 300 }
        $nowArg = $null
        if (-not [string]::IsNullOrWhiteSpace($NowUtc)) { $nowArg = ([string]$NowUtc) }
        $effPolicy = $Policy
        if ($null -eq $effPolicy) {
            try { $effPolicy = Get-OrchestrationDeliveryPolicy $null } catch { $effPolicy = $null }
        }
        $actorSrc = ([string]$ActorIdentitySource).Trim()
        if ([string]::IsNullOrWhiteSpace($actorSrc)) { $actorSrc = 'explicit-cli' }
        $lw = $null
        try { $lw = Get-OrchestrationGitHubWaits -WaitsDir $WaitsDir } catch { $lw = $null }
        if (($null -eq $lw) -or (-not [bool](Get-GRRFieldValue $lw 'ok' $false))) {
            $why = 'waits-dir-unreadable'
            try {
                $r = ([string](Get-GRRFieldValue $lw 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            return [pscustomobject]@{
                ok = $false; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_FAIL'
                reason = $why; items = @(); kernel_mutated = $false
                grants_authority = $false; done_approved = $false
                merge_authority = $false; resume_authorized = $false
                scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
            }
        }
        $waits = @()
        try { $waits = @(Get-GRRFieldValue $lw 'waits' @()) } catch { $waits = @() }
        foreach ($w in @($waits)) {
            $rec = [ordered]@{
                task_id = ''; dedup_key = ''; decision = 'HOLD'; reason = 'internal-error'
                readiness = 'UNKNOWN'; notify = ''; confirmed = $false; confirm_reason = ''
                kernel = 'not-attempted'; kernel_error = ''; kernel_mutated = $false
            }
            try {
                $tid = ([string](Get-GRRFieldValue $w 'task_id' '')).Trim()
                $ddk = ([string](Get-GRRFieldValue $w 'dedup_key' '')).Trim()
                $rec['task_id'] = $tid
                $rec['dedup_key'] = $ddk
                if ([string]::IsNullOrWhiteSpace($tid)) {
                    $rec['reason'] = 'invalid-wait-task'
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $flagsDoc = Read-GRRJsonFile -Path (Join-Path $SnapshotsDir ($tid + '.flags.json'))
                $evtId = ''
                try {
                    $evtPath = Join-Path $SnapshotsDir ($tid + '.eventid.txt')
                    if (Test-Path -LiteralPath $evtPath -PathType Leaf) {
                        $evtId = ([string][IO.File]::ReadAllText($evtPath, [Text.Encoding]::UTF8)).Trim()
                    }
                }
                catch { $evtId = '' }
                if ([string]::IsNullOrWhiteSpace($evtId)) { $evtId = ('evt-' + $tid) }
                if ($null -eq $flagsDoc) {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = 'flags-missing'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=flags-missing')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $authSlot = Get-GRRFlagRequiredBool $flagsDoc 'github_auth_ok'
                if (-not [bool]$authSlot.ok) {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = ([string]$authSlot.reason)
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=' + ([string]$authSlot.reason))
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                if (-not [bool]$authSlot.value) {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = 'github-auth-failed'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=github-auth-failed')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $snap = Read-GRRJsonFile -Path (Join-Path $SnapshotsDir ($tid + '.snapshot.json'))
                if ($null -eq $snap) {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = 'snapshot-missing'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=snapshot-missing')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $reqLease = Get-GRRFlagRequiredBool $flagsDoc 'lease_alive'
                $reqOwner = Get-GRRFlagRequiredBool $flagsDoc 'owner_alive'
                $reqAuthZ = Get-GRRFlagRequiredBool $flagsDoc 'authorization_alive'
                $reqExec = Get-GRRFlagRequiredBool $flagsDoc 'executor_present'
                $reqCancel = Get-GRRFlagRequiredBool $flagsDoc 'cancel_requested'
                $badFlag = ''
                if (-not [bool]$reqLease.ok) { $badFlag = 'flag-invalid-lease_alive' }
                elseif (-not [bool]$reqOwner.ok) { $badFlag = 'flag-invalid-owner_alive' }
                elseif (-not [bool]$reqAuthZ.ok) { $badFlag = 'flag-invalid-authorization_alive' }
                elseif (-not [bool]$reqExec.ok) { $badFlag = 'flag-invalid-executor_present' }
                elseif (-not [bool]$reqCancel.ok) { $badFlag = 'flag-invalid-cancel_requested' }
                if ($badFlag -cne '') {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = $badFlag
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=' + $badFlag)
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $leaseAlive = [bool]$reqLease.value
                $ownerAlive = [bool]$reqOwner.value
                $authAlive = [bool]$reqAuthZ.value
                $execPresent = [bool]$reqExec.value
                $cancelReq = [bool]$reqCancel.value
                $evtDdk = ''
                try {
                    $e = Get-GRRFieldValue $flagsDoc 'event_dedup_key' $null
                    if ($null -ne $e) { $evtDdk = ([string]$e).Trim() }
                }
                catch { $evtDdk = '' }
                $applied = @()
                try {
                    $rawApplied = Get-GRRFieldValue $w 'applied_events' $null
                    if ($null -ne $rawApplied) { $applied = @($rawApplied) }
                }
                catch { $applied = @() }
                $already = $false
                foreach ($seen in @($applied)) {
                    if ([string]$seen -ceq $evtId) { $already = $true; break }
                }
                $dec = $null
                try {
                    $dec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $snap -Policy $effPolicy `
                        -NowUtc $nowArg -MaxAgeSeconds $maxAge -LeaseAlive $leaseAlive `
                        -OwnerAlive $ownerAlive -AuthorizationAlive $authAlive `
                        -ExecutorPresent $execPresent -CancelRequested $cancelReq `
                        -AlreadyApplied $already -EventDedupKey $evtDdk
                }
                catch { $dec = $null }
                if ($null -eq $dec) {
                    $rec['decision'] = 'HOLD'
                    $rec['reason'] = 'decision-failed'
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $dName = ([string](Get-GRRFieldValue $dec 'decision' 'INVALID')).Trim().ToUpperInvariant()
                $dReason = ([string](Get-GRRFieldValue $dec 'reason' 'internal-error'))
                $dRdy = ([string](Get-GRRFieldValue $dec 'readiness' 'UNKNOWN'))
                $dNotify = ([string](Get-GRRFieldValue $dec 'notify' ''))
                $rec['decision'] = $dName
                $rec['reason'] = $dReason
                $rec['readiness'] = $dRdy
                $rec['notify'] = $dNotify
                if ($dName -ceq 'RESUME') {
                    $bind = Test-GRRWaitKernelBinding -Wait $w -TasksDir $TasksDir
                    if (-not [bool]$bind.ok) {
                        $rec['decision'] = 'HOLD'
                        $rec['reason'] = ([string]$bind.reason)
                        $rec['kernel'] = 'not-attempted'
                        $rec['confirmed'] = $false
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $ub = Invoke-GRRKernelUnblock -TaskId $tid -Wait $w -Bind $bind `
                        -ActorSource $actorSrc -TasksDir $TasksDir -FlagsPath $FlagsPath
                    $rec['kernel'] = ([string]$ub.kernel)
                    $rec['kernel_error'] = ([string]$ub.kernel_error)
                    $rec['kernel_mutated'] = [bool]$ub.mutated
                    if (-not [bool]$ub.ok) {
                        $rec['decision'] = 'HOLD'
                        $ubErr = ([string]$ub.kernel_error)
                        if ([string]::IsNullOrWhiteSpace($ubErr)) { $ubErr = 'transition-failed' }
                        $rec['reason'] = ('unblock-refused:' + $ubErr)
                        $rec['confirmed'] = $false
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $anyKernelWrite = $true
                    $anyResume = $true
                    $cf = $null
                    try {
                        $cf = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $WaitsDir -DedupKey $ddk -EventId $evtId
                    }
                    catch { $cf = $null }
                    if ($null -eq $cf) {
                        $rec['reason'] = 'confirm-failed-after-unblock'
                        $rec['confirm_reason'] = 'confirm-failed-after-unblock'
                        $rec['confirmed'] = $false
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $cfOk = [bool](Get-GRRFieldValue $cf 'ok' $false)
                    $cfReason = ([string](Get-GRRFieldValue $cf 'reason' ''))
                    $rec['confirm_reason'] = $cfReason
                    if ($cfOk) {
                        $rec['confirmed'] = $true
                    }
                    else {
                        if ([string]::IsNullOrWhiteSpace($cfReason)) { $cfReason = 'confirm-failed' }
                        $rec['reason'] = ('confirm-failed-after-unblock:' + $cfReason)
                        $rec['confirm_reason'] = $cfReason
                        $rec['confirmed'] = $false
                    }
                }
                elseif ($dName -ceq 'DUPLICATE_NOOP') {
                    $rec['confirmed'] = $true
                    $rec['kernel'] = 'not-attempted'
                    $reDec = $null
                    try {
                        $reDec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $snap -Policy $effPolicy `
                            -NowUtc $nowArg -MaxAgeSeconds $maxAge -LeaseAlive $leaseAlive `
                            -OwnerAlive $ownerAlive -AuthorizationAlive $authAlive `
                            -ExecutorPresent $execPresent -CancelRequested $cancelReq `
                            -AlreadyApplied $false -EventDedupKey $evtDdk
                    }
                    catch { $reDec = $null }
                    if ($null -eq $reDec) {
                        $rec['decision'] = 'HOLD'
                        $rec['reason'] = 'revalidation-hold:decision-failed'
                        $rec['notify'] = ('HOLD ' + $tid + ' reason=revalidation-hold:decision-failed')
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $reName = ([string](Get-GRRFieldValue $reDec 'reason' 'internal-error'))
                    $reDecision = ([string](Get-GRRFieldValue $reDec 'decision' 'INVALID')).Trim().ToUpperInvariant()
                    $reRdy = ([string](Get-GRRFieldValue $reDec 'readiness' 'UNKNOWN'))
                    if ($reDecision -cne 'RESUME') {
                        $rec['decision'] = 'HOLD'
                        $rec['reason'] = ('revalidation-hold:' + $reName)
                        $rec['readiness'] = $reRdy
                        $rec['notify'] = ('HOLD ' + $tid + ' reason=revalidation-hold:' + $reName)
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $rec['readiness'] = $reRdy
                    $bind2 = Test-GRRWaitKernelBinding -Wait $w -TasksDir $TasksDir
                    if (-not [bool]$bind2.ok) {
                        if ([string]$bind2.reason -cne 'kernel-not-blocked') {
                            $rec['decision'] = 'HOLD'
                            $rec['reason'] = ([string]$bind2.reason)
                        }
                    }
                    else {
                        $ub2 = Invoke-GRRKernelUnblock -TaskId $tid -Wait $w -Bind $bind2 `
                            -ActorSource $actorSrc -TasksDir $TasksDir -FlagsPath $FlagsPath
                        if ([bool]$ub2.ok) {
                            $rec['decision'] = 'RESUME'
                            $rec['reason'] = 'reconciled-pending-confirm'
                            $rec['kernel'] = 'unblocked'
                            $rec['kernel_error'] = ''
                            $rec['kernel_mutated'] = $true
                            $anyKernelWrite = $true
                            $anyResume = $true
                        }
                        else {
                            $rec['decision'] = 'HOLD'
                            $ubErr2 = ([string]$ub2.kernel_error)
                            if ([string]::IsNullOrWhiteSpace($ubErr2)) { $ubErr2 = 'transition-failed' }
                            $rec['reason'] = ('unblock-refused:' + $ubErr2)
                            $rec['kernel'] = 'unblock-failed'
                            $rec['kernel_error'] = $ubErr2
                        }
                    }
                }
                elseif ($dName -ceq 'READY') {
                    $rec['kernel'] = 'not-attempted'
                }
                else {
                    $rec['kernel'] = 'not-attempted'
                }
            }
            catch {
                try { $rec['reason'] = 'internal-error' } catch { }
            }
            [void]$items.Add([pscustomobject]$rec)
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_FAIL'
            reason = 'internal-error'; items = @($items.ToArray()); kernel_mutated = $anyKernelWrite
            grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $anyResume
            scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
        }
    }
    return [pscustomobject]@{
        ok = $true; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_PASS'
        reason = ''; items = @($items.ToArray()); kernel_mutated = $anyKernelWrite
        grants_authority = $false; done_approved = $false
        merge_authority = $false; resume_authorized = $anyResume
        scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
    }
}

if ((-not [string]::IsNullOrWhiteSpace($WaitsDir)) -or (-not [string]::IsNullOrWhiteSpace($SnapshotsDir))) {
    function Write-GRREnvelope {
        param($Envelope)
        try { Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress) }
        catch {
            Write-Output '{"ok":false,"harness":"github-resume-reconcile-v1","verdict":"HARNESS_FAIL","reason":"encode-failed","items":[],"kernel_mutated":false,"grants_authority":false,"done_approved":false,"merge_authority":false,"resume_authorized":false}'
        }
    }
    $GRR_Policy = $null
    $GRR_PolicyBad = $false
    try {
        $GRR_PolRes = Resolve-GRRPolicyFile -PolicyPath $PolicyPath
        if ([bool]$GRR_PolRes.ok) { $GRR_Policy = $GRR_PolRes.policy }
        elseif ([bool]$GRR_PolRes.provided) { $GRR_PolicyBad = $true }
    }
    catch { $GRR_Policy = $null }
    if ($GRR_PolicyBad) {
        $GRR_FailEnv = [pscustomobject]@{
            ok = $false; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_FAIL'
            reason = 'policy-invalid'; items = @(); kernel_mutated = $false
            grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $false
            scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
        }
        Write-GRREnvelope -Envelope $GRR_FailEnv
        exit 1
    }
    $GRR_Out = $null
    try {
        $GRR_Out = Invoke-GitHubResumeReconcile -WaitsDir $WaitsDir -SnapshotsDir $SnapshotsDir `
            -TasksDir $TasksDir -FlagsPath $FlagsPath -Policy $GRR_Policy `
            -NowUtc $NowUtc -MaxAgeSeconds $MaxAgeSeconds -ActorIdentitySource $ActorIdentitySource
    }
    catch {
        $GRR_Out = [pscustomobject]@{
            ok = $false; harness = 'github-resume-reconcile-v1'; verdict = 'HARNESS_FAIL'
            reason = 'internal-error'; items = @(); kernel_mutated = $false
            grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $false
            scheduling_gap = 'no-scheduler-no-wakeup: one-shot only; planner or authorized infra must invoke per fresh snapshot'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        try {
            $GRR_Json = ConvertTo-Json -InputObject $GRR_Out -Depth 10 -Compress
            [IO.File]::WriteAllText($OutFile, $GRR_Json, (New-Object Text.UTF8Encoding $false))
        }
        catch { }
    }
    Write-GRREnvelope -Envelope $GRR_Out
    if ([bool]$GRR_Out.ok) { exit 0 } else { exit 1 }
}
