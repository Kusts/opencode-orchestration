[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
$script:passed=0; $script:failed=0
function Assert-Team([bool]$Condition,[string]$Name) { if($Condition){$script:passed++}else{$script:failed++;Write-Host ('[FAIL] '+$Name)} }
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$flags=Join-Path $repo 'source\registry\capability-flags.json'
$tmp=Join-Path $env:TEMP ('oo-team-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
 $c=New-OrchestrationTask -TaskId 'team-task' -Objective 'team' -Actor planner -TasksDir $tmp -FlagsPath $flags
 $b=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-task -RunId r1 -SessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $wb=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-task -RunId r1 -SessionId ses-worker -ParentId ses-root -WorkerSession -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ([bool]($c.ok -and $b.ok -and $wb.ok -and $wb.bindings.active_execution_owner -eq 'ses-root')) 'normal root and worker bind'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.ok -and $x.revision -eq 4) 'coordinator adds bound member'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'member is not coordinator'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-unbound -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_NOT_BOUND') 'unbound rejected'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-root -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_INVALID') 'coordinator cannot be member'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role Coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_ROLE_INVALID') 'role case sensitive'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.duplicate -and $x.revision -eq 4 -and $null -ne $x.team) 'duplicate idempotent'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role tester -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_CONFLICT') 'role conflict'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-worker -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.ok -and $x.revision -eq 5) 'member can release self'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-worker -ExpectedRevision 5 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.duplicate -and $null -ne $x.team) 'repeat release idempotent'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-no-member -CoordinatorSessionId ses-root -ExpectedRevision 5 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_NOT_FOUND') 'missing member'
 $get=Get-OrchestrationTaskTeam -TaskId team-task -TasksDir $tmp -FlagsPath $flags
 $beforeGet=Get-OrchestrationTask -TaskId team-task -TasksDir $tmp
 $teamTimestamp=$get.team.updated_at
 $getAgain=Get-OrchestrationTaskTeam -TaskId team-task -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($get.ok -and $get.revision -eq 5 -and $get.team.members[0].released_at -and
    $beforeGet.updated_at -eq (Get-OrchestrationTask -TaskId team-task -TasksDir $tmp).updated_at -and
    $teamTimestamp -eq $getAgain.team.updated_at -and $getAgain.revision -eq 5) 'read leaves revision and updated_at unchanged'
 $hb=Set-OrchestrationTaskHandback -TaskId team-task -SessionId ses-root -Summary done -ExpectedRevision 5 -TasksDir $tmp -FlagsPath $flags
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($hb.ok -and $x.error -eq 'TEAM_NOT_COORDINATOR') 'handback clears coordinator without fallback'
  $rootDetach=Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId team-task -RunId r1 -SessionId ses-root -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags
  $root2=Invoke-OrchestrationTaskSessionBinding -Operation rebind -TaskId team-task -RunId r1 -SessionId ses-root2 -ExpectedRevision 7 -TasksDir $tmp -FlagsPath $flags
  $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root2 -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags
  Assert-Team ($rootDetach.ok -and $root2.ok -and $x.ok -and $x.revision -eq 9) 'explicit detach and rebind restores coordination'
 $bulk=New-OrchestrationTask -TaskId team-bulk -Objective bulk -Actor planner -TasksDir $tmp -FlagsPath $flags
 $bulkBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-bulk -RunId rb -SessionId ses-bulk-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $bulkPath=Join-Path $tmp 'team-bulk.json'; $bulkDoc=[IO.File]::ReadAllText($bulkPath) | ConvertFrom-Json
 $bulkDoc.bindings.runs[0].worker_sessions=@(1..9 | ForEach-Object { 'ses-bulk-'+$_ })
 [IO.File]::WriteAllText($bulkPath,($bulkDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $rev=2
 for($i=1;$i -le 8;$i++) {
   $x=Add-OrchestrationTaskTeamMember -TaskId team-bulk -SessionId ('ses-bulk-'+$i) -Role coder -RunId rb -CoordinatorSessionId ses-bulk-root -ExpectedRevision $rev -TasksDir $tmp -FlagsPath $flags
   if($x.ok){$rev=$x.revision}; Assert-Team ([bool]$x.ok) ('limit member '+$i)
 }
 $x=Add-OrchestrationTaskTeamMember -TaskId team-bulk -SessionId ses-bulk-9 -Role coder -RunId rb -CoordinatorSessionId ses-bulk-root -ExpectedRevision $rev -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_LIMIT_EXCEEDED') 'ninth active member refused'
 if($x.error -eq 'TEAM_LIMIT_EXCEEDED') {
   for($i=0;$i -lt 20;$i++) {
     $released=Remove-OrchestrationTaskTeamMember -TaskId team-bulk -SessionId ses-bulk-1 -CoordinatorSessionId ses-bulk-root -ExpectedRevision $rev -TasksDir $tmp -FlagsPath $flags
     if($released.ok){$rev=$released.revision}
     $readded=Add-OrchestrationTaskTeamMember -TaskId team-bulk -SessionId ses-bulk-1 -Role coder -RunId rb -CoordinatorSessionId ses-bulk-root -ExpectedRevision $rev -TasksDir $tmp -FlagsPath $flags
     if($readded.ok){$rev=$readded.revision}
   }
   $pruned=Get-OrchestrationTaskTeam -TaskId team-bulk -TasksDir $tmp -FlagsPath $flags
   $activeCount=@($pruned.team.members | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.released_at)}).Count
   Assert-Team ($activeCount -eq 8 -and @($pruned.team.members).Count -le 16) 'pruning preserves eight active entries and caps history'
 }
 Assert-Team ($bulk.ok -and $bulkBind.ok) 'bulk task fixture created'
 $ownerTask=New-OrchestrationTask -TaskId team-owner-check -Objective owner -Actor planner -TasksDir $tmp -FlagsPath $flags
 $ownerRoot=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-owner-check -RunId own-run -SessionId own-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $ownerBadParent=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-owner-check -RunId own-run -SessionId ses-w -ParentId wrong-root -WorkerSession -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 $ownerWorker=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-owner-check -RunId own-run -SessionId ses-w -ParentId own-root -WorkerSession -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 $ownerPath=Join-Path $tmp 'team-owner-check.json'; $ownerDoc=[IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
 $ownerDoc.bindings.active_execution_owner=''; [IO.File]::WriteAllText($ownerPath,($ownerDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $workerNoOwner=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-owner-check -RunId own-run -SessionId ses-w2 -WorkerSession -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($workerNoOwner.ok -and [string]::IsNullOrWhiteSpace($workerNoOwner.bindings.active_execution_owner)) 'worker bind never claims empty owner'
 $ownerDoc=[IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
 $ownerDoc.bindings.active_execution_owner='ses-w'; [IO.File]::WriteAllText($ownerPath,($ownerDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $workerOwner=Add-OrchestrationTaskTeamMember -TaskId team-owner-check -SessionId ses-w -Role coder -RunId own-run -CoordinatorSessionId ses-w -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($ownerTask.ok -and $ownerRoot.ok -and $ownerBadParent.error -eq 'BIND_PARENT_MISMATCH' -and
    $ownerWorker.ok -and $workerOwner.error -eq 'TEAM_NOT_COORDINATOR') 'worker parent gate and owner refusal'
 $detTask=New-OrchestrationTask -TaskId team-detached -Objective detached -Actor planner -TasksDir $tmp -FlagsPath $flags
 $detRoot=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-detached -RunId det-run -SessionId det-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $detached=Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId team-detached -RunId det-run -SessionId det-root -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 $detCoord=Add-OrchestrationTaskTeamMember -TaskId team-detached -SessionId det-root -Role coder -RunId det-run -CoordinatorSessionId det-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($detTask.ok -and $detRoot.ok -and $detached.ok -and $detCoord.error -eq 'TEAM_NOT_COORDINATOR') 'detached root cannot coordinate'
  $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker -ExpectedRevision 9 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'worker cannot impersonate coordinator'
 $missingCoordinator=$false
 try { Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags | Out-Null }
 catch { $missingCoordinator=$true }
 Assert-Team $missingCoordinator 'library requires asserted coordinator'
  $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-no-member -CoordinatorSessionId ses-other -ExpectedRevision 9 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'unrelated worker cannot release member'
  $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root2 -ExpectedRevision 9 -TasksDir $tmp -FlagsPath $flags
  Assert-Team ($x.ok -and $x.revision -eq 10) 'coordinator can release member'
 $cli=Join-Path $PSScriptRoot '..\task-kernel.ps1'
 $cliOut=& powershell -NoProfile -File $cli -Action team-add -TaskId team-task `
    -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root2 `
     -ExpectedRevision 10 -TasksDir $tmp -FlagsPath $flags
 $cliCode=$LASTEXITCODE
 Assert-Team ($cliCode -eq 0 -and ($cliOut -join '') -match '"ok"\s*:\s*true') 'CLI add succeeds with deterministic JSON'
 & powershell -NoProfile -File $cli -Action team-add -TaskId team-task `
      -SessionId ses-worker -Role coder -RunId r1 -ExpectedRevision 10 `
    -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 2) 'CLI requires coordinator argument'
 & powershell -NoProfile -File $cli -Action team-add -TaskId team-task `
     -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker `
      -ExpectedRevision 11 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 1) 'CLI rejects invalid coordinator'
  & powershell -NoProfile -File $cli -Action team-add -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root2 -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 3) 'CLI maps CAS conflict'
 $cliOut=& powershell -NoProfile -File $cli -Action team-get -TaskId team-task -TasksDir $tmp -FlagsPath $flags
   Assert-Team ($LASTEXITCODE -eq 0 -and ($cliOut -join '') -match '"revision"\s*:\s*11') 'CLI get is read-only'
   & powershell -NoProfile -File $cli -Action team-release -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root2 -ExpectedRevision 11 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 0) 'CLI release succeeds'
 $cliCreate=& powershell -NoProfile -File $cli -Action create -TaskId team-cli-flow -Objective flow -Actor planner -TasksDir $tmp -FlagsPath $flags
 $cliRoot=& powershell -NoProfile -File $cli -Action bind-session -TaskId team-cli-flow -RunId flow-run -SessionId flow-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $cliWorker=& powershell -NoProfile -File $cli -Action bind-session -TaskId team-cli-flow -RunId flow-run -SessionId flow-worker -ParentSessionId flow-root -WorkerSession -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 $cliTeam=& powershell -NoProfile -File $cli -Action team-add -TaskId team-cli-flow `
    -SessionId flow-worker -Role coder -RunId flow-run -CoordinatorSessionId flow-root `
    -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($LASTEXITCODE -eq 0 -and ($cliTeam -join '') -match '"ok"\s*:\s*true') 'pure CLI create-bind-worker-team flow'
 Assert-Team (($cliCreate -join '') -match '"ok"\s*:\s*true' -and ($cliRoot -join '') -match '"ok"\s*:\s*true' -and ($cliWorker -join '') -match '"ok"\s*:\s*true') 'CLI flow setup succeeds'
 $badRun=Add-OrchestrationTaskTeamMember -TaskId team-cli-flow -SessionId flow-worker -Role coder -RunId 'bad/run' -CoordinatorSessionId flow-root -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($badRun.error -eq 'BIND_INVALID_ID') 'RunId charset checked'
 $terminalPath=Join-Path $tmp 'team-task.json'; $terminalDoc=[IO.File]::ReadAllText($terminalPath) | ConvertFrom-Json
 $terminalDoc.state='DONE'; [IO.File]::WriteAllText($terminalPath,($terminalDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
  & powershell -NoProfile -File $cli -Action team-release -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root2 -ExpectedRevision 12 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 4) 'CLI terminal release maps illegal transition'
   $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root2 -ExpectedRevision 12 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'ILLEGAL_TRANSITION') 'terminal add rejected'
   $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root2 -ExpectedRevision 12 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'ILLEGAL_TRANSITION') 'terminal remove rejected'
 $badShape=New-OrchestrationTask -TaskId team-corrupt -Objective corrupt -Actor planner -TasksDir $tmp -FlagsPath $flags
 $badBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId team-corrupt -RunId corrupt-run -SessionId corrupt-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 $badPath=Join-Path $tmp 'team-corrupt.json'; $badDoc=[IO.File]::ReadAllText($badPath) | ConvertFrom-Json
 $badDoc | Add-Member -NotePropertyName team -NotePropertyValue 'invalid' -Force
 [IO.File]::WriteAllText($badPath,($badDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $badGet=Get-OrchestrationTaskTeam -TaskId team-corrupt -TasksDir $tmp -FlagsPath $flags
 $badMutation=Add-OrchestrationTaskTeamMember -TaskId team-corrupt -SessionId corrupt-root `
    -Role coder -RunId corrupt-run -CoordinatorSessionId corrupt-root `
    -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($badShape.ok -and $badBind.ok -and $badGet.error -eq 'MALFORMED' -and $badMutation.error -eq 'MALFORMED') 'corrupt team shape rejected on read and mutation'
 $badDoc | Add-Member -NotePropertyName team -NotePropertyValue ([ordered]@{members='not-array'}) -Force
 [IO.File]::WriteAllText($badPath,($badDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $badMembers=Get-OrchestrationTaskTeam -TaskId team-corrupt -TasksDir $tmp -FlagsPath $flags
 $badDoc.team=[ordered]@{members=@([ordered]@{role='coder'})}
 [IO.File]::WriteAllText($badPath,($badDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $badMember=Get-OrchestrationTaskTeam -TaskId team-corrupt -TasksDir $tmp -FlagsPath $flags
 $badDoc.team=[ordered]@{members=@([ordered]@{session_id='active-without-role'})}
 [IO.File]::WriteAllText($badPath,($badDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $badActive=Get-OrchestrationTaskTeam -TaskId team-corrupt -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($badMembers.error -eq 'MALFORMED' -and $badMember.error -eq 'MALFORMED' -and
    $badActive.error -eq 'MALFORMED') 'corrupt members and active role/run shape rejected'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'CAS_CONFLICT') 'CAS conflict'
 $x=Add-OrchestrationTaskTeamMember -TaskId missing -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'NOT_FOUND') 'task missing'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("passed=$script:passed failed=$script:failed")
if($script:failed -gt 0){exit 1}


