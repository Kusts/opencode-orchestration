$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out=Join-Path ([IO.Path]::GetTempPath()) ('efficiency-test-'+[guid]::NewGuid().ToString('N')+'.json')
$savedOptIn=[Environment]::GetEnvironmentVariable('F3_PERMISSION_RUN_OPT_IN','Process')
try {
  $env:F3_PERMISSION_RUN_OPT_IN='1'
  & (Join-Path $PSScriptRoot 'measure-efficiency-baseline.ps1') -RepoRoot $root -Output $out | Out-Null
  $data=Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
  if (@($data.scenarios).Count -lt 3) { throw 'expected at least three scenarios' }
  foreach ($s in $data.scenarios) { foreach ($key in 'planner_calls','subagents','retries','tokens','cost') { if ($s.$key -ne 'not_measured') { throw "missing not_measured: $key" } } }
  $failed=@($data.scenarios|Where-Object name -eq 'fail-closed')
  if ($failed.Count -ne 1 -or $failed[0].exit_code -eq 0 -or -not $failed[0].fail_closed_expected -or -not $failed[0].fail_closed_marker_observed -or $failed[0].status -ne 'PASS') { throw 'fail-closed child inherited opt-in or failed to emit the required gate token' }
  $json=Get-Content -Raw -LiteralPath $out
  if ($json -match '(?i)(sk-[A-Za-z0-9]{12,}|password\s*[:=]\s*(?!\[REDACTED\])\S+)') { throw 'possible secret in JSON' }
  & $env:ComSpec /d /c "git -C `"$root`" diff --check >nul 2>nul"
  if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }
  Write-Host 'measure-efficiency-baseline: PASS=4 FAIL=0 (3 cenários + segurança do opt-in herdado)'
} finally {
  if ($null -eq $savedOptIn) { Remove-Item Env:F3_PERMISSION_RUN_OPT_IN -ErrorAction SilentlyContinue } else { $env:F3_PERMISSION_RUN_OPT_IN=$savedOptIn }
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
}
