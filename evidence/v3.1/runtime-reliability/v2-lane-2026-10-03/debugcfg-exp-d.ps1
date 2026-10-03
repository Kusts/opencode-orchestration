# Exp D: bisect da config - 19 workers completos (D1) vs sem tester (D2)
# Hipotese H-G: nova shape de permissoes do tester (catch-all allow + denies, 2026-10-03)
# trava o loader de config do V2 2.0.18. Gravacao incremental.
$ErrorActionPreference = 'Continue'
$repo = (Get-Location).Path
. (Join-Path $repo 'scripts\runtime\lib\AgentTranslator.ps1')
. (Join-Path $repo 'scripts\runtime\lib\SpikeProcess.ps1')
$bin = "$env:USERPROFILE\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe"
$dir = 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-03'
$out = "$dir\debugcfg-exp-d.json"

function Get-Head([string]$s, [int]$n = 200) {
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
    return [ordered]@{ timedout = [bool]$p.TimedOut; rc = $p.ExitCode; out_head = Get-Head ([string]$p.Stdout) }
  } catch {
    return [ordered]@{ threw = $true; error = ("$_" -replace '\s+', ' ').Substring(0, [Math]::Min(300, ("$_".Length))) }
  }
}

$agentsDir = Join-Path $repo 'source\agents'
$r = [ordered]@{ record = 'v2-lane-expd-config-bisect'; date = (Get-Date).ToString('o') }
Save $r $out

# D1: config completa (19 workers)
$ha = Join-Path $env:TEMP 'oo-v2lane-expd-a'
Remove-Item $ha -Recurse -Force -ErrorAction SilentlyContinue
$stemsA = New-ExpConfig (Join-Path $ha 'xdg\opencode\opencode.json') $agentsDir @()
$r.D1_full_19 = [ordered]@{ workers = $stemsA.Count; tester_incluido = ($stemsA -contains 'tester'); cfg_bytes = (Get-Item (Join-Path $ha 'xdg\opencode\opencode.json')).Length }
Save $r $out
$r.D1_full_19.debug_config = Test-DebugConfig $ha 30000
Save $r $out
# cleanup servico de D1
$e1 = @{ XDG_CONFIG_HOME = (Join-Path $ha 'xdg'); XDG_DATA_HOME = (Join-Path $ha 'xdg-data'); XDG_STATE_HOME = (Join-Path $ha 'xdg-state'); XDG_CACHE_HOME = (Join-Path $ha 'xdg-cache'); HOME = (Join-Path $ha 'home'); USERPROFILE = (Join-Path $ha 'home') }
$rm1 = @('OPENCODE_CONFIG','OPENCODE_CONFIG_DIR','OPENCODE_CONFIG_FILE','OPENCODE_CONFIG_CONTENT')
Invoke-SpikeChild -FilePath $bin -ArgumentList @('service','stop') -EnvSet $e1 -EnvRemove $rm1 -WorkingDirectory (Join-Path $ha 'cwd') -TimeoutMs 15000 | Out-Null

# D2: config sem tester (18 workers)
$hb = Join-Path $env:TEMP 'oo-v2lane-expd-b'
Remove-Item $hb -Recurse -Force -ErrorAction SilentlyContinue
$stemsB = New-ExpConfig (Join-Path $hb 'xdg\opencode\opencode.json') $agentsDir @('tester')
$r.D2_sem_tester = [ordered]@{ workers = $stemsB.Count; tester_incluido = ($stemsB -contains 'tester'); cfg_bytes = (Get-Item (Join-Path $hb 'xdg\opencode\opencode.json')).Length }
Save $r $out
$r.D2_sem_tester.debug_config = Test-DebugConfig $hb 30000
Save $r $out
$e2 = @{ XDG_CONFIG_HOME = (Join-Path $hb 'xdg'); XDG_DATA_HOME = (Join-Path $hb 'xdg-data'); XDG_STATE_HOME = (Join-Path $hb 'xdg-state'); XDG_CACHE_HOME = (Join-Path $hb 'xdg-cache'); HOME = (Join-Path $hb 'home'); USERPROFILE = (Join-Path $hb 'home') }
Invoke-SpikeChild -FilePath $bin -ArgumentList @('service','stop') -EnvSet $e2 -EnvRemove $rm1 -WorkingDirectory (Join-Path $hb 'cwd') -TimeoutMs 15000 | Out-Null

$c49 = Get-NetTCPConnection -LocalPort 49374 -State Listen -ErrorAction SilentlyContinue
$r.intact_49374 = if ($c49) { $c49.OwningProcess } else { 'NONE' }
$d1t = [bool]$r.D1_full_19.debug_config.timedout; $d2t = [bool]$r.D2_sem_tester.debug_config.timedout
$r.verdict_hint = if ($d1t -and -not $d2t) { 'TESTER_CONFIRMADO_D1_trava_D2_passa' } elseif ($d1t -and $d2t) { 'NAO_E_O_TESTER_AMBOS_TRAVAM' } elseif (-not $d1t -and -not $d2t) { 'AMBOS_PASSAM_hang_nao_reproduziu' } else { 'D1_passa_D2_trava_inesperado' }
$r.finished_at = (Get-Date).ToString('o')
Save $r $out
Write-Host 'EXPD_DONE'
