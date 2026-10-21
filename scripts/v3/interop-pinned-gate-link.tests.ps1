<#!
.SYNOPSIS
    O5 link fixture: delivery eligibility + resume readiness => pinned gate only.
.DESCRIPTION
    Run: powershell -NoProfile -File <this-file> (or pwsh). Exit 0/1.
    PS 5.1 compatible. ASCII-only. All fixtures in TEMP or in-memory;
    bundle fixture built in-test (no cross-repo reads); executor and
    persist are inert mocks. No network, no process spawn, no shell,
    no merge/deploy, no DONE claim, no second store.

    Link under test (in-test composer Invoke-O5Link, the ONLY productive
    entry exercised here, except probe 6b):
      Test-ObjectiveBundlePin (PIN_CURRENT else HOLD, zero calls)
      -> Test-OrchestrationMergeEligibility (eligible else HOLD, zero calls)
      -> Get-OrchestrationGitHubReadiness (READY_FOR_RESUME else HOLD, zero calls)
      -> Invoke-OcPinnedDeliveryGate (bundle pin vigente + injected mocks).
    Probe 6b is a gate-level UNIT check on Test-OcGateDecision (defense in
    depth, no executor, no productive link); it is not part of the O5Link
    single-entry harness.

    Receipt vocabulary: SOFT_ADVISORY/CONFIRMED on EXECUTED; FAILED/UNKNOWN
    surface as REMEDIATE/RECONCILE outcomes with null receipt. Never
    MEDIATED_ENFORCED, never DONE, never merge. Stale pin: zero executor
    and zero persist calls. Old SHA never authorizes a new HEAD. Self
    review never counts as independent. UNKNOWN reconciles with exactly
    one executor call (no ambiguous retry).
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationDeliveryGateAdapter.ps1'))
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationDelivery.ps1'))
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationGitHubResume.ps1'))

