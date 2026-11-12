<#
.SYNOPSIS
    Measures local skill catalog, SKILL.md files, and bridge dispatch context.
.DESCRIPTION
    Read-only local I/O. No network or model calls. PowerShell 5.1, ASCII-only.
#>
[CmdletBinding()]
param(
    [string[]]$Roots,
    [string]$OutFile,
    [string]$GeneratedAt,
    [int]$MaxNodes = 10000,
    [int]$MaxDepth = 64
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$generatedAtSource = if ([string]::IsNullOrWhiteSpace($GeneratedAt)) { $GeneratedAt = [DateTime]::UtcNow.ToString('o'); 'clock_utc' } else { 'parameter' }
$catalogPath = Join-Path $repoRoot 'source\registry\skills-catalog.json'
$catalogText = [IO.File]::ReadAllText($catalogPath, [Text.UTF8Encoding]::new($false))
$catalogDoc = $catalogText | ConvertFrom-Json
$entries = @($catalogDoc.skills)
$fields = @()
foreach ($entry in $entries) { foreach ($p in $entry.PSObject.Properties.Name) { if ($fields -notcontains $p) { $fields += $p } } }
$userHome = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($userHome) -and $env:HOMEDRIVE -and $env:HOMEPATH) { $userHome = Join-Path $env:HOMEDRIVE $env:HOMEPATH }
$defaultRoots = @((Join-Path $repoRoot 'skills-core'))
if ([string]::IsNullOrWhiteSpace($userHome)) { $defaultRoots += @((Join-Path ([IO.Path]::GetTempPath()) 'no-user-profile\.config\opencode\skills'), (Join-Path ([IO.Path]::GetTempPath()) 'no-user-profile\.agents\skills')) }
else { $defaultRoots += @((Join-Path $userHome '.config\opencode\skills'), (Join-Path $userHome '.agents\skills')) }
if ($null -eq $Roots -or $Roots.Count -eq 0) { $Roots = $defaultRoots }
$repoRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
function Get-CanonicalDirectoryPath {
    param([string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return [IO.Path]::GetFullPath($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
}
function Get-DirectoryTarget {
    param($Item)
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $targetProperty = $Item.PSObject.Properties['Target']
        if ($null -ne $targetProperty -and $targetProperty.Value) {
            $target = [string]@($targetProperty.Value)[0]
            if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Item.FullName) $target }
            return [IO.Path]::GetFullPath($target)
        }
        return $null
    }
    return $Item.FullName
}
$rootResults = @()
foreach ($root in $Roots) {
    $exists = Test-Path -LiteralPath $root -PathType Container
    $perSkill = @()
    $entryCount = 0; $reparseCount = 0; $unreachable = 0; $lowerBound = $false; $truncated = $false; $truncatedReason = @()
    if ($exists) {
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue(@{ visible=$root; physical=$root; depth=0 })
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        while ($queue.Count -gt 0) {
            if ($visited.Count -ge $MaxNodes) { $truncated=$true; $lowerBound=$true; $truncatedReason += 'max_nodes'; break }
            $node = $queue.Dequeue()
            try {
                $canonical = Get-CanonicalDirectoryPath $node.physical
                if (-not $visited.Add($canonical)) { continue }
                $children = @(Get-ChildItem -LiteralPath $node.physical -Force -ErrorAction Stop)
                if ($node.physical -eq $root) { $entryCount = $children.Count }
                foreach ($child in $children) {
                    if (-not $child.PSIsContainer) { continue }
                    $target = Get-DirectoryTarget $child
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $reparseCount++ }
                    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target -PathType Container)) { $unreachable++; $lowerBound=$true; continue }
                    $physical = if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $target } else { $child.FullName }
                    if ($node.depth + 1 -gt $MaxDepth) { $truncated=$true; $lowerBound=$true; if ($truncatedReason -notcontains 'max_depth') { $truncatedReason += 'max_depth' }; continue }
                    $queue.Enqueue(@{ visible=$child.FullName; physical=$physical; depth=$node.depth + 1 })
                }
                $skillFile = Join-Path $node.physical 'SKILL.md'
                if (Test-Path -LiteralPath $skillFile -PathType Leaf) {
                    $bytes = [IO.File]::ReadAllBytes($skillFile)
                    $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
                    $id = Split-Path -Leaf $node.visible
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                    $perSkill += [pscustomobject]@{ id=$id; bytes=$bytes.Length; chars=$text.Length; sha256=$hash }
                }
            } catch { $unreachable++; $lowerBound=$true }
        }
    }
    $sumBytes = 0; $sumChars = 0
    foreach ($item in $perSkill) { $sumBytes += $item.bytes; $sumChars += $item.chars }
    $label = if ($root -eq $defaultRoots[0]) { 'repo:skills-core' } elseif ($root -eq $defaultRoots[1]) { 'user:opencode-skills' } elseif ($root -eq $defaultRoots[2]) { 'user:agents-skills' } else { 'override:' + [IO.Path]::GetFileName($root) }
    $rootResults += [pscustomobject]@{ path=$root; path_label=$label; exists=[bool]$exists; entry_count_observed=$entryCount; reparse_point_entries_observed=$reparseCount; unreachable_count=$unreachable; total_is_lower_bound=$lowerBound; truncated=$truncated; truncated_reason=@($truncatedReason); skill_md_count_observed=$perSkill.Count; total_skill_md_bytes_observed=$sumBytes; total_skill_md_chars_observed=$sumChars; per_skill=@($perSkill) }
}
$taskPath = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-task-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $task = @{ task_id='skill-cost-measurement'; objective='Create a PowerShell test for a local JSON parser'; task_type='implementation'; domain_hints=@('powershell'); risk='low'; read_write_mode='read'; constraints=@() } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($taskPath, $task, [Text.UTF8Encoding]::new($false))
    $bridgeOutput = & (Join-Path $repoRoot 'scripts\v3\skill-bridge.ps1') -TaskFile $taskPath 2>$null
    $bridge = ($bridgeOutput -join "`n") | ConvertFrom-Json
} finally { Remove-Item -LiteralPath $taskPath -Force -ErrorAction SilentlyContinue }
$contextText = [string]$bridge.capability_context_text
$ctxChars = $contextText.Length
$ctxBytes = [Text.UTF8Encoding]::new($false).GetByteCount($contextText)
$estimates = @()
foreach ($item in @(@{ name='catalog_chars'; chars=$catalogText.Length }, @{ name='dispatch_context_chars'; chars=$ctxChars })) {
    $estimates += [pscustomobject]@{ source=$item.name; estimated_tokens=[int][Math]::Ceiling($item.chars / 4.0); is_estimate=$true; method='chars/4' }
}
$unknown = @(
    [pscustomobject]@{ item='runtime_skill_listing'; reason='Runtime-injected skill listing is not derivable from filesystem contents, even when junctions are resolved.' },
    [pscustomobject]@{ item='actual_context_tokens'; reason='Actual provider context tokenization requires a real session observation.' },
    [pscustomobject]@{ item='provider_cache_and_cost'; reason='Cache read/write and provider cost require a real session via cache-metrics.ps1.' }
)
$result = [pscustomobject]@{
    generated_at=$GeneratedAt
    generated_at_source=$generatedAtSource
    catalog=[pscustomobject]@{ path=$catalogPath; bytes_observed=([IO.File]::ReadAllBytes($catalogPath)).Length; chars_observed=$catalogText.Length; entries_observed=$entries.Count; fields_observed=@($fields | Sort-Object) }
    roots=@($rootResults)
    dispatch_context=[pscustomobject]@{ status=$bridge.status; chars_observed=$ctxChars; bytes_observed=$ctxBytes; text=$contextText; explanation=$(if ($bridge.status -eq 'disabled') { 'skill_routing.enabled is false; no dispatch context is emitted.' } else { $bridge.reason }) }
    estimates=@($estimates)
    unknown=@($unknown)
    method=[pscustomobject]@{ name='deterministic_local_io'; no_model_call=$true; base_revision=$repoRevision; generated_by_commit=$repoRevision; limitations=@('Token estimates use chars/4 and are not observed tokens.', 'Runtime injection and provider cache/cost are not measured.') }
    limitations=@('Local filesystem observations do not represent runtime-injected skills or provider accounting.', 'path is machine-specific; use path_label for stable identification.')
}
$json = $result | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutFile)) { [IO.File]::WriteAllText($OutFile, $json + "`n", [Text.UTF8Encoding]::new($false)) }
else { Write-Output $json }
