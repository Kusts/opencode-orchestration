[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationLocalizedRepair.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationVerifier.ps1')
$script:passed=0; $script:failed=0
function Assert-RL { param([bool]$Condition,[string]$Name,[string]$Detail=''); if($Condition){Write-Host "[PASS] $Name";$script:passed++}else{Write-Host "[FAIL] $Name -- $Detail";$script:failed++} }
function Hash-RL { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Text-RL { param([string]$Path,[string]$Text); [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function Quote-RL { param([string]$Value); $v=$Value -replace '(\\*)"','$1$1\"'; $v=$v -replace '(\\+)$','$1$1'; return '"'+$v+'"' }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('review-repair-loop-'+[guid]::NewGuid().ToString('N'))
$tasks=Join-Path $tmp 'tasks'; $repo=Join-Path $tmp 'repo'; $flags=Join-Path $tmp 'flags.json'; $policy=Join-Path $repo 'policy.json'
New-Item -ItemType Directory -Path $tasks,$repo -Force|Out-Null
Text-RL $flags '{"task_kernel":{"enabled":true,"shadow":false}}'
function New-LoopFixture {
  $null=& git -C $repo init -b master 2>$null
  if($LASTEXITCODE -ne 0){$null=& git -C $repo init 2>$null}
  & git -C $repo config user.email 'loop@example.com' 2>$null
  & git -C $repo config user.name 'Loop Test' 2>$null
  & git -C $repo config core.autocrlf false 2>$null
  & git -C $repo config core.safecrlf false 2>$null
  Text-RL (Join-Path $repo 'base.txt') "base`n"
  $prof=New-Object PSCustomObject
  $prof|Add-Member -NotePropertyName passes -NotePropertyValue ([PSCustomObject]@{class='test';command='powershell -NoProfile -Command exit 0';timeout_seconds=60})
  $doc=[ordered]@{version=1;default_timeout_seconds=120;max_output_chars=4000;profiles=$prof}
  Text-RL $policy (ConvertTo-Json -InputObject (New-Object PSCustomObject -Property $doc) -Depth 6 -Compress)
  & git -C $repo add -A 2>$null; & git -C $repo commit -m init -q 2>$null
  if($LASTEXITCODE -ne 0){throw 'fixture git commit failed'}
  $budget=Get-ExecutionBudgetDefaultPolicyPath
  $created=New-OrchestrationTask -TaskId loop-task-001 -Objective 'Fix review finding' -TaskType implementation -Risk low -Actor planner `
    -RuntimeId opencode-v1 -RuntimeGeneration 1 -RuntimeProfile v1 -RuntimeVersion 1.18.32 -BaseRevision HEAD `
    -ReadScopes @('src') -WriteScopes @('src') -Grants @('fs.read','fs.write') -AcceptanceCriteria @('review fix verified') `
    -ExpectedArtifacts @('src/a.ts') -VerificationProfiles @('passes') -AttemptBudget 3 -BudgetPolicyPath $budget `
    -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
  if(-not $created.ok){throw "fixture task creation: $($created.error)"}
}
function Move-ToReview {
  $null=Invoke-OrchestrationTaskTransition -TaskId loop-task-001 -ToState PLANNING -Actor planner -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
  $null=Invoke-OrchestrationTaskTransition -TaskId loop-task-001 -ToState IMPLEMENTING -Actor planner -ExpectedRevision 2 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
  $null=Invoke-OrchestrationTaskTransition -TaskId loop-task-001 -ToState VALIDATING -Actor coder -ExpectedRevision 3 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
  $worker=Set-OrchestrationTaskWorkerResult -TaskId loop-task-001 -Status candidate_pass -ClaimedEvidence @('criterion:0:review fix verified') -ProducedBy coder -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
  if(-not $worker.ok){throw "candidate_pass: $($worker.error)"}
  $null=Invoke-OrchestrationTaskTransition -TaskId loop-task-001 -ToState REVIEWING -Actor tester -ExpectedRevision 5 -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
}
try {
 New-LoopFixture
 Move-ToReview
 $head=(& git -C $repo rev-parse HEAD).Trim()
 $finding=@(@{finding_id='F-1';file='src/a.ts';line=1;commit_sha=$head;message='Handle the reviewed case';severity='low'})|ConvertTo-Json -Depth 5 -Compress
 $r=Set-OrchestrationTaskReview -TaskId loop-task-001 -Kind reviewer -Status changes_required -By reviewer -ExpectedRevision 6 -FindingsJson $finding -TasksDir $tasks -FlagsPath $flags
 if(-not $r.ok){throw "changes_required review: $($r.error)"}
 $beforeRec=Get-OrchestrationTask -TaskId loop-task-001 -TasksDir $tasks -RepoRoot $repo
 $decision=Resolve-OrchestrationLocalizedRepair -Severity low -ChangedFiles 1 -ScopeOverlap $true -ExternalEffectsAmbiguous $false -EvidenceCurrent $true -Attempts 0 -FailureClass localized
 $json=ConvertTo-Json -InputObject $decision -Depth 5 -Compress
 $saved=Add-OrchestrationTaskRepairDecision -TaskId loop-task-001 -RepairDecisionJson $json -ExpectedRevision 7 -RecordedBy planner -Severity low -ChangedFiles 1 -ScopeOverlap $true -EvidenceCurrent $true -Attempts 0 -FailureClass localized -TasksDir $tasks -FlagsPath $flags
 if(-not $saved.ok){throw "repair decision: $($saved.error)"}
 $afterDecision=Get-OrchestrationTask -TaskId loop-task-001 -TasksDir $tasks -RepoRoot $repo
 Assert-RL ($decision.decision -eq 'LOCAL_REPAIR' -and @($afterDecision.review.findings).Count -eq 1 -and $afterDecision.review.findings_count -eq 1) 'findings persist through advisory decision'
  Assert-RL ($afterDecision.state -eq $beforeRec.state -and $afterDecision.review.status -eq $beforeRec.review.status -and $afterDecision.worker_result.produced_by -eq $beforeRec.worker_result.produced_by -and $afterDecision.worker_result.status -eq $beforeRec.worker_result.status -and $null -eq $afterDecision.verification) 'state, review, worker preserved and verification unchanged before verify'
 $approved=Set-OrchestrationTaskReview -TaskId loop-task-001 -Kind reviewer -Status approved -By reviewer -ExpectedRevision 8 -TasksDir $tasks -FlagsPath $flags
 if(-not $approved.ok){throw "approved review: $($approved.error)"}
 $vr=Invoke-TaskKernelVerifyRun -TaskId loop-task-001 -ExpectedRevision 9 -VerificationPolicyPath $policy -TasksDir $tasks -FlagsPath $flags -RepoRoot $repo
 if(-not $vr.ok){throw "verify-run: $($vr.error)"}
 $done=Complete-OrchestrationTask -TaskId loop-task-001 -Actor planner -ExpectedRevision 10 -ResidualRisks @('none outstanding') -OrchestrationCompliance COMPLIANT -ActorIdentitySource explicit-cli -TasksDir $tasks -FlagsPath $flags
 if(-not $done.ok){throw "complete: $($done.error)"}
 $rec=Get-OrchestrationTask -TaskId loop-task-001 -TasksDir $tasks -RepoRoot $repo
 Assert-RL ($rec.state -eq 'DONE' -and @($rec.review_history).Count -eq 1 -and @($rec.repair_decisions).Count -eq 1 -and $rec.repair_decisions[0].decision -eq 'LOCAL_REPAIR') 'full review repair loop reaches DONE with review history and advisory record'
 Assert-RL ($rec.worker_result.status -eq 'candidate_pass' -and $rec.verification.verification_source -eq 'kernel-executed') 'worker and kernel verification preserved at DONE'

 $file=Join-Path $tasks 'loop-task-001.json'; $bytes=Hash-RL $file
 $bad=Add-OrchestrationTaskRepairDecision -TaskId loop-task-001 -RepairDecisionJson 'bad-json' -ExpectedRevision 11 -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
 Assert-RL ($bad.error -eq 'REPAIR_DECISION_INVALID' -and (Hash-RL $file) -eq $bytes) 'invalid JSON refused without write'
 $cas=Add-OrchestrationTaskRepairDecision -TaskId loop-task-001 -RepairDecisionJson $json -ExpectedRevision 10 -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
 Assert-RL ($cas.error -eq 'CAS_CONFLICT' -and (Hash-RL $file) -eq $bytes) 'stale CAS refused without write'
 $terminal=Add-OrchestrationTaskRepairDecision -TaskId loop-task-001 -RepairDecisionJson $json -ExpectedRevision 11 -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
 Assert-RL ($terminal.error -eq 'TASK_TERMINAL' -and (Hash-RL $file) -eq $bytes) 'terminal task refused without write'

 # Exercise the 20-entry cap on a separate active task, carrying each CAS revision forward.
 $null=New-OrchestrationTask -TaskId bound-task-001 -Objective bound -Actor planner -RuntimeId opencode-v1 -RuntimeGeneration 1 -RuntimeProfile v1 -RuntimeVersion 1.18.32 -ReadScopes @('src') -WriteScopes @('src') -Grants @('fs.read') -AcceptanceCriteria @('x') -ExpectedArtifacts @('x') -TasksDir $tasks -FlagsPath $flags
 for($i=1;$i -le 21;$i++){
   $p=[PSCustomObject]@{ok=$true;decision='LOCAL_REPAIR';reason="decision-$i";constraints=@('same-task')}
   $x=Add-OrchestrationTaskRepairDecision -TaskId bound-task-001 -RepairDecisionJson (ConvertTo-Json $p -Compress) -ExpectedRevision $i -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
   if(-not $x.ok){throw "bound decision $i`: $($x.error)"}
 }
 $bounded=Get-OrchestrationTask -TaskId bound-task-001 -TasksDir $tasks -RepoRoot $repo
 Assert-RL (@($bounded.repair_decisions).Count -eq 20 -and $bounded.repair_decisions[0].reason -eq 'decision-2' -and $bounded.repair_decisions[-1].reason -eq 'decision-21') '21 decisions retain the latest 20 in order'
 $boundFile=Join-Path $tasks 'bound-task-001.json'; $badBytes=Hash-RL $boundFile
 $invalidCases=@(
   @{json='{"ok":false,"decision":"LOCAL_REPAIR","reason":"x","constraints":[]}';error='REPAIR_DECISION_INVALID';name='ok=false'},
   @{json='{"ok":true,"decision":"OTHER","reason":"x","constraints":[]}';error='REPAIR_DECISION_NOT_ALLOWED';name='decision outside enum'},
   @{json=(ConvertTo-Json -Compress @{ok=$true;decision='LOCAL_REPAIR';reason='x';constraints=@(('x'*65))});error='REPAIR_DECISION_INVALID';name='constraint too long'},
   @{json=(ConvertTo-Json -Compress @{ok=$true;decision='LOCAL_REPAIR';reason='x';constraints=@(1..11|ForEach-Object {'c'})});error='REPAIR_DECISION_TOO_LARGE';name='too many constraints'},
   @{json=(' '*16385);error='REPAIR_DECISION_TOO_LARGE';name='payload over 16 KiB'}
 )
 foreach($case in $invalidCases){
   $rejected=Add-OrchestrationTaskRepairDecision -TaskId bound-task-001 -RepairDecisionJson $case.json -ExpectedRevision 22 -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
   Assert-RL ($rejected.error -eq $case.error -and (Hash-RL $boundFile) -eq $badBytes) "$($case.name) refused without write" $rejected.error
 }
 $badContext=Add-OrchestrationTaskRepairDecision -TaskId bound-task-001 -RepairDecisionJson $json -ExpectedRevision 22 -RecordedBy planner -Severity urgent -TasksDir $tasks -FlagsPath $flags
 Assert-RL ($badContext.error -eq 'REPAIR_DECISION_INVALID' -and (Hash-RL $boundFile) -eq $badBytes) 'invalid context rejected without write'
 Text-RL $flags '{"task_kernel":{"enabled":false,"shadow":false}}'
 $disabled=Add-OrchestrationTaskRepairDecision -TaskId bound-task-001 -RepairDecisionJson $json -ExpectedRevision 22 -RecordedBy planner -TasksDir $tasks -FlagsPath $flags
 Assert-RL ($disabled.error -eq 'KERNEL_DISABLED' -and (Hash-RL $boundFile) -eq $badBytes) 'disabled kernel refused without write'
 Text-RL $flags '{"task_kernel":{"enabled":true,"shadow":false}}'

 $cli=Join-Path $PSScriptRoot '..\task-kernel.ps1'; $cli=(Resolve-Path $cli).Path
 $psExe=(Get-Process -Id $PID).Path
 $cliArgs=@('-NoProfile','-File',$cli,'-Action','record-repair-decision','-TaskId','bound-task-001','-ExpectedRevision','22','-RecordedBy','planner','-RepairDecisionJson',$json,'-TasksDir',$tasks,'-FlagsPath',$flags)
 $start=New-Object Diagnostics.ProcessStartInfo; $start.FileName=$psExe; $start.Arguments=(($cliArgs|ForEach-Object { Quote-RL ([string]$_) }) -join ' '); $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
 $proc=[Diagnostics.Process]::Start($start); $stdOut=$proc.StandardOutput.ReadToEnd(); $stdErr=$proc.StandardError.ReadToEnd(); $proc.WaitForExit(); $cliExit=$proc.ExitCode; $cliOut=$stdOut+$stdErr
 $cliResult=$null; try{$cliResult=$cliOut|ConvertFrom-Json -ErrorAction Stop}catch{}
 Assert-RL ($cliExit -eq 0 -and $cliResult.ok -and $cliResult.revision -eq 23) 'CLI record-repair-decision succeeds in child process' $cliOut
 $usageArgs=@('-NoProfile','-File',$cli,'-Action','record-repair-decision','-TaskId','bound-task-001')
 $start.Arguments=(($usageArgs|ForEach-Object { Quote-RL ([string]$_) }) -join ' '); $proc=[Diagnostics.Process]::Start($start); $usageOut=$proc.StandardOutput.ReadToEnd()+$proc.StandardError.ReadToEnd(); $proc.WaitForExit(); $usageExit=$proc.ExitCode
 Assert-RL ($usageExit -eq 2) 'CLI missing required parameters exits with usage code 2' $usageOut
} catch { Write-Host ('[ERROR] ' + $_.Exception.Message); $script:failed++ }
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "REVIEW-REPAIR-LOOP: $passed passed / $failed failed"
if($failed){exit 1}; exit 0
