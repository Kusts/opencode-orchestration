<#!
.SYNOPSIS
    Task D follow-up: behavioural proof for the Jev flag-gate dedup.
.DESCRIPTION
    The old PlannerLoop pre-checked the flags registry node and, when the node
    was ABSENT, returned the closed envelope 'jev-advisory-flag-absent' without
    calling the lib. After removing that duplicate read, Invoke-JevAdvisoryCall
    owns the gate and returns JEV_FLAG_INVALID; the loop maps it back to the
    exact old envelope.

    This suite proves, with a trigger-satisfying descriptor and a counting
    probe, that:
      - flag ABSENT  : zero probe/transport calls, old envelope preserved;
      - flag DISABLED: zero probe/transport calls, JEV_DISABLED (same as base);
      - flag ACTIVE  : exactly one probe call (positive control for the seam);
      - plan/route/authoritative are unchanged in every case;
      - a runtime run of the BASE commit (a09a1a2) produces byte-identical
        plans for the absent and disabled fixtures.

    ASCII-only. PowerShell 5.1 and 7 compatible.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$v3Root = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3Root)
$loopPath = Join-Path $v3Root 'lib\OrchestrationPlannerLoop.ps1'
$jevPath = Join-Path $v3Root 'lib\OrchestrationJevAdvisory.ps1'
$now = '2026-11-20T00:00:00.0000000Z'
$baseSha = 'a09a1a2db6b96bb9537b2e78d01f923dd53fdd29'
$script:checks = @()
function Check { param([string]$Name, [bool]$Ok); $script:checks += [pscustomobject]@{ Name = $Name; Ok = $Ok }; Write-Output (($(if ($Ok) { 'PASS ' } else { 'FAIL ' })) + $Name) }
function Strip-Jev { param($Plan); $c = $Plan.PSObject.Copy(); $c.PSObject.Properties.Remove('jev_advisory_result'); return (ConvertTo-Json -InputObject $c -Depth 16 -Compress) }
function HitCount { param([string]$Path); if (-not (Test-Path -LiteralPath $Path)) { return 0 }; return ([regex]::Matches([IO.File]::ReadAllText($Path), 'hit;')).Count }
function New-Probe { param([string]$Marker); return [scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');[pscustomobject]@{{model='jev-latest';answers=[pscustomobject]@{{route=[pscustomobject]@{{type='choice';choice='minimal';confidence=0.8}}}};usage=[pscustomobject]@{{input_tokens=1;output_tokens=1}}}}" -f $Marker)) }

# Cheap structural guards (not the proof; the behavioural cases below are).
$loopSrc = [IO.File]::ReadAllText($loopPath)
$jevSrc = [IO.File]::ReadAllText($jevPath)
Check 'flag-gate-not-duplicated-in-planner-loop' ($loopSrc -notmatch 'Get-JevAdvisoryFlag')
Check 'flag-gate-owned-by-jev-lib' ($jevSrc -match 'Get-JevAdvisoryFlag')
Check 'flag-gate-read-once-in-owner' ((([regex]::Matches($jevSrc, 'Get-JevAdvisoryFlag\s+-FlagsPath')).Count) -eq 1)

$opt = @{ timestamp = $now }
# Descriptor known to satisfy Test-JevAdvisoryTrigger (reason model-route-uncertain).
$desc = @{ objective = 'Plan under model-route uncertainty'; risk = 'low'; model_route_uncertain = $true }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('taskd-jev-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$oldKey = $env:JEV_API_KEY
try {
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY', 'sk-SYNTHETICSECRET-TASKD-CANARY')
    $tele = Join-Path $tmpRoot 'tele'; New-Item -ItemType Directory -Path $tele -Force | Out-Null
    $opt.jev_advisory_telemetry_root = $tele

    $absentJson = '{ "runtime_support": { "v1": false } }'
    $disabledJson = '{ "jev_advisory": { "enabled": false, "shadow": false } }'
    $activeJson = '{ "jev_advisory": { "enabled": true, "shadow": false } }'
    $fxAbsent = Join-Path $tmpRoot 'flags-absent.json'
    $fxDisabled = Join-Path $tmpRoot 'flags-disabled.json'
    $fxActive = Join-Path $tmpRoot 'flags-active.json'
    [IO.File]::WriteAllText($fxAbsent, $absentJson)
    [IO.File]::WriteAllText($fxDisabled, $disabledJson)
    [IO.File]::WriteAllText($fxActive, $activeJson)

    . $loopPath

    # ---- Section B: behavioural cases through the CURRENT PlannerLoop -------
    $mAbsent = Join-Path $tmpRoot 'm-absent.txt'
    $mDisabled = Join-Path $tmpRoot 'm-disabled.txt'
    $mActive = Join-Path $tmpRoot 'm-active.txt'
    $rAbsent = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mAbsent) -JevAdvisoryFlagsPath $fxAbsent
    $rDisabled = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mDisabled) -JevAdvisoryFlagsPath $fxDisabled
    $rActive = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mActive) -JevAdvisoryFlagsPath $fxActive

    Check 'absent-flag-trigger-did-fire' ([bool]$rAbsent.plan.jev_triggers.should_consult)
    Check 'absent-flag-zero-probe-calls' ((HitCount $mAbsent) -eq 0)
    Check 'disabled-flag-zero-probe-calls' ((HitCount $mDisabled) -eq 0)
    Check 'active-flag-probe-is-wired-once' ((HitCount $mActive) -eq 1 -and [bool]$rActive.plan.jev_advisory_result.consulted)

    $ja = $rAbsent.plan.jev_advisory_result
    Check 'absent-flag-old-envelope-preserved' ($ja.status -ceq 'unavailable' -and $ja.reason -ceq 'jev-advisory-flag-absent' -and (-not [bool]$ja.consulted) -and (-not [bool]$ja.would_consult) -and (-not [bool]$ja.evaluated) -and $ja.advice_state -ceq 'NOT_CONSULTED' -and [bool]$ja.fallback_continue -and (-not [bool]$ja.blocked) -and (-not [bool]$ja.authoritative) -and [bool]$ja.recommendation_only)
    $jd = $rDisabled.plan.jev_advisory_result
    Check 'disabled-flag-canonical-status' ($jd.status -ceq 'JEV_DISABLED' -and (-not [bool]$jd.consulted) -and [bool]$jd.fallback_continue -and (-not [bool]$jd.blocked) -and (-not [bool]$jd.authoritative))

    $planA = Strip-Jev $rAbsent.plan
    $planD = Strip-Jev $rDisabled.plan
    $planV = Strip-Jev $rActive.plan
    Check 'plan-identical-across-flag-modes' ($planA -ceq $planD -and $planA -ceq $planV)
    Check 'route-and-authority-unchanged' ($rAbsent.plan.dispatch_plan.workers.Count -ge 1 -and (-not [bool]$rAbsent.plan.jev_advisory.authoritative) -and $rAbsent.plan.jev_advisory.kernel_authority -ceq 'planner/kernel')
    # No DONE key is ever produced by the planner record.
    Check 'no-done-key-in-plans' (($rAbsent.plan.PSObject.Properties.Name -notcontains 'done') -and ($rDisabled.plan.PSObject.Properties.Name -notcontains 'done'))

    # ---- Section C: runtime comparison against the BASE commit --------------
    $tmpBase = Join-Path $tmpRoot 'base'
    $baseLib = Join-Path $tmpBase 'scripts\v3\lib'
    $baseReg = Join-Path $tmpBase 'source\registry'
    New-Item -ItemType Directory -Path $baseLib -Force | Out-Null
    New-Item -ItemType Directory -Path $baseReg -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $v3Root 'lib') -Filter '*.ps1' -File | Copy-Item -Destination $baseLib -Force
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'source\registry') -File | Copy-Item -Destination $baseReg -Force
    $baseSrc = (& git -C $repoRoot show ($baseSha + ':scripts/v3/lib/OrchestrationPlannerLoop.ps1') | Out-String)
    [IO.File]::WriteAllText((Join-Path $baseLib 'OrchestrationPlannerLoop.ps1'), $baseSrc)
    $canonicalFlags = Join-Path $baseReg 'capability-flags.json'
    $mBaseA = Join-Path $tmpRoot 'm-base-absent.txt'
    $mBaseD = Join-Path $tmpRoot 'm-base-disabled.txt'

    # Base + ABSENT (node removed from the temp canonical flags file).
    [IO.File]::WriteAllText($canonicalFlags, $absentJson)
    . (Join-Path $baseLib 'OrchestrationPlannerLoop.ps1')
    $bAbsent = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mBaseA)
    . $loopPath
    $cAbsent = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mAbsent) -JevAdvisoryFlagsPath $canonicalFlags
    Check 'base-vs-current-absent-byte-identical' ([string]$bAbsent.plan_json -ceq [string]$cAbsent.plan_json)
    Check 'base-absent-old-envelope' ($bAbsent.plan.jev_advisory_result.status -ceq 'unavailable' -and $bAbsent.plan.jev_advisory_result.reason -ceq 'jev-advisory-flag-absent')
    Check 'base-absent-zero-probe-calls' ((HitCount $mBaseA) -eq 0)

    # Base + DISABLED.
    [IO.File]::WriteAllText($canonicalFlags, $disabledJson)
    . (Join-Path $baseLib 'OrchestrationPlannerLoop.ps1')
    $bDisabled = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mBaseD)
    . $loopPath
    $cDisabled = Invoke-OrchestrationPlannerLoop $desc $opt -JevAdvisoryProbe (New-Probe $mDisabled) -JevAdvisoryFlagsPath $canonicalFlags
    Check 'base-vs-current-disabled-byte-identical' ([string]$bDisabled.plan_json -ceq [string]$cDisabled.plan_json)
    Check 'base-disabled-canonical-status' ($bDisabled.plan.jev_advisory_result.status -ceq 'JEV_DISABLED')
    Check 'base-disabled-zero-probe-calls' ((HitCount $mBaseD) -eq 0)
} finally {
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY', $oldKey)
    try { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

$okCount = @($script:checks | Where-Object { $_.Ok }).Count
$total = @($script:checks).Count
Write-Output ('RESULT: ' + $okCount + '/' + $total + ' PASS')
if ($okCount -ne $total) { exit 1 }
exit 0
