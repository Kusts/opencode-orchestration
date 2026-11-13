<#!
.SYNOPSIS
    Testes de metricas de cache (M4, issue #11).
.DESCRIPTION
    Parser puro; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationCacheMetrics.ps1')

$script:passed = 0
$script:failed = 0
function Assert-CM {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

try {
    $full = '{"data":{"tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":9000,"write":300}},"cost":0.42}}'
    $m = Get-OrchestrationCacheMetrics -Session $full
    Assert-CM ([bool]$m.ok) '[CM1] fixture completa parseia' ([string]$m.error)
    Assert-CM (([int64]$m.input_tokens -eq 1000)) '[CM1] input preservado' ([string]$m.input_tokens)
    Assert-CM (([int64]$m.output_tokens -eq 200)) '[CM1] output preservado' ([string]$m.output_tokens)
    Assert-CM (([int64]$m.cache_read_tokens -eq 9000)) '[CM1] cache read preservado' ([string]$m.cache_read_tokens)
    Assert-CM (([int64]$m.cache_write_tokens -eq 300)) '[CM1] cache write preservado' ([string]$m.cache_write_tokens)
    Assert-CM (([int64]$m.prompt_tokens -eq 1000)) '[CM1] prompt = input' ([string]$m.prompt_tokens)
    Assert-CM (([double]$m.cache_read_ratio -gt 0.89) -and ([double]$m.cache_read_ratio -lt 0.91)) '[CM1] ratio = read/(input+read)' ([string]$m.cache_read_ratio)
    Assert-CM (([double]$m.cost -eq 0.42) -and ([string]$m.cost_source -ceq 'reported')) '[CM1] custo reportado' ([string]$m.cost)

    $obj = $full | ConvertFrom-Json
    $m2 = Get-OrchestrationCacheMetrics -Session $obj
    Assert-CM ([bool]$m2.ok -and [int64]$m2.input_tokens -eq 1000) '[CM2] aceita objeto' ([string]$m2.error)

    $noCache = '{"tokens":{"input":10,"output":1}}'
    $m3 = Get-OrchestrationCacheMetrics -Session $noCache
    Assert-CM ([bool]$m3.ok) '[CM3] ausencia de cache nao quebra' ([string]$m3.error)
    Assert-CM (([string]$m3.cache_read_tokens -ceq 'UNKNOWN')) '[CM3] cache read UNKNOWN' ([string]$m3.cache_read_tokens)
    Assert-CM (([string]$m3.cache_read_ratio -ceq 'UNKNOWN')) '[CM3] ratio UNKNOWN' ([string]$m3.cache_read_ratio)

    $zero = '{"tokens":{"input":0,"output":0,"cache":{"read":0,"write":0}},"cost":0}'
    $m4 = Get-OrchestrationCacheMetrics -Session $zero
    Assert-CM ([bool]$m4.ok) '[CM4] zeros parseiam' ([string]$m4.error)
    Assert-CM (([string]$m4.cache_read_ratio -ceq 'UNKNOWN')) '[CM4] denominador zero nao divide' ([string]$m4.cache_read_ratio)
    Assert-CM (([string]$m4.cost -ceq 'UNKNOWN') -and ([string]$m4.cost_source -ceq 'unknown')) '[CM4] custo zero nao vira zero' ([string]$m4.cost)

    $noInput = '{"tokens":{"output":5}}'
    $m5 = Get-OrchestrationCacheMetrics -Session $noInput
    Assert-CM ((-not [bool]$m5.ok) -and ([string]$m5.error -ceq 'CACHE_METRICS_INPUT_MISSING')) '[CM5] input ausente falha fechado' ([string]$m5.error)

    $bad = Get-OrchestrationCacheMetrics -Session 'nao-e-json'
    Assert-CM ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'CACHE_METRICS_INVALID')) '[CM6] JSON invalido recusado' ([string]$bad.error)

    $badTokens = Get-OrchestrationCacheMetrics -Session '{"cost":1}'
    Assert-CM ((-not [bool]$badTokens.ok) -and ([string]$badTokens.error -ceq 'CACHE_METRICS_TOKENS_MISSING')) '[CM7] tokens ausentes recusados' ([string]$badTokens.error)
}
finally { }

Write-Host ''
Write-Host ('CACHE-METRICS: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
