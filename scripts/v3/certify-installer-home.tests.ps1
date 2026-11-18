$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'certify-installer-home.ps1'
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$base = Join-Path $temp ('oo-f2-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
try {
  $fake = Join-Path $base 'fake.ps1'
  $fakeUninstall = Join-Path $base 'fake-uninstall.ps1'
  $fakeText = @'
param([string]$TargetHome,[string]$Runtime,[switch]$Clean)
$ErrorActionPreference='Stop'
$d=Join-Path $TargetHome '.opencode-orchestration'
New-Item -ItemType Directory -Force $d | Out-Null
$p=Join-Path $d 'manifest.json'
$o=[ordered]@{managed_files=@(@{relative='agents/coder.md';sha256='synthetic'})}
[IO.File]::WriteAllText($p,($o|ConvertTo-Json -Depth 3))
$agents=Join-Path $TargetHome '.config\opencode\agents'
New-Item -ItemType Directory -Force $agents | Out-Null
$ruleA="  - action: shell`n    resource: git reset *--hard*`n    effect: deny"
$ruleB="  - action: shell`n    resource: git reset --hard*`n    effect: deny"
if ($TargetHome -match 'home-reinstall') {
  if ($env:F2_TEST_DIFFERENT_TUPLE -eq '1') { $ruleB=$ruleB.Replace('git reset --hard*','different command') }
  $permissions="$ruleB`n$ruleA"
} else { $permissions="$ruleA`n$ruleB" }
$coder="---`nname: coder`npermissions:`n$permissions`n---`nbody`n"
[IO.File]::WriteAllText((Join-Path $agents 'coder.md'),$coder)
'@
  [IO.File]::WriteAllText($fake,$fakeText)
  [IO.File]::WriteAllText($fakeUninstall,"param([string]`$TargetHome)`nRemove-Item -LiteralPath (Join-Path `$TargetHome '.opencode-orchestration') -Recurse -Force")
  & $scriptPath -TempBase $base -InstallerPath $fake -UninstallerPath $fakeUninstall -SkipActiveHashGuard
  $runDir = Get-ChildItem $base -Directory -Filter 'oo-f2-*' | Sort-Object Name -Descending | Select-Object -First 1
  $out = Join-Path $runDir.FullName 'artifacts\certification.json'
  if ($LASTEXITCODE -ne 0) { throw 'two-cycle/idempotency fixture failed' }
  $result = Get-Content $out -Raw | ConvertFrom-Json
  if (-not $result.stages.idempotency.passed) { throw 'idempotency mismatch not handled' }
  if (-not $result.stages.fresh_home_comparison.equal) { throw 'fresh-home hashes differ' }
  if (-not $result.stages.fresh_home_comparison.permission_order_differs -or -not $result.stages.fresh_home_comparison.order_is_semantically_relevant) { throw 'permission-order residual was not captured' }
  $guard = Join-Path $PSScriptRoot 'assert-active-paths-unchanged.ps1'
  $watched = Join-Path $base 'watched.txt'
  [IO.File]::WriteAllText($watched,'before')
  $baseline = Join-Path $base 'baseline.json'
  & $guard -Mode Capture -Output $baseline -Paths @($watched) -ProtectedRootsOverride @($env:USERPROFILE)
  [IO.File]::WriteAllText($watched,'after')
  & $guard -Mode Verify -BaselinePath $baseline -Paths @($watched) -ProtectedRootsOverride @($env:USERPROFILE)
  if ($LASTEXITCODE -eq 0) { throw 'active-path mutation was not detected' }
  $outside = 'C:\oo-f2-nope'
  $caught = ''
  try { & $scriptPath -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -TempBase $outside -InstallerPath $fake -Output (Join-Path $base 'must-not-write.json') -SkipActiveHashGuard }
  catch { $caught = $_.Exception.Message }
  if ($caught -notmatch 'F2_TEMPBASE_OUTSIDE_TEMP') { throw "real outside-TEMP rejection not exercised: $caught" }
  $outputCaught = ''
  try {
    $runFake = Join-Path $base 'oo-f2-for-output'
    New-Item -ItemType Directory -Path $runFake | Out-Null
    & $scriptPath -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -TempBase $base -InstallerPath $fake -Output (Join-Path $runFake 'outside-output.json') -SkipActiveHashGuard
  }
  catch { $outputCaught = $_.Exception.Message }
  if ($outputCaught -notmatch 'F2_OUTPUT_OUTSIDE_RUN') { throw "output outside run was not rejected: $outputCaught" }
  $env:F2_TEST_DIFFERENT_TUPLE='1'
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $diffOutput = & powershell.exe -NoProfile -File $scriptPath -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -TempBase $base -InstallerPath $fake -UninstallerPath $fakeUninstall -SkipActiveHashGuard 2>&1
  $diffExit = $LASTEXITCODE
  $ErrorActionPreference = $savedPreference
  Remove-Item Env:F2_TEST_DIFFERENT_TUPLE -ErrorAction SilentlyContinue
  if (($diffExit -eq 0) -or (($diffOutput -join "`n") -notmatch 'F2_UNEXPLAINED_CONTENT_DIFFERENCE')) { throw 'different permission tuple did not fail with the expected token' }
  Write-Output 'PASS: two-cycle, hash comparison, idempotency, outside-TEMP rejection'
} finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }

