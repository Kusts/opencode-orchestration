<#!
.SYNOPSIS
    Testes da ponte GH-WAKE -> intake -> Kernel (M6, #183/#185).
.DESCRIPTION
    TasksDir temporario; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')
$bridge = Join-Path $PSScriptRoot 'github-event-bridge.ps1'
$script:passed = 0
$script:failed = 0
function Assert-EB {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$flags = Join-Path $repo 'source\registry\capability-flags.json'
$tmp = Join-Path $env:TEMP ('oo-event-bridge-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$u = New-Object System.Text.UTF8Encoding($false)
function Write-Fixture([string]$Name, [string]$Text) { $p = Join-Path $tmp $Name; [IO.File]::WriteAllText($p, $Text, $u); return $p }
$envFile = Write-Fixture 'e.json' '{"source":"github","trigger":"issue_comment","thread":"pr:123","delivery_id":"d-1234","repo":"Kusts/opencode-orchestration","summary":"comentario"}'
$routesFile = Write-Fixture 'r.json' '[{"task_id":"task-bridge-1","thread":"pr:123","state":"IMPLEMENTING"}]'
$seen = Join-Path $tmp 'seen.txt'
function Invoke-Bridge([string[]]$Extra) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $bridge @Extra 2>&1
    $code = $LASTEXITCODE
    $doc = $null
    try { $doc = (($out -join "`n") | ConvertFrom-Json) } catch { $doc = $null }
    return @{ code = $code; doc = $doc; raw = ($out -join "`n") }
}
try {
    $c = New-OrchestrationTask -TaskId 'task-bridge-1' -Objective 'receber evento via bridge' -TaskType 'validation' -Risk 'low' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -Actor 'planner' -TasksDir $tmp -FlagsPath $flags
    Assert-EB ([bool]$c.ok) '[EB1] task criada' ([string]$c.error)

    $a = Invoke-Bridge @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-TasksDir', $tmp, '-FlagsPath', $flags)
    Assert-EB (($a.code -eq 0) -and ([string]$a.doc.route -ceq 'ATTACH') -and ([bool]$a.doc.delivered) -and (-not [bool]$a.doc.duplicate)) '[EB2] bridge entrega no Kernel' ([string]$a.raw)
    $t = Get-OrchestrationTask -TaskId 'task-bridge-1' -TasksDir $tmp -RepoRoot $repo
    Assert-EB ((@($t['event_inbox']).Count -eq 1)) '[EB2] inbox com 1 evento' ([string](@($t['event_inbox']).Count))

    $b = Invoke-Bridge @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-TasksDir', $tmp, '-FlagsPath', $flags)
    Assert-EB (($b.code -eq 0) -and ([bool]$b.doc.duplicate) -and ([int]$b.doc.revision -eq 2)) '[EB3] reentrega idempotente no Kernel' ([string]$b.raw)

    $c2 = Invoke-Bridge @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-SeenFile', $seen, '-Record', '-TasksDir', $tmp, '-FlagsPath', $flags)
    Assert-EB (($c2.code -eq 0) -and ([bool]$c2.doc.recorded)) '[EB4] ledger registra entrega' ([string]$c2.raw)
    $c3 = Invoke-Bridge @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-SeenFile', $seen, '-TasksDir', $tmp, '-FlagsPath', $flags)
    Assert-EB (($c3.code -eq 0) -and ([string]$c3.doc.route -ceq 'IGNORE')) '[EB5] entrega ja registrada e ignorada' ([string]$c3.raw)

    $key = [string]$t['event_inbox'][0]['dedup_key']
    $ack = Confirm-OrchestrationTaskEvent -TaskId 'task-bridge-1' -DedupKey $key -SessionId 'ses_0123456789abcdef' -ResponseSummary 'comentario lido pelo worker' -ExpectedRevision 2 -TasksDir $tmp -FlagsPath $flags
    Assert-EB ([bool]$ack.ok -and -not [bool]$ack.duplicate) '[EB6] ack de consumo/settlement' ([string]$ack.error)
    $t2 = Get-OrchestrationTask -TaskId 'task-bridge-1' -TasksDir $tmp -RepoRoot $repo
    Assert-EB ([bool]$t2['event_inbox'][0]['acknowledged']) '[EB6] evento marcado acknowledged' ''
    $ack2 = Confirm-OrchestrationTaskEvent -TaskId 'task-bridge-1' -DedupKey $key -SessionId 'ses_0123456789abcdef' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-EB ([bool]$ack2.ok -and [bool]$ack2.duplicate -and ([int]$ack2.revision -eq 3)) '[EB7] ack idempotente' ([string]$ack2.duplicate)
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('EVENT-BRIDGE: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0

