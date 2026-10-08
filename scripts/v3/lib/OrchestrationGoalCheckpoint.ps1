<#!
.SYNOPSIS
    V3 Goal Checkpoint + Session Recovery: durable checkpoint records (SPEC v0.1.0 Phase 10).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure store + resume
    helpers, fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: constructors return $null on invalid input, store
    helpers return an envelope with ok=$false and a machine-readable
    reason. No network, no process, no grants, no leases, no verification.

    TDR-F10: New-OrchestrationGoalCheckpoint snapshots a Goal record into
    a checkpoint record (ordered): checkpoint_id, goal_id, goal_revision,
    objective, progress, plan_progress, decision_refs, evidence_refs,
    failed_strategies, blockers, risks, waits, next_move,
    resume_preconditions, base_revision, created_at. checkpoint_id is the
    first 16 hex chars of SHA256 over the canonical content WITHOUT
    timestamp/id, so the same goal content always yields the same id
    (an explicit -CheckpointId must match ^[a-f0-9]{16}$).
    resume_preconditions carries base_revision, goal_exists and
    store_readable (both $false at creation; resolved by
    Test-OrchestrationCheckpointResume).

    File layout: one JSON file per checkpoint in <StoreDir>, default
    <repoRoot>/cache/goal-store/checkpoints. File name is the lowercase
    checkpoint_id + '.json'. Writes are atomic (temp+move) while holding
    an exclusive '.checkpoint.lock' file lock with a bounded retry,
    mirroring OrchestrationGoalKernel / OrchestrationEvidenceStore.

    This lib never reads or writes real sessions and never touches the
    reconciler; resume only checks Goal store presence plus a live
    goal-revision match (structural). A checkpoint whose goal_revision
    differs from the live Goal revision is stale and never hydrates;
    a declared base_revision is compared only when both sides carry one.
#>
[CmdletBinding()]
param()

function Get-OrchestrationGoalCheckpointStoreDir {
    [CmdletBinding()]
    param([string]$StoreDir = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($StoreDir)) { return ([string]$StoreDir) }
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        if ([string]::IsNullOrWhiteSpace($repoRoot)) { return '' }
        $dir = Join-Path (Join-Path (Join-Path $repoRoot 'cache') 'goal-store') 'checkpoints'
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($dir)
        }
        return $dir
    }
    catch { return '' }
}

function Test-GCCheckpointId {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-f0-9]{16}$')
    }
    catch { return $false }
}

function Test-GCGoalId {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,64}$')
    }
    catch { return $false }
}

function Get-GCValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) {
            if ($Default -is [array]) { return ,$Default }
            return $Default
        }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $v = $Object[$Name]
                if ($null -eq $v) { return $null }
                if ($v -is [array]) { return ,$v }
                return $v
            }
            if ($Default -is [array]) { return ,$Default }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) {
            $v = $p.Value
            if ($null -eq $v) { return $null }
            if ($v -is [array]) { return ,$v }
            return $v
        }
        if ($Default -is [array]) { return ,$Default }
        return $Default
    }
    catch {
        if ($Default -is [array]) { return ,$Default }
        return $Default
    }
}

function Get-GCLong {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) { return [long]$Value }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [short]) { return [long]$Value }
        return $Default
    }
    catch { return $Default }
}

