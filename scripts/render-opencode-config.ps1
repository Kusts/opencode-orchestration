<#!
.SYNOPSIS
    Renderiza as instrucoes do OpenCode de forma deterministica.

.DESCRIPTION
    Le apenas source/ (global + adapter OpenCode) e escreve conteudo
    reviewavel em generated/opencode/. Nao toca em caminhos ativos,
    skills, credenciais ou caches. OpenCode-only.
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

$sources = @('source/global/AGENTS.md', 'source/adapters/opencode.md')
$sourceBodies = @($sources | ForEach-Object { Read-SourceText $_ })
$content = ($header.TrimEnd() + "`n`n" + ($sourceBodies -join "`n`n")).TrimEnd() + "`n"
$destination = Join-Path $OutputRoot 'opencode/AGENTS.md'
Write-Utf8NoBom -Path $destination -Text $content

$manifestRows = @(
    [ordered]@{
        runtime = 'opencode'
        generated = 'opencode/AGENTS.md'
        sources = @($sources)
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        bytes = (Get-Item -LiteralPath $destination).Length
    }
)

$manifest = [ordered]@{
    version = 1
    renderer = 'scripts/render-opencode-config.ps1'
    source_root = 'source'
    generated_root = 'generated'
    files = @($manifestRows)
}
$manifestPath = Join-Path $OutputRoot 'manifest.json'
Write-Utf8NoBom -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")

Write-Host ("Rendered 1 deterministic instruction file under " + $OutputRoot) -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor DarkGray
exit 0
