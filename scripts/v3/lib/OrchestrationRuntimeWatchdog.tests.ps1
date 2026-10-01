<#!
.SYNOPSIS
    Tests for lib/OrchestrationRuntimeWatchdog.ps1 (Phase 25, shadow only).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP for telemetry + fixture flags,
    cleanup in finally. Bracketed output the runner parses. Exit 0 on all
    pass, exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
    Covers: fingerprint normalization + secret redaction (canary
    sk-SYNTHETICSECRET never persisted), suffix-post-progress repetition
    semantics (soft/hard/cycle, incl. old-progress cases X,A x5 and
    same-identity progress-first), healthy worker NONE, synthetic
    no-return HARD_TIMEOUT in shadow (would-interrupt recorded, nothing
    actually interrupted), long-but-progressing no NO_PROGRESS,
    NO_PROGRESS threshold, BUDGET_NEAR_LIMIT advisory at 80%, flag seam
    (disabled / shadow / enforcement-not-implemented), history cap 256
    with oldest eviction, limits read from policy (no literals),
    telemetry sanitized + bounded under an exclusive lock (fail-closed
    on accounting failure), per-field fingerprint redaction (distinct
    targets/classes stay distinct), mandatory observe identity, silent
    NO_PROGRESS hang persisted in JSONL, re-register keeps the exact
    clock plus history (proven by behavior), SK-/Sk- case-insensitive,
    shadow read-only over task records.
    Phase 25 never interrupts: every would_interrupt=true assert also
    proves the execution is still registered and no task file was
    written.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationRuntimeWatchdog.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-Watchdog {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-WatchdogFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-WatchdogTinyBudget {
    param([int]$Steps, [int]$Wall, [int]$NoProg)
    return [ordered]@{
        profile = 'fast'; step_budget = $Steps; wall_clock_seconds = $Wall
        no_progress_seconds = $NoProg; repeated_action_soft_limit = 3
        repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoPolicy = Join-Path $repo 'source\registry\execution-budget-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'
$repoTasksDir = Join-Path $repo 'cache\runtime\tasks'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-watchdog-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'telemetry'
$flagsDisabled = Join-Path $tempRoot 'flags-disabled.json'
$flagsShadow = Join-Path $tempRoot 'flags-shadow.json'
$flagsEnforce = Join-Path $tempRoot 'flags-enforce.json'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
Write-WatchdogFixture -Path $flagsDisabled -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
Write-WatchdogFixture -Path $flagsShadow -Text '{"watchdog":{"enabled":false,"shadow":true}}'
Write-WatchdogFixture -Path $flagsEnforce -Text '{"watchdog":{"enabled":true,"shadow":false}}'

function Get-WatchdogTeleText {
    $acc = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $teleRoot -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $acc += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    return $acc
}

try {
    Clear-OrchestrationWatchdogState

    # 1. fingerprint normalization (independent expectation: case/space/separator collapse)
    $n1 = Get-WatchdogActionFingerprint -Tool 'Shell' -Arguments 'git  status --short' -Target 'repo\' -ResultClass ''
    $n2 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'git status --short' -Target 'repo/' -ResultClass ''
    Assert-Watchdog ((-not [string]::IsNullOrWhiteSpace($n1)) -and ($n1 -ceq $n2) -and ($n1 -cmatch '^[0-9a-f]{64}$')) 'fingerprint normalized + 64-hex' ($n1)

    # 2. secret redaction BEFORE hash: distinct secrets converge, nothing leaks
    $s1 = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=abc123' -Target 'remote' -ResultClass ''
    $s2 = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=zzz999' -Target 'remote' -ResultClass ''
    Assert-Watchdog (($s1 -ceq $s2) -and ($s1 -notmatch 'abc123') -and ($s1 -notmatch 'zzz999')) 'secret values redacted before hash' ($s1)
    $c1 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo sk-SYNTHETICSECRET-1' -Target 'repo' -ResultClass ''
    $c2 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo sk-SYNTHETICSECRET-2' -Target 'repo' -ResultClass ''
    $cr = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo <redacted>' -Target 'repo' -ResultClass ''
    Assert-Watchdog (($c1 -ceq $c2) -and ($c1 -ceq $cr) -and ($c1 -notmatch 'SYNTHETICSECRET')) 'canary redacted, converges to redacted form' ($c1)
    Assert-Watchdog (([string]::IsNullOrWhiteSpace((Get-WatchdogActionFingerprint -Tool '' -Arguments 'x' -Target 'y' -ResultClass '')))) 'empty tool rejected with empty digest' ''

    # 3. loop limits come from the central policy (read independently, no literals)
    $lim = Get-WatchdogLoopLimits -PolicyPath $repoPolicy -RepoRoot $repo
    $rawDoc = ([IO.File]::ReadAllText($repoPolicy, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $rawSoft = [int]$rawDoc.loop_guard.repeated_action_soft_limit
    $rawHard = [int]$rawDoc.loop_guard.repeated_action_hard_limit
    $rawCyc = [int]$rawDoc.loop_guard.cycle_repeat_limit
    Assert-Watchdog (([bool]$lim.ok) -and ([int]$lim.soft -eq $rawSoft) -and ([int]$lim.hard -eq $rawHard) -and ([int]$lim.cycle -eq $rawCyc) -and ($rawSoft -eq 3) -and ($rawHard -eq 5) -and ($rawCyc -eq 3)) 'limits mirror central policy loop_guard' (([string]$lim.soft + '/' + [string]$lim.hard + '/' + [string]$lim.cycle))

    # 4. flag seam: repo flags are shadow (enabled=false, shadow=true) -> register works
    $fr = Get-WatchdogFlagState -FlagsPath $repoFlags -RepoRoot $repo
    Assert-Watchdog ((-not [bool]$fr.enabled) -and ([bool]$fr.shadow)) 'repo flags watchdog enabled=false shadow=true' ''
    $gShadow = Get-WatchdogGate -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ($gShadow -ceq 'SHADOW') 'explicit shadow fixture gates SHADOW' ($gShadow)
    $gDis = Get-WatchdogGate -FlagsPath $flagsDisabled -RepoRoot $repo
    Assert-Watchdog ($gDis -ceq 'DISABLED') 'flags without watchdog node gate DISABLED' ($gDis)

    # 5. disabled seam: every entry point refuses without effect
    $dReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-disabled-1' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -FlagsPath $flagsDisabled -RepoRoot $repo
    Assert-Watchdog (([string]$dReg.error -ceq 'WATCHDOG_DISABLED') -and (-not [bool]$dReg.ok)) 'disabled register returns WATCHDOG_DISABLED' ([string]$dReg.error)
    $dAdd = Add-OrchestrationWatchdogAction -TaskId 'wd-disabled-1' -Tool 'shell' -FlagsPath $flagsDisabled -RepoRoot $repo
    Assert-Watchdog ([string]$dAdd.error -ceq 'WATCHDOG_DISABLED') 'disabled observe returns WATCHDOG_DISABLED' ([string]$dAdd.error)
    $dEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-disabled-1' -FlagsPath $flagsDisabled -RepoRoot $repo
    Assert-Watchdog ([string]$dEval.error -ceq 'WATCHDOG_DISABLED') 'disabled evaluate returns WATCHDOG_DISABLED' ([string]$dEval.error)

    # 6. enforcement seam: honest not-implemented, nothing stored
    $eReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-enforce-1' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -FlagsPath $flagsEnforce -RepoRoot $repo
    Assert-Watchdog ([string]$eReg.error -ceq 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') 'enabled=true returns ENFORCEMENT_NOT_IMPLEMENTED' ([string]$eReg.error)
    $eLookup = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enforce-1' -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$eLookup.error -ceq 'NOT_REGISTERED') 'rejected enforcement stored nothing' ([string]$eLookup.error)

    # 7. id validation (closed charset, existing convention)
    $bTiny = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 300
    $badId = Register-OrchestrationWatchdogExecution -TaskId 'BAD ID!!' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -Budget $bTiny -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$badId.error -ceq 'INVALID_TASK_ID') 'free-text task id rejected' ([string]$badId.error)
    $badAtt = Register-OrchestrationWatchdogExecution -TaskId 'wd-bad-att' -AttemptN 'x' -SessionId 'wd-sess-1' -Role 'coder' -Budget $bTiny -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$badAtt.error -ceq 'INVALID_ATTEMPT') 'non-integer attempt rejected' ([string]$badAtt.error)
    $badSess = Register-OrchestrationWatchdogExecution -TaskId 'wd-bad-sess' -AttemptN 1 -SessionId 'ses ****' -Role 'coder' -Budget $bTiny -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$badSess.error -ceq 'INVALID_SESSION_ID') 'free-text session id rejected' ([string]$badSess.error)
    $badBudget = New-WatchdogTinyBudget -Steps 8 -Wall 100 -NoProg 200
    $badB = Register-OrchestrationWatchdogExecution -TaskId 'wd-bad-budget' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -Budget $badBudget -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$badB.error -ceq 'INVALID_BUDGET') 'no_progress above wall rejected' ([string]$badB.error)

    # 8. healthy worker with varied progress is never marked
    $t0 = (Get-Date).ToUniversalTime()
    $bHealthy = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 300
    $hReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-healthy-1' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -Budget $bHealthy -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$hReg.ok) 'healthy register ok in shadow' ''
    $hLast = $null
    $tools = @('shell', 'read', 'shell', 'read', 'shell')
    $args = @('git status --short', 'opencode.json', 'git diff --stat', 'CHANGELOG.md', 'git log --oneline -5')
    for ($i = 0; $i -lt 5; $i++) {
        $hLast = Add-OrchestrationWatchdogAction -TaskId 'wd-healthy-1' -AttemptN 1 -SessionId 'wd-sess-1' -Tool $tools[$i] -Arguments $args[$i] -Target 'repo' -HasProgress $true -AtUtc ($t0.AddSeconds(10 + $i * 10)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([string]$hLast.classification -ceq 'NONE') -and (-not [bool]$hLast.would_interrupt) -and ([bool]$hLast.ok)) 'varied progressing worker stays NONE' ([string]$hLast.classification)

    # 9. synthetic non-returning worker hits HARD_TIMEOUT in shadow; nothing actually happens
    $bShort = New-WatchdogTinyBudget -Steps 4 -Wall 30 -NoProg 10
    $sReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-stall-1' -AttemptN 1 -SessionId 'wd-sess-2' -Role 'coder' -Budget $bShort -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$sReg.ok) 'synthetic stall register ok' ''
    $sEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-stall-1' -AtUtc ($t0.AddSeconds(31)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([string]$sEval.classification -ceq 'HARD_TIMEOUT') -and ([bool]$sEval.would_interrupt)) 'no-return past wall => HARD_TIMEOUT would-interrupt' ([string]$sEval.classification)
    $sStill = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-stall-1' -AtUtc ($t0.AddSeconds(32)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([bool]$sStill.ok) -and ([int]$sStill.steps -eq 0)) 'shadow interrupted nothing: execution intact, steps 0' ([string]$sStill.steps)
    $probeTaskFile = Join-Path $repoTasksDir 'wd-stall-1.json'
    Assert-Watchdog (-not (Test-Path -LiteralPath $probeTaskFile)) 'shadow wrote no task record' ($probeTaskFile)

    # 10. long but progressing worker does not hit NO_PROGRESS
    $bProg = New-WatchdogTinyBudget -Steps 64 -Wall 3600 -NoProg 60
    $pReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-progress-1' -AttemptN 1 -SessionId 'wd-sess-3' -Role 'explorer' -Budget $bProg -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$pReg.ok) 'progressing register ok' ''
    $pLast = $null
    for ($i = 0; $i -lt 6; $i++) {
        $pLast = Add-OrchestrationWatchdogAction -TaskId 'wd-progress-1' -AttemptN 1 -SessionId 'wd-sess-3' -Tool 'shell' -Arguments ('git diff HEAD~' + $i) -Target 'repo' -HasProgress $true -AtUtc ($t0.AddSeconds(50 + $i * 50)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    $pEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-progress-1' -AtUtc ($t0.AddSeconds(340)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([string]$pEval.classification -ceq 'NONE') -and (-not [bool]$pEval.would_interrupt)) 'steady progress over 5min never stalls' ([string]$pEval.classification)

    # 11. genuine no-progress past threshold => NO_PROGRESS suspected + would-interrupt recorded
    $bNp = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 20
    $nReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-noprog-1' -AttemptN 1 -SessionId 'wd-sess-4' -Role 'coder' -Budget $bNp -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$nReg.ok) 'no-progress fixture register ok' ''
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-noprog-1' -AttemptN 1 -SessionId 'wd-sess-4' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $nEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-noprog-1' -AtUtc ($t0.AddSeconds(21)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([string]$nEval.classification -ceq 'NO_PROGRESS') -and ([bool]$nEval.would_interrupt)) 'silence past no_progress => NO_PROGRESS would-interrupt' ([string]$nEval.classification)

    # 12. identical repetition soft (3x) then hard (5x) in the correct window
    $bRep = New-WatchdogTinyBudget -Steps 64 -Wall 3600 -NoProg 900
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-repeat-1' -AttemptN 1 -SessionId 'wd-sess-5' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $rRes = $null
    for ($i = 0; $i -lt 3; $i++) {
        $rRes = Add-OrchestrationWatchdogAction -TaskId 'wd-repeat-1' -AttemptN 1 -SessionId 'wd-sess-5' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([string]$rRes.classification -ceq 'STALL_SUSPECTED') -and (-not [bool]$rRes.would_interrupt)) '3x identical => STALL_SUSPECTED (suspect only)' ([string]$rRes.classification)
    for ($i = 3; $i -lt 5; $i++) {
        $rRes = Add-OrchestrationWatchdogAction -TaskId 'wd-repeat-1' -AttemptN 1 -SessionId 'wd-sess-5' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([string]$rRes.classification -ceq 'REPEATED_ACTION') -and ([bool]$rRes.would_interrupt)) '5x identical => REPEATED_ACTION would-interrupt' ([string]$rRes.classification)
    $rStill = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-repeat-1' -AtUtc ($t0.AddSeconds(6)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$rStill.ok) 'hard stall recorded only: execution still present' ''

    # 13. old progress does not mask a later stall (X,A x5 / X,A x3)
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-oldprog-1' -AttemptN 1 -SessionId 'wd-sess-6' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-oldprog-1' -AttemptN 1 -SessionId 'wd-sess-6' -Tool 'read' -Arguments 'CHANGELOG.md' -Target 'repo' -HasProgress $true -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $oRes = $null
    for ($i = 0; $i -lt 5; $i++) {
        $oRes = Add-OrchestrationWatchdogAction -TaskId 'wd-oldprog-1' -AttemptN 1 -SessionId 'wd-sess-6' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(1 + $i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog ([string]$oRes.classification -ceq 'REPEATED_ACTION') 'X,A x5 progress only in X => REPEATED_ACTION' ([string]$oRes.classification)
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-oldprog-2' -AttemptN 1 -SessionId 'wd-sess-6' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-oldprog-2' -AttemptN 1 -SessionId 'wd-sess-6' -Tool 'read' -Arguments 'CHANGELOG.md' -Target 'repo' -HasProgress $true -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $oRes2 = $null
    for ($i = 0; $i -lt 3; $i++) {
        $oRes2 = Add-OrchestrationWatchdogAction -TaskId 'wd-oldprog-2' -AttemptN 1 -SessionId 'wd-sess-6' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(1 + $i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog ([string]$oRes2.classification -ceq 'STALL_SUSPECTED') 'X,A x3 progress only in X => STALL_SUSPECTED' ([string]$oRes2.classification)

    # 14. same-identity progress-first: suffix after progress still classified
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-sameid-1' -AttemptN 1 -SessionId 'wd-sess-7' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $qRes = $null
    for ($i = 0; $i -lt 4; $i++) {
        $first = ($i -eq 0)
        $qRes = Add-OrchestrationWatchdogAction -TaskId 'wd-sameid-1' -AttemptN 1 -SessionId 'wd-sess-7' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $first -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog ([string]$qRes.classification -ceq 'STALL_SUSPECTED') 'A x4 progress only first => STALL_SUSPECTED' ([string]$qRes.classification)
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-sameid-2' -AttemptN 1 -SessionId 'wd-sess-7' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    for ($i = 0; $i -lt 6; $i++) {
        $first = ($i -eq 0)
        $qRes = Add-OrchestrationWatchdogAction -TaskId 'wd-sameid-2' -AttemptN 1 -SessionId 'wd-sess-7' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $first -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog ([string]$qRes.classification -ceq 'REPEATED_ACTION') 'A x6 progress only first => REPEATED_ACTION' ([string]$qRes.classification)

    # 15. short cycle A-B x3 => REPEATED_CYCLE
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-cycle-1' -AttemptN 1 -SessionId 'wd-sess-8' -Role 'coder' -Budget $bRep -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $yRes = $null
    for ($i = 0; $i -lt 6; $i++) {
        if (($i % 2) -eq 0) { $yRes = Add-OrchestrationWatchdogAction -TaskId 'wd-cycle-1' -AttemptN 1 -SessionId 'wd-sess-8' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot }
        else { $yRes = Add-OrchestrationWatchdogAction -TaskId 'wd-cycle-1' -AttemptN 1 -SessionId 'wd-sess-8' -Tool 'read' -Arguments 'opencode.json' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot }
    }
    Assert-Watchdog (([string]$yRes.classification -ceq 'REPEATED_CYCLE') -and ([bool]$yRes.would_interrupt)) 'A-B x3 without delta => REPEATED_CYCLE would-interrupt' ([string]$yRes.classification)

    # 16. budget near limit advisory at 80% steps (independent: step_budget 10, 8 distinct progressing)
    $bNear = New-WatchdogTinyBudget -Steps 10 -Wall 3600 -NoProg 900
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-near-1' -AttemptN 1 -SessionId 'wd-sess-9' -Role 'coder' -Budget $bNear -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $vRes = $null
    for ($i = 0; $i -lt 8; $i++) {
        $vRes = Add-OrchestrationWatchdogAction -TaskId 'wd-near-1' -AttemptN 1 -SessionId 'wd-sess-9' -Tool 'shell' -Arguments ('git diff HEAD~' + $i) -Target 'repo' -HasProgress $true -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([string]$vRes.classification -ceq 'BUDGET_NEAR_LIMIT') -and (-not [bool]$vRes.would_interrupt)) '8 of 10 steps => BUDGET_NEAR_LIMIT advisory' ([string]$vRes.classification)
    $nearEv = @($vRes.events | Where-Object { [string]$_.event -ceq 'BUDGET_NEAR_LIMIT' })
    Assert-Watchdog ($nearEv.Count -ge 1) 'near-limit telemetry event emitted' ''

    # 17. telemetry sanitized: no secret/canary/raw value persisted
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-secret-1' -AttemptN 1 -SessionId 'wd-sess-10' -Role 'coder' -Budget $bTiny -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-secret-1' -AttemptN 1 -SessionId 'wd-sess-10' -Tool 'mcp' -Arguments 'call memory token=abc123' -Target 'remote' -HasProgress $false -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-secret-1' -AttemptN 1 -SessionId 'wd-sess-10' -Tool 'shell' -Arguments 'echo sk-SYNTHETICSECRET-9' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(1)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $teleText = Get-WatchdogTeleText
    Assert-Watchdog (($teleText -notmatch 'abc123') -and ($teleText -notmatch 'SYNTHETICSECRET')) 'telemetry holds no secret or canary' ''
    Assert-Watchdog (($teleText -match 'WATCHDOG_WOULD_INTERRUPT') -and ($teleText -match 'STALL_SUSPECTED')) 'shadow telemetry carries expected event tokens' ''

    # 18. history cap 256 with oldest eviction (independent: 260 distinct progressing actions)
    $bBig = New-WatchdogTinyBudget -Steps 400 -Wall 3600 -NoProg 900
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-cap-1' -AttemptN 1 -SessionId 'wd-sess-11' -Role 'coder' -Budget $bBig -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $capRes = $null
    for ($i = 0; $i -lt 260; $i++) {
        $capRes = Add-OrchestrationWatchdogAction -TaskId 'wd-cap-1' -AttemptN 1 -SessionId 'wd-sess-11' -Tool 'shell' -Arguments ('probe item ' + $i) -Target 'repo' -HasProgress $true -AtUtc ($t0.AddSeconds($i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([int]$capRes.steps -eq 260) -and ([int]$capRes.history_evicted -eq 4)) 'history capped at 256, oldest evicted with counter' (([string]$capRes.steps + '/' + [string]$capRes.history_evicted))
    Assert-Watchdog ([string]$capRes.classification -ceq 'NONE') 'capped progressing history stays NONE' ([string]$capRes.classification)

    # 19. HIGH: silent zero-action past deadline via evaluation emits HARD_TIMEOUT telemetry
    $teleSilent = Join-Path $tempRoot 'telemetry-silent'
    New-Item -ItemType Directory -Path $teleSilent -Force | Out-Null
    $bSilent = New-WatchdogTinyBudget -Steps 32 -Wall 30 -NoProg 10
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-silent-1' -AttemptN 1 -SessionId 'wd-sess-20' -Role 'coder' -Budget $bSilent -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $silEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-silent-1' -AtUtc ($t0.AddSeconds(31)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleSilent
    Assert-Watchdog (([string]$silEval.classification -ceq 'HARD_TIMEOUT') -and ([bool]$silEval.would_interrupt)) 'silent zero-action past wall => HARD_TIMEOUT' ([string]$silEval.classification)
    $silText = ''
    try { foreach ($f in @(Get-ChildItem -LiteralPath $teleSilent -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) { $silText += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } } catch { }
    Assert-Watchdog (($silText -match 'WATCHDOG_WOULD_INTERRUPT') -and ($silText -match 'HARD_TIMEOUT')) 'silent hang persisted HARD_TIMEOUT event in JSONL' ''
    $silStill = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-silent-1' -AtUtc ($t0.AddSeconds(32)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleSilent
    Assert-Watchdog (([bool]$silStill.ok) -and ([int]$silStill.steps -eq 0)) 'silent eval interrupted nothing: steps still 0' ([string]$silStill.steps)
    Assert-Watchdog (-not (Test-Path -LiteralPath (Join-Path $repoTasksDir 'wd-silent-1.json'))) 'silent eval wrote no task record' ''

    # 20. HIGH: deadline wins over simultaneous hard repetition (main event = HARD_TIMEOUT)
    $teleRace = Join-Path $tempRoot 'telemetry-race'
    New-Item -ItemType Directory -Path $teleRace -Force | Out-Null
    $bRace = New-WatchdogTinyBudget -Steps 64 -Wall 5 -NoProg 5
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-race-1' -AttemptN 1 -SessionId 'wd-sess-21' -Role 'coder' -Budget $bRace -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $raceRes = $null
    for ($i = 0; $i -lt 5; $i++) {
        $raceRes = Add-OrchestrationWatchdogAction -TaskId 'wd-race-1' -AttemptN 1 -SessionId 'wd-sess-21' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(6 + $i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRace
    }
    Assert-Watchdog ([string]$raceRes.classification -ceq 'HARD_TIMEOUT') 'deadline + hard repetition => HARD_TIMEOUT wins' ([string]$raceRes.classification)
    $raceMain = @($raceRes.events | Where-Object { [string]$_.event -ceq 'WATCHDOG_WOULD_INTERRUPT' } | Select-Object -First 1)
    Assert-Watchdog ((@($raceMain).Count -ge 1) -and ([string]$raceMain[0].class -ceq 'HARD_TIMEOUT')) 'main event derived from classification HARD_TIMEOUT' ''

    # 21. MEDIUM identity: stale attempt rejected, same-identity re-register idempotent
    $bId = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 300
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-ident-1' -AttemptN 1 -SessionId 'wd-sess-30' -Role 'coder' -Budget $bId -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-ident-1' -AttemptN 1 -SessionId 'wd-sess-30' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $true -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $stale = Add-OrchestrationWatchdogAction -TaskId 'wd-ident-1' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(5)) -AttemptN 2 -SessionId 'wd-sess-30' -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([string]$stale.error -ceq 'IDENTITY_CONFLICT') -and (-not [bool]$stale.ok)) 'late event from prior attempt rejected' ([string]$stale.error)
    $afterStale = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-ident-1' -AtUtc ($t0.AddSeconds(6)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([bool]$afterStale.ok) -and ([int]$afterStale.steps -eq 1)) 'rejected observation mutated nothing (steps still 1)' ([string]$afterStale.steps)
    $reReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-ident-1' -AttemptN 1 -SessionId 'wd-sess-30' -Role 'coder' -Budget $bId -StartedAtUtc ($t0.AddSeconds(999)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([bool]$reReg.ok) -and ([bool]$reReg.idempotent)) 'same-identity re-register idempotent' ''
    $afterRe = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-ident-1' -AtUtc ($t0.AddSeconds(7)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([int]$afterRe.steps -eq 1) -and ([string]$afterRe.classification -ceq 'NONE')) 'idempotent re-register kept clock and history' (([string]$afterRe.steps + '/' + [string]$afterRe.classification))
    $confReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-ident-1' -AttemptN 2 -SessionId 'wd-sess-30' -Role 'coder' -Budget $bId -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([string]$confReg.error -ceq 'IDENTITY_CONFLICT') 'different identity on same task rejected' ([string]$confReg.error)

    # 22. MEDIUM+LOW cap: pre-size accounting drops event that would overflow, file stays <= cap
    $teleCap = Join-Path $tempRoot 'telemetry-cap'
    New-Item -ItemType Directory -Path $teleCap -Force | Out-Null
    $savedCap = $script:WatchdogTelemetryCapBytes
    $script:WatchdogTelemetryCapBytes = 600
    try {
        [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-tcap-1' -AttemptN 1 -SessionId 'wd-sess-40' -Role 'coder' -Budget $bId -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
        $w1 = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-tcap-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleCap -RepoRoot $repo
        Assert-Watchdog ([bool]$w1.ok) 'first cap event written' ''
        $targetCap = Get-WatchdogTelemetryFile -TelemetryRoot $teleCap -RepoRoot $repo
        $curLen = ([IO.FileInfo]::new($targetCap)).Length
        $remain = 600 - $curLen
        Assert-Watchdog ($remain -gt 0) 'cap test has remainder to overflow' ([string]$remain)
        $script:WatchdogTelemetryCapBytes = ($curLen + 10)
        $w2 = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-tcap-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 2 -ElapsedSeconds 2 -TelemetryRoot $teleCap -RepoRoot $repo
        Assert-Watchdog (((-not [bool]$w2.ok)) -and ([string]$w2.skipped -ceq 'rotation-cap')) 'overflowing event honestly dropped' ([string]$w2.skipped)
        $finalLen = ([IO.FileInfo]::new($targetCap)).Length
        Assert-Watchdog ($finalLen -le ($curLen + 10)) 'bounded file never exceeds cap' (([string]$finalLen))
    }
    finally { $script:WatchdogTelemetryCapBytes = $savedCap }

    # 23. LOW sanitization: JEV_API_KEY case/space/equals variants converge, no leak
    $j1 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'call JEV_API_KEY abcSYNTH1' -Target 'repo' -ResultClass ''
    $j2 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'call jev_api_key=abcSYNTH2' -Target 'repo' -ResultClass ''
    $j3 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'call Jev_Api_Key:  abcSYNTH3' -Target 'repo' -ResultClass ''
    Assert-Watchdog ((($j1 -ceq $j2) -and ($j2 -ceq $j3)) -and ($j1 -cmatch '^[0-9a-f]{64}$')) 'JEV_API_KEY variants converge case-insensitively' ($j1)
    Assert-Watchdog ((($j1 -notmatch 'abcSYNTH1') -and ($j1 -notmatch 'abcSYNTH2')) -and ($j1 -notmatch 'SYNTH')) 'JEV synthetic values never leak into digest' ''

    # 24. REVIEW per-field sanitization + unambiguous composition: distinct
    #     secrets converge only when target/class match; target and class
    #     vary on SEPARATE axes (four combos with independent expectations);
    #     a literal '|' inside a field never shifts boundaries (length
    #     prefix disambiguates: old naive '|' join merged the pipe pair)
    $pfA = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=AAA111' -Target 'repo-a' -ResultClass 'ok'
    $pfB = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=BBB222' -Target 'repo-a' -ResultClass 'ok'
    Assert-Watchdog (($pfA -ceq $pfB) -and ($pfA -cmatch '^[0-9a-f]{64}$')) 'per-field: distinct secrets converge with same target/class' ($pfA)
    $pfBase = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=AAA111' -Target 'repo-a' -ResultClass 'ok'
    $pfSameTC = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=BBB222' -Target 'repo-a' -ResultClass 'ok'
    $pfDiffTarget = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=BBB222' -Target 'repo-b' -ResultClass 'ok'
    $pfDiffClass = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=BBB222' -Target 'repo-a' -ResultClass 'error'
    $pfDiffBoth = Get-WatchdogActionFingerprint -Tool 'mcp' -Arguments 'call memory token=BBB222' -Target 'repo-b' -ResultClass 'error'
    Assert-Watchdog ($pfBase -ceq $pfSameTC) 'per-field: same target+class converges' ''
    Assert-Watchdog (($pfBase -cne $pfDiffTarget) -and ($pfDiffTarget -notmatch 'BBB222')) 'per-field: target-only change stays distinct' ''
    Assert-Watchdog (($pfBase -cne $pfDiffClass) -and ($pfDiffClass -notmatch 'BBB222')) 'per-field: class-only change stays distinct' ''
    Assert-Watchdog (($pfBase -cne $pfDiffBoth) -and ($pfDiffTarget -cne $pfDiffClass)) 'per-field: both-changed distinct, axes independent' ''
    $pipeA = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'x|repo-a' -Target 'repo-b' -ResultClass 'ok'
    $pipeB = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'x' -Target 'repo-a|repo-b' -ResultClass 'ok'
    Assert-Watchdog ((($pipeA -cne $pipeB) -and ($pipeA -cmatch '^[0-9a-f]{64}$')) -and ($pipeB -cmatch '^[0-9a-f]{64}$')) 'unambiguous: pipe pair fingerprints DIFFER' ''

    # 25. REVIEW+SEC observe requires identity: absent/partial rejected, no mutation
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-reqid-1' -AttemptN 1 -SessionId 'wd-sess-50' -Role 'coder' -Budget $bId -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-reqid-1' -AttemptN 1 -SessionId 'wd-sess-50' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $true -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $noId = Add-OrchestrationWatchdogAction -TaskId 'wd-reqid-1' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(5)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (((-not [bool]$noId.ok)) -and ([string]$noId.error -ceq 'INVALID_ATTEMPT')) 'observe without identity rejected' ([string]$noId.error)
    $partAtt = Add-OrchestrationWatchdogAction -TaskId 'wd-reqid-1' -AttemptN 1 -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(5)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (((-not [bool]$partAtt.ok)) -and ([string]$partAtt.error -ceq 'INVALID_SESSION_ID')) 'observe with attempt only rejected' ([string]$partAtt.error)
    $partSess = Add-OrchestrationWatchdogAction -TaskId 'wd-reqid-1' -SessionId 'wd-sess-50' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(5)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (((-not [bool]$partSess.ok)) -and ([string]$partSess.error -ceq 'INVALID_ATTEMPT')) 'observe with session only rejected' ([string]$partSess.error)
    $sessDiv = Add-OrchestrationWatchdogAction -TaskId 'wd-reqid-1' -AttemptN 1 -SessionId 'wd-sess-51' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(5)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (((-not [bool]$sessDiv.ok)) -and ([string]$sessDiv.error -ceq 'IDENTITY_CONFLICT')) 'observe with divergent session rejected in isolation' ([string]$sessDiv.error)
    $afterReq = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-reqid-1' -AtUtc ($t0.AddSeconds(6)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([bool]$afterReq.ok) -and ([int]$afterReq.steps -eq 1)) 'rejected observations mutated nothing (steps still 1)' ([string]$afterReq.steps)

    # 26. SEC accounting failure is fail-closed: refused code, nothing written
    $teleAcct = Join-Path $tempRoot 'telemetry-acct'
    New-Item -ItemType Directory -Path $teleAcct -Force | Out-Null
    $script:WatchdogSimulateAccountingFailure = $true
    try {
        $aFail = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-acct-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleAcct -RepoRoot $repo
        Assert-Watchdog (((-not [bool]$aFail.ok)) -and ([string]$aFail.skipped -ceq 'accounting-unavailable')) 'accounting failure refuses write fail-closed' ([string]$aFail.skipped)
        $acctFiles = @(Get-ChildItem -LiteralPath $teleAcct -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)
        Assert-Watchdog (@($acctFiles).Count -eq 0) 'failed accounting wrote nothing' ''
    }
    finally { $script:WatchdogSimulateAccountingFailure = $false }

    # 27. REVIEW silent NO_PROGRESS hang persists events in JSONL (not only returned)
    $teleNp = Join-Path $tempRoot 'telemetry-noprog'
    New-Item -ItemType Directory -Path $teleNp -Force | Out-Null
    $bNpSilent = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 20
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-npsil-1' -AttemptN 1 -SessionId 'wd-sess-60' -Role 'coder' -Budget $bNpSilent -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    $npEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-npsil-1' -AtUtc ($t0.AddSeconds(21)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleNp
    Assert-Watchdog (([string]$npEval.classification -ceq 'NO_PROGRESS') -and ([bool]$npEval.would_interrupt)) 'silent hang past no_progress => NO_PROGRESS' ([string]$npEval.classification)
    $npText = ''
    try { foreach ($f in @(Get-ChildItem -LiteralPath $teleNp -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) { $npText += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) } } catch { }
    Assert-Watchdog ((($npText -match 'NO_PROGRESS_SUSPECTED') -and ($npText -match 'WATCHDOG_WOULD_INTERRUPT')) -and ($npText -match 'NO_PROGRESS')) 'silent NO_PROGRESS persisted both events in JSONL' ''

    # 28. REVIEW re-register keeps exact clock (elapsed_s, not clamped zero) and
    #     history by behavior (old fingerprints count after re-register)
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-rereg-1' -AttemptN 1 -SessionId 'wd-sess-61' -Role 'coder' -Budget $bId -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-rereg-1' -AttemptN 1 -SessionId 'wd-sess-61' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $true -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $rrRe = Register-OrchestrationWatchdogExecution -TaskId 'wd-rereg-1' -AttemptN 1 -SessionId 'wd-sess-61' -Role 'coder' -Budget $bId -StartedAtUtc ($t0.AddSeconds(999)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([bool]$rrRe.ok) -and ([bool]$rrRe.idempotent)) 're-register same identity idempotent' ''
    $rrEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-rereg-1' -AtUtc ($t0.AddSeconds(7)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([int]$rrEval.elapsed_s -eq 7) -and ([int]$rrEval.steps -eq 1)) 'idempotent re-register kept exact clock (elapsed 7, steps 1)' (([string]$rrEval.elapsed_s + '/' + [string]$rrEval.steps))
    $rrLast = $null
    for ($i = 0; $i -lt 3; $i++) {
        $rrLast = Add-OrchestrationWatchdogAction -TaskId 'wd-rereg-1' -AttemptN 1 -SessionId 'wd-sess-61' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(8 + $i)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Watchdog (([string]$rrLast.classification -ceq 'STALL_SUSPECTED') -and ([int]$rrLast.steps -eq 4)) 'pre-register history intact: 1 old + 3 new => STALL_SUSPECTED steps 4' (([string]$rrLast.classification + '/' + [string]$rrLast.steps))
    # 28b. REVIEW discriminative: TWO identical no-progress actions before
    #     re-register + ONE after => STALL_SUSPECTED steps 3. An
    #     implementation that wiped history on re-register would see a
    #     trailing run of 1 => NONE and fail this assert.
    [void](Register-OrchestrationWatchdogExecution -TaskId 'wd-rereg-2' -AttemptN 1 -SessionId 'wd-sess-62' -Role 'coder' -Budget $bId -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-rereg-2' -AttemptN 1 -SessionId 'wd-sess-62' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-rereg-2' -AttemptN 1 -SessionId 'wd-sess-62' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(1)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot)
    $rrRe2 = Register-OrchestrationWatchdogExecution -TaskId 'wd-rereg-2' -AttemptN 1 -SessionId 'wd-sess-62' -Role 'coder' -Budget $bId -StartedAtUtc ($t0.AddSeconds(999)) -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog (([bool]$rrRe2.ok) -and ([bool]$rrRe2.idempotent)) 'discriminative re-register same identity idempotent' ''
    $rrDisc = Add-OrchestrationWatchdogAction -TaskId 'wd-rereg-2' -AttemptN 1 -SessionId 'wd-sess-62' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t0.AddSeconds(2)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Watchdog (([string]$rrDisc.classification -ceq 'STALL_SUSPECTED') -and ([int]$rrDisc.steps -eq 3)) 'history survived re-register: 2 old + 1 new => STALL_SUSPECTED steps 3' (([string]$rrDisc.classification + '/' + [string]$rrDisc.steps))

    # 29. REVIEW SK-/Sk- case-insensitive canary convergence, no leak
    $k1 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo SK-SYNTHETICSECRET-9' -Target 'repo' -ResultClass ''
    $k2 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo sk-SYNTHETICSECRET-9' -Target 'repo' -ResultClass ''
    $k3 = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo Sk-SyntheticSecret-9' -Target 'repo' -ResultClass ''
    $kR = Get-WatchdogActionFingerprint -Tool 'shell' -Arguments 'echo <redacted>' -Target 'repo' -ResultClass ''
    Assert-Watchdog (((($k1 -ceq $k2) -and ($k2 -ceq $k3)) -and ($k3 -ceq $kR)) -and ($k1 -cmatch '^[0-9a-f]{64}$')) 'SK-/Sk-/sk- canary variants converge to redacted form' ($k1)
    Assert-Watchdog (($k1 -notmatch 'SYNTHETICSECRET') -and ($k1 -notmatch 'SYNTH')) 'upper/mixed canary values never leak' ''

    Write-Host ''
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
finally {
    try { Clear-OrchestrationWatchdogState } catch { }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
