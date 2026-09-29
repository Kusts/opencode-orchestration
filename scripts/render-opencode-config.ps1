<#!
.SYNOPSIS
    Renderiza as instrucoes do OpenCode de forma deterministica (V1 + V2).

.DESCRIPTION
    Le apenas source/ (global + adapter por runtime) e escreve conteudo
    reviewavel em generated/opencode/. Nao toca em caminhos ativos,
    skills, credenciais ou caches. OpenCode-only.

    Saidas (Phase 6, V3.1):
    - generated/opencode/v1/AGENTS.md (global + source/adapters/opencode.md)
    - generated/opencode/v2/AGENTS.md (global + source/adapters/opencode-v2.md)
    - generated/opencode/AGENTS.md = copia byte-identica do v1 (compat com
      consumers atuais; o instalador le as fontes source/ diretamente, nao
      este arquivo).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $RepoRoot 'generated' }

function Normalize-Text {
    param([Parameter(Mandatory)][string]$Text)
    return ($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n")
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n" -replace "`r", "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-SourceText {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fonte ausente: $RelativePath" }
    return Normalize-Text ([IO.File]::ReadAllText($path))
}

$header = @'
<!-- GENERATED FILE: direct edits will be overwritten. -->
<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->
<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->
'@

$globalBody = Read-SourceText 'source/global/AGENTS.md'
$manifestRows = @()

foreach ($rt in @(@{ Id = 'v1'; Adapter = 'source/adapters/opencode.md' }, @{ Id = 'v2'; Adapter = 'source/adapters/opencode-v2.md' })) {
    $adapterBody = Read-SourceText $rt.Adapter
    $content = ($header.TrimEnd() + "`n`n" + $globalBody + "`n`n" + $adapterBody).TrimEnd() + "`n"
    $rel = ('opencode/' + $rt.Id + '/AGENTS.md')
    $destination = Join-Path $OutputRoot $rel
    Write-Utf8NoBom -Path $destination -Text $content
    $manifestRows += [ordered]@{
        runtime = ('opencode-' + $rt.Id)
        generated = $rel
        sources = @('source/global/AGENTS.md', $rt.Adapter)
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        bytes = (Get-Item -LiteralPath $destination).Length
    }
}

# Compat: generated/opencode/AGENTS.md permanece como copia byte-identica do
# v1 (consumers atuais). Nao e fonte de verdade do instalador (que le
# source/ diretamente).
$v1Path = Join-Path $OutputRoot 'opencode/v1/AGENTS.md'
$compatPath = Join-Path $OutputRoot 'opencode/AGENTS.md'
Copy-Item -LiteralPath $v1Path -Destination $compatPath -Force
$manifestRows += [ordered]@{
    runtime = 'opencode'
    generated = 'opencode/AGENTS.md'
    sources = @('source/global/AGENTS.md', 'source/adapters/opencode.md')
    sha256 = (Get-FileHash -LiteralPath $compatPath -Algorithm SHA256).Hash
    bytes = (Get-Item -LiteralPath $compatPath).Length
    note = 'copia de compatibilidade de opencode/v1/AGENTS.md'
}

$manifest = [ordered]@{
    version = 1
    renderer = 'scripts/render-opencode-config.ps1'
    source_root = 'source'
    generated_root = 'generated'
    files = @($manifestRows)
}
$manifestPath = Join-Path $OutputRoot 'manifest.json'
Write-Utf8NoBom -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")

Write-Host ("Rendered 3 deterministic instruction files under " + $OutputRoot) -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor DarkGray
exit 0
