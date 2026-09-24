<#!
.SYNOPSIS
    Preview e reconcilia as instrucoes geradas do OpenCode com o destino ativo.

.DESCRIPTION
    Sem -Apply nunca modifica estado ativo. Com -Apply, o destino e validado,
    protegido por backup CAS com timestamp, salvo em rollback.json e escrito
    atomicamente via .tmp + verificacao de hash. OpenCode-only: sem
    runtimes.json, sem componentes Mcp/Launchers. Ownership interno apenas
    informativo (control-plane|user|runtime|plugin).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$GeneratedRoot,
    [string]$UserProfileRoot,
    [string]$BackupRoot,
    [string]$ModelsPath,
    [string]$HomeDir,
    [string]$RepoDir,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($RepoDir)) { $RepoRoot = $RepoDir }
if (-not [string]::IsNullOrWhiteSpace($HomeDir)) { $UserProfileRoot = $HomeDir }
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($GeneratedRoot)) { $GeneratedRoot = Join-Path $RepoRoot 'generated' }
if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) { $UserProfileRoot = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $UserProfileRoot '.config\opencode\reconciliation-backups' }
if ([string]::IsNullOrWhiteSpace($HomeDir)) { $HomeDir = $UserProfileRoot }
if ([string]::IsNullOrWhiteSpace($RepoDir)) { $RepoDir = $RepoRoot }

function Get-ReconcileModels {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ("Arquivo de modelos ausente: " + $Path) }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $lines = $raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }
    $parsed = ($lines -join "`n") | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($parsed.planner) -or [string]::IsNullOrWhiteSpace($parsed.cheap) -or [string]::IsNullOrWhiteSpace($parsed.strong)) { throw 'Arquivo de modelos precisa definir planner, cheap e strong.' }
    return $parsed
}

function Resolve-ReconcileTokens {
    param([Parameter(Mandatory)][string]$Text, $Models, [Parameter(Mandatory)][string]$HomeValue, [Parameter(Mandatory)][string]$RepoValue)
    $r = $Text
    if ($null -ne $Models) {
        $r = $r.Replace('{{MODEL_PLANNER}}', $Models.planner)
        $r = $r.Replace('{{MODEL_CHEAP}}', $Models.cheap)
        $r = $r.Replace('{{MODEL_STRONG}}', $Models.strong)
    }
    $homeSlash = $HomeValue -replace '\\', '/'
    $r = $r.Replace('{{HOME}}', $homeSlash)
    $r = $r.Replace('{{REPO_DIR}}', ($RepoValue -replace '\\', '/'))
    return $r
}

function Get-FileHashSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n" -replace "`r", "`n"), [Text.UTF8Encoding]::new($false))
}

function Write-SafeJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-Utf8NoBom -Path $Path -Text (($Value | ConvertTo-Json -Depth 12) + "`n")
}

