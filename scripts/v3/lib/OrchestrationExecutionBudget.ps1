<#!
.SYNOPSIS
    V3 Execution Budgets: canonical bounded-execution policy (Phase 23).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the canonical
    execution-budget contract from the V3.1 runtime-reliability addendum
    (SPEC Part A sections 3-7, PLAN Phase 23):

      - Central policy file source/registry/execution-budget-policy.json
        (version 1): 5 profiles with exact defaults (fast 16/600/180,
        standard-read 24/900/240, standard-write 32/1200/300, deep
        40/1800/360, planner-turn 64/3600/480), loop-guard limits
        (soft 3 / hard 5 / cycle 3 / provider-retry 2), role -> default
        mapping, override bounds (max 45min worker / 90min planner wall,
        max 96 steps, max 960s no-progress) and the planner-turn block.
      - Strict validation: profile must be known; every numeric field must
        be a real integer (bool/string/double/infinity rejected), in range,
        no_progress <= wall, soft < hard. Invalid input fails closed.
      - Override validation against the explicit policy bounds; anything
        outside fails closed and a worker may never widen its budget.
      - Flag seam: bounded_execution{enabled,shadow} read from -FlagsPath
        (default source/registry/capability-flags.json). Phase 23 is
        shadow/record-only: enforcement is always reported OFF
        (Get-ExecutionBudgetEnforcementState returns enforce=$false with a
        shadow note); this file never writes capability flags.
      - No disk writes, no renderer changes, no enforcement claims.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects ({ok:$false, error:'CODE'}), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------- repo / path helpers ----------

function Get-ExecutionBudgetRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-ExecutionBudgetDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-ExecutionBudgetRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\execution-budget-policy.json')
}

function Get-ExecutionBudgetDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-ExecutionBudgetRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function New-ExecutionBudgetError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code, $Extra)
    $r = [ordered]@{ ok = $false; error = $Code }
    if ($null -ne $Extra) {
        if ($Extra -is [System.Collections.IDictionary]) {
            foreach ($k in @($Extra.Keys)) { $r[[string]$k] = $Extra[$k] }
        }
        else {
            foreach ($p in @($Extra.PSObject.Properties)) { $r[$p.Name] = $p.Value }
        }
    }
    return ([PSCustomObject]$r)
}

function ConvertTo-ExecutionBudgetOrdered {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return [string]$Node }
    if ($Node -is [bool]) { return [bool]$Node }
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Node.Keys)) {
            $o[[string]$k] = (ConvertTo-ExecutionBudgetOrdered -Node $Node[$k])
        }
        return $o
    }
    if ($Node -is [System.ValueType]) { return $Node }
    if ($Node -is [System.Collections.IEnumerable]) {
        $a = @()
        foreach ($e in $Node) { $a += (ConvertTo-ExecutionBudgetOrdered -Node $e) }
        return $a
    }
    $o = [ordered]@{}
    foreach ($p in @($Node.PSObject.Properties)) {
        $o[$p.Name] = (ConvertTo-ExecutionBudgetOrdered -Node $p.Value)
    }
    return $o
}

function Read-ExecutionBudgetPolicy {
    <#
    .SYNOPSIS
        Reads the central policy file. Returns @{found, malformed, doc}.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $out = @{ found = $false; malformed = $false; doc = $null }
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $out.found = $true
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $doc) { $out.malformed = $true; return $out }
        $rec = ConvertTo-ExecutionBudgetOrdered -Node $doc
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary])) { $out.malformed = $true; return $out }
        $out.doc = $rec
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Test-ExecutionBudgetInt {
    <#
    .SYNOPSIS
        Strict integer check: only [int]/[long] (never bool/string/double),
        within [Min, Max]. Rejects negative/bool/string/infinity by type.
        Never throws.
    #>
    [CmdletBinding()]
    param($Value, [int]$Min = 1, [int]$Max = 2147483647)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
        $n = [long]$Value
        return (($n -ge [long]$Min) -and ($n -le [long]$Max))
    }
    catch { return $false }
}

