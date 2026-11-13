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
 $path=Join-Path $tmp 'team-task.json'; $doc=[IO.File]::ReadAllText($path) | ConvertFrom-Json
 $doc.bindings.runs[0].worker_sessions=@('ses-worker'); [IO.File]::WriteAllText($path,($doc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 Assert-Team ([bool]($c.ok -and $b.ok)) 'create and bind'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.ok -and $x.revision -eq 3) 'coordinator adds bound member'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'member is not coordinator'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-unbound -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_NOT_BOUND') 'unbound rejected'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-root -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_INVALID') 'coordinator cannot be member'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role Coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_ROLE_INVALID') 'role case sensitive'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.duplicate -and $x.revision -eq 3) 'duplicate idempotent'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role tester -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_CONFLICT') 'role conflict'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-worker -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.ok -and $x.revision -eq 4) 'member can release self'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-worker -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.duplicate) 'repeat release idempotent'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-no-member -CoordinatorSessionId ses-worker -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_MEMBER_NOT_FOUND') 'missing member'
 $get=Get-OrchestrationTaskTeam -TaskId team-task -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($get.ok -and $get.revision -eq 4 -and $get.team.members[0].released_at) 'read does not bump revision and preserves history'
 $hb=Set-OrchestrationTaskHandback -TaskId team-task -SessionId ses-root -Summary done -ExpectedRevision 4 -TasksDir $tmp -FlagsPath $flags
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 5 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($hb.ok -and $x.ok -and $x.revision -eq 6) 'root fallback coordinator after handback'
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
 Assert-Team ($bulk.ok -and $bulkBind.ok) 'bulk task fixture created'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'worker cannot impersonate coordinator'
 $missingCoordinator=$false
 try { Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags | Out-Null }
 catch { $missingCoordinator=$true }
 Assert-Team $missingCoordinator 'library requires asserted coordinator'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-other -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'TEAM_NOT_COORDINATOR') 'unrelated worker cannot release member'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root -ExpectedRevision 6 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.ok -and $x.revision -eq 7) 'coordinator can release member'
 $cli=Join-Path $PSScriptRoot '..\task-kernel.ps1'
 $cliOut=& powershell -NoProfile -File $cli -Action team-add -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 7 -TasksDir $tmp -FlagsPath $flags
 $cliCode=$LASTEXITCODE
 Assert-Team ($cliCode -eq 0 -and ($cliOut -join '') -match '"ok"\s*:\s*true') 'CLI add succeeds with deterministic JSON'
 & powershell -NoProfile -File $cli -Action team-add -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 2) 'CLI requires coordinator argument'
 & powershell -NoProfile -File $cli -Action team-add -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-worker -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 1) 'CLI rejects invalid coordinator'
 & powershell -NoProfile -File $cli -Action team-add -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags | Out-Null
 Assert-Team ($LASTEXITCODE -eq 3) 'CLI maps CAS conflict'
 $cliOut=& powershell -NoProfile -File $cli -Action team-get -TaskId team-task -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($LASTEXITCODE -eq 0 -and ($cliOut -join '') -match '"revision"\s*:\s*8') 'CLI get is read-only'
 $terminalPath=Join-Path $tmp 'team-task.json'; $terminalDoc=[IO.File]::ReadAllText($terminalPath) | ConvertFrom-Json
 $terminalDoc.state='DONE'; [IO.File]::WriteAllText($terminalPath,($terminalDoc|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'ILLEGAL_TRANSITION') 'terminal add rejected'
 $x=Remove-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -CoordinatorSessionId ses-root -ExpectedRevision 8 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'ILLEGAL_TRANSITION') 'terminal remove rejected'
 $x=Add-OrchestrationTaskTeamMember -TaskId team-task -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'CAS_CONFLICT') 'CAS conflict'
 $x=Add-OrchestrationTaskTeamMember -TaskId missing -SessionId ses-worker -Role coder -RunId r1 -CoordinatorSessionId ses-root -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
 Assert-Team ($x.error -eq 'NOT_FOUND') 'task missing'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("passed=$script:passed failed=$script:failed")
if($script:failed -gt 0){exit 1}


