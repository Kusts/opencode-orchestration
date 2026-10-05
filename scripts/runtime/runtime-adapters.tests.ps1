$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'lib\RuntimeAdapters.ps1'
. $lib
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
# Pins vem do registry unico (source/registry/runtime-versions.json), nunca de
# literal neste arquivo de teste. Fixtures sinteticas de versao nao mudam.
. (Join-Path $repoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
$pinV1 = Get-OrchestrationRuntimeVersion -Name v1 -RepoRoot $repoRoot
$pinV2 = Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $repoRoot
$pinPluginV1 = Get-OrchestrationRuntimeVersion -Name plugin_v1 -RepoRoot $repoRoot
$pinPluginV2 = Get-OrchestrationRuntimeVersion -Name plugin_v2 -RepoRoot $repoRoot
$pinBun = Get-OrchestrationRuntimeVersion -Name bun -RepoRoot $repoRoot
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

  # --- RuntimeVersions: registry unico + fail-closed (sem fallback literal) ---
  $pinShaped = $true
  foreach ($pinCase in @($pinV1, $pinV2, $pinPluginV1, $pinPluginV2, $pinBun)) {
    if (([string]$pinCase.spec -cne ([string]$pinCase.package + '@' + [string]$pinCase.version)) -or [string]::IsNullOrWhiteSpace([string]$pinCase.version)) { $pinShaped = $false }
  }
  Assert-That $pinShaped 'RuntimeVersions: spec == package@version em todos os pins' 'campo divergente/vazio'
  $pinRoot = Join-Path $base 'sem-registry'
  New-Item -ItemType Directory -Path $pinRoot -Force | Out-Null
  $pinThrewMissing = $false
  $pinMsgMissing = ''
  try { Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $pinRoot | Out-Null } catch { $pinThrewMissing = $true; $pinMsgMissing = $_.Exception.Message }
  Assert-That (($pinThrewMissing) -and ($pinMsgMissing -like '*ausente*')) 'RuntimeVersions: registry ausente lanca (fail-closed, sem default)' $pinMsgMissing
  $pinBadRoot = Join-Path $base 'bad-versions'
  Write-Fixture -Path (Join-Path $pinBadRoot 'source\registry\runtime-versions.json') -Text '{ nao e json'
  $pinThrewBad = $false
  $pinMsgBad = ''
  try { Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $pinBadRoot | Out-Null } catch { $pinThrewBad = $true; $pinMsgBad = $_.Exception.Message }
  Assert-That (($pinThrewBad) -and ($pinMsgBad -like '*ilegivel*')) 'RuntimeVersions: JSON invalido lanca (fail-closed)' $pinMsgBad
  $pinDriftRoot = Join-Path $base 'drift-versions'
  Write-Fixture -Path (Join-Path $pinDriftRoot 'source\registry\runtime-versions.json') -Text '{"schema_version":1,"runtimes":{"v2":{"package":"@opencode/cli","version":"2.0.23","spec":"@opencode/cli@1.0.0"}}}'
  $pinThrewDrift = $false
  $pinMsgDrift = ''
  try { Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $pinDriftRoot | Out-Null } catch { $pinThrewDrift = $true; $pinMsgDrift = $_.Exception.Message }
  Assert-That (($pinThrewDrift) -and ($pinMsgDrift -like '*inconsistente*')) 'RuntimeVersions: spec divergente do par lanca (drift)' $pinMsgDrift
  $pinThrewName = $false
  try { Get-OrchestrationRuntimeVersion -Name 'v9' -RepoRoot $repoRoot | Out-Null } catch { $pinThrewName = $true }
  Assert-That $pinThrewName 'RuntimeVersions: nome desconhecido recusado' 'aceitou nome invalido'

  # RR-VERSIONS-REGISTRY-FIX3: semver ESTRITO. '01.2.3'/'1.02.3' (zero a
  # esquerda), '1.2.3-..' (prerelease vazio) e "1.2.3`n" (LF final, que '^...$'
  # em .NET aceitaria) nao sao pins revisados => fail closed. 'latest'/'1.x'
  # ja eram barrados pelo formato fechado do FIX2 e seguem barrados.
  # RR-VERSIONS-REGISTRY-FIX4: \d em .NET casa digito UNICODE (categoria Nd),
  # nao so '0'-'9' -- entao '1' + U+0662 + '.2.3' e '1.2.3-1' + U+0662
  # (arabic-indic digit) casavam na regex como se fossem pins revisados, o
  # mesmo buraco que '^...$' abria com LF final. Montado por code point para o
  # .ps1 continuar ASCII: PS 5.1 le .ps1 sem BOM como ANSI e corromperia um
  # literal UTF-8, fazendo o teste passar pelo motivo errado. O host ve de fato
  # U+0662 em PS 5.1 e pwsh.
  $badUnicodeDigit = [string][char]0x0662
  $badPinIdx = 0
  foreach ($badVer in @('01.2.3', '1.02.3', '1.2.3-..', "1.2.3`n", 'latest', '1.x', ('1' + $badUnicodeDigit + '.2.3'), ('1.2.3-1' + $badUnicodeDigit))) {
    $badPinIdx++
    $badRoot = Join-Path $base ('bad-ver-' + $badPinIdx)
    $badJson = '{"schema_version":1,"runtimes":{"v2":{"package":"@opencode/cli","version":"' + ($badVer -replace "`n", '\n') + '","spec":"@opencode/cli@' + ($badVer -replace "`n", '\n') + '"}}}'
    Write-Fixture -Path (Join-Path $badRoot 'source\registry\runtime-versions.json') -Text $badJson
    $badThrew = $false
    $badMsg = ''
    try { Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $badRoot | Out-Null } catch { $badThrew = $true; $badMsg = $_.Exception.Message }
    $badLabel = ($badVer -replace "`n", '\n')
    Assert-That (($badThrew) -and ($badMsg -like '*fora do semver exato*')) "RuntimeVersions: version '$badLabel' rejeitada (semver estrito)" $badMsg
  }
  # Controle positivo: o pin real do registry e um prerelease valido tem de
  # passar pela MESMA regex (a correcao nao pode virar faz-tudo-negativo).
  foreach ($goodVer in @('2.0.23', '2.0.23-beta.1')) {
    $goodRoot = Join-Path $base ('ok-ver-' + ($goodVer -replace '[^a-zA-Z0-9]', '-'))
    $goodJson = '{"schema_version":1,"runtimes":{"v2":{"package":"@opencode/cli","version":"' + $goodVer + '","spec":"@opencode/cli@' + $goodVer + '"}}}'
    Write-Fixture -Path (Join-Path $goodRoot 'source\registry\runtime-versions.json') -Text $goodJson
    $goodGot = ''
    $goodOk = $false
    try { $goodGot = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $goodRoot).version; $goodOk = ($goodGot -ceq $goodVer) } catch { $goodOk = $false }
    Assert-That $goodOk "RuntimeVersions: version '$goodVer' aceita (controle positivo)" $goodGot
  }

  # --- Get-RuntimeDescriptor ---
  $d1 = Get-RuntimeDescriptor -Registry $reg -RuntimeId 'opencode-v1'
  Assert-That ([string]$d1.plugin_dependency_spec -eq [string]$pinPluginV1.Spec) 'Get-RuntimeDescriptor opencode-v1 ok (pin do registry)' ([string]$d1.plugin_dependency_spec)
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
  Assert-That ([string]$v1.PluginDependencySpec -eq [string]$pinPluginV1.Spec) 'AdapterView v1 PluginDependencySpec (pin do registry)' ([string]$v1.PluginDependencySpec)
  $v2 = Get-RuntimeAdapterView -Registry $reg -RuntimeId 'opencode-v2'
  Assert-That ([string]$v2.PluginDependencySpec -eq [string]$pinPluginV2.Spec) 'AdapterView v2 PluginDependencySpec (pin do registry)' ([string]$v2.PluginDependencySpec)
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

  # --- Instalador (a): -Runtime V2 -WhatIf -> plano V2 sem escrita (Phase 6 ativa) ---
  $homeA = Join-Path $base 'home-a'
  New-Item -ItemType Directory -Path $homeA -Force | Out-Null
  $emptyA = Join-Path $base 'empty-a'
  New-Item -ItemType Directory -Path $emptyA -Force | Out-Null
  $ia = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -Runtime V2 -WhatIf -TargetHome "' + $homeA + '"') -PathOverride $emptyA
  Assert-That ([int]$ia.Code -eq 0) 'Installer -Runtime V2 -WhatIf => exit 0' ('exit=' + $ia.Code + ' out=' + [string]$ia.Out)
  Assert-That (([string]$ia.Out -like '*runtime=V2*')) 'Installer -Runtime V2 registra decisao no log' ([string]$ia.Out)
  Assert-That (([string]$ia.Out -like '*INSTALL PLAN*')) 'Installer -Runtime V2 -WhatIf imprime plano' ([string]$ia.Out)
  $afterA = @(Get-ChildItem -LiteralPath $homeA -Force -ErrorAction SilentlyContinue)
  Assert-That ($afterA.Count -eq 0) 'Installer -Runtime V2 -WhatIf nao escreveu nada' ('arquivos=' + $afterA.Count)

  # --- Instalador (a2): V31-P6-FIX-EXPLICIT: -Runtime V2 -WhatIf com V1 global no PATH => exit 0 (explicit wins, sem probe) ---
  $homeA2 = Join-Path $base 'home-a2'
  New-Item -ItemType Directory -Path $homeA2 -Force | Out-Null
  $shimV1Dir = Join-Path $base 'shim-v1-global'
  New-Item -ItemType Directory -Path $shimV1Dir -Force | Out-Null
  Write-Fixture -Path (Join-Path $shimV1Dir 'opencode.cmd') -Text ('@echo off' + "`n" + 'echo 1.18.32' + "`n")
  $ia2 = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -Runtime V2 -WhatIf -TargetHome "' + $homeA2 + '"') -PathOverride $shimV1Dir
  Assert-That ([int]$ia2.Code -eq 0) 'Installer -Runtime V2 -WhatIf com V1 global => exit 0 (explicit wins)' ('exit=' + $ia2.Code + ' out=' + [string]$ia2.Out)
  Assert-That (([string]$ia2.Out -like '*runtime=V2*')) 'Installer -Runtime V2 com V1 global registra runtime=V2' ([string]$ia2.Out)
  Assert-That (([string]$ia2.Out -like '*INSTALL PLAN*')) 'Installer -Runtime V2 com V1 global imprime plano' ([string]$ia2.Out)
  $afterA2 = @(Get-ChildItem -LiteralPath $homeA2 -Force -ErrorAction SilentlyContinue)
  Assert-That ($afterA2.Count -eq 0) 'Installer -Runtime V2 com V1 global nao escreveu nada' ('arquivos=' + $afterA2.Count)

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

  # --- V31-R1 F5: probe com exit != 0 e output valida => inconclusivo ---
  $prBadExit = Invoke-RuntimeProbe -ProbeCommand (New-FakeProbe "Write-Output '1.18.32'; exit 5")
  Assert-That ((-not [bool]$prBadExit.Ok)) 'Probe exit != 0 => Ok=false' ('Ok=' + $prBadExit.Ok + ' reason=' + [string]$prBadExit.Reason)
  Assert-That ([string]$prBadExit.ProbeErrorKind -eq 'probe-failed') 'Probe exit != 0 => kind probe-failed' ([string]$prBadExit.ProbeErrorKind)
  $rBadExit = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand (New-FakeProbe "Write-Output '1.18.32'; exit 5")
  Assert-That (([string]$rBadExit.Decision -eq 'unresolved') -and ([bool]$rBadExit.ProbeError)) 'Resolve Auto probe exit != 0 => unresolved+ProbeError' ([string]$rBadExit.Decision)

  # --- V31-R1 F1: kinds discriminaveis na decisao ---
  $rMiss = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand @('__missing-opencode-binary__')
  Assert-That (([bool]$rMiss.ProbeError) -and ([string]$rMiss.ProbeErrorKind -eq 'binary-missing')) 'Resolve Auto binario ausente => kind binary-missing' ([string]$rMiss.ProbeErrorKind + ' ' + [string]$rMiss.Reason)

  # --- V31-R1 F6: shim em diretorio com espaco resolve ---
  $spaceDir = Join-Path $base 'dir com espaco'
  New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null
  Write-Fixture -Path (Join-Path $spaceDir 'opencode.cmd') -Text ('@echo off' + "`n" + 'echo 2.0.18' + "`n")
  $savedPath3 = $env:PATH
  try {
    $env:PATH = $spaceDir + ';' + $env:PATH
    $rSpace = Resolve-OpencodeRuntime -Registry $reg -Mode 'Auto' -ProbeCommand @('opencode', '--version')
  }
  finally {
    $env:PATH = $savedPath3
  }
  Assert-That (([string]$rSpace.Decision -eq 'target') -and ([string]$rSpace.RuntimeId -eq 'opencode-v2')) 'Resolve Auto via shim com espaco => target opencode-v2' ([string]$rSpace.Decision + '/' + [string]$rSpace.RuntimeId + ' ' + [string]$rSpace.Reason)

  # --- V31-R1 F1a: installer Auto + binario presente + probe lixo/falha => exit 6 ---
  $homeD = Join-Path $base 'home-d'
  New-Item -ItemType Directory -Path $homeD -Force | Out-Null
  $shimFailDir = Join-Path $base 'shim-fail'
  New-Item -ItemType Directory -Path $shimFailDir -Force | Out-Null
  Write-Fixture -Path (Join-Path $shimFailDir 'opencode.cmd') -Text ('@echo off' + "`n" + 'echo garbage-no-version' + "`n" + 'exit /b 3' + "`n")
  $iD = Invoke-Child -File $psExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $installPs1 + '" -WhatIf -TargetHome "' + $homeD + '"') -PathOverride $shimFailDir
  Assert-That ([int]$iD.Code -eq 6) 'Installer Auto binario presente + probe falho => exit 6' ('exit=' + $iD.Code + ' out=' + [string]$iD.Out)
  Assert-That (([string]$iD.Out -like '*inconclusivo*')) 'Installer Auto probe falho avisa inconclusivo' ([string]$iD.Out)
  $afterD = @(Get-ChildItem -LiteralPath $homeD -Force -ErrorAction SilentlyContinue)
  Assert-That ($afterD.Count -eq 0) 'Installer Auto probe falho nao escreveu nada' ('arquivos=' + $afterD.Count)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
