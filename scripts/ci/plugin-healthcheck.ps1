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
param(
  [string]$PluginsDir = (Join-Path $HOME ".config\opencode\plugins"),
  [string]$LogPath = (Join-Path $HOME ".local\share\opencode\log\opencode.log"),
  [string[]]$ExpectedActive = @("orchestration-enforcement.js", "ai-memory-opencode2.ts"),
  [string[]]$DeprecatedAbsent = @("ai-memory.ts"),
  [string]$TelemetryPath = (Join-Path $HOME ".opencode-orchestration\evidence\v3\orchestration\session-injections.jsonl"),
  [string]$SinceTimestamp = ""
)
$ErrorActionPreference = "Stop"
$failures = @()
$warnings = @()

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
if (Test-Path $LogPath) {
  $tail = Get-Content $LogPath -Tail 3000
  $run = $null
  for ($i = $tail.Count - 1; $i -ge 0; $i--) {
    $m = [regex]::Match($tail[$i], 'run=([0-9a-f]{8})')
    if ($m.Success) { $run = $m.Groups[1].Value; break }
  }
  if ($null -eq $run) { $failures += "no run id found in log tail (cannot scope load errors to a run)" }
  else {
    $fs = New-Object System.IO.FileStream($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs)
    try {
      while (-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        if ($line -eq $null -or $line.IndexOf($run) -lt 0) { continue }
        if ($line -match 'failed to load plugin.+target="([^"]+)" ref=(err_[0-9a-f]+)') {
          $skip = $false
          if ($SinceTimestamp -ne "") {
            $tsm = [regex]::Match($line, 'timestamp=([^ ]+)')
            if ($tsm.Success -and $tsm.Groups[1].Value -le $SinceTimestamp) { $skip = $true }
          }
          if (-not $skip) {
            $loadErrors++
            if ($loadRefs.Count -lt 5) { $loadRefs += @{ target = $Matches[1]; ref = $Matches[2] } }
          }
        }
        foreach ($key in @($plugins.Keys)) {
          $pat = 'msg="loading plugin" id="[^"]*' + [regex]::Escape($key) + '"'
          if ($line -match $pat) { $plugins[$key]["loaded"] = $true }
        }
      }
    } finally { $sr.Close(); $fs.Close() }
    foreach ($r in $loadRefs) {
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
      if (-not $plugins[$key]["loaded"]) { $failures += "no loading-plugin line in run ${run}: $key" }
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

$overall = if ($failures.Count -eq 0) { "PASS" } else { "FAIL" }
$result = [ordered]@{
  overall = $overall
  plugins = $plugins
  deprecated = $deprecated
  forbidden_leftovers = $forbidden
  other_files_informational = $others
  load_errors = $loadErrors
  expected_load_errors = $expectedLoadErrors
  load_error_refs = $loadRefs
  telemetry = $telemetry
  failures = $failures
  warnings = $warnings
}
$result | ConvertTo-Json -Depth 5
if ($overall -eq "FAIL") { exit 1 } else { exit 0 }
