<#!
.SYNOPSIS
    Renderiza instruções globais e adapters de forma determinística.

.DESCRIPTION
    Lê apenas source/ e escreve conteúdo reviewável em generated/. Não toca em
    caminhos ativos, skills, credenciais ou caches.
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
<!-- Canonical source: source/; regenerate with scripts/render-agent-config.ps1. -->
<!-- This file is active only after scripts/reconcile-agent-config.ps1 applies it. -->
'@

$specs = @(
    [ordered]@{ runtime = 'global'; generated_relative = 'global/AGENTS.md'; sources = @('source/global/AGENTS.md') },
    [ordered]@{ runtime = 'codex'; generated_relative = 'codex/AGENTS.md'; sources = @('source/global/AGENTS.md', 'source/adapters/codex.md') },
    [ordered]@{ runtime = 'claude'; generated_relative = 'claude/CLAUDE.md'; sources = @('source/global/AGENTS.md', 'source/adapters/claude.md') },
    [ordered]@{ runtime = 'opencode'; generated_relative = 'opencode/AGENTS.md'; sources = @('source/global/AGENTS.md', 'source/adapters/opencode.md') },
    [ordered]@{ runtime = 'pi'; generated_relative = 'pi/AGENTS.md'; sources = @('source/global/AGENTS.md') },
    [ordered]@{ runtime = 'pi'; generated_relative = 'pi/agent/AGENTS.md'; sources = @('source/adapters/pi.md') },
    [ordered]@{ runtime = 'antigravity-cli'; generated_relative = 'antigravity-cli/AGENTS.md'; sources = @('source/global/AGENTS.md', 'source/adapters/antigravity-cli.md') },
    [ordered]@{ runtime = 'antigravity-ide'; generated_relative = 'antigravity-ide/AGENTS.md'; sources = @('source/global/AGENTS.md', 'source/adapters/antigravity-ide.md') }
)

$manifestRows = @()
foreach ($spec in $specs) {
    $sourceBodies = @($spec.sources | ForEach-Object { Read-SourceText $_ })
    $content = ($header.TrimEnd() + "`n`n" + ($sourceBodies -join "`n`n")).TrimEnd() + "`n"
    $destination = Join-Path $OutputRoot $spec.generated_relative
    Write-Utf8NoBom -Path $destination -Text $content
    $manifestRows += [ordered]@{
        runtime = $spec.runtime
        generated = $spec.generated_relative
        sources = @($spec.sources)
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        bytes = (Get-Item -LiteralPath $destination).Length
    }
}

$manifest = [ordered]@{
    version = 1
    renderer = 'scripts/render-agent-config.ps1'
    source_root = 'source'
    generated_root = 'generated'
    files = @($manifestRows)
}
$manifestPath = Join-Path $OutputRoot 'manifest.json'
Write-Utf8NoBom -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")

Write-Host "Rendered $($manifestRows.Count) deterministic instruction files under $OutputRoot" -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor DarkGray
exit 0
