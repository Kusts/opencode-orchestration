$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$lib = Join-Path $v3 'lib\OrchestrationPreflight.ps1'
$cli = Join-Path $v3 'orchestration-preflight.ps1'

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Invoke-PreflightCliRaw {
    param([string[]]$Argv)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = & powershell -NoProfile -File $cli @Argv
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = (($text | ForEach-Object { "$_" }) -join "`n") }
}

function Get-JsonTail {
    param([string]$Text)
    $idx = $Text.IndexOf('{')
    if ($idx -lt 0) { return $null }
    $tail = $Text.Substring($idx)
    try { return ($tail | ConvertFrom-Json) } catch { return $null }
}

try {
    Assert-That (Test-Path -LiteralPath $lib -PathType Leaf) 'lib file exists' "Missing $lib"
    Assert-That (Test-Path -LiteralPath $cli -PathType Leaf) 'cli file exists' "Missing $cli"
    . $lib

    # 1) trivial typo => SINGLE_WORKER with one cheap worker (full orchestration)
    $r1 = Get-OrchestrationPreflight -Objective 'fix typo in button label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$r1.orchestration_decision -ceq 'SINGLE_WORKER') -and ([string]$r1.task_class -ceq 'trivial')) '1 trivial typo => SINGLE_WORKER' ($r1 | ConvertTo-Json -Compress)
    Assert-That ((@($r1.selected_agents).Count -eq 1) -and (@($r1.selected_agents) -contains 'coder')) '1 SINGLE_WORKER returns 1 worker (coder)' ((@($r1.selected_agents)) -join ',')
    Assert-That ([string]$r1.bypass_verdict -ceq 'OK') '1 SINGLE_WORKER bypass_verdict OK' ([string]$r1.bypass_verdict)

    # 2) point lookup => SINGLE_WORKER with explorer
    $r2 = Get-OrchestrationPreflight -Objective 'point lookup: where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$r2.orchestration_decision -ceq 'SINGLE_WORKER') -and ([string]$r2.task_class -ceq 'trivial')) '2 point lookup => SINGLE_WORKER' ($r2 | ConvertTo-Json -Compress)
    Assert-That (@($r2.selected_agents) -contains 'explorer') '2 lookup selects explorer' ((@($r2.selected_agents)) -join ',')

    # 2b) cosmetic CLI case from acceptance: typo fix => SINGLE_WORKER non-empty agents
    $r2b = Get-OrchestrationPreflight -Objective 'corrigir typo no README' -TaskType 'cosmetic' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$r2b.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($r2b.selected_agents).Count -ge 1)) '2b cosmetic typo => SINGLE_WORKER with worker' ($r2b | ConvertTo-Json -Compress)

    # 3) non-trivial implementation => MULTI_WORKER with coder
    $r3 = Get-OrchestrationPreflight -Objective 'implement bounded edit for retry queue with tests across two modules' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write'
    Assert-That (([string]$r3.orchestration_decision -ceq 'MULTI_WORKER') -and ([string]$r3.task_class -ceq 'non_trivial')) '3 implementation => MULTI_WORKER' ($r3 | ConvertTo-Json -Compress)
    Assert-That ((@($r3.selected_agents) -contains 'coder')) '3 implementation selects coder' ((@($r3.selected_agents)) -join ',')
    Assert-That (([string]$r3.bypass_verdict -ceq 'UNVERIFIED_POST_EXECUTION_REQUIRED') -and (-not [string]::IsNullOrWhiteSpace([string]$r3.post_execution_check))) '3 MULTI_WORKER plans only, post check required' ($r3 | ConvertTo-Json -Compress)

    # 4) analysis/audit => MULTI_WORKER
    $r4 = Get-OrchestrationPreflight -Objective 'analyze checkout funnel latency and audit failure modes with evidence' -TaskType 'analysis' -Domain 'backend' -Risk 'medium' -ReadWrite 'read'
    Assert-That ([string]$r4.orchestration_decision -ceq 'MULTI_WORKER') '4 analysis/audit => MULTI_WORKER' ($r4 | ConvertTo-Json -Compress)

    # 5) significant plan => MULTI_WORKER
    $r5 = Get-OrchestrationPreflight -Objective 'plan requirements breakdown with acceptance criteria for notification preferences' -TaskType 'planning' -Domain 'planning' -Risk 'medium' -ReadWrite 'read'
    Assert-That ([string]$r5.orchestration_decision -ceq 'MULTI_WORKER') '5 significant plan => MULTI_WORKER' ($r5 | ConvertTo-Json -Compress)

    # 5b) explicit goal => PERSISTENT_GOAL (non_trivial, workers like MULTI_WORKER)
    $r5b = Get-OrchestrationPreflight -Objective 'alcancar o goal de cobertura de testes do modulo de cobranca' -TaskType 'goal' -Domain 'backend' -Risk 'medium' -ReadWrite 'write'
    Assert-That (([string]$r5b.orchestration_decision -ceq 'PERSISTENT_GOAL') -and ([string]$r5b.task_class -ceq 'non_trivial')) '5b goal tasktype => PERSISTENT_GOAL' ($r5b | ConvertTo-Json -Compress)
    Assert-That ((@($r5b.selected_agents).Count -ge 1) -and ([string]$r5b.bypass_verdict -ceq 'UNVERIFIED_POST_EXECUTION_REQUIRED') -and ([string]$r5b.fallback_reason -ceq 'goal_promotion_explicit')) '5b PERSISTENT_GOAL has workers + explicit reason' ($r5b | ConvertTo-Json -Compress)

    # 5c) spec+plan objective => PERSISTENT_GOAL via keyword promotion
    $r5c = Get-OrchestrationPreflight -Objective 'implementar SPEC e PLAN em 3 fases' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write'
    Assert-That (([string]$r5c.orchestration_decision -ceq 'PERSISTENT_GOAL') -and ([string]$r5c.fallback_reason -ceq 'goal_promotion_spec_plan')) '5c spec+plan phases => PERSISTENT_GOAL' ($r5c | ConvertTo-Json -Compress)

    # 5d) word-boundary: 'planilha'/'plant' nao promovem a goal (TDR-F1-12)
    $r5d = Get-OrchestrationPreflight -Objective 'inspecionar planilha de custos' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$r5d.orchestration_decision -ceq 'SINGLE_WORKER') '5d planilha lookup => SINGLE_WORKER' ($r5d | ConvertTo-Json -Compress)
    $r5e = Get-OrchestrationPreflight -Objective 'inspect plant labels' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$r5e.orchestration_decision -ceq 'SINGLE_WORKER') '5e plant labels lookup => SINGLE_WORKER' ($r5e | ConvertTo-Json -Compress)

    # 5f) SINGLE_WORKER carrega post_execution_check trivial com participacao (FIX-03)
    Assert-That (([string]$r1.post_execution_check -like '*TaskClass trivial*') -and ([string]$r1.post_execution_check -like '*ActualWorkerParticipation*')) '5f SINGLE_WORKER post check exige participacao' ([string]$r1.post_execution_check)

    # 6) security-sensitive => DETERMINISTIC_FALLBACK (never BLOCKED)
    $r6 = Get-OrchestrationPreflight -Objective 'audit authentication and authorization, fix jwt session handling' -TaskType 'review' -Domain 'security' -Risk 'high' -ReadWrite 'write'
    Assert-That ([string]$r6.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') '6 security => DETERMINISTIC_FALLBACK' ($r6 | ConvertTo-Json -Compress)
    Assert-That ([string]$r6.orchestration_decision -cne 'BLOCKED') '6 security is not BLOCKED' ([string]$r6.orchestration_decision)

    # 7) Router unavailable => DETERMINISTIC_FALLBACK (never silent bypass)
    $r7 = Get-OrchestrationPreflight -Objective 'implement bounded edit for retry queue' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RouterHealthy $false
    Assert-That ([string]$r7.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') '7 router unavailable => DETERMINISTIC_FALLBACK' ($r7 | ConvertTo-Json -Compress)
    Assert-That (-not (Test-OrchestrationRouterHealth -Healthy $false)) '7 health($false) is not healthy' 'expected false'

    # 8) Registry stale => DETERMINISTIC_FALLBACK
    $r8 = Get-OrchestrationPreflight -Objective 'implement bounded edit for retry queue' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RegistryFresh $false
    Assert-That (([string]$r8.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$r8.fallback_reason -ceq 'registry_stale')) '8 registry stale => DETERMINISTIC_FALLBACK registry_stale' ($r8 | ConvertTo-Json -Compress)

    # 9) non-trivial zero-worker => BYPASS; trivial zero-worker => no bypass; non-trivial with worker => no bypass
    $b1 = Test-OrchestrationBypass -TaskClass 'non_trivial' -WorkerParticipation 0
    Assert-That ([bool]$b1 -eq $true) '9 non-trivial zero-worker => BYPASS' "$b1"
    $b2 = Test-OrchestrationBypass -TaskClass 'trivial' -WorkerParticipation 0
    Assert-That ([bool]$b2 -eq $false) '9 trivial zero-worker => no bypass' "$b2"
    $b3 = Test-OrchestrationBypass -TaskClass 'non_trivial' -WorkerParticipation 2
    Assert-That ([bool]$b3 -eq $false) '9 non-trivial with workers => no bypass' "$b3"

    # 10) legacy DIRECT_* tokens are fail-closed: always rejected, token list empty
    Assert-That (-not (Test-OrchestrationDirectReason -Reason 'DIRECT_MAGIC_GUESS')) '10 invalid direct reason => rejected' 'expected false'
    Assert-That (-not (Test-OrchestrationDirectReason -Reason 'DIRECT_TRIVIAL_LOCALIZED')) '10 legacy DIRECT_TRIVIAL_LOCALIZED => rejected (fail-closed)' 'expected false'
    Assert-That (@(Get-OrchestrationDirectTokens).Count -eq 0) '10 direct token list is empty (deprecated)' 'expected empty'

    # 11) worker subdelegation attempt => denied
    $s1 = Test-OrchestrationSubdelegation -IsWorker $true
    Assert-That ([string]$s1 -ceq 'denied') '11 worker subdelegation => denied' "$s1"

    # 12) prose-only trivial is rejected: non-trivial type + keyword stays MULTI_WORKER
    $r12 = Get-OrchestrationPreflight -Objective 'analyze formatting routine behavior across modules' -TaskType 'analysis' -Domain 'backend' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$r12.orchestration_decision -ceq 'MULTI_WORKER') '12 prose format word does not make trivial' ($r12 | ConvertTo-Json -Compress)

    # 13) explicit review beats research keyword
    $r13 = Get-OrchestrationPreflight -Objective 'review the pesquisa synthesis for correctness' -TaskType 'review' -Domain 'backend' -Risk 'medium' -ReadWrite 'read'
    Assert-That ((@($r13.selected_agents) -contains 'reviewer')) '13 review beats research keyword' ((@($r13.selected_agents)) -join ',')

    # 14) isolated release is not infra_mutation (H3 aligned with Acceptance)
    $hx14 = Get-OrchestrationHardExclusions -Objective 'prepare release notes draft for patch 1.2' -TaskType 'documentation' -Domain 'documentation' -Risk 'low' -ReadWrite 'read'
    Assert-That (-not (@($hx14.Tokens) -contains 'infra_mutation')) '14 isolated release is not infra_mutation' ((@($hx14.Tokens)) -join ',')

    # 15) DONE gate: post-execution compliance (ExecutionShape, fail-closed on legacy)
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'MULTI_WORKER' -ActualWorkerParticipation 0) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 MULTI_WORKER zero-worker => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'MULTI_WORKER' -ActualWorkerParticipation 2) -ceq 'COMPLIANT') '15 MULTI_WORKER with workers => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'PERSISTENT_GOAL' -ActualWorkerParticipation 0) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 PERSISTENT_GOAL zero-worker => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'PERSISTENT_GOAL' -ActualWorkerParticipation 1) -ceq 'COMPLIANT') '15 PERSISTENT_GOAL with worker => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DETERMINISTIC_FALLBACK' -DeterministicOwnerExecuted $false) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 FALLBACK owner not run => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DETERMINISTIC_FALLBACK' -DeterministicOwnerExecuted $true) -ceq 'COMPLIANT') '15 FALLBACK owner ran => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'BLOCKED') -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 BLOCKED => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 0) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 trivial SINGLE_WORKER zero-worker => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'COMPLIANT') '15 trivial SINGLE_WORKER shape+worker => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -ExecutionShape 'single_worker' -ActualWorkerParticipation 1) -ceq 'COMPLIANT') '15 trivial shape case-insensitive => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass '' -Decision 'SINGLE_WORKER' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'NON_COMPLIANT_INVALID_TASK_CLASS') '15 empty TaskClass => INVALID_TASK_CLASS' 'expected invalid class'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'x' -Decision 'SINGLE_WORKER' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'NON_COMPLIANT_INVALID_TASK_CLASS') '15 unknown TaskClass => INVALID_TASK_CLASS' 'expected invalid class'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision '' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'NON_COMPLIANT_INVALID_DECISION') '15 trivial empty Decision => INVALID_DECISION' 'expected invalid decision'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'MULTI_WORKER' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'NON_COMPLIANT_INVALID_DECISION') '15 trivial wrong Decision => INVALID_DECISION' 'expected invalid decision'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -DirectReason 'nota qualquer' -ExecutionShape 'SINGLE_WORKER' -ActualWorkerParticipation 1) -ceq 'NON_COMPLIANT_INVALID_DIRECT_REASON') '15 trivial non-DIRECT reason => INVALID_DIRECT_REASON' 'expected invalid reason'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -DirectReason 'DIRECT_COSMETIC_NO_LOGIC') -ceq 'NON_COMPLIANT_DEPRECATED_DIRECT') '15 trivial legacy DIRECT_* => NON_COMPLIANT_DEPRECATED_DIRECT' 'expected deprecated'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER' -ExecutionShape 'MULTI_WORKER') -ceq 'NON_COMPLIANT_DEPRECATED_DIRECT') '15 trivial wrong shape => NON_COMPLIANT_DEPRECATED_DIRECT' 'expected deprecated'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'SINGLE_WORKER') -ceq 'NON_COMPLIANT_MISSING_DIRECT_REASON') '15 trivial with nothing => NON_COMPLIANT_MISSING_*' 'expected missing'

    # 16) CLI: malformed health string fails closed to fallback
    $c3 = Invoke-PreflightCliRaw -Argv @('-Objective', 'implement bounded edit for retry queue', '-TaskType', 'implementation', '-Domain', 'backend', '-Risk', 'medium', '-ReadWrite', 'write', '-RouterHealthy', 'maybe')
    $o3 = Get-JsonTail -Text $c3.Text
    Assert-That (($c3.Code -eq 0) -and ($null -ne $o3) -and ([string]$o3.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '16 CLI malformed health => fallback' $c3.Text

    # Vague task => DETERMINISTIC_FALLBACK vague_task_underspecified
    $rv = Get-OrchestrationPreflight -Objective '' -TaskType '' -Domain '' -Risk 'unknown' -ReadWrite ''
    Assert-That (([string]$rv.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rv.fallback_reason -ceq 'vague_task_underspecified')) 'vague => DETERMINISTIC_FALLBACK vague_task_underspecified' ($rv | ConvertTo-Json -Compress)

    # CLI: valid inline prints JSON with required keys, exit 0
    $c1 = Invoke-PreflightCliRaw -Argv @('-Objective', 'fix typo in label', '-TaskType', 'trivial', '-Domain', 'code', '-Risk', 'low', '-ReadWrite', 'read')
    $o1 = Get-JsonTail -Text $c1.Text
    Assert-That ($c1.Code -eq 0) 'cli trivial: exit 0' ("Exit $($c1.Code)")
    Assert-That (($null -ne $o1) -and ([string]$o1.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($o1.selected_agents).Count -ge 1) -and ($null -ne $o1.evidence_hint)) 'cli trivial: JSON SINGLE_WORKER with worker + evidence_hint' $c1.Text

    # CLI: invalid use => exit 2, never MCP
    $c2 = Invoke-PreflightCliRaw -Argv @()
    Assert-That ($c2.Code -eq 2) 'cli no args: exit 2' ("Exit $($c2.Code)")
}
catch {
    Assert-That $false 'harness: no exception' $_.Exception.Message
}

Write-Output ''
Write-Output ('TEST RESULTS: ' + $passed + ' / ' + $total + ' passed')
if ($passed -eq $total) { exit 0 }
exit 1
