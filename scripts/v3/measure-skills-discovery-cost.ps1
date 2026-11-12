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
    [string]$GeneratedAt
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($GeneratedAt)) { $GeneratedAt = [DateTime]::UtcNow.ToString('o') }
$catalogPath = Join-Path $repoRoot 'source\registry\skills-catalog.json'
$catalogText = [IO.File]::ReadAllText($catalogPath, [Text.UTF8Encoding]::new($false))
$catalogDoc = $catalogText | ConvertFrom-Json
$entries = @($catalogDoc.skills)
$fields = @()
foreach ($entry in $entries) { foreach ($p in $entry.PSObject.Properties.Name) { if ($fields -notcontains $p) { $fields += $p } } }
$defaultRoots = @(
    (Join-Path $repoRoot 'skills-core'),
    (Join-Path $env:USERPROFILE '.config\opencode\skills'),
    (Join-Path $env:USERPROFILE '.agents\skills')
)
if ($null -eq $Roots -or $Roots.Count -eq 0) { $Roots = $defaultRoots }
$rootResults = @()
foreach ($root in $Roots) {
    $exists = Test-Path -LiteralPath $root -PathType Container
    $perSkill = @()
    if ($exists) {
        foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'SKILL.md' -File -Recurse | Sort-Object FullName) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
            $id = Split-Path -Leaf (Split-Path -Parent $file.FullName)
            $perSkill += [pscustomobject]@{ id = $id; bytes = $bytes.Length; chars = $text.Length; sha256 = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        }
    }
    $sumBytes = 0; $sumChars = 0
    foreach ($item in $perSkill) { $sumBytes += $item.bytes; $sumChars += $item.chars }
    $rootResults += [pscustomobject]@{ path = $root; exists = [bool]$exists; entry_count_observed = $(if ($exists) { @(Get-ChildItem -LiteralPath $root -Directory).Count } else { 0 }); skill_md_count_observed = $perSkill.Count; total_skill_md_bytes_observed = $sumBytes; total_skill_md_chars_observed = $sumChars; per_skill = @($perSkill) }
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
    [pscustomobject]@{ item='runtime_skill_listing'; reason='Runtime-injected skill listing is not observable from local files.' },
    [pscustomobject]@{ item='actual_context_tokens'; reason='Actual provider context tokenization requires a real session observation.' },
    [pscustomobject]@{ item='provider_cache_and_cost'; reason='Cache read/write and provider cost require a real session via cache-metrics.ps1.' }
)
$revision = (& git -C $repoRoot rev-parse HEAD).Trim()
$result = [pscustomobject]@{
    generated_at=$GeneratedAt
    catalog=[pscustomobject]@{ path=$catalogPath; bytes_observed=([IO.File]::ReadAllBytes($catalogPath)).Length; chars_observed=$catalogText.Length; entries_observed=$entries.Count; fields_observed=@($fields | Sort-Object) }
    roots=@($rootResults)
    dispatch_context=[pscustomobject]@{ status=$bridge.status; chars_observed=$ctxChars; bytes_observed=$ctxBytes; text=$contextText; explanation=$(if ($bridge.status -eq 'disabled') { 'skill_routing.enabled is false; no dispatch context is emitted.' } else { $bridge.reason }) }
    estimates=@($estimates)
    unknown=@($unknown)
    method=[pscustomobject]@{ name='deterministic_local_io'; no_model_call=$true; base_revision=$revision; limitations=@('Token estimates use chars/4 and are not observed tokens.', 'Runtime injection and provider cache/cost are not measured.') }
    limitations=@('Local filesystem observations do not represent runtime-injected skills or provider accounting.')
}
$json = $result | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($OutFile)) { [IO.File]::WriteAllText($OutFile, $json + "`n", [Text.UTF8Encoding]::new($false)) }
else { Write-Output $json }
