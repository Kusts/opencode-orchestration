$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'measure-skills-discovery-cost.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outA = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-a-' + [guid]::NewGuid().ToString('N') + '.json')
$outB = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-b-' + [guid]::NewGuid().ToString('N') + '.json')
$before = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
$catalogPath = Join-Path $repo 'source/registry/skills-catalog.json'
$catalogHashBefore = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
$skillsHashesBefore = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills-core') -Recurse -File | ForEach-Object { '{0}:{1}' -f $_.FullName,(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object)
$total = 0; $passed = 0
function Assert-True { param([bool]$Condition,[string]$Name) $script:total++; if ($Condition) { $script:passed++ } else { throw "FAIL: $Name" } }
try {
    & $scriptPath -OutFile $outA -GeneratedAt '2026-11-12T00:00:00Z'
    & $scriptPath -OutFile $outB -GeneratedAt '2026-11-12T00:00:00Z'
    $aText = [IO.File]::ReadAllText($outA); $bText = [IO.File]::ReadAllText($outB)
    $doc = $aText | ConvertFrom-Json
    Assert-True ($aText -ceq $bText) 'deterministic output'
    Assert-True ($null -ne $doc.catalog -and $doc.roots.Count -ge 1 -and $null -ne $doc.dispatch_context -and $null -ne $doc.estimates -and $doc.unknown.Count -ge 3 -and $null -ne $doc.method -and $null -ne $doc.limitations -and $doc.catalog.entries_observed -ge 1) 'required non-empty blocks'
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
    Assert-True ($doc.catalog.entries_observed -eq @($catalog.skills).Count) 'catalog entry count'
    Assert-True (@($doc.estimates | Where-Object { -not $_.is_estimate -or $_.method -ne 'chars/4' }).Count -eq 0) 'estimate labels'
    $observedFields = @('bytes_observed','chars_observed','entries_observed','entry_count_observed','reparse_point_entries_observed','unreachable_count','skill_md_count_observed','total_skill_md_bytes_observed','total_skill_md_chars_observed')
    $badObserved = $false
    foreach ($root in $doc.roots) {
        foreach ($name in $observedFields) { $property=$root.PSObject.Properties[$name]; if ($null -ne $property -and $property.Value -is [string]) { if ($property.Value -match 'is_estimate|estimated_|chars/4') { $badObserved=$true } } }
        foreach ($skill in $root.per_skill) { foreach ($name in $observedFields) { $property=$skill.PSObject.Properties[$name]; if ($null -ne $property -and $property.Value -is [string] -and $property.Value -match 'is_estimate|estimated_|chars/4') { $badObserved=$true } } }
    }
    foreach ($name in $observedFields) { $property=$doc.catalog.PSObject.Properties[$name]; if ($null -ne $property -and $property.Value -is [string] -and $property.Value -match 'is_estimate|estimated_|chars/4') { $badObserved=$true } }
    Assert-True (-not $badObserved) 'no estimates in observed fields'
    $unknownText = $doc.unknown | ConvertTo-Json -Depth 4 -Compress
    Assert-True ($doc.unknown.Count -ge 3 -and $unknownText.Contains('runtime_skill_listing') -and $unknownText.Contains('actual_context_tokens') -and $unknownText.Contains('provider_cache_and_cost')) 'unknowns cover runtime and provider'
    $after = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
    $catalogHashAfter = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
    $skillsHashesAfter = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills-core') -Recurse -File | ForEach-Object { '{0}:{1}' -f $_.FullName,(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object)
    Assert-True ((Compare-Object $before $after).Count -eq 0 -and $catalogHashBefore -eq $catalogHashAfter -and (Compare-Object $skillsHashesBefore $skillsHashesAfter).Count -eq 0) 'no repo writes or modifications'
    $junctionBase = Join-Path ([IO.Path]::GetTempPath()) ('skill-junction-test-' + [guid]::NewGuid().ToString('N'))
    $targetDir = Join-Path $junctionBase 'real-skill'; $linkDir = Join-Path $junctionBase 'root\visible-skill'
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $junctionBase 'root') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $targetDir 'SKILL.md') -Value '# Junction test' -Encoding UTF8
    New-Item -ItemType Junction -Path $linkDir -Target $targetDir | Out-Null
    $junctionOut = Join-Path $junctionBase 'junction.json'
    & $scriptPath -Roots (Join-Path $junctionBase 'root') -OutFile $junctionOut -GeneratedAt '2026-11-12T00:00:00Z'
    $junctionDoc = Get-Content -LiteralPath $junctionOut -Raw | ConvertFrom-Json
    Assert-True ($junctionDoc.roots[0].entry_count_observed -eq 1 -and $junctionDoc.roots[0].reparse_point_entries_observed -eq 1 -and $junctionDoc.roots[0].skill_md_count_observed -eq 1 -and $junctionDoc.roots[0].per_skill[0].id -eq 'visible-skill') 'junction skill counted'
    Remove-Item -LiteralPath $junctionBase -Recurse -Force
    Write-Output "PASS: $passed/$total"
} finally { Remove-Item $outA,$outB -Force -ErrorAction SilentlyContinue; if (Test-Path -LiteralPath $junctionBase) { Remove-Item -LiteralPath $junctionBase -Recurse -Force -ErrorAction SilentlyContinue } }
