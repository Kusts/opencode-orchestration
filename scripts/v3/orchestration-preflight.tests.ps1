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

    # 1) trivial typo with explicit delegation => SINGLE_WORKER with one cheap worker
    $r1 = Get-OrchestrationPreflight -Objective 'fix typo in button label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That (([string]$r1.orchestration_decision -ceq 'SINGLE_WORKER') -and ([string]$r1.task_class -ceq 'trivial')) '1 trivial typo => SINGLE_WORKER' ($r1 | ConvertTo-Json -Compress)
    Assert-That ((@($r1.selected_agents).Count -eq 1) -and (@($r1.selected_agents) -contains 'coder')) '1 SINGLE_WORKER returns 1 worker (coder)' ((@($r1.selected_agents)) -join ',')
    Assert-That ([string]$r1.bypass_verdict -ceq 'OK') '1 SINGLE_WORKER bypass_verdict OK' ([string]$r1.bypass_verdict)

    # 2) point lookup with explicit delegation => SINGLE_WORKER with explorer
    $r2 = Get-OrchestrationPreflight -Objective 'point lookup: where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That (([string]$r2.orchestration_decision -ceq 'SINGLE_WORKER') -and ([string]$r2.task_class -ceq 'trivial')) '2 point lookup => SINGLE_WORKER' ($r2 | ConvertTo-Json -Compress)
    Assert-That (@($r2.selected_agents) -contains 'explorer') '2 lookup selects explorer' ((@($r2.selected_agents)) -join ',')

    # 2b) cosmetic CLI case with explicit delegation => SINGLE_WORKER non-empty agents
    $r2b = Get-OrchestrationPreflight -Objective 'corrigir typo no README' -TaskType 'cosmetic' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
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

    # 5d) word-boundary: 'planilha'/'plant' nao promovem a goal (explicit delegation kept)
    $r5d = Get-OrchestrationPreflight -Objective 'inspecionar planilha de custos' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That ([string]$r5d.orchestration_decision -ceq 'SINGLE_WORKER') '5d planilha lookup => SINGLE_WORKER' ($r5d | ConvertTo-Json -Compress)
    $r5e = Get-OrchestrationPreflight -Objective 'inspect plant labels' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
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

    # 15b) DIRECT_VERIFIED: rota direta autorizada para tarefas triviais
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0) -ceq 'COMPLIANT') '15b DIRECT_VERIFIED trivial zero-worker => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason '' -ActualWorkerParticipation 0) -ceq 'NON_COMPLIANT_MISSING_DIRECT_REASON') '15b DIRECT_VERIFIED missing reason => MISSING_DIRECT_REASON' 'expected missing reason'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'SINGLE_WORKER' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0) -ceq 'NON_COMPLIANT_INVALID_DECISION') '15b DIRECT_VERIFIED mismatched shape => INVALID_DECISION' 'expected invalid decision'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15b DIRECT_VERIFIED on non-trivial => BYPASS' 'expected bypass'

    # Preflight com estrategia DIRECT_VERIFIED
    $rd = Get-OrchestrationPreflight -Objective 'fix typo in header' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'DIRECT_VERIFIED'
    Assert-That (($rd.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($rd.selected_agents).Count -eq 0) -and ($rd.bypass_verdict -ceq 'OK')) 'preflight DIRECT_VERIFIED produces direct decision without subagents' 'expected direct'
    $rnt = Get-OrchestrationPreflight -Objective 'implement database migration' -TaskType 'implementation' -Domain 'database' -Risk 'high' -ReadWrite 'write' -ExecutionStrategy 'DIRECT_VERIFIED'
    Assert-That ($rnt.orchestration_decision -cne 'DIRECT_VERIFIED') 'preflight DIRECT_VERIFIED rejects non-trivial task' 'expected non-direct'

    # Regressao: micro edit em docs com palavra sensivel (delete) nao pode ser DIRECT_VERIFIED
    # (bug: $blob undefined fazia sensitiveHit sempre false, permitindo bypass)
    $rsens = Get-OrchestrationPreflight -Objective 'delete old note in guide' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -ExecutionStrategy 'DIRECT_VERIFIED'
    Assert-That ($rsens.orchestration_decision -cne 'DIRECT_VERIFIED') 'preflight DIRECT_VERIFIED rejects micro edit with sensitive keyword' 'expected non-direct'

    # 15c) #201: eligible safe trivial defaults to DIRECT_VERIFIED (no explicit strategy)
    $rdef = Get-OrchestrationPreflight -Objective 'fix typo in button label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$rdef.orchestration_decision -ceq 'DIRECT_VERIFIED') -and ([string]$rdef.task_class -ceq 'trivial')) '15c default eligible trivial => DIRECT_VERIFIED' ($rdef | ConvertTo-Json -Compress)
    Assert-That ((@($rdef.selected_agents).Count -eq 0) -and ([string]$rdef.bypass_verdict -ceq 'OK')) '15c default direct spawns zero workers' ((@($rdef.selected_agents)) -join ',')
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision ([string]$rdef.orchestration_decision) -ExecutionShape 'DIRECT_VERIFIED' -DirectReason ([string]$rdef.direct_reason) -ActualWorkerParticipation 0) -ceq 'COMPLIANT') '15c default direct passes existing DONE gate with zero workers' ([string]$rdef.direct_reason)
    # explicit SINGLE_WORKER remains available for useful delegation
    $rsw = Get-OrchestrationPreflight -Objective 'fix typo in button label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That (([string]$rsw.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($rsw.selected_agents).Count -eq 1)) '15c explicit SINGLE_WORKER still delegates' ($rsw | ConvertTo-Json -Compress)
    # nearby negative: default strategy must not route unsafe write direct
    $rneg = Get-OrchestrationPreflight -Objective 'delete old note in guide' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That ([string]$rneg.orchestration_decision -cne 'DIRECT_VERIFIED') '15c default rejects sensitive micro-edit (delete)' ($rneg | ConvertTo-Json -Compress)

    # 15d) #201-fatia2: rota direta elegivel independe do router (classificador local)
    $rdu = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -RouterHealthy $false
    Assert-That (([string]$rdu.orchestration_decision -ceq 'DIRECT_VERIFIED') -and ([string]$rdu.task_class -ceq 'trivial')) '15d direct elegivel + router unhealthy => DIRECT_VERIFIED' ($rdu | ConvertTo-Json -Compress)
    Assert-That ((@($rdu.selected_agents).Count -eq 0) -and ([string]$rdu.bypass_verdict -ceq 'OK')) '15d direct router-independent gera zero workers' ((@($rdu.selected_agents)) -join ',')
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision ([string]$rdu.orchestration_decision) -ExecutionShape 'DIRECT_VERIFIED' -DirectReason ([string]$rdu.direct_reason) -ActualWorkerParticipation 0) -ceq 'COMPLIANT') '15d direct router-independent passa no DONE gate' ([string]$rdu.direct_reason)
    $rdst = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -RegistryFresh $false
    Assert-That ([string]$rdst.orchestration_decision -ceq 'DIRECT_VERIFIED') '15d direct elegivel + registry stale => DIRECT_VERIFIED' ($rdst | ConvertTo-Json -Compress)
    $rdok = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -RegistryOk $false
    Assert-That ([string]$rdok.orchestration_decision -ceq 'DIRECT_VERIFIED') '15d direct elegivel + registry unhealthy => DIRECT_VERIFIED' ($rdok | ConvertTo-Json -Compress)
    # controle: SINGLE_WORKER explicito com router unhealthy cai em fallback
    $rsu = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -RouterHealthy $false -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That (([string]$rsu.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rsu.fallback_reason -ceq 'router_unavailable')) '15d SINGLE explicito + router unhealthy => fallback' ($rsu | ConvertTo-Json -Compress)
    $rivi = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -RouterHealthy $false -ExecutionStrategy 'BOGUS_STRATEGY'
    Assert-That (([string]$rivi.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rivi.fallback_reason -ceq 'router_unavailable')) '15d invalid strategy + router unhealthy => fallback, never direct' ($rivi | ConvertTo-Json -Compress)
    # compat: estrategia nao reconhecida e nao vazia jamais vira direta (fallback delegado seguro)
    $rinv = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -ExecutionStrategy 'BOGUS_STRATEGY'
    Assert-That (([string]$rinv.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($rinv.selected_agents).Count -ge 1)) '15d invalid strategy stays delegated (non-direct)' ($rinv | ConvertTo-Json -Compress)
    # controle: nontrivial + router unhealthy inalterado
    $rnu = Get-OrchestrationPreflight -Objective 'implement bounded edit for retry queue' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RouterHealthy $false
    Assert-That (([string]$rnu.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rnu.fallback_reason -ceq 'router_unavailable')) '15d nontrivial + router unhealthy => fallback inalterado' ($rnu | ConvertTo-Json -Compress)

    # 15e) #201-fatia3: goal (explicito e spec+plan) com router unhealthy preserva fallback
    $rgu = Get-OrchestrationPreflight -Objective 'alcancar o goal de cobertura de testes do modulo de cobranca' -TaskType 'goal' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RouterHealthy $false
    Assert-That (([string]$rgu.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rgu.fallback_reason -ceq 'router_unavailable')) '15e explicit goal + router unhealthy => fallback' ($rgu | ConvertTo-Json -Compress)
    $rspu = Get-OrchestrationPreflight -Objective 'implementar SPEC e PLAN em 3 fases' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RouterHealthy $false
    Assert-That (([string]$rspu.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rspu.fallback_reason -ceq 'router_unavailable')) '15e spec+plan + router unhealthy => fallback' ($rspu | ConvertTo-Json -Compress)
    $rgs = Get-OrchestrationPreflight -Objective 'alcancar o goal de cobertura de testes do modulo de cobranca' -TaskType 'goal' -Domain 'backend' -Risk 'medium' -ReadWrite 'write' -RegistryFresh $false
    Assert-That (([string]$rgs.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rgs.fallback_reason -ceq 'registry_stale')) '15e explicit goal + registry stale => fallback' ($rgs | ConvertTo-Json -Compress)

    # 15f) #201-correcao: intento substantivo no Objective nunca e direto,
    # mesmo com metadados triviais (usa Test-OrchestrationKeyword existente)
    $radv = Get-OrchestrationPreflight -Objective 'Implement new workflow' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$radv.orchestration_decision -cne 'DIRECT_VERIFIED') '15f substantive objective with trivial metadata => not DIRECT_VERIFIED' ($radv | ConvertTo-Json -Compress)
    Assert-That (([string]$radv.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$radv.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$radv.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15f substantive objective => worker route or fallback' ($radv | ConvertTo-Json -Compress)
    # controles: typo e point lookup continuam DIRECT_VERIFIED por padrao
    $rtypo = Get-OrchestrationPreflight -Objective 'fix typo in label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$rtypo.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($rtypo.selected_agents).Count -eq 0)) '15f ordinary typo still DIRECT_VERIFIED' ($rtypo | ConvertTo-Json -Compress)
    $rlook = Get-OrchestrationPreflight -Objective 'where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$rlook.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($rlook.selected_agents).Count -eq 0)) '15f point lookup still DIRECT_VERIFIED' ($rlook | ConvertTo-Json -Compress)

    # 15g) reviewer finding: whole-codebase performance analysis with
    # trivial metadata must never take the direct route (Router-independent)
    $rperf = Get-OrchestrationPreflight -Objective 'Analyze the entire codebase for performance bottlenecks' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rperf.orchestration_decision -cne 'DIRECT_VERIFIED') '15g whole-codebase performance analysis with trivial metadata => not DIRECT_VERIFIED' ($rperf | ConvertTo-Json -Compress)
    Assert-That (([string]$rperf.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$rperf.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$rperf.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15g performance analysis => worker route or fallback' ($rperf | ConvertTo-Json -Compress)
    # independent substantive investigation objective with the same trivial metadata
    $rinvsub = Get-OrchestrationPreflight -Objective 'Investigate checkout latency across modules and compare retry strategies' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rinvsub.orchestration_decision -cne 'DIRECT_VERIFIED') '15g investigation/compare with trivial metadata => not DIRECT_VERIFIED' ($rinvsub | ConvertTo-Json -Compress)

    # 15h) second review: broad-scope objective with trivial metadata is never
    # direct, even when a lookup verb is present; direct requires bounded
    # point-lookup/micro-edit evidence in the objective itself
    $rh1 = Get-OrchestrationPreflight -Objective 'what should change across these modules?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rh1.orchestration_decision -cne 'DIRECT_VERIFIED') '15h broad across/modules with trivial metadata => not DIRECT_VERIFIED' ($rh1 | ConvertTo-Json -Compress)
    Assert-That (([string]$rh1.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$rh1.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$rh1.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15h across/modules => worker route or fallback' ($rh1 | ConvertTo-Json -Compress)
    $rh2 = Get-OrchestrationPreflight -Objective 'Find all usages of retry policy across the repository' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rh2.orchestration_decision -cne 'DIRECT_VERIFIED') '15h find all usages across repository => not DIRECT_VERIFIED' ($rh2 | ConvertTo-Json -Compress)
    Assert-That (([string]$rh2.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$rh2.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$rh2.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15h all/usages/across => worker route or fallback' ($rh2 | ConvertTo-Json -Compress)
    # scope-quantifier variants: every/entire/multiple stay delegated
    $rh3 = Get-OrchestrationPreflight -Objective 'list every handler in the entire service' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rh3.orchestration_decision -cne 'DIRECT_VERIFIED') '15h every/entire scope => not DIRECT_VERIFIED' ($rh3 | ConvertTo-Json -Compress)
    $rh4 = Get-OrchestrationPreflight -Objective 'summarize changes across multiple modules' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rh4.orchestration_decision -cne 'DIRECT_VERIFIED') '15h across/multiple scope => not DIRECT_VERIFIED' ($rh4 | ConvertTo-Json -Compress)
    # controls: bounded point lookups and micro-edits stay direct by default
    $ch1 = Get-OrchestrationPreflight -Objective 'fix typo in label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ch1.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ch1.selected_agents).Count -eq 0)) '15h bounded typo still DIRECT_VERIFIED' ($ch1 | ConvertTo-Json -Compress)
    $ch2 = Get-OrchestrationPreflight -Objective 'where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ch2.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ch2.selected_agents).Count -eq 0)) '15h bounded where-defined still DIRECT_VERIFIED' ($ch2 | ConvertTo-Json -Compress)
    $ch3 = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That (([string]$ch3.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ch3.selected_agents).Count -eq 0)) '15h bounded docs micro-edit still DIRECT_VERIFIED' ($ch3 | ConvertTo-Json -Compress)
    # control: explicit SINGLE_WORKER remains delegated even for bounded work
    $ch4 = Get-OrchestrationPreflight -Objective 'where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read' -ExecutionStrategy 'SINGLE_WORKER'
    Assert-That (([string]$ch4.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($ch4.selected_agents).Count -ge 1)) '15h explicit SINGLE_WORKER still delegates' ($ch4 | ConvertTo-Json -Compress)

    # 15i) third review: generic fix verb alone never establishes triviality;
    # direct requires bounded point-lookup or specific micro-edit evidence
    $ri1 = Get-OrchestrationPreflight -Objective 'Fix system behavior' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$ri1.orchestration_decision -cne 'DIRECT_VERIFIED') '15i generic fix system behavior read => not DIRECT_VERIFIED' ($ri1 | ConvertTo-Json -Compress)
    Assert-That (([string]$ri1.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$ri1.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$ri1.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15i generic fix system behavior read => worker route or fallback' ($ri1 | ConvertTo-Json -Compress)
    $ri2 = Get-OrchestrationPreflight -Objective 'Fix error handling in the workflow' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$ri2.orchestration_decision -cne 'DIRECT_VERIFIED') '15i generic fix error workflow read => not DIRECT_VERIFIED' ($ri2 | ConvertTo-Json -Compress)
    Assert-That (([string]$ri2.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$ri2.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$ri2.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15i generic fix error workflow read => worker route or fallback' ($ri2 | ConvertTo-Json -Compress)
    $ri3 = Get-OrchestrationPreflight -Objective 'Fix system behavior' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That ([string]$ri3.orchestration_decision -cne 'DIRECT_VERIFIED') '15i generic fix system behavior docs-write => not DIRECT_VERIFIED' ($ri3 | ConvertTo-Json -Compress)
    $ri4 = Get-OrchestrationPreflight -Objective 'Fix error handling in the workflow' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That ([string]$ri4.orchestration_decision -cne 'DIRECT_VERIFIED') '15i generic fix error workflow docs-write => not DIRECT_VERIFIED' ($ri4 | ConvertTo-Json -Compress)
    $ri5 = Get-OrchestrationPreflight -Objective 'Fix the workflow behavior across modules' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$ri5.orchestration_decision -cne 'DIRECT_VERIFIED') '15i fix workflow across modules => not DIRECT_VERIFIED' ($ri5 | ConvertTo-Json -Compress)
    Assert-That (([string]$ri5.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$ri5.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$ri5.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15i fix workflow across modules => worker route or fallback' ($ri5 | ConvertTo-Json -Compress)
    # controls: bounded point lookups and specific micro-edits stay direct
    $ci1 = Get-OrchestrationPreflight -Objective 'fix typo in label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci1.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci1.selected_agents).Count -eq 0)) '15i bounded typo read still DIRECT_VERIFIED' ($ci1 | ConvertTo-Json -Compress)
    $ci2 = Get-OrchestrationPreflight -Objective 'fix typo in README' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That (([string]$ci2.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci2.selected_agents).Count -eq 0)) '15i bounded typo docs-write still DIRECT_VERIFIED' ($ci2 | ConvertTo-Json -Compress)
    $ci3 = Get-OrchestrationPreflight -Objective 'where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci3.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci3.selected_agents).Count -eq 0)) '15i where-defined still DIRECT_VERIFIED' ($ci3 | ConvertTo-Json -Compress)
    $ci4 = Get-OrchestrationPreflight -Objective 'point lookup: where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci4.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci4.selected_agents).Count -eq 0)) '15i point lookup still DIRECT_VERIFIED' ($ci4 | ConvertTo-Json -Compress)
    $ci5 = Get-OrchestrationPreflight -Objective 'inspect plant labels' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci5.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci5.selected_agents).Count -eq 0)) '15i inspect plant labels still DIRECT_VERIFIED' ($ci5 | ConvertTo-Json -Compress)
    $ci6 = Get-OrchestrationPreflight -Objective 'inspecionar planilha de custos' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci6.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci6.selected_agents).Count -eq 0)) '15i inspecionar planilha still DIRECT_VERIFIED' ($ci6 | ConvertTo-Json -Compress)
    # control: exact quantifier matching avoids prefix overmatch (allow/allocate are not all)
    $ci7 = Get-OrchestrationPreflight -Objective 'fix typo in allow list' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ci7.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ci7.selected_agents).Count -eq 0)) '15i allow prefix is not all quantifier' ($ci7 | ConvertTo-Json -Compress)

    # 15j) bounded final correction: localized PT micro-edit stays direct; point cue + broad scope stays delegated
    $rj1 = Get-OrchestrationPreflight -Objective 'corrigir pontuacao no guia de instalacao' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write'
    Assert-That (([string]$rj1.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($rj1.selected_agents).Count -eq 0)) '15j PT punctuation micro-edit stays DIRECT_VERIFIED' ($rj1 | ConvertTo-Json -Compress)
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision ([string]$rj1.orchestration_decision) -ExecutionShape 'DIRECT_VERIFIED' -DirectReason ([string]$rj1.direct_reason) -ActualWorkerParticipation 0) -ceq 'COMPLIANT') '15j PT micro-edit passes DONE gate' ([string]$rj1.direct_reason)
    $rj2 = Get-OrchestrationPreflight -Objective 'Where is this symbol defined everywhere?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rj2.orchestration_decision -cne 'DIRECT_VERIFIED') '15j where-defined everywhere => not DIRECT_VERIFIED' ($rj2 | ConvertTo-Json -Compress)
    Assert-That (([string]$rj2.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$rj2.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$rj2.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15j where-defined everywhere => worker route or fallback' ($rj2 | ConvertTo-Json -Compress)
    $rj3 = Get-OrchestrationPreflight -Objective 'Where is this symbol defined globally?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rj3.orchestration_decision -cne 'DIRECT_VERIFIED') '15j where-defined globally => not DIRECT_VERIFIED' ($rj3 | ConvertTo-Json -Compress)
    $rj4 = Get-OrchestrationPreflight -Objective 'Onde este simbolo e definido globalmente?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rj4.orchestration_decision -cne 'DIRECT_VERIFIED') '15j onde-definido globalmente => not DIRECT_VERIFIED' ($rj4 | ConvertTo-Json -Compress)
    $rj5 = Get-OrchestrationPreflight -Objective 'where is this flag defined repo-wide?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rj5.orchestration_decision -cne 'DIRECT_VERIFIED') '15j where-defined repo-wide => not DIRECT_VERIFIED' ($rj5 | ConvertTo-Json -Compress)
    $rj6 = Get-OrchestrationPreflight -Objective 'where is this flag defined throughout the repository?' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rj6.orchestration_decision -cne 'DIRECT_VERIFIED') '15j where-defined throughout repository => not DIRECT_VERIFIED' ($rj6 | ConvertTo-Json -Compress)

    # 15k) fourth review: generic PT 'qual' prefix must not authorize direct;
    # 'Qualidade...' is a qualitative assessment, not a bounded point lookup.
    # Narrow PT lookup phrases ('qual arquivo/campo/simbolo') stay explicit.
    $rk1 = Get-OrchestrationPreflight -Objective 'Qualidade do sistema e dos fluxos' -TaskType 'trivial' -Domain 'docs' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$rk1.orchestration_decision -cne 'DIRECT_VERIFIED') '15k qualitative Qualidade assessment => not DIRECT_VERIFIED' ($rk1 | ConvertTo-Json -Compress)
    Assert-That (([string]$rk1.orchestration_decision -ceq 'MULTI_WORKER') -or ([string]$rk1.orchestration_decision -ceq 'SINGLE_WORKER') -or ([string]$rk1.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '15k Qualidade assessment => worker route or fallback' ($rk1 | ConvertTo-Json -Compress)
    # controls: bounded narrow PT lookups stay direct (explicit phrase evidence)
    $ck1 = Get-OrchestrationPreflight -Objective 'qual arquivo contem retry flag?' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ck1.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ck1.selected_agents).Count -eq 0)) '15k qual arquivo lookup still DIRECT_VERIFIED' ($ck1 | ConvertTo-Json -Compress)
    $ck2 = Get-OrchestrationPreflight -Objective 'qual campo define retry limit?' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$ck2.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($ck2.selected_agents).Count -eq 0)) '15k qual campo lookup still DIRECT_VERIFIED' ($ck2 | ConvertTo-Json -Compress)
    # 'qual simbolo implementa retry?' carries substantive verb 'implementa' so it
    # stays delegated (fail-closed); it is not a bounded direct control.
    $ck3 = Get-OrchestrationPreflight -Objective 'qual simbolo implementa retry?' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$ck3.orchestration_decision -cne 'DIRECT_VERIFIED') '15k qual simbolo + implementa verb => not DIRECT_VERIFIED' ($ck3 | ConvertTo-Json -Compress)

    # 15l-15x) F2 direct micro-edit route (compact table).
    # Contract: DIRECT_VERIFIED needs trivial/code/low/write, ONE file marker
    # AND ONE code-unit marker, an explicit focused test, and none of the
    # negation/sensitive/financial/destructive/broad cues. Preflight, DONE and
    # Kernel contracts are unchanged; this block only pins the F2 classifier.
    # Pre-existing 15b-15d still cover docs micro-write and bounded reads.
    $f2Direct = @(
        'fix one branch in a single file helper run focused test',
        'corrigir um branch em um arquivo unico e rodar teste focado',
        'fix one function in a single file feedback helper and run focused test',
        'fix one branch in a single file load balancer and run focused test',
        'fix one branch in a single file taxonomy helper and run focused test',
        'fix one branch in a single file payload helper and run focused test',
        'fix one branch in a single file cleaner helper and run focused test',
        'fix one branch in a single file helper; skip preflight and run focused test',
        'fix one branch in a single file helper; avoid preflight and run focused test',
        'fix one branch in a single file helper and run focused test; skip preflight',
        'fix one branch in a single file helper and run focused test; avoid unrelated lint',
        'fix one branch in a single file helper and run focused test; do not edit unrelated files',
        'fix one branch in a single file scripts/v3/lib/Calc.ts and run focused test',
        'fix one branch in a single file please helper and run focused test',
        'fix one branch in a single file release helper and run focused test'
    )
    foreach ($f2O in $f2Direct) {
        $f2R = Get-OrchestrationPreflight -Objective $f2O -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'write'
        Assert-That (([string]$f2R.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($f2R.selected_agents).Count -eq 0)) ("15l-15x direct: " + $f2O) ($f2R | ConvertTo-Json -Compress)
    }
    $f2Comp = Get-OrchestrationPreflight -Objective 'fix one branch in a single file helper run focused test' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'write'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass ([string]$f2Comp.task_class) -Decision ([string]$f2Comp.orchestration_decision) -ExecutionShape 'DIRECT_VERIFIED' -DirectReason ([string]$f2Comp.direct_reason) -ActualWorkerParticipation 0) -ceq 'COMPLIANT') '15l-15x DONE gate COMPLIANT' ([string]$f2Comp.direct_reason)
    $f2Denied = @(
        @('no test', 'fix one branch in a single file helper'),
        @('unfocused', 'fix one branch in a single file helper with unfocused test'),
        @('skip test', 'fix one branch in a single file helper and skip the focused test'),
        @('skip flaky', 'fix one branch in a single file helper and skip the flaky focused test'),
        @('skip whole', 'fix one branch in a single file helper and skip this whole test and run focused test'),
        @('skip entire', 'fix one branch in a single file helper and skip that entire test and run focused test'),
        @('skip running it', 'fix one branch in a single file helper and skip running it and run focused test'),
        @('avoid failing', 'fix one branch in a single file helper and avoid the failing test and run focused test'),
        @('dont run', 'fix one branch in a single file helper and dont run focused test'),
        @('post skip', 'fix one branch in a single file helper and run focused test; then skip it'),
        @('post no need', 'fix one branch in a single file helper run focused test. no need to run it'),
        @('post will not', 'fix one branch in a single file helper run focused test. it will not run'),
        @('post without', 'fix one branch in a single file helper run focused test; without running it'),
        @('post not run', 'fix one branch in a single file helper run focused test. not run'),
        @('PT sem rodar', 'corrigir um branch em um arquivo unico e rodar teste focado sem rodar teste'),
        @('PT sem nenhum', 'corrigir um branch em um arquivo unico sem nenhum teste focado'),
        @('PT dispensar', 'corrigir um branch em um arquivo unico e dispensar teste e rodar teste focado'),
        @('PT depois', 'corrigir um branch em um arquivo unico e rodar teste focado, teste pode ficar para depois'),
        @('PT pular', 'corrigir um branch em um arquivo unico e pular teste focado'),
        @('PT ignorar', 'corrigir um branch em um arquivo unico e ignorar o teste focado'),
        @('PT evitar', 'corrigir um branch em um arquivo unico e evitar teste focado'),
        @('missing file', 'fix one branch in helper and run focused test'),
        @('missing code unit', 'fix helper in a single file and run focused test'),
        @('substring file marker', 'fix one branch in algum arquivo helper and run focused test'),
        @('substring unit marker', 'fix behavior in a single file on algum branch helper and run focused test'),
        @('negative file', 'fix one branch in helper without a single file and run focused test'),
        @('two files', 'fix one branch in a single file helper and two files and run focused test'),
        @('three files', 'fix one branch in a single file helper and three files and run focused test'),
        @('one more file', 'fix one branch in a single file helper and one more file and run focused test'),
        @('duas arquivos', 'fix one branch in a single file helper and duas arquivos and run focused test'),
        @('another module', 'fix one branch in a single file helper and another module and run focused test'),
        @('not a single file', 'fix one branch in a single file helper not a single file and run focused test'),
        @('not only one file', 'fix one branch in a single file helper and run focused test, not only one file'),
        @('payment', 'fix one branch in a single file helper and payment calculation and run focused test'),
        @('charging', 'fix one branch in a single file helper and charging logic and run focused test'),
        @('invoicing', 'fix one branch in a single file helper and invoicing helper and run focused test'),
        @('payout', 'fix one branch in a single file helper and payout helper and run focused test'),
        @('pagando', 'corrigir um branch em um arquivo unico e pagando o helper e rodar teste focado'),
        @('cobrando', 'corrigir um branch em um arquivo unico e cobrando o helper e rodar teste focado'),
        @('estornando', 'corrigir um branch em um arquivo unico e estornando o valor e rodar teste focado'),
        @('cobrador', 'corrigir um branch em um arquivo unico e ajustar o cobrador e rodar teste focado'),
        @('removing', 'fix one branch in a single file helper and removing dead code and run focused test'),
        @('deleting', 'fix one branch in a single file helper and deleting dead code and run focused test'),
        @('erasing', 'fix one branch in a single file helper and erasing dead code and run focused test'),
        @('prune', 'fix one branch in a single file helper and prune dead code and run focused test'),
        @('remove', 'fix one branch in a single file helper and remove dead code and run focused test'),
        @('clean up', 'fix one branch in a single file helper and clean up dead code and run focused test'),
        @('apagando', 'corrigir um branch em um arquivo unico e apagando codigo e rodar teste focado'),
        @('excluindo', 'corrigir um branch em um arquivo unico e excluindo codigo e rodar teste focado'),
        @('remover', 'corrigir um branch em um arquivo unico e remover o codigo antigo rodando teste focado'),
        @('excluir', 'corrigir um branch em um arquivo unico e excluir o codigo antigo rodando teste focado'),
        @('apagar', 'corrigir um branch em um arquivo unico e apagar o codigo antigo rodando teste focado'),
        @('permission', 'fix one branch in a permission helper in a single file and run focused test'),
        @('secret', 'fix one branch in a single file secret helper and run focused test'),
        @('auth', 'fix one branch in a single file auth helper and run focused test'),
        @('security', 'fix one branch in a single file security helper and run focused test'),
        @('credentials PT', 'corrigir um branch em um arquivo unico das credenciais e rodar teste focado'),
        @('deploy', 'fix one branch in a single file helper and deploy it and run focused test'),
        @('delete', 'fix one branch in a single file helper and delete old code and run focused test'),
        @('login', 'fix one branch in a single file login helper and run focused test'),
        @('role', 'fix one branch in a single file role helper and run focused test'),
        @('jwt', 'fix one branch in a single file jwt helper and run focused test'),
        @('rbac', 'fix one branch in a single file rbac helper and run focused test'),
        @('acl', 'fix one branch in a single file acl helper and run focused test'),
        @('access-control', 'fix one branch in a single file access-control helper and run focused test'),
        @('sanitization', 'fix one branch in a single file sanitization helper and run focused test'),
        @('sql', 'fix one branch in a single file sql helper and run focused test'),
        @('hash', 'fix one branch in a single file hash helper and run focused test'),
        @('hmac', 'fix one branch in a single file hmac helper and run focused test'),
        @('signature', 'fix one branch in a single file signature helper and run focused test'),
        @('cors', 'fix one branch in a single file cors helper and run focused test'),
        @('concurrent', 'fix one branch in a single file concurrent helper and run focused test'),
        @('race', 'fix one branch in a single file race helper and run focused test'),
        @('mutex', 'fix one branch in a single file mutex helper and run focused test'),
        @('lock', 'fix one branch in a single file lock helper and run focused test'),
        @('lease', 'fix one branch in a single file lease helper and run focused test'),
        @('worktree', 'fix one branch in a single file worktree helper and run focused test'),
        @('shared-file', 'fix one branch in a single file shared-file helper and run focused test'),
        @('not just one file', 'fix one branch in a single file helper not just one file and run focused test'),
        @('both files', 'fix one branch in a single file helper both files and run focused test'),
        @('other file', 'fix one branch in a single file helper other file and run focused test'),
        @('second file', 'fix one branch in a single file helper second file and run focused test'),
        @('callers', 'fix one branch in a single file helper callers and run focused test'),
        @('two paths', 'fix one branch in a single file helper src/a.ps1 and tests/a.tests.ps1 and run focused test'),
        @('kernel path', 'fix one branch in a single file scripts/v3/lib/OrchestrationTaskKernel.ps1 and run focused test'),
        @('worktree lease path', 'fix one branch in a single file scripts/v3/lib/WorktreeLease.ps1 and run focused test'),
        @('grant helper', 'fix one branch in a single file scripts/v3/lib/GrantIssuer.ps1 and run focused test'),
        @('verifier helper', 'fix one branch in a single file scripts/v3/lib/VerifierRules.ps1 and run focused test'),
        @('grant ts', 'fix one branch in a single file src/core/ExecutionGrant.ts and run focused test'),
        @('verifier ts', 'fix one branch in a single file src/core/VerifierProfiles.ts and run focused test'),
        @('opencode json', 'fix one branch in a single file opencode.json and run focused test'),
        @('permission helper', 'fix one branch in a single file scripts/v3/lib/PermissionHelper.ps1 and run focused test'),
        @('authz helper', 'fix one branch in a single file scripts/v3/lib/AuthzHelper.ps1 and run focused test'),
        @('env file', 'fix one branch in a single file .env and run focused test'),
        @('dotenv', 'fix one branch in a single file dotenv helper and run focused test'),
        @('settings config', 'fix one branch in a single file settings config helper and run focused test'),
        @('opencode config', 'fix one branch in a single file opencode config helper and run focused test'),
        @('mandate enforcement', 'fix one branch in a single file src/core/MandateEnforcement.ts and run focused test'),
        @('capability registry', 'fix one branch in a single file src/core/CapabilityRegistry.ts and run focused test'),
        @('policy rules', 'fix one branch in a single file src/core/PolicyRules.ts and run focused test'),
        @('preflight path', 'fix one branch in a single file scripts/v3/orchestration-preflight.ps1 and run focused test'),
        @('orchestration taskkernel', 'fix one branch in a single file OrchestrationTaskKernel helper and run focused test'),
        @('taskkernel', 'fix one branch in a single file TaskKernel helper and run focused test'),
        @('worktree lease', 'fix one branch in a single file WorktreeLease helper and run focused test'),
        @('lease manager', 'fix one branch in a single file LeaseManager helper and run focused test'),
        @('execution grant', 'fix one branch in a single file ExecutionGrant helper and run focused test'),
        @('grant policy', 'fix one branch in a single file GrantPolicy helper and run focused test'),
        @('verifier profiles', 'fix one branch in a single file VerifierProfiles helper and run focused test'),
        @('permission gate', 'fix one branch in a single file PermissionGate helper and run focused test'),
        @('orchestration preflight', 'fix one branch in a single file OrchestrationPreflight helper and run focused test'),
        @('done compliance', 'fix one branch in a single file OrchestrationDoneCompliance helper and run focused test'),
        @('capability acceptance', 'fix one branch in a single file CapabilityAcceptance helper and run focused test'),
        @('mcp safety', 'fix one branch in a single file McpSafety helper and run focused test')
    )
    $f2N = 0
    foreach ($f2C in $f2Denied) {
        $f2N++
        $f2R = Get-OrchestrationPreflight -Objective ([string]$f2C[1]) -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'write'
        Assert-That ([string]$f2R.orchestration_decision -cne 'DIRECT_VERIFIED') ("15l-15x denied #" + $f2N + " " + $f2C[0]) ($f2R | ConvertTo-Json -Compress)
    }
    $f2Meta = @(
        @('implementation', 'implementation', 'low'),
        @('cosmetic', 'cosmetic', 'low'),
        @('medium risk', 'trivial', 'medium'),
        @('high risk', 'trivial', 'high')
    )
    foreach ($f2M in $f2Meta) {
        $f2R = Get-OrchestrationPreflight -Objective 'fix one branch in a single file helper and run focused test' -TaskType ([string]$f2M[1]) -Domain 'code' -Risk ([string]$f2M[2]) -ReadWrite 'write'
        Assert-That ([string]$f2R.orchestration_decision -cne 'DIRECT_VERIFIED') ("15l-15x metadata " + $f2M[0]) ($f2R | ConvertTo-Json -Compress)
    }
    # 16) CLI: malformed health string fails closed to fallback
    $c3 = Invoke-PreflightCliRaw -Argv @('-Objective', 'implement bounded edit for retry queue', '-TaskType', 'implementation', '-Domain', 'backend', '-Risk', 'medium', '-ReadWrite', 'write', '-RouterHealthy', 'maybe')
    $o3 = Get-JsonTail -Text $c3.Text
    Assert-That (($c3.Code -eq 0) -and ($null -ne $o3) -and ([string]$o3.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK')) '16 CLI malformed health => fallback' $c3.Text

    # Vague task => DETERMINISTIC_FALLBACK vague_task_underspecified
    $rv = Get-OrchestrationPreflight -Objective '' -TaskType '' -Domain '' -Risk 'unknown' -ReadWrite ''
    Assert-That (([string]$rv.orchestration_decision -ceq 'DETERMINISTIC_FALLBACK') -and ([string]$rv.fallback_reason -ceq 'vague_task_underspecified')) 'vague => DETERMINISTIC_FALLBACK vague_task_underspecified' ($rv | ConvertTo-Json -Compress)

    # CLI: valid inline prints JSON with required keys, exit 0 (default eligible trivial => DIRECT_VERIFIED, zero workers)
    $c1 = Invoke-PreflightCliRaw -Argv @('-Objective', 'fix typo in label', '-TaskType', 'trivial', '-Domain', 'code', '-Risk', 'low', '-ReadWrite', 'read')
    $o1 = Get-JsonTail -Text $c1.Text
    Assert-That ($c1.Code -eq 0) 'cli trivial: exit 0' ("Exit $($c1.Code)")
    Assert-That (($null -ne $o1) -and ([string]$o1.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($o1.selected_agents).Count -eq 0) -and ($null -ne $o1.evidence_hint)) 'cli trivial: JSON DIRECT_VERIFIED zero workers + evidence_hint' $c1.Text

    # CLI: explicit SINGLE_WORKER keeps the delegation path
    $c1b = Invoke-PreflightCliRaw -Argv @('-Objective', 'fix typo in label', '-TaskType', 'trivial', '-Domain', 'code', '-Risk', 'low', '-ReadWrite', 'read', '-ExecutionStrategy', 'SINGLE_WORKER')
    $o1b = Get-JsonTail -Text $c1b.Text
    Assert-That (($c1b.Code -eq 0) -and ($null -ne $o1b) -and ([string]$o1b.orchestration_decision -ceq 'SINGLE_WORKER') -and (@($o1b.selected_agents).Count -ge 1)) 'cli trivial explicit SINGLE_WORKER: JSON SINGLE_WORKER with worker' $c1b.Text

    # CLI: rota direta elegivel independe do router (bloqueador observado #201-fatia2)
    $cdu = Invoke-PreflightCliRaw -Argv @('-Objective', 'fix typo in README', '-TaskType', 'cosmetic', '-Domain', 'docs', '-Risk', 'low', '-ReadWrite', 'write', '-RouterHealthy', 'false')
    $odu = Get-JsonTail -Text $cdu.Text
    Assert-That (($cdu.Code -eq 0) -and ($null -ne $odu) -and ([string]$odu.orchestration_decision -ceq 'DIRECT_VERIFIED') -and (@($odu.selected_agents).Count -eq 0)) 'cli direct + RouterHealthy false => DIRECT_VERIFIED zero workers' $cdu.Text

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
