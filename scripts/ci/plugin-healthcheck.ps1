# Plugin healthcheck for the OpenCode V2 autodiscovered plugins directory.
# Read-only: inspects files, static export shape, and the server log.
# Prints a JSON summary (names, counts, timestamps only — never secrets)
# and exits 0 on PASS, 1 on FAIL.
# Convention: expected/deprecated plugin NAMES are parameters, not hardcoded
# extras; unknown files are reported informationally (see item 10, Phase 2A).
# Failure policy (Phase 2A review): (a) no run id in the log tail is a FAILURE
# (load errors cannot be scoped to a run without it); (b) ANY LoadError whose
# target matches an expected plugin (ExpectedActive, substring match) is a
# FAILURE; LoadErrors for non-expected plugins are warnings only. Plugin
# health requires zero expected-plugin load errors.
# F0/F5: totals contam TODOS os erros em escopo (amostra de 5 e so exibicao);
# run e token exato (inicio/whitespace antes; whitespace/,/;/fim depois;
# rejeita prefixo notrun= e sufixo nao-hex; mesma regex no extrator e no
# matcher; sem run => FAIL); erros com timestamp desconhecido entram em
# escopo (fail-closed), mas loading exige timestamp valido alem do corte
# (sem timestamp valido nao vale loaded/healthy; recusa em warning limitado);
# refs exibem so identificadores limitados
# (expected/deprecated ou "non-expected-plugin"), nunca target cru/URL/linha.
param(
  [string]$PluginsDir = (Join-Path $HOME ".config\opencode\plugins"),
  [string]$LogPath = (Join-Path $HOME ".local\share\opencode\log\opencode.log"),
  [string[]]$ExpectedActive = @("orchestration-enforcement.js", "ai-memory-opencode2.ts"),
  [string[]]$DeprecatedAbsent = @("ai-memory.ts"),
  [string]$TelemetryPath = (Join-Path $HOME ".opencode-orchestration\evidence\v3\orchestration\session-injections.jsonl"),
  [string]$SinceTimestamp = "",
  [string]$RuntimePath = "",
  [string]$ConfigPath = "",
  [string]$RuntimeVersion = "",
  [string]$RepoRoot = ""
)
$ErrorActionPreference = "Stop"
$failures = @()
$warnings = @()

# F0/F5 diagnostico apenas: presenca/forma/linhas de log nunca provam
# invocacao confiavel nem enforcement. Metadados abaixo sao fingerprints
# de diagnostico (hashes read-only, versao alegada) sem atestacao.
function Get-HealthSanitizedPlugin([string]$target, [string[]]$expected, [string[]]$deprecated) {
  foreach ($exp in $expected) {
    if (-not [string]::IsNullOrWhiteSpace($exp) -and $target -like ("*" + $exp + "*")) { return $exp }
  }
  foreach ($dep in $deprecated) {
    if (-not [string]::IsNullOrWhiteSpace($dep) -and $target -like ("*" + $dep + "*")) { return $dep }
  }
  return "non-expected-plugin"
}

# Token de run: mesma regex no extrator e no matcher. Formato exato 8hex em
# estilo logfmt: inicio ou whitespace antes, whitespace/,/;/fim depois.
# Rejeita prefixo (notrun=...) e sufixo (hex extra ou letra como z).
# Formas nao confirmadas nos logs (ex. run="..." citado) nao casam:
# sem run => FAIL (fail-closed, nunca PASS fabricado).
function Test-HealthRunPattern([string]$hex8) {
  return ('(?:^|\s)run=' + $hex8 + '(?=[\s,;]|$)')
}

function Test-HealthExactRun([string]$line, [string]$run) {
  if ([string]::IsNullOrWhiteSpace($line) -or [string]::IsNullOrWhiteSpace($run)) { return $false }
  return ([regex]::IsMatch($line, (Test-HealthRunPattern ([regex]::Escape($run)))))
}