function Get-ExecutionBudgetPolicyNode {
    [CmdletBinding()]
    param($Doc, [string]$Name)
    try {
        if ($null -eq $Doc) { return $null }
        if ($Doc -is [System.Collections.IDictionary]) {
            if ($Doc.Contains($Name)) { return $Doc[$Name] }
            return $null
        }
        $p = $Doc.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Assert-ExecutionBudgetPolicyJson {
    <#
    .SYNOPSIS
        Validates the central policy file. Returns @{valid, errors}.
        Checks version 1, the 5 exact profile defaults, exact loop-guard
        limits, default_profile, role coverage, override bounds and the
        planner-turn block. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errors.Add('file-missing') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $errors.Add('invalid-json') | Out-Null }
        if ($errors.Count -gt 0) {
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $rec = ConvertTo-ExecutionBudgetOrdered -Node $doc
        try { if ([int]$rec['version'] -ne 1) { $errors.Add('version-must-be-1') | Out-Null } }
        catch { $errors.Add('version-must-be-1') | Out-Null }
        $expected = [ordered]@{
            'fast'           = [ordered]@{ step_budget = 16; wall_clock_seconds = 600; no_progress_seconds = 180 }
            'standard-read'  = [ordered]@{ step_budget = 24; wall_clock_seconds = 900; no_progress_seconds = 240 }
            'standard-write' = [ordered]@{ step_budget = 32; wall_clock_seconds = 1200; no_progress_seconds = 300 }
            'deep'           = [ordered]@{ step_budget = 40; wall_clock_seconds = 1800; no_progress_seconds = 360 }
            'planner-turn'   = [ordered]@{ step_budget = 64; wall_clock_seconds = 3600; no_progress_seconds = 480 }
        }
        $profiles = Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'profiles'
        if ($null -eq $profiles -or -not ($profiles -is [System.Collections.IDictionary])) {
            $errors.Add('profiles-missing') | Out-Null
        }
        else {
            foreach ($k in @($expected.Keys)) {
                $slot = Get-ExecutionBudgetPolicyNode -Doc $profiles -Name ([string]$k)
                if ($null -eq $slot -or -not ($slot -is [System.Collections.IDictionary])) {
                    $errors.Add(('profile-missing:' + [string]$k)) | Out-Null
                    continue
                }
                foreach ($f in @('step_budget', 'wall_clock_seconds', 'no_progress_seconds')) {
                    $want = [int]$expected[$k][$f]
                    $got = $null
                    if ($slot -is [System.Collections.IDictionary]) {
                        if ($slot.Contains($f)) { $got = $slot[$f] }
                    }
                    if (-not (Test-ExecutionBudgetInt -Value $got -Min 1 -Max 86400)) {
                        $errors.Add(('profile-not-int:' + [string]$k + ':' + $f)) | Out-Null
                    }
                    elseif ([int]$got -ne $want) {
                        $errors.Add(('profile-default-mismatch:' + [string]$k + ':' + $f + ':' + [string]$got)) | Out-Null
                    }
                }
            }
        }
        $guard = Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'loop_guard'
        $wantGuard = [ordered]@{
            repeated_action_soft_limit = 3
            repeated_action_hard_limit = 5
            cycle_repeat_limit         = 3
            provider_retry_limit       = 2
        }
        if ($null -eq $guard -or -not ($guard -is [System.Collections.IDictionary])) {
            $errors.Add('loop_guard-missing') | Out-Null
        }
        else {
            foreach ($f in @($wantGuard.Keys)) {
                $got = $null
                if ($guard.Contains($f)) { $got = $guard[$f] }
                if (-not (Test-ExecutionBudgetInt -Value $got -Min 0 -Max 100)) {
                    $errors.Add(('loop_guard-not-int:' + $f)) | Out-Null
                }
                elseif ([int]$got -ne [int]$wantGuard[$f]) {
                    $errors.Add(('loop_guard-mismatch:' + $f + ':' + [string]$got)) | Out-Null
                }
            }
            $soft = 0
            $hard = 0
            try { $soft = [int]$guard['repeated_action_soft_limit'] } catch { $soft = 0 }
            try { $hard = [int]$guard['repeated_action_hard_limit'] } catch { $hard = 0 }
            if (($soft -le 0) -or ($hard -le $soft)) { $errors.Add('loop_guard-soft-must-be-lt-hard') | Out-Null }
        }
        $defProfile = [string](Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'default_profile')
        if (@('fast', 'standard-read', 'standard-write', 'deep', 'planner-turn') -cnotcontains $defProfile) {
            $errors.Add('default_profile-invalid') | Out-Null
        }
        $roles = Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'role_defaults'
        $needRoles = @('build', 'explorer', 'researcher', 'coder', 'tester', 'reviewer', 'security-reviewer', 'debugger', 'architect', 'docs-manager', 'frontend-engineer', 'backend-engineer', 'database-engineer', 'ai-agent-engineer', 'automation-engineer', 'infra-engineer', 'requirements-analyst', 'engineering-advisor', 'product-designer', 'skeptic')
        if ($null -eq $roles -or -not ($roles -is [System.Collections.IDictionary])) {
            $errors.Add('role_defaults-missing') | Out-Null
        }
        else {
            foreach ($rk in $needRoles) {
                $rv = $null
                foreach ($k in @($roles.Keys)) {
                    if ([string]$k -ceq $rk) { $rv = $roles[$k]; break }
                }
                if (@('fast', 'standard-read', 'standard-write', 'deep', 'planner-turn') -cnotcontains ([string]$rv)) {
                    $errors.Add(('role-default-invalid:' + $rk)) | Out-Null
                }
            }
            $spot = [ordered]@{ 'coder' = 'standard-write'; 'explorer' = 'standard-read'; 'debugger' = 'deep'; 'build' = 'planner-turn' }
            foreach ($sk in @($spot.Keys)) {
                $sv = ''
                foreach ($k in @($roles.Keys)) {
                    if ([string]$k -ceq $sk) { $sv = ([string]$roles[$k]).Trim(); break }
                }
                if ($sv -cne [string]$spot[$sk]) { $errors.Add(('role-default-mismatch:' + $sk)) | Out-Null }
            }
        }
        $bounds = Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'override_bounds'
        $wantBounds = [ordered]@{
            max_step_budget                  = 96
            max_wall_clock_seconds_worker    = 2700
            max_wall_clock_seconds_planner   = 5400
            max_no_progress_seconds          = 960
        }
        if ($null -eq $bounds -or -not ($bounds -is [System.Collections.IDictionary])) {
            $errors.Add('override_bounds-missing') | Out-Null
        }
        else {
            foreach ($f in @($wantBounds.Keys)) {
                $got = $null
                if ($bounds.Contains($f)) { $got = $bounds[$f] }
                if (-not (Test-ExecutionBudgetInt -Value $got -Min 1 -Max 86400)) {
                    $errors.Add(('override_bounds-not-int:' + $f)) | Out-Null
                }
                elseif ([int]$got -ne [int]$wantBounds[$f]) {
                    $errors.Add(('override_bounds-mismatch:' + $f + ':' + [string]$got)) | Out-Null
                }
            }
        }
        $pt = Get-ExecutionBudgetPolicyNode -Doc $rec -Name 'planner_turn'
        if ($null -eq $pt -or -not ($pt -is [System.Collections.IDictionary])) {
            $errors.Add('planner_turn-missing') | Out-Null
        }
        else {
            $pp = ''
            if ($pt.Contains('budget_profile')) { $pp = ([string]$pt['budget_profile']).Trim() }
            if ($pp -cne 'planner-turn') { $errors.Add('planner_turn-profile-must-be-planner-turn') | Out-Null }
            foreach ($bf in @('new_input_signal_required', 'session_lifetime_unbounded', 'shadow_record_only')) {
                $bv = $null
                if ($pt.Contains($bf)) { $bv = $pt[$bf] }
                if (-not ($bv -is [bool]) -or (-not [bool]$bv)) {
                    $errors.Add(('planner_turn-must-be-true:' + $bf)) | Out-Null
                }
            }
        }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

function Get-ExecutionBudgetProfileName {
    [CmdletBinding()]
    param([string]$Profile)
    $p = ([string]$Profile).Trim().ToLowerInvariant()
    if (@('fast', 'standard-read', 'standard-write', 'deep', 'planner-turn') -ccontains $p) { return $p }
    return ''
}

function Test-ExecutionBudgetEventId {
    <#
    .SYNOPSIS
        Closed-charset identity for planner turn/event ids (like task ids).
        Lowercase alnum start, 3-64 chars of [a-z0-9._-]. Rejects free text,
        spaces, secrets/canaries. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-ExecutionBudgetPolicyFull {
    <#
    .SYNOPSIS
        Full policy gate reusing the existing file validator (no recursion:
        Assert reads the file, never calls getters). Returns $true when the
        policy file at $Path is fully valid. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $r = Assert-ExecutionBudgetPolicyJson -Path $Path
        return ([bool]$r.valid)
    }
    catch { return $false }
}

function Get-ExecutionBudgetProfileBudget {
    <#
    .SYNOPSIS
        Builds the canonical budget object for a profile from policy.
        Returns ok + budget, or INVALID_PROFILE / BUDGET_POLICY_UNAVAILABLE.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [string]$PolicyPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $p = Get-ExecutionBudgetProfileName -Profile $Profile
        if ([string]::IsNullOrWhiteSpace($p)) {
            return (New-ExecutionBudgetError -Code 'INVALID_PROFILE' -Extra @{ profile = ([string]$Profile) })
        }
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
        }
        $slot = Read-ExecutionBudgetPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_UNAVAILABLE') }
        if ([bool]$slot.malformed) { return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID') }
        $doc = $slot.doc
        $profiles = Get-ExecutionBudgetPolicyNode -Doc $doc -Name 'profiles'
        $guard = Get-ExecutionBudgetPolicyNode -Doc $doc -Name 'loop_guard'
        if (($null -eq $profiles) -or ($null -eq $guard)) { return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID') }
        $entry = Get-ExecutionBudgetPolicyNode -Doc $profiles -Name $p
        if (($null -eq $entry) -or -not ($entry -is [System.Collections.IDictionary])) {
            return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
        }
        $gl = @{}
        foreach ($gf in @('repeated_action_soft_limit', 'repeated_action_hard_limit', 'cycle_repeat_limit', 'provider_retry_limit')) {
            $gv = Get-ExecutionBudgetPolicyNode -Doc $guard -Name $gf
            if (-not (Test-ExecutionBudgetInt -Value $gv -Min 0 -Max 100)) {
                return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
            }
            $gl[$gf] = [int]$gv
        }
        $sb = Get-ExecutionBudgetPolicyNode -Doc $entry -Name 'step_budget'
        $wc = Get-ExecutionBudgetPolicyNode -Doc $entry -Name 'wall_clock_seconds'
        $np = Get-ExecutionBudgetPolicyNode -Doc $entry -Name 'no_progress_seconds'
        if ((-not (Test-ExecutionBudgetInt -Value $sb -Min 1 -Max 86400)) -or (-not (Test-ExecutionBudgetInt -Value $wc -Min 1 -Max 86400)) -or (-not (Test-ExecutionBudgetInt -Value $np -Min 1 -Max 86400))) {
            return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
        }
        $budget = [ordered]@{
            profile                   = $p
            step_budget               = [int]$sb
            wall_clock_seconds        = [int]$wc
            no_progress_seconds       = [int]$np
            repeated_action_soft_limit = [int]$gl['repeated_action_soft_limit']
            repeated_action_hard_limit = [int]$gl['repeated_action_hard_limit']
            cycle_repeat_limit        = [int]$gl['cycle_repeat_limit']
            provider_retry_limit      = [int]$gl['provider_retry_limit']
        }
        return [PSCustomObject]@{ ok = $true; budget = $budget }
    }
    catch { return (New-ExecutionBudgetError -Code 'INTERNAL_ERROR') }
}

function Get-ExecutionBudgetForRole {
    <#
    .SYNOPSIS
        Role -> default profile -> canonical budget. Unknown role falls back
        to the policy default_profile. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$PolicyPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $pp0 = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp0)) { $pp0 = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp0)) {
            return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
        }
        $slot = Read-ExecutionBudgetPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_UNAVAILABLE') }
        if ([bool]$slot.malformed) { return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID') }
        $doc = $slot.doc
        $roles = Get-ExecutionBudgetPolicyNode -Doc $doc -Name 'role_defaults'
        $key = ([string]$Role).Trim()
        $prof = ''
        if (($null -ne $roles) -and ($roles -is [System.Collections.IDictionary])) {
            foreach ($k in @($roles.Keys)) {
                if ([string]$k -ceq $key) { $prof = ([string]$roles[$k]).Trim(); break }
            }
            if ([string]::IsNullOrWhiteSpace($prof)) {
                foreach ($k in @($roles.Keys)) {
                    if (([string]$k).ToLowerInvariant() -ceq $key.ToLowerInvariant()) { $prof = ([string]$roles[$k]).Trim(); break }
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($prof)) {
            $prof = ([string](Get-ExecutionBudgetPolicyNode -Doc $doc -Name 'default_profile')).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($prof)) { $prof = 'standard-write' }
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        $b = Get-ExecutionBudgetProfileBudget -Profile $prof -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$b.ok) { return $b }
        return [PSCustomObject]@{ ok = $true; profile = $prof; budget = $b.budget }
    }
    catch { return (New-ExecutionBudgetError -Code 'INTERNAL_ERROR') }
}

function Test-ExecutionBudgetObject {
    <#
    .SYNOPSIS
        Validates a budget object (profile known, strict ints, no_progress
        <= wall, soft < hard). Returns @{valid, errors}. Never throws.
    #>
    [CmdletBinding()]
    param($Budget)
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -eq $Budget) { $errors.Add('budget-missing') | Out-Null; return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) } }
        $get = {
            param($Node, $Name)
            try {
                if ($Node -is [System.Collections.IDictionary]) {
                    if ($Node.Contains($Name)) { return $Node[$Name] }
                    return $null
                }
                $pp = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
                if ($null -ne $pp) { return $pp.Value }
                return $null
            }
            catch { return $null }
        }
        $prof = [string](& $get $Budget 'profile')
        if ([string]::IsNullOrWhiteSpace((Get-ExecutionBudgetProfileName -Profile $prof))) { $errors.Add('profile-invalid') | Out-Null }
        $sb = (& $get $Budget 'step_budget')
        $wc = (& $get $Budget 'wall_clock_seconds')
        $np = (& $get $Budget 'no_progress_seconds')
        $soft = (& $get $Budget 'repeated_action_soft_limit')
        $hard = (& $get $Budget 'repeated_action_hard_limit')
        $cyc = (& $get $Budget 'cycle_repeat_limit')
        $prv = (& $get $Budget 'provider_retry_limit')
        if (-not (Test-ExecutionBudgetInt -Value $sb -Min 1 -Max 86400)) { $errors.Add('step_budget-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $wc -Min 1 -Max 86400)) { $errors.Add('wall_clock_seconds-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $np -Min 1 -Max 86400)) { $errors.Add('no_progress_seconds-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $soft -Min 1 -Max 100)) { $errors.Add('repeated_action_soft_limit-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $hard -Min 1 -Max 100)) { $errors.Add('repeated_action_hard_limit-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $cyc -Min 1 -Max 100)) { $errors.Add('cycle_repeat_limit-invalid') | Out-Null }
        if (-not (Test-ExecutionBudgetInt -Value $prv -Min 0 -Max 100)) { $errors.Add('provider_retry_limit-invalid') | Out-Null }
        if (($errors.Count -eq 0) -and ([long]$np -gt [long]$wc)) { $errors.Add('no_progress-must-be-lte-wall') | Out-Null }
        if (($errors.Count -eq 0) -and ([long]$soft -ge [long]$hard)) { $errors.Add('soft-must-be-lt-hard') | Out-Null }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

function Test-ExecutionBudgetOverride {
    <#
    .SYNOPSIS
        Validates a budget against the explicit policy override bounds:
        steps <= 96, worker wall <= 2700, planner wall <= 5400,
        no_progress <= wall and <= 960. Returns @{valid, errors}.
        Never throws.
    #>
    [CmdletBinding()]
    param($Budget, [switch]$IsPlannerTurn, [string]$PolicyPath = '', [string]$RepoRoot = '')
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $base = Test-ExecutionBudgetObject -Budget $Budget
        if (-not [bool]$base.valid) {
            foreach ($e in @($base.errors)) { $errors.Add([string]$e) | Out-Null }
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $slot = Read-ExecutionBudgetPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { $errors.Add('policy-unavailable') | Out-Null; return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) } }
        if ([bool]$slot.malformed) { $errors.Add('policy-invalid') | Out-Null; return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) } }
        $bounds = Get-ExecutionBudgetPolicyNode -Doc $slot.doc -Name 'override_bounds'
        if (($null -eq $bounds) -or -not ($bounds -is [System.Collections.IDictionary])) {
            $errors.Add('override_bounds-missing') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $get = {
            param($Node, $Name)
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains($Name)) { return $Node[$Name] }
                return $null
            }
            $pp = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
            if ($null -ne $pp) { return $pp.Value }
            return $null
        }
        $maxStep = [int](& $get $bounds 'max_step_budget')
        $maxWorker = [int](& $get $bounds 'max_wall_clock_seconds_worker')
        $maxPlanner = [int](& $get $bounds 'max_wall_clock_seconds_planner')
        $maxNp = [int](& $get $bounds 'max_no_progress_seconds')
        $sb = [int](& $get $Budget 'step_budget')
        $wc = [int](& $get $Budget 'wall_clock_seconds')
        $np = [int](& $get $Budget 'no_progress_seconds')
        if ($sb -gt $maxStep) { $errors.Add('step_budget-exceeds-max') | Out-Null }
        $cap = $maxWorker
        if ([bool]$IsPlannerTurn) { $cap = $maxPlanner }
        if ($wc -gt $cap) { $errors.Add('wall_clock-exceeds-max') | Out-Null }
        if ($np -gt $maxNp) { $errors.Add('no_progress-exceeds-max') | Out-Null }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

