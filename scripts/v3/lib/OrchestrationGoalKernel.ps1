<#!
.SYNOPSIS
    V3 Goal Kernel: durable Goal persistence above the TaskKernel (SPEC v0.1.0 Phase 6).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure store + transition
    helpers, fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns an object with ok=$false and a
    machine-readable reason. No network, no process, no grants, no leases,
    no verification.

    TDR-F6-01: Goal record (ordered): schema_version=1, goal_id
    (^[A-Za-z0-9._:-]{1,64}$), objective, criteria @(), verification_surfaces
    @(), state, revision [long], budget @{soft_cap, hard_cap, spent},
    progress @{satisfied, total, updated_at}, plan_progress
    @{phase, total_phases, done_tasks}, evidence_refs @(), decision_refs @(),
    failed_strategies @(), active_tasks @(), completed_tasks @(), blockers @(),
    risks @(), next_move @{}, checkpoint_revision [long], created_at,
    updated_at. States: DRAFT ACTIVE PAUSED BLOCKED BUDGET_LIMITED COMPLETED
    EXHAUSTED CANCELLED; terminals COMPLETED EXHAUSTED CANCELLED (immutable
    once terminal). All mutations bump revision by 1 and refresh updated_at.

    TDR-F6-02: the declarative contract lives in
    source/registry/goal-policy.json (states, terminal, transitions,
    budget_fields). The transition table below must match it exactly
    (asserted by the suite); the JSON is the readable policy, this lib is
    the enforcement.

    TDR-F6-03 DEVIATION (recorded, not implemented): the TaskKernel is NOT
    touched in this phase. goal_id / goal_iteration / work_item_id /
    decision_ref live in the Goal record and in dispatch contracts, never in
    the kernel record. No kernel file was read for write, only for style.

    Next-move delegation (TDR-F6-01): Get-OrchestrationGoalNextMove derives a
    controller status snapshot from the Goal and delegates to
    Get-OrchestrationNextMove from OrchestrationObjectiveController.ps1 via
    lazy dot-source. The controller list is never duplicated here. When the
    controller file (or command) is unavailable the function returns
    ok=$false reason 'controller-unavailable' with no next_move (never throws).

    File layout: one JSON file per goal in <StoreDir>, default
    <repoRoot>/cache/goal-store (same idiom as TDR-F3-01). The file name is
    the lowercase goal_id with ':' mapped to '=' ('=' is outside the goal_id
    charset, so the mapping is injective; ':' would create an ADS path via
    .NET IO). Identity is case-insensitive: New rejects a canonical
    collision ('duplicate-goal-id') and reads compare -ieq.
    Writes are atomic (temp+move) while holding an exclusive '.goal.lock'
    file lock with a bounded retry, mirroring OrchestrationEvidenceStore.
#>
[CmdletBinding()]
param()

function Get-OrchestrationGoalStoreDir {
    [CmdletBinding()]
    param([string]$StoreDir = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($StoreDir)) { return ([string]$StoreDir) }
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        if ([string]::IsNullOrWhiteSpace($repoRoot)) { return '' }
        $dir = Join-Path (Join-Path $repoRoot 'cache') 'goal-store'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($dir)
        }
        return $dir
    }
    catch { return '' }
}

function Get-OrchestrationGoalStates {
    [CmdletBinding()]
    param()
    return @('DRAFT', 'ACTIVE', 'PAUSED', 'BLOCKED', 'BUDGET_LIMITED', 'COMPLETED', 'EXHAUSTED', 'CANCELLED')
}

function Get-OrchestrationGoalTerminalStates {
    [CmdletBinding()]
    param()
    return @('COMPLETED', 'EXHAUSTED', 'CANCELLED')
}

function Get-GKGoalTransitions {
    try {
        return @{
            'DRAFT'         = @('ACTIVE', 'CANCELLED')
            'ACTIVE'        = @('PAUSED', 'BLOCKED', 'BUDGET_LIMITED', 'COMPLETED', 'EXHAUSTED', 'CANCELLED')
            'PAUSED'        = @('ACTIVE', 'CANCELLED')
            'BLOCKED'       = @('ACTIVE', 'CANCELLED')
            'BUDGET_LIMITED' = @('ACTIVE', 'EXHAUSTED', 'CANCELLED')
            'COMPLETED'     = @()
            'EXHAUSTED'     = @()
            'CANCELLED'     = @()
        }
    }
    catch { return @{} }
}

