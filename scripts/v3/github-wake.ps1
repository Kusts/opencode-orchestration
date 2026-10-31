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

    Usage (explicit dirs, resolver opt-in, no live booleans):
      powershell -NoProfile -File github-wake.ps1 -WaitsDir <dir> `
        -TasksDir <dir> -GoalStoreDir <dir> -CheckpointDir <dir> `
        -FlagsPath <flags.json> -ResolveAuthorization `
        -ResolveExecutor -ExecutorProofPath <proof.json> `
        [-GraphQLSnapshotFile <raw-fixture>]

    Liveness resolvers (opt-in, fail-closed, never persisted as authority):
      -ResolveLease (-LeaseFromWait alias): derive LeaseAlive per wait
        from lease_expires_utc/deadline_utc vs NowUtc. Lease/owner are
        wait-document facts, evaluated per wait on every pass.
      -ResolveOwner: derive OwnerAlive per wait from owner/lease_owner
        shape (Test-GHRSOwner) plus match against the Kernel task
        active_wait owner. Divergence => owner-mismatch, never RESUME.
      -ResolveAuthorization: derive AuthorizationAlive without the live
        -AuthorizationAlive switch. Requires a trusted identity source
        (Test-OrchestrationActorIdentitySource) plus ONE live source:
        (a) -AuthorizationProofPath JSON file carrying
        {"authorization_alive":true} (optional actor_identity_source
        must match), or (b) the live -FlagsPath with task_kernel
        enabled. Absent/invalid proof or disabled kernel =>
        authorization-revoked (fail-closed). Proof files are
        operator-owned per-tick attestations, never stored in the
        scheduler config as booleans.
      -ResolveExecutor: derive ExecutorPresent without the live
        -ExecutorPresent switch. Requires -ExecutorProofPath JSON
        file carrying {"executor_present":true} (optional observed_at
        must be within MaxAgeSeconds of NowUtc; observed_at more than
        60s in the future is rejected as executor-proof-future to
        tolerate only small clock skew). Absent/invalid/stale
        proof => no-executor (READY, never RESUME). A running
        scheduler alone is never treated as executor presence.
        HOLD honesto: executor liveness has no Kernel-owned lease
        contract; the proof file is a minimal explicit probe and its
        freshness is the operator's responsibility.
      Without any live switch, resolve switch, or proof path, the
      pass stays TERMINAL authorization-revoked (fail-closed).

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
    [switch]$ResolveAuthorization,
    [switch]$ResolveExecutor,
    [switch]$ResolveOwner,
    [Alias('LeaseFromWait')][switch]$ResolveLease,
    [string]$AuthorizationProofPath = '',
    [string]$ExecutorProofPath = '',
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
    $GHW_GoalLib = Join-Path $GHW_LibDir 'lib\OrchestrationGoalKernel.ps1'
    if (Test-Path -LiteralPath $GHW_GoalLib -PathType Leaf) { . $GHW_GoalLib }
    # Productive dispatch mechanism (Prepare/Claim/Settle). Loaded ONCE
    # here at script scope so the definitions persist for every
    # dot-source consumer (wake CLI, controller driver, tests). A lazy
    # dot-source inside a function would land in that function's local
    # scope and vanish on return. Load failure stays fail-closed: the
    # Import probe below refuses the productive phase when the Intent
    # constructor is unavailable. Top-level safe: the lib carries only
    # an empty param() plus function definitions.
    $GHW_DispatchLib = Join-Path $GHW_LibDir 'lib\OrchestrationNativeDispatch.ps1'
    if (Test-Path -LiteralPath $GHW_DispatchLib -PathType Leaf) { . $GHW_DispatchLib }
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

