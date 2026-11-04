<#!
.SYNOPSIS
    Etapa 1 FULL_DELIVERY — setup do piloto isolado (runtime real).
.DESCRIPTION
    Cria um Goal isolado com duas tarefas dependentes (Task A gera artefato
    estruturado; Task B consome o artefato de A e produz segundo resultado).
    Persiste goal/tasks/ownership e escreve os arquivos de autorizacao e
    intent necessarios para objective-step.ps1 next/settle.
    Imprime um JSON com todos os caminhos e IDs para o Planner consumir.
    Nao executa dispatch, nao spawna worker, nao toca ambiente produtivo.
    PS 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$WorkRoot = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationNativeDispatch.ps1')

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('fd-pilot-' + [guid]::NewGuid().ToString('N'))
}
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$goalDir = Join-Path $WorkRoot 'goals'
$ckptDir = Join-Path $WorkRoot 'checkpoints'
$receiptDir = Join-Path $WorkRoot 'receipts'
$evDir = Join-Path $WorkRoot 'evidence'
$tasksDir = Join-Path $WorkRoot 'tasks'
$flagsPath = Join-Path $WorkRoot 'flags.json'
$artifactDir = Join-Path $WorkRoot 'artifacts'
foreach ($d in @($goalDir,$ckptDir,$receiptDir,$evDir,$tasksDir,$artifactDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
[IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

# Repo de verificacao fixado do piloto: o policy commitado e o plano de
# verificacao de cada task (profiles checam o artefato real) e a branch
# 'rev-pilot' torna base_revision um ref resolvivel para o kernel.
$verifyRepo = Join-Path $WorkRoot 'verify-repo'
New-Item -ItemType Directory -Path (Join-Path $verifyRepo 'source\registry') -Force | Out-Null
function Invoke-PilotGit {
    param([string]$Dir, [string[]]$GitArgs)
    & git -C $Dir @GitArgs *> $null
    if ($LASTEXITCODE -ne 0) { throw ('pilot-git-failed: ' + ($GitArgs -join ' ') + ' exit=' + [string]$LASTEXITCODE) }
}
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('init', '-q')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('config', 'user.email', 'pilot-fixture@example.com')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('config', 'user.name', 'Pilot Fixture')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('config', 'core.autocrlf', 'false')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('config', 'core.safecrlf', 'false')
$checkArt = @'
$ErrorActionPreference = 'Stop'
$kind = ''
if ($args.Count -ge 1) { $kind = [string]$args[0] }
$root = Split-Path -Parent $PSScriptRoot
$pa = Join-Path $root 'artifacts\output-a.json'
$pb = Join-Path $root 'artifacts\output-b.json'
if ($kind -ceq 'A') {
    if (-not (Test-Path -LiteralPath $pa -PathType Leaf)) { exit 1 }
    try { $o = [IO.File]::ReadAllText($pa, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { exit 1 }
    if ($null -eq $o) { exit 1 }
    if ([int]$o.value -ne 42) { exit 1 }
    if ([string]$o.from -cne 'task-a') { exit 1 }
    exit 0
}
if ($kind -ceq 'B') {
    if (-not (Test-Path -LiteralPath $pb -PathType Leaf)) { exit 1 }
    try { $o = [IO.File]::ReadAllText($pb, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { exit 1 }
    if ($null -eq $o) { exit 1 }
    if ([int]$o.derived -ne 84) { exit 1 }
    $src = $o.source
    $ok = $false
    if ($src -is [string]) {
        try { $s2 = $src | ConvertFrom-Json; if (($null -ne $s2) -and ([int]$s2.value -eq 42) -and ([string]$s2.from -ceq 'task-a')) { $ok = $true } } catch { $ok = $false }
    } elseif ($null -ne $src) {
        try { if (([int]$src.value -eq 42) -and ([string]$src.from -ceq 'task-a')) { $ok = $true } } catch { $ok = $false }
    }
    if (-not $ok) { exit 1 }
    exit 0
}
exit 1
'@
$lfArt = ($checkArt -replace "`r`n", "`n") -replace "`r", "`n"
[IO.File]::WriteAllText((Join-Path $verifyRepo 'check-artifact.ps1'), $lfArt, [Text.UTF8Encoding]::new($false))
$pilotPol = [ordered]@{
    version                 = 1
    default_timeout_seconds = 60
    max_output_chars        = 4000
    profiles                = @{
        'fd-artifact-a' = [ordered]@{ class = 'test'; command = 'powershell -NoProfile -File check-artifact.ps1 A'; timeout_seconds = 30 }
        'fd-artifact-b' = [ordered]@{ class = 'test'; command = 'powershell -NoProfile -File check-artifact.ps1 B'; timeout_seconds = 30 }
    }
}
[IO.File]::WriteAllText((Join-Path $verifyRepo 'source\registry\verification-policy.json'), (($pilotPol | ConvertTo-Json -Depth 6 -Compress) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('add', '-A')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('commit', '-q', '-m', 'pilot verification plan')
Invoke-PilotGit -Dir $verifyRepo -GitArgs @('branch', 'rev-pilot')

$goalId = 'fd-pilot-goal'
$owner = 'planner-1'
$ph = Get-NativeDispatchHash32 'fd-pilot-prompt-material'
$baseRev = 'rev-pilot'

# Goal
$g = New-OrchestrationGoal -GoalId $goalId -Objective 'gerar e consumir artefato (piloto FULL_DELIVERY)' -Criteria @('artefato-gerado','artefato-consumido') -TotalPhases 2 -StoreDir $goalDir
if (-not [bool]$g.ok) { throw ('goal-create-failed: ' + [string]$g.reason) }
$act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
$sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
if (-not [bool]$sv.ok) { throw ('goal-save-failed: ' + [string]$sv.reason) }
$own = Acquire-OrchestrationGoalOwnership -GoalId $goalId -OwnerId $owner -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
if (-not [bool]$own.ok) { throw ('ownership-failed: ' + [string]$own.reason) }
$gen = [long]$own.ownership['generation']

function New-PilotTask {
    param([string]$Id)
    $prof = if ($Id -ceq 'fd-task-a') { 'fd-artifact-a' } else { 'fd-artifact-b' }
    $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
        -Risk 'low' -Actor $owner -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.2.3' -BaseRevision $baseRev -ReadScopes @('src/pilot.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 `
        -VerificationProfiles @($prof) -RepoRoot $verifyRepo -BudgetPolicyPath (Get-ExecutionBudgetDefaultPolicyPath) `
        -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $WorkRoot
    if (-not [bool]$c.ok) { throw ('task-create-failed ' + $Id + ': ' + [string]$c.error) }
    $slot = Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $goalId -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    if (-not [bool]$add.ok) { throw ('task-attach-failed ' + $Id + ': ' + [string]$add.reason) }
}
New-PilotTask -Id 'fd-task-a'
New-PilotTask -Id 'fd-task-b'

# Authorization file (consumed by objective-step.ps1 next)
$auth = @{ explicit_allow = $true; goal_id = $goalId; owner = $owner; generation = $gen; source = 'planner' }
$authPath = Join-Path $WorkRoot 'authorization.json'
[IO.File]::WriteAllText($authPath, (ConvertTo-Json -InputObject $auth -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))

# Intent files
function Write-Intent {
    param([string]$TaskId, [string]$Path)
    $intent = @{
        task_id = $TaskId; task_expected_revision = 1; agent = 'coder';
        prompt_hash = $ph; scope = @('src/pilot.ps1');
        acceptance_criteria = @('criterion:0');
        owner = $owner; ownership_generation = $gen; base_revision = $baseRev
    }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $intent -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
}
$intentA = Join-Path $WorkRoot 'intent-a.json'
$intentB = Join-Path $WorkRoot 'intent-b.json'
Write-Intent -TaskId 'fd-task-a' -Path $intentA
Write-Intent -TaskId 'fd-task-b' -Path $intentB

$result = [ordered]@{
    work_root = $WorkRoot
    goal_id = $goalId
    owner = $owner
    generation = $gen
    goal_store_dir = $goalDir
    checkpoint_dir = $ckptDir
    receipt_dir = $receiptDir
    evidence_dir = $evDir
    tasks_dir = $tasksDir
    flags_path = $flagsPath
    verify_repo = $verifyRepo
    artifact_dir = $artifactDir
    authorization_file = $authPath
    intent_a_file = $intentA
    intent_b_file = $intentB
    task_a_id = 'fd-task-a'
    task_b_id = 'fd-task-b'
    objective_step = (Join-Path $PSScriptRoot 'objective-step.ps1')
}
Write-Host (ConvertTo-Json -InputObject $result -Depth 5 -Compress)