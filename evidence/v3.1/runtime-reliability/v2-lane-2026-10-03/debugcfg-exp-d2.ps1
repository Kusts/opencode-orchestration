# Exp D v2: bisect com portas frescas + stderr capturado + settle
$ErrorActionPreference = 'Continue'
$repo = (Get-Location).Path
. (Join-Path $repo 'scripts\runtime\lib\AgentTranslator.ps1')
. (Join-Path $repo 'scripts\runtime\lib\SpikeProcess.ps1')
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$dir = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03'
$out = "$dir\debugcfg-exp-d2.json"

function Get-Head([string]$s, [int]$n = 300) {
  $flat = ($s -replace '\s+', ' ').Trim()
  if ($flat.Length -eq 0) { return '' }
  return $flat.Substring(0, [Math]::Min($n, $flat.Length))
}
function Save($obj, [string]$path) { $obj | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8 }

function New-ExpConfig([string]$ConfigPath, [string]$AgentsDir, [string[]]$Skip) {
  $files = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name | Where-Object { $Skip -notcontains [IO.Path]::GetFileNameWithoutExtension($_.Name) })
  $agents = [ordered]@{}
  $stems = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    [void]$stems.Add($stem)
    $parsed = Read-AgentFileCanonical -Path $f.FullName
    $c = $parsed.Canonical
    $rules = New-Object System.Collections.ArrayList
    if ([bool]$c.EditPresent) { [void]$rules.Add([ordered]@{ action = 'edit'; resource = '*'; effect = [string]$c.Edit }) }
    foreach ($r in @(Get-OrderedV2ShellRules -Canonical $c)) { [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect }) }
    foreach ($r in @(Get-OrderedV2TaskRules -Canonical $c)) { [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect }) }
    $agents[$stem] = [ordered]@{ mode = [string]$c.Mode; permissions = @($rules) }
  }
  $buildRules = New-Object System.Collections.ArrayList
  [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' })
  foreach ($s in ($stems | Sort-Object)) { [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = [string]$s; effect = 'allow' }) }
  $orderedAgents = [ordered]@{ build = [ordered]@{ mode = 'primary'; permissions = @($buildRules) } }
  foreach ($s in ($stems | Sort-Object)) { $orderedAgents[[string]$s] = $agents[[string]$s] }
  $cfg = [ordered]@{ default_agent = 'build'; agents = $orderedAgents; experimental = [ordered]@{ subagent_depth = 1 } }
  $parent = Split-Path -Parent $ConfigPath
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($ConfigPath, ((($cfg | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  return @($stems)
}

function Test-DebugConfig([string]$home2, [int]$budgetMs) {
  $env2 = @{
    XDG_CONFIG_HOME = (Join-Path $home2 'xdg'); XDG_DATA_HOME = (Join-Path $home2 'xdg-data')
    XDG_STATE_HOME = (Join-Path $home2 'xdg-state'); XDG_CACHE_HOME = (Join-Path $home2 'xdg-cache')
    HOME = (Join-Path $home2 'home'); USERPROFILE = (Join-Path $home2 'home')
  }
  $rem = @('OPENCODE_CONFIG','OPENCODE_CONFIG_DIR','OPENCODE_CONFIG_FILE','OPENCODE_CONFIG_CONTENT')
  try {
    $p = Invoke-SpikeChild -FilePath $bin -ArgumentList @('debug','config') -EnvSet $env2 -EnvRemove $rem -WorkingDirectory (Join-Path $home2 'cwd') -TimeoutMs $budgetMs
    return [ordered]@{ timedout = [bool]$p.TimedOut; rc = $p.ExitCode; out_head = Get-Head ([string]$p.Stdout); err_head = Get-Head ([string]$p.Stderr); stdout_len = ([string]$p.Stdout).Length; stderr_len = ([string]$p.Stderr).Length }
  } catch {
    return [ordered]@{ threw = $true; error = (Get-Head "$_" 300) }
  }
}

$agentsDir = Join-Path $repo 'source\agents'
$r = [ordered]@{ record = 'v2-lane-expd2-config-bisect-clean'; date = (Get-Date).ToString('o') }
Save $r $out

# D1: 19 workers, porta 59831, home fresco
$ha = Join-Path $env:TEMP 'oo-v2lane-expd2-a'
Remove-Item $ha -Recurse -Force -ErrorAction SilentlyContinue
foreach ($dd in @('xdg','xdg-data','xdg-state','xdg-cache','home','cwd')) { New-Item -ItemType Directory (Join-Path $ha $dd) -Force | Out-Null }
$stemsA = New-ExpConfig (Join-Path $ha 'xdg\opencode\opencode.json') $agentsDir @()
$r.D1_full_19 = [ordered]@{ workers = $stemsA.Count; tester_incluido = ($stemsA -contains 'tester'); cfg_bytes = (Get-Item (Join-Path $ha 'xdg\opencode\opencode.json')).Length; service_port = 59831 }
Start-Sleep -Seconds 3
$r.D1_full_19.debug_config = Test-DebugConfig $ha 30000
Save $r $out

# D2: 18 workers (sem tester), porta 59832, home fresco
$hb = Join-Path $env:TEMP 'oo-v2lane-expd2-b'
Remove-Item $hb -Recurse -Force -ErrorAction SilentlyContinue
foreach ($dd in @('xdg','xdg-data','xdg-state','xdg-cache','home','cwd')) { New-Item -ItemType Directory (Join-Path $hb $dd) -Force | Out-Null }
$stemsB = New-ExpConfig (Join-Path $hb 'xdg\opencode\opencode.json') $agentsDir @('tester')
$r.D2_sem_tester = [ordered]@{ workers = $stemsB.Count; tester_incluido = ($stemsB -contains 'tester'); cfg_bytes = (Get-Item (Join-Path $hb 'xdg\opencode\opencode.json')).Length; service_port = 59832 }
Start-Sleep -Seconds 3
$r.D2_sem_tester.debug_config = Test-DebugConfig $hb 30000
Save $r $out

$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$d1 = $r.D1_full_19.debug_config; $d2 = $r.D2_sem_tester.debug_config
$d1ok = (-not $d1.threw) -and (-not [bool]$d1.timedout) -and ([int]$d1.rc -eq 0) -and ([int]$d1.stdout_len -gt 0)
$d2ok = (-not $d2.threw) -and (-not [bool]$d2.timedout) -and ([int]$d2.rc -eq 0) -and ([int]$d2.stdout_len -gt 0)
$r.d1_pass_real = $d1ok; $r.d2_pass_real = $d2ok
$r.verdict_hint = if ($d1ok -and $d2ok) { 'AMBOS_RC0_PASS' } elseif ((-not $d1ok) -and $d2ok) { 'D1_FALHA_D2_PASSA_aponta_para_tester_ou_tamanho' } elseif ($d1ok -and (-not $d2ok)) { 'D1_PASSA_D2_FALHA_inesperado' } else { 'NENHUM_PASSOU_RC0_ver_err_head' }
$r.finished_at = (Get-Date).ToString('o')
Save $r $out
Write-Host 'EXPD2_DONE'