function Get-GHWakeIdempotencyKey {
    param([string]$DedupKey = '', [string]$EventId = '')
    try {
        $d = ([string]$DedupKey).Trim()
        $e = ([string]$EventId).Trim()
        if ([string]::IsNullOrWhiteSpace($d) -or [string]::IsNullOrWhiteSpace($e)) { return '' }
        $raw = ($d + ':' + $e)
        $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
        $sha = $null
        try { $sha = [System.Security.Cryptography.SHA256]::Create() } catch { return '' }
        try {
            $hash = $sha.ComputeHash($bytes)
            $hex = ''
            foreach ($b in $hash) { $hex += $b.ToString('x2') }
            if ($hex.Length -lt 32) { return '' }
            return ($hex.Substring(0, 32).ToLowerInvariant())
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function New-GHWakeNextAction {
    param($Wait = $null, [string]$TaskId = '', [string]$CheckpointId = '', [string]$GoalId = '', [string]$EventId = '')
    try {
        $tid = ([string]$TaskId).Trim()
        $cid = ([string]$CheckpointId).Trim()
        $gid = ([string]$GoalId).Trim()
        $evt = ([string]$EventId).Trim()
        $ddk = ([string](Get-GHWValue $Wait 'dedup_key' '')).Trim()
        $gen = [long]0
        try { $gen = [long](Get-GHWValue $Wait 'generation' 0) } catch { $gen = 0 }
        $lown = ([string](Get-GHWValue $Wait 'lease_owner' '')).Trim()
        $lexp = ([string](Get-GHWValue $Wait 'lease_expires_utc' '')).Trim()
        $idem = Get-GHWakeIdempotencyKey -DedupKey $ddk -EventId $evt
        return [pscustomobject]@{
            task_id = $tid; checkpoint_id = $cid
            goal_id = $gid; wait_dedup_key = $ddk
            generation = $gen; lease_owner = $lown; lease_expires_utc = $lexp
            event_id = $evt; kernel_state = 'IMPLEMENTING'
            idempotency_key = $idem
            announce = ('next-action task=' + $tid + ' checkpoint=' + $cid)
        }
    }
    catch { return $null }
}

function Test-GHWakeHandoffShape {
    param($NextAction = $null)
    try {
        if ($null -eq $NextAction) { return @{ ok = $false; reason = 'no-next-action' } }
        $tid = ([string](Get-GHWValue $NextAction 'task_id' '')).Trim()
        $cid = ([string](Get-GHWValue $NextAction 'checkpoint_id' '')).Trim()
        $gid = ([string](Get-GHWValue $NextAction 'goal_id' '')).Trim()
        $ddk = ([string](Get-GHWValue $NextAction 'wait_dedup_key' '')).Trim()
        $evt = ([string](Get-GHWValue $NextAction 'event_id' '')).Trim()
        $kst = ([string](Get-GHWValue $NextAction 'kernel_state' '')).Trim().ToUpperInvariant()
        $idem = ([string](Get-GHWValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant()
        $lown = ([string](Get-GHWValue $NextAction 'lease_owner' '')).Trim()
        $lexp = ([string](Get-GHWValue $NextAction 'lease_expires_utc' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ($cid -cnotmatch '^[a-f0-9]{16}$') { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ([string]::IsNullOrWhiteSpace($gid)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ([string]::IsNullOrWhiteSpace($ddk)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if (-not (Test-GHWEventId -Value $evt)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ($kst -cne 'IMPLEMENTING') { return @{ ok = $false; reason = 'kernel-not-implementing' } }
        if ($idem -cnotmatch '^[a-f0-9]{32}$') { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ([string]::IsNullOrWhiteSpace($lown)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        if ($null -eq (Convert-GHWUtc -Value $lexp)) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        $genRaw = Get-GHWValue $NextAction 'generation' $null
        $genOk = $false
        try {
            if (($genRaw -is [int]) -or ($genRaw -is [long]) -or ($genRaw -is [short]) -or ($genRaw -is [byte])) {
                if ([long]$genRaw -ge 0) { $genOk = $true }
            }
        }
        catch { $genOk = $false }
        if (-not $genOk) { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
        $exp = Get-GHWakeIdempotencyKey -DedupKey $ddk -EventId $evt
        if ([string]::IsNullOrWhiteSpace($exp) -or ($idem -cne $exp)) { return @{ ok = $false; reason = 'idempotency-mismatch' } }
        return @{ ok = $true; reason = '' }
    }
    catch { return @{ ok = $false; reason = 'invalid-next-action-shape' } }
}

function Find-GHWakeWaitByDedup {
    param([string]$WaitsDir = '', [string]$DedupKey = '')
    try {
        $dir = ([string]$WaitsDir).Trim()
        $ddk = ([string]$DedupKey).Trim()
        if ([string]::IsNullOrWhiteSpace($dir) -or [string]::IsNullOrWhiteSpace($ddk)) { return $null }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter 'ghwait-*.json' -ErrorAction Stop)) {
            if ([long]$f.Length -le 0 -or [long]$f.Length -gt 262144) { continue }
            $doc = $null
            try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } catch { continue }
            if ([string](Get-GHWValue $doc 'dedup_key' '') -ceq $ddk) { return $doc }
        }
        return $null
    }
    catch { return $null }
}

function Test-GHWakeHandoffBinding {
    param($Wait = $null, [string]$TasksDir = '')
    try {
        if ($null -eq $Wait) { return @{ ok = $false; reason = 'wait-not-found' } }
        $tid = ([string](Get-GHWValue $Wait 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return @{ ok = $false; reason = 'wait-not-found' } }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir } catch { $task = $null }
        $taskErr = ''
        try {
            if ($null -eq $task) { $taskErr = 'NOT_FOUND' }
            elseif ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('error')) { $taskErr = ([string]$task['error']) }
            }
            else {
                $ep = $task.PSObject.Properties['error']
                if ($null -ne $ep) { $taskErr = ([string]$ep.Value) }
            }
        }
        catch { $taskErr = 'INTERNAL_ERROR' }
        if (-not [string]::IsNullOrWhiteSpace($taskErr)) { return @{ ok = $false; reason = 'task-unreadable' } }
        $state = ''
        try { $state = ([string]$task['state']).Trim().ToUpperInvariant() } catch { $state = '' }
        if ($state -cne 'IMPLEMENTING') { return @{ ok = $false; reason = 'kernel-not-implementing' } }
        $bind = $null
        try { $bind = Test-GRRWaitKernelBinding -Wait $Wait -TasksDir $TasksDir } catch { $bind = $null }
        if (($null -ne $bind) -and [bool](Get-GHWValue $bind 'ok' $false)) { return @{ ok = $true; reason = ''; fingerprint = ([string](Get-GHWValue $bind 'fingerprint' '')) } }
        $why = ''
        try { $why = ([string](Get-GHWValue $bind 'reason' '')) } catch { $why = '' }
        if ($why -cne 'kernel-not-blocked') { return @{ ok = $false; reason = 'binding-diverged' } }
        $fpSlot = $null
        try {
            $wRepo = ([string](Get-GHWValue $Wait 'repository' '')).Trim().ToLowerInvariant()
            $wPr = [long]0
            try { $wPr = [long](Get-GHWValue $Wait 'pr_number' 0) } catch { $wPr = 0 }
            $wSha = ([string](Get-GHWValue $Wait 'expected_head_sha' '')).Trim().ToLowerInvariant()
            $wOwner = ([string](Get-GHWValue $Wait 'owner' '')).Trim()
            $wDep = ('github-ci:v1:' + $wRepo + ':' + [string]$wPr + ':' + $wSha)
            $fpSlot = Get-OrchestrationWaitFingerprint -Type 'external_dependency' -Owner $wOwner -Action 'revalidate-github-ci' -DependencyId $wDep
        }
        catch { $fpSlot = $null }
        if (($null -eq $fpSlot) -or (-not [bool](Get-GHWValue $fpSlot 'ok' $false))) { return @{ ok = $false; reason = 'binding-diverged' } }
        $expFp = ([string](Get-GHWValue $fpSlot 'fingerprint' ''))
        if ([string]::IsNullOrWhiteSpace($expFp)) { return @{ ok = $false; reason = 'binding-diverged' } }
        $wh = @()
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('wait_history') -and ($null -ne $task['wait_history'])) { $wh = @($task['wait_history']) }
            }
            else {
                $hp = $task.PSObject.Properties['wait_history']
                if (($null -ne $hp) -and ($null -ne $hp.Value)) { $wh = @($hp.Value) }
            }
        }
        catch { $wh = @() }
        if (@($wh).Count -eq 0) { return @{ ok = $false; reason = 'binding-diverged' } }
        $last = @($wh)[@($wh).Count - 1]
        $histFp = ''
        try {
            if (($null -ne $last) -and ($last -is [System.Collections.IDictionary]) -and $last.Contains('fingerprint')) { $histFp = ([string]$last['fingerprint']) }
        }
        catch { $histFp = '' }
        if ([string]::IsNullOrWhiteSpace($histFp) -or ($histFp -cne $expFp)) { return @{ ok = $false; reason = 'binding-diverged' } }
        return @{ ok = $true; reason = ''; fingerprint = $expFp }
    }
    catch { return @{ ok = $false; reason = 'binding-diverged' } }
}

function Test-GHWakeHandoffCheckpoint {
    param([string]$CheckpointId = '', [string]$CheckpointDir = '', [string]$GoalStoreDir = '')
    try {
        $cid = ([string]$CheckpointId).Trim()
        if ($cid -cnotmatch '^[a-f0-9]{16}$') { return @{ ok = $false; reason = 'checkpoint-missing' } }
        $dir = ([string]$CheckpointDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            try { $dir = Get-OrchestrationGoalCheckpointStoreDir -StoreDir '' } catch { $dir = '' }
        }
        if ([string]::IsNullOrWhiteSpace($dir)) { return @{ ok = $false; reason = 'checkpoint-missing' } }
        $load = $null
        try { $load = Load-OrchestrationGoalCheckpoint -CheckpointId $cid -StoreDir $dir } catch { $load = $null }
        if (($null -eq $load) -or (-not [bool](Get-GHWValue $load 'ok' $false))) { return @{ ok = $false; reason = 'checkpoint-missing' } }
        $resume = $null
        try { $resume = Test-OrchestrationCheckpointResume -Checkpoint (Get-GHWValue $load 'checkpoint' $null) -GoalStoreDir $GoalStoreDir } catch { $resume = $null }
        if (($null -eq $resume) -or (-not [bool](Get-GHWValue $resume 'resumable' $false))) { return @{ ok = $false; reason = 'checkpoint-not-resumable' } }
        return @{ ok = $true; reason = '' }
    }
    catch { return @{ ok = $false; reason = 'checkpoint-missing' } }
}

function Test-GHWakeHandoffTarget {
    param($NextAction = $null, $Wait = $null)
    try {
        if (($null -eq $NextAction) -or ($null -eq $Wait)) { return @{ ok = $false; reason = 'wait-not-found' } }
        $tidGot = ([string](Get-GHWValue $NextAction 'task_id' '')).Trim()
        $tidExp = ([string](Get-GHWValue $Wait 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($tidExp) -or ($tidGot -cne $tidExp)) { return @{ ok = $false; reason = 'handoff-task-mismatch' } }
        $gidGot = ([string](Get-GHWValue $NextAction 'goal_id' '')).Trim()
        $gidExp = ([string](Get-GHWValue $Wait 'objective_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($gidExp) -or ($gidGot -cne $gidExp)) { return @{ ok = $false; reason = 'handoff-goal-mismatch' } }
        return @{ ok = $true; reason = '' }
    }
    catch { return @{ ok = $false; reason = 'handoff-task-mismatch' } }
}

function Get-GHWakeDispatchPromptHash {
    # Deterministic SHA256-32 (hex) over goal+task+checkpoint+dedup.
    # Never carries prompt text or secrets, only the 32-hex digest.
    param([string]$GoalId = '', [string]$TaskId = '', [string]$CheckpointId = '', [string]$DedupKey = '')
    try {
        $g = ([string]$GoalId).Trim()
        $t = ([string]$TaskId).Trim()
        $c = ([string]$CheckpointId).Trim()
        $d = ([string]$DedupKey).Trim()
        if ([string]::IsNullOrWhiteSpace($g) -or [string]::IsNullOrWhiteSpace($t) -or [string]::IsNullOrWhiteSpace($c) -or [string]::IsNullOrWhiteSpace($d)) { return '' }
        $raw = ('ghw-dispatch-v1|' + $g + '|' + $t + '|' + $c + '|' + $d)
        $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
        $sha = $null
        try { $sha = [System.Security.Cryptography.SHA256]::Create() } catch { return '' }
        try {
            $h = $sha.ComputeHash($bytes)
            $hex = ''
            foreach ($b in $h) { $hex += $b.ToString('x2') }
            if ($hex.Length -lt 32) { return '' }
            return ($hex.Substring(0, 32).ToLowerInvariant())
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-GHWakeHandoffSessionToken {
    # Deterministic pre-effect session token for ONE handoff (from the
    # claim-once idempotency key). Prepare and Claim both bind this exact
    # token, so retries stay consistent; the REAL worker session only
    # appears at Settle time as ChildSessionId (Planner-attested).
    param([string]$IdempotencyKey = '')
    try {
        $k = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($k -cnotmatch '^[a-f0-9]{32}$') { return '' }
        return ('ghw-handoff-' + $k)
    }
    catch { return '' }
}

function Get-GHWakeHandoffMessageId {
    param([string]$IdempotencyKey = '')
    try {
        $k = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($k -cnotmatch '^[a-f0-9]{32}$') { return '' }
        return ('ghwmsg-' + $k)
    }
    catch { return '' }
}

function Get-GHWakeHandoffCallId {
    param([string]$IdempotencyKey = '')
    try {
        $k = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($k -cnotmatch '^[a-f0-9]{32}$') { return '' }
        return ('ghwcall-' + $k)
    }
    catch { return '' }
}

function Import-GHWakeDispatchLib {
    # Probe-only, fail-closed. The productive dispatch library is loaded
    # ONCE at the top level of this file (script scope, definitions
    # persist). A lazy dot-source HERE would land in this function's
    # local scope and vanish on return, silently disabling every
    # Intent/Prepare/Claim/Settle call. Never load here; only probe.
    # Never throws.
    try {
        $cmd = Get-Command New-OrchestrationNativeDispatchIntent -ErrorAction SilentlyContinue
        return ($null -ne $cmd)
    }
    catch { return $false }
}

function New-GHWakeDispatchIntent {
    # Thin fail-closed wrapper over the supported Intent constructor.
    # ExternalIdempotent is always $true with the claim-once marker path
    # as ExternalIdempotencyProof: the handoff documents the single
    # idempotent reservation (same key) whose replay the receipt machine
    # governs; a divergente Intent for the same key stays a collision.
    param(
        [string]$TaskId = '',
        [long]$TaskExpectedRevision = 0,
        [string]$Agent = 'coder',
        [string]$PromptHash = '',
        [string[]]$Scope = @(),
        [string[]]$AcceptanceCriteria = @(),
        [string]$IdempotencyKey = '',
        [string]$Owner = '',
        [long]$OwnershipGeneration = 0,
        [string]$BaseRevision = '',
        [string]$ExternalIdempotencyProof = ''
    )
    try {
        if (-not (Import-GHWakeDispatchLib)) {
            return @{ ok = $false; reason = 'dispatch-lib-unavailable'; intent = $null }
        }
        $slot = $null
        try {
            $slot = New-OrchestrationNativeDispatchIntent -TaskId ([string]$TaskId) `
                -TaskExpectedRevision ([long]$TaskExpectedRevision) -Agent ([string]$Agent) `
                -PromptHash ([string]$PromptHash) -Scope @($Scope) `
                -AcceptanceCriteria @($AcceptanceCriteria) -IdempotencyKey ([string]$IdempotencyKey) `
                -Owner ([string]$Owner) -OwnershipGeneration ([long]$OwnershipGeneration) `
                -BaseRevision ([string]$BaseRevision) -ExternalIdempotent $true `
                -ExternalIdempotencyProof ([string]$ExternalIdempotencyProof)
        }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-GHWValue $slot 'ok' $false))) {
            $why = 'invalid-intent'
            try {
                $r = ([string](Get-GHWValue $slot 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            return @{ ok = $false; reason = $why; intent = $null }
        }
        return @{ ok = $true; reason = ''; intent = (Get-GHWValue $slot 'intent' $null) }
    }
    catch { return @{ ok = $false; reason = 'invalid-intent'; intent = $null } }
}

function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    try {
        $m = ([string]$MarkerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($m)) { return $null }
        if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($m, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function Set-GHWakeDispatchSettlement {
    # Completes the productive loop for ONE claimed handoff. Validates the
    # wake marker (claimed, same idempotency key) plus the NativeDispatch
    # receipt for the same key, then runs the supported Claim (handoff
    # session token) + Settle (Planner-attested child session + candidate
    # result) chain. Only a settled receipt flips the marker to
    # 'dispatched' with the real session id. Without a real session id,
    # or on any refusal, nothing is marked dispatched (fail-closed).
    # Single-shot: no loop, no sleep, no spawn, no merge/deploy/DONE.
    [CmdletBinding()]
    param(
        [string]$MarkerPath = '',
        [string]$SessionId = '',
        $ResultOk = $null,
        [string]$ResultSummary = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$FlagsPath = '',
        [string]$ExpectedGoalId = '',
        [string]$ExpectedTaskId = ''
    )
    $mkSettle = {
        param([bool]$Ok, [bool]$Dispatched, [string]$Reason, [bool]$Settled, [bool]$Duplicate)
        return [pscustomobject][ordered]@{
            ok = [bool]$Ok; dispatched = [bool]$Dispatched
            reason = ([string]$Reason); settled = [bool]$Settled
            duplicate = [bool]$Duplicate; executed = [bool]$Dispatched
            marker_path = ([string]$MarkerPath)
            grants_authority = $false; done_approved = $false; merge_authority = $false
        }
    }
    try {
        $m = ([string]$MarkerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($m)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-invalid' -Settled $false -Duplicate $false)
        }
        $sid = ([string]$SessionId).Trim()
        if ($sid -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-invalid' -Settled $false -Duplicate $false)
        }
        if (($null -eq $ResultOk) -or (-not ($ResultOk -is [bool]))) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-result-invalid' -Settled $false -Duplicate $false)
        }
        $doc = Read-GHWakeMarkerDoc -MarkerPath $m
        if ($null -eq $doc) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-unreadable' -Settled $false -Duplicate $false)
        }
        $mStat = ([string](Get-GHWValue $doc 'status' '')).Trim()
        $mIdem = ([string](Get-GHWValue $doc 'idempotency_key' '')).Trim().ToLowerInvariant()
        $mTask = ([string](Get-GHWValue $doc 'task_id' '')).Trim()
        $mGoal = ([string](Get-GHWValue $doc 'goal_id' '')).Trim()
        $mDdk = ([string](Get-GHWValue $doc 'wait_dedup_key' '')).Trim()
        $mEvt = ([string](Get-GHWValue $doc 'event_id' '')).Trim()
        $base = ''
        try { $base = [IO.Path]::GetFileNameWithoutExtension($m) } catch { $base = '' }
        $fileIdem = ''
        try {
            if ($base -cmatch '^ghw-handoff-([a-f0-9]{32})$') { $fileIdem = $Matches[1].ToLowerInvariant() }
        }
        catch { $fileIdem = '' }
        if ([string]::IsNullOrWhiteSpace($mIdem) -or ($mIdem -cnotmatch '^[a-f0-9]{32}$')) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-invalid' -Settled $false -Duplicate $false)
        }
        if ((-not [string]::IsNullOrWhiteSpace($fileIdem)) -and ($fileIdem -cne $mIdem)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-invalid' -Settled $false -Duplicate $false)
        }
        if ($mStat -ceq 'dispatched') {
            $dupSess = ([string](Get-GHWValue $doc 'session_id' '')).Trim()
            # Fail-closed duplicate: a dispatched marker alone never proves
            # dispatch. The settled receipt for the same key must agree:
            # receipt phase settled AND settle_child_session_id == sid ==
            # marker session_id. Absent/unreadable receipt or any
            # divergence refuses without dispatched=true.
            $dupGoal = $mGoal
            if ([string]::IsNullOrWhiteSpace($dupGoal)) { $dupGoal = ([string]$ExpectedGoalId).Trim() }
            if ([string]::IsNullOrWhiteSpace($dupGoal)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-goal-unknown' -Settled $true -Duplicate $false)
            }
            $dupExpTask = ([string]$ExpectedTaskId).Trim()
            if ((-not [string]::IsNullOrWhiteSpace($dupExpTask)) -and ($mTask -cne $dupExpTask)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-task-mismatch' -Settled $true -Duplicate $false)
            }
            $dupExpGoal = ([string]$ExpectedGoalId).Trim()
            if ((-not [string]::IsNullOrWhiteSpace($mGoal)) -and (-not [string]::IsNullOrWhiteSpace($dupExpGoal)) -and ($mGoal -cne $dupExpGoal)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            if ([string]::IsNullOrWhiteSpace($mDdk) -or [string]::IsNullOrWhiteSpace($mEvt)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            # MEDIUM-6D-DISP-F8: bind marker ddk/evt exactly to the settled
            # receipt key. The receipt persists no wait_dedup_key/event_id
            # fields (NativeDispatch schema), and this signature carries no
            # WaitsDir/NextAction, so the authoritative anchor available here
            # is the claim-once idempotency key itself (file name + receipt
            # lookup key). idempotency_key is DEFINED as sha256(ddk:evt)[0:32]
            # (Get-GHWakeIdempotencyKey), so recompute and compare exactly:
            # any divergent ddk or evt breaks the binding and refuses
            # fail-closed without dispatched=true. Full NextAction-vs-wait-doc
            # exactness (generation/lease_owner/task/goal) is enforced upstream
            # in Invoke-GHWakeControllerHandoff before claim.
            $dupExpIdem = Get-GHWakeIdempotencyKey -DedupKey $mDdk -EventId $mEvt
            if ([string]::IsNullOrWhiteSpace($dupExpIdem) -or ($dupExpIdem -cne $mIdem)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            if (-not (Test-GHWEventId -Value $mEvt)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            if (-not (Import-GHWakeDispatchLib)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $true -Duplicate $false)
            }
            $dupNeed = @('Get-OrchestrationDispatchReceiptDir', 'Resolve-NDGoalReceiptDir', 'Read-NDReceipt')
            foreach ($dnc in @($dupNeed)) {
                try {
                    if ($null -eq (Get-Command $dnc -ErrorAction SilentlyContinue)) {
                        return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $true -Duplicate $false)
                    }
                }
                catch {
                    return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $true -Duplicate $false)
                }
            }
            $dupRoot = ''
            try { $dupRoot = Get-OrchestrationDispatchReceiptDir -ReceiptDir ([string]$ReceiptDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() } catch { $dupRoot = '' }
            if ([string]::IsNullOrWhiteSpace($dupRoot)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $true -Duplicate $false)
            }
            $dupState = $null
            try { $dupState = Resolve-NDGoalReceiptDir -RootDir $dupRoot -GoalId $dupGoal } catch { $dupState = $null }
            $dupDir = ''
            try { $dupDir = ([string](Get-GHWValue $dupState 'dir' '')) } catch { $dupDir = '' }
            if ([string]::IsNullOrWhiteSpace($dupDir)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $true -Duplicate $false)
            }
            $dupIdent = ''
            try { $dupIdent = ([string](Get-GHWValue $dupState 'created_utc' '')) } catch { $dupIdent = '' }
            $dupRead = $null
            try { $dupRead = Read-NDReceipt -Dir $dupDir -Key $mIdem -Expected $dupIdent -AllowHandoffPhases } catch { $dupRead = $null }
            if (($null -eq $dupRead) -or (-not [bool](Get-GHWValue $dupRead 'ok' $false))) {
                $dupRw = 'settle-not-prepared'
                try {
                    $dupRr = ([string](Get-GHWValue $dupRead 'reason' ''))
                    if ($dupRr -ceq 'receipt-absent') { $dupRw = 'settle-not-prepared' }
                    elseif (-not [string]::IsNullOrWhiteSpace($dupRr)) { $dupRw = $dupRr }
                }
                catch { }
                return (& $mkSettle -Ok $false -Dispatched $false -Reason $dupRw -Settled $true -Duplicate $false)
            }
            $dupReceipt = Get-GHWValue $dupRead 'receipt' $null
            if ($null -eq $dupReceipt) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-prepared' -Settled $true -Duplicate $false)
            }
            $dupTask = ([string](Get-GHWValue $dupReceipt 'task_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($dupTask) -or ($dupTask -cne $mTask)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-task-mismatch' -Settled $true -Duplicate $false)
            }
            # Sweep F8: the settled receipt is conferring on goal too
            # (namespace-bound at read, but compare exactly like task_id;
            # divergence is identity, not a task mismatch).
            $dupRecGoal = ([string](Get-GHWValue $dupReceipt 'goal_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($dupRecGoal) -or ($dupRecGoal -cne $dupGoal)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            $dupPhase = ([string](Get-GHWValue $dupReceipt 'phase' '')).Trim().ToLowerInvariant()
            if ($dupPhase -cne 'settled') {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-prepared' -Settled $true -Duplicate $false)
            }
            $dupChild = ''
            try { $dupChild = ([string](Get-GHWValue $dupReceipt 'settle_child_session_id' '')).Trim() } catch { $dupChild = '' }
            if ([string]::IsNullOrWhiteSpace($dupChild) -or ($dupChild -cne $sid) -or ($dupChild -cne $dupSess) -or ($dupSess -cne $sid)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-mismatch' -Settled $true -Duplicate $false)
            }
            return (& $mkSettle -Ok $true -Dispatched $true -Reason 'settle-duplicate' -Settled $true -Duplicate $true)
        }
        if ($mStat -cne 'claimed') {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-claimed' -Settled $false -Duplicate $false)
        }
        $expTask = ([string]$ExpectedTaskId).Trim()
        if ((-not [string]::IsNullOrWhiteSpace($expTask)) -and ($mTask -cne $expTask)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-task-mismatch' -Settled $false -Duplicate $false)
        }
        $goalId = $mGoal
        if ([string]::IsNullOrWhiteSpace($goalId)) { $goalId = ([string]$ExpectedGoalId).Trim() }
        if ([string]::IsNullOrWhiteSpace($goalId)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-goal-unknown' -Settled $false -Duplicate $false)
        }
        if (-not (Import-GHWakeDispatchLib)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
        }
        $needCmds = @('Invoke-OrchestrationNativeDispatchClaim', 'Invoke-OrchestrationNativeDispatchSettle', 'Get-OrchestrationDispatchReceiptDir', 'Resolve-NDGoalReceiptDir', 'Read-NDReceipt')
        foreach ($nc in @($needCmds)) {
            try {
                if ($null -eq (Get-Command $nc -ErrorAction SilentlyContinue)) {
                    return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
                }
            }
            catch {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
            }
        }
        $root = ''
        try { $root = Get-OrchestrationDispatchReceiptDir -ReceiptDir ([string]$ReceiptDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() } catch { $root = '' }
        if ([string]::IsNullOrWhiteSpace($root)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
        }
        $rState = $null
        try { $rState = Resolve-NDGoalReceiptDir -RootDir $root -GoalId $goalId } catch { $rState = $null }
        $rDir = ''
        try { $rDir = ([string](Get-GHWValue $rState 'dir' '')) } catch { $rDir = '' }
        if ([string]::IsNullOrWhiteSpace($rDir)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
        }
        $rIdent = ''
        try { $rIdent = ([string](Get-GHWValue $rState 'created_utc' '')) } catch { $rIdent = '' }
        $read = $null
        try { $read = Read-NDReceipt -Dir $rDir -Key $mIdem -Expected $rIdent -AllowHandoffPhases } catch { $read = $null }
        if (($null -eq $read) -or (-not [bool](Get-GHWValue $read 'ok' $false))) {
            $rw = 'settle-not-prepared'
            try {
                $rr = ([string](Get-GHWValue $read 'reason' ''))
                if ($rr -ceq 'receipt-absent') { $rw = 'settle-not-prepared' }
                elseif (-not [string]::IsNullOrWhiteSpace($rr)) { $rw = $rr }
            }
            catch { }
            return (& $mkSettle -Ok $false -Dispatched $false -Reason $rw -Settled $false -Duplicate $false)
        }
        $receipt = Get-GHWValue $read 'receipt' $null
        if ($null -eq $receipt) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-prepared' -Settled $false -Duplicate $false)
        }
        # F9 upfront gate (MEDIUM-6D-DISP-F8): marker ddk/evt binding plus
        # receipt goal exactness, checked AFTER receipt resolution and
        # BEFORE any mutation (Claim, Settle, marker write). Covers the
        # claimed path, the settled-recovery marker flip below and every
        # later re-read by construction: no dispatched=true return below
        # this point is reachable without passing here. Reasons reuse the
        # existing settled vocabulary (settle-identity-diverged).
        if ([string]::IsNullOrWhiteSpace($mDdk) -or [string]::IsNullOrWhiteSpace($mEvt)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $false -Duplicate $false)
        }
        if (-not (Test-GHWEventId -Value $mEvt)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $false -Duplicate $false)
        }
        $gateExpIdem = Get-GHWakeIdempotencyKey -DedupKey $mDdk -EventId $mEvt
        if ([string]::IsNullOrWhiteSpace($gateExpIdem) -or ($gateExpIdem -cne $mIdem)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $false -Duplicate $false)
        }
        $rGoal = ([string](Get-GHWValue $receipt 'goal_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($rGoal) -or ($rGoal -cne $goalId)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $false -Duplicate $false)
        }
        $rPhase = ([string](Get-GHWValue $receipt 'phase' '')).Trim().ToLowerInvariant()
        $rTask = ([string](Get-GHWValue $receipt 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($rTask) -or ($rTask -cne $mTask)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-task-mismatch' -Settled $false -Duplicate $false)
        }
        $pfp = ([string](Get-GHWValue $receipt 'prepared_fingerprint' '')).Trim().ToLowerInvariant()
        $ref = ([string](Get-GHWValue $receipt 'reference' '')).Trim()
        $agent = ([string](Get-GHWValue $receipt 'agent' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($pfp) -or ($pfp -cnotmatch '^[a-f0-9]{32}$')) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-prepared' -Settled $false -Duplicate $false)
        }
        if ([string]::IsNullOrWhiteSpace($agent)) { $agent = 'coder' }
        $criteria = @()
        try {
            $rcRaw = Get-GHWValue $receipt 'acceptance_criteria' $null
            if ($null -ne $rcRaw) { $criteria = @($rcRaw) }
        }
        catch { $criteria = @() }
        $criteria = @($criteria | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -cmatch '^criterion:[0-9]+$' })
        if (@($criteria).Count -lt 1) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-result-invalid' -Settled $false -Duplicate $false)
        }
        $liveOwner = ''
        $liveGen = [long]0
        try {
            $gslot = Get-OrchestrationGoal -GoalId $goalId -StoreDir ([string]$GoalStoreDir).Trim()
            $grec = Get-GHWValue $gslot 'goal' $null
            $own = Get-GHWValue $grec 'ownership' $null
            $liveOwner = ([string](Get-GHWValue $own 'owner_id' '')).Trim()
            $liveGen = [long](Get-GHWValue $own 'generation' 0)
        }
        catch { $liveOwner = ''; $liveGen = 0 }
        if ([string]::IsNullOrWhiteSpace($liveOwner) -or ($liveGen -lt 1)) {
            try {
                $lo = ([string](Get-GHWValue $receipt 'owner' '')).Trim()
                $lg = [long](Get-GHWValue $receipt 'ownership_generation' 0)
                if ((-not [string]::IsNullOrWhiteSpace($lo)) -and ($lg -ge 1)) { $liveOwner = $lo; $liveGen = $lg }
            }
            catch { }
        }
        if ([string]::IsNullOrWhiteSpace($liveOwner) -or ($liveGen -lt 1)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-ownership-unknown' -Settled $false -Duplicate $false)
        }
        $auth = [pscustomobject][ordered]@{
            goal_id = $goalId; owner = $liveOwner; generation = $liveGen
            explicit_allow = $true; source = 'gh-wake-handoff'
        }
        $tok = Get-GHWakeHandoffSessionToken -IdempotencyKey $mIdem
        $msg = Get-GHWakeHandoffMessageId -IdempotencyKey $mIdem
        $call = Get-GHWakeHandoffCallId -IdempotencyKey $mIdem
        if ([string]::IsNullOrWhiteSpace($tok) -or [string]::IsNullOrWhiteSpace($msg) -or [string]::IsNullOrWhiteSpace($call)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-unavailable' -Settled $false -Duplicate $false)
        }
        $gDir = ([string]$GoalStoreDir).Trim()
        $tDir = ([string]$TasksDir).Trim()
        $fPath = ([string]$FlagsPath).Trim()
        $evDir = ([string]$EvidenceStoreDir).Trim()
        if ($rPhase -ceq 'settled') {
            # Receipt already settled (earlier attempt settled before the
            # marker flip): complete the marker now, no second effect.
            $finDoc = Read-GHWakeMarkerDoc -MarkerPath $m
            $finStat = ''
            try { $finStat = ([string](Get-GHWValue $finDoc 'status' '')).Trim() } catch { $finStat = '' }
            if ($finStat -cne 'claimed') {
                if ($finStat -ceq 'dispatched') {
                    $finIdemX = ''
                    try { $finIdemX = ([string](Get-GHWValue $finDoc 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $finIdemX = '' }
                    $finTaskX = ''
                    try { $finTaskX = ([string](Get-GHWValue $finDoc 'task_id' '')).Trim() } catch { $finTaskX = '' }
                    $finGoalX = ''
                    try { $finGoalX = ([string](Get-GHWValue $finDoc 'goal_id' '')).Trim() } catch { $finGoalX = '' }
                    $finDdkX = ''
                    try { $finDdkX = ([string](Get-GHWValue $finDoc 'wait_dedup_key' '')).Trim() } catch { $finDdkX = '' }
                    $finEvtX = ''
                    try { $finEvtX = ([string](Get-GHWValue $finDoc 'event_id' '')).Trim() } catch { $finEvtX = '' }
                    $finIdentOkX = (($finIdemX -ceq $mIdem) -and ($finTaskX -ceq $mTask) -and ($finGoalX -ceq $goalId) -and ($finDdkX -ceq $mDdk) -and ($finEvtX -ceq $mEvt))
                    if (-not [bool]$finIdentOkX) {
                        return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
                    }
                    $finSess = ''
                    try { $finSess = ([string](Get-GHWValue $finDoc 'session_id' '')).Trim() } catch { $finSess = '' }
                    $finChild = ''
                    try { $finChild = ([string](Get-GHWValue $receipt 'settle_child_session_id' '')).Trim() } catch { $finChild = '' }
                    if ([string]::IsNullOrWhiteSpace($finChild) -or ($finChild -cne $sid) -or ($finChild -cne $finSess) -or ($finSess -cne $sid)) {
                        return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-mismatch' -Settled $true -Duplicate $false)
                    }
                    return (& $mkSettle -Ok $true -Dispatched $true -Reason 'settle-duplicate' -Settled $true -Duplicate $true)
                }
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-claimed' -Settled $true -Duplicate $false)
            }
            $finIdem = ''
            try { $finIdem = ([string](Get-GHWValue $finDoc 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $finIdem = '' }
            $finTask = ''
            try { $finTask = ([string](Get-GHWValue $finDoc 'task_id' '')).Trim() } catch { $finTask = '' }
            $finGoal = ''
            try { $finGoal = ([string](Get-GHWValue $finDoc 'goal_id' '')).Trim() } catch { $finGoal = '' }
            $finDdk = ''
            try { $finDdk = ([string](Get-GHWValue $finDoc 'wait_dedup_key' '')).Trim() } catch { $finDdk = '' }
            $finEvt = ''
            try { $finEvt = ([string](Get-GHWValue $finDoc 'event_id' '')).Trim() } catch { $finEvt = '' }
            $finIdentOk = (($finIdem -ceq $mIdem) -and ($finTask -ceq $mTask) -and ($finGoal -ceq $goalId) -and ($finDdk -ceq $mDdk) -and ($finEvt -ceq $mEvt))
            if (-not [bool]$finIdentOk) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            $rChild = ''
            try { $rChild = ([string](Get-GHWValue $receipt 'settle_child_session_id' '')).Trim() } catch { $rChild = '' }
            if ($rChild -cne $sid) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-mismatch' -Settled $true -Duplicate $false)
            }
            $wStatus = 'candidate_pass'
            if (-not [bool]$ResultOk) { $wStatus = 'failed' }
            $payload = [ordered]@{
                task_id = $mTask; wait_dedup_key = ([string](Get-GHWValue $doc 'wait_dedup_key' ''))
                event_id = ([string](Get-GHWValue $doc 'event_id' '')); idempotency_key = $mIdem
                goal_id = $goalId; status = 'dispatched'; session_id = $rChild
                result_status = $wStatus; result_summary = ([string]$ResultSummary).Trim()
                settled_at = ([DateTime]::UtcNow.ToString('o'))
            }
            try {
                [IO.File]::WriteAllText($m, (ConvertTo-Json -InputObject $payload -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
            }
            catch {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-failed' -Settled $true -Duplicate $false)
            }
            return (& $mkSettle -Ok $true -Dispatched $true -Reason 'settle-duplicate' -Settled $true -Duplicate $true)
        }
        if ($rPhase -cne 'prepared') {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-prepared' -Settled $false -Duplicate $false)
        }
        $claim = $null
        try {
            $claim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $mIdem -Authorization $auth `
                -SessionId $tok -MessageId $msg -CallId $call -CallerAgent 'planner' -TargetAgent $agent `
                -PreparedFingerprint $pfp -ReceiptDir ([string]$ReceiptDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() `
                -GoalStoreDir $gDir -TasksDir $tDir -FlagsPath $fPath
        }
        catch { $claim = $null }
        $claimOk = (($null -ne $claim) -and [bool](Get-GHWValue $claim 'ok' $false) -and [bool](Get-GHWValue $claim 'claimed' $false))
        if (-not [bool]$claimOk) {
            $cw = 'settle-claim-refused'
            try {
                $cr = ([string](Get-GHWValue $claim 'reason' ''))
                if ($cr -ceq 'claim-already-consumed') { $cw = 'claim-already-consumed' }
                elseif (-not [string]::IsNullOrWhiteSpace($cr)) { $cw = $cr }
            }
            catch { }
            if ($cw -cne 'claim-already-consumed') {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason $cw -Settled $false -Duplicate $false)
            }
        }
        $wStatus = 'candidate_pass'
        if (-not [bool]$ResultOk) { $wStatus = 'failed' }
        $result = [pscustomobject][ordered]@{ status = $wStatus; claimed_evidence = [string[]]@($criteria) }
        $settle = $null
        try {
            $settle = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $mIdem -Authorization $auth `
                -ChildSessionId $sid -SessionId $tok -MessageId $msg -CallId $call -CallerAgent 'planner' -TargetAgent $agent `
                -PreparedFingerprint $pfp -Reference $ref -TaskId $rTask -Result $result `
                -ReceiptDir ([string]$ReceiptDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() `
                -GoalStoreDir $gDir -EvidenceStoreDir $evDir -TasksDir $tDir -FlagsPath $fPath
        }
        catch { $settle = $null }
        $settleOk = (($null -ne $settle) -and [bool](Get-GHWValue $settle 'ok' $false) -and [bool](Get-GHWValue $settle 'settled' $false))
        $settleDup = (($null -ne $settle) -and [bool](Get-GHWValue $settle 'duplicate' $false))
        if ((-not [bool]$settleOk) -and (-not [bool]$settleDup)) {
            $sw = 'settle-refused'
            try {
                $sr = ([string](Get-GHWValue $settle 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($sr)) { $sw = $sr }
            }
            catch { }
            return (& $mkSettle -Ok $false -Dispatched $false -Reason $sw -Settled $false -Duplicate $false)
        }
        $cur = Read-GHWakeMarkerDoc -MarkerPath $m
        $curStat = ''
        try { $curStat = ([string](Get-GHWValue $cur 'status' '')).Trim() } catch { $curStat = '' }
        if ($curStat -ceq 'dispatched') {
            $curIdemX = ''
            try { $curIdemX = ([string](Get-GHWValue $cur 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $curIdemX = '' }
            $curTaskX = ''
            try { $curTaskX = ([string](Get-GHWValue $cur 'task_id' '')).Trim() } catch { $curTaskX = '' }
            $curGoalX = ''
            try { $curGoalX = ([string](Get-GHWValue $cur 'goal_id' '')).Trim() } catch { $curGoalX = '' }
            $curDdkX = ''
            try { $curDdkX = ([string](Get-GHWValue $cur 'wait_dedup_key' '')).Trim() } catch { $curDdkX = '' }
            $curEvtX = ''
            try { $curEvtX = ([string](Get-GHWValue $cur 'event_id' '')).Trim() } catch { $curEvtX = '' }
            $curIdentOkX = (($curIdemX -ceq $mIdem) -and ($curTaskX -ceq $mTask) -and ($curGoalX -ceq $goalId) -and ($curDdkX -ceq $mDdk) -and ($curEvtX -ceq $mEvt))
            if (-not [bool]$curIdentOkX) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
            }
            $curSess = ''
            try { $curSess = ([string](Get-GHWValue $cur 'session_id' '')).Trim() } catch { $curSess = '' }
            $curChild = ''
            try { $curChild = ([string](Get-GHWValue $settle 'child_session_id' '')).Trim() } catch { $curChild = '' }
            if ([string]::IsNullOrWhiteSpace($curChild) -or ($curChild -cne $sid) -or ($curChild -cne $curSess) -or ($curSess -cne $sid)) {
                return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-mismatch' -Settled $true -Duplicate $false)
            }
            return (& $mkSettle -Ok $true -Dispatched $true -Reason 'settle-duplicate' -Settled $true -Duplicate $true)
        }
        if ($curStat -cne 'claimed') {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-not-claimed' -Settled $true -Duplicate $false)
        }
        $curIdem = ''
        try { $curIdem = ([string](Get-GHWValue $cur 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $curIdem = '' }
        $curTask = ''
        try { $curTask = ([string](Get-GHWValue $cur 'task_id' '')).Trim() } catch { $curTask = '' }
        $curGoal = ''
        try { $curGoal = ([string](Get-GHWValue $cur 'goal_id' '')).Trim() } catch { $curGoal = '' }
        $curDdk = ''
        try { $curDdk = ([string](Get-GHWValue $cur 'wait_dedup_key' '')).Trim() } catch { $curDdk = '' }
        $curEvt = ''
        try { $curEvt = ([string](Get-GHWValue $cur 'event_id' '')).Trim() } catch { $curEvt = '' }
        $curIdentOk = (($curIdem -ceq $mIdem) -and ($curTask -ceq $mTask) -and ($curGoal -ceq $goalId) -and ($curDdk -ceq $mDdk) -and ($curEvt -ceq $mEvt))
        if (-not [bool]$curIdentOk) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-identity-diverged' -Settled $true -Duplicate $false)
        }
        $sChild = ''
        try { $sChild = ([string](Get-GHWValue $settle 'child_session_id' '')).Trim() } catch { $sChild = '' }
        if ([string]::IsNullOrWhiteSpace($sChild) -or ($sChild -cne $sid)) {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-session-mismatch' -Settled $true -Duplicate $false)
        }
        $effSess = $sChild
        $payload = [ordered]@{
            task_id = $mTask; wait_dedup_key = ([string](Get-GHWValue $doc 'wait_dedup_key' ''))
            event_id = ([string](Get-GHWValue $doc 'event_id' '')); idempotency_key = $mIdem
            goal_id = $goalId; status = 'dispatched'; session_id = $effSess
            result_status = $wStatus; result_summary = ([string]$ResultSummary).Trim()
            settled_at = ([DateTime]::UtcNow.ToString('o'))
        }
        try {
            [IO.File]::WriteAllText($m, (ConvertTo-Json -InputObject $payload -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
        }
        catch {
            return (& $mkSettle -Ok $false -Dispatched $false -Reason 'settle-marker-failed' -Settled $true -Duplicate $false)
        }
        $dupOut = $false
        try { $dupOut = [bool]$settleDup } catch { $dupOut = $false }
        if ([bool]$claimOk -and (-not $dupOut)) {
            return (& $mkSettle -Ok $true -Dispatched $true -Reason 'planner-settled' -Settled $true -Duplicate $false)
        }
        return (& $mkSettle -Ok $true -Dispatched $true -Reason 'settle-duplicate' -Settled $true -Duplicate $true)
    }
    catch {
        try { return (& $mkSettle -Ok $false -Dispatched $false -Reason 'internal-error' -Settled $false -Duplicate $false) } catch { return $null }
    }
}

function New-GHWakeHandoffClaim {
    param([string]$MarkerPath = '', [string]$TaskId = '', [string]$DedupKey = '', [string]$EventId = '', [string]$IdempotencyKey = '', [string]$GoalId = '')
    try {
        $marker = ([string]$MarkerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($marker)) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = '' } }
        $mdir = ''
        try { $mdir = [IO.Path]::GetDirectoryName($marker) } catch { $mdir = '' }
        if ((-not [string]::IsNullOrWhiteSpace($mdir)) -and (-not (Test-Path -LiteralPath $mdir -PathType Container))) {
            try { [void][IO.Directory]::CreateDirectory($mdir) } catch { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
            if (-not (Test-Path -LiteralPath $mdir -PathType Container)) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
        }
        $payload = [ordered]@{ task_id = ([string]$TaskId); wait_dedup_key = ([string]$DedupKey); event_id = ([string]$EventId); idempotency_key = ([string]$IdempotencyKey); goal_id = ([string]$GoalId); status = 'claimed' }
        $json = ''
        try { $json = (ConvertTo-Json -InputObject $payload -Depth 4 -Compress) } catch { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $fs = $null
        try {
            $fs = [IO.File]::Open($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
        }
        catch [IO.IOException] {
            try { if ($null -ne $fs) { $fs.Dispose() } } catch { }
            $markerExists = $false
            try { $markerExists = (Test-Path -LiteralPath $marker -PathType Leaf) } catch { $markerExists = $false }
            if (-not [bool]$markerExists) {
                return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker }
            }
            $dupReason = 'duplicate-noop'
            $dupValidated = $false
            try {
                if (Test-Path -LiteralPath $marker -PathType Leaf) {
                    $mdoc = ConvertFrom-Json ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8))
                    $mtask = ([string](Get-GHWValue $mdoc 'task_id' '')).Trim()
                    $mddk = ([string](Get-GHWValue $mdoc 'wait_dedup_key' '')).Trim()
                    $mevt = ([string](Get-GHWValue $mdoc 'event_id' '')).Trim()
                    $midem = ([string](Get-GHWValue $mdoc 'idempotency_key' '')).Trim().ToLowerInvariant()
                    $mstat = ([string](Get-GHWValue $mdoc 'status' '')).Trim()
                    $mgoal = ([string](Get-GHWValue $mdoc 'goal_id' '')).Trim()
                    $expGoal = ([string]$GoalId).Trim()
                    $expEvt = ([string]$EventId).Trim()
                    $expIdem = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
                    if (($mtask -cne ([string]$TaskId)) -or ($mddk -cne ([string]$DedupKey))) { return @{ ok = $false; duplicate = $false; reason = 'idempotency-collision'; path = $marker } }
                    elseif ((-not [string]::IsNullOrWhiteSpace($mgoal)) -and (-not [string]::IsNullOrWhiteSpace($expGoal)) -and ($mgoal -cne $expGoal)) { return @{ ok = $false; duplicate = $false; reason = 'idempotency-collision'; path = $marker } }
                    elseif ([string]::IsNullOrWhiteSpace($expEvt) -or (-not (Test-GHWEventId -Value $expEvt))) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
                    elseif ([string]::IsNullOrWhiteSpace($expIdem) -or ($expIdem -cnotmatch '^[a-f0-9]{32}$')) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
                    elseif ([string]::IsNullOrWhiteSpace($mevt) -or (-not (Test-GHWEventId -Value $mevt)) -or ($mevt -cne $expEvt)) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
                    elseif ([string]::IsNullOrWhiteSpace($midem) -or ($midem -cnotmatch '^[a-f0-9]{32}$') -or ($midem -cne $expIdem)) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
                    elseif (($mstat -cne 'claimed') -and ($mstat -cne 'dispatched')) { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
                    $dupValidated = $true
                }
            }
            catch { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker } }
            if (-not [bool]$dupValidated) {
                return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker }
            }
            return @{ ok = $true; duplicate = $true; reason = $dupReason; path = $marker }
        }
        catch {
            try { if ($null -ne $fs) { $fs.Dispose() } } catch { }
            return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = $marker }
        }
        try { if ($null -ne $fs) { $fs.Dispose() } } catch { }
        return @{ ok = $true; duplicate = $false; reason = ''; path = $marker }
    }
    catch { return @{ ok = $false; duplicate = $false; reason = 'handoff-persist-failed'; path = ([string]$MarkerPath) } }
}

function Set-GHWakeHandoffDispatched {
    param([string]$MarkerPath = '', [string]$TaskId = '', [string]$DedupKey = '', [string]$EventId = '', [string]$IdempotencyKey = '')
    try {
        $marker = ([string]$MarkerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($marker)) { return @{ ok = $true; reason = '' } }
        $payload = [ordered]@{ task_id = ([string]$TaskId); wait_dedup_key = ([string]$DedupKey); event_id = ([string]$EventId); idempotency_key = ([string]$IdempotencyKey); status = 'dispatched' }
        [IO.File]::WriteAllText($marker, (ConvertTo-Json -InputObject $payload -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
        return @{ ok = $true; reason = '' }
    }
    catch { return @{ ok = $false; reason = 'handoff-persist-failed' } }
}

function Remove-GHWakeHandoffClaim {
    param([string]$MarkerPath = '')
    try {
        $marker = ([string]$MarkerPath).Trim()
        if ([string]::IsNullOrWhiteSpace($marker)) { return }
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return }
        $cur = ConvertFrom-Json ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8))
        if ([string](Get-GHWValue $cur 'status' '') -cne 'claimed') { return }
        [void](Remove-Item -LiteralPath $marker -Force -ErrorAction Stop)
    }
    catch { }
}

function Invoke-GHWakeControllerHandoff {
    # IMPLEMENTING alone is never execution: the Kernel BLOCKED->IMPLEMENTING
    # transition only unblocks the task. executed=$true appears solely when
    # Set-GHWakeDispatchSettlement completes the productive Claim + Settle
    # chain with a Planner-attested session id; a bare IMPLEMENTING task
    # with no handoff envelope yields no-next-action, and a positive
    # controller probe is only a 'controller-responded' signal (marker stays
    # 'claimed', dispatched stays false) until the Planner settles it.
    [CmdletBinding()]
    param(
        $NextAction = $null,
        [string]$WaitsDir = '',
        [string]$TasksDir = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointDir = '',
        [string]$FlagsPath = '',
        [string]$NowUtc = '',
        [string]$HandoffStateDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$EvidenceStoreDir = '',
        $ObjectiveStepProbe = $null,
        $NextMoveProbe = $null
    )
    $mkResult = {
        param([bool]$Ok, [bool]$Dispatched, [string]$Decision, [string]$Reason, [string]$Controller, $EchoAction, [string]$MarkerPath = '', $DispatchIntent = $null, $Prepare = $null)
        $tidOut = ''
        $idemOut = ''
        try { $tidOut = ([string](Get-GHWValue $EchoAction 'task_id' '')) } catch { $tidOut = '' }
        try { $idemOut = ([string](Get-GHWValue $EchoAction 'idempotency_key' '')) } catch { $idemOut = '' }
        return [pscustomobject]@{
            ok = [bool]$Ok; dispatched = [bool]$Dispatched
            decision = ([string]$Decision); reason = ([string]$Reason)
            controller = ([string]$Controller)
            task_id = $tidOut; idempotency_key = $idemOut
            kernel_state = 'IMPLEMENTING'; executed = [bool]$Dispatched
            grants_authority = $false; done_approved = $false; merge_authority = $false
            marker_path = ([string]$MarkerPath)
            dispatch_intent = $DispatchIntent; prepare = $Prepare
            next_action = $EchoAction
        }
    }
    try {
        $shape = Test-GHWakeHandoffShape -NextAction $NextAction
        if (-not [bool]$shape.ok) {
            $dec = 'not-dispatched'
            return (& $mkResult -Ok $false -Dispatched $false -Decision $dec -Reason ([string]$shape.reason) -Controller 'none' -EchoAction $NextAction)
        }
        $ddk = ([string](Get-GHWValue $NextAction 'wait_dedup_key' '')).Trim()
        $evt = ([string](Get-GHWValue $NextAction 'event_id' '')).Trim()
        $idem = ([string](Get-GHWValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant()
        $waitDoc = Find-GHWakeWaitByDedup -WaitsDir $WaitsDir -DedupKey $ddk
        if ($null -eq $waitDoc) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'wait-not-found' -Controller 'none' -EchoAction $NextAction)
        }
        $genExp = [long]0
        try { $genExp = [long](Get-GHWValue $waitDoc 'generation' 0) } catch { $genExp = 0 }
        $genGot = [long](Get-GHWValue $NextAction 'generation' -1)
        if ($genGot -ne $genExp) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'generation-mismatch' -Controller 'none' -EchoAction $NextAction)
        }
        $lownExp = ([string](Get-GHWValue $waitDoc 'lease_owner' '')).Trim()
        $lownGot = ([string](Get-GHWValue $NextAction 'lease_owner' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($lownExp) -or ($lownGot -cne $lownExp)) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'binding-diverged' -Controller 'none' -EchoAction $NextAction)
        }
        $bindRes = $null
        try { $bindRes = Test-GHWakeHandoffTarget -NextAction $NextAction -Wait $waitDoc } catch { $bindRes = $null }
        if (($null -eq $bindRes) -or (-not [bool](Get-GHWValue $bindRes 'ok' $false))) {
            $br = 'handoff-task-mismatch'
            try {
                $r0 = ([string](Get-GHWValue $bindRes 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r0)) { $br = $r0 }
            }
            catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $br -Controller 'none' -EchoAction $NextAction)
        }
        $bindRes = Test-GHWakeHandoffBinding -Wait $waitDoc -TasksDir $TasksDir
        if (-not [bool]$bindRes.ok) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason ([string]$bindRes.reason) -Controller 'none' -EchoAction $NextAction)
        }
        $hsdEarly = ([string]$HandoffStateDir).Trim()
        if ([string]::IsNullOrWhiteSpace($hsdEarly)) { $hsdEarly = ([string]$CheckpointDir).Trim() }
        if ([string]::IsNullOrWhiteSpace($hsdEarly)) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'handoff-persist-failed' -Controller 'none' -EchoAction $NextAction)
        }
        $cid = ([string](Get-GHWValue $NextAction 'checkpoint_id' '')).Trim()
        $ckptRes = Test-GHWakeHandoffCheckpoint -CheckpointId $cid -CheckpointDir $CheckpointDir -GoalStoreDir $GoalStoreDir
        if (-not [bool]$ckptRes.ok) {
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason ([string]$ckptRes.reason) -Controller 'none' -EchoAction $NextAction)
        }
        $nowObj = Convert-GHWUtc -Value $NowUtc
        if ($null -eq $nowObj) { $nowObj = [datetime]::UtcNow }
        $leaseRes = $null
        try { $leaseRes = Resolve-GHWLeaseAlive -Wait $waitDoc -NowObj $nowObj } catch { $leaseRes = $null }
        if (($null -eq $leaseRes) -or (-not [bool](Get-GHWValue $leaseRes 'alive' $false))) {
            $lr = 'lease-expired'
            try {
                $r2 = ([string](Get-GHWValue $leaseRes 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r2)) { $lr = $r2 }
            }
            catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $lr -Controller 'none' -EchoAction $NextAction)
        }
        # applied_events is the WAIT-level dedup (prevents re-RESUME of the
        # same event across wake ticks) and is recorded by the wake itself
        # on RESUME, so it is ALWAYS seen by the time this handoff runs.
        # It must not gate the handoff: the claim-once marker below is the
        # exactly-once gate (claimed/dispatched marker => duplicate-noop;
        # released-on-failure marker => fresh claim with idempotent
        # prepare-reuse). Gating here would make intent-ready unreachable
        # on the normal wake->handoff flow, or would force every probe
        # call into a replay refusal.
        $hsd = ([string]$HandoffStateDir).Trim()
        if ([string]::IsNullOrWhiteSpace($hsd)) { $hsd = ([string]$CheckpointDir).Trim() }
        $marker = ''
        if (-not [string]::IsNullOrWhiteSpace($hsd)) {
            $marker = Join-Path $hsd ('ghw-handoff-' + $idem + '.json')
        }
        $tidClaim = ([string](Get-GHWValue $NextAction 'task_id' ''))
        $gidClaim = ([string](Get-GHWValue $NextAction 'goal_id' '')).Trim()
        $claimOnce = {
            $cc = $null
            try { $cc = New-GHWakeHandoffClaim -MarkerPath $marker -TaskId $tidClaim -DedupKey $ddk -EventId $evt -IdempotencyKey $idem -GoalId $gidClaim } catch { $cc = $null }
            if (($null -eq $cc) -or (-not [bool](Get-GHWValue $cc 'ok' $false))) {
                $failReason = 'handoff-persist-failed'
                try {
                    $ft = ([string](Get-GHWValue $cc 'reason' ''))
                    if ($ft -ceq 'idempotency-collision') { $failReason = $ft }
                }
                catch { }
                return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $failReason -Controller 'none' -EchoAction $NextAction)
            }
            if ([bool](Get-GHWValue $cc 'duplicate' $false)) {
                $drr = 'duplicate-noop'
                try {
                    $t = ([string](Get-GHWValue $cc 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($t)) { $drr = $t }
                }
                catch { }
                return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $drr -Controller 'none' -EchoAction $NextAction)
            }
            return $null
        }
        $preGate = (& $claimOnce)
        if ($null -ne $preGate) { return $preGate }
        # Productive phase: build the supported DispatchIntent from the
        # LIVE task/goal and persist it via Prepare (pending receipt, zero
        # worker effect). Any refusal is fail-closed here: not-dispatched,
        # no probe, marker claim released for a later tick.
        $doPrepare = {
            $liveTaskRec = $null
            try { $liveTaskRec = Get-OrchestrationTask -TaskId $tidClaim -TasksDir $TasksDir } catch { $liveTaskRec = $null }
            $tErr = ''
            try {
                if ($null -eq $liveTaskRec) { $tErr = 'task-unreadable' }
                elseif ($liveTaskRec -is [System.Collections.IDictionary]) {
                    if ($liveTaskRec.Contains('error')) { $tErr = ([string]$liveTaskRec['error']) }
                }
                else {
                    $ep = $liveTaskRec.PSObject.Properties['error']
                    if ($null -ne $ep) { $tErr = ([string]$ep.Value) }
                }
            }
            catch { $tErr = 'task-unreadable' }
            if (-not [string]::IsNullOrWhiteSpace($tErr)) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-task-unreadable' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            $tRev = [long]0
            $tBase = ''
            $tScopes = @()
            $tCriteria = @()
            try { $tRev = [long](Get-GHWValue $liveTaskRec 'revision' 0) } catch { $tRev = 0 }
            try { $tBase = ([string](Get-GHWValue $liveTaskRec 'base_revision' '')).Trim() } catch { $tBase = '' }
            try {
                $rsRaw = Get-GHWValue $liveTaskRec 'read_scopes' $null
                if ($null -ne $rsRaw) { $tScopes += @($rsRaw) }
                $wsRaw = Get-GHWValue $liveTaskRec 'write_scopes' $null
                if ($null -ne $wsRaw) { $tScopes += @($wsRaw) }
            }
            catch { $tScopes = @() }
            $tScopes = @($tScopes | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            try {
                $acRaw = Get-GHWValue $liveTaskRec 'acceptance_criteria' $null
                if ($null -ne $acRaw) { $tCriteria = @($acRaw) }
            }
            catch { $tCriteria = @() }
            $tCriteria = @($tCriteria | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -cmatch '^criterion:[0-9]+$' })
            if (($tRev -lt 1) -or [string]::IsNullOrWhiteSpace($tBase)) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-task-unreadable' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            if (@($tScopes).Count -lt 1) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-no-scopes' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            if (@($tCriteria).Count -lt 1) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-no-criteria' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            $liveGoalRec = $null
            try {
                $gs = Get-OrchestrationGoal -GoalId $gidClaim -StoreDir $GoalStoreDir
                if (($null -ne $gs) -and [bool](Get-GHWValue $gs 'ok' $false)) { $liveGoalRec = Get-GHWValue $gs 'goal' $null }
            }
            catch { $liveGoalRec = $null }
            if ($null -eq $liveGoalRec) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-goal-unreadable' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            $ownGen = [long]0
            try { $ownGen = [long](Get-GHWValue (Get-GHWValue $liveGoalRec 'ownership' $null) 'generation' 0) } catch { $ownGen = 0 }
            if ($ownGen -lt 1) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-ownership-unknown' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            # Agent default: the goal next-move carries no agent field, so
            # the productive default is the documented 'coder' owner.
            $promptHash = Get-GHWakeDispatchPromptHash -GoalId $gidClaim -TaskId $tidClaim -CheckpointId $cid -DedupKey $ddk
            $prepSession = Get-GHWakeHandoffSessionToken -IdempotencyKey $idem
            if ([string]::IsNullOrWhiteSpace($promptHash) -or [string]::IsNullOrWhiteSpace($prepSession)) {
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'dispatch-intent-invalid' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            $intentSlot = New-GHWakeDispatchIntent -TaskId $tidClaim -TaskExpectedRevision $tRev `
                -Agent 'coder' -PromptHash $promptHash -Scope @($tScopes) -AcceptanceCriteria @($tCriteria) `
                -IdempotencyKey $idem -Owner $lownExp -OwnershipGeneration $ownGen `
                -BaseRevision $tBase -ExternalIdempotencyProof $marker
            if (-not [bool](Get-GHWValue $intentSlot 'ok' $false)) {
                $iw = 'dispatch-intent-invalid'
                try {
                    $ir = ([string](Get-GHWValue $intentSlot 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($ir)) { $iw = ('dispatch-intent-invalid:' + $ir) }
                }
                catch { }
                return @{ ok = $false; intent = $null; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $iw -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker) }
            }
            $builtIntent = Get-GHWValue $intentSlot 'intent' $null
            $auth = [pscustomobject][ordered]@{
                goal_id = $gidClaim; owner = $lownExp; generation = $ownGen
                explicit_allow = $true; source = 'gh-wake-handoff'
            }
            $prep = $null
            try {
                $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $builtIntent -Authorization $auth `
                    -SessionId $prepSession -ReceiptDir ([string]$ReceiptDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() `
                    -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath
            }
            catch { $prep = $null }
            if (($null -eq $prep) -or (-not [bool](Get-GHWValue $prep 'ok' $false))) {
                $pw = 'prepare-refused'
                try {
                    $prr = ([string](Get-GHWValue $prep 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($prr)) { $pw = ('prepare-refused:' + $prr) }
                }
                catch { }
                return @{ ok = $false; intent = $builtIntent; view = $null; result = (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $pw -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $builtIntent) }
            }
            $view = [pscustomobject][ordered]@{
                admitted = [bool](Get-GHWValue $prep 'admitted' $false)
                reused = [bool](Get-GHWValue $prep 'reused' $false)
                phase = ([string](Get-GHWValue $prep 'phase' ''))
                reference = ([string](Get-GHWValue $prep 'reference' ''))
                intent_fingerprint = ([string](Get-GHWValue $prep 'intent_fingerprint' ''))
                prepared_fingerprint = ([string](Get-GHWValue $prep 'prepared_fingerprint' ''))
                session_id = ([string](Get-GHWValue $prep 'session_id' ''))
                task_id = ([string](Get-GHWValue $prep 'task_id' ''))
                agent = ([string](Get-GHWValue $prep 'agent' ''))
            }
            return @{ ok = $true; intent = $builtIntent; view = $view; result = $null }
        }
        $ctrlName = 'none'
        $ctrlOut = $null
        if ($null -ne $ObjectiveStepProbe) {
            $ctrlName = 'objective-step-probe'
            $prStep = (& $doPrepare)
            if (-not [bool](Get-GHWValue $prStep 'ok' $false)) {
                try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
                return (Get-GHWValue $prStep 'result' $null)
            }
            $prepIntent = Get-GHWValue $prStep 'intent' $null
            $prepView = Get-GHWValue $prStep 'view' $null
            try { $ctrlOut = & $ObjectiveStepProbe $NextAction } catch { $ctrlOut = $null }
            if ($null -eq $ctrlOut) {
                try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
                return (& $mkResult -Ok $false -Dispatched $false -Decision 'not-dispatched' -Reason 'controller-failed' -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
            }
            $okProbe = $false
            try { $okProbe = [bool](Get-GHWValue $ctrlOut 'dispatched' (Get-GHWValue $ctrlOut 'ok' $false)) } catch { $okProbe = $false }
            if ([bool]$okProbe) {
                # A positive probe is a controller RESPONSE, never an
                # execution proof: the marker stays 'claimed' and only the
                # Planner, after a real subagent run, completes the loop
                # via Set-GHWakeDispatchSettlement (Claim + Settle).
                $probeReason = 'controller-responded'
                try {
                    $prx = ([string](Get-GHWValue $ctrlOut 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($prx)) { $probeReason = $prx }
                }
                catch { }
                return (& $mkResult -Ok $true -Dispatched $false -Decision 'controller-responded' -Reason $probeReason -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
            }
            $pr = 'controller-declined'
            try {
                $rr = ([string](Get-GHWValue $ctrlOut 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($rr)) { $pr = $rr }
            }
            catch { }
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $pr -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
        }
        if ($null -ne $NextMoveProbe) {
            $ctrlName = 'next-move-probe'
            $prMove = (& $doPrepare)
            if (-not [bool](Get-GHWValue $prMove 'ok' $false)) {
                try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
                return (Get-GHWValue $prMove 'result' $null)
            }
            $prepIntent = Get-GHWValue $prMove 'intent' $null
            $prepView = Get-GHWValue $prMove 'view' $null
            try { $ctrlOut = & $NextMoveProbe $NextAction } catch { $ctrlOut = $null }
            if ($null -eq $ctrlOut) {
                try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
                return (& $mkResult -Ok $false -Dispatched $false -Decision 'not-dispatched' -Reason 'controller-failed' -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
            }
            $okProbe2 = $false
            try { $okProbe2 = [bool](Get-GHWValue $ctrlOut 'dispatched' (Get-GHWValue $ctrlOut 'ok' $false)) } catch { $okProbe2 = $false }
            if ([bool]$okProbe2) {
                $probeReason2 = 'controller-responded'
                try {
                    $prx2 = ([string](Get-GHWValue $ctrlOut 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($prx2)) { $probeReason2 = $prx2 }
                }
                catch { }
                return (& $mkResult -Ok $true -Dispatched $false -Decision 'controller-responded' -Reason $probeReason2 -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
            }
            $pr2 = 'controller-declined'
            try {
                $rr2 = ([string](Get-GHWValue $ctrlOut 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($rr2)) { $pr2 = $rr2 }
            }
            catch { }
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $pr2 -Controller $ctrlName -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
        }
        $gid = $gidClaim
        $gCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $nCmd = Get-Command Get-OrchestrationGoalNextMove -ErrorAction SilentlyContinue
        if (($null -eq $gCmd) -or ($null -eq $nCmd)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'controller-unavailable' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker)
        }
        $gslot = $null
        try { $gslot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $gslot = $null }
        if (($null -eq $gslot) -or (-not [bool](Get-GHWValue $gslot 'ok' $false))) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'goal-unreadable' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker)
        }
        $mslot = $null
        try { $mslot = Get-OrchestrationGoalNextMove -Goal (Get-GHWValue $gslot 'goal' $null) } catch { $mslot = $null }
        if (($null -eq $mslot) -or (-not [bool](Get-GHWValue $mslot 'ok' $false))) {
            $mr = 'next-move-failed'
            try {
                $r3 = ([string](Get-GHWValue $mslot 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r3)) { $mr = $r3 }
            }
            catch { }
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason $mr -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker)
        }
        $moveName = ''
        try { $moveName = (([string](Get-GHWValue (Get-GHWValue $mslot 'next_move' $null) 'move' '')).Trim().ToUpperInvariant()) } catch { $moveName = '' }
        if (($moveName -cne 'CONTINUE') -and ($moveName -cne 'RETRY')) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (& $mkResult -Ok $true -Dispatched $false -Decision 'not-dispatched' -Reason 'move-needs-no-dispatch' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker)
        }
        $prPlain = (& $doPrepare)
        if (-not [bool](Get-GHWValue $prPlain 'ok' $false)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $marker } catch { }
            return (Get-GHWValue $prPlain 'result' $null)
        }
        $prepIntent = Get-GHWValue $prPlain 'intent' $null
        $prepView = Get-GHWValue $prPlain 'view' $null
        return (& $mkResult -Ok $true -Dispatched $false -Decision 'intent-ready' -Reason 'prepared-awaits-planner-dispatch' -Controller 'goal-next-move' -EchoAction $NextAction -MarkerPath $marker -DispatchIntent $prepIntent -Prepare $prepView)
    }
    catch {
        try { return (& $mkResult -Ok $false -Dispatched $false -Decision 'not-dispatched' -Reason 'internal-error' -Controller 'none' -EchoAction $NextAction) } catch { return $null }
    }
}

function Resolve-GHWLeaseAlive {
    param($Wait = $null, $NowObj = $null)
    try {
        if ($null -eq $Wait) { return @{ alive = $false; reason = 'lease-expired' } }
        $exp = Convert-GHWUtc -Value (Get-GHWValue $Wait 'lease_expires_utc' $null)
        if ($null -eq $exp) { return @{ alive = $false; reason = 'lease-expired' } }
        $now = $NowObj
        if ($null -eq $now) { $now = [datetime]::UtcNow }
        try { $now = ([datetime]$now).ToUniversalTime() } catch { $now = [datetime]::UtcNow }
        if ($now -gt $exp) { return @{ alive = $false; reason = 'lease-expired' } }
        $dl = Convert-GHWUtc -Value (Get-GHWValue $Wait 'deadline_utc' $null)
        if (($null -ne $dl) -and ($now -gt $dl)) { return @{ alive = $false; reason = 'wait-expired' } }
        return @{ alive = $true; reason = '' }
    }
    catch { return @{ alive = $false; reason = 'lease-expired' } }
}

function Test-GHWFallbackOwner {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Resolve-GHWOwnerAlive {
    param($Wait = $null, [string]$TasksDir = '')
    try {
        if ($null -eq $Wait) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $own = ([string](Get-GHWValue $Wait 'owner' '')).Trim()
        $lown = ([string](Get-GHWValue $Wait 'lease_owner' '')).Trim()
        $okOwn = $false
        $okLease = $false
        try {
            if ($null -ne (Get-Command Test-GHRSOwner -ErrorAction SilentlyContinue)) {
                $okOwn = [bool](Test-GHRSOwner -Value $own)
                $okLease = [bool](Test-GHRSOwner -Value $lown)
            }
            else {
                $okOwn = [bool](Test-GHWFallbackOwner -Value $own)
                $okLease = [bool](Test-GHWFallbackOwner -Value $lown)
            }
        }
        catch { return @{ alive = $false; reason = 'owner-mismatch' } }
        if ((-not [bool]$okOwn) -or (-not [bool]$okLease)) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $td = ([string]$TasksDir).Trim()
        if ([string]::IsNullOrWhiteSpace($td)) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $tid = ([string](Get-GHWValue $Wait 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $td } catch { $task = $null }
        if ($null -eq $task) { return @{ alive = $false; reason = 'owner-mismatch' } }
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('error')) { return @{ alive = $false; reason = 'owner-mismatch' } }
            }
            else {
                $ep = $task.PSObject.Properties['error']
                if ($null -ne $ep) { return @{ alive = $false; reason = 'owner-mismatch' } }
            }
        }
        catch { return @{ alive = $false; reason = 'owner-mismatch' } }
        $aw = $null
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('active_wait')) { $aw = $task['active_wait'] }
            }
            else {
                $ap = $task.PSObject.Properties['active_wait']
                if ($null -ne $ap) { $aw = $ap.Value }
            }
        }
        catch { $aw = $null }
        $expOwn = $own
        $expLease = $lown
        try {
            if ($null -ne (Get-Command Protect-TaskKernelText -ErrorAction SilentlyContinue)) {
                $expOwn = [string](Protect-TaskKernelText -Text $own)
                $expLease = [string](Protect-TaskKernelText -Text $lown)
            }
            else { return @{ alive = $false; reason = 'owner-mismatch' } }
        }
        catch { return @{ alive = $false; reason = 'owner-mismatch' } }
        if (($null -ne $aw) -and ($aw -is [System.Collections.IDictionary])) {
            $awOwner = ''
            try {
                if ($aw.Contains('owner')) { $awOwner = ([string]$aw['owner']) }
            }
            catch { return @{ alive = $false; reason = 'owner-mismatch' } }
            if ([string]::IsNullOrWhiteSpace($awOwner)) { return @{ alive = $false; reason = 'owner-mismatch' } }
            if (($awOwner -cne $expOwn) -or ($awOwner -cne $expLease)) { return @{ alive = $false; reason = 'owner-mismatch' } }
            return @{ alive = $true; reason = '' }
        }
        # Post-unblock reconcile: the Kernel archives active_wait into
        # wait_history on BLOCKED->IMPLEMENTING (active_wait becomes null).
        # The wait file may still be unconfirmed; owner liveness then comes
        # from the newest archived entry tied to THIS wait (fingerprint),
        # never from shape alone.
        $wh = @()
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('wait_history') -and ($null -ne $task['wait_history'])) { $wh = @($task['wait_history']) }
            }
            else {
                $hp = $task.PSObject.Properties['wait_history']
                if (($null -ne $hp) -and ($null -ne $hp.Value)) { $wh = @($hp.Value) }
            }
        }
        catch { $wh = @() }
        if (@($wh).Count -eq 0) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $last = @($wh)[@($wh).Count - 1]
        if (($null -eq $last) -or (-not ($last -is [System.Collections.IDictionary]))) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $histOwner = ''
        $histFp = ''
        try {
            if ($last.Contains('owner')) { $histOwner = ([string]$last['owner']) }
            if ($last.Contains('fingerprint')) { $histFp = ([string]$last['fingerprint']) }
        }
        catch { return @{ alive = $false; reason = 'owner-mismatch' } }
        if ([string]::IsNullOrWhiteSpace($histOwner) -or [string]::IsNullOrWhiteSpace($histFp)) { return @{ alive = $false; reason = 'owner-mismatch' } }
        if (($histOwner -cne $expOwn) -or ($histOwner -cne $expLease)) { return @{ alive = $false; reason = 'owner-mismatch' } }
        $fpOk = $false
        try {
            if ($null -ne (Get-Command Get-OrchestrationWaitFingerprint -ErrorAction SilentlyContinue)) {
                $wRepo = ([string](Get-GHWValue $Wait 'repository' '')).Trim().ToLowerInvariant()
                $wPr = 0
                try { $wPr = [long](Get-GHWValue $Wait 'pr_number' 0) } catch { $wPr = 0 }
                $wSha = ([string](Get-GHWValue $Wait 'expected_head_sha' '')).Trim().ToLowerInvariant()
                $wDep = ('github-ci:v1:' + $wRepo + ':' + [string]$wPr + ':' + $wSha)
                $slot = Get-OrchestrationWaitFingerprint -Type 'external_dependency' -Owner $own -Action 'revalidate-github-ci' -DependencyId $wDep
                if (($null -ne $slot) -and [bool](Get-GHWValue $slot 'ok' $false)) {
                    $expFp = ([string](Get-GHWValue $slot 'fingerprint' ''))
                    if ((-not [string]::IsNullOrWhiteSpace($expFp)) -and ($histFp -ceq $expFp)) { $fpOk = $true }
                }
            }
        }
        catch { $fpOk = $false }
        if (-not [bool]$fpOk) { return @{ alive = $false; reason = 'owner-mismatch' } }
        return @{ alive = $true; reason = '' }
    }
    catch { return @{ alive = $false; reason = 'owner-mismatch' } }
}

function Resolve-GHWAuthorizationAlive {
    param([string]$ActorIdentitySource = '', [string]$FlagsPath = '', [string]$AuthorizationProofPath = '')
    try {
        $src = ([string]$ActorIdentitySource).Trim()
        if ([string]::IsNullOrWhiteSpace($src)) { $src = 'explicit-cli' }
        $trusted = $false
        try { $trusted = [bool](Test-OrchestrationActorIdentitySource -Source $src) } catch { $trusted = $false }
        if (-not [bool]$trusted) { return @{ alive = $false; reason = 'authorization-revoked' } }
        $pp = ([string]$AuthorizationProofPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($pp)) {
            try {
                if (-not (Test-Path -LiteralPath $pp -PathType Leaf)) { return @{ alive = $false; reason = 'authorization-revoked' } }
                $fi = Get-Item -LiteralPath $pp -Force
                if ([long]$fi.Length -le 0 -or [long]$fi.Length -gt 262144) { return @{ alive = $false; reason = 'authorization-revoked' } }
                $doc = ConvertFrom-Json ([IO.File]::ReadAllText($pp, [Text.Encoding]::UTF8))
                if ($null -eq $doc) { return @{ alive = $false; reason = 'authorization-revoked' } }
                $v = $null
                $present = $false
                if ($doc -is [System.Collections.IDictionary]) {
                    if ($doc.Contains('authorization_alive')) { $v = $doc['authorization_alive']; $present = $true }
                }
                else {
                    $p = $doc.PSObject.Properties['authorization_alive']
                    if ($null -ne $p) { $v = $p.Value; $present = $true }
                }
                if ((-not [bool]$present) -or (-not ($v -is [bool])) -or (-not [bool]$v)) { return @{ alive = $false; reason = 'authorization-revoked' } }
                $ps = $null
                $psPresent = $false
                try {
                    if ($doc -is [System.Collections.IDictionary]) {
                        if ($doc.Contains('actor_identity_source')) { $ps = $doc['actor_identity_source']; $psPresent = $true }
                    }
                    else {
                        $q = $doc.PSObject.Properties['actor_identity_source']
                        if ($null -ne $q) { $ps = $q.Value; $psPresent = $true }
                    }
                }
                catch { $psPresent = $false }
                if ([bool]$psPresent -and ($null -ne $ps) -and ($ps -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$ps))) {
                    if ([string]$ps -cne $src) { return @{ alive = $false; reason = 'authorization-revoked' } }
                    $pt = $false
                    try { $pt = [bool](Test-OrchestrationActorIdentitySource -Source ([string]$ps)) } catch { $pt = $false }
                    if (-not [bool]$pt) { return @{ alive = $false; reason = 'authorization-revoked' } }
                }
                return @{ alive = $true; reason = '' }
            }
            catch { return @{ alive = $false; reason = 'authorization-revoked' } }
        }
        $fp = ([string]$FlagsPath).Trim()
        if ([string]::IsNullOrWhiteSpace($fp)) { return @{ alive = $false; reason = 'authorization-revoked' } }
        $flagsEnabled = $false
        try {
            if ($null -ne (Get-Command Get-TaskKernelFlagState -ErrorAction SilentlyContinue)) {
                $st = Get-TaskKernelFlagState -FlagsPath $fp
                try { $flagsEnabled = [bool](Get-GHWValue $st 'enabled' $false) } catch { $flagsEnabled = $false }
            }
            else {
                $doc = Read-GHWJsonFile -Path $fp
                if ($null -ne $doc) {
                    $tk = Get-GHWValue $doc 'task_kernel' $null
                    if ($null -ne $tk) { $flagsEnabled = [bool](Get-GHWValue $tk 'enabled' $false) }
                }
            }
        }
        catch { $flagsEnabled = $false }
        if (-not [bool]$flagsEnabled) { return @{ alive = $false; reason = 'authorization-revoked' } }
        return @{ alive = $true; reason = '' }
    }
    catch { return @{ alive = $false; reason = 'authorization-revoked' } }
}

function Resolve-GHWExecutorAlive {
    param([string]$ExecutorProofPath = '', [string]$NowUtc = '', $MaxAgeSeconds = 300)
    try {
        $pp = ([string]$ExecutorProofPath).Trim()
        if ([string]::IsNullOrWhiteSpace($pp)) { return @{ alive = $false; reason = 'no-executor' } }
        try {
            if (-not (Test-Path -LiteralPath $pp -PathType Leaf)) { return @{ alive = $false; reason = 'no-executor' } }
            $fi = Get-Item -LiteralPath $pp -Force
            if ([long]$fi.Length -le 0 -or [long]$fi.Length -gt 262144) { return @{ alive = $false; reason = 'no-executor' } }
            $doc = ConvertFrom-Json ([IO.File]::ReadAllText($pp, [Text.Encoding]::UTF8))
            if ($null -eq $doc) { return @{ alive = $false; reason = 'no-executor' } }
            $v = $null
            $present = $false
            if ($doc -is [System.Collections.IDictionary]) {
                if ($doc.Contains('executor_present')) { $v = $doc['executor_present']; $present = $true }
            }
            else {
                $p = $doc.PSObject.Properties['executor_present']
                if ($null -ne $p) { $v = $p.Value; $present = $true }
            }
            if ((-not [bool]$present) -or (-not ($v -is [bool])) -or (-not [bool]$v)) { return @{ alive = $false; reason = 'no-executor' } }
            $obsRaw = $null
            $obsPresent = $false
            try {
                if ($doc -is [System.Collections.IDictionary]) {
                    if ($doc.Contains('observed_at')) { $obsRaw = $doc['observed_at']; $obsPresent = $true }
                }
                else {
                    $q = $doc.PSObject.Properties['observed_at']
                    if ($null -ne $q) { $obsRaw = $q.Value; $obsPresent = $true }
                }
            }
            catch { $obsPresent = $false }
            if (-not [bool]$obsPresent) { return @{ alive = $false; reason = 'no-executor' } }
            if ($null -eq $obsRaw) { return @{ alive = $false; reason = 'no-executor' } }
            if (($obsRaw -is [string]) -and [string]::IsNullOrWhiteSpace([string]$obsRaw)) { return @{ alive = $false; reason = 'no-executor' } }
            $obs = Convert-GHWUtc -Value $obsRaw
            $now = Convert-GHWUtc -Value ([string]$NowUtc)
            if (($null -eq $obs) -or ($null -eq $now)) { return @{ alive = $false; reason = 'no-executor' } }
            $cap = 300
            try { if (($MaxAgeSeconds -is [int]) -or ($MaxAgeSeconds -is [long])) { $cap = [long]$MaxAgeSeconds } } catch { $cap = 300 }
            if (($now - $obs).TotalSeconds -gt [double]$cap) { return @{ alive = $false; reason = 'no-executor' } }
            $skew = 60
            if (($obs - $now).TotalSeconds -gt [double]$skew) { return @{ alive = $false; reason = 'executor-proof-future' } }
            return @{ alive = $true; reason = '' }
        }
        catch { return @{ alive = $false; reason = 'no-executor' } }
    }
    catch { return @{ alive = $false; reason = 'no-executor' } }
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
        [bool]$ResolveAuthorization = $false,
        [bool]$ResolveExecutor = $false,
        [bool]$ResolveOwner = $false,
        [bool]$ResolveLease = $false,
        [string]$AuthorizationProofPath = '',
        [string]$ExecutorProofPath = '',
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
        $ghwResolvedAuth = [bool]$AuthorizationAlive
        if ((-not $ghwResolvedAuth) -and [bool]$ResolveAuthorization) {
            $ghwAuthRes = $null
            try { $ghwAuthRes = Resolve-GHWAuthorizationAlive -ActorIdentitySource ([string]$ActorIdentitySource) -FlagsPath ([string]$FlagsPath) -AuthorizationProofPath ([string]$AuthorizationProofPath) } catch { $ghwAuthRes = $null }
            $ghwAuthOk = $false
            try { if (($null -ne $ghwAuthRes) -and [bool](Get-GHWValue $ghwAuthRes 'alive' $false)) { $ghwAuthOk = $true } } catch { $ghwAuthOk = $false }
            $ghwResolvedAuth = [bool]$ghwAuthOk
        }
        $ghwResolvedExec = [bool]$ExecutorPresent
        if ((-not $ghwResolvedExec) -and [bool]$ResolveExecutor) {
            $ghwExecRes = $null
            try { $ghwExecRes = Resolve-GHWExecutorAlive -ExecutorProofPath ([string]$ExecutorProofPath) -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds } catch { $ghwExecRes = $null }
            $ghwExecOk = $false
            try { if (($null -ne $ghwExecRes) -and [bool](Get-GHWValue $ghwExecRes 'alive' $false)) { $ghwExecOk = $true } } catch { $ghwExecOk = $false }
            $ghwResolvedExec = [bool]$ghwExecOk
        }
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
                $leaseAlive = $false
                try {
                    $ghwLeaseRes = Resolve-GHWLeaseAlive -Wait $w -NowObj $nowObj
                    if (($null -ne $ghwLeaseRes) -and [bool](Get-GHWValue $ghwLeaseRes 'alive' $false)) { $leaseAlive = $true }
                }
                catch { $leaseAlive = $false }
                $ownerAlive = $false
                try {
                    $ghwOwnerRes = Resolve-GHWOwnerAlive -Wait $w -TasksDir ([string]$TasksDir)
                    if (($null -ne $ghwOwnerRes) -and [bool](Get-GHWValue $ghwOwnerRes 'alive' $false)) { $ownerAlive = $true }
                }
                catch { $ownerAlive = $false }
                if ([bool]$already) {
                    $dec = $null
                    try {
                        $dec = Test-OrchestrationGitHubResume -Wait $w -Snapshot $null -Policy $Policy `
                            -NowUtc $nowStr -MaxAgeSeconds $MaxAgeSeconds -LeaseAlive $leaseAlive `
                            -OwnerAlive $ownerAlive -AuthorizationAlive $ghwResolvedAuth `
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
                                    $recLease = [bool]$leaseAlive
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
                                                -OwnerAlive $ownerAlive -AuthorizationAlive $ghwResolvedAuth `
                                                -ExecutorPresent $ghwResolvedExec -CancelRequested ([bool]$CancelRequested) `
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
                                                $nextAction = New-GHWakeNextAction -Wait $w -TaskId $tid -CheckpointId $recCid -GoalId $recObj -EventId $evt
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
                # $leaseAlive/$ownerAlive already resolved per wait above
                # (Resolve-GHWLeaseAlive / Resolve-GHWOwnerAlive); no
                # hardcoded true here.
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
                        -OwnerAlive $ownerAlive -AuthorizationAlive $ghwResolvedAuth `
                        -ExecutorPresent $ghwResolvedExec -CancelRequested ([bool]$CancelRequested) `
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
                        $nextAction = New-GHWakeNextAction -Wait $w -TaskId $tid -CheckpointId $cid -GoalId $objectiveId -EventId $evt
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
                    $nextAction = New-GHWakeNextAction -Wait $w -TaskId $tid -CheckpointId $cid -GoalId $objectiveId -EventId $evt
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
        [bool]$ResolveAuthorization = $false,
        [bool]$ResolveExecutor = $false,
        [bool]$ResolveOwner = $false,
        [bool]$ResolveLease = $false,
        [string]$AuthorizationProofPath = '',
        [string]$ExecutorProofPath = '',
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
            resolve_authorization = [bool]$ResolveAuthorization
            resolve_executor = [bool]$ResolveExecutor
            resolve_owner = [bool]$ResolveOwner
            resolve_lease = [bool]$ResolveLease
            authorization_proof_path = ([string]$AuthorizationProofPath)
            executor_proof_path = ([string]$ExecutorProofPath)
        }
        # Fail-closed: per-run authorization flags are NEVER persisted as
        # authority. Even when callers pass true, the config stores false;
        # live CLI switches (or opt-in resolvers with proof paths) must
        # supply the current values each execution. resolve_* and
        # *_proof_path entries are resolver opt-ins, not authority: they
        # only allow the tick to consult live sources, never true by fiat.
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
        # Scheduler parses StartBoundary as LOCAL time (no zone suffix): UtcNow
        # on a UTC-3 host fired ~3h late in live proof (LIVE-6D-PROOF DEVIATION-2).
        $start = ([datetime]::Now.AddMinutes(2)).ToString('yyyy-MM-ddTHH:mm:ss')
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
        $effResolveAuth = [bool]$ResolveAuthorization
        $effResolveExec = [bool]$ResolveExecutor
        $effResolveOwner = [bool]$ResolveOwner
        $effResolveLease = [bool]$ResolveLease
        $effAuthProof = ([string]$AuthorizationProofPath).Trim()
        $effExecProof = ([string]$ExecutorProofPath).Trim()
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
            if ([string]::IsNullOrWhiteSpace($effAuthProof)) { $effAuthProof = ([string](Get-GHWValue $cfgDoc 'authorization_proof_path' '')).Trim() }
            if ([string]::IsNullOrWhiteSpace($effExecProof)) { $effExecProof = ([string](Get-GHWValue $cfgDoc 'executor_proof_path' '')).Trim() }
            if (-not $effResolveAuth) {
                try {
                    $ghwRv = Get-GHWValue $cfgDoc 'resolve_authorization' $false
                    if (($ghwRv -is [bool]) -and [bool]$ghwRv) { $effResolveAuth = $true }
                }
                catch { $effResolveAuth = $false }
            }
            if (-not $effResolveExec) {
                try {
                    $ghwRv = Get-GHWValue $cfgDoc 'resolve_executor' $false
                    if (($ghwRv -is [bool]) -and [bool]$ghwRv) { $effResolveExec = $true }
                }
                catch { $effResolveExec = $false }
            }
            if (-not $effResolveOwner) {
                try {
                    $ghwRv = Get-GHWValue $cfgDoc 'resolve_owner' $false
                    if (($ghwRv -is [bool]) -and [bool]$ghwRv) { $effResolveOwner = $true }
                }
                catch { $effResolveOwner = $false }
            }
            if (-not $effResolveLease) {
                try {
                    $ghwRv = Get-GHWValue $cfgDoc 'resolve_lease' $false
                    if (($ghwRv -is [bool]) -and [bool]$ghwRv) { $effResolveLease = $true }
                }
                catch { $effResolveLease = $false }
            }
            # Fail-closed: per-run authorization flags come ONLY from live CLI
            # switches (defaults false). Config values are never promoted to
            # true; a run without explicit -AuthorizationAlive (and without
            # opt-in -ResolveAuthorization plus a live proof source) ends in
            # TERMINAL authorization-revoked, never RESUME. The config may
            # only carry resolver opt-ins (resolve_* plus *_proof_path);
            # resolve opt-ins consult live sources, they are not authority.
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
                -ResolveAuthorization $effResolveAuth -ResolveExecutor $effResolveExec `
                -ResolveOwner $effResolveOwner -ResolveLease $effResolveLease `
                -AuthorizationProofPath $effAuthProof -ExecutorProofPath $effExecProof `
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