function Get-ExecutionBudgetDerivedDefault {
    <#
    .SYNOPSIS
        Read-only derived default for records without a budget (backward
        compat). Never writes. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath = '', [string]$RepoRoot = '')
    try {
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
        }
        $slot = Read-ExecutionBudgetPolicy -PolicyPath $pp -RepoRoot $RepoRoot
        $prof = 'standard-write'
        if ([bool]$slot.found -and (-not [bool]$slot.malformed)) {
            $d = ([string](Get-ExecutionBudgetPolicyNode -Doc $slot.doc -Name 'default_profile')).Trim()
            if (-not [string]::IsNullOrWhiteSpace((Get-ExecutionBudgetProfileName -Profile $d))) { $prof = $d }
        }
        $b = Get-ExecutionBudgetProfileBudget -Profile $prof -PolicyPath $pp -RepoRoot $RepoRoot
        if ([bool]$b.ok) {
            return [PSCustomObject]@{ ok = $true; profile = $prof; budget = $b.budget; derived = $true }
        }
        return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
    }
    catch {
        return (New-ExecutionBudgetError -Code 'BUDGET_POLICY_INVALID')
    }
}

# ---------- flags (read-only) ----------

function Get-ExecutionBudgetFlagState {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $out = @{ enabled = $false; shadow = $false }
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-ExecutionBudgetDefaultFlagsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        if ($null -eq $doc) { return $out }
        $be = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('bounded_execution')) { $be = $doc['bounded_execution'] }
        }
        else {
            $prop = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'bounded_execution' } | Select-Object -First 1
            if ($null -ne $prop) { $be = $prop.Value }
        }
        if ($null -eq $be) { return $out }
        foreach ($field in @('enabled', 'shadow')) {
            $slot = $null
            if ($be -is [System.Collections.IDictionary]) {
                if ($be.Contains($field)) { $slot = $be[$field] }
            }
            else {
                $fp = $be.PSObject.Properties | Where-Object { $_.Name -ceq $field } | Select-Object -First 1
                if ($null -ne $fp) { $slot = $fp.Value }
            }
            if (($null -ne $slot) -and ($slot -is [bool])) {
                if ($field -ceq 'enabled') { $out.enabled = [bool]$slot }
                else { $out.shadow = [bool]$slot }
            }
        }
    }
    catch { return $out }
    return $out
}

function Get-ExecutionBudgetEnforcementState {
    <#
    .SYNOPSIS
        Phase 23 shadow posture: enforcement is always OFF; the budget is
        recorded, never enforced. Returns the flag values plus the note.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    try {
        $f = Get-ExecutionBudgetFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        return [PSCustomObject]@{
            enforce = $false
            enabled = [bool]$f.enabled
            shadow  = [bool]$f.shadow
            note    = 'phase23-shadow-only: budgets are recorded, never enforced; native renderer fields HOLD'
        }
    }
    catch {
        return [PSCustomObject]@{
            enforce = $false; enabled = $false; shadow = $false
            note    = 'phase23-shadow-only: budgets are recorded, never enforced; native renderer fields HOLD'
        }
    }
}
