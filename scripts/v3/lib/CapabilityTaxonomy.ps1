<#!
.SYNOPSIS
    V3 Capability taxonomy: vocabulario versionado com matching deterministico.
.DESCRIPTION
    Biblioteca dot-sourceable (le apenas source/registry/capability-policy.json
    via Import-CapabilityPolicy). A taxonomia e a unica fonte do vocabulario
    valido (plano §5.2): capability fora da lista e `unknown` e nunca e
    selecionavel/executavel. Este modulo nao decide permissao.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Import-CapabilityPolicy {
    <#
    .SYNOPSIS
        Le source/registry/capability-policy.json a partir da raiz do repo.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )
    $candidate = Join-Path $RepoRoot 'source\registry\capability-policy.json'
    if (-not (Test-Path -LiteralPath $candidate)) {
        $fallback = Join-Path (Split-Path -Parent $RepoRoot) 'source\registry\capability-policy.json'
        if (Test-Path -LiteralPath $fallback) {
            $candidate = $fallback
        }
        else {
            throw ("capability-policy.json not found at '{0}'." -f $candidate)
        }
    }
    $policyText = [IO.File]::ReadAllText($candidate, [Text.UTF8Encoding]::new($false))
    return ($policyText | ConvertFrom-Json)
}

function Get-CanonicalCapabilityList {
    <#
    .SYNOPSIS
        Retorna os IDs canonicos (chaves de producers) ordenados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Policy
    )
    $producers = $Policy.capability_taxonomy.producers
    if ($null -eq $producers) {
        return @()
    }
    $names = @($producers.PSObject.Properties | ForEach-Object { $_.Name })
    [Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

function Test-CanonicalCapability {
    <#
    .SYNOPSIS
        Matching exato (case-sensitive): true somente se o ID esta na lista.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Policy,
        [Parameter(Mandatory = $true)]
        [string]$Id
    )
    $list = @(Get-CanonicalCapabilityList -Policy $Policy)
    return ($list -ccontains $Id)
}

function Get-CapabilityProducer {
    <#
    .SYNOPSIS
        Retorna os produtores autorizados do ID, ou vazio se nao canonico.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Policy,
        [Parameter(Mandatory = $true)]
        [string]$Id
    )
    if (-not (Test-CanonicalCapability -Policy $Policy -Id $Id)) {
        return @()
    }
    $producers = $Policy.capability_taxonomy.producers
    $entry = $producers.PSObject.Properties | Where-Object { $_.Name -ceq $Id } | Select-Object -First 1
    if ($null -eq $entry -or $null -eq $entry.Value) {
        return @()
    }
    return @($entry.Value)
}

function Test-CapabilityProducerAuthorized {
    <#
    .SYNOPSIS
        True somente se o ID e canonico e o produtor esta listado para ele.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Policy,
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Producer
    )
    $allowed = @(Get-CapabilityProducer -Policy $Policy -Id $Id)
    return ($allowed -ccontains $Producer)
}

function Get-CapabilityRisk {
    <#
    .SYNOPSIS
        Retorna o risco curado da risk_policy, ou 'unknown' se ausente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Policy,
        [Parameter(Mandatory = $true)]
        [string]$Id
    )
    $map = $Policy.risk_policy.capability_risk
    if ($null -ne $map) {
        $entry = $map.PSObject.Properties | Where-Object { $_.Name -ceq $Id } | Select-Object -First 1
        if ($null -ne $entry -and $null -ne $entry.Value) {
            return [string]$entry.Value
        }
    }
    return 'unknown'
}
