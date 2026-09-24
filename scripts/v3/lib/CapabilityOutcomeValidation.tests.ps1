$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'CapabilityOutcomeValidation.ps1')

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function New-Case {
    param([string[]]$Expected, [string[]]$Acceptable, [string[]]$Forbidden, [bool]$DetFirst, [bool]$Direct)
    return [PSCustomObject]@{
        id = 'case'; category = 'x'; task_type = 'implementation'; domain = 'backend'
        expected_agents = $Expected; acceptable_agents = $Acceptable; forbidden_agents = $Forbidden
        deterministic_first = $DetFirst; expect_direct = $Direct
    }
}
function New-Decision {
    param([string]$Selected, [string]$Candidate, [string]$Expected, [bool]$Accepted, [bool]$Direct, [bool]$Fallback, [string]$Reason, [string]$Mode, [bool]$Blocked)
    return [PSCustomObject]@{
        selected_agent = $Selected; router_candidate = $Candidate; expected_agent = $Expected
        accepted = $Accepted; direct = $Direct; fallback_used = $Fallback; fallback_reason = $Reason
        mode = $Mode; blocked = $Blocked; disagreement = $false; envelope_category = ''; envelope_allowed = $true
        confidence_class = 'explicit'
    }
}

try {
    # 1) aceito no esperado => GOOD
    $c = New-Case -Expected @('backend-engineer') -Acceptable @('backend-engineer') -Forbidden @() -DetFirst $false -Direct $false
    $d = New-Decision -Selected 'backend-engineer' -Candidate 'backend-engineer' -Expected 'backend-engineer' -Accepted $true -Direct $false -Fallback $false -Reason '' -Mode 'active' -Blocked $false
    $r = Get-OutcomeCaseClassification -Case $c -Decision $d
    Assert-That ($r.Classification -ceq 'GOOD_ROUTE') 'aceito no esperado => GOOD_ROUTE' $r.Classification
    Assert-That ((Get-OutcomeValidationRouteMode -Decision $d) -ceq 'ROUTER') 'route_mode ROUTER' (Get-OutcomeValidationRouteMode -Decision $d)

    # 2) aceito em alternativo aceitavel => ACCEPTABLE
    $d2 = New-Decision -Selected 'skeptic' -Candidate 'skeptic' -Expected 'engineering-advisor' -Accepted $true -Direct $false -Fallback $false -Reason '' -Mode 'active' -Blocked $false
    $c2 = New-Case -Expected @('engineering-advisor') -Acceptable @('engineering-advisor', 'skeptic') -Forbidden @() -DetFirst $false -Direct $false
    $r2 = Get-OutcomeCaseClassification -Case $c2 -Decision $d2
    Assert-That ($r2.Classification -ceq 'ACCEPTABLE_ROUTE') 'aceito alternativo => ACCEPTABLE_ROUTE' $r2.Classification

    # 3) selecao proibida => WRONG + safety
    $c3 = New-Case -Expected @('coder') -Acceptable @('coder') -Forbidden @('security-reviewer') -DetFirst $false -Direct $false
    $d3 = New-Decision -Selected 'security-reviewer' -Candidate 'security-reviewer' -Expected 'coder' -Accepted $true -Direct $false -Fallback $false -Reason '' -Mode 'active' -Blocked $false
    $r3 = Get-OutcomeCaseClassification -Case $c3 -Decision $d3
    Assert-That (($r3.Classification -ceq 'WRONG_ROUTE') -and ([bool]$r3.SafetyViolation)) 'forbidden selecionado => WRONG + safety' $r3.Classification

    # 4) Router controlando categoria deterministic-first => WRONG + safety
    $c4 = New-Case -Expected @('debugger') -Acceptable @('debugger') -Forbidden @() -DetFirst $true -Direct $false
    $d4 = New-Decision -Selected 'reviewer' -Candidate 'reviewer' -Expected 'debugger' -Accepted $true -Direct $false -Fallback $false -Reason '' -Mode 'active' -Blocked $false
    $r4 = Get-OutcomeCaseClassification -Case $c4 -Decision $d4
    Assert-That (($r4.Classification -ceq 'WRONG_ROUTE') -and ([bool]$r4.SafetyViolation)) 'deterministic-first controlado => WRONG + safety' $r4.Classification

    # 5) deterministic-first preservado => GOOD
    $d5 = New-Decision -Selected 'debugger' -Candidate 'reviewer' -Expected 'debugger' -Accepted $false -Direct $false -Fallback $true -Reason 'category_not_in_stage1' -Mode 'fallback' -Blocked $false
    $r5 = Get-OutcomeCaseClassification -Case $c4 -Decision $d5
    Assert-That ($r5.Classification -ceq 'GOOD_ROUTE') 'deterministic-first preservado => GOOD_ROUTE' $r5.Classification

    # 6) trivial direct => GOOD
    $c6 = New-Case -Expected @('build') -Acceptable @('build') -Forbidden @() -DetFirst $false -Direct $true
    $d6 = New-Decision -Selected 'build' -Candidate '' -Expected 'coder' -Accepted $false -Direct $true -Fallback $false -Reason '' -Mode 'deterministic' -Blocked $false
    $r6 = Get-OutcomeCaseClassification -Case $c6 -Decision $d6
    Assert-That (($r6.Classification -ceq 'GOOD_ROUTE') -and ((Get-OutcomeValidationRouteMode -Decision $d6) -ceq 'DIRECT')) 'trivial direct => GOOD/DIRECT' $r6.Classification

    # 7) fallback com candidato aceitavel => SUBOPTIMAL
    $c7 = New-Case -Expected @('reviewer') -Acceptable @('reviewer', 'backend-engineer') -Forbidden @() -DetFirst $false -Direct $false
    $d7 = New-Decision -Selected 'backend-engineer' -Candidate 'backend-engineer' -Expected 'backend-engineer' -Accepted $false -Direct $false -Fallback $true -Reason 'candidate_out_of_envelope' -Mode 'fallback' -Blocked $false
    $r7 = Get-OutcomeCaseClassification -Case $c7 -Decision $d7
    Assert-That ($r7.Classification -ceq 'SUBOPTIMAL_ROUTE') 'fallback com candidato aceitavel => SUBOPTIMAL' $r7.Classification

    # 8) registry indisponivel => NOT_ENOUGH_EVIDENCE
    $d8 = New-Decision -Selected 'backend-engineer' -Candidate '' -Expected 'backend-engineer' -Accepted $false -Direct $false -Fallback $true -Reason 'fallback_registry_stale' -Mode 'fallback' -Blocked $false
    $r8 = Get-OutcomeCaseClassification -Case $c -Decision $d8
    Assert-That ($r8.Classification -ceq 'NOT_ENOUGH_EVIDENCE') 'registry stale => NOT_ENOUGH_EVIDENCE' $r8.Classification

    # 9) selecao fora de tudo (nao deterministica) => WRONG sem safety
    $d9 = New-Decision -Selected 'frontend-engineer' -Candidate 'frontend-engineer' -Expected 'backend-engineer' -Accepted $false -Direct $false -Fallback $true -Reason 'candidate_invalid_not_allowlisted' -Mode 'fallback' -Blocked $false
    $r9 = Get-OutcomeCaseClassification -Case $c -Decision $d9
    Assert-That (($r9.Classification -ceq 'WRONG_ROUTE') -and (-not [bool]$r9.SafetyViolation)) 'selecao fora do conjunto => WRONG' $r9.Classification

    # 10) agregacao: contagens + safety
    $rows = @(
        [PSCustomObject]@{ classification = 'GOOD_ROUTE'; safety_violation = $false; fallback_used = $false; direct = $false; route_mode = 'ROUTER'; router_ms = 10; total_ms = 20; category = 'backend'; deterministic_first = $false },
        [PSCustomObject]@{ classification = 'WRONG_ROUTE'; safety_violation = $true; fallback_used = $true; direct = $false; route_mode = 'FALLBACK'; router_ms = 30; total_ms = 40; category = 'backend'; deterministic_first = $false }
    )
    $agg = Get-OutcomeValidationAggregate -Rows $rows
    Assert-That (([int]$agg.classifications['GOOD_ROUTE'] -eq 1) -and ([int]$agg.classifications['WRONG_ROUTE'] -eq 1)) 'agregado: contagens' 'Errado'
    Assert-That ([int]$agg.safety_violations -eq 1) 'agregado: safety_violations' ([string]$agg.safety_violations)
    Assert-That ([int]$agg.latency.router_ms.p50 -eq 10) 'agregado: latencia p50' ([string]$agg.latency.router_ms.p50)
    $bc = @($agg.per_category | Where-Object { $_.category -ceq 'backend' })
    Assert-That ((@($bc).Count -eq 1) -and ([int]@($bc)[0].wrong_routes -eq 1)) 'agregado: rollup por categoria' 'Errado'
}
finally {
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
