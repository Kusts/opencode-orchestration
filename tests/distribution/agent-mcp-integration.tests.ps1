<#!
.SYNOPSIS
    Suite estatica da integracao testing-profile x tester/debugger (sem modelo, sem rede).
.DESCRIPTION
    Valida a fixture local (ASCII, zero recursos externos, elementos),
    a presenca da secao de uso pelos agentes em docs/mcp-profiles.md,
    a lane (scripts/ci/agent-mcp-integration-lane-v2.ps1) com params
    obrigatorios, os pontos de guarda do registry (testing APPROVED;
    mcp_routing/capability_router.active/skill_routing/adaptive_ranking OFF),
    os templates tester/debugger ainda mode=subagent e a ausencia de
    literais de segredo nos arquivos novos. Somente leitura; PS 5.1 compativel.
    Estilo distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
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
$fixturePath = Join-Path $RepoRoot 'tests\distribution\agent-mcp-integration-fixture\index.html'
$lanePath = Join-Path $RepoRoot 'scripts\ci\agent-mcp-integration-lane-v2.ps1'
$errorPath = Join-Path $RepoRoot 'tests\distribution\agent-mcp-integration-fixture\error.html'
$profPath = Join-Path $RepoRoot 'source\registry\mcp-profiles.json'
$flagsPath = Join-Path $RepoRoot 'source\registry\capability-flags.json'
$tmplV2Path = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'
$tmplV1Path = Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl'
$docsPath = Join-Path $RepoRoot 'docs\mcp-profiles.md'
$suitePath = Join-Path $RepoRoot 'tests\distribution\agent-mcp-integration.tests.ps1'

# --- Fixture: existe + ASCII + sem recursos externos ---
Assert (Test-Path -LiteralPath $fixturePath -PathType Leaf) 'fixture index.html existe'

$fixBytes = $null
$fixText = ''
if (Test-Path -LiteralPath $fixturePath -PathType Leaf) {
  $fixBytes = [IO.File]::ReadAllBytes($fixturePath)
  $fixText = [Text.Encoding]::UTF8.GetString($fixBytes)
  $nonAscii = @($fixBytes | Where-Object { $_ -gt 127 })
  Assert ($nonAscii.Count -eq 0) 'fixture ASCII-only' ('bytes>127=' + $nonAscii.Count)
  Assert (($fixText -notmatch 'https?://') -and ($fixText -notmatch '(?i)\bcdn\b')) 'fixture sem recursos externos (sem http, sem CDN)'
  Assert ($fixText -notmatch '(?i)\bfetch\s*\(') 'fixture sem fetch externo'
  Assert ($fixText -match '<h1>Agent MCP Integration Fixture</h1>') 'fixture h1 com titulo fixo'
  Assert (($fixText -match '<span id="count">') -and ($fixText -match '<button id="count-btn"')) 'fixture botao contador + span#count'
  Assert (($fixText -match '<form') -and ($fixText -match 'id="echo-input"') -and ($fixText -match '<div id="echo"')) 'fixture form texto com echo em div#echo'
  Assert (($fixText -match "console\.error\('FIXTURE-ERROR-42'\)") -and ($fixText -match "console\.warn\('FIXTURE-WARN-7'\)")) 'fixture emite FIXTURE-ERROR-42 + FIXTURE-WARN-7'
  $anchors = ([regex]::Matches($fixText, 'href="#')).Count
  Assert (($anchors -ge 3) -and ($fixText -notmatch 'href="https?://')) 'fixture lista de 3 links ancora internos' ('anchors=' + $anchors)
  $hasSrcScript = $fixText -match '<script[^>]+src='
  $jsLines = 999
  $m = [regex]::Match($fixText, '(?s)<script>(.*?)</script>')
  if ($m.Success) {
    $jsLines = @($m.Groups[1].Value -split "`r?`n").Count
  }
  Assert ((-not $hasSrcScript) -and ($m.Success) -and ($jsLines -lt 60)) 'fixture JS inline < 60 linhas, sem dependencias' ('linhas=' + $jsLines)
}
else {
  Assert $false 'fixture ASCII-only' 'arquivo ausente'
  Assert $false 'fixture sem recursos externos (sem http, sem CDN)' 'arquivo ausente'
  Assert $false 'fixture sem fetch externo' 'arquivo ausente'
  Assert $false 'fixture h1 com titulo fixo' 'arquivo ausente'
  Assert $false 'fixture botao contador + span#count' 'arquivo ausente'
  Assert $false 'fixture form texto com echo em div#echo' 'arquivo ausente'
  Assert $false 'fixture emite FIXTURE-ERROR-42 + FIXTURE-WARN-7' 'arquivo ausente'
  Assert $false 'fixture lista de 3 links ancora internos' 'arquivo ausente'
  Assert $false 'fixture JS inline < 60 linhas, sem dependencias' 'arquivo ausente'
}

