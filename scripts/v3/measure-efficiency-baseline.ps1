[CmdletBinding()]
param([string]$RepoRoot='', [string]$Output='')
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if ([string]::IsNullOrWhiteSpace($Output)) { $Output=Join-Path ([IO.Path]::GetTempPath()) ('efficiency-baseline-'+[guid]::NewGuid().ToString('N')+'.json') }
$shell=(Get-Process -Id $PID).Path
$targetGuard=Join-Path $RepoRoot 'scripts\v3\target-guard.tests.ps1'
$certify=Join-Path $RepoRoot 'scripts\v3\certify-permissions-runtime.ps1'
$planOutput=Join-Path ([IO.Path]::GetTempPath()) ('efficiency-plan-'+[guid]::NewGuid().ToString('N')+'.json')
$scenarios=@(
  [ordered]@{name='trivial'; arguments=@('-NoProfile','-File',$targetGuard); expected='normal'},
  [ordered]@{name='medium'; arguments=@('-NoProfile','-File',$certify,'-Mode','Plan','-Output',$planOutput); expected='normal'},
  [ordered]@{name='fail-closed'; arguments=@('-NoProfile','-File',$certify,'-Mode','Run'); expected='F3_RUN_REQUIRES_'}
)
$rows=@()
foreach ($scenario in $scenarios) {
  $stdout=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.out')
  $stderr=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N')+'.err')
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $argumentLine=($scenario.arguments|ForEach-Object { '"'+([string]$_).Replace('"','\"')+'"' }) -join ' '
  $savedOptIn=[Environment]::GetEnvironmentVariable('F3_PERMISSION_RUN_OPT_IN','Process')
  try {
    if ($scenario.name -eq 'fail-closed') {
      Remove-Item Env:F3_PERMISSION_RUN_OPT_IN -ErrorAction SilentlyContinue
    }
    $process=Start-Process -FilePath $shell -ArgumentList $argumentLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  } finally {
    if ($scenario.name -eq 'fail-closed') {
      if ($null -eq $savedOptIn) { Remove-Item Env:F3_PERMISSION_RUN_OPT_IN -ErrorAction SilentlyContinue }
      else { $env:F3_PERMISSION_RUN_OPT_IN=$savedOptIn }
    }
  }
  $exit=[int]$process.ExitCode
  $sw.Stop()
  $joined=((Get-Content -Raw -LiteralPath $stdout -ErrorAction SilentlyContinue)+' '+(Get-Content -Raw -LiteralPath $stderr -ErrorAction SilentlyContinue))
  Remove-Item $stdout,$stderr -Force -ErrorAction SilentlyContinue
  $assertions=$null
  if ($joined -match 'PASS=(\d+)\s+FAIL=(\d+)') { $assertions=[int]$Matches[1]+[int]$Matches[2] }
  $cases=$null
  if ($scenario.name -eq 'medium' -and (Test-Path -LiteralPath $planOutput)) {
    try { $cases=@((Get-Content -Raw -LiteralPath $planOutput|ConvertFrom-Json).cases).Count } catch {}
    Remove-Item -LiteralPath $planOutput -Force -ErrorAction SilentlyContinue
  }
  $closed=if ($scenario.expected -eq 'normal') { $null } else { ($exit -ne 0 -and $joined.Contains('F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN=1')) }
  $status=if ($scenario.expected -eq 'normal') { if ($exit -eq 0) {'PASS'} else {'FAIL'} } elseif ($closed) {'PASS'} else {'FAIL'}
  $failureReason=if ($status -eq 'FAIL' -and $scenario.name -eq 'fail-closed') { 'Expected fail-closed token F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN=1 was absent or child exited successfully.' } elseif ($status -eq 'FAIL') { 'Scenario exited non-zero.' } else { $null }
  $displayArgs=@($scenario.arguments|Where-Object { $_ -ne '-NoProfile' })
  $rows+=,[ordered]@{
    name=$scenario.name; command=('powershell -NoProfile '+($displayArgs -join ' '))
    exit_code=$exit; duration_ms=[long]$sw.ElapsedMilliseconds; assertion_count=$assertions; case_count=$cases
    status=$status; failure_reason=$failureReason; fail_closed_expected=$closed
    fail_closed_marker_observed=[bool]($scenario.name -eq 'fail-closed' -and $joined.Contains('F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN=1'))
    planner_calls='not_measured'; subagents='not_measured'; retries='not_measured'; tokens='not_measured'; cost='not_measured'
  }
}
$branch=(& git -C $RepoRoot branch --show-current 2>$null | Select-Object -First 1)
$commit=(& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
$version='unknown'
try { . (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1'); $version=[string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Version } catch {}
$doc=[ordered]@{schema='operational-maturity-efficiency-baseline/v1'; generated_at=[DateTime]::UtcNow.ToString('o'); runtime=[ordered]@{powershell=$PSVersionTable.PSVersion.ToString(); opencode_v2=$version}; branch=[string]$branch; commit=[string]$commit; scenarios=@($rows); limitations=@('Planner/subagent/retry/token/cost telemetry is not provided by these tools.','Duration is local wall-clock measurement and is not a before/after comparison.','The fail-closed child is launched with F3_PERMISSION_RUN_OPT_IN removed from its inherited process environment.')}
$doc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8
Write-Output $Output
