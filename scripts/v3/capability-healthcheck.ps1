<#!
.SYNOPSIS
    Healthcheck base das capabilities do registry V2 (Fase 2A fatia 2, observacional).
.DESCRIPTION
    Le source/registry/capabilities-v2.json e emite um resultado estruturado por
    capability: installed / configured / healthy / managed. Somente leitura:
    nunca escreve, nunca executa rede, nunca altera routing/flags, nunca revela
    secrets (env e testada por NOME; somente booleans presente/ausente saem no
    output; valores jamais sao lidos para output).

    Probes suportados (campo healthcheck.probe do registry):
      repo-file   - target existe sob o RepoRoot (installed); healthy=true se
                    existe (+ verificacao de sidecar sha256 quando
                    integrity_sidecar declarado).
      repo-dir    - target e diretorio sob o RepoRoot com expect_files presentes.
      command     - Get-Command target (installed); 'target --version' com
                    timeout (healthy). Ausente nao e erro: healthy=false.
      mcp-config  - chave mcp.<target> na config viva do usuario
                    (opencode.jsonc preferido, senao opencode.json, somente
                    leitura); configured = env_names presentes (nomes apenas).
                    healthy = installed -and configured. Sem rede.
      mcp-path    - caminho pontilhado sob mcp.* (ex. servers.ai-memory);
                    mesma semantica de configured/healthy do mcp-config.

    Exit: 0 = sondagem concluida (mesmo com capabilities ausentes/doentes);
    2 = fail-closed (registry ausente/ilegivel). PS 5.1 compativel.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$RegistryPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
  $RegistryPath = Join-Path $RepoRoot 'source\registry\capabilities-v2.json'
}

function Read-Utf8Text {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Strip-JsoncComments {
  <#
  .SYNOPSIS
      Parser JSONC tolerante (somente leitura): remove comentarios de linha
      (//), de bloco (/* */) e trailing commas antes de } ou ], ignorando
      conteudo dentro de strings. PS 5.1 compativel.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escaped = $false
  $inLineComment = $false
  $inBlockComment = $false
  $i = 0
  while ($i -lt $Text.Length) {
    $c = $Text[$i]
    $nxt = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { '' }
    if ($inLineComment) {
      if ($c -eq "`n") { $inLineComment = $false; [void]$sb.Append($c) }
      $i++; continue
    }
    if ($inBlockComment) {
      if (($c -eq '*') -and ($nxt -eq '/')) { $inBlockComment = $false; $i += 2; continue }
      if ($c -eq "`n") { [void]$sb.Append($c) }
      $i++; continue
    }
    if ($inString) {
      [void]$sb.Append($c)
      if ($escaped) { $escaped = $false }
      elseif ($c -eq '\') { $escaped = $true }
      elseif ($c -eq '"') { $inString = $false }
      $i++; continue
    }
    if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
    if (($c -eq '/') -and ($nxt -eq '/')) { $inLineComment = $true; $i += 2; continue }
    if (($c -eq '/') -and ($nxt -eq '*')) { $inBlockComment = $true; $i += 2; continue }
    [void]$sb.Append($c); $i++
  }
  return (Remove-TrailingCommas -Text $sb.ToString())
}

function Remove-TrailingCommas {
  <#
  .SYNOPSIS
      Remove virgulas pendentes antes de } ou ] fora de strings.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Text)
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escaped = $false
  $i = 0
  while ($i -lt $Text.Length) {
    $c = $Text[$i]
    if ($inString) {
      [void]$sb.Append($c)
      if ($escaped) { $escaped = $false }
      elseif ($c -eq '\') { $escaped = $true }
      elseif ($c -eq '"') { $inString = $false }
      $i++; continue
    }
    if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
    if ($c -eq ',') {
      $j = $i + 1
      while (($j -lt $Text.Length) -and ([string]$Text[$j] -match '\s')) { $j++ }
      if (($j -lt $Text.Length) -and (([string]$Text[$j] -ceq '}') -or ([string]$Text[$j] -ceq ']'))) {
        $i++; continue
      }
      [void]$sb.Append($c); $i++; continue
    }
    [void]$sb.Append($c); $i++
  }
  return $sb.ToString()
}

function Invoke-VersionProbe {
  <#
  .SYNOPSIS
      Roda '<exe> --version' com timeout, sem herdar segredos no output capturado.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Exe, [int]$TimeoutSeconds = 15)
  if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 1 }
  if ($TimeoutSeconds -gt 120) { $TimeoutSeconds = 120 }
  try {
    $exePath = $Exe
    $args = '--version'
    try {
      $resolved = (Get-Command $Exe -ErrorAction SilentlyContinue)
      if (($null -ne $resolved) -and (-not [string]::IsNullOrWhiteSpace([string]$resolved.Source))) {
        $exePath = [string]$resolved.Source
      }
    }
    catch { }
    $ext = ''
    try { $ext = ([IO.Path]::GetExtension($exePath)).ToLowerInvariant() } catch { $ext = '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($ext -ceq '.ps1') {
      $psi.FileName = 'powershell'
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $exePath + '" --version'
    }
    elseif (($ext -ceq '.cmd') -or ($ext -ceq '.bat')) {
      $psi.FileName = 'cmd.exe'
      $psi.Arguments = '/c ""' + $exePath + '" --version"'
    }
    else {
      $psi.FileName = $exePath
      $psi.Arguments = $args
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($psi.WorkingDirectory)) { $psi.WorkingDirectory = $RepoRoot }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $p) { return @{ ok = $false; note = 'processo nao iniciou' } }
    $finished = $p.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
      try { $p.Kill() } catch { }
      return @{ ok = $false; note = 'timeout' }
    }
    if ($p.ExitCode -eq 0) { return @{ ok = $true; note = 'exit 0' } }
    return @{ ok = $false; note = ('exit ' + $p.ExitCode) }
  }
  catch {
    return @{ ok = $false; note = 'excecao ao sondar' }
  }
}

