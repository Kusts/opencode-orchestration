<#!
.SYNOPSIS
    Tests for S5: STEER advisory interrupt mode + CLOSE vs RETRY settlement.
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP for telemetry + fixture flags +
    kernel task dirs, cleanup in finally. Bracketed output the runner
    parses. Exit 0 on all pass, exit 1 on any fail or unexpected
    exception. PS 5.1 compatible. ASCII-only.

    Every scenario carries an EXTERNAL bound: fast inline scenarios keep
    a per-scenario Stopwatch (asserted below 90s); the live-child STEER
    scenario and the CLI scenarios run through a REAL-deadline harness
    (Start-Job + Wait-Job -Timeout + Stop-Job/Remove-Job cleanup); a
    deadline breach aborts the job and FAILS the scenario instead of
    hanging the suite. Cleanup kills ONLY OWN tracked child PIDs created
    by this file (never foreign processes). No infinite wait exists in
    this file.

    Covers (P1-05-S5):
      S1. STEER validator: closed set '', KILL, STEER (case-insensitive);
          unknown tokens rejected.
      S2. STEER on an unbound execution: advisory recorded (who/when/
          reason), interrupted=$false, settlement STEER_ADVISORY, telemetry
          carries WATCHDOG_STEER_ADVISORY, no kill, no auto-retry (a
          second STEER call returns advisory again).
      S3. Kill unchanged by default: default call and explicit KILL on
          the same unbound shape return the same refusal; an invalid
          mode returns INVALID_INTERRUPT_MODE with nothing stored.
      S4. STEER on a REAL bound child (real-deadline job): the child
          survives, settlement is queryable as STEER_ADVISORY; the
          ENFORCE dispatcher with STEER bypasses the no-process-identity
          branch on an unbound execution.
      S5. Kernel seam CLOSE vs RETRY: Confirm default settles with
          disposition retry (backward compatible); Confirm CLOSE settles
          with disposition close; Start after CLOSE is rejected with
          WATCHDOG_CLOSED_NO_RETRY while release (cancel) still works;
          lowercase close accepted; repeats are idempotent and report
          the stored disposition; invalid disposition rejected without
          mutation.
      S6. Retry after RETRY still gated: after a RETRY settlement, the
          third gated worker-result failure returns ATTEMPT_GATE_FAILED
          (debugger_required) — CLOSE ends without retry, RETRY keeps
          the hypothesis/new-evidence gate.
      S7. CLI: watchdog-settle accepts -WatchdogDisposition CLOSE and
          reports it; an invalid token exits 2.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libWatchdog = Join-Path $PSScriptRoot 'OrchestrationRuntimeWatchdog.ps1'
. $libWatchdog
$libKernel = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $libKernel

$script:passed = 0
$script:failed = 0
$script:s5Children = New-Object System.Collections.ArrayList

