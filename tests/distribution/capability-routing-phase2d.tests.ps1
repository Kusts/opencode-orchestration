<#!
.SYNOPSIS
    Suite Phase 2D capability routing (SHADOW ONLY): corpus positivo/negativo, sessao, conflitos.
.DESCRIPTION
    Valida source/registry/capability-routing.json + lib/CapabilityResolver.ps1
    (deterministico, offline) sobre o corpus
    evidence/capabilities-phase-2d/shadow-corpus-2026-10-07.json (5 positivas,
    5 negativas, 1 conflito, 1 ambiguidade). Cobre schema do resolver, project
    detection com fixtures em TEMP, stack detection, profile/agent/skill/MCP
    selection, risk, conflitos (supabase+neon -> AMBIGUOUS), fallbacks,
    negative routing (5 casos), session isolation via overlay CLI e
    determinismo (mesma entrada 2x -> JSON identico). Como artefato, regrava
    evidence/capabilities-phase-2d/shadow-results-2026-10-07.json com as saidas
    reais do resolver sobre o corpus. CLI sempre com -NoTelemetry. Somente
    leitura no repo (exceto o artefato de results); fixtures so em TEMP.
    Estilo distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1. PS 5.1, ASCII.
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
function Test-HasAll($Actual, $Expected) {
  foreach ($e in @($Expected)) {
    if (@($Actual) -cnotcontains [string]$e) { return $false }
  }
  return $true
}
function Get-Missing($Actual, $Expected) {
  $m = New-Object System.Collections.ArrayList
  foreach ($e in @($Expected)) {
    if (@($Actual) -cnotcontains [string]$e) { [void]$m.Add([string]$e) }
  }
  return ($m -join ',')
}
function Get-Forbidden($Actual, $Banned) {
  $f = New-Object System.Collections.ArrayList
  foreach ($b in @($Banned)) {
    if (@($Actual) -ccontains [string]$b) { [void]$f.Add([string]$b) }
  }
  return ($f -join ',')
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$routingPath = Join-Path $RepoRoot 'source\registry\capability-routing.json'
$libPath = Join-Path $RepoRoot 'scripts\v3\lib\CapabilityResolver.ps1'
$cliPath = Join-Path $RepoRoot 'scripts\v3\capability-resolve.ps1'
$overlayPath = Join-Path $RepoRoot 'scripts\v3\capability-profile-overlay.ps1'
$corpusPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2d\shadow-corpus-2026-10-07.json'
$resultsPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2d\shadow-results-2026-10-07.json'

Assert (Test-Path -LiteralPath $routingPath -PathType Leaf) 'routing capability-routing.json existe'
Assert (Test-Path -LiteralPath $libPath -PathType Leaf) 'lib CapabilityResolver.ps1 existe'
Assert (Test-Path -LiteralPath $cliPath -PathType Leaf) 'cli capability-resolve.ps1 existe'
Assert (Test-Path -LiteralPath $overlayPath -PathType Leaf) 'cli capability-profile-overlay.ps1 existe'
Assert (Test-Path -LiteralPath $corpusPath -PathType Leaf) 'corpus shadow-corpus-2026-10-07.json existe'

$routing = $null
try {
  $routing = ([IO.File]::ReadAllText($routingPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $routing) 'routing parseia como JSON'
} catch { Assert $false 'routing parseia como JSON' $_.Exception.Message }

$corpus = $null
try {
  $corpus = ([IO.File]::ReadAllText($corpusPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $corpus) 'corpus parseia como JSON'
} catch { Assert $false 'corpus parseia como JSON' $_.Exception.Message }

if ($null -ne $routing) {
  Assert (([string]$routing.version) -ceq '1') 'routing version == 1'
  Assert (([string]$routing.resolver_version) -ceq '2d-shadow-1') 'routing resolver_version == 2d-shadow-1'
  Assert (([string]$routing.mode) -ceq 'shadow') 'routing mode == shadow'
  $rc = @($routing.reason_codes)
  Assert ($rc.Count -ge 14) 'routing reason_codes >= 14' ('obtido: ' + $rc.Count)
  foreach ($c in @('PROJECT_USES_SUPABASE', 'BROWSER_E2E_REQUIRED', 'LIBRARY_DOCS_REQUIRED', 'RISK_PRODUCTION_WRITE', 'AMBIGUOUS')) {
    Assert ($rc -ccontains $c) ('routing reason_code presente: ' + $c)
  }
  $tc = @($routing.task_classes)
  Assert ($tc.Count -eq 12) 'routing task_classes == 12' ('obtido: ' + $tc.Count)
  $markers = @($routing.stack_detectors | ForEach-Object { [string]$_.marker })
  foreach ($m in @('package.json', 'supabase', 'terraform')) {
    Assert ($markers -ccontains $m) ('routing stack_detector marker: ' + $m)
  }
  Assert ((@($routing.agent_rules)).Count -ge 9) 'routing agent_rules >= 9'
  Assert (([int]$routing.skill_policy.max_skills) -eq 3) 'routing skill max_skills == 3'
  $mcpNames = @($routing.mcp_rules | ForEach-Object { [string]$_.mcp })
  foreach ($m in @('playwright-mcp', 'chrome-devtools-mcp', 'context7')) {
    Assert ($mcpNames -ccontains $m) ('routing mcp_rule presente: ' + $m)
  }
  Assert ((@($routing.risk_model.levels)).Count -eq 4) 'routing risk levels == 4 (LOW/MEDIUM/HIGH/CRITICAL)'
  $eg = @($routing.exclusive_groups | Where-Object { [string]$_.id -ceq 'database-stack' })
  Assert ($eg.Count -eq 1) 'routing exclusive_group database-stack existe'
  if ($eg.Count -eq 1) {
    Assert ((@($eg[0].members) -ccontains 'database-supabase') -and (@($eg[0].members) -ccontains 'database-neon')) 'routing database-stack contem supabase + neon'
  }
  $fb = @($routing.fallbacks | Where-Object { ([string]$_.mcp) -ceq 'playwright-mcp' })
  Assert ($fb.Count -ge 1) 'routing fallback para playwright-mcp existe'
  if ($fb.Count -ge 1) {
    Assert (([string]$fb[0].fallback).Contains('Playwright CLI')) 'routing fallback playwright cita Playwright CLI'
  }
  Assert ((@($routing.deny_rules)).Count -ge 1) 'routing deny_rules nao vazio'
}

if ($null -ne $corpus) {
  Assert (([int]$corpus.version) -eq 1) 'corpus version == 1'
  $cases = @($corpus.cases)
  Assert ($cases.Count -eq 12) 'corpus tem 12 casos' ('obtido: ' + $cases.Count)
  $ids = @($cases | ForEach-Object { [string]$_.id })
  Assert ((@($ids | Sort-Object -Unique)).Count -eq 12) 'corpus ids unicos'
  foreach ($p in @('P1-', 'P2-', 'P3-', 'P4-', 'P5-', 'N1-', 'N2-', 'N3-', 'N4-', 'N5-', 'C1-', 'A1-')) {
    $hit = @($ids | Where-Object { $_ -like ($p + '*') }).Count
    Assert ($hit -eq 1) ('corpus caso presente: ' + $p)
  }
  $fxErrs = New-Object System.Collections.ArrayList
  foreach ($c in $cases) {
    if ([string]::IsNullOrWhiteSpace([string]$c.id)) { [void]$fxErrs.Add('(sem id)') }
    if (@('empty', 'supabase', 'terraform') -cnotcontains [string]$c.fixture) {
      [void]$fxErrs.Add(([string]$c.id + ': fixture invalida: ' + [string]$c.fixture))
    }
    if ($null -eq $c.expected) { [void]$fxErrs.Add(([string]$c.id + ': sem expected')) }
    if ($null -eq $c.not_expected) { [void]$fxErrs.Add(([string]$c.id + ': sem not_expected')) }
  }
  Assert ($fxErrs.Count -eq 0) 'corpus casos com id/fixture/expected/not_expected' ($fxErrs -join ' | ')
}

try { . $libPath } catch { Assert $false 'lib CapabilityResolver.ps1 carrega (dot-source)' $_.Exception.Message }

$tempBase = $env:TEMP
if ([string]::IsNullOrWhiteSpace($tempBase)) { $tempBase = Join-Path $RepoRoot 'cache\v3' }
$fxEmpty = Join-Path $tempBase 'phase2d-fx-empty'
$fxSupabase = Join-Path $tempBase 'phase2d-fx-supabase'
$fxTerraform = Join-Path $tempBase 'phase2d-fx-terraform'
foreach ($d in @($fxEmpty, $fxSupabase, $fxTerraform)) {
  if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $d -Force | Out-Null
}
[IO.File]::WriteAllText((Join-Path $fxSupabase 'package.json'), '{"name":"fx-supabase"}', [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $fxSupabase 'supabase') -Force | Out-Null
# P2-1: fixture supabase com evidencia concreta (config + migrations), nunca dir vazio
[IO.File]::WriteAllText((Join-Path (Join-Path $fxSupabase 'supabase') 'config.toml'), '[project]', [Text.UTF8Encoding]::new($false))
$fxSupaMig = Join-Path (Join-Path $fxSupabase 'supabase') 'migrations'
New-Item -ItemType Directory -Path $fxSupaMig -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $fxSupaMig '0001_init.sql'), 'create table t (id int);', [Text.UTF8Encoding]::new($false))
# P2-1: fixture controle com supabase/ vazio (sem evidencia) -> nunca prova banco
$fxSupabaseEmpty = Join-Path $tempBase 'phase2d-fx-supabase-empty'
if (Test-Path -LiteralPath $fxSupabaseEmpty) { Remove-Item -LiteralPath $fxSupabaseEmpty -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $fxSupabaseEmpty -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fxSupabaseEmpty 'supabase') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fxTerraform 'terraform') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $fxTerraform 'package.json'), '{"name":"fx-terraform"}', [Text.UTF8Encoding]::new($false))