function Get-UserMcpPathConfigured {
  <#
  .SYNOPSIS
      Verifica presenca de um caminho pontilhado sob mcp.* na config viva
      (somente leitura). Ex.: path 'servers.ai-memory' resolve
      mcp.servers.'ai-memory'. Retorna @{ found; path; unreadable } como
      Get-UserMcpConfigured.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$McpPath)
  $cfgDir = Join-Path $HOME '.config\opencode'
  $unreadable = @()
  foreach ($leaf in @('opencode.jsonc', 'opencode.json')) {
    $full = Join-Path $cfgDir $leaf
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    try {
      $raw = Strip-JsoncComments -Text (Read-Utf8Text -Path $full)
      $doc = $raw | ConvertFrom-Json
      $node = $doc.mcp
      $ok = ($null -ne $node)
      if ($ok) {
        foreach ($seg in @(([string]$McpPath -split '\.'))) {
          if (($null -ne $node) -and ($null -ne $node.PSObject.Properties[$seg])) { $node = $node.$seg }
          else { $ok = $false; break }
        }
      }
      if ($ok) { return @{ found = $true; path = $leaf; unreadable = $unreadable } }
      return @{ found = $false; path = $leaf; unreadable = $unreadable }
    }
    catch {
      $unreadable += $leaf
      continue
    }
  }
  return @{ found = $false; path = ''; unreadable = $unreadable }
}

function Get-UserMcpConfigured {
  <#
  .SYNOPSIS
      Verifica presenca da chave mcp.<name> na config viva (somente leitura).
      Retorna @{ found = <bool>; path = <config usada ou ''>; unreadable = <configs
      existentes que nao parsearam mesmo com o parser tolerante> }. Quando um
      arquivo de maior precedencia existe mas e ilegivel, ele e listado em
      unreadable em vez de haver fallback silencioso para o alternativo.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$McpName)
  $cfgDir = Join-Path $HOME '.config\opencode'
  $unreadable = @()
  foreach ($leaf in @('opencode.jsonc', 'opencode.json')) {
    $full = Join-Path $cfgDir $leaf
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    try {
      $raw = Strip-JsoncComments -Text (Read-Utf8Text -Path $full)
      $doc = $raw | ConvertFrom-Json
      if (($null -ne $doc) -and ($null -ne $doc.mcp) -and ($null -ne $doc.mcp.PSObject.Properties[$McpName])) {
        return @{ found = $true; path = $leaf; unreadable = $unreadable }
      }
      return @{ found = $false; path = $leaf; unreadable = $unreadable }
    }
    catch {
      $unreadable += $leaf
      continue
    }
  }
  return @{ found = $false; path = ''; unreadable = $unreadable }
}

