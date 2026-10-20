<#!
.SYNOPSIS
    Tests for OrchestrationExternalActionGate.ps1 (PLAN-ORCH O3.6 RED-GREEN).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    No network, no external calls, TEMP fixtures only (none needed).
    PS 5.1 compatible (no multi-segment Join-Path, no param block).
    - low with passing checks => ALLOW without reviewer.
    - high without human/review => NEEDS_USER_AUTHORITY.
    - self-review => POLICY_BLOCKED. SHA drift => POLICY_BLOCKED.
    - N/A without reason => POLICY_BLOCKED; with reason => passes.
    - FAIL/PENDING/UNKNOWN never equal PASS.
    - untrusted evidence on high => POLICY_BLOCKED.
    - unknown risk => POLICY_BLOCKED. Non-bool authority => NEEDS.
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationExternalActionGate.ps1'))

$total = 0
$passed = 0
function Assert-Gate($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function New-Check($id, $status, $reason) {
  return @{ id = $id; status = $status; reason = $reason }
}
function New-Auth($authorized, $author) {
  return @{ authorized = $authorized; author = $author }
}
function New-Ev($prov, $reviewer, $sha, $human) {
  return @{ provenance = $prov; reviewer_identity = $reviewer; subject_sha = $sha; human_confirmed = $human }
}

$passChecks = @((New-Check 'c1' 'PASS' ''), (New-Check 'c2' 'PASS' ''))

# --- 1. low + passing checks => ALLOW, no reviewer needed.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'task-model' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'ALLOW')) 'low passes without reviewer'

# --- 2. high without human/review => NEEDS_USER_AUTHORITY.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'high' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'NEEDS_USER_AUTHORITY') -and ($r.reasons -contains 'HUMAN_REQUIRED') -and ($r.reasons -contains 'REVIEW_REQUIRED')) 'high without human/review NEEDS'

# --- 3. self-review => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'reviewer-human' 'alice' 'S1' $true)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'SELF_REVIEW')) 'self-review blocked'

# --- 4. SHA drift => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S2' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'SHA_DRIFT')) 'sha drift blocked'

# --- 5. N/A without reason => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'N/A' '')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and (($r.reasons -join ',') -match 'NA_WITHOUT_REASON')) 'N/A without reason blocked'

# --- 6. N/A with reason => passes that check.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'N/A' 'not applicable on windows')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'ALLOW')) 'N/A with reason allowed'

# --- 7a. FAIL never equals PASS.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'FAIL' '')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and (($r.reasons -join ',') -match 'CHECK_NOT_PASS')) 'FAIL blocked'

# --- 7b. PENDING never equals PASS.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'PENDING' '')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED')) 'PENDING blocked'

# --- 7c. UNKNOWN never equals PASS; string 'false'/invalid status blocked.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'false' '')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED')) 'string-false status blocked'

# --- 8. untrusted evidence on high => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'high' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'task-model' 'bob' 'S1' $true)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'UNTRUSTED_EVIDENCE')) 'untrusted evidence on high blocked'

# --- 9. unknown risk => POLICY_BLOCKED fail-closed.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'extreme' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'UNKNOWN_RISK')) 'unknown risk fail-closed'

# --- 10. non-bool authority => NEEDS (never presumed).
$r = Test-OcGateDecision -Authority @{ author = 'alice' } -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'NEEDS_USER_AUTHORITY') -and ($r.reasons -contains 'AUTHORITY_NOT_BOOLEAN')) 'missing authority NEEDS'

# --- 11a. medium without reviewer, review applicable => NEEDS.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; review_applicable = $true } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'NEEDS_USER_AUTHORITY')) 'medium without reviewer NEEDS'

# --- 11b. medium, review not applicable WITH waiver reason => ALLOW.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; review_applicable = $false; review_waiver_reason = 'docs-only change, no reviewer needed' } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'ALLOW')) 'medium waiver with reason allowed'

# --- 11c. medium waiver without reason => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; review_applicable = $false } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'REVIEW_WAIVER_WITHOUT_REASON')) 'medium waiver without reason blocked'