# --- Fixture error.html: existe + ASCII + marcador + console.error + sem externos ---
Assert (Test-Path -LiteralPath $errorPath -PathType Leaf) 'fixture error.html existe'
if (Test-Path -LiteralPath $errorPath -PathType Leaf) {
  $errBytes = [IO.File]::ReadAllBytes($errorPath)
  $errText = [Text.Encoding]::UTF8.GetString($errBytes)
  $errNonAscii = @($errBytes | Where-Object { $_ -gt 127 })
  Assert (@($errNonAscii).Count -eq 0) 'fixture error.html ASCII-only'
  Assert (($errText -match 'FIXTURE-ERROR-42') -and ($errText -match 'id="emarker"')) 'fixture error.html marcador FIXTURE-ERROR-42'
  Assert ($errText -match 'console\.error') 'fixture error.html emite console.error'
  Assert (($errText -notmatch 'https?://') -and ($errText -notmatch '<script[^>]+src=')) 'fixture error.html sem recursos externos'
}
else {
  Assert $false 'fixture error.html ASCII-only' 'arquivo ausente'
  Assert $false 'fixture error.html marcador FIXTURE-ERROR-42' 'arquivo ausente'
  Assert $false 'fixture error.html emite console.error' 'arquivo ausente'
  Assert $false 'fixture error.html sem recursos externos' 'arquivo ausente'
}

# --- Lane: existe com params obrigatorios ---
Assert (Test-Path -LiteralPath $lanePath -PathType Leaf) 'lane script existe'
if (Test-Path -LiteralPath $lanePath -PathType Leaf) {
  $laneText = [IO.File]::ReadAllText($lanePath, [Text.Encoding]::UTF8)
  Assert (($laneText -match '(?m)^\s*param\s*\(') -and ($laneText -match '\$ScenarioFilter') -and ($laneText -match '\$ModelKeyEnvName') -and ($laneText -match '\$EvidenceDir') -and ($laneText -match '\$FixtureDir') -and ($laneText -match '\$CheapModel') -and ($laneText -match '\$StrongModel') -and ($laneText -match '\$BinaryPath')) 'lane com params de contrato'
  Assert (($laneText -match 'function Add-LaneServeAuth') -and ($laneText -match 'OPENCODE_PASSWORD') -and ($laneText -match 'function Wait-LaneMcpNames') -and ($laneText -match 'function Get-LaneChildAgents')) 'lane com auth de serve + espera MCP + child sessions'
  Assert ((@([regex]::Matches($laneText, "-Agent 'build'")).Count -ge 2) -and ($laneText -match "'--agent', 'build'") -and ($laneText -notmatch "-Agent 'tester'") -and ($laneText -notmatch "-Agent 'debugger'") -and ($laneText -notmatch "'--agent', 'tester'") -and ($laneText -notmatch "'--agent', 'debugger'")) 'lane invoca via build (subagents nao sao primary)'
  Assert (($laneText -match 'Delegate to the tester') -and ($laneText -match 'Delegate to the debugger')) 'lane delega a tester/debugger via Planner'
  Assert (($laneText -match 'browser_run_code_unsafe') -and ($laneText -match "'deny'") -and ($laneText -match 'evaluate_script') -and ($laneText -match 'run_code_unsafe')) 'lane materializa restricoes MCP + scan de proibidas'
  Assert (($laneText -match 'FixtureDir incompativel') -and ($laneText -match 'id="count-btn"')) 'lane valida contrato da FixtureDir'
  Assert (($laneText -match 'WaitForExit\(5000\)') -and ($laneText -match '\$task = \$null') -and ($laneText -match 'npm_config_cache')) 'lane com leitura limitada + HOME isolado do npx'
  Assert (($laneText -match 'Test-LaneLocalhostUrl') -and ($laneText -match '49374')) 'lane com guard localhost + recusa 49374'
}
else {
  Assert $false 'lane com params obrigatorios' 'arquivo ausente'
}

