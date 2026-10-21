<#!
.SYNOPSIS
    Tests for OrchestrationExternalActionBoundary.ps1 (PLAN-ORCH O4).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    PS 5.1 compatible. Executor is always an inert mock scriptblock.
    - missing/non-bool Authorized => NEEDS (fail-closed adaptation, O4.2).
    - grants/env drift => RECONCILE before any act (O4.4).
    - receipt says SOFT_ADVISORY, never MEDIATED_ENFORCED (O4.7).
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationExternalActionBoundary.ps1'))
$persistCalls = @{ n = 0 }
$persistOk = { param($i) $persistCalls.n++; return $true }.GetNewClosure()
$persistFail = { param($i) return $false }.GetNewClosure()

$total = 0
$passed = 0
function Assert-B($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function New-BAuth($authorized, $author) {
  return @{ authorized = $authorized; author = $author; grants = @('deploy:staging'); environment = 'staging' }
}
function New-BEv($prov, $reviewer, $sha, $human) {
  return @{ provenance = $prov; reviewer_identity = $reviewer; subject_sha = $sha; human_confirmed = $human; pinned_grants = @('deploy:staging'); pinned_environment = 'staging' }
}
function B-Intent($sha) {
  return (New-OcExternalIntent -Goal 'g1' -Action 'deploy.staging' -Target 'staging-web-01' -Sha $sha -Payload 'fake-payload' -IdempotencyKey 'K-001' -Grants @('deploy:staging') -Environment 'staging')
}
$okChecks = @(@{ id = 'c1'; status = 'PASS'; reason = '' })

# --- 1. missing Authorized => NEEDS (O4.2: no presumed authority).
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority @{ author = 'a' } -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $null
Assert-B (($r.outcome -ceq 'NEEDS_USER_AUTHORITY') -and ($r.reasons -contains 'AUTHORITY_NOT_BOOLEAN')) 'missing Authorized NEEDS'

# --- 2. Authorized=false => NEEDS even with HumanApproved=true.
$denyAuth = New-BAuth $false 'a'; $denyAuth.human_approved = $true
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority $denyAuth -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $null
Assert-B (($r.outcome -ceq 'NEEDS_USER_AUTHORITY')) 'denied authority NEEDS despite human flag'

# --- 3. grants drift => RECONCILE, no execution.
$mock = { param($i, $e) return @{ status = 'PASS' } }.GetNewClosure()
$driftAuth = New-BAuth $true 'a'; $driftAuth.grants = @('deploy:production')
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority $driftAuth -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $mock
Assert-B (($r.outcome -ceq 'RECONCILE') -and ($r.reasons -contains 'GRANTS_DRIFT')) 'grants drift reconciles'

# --- 4. env drift => RECONCILE.
$envAuth = New-BAuth $true 'a'; $envAuth.environment = 'production'
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority $envAuth -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $mock
Assert-B (($r.outcome -ceq 'RECONCILE') -and ($r.reasons -contains 'ENV_DRIFT')) 'env drift reconciles'

# --- 5. ALLOW + PASS => EXECUTED, SOFT_ADVISORY receipt, idempotency kept.
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $mock
Assert-B (($r.outcome -ceq 'EXECUTED') -and ($r.receipt.enforcement -ceq 'SOFT_ADVISORY') -and ($r.receipt.outcome -ceq 'CONFIRMED') -and ($r.receipt.idempotency_key -ceq 'K-001')) 'executed with honest receipt'

# --- 6. mock PENDING => WAIT.
$pend = { param($i, $e) return @{ status = 'PENDING' } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $pend
Assert-B (($r.outcome -ceq 'WAIT')) 'pending waits'

# --- 7. mock FAIL => REMEDIATE.
$fail = { param($i, $e) return @{ status = 'FAIL' } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $fail
Assert-B (($r.outcome -ceq 'REMEDIATE')) 'fail remediates'

# --- 8. mock UNKNOWN => RECONCILE.
$unk = { param($i, $e) return @{ status = 'WEIRD' } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $unk
Assert-B (($r.outcome -ceq 'RECONCILE')) 'unknown reconciles'

# --- 9. no executor => WAIT (would-execute, no effect).
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $null
Assert-B (($r.outcome -ceq 'WAIT')) 'no executor waits'

# --- 10. intent persistence: payload hash stable + persisted_at.
$i1 = B-Intent 'S1'; $i2 = B-Intent 'S1'
Assert-B ((($i1.payload_hash -ceq $i2.payload_hash)) -and (-not [string]::IsNullOrWhiteSpace($i1.persisted_at)) -and ($i1.idempotency_key -ceq 'K-001')) 'intent persisted with hash'

# --- 11. malicious off-route executor output ignored (only status vocabulary matters).
$evil = { param($i, $e) return @{ status = 'PASS'; done = $true; verified_pass = $true } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $evil
Assert-B (($r.outcome -ceq 'EXECUTED') -and ($null -eq $r.done) -and ($null -eq $r.verified_pass)) 'off-route executor claims ignored'


# --- 12. persist failure => POLICY_BLOCKED with ZERO executor calls.
$execCalls = @{ n = 0 }
$counting = { param($i, $e) $execCalls.n++; return @{ status = 'PASS' } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistFail -Executor $counting
Assert-B (($r.outcome -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'PERSIST_FAILED') -and ($execCalls.n -eq 0)) 'persist failure blocks with zero executor calls'

# --- 13. missing PersistFn => POLICY_BLOCKED (no unverified execution).
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -Executor $counting
Assert-B (($r.outcome -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'PERSIST_FN_MISSING')) 'missing persist fn blocked'

# --- 14. executor throws after partial effect => RECONCILE (never blind retry).
$sideFx = @{ n = 0 }
$thrower = { param($i, $e) $sideFx.n++; throw 'simulated transport failure after effect' }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $thrower
Assert-B (($r.outcome -ceq 'RECONCILE') -and ($r.reasons -contains 'EXECUTOR_EXCEPTION') -and ($sideFx.n -eq 1)) 'executor exception reconciles'

# --- 15. hand-made intent without context snapshot => INTENT_CONTEXT_INCOMPLETE.
$bare = [pscustomobject]@{ goal = 'g1'; action = 'deploy.staging'; target = 't'; sha = 'S1'; payload_hash = 'ph'; idempotency_key = 'K-001' }
$r = Invoke-OcExternalActionBoundary -PersistedIntent $bare -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $persistOk -Executor $counting
Assert-B (($r.outcome -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'INTENT_CONTEXT_INCOMPLETE')) 'snapshot-less intent blocked'

# --- 16. intent creation rejects empty context (fail-closed at creation).
$threw = $false
try { $null = New-OcExternalIntent -Goal 'g1' -Action 'a' -Target 't' -Sha 'S' -Payload 'p' -IdempotencyKey 'K' -Grants @() -Environment 'staging' } catch { $threw = $true }
Assert-B ($threw) 'empty grants rejected at creation'


# --- 17. noisy persist (incidental output + $false) => PERSIST_FAILED, zero executor calls.
$noisyCalls = @{ n = 0 }
$noisy = { param($i) 'diagnostico incidental'; return $false }.GetNewClosure()
$execCalls2 = @{ n = 0 }
$counting2 = { param($i, $e) $execCalls2.n++; return @{ status = 'PASS' } }.GetNewClosure()
$r = Invoke-OcExternalActionBoundary -PersistedIntent (B-Intent 'S1') -Authority (New-BAuth $true 'a') -Risk 'low' -Checks $okChecks -Evidence (New-BEv 'ci-system' '' 'S1' $false) -RequiredCheckIds @() -PersistFn $noisy -Executor $counting2
Assert-B (($r.outcome -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'PERSIST_FAILED') -and ($execCalls2.n -eq 0)) 'noisy persist fails closed with zero executor calls'
Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
