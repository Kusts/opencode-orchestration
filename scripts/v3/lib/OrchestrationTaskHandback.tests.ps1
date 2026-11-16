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
    $revision=[int]$valid.revision
    $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB ([bool]$valid.ok -and [string]$t['handback']['dedup_key'] -ceq [string]$evt.dedup_key) 'valid event reference'
    $badContext=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'context' -ExpectedRevision $revision -ContextOnly -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($badContext.error -ceq 'HANDBACK_CONTEXT_ONLY_REQUIRES_EVENT') 'context only requires event'
    $actionableContext=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'context' -DedupKey $evt.dedup_key -ExpectedRevision $revision -ContextOnly -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($actionableContext.error -ceq 'EVENT_CONTEXT_ONLY_NOT_ALLOWED' -and [int](Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp).revision -eq $revision) 'actionable context rejected without write'
    $trimmed=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'trim' -NextSteps '  next  ' -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    $revision=[int]$trimmed.revision; $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB ([bool]$trimmed.ok -and $t['handback']['next_steps'] -ceq 'next') 'next steps trimmed'

    $info=Add-OrchestrationTaskEvent -TaskId 'task-handback-1' -EnvelopeJson '{"source":"github","trigger":"issue_comment","thread":"issue:3","delivery_id":"d-hb2","repo":"Kusts/opencode-orchestration","informational_only":true}' -ExpectedRevision $revision -TasksDir $tmp -FlagsPath $flags
    $revision=[int]$info.revision
    $contextOk=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'context' -DedupKey $info.dedup_key -ExpectedRevision $revision -ContextOnly -TasksDir $tmp -FlagsPath $flags
    $revision=[int]$contextOk.revision
    $t=Get-OrchestrationTask -TaskId 'task-handback-1' -TasksDir $tmp
    Assert-HB ([bool]$contextOk.ok -and [bool]$t['handback']['context_only']) 'informational context-only persists'

    $legacy=New-OrchestrationTask -TaskId 'task-handback-legacy' -Objective 'legacy handback' -Actor planner -TasksDir $tmp -FlagsPath $flags
    $legacyBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-legacy' -RunId 'run-legacy' -SessionId 'ses-legacy' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $legacyPath=Join-Path $tmp 'task-handback-legacy.json'; $legacyDoc=[IO.File]::ReadAllText($legacyPath) | ConvertFrom-Json
    $legacyDoc.PSObject.Properties.Remove('handback'); $legacyDoc.PSObject.Properties.Remove('handback_history')
    [IO.File]::WriteAllText($legacyPath,($legacyDoc | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $legacyResult=Set-OrchestrationTaskHandback -TaskId 'task-handback-legacy' -SessionId 'ses-legacy' -Summary 'legacy' -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    $legacyRead=Get-OrchestrationTask -TaskId 'task-handback-legacy' -TasksDir $tmp
    Assert-HB ([bool]$legacyBind.ok -and [bool]$legacyResult.ok -and @($legacyRead['handback_history']).Count -eq 1 -and $null -ne $legacyRead['handback_history'][0] -and $legacyRead['handback_history'][0]['session_id'] -ceq 'ses-legacy') 'legacy handback history has one non-null entry'

    $workerTask=New-OrchestrationTask -TaskId 'task-handback-worker' -Objective 'worker bind' -Actor planner -TasksDir $tmp -FlagsPath $flags
    $workerRoot=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-worker' -RunId 'run-worker' -SessionId 'ses-root' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $workerBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-worker' -RunId 'run-worker' -SessionId 'ses-worker' -ParentId 'ses-root' -ExpectedRevision 2 -WorkerSession -TasksDir $tmp -FlagsPath $flags
    $workerPath=Join-Path $tmp 'task-handback-worker.json'; $workerDoc=[IO.File]::ReadAllText($workerPath) | ConvertFrom-Json
    $workerDoc.bindings.active_execution_owner='ses-owner'; [IO.File]::WriteAllText($workerPath,($workerDoc | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $workerHandback=Set-OrchestrationTaskHandback -TaskId 'task-handback-worker' -SessionId 'ses-worker' -Summary 'worker' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    $workerState=Get-OrchestrationTask -TaskId 'task-handback-worker' -TasksDir $tmp
    Assert-HB ([bool]$workerTask.ok -and [bool]$workerRoot.ok -and [bool]$workerBind.ok -and
        [bool]$workerHandback.ok -and $workerState['bindings']['active_execution_owner'] -ceq 'ses-owner') 'worker handback leaves injected other owner intact'

    $workerOwnerTask=New-OrchestrationTask -TaskId 'task-handback-worker-owner' -Objective 'worker owner release' -Actor planner -TasksDir $tmp -FlagsPath $flags
    $workerOwnerRoot=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-worker-owner' -RunId 'run-worker-owner' -SessionId 'ses-root-owner' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $workerOwnerBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-worker-owner' -RunId 'run-worker-owner' -SessionId 'ses-worker-owner' -ParentId 'ses-root-owner' -ExpectedRevision 2 -WorkerSession -TasksDir $tmp -FlagsPath $flags
    $workerOwnerPath=Join-Path $tmp 'task-handback-worker-owner.json'
    $workerOwnerDoc=[IO.File]::ReadAllText($workerOwnerPath) | ConvertFrom-Json
    $workerOwnerDoc.bindings.active_execution_owner='ses-worker-owner'
    [IO.File]::WriteAllText($workerOwnerPath,($workerOwnerDoc | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $workerOwnerHandback=Set-OrchestrationTaskHandback -TaskId 'task-handback-worker-owner' -SessionId 'ses-worker-owner' -Summary 'worker owner' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    $workerOwnerState=Get-OrchestrationTask -TaskId 'task-handback-worker-owner' -TasksDir $tmp
    Assert-HB ([bool]$workerOwnerRoot.ok -and [bool]$workerOwnerBind.ok -and
        [bool]$workerOwnerHandback.ok -and $workerOwnerState['bindings']['active_execution_owner'] -ceq '') 'injected worker owner handback releases ownership'

    $detachedTask=New-OrchestrationTask -TaskId 'task-handback-detached' -Objective 'detached bind' -Actor planner -TasksDir $tmp -FlagsPath $flags
    $detachedBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-detached' -RunId 'run-detached' -SessionId 'ses-detached' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $detach=Detach-OrchestrationTaskSession -TaskId 'task-handback-detached' -RunId 'run-detached' -SessionId 'ses-detached' -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    $detachedHandback=Set-OrchestrationTaskHandback -TaskId 'task-handback-detached' -SessionId 'ses-detached' -Summary 'not allowed' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$detachedBind.ok -and [bool]$detach.ok -and $detachedHandback.error -ceq 'HANDBACK_SESSION_NOT_BOUND') 'detached session rejected'

    $cliTask=New-OrchestrationTask -TaskId 'task-handback-cli' -Objective 'handback CLI' -Actor planner -TasksDir $tmp -FlagsPath $flags
    $cliBind=Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'task-handback-cli' -RunId 'run-cli' -SessionId 'ses-cli' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $cli=Join-Path (Split-Path -Parent $PSScriptRoot) 'task-kernel.ps1'
    $cliHost='powershell.exe'; if($PSVersionTable.PSEdition -eq 'Core'){$cliHost='pwsh.exe'}
    function Invoke-HBCLI([string[]]$CliArgs) {
        $quoted=@($CliArgs | ForEach-Object { if($_ -match '\s'){ '"'+$_+'"' } else { $_ } }) -join ' '
        $outFile=Join-Path $tmp ('cli-'+[guid]::NewGuid().ToString('N')+'.out')
        $proc=Start-Process -FilePath (Get-Command $cliHost).Source -ArgumentList (('-NoProfile -File "{0}" ' -f $cli)+$quoted) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile
        $stdout=''; if(Test-Path $outFile){$stdout=[IO.File]::ReadAllText($outFile)}
        return @{code=[int]($proc.ExitCode -band 0xffff);stdout=$stdout}
    }
    $cliBase=@('-Action','handback','-TaskId','task-handback-cli','-SessionId','ses-cli','-TasksDir',$tmp,'-FlagsPath',$flags)
    $cliSuccess=Invoke-HBCLI ($cliBase+@('-Summary','ok','-ExpectedRevision','2'))
    $cliDuplicate=Invoke-HBCLI ($cliBase+@('-Summary','ok','-ExpectedRevision','3'))
    $cliUsage=Invoke-HBCLI ($cliBase+@('-ExpectedRevision','3'))
    $cliCas=Invoke-HBCLI ($cliBase+@('-Summary','stale','-ExpectedRevision','1'))
    Assert-HB ([bool]$cliBind.ok -and $cliSuccess.code -eq 0 -and $cliDuplicate.code -eq 0 -and $cliDuplicate.stdout -match '"duplicate":\s*true' -and $cliUsage.code -eq 2 -and $cliCas.code -eq 3) 'CLI exit codes and duplicate result'
    $cas=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'stale' -ExpectedRevision 0 -TasksDir $tmp -FlagsPath $flags
    Assert-HB ($cas.error -ceq 'CAS_CONFLICT') 'CAS conflict'
    $cancel=Cancel-OrchestrationTask -TaskId 'task-handback-1' -Actor planner -Reason done -ExpectedRevision $revision -ActorIdentitySource explicit-cli -TasksDir $tmp -FlagsPath $flags
    $terminal=Set-OrchestrationTaskHandback -TaskId 'task-handback-1' -SessionId 'ses-root' -Summary 'late' -ExpectedRevision ([int]$cancel.revision) -TasksDir $tmp -FlagsPath $flags
    Assert-HB ([bool]$cancel.ok -and $terminal.error -ceq 'ILLEGAL_TRANSITION') 'terminal rejected'
} finally { if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue} }
Write-Host ('TASK-HANDBACK: '+$script:passed+' passed / '+$script:failed+' failed')
if($script:failed -gt 0){exit 1}; exit 0
