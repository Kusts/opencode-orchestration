# Exp E: captura de sockets do debug config DURANTE o hang (H-A': cliente dispara 49374?)
$ErrorActionPreference = 'Continue'
$repo = (Get-Location).Path
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$dir = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03'
$out = "$dir\debugcfg-exp-e.json"

function Save2($obj, [string]$path) { $obj | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8 }
function Get-Headless([string]$f) {
  if (-not (Test-Path $f)) { return '(arquivo ausente)' }
  $raw = Get-Content $f -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return '(vazio)' }
  $flat = ($raw -replace '\s+', ' ').Trim()
  if ($flat.Length -eq 0) { return '(vazio)' }
  return $flat.Substring(0, [Math]::Min(300, $flat.Length))
}

$th = Join-Path $env:TEMP 'oo-v2lane-expe'
Remove-Item $th -Recurse -Force -ErrorAction SilentlyContinue
foreach ($dd in @('xdg','xdg-data','xdg-state','xdg-cache','home','cwd')) { New-Item -ItemType Directory (Join-Path $th $dd) -Force | Out-Null }

# config fixture: copia a D1 (19 workers) ja gerada pela exp D2 (home a)
$srcCfg = Join-Path $env:TEMP 'oo-v2lane-expd2-a\xdg\opencode\opencode.json'
$dstCfgDir = Join-Path $th 'xdg\opencode'
New-Item -ItemType Directory $dstCfgDir -Force | Out-Null
Copy-Item $srcCfg (Join-Path $dstCfgDir 'opencode.json') -Force

# aplica env isolado no processo pai antes do Start-Process (herdada pelo filho)
foreach ($pair in @{ XDG_CONFIG_HOME = (Join-Path $th 'xdg'); XDG_DATA_HOME = (Join-Path $th 'xdg-data'); XDG_STATE_HOME = (Join-Path $th 'xdg-state'); XDG_CACHE_HOME = (Join-Path $th 'xdg-cache'); HOME = (Join-Path $th 'home'); USERPROFILE = (Join-Path $th 'home') }.GetEnumerator()) {
  Set-Item -Path "env:$($pair.Key)" -Value $pair.Value
}
foreach ($k in @('OPENCODE_CONFIG','OPENCODE_CONFIG_DIR','OPENCODE_CONFIG_FILE','OPENCODE_CONFIG_CONTENT')) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }

$r = [ordered]@{ record = 'v2-lane-expe-socket-capture'; date = (Get-Date).ToString('o'); config_fixture = '19 workers (copia D1)'; port_expected = 59833 }
$null = & $bin service set port 59833 2>&1
$r.set_rc = $LASTEXITCODE
Save2 $r $out

$p = Start-Process -FilePath $bin -ArgumentList @('debug','config') -WorkingDirectory (Join-Path $th 'cwd') -RedirectStandardOutput (Join-Path $th 'dc-out.txt') -RedirectStandardError (Join-Path $th 'dc-err.txt') -PassThru -NoNewWindow
$r.child_pid = $p.Id

$samples = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 1000
  if ($p.HasExited) { $r.child_exited_at_ms = ($i+1)*1000; break }
  $conns = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $p.Id })
  foreach ($c in $conns) {
    [void]$samples.Add([ordered]@{ t_ms = ($i+1)*1000; kind = 'socket'; state = [string]$c.State; local = "$($c.LocalAddress):$($c.LocalPort)"; remote = "$($c.RemoteAddress):$($c.RemotePort)" })
  }
  $opCount = @(Get-Process opencode -ErrorAction SilentlyContinue).Count
  [void]$samples.Add([ordered]@{ t_ms = ($i+1)*1000; kind = 'procs'; opencode_proc_count = $opCount })
}
$r.child_exited_during_capture = $p.HasExited
if (-not $p.HasExited) { try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { } }

$r.socket_samples = @($samples | Where-Object { $_.kind -eq 'socket' })
$r.proc_count_timeline = @($samples | Where-Object { $_.kind -eq 'procs' } | ForEach-Object { "$($_.t_ms):$($_.opencode_proc_count)" })
$r.any_conn_49374 = @($r.socket_samples | Where-Object { ("$($_.remote)" -match ':49374') -or ("$($_.local)" -match ':49374') }).Count
$r.any_conn_59833 = @($r.socket_samples | Where-Object { ("$($_.remote)" -match ':59833') -or ("$($_.local)" -match ':59833') }).Count
$r.socket_summary = @($r.socket_samples | ForEach-Object { "$($_.t_ms)ms $($_.state) $($_.local)->$($_.remote)" })
$r.dc_out_head = Get-Headless (Join-Path $th 'dc-out.txt')
$r.dc_err_head = Get-Headless (Join-Path $th 'dc-err.txt')

$null = & $bin service stop 2>&1
$r.stop_rc = $LASTEXITCODE
$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$r.finished_at = (Get-Date).ToString('o')
Save2 $r $out
Write-Host 'EXPE_DONE'
