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
    Telemetry follow-ups (cross-process write coordination + bounded
    multi-day retention): deterministic gate name per telemetry
    directory, a real OWN child process holding the mutex (write skips
    lock-busy in bounded time, nothing written, recovers afterwards), a
    child killed mid-hold (write applies the policy without hanging,
    recovers afterwards, and the abandonment SIGNAL is asserted at the
    gate where Windows still delivers it), retention deleting ONLY
    matching files strictly older than the injected-Now horizon, caps
    honored, non-matching files untouched, per-file delete error
    non-fatal, the sweep wired into the successful write without
    damaging it, plus the FIX reviews: canonical directory identity (one
    mutex per directory spelling), bounded incremental sweep under a
    flooded directory, no sweep through a reparse point, and JSONL
    framing preserved after a truncated tail, plus the FIX reviews:
    canonical directory identity (one mutex per directory spelling,
    absolute AND relative), one resolution per operation (writer, gate
    and sweep share the pinned directory even when the process working
    directory moves in between), bounded incremental sweep with the budget
    spent before any filtering (including names outside the pattern and
    subdirectories, cap 0 = no enumeration, conservative truncation with
    no probe), observable retention starvation (no_progress), no sweep
    through a reparse point, and JSONL framing preserved after a
    truncated tail.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationRuntimeWatchdog.ps1'
. $libPath

$script:passed = 0
$script:failed = 0
$script:wdChildren = New-Object System.Collections.ArrayList

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

# ---------- cross-process gate helpers (OWN ephemeral children only) ----------

