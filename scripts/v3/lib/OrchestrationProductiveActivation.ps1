<#!
.SYNOPSIS
    ACT-01 Productive Activation: real impls for the restricted executor
    behind an explicit operator gate (AUTHORITY_CHANGE, max risk, closed scope).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Fail-closed, PS 5.1
    compatible, ASCII-only. No network, no process spawn, no secrets, no
    flags read or written, no DONE and no verified_pass ever issued here.

    The restricted executor (OrchestrationObjectiveRuntime) invokes effect
    seams ONLY under its explicit -TestCallback switch. This file plugs
    REAL impls built on existing kernel functions:

      ProductiveDispatchImpl   TaskKernel start-attempt with goal/task/
                               work-item binding + idempotency key; returns
                               a receipt (destination + action + task/run +
                               generation + result, operation 'dispatch').
      ProductiveSettleImpl     TaskKernel worker-result settle; returns a
                               receipt bound to the settle proof
                               (operation 'settlement').
      ProductiveReconcileImpl  Destination-consulting observation.
                               destination via the binding; never re-effects.
      ProductiveCheckpointImpl GoalCheckpoint save/load real (round-trip
                               validated before the id is returned).

    Activation is EXPLICIT and reversible: every entry point carries a
    -Productive switch. Absent => HOLD (the executor runs its current
    intact path with zero impl invocations). Present => still HOLD unless
    a live GoalKernel ownership (Test-OrchestrationGoalOwnership held),
    an explicit allow envelope (admitted + explicit_allow) and the
    fencing token (owner + generation) all prove out. Never fail-open.

    Proofs required before each effect: live ownership revalidated
    pre-callback under the store lock (executor CAS helpers own the
    lock); receipts validated against proof/operation by the executor
    gates; same key => original receipt (diary CAS + TaskKernel
    descriptor idempotency); terminal Goal => no dispatch.

    Dispatch is a TaskKernel record, never a process/agent spawn.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    foreach ($PALibName in @('OrchestrationTaskKernel.ps1', 'OrchestrationGoalKernel.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationObjectiveRuntime.ps1')) {
        try {
            $PALibPath = Join-Path $PSScriptRoot $PALibName
            if (Test-Path -LiteralPath $PALibPath -PathType Leaf) { . $PALibPath }
        }
        catch { }
    }
}
catch { }

function Get-ProductiveActivationVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PRODUCTIVE-ACTIVATION'
        phase          = 'ACT-01'
    }
}

function Get-PAFieldValue {
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

function Get-PALongValue {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) { return [long]$Value }
        return $Default
    }
    catch { return $Default }
}

function New-PATracker {
    [CmdletBinding()]
    param($Tracker = $null)
    try {
        if (($null -ne $Tracker) -and ($Tracker -is [System.Collections.IDictionary])) {
            foreach ($k in @('dispatch', 'settle', 'reconcile', 'checkpoint')) {
                try { if (-not $Tracker.Contains($k)) { $Tracker[$k] = [long]0 } } catch { }
            }
            return $Tracker
        }
        return @{ dispatch = [long]0; settle = [long]0; reconcile = [long]0; checkpoint = [long]0 }
    }
    catch { return @{ dispatch = [long]0; settle = [long]0; reconcile = [long]0; checkpoint = [long]0 } }
}

function Get-PATrackerCount {
    param($Tracker, [string]$Name)
    try {
        if (($null -ne $Tracker) -and ($Tracker -is [System.Collections.IDictionary]) -and $Tracker.Contains($Name)) {
            return (Get-PALongValue $Tracker[$Name] 0)
        }
        return [long]0
    }
    catch { return [long]0 }
}

function Test-ProductiveGate {
    # Explicit operator gate: -Productive present AND live GoalKernel
    # ownership held AND explicit allow envelope admitted AND fencing
    # token bound. Anything else is HOLD (never fail-open). Never throws.
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [string]$GoalStoreDir = '',
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [string]$Operation = 'dispatch',
        [string]$Resource = '',
        [switch]$Productive
    )
    try {
        if (-not [bool]$Productive) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'hold-productive-disabled:productive-absent'; goal = $null; revision = [long]0 }
        }
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'hold-productive-disabled:invalid-goal-id'; goal = $null; revision = [long]0 }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-PAFieldValue $slot 'ok' $false)) -or ($null -eq (Get-PAFieldValue $slot 'goal' $null))) {
            $why = 'hold-productive-disabled:goal-read-failed'
            try { if (($null -ne $slot) -and (-not [string]::IsNullOrWhiteSpace([string]$slot.reason))) { $why = ('hold-productive-disabled:' + [string]$slot.reason) } } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why; goal = $null; revision = [long]0 }
        }
        $goal = (Get-PAFieldValue $slot 'goal' $null)
        $state = ''
        try { $state = (([string](Get-PAFieldValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $state = '' }
        if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'hold-productive-disabled:goal-terminal'; goal = $null; revision = [long]0 }
        }
        $own = $null
        try { $own = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $OwnerId -Generation $Generation }
        catch { $own = $null }
        if (($null -eq $own) -or (-not [bool](Get-PAFieldValue $own 'ok' $false)) -or (-not [bool](Get-PAFieldValue $own 'held' $false))) {
            $why = 'hold-productive-disabled:ownership-not-held'
            try { if (($null -ne $own) -and (-not [string]::IsNullOrWhiteSpace([string]$own.reason))) { $why = ('hold-productive-disabled:ownership-not-held:' + [string]$own.reason) } } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why; goal = $null; revision = [long]0 }
        }
        $env = $null
        try { $env = New-OrchestrationObjectiveAuthEnvelope -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation $Operation -Resource $Resource -Decision $Operation }
        catch { $env = $null }
        $adm = $false
        $exp = $false
        $envWhy = 'hold-productive-disabled:envelope-denied'
        try {
            if ($null -ne $env) {
                $adm = [bool](Get-PAFieldValue $env 'admitted' $false)
                $exp = [bool](Get-PAFieldValue $env 'explicit_allow' $false)
                if (-not [string]::IsNullOrWhiteSpace([string](Get-PAFieldValue $env 'reason' ''))) {
                    $envWhy = ('hold-productive-disabled:' + [string](Get-PAFieldValue $env 'reason' ''))
                }
            }
        }
        catch { $adm = $false; $exp = $false }
        if ((-not $adm) -or (-not $exp)) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $envWhy; goal = $null; revision = [long]0 }
        }
        $rev = Get-PALongValue (Get-PAFieldValue $goal 'revision' $null) 0
        return [pscustomobject]@{ ok = $true; admitted = $true; reason = ''; goal = $goal; revision = [long]$rev }
    }
    catch {
        return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'hold-productive-disabled:internal-error'; goal = $null; revision = [long]0 }
    }
}

function New-PAProof {
    param([string]$Destination = '', [string]$Action = '', [string]$OwnerId = '', [long]$Generation = 0, [string]$Key = '')
    try {
        return @{ destination = [string]$Destination; action = [string]$Action; fencing_owner = ([string]$OwnerId).Trim(); fencing_generation = [long](Get-PALongValue $Generation -1); idempotency_key = [string]$Key }
    }
    catch { return $null }
}

