<#!
.SYNOPSIS
    Runtime Adapter model (Phase 1, V3.1 kernel hardening): leitura declarativa
    do registry dual-runtime e resolucao de geracao OpenCode.
.DESCRIPTION
    Lib dot-sourceable, PS 5.1 compativel (sem ternario, sem ??, sem
    Invoke-Expression). Nao executa nada no dot-source: so define funcoes.
    Os campos template/renderer_root dos descriptors sao METADADOS
    declarativos nesta fase (templates V2 sao criados na Phase 2).
    Fail closed: ambiguidade nunca resolve sozinha.
#>

$ErrorActionPreference = 'Stop'

# Pins de versao NAO vivem nesta lib: vivem em UM registry commitado
# (source/registry/runtime-versions.json), lido pelo loader abaixo. Esta lib
# NUNCA e copiada para perfis (ao contrario de RuntimePortPreflight), logo o
# dot-source por $PSScriptRoot e seguro e explicito.
$RuntimeVersionsLib = Join-Path $PSScriptRoot 'RuntimeVersions.ps1'
if (-not (Test-Path -LiteralPath $RuntimeVersionsLib -PathType Leaf)) {
  throw ('lib de versoes ausente (pin de plugin vem de source/registry/runtime-versions.json): ' + $RuntimeVersionsLib)
}
. $RuntimeVersionsLib

function Get-RuntimePluginPinName([string]$RuntimeId = '') {
  if ([string]$RuntimeId -ceq 'opencode-v1') { return 'plugin_v1' }
  if ([string]$RuntimeId -ceq 'opencode-v2') { return 'plugin_v2' }
  throw ('sem pin de plugin no registry de versoes para o runtime: ' + [string]$RuntimeId)
}

function Get-RuntimePluginDependencySpec {
  param([string]$RuntimeId = '')
  if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
    throw 'runtime descriptor ausente (RuntimeId vazio) para o pin de plugin.'
  }
  $pinName = Get-RuntimePluginPinName -RuntimeId $RuntimeId
  return [string](Get-OrchestrationRuntimeVersion -Name $pinName).Spec
}

function Read-RuntimeRegistry {
  param([string]$RegistryPath = '')
  if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
    # lib vive em scripts/runtime/lib -> repo root = 3 niveis acima
    $root = $here
    try { $root = (Resolve-Path -LiteralPath (Join-Path $here '..\..\..')).Path } catch { }
    $RegistryPath = Join-Path $root 'source\registry\runtimes.json'
  }
  if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw ('runtime registry ilegivel (arquivo ausente): ' + $RegistryPath)
  }
  try {
    $raw = [IO.File]::ReadAllText($RegistryPath, [Text.Encoding]::UTF8)
    $reg = $raw | ConvertFrom-Json
  }
  catch {
    throw ('runtime registry ilegivel (parse falhou): ' + $RegistryPath + ' : ' + $_.Exception.Message)
  }
  if (($null -eq $reg) -or ($null -eq $reg.runtimes)) {
    throw ('runtime registry ilegivel (sem bloco runtimes): ' + $RegistryPath)
  }
  return $reg
}

function Get-RuntimeDescriptor {
  param($Registry, [string]$RuntimeId = '')
  if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
    throw 'runtime descriptor ausente (RuntimeId vazio).'
  }
  if (($null -eq $Registry) -or ($null -eq $Registry.runtimes)) {
    throw 'runtime registry sem bloco runtimes.'
  }
  $names = @($Registry.runtimes.PSObject.Properties.Name)
  if ($names -notcontains $RuntimeId) {
    throw ('runtime descriptor ausente: ' + $RuntimeId)
  }
  $d = $Registry.runtimes.$RuntimeId
  $sup = $false
  try { if ($null -ne $d.supported) { $sup = [bool]$d.supported } } catch { $sup = $false }
  if (-not $sup) {
    throw ('runtime descriptor sem suporte (supported=false): ' + $RuntimeId)
  }
  # Cópia rasa com o pin de plugin resolvido do registry UNICO de versoes
  # (runtimes.json continua sendo a declaracao de runtime/validacao
  # historica; o pin vivo vem de runtime-versions.json). Cópia para nao mutar
  # o objeto do registry recebido pelo chamador.
  $view = [ordered]@{}
  foreach ($p in @($d.PSObject.Properties)) {
    $view[[string]$p.Name] = $p.Value
  }
  $view['plugin_dependency_spec'] = Get-RuntimePluginDependencySpec -RuntimeId $RuntimeId
  return [pscustomobject]$view
}

