# Lane V2 2026-10-03 - parte 2: status -> stop owned -> settlement (padrao P22)
# Rodar detached; auto-contido; nunca mata PID (stop via CLI do servico).
$ErrorActionPreference = 'Continue'
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$th = Join-Path $env:TEMP 'oo-v2lane-native'
$env:XDG_CONFIG_HOME = $th
$env:XDG_DATA_HOME = Join-Path $th 'data'
$env:XDG_STATE_HOME = Join-Path $th 'state'
$env:XDG_CACHE_HOME = Join-Path $th 'cache'
$port = 59820
$r = [ordered]@{ record = 'v2-lane-native-lifecycle-part2'; date = (Get-Date).ToString('o'); port = $port }
$pre = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.pre_listener_pid = if ($pre) { $pre.OwningProcess } else { $null }
$o = & $bin service status 2>&1
$r.status_rc = $LASTEXITCODE
$r.status_out = (@($o) | Select-Object -First 6) -join ' | '
$o2 = & $bin service stop 2>&1
$r.stop_rc = $LASTEXITCODE
$r.stop_out = (@($o2) | Select-Object -First 4) -join ' | '
Start-Sleep -Seconds 2
$post = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.post_listener = if ($post) { "STILL_LISTENING pid=$($post.OwningProcess)" } else { 'GONE' }
$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.port49374_owner_after = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$out = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03\native-lifecycle-part2.json'
$r | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host "PART2_DONE -> $out"