function Get-PAHashHex32 {
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

function Test-PABindingComplete {
    # Full-chain completeness for a dispatch binding. All fields of
    # goal/work-item/action_revision/owner/generation/task/run/key +
    # role are REQUIRED (role absent => deny). Never throws.
    param($Binding = $null)
    try {
        if ($null -eq $Binding) { return $false }
        $k = ([string](Get-PAFieldValue $Binding 'key' '')).Trim().ToLowerInvariant()
        $ik = ([string](Get-PAFieldValue $Binding 'idempotency_key' '')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($k) -or ($ik -cne $k)) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'goal_id' '')).Trim())) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'work_item_id' '')).Trim())) { return $false }
        if ((Get-PALongValue (Get-PAFieldValue $Binding 'action_revision' $null) -1) -lt 1) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'task_id' '')).Trim())) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'run_id' '')).Trim())) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'attempt_role' '')).Trim())) { return $false }
        if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $Binding 'owner' '')).Trim())) { return $false }
        if ((Get-PALongValue (Get-PAFieldValue $Binding 'generation' $null) -1) -lt 1) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-PABindingEqual {
    # Exact full-chain equality (case-sensitive ids, numeric
    # generation/revision). Any divergence => conflict. Never throws.
    param($A = $null, $B = $null)
    try {
        if (($null -eq $A) -or ($null -eq $B)) { return $false }
        if ([string](Get-PAFieldValue $A 'key' '') -cne [string](Get-PAFieldValue $B 'key' '')) { return $false }
        if ([string](Get-PAFieldValue $A 'goal_id' '') -cne [string](Get-PAFieldValue $B 'goal_id' '')) { return $false }
        if ([string](Get-PAFieldValue $A 'work_item_id' '') -cne [string](Get-PAFieldValue $B 'work_item_id' '')) { return $false }
        if ((Get-PALongValue (Get-PAFieldValue $A 'action_revision' $null) -1) -ne (Get-PALongValue (Get-PAFieldValue $B 'action_revision' $null) -1)) { return $false }
        if ([string](Get-PAFieldValue $A 'task_id' '') -cne [string](Get-PAFieldValue $B 'task_id' '')) { return $false }
        if ([string](Get-PAFieldValue $A 'run_id' '') -cne [string](Get-PAFieldValue $B 'run_id' '')) { return $false }
        if ([string](Get-PAFieldValue $A 'attempt_role' '') -cne [string](Get-PAFieldValue $B 'attempt_role' '')) { return $false }
        if ([string](Get-PAFieldValue $A 'owner' '') -cne [string](Get-PAFieldValue $B 'owner' '')) { return $false }
        if ((Get-PALongValue (Get-PAFieldValue $A 'generation' $null) -1) -ne (Get-PALongValue (Get-PAFieldValue $B 'generation' $null) -1)) { return $false }
        if ([string](Get-PAFieldValue $A 'idempotency_key' '') -cne [string](Get-PAFieldValue $B 'idempotency_key' '')) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-PAReceiptForBinding {
    # Receipt provenance for a binding: operation MUST be dispatch,
    # destination/action present and exact, task/run/key/generation
    # bound to the binding. Status/producer alone are insufficient.
    # Never throws.
    param($Receipt = $null, $Binding = $null)
    try {
        if (($null -eq $Receipt) -or ($null -eq $Binding)) { return $false }
        if ((($Receipt -isnot [System.Collections.IDictionary]) -and ($Receipt -isnot [pscustomobject]))) { return $false }
        $op = ([string](Get-PAFieldValue $Receipt 'operation' '')).Trim().ToLowerInvariant()
        if ($op -cne 'dispatch') { return $false }
        $dst = ([string](Get-PAFieldValue $Receipt 'destination' '')).Trim()
        $act = ([string](Get-PAFieldValue $Receipt 'action' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($dst) -or [string]::IsNullOrWhiteSpace($act)) { return $false }
        if ($dst -cne 'task-kernel') { return $false }
        if ($act -cne 'start-attempt') { return $false }
        if ([string](Get-PAFieldValue $Receipt 'task_id' '') -cne [string](Get-PAFieldValue $Binding 'task_id' '')) { return $false }
        if ([string](Get-PAFieldValue $Receipt 'run_id' '') -cne [string](Get-PAFieldValue $Binding 'run_id' '')) { return $false }
        $rk = ([string](Get-PAFieldValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
        $bk = ([string](Get-PAFieldValue $Binding 'key' '')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($rk) -or ($rk -cne $bk)) { return $false }
        if ((Get-PALongValue (Get-PAFieldValue $Receipt 'generation' $null) -1) -ne (Get-PALongValue (Get-PAFieldValue $Binding 'generation' $null) -1)) { return $false }
        return $true
    }
    catch { return $false }
}
function Get-PABindingPath {
    # Durable goal -> work-item -> task -> attempt/session binding file,
    # keyed by hash of the canonical idempotency key. Never throws.
    param([string]$Dir = '', [string]$Key = '')
    try {
        $d = ([string]$Dir).Trim()
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($d) -or [string]::IsNullOrWhiteSpace($k)) { return '' }
        $h = Get-PAHashHex32 ('binding|' + $k)
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $d ('binding-' + $h + '.binding.json'))
    }
    catch { return '' }
}

function Save-PABinding {
    # Persists the dispatch binding BEFORE any Start (create-if-absent
    # CAS over the FULL chain; never Move-Force arbitration). Same key
    # + full-chain equal is idempotent success; same key + any field
    # divergent is a conflict (fail closed, no start). Incomplete
    # binding, empty dir or write failure => $false (no start). The
    # write is atomic create-new: a concurrent winner is re-read and
    # compared (equal => success, divergent => conflict). Never throws.
    param($Binding = $null, [string]$Dir = '')
    try {
        if (-not (Test-PABindingComplete $Binding)) { return $false }
        $k = ([string](Get-PAFieldValue $Binding 'key' '')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($k)) { return $false }
        $dir = ([string]$Dir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($dir) }
        }
        catch { return $false }
        $path = Get-PABindingPath -Dir $dir -Key $k
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $raw = $null
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
            catch { return $false }
            if ($null -eq $raw) { return $false }
            if (-not (Test-PABindingComplete $raw)) { return $false }
            if ([string](Get-PAFieldValue $raw 'key' '') -cne $k) { return $false }
            if (Test-PABindingEqual $raw $Binding) { return $true }
            return $false
        }
        $json = ConvertTo-Json -InputObject $Binding -Depth 10 -Compress
        $bytes = ([Text.UTF8Encoding]::new($false)).GetBytes($json)
        $created = $false
        try {
            $fs = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            }
            finally { try { $fs.Close() } catch { } }
            $created = $true
        }
        catch [IO.IOException] {
            $created = $false
        }
        catch { return $false }
        if ($created) { return $true }
        $raw2 = $null
        try { $raw2 = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
        catch { return $false }
        if ($null -eq $raw2) { return $false }
        if (-not (Test-PABindingComplete $raw2)) { return $false }
        if ([string](Get-PAFieldValue $raw2 'key' '') -cne $k) { return $false }
        if (Test-PABindingEqual $raw2 $Binding) { return $true }
        return $false
    }
    catch { return $false }
}

function Get-PABinding {
    # Reads the durable binding for an idempotency key. $null when
    # absent or corrupt (absence is indeterminate, never proof of
    # anything). Never throws.
    param([string]$Dir = '', [string]$Key = '')
    try {
        $path = Get-PABindingPath -Dir ([string]$Dir) -Key ([string]$Key)
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) }
        catch { return $null }
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if ([string](Get-PAFieldValue $raw 'key' '') -cne $k) { return $null }
        return $raw
    }
    catch { return $null }
}

