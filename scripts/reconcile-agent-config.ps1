<#!
.SYNOPSIS
    Preview e reconcilia instruções geradas com destinos ativos.

.DESCRIPTION
    Sem -Apply nunca modifica estado ativo. Com -Apply, cada destino é
    validado, protegido por hash CAS, salvo em backup e escrito atomicamente.
    O reconciliador não imprime valores de arquivos nem segredos.
#>
[CmdletBinding()]
param(
    [ValidateSet('Instructions','Mcp','Settings','Launchers','All')]
    [string]$Component = 'All',
    [ValidateSet('Codex','Claude','OpenCode','Pi','AntigravityCli','AntigravityIde','All')]
    [string]$Runtime = 'All',
    [switch]$Apply,
    [switch]$Force,
    [switch]$LoadOnly,
    [string]$RepoRoot,
    [string]$GeneratedRoot,
    [string]$UserProfileRoot,
    [string]$ActiveRoot,
    [string]$BackupRoot,
    [string]$PlanPath,
    [switch]$Backup
)

$ErrorActionPreference = 'Stop'
if ($Apply -and $Backup) { throw 'Backup e Apply são modos exclusivos.' }

function Get-FileHashSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}

function Test-CompareAndSwap {
    param([AllowNull()][string]$ExpectedHash, [AllowNull()][string]$ActualHash, [switch]$AllowMissing)
    $expectedMissing = [string]::IsNullOrWhiteSpace($ExpectedHash)
    $actualMissing = [string]::IsNullOrWhiteSpace($ActualHash)
    if ($expectedMissing) { return ($AllowMissing -and $actualMissing) }
    if ($actualMissing) { return $false }
    return ($ExpectedHash -eq $ActualHash)
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

function Expand-ControlPath {
    param([Parameter(Mandatory)][string]$Path)
    $result = $Path
    $result = $result.Replace('%USERPROFILE%', $UserProfileRoot)
    $result = $result.Replace('%APPDATA%', [Environment]::GetFolderPath('ApplicationData'))
    $result = $result.Replace('%LOCALAPPDATA%', [Environment]::GetFolderPath('LocalApplicationData'))
    return $result.Replace('/', '\')
}

function Assert-RuntimeRegistry {
    param([Parameter(Mandatory)]$Registry)
    $ownerValues = @('control-plane','user','runtime','orca','herdr','plugin')
    foreach ($runtimeEntry in @($Registry.runtimes.PSObject.Properties)) {
        $runtimeValue = $runtimeEntry.Value
        foreach ($required in @('id','executable','instruction_targets','settings_targets','mcp','launch','merge_strategy','smoke_test')) {
            if ($null -eq $runtimeValue.PSObject.Properties[$required]) { throw "Runtime '$($runtimeEntry.Name)' sem campo obrigatório '$required'." }
        }
        foreach ($target in @($runtimeValue.instruction_targets) + @($runtimeValue.settings_targets)) {
            if ($null -eq $target.owner) { throw "Target de '$($runtimeEntry.Name)' sem owner." }
            foreach ($owner in ([string]$target.owner -split ([regex]::Escape('+')))) {
                if ($ownerValues -notcontains $owner) { throw "Owner inválido '$owner' em '$($runtimeEntry.Name)'." }
            }
        }
    }
}

if ($LoadOnly) { return }
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($GeneratedRoot)) { $GeneratedRoot = Join-Path $RepoRoot 'generated' }
if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) { $UserProfileRoot = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($ActiveRoot)) { $ActiveRoot = Join-Path $UserProfileRoot '.agents' }
if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $ActiveRoot 'reconciliation-backups' }

$registryPath = Join-Path $RepoRoot 'source/registry/runtimes.json'
$registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
Assert-RuntimeRegistry -Registry $registry

if ($Component -eq 'Mcp') {
    $mcpScript = Join-Path $RepoRoot 'scripts/reconcile-mcp.ps1'
    $mcpArgs = @('-NoProfile','-File',$mcpScript,'-RepoRoot',$RepoRoot,'-UserProfileRoot',$UserProfileRoot,'-BackupRoot',$BackupRoot)
    if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $mcpArgs += @('-PlanPath',$PlanPath) }
    if ($Runtime -ne 'All') { $mcpArgs += @('-Runtime',$Runtime) } else { $mcpArgs += @('-Runtime','All') }
    if ($Apply) { $mcpArgs += '-Apply' } else { $mcpArgs += '-Preview' }
    if ($Force) { $mcpArgs += '-Force' }
    & pwsh @mcpArgs
    exit $LASTEXITCODE
}

if ($Component -eq 'Launchers') {
    $launcherScript = Join-Path $RepoRoot 'scripts/install-agent-launchers.ps1'
    $launcherArgs = @('-NoProfile','-File',$launcherScript,'-RepoRoot',$RepoRoot,'-ActiveRoot',$ActiveRoot,'-BackupRoot',$BackupRoot)
    if ($Apply) { $launcherArgs += '-Apply' } else { $launcherArgs += '-Preview' }
    if ($Force) { $launcherArgs += '-Force' }
    & pwsh @launcherArgs
    exit $LASTEXITCODE
}

