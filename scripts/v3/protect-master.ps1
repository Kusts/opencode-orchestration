<#!
.SYNOPSIS
    Local guard against direct-master writes (Phase 2E git governance).
.DESCRIPTION
    Blocklist classifier for intended git command lines. It never executes
    a git write; it only classifies an intended command as ALLOW or DENY
    with a reason code. Read-only branch detection (`git branch
    --show-current`) is the only git invocation, CLI mode only, best-effort.
    Dot-sourceable library (no execution on load):
      . ./protect-master.ps1
      Test-GitOperationAllowed -CommandLine 'git push origin master' -CurrentBranch 'feat/x'
    Guard processual/opt-in: classifica sem executar; nao esta instalado
    como git hook; enforcement remoto (branch protection) pendente de
    autorizacao do operador.
    CLI mode (classify one command; exit 0 = ALLOW, exit 1 = DENY):
      powershell -NoProfile -File protect-master.ps1 -CommandLine 'git push origin master' [-CurrentBranch 'feat/x']
    Denied patterns (fail-closed):
      (a) direct commit on master (current branch is master + commit op)
      (b) push to origin master / refs/heads/master (DIRECT_MASTER_PUSH);
          surrounding single/double quotes are stripped before matching
          (ex: "master" matches master); --all and --mirror are denied
          fail-closed (may update master; push explicit refspecs instead)
      (c) force push (--force / --force-with-lease / -f / +refspec) that
          touches master (FORCE_PUSH); force with no explicit target while
          on master (or on an unknown branch) is also denied
      (d) delete of master (`--delete master` or `:master` refspec)
    Allowed: checkout/pull/log/status/fetch/diff (OK_READONLY), feature
    branch pushes and other well-formed local workflow commands
    (OK_FEATURE_BRANCH). There is intentionally NO docs-only exemption:
    committing docs while on master is still DIRECT_MASTER_COMMIT.
    Anything that fails to parse as a git command is denied fail-closed
    (UNKNOWN_OPERATION); a commit with an unknown branch is denied
    (UNKNOWN_BRANCH). Unknown but well-formed git commands are allowed
    because this guard is a master-protection blocklist, not a general
    allowlist. PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
  [string]$CommandLine = '',
  [string]$CurrentBranch = ''
)

$ErrorActionPreference = 'Stop'

function New-GitGuardResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][bool]$Allowed,
    [Parameter(Mandatory = $true)][string]$ReasonCode,
    [string]$Message = ''
  )
  $verdict = 'DENY'
  if ($Allowed) { $verdict = 'ALLOW' }
  return [PSCustomObject]@{
    Allowed    = $Allowed
    Verdict    = $verdict
    ReasonCode = $ReasonCode
    Message    = $Message
  }
}