function Test-PAInCallbackGate {
    # In-callback gate (B4): live ownership + allow envelope + fencing
    # revalidated INSIDE the effect/observation callback from the LIVE
    # goal record read from GoalStoreDir (live-only; snapshot is never
    # trusted as live). GoalStoreDir empty => deny. A direct
    # invocation without proof is denied. Never throws.
    param($GoalSnapshot = $null, [string]$GoalStoreDir = '', [string]$OwnerId = '', [long]$Generation = 0, $Auth = $null, [string]$ExpectedOperation = '', [string]$WorkItemId = '', [switch]$AllowTerminal)
    try {
        $op = ([string]$ExpectedOperation).Trim().ToLowerInvariant()
        $wid = ([string]$WorkItemId).Trim()
        if ([string]::IsNullOrWhiteSpace($op) -or [string]::IsNullOrWhiteSpace($wid)) {
            return @{ ok = $false; reason = 'callback-gate-denied:invalid-expectation' }
        }
        $adm = $false
        $exp = $false
        $aop = ''
        $ars = ''
        try {
            if ((($Auth -is [System.Collections.IDictionary]) -or ($Auth -is [pscustomobject]))) {
                $adm = [bool](Get-PAFieldValue $Auth 'admitted' $false)
                $exp = [bool](Get-PAFieldValue $Auth 'explicit_allow' $false)
                $aop = ([string](Get-PAFieldValue $Auth 'operation' '')).Trim().ToLowerInvariant()
                $ars = ([string](Get-PAFieldValue $Auth 'resource' '')).Trim()
            }
        }
        catch { }
        if ((-not $adm) -or (-not $exp)) {
            return @{ ok = $false; reason = 'callback-gate-denied:auth-not-admitted' }
        }
        if ($aop -cne $op) {
            return @{ ok = $false; reason = 'callback-gate-denied:auth-operation-mismatch' }
        }
        if ($ars -cne $wid) {
            return @{ ok = $false; reason = 'callback-gate-denied:auth-resource-mismatch' }
        }
        $gid = ([string](Get-PAFieldValue $GoalSnapshot 'goal_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return @{ ok = $false; reason = 'callback-gate-denied:invalid-goal' }
        }
        $getGoal = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $testOwn = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $getGoal) -or ($null -eq $testOwn)) {
            return @{ ok = $false; reason = 'callback-gate-denied:goal-kernel-unavailable' }
        }
        $live = $null
        if ([string]::IsNullOrWhiteSpace([string]$GoalStoreDir)) {
            return @{ ok = $false; reason = 'callback-gate-denied:goal-store-required' }
        }
        try {
            $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
            if (($null -eq $slot) -or (-not [bool](Get-PAFieldValue $slot 'ok' $false))) {
                return @{ ok = $false; reason = 'callback-gate-denied:goal-read-failed' }
            }
            $live = Get-PAFieldValue $slot 'goal' $null
            if ($null -eq $live) {
                return @{ ok = $false; reason = 'callback-gate-denied:goal-read-failed' }
            }
        }
        catch {
            return @{ ok = $false; reason = 'callback-gate-denied:goal-read-failed' }
        }
        if (-not [bool]$AllowTerminal) {
            $stt = ''
            try { $stt = (([string](Get-PAFieldValue $live 'state' '')).Trim().ToUpperInvariant()) } catch { $stt = '' }
            if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $stt) {
                return @{ ok = $false; reason = 'callback-gate-denied:goal-terminal' }
            }
        }
        $own = $null
        try { $own = Test-OrchestrationGoalOwnership -Goal $live -OwnerId $OwnerId -Generation $Generation }
        catch { $own = $null }
        if (($null -eq $own) -or (-not [bool](Get-PAFieldValue $own 'held' $false))) {
            $why = 'callback-gate-denied:ownership-not-held'
            try {
                if (($null -ne $own) -and (-not [string]::IsNullOrWhiteSpace([string](Get-PAFieldValue $own 'reason' '')))) {
                    $why = ('callback-gate-denied:' + [string](Get-PAFieldValue $own 'reason' ''))
                }
            }
            catch { }
            return @{ ok = $false; reason = $why }
        }
        return @{ ok = $true; reason = '' }
    }
    catch {
        return @{ ok = $false; reason = 'callback-gate-denied:internal-error' }
    }
}

function Test-PARealWorkerResult {
    # Real-result validation (B1): closed status, real producer equal
    # to AttemptRole, non-empty evidence. Anything else is denied
    # (settlement stays pending, never fabricated). Never throws.
    param($Worker = $null, [string]$Role = '')
    try {
        if ($null -eq $Worker) {
            return @{ ok = $false; reason = 'worker-result-missing' }
        }
        $stt = ([string](Get-PAFieldValue $Worker 'status' '')).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $stt) {
            return @{ ok = $false; reason = 'worker-result-invalid-status' }
        }
        $prod = ([string](Get-PAFieldValue $Worker 'produced_by' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($prod)) {
            return @{ ok = $false; reason = 'worker-result-missing-producer' }
        }
        $role = ([string]$Role).Trim()
        if ([string]::IsNullOrWhiteSpace($role)) {
            return @{ ok = $false; reason = 'worker-result-missing-role' }
        }
        if ($prod -cne $role) {
            return @{ ok = $false; reason = 'worker-result-producer-role-mismatch' }
        }
        $ev = Get-PAFieldValue $Worker 'evidence' $null
        if ($null -eq $ev) { $ev = Get-PAFieldValue $Worker 'claimed_evidence' $null }
        $items = @($ev)
        if ($items.Count -eq 0) {
            return @{ ok = $false; reason = 'worker-result-missing-evidence' }
        }
        $clean = New-Object System.Collections.Generic.List[string]
        foreach ($e in $items) {
            if (($null -eq $e) -or (-not ($e -is [string])) -or [string]::IsNullOrWhiteSpace([string]$e)) {
                return @{ ok = $false; reason = 'worker-result-invalid-evidence' }
            }
            $clean.Add([string]$e) | Out-Null
        }
        return @{ ok = $true; reason = ''; status = $stt; produced_by = $prod; evidence = ([string[]]$clean.ToArray()) }
    }
    catch {
        return @{ ok = $false; reason = 'worker-result-invalid' }
    }
}

function Get-PAWorkerResultFromEvent {
    # Extracts a worker-result shaped node from the executor event
    # payload (payload.worker_result, or the payload itself when it
    # carries status + produced_by). $null when absent. Never throws.
    param($Event = $null)
    try {
        if ($null -eq $Event) { return $null }
        $pay = Get-PAFieldValue $Event 'payload' $null
        if ($null -eq $pay) { return $null }
        $wr = Get-PAFieldValue $pay 'worker_result' $null
        if ($null -ne $wr) { return $wr }
        $stt = Get-PAFieldValue $pay 'status' $null
        $pb = Get-PAFieldValue $pay 'produced_by' $null
        if (($null -ne $stt) -and ($null -ne $pb)) { return $pay }
        return $null
    }
    catch { return $null }
}

