<#!
.SYNOPSIS
    V3 autonomy envelope + stop policy (Phase 2 contract, declarative only).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure functions,
    fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: any failure returns $null / $false / a
    fully-denied envelope. No network, no process, no registry access
    outside the autonomy-policy.json file. Enforcement is NOT here;
    it is wired in later phases. The kernel remains the authority.
#>
[CmdletBinding()]
param()

function Get-OrchestrationAutonomyPolicy {
    [CmdletBinding()]
    param([string]$PolicyPath = '')
    try {
        $path = ([string]$PolicyPath).Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Join-Path $PSScriptRoot '..\..\..\source\registry\autonomy-policy.json'
        }
        $full = [IO.Path]::GetFullPath($path)
        $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        $policy = ConvertFrom-Json $text
        if ($null -eq $policy) { return $null }
        return $policy
    }
    catch { return $null }
}

function Get-OrchestrationStopReasons {
    [CmdletBinding()]
    param()
    return @(
        'OBJECTIVE_COMPLETED',
        'HUMAN_AUTHORITY_REQUIRED',
        'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE',
        'GOAL_HARD_BUDGET_EXHAUSTED',
        'POLICY_BLOCKED',
        'CANCELLED'
    )
}

function Get-OrchestrationAuthorityBoundaries {
    [CmdletBinding()]
    param()
    return @(
        'PRODUCT_INTENT_AMBIGUITY',
        'IRREVERSIBLE_REAL_DATA_ACTION',
        'UNAUTHORIZED_PRODUCTION_ACTION',
        'EXTERNAL_COST_OR_PURCHASE',
        'CREATE_ROTATE_REVOKE_CREDENTIAL',
        'EXTERNAL_COMMUNICATION_AS_USER',
        'MATERIAL_SCOPE_EXPANSION',
        'POLICY_DENIED',
        'REQUIRED_EXTERNAL_INPUT_UNAVAILABLE'
    )
}

function Get-OrchestrationAutoAuthorized {
    [CmdletBinding()]
    param()
    return @(
        'delegate_workers',
        'research',
        'memory_evidence_query',
        'jev_consult',
        'edit_refactor',
        'test_build',
        'debug_local',
        'branch_create',
        'worktree_create',
        'commit',
        'pr_open',
        'findings_repair',
        'ci_rerun',
        'replan',
        'strategy_switch',
        'next_wave',
        'checkpoint',
        'session_rotate',
        'goal_resume'
    )
}

function Test-OrchestrationStopReason {
    [CmdletBinding()]
    param([string]$Reason = '')
    try {
        $r = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { return $false }
        foreach ($known in (Get-OrchestrationStopReasons)) {
            if ($r -ieq $known) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-OrchestrationAuthorityBoundary {
    [CmdletBinding()]
    param([string]$Boundary = '')
    try {
        $b = ([string]$Boundary).Trim()
        if ([string]::IsNullOrWhiteSpace($b)) { return $false }
        foreach ($known in (Get-OrchestrationAuthorityBoundaries)) {
            if ($b -ieq $known) { return $true }
        }
        return $false
    }
    catch { return $false }
}

# Get-OrchestrationAuthorizationEnvelope builds the Allowed/Denied/Boundaries
# triple from declarative inputs. Fail-closed contract:
# - Unknown auto ids fail closed to Denied (never Allowed).
# - Unknown boundary codes fail closed TOTAL: the constraint is
#   unrecognizable, so no action is released (Allowed is emptied and the
#   unknown code is recorded in Denied). Known boundaries keep the current
#   behavior. Any internal failure returns a fully-denied envelope.
function Get-OrchestrationAuthorizationEnvelope {
    [CmdletBinding()]
    param(
        [string[]]$AutoAuthorized = @(),
        [string[]]$Denied = @(),
        [string[]]$Boundaries = @()
    )
    try {
        $knownAuto = @(Get-OrchestrationAutoAuthorized)
        $knownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $knownAuto) {
            $ks = ([string]$k).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ks)) { $knownSet.Add($ks) | Out-Null }
        }
        $denSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($d in @($Denied)) {
            $ds = ([string]$d).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ds)) { $denSet.Add($ds) | Out-Null }
        }
        $bndSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($Boundaries)) {
            $bs = ([string]$b).Trim()
            if (-not [string]::IsNullOrWhiteSpace($bs)) { $bndSet.Add($bs) | Out-Null }
        }
        $knownBndSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in (Get-OrchestrationAuthorityBoundaries)) {
            $ks = ([string]$k).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ks)) { $knownBndSet.Add($ks) | Out-Null }
        }
        $unknownBnd = New-Object System.Collections.ArrayList
        $seenUnknownBnd = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($Boundaries)) {
            $bs = ([string]$b).Trim()
            if ([string]::IsNullOrWhiteSpace($bs)) { continue }
            if (-not $knownBndSet.Contains($bs)) {
                if (-not $seenUnknownBnd.Contains($bs)) {
                    $seenUnknownBnd.Add($bs) | Out-Null
                    [void]$unknownBnd.Add($bs)
                }
            }
        }
        $allowed = New-Object System.Collections.ArrayList
        $deniedOut = New-Object System.Collections.ArrayList
        $seenDenied = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $addDenied = {
            param([string]$v)
            $s = ([string]$v).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { return }
            if (-not $seenDenied.Contains($s)) {
                $seenDenied.Add($s) | Out-Null
                [void]$deniedOut.Add($s)
            }
        }
        foreach ($d in @($Denied)) { & $addDenied ([string]$d) }
        $seenAuto = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($a in @($AutoAuthorized)) {
            $s = ([string]$a).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            if ($seenAuto.Contains($s)) { continue }
            $seenAuto.Add($s) | Out-Null
            if (-not $knownSet.Contains($s)) { & $addDenied $s; continue }
            if ($denSet.Contains($s)) { & $addDenied $s; continue }
            if ($bndSet.Contains($s)) { & $addDenied $s; continue }
            [void]$allowed.Add($s)
        }
        if ($unknownBnd.Count -gt 0) {
            foreach ($s in @($allowed)) { & $addDenied $s }
            $allowed.Clear()
            foreach ($u in @($unknownBnd)) { & $addDenied $u }
        }
        $bndOut = New-Object System.Collections.ArrayList
        $seenBnd = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($b in @($Boundaries)) {
            $s = ([string]$b).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            if ($seenBnd.Contains($s)) { continue }
            $seenBnd.Add($s) | Out-Null
            [void]$bndOut.Add($s)
        }
        return [PSCustomObject]@{
            Allowed    = [string[]]$allowed.ToArray()
            Denied     = [string[]]$deniedOut.ToArray()
            Boundaries = [string[]]$bndOut.ToArray()
        }
    }
    catch {
        $flat = New-Object System.Collections.ArrayList
        try {
            foreach ($a in @($AutoAuthorized)) {
                $s = ([string]$a).Trim()
                if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$flat.Add($s) }
            }
            foreach ($d in @($Denied)) {
                $s = ([string]$d).Trim()
                if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$flat.Add($s) }
            }
        }
        catch { }
        return [PSCustomObject]@{
            Allowed    = @()
            Denied     = [string[]]$flat.ToArray()
            Boundaries = @()
        }
    }
}