function Get-StrippedGitToken {
  [CmdletBinding()]
  param([string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
  $t = $Token.Trim()
  if ($t.Length -ge 2) {
    $first = $t[0]
    $last = $t[$t.Length - 1]
    if ((($first -ceq '"') -or ($first -ceq "'")) -and ($last -ceq $first)) {
      $t = $t.Substring(1, $t.Length - 2).Trim()
    }
  }
  return $t
}

function Test-PushTokenTargetsMaster {
  [CmdletBinding()]
  param([string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
  $t = Get-StrippedGitToken -Token $Token
  if ($t -ceq 'master') { return $true }
  if ($t -ceq 'refs/heads/master') { return $true }
  if ($t -cmatch '\A:(refs/heads/)?master\Z') { return $true }
  if ($t -cmatch '\A\+(refs/heads/)?master\Z') { return $true }
  if ($t -cmatch '\A\+(refs/heads/)?master:') { return $true }
  if ($t -cmatch '\A\+?.*:(refs/heads/)?master\Z') { return $true }
  return $false
}

function Test-PushTokenIsDeleteMasterRefspec {
  [CmdletBinding()]
  param([string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
  $t = Get-StrippedGitToken -Token $Token
  if ($t -cmatch '\A:(refs/heads/)?master\Z') { return $true }
  return $false
}

function Test-PushTokenIsPlusMasterRefspec {
  [CmdletBinding()]
  param([string]$Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
  $t = Get-StrippedGitToken -Token $Token
  if ($t.StartsWith('+') -and (Test-PushTokenTargetsMaster -Token $t)) { return $true }
  return $false
}

function Test-GitOperationAllowed {
  <#
  .SYNOPSIS
      Classifies an intended git command line without executing it.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$CommandLine,
    [string]$CurrentBranch = ''
  )
  $branch = ''
  if (-not [string]::IsNullOrWhiteSpace($CurrentBranch)) { $branch = $CurrentBranch.Trim() }
  $raw = ''
  if ($null -ne $CommandLine) { $raw = ([string]$CommandLine).Trim() }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return (New-GitGuardResult -Allowed $false -ReasonCode 'UNKNOWN_OPERATION' -Message 'empty command line denied fail-closed')
  }
  $tokens = @($raw -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if (($tokens.Count -eq 0) -or ($tokens[0].ToLowerInvariant() -ne 'git')) {
    return (New-GitGuardResult -Allowed $false -ReasonCode 'UNKNOWN_OPERATION' -Message 'not a git command; denied fail-closed')
  }
  $i = 1
  $sub = ''
  while ($i -lt $tokens.Count) {
    $t = $tokens[$i]
    if (($t -ceq '-C') -or ($t -ceq '-c')) { $i += 2; continue }
    if ($t.StartsWith('-')) { $i++; continue }
    $sub = $t.ToLowerInvariant()
    break
  }
  if ([string]::IsNullOrWhiteSpace($sub)) {
    return (New-GitGuardResult -Allowed $false -ReasonCode 'UNKNOWN_OPERATION' -Message 'no git subcommand found; denied fail-closed')
  }
  if ($sub -ceq 'commit') {
    if ($branch -ceq 'master') {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DIRECT_MASTER_COMMIT' -Message 'direct commit on master is blocked; use a feature branch + PR (no docs-only exemption)')
    }
    if ([string]::IsNullOrWhiteSpace($branch)) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'UNKNOWN_BRANCH' -Message 'current branch unknown; commit denied fail-closed')
    }
    return (New-GitGuardResult -Allowed $true -ReasonCode 'OK_FEATURE_BRANCH' -Message ('commit on branch "{0}" is allowed' -f $branch))
  }
  if ($sub -ceq 'push') {
    $rest = @()
    if (($i + 1) -lt $tokens.Count) { $rest = @($tokens[($i + 1)..($tokens.Count - 1)]) }
    $forceFlag = $false
    $deleteFlag = $false
    $broadFlag = $false
    foreach ($t in $rest) {
      $nt = Get-StrippedGitToken -Token $t
      if (($nt -ceq '--force') -or ($nt -ceq '-f') -or ($nt -ceq '--force-with-lease') -or ($nt -cmatch '\A--force-with-lease=.*\Z')) { $forceFlag = $true }
      if (($nt -ceq '--delete') -or ($nt -ceq '-d')) { $deleteFlag = $true }
      if (($nt -ceq '--all') -or ($nt -ceq '--mirror')) { $broadFlag = $true }
    }
    $positionals = @($rest | Where-Object { -not (Get-StrippedGitToken -Token $_).StartsWith('-') })
    $anyMaster = $false
    $deleteMasterRefspec = $false
    $plusMaster = $false
    foreach ($p in $positionals) {
      if (Test-PushTokenTargetsMaster -Token $p) { $anyMaster = $true }
      if (Test-PushTokenIsDeleteMasterRefspec -Token $p) { $deleteMasterRefspec = $true }
      if (Test-PushTokenIsPlusMasterRefspec -Token $p) { $plusMaster = $true }
    }
    $implicitRisky = (([string]::IsNullOrWhiteSpace($branch)) -or ($branch -ceq 'master'))
    if ($broadFlag) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DIRECT_MASTER_PUSH' -Message 'push --all/--mirror denied fail-closed: may update protected branch master; push explicit refspecs instead')
    }
    if ($deleteMasterRefspec) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DELETE_PROTECTED' -Message 'deleting refs/heads/master via refspec is blocked')
    }
    if ($deleteFlag -and $anyMaster) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DELETE_PROTECTED' -Message 'deleting protected branch master is blocked')
    }
    if ($plusMaster) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'FORCE_PUSH' -Message 'force-push refspec touching master is blocked')
    }
    if ($forceFlag -and $anyMaster) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'FORCE_PUSH' -Message 'force push touching protected branch master is blocked')
    }
    if ($forceFlag -and ($positionals.Count -le 1) -and $implicitRisky) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'FORCE_PUSH' -Message 'force push with implicit target while on master/unknown branch is blocked fail-closed')
    }
    if ($anyMaster) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DIRECT_MASTER_PUSH' -Message 'push to protected branch master is blocked; use a feature branch + PR')
    }
    if (($positionals.Count -le 1) -and $implicitRisky) {
      return (New-GitGuardResult -Allowed $false -ReasonCode 'DIRECT_MASTER_PUSH' -Message 'push with implicit target while on master/unknown branch is blocked fail-closed')
    }
    return (New-GitGuardResult -Allowed $true -ReasonCode 'OK_FEATURE_BRANCH' -Message 'push does not touch protected branch master')
  }
  $readOnly = @('checkout', 'pull', 'fetch', 'log', 'status', 'diff', 'show', 'rev-parse', 'clone')
  if ($readOnly -ccontains $sub) {
    return (New-GitGuardResult -Allowed $true -ReasonCode 'OK_READONLY' -Message ('read-only git {0} is allowed' -f $sub))
  }
  return (New-GitGuardResult -Allowed $true -ReasonCode 'OK_FEATURE_BRANCH' -Message ('git {0} does not match any protected pattern' -f $sub))
}