function New-ProductiveDispatchImpl {
    # Real dispatch constructor over Start-OrchestrationTaskAttempt.
    # Record-only: no spawn. Without -Productive no impl is returned.
    # GoalStoreDir AND DispatchStoreDir are REQUIRED (empty => HOLD,
    # no impl): the callback reads live ownership from the store and
    # pre-registers the full binding before any Start. The returned
    # wrapper always revalidates live ownership + allow + fencing
    # INSIDE the callback (B4); direct invocation without proof is
    # denied. Binding is persisted BEFORE Start (create-if-absent CAS
    # over the full chain; failure => no start), ownership is
    # revalidated live pre-Start, and the receipt is returned only
    # after a correlated Start success (crash => pending/INDETERMINED).
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$AttemptRole = 'coder',
        [string]$SessionId = 'productive-session',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$TelemetryRoot = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [string]$Destination = 'task-kernel',
        [string]$Action = 'start-attempt',
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        $Tracker = $null,
        [switch]$Productive
    )
    try {
        if (-not [bool]$Productive) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:productive-absent'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$GoalStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:goal-store-required'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$DispatchStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:dispatch-store-required'; impl = $null }
        }
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-task-id'; impl = $null }
        }
        $oid = ([string]$OwnerId).Trim()
        $gen = Get-PALongValue $Generation -1
        if ([string]::IsNullOrWhiteSpace($oid) -or ($gen -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-fencing'; impl = $null }
        }
        $role = ([string]$AttemptRole).Trim()
        if ([string]::IsNullOrWhiteSpace($role)) { $role = 'coder' }
        $sid = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($sid)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-session'; impl = $null }
        }
        $trk = New-PATracker $Tracker
        $st = @{ task_id = $tid; role = $role; session = $sid; tasks_dir = [string]$TasksDir; flags = [string]$FlagsPath; telemetry = [string]$TelemetryRoot; owner = $oid; generation = [long]$gen; dst = [string]$Destination; act = [string]$Action; goaldir = [string]$GoalStoreDir; binddir = [string]$DispatchStoreDir; tracker = $trk; armed = $true }
        $impl = {
            param($intent, $goal, $auth)
            try {
                if (-not [bool]$st.armed) { return $null }
                $k = [string](Get-PAFieldValue $intent 'key' '')
                if ([string]::IsNullOrWhiteSpace($k)) { return $null }
                if ((Get-PALongValue (Get-PAFieldValue $intent 'generation' $null) -1) -ne [long]$st.generation) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.goaldir)) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.binddir)) { return $null }
                $dgid = ([string](Get-PAFieldValue $intent 'goal_id' '')).Trim()
                $dbwid = ([string](Get-PAFieldValue $intent 'work_item_id' '')).Trim()
                $darev = Get-PALongValue (Get-PAFieldValue $intent 'action_revision' $null) -1
                if ([string]::IsNullOrWhiteSpace($dgid) -or [string]::IsNullOrWhiteSpace($dbwid) -or ($darev -lt 1)) { return $null }
                $gst = ''
                try { $gst = (([string](Get-PAFieldValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $gst = '' }
                if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $gst) { return $null }
                $dwid = ([string](Get-PAFieldValue $intent 'work_item_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($dwid)) { return $null }
                $snapGid = ([string](Get-PAFieldValue $goal 'goal_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($snapGid) -or ($snapGid -cne $dgid)) { return $null }
                $dgate = Test-PAInCallbackGate -GoalSnapshot $goal -GoalStoreDir ([string]$st.goaldir) -OwnerId ([string]$st.owner) -Generation ([long]$st.generation) -Auth $auth -ExpectedOperation 'dispatch' -WorkItemId $dwid
                if (($null -eq $dgate) -or (-not [bool](Get-PAFieldValue $dgate 'ok' $false))) { return $null }
                try { $st.tracker['dispatch'] = ((Get-PALongValue $st.tracker['dispatch'] 0) + 1) } catch { }
                $trec = $null
                try { $trec = Get-OrchestrationTask -TaskId ([string]$st.task_id) -TasksDir ([string]$st.tasks_dir) }
                catch { $trec = $null }
                if (($null -eq $trec) -or (-not ($trec -is [System.Collections.IDictionary])) -or (-not $trec.Contains('revision'))) { return $null }
                $tstate = ''
                try { $tstate = (([string]$trec['state']).Trim().ToUpperInvariant()) } catch { $tstate = '' }
                if ($tstate -cne 'IMPLEMENTING') { return $null }
                $trev = Get-PALongValue $trec['revision'] -1
                if ($trev -lt 1) { return $null }
                $dbind = [ordered]@{
                    schema_version  = 1
                    key             = $k
                    goal_id         = $dgid
                    work_item_id    = $dbwid
                    action_revision = [long]$darev
                    task_id         = [string]$st.task_id
                    run_id          = [string]$st.session
                    attempt_role    = [string]$st.role
                    owner           = [string]$st.owner
                    generation      = [long]$st.generation
                    idempotency_key = $k
                    created_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                if (-not (Save-PABinding -Binding $dbind -Dir ([string]$st.binddir))) { return $null }
                $reown = $null
                try {
                    $reslot = Get-OrchestrationGoal -GoalId $dgid -StoreDir ([string]$st.goaldir)
                    $relive = $null
                    if (($null -ne $reslot) -and ([bool](Get-PAFieldValue $reslot 'ok' $false))) { $relive = Get-PAFieldValue $reslot 'goal' $null }
                    if ($null -ne $relive) { $reown = Test-OrchestrationGoalOwnership -Goal $relive -OwnerId ([string]$st.owner) -Generation ([long]$st.generation) }
                }
                catch { $reown = $null }
                if (($null -eq $reown) -or (-not [bool](Get-PAFieldValue $reown 'held' $false))) { return $null }
                $sa = $null
                try {
                    $sa = Start-OrchestrationTaskAttempt -TaskId ([string]$st.task_id) -AttemptRole ([string]$st.role) -SessionId ([string]$st.session) -Actor 'planner' -ExpectedRevision ([int]$trev) -ActorIdentitySource 'explicit-cli' -StrategyApproach 'productive-dispatch' -StrategyTool 'task-kernel-record' -StrategyParams @($k) -TasksDir ([string]$st.tasks_dir) -FlagsPath ([string]$st.flags) -TelemetryRoot ([string]$st.telemetry)
                }
                catch { $sa = $null }
                if (($null -eq $sa) -or (-not [bool](Get-PAFieldValue $sa 'ok' $false))) { return $null }
                $post = $null
                try { $post = Get-OrchestrationTask -TaskId ([string]$st.task_id) -TasksDir ([string]$st.tasks_dir) }
                catch { $post = $null }
                if (($null -eq $post) -or (-not ($post -is [System.Collections.IDictionary])) -or (-not $post.Contains('execution_runtime'))) { return $null }
                $prt = $null
                try { $prt = $post['execution_runtime'] } catch { $prt = $null }
                if (($null -eq $prt) -or (-not (($prt -is [System.Collections.IDictionary]) -or ($prt -is [pscustomobject])))) { return $null }
                if (([string](Get-PAFieldValue $prt 'session_id' '')).Trim() -cne ([string]$st.session)) { return $null }
                $prole = ([string](Get-PAFieldValue $prt 'attempt_role' '')).Trim()
                if ((-not [string]::IsNullOrWhiteSpace($prole)) -and ($prole -cne ([string]$st.role))) { return $null }
                if ([string]::IsNullOrWhiteSpace($prole)) { return $null }
                $res = 'attempt-started'
                try { if ([bool](Get-PAFieldValue $sa 'idempotent' $false)) { $res = 'attempt-idempotent' } } catch { }
                return [pscustomobject]@{
                    ok = $true; dispatched = $true; destination = [string]$st.dst; action = [string]$st.act
                    task_id = [string]$st.task_id; run_id = [string]$st.session; generation = [long]$st.generation
                    result = $res; idempotency_key = $k; operation = 'dispatch'; reason = 'productive-dispatch'
                }
            }
            catch { return $null }
        }.GetNewClosure()
        return [pscustomobject]@{ ok = $true; reason = ''; impl = $impl }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; impl = $null }
    }
}

function New-ProductiveSettleImpl {
    # Real settle constructor over Set-OrchestrationTaskWorkerResult.
    # Settles ONLY from a REAL worker result (status + producer +
    # evidence, producer must equal AttemptRole) bound to the live
    # attempt and the original binding + dispatch receipt (both
    # MANDATORY). The full chain
    # goal/work-item/action_revision/owner/generation/task/run/key +
    # role is REQUIRED (role absent => deny); the receipt MUST carry
    # operation dispatch + destination/action with exact provenance
    # (status/producer alone are insufficient). Without a real result
    # settlement stays pending (never fabricated). The wrapper always
    # revalidates live ownership + allow + fencing INSIDE the callback
    # (B4). GoalStoreDir AND DispatchStoreDir are REQUIRED (empty =>
    # HOLD, no impl). Without -Productive no impl is returned.
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$AttemptRole = 'coder',
        [string]$SessionId = 'productive-session',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$TelemetryRoot = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [string]$Destination = 'task-kernel',
        [string]$Action = 'worker-result',
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        [string]$WorkerStatus = '',
        [string]$WorkerProducedBy = '',
        [string[]]$WorkerEvidence = @(),
        $Tracker = $null,
        [switch]$Productive
    )
    try {
        if (-not [bool]$Productive) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:productive-absent'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$GoalStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:goal-store-required'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$DispatchStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:dispatch-store-required'; impl = $null }
        }
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-task-id'; impl = $null }
        }
        $oid = ([string]$OwnerId).Trim()
        $gen = Get-PALongValue $Generation -1
        if ([string]::IsNullOrWhiteSpace($oid) -or ($gen -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-fencing'; impl = $null }
        }
        $sid = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($sid)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-session'; impl = $null }
        }
        $srole = ([string]$AttemptRole).Trim()
        if ([string]::IsNullOrWhiteSpace($srole)) { $srole = 'coder' }
        $wev = @($WorkerEvidence)
        $trk = New-PATracker $Tracker
        $st = @{ task_id = $tid; role = $srole; session = $sid; tasks_dir = [string]$TasksDir; flags = [string]$FlagsPath; telemetry = [string]$TelemetryRoot; owner = $oid; generation = [long]$gen; dst = [string]$Destination; act = [string]$Action; goaldir = [string]$GoalStoreDir; binddir = [string]$DispatchStoreDir; worker = @{ status = ([string]$WorkerStatus); produced_by = ([string]$WorkerProducedBy); evidence = $wev }; tracker = $trk; armed = $true }
        $impl = {
            param($snap, $dispatch, $goal, $auth)
            try {
                if (-not [bool]$st.armed) { return $null }
                $k = [string](Get-PAFieldValue $snap 'key' '')
                if ([string]::IsNullOrWhiteSpace($k)) { return $null }
                if ((Get-PALongValue (Get-PAFieldValue $snap 'generation' $null) -1) -ne [long]$st.generation) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.goaldir)) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.binddir)) { return $null }
                if ([string]::IsNullOrWhiteSpace(([string]$st.role).Trim())) { return $null }
                $swid = ([string](Get-PAFieldValue $snap 'work_item_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($swid)) { return $null }
                $sgid = ([string](Get-PAFieldValue $snap 'goal_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($sgid)) { return $null }
                $sarev = Get-PALongValue (Get-PAFieldValue $snap 'action_revision' $null) -1
                if ($sarev -lt 1) { return $null }
                $snapSGid = ([string](Get-PAFieldValue $goal 'goal_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($snapSGid) -or ($snapSGid -cne $sgid)) { return $null }
                try { $st.tracker['settle'] = ((Get-PALongValue $st.tracker['settle'] 0) + 1) } catch { }
                $sgate = Test-PAInCallbackGate -GoalSnapshot $goal -GoalStoreDir ([string]$st.goaldir) -OwnerId ([string]$st.owner) -Generation ([long]$st.generation) -Auth $auth -ExpectedOperation 'settlement' -WorkItemId $swid -AllowTerminal
                if (($null -eq $sgate) -or (-not [bool](Get-PAFieldValue $sgate 'ok' $false))) { return $null }
                $swr = Test-PARealWorkerResult -Worker $st.worker -Role ([string]$st.role)
                if (($null -eq $swr) -or (-not [bool](Get-PAFieldValue $swr 'ok' $false))) { return $null }
                $wStatus = [string](Get-PAFieldValue $swr 'status' '')
                $wProd = [string](Get-PAFieldValue $swr 'produced_by' '')
                $wEv = @([string[]](Get-PAFieldValue $swr 'evidence' @()))
                $sbind = $null
                try { $sbind = Get-PABinding -Dir ([string]$st.binddir) -Key $k } catch { $sbind = $null }
                if ($null -eq $sbind) { return $null }
                if (-not (Test-PABindingComplete $sbind)) { return $null }
                if ([string](Get-PAFieldValue $sbind 'key' '') -cne $k) { return $null }
                if ([string](Get-PAFieldValue $sbind 'goal_id' '') -cne $sgid) { return $null }
                if ([string](Get-PAFieldValue $sbind 'work_item_id' '') -cne $swid) { return $null }
                if ((Get-PALongValue (Get-PAFieldValue $sbind 'action_revision' $null) -1) -ne [long]$sarev) { return $null }
                if ([string](Get-PAFieldValue $sbind 'task_id' '') -cne ([string]$st.task_id)) { return $null }
                if ([string](Get-PAFieldValue $sbind 'run_id' '') -cne ([string]$st.session)) { return $null }
                if ([string](Get-PAFieldValue $sbind 'attempt_role' '') -cne ([string]$st.role)) { return $null }
                if ([string](Get-PAFieldValue $sbind 'owner' '') -cne ([string]$st.owner)) { return $null }
                if ((Get-PALongValue (Get-PAFieldValue $sbind 'generation' $null) -1) -ne [long]$st.generation) { return $null }
                $cand = $null
                try {
                    if ((($dispatch -is [System.Collections.IDictionary]) -or ($dispatch -is [pscustomobject])) -and (-not [string]::IsNullOrWhiteSpace([string](Get-PAFieldValue $dispatch 'task_id' '')))) { $cand = $dispatch }
                    else {
                        $sr = Get-PAFieldValue $snap 'receipt' $null
                        if ((($sr -is [System.Collections.IDictionary]) -or ($sr -is [pscustomobject])) -and (-not [string]::IsNullOrWhiteSpace([string](Get-PAFieldValue $sr 'task_id' '')))) { $cand = $sr }
                    }
                }
                catch { $cand = $null }
                if ($null -eq $cand) { return $null }
                $candOp = ([string](Get-PAFieldValue $cand 'operation' '')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($candOp)) {
                    if (-not (Test-PAReceiptForBinding -Receipt $cand -Binding $sbind)) { return $null }
                }
                else {
                    $obsEff = $false
                    try { $obsEff = [bool](Get-PAFieldValue $cand 'effect_observed' $false) } catch { $obsEff = $false }
                    if (-not $obsEff) { return $null }
                    $obsDst = ([string](Get-PAFieldValue $cand 'destination' '')).Trim()
                    $obsAct = ([string](Get-PAFieldValue $cand 'action' '')).Trim()
                    if ($obsDst -cne 'task-kernel') { return $null }
                    if ((@('start-attempt', 'worker-result') -cnotcontains $obsAct)) { return $null }
                    if ([string](Get-PAFieldValue $cand 'task_id' '') -cne [string](Get-PAFieldValue $sbind 'task_id' '')) { return $null }
                    if ([string](Get-PAFieldValue $cand 'run_id' '') -cne [string](Get-PAFieldValue $sbind 'run_id' '')) { return $null }
                }
                $trec = $null
                try { $trec = Get-OrchestrationTask -TaskId ([string]$st.task_id) -TasksDir ([string]$st.tasks_dir) }
                catch { $trec = $null }
                if (($null -eq $trec) -or (-not ($trec -is [System.Collections.IDictionary])) -or (-not $trec.Contains('revision'))) { return $null }
                $attSess = ''
                $attRole = ''
                try {
                    $rt = $null
                    if ($trec.Contains('execution_runtime')) { $rt = $trec['execution_runtime'] }
                    if (($null -ne $rt) -and (($rt -is [System.Collections.IDictionary]) -or ($rt -is [pscustomobject]))) {
                        $attSess = ([string](Get-PAFieldValue $rt 'session_id' '')).Trim()
                        $attRole = ([string](Get-PAFieldValue $rt 'attempt_role' '')).Trim()
                    }
                }
                catch { $attSess = ''; $attRole = '' }
                if ([string]::IsNullOrWhiteSpace($attSess) -or ($attSess -cne ([string]$st.session))) { return $null }
                if ([string]::IsNullOrWhiteSpace($attRole) -or ($attRole -cne ([string]$st.role))) { return $null }
                $trev = Get-PALongValue $trec['revision'] -1
                if ($trev -lt 1) { return $null }
                $haveWr = $null
                try { if ($trec.Contains('worker_result')) { $haveWr = $trec['worker_result'] } } catch { $haveWr = $null }
                if (($null -ne $haveWr) -and (($haveWr -is [System.Collections.IDictionary]) -or ($haveWr -is [pscustomobject]))) {
                    $hProd = ([string](Get-PAFieldValue $haveWr 'produced_by' '')).Trim()
                    $hStat = ([string](Get-PAFieldValue $haveWr 'status' '')).Trim().ToLowerInvariant()
                    $hEv = Get-PAFieldValue $haveWr 'evidence' $null
                    if ($null -eq $hEv) { $hEv = Get-PAFieldValue $haveWr 'claimed_evidence' $null }
                    $hItems = @($hEv)
                    $evSame = $false
                    try {
                        if ((@($hItems)).Count -eq (@($wEv)).Count) {
                            $evSame = $true
                            for ($hei = 0; $hei -lt (@($wEv)).Count; $hei++) {
                                if ([string](@($hItems))[$hei] -cne [string](@($wEv))[$hei]) { $evSame = $false; break }
                            }
                        }
                    }
                    catch { $evSame = $false }
                    if (($hProd -ceq $wProd) -and ($hStat -ceq $wStatus) -and $evSame) {
                        return [pscustomobject]@{
                            ok = $true; destination = [string]$st.dst; action = [string]$st.act
                            task_id = [string]$st.task_id; run_id = [string]$st.session; generation = [long]$st.generation
                            result = 'worker-result-recorded'; produced_by = $wProd; worker_status = $wStatus
                            idempotency_key = $k; operation = 'settlement'; reason = 'productive-settle-recovered'
                        }
                    }
                    return $null
                }
                $wr = $null
                try {
                    $wr = Set-OrchestrationTaskWorkerResult -TaskId ([string]$st.task_id) -Status $wStatus -ClaimedEvidence ([string[]]$wEv) -ProducedBy $wProd -ExpectedRevision ([int]$trev) -StrategyApproach 'productive-dispatch' -StrategyTool 'task-kernel-record' -StrategyParams @($k) -TasksDir ([string]$st.tasks_dir) -FlagsPath ([string]$st.flags) -TelemetryRoot ([string]$st.telemetry)
                }
                catch { $wr = $null }
                if (($null -eq $wr) -or (-not [bool](Get-PAFieldValue $wr 'ok' $false))) { return $null }
                return [pscustomobject]@{
                    ok = $true; destination = [string]$st.dst; action = [string]$st.act
                    task_id = [string]$st.task_id; run_id = [string]$st.session; generation = [long]$st.generation
                    result = 'worker-result-recorded'; produced_by = $wProd; worker_status = $wStatus
                    idempotency_key = $k; operation = 'settlement'; reason = 'productive-settle'
                }
            }
            catch { return $null }
        }.GetNewClosure()
        return [pscustomobject]@{ ok = $true; reason = ''; impl = $impl }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; impl = $null }
    }
}

function New-ProductiveReconcileImpl {
    # Destination-consulting observation (B2): live gate first, then
    # the MANDATORY durable binding for the intent key, then a live
    # TaskKernel read of the binding task. Dispatch is observed ONLY
    # with a live attempt matching task + session + role + key (the
    # key persisted on the attempt as the strategy fingerprint of the
    # productive dispatch); the binding chain (goal, work item,
    # action revision, owner, generation) must also match the intent
    # record. Settlement is observed ONLY with a persisted
    # worker_result of the same correlation. Any divergence or
    # absence is INDETERMINATE (all false, pending). Never writes, never re-effects, never proves
    # from the diary receipt. The wrapper always revalidates live
    # ownership + allow + fencing INSIDE the callback (B4).
    # GoalStoreDir, DispatchStoreDir AND TasksDir are REQUIRED
    # (empty => HOLD, no impl). Without -Productive no impl is
    # returned.
    [CmdletBinding()]
    param([string]$GoalStoreDir = '', [string]$DispatchStoreDir = '', [string]$TasksDir = '', [string]$OwnerId = '', [long]$Generation = 0, $Tracker = $null, [switch]$Productive)
    try {
        if (-not [bool]$Productive) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:productive-absent'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$GoalStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:goal-store-required'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$DispatchStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:dispatch-store-required'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$TasksDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:tasks-dir-required'; impl = $null }
        }
        $trk = New-PATracker $Tracker
        $st = @{ goaldir = [string]$GoalStoreDir; binddir = [string]$DispatchStoreDir; tasksdir = [string]$TasksDir; owner = ([string]$OwnerId).Trim(); generation = (Get-PALongValue $Generation -1); tracker = $trk; armed = $true }
        $impl = {
            param($rec, $auth)
            try {
                if (-not [bool]$st.armed) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.goaldir)) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.binddir)) { return $null }
                if ([string]::IsNullOrWhiteSpace([string]$st.tasksdir)) { return $null }
                try { $st.tracker['reconcile'] = ((Get-PALongValue $st.tracker['reconcile'] 0) + 1) } catch { }
                if ($null -eq $rec) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:no-record' }
                }
                $rk = ([string](Get-PAFieldValue $rec 'key' '')).Trim().ToLowerInvariant()
                $rwid = ([string](Get-PAFieldValue $rec 'work_item_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($rk) -or [string]::IsNullOrWhiteSpace($rwid)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:invalid-record' }
                }
                $rgate = Test-PAInCallbackGate -GoalSnapshot $rec -GoalStoreDir ([string]$st.goaldir) -OwnerId ([string]$st.owner) -Generation ([long]$st.generation) -Auth $auth -ExpectedOperation 'reconcile' -WorkItemId $rwid -AllowTerminal
                if (($null -eq $rgate) -or (-not [bool](Get-PAFieldValue $rgate 'ok' $false))) { return $null }
                $rbind = $null
                try { $rbind = Get-PABinding -Dir ([string]$st.binddir) -Key $rk } catch { $rbind = $null }
                if ($null -eq $rbind) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:no-binding' }
                }
                if (-not (Test-PABindingComplete $rbind)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:binding-incomplete' }
                }
                if ([string](Get-PAFieldValue $rbind 'key' '') -cne $rk) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:binding-key-mismatch' }
                }
                $recGid = ([string](Get-PAFieldValue $rec 'goal_id' '')).Trim()
                $recWid = ([string](Get-PAFieldValue $rec 'work_item_id' '')).Trim()
                $recRev = Get-PALongValue (Get-PAFieldValue $rec 'action_revision' $null) -1
                $recOwn = ([string](Get-PAFieldValue $rec 'owner' '')).Trim()
                $recGen = Get-PALongValue (Get-PAFieldValue $rec 'generation' $null) -1
                if (([string](Get-PAFieldValue $rbind 'goal_id' '') -cne $recGid) -or ([string](Get-PAFieldValue $rbind 'work_item_id' '') -cne $recWid) -or ((Get-PALongValue (Get-PAFieldValue $rbind 'action_revision' $null) -1) -ne [long]$recRev)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:binding-chain-mismatch' }
                }
                if (([string](Get-PAFieldValue $rbind 'owner' '') -cne $recOwn) -or ((Get-PALongValue (Get-PAFieldValue $rbind 'generation' $null) -1) -ne [long]$recGen)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:binding-fencing-mismatch' }
                }
                if ([string]::IsNullOrWhiteSpace(([string](Get-PAFieldValue $rbind 'attempt_role' '')).Trim())) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:binding-role-missing' }
                }
                $rtask = ([string](Get-PAFieldValue $rbind 'task_id' '')).Trim()
                $rrun = ([string](Get-PAFieldValue $rbind 'run_id' '')).Trim()
                $rrole = ([string](Get-PAFieldValue $rbind 'attempt_role' '')).Trim()
                $rdst = 'task-kernel'
                $ract = 'start-attempt'
                $rt = $null
                try { $rt = Get-OrchestrationTask -TaskId $rtask -TasksDir ([string]$st.tasksdir) }
                catch { $rt = $null }
                if (($null -eq $rt) -or (-not ($rt -is [System.Collections.IDictionary])) -or (-not $rt.Contains('revision'))) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:no-destination-record' }
                }
                $rert = $null
                try { if ($rt.Contains('execution_runtime')) { $rert = $rt['execution_runtime'] } } catch { $rert = $null }
                if (($null -eq $rert) -or (-not (($rert -is [System.Collections.IDictionary]) -or ($rert -is [pscustomobject])))) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:no-attempt' }
                }
                $rsess = ([string](Get-PAFieldValue $rert 'session_id' '')).Trim()
                $rAttRole = ([string](Get-PAFieldValue $rert 'attempt_role' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($rsess) -or ($rsess -cne $rrun)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:session-mismatch' }
                }
                if ([string]::IsNullOrWhiteSpace($rAttRole) -or ($rAttRole -cne $rrole)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:role-mismatch' }
                }
                $rkFp = $null
                try { $rkFp = Resolve-TaskKernelStrategyFingerprint -Approach 'productive-dispatch' -ToolOrPath 'task-kernel-record' -KeyParams @($rk) } catch { $rkFp = $null }
                $rkFpVal = ''
                try {
                    if (($null -ne $rkFp) -and [bool](Get-PAFieldValue $rkFp 'ok' $false)) { $rkFpVal = [string](Get-PAFieldValue $rkFp 'fingerprint' '') }
                }
                catch { $rkFpVal = '' }
                $dstFpVal = ''
                try {
                    $rkGe = Get-PAFieldValue $rert 'gate_evidence' $null
                    if (($null -ne $rkGe) -and (($rkGe -is [System.Collections.IDictionary]) -or ($rkGe -is [pscustomobject]))) {
                        $dstFpVal = [string](Get-PAFieldValue $rkGe 'strategy_fingerprint' '')
                    }
                }
                catch { $dstFpVal = '' }
                $rkFpNorm = ''
                $dstFpNorm = ''
                try { $rkFpNorm = ConvertTo-TaskKernelFingerprint -Value $rkFpVal } catch { $rkFpNorm = '' }
                try { $dstFpNorm = ConvertTo-TaskKernelFingerprint -Value $dstFpVal } catch { $dstFpNorm = '' }
                if ([string]::IsNullOrWhiteSpace($rkFpNorm) -or [string]::IsNullOrWhiteSpace($dstFpNorm) -or ($dstFpNorm -cne $rkFpNorm)) {
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:attempt-key-mismatch' }
                }
                $rwr = $null
                try { if ($rt.Contains('worker_result')) { $rwr = $rt['worker_result'] } } catch { $rwr = $null }
                if (($null -ne $rwr) -and (($rwr -is [System.Collections.IDictionary]) -or ($rwr -is [pscustomobject]))) {
                    $rwStat = ([string](Get-PAFieldValue $rwr 'status' '')).Trim().ToLowerInvariant()
                    $rwProd = ([string](Get-PAFieldValue $rwr 'produced_by' '')).Trim()
                    $rwEv = Get-PAFieldValue $rwr 'evidence' $null
                    if ($null -eq $rwEv) { $rwEv = Get-PAFieldValue $rwr 'claimed_evidence' $null }
                    $rwOk = ((@('candidate_pass', 'failed', 'blocked') -ccontains $rwStat) -and ($rwProd -ceq $rrole) -and ($null -ne $rwEv) -and ((@($rwEv)).Count -gt 0))
                    if ($rwOk) {
                        return [pscustomobject]@{ ok = $true; effect_observed = $true; destination = $rdst; action = 'worker-result'; task_id = $rtask; run_id = $rrun; reason = 'productive-reconciled-settlement' }
                    }
                    return [pscustomobject]@{ ok = $true; effect_observed = $false; no_effect_proven = $false; no_capable_request = $false; reason = 'productive-reconcile-indeterminate:worker-result-mismatch' }
                }
                return [pscustomobject]@{ ok = $true; effect_observed = $true; destination = $rdst; action = $ract; task_id = $rtask; run_id = $rrun; reason = 'productive-reconciled-effect' }
            }
            catch { return $null }
        }.GetNewClosure()
        return [pscustomobject]@{ ok = $true; reason = ''; impl = $impl }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; impl = $null }
    }
}