function Get-RuntimeFromVersionOutput {
  param([string]$VersionText = '')
  $res = @{ Generation = 0; VersionText = $VersionText; Major = 0; Known = $false; Reason = '' }
  if ([string]::IsNullOrWhiteSpace($VersionText)) {
    $res.Reason = 'saida de versao vazia'
    return $res
  }
  $found = $false
  $major = 0
  $lines = @($VersionText -split "`r?`n")
  foreach ($ln in $lines) {
    $m = [regex]::Match($ln, '(\d+)\.(\d+)\.(\d+)')
    if ($m.Success) {
      $found = $true
      $major = [int]$m.Groups[1].Value
      break
    }
  }
  if (-not $found) {
    $res.Reason = 'nenhum token semver x.y.z na saida'
    return $res
  }
  $res.Major = $major
  if ($major -eq 1) {
    $res.Generation = 1
    $res.Known = $true
    $res.Reason = 'major 1 => geracao V1'
    return $res
  }
  if ($major -eq 2) {
    $res.Generation = 2
    $res.Known = $true
    $res.Reason = 'major 2 => geracao V2'
    return $res
  }
  $res.Reason = ('major ' + $major + ' nao reconhecido (esperado 1 ou 2)')
  return $res
}

function Test-RuntimeSupported {
  param($Descriptor)
  $res = @{ Supported = $false; Reason = '' }
  if ($null -eq $Descriptor) {
    $res.Reason = 'descriptor nulo'
    return $res
  }
  $sup = $false
  try { if ($null -ne $Descriptor.supported) { $sup = [bool]$Descriptor.supported } } catch { $sup = $false }
  if (-not $sup) {
    $res.Reason = 'supported=false no descriptor'
    return $res
  }
  $vv = ''
  try { if ($null -ne $Descriptor.validated_version) { $vv = [string]$Descriptor.validated_version } } catch { $vv = '' }
  if ([string]::IsNullOrWhiteSpace($vv)) {
    $res.Reason = 'validated_version ausente no descriptor'
    return $res
  }
  $res.Supported = $true
  $res.Reason = ('supported=true, validated_version=' + $vv)
  return $res
}

function Invoke-RuntimeProbe {
  param([string[]]$ProbeCommand = @('opencode', '--version'), [int]$TimeoutMs = 15000)
  $res = @{ Ok = $false; Output = ''; Reason = ''; TimedOut = $false; ExitCode = -1; ProbeErrorKind = 'probe-failed' }
  if (($null -eq $ProbeCommand) -or ($ProbeCommand.Count -eq 0)) {
    $res.Reason = 'probe command vazio'
    return $res
  }  $file = $ProbeCommand[0]
  $argList = @()
  if ($ProbeCommand.Count -gt 1) { $argList = @($ProbeCommand[1..($ProbeCommand.Count - 1)]) }
  $quotedArgs = @()
  foreach ($a in $argList) {
    $s = [string]$a
    if (($s.Contains(' ')) -or ($s.Contains('"'))) {
      $s = '"' + ($s -replace '"', '\"') + '"'
    }
    $quotedArgs += $s
  }
  $argsLine = ($quotedArgs -join ' ')
  $execFile = $file
  $execArgs = $argsLine
  try {
    # Phase 6 (robustez npm-shim): Get-Command sem -All devolve por
    # precedencia de tipo (ExternalScript .ps1 vence Application .cmd mesmo
    # com o .cmd antes no PATH). Prefere-se o primeiro Application na ordem
    # do PATH (.cmd/.exe executaveis de verdade); dirs npm/V2-probe trazem
    # opencode.ps1 + opencode.cmd lado a lado e o .cmd e o executavel.
    $gc = $null
    try {
      $cands = @(Get-Command -Name $file -All -ErrorAction SilentlyContinue)
      foreach ($cd in $cands) {
        if ($cd.CommandType -eq 'Application') { $gc = $cd; break }
      }
      if (($null -eq $gc) -and ($cands.Count -gt 0)) { $gc = $cands[0] }
    }
    catch { $gc = Get-Command -Name $file -ErrorAction SilentlyContinue }
    if (($null -ne $gc) -and ($gc.CommandType -eq 'Application')) {
      $src = [string]$gc.Source
      if (-not [string]::IsNullOrWhiteSpace($src)) {
        $ext = ''
        try { $ext = [IO.Path]::GetExtension($src).ToLowerInvariant() } catch { $ext = '' }
        if (($ext -eq '.cmd') -or ($ext -eq '.bat')) {
          $qs = $src
          if (($qs.Contains(' ')) -or ($qs.Contains('"'))) {
            $qs = '"' + ($qs -replace '"', '\"') + '"'
          }
          $cmdExe = $env:ComSpec
          if ([string]::IsNullOrWhiteSpace($cmdExe)) { $cmdExe = 'cmd.exe' }
          $execFile = $cmdExe
          # cmd /s /c com aspas externas: sem /s o cmd remove as primeiras/
          # ultimas aspas e caminhos com espaco quebram (finding V31-R1 F6).
          if ([string]::IsNullOrWhiteSpace($argsLine)) { $execArgs = '/s /c "' + $qs + '"' }
          else { $execArgs = '/s /c "' + $qs + ' ' + $argsLine + '"' }
        }
        else {
          $execFile = $src
          $execArgs = $argsLine
        }
      }
    }
  }
  catch { $execFile = $file; $execArgs = $argsLine }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $execFile
  $psi.Arguments = $execArgs
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = [IO.Path]::GetTempPath()
  # FIX CI ps7: filho 5.1 herdaria PSModulePath do host pwsh e perderia
  # autoload dos modulos padrao; fixa para os modulos do 5.1.
  try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  }
  catch {
    $kind = 'probe-failed'
    try {
      $gcMiss = Get-Command -Name $file -ErrorAction SilentlyContinue
      if ($null -eq $gcMiss) { $kind = 'binary-missing' }
    }
    catch { $kind = 'probe-failed' }
    $res.ProbeErrorKind = $kind
    $res.Reason = ('probe nao executou (' + $file + '): ' + $_.Exception.Message)
    return $res
  }
  try {
    $finished = $p.WaitForExit($TimeoutMs)
    if (-not $finished) {
      $res.TimedOut = $true
      try { $p.Kill() } catch { }
      try { $p.WaitForExit(5000) } catch { }
      $res.Reason = ('probe timeout apos ' + $TimeoutMs + 'ms')
      return $res
    }
    $out = ''
    $err = ''
    try { $out = $p.StandardOutput.ReadToEnd() } catch { $out = '' }
    try { $err = $p.StandardError.ReadToEnd() } catch { $err = '' }
    $code = -1
    try { $code = $p.ExitCode } catch { $code = -1 }
    try { $p.Close() } catch { }
    $res.ExitCode = $code
    # Ok exige exit 0 E saida nao-vazia (finding V31-R1 F5): output com
    # exit != 0 e inconclusivo, nunca evidencia de geracao.
    if ($code -ne 0) {
      $res.Reason = ('probe exit code ' + $code + ' (esperado 0)')
      return $res
    }
    $combined = (($out + "`n" + $err).Trim())
    if ([string]::IsNullOrWhiteSpace($combined)) {
      $res.Reason = 'probe sem saida (stdout+stderr vazios)'
      return $res
    }
    $res.Ok = $true
    $res.ProbeErrorKind = 'none'
    $res.Output = $combined
    $res.Reason = 'probe ok'
    return $res
  }
  catch {
    $res.Reason = ('probe falhou: ' + $_.Exception.Message)
    return $res
  }
}

