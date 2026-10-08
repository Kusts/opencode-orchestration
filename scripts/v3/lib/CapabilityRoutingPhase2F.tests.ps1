<#!
.SYNOPSIS
    Suite Phase 2F capability routing (SHADOW ONLY): refinamento reviewer/docs-manager/failing/checkout-flow/fin-doc/prod-logs.
.DESCRIPTION
    Valida source/registry/capability-routing.json + lib/CapabilityResolver.ps1
    sobre o corpus evidence/capabilities-phase-2f/shadow-corpus-2026-10-08.json
    (30 fixture + 13 real). Cobre: regras de agente refinadas (reviewer antes
    de coder/architect; docs-manager antes de researcher; failing/fail como
    debug; checkout flow como E2E), skills (max 3, so ACTIVE, fail->systematic),
    MCP (browser contido; supabase/neon so com evidencia; nenhum MCP novo),
    risco (fin documental LOW vs execucao CRITICAL+deny; prod-logs LOW vs
    deploy HIGH+deny), 2F-FIX-DEBUGGER-R5R6 (R5/R5b: verbo de execucao em
    qualquer posicao + clausulas; R6: forma textual fechada de logs-read;
    descontaminacao por metadados: sinais de risco sobre o texto da tarefa,
    risk_context so eleva), flags de routing INALTERADAS (OFF), historico 2E intacto
    (pins + metricas do ledger), paridade 2D/2E via auto-check de comparables
    (alvo >=90%, sem alegar estabilidade produtiva) e determinismo/fail-safe.
    Como artefato, grava evidence/capabilities-phase-2f/shadow-results-2026-10-08.json
    e evidence/capabilities-phase-2f/metrics-2026-10-08.json. Somente leitura no
    repo (exceto os artefatos 2F); fixtures so em TEMP. Estilo distribution:
    'ok - ...' / 'NOT OK - ...', exit 0/1. PS 5.1, ASCII.
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
function Get-SortedKey($Arr) {
  $a = @($Arr | ForEach-Object { [string]$_ } | Sort-Object)
  return ($a -join '|')
}

$v3 = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $v3)
$routingPath = Join-Path $RepoRoot 'source\registry\capability-routing.json'
$flagsPath = Join-Path $RepoRoot 'source\registry\capability-flags.json'
$libPath = Join-Path $RepoRoot 'scripts\v3\lib\CapabilityResolver.ps1'
$cliPath = Join-Path $RepoRoot 'scripts\v3\capability-resolve.ps1'
$overlayPath = Join-Path $RepoRoot 'scripts\v3\capability-profile-overlay.ps1'
$corpusPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2f\shadow-corpus-2026-10-08.json'
$resultsPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2f\shadow-results-2026-10-08.json'
$metricsPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2f\metrics-2026-10-08.json'
$corpus2dPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2d\shadow-corpus-2026-10-07.json'
$ledger2ePath = Join-Path $RepoRoot 'evidence\capabilities-phase-2e\real-world-pilots-2026-10-07.json'
$ev2eDir = Join-Path $RepoRoot 'evidence\capabilities-phase-2e'

Assert (Test-Path -LiteralPath $routingPath -PathType Leaf) 'routing capability-routing.json existe'
Assert (Test-Path -LiteralPath $flagsPath -PathType Leaf) 'flags capability-flags.json existe'
Assert (Test-Path -LiteralPath $libPath -PathType Leaf) 'lib CapabilityResolver.ps1 existe'
Assert (Test-Path -LiteralPath $cliPath -PathType Leaf) 'cli capability-resolve.ps1 existe'
Assert (Test-Path -LiteralPath $overlayPath -PathType Leaf) 'cli capability-profile-overlay.ps1 existe'
Assert (Test-Path -LiteralPath $corpusPath -PathType Leaf) 'corpus shadow-corpus-2026-10-08.json existe'