function New-ProductiveCheckpointImpl {
    # Real checkpoint constructor over GoalCheckpoint save/load. The id
    # is returned only after a load round-trip proves durability.
    # Ownership viva + fencing are revalidated INSIDE the callback
    # (B4) from the LIVE store record (live-only; GoalStoreDir empty
    # => deny). Without -Productive no impl is returned.
    [CmdletBinding()]
    param([string]$CheckpointStoreDir = '', [string]$GoalStoreDir = '', [string]$OwnerId = '', [long]$Generation = 0, $Tracker = $null, [switch]$Productive)
    try {
        if (-not [bool]$Productive) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:productive-absent'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$CheckpointStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-checkpoint-store'; impl = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$GoalStoreDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:goal-store-required'; impl = $null }
        }
        $trk = New-PATracker $Tracker
        $st = @{ dir = [string]$CheckpointStoreDir; goaldir = [string]$GoalStoreDir; owner = ([string]$OwnerId).Trim(); generation = (Get-PALongValue $Generation -1); tracker = $trk; armed = $true }
        $impl = {
            param($goal)
            try {
                if (-not [bool]$st.armed) { return '' }
                $cgid = ([string](Get-PAFieldValue $goal 'goal_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($cgid)) { return '' }
                if ([string]::IsNullOrWhiteSpace([string]$st.goaldir)) { return '' }
                $cslot = $null
                try { $cslot = Get-OrchestrationGoal -GoalId $cgid -StoreDir ([string]$st.goaldir) } catch { $cslot = $null }
                if (($null -eq $cslot) -or (-not [bool](Get-PAFieldValue $cslot 'ok' $false))) { return '' }
                $clive = Get-PAFieldValue $cslot 'goal' $null
                if ($null -eq $clive) { return '' }
                $cown = $null
                try { $cown = Test-OrchestrationGoalOwnership -Goal $clive -OwnerId ([string]$st.owner) -Generation ([long]$st.generation) } catch { $cown = $null }
                if (($null -eq $cown) -or (-not [bool](Get-PAFieldValue $cown 'held' $false))) { return '' }
                try { $st.tracker['checkpoint'] = ((Get-PALongValue $st.tracker['checkpoint'] 0) + 1) } catch { }
                $cp = $null
                try { $cp = New-OrchestrationGoalCheckpoint -GoalRecord $goal }
                catch { $cp = $null }
                if ($null -eq $cp) { return '' }
                $sv = $null
                try { $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $cp -StoreDir ([string]$st.dir) }
                catch { $sv = $null }
                if (($null -eq $sv) -or (-not [bool](Get-PAFieldValue $sv 'ok' $false))) { return '' }
                $cid = [string](Get-PAFieldValue $sv 'checkpoint_id' '')
                if ([string]::IsNullOrWhiteSpace($cid)) { return '' }
                $ld = $null
                try { $ld = Load-OrchestrationGoalCheckpoint -CheckpointId $cid -StoreDir ([string]$st.dir) }
                catch { $ld = $null }
                if (($null -eq $ld) -or (-not [bool](Get-PAFieldValue $ld 'ok' $false))) { return '' }
                return [pscustomobject]@{ checkpoint_id = $cid }
            }
            catch { return '' }
        }.GetNewClosure()
        return [pscustomobject]@{ ok = $true; reason = ''; impl = $impl }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; impl = $null }
    }
}