function Resolve-OpencodeRuntime {
  param(
    $Registry,
    [ValidateSet('Auto', 'V1', 'V2', 'Both')]
    [string]$Mode = 'Auto',
    [string[]]$ProbeCommand = @('opencode', '--version')
  )
  $probeBound = $PSBoundParameters.ContainsKey('ProbeCommand')
  if ($Mode -eq 'Both') {
    return @{ Decision = 'deferred'; RuntimeId = $null; Generation = 0; Reason = 'perfis isolados ativam em fase posterior'; ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = '' }
  }
  if (($Mode -eq 'V1') -or ($Mode -eq 'V2')) {
    # NOTA V31-P6-FIX-EXPLICIT: o ramo conflict abaixo existe para CHAMADORES
    # que passam ProbeCommand explicitamente (dupla checagem opt-in). O
    # installer (install.ps1) NAO usa probe para -Runtime explicito: chama sem
    # ProbeCommand e cai no ramo 'explicit always wins (sem probe)' acima.
    $wantGen = 1
    $wantId = 'opencode-v1'
    if ($Mode -eq 'V2') { $wantGen = 2; $wantId = 'opencode-v2' }
    if (-not $probeBound) {
      return @{ Decision = 'target'; RuntimeId = $wantId; Generation = $wantGen; Reason = 'explicit always wins (sem probe)'; ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = '' }
    }
    $pr = Invoke-RuntimeProbe -ProbeCommand $ProbeCommand
    if (-not $pr.Ok) {
      $pk = 'probe-failed'
      try { if (-not [string]::IsNullOrWhiteSpace([string]$pr.ProbeErrorKind)) { $pk = [string]$pr.ProbeErrorKind } } catch { $pk = 'probe-failed' }
      return @{ Decision = 'target'; RuntimeId = $wantId; Generation = $wantGen; Reason = ('explicit always wins; probe indisponivel: ' + $pr.Reason); ProbeError = $true; ProbeErrorKind = $pk; Mode = $Mode; ProbeOutput = '' }
    }
    $parsed = Get-RuntimeFromVersionOutput -VersionText $pr.Output
    if (($parsed.Known) -and ([int]$parsed.Generation -eq $wantGen)) {
      return @{ Decision = 'target'; RuntimeId = $wantId; Generation = $wantGen; Reason = 'explicito confirmado pelo probe'; ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = $pr.Output }
    }
    $gotLabel = 'unknown'
    if ($parsed.Known) { $gotLabel = ('geracao ' + $parsed.Generation) }
    return @{ Decision = 'conflict'; RuntimeId = $null; Generation = 0; Reason = ('conflito: pedido ' + $Mode + ' (geracao ' + $wantGen + ') mas probe indica ' + $gotLabel + ' (' + $parsed.Reason + ')'); ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = $pr.Output }
  }
  # Mode Auto: probe UMA vez.
  $prAuto = Invoke-RuntimeProbe -ProbeCommand $ProbeCommand
  if (-not $prAuto.Ok) {
    $to = ''
    if ($prAuto.TimedOut) { $to = ' (timeout)' }
    $ak = 'probe-failed'
    try { if (-not [string]::IsNullOrWhiteSpace([string]$prAuto.ProbeErrorKind)) { $ak = [string]$prAuto.ProbeErrorKind } } catch { $ak = 'probe-failed' }
    return @{ Decision = 'unresolved'; RuntimeId = $null; Generation = 0; Reason = ('probe indisponivel' + $to + ': ' + $prAuto.Reason); ProbeError = $true; ProbeErrorKind = $ak; Mode = $Mode; ProbeOutput = '' }
  }
  $pa = Get-RuntimeFromVersionOutput -VersionText $prAuto.Output
  if (-not $pa.Known) {
    return @{ Decision = 'unresolved'; RuntimeId = $null; Generation = 0; Reason = ('versao nao reconhecida: ' + $pa.Reason); ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = $prAuto.Output }
  }
  if ([int]$pa.Generation -eq 1) {
    return @{ Decision = 'target'; RuntimeId = 'opencode-v1'; Generation = 1; Reason = 'probe indica geracao V1'; ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = $prAuto.Output }
  }
  return @{ Decision = 'target'; RuntimeId = 'opencode-v2'; Generation = 2; Reason = 'probe indica geracao V2'; ProbeError = $false; ProbeErrorKind = 'none'; Mode = $Mode; ProbeOutput = $prAuto.Output }
}

