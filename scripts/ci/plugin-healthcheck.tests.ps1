# plugin-healthcheck.tests.ps1 -- F0/F5 (diagnostico).
# Casos: missing plugin; time cutoff (erro antigo filtrado; loading exige
# timestamp valido); run exato (substring/prefixo/sufixo rejeitados); erro #6
# no total (amostra cap 5); loaded sem arquivo nao e healthy; Since invalido
# fail-closed; erro sem timestamp valido com filtro => em escopo; loading sem
# timestamp com filtro => FAIL + recusa limitada; hashes mudam; redacao sem
# segredo; schema legacy preservado; metadados ausentes => UNKNOWN; engine
# do filho == engine atual (reportada em engine.*).
# PS 5.1 e PS7 compativel. Sem Pester. Fixtures em TEMP owned. ASCII only.
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')
$ErrorActionPreference = 'Stop'
$script:cli = Join-Path $PSScriptRoot 'plugin-healthcheck.ps1'
$script:childExe = ''
$script:childIsCore = $false
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
  $found = $null
  try { $found = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $found = $null }
  if (($null -ne $found) -and (-not [string]::IsNullOrWhiteSpace([string]$found.Source))) {
    $script:childExe = [string]$found.Source
    $script:childIsCore = $true
  }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) {
  $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
  $script:childExe = $psExe
  $script:childIsCore = $false
}
if ([string]::IsNullOrWhiteSpace($script:childExe)) {
  Write-Host '[FAIL] engine indisponivel (nem pwsh nem powershell resolvidos)'
  exit 1
}
# Harness imprime so o caminho da engine (sem segredos).
Write-Host ('engine: ' + $script:childExe)

$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name -- $detail" }
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('hc-f5-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$v2body = "const p = {`r`n  id: `"t`",`r`n  setup: () => {},`r`n};`r`nexport default p;`r`n"
$expA = 'plug-a.js'
$expB = 'plug-b.js'

function New-PlugDir([string]$dir, [string[]]$names) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  foreach ($n in $names) {
    [IO.File]::WriteAllText((Join-Path $dir $n), $script:v2body, (New-Object Text.UTF8Encoding $false))
  }
}

function Invoke-Hc {
  param([string]$argLine)
  # -Command (nao -File): literais de array @('a','b') e strings vazias precisam
  # de avaliacao PowerShell; -File passa tudo como string literal.
  $cmd = "& '" + $script:cli + "' " + $argLine
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:childExe
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd.Replace('"', '\"') + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $PSScriptRoot
  if (-not $script:childIsCore) {
    try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  }
  $p = [System.Diagnostics.Process]::Start($psi)
  $so = ''
  try { $so = $p.StandardOutput.ReadToEnd() } catch { $so = '' }
  $done = $false
  try { $done = $p.WaitForExit(60000) } catch { $done = $false }
  if (-not $done) { try { $p.Kill() } catch { } }
  $code = -1
  try { $code = $p.ExitCode } catch { $code = -1 }
  try { $p.Close() } catch { }
  $obj = $null
  try { $obj = ($so | ConvertFrom-Json) } catch { $obj = $null }
  return @{ Code = $code; Out = $so; Obj = $obj }
}

function New-LogLine([string]$run, [string]$ts, [string]$body) {
  return ('ts x timestamp=' + $ts + ' run=' + $run + ' ' + $body)
}

