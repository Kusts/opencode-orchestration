$ErrorActionPreference='Stop'
$repo=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$scriptPath=Join-Path $PSScriptRoot 'certify-permissions-runtime.ps1'
. (Join-Path $PSScriptRoot 'lib\PermissionRuntimeCertification.ps1')
$count=0; $failed=0
function Check($ok,$name) { $script:count++; if ($ok) { Write-Host "[PASS] $name" } else { Write-Host "[FAIL] $name"; $script:failed++ } }
$base=[IO.Path]::GetTempPath()
$out=Join-Path $base ('f3-plan-test-'+[guid]::NewGuid().ToString('N')+'.json')
$plan=$null
$runRoot=$null
try {
  & $scriptPath -RepoRoot $repo -TempBase $base -Mode Plan -Output $out
  $plan=Get-Content $out -Raw|ConvertFrom-Json
  $config=Get-Content $plan.fixture.path -Raw|ConvertFrom-Json
  $rules=@($config.agents.build.permissions)
  Check ($rules.Count -eq 3 -and $rules[0].resource -ceq ('echo '+$plan.fixture.tokens.allow) -and $rules[1].resource -ceq ('echo '+$plan.fixture.tokens.ask) -and $rules[2].resource -ceq ('git reset --hard '+$plan.fixture.tokens.deny)) 'permission rules use exact unique command resources'
  Check ([IO.Path]::GetFullPath($plan.fixture.path).StartsWith([IO.Path]::GetFullPath($base),[StringComparison]::OrdinalIgnoreCase)) 'Plan writes fixture only under TEMP'
  $rejected=$false
  try { & $scriptPath -RepoRoot $repo -TempBase $repo -Mode Plan -Output $out } catch { $rejected=($_.Exception.Message -match 'F3_TEMPBASE_OUTSIDE_TEMP') }
  Check $rejected 'TempBase outside TEMP rejected'
  $fake=Get-F3AskClassification $null
  $rawBool=Get-F3AskClassification $true
  $validEvidence=Get-F3AskClassification ([pscustomobject]@{source='event-stream';decision_id='decision-1'})
  Check ($fake.status -ceq 'HOLD' -and $rawBool.status -ceq 'HOLD' -and $validEvidence.status -ceq 'PASS') 'ask PASS requires event source and decision id'
  $serviceRejected=$false
  try { Assert-F3ServiceInactive -ExitCode 0 -Text 'server running at 127.0.0.1:49374' } catch { $serviceRejected=($_.Exception.Message -eq 'SERVICE_ISOLATION_UNPROVEN') }
  Check $serviceRejected 'active/unproven service status aborts before startup'
  $passwordRejected=$false
  try { Assert-F3PasswordPresent @{XDG_CONFIG_HOME='isolated'} } catch { $passwordRejected=($_.Exception.Message -eq 'F3_PASSWORD_MISSING_BEFORE_WARMUP') }
  Check $passwordRejected 'missing ephemeral password aborts before warmup'
  $verifyRejected=$false
  try { Assert-F3PostRun -VerifyExit 1 -StopSucceeded $true -PostStatusExit 1 -PostStatusText 'not running' } catch { $verifyRejected=($_.Exception.Message -eq 'ACTIVE_PATH_CHANGED') }
  Check ($verifyRejected -and (Get-F3RunExitCode -VerifyExit 1 -PostGateFailed $false) -eq 1) 'Verify divergence requires nonzero exit'
  $outside=Join-Path $base ('f3-outside-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $outside -Force|Out-Null
  $directoryRejected=$false
  try { Assert-F3SessionDirectory -Directory $outside -RunRoot $base } catch { $directoryRejected=($_.Exception.Message -eq 'SESSION_DIRECTORY_UNPROVEN') }
  Check $directoryRejected 'session directory must be git repo under runRoot'
  Remove-Item $outside -Recurse -Force
} finally {
  if (Test-Path $out) { Remove-Item $out -Force }
  if ($plan -and $plan.fixture -and $plan.fixture.path) {
    $fixtureDir=Split-Path $plan.fixture.path -Parent
    $runRoot=Split-Path (Split-Path $fixtureDir -Parent) -Parent
    if ($runRoot -and (Test-Path $runRoot) -and $runRoot.StartsWith([IO.Path]::GetFullPath($base),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item $runRoot -Recurse -Force }
  }
}
Write-Host "RESULT $($count-$failed)/$count"
if ($failed) { exit 1 }
