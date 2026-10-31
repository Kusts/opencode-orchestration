<#!
.SYNOPSIS
    Etapa 6D GH-WAKE: real scheduled wake for GitHub CI waits (single-shot).
.DESCRIPTION
    Single-shot CLI, dot-source safe. Scans valid ghwait documents once,
    fetches one FRESH snapshot per wait through the REAL github-await
    transport (gh api graphql, never reimplemented here; fixture file is
    test-only), evaluates readiness through the pure Delivery function and
    the resume caller (never reimplemented here), checks the durable Goal
    checkpoint before announcing any next action, and ONLY on RESUME performs
    a CAS confirm plus a Kernel BLOCKED->IMPLEMENTING unblock referencing
    the active-wait fingerprint. No daemon, no watcher, no service, no
    second control plane, no new Kernel, no polling, no busy loop: one pass
    over the waits directory, bounded API retry (MaxApiAttempts, default 3,
    linear backoff), then exit. No merge, no push, no deploy, no DONE claim,
    no grant issuance, no tokens stored or read, no LLM in the loop.
    Authority pins are always false except resume_authorized on RESUME.
    Scheduler: Register/Unregister-GitHubWakeSchedule manage a Windows
    Scheduled Task via schtasks.exe with an explicit XML definition
    (bounded repetition, execution time limit, battery blocks disabled),
    invoking this CLI as a separate process with args persisted in a JSON
    config file. No ScheduledTasks module required.
    PS 5.1 and PS7 compatible. ASCII-only.

    Usage (scheduled/live):
      powershell -NoProfile -File github-wake.ps1 -ConfigFile <path>

    Usage (explicit dirs):
      powershell -NoProfile -File github-wake.ps1 -WaitsDir <dir> `
        -TasksDir <dir> -GoalStoreDir <dir> -CheckpointDir <dir> `
        -FlagsPath <flags.json> -AuthorizationAlive:$true `
        [-ExecutorPresent:$true] [-GraphQLSnapshotFile <raw-fixture>]

    Exit 0 = wake pass completed (per-item HOLD/KEEP_WAITING/TERMINAL are
    data, not failure). Exit 1 = transport/scan failure. Exit 2 = args.
    Stdout carries exactly one JSON envelope. Dot-source safe: without
    -WaitsDir and without -ConfigFile this file defines functions only.
#>
param(
    [string]$WaitsDir = '',
    [string]$TasksDir = '',
    [string]$GoalStoreDir = '',
    [string]$CheckpointDir = '',
    [string]$ConfigFile = '',
    [string]$FlagsPath = '',
    [string]$PolicyPath = '',
    [string]$GraphQLSnapshotFile = '',
    [string]$EventId = '',
    $MaxAgeSeconds = 300,
    [string]$NowUtc = '',
    [string]$ActorIdentitySource = 'explicit-cli',
    [switch]$AuthorizationAlive,
    [switch]$ExecutorPresent,
    [switch]$CancelRequested,
    $MaxApiAttempts = 3,
    $TimeoutMs = 10000,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

# Dot-sourcing github-await.ps1 runs its param block in this scope, which
# would overwrite same-named parameters. Save and restore around each
# dot-source; await and reconcile are dot-source safe so their entrypoint
# guards stay silent with default (empty) values.
$GHW_SavedWaitsDir = $WaitsDir
$GHW_SavedTasksDir = $TasksDir
$GHW_SavedGoalStoreDir = $GoalStoreDir
$GHW_SavedCheckpointDir = $CheckpointDir
$GHW_SavedConfigFile = $ConfigFile
$GHW_SavedFlagsPath = $FlagsPath
$GHW_SavedPolicyPath = $PolicyPath
$GHW_SavedGraphQLSnapshotFile = $GraphQLSnapshotFile
$GHW_SavedEventId = $EventId
$GHW_SavedMaxAgeSeconds = $MaxAgeSeconds
$GHW_SavedNowUtc = $NowUtc
$GHW_SavedActorIdentitySource = $ActorIdentitySource
$GHW_SavedAuthorizationAlive = $AuthorizationAlive
$GHW_SavedExecutorPresent = $ExecutorPresent
$GHW_SavedCancelRequested = $CancelRequested
$GHW_SavedMaxApiAttempts = $MaxApiAttempts
$GHW_SavedTimeoutMs = $TimeoutMs
$GHW_SavedOutFile = $OutFile
. (Join-Path $PSScriptRoot 'github-await.ps1')
$WaitsDir = $GHW_SavedWaitsDir
$TasksDir = $GHW_SavedTasksDir
$GoalStoreDir = $GHW_SavedGoalStoreDir
$CheckpointDir = $GHW_SavedCheckpointDir
$ConfigFile = $GHW_SavedConfigFile
$FlagsPath = $GHW_SavedFlagsPath
$PolicyPath = $GHW_SavedPolicyPath
$GraphQLSnapshotFile = $GHW_SavedGraphQLSnapshotFile
$EventId = $GHW_SavedEventId
$MaxAgeSeconds = $GHW_SavedMaxAgeSeconds
$NowUtc = $GHW_SavedNowUtc
$ActorIdentitySource = $GHW_SavedActorIdentitySource
$AuthorizationAlive = $GHW_SavedAuthorizationAlive
$ExecutorPresent = $GHW_SavedExecutorPresent
$CancelRequested = $GHW_SavedCancelRequested
$MaxApiAttempts = $GHW_SavedMaxApiAttempts
$TimeoutMs = $GHW_SavedTimeoutMs
$OutFile = $GHW_SavedOutFile
$GHW_SavedSnapshotsDir = ''
. (Join-Path $PSScriptRoot 'github-resume-reconcile.ps1')
$WaitsDir = $GHW_SavedWaitsDir
$TasksDir = $GHW_SavedTasksDir
$GoalStoreDir = $GHW_SavedGoalStoreDir
$CheckpointDir = $GHW_SavedCheckpointDir
$ConfigFile = $GHW_SavedConfigFile
$FlagsPath = $GHW_SavedFlagsPath
$PolicyPath = $GHW_SavedPolicyPath
$GraphQLSnapshotFile = $GHW_SavedGraphQLSnapshotFile
$EventId = $GHW_SavedEventId
$MaxAgeSeconds = $GHW_SavedMaxAgeSeconds
$NowUtc = $GHW_SavedNowUtc
$ActorIdentitySource = $GHW_SavedActorIdentitySource
$AuthorizationAlive = $GHW_SavedAuthorizationAlive
$ExecutorPresent = $GHW_SavedExecutorPresent
$CancelRequested = $GHW_SavedCancelRequested
$MaxApiAttempts = $GHW_SavedMaxApiAttempts
$TimeoutMs = $GHW_SavedTimeoutMs
$OutFile = $GHW_SavedOutFile
Remove-Variable -Name GHW_SavedWaitsDir, GHW_SavedTasksDir, GHW_SavedGoalStoreDir, GHW_SavedCheckpointDir, GHW_SavedConfigFile, GHW_SavedFlagsPath, GHW_SavedPolicyPath, GHW_SavedGraphQLSnapshotFile, GHW_SavedEventId, GHW_SavedMaxAgeSeconds, GHW_SavedNowUtc, GHW_SavedActorIdentitySource, GHW_SavedAuthorizationAlive, GHW_SavedExecutorPresent, GHW_SavedCancelRequested, GHW_SavedMaxApiAttempts, GHW_SavedTimeoutMs, GHW_SavedOutFile, GHW_SavedSnapshotsDir -ErrorAction SilentlyContinue
try {
    $GHW_LibDir = $PSScriptRoot
    $GHW_DeliveryLib = Join-Path $GHW_LibDir 'lib\OrchestrationDelivery.ps1'
    if (Test-Path -LiteralPath $GHW_DeliveryLib -PathType Leaf) { . $GHW_DeliveryLib }
    $GHW_CheckpointLib = Join-Path $GHW_LibDir 'lib\OrchestrationGoalCheckpoint.ps1'
    if (Test-Path -LiteralPath $GHW_CheckpointLib -PathType Leaf) { . $GHW_CheckpointLib }
}
catch { }

function Get-GHWValue {
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

function Test-GHWTaskName {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        if ($v -cnotmatch '\A[A-Za-z0-9._-]+\Z') { return $false }
        return $true
    }
    catch { return $false }
}

function Test-GHWEventId {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 256) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]+$')
    }
    catch { return $false }
}

function Convert-GHWUtc {
    param($Value)
    try {
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) {
            try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
        }
        if ($Value -is [string]) {
            $s = ([string]$Value).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            $dt = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            try {
                if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) { return $dt }
            }
            catch { return $null }
            return $null
        }
        return $null
    }
    catch { return $null }
}

function Test-GHWStrictInt {
    param($Value, [long]$Min = 1, [long]$Max = 3600)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        $n = [long]$Value
        return (($n -ge $Min) -and ($n -le $Max))
    }
    catch { return $false }
}

function Read-GHWJsonFile {
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

function Resolve-GHWPolicy {
    param([string]$PolicyPath = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
            $doc = Read-GHWJsonFile -Path ([string]$PolicyPath).Trim()
            if ($null -eq $doc) { return @{ ok = $false; policy = $null; reason = 'policy-invalid' } }
            return @{ ok = $true; policy = $doc; reason = '' }
        }
        $pol = $null
        try { $pol = Get-OrchestrationDeliveryPolicy $null } catch { $pol = $null }
        if ($null -eq $pol) { return @{ ok = $false; policy = $null; reason = 'policy-invalid' } }
        return @{ ok = $true; policy = $pol; reason = '' }
    }
    catch { return @{ ok = $false; policy = $null; reason = 'policy-invalid' } }
}

function Find-GHWNewestCheckpoint {
    param([string]$CheckpointDir = '', [string]$GoalId = '')
    try {
        $dir = ([string]$CheckpointDir).Trim()
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($dir) -or (-not (Test-Path -LiteralPath $dir -PathType Container))) {
            return @{ ok = $false; checkpoint_id = ''; reason = 'checkpoint-dir-unreadable' }
        }
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return @{ ok = $false; checkpoint_id = ''; reason = 'invalid-goal' }
        }
        $bestId = ''
        $bestAt = ''
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction Stop)) {
            if ([long]$f.Length -le 0 -or [long]$f.Length -gt 262144) { continue }
            $doc = $null
            try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } catch { continue }
            $docGid = ([string](Get-GHWValue $doc 'goal_id' '')).Trim()
            if ($docGid -cne $gid) { continue }
            $cid = ([string](Get-GHWValue $doc 'checkpoint_id' '')).Trim()
            if ($cid -cnotmatch '^[a-f0-9]{16}$') { continue }
            $at = ([string](Get-GHWValue $doc 'created_at' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($bestId) -or ([string]$at -cgt [string]$bestAt)) {
                $bestId = $cid
                $bestAt = $at
            }
        }
        if ([string]::IsNullOrWhiteSpace($bestId)) {
            return @{ ok = $false; checkpoint_id = ''; reason = 'checkpoint-missing' }
        }
        return @{ ok = $true; checkpoint_id = $bestId; reason = '' }
    }
    catch { return @{ ok = $false; checkpoint_id = ''; reason = 'checkpoint-dir-unreadable' } }
}

function Invoke-GHWObserve {
    [CmdletBinding()]
    param(
        [string]$Repository = '',
        [long]$PrNumber = 0,
        [string]$ExpectedHeadSha = '',
        [string]$ObservedAt = '',
        [string]$GraphQLSnapshotFile = '',
        [int]$TimeoutMs = 10000,
        [int]$MaxApiAttempts = 3
    )
    try {
        $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        $expLow = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($GraphQLSnapshotFile)) {
            $fx = ([string]$GraphQLSnapshotFile).Trim()
            $raw = $null
            try {
                if (-not (Test-Path -LiteralPath $fx -PathType Leaf)) {
                    return @{ ok = $false; snapshot = $null; transport = 'fixture-declared'; attempts = 0; reason = 'invalid-snapshot-file'; detail = '' }
                }
                $fxi = Get-Item -LiteralPath $fx -Force
                if ([long]$fxi.Length -le 0 -or [long]$fxi.Length -gt 262144) {
                    return @{ ok = $false; snapshot = $null; transport = 'fixture-declared'; attempts = 0; reason = 'invalid-snapshot-file'; detail = '' }
                }
                $raw = ConvertFrom-Json ([IO.File]::ReadAllText($fx, [Text.Encoding]::UTF8))
            }
            catch {
                return @{ ok = $false; snapshot = $null; transport = 'fixture-declared'; attempts = 0; reason = 'snapshot-unparseable'; detail = '' }
            }
            $norm = Convert-GHARawToSnapshot -Raw $raw -Repository $repoCanon -PrNumber $PrNumber -ObservedAt $ObservedAt
            if (-not [bool]$norm.ok) {
                $first = 'schema-failed'
                try { if ($null -ne $norm.errors -and @($norm.errors).Count -gt 0) { $first = [string]@($norm.errors)[0] } } catch { }
                return @{ ok = $false; snapshot = $null; transport = 'fixture-declared'; attempts = 1; reason = 'api-failure'; detail = $first }
            }
            return @{ ok = $true; snapshot = $norm.snapshot; transport = 'fixture-declared'; attempts = 1; reason = ''; detail = '' }
        }
        $ghCmd = $null
        try { $ghCmd = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghCmd = $null }
        if (($null -eq $ghCmd) -or [string]::IsNullOrWhiteSpace([string]$ghCmd.Source)) {
            return @{ ok = $false; snapshot = $null; transport = 'gh-query'; attempts = 0; reason = 'gh-not-found'; detail = '' }
        }
        $parts = ([string]$Repository).Trim().Split('/')
        $ghArgs = Get-GHAGhArgs -OwnerPart ([string]$parts[0]).Trim() -NamePart ([string]$parts[1]).Trim() -Number $PrNumber
        $last = 'child-failed'
        $cap = 3
        try { if ([int]$MaxApiAttempts -ge 1 -and [int]$MaxApiAttempts -le 3) { $cap = [int]$MaxApiAttempts } } catch { $cap = 3 }
        for ($attempt = 1; $attempt -le $cap; $attempt++) {
            $child = $null
            try {
                $child = Invoke-GHAChildTransport -FilePath ([string]$ghCmd.Source) -ArgumentList $ghArgs -TimeoutMs $TimeoutMs -OutputCapChars 262144
            }
            catch { $child = $null }
            if (($null -ne $child) -and [bool]$child.Started -and (-not [bool]$child.TimedOut) -and (-not [bool]$child.DrainIncomplete) -and (-not [bool]$child.StdoutTruncated) -and ([int]$child.ExitCode -eq 0)) {
                $raw = $null
                try {
                    if ([string]::IsNullOrWhiteSpace([string]$child.Stdout)) { throw 'empty stdout' }
                    $raw = ConvertFrom-Json ([string]$child.Stdout)
                }
                catch { $raw = $null }
                if ($null -eq $raw) {
                    $last = 'snapshot-unparseable'
                }
                else {
                    $norm = Convert-GHARawToSnapshot -Raw $raw -Repository $repoCanon -PrNumber $PrNumber -ObservedAt $ObservedAt
                    if ([bool]$norm.ok) {
                        return @{ ok = $true; snapshot = $norm.snapshot; transport = 'gh-query'; attempts = [int]$attempt; reason = ''; detail = '' }
                    }
                    $first = 'schema-failed'
                    try { if ($null -ne $norm.errors -and @($norm.errors).Count -gt 0) { $first = [string]@($norm.errors)[0] } } catch { }
                    return @{ ok = $false; snapshot = $null; transport = 'gh-query'; attempts = [int]$attempt; reason = 'api-failure'; detail = $first }
                }
            }
            else {
                $last = 'child-failed'
                try {
                    if (($null -ne $child) -and [bool]$child.TimedOut) { $last = 'child-timeout' }
                    elseif (($null -ne $child) -and ([int]$child.ExitCode -ne 0)) { $last = 'gh-nonzero-exit' }
                }
                catch { }
            }
            if ([int]$attempt -lt [int]$cap) {
                Start-Sleep -Seconds ([int]$attempt)
            }
        }
        return @{ ok = $false; snapshot = $null; transport = 'gh-query'; attempts = $cap; reason = 'api-failure'; detail = $last }
    }
    catch {
        return @{ ok = $false; snapshot = $null; transport = 'unknown'; attempts = 0; reason = 'api-failure'; detail = 'internal-error' }
    }
}

function New-GHWakeItem {
    param([string]$TaskId = '', [string]$DedupKey = '')
    return [ordered]@{
        task_id = ([string]$TaskId); dedup_key = ([string]$DedupKey)
        decision = 'HOLD'; reason = 'internal-error'; readiness = 'UNKNOWN'
        notify = ('HOLD ' + ([string]$TaskId) + ' reason=internal-error')
        confirmed = $false; confirm_reason = ''
        kernel = 'not-attempted'; kernel_error = ''; kernel_mutated = $false
        transport = 'none'; attempts = 0; readiness_probe = 'UNKNOWN'
    }
}

function Invoke-GitHubWake {
    [CmdletBinding()]
    param(
        [string]$WaitsDir = '',
        [string]$TasksDir = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointDir = '',
        [string]$FlagsPath = '',
        $Policy = $null,
        [string]$GraphQLSnapshotFile = '',
        [string]$EventId = '',
        [long]$MaxAgeSeconds = 300,
        [string]$NowUtc = '',
        [string]$ActorIdentitySource = 'explicit-cli',
        [bool]$AuthorizationAlive = $false,
        [bool]$ExecutorPresent = $false,
        [bool]$CancelRequested = $false,
        [int]$MaxApiAttempts = 3,
        [int]$TimeoutMs = 10000
    )
    $items = New-Object System.Collections.ArrayList
    $kernelMutated = $false
    $anyResume = $false
    $nextAction = $null
    try {
        $lw = $null
        try { $lw = Get-OrchestrationGitHubWaits -WaitsDir $WaitsDir } catch { $lw = $null }
        if (($null -eq $lw) -or (-not [bool](Get-GHWValue $lw 'ok' $false))) {
            $why = 'waits-dir-unreadable'
            try {
                $r = ([string](Get-GHWValue $lw 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            return [pscustomobject]@{
                ok = $false; harness = 'github-wake-v1'; verdict = 'WAKE_FAIL'
                reason = $why; items = @(); evaluated = [long]0; resumed = [long]0
                kernel_mutated = $false; grants_authority = $false; done_approved = $false
                merge_authority = $false; resume_authorized = $false
                scheduler = 'schtasks-xml; single-shot per tick; no in-memory state'
                next_action = $null
            }
        }
        $nowObj = Convert-GHWUtc -Value $NowUtc
        if ($null -eq $nowObj) { $nowObj = [datetime]::UtcNow }
        $nowStr = ([datetime]$nowObj).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $waits = @()
        try { $waits = @(Get-GHWValue $lw 'waits' @()) } catch { $waits = @() }
        foreach ($w in @($waits)) {
            $rec = New-GHWakeItem
            try {
                $tid = ([string](Get-GHWValue $w 'task_id' '')).Trim()
                $ddk = ([string](Get-GHWValue $w 'dedup_key' '')).Trim()
                $rec['task_id'] = $tid
                $rec['dedup_key'] = $ddk
                if ([string]::IsNullOrWhiteSpace($tid)) {
                    $rec['reason'] = 'invalid-wait-task'
                    $rec['notify'] = 'HOLD reason=invalid-wait-task'
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $evt = ([string]$EventId).Trim()
                if ([string]::IsNullOrWhiteSpace($evt)) { $evt = ('evt-' + $tid) }
                if (-not (Test-GHWEventId -Value $evt)) {
                    $rec['reason'] = 'invalid-event-id'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=invalid-event-id')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $task = $null
                try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir } catch { $task = $null }
                $taskErr = ''
                try {
                    if ($null -ne $task) {
                        if ($task -is [System.Collections.IDictionary]) {
                            if ($task.Contains('error')) { $taskErr = ([string]$task['error']) }
                        }
                        else {
                            $ep = $task.PSObject.Properties['error']
                            if ($null -ne $ep) { $taskErr = ([string]$ep.Value) }
                        }
                    }
                    else { $taskErr = 'NOT_FOUND' }
                }
                catch { $taskErr = 'INTERNAL_ERROR' }
                if (-not [string]::IsNullOrWhiteSpace($taskErr)) {
                    $rec['reason'] = 'task-unreadable'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=task-unreadable')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $state = ''
                try { $state = ([string]$task['state']).Trim().ToUpperInvariant() } catch { $state = '' }
                if ($state -ceq 'DONE') {
                    $rec['reason'] = 'already-done'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=already-done')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                if (($state -ceq 'EXHAUSTED') -or ($state -ceq 'CANCELLED')) {
                    $rec['reason'] = 'kernel-terminal'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=kernel-terminal')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $applied = @()
                try {
                    $rawApplied = Get-GHWValue $w 'applied_events' $null
                    if ($null -ne $rawApplied) { $applied = @($rawApplied) }
                }
                catch { $applied = @() }
                $already = $false
                foreach ($seen in @($applied)) {
                    if ([string]$seen -ceq $evt) { $already = $true; break }
                }
                if ([bool]$already) {
                    $dec = $null
                    try {
                        $dec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $null -Policy $Policy `
                            -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds -LeaseAlive $true `
                            -OwnerAlive $true -AuthorizationAlive $true `
                            -ExecutorPresent $false -CancelRequested $false `
                            -AlreadyApplied $true -EventDedupKey ''
                    }
                    catch { $dec = $null }
                    $dName = 'DUPLICATE_NOOP'
                    $dReason = 'duplicate-suppressed'
                    $dRdy = 'UNKNOWN'
                    $dNotify = ('DUPLICATE_NOOP ' + $tid + ' reason=duplicate-suppressed')
                    try {
                        if ($null -ne $dec) {
                            $dName = ([string](Get-GHWValue $dec 'decision' 'DUPLICATE_NOOP')).Trim().ToUpperInvariant()
                            $dReason = ([string](Get-GHWValue $dec 'reason' 'duplicate-suppressed'))
                            $dRdy = ([string](Get-GHWValue $dec 'readiness' 'UNKNOWN'))
                            $dNotify = ([string](Get-GHWValue $dec 'notify' $dNotify))
                        }
                    }
                    catch { }
                    # Liveness recovery: the event is already confirmed but
                    # the task never left BLOCKED (a prior tick ran Confirm
                    # CAS, then the unblock failed). Without this, every
                    # later tick returns DUPLICATE_NOOP forever and the task
                    # stays BLOCKED. Revalidate fully (binding, checkpoint,
                    # fresh observe + RESUME) and unblock exactly once.
                    $recovered = $false
                    if ($state -ceq 'BLOCKED') {
                        $recBind = $null
                        try { $recBind = Test-GRRWaitKernelBinding -Wait $w -TasksDir $TasksDir } catch { $recBind = $null }
                        if (($null -ne $recBind) -and [bool](Get-GHWValue $recBind 'ok' $false)) {
                            $recCkptDir = ([string]$CheckpointDir).Trim()
                            if ([string]::IsNullOrWhiteSpace($recCkptDir)) {
                                try { $recCkptDir = Get-OrchestrationGoalCheckpointStoreDir -StoreDir '' } catch { $recCkptDir = '' }
                            }
                            $recObj = ([string](Get-GHWValue $w 'objective_id' '')).Trim()
                            $recFound = Find-GHWNewestCheckpoint -CheckpointDir $recCkptDir -GoalId $recObj
                            if ([bool](Get-GHWValue $recFound 'ok' $false)) {
                                $recCid = ([string](Get-GHWValue $recFound 'checkpoint_id' ''))
                                $recLoad = $null
                                try { $recLoad = Load-OrchestrationGoalCheckpoint -CheckpointId $recCid -StoreDir $recCkptDir } catch { $recLoad = $null }
                                $recResume = $null
                                try { $recResume = Test-OrchestrationCheckpointResume -Checkpoint (Get-GHWValue $recLoad 'checkpoint' $null) -GoalStoreDir $GoalStoreDir } catch { $recResume = $null }
                                if (($null -ne $recResume) -and [bool](Get-GHWValue $recResume 'resumable' $false)) {
                                    $recLease = $true
                                    try {
                                        $recLeaseExp = Convert-GHWUtc -Value (Get-GHWValue $w 'lease_expires_utc' $null)
                                        if (($null -ne $recLeaseExp) -and ($nowObj -gt $recLeaseExp)) { $recLease = $false }
                                    }
                                    catch { $recLease = $true }
                                    $recRepo = ([string](Get-GHWValue $w 'repository' '')).Trim().ToLowerInvariant()
                                    $recPr = [long]0
                                    try { $recPr = [long](Get-GHWValue $w 'pr_number' 0) } catch { $recPr = 0 }
                                    $recSha = ([string](Get-GHWValue $w 'expected_head_sha' '')).Trim().ToLowerInvariant()
                                    $recFx = ([string]$GraphQLSnapshotFile).Trim()
                                    $recObs = Invoke-GHWObserve -Repository $recRepo -PrNumber $recPr -ExpectedHeadSha $recSha -ObservedAt $nowStr -GraphQLSnapshotFile $recFx -TimeoutMs $TimeoutMs -MaxApiAttempts $MaxApiAttempts
                                    if ([bool](Get-GHWValue $recObs 'ok' $false)) {
                                        $recSnap = Get-GHWValue $recObs 'snapshot' $null
                                        $recDec = $null
                                        try {
                                            $recDec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $recSnap -Policy $Policy `
                                                -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds -LeaseAlive $recLease `
                                                -OwnerAlive $true -AuthorizationAlive ([bool]$AuthorizationAlive) `
                                                -ExecutorPresent ([bool]$ExecutorPresent) -CancelRequested ([bool]$CancelRequested) `
                                                -AlreadyApplied $false -EventDedupKey $ddk
                                        }
                                        catch { $recDec = $null }
                                        $recName = ''
                                        try { $recName = ([string](Get-GHWValue $recDec 'decision' '')).Trim().ToUpperInvariant() } catch { $recName = '' }
                                        if ($recName -ceq 'RESUME') {
                                            $recActor = ([string](Get-GHWValue $w 'owner' '')).Trim()
                                            if ([string]::IsNullOrWhiteSpace($recActor)) { $recActor = ([string](Get-GHWValue $w 'lease_owner' '')).Trim() }
                                            if ([string]::IsNullOrWhiteSpace($recActor)) { $recActor = 'planner' }
                                            $recFp = ([string](Get-GHWValue $recBind 'fingerprint' ''))
                                            $recRev = 0
                                            try { $recRev = [int](Get-GHWValue $recBind 'revision' 0) } catch { $recRev = 0 }
                                            $recTr = $null
                                            try {
                                                $recTr = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'IMPLEMENTING' `
                                                    -Actor $recActor -ExpectedRevision $recRev -WaitFingerprint $recFp `
                                                    -ActorIdentitySource ([string]$ActorIdentitySource) -TasksDir $TasksDir `
                                                    -FlagsPath $FlagsPath -TelemetryRoot ''
                                            }
                                            catch { $recTr = $null }
                                            if (($null -ne $recTr) -and [bool](Get-GHWValue $recTr 'ok' $false)) {
                                                $kernelMutated = $true
                                                $anyResume = $true
                                                $rec['decision'] = 'RESUME'
                                                $rec['reason'] = 'reconciled-pending-unblock'
                                                $rec['readiness'] = ([string](Get-GHWValue $recDec 'readiness' 'UNKNOWN'))
                                                $rec['notify'] = ('RESUME ' + $tid + ' reason=reconciled-pending-unblock')
                                                $rec['transport'] = ([string](Get-GHWValue $recObs 'transport' ''))
                                                $rec['attempts'] = [long](Get-GHWValue $recObs 'attempts' 0)
                                                $rec['confirmed'] = $true
                                                $rec['confirm_reason'] = 'duplicate-suppressed'
                                                $rec['kernel'] = 'unblocked'
                                                $rec['kernel_mutated'] = $true
                                                $nextAction = [pscustomobject]@{
                                                    task_id = $tid; checkpoint_id = $recCid
                                                    goal_id = $recObj; wait_dedup_key = $ddk
                                                    kernel_state = 'IMPLEMENTING'
                                                    announce = ('next-action task=' + $tid + ' checkpoint=' + $recCid)
                                                }
                                                [void]$items.Add([pscustomobject]$rec)
                                                $recovered = $true
                                            }
                                            else {
                                                $recErr = 'transition-failed'
                                                try {
                                                    $recRaw = ([string](Get-GHWValue $recTr 'error' ''))
                                                    if (-not [string]::IsNullOrWhiteSpace($recRaw)) { $recErr = $recRaw }
                                                }
                                                catch { }
                                                $rec['decision'] = 'HOLD'
                                                $rec['reason'] = ('unblock-refused:' + $recErr)
                                                $rec['notify'] = ('HOLD ' + $tid + ' reason=unblock-refused:' + $recErr)
                                                $rec['readiness'] = ([string](Get-GHWValue $recDec 'readiness' 'UNKNOWN'))
                                                $rec['confirmed'] = $true
                                                $rec['confirm_reason'] = 'duplicate-suppressed'
                                                $rec['kernel'] = 'unblock-failed'
                                                $rec['kernel_error'] = $recErr
                                                [void]$items.Add([pscustomobject]$rec)
                                                $recovered = $true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if ([bool]$recovered) { continue }
                    $rec['decision'] = $dName
                    $rec['reason'] = $dReason
                    $rec['readiness'] = $dRdy
                    $rec['notify'] = $dNotify
                    $rec['confirmed'] = $true
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $ckptDir = ([string]$CheckpointDir).Trim()
                if ([string]::IsNullOrWhiteSpace($ckptDir)) {
                    try { $ckptDir = Get-OrchestrationGoalCheckpointStoreDir -StoreDir '' } catch { $ckptDir = '' }
                }
                $objectiveId = ([string](Get-GHWValue $w 'objective_id' '')).Trim()
                $found = Find-GHWNewestCheckpoint -CheckpointDir $ckptDir -GoalId $objectiveId
                if (-not [bool]$found.ok) {
                    $rec['reason'] = ([string]$found.reason)
                    if ([string]::IsNullOrWhiteSpace([string]$rec['reason'])) { $rec['reason'] = 'checkpoint-missing' }
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=' + ([string]$rec['reason']))
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $cid = ([string]$found.checkpoint_id)
                $load = $null
                try { $load = Load-OrchestrationGoalCheckpoint -CheckpointId $cid -StoreDir $ckptDir } catch { $load = $null }
                if (($null -eq $load) -or (-not [bool](Get-GHWValue $load 'ok' $false))) {
                    $rec['reason'] = 'checkpoint-missing'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=checkpoint-missing')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $resume = $null
                try { $resume = Test-OrchestrationCheckpointResume -Checkpoint (Get-GHWValue $load 'checkpoint' $null) -GoalStoreDir $GoalStoreDir } catch { $resume = $null }
                if (($null -eq $resume) -or (-not [bool](Get-GHWValue $resume 'resumable' $false))) {
                    $why = 'resume-not-resumable'
                    try {
                        $rs = @(Get-GHWValue $resume 'reasons' @())
                        if (@($rs).Count -gt 0) { $why = ('checkpoint-not-resumable:' + ((@($rs) | Select-Object -First 2) -join ',')) }
                    }
                    catch { $why = 'checkpoint-not-resumable' }
                    if ($why -ceq 'resume-not-resumable') { $why = 'checkpoint-not-resumable' }
                    $rec['reason'] = $why
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=' + $why)
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $bind = $null
                try { $bind = Test-GRRWaitKernelBinding -Wait $w -TasksDir $TasksDir } catch { $bind = $null }
                $reconcileOnly = $false
                if (($null -eq $bind) -or (-not [bool](Get-GHWValue $bind 'ok' $false))) {
                    $why = 'wait-binding-mismatch'
                    try {
                        $b = ([string](Get-GHWValue $bind 'reason' ''))
                        if (-not [string]::IsNullOrWhiteSpace($b)) { $why = $b }
                    }
                    catch { }
                    if ($why -ceq 'kernel-not-blocked') {
                        $taskStateProbe = ''
                        try { $taskStateProbe = ([string]$task['state']).Trim().ToUpperInvariant() } catch { $taskStateProbe = '' }
                        if ($taskStateProbe -ceq 'IMPLEMENTING') {
                            $reconcileOnly = $true
                        }
                        else {
                            $rec['reason'] = 'kernel-not-blocked'
                            $rec['notify'] = ('HOLD ' + $tid + ' reason=' + ([string]$rec['reason']))
                            [void]$items.Add([pscustomobject]$rec)
                            continue
                        }
                    }
                    else {
                        $rec['reason'] = $why
                        $rec['notify'] = ('HOLD ' + $tid + ' reason=' + ([string]$rec['reason']))
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                }
                $leaseAlive = $true
                try {
                    $leaseExp = Convert-GHWUtc -Value (Get-GHWValue $w 'lease_expires_utc' $null)
                    if (($null -ne $leaseExp) -and ($nowObj -gt $leaseExp)) { $leaseAlive = $false }
                }
                catch { $leaseAlive = $true }
                $repo = ([string](Get-GHWValue $w 'repository' '')).Trim().ToLowerInvariant()
                $prNum = [long]0
                try { $prNum = [long](Get-GHWValue $w 'pr_number' 0) } catch { $prNum = 0 }
                $expSha = ([string](Get-GHWValue $w 'expected_head_sha' '')).Trim().ToLowerInvariant()
                $fxArg = ([string]$GraphQLSnapshotFile).Trim()
                $obs = Invoke-GHWObserve -Repository $repo -PrNumber $prNum -ExpectedHeadSha $expSha -ObservedAt $nowStr -GraphQLSnapshotFile $fxArg -TimeoutMs $TimeoutMs -MaxApiAttempts $MaxApiAttempts
                $rec['transport'] = ([string]$obs.transport)
                $rec['attempts'] = [long]$obs.attempts
                if (-not [bool]$obs.ok) {
                    $detail = ([string]$obs.detail).Trim()
                    $why = 'api-failure'
                    if (-not [string]::IsNullOrWhiteSpace($detail)) { $why = ('api-failure:' + $detail) }
                    if ([string]$obs.reason -cne 'api-failure') { $why = ([string]$obs.reason) }
                    if ([string]::IsNullOrWhiteSpace($why)) { $why = 'api-failure' }
                    if ($why -cmatch '^api-failure') { $why = 'api-failure' }
                    $rec['reason'] = $why
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=' + $why)
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $snap = $obs.snapshot
                $probe = $null
                try {
                    $probe = Get-OrchestrationGitHubReadiness -Repository $repo -PrNumber $prNum -ExpectedHeadSha $expSha -Snapshot $snap -Policy $Policy -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds
                }
                catch { $probe = $null }
                if ($null -eq $probe) {
                    $rec['reason'] = 'readiness-unavailable'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=readiness-unavailable')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                try { $rec['readiness_probe'] = ([string](Get-GHWValue $probe 'readiness' 'UNKNOWN')) } catch { }
                $dec = $null
                try {
                    $dec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $snap -Policy $Policy `
                        -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds -LeaseAlive $leaseAlive `
                        -OwnerAlive $true -AuthorizationAlive ([bool]$AuthorizationAlive) `
                        -ExecutorPresent ([bool]$ExecutorPresent) -CancelRequested ([bool]$CancelRequested) `
                        -AlreadyApplied $false -EventDedupKey $ddk
                }
                catch { $dec = $null }
                if ($null -eq $dec) {
                    $rec['reason'] = 'decision-failed'
                    $rec['notify'] = ('HOLD ' + $tid + ' reason=decision-failed')
                    [void]$items.Add([pscustomobject]$rec)
                    continue
                }
                $dName = ([string](Get-GHWValue $dec 'decision' 'INVALID')).Trim().ToUpperInvariant()
                $dReason = ([string](Get-GHWValue $dec 'reason' 'internal-error'))
                $dRdy = ([string](Get-GHWValue $dec 'readiness' 'UNKNOWN'))
                $dNotify = ([string](Get-GHWValue $dec 'notify' ''))
                $rec['decision'] = $dName
                $rec['reason'] = $dReason
                $rec['readiness'] = $dRdy
                $rec['notify'] = $dNotify
                if ($dName -ceq 'RESUME') {
                    if ([bool]$reconcileOnly) {
                        $cf = $null
                        try {
                            $cf = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $WaitsDir -DedupKey $ddk -EventId $evt
                        }
                        catch { $cf = $null }
                        if (($null -ne $cf) -and [bool](Get-GHWValue $cf 'ok' $false)) {
                            $rec['confirmed'] = $true
                            $rec['confirm_reason'] = ([string](Get-GHWValue $cf 'reason' ''))
                        }
                        else {
                            $cfReason = 'confirm-failed'
                            try {
                                $cr = ([string](Get-GHWValue $cf 'reason' ''))
                                if (-not [string]::IsNullOrWhiteSpace($cr)) { $cfReason = $cr }
                            }
                            catch { }
                            $rec['confirmed'] = $false
                            $rec['confirm_reason'] = $cfReason
                            $rec['decision'] = 'HOLD'
                            $rec['reason'] = ('confirm-failed:' + $cfReason)
                            $rec['notify'] = ('HOLD ' + $tid + ' reason=confirm-failed:' + $cfReason)
                            $rec['kernel'] = 'not-attempted'
                            [void]$items.Add([pscustomobject]$rec)
                            continue
                        }
                        $anyResume = $true
                        $rec['kernel'] = 'reconciled'
                        $rec['kernel_mutated'] = $false
                        $rec['reason'] = 'reconciled-pending-confirm'
                        $rec['notify'] = ('RESUME ' + $tid + ' reason=reconciled-pending-confirm')
                        $nextAction = [pscustomobject]@{
                            task_id = $tid; checkpoint_id = $cid
                            goal_id = $objectiveId; wait_dedup_key = $ddk
                            kernel_state = 'IMPLEMENTING'
                            announce = ('next-action task=' + $tid + ' checkpoint=' + $cid)
                        }
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $cf = $null
                    try {
                        $cf = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $WaitsDir -DedupKey $ddk -EventId $evt
                    }
                    catch { $cf = $null }
                    if (($null -eq $cf) -or (-not [bool](Get-GHWValue $cf 'ok' $false))) {
                        $cfReason = 'confirm-failed'
                        try {
                            $cr = ([string](Get-GHWValue $cf 'reason' ''))
                            if (-not [string]::IsNullOrWhiteSpace($cr)) { $cfReason = $cr }
                        }
                        catch { }
                        $rec['decision'] = 'HOLD'
                        $rec['reason'] = ('confirm-failed:' + $cfReason)
                        $rec['notify'] = ('HOLD ' + $tid + ' reason=confirm-failed:' + $cfReason)
                        $rec['kernel'] = 'not-attempted'
                        $rec['confirmed'] = $false
                        $rec['confirm_reason'] = $cfReason
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $rec['confirmed'] = $true
                    $rec['confirm_reason'] = ([string](Get-GHWValue $cf 'reason' ''))
                    $actor = ([string](Get-GHWValue $w 'owner' '')).Trim()
                    if ([string]::IsNullOrWhiteSpace($actor)) { $actor = ([string](Get-GHWValue $w 'lease_owner' '')).Trim() }
                    if ([string]::IsNullOrWhiteSpace($actor)) { $actor = 'planner' }
                    $fp = ([string](Get-GHWValue $bind 'fingerprint' ''))
                    $taskRev = 0
                    try { $taskRev = [int](Get-GHWValue $bind 'revision' 0) } catch { $taskRev = 0 }
                    $tr = $null
                    try {
                        $tr = Invoke-OrchestrationTaskTransition -TaskId $tid -ToState 'IMPLEMENTING' `
                            -Actor $actor -ExpectedRevision $taskRev -WaitFingerprint $fp `
                            -ActorIdentitySource ([string]$ActorIdentitySource) -TasksDir $TasksDir `
                            -FlagsPath $FlagsPath -TelemetryRoot ''
                    }
                    catch { $tr = $null }
                    if (($null -eq $tr) -or (-not [bool](Get-GHWValue $tr 'ok' $false))) {
                        $e2 = 'transition-failed'
                        try {
                            $eRaw = ([string](Get-GHWValue $tr 'error' ''))
                            if (-not [string]::IsNullOrWhiteSpace($eRaw)) { $e2 = $eRaw }
                        }
                        catch { }
                        $rec['decision'] = 'HOLD'
                        $rec['reason'] = ('unblock-refused:' + $e2)
                        $rec['notify'] = ('HOLD ' + $tid + ' reason=unblock-refused:' + $e2)
                        $rec['kernel'] = 'unblock-failed'
                        $rec['kernel_error'] = $e2
                        [void]$items.Add([pscustomobject]$rec)
                        continue
                    }
                    $kernelMutated = $true
                    $anyResume = $true
                    $rec['kernel'] = 'unblocked'
                    $rec['kernel_mutated'] = $true
                    $nextAction = [pscustomobject]@{
                        task_id = $tid; checkpoint_id = $cid
                        goal_id = $objectiveId; wait_dedup_key = $ddk
                        kernel_state = 'IMPLEMENTING'
                        announce = ('next-action task=' + $tid + ' checkpoint=' + $cid)
                    }
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
            ok = $false; harness = 'github-wake-v1'; verdict = 'WAKE_FAIL'
            reason = 'internal-error'; items = @($items.ToArray()); evaluated = [long]@($items.ToArray()).Count; resumed = [long]0
            kernel_mutated = $kernelMutated; grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $anyResume
            scheduler = 'schtasks-xml; single-shot per tick; no in-memory state'
            next_action = $nextAction
        }
    }
    $resumed = [long]0
    try {
        foreach ($it in @($items.ToArray())) {
            if ([string](Get-GHWValue $it 'decision' '') -ceq 'RESUME') { $resumed++ }
        }
    }
    catch { $resumed = 0 }
    return [pscustomobject]@{
        ok = $true; harness = 'github-wake-v1'; verdict = 'WAKE_PASS'
        reason = ''; items = @($items.ToArray()); evaluated = [long]@($items.ToArray()).Count; resumed = $resumed
        kernel_mutated = [bool]$kernelMutated; grants_authority = $false; done_approved = $false
        merge_authority = $false; resume_authorized = [bool]$anyResume
        scheduler = 'schtasks-xml; single-shot per tick; no in-memory state'
        next_action = $nextAction
    }
}

function Convert-GHWXmlEscape {
    param([string]$Text = '')
    try {
        $s = [string]$Text
        $s = $s.Replace('&', '&amp;')
        $s = $s.Replace('<', '&lt;')
        $s = $s.Replace('>', '&gt;')
        $s = $s.Replace('"', '&quot;')
        $s = $s.Replace("'", '&apos;')
        return $s
    }
    catch { return '' }
}

function New-GitHubWakeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WaitsDir = '',
        [string]$TasksDir = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointDir = '',
        [string]$FlagsPath = '',
        [string]$PolicyPath = '',
        [string]$GraphQLSnapshotFile = '',
        [string]$EventId = '',
        $MaxAgeSeconds = 300,
        [string]$NowUtc = '',
        [string]$ActorIdentitySource = 'explicit-cli',
        [bool]$AuthorizationAlive = $false,
        [bool]$ExecutorPresent = $false,
        [bool]$CancelRequested = $false,
        $MaxApiAttempts = 3,
        $TimeoutMs = 10000,
        [string]$OutFile = ''
    )
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-path'; path = '' }
        }
        $maxAge = 300
        try { if (Test-GHWStrictInt -Value $MaxAgeSeconds -Min 1 -Max 3600) { $maxAge = [long]$MaxAgeSeconds } } catch { }
        $maxApi = 3
        try { if (Test-GHWStrictInt -Value $MaxApiAttempts -Min 1 -Max 3) { $maxApi = [int]$MaxApiAttempts } } catch { }
        $toMs = 10000
        try { if (Test-GHWStrictInt -Value $TimeoutMs -Min 1 -Max 10000) { $toMs = [int]$TimeoutMs } } catch { }
        $doc = [ordered]@{
            waits_dir = ([string]$WaitsDir); tasks_dir = ([string]$TasksDir)
            goal_store_dir = ([string]$GoalStoreDir); checkpoint_dir = ([string]$CheckpointDir)
            flags_path = ([string]$FlagsPath); policy_path = ([string]$PolicyPath)
            graphql_snapshot_file = ([string]$GraphQLSnapshotFile); event_id = ([string]$EventId)
            max_age_seconds = $maxAge; now_utc = ([string]$NowUtc)
            actor_identity_source = ([string]$ActorIdentitySource)
            authorization_alive = $false; executor_present = $false
            cancel_requested = $false; max_api_attempts = $maxApi
            timeout_ms = $toMs; out_file = ([string]$OutFile)
        }
        # Fail-closed: per-run authorization flags are NEVER persisted as
        # authority. Even when callers pass true, the config stores false;
        # live CLI switches must supply the current values each execution.
        $json = ConvertTo-Json -InputObject $doc -Depth 4 -Compress
        $dir = [IO.Path]::GetDirectoryName($p)
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            try {
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($dir) }
            }
            catch { return [pscustomobject]@{ ok = $false; reason = 'config-dir-unavailable'; path = '' } }
        }
        try { [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false)) }
        catch { return [pscustomobject]@{ ok = $false; reason = 'config-persist-failed'; path = '' } }
        return [pscustomobject]@{ ok = $true; reason = ''; path = $p }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'internal-error'; path = '' } }
}

function Get-GHWSchtasksXml {
    param(
        [string]$TaskName = '',
        [string]$WakeScript = '',
        [string]$ConfigFile = '',
        [int]$IntervalMinutes = 5,
        [int]$DurationHours = 12,
        [int]$ExecutionTimeLimitMinutes = 5
    )
    try {
        $psExe = (Join-Path ([string]$env:windir) 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $start = ([datetime]::UtcNow.AddMinutes(2)).ToString('yyyy-MM-ddTHH:mm:ss')
        $args = ('-NoProfile -ExecutionPolicy Bypass -File "' + ([string]$WakeScript) + '" -ConfigFile "' + ([string]$ConfigFile) + '"')
        $xml = ('<?xml version="1.0" encoding="UTF-16"?>' + "`r`n")
        $xml += ('<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">' + "`r`n")
        $xml += ('  <RegistrationInfo>' + "`r`n")
        $xml += ('    <URI>\' + (Convert-GHWXmlEscape -Text ([string]$TaskName)) + '</URI>' + "`r`n")
        $xml += ('    <Author>orchestration-wake</Author>' + "`r`n")
        $xml += ('    <Description>Etapa 6D GH-WAKE single-shot: ' + (Convert-GHWXmlEscape -Text ([string]$ConfigFile)) + '</Description>' + "`r`n")
        $xml += ('  </RegistrationInfo>' + "`r`n")
        $xml += ('  <Triggers>' + "`r`n")
        $xml += ('    <TimeTrigger>' + "`r`n")
        $xml += ('      <StartBoundary>' + $start + '</StartBoundary>' + "`r`n")
        $xml += ('      <Enabled>true</Enabled>' + "`r`n")
        $xml += ('      <Repetition>' + "`r`n")
        $xml += ('        <Interval>PT' + [string]$IntervalMinutes + 'M</Interval>' + "`r`n")
        $xml += ('        <Duration>PT' + [string]$DurationHours + 'H</Duration>' + "`r`n")
        $xml += ('        <StopAtDurationEnd>true</StopAtDurationEnd>' + "`r`n")
        $xml += ('      </Repetition>' + "`r`n")
        $xml += ('    </TimeTrigger>' + "`r`n")
        $xml += ('  </Triggers>' + "`r`n")
        $xml += ('  <Principals>' + "`r`n")
        $xml += ('    <Principal id="Author">' + "`r`n")
        $xml += ('      <LogonType>InteractiveToken</LogonType>' + "`r`n")
        $xml += ('      <RunLevel>LeastPrivilege</RunLevel>' + "`r`n")
        $xml += ('    </Principal>' + "`r`n")
        $xml += ('  </Principals>' + "`r`n")
        $xml += ('  <Settings>' + "`r`n")
        $xml += ('    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>' + "`r`n")
        $xml += ('    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>' + "`r`n")
        $xml += ('    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>' + "`r`n")
        $xml += ('    <AllowStartIfOnBatteries>true</AllowStartIfOnBatteries>' + "`r`n")
        $xml += ('    <StartWhenAvailable>true</StartWhenAvailable>' + "`r`n")
        $xml += ('    <AllowStartOnDemand>true</AllowStartOnDemand>' + "`r`n")
        $xml += ('    <Enabled>true</Enabled>' + "`r`n")
        $xml += ('    <ExecutionTimeLimit>PT' + [string]$ExecutionTimeLimitMinutes + 'M</ExecutionTimeLimit>' + "`r`n")
        $xml += ('  </Settings>' + "`r`n")
        $xml += ('  <Actions Context="Author">' + "`r`n")
        $xml += ('    <Exec>' + "`r`n")
        $xml += ('      <Command>' + (Convert-GHWXmlEscape -Text $psExe) + '</Command>' + "`r`n")
        $xml += ('      <Arguments>' + (Convert-GHWXmlEscape -Text $args) + '</Arguments>' + "`r`n")
        $xml += ('    </Exec>' + "`r`n")
        $xml += ('  </Actions>' + "`r`n")
        $xml += ('</Task>')
        return $xml
    }
    catch { return '' }
}

function Test-GHWScheduleOwner {
    param([string]$ExistingXml = '', [string]$WakeScript = '', [string]$ConfigFile = '')
    try {
        $x = [string]$ExistingXml
        $w = ([string]$WakeScript).Trim()
        $c = ([string]$ConfigFile).Trim()
        if ([string]::IsNullOrWhiteSpace($x) -or [string]::IsNullOrWhiteSpace($w) -or [string]::IsNullOrWhiteSpace($c)) { return $false }
        $doc = $null
        try { $doc = [xml]$x } catch { return $false }
        if ($null -eq $doc) { return $false }
        $execs = @()
        try { $execs = @($doc.GetElementsByTagName('Exec')) } catch { return $false }
        if (@($execs).Count -ne 1) { return $false }
        $cmdText = ''
        $argText = ''
        try {
            $first = @($execs)[0]
            foreach ($ch in @($first.ChildNodes)) {
                $nm = ''
                try { $nm = [string]$ch.LocalName } catch { $nm = '' }
                if ([string]::IsNullOrWhiteSpace($nm)) { try { $nm = [string]$ch.Name } catch { $nm = '' } }
                if ($nm -ceq 'Command') { $cmdText = ([string]$ch.InnerText) }
                elseif ($nm -ceq 'Arguments') { $argText = ([string]$ch.InnerText) }
            }
        }
        catch { return $false }
        $cmdNorm = ([string]$cmdText).Trim()
        for ($qi = 0; $qi -lt 4; $qi++) {
            if (($cmdNorm.Length -ge 2) -and ((($cmdNorm.StartsWith('"')) -and ($cmdNorm.EndsWith('"'))) -or (($cmdNorm.StartsWith("'") -and ($cmdNorm.EndsWith("'")))))) { $cmdNorm = ($cmdNorm.Substring(1, $cmdNorm.Length - 2)).Trim() } else { break }
        }
        if ([string]::IsNullOrWhiteSpace($cmdNorm)) { return $false }
        $leaf = ''
        try { $leaf = [string][IO.Path]::GetFileName($cmdNorm) } catch { $leaf = '' }
        if (-not ([string]$leaf -ieq 'powershell.exe')) { return $false }
        $expected = ''
        try { $expected = (Join-Path ([string]$env:windir) 'System32\WindowsPowerShell\v1.0\powershell.exe') } catch { $expected = '' }
        $cmdOk = $false
        try {
            if ($cmdNorm -ieq 'powershell.exe') { $cmdOk = $true }
            elseif ((-not [string]::IsNullOrWhiteSpace($expected)) -and ($cmdNorm -ieq $expected)) { $cmdOk = $true }
            elseif (($cmdNorm -ilike '*\powershell.exe') -or ($cmdNorm -ilike '*/powershell.exe')) { $cmdOk = $true }
        }
        catch { $cmdOk = $false }
        if (-not [bool]$cmdOk) { return $false }
        $a = ([string]$argText)
        if ([string]::IsNullOrWhiteSpace($a)) { return $false }
        $wNorm = ([string]$w).Trim()
        for ($qi = 0; $qi -lt 4; $qi++) {
            if (($wNorm.Length -ge 2) -and ((($wNorm.StartsWith('"')) -and ($wNorm.EndsWith('"'))) -or (($wNorm.StartsWith("'") -and ($wNorm.EndsWith("'")))))) { $wNorm = ($wNorm.Substring(1, $wNorm.Length - 2)).Trim() } else { break }
        }
        $wNorm = $wNorm.ToLowerInvariant().Replace('/', '\')
        $cNorm = ([string]$c).Trim()
        for ($qi = 0; $qi -lt 4; $qi++) {
            if (($cNorm.Length -ge 2) -and ((($cNorm.StartsWith('"')) -and ($cNorm.EndsWith('"'))) -or (($cNorm.StartsWith("'") -and ($cNorm.EndsWith("'")))))) { $cNorm = ($cNorm.Substring(1, $cNorm.Length - 2)).Trim() } else { break }
        }
        $cNorm = $cNorm.ToLowerInvariant().Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($wNorm) -or [string]::IsNullOrWhiteSpace($cNorm)) { return $false }
        $tokens = @()
        $cur = ''
        $inQ = $false
        for ($ti = 0; $ti -lt $a.Length; $ti++) {
            $tch = [string]$a[$ti]
            if ($tch -ceq '"') { $inQ = -not $inQ }
            elseif (([string]::IsNullOrWhiteSpace($tch)) -and (-not $inQ)) {
                if ($cur.Length -gt 0) { $tokens += $cur; $cur = '' }
            }
            else { $cur += $tch }
        }
        if ($cur.Length -gt 0) { $tokens += $cur }
        $toks = @($tokens)
        $fileCount = 0
        $fileVal = ''
        $cfgCount = 0
        $cfgVal = ''
        for ($ti = 0; $ti -lt @($toks).Count; $ti++) {
            $tn = [string]@($toks)[$ti]
            if ($tn -ieq '-File') {
                $fileCount += 1
                if (($fileCount -eq 1) -and (($ti + 1) -lt @($toks).Count)) {
                    $v = ([string]@($toks)[$ti + 1]).Trim()
                    for ($qi = 0; $qi -lt 4; $qi++) {
                        if (($v.Length -ge 2) -and ((($v.StartsWith('"')) -and ($v.EndsWith('"'))) -or (($v.StartsWith("'") -and ($v.EndsWith("'")))))) { $v = ($v.Substring(1, $v.Length - 2)).Trim() } else { break }
                    }
                    $fileVal = $v.ToLowerInvariant().Replace('/', '\')
                }
            }
            elseif (($tn -ieq '-ConfigFile') -or ($tn -ieq '-Config')) {
                $cfgCount += 1
                if (($cfgCount -eq 1) -and (($ti + 1) -lt @($toks).Count)) {
                    $v = ([string]@($toks)[$ti + 1]).Trim()
                    for ($qi = 0; $qi -lt 4; $qi++) {
                        if (($v.Length -ge 2) -and ((($v.StartsWith('"')) -and ($v.EndsWith('"'))) -or (($v.StartsWith("'") -and ($v.EndsWith("'")))))) { $v = ($v.Substring(1, $v.Length - 2)).Trim() } else { break }
                    }
                    $cfgVal = $v.ToLowerInvariant().Replace('/', '\')
                }
            }
        }
        if ($fileCount -ne 1) { return $false }
        if ($cfgCount -ne 1) { return $false }
        if ($fileVal -cne $wNorm) { return $false }
        if ($cfgVal -cne $cNorm) { return $false }
        return $true
    }
    catch { return $false }
}

function Register-GitHubWakeSchedule {
    [CmdletBinding()]
    param(
        [string]$TaskName = '',
        [string]$WakeScript = '',
        [string]$ConfigFile = '',
        [int]$IntervalMinutes = 5,
        [int]$DurationHours = 12,
        [int]$ExecutionTimeLimitMinutes = 5,
        [switch]$Force,
        [switch]$DryRun
    )
    try {
        $name = ([string]$TaskName).Trim()
        if (-not (Test-GHWTaskName -Value $name)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-name'; reused = $false; task_name = ''; xml_path = ''; command = '' }
        }
        if (($IntervalMinutes -lt 1) -or ($IntervalMinutes -gt 1440)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-interval'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        if (($DurationHours -lt 1) -or ($DurationHours -gt 24)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-duration'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        if (($ExecutionTimeLimitMinutes -lt 1) -or ($ExecutionTimeLimitMinutes -gt 60)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-time-limit'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        $wake = ([string]$WakeScript).Trim()
        $cfg = ([string]$ConfigFile).Trim()
        if ([string]::IsNullOrWhiteSpace($wake) -or (-not (Test-Path -LiteralPath $wake -PathType Leaf))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-wake-script'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        if ([string]::IsNullOrWhiteSpace($cfg) -or (-not (Test-Path -LiteralPath $cfg -PathType Leaf))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-config-file'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        $xml = Get-GHWSchtasksXml -TaskName $name -WakeScript $wake -ConfigFile $cfg -IntervalMinutes $IntervalMinutes -DurationHours $DurationHours -ExecutionTimeLimitMinutes $ExecutionTimeLimitMinutes
        if ([string]::IsNullOrWhiteSpace($xml)) {
            return [pscustomobject]@{ ok = $false; reason = 'xml-failed'; reused = $false; task_name = $name; xml_path = ''; command = '' }
        }
        $xmlPath = Join-Path ([IO.Path]::GetTempPath()) ($name + '.wake-schtasks.xml')
        $createCmd = ('schtasks /Create /TN "' + $name + '" /XML "' + $xmlPath + '"')
        if ([bool]$DryRun) {
            return [pscustomobject]@{ ok = $true; reason = 'dry-run'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd; xml = $xml }
        }
        try { [IO.File]::WriteAllText($xmlPath, $xml, ([Text.Encoding]::Unicode)) } catch { }
        if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'xml-persist-failed'; reused = $false; task_name = $name; xml_path = ''; command = $createCmd }
        }
        $queryOut = ''
        try { $queryOut = (& schtasks.exe /Query /TN $name 2>&1 | Out-String) } catch { $queryOut = '' }
        $exists = ($LASTEXITCODE -eq 0)
        if ([bool]$exists) {
            $existingXml = ''
            try { $existingXml = (& schtasks.exe /Query /TN $name /XML 2>&1 | Out-String) } catch { $existingXml = '' }
            $owned = Test-GHWScheduleOwner -ExistingXml ([string]$existingXml) -WakeScript $wake -ConfigFile $cfg
            if (-not [bool]$owned) {
                if (-not [bool]$Force) {
                    return [pscustomobject]@{ ok = $false; reason = 'task-name-conflict'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd; xml = $xml }
                }
                try { & schtasks.exe /Delete /TN $name /F 2>&1 | Out-Null } catch { }
                $createOut = ''
                try { $createOut = (& schtasks.exe /Create /TN $name /XML $xmlPath 2>&1 | Out-String) } catch { $createOut = '' }
                if ($LASTEXITCODE -ne 0) {
                    return [pscustomobject]@{ ok = $false; reason = 'schtasks-create-failed'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
                }
                return [pscustomobject]@{ ok = $true; reason = 'replaced-conflict'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
            }
            if (-not [bool]$Force) {
                return [pscustomobject]@{ ok = $true; reason = 'already-registered'; reused = $true; task_name = $name; xml_path = $xmlPath; command = $createCmd; xml = $xml }
            }
            try { & schtasks.exe /Delete /TN $name /F 2>&1 | Out-Null } catch { }
            $createOut = ''
            try { $createOut = (& schtasks.exe /Create /TN $name /XML $xmlPath 2>&1 | Out-String) } catch { $createOut = '' }
            if ($LASTEXITCODE -ne 0) {
                return [pscustomobject]@{ ok = $false; reason = 'schtasks-create-failed'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
            }
            return [pscustomobject]@{ ok = $true; reason = 'replaced-owned'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
        }
        $createOut = ''
        try { $createOut = (& schtasks.exe /Create /TN $name /XML $xmlPath 2>&1 | Out-String) } catch { $createOut = '' }
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ ok = $false; reason = 'schtasks-create-failed'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
        }
        return [pscustomobject]@{ ok = $true; reason = 'registered'; reused = $false; task_name = $name; xml_path = $xmlPath; command = $createCmd }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reused = $false; task_name = ''; xml_path = ''; command = '' }
    }
}

function Unregister-GitHubWakeSchedule {
    [CmdletBinding()]
    param([string]$TaskName = '', [switch]$Force, [switch]$DryRun)
    try {
        $name = ([string]$TaskName).Trim()
        if (-not (Test-GHWTaskName -Value $name)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-name'; reused = $false; task_name = ''; command = '' }
        }
        $delCmd = ('schtasks /Delete /TN "' + $name + '" /F')
        if ([bool]$DryRun) {
            return [pscustomobject]@{ ok = $true; reason = 'dry-run'; reused = $false; task_name = $name; command = $delCmd }
        }
        try { & schtasks.exe /Query /TN $name 2>&1 | Out-Null } catch { }
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ ok = $true; reason = 'not-found'; reused = $true; task_name = $name; command = $delCmd }
        }
        if (-not [bool]$Force) {
            return [pscustomobject]@{ ok = $false; reason = 'confirmation-required'; reused = $false; task_name = $name; command = $delCmd }
        }
        try { & schtasks.exe /Delete /TN $name /F 2>&1 | Out-Null } catch { }
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ ok = $false; reason = 'schtasks-delete-failed'; reused = $false; task_name = $name; command = $delCmd }
        }
        return [pscustomobject]@{ ok = $true; reason = 'unregistered'; reused = $false; task_name = $name; command = $delCmd }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reused = $false; task_name = ''; command = '' }
    }
}

# CLI entrypoint. Runs only when -WaitsDir or -ConfigFile is supplied, so
# dot-sourcing this file as a library defines the functions above and does
# nothing else. Single pass: no loop over time, no sleep outside the
# bounded API retry, no timer, no watcher, no daemon, no scheduler spawn.
if ((-not [string]::IsNullOrWhiteSpace($WaitsDir)) -or (-not [string]::IsNullOrWhiteSpace($ConfigFile))) {
    function Write-GHWEnvelope {
        param($Envelope)
        try {
            Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
        }
        catch {
            Write-Output '{"ok":false,"harness":"github-wake-v1","verdict":"WAKE_FAIL","reason":"encode-failed","items":[],"evaluated":0,"resumed":0,"kernel_mutated":false,"grants_authority":false,"done_approved":false,"merge_authority":false,"resume_authorized":false}'
        }
    }
    function New-GHWErrorEnvelope {
        param([string]$Reason)
        return [pscustomobject]@{
            ok = $false; harness = 'github-wake-v1'; verdict = 'WAKE_FAIL'
            reason = $Reason; items = @(); evaluated = [long]0; resumed = [long]0
            kernel_mutated = $false; grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $false
            scheduler = 'schtasks-xml; single-shot per tick; no in-memory state'
            next_action = $null
        }
    }
    try {
        $effWaitsDir = ([string]$WaitsDir).Trim()
        $effTasksDir = ([string]$TasksDir).Trim()
        $effGoalStoreDir = ([string]$GoalStoreDir).Trim()
        $effCheckpointDir = ([string]$CheckpointDir).Trim()
        $effFlagsPath = ([string]$FlagsPath).Trim()
        $effPolicyPath = ([string]$PolicyPath).Trim()
        $effFixture = ([string]$GraphQLSnapshotFile).Trim()
        $effEventId = ([string]$EventId).Trim()
        $effNow = ([string]$NowUtc).Trim()
        $effActor = ([string]$ActorIdentitySource).Trim()
        $effOut = ([string]$OutFile).Trim()
        $effAuth = [bool]$AuthorizationAlive
        $effExec = [bool]$ExecutorPresent
        $effCancel = [bool]$CancelRequested
        $effMaxAge = $MaxAgeSeconds
        $effMaxApi = $MaxApiAttempts
        $effTimeout = $TimeoutMs
        $cfgTrim = ([string]$ConfigFile).Trim()
        if (-not [string]::IsNullOrWhiteSpace($cfgTrim)) {
            $cfgDoc = Read-GHWJsonFile -Path $cfgTrim
            if ($null -eq $cfgDoc) {
                Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-config-file')
                exit 2
            }
            if ([string]::IsNullOrWhiteSpace($effWaitsDir)) { $effWaitsDir = ([string](Get-GHWValue $cfgDoc 'waits_dir' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effTasksDir)) { $effTasksDir = ([string](Get-GHWValue $cfgDoc 'tasks_dir' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effGoalStoreDir)) { $effGoalStoreDir = ([string](Get-GHWValue $cfgDoc 'goal_store_dir' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effCheckpointDir)) { $effCheckpointDir = ([string](Get-GHWValue $cfgDoc 'checkpoint_dir' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effFlagsPath)) { $effFlagsPath = ([string](Get-GHWValue $cfgDoc 'flags_path' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effPolicyPath)) { $effPolicyPath = ([string](Get-GHWValue $cfgDoc 'policy_path' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effFixture)) { $effFixture = ([string](Get-GHWValue $cfgDoc 'graphql_snapshot_file' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effEventId)) { $effEventId = ([string](Get-GHWValue $cfgDoc 'event_id' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effNow)) { $effNow = ([string](Get-GHWValue $cfgDoc 'now_utc' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effActor)) { $effActor = ([string](Get-GHWValue $cfgDoc 'actor_identity_source' 'explicit-cli')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effOut)) { $effOut = ([string](Get-GHWValue $cfgDoc 'out_file' '')).Trim() }
            # Fail-closed: per-run authorization flags come ONLY from live CLI
            # switches (defaults false). Config values are never promoted to
            # true; a run without explicit -AuthorizationAlive ends in
            # TERMINAL authorization-revoked, never RESUME.
        }
        if ([string]::IsNullOrWhiteSpace($effWaitsDir) -or (-not (Test-Path -LiteralPath $effWaitsDir -PathType Container))) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-waits-dir')
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($effTasksDir) -or (-not (Test-Path -LiteralPath $effTasksDir -PathType Container))) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-tasks-dir')
            exit 2
        }
        if (-not (Test-GHWStrictInt -Value $effMaxAge -Min 1 -Max 3600)) {
            $cfgAge = $null
            if (-not [string]::IsNullOrWhiteSpace($cfgTrim)) {
                try { $cfgDoc2 = Read-GHWJsonFile -Path $cfgTrim; $cfgAge = Get-GHWValue $cfgDoc2 'max_age_seconds' $null } catch { $cfgAge = $null }
            }
            if (Test-GHWStrictInt -Value $cfgAge -Min 1 -Max 3600) { $effMaxAge = [long]$cfgAge }
            else {
                Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-max-age')
                exit 2
            }
        }
        $effMaxAge = [long]$effMaxAge
        if (-not (Test-GHWStrictInt -Value $effMaxApi -Min 1 -Max 3)) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-max-api-attempts')
            exit 2
        }
        $effMaxApi = [int]$effMaxApi
        if (-not (Test-GHWStrictInt -Value $effTimeout -Min 1 -Max 10000)) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-timeout')
            exit 2
        }
        $effTimeout = [int]$effTimeout
        if ([string]::IsNullOrWhiteSpace($effActor)) { $effActor = 'explicit-cli' }
        $trusted = $false
        try { $trusted = Test-OrchestrationActorIdentitySource -Source $effActor } catch { $trusted = $false }
        if (-not [bool]$trusted) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-identity-source')
            exit 2
        }
        if ((-not [string]::IsNullOrWhiteSpace($effEventId)) -and (-not (Test-GHWEventId -Value $effEventId))) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-event-id')
            exit 2
        }
        if ((-not [string]::IsNullOrWhiteSpace($effNow)) -and ($null -eq (Convert-GHWUtc -Value $effNow))) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-now')
            exit 2
        }
        if ((-not [string]::IsNullOrWhiteSpace($effFixture)) -and (-not (Test-Path -LiteralPath $effFixture -PathType Leaf))) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'invalid-snapshot-file')
            exit 2
        }
        $polRes = Resolve-GHWPolicy -PolicyPath $effPolicyPath
        if (-not [bool]$polRes.ok) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason ([string]$polRes.reason))
            exit 1
        }
        $result = $null
        try {
            $result = Invoke-GitHubWake -WaitsDir $effWaitsDir -TasksDir $effTasksDir `
                -GoalStoreDir $effGoalStoreDir -CheckpointDir $effCheckpointDir -FlagsPath $effFlagsPath `
                -Policy $polRes.policy -GraphQLSnapshotFile $effFixture -EventId $effEventId `
                -MaxAgeSeconds $effMaxAge -NowUtc $effNow -ActorIdentitySource $effActor `
                -AuthorizationAlive $effAuth -ExecutorPresent $effExec -CancelRequested $effCancel `
                -MaxApiAttempts $effMaxApi -TimeoutMs $effTimeout
        }
        catch { $result = $null }
        if ($null -eq $result) {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'internal-error')
            exit 1
        }
        if (-not [string]::IsNullOrWhiteSpace($effOut)) {
            try {
                $json = ConvertTo-Json -InputObject $result -Depth 10 -Compress
                [IO.File]::WriteAllText($effOut, $json, (New-Object Text.UTF8Encoding $false))
            }
            catch { }
        }
        Write-GHWEnvelope -Envelope $result
        if ([bool]$result.ok) { exit 0 } else { exit 1 }
    }
    catch {
        try {
            Write-GHWEnvelope (New-GHWErrorEnvelope -Reason 'internal-error')
        }
        catch { }
        exit 1
    }
}