function Test-OrchestrationGoalTransition {
    [CmdletBinding()]
    param([string]$From = '', [string]$To = '')
    try {
        $f = ([string]$From).Trim().ToUpperInvariant()
        $t = ([string]$To).Trim().ToUpperInvariant()
        $table = Get-GKGoalTransitions
        if (-not $table.ContainsKey($f)) { return $false }
        foreach ($allowed in @($table[$f])) {
            if ($t -ceq ([string]$allowed)) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-GKGoalId {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,64}$')
    }
    catch { return $false }
}

function Get-GKGoalValue {
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

function Get-GKGoalLong {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [short]) { return [long]$Value }
        return $Default
    }
    catch { return $Default }
}

function Get-GKGoalStringList {
    param($Value)
    # NOTE: empty arrays collapse to $null both when passed as an argument
    # and when returned (PS Sweet: f @() arrives as $null, return @()
    # reads back as $null). Every return below is comma-wrapped so the
    # caller always receives a real array; $null input means empty (valid).
    try {
        if ($null -eq $Value) { return ,([string[]]@()) }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return ,([string[]]@()) }
            return ,([string[]]@([string]$Value))
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($item in @($Value)) {
            if ($item -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item)) { [void]$out.Add([string]$item) }
            }
            else { return $null }
        }
        return ,([string[]]$out.ToArray())
    }
    catch { return $null }
}

function Get-GKGoalStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

# Canonical instant reader: dates are stored as ISO 'o' strings, but
# ConvertFrom-Json on PS7+ hydrates them into [DateTime]. Canonicalize
# both shapes back to 'o' so a save/load roundtrip is byte-identical on
# either engine. Unspecified-kind dates fail closed to '' (invalid).
function Get-GKGoalInstant {
    param($Value)
    try {
        if ($null -eq $Value) { return '' }
        if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime.ToString('o') }
        if ($Value -is [DateTime]) {
            $dt = [DateTime]$Value
            if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return '' }
            return $dt.ToUniversalTime().ToString('o')
        }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        return $s
    }
    catch { return '' }
}