$ctxEmpty = Get-ProjectContext -ProjectRoot $fxEmpty
Assert ((@($ctxEmpty.stacks) -cnotcontains 'supabase') -and (@($ctxEmpty.stacks) -cnotcontains 'terraform')) 'project detection: dir vazio sem stacks de banco/iac'
$ctxSup = Get-ProjectContext -ProjectRoot $fxSupabase
Assert (@($ctxSup.stacks) -ccontains 'supabase') 'project detection: supabase/ detecta stack supabase'
Assert (@($ctxSup.stacks) -ccontains 'node') 'project detection: package.json detecta stack node'
Assert (@($ctxSup.signals) -ccontains 'supabase-project') 'stack detection: signal supabase-project presente'
Assert (@($ctxSup.evidence) -ccontains 'marker:supabase') 'stack detection: evidence marker:supabase presente'
$ctxTf = Get-ProjectContext -ProjectRoot $fxTerraform
Assert (@($ctxTf.stacks) -ccontains 'terraform') 'project detection: terraform/ detecta stack terraform'

# --- P2-1 FIX: supabase/ vazio nao prova stack de banco ---
$ctxSupEmpty = Get-ProjectContext -ProjectRoot $fxSupabaseEmpty
Assert ((@($ctxSupEmpty.stacks) -cnotcontains 'supabase')) 'P2-1 supabase vazio sem stack supabase'
$rmSupEmpty = $null
try { $rmSupEmpty = Invoke-CapabilityResolve -TaskInput @{ task = 'Create migration to alter orders schema with ddl change'; task_class = 'migration'; project = @{ stack = '' }; projectRoot = $fxSupabaseEmpty } } catch { $rmSupEmpty = $null }
Assert ($null -ne $rmSupEmpty) 'P2-1 supabase vazio resolve sem throw'
if ($null -ne $rmSupEmpty) {
  Assert ((@($rmSupEmpty.profiles) -cnotcontains 'database-supabase')) 'P2-1 supabase vazio sem profile database-supabase'
  Assert ((@($rmSupEmpty.mcps) -cnotcontains 'supabase-mcp')) 'P2-1 supabase vazio sem supabase-mcp'
  Assert (([string]$rmSupEmpty.confidence) -ceq 'AMBIGUOUS') 'P2-1 supabase vazio confidence AMBIGUOUS'
}

