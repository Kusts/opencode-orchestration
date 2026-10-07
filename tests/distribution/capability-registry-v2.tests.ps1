<#!
.SYNOPSIS
    Suite do Capability Registry V2 (Fase 2A fatia 2): schema + honestidade + healthcheck.
.DESCRIPTION
    Valida source/registry/capabilities-v2.json (ids unicos, campos obrigatorios,
    refs validas, healthcheck presente quando exigido, sem claim installed para
    capabilities novas/opcionais) e executa scripts/v3/capability-healthcheck.ps1
    -Json (12+ resultados estruturados, sem vazamento de secrets).
    Estilo das suites distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
    Somente leitura; nao altera routing/flags; PS 5.1 compativel.
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else {
    $script:fail += 1
    $line = ("NOT OK - " + $Name)
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + " -- " + $Detail }
    Write-Host $line
  }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$regPath = Join-Path $RepoRoot 'source\registry\capabilities-v2.json'
$hcPath = Join-Path $RepoRoot 'scripts\v3\capability-healthcheck.ps1'

Assert (Test-Path -LiteralPath $regPath -PathType Leaf) 'registry capabilities-v2.json existe'
Assert (Test-Path -LiteralPath $hcPath -PathType Leaf) 'healthcheck capability-healthcheck.ps1 existe'

$reg = $null
try {
  $reg = ([IO.File]::ReadAllText($regPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $reg) 'registry parseia como JSON'
}
catch {
  Assert $false 'registry parseia como JSON' $_.Exception.Message
}

if ($null -ne $reg) {
  Assert (([string]$reg.schema_version) -ceq '1') 'registry schema_version == 1' ('obtido: ' + [string]$reg.schema_version)
  $caps = @($reg.capabilities)
  $expectedIds = @('planner', 'planning-advisors', 'core-agents', 'core-skills', 'orchestration-enforcement', 'ai-memory', 'context7', 'jev', 'skills-catalog', 'github-mcp', 'playwright-mcp', 'chrome-devtools-mcp', 'opencode-runtime', 'git', 'github-cli', 'playwright-cli', 'docker')
  Assert ($caps.Count -eq $expectedIds.Count) ('registry tem ' + $expectedIds.Count + ' capabilities') ('obtido: ' + $caps.Count)

  $ids = @($caps | ForEach-Object { [string]$_.id })
  $uniq = @($ids | Sort-Object -Unique)
  Assert (($ids.Count -gt 0) -and ($ids.Count -eq $uniq.Count)) 'ids unicos' ('total=' + $ids.Count + ' unicos=' + $uniq.Count)
  foreach ($e in $expectedIds) {
    Assert ($ids -contains $e) ('id presente: ' + $e)
  }

  $allowedStatus = @('DECLARED', 'INSTALLED', 'DISCOVERED', 'ACTIVE', 'CANDIDATE')
  $allowedRisk = @('low', 'medium', 'high', 'critical', 'unknown')
  $allowedModes = @('always', 'on-demand', 'advisory-only', 'candidate')
  $allowedProbes = @('repo-file', 'repo-dir', 'command', 'mcp-config', 'mcp-path')
  $refErrs = New-Object System.Collections.ArrayList
  foreach ($c in $caps) {
    $cid = [string]$c.id
    foreach ($f in @('id', 'description', 'type', 'managed_by', 'declared_by')) {
      if ([string]::IsNullOrWhiteSpace([string]$c.$f)) { [void]$refErrs.Add(($cid + ': campo vazio: ' + $f)) }
    }
    $rt = $null
    try { $rt = $c.runtime.v2 } catch { $rt = $null }
    if (($null -eq $rt) -or (-not ($rt -is [bool]))) { [void]$refErrs.Add(($cid + ': runtime.v2 ausente ou nao-bool')) }
    foreach ($s in @('desired', 'observed')) {
      $v = ''
      try { $v = [string]$c.status.$s } catch { $v = '' }
      if ($allowedStatus -notcontains $v) { [void]$refErrs.Add(($cid + ': status.' + $s + ' invalido: ' + $v)) }
    }
    $rl = ''
    try { $rl = [string]$c.risk.level } catch { $rl = '' }
    if ($allowedRisk -notcontains $rl) { [void]$refErrs.Add(($cid + ': risk.level invalido: ' + $rl)) }
    $am = ''
    try { $am = [string]$c.activation.mode } catch { $am = '' }
    if ($allowedModes -notcontains $am) { [void]$refErrs.Add(($cid + ': activation.mode invalido: ' + $am)) }
    $pb = ''
    try { $pb = [string]$c.healthcheck.probe } catch { $pb = '' }
    if ($allowedProbes -notcontains $pb) { [void]$refErrs.Add(($cid + ': healthcheck.probe invalido: ' + $pb)) }
    try {
      if ([string]::IsNullOrWhiteSpace([string]$c.healthcheck.command)) { [void]$refErrs.Add(($cid + ': healthcheck.command vazio')) }
    }
    catch { [void]$refErrs.Add(($cid + ': healthcheck.command ausente')) }
    $to = 0
    try { $to = [int]$c.healthcheck.timeout_seconds } catch { $to = 0 }
    if (($to -lt 1) -or ($to -gt 120)) { [void]$refErrs.Add(($cid + ': timeout_seconds fora de 1..120: ' + [string]$c.healthcheck.timeout_seconds)) }
    # Refs validas por tipo de probe.
    if ($pb -ceq 'repo-file') {
      $t = ''
      try { $t = [string]$c.healthcheck.target } catch { $t = '' }
      if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($t -replace '/', '\')) -PathType Leaf)) {
        [void]$refErrs.Add(($cid + ': repo-file inexistente: ' + $t))
      }
    }
    elseif ($pb -ceq 'repo-dir') {
      $t = ''
      try { $t = [string]$c.healthcheck.target } catch { $t = '' }
      $dir = Join-Path $RepoRoot ($t -replace '/', '\')
      if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void]$refErrs.Add(($cid + ': repo-dir inexistente: ' + $t))
      }
      else {
        try {
          foreach ($e2 in @($c.healthcheck.expect_files)) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir (([string]$e2) -replace '/', '\')))) {
              [void]$refErrs.Add(($cid + ': expect_files ausente: ' + [string]$e2))
            }
          }
        }
        catch { [void]$refErrs.Add(($cid + ': expect_files ilegivel')) }
      }
    }
  }
  Assert ($refErrs.Count -eq 0) 'schema + refs validas (runtime.v2, status, risk, activation, healthcheck)' ($refErrs -join ' | ')

  # Honestidade: opcionais/novos/pilotos nunca nascem installed/active.
  $honErrs = New-Object System.Collections.ArrayList
  foreach ($c in $caps) {
    $cid = [string]$c.id
    $obs = ''
    try { $obs = [string]$c.status.observed } catch { $obs = '' }
    if (((($cid -ceq 'playwright-cli') -or ($cid -ceq 'docker')) -and (($obs -ceq 'INSTALLED') -or ($obs -ceq 'ACTIVE'))) -or ((($cid -ceq 'github-mcp') -or ($cid -ceq 'playwright-mcp') -or ($cid -ceq 'chrome-devtools-mcp')) -and (($obs -ceq 'INSTALLED') -or ($obs -ceq 'ACTIVE')))) {
      [void]$honErrs.Add(($cid + ': opcional/piloto com observed INSTALLED/ACTIVE (proibido; usar DISCOVERED/DECLARED/CANDIDATE)'))
    }
  }
  Assert ($honErrs.Count -eq 0) 'sem claim installed/active para opcionais e pilotos' ($honErrs -join ' | ')
}

