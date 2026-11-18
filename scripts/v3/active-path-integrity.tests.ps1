$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot 'assert-active-paths-unchanged.ps1'
$base = Join-Path ([IO.Path]::GetTempPath()) ('active-integrity-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  $fixture = Join-Path $base 'fixture.txt'
  $missing = Join-Path $base 'missing.txt'
  $baseline = Join-Path $base 'baseline.json'
  $protectedRoot = Join-Path $base 'synthetic-profile'
  New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
  [IO.File]::WriteAllText($fixture, 'original')
  & powershell -NoProfile -File $tool -Mode Capture -Output $baseline -Paths @($fixture,$missing) -ProtectedRootsOverride $protectedRoot
  if ($LASTEXITCODE -ne 0) { throw 'capture failed' }
  & powershell -NoProfile -File $tool -Mode Verify -Input $baseline -ProtectedRootsOverride $protectedRoot
  if ($LASTEXITCODE -ne 0) { throw 'unchanged verify failed' }
  [IO.File]::WriteAllText($fixture, 'changed')
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Verify -Input $baseline -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_CHANGED')) { throw 'modified fixture was not detected' }
  Remove-Item -LiteralPath $fixture
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Verify -Input $baseline -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_CHANGED')) { throw 'removed fixture was not detected' }
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Capture -Output (Join-Path $base 'dir-baseline.json') -Paths $base -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_DIRECTORY_REJECTED')) { throw 'directory input was not rejected' }
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Capture -Output $baseline -Paths $baseline -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_OUTPUT_COLLISION')) { throw 'output collision was not rejected' }
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Capture -Output (Join-Path $protectedRoot 'output.json') -Paths $fixture -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_OUTPUT_IN_PROFILE')) { throw 'protected output was not rejected' }
  $tempOutput = Join-Path $base 'temp-output.json'
  & powershell -NoProfile -File $tool -Mode Capture -Output $tempOutput -Paths @($fixture) -ProtectedRootsOverride $protectedRoot
  if ($LASTEXITCODE -ne 0) { throw 'TEMP output was not permitted' }
  $profile = [Environment]::GetFolderPath('UserProfile')
  if ([string]::IsNullOrWhiteSpace($profile)) { throw 'user profile unavailable for config-path test' }
  $configOutput = Join-Path $profile '.config\opencode\f2-output.json'
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Capture -Output $configOutput -Paths @($fixture) 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_OUTPUT_IN_PROFILE')) { throw 'active config output was not rejected with compatibility token' }
  $ErrorActionPreference = 'Continue'
  $out = & powershell -NoProfile -File $tool -Mode Capture -Output (Join-Path $base 'invalid.json') -Paths ' ' -ProtectedRootsOverride $protectedRoot 2>&1
  $ErrorActionPreference = $savedPreference
  if (($LASTEXITCODE -eq 0) -or (($out -join "`n") -notmatch 'ACTIVE_PATH_INVALID')) { throw 'empty input path was not rejected honestly' }
  Write-Host 'active-path-integrity: PASS (9 checks)'
} finally { Remove-Item -LiteralPath $base -Recurse -Force }