function Get-HealthUtc([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  $dt = [datetime]::MinValue
  $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
  $ok = [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)
  if ($ok) { return $dt }
  return $null
}

function Get-HealthFileHash([string]$path) {
  # SHA256 via .NET direto (sem Get-FileHash): o filho pode herdar um
  # PSModulePath estranho do pai (ex. pwsh => modulos 5.1 indisponiveis).
  $out = ""
  try {
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        $sha = $null
        $fs = $null
        try {
          $sha = [System.Security.Cryptography.SHA256]::Create()
          $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
          $bytes = $sha.ComputeHash($fs)
          $out = ([BitConverter]::ToString($bytes)).Replace("-", "")
        } finally {
          if ($null -ne $fs) { try { $fs.Close() } catch { } }
          if ($null -ne $sha) { try { $sha.Dispose() } catch { } }
        }
      }
    }
  } catch { $out = "" }
  return $out
}

$sinceUtc = $null
$sinceInvalid = $false
if ($SinceTimestamp -ne "") {
  $sinceUtc = Get-HealthUtc $SinceTimestamp
  if ($null -eq $sinceUtc) {
    $sinceInvalid = $true
    $failures += "invalid SinceTimestamp (fail-closed, no time filtering applied)"
  }
}

function Get-ExportShape([string]$path) {
  $txt = [System.IO.File]::ReadAllText($path)
  $hasId = $txt -match '(?m)^\s*id\s*:'
  $hasSetup = $txt -match '(?m)^\s*(setup|effect)\s*[:=]'
  $hasDefault = ($txt -match 'export\s+default\b') -or ($txt -match '\b as default\b')
  $looksV1Fn = $txt -match '(?m)^export\s+(const\s+\w+\s*:\s*Plugin\s*=\s*async|default\s+[A-Za-z_]\w*\s*;?\s*$)'
  if ($hasId -and $hasSetup -and $hasDefault) { return "v2_object" }
  if ($looksV1Fn) { return "v1_function" }
  return "unknown"
}

$plugins = @{}
foreach ($name in $ExpectedActive) {
  $p = Join-Path $PluginsDir $name
  $present = Test-Path $p
  $shape = "missing"
  if ($present) { $shape = Get-ExportShape $p } else { $failures += "missing expected plugin: $name" }
  if ($present -and $shape -ne "v2_object") { $failures += "unexpected export shape for ${name}: ${shape}" }
  $plugins[$name] = @{ present = $present; shape = $shape; loaded = $false; healthy = $false }
}

$deprecated = @{}
foreach ($name in $DeprecatedAbsent) {
  $present = Test-Path (Join-Path $PluginsDir $name)
  if ($present) { $failures += "deprecated plugin still in active root: $name" }
  $deprecated[$name] = @{ present = $present; deprecated = $true }
}

$forbidden = @()
if (Test-Path $PluginsDir) {
  Get-ChildItem $PluginsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match '\.(bak[^.]*|disabled.*|v\d+-disabled.*)$') { $forbidden += $_.Name }
  }
}
foreach ($f in $forbidden) {
  if ($f -like "ai-memory*") { $failures += "inactive ai-memory copy in active root: $f" }
  else { $warnings += "inactive copy in active root (out of Phase 2A scope): $f" }
}

$others = @()
if (Test-Path $PluginsDir) {
  Get-ChildItem $PluginsDir -File -ErrorAction SilentlyContinue | ForEach-Object {
    if (($ExpectedActive -notcontains $_.Name) -and ($forbidden -notcontains $_.Name)) { $others += $_.Name }
  }
}