$renderer = Join-Path $RepoRoot 'scripts/render-agent-config.ps1'
& $renderer -RepoRoot $RepoRoot -OutputRoot $GeneratedRoot | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Renderização falhou; reconciliação abortada.' }

$instructionSpecs = @(
    [ordered]@{ selector = 'All'; label = 'generated/global/AGENTS.md'; generated_relative = 'global/AGENTS.md'; target = (Join-Path $ActiveRoot 'AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'Codex'; label = 'generated/codex/AGENTS.md'; generated_relative = 'codex/AGENTS.md'; target = (Join-Path $UserProfileRoot '.codex/AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'Claude'; label = 'generated/claude/CLAUDE.md'; generated_relative = 'claude/CLAUDE.md'; target = (Join-Path $UserProfileRoot '.claude/CLAUDE.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'OpenCode'; label = 'generated/opencode/AGENTS.md'; generated_relative = 'opencode/AGENTS.md'; target = (Join-Path $UserProfileRoot '.config/opencode/AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'Pi'; label = 'generated/pi/AGENTS.md'; generated_relative = 'pi/AGENTS.md'; target = (Join-Path $UserProfileRoot '.pi/AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'Pi'; label = 'generated/pi/agent/AGENTS.md'; generated_relative = 'pi/agent/AGENTS.md'; target = (Join-Path $UserProfileRoot '.pi/agent/AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'AntigravityCli'; label = 'generated/antigravity-cli/AGENTS.md'; generated_relative = 'antigravity-cli/AGENTS.md'; target = (Join-Path $UserProfileRoot '.antigravitycli/AGENTS.md'); owner = 'control-plane' },
    [ordered]@{ selector = 'AntigravityIde'; label = 'generated/antigravity-ide/AGENTS.md'; generated_relative = 'antigravity-ide/AGENTS.md'; target = (Join-Path $UserProfileRoot '.antigravity-ide/AGENTS.md'); owner = 'control-plane' }
)

$selected = @()
if ($Component -in @('Instructions','All')) {
    $selected = @($instructionSpecs | Where-Object { $Runtime -eq 'All' -or $_.selector -eq $Runtime -or $_.selector -eq 'All' })
}

if ($Component -notin @('Instructions','All')) {
    Write-Host "[$Component] no active target is registered in this phase; preview is non-mutating." -ForegroundColor DarkGray
    if ($Apply) { Write-Error "Component '$Component' ainda não possui reconciliador implementado."; exit 2 }
    exit 0
}

$plan = @()
Write-Host "`n=== AGENT CONFIG RECONCILIATION ===" -ForegroundColor Cyan
Write-Host "MODE: $(if ($Apply) { 'APPLY' } else { 'PREVIEW' }); COMPONENT: $Component; RUNTIME: $Runtime" -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Cyan' })
foreach ($spec in $selected) {
    $sourcePath = Join-Path $GeneratedRoot $spec.generated_relative
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Generated source ausente: $($spec.generated_relative)" }
    $targetPath = $spec.target
    $expectedHash = Get-FileHashSafe -Path $targetPath
    $desiredHash = Get-FileHashSafe -Path $sourcePath
    $status = if ($null -eq $expectedHash) { 'MISSING' } elseif ($expectedHash -eq $desiredHash) { 'SAME' } else { 'DIFFERENT' }
    $plan += [pscustomobject]@{
        label = $spec.label
        source = $sourcePath
        target = $targetPath
        owner = $spec.owner
        expected_hash = $expectedHash
        desired_hash = $desiredHash
        status = $status
    }
    $shortExpected = if ($expectedHash) { $expectedHash.Substring(0, 12) } else { '<none>' }
    $shortDesired = $desiredHash.Substring(0, 12)
    Write-Host ("[{0}] {1} -> {2} (current {3}; desired {4})" -f $status, $spec.label, $targetPath, $shortExpected, $shortDesired) -ForegroundColor $(if ($status -eq 'SAME') { 'Green' } else { 'Yellow' })
}

$actionable = @($plan | Where-Object { $_.status -ne 'SAME' })
Write-Host "Actionable instruction targets: $($actionable.Count)" -ForegroundColor White
if ($Backup) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRoot "preapply-$Runtime-$stamp"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupEntries = @()
    foreach ($item in $plan) {
        $backupFile = $null
        if ($item.expected_hash) {
            $backupFile = Join-Path $backupDir ("{0:D2}-{1}" -f $backupEntries.Count, (Split-Path -Leaf $item.target))
            Copy-Item -LiteralPath $item.target -Destination $backupFile -Force
        }
        $backupEntries += [ordered]@{ label = $item.label; target = $item.target; expected_hash = $item.expected_hash; backup_path = $backupFile; existed_before = ($null -ne $item.expected_hash) }
    }
    $preapplyManifest = [ordered]@{ version = 1; created_at = (Get-Date).ToString('o'); component = $Component; runtime = $Runtime; entries = @($backupEntries); note = 'Pre-apply instruction snapshot; no active file was changed.' }
    $preapplyManifestPath = Join-Path $backupDir 'rollback.json'
    Write-SafeJson -Path $preapplyManifestPath -Value $preapplyManifest
    Write-Host ('Pre-apply instruction backup: ' + $preapplyManifestPath)
    exit 0
}
if (-not $Apply) {
    Write-Host 'Preview complete. No active file was changed.' -ForegroundColor Cyan
    exit 0
}
if ($actionable.Count -eq 0) {
    Write-Host 'Nothing to apply.' -ForegroundColor Green
    exit 0
}
if ($Force -and @($actionable | Where-Object { $_.owner -ne 'control-plane' }).Count -gt 0) {
    Write-Error 'Force só pode ser usado em arquivos controlados pelo control plane.'
    exit 2
}
if (-not $Force) {
    $answer = Read-Host "Digite yes para aplicar $($actionable.Count) arquivo(s)"
    if ($answer -ne 'yes') { Write-Host 'Cancelled. No active file was changed.' -ForegroundColor Cyan; exit 0 }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $BackupRoot "reconcile-$stamp"
$manifestPath = Join-Path $backupDir 'rollback.json'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$entries = @()
foreach ($item in $actionable) {
    $entries += [ordered]@{
        label = $item.label
        target = $item.target
        source = $item.source
        owner = $item.owner
        expected_hash = $item.expected_hash
        desired_hash = $item.desired_hash
        existed_before = ($null -ne $item.expected_hash)
        backup_path = $null
        status = 'planned'
        error = $null
    }
}
$manifest = [ordered]@{ version = 1; created_at = (Get-Date).ToString('o'); component = $Component; runtime = $Runtime; entries = @($entries) }
Write-SafeJson -Path $manifestPath -Value $manifest

$failures = 0
for ($index = 0; $index -lt $actionable.Count; $index++) {
    $item = $actionable[$index]
    $entry = $entries[$index]
    $tempPath = $null
    try {
        $currentBeforeBackup = Get-FileHashSafe -Path $item.target
        if (-not (Test-CompareAndSwap -ExpectedHash $item.expected_hash -ActualHash $currentBeforeBackup -AllowMissing)) { throw "CAS conflict: destino mudou após o preview." }
        if ($null -ne $currentBeforeBackup) {
            $backupFile = Join-Path $backupDir ("{0:D2}-{1}" -f $index, (Split-Path -Leaf $item.target))
            Copy-Item -LiteralPath $item.target -Destination $backupFile -Force
            $entry.backup_path = $backupFile
        }
        $desiredText = [IO.File]::ReadAllText($item.source)
        if ($desiredText -notmatch '(?m)^<!-- GENERATED FILE:') { throw 'Fonte gerada sem marcador de geração.' }
        $targetParent = Split-Path -Parent $item.target
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        $tempPath = Join-Path $targetParent ('.' + (Split-Path -Leaf $item.target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        Write-Utf8NoBom -Path $tempPath -Text $desiredText
        if (-not (Test-Path -LiteralPath $tempPath -PathType Leaf)) { throw 'Arquivo temporário não foi criado.' }
        $currentBeforeMove = Get-FileHashSafe -Path $item.target
        if (-not (Test-CompareAndSwap -ExpectedHash $item.expected_hash -ActualHash $currentBeforeMove -AllowMissing)) { throw "CAS conflict: destino mudou antes da substituição." }
        if (Test-Path -LiteralPath $item.target) { [IO.File]::Delete($item.target) }
        [IO.File]::Move($tempPath, $item.target)
        $actualAfter = Get-FileHashSafe -Path $item.target
        if ($actualAfter -ne $item.desired_hash) { throw 'Hash pós-aplicação não confere.' }
        $entry.status = 'applied-and-verified'
        Write-Host "[APPLIED] $($item.label) -> $($item.target)" -ForegroundColor Green
    } catch {
        $failures++
        $entry.status = 'failed'
        $entry.error = $_.Exception.Message
        Write-Host "[FAILED] $($item.label): $($_.Exception.Message)" -ForegroundColor Red
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
    $manifest.entries = @($entries)
    Write-SafeJson -Path $manifestPath -Value $manifest
}

Write-Host "Rollback manifest: $manifestPath" -ForegroundColor DarkGray
if ($failures -gt 0) { Write-Error "$failures target(s) failed; successful independent targets were preserved."; exit 1 }
Write-Host 'Reconciliation complete.' -ForegroundColor Green
exit 0
