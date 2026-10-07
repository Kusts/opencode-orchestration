<#!
.SYNOPSIS
    Phase 2D session-scoped profile overlay helper (SHADOW ONLY). Never live.
.DESCRIPTION
    Generates a session-scoped overlay JSON {session_id, profiles,
    generated_at, expires=session, mcps[]} under -OutDir (default $env:TEMP
    or cache/v3/overlays). Never touches ~/.config/opencode. -Release removes
    the overlay for a session. Overlays of different sessions never mix
    (paths keyed by session_id). PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [string[]]$Profiles,
    [string]$SessionId,
    [string]$OutDir,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)

function Write-OverlayCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-OverlaySafeId {
    param([string]$Raw)
    $s = ([string]$Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    if ($s -match '[^A-Za-z0-9_-]') { return '' }
    if ($s.Length -gt 64) { return '' }
    return $s
}

function Get-OverlayDir {
    param([string]$Wanted)
    if (-not [string]::IsNullOrWhiteSpace($Wanted)) { return $Wanted }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { return (Join-Path $env:TEMP 'capability-overlays') }
    return (Join-Path $repoRoot 'cache\v3\overlays')
}

if ([string]::IsNullOrWhiteSpace($SessionId)) {
    Write-OverlayCliError 'Usage: capability-profile-overlay.ps1 -Profiles <a,b> -SessionId <id> [-OutDir <dir>] [-Release].'
    exit 2
}
$sid = Get-OverlaySafeId -Raw $SessionId
if ([string]::IsNullOrWhiteSpace($sid)) {
    Write-OverlayCliError 'capability-profile-overlay.ps1: -SessionId must match [A-Za-z0-9_-]{1,64}.'
    exit 2
}

$dir = Get-OverlayDir -Wanted $OutDir
try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
catch {
    Write-OverlayCliError ("capability-profile-overlay.ps1: cannot create OutDir ({0})" -f $_.Exception.Message)
    exit 2
}

try { $dirFull = [IO.Path]::GetFullPath($dir) } catch { $dirFull = $dir }
$overlayPath = Join-Path $dirFull ("overlay-{0}.json" -f $sid)

if ($Release) {
    try {
        if (Test-Path -LiteralPath $overlayPath) { Remove-Item -LiteralPath $overlayPath -Force }
        $done = [PSCustomObject]@{ session_id = $sid; released = $true; path = $overlayPath }
        Write-Output ($done | ConvertTo-Json -Depth 6 -Compress)
        exit 0
    }
    catch {
        Write-OverlayCliError ("capability-profile-overlay.ps1: cannot release overlay ({0})" -f $_.Exception.Message)
        exit 2
    }
}

$clean = New-Object System.Collections.Generic.List[string]
foreach ($raw in @($Profiles)) {
    foreach ($part in ([string]$raw -split '[,;]')) {
        $s = $part.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -match '[^a-z0-9_-]') { continue }
        if ($clean -cnotcontains $s) { $clean.Add($s) }
    }
}
$profileArr = [string[]]$clean
[Array]::Sort($profileArr, [System.StringComparer]::Ordinal)

# validacao contra registries (fail-closed: ilegivel -> recusa)
$knownIds = New-Object System.Collections.Generic.List[string]
$groups = New-Object System.Collections.ArrayList
[void]$groups.Add(@('database-supabase', 'database-neon'))
$registriesOk = $false
try {
    $routingText = [IO.File]::ReadAllText((Join-Path $repoRoot 'source\registry\capability-routing.json'), [Text.UTF8Encoding]::new($false))
    $routingDoc = $routingText | ConvertFrom-Json
    foreach ($r in @($routingDoc.profile_rules)) {
        $id = ([string]$r.profile).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($id)) -or ($knownIds -ccontains $id)) { continue }
        [void]$knownIds.Add($id)
    }
    foreach ($g in @($routingDoc.exclusive_groups)) {
        $members = @(@($g.members) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($members.Count -ge 2) { [void]$groups.Add($members) }
    }
    $mcpText = [IO.File]::ReadAllText((Join-Path $repoRoot 'source\registry\mcp-profiles.json'), [Text.UTF8Encoding]::new($false))
    $mcpDoc = $mcpText | ConvertFrom-Json
    foreach ($p in @($mcpDoc.profiles)) {
        $id = ([string]$p.id).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($id)) -or ($knownIds -ccontains $id)) { continue }
        [void]$knownIds.Add($id)
    }
    $registriesOk = ($knownIds.Count -gt 0)
}
catch { $registriesOk = $false }
if (-not $registriesOk) {
    Write-OverlayCliError 'capability-profile-overlay.ps1: registry indisponivel (fail-closed: recusa).'
    exit 2
}
foreach ($p in $profileArr) {
    if ($knownIds -cnotcontains $p) {
        Write-OverlayCliError ("capability-profile-overlay.ps1: profile id desconhecido (recusa): {0}" -f $p)
        exit 2
    }
}
foreach ($g in $groups) {
    $hit = @($g | Where-Object { $profileArr -ccontains $_ })
    if ($hit.Count -ge 2) {
        Write-OverlayCliError ("capability-profile-overlay.ps1: profiles mutuamente exclusivos (recusa): {0}" -f ($hit -join ','))
        exit 2
    }
}

# P2-2 FIX: MCPs derivados do registry (mcp-profiles.json), nunca de mapa
# parcial hardcoded. Todo profile aceito resolve seus MCPs; novo profile no
# registry funciona sem patch aqui.
$mcpMap = @{}
try {
    foreach ($p in @($mcpDoc.profiles)) {
        $profId = ([string]$p.id).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($profId)) { continue }
        $ms = @(@($p.mcps) | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $mcpMap[$profId] = @($ms)
    }
}
catch { }
$mcps = New-Object System.Collections.Generic.List[string]
foreach ($p in $profileArr) {
    if ($mcpMap.ContainsKey($p)) {
        foreach ($m in @($mcpMap[$p])) {
            if ($mcps -cnotcontains $m) { $mcps.Add($m) }
        }
    }
}
$mcpArr = [string[]]$mcps
[Array]::Sort($mcpArr, [System.StringComparer]::Ordinal)

$overlay = [PSCustomObject]@{
    session_id   = $sid
    profiles     = $profileArr
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    expires      = 'session'
    mcps         = $mcpArr
    mode         = 'shadow'
}
try {
    $json = ($overlay | ConvertTo-Json -Depth 6 -Compress)
    [IO.File]::WriteAllText($overlayPath, $json, [Text.UTF8Encoding]::new($false))
    $result = [PSCustomObject]@{ session_id = $sid; path = $overlayPath; profiles = $profileArr; mcps = $mcpArr; mode = 'shadow' }
    Write-Output ($result | ConvertTo-Json -Depth 6 -Compress)
    exit 0
}
catch {
    Write-OverlayCliError ("capability-profile-overlay.ps1: cannot write overlay ({0})" -f $_.Exception.Message)
    exit 2
}