function ConvertTo-GKGoalRecord {
    param($Goal)
    try {
        $gid = [string](Get-GKGoalValue $Goal 'goal_id' '')
        if (-not (Test-GKGoalId $gid)) { return $null }
        $sv = Get-GKGoalLong (Get-GKGoalValue $Goal 'schema_version' $null) -1
        if ($sv -ne 1) { return $null }
        $obj = [string](Get-GKGoalValue $Goal 'objective' '')
        if ([string]::IsNullOrWhiteSpace($obj)) { return $null }
        $criteria = Get-GKGoalStringList (Get-GKGoalValue $Goal 'criteria' @())
        if ($null -eq $criteria) { return $null }
        $surfaces = Get-GKGoalStringList (Get-GKGoalValue $Goal 'verification_surfaces' @())
        if ($null -eq $surfaces) { return $null }
        $state = ([string](Get-GKGoalValue $Goal 'state' '')).Trim().ToUpperInvariant()
        if (@(Get-OrchestrationGoalStates) -cnotcontains $state) { return $null }
        $rev = Get-GKGoalLong (Get-GKGoalValue $Goal 'revision' $null) -1
        if ($rev -lt 1) { return $null }
        $ckpt = Get-GKGoalLong (Get-GKGoalValue $Goal 'checkpoint_revision' $null) -1
        if ($ckpt -lt 0) { return $null }
        $rawBudget = Get-GKGoalValue $Goal 'budget' $null
        if ($null -eq $rawBudget) { return $null }
        $soft = Get-GKGoalLong (Get-GKGoalValue $rawBudget 'soft_cap' $null) -1
        $hard = Get-GKGoalLong (Get-GKGoalValue $rawBudget 'hard_cap' $null) -1
        $spent = Get-GKGoalLong (Get-GKGoalValue $rawBudget 'spent' $null) -1
        if ($soft -lt 0 -or $hard -lt 0 -or $spent -lt 0) { return $null }
        $rawProgress = Get-GKGoalValue $Goal 'progress' $null
        if ($null -eq $rawProgress) { return $null }
        $sat = Get-GKGoalLong (Get-GKGoalValue $rawProgress 'satisfied' $null) -1
        $tot = Get-GKGoalLong (Get-GKGoalValue $rawProgress 'total' $null) -1
        if ($sat -lt 0 -or $tot -lt 0 -or $sat -gt $tot) { return $null }
        $progAt = Get-GKGoalInstant (Get-GKGoalValue $rawProgress 'updated_at' '')
        if ([string]::IsNullOrWhiteSpace($progAt)) { return $null }
        $rawPlan = Get-GKGoalValue $Goal 'plan_progress' $null
        if ($null -eq $rawPlan) { return $null }
        $phase = Get-GKGoalLong (Get-GKGoalValue $rawPlan 'phase' $null) -1
        $tph = Get-GKGoalLong (Get-GKGoalValue $rawPlan 'total_phases' $null) -1
        $done = Get-GKGoalLong (Get-GKGoalValue $rawPlan 'done_tasks' $null) -1
        if ($phase -lt 0 -or $tph -lt 0 -or $done -lt 0) { return $null }
        $evRefs = Get-GKGoalStringList (Get-GKGoalValue $Goal 'evidence_refs' @())
        if ($null -eq $evRefs) { return $null }
        $decRefs = Get-GKGoalStringList (Get-GKGoalValue $Goal 'decision_refs' @())
        if ($null -eq $decRefs) { return $null }
        $failed = Get-GKGoalStringList (Get-GKGoalValue $Goal 'failed_strategies' @())
        if ($null -eq $failed) { return $null }
        $active = Get-GKGoalStringList (Get-GKGoalValue $Goal 'active_tasks' @())
        if ($null -eq $active) { return $null }
        $completed = Get-GKGoalStringList (Get-GKGoalValue $Goal 'completed_tasks' @())
        if ($null -eq $completed) { return $null }
        foreach ($tid in @($active + $completed)) {
            if (-not (Test-GKGoalId $tid)) { return $null }
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($tid in @($active)) {
            if ($seen.Contains($tid)) { return $null }
            [void]$seen.Add($tid)
        }
        foreach ($tid in @($completed)) {
            if ($seen.Contains($tid)) { return $null }
            [void]$seen.Add($tid)
        }
        $blockers = Get-GKGoalStringList (Get-GKGoalValue $Goal 'blockers' @())
        if ($null -eq $blockers) { return $null }
        $risks = Get-GKGoalStringList (Get-GKGoalValue $Goal 'risks' @())
        if ($null -eq $risks) { return $null }
        $rawNext = Get-GKGoalValue $Goal 'next_move' $null
        $nextMove = [ordered]@{}
        if ($null -ne $rawNext) {
            if (($rawNext -is [System.Collections.IDictionary]) -or ($rawNext -is [pscustomobject])) {
                if ($rawNext -is [System.Collections.IDictionary]) {
                    foreach ($k in $rawNext.Keys) { $nextMove[[string]$k] = $rawNext[$k] }
                }
                else {
                    foreach ($p in $rawNext.PSObject.Properties) { $nextMove[$p.Name] = $p.Value }
                }
            }
            else { return $null }
        }
        $created = Get-GKGoalInstant (Get-GKGoalValue $Goal 'created_at' '')
        $updated = Get-GKGoalInstant (Get-GKGoalValue $Goal 'updated_at' '')
        if ([string]::IsNullOrWhiteSpace($created) -or [string]::IsNullOrWhiteSpace($updated)) { return $null }
        $rec = [ordered]@{
            schema_version         = 1
            goal_id                = $gid
            objective              = $obj
            criteria               = @($criteria)
            verification_surfaces  = @($surfaces)
            state                  = $state
            revision               = [long]$rev
            budget                 = [ordered]@{ soft_cap = [long]$soft; hard_cap = [long]$hard; spent = [long]$spent }
            progress               = [ordered]@{ satisfied = [long]$sat; total = [long]$tot; updated_at = $progAt }
            plan_progress          = [ordered]@{ phase = [long]$phase; total_phases = [long]$tph; done_tasks = [long]$done }
            evidence_refs          = @($evRefs)
            decision_refs          = @($decRefs)
            failed_strategies      = @($failed)
            active_tasks           = @($active)
            completed_tasks        = @($completed)
            blockers               = @($blockers)
            risks                  = @($risks)
            next_move              = $nextMove
            checkpoint_revision    = [long]$ckpt
            created_at             = $created
            updated_at             = $updated
        }
        return $rec
    }
    catch { return $null }
}

function Copy-GKGoalRecord {
    param($Goal)
    try {
        $valid = ConvertTo-GKGoalRecord $Goal
        if ($null -eq $valid) { return $null }
        $json = ConvertTo-Json -InputObject $valid -Depth 20 -Compress
        $back = ConvertFrom-Json $json
        return (ConvertTo-GKGoalRecord $back)
    }
    catch { return $null }
}

function Get-GKGoalFilePath {
    param([string]$StoreDir, [string]$GoalId)
    try {
        # Canonical filename: lowercase identity, ':' mapped to '=' ('='
        # is outside the goal_id charset, so the mapping stays injective).
        $safe = (([string]$GoalId).ToLowerInvariant() -replace ':', '=')
        return (Join-Path $StoreDir ($safe + '.json'))
    }
    catch { return '' }
}

# Internal lock + atomic-write helpers shared by Save and Update.
# Save-OrchestrationGoal is last-writer-wins BY DESIGN for direct writes;
# Update-OrchestrationGoal performs the atomic CAS path (lock -> read ->
# check ExpectedRevision -> mutate -> write under the SAME lock).
function Open-GKGoalLock {
    param([string]$Dir, [int]$LockTimeoutMs = 500)
    try {
        $lockPath = Join-Path $Dir '.goal.lock'
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

function Write-GKGoalRecordAtomic {
    param([string]$Dir, $Rec)
    try {
        $gid = [string]$Rec['goal_id']
        $path = Get-GKGoalFilePath -StoreDir $Dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; path = '' }
        }
        $json = ConvertTo-Json -InputObject $Rec -Depth 20 -Compress
        $tmp = Join-Path $Dir (('goal-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try {
            [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'goal-write-failed'; path = '' }
        }
        try {
            Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return [pscustomobject]@{ ok = $false; reason = 'goal-write-failed'; path = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; path = $path }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'goal-write-failed'; path = '' }
    }
}

function New-OrchestrationGoal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GoalId,
        [Parameter(Mandatory = $true)][string]$Objective,
        [string[]]$Criteria = @(),
        [string[]]$VerificationSurfaces = @(),
        [long]$SoftCap = 0,
        [long]$HardCap = 0,
        [long]$TotalPhases = 0,
        [string]$StoreDir = ''
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-GKGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; goal = $null }
        }
        try {
            $dupDir = Get-OrchestrationGoalStoreDir -StoreDir $StoreDir
            if (-not [string]::IsNullOrWhiteSpace($dupDir)) {
                $canon = Get-GKGoalFilePath -StoreDir ([string]$dupDir) -GoalId $gid
                if ((-not [string]::IsNullOrWhiteSpace($canon)) -and (Test-Path -LiteralPath $canon -PathType Leaf)) {
                    return [pscustomobject]@{ ok = $false; reason = 'duplicate-goal-id'; goal = $null }
                }
            }
        }
        catch { }
        $obj = ([string]$Objective).Trim()
        if ([string]::IsNullOrWhiteSpace($obj)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; goal = $null }
        }
        if ($SoftCap -lt 0 -or $HardCap -lt 0 -or $TotalPhases -lt 0) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-budget'; goal = $null }
        }
        $criteria = (Get-GKGoalStringList $Criteria)
        $surfaces = (Get-GKGoalStringList $VerificationSurfaces)
        if ($null -eq $criteria -or $null -eq $surfaces) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-list'; goal = $null }
        }
        $stamp = Get-GKGoalStamp
        $rec = [ordered]@{
            schema_version         = 1
            goal_id                = $gid
            objective              = $obj
            criteria               = @($criteria)
            verification_surfaces  = @($surfaces)
            state                  = 'DRAFT'
            revision               = [long]1
            budget                 = [ordered]@{ soft_cap = [long]$SoftCap; hard_cap = [long]$HardCap; spent = [long]0 }
            progress               = [ordered]@{ satisfied = [long]0; total = [long]@($criteria).Count; updated_at = $stamp }
            plan_progress          = [ordered]@{ phase = [long]0; total_phases = [long]$TotalPhases; done_tasks = [long]0 }
            evidence_refs          = @()
            decision_refs          = @()
            failed_strategies      = @()
            active_tasks           = @()
            completed_tasks        = @()
            blockers               = @()
            risks                  = @()
            next_move              = [ordered]@{}
            checkpoint_revision    = [long]0
            created_at             = $stamp
            updated_at             = $stamp
        }
        if ($null -eq (ConvertTo-GKGoalRecord $rec)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
    }
}