$loadErrors = 0
$expectedLoadErrors = 0
$loadRefs = @()
$allLoadErrors = @()
$runIdOut = "UNKNOWN"
if (Test-Path $LogPath) {
  $tail = Get-Content $LogPath -Tail 3000
  $run = $null
  for ($i = $tail.Count - 1; $i -ge 0; $i--) {
    $m = [regex]::Match($tail[$i], (Test-HealthRunPattern '([0-9a-f]{8})'))
    if ($m.Success) { $run = $m.Groups[1].Value; break }
  }
  if ($null -eq $run) { $failures += "no run id found in log tail (cannot scope load errors to a run)" }
  else {
    $runIdOut = $run
    $unverifiableLoading = @{}
    $fs = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs)
    try {
      while (-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        if ($line -eq $null -or (-not (Test-HealthExactRun $line $run))) { continue }
        $lineUtc = $null
        $tsmScope = [regex]::Match($line, 'timestamp=([^ ]+)')
        if ($tsmScope.Success) { $lineUtc = Get-HealthUtc $tsmScope.Groups[1].Value }
        $filterOn = ((-not $sinceInvalid) -and ($null -ne $sinceUtc))
        # Erros: timestamp desconhecido SEMPRE inspecionado (fail-closed).
        $errorInScope = $true
        if ($filterOn -and ($null -ne $lineUtc) -and ($lineUtc -le $sinceUtc)) { $errorInScope = $false }
        if ($errorInScope -and ($line -match 'failed to load plugin.+target="([^"]+)" ref=(err_[0-9a-f]+)')) {
          $rawTarget = $Matches[1]
          $ref = $Matches[2]
          $sanitized = Get-HealthSanitizedPlugin $rawTarget $ExpectedActive $DeprecatedAbsent
          $allLoadErrors += @{ target = $sanitized; ref = $ref }
        }
        # Loading e afirmacao positiva: exige timestamp valido alem do corte.
        # Sem timestamp valido com filtro exigido nao vale loaded/healthy.
        foreach ($key in @($plugins.Keys)) {
          $pat = 'msg="loading plugin" id="[^"]*' + [regex]::Escape($key) + '"'
          if ($line -match $pat) {
            if (-not $filterOn) { $plugins[$key]["loaded"] = $true }
            elseif (($null -ne $lineUtc) -and ($lineUtc -gt $sinceUtc)) { $plugins[$key]["loaded"] = $true }
            else { $unverifiableLoading[$key] = $true }
          }
        }
      }
    } finally { $sr.Close(); $fs.Close() }
    # Total real: TODOS os erros em escopo classificam; amostra de 5 e so exibicao.
    $loadErrors = @($allLoadErrors).Count
    $cap = 5
    if ($loadErrors -gt 0) {
      $upper = $loadErrors
      if ($upper -gt $cap) { $upper = $cap }
      for ($k = 0; $k -lt $upper; $k++) { $loadRefs += $allLoadErrors[$k] }
    }
    foreach ($r in $allLoadErrors) {
      $isExpected = $false
      foreach ($exp in $ExpectedActive) {
        if ($r.target -like ("*" + $exp + "*")) { $isExpected = $true; break }
      }
      $isDeprecated = $false
      foreach ($dep in $DeprecatedAbsent) {
        if ($r.target -like ("*" + $dep + "*")) { $isDeprecated = $true; break }
      }
      if ($isExpected) {
        $expectedLoadErrors++
        $failures += "LoadError in run ${run}: $($r.target) ($($r.ref))"
      } elseif ($isDeprecated) {
        $failures += "LoadError for deprecated plugin in run ${run}: $($r.target) ($($r.ref))"
      } else {
        $warnings += "LoadError for non-expected plugin in run ${run}: $($r.target) ($($r.ref))"
      }
    }
    foreach ($key in @($plugins.Keys)) {
      if (-not $plugins[$key]["loaded"]) {
        $failures += "no loading-plugin line in run ${run}: $key"
        if ($unverifiableLoading.ContainsKey($key)) {
          $warnings += "unverifiable loading-plugin line refused (no valid timestamp past cutoff) in run ${run}: $key"
        }
      }
      $plugins[$key]["healthy"] = ($plugins[$key]["present"] -and ($plugins[$key]["shape"] -eq "v2_object") -and $plugins[$key]["loaded"] -and ($expectedLoadErrors -eq 0))
    }
  }
} else { $failures += "server log not found: $LogPath" }

$telemetry = @{ present = $false }
if (Test-Path $TelemetryPath) {
  $last = Get-Content $TelemetryPath -Tail 1
  $tsm = [regex]::Match($last, '"ts":"([^"]+)"')
  $telemetry = @{ present = $true; last_ts = $(if ($tsm.Success) { $tsm.Groups[1].Value } else { "unknown" }) }
}