$fxMap = @{ 'empty' = $fxEmpty; 'supabase' = $fxSupabase; 'terraform' = $fxTerraform }
$resolved = @{}
foreach ($c in @($corpus.cases)) {
  $fx = $fxMap[[string]$c.fixture]
  if ([string]::IsNullOrWhiteSpace($fx)) { $fx = $fxEmpty }
  $stack = ''
  try { $stack = [string]$c.project.stack } catch { $stack = '' }
  $input = @{ task = [string]$c.task; task_class = [string]$c.task_class; project = @{ stack = $stack }; projectRoot = $fx }
  $r = $null
  try { $r = Invoke-CapabilityResolve -TaskInput $input } catch { $r = $null }
  Assert ($null -ne $r) ('resolve executa: ' + [string]$c.id)
  if ($null -eq $r) { continue }
  $resolved[[string]$c.id] = $r
  Assert (([string]$r.mode) -ceq 'shadow') ([string]$c.id + ' mode == shadow')
  Assert ((@($r.skills)).Count -le 3) ([string]$c.id + ' skills <= 3')
  $miss = Get-Missing @($r.agents) @($c.expected.agents)
  Assert ([string]::IsNullOrWhiteSpace($miss)) ([string]$c.id + ' agent esperado') ('falta: ' + $miss)
  $missP = Get-Missing @($r.profiles) @($c.expected.profiles)
  Assert ([string]::IsNullOrWhiteSpace($missP)) ([string]$c.id + ' profiles esperados') ('falta: ' + $missP)
  $missM = Get-Missing @($r.mcps) @($c.expected.mcps)
  Assert ([string]::IsNullOrWhiteSpace($missM)) ([string]$c.id + ' mcps esperados') ('falta: ' + $missM)
  $missS = Get-Missing @($r.skills) @($c.expected.skills)
  Assert ([string]::IsNullOrWhiteSpace($missS)) ([string]$c.id + ' skills esperadas') ('falta: ' + $missS)
  Assert (([string]$r.risk.level) -ceq [string]$c.expected.risk) ([string]$c.id + ' risk == ' + [string]$c.expected.risk) ('obtido: ' + [string]$r.risk.level)
  Assert (([string]$r.confidence) -ceq [string]$c.expected.confidence) ([string]$c.id + ' confidence == ' + [string]$c.expected.confidence) ('obtido: ' + [string]$r.confidence)
  $missR = Get-Missing @($r.reason_codes) @($c.expected.reason_codes)
  Assert ([string]::IsNullOrWhiteSpace($missR)) ([string]$c.id + ' reason_codes esperados') ('falta: ' + $missR)
  $badP = Get-Forbidden @($r.profiles) @($c.not_expected.profiles)
  $badM = Get-Forbidden @($r.mcps) @($c.not_expected.mcps)
  $badC = Get-Forbidden @($r.capabilities) @($c.not_expected.caps)
  $badAll = ($badP + '|' + $badM + '|' + $badC).Trim('|')
  $noneBad = [string]::IsNullOrWhiteSpace($badAll.Replace('|', ''))
  Assert ($noneBad) ([string]$c.id + ' nada do not_expected ativo') ('achado: ' + $badAll)
}

if ($resolved.ContainsKey('P5-e2e-flow')) {
  $fb5 = @($resolved['P5-e2e-flow'].fallbacks)
  Assert ($fb5 -ccontains 'Playwright CLI 1.60 + skill playwright-cli') 'fallback P5 lista Playwright CLI'
}
if ($resolved.ContainsKey('P2-supabase-migration')) {
  $fb2 = @($resolved['P2-supabase-migration'].fallbacks)
  $hasSupFb = $false
  foreach ($f in $fb2) { if (([string]$f).Contains('Supabase CLI')) { $hasSupFb = $true } }
  Assert ($hasSupFb) 'fallback P2 lista Supabase CLI'
}
if ($resolved.ContainsKey('C1-supabase-neon-conflict')) {
  $cc = $resolved['C1-supabase-neon-conflict']
  Assert (([string]$cc.confidence) -ceq 'AMBIGUOUS') 'conflito C1 confidence AMBIGUOUS'
  Assert (((@($cc.profiles) -cnotcontains 'database-supabase') -and (@($cc.profiles) -cnotcontains 'database-neon'))) 'conflito C1 sem ambos os profiles'
  Assert (((@($cc.mcps) -cnotcontains 'supabase-mcp') -and (@($cc.mcps) -cnotcontains 'neon-mcp'))) 'conflito C1 sem ambos os MCPs'
}
if ($resolved.ContainsKey('A1-empty-ambiguous')) {
  $aa = $resolved['A1-empty-ambiguous']
  Assert (([string]$aa.confidence) -ceq 'AMBIGUOUS') 'ambiguidade A1 confidence AMBIGUOUS'
  Assert ((@($aa.reason_codes) -ccontains 'AMBIGUOUS')) 'ambiguidade A1 reason AMBIGUOUS'
  Assert ((@($aa.agents) -ccontains 'coder')) 'ambiguidade A1 agent coder'
}