function Save-OrchestrationGoal {
    [CmdletBinding()]
    param($Goal = $null, [string]$StoreDir = '', [int]$LockTimeoutMs = 500)
    try {
        $rec = ConvertTo-GKGoalRecord $Goal
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal_id = ''; revision = [long]0 }
        }
        $dir = Get-OrchestrationGoalStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; goal_id = ''; revision = [long]0 }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; goal_id = ''; revision = [long]0 }
        }
        $lock = Open-GKGoalLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; goal_id = [string]$rec['goal_id']; revision = [long]$rec['revision'] }
        }
        try {
            # Last-writer-wins by design for direct writes; CAS callers use Update-OrchestrationGoal.
            $w = Write-GKGoalRecordAtomic -Dir $dir -Rec $rec
            if (-not [bool]$w.ok) {
                return [pscustomobject]@{ ok = $false; reason = [string]$w.reason; goal_id = [string]$rec['goal_id']; revision = [long]$rec['revision'] }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; goal_id = [string]$rec['goal_id']; revision = [long]$rec['revision']; path = [string]$w.path }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'goal-write-failed'; goal_id = ''; revision = [long]0 }
    }
}

function Get-OrchestrationGoal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GoalId, [string]$StoreDir = '')
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-GKGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; goal = $null }
        }
        $dir = Get-OrchestrationGoalStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; goal = $null }
        }
        $path = Get-GKGoalFilePath -StoreDir $dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'goal-not-found'; goal = $null }
        }
        try {
            $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        $rec = ConvertTo-GKGoalRecord $raw
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        if ([string]$rec['goal_id'] -ine $gid) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
    }
}

