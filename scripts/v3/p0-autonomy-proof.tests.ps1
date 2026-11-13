<#
.SYNOPSIS
    Process-level tests for the P0 GoalKernel proof harness.
    PowerShell 5.1/7 compatible, ASCII-only, isolated to a temporary store.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:CliPath = Join-Path $PSScriptRoot 'p0-autonomy-proof.ps1'
$script:HostExe = ''
try { $script:HostExe = [string](Get-Process -Id $PID).Path } catch { }
if ([string]::IsNullOrWhiteSpace($script:HostExe)) {
    if ($PSVersionTable.PSEdition -eq 'Core') { $script:HostExe = Join-Path $PSHOME 'pwsh.exe' }
    else { $script:HostExe = Join-Path $PSHOME 'powershell.exe' }
}

function Assert-P0Proof {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else {
        Write-Host ('[FAIL] ' + $Name + $(if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' -- ' + $Detail }))
        $script:Failed++
    }
}

function Invoke-P0ProofCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $quoted = @()
    foreach ($arg in @($CliArgs)) { $quoted += ('"' + ([string]$arg).Replace('"', '\"') + '"') }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CliPath + '" ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($stdout)) { $json = ConvertFrom-Json -InputObject $stdout } } catch { }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout.Trim(); Stderr = $stderr.Trim(); Json = $json }
}