# Metadados incrementais opcionais (diagnostico apenas, nunca gateiam PASS):
# hashes read-only de runtime/config/plugins + versao alegada vs pin.
$pluginHashes = @{}
foreach ($name in $ExpectedActive) {
  $pp = Join-Path $PluginsDir $name
  if (Test-Path -LiteralPath $pp -PathType Leaf) {
    $h = Get-HealthFileHash $pp
    if ($h -eq "") { $pluginHashes[$name] = "UNKNOWN" } else { $pluginHashes[$name] = $h }
  } else { $pluginHashes[$name] = "missing" }
}
$runtimeHash = Get-HealthFileHash $RuntimePath
$runtimeMeta = @{ status = "UNKNOWN"; sha256 = "UNKNOWN" }
if ($RuntimePath -ne "") {
  if ($runtimeHash -ne "") { $runtimeMeta = @{ status = "available"; sha256 = $runtimeHash } }
  else { $runtimeMeta = @{ status = "unavailable"; sha256 = "UNKNOWN" } }
}
$configHash = Get-HealthFileHash $ConfigPath
$configMeta = @{ status = "UNKNOWN"; sha256 = "UNKNOWN" }
if ($ConfigPath -ne "") {
  if ($configHash -ne "") { $configMeta = @{ status = "available"; sha256 = $configHash } }
  else { $configMeta = @{ status = "unavailable"; sha256 = "UNKNOWN" } }
}
$claimedVersion = @{ status = "UNKNOWN"; claimed = "UNKNOWN"; pinned = "UNKNOWN"; match = "UNKNOWN" }
if ($RuntimeVersion -ne "") {
  $claimedVersion["claimed"] = $RuntimeVersion
  $claimedVersion["status"] = "UNVERIFIED"
  try {
    $rr = $RepoRoot
    if ([string]::IsNullOrWhiteSpace($rr)) {
      $here = $PSScriptRoot
      $rr = (Resolve-Path -LiteralPath (Join-Path $here '..\..')).Path
    }
    $libPath = Join-Path $rr 'scripts\runtime\lib\RuntimeVersions.ps1'
    if (Test-Path -LiteralPath $libPath -PathType Leaf) {
      . $libPath
      $pin = Get-OrchestrationRuntimeVersion -Name 'v2' -RepoRoot $rr
      $claimedVersion["pinned"] = [string]$pin.Version
      if ($RuntimeVersion -eq [string]$pin.Version) { $claimedVersion["match"] = $true }
      else { $claimedVersion["match"] = $false }
    }
  } catch { $claimedVersion["pinned"] = "UNKNOWN" }
}

$overall = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
$sampleCapped = ($loadErrors -gt @($loadRefs).Count)
$engineInfo = @{ powershell_version = "UNKNOWN"; edition = "UNKNOWN" }
try {
  $engineInfo = @{ powershell_version = [string]$PSVersionTable.PSVersion; edition = [string]$PSEdition }
} catch { }
$result = [ordered]@{
  overall = $overall
  run_id = $runIdOut
  since_timestamp = $(if ($SinceTimestamp -eq "") { "none" } else { $SinceTimestamp })
  plugins = $plugins
  deprecated = $deprecated
  forbidden_leftovers = $forbidden
  other_files_informational = $others
  load_errors = $loadErrors
  load_errors_total = $loadErrors
  expected_load_errors = $expectedLoadErrors
  load_error_refs = $loadRefs
  load_error_sample_capped = $sampleCapped
  telemetry = $telemetry
  failures = $failures
  warnings = $warnings
  plugin_hashes = $pluginHashes
  runtime = $runtimeMeta
  config = $configMeta
  claimed_runtime_version = $claimedVersion
  evidence_correlation = "NOT_OBSERVED"
  invocation_proven = $false
  diagnostic_only = $true
  engine = $engineInfo
}
$result | ConvertTo-Json -Depth 5
if ($overall -eq "FAIL") { exit 1 } else { exit 0 }