function Get-RuntimeAdapterView {
  param($Registry, [string]$RuntimeId = '')
  if (($null -eq $Registry) -or ($null -eq $Registry.runtimes)) {
    throw 'runtime registry sem bloco runtimes.'
  }
  $names = @($Registry.runtimes.PSObject.Properties.Name)
  if ($names -notcontains $RuntimeId) {
    throw ('runtime descriptor inexistente: ' + $RuntimeId)
  }
  $d = $Registry.runtimes.$RuntimeId
  $missing = New-Object System.Collections.ArrayList
  $tpl = ''
  $spec = ''
  $roots = @()
  $smoke = ''
  $keys = @()
  $rend = ''
  try { if ($null -ne $d.template) { $tpl = [string]$d.template } } catch { $tpl = '' }
  # Pin de plugin: registry UNICO de versoes (fail-closed; nunca literal).
  try { $spec = Get-RuntimePluginDependencySpec -RuntimeId $RuntimeId } catch { $spec = ''; [void]$missing.Add('plugin_dependency_spec (registry de versoes)') }
  try { if ($null -ne $d.config_roots) { $roots = @($d.config_roots) } } catch { $roots = @() }
  try { if ($null -ne $d.smoke_command) { $smoke = [string]$d.smoke_command } } catch { $smoke = '' }
  try { if ($null -ne $d.managed_config_keys) { $keys = @($d.managed_config_keys) } } catch { $keys = @() }
  try { if ($null -ne $d.renderer_root) { $rend = [string]$d.renderer_root } } catch { $rend = '' }
  if ([string]::IsNullOrWhiteSpace($tpl)) { [void]$missing.Add('template') }
  if ([string]::IsNullOrWhiteSpace($spec)) { [void]$missing.Add('plugin_dependency_spec') }
  if ($roots.Count -eq 0) { [void]$missing.Add('config_roots') }
  if ([string]::IsNullOrWhiteSpace($smoke)) { [void]$missing.Add('smoke_command') }
  if ($keys.Count -eq 0) { [void]$missing.Add('managed_config_keys') }
  if ([string]::IsNullOrWhiteSpace($rend)) { [void]$missing.Add('renderer_root') }
  if ($missing.Count -gt 0) {
    throw ('adapter view incompleta para ' + $RuntimeId + ' (campos ausentes: ' + ($missing -join ', ') + ')')
  }
  return @{
    RuntimeId = $RuntimeId
    TemplatePath = $tpl
    PluginDependencySpec = $spec
    ConfigRoots = $roots
    SmokeCommand = $smoke
    ManagedConfigKeys = $keys
    RendererRoot = $rend
  }
}
