<#!
.SYNOPSIS
    Testes da cadeia canonica de escalonamento (M0/M1, issue #208).
.DESCRIPTION
    Sem rede, sem spawn e sem escrever no repo: fixtures em TEMP.
    PS 5.1, ASCII-only (a seta e construida em runtime).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelChain.ps1')

$script:passed = 0
$script:failed = 0
function Assert-MC {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$policyPath = Join-Path $repoRoot 'source\registry\model-routing-policy.json'
$adapterPath = Join-Path $repoRoot 'source\adapters\opencode-v2.md'
$arrow = [string][char]0x2192

$tmp = Join-Path $env:TEMP ('oo-modelchain-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Write-MCFixture {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-MCPolicy {
    param([string]$Path, [scriptblock]$Mutate)
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    if ($null -ne $Mutate) { & $Mutate $policy }
    Write-MCFixture -Path $Path -Text ($policy | ConvertTo-Json -Depth 100)
}
$canonicalAdapter = 'T3 (Sonnet) ' + $arrow + ' T4 (Opus)' + "`n" +
    'Opus' + $arrow + 'Astra' + "`n" +
    'candidato openai/gpt-6.1-sol de mesmo tier' + "`n" +
    'claude-agent/fable permanece HOLD' + "`n" +
    'nao um degrau entre T3 e Astra' + "`n" +
    '<!-- model-chain:canonical source=model-routing-policy.json -->'

try {
    # 1. Repo real: policy e adapter concordam.
    $real = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $adapterPath
    Assert-MC ([bool]$real.ok) '[MC1] policy real <-> adapter real' ([string]($real.errors -join ' | '))
    Assert-MC (([string]$real.chain.T3Model -ceq 'claude-agent/sonnet')) '[MC2] T3 = sonnet' ([string]$real.chain.T3Model)
    Assert-MC (([string]$real.chain.T4Model -ceq 'claude-agent/opus')) '[MC2] T4 = opus' ([string]$real.chain.T4Model)
    Assert-MC (([string]$real.chain.ExceptionalModel -ceq 'openai/gpt-6-astra')) '[MC2] exceptional = astra' ([string]$real.chain.ExceptionalModel)
    Assert-MC ((@($real.chain.T4AlternativeModels) -contains 'openai/gpt-6.1-sol')) '[MC2] sol = candidato T4' ([string]($real.chain.T4AlternativeModels -join ','))
    Assert-MC ([bool]$real.chain.FablePresent -and [bool]$real.chain.FableGated) '[MC2] fable presente e gated' ''

    # 2. Drift de politica: T3 promovido para Sol.
    $p3 = Join-Path $tmp 'policy-t3-sol.json'
    Write-MCPolicy -Path $p3 -Mutate { param($p) $p.tiers.T3.primary = 'sol' }
    $driftT3 = Test-OrchestrationModelChainConsistency -PolicyPath $p3 -AdapterPath $adapterPath
    Assert-MC (-not [bool]$driftT3.ok) '[MC3] T3=sol e recusado' ''
    Assert-MC ((@($driftT3.errors) -join ' | ') -match 't3-primary-drift') '[MC3] erro nomeia t3-primary-drift' ([string]($driftT3.errors -join ' | '))

    # 3. Drift de excepcional: Astra trocado por Sol.
    $p4 = Join-Path $tmp 'policy-exceptional-sol.json'
    Write-MCPolicy -Path $p4 -Mutate { param($p) $p.tiers.T4.exceptional = 'sol' }
    $driftExc = Test-OrchestrationModelChainConsistency -PolicyPath $p4 -AdapterPath $adapterPath
    Assert-MC (-not [bool]$driftExc.ok) '[MC4] excepcional=sol e recusado' ''
    Assert-MC ((@($driftExc.errors) -join ' | ') -match 't4-exceptional-drift') '[MC4] erro nomeia t4-exceptional-drift' ([string]($driftExc.errors -join ' | '))

    # 4. Adapter sem a cadeia canonica.
    $adapterMissing = Join-Path $tmp 'adapter-missing.md'
    Write-MCFixture -Path $adapterMissing -Text 'Sem cadeia declarada; openai/gpt-6.1-sol aparece apenas como candidato.'
    $missing = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $adapterMissing
    Assert-MC (-not [bool]$missing.ok) '[MC5] adapter sem cadeia e recusado' ''
    Assert-MC ((@($missing.errors) -join ' | ') -match 'adapter-missing-chain') '[MC5] erro nomeia adapter-missing-chain' ([string]($missing.errors -join ' | '))

    # 5. Adapter que promove Sol entre T3 e Astra (com parenteses).
    $adapterDrift = Join-Path $tmp 'adapter-t3-sol.md'
    Write-MCFixture -Path $adapterDrift -Text ('T3 (Sonnet) ' + $arrow + ' Sol ' + $arrow + ' Astra; openai/gpt-6.1-sol')
    $driftAdapter = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $adapterDrift
    Assert-MC (-not [bool]$driftAdapter.ok) '[MC6] adapter T3->Sol e recusado' ''
    Assert-MC ((@($driftAdapter.errors) -join ' | ') -match 'adapter-t3-sol-drift') '[MC6] erro nomeia adapter-t3-sol-drift' ([string]($driftAdapter.errors -join ' | '))

    # 6. Policy ilegivel falha fechado, sem excecao vazando.
    $unreadable = Test-OrchestrationModelChainConsistency -PolicyPath (Join-Path $tmp 'nao-existe.json') -AdapterPath $adapterPath
    Assert-MC (-not [bool]$unreadable.ok) '[MC7] policy ausente falha fechado' ''
    Assert-MC ((@($unreadable.errors) -join ' | ') -match 'policy-unreadable') '[MC7] erro nomeia policy-unreadable' ([string]($unreadable.errors -join ' | '))

    # 7. Adapter ilegivel falha fechado.
    $badAdapter = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath (Join-Path $tmp 'adapter-inexistente.md')
    Assert-MC (-not [bool]$badAdapter.ok) '[MC8] adapter ausente falha fechado' ''
    Assert-MC ((@($badAdapter.errors) -join ' | ') -match 'adapter-unreadable') '[MC8] erro nomeia adapter-unreadable' ([string]($badAdapter.errors -join ' | '))

    # 8. Adapter canonico sem Opus->Astra.
    $noAstra = Join-Path $tmp 'adapter-no-astra.md'
    Write-MCFixture -Path $noAstra -Text ('T3 (Sonnet) ' + $arrow + ' T4 (Opus)' + "`n" + 'openai/gpt-6.1-sol' + "`n" + 'claude-agent/fable permanece HOLD' + "`n" + 'degrau entre T3 e Astra' + "`n" + '<!-- model-chain:canonical -->')
    $rNoAstra = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $noAstra
    Assert-MC (-not [bool]$rNoAstra.ok) '[MC9] falta Opus->Astra e recusado' ''
    Assert-MC ((@($rNoAstra.errors) -join ' | ') -match 'adapter-missing-astra') '[MC9] erro nomeia adapter-missing-astra' ([string]($rNoAstra.errors -join ' | '))

    # 9. Adapter sem o bloco decisorio (frase/marcador ausentes).
    $noBlock = Join-Path $tmp 'adapter-no-block.md'
    Write-MCFixture -Path $noBlock -Text ('T3 (Sonnet) ' + $arrow + ' T4 (Opus)' + "`n" + 'Opus' + $arrow + 'Astra' + "`n" + 'openai/gpt-6.1-sol' + "`n" + 'claude-agent/fable permanece HOLD')
    $rNoBlock = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $noBlock
    Assert-MC (-not [bool]$rNoBlock.ok) '[MC10] adapter sem bloco decisorio e recusado' ''
    Assert-MC ((@($rNoBlock.errors) -join ' | ') -match 'adapter-missing-canonical-block') '[MC10] erro nomeia adapter-missing-canonical-block' ([string]($rNoBlock.errors -join ' | '))

    # 10. Adapter sem declarar Fable em HOLD.
    $noFableHold = Join-Path $tmp 'adapter-no-fable-hold.md'
    Write-MCFixture -Path $noFableHold -Text ($canonicalAdapter -replace 'claude-agent/fable permanece HOLD', 'claude-agent/fable disponivel')
    $rNoFable = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $noFableHold
    Assert-MC (-not [bool]$rNoFable.ok) '[MC11] fable fora de HOLD e recusado' ''
    Assert-MC ((@($rNoFable.errors) -join ' | ') -match 'adapter-fable-not-hold') '[MC11] erro nomeia adapter-fable-not-hold' ([string]($rNoFable.errors -join ' | '))

    # 11. Adapter com T3 -> Sol sem parenteses.
    $t3Sol = Join-Path $tmp 'adapter-t3-sol-plain.md'
    Write-MCFixture -Path $t3Sol -Text ($canonicalAdapter + "`n" + 'T3 ' + $arrow + ' Sol ' + $arrow + ' Astra')
    $rT3Sol = Test-OrchestrationModelChainConsistency -PolicyPath $policyPath -AdapterPath $t3Sol
    Assert-MC (-not [bool]$rT3Sol.ok) '[MC12] adapter T3->Sol (sem parenteses) e recusado' ''
    Assert-MC ((@($rT3Sol.errors) -join ' | ') -match 'adapter-t3-sol-drift') '[MC12] erro nomeia adapter-t3-sol-drift' ([string]($rT3Sol.errors -join ' | '))

    # 12. Drift de T4 primary.
    $p10 = Join-Path $tmp 'policy-t4-sonnet.json'
    Write-MCPolicy -Path $p10 -Mutate { param($p) $p.tiers.T4.primary = 'claude_sonnet' }
    $rT4 = Test-OrchestrationModelChainConsistency -PolicyPath $p10 -AdapterPath $adapterPath
    Assert-MC ((@($rT4.errors) -join ' | ') -match 't4-primary-drift') '[MC13] T4 primary divergente e recusado' ([string]($rT4.errors -join ' | '))

    # 13. Policy T4 alternatives sem Sol.
    $p11 = Join-Path $tmp 'policy-no-sol.json'
    Write-MCPolicy -Path $p11 -Mutate { param($p) $p.tiers.T4.alternatives = @('claude_opus') }
    $rNoSol = Test-OrchestrationModelChainConsistency -PolicyPath $p11 -AdapterPath $adapterPath
    Assert-MC ((@($rNoSol.errors) -join ' | ') -match 't4-sol-candidate-missing') '[MC14] Sol removido de alternatives e recusado' ([string]($rNoSol.errors -join ' | '))

    # 14. Policy promove Fable para alternatives.
    $p12 = Join-Path $tmp 'policy-fable-chain.json'
    Write-MCPolicy -Path $p12 -Mutate { param($p) $p.tiers.T4.alternatives = @($p.tiers.T4.alternatives) + @('claude_fable') }
    $rFable = Test-OrchestrationModelChainConsistency -PolicyPath $p12 -AdapterPath $adapterPath
    Assert-MC (-not [bool]$rFable.ok) '[MC15] Fable promovido e recusado' ''
    Assert-MC ((@($rFable.errors) -join ' | ') -match 'fable-in-chain') '[MC15] erro nomeia fable-in-chain' ([string]($rFable.errors -join ' | '))

    # 15. Policy remove o gate de Fable.
    $p13 = Join-Path $tmp 'policy-fable-ungated.json'
    Write-MCPolicy -Path $p13 -Mutate { param($p) $p.models.claude_fable.gated = $false }
    $rGate = Test-OrchestrationModelChainConsistency -PolicyPath $p13 -AdapterPath $adapterPath
    Assert-MC (-not [bool]$rGate.ok) '[MC16] Fable sem gate e recusado' ''
    Assert-MC ((@($rGate.errors) -join ' | ') -match 'fable-gate-missing') '[MC16] erro nomeia fable-gate-missing' ([string]($rGate.errors -join ' | '))
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('MODEL-CHAIN: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