function Read-Utf8([string]$Path) {
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

$sourcePath = Join-Path $GeneratedRoot 'opencode/AGENTS.md'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Generated source ausente: opencode/AGENTS.md (rode scripts/render-opencode-config.ps1)." }
$generatedText = Read-Utf8 $sourcePath
if ($generatedText -notmatch '(?m)^<!-- GENERATED FILE:') { throw 'Fonte gerada sem marcador de geracao.' }

$headerLines = @(
    '<!-- GENERATED FILE: direct edits will be overwritten. -->',
    '<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->',
    '<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->'
)
$header = ($headerLines -join "`n")
$bodyLines = ($generatedText -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"
$bodyStart = 0
while (($bodyStart -lt $bodyLines.Count) -and (($headerLines -contains $bodyLines[$bodyStart]) -or ([string]::IsNullOrWhiteSpace($bodyLines[$bodyStart])))) { $bodyStart++ }
$content = (($bodyLines | Select-Object -Skip $bodyStart) -join "`n").TrimEnd() + "`n"

$reconcileModels = $null
if (-not [string]::IsNullOrWhiteSpace($ModelsPath)) { $reconcileModels = Get-ReconcileModels -Path $ModelsPath }
$content = Resolve-ReconcileTokens -Text $content -Models $reconcileModels -HomeValue $HomeDir -RepoValue $RepoDir
$pendingModelTokens = ($content -match '\{\{MODEL_')
$pendingPathTokens = (($content -match '\{\{HOME\}\}') -or ($content -match '\{\{REPO_DIR\}\}'))

$markStart = '<!-- opencode-orchestration:start -->'
$markEnd = '<!-- opencode-orchestration:end -->'
$owner = 'control-plane'
$targetPath = Join-Path $UserProfileRoot '.config\opencode\AGENTS.md'
$desiredHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$currentHash = Get-FileHashSafe -Path $targetPath

$hasMarkers = $false
$action = 'create'
$status = 'MISSING'
if ($null -ne $currentHash) {
    $existing = Read-Utf8 $targetPath
    $hasMarkers = $existing.Contains($markStart) -and $existing.Contains($markEnd)
    if ($hasMarkers) {
        $pattern = [regex]::Escape($markStart) + '[\s\S]*?' + [regex]::Escape($markEnd)
        $innerNew = ($markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd)
        $candidate = [regex]::Replace($existing, $pattern, '__OO_BLOCK__').Replace('__OO_BLOCK__', $innerNew)
        if (-not $candidate.Contains('GENERATED FILE')) { $candidate = $header.TrimEnd() + "`n" + $candidate.TrimStart() }
        $candidate = $candidate.TrimEnd() + "`n"
        $tmpProbe = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmpProbe, ($candidate -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
            $candidateHash = (Get-FileHash -LiteralPath $tmpProbe -Algorithm SHA256).Hash
        } finally { Remove-Item -LiteralPath $tmpProbe -Force -ErrorAction SilentlyContinue }
        if ($candidateHash -eq $currentHash) { $status = 'SAME' } else { $status = 'DIFFERENT' }
        $action = 'replace-block'
    } else {
        $status = 'DIFFERENT'
        $action = 'append-block'
    }
}

Write-Host '' ; Write-Host '=== OPENCODE CONFIG RECONCILIATION ===' -ForegroundColor Cyan
if ($Apply) { Write-Host 'MODE: APPLY; COMPONENT: Instructions; RUNTIME: OpenCode' -ForegroundColor Yellow } else { Write-Host 'MODE: PREVIEW; COMPONENT: Instructions; RUNTIME: OpenCode' -ForegroundColor Cyan }
$shortCurrent = '<none>'
if ($currentHash) { $shortCurrent = $currentHash.Substring(0, 12) }
Write-Host ("[{0}] generated/opencode/AGENTS.md -> {1} (current {2}; desired {3}; owner {4}; action {5})" -f $status, $targetPath, $shortCurrent, $desiredHash.Substring(0, 12), $owner, $action) -ForegroundColor $(if ($status -eq 'SAME') { 'Green' } else { 'Yellow' })
if ($pendingModelTokens -or $pendingPathTokens) {
    Write-Host 'Plano com tokens pendentes: informe ModelsPath para resolver modelos antes do apply.' -ForegroundColor Yellow
}

if (-not $Apply) {
    Write-Host 'Preview complete. No active file was changed.' -ForegroundColor Cyan
    exit 0
}
if ($pendingModelTokens -and [string]::IsNullOrWhiteSpace($ModelsPath)) {
    Write-Host 'Apply abortado: modelos nao resolvidos e ModelsPath nao informado. Nada foi escrito.' -ForegroundColor Red
    exit 2
}
if ($pendingModelTokens -or $pendingPathTokens) {
    Write-Host 'Apply abortado: ha tokens nao resolvidos no conteudo. Nada foi escrito.' -ForegroundColor Red
    exit 2
}
if ($status -eq 'SAME') {
    Write-Host 'Nothing to apply.' -ForegroundColor Green
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot ("reconcile-opencode-" + $stamp)
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backupFile = $null
if ($null -ne $currentHash) {
    $backupFile = Join-Path $backupDir 'AGENTS.md'
    Copy-Item -LiteralPath $targetPath -Destination $backupFile -Force
}
$rollback = [ordered]@{
    version = 1
    created_at = (Get-Date).ToString('o')
    component = 'Instructions'
    runtime = 'OpenCode'
    entries = @(
        [ordered]@{
            label = 'generated/opencode/AGENTS.md'
            target = $targetPath
            source = $sourcePath
            owner = $owner
            expected_hash = $currentHash
            desired_hash = $desiredHash
            existed_before = ($null -ne $currentHash)
            backup_path = $backupFile
            status = 'planned'
            error = $null
        }
    )
}
$rollbackPath = Join-Path $backupDir 'rollback.json'
Write-SafeJson -Path $rollbackPath -Value $rollback

try {
    $beforeApply = Get-FileHashSafe -Path $targetPath
    if ($beforeApply -ne $currentHash) { throw 'CAS conflict: destino mudou apos o preview.' }
    $newText = $null
    if ($action -eq 'replace-block') {
        $existing = Read-Utf8 $targetPath
        $pattern = [regex]::Escape($markStart) + '[\s\S]*?' + [regex]::Escape($markEnd)
        $innerNew = ($markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd)
        $newText = [regex]::Replace($existing, $pattern, '__OO_BLOCK__').Replace('__OO_BLOCK__', $innerNew)
        if (-not $newText.Contains('GENERATED FILE')) { $newText = $header.TrimEnd() + "`n" + $newText.TrimStart() }
        $newText = $newText.TrimEnd() + "`n"
    } elseif ($action -eq 'append-block') {
        $existing = (Read-Utf8 $targetPath).TrimEnd()
        $block = $header.TrimEnd() + "`n" + $markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd + "`n"
        $newText = $existing + "`n`n" + $block.TrimEnd() + "`n"
    } else {
        $block = $header.TrimEnd() + "`n" + $markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd + "`n"
        $newText = $block.TrimEnd() + "`n"
    }
    $targetParent = Split-Path -Parent $targetPath
    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    $tempPath = Join-Path $targetParent ('.' + (Split-Path -Leaf $targetPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-Utf8NoBom -Path $tempPath -Text $newText
        $beforeMove = Get-FileHashSafe -Path $targetPath
        if ($beforeMove -ne $currentHash) { throw 'CAS conflict: destino mudou antes da substituicao.' }
        if (Test-Path -LiteralPath $targetPath) {
            $replaceBackup = $tempPath + '.bak'
            try { [System.IO.File]::Replace($tempPath, $targetPath, $replaceBackup, $false) }
            catch { Move-Item -LiteralPath $tempPath -Destination $targetPath -Force }
            if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue }
        } else {
            [IO.File]::Move($tempPath, $targetPath)
        }
    } finally {
        if (($tempPath) -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
    $afterHash = Get-FileHashSafe -Path $targetPath
    $afterText = Read-Utf8 $targetPath
    if (-not $afterText.Contains($markStart)) { throw 'Verificacao pos-aplicacao falhou: marcadores ausentes.' }
    if (-not $afterText.Contains($content.TrimEnd().Substring(0, [Math]::Min(64, $content.TrimEnd().Length)))) { throw 'Verificacao pos-aplicacao falhou: conteudo nao confere.' }
    $rollback.entries[0].status = 'applied-and-verified'
    $rollback.entries[0].applied_hash = $afterHash
    Write-SafeJson -Path $rollbackPath -Value $rollback
    Write-Host ("[APPLIED] generated/opencode/AGENTS.md -> " + $targetPath) -ForegroundColor Green
    Write-Host ("Rollback manifest: " + $rollbackPath) -ForegroundColor DarkGray
    Write-Host 'Reconciliation complete.' -ForegroundColor Green
    exit 0
} catch {
    $rollback.entries[0].status = 'failed'
    $rollback.entries[0].error = $_.Exception.Message
    Write-SafeJson -Path $rollbackPath -Value $rollback
    Write-Host ("[FAILED] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
