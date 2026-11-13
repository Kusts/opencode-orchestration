<#!
.SYNOPSIS
    Testes da intake de eventos GitHub (M6, #183/#185).
.DESCRIPTION
    Invoca o CLI com fixtures em arquivo; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'event-intake.ps1'
$script:passed = 0
$script:failed = 0
function Assert-EI {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}
$tmp = Join-Path $env:TEMP ('oo-event-intake-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$seen = Join-Path $tmp 'seen.txt'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Fixture([string]$Name, [string]$Text) {
    $p = Join-Path $tmp $Name
    [IO.File]::WriteAllText($p, $Text, $utf8)
    return $p
}
$envFile = Write-Fixture 'envelope.json' '{"source":"github","trigger":"issue_comment","thread":"pr:123","delivery_id":"d-1234","repo":"Kusts/opencode-orchestration"}'
$routesFile = Write-Fixture 'routes.json' '[{"task_id":"task-a","thread":"pr:123","state":"IMPLEMENTING"},{"task_id":"task-b","thread":"pr:999","state":"IMPLEMENTING"}]'
$infoFile = Write-Fixture 'info.json' '{"source":"github","trigger":"issue_comment","thread":"pr:123","delivery_id":"d-info","repo":"Kusts/opencode-orchestration","informational_only":true}'
$badFile = Write-Fixture 'bad.json' '{"source":"gitlab","trigger":"issue_comment","thread":"pr:1","delivery_id":"d-1","repo":"a/b"}'
function Invoke-Intake([string[]]$Extra) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script @Extra 2>&1
    $code = $LASTEXITCODE
    $doc = $null
    try { $doc = (($out -join "`n") | ConvertFrom-Json) } catch { $doc = $null }
    return @{ code = $code; doc = $doc; raw = ($out -join "`n") }
}
try {
    $a = Invoke-Intake @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile)
    Assert-EI (($a.code -eq 0) -and ([string]$a.doc.route -ceq 'ATTACH') -and ([string]$a.doc.task_id -ceq 'task-a')) '[EI1] thread com dono unico => ATTACH' ([string]$a.raw)

    $b = Invoke-Intake @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-SeenFile', $seen, '-Record')
    Assert-EI (($b.code -eq 0) -and ([bool]$b.doc.recorded)) '[EI2] primeira entrega registrada' ([string]$b.raw)
    $c = Invoke-Intake @('-EnvelopeFile', $envFile, '-RoutesFile', $routesFile, '-SeenFile', $seen)
    Assert-EI (($c.code -eq 0) -and ([string]$c.doc.route -ceq 'IGNORE') -and ([string]$c.doc.reason -ceq 'duplicate-delivery')) '[EI3] segunda entrega deduplicada' ([string]$c.raw)

    $d = Invoke-Intake @('-EnvelopeFile', $infoFile, '-RoutesFile', $routesFile)
    Assert-EI (([string]$d.doc.route -ceq 'IGNORE') -and ([string]$d.doc.reason -ceq 'informational-only')) '[EI4] informativo ignorado' ([string]$d.raw)

    $e = Invoke-Intake @('-EnvelopeFile', $envFile)
    Assert-EI ([string]$e.doc.route -ceq 'OBSERVE') '[EI5] sem dono e admission off => OBSERVE' ([string]$e.raw)
    $f = Invoke-Intake @('-EnvelopeFile', $envFile, '-AdmissionEnabled')
    Assert-EI ([string]$f.doc.route -ceq 'NEW_TASK') '[EI6] admission on => NEW_TASK' ([string]$f.raw)

    $g = Invoke-Intake @('-EnvelopeFile', $badFile)
    Assert-EI (($g.code -eq 1) -and ([string]$g.doc.error -ceq 'EVENT_SOURCE_UNSUPPORTED')) '[EI7] fonte invalida recusada' ([string]$g.raw)

    $h = Invoke-Intake @('-EnvelopeJson', '{}', '-EnvelopeFile', $envFile)
    Assert-EI (($h.code -eq 2) -and ([string]$h.doc.error -ceq 'ENVELOPE_INPUT_AMBIGUOUS')) '[EI8] entradas ambiguas recusadas' ([string]$h.raw)
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('EVENT-INTAKE: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