$total = 0
$passed = 0
function Assert-L($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function Write-Utf8NoBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}
function New-LinkBundle {
  return [ordered]@{
    schema = 'agent-profile-bundle/v1'
    bundle_id = 'agent-config:o5link01'
    source_repository = 'kust-projetos/agent-config'
    source_commit_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    target_runtime = 'opencode-v2'
    compatibility = [ordered]@{ dialect = 'v2'; minimum_capabilities = @('agents', 'permissions') }
    policy_refs = [ordered]@{ agent_profiles = 'p'; native_permissions = 'n'; risk_requirements = 'r'; capability_catalog = 'c' }
    agent_profiles = @(
      [ordered]@{ agent_id = 'coder'; mode = 'subagent'; native_permissions = @([ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }) })
    managed_paths = @([ordered]@{ resource = 'AGENTS.md'; namespace = 'agent-config:global'; owner = 'agent-config' })
    legacy_compatibility = [ordered]@{ v1_mutation = $false }
    format_version = 1
  }
}
function Write-LinkBundle($obj, $path) {
  $canon = Get-ConsumerCanonicalJson -Bundle $obj
  $digest = Get-ConsumerDigest -CanonicalJson $canon
  Write-Utf8NoBom $path (($canon.TrimEnd('}')) + ',"payload_digest":"' + $digest + '"}')
}
function New-LinkPolicy {
  return [pscustomobject]@{
    schema_version = 1
    require_pr = $true
    direct_push = 'deny'
    force_push = 'deny'
    deletion_protected = $true
    required_checks = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
    review = [pscustomobject]@{ internal_reviewer = 'required'; security_reviewer_on = @('auth', 'security-sensitive') }
    auto_merge = [pscustomobject]@{ allowed = $true; requires = @('policy_ok', 'risk_low_or_medium', 'all_checks_green', 'reviewer_approved', 'no_unresolved_p1') }
    terminal_states = @('MERGED', 'DELIVERY_BLOCKED', 'CANCELLED')
  }
}
function New-LinkEligChecks($conclusion) {
  $out = @()
  foreach ($n in @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')) {
    $out += [pscustomobject]@{ name = $n; conclusion = $conclusion }
  }
  return $out
}
function New-LinkSnapshot($headSha, $mode) {
  $checks = @()
  foreach ($n in @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')) {
    $st = 'COMPLETED'; $con = 'success'; $hs = $headSha
    if (($mode -ceq 'pending') -and ($n -ceq 'CI (ps7)')) { $st = 'IN_PROGRESS'; $con = $null }
    $checks += [pscustomobject]@{ name = $n; head_sha = $hs; status = $st; conclusion = $con }
  }
  $mergeable = 'MERGEABLE'; $review = 'APPROVED'; $complete = $true
  if ($mode -ceq 'unknown') { $mergeable = 'UNKNOWN' }
  $obs = ([datetime]::UtcNow.AddSeconds(-10)).ToUniversalTime().ToString('o')
  return [pscustomobject]@{
    repository = 'acme/app'; pr_number = 7; head_sha = $headSha; commit_sha = $headSha
    observed_at = $obs; pr_state = 'OPEN'; mergeable = $mergeable
    review_decision = $review; checks_complete = $complete; checks = $checks
  }
}
# In-test O5 composer: the single entry. Any pre-gate refusal returns
# link=HOLD with zero persist/executor calls (counters prove it).
function Invoke-O5Link($BundleLoad, $Pin, $Policy, $Snapshot, $NowUtc, $Authority, $Action, $Target, $Sha, $PolicyDigest, $Risk, $ReviewerIdentity, $HumanConfirmed, $EvidenceChannel, $PersistFn, $Executor, $ReviewerApproved, $UnresolvedP1) {
  $pinSt = Test-ObjectiveBundlePin -Pin $Pin -BundleLoad $BundleLoad
  if ($pinSt -cne 'PIN_CURRENT') {
    return [pscustomobject]@{ link = 'HOLD'; reason = ('stale-pin:' + $pinSt); gate = ([pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @(('STALE_BUNDLE_PIN:' + $pinSt)); receipt = $null }) }
  }
  $elig = Test-OrchestrationMergeEligibility -Policy $Policy -Checks (New-LinkEligChecks 'success') -ReviewerApproved $ReviewerApproved -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 $UnresolvedP1 -Risk $Risk
  if (-not [bool]$elig.eligible) {
    return [pscustomobject]@{ link = 'HOLD'; reason = ('ineligible:' + (($elig.reasons -join ','))); gate = ([pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @($elig.reasons); receipt = $null }) }
  }
  $rdy = Get-OrchestrationGitHubReadiness -Repository 'acme/app' -PrNumber 7 -ExpectedHeadSha $Sha -Snapshot $Snapshot -Policy $Policy -NowUtc $NowUtc -MaxAgeSeconds 300
  $rv = ([string]$rdy.readiness).Trim().ToUpperInvariant()
  if (($rv -cne 'READY_FOR_RESUME') -or (-not [bool]$rdy.ok)) {
    return [pscustomobject]@{ link = 'HOLD'; reason = ('not-ready:' + $rv); gate = ([pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @(('READINESS_' + $rv)); receipt = $null }) }
  }
  $g = Invoke-OcPinnedDeliveryGate -BundleLoad $BundleLoad -Pin $Pin -Authority $Authority -Action $Action -Target $Target -Sha $Sha -PolicyDigest $PolicyDigest -Risk $Risk -DeliveryChecks (New-LinkEligChecks 'success') -ReviewerIdentity $ReviewerIdentity -HumanConfirmed $HumanConfirmed -EvidenceChannel $EvidenceChannel -PersistFn $PersistFn -Executor $Executor -Policy $Policy
  return [pscustomobject]@{ link = 'GATE'; reason = ''; gate = $g }
}