try {
  $noTel = Join-Path $base 'no-telemetry.jsonl'

  # --- 1. missing expected plugin => FAIL ---
  $d1 = Join-Path $base 'c1plug'
  New-PlugDir $d1 @($expA)
  $l1 = Join-Path $base 'c1.log'
  [IO.File]::WriteAllLines($l1, @(
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
  ), (New-Object Text.UTF8Encoding $false))
  $r1 = Invoke-Hc ('-PluginsDir "' + $d1 + '" -LogPath "' + $l1 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r1.Code -eq 1) -and ($null -ne $r1.Obj) -and ([string]$r1.Obj.overall -eq 'FAIL')) 'missing expected plugin => FAIL' ('exit=' + $r1.Code)
  Assert-That (([string]$r1.Out -like '*missing expected plugin*')) 'missing: failure menciona plugin ausente' 'sem marcador'

  # --- 2. time cutoff coerente: erro antigo filtrado, loading novo conta => PASS; sem Since => FAIL ---
  $d2 = Join-Path $base 'c2plug'
  New-PlugDir $d2 @($expA, $expB)
  $l2 = Join-Path $base 'c2.log'
  [IO.File]::WriteAllLines($l2, @(
    (New-LogLine 'bbbbbbbb' '2026-10-01T10:00:00Z' ('FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_abc123'))
    (New-LogLine 'bbbbbbbb' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'bbbbbbbb' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
  ), (New-Object Text.UTF8Encoding $false))
  $r2f = Invoke-Hc ('-PluginsDir "' + $d2 + '" -LogPath "' + $l2 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -SinceTimestamp "2026-10-05T00:00:00Z"')
  Assert-That (([int]$r2f.Code -eq 0) -and ([string]$r2f.Obj.overall -eq 'PASS')) 'cutoff: erro antigo filtrado + loading novo => PASS' ('exit=' + $r2f.Code)
  $r2n = Invoke-Hc ('-PluginsDir "' + $d2 + '" -LogPath "' + $l2 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r2n.Code -eq 1) -and ([int]$r2n.Obj.expected_load_errors -eq 1)) 'sem Since: mesmo erro antigo conta => FAIL' ('exit=' + $r2n.Code)

  # --- 3. substring de run nao casa (run=aaaaaaaa9 nao e run=aaaaaaaa) ---
  $d3 = Join-Path $base 'c3plug'
  New-PlugDir $d3 @($expA, $expB)
  $l3 = Join-Path $base 'c3.log'
  [IO.File]::WriteAllLines($l3, @(
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    ('ts x timestamp=2026-10-10T10:00:00Z run=aaaaaaaa9 FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_def456')
  ), (New-Object Text.UTF8Encoding $false))
  $r3 = Invoke-Hc ('-PluginsDir "' + $d3 + '" -LogPath "' + $l3 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r3.Code -eq 0) -and ([int]$r3.Obj.load_errors -eq 0)) 'substring run=aaaaaaaa9 nao casa run=aaaaaaaa' ('exit=' + $r3.Code + ' load=' + $r3.Obj.load_errors)

  # --- 3b. prefixo notrun= nao casa; sufixo nao-hex (z) nao casa ---
  $d3b = Join-Path $base 'c3bplug'
  New-PlugDir $d3b @($expA, $expB)
  $l3b = Join-Path $base 'c3b.log'
  [IO.File]::WriteAllLines($l3b, @(
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    ('ts x timestamp=2026-10-10T10:00:00Z notrun=aaaaaaaa FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_def456')
  ), (New-Object Text.UTF8Encoding $false))
  $r3b = Invoke-Hc ('-PluginsDir "' + $d3b + '" -LogPath "' + $l3b + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r3b.Code -eq 0) -and ([int]$r3b.Obj.load_errors -eq 0)) 'prefixo notrun=aaaaaaaa nao casa' ('exit=' + $r3b.Code + ' load=' + $r3b.Obj.load_errors)
  $l3c = Join-Path $base 'c3c.log'
  [IO.File]::WriteAllLines($l3c, @(
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    ('ts x timestamp=2026-10-10T10:00:00Z run=aaaaaaaaz FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_def456')
  ), (New-Object Text.UTF8Encoding $false))
  $r3c = Invoke-Hc ('-PluginsDir "' + $d3b + '" -LogPath "' + $l3c + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r3c.Code -eq 0) -and ([int]$r3c.Obj.load_errors -eq 0)) 'sufixo run=aaaaaaaaz nao casa' ('exit=' + $r3c.Code + ' load=' + $r3c.Obj.load_errors)

  # --- 4. erro #6 esperado: total 6, amostra 5, FAIL, healthy=false ---
  $d4 = Join-Path $base 'c4plug'
  New-PlugDir $d4 @($expA, $expB)
  $lines4 = @()
  $lines4 += (New-LogLine 'cccccccc' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
  $lines4 += (New-LogLine 'cccccccc' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
  $refs4 = @('err_111111', 'err_222222', 'err_333333', 'err_444444', 'err_555555', 'err_666666')
  foreach ($rf in $refs4) {
    $lines4 += (New-LogLine 'cccccccc' '2026-10-10T10:00:00Z' ('FAILED failed to load plugin boom target="x/' + $expA + '" ref=' + $rf))
  }
  $l4 = Join-Path $base 'c4.log'
  [IO.File]::WriteAllLines($l4, $lines4, (New-Object Text.UTF8Encoding $false))
  $r4 = Invoke-Hc ('-PluginsDir "' + $d4 + '" -LogPath "' + $l4 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r4.Code -eq 1) -and ([int]$r4.Obj.load_errors -eq 6) -and ([int]$r4.Obj.expected_load_errors -eq 6)) 'erro #6 conta no total (6/6)' ('load=' + $r4.Obj.load_errors + ' exp=' + $r4.Obj.expected_load_errors)
  Assert-That ((@($r4.Obj.load_error_refs).Count -eq 5) -and ([bool]$r4.Obj.load_error_sample_capped)) 'amostra cap 5 com flag' ('refs=' + @($r4.Obj.load_error_refs).Count)
  Assert-That ((-not [bool]$r4.Obj.plugins.PSObject.Properties[$expA].Value.healthy)) 'loaded nao e healthy com erro requerido' 'healthy indevido'

  # --- 5. loaded sem arquivo: loading no log nao salva missing ---
  $d5 = Join-Path $base 'c5plug'
  New-PlugDir $d5 @($expA)
  $l5 = Join-Path $base 'c5.log'
  [IO.File]::WriteAllLines($l5, @(
    (New-LogLine 'dddddddd' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'dddddddd' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
  ), (New-Object Text.UTF8Encoding $false))
  $r5 = Invoke-Hc ('-PluginsDir "' + $d5 + '" -LogPath "' + $l5 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([int]$r5.Code -eq 1) -and ([string]$r5.Out -like '*missing expected plugin*')) 'loaded sem arquivo => FAIL missing' ('exit=' + $r5.Code)
  Assert-That ((-not [bool]$r5.Obj.plugins.PSObject.Properties[$expB].Value.healthy)) 'plugin ausente nunca healthy' 'healthy indevido'

  # --- 6. Since invalido fail-closed; linha sem timestamp com filtro exigido entra em escopo ---
  $d6 = Join-Path $base 'c6plug'
  New-PlugDir $d6 @($expA, $expB)
  $l6 = Join-Path $base 'c6.log'
  [IO.File]::WriteAllLines($l6, @(
    (New-LogLine 'eeeeeeee' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'eeeeeeee' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    (New-LogLine 'eeeeeeee' '2026-10-10T10:00:00Z' ('FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_789abc'))
  ), (New-Object Text.UTF8Encoding $false))
  $r6 = Invoke-Hc ('-PluginsDir "' + $d6 + '" -LogPath "' + $l6 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -SinceTimestamp "not-a-time"')
  Assert-That (([int]$r6.Code -eq 1) -and ([string]$r6.Out -like '*invalid SinceTimestamp*')) 'Since invalido => FAIL fail-closed' ('exit=' + $r6.Code)
  $l6b = Join-Path $base 'c6b.log'
  [IO.File]::WriteAllLines($l6b, @(
    (New-LogLine 'eeeeeeee' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'eeeeeeee' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    ('ts x timestamp=not-a-time run=eeeeeeee FAILED failed to load plugin boom target="x/' + $expA + '" ref=err_789abc')
  ), (New-Object Text.UTF8Encoding $false))
  $r6b = Invoke-Hc ('-PluginsDir "' + $d6 + '" -LogPath "' + $l6b + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -SinceTimestamp "2026-10-05T00:00:00Z"')
  Assert-That (([int]$r6b.Code -eq 1) -and ([int]$r6b.Obj.expected_load_errors -eq 1)) 'linha sem timestamp valido com filtro => em escopo' ('exit=' + $r6b.Code)

  # --- 6c. loading sem timestamp com Since valido: nao vale loaded/healthy + recusa limitada ---
  $l6c = Join-Path $base 'c6c.log'
  [IO.File]::WriteAllLines($l6c, @(
    ('ts x run=eeeeeeee msg="loading plugin" id="x/' + $expA + '"')
    ('ts x run=eeeeeeee msg="loading plugin" id="x/' + $expB + '"')
  ), (New-Object Text.UTF8Encoding $false))
  $r6c = Invoke-Hc ('-PluginsDir "' + $d6 + '" -LogPath "' + $l6c + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -SinceTimestamp "2026-10-05T00:00:00Z"')
  Assert-That (([int]$r6c.Code -eq 1) -and (-not [bool]$r6c.Obj.plugins.PSObject.Properties[$expA].Value.loaded) -and (-not [bool]$r6c.Obj.plugins.PSObject.Properties[$expA].Value.healthy)) 'loading sem timestamp com Since => FAIL loaded=false healthy=false' ('exit=' + $r6c.Code)
  Assert-That (([string]$r6c.Out -like '*unverifiable loading-plugin line refused*')) 'loading sem timestamp => recusa limitada' 'sem marcador'

  # --- 7. hashes: mudanca detectada; ausente => UNKNOWN ---
  $d7 = Join-Path $base 'c7plug'
  New-PlugDir $d7 @($expA, $expB)
  $l7 = Join-Path $base 'c7.log'
  [IO.File]::WriteAllLines($l7, @(
    (New-LogLine 'ffffffff' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'ffffffff' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
  ), (New-Object Text.UTF8Encoding $false))
  $rt7 = Join-Path $base 'rt.bin'
  [IO.File]::WriteAllText($rt7, 'v1', (New-Object Text.UTF8Encoding $false))
  $cf7 = Join-Path $base 'cfg.json'
  [IO.File]::WriteAllText($cf7, '{"a":1}', (New-Object Text.UTF8Encoding $false))
  $r7a = Invoke-Hc ('-PluginsDir "' + $d7 + '" -LogPath "' + $l7 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -RuntimePath "' + $rt7 + '" -ConfigPath "' + $cf7 + '"')
  Assert-That (([int]$r7a.Code -eq 0) -and ([string]$r7a.Obj.runtime.status -eq 'available') -and ([string]$r7a.Obj.config.status -eq 'available')) 'runtime/config existentes => available' ('exit=' + $r7a.Code)
  $hBefore = [string]$r7a.Obj.runtime.sha256
  [IO.File]::WriteAllText($rt7, 'v2-changed', (New-Object Text.UTF8Encoding $false))
  $r7b = Invoke-Hc ('-PluginsDir "' + $d7 + '" -LogPath "' + $l7 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '" -RuntimePath "' + $rt7 + '" -ConfigPath "' + $cf7 + '"')
  Assert-That (([string]$r7b.Obj.runtime.sha256 -ne $hBefore) -and ([string]$r7b.Obj.runtime.sha256 -ne 'UNKNOWN')) 'hash muda com conteudo' 'hash igual'
  $r7c = Invoke-Hc ('-PluginsDir "' + $d7 + '" -LogPath "' + $l7 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([string]$r7c.Obj.runtime.status -eq 'UNKNOWN') -and ([string]$r7c.Obj.config.status -eq 'UNKNOWN') -and ([string]$r7c.Obj.claimed_runtime_version.status -eq 'UNKNOWN')) 'metadados ausentes => UNKNOWN' 'presumiu valor'
  Assert-That (([string]$r7c.Obj.evidence_correlation -eq 'NOT_OBSERVED') -and (-not [bool]$r7c.Obj.invocation_proven)) 'sem atestacao: NOT_OBSERVED + invocation false' 'alegou prova'

  # --- 8. redacao: segredo no target nunca vaza; schema legacy intacto ---
  $d8 = Join-Path $base 'c8plug'
  New-PlugDir $d8 @($expA, $expB)
  $l8 = Join-Path $base 'c8.log'
  $secret = 'sk-SYNTHETICSECRET-999'
  [IO.File]::WriteAllLines($l8, @(
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expA + '"'))
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('msg="loading plugin" id="x/' + $expB + '"'))
    (New-LogLine 'aaaaaaaa' '2026-10-10T10:00:00Z' ('FAILED failed to load plugin boom target="https://evil.example/?token=' + $secret + '" ref=err_000aaa'))
  ), (New-Object Text.UTF8Encoding $false))
  $r8 = Invoke-Hc ('-PluginsDir "' + $d8 + '" -LogPath "' + $l8 + '" -ExpectedActive @(''' + $expA + ''',''' + $expB + ''') -DeprecatedAbsent @() -TelemetryPath "' + $noTel + '"')
  Assert-That (([string]$r8.Out -notlike ('*' + $secret + '*'))) 'target arbitrario com segredo redigido' 'vazou segredo'
  $legacy = @('overall', 'plugins', 'deprecated', 'forbidden_leftovers', 'other_files_informational', 'load_errors', 'expected_load_errors', 'load_error_refs', 'telemetry', 'failures', 'warnings')
  $missingLegacy = @()
  foreach ($f in $legacy) {
    if ($null -eq $r8.Obj.PSObject.Properties[$f]) { $missingLegacy += $f }
  }
  Assert-That ((@($missingLegacy).Count -eq 0)) 'schema legacy preservado' ('ausentes: ' + ($missingLegacy -join ','))

  # --- 9. engine do filho == engine atual, reportada em engine.* ---
  $engVer = [string]$r8.Obj.engine.powershell_version
  $engEd = [string]$r8.Obj.engine.edition
  if ($script:childIsCore) {
    Assert-That ((($engVer -notlike '5.*') -and ($engEd -eq 'Core'))) 'filho pwsh: engine reportada Core nao-5' ('ver=' + $engVer + ' ed=' + $engEd)
  } else {
    Assert-That ((($engVer -like '5.*') -and ($engEd -eq 'Desktop'))) 'filho powershell: engine reportada Desktop 5' ('ver=' + $engVer + ' ed=' + $engEd)
  }
}
finally {
  try { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ("TOTAL " + $script:passed + "/" + $script:total)
if ($script:passed -ne $script:total) { exit 1 } else { exit 0 }
