$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime\lib\OrchestrationTargetGuard.ps1')
$base = Join-Path ([IO.Path]::GetTempPath()) ('target-guard-' + [guid]::NewGuid().ToString('N'))
$saved = @{ USERPROFILE=$env:USERPROFILE; HOME=$env:HOME; TEMP=$env:TEMP; TMP=$env:TMP }
$passed = 0
$failed = 0
function Assert-Guard([scriptblock]$Action, [bool]$ShouldReject, [string]$Name, [string]$Token='MUTATING_TARGET_REQUIRES_EXPLICIT_PATH') {
  $rejected = $false
  try { & $Action } catch { $rejected = $_.Exception.Message.Contains($Token) }
  if ($rejected -eq $ShouldReject) { Write-Host ('PASS ' + $Name); $script:passed++ }
  else { Write-Host ('FAIL ' + $Name); $script:failed++ }
}
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  $env:USERPROFILE = Join-Path $base 'synthetic-profile'
  New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
  $override = @($env:USERPROFILE)
  $profileChild = Join-Path $env:USERPROFILE 'child'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed $profileChild $false $false -IsNonInteractive:$true -ProtectedRootsOverride $override } $true 'noninteractive implicit profile denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed $profileChild $false $false -IsNonInteractive:$false -ProtectedRootsOverride $override } $true 'interactive implicit profile denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed $profileChild $true $false -IsNonInteractive:$false -ProtectedRootsOverride $override } $true 'explicit profile without opt-in denied interactively'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed $profileChild $true $true -IsNonInteractive:$true -ProtectedRootsOverride $override } $false 'profile opt-in allowed'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed ($env:USERPROFILE + '\') $false $false -IsNonInteractive:$true -ProtectedRootsOverride $override } $true 'trailing separator profile denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed ('\\?\' + $profileChild) $false $false -IsNonInteractive:$true -ProtectedRootsOverride $override } $true 'device prefix profile denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed '\\?\Volume{1234}\target' $false $false -ProtectedRootsOverride $override } $true 'unsupported device namespace denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed '\\server\share\home' $false $false -ProtectedRootsOverride $override } $true 'UNC denied'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $base 'home') $false $false -ProtectedRootsOverride $override } $false 'temp allowed when not profile-sensitive subtree'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed ($env:USERPROFILE + '-temp') $false $false -ProtectedRootsOverride $override } $false 'similar prefix outside profile allowed'
  $env:TEMP = $env:USERPROFILE
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $env:USERPROFILE '.config\opencode') $true $false -ProtectedRootsOverride $override } $true 'TEMP profile does not release opencode config'
  $env:USERPROFILE = ''
  $env:HOME = Join-Path $base 'home-source'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $env:HOME 'child') $false $false } $true 'HOME protects target when USERPROFILE empty'
  $env:USERPROFILE = Join-Path $base 'divergent-profile'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $base 'injected-profile\child') $false $false -ProtectedRootsOverride @((Join-Path $base 'injected-profile')) } $true 'override protects divergent root'
  Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $base 'unknown-target') $false $false -ProtectedRootsOverride @() } $true 'unknown roots fail closed' 'MUTATING_TARGET_PROFILE_ROOT_UNKNOWN'
  $linkTarget = $env:USERPROFILE
  New-Item -ItemType Directory -Path $linkTarget -Force | Out-Null
  $link = Join-Path $base 'profile-link'
  try {
    New-Item -ItemType SymbolicLink -Path $link -Target $linkTarget -ErrorAction Stop | Out-Null
    Assert-Guard { Assert-OrchestrationMutatingTargetAllowed (Join-Path $link 'child') $false $false -ProtectedRootsOverride @($linkTarget) } $true 'link fails closed' 'MUTATING_TARGET_REPARSE_UNVERIFIED'
  } catch { Write-Host ('SKIP symlink case: ' + $_.Exception.Message) }
  if ($failed -gt 0) { throw ("guard assertions failed: $failed") }
  Write-Host ("target-guard: PASS={0} FAIL={1}" -f $passed, $failed)
} finally {
  foreach ($name in @('USERPROFILE','HOME','TEMP','TMP')) { [Environment]::SetEnvironmentVariable($name, [string]$saved[$name], 'Process') }
  Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}
