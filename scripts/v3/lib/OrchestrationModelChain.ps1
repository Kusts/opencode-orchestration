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

    if ($chain.T3Key -cne 'claude_sonnet') {
        [void]$errors.Add('t3-primary-drift: esperado claude_sonnet, encontrado ' + $chain.T3Key)
    }
    if ($chain.T4Key -cne 'claude_opus') {
        [void]$errors.Add('t4-primary-drift: esperado claude_opus, encontrado ' + $chain.T4Key)
    }
    if ($chain.ExceptionalKey -cne 'astra') {
        [void]$errors.Add('t4-exceptional-drift: esperado astra, encontrado ' + $chain.ExceptionalKey)
    }
    if (@($chain.T4AlternativeKeys) -notcontains 'sol') {
        [void]$errors.Add('t4-sol-candidate-missing: sol deve ser candidato de mesmo tier T4')
    }
    if ($chain.T3Model -cne 'claude-agent/sonnet') {
        [void]$errors.Add('t3-model-drift: esperado claude-agent/sonnet, encontrado ' + [string]$chain.T3Model)
    }
    if ($chain.T4Model -cne 'claude-agent/opus') {
        [void]$errors.Add('t4-model-drift: esperado claude-agent/opus, encontrado ' + [string]$chain.T4Model)
    }
    if ($chain.ExceptionalModel -cne 'openai/gpt-6-astra') {
        [void]$errors.Add('exceptional-model-drift: esperado openai/gpt-6-astra, encontrado ' + [string]$chain.ExceptionalModel)
    }
    if (@($chain.T4AlternativeModels) -notcontains 'openai/gpt-6.1-sol') {
        [void]$errors.Add('sol-model-drift: esperado openai/gpt-6.1-sol em tiers.T4.alternatives')
    }
    if (-not [bool]$chain.FablePresent) {
        [void]$errors.Add('fable-missing: claude_fable deve existir e permanecer em HOLD')
    }
    elseif (-not [bool]$chain.FableGated) {
        [void]$errors.Add('fable-gate-missing: claude_fable deve manter gated=true')
    }
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
    if (-not $adapter.Contains('openai/gpt-6.1-sol')) {
        [void]$errors.Add('adapter-missing-sol-candidate: falta openai/gpt-6.1-sol como candidato T4')
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
