# Exp C v3: stdin discriminator com instrumentacao a prova de falha
$ErrorActionPreference = 'Continue'
$repo = (Get-Location).Path
. (Join-Path $repo 'scripts\runtime\lib\SpikeProcess.ps1')
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$th = Join-Path $env:TEMP 'oo-v2lane-expc'
Remove-Item $th -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @('xdg','xdg-data','xdg-state','xdg-cache','home','cwd')) { New-Item -ItemType Directory (Join-Path $th $d) -Force | Out-Null }
$isoEnv = @{
  XDG_CONFIG_HOME = (Join-Path $th 'xdg'); XDG_DATA_HOME = (Join-Path $th 'xdg-data')
  XDG_STATE_HOME = (Join-Path $th 'xdg-state'); XDG_CACHE_HOME = (Join-Path $th 'xdg-cache')
  HOME = (Join-Path $th 'home'); USERPROFILE = (Join-Path $th 'home')
}
$isoRemove = @('OPENCODE_CONFIG','OPENCODE_CONFIG_DIR','OPENCODE_CONFIG_FILE','OPENCODE_CONFIG_CONTENT')
$cwdT = Join-Path $th 'cwd'
$port = 59825
$out = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03\debugcfg-exp-c.json'

function Get-Head([string]$s, [int]$n = 200) {
  $flat = ($s -replace '\s+', ' ').Trim()
  if ($flat.Length -eq 0) { return '' }
  return $flat.Substring(0, [Math]::Min($n, $flat.Length))
}
function Save($obj, [string]$path) { $obj | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8 }

$r = [ordered]@{ record = 'v2-lane-expc-stdin-discriminator-v3'; date = (Get-Date).ToString('o'); port = $port; home = $th }
Save $r $out

$set = Invoke-SpikeChild -FilePath $bin -ArgumentList @('service','set','port',"$port") -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 20000
$r.set = [ordered]@{ timedout = [bool]$set.TimedOut; rc = $set.ExitCode }
Save $r $out

$c0 = Invoke-SpikeChild -FilePath $bin -ArgumentList @('debug','config') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
$r.C0_no_stdinnul = [ordered]@{ timedout = [bool]$c0.TimedOut; rc = $c0.ExitCode }
try { $r.C0_no_stdinnul.out_head = Get-Head ([string]$c0.Stdout); $r.C0_no_stdinnul.stdout_len = ([string]$c0.Stdout).Length } catch { $r.C0_no_stdinnul.fmt_error = "$_" }
Save $r $out

$c1 = Invoke-SpikeChild -FilePath $bin -ArgumentList @('debug','config') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 45000 -StdinNul
$r.C1_stdinnul = [ordered]@{ timedout = [bool]$c1.TimedOut; rc = $c1.ExitCode }
try { $r.C1_stdinnul.out_head = Get-Head ([string]$c1.Stdout); $r.C1_stdinnul.err_head = Get-Head ([string]$c1.Stderr); $r.C1_stdinnul.stdout_len = ([string]$c1.Stdout).Length } catch { $r.C1_stdinnul.fmt_error = "$_" }
Save $r $out

$stop = Invoke-SpikeChild -FilePath $bin -ArgumentList @('service','stop') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 20000
$r.stop = [ordered]@{ timedout = [bool]$stop.TimedOut; rc = $stop.ExitCode }
$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$c0t = [bool]$r.C0_no_stdinnul.timedout; $c1t = [bool]$r.C1_stdinnul.timedout
$r.verdict_hint = if (-not $c0t -and -not $c1t) { 'AMBOS_PASSAM_stdin_nao_e_causa_hoje' } elseif ($c0t -and -not $c1t) { 'STDIN_CONFIRMADO_C0_trava_C1_passa' } elseif ($c0t -and $c1t) { 'AMBOS_TRAVAM_stdin_nao_explica' } else { 'C0_passa_C1_trava_inesperado' }
$r.finished_at = (Get-Date).ToString('o')
Save $r $out
Write-Host 'EXPC_V3_DONE'
