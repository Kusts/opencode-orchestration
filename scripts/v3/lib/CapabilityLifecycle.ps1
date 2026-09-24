<#!
.SYNOPSIS
    V3 Capability lifecycle: fingerprint deterministico e estado de reload do runtime.

.DESCRIPTION
    Biblioteca dot-sourceable, sem efeitos colaterais ao carregar.
    O fingerprint cobre os arquivos *.md do alvo (nome + sha256, ordem
    ordinal) e e retornado como "sha256:<HEX>". Get-FileSetFingerprint
    generaliza para qualquer conjunto de arquivos (ex.: o config alvo
    opencode.json alem dos .md); o apply do authority registra/baselina o
    config alvo junto com os .md.

    Modelo de estados (nenhum processo real e reiniciado aqui; o restart ou
    a nova instancia e passo documentado/manual do operador):
      - New-RuntimeBaseline registra o conjunto que o runtime carregou.
      - Get-RuntimeReloadStatus compara o disco atual com o baseline:
        RUNTIME_ACTIVE (igual), RUNTIME_RELOAD_REQUIRED (diferente),
        UNKNOWN (sem baseline ou baseline ilegivel).
      - Set-RuntimeReloadStatus registra DISK_APPLIED_RELOAD_REQUIRED apos
        um Apply: o disco mudou, entao o runtime so volta a RUNTIME_ACTIVE
        numa nova instancia que grave um novo baseline.
      - MODEL-ONLY: RUNTIME_ACTIVE SOMENTE com nova instancia declarada
        (New-RuntimeBaseline / New-FileSetBaseline); nunca inferido de
        escrita em disco. `state`/`status` sao informativos ate existir
        apply real.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Resolve-ReloadStorePath {
    <#
    .SYNOPSIS
        Resolve o caminho do reload-state.json (default: cache/v3/reload-state.json).
    #>
    [CmdletBinding()]
    param(
        [string]$StorePath
    )
    if (-not [string]::IsNullOrWhiteSpace($StorePath)) {
        return $StorePath
    }
    $v3Dir = Split-Path -Parent $PSScriptRoot
    $scriptsDir = Split-Path -Parent $v3Dir
    $repoRoot = Split-Path -Parent $scriptsDir
    return (Join-Path $repoRoot 'cache\v3\reload-state.json')
}

function Get-TargetFingerprint {
    <#
    .SYNOPSIS
        Fingerprint deterministico ("sha256:...") dos *.md do alvo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )
    $lines = @()
    if (Test-Path -LiteralPath $TargetRoot -PathType Container) {
        $names = @(
            Get-ChildItem -LiteralPath $TargetRoot -Filter '*.md' -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name }
        )
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
        foreach ($name in $names) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $TargetRoot $name) -Algorithm SHA256).Hash
            $lines += ($name + ':' + $hash)
        }
    }
    $joined = ($lines -join "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($digest | ForEach-Object { $_.ToString('X2') })
    return ('sha256:' + $hex)
}

function Get-FileSetFingerprint {
    <#
    .SYNOPSIS
        Fingerprint deterministico ("sha256:...") de um conjunto qualquer de
        arquivos (ex.: opencode.json alvo + .md). Linhas "nome:hash" ordenadas
        (ordinal); nomes relativos ao ancestral comum quando possivel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FilePaths
    )
    $lines = @()
    $sorted = @($FilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -CaseSensitive)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    foreach ($fp in $sorted) {
        if (Test-Path -LiteralPath $fp -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash
            $lines += ([string]$fp + ':' + ([string]$hash).ToLowerInvariant())
        }
        else {
            $lines += ([string]$fp + ':missing')
        }
    }
    $joined = ($lines -join "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    $hex = -join ($digest | ForEach-Object { $_.ToString('X2') })
    return ('sha256:' + $hex)
}