function Get-GitGovernanceReviewClassification {
  <#
  .SYNOPSIS
      Distinguishes a real approval from a fallback acceptance.
  .DESCRIPTION
      REVIEW_APPROVED requires an explicit approval bound to the SHA plus
      green CI and resolved threads. ReviewAvailable alone never approves;
      it only signals a reviewer is in the loop. A missing/unrecorded
      approval, failing CI, or unresolved threads is REVIEW_FALLBACK, never
      REVIEW_APPROVED, so fallback acceptance cannot be mistaken for an
      approval in closure/audit records.
  #>
  [CmdletBinding()]
  param(
    [bool]$ReviewAvailable,
    [bool]$CiPass,
    [bool]$ThreadsResolved,
    [bool]$ReviewApproved = $false
  )
  if ($ReviewApproved -and $CiPass -and $ThreadsResolved) { return 'REVIEW_APPROVED' }
  return 'REVIEW_FALLBACK'
}

# CLI entrypoint. Runs only when -CommandLine is supplied, so dot-sourcing
# this file as a library defines the functions and does nothing else.
if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
  $cliBranch = ''
  if (-not [string]::IsNullOrWhiteSpace($CurrentBranch)) { $cliBranch = $CurrentBranch.Trim() }
  if ([string]::IsNullOrWhiteSpace($cliBranch)) {
    try {
      $detected = (& git branch --show-current 2>$null | Select-Object -First 1)
      if (-not [string]::IsNullOrWhiteSpace($detected)) { $cliBranch = ([string]$detected).Trim() }
    }
    catch { }
  }
  try {
    $cliResult = Test-GitOperationAllowed -CommandLine $CommandLine -CurrentBranch $cliBranch
  }
  catch {
    Write-Host ("DENY UNKNOWN_ERROR :: {0}" -f $_.Exception.Message)
    exit 1
  }
  if ($cliResult.Allowed) {
    Write-Host ("ALLOW {0} :: {1}" -f $cliResult.ReasonCode, $cliResult.Message)
    exit 0
  }
  else {
    Write-Host ("DENY {0} :: {1}" -f $cliResult.ReasonCode, $cliResult.Message)
    exit 1
  }
}
