<#!
.SYNOPSIS
    Tests for OrchestrationDeliveryGateAdapter.ps1 (PLAN-ORCH O5).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    PS 5.1 compatible. Executor and persist are inert mocks; merge execution
    stays external. Required set comes from source/registry/delivery-policy.json.
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationDeliveryGateAdapter.ps1'))

$total = 0
$passed = 0
function Assert-D($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
$reqNames = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
function New-AllSuccess {
  $out = @()
  foreach ($n in $reqNames) { $out += @{ name = $n; conclusion = 'success' } }
  return $out
}
function New-Auth($ok, $author) {
  return @{ authorized = $ok; author = $author; grants = @('deploy:staging'); environment = 'staging' }
}
$persistOk = { param($i) return $true }.GetNewClosure()
$execOk = { param($i, $e) return @{ status = 'PASS' } }.GetNewClosure()
function Invoke-Delivery($auth, $risk, $checks, $reviewer, $human, $channel) {
  return (Invoke-OcDeliveryGate -Authority $auth -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk $risk -DeliveryChecks $checks -ReviewerIdentity $reviewer -HumanConfirmed $human -EvidenceChannel $channel -PersistFn $persistOk -Executor $execOk)
}

# --- 1. green + reviewed + low => EXECUTED.
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' (New-AllSuccess) 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'EXECUTED') -and ($r.receipt.enforcement -ceq 'SOFT_ADVISORY')) 'green reviewed low executed'

# --- 2. one failure => REMEDIATE.
$checks = New-AllSuccess; $checks[0] = @{ name = 'CI (ps51)'; conclusion = 'failure' }
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'REMEDIATE') -and (($r.reasons -join ',') -match 'CHECK_NOT_PASS')) 'failure remediates'

# --- 3. pending => REMEDIATE (gate blocks, never passes through).
$checks = New-AllSuccess; $checks[1] = @{ name = 'CI (ps7)'; conclusion = 'pending' }
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'REMEDIATE')) 'pending remediates'

# --- 4. omitted required check => REMEDIATE.
$checks = @((New-AllSuccess)[1..4])
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'REMEDIATE') -and (($r.reasons -join ',') -match 'REQUIRED_CHECK_MISSING')) 'omitted check remediates'

# --- 5. untrusted channel on high => REMEDIATE.
$r = Invoke-Delivery (New-Auth $true 'alice') 'high' (New-AllSuccess) 'bob' $true 'task-model'
Assert-D (($r.outcome -ceq 'REMEDIATE') -and ($r.reasons -contains 'UNTRUSTED_EVIDENCE')) 'untrusted high remediates'

# --- 6. null conclusion => UNKNOWN => REMEDIATE.
$checks = New-AllSuccess; $checks[2] = @{ name = 'CI (smoke opencode real)'; conclusion = $null }
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'REMEDIATE')) 'null conclusion remediates'

# --- 7. skipped with provider reason => passes that check (low).
$checks = New-AllSuccess; $checks[3] = @{ name = 'CI (v2 lane, perfil V2 provisionado)'; conclusion = 'skipped' }
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks '' $false 'provider-api'
Assert-D (($r.outcome -ceq 'EXECUTED')) 'skipped with reason allowed on low'

# --- 8. non-bool authority => NEEDS.
$r = Invoke-Delivery (@{ author = 'alice'; grants = @('deploy:staging'); environment = 'staging' }) 'low' (New-AllSuccess) '' $false 'provider-api'
Assert-D (($r.outcome -ceq 'NEEDS_USER_AUTHORITY')) 'non-bool authority needs'

# --- 9. medium without reviewer => NEEDS.
$r = Invoke-Delivery (New-Auth $true 'alice') 'medium' (New-AllSuccess) '' $false 'provider-api'
Assert-D (($r.outcome -ceq 'NEEDS_USER_AUTHORITY')) 'medium without reviewer needs'

# --- 10. high with human + reviewer trusted => EXECUTED.
$r = Invoke-Delivery (New-Auth $true 'alice') 'high' (New-AllSuccess) 'bob' $true 'provider-api'
Assert-D (($r.outcome -ceq 'EXECUTED')) 'high with human+reviewer executed'

# --- 11. extras outside required set are discarded.
$checks = New-AllSuccess + @(@{ name = 'EVIL-EXTRA'; conclusion = 'failure' })
$r = Invoke-Delivery (New-Auth $true 'alice') 'low' $checks 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'EXECUTED')) 'extras discarded'

# --- 12. unknown risk => POLICY_BLOCKED => REMEDIATE.
$r = Invoke-Delivery (New-Auth $true 'alice') 'extreme' (New-AllSuccess) 'bob' $false 'provider-api'
Assert-D (($r.outcome -ceq 'REMEDIATE') -and ($r.reasons -contains 'UNKNOWN_RISK')) 'unknown risk remediates'

# --- 13. contract: mocks inspect the intent (snapshot + policy digest bound).
$seen = @{ intent = $null; exec = 0 }
$capPersist = { param($i) $seen.intent = $i; return $true }.GetNewClosure()
$capExec = { param($i, $e) $seen.exec++; return @{ status = 'PASS' } }.GetNewClosure()
$r = Invoke-OcDeliveryGate -Authority (New-Auth $true 'alice') -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk 'low' -DeliveryChecks (New-AllSuccess) -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $capPersist -Executor $capExec
Assert-D (($r.outcome -ceq 'EXECUTED') -and ($seen.intent.policy_digest -ceq 'pd1') -and (($seen.intent.grants_snapshot -join ',') -ceq 'deploy:staging') -and ($seen.intent.environment_snapshot -ceq 'staging') -and ($seen.exec -eq 1)) 'intent carries bound context'

# --- 14. contract: authority without grants => INTENT_CONTEXT_INVALID, zero execution.
$seen2 = @{ exec = 0 }
$capExec2 = { param($i, $e) $seen2.exec++; return @{ status = 'PASS' } }.GetNewClosure()
$r = Invoke-OcDeliveryGate -Authority (@{ authorized = $true; author = 'alice' }) -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk 'low' -DeliveryChecks (New-AllSuccess) -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $persistOk -Executor $capExec2
Assert-D (($r.outcome -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'INTENT_CONTEXT_INVALID') -and ($seen2.exec -eq 0)) 'grantless authority blocked without execution'

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