# --- Registry: pontos de guarda INALTERADOS ---
$prof = $null
try { $prof = ([IO.File]::ReadAllText($profPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $prof = $null }
Assert ($null -ne $prof) 'mcp-profiles.json parseia'
if ($null -ne $prof) {
  $testing = @(@($prof.profiles) | Where-Object { [string]$_.id -ceq 'testing' })
  Assert ((@($testing).Count -eq 1) -and ([string]$testing[0].status -ceq 'APPROVED')) 'guard: profile testing APPROVED'
}

$flags = $null
try { $flags = ([IO.File]::ReadAllText($flagsPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $flags = $null }
Assert ($null -ne $flags) 'capability-flags.json parseia'
if ($null -ne $flags) {
  Assert ($flags.mcp_routing.enabled -eq $false) 'guard: mcp_routing OFF'
  Assert ($flags.capability_router.active -eq $false) 'guard: capability_router.active OFF'
  Assert ($flags.skill_routing.enabled -eq $false) 'guard: skill_routing OFF'
  Assert ($flags.adaptive_ranking.enabled -eq $false) 'guard: adaptive_ranking OFF'
}

# --- Templates: tester/debugger ainda mode=subagent ---
foreach ($t in @(@{ Path = $tmplV2Path; Name = 'v2'; Key = 'agents' }, @{ Path = $tmplV1Path; Name = 'v1'; Key = 'agent' })) {
  $tmpl = $null
  try { $tmpl = ([IO.File]::ReadAllText($t.Path, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $tmpl = $null }
  Assert ($null -ne $tmpl) ('template ' + $t.Name + ' parseia')
  if ($null -ne $tmpl) {
    $agents = $tmpl.($t.Key)
    Assert (([string]$agents.tester.mode -ceq 'subagent')) ('template ' + $t.Name + ' tester mode=subagent')
    Assert (([string]$agents.debugger.mode -ceq 'subagent')) ('template ' + $t.Name + ' debugger mode=subagent')
  }
}

# --- Sem literais de segredo nos arquivos novos (padroes montados sem contiguidade) ---
$secPats = @(('sk' + '-'), ('Bear' + 'er'), ('api' + '_' + 'key'))
foreach ($f in @($fixturePath, $errorPath, $docsPath, $suitePath)) {
  $label = [IO.Path]::GetFileName($f)
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Assert $false ("sem segredo em " + $label) 'arquivo ausente'; continue }
  $t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
  $hits = New-Object System.Collections.ArrayList
  foreach ($p in $secPats) { if ($t -match [regex]::Escape($p)) { [void]$hits.Add($p) } }
  Assert ($hits.Count -eq 0) ("sem segredo em " + $label) ($hits -join ',')
}

# --- Docs: secao de uso pelos agentes presente ---
Assert (Test-Path -LiteralPath $docsPath -PathType Leaf) 'docs mcp-profiles.md existe'
if (Test-Path -LiteralPath $docsPath -PathType Leaf) {
  $docs = [IO.File]::ReadAllText($docsPath, [Text.Encoding]::UTF8)
  Assert ($docs -match '(?m)^## Uso pelos agentes \(tester/debugger\)') 'docs secao tester/debugger presente'
  Assert (($docs -match 'XDG_CONFIG_HOME') -and ($docs -match 'opencode run --standalone') -and ($docs -match 'opencode serve --port')) 'docs ativacao via profile isolado + comandos'
  Assert (($docs -match 'NOT_SUPPORTED') -and ($docs -match 'session_id') -and ($docs -match 'session\.environment')) 'docs isolamento intrasservico NOT_SUPPORTED'
  Assert (($docs -match '(?i)permission model inalterado') -and ($docs -match '(?i)custo sob demanda')) 'docs permission model + custo'
  Assert (($docs -match 'tester') -and ($docs -match 'Playwright') -and ($docs -match 'debugger') -and ($docs -match 'DevTools')) 'docs tester->Playwright + debugger->DevTools via Planner'
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