# --- 13. RISK 'MEDIUM' (uppercase) still requires review.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'MEDIUM' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'NEEDS_USER_AUTHORITY')) 'uppercase MEDIUM requires review'

# --- 14. missing author with required review => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority @{ authorized = $true } -Intent @{ sha = 'S1' } -Risk 'high' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' 'bob' 'S1' $true)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'AUTHOR_REQUIRED')) 'missing author with review blocked'

# --- 15. case-variant self-review (Alice vs alice) => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'Alice') -Intent @{ sha = 'S1' } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'reviewer-human' 'alice ' 'S1' $true)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'SELF_REVIEW')) 'case-variant self-review blocked'

# --- 16. required check set enforced: omission => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -Evidence (New-Ev 'ci-system' '' 'S1' $false) -RequiredCheckIds @('c1', 'security-scan')
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and (($r.reasons -join ',') -match 'REQUIRED_CHECK_MISSING')) 'omitted required check blocked'

# --- 17. duplicate check id => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @((New-Check 'c1' 'PASS' ''), (New-Check 'c1' 'PASS' '')) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and (($r.reasons -join ',') -match 'DUPLICATE_CHECK')) 'duplicate check blocked'

# --- 18. intent sha without evidence binding => POLICY_BLOCKED (no pass-through).
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'high' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' 'bob' '' $true)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'SHA_DRIFT')) 'missing evidence binding blocked'

# --- 19. policy digest drift => POLICY_BLOCKED; match => ALLOW.
$evPol = New-Ev 'ci-system' '' 'S1' $false; $evPol.policy_digest = 'pd2'
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; policy_digest = 'pd1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence $evPol
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'POLICY_DRIFT')) 'policy drift blocked'
$evPol2 = New-Ev 'ci-system' '' 'S1' $false; $evPol2.policy_digest = 'pd1'
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; policy_digest = 'pd1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence $evPol2
Assert-Gate (($r.decision -ceq 'ALLOW')) 'matching policy context allowed'

# --- 12. gate never signs DONE: result carries no DONE/verified_pass claim.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($null -eq $r.done) -and ($null -eq $r.verified_pass) -and ($null -eq $r.certificate)) 'gate signs no DONE'

# --- 20. check without id => POLICY_BLOCKED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks @(@{ status = 'PASS'; reason = '' }) -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'CHECK_WITHOUT_ID')) 'check without id blocked'

# --- 21. medium with neither side carrying SHA => EVIDENCE_BINDING_REQUIRED.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ action = 'x' } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' 'bob' '' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'EVIDENCE_BINDING_REQUIRED')) 'medium without binding blocked'

# --- 22. undeclared required set => POLICY_BLOCKED (omission by integrator).
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'low' -Checks $passChecks -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'REQUIRED_SET_UNDECLARED')) 'undeclared required set blocked'

# --- 23. unilateral policy digest (intent declares, evidence lacks) => blocked.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; policy_digest = 'pd1' } -Risk 'low' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'POLICY_DIGEST_MISSING')) 'unilateral policy digest blocked'

# --- 24. human_confirmed as string 'true' never satisfies high gate.
$evStr = New-Ev 'ci-system' 'bob' 'S1' 'true'
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1' } -Risk 'high' -Checks $passChecks -RequiredCheckIds @() -Evidence $evStr
Assert-Gate (($r.decision -ceq 'NEEDS_USER_AUTHORITY') -and ($r.reasons -contains 'HUMAN_REQUIRED')) 'string human flag rejected'

# --- 25. review_applicable as string => POLICY_BLOCKED invalid type.
$r = Test-OcGateDecision -Authority (New-Auth $true 'alice') -Intent @{ sha = 'S1'; review_applicable = 'false' } -Risk 'medium' -Checks $passChecks -RequiredCheckIds @() -Evidence (New-Ev 'ci-system' '' 'S1' $false)
Assert-Gate (($r.decision -ceq 'POLICY_BLOCKED') -and ($r.reasons -contains 'INVALID_REVIEW_APPLICABILITY')) 'string review_applicable blocked'

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