function Update-OrchestrationGoal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GoalId,
        [Parameter(Mandatory = $true)][long]$ExpectedRevision,
        $Fields = @{},
        [string]$StoreDir = '',
        [int]$LockTimeoutMs = 500
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-GKGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; goal = $null }
        }
        if (($null -eq $Fields) -or (-not ($Fields -is [System.Collections.IDictionary]) -and -not ($Fields -is [pscustomobject]))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-fields'; goal = $null }
        }
        $dir = Get-OrchestrationGoalStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; goal = $null }
        }
        # Field-name validation first (no IO): protected and updatable sets.
        $protected = @('schema_version', 'goal_id', 'revision', 'created_at', 'state', 'active_tasks', 'completed_tasks')
        if ($Fields -is [System.Collections.IDictionary]) { $names = @($Fields.Keys) }
        else { $names = @($Fields.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($name in @($names)) {
            $n = [string]$name
            if ($protected -ccontains $n) {
                if ($n -ceq 'state') {
                    return [pscustomobject]@{ ok = $false; reason = 'state-via-transition'; goal = $null }
                }
                if ($n -ceq 'active_tasks' -or $n -ceq 'completed_tasks') {
                    return [pscustomobject]@{ ok = $false; reason = 'tasks-via-task-ops'; goal = $null }
                }
                return [pscustomobject]@{ ok = $false; reason = 'protected-field'; goal = $null }
            }
        }
        $updatable = @('objective', 'criteria', 'verification_surfaces', 'budget', 'progress', 'plan_progress', 'evidence_refs', 'decision_refs', 'failed_strategies', 'blockers', 'risks', 'next_move', 'checkpoint_revision')
        foreach ($name in @($names)) {
            $n = [string]$name
            if ($updatable -cnotcontains $n) {
                return [pscustomobject]@{ ok = $false; reason = 'field-not-updatable'; goal = $null }
            }
        }
        # Atomic CAS: acquire the store lock BEFORE read/check/mutate/persist
        # so two writers with the same ExpectedRevision cannot interleave.
        $lock = Open-GKGoalLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; goal = $null }
        }
        try {
        $path = Get-GKGoalFilePath -StoreDir $dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'goal-not-found'; goal = $null }
        }
        try {
            $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        $rec = ConvertTo-GKGoalRecord $raw
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        if ([string]$rec['goal_id'] -ine $gid) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        $rec = Copy-GKGoalRecord $rec
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; goal = $null }
        }
        if ([long]$rec['revision'] -ne [long]$ExpectedRevision) {
            return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; goal = $null }
        }
        $stamp = Get-GKGoalStamp
        $criteriaTouched = $false
        $progressTouched = $false
        foreach ($name in @($names)) {
            $n = [string]$name
            $v = Get-GKGoalValue $Fields $n $null
            switch ($n) {
                'objective' {
                    $s = ([string]$v).Trim()
                    if ([string]::IsNullOrWhiteSpace($s)) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; goal = $null }
                    }
                    $rec['objective'] = $s
                }
                'criteria' {
                    $list = Get-GKGoalStringList $v
                    if ($null -eq $list) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-list'; goal = $null }
                    }
                    $rec['criteria'] = @($list)
                    $criteriaTouched = $true
                }
                'verification_surfaces' {
                    $list = Get-GKGoalStringList $v
                    if ($null -eq $list) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-list'; goal = $null }
                    }
                    $rec['verification_surfaces'] = @($list)
                }
                'budget' {
                    if ($null -eq $v) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-budget'; goal = $null }
                    }
                    $soft = Get-GKGoalLong (Get-GKGoalValue $v 'soft_cap' $null) -1
                    $hard = Get-GKGoalLong (Get-GKGoalValue $v 'hard_cap' $null) -1
                    $spent = Get-GKGoalLong (Get-GKGoalValue $v 'spent' $null) -1
                    if ($soft -lt 0 -or $hard -lt 0 -or $spent -lt 0) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-budget'; goal = $null }
                    }
                    $rec['budget'] = [ordered]@{ soft_cap = [long]$soft; hard_cap = [long]$hard; spent = [long]$spent }
                }
                'progress' {
                    if ($null -eq $v) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-progress'; goal = $null }
                    }
                    $sat = Get-GKGoalLong (Get-GKGoalValue $v 'satisfied' $null) -1
                    $tot = Get-GKGoalLong (Get-GKGoalValue $v 'total' $null) -1
                    if ($sat -lt 0 -or $tot -lt 0 -or $sat -gt $tot) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-progress'; goal = $null }
                    }
                    $at = [string](Get-GKGoalValue $v 'updated_at' '')
                    if ([string]::IsNullOrWhiteSpace($at)) { $at = $stamp }
                    $rec['progress'] = [ordered]@{ satisfied = [long]$sat; total = [long]$tot; updated_at = $at }
                    $progressTouched = $true
                }
                'plan_progress' {
                    if ($null -eq $v) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-plan-progress'; goal = $null }
                    }
                    $phase = Get-GKGoalLong (Get-GKGoalValue $v 'phase' $null) -1
                    $tph = Get-GKGoalLong (Get-GKGoalValue $v 'total_phases' $null) -1
                    $done = Get-GKGoalLong (Get-GKGoalValue $v 'done_tasks' $null) -1
                    if ($phase -lt 0 -or $tph -lt 0 -or $done -lt 0) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-plan-progress'; goal = $null }
                    }
                    $rec['plan_progress'] = [ordered]@{ phase = [long]$phase; total_phases = [long]$tph; done_tasks = [long]$done }
                }
                'checkpoint_revision' {
                    $ck = Get-GKGoalLong $v -1
                    if ($ck -lt 0) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-checkpoint'; goal = $null }
                    }
                    $rec['checkpoint_revision'] = [long]$ck
                }
                'next_move' {
                    if ($null -eq $v) {
                        $rec['next_move'] = [ordered]@{}
                    }
                    elseif (($v -is [System.Collections.IDictionary]) -or ($v -is [pscustomobject])) {
                        $nm = [ordered]@{}
                        if ($v -is [System.Collections.IDictionary]) {
                            foreach ($k in $v.Keys) { $nm[[string]$k] = $v[$k] }
                        }
                        else {
                            foreach ($p in $v.PSObject.Properties) { $nm[$p.Name] = $p.Value }
                        }
                        $rec['next_move'] = $nm
                    }
                    else {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-next-move'; goal = $null }
                    }
                }
                default {
                    $list = Get-GKGoalStringList $v
                    if ($null -eq $list) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-list'; goal = $null }
                    }
                    $rec[$n] = @($list)
                }
            }
        }
        if ($criteriaTouched -and -not $progressTouched) {
            $oldSat = [long]$rec['progress']['satisfied']
            $newTot = [long]@($rec['criteria']).Count
            if ($oldSat -gt $newTot) { $oldSat = $newTot }
            $rec['progress'] = [ordered]@{ satisfied = [long]$oldSat; total = [long]$newTot; updated_at = $stamp }
        }
        $rec['revision'] = [long]$rec['revision'] + 1
        $rec['updated_at'] = $stamp
        if ($null -eq (ConvertTo-GKGoalRecord $rec)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
        }
        # Persist under the SAME lock acquired above (never re-acquire).
        $w = Write-GKGoalRecordAtomic -Dir $dir -Rec $rec
        if (-not [bool]$w.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$w.reason; goal = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-fields'; goal = $null }
    }
}

