# Exp A: debug config com servico JA STARTADO explicitamente (discriminador H1)
# Home isolado; porta privada; nunca toca 49374; stop OWNED no fim.
$ErrorActionPreference = 'Continue'
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$th = Join-Path $env:TEMP 'oo-v2lane-expa'
Remove-Item $th -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $th -Force | Out-Null
$env:XDG_CONFIG_HOME = $th
$env:XDG_DATA_HOME = Join-Path $th 'data'
$env:XDG_STATE_HOME = Join-Path $th 'state'
$env:XDG_CACHE_HOME = Join-Path $th 'cache'
$port = 59821
$r = [ordered]@{ record = 'v2-lane-expa-debugcfg-after-explicit-start'; date = (Get-Date).ToString('o'); port = $port; home = $th }

# porta livre?
$pre = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.port_free_at_start = ($null -eq $pre)
if (-not $r.port_free_at_start) { $r.aborted = 'port not free'; $r | ConvertTo-Json -Depth 4 | Set-Content 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03\debugcfg-exp-a.json' -Encoding UTF8; exit 2 }

$o1 = & $bin service set port $port 2>&1
$r.set_rc = $LASTEXITCODE
$o2 = & $bin service start 2>&1
$r.start_rc = $LASTEXITCODE
$r.start_out = (@($o2) | Select-Object -First 2) -join ' | '
Start-Sleep -Seconds 2
$l1 = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.listener_after_start = if ($l1) { "PID=$($l1.OwningProcess)" } else { 'NONE' }

# debug config com budget 60s (filho proprio; kill own-child em timeout padrao SpikeProcess)
$dcOut = Join-Path $th 'dc-out.txt'; $dcErr = Join-Path $th 'dc-err.txt'
$p = Start-Process -FilePath $bin -ArgumentList @('debug','config') -WorkingDirectory $th -RedirectStandardOutput $dcOut -RedirectStandardError $dcErr -PassThru -WindowStyle Hidden -NoNewWindow
$done = $p.WaitForExit(60000)
$r.debugconfig_exited = $done
if ($done) { $r.debugconfig_rc = $p.ExitCode } else { try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }; $r.debugconfig_rc = 'TIMEOUT_60S_own_child_killed' }
$r.debugconfig_out_head = if (Test-Path $dcOut) { ((Get-Content $dcOut -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ').Substring(0, [Math]::Min(300, (Get-Item $dcOut).Length)) } else { '' }
$r.debugconfig_err_head = if (Test-Path $dcErr) { ((Get-Content $dcErr -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ').Substring(0, [Math]::Min(300, (Get-Item $dcErr).Length)) } else { '' }

$o3 = & $bin service status 2>&1
$r.status_rc = $LASTEXITCODE
$r.status_out = (@($o3) | Select-Object -First 2) -join ' | '
$o4 = & $bin service stop 2>&1
$r.stop_rc = $LASTEXITCODE
Start-Sleep -Seconds 2
$l2 = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.settlement = if ($l2) { "STILL pid=$($l2.OwningProcess)" } else { 'GONE' }
$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$r | ConvertTo-Json -Depth 4 | Set-Content 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03\debugcfg-exp-a.json' -Encoding UTF8
Write-Host 'EXPA_DONE'
