[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('p32-'+[guid]::NewGuid().ToString('N'))
$tasks=Join-Path $root 'tasks';$flags=Join-Path $root 'flags.json'
New-Item -ItemType Directory -Path $tasks -Force|Out-Null
[IO.File]::WriteAllText($flags,'{"task_kernel":{"enabled":true,"shadow":false}}',[Text.UTF8Encoding]::new($false))
$passed=0;$failed=0
function Check([bool]$ok,[string]$name){if($ok){Write-Host "[PASS] $name";$script:passed++}else{Write-Host "[FAIL] $name";$script:failed++}}
try {
 $t=New-OrchestrationTask -TaskId 'p32-test-task' -Objective 'session binding test' -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
 Check ($t.ok) 'create task'
 $legacy=Get-OrchestrationTaskBindings -TaskId 'p32-test-task' -TasksDir $tasks
 Check ($legacy.ok -and @($legacy.bindings.runs).Count -eq 0) 'legacy no bindings read'
 $a=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-a' -ExpectedRevision 1 -Runtime 'opencode' -Version '1' -TasksDir $tasks -FlagsPath $flags
 Check ($a.ok) 'bind session'
 $same=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-a' -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
 Check ($same.ok -and $same.idempotent) 'same bind idempotent'
 $rOwner=Rebind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-b' -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
 Check ($rOwner.error -eq 'BIND_CONFLICT' -and $rOwner.existing_owner_id -eq 'sess-a') 'active rebind cannot steal owner'
 $preDetach=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-a' -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
 $r=Rebind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-b' -ExpectedRevision 3 -TasksDir $tasks -FlagsPath $flags
 Check ($preDetach.ok -and $r.ok) 'rebind detached run'
 $rSame=Rebind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-b' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
 Check ($rSame.ok -and $rSame.idempotent) 'rebind same session idempotent'
 $bad=Rebind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-b' -SessionId 'sess-c' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
 Check ($bad.error -eq 'REBIND_RUN_MISMATCH') 'rebind different run rejected'
 $conflict=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-c' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
 Check ($conflict.error -eq 'BIND_CONFLICT') 'different owner rejected'
 $stale=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-d' -ExpectedRevision 3 -TasksDir $tasks -FlagsPath $flags
 Check ($stale.error -eq 'CAS_CONFLICT') 'stale CAS loses race'
 $detach=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-b' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
 $after=Get-OrchestrationTask -TaskId 'p32-test-task' -TasksDir $tasks
 Check ($detach.ok -and $after.state -eq 'DISCOVERING') 'detach preserves task state'
 $again=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-b' -ExpectedRevision 5 -TasksDir $tasks -FlagsPath $flags
 Check ($again.ok -and $again.idempotent) 'detach idempotent'
 $wrongDetach=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'other' -ExpectedRevision 5 -TasksDir $tasks -FlagsPath $flags
 Check ($wrongDetach.error -eq 'BIND_CONFLICT') 'detached run rejects foreign session detach'
 $reattach=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId 'sess-e' -ExpectedRevision 5 -TasksDir $tasks -FlagsPath $flags
 Check ($reattach.ok -and $reattach.bindings.runs[0].status -eq 'attached') 'reattach after detach'
 $reconstructed=Get-OrchestrationTaskBindings -TaskId 'p32-test-task' -TasksDir $tasks
 Check ($reconstructed.ok -and @($reconstructed.bindings.runs).Count -eq 1) 'kernel is reconstruction source'

 foreach($invalidId in @("line`nbreak",'pipe|bad',('x'*256))) {
   $badBind=Bind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId $invalidId -SessionId 'valid' -ExpectedRevision 6 -TasksDir $tasks -FlagsPath $flags
   $badRebind=Rebind-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId $invalidId -ExpectedRevision 6 -TasksDir $tasks -FlagsPath $flags
   $badDetach=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId 'run-a' -SessionId $invalidId -ExpectedRevision 6 -TasksDir $tasks -FlagsPath $flags
   Check ($badBind.error -eq 'BIND_INVALID_ID' -and $badRebind.error -eq 'BIND_INVALID_ID' -and $badDetach.error -eq 'BIND_INVALID_ID') 'unsafe identifier rejected before mutation'
 }
 $emptyRun=Detach-OrchestrationTaskSession -TaskId 'p32-test-task' -RunId '' -SessionId 'sess-e' -ExpectedRevision 6 -TasksDir $tasks -FlagsPath $flags
 Check ($emptyRun.error -eq 'BIND_INVALID_ID') 'kernel requires RunId for detach'
 foreach($badMetadata in @(@{SeatId="bad`nid"},@{ParentId='bad|id'},@{RootId=('z'*256)})) {
   $args=@{TaskId='p32-test-task';RunId='run-meta';SessionId='meta-session';ExpectedRevision=6;TasksDir=$tasks;FlagsPath=$flags}
   foreach($key in $badMetadata.Keys){$args[$key]=$badMetadata[$key]}
   $metadataResult=Bind-OrchestrationTaskSession @args
   Check ($metadataResult.error -eq 'BIND_INVALID_ID') 'invalid seat/parent/root provenance ID rejected'
 }

 $live=New-OrchestrationTask -TaskId 'p32-implementing' -Objective 'detach while implementing' -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
 $p=Invoke-OrchestrationTaskTransition -TaskId 'p32-implementing' -ToState PLANNING -Actor planner -ActorIdentitySource explicit-cli -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
 $i=Invoke-OrchestrationTaskTransition -TaskId 'p32-implementing' -ToState IMPLEMENTING -Actor planner -ActorIdentitySource explicit-cli -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
 $ib=Bind-OrchestrationTaskSession -TaskId 'p32-implementing' -RunId 'run-live' -SessionId 'sess-live' -ExpectedRevision 3 -TasksDir $tasks -FlagsPath $flags
 $id=Detach-OrchestrationTaskSession -TaskId 'p32-implementing' -RunId 'run-live' -SessionId 'sess-live' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
 $it=Get-OrchestrationTask -TaskId 'p32-implementing' -TasksDir $tasks
 if(-not ($p.ok -and $i.ok -and $ib.ok -and $id.ok -and $it.state -eq 'IMPLEMENTING' -and $it.bindings.runs[0].status -eq 'detached' -and -not [string]::IsNullOrWhiteSpace($it.bindings.runs[0].detached_at))){Write-Host (($p|ConvertTo-Json -Compress)+' '+($i|ConvertTo-Json -Compress)+' '+($ib|ConvertTo-Json -Compress)+' '+($id|ConvertTo-Json -Compress)+' '+($it|ConvertTo-Json -Depth 6 -Compress))}
 $liveBinding=@($it.bindings.runs)[0]
 Check ($p.ok -and $i.ok -and $ib.ok -and $id.ok -and $it.state -eq 'IMPLEMENTING' -and $liveBinding.status -eq 'detached' -and -not [string]::IsNullOrWhiteSpace($liveBinding.detached_at)) 'IMPLEMENTING remains detached with timestamp'

 $cliTask=New-OrchestrationTask -TaskId 'p32-cli-task' -Objective 'CLI binding test' -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
  $cli=Join-Path (Split-Path -Parent $PSScriptRoot) 'task-kernel.ps1'
  $cliHost='powershell.exe'; if($PSVersionTable.PSEdition -eq 'Core'){$cliHost='pwsh.exe'}
  function Invoke-CLI([string[]]$CliArgs,[string]$HostExe=$cliHost) {
    $quoted=@($CliArgs | ForEach-Object { if($_ -match '\s'){ '"'+$_+'"' } else { $_ } }) -join ' '
    $proc=Start-Process -FilePath (Get-Command $HostExe).Source -ArgumentList (('-NoProfile -File "{0}" ' -f $cli)+$quoted) -Wait -PassThru -WindowStyle Hidden
   return [int]($proc.ExitCode -band 0xffff)
 }
  $cliBind=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-1','-ExpectedRevision','1','-TasksDir',$tasks,'-FlagsPath',$flags)
  $cliRebind=Invoke-CLI @('-Action','rebind-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-2','-ExpectedRevision','2','-TasksDir',$tasks,'-FlagsPath',$flags)
   $cliDetach=Invoke-CLI @('-Action','detach-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-1','-ExpectedRevision','2','-TasksDir',$tasks,'-FlagsPath',$flags)
   $cliDetachedRebind=Invoke-CLI @('-Action','rebind-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-2','-ExpectedRevision','3','-TasksDir',$tasks,'-FlagsPath',$flags)
   $cliConflict=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-4','-ExpectedRevision','4','-TasksDir',$tasks,'-FlagsPath',$flags)
   $cliFinalDetach=Invoke-CLI @('-Action','detach-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-2','-ExpectedRevision','4','-TasksDir',$tasks,'-FlagsPath',$flags)
   $cliReattach=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-task','-RunId','run-cli','-SessionId','cli-3','-ExpectedRevision','5','-TasksDir',$tasks,'-FlagsPath',$flags)
  $cliGet=Invoke-CLI @('-Action','get-bindings','-TaskId','p32-cli-task','-TasksDir',$tasks)
  $cliState=Get-OrchestrationTaskBindings -TaskId 'p32-cli-task' -TasksDir $tasks
  $cliUse=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-task')
  $cliOptionalTask=New-OrchestrationTask -TaskId 'p32-cli-detach' -Objective 'CLI run resolver' -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
  $cliOptionalBind=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-detach','-RunId','run-one','-SessionId','only-session','-ExpectedRevision','1','-TasksDir',$tasks,'-FlagsPath',$flags)
  $cliOptionalDetach=Invoke-CLI @('-Action','detach-session','-TaskId','p32-cli-detach','-SessionId','only-session','-ExpectedRevision','2','-TasksDir',$tasks,'-FlagsPath',$flags)
  $cliBadId=Invoke-CLI @('-Action','bind-session','-TaskId','p32-cli-detach','-RunId','bad|id','-SessionId','sid','-ExpectedRevision','3','-TasksDir',$tasks,'-FlagsPath',$flags)
 Check ($cliBind -eq 0 -and $cliRebind -eq 2 -and $cliDetach -eq 0 -and $cliDetachedRebind -eq 0 -and $cliFinalDetach -eq 0 -and $cliReattach -eq 0 -and $cliConflict -eq 2 -and $cliGet -eq 0 -and $cliUse -eq 1 -and $cliState.bindings.runs.status -eq 'attached' -and $cliOptionalBind -eq 0 -and $cliOptionalDetach -eq 0 -and $cliBadId -eq 1) 'CLI exits, optional run resolution, and get-bindings'

 . (Join-Path $PSScriptRoot 'OrchestrationBootstrapContext.ps1')
 $bootstrap=New-OrchestrationBootstrapContext -RepoRoot $root -TasksDir $tasks -FlagsPath $flags -JevPolicyPath (Join-Path $root 'none-jev.json') -AiMemoryPolicyPath (Join-Path $root 'none-memory.json') -ByteBudget 8192
  Check ($null -ne $bootstrap -and $bootstrap.tasks.Contains('active_count') -and $bootstrap.tasks.active_count -ge 1) 'bootstrap reads extended bound/detached records'

  foreach($cliHost in @('powershell.exe','pwsh.exe')) {
    $suffix=if($cliHost -eq 'pwsh.exe'){'pwsh'}else{'ps51'}
    $priorityId='p32-priority-'+$suffix
    $null=New-OrchestrationTask -TaskId $priorityId -Objective ('attached resolver priority '+$suffix) -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
    $null=Bind-OrchestrationTaskSession -TaskId $priorityId -RunId 'already-detached' -SessionId 'priority-sid' -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
    $null=Detach-OrchestrationTaskSession -TaskId $priorityId -RunId 'already-detached' -SessionId 'priority-sid' -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
    $null=Bind-OrchestrationTaskSession -TaskId $priorityId -RunId 'currently-attached' -SessionId 'priority-sid' -ExpectedRevision 3 -TasksDir $tasks -FlagsPath $flags
    $priorityCli=Invoke-CLI -HostExe $cliHost -CliArgs @('-Action','detach-session','-TaskId',$priorityId,'-SessionId','priority-sid','-ExpectedRevision','4','-TasksDir',$tasks,'-FlagsPath',$flags)
    $priorityState=Get-OrchestrationTaskBindings -TaskId $priorityId -TasksDir $tasks
    $priorityRecord=Get-OrchestrationTask -TaskId $priorityId -TasksDir $tasks
    $priorityRuns=@($priorityState.bindings.runs)
    $selectedRun=@($priorityRuns | Where-Object { $_.run_id -eq 'currently-attached' })[0]
    $priorityStep1=($priorityCli -eq 0 -and @($priorityState.bindings.runs).Count -eq 2 -and $selectedRun.status -eq 'detached' -and $priorityRecord.revision -eq 5)
    $priorityStep2=Invoke-CLI -HostExe $cliHost -CliArgs @('-Action','detach-session','-TaskId',$priorityId,'-RunId','currently-attached','-SessionId','priority-sid','-ExpectedRevision','5','-TasksDir',$tasks,'-FlagsPath',$flags)
    $priorityAfterStep2=Get-OrchestrationTask -TaskId $priorityId -TasksDir $tasks
    # Step 1 is itself detach; explicit RunId repeat is idempotent, not a
    # second state change. Both matching records are now detached.
    $priorityStep2Ok=($priorityStep2 -eq 0 -and $priorityAfterStep2.revision -eq 5)
    $priorityStep3=Invoke-CLI -HostExe $cliHost -CliArgs @('-Action','detach-session','-TaskId',$priorityId,'-SessionId','priority-sid','-ExpectedRevision','5','-TasksDir',$tasks,'-FlagsPath',$flags)
    $priorityAfterStep3=Get-OrchestrationTask -TaskId $priorityId -TasksDir $tasks
    # After the explicit detach, BOTH runs match the same SessionId and are
    # detached. Preserve I2: no-RunId resolution is ambiguous, not unique.
    $priorityStep3Ok=($priorityStep3 -eq 2 -and $priorityAfterStep3.revision -eq 5)
    Check ($priorityStep1 -and $priorityStep2Ok -and $priorityStep3Ok) ('{0} attached priority, explicit detach, then detached ambiguity per I2' -f $suffix)

    $detachedId='p32-d-cli-'+$suffix
    $null=New-OrchestrationTask -TaskId $detachedId -Objective ('detached resolver '+$suffix) -Actor 'planner' -TasksDir $tasks -FlagsPath $flags
    $null=Bind-OrchestrationTaskSession -TaskId $detachedId -RunId 'detached-a' -SessionId 'shared-sid' -ExpectedRevision 1 -TasksDir $tasks -FlagsPath $flags
    $null=Detach-OrchestrationTaskSession -TaskId $detachedId -RunId 'detached-a' -SessionId 'shared-sid' -ExpectedRevision 2 -TasksDir $tasks -FlagsPath $flags
    $detachedCli=Invoke-CLI -HostExe $cliHost -CliArgs @('-Action','detach-session','-TaskId',$detachedId,'-SessionId','shared-sid','-ExpectedRevision','3','-TasksDir',$tasks,'-FlagsPath',$flags)
    $null=Bind-OrchestrationTaskSession -TaskId $detachedId -RunId 'detached-b' -SessionId 'shared-sid' -ExpectedRevision 3 -TasksDir $tasks -FlagsPath $flags
    $null=Detach-OrchestrationTaskSession -TaskId $detachedId -RunId 'detached-b' -SessionId 'shared-sid' -ExpectedRevision 4 -TasksDir $tasks -FlagsPath $flags
    $ambiguousCli=Invoke-CLI -HostExe $cliHost -CliArgs @('-Action','detach-session','-TaskId',$detachedId,'-SessionId','shared-sid','-ExpectedRevision','5','-TasksDir',$tasks,'-FlagsPath',$flags)
    Write-Host ("[ENGINE] {0} CLI exit codes: priority={1}, detached={2}, ambiguous={3}" -f $cliHost,$priorityCli,$detachedCli,$ambiguousCli)
    Check ($detachedCli -eq 0 -and $ambiguousCli -eq 2) ('{0} CLI resolves detached unique and rejects ambiguous' -f $suffix)
  }
} finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host ("[SUMMARY] passed={0} failed={1}" -f $passed,$failed)
if($failed -gt 0){exit 1};exit 0
