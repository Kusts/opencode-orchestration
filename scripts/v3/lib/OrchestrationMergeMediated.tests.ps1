<#!
.SYNOPSIS
    RED tests for OrchestrationMergeMediated.ps1 (ETAPA 6 6B).
.DESCRIPTION
    Run: powershell -NoProfile -File <this-file> (or pwsh). Exit 0/1.
    PS 5.1 compatible. All external effects injected (PersistFn, Executor,
    VerifyFn, ReceiptStore in-memory). No network, no gh, no merge real.
    These tests FAIL before the wiring (function missing) and PASS after.
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$lib = Join-Path $v3 'OrchestrationMergeMediated.ps1'

$total = 0
$passed = 0
function Assert-M($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}

# --- helper: load implementation if present (RED => missing) ---
$implOk = Test-Path $lib
if ($implOk) { . $lib }

function New-Policy {
  return @{
    schema_version = 1; require_pr = $true; direct_push = 'deny'; force_push = 'deny'
    required_checks = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
    review = @{ internal_reviewer = 'required'; security_reviewer_on = @() }
    auto_merge = @{ allowed = $true; requires = @('policy_ok', 'risk_low_or_medium', 'all_checks_green', 'reviewer_approved', 'no_unresolved_p1') }
  }
}
$shaGood = 'a' * 40
$shaOld = 'b' * 40
function New-Snap($headSha, $prState, $review, $conclusion) {
  $checks = @()
  foreach ($n in @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')) {
    $checks += @{ name = $n; head_sha = $headSha; status = 'COMPLETED'; conclusion = $conclusion }
  }
  return @{
    repository = 'kusts/opencode-orchestration'; pr_number = 99
    head_sha = $headSha; commit_sha = $headSha
    observed_at = ([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
    pr_state = $prState; mergeable = 'MERGEABLE'; review_decision = $review
    checks_complete = $true; checks = $checks
  }
}
function New-AuthGood {
  return @{ authorized = $true; author = 'planner'; grants = @('repo:merge'); environment = 'github:pr'; production_authorized = $true; credential_scope = @('gh:repo:merge') }
}
$persistOk = { param($i) return $true }.GetNewClosure()
$storeNew = { return @{} }.GetNewClosure()

# 0. implementation exists
Assert-M ($implOk) 'impl exists' 'OrchestrationMergeMediated.ps1 ausente'

if ($implOk) {
  # 1. CI verde em SHA antigo => STALE/head-mismatch, sem executar
  $execN = @{ n = 0 }
  $exec = { param($i,$e) $execN.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verify = { param($r,$p,$s) return @{ merged = $false; sha = ''; state = 'OPEN' } }.GetNewClosure()
  $store = @{}
  $r = Invoke-OrchestrationMergeMediated -Repository 'Kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaOld 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec -VerifyFn $verify -ReceiptStore $store -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r.outcome -ceq 'RECONCILE') -and ($execN.n -eq 0)) 'sha antigo reconcilia sem executar' (($r | ConvertTo-Json -Depth 4 -Compress))

  # 2. review pendente => REMEDIATE, sem executar
  $execN2 = @{ n = 0 }
  $exec2 = { param($i,$e) $execN2.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store2 = @{}
  $r2 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'REVIEW_REQUIRED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $false -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity '' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec2 -VerifyFn $verify -ReceiptStore $store2 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r2.outcome -ceq 'REMEDIATE') -and ($execN2.n -eq 0)) 'review pendente remedia' (($r2 | ConvertTo-Json -Depth 4 -Compress))

  # 3. changes requested => REMEDIATE
  $store3 = @{}
  $r3 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'CHANGES_REQUESTED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec2 -VerifyFn $verify -ReceiptStore $store3 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r3.outcome -ceq 'REMEDIATE')) 'changes requested remedia' (($r3 | ConvertTo-Json -Depth 4 -Compress))

  # 4. autoridade ausente => NEEDS_USER_AUTHORITY, zero executor
  $execN4 = @{ n = 0 }
  $exec4 = { param($i,$e) $execN4.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store4 = @{}
  $badAuth = @{ author = 'planner'; grants = @('repo:merge'); environment = 'github:pr'; production_authorized = $true; credential_scope = @('gh:repo:merge') }
  $r4 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $badAuth -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verify -ReceiptStore $store4 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r4.outcome -ceq 'NEEDS_USER_AUTHORITY') -and ($execN4.n -eq 0)) 'autoridade ausente precisa humano' (($r4 | ConvertTo-Json -Depth 4 -Compress))

  # 5. CREDENTIAL_SCOPE incompatível => POLICY_BLOCKED
  $store5 = @{}
  $badScope = New-AuthGood; $badScope.credential_scope = @('chat:read')
  $r5 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $badScope -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verify -ReceiptStore $store5 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r5.outcome -ceq 'POLICY_BLOCKED') -and (($r5.reasons -join ',') -match 'CREDENTIAL_SCOPE')) 'scope incompativel bloqueia' (($r5 | ConvertTo-Json -Depth 4 -Compress))

  # 6. grants divergentes (live vs snapshot) => RECONCILE via boundary
  $store6 = @{}
  $execN6 = @{ n = 0 }
  $exec6 = { param($i,$e) $execN6.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $driftPersist = { param($i) $script:driftIntent = $i; return $true }.GetNewClosure()
  # força drift: persiste com grants A, chama com Authority grants B — implementado via PersistFn que troca snapshot
  $driftAuth = New-AuthGood; $driftAuth.grants = @('outro:grant')
  $r6 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $driftAuth -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec6 -VerifyFn $verify -ReceiptStore $store6 -GoalId 'G1' -TaskId 'T1'
  # sem DryRun para exercitar boundary; grants repo:merge vs outro:grant devem ao menos persistir e decidir (EXECUTED ou RECONCILE), nunca pular validação
  Assert-M (($r6.outcome -in @('EXECUTED', 'RECONCILE', 'REMEDIATE', 'WAIT')) -and ($null -ne $r6.receipt -or $r6.outcome -cne 'EXECUTED')) 'grants divergentes decidem sem pular validacao' (($r6 | ConvertTo-Json -Depth 4 -Compress))

  # 7. falha/timeout do executor => RECONCILE, sem recibo CONFIRMED
  $store7 = @{}
  $failExec = { param($i,$e) throw 'timeout simulado' }.GetNewClosure()
  $r7 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExec -VerifyFn $verify -ReceiptStore $store7 -GoalId 'G1' -TaskId 'T1'
  Assert-M (($r7.outcome -ceq 'RECONCILE') -and ($null -eq $r7.receipt -or $r7.receipt.outcome -cne 'CONFIRMED')) 'timeout reconcilia' (($r7 | ConvertTo-Json -Depth 4 -Compress))

  # 8. merge remoto já aplicado, recibo local ausente => reconcilia sem re-executar
  $execN8 = @{ n = 0 }
  $exec8 = { param($i,$e) $execN8.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyMerged = { param($r,$p,$s) return @{ merged = $true; sha = $shaGood; state = 'MERGED' } }.GetNewClosure()
  $store8 = @{}
  $r8 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8 -VerifyFn $verifyMerged -ReceiptStore $store8 -GoalId 'G1' -TaskId 'T1'
  Assert-M ((($r8.outcome -ceq 'EXECUTED') -or ($r8.outcome -ceq 'REMEDIATE')) -and ($execN8.n -eq 0)) 'remoto mergeado nao re-executa' (($r8 | ConvertTo-Json -Depth 4 -Compress))

  # 9. replay idempotente => sem duplicar execução
  $execN9 = @{ n = 0 }
  $exec9 = { param($i,$e) $execN9.n++; return @{ status = 'PASS'; merged_sha = $shaGood } }.GetNewClosure()
  $verifyOk = { param($r,$p,$s) return @{ merged = $true; sha = $shaGood; state = 'MERGED' } }.GetNewClosure()
  $store9 = @{}
  $a1 = @{ authorized = $true; author = 'planner'; grants = @('repo:merge'); environment = 'github:pr'; production_authorized = $true; credential_scope = @('gh:repo:merge') }
  $first = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $a1 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec9 -VerifyFn $verifyOk -ReceiptStore $store9 -GoalId 'G1' -TaskId 'T1'
  $nAfterFirst = $execN9.n
  $second = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $a1 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec9 -VerifyFn $verifyOk -ReceiptStore $store9 -GoalId 'G1' -TaskId 'T1'
  Assert-M (($nAfterFirst -eq 1) -and ($execN9.n -eq 1) -and (($second.reasons -join ',') -match 'IDEMPOTENT_REPLAY')) 'replay idempotente' ("first=$nAfterFirst second_n=$($execN9.n) " + ($second | ConvertTo-Json -Depth 4 -Compress))

  # 10. string da LLM como aprovação nunca autoriza
  $store10 = @{}
  $execN10 = @{ n = 0 }
  $exec10 = { param($i,$e) $execN10.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r10 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'medium' -ReviewerApproved 'approved' -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed 'yes' -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec10 -VerifyFn $verify -ReceiptStore $store10 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r10.outcome -ne 'DRYRUN_OK') -and ($r10.outcome -ne 'EXECUTED') -and ($execN10.n -eq 0)) 'string LLM nao autoriza' (($r10 | ConvertTo-Json -Depth 4 -Compress))

  # 11. dry-run válido => DRYRUN_OK auditável, zero execução, recibo dry_run
  $execN11 = @{ n = 0 }
  $exec11 = { param($i,$e) $execN11.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store11 = @{}
  $r11 = Invoke-OrchestrationMergeMediated -Repository 'kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec11 -VerifyFn $verify -ReceiptStore $store11 -GoalId 'G1' -TaskId 'T1' -DryRun
  Assert-M (($r11.outcome -ceq 'DRYRUN_OK') -and ($execN11.n -eq 0) -and ($null -ne $r11.receipt) -and ($r11.receipt.dry_run -eq $true)) 'dry-run auditavel' (($r11 | ConvertTo-Json -Depth 4 -Compress))
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
