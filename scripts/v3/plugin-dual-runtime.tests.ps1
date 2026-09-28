# plugin-dual-runtime.tests.ps1 — Phase 4 (V3.1): arquitetura dual-runtime do plugin.
# Valida sem harness TS: (a) lista canonica de 19 workers identica entre
# shared/identity.ts e source/agents/*.md; (b) pureza do shared (sem imports
# de runtime; adapters/index sem imports de runtime dos pacotes); (c) forma
# do dual-export { id, setup, server }; (d) typecheck dual real (V1+V2+DUAL).
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pluginIndex = Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'
$pluginDir = Join-Path $RepoRoot 'plugins\orchestration-enforcement'
$sharedDir = Join-Path $pluginDir 'shared'

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
  else {
    $msg = "[FAIL] $name"
    if (-not [string]::IsNullOrWhiteSpace($detail)) { $msg = $msg + " -- " + $detail }
    Write-Host $msg
  }
}

# (a) 19 workers: shared/identity.ts vs source/agents/*.md (canonico).
$canonAgents = @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
Assert-That ($canonAgents.Count -eq 19) 'canon tem 19 agents em source/agents' ("count=$($canonAgents.Count)")
$identityText = [IO.File]::ReadAllText((Join-Path $sharedDir 'identity.ts'))
$blockStart = $identityText.IndexOf('WORKER_AGENT_NAMES')
$blockEnd = $identityText.IndexOf('];', $blockStart)
$block = ''
if (($blockStart -ge 0) -and ($blockEnd -gt $blockStart)) { $block = $identityText.Substring($blockStart, $blockEnd - $blockStart) }
$listed = @([regex]::Matches($block, '"([a-z][a-z0-9-]*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$missing = @($canonAgents | Where-Object { $listed -notcontains $_ })
$extra = @($listed | Where-Object { $canonAgents -notcontains $_ })
Assert-That (($missing.Count -eq 0) -and ($extra.Count -eq 0) -and ($listed.Count -eq 19)) 'WORKER_AGENT_NAMES identica ao canon (19)' ("missing=[$($missing -join ',')] extra=[$($extra -join ',')] listed=$($listed.Count)")

# (a2) regra unica: sentenca-ancora do mandato mora SO em shared/mandate.ts.
$anchorFiles = @()
foreach ($f in @($pluginIndex, (Join-Path $pluginDir 'v1.ts'), (Join-Path $pluginDir 'v2.ts'))) {
  $t = [IO.File]::ReadAllText($f)
  if ($t.Contains('TRIVIAL_DIRECT')) { $anchorFiles += (Split-Path -Leaf $f) }
}
$mandateText = [IO.File]::ReadAllText((Join-Path $sharedDir 'mandate.ts'))
Assert-That (($anchorFiles.Count -eq 0) -and $mandateText.Contains('TRIVIAL_DIRECT')) 'mandato em fonte unica (shared/mandate.ts)' ("ancora fora do shared: [$($anchorFiles -join ',')]")
# marcadores das duas geracoes derivam do mesmo construtor.
Assert-That ($mandateText.Contains('generation') -and $mandateText.Contains(':worker')) 'mandate.ts parametriza geracao (v1/v2 + :worker)' 'sem marker parametrizado'

# (b) pureza: shared/*.ts (exceto telemetry.ts) sem imports; telemetry sem @opencode.
$pureOk = $true
$pureDetail = ''
foreach ($f in @(Get-ChildItem -File (Join-Path $sharedDir '*.ts'))) {
  $t = [IO.File]::ReadAllText($f.FullName)
  if ($f.BaseName -eq 'telemetry') {
    if ($t -match '@opencode-ai/|@opencode/') { $pureOk = $false; $pureDetail = $pureDetail + ' telemetry importa @opencode;' }
    if ($t -notmatch 'from "node:') { $pureOk = $false; $pureDetail = $pureDetail + ' telemetry sem node:fs/os/path;' }
  } else {
    if ($t -match '^\s*import\s.*from\s' -or $t -match 'require\s*\(') {
      # Permite apenas imports relativos de irmaos shared (./x), nunca pacotes.
      $lines = $t -split "`n" | Where-Object { $_ -match '^\s*import\s' -and $_ -notmatch 'from\s+["'']\./' }
      if ($lines.Count -gt 0) { $pureOk = $false; $pureDetail = $pureDetail + " $($f.Name) tem import nao-relativo;" }
      if ($t -match 'require\s*\(') { $pureOk = $false; $pureDetail = $pureDetail + " $($f.Name) usa require;" }
    }
  }
}
Assert-That $pureOk 'shared puro (sem imports externos; telemetry so node:)' $pureDetail.Trim()

# (b2) adapters + index: nenhum import de RUNTIME dos pacotes (so `import type`).
# Olha apenas statements de modulo (import/export ... from "pacote"); mencoes
# em comentarios sao irrelevantes.
$extOk = $true
$extDetail = ''
foreach ($f in @($pluginIndex, (Join-Path $pluginDir 'v1.ts'), (Join-Path $pluginDir 'v2.ts'))) {
  $t = [IO.File]::ReadAllText($f)
  $bad = $t -split "`n" | Where-Object { ($_ -match '(import|export)\s[^;]*from\s+["'']@opencode') -and ($_ -notmatch 'import\s+type\s') }
  $badReq = $t -split "`n" | Where-Object { $_ -match 'require\s*\(\s*["'']@opencode' }
  $n = $bad.Count + $badReq.Count
  if ($n -gt 0) { $extOk = $false; $extDetail = $extDetail + " $(Split-Path -Leaf $f): $n linha(s) com referencia nao-type;" }
}
Assert-That $extOk 'adapters/index sem import de runtime @opencode*' $extDetail.Trim()

# (b3) v1.ts importa o pacote V1 (type-only) e v2.ts o pacote V2 (type-only): trilhas distintas.
$v1t = [IO.File]::ReadAllText((Join-Path $pluginDir 'v1.ts'))
$v2t = [IO.File]::ReadAllText((Join-Path $pluginDir 'v2.ts'))
Assert-That ($v1t -match 'import\s+type\s.*@opencode-ai/plugin') 'v1.ts referencia tipos @opencode-ai/plugin' 'sem import type V1'
Assert-That ($v2t -match 'import\s+type\s.*@opencode/plugin') 'v2.ts referencia tipos @opencode/plugin' 'sem import type V2'
Assert-That ($v1t -notmatch '@opencode/plugin"') 'v1.ts nao toca no pacote V2' 'referencia cruzada V1->V2'
Assert-That (($v2t -split "`n" | Where-Object { $_ -match '@opencode-ai/plugin' }).Count -eq 0) 'v2.ts nao toca no pacote V1' 'referencia cruzada V2->V1'

# (c) dual-export no index: default com id + setup + server.
$idx = [IO.File]::ReadAllText($pluginIndex)
Assert-That ($idx -match 'export\s+default') 'index tem export default' 'sem default'
Assert-That (($idx -match 'id:\s*V2_ID' -or $idx -match '\bid\b') -and ($idx -match '\bsetup\b') -and ($idx -match '\bserver\b')) 'default export carrega id+setup+server' 'forma inesperada'
Assert-That ($idx -match 'OrchestrationEnforcement' -and $idx -match '__orchestrationEnforcementTest') 'index preserva back-compat (harness)' 'named exports ausentes'

# (d) typecheck dual real — GATED por rede: roda SOMENTE com
# OO_PLUGIN_TYPECHECK=1 (o CI define); default imprime [SKIP] e segue sem
# falhar, para nao estourar o budget de 300s/suite do runner com installs
# de rede (bun add + tsc nas 3 trilhas V1/V2/DUAL).
$tcScript = Join-Path $RepoRoot 'scripts\ci\typecheck-plugin.ps1'
Assert-That (Test-Path -LiteralPath $tcScript -PathType Leaf) 'typecheck-plugin.ps1 existe' 'ausente'
if ($env:OO_PLUGIN_TYPECHECK -eq '1') {
  $tcCode = -1
  if (Test-Path -LiteralPath $tcScript -PathType Leaf) {
    # Sob o runner, o orcamento e 300s/suite: cap curto no bun add para cair
    # no fallback npm rapido quando o resolver do bun trava (rede degradada).
    $env:OO_TYPECHECK_BUN_MS = '120000'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $tcScript + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $RepoRoot
    $p = [System.Diagnostics.Process]::Start($psi)
    # Cap interno generoso (invocacao direta tolera installs lentos); sob o
    # runner V3 o orcamento da suite (300s) aplica-se de qualquer forma.
    $finished = $p.WaitForExit(1500000)
    if (-not $finished) {
      try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
      Assert-That $false 'typecheck dual exit 0 (timeout 1500s)' 'timeout'
    } else {
      $tcCode = $p.ExitCode
      try { $p.Close() } catch { }
      Assert-That ($tcCode -eq 0) 'typecheck dual exit 0 (trilhas V1+V2+DUAL)' ("exit=$tcCode")
    }
  }
}
else {
  Write-Host '[SKIP] typecheck dual (rede fora do budget 300s/suite; defina OO_PLUGIN_TYPECHECK=1 para rodar)'
  Assert-That $true 'typecheck dual gated (skip sem OO_PLUGIN_TYPECHECK=1)' 'typecheck roda so no CI'
}

# (e) harness mock V2 (V31-R2 F3): local e sem rede, roda SEMPRE (rapido).
# Cobre setup() do adapter V2 contra ctx fake: mandato v2 injetado,
# telemetria com runtime:v2, superficies ausentes fail-open e cleanup.
# Falha do mock = FAIL da suite.
$mockPath = Join-Path $RepoRoot 'tests\distribution\plugin-harness\v2-mock.ts'
Assert-That (Test-Path -LiteralPath $mockPath -PathType Leaf) 'v2-mock.ts existe' 'ausente'
$bunMock = Get-Command 'bun' -ErrorAction SilentlyContinue
Assert-That ($null -ne $bunMock) 'bun disponivel (gate do mock V2)' 'bun ausente no PATH'
if ($null -ne $bunMock) {
  $mockOut = & bun run $mockPath 2>&1
  $mockCode = $LASTEXITCODE
  foreach ($l in @($mockOut)) { Write-Host $l }
  $mockBad = @($mockOut | Where-Object { $_ -match 'NOT OK -' }).Count
  $mockSummary = @($mockOut | Where-Object { $_ -match '^SUMMARY' })
  $mockSummaryOk = (($mockSummary.Count -gt 0) -and ($mockSummary[0] -match 'fail=0'))
  Assert-That ($mockCode -eq 0) 'mock V2 exit 0' ("exit=$mockCode")
  Assert-That ($mockBad -eq 0) 'mock V2 sem NOT OK' ("NOT OK=$mockBad")
  Assert-That $mockSummaryOk 'mock V2 summary fail=0' 'summary ausente ou com falha'
}

Write-Host ''
Write-Host ("PASS: " + $passed + " / FAIL: " + ($total - $passed) + " / TOTAL: " + $total)
if ($passed -ne $total) { exit 1 } else { exit 0 }
