$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'measure-skills-discovery-cost.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outA = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-a-' + [guid]::NewGuid().ToString('N') + '.json')
$outB = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-b-' + [guid]::NewGuid().ToString('N') + '.json')
$before = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
$total = 0; $passed = 0
function Assert-True { param([bool]$Condition,[string]$Name) $script:total++; if ($Condition) { $script:passed++ } else { throw "FAIL: $Name" } }
try {
    & $scriptPath -OutFile $outA -GeneratedAt '2026-11-12T00:00:00Z'
    & $scriptPath -OutFile $outB -GeneratedAt '2026-11-12T00:00:00Z'
    $aText = [IO.File]::ReadAllText($outA); $bText = [IO.File]::ReadAllText($outB)
    $doc = $aText | ConvertFrom-Json
    Assert-True ($aText -ceq $bText) 'deterministic output'
    Assert-True ($null -ne $doc.catalog -and $null -ne $doc.roots -and $null -ne $doc.dispatch_context -and $null -ne $doc.estimates -and $null -ne $doc.unknown -and $null -ne $doc.method -and $null -ne $doc.limitations) 'required blocks'
    $catalog = Get-Content (Join-Path $repo 'source/registry/skills-catalog.json') -Raw | ConvertFrom-Json
    Assert-True ($doc.catalog.entries_observed -eq @($catalog.skills).Count) 'catalog entry count'
    Assert-True (@($doc.estimates | Where-Object { -not $_.is_estimate -or $_.method -ne 'chars/4' }).Count -eq 0) 'estimate labels'
    Assert-True (($doc.catalog.PSObject.Properties.Name -contains 'estimated_tokens') -eq $false -and ($doc.dispatch_context.PSObject.Properties.Name -contains 'estimated_tokens') -eq $false) 'no observed-field estimate placement'
    $unknownText = $doc.unknown | ConvertTo-Json -Depth 4 -Compress
    Assert-True ($doc.unknown.Count -ge 3 -and $unknownText.Contains('runtime_skill_listing') -and $unknownText.Contains('actual_context_tokens') -and $unknownText.Contains('provider_cache_and_cost')) 'unknowns cover runtime and provider'
    $after = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
    Assert-True ((Compare-Object $before $after).Count -eq 0) 'no files added to repo'
    Write-Output "PASS: $passed/$total"
} finally { Remove-Item $outA,$outB -Force -ErrorAction SilentlyContinue }
