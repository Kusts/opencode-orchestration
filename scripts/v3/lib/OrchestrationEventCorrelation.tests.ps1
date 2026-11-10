<#!
.SYNOPSIS
    Testes de correlacao/dedup de eventos (M6, issues #183/#185).
.DESCRIPTION
    Funcoes puras; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventCorrelation.ps1')

$script:passed = 0
$script:failed = 0
function Assert-EV {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

try {
    $e = New-OrchestrationEventEnvelope -Source 'github' -Trigger 'issue_comment' -Thread 'pr:123' -DeliveryId 'delivery-abc-1' -Repo 'Kusts/opencode-orchestration' -Summary 'comentario pertinente'
    Assert-EV ([bool]$e.ok) '[EV1] envelope valido' ([string]$e.error)
    Assert-EV (([string]$e.dedup_key -cmatch '^[0-9a-f]{64}$')) '[EV1] dedup key sha256' ([string]$e.dedup_key)

    $routes = @(
        @{ task_id = 'task-a'; thread = 'pr:123'; state = 'IMPLEMENTING' },
        @{ task_id = 'task-b'; thread = 'pr:999'; state = 'IMPLEMENTING' }
    )
    $attach = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes $routes
    Assert-EV (([string]$attach.route -ceq 'ATTACH') -and ([string]$attach.task_id -ceq 'task-a')) '[EV2] thread com dono unico => ATTACH' ([string]$attach.route)

    $dup = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes $routes -SeenDeliveryKeys @([string]$e.dedup_key)
    Assert-EV (([string]$dup.route -ceq 'IGNORE') -and ([string]$dup.reason -ceq 'duplicate-delivery')) '[EV3] entrega duplicada => IGNORE' ([string]$dup.reason)

    $info = New-OrchestrationEventEnvelope -Source 'github' -Trigger 'issue_comment' -Thread 'pr:123' -DeliveryId 'delivery-info-2' -Repo 'Kusts/opencode-orchestration' -InformationalOnly $true
    $infoRoute = Resolve-OrchestrationEventRoute -Envelope $info -TaskRoutes $routes
    Assert-EV (([string]$infoRoute.route -ceq 'IGNORE') -and ([string]$infoRoute.reason -ceq 'informational-only')) '[EV4] informativo => IGNORE' ([string]$infoRoute.reason)

    $amb = @($routes) + @(@{ task_id = 'task-c'; thread = 'pr:123'; state = 'VALIDATING' })
    $ambRoute = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes $amb
    Assert-EV (([string]$ambRoute.route -ceq 'ESCALATE') -and ([string]$ambRoute.reason -ceq 'ambiguous-thread-owner')) '[EV5] dois donos => ESCALATE' ([string]$ambRoute.route)

    $done = @(@{ task_id = 'task-a'; thread = 'pr:123'; state = 'DONE' })
    $doneRoute = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes $done
    Assert-EV (([string]$doneRoute.route -ceq 'OBSERVE')) '[EV6] dono terminal nao recebe => OBSERVE' ([string]$doneRoute.route)

    $new = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes @() -AdmissionEnabled $true
    Assert-EV (([string]$new.route -ceq 'NEW_TASK') -and ([string]$new.reason -ceq 'admission-enabled')) '[EV7] admission ligada => NEW_TASK' ([string]$new.route)

    $observe = Resolve-OrchestrationEventRoute -Envelope $e -TaskRoutes @()
    Assert-EV (([string]$observe.route -ceq 'OBSERVE') -and ([string]$observe.reason -ceq 'admission-disabled')) '[EV8] admission desligada => OBSERVE' ([string]$observe.route)

    $badSource = New-OrchestrationEventEnvelope -Source 'gitlab' -Trigger 'issue_comment' -Thread 'pr:1' -DeliveryId 'd-1234' -Repo 'a/b'
    Assert-EV ((-not [bool]$badSource.ok) -and ([string]$badSource.error -ceq 'EVENT_SOURCE_UNSUPPORTED')) '[EV9] fonte fora do escopo recusada' ([string]$badSource.error)
    $badThread = New-OrchestrationEventEnvelope -Source 'github' -Trigger 'issue_comment' -Thread 'fora:1' -DeliveryId 'd-1234' -Repo 'a/b'
    Assert-EV ((-not [bool]$badThread.ok) -and ([string]$badThread.error -ceq 'EVENT_THREAD_INVALID')) '[EV9] thread invalido recusado' ([string]$badThread.error)
}
finally { }

Write-Host ''
Write-Host ('EVENT-CORRELATION: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
