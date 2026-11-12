<#
.SYNOPSIS
    Deterministic TEMP-store coverage for reviewer schema and retry decisions.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')
$repo=Get-TaskKernelRepoRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('retry-decision-' + [guid]::NewGuid().ToString('N'))
$tasks=Join-Path $temp 'tasks'; $flags=Join-Path $temp 'flags.json'; $testRepo=Join-Path $temp 'repo'
$script:passed=0; $script:failed=0
function Assert-E2E([bool]$ok,[string]$name){if($ok){$script:passed++;Write-Host ('[PASS] '+$name)}else{$script:failed++;Write-Host ('[FAIL] '+$name)}}
function Invoke-DecisionCli([string]$id,[int]$revision,[string]$ambiguous='false',[string]$failureClass='localized'){
    $hostPath=[string](Get-Process -Id $PID).Path
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'task-kernel.ps1'),'-Action','retry-decision','-TaskId',$id,'-ExpectedRevision',[string]$revision,'-Severity','high','-ScopeOverlap','true','-ExternalEffectsAmbiguous',$ambiguous,'-EvidenceCurrent','true','-TasksDir',$tasks,'-FlagsPath',$flags)
    $args+=@('-ChangedFiles','1','-FailureClass',$failureClass)
    $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try {$out=& $hostPath @args 2>&1} finally {$ErrorActionPreference=$oldPreference}
    return [pscustomobject]@{code=$LASTEXITCODE;stdout=($out -join "`n");json=$(try{($out -join "`n")|ConvertFrom-Json}catch{$null})}
}
try {
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    New-Item -ItemType Directory -Path $testRepo -Force | Out-Null
    [IO.File]::WriteAllText($flags,'{"task_kernel":{"enabled":true,"shadow":false}}',[Text.UTF8Encoding]::new($false))
    & git -C $testRepo init -b main *>$null
    if($LASTEXITCODE -ne 0){& git -C $testRepo init *>$null}
    & git -C $testRepo config user.email 'test@example.com' *>$null
    & git -C $testRepo config user.name 'Test' *>$null
    & git -C $testRepo config core.autocrlf false *>$null
    & git -C $testRepo config core.safecrlf false *>$null
    [IO.File]::WriteAllText((Join-Path $testRepo 'fixture.txt'),"fixture`n",[Text.UTF8Encoding]::new($false))
    $policy=Join-Path $testRepo 'verify-policy.json'
    $profiles=New-Object PSCustomObject
    $profiles | Add-Member -NotePropertyName passes -NotePropertyValue ([PSCustomObject]@{class='test';command='powershell -NoProfile -Command exit 0';timeout_seconds=30})
    [IO.File]::WriteAllText($policy,([ordered]@{version=1;default_timeout_seconds=60;max_output_chars=1000;profiles=$profiles}|ConvertTo-Json -Depth 6 -Compress),[Text.UTF8Encoding]::new($false))
    & git -C $testRepo add -A *>$null; & git -C $testRepo commit -m init -q *>$null
    $baseRevision=(& git -C $testRepo rev-parse HEAD).Trim()
    $id='repair-e2e-001'
    $budgetPolicy=Get-ExecutionBudgetDefaultPolicyPath
    $c=New-OrchestrationTask -TaskId $id -Objective 'review repair proof' -TaskType implementation -Risk low -RuntimeId opencode-v2 -RuntimeGeneration 2 -RuntimeProfile v2 -RuntimeVersion '2.2.6' -Actor planner -BaseRevision $baseRevision -AcceptanceCriteria @('fixture passes') -VerificationProfiles @('passes') -BudgetPolicyPath $budgetPolicy -RepoRoot $testRepo -TasksDir $tasks -FlagsPath $flags
    $null=Invoke-OrchestrationTaskTransition -TaskId $id -ToState PLANNING -Actor planner -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
    $null=Invoke-OrchestrationTaskTransition -TaskId $id -ToState IMPLEMENTING -Actor planner -ExpectedRevision 2 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
    $null=Invoke-OrchestrationTaskTransition -TaskId $id -ToState VALIDATING -Actor coder -ExpectedRevision 3 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
    $w=Set-OrchestrationTaskWorkerResult -TaskId $id -Status candidate_pass -ClaimedEvidence @('criterion:0') -ProducedBy coder -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
    $v=Invoke-TaskKernelVerifyRun -TaskId $id -ExpectedRevision 5 -VerificationPolicyPath $policy -TasksDir $tasks -FlagsPath $flags -RepoRoot $testRepo
    $null=Invoke-OrchestrationTaskTransition -TaskId $id -ToState REVIEWING -Actor tester -ExpectedRevision 6 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
    $finding=@(@{finding_id='F-1';file='src/example.ps1';line=4;commit_sha=$baseRevision;message='Fix the reviewed edge case.';severity='high'})|ConvertTo-Json -Depth 5
    $r=Set-OrchestrationTaskReview -TaskId $id -Kind reviewer -Status changes_required -By reviewer -ExpectedRevision 7 -FindingsJson $finding -TasksDir $tasks -FlagsPath $flags
    $blocked=Test-OrchestrationTaskCompletion -TaskId $id -TasksDir $tasks -OrchestrationCompliance COMPLIANT -ResidualRisks @('none')
    Assert-E2E ($c.ok -and $w.ok -and $v.ok -and $r.ok -and -not $blocked.complete -and @($blocked.reasons) -contains 'review-not-approved') ('review-findings-block-completion '+$c.error+'/'+$w.error+'/'+$v.error+'/'+$r.error+'/'+(@($blocked.reasons)-join ','))
    $local=Invoke-DecisionCli $id 8
    $after=Get-OrchestrationTask -TaskId $id -TasksDir $tasks
    Assert-E2E ($local.code -eq 0 -and $local.json.repair_decision.decision -eq 'LOCAL_REPAIR' -and $after.repair_decision.reason -eq 'localized-finding') 'cli-persists-local-repair-advisory'
    # Restore a fresh review state for a separate ambiguous-effects decision.
    $replan=Invoke-DecisionCli $id 9 'true'
    Assert-E2E ($replan.code -eq 0 -and $replan.json.repair_decision.decision -eq 'REPLAN') 'ambiguous-effect-replans'
    $escalateId='repair-e2e-002'
    $ec=New-OrchestrationTask -TaskId $escalateId -Objective 'retry budget proof' -TaskType implementation -Risk low -RuntimeId opencode-v2 -RuntimeGeneration 2 -RuntimeProfile v2 -RuntimeVersion '2.2.6' -Actor planner -BudgetPolicyPath $budgetPolicy -RepoRoot $testRepo -TasksDir $tasks -FlagsPath $flags
    $null=Set-OrchestrationTaskWorkerResult -TaskId $escalateId -Status failed -ProducedBy coder -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
    $null=Set-OrchestrationTaskWorkerResult -TaskId $escalateId -Status failed -ProducedBy coder -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
    $escalated=Invoke-DecisionCli $escalateId 3
    Assert-E2E ($ec.ok -and $escalated.code -eq 0 -and $escalated.json.repair_decision.decision -eq 'ESCALATE' -and $escalated.json.repair_decision.inputs.attempts -eq 2) 'task-attempt-counter-escalates-after-two'
    $approved=Set-OrchestrationTaskReview -TaskId $id -Kind reviewer -Status approved -By reviewer -ExpectedRevision 10 -TasksDir $tasks -FlagsPath $flags
    $gate=Test-OrchestrationTaskCompletion -TaskId $id -TasksDir $tasks -OrchestrationCompliance COMPLIANT -ResidualRisks @('none')
    $done=Complete-OrchestrationTask -TaskId $id -Actor planner -ExpectedRevision 11 -ResidualRisks @('none') -OrchestrationCompliance COMPLIANT -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
    Assert-E2E ($approved.ok -and $gate.complete -and $done.ok -and (Get-OrchestrationTask -TaskId $id -TasksDir $tasks).state -eq 'DONE') 'approved-review-completes-through-existing-kernel-gate'
    $invalid=Invoke-DecisionCli $id 12 'false' 'invalid'
    Assert-E2E ($invalid.code -ne 0 -and (Get-OrchestrationTask -TaskId $id -TasksDir $tasks).repair_decision.decision -eq 'REPLAN') 'invalid-input-fails-closed-without-overwriting-decision'
} catch {Write-Host ('[FAIL] unexpected: '+$_);Write-Host $_.ScriptStackTrace;$script:failed++}
finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}}
Write-Host ('RETRY-DECISION-E2E: '+$script:passed+' passed / '+$script:failed+' failed')
if($script:failed){exit 1};exit 0