if (-not (Test-Path -LiteralPath $script:HostExe -PathType Leaf)) {
    Assert-P0Proof $false 'CLI host executable available' $script:HostExe
}
else {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('p0-autonomy-proof-' + [Guid]::NewGuid().ToString('N'))
    $store = Join-Path $root 'goals'
    $evidence = Join-Path $root 'task1-evidence.txt'
    try {
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::WriteAllText($evidence, 'synthetic verified artifact', [Text.Encoding]::ASCII)
        $initArgs = @('-Action', 'init', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-OwnerId', 'test-planner')
        $init1 = Invoke-P0ProofCli $initArgs
        Assert-P0Proof (($init1.ExitCode -eq 0) -and [bool]$init1.Json.ok -and ([string]$init1.Json.goal_id -ceq 'proof-test-001') -and ([string]$init1.Json.owner_id -ceq 'test-planner') -and ([long]$init1.Json.generation -ge 1) -and ((@($init1.Json.active_tasks) -join ',') -ceq 'T1,T2,T3')) 'init creates ACTIVE Goal with ownership and ordered T1-T3' ($init1.Stdout + ' ' + $init1.Stderr)
        $init2 = Invoke-P0ProofCli $initArgs
        Assert-P0Proof (($init2.ExitCode -eq 0) -and ([long]$init2.Json.revision -eq [long]$init1.Json.revision) -and ((@($init2.Json.active_tasks) -join ',') -ceq 'T1,T2,T3')) 'second init is idempotent' ($init2.Stdout + ' ' + $init2.Stderr)

        $resume0 = Invoke-P0ProofCli @('-Action', 'resume', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($resume0.ExitCode -eq 0) -and ([string]$resume0.Json.resume_source -ceq 'goal-store') -and ([string]$resume0.Json.state -ceq 'ACTIVE') -and ($null -ne $resume0.Json.next_move)) 'new process resumes persisted Goal and returns next_move' ($resume0.Stdout + ' ' + $resume0.Stderr)

        $earlyT2 = Invoke-P0ProofCli @('-Action', 'record-task', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-TaskId', 'T2', '-EvidencePath', $evidence)
        Assert-P0Proof (($earlyT2.ExitCode -eq 1) -and ($earlyT2.Stderr -match 'Out of order')) 'record-task rejects T2 before T1' $earlyT2.Stderr
        $t1 = Invoke-P0ProofCli @('-Action', 'record-task', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-TaskId', 'T1', '-EvidencePath', $evidence, '-Summary', 'artifact verified')
        Assert-P0Proof (($t1.ExitCode -eq 0) -and ((@($t1.Json.completed_tasks) -join ',') -ceq 'T1') -and ([long]$t1.Json.satisfied -eq 1)) 'T1 completion persists evidence and increments progress' ($t1.Stdout + ' ' + $t1.Stderr)
        $resume1 = Invoke-P0ProofCli @('-Action', 'resume', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($resume1.ExitCode -eq 0) -and ((@($resume1.Json.completed_tasks) -join ',') -ceq 'T1') -and ((@($resume1.Json.active_tasks) -join ',') -ceq 'T2,T3')) 'resume after T1 sees persisted task state' ($resume1.Stdout + ' ' + $resume1.Stderr)
        $t2Failure = Invoke-P0ProofCli @('-Action', 'record-failure', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-TaskId', 'T2', '-Reason', 'synthetic validation failure', '-Severity', 'high', '-Attempts', '1')
        $failureRecord = $null
        if ($t2Failure.Json -and @($t2Failure.Json.failed_strategies).Count -gt 0) { try { $failureRecord = ConvertFrom-Json -InputObject ([string]$t2Failure.Json.failed_strategies[-1]) } catch { } }
        Assert-P0Proof (($t2Failure.ExitCode -eq 0) -and (@($t2Failure.Json.completed_tasks) -cnotcontains 'T2') -and ([string]$failureRecord.task_id -ceq 'T2') -and ([string]$failureRecord.reason -ceq 'synthetic validation failure')) 'record-failure on T2 persists failure without completing task' ($t2Failure.Stdout + ' ' + $t2Failure.Stderr)

        $tooSoon = Invoke-P0ProofCli @('-Action', 'complete', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($tooSoon.ExitCode -eq 1) -and ($tooSoon.Stderr -match 'T1, T2, and T3')) 'complete refuses before all three tasks and criteria' $tooSoon.Stderr
        $t2 = Invoke-P0ProofCli @('-Action', 'record-task', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-TaskId', 'T2', '-EvidencePath', $evidence, '-Summary', 'failure replanned')
        Assert-P0Proof (($t2.ExitCode -eq 0) -and ([long]$t2.Json.satisfied -eq 2) -and ((@($t2.Json.completed_tasks) -join ',') -ceq 'T1,T2')) 'T2 completes after failure/replan and T1' ($t2.Stdout + ' ' + $t2.Stderr)
        $twoTasks = Invoke-P0ProofCli @('-Action', 'complete', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($twoTasks.ExitCode -eq 1) -and ($twoTasks.Stderr -match 'T1, T2, and T3')) 'complete refuses with only two completed tasks' $twoTasks.Stderr
        $t3 = Invoke-P0ProofCli @('-Action', 'record-task', '-StoreDir', $store, '-GoalId', 'proof-test-001', '-TaskId', 'T3', '-EvidencePath', $evidence, '-Summary', 'independent validation passed')
        Assert-P0Proof (($t3.ExitCode -eq 0) -and ([long]$t3.Json.satisfied -eq 3) -and ((@($t3.Json.completed_tasks) -join ',') -ceq 'T1,T2,T3')) 'T3 completion reaches all tasks and satisfied=3' ($t3.Stdout + ' ' + $t3.Stderr)
        $done = Invoke-P0ProofCli @('-Action', 'complete', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($done.ExitCode -eq 0) -and ([string]$done.Json.state -ceq 'COMPLETED') -and ([long]$done.Json.revision -gt [long]$t3.Json.revision)) 'complete transitions Goal to COMPLETED' ($done.Stdout + ' ' + $done.Stderr)
        $doneAgain = Invoke-P0ProofCli @('-Action', 'complete', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($doneAgain.ExitCode -eq 1) -and ($doneAgain.Stderr -match 'terminal-goal')) 'complete after COMPLETED is refused as terminal' $doneAgain.Stderr
        $status = Invoke-P0ProofCli @('-Action', 'status', '-StoreDir', $store, '-GoalId', 'proof-test-001')
        Assert-P0Proof (($status.ExitCode -eq 0) -and ([string]$status.Json.state -ceq 'COMPLETED') -and ([long]$status.Json.progress.satisfied -eq 3) -and ((@($status.Json.tasks.completed) -join ',') -ceq 'T1,T2,T3')) 'status reflects persisted terminal Goal and progress' ($status.Stdout + ' ' + $status.Stderr)
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
Write-Host ('P0-AUTONOMY-PROOF: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }
exit 0