# Healthcheck: executa -Json e valida envelope.
$hcJson = ''
$hcCode = -1
try {
  $hcJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $hcPath -Json -RepoRoot $RepoRoot 2>&1 | Out-String
  $hcCode = $LASTEXITCODE
}
catch {
  $hcJson = $_.Exception.Message
  $hcCode = -1
}
Assert ($hcCode -eq 0) 'healthcheck exit 0' ('exit=' + $hcCode)
$env = $null
try {
  $env = $hcJson | ConvertFrom-Json
  Assert ($null -ne $env) 'healthcheck emite JSON parseavel'
}
catch {
  Assert $false 'healthcheck emite JSON parseavel' ($hcJson.Substring(0, [Math]::Min(300, $hcJson.Length)))
}
if ($null -ne $env) {
  Assert (([string]$env.schema_version) -ceq '1') 'healthcheck schema_version == 1'
  $res = @($env.results)
  Assert ($res.Count -ge 12) 'healthcheck cobre >=12 capabilities' ('obtido: ' + $res.Count)
  $fErrs = New-Object System.Collections.ArrayList
  foreach ($r in $res) {
    foreach ($f in @('installed', 'configured', 'healthy', 'managed')) {
      $v = $null
      try { $v = $r.$f } catch { $v = $null }
      if (($null -eq $v) -or (-not ($v -is [bool]))) { [void]$fErrs.Add(([string]$r.id + ': ' + $f + ' nao-bool')) }
    }
    if ([string]::IsNullOrWhiteSpace([string]$r.id)) { [void]$fErrs.Add('(sem id): resultado sem id') }
  }
  Assert ($fErrs.Count -eq 0) 'resultados com installed/configured/healthy/managed booleans' ($fErrs -join ' | ')
  if ($null -ne $reg) {
    $regIds = @($reg.capabilities | ForEach-Object { [string]$_.id })
    $resIds = @($res | ForEach-Object { [string]$_.id })
    $d = Compare-Object $regIds $resIds
    Assert (($null -eq $d)) 'healthcheck cobre exatamente os ids do registry' ((($d | ForEach-Object { $_.InputObject }) -join ','))
  }
  # Sem vazamento de secrets: valores de env sensiveis jamais aparecem no output.
  $leakErrs = New-Object System.Collections.ArrayList
  foreach ($n in @('AI_MEMORY_AUTH_TOKEN', 'JEV_API_KEY', 'JEV_BASE_URL', 'OPENCODE_ZEN_API_KEY', 'GITHUB_PERSONAL_ACCESS_TOKEN')) {
    $val = [System.Environment]::GetEnvironmentVariable($n)
    if (-not [string]::IsNullOrWhiteSpace($val)) {
      if ($hcJson.Contains($val)) { [void]$leakErrs.Add(('valor de ' + $n + ' presente no output')) }
    }
  }
  Assert ($leakErrs.Count -eq 0) 'healthcheck nao vaza valores de secrets' ($leakErrs -join ' | ')
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
