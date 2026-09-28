$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'lib\RuntimeAdapters.ps1'
. $lib
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$repoRegistry = Join-Path $repoRoot 'source\registry\runtimes.json'
$installPs1 = Join-Path $repoRoot 'install.ps1'
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('rt-adapters-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name -- $detail" }
}

function Write-Fixture {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
  [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Invoke-Child {
  param([string]$File, [string]$Arguments, [string]$PathOverride)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $script:repoRoot
  try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  if ($null -ne $PathOverride) {
    $psi.EnvironmentVariables['PATH'] = $PathOverride
  }
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEnd()
  $e = $p.StandardError.ReadToEnd()
  $p.WaitForExit(120000)
  $c = $p.ExitCode
  try { $p.Close() } catch { }
  return @{ Code = $c; Out = ($o + "`n" + $e) }
}

function New-FakeProbe {
  param([Parameter(Mandatory)][string]$PrintCommand)
  return @($script:psExe, '-NoProfile', '-Command', $PrintCommand)
}

try {
  # --- Read-RuntimeRegistry ok ---
  $reg = Read-RuntimeRegistry -RegistryPath $repoRegistry
  Assert-That (($null -ne $reg) -and ($null -ne $reg.runtimes)) 'Read-RuntimeRegistry ok (repo)' 'parse falhou'
  Assert-That ([string]$reg.registry_version -eq '2') 'Read-RuntimeRegistry registry_version=2' ([string]$reg.registry_version)

  # --- Read-RuntimeRegistry ilegivel -> erro claro ---
  $threwMissing = $false
  $msgMissing = ''
  try { Read-RuntimeRegistry -RegistryPath (Join-Path $base 'nao-existe\runtimes.json') | Out-Null } catch { $threwMissing = $true; $msgMissing = $_.Exception.Message }
  Assert-That ($threwMissing) 'Read-RuntimeRegistry ausente lanca' 'nao lancou'
  Assert-That ($msgMissing -like '*ilegivel*') 'Read-RuntimeRegistry ausente: erro claro' $msgMissing
  $badPath = Join-Path $base 'bad\runtimes.json'
  Write-Fixture -Path $badPath -Text '{ invalido,,,'
  $threwBad = $false
  $msgBad = ''
  try { Read-RuntimeRegistry -RegistryPath $badPath | Out-Null } catch { $threwBad = $true; $msgBad = $_.Exception.Message }
  Assert-That ($threwBad) 'Read-RuntimeRegistry malformado lanca' 'nao lancou'
  Assert-That ($msgBad -like '*ilegivel*') 'Read-RuntimeRegistry malformado: erro claro' $msgBad

  # --- Get-RuntimeDescriptor ---
  $d1 = Get-RuntimeDescriptor -Registry $reg -RuntimeId 'opencode-v1'
  Assert-That ([string]$d1.plugin_dependency_spec -eq '@opencode-ai/plugin@1.18.32') 'Get-RuntimeDescriptor opencode-v1 ok' ([string]$d1.plugin_dependency_spec)
  $threwNoId = $false
  try { Get-RuntimeDescriptor -Registry $reg -RuntimeId 'nao-existe' | Out-Null } catch { $threwNoId = $true }
  Assert-That ($threwNoId) 'Get-RuntimeDescriptor ausente lanca' 'nao lancou'
  $unsupPath = Join-Path $base 'unsup\runtimes.json'
  Write-Fixture -Path $unsupPath -Text '{"runtimes":{"fake-x":{"id":"fake-x","supported":false,"validated_version":"0.0.0"}}}'
  $regUnsup = Read-RuntimeRegistry -RegistryPath $unsupPath
  $threwUnsup = $false
  try { Get-RuntimeDescriptor -Registry $regUnsup -RuntimeId 'fake-x' | Out-Null } catch { $threwUnsup = $true }
  Assert-That ($threwUnsup) 'Get-RuntimeDescriptor unsupported lanca' 'nao lancou'

  # --- Get-RuntimeFromVersionOutput ---
  $p1 = Get-RuntimeFromVersionOutput -VersionText '1.18.32'
  Assert-That (([int]$p1.Generation -eq 1) -and ([bool]$p1.Known)) "Get-VersionOutput '1.18.32' => V1" ('gen=' + $p1.Generation)
  $p2 = Get-RuntimeFromVersionOutput -VersionText '2.0.18'
  Assert-That (([int]$p2.Generation -eq 2) -and ([bool]$p2.Known)) "Get-VersionOutput '2.0.18' => V2" ('gen=' + $p2.Generation)
  $p3 = Get-RuntimeFromVersionOutput -VersionText '1.18.33 (build x)'
  Assert-That ([int]$p3.Generation -eq 1) "Get-VersionOutput '1.18.33 (build x)' => V1" ('gen=' + $p3.Generation)
  $p4 = Get-RuntimeFromVersionOutput -VersionText ''
  Assert-That (([int]$p4.Generation -eq 0) -and (-not [bool]$p4.Known)) 'Get-VersionOutput vazio => Unknown' ('gen=' + $p4.Generation)
  $p5 = Get-RuntimeFromVersionOutput -VersionText 'garbage sem numero'
  Assert-That (([int]$p5.Generation -eq 0) -and (-not [bool]$p5.Known)) 'Get-VersionOutput garbage => Unknown' ('gen=' + $p5.Generation)
  $p6 = Get-RuntimeFromVersionOutput -VersionText ("opencode banner`nversao 2.0.18 disponivel`nok")
  Assert-That ([int]$p6.Generation -eq 2) 'Get-VersionOutput multi-linha extrai semver' ('gen=' + $p6.Generation)
  $p7 = Get-RuntimeFromVersionOutput -VersionText '3.0.0'
  Assert-That (([int]$p7.Generation -eq 0) -and (-not [bool]$p7.Known) -and (-not [string]::IsNullOrWhiteSpace([string]$p7.Reason))) "Get-VersionOutput '3.0.0' => Unknown com reason" ('gen=' + $p7.Generation + ' reason=' + $p7.Reason)

  # --- Test-RuntimeSupported ---
  $sup1 = Test-RuntimeSupported -Descriptor $d1
  Assert-That ([bool]$sup1.Supported) 'Test-RuntimeSupported v1 => true' ([string]$sup1.Reason)
  $fakeDesc = New-Object PSObject
  $fakeDesc | Add-Member -NotePropertyName 'supported' -NotePropertyValue $false
  $sup2 = Test-RuntimeSupported -Descriptor $fakeDesc
  Assert-That ((-not [bool]$sup2.Supported) -and (-not [string]::IsNullOrWhiteSpace([string]$sup2.Reason))) 'Test-RuntimeSupported false + reason' ([string]$sup2.Reason)

  # --- Resolve Auto: probe V1 unico -> target v1 ---
  $rA1 = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output '1.18.32'")
  Assert-That (([string]$rA1.Decision -eq 'target') -and ([string]$rA1.RuntimeId -eq 'opencode-v1')) 'Resolve Auto probe V1 => target opencode-v1' ([string]$rA1.Decision + '/' + [string]$rA1.RuntimeId)

  # --- Resolve Auto: probe V2 unico -> target v2 ---
  $rA2 = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output '2.0.18'")
  Assert-That (([string]$rA2.Decision -eq 'target') -and ([string]$rA2.RuntimeId -eq 'opencode-v2')) 'Resolve Auto probe V2 => target opencode-v2' ([string]$rA2.Decision + '/' + [string]$rA2.RuntimeId)

  # --- Resolve Auto: probe Unknown -> unresolved ---
  $rAU = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output 'garbage-no-version'")
  Assert-That ([string]$rAU.Decision -eq 'unresolved') 'Resolve Auto probe Unknown => unresolved' ([string]$rAU.Decision)

  # --- Resolve Auto: probe vazio -> unresolved ---
  $rAE = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output ''")
  Assert-That ([string]$rAE.Decision -eq 'unresolved') 'Resolve Auto probe vazio => unresolved' ([string]$rAE.Decision)

  # --- Resolve Auto: duas versoes -> deterministico (primeira linha com semver vence) ---
  $rA12 = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output '2.0.18','1.18.32'")
  Assert-That (([string]$rA12.Decision -eq 'target') -and ([string]$rA12.RuntimeId -eq 'opencode-v2')) 'Resolve Auto 2 linhas => primeira vence (v2)' ([string]$rA12.Decision + '/' + [string]$rA12.RuntimeId)

  # --- Mode V1 explicito SEM probe -> target sem executar nada ---
  $shimDir = Join-Path $base 'shim'
  New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
  $marker = Join-Path $base 'shim-marker.txt'
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  $shimCmd = Join-Path $shimDir 'opencode.cmd'
  Write-Fixture -Path $shimCmd -Text ('@echo off' + "`n" + 'echo probed > "' + $marker + '"' + "`n" + 'echo 2.0.18' + "`n")
  $savedPath = $env:PATH
  try {
    $env:PATH = $shimDir + ';' + $env:PATH
    $rV1 = Resolve-OpencodeRuntime -Registry $reg -Mode 'V1'
  }
  finally {
    $env:PATH = $savedPath
  }
  Assert-That (([string]$rV1.Decision -eq 'target') -and ([string]$rV1.RuntimeId -eq 'opencode-v1')) 'Resolve V1 explicito sem probe => target' ([string]$rV1.Decision + '/' + [string]$rV1.RuntimeId)
  Assert-That (-not (Test-Path -LiteralPath $marker -PathType Leaf)) 'Resolve V1 explicito nao executou probe (marker ausente)' 'shim foi executado'

  # --- Probe via shim .cmd: Auto resolve V2 (regressao Windows PATH shim) ---
  $shimAutoDir = Join-Path $base 'shim-auto'
  New-Item -ItemType Directory -Path $shimAutoDir -Force | Out-Null
  $shimAutoCmd = Join-Path $shimAutoDir 'opencode.cmd'
  Write-Fixture -Path $shimAutoCmd -Text ('@echo off' + "`n" + 'echo 2.0.18' + "`n")
  $savedPath2 = $env:PATH
  try {
    $env:PATH = $shimAutoDir + ';' + $env:PATH
    $rShim = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand @('opencode', '--version')
  }
  finally {
    $env:PATH = $savedPath2
  }
  Assert-That (([string]$rShim.Decision -eq 'target') -and ([string]$rShim.RuntimeId -eq 'opencode-v2')) 'Resolve Auto via shim .cmd => target opencode-v2' ([string]$rShim.Decision + '/' + [string]$rShim.RuntimeId + ' ' + [string]$rShim.Reason)
  $prExe = Invoke-RuntimeProbe -ProbeCommand (New-FakeProbe "Write-Output '1.18.32'")
  Assert-That (([bool]$prExe.Ok) -and ([string]$prExe.Output -like '*1.18.32*')) 'Invoke-RuntimeProbe powershell.exe direto segue ok' ([string]$prExe.Output + ' ' + [string]$prExe.Reason)

  # --- Mode V1 com probe V2 -> conflict ---
  $rC1 = Resolve-OpencodeRuntime -Registry $reg -Mode 'V1' -ProbeCommand (New-FakeProbe "Write-Output '2.0.18'")
  Assert-That ([string]$rC1.Decision -eq 'conflict') 'Resolve V1 com probe V2 => conflict' ([string]$rC1.Decision)

  # --- Mode V2 com probe V1 -> conflict ---
  $rC2 = Resolve-OpencodeRuntime -Registry $reg -Mode 'V2' -ProbeCommand (New-FakeProbe "Write-Output '1.18.32'")
  Assert-That ([string]$rC2.Decision -eq 'conflict') 'Resolve V2 com probe V1 => conflict' ([string]$rC2.Decision)

  # --- Mode Both -> deferred ---
  $rB = Resolve-OpencodeRuntime -Registry $reg -Mode 'Both'
  Assert-That ([string]$rB.Decision -eq 'deferred') 'Resolve Both => deferred' ([string]$rB.Decision)

  # --- Get-RuntimeAdapterView ---
  $v1 = Get-RuntimeAdapterView -Registry $reg -RuntimeId 'opencode-v1'
  Assert-That ([string]$v1.TemplatePath -eq 'templates/opencode.v1.json.tmpl') 'AdapterView v1 TemplatePath' ([string]$v1.TemplatePath)
  Assert-That ([string]$v1.PluginDependencySpec -eq '@opencode-ai/plugin@1.18.32') 'AdapterView v1 PluginDependencySpec' ([string]$v1.PluginDependencySpec)
  $v2 = Get-RuntimeAdapterView -Registry $reg -RuntimeId 'opencode-v2'
  Assert-That ([string]$v2.PluginDependencySpec -eq '@opencode/plugin@2.0.18') 'AdapterView v2 PluginDependencySpec' ([string]$v2.PluginDependencySpec)
  Assert-That ((@($v2.ManagedConfigKeys).Count -gt 0) -and (-not [string]::IsNullOrWhiteSpace([string]$v2.RendererRoot))) 'AdapterView v2 keys+renderer' ([string]$v2.RendererRoot)
  $threwView = $false
  try { Get-RuntimeAdapterView -Registry $reg -RuntimeId 'nao-existe' | Out-Null } catch { $threwView = $true }
  Assert-That ($threwView) 'AdapterView inexistente lanca' 'nao lancou'
  Assert-That (Test-Path -LiteralPath (Join-Path $repoRoot ([string]$v1.TemplatePath -replace '/', '\')) -PathType Leaf) 'AdapterView v1 TemplatePath existe no repo' ([string]$v1.TemplatePath)
  Assert-That (Test-Path -LiteralPath (Join-Path $repoRoot ([string]$v2.TemplatePath -replace '/', '\')) -PathType Leaf) 'AdapterView v2 TemplatePath existe no repo' ([string]$v2.TemplatePath)

  # --- RuntimesRegistry: invariante de ownership preservada ---
  $names = @($reg.runtimes.PSObject.Properties.Name)
  Assert-That (($names -contains 'opencode') -and ($names -contains 'opencode-v1') -and ($names -contains 'opencode-v2')) 'Registry tem opencode+opencode-v1+opencode-v2' ($names -join ',')
  $ownerSection = $reg.runtimes.opencode.settings_targets[0].sections.'agent.build.permission.task'
  Assert-That ([string]$ownerSection -eq 'control-plane') 'Registry opencode ownership preservada' ([string]$ownerSection)
  Assert-That ([string]$reg.selection.default_runtime -eq 'opencode') 'Registry selection default_runtime=opencode' ([string]$reg.selection.default_runtime)

  # --- Instalador (a): -Runtime V2 -WhatIf -> exit 6 sem tocar nada ---
  $homeA = Join-Path $base 'home-a'
  New-Item -ItemType Directory -Path $homeA -Force | Out-Null
  $ia = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -Runtime V2 -WhatIf -TargetHome "' + $homeA + '"')
  Assert-That ([int]$ia.Code -eq 6) 'Installer -Runtime V2 -WhatIf => exit 6' ('exit=' + $ia.Code + ' out=' + [string]$ia.Out)
  $afterA = @(Get-ChildItem -LiteralPath $homeA -Force -ErrorAction SilentlyContinue)
  Assert-That ($afterA.Count -eq 0) 'Installer -Runtime V2 nao escreveu nada' ('arquivos=' + $afterA.Count)

  # --- Instalador (b): -Runtime Auto sem opencode no PATH -> assume V1 com aviso ---
  $homeB = Join-Path $base 'home-b'
  New-Item -ItemType Directory -Path $homeB -Force | Out-Null
  $emptyDir = Join-Path $base 'empty-path'
  New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
  $ib = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -WhatIf -TargetHome "' + $homeB + '"') -PathOverride $emptyDir
  Assert-That (([string]$ib.Out -like '*assumindo V1*')) 'Installer Auto sem PATH avisa assumindo V1' ([string]$ib.Out)
  Assert-That (([int]$ib.Code -eq 0) -or ([int]$ib.Code -eq 3)) 'Installer Auto sem PATH segue fluxo legado (exit 0/3)' ('exit=' + $ib.Code + ' out=' + [string]$ib.Out)

  # --- Instalador (c): -Runtime V1 -WhatIf -> fluxo legado sem escrita ---
  $homeC = Join-Path $base 'home-c'
  New-Item -ItemType Directory -Path $homeC -Force | Out-Null
  $ic = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -Runtime V1 -WhatIf -TargetHome "' + $homeC + '"')
  Assert-That (([int]$ic.Code -eq 0) -or ([int]$ic.Code -eq 3)) 'Installer -Runtime V1 -WhatIf => exit 0/3' ('exit=' + $ic.Code + ' out=' + [string]$ic.Out)
  Assert-That (([string]$ic.Out).Contains('[install] runtime=V1')) 'Installer -Runtime V1 registra decisao no log' ([string]$ic.Out)
  $afterC = @(Get-ChildItem -LiteralPath $homeC -Force -ErrorAction SilentlyContinue)
  Assert-That ($afterC.Count -eq 0) 'Installer -Runtime V1 -WhatIf nao escreveu nada' ('arquivos=' + $afterC.Count)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
