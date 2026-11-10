<#!
.SYNOPSIS
    Testes da virtualizacao de observacoes (M4, issue #12).
.DESCRIPTION
    Sem rede e sem modelo: store temporario, IO real. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationObservationVirtualization.ps1')

$script:passed = 0
$script:failed = 0
function Assert-OV {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

$tmp = Join-Path $env:TEMP ('oo-observation-' + [guid]::NewGuid().ToString('N'))
$store = Join-Path $tmp 'store'
New-Item -ItemType Directory -Path $store -Force | Out-Null

try {
    $longText = ('linha com acento: evidência completa; ' * 120)
    $v = New-OrchestrationVirtualizedObservation -Content $longText -StoreDir $store -Kind 'tool-output' -TaskId 'task-ov-1' -PreviewChars 200
    Assert-OV ([bool]$v.ok) '[OV1] virtualiza observacao longa' ([string]$v.error)
    Assert-OV ([bool]$v.truncated) '[OV1] marca truncamento' ''
    Assert-OV (([int]$v.preview.Length -eq 200)) '[OV1] preview limitado a 200 chars' ([string]$v.preview.Length)
    Assert-OV (([string]$v.artifact_ref.sha256 -cmatch '^[0-9a-f]{64}$')) '[OV1] ref tem sha256' ([string]$v.artifact_ref.sha256)
    Assert-OV (([int]$v.artifact_ref.bytes -gt 0)) '[OV1] ref registra bytes' ([string]$v.artifact_ref.bytes)

    $read = Read-OrchestrationArtifactRef -Path ([string]$v.artifact_ref.path) -ExpectedSha256 ([string]$v.artifact_ref.sha256) -StoreDir $store
    Assert-OV ([bool]$read.ok) '[OV2] recall exato funciona' ([string]$read.error)
    Assert-OV (([string]$read.content -ceq $longText)) '[OV2] conteudo integral identico (UTF-8)' ''

    $again = New-OrchestrationArtifactRef -Content $longText -StoreDir $store -Kind 'tool-output'
    Assert-OV ([bool]$again.ok) '[OV3] reescrita idempotente' ([string]$again.error)
    Assert-OV ((-not [bool]$again.created)) '[OV3] segundo write nao recria' ([string]$again.created)
    Assert-OV (([string]$again.sha256 -ceq [string]$v.artifact_ref.sha256)) '[OV3] mesmo artifact id' ''

    $small = New-OrchestrationVirtualizedObservation -Content 'curto' -StoreDir $store -Kind 'other' -PreviewChars 200
    Assert-OV ([bool]$small.ok -and (-not [bool]$small.truncated)) '[OV4] conteudo curto nao trunca' ''
    Assert-OV (([string]$small.preview -ceq 'curto')) '[OV4] preview integral' ([string]$small.preview)

    $tooBig = New-OrchestrationArtifactRef -Content ('x' * 100) -StoreDir $store -Kind 'other' -MaxBytes 10
    Assert-OV ((-not [bool]$tooBig.ok) -and ([string]$tooBig.error -ceq 'ARTIFACT_TOO_LARGE')) '[OV5] limite de tamanho falha fechado' ([string]$tooBig.error)

    $badKind = New-OrchestrationArtifactRef -Content 'x' -StoreDir $store -Kind 'unknown-kind'
    Assert-OV ((-not [bool]$badKind.ok) -and ([string]$badKind.error -ceq 'ARTIFACT_KIND_INVALID')) '[OV6] kind invalido recusado' ([string]$badKind.error)

    $noStore = New-OrchestrationArtifactRef -Content 'x' -StoreDir ''
    Assert-OV ((-not [bool]$noStore.ok) -and ([string]$noStore.error -ceq 'ARTIFACT_STORE_REQUIRED')) '[OV7] store obrigatorio' ([string]$noStore.error)

    $missing = Read-OrchestrationArtifactRef -Path (Join-Path $store 'other\nao-existe.txt') -ExpectedSha256 ('0' * 64) -StoreDir $store
    Assert-OV ((-not [bool]$missing.ok) -and ([string]$missing.error -ceq 'ARTIFACT_NOT_FOUND')) '[OV8] arquivo ausente falha fechado' ([string]$missing.error)

    $outside = Join-Path $tmp 'outside.txt'
    [IO.File]::WriteAllText($outside, 'fora do store')
    $esc = Read-OrchestrationArtifactRef -Path $outside -ExpectedSha256 ('0' * 64) -StoreDir $store
    Assert-OV ((-not [bool]$esc.ok) -and ([string]$esc.error -ceq 'ARTIFACT_PATH_ESCAPE')) '[OV9] leitura fora do store recusada' ([string]$esc.error)

    $tampered = [string]$v.artifact_ref.path
    [IO.File]::WriteAllText($tampered, 'conteudo adulterado')
    $bad = Read-OrchestrationArtifactRef -Path $tampered -ExpectedSha256 ([string]$v.artifact_ref.sha256) -StoreDir $store
    Assert-OV ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'ARTIFACT_HASH_MISMATCH')) '[OV10] adulteracao detectada por hash' ([string]$bad.error)
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('OBSERVATION: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
