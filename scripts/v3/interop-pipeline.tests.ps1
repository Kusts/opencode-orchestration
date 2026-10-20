<#!
.SYNOPSIS
    Interop pipeline fixture (PLAN-ORCH O6.2: bundle->pin->gate->receipt).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    PS 5.1 compatible. All fixtures in TEMP; bundle fixture built in-test
    (no cross-repo reads); executor and persist are inert mocks.
    Chain: bundle load => objective pin => profile resolve => delivery gate
    => boundary receipt. Stale pin never reaches the gate. Pending CI
    remediates; same-SHA success executes once with a stable idempotency
    key. Nothing in the chain signs DONE (O3.5).
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
. (Join-Path $v3 (Join-Path 'lib' 'AgentProfileBundleConsumer.ps1'))
. (Join-Path $v3 (Join-Path 'lib' 'OrchestrationDeliveryGateAdapter.ps1'))

$total = 0
$passed = 0
function Assert-P($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function Write-Utf8NoBom($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}
function New-PipeBundle {
  return [ordered]@{
    schema = 'agent-profile-bundle/v1'
    bundle_id = 'agent-config:pipe01'
    source_repository = 'kust-projetos/agent-config'
    source_commit_sha = 'b' * 40
    target_runtime = 'opencode-v2'
    compatibility = [ordered]@{ dialect = 'v2'; minimum_capabilities = @('agents', 'permissions') }
    policy_refs = [ordered]@{ agent_profiles = 'p'; native_permissions = 'n'; risk_requirements = 'r'; capability_catalog = 'c' }
    agent_profiles = @(
      [ordered]@{ agent_id = 'coder'; mode = 'subagent'; native_permissions = @([ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }) },
      [ordered]@{ agent_id = 'tester'; mode = 'subagent'; native_permissions = @([ordered]@{ action = 'shell'; resource = 'git status *'; effect = 'allow' }) },
      [ordered]@{ agent_id = 'reviewer'; mode = 'subagent'; native_permissions = @([ordered]@{ action = 'shell'; resource = '*'; effect = 'deny' }) })
    managed_paths = @([ordered]@{ resource = 'AGENTS.md'; namespace = 'agent-config:global'; owner = 'agent-config' })
    legacy_compatibility = [ordered]@{ v1_mutation = $false }
    format_version = 1
  }
}
function Write-PipeBundle($obj, $path) {
  $canon = Get-ConsumerCanonicalJson -Bundle $obj
  $digest = Get-ConsumerDigest -CanonicalJson $canon
  Write-Utf8NoBom $path (($canon.TrimEnd('}')) + ',"payload_digest":"' + $digest + '"}')
}
$reqNames = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
function Pipe-Checks($conclusion) {
  $out = @()
  foreach ($n in $reqNames) { $out += @{ name = $n; conclusion = $conclusion } }
  return $out
}
$pipeAuth = @{ authorized = $true; author = 'planner'; grants = @('deploy:staging'); environment = 'staging' }
$execCount = @{ n = 0 }
$mockExec = { param($i, $e) $execCount.n++; return @{ status = 'PASS' } }.GetNewClosure()
$mockPersist = { param($i) return $true }.GetNewClosure()
function Invoke-PipeGate($checks, $reviewer, $risk) {
  return (Invoke-OcDeliveryGate -Authority $pipeAuth -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk $risk -DeliveryChecks $checks -ReviewerIdentity $reviewer -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $mockPersist -Executor $mockExec)
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('pipe-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
try {
  # --- 1. bundle loads, pin current.
  $fx = Join-Path $tmpRoot 'bundle.json'
  Write-PipeBundle (New-PipeBundle) $fx
  $load = Read-AgentProfileBundle -LiteralPath $fx
  Assert-P (($load.Ok) -and ($load.Code -ceq 'BUNDLE_OK')) 'pipe bundle loads'
  $pin = New-ObjectiveBundlePin -Bundle $load.Bundle -ObjectiveId 'OBJ-PIPE'
  Assert-P ((Test-ObjectiveBundlePin -Pin $pin -BundleLoad (Read-AgentProfileBundle -LiteralPath $fx)) -ceq 'PIN_CURRENT') 'pipe pin current'

  # --- 2. profiles resolve for coder/tester/reviewer lane.
  $okRes = $true
  foreach ($id in @('coder', 'tester', 'reviewer')) {
    $rr = Resolve-BundleAgentProfile -Bundle $load.Bundle -AgentId $id
    if (-not $rr.Ok) { $okRes = $false }
  }
  Assert-P ($okRes) 'pipe lane resolves'

  # --- 3. fresh pin flows through the REAL composition point and executes once.
  $freshLoad = Read-AgentProfileBundle -LiteralPath $fx
  $pc = @{ n = 0 }; $ec = @{ n = 0 }
  $cPersist = { param($i) $pc.n++; return $true }.GetNewClosure()
  $cExec = { param($i, $e) $ec.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $r = Invoke-OcPinnedDeliveryGate -BundleLoad $freshLoad -Pin $pin -Authority $pipeAuth -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk 'low' -DeliveryChecks (Pipe-Checks 'success') -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $cPersist -Executor $cExec
  Assert-P (($r.outcome -ceq 'EXECUTED') -and ($r.receipt.outcome -ceq 'CONFIRMED') -and ($r.receipt.enforcement -ceq 'SOFT_ADVISORY') -and ($pc.n -eq 1) -and ($ec.n -eq 1)) 'pipe pinned green executes once'

  # --- 4. stale pin NEVER reaches persist, gate, or executor (real composition).
  $b2 = New-PipeBundle; $b2.bundle_id = 'agent-config:pipe02'
  Write-PipeBundle $b2 $fx
  $staleLoad = Read-AgentProfileBundle -LiteralPath $fx
  $pc2 = @{ n = 0 }; $ec2 = @{ n = 0 }
  $cPersist2 = { param($i) $pc2.n++; return $true }.GetNewClosure()
  $cExec2 = { param($i, $e) $ec2.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $rs2 = Invoke-OcPinnedDeliveryGate -BundleLoad $staleLoad -Pin $pin -Authority $pipeAuth -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk 'low' -DeliveryChecks (Pipe-Checks 'success') -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $cPersist2 -Executor $cExec2
  Assert-P (($rs2.outcome -ceq 'POLICY_BLOCKED') -and (($rs2.reasons -join ',') -match 'STALE_BUNDLE_PIN:STALE_POLICY') -and ($pc2.n -eq 0) -and ($ec2.n -eq 0)) 'pipe stale pin blocks persist+gate+executor'

  # --- 5. pending CI remediates; same-SHA success executes (stable idempotency key).
  $rp = Invoke-PipeGate (Pipe-Checks 'pending') 'bob' 'low'
  $rs = Invoke-PipeGate (Pipe-Checks 'success') 'bob' 'low'
  Assert-P (($rp.outcome -ceq 'REMEDIATE') -and ($rs.outcome -ceq 'EXECUTED') -and ($rs.receipt.idempotency_key -ceq 'delivery|merge|main|abc123')) 'pipe pending-then-success with stable key'

  # --- 6. nothing in the chain signs DONE.
  $blobs = @(($r | ConvertTo-Json -Depth 6 -Compress), ($rs | ConvertTo-Json -Depth 6 -Compress))
  Assert-P ((($blobs -join ' ') -notmatch 'verified_pass|"done"|certificate')) 'pipe signs no DONE'

  # --- 7. incompatible bundle (wrong schema) => blocked before persist+executor.
  $bad = New-PipeBundle; $bad.schema = 'agent-profile-bundle/v9'
  Write-PipeBundle $bad $fx
  $badLoad = Read-AgentProfileBundle -LiteralPath $fx
  $pc3 = @{ n = 0 }; $ec3 = @{ n = 0 }
  $cPersist3 = { param($i) $pc3.n++; return $true }.GetNewClosure()
  $cExec3 = { param($i, $e) $ec3.n++; return @{ status = 'PASS' } }.GetNewClosure()
  $rb = Invoke-OcPinnedDeliveryGate -BundleLoad $badLoad -Pin $pin -Authority $pipeAuth -Action 'merge' -Target 'main' -Sha 'abc123' -PolicyDigest 'pd1' -Risk 'low' -DeliveryChecks (Pipe-Checks 'success') -ReviewerIdentity 'bob' -HumanConfirmed $false -EvidenceChannel 'provider-api' -PersistFn $cPersist3 -Executor $cExec3
  Assert-P ((($rb.outcome -ceq 'POLICY_BLOCKED') -and (($rb.reasons -join ',') -match 'STALE_BUNDLE_PIN') -and ($pc3.n -eq 0) -and ($ec3.n -eq 0))) 'pipe incompatible bundle blocked with zero calls'
}
finally {
  if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
