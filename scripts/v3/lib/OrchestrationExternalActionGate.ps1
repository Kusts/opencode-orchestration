<#
.SYNOPSIS
    Owned-B external-action gate (PLAN-ORCH O3.1-O3.5). PS 5.1 compatible.
.DESCRIPTION
    Single pipeline: ObjectiveAuthority + ExternalActionIntent + resolved risk
    + required checks + verified evidence => decision. Decisions are
    ALLOW / NEEDS_USER_AUTHORITY / POLICY_BLOCKED. The gate NEVER signs
    Task DONE / Goal DONE (O3.5): it is a precondition, not a delivery
    certificate. No network, no process spawn, no state mutation.
    Risk vocabulary: low / medium / high / critical (fail-closed on unknown).
    Check status vocabulary: PASS / FAIL / PENDING / UNKNOWN / N/A (N/A only
    with a non-empty reason; FAIL/PENDING/UNKNOWN never equal PASS).
    Evidence provenance: only 'ci-system', 'reviewer-human', 'provider-api'
    are trusted; anything else (e.g. 'task-model') is untrusted.
#>
[CmdletBinding()]
param()

function Get-OcGateValue { param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $Default
}

function Test-OcGateDecision {
  [CmdletBinding()] param($Authority, $Intent, [string]$Risk, $Checks, $Evidence, $RequiredCheckIds)
  $reasons = New-Object System.Collections.ArrayList
  $needHuman = $false

  # --- O3.2: normalize risk once; unknown (any case) fails closed.
  $Risk = ([string]$Risk).ToLowerInvariant()

  # --- O3.1a: authority must be explicit. Missing/unknown authority denies.
  $authorized = Get-OcGateValue $Authority 'authorized' $null
  if ($authorized -isnot [bool]) {
    [void]$reasons.Add('AUTHORITY_NOT_BOOLEAN')
    return [pscustomobject]@{ decision = 'NEEDS_USER_AUTHORITY'; reasons = @($reasons); risk = $Risk }
  }
  if ($authorized -ne $true) {
    [void]$reasons.Add('AUTHORITY_DENIED')
    return [pscustomobject]@{ decision = 'NEEDS_USER_AUTHORITY'; reasons = @($reasons); risk = $Risk }
  }

  # --- O3.2: risk vocabulary unified, fail-closed.
  if ($Risk -notin @('low', 'medium', 'high', 'critical')) {
    [void]$reasons.Add('UNKNOWN_RISK')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }

  # --- O3.1c: required checks. The required set must be EXPLICITLY declared
  # by the caller ($null = undeclared => blocked). An explicitly empty set is
  # legitimate (no required checks). Every required id must be present
  # exactly once; additional passing checks are permitted as extra evidence.
  $checks = @($Checks)
  if ($null -eq $RequiredCheckIds) {
    [void]$reasons.Add('REQUIRED_SET_UNDECLARED')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }
  $seen = @{}
  foreach ($c in $checks) {
    $cid = [string](Get-OcGateValue $c 'id' '')
    if ([string]::IsNullOrWhiteSpace($cid)) {
      [void]$reasons.Add('CHECK_WITHOUT_ID')
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
    if ($seen.ContainsKey($cid)) {
      [void]$reasons.Add(('DUPLICATE_CHECK:' + $cid))
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
    $seen[$cid] = $true
  }
  foreach ($rid in @($RequiredCheckIds)) {
    if (-not $seen.ContainsKey([string]$rid)) {
      [void]$reasons.Add(('REQUIRED_CHECK_MISSING:' + $rid))
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
  }
  if ($checks.Count -eq 0) {
    [void]$reasons.Add('NO_CHECKS_DEFINED')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }
  foreach ($c in $checks) {
    $id = [string](Get-OcGateValue $c 'id' 'unknown')
    $st = [string](Get-OcGateValue $c 'status' 'UNKNOWN')
    $rs = [string](Get-OcGateValue $c 'reason' '')
    if ($st -ceq 'PASS') { continue }
    if ($st -ceq 'N/A') {
      if ([string]::IsNullOrWhiteSpace($rs)) {
        [void]$reasons.Add(('NA_WITHOUT_REASON:' + $id))
        return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
      }
      continue
    }
    [void]$reasons.Add(('CHECK_NOT_PASS:' + $id + ':' + $st))
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }

  # --- O3.1b: SHA/policy binding. An identified intent requires a matching
  # evidence binding (absence is drift, not a pass-through); medium+ always
  # requires an evidence binding. Policy digest drift blocks when both sides
  # carry one.
  $intentSha = [string](Get-OcGateValue $Intent 'sha' '')
  if ([string]::IsNullOrWhiteSpace($intentSha)) { $intentSha = [string](Get-OcGateValue $Intent 'digest' '') }
  $evSha = [string](Get-OcGateValue $Evidence 'subject_sha' '')
  if ([string]::IsNullOrWhiteSpace($evSha)) { $evSha = [string](Get-OcGateValue $Evidence 'digest' '') }
  if (-not [string]::IsNullOrWhiteSpace($intentSha)) {
    if ([string]::IsNullOrWhiteSpace($evSha) -or ($intentSha -cne $evSha)) {
      [void]$reasons.Add('SHA_DRIFT')
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
  }
  elseif ($Risk -in @('medium', 'high', 'critical')) {
    [void]$reasons.Add('EVIDENCE_BINDING_REQUIRED')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }
  $intentPol = [string](Get-OcGateValue $Intent 'policy_digest' '')
  $evPol = [string](Get-OcGateValue $Evidence 'policy_digest' '')
  $intentHasPol = -not [string]::IsNullOrWhiteSpace($intentPol)
  $evHasPol = -not [string]::IsNullOrWhiteSpace($evPol)
  if ($intentHasPol -xor $evHasPol) {
    # One side declares a policy digest and the other does not: unbound.
    # Bilateral absence is explicitly allowed (no policy to bind).
    [void]$reasons.Add('POLICY_DIGEST_MISSING')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }
  if ($intentHasPol -and $evHasPol -and ($intentPol -cne $evPol)) {
    [void]$reasons.Add('POLICY_DRIFT')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }

  # --- O4.5/O3.6: evidence provenance. Untrusted source blocks high/critical.
  $prov = [string](Get-OcGateValue $Evidence 'provenance' 'untrusted')
  $trusted = @('ci-system', 'reviewer-human', 'provider-api')
  if (($prov -notin $trusted) -and ($Risk -in @('high', 'critical'))) {
    [void]$reasons.Add('UNTRUSTED_EVIDENCE')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }

  # --- O3.3/O3.4: reviewer independence (canonical identity compare).
  # When review is required, author identity is mandatory.
  $author = [string](Get-OcGateValue $Authority 'author' '')
  $reviewer = [string](Get-OcGateValue $Evidence 'reviewer_identity' '')
  $canonAuthor = $author.Trim().ToLowerInvariant()
  $canonReviewer = $reviewer.Trim().ToLowerInvariant()
  if ((-not [string]::IsNullOrWhiteSpace($canonAuthor)) -and (-not [string]::IsNullOrWhiteSpace($canonReviewer)) -and ($canonAuthor -ceq $canonReviewer)) {
    [void]$reasons.Add('SELF_REVIEW')
    return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
  }
  $reviewRequired = $false
  if ($Risk -in @('high', 'critical')) { $reviewRequired = $true }
  elseif ($Risk -ceq 'medium') {
    $reviewApplicable = Get-OcGateValue $Intent 'review_applicable' $true
    if ($reviewApplicable -isnot [bool]) {
      [void]$reasons.Add('INVALID_REVIEW_APPLICABILITY')
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
    if ($reviewApplicable -ne $false) { $reviewRequired = $true }
    else {
      $waiver = [string](Get-OcGateValue $Intent 'review_waiver_reason' '')
      if ([string]::IsNullOrWhiteSpace($waiver)) {
        [void]$reasons.Add('REVIEW_WAIVER_WITHOUT_REASON')
        return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
      }
    }
  }
  if ($reviewRequired) {
    if ([string]::IsNullOrWhiteSpace($canonAuthor)) {
      [void]$reasons.Add('AUTHOR_REQUIRED')
      return [pscustomobject]@{ decision = 'POLICY_BLOCKED'; reasons = @($reasons); risk = $Risk }
    }
    if ([string]::IsNullOrWhiteSpace($canonReviewer)) { $needHuman = $true }
    if ($Risk -in @('high', 'critical')) {
      # Strict bool: strings like 'true' never satisfy human confirmation.
      $humanOk = Get-OcGateValue $Evidence 'human_confirmed' $false
      if (($humanOk -isnot [bool]) -or ($humanOk -ne $true)) { $needHuman = $true }
    }
    if ([string]::IsNullOrWhiteSpace($canonReviewer)) {
      [void]$reasons.Add('REVIEW_REQUIRED')
    }
    if (($Risk -in @('high', 'critical')) -and (($humanOk -isnot [bool]) -or ($humanOk -ne $true))) {
      [void]$reasons.Add('HUMAN_REQUIRED')
    }
  }
  # low: no reviewer call required (O3.6), no fanout.

  if ($needHuman) {
    return [pscustomobject]@{ decision = 'NEEDS_USER_AUTHORITY'; reasons = @($reasons); risk = $Risk }
  }
  [void]$reasons.Add('OK')
  return [pscustomobject]@{ decision = 'ALLOW'; reasons = @($reasons); risk = $Risk }
}