# --- REV1: skills somente ACTIVE no catalogo ---
$catActive = @()
try {
  $catDoc = ([IO.File]::ReadAllText((Join-Path $RepoRoot 'source\registry\skills-catalog.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $catActive = @($catDoc.skills | Where-Object { ([string]$_.status) -ceq 'ACTIVE' } | ForEach-Object { ([string]$_.id).Trim().ToLowerInvariant() })
} catch { $catActive = @() }
Assert ($catActive.Count -gt 0) 'catalogo skills ACTIVE nao vazio'
foreach ($c in @($corpus.cases)) {
  $r = $resolved[[string]$c.id]
  if ($null -eq $r) { continue }
  $badSk = @(@($r.skills) | Where-Object { $catActive -cnotcontains ([string]$_).Trim().ToLowerInvariant() })
  Assert ($badSk.Count -eq 0) ('skills ACTIVE no catalogo: ' + [string]$c.id) ($badSk -join ',')
}

# --- REV1: igualdade exata dos conjuntos (agents/profiles/mcps/skills) ---
function Get-SortedKey($Arr) {
  $a = @($Arr | ForEach-Object { [string]$_ } | Sort-Object)
  return ($a -join '|')
}
foreach ($c in @($corpus.cases)) {
  $r = $resolved[[string]$c.id]
  if ($null -eq $r) { continue }
  Assert ((Get-SortedKey @($r.agents)) -ceq (Get-SortedKey @($c.expected.agents))) ([string]$c.id + ' agents igualdade exata') ('obtido: ' + (Get-SortedKey @($r.agents)))
  Assert ((Get-SortedKey @($r.profiles)) -ceq (Get-SortedKey @($c.expected.profiles))) ([string]$c.id + ' profiles igualdade exata') ('obtido: ' + (Get-SortedKey @($r.profiles)))
  Assert ((Get-SortedKey @($r.mcps)) -ceq (Get-SortedKey @($c.expected.mcps))) ([string]$c.id + ' mcps igualdade exata') ('obtido: ' + (Get-SortedKey @($r.mcps)))
  Assert ((Get-SortedKey @($r.skills)) -ceq (Get-SortedKey @($c.expected.skills))) ([string]$c.id + ' skills igualdade exata') ('obtido: ' + (Get-SortedKey @($r.skills)))
}

# --- REV1: PILOT exige prova de projeto (marker ou stack declarado) ---
if ($resolved.ContainsKey('P2-supabase-migration')) {
  Assert ((@($resolved['P2-supabase-migration'].pilot_profiles) -ccontains 'database-supabase')) 'PILOT P2 pilot_profiles contem database-supabase'
}
if ($resolved.ContainsKey('C1-supabase-neon-conflict')) {
  Assert ((@($resolved['C1-supabase-neon-conflict'].pilot_profiles).Count) -eq 0) 'PILOT C1 pilot_profiles vazio'
}
if ($resolved.ContainsKey('A1-empty-ambiguous')) {
  Assert ((@($resolved['A1-empty-ambiguous'].pilot_profiles).Count) -eq 0) 'PILOT A1 pilot_profiles vazio'
}
$mentionOnly = @{ task = 'Create supabase migration to alter orders schema with ddl change'; task_class = 'migration'; project = @{ stack = '' }; projectRoot = $fxEmpty }
$rm = $null
try { $rm = Invoke-CapabilityResolve -TaskInput $mentionOnly } catch { $rm = $null }
Assert ($null -ne $rm) 'PILOT mencao-sem-prova executa'
if ($null -ne $rm) {
  Assert ((@($rm.profiles) -cnotcontains 'database-supabase')) 'PILOT mencao-sem-prova sem profile database-supabase'
  Assert ((@($rm.mcps) -cnotcontains 'supabase-mcp')) 'PILOT mencao-sem-prova sem supabase-mcp'
  Assert (([string]$rm.confidence) -ceq 'AMBIGUOUS') 'PILOT mencao-sem-prova confidence AMBIGUOUS'
  Assert ((@($rm.reason_codes) -ccontains 'TASK_REQUIRES_DATABASE')) 'PILOT mencao-sem-prova mantem reason informativo'
}

# --- REV1: fail-safe de registry (RoutingPath invalido -> fallback sem throw) ---
$fs = $null
$fsThrew = $false
try { $fs = Invoke-CapabilityResolve -TaskInput @{ task = 'anything'; task_class = 'migration' } -RoutingPath (Join-Path $tempBase 'phase2d-no-such-routing.json') }
catch { $fsThrew = $true }
Assert ((-not $fsThrew) -and ($null -ne $fs)) 'fail-safe registry retorna sem throw'
if ($null -ne $fs) {
  Assert ((@($fs.agents) -join '|') -ceq 'coder') 'fail-safe agents == coder'
  Assert ((@($fs.skills).Count) -eq 0) 'fail-safe skills vazio'
  Assert ((@($fs.profiles).Count) -eq 0) 'fail-safe profiles vazio'
  Assert ((@($fs.capabilities) -join '|') -ceq 'code.bounded-edit') 'fail-safe capabilities == code.bounded-edit'
  Assert (([string]$fs.risk.level) -ceq 'MEDIUM') 'fail-safe risk MEDIUM'
  Assert (([string]$fs.confidence) -ceq 'AMBIGUOUS') 'fail-safe confidence AMBIGUOUS'
  Assert ((@($fs.reason_codes) -ccontains 'AMBIGUOUS')) 'fail-safe reason AMBIGUOUS'
  Assert (([string]$fs.mode) -ceq 'shadow') 'fail-safe mode shadow'
}

# --- REV1: fallbacks completos (todo MCP selecionavel tem fallback) ---
$fbMap = @{}
foreach ($f in @($routing.fallbacks)) { $fbMap[[string]$f.mcp] = [string]$f.fallback }
Assert ((@($routing.fallbacks)).Count -ge 8) 'routing fallbacks >= 8' ('obtido: ' + (@($routing.fallbacks)).Count)
foreach ($m in @('context7', 'jev', 'ai-memory', 'playwright-mcp', 'chrome-devtools-mcp', 'supabase-mcp', 'neon-mcp')) {
  Assert ($fbMap.ContainsKey($m)) ('routing fallback presente: ' + $m)
}
foreach ($c in @($corpus.cases)) {
  $r = $resolved[[string]$c.id]
  if ($null -eq $r) { continue }
  $noFb = @(@($r.mcps) | Where-Object { -not $fbMap.ContainsKey([string]$_) })
  Assert ($noFb.Count -eq 0) ([string]$c.id + ' todo MCP com fallback') ($noFb -join ',')
}

$ovDir = Join-Path $tempBase 'phase2d-overlays'
if (Test-Path -LiteralPath $ovDir) { Remove-Item -LiteralPath $ovDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $ovDir -Force | Out-Null
$ovA = ''
$ovACode = -1
try {
  $ovA = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'testing' -SessionId 'phase2d-A' -OutDir $ovDir 2>&1 | Out-String
  $ovACode = $LASTEXITCODE
} catch { $ovA = $_.Exception.Message }
Assert ($ovACode -eq 0) 'overlay session A exit 0' ('exit=' + $ovACode)
$ovB = ''
$ovBCode = -1
try {
  $ovB = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'core' -SessionId 'phase2d-B' -OutDir $ovDir 2>&1 | Out-String
  $ovBCode = $LASTEXITCODE
} catch { $ovB = $_.Exception.Message }
Assert ($ovBCode -eq 0) 'overlay session B exit 0' ('exit=' + $ovBCode)
$joA = $null; $joB = $null
try { $joA = $ovA | ConvertFrom-Json } catch { $joA = $null }
try { $joB = $ovB | ConvertFrom-Json } catch { $joB = $null }
Assert (($null -ne $joA) -and ($null -ne $joB)) 'overlays parseiam como JSON'
if (($null -ne $joA) -and ($null -ne $joB)) {
  Assert ([string]$joA.path -cne [string]$joB.path) 'session isolation: paths diferentes por sessao'
  Assert ((@($joA.mcps) -ccontains 'playwright-mcp')) 'session A (testing) com playwright-mcp'
  Assert ((@($joB.mcps) -cnotcontains 'playwright-mcp')) 'session B (sem testing) sem playwright-mcp'
  Assert ((([string]$joA.mode -ceq 'shadow') -and ([string]$joB.mode -ceq 'shadow'))) 'overlays mode shadow'
  $pa = [string]$joA.path; $pb = [string]$joB.path
  Assert ((Test-Path -LiteralPath $pa -PathType Leaf) -and (Test-Path -LiteralPath $pb -PathType Leaf)) 'overlay files existem no OutDir'
  $relA = ''; $relACode = -1
  try {
    $relA = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -SessionId 'phase2d-A' -OutDir $ovDir -Release 2>&1 | Out-String
    $relACode = $LASTEXITCODE
  } catch { $relA = $_.Exception.Message }
  Assert (($relACode -eq 0) -and (-not (Test-Path -LiteralPath $pa))) 'overlay session A release remove arquivo'
  $relB = ''; $relBCode = -1
  try {
    $relB = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -SessionId 'phase2d-B' -OutDir $ovDir -Release 2>&1 | Out-String
    $relBCode = $LASTEXITCODE
  } catch { $relB = $_.Exception.Message }
  Assert (($relBCode -eq 0) -and (-not (Test-Path -LiteralPath $pb))) 'overlay session B release remove arquivo'
}

$detTask = Join-Path $tempBase 'phase2d-det-task.json'
[IO.File]::WriteAllText($detTask, '{"task_id":"P5-det","task":"Validate checkout e2e fluxo web with playwright navigation across formulario steps","task_class":"testing","project":{"stack":""}}', [Text.UTF8Encoding]::new($false))
$det1 = ''; $detCode1 = -1
try {
  $det1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $detTask -ProjectRoot $fxEmpty -NoTelemetry 2>&1 | Out-String
  $detCode1 = $LASTEXITCODE
} catch { $det1 = $_.Exception.Message }
$det2 = ''; $detCode2 = -1
try {
  $det2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $detTask -ProjectRoot $fxEmpty -NoTelemetry 2>&1 | Out-String
  $detCode2 = $LASTEXITCODE
} catch { $det2 = $_.Exception.Message }
Assert (($detCode1 -eq 0) -and ($detCode2 -eq 0)) 'cli determinismo exit 0 nas 2 rodadas'
Assert ($det1.Trim() -ceq $det2.Trim()) 'determinismo: mesma entrada 2x -> JSON identico'
$dj = $null
try { $dj = $det1 | ConvertFrom-Json } catch { $dj = $null }
Assert ($null -ne $dj) 'cli emite JSON parseavel'
if ($null -ne $dj) {
  Assert (([string]$dj.mode) -ceq 'shadow') 'cli mode == shadow'
  Assert (([string]$dj.resolver_version) -ceq '2d-shadow-1') 'cli resolver_version == 2d-shadow-1'
  Assert (([string]$dj.task_id) -ceq 'P5-det') 'cli preserva task_id'
  Assert ((@($dj.agents_selected) -ccontains 'tester')) 'cli P5 agent tester'
  Assert ((@($dj.profiles_selected) -ccontains 'testing')) 'cli P5 profile testing'
  Assert ((@($dj.mcps_selected) -ccontains 'playwright-mcp')) 'cli P5 mcp playwright-mcp'
  Assert (([string]$dj.risk) -ceq 'MEDIUM') 'cli P5 risk MEDIUM'
}

# --- REV1: sanitizacao CLI (canario nunca persiste em stdout/OutFile) ---
$canTask = Join-Path $tempBase 'phase2d-canary-task.json'
[IO.File]::WriteAllText($canTask, '{"task_id":"sk-SYNTHETICSECRET x","task_class":"sk-SYNTHETICSECRET","task":"read docs"}', [Text.UTF8Encoding]::new($false))
$canOut = Join-Path $tempBase 'phase2d-canary-out.json'
$canStd = ''
$canCode = -1
try {
  $canStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $canTask -ProjectRoot $fxEmpty -OutFile $canOut -NoTelemetry 2>&1 | Out-String
  $canCode = $LASTEXITCODE
} catch { $canStd = $_.Exception.Message }
Assert ($canCode -eq 0) 'sanitizacao CLI exit 0'
Assert ($canStd -cnotmatch 'sk-SYNTHETICSECRET') 'sanitizacao stdout sem canario'
$canFile = 'sk-SYNTHETICSECRET'
try { $canFile = [IO.File]::ReadAllText($canOut, [Text.UTF8Encoding]::new($false)) } catch { $canFile = 'sk-SYNTHETICSECRET' }
Assert ($canFile -cnotmatch 'sk-SYNTHETICSECRET') 'sanitizacao OutFile sem canario'
$cj = $null
try { $cj = $canStd | ConvertFrom-Json } catch { $cj = $null }
Assert (($null -ne $cj) -and (([string]$cj.task_id) -ceq 'unknown')) 'sanitizacao task_id invalido -> unknown'
Assert (($null -ne $cj) -and (([string]$cj.task_class) -ceq 'unknown')) 'sanitizacao task_class fora da allowlist -> unknown'
Assert (($null -ne $cj) -and ((@($cj.reason_codes) -ccontains 'AMBIGUOUS'))) 'sanitizacao task_class unknown preserva reason AMBIGUOUS'
Remove-Item -LiteralPath $canTask -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $canOut -Force -ErrorAction SilentlyContinue

# --- R2 FIX 1: telemetria grava task_id como hash (canario exato nunca persiste) ---
$can2Task = Join-Path $tempBase 'phase2d-canary2-task.json'
[IO.File]::WriteAllText($can2Task, '{"task_id":"sk-SYNTHETICSECRET","task_class":"sk-SYNTHETICSECRET","task":"read docs"}', [Text.UTF8Encoding]::new($false))
$can2Tel = Join-Path $tempBase 'phase2d-canary2-resolver.jsonl'
if (Test-Path -LiteralPath $can2Tel) { Remove-Item -LiteralPath $can2Tel -Force -ErrorAction SilentlyContinue }
$can2Std = ''
$can2Code = -1
try {
  $can2Std = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $can2Task -ProjectRoot $fxEmpty -TelemetryPath $can2Tel 2>&1 | Out-String
  $can2Code = $LASTEXITCODE
} catch { $can2Std = $_.Exception.Message }
Assert ($can2Code -eq 0) 'telemetria hash CLI exit 0' ('exit=' + $can2Code)
$can2j = $null
try { $can2j = $can2Std | ConvertFrom-Json } catch { $can2j = $null }
Assert (($null -ne $can2j) -and (([string]$can2j.task_class) -ceq 'unknown')) 'telemetria hash stdout task_class unknown'
Assert (Test-Path -LiteralPath $can2Tel -PathType Leaf) 'telemetria JSONL criado no TelemetryPath'
$expHash = ''
try {
  $sha2 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hh2 = $sha2.ComputeHash([Text.Encoding]::UTF8.GetBytes('sk-SYNTHETICSECRET'))
    $expHash = ((($hh2 | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16))
  }
  finally { try { $sha2.Dispose() } catch { } }
} catch { $expHash = '' }
Assert ((-not [string]::IsNullOrWhiteSpace($expHash)) -and ($expHash -cmatch '^[0-9a-f]{16}$')) 'telemetria hash esperado 16 hex'
$telText = ''
try { $telText = [IO.File]::ReadAllText($can2Tel, [Text.UTF8Encoding]::new($false)) } catch { $telText = '' }
Assert (-not $telText.Contains('sk-SYNTHETICSECRET')) 'telemetria JSONL sem literal do canario'
if (-not [string]::IsNullOrWhiteSpace($expHash)) {
  Assert ($telText.Contains($expHash)) 'telemetria JSONL contem hash 16hex do task_id'
}
Remove-Item -LiteralPath $can2Task -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $can2Tel -Force -ErrorAction SilentlyContinue

# --- R2 FIX 1: -TelemetryPath fora do confinado -> exit 2 (fail-closed) ---
# O confinamento produtivo aceita <repo>\cache\v3\telemetry e o $env:TEMP do
# processo filho. Quando o repo vive sob o TEMP do SO (worktree em TEMP), o
# caminho evidence/ bate no prefixo TEMP sem querer e o CLI aceita; por isso o
# filho recebe um TEMP/TMP efemero exclusivo (nunca ancestor de evidence/),
# com o ambiente do processo pai restaurado em finally.
$evilTel = Join-Path $RepoRoot 'evidence\phase2d-tel-evil.jsonl'
$evilTask = Join-Path $tempBase 'phase2d-evil-task.json'
[IO.File]::WriteAllText($evilTask, '{"task_id":"EVIL-1","task":"read docs","task_class":"documentation"}', [Text.UTF8Encoding]::new($false))
$evilTmpDir = Join-Path $tempBase ('phase2d-evil-temp-' + [Guid]::NewGuid().ToString('n'))
if (Test-Path -LiteralPath $evilTmpDir) { throw 'Temporary fixture path collision; preserving existing directory.' }
New-Item -ItemType Directory -Path $evilTmpDir -Force | Out-Null
$oldEapEvil = $ErrorActionPreference
$oldTempEvil = $env:TEMP
$oldTmpEvil = $env:TMP
$evilStd = ''
$evilCode = -1
try {
  $ErrorActionPreference = 'Continue'
  $env:TEMP = $evilTmpDir
  $env:TMP = $evilTmpDir
  $evilStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $evilTask -ProjectRoot $fxEmpty -TelemetryPath $evilTel 2>&1 | Out-String
  $evilCode = $LASTEXITCODE
}
finally {
  $ErrorActionPreference = $oldEapEvil
  if ($null -eq $oldTempEvil) { Remove-Item -LiteralPath 'Env:\TEMP' -Force -ErrorAction SilentlyContinue } else { $env:TEMP = $oldTempEvil }
  if ($null -eq $oldTmpEvil) { Remove-Item -LiteralPath 'Env:\TMP' -Force -ErrorAction SilentlyContinue } else { $env:TMP = $oldTmpEvil }
}
Assert ($evilCode -eq 2) 'telemetry fora do confinado exit 2' ('exit=' + $evilCode)
Assert (-not (Test-Path -LiteralPath $evilTel)) 'telemetry fora do confinado nada escrito'
Remove-Item -LiteralPath $evilTask -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $evilTmpDir -Recurse -Force -ErrorAction SilentlyContinue

# --- R2 FIX 2: schema invalido '{}' via -RoutingPath -> fallback sem throw ---
$badSchema = Join-Path $tempBase 'phase2d-bad-schema.json'
[IO.File]::WriteAllText($badSchema, '{}', [Text.UTF8Encoding]::new($false))
$badCliTask = Join-Path $tempBase 'phase2d-badschema-task.json'
[IO.File]::WriteAllText($badCliTask, '{"task_id":"SCHEMA-1","task":"read docs","task_class":"documentation","project":{"stack":""}}', [Text.UTF8Encoding]::new($false))
$badStd = ''
$badCode = -1
try {
  $badStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $badCliTask -ProjectRoot $fxEmpty -RoutingPath $badSchema -NoTelemetry 2>&1 | Out-String
  $badCode = $LASTEXITCODE
} catch { $badStd = $_.Exception.Message }
Assert ($badCode -eq 0) 'schema invalido CLI exit 0 sem throw' ('exit=' + $badCode)
$badJ = $null
try { $badJ = $badStd | ConvertFrom-Json } catch { $badJ = $null }
Assert (($null -ne $badJ) -and ((@($badJ.agents_selected) -join '|') -ceq 'coder')) 'schema invalido agents == coder'
Assert (($null -ne $badJ) -and ((@($badJ.skills_selected).Count) -eq 0)) 'schema invalido skills vazio'
Assert (($null -ne $badJ) -and ((@($badJ.capabilities_selected) -join '|') -ceq 'code.bounded-edit')) 'schema invalido capabilities == code.bounded-edit'
Assert (($null -ne $badJ) -and (([string]$badJ.risk) -ceq 'MEDIUM')) 'schema invalido risk MEDIUM'
Assert (($null -ne $badJ) -and (([string]$badJ.confidence) -ceq 'AMBIGUOUS')) 'schema invalido confidence AMBIGUOUS'
Assert (($null -ne $badJ) -and ((@($badJ.reason_codes) -ccontains 'AMBIGUOUS'))) 'schema invalido reason AMBIGUOUS'
Remove-Item -LiteralPath $badSchema -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $badCliTask -Force -ErrorAction SilentlyContinue

# --- R2 FIX 2: JSON malformado -> fallback sem throw ---
$badJson = Join-Path $tempBase 'phase2d-bad-json.json'
[IO.File]::WriteAllText($badJson, 'this is not json {{{', [Text.UTF8Encoding]::new($false))
$fsBad = $null
$fsBadThrew = $false
try { $fsBad = Invoke-CapabilityResolve -TaskInput @{ task = 'read docs'; task_class = 'documentation' } -RoutingPath $badJson }
catch { $fsBadThrew = $true }
Assert ((-not $fsBadThrew) -and ($null -ne $fsBad)) 'JSON malformado retorna sem throw'
if ($null -ne $fsBad) {
  Assert ((@($fsBad.agents) -join '|') -ceq 'coder') 'JSON malformado agents == coder'
  Assert ((@($fsBad.capabilities) -join '|') -ceq 'code.bounded-edit') 'JSON malformado capabilities == code.bounded-edit'
  Assert (([string]$fsBad.risk.level) -ceq 'MEDIUM') 'JSON malformado risk MEDIUM'
  Assert (([string]$fsBad.confidence) -ceq 'AMBIGUOUS') 'JSON malformado confidence AMBIGUOUS'
  Assert ((@($fsBad.reason_codes) -ccontains 'AMBIGUOUS')) 'JSON malformado reason AMBIGUOUS'
}
Remove-Item -LiteralPath $badJson -Force -ErrorAction SilentlyContinue

# --- REV1: CLI projeta permissions (refund Stripe -> deny + CRITICAL) ---
$finTask = Join-Path $tempBase 'phase2d-fin-task.json'
[IO.File]::WriteAllText($finTask, '{"task_id":"FIN-refund-1","task":"Process stripe refund for payout cobranca dispute","task_class":"implementation","project":{"stack":""}}', [Text.UTF8Encoding]::new($false))
$finStd = ''
try {
  $finStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $finTask -ProjectRoot $fxEmpty -NoTelemetry 2>&1 | Out-String
} catch { $finStd = '' }
$fj = $null
try { $fj = $finStd | ConvertFrom-Json } catch { $fj = $null }
Assert (($null -ne $fj) -and (([string]$fj.permissions.recommendation) -ceq 'deny')) 'CLI financeiro permissions.recommendation == deny'
Assert (($null -ne $fj) -and (([string]$fj.risk) -ceq 'CRITICAL')) 'CLI financeiro risk == CRITICAL'
Assert (($null -ne $fj) -and (([string]$fj.task_class) -ceq 'implementation')) 'CLI preserva task_class valida da allowlist'
Remove-Item -LiteralPath $finTask -Force -ErrorAction SilentlyContinue

# --- REV1: overlay exclusividade + id desconhecido ---
# (EAP local Continue: exit != 0 com stderr vira erro terminante sob Stop; aqui o exit code e o assert)
$ovRevDir = Join-Path $tempBase 'phase2d-overlays-rev1'
if (Test-Path -LiteralPath $ovRevDir) { Remove-Item -LiteralPath $ovRevDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $ovRevDir -Force | Out-Null
$oldEapOv = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ovC = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'database-supabase,database-neon' -SessionId 'phase2d-C' -OutDir $ovRevDir 2>&1 | Out-String
$ovCCode = $LASTEXITCODE
$ovU = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'nope-unknown-xyz' -SessionId 'phase2d-U' -OutDir $ovRevDir 2>&1 | Out-String
$ovUCode = $LASTEXITCODE
$ErrorActionPreference = $oldEapOv
Assert ($ovCCode -eq 2) 'overlay conflito supabase+neon exit 2' ('exit=' + $ovCCode)
Assert ($ovC -cmatch 'exclusivos') 'overlay conflito erro claro'
Assert ($ovUCode -eq 2) 'overlay id desconhecido exit 2' ('exit=' + $ovUCode)
Assert ($ovU -cmatch 'desconhecido') 'overlay id desconhecido erro claro'
Remove-Item -LiteralPath $ovRevDir -Recurse -Force -ErrorAction SilentlyContinue

# --- P2-2 FIX: todo profile aceito deriva MCPs do registry ---
$oldEapP2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$ovProd = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'product' -SessionId 'phase2d-P' -OutDir $ovDir 2>&1 | Out-String
$ovProdCode = $LASTEXITCODE
$ovCoreDev = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'core-dev' -SessionId 'phase2d-CD' -OutDir $ovDir 2>&1 | Out-String
$ovCoreDevCode = $LASTEXITCODE
$ovBackend = & powershell -NoProfile -ExecutionPolicy Bypass -File $overlayPath -Profiles 'backend' -SessionId 'phase2d-BE' -OutDir $ovDir 2>&1 | Out-String
$ovBackendCode = $LASTEXITCODE
$ErrorActionPreference = $oldEapP2
Assert ($ovProdCode -eq 0) 'P2-2 overlay product exit 0' ('exit=' + $ovProdCode)
$joProd = $null; try { $joProd = $ovProd | ConvertFrom-Json } catch { $joProd = $null }
Assert (($null -ne $joProd) -and ((@($joProd.mcps) -ccontains 'posthog-mcp'))) 'P2-2 overlay product deriva posthog-mcp'
Assert ($ovCoreDevCode -eq 0) 'P2-2 overlay core-dev exit 0' ('exit=' + $ovCoreDevCode)
$joCD = $null; try { $joCD = $ovCoreDev | ConvertFrom-Json } catch { $joCD = $null }
Assert (($null -ne $joCD) -and ((@($joCD.mcps) -ccontains 'github-mcp'))) 'P2-2 overlay core-dev deriva github-mcp'
Assert ($ovBackendCode -eq 0) 'P2-2 overlay backend exit 0' ('exit=' + $ovBackendCode)
$joBE = $null; try { $joBE = $ovBackend | ConvertFrom-Json } catch { $joBE = $null }
Assert (($null -ne $joBE) -and ((@($joBE.mcps) -ccontains 'postman-mcp'))) 'P2-2 overlay backend deriva postman-mcp'

# --- P2-3 FIX: classe invalida nao contamina a decisao ---
$badClassTask = Join-Path $tempBase 'phase2d-badclass-task.json'
[IO.File]::WriteAllText($badClassTask, '{"task_id":"BC-1","task":"read docs overview","task_class":"production","project":{"stack":""}}', [Text.UTF8Encoding]::new($false))
$badClassStd = ''
$badClassCode = -1
try {
  $badClassStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $badClassTask -ProjectRoot $fxEmpty -NoTelemetry 2>&1 | Out-String
  $badClassCode = $LASTEXITCODE
} catch { $badClassStd = $_.Exception.Message }
Assert ($badClassCode -eq 0) 'P2-3 classe invalida CLI exit 0' ('exit=' + $badClassCode)
$bcJ = $null; try { $bcJ = $badClassStd | ConvertFrom-Json } catch { $bcJ = $null }
Assert (($null -ne $bcJ) -and (([string]$bcJ.task_class) -ceq 'unknown')) 'P2-3 classe invalida publica unknown'
if ($null -ne $bcJ) {
  Assert (([string]$bcJ.risk) -cne 'HIGH') 'P2-3 classe invalida sem HIGH fantasma' ('obtido: ' + [string]$bcJ.risk)
  Assert ((@($bcJ.reason_codes) -cnotcontains 'RISK_PRODUCTION_WRITE')) 'P2-3 classe invalida sem RISK_PRODUCTION_WRITE'
  Assert (([string]$bcJ.permissions.recommendation) -ceq 'allow') 'P2-3 classe invalida perm allow'
}
Remove-Item -LiteralPath $badClassTask -Force -ErrorAction SilentlyContinue

# --- P2-4 FIX: release isolado nao e escrita em producao ---
$relTask = Join-Path $tempBase 'phase2d-release-task.json'
[IO.File]::WriteAllText($relTask, '{"task_id":"REL-1","task":"review release notes for docs update","task_class":"documentation","project":{"stack":""}}', [Text.UTF8Encoding]::new($false))
$relStd = ''
try { $relStd = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPath -TaskFile $relTask -ProjectRoot $fxEmpty -NoTelemetry 2>&1 | Out-String } catch { $relStd = '' }
$rj = $null; try { $rj = $relStd | ConvertFrom-Json } catch { $rj = $null }
Assert (($null -ne $rj) -and (([string]$rj.risk) -ceq 'LOW')) 'P2-4 release isolado risk LOW' ('obtido: ' + [string]$rj.risk)
if ($null -ne $rj) {
  Assert ((@($rj.reason_codes) -cnotcontains 'RISK_PRODUCTION_WRITE')) 'P2-4 release isolado sem RISK_PRODUCTION_WRITE'
  Assert (([string]$rj.permissions.recommendation) -ceq 'allow') 'P2-4 release isolado perm allow'
}
Remove-Item -LiteralPath $relTask -Force -ErrorAction SilentlyContinue

$resArr = New-Object System.Collections.ArrayList
foreach ($c in @($corpus.cases)) {
  $r = $resolved[[string]$c.id]
  if ($null -eq $r) { continue }
  [void]$resArr.Add([PSCustomObject]@{
    case_id = [string]$c.id
    task = [string]$c.task
    task_class = [string]$c.task_class
    agents = @($r.agents)
    profiles = @($r.profiles)
    pilot_profiles = @($r.pilot_profiles)
    mcps = @($r.mcps)
    skills = @($r.skills)
    capabilities = @($r.capabilities)
    risk = [string]$r.risk.level
    reason_codes = @($r.reason_codes)
    fallbacks = @($r.fallbacks)
    confidence = [string]$r.confidence
    mode = [string]$r.mode
  })
}
$resDoc = [PSCustomObject]@{
  version = 1
  generated = '2026-10-07'
  resolver_version = '2d-shadow-1'
  mode = 'shadow'
  note = 'generated by tests/distribution/capability-routing-phase2d.tests.ps1 over shadow-corpus-2026-10-07.json; shadow only, no activation'
  count = $resArr.Count
  results = @($resArr)
}
[IO.File]::WriteAllText($resultsPath, ($resDoc | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
Assert (Test-Path -LiteralPath $resultsPath -PathType Leaf) 'results shadow-results-2026-10-07.json gravado'
$rp = $null
try { $rp = ([IO.File]::ReadAllText($resultsPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $rp = $null }
Assert ($null -ne $rp) 'results parseia como JSON'
if ($null -ne $rp) {
  Assert (([int]$rp.count) -eq 12) 'results count == 12' ('obtido: ' + [string]$rp.count)
  $p2r = @($rp.results | Where-Object { [string]$_.case_id -ceq 'P2-supabase-migration' })
  Assert ($p2r.Count -eq 1) 'results contem P2'
  if ($p2r.Count -eq 1) {
    Assert (([string]$p2r[0].risk) -ceq 'HIGH') 'results P2 risk HIGH'
    Assert ((@($p2r[0].profiles) -ccontains 'database-supabase')) 'results P2 profile database-supabase'
    Assert ((@($p2r[0].pilot_profiles) -ccontains 'database-supabase')) 'results P2 pilot_profiles database-supabase'
  }
  $c1r = @($rp.results | Where-Object { [string]$_.case_id -ceq 'C1-supabase-neon-conflict' })
  if ($c1r.Count -eq 1) {
    Assert (([string]$c1r[0].confidence) -ceq 'AMBIGUOUS') 'results C1 confidence AMBIGUOUS'
  } else { Assert $false 'results contem C1' }
}

Remove-Item -LiteralPath $fxEmpty -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fxSupabase -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fxSupabaseEmpty -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fxTerraform -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ovDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $detTask -Force -ErrorAction SilentlyContinue

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