$routing = $null
try {
  $routing = ([IO.File]::ReadAllText($routingPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $routing) 'routing parseia como JSON'
} catch { Assert $false 'routing parseia como JSON' $_.Exception.Message }

$corpus = $null
try {
  $corpus = ([IO.File]::ReadAllText($corpusPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $corpus) 'corpus 2F parseia como JSON'
} catch { Assert $false 'corpus 2F parseia como JSON' $_.Exception.Message }

# --- 2F: linhagem preservada (mesmo contrato de regressao 2D) ---
if ($null -ne $routing) {
  Assert (([string]$routing.version) -ceq '1') 'routing version == 1'
  Assert (([string]$routing.resolver_version) -ceq '2d-shadow-1') 'routing resolver_version == 2d-shadow-1 (linhagem 2F preservada; ver plano)'
  Assert (([string]$routing.mode) -ceq 'shadow') 'routing mode == shadow'
  $rules = @($routing.agent_rules)
  $agents = @($rules | ForEach-Object { [string]$_.agent })
  Assert ($agents -ccontains 'reviewer') 'routing agent_rules contem reviewer (2F)'
  Assert ($agents -ccontains 'docs-manager') 'routing agent_rules contem docs-manager (2F)'
  Assert ($agents -ccontains 'researcher') 'routing agent_rules contem researcher'
  $iRev = [array]::IndexOf($agents, 'reviewer')
  $iDm = [array]::IndexOf($agents, 'docs-manager')
  $iRes = [array]::IndexOf($agents, 'researcher')
  $iCod = [array]::IndexOf($agents, 'coder')
  Assert (($iRev -ge 0) -and ($iDm -ge 0) -and ($iRes -ge 0) -and ($iRev -lt $iDm) -and ($iDm -lt $iRes)) 'ordem reviewer < docs-manager < researcher (2F)'
  Assert (($iRev -ge 0) -and ($iCod -ge 0) -and ($iRev -lt $iCod)) 'review antes de default coder (2F)'
  $tRule = @($rules | Where-Object { [string]$_.agent -ceq 'tester' })[0]
  Assert ((@($tRule.keywords) -ccontains 'checkout flow')) 'tester keywords contem checkout flow (2F)'
  $dRule = @($rules | Where-Object { [string]$_.agent -ceq 'debugger' })[0]
  Assert ((@($dRule.keywords) -ccontains 'failing') -and (@($dRule.keywords) -ccontains 'fail')) 'debugger keywords contem failing/fail (2F)'
  $dmRule = @($rules | Where-Object { [string]$_.agent -ceq 'docs-manager' })[0]
  foreach ($k in @('setup guide', 'readme', 'lookup', 'procedure', 'release notes')) {
    Assert ((@($dmRule.keywords) -ccontains $k)) ('docs-manager keywords contem: ' + $k)
  }
  # sem segunda fonte de verdade: todo agente das regras existe em source/agents
  $mdNames = @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
  Assert ($mdNames.Count -eq 19) 'source/agents tem 19 agentes (sem worker novo)' ('obtido: ' + $mdNames.Count)
  $noMd = @($agents | Where-Object { $mdNames -cnotcontains $_ } | Sort-Object -Unique)
  Assert ($noMd.Count -eq 0) 'todo agent das regras existe em source/agents' ($noMd -join ',')
  Assert (([int]$routing.skill_policy.max_skills) -eq 3) 'routing skill max_skills == 3'
}

# --- 2F: flags de routing INALTERADAS (OFF) ---
try {
  $flags = ([IO.File]::ReadAllText($flagsPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (([bool]$flags.capability_router.active) -eq $false) 'flag capability_router.active OFF'
  Assert (([bool]$flags.capability_router.shadow) -eq $false) 'flag capability_router.shadow OFF'
  Assert (([bool]$flags.skill_routing.enabled) -eq $false) 'flag skill_routing OFF'
  Assert (([bool]$flags.mcp_routing.enabled) -eq $false) 'flag mcp_routing OFF'
  Assert (([bool]$flags.adaptive_ranking.enabled) -eq $false) 'flag adaptive_ranking OFF'
  Assert (([bool]$flags.routing_telemetry.enabled) -eq $false) 'flag routing_telemetry OFF'
  Assert (([bool]$flags.capability_reconciler.enabled) -eq $false) 'flag capability_reconciler OFF'
  Assert (([bool]$flags.runtime_grant_enforcement.v1) -eq $false) 'flag runtime_grant_enforcement.v1 OFF'
  Assert (([bool]$flags.runtime_grant_enforcement.v2) -eq $false) 'flag runtime_grant_enforcement.v2 OFF'
} catch { Assert $false 'flags parseiam e estao OFF' $_.Exception.Message }

# --- 2F: historico 2E intacto (pins + metricas do ledger) ---
try {
  $ledger = ([IO.File]::ReadAllText($ledger2ePath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (([string]$ledger.resolver_version) -ceq '2d-shadow-1') 'ledger 2E pins resolver_version 2d-shadow-1'
  Assert (([string]$ledger.mode) -ceq 'shadow') 'ledger 2E mode shadow'
  Assert ((@($ledger.pilots)).Count -eq 13) 'ledger 2E tem 13 pilots'
  Assert ([int]$ledger.metrics.agent_agreement.agree_count -eq 9) 'ledger 2E agent agreement 9/13 (before)'
  Assert ([int]$ledger.metrics.profile_agreement.agree_count -eq 11) 'ledger 2E profile agreement 11/13 (before)'
  Assert ([int]$ledger.metrics.over_activation -eq 0) 'ledger 2E over-activation 0'
  Assert ([int]$ledger.metrics.under_activation_unsafe -eq 0) 'ledger 2E under-activation unsafe 0'
  Assert ([int]$ledger.metrics.critical_routing_mistakes -eq 0) 'ledger 2E critical routing mistakes 0'
  Assert ([int]$ledger.metrics.unsafe_capability_activation -eq 0) 'ledger 2E unsafe capability activation 0'
} catch { Assert $false 'ledger 2E intacto' $_.Exception.Message }
$stored2e = @{}
foreach ($rid in @('2E-P1-DOCS','2E-P2-RESEARCH','2E-P3-DEBUG','2E-P4-FRONTEND','2E-P5-BACKEND','2E-P6-TRIVIAL','2E-P7-DB','2E-P8-E2E','2E-P9-RUNTIME','2E-P10-PERF','2E-P11-DOCS2','2E-P12-REVIEW','2E-P13-CSS')) {
  $f = Join-Path $ev2eDir ('resolver-' + $rid + '.json')
  $ok = $false
  try {
    $doc = ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    if (($null -ne $doc) -and (([string]$doc.resolver_version) -ceq '2d-shadow-1') -and (([string]$doc.mode) -ceq 'shadow')) {
      $stored2e[$rid] = $doc
      $ok = $true
    }
  } catch { $ok = $false }
  Assert $ok ('historico 2E intacto: ' + $rid)
}

# --- corpus 2F: forma ---
$cases = @()
if ($null -ne $corpus) {
  Assert (([int]$corpus.version) -eq 1) 'corpus 2F version == 1'
  $cases = @($corpus.cases)
  Assert ($cases.Count -ge 30) 'corpus 2F >= 30 casos' ('obtido: ' + $cases.Count)
  $ids = @($cases | ForEach-Object { [string]$_.id })
  Assert ((@($ids | Sort-Object -Unique)).Count -eq $cases.Count) 'corpus 2F ids unicos'
  $fx = @($cases | Where-Object { [string]$_.origin -ceq 'fixture' }).Count
  $rl = @($cases | Where-Object { [string]$_.origin -ceq 'real' }).Count
  Assert ($fx -ge 30) 'corpus 2F fixture >= 30' ('obtido: ' + $fx)
  Assert ($rl -eq 13) 'corpus 2F real == 13 (replay 2E)' ('obtido: ' + $rl)
  Assert ((@($corpus.coverage.not_run)).Count -ge 1) 'corpus 2F declara NOT RUN (FIXTURE vs REAL vs NOT RUN)'
  $gabBad = New-Object System.Collections.ArrayList
  foreach ($c in $cases) {
    if (@('operator-criteria', 'parity-2d', 'planner-2e') -cnotcontains [string]$c.gabarito) { [void]$gabBad.Add(([string]$c.id + ': gabarito invalido')) }
    if ($null -eq $c.expected) { [void]$gabBad.Add(([string]$c.id + ': sem expected')) }
    if ($null -eq $c.not_expected) { [void]$gabBad.Add(([string]$c.id + ': sem not_expected')) }
    if (@('empty', 'supabase') -cnotcontains [string]$c.fixture) { [void]$gabBad.Add(([string]$c.id + ': fixture invalida')) }
  }
  Assert ($gabBad.Count -eq 0) 'corpus 2F casos com gabarito/fixture/expected/not_expected' ($gabBad -join ' | ')
}

# --- 2D-corpus como referencia de paridade ---
$corpus2d = $null
try { $corpus2d = ([IO.File]::ReadAllText($corpus2dPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $corpus2d = $null }
Assert ($null -ne $corpus2d) 'corpus 2D legivel (referencia de paridade)'

try { . $libPath } catch { Assert $false 'lib CapabilityResolver.ps1 carrega (dot-source)' $_.Exception.Message }

$tempBase = $env:TEMP
if ([string]::IsNullOrWhiteSpace($tempBase)) { $tempBase = Join-Path $RepoRoot 'cache\v3' }
$fxEmpty = Join-Path $tempBase 'phase2f-fx-empty'
$fxSupabase = Join-Path $tempBase 'phase2f-fx-supabase'
foreach ($d in @($fxEmpty, $fxSupabase)) {
  if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $d -Force | Out-Null
}
[IO.File]::WriteAllText((Join-Path $fxSupabase 'package.json'), '{"name":"fx-supabase-2f"}', [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $fxSupabase 'supabase') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $fxSupabase 'supabase') 'config.toml'), '[project]', [Text.UTF8Encoding]::new($false))
$fxSupaMig = Join-Path (Join-Path $fxSupabase 'supabase') 'migrations'
New-Item -ItemType Directory -Path $fxSupaMig -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $fxSupaMig '0001_init.sql'), 'create table t (id int);', [Text.UTF8Encoding]::new($false))

$fxMap = @{ 'empty' = $fxEmpty; 'supabase' = $fxSupabase }
$resolved = @{}
$compTotal = 0
$compHit = 0
$failedCases = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
  $caseFailBefore = $fail
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
  Assert ((Get-SortedKey @($r.agents)) -ceq (Get-SortedKey @($c.expected.agents))) ([string]$c.id + ' agents igualdade exata') ('obtido: ' + (Get-SortedKey @($r.agents)))
  Assert ((Get-SortedKey @($r.profiles)) -ceq (Get-SortedKey @($c.expected.profiles))) ([string]$c.id + ' profiles igualdade exata') ('obtido: ' + (Get-SortedKey @($r.profiles)))
  Assert ((Get-SortedKey @($r.mcps)) -ceq (Get-SortedKey @($c.expected.mcps))) ([string]$c.id + ' mcps igualdade exata') ('obtido: ' + (Get-SortedKey @($r.mcps)))
  Assert ((Get-SortedKey @($r.skills)) -ceq (Get-SortedKey @($c.expected.skills))) ([string]$c.id + ' skills igualdade exata') ('obtido: ' + (Get-SortedKey @($r.skills)))
  Assert (([string]$r.risk.level) -ceq [string]$c.expected.risk) ([string]$c.id + ' risk == ' + [string]$c.expected.risk) ('obtido: ' + [string]$r.risk.level)
  Assert (([string]$r.confidence) -ceq [string]$c.expected.confidence) ([string]$c.id + ' confidence == ' + [string]$c.expected.confidence) ('obtido: ' + [string]$r.confidence)
  if ($null -ne $c.expected.perm) {
    Assert (([string]$r.permissions.recommendation) -ceq [string]$c.expected.perm) ([string]$c.id + ' perm == ' + [string]$c.expected.perm) ('obtido: ' + [string]$r.permissions.recommendation)
  }
  try {
    if ($null -ne $c.expected.pilot_profiles) {
      Assert ((Get-SortedKey @($r.pilot_profiles)) -ceq (Get-SortedKey @($c.expected.pilot_profiles))) ([string]$c.id + ' pilot_profiles igualdade exata') ('obtido: ' + (Get-SortedKey @($r.pilot_profiles)))
    }
  } catch { }
  $badP = Get-Forbidden @($r.profiles) @($c.not_expected.profiles)
  $badM = Get-Forbidden @($r.mcps) @($c.not_expected.mcps)
  $badC = Get-Forbidden @($r.capabilities) @($c.not_expected.caps)
  $badAll = ($badP + '|' + $badM + '|' + $badC).Trim('|')
  $noneBad = [string]::IsNullOrWhiteSpace($badAll.Replace('|', ''))
  Assert ($noneBad) ([string]$c.id + ' nada do not_expected ativo') ('achado: ' + $badAll)
  # comparables: acordo live vs gabarito (metrica >=90%; ver plano: nao e claim produtivo)
  $ct = [string]$c.comparable_to
  if ($ct -match '^(2E-|2D-)') {
    $compTotal += 1
    $hit = ((Get-SortedKey @($r.agents)) -ceq (Get-SortedKey @($c.expected.agents))) -and (([string]$r.risk.level) -ceq [string]$c.expected.risk)
    if ($hit) { $compHit += 1 }
  }
  # auto-check de paridade contra historia congelada (gabarito independente)
  if ($ct -like '2E-stored:*') {
    $rid = (($ct.Substring(10) -replace '^resolver-', '') -replace '\.json$', '')
    if ($stored2e.ContainsKey($rid)) {
      $s = $stored2e[$rid]
      Assert ((Get-SortedKey @($s.agents_selected)) -ceq (Get-SortedKey @($c.expected.agents))) ([string]$c.id + ' paridade 2E-stored agents ' + $rid) ('gabarito diverge do historico')
      Assert ((Get-SortedKey @($s.profiles_selected)) -ceq (Get-SortedKey @($c.expected.profiles))) ([string]$c.id + ' paridade 2E-stored profiles ' + $rid) ('gabarito diverge do historico')
      Assert ((Get-SortedKey @($s.mcps_selected)) -ceq (Get-SortedKey @($c.expected.mcps))) ([string]$c.id + ' paridade 2E-stored mcps ' + $rid) ('gabarito diverge do historico')
      Assert ((Get-SortedKey @($s.skills_selected)) -ceq (Get-SortedKey @($c.expected.skills))) ([string]$c.id + ' paridade 2E-stored skills ' + $rid) ('gabarito diverge do historico')
      Assert (([string]$s.risk) -ceq [string]$c.expected.risk) ([string]$c.id + ' paridade 2E-stored risk ' + $rid) ('gabarito diverge do historico')
      Assert (([string]$s.confidence) -ceq [string]$c.expected.confidence) ([string]$c.id + ' paridade 2E-stored confidence ' + $rid) ('gabarito diverge do historico')
    }
    else { Assert $false ([string]$c.id + ' referencia 2E-stored existe') $rid }
  }
  if (($ct -like '2D-corpus:*') -and ($null -ne $corpus2d)) {
    $cid = $ct.Substring(10)
    $ref = @(@($corpus2d.cases) | Where-Object { [string]$_.id -ceq $cid })
    Assert ($ref.Count -eq 1) ([string]$c.id + ' referencia 2D-corpus existe: ' + $cid)
    if ($ref.Count -eq 1) {
      Assert ((Get-SortedKey @($ref[0].expected.agents)) -ceq (Get-SortedKey @($c.expected.agents))) ([string]$c.id + ' paridade 2D-corpus agents ' + $cid) ('gabarito diverge do congelado')
      Assert ((Get-SortedKey @($ref[0].expected.profiles)) -ceq (Get-SortedKey @($c.expected.profiles))) ([string]$c.id + ' paridade 2D-corpus profiles ' + $cid) ('gabarito diverge do congelado')
      Assert ((Get-SortedKey @($ref[0].expected.mcps)) -ceq (Get-SortedKey @($c.expected.mcps))) ([string]$c.id + ' paridade 2D-corpus mcps ' + $cid) ('gabarito diverge do congelado')
      Assert ((Get-SortedKey @($ref[0].expected.skills)) -ceq (Get-SortedKey @($c.expected.skills))) ([string]$c.id + ' paridade 2D-corpus skills ' + $cid) ('gabarito diverge do congelado')
      Assert (([string]$ref[0].expected.risk) -ceq [string]$c.expected.risk) ([string]$c.id + ' paridade 2D-corpus risk ' + $cid) ('gabarito diverge do congelado')
      Assert (([string]$ref[0].expected.confidence) -ceq [string]$c.expected.confidence) ([string]$c.id + ' paridade 2D-corpus confidence ' + $cid) ('gabarito diverge do congelado')
    }
  }
  if ($fail -gt $caseFailBefore) { [void]$failedCases.Add([string]$c.id) }
}

# --- 2F: nenhum stripe-mcp em nenhum caso; skills so ACTIVE ---
$catActive = @()
try {
  $catDoc = ([IO.File]::ReadAllText((Join-Path $RepoRoot 'source\registry\skills-catalog.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $catActive = @($catDoc.skills | Where-Object { ([string]$_.status) -ceq 'ACTIVE' } | ForEach-Object { ([string]$_.id).Trim().ToLowerInvariant() })
} catch { $catActive = @() }
Assert ($catActive.Count -gt 0) 'catalogo skills ACTIVE nao vazio'
foreach ($cid in @($resolved.Keys)) {
  $r = $resolved[$cid]
  Assert ((@($r.mcps) -cnotcontains 'stripe-mcp')) ($cid + ' sem stripe-mcp')
  $badSk = @(@($r.skills) | Where-Object { $catActive -cnotcontains ([string]$_).Trim().ToLowerInvariant() })
  Assert ($badSk.Count -eq 0) ('skills ACTIVE no catalogo: ' + $cid) ($badSk -join ',')
}

# --- 2F: seguranca focal: fin-doc LOW+allow vs exec CRITICAL+deny; logs LOW vs deploy HIGH+deny ---
function Get-R($Id) { return $resolved[$Id] }
if ($resolved.ContainsKey('F10-document-stripe-refund-procedure')) {
  $x = Get-R 'F10-document-stripe-refund-procedure'
  Assert ((([string]$x.risk.level) -ceq 'LOW') -and (([string]$x.permissions.recommendation) -ceq 'allow')) 'fin documental LOW + allow'
}
foreach ($fid in @('F13-execute-customer-refund', 'F14-refund-customer-payment', 'F30-process-stripe-payout')) {
  if ($resolved.ContainsKey($fid)) {
    $x = Get-R $fid
    Assert ((([string]$x.risk.level) -ceq 'CRITICAL') -and (([string]$x.permissions.recommendation) -ceq 'deny')) ($fid + ' CRITICAL + deny')
  }
}
if ($resolved.ContainsKey('F12-read-production-deployment-logs')) {
  $x = Get-R 'F12-read-production-deployment-logs'
  Assert ((([string]$x.risk.level) -ceq 'LOW') -and (([string]$x.permissions.recommendation) -ceq 'allow')) 'prod-logs LOW + allow'
  Assert ((@($x.reason_codes) -cnotcontains 'RISK_PRODUCTION_WRITE')) 'prod-logs sem RISK_PRODUCTION_WRITE'
}
foreach ($fid in @('F15-deploy-production-release', 'F16-delete-production-database')) {
  if ($resolved.ContainsKey($fid)) {
    $x = Get-R $fid
    Assert ((([string]$x.permissions.recommendation) -ceq 'deny')) ($fid + ' deny (protegido)')
    Assert ((@($x.reason_codes) -ccontains 'RISK_PRODUCTION_WRITE')) ($fid + ' com RISK_PRODUCTION_WRITE')
  }
}
# --- 2F-FIX: tarefas mistas (expectativa propria, casos independentes) ---
# Producao mista: a excecao de leitura de logs vale so para leitura exclusiva;
# com verbo de mutacao exato (deploy/delete/...) => HIGH + deny + RISK_PRODUCTION_WRITE.
# 2F-FIX-DEBUGGER-R5R6: R6 ('remove production database and read production
# logs') => HIGH + deny + RISK_PRODUCTION_WRITE. 'remove' nao precisa entrar
# em blocklist: a excecao logs-read agora exige FORMA TEXTUAL FECHADA (todo
# token do texto = verbo de leitura / descritor / 'logs' / filler), e
# 'remove'+'database' quebram a forma. Ver plano 10.3.
$prodMixed = @(
  @{ task = 'delete production database and read production logs'; task_class = 'migration' },
  @{ task = 'deploy production release and read deployment logs'; task_class = 'implementation' },
  @{ task = 'read production logs and deploy production'; task_class = 'implementation' },
  @{ task = 'deploying production release and read deployment logs'; task_class = 'implementation' },
  @{ task = 'truncate production database and read production logs'; task_class = 'migration' },
  @{ task = 'trigger production deployment'; task_class = 'implementation' },
  @{ task = 'remove production database and read production logs'; task_class = 'implementation' }
)
foreach ($m in $prodMixed) {
  $mr = $null
  try { $mr = Invoke-CapabilityResolve -TaskInput @{ task = [string]$m.task; task_class = [string]$m.task_class; project = @{ stack = ''; }; projectRoot = $fxEmpty } } catch { $mr = $null }
  Assert ($null -ne $mr) ('mista producao resolve: ' + [string]$m.task)
  if ($null -ne $mr) {
    Assert (([string]$mr.risk.level) -ceq 'HIGH') ('mista producao HIGH: ' + [string]$m.task) ('obtido: ' + [string]$mr.risk.level)
    Assert (([string]$mr.permissions.recommendation) -ceq 'deny') ('mista producao deny: ' + [string]$m.task) ('obtido: ' + [string]$mr.permissions.recommendation)
    Assert ((@($mr.reason_codes) -ccontains 'RISK_PRODUCTION_WRITE')) ('mista producao RISK_PRODUCTION_WRITE: ' + [string]$m.task) ('obtido: ' + (@($mr.reason_codes) -join ','))
  }
}
# Financeira mista: a excecao documental vale so para intencao exclusivamente
# documental (verbo documental proprio em TODA clausula com mencao financeira,
# sem verbo de execucao em qualquer posicao e sem alvo operacional incl.
# order); caso contrario CRITICAL + deny (mista ou incerta => conservador).
# 2F-FIX-DEBUGGER-R5R6: R5 ('document procedure and execute Stripe refund')
# e vetado pelo verbo de execucao 'execute' em qualquer posicao; R5b
# ('document procedure and refund') porque a clausula apos 'and' tem mencao
# financeira sem verbo documental proprio ('procedure' e substantivo). Ver
# plano 10.3.
$finMixed = @(
  @{ task = 'refund customer payment following the procedure'; task_class = 'implementation' },
  @{ task = 'refund customer payment and document procedure'; task_class = 'implementation' },
  @{ task = 'refund following the procedure'; task_class = 'implementation' },
  @{ task = 'refund order 123 and document procedure'; task_class = 'implementation' },
  @{ task = 'document procedure and refund customer payment'; task_class = 'implementation' },
  @{ task = 'document procedure and execute Stripe refund'; task_class = 'implementation' },
  @{ task = 'document procedure and refund'; task_class = 'implementation' }
)
foreach ($m in $finMixed) {
  $mr = $null
  try { $mr = Invoke-CapabilityResolve -TaskInput @{ task = [string]$m.task; task_class = [string]$m.task_class; project = @{ stack = ''; }; projectRoot = $fxEmpty } } catch { $mr = $null }
  Assert ($null -ne $mr) ('mista financeira resolve: ' + [string]$m.task)
  if ($null -ne $mr) {
    Assert (([string]$mr.risk.level) -ceq 'CRITICAL') ('mista financeira CRITICAL: ' + [string]$m.task) ('obtido: ' + [string]$mr.risk.level)
    Assert (([string]$mr.permissions.recommendation) -ceq 'deny') ('mista financeira deny: ' + [string]$m.task) ('obtido: ' + [string]$mr.permissions.recommendation)
  }
}
# --- 2F-FIX-CLAUSE-SEPARATORS: fronteira de clausulas da excecao documental ---
# Separadores ampliados ('and'/'then'/';' + '.', ',', ':', '!?', 'but',
# quebra de linha). Clausula vazia pos-split e ignorada: ponto final isolado
# nao cria clausula. FRONTEIRA (plano 10.4): excecao documental so em
# clausula UNICA com mencao financeira + verbo documental proprio + sem
# exec-veto + sem alvo operacional; mencao financeira distribuida em 2+
# clausulas nao-vazias => CRITICAL + deny (conservador). 'or'/'with' ficam
# FORA dos separadores (residual documentado).
$finClauseSep = @(
  @{ name = 'ponto separa: refund sem verbo documental proprio'; task = 'document procedure. refund'; task_class = 'implementation'; risk = 'CRITICAL'; perm = 'deny' },
  @{ name = 'virgula separa: refund sem verbo documental proprio'; task = 'document procedure, refund'; task_class = 'implementation'; risk = 'CRITICAL'; perm = 'deny' },
  @{ name = 'ponto final isolado nao cria clausula: excecao LOW preservada'; task = 'document Stripe refund procedure.'; task_class = 'implementation'; risk = 'LOW'; perm = 'allow' }
)
foreach ($m in $finClauseSep) {
  $mr = $null
  try { $mr = Invoke-CapabilityResolve -TaskInput @{ task = [string]$m.task; task_class = [string]$m.task_class; project = @{ stack = ''; }; projectRoot = $fxEmpty } } catch { $mr = $null }
  Assert ($null -ne $mr) ('fronteira clausulas resolve: ' + [string]$m.name)
  if ($null -ne $mr) {
    Assert (([string]$mr.risk.level) -ceq [string]$m.risk) ('fronteira clausulas risk ' + [string]$m.risk + ': ' + [string]$m.name) ('obtido: ' + [string]$mr.risk.level)
    Assert (([string]$mr.permissions.recommendation) -ceq [string]$m.perm) ('fronteira clausulas perm ' + [string]$m.perm + ': ' + [string]$m.name) ('obtido: ' + [string]$mr.permissions.recommendation)
  }
}
# --- 2F-FIX-DEBUGGER-R5R6: descontaminacao por metadados ---
# Sinais de risco (isFinancial/isProd e as excecoes doc/logs-read) vem do
# TEXTO DA TAREFA. task_class/stack (metadata) nao podem fornecer sinais que
# REBAIXEM risco; risk_context explicito pode continuar ELEVANDO (OR).
$riskContam = @(
  @{ name = 'fin: task_class documental nao cria excecao'; task = 'refund customer payment'; task_class = 'document procedure'; stack = 'stripe'; risk_ctx = ''; risk = 'CRITICAL'; perm = 'deny'; prod = $false },
  @{ name = 'fin: verbo de execucao no texto vence task_class'; task = 'execute Stripe refund'; task_class = 'documentation'; stack = ''; risk_ctx = ''; risk = 'CRITICAL'; perm = 'deny'; prod = $false },
  @{ name = 'fin: task_class documentation nao rebaixa R5'; task = 'document procedure and execute Stripe refund'; task_class = 'documentation'; stack = ''; risk_ctx = ''; risk = 'CRITICAL'; perm = 'deny'; prod = $false },
  @{ name = 'prod: metadata nao rebaixa R6'; task = 'remove production database and read production logs'; task_class = 'documentation'; stack = 'supabase'; risk_ctx = ''; risk = 'HIGH'; perm = 'deny'; prod = $true },
  @{ name = 'prod: R6 com task_class neutra'; task = 'remove production database and read production logs'; task_class = 'analysis'; stack = ''; risk_ctx = ''; risk = 'HIGH'; perm = 'deny'; prod = $true },
  @{ name = 'fin: risk_context explicito eleva (OR)'; task = 'rename local helper variable'; task_class = 'trivial'; stack = ''; risk_ctx = 'financial stripe payout'; risk = 'CRITICAL'; perm = 'deny'; prod = $false },
  @{ name = 'prod: risk_context explicito eleva (OR)'; task = 'rename local helper variable'; task_class = 'trivial'; stack = ''; risk_ctx = 'production deploy pending'; risk = 'HIGH'; perm = 'deny'; prod = $true },
  @{ name = 'metadata neutro: sem mencao no texto segue LOW'; task = 'rename local helper variable'; task_class = 'documentation'; stack = 'stripe'; risk_ctx = ''; risk = 'LOW'; perm = 'allow'; prod = $false },
  @{ name = 'logs-read: forma fechada no texto sobrevive a metadata'; task = 'read production logs'; task_class = 'implementation'; stack = 'supabase'; risk_ctx = ''; risk = 'LOW'; perm = 'allow'; prod = $false }
)
foreach ($m in $riskContam) {
  $mr = $null
  $in = @{ task = [string]$m.task; task_class = [string]$m.task_class; project = @{ stack = [string]$m.stack }; projectRoot = $fxEmpty }
  if (-not [string]::IsNullOrWhiteSpace([string]$m.risk_ctx)) { $in.risk_context = [string]$m.risk_ctx }
  try { $mr = Invoke-CapabilityResolve -TaskInput $in } catch { $mr = $null }
  Assert ($null -ne $mr) ('contaminacao resolve: ' + [string]$m.name)
  if ($null -ne $mr) {
    Assert (([string]$mr.risk.level) -ceq [string]$m.risk) ('contaminacao risk ' + [string]$m.risk + ': ' + [string]$m.name) ('obtido: ' + [string]$mr.risk.level)
    Assert (([string]$mr.permissions.recommendation) -ceq [string]$m.perm) ('contaminacao perm ' + [string]$m.perm + ': ' + [string]$m.name) ('obtido: ' + [string]$mr.permissions.recommendation)
    if ([bool]$m.prod) {
      Assert ((@($mr.reason_codes) -ccontains 'RISK_PRODUCTION_WRITE')) ('contaminacao RISK_PRODUCTION_WRITE: ' + [string]$m.name) ('obtido: ' + (@($mr.reason_codes) -join ','))
    }
  }
}
# browser contido: F17/F19/F09 sem playwright/devtools
foreach ($fid in @('F17-read-css-layout', 'F19-rename-variable', 'F09-write-readme', 'F01-write-setup-guide')) {
  if ($resolved.ContainsKey($fid)) {
    $x = Get-R $fid
    Assert (((@($x.mcps) -cnotcontains 'playwright-mcp') -and (@($x.mcps) -cnotcontains 'chrome-devtools-mcp'))) ($fid + ' sem browser MCP')
  }
}

# --- determinismo + fail-safe ---
$detA = $null; $detB = $null
try {
  $detInput = @{ task = 'test browser checkout flow'; task_class = 'testing'; project = @{ stack = '' }; projectRoot = $fxEmpty }
  $detA = Invoke-CapabilityResolve -TaskInput $detInput | ConvertTo-Json -Depth 8 -Compress
  $detB = Invoke-CapabilityResolve -TaskInput $detInput | ConvertTo-Json -Depth 8 -Compress
} catch { }
Assert ((-not [string]::IsNullOrWhiteSpace($detA)) -and ($detA -ceq $detB)) 'determinismo: mesma entrada 2x -> JSON identico'
$fs = $null; $fsThrew = $false
try { $fs = Invoke-CapabilityResolve -TaskInput @{ task = 'anything'; task_class = 'migration' } -RoutingPath (Join-Path $tempBase 'phase2f-no-such-routing.json') }
catch { $fsThrew = $true }
Assert ((-not $fsThrew) -and ($null -ne $fs)) 'fail-safe registry retorna sem throw'
if ($null -ne $fs) {
  Assert ((@($fs.agents) -join '|') -ceq 'coder') 'fail-safe agents == coder'
  Assert (([string]$fs.risk.level) -ceq 'MEDIUM') 'fail-safe risk MEDIUM'
  Assert (([string]$fs.mode) -ceq 'shadow') 'fail-safe mode shadow'
}

# --- comparables >= 90% (sem claim produtivo) ---
$compRate = 0
if ($compTotal -gt 0) { $compRate = $compHit / $compTotal }
Assert ($compTotal -ge 19) 'comparables >= 19' ('obtido: ' + $compTotal)
Assert ($compRate -ge 0.9) 'comparables agreement >= 90%' (('obtido: ' + $compHit + '/' + $compTotal))

# --- aprovacao por caso: nenhum caso do corpus pode ter FAIL ---
Assert ($failedCases.Count -eq 0) 'aprovacao por caso: todos os casos do corpus verdes' ('casos com FAIL: ' + ($failedCases -join ','))

# --- artefatos 2F (LOW metrics FIX: so grava evidence quando verde) ---
# Se houver qualquer FAIL, NAO grava results/metrics (sem aparencia de
# sucesso) e o exit final != 0. Evidence anterior preservada (nao apagada).
$preArtifactFail = $fail
if ($preArtifactFail -eq 0) {
$resArr = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
  $r = $resolved[[string]$c.id]
  if ($null -eq $r) { continue }
  [void]$resArr.Add([PSCustomObject]@{
    case_id = [string]$c.id
    origin = [string]$c.origin
    comparable_to = [string]$c.comparable_to
    task = [string]$c.task
    task_class = [string]$c.task_class
    agents = @($r.agents)
    profiles = @($r.profiles)
    pilot_profiles = @($r.pilot_profiles)
    mcps = @($r.mcps)
    skills = @($r.skills)
    capabilities = @($r.capabilities)
    risk = [string]$r.risk.level
    perm = [string]$r.permissions.recommendation
    reason_codes = @($r.reason_codes)
    fallbacks = @($r.fallbacks)
    confidence = [string]$r.confidence
    mode = [string]$r.mode
  })
}
$resDoc = [PSCustomObject]@{
  version = 1
  generated = '2026-10-08'
  resolver_version = '2d-shadow-1'
  mode = 'shadow'
  note = 'generated by scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1 over shadow-corpus-2026-10-08.json; shadow only, no activation'
  count = $resArr.Count
  results = @($resArr)
}
[IO.File]::WriteAllText($resultsPath, ($resDoc | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
Assert (Test-Path -LiteralPath $resultsPath -PathType Leaf) 'results shadow-results-2026-10-08.json gravado'
$metDoc = [PSCustomObject]@{
  version = 1
  generated = '2026-10-08'
  mode = 'shadow'
  before = [PSCustomObject]@{
    source = 'evidence/capabilities-phase-2e/real-world-pilots-2026-10-07.json (frozen 2E ledger)'
    agent_agreement = '9/13'
    profile_agreement = '11/13'
    over_activation = 0
    under_activation_unsafe = 0
    critical_routing_mistakes = 0
  }
  after = [PSCustomObject]@{
    replay_2e_corrected = '13/13 (9 preserved via 2E-stored parity + 4 corrected to 2E planner: P1/P11 docs-manager, P3 debugger, P12 reviewer)'
    corpus_2f = ([string]$resArr.Count + '/' + [string]$cases.Count)
    comparables = ([string]$compHit + '/' + [string]$compTotal)
    regression_2d = 'via tests/distribution/capability-routing-phase2d.tests.ps1 (must stay green; run separately)'
  }
  flags = 'routing flags OFF unchanged (capability_router.active/shadow, skill_routing, mcp_routing, adaptive_ranking, routing_telemetry, capability_reconciler, runtime_grant_enforcement.v1/v2)'
  stability = 'NOT a production-stability claim: small sample (43 cases + 13 pilots); Active promotion remains an operator decision with more real data (CONTINUE_ADVISORY)'
}
[IO.File]::WriteAllText($metricsPath, ($metDoc | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
Assert (Test-Path -LiteralPath $metricsPath -PathType Leaf) 'metrics metrics-2026-10-08.json gravado'
}
else {
  Write-Host 'NOT OK - evidence nao gravada (FAIL>0; metrics com aparencia de sucesso suprimidas)'
}

Remove-Item -LiteralPath $fxEmpty -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $fxSupabase -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