$SHA_OLD = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$SHA_NEW = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('o5link-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$captured = New-Object System.Collections.ArrayList
try {
  $fx = Join-Path $tmpRoot 'bundle.json'
  Write-LinkBundle (New-LinkBundle) $fx
  $load = Read-AgentProfileBundle -LiteralPath $fx
  $policy = New-LinkPolicy
  $pin = New-ObjectiveBundlePin -Bundle $load.Bundle -ObjectiveId 'OBJ-O5LINK'

  # --- 1. single source: required set comes from the policy object, shape ok.
  $req = Get-OrchestrationDeliveryRequiredChecks $policy
  Assert-L ((Test-OrchestrationDeliveryPolicyShape $policy) -and ($null -ne $req) -and (@($req).Count -eq 5)) 'o5 policy shape + single required set' 'policy shape or required set broken'

  # --- 2. green: eligible + READY_FOR_RESUME => pinned gate EXECUTED, SOFT_ADVISORY/CONFIRMED, once.
  $nowGreen = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
  $auth = @{ authorized = $true; author = 'planner'; grants = @('deploy:staging'); environment = 'staging' }
  $pc = @{ n = 0 }; $ec = @{ n = 0 }
  $cPersist = { param($i) $pc.n++; return $true }.GetNewClosure()
  $cExec = { param($i, $e) $ec.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $snapGreen = New-LinkSnapshot $SHA_OLD 'green'
  $r = Invoke-O5Link $load $pin $policy $snapGreen $nowGreen $auth 'merge' 'main' $SHA_OLD 'pd1' 'low' 'bob' $false 'provider-api' $cPersist $cExec $true 0
  [void]$captured.Add(($r.gate | ConvertTo-Json -Depth 6 -Compress))
  Assert-L (($r.link -ceq 'GATE') -and ($r.gate.outcome -ceq 'EXECUTED') -and ($r.gate.receipt.outcome -ceq 'CONFIRMED') -and ($r.gate.receipt.enforcement -ceq 'SOFT_ADVISORY') -and ($pc.n -eq 1) -and ($ec.n -eq 1) -and ($r.gate.receipt.idempotency_key -ceq ('delivery|merge|main|' + $SHA_OLD))) 'o5 green executes once with advisory receipt' 'green path did not execute exactly once'

  # --- 3. ineligible (reviewer-pending) => HOLD before gate, zero calls.
  $pc3 = @{ n = 0 }; $ec3 = @{ n = 0 }
  $p3 = { param($i) $pc3.n++; return $true }.GetNewClosure()
  $e3 = { param($i, $e) $ec3.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r3 = Invoke-O5Link $load $pin $policy $snapGreen $nowGreen $auth 'merge' 'main' $SHA_OLD 'pd1' 'low' 'bob' $false 'provider-api' $p3 $e3 $false 0
  [void]$captured.Add(($r3.gate | ConvertTo-Json -Depth 4 -Compress))
  Assert-L (($r3.link -ceq 'HOLD') -and (($r3.reason) -match 'reviewer-pending') -and ($pc3.n -eq 0) -and ($ec3.n -eq 0)) 'o5 ineligible holds with zero calls' 'ineligible path reached executor/persist'

  # --- 4. readiness CHECKS_PENDING => HOLD before gate, zero calls.
  $pc4 = @{ n = 0 }; $ec4 = @{ n = 0 }
  $p4 = { param($i) $pc4.n++; return $true }.GetNewClosure()
  $e4 = { param($i, $e) $ec4.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $snapPend = New-LinkSnapshot $SHA_OLD 'pending'
  $r4 = Invoke-O5Link $load $pin $policy $snapPend $nowGreen $auth 'merge' 'main' $SHA_OLD 'pd1' 'low' 'bob' $false 'provider-api' $p4 $e4 $true 0
  [void]$captured.Add(($r4.gate | ConvertTo-Json -Depth 4 -Compress))
  Assert-L (($r4.link -ceq 'HOLD') -and (($r4.reason) -match 'CHECKS_PENDING') -and ($pc4.n -eq 0) -and ($ec4.n -eq 0)) 'o5 pending readiness holds with zero calls' 'pending path reached executor/persist'

  # --- 5. stale pin NEVER reaches persist, gate, or executor.
  $b2 = New-LinkBundle; $b2.bundle_id = 'agent-config:o5link02'
  Write-LinkBundle $b2 $fx
  $staleLoad = Read-AgentProfileBundle -LiteralPath $fx
  $pc5 = @{ n = 0 }; $ec5 = @{ n = 0 }
  $p5 = { param($i) $pc5.n++; return $true }.GetNewClosure()
  $e5 = { param($i, $e) $ec5.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r5 = Invoke-O5Link $staleLoad $pin $policy $snapGreen $nowGreen $auth 'merge' 'main' $SHA_OLD 'pd1' 'low' 'bob' $false 'provider-api' $p5 $e5 $true 0
  [void]$captured.Add(($r5.gate | ConvertTo-Json -Depth 4 -Compress))
  Assert-L (($r5.link -ceq 'HOLD') -and (($r5.gate.reasons -join ',') -match 'STALE_BUNDLE_PIN:STALE_POLICY') -and ($pc5.n -eq 0) -and ($ec5.n -eq 0)) 'o5 stale pin blocks with zero calls' 'stale pin reached persist/executor'

  # --- 6. old SHA never authorizes new HEAD: readiness STALE => HOLD, zero calls.
  $freshLoad = Read-AgentProfileBundle -LiteralPath $fx
  $pin2 = New-ObjectiveBundlePin -Bundle $freshLoad.Bundle -ObjectiveId 'OBJ-O5LINK'
  $snapNew = New-LinkSnapshot $SHA_NEW 'green'
  $pc6 = @{ n = 0 }; $ec6 = @{ n = 0 }
  $p6 = { param($i) $pc6.n++; return $true }.GetNewClosure()
  $e6 = { param($i, $e) $ec6.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r6 = Invoke-O5Link $freshLoad $pin2 $policy $snapNew $nowGreen $auth 'merge' 'main' $SHA_OLD 'pd1' 'low' 'bob' $false 'provider-api' $p6 $e6 $true 0
  [void]$captured.Add(($r6.gate | ConvertTo-Json -Depth 4 -Compress))
  Assert-L (($r6.link -ceq 'HOLD') -and (($r6.reason) -match 'STALE') -and ($pc6.n -eq 0) -and ($ec6.n -eq 0)) 'o5 old sha never authorizes new head' 'sha drift reached executor/persist'

  # --- 6b. UNIT (gate-level, outside the O5Link single entry): SHA binding still blocks drift (defense in depth, no executor involved).
  # Single-entry contract covers link cases via Invoke-O5Link; this probe isolates Test-OcGateDecision only.
  $gIntent = [pscustomobject]@{ sha = $SHA_NEW; policy_digest = 'pd1' }
  $gEv = [pscustomobject]@{ subject_sha = $SHA_OLD; digest = $SHA_OLD; policy_digest = 'pd1'; provenance = 'provider-api'; reviewer_identity = 'bob' }
  $gAuth = @{ authorized = $true; author = 'planner' }
  $gChecks = @()
  foreach ($n in @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')) {
    $gChecks += @{ id = $n; status = 'PASS'; reason = '' }
  }
  $g6b = Test-OcGateDecision -Authority $gAuth -Intent $gIntent -Risk 'low' -Checks $gChecks -Evidence $gEv -RequiredCheckIds @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
  [void]$captured.Add(($g6b | ConvertTo-Json -Depth 6 -Compress))
  Assert-L ((($g6b.decision -ceq 'POLICY_BLOCKED') -and ((($g6b.reasons -join ',')) -match 'SHA_DRIFT'))) 'o5 [unit-gate] sha drift blocked without executing' 'sha drift not blocked'

  # --- 7. self review is not independent: author == reviewer => blocked, zero executor calls (via O5Link single entry).
  $selfAuth = @{ authorized = $true; author = 'planner'; grants = @('deploy:staging'); environment = 'staging' }
  $pc7 = @{ n = 0 }; $ec7 = @{ n = 0 }
  $p7 = { param($i) $pc7.n++; return $true }.GetNewClosure()
  $e7 = { param($i, $e) $ec7.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $snapSelf = New-LinkSnapshot $SHA_NEW 'green'
  $nowSelf = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
  $r7 = Invoke-O5Link $freshLoad $pin2 $policy $snapSelf $nowSelf $selfAuth 'merge' 'main' $SHA_NEW 'pd1' 'medium' 'Planner' $false 'provider-api' $p7 $e7 $true 0
  [void]$captured.Add(($r7.gate | ConvertTo-Json -Depth 6 -Compress))
  Assert-L (($r7.link -ceq 'GATE') -and ((($r7.gate.reasons -join ',')) -match 'SELF_REVIEW') -and ($ec7.n -eq 0)) 'o5 self review blocked without executing' 'self review executed or not flagged'

  # --- 8. UNKNOWN executor => RECONCILE, exactly one call, null receipt (no ambiguous retry).
  $pc8 = @{ n = 0 }; $ec8 = @{ n = 0 }
  $p8 = { param($i) $pc8.n++; return $true }.GetNewClosure()
  $e8 = { param($i, $e) $ec8.n++; return @{ status = 'WEIRD' } }.GetNewClosure()
  $snap8 = New-LinkSnapshot $SHA_NEW 'green'
  $now8 = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
  $r8 = Invoke-O5Link $freshLoad $pin2 $policy $snap8 $now8 $auth 'merge' 'main' $SHA_NEW 'pd1' 'low' 'bob' $false 'provider-api' $p8 $e8 $true 0
  [void]$captured.Add(($r8.gate | ConvertTo-Json -Depth 6 -Compress))
  Assert-L (($r8.gate.outcome -ceq 'RECONCILE') -and ((($r8.gate.reasons -join ',')) -match 'EXECUTOR_UNKNOWN') -and ($ec8.n -eq 1) -and ($null -eq $r8.gate.receipt)) 'o5 unknown reconciles once without receipt' 'unknown did not reconcile exactly once'

  # --- 9. UNKNOWN readiness (mergeable UNKNOWN) => HOLD, zero calls, stable on re-evaluation.
  $pc9 = @{ n = 0 }; $ec9 = @{ n = 0 }
  $p9 = { param($i) $pc9.n++; return $true }.GetNewClosure()
  $e9 = { param($i, $e) $ec9.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $snapU = New-LinkSnapshot $SHA_NEW 'unknown'
  $now9 = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
  $r9a = Invoke-O5Link $freshLoad $pin2 $policy $snapU $now9 $auth 'merge' 'main' $SHA_NEW 'pd1' 'low' 'bob' $false 'provider-api' $p9 $e9 $true 0
  $r9b = Invoke-O5Link $freshLoad $pin2 $policy $snapU $now9 $auth 'merge' 'main' $SHA_NEW 'pd1' 'low' 'bob' $false 'provider-api' $p9 $e9 $true 0
  [void]$captured.Add(($r9a.gate | ConvertTo-Json -Depth 4 -Compress))
  Assert-L (($r9a.link -ceq 'HOLD') -and ($r9b.link -ceq 'HOLD') -and ($pc9.n -eq 0) -and ($ec9.n -eq 0)) 'o5 unknown readiness holds without retry' 'unknown readiness retried or called executor'

  # --- 10. fail-closed persist + vocabulary: missing persist blocks; no enforced/done/merge anywhere (via O5Link single entry).
  $ec10 = @{ n = 0 }
  $e10 = { param($i, $e) $ec10.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $snap10 = New-LinkSnapshot $SHA_NEW 'green'
  $now10 = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
  $r10 = Invoke-O5Link $freshLoad $pin2 $policy $snap10 $now10 $auth 'merge' 'main' $SHA_NEW 'pd1' 'low' 'bob' $false 'provider-api' $null $e10 $true 0
  [void]$captured.Add(($r10.gate | ConvertTo-Json -Depth 6 -Compress))
  $blob = ($captured -join ' ')
  Assert-L (($r10.link -ceq 'GATE') -and ($r10.gate.outcome -ceq 'POLICY_BLOCKED') -and ((($r10.gate.reasons -join ',')) -match 'PERSIST_FN_MISSING') -and ($ec10.n -eq 0)) 'o5 missing persist fails closed with zero executor calls' 'missing persist executed'
  Assert-L ((($blob) -notmatch 'MEDIATED_ENFORCED') -and (($blob) -notmatch '"DONE"') -and (($blob) -notmatch 'verified_pass') -and (($blob) -notmatch 'gh pr merge') -and (($blob) -notmatch 'git merge')) 'o5 never enforced, never done, never merge' 'forbidden vocabulary found'
}
finally {
  if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