function New-FileSetBaseline {
    <#
    .SYNOPSIS
        Baseline declarado de um conjunto de arquivos (status RUNTIME_ACTIVE).
        RUNTIME_ACTIVE SOMENTE via baseline declarado (nova instancia); nunca
        inferido.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FilePaths,
        [string]$StorePath,
        [string]$TargetRoot
    )
    $resolved = Resolve-ReloadStorePath -StorePath $StorePath
    $record = [ordered]@{
        fingerprint     = (Get-FileSetFingerprint -FilePaths $FilePaths)
        status          = 'RUNTIME_ACTIVE'
        target_root     = $TargetRoot
        file_set        = @($FilePaths)
        recorded_at     = (Get-Date).ToString('o')
        declared_origin = 'new-instance-baseline'
    }
    Write-ReloadStateJson -Path $resolved -Value $record
    return $record
}

function Write-ReloadStateJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Value
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $text = (($Value | ConvertTo-Json -Depth 8) + "`n")
    $lf = ($text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-RuntimeBaseline {
    <#
    .SYNOPSIS
        Grava o baseline do conjunto que o runtime carregou (status RUNTIME_ACTIVE).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [string]$StorePath
    )
    $resolved = Resolve-ReloadStorePath -StorePath $StorePath
    $record = [ordered]@{
        fingerprint = (Get-TargetFingerprint -TargetRoot $TargetRoot)
        status      = 'RUNTIME_ACTIVE'
        target_root = $TargetRoot
        recorded_at = (Get-Date).ToString('o')
    }
    Write-ReloadStateJson -Path $resolved -Value $record
    return $record
}

function Get-RuntimeReloadStatus {
    <#
    .SYNOPSIS
        RUNTIME_ACTIVE, RUNTIME_RELOAD_REQUIRED ou UNKNOWN (sem baseline).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [string]$StorePath
    )
    $resolved = Resolve-ReloadStorePath -StorePath $StorePath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return 'UNKNOWN'
    }
    try {
        $stored = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    } catch {
        return 'UNKNOWN'
    }
    if ($null -eq $stored -or [string]::IsNullOrWhiteSpace([string]$stored.fingerprint)) {
        return 'UNKNOWN'
    }
    if ([string]$stored.status -ceq 'DISK_APPLIED_RELOAD_REQUIRED') {
        return 'RUNTIME_RELOAD_REQUIRED'
    }
    $current = Get-TargetFingerprint -TargetRoot $TargetRoot
    if ($current -ceq [string]$stored.fingerprint) {
        return 'RUNTIME_ACTIVE'
    }
    return 'RUNTIME_RELOAD_REQUIRED'
}

function Set-RuntimeReloadStatus {
    <#
    .SYNOPSIS
        Registra um status de reload (ex.: DISK_APPLIED_RELOAD_REQUIRED apos Apply).
    .DESCRIPTION
        Preserva o fingerprint do baseline existente (a visao do runtime nao
        muda com escrita em disco); se nao houver baseline, usa o fingerprint
        atual do disco. Nunca reinicia processos. RUNTIME_ACTIVE nunca e
        inferido aqui: somente New-RuntimeBaseline/New-FileSetBaseline
        (nova instancia declarada) registra RUNTIME_ACTIVE. Quando -ConfigPath
        e informado, o fingerprint/snapshot do config alvo e registrado junto
        (config_path/config_snapshot) alem dos .md.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('RUNTIME_ACTIVE', 'RUNTIME_RELOAD_REQUIRED', 'DISK_APPLIED_RELOAD_REQUIRED')]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot,
        [string]$StorePath,
        [string]$ConfigPath
    )
    $resolved = Resolve-ReloadStorePath -StorePath $StorePath
    $fingerprint = $null
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
            if ($null -ne $previous -and -not [string]::IsNullOrWhiteSpace([string]$previous.fingerprint)) {
                $fingerprint = [string]$previous.fingerprint
            }
        } catch {
            $fingerprint = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        $fingerprint = Get-TargetFingerprint -TargetRoot $TargetRoot
    }
    $record = [ordered]@{
        fingerprint = $fingerprint
        status      = $Status
        target_root = $TargetRoot
        recorded_at = (Get-Date).ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        try { $record['config_path'] = $ConfigPath } catch { }
        try {
            if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
                $record['config_snapshot'] = (Get-FileSetFingerprint -FilePaths @($ConfigPath))
            }
        } catch { }
    }
    Write-ReloadStateJson -Path $resolved -Value $record
    return $record
}