function Test-SidecarIntegrity {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$BundleFull, [Parameter(Mandatory)][string]$SidecarFull)
  try {
    if (-not (Test-Path -LiteralPath $BundleFull -PathType Leaf)) { return @{ ok = $false; note = 'bundle ausente' } }
    if (-not (Test-Path -LiteralPath $SidecarFull -PathType Leaf)) { return @{ ok = $false; note = 'sidecar ausente' } }
    $hex = ([IO.File]::ReadAllText($SidecarFull, [Text.Encoding]::UTF8)).Trim()
    if ($hex -notmatch '^[0-9a-fA-F]{64}$') { return @{ ok = $false; note = 'sidecar com formato invalido' } }
    $h = ((Get-FileHash -LiteralPath $BundleFull -Algorithm SHA256).Hash).ToLowerInvariant()
    if ($hex.ToLowerInvariant() -ceq $h) { return @{ ok = $true; note = 'sha256 casa' } }
    return @{ ok = $false; note = 'sidecar diverge do bundle' }
  }
  catch {
    return @{ ok = $false; note = 'excecao na verificacao' }
  }
}

if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
  [Console]::Error.WriteLine('capabilities-v2.json ausente: ' + $RegistryPath)
  exit 2
}
$reg = $null
try {
  $reg = (Read-Utf8Text -Path $RegistryPath) | ConvertFrom-Json
}
catch {
  [Console]::Error.WriteLine('capabilities-v2.json ilegivel: ' + $_.Exception.Message)
  exit 2
}
if (($null -eq $reg) -or ($null -eq $reg.capabilities)) {
  [Console]::Error.WriteLine('capabilities-v2.json sem bloco capabilities')
  exit 2
}

