<#
.SYNOPSIS
    Owned-B delivery-to-boundary wiring (PLAN-ORCH O5). PS 5.1 compatible.
.DESCRIPTION
    Adapter: delivery inputs (policy-required CI checks, reviewer, risk) =>
    gate inputs (required set, mapped checks, verified evidence) => intent
    (with grants/environment snapshot) => mediated boundary.
    - Required set comes from delivery-policy.json (canonical, no second
      table): Get-OrchestrationDeliveryRequiredChecks. Extras are discarded
      before evaluation (delivery rule FIX3); omission => REQUIRED_SET
      mechanics of the gate apply.
    - Conclusion mapping (provider vocabulary => gate vocabulary):
      success => PASS; failure/timed_out/cancelled/action_required => FAIL;
      pending/queued/in_progress/waiting/requested => PENDING;
      skipped => N/A (reason required, supplied as provider-skipped);
      null/non-string/anything else => UNKNOWN (fail-closed).
    - Provenance allowlist is explicit: the caller declares the evidence
      channel; only 'provider-api', 'ci-system', 'reviewer-human' are
      trusted. Anything else => 'untrusted' (high/critical blocked by gate).
    - Merge execution stays external (human/bot): this adapter decides the
      gate outcome only; $Executor is injected (fixture/mock in O5).
    No network, no process spawn, no state mutation.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationExternalActionBoundary.ps1')
. (Join-Path $PSScriptRoot 'AgentProfileBundleConsumer.ps1')

function Convert-OcDeliveryConclusion { param($Conclusion, [string]$Name)
  if ($Conclusion -isnot [string]) {
    return @{ id = [string]$Name; status = 'UNKNOWN'; reason = 'non-string conclusion' }
  }
  $c = ([string]$Conclusion).ToLowerInvariant()
  if ($c -ceq 'success') { return @{ id = [string]$Name; status = 'PASS'; reason = '' } }
  if ($c -in @('failure', 'timed_out', 'cancelled', 'action_required')) {
    return @{ id = [string]$Name; status = 'FAIL'; reason = ('provider:' + $c) }
  }
  if ($c -in @('pending', 'queued', 'in_progress', 'waiting', 'requested')) {
    return @{ id = [string]$Name; status = 'PENDING'; reason = ('provider:' + $c) }
  }
  if ($c -ceq 'skipped') {
    return @{ id = [string]$Name; status = 'N/A'; reason = ('provider skipped:' + [string]$Name) }
  }
  return @{ id = [string]$Name; status = 'UNKNOWN'; reason = ('unmapped conclusion:' + [string]$Conclusion) }
}

function Invoke-OcDeliveryGate {
  [CmdletBinding()] param($Authority, [string]$Action, [string]$Target, [string]$Sha, [string]$PolicyDigest, [string]$Risk, $DeliveryChecks, $ReviewerIdentity, $HumanConfirmed, [string]$EvidenceChannel, $PersistFn, $Executor, $Policy)
  $required = Get-OrchestrationDeliveryRequiredChecks $Policy
  if ($null -eq $required) {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('DELIVERY_POLICY_UNAVAILABLE'); receipt = $null }
  }
  $reqKeys = @{}
  foreach ($rn in @($required)) { $rk = ([string]$rn).ToLowerInvariant(); if (-not $reqKeys.ContainsKey($rk)) { $reqKeys[$rk] = [string]$rn } }
  $mapped = New-Object System.Collections.ArrayList
  foreach ($c in @($DeliveryChecks)) {
    $n = ''; $con = $null
    if ($null -ne $c) {
      if ($c -is [System.Collections.IDictionary]) {
        if ($c.Contains('name')) { $n = [string]$c['name'] }
        if ($c.Contains('conclusion')) { $con = $c['conclusion'] }
      } else {
        $p = $c.PSObject.Properties['name']; if ($null -ne $p) { $n = [string]$p.Value }
        $p2 = $c.PSObject.Properties['conclusion']; if ($null -ne $p2) { $con = $p2.Value }
      }
    }
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    if (-not $reqKeys.ContainsKey($n.ToLowerInvariant())) { continue }
    [void]$mapped.Add((Convert-OcDeliveryConclusion $con $reqKeys[$n.ToLowerInvariant()]))
  }
  $channel = [string]$EvidenceChannel
  $trusted = @('provider-api', 'ci-system', 'reviewer-human')
  $prov = 'untrusted'
  if ($channel -in $trusted) { $prov = $channel }
  $evidence = @{
    provenance = $prov; reviewer_identity = [string]$ReviewerIdentity
    subject_sha = [string]$Sha; digest = [string]$Sha
    policy_digest = [string]$PolicyDigest; human_confirmed = $HumanConfirmed
  }
  $grants = @()
  $env = ''
  if ($null -ne $Authority) {
    if ($Authority -is [System.Collections.IDictionary]) {
      if ($Authority.Contains('grants')) { $grants = @($Authority['grants']) }
      if ($Authority.Contains('environment')) { $env = [string]$Authority['environment'] }
    } else {
      $pg = $Authority.PSObject.Properties['grants']; if ($null -ne $pg) { $grants = @($pg.Value) }
      $pe = $Authority.PSObject.Properties['environment']; if ($null -ne $pe) { $env = [string]$pe.Value }
    }
  }
  try {
    $intent = New-OcExternalIntent -Goal 'delivery' -Action $Action -Target $Target -Sha $Sha -Payload ($Action + '|' + $Target + '|' + $Sha) -IdempotencyKey ('delivery|' + $Action + '|' + $Target + '|' + $Sha) -Grants $grants -Environment $env -PolicyDigest $PolicyDigest
  } catch {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('INTENT_CONTEXT_INVALID'); receipt = $null }
  }
  return (Invoke-OcExternalActionBoundary -PersistedIntent $intent -Authority $Authority -Risk $Risk -Checks @($mapped) -Evidence $evidence -RequiredCheckIds @($required) -PersistFn $PersistFn -Executor $Executor)
}

function Invoke-OcPinnedDeliveryGate {
  <#
  .SYNOPSIS
      Real composition point: bundle pin => delivery gate => boundary.
  .DESCRIPTION
      The ONLY supported entry for objective-bound delivery actions. A stale
      (or unavailable/incompatible) pin NEVER reaches the gate, the persist
      callback, or the executor: zero calls, POLICY_BLOCKED with the pin
      status. Fresh pins flow into Invoke-OcDeliveryGate unchanged.
  #>
  [CmdletBinding()] param($BundleLoad, $Pin, $Authority, [string]$Action, [string]$Target, [string]$Sha, [string]$PolicyDigest, [string]$Risk, $DeliveryChecks, $ReviewerIdentity, $HumanConfirmed, [string]$EvidenceChannel, $PersistFn, $Executor, $Policy)
  $st = Test-ObjectiveBundlePin -Pin $Pin -BundleLoad $BundleLoad
  if ($st -cne 'PIN_CURRENT') {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('STALE_BUNDLE_PIN:' + $st); receipt = $null }
  }
  return (Invoke-OcDeliveryGate -Authority $Authority -Action $Action -Target $Target -Sha $Sha -PolicyDigest $PolicyDigest -Risk $Risk -DeliveryChecks $DeliveryChecks -ReviewerIdentity $ReviewerIdentity -HumanConfirmed $HumanConfirmed -EvidenceChannel $EvidenceChannel -PersistFn $PersistFn -Executor $Executor -Policy $Policy)
}