function Get-WatchdogTestShell {
    # Current host executable (so each engine spawns its own flavor),
    # with the standard powershell.exe fallback chain. Never throws.
    try {
        $fn = ''
        try { $fn = [string]([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { $fn = '' }
        if ((-not [string]::IsNullOrWhiteSpace($fn)) -and (Test-Path -LiteralPath $fn -PathType Leaf)) { return $fn }
    }
    catch { }
    $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (($null -ne $c) -and (-not [string]::IsNullOrWhiteSpace([string]$c.Source))) { return ([string]$c.Source) }
    return (Join-Path ([string]$env:SystemRoot) 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-WatchdogMutexHolderScript {
    # Standalone holder: acquires the named mutex, signals readiness,
    # then holds it for -HoldMs. Writes only the ready file; never
    # touches the repository.
    $lines = @(
        'param(',
        '    [Parameter(Mandatory = $true)][string]$MutexName,',
        '    [Parameter(Mandatory = $true)][string]$ReadyFile,',
        '    [int]$HoldMs = 2500',
        ')',
        '$ErrorActionPreference = ''Stop''',
        '$m = [System.Threading.Mutex]::new($false, $MutexName)',
        '$ok = $false',
        'try { $ok = [bool]$m.WaitOne(30000) } catch { $ok = $false }',
        'try { [IO.File]::WriteAllText($ReadyFile, (''held='' + [string]$ok)) } catch { }',
        'if ($HoldMs -gt 0) { Start-Sleep -Milliseconds ([int]$HoldMs) }',
        'if ($ok) { try { $m.ReleaseMutex() } catch { } }',
        'try { $m.Dispose() } catch { }',
        'exit 0'
    )
    return ($lines -join "`n")
}

function Start-WatchdogMutexHolder {
    param([string]$MutexName, [string]$ReadyFile, [int]$HoldMs = 2500)
    $shell = Get-WatchdogTestShell
    $holder = Join-Path $tempRoot ('mutex-holder-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Write-WatchdogFixture -Path $holder -Text (Get-WatchdogMutexHolderScript)
    $proc = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $holder + '"'), '-MutexName', ('"' + $MutexName + '"'), '-ReadyFile', ('"' + $ReadyFile + '"'), '-HoldMs', ([string]$HoldMs)) -WindowStyle Hidden -PassThru
    [void]$script:wdChildren.Add($proc)
    return $proc
}

function Wait-WatchdogFileReady {
    param([string]$Path, [int]$TimeoutMs = 20000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Stop-WatchdogOwnChild {
    param($Proc)
    try {
        if ($null -ne $Proc) {
            try { $Proc.Refresh() } catch { }
            if (-not [bool]$Proc.HasExited) { Stop-Process -Id ([int]$Proc.Id) -Force -ErrorAction SilentlyContinue }
            try { [void]$Proc.WaitForExit(10000) } catch { }
        }
    }
    catch { }
}

function Write-WatchdogJsonlFixture {
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$Name)
    $p = Join-Path $Dir $Name
    [IO.File]::WriteAllText($p, ('{' + '"ts":"2026-01-01T00:00:00.0000000Z"' + '}' + "`n"), [Text.UTF8Encoding]::new($false))
    return $p
}

function Get-WatchdogDirNames {
    param([string]$Dir)
    $names = @()
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) { $names += ([string]$f.Name) }
    }
    catch { }
    return $names
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
    $teleDisabled = Join-Path $tempRoot 'telemetry-disabled'
    $dReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-disabled-1' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -FlagsPath $flagsDisabled -RepoRoot $repo
    Assert-Watchdog (([string]$dReg.error -ceq 'WATCHDOG_DISABLED') -and (-not [bool]$dReg.ok)) 'disabled register returns WATCHDOG_DISABLED' ([string]$dReg.error)
    $dAdd = Add-OrchestrationWatchdogAction -TaskId 'wd-disabled-1' -Tool 'shell' -FlagsPath $flagsDisabled -RepoRoot $repo -TelemetryRoot $teleDisabled
    Assert-Watchdog ([string]$dAdd.error -ceq 'WATCHDOG_DISABLED') 'disabled observe returns WATCHDOG_DISABLED' ([string]$dAdd.error)
    $dEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-disabled-1' -FlagsPath $flagsDisabled -RepoRoot $repo -TelemetryRoot $teleDisabled
    Assert-Watchdog ([string]$dEval.error -ceq 'WATCHDOG_DISABLED') 'disabled evaluate returns WATCHDOG_DISABLED' ([string]$dEval.error)

    # 6. enforcement seam: honest not-implemented, nothing stored
    $teleEnforceGate = Join-Path $tempRoot 'telemetry-enforce-gate'
    $eReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-enforce-1' -AttemptN 1 -SessionId 'wd-sess-1' -Role 'coder' -FlagsPath $flagsEnforce -RepoRoot $repo
    Assert-Watchdog ([string]$eReg.error -ceq 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') 'enabled=true returns ENFORCEMENT_NOT_IMPLEMENTED' ([string]$eReg.error)
    $eLookup = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enforce-1' -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleEnforceGate
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
    $teleStall = Join-Path $tempRoot 'telemetry-stall'
    $bShort = New-WatchdogTinyBudget -Steps 4 -Wall 30 -NoProg 10
    $sReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-stall-1' -AttemptN 1 -SessionId 'wd-sess-2' -Role 'coder' -Budget $bShort -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$sReg.ok) 'synthetic stall register ok' ''
    $sEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-stall-1' -AtUtc ($t0.AddSeconds(31)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleStall
    Assert-Watchdog (([string]$sEval.classification -ceq 'HARD_TIMEOUT') -and ([bool]$sEval.would_interrupt)) 'no-return past wall => HARD_TIMEOUT would-interrupt' ([string]$sEval.classification)
    $sStill = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-stall-1' -AtUtc ($t0.AddSeconds(32)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleStall
    Assert-Watchdog (([bool]$sStill.ok) -and ([int]$sStill.steps -eq 0)) 'shadow interrupted nothing: execution intact, steps 0' ([string]$sStill.steps)
    $probeTaskFile = Join-Path $repoTasksDir 'wd-stall-1.json'
    Assert-Watchdog (-not (Test-Path -LiteralPath $probeTaskFile)) 'shadow wrote no task record' ($probeTaskFile)

    # 10. long but progressing worker does not hit NO_PROGRESS
    $teleProg = Join-Path $tempRoot 'telemetry-progress'
    $bProg = New-WatchdogTinyBudget -Steps 64 -Wall 3600 -NoProg 60
    $pReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-progress-1' -AttemptN 1 -SessionId 'wd-sess-3' -Role 'explorer' -Budget $bProg -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$pReg.ok) 'progressing register ok' ''
    $pLast = $null
    for ($i = 0; $i -lt 6; $i++) {
        $pLast = Add-OrchestrationWatchdogAction -TaskId 'wd-progress-1' -AttemptN 1 -SessionId 'wd-sess-3' -Tool 'shell' -Arguments ('git diff HEAD~' + $i) -Target 'repo' -HasProgress $true -AtUtc ($t0.AddSeconds(50 + $i * 50)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    $pEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-progress-1' -AtUtc ($t0.AddSeconds(340)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleProg
    Assert-Watchdog (([string]$pEval.classification -ceq 'NONE') -and (-not [bool]$pEval.would_interrupt)) 'steady progress over 5min never stalls' ([string]$pEval.classification)

    # 11. genuine no-progress past threshold => NO_PROGRESS suspected + would-interrupt recorded
    $teleNoProgThresh = Join-Path $tempRoot 'telemetry-noprog-threshold'
    $bNp = New-WatchdogTinyBudget -Steps 32 -Wall 1200 -NoProg 20
    $nReg = Register-OrchestrationWatchdogExecution -TaskId 'wd-noprog-1' -AttemptN 1 -SessionId 'wd-sess-4' -Role 'coder' -Budget $bNp -StartedAtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Watchdog ([bool]$nReg.ok) 'no-progress fixture register ok' ''
    [void](Add-OrchestrationWatchdogAction -TaskId 'wd-noprog-1' -AttemptN 1 -SessionId 'wd-sess-4' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc $t0 -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleNoProgThresh)
    $nEval = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-noprog-1' -AtUtc ($t0.AddSeconds(21)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleNoProgThresh
    Assert-Watchdog (([string]$nEval.classification -ceq 'NO_PROGRESS') -and ([bool]$nEval.would_interrupt)) 'silence past no_progress => NO_PROGRESS would-interrupt' ([string]$nEval.classification)

    # 12. identical repetition soft (3x) then hard (5x) in the correct window
    $teleRepeat = Join-Path $tempRoot 'telemetry-repeat'
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
    $rStill = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-repeat-1' -AtUtc ($t0.AddSeconds(6)) -FlagsPath $flagsShadow -RepoRoot $repo -TelemetryRoot $teleRepeat
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

    # 30. FOLLOW-UP cross-process gate: the mutex name is deterministic
    #     from the telemetry directory (closed charset, no path chars),
    #     so every process that resolves the same directory coordinates
    #     on the SAME kernel object.
    $teleGate = Join-Path $tempRoot 'telemetry-gate'
    New-Item -ItemType Directory -Path $teleGate -Force | Out-Null
    $gateName = Get-WatchdogTelemetryMutexName -TelemetryRoot $teleGate -RepoRoot $repo
    $gateNameSame = Get-WatchdogTelemetryMutexName -Directory ((Join-Path $teleGate '.'))
    $gateNameOther = Get-WatchdogTelemetryMutexName -TelemetryRoot $teleSilent -RepoRoot $repo
    Assert-Watchdog ([string]$gateName -cmatch '^Global\\OrchWatchdogTel-[0-9a-f]{16}$') 'gate name is a deterministic closed-charset global mutex name' ([string]$gateName)
    Assert-Watchdog (([string]$gateName -ceq [string]$gateNameSame) -and ([string]$gateName -cne [string]$gateNameOther)) 'gate name stable per directory, distinct per directory' (([string]$gateName + ' vs ' + [string]$gateNameOther))

    # 31. HIGH cross-process contention: an OWN ephemeral child process
    #     holds the mutex for ~2.5s; the write must SKIP with an honest
    #     reason in bounded time (never block on the holder, never
    #     throw, never leave a partial line), and must succeed again once
    #     the holder is gone.
    $teleLock = Join-Path $tempRoot 'telemetry-lock'
    New-Item -ItemType Directory -Path $teleLock -Force | Out-Null
    $lockName = Get-WatchdogTelemetryMutexName -TelemetryRoot $teleLock -RepoRoot $repo
    $lockReady = Join-Path $tempRoot 'mutex-holder-ready.txt'
    $lockChild = Start-WatchdogMutexHolder -MutexName $lockName -ReadyFile $lockReady -HoldMs 2500
    $lockHeld = Wait-WatchdogFileReady -Path $lockReady -TimeoutMs 20000
    $swLock = [System.Diagnostics.Stopwatch]::StartNew()
    $wLock = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-lock-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleLock -RepoRoot $repo
    $swLock.Stop()
    Assert-Watchdog ([bool]$lockHeld) 'contention fixture: child acquired the telemetry mutex' ''
    Assert-Watchdog (((-not [bool]$wLock.ok)) -and ([string]$wLock.skipped -ceq 'lock-busy')) 'real cross-process contention skips the write with lock-busy' ([string]$wLock.skipped)
    Assert-Watchdog ($swLock.ElapsedMilliseconds -lt 2000) 'contention skip is bounded (did not wait out the holder)' (([string]$swLock.ElapsedMilliseconds + 'ms for a 2500ms holder'))
    Assert-Watchdog (-not (Test-Path -LiteralPath (Get-WatchdogTelemetryFile -TelemetryRoot $teleLock -RepoRoot $repo) -PathType Leaf)) 'skipped write created no file, no partial line' ''
    Stop-WatchdogOwnChild -Proc $lockChild
    $wAfterLock = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-lock-2' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleLock -RepoRoot $repo
    $lockFile = Get-WatchdogTelemetryFile -TelemetryRoot $teleLock -RepoRoot $repo
    $lockLines = @()
    try { $lockLines = @([IO.File]::ReadAllLines($lockFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { }
    Assert-Watchdog (([bool]$wAfterLock.ok) -and (@($lockLines).Count -eq 1)) 'write succeeds again after contention, exactly one complete line' (([string]$wAfterLock.skipped + '/' + [string](@($lockLines).Count)))

    # 32. HIGH abandoned mutex: a child acquires the mutex and dies
    #     WITHOUT releasing it. The next write must not hang and must
    #     apply the fail-safe policy (skip with the structured
    #     mutex-abandoned reason, since a writer that died mid-append
    #     may have left a truncated line), then succeed afterwards.
    $teleAband = Join-Path $tempRoot 'telemetry-abandon'
    New-Item -ItemType Directory -Path $teleAband -Force | Out-Null
    $abandName = Get-WatchdogTelemetryMutexName -TelemetryRoot $teleAband -RepoRoot $repo
    $abandReady = Join-Path $tempRoot 'mutex-abandon-ready.txt'
    $abandChild = Start-WatchdogMutexHolder -MutexName $abandName -ReadyFile $abandReady -HoldMs 60000
    $abandHeld = Wait-WatchdogFileReady -Path $abandReady -TimeoutMs 20000
    Stop-WatchdogOwnChild -Proc $abandChild
    Assert-Watchdog ([bool]$abandHeld) 'abandon fixture: OWN child acquired the telemetry mutex and died holding it' ''
    $swAb = [System.Diagnostics.Stopwatch]::StartNew()
    $wAb = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-aband-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleAband -RepoRoot $repo
    $swAb.Stop()
    $abSkip = [string]$wAb.skipped
    Assert-Watchdog ($swAb.ElapsedMilliseconds -lt 2000) 'abandoned mutex never hangs the caller' (([string]$swAb.ElapsedMilliseconds + 'ms'))
    Assert-Watchdog (((-not [bool]$wAb.ok)) -or ([string]$abSkip -ceq '')) 'abandoned mutex applies a policy: skip with a reason, or a clean write when no signal arrives' ($abSkip)
    $abFile = Get-WatchdogTelemetryFile -TelemetryRoot $teleAband -RepoRoot $repo
    $abLines = @()
    $abBad = 0
    try {
        $abLines = @([IO.File]::ReadAllLines($abFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($abLine in @($abLines)) { try { [void]($abLine | ConvertFrom-Json) } catch { $abBad++ } }
    }
    catch { $abBad = 1 }
    Assert-Watchdog (([bool]$wAb.ok) -and (@($abLines).Count -eq 1) -and ($abBad -eq 0)) 'after a real abandonment the file holds exactly one complete parseable line' (($abSkip + '/' + [string](@($abLines).Count) + '/' + [string]$abBad))
    $wAfterAb = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-aband-2' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleAband -RepoRoot $repo
    Assert-Watchdog ([bool]$wAfterAb.ok) 'write recovers after an abandoned mutex (gate not leaked)' ([string]$wAfterAb.skipped)
    # Signal leg at the gate: Windows only delivers
    # AbandonedMutexException while the mutex OBJECT survives, i.e. while
    # some other handle is open. That observer handle is a test fixture
    # for the signal itself (never needed for the policy above); the gate
    # must release the ownership the exception grants and skip, and the
    # next acquire must succeed - otherwise the abandoned name would
    # wedge every later event.
    $abandKeep = $null
    try {
        $abandKeep = [System.Threading.Mutex]::new($false, $abandName)
        $abandReady2 = Join-Path $tempRoot 'mutex-abandon-ready2.txt'
        $abandChild2 = Start-WatchdogMutexHolder -MutexName $abandName -ReadyFile $abandReady2 -HoldMs 60000
        [void](Wait-WatchdogFileReady -Path $abandReady2 -TimeoutMs 20000)
        Stop-WatchdogOwnChild -Proc $abandChild2
        $sigGate = Enter-WatchdogTelemetryWriteGate -TelemetryRoot $teleAband -RepoRoot $repo
        Assert-Watchdog (((-not [bool]$sigGate.ok)) -and ([string]$sigGate.skipped -ceq 'mutex-abandoned')) 'abandonment signal: gate skips with mutex-abandoned (fail-safe)' ([string]$sigGate.skipped)
        $sigGate2 = Enter-WatchdogTelemetryWriteGate -TelemetryRoot $teleAband -RepoRoot $repo
        $sig2ok = [bool]$sigGate2.ok
        $sig2skip = [string]$sigGate2.skipped
        Exit-WatchdogTelemetryWriteGate -Mutex $sigGate2.mutex -Owned ([bool]$sigGate2.owned)
        Assert-Watchdog ([bool]$sig2ok) 'gate not wedged after an abandonment (next acquire succeeds, ownership released)' ([string]$sig2skip)
    }
    finally { try { if ($null -ne $abandKeep) { $abandKeep.Dispose() } } catch { } }

    # 33. FOLLOW-UP retention horizon/caps are documented defaults in the lib
    Assert-Watchdog (([int]$script:WatchdogTelemetryRetentionDays -eq 7) -and ([int]$script:WatchdogRetentionMaxExamined -eq 64) -and ([int]$script:WatchdogRetentionMaxDeleted -eq 32)) 'retention defaults documented: 7-day horizon, 64 examined, 32 deleted' (([string]$script:WatchdogTelemetryRetentionDays + '/' + [string]$script:WatchdogRetentionMaxExamined + '/' + [string]$script:WatchdogRetentionMaxDeleted))

    # 34. HIGH retention deletes ONLY matching watchdog files strictly
    #     older than the horizon; every non-matching file in the same
    #     directory is left untouched. Now is injected (deterministic).
    $retNow = [DateTime]::new(2026, 3, 20, 12, 0, 0, [DateTimeKind]::Utc)
    $teleRet = Join-Path $tempRoot 'telemetry-retention'
    New-Item -ItemType Directory -Path $teleRet -Force | Out-Null
    $retOld = Write-WatchdogJsonlFixture -Dir $teleRet -Name 'watchdog-20260312.jsonl'
    $retEdge = Write-WatchdogJsonlFixture -Dir $teleRet -Name 'watchdog-20260313.jsonl'
    $retToday = Write-WatchdogJsonlFixture -Dir $teleRet -Name 'watchdog-20260320.jsonl'
    foreach ($rn in @('mcp-safety-20260312.jsonl', 'watchdog.jsonl', 'watchdog-2026.jsonl', 'watchdog-2026031.jsonl', 'watchdog-20261332.jsonl', 'watchdog-20260312.jsonl.bak', 'notes-20260312.txt')) {
        [void](Write-WatchdogJsonlFixture -Dir $teleRet -Name $rn)
    }
    # 'examined' counts every file system ENTRY visited (no glob), so the
    # other producers' files and the malformed names cost budget too
    # (10 entries here).
    $retRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleRet -RepoRoot $repo -AtUtc $retNow
    Assert-Watchdog (([bool]$retRes.ok) -and ([int]$retRes.deleted -eq 1) -and ([int]$retRes.retained -eq 2) -and ([int]$retRes.failed -eq 0) -and ([int]$retRes.examined -eq 10) -and (-not [bool]$retRes.truncated) -and (-not [bool]$retRes.no_progress)) 'retention: only the strictly-older matching file deleted (examined 10 entries, deleted 1, retained 2)' (([string]$retRes.examined + '/' + [string]$retRes.deleted + '/' + [string]$retRes.retained + '/' + [string]$retRes.failed))
    Assert-Watchdog (-not (Test-Path -LiteralPath $retOld -PathType Leaf)) 'retention: file older than the 7-day horizon removed' ($retOld)
    Assert-Watchdog ((Test-Path -LiteralPath $retEdge -PathType Leaf) -and (Test-Path -LiteralPath $retToday -PathType Leaf)) 'retention: horizon edge (exactly 7 days) and today kept' ''
    $retNames = @(Get-WatchdogDirNames -Dir $teleRet)
    $intact = $true
    foreach ($keepName in @('watchdog-20260313.jsonl', 'watchdog-20260320.jsonl', 'mcp-safety-20260312.jsonl', 'watchdog.jsonl', 'watchdog-2026.jsonl', 'watchdog-2026031.jsonl', 'watchdog-20261332.jsonl', 'watchdog-20260312.jsonl.bak', 'notes-20260312.txt')) {
        if ($retNames -cnotcontains $keepName) { $intact = $false }
    }
    Assert-Watchdog ($intact) 'retention: non-matching files untouched (other producers, bad stamps, other extensions)' (($retNames -join ','))
    Assert-Watchdog ([int]$retRes.retention_days -eq 7) 'retention reports the documented 7-day horizon' ([string]$retRes.retention_days)
    $retAgain = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleRet -RepoRoot $repo -AtUtc $retNow
    Assert-Watchdog (([int]$retAgain.deleted -eq 0) -and ([int]$retAgain.examined -eq 9) -and (-not [bool]$retAgain.truncated)) 'retention is idempotent and deterministic under the same injected Now' (([string]$retAgain.examined + '/' + [string]$retAgain.deleted))
    $teleRetSoon = Join-Path $tempRoot 'telemetry-retention-soon'
    New-Item -ItemType Directory -Path $teleRetSoon -Force | Out-Null
    [void](Write-WatchdogJsonlFixture -Dir $teleRetSoon -Name 'watchdog-20260312.jsonl')
    $retSoon = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleRetSoon -RepoRoot $repo -AtUtc ($retNow.AddDays(-7))
    Assert-Watchdog (([int]$retSoon.deleted -eq 0) -and (@(Get-WatchdogDirNames -Dir $teleRetSoon) -contains 'watchdog-20260312.jsonl')) 'retention honors the injected clock (a week earlier deletes nothing)' ([string]$retSoon.deleted)

    # 35. MEDIUM caps bound the per-call work (examined and deleted)
    $teleRetCap = Join-Path $tempRoot 'telemetry-retention-cap'
    New-Item -ItemType Directory -Path $teleRetCap -Force | Out-Null
    foreach ($cn in @('watchdog-20260301.jsonl', 'watchdog-20260302.jsonl', 'watchdog-20260303.jsonl', 'watchdog-20260304.jsonl', 'watchdog-20260305.jsonl')) { [void](Write-WatchdogJsonlFixture -Dir $teleRetCap -Name $cn) }
    $capRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleRetCap -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 2 -MaxFilesDeleted 1
    $capLeft = @(Get-WatchdogDirNames -Dir $teleRetCap)
    Assert-Watchdog (([int]$capRes.examined -eq 2) -and ([int]$capRes.deleted -eq 1) -and ([int]$capRes.retained -eq 1)) 'retention caps honored: examined 2, deleted 1' (([string]$capRes.examined + '/' + [string]$capRes.deleted + '/' + [string]$capRes.retained))
    Assert-Watchdog ((@($capLeft).Count -eq 4) -and ($capLeft -ccontains 'watchdog-20260305.jsonl') -and (-not ($capLeft -ccontains 'watchdog-20260301.jsonl'))) 'retention cap leaves the rest for the next bounded call' (($capLeft -join ','))

    # 36. MEDIUM a per-file delete failure keeps that file and does NOT
    #     stop the sweep (locked file injected for real, no seam).
    $teleRetLock = Join-Path $tempRoot 'telemetry-retention-locked'
    New-Item -ItemType Directory -Path $teleRetLock -Force | Out-Null
    foreach ($ln in @('watchdog-20260301.jsonl', 'watchdog-20260302.jsonl', 'watchdog-20260303.jsonl')) { [void](Write-WatchdogJsonlFixture -Dir $teleRetLock -Name $ln) }
    $lockedPath = Join-Path $teleRetLock 'watchdog-20260303.jsonl'
    $lockHandle = $null
    try {
        $lockHandle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $lockRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleRetLock -RepoRoot $repo -AtUtc $retNow
        Assert-Watchdog (([bool]$lockRes.ok) -and ([int]$lockRes.deleted -eq 2) -and ([int]$lockRes.failed -eq 1)) 'per-file delete error leaves that file and the sweep continues' (([string]$lockRes.deleted + '/' + [string]$lockRes.failed))
        Assert-Watchdog ((Test-Path -LiteralPath $lockedPath -PathType Leaf) -and (-not (Test-Path -LiteralPath (Join-Path $teleRetLock 'watchdog-20260301.jsonl') -PathType Leaf))) 'undeletable file kept, older siblings still removed' ''
    }
    finally { try { if ($null -ne $lockHandle) { $lockHandle.Dispose() } } catch { } }

    # 37. MEDIUM retention is wired into the write path and never damages
    #     the event just written (other producer's file untouched)
    $realNow = (Get-Date).ToUniversalTime()
    $teleRetWrite = Join-Path $tempRoot 'telemetry-retention-write'
    New-Item -ItemType Directory -Path $teleRetWrite -Force | Out-Null
    $staleStamp = ([DateTimeOffset]::new($realNow.AddDays(-9)).UtcDateTime.ToString('yyyyMMdd'))
    $stalePath = Write-WatchdogJsonlFixture -Dir $teleRetWrite -Name ('watchdog-' + $staleStamp + '.jsonl')
    $foreignStale = Write-WatchdogJsonlFixture -Dir $teleRetWrite -Name ('mcp-safety-' + $staleStamp + '.jsonl')
    $wRet = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-ret-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleRetWrite -RepoRoot $repo
    $writeRetFile = Get-WatchdogTelemetryFile -TelemetryRoot $teleRetWrite -RepoRoot $repo
    Assert-Watchdog (((-not (Test-Path -LiteralPath $stalePath -PathType Leaf)) -and (Test-Path -LiteralPath $foreignStale -PathType Leaf)) -and ([bool]$wRet.ok)) 'write path sweeps stale watchdog files only, other producers untouched' ([string]$wRet.skipped)
    $writeRetLines = @()
    try { $writeRetLines = @([IO.File]::ReadAllLines($writeRetFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { }
    Assert-Watchdog ((@($writeRetLines).Count -eq 1) -and ([string]$writeRetLines[0] -match 'STALL_SUSPECTED')) 'retention never damaged the event just written (one complete line)' (([string](@($writeRetLines).Count) + ' line(s)'))

    # 38. LOW retention on a directory that does not exist is honest and
    #     never throws (the write path calls it best-effort every time)
    $retMissing = Invoke-WatchdogTelemetryRetention -TelemetryRoot (Join-Path $tempRoot 'telemetry-absent') -RepoRoot $repo -AtUtc $retNow
    Assert-Watchdog (([bool]$retMissing.ok) -and ([string]$retMissing.reason -ceq 'no-directory') -and ([int]$retMissing.deleted -eq 0)) 'retention on a missing directory is a no-op, no throw' ([string]$retMissing.reason)

    # 39. HIGH F2 canonical identity: every common spelling of ONE
    #     directory must derive the SAME mutex, otherwise two producers
    #     would silently break the exclusivity of the rotation cap.
    $canonDir = Join-Path $tempRoot 'canon'
    New-Item -ItemType Directory -Path $canonDir -Force | Out-Null
    $canonNames = @(
        (Get-WatchdogTelemetryMutexName -Directory $canonDir),
        (Get-WatchdogTelemetryMutexName -Directory ($canonDir + '\')),
        (Get-WatchdogTelemetryMutexName -Directory ($canonDir.ToUpperInvariant())),
        (Get-WatchdogTelemetryMutexName -Directory ($canonDir + '\.')),
        (Get-WatchdogTelemetryMutexName -Directory (Join-Path $tempRoot 'canon-sibling\..\canon'))
    )
    $canonUnique = @($canonNames | Select-Object -Unique)
    Assert-Watchdog (@($canonUnique).Count -eq 1) 'F2: trailing sep, upper case, dot-suffix and internal dotdot all share ONE mutex name' (($canonUnique -join ','))
    $canonResolved = Get-WatchdogTelemetryDirectory -TelemetryRoot ($canonDir + '\.') -RepoRoot $repo
    Assert-Watchdog (([IO.Path]::IsPathRooted($canonResolved)) -and ([IO.Path]::GetFullPath($canonResolved) -ceq $canonResolved)) 'F2: the telemetry directory resolves to one rooted canonical path' ([string]$canonResolved)
    Assert-Watchdog (([string](Get-WatchdogTelemetryMutexName -Directory (Join-Path $tempRoot 'canon-sibling\..\canon'))) -ceq ([string](Get-WatchdogTelemetryMutexName -TelemetryRoot $canonDir -RepoRoot $repo))) 'F2: writer, gate and retention resolve the same canonical name for one directory' ''

    # 40. HIGH F3 bounded work per call: a directory flooded with entries
    #     must cost only the caps - no materialization, no unbounded
    #     validation or sorting - and truncation is reported.
    $hostileA = Join-Path $tempRoot 'telemetry-hostile-a'
    $hostileB = Join-Path $tempRoot 'telemetry-hostile-b'
    $hostileInv = Join-Path $tempRoot 'telemetry-hostile-invalid'
    foreach ($hd in @($hostileA, $hostileB, $hostileInv)) { New-Item -ItemType Directory -Path $hd -Force | Out-Null }
    foreach ($hd in @($hostileA, $hostileB)) {
        for ($i = 0; $i -lt 200; $i++) {
            $hdDay = ([DateTime]::new(2025, 12, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddDays($i)
            [void](Write-WatchdogJsonlFixture -Dir $hd -Name ('watchdog-' + $hdDay.ToString('yyyyMMdd') + '.jsonl'))
        }
    }
    for ($i = 0; $i -lt 50; $i++) { [void](Write-WatchdogJsonlFixture -Dir $hostileInv -Name ('watchdog-bad' + $i + '.jsonl')) }
    $hostileRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $hostileA -RepoRoot $repo -AtUtc $retNow
    Assert-Watchdog (([int]$hostileRes.examined -eq 64) -and ([int]$hostileRes.deleted -eq 32) -and ([int]$hostileRes.retained -eq 32) -and ([bool]$hostileRes.truncated)) 'F3: a 200-file directory costs only the caps (examined 64, deleted 32, truncated)' (([string]$hostileRes.examined + '/' + [string]$hostileRes.deleted + '/' + [string]$hostileRes.retained + '/' + [string]$hostileRes.truncated))
    Assert-Watchdog ((@(Get-WatchdogDirNames -Dir $hostileA)).Count -eq 168) 'F3: exactly the capped deletions happened (200 - 32), the rest is left for later calls' ([string](@(Get-WatchdogDirNames -Dir $hostileA)).Count)
    $hostileRes2 = Invoke-WatchdogTelemetryRetention -TelemetryRoot $hostileB -RepoRoot $repo -AtUtc $retNow
    Assert-Watchdog (([int]$hostileRes2.examined -eq [int]$hostileRes.examined) -and ([int]$hostileRes2.deleted -eq [int]$hostileRes.deleted) -and ([bool]$hostileRes2.truncated -eq [bool]$hostileRes.truncated)) 'F3: bounded and deterministic for two identical flooded directories' (([string]$hostileRes2.examined + '/' + [string]$hostileRes2.deleted + '/' + [string]$hostileRes2.truncated))
    $hostileZero = Invoke-WatchdogTelemetryRetention -TelemetryRoot $hostileB -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 0
    Assert-Watchdog (([int]$hostileZero.examined -eq 0) -and ([int]$hostileZero.deleted -eq 0) -and ([string]$hostileZero.reason -ceq 'cap-zero') -and ((@(Get-WatchdogDirNames -Dir $hostileB)).Count -eq 168)) 'F3/FIX5: examined cap 0 examines and deletes nothing at all (cap-zero)' (([string]$hostileZero.examined + '/' + [string]$hostileZero.deleted + '/' + [string]$hostileZero.reason))
    $invRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $hostileInv -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 5
    Assert-Watchdog (([int]$invRes.examined -eq 5) -and ([int]$invRes.deleted -eq 0) -and ([bool]$invRes.truncated)) 'F3: invalid names spend the examined budget (scanning them is never free)' (([string]$invRes.examined + '/' + [string]$invRes.deleted + '/' + [string]$invRes.truncated))

    # 41. HIGH F4 the sweep never traverses a reparse point: a junction
    #     used AS the telemetry directory is refused fail-safe, so no
    #     canary outside the physical directory can be deleted. Explicitly
    #     SKIPPED (never faked) where the environment forbids it.
    $junctionTarget = Join-Path $tempRoot 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionCanary = Write-WatchdogJsonlFixture -Dir $junctionTarget -Name 'watchdog-20250101.jsonl'
    $junctionLink = Join-Path $tempRoot 'junction-link'
    $junctionOk = $false
    $junctionErr = ''
    try { New-Item -ItemType Junction -Path $junctionLink -Target $junctionTarget -ErrorAction Stop | Out-Null; $junctionOk = $true }
    catch { $junctionErr = [string]$_.Exception.Message }
    if ($junctionOk) {
        try {
            $junctionRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $junctionLink -RepoRoot $repo -AtUtc $retNow
            Assert-Watchdog (([string]$junctionRes.reason -ceq 'reparse-detected') -and ([int]$junctionRes.deleted -eq 0) -and (Test-Path -LiteralPath $junctionCanary -PathType Leaf)) 'F4: junction telemetry dir => reparse-detected, nothing deleted, canary intact' ([string]$junctionRes.reason)
            $junctionDirect = Invoke-WatchdogTelemetryRetention -TelemetryRoot $junctionTarget -RepoRoot $repo -AtUtc $retNow
            Assert-Watchdog (([int]$junctionDirect.deleted -eq 1) -and (-not (Test-Path -LiteralPath $junctionCanary -PathType Leaf))) 'F4: the same canary in the REAL directory is swept (guard is specific, not a blanket refusal)' ([string]$junctionDirect.deleted)
        }
        finally { try { if (Test-Path -LiteralPath $junctionLink) { [IO.Directory]::Delete($junctionLink, $false) } } catch { } }
    }
    else { Write-Host ('[SKIP] F4 junction fixture unavailable in this environment (' + $junctionErr + ')') }

    # 42. HIGH F1 framing: a writer terminated mid-append leaves a tail
    #     fragment; the next event must be refused (structured reason),
    #     the fragment must be preserved as evidence and NOTHING may be
    #     concatenated onto it. With an intact tail the append goes
    #     through again.
    $teleTail = Join-Path $tempRoot 'telemetry-tail'
    New-Item -ItemType Directory -Path $teleTail -Force | Out-Null
    $wTail1 = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-tail-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $teleTail -RepoRoot $repo
    $tailFile = Get-WatchdogTelemetryFile -TelemetryRoot $teleTail -RepoRoot $repo
    $tailFragment = '{"ts":"2026-01-01T00:00:00.0000000Z","source":"watchdog-shadow","eve'
    [IO.File]::AppendAllText($tailFile, $tailFragment, [Text.UTF8Encoding]::new($false))
    $wTail2 = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-tail-2' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 2 -ElapsedSeconds 2 -TelemetryRoot $teleTail -RepoRoot $repo
    $tailText = ''
    try { $tailText = [IO.File]::ReadAllText($tailFile, [Text.Encoding]::UTF8) } catch { }
    Assert-Watchdog (([bool]$wTail1.ok) -and ((-not [bool]$wTail2.ok)) -and ([string]$wTail2.skipped -ceq 'tail-incomplete')) 'F1: appending onto a truncated tail is refused with tail-incomplete' ([string]$wTail2.skipped)
    $tailParts = @($tailText -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-Watchdog ((@($tailParts).Count -eq 2) -and ([string]$tailParts[1] -ceq $tailFragment)) 'F1: fragment preserved verbatim and never concatenated (one intact line + the fragment)' (([string](@($tailParts).Count) + ' part(s)'))
    [IO.File]::WriteAllText($tailFile, (([string]$tailParts[0]) + "`n"), [Text.UTF8Encoding]::new($false))
    $wTail3 = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-tail-3' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 3 -ElapsedSeconds 3 -TelemetryRoot $teleTail -RepoRoot $repo
    Assert-Watchdog ([bool]$wTail3.ok) 'F1: with an intact tail the append goes through again' ([string]$wTail3.skipped)
    $tailAllOk = $true
    try {
        foreach ($tl in @([IO.File]::ReadAllLines($tailFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            try { [void]($tl | ConvertFrom-Json) } catch { $tailAllOk = $false }
        }
    }
    catch { $tailAllOk = $false }
    Assert-Watchdog ($tailAllOk) 'F1: every line of the recovered file is a complete parseable event' ''

    # 43. HIGH FIX5 the budget is spent BEFORE any filtering: entries
    #     outside the watchdog pattern and subdirectories cost budget too,
    #     are never deleted, and truncation comes from the counter alone
    #     (no probe - exactly `cap` entries is reported conservatively).
    $teleOutside = Join-Path $tempRoot 'telemetry-outside'
    New-Item -ItemType Directory -Path $teleOutside -Force | Out-Null
    for ($i = 0; $i -lt 100; $i++) { [IO.File]::WriteAllText((Join-Path $teleOutside ('hostis-' + $i + '.txt')), 'x') }
    for ($i = 0; $i -lt 20; $i++) { [IO.File]::WriteAllText((Join-Path $teleOutside ('notas-' + $i + '.jsonl')), 'x') }
    for ($i = 0; $i -lt 5; $i++) { New-Item -ItemType Directory -Path (Join-Path $teleOutside ('subdir-' + $i)) -Force | Out-Null }
    $telemetryLookalikeDir = Join-Path $teleOutside 'watchdog-20250101.jsonl'
    New-Item -ItemType Directory -Path $telemetryLookalikeDir -Force | Out-Null
    $outsideRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleOutside -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 8 -MaxFilesDeleted 8
    Assert-Watchdog (([int]$outsideRes.examined -eq 8) -and ([int]$outsideRes.deleted -eq 0) -and ([bool]$outsideRes.truncated)) 'FIX5: names outside the pattern still spend the budget (examined == cap, truncated, nothing deleted)' (([string]$outsideRes.examined + '/' + [string]$outsideRes.deleted + '/' + [string]$outsideRes.truncated))
    $outsideFiles = @(Get-WatchdogDirNames -Dir $teleOutside)
    $outsideDirs = @(Get-ChildItem -LiteralPath $teleOutside -Directory -ErrorAction SilentlyContinue)
    Assert-Watchdog ((@($outsideFiles).Count -eq 120) -and (Test-Path -LiteralPath $telemetryLookalikeDir -PathType Container) -and (@($outsideDirs).Count -eq 6)) 'FIX5: no entry outside the pattern and no subdirectory was deleted (120 files + 6 dirs intact)' (([string](@($outsideFiles).Count) + ' files, ' + [string](@($outsideDirs).Count) + ' dirs'))
    $teleExact = Join-Path $tempRoot 'telemetry-exact'
    New-Item -ItemType Directory -Path $teleExact -Force | Out-Null
    for ($i = 0; $i -lt 4; $i++) {
        $exDay = ([DateTime]::new(2025, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddDays($i)
        [void](Write-WatchdogJsonlFixture -Dir $teleExact -Name ('watchdog-' + $exDay.ToString('yyyyMMdd') + '.jsonl'))
    }
    $exactRes = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleExact -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 4 -MaxFilesDeleted 4
    Assert-Watchdog (([int]$exactRes.examined -eq 4) -and ([int]$exactRes.deleted -eq 4) -and ([bool]$exactRes.truncated) -and (-not [bool]$exactRes.no_progress)) 'FIX5: exactly cap entries => conservative truncated (no probe), every eligible one deleted' (([string]$exactRes.examined + '/' + [string]$exactRes.deleted + '/' + [string]$exactRes.truncated))
    $exactRes2 = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleExact -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 4 -MaxFilesDeleted 4
    Assert-Watchdog (([int]$exactRes2.examined -eq 0) -and (-not [bool]$exactRes2.truncated) -and (-not [bool]$exactRes2.no_progress)) 'FIX5: an exhausted directory is not flagged truncated (counter below the cap)' (([string]$exactRes2.examined + '/' + [string]$exactRes2.truncated))

    # 44. MEDIUM FIX6 starvation is OBSERVABLE: a non-deletable prefix
    #      eats the whole budget on every call and the result says so.
    #      Remove the prefix and the next call reaches the canary.
    $teleStarve = Join-Path $tempRoot 'telemetry-starve'
    New-Item -ItemType Directory -Path $teleStarve -Force | Out-Null
    for ($i = 0; $i -lt 100; $i++) { [IO.File]::WriteAllText((Join-Path $teleStarve ('aaa-prefix-' + $i + '.txt')), 'x') }
    $starveCanary = Write-WatchdogJsonlFixture -Dir $teleStarve -Name 'watchdog-20250101.jsonl'
    $starveRes1 = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleStarve -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 4 -MaxFilesDeleted 4
    Assert-Watchdog (([bool]$starveRes1.truncated) -and ([int]$starveRes1.deleted -eq 0) -and ([bool]$starveRes1.no_progress) -and ([string]$starveRes1.reason -ceq 'no-progress') -and (Test-Path -LiteralPath $starveCanary -PathType Leaf)) 'FIX6: starvation is signalled (truncated + nothing deleted + no_progress) with the canary intact' (([string]$starveRes1.truncated + '/' + [string]$starveRes1.deleted + '/' + [string]$starveRes1.no_progress + '/' + [string]$starveRes1.reason))
    foreach ($sp in @(Get-ChildItem -LiteralPath $teleStarve -Filter 'aaa-prefix-*.txt' -File -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $sp.FullName -Force -ErrorAction SilentlyContinue } catch { } }
    $starveRes2 = Invoke-WatchdogTelemetryRetention -TelemetryRoot $teleStarve -RepoRoot $repo -AtUtc $retNow -MaxFilesExamined 4 -MaxFilesDeleted 4
    Assert-Watchdog (([int]$starveRes2.deleted -eq 1) -and (-not (Test-Path -LiteralPath $starveCanary -PathType Leaf)) -and (-not [bool]$starveRes2.no_progress)) 'FIX6: with the prefix gone the next bounded call reaches and deletes the canary' (([string]$starveRes2.deleted + '/' + [string]$starveRes2.no_progress))

    # 45. HIGH FIX7 RELATIVE path: the same directory passed relative
    #      resolves to the same canonical directory, the same mutex and
    #      the same file as the absolute form, so writer, gate and
    #      retention really coordinate.
    $relDir = Join-Path $tempRoot 'telemetry-rel'
    New-Item -ItemType Directory -Path $relDir -Force | Out-Null
    $absMutex = Get-WatchdogTelemetryMutexName -TelemetryRoot $relDir -RepoRoot $repo
    $absResolved = Get-WatchdogTelemetryDirectory -TelemetryRoot $relDir -RepoRoot $repo
    $relMutex = ''
    $relResolved = ''
    $wAbsRel = $null
    $wRelAbs = $null
    $oldLoc = ''
    $oldCwd = ''
    try {
        # Canonicalization resolves a relative path against the PROCESS
        # working directory (the only stable base a library can rely on),
        # so the fixture moves it - and restores both afterwards.
        $oldLoc = [string](Get-Location).Path
        $oldCwd = [string][Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $tempRoot
        Set-Location -LiteralPath $tempRoot
        $relMutex = Get-WatchdogTelemetryMutexName -Directory '.\telemetry-rel'
        $relResolved = Get-WatchdogTelemetryDirectory -TelemetryRoot 'telemetry-rel' -RepoRoot $repo
        $wAbsRel = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-rel-abs' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot $relDir -RepoRoot $repo
        $wRelAbs = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-rel-rel' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 2 -ElapsedSeconds 2 -TelemetryRoot '.\telemetry-rel\' -RepoRoot $repo
    }
    finally {
        try { if (-not [string]::IsNullOrWhiteSpace($oldCwd)) { [Environment]::CurrentDirectory = $oldCwd } } catch { }
        try { if (-not [string]::IsNullOrWhiteSpace($oldLoc)) { Set-Location -LiteralPath $oldLoc } } catch { }
    }
    Assert-Watchdog (([string]$relMutex -ceq [string]$absMutex) -and ([string]$relResolved -ceq [string]$absResolved)) 'FIX7: a relative path resolves to the same canonical directory and the same mutex name' (([string]$relMutex + ' vs ' + [string]$absMutex))
    $relFile = Get-WatchdogTelemetryFile -TelemetryRoot $relDir -RepoRoot $repo
    $relLines = @()
    try { $relLines = @([IO.File]::ReadAllLines($relFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { }
    Assert-Watchdog (([bool]$wAbsRel.ok) -and ([bool]$wRelAbs.ok) -and (@($relLines).Count -eq 2)) 'FIX7: append via relative and via absolute land in ONE file under ONE gate' (([string]$wAbsRel.skipped + '/' + [string]$wRelAbs.skipped + '/' + [string](@($relLines).Count)))

    # 46. HIGH FIX8 single resolution per operation: the directory is
    #     canonicalized ONCE and pinned for target, gate and sweep. The
    #     process working directory is mutable, so re-resolving a
    #     relative root later in the same call could make the sweep
    #     delete old telemetry in a DIFFERENT directory than the one
    #     just written. Two destinations share the SAME relative name
    #     here, reachable only from different working directories.
    $teleFix8A = Join-Path $tempRoot 'fix8-telemetry'
    $teleFix8Other = Join-Path $tempRoot 'other'
    $teleFix8B = Join-Path $teleFix8Other 'fix8-telemetry'
    New-Item -ItemType Directory -Path $teleFix8A -Force | Out-Null
    New-Item -ItemType Directory -Path $teleFix8B -Force | Out-Null
    $fix8CanaryA = Write-WatchdogJsonlFixture -Dir $teleFix8A -Name 'watchdog-20250101.jsonl'
    $fix8CanaryB = Write-WatchdogJsonlFixture -Dir $teleFix8B -Name 'watchdog-20250101.jsonl'
    $fix8Pinned = ''
    $fix8Hazard = ''
    $fix8Sweep = $null
    $oldCwd8 = ''
    try {
        $oldCwd8 = [string][Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $tempRoot
        # pinned the way the writer pins it: one resolution, absolute
        $fix8Pinned = Get-WatchdogTelemetryDirectory -TelemetryRoot 'fix8-telemetry' -RepoRoot $repo
        # the hazard: the SAME relative input now resolves elsewhere
        [Environment]::CurrentDirectory = $teleFix8Other
        $fix8Hazard = Get-WatchdogTelemetryDirectory -TelemetryRoot 'fix8-telemetry' -RepoRoot $repo
        Assert-Watchdog (([string]$fix8Pinned -ceq (Resolve-Path -LiteralPath $teleFix8A).Path) -and ([string]$fix8Hazard -ceq (Resolve-Path -LiteralPath $teleFix8B).Path) -and ([string]$fix8Pinned -cne [string]$fix8Hazard)) 'FIX8: a relative root IS working-directory dependent, and the pinned value is the absolute first destination' (([string]$fix8Pinned + ' vs ' + [string]$fix8Hazard))
        # the internal call the writer makes: the sweep gets the PINNED
        # directory, even though the working directory now points at the
        # other destination
        $fix8Sweep = Invoke-WatchdogTelemetryRetention -Directory $fix8Pinned -AtUtc $retNow
        Assert-Watchdog (([int]$fix8Sweep.deleted -eq 1) -and (-not (Test-Path -LiteralPath $fix8CanaryA -PathType Leaf)) -and (Test-Path -LiteralPath $fix8CanaryB -PathType Leaf)) 'FIX8: sweep with the pinned directory deletes ONLY there (second destination canary intact)' (([string]$fix8Sweep.deleted + '/' + [string]$fix8Sweep.reason))
    }
    finally { try { if (-not [string]::IsNullOrWhiteSpace($oldCwd8)) { [Environment]::CurrentDirectory = $oldCwd8 } } catch { } }
    # a write whose relative root resolves to the OTHER destination must
    # stay entirely there: nothing appears in the first one
    $fix8W = $null
    $oldCwd8b = ''
    try {
        $oldCwd8b = [string][Environment]::CurrentDirectory
        [Environment]::CurrentDirectory = $teleFix8Other
        $fix8W = Write-WatchdogTelemetryEvent -EventName 'STALL_SUSPECTED' -TaskId 'wd-fix8-1' -AttemptN 1 -Class 'STALL_SUSPECTED' -WouldInterrupt $false -Steps 1 -ElapsedSeconds 1 -TelemetryRoot 'fix8-telemetry' -RepoRoot $repo
    }
    finally { try { if (-not [string]::IsNullOrWhiteSpace($oldCwd8b)) { [Environment]::CurrentDirectory = $oldCwd8b } } catch { } }
    $fix8FilesA = @(Get-WatchdogDirNames -Dir $teleFix8A)
    $fix8LinesB = @()
    try { $fix8LinesB = @([IO.File]::ReadAllLines((Get-WatchdogTelemetryFile -TelemetryRoot $teleFix8B -RepoRoot $repo), [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { }
    Assert-Watchdog (([bool]$fix8W.ok) -and (@($fix8FilesA).Count -eq 0) -and (@($fix8LinesB).Count -eq 1)) 'FIX8: the write and its sweep stay in the directory resolved by THAT call (first destination never touched)' (([string]$fix8W.skipped + '/' + [string](@($fix8FilesA).Count) + '/' + [string](@($fix8LinesB).Count)))

    Write-Host ''
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
finally {
    try { Clear-OrchestrationWatchdogState } catch { }
    # Only OWN ephemeral mutex-holder children are ever stopped here.
    try {
        foreach ($wc in @($script:wdChildren.ToArray())) {
            try { if (-not [bool]$wc.HasExited) { Stop-Process -Id ([int]$wc.Id) -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }
    catch { }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