function Get-GCStringList {
    param($Value)
    # Comma-wrapped returns: empty-collapse ($null) always stays a real
    # array for the caller; $null input is empty (valid).
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

function Get-GCStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

function Get-GCInstant {
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

function Get-GCCheckpointHash16 {
    param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            $h = $sha.ComputeHash($bytes)
            $hex = ([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant()
            return $hex.Substring(0, 16)
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function ConvertTo-GCCheckpointRecord {
    param($Checkpoint)
    try {
        $rawCid = Get-GCValue $Checkpoint 'checkpoint_id' $null
        if (-not ($rawCid -is [string])) { return $null }
        $cid = ([string]$rawCid).Trim()
        if (-not (Test-GCCheckpointId $cid)) { return $null }
        $rawGid = Get-GCValue $Checkpoint 'goal_id' $null
        if (-not ($rawGid -is [string])) { return $null }
        $gid = ([string]$rawGid).Trim()
        if (-not (Test-GCGoalId $gid)) { return $null }
        $rawRev = Get-GCValue $Checkpoint 'goal_revision' $null
        if ($rawRev -is [array]) { return $null }
        $rev = Get-GCLong $rawRev -1
        if ($rev -lt 1) { return $null }
        $obj = [string](Get-GCValue $Checkpoint 'objective' '')
        if ([string]::IsNullOrWhiteSpace($obj)) { return $null }
        $rawProgress = Get-GCValue $Checkpoint 'progress' $null
        if ($null -eq $rawProgress) { return $null }
        $sat = Get-GCLong (Get-GCValue $rawProgress 'satisfied' $null) -1
        $tot = Get-GCLong (Get-GCValue $rawProgress 'total' $null) -1
        if ($sat -lt 0 -or $tot -lt 0 -or $sat -gt $tot) { return $null }
        $progAt = Get-GCInstant (Get-GCValue $rawProgress 'updated_at' '')
        if ([string]::IsNullOrWhiteSpace($progAt)) { return $null }
        $rawPlan = Get-GCValue $Checkpoint 'plan_progress' $null
        if ($null -eq $rawPlan) { return $null }
        $phase = Get-GCLong (Get-GCValue $rawPlan 'phase' $null) -1
        $tph = Get-GCLong (Get-GCValue $rawPlan 'total_phases' $null) -1
        $done = Get-GCLong (Get-GCValue $rawPlan 'done_tasks' $null) -1
        if ($phase -lt 0 -or $tph -lt 0 -or $done -lt 0) { return $null }
        $flatLists = [ordered]@{}
        foreach ($lname in @('decision_refs', 'evidence_refs', 'failed_strategies', 'blockers', 'risks', 'waits')) {
            $lv = Get-GCStringList (Get-GCValue $Checkpoint $lname @())
            if ($null -eq $lv) { return $null }
            $flatLists[$lname] = $lv
        }
        $rawNext = Get-GCValue $Checkpoint 'next_move' $null
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
        $rawPre = Get-GCValue $Checkpoint 'resume_preconditions' $null
        if ($null -eq $rawPre) { return $null }
        if ((-not ($rawPre -is [System.Collections.IDictionary])) -and (-not ($rawPre -is [pscustomobject]))) { return $null }
        $preBase = Get-GCValue $rawPre 'base_revision' $null
        if (($null -ne $preBase) -and (-not ($preBase -is [string]))) { return $null }
        foreach ($fname in @('goal_exists', 'store_readable')) {
            $fv = Get-GCValue $rawPre $fname $null
            if (-not ($fv -is [bool])) { return $null }
        }
        $base = Get-GCValue $Checkpoint 'base_revision' $null
        if (($null -ne $base) -and (-not ($base -is [string]))) { return $null }
        $created = Get-GCInstant (Get-GCValue $Checkpoint 'created_at' '')
        if ([string]::IsNullOrWhiteSpace($created)) { return $null }
        # Storage keeps true flat arrays: Get-GCStringList returns a real
        # string[] to its caller (comma-wrapped return), and @() preserves
        # it, so direct consumers see the correct .Count. The loop above
        # already rejected invalid lists.
        $rec = [ordered]@{
            checkpoint_id        = $cid
            goal_id              = $gid
            goal_revision        = [long]$rev
            objective            = $obj
            progress             = [ordered]@{ satisfied = [long]$sat; total = [long]$tot; updated_at = $progAt }
            plan_progress        = [ordered]@{ phase = [long]$phase; total_phases = [long]$tph; done_tasks = [long]$done }
            decision_refs        = @($flatLists['decision_refs'])
            evidence_refs        = @($flatLists['evidence_refs'])
            failed_strategies    = @($flatLists['failed_strategies'])
            blockers             = @($flatLists['blockers'])
            risks                = @($flatLists['risks'])
            waits                = @($flatLists['waits'])
            next_move            = $nextMove
            resume_preconditions = [ordered]@{
                base_revision  = [string](Get-GCValue $rawPre 'base_revision' '')
                goal_exists    = [bool](Get-GCValue $rawPre 'goal_exists' $false)
                store_readable = [bool](Get-GCValue $rawPre 'store_readable' $false)
            }
            base_revision        = [string](Get-GCValue $Checkpoint 'base_revision' '')
            created_at           = $created
        }
        return $rec
    }
    catch { return $null }
}

function New-OrchestrationGoalCheckpoint {
    [CmdletBinding()]
    param($GoalRecord = $null, [string]$CheckpointId = '')
    try {
        $rawGid = Get-GCValue $GoalRecord 'goal_id' $null
        if (-not ($rawGid -is [string])) { return $null }
        $gid = ([string]$rawGid).Trim()
        if (-not (Test-GCGoalId $gid)) { return $null }
        $rawRevVal = Get-GCValue $GoalRecord 'revision' $null
        if ($rawRevVal -is [array]) { return $null }
        $rev = Get-GCLong $rawRevVal -1
        if ($rev -lt 1) { return $null }
        $obj = ([string](Get-GCValue $GoalRecord 'objective' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($obj)) { return $null }
        $rawProgress = Get-GCValue $GoalRecord 'progress' $null
        if ($null -eq $rawProgress) { return $null }
        $sat = Get-GCLong (Get-GCValue $rawProgress 'satisfied' $null) -1
        $tot = Get-GCLong (Get-GCValue $rawProgress 'total' $null) -1
        if ($sat -lt 0 -or $tot -lt 0 -or $sat -gt $tot) { return $null }
        $progAt = Get-GCInstant (Get-GCValue $rawProgress 'updated_at' '')
        if ([string]::IsNullOrWhiteSpace($progAt)) { return $null }
        $rawPlan = Get-GCValue $GoalRecord 'plan_progress' $null
        if ($null -eq $rawPlan) { return $null }
        $phase = Get-GCLong (Get-GCValue $rawPlan 'phase' $null) -1
        $tph = Get-GCLong (Get-GCValue $rawPlan 'total_phases' $null) -1
        $done = Get-GCLong (Get-GCValue $rawPlan 'done_tasks' $null) -1
        if ($phase -lt 0 -or $tph -lt 0 -or $done -lt 0) { return $null }
        $decRefs = Get-GCStringList (Get-GCValue $GoalRecord 'decision_refs' @())
        $evRefs = Get-GCStringList (Get-GCValue $GoalRecord 'evidence_refs' @())
        $failed = Get-GCStringList (Get-GCValue $GoalRecord 'failed_strategies' @())
        $blockers = Get-GCStringList (Get-GCValue $GoalRecord 'blockers' @())
        $risks = Get-GCStringList (Get-GCValue $GoalRecord 'risks' @())
        $waits = Get-GCStringList (Get-GCValue $GoalRecord 'waits' @())
        if ($null -eq $decRefs -or $null -eq $evRefs -or $null -eq $failed -or $null -eq $blockers -or $null -eq $risks -or $null -eq $waits) { return $null }
        $rawNext = Get-GCValue $GoalRecord 'next_move' $null
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
        $baseRaw = Get-GCValue $GoalRecord 'base_revision' ''
        if (($null -ne $baseRaw) -and (-not ($baseRaw -is [string]))) { return $null }
        $base = [string]$baseRaw
        if ($null -eq $base) { $base = '' }
        $progress = [ordered]@{ satisfied = [long]$sat; total = [long]$tot; updated_at = $progAt }
        $plan = [ordered]@{ phase = [long]$phase; total_phases = [long]$tph; done_tasks = [long]$done }
        $cid = ([string]$CheckpointId).Trim()
        if ([string]::IsNullOrWhiteSpace($cid)) {
            $material = [ordered]@{
                goal_id           = $gid
                goal_revision     = [long]$rev
                objective         = $obj
                progress          = $progress
                plan_progress     = $plan
                decision_refs     = @($decRefs)
                evidence_refs     = @($evRefs)
                failed_strategies = @($failed)
                blockers          = @($blockers)
                risks             = @($risks)
                waits             = @($waits)
                next_move         = $nextMove
                base_revision     = $base
            }
            $canon = ConvertTo-Json -InputObject $material -Depth 20 -Compress
            $cid = Get-GCCheckpointHash16 $canon
            if ([string]::IsNullOrWhiteSpace($cid)) { return $null }
        }
        elseif (-not (Test-GCCheckpointId $cid)) { return $null }
        $rec = [ordered]@{
            checkpoint_id        = $cid
            goal_id              = $gid
            goal_revision        = [long]$rev
            objective            = $obj
            progress             = $progress
            plan_progress        = $plan
            decision_refs        = @($decRefs)
            evidence_refs        = @($evRefs)
            failed_strategies    = @($failed)
            blockers             = @($blockers)
            risks                = @($risks)
            waits                = @($waits)
            next_move            = $nextMove
            resume_preconditions = [ordered]@{ base_revision = $base; goal_exists = $false; store_readable = $false }
            base_revision        = $base
            created_at           = Get-GCStamp
        }
        if ($null -eq (ConvertTo-GCCheckpointRecord $rec)) { return $null }
        return $rec
    }
    catch { return $null }
}

function Open-GCCheckpointLock {
    param([string]$Dir, [int]$LockTimeoutMs = 500)
    try {
        $lockPath = Join-Path $Dir '.checkpoint.lock'
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

function Write-GCCheckpointRecordAtomic {
    param([string]$Dir, $Rec)
    try {
        $cid = [string]$Rec['checkpoint_id']
        if (-not (Test-GCCheckpointId $cid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-checkpoint-id'; path = '' }
        }
        $path = Join-Path $Dir ($cid.ToLowerInvariant() + '.json')
        $json = ConvertTo-Json -InputObject $Rec -Depth 20 -Compress
        $tmp = Join-Path $Dir (('checkpoint-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try {
            [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-write-failed'; path = '' }
        }
        try {
            Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-write-failed'; path = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; path = $path }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'checkpoint-write-failed'; path = '' }
    }
}

function Save-OrchestrationGoalCheckpoint {
    [CmdletBinding()]
    param($Checkpoint = $null, [string]$StoreDir = '', [int]$LockTimeoutMs = 500)
    try {
        $rec = ConvertTo-GCCheckpointRecord $Checkpoint
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-checkpoint'; checkpoint_id = ''; path = '' }
        }
        $dir = Get-OrchestrationGoalCheckpointStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; checkpoint_id = ''; path = '' }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; checkpoint_id = ''; path = '' }
        }
        $lock = Open-GCCheckpointLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return [pscustomobject]@{ ok = $false; reason = 'lock-busy'; checkpoint_id = [string]$rec['checkpoint_id']; path = '' }
        }
        try {
            $w = Write-GCCheckpointRecordAtomic -Dir $dir -Rec $rec
            if (-not [bool]$w.ok) {
                return [pscustomobject]@{ ok = $false; reason = [string]$w.reason; checkpoint_id = [string]$rec['checkpoint_id']; path = '' }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; checkpoint_id = [string]$rec['checkpoint_id']; path = [string]$w.path }
        }
        finally {
            try { $lock.Dispose() } catch { }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'checkpoint-write-failed'; checkpoint_id = ''; path = '' }
    }
}

function Load-OrchestrationGoalCheckpoint {
    [CmdletBinding()]
    param([string]$CheckpointId = '', [string]$StoreDir = '')
    try {
        $cid = ([string]$CheckpointId).Trim()
        if (-not (Test-GCCheckpointId $cid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-checkpoint-id'; checkpoint = $null }
        }
        $dir = Get-OrchestrationGoalCheckpointStoreDir -StoreDir $StoreDir
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; checkpoint = $null }
        }
        $path = Join-Path $dir ($cid.ToLowerInvariant() + '.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-not-found'; checkpoint = $null }
        }
        try {
            $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; checkpoint = $null }
        }
        $rec = ConvertTo-GCCheckpointRecord $raw
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; checkpoint = $null }
        }
        if ([string]$rec['checkpoint_id'] -cne $cid) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; checkpoint = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; checkpoint = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-record'; checkpoint = $null }
    }
}

function Test-OrchestrationCheckpointResume {
    [CmdletBinding()]
    param($Checkpoint = $null, [string]$GoalStoreDir = '')
    try {
        $plan = [ordered]@{ hydrate_goal = $false; revalidate_decisions = $false; recompute_next_move = $false }
        $rec = ConvertTo-GCCheckpointRecord $Checkpoint
        if ($null -eq $rec) {
            return [pscustomobject]@{ resumable = $false; reasons = [string[]]@('invalid-checkpoint'); resume_plan = $plan }
        }
        $reasons = New-Object System.Collections.ArrayList
        $gid = [string]$rec['goal_id']
        $rev = [long]$rec['goal_revision']
        if ([string]::IsNullOrWhiteSpace($gid)) { [void]$reasons.Add('empty-goal-id') }
        if ($rev -lt 1) { [void]$reasons.Add('invalid-goal-revision') }
        $dir = ([string]$GoalStoreDir).Trim()
        $verifiable = $false
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            try { $verifiable = Test-Path -LiteralPath $dir -PathType Container }
            catch { $verifiable = $false }
        }
        if (-not $verifiable) {
            [void]$reasons.Add('goal-store-unverifiable')
        }
        elseif ($reasons.Count -eq 0) {
            $safe = ($gid.ToLowerInvariant() -replace ':', '=')
            $gpath = Join-Path $dir ($safe + '.json')
            if (-not (Test-Path -LiteralPath $gpath -PathType Leaf)) {
                [void]$reasons.Add('goal-not-found')
            }
            else {
                try {
                    $graw = ConvertFrom-Json ([IO.File]::ReadAllText($gpath, [Text.Encoding]::UTF8))
                    $ggid = [string](Get-GCValue $graw 'goal_id' '')
                    if ($ggid -ine $gid) { [void]$reasons.Add('goal-unreadable') }
                    else {
                        $liveRevRaw = Get-GCValue $graw 'revision' $null
                        if ($liveRevRaw -is [array]) { [void]$reasons.Add('goal-unreadable') }
                        else {
                            $liveRev = Get-GCLong $liveRevRaw -1
                            if ($liveRev -lt 1) { [void]$reasons.Add('goal-unreadable') }
                            elseif ($liveRev -ne $rev) { [void]$reasons.Add('stale-goal-revision') }
                            else {
                                $liveBase = [string](Get-GCValue $graw 'base_revision' '')
                                $ckptBase = [string]$rec['base_revision']
                                if ((-not [string]::IsNullOrWhiteSpace($liveBase)) -and (-not [string]::IsNullOrWhiteSpace($ckptBase)) -and ($liveBase -cne $ckptBase)) {
                                    [void]$reasons.Add('stale-base-revision')
                                }
                            }
                        }
                    }
                }
                catch { [void]$reasons.Add('goal-unreadable') }
            }
        }
        $ok = ($reasons.Count -eq 0)
        if ($ok) {
            $plan = [ordered]@{ hydrate_goal = $true; revalidate_decisions = $true; recompute_next_move = $true }
        }
        # Flat string[]: direct consumers see the true .Count (a
        # comma-wrapped empty would read back as Count 1).
        $reasonFlat = [string[]]$reasons.ToArray()
        return [pscustomobject]@{ resumable = [bool]$ok; reasons = $reasonFlat; resume_plan = $plan }
    }
    catch {
        $plan = [ordered]@{ hydrate_goal = $false; revalidate_decisions = $false; recompute_next_move = $false }
        return [pscustomobject]@{ resumable = $false; reasons = [string[]]@('invalid-checkpoint'); resume_plan = $plan }
    }
}
