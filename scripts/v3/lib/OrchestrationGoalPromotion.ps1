<#!
.SYNOPSIS
    V3 Auto Goal Promotion: pure promotion scoring (SPEC v0.1.0 Phase 7).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure functions,
    fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns a task-shaped envelope
    (promote=$false, score=0). No network, no process, no store, no
    kernel, no dispatch. This lib only scores; promotion wiring belongs
    to a later phase (never here).

    TDR-F7 (promotion scoring, explainable, threshold >= 3):
    Test-OrchestrationGoalPromotion maps one signal snapshot to one
    scoring envelope: promote, score, shape, reasons. Weights:
      spec_plan present (SPEC + PLAN) ................. +3
      phase_count >= 3 ................................ +2
      phase_count == 2 ................................ +1
      expected_waves >= 3 ............................. +1
      criteria_count >= 3 ............................. +1
      likely_cross_session ............................ +2
      iterative_verification .......................... +1
      explicit_continuation ........................... +2
    Negative counts clamp to 0. Score >= 3 promotes to
    'persistent-goal'; otherwise the shape stays 'task'. SPEC + PLAN
    alone promotes (strong PLAN preference); 2 phases alone do not
    (Jev advisory threshold three, weak 0.24, composed by Planner).
    Reasons carry one stable token per contributing signal plus a final
    verdict token ('threshold-met' or 'below-threshold').
#>
[CmdletBinding()]
param()

$script:GPPromotionThreshold = 3

function Get-GPField {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Get-GPGateBool {
    param($Value)
    try {
        if ($Value -is [bool]) { return [bool]$Value }
        return $false
    }
    catch { return $false }
}

function Get-GPPromotionCount {
    param($Value)
    try {
        if ($null -eq $Value) { return [long]0 }
        if ($Value -is [long]) {
            if ([long]$Value -lt 0) { return [long]0 }
            return [long]$Value
        }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) {
            $n = [long]$Value
            if ($n -lt 0) { return [long]0 }
            return $n
        }
        return [long]0
    }
    catch { return [long]0 }
}

function New-GPPromotionResult {
    param([bool]$Promote, [long]$Score, [string]$Shape, [string[]]$Reasons)
    try {
        $s = [long]$Score
        if ($s -lt 0) { $s = 0 }
        $names = @('task', 'persistent-goal')
        $sh = ([string]$Shape).Trim().ToLowerInvariant()
        if ($names -cnotcontains $sh) {
            if ($Promote) { $sh = 'persistent-goal' } else { $sh = 'task' }
        }
        $list = @()
        if ($null -ne $Reasons) {
            foreach ($r in @($Reasons)) {
                if ($r -is [string] -and (-not [string]::IsNullOrWhiteSpace([string]$r))) {
                    $list += [string]$r
                }
            }
        }
        return [PSCustomObject][ordered]@{
            promote = [bool]$Promote
            score   = $s
            shape   = $sh
            reasons = [string[]]$list
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            promote = $false
            score   = [long]0
            shape   = 'task'
            reasons = [string[]]@('invalid-signals')
        }
    }
}

function Test-OrchestrationGoalPromotion {
    <#
    .SYNOPSIS
        Pure promotion scoring (TDR-F7).
    .DESCRIPTION
        Maps one signal snapshot (hashtable or PSObject, all fields
        optional) to one scoring envelope: promote, score, shape,
        reasons. Accepted fields: has_spec_plan (strict bool),
        phase_count / expected_waves / criteria_count (int-like,
        negatives clamp to 0, non-numeric reads as 0),
        likely_cross_session / iterative_verification /
        explicit_continuation (strict bool). Non-object input fails
        closed to a task envelope with reason 'invalid-signals'.
        Never throws, never returns $null.
    #>
    [CmdletBinding()]
    param($Signals = $null)
    try {
        if (($null -eq $Signals) -or ((-not ($Signals -is [System.Collections.IDictionary])) -and (-not ($Signals -is [pscustomobject])))) {
            return (New-GPPromotionResult -Promote $false -Score 0 -Shape 'task' -Reasons @('invalid-signals'))
        }
        $hasSpec = Get-GPGateBool (Get-GPField $Signals 'has_spec_plan')
        $phases = Get-GPPromotionCount (Get-GPField $Signals 'phase_count')
        $waves = Get-GPPromotionCount (Get-GPField $Signals 'expected_waves')
        $criteria = Get-GPPromotionCount (Get-GPField $Signals 'criteria_count')
        $cross = Get-GPGateBool (Get-GPField $Signals 'likely_cross_session')
        $iter = Get-GPGateBool (Get-GPField $Signals 'iterative_verification')
        $expl = Get-GPGateBool (Get-GPField $Signals 'explicit_continuation')
        $score = [long]0
        $reasons = New-Object System.Collections.ArrayList
        if ($hasSpec) { $score += 3; [void]$reasons.Add('spec-plan') }
        if ($phases -ge 3) { $score += 2; [void]$reasons.Add('phases>=3') }
        elseif ($phases -eq 2) { $score += 1; [void]$reasons.Add('phases==2') }
        if ($waves -ge 3) { $score += 1; [void]$reasons.Add('waves>=3') }
        if ($criteria -ge 3) { $score += 1; [void]$reasons.Add('criteria>=3') }
        if ($cross) { $score += 2; [void]$reasons.Add('cross-session') }
        if ($iter) { $score += 1; [void]$reasons.Add('iterative-verification') }
        if ($expl) { $score += 2; [void]$reasons.Add('explicit-continuation') }
        if ($score -ge $script:GPPromotionThreshold) {
            [void]$reasons.Add('threshold-met')
            return (New-GPPromotionResult -Promote $true -Score $score -Shape 'persistent-goal' -Reasons ([string[]]$reasons.ToArray()))
        }
        [void]$reasons.Add('below-threshold')
        return (New-GPPromotionResult -Promote $false -Score $score -Shape 'task' -Reasons ([string[]]$reasons.ToArray()))
    }
    catch {
        return (New-GPPromotionResult -Promote $false -Score 0 -Shape 'task' -Reasons @('invalid-signals'))
    }
}
