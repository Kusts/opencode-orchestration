$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'measure-skills-discovery-cost.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$outA = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-a-' + [guid]::NewGuid().ToString('N') + '.json')
$outB = Join-Path ([IO.Path]::GetTempPath()) ('skill-cost-b-' + [guid]::NewGuid().ToString('N') + '.json')
$before = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
$catalogPath = Join-Path $repo 'source/registry/skills-catalog.json'
$catalogHashBefore = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
$skillsHashesBefore = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills-core') -Recurse -File | ForEach-Object { '{0}:{1}' -f $_.FullName,(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object)
$gitStatusBefore = (& git -C $repo status --porcelain | Out-String).TrimEnd()
$gitDiffBefore = (& git -C $repo diff --name-only | Out-String).TrimEnd()
$total = 0; $passed = 0
function Assert-True { param([bool]$Condition,[string]$Name) $script:total++; if ($Condition) { $script:passed++ } else { throw "FAIL: $Name" } }
function Test-EstimateMarker {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { if (($key -ceq 'is_estimate' -and [bool]$Value[$key]) -or $key -match '^estimated_') { return $true }; if ($key -ceq 'method' -and $Value[$key] -ceq 'chars/4') { return $true }; if (Test-EstimateMarker $Value[$key]) { return $true } }
        return $false
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) { if (($property.Name -ceq 'is_estimate' -and [bool]$property.Value) -or $property.Name -match '^estimated_') { return $true }; if ($property.Name -ceq 'method' -and $property.Value -ceq 'chars/4') { return $true }; if (Test-EstimateMarker $property.Value) { return $true } }
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { foreach ($item in $Value) { if (Test-EstimateMarker $item) { return $true } }; return $false }
    return ([string]$Value -match 'is_estimate|estimated_|chars/4')
}
function Test-ObservedEstimate { param($Value) if ($Value -is [System.Collections.IDictionary]) { if (@($Value.Keys | Where-Object { $_ -match '(^|_)observed(_|$)' }).Count -gt 0 -and (Test-EstimateMarker $Value)) { return $true }; foreach ($key in $Value.Keys) { if (Test-ObservedEstimate $Value[$key]) { return $true } } } elseif ($Value -is [System.Management.Automation.PSCustomObject]) { if (@($Value.PSObject.Properties.Name | Where-Object { $_ -match '(^|_)observed(_|$)' }).Count -gt 0 -and (Test-EstimateMarker $Value)) { return $true }; foreach ($property in $Value.PSObject.Properties) { if (Test-ObservedEstimate $property.Value) { return $true } } } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { foreach ($item in $Value) { if (Test-ObservedEstimate $item) { return $true } } }; return $false }
$junctionBase = $null
try {
    $cleanFixture = [pscustomobject]@{ catalog=[pscustomobject]@{ entries_observed=3 }; roots=@() }
    $badNested = [pscustomobject]@{ observed_x=[pscustomobject]@{ is_estimate=$true } }
    $badMethod = [pscustomobject]@{ total_observed=123; method='chars/4' }
    Assert-True (-not (Test-ObservedEstimate $cleanFixture)) 'recursive detector accepts clean fixture'
    Assert-True (Test-ObservedEstimate $badNested) 'recursive detector rejects nested is_estimate fixture'
    Assert-True (Test-ObservedEstimate $badMethod) 'recursive detector rejects chars/4 fixture'
    & $scriptPath -OutFile $outA -GeneratedAt '2026-11-12T00:00:00Z'
    & $scriptPath -OutFile $outB -GeneratedAt '2026-11-12T00:00:00Z'
    $aText = [IO.File]::ReadAllText($outA); $bText = [IO.File]::ReadAllText($outB)
    $doc = $aText | ConvertFrom-Json
    Assert-True ($aText -ceq $bText) 'deterministic output'
    Assert-True ($null -ne $doc.catalog -and $doc.roots.Count -ge 1 -and $null -ne $doc.dispatch_context -and $null -ne $doc.estimates -and $doc.unknown.Count -ge 3 -and $null -ne $doc.method -and $null -ne $doc.limitations -and $doc.catalog.entries_observed -ge 1) 'required non-empty blocks'
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
    Assert-True ($doc.catalog.entries_observed -eq @($catalog.skills).Count) 'catalog entry count'
    Assert-True (@($doc.estimates | Where-Object { -not $_.is_estimate -or $_.method -ne 'chars/4' }).Count -eq 0) 'estimate labels'
    Assert-True (-not (Test-ObservedEstimate $doc)) 'no estimates in any observed field'
    Assert-True (@($doc.roots | Where-Object { $_.truncated -eq $true }).Count -eq 0) 'default caps do not truncate current roots'
    $unknownText = $doc.unknown | ConvertTo-Json -Depth 4 -Compress
    Assert-True ($doc.unknown.Count -ge 3 -and $unknownText.Contains('runtime_skill_listing') -and $unknownText.Contains('actual_context_tokens') -and $unknownText.Contains('provider_cache_and_cost')) 'unknowns cover runtime and provider'
    $after = @(Get-ChildItem -LiteralPath $repo -Recurse -File | ForEach-Object FullName | Sort-Object)
    $gitStatusAfter = (& git -C $repo status --porcelain | Out-String).TrimEnd()
    $gitDiffAfter = (& git -C $repo diff --name-only | Out-String).TrimEnd()
    $catalogHashAfter = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
    $skillsHashesAfter = @(Get-ChildItem -LiteralPath (Join-Path $repo 'skills-core') -Recurse -File | ForEach-Object { '{0}:{1}' -f $_.FullName,(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Sort-Object)
    Assert-True ((Compare-Object $before $after).Count -eq 0 -and $catalogHashBefore -eq $catalogHashAfter -and (Compare-Object $skillsHashesBefore $skillsHashesAfter).Count -eq 0 -and $gitStatusBefore -ceq $gitStatusAfter -and $gitDiffBefore -ceq $gitDiffAfter) 'no repo writes or modifications'
    if ($env:OS -eq 'Windows_NT') {
        $junctionBase = Join-Path ([IO.Path]::GetTempPath()) ('skill-junction-test-' + [guid]::NewGuid().ToString('N'))
        $targetDir = Join-Path $junctionBase 'real-skill'; $testRoot = Join-Path $junctionBase 'root'; $linkDir = Join-Path $testRoot 'visible-skill'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $targetDir 'SKILL.md') -Value '# Junction test' -Encoding UTF8
        New-Item -ItemType Junction -Path $linkDir -Target $targetDir | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $testRoot 'visible-skill-alias') -Target $targetDir | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $testRoot 'back-to-root') -Target $testRoot | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $testRoot 'back-to-parent') -Target $junctionBase | Out-Null
        $nestedDir = Join-Path $testRoot 'nested\nested-skill'
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nestedDir 'SKILL.md') -Value '# Nested skill' -Encoding UTF8
        $junctionOut = Join-Path $junctionBase 'junction.json'
        & $scriptPath -Roots $testRoot -OutFile $junctionOut -GeneratedAt '2026-11-12T00:00:00Z' -MaxNodes 100 -MaxDepth 10
        $junctionDoc = Get-Content -LiteralPath $junctionOut -Raw | ConvertFrom-Json
        $rootResult = $junctionDoc.roots[0]
        Assert-True ($rootResult.entry_count_observed -eq 5 -and $rootResult.reparse_point_entries_observed -eq 4 -and $rootResult.skill_md_count_observed -eq 2 -and $rootResult.per_skill.id -contains 'visible-skill') 'junction skill counted once with root/parent cycles and alias'
        Assert-True ($rootResult.per_skill.id -contains 'nested-skill') 'nested skill directory counted'
        Assert-True (-not $rootResult.truncated) 'cycles terminate under generous node cap'
        $capOut = Join-Path $junctionBase 'capped.json'
        & $scriptPath -Roots $testRoot -OutFile $capOut -GeneratedAt '2026-11-12T00:00:00Z' -MaxNodes 1 -MaxDepth 10
        $capDoc = Get-Content -LiteralPath $capOut -Raw | ConvertFrom-Json
        Assert-True ($capDoc.roots[0].truncated -and $capDoc.roots[0].truncated_reason.Count -gt 0) 'node cap reports truncation'
        $depthOut = Join-Path $junctionBase 'depth-capped.json'
        & $scriptPath -Roots $testRoot -OutFile $depthOut -GeneratedAt '2026-11-12T00:00:00Z' -MaxNodes 100 -MaxDepth 0
        $depthDoc = Get-Content -LiteralPath $depthOut -Raw | ConvertFrom-Json
        Assert-True ($depthDoc.roots[0].truncated -and $depthDoc.roots[0].truncated_reason -contains 'max_depth') 'depth cap reports truncation'
        Remove-Item -LiteralPath $junctionBase -Recurse -Force
    } else { Write-Output '[SKIP] Junction/cycle tests require Windows' }
    Write-Output "PASS: $passed/$total"
} finally { Remove-Item $outA,$outB -Force -ErrorAction SilentlyContinue; if ($null -ne $junctionBase -and (Test-Path -LiteralPath $junctionBase)) { Remove-Item -LiteralPath $junctionBase -Recurse -Force -ErrorAction SilentlyContinue } }
