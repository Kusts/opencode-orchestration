<#!
.SYNOPSIS
    Cadeia canonica de escalonamento de modelos (policy <-> adapter V2).
.DESCRIPTION
    Fonte da verdade: source/registry/model-routing-policy.json.
    O adapter V2 e um espelho documental: divergencia entre os dois e drift,
    nunca uma segunda decisao. Leitura pura, sem rede e sem escrita.
    PS 5.1 compativel, ASCII-only no codigo (a seta e construida em runtime).
#>

function Read-OrchestrationModelChainJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Get-OrchestrationModelChainProperty {
    param($Node, [string]$Name)
    if ($null -eq $Node -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
    $prop = $Node.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-OrchestrationModelIdForKey {
    param($Models, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    $model = Get-OrchestrationModelChainProperty -Node $Models -Name $Key
    if ($null -eq $model) { return $null }
    return [string](Get-OrchestrationModelChainProperty -Node $model -Name 'model_id')
}

function Get-OrchestrationCanonicalModelChain {
    <#
    .SYNOPSIS
        Extrai a cadeia T3 -> T4 -> excepcional declarada pela politica.
    .DESCRIPTION
        Retorna chaves e model_ids declarados, sem inventar fallback: o que a
        politica nao declarar volta como $null/vazio.
    #>
    param([Parameter(Mandatory = $true)][string]$PolicyPath)

    $policy = Read-OrchestrationModelChainJson -Path $PolicyPath
    $tiers = Get-OrchestrationModelChainProperty -Node $policy -Name 'tiers'
    $models = Get-OrchestrationModelChainProperty -Node $policy -Name 'models'
    if ($null -eq $tiers) { throw 'policy sem bloco tiers' }
    if ($null -eq $models) { throw 'policy sem bloco models' }

    $t3 = Get-OrchestrationModelChainProperty -Node $tiers -Name 'T3'
    $t4 = Get-OrchestrationModelChainProperty -Node $tiers -Name 'T4'
    if ($null -eq $t3) { throw 'policy sem tiers.T3' }
    if ($null -eq $t4) { throw 'policy sem tiers.T4' }

    $t3Key = [string](Get-OrchestrationModelChainProperty -Node $t3 -Name 'primary')
    $t4Key = [string](Get-OrchestrationModelChainProperty -Node $t4 -Name 'primary')
    $exceptionalKey = [string](Get-OrchestrationModelChainProperty -Node $t4 -Name 'exceptional')
    $altRaw = Get-OrchestrationModelChainProperty -Node $t4 -Name 'alternatives'
    $altKeys = @()
    if ($null -ne $altRaw) { $altKeys = @($altRaw | ForEach-Object { [string]$_ }) }

    $fable = Get-OrchestrationModelChainProperty -Node $models -Name 'claude_fable'
    $fableGated = $false
    if ($null -ne $fable) {
        $fableGatedRaw = Get-OrchestrationModelChainProperty -Node $fable -Name 'gated'
        if ($null -ne $fableGatedRaw) { $fableGated = [bool]$fableGatedRaw }
    }
    $astraProofGated = [bool](Get-OrchestrationModelChainProperty -Node (Get-OrchestrationModelChainProperty -Node $policy -Name 'runtime_verification') -Name 'require_failure_receipt_for_astra')
    $exceptionalModel = Get-OrchestrationModelChainProperty -Node $models -Name $exceptionalKey
    $exceptionalBudgetRequired = [bool](Get-OrchestrationModelChainProperty -Node (Get-OrchestrationModelChainProperty -Node $exceptionalModel -Name 'cost_profile') -Name 'exceptional_budget_required')
    $primaryTierProfiles = @(
        @(Get-OrchestrationModelChainProperty -Node (Get-OrchestrationModelChainProperty -Node $models -Name $t3Key) -Name 'tier_profiles'),
        @(Get-OrchestrationModelChainProperty -Node (Get-OrchestrationModelChainProperty -Node $models -Name $t4Key) -Name 'tier_profiles')
    )
    $alternativeTierProfiles = @($altKeys | ForEach-Object {
        $alternative = Get-OrchestrationModelChainProperty -Node $models -Name $_
        @(Get-OrchestrationModelChainProperty -Node $alternative -Name 'tier_profiles')
    })

    return [pscustomobject]@{
        PolicyVersion      = [string](Get-OrchestrationModelChainProperty -Node $policy -Name 'policy_version')
        T3Key              = $t3Key
        T3Model            = Get-OrchestrationModelIdForKey -Models $models -Key $t3Key
        T4Key              = $t4Key
        T4Model            = Get-OrchestrationModelIdForKey -Models $models -Key $t4Key
        ExceptionalKey     = $exceptionalKey
        ExceptionalModel   = Get-OrchestrationModelIdForKey -Models $models -Key $exceptionalKey
        T4AlternativeKeys  = $altKeys
        T4AlternativeModels = @($altKeys | ForEach-Object { Get-OrchestrationModelIdForKey -Models $models -Key $_ })
        T4AlternativeTierProfiles = $alternativeTierProfiles
        ExceptionalProofGated = $astraProofGated
        ExceptionalBudgetRequired = $exceptionalBudgetRequired
        PrimaryTierProfiles = $primaryTierProfiles
        FablePresent       = ($null -ne $fable)
        FableGated         = $fableGated
    }
}

function Test-OrchestrationModelChainConsistency {
    <#
    .SYNOPSIS
        Verifica se a politica e o adapter V2 descrevem a mesma cadeia.
    .DESCRIPTION
        Baseline decidido em 2026-11-10 (issue #208): T3 Sonnet -> T4 Opus ->
        Astra excepcional. Sol e candidato de mesmo tier T4, nunca degrau
        entre T3 e Astra. Fable permanece HOLD. Mudar o baseline exige mudar
        politica, adapter e este contrato de forma deliberada.
    .OUTPUTS
        Objeto com ok, errors e chain.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PolicyPath,
        [Parameter(Mandatory = $true)][string]$AdapterPath
    )

    $errors = New-Object System.Collections.ArrayList
    $chain = $null
    try {
        $chain = Get-OrchestrationCanonicalModelChain -PolicyPath $PolicyPath
    }
    catch {
        [void]$errors.Add('policy-unreadable: ' + $_.Exception.Message)
        return [pscustomobject]@{ ok = $false; errors = @($errors); chain = $null }
    }

    if ([string]::IsNullOrWhiteSpace([string]$chain.T3Key) -or [string]::IsNullOrWhiteSpace([string]$chain.T3Model) -or
        [string]::IsNullOrWhiteSpace([string]$chain.T4Key) -or [string]::IsNullOrWhiteSpace([string]$chain.T4Model)) {
        [void]$errors.Add('tier-primary-missing: T3 e T4 devem declarar modelos primarios')
    }
    elseif (($chain.T3Key -ceq $chain.T4Key) -or ($chain.T3Model -ceq $chain.T4Model)) {
        [void]$errors.Add('tier-primary-not-distinct: T3 e T4 devem ser distintos')
    }
    if (@($chain.PrimaryTierProfiles[0]) -notcontains 'T3') {
        [void]$errors.Add('t3-primary-drift: modelo primario nao pertence ao tier T3')
    }
    if (@($chain.PrimaryTierProfiles[1]) -notcontains 'T4') {
        [void]$errors.Add('t4-primary-drift: modelo primario nao pertence ao tier T4')
    }
    if ([string]::IsNullOrWhiteSpace([string]$chain.ExceptionalKey) -or [string]::IsNullOrWhiteSpace([string]$chain.ExceptionalModel)) {
        [void]$errors.Add('t4-exceptional-missing: T4 deve declarar modelo excepcional')
    }
    if (-not [bool]$chain.ExceptionalProofGated) {
        [void]$errors.Add('exceptional-proof-gate-missing: modelo excepcional deve exigir prova de falha')
    }
    if (-not [bool]$chain.ExceptionalBudgetRequired) {
        [void]$errors.Add('t4-exceptional-drift: modelo excepcional nao esta marcado como excepcional pela policy')
    }
    $t4AlternativeIndex = -1
    for ($i = 0; $i -lt @($chain.T4AlternativeModels).Count; $i++) {
        if (-not [string]::IsNullOrWhiteSpace([string]$chain.T4AlternativeModels[$i]) -and
            $chain.T4AlternativeKeys[$i] -cne $chain.T4Key -and
            $chain.T4AlternativeKeys[$i] -cne $chain.T3Key -and
            @($chain.T4AlternativeTierProfiles[$i]) -contains 'T4') {
            $t4AlternativeIndex = $i
            break
        }
    }
    if ($t4AlternativeIndex -lt 0) {
        [void]$errors.Add('t4-sol-candidate-missing: tiers.T4 deve declarar candidato alternativo same-tier')
    }
    if (-not [bool]$chain.FablePresent) {
        [void]$errors.Add('fable-missing: claude_fable deve existir e permanecer em HOLD')
    }
    elseif (-not [bool]$chain.FableGated) {
        [void]$errors.Add('fable-gate-missing: claude_fable deve manter gated=true')
    }
    # claude_fable is the policy's named HOLD model; the ID is needed to test
    # that this specifically gated model never appears in the primary chain.
    $fableInChain = (@($chain.T4AlternativeKeys) -contains 'claude_fable') -or
                    ($chain.T3Key -ceq 'claude_fable') -or
                    ($chain.T4Key -ceq 'claude_fable') -or
                    ($chain.ExceptionalKey -ceq 'claude_fable')
    if ($fableInChain) {
        [void]$errors.Add('fable-in-chain: claude_fable nao pode ocupar primary/exceptional/alternatives')
    }

    $adapter = $null
    try {
        $adapter = [IO.File]::ReadAllText($AdapterPath, [Text.Encoding]::UTF8)
    }
    catch {
        [void]$errors.Add('adapter-unreadable: ' + $_.Exception.Message)
        return [pscustomobject]@{ ok = $false; errors = @($errors); chain = $chain }
    }

    $arrow = [string][char]0x2192
    $arrowEsc = [regex]::Escape($arrow)
    $canonicalT3T4 = 'T3 (Sonnet) ' + $arrow + ' T4 (Opus)'
    $canonicalOpusAstra = 'Opus' + $arrow + 'Astra'

    if (-not $adapter.Contains($canonicalT3T4)) {
        [void]$errors.Add('adapter-missing-chain: falta "' + $canonicalT3T4 + '"')
    }
    if (-not $adapter.Contains($canonicalOpusAstra)) {
        [void]$errors.Add('adapter-missing-astra: falta "' + $canonicalOpusAstra + '"')
    }
    foreach ($alternativeModel in @($chain.T4AlternativeModels)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alternativeModel) -and -not $adapter.Contains([string]$alternativeModel)) {
            [void]$errors.Add('adapter-missing-t4-candidate: falta candidato same-tier T4 da policy: ' + [string]$alternativeModel)
        }
    }
    if (-not $adapter.Contains('<!-- model-chain:canonical')) {
        [void]$errors.Add('adapter-missing-canonical-block: falta o marcador <!-- model-chain:canonical')
    }
    if (-not $adapter.Contains('degrau entre T3 e Astra')) {
        [void]$errors.Add('adapter-missing-canonical-block: falta a frase decisoria "degrau entre T3 e Astra"')
    }
    $fableHoldPattern = '(?is)fable.{0,160}?HOLD'
    if ($adapter -notmatch $fableHoldPattern) {
        [void]$errors.Add('adapter-fable-not-hold: adapter nao declara fable em HOLD')
    }
    $t3SolPatterns = @(
        ('T3\s*\(Sonnet\)\s*' + $arrowEsc + '\s*Sol'),
        ('T3\s*' + $arrowEsc + '\s*Sol'),
        ('(?i)Sonnet\s*' + $arrowEsc + '\s*Sol')
    )
    foreach ($pat in $t3SolPatterns) {
        if ($adapter -match $pat) {
            [void]$errors.Add('adapter-t3-sol-drift: adapter promove Sol a degrau a partir de T3/Sonnet')
            break
        }
    }

    return [pscustomobject]@{
        ok     = ($errors.Count -eq 0)
        errors = @($errors)
        chain  = $chain
    }
}
