<#!
.SYNOPSIS
    Tests for OrchestrationMergeMediated.ps1 (ETAPA 6 6B, rodada final PR175).
.DESCRIPTION
    Run: powershell -NoProfile -File <this-file> (or pwsh). Exit 0/1.
    PS 5.1 compatible. All external effects injected (PersistFn, Executor,
    VerifyFn, ReceiptStore in-memory + file for restart proof). No network,
    no gh, no merge real. Uses canonical delivery-policy shape only.
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

$implOk = Test-Path $lib
if ($implOk) { . $lib }

function New-Policy {
  return @{
    schema_version = 1; require_pr = $true; direct_push = 'deny'; force_push = 'deny'
    deletion_protected = $true
    required_checks = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
    review = @{ internal_reviewer = 'required'; security_reviewer_on = @('auth', 'credentials', 'grants', 'permissions', 'infra', 'security-sensitive') }
    auto_merge = @{ allowed = $true; requires = @('policy_ok', 'risk_low_or_medium', 'all_checks_green', 'reviewer_approved', 'no_unresolved_p1') }
    terminal_states = @('MERGED', 'DELIVERY_BLOCKED', 'CANCELLED')
  }
}
$shaGood = 'a' * 40
$shaOld = 'b' * 40
$shaMerge = 'c' * 40
$repoGood = 'kusts/opencode-orchestration'
$scopeGood = 'github:merge:kusts/opencode-orchestration'
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
  return @{ authorized = $true; author = 'planner'; grants = @('repo:merge'); environment = 'github:pr'; production_authorized = $true; credential_scope = @('github:merge:kusts/opencode-orchestration') }
}
$persistOk = { param($i) return $true }.GetNewClosure()

Assert-M ($implOk) 'impl exists' 'OrchestrationMergeMediated.ps1 ausente'