$results = @()
foreach ($cap in @($reg.capabilities)) {
  $id = [string]$cap.id
  $probe = ''
  try { $probe = [string]$cap.healthcheck.probe } catch { $probe = '' }
  $target = ''
  try { $target = [string]$cap.healthcheck.target } catch { $target = '' }
  $timeout = 15
  try { $timeout = [int]$cap.healthcheck.timeout_seconds } catch { $timeout = 15 }
  $managed = $false
  try { $managed = (([string]$cap.managed_by) -ceq 'control-plane') } catch { $managed = $false }

  $installed = $false
  $configured = $false
  $healthy = $false
  $detail = ''

  if ($probe -ceq 'repo-file') {
    $full = Join-Path $RepoRoot ($target -replace '/', '\')
    $installed = (Test-Path -LiteralPath $full -PathType Leaf)
    $configured = $installed
    $healthy = $installed
    $detail = 'arquivo no repo: ' + $target
    $sidecar = ''
    try { $sidecar = [string]$cap.healthcheck.integrity_sidecar } catch { $sidecar = '' }
    if ($installed -and (-not [string]::IsNullOrWhiteSpace($sidecar))) {
      $chk = Test-SidecarIntegrity -BundleFull $full -SidecarFull (Join-Path $RepoRoot ($sidecar -replace '/', '\'))
      $healthy = [bool]$chk.ok
      $detail = $detail + '; integridade: ' + [string]$chk.note
    }
  }
  elseif ($probe -ceq 'repo-dir') {
    $full = Join-Path $RepoRoot ($target -replace '/', '\')
    $expect = @()
    try { foreach ($e in @($cap.healthcheck.expect_files)) { $expect += [string]$e } } catch { $expect = @() }
    $missing = @()
    if (Test-Path -LiteralPath $full -PathType Container) {
      foreach ($e in $expect) {
        if (-not (Test-Path -LiteralPath (Join-Path $full ($e -replace '/', '\')))) { $missing += $e }
      }
      $installed = ($missing.Count -eq 0)
    }
    $configured = $installed
    $healthy = $installed
    if ($missing.Count -gt 0) { $detail = 'ausentes em ' + $target + ': ' + ($missing -join ', ') }
    else { $detail = 'diretorio no repo com ' + $expect.Count + ' esperado(s): ' + $target }
  }
  elseif ($probe -ceq 'command') {
    $cmd = (Get-Command $target -ErrorAction SilentlyContinue)
    $installed = ($null -ne $cmd)
    $configured = $installed
    if ($installed) {
      $vr = Invoke-VersionProbe -Exe $target -TimeoutSeconds $timeout
      $healthy = [bool]$vr.ok
      $detail = 'CLI presente; --version: ' + [string]$vr.note
    }
    else {
      $detail = 'CLI ausente no PATH: ' + $target
    }
  }
  elseif ($probe -ceq 'mcp-config') {
    $mc = Get-UserMcpConfigured -McpName $target
    $installed = [bool]$mc.found
    $envNames = @()
    try { foreach ($e in @($cap.healthcheck.env_names)) { $envNames += [string]$e } } catch { $envNames = @() }
    $present = @()
    $absent = @()
    foreach ($n in $envNames) {
      # Presenca por NOME apenas; o valor jamais e lido para output.
      if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($n))) { $absent += $n }
      else { $present += $n }
    }
    if ($envNames.Count -eq 0) { $configured = $installed }
    else { $configured = ($installed -and ($absent.Count -eq 0)) }
    $healthy = ($installed -and $configured)
    $detail = 'mcp.' + $target + ' na config: ' + [string]$mc.path
    if (@($mc.unreadable).Count -gt 0) {
      $detail = $detail + '; config ilegivel (sem fallback silencioso): ' + ((@($mc.unreadable)) -join ',')
    }
    if ($envNames.Count -gt 0) {
      $detail = $detail + '; env presentes: ' + $present.Count + '; ausentes: ' + ($absent -join ',')
    }
  }
  elseif ($probe -ceq 'mcp-path') {
    $mc = Get-UserMcpPathConfigured -McpPath $target
    $installed = [bool]$mc.found
    $envNames = @()
    try { foreach ($e in @($cap.healthcheck.env_names)) { $envNames += [string]$e } } catch { $envNames = @() }
    $present = @()
    $absent = @()
    foreach ($n in $envNames) {
      # Presenca por NOME apenas; o valor jamais e lido para output.
      if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($n))) { $absent += $n }
      else { $present += $n }
    }
    if ($envNames.Count -eq 0) { $configured = $installed }
    else { $configured = ($installed -and ($absent.Count -eq 0)) }
    $healthy = ($installed -and $configured)
    $detail = 'mcp.' + $target + ' na config: ' + [string]$mc.path
    if (@($mc.unreadable).Count -gt 0) {
      $detail = $detail + '; config ilegivel (sem fallback silencioso): ' + ((@($mc.unreadable)) -join ',')
    }
    if ($envNames.Count -gt 0) {
      $detail = $detail + '; env presentes: ' + $present.Count + '; ausentes: ' + ($absent -join ',')
    }
  }
  else {
    $detail = 'probe desconhecido: ' + $probe
  }

  $results += [ordered]@{
    id         = $id
    installed  = [bool]$installed
    configured = [bool]$configured
    healthy    = [bool]$healthy
    managed    = [bool]$managed
    probe      = $probe
    detail     = $detail
  }
}

$envelope = [ordered]@{
  schema_version = 1
  generated_at   = ((Get-Date).ToUniversalTime().ToString('o'))
  registry       = 'source/registry/capabilities-v2.json'
  results        = @($results)
}

if ($Json) {
  $envelope | ConvertTo-Json -Depth 6 -Compress | Write-Output
  exit 0
}

foreach ($r in @($results)) {
  $flag = 'OK'
  if (-not ([bool]$r.healthy)) { $flag = 'MISS' }
  Write-Host ($flag + ' ' + [string]$r.id + ' installed=' + [string]$r.installed + ' configured=' + [string]$r.configured + ' healthy=' + [string]$r.healthy + ' managed=' + [string]$r.managed + ' -- ' + [string]$r.detail)
}
exit 0