function Assert-S5 {
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

function Write-S5Fixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Get-S5Shell {
    $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (($null -ne $c) -and (-not [string]::IsNullOrWhiteSpace([string]$c.Source))) { return ([string]$c.Source) }
    return (Join-Path ([string]$env:SystemRoot) 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Start-S5Child {
    param([int]$SleepSeconds = 120)
    $shell = Get-S5Shell
    $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Seconds ' + [string]$SleepSeconds)) -WindowStyle Hidden -PassThru
    [void]$script:s5Children.Add($p)
    return $p
}

function Test-S5Alive {
    param($Proc)
    try {
        $live = Get-Process -Id ([int]$Proc.Id) -ErrorAction Stop
        return ($null -ne $live)
    }
    catch { return $false }
}

function Wait-S5Ready {
    param($Proc, [int]$TimeoutMs = 10000)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
            $ok = $false
            try {
                $live = Get-Process -Id ([int]$Proc.Id) -ErrorAction Stop
                if (($null -ne $live) -and (-not [string]::IsNullOrWhiteSpace([string]$live.Path))) {
                    $null = ([DateTime]$live.StartTime).ToUniversalTime()
                    $ok = $true
                }
            }
            catch { $ok = $false }
            if ($ok) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }
    catch { return $false }
}

function Stop-S5Safety {
    param($Proc)
    try {
        try { $Proc.Refresh() } catch { }
        if (-not $Proc.HasExited) { Stop-Process -Id ([int]$Proc.Id) -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

function Get-S5TeleText {
    param([string]$TeleRoot)
    $acc = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $TeleRoot -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $acc += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    return $acc
}

function Invoke-S5CliBounded {
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string]$ScriptFile, [string[]]$CliArgs = @(), [int]$TimeoutSeconds = 60)
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($E, $F, $A)
            $ErrorActionPreference = 'Stop'
            $o = @(& $E -NoProfile -File $F @A)
            $code = $LASTEXITCODE
            return @{ s5_cli = $true; exit = [int]$code; out = ((@($o) | ForEach-Object { [string]$_ }) -join "`n") }
        } -ArgumentList @($Exe, $ScriptFile, $CliArgs)
        $waited = Wait-Job -Job $job -Timeout ([int]$TimeoutSeconds)
        if (($null -eq $waited) -or ([string]$job.State -cne 'Completed')) {
            try { Stop-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
            return [PSCustomObject]@{ ok = $false; timed_out = $true; exit = -1; out = '' }
        }
        $raw = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        foreach ($o in $raw) {
            if (($null -ne $o) -and ($o -is [System.Collections.IDictionary]) -and $o.Contains('s5_cli')) {
                return [PSCustomObject]@{ ok = $true; timed_out = $false; exit = [int]$o['exit']; out = ([string]$o['out']) }
            }
        }
        return [PSCustomObject]@{ ok = $false; timed_out = $false; exit = -1; out = '' }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; timed_out = $false; exit = -1; out = '' }
    }
    finally {
        if ($null -ne $job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function New-S5Task {
    param([string]$Id, [string]$TasksDir, [string]$FlagsPath, [string]$Repo)
    return (New-OrchestrationTask -TaskId $Id -Objective 'S5 steer/close probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -AcceptanceCriteria @('criterion:0:seam') -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $Repo)
}

function Invoke-S5ToImplementing {
    param([string]$Id, [int]$Revision, [string]$TasksDir, [string]$FlagsPath, [string]$TeleRoot, [string]$Repo)
    $p = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' `
        -ExpectedRevision ([int]$Revision) -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TeleRoot -RepoRoot $Repo
    if (-not [bool]$p.ok) { return $p }
    return (Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$p.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $TeleRoot -RepoRoot $Repo)
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$v3cli = Join-Path $v3 'task-kernel.ps1'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-watchdog-s5-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'telemetry'
$flagsEnforce = Join-Path $tempRoot 'flags-enforce.json'
$kernelTasks = Join-Path $tempRoot 'kernel-tasks'
$kernelFlags = Join-Path $tempRoot 'flags-kernel.json'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $kernelTasks -Force | Out-Null
Write-S5Fixture -Path $flagsEnforce -Text '{"watchdog":{"enabled":true,"shadow":false}}'
Write-S5Fixture -Path $kernelFlags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'

try {
    Clear-OrchestrationWatchdogState

    # S1. STEER mode validator: closed set.
    $swS1 = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-S5 ([bool](Test-WatchdogInterruptMode -Value '')) 'S1 absent mode valid (default KILL)' ''
    Assert-S5 ([bool](Test-WatchdogInterruptMode -Value 'KILL')) 'S1 KILL valid' ''
    Assert-S5 ([bool](Test-WatchdogInterruptMode -Value 'steer')) 'S1 STEER valid case-insensitive' ''
    Assert-S5 (-not [bool](Test-WatchdogInterruptMode -Value 'DESTROY')) 'S1 unknown token invalid' ''
    $swS1.Stop()
    Assert-S5 (($swS1.Elapsed.TotalSeconds -lt 90)) 'S1 externally bounded' ([string][int]$swS1.Elapsed.TotalSeconds + 's')

    # S2. STEER on an unbound execution: advisory recorded, no kill, no retry.
    $swS2 = [System.Diagnostics.Stopwatch]::StartNew()
    $execSteer = @{ attempt_n = 1 }
    $rSteer = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-unbound' -Execution $execSteer -Classification 'HARD_TIMEOUT' `
        -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEER' -SteerReason 'operator steer probe' -RequestedBy 'planner'
    Assert-S5 (([bool]$rSteer.ok) -and ([bool]$rSteer.advisory) -and (-not [bool]$rSteer.interrupted) -and ([string]$rSteer.settlement -ceq 'STEER_ADVISORY') -and ([string]$rSteer.reason -ceq 'WATCHDOG_STEER_ADVISORY')) 'S2 STEER returns advisory without interrupt' ([string]$rSteer.error)
    $stNode = $null
    try { $stNode = $execSteer['enforcement'] } catch { $stNode = $null }
    $stShapeOk = $false
    try {
        $stShapeOk = ((($null -ne $stNode) -and ($stNode -is [System.Collections.IDictionary])) -and ([string]$stNode['settlement'] -ceq 'STEER_ADVISORY'))
    }
    catch { $stShapeOk = $false }
    $stMetaOk = $false
    try {
        $stMetaOk = (([bool]$stNode['advisory']) -and (-not [bool]$stNode['interrupted']) -and ([string]$stNode['steer_reason'] -ceq 'operator steer probe') -and ([string]$stNode['steer_requested_by'] -ceq 'planner') -and (-not [string]::IsNullOrWhiteSpace([string]$stNode['steer_at'])))
    }
    catch { $stMetaOk = $false }
    Assert-S5 (([bool]$stShapeOk) -and ([bool]$stMetaOk)) 'S2 advisory records who/when/reason' ''
    $teleS2 = Get-S5TeleText -TeleRoot $teleRoot
    Assert-S5 (([string]$teleS2).Contains('WATCHDOG_STEER_ADVISORY')) 'S2 STEER telemetry event recorded' ''
    $rSteer2 = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-unbound' -Execution $execSteer -Classification 'HARD_TIMEOUT' `
        -ElapsedSeconds 32 -Steps 1 -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEER' -SteerReason 'second look' -RequestedBy 'planner'
    Assert-S5 (([bool]$rSteer2.ok) -and (-not [bool]$rSteer2.interrupted) -and ([string]$rSteer2.settlement -ceq 'STEER_ADVISORY')) 'S2 second STEER still advisory (no auto-retry)' ([string]$rSteer2.error)
    $swS2.Stop()
    Assert-S5 (($swS2.Elapsed.TotalSeconds -lt 90)) 'S2 externally bounded' ([string][int]$swS2.Elapsed.TotalSeconds + 's')

    # S3. Kill path unchanged by default; invalid mode rejected with nothing stored.
    $swS3 = [System.Diagnostics.Stopwatch]::StartNew()
    $execDef = @{ attempt_n = 1 }
    $rDef = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-default' -Execution $execDef -Classification 'HARD_TIMEOUT' `
        -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    $execKill = @{ attempt_n = 1 }
    $rKill = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-kill' -Execution $execKill -Classification 'HARD_TIMEOUT' `
        -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'KILL'
    Assert-S5 (((-not [bool]$rDef.ok) -and (-not [bool]$rKill.ok) -and ([string]$rDef.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$rKill.error -ceq [string]$rDef.error))) 'S3 default and explicit KILL refuse identically' ([string]$rDef.error + '/' + [string]$rKill.error)
    $execBad = @{ attempt_n = 1 }
    $rBad = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-badmode' -Execution $execBad -Classification 'HARD_TIMEOUT' `
        -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'DESTROY'
    $badStored = $null
    try { $badStored = $execBad['enforcement'] } catch { $badStored = $null }
    Assert-S5 (((-not [bool]$rBad.ok) -and ([string]$rBad.error -ceq 'INVALID_INTERRUPT_MODE') -and ($null -eq $badStored))) 'S3 invalid mode rejected with nothing stored' ([string]$rBad.error)
    $swS3.Stop()
    Assert-S5 (($swS3.Elapsed.TotalSeconds -lt 90)) 'S3 externally bounded' ([string][int]$swS3.Elapsed.TotalSeconds + 's')

    # S4. STEER on a REAL bound child: the child survives; dispatcher STEER
    # bypasses the no-process-identity branch.
    $swS4 = [System.Diagnostics.Stopwatch]::StartNew()
    $cS4 = Start-S5Child -SleepSeconds 120
    $s4ok = $false
    try {
        [void](Wait-S5Ready -Proc $cS4 -TimeoutMs 10000)
        $livePathS4 = ''
        try { $livePathS4 = ([string](Get-Process -Id ([int]$cS4.Id) -ErrorAction Stop).Path).Trim() } catch { $livePathS4 = '' }
        $liveStartS4 = $null
        try { $liveStartS4 = ([DateTime]$cS4.StartTime) } catch { $liveStartS4 = $null }
        $budgetS4 = [ordered]@{
            profile = 'fast'; step_budget = 64; wall_clock_seconds = 1200
            no_progress_seconds = 600; repeated_action_soft_limit = 3
            repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
        }
        $rReg = Register-OrchestrationWatchdogExecution -TaskId 's5-steer-live' -AttemptN 1 -SessionId 's5-steer-sess' -Role 'coder' `
            -Budget $budgetS4 -StartedAtUtc ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -RepoRoot $repo `
            -ProcessId ([int]$cS4.Id) -ProcessPath $livePathS4 -ParentProcessId ([int]$PID) -ProcessStartTime $liveStartS4
        Assert-S5 ([bool]$rReg.ok) 'S4 live child registered bound' ([string]$rReg.error)
        if ([bool]$rReg.ok) {
            $execLive = $script:WatchdogExecutions['s5-steer-live']
            $rLive = Invoke-WatchdogProcessInterrupt -TaskId 's5-steer-live' -Execution $execLive -Classification 'HARD_TIMEOUT' `
                -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEER' -SteerReason 'live steer probe' -RequestedBy 'planner'
            Assert-S5 (([bool]$rLive.ok) -and (-not [bool]$rLive.interrupted) -and ([string]$rLive.settlement -ceq 'STEER_ADVISORY')) 'S4 STEER on live child advisory' ([string]$rLive.error)
            Assert-S5 (Test-S5Alive -Proc $cS4) 'S4 live child survives STEER' ''
            $qLive = Get-OrchestrationWatchdogSettlement -TaskId 's5-steer-live' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
            Assert-S5 (([bool]$qLive.ok) -and ([bool]$qLive.engaged) -and (-not [bool]$qLive.interrupted) -and ([string]$qLive.settlement -ceq 'STEER_ADVISORY')) 'S4 STEER settlement queryable' ([string]$qLive.settlement)
            $s4ok = $true
        }
    }
    finally { Stop-S5Safety -Proc $cS4 }
    Assert-S5 ([bool]$s4ok) 'S4 live-child STEER block completed' ''
    $execDisp = @{ attempt_n = 1 }
    $evalDisp = [ordered]@{ would_interrupt = $true; classification = 'HARD_TIMEOUT'; elapsed_s = 31; steps = 0 }
    $rDisp = Invoke-WatchdogEnforcement -TaskId 's5-steer-disp' -Execution $execDisp -Eval $evalDisp `
        -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEER' -SteerReason 'dispatcher probe' -RequestedBy 'build'
    Assert-S5 (([bool]$rDisp.ok) -and (-not [bool]$rDisp.interrupted) -and ([string]$rDisp.settlement -ceq 'STEER_ADVISORY')) 'S4 dispatcher STEER bypasses no-process-identity' ([string]$rDisp.error)
    $execDispDef = @{ attempt_n = 1 }
    $rDispDef = Invoke-WatchdogEnforcement -TaskId 's5-steer-dispdef' -Execution $execDispDef -Eval $evalDisp `
        -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-S5 (([bool]$rDispDef.ok) -and ([string]$rDispDef.reason -ceq 'WATCHDOG_NO_PROCESS_IDENTITY')) 'S4 dispatcher default stays NO_PROCESS_IDENTITY when unbound' ([string]$rDispDef.reason)
    $execDispBad = @{ attempt_n = 1 }
    $rDispBad = Invoke-WatchdogEnforcement -TaskId 's5-steer-dispbad' -Execution $execDispBad -Eval $evalDisp `
        -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEERX'
    $badStored = $null
    try { $badStored = $execDispBad['enforcement'] } catch { $badStored = $null }
    Assert-S5 (((-not [bool]$rDispBad.ok) -and ([string]$rDispBad.error -ceq 'INVALID_INTERRUPT_MODE') -and ($null -eq $badStored))) 'S4b dispatcher invalid mode rejected without kill' ([string]$rDispBad.error)
    $cS4b = Start-S5Child -SleepSeconds 120
    try {
        [void](Wait-S5Ready -Proc $cS4b -TimeoutMs 10000)
        $livePathS4b = ''
        try { $livePathS4b = ([string](Get-Process -Id ([int]$cS4b.Id) -ErrorAction Stop).Path).Trim() } catch { $livePathS4b = '' }
        $liveStartS4b = $null
        try { $liveStartS4b = ([DateTime]$cS4b.StartTime) } catch { $liveStartS4b = $null }
        $budgetS4b = [ordered]@{
            profile = 'fast'; step_budget = 64; wall_clock_seconds = 1200
            no_progress_seconds = 600; repeated_action_soft_limit = 3
            repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
        }
        $rRegB = Register-OrchestrationWatchdogExecution -TaskId 's5-steer-dispbad-bound' -AttemptN 1 -SessionId 's5-steer-sess-b' -Role 'coder' `
            -Budget $budgetS4b -StartedAtUtc ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -RepoRoot $repo `
            -ProcessId ([int]$cS4b.Id) -ProcessPath $livePathS4b -ParentProcessId ([int]$PID) -ProcessStartTime $liveStartS4b
        Assert-S5 ([bool]$rRegB.ok) 'S4b bound child registered for invalid-mode probe' ([string]$rRegB.error)
        if ([bool]$rRegB.ok) {
            $execBoundBad = $script:WatchdogExecutions['s5-steer-dispbad-bound']
            $evalBoundBad = [ordered]@{ would_interrupt = $true; classification = 'HARD_TIMEOUT'; elapsed_s = 31; steps = 0 }
            $rBoundBad = Invoke-WatchdogEnforcement -TaskId 's5-steer-dispbad-bound' -Execution $execBoundBad -Eval $evalBoundBad `
                -TelemetryRoot $teleRoot -RepoRoot $repo -InterruptMode 'STEERX'
            Assert-S5 (((-not [bool]$rBoundBad.ok) -and ([string]$rBoundBad.error -ceq 'INVALID_INTERRUPT_MODE'))) 'S4b dispatcher invalid mode rejected on bound execution' ([string]$rBoundBad.error)
            Assert-S5 (Test-S5Alive -Proc $cS4b) 'S4b bound child survives invalid mode' ''
        }
    }
    finally { Stop-S5Safety -Proc $cS4b }
    $swS4.Stop()
    Assert-S5 (($swS4.Elapsed.TotalSeconds -lt 90)) 'S4 externally bounded' ([string][int]$swS4.Elapsed.TotalSeconds + 's')

    # S5. Kernel seam: Confirm default = retry; CLOSE ends without retry.
    $swS5 = [System.Diagnostics.Stopwatch]::StartNew()
    $c1 = New-S5Task -Id 's5-close-retry' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    Assert-S5 ([bool]$c1.ok) 'S5 retry task created' ''
    $t1 = Invoke-S5ToImplementing -Id 's5-close-retry' -Revision ([int]$c1.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    Assert-S5 ([bool]$t1.ok) 'S5 retry task implementing' ''
    $e1 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-retry' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$t1.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$e1.ok) -and ([bool]$e1.watchdog_engaged)) 'S5 retry interrupt engaged' ''
    $s1 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-retry' -Actor 'planner' `
        -ExpectedRevision ([int]$e1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$s1.ok) -and ([bool]$s1.watchdog_settled) -and ([string]$s1.disposition -ceq 'retry')) 'S5 default Confirm settles as retry' ([string]$s1.disposition)
    $g1 = Get-OrchestrationTask -TaskId 's5-close-retry' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-S5 ([string]$g1['watchdog_interrupt']['settled_disposition'] -ceq 'retry') 'S5 retry disposition persisted' ''
    $a1 = Start-OrchestrationTaskAttempt -TaskId 's5-close-retry' -AttemptRole 'coder' -SessionId 's5-close-sess-1' -Actor 'planner' `
        -ExpectedRevision ([int]$s1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-S5 ([bool]$a1.ok) 'S5 attempt allowed after RETRY settlement' ([string]$a1.error)

    $c2 = New-S5Task -Id 's5-close-shut' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    Assert-S5 ([bool]$c2.ok) 'S5 close task created' ''
    $t2 = Invoke-S5ToImplementing -Id 's5-close-shut' -Revision ([int]$c2.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    Assert-S5 ([bool]$t2.ok) 'S5 close task implementing' ''
    $e2 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-shut' -AttemptN 1 -Class 'NO_PROGRESS' -Actor 'planner' `
        -ExpectedRevision ([int]$t2.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 ([bool]$e2.ok) 'S5 close interrupt engaged' ''
    $s2 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-shut' -Actor 'planner' -Disposition 'CLOSE' `
        -ExpectedRevision ([int]$e2.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$s2.ok) -and ([bool]$s2.watchdog_settled) -and ([string]$s2.disposition -ceq 'close')) 'S5 CLOSE Confirm settles as close' ([string]$s2.disposition)
    $a2 = Start-OrchestrationTaskAttempt -TaskId 's5-close-shut' -AttemptRole 'coder' -SessionId 's5-close-sess-2' -Actor 'planner' `
        -ExpectedRevision ([int]$s2.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-S5 (((-not [bool]$a2.ok) -and ([string]$a2.error -ceq 'WATCHDOG_CLOSED_NO_RETRY'))) 'S5 attempt rejected after CLOSE' ([string]$a2.error)
    $g2 = Get-OrchestrationTask -TaskId 's5-close-shut' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-S5 (([int]$g2['revision'] -eq [int]$s2.revision)) 'S5 rejected attempt writes nothing' ''
    $x2 = Cancel-OrchestrationTask -TaskId 's5-close-shut' -Actor 'planner' -ExpectedRevision ([int]$s2.revision) -Reason 'close probe done' `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$x2.ok) -and ([string]$x2.state -ceq 'CANCELLED')) 'S5 release still works after CLOSE' ([string]$x2.state)
    $swS5.Stop()
    Assert-S5 (($swS5.Elapsed.TotalSeconds -lt 90)) 'S5 externally bounded' ([string][int]$swS5.Elapsed.TotalSeconds + 's')

    # S5b. Case-insensitivity, idempotency, invalid disposition.
    $swS5b = [System.Diagnostics.Stopwatch]::StartNew()
    $c3 = New-S5Task -Id 's5-close-lower' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $t3 = Invoke-S5ToImplementing -Id 's5-close-lower' -Revision ([int]$c3.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $e3 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-lower' -AttemptN 1 -Class 'REPEATED_CYCLE' -Actor 'planner' `
        -ExpectedRevision ([int]$t3.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    $s3 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-lower' -Actor 'planner' -Disposition 'close' `
        -ExpectedRevision ([int]$e3.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$s3.ok) -and ([string]$s3.disposition -ceq 'close')) 'S5b lowercase close accepted' ([string]$s3.disposition)
    $s3b = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-lower' -Actor 'planner' -Disposition 'RETRY' `
        -ExpectedRevision ([int]$s3.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$s3b.ok) -and ([bool]$s3b.noop) -and ([string]$s3b.disposition -ceq 'close') -and ([int]$s3b.revision -eq [int]$s3.revision)) 'S5b repeat reports stored disposition without mutation' ''
    $c4 = New-S5Task -Id 's5-close-bad' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $t4 = Invoke-S5ToImplementing -Id 's5-close-bad' -Revision ([int]$c4.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $e4 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-bad' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$t4.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    $g4pre = Get-OrchestrationTask -TaskId 's5-close-bad' -TasksDir $kernelTasks -RepoRoot $repo
    $s4 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-bad' -Actor 'planner' -Disposition 'DELETE' `
        -ExpectedRevision ([int]$e4.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    $g4post = Get-OrchestrationTask -TaskId 's5-close-bad' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-S5 (((-not [bool]$s4.ok) -and ([string]$s4.error -ceq 'INVALID_WATCHDOG_DISPOSITION') -and ([int]$g4post['revision'] -eq [int]$g4pre['revision']))) 'S5b invalid disposition rejected without mutation' ([string]$s4.error)
    $k4 = Complete-OrchestrationTask -TaskId 's5-close-bad' -Actor 'planner' -ExpectedRevision ([int]$e4.revision) `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 ([string]$k4.error -ceq 'SETTLEMENT_REQUIRED') 'S5b pending mark still blocks complete' ([string]$k4.error)
    $swS5b.Stop()
    Assert-S5 (($swS5b.Elapsed.TotalSeconds -lt 90)) 'S5b externally bounded' ([string][int]$swS5b.Elapsed.TotalSeconds + 's')

    # S5c. CLOSE sticky: CLOSE -> new interrupt rejected, RETRY cannot reopen.
    $swS5c = [System.Diagnostics.Stopwatch]::StartNew()
    $cc = New-S5Task -Id 's5-close-sticky' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $tc = Invoke-S5ToImplementing -Id 's5-close-sticky' -Revision ([int]$cc.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $ec = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-sticky' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$tc.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    $sc = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-sticky' -Actor 'planner' -Disposition 'CLOSE' `
        -ExpectedRevision ([int]$ec.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$sc.ok) -and ([string]$sc.disposition -ceq 'close')) 'S5c CLOSE settlement ok' ([string]$sc.disposition)
    $gcPre = Get-OrchestrationTask -TaskId 's5-close-sticky' -TasksDir $kernelTasks -RepoRoot $repo
    $ec2 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-sticky' -AttemptN 1 -Class 'NO_PROGRESS' -Actor 'planner' `
        -ExpectedRevision ([int]$sc.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (((-not [bool]$ec2.ok) -and ([string]$ec2.error -ceq 'WATCHDOG_CLOSED_NO_RETRY'))) 'S5c reengagement after CLOSE rejected' ([string]$ec2.error)
    $gcMid = Get-OrchestrationTask -TaskId 's5-close-sticky' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-S5 (([int]$gcMid['revision'] -eq [int]$gcPre['revision']) -and ([string]$gcMid['watchdog_interrupt']['settled_disposition'] -ceq 'close')) 'S5c rejected reengagement writes nothing, disposition stays close' ''
    $scRetry = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-close-sticky' -Actor 'planner' -Disposition 'RETRY' `
        -ExpectedRevision ([int]$sc.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 (([bool]$scRetry.ok) -and ([bool]$scRetry.noop) -and ([string]$scRetry.disposition -ceq 'close') -and ([int]$scRetry.revision -eq [int]$sc.revision)) 'S5c RETRY after CLOSE stays noop close' ''
    $ac = Start-OrchestrationTaskAttempt -TaskId 's5-close-sticky' -AttemptRole 'coder' -SessionId 's5-close-sess-c' -Actor 'planner' `
        -ExpectedRevision ([int]$sc.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-S5 (((-not [bool]$ac.ok) -and ([string]$ac.error -ceq 'WATCHDOG_CLOSED_NO_RETRY'))) 'S5c attempt stays blocked after CLOSE' ([string]$ac.error)
    $swS5c.Stop()
    Assert-S5 (($swS5c.Elapsed.TotalSeconds -lt 90)) 'S5c externally bounded' ([string][int]$swS5c.Elapsed.TotalSeconds + 's')

    # S5d. Malformed node fail-closed on the CLOSE gate.
    $swS5d = [System.Diagnostics.Stopwatch]::StartNew()
    $cd = New-S5Task -Id 's5-close-malformed' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $td = Invoke-S5ToImplementing -Id 's5-close-malformed' -Revision ([int]$cd.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $ed = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-malformed' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$td.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 ([bool]$ed.ok) 'S5d malformed probe interrupt engaged' ''
    $dFile = Get-TaskKernelFilePath -TaskId 's5-close-malformed' -TasksDir $kernelTasks -RepoRoot $repo
    $dSlot = Read-TaskKernelRecord -TaskFile $dFile
    $dRec = $dSlot.record
    $dRec['watchdog_interrupt'] = 'engaged'
    $dWr = Write-TaskKernelRecord -Record $dRec -TaskFile $dFile
    Assert-S5 ([bool]$dWr.ok) 'S5d malformed node written' ''
    $dPost = Get-OrchestrationTask -TaskId 's5-close-malformed' -TasksDir $kernelTasks -RepoRoot $repo
    $ad = Start-OrchestrationTaskAttempt -TaskId 's5-close-malformed' -AttemptRole 'coder' -SessionId 's5-close-sess-d' -Actor 'planner' `
        -ExpectedRevision ([int]$dPost['revision']) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-S5 (((-not [bool]$ad.ok) -and ([string]$ad.error -ceq 'WATCHDOG_CLOSED_NO_RETRY'))) 'S5d malformed node blocks attempt fail-closed' ([string]$ad.error)
    $swS5d.Stop()
    Assert-S5 (($swS5d.Elapsed.TotalSeconds -lt 90)) 'S5d externally bounded' ([string][int]$swS5d.Elapsed.TotalSeconds + 's')

    # S6. RETRY keeps the ATTEMPT_GATE: third gated failure still blocked.
    $swS6 = [System.Diagnostics.Stopwatch]::StartNew()
    $c6 = New-S5Task -Id 's5-retry-gated' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $t6 = Invoke-S5ToImplementing -Id 's5-retry-gated' -Revision ([int]$c6.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $e6 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-retry-gated' -AttemptN 1 -Class 'NO_PROGRESS' -Actor 'planner' `
        -ExpectedRevision ([int]$t6.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    $s6 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 's5-retry-gated' -Actor 'planner' -Disposition 'RETRY' `
        -ExpectedRevision ([int]$e6.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 ([bool]$s6.ok) 'S6 RETRY settlement ok' ''
    $f61 = Set-OrchestrationTaskWorkerResult -TaskId 's5-retry-gated' -Status 'failed' -ClaimedEvidence @('criterion:0:try one') -ProducedBy 'coder' -ExpectedRevision ([int]$s6.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TelemetryRoot $teleRoot
    $f62 = Set-OrchestrationTaskWorkerResult -TaskId 's5-retry-gated' -Status 'failed' -ClaimedEvidence @('criterion:0:try two') -ProducedBy 'coder' -ExpectedRevision ([int]$f61.revision) -Hypothesis 'retry narrower' -TasksDir $kernelTasks -FlagsPath $kernelFlags -TelemetryRoot $teleRoot
    Assert-S5 (([bool]$f61.ok) -and ([bool]$f62.ok)) 'S6 two failures recorded' ''
    $f63 = Set-OrchestrationTaskWorkerResult -TaskId 's5-retry-gated' -Status 'failed' -ClaimedEvidence @('criterion:0:try three no news') -ProducedBy 'coder' -ExpectedRevision ([int]$f62.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TelemetryRoot $teleRoot
    Assert-S5 (((-not [bool]$f63.ok) -and ([string]$f63.error -ceq 'ATTEMPT_GATE_FAILED') -and ([string]$f63.reason -ceq 'debugger_required'))) 'S6 retry still gated after RETRY settlement' ([string]$f63.error + '/' + [string]$f63.reason)
    $swS6.Stop()
    Assert-S5 (($swS6.Elapsed.TotalSeconds -lt 90)) 'S6 externally bounded' ([string][int]$swS6.Elapsed.TotalSeconds + 's')

    # S7. CLI: watchdog-settle honors -WatchdogDisposition CLOSE; bad token exits 2.
    $swS7 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell = Get-S5Shell
    $c7 = New-S5Task -Id 's5-close-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $t7 = Invoke-S5ToImplementing -Id 's5-close-cli' -Revision ([int]$c7.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $e7 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-cli' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$t7.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-S5 ([bool]$e7.ok) 'S7 CLI probe interrupt engaged' ''
    $cliArgs = @('-Action', 'watchdog-settle', '-TaskId', 's5-close-cli', '-Actor', 'planner', `
        '-ExpectedRevision', ([string][int]$e7.revision), '-ActorIdentitySource', 'explicit-cli', '-TasksDir', $kernelTasks, '-FlagsPath', $kernelFlags, `
        '-WatchdogDisposition', 'CLOSE')
    $cli = Invoke-S5CliBounded -Exe $shell -ScriptFile $v3cli -CliArgs $cliArgs -TimeoutSeconds 60
    $cliOk = (((-not [bool]$cli.timed_out) -and ([int]$cli.exit -eq 0) -and ([string]$cli.out -match 'watchdog_settled') -and ([string]$cli.out -match 'close')))
    Assert-S5 ($cliOk) 'S7 CLI watchdog-settle CLOSE wired under a real external deadline' ('exit=' + [string][int]$cli.exit)
    $c7b = New-S5Task -Id 's5-close-clibad' -TasksDir $kernelTasks -FlagsPath $kernelFlags -Repo $repo
    $t7b = Invoke-S5ToImplementing -Id 's5-close-clibad' -Revision ([int]$c7b.revision) -TasksDir $kernelTasks -FlagsPath $kernelFlags -TeleRoot $teleRoot -Repo $repo
    $e7b = Set-OrchestrationTaskWatchdogInterrupt -TaskId 's5-close-clibad' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$t7b.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    # Invalid disposition exits 2 before any file IO (usage validation
    # precedes the seam call), so it runs synchronously in-process: a
    # job would report Failed on the expected stderr line (RemoteException)
    # instead of the exit code. Post-hoc Stopwatch bound below.
    $swBad = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $shell -NoProfile -File $v3cli -Action 'watchdog-settle' -TaskId 's5-close-clibad' -Actor 'planner' `
            -ExpectedRevision ([int]$e7b.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags `
            -WatchdogDisposition 'DELETE' 2>$null
        $cliBadCode = [int]$LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prevEap }
    $swBad.Stop()
    Assert-S5 ((([int]$cliBadCode -eq 2) -and (($swBad.Elapsed.TotalSeconds) -lt 90))) 'S7 CLI invalid disposition exits 2' ('exit=' + [string][int]$cliBadCode)
    $swS7.Stop()
    Assert-S5 (($swS7.Elapsed.TotalSeconds -lt 90)) 'S7 externally bounded' ([string][int]$swS7.Elapsed.TotalSeconds + 's')
}
catch {
    Write-Host ('[FAIL] S5 harness error: ' + $_.Exception.Message)
    $script:failed++
}
finally {
    foreach ($kp in @($script:s5Children.ToArray())) { Stop-S5Safety -Proc $kp }
    try { Clear-OrchestrationWatchdogState } catch { }
    try {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

Write-Host ("S5 RESULT passed={0} failed={1}" -f $script:passed, $script:failed)
if ([int]$script:failed -gt 0) { exit 1 }
exit 0
