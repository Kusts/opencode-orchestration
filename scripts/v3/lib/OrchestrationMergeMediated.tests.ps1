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
  $verifyMerge6 = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = $repoGood; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
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
  $verifyAfterTimeout = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $r7b = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExecB -VerifyFn $verifyAfterTimeout -ReceiptStore $store7b -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok7b = (($r7b.outcome -ceq 'EXECUTED') -and ($null -ne $r7b.receipt) -and ([string]$r7b.receipt.pr_head_sha -ceq $shaGood) -and ([string]$r7b.receipt.merge_commit_sha -ceq $shaMerge) -and ([bool]$r7b.receipt.reconciled -eq $true))
  Assert-M ($ok7b) 'timeout apos efeito reconcilia EXECUTED' (($r7b | ConvertTo-Json -Depth 4 -Compress))

  # 8. merge remoto confirmado (MERGED + merge_commit distinto) => EXECUTED reconciliado sem re-executar
  $execN8 = @{ n = 0 }
  $exec8 = { param($i,$e) $execN8.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyMerged = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
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
  $verifyCommit = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store8d = @{}
  $r8d = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec8d -VerifyFn $verifyCommit -ReceiptStore $store8d -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok8d = (($r8d.outcome -ceq 'EXECUTED') -and ($execN8d.n -eq 1) -and ($null -ne $r8d.receipt) -and ([string]$r8d.receipt.pr_head_sha -ceq $shaGood) -and ([string]$r8d.receipt.merge_commit_sha -ceq $shaMerge) -and ([string]$r8d.receipt.merge_commit_sha -cne [string]$r8d.receipt.pr_head_sha))
  Assert-M ($ok8d) 'merge commit separa SHAs no recibo' (($r8d | ConvertTo-Json -Depth 4 -Compress))

  # 9. replay idempotente => sem duplicar execucao
  $execN9 = @{ n = 0 }
  $exec9 = { param($i,$e) $execN9.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyOk = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
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
  $verifyFile = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
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

  # T12. repository ausente => RECONCILE
  $execN12 = @{ n = 0 }
  $exec12 = { param($i,$e) $execN12.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyNoRepo = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store12 = @{}
  $r12 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec12 -VerifyFn $verifyNoRepo -ReceiptStore $store12 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r12.outcome -ceq 'RECONCILE') -and ($r12.outcome -cne 'EXECUTED')) 'T12 repository ausente reconcilia' (($r12 | ConvertTo-Json -Depth 4 -Compress))

  # T13. repository diferente => RECONCILE
  $execN13 = @{ n = 0 }
  $exec13 = { param($i,$e) $execN13.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyOtherRepo = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'other/repo'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store13 = @{}
  $r13 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec13 -VerifyFn $verifyOtherRepo -ReceiptStore $store13 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r13.outcome -ceq 'RECONCILE') -and ($r13.outcome -cne 'EXECUTED')) 'T13 repository diferente reconcilia' (($r13 | ConvertTo-Json -Depth 4 -Compress))

  # T14. pr_number ausente => RECONCILE
  $execN14 = @{ n = 0 }
  $exec14 = { param($i,$e) $execN14.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyNoPr = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store14 = @{}
  $r14 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec14 -VerifyFn $verifyNoPr -ReceiptStore $store14 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r14.outcome -ceq 'RECONCILE') -and ($r14.outcome -cne 'EXECUTED')) 'T14 pr ausente reconcilia' (($r14 | ConvertTo-Json -Depth 4 -Compress))

  # T15. pr_number diferente => RECONCILE
  $execN15 = @{ n = 0 }
  $exec15 = { param($i,$e) $execN15.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyOtherPr = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 100; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store15 = @{}
  $r15 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec15 -VerifyFn $verifyOtherPr -ReceiptStore $store15 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r15.outcome -ceq 'RECONCILE') -and ($r15.outcome -cne 'EXECUTED')) 'T15 pr diferente reconcilia' (($r15 | ConvertTo-Json -Depth 4 -Compress))

  # T16. metodo nao comprovado => RECONCILE verify-method-unproven (direto + Invoke)
  $noProof = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' }
  $d16 = Get-MMVerifiedMerge -VerifyResult $noProof -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d16.ok -eq $false)) -and ($d16.reasons -contains 'verify-method-unproven')) 'T16 direto metodo sem prova' (($d16 | ConvertTo-Json -Depth 4 -Compress))
  $execN16 = @{ n = 0 }
  $exec16 = { param($i,$e) $execN16.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyNoProof = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge' } }.GetNewClosure()
  $store16 = @{}
  $r16 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec16 -VerifyFn $verifyNoProof -ReceiptStore $store16 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r16.outcome -ceq 'RECONCILE') -and (($r16.reasons -join ',') -match 'verify-method-unproven')) 'T16 invoke metodo sem prova reconcilia' (($r16 | ConvertTo-Json -Depth 4 -Compress))

  # T17. metodo squash via Verify => POLICY_BLOCKED (direto + Invoke)
  $squashProof = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) }
  $d17 = Get-MMVerifiedMerge -VerifyResult $squashProof -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d17.ok -eq $false)) -and ($d17.reasons -contains 'MERGE_METHOD_PROHIBITED')) 'T17 direto squash bloqueia' (($d17 | ConvertTo-Json -Depth 4 -Compress))
  $execN17 = @{ n = 0 }
  $exec17 = { param($i,$e) $execN17.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifySquash = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store17 = @{}
  $r17 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec17 -VerifyFn $verifySquash -ReceiptStore $store17 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r17.outcome -ceq 'POLICY_BLOCKED') -and (($r17.reasons -join ',') -match 'MERGE_METHOD_PROHIBITED')) 'T17 invoke squash bloqueia' (($r17 | ConvertTo-Json -Depth 4 -Compress))

  # T18. merge_commit igual ao HEAD => RECONCILE verify-sha-mismatch (direto + Invoke)
  $sameSha = @{ merged = $true; merge_commit_sha = $shaGood; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) }
  $d18 = Get-MMVerifiedMerge -VerifyResult $sameSha -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d18.ok -eq $false)) -and ($d18.reasons -contains 'verify-sha-mismatch')) 'T18 direto sha igual rejeita' (($d18 | ConvertTo-Json -Depth 4 -Compress))
  $execN18 = @{ n = 0 }
  $exec18 = { param($i,$e) $execN18.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifySameSha = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaGood; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store18 = @{}
  $r18 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec18 -VerifyFn $verifySameSha -ReceiptStore $store18 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r18.outcome -ceq 'RECONCILE') -and (($r18.reasons -join ',') -match 'verify-sha-mismatch')) 'T18 invoke sha igual reconcilia' (($r18 | ConvertTo-Json -Depth 4 -Compress))

  # T19. direto: merge valido com SHA diferente + parents vinculo => ok=true
  $validProof = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; commit_parents = @($shaGood, ('d' * 40)) }
  $d19 = Get-MMVerifiedMerge -VerifyResult $validProof -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d19.ok -eq $true)) -and ([string]$d19.merge_commit_sha -ceq $shaMerge)) 'T19 direto merge valido ok' (($d19 | ConvertTo-Json -Depth 4 -Compress))

  # T20. timeout apos efeito com prova api_method => EXECUTED reconciliado
  $store20 = @{}
  $failExec20 = { param($i,$e) throw 'timeout simulado' }.GetNewClosure()
  $verifyApiProof = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; api_method = 'merge' } }.GetNewClosure()
  $r20 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExec20 -VerifyFn $verifyApiProof -ReceiptStore $store20 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  $ok20 = (($r20.outcome -ceq 'EXECUTED') -and ($null -ne $r20.receipt) -and ([bool]$r20.receipt.reconciled -eq $true) -and ([string]$r20.receipt.merge_commit_sha -ceq $shaMerge))
  Assert-M ($ok20) 'T20 timeout com prova api reconcilia' (($r20 | ConvertTo-Json -Depth 4 -Compress))

  # T21. timeout com Verify sem identidade/prova => RECONCILE sem CONFIRMED
  $store21 = @{}
  $failExec21 = { param($i,$e) throw 'timeout simulado' }.GetNewClosure()
  $verifyNoId = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge } }.GetNewClosure()
  $r21 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $failExec21 -VerifyFn $verifyNoId -ReceiptStore $store21 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r21.outcome -ceq 'RECONCILE') -and ($null -eq $r21.receipt -or $r21.receipt.outcome -cne 'CONFIRMED')) 'T21 timeout sem identidade reconcilia' (($r21 | ConvertTo-Json -Depth 4 -Compress))

  # T22. relogio fonte confiavel: Planner NowUtc forjado nao evita expiracao real
  $store22 = @{}
  $execN22 = @{ n = 0 }
  $exec22 = { param($i,$e) $execN22.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $expAuth22 = New-AuthGood; $expAuth22.expires_at = '2000-01-01T00:00:00Z'
  $r22 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'OPEN' 'APPROVED' 'success') -Policy (New-Policy) -Authority $expAuth22 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec22 -VerifyFn $verifyOpen -ReceiptStore $store22 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun -NowUtc '1999-01-01T00:00:00Z'
  Assert-M (($r22.outcome -ceq 'NEEDS_USER_AUTHORITY') -and (($r22.reasons -join ',') -match 'AUTHORITY_EXPIRED')) 'T22 relogio confiavel ignora NowUtc forjado' (($r22 | ConvertTo-Json -Depth 4 -Compress))

  # T23. relogio fonte confiavel 2: expiracao futura valida nao e afetada por NowUtc forjado futuro
  $store23 = @{}
  $execN23 = @{ n = 0 }
  $exec23 = { param($i,$e) $execN23.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $t23exp = ([datetime]::UtcNow.AddHours(2).ToString('o'))
  $t23now = ([datetime]::UtcNow.AddHours(3).ToString('o'))
  $auth23 = New-AuthGood; $auth23.expires_at = $t23exp
  $snap23 = New-Snap $shaGood 'OPEN' 'APPROVED' 'success'; $snap23.observed_at = $t23now
  $r23 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot $snap23 -Policy (New-Policy) -Authority $auth23 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec23 -VerifyFn $verifyOpen -ReceiptStore $store23 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun -NowUtc $t23now
  Assert-M (($r23.outcome -ceq 'DRYRUN_OK') -and ((($r23.reasons -join ',') -match 'AUTHORITY_EXPIRED') -eq $false)) 'T23 relogio confiavel ignora futuro forjado' (($r23 | ConvertTo-Json -Depth 4 -Compress))

  # T24. ClockFn confiavel: expiracao 2000 com relogio 1999 => nao expirada
  $store24 = @{}
  $execN24 = @{ n = 0 }
  $exec24 = { param($i,$e) $execN24.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $auth24 = New-AuthGood; $auth24.expires_at = '2000-01-01T00:00:00Z'
  $snap24 = New-Snap $shaGood 'OPEN' 'APPROVED' 'success'; $snap24.observed_at = '1999-01-01T00:00:00Z'
  $clock1999 = { return '1999-01-01T00:00:00Z' }.GetNewClosure()
  $r24 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot $snap24 -Policy (New-Policy) -Authority $auth24 -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec24 -VerifyFn $verifyOpen -ReceiptStore $store24 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge' -DryRun -ClockFn $clock1999
  Assert-M (($r24.outcome -ceq 'DRYRUN_OK') -and ((($r24.reasons -join ',') -match 'AUTHORITY_EXPIRED') -eq $false)) 'T24 ClockFn como fonte' (($r24 | ConvertTo-Json -Depth 4 -Compress))

  # T25. api_method squash com parents validos => POLICY_BLOCKED (direto + Invoke TERMINAL sem execucao)
  $apiSquash25 = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; api_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) }
  $d25 = Get-MMVerifiedMerge -VerifyResult $apiSquash25 -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d25.ok -eq $false)) -and ($d25.reasons -contains 'MERGE_METHOD_PROHIBITED')) 'T25 direto api squash bloqueia' (($d25 | ConvertTo-Json -Depth 4 -Compress))
  $execN25 = @{ n = 0 }
  $exec25 = { param($i,$e) $execN25.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyApiSquash25 = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; api_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store25 = @{}
  $r25 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec25 -VerifyFn $verifyApiSquash25 -ReceiptStore $store25 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r25.outcome -ceq 'POLICY_BLOCKED') -and (($r25.reasons -join ',') -match 'MERGE_METHOD_PROHIBITED') -and ($execN25.n -eq 0)) 'T25 invoke TERMINAL api squash bloqueia sem executar' (($r25 | ConvertTo-Json -Depth 4 -Compress))

  # T26. conflito merge_method=merge + api_method=squash => POLICY_BLOCKED (direto + Invoke TERMINAL sem execucao)
  $conflict26 = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; api_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) }
  $d26 = Get-MMVerifiedMerge -VerifyResult $conflict26 -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d26.ok -eq $false)) -and ($d26.reasons -contains 'MERGE_METHOD_PROHIBITED')) 'T26 direto conflito bloqueia' (($d26 | ConvertTo-Json -Depth 4 -Compress))
  $execN26 = @{ n = 0 }
  $exec26 = { param($i,$e) $execN26.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyConflict26 = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; api_method = 'squash'; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store26 = @{}
  $r26 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec26 -VerifyFn $verifyConflict26 -ReceiptStore $store26 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r26.outcome -ceq 'POLICY_BLOCKED') -and (($r26.reasons -join ',') -match 'MERGE_METHOD_PROHIBITED') -and ($execN26.n -eq 0)) 'T26 invoke TERMINAL conflito bloqueia sem executar' (($r26 | ConvertTo-Json -Depth 4 -Compress))

  # T27. campo de metodo nao-string presente => POLICY_BLOCKED (direto + Invoke TERMINAL sem execucao)
  $nonStr27 = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; api_method = 42; commit_parents = @($shaGood, ('d' * 40)) }
  $d27 = Get-MMVerifiedMerge -VerifyResult $nonStr27 -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d27.ok -eq $false)) -and ($d27.reasons -contains 'MERGE_METHOD_PROHIBITED')) 'T27 direto api_method int bloqueia' (($d27 | ConvertTo-Json -Depth 4 -Compress))
  $nonStr27b = @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 123; commit_parents = @($shaGood, ('d' * 40)) }
  $d27b = Get-MMVerifiedMerge -VerifyResult $nonStr27b -RepoCanon 'kusts/opencode-orchestration' -PrNum 99 -ExpectedHeadSha $shaGood
  Assert-M ((([bool]$d27b.ok -eq $false)) -and ($d27b.reasons -contains 'MERGE_METHOD_PROHIBITED')) 'T27 direto merge_method int bloqueia' (($d27b | ConvertTo-Json -Depth 4 -Compress))
  $execN27 = @{ n = 0 }
  $exec27 = { param($i,$e) $execN27.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $verifyNonStr27 = { param($r,$p,$s) return @{ merged = $true; merge_commit_sha = $shaMerge; repository = 'kusts/opencode-orchestration'; pr_number = 99; merge_method = 'merge'; api_method = 42; commit_parents = @($shaGood, ('d' * 40)) } }.GetNewClosure()
  $store27 = @{}
  $r27 = Invoke-OrchestrationMergeMediated -Repository $repoGood -PrNumber 99 -ExpectedHeadSha $shaGood -Snapshot (New-Snap $shaGood 'MERGED' 'APPROVED' 'success') -Policy (New-Policy) -Authority (New-AuthGood) -Risk 'low' -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $exec27 -VerifyFn $verifyNonStr27 -ReceiptStore $store27 -GoalId 'G1' -TaskId 'T1' -MergeMethod 'merge'
  Assert-M (($r27.outcome -ceq 'POLICY_BLOCKED') -and (($r27.reasons -join ',') -match 'MERGE_METHOD_PROHIBITED') -and ($execN27.n -eq 0)) 'T27 invoke TERMINAL metodo int bloqueia sem executar' (($r27 | ConvertTo-Json -Depth 4 -Compress))
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
