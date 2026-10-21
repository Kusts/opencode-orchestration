<#
.SYNOPSIS
    Owned-B mediated boundary for external actions (PLAN-ORCH O4.1-O4.7).
.DESCRIPTION
    Single choke-point: persist intent => gate => revalidate => execute =>
    receipt. PS 5.1 compatible. No network, no process spawn; the Executor
    is injected (test seam: mock scriptblock; production wiring is O5).
    - O4.2: missing/non-bool Authorized => NEEDS_USER_AUTHORITY (never the
      frozen permissive default). HumanApproved never substitutes signed
      scope / persisted objective.
    - O4.4: intent (goal, action, target, SHA/digest, payload hash,
      idempotency key) persisted BEFORE first effect; policy_digest / SHA /
      grants / environment revalidated immediately before the act.
    - O4.5: PASS evidence must carry trusted provenance; model strings never
      count as CI=PASS.
    - O4.6: PENDING records wait; FAIL returns remediation; post-mutation
      UNKNOWN demands remote-state reconcile before retry.
    - O4.7: unrestricted direct shell is NOT MEDIATED_ENFORCED; receipts say
      SOFT_ADVISORY when enforcement is unavailable.
    Decisions: ALLOW / NEEDS_USER_AUTHORITY / POLICY_BLOCKED / EXECUTED /
    WAIT / REMEDIATE / RECONCILE. Never DONE (O3.5).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'OrchestrationExternalActionGate.ps1')

function Get-OcBValue { param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $Default
}

function New-OcExternalIntent {
  [CmdletBinding()] param($Goal, [string]$Action, [string]$Target, [string]$Sha, [string]$Payload, [string]$IdempotencyKey, $Grants, [string]$Environment, [string]$PolicyDigest)
  # O4.4: authorization context snapshot is mandatory at creation.
  $g0 = @($Grants)
  if (($g0.Count -eq 0) -or ([string]::IsNullOrWhiteSpace([string]$Environment))) { throw 'New-OcExternalIntent requires non-empty Grants and Environment (O4.4 context snapshot).' }
  $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Payload)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { $ph = ([BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '')) }
  finally { $hasher.Dispose() }
  return [pscustomobject]@{
    goal = $Goal; action = $Action; target = $Target; sha = $Sha
    payload_hash = $ph; idempotency_key = $IdempotencyKey
    policy_digest = [string]$PolicyDigest
    grants_snapshot = @($g0); environment_snapshot = [string]$Environment
    persisted_at = ([DateTime]::UtcNow.ToString('o'))
  }
}

