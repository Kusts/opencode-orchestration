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

    Assert-EI ([string]$a.doc.signature_status -ceq 'not-configured') '[EI9] legacy explicito'
    $secretFile=Write-Fixture 'secret.txt' 'sk-SYNTHETICSECRET'
    $body=[IO.File]::ReadAllBytes($envFile)
    $key=[Text.Encoding]::UTF8.GetBytes('sk-SYNTHETICSECRET')
    $hm=New-Object -TypeName Security.Cryptography.HMACSHA256 -ArgumentList (,$key)
    $mac=([BitConverter]::ToString($hm.ComputeHash($body))).Replace('-','').ToLowerInvariant()
    $sig='sha256='+$mac
    $signed=Join-Path $tmp 'signed-seen';$v=Invoke-Intake @('-EnvelopeFile',$envFile,'-SecretFile',$secretFile,'-SignatureHeader',$sig,'-SeenFile',$signed,'-Record')
    Assert-EI (($v.code -eq 0) -and ($v.doc.signature_status -eq 'verified') -and $v.doc.recorded) '[EI10] HMAC valido'
    $beforeLedger=[IO.File]::ReadAllText($signed)
    $badSig=Invoke-Intake @('-EnvelopeFile',$envFile,'-SecretFile',$secretFile,'-SignatureHeader',('sha256='+('0'*64)),'-SeenFile',$signed,'-Record')
    Assert-EI (($badSig.code -eq 1) -and ([IO.File]::ReadAllText($signed) -ceq $beforeLedger)) '[EI11] HMAC invalido nao grava'
    $noSig=Invoke-Intake @('-EnvelopeFile',$envFile,'-SecretFile',$secretFile,'-SeenFile',$signed,'-Record')
    Assert-EI (($noSig.code -eq 1) -and ($noSig.doc.error -eq 'SIGNATURE_MISSING') -and ([IO.File]::ReadAllText($signed) -ceq $beforeLedger)) '[EI12] assinatura ausente nao grava'
    $jsonSig=Invoke-Intake @('-EnvelopeJson','{}','-SecretFile',$secretFile)
    Assert-EI (($jsonSig.code -eq 2) -and ($jsonSig.doc.error -eq 'SIGNATURE_REQUIRES_FILE')) '[EI13] JSON com segredo exige arquivo'
    $ignored=Invoke-Intake @('-EnvelopeFile',$envFile,'-SignatureHeader','ignored-header')
    Assert-EI (($ignored.code -eq 0) -and $ignored.doc.signature_header_ignored) '[EI14] header ignorado sinalizado'
    $missing=Invoke-Intake @('-EnvelopeFile',(Join-Path $tmp 'absent.json'),'-SecretFile',$secretFile)
    Assert-EI (($missing.code -eq 2) -and $missing.doc.error -eq 'ENVELOPE_REQUIRED') '[EI15] arquivo ausente com segredo'
    $large=Join-Path $tmp 'large.json';$stream=[IO.File]::OpenWrite($large)
    try {$stream.SetLength(65537)} finally {$stream.Dispose()}
    $tooLarge=Invoke-Intake @('-EnvelopeFile',$large,'-SecretFile',$secretFile,'-SignatureHeader',$sig)
    Assert-EI (($tooLarge.code -eq 1) -and $tooLarge.doc.error -eq 'EVENT_INPUT_TOO_LARGE') '[EI16] limite intake antes da leitura'
    $env:EI_TEST_SECRET="sk-SYNTHETICSECRET`n"
    $fromEnv=Invoke-Intake @('-EnvelopeFile',$envFile,'-SecretEnvVar','EI_TEST_SECRET','-SignatureHeader',$sig)
    Assert-EI (($fromEnv.code -eq 0) -and $fromEnv.doc.signature_status -eq 'verified') '[EI17] env secret trim'
    Remove-Item Env:EI_TEST_SECRET -ErrorAction SilentlyContinue
    $bomFile=Join-Path $tmp 'bom.json';$plain=[IO.File]::ReadAllBytes($envFile)
    $bomBytes=[byte[]]@(0xEF,0xBB,0xBF)+$plain;[IO.File]::WriteAllBytes($bomFile,$bomBytes)
    $bomKey=[Text.Encoding]::UTF8.GetBytes('sk-SYNTHETICSECRET')
    $bomMac=New-Object -TypeName Security.Cryptography.HMACSHA256 -ArgumentList (,$bomKey)
    $bomSig='sha256='+([BitConverter]::ToString($bomMac.ComputeHash($bomBytes))).Replace('-','').ToLowerInvariant()
    $bomResult=Invoke-Intake @('-EnvelopeFile',$bomFile,'-SecretFile',$secretFile,'-SignatureHeader',$bomSig)
    Assert-EI (($bomResult.code -eq 0) -and $bomResult.doc.ok -and
        $bomResult.doc.signature_status -eq 'verified') '[EI18] BOM assinado parseado'
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('EVENT-INTAKE: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
