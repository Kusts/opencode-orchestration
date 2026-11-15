<#
.SYNOPSIS
    Fixture-only diagnostic evaluator for external-action claims.
.DESCRIPTION
    This module performs no I/O and never treats a local claim as authority.
    It is fixture-only; diagnostics never authorize execution. Reason codes
    are deferred to avoid widening the diagnostic contract. Nonce replay
    matching is case-insensitive, conservatively treating case variants as used.
#>
[CmdletBinding()]
param()

function Test-OcExternalActionClaim {
  [CmdletBinding()]
  param(
    $Claim,
    [string]$ActionHash,
    [string[]]$UsedNonces = @(),
  [datetime]$Now = [datetime]::UtcNow
  )

  $present = $null -ne $Claim
  $binding = $false
  $fresh = $false
  $nonceUnused = $false
  $valid = $false
  if ($present -and ($Claim -is [System.Collections.IDictionary])) {
    $allowed = @('action_hash', 'scope', 'claimed_by', 'source', 'claimed_at', 'expires_at', 'nonce')
    $keys = @($Claim.Keys | ForEach-Object { [string]$_ })
    $shapeOk = ($keys.Count -eq $allowed.Count) -and
      (@($keys | Where-Object { $_ -notin $allowed }).Count -eq 0) -and
      (@($allowed | Where-Object { $_ -notin $keys }).Count -eq 0)
    if ($shapeOk) {
      $stringsOk = $true
      foreach ($name in $allowed) {
        if (($Claim[$name] -isnot [string]) -or [string]::IsNullOrWhiteSpace($Claim[$name])) { $stringsOk = $false }
      }
      $claimedAt = [datetimeoffset]::MinValue
      $expiresAt = [datetimeoffset]::MinValue
      $claimedText = [string]$Claim['claimed_at']
      $expiresText = [string]$Claim['expires_at']
      $isoPattern = '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z'
      $hasExplicitZone = { param($text) $text -cmatch $isoPattern }
      $datesOk = (& $hasExplicitZone $claimedText) -and (& $hasExplicitZone $expiresText) -and
        [datetimeoffset]::TryParse($claimedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$claimedAt) -and
        [datetimeoffset]::TryParse($expiresText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$expiresAt)
      if ($stringsOk -and $datesOk) {
        $claimedAt = $claimedAt.ToUniversalTime()
        $expiresAt = $expiresAt.ToUniversalTime()
        $nowUtc = $Now
        if ($Now.Kind -eq [DateTimeKind]::Local) { $nowUtc = $Now.ToUniversalTime() }
        elseif ($Now.Kind -eq [DateTimeKind]::Unspecified) { $nowUtc = [datetime]::SpecifyKind($Now, [DateTimeKind]::Utc) }
        $nowInstant = [datetimeoffset]::new($nowUtc)
        $valid = $true
        $binding = ([string]$Claim['action_hash'] -ceq $ActionHash) -and
          ([string]$Claim['scope'] -ceq 'external-action')
        $fresh = ($claimedAt -le $nowInstant) -and ($expiresAt -gt $nowInstant) -and ($expiresAt -gt $claimedAt)
        $nonceUnused = -not (@($UsedNonces) | Where-Object { [string]::Equals($_, $Claim['nonce'], [StringComparison]::OrdinalIgnoreCase) })
      }
    }
  }
  [pscustomobject]@{
    claim_present = [bool]$present; action_bound = [bool]$binding
    fresh = [bool]$fresh; nonce_unused = [bool]$nonceUnused
    well_formed = [bool]$valid; trust = 'UNVERIFIED_LOCAL'; effective = $false
  }
}