function Set-OrchestrationGoalState {
    [CmdletBinding()]
    param($Goal = $null, [string]$ToState = '')
    try {
        $rec = Copy-GKGoalRecord $Goal
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
        }
        $to = ([string]$ToState).Trim().ToUpperInvariant()
        if (@(Get-OrchestrationGoalStates) -cnotcontains $to) {
            return [pscustomobject]@{ ok = $false; reason = 'unknown-state'; goal = $null }
        }
        $from = [string]$rec['state']
        if (-not (Test-OrchestrationGoalTransition -From $from -To $to)) {
            return [pscustomobject]@{ ok = $false; reason = 'illegal-transition'; goal = $null }
        }
        $rec['state'] = $to
        $rec['revision'] = [long]$rec['revision'] + 1
        $rec['updated_at'] = Get-GKGoalStamp
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
    }
}

function Add-OrchestrationGoalTask {
    [CmdletBinding()]
    param($Goal = $null, [string]$TaskId = '')
    try {
        $rec = Copy-GKGoalRecord $Goal
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-GKGoalId $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; goal = $null }
        }
        foreach ($t in @(@($rec['active_tasks']) + @($rec['completed_tasks']))) {
            if ($tid -ceq [string]$t) {
                return [pscustomobject]@{ ok = $false; reason = 'duplicate-task'; goal = $null }
            }
        }
        $rec['active_tasks'] = @(@($rec['active_tasks']) + @($tid))
        $rec['revision'] = [long]$rec['revision'] + 1
        $rec['updated_at'] = Get-GKGoalStamp
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
    }
}

