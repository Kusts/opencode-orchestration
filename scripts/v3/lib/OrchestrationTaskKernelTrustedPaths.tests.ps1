<#!
.SYNOPSIS
    CLI trusted-path binding regressions (ROUTER-V14).
.DESCRIPTION
    Proves verify-run, model-attempt, model-proof, model-select refuse
    divergent caller-selected paths BEFORE any store I/O with
    TRUSTED_PATH_MISMATCH + path_role enum, no path echo, no dest read.
    No providers, no network, no inference. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$libRoot = $PSScriptRoot
. (Join-Path $libRoot 'OrchestrationTaskKernel.ps1')
$script:pass = 0; $script:fail = 0
function Assert-TP([bool]$c,[string]$n,[string]$d='') {
    if ($c) { Write-Host ("[PASS] {0}" -f $n); $script:pass++ }
    else { if ($d -eq '') { Write-Host ("[FAIL] {0}" -f $n) } else { Write-Host ("[FAIL] {0} -- {1}" -f $n,$d) }; $script:fail++ }
}
try {
    $cliPs1 = Join-Path (Split-Path -Parent $libRoot) 'task-kernel.ps1'
    $canonTasks = Get-TaskKernelDefaultTasksDir -RepoRoot ''
    $canonFlags = Get-TaskKernelDefaultFlagsPath -RepoRoot ''
    $canonRoot = Get-TaskKernelRepoRoot -RepoRoot ''
    $canonPol = Get-TaskKernelModelPolicyDefaultPath -RepoRoot ''
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('tp-kernel-' + [guid]::NewGuid().ToString('N'))
    $tasksDir = Join-Path $tmpRoot 'tasks'
    $flagsPath = Join-Path $tmpRoot 'flags.json'
    $altStore = Join-Path $tmpRoot 'alt-store'
    $altFlags = Join-Path $tmpRoot 'alt-flags.json'
    $altPol = Join-Path $tmpRoot 'alt-model-policy.json'
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    New-Item -ItemType Directory -Path $altStore -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($altFlags, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($altPol, '{}', [Text.UTF8Encoding]::new($false))
    $tid = 'tp-trust-001'
    $cr = New-OrchestrationTask -TaskId $tid -Objective 'Trusted path fixture' -TaskType 'implementation' -Risk 'low' -Actor 'planner' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.5' -BaseRevision 'HEAD' -ReadScopes @('src/a') -WriteScopes @() -Grants @('fs.read') -AcceptanceCriteria @('a holds') -ExpectedArtifacts @('src/a/out.js') -VerificationProfiles @() -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tmpRoot
    Assert-TP ([bool]$cr.ok) 'TP00-fixture-created-library-injectable' ([string]$cr.error)
    $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $tasksDir
    $before = [IO.File]::ReadAllBytes($taskFile)
    $h0 = (([Security.Cryptography.SHA256]::Create().ComputeHash($before) | ForEach-Object { $_.ToString('x2') }) -join '')
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-proof -TaskId $tid -RequiredTier T3 -TasksDir $altStore 2>&1 | Out-String
    $d1 = ($o1 | ConvertFrom-Json -ErrorAction Stop)
    Assert-TP ((([string]$d1.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$d1.path_role -ceq 'tasks_dir') -and ($o1 -notmatch [regex]::Escape($altStore)))) 'TP01-model-proof-divergent-tasksdir-refused' ("err=" + [string]$d1.error)
    Assert-TP ((@(Get-ChildItem -LiteralPath $altStore -ErrorAction SilentlyContinue)).Count -eq 0) 'TP02-alt-store-creates-no-task' ''
    $o3 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-select -TaskId $tid -AttemptRole coder -PolicyPath $altPol 2>&1 | Out-String
    $d3 = ($o3 | ConvertFrom-Json -ErrorAction Stop)
    Assert-TP ((([string]$d3.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$d3.path_role -ceq 'model_policy') -and ($o3 -notmatch [regex]::Escape($altPol)))) 'TP03-model-select-divergent-policy-refused' ("err=" + [string]$d3.error)
    $o4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-attempt -TaskId $tid -SessionId 'ses-x' -ExpectedRevision 1 -FlagsPath $altFlags 2>&1 | Out-String
    $d4 = ($o4 | ConvertFrom-Json -ErrorAction Stop)
    Assert-TP ((([string]$d4.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$d4.path_role -ceq 'flags_path'))) 'TP04-model-attempt-divergent-flags-refused' ("err=" + [string]$d4.error)
    $o5 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action verify-run -TaskId $tid -ExpectedRevision 1 -CliRepoRoot $tmpRoot -TasksDir $altStore 2>&1 | Out-String
    $d5 = ($o5 | ConvertFrom-Json -ErrorAction Stop)
    Assert-TP ((([string]$d5.error -ceq 'TRUSTED_PATH_MISMATCH') -and (([string]$d5.path_role -ceq 'repo_root') -or ([string]$d5.path_role -ceq 'tasks_dir')))) 'TP05-verify-run-divergent-root-refused' ("role=" + [string]$d5.path_role)
    $after = [IO.File]::ReadAllBytes($taskFile)
    $h1 = (([Security.Cryptography.SHA256]::Create().ComputeHash($after) | ForEach-Object { $_.ToString('x2') }) -join '')
    Assert-TP (($h0 -ceq $h1)) 'TP06-verify-run-refusal-alters-no-task-bytes' ''
    $o7 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-proof -TaskId 'tp-no-such-task-zzz' -RequiredTier T3 -TasksDir $canonTasks -FlagsPath $canonFlags -CliRepoRoot $canonRoot -PolicyPath $canonPol 2>&1 | Out-String
    $d7 = ($o7 | ConvertFrom-Json -ErrorAction Stop)
    Assert-TP ((([string]$d7.error -ceq 'NOT_FOUND') -and ($o7 -notmatch 'TRUSTED_PATH_MISMATCH'))) 'TP07-canonical-equivalent-paths-accepted' ("err=" + [string]$d7.error)
    try { if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:fail++
}
Write-Host ("RESULTS {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
