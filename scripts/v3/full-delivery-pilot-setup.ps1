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
    $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
        -Risk 'low' -Actor $owner -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.2.3' -BaseRevision $baseRev -ReadScopes @('src/pilot.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $WorkRoot
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
    artifact_dir = $artifactDir
    authorization_file = $authPath
    intent_a_file = $intentA
    intent_b_file = $intentB
    task_a_id = 'fd-task-a'
    task_b_id = 'fd-task-b'
    objective_step = (Join-Path $PSScriptRoot 'objective-step.ps1')
}
Write-Host (ConvertTo-Json -InputObject $result -Depth 5 -Compress)