function Invoke-OcExternalActionBoundary {
  [CmdletBinding()] param($PersistedIntent, $Authority, [string]$Risk, $Checks, $Evidence, $Executor, $RequiredCheckIds, $PersistFn)
  # --- O4.2: no presumed authority. Missing/non-bool => NEEDS (fail-closed).
  $authRaw = Get-OcBValue $Authority 'authorized' $null
  if ($authRaw -isnot [bool]) {
    return [pscustomobject]@{ outcome = 'NEEDS_USER_AUTHORITY'; reasons = @('AUTHORITY_NOT_BOOLEAN'); receipt = $null }
  }
  # --- O4.4a: persist intent BEFORE any effect. The store is injected
  # (production wiring in O5 plugs the Objective store; no store is created
  # here). Persist failure => zero executor invocation. Strict receipt:
  # exactly one [bool] $true; incidental output plus $false is NOT persistence.
  if ($null -eq $PersistFn) {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('PERSIST_FN_MISSING'); receipt = $null }
  }
  $pok = $false
  try { $pout = @(& $PersistFn $PersistedIntent); if (($pout.Count -eq 1) -and ($pout[0] -is [bool]) -and ($pout[0] -eq $true)) { $pok = $true } }
  catch { $pok = $false }
  if (-not $pok) {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('PERSIST_FAILED'); receipt = $null }
  }
  # --- O4.4b: revalidate live grants/environment against the INTENT snapshot
  # (captured at creation, never from evidence pins). Missing snapshot =>
  # block: protection can never be silently disabled.
  $snapGrants = @(Get-OcBValue $PersistedIntent 'grants_snapshot' $null)
  $snapEnv = [string](Get-OcBValue $PersistedIntent 'environment_snapshot' '')
  if (($null -eq $snapGrants) -or ($snapGrants.Count -eq 0) -or ([string]::IsNullOrWhiteSpace($snapEnv))) {
    return [pscustomobject]@{ outcome = 'POLICY_BLOCKED'; reasons = @('INTENT_CONTEXT_INCOMPLETE'); receipt = $null }
  }
  $liveGrants = @(Get-OcBValue $Authority 'grants' @())
  $liveEnv = [string](Get-OcBValue $Authority 'environment' '')
  if (((@($liveGrants | Sort-Object) -join ',') -cne (@($snapGrants | Sort-Object) -join ','))) {
    return [pscustomobject]@{ outcome = 'RECONCILE'; reasons = @('GRANTS_DRIFT'); receipt = $null }
  }
  if ($liveEnv -cne $snapEnv) {
    return [pscustomobject]@{ outcome = 'RECONCILE'; reasons = @('ENV_DRIFT'); receipt = $null }
  }
  # --- Gate (precondition, never a delivery certificate).
  $g = Test-OcGateDecision -Authority $Authority -Intent $PersistedIntent -Risk $Risk -Checks $Checks -Evidence $Evidence -RequiredCheckIds $RequiredCheckIds
  if ($g.decision -ceq 'NEEDS_USER_AUTHORITY') {
    return [pscustomobject]@{ outcome = 'NEEDS_USER_AUTHORITY'; reasons = @($g.reasons); receipt = $null }
  }
  if ($g.decision -ceq 'POLICY_BLOCKED') {
    return [pscustomobject]@{ decision = $g.decision; outcome = 'REMEDIATE'; reasons = @($g.reasons); receipt = $null }
  }
  # --- O4.6: executor outcomes.
  if ($null -eq $Executor) {
    return [pscustomobject]@{ outcome = 'WAIT'; reasons = @('NO_EXECUTOR_WOULD_EXECUTE'); receipt = $null }
  }
  # --- O4.6b: executor exceptions (partial effect possible) => RECONCILE,
  # never an uncaught throw: the caller must not retry blindly.
  $er = $null
  try { $er = & $Executor $PersistedIntent $Evidence }
  catch {
    return [pscustomobject]@{ outcome = 'RECONCILE'; reasons = @('EXECUTOR_EXCEPTION'); receipt = $null }
  }
  $st = [string](Get-OcBValue $er 'status' 'UNKNOWN')
  if ($st -ceq 'PASS') {
    $receipt = [pscustomobject]@{
      action = $PersistedIntent.action; target = $PersistedIntent.target
      sha = $PersistedIntent.sha; payload_hash = $PersistedIntent.payload_hash
      idempotency_key = $PersistedIntent.idempotency_key
      enforcement = 'SOFT_ADVISORY'; outcome = 'CONFIRMED'
    }
    return [pscustomobject]@{ outcome = 'EXECUTED'; reasons = @('OK'); receipt = $receipt }
  }
  if ($st -ceq 'PENDING') {
    return [pscustomobject]@{ outcome = 'WAIT'; reasons = @('EXECUTOR_PENDING'); receipt = $null }
  }
  if ($st -ceq 'FAIL') {
    return [pscustomobject]@{ outcome = 'REMEDIATE'; reasons = @('EXECUTOR_FAIL'); receipt = $null }
  }
  return [pscustomobject]@{ outcome = 'RECONCILE'; reasons = @('EXECUTOR_UNKNOWN'); receipt = $null }
}
