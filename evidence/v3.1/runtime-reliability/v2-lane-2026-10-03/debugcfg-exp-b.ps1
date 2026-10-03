# Exp B: debug config SEM start explicito, com captura de timeline (H1/H2/H4)
# Pergunta: durante o timeout, aparece listener na porta privada? em 49374? quando?
$ErrorActionPreference = 'Continue'
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$th = Join-Path $env:TEMP 'oo-v2lane-expb'
Remove-Item $th -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $th -Force | Out-Null
$env:XDG_CONFIG_HOME = $th
$env:XDG_DATA_HOME = Join-Path $th 'data'
$env:XDG_STATE_HOME = Join-Path $th 'state'
$env:XDG_CACHE_HOME = Join-Path $th 'cache'
$port = 59822
$dir = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03'
$r = [ordered]@{ record = 'v2-lane-expb-debugcfg-implicit-timeline'; date = (Get-Date).ToString('o'); port = $port; home = $th }
$pre = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
$r.port_free_at_start = ($null -eq $pre)
if (-not $r.port_free_at_start) { $r.aborted = 'port not free'; $r | ConvertTo-Json -Depth 4 | Set-Content "$dir\debugcfg-exp-b.json" -Encoding UTF8; exit 2 }

$o1 = & $bin service set port $port 2>&1
$r.set_rc = $LASTEXITCODE

# timeline: 90 iteracoes x 2s = 180s
$tl = "$dir\debugcfg-exp-b-timeline.jsonl"
Remove-Item $tl -ErrorAction SilentlyContinue
$sw = [Diagnostics.Stopwatch]::StartNew()
$capScript = {
  param($port, $tl, $swMs)
  $sw = [Diagnostics.Stopwatch]::StartNew(); $sw.Start()
  while ($sw.Elapsed.TotalMilliseconds -lt 190000) {
    $t = [long]$sw.Elapsed.TotalMilliseconds
    $l = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    $d = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
    $oc = @(Get-Process opencode -ErrorAction SilentlyContinue).Count
    $line = @{ t_ms = $t; private_listener = if ($l) { $l.OwningProcess } else { 0 }; p49374 = if ($d) { $d.OwningProcess } else { 0 }; opencode_procs = $oc } | ConvertTo-Json -Compress
    Add-Content -Path $tl -Value $line -Encoding UTF8
    Start-Sleep -Milliseconds 2000
  }
}
$cap = Start-Job -ScriptBlock $capScript -ArgumentList $port, (Resolve-Path $dir).Path + '\debugcfg-exp-b-timeline.jsonl', 0

# debug config com budget 150s
$dcOut = Join-Path $th 'dc-out.txt'; $dcErr = Join-Path $th 'dc-err.txt'
$p = Start-Process -FilePath $bin -ArgumentList @('debug','config') -WorkingDirectory $th -RedirectStandardOutput $dcOut -RedirectStandardError $dcErr -PassThru -WindowStyle Hidden -NoNewWindow
$done = $p.WaitForExit(150000)
$r.debugconfig_exited = $done
$r.debugconfig_elapsed_ms = [long]$sw.Elapsed.TotalMilliseconds
if ($done) { $r.debugconfig_rc = $p.ExitCode } else { try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }; $r.debugconfig_rc = 'TIMEOUT_150S_own_child_killed' }
$r.debugconfig_out_head = if (Test-Path $dcOut) { $raw = Get-Content $dcOut -Raw -ErrorAction SilentlyContinue; if ($raw) { ($raw -replace '\s+', ' ').Substring(0, [Math]::Min(300, $raw.Length)) } else { '' } } else { '' }
$r.debugconfig_err_head = if (Test-Path $dcErr) { $raw = Get-Content $dcErr -Raw -ErrorAction SilentlyContinue; if ($raw) { ($raw -replace '\s+', ' ').Substring(0, [Math]::Min(300, $raw.Length)) } else { '' } } else { '' }

Stop-Job $cap -ErrorAction SilentlyContinue; Remove-Job $cap -Force -ErrorAction SilentlyContinue
# resumo da timeline
if (Test-Path $tl) {
  $lines = Get-Content $tl | ForEach-Object { $_ | ConvertFrom-Json }
  $priv = $lines | Where-Object { $_.private_listener -ne 0 }
  $r.timeline_samples = $lines.Count
  $r.first_private_listener = if ($priv) { "t=$($priv[0].t_ms)ms pid=$($priv[0].private_listener)" } else { 'NEVER' }
  $r.p49374_owners_seen = @($lines | ForEach-Object { $_.p49374 } | Sort-Object -Unique) -join ','
  $r.max_opencode_procs = ($lines | Measure-Object -Property opencode_procs -Maximum).Maximum
}
$o4 = & $bin service stop 2>&1
$r.stop_rc = $LASTEXITCODE
$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$r | ConvertTo-Json -Depth 4 | Set-Content "$dir\debugcfg-exp-b.json" -Encoding UTF8
Write-Host 'EXPB_DONE'
