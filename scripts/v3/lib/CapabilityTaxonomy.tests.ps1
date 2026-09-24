<#!
.SYNOPSIS
    Testes standalone do CapabilityTaxonomy.ps1 (Phase 1).
.DESCRIPTION
    Roda com `pwsh -NoProfile -File <este-arquivo>`; termina com exit 0/1.
    Aserções DINÂMICAS contra source/registry/capability-policy.json
    (via Import-CapabilityPolicy): o teste acompanha o crescimento da
    taxonomia em vez de fixar a contagem antiga de 15 classes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $PSScriptRoot 'CapabilityTaxonomy.ps1'
. $libPath

$passed = 0
$failed = 0

function Assert-TaxonomyTrue {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host ("PASS {0}" -f $Name)
        $script:passed++
    }
    else {
        Write-Host ("FAIL {0}" -f $Name)
        $script:failed++
    }
}

try {
    $policyRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $policy = Import-CapabilityPolicy -RepoRoot $policyRoot
    Assert-TaxonomyTrue ($null -ne $policy.capability_taxonomy) 'policy loads with capability_taxonomy'

    $defaultPolicy = Import-CapabilityPolicy
    Assert-TaxonomyTrue ($null -ne $defaultPolicy.capability_taxonomy) 'policy loads with default RepoRoot'

    $producerKeys = @($policy.capability_taxonomy.producers.PSObject.Properties | ForEach-Object { $_.Name })
    $list = @(Get-CanonicalCapabilityList -Policy $policy)
    $missing = @($producerKeys | Where-Object { $list -cnotcontains $_ })
    $extra = @($list | Where-Object { $producerKeys -cnotcontains $_ })
    Assert-TaxonomyTrue (($list.Count -eq $producerKeys.Count) -and ($missing.Count -eq 0) -and ($extra.Count -eq 0)) 'canonical list equals producers key set'

    $sorted = @($list | Sort-Object)
    $ordered = @()
    for ($index = 0; $index -lt $list.Count; $index++) {
        if ($list[$index] -cne $sorted[$index]) { $ordered = @('out-of-order'); break }
    }
    Assert-TaxonomyTrue ($ordered.Count -eq 0) 'canonical list is sorted'

    $allCanonical = $true
    foreach ($key in @($producerKeys)) {
        if (-not (Test-CanonicalCapability -Policy $policy -Id $key)) { $allCanonical = $false; break }
    }
    Assert-TaxonomyTrue $allCanonical 'every producer key is canonical'
    Assert-TaxonomyTrue (Test-CanonicalCapability -Policy $policy -Id 'database.read') 'database.read is canonical'
    Assert-TaxonomyTrue (-not (Test-CanonicalCapability -Policy $policy -Id 'teleportation.reverse')) 'clearly-unknown id is not canonical'
    Assert-TaxonomyTrue (-not (Test-CanonicalCapability -Policy $policy -Id 'code')) 'bare namespace is not canonical'
    Assert-TaxonomyTrue (-not (Test-CanonicalCapability -Policy $policy -Id 'database.unknown')) 'unknown capability is not canonical'
    Assert-TaxonomyTrue (-not (Test-CanonicalCapability -Policy $policy -Id 'Database.Read')) 'matching is exact (case-sensitive)'

    $dbWrite = @((Get-CapabilityProducer -Policy $policy -Id 'database.write'))
    Assert-TaxonomyTrue (($dbWrite.Count -eq 1) -and ($dbWrite -ccontains 'mcp-policy')) 'database.write producers are exactly mcp-policy'
    $prodDestr = @((Get-CapabilityProducer -Policy $policy -Id 'production.destructive'))
    Assert-TaxonomyTrue (($prodDestr.Count -eq 1) -and ($prodDestr -ccontains 'mcp-policy')) 'production.destructive producers are exactly mcp-policy'
    $bounded = @(Get-CapabilityProducer -Policy $policy -Id 'code.bounded-edit')
    Assert-TaxonomyTrue (($bounded -ccontains 'agent-orchestration') -and ($bounded -ccontains 'skill-policy')) 'code.bounded-edit producers include agent-orchestration and skill-policy'
    $deploys = @(Get-CapabilityProducer -Policy $policy -Id 'infrastructure.deployment')
    Assert-TaxonomyTrue ($deploys -ccontains 'agent-orchestration') 'infrastructure.deployment producers include agent-orchestration'
    Assert-TaxonomyTrue (@(Get-CapabilityProducer -Policy $policy -Id 'database.unknown').Count -eq 0) 'unknown id returns empty producers'

    Assert-TaxonomyTrue (Test-CapabilityProducerAuthorized -Policy $policy -Id 'database.read' -Producer 'mcp-policy') 'mcp-policy may produce database.read'
    Assert-TaxonomyTrue (-not (Test-CapabilityProducerAuthorized -Policy $policy -Id 'code.bounded-edit' -Producer 'mcp-policy')) 'mcp-policy may not produce code.bounded-edit'
    Assert-TaxonomyTrue (-not (Test-CapabilityProducerAuthorized -Policy $policy -Id 'database.write' -Producer 'agent-orchestration')) 'database.write is mcp-policy only'
    Assert-TaxonomyTrue (Test-CapabilityProducerAuthorized -Policy $policy -Id 'code.bounded-edit' -Producer 'agent-orchestration') 'agent-orchestration may produce code.bounded-edit'
    Assert-TaxonomyTrue (-not (Test-CapabilityProducerAuthorized -Policy $policy -Id 'database.unknown' -Producer 'mcp-policy')) 'unknown id authorizes no producer'

    Assert-TaxonomyTrue ((Get-CapabilityRisk -Policy $policy -Id 'database.migration') -ceq 'high') 'database.migration risk is high'
    $riskKeys = @()
    if ($null -ne $policy.risk_policy.capability_risk) {
        $riskKeys = @($policy.risk_policy.capability_risk.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $noRisk = @($producerKeys | Where-Object { $riskKeys -cnotcontains $_ } | Select-Object -First 1)
    if ($noRisk.Count -eq 0) {
        Assert-TaxonomyTrue $false 'policy has at least one producer key without a risk entry'
    }
    else {
        Assert-TaxonomyTrue ((Get-CapabilityRisk -Policy $policy -Id $noRisk[0]) -ceq 'unknown') ('risk is unknown for class without entry ({0})' -f $noRisk[0])
    }
    Assert-TaxonomyTrue ((Get-CapabilityRisk -Policy $policy -Id 'database.unknown') -ceq 'unknown') 'unknown id risk is unknown'
}
catch {
    Write-Host ("FAIL unexpected error: {0}" -f $_)
    exit 1
}

Write-Host ("CapabilityTaxonomy: {0} / {1} tests passed" -f $passed, ($passed + $failed))
if ($failed -gt 0) { exit 1 }
exit 0
