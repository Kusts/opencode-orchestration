<#!
.SYNOPSIS
    Helper de subprocesso isolado para spikes/smokes V2 (Phase 5/8, V3.1).
.DESCRIPTION
    Lib dot-sourceable, PS 5.1 e PS7 compativel (sem ternario, sem ??, sem
    Invoke-Expression). Nao executa nada no dot-source alem de registrar o
    coletor C# (Add-Type, uma vez por sessao): so define funcoes.

    Propriedades garantidas (so fatos implementados; sem claim alem do codigo):
      - exit code verdadeiro do processo (nunca marcador echo %ERRORLEVEL%);
      - drenos limitados via coletor C# (SpikeDrain.DrainBounded): cada stream
        e lido em fatias ate EOF, teto de chars ou deadline propria; apos
        timeout+kill ou root saido com descendente segurando o pipe, o dreno
        nao bloqueia alem do deadline (DrainIncomplete=true; nunca .Result
        cego). Pico de memoria limitado pelo teto;
      - stdin: por padrao redirecionado e fechado de imediato; com -StdinNul
        o filho recebe o dispositivo NUL (via camada cmd com validacao
        conservadora). NUL e obrigatorio para CLIs bun/Node cujo servico
        herda o pipe de stdin e nunca ve EOF no pipe fechado (observado:
        `debug agents` do V2 2.0.18 trava 30s com stdin fechado e responde
        em ~175ms com `< NUL`; evidenciado em sonda dedicada);
      - ambiente e cwd sao SOMENTE do filho (ProcessStartInfo); com
        -CleanEnvironment o filho recebe SO allowlist de runtime do SO
        (PATH/SystemRoot/WINDIR/ComSpec/PATHEXT/TEMP/TMP + PSModulePath quando
        presente no pai) mais o EnvSet do chamador: nenhuma API key, flag
        OPENCODE_* ou token herdado por acidente. Sem o switch, vale a
        semantica herdada + EnvSet/EnvRemove;
      - stdin fechado de imediato; close/dispose do processo em finally;
      - ArgumentList como array com quoting de exe nativo Windows
        (regras CommandLineToArgvW: aspas escapadas, backslashes finais
        dobrados); sem shell injection;
      - shims .cmd/.bat: prefere resolver o .exe real (padrao de shim npm
        "%dp0%\..\caminho\bin.exe"); se irresoluvel, so aceita via
        'cmd /d /s /c' quando caminho e args passam na validacao conservadora
        (rejeita & | < > ^ % ! " ' ( ) ; $ ` e quebras de linha); caso
        contrario recusa sem executar (Started=false);
      - versao estrita compartilhada (Test-SpikeExactVersion): linha exata
        'opencode v<V>' (rejeita 2.0.180, -beta e mencao arbitraria);
      - raizes por-run (New/Remove-SpikeRunChild): filho unico sob base do
        chamador, recusa sobrescrita (sentinela), remocao confinada a base;
      - parada de servico com gates (Invoke-SpikeServiceStopIfOwned): so para
        servico provado (isolamento + porta configurada + warmup) e verificado
        no mesmo endpoint privado via status; nunca toca servico global;
      - RR-P22-JOB-OBJECTS: Invoke-SpikeChild aceita -JobObject OPCIONAL
        (objeto da lib RuntimeJobObject). Presente => o filho e atribuido ao
        job imediatamente apos o start e o resultado carrega JobAssigned /
        JobNote. Ausente => comportamento IDENTICO ao anterior (JobAssigned
        =false, JobNote ='' em todos os retornos, shape estavel para todos os
        chamadores). A lib nao e carregada por este arquivo: sem ela e sem
        -JobObject nada muda; com -JobObject e sem lib => falha honesta
        (JobAssigned=false, JobNote com o motivo), nunca excecao.
      - TreeKill (novo): no TIMEOUT, cleanup NUNCA por arvore de PID historico.
        Com atribuicao provada a arvore morre por KILL_ON_JOB_CLOSE
        (descendentes por heranca, mais forte que /T) => TreeKill='job'. Sem
        job, so o root e encerrado pelo handle do spawn PROPRIO =>
        TreeKill='root-only' (descendentes podem escapar; sem claim de tree
        kill). TreeKill='none' quando nao houve timeout ou o start falhou.
#>

$ErrorActionPreference = 'Stop'

$SpikeDrainCs = @'
using System;
using System.IO;
using System.Threading.Tasks;
using System.Diagnostics;
public static class SpikeDrain {
  public sealed class BoundedResult {
    public string Text;
    public bool Truncated;
    public bool Complete;
  }
  public static BoundedResult DrainBounded(StreamReader reader, int capChars, int timeoutMs) {
    BoundedResult r = new BoundedResult();
    r.Text = "";
    r.Truncated = false;
    r.Complete = false;
    if (reader == null || capChars <= 0 || timeoutMs <= 0) return r;
    int startCap = capChars < 8192 ? capChars : 8192;
    System.Text.StringBuilder sb = new System.Text.StringBuilder(startCap);
    Stopwatch sw = Stopwatch.StartNew();
    char[] buf = new char[4096];
    try {
      while (true) {
        if (sb.Length >= capChars) { r.Truncated = true; break; }
        long left = (long)timeoutMs - sw.ElapsedMilliseconds;
        if (left <= 0) break;
        int slice = left > 2000 ? 2000 : (int)left;
        Task<int> task = reader.ReadAsync(buf, 0, buf.Length);
        bool done = false;
        try { done = task.Wait(slice); } catch { break; }
        if (!done) break;
        int n = 0;
        try { n = task.Result; } catch { break; }
        if (n <= 0) { r.Complete = true; break; }
        int room = capChars - sb.Length;
        if (n >= room) { sb.Append(buf, 0, room); r.Truncated = true; break; }
        sb.Append(buf, 0, n);
      }
    } catch { }
    try { sw.Stop(); } catch { }
    r.Text = sb.ToString();
    return r;
  }
}
'@
if (-not ([System.Management.Automation.PSTypeName]'SpikeDrain').Type) {
  Add-Type -TypeDefinition $SpikeDrainCs -Language CSharp
}

function ConvertTo-SpikeArguments {
  param([string[]]$ArgumentList = @())
  $parts = New-Object System.Collections.ArrayList
  foreach ($a in $ArgumentList) {
    $s = [string]$a
    if ($s -eq '') { [void]$parts.Add('""'); continue }
    $needs = $false
    if ($s.Contains(' ') -or $s.Contains("`t") -or $s.Contains('"')) { $needs = $true }
    if (-not $needs) { [void]$parts.Add($s); continue }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $s.ToCharArray()) {
      if ($c -eq '\') { $slashes += 1 }
      elseif ($c -eq '"') {
        [void]$sb.Append((New-Object String '\', (2 * $slashes + 1)))
        [void]$sb.Append('"')
        $slashes = 0
      }
      else {
        if ($slashes -gt 0) {
          [void]$sb.Append((New-Object String '\', $slashes))
          $slashes = 0
        }
        [void]$sb.Append($c)
      }
    }
    if ($slashes -gt 0) {
      [void]$sb.Append((New-Object String '\', (2 * $slashes)))
    }
    [void]$sb.Append('"')
    [void]$parts.Add($sb.ToString())
  }
  return ([string]($parts -join ' '))
}

function Test-SpikeExactVersion {
  param([string]$Text = '', [string]$Version = '')
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
  $rx = '(?m)^opencode v' + [regex]::Escape($Version) + '\s*$'
  return ([regex]::IsMatch($Text, $rx))
}

function Resolve-SpikeShimTarget {
  param([string]$ShimPath = '')
  if ([string]::IsNullOrWhiteSpace($ShimPath)) { return $null }
  if (-not (Test-Path -LiteralPath $ShimPath -PathType Leaf)) { return $null }
  try {
    $fs = [IO.File]::OpenRead($ShimPath)
    try {
      $buf = New-Object byte[] 16384
      $n = $fs.Read($buf, 0, $buf.Length)
      $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    }
    finally { $fs.Close() }
  }
  catch { return $null }
  $m = [regex]::Match($txt, '"%~?dp0%\\([^"\r\n]+\.exe)"')
  if (-not $m.Success) { return $null }
  $rel = ($m.Groups[1].Value -replace '/', '\')
  $dir = Split-Path -Parent $ShimPath
  $cand = Join-Path $dir $rel
  try { $cand = [IO.Path]::GetFullPath($cand) } catch { }
  if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
  return $null
}

function Test-SpikeCmdSafeText {
  param([string]$Text = '')
  $s = [string]$Text
  if ($s -match '[&|<>\^%!"''();$`\{\}\[\]\r\n]') { return $false }
  return $true
}

function Get-SpikeFreePort {
  $lis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  try {
    $lis.Start()
    return [int]$lis.LocalEndpoint.Port
  }
  finally {
    try { $lis.Stop() } catch { }
  }
}

function Invoke-SpikeChild {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [hashtable]$EnvSet = $null,
    [string[]]$EnvRemove = @(),
    [string]$WorkingDirectory = '',
    [int]$TimeoutMs = 30000,
    [int]$OutputCapChars = 65536,
    [int]$DrainMs = 5000,
    [switch]$CleanEnvironment,
    [switch]$StdinNul,
    [object]$JobObject = $null
  )
  $started = [System.DateTime]::UtcNow
  $viaCmd = $false
  $shimResolved = $false
  $execPath = $FilePath
  $ext = ''
  try { $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant() } catch { $ext = '' }
  if (($ext -eq '.cmd') -or ($ext -eq '.bat')) {
    $target = Resolve-SpikeShimTarget -ShimPath $FilePath
    if (($null -ne $target) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
      $execPath = $target
      $shimResolved = $true
    }
    else {
      if (-not (Test-SpikeCmdSafeText -Text $FilePath)) {
        return @{
          ExitCode = -3; Stdout = ''; Stderr = ''; TimedOut = $false
          Started = $false; ElapsedMs = 0; ExecPath = $FilePath
          ViaCmd = $false; ShimResolved = $false; DrainIncomplete = $false
          StdoutTruncated = $false; StderrTruncated = $false
          JobAssigned = $false; JobNote = ''; TreeKill = 'none'
          Note = 'shim .cmd irresoluvel com meta-char no caminho: recusado sem executar'
        }
      }
      foreach ($a in $ArgumentList) {
        if (-not (Test-SpikeCmdSafeText -Text ([string]$a))) {
          return @{
            ExitCode = -3; Stdout = ''; Stderr = ''; TimedOut = $false
            Started = $false; ElapsedMs = 0; ExecPath = $FilePath
            ViaCmd = $false; ShimResolved = $false; DrainIncomplete = $false
            StdoutTruncated = $false; StderrTruncated = $false
            JobAssigned = $false; JobNote = ''; TreeKill = 'none'
            Note = 'shim .cmd irresoluvel com arg com shell-meta: recusado sem executar'
          }
        }
      }
      $viaCmd = $true
    }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $argsLine = ConvertTo-SpikeArguments -ArgumentList $ArgumentList
  if ($StdinNul -and (-not $viaCmd)) {
    if (-not (Test-SpikeCmdSafeText -Text $execPath)) {
      return @{
        ExitCode = -3; Stdout = ''; Stderr = ''; TimedOut = $false
        Started = $false; ElapsedMs = 0; ExecPath = $execPath
        ViaCmd = $false; ShimResolved = $shimResolved; DrainIncomplete = $false
        StdoutTruncated = $false; StderrTruncated = $false
        JobAssigned = $false; JobNote = ''; TreeKill = 'none'
        Note = 'StdinNul com meta-char no caminho: recusado sem executar'
      }
    }
    foreach ($a in $ArgumentList) {
      if (-not (Test-SpikeCmdSafeText -Text ([string]$a))) {
        return @{
          ExitCode = -3; Stdout = ''; Stderr = ''; TimedOut = $false
          Started = $false; ElapsedMs = 0; ExecPath = $execPath
          ViaCmd = $false; ShimResolved = $shimResolved; DrainIncomplete = $false
          StdoutTruncated = $false; StderrTruncated = $false
          JobAssigned = $false; JobNote = ''; TreeKill = 'none'
          Note = 'StdinNul com arg com shell-meta: recusado sem executar'
        }
      }
    }
    $viaCmd = $true
  }
  if ($viaCmd) {
    $cmdExe = $env:ComSpec
    if ([string]::IsNullOrWhiteSpace($cmdExe)) { $cmdExe = 'cmd.exe' }
    $q = $execPath
    if (($q.Contains(' ')) -or ($q.Contains('"'))) {
      $q = '"' + ($q -replace '"', '\"') + '"'
    }
    $psi.FileName = $cmdExe
    if ($StdinNul) {
      if ([string]::IsNullOrWhiteSpace($argsLine)) {
        $psi.Arguments = '/d /s /c "' + $q + ' < NUL"'
      }
      else {
        $psi.Arguments = '/d /s /c "' + $q + ' ' + $argsLine + ' < NUL"'
      }
    }
    elseif ([string]::IsNullOrWhiteSpace($argsLine)) {
      $psi.Arguments = '/d /s /c "' + $q + '"'
    }
    else {
      $psi.Arguments = '/d /s /c "' + $q + ' ' + $argsLine + '"'
    }
  }
  else {
    $psi.FileName = $execPath
    $psi.Arguments = $argsLine
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $psi.WorkingDirectory = $WorkingDirectory
  }
  if ($CleanEnvironment) {
    $keep = @{}
    foreach ($k in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP')) {
      $v = $null
      try { $v = [Environment]::GetEnvironmentVariable($k, 'Process') } catch { $v = $null }
      if ($null -ne $v) { $keep[$k] = $v }
    }
    try {
      $pm = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
      if (-not [string]::IsNullOrWhiteSpace($pm)) { $keep['PSModulePath'] = $pm }
    }
    catch { }
    try { $psi.EnvironmentVariables.Clear() } catch { }
    foreach ($k in @($keep.Keys)) {
      try { $psi.EnvironmentVariables[$k] = [string]$keep[$k] } catch { }
    }
  }
  if ($null -ne $EnvSet) {
    foreach ($k in @($EnvSet.Keys)) {
      $kk = [string]$k
      if ([string]::IsNullOrWhiteSpace($kk)) { continue }
      try { $psi.EnvironmentVariables[$kk] = [string]$EnvSet[$kk] } catch { }
    }
  }
  foreach ($r in $EnvRemove) {
    $rk = [string]$r
    if ([string]::IsNullOrWhiteSpace($rk)) { continue }
    try { [void]$psi.EnvironmentVariables.Remove($rk) } catch { }
  }
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  }
  catch {
    return @{
      ExitCode = -3; Stdout = ''; Stderr = ''; TimedOut = $false
      Started = $false; ElapsedMs = 0; ExecPath = $execPath
      ViaCmd = $viaCmd; ShimResolved = $shimResolved; DrainIncomplete = $false
      StdoutTruncated = $false; StderrTruncated = $false
      JobAssigned = $false; JobNote = ''; TreeKill = 'none'
      Note = ('start falhou: ' + $_.Exception.Message)
    }
  }
  # RR-P22-JOB-OBJECTS: atribuicao AO JOB imediatamente apos o start, quando o
  # chamador pediu -JobObject. Membership e por arvore de criacao, entao o
  # neto criado depois daqui entra no job. A lib nao e carregada aqui: sem
  # -JobObject o bloco inteiro e pulado (comportamento anterior intacto).
  $jobAssigned = $false
  $jobNote = ''
  if ($null -ne $JobObject) {
    if ($null -eq (Get-Command -Name 'Add-RuntimeJobProcess' -ErrorAction SilentlyContinue)) {
      $jobNote = 'lib RuntimeJobObject.ps1 nao carregada: sem atribuicao (fail-closed)'
    }
    else {
      $jobAdd = Add-RuntimeJobProcess -Job $JobObject -Process $p
      if ([bool]$jobAdd.Ok) {
        $jobAssigned = $true
        $jobNote = 'atribuido ao job (pid ' + [int]$jobAdd.Pid + ')'
      }
      else {
        $jobNote = ('atribuicao falhou: api=' + [string]$jobAdd.Api + ' ' + [string]$jobAdd.Reason)
      }
    }
  }
  try { $p.StandardInput.Close() } catch { }
  $done = $false
  try {
    $done = $p.WaitForExit($TimeoutMs)
  }
  catch {
    $done = $false
  }
  $elapsed = [long]([System.DateTime]::UtcNow - $started).TotalMilliseconds
  $timedOut = (-not $done)
  $treeKill = 'none'
  if ($timedOut) {
    # RR-P22-JOB-OBJECTS: cleanup NUNCA por arvore de PID historico.
    # COM atribuicao provada, a arvore morre por KILL_ON_JOB_CLOSE: os
    # descendentes integrados por heranca (neto incluido) morrem junto, o que e
    # MAIS FORTE que /T por PID. SEM job, so o root pelo handle do spawn PROPRIO
    # e encerrado e isso e rotulado honestamente: descendentes podem escapar e
    # nao ha claim de tree kill.
    if ($jobAssigned) {
      $treeKill = 'job'
      try {
        $jobStop = Stop-RuntimeJobObject -Job $JobObject -TimeoutMs 15000
        if (-not [bool]$jobStop.Ok) { $jobNote = $jobNote + ' | stop do job falhou: ' + [string]$jobStop.Reason }
      }
      catch { $jobNote = $jobNote + ' | stop do job lancou: ' + [string]$_.Exception.Message }
      try { [void](Close-RuntimeJobObject -Job $JobObject) } catch { }
    }
    else {
      $treeKill = 'root-only'
      try { $p.Kill() } catch { }
    }
    Start-Sleep -Milliseconds 1500
    try { [void]$p.WaitForExit(2000) } catch { }
  }
  $oTrunc = $false
  $eTrunc = $false
  $oDone = $false
  $eDone = $false
  $o = ''
  $e = ''
  try {
    $or = [SpikeDrain]::DrainBounded($p.StandardOutput, $OutputCapChars, $DrainMs)
    $o = [string]$or.Text
    $oTrunc = [bool]$or.Truncated
    $oDone = [bool]$or.Complete
  }
  catch { $o = '' }
  try {
    $er = [SpikeDrain]::DrainBounded($p.StandardError, $OutputCapChars, $DrainMs)
    $e = [string]$er.Text
    $eTrunc = [bool]$er.Truncated
    $eDone = [bool]$er.Complete
  }
  catch { $e = '' }
  if ($null -eq $o) { $o = '' }
  if ($null -eq $e) { $e = '' }
  if ($oTrunc -and ($o.Length -lt ($OutputCapChars + 64))) {
    $o = $o + "`n...[truncado em " + $OutputCapChars + " chars]"
  }
  if ($eTrunc -and ($e.Length -lt ($OutputCapChars + 64))) {
    $e = $e + "`n...[truncado em " + $OutputCapChars + " chars]"
  }
  $code = -1
  if (-not $timedOut) {
    try { $code = $p.ExitCode } catch { $code = -1 }
  }
  try { $p.Close() } catch { }
  try { $p.Dispose() } catch { }
  return @{
    ExitCode = $code
    Stdout = $o
    Stderr = $e
    TimedOut = $timedOut
    Started = $true
    ElapsedMs = $elapsed
    ExecPath = $execPath
    ViaCmd = $viaCmd
    ShimResolved = $shimResolved
    DrainIncomplete = (-not ($oDone -and $eDone))
    StdoutTruncated = $oTrunc
    StderrTruncated = $eTrunc
    JobAssigned = $jobAssigned
    JobNote = $jobNote
    TreeKill = $treeKill
    Note = ''
  }
}

function New-SpikeRunChild {
  param(
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [string]$Prefix = 'oo-run-',
    [string]$FixedName = ''
  )
  $name = $FixedName
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = $Prefix + [guid]::NewGuid().ToString('N')
  }
  $path = Join-Path $BaseDir $name
  if (Test-Path -LiteralPath $path) {
    return @{ Created = $false; Path = $path; Reason = 'caminho ja existe: recusa sobrescrever (sentinela preservada)' }
  }
  try {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
  catch {
    return @{ Created = $false; Path = $path; Reason = ('criacao falhou: ' + $_.Exception.Message) }
  }
  return @{ Created = $true; Path = $path; Reason = '' }
}

function Remove-SpikeRunChild {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BaseDir
  )
  $full = $null
  $fullBase = $null
  try {
    if (-not (Test-Path -LiteralPath $Path)) {
      return @{ Removed = $true; Reason = 'ausente (nada a remover)' }
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $fullBase = (Resolve-Path -LiteralPath $BaseDir).Path
  }
  catch {
    return @{ Removed = $false; Reason = ('resolucao falhou: ' + $_.Exception.Message) }
  }
  $pfx = $fullBase.TrimEnd('\') + '\'
  if (-not ($full.StartsWith($pfx, [System.StringComparison]::OrdinalIgnoreCase) -and ($full.Length -gt $pfx.Length))) {
    return @{ Removed = $false; Reason = 'fora da base: remocao recusada (confinamento)' }
  }
  try {
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
  }
  catch {
    return @{ Removed = $false; Reason = ('remocao falhou: ' + $_.Exception.Message) }
  }
  if (Test-Path -LiteralPath $full) {
    return @{ Removed = $false; Reason = 'restos apos remocao (handles abertos?)' }
  }
  return @{ Removed = $true; Reason = '' }
}

function Invoke-SpikeServiceStopIfOwned {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [hashtable]$EnvSet = $null,
    [string[]]$EnvRemove = @(),
    [string]$WorkingDirectory = '',
    [bool]$IsolationProved = $false,
    [bool]$PortConfigured = $false,
    [int]$Port = 0,
    [bool]$WarmupAttempted = $false,
    [int]$TimeoutMs = 30000,
    [int]$DrainMs = 5000,
    [switch]$CleanEnvironment,
    [switch]$StdinNul
  )
  $gates = ('isolation=' + $IsolationProved + ' port=' + $PortConfigured + ':' + $Port + ' warmup=' + $WarmupAttempted)
  if (-not ($IsolationProved -and $PortConfigured -and $WarmupAttempted)) {
    return @{ Attempted = $false; Stopped = $false; Reason = ('gates insuficientes, stop ausente (' + $gates + ')'); StatusText = '' }
  }
  $common = @{
    FilePath = $FilePath
    EnvSet = $EnvSet
    EnvRemove = $EnvRemove
    WorkingDirectory = $WorkingDirectory
    TimeoutMs = $TimeoutMs
    DrainMs = $DrainMs
  }
  if ($CleanEnvironment) { $common.CleanEnvironment = $true }
  if ($StdinNul) { $common.StdinNul = $true }
  $st = Invoke-SpikeChild @common -ArgumentList @('service', 'status')
  if ([bool]$st.TimedOut) {
    return @{ Attempted = $false; Stopped = $false; Reason = 'status timeout: stop ausente (endpoint nao verificado)'; StatusText = '' }
  }
  if ([int]$st.ExitCode -ne 0) {
    return @{ Attempted = $false; Stopped = $false; Reason = ('status rc=' + $st.ExitCode + ': stop ausente (endpoint nao verificado)'); StatusText = '' }
  }
  $txt = ([string]$st.Stdout + "`n" + [string]$st.Stderr).Trim()
  if ((-not $txt.Contains('127.0.0.1:' + $Port)) -or ($txt.Contains('49374'))) {
    return @{ Attempted = $false; Stopped = $false; Reason = ('status sem endpoint privado 127.0.0.1:' + $Port + ': stop ausente (nao-owned)'); StatusText = $txt }
  }
  $sp = Invoke-SpikeChild @common -ArgumentList @('service', 'stop')
  $ok = (((-not [bool]$sp.TimedOut) -and ([int]$sp.ExitCode -eq 0)))
  $reason = 'stop rc=0 (servico owned parado)'
  if (-not $ok) { $reason = ('stop falhou (rc=' + $sp.ExitCode + ' timeout=' + $sp.TimedOut + ')') }
  return @{ Attempted = $true; Stopped = $ok; Reason = $reason; StatusText = $txt }
}