function Add-PAProductiveNote {
    param($Result, [string]$Mode = '', $Tracker = $null)
    try {
        if ($null -eq $Result) { return $null }
        try {
            $Result | Add-Member -NotePropertyName 'productive' -NotePropertyValue ([string]$Mode) -Force
            $Result | Add-Member -NotePropertyName 'productive_dispatch_calls' -NotePropertyValue ([long](Get-PATrackerCount $Tracker 'dispatch')) -Force
            $Result | Add-Member -NotePropertyName 'productive_settle_calls' -NotePropertyValue ([long](Get-PATrackerCount $Tracker 'settle')) -Force
            $Result | Add-Member -NotePropertyName 'productive_reconcile_calls' -NotePropertyValue ([long](Get-PATrackerCount $Tracker 'reconcile')) -Force
            $Result | Add-Member -NotePropertyName 'productive_checkpoint_calls' -NotePropertyValue ([long](Get-PATrackerCount $Tracker 'checkpoint')) -Force
        }
        catch { }
        return $Result
    }
    catch { return $Result }
}

function Invoke-ProductiveObjectiveEvent {
    # Explicit productive entry point for one executor event.
    # Without -Productive the executor runs its current intact path
    # (no impl, no TestCallback, zero invocations). With -Productive
    # the gate must admit before any real impl is built or invoked.
    [CmdletBinding()]
    param(
        $Event = $null,
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        [string]$CheckpointStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$TelemetryRoot = '',
        [string]$TaskId = '',
        [string]$AttemptRole = 'coder',
        [string]$SessionId = 'productive-session',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [long]$ExpectedRevision = 0,
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [string]$BudgetScope = 'worker',
        [bool]$BudgetExhausted = $false,
        [string]$WorkerStatus = '',
        [string]$WorkerProducedBy = '',
        [string[]]$WorkerEvidence = @(),
        $Tracker = $null,
        [switch]$Productive
    )
    try {
        $trk = New-PATracker $Tracker
        if (-not [bool]$Productive) {
            $held = $null
            try {
                $held = Invoke-OrchestrationObjectiveEvent -Event $Event -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -User $User -Project $Project -Runtime $Runtime -Grants $Grants -BudgetScope $BudgetScope -BudgetExhausted ([bool]$BudgetExhausted)
            }
            catch { $held = $null }
            if ($null -eq $held) {
                $held = [pscustomobject]@{ ok = $true; reason = 'hold-productive-disabled:productive-absent'; dispatched = $false; decision = 'held'; grants_authority = $false; done_approved = $false; verified_pass = $false }
            }
            return (Add-PAProductiveNote $held 'hold-productive-disabled:productive-absent' $trk)
        }
        $gid = [string](Get-PAFieldValue $Event 'goal_id' '')
        $wid = [string](Get-PAFieldValue $Event 'work_item_id' '')
        $arev = Get-PALongValue (Get-PAFieldValue $Event 'action_revision' $null) -1
        $gate = Test-ProductiveGate -GoalId $gid -OwnerId $OwnerId -Generation $Generation -GoalStoreDir $GoalStoreDir -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'dispatch' -Resource $wid -Productive:$Productive
        if (($null -eq $gate) -or (-not [bool](Get-PAFieldValue $gate 'ok' $false))) {
            $why = 'hold-productive-disabled:gate-denied'
            try { if (($null -ne $gate) -and (-not [string]::IsNullOrWhiteSpace([string]$gate.reason))) { $why = [string]$gate.reason } } catch { }
            $h = [pscustomobject]@{ ok = $false; reason = $why; dispatched = $false; duplicate = $false; decision = 'blocked'; grants_authority = $false; done_approved = $false; verified_pass = $false }
            return (Add-PAProductiveNote $h $why $trk)
        }
        $key = ''
        try { $key = Get-OrchestrationObjectiveIdempotencyKey -GoalId $gid -WorkItemId $wid -ActionRevision $arev }
        catch { $key = '' }
        if ([string]::IsNullOrWhiteSpace($key)) {
            $h = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:invalid-event'; dispatched = $false; duplicate = $false; decision = 'blocked'; grants_authority = $false; done_approved = $false; verified_pass = $false }
            return (Add-PAProductiveNote $h 'hold-productive-disabled:invalid-event' $trk)
        }
        $dProof = New-PAProof -Destination 'task-kernel' -Action 'start-attempt' -OwnerId $OwnerId -Generation $Generation -Key $key
        $sProof = New-PAProof -Destination 'task-kernel' -Action 'worker-result' -OwnerId $OwnerId -Generation $Generation -Key $key
        $effWStatus = ([string]$WorkerStatus).Trim().ToLowerInvariant()
        $effWProd = ([string]$WorkerProducedBy).Trim()
        $effWEv = @($WorkerEvidence)
        if ([string]::IsNullOrWhiteSpace($effWStatus)) {
            $fromEv = $null
            try { $fromEv = Get-PAWorkerResultFromEvent -Event $Event } catch { $fromEv = $null }
            if ($null -ne $fromEv) {
                $effWStatus = ([string](Get-PAFieldValue $fromEv 'status' '')).Trim().ToLowerInvariant()
                $effWProd = ([string](Get-PAFieldValue $fromEv 'produced_by' '')).Trim()
                $tmpEv = Get-PAFieldValue $fromEv 'evidence' $null
                if ($null -eq $tmpEv) { $tmpEv = Get-PAFieldValue $fromEv 'claimed_evidence' $null }
                if ($null -ne $tmpEv) { $effWEv = @($tmpEv) }
            }
        }
        $d = New-ProductiveDispatchImpl -TaskId $TaskId -AttemptRole $AttemptRole -SessionId $SessionId -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot -OwnerId $OwnerId -Generation $Generation -Destination 'task-kernel' -Action 'start-attempt' -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -Tracker $trk -Productive:$Productive
        $s = New-ProductiveSettleImpl -TaskId $TaskId -AttemptRole $AttemptRole -SessionId $SessionId -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot -OwnerId $OwnerId -Generation $Generation -Destination 'task-kernel' -Action 'worker-result' -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -WorkerStatus $effWStatus -WorkerProducedBy $effWProd -WorkerEvidence $effWEv -Tracker $trk -Productive:$Productive
        $c = New-ProductiveCheckpointImpl -CheckpointStoreDir $CheckpointStoreDir -GoalStoreDir $GoalStoreDir -OwnerId $OwnerId -Generation $Generation -Tracker $trk -Productive:$Productive
        if (($null -eq $d) -or (-not [bool](Get-PAFieldValue $d 'ok' $false)) -or ($null -eq $s) -or (-not [bool](Get-PAFieldValue $s 'ok' $false)) -or ($null -eq $c) -or (-not [bool](Get-PAFieldValue $c 'ok' $false))) {
            $h = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:impl-unavailable'; dispatched = $false; duplicate = $false; decision = 'blocked'; grants_authority = $false; done_approved = $false; verified_pass = $false }
            return (Add-PAProductiveNote $h 'hold-productive-disabled:impl-unavailable' $trk)
        }
        $r = $null
        try {
            $r = Invoke-OrchestrationObjectiveEvent -Event $Event -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -User $User -Project $Project -Runtime $Runtime -Grants $Grants -BudgetScope $BudgetScope -BudgetExhausted ([bool]$BudgetExhausted) -DispatchImpl $d.impl -SettleImpl $s.impl -CheckpointImpl $c.impl -DispatchProof $dProof -SettleProof $sProof -TestCallback
        }
        catch { $r = $null }
        if ($null -eq $r) {
            $r = [pscustomobject]@{ ok = $false; reason = 'internal-error'; dispatched = $false; duplicate = $false; decision = 'blocked'; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        return (Add-PAProductiveNote $r 'engaged' $trk)
    }
    catch {
        $h = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; dispatched = $false; duplicate = $false; decision = 'blocked'; grants_authority = $false; done_approved = $false; verified_pass = $false }
        try { return (Add-PAProductiveNote $h 'hold-productive-disabled:internal-error' $Tracker) } catch { return $h }
    }
}

function Invoke-ProductiveObjectiveReconcile {
    # Explicit productive entry point for crash recovery. Pure
    # observation + kernel settle; never a new dispatch. Without
    # -Productive the executor runs its current intact path.
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$TelemetryRoot = '',
        [string]$TaskId = '',
        [string]$AttemptRole = 'coder',
        [string]$SessionId = 'productive-session',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [long]$ExpectedRevision = 0,
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [string]$WorkerStatus = '',
        [string]$WorkerProducedBy = '',
        [string[]]$WorkerEvidence = @(),
        $Tracker = $null,
        $SettleProof = $null,
        [switch]$Productive
    )
    try {
        $trk = New-PATracker $Tracker
        if (-not [bool]$Productive) {
            $held = $null
            try {
                $held = Invoke-OrchestrationObjectiveReconcile -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -User $User -Project $Project -Runtime $Runtime -Grants $Grants
            }
            catch { $held = $null }
            if ($null -eq $held) {
                $held = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:productive-absent'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
            }
            return (Add-PAProductiveNote $held 'hold-productive-disabled:productive-absent' $trk)
        }
        $gate = Test-ProductiveGate -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation -GoalStoreDir $GoalStoreDir -User $User -Project $Project -Runtime $Runtime -Grants $Grants -Operation 'reconcile' -Resource $GoalId -Productive:$Productive
        if (($null -eq $gate) -or (-not [bool](Get-PAFieldValue $gate 'ok' $false))) {
            $why = 'hold-productive-disabled:gate-denied'
            try { if (($null -ne $gate) -and (-not [string]::IsNullOrWhiteSpace([string]$gate.reason))) { $why = [string]$gate.reason } } catch { }
            $h = [pscustomobject]@{ ok = $false; reason = $why; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
            return (Add-PAProductiveNote $h $why $trk)
        }
        $rc = New-ProductiveReconcileImpl -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -TasksDir $TasksDir -OwnerId $OwnerId -Generation $Generation -Tracker $trk -Productive:$Productive
        $st = New-ProductiveSettleImpl -TaskId $TaskId -AttemptRole $AttemptRole -SessionId $SessionId -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TelemetryRoot -OwnerId $OwnerId -Generation $Generation -Destination 'task-kernel' -Action 'worker-result' -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -WorkerStatus $WorkerStatus -WorkerProducedBy $WorkerProducedBy -WorkerEvidence $WorkerEvidence -Tracker $trk -Productive:$Productive
        if (($null -eq $rc) -or (-not [bool](Get-PAFieldValue $rc 'ok' $false)) -or ($null -eq $st) -or (-not [bool](Get-PAFieldValue $st 'ok' $false))) {
            $h = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:impl-unavailable'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
            return (Add-PAProductiveNote $h 'hold-productive-disabled:impl-unavailable' $trk)
        }
        $r = $null
        try {
            $r = Invoke-OrchestrationObjectiveReconcile -GoalId $GoalId -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $ExpectedRevision -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -ReconcileImpl $rc.impl -SettleImpl $st.impl -User $User -Project $Project -Runtime $Runtime -Grants $Grants -SettleProof $SettleProof -TestCallback
        }
        catch { $r = $null }
        if ($null -eq $r) {
            $r = [pscustomobject]@{ ok = $false; reason = 'internal-error'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        return (Add-PAProductiveNote $r 'engaged' $trk)
    }
    catch {
        $h = [pscustomobject]@{ ok = $false; reason = 'hold-productive-disabled:internal-error'; reconciled = 0; settled = 0; redispatched = 0; holds = 0; grants_authority = $false; done_approved = $false; verified_pass = $false }
        try { return (Add-PAProductiveNote $h 'hold-productive-disabled:internal-error' $Tracker) } catch { return $h }
    }
}
