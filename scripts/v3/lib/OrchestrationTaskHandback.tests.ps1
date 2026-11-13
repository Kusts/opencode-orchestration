<#
.SYNOPSIS
    Tests bounded task handback and conversation ownership release.
.DESCRIPTION
    Uses a GUID-scoped temporary TasksDir. PowerShell 5.1 compatible, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
$script:passed=0; $script:failed=0
function Assert-HB([bool]$Condition,[string]$Name) { if($Condition){$script:passed++}else{$script:failed++;Write-Host ('[FAIL] '+$Name)} }
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$flags=Join-Path $repo 'source\registry\capability-flags.json'
$tmp=Join-Path $env:TEMP ('oo-handback-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $c=New-OrchestrationTask -TaskId 'task-handback-1' -Objective 'handback' -Actor 'planner' -Risk low -TaskType validation -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$c.ok) 'create'
    $unbound=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-unbound' -Summary 'summary' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($unbound.error -ceq 'HANDBACK_SESSION_NOT_BOUND') 'unbound rejected'
    $bind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-1' -RunId 'run-1' -SessionId 'ses-root' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$bind.ok) 'session bound'
    $hb=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'done' -NextSteps 'continue' -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB ([bool]$hb.ok -and [int]$hb.revision -eq 3 -and $t['handback']['summary'] -ceq 'done' -and $t['handback']['next_steps'] -ceq 'continue') 'persist summary and next steps'
    Assert-HB ($t['bindings']['active_execution_owner'] -ceq '') 'owner released'
    $dup=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'done' -NextSteps 'continue' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$dup.duplicate -and [int]$dup.revision -eq 3) 'idempotent'
    $revision=3
    for($i=0;$i -lt 7;$i++){ $x=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary ('summary-'+$i) -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags; if($x.ok){$revision=[int]$x.revision} }
    $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB (@($t['handback_history']).Count -eq 5) 'history capped at five'
    $empty=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary ' ' -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($empty.error -ceq 'HANDBACK_SUMMARY_REQUIRED') 'empty summary'
    $large=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary ('x'*1001) -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($large.error -ceq 'HANDBACK_CONTENT_TOO_LARGE') 'summary bound'
    $largeNext=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'valid' -NextSteps ('x'*1001) -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($largeNext.error -ceq 'HANDBACK_CONTENT_TOO_LARGE') 'next steps bound'
    $badkey=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'valid' -DedupKey 'bad' -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($badkey.error -ceq 'EVENT_DEDUP_KEY_INVALID') 'bad dedup key'
    $missing=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'valid' -DedupKey ('a'*64) -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($missing.error -ceq 'EVENT_NOT_FOUND') 'missing event key'
    $evt=Add-OrchestrationTaskEvent -TaskId 'task-handback-1' -EnvelopeJson '{"source":"github","trigger":"issue_comment","thread":"issue:2","delivery_id":"d-hb1","repo":"Kusts/opencode-orchestration"}' -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    $revision=[int]$evt.revision
    $valid=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'event ref' -DedupKey $evt.dedup_key -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB ([bool]$valid.ok -and [string]$t['handback']['dedup_key'] -ceq [string]$evt.dedup_key) 'valid event reference'
    $cas=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'stale' -ExpectedRevision 0 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($cas.error -ceq 'CAS_CONFLICT') 'CAS conflict'
    $cancel=Cancel-OrchestrationTask -TaskId 'task-handback-1' -Actor planner -Reason done -ExpectedRevision ([int]$valid.revision) -ActorIdentitySource explicit-cli -TasksDir $tmp -FlagsPath $flags
    $terminal=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'late' -ExpectedRevision ([int]$cancel.revision) -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$cancel.ok -and $terminal.error -ceq 'ILLEGAL_TRANSITION') 'terminal rejected'
} finally { if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue} }
Write-Host ('TASK-HANDBACK: '+$script:passed+' passed / '+$script:failed+' failed')
if($script:failed -gt 0){exit 1}; exit 0