if ($implOk) {
  $verifyOpen = { param($r,$p,$s) return @{ merged = $false; sha = ''; state = 'OPEN' } }.GetNewClosure()

  # 1. SHA antigo => STALE, sem executar
  $execN = @{ n = 0 }
  $exec = { param($i,$e) $execN.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store = @{}
  $r = Invoke-OrchestrationMergeMediated -Repository 'Kusts/opencode-orchestration' -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaOld 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec -VerifyFn $verifyOpen -ReceiptStore $store -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r.outcome -ceq 'RECONCILE') -and ($execN.n -eq 0)) 'sha antigo reconcilia sem executar' (($r | ConvertTo-Json -Depth 4 -Compress))

  # 2. review pendente => REMEDIATE
  $execN2 = @{ n = 0 }
  $exec2 = { param($i,$e) $execN2.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store2 = @{}
  $r2 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'REVIEW_REQUIRED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $false -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity '' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec2 -VerifyFn $verifyOpen -ReceiptStore $store2 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r2.outcome -ceq 'REMEDIATE') -and ($execN2.n -eq 0)) 'review pendente remedia' (($r2 | ConvertTo-Json -Depth 4 -Compress))

  # 3. changes requested => REMEDIATE
  $store3 = @{}
  $r3 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'CHANGES_REQUESTED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec2 -VerifyFn $verifyOpen -ReceiptStore $store3 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r3.outcome -ceq 'REMEDIATE')) 'changes requested remedia' (($r3 | ConvertTo-Json -Depth 4 -Compress))

  # 4. autoridade ausente => NEEDS_USER_AUTHORITY
  $execN4 = @{ n = 0 }
  $exec4 = { param($i,$e) $execN4.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store4 = @{}
  $badAuth = @{ author = 'planner'; grants = @('repo:merge'); environment = 'github:pr'; production_authorized = $true; credential_scope = @($scopeGood) }
  $r4 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $badAuth -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verifyOpen -ReceiptStore $store4 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r4.outcome -ceq 'NEEDS_USER_AUTHORITY') -and ($execN4.n -eq 0)) 'autoridade ausente precisa humano' (($r4 | ConvertTo-Json -Depth 4 -Compress))

  # 5. scope generico antigo => POLICY_BLOCKED (sem substring permissiva)
  $store5 = @{}
  $badScope = New-AuthGood; $badScope.credential_scope = @('gh:repo:merge')
  $r5 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $badScope -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verifyOpen -ReceiptStore $store5 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r5.outcome -ceq 'POLICY_BLOCKED') -and (($r5.reasons -join ',') -match 'CREDENTIAL_SCOPE')) 'scope generico bloqueia' (($r5 | ConvertTo-Json -Depth 4 -Compress))

  # 5b. scope somente-leitura => POLICY_BLOCKED
  $store5b = @{}
  $readScope = New-AuthGood; $readScope.credential_scope = @('github:read:kusts/opencode-orchestration')
  $r5b = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $readScope -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verifyOpen -ReceiptStore $store5b -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r5b.outcome -ceq 'POLICY_BLOCKED') -and ($execN4.n -eq 0)) 'scope leitura bloqueia' (($r5b | ConvertTo-Json -Depth 4 -Compress))

  # 5c. scope de outro repo => POLICY_BLOCKED
  $store5c = @{}
  $otherScope = New-AuthGood; $otherScope.credential_scope = @('github:merge:other/repo')
  $r5c = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $otherScope -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verifyOpen -ReceiptStore $store5c -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r5c.outcome -ceq 'POLICY_BLOCKED') -and (($r5c.reasons -join ',') -match 'CREDENTIAL_SCOPE_INSUFFICIENT')) 'scope outro repo bloqueia' (($r5c | ConvertTo-Json -Depth 4 -Compress))

  # 5d. autorizacao expirada => NEEDS_USER_AUTHORITY
  $store5d = @{}
  $expAuth = New-AuthGood; $expAuth.expires_at = '2000-01-01T00:00:00Z'
  $r5d = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $expAuth -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec4 -VerifyFn $verifyOpen -ReceiptStore $store5d -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun -NowUtc '2026-10-30T00:00:00Z'
  Assert-M (($r5d.outcome -ceq 'NEEDS_USER_AUTHORITY') -and (($r5d.reasons -join ',') -match 'AUTHORITY_EXPIRED')) 'autorizacao expirada bloqueia' (($r5d | ConvertTo-Json -Depth 4 -Compress))

  # 6. grants divergentes reais (persist vs live) => RECONCILE GRANTS_DRIFT sem efeito
  $store6 = @{}
  $execN6 = @{ n = 0 }
  $exec6 = { param($i,$e) $execN6.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $script:driftAuth6 = New-AuthGood
  $driftPersist6 = { param($i) $script:driftAuth6.grants = @('outro:grant'); return $true }.GetNewClosure()
  $verifyMerge6 = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = $repoGood; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $r6 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $script:driftAuth6 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $driftPersist6 -Executor $exec6 -VerifyFn $verifyMerge6 -ReceiptStore $store6 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r6.outcome -ceq 'RECONCILE') -and (($r6.reasons -join ',') -match 'GRANTS_DRIFT') -and ($execN6.n -eq 0) -and ($null -eq $r6.receipt)) 'grants divergentes bloqueiam sem efeito' (($r6 | ConvertTo-Json -Depth 4 -Compress))

  # 7. timeout com efeito remoto ausente => RECONCILE sem CONFIRMED
  $store7 = @{}
  $failExec = { param($i,$e) throw 'timeout simulado' }.GetNewClosure()
  $r7 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExec -VerifyFn $verifyOpen -ReceiptStore $store7 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r7.outcome -ceq 'RECONCILE') -and ($null -eq $r7.receipt -or $r7.receipt.outcome -cne 'CONFIRMED')) 'timeout sem efeito reconcilia' (($r7 | ConvertTo-Json -Depth 4 -Compress))

  # 7b. timeout apos efeito remoto bem-sucedido => EXECUTED reconciliado com ambos SHAs
  $store7b = @{}
  $failExecB = { param($i,$e) throw 'timeout apos merge real' }.GetNewClosure()
  $verifyAfterTimeout = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $r7b = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExecB -VerifyFn $verifyAfterTimeout -ReceiptStore $store7b -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok7b = (($r7b.outcome -ceq 'EXECUTED') -and ($null -ne $r7b.receipt) -and ([string]$r7b.receipt.pr_head_sha -ceq $shaGood) -and ([string]$r7b.receipt.merge_commit_sha -ceq $shaMerge) -and ([bool]$r7b.receipt.reconciled -eq $true))
  Assert-M ($ok7b) 'timeout apos efeito reconcilia EXECUTED' (($r7b | ConvertTo-Json -Depth 4 -Compress))

  # 8. merge remoto confirmado (MERGED + merge_commit distinto) => EXECUTED reconciliado sem re-executar
  $execN8 = @{ n = 0 }
  $exec8 = { param($i,$e) $execN8.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyMerged = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $store8 = @{}
  $r8 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8 -VerifyFn $verifyMerged -ReceiptStore $store8 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok8 = (($r8.outcome -ceq 'EXECUTED') -and ($execN8.n -eq 0) -and ($null -ne $r8.receipt) -and ([string]$r8.receipt.pr_head_sha -ceq $shaGood) -and ([string]$r8.receipt.merge_commit_sha -ceq $shaMerge))
  Assert-M ($ok8) 'remoto mergeado reconcilia sem re-executar' (($r8 | ConvertTo-Json -Depth 4 -Compress))

  # 8b. squash proibido pela policy
  $execN8b = @{ n = 0 }
  $exec8b = { param($i,$e) $execN8b.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store8b = @{}
  $r8b = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8b -VerifyFn $verifyOpen -ReceiptStore $store8b -GoalId 'G1' -TaskId 'T1' -MergeMethod 'squash'
  Assert-M (($r8b.outcome -ceq 'POLICY_BLOCKED') -and (($r8b.reasons -join ',') -match 'MERGE_METHOD_PROHIBITED') -and ($execN8b.n -eq 0)) 'squash proibido bloqueia' (($r8b | ConvertTo-Json -Depth 4 -Compress))

  # 8c. rebase proibido pela policy
  $execN8c = @{ n = 0 }
  $exec8c = { param($i,$e) $execN8c.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store8c = @{}
  $r8c = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8c -VerifyFn $verifyOpen -ReceiptStore $store8c -GoalId 'G1' -TaskId 'T1' -MergeMethod 'rebase'
  Assert-M (($r8c.outcome -ceq 'POLICY_BLOCKED') -and ($execN8c.n -eq 0)) 'rebase proibido bloqueia' (($r8c | ConvertTo-Json -Depth 4 -Compress))

  # 8d. merge commit real (Verify com merge_commit distinto) => EXECUTED com ambos SHAs
  $execN8d = @{ n = 0 }
  $exec8d = { param($i,$e) $execN8d.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyCommit = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $store8d = @{}
  $r8d = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8d -VerifyFn $verifyCommit -ReceiptStore $store8d -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok8d = (($r8d.outcome -ceq 'EXECUTED') -and ($execN8d.n -eq 1) -and ($null -ne $r8d.receipt) -and ([string]$r8d.receipt.pr_head_sha -ceq $shaGood) -and ([string]$r8d.receipt.merge_commit_sha -ceq $shaMerge) -and ([string]$r8d.receipt.merge_commit_sha -cne [string]$r8d.receipt.pr_head_sha))
  Assert-M ($ok8d) 'merge commit separa SHAs no recibo' (($r8d | ConvertTo-Json -Depth 4 -Compress))

  # 9. replay idempotente => sem duplicar execucao
  $execN9 = @{ n = 0 }
  $exec9 = { param($i,$e) $execN9.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyOk = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $store9 = @{}
  $a1 = New-AuthGood
  $first = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $a1 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec9 -VerifyFn $verifyOk -ReceiptStore $store9 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $nAfterFirst = $execN9.n
  $second = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $a1 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec9 -VerifyFn $verifyOk -ReceiptStore $store9 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($nAfterFirst -eq 1) -and ($execN9.n -eq 1) -and (($second.reasons -join ',') -match 'IDEMPOTENT_REPLAY')) 'replay idempotente' ("first=$nAfterFirst second_n=$($execN9.n) " + ($second | ConvertTo-Json -Depth 4 -Compress))

  # 9b. idempotencia apos reinicio via persistencia em arquivo + reconciliacao remota
  $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ('mm-restart-' + [guid]::NewGuid().ToString('N') + '.json')
  $execN9b = @{ n = 0 }
  $exec9b = { param($i,$e) $execN9b.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $persistFile = { param($i) [IO.File]::WriteAllText($tmpFile, (($i | ConvertTo-Json -Depth 6 -Compress))); return $true }.GetNewClosure()
  $verifyFile = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $store9b = @{}
  $firstB = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistFile -Executor $exec9b -VerifyFn $verifyFile -ReceiptStore $store9b -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $fileExists = Test-Path $tmpFile
  . $lib
  $storeRestart = @{}
  $execNRestart = @{ n = 0 }
  $execRestart = { param($i,$e) $execNRestart.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $secondB = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $execRestart -VerifyFn $verifyFile -ReceiptStore $storeRestart -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  try { if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force } } catch { }
  $ok9b = (($firstB.outcome -ceq 'EXECUTED') -and $fileExists -and ($secondB.outcome -ceq 'EXECUTED') -and ($execNRestart.n -eq 0) -and ($null -ne $secondB.receipt) -and ([string]$secondB.receipt.merge_commit_sha -ceq $shaMerge))
  Assert-M ($ok9b) 'restart reconcilia via remoto sem re-executar' (("fileExists=$fileExists restart_n=$($execNRestart.n) ") + ($secondB | ConvertTo-Json -Depth 4 -Compress))

  # 10. string da LLM como aprovacao nunca autoriza
  $store10 = @{}
  $execN10 = @{ n = 0 }
  $exec10 = { param($i,$e) $execN10.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r10 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'medium' -ReviewerApproved 'approved' -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed 'yes' -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec10 -VerifyFn $verifyOpen -ReceiptStore $store10 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r10.outcome -ne 'DRYRUN_OK') -and ($r10.outcome -ne 'EXECUTED') -and ($execN10.n -eq 0)) 'string LLM nao autoriza' (($r10 | ConvertTo-Json -Depth 4 -Compress))

  # 11. dry-run valido => DRYRUN_OK auditavel, zero execucao, recibo dry_run com pr_head
  $execN11 = @{ n = 0 }
  $exec11 = { param($i,$e) $execN11.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $store11 = @{}
  $r11 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec11 -VerifyFn $verifyOpen -ReceiptStore $store11 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun
  Assert-M (($r11.outcome -ceq 'DRYRUN_OK') -and ($execN11.n -eq 0) -and ($null -ne $r11.receipt) -and ($r11.receipt.dry_run -eq $true) -and ([string]$r11.receipt.pr_head_sha -ceq $shaGood)) 'dry-run auditavel' (($r11 | ConvertTo-Json -Depth 4 -Compress))
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
