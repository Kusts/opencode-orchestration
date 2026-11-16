<#!
.SYNOPSIS
    Testes de entrega de evento a uma Task (M6, #183).
.DESCRIPTION
    Task Kernel real com TasksDir temporario; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')

$script:passed = 0
$script:failed = 0
function Assert-TE {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$flags = Join-Path $repo 'source\registry\capability-flags.json'
$tmp = Join-Path $env:TEMP ('oo-task-event-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env1 = '{"source":"github","trigger":"issue_comment","thread":"pr:123","delivery_id":"d-1234","repo":"Kusts/opencode-orchestration","summary":"comentario pertinente"}'
$env2 = '{"source":"github","trigger":"issue_comment","thread":"pr:123","delivery_id":"d-5678","repo":"Kusts/opencode-orchestration","summary":"segundo comentario"}'
try {
    $c = New-OrchestrationTask -TaskId 'task-event-1' -Objective 'receber evento' -TaskType 'validation' -Risk 'low' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -Actor 'planner' -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$c.ok) '[TE1] task criada' ([string]$c.error)

    $a = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson $env1 -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$a.ok -and -not [bool]$a.duplicate) '[TE2] evento entregue' ([string]$a.error)
    $t = Get-OrchestrationTask -TaskId 'task-event-1' -TasksDir $tmp -RepoRoot $repo
    $inbox = @($t['event_inbox'])
    Assert-TE (($inbox.Count -eq 1) -and ([string]$inbox[0]['thread'] -ceq 'pr:123')) '[TE2] inbox tem o evento' ([string]$inbox.Count)

    $dup = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson $env1 -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$dup.ok -and [bool]$dup.duplicate -and ([int]$dup.revision -eq 2)) '[TE3] reentrega idempotente' ([string]$dup.duplicate)
    $t2 = Get-OrchestrationTask -TaskId 'task-event-1' -TasksDir $tmp -RepoRoot $repo
    Assert-TE ((@($t2['event_inbox']).Count -eq 1)) '[TE3] inbox nao duplica' ([string](@($t2['event_inbox']).Count))

    $b = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson $env2 -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$b.ok -and -not [bool]$b.duplicate) '[TE4] segundo evento distinto aceito' ([string]$b.error)
    $t3 = Get-OrchestrationTask -TaskId 'task-event-1' -TasksDir $tmp -RepoRoot $repo
    Assert-TE ((@($t3['event_inbox']).Count -eq 2)) '[TE4] inbox com dois eventos' ([string](@($t3['event_inbox']).Count))

    $bad = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson 'nao-e-json' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'EVENT_INVALID_JSON')) '[TE5] JSON invalido recusado' ([string]$bad.error)
    $badSource = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson '{"source":"gitlab","trigger":"issue_comment","thread":"pr:1","delivery_id":"d-1","repo":"a/b"}' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ((-not [bool]$badSource.ok) -and ([string]$badSource.error -ceq 'EVENT_SOURCE_UNSUPPORTED')) '[TE6] fonte invalida recusada' ([string]$badSource.error)

    $cas = Add-OrchestrationTaskEvent -TaskId 'task-event-1' -EnvelopeJson $env2 -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ((-not [bool]$cas.ok) -and ([string]$cas.error -ceq 'CAS_CONFLICT')) '[TE7] CAS conflict recusado' ([string]$cas.error)

    $c2 = New-OrchestrationTask -TaskId 'task-event-2' -Objective 'task terminal' -TaskType 'validation' -Risk 'low' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -Actor 'planner' -TasksDir $tmp -FlagsPath $flags
    $cancel = Cancel-OrchestrationTask -TaskId 'task-event-2' -Actor 'planner' -Reason 'teste' -ExpectedRevision 1 -ActorIdentitySource 'explicit-cli' -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$cancel.ok) '[TE8] task cancelada' ([string]$cancel.error)
    $term = Add-OrchestrationTaskEvent -TaskId 'task-event-2' -EnvelopeJson $env1 -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    Assert-TE ((-not [bool]$term.ok) -and ([string]$term.error -ceq 'ILLEGAL_TRANSITION')) '[TE8] task terminal recusada' ([string]$term.error)

    $info = '{"source":"github","trigger":"issue_comment","thread":"issue:55","delivery_id":"d-info1","repo":"Kusts/opencode-orchestration","informational_only":true,"summary":"FYI"}'
    $ic = New-OrchestrationTask -TaskId 'task-event-info' -Objective 'informativo' -TaskType 'validation' -Risk 'low' -Actor 'planner' -TasksDir $tmp -FlagsPath $flags
    $ia = Add-OrchestrationTaskEvent -TaskId 'task-event-info' -EnvelopeJson $info -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    $key = [string]$ia.dedup_key
    $ack = Confirm-OrchestrationTaskEvent -TaskId 'task-event-info' -DedupKey $key -SessionId 'ses-info' -ExpectedRevision 2 -ContextOnly -TasksDir $tmp -FlagsPath $flags
    $ackTask = Get-OrchestrationTask -TaskId 'task-event-info' -TasksDir $tmp
    Assert-TE ([bool]$ack.ok -and [string]$ackTask['event_inbox'][0]['ack_kind'] -ceq 'context_only') '[TE9] ack context-only informativo'
    $ackDup = Confirm-OrchestrationTaskEvent -TaskId 'task-event-info' -DedupKey $key -SessionId 'ses-info' -ExpectedRevision 3 -ContextOnly -TasksDir $tmp -FlagsPath $flags
    Assert-TE ([bool]$ackDup.duplicate -and [int]$ackDup.revision -eq 3) '[TE9] segundo ack context-only idempotente'
    $responseAck = Confirm-OrchestrationTaskEvent -TaskId 'task-event-1' -DedupKey ([string]$a.dedup_key) -SessionId 'ses-act' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    $denied = Confirm-OrchestrationTaskEvent -TaskId 'task-event-1' -DedupKey ([string]$a.dedup_key) -SessionId 'ses-act' -ExpectedRevision 4 -ContextOnly -TasksDir $tmp -FlagsPath $flags
    $unchanged = Get-OrchestrationTask -TaskId 'task-event-1' -TasksDir $tmp
    Assert-TE ([bool]$responseAck.ok -and [string]$unchanged['event_inbox'][0]['ack_kind'] -ceq 'response') '[TE9] ack acionavel registra response'
    Assert-TE ([string]$denied.error -ceq 'EVENT_CONTEXT_ONLY_NOT_ALLOWED' -and [int]$unchanged.revision -eq 4) '[TE9] context-only retry de ack response recusado sem revision'
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('TASK-EVENT: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