function Complete-OrchestrationGoalTask {
    [CmdletBinding()]
    param($Goal = $null, [string]$TaskId = '')
    try {
        $rec = Copy-GKGoalRecord $Goal
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-GKGoalId $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; goal = $null }
        }
        $found = $false
        $rest = New-Object System.Collections.ArrayList
        foreach ($t in @($rec['active_tasks'])) {
            if (-not $found -and ($tid -ceq [string]$t)) { $found = $true }
            else { [void]$rest.Add([string]$t) }
        }
        if (-not $found) {
            return [pscustomobject]@{ ok = $false; reason = 'task-not-found'; goal = $null }
        }
        $rec['active_tasks'] = [string[]]$rest.ToArray()
        $rec['completed_tasks'] = @(@($rec['completed_tasks']) + @($tid))
        $rec['revision'] = [long]$rec['revision'] + 1
        $rec['updated_at'] = Get-GKGoalStamp
        return [pscustomobject]@{ ok = $true; reason = ''; goal = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; goal = $null }
    }
}

function Get-OrchestrationGoalNextMove {
    [CmdletBinding()]
    param($Goal = $null, [string]$ControllerPath = '')
    try {
        $rec = ConvertTo-GKGoalRecord $Goal
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; next_move = $null }
        }
        $explicit = -not [string]::IsNullOrWhiteSpace($ControllerPath)
        $cmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
        if ($explicit) {
            $cpath = ([string]$ControllerPath).Trim()
            if (-not (Test-Path -LiteralPath $cpath -PathType Leaf)) {
                return [pscustomobject]@{ ok = $false; reason = 'controller-unavailable'; next_move = $null }
            }
            try { . $cpath } catch { }
            $cmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
            if ($null -eq $cmd) {
                return [pscustomobject]@{ ok = $false; reason = 'controller-unavailable'; next_move = $null }
            }
        }
        elseif ($null -eq $cmd) {
            $sibling = Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1'
            if (Test-Path -LiteralPath $sibling -PathType Leaf) {
                try { . $sibling } catch { }
                $cmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
            }
            if ($null -eq $cmd) {
                return [pscustomobject]@{ ok = $false; reason = 'controller-unavailable'; next_move = $null }
            }
        }
        $state = [string]$rec['state']
        $remaining = New-Object System.Collections.ArrayList
        foreach ($t in @($rec['active_tasks'])) { [void]$remaining.Add([string]$t) }
        $crit = @($rec['criteria'])
        $sat = [long]$rec['progress']['satisfied']
        if ($sat -lt 0) { $sat = 0 }
        if ($sat -gt [long]$crit.Count) { $sat = [long]$crit.Count }
        for ($i = $sat; $i -lt $crit.Count; $i++) {
            [void]$remaining.Add(('criterion:' + [string]$crit[$i]))
        }
        $completed = ($state -ceq 'COMPLETED')
        $authorized = (@('BLOCKED', 'CANCELLED', 'EXHAUSTED') -cnotcontains $state)
        $blockerKind = ''
        if ($state -ceq 'BUDGET_LIMITED') { $blockerKind = 'policy' }
        $terminalBlocker = $null
        if ($state -ceq 'EXHAUSTED') { $terminalBlocker = 'GOAL_HARD_BUDGET_EXHAUSTED' }
        elseif ($state -ceq 'CANCELLED') { $terminalBlocker = 'CANCELLED' }
        $progressPossible = ($state -ceq 'ACTIVE')
        $status = @{
            objective_completed     = [bool]$completed
            remaining_work          = [string[]]$remaining.ToArray()
            authorized              = [bool]$authorized
            blocker_kind            = [string]$blockerKind
            progress_possible       = [bool]$progressPossible
            strategy_change         = $false
            context_degraded        = $false
            last_failure            = $null
            terminal_blocker        = $terminalBlocker
            consecutive_no_progress = [long]0
        }
        try {
            $move = Get-OrchestrationNextMove -Status $status
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'next-move-failed'; next_move = $null }
        }
        if ($null -eq $move) {
            return [pscustomobject]@{ ok = $false; reason = 'next-move-failed'; next_move = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; next_move = $move }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'next-move-failed'; next_move = $null }
    }
}
