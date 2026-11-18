function Get-F3AskClassification {
  param($Evidence)
  if ($null -eq $Evidence -or [string]::IsNullOrWhiteSpace([string]$Evidence.source) -or [string]::IsNullOrWhiteSpace([string]$Evidence.decision_id)) {
    return [ordered]@{ status='HOLD'; signal='approval event source and decision identifier are required' }
  }
  return [ordered]@{ status='PASS'; signal=([string]$Evidence.source+':'+[string]$Evidence.decision_id) }
}
function Assert-F3ServiceInactive {
  param([int]$ExitCode,[string]$Text)
  if ($ExitCode -eq 0 -or $Text -notmatch '(?i)(not running|no service|service is stopped|not started)') { throw 'SERVICE_ISOLATION_UNPROVEN' }
}
function Assert-F3PasswordPresent {
  param([hashtable]$Environment)
  if (-not $Environment.ContainsKey('OPENCODE_PASSWORD') -or [string]::IsNullOrWhiteSpace([string]$Environment.OPENCODE_PASSWORD)) { throw 'F3_PASSWORD_MISSING_BEFORE_WARMUP' }
}
function Assert-F3SessionDirectory {
  param([string]$Directory,[string]$RunRoot)
  if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'SESSION_DIRECTORY_UNPROVEN' }
  $full=[IO.Path]::GetFullPath($Directory); $root=([IO.Path]::GetFullPath($RunRoot).TrimEnd('\')+'\')
  if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path (Join-Path $full '.git'))) { throw 'SESSION_DIRECTORY_UNPROVEN' }
}
function Assert-F3PostRun {
  param([int]$VerifyExit,[bool]$StopSucceeded,[int]$PostStatusExit,[string]$PostStatusText)
  if ($VerifyExit -ne 0) { throw 'ACTIVE_PATH_CHANGED' }
  if (-not $StopSucceeded -or $PostStatusExit -eq 0 -or $PostStatusText -notmatch '(?i)(not running|no service|service is stopped|not started)') { throw 'F3_POST_RUN_SERVICE_STATE_UNPROVEN' }
}
function Get-F3RunExitCode {
  param([int]$VerifyExit,[bool]$PostGateFailed)
  if ($VerifyExit -ne 0 -or $PostGateFailed) { return 1 }
  return 0
}
