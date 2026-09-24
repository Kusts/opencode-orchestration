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

    # 1) trivial typo => TRIVIAL_DIRECT
    $r1 = Get-OrchestrationPreflight -Objective 'fix typo in button label' -TaskType 'trivial' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$r1.orchestration_decision -ceq 'TRIVIAL_DIRECT') -and ([string]$r1.task_class -ceq 'trivial')) '1 trivial typo => TRIVIAL_DIRECT' ($r1 | ConvertTo-Json -Compress)
    Assert-That (Test-OrchestrationDirectReason -Reason ([string]$r1.direct_reason)) '1 direct reason is valid token' ([string]$r1.direct_reason)

    # 2) point lookup => TRIVIAL_DIRECT
    $r2 = Get-OrchestrationPreflight -Objective 'point lookup: where is retry flag defined' -TaskType 'lookup' -Domain 'code' -Risk 'low' -ReadWrite 'read'
    Assert-That (([string]$r2.orchestration_decision -ceq 'TRIVIAL_DIRECT') -and ([string]$r2.task_class -ceq 'trivial')) '2 point lookup => TRIVIAL_DIRECT' ($r2 | ConvertTo-Json -Compress)

    # 3) non-trivial implementation => DELEGATED with coder
    $r3 = Get-OrchestrationPreflight -Objective 'implement bounded edit for retry queue with tests across two modules' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write'
    Assert-That (([string]$r3.orchestration_decision -ceq 'DELEGATED') -and ([string]$r3.task_class -ceq 'non_trivial')) '3 implementation => DELEGATED' ($r3 | ConvertTo-Json -Compress)
    Assert-That ((@($r3.selected_agents) -contains 'coder')) '3 implementation selects coder' ((@($r3.selected_agents)) -join ',')
    Assert-That (([string]$r3.bypass_verdict -ceq 'UNVERIFIED_POST_EXECUTION_REQUIRED') -and (-not [string]::IsNullOrWhiteSpace([string]$r3.post_execution_check))) '3 DELEGATED plans only, post check required' ($r3 | ConvertTo-Json -Compress)

    # 4) analysis/audit => DELEGATED
    $r4 = Get-OrchestrationPreflight -Objective 'analyze checkout funnel latency and audit failure modes with evidence' -TaskType 'analysis' -Domain 'backend' -Risk 'medium' -ReadWrite 'read'
    Assert-That ([string]$r4.orchestration_decision -ceq 'DELEGATED') '4 analysis/audit => DELEGATED' ($r4 | ConvertTo-Json -Compress)

    # 5) significant plan => DELEGATED
    $r5 = Get-OrchestrationPreflight -Objective 'plan requirements breakdown with acceptance criteria for notification preferences' -TaskType 'planning' -Domain 'planning' -Risk 'medium' -ReadWrite 'read'
    Assert-That ([string]$r5.orchestration_decision -ceq 'DELEGATED') '5 significant plan => DELEGATED' ($r5 | ConvertTo-Json -Compress)

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

    # 10) invalid direct reason => rejected
    Assert-That (-not (Test-OrchestrationDirectReason -Reason 'DIRECT_MAGIC_GUESS')) '10 invalid direct reason => rejected' 'expected false'
    Assert-That (Test-OrchestrationDirectReason -Reason 'DIRECT_TRIVIAL_LOCALIZED') '10 valid token accepted' 'expected true'

    # 11) worker subdelegation attempt => denied
    $s1 = Test-OrchestrationSubdelegation -IsWorker $true
    Assert-That ([string]$s1 -ceq 'denied') '11 worker subdelegation => denied' "$s1"

    # 12) prose-only trivial is rejected: non-trivial type + keyword stays DELEGATED
    $r12 = Get-OrchestrationPreflight -Objective 'analyze formatting routine behavior across modules' -TaskType 'analysis' -Domain 'backend' -Risk 'low' -ReadWrite 'read'
    Assert-That ([string]$r12.orchestration_decision -ceq 'DELEGATED') '12 prose format word does not make trivial' ($r12 | ConvertTo-Json -Compress)

    # 13) explicit review beats research keyword
    $r13 = Get-OrchestrationPreflight -Objective 'review the pesquisa synthesis for correctness' -TaskType 'review' -Domain 'backend' -Risk 'medium' -ReadWrite 'read'
    Assert-That ((@($r13.selected_agents) -contains 'reviewer')) '13 review beats research keyword' ((@($r13.selected_agents)) -join ',')

    # 14) isolated release is not infra_mutation (H3 aligned with Acceptance)
    $hx14 = Get-OrchestrationHardExclusions -Objective 'prepare release notes draft for patch 1.2' -TaskType 'documentation' -Domain 'documentation' -Risk 'low' -ReadWrite 'read'
    Assert-That (-not (@($hx14.Tokens) -contains 'infra_mutation')) '14 isolated release is not infra_mutation' ((@($hx14.Tokens)) -join ',')

    # 15) DONE gate: post-execution compliance
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DELEGATED' -ActualWorkerParticipation 0) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 DELEGATED zero-worker => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DELEGATED' -ActualWorkerParticipation 2) -ceq 'COMPLIANT') '15 DELEGATED with workers => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DETERMINISTIC_FALLBACK' -DeterministicOwnerExecuted $false) -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 FALLBACK owner not run => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'DETERMINISTIC_FALLBACK' -DeterministicOwnerExecuted $true) -ceq 'COMPLIANT') '15 FALLBACK owner ran => COMPLIANT' 'expected compliant'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'non_trivial' -Decision 'BLOCKED') -ceq 'ORCHESTRATION_POLICY_BYPASS') '15 BLOCKED => BYPASS' 'expected bypass'
    Assert-That ((Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'TRIVIAL_DIRECT' -DirectReason 'DIRECT_COSMETIC_NO_LOGIC') -ceq 'COMPLIANT') '15 trivial valid token => COMPLIANT' 'expected compliant'

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
    Assert-That (($null -ne $o1) -and ([string]$o1.orchestration_decision -ceq 'TRIVIAL_DIRECT') -and ($null -ne $o1.evidence_hint)) 'cli trivial: JSON with evidence_hint' $c1.Text

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
