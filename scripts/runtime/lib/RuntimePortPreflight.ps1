<#!
.SYNOPSIS
    Runtime port preflight para OpenCode V2 (Phase 22, V3.1): lib dot-sourceable.
.DESCRIPTION
    Diagnostico read-only de propriedade de porta TCP antes do startup do
    servico gerenciado V2. Nao executa nada no dot-source: so define funcoes.
    PS 5.1 e PS7 compativel (sem ternario, sem ??, sem Invoke-Expression).
    ASCII only. Nunca mata PID. Nunca toca config global: persistencia de
    porta alternativa e SEMPRE por perfil (service-port.json sob o ProfileDir).
    Fail closed: faixa excluida, saude desconhecida ou identidade incerta
    nunca autorizam start nem reuse.
    Outcomes normalizados (6):
      PORT_FREE | PORT_OWNED_BY_EXPECTED_SERVICE | PORT_OCCUPIED_OTHER_PROCESS
      PORT_WINDOWS_EXCLUDED | PORT_STALE_OR_UNKNOWN | SERVICE_UNHEALTHY
    Revisao RR-P22-FIX1 (reviewer+security):
      - netsh: exit code + formato exigidos; parser tabular (espacos) e hifen.
      - listener: QuerySucceeded explicito; netstat bounded primario.
      - reuse: nome exato + ownership (path/profil) + health endpoint exato.
      - processos: helper bounded unico, exe only em mutacao, sem herdar
        OPENCODE_CONFIG*, saida limitada/sanitizada, kill somente filho proprio.
    Revisao RR-P22-FIX2 (debugger ses_f0c1e6efcffewSFjo9VodQmJL1, contracao):
      - REUSE HOLD: nenhum ShouldReuse true em producao ate prova de instancia
        exata (endpoint/path inventados nao valem); expected => STALE,
        desconhecido => OCCUPIED; enum preservado, OWNED nao emitido.
      - netsh: rodape '*' final obrigatorio; numerico malformado invalida tudo.
      - job fallback: falha carrega success=false explicito (sem default
        permissivo); selector exige QuerySucceeded explicito.
      - helper: sem ReadToEnd sync; truncado/incompleto nunca success;
        descendants sem prova (BLOCKER explicito, kill so filho direto).
      - service-port.json: schema exato com state=pending (desired); sem claim
        applied; helper sem debug config/warmup/status (podem iniciar servico).
      - ownership: .exe only (shim .cmd nunca prova); reparse ancestry em
        persist/tmp, config/state/data/cache, marker/profile; sem fallback
        lexical (TEMP nao e prova de confinamento).
    Pin de versao (RR-VERSIONS-REGISTRY): esta lib e COPIADA para os perfis e
    por isso permanece STANDALONE (nunca dot-source de outra lib). Por isso
    NAO existe default de versao aqui: -ExpectedVersion vazio e recusado
    (fail-closed) e o pin tem de chegar do registry unico
    (source/registry/runtime-versions.json) via o chamador (wrapper gerado em
    New-OrchestrationProfile). Nunca reintroduzir literal de pin nesta lib.
#>

$ErrorActionPreference = 'Stop'

function Get-PreflightOutcomes {
  return @('PORT_FREE', 'PORT_OWNED_BY_EXPECTED_SERVICE', 'PORT_OCCUPIED_OTHER_PROCESS', 'PORT_WINDOWS_EXCLUDED', 'PORT_STALE_OR_UNKNOWN', 'SERVICE_UNHEALTHY')
}

function Assert-PreflightPort([int]$Port) {
  if (($Port -lt 1) -or ($Port -gt 65535)) {
    throw ('PREFLIGHT-FAIL: porta invalida (esperado 1..65535): ' + $Port)
  }
}

function Limit-PreflightOutput {
  param([string]$Text = '', [int]$MaxChars = 8192)
  $t = [string]$Text
  if ($t.Length -gt $MaxChars) {
    $t = $t.Substring(0, $MaxChars) + "`n...[truncado em " + $MaxChars + " chars]..."
  }
  try {
    $t = [regex]::Replace($t, '(?i)(api[_-]?key|token|secret|authorization|bearer|password|passwd|\bpwd\b)\s*[:=]\s*\S+', '$1=[REDACTED]')
  }
  catch { }
  return $t
}

function Test-PreflightCmdMetachars {
  param([string]$Text = '')
  $t = [string]$Text
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  if ($t -match '[&|<>^%!`$;(){}\[\]"' + "'" + ']') { return $true }
  return $false
}

function Invoke-PreflightBoundedExe {
  param(
    [string]$File = '',
    [string]$ArgsLine = '',
    [string]$WorkDir = '',
    $EnvTable = $null,
    [string[]]$EnvRemove = @(),
    [int]$TimeoutMs = 15000,
    [int]$MaxChars = 8192
  )
  $res = @{ Started = $false; Finished = $false; TimedOut = $false; ExitCode = -1; Output = ''; Truncated = $false }
  if ([string]::IsNullOrWhiteSpace($File)) {
    $res.Output = 'executavel vazio.'
    return $res
  }
  if (Test-PreflightCmdMetachars -Text $File) {
    $res.Output = ('executavel com metachar cmd sensivel recusado: ' + $File)
    return $res
  }
  $wd = $WorkDir
  if ([string]::IsNullOrWhiteSpace($wd)) { $wd = [IO.Path]::GetTempPath() }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = [string]$ArgsLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $wd
  if ($null -ne $EnvTable) {
    foreach ($k in @($EnvTable.Keys)) {
      try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvTable[$k] } catch { }
    }
  }
  foreach ($r in @($EnvRemove)) {
    try { [void]$psi.EnvironmentVariables.Remove([string]$r) } catch { }
  }
  try {
    foreach ($ek in @($psi.EnvironmentVariables.Keys)) {
      if ([string]$ek -like 'OPENCODE_CONFIG*') {
        try { [void]$psi.EnvironmentVariables.Remove([string]$ek) } catch { }
      }
    }
  }
  catch { }
  try {
    foreach ($pk in @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH')) {
      try { [void]$psi.EnvironmentVariables.Remove($pk) } catch { }
    }
  }
  catch { }
  try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
  }
  catch {
    $res.Output = ('processo nao iniciou (' + $File + '): ' + $_.Exception.Message)
    return $res
  }
  $res.Started = $true
  $soTask = $null
  $seTask = $null
  try { $soTask = $p.StandardOutput.ReadToEndAsync() } catch { $soTask = $null }
  try { $seTask = $p.StandardError.ReadToEndAsync() } catch { $seTask = $null }
  $finished = $false
  try { $finished = $p.WaitForExit($TimeoutMs) } catch { $finished = $false }
  if (-not $finished) {
    $res.TimedOut = $true
    try { $p.Kill() } catch { }
    try { $p.WaitForExit(5000) } catch { }
    # RR-P22-FIX2: Kill() encerra so o filho direto; descendants (netos,
    # shims .cmd -> node -> servico) NAO tem cleanup provado nesta phase
    # (sem job objects). BLOCKER explicito: chamar este helper com binario
    # que gera descendants hung e risco conhecido, nao estado settled.
    $so = ''
    $se = ''
    try {
      if ($null -ne $soTask) {
        if ($soTask.Wait(5000)) { $so = [string]$soTask.Result }
      }
    }
    catch { $so = '' }
    try {
      if ($null -ne $seTask) {
        if ($seTask.Wait(5000)) { $se = [string]$seTask.Result }
      }
    }
    catch { $se = '' }
    $combined = ($so + "`n" + $se).Trim()
    try { $res.Truncated = ($combined.Length -gt $MaxChars) } catch { $res.Truncated = $false }
    $res.Output = (Limit-PreflightOutput -Text $combined -MaxChars $MaxChars)
    try { $p.Close() } catch { }
    return $res
  }
  $res.Finished = $true
  try { $res.ExitCode = $p.ExitCode } catch { $res.ExitCode = -1 }
  # RR-P22-FIX2: sem fallback sync ReadToEnd (deadlock classico com filho
  # verboso: pipe cheio bloqueia o filho enquanto o pai espera a saida).
  # O que as tasks async nao entregaram em 5s apos exit e tratado como
  # leitura incompleta (Truncated), que nunca e success a jusante.
  $partialNote = ''
  try {
    if (($null -ne $soTask) -and (-not $soTask.Wait(5000))) { $partialNote = 'stdout async incompleto apos exit' }
  }
  catch { $partialNote = 'stdout async sem leitura' }
  try {
    if (($null -ne $seTask) -and (-not $seTask.Wait(5000))) {
      if ($partialNote -ne '') { $partialNote += '; ' }
      $partialNote += 'stderr async incompleto apos exit'
    }
  }
  catch {
    if ($partialNote -ne '') { $partialNote += '; ' }
    $partialNote += 'stderr async sem leitura'
  }
  if ($partialNote -ne '') {
    $res.Output = (Limit-PreflightOutput -Text ('leitura incompleta (fail-closed a jusante): ' + $partialNote) -MaxChars $MaxChars)
    $res.Truncated = $true
    $res.Finished = $false
    try { $p.Close() } catch { }
    return $res
  }
  $so = ''
  $se = ''
  try { if ($null -ne $soTask) { $so = [string]$soTask.Result } } catch { $so = '' }
  try { if ($null -ne $seTask) { $se = [string]$seTask.Result } } catch { $se = '' }
  $combined = ($so + "`n" + $se).Trim()
  try { $res.Truncated = ($combined.Length -gt $MaxChars) } catch { $res.Truncated = $false }
  $res.Output = (Limit-PreflightOutput -Text $combined -MaxChars $MaxChars)
  try { $p.Close() } catch { }
  return $res
}

function Convert-PreflightExcludedRanges {
  param([string]$Raw = '')
  $o = [string]$Raw
  $recognized = $false
  try {
    if ($o -match '(?i)(start\s*port|end\s*port|porta\s*inicial|porta\s*final|excluded\s*port|port\s*exclusion|excludedportrange|exclusion\s*ranges|intervalos?\s*de\s*porta)') { $recognized = $true }
  }
  catch { $recognized = $false }
  # RR-P22-FIX2: o rodape '*' do netsh ("* - Administered port exclusions.")
  # e obrigatorio. Sem ele, a saida pode ser parcial/localizada/desconhecida:
  # formato nao reconhecido (fail-closed a jusante).
  $hasStar = $false
  try { $hasStar = ($o -match '\*') } catch { $hasStar = $false }
  $list = New-Object System.Collections.ArrayList
  $invalidNumeric = $false
  if (-not [string]::IsNullOrWhiteSpace($o)) {
    foreach ($ln in @($o -split "`r?`n")) {
      $t = [string]$ln
      if ([string]::IsNullOrWhiteSpace($t)) { continue }
      if (-not ($t -match '\d')) { continue }
      $done = $false
      $m = [regex]::Match($t, '(\d+)\s*-\s*(\d+)')
      if ($m.Success) {
        $a = 0
        $b = 0
        try { $a = [int]$m.Groups[1].Value } catch { $a = 0 }
        try { $b = [int]$m.Groups[2].Value } catch { $b = 0 }
        if (($a -ge 1) -and ($b -ge $a) -and ($b -le 65535)) {
          [void]$list.Add(@{ Start = $a; End = $b; Raw = $t.Trim() })
          $done = $true
        }
        else {
          # RR-P22-FIX2: numerico malformado (faixa invalida) invalida tudo.
          $invalidNumeric = $true
          continue
        }
      }
      if ($done) { continue }
      # Linha tabular "START END" com opcional '*' a direita (marcador de
      # exclusao administrada do netsh real: "50000 50059 *").
      $m2 = [regex]::Match($t, '^\s*(\d+)\s+(\d+)\s*\*?\s*$')
      if ($m2.Success) {
        $a = 0
        $b = 0
        try { $a = [int]$m2.Groups[1].Value } catch { $a = 0 }
        try { $b = [int]$m2.Groups[2].Value } catch { $b = 0 }
        if (($a -ge 1) -and ($b -ge $a) -and ($b -le 65535)) {
          [void]$list.Add(@{ Start = $a; End = $b; Raw = $t.Trim() })
          continue
        }
        $invalidNumeric = $true
        continue
      }
      # Linha com digitos que nao casa nenhum formato tabular conhecido
      # (erro do netsh, cabecalho localizado com numero, saida parcial):
      # invalida o parse inteiro em vez de ignorar silenciosamente.
      $invalidNumeric = $true
    }
  }
  if ($invalidNumeric) { return @{ Recognized = $false; Ranges = @() } }
  if (-not $hasStar) { return @{ Recognized = $false; Ranges = @($list) } }
  if ($list.Count -gt 0) { $recognized = $true }
  return @{ Recognized = $recognized; Ranges = @($list) }
}

function Get-PreflightListenerQueryOk {
  param($Listener = $null)
  if ($null -eq $Listener) { return $false }
  try {
    if ($Listener -is [System.Collections.Hashtable]) {
      if ($Listener.ContainsKey('QuerySucceeded')) { return [bool]$Listener['QuerySucceeded'] }
    }
    elseif ($Listener -is [System.Collections.IDictionary]) {
      if ($Listener.Contains('QuerySucceeded')) { return [bool]$Listener['QuerySucceeded'] }
    }
    else {
      try {
        $v = $Listener.QuerySucceeded
        if ($null -ne $v) { return [bool]$v }
      }
      catch { }
    }
  }
  catch { }
  try {
    $src = [string]$Listener.Source
    if ($src -eq 'override') { return $true }
  }
  catch { }
  return $false
}

function Get-PreflightNetTCPListenerBounded {
  param([int]$Port = 0, [int]$TimeoutMs = 10000)
  Assert-PreflightPort -Port $Port
  $res = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Source = 'Get-NetTCPConnection'; Detail = ''; QuerySucceeded = $false }
  $job = $null
  try {
    $sb = {
      param($pp)
      # RR-P22-FIX3 (B): inicializa QuerySucceeded=false; SOMENTE query com
      # Get-NetTCPConnection concluido define true (achado e nao-achado);
      # catch mantem false (sem prova, sem claim de livre).
      $out = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Detail = ''; QuerySucceeded = $false }
      try {
        $rows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { [int]$_.LocalPort -eq $pp })
        foreach ($r in $rows) {
          $addr = ''
          try { $addr = [string]$r.LocalAddress } catch { $addr = '' }
          if (($addr -eq '127.0.0.1') -or ($addr -eq '0.0.0.0') -or ($addr -eq '::') -or ($addr -eq '::1') -or ($addr -eq '0:0:0:0:0:0:0:0') -or ($addr -eq '[::]') -or ($addr -eq '[::1]')) {
            $out.Exists = $true
            try { $out.OwningPID = [int]$r.OwningProcess } catch { $out.OwningPID = 0 }
            $out.LocalAddress = $addr
            $out.Detail = ('listener ' + $addr + ':' + $pp + ' PID ' + $out.OwningPID)
            $out.QuerySucceeded = $true
            return $out
          }
        }
        $out.Detail = ('sem listener 127.0.0.1/0.0.0.0 na porta ' + $pp)
        $out.QuerySucceeded = $true
        return $out
      }
      catch {
        $out.Detail = ('consulta falhou: ' + $_.Exception.Message)
        # RR-P22-FIX3 (B): catch mantem QuerySucceeded=false.
        return $out
      }
    }
    $job = Start-Job -ScriptBlock $sb -ArgumentList $Port -ErrorAction Stop
    $done = Wait-Job -Job $job -Timeout ($TimeoutMs / 1000) -ErrorAction SilentlyContinue
    if ($null -eq $done) {
      try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
      $res.Detail = 'Get-NetTCPConnection timeout (job proprio encerrado; fail-closed a jusante)'
      return $res
    }
    $jr = Receive-Job -Job $job -ErrorAction SilentlyContinue
    # RR-P22-FIX2: job falho carrega success=false explicito com a excecao
    # (nunca default permissivo: sem prova de query, sem claim de livre).
    try { $jstate = [string]$job.JobStateInfo.State } catch { $jstate = '' }
    if ($jstate -eq 'Failed') {
      $reason = ''
      try { $reason = [string]$job.JobStateInfo.Reason.Message } catch { $reason = $jstate }
      $res.Detail = ('Get-NetTCPConnection job falhou (success=false explicito): ' + (Limit-PreflightOutput -Text $reason -MaxChars 500))
      return $res
    }
    if ($null -ne $jr) {
      try { $res.Exists = [bool]$jr.Exists } catch { }
      try { $res.OwningPID = [int]$jr.OwningPID } catch { }
      try { $res.LocalAddress = [string]$jr.LocalAddress } catch { }
      try { $res.Detail = [string]$jr.Detail } catch { }
      # RR-P22-FIX3 (B): pai COPIA o boolean explicito do job; nunca atribui
      # true por qualquer row. Sem chave QuerySucceeded => false (recusa).
      $copied = $false
      $copyOk = $false
      try {
        if ($jr -is [System.Collections.Hashtable]) {
          if ($jr.ContainsKey('QuerySucceeded')) { $copied = [bool]$jr['QuerySucceeded']; $copyOk = $true }
        }
        elseif ($jr -is [System.Collections.IDictionary]) {
          if ($jr.Contains('QuerySucceeded')) { $copied = [bool]$jr['QuerySucceeded']; $copyOk = $true }
        }
        else {
          $qv = $jr.QuerySucceeded
          if ($null -ne $qv) { $copied = [bool]$qv; $copyOk = $true }
        }
      }
      catch { $copyOk = $false }
      if ($copyOk) { $res.QuerySucceeded = $copied }
      else { $res.QuerySucceeded = $false }
    }
    else {
      $res.Detail = 'Get-NetTCPConnection sem resultado (fail-closed a jusante)'
    }
    return $res
  }
  catch {
    $res.Detail = ('Get-NetTCPConnection nao executou de forma bounded: ' + $_.Exception.Message)
    return $res
  }
  finally {
    if ($null -ne $job) {
      try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
    }
  }
}

function Get-PreflightListener {
  param([int]$Port = 0)
  Assert-PreflightPort -Port $Port
  $res = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Source = ''; Detail = ''; QuerySucceeded = $false }
  $ns = Invoke-PreflightBoundedExe -File 'netstat.exe' -ArgsLine '-ano -p TCP' -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 15000 -MaxChars 262144
  # RR-P22-FIX2: leitura truncada/incompleta nunca e success; parcial nao
  # autoriza parse (cai no fallback bounded independente, sem claim).
  if ([bool]$ns.Truncated -or (-not [bool]$ns.Finished)) {
    $res.Source = 'netstat'
    $res.Detail = 'netstat com leitura truncada/incompleta (fail-closed nesta fonte; fallback bounded Get-NetTCPConnection)'
  }
  elseif ([bool]$ns.Started -and [bool]$ns.Finished -and ([int]$ns.ExitCode -eq 0)) {
    $o = [string]$ns.Output
    if ($o -match '(?i)(TCP|LISTENING)') {
      foreach ($ln in @($o -split "`r?`n")) {
        $m = [regex]::Match($ln, '^\s*TCP\s+(\S+)\s+\S+\s+LISTENING\s+(\d+)\s*$')
        if (-not $m.Success) { continue }
        $local = $m.Groups[1].Value
        $ownerPid = 0
        try { $ownerPid = [int]$m.Groups[2].Value } catch { $ownerPid = 0 }
        $lm = [regex]::Match($local, '^(.*):(\d+)$')
        if (-not $lm.Success) { continue }
        $lport = 0
        try { $lport = [int]$lm.Groups[2].Value } catch { continue }
        if ($lport -ne $Port) { continue }
        $laddrRaw = $lm.Groups[1].Value
        $laddr = $laddrRaw.Trim('[', ']')
        if (($laddrRaw -eq '127.0.0.1') -or ($laddrRaw -eq '0.0.0.0') -or ($laddrRaw -eq '[::]') -or ($laddrRaw -eq '::') -or ($laddr -eq '::') -or ($laddr -eq '::1') -or ($laddr -eq '0:0:0:0:0:0:0:0') -or ($laddr -eq '127.0.0.1') -or ($laddr -eq '0.0.0.0')) {
          $res.Exists = $true
          $res.OwningPID = $ownerPid
          $res.LocalAddress = $laddrRaw
          $res.Source = 'netstat'
          $res.Detail = ('listener ' + $local + ' PID ' + $ownerPid)
          $res.QuerySucceeded = $true
          return $res
        }
      }
      $res.Source = 'netstat'
      $res.Detail = ('sem listener 127.0.0.1/0.0.0.0 na porta ' + $Port)
      $res.QuerySucceeded = $true
      return $res
    }
    $res.Source = 'netstat'
    $res.Detail = 'netstat sem formato TCP/LISTENING reconhecido (fail-closed a jusante)'
    $res.QuerySucceeded = $false
  }
  else {
    $why = 'netstat indisponivel'
    try {
      if ([bool]$ns.TimedOut) { $why = 'netstat timeout (filho direto encerrado; descendants sem prova, BLOCKER RR-P22-FIX2)' }
      elseif (-not [bool]$ns.Started) { $why = ('netstat nao iniciou: ' + [string]$ns.Output) }
      elseif (-not [bool]$ns.Finished) { $why = 'netstat nao concluiu (fail-closed a jusante)' }
      else { $why = ('netstat exit ' + [int]$ns.ExitCode) }
    }
    catch { }
    $res.Source = 'netstat'
    $res.Detail = ($why + ' (fallback bounded Get-NetTCPConnection)')
  }
  $fb = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs 10000
  return $fb
}

function Get-PreflightProcessIdentity {
  param([int]$OwnerPID = 0)
  $res = @{ Exists = $false; PID = $OwnerPID; Name = ''; Path = ''; Detail = '' }
  if ($OwnerPID -le 0) {
    $res.Detail = 'PID invalido (<=0)'
    return $res
  }
  try {
    $pr = Get-Process -Id $OwnerPID -ErrorAction Stop
    $res.Exists = $true
    try { $res.Name = [string]$pr.ProcessName } catch { $res.Name = '' }
    try { $res.Path = [string]$pr.Path } catch { $res.Path = '' }
    if ([string]::IsNullOrWhiteSpace($res.Path)) {
      try { $res.Path = [string]$pr.MainModule.FileName } catch { }
    }
    $res.Detail = ('processo ' + $res.Name + ' PID ' + $OwnerPID)
    return $res
  }
  catch {
    $res.Detail = ('processo PID ' + $OwnerPID + ' nao resolvido: ' + $_.Exception.Message)
    return $res
  }
}

function Get-PreflightExcludedRanges {
  $res = @{ Available = $false; Ranges = @(); Raw = ''; Detail = '' }
  $ns = Invoke-PreflightBoundedExe -File 'netsh.exe' -ArgsLine 'interface ipv4 show excludedportrange tcp' -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 15000
  if (-not [bool]$ns.Started) {
    $res.Detail = ('netsh nao iniciou (fail-closed a jusante): ' + [string]$ns.Output)
    return $res
  }
  # RR-P22-FIX2: leitura truncada/incompleta nunca e success.
  if ([bool]$ns.Truncated -or (-not [bool]$ns.Finished)) {
    $res.Detail = 'netsh com leitura truncada/incompleta (fail-closed a jusante)'
    return $res
  }
  if ([bool]$ns.TimedOut -or (-not [bool]$ns.Finished)) {
    $res.Detail = 'netsh timeout (filho proprio encerrado; fail-closed a jusante)'
    return $res
  }
  if ([int]$ns.ExitCode -ne 0) {
    $res.Detail = ('netsh exit ' + [int]$ns.ExitCode + ' (fail-closed a jusante): ' + (Limit-PreflightOutput -Text ([string]$ns.Output) -MaxChars 2000))
    return $res
  }
  $o = [string]$ns.Output
  $res.Raw = (Limit-PreflightOutput -Text $o -MaxChars 32768)
  $parsed = Convert-PreflightExcludedRanges -Raw $o
  if (-not [bool]$parsed.Recognized) {
    $res.Detail = 'netsh sem formato reconhecido (fail-closed a jusante)'
    return $res
  }
  $res.Available = $true
  $res.Ranges = @($parsed.Ranges)
  $res.Detail = ((@($parsed.Ranges).Count).ToString() + ' faixa(s) excluida(s) lida(s)')
  return $res
}

function Test-PreflightPortExcluded {
  param([int]$Port = 0, $Ranges = @())
  Assert-PreflightPort -Port $Port
  foreach ($r in @($Ranges)) {
    $a = 0
    $b = 0
    try { $a = [int]$r.Start } catch { continue }
    try { $b = [int]$r.End } catch { continue }
    if (($Port -ge $a) -and ($Port -le $b)) {
      return @{ Excluded = $true; Range = $r }
    }
  }
  return @{ Excluded = $false; Range = $null }
}

function Get-PreflightEphemeralPort {
  $lis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  try {
    $lis.Start()
    return [int]$lis.LocalEndpoint.Port
  }
  finally {
    try { $lis.Stop() } catch { }
  }
}

function Test-PreflightExpectedName {
  param([string]$ProcessName = '', [string[]]$ExpectedNames = @('opencode'))
  $raw = [string]$ProcessName
  $base = $raw.Trim()
  try { $base = [IO.Path]::GetFileNameWithoutExtension($base) } catch { }
  $base = $base.Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($base)) { return $false }
  foreach ($e in @($ExpectedNames)) {
    $eb = ([string]$e).Trim()
    try { $eb = [IO.Path]::GetFileNameWithoutExtension($eb) } catch { }
    $eb = $eb.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($eb)) { continue }
    if ($base -eq $eb) { return $true }
  }
  return $false
}

function Test-PreflightExactEndpoint {
  param([string]$Detail = '', [int]$Port = 0)
  Assert-PreflightPort -Port $Port
  $t = [string]$Detail
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  $rx = '127\.0\.0\.1:' + [string]$Port + '(?!\d)'
  try { return [regex]::IsMatch($t, $rx) } catch { return $false }
}

function Test-PreflightOwnershipProven {
  param($Process = $null, [string[]]$ExpectedBinaryPaths = @(), [string]$ExpectedProfileDir = '')
  if ($null -eq $Process) { return $false }
  $pp = ''
  try { $pp = [string]$Process.Path } catch { $pp = '' }
  if ([string]::IsNullOrWhiteSpace($pp)) { return $false }
  # RR-P22-FIX2 (debugger): shim .cmd provisionado no manifest e o servico em
  # cache com exe path diferente; nome-only nunca prova. Ownership exige .exe
  # exato (processo e allowlist); .cmd nunca prova ownership.
  try {
    if (-not $pp.ToLowerInvariant().EndsWith('.exe')) { return $false }
  }
  catch { return $false }
  $hasAllow = $false
  $matchAllow = $false
  foreach ($e in @($ExpectedBinaryPaths)) {
    if ([string]::IsNullOrWhiteSpace([string]$e)) { continue }
    try {
      if (-not ([string]$e).ToLowerInvariant().EndsWith('.exe')) { continue }
    }
    catch { continue }
    $hasAllow = $true
    try {
      $a = ([IO.Path]::GetFullPath([string]$e)).TrimEnd('\')
      $b = ([IO.Path]::GetFullPath($pp)).TrimEnd('\')
      if ($a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) { $matchAllow = $true }
    }
    catch {
      if (([string]$e).Equals($pp, [StringComparison]::OrdinalIgnoreCase)) { $matchAllow = $true }
    }
  }
  $underProfile = $false
  $hasProfile = (-not [string]::IsNullOrWhiteSpace($ExpectedProfileDir))
  if ($hasProfile) {
    try {
      $root = ([IO.Path]::GetFullPath($ExpectedProfileDir)).TrimEnd('\')
      $full = ([IO.Path]::GetFullPath($pp)).TrimEnd('\')
      if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $underProfile = $true
      }
    }
    catch { $underProfile = $false }
  }
  if ($hasAllow -or $hasProfile) {
    if ($matchAllow -or $underProfile) { return $true }
    return $false
  }
  return $false
}

function Get-PreflightCollisionHint {
  param([int]$Port = 0, [string]$ProcessName = '', [string]$ProcessPath = '')
  $n = ([string]$ProcessName).ToLowerInvariant()
  $pp = ([string]$ProcessPath).ToLowerInvariant()
  if ($Port -eq 49374) {
    if (($n.Contains('docker') -or $pp.Contains('docker')) -and (($n.Contains('backend') -or $pp.Contains('backend')) -or $true)) {
      return 'porta 49374 ocupada por Docker port-forward (provavel AI Memory local 127.0.0.1:49374->49374/tcp, healthy). Nunca inicie o servico V2 em 49374 enquanto ocupado; use `opencode service set port <livre>` por perfil.'
    }
    return 'porta 49374 e o default do servico V2 e o default historico do AI Memory local. Nunca inicie usando 49374 se ocupado; selecione porta livre e persista por perfil.'
  }
  if ($n.Contains('docker') -or $pp.Contains('docker')) {
    return 'listener pertence a Docker (possivel port-forward de container). Nao mate o PID; escolha outra porta.'
  }
  if ($n.Contains('cloudflared')) {
    return 'listener e cliente cloudflared conectado (observado como cliente de 49374, nao dono). Nao mate o PID.'
  }
  return ''
}

function Invoke-PreflightPort {
  param(
    [int]$Port = 0,
    [string[]]$ExpectedProcessNames = @('opencode'),
    [string[]]$ExpectedProcessPaths = @(),
    [string]$ExpectedProfileDir = '',
    $HealthProbe = $null,
    $ListenerOverride = $null,
    $ProcessOverride = $null,
    $ExcludedRangesOverride = $null,
    [bool]$ExcludedQueryAvailableOverride = $true,
    $HealthOverride = $null
  )
  Assert-PreflightPort -Port $Port
  $diag = New-Object System.Collections.ArrayList
  [void]$diag.Add('preflight read-only; nenhum PID sera terminado por este modulo')
  $excludedRanges = @()
  $excludedAvailable = $false
  if ($null -ne $ExcludedRangesOverride) {
    $excludedRanges = @($ExcludedRangesOverride)
    $excludedAvailable = [bool]$ExcludedQueryAvailableOverride
    [void]$diag.Add('faixas excluidas via override (teste)')
  }
  else {
    $ex = Get-PreflightExcludedRanges
    $excludedAvailable = [bool]$ex.Available
    $excludedRanges = @($ex.Ranges)
    [void]$diag.Add([string]$ex.Detail)
  }
  if (-not $excludedAvailable) {
    [void]$diag.Add('faixas excluidas INDISPONIVEIS: fail-closed (nao autoriza start)')
    return [ordered]@{
      Outcome = 'PORT_STALE_OR_UNKNOWN'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $null
      Process = $null
      Excluded = @{ Checked = $false; Excluded = $false; Range = $null }
      Health = @{ Checked = $false; Healthy = $false; Detail = 'faixas excluidas indisponiveis' }
      Diagnostics = @($diag)
      CollisionHint = (Get-PreflightCollisionHint -Port $Port -ProcessName '' -ProcessPath '')
    }
  }
  $exTest = Test-PreflightPortExcluded -Port $Port -Ranges $excludedRanges
  if ([bool]$exTest.Excluded) {
    [void]$diag.Add(('porta ' + $Port + ' em faixa excluida do Windows: ' + [string]$exTest.Range.Raw))
    return [ordered]@{
      Outcome = 'PORT_WINDOWS_EXCLUDED'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $null
      Process = $null
      Excluded = @{ Checked = $true; Excluded = $true; Range = $exTest.Range }
      Health = @{ Checked = $false; Healthy = $false; Detail = 'nao avaliado (faixa excluida)' }
      Diagnostics = @($diag)
      CollisionHint = (Get-PreflightCollisionHint -Port $Port -ProcessName '' -ProcessPath '')
    }
  }
  $lis = $null
  if ($null -ne $ListenerOverride) {
    $lis = $ListenerOverride
    [void]$diag.Add('listener via override (teste)')
  }
  else {
    $lis = Get-PreflightListener -Port $Port
    [void]$diag.Add([string]$lis.Detail)
  }
  $qOk = Get-PreflightListenerQueryOk -Listener $lis
  if (-not $qOk) {
    [void]$diag.Add('listener sem QuerySucceeded: fail-closed (nao autoriza start nem reuse)')
    return [ordered]@{
      Outcome = 'PORT_STALE_OR_UNKNOWN'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $lis
      Process = $null
      Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
      Health = @{ Checked = $false; Healthy = $false; Detail = 'listener query sem sucesso' }
      Diagnostics = @($diag)
      CollisionHint = (Get-PreflightCollisionHint -Port $Port -ProcessName '' -ProcessPath '')
    }
  }
  if (-not [bool]$lis.Exists) {
    [void]$diag.Add(('porta ' + $Port + ' livre: start permitido (re-checar no start real)'))
    return [ordered]@{
      Outcome = 'PORT_FREE'
      Port = $Port
      ShouldStart = $true
      ShouldReuse = $false
      Listener = $lis
      Process = $null
      Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
      Health = @{ Checked = $false; Healthy = $false; Detail = 'sem listener; health n/a' }
      Diagnostics = @($diag)
      CollisionHint = (Get-PreflightCollisionHint -Port $Port -ProcessName '' -ProcessPath '')
    }
  }
  $ownerPid = 0
  try { $ownerPid = [int]$lis.OwningPID } catch { $ownerPid = 0 }
  $proc = $null
  if ($null -ne $ProcessOverride) {
    $proc = $ProcessOverride
    [void]$diag.Add('processo via override (teste)')
  }
  else {
    $proc = Get-PreflightProcessIdentity -OwnerPID $ownerPid
    [void]$diag.Add([string]$proc.Detail)
  }
  if (-not [bool]$proc.Exists) {
    [void]$diag.Add('listener sem processo resolvivel (stale/zombie?): fail-closed')
    return [ordered]@{
      Outcome = 'PORT_STALE_OR_UNKNOWN'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $lis
      Process = $proc
      Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
      Health = @{ Checked = $false; Healthy = $false; Detail = 'identidade nao resolvida' }
      Diagnostics = @($diag)
      CollisionHint = (Get-PreflightCollisionHint -Port $Port -ProcessName ([string]$proc.Name) -ProcessPath ([string]$proc.Path))
    }
  }
  $isExpected = Test-PreflightExpectedName -ProcessName ([string]$proc.Name) -ExpectedNames $ExpectedProcessNames
  $ownershipProven = Test-PreflightOwnershipProven -Process $proc -ExpectedBinaryPaths $ExpectedProcessPaths -ExpectedProfileDir $ExpectedProfileDir
  [void]$diag.Add(('processo dono: ' + [string]$proc.Name + ' (expected-name=' + $isExpected + ' ownership=' + $ownershipProven + ')'))
  $health = $null
  if ($null -ne $HealthOverride) {
    $health = $HealthOverride
    [void]$diag.Add('health via override (teste)')
  }
  elseif ($null -ne $HealthProbe) {
    try {
      $health = (& $HealthProbe @{ Port = $Port; OwnerPID = $ownerPid; ProcessName = [string]$proc.Name; ProcessPath = [string]$proc.Path })
      if ($null -eq $health) { $health = @{ Checked = $false; Healthy = $false; Detail = 'probe retornou nulo' } }
    }
    catch {
      $health = @{ Checked = $false; Healthy = $false; Detail = ('probe falhou: ' + $_.Exception.Message) }
    }
    [void]$diag.Add(('health probe: ' + [string]$health.Detail))
  }
  else {
    $health = @{ Checked = $false; Healthy = $false; Detail = 'sem probe de saude; reuse exige ownership+health (fail-closed)' }
    [void]$diag.Add([string]$health.Detail)
  }
  $hint = Get-PreflightCollisionHint -Port $Port -ProcessName ([string]$proc.Name) -ProcessPath ([string]$proc.Path)
  $healthy = $false
  $checked = $false
  try { $checked = [bool]$health.Checked } catch { $checked = $false }
  try { $healthy = [bool]$health.Healthy } catch { $healthy = $false }
  $healthExact = Test-PreflightExactEndpoint -Detail ([string]$health.Detail) -Port $Port
  # RR-P22-FIX2 REUSE HOLD (debugger ses_f0c1e6efcffewSFjo9VodQmJL1): nenhum
  # ShouldReuse true em producao ate prova de instancia exata. Endpoint e path
  # observados nao constituem identidade de instancia (cache do servico pode
  # apontar exe diferente do provisionado; nome-only nao reconhece). O ramo
  # abaixo seria o unico emissor de PORT_OWNED_BY_EXPECTED_SERVICE: agora
  # emite PORT_STALE_OR_UNKNOWN (expected => STALE) com HOLD explicito.
  # O enum em Get-PreflightOutcomes e preservado; OWNED nao e emitido.
  if ($isExpected -and $ownershipProven -and $checked -and $healthy -and $healthExact) {
    [void]$diag.Add('REUSE HOLD (RR-P22-FIX2): ownership+endpoint exato insuficientes sem prova de instancia exata; reuse bloqueado e segundo start tambem bloqueado (fail-closed)')
    return [ordered]@{
      Outcome = 'PORT_STALE_OR_UNKNOWN'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $lis
      Process = $proc
      Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
      Health = $health
      Diagnostics = @($diag)
      CollisionHint = $hint
    }
  }
  if ($isExpected) {
    if (-not $ownershipProven) {
      [void]$diag.Add('nome esperado mas SEM prova de ownership (path/perfil): fail-closed (PORT_STALE_OR_UNKNOWN); nome sozinho nunca autoriza reuse')
      return [ordered]@{
        Outcome = 'PORT_STALE_OR_UNKNOWN'
        Port = $Port
        ShouldStart = $false
        ShouldReuse = $false
        Listener = $lis
        Process = $proc
        Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
        Health = $health
        Diagnostics = @($diag)
        CollisionHint = $hint
      }
    }
    if ($checked -and $healthy -and (-not $healthExact)) {
      [void]$diag.Add('health sem endpoint exato 127.0.0.1:porta (prefixo nao basta): fail-closed')
      return [ordered]@{
        Outcome = 'PORT_STALE_OR_UNKNOWN'
        Port = $Port
        ShouldStart = $false
        ShouldReuse = $false
        Listener = $lis
        Process = $proc
        Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
        Health = $health
        Diagnostics = @($diag)
        CollisionHint = $hint
      }
    }
    if ($checked -and (-not $healthy)) {
      [void]$diag.Add('servico esperado presente mas unhealthy: fail-closed (cleanup so com prova de ownership)')
      return [ordered]@{
        Outcome = 'SERVICE_UNHEALTHY'
        Port = $Port
        ShouldStart = $false
        ShouldReuse = $false
        Listener = $lis
        Process = $proc
        Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
        Health = $health
        Diagnostics = @($diag)
        CollisionHint = $hint
      }
    }
    [void]$diag.Add('servico esperado com saude nao verificada: fail-closed (PORT_STALE_OR_UNKNOWN)')
    return [ordered]@{
      Outcome = 'PORT_STALE_OR_UNKNOWN'
      Port = $Port
      ShouldStart = $false
      ShouldReuse = $false
      Listener = $lis
      Process = $proc
      Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
      Health = $health
      Diagnostics = @($diag)
      CollisionHint = $hint
    }
  }
  [void]$diag.Add('porta ocupada por outro processo: nunca matar PID automaticamente')
  return [ordered]@{
    Outcome = 'PORT_OCCUPIED_OTHER_PROCESS'
    Port = $Port
    ShouldStart = $false
    ShouldReuse = $false
    Listener = $lis
    Process = $proc
    Excluded = @{ Checked = $true; Excluded = $false; Range = $null }
    Health = $health
    Diagnostics = @($diag)
    CollisionHint = $hint
  }
}

function Get-PreflightProfilePortPath {
  param([string]$ProfileDir = '')
  if ([string]::IsNullOrWhiteSpace($ProfileDir)) { throw 'PREFLIGHT-FAIL: ProfileDir vazio.' }
  return (Join-Path $ProfileDir 'service-port.json')
}

function Test-PreflightServicePortSchema {
  param($Json = $null)
  # RR-P22-FIX2: schema exato do marker desired/applied. Nesta phase so
  # state=pending (desired) e gravavel; applied exige prova de instancia
  # exata ainda sem mecanismo provado (HOLD). Sem schema exato => startup
  # bloqueia com PORT_CONFIGURATION_UNVERIFIED (nunca muda 49374).
  if ($null -eq $Json) { return @{ Ok = $false; Detail = 'json nulo.' } }
  $port = 0
  try { $port = [int]$Json.port } catch { return @{ Ok = $false; Detail = 'port ausente ou nao numerico.' } }
  if (($port -lt 1) -or ($port -gt 65535)) {
    return @{ Ok = $false; Detail = ('port fora de 1..65535: ' + $port) }
  }
  $state = ''
  try { $state = [string]$Json.state } catch { $state = '' }
  if ($state -ne 'pending') {
    return @{ Ok = $false; Detail = ('state exato pending exigido (obtido: ' + $state + '); marker antigo sem state nao e prova (PORT_CONFIGURATION_UNVERIFIED).') }
  }
  $src = ''
  try { $src = [string]$Json.source } catch { $src = '' }
  if ([string]::IsNullOrWhiteSpace($src)) {
    return @{ Ok = $false; Detail = 'source ausente (schema exato exige origem).' }
  }
  return @{ Ok = $true; Port = $port; State = $state; Source = $src; Detail = 'schema pending ok (desired; applied exige prova, HOLD)' }
}

function Get-PreflightPersistedPort {
  param([string]$ProfileDir = '')
  $p = Get-PreflightProfilePortPath -ProfileDir $ProfileDir
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  try {
    $j = (([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
    $port = 0
    try { $port = [int]$j.port } catch { return $null }
    if (($port -lt 1) -or ($port -gt 65535)) { return $null }
    $state = ''
    try { $state = [string]$j.state } catch { $state = '' }
    return @{ Port = $port; State = $state; Source = [string]$j.source; UpdatedAt = [string]$j.updated_at; Path = $p }
  }
  catch { return $null }
}

function Set-PreflightPersistedPort {
  param([string]$ProfileDir = '', [int]$Port = 0, [string]$Source = 'manual', [string]$State = 'pending')
  Assert-PreflightPort -Port $Port
  # RR-P22-FIX2: gravacao SOMENTE pending (desired). Nenhum caminho desta
  # phase grava applied/claim de efeito nativo.
  if ($State -ne 'pending') { throw 'PREFLIGHT-FAIL: state gravavel nesta phase e somente pending (applied em HOLD).' }
  if ([string]::IsNullOrWhiteSpace($ProfileDir)) { throw 'PREFLIGHT-FAIL: ProfileDir vazio.' }
  if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
    throw ('PREFLIGHT-FAIL: ProfileDir inexistente: ' + $ProfileDir)
  }
  # RR-P22-FIX2: persist/tmp com ancestry anti-reparse sob o perfil.
  $ancP = Test-PreflightNoReparseAncestry -Path $ProfileDir -Root $ProfileDir
  if (-not [bool]$ancP.Ok) { throw ('PREFLIGHT-FAIL: ProfileDir com ancestry invalida: ' + [string]$ancP.Detail) }
  $target = Get-PreflightProfilePortPath -ProfileDir $ProfileDir
  # RR-P22-FIX3 (E): marker/tmp com ancestry anti-reparse sob o perfil: target
  # existente reparse => recusa; ancestry do target verificada; tmp recem
  # escrito reparse => recusa antes do move (fail-closed).
  $tgtAnc = Test-PreflightNoReparseAncestry -Path $target -Root $ProfileDir
  if (-not [bool]$tgtAnc.Ok) { throw ('PREFLIGHT-FAIL: marker com ancestry invalida: ' + [string]$tgtAnc.Detail) }
  if (Test-Path -LiteralPath $target -PathType Leaf) {
    try {
      $tattrs = (Get-Item -Force -LiteralPath $target).Attributes
      if (($tattrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('PREFLIGHT-FAIL: marker e reparse point: ' + $target) }
    }
    catch {
      if ($_.Exception.Message -match '^PREFLIGHT-FAIL') { throw }
      throw ('PREFLIGHT-FAIL: inspeacao do marker falhando: ' + $target)
    }
  }
  $obj = [ordered]@{
    port = $Port
    state = 'pending'
    source = $Source
    updated_at = ((Get-Date).ToString('o'))
    note = 'desired port (pending) do servico V2 POR PERFIL; nunca global; nunca claim de applied. Re-checada a cada start via preflight; applied exige prova de instancia (HOLD RR-P22-FIX2).'
  }
  $tmp = $target + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($obj | ConvertTo-Json -Depth 4).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  try {
    $tmpAttrs = (Get-Item -Force -LiteralPath $tmp).Attributes
    if (($tmpAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
      throw ('PREFLIGHT-FAIL: tmp e reparse point: ' + $tmp)
    }
  }
  catch {
    if ($_.Exception.Message -match '^PREFLIGHT-FAIL') { throw }
    try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
    throw ('PREFLIGHT-FAIL: inspeacao do tmp falhando: ' + $tmp)
  }
  Move-Item -LiteralPath $tmp -Destination $target -Force
  return @{ Port = $Port; State = 'pending'; Path = $target }
}

function Select-PreflightServicePort {
  param(
    [int[]]$CandidatePorts = @(),
    $ExcludedRanges = @(),
    $ListenerProbe = $null
  )
  foreach ($c in @($CandidatePorts)) {
    $p = 0
    try { $p = [int]$c } catch { continue }
    if (($p -lt 1) -or ($p -gt 65535)) { continue }
    $ex = Test-PreflightPortExcluded -Port $p -Ranges @($ExcludedRanges)
    if ([bool]$ex.Excluded) { continue }
    $exists = $false
    $qOk = $false
    if ($null -ne $ListenerProbe) {
      try {
        $lr = (& $ListenerProbe $p)
        if ($null -eq $lr) { continue }
        # RR-P22-FIX2: sem QuerySucceeded explicito, sem claim. Ausencia da
        # chave (ou tipo desconhecido) e recusa, nao default permissivo.
        try {
          if ($lr -is [System.Collections.Hashtable]) {
            if ($lr.ContainsKey('QuerySucceeded')) { $qOk = [bool]$lr['QuerySucceeded'] }
            else { $qOk = $false }
          }
          elseif ($lr -is [System.Collections.IDictionary]) {
            if ($lr.Contains('QuerySucceeded')) { $qOk = [bool]$lr['QuerySucceeded'] }
            else { $qOk = $false }
          }
          else { $qOk = $false }
        }
        catch { $qOk = $false }
        if (-not $qOk) { continue }
        $exists = [bool]$lr.Exists
      }
      catch { continue }
    }
    else {
      try {
        $lr = Get-PreflightListener -Port $p
        $qOk = Get-PreflightListenerQueryOk -Listener $lr
        if (-not $qOk) { continue }
        $exists = [bool]$lr.Exists
      }
      catch { continue }
    }
    if (-not $exists -and $qOk) { return $p }
  }
  return 0
}

function Test-PreflightRemoteMemoryPreconditions {
  param([string]$Endpoint = '', $EnvTable = $null)
  $checks = New-Object System.Collections.ArrayList
  $ep = [string]$Endpoint
  if ([string]::IsNullOrWhiteSpace($ep) -and ($null -ne $EnvTable)) {
    foreach ($k in @('AI_MEMORY_ENDPOINT', 'AIMEMORY_ENDPOINT', 'MEMORY_ENDPOINT')) {
      try {
        $v = [string]$EnvTable[$k]
        if (-not [string]::IsNullOrWhiteSpace($v)) { $ep = $v; break }
      }
      catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($ep)) {
    foreach ($k in @('AI_MEMORY_ENDPOINT', 'AIMEMORY_ENDPOINT', 'MEMORY_ENDPOINT')) {
      try {
        $v = [string](Get-Item -Path ('Env:\' + $k) -ErrorAction SilentlyContinue).Value
        if (-not [string]::IsNullOrWhiteSpace($v)) { $ep = $v; break }
      }
      catch { }
    }
  }
  [void]$checks.Add(@{ name = 'endpoint_from_user_owned_config'; passed = (-not [string]::IsNullOrWhiteSpace($ep)); detail = 'endpoint deve vir de config/env do usuario; nada commitado aqui' })
  $noLocal = $true
  if ($ep -match '127\.0\.0\.1:49374|localhost:49374') { $noLocal = $false }
  [void]$checks.Add(@{ name = 'no_required_local_49374'; passed = $noLocal; detail = 'remote nao deve exigir listener local fixo 49374' })
  $noSecret = $true
  if ($ep -match '(?i)(api[_-]?key|token|secret)\s*[:=]') { $noSecret = $false }
  [void]$checks.Add(@{ name = 'no_secret_in_endpoint'; passed = $noSecret; detail = 'endpoint nao embute segredo; chave via env/credential store' })
  $ok = $true
  foreach ($c in @($checks)) { if (-not [bool]$c.passed) { $ok = $false } }
  return @{ Supported = $ok; Endpoint = $ep; RequiresLocalListener = $false; Checks = @($checks); Note = 'pre-condicao de suporte remoto (Phase22); migracao real e Phase31' }
}

function Test-PreflightProfileManifestV2 {
  param([string]$ProfileDir = '')
  if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
    return @{ Ok = $false; Detail = 'ProfileDir vazio.' }
  }
  if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
    return @{ Ok = $false; Detail = ('ProfileDir inexistente: ' + $ProfileDir) }
  }
  $mf = Join-Path $ProfileDir 'manifest.json'
  if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) {
    return @{ Ok = $false; Detail = ('manifest ausente: ' + $mf) }
  }
  try {
    $pm = (([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
  }
  catch {
    return @{ Ok = $false; Detail = ('manifest ilegivel: ' + $_.Exception.Message) }
  }
  try {
    if (([string]$pm.runtime_id -ne 'opencode-v2') -or ([int]$pm.generation -ne 2)) {
      return @{ Ok = $false; Detail = 'manifest nao e v2 (runtime_id/generation divergentes).' }
    }
  }
  catch {
    return @{ Ok = $false; Detail = 'manifest sem runtime_id/generation validos.' }
  }
  $cfg = ''
  try { $cfg = [string]$pm.config_root } catch { $cfg = '' }
  $bin = ''
  try {
    if ($null -ne $pm.provisioned) { $bin = [string]$pm.provisioned.binary_path }
  }
  catch { $bin = '' }
  return @{ Ok = $true; Detail = 'manifest v2 ok'; ConfigRoot = $cfg; ProvisionedBinary = $bin }
}

function Test-PreflightNoReparseAncestry {
  param([string]$Path = '', [string]$Root = '')
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return @{ Ok = $false; Detail = 'caminho vazio (ancestry nao verificavel).' }
  }
  if ([string]::IsNullOrWhiteSpace($Root)) {
    return @{ Ok = $false; Detail = 'raiz vazia (ancestry nao verificavel).' }
  }
  $pathNorm = ''
  $rootNorm = ''
  try { $pathNorm = ([IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return @{ Ok = $false; Detail = ('caminho nao normalizavel: ' + $Path) } }
  try { $rootNorm = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') } catch { return @{ Ok = $false; Detail = ('raiz nao normalizavel: ' + $Root) } }
  $isUnder = $pathNorm.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase)
  $isRoot = $pathNorm.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase)
  if ((-not $isUnder) -and (-not $isRoot)) {
    return @{ Ok = $false; Detail = ('fora da raiz esperada: ' + $Path) }
  }
  # RR-P22-FIX3 (E): Path==Root tambem verifica: Root em si + todos os
  # ancestrais EXISTENTES do Root sao inspecionados antes do laco (fail-closed;
  # Root reparse => recusa neste modulo). Sem helper externo: Get-Item fail =>
  # recusa (nunca default permissivo).
  try {
    if (Test-Path -LiteralPath $rootNorm) {
      try {
        $rattrs = (Get-Item -Force -LiteralPath $rootNorm).Attributes
        if (($rattrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          return @{ Ok = $false; Detail = ('raiz e reparse point: ' + $rootNorm) }
        }
      }
      catch {
        return @{ Ok = $false; Detail = ('inspeacao da raiz falhando: ' + $rootNorm) }
      }
    }
    else {
      return @{ Ok = $false; Detail = ('raiz inexistente (ancestry nao verificavel): ' + $Root) }
    }
  }
  catch {
    return @{ Ok = $false; Detail = ('inspeacao da raiz falhando: ' + $Root) }
  }
   # Inspect the full ancestry, including parents above the declared root.
   # A junction above ProfileDir also redirects every confined child path.
   $cursor = $pathNorm
   while (-not [string]::IsNullOrWhiteSpace($cursor)) {
    if (Test-Path -LiteralPath $cursor) {
      try {
       $attrs = (Get-Item -Force -LiteralPath $cursor -ErrorAction Stop).Attributes
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          return @{ Ok = $false; Detail = ('atravessa reparse point: ' + $cursor) }
        }
      }
      catch {
        return @{ Ok = $false; Detail = ('inspeacao de ancestral falhando: ' + $cursor) }
      }
    }
    $parent = $cursor
     try { $parent = (Split-Path -Parent $cursor) } catch { return @{ Ok = $false; Detail = 'ancestry inspection failed' } }
    if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $cursor)) { break }
     $cursor = $parent
   }
   return @{ Ok = $true; Detail = 'full ancestry sem reparse' }
}

function Test-PreflightConfinedEnv {
  param($EnvTable = $null, [string]$ProfileDir = '', [string]$ConfigRoot = '')
  if ($null -eq $EnvTable) {
    return @{ Ok = $false; Detail = 'EnvTable ausente (XDG exigido).' }
  }
  $xdg = ''
  try { $xdg = [string]$EnvTable['XDG_CONFIG_HOME'] } catch { $xdg = '' }
  if ([string]::IsNullOrWhiteSpace($xdg)) {
    return @{ Ok = $false; Detail = 'XDG_CONFIG_HOME vazio (mutacao recusada).' }
  }
  $profNorm = ''
  try { $profNorm = ([IO.Path]::GetFullPath($ProfileDir)).TrimEnd('\') } catch { $profNorm = '' }
  $xdgNorm = ''
  try { $xdgNorm = ([IO.Path]::GetFullPath($xdg)).TrimEnd('\') } catch { $xdgNorm = '' }
  if ([string]::IsNullOrWhiteSpace($profNorm) -or [string]::IsNullOrWhiteSpace($xdgNorm)) {
    return @{ Ok = $false; Detail = 'XDG_CONFIG_HOME ou ProfileDir nao normalizavel.' }
  }
  if (-not ($xdgNorm.StartsWith($profNorm + '\', [StringComparison]::OrdinalIgnoreCase) -or $xdgNorm.Equals($profNorm, [StringComparison]::OrdinalIgnoreCase))) {
    return @{ Ok = $false; Detail = ('XDG_CONFIG_HOME fora do perfil (divergente): ' + $xdg) }
  }
  # RR-P22-FIX2: ancestry com reparse tambem vale para o config root.
  $xdgAnc = Test-PreflightNoReparseAncestry -Path $xdg -Root $profNorm
  if (-not [bool]$xdgAnc.Ok) {
    return @{ Ok = $false; Detail = ('XDG_CONFIG_HOME com reparse (' + [string]$xdgAnc.Detail + ').') }
  }
  if (-not [string]::IsNullOrWhiteSpace($ConfigRoot)) {
    try {
      $cfgNorm = ([IO.Path]::GetFullPath($ConfigRoot)).TrimEnd('\')
      if (-not $xdgNorm.Equals($cfgNorm, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Ok = $false; Detail = ('XDG_CONFIG_HOME divergente do config_root do manifest.') }
      }
    }
    catch { }
  }
  foreach ($k in @('XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'HOME', 'USERPROFILE')) {
    $v = ''
    try { $v = [string]$EnvTable[$k] } catch { $v = '' }
     if ([string]::IsNullOrWhiteSpace($v)) {
       return @{ Ok = $false; Detail = ($k + ' missing from effective isolated environment') }
     }
    # RR-P22-FIX2: sem fallback lexical (TEMP nao e prova de confinamento).
    # Todo path de config/state/data/cache/marker deve estar sob o perfil E
    # sem reparse na ancestry.
    $anc = Test-PreflightNoReparseAncestry -Path $v -Root $profNorm
    if (-not [bool]$anc.Ok) {
      return @{ Ok = $false; Detail = ($k + ' fora do perfil ou com reparse (' + [string]$anc.Detail + ').') }
    }
  }
  return @{ Ok = $true; Detail = 'env confinado ao perfil' }
}

function Get-PreflightEffectiveEnv {
  param($EnvTable = $null, [string]$ProfileDir = '')
  $eff = @{}
  if ($null -ne $EnvTable) {
    foreach ($k in @($EnvTable.Keys)) {
      try { $eff[[string]$k] = [string]$EnvTable[$k] } catch { }
    }
  }
  try {
    $homeD = Join-Path $ProfileDir 'home'
    $pairs = @(
      @('XDG_STATE_HOME', (Join-Path $homeD '.local\state')),
      @('XDG_DATA_HOME', (Join-Path $homeD '.local\share')),
      @('XDG_CACHE_HOME', (Join-Path $homeD '.local\cache')),
      @('HOME', $homeD),
      @('USERPROFILE', $homeD)
    )
    foreach ($pr in $pairs) {
      $kk = [string]$pr[0]
      if ([string]::IsNullOrWhiteSpace([string]$eff[$kk])) { $eff[$kk] = [string]$pr[1] }
    }
  }
  catch { }
  return $eff
}

function Test-PreflightProfileEmptyState {
  param($EffEnv = $null, [string]$ProfileDir = '')
  # RR-P22-NATIVE-IMPLEMENT: prova de empty-state POR PERFIL para autorizar
  # `service set port` de porta alternativa SEM consultar a porta global 49374.
  # Empty=true SOMENTE com prova conjunta: state dir do perfil (XDG_STATE_HOME
  # efetivo + /opencode) inexistente ou com 0 itens E service.json do perfil
  # ausente ou legivel com {port} numerico/ausente. Query de state inexistente
  # = nenhum servico do perfil (set nao para/derruba nada owned). Sem prova =>
  # Empty=false (fail-closed; possivel servico owned, stop fora de escopo).
  # Nunca olha/mata 49374; nunca executa processo; anti-reparse preservado.
  $res = @{ Empty = $false; Detail = 'nao avaliado.'; StatePath = ''; StateItems = -1; NativeConfig = ''; CurrentDesired = '' }
  if ($null -eq $EffEnv) {
    $res.Detail = 'env efetivo ausente (sem prova de vazio).'
    return $res
  }
  $sh = ''
  $ch = ''
  try { $sh = [string]$EffEnv['XDG_STATE_HOME'] } catch { $sh = '' }
  try { $ch = [string]$EffEnv['XDG_CONFIG_HOME'] } catch { $ch = '' }
  if ([string]::IsNullOrWhiteSpace($sh) -or [string]::IsNullOrWhiteSpace($ch)) {
    $res.Detail = 'XDG_STATE_HOME/XDG_CONFIG_HOME efetivos ausentes (sem prova de vazio).'
    return $res
  }
  $stateOp = ''
  $svcJson = ''
  try { $stateOp = (Join-Path $sh 'opencode') } catch { $stateOp = '' }
  try { $svcJson = (Join-Path (Join-Path $ch 'opencode') 'service.json') } catch { $svcJson = '' }
  $res.StatePath = $stateOp
  $res.NativeConfig = $svcJson
  if ([string]::IsNullOrWhiteSpace($stateOp) -or [string]::IsNullOrWhiteSpace($svcJson)) {
    $res.Detail = 'state/config do perfil nao normalizaveis (sem prova de vazio).'
    return $res
  }
  $stAnc = Test-PreflightNoReparseAncestry -Path $stateOp -Root $ProfileDir
  if (-not [bool]$stAnc.Ok) {
    $res.Detail = ('state do perfil com ancestry invalida (sem prova de vazio): ' + [string]$stAnc.Detail)
    return $res
  }
  $cfgAnc = Test-PreflightNoReparseAncestry -Path $svcJson -Root $ProfileDir
  if (-not [bool]$cfgAnc.Ok) {
    $res.Detail = ('config do perfil com ancestry invalida (sem prova de vazio): ' + [string]$cfgAnc.Detail)
    return $res
  }
  if (Test-Path -LiteralPath $stateOp) {
    try {
      $it = (Get-Item -Force -LiteralPath $stateOp -ErrorAction Stop)
    }
    catch {
      $res.Detail = ('state do perfil nao inspecionavel (sem prova de vazio): ' + $stateOp)
      return $res
    }
    if (($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      $res.Detail = ('state do perfil e reparse point (sem prova de vazio): ' + $stateOp)
      return $res
    }
    if (($it.Attributes -band [IO.FileAttributes]::Directory) -eq 0) {
      $res.Detail = ('state do perfil nao e diretorio (sem prova de vazio): ' + $stateOp)
      return $res
    }
    try {
      $kids = @(Get-ChildItem -Force -LiteralPath $stateOp -ErrorAction Stop)
      $res.StateItems = [int]$kids.Count
    }
    catch {
      $res.Detail = ('conteudo do state nao listavel (sem prova de vazio): ' + $stateOp)
      return $res
    }
    if ([int]$res.StateItems -gt 0) {
      $res.Detail = ('state do perfil com ' + [int]$res.StateItems + ' item(ns): possivel servico owned (set recusado sem prova de stop): ' + $stateOp)
      return $res
    }
  }
  else {
    $res.StateItems = 0
  }
  if (Test-Path -LiteralPath $svcJson -PathType Leaf) {
    try {
      $attrs = (Get-Item -Force -LiteralPath $svcJson -ErrorAction Stop).Attributes
      if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $res.Detail = ('service.json e reparse point (sem prova de vazio): ' + $svcJson)
        return $res
      }
    }
    catch {
      $res.Detail = ('service.json nao inspecionavel (sem prova de vazio): ' + $svcJson)
      return $res
    }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($svcJson, [Text.Encoding]::UTF8) } catch { $raw = '' }
    if ($raw.Length -gt 65536) {
      $res.Detail = 'service.json grande demais para leitura bounded (sem prova de vazio).'
      return $res
    }
    $sj = $null
    try { $sj = ($raw | ConvertFrom-Json) } catch { $sj = $null }
    if ($null -eq $sj) {
      $res.Detail = ('service.json ilegivel (sem prova de vazio; sem overwrite cego): ' + $svcJson)
      return $res
    }
    $hasPort = $false
    try { $hasPort = ($null -ne $sj.port) } catch { $hasPort = $false }
    if ($hasPort) {
      $pn = 0
      try { $pn = [int]$sj.port } catch { $pn = 0 }
      if (($pn -lt 1) -or ($pn -gt 65535)) {
        $res.Detail = ('service.json com port nao numerico (' + [string]$sj.port + '): sem prova de vazio.')
        return $res
      }
      $res.CurrentDesired = [string]$pn
    }
    else {
      $res.CurrentDesired = '(default implicito; sem service.json port)'
    }
  }
  else {
    $res.CurrentDesired = '(ausente; default implicito)'
  }
  $res.Empty = $true
  $res.Detail = ('perfil vazio provado: state ' + $stateOp + ' com ' + [int]$res.StateItems + ' item(ns); desired nativo atual ' + [string]$res.CurrentDesired + '; 49374 global nao consultado.')
  return $res
}

function Invoke-PreflightServiceSetPort {
  param(
    [string]$BinaryPath = '',
    [int]$Port = 0,
    $EnvTable = $null,
    [string[]]$EnvRemove = @(),
    [string]$WorkingDirectory = '',
    [int]$TimeoutMs = 30000,
    [string]$ExpectedVersion = '',
    [bool]$RequireExactVersion = $true,
    [string]$ProfileDir = '',
    [string]$ExpectedBinaryPath = ''
  )
  Assert-PreflightPort -Port $Port
  if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
    return @{ Ok = $false; Output = 'binario vazio (mutacao recusada).' }
  }
  # Pin exato nunca vem de literal desta lib (standalone): ausente = fail-closed.
  if ($RequireExactVersion -and [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    return @{ Ok = $false; Output = 'expected version vazia; pin deve vir do registry via chamador (mutacao recusada).' }
  }
  if (-not $BinaryPath.ToLowerInvariant().EndsWith('.exe')) {
    return @{ Ok = $false; Output = ('binario deve ser .exe (mutacao recusada; sem shell/cmd): ' + $BinaryPath) }
  }
  if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
    return @{ Ok = $false; Output = ('binario inexistente: ' + $BinaryPath) }
  }
  if (Test-PreflightCmdMetachars -Text $BinaryPath) {
    return @{ Ok = $false; Output = 'binario com metachar sensivel recusado.' }
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedBinaryPath)) {
    try {
      $a = ([IO.Path]::GetFullPath($ExpectedBinaryPath)).TrimEnd('\')
      $b = ([IO.Path]::GetFullPath($BinaryPath)).TrimEnd('\')
      if (-not $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Ok = $false; Output = 'binario divergente do esperado (mutacao recusada).' }
      }
    }
    catch {
      if (-not ([string]$ExpectedBinaryPath).Equals($BinaryPath, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Ok = $false; Output = 'binario divergente do esperado (mutacao recusada).' }
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
    return @{ Ok = $false; Output = 'ProfileDir vazio (mutacao recusada: service set port exige perfil).' }
  }
  $mv = Test-PreflightProfileManifestV2 -ProfileDir $ProfileDir
  if (-not [bool]$mv.Ok) {
    return @{ Ok = $false; Output = ('perfil v2 sem prova (mutacao recusada): ' + [string]$mv.Detail) }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$mv.ProvisionedBinary)) {
    try {
      $a = ([IO.Path]::GetFullPath([string]$mv.ProvisionedBinary)).TrimEnd('\')
      $b = ([IO.Path]::GetFullPath($BinaryPath)).TrimEnd('\')
      if (-not $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Ok = $false; Output = 'binario divergente do provisioned do manifest (mutacao recusada).' }
      }
    }
    catch { }
  }
  $rm = New-Object System.Collections.ArrayList
  foreach ($r in @($EnvRemove)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$r)) { [void]$rm.Add([string]$r) }
  }
  foreach ($k in @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH')) {
    if ($rm -notcontains $k) { [void]$rm.Add($k) }
  }
  $wd = $WorkingDirectory
  if ([string]::IsNullOrWhiteSpace($wd)) { $wd = [IO.Path]::GetTempPath() }
  $effEnv = Get-PreflightEffectiveEnv -EnvTable $EnvTable -ProfileDir $ProfileDir
  # RR-P22-FIX3 (D): valida o env EFETIVO (apos defaults + EnvRemove) antes de
  # iniciar qualquer mutador (--version inclusive). Sem variaveis obrigatorias
  # ou com anti-reparse em QUALQUER default => HOLD estruturado conservador
  # (API preservada + chave Hold); nunca inicia processo. Progresso parcial
  # honesto: efeito nativo nao confirmado nesta phase.
  $effCheck = @{}
  try {
    foreach ($kk in @($effEnv.Keys)) { $effCheck[[string]$kk] = [string]$effEnv[$kk] }
    foreach ($rr in @($rm)) {
      try { [void]$effCheck.Remove([string]$rr) } catch { }
    }
  }
  catch { }
  $ev = Test-PreflightConfinedEnv -EnvTable $effCheck -ProfileDir $ProfileDir -ConfigRoot ([string]$mv.ConfigRoot)
  if (-not [bool]$ev.Ok) {
    return @{ Ok = $false; Hold = 'NATIVE_PORT_CONFIGURATION_HOLD'; Output = ('NATIVE_PORT_CONFIGURATION_HOLD: env efetivo nao confinado/seguro (mutacao recusada antes de qualquer mutador): ' + [string]$ev.Detail) }
  }
  $ver = Invoke-PreflightBoundedExe -File $BinaryPath -ArgsLine '--version' -WorkDir $wd -EnvTable $effEnv -EnvRemove @($rm) -TimeoutMs 30000
  if ([bool]$ver.TimedOut -or (-not [bool]$ver.Finished)) {
    return @{ Ok = $false; Output = '--version timeout (binario nao responde; filho proprio encerrado)' }
  }
  if ([int]$ver.ExitCode -ne 0) {
    return @{ Ok = $false; Output = ('--version exit ' + [int]$ver.ExitCode + ': ' + [string]$ver.Output) }
  }
  if ($RequireExactVersion) {
    $rx = '(?m)^opencode v' + [regex]::Escape($ExpectedVersion) + '\s*$'
    if (-not ([regex]::IsMatch([string]$ver.Output, $rx))) {
      return @{ Ok = $false; Output = ('versao exata ' + $ExpectedVersion + ' nao confirmada; service set port recusado (prova de versao exata exigida; pin do registry). Obtido: ' + (([string]$ver.Output -split "`r?`n" | Select-Object -First 1))) }
    }
  }
  $free = Get-PreflightListener -Port $Port
  if (-not (Get-PreflightListenerQueryOk -Listener $free)) {
    return @{ Ok = $false; Output = ('porta ' + $Port + ' com query sem sucesso (service set port recusado; fail-closed)') }
  }
  if ([bool]$free.Exists) {
    return @{ Ok = $false; Output = ('porta ' + $Port + ' ocupada (PID ' + $free.OwningPID + '); service set port recusado sem matar PID') }
  }
  # RR-P22-NATIVE-IMPLEMENT (substitui gate global FIX2): 'debug config' no
  # binario V2 de pin 2.0.18 inicia serve --service (efeito de start).
  # Warmup/start/status
  # pos-set REMOVIDOS deste helper: nenhuma chamada que possa parar/iniciar
  # servico. O gate global na porta nativa 49374 foi REMOVIDO por ser indevido:
  # 49374 ocupada por outro servico/processo (ex. ssh port-forward) nao pode
  # impedir SET de porta alternativa para perfil isolado VAZIO. No lugar,
  # prova de empty-state POR PERFIL (state inexistente/vazio + desired nativo
  # atual lido do service.json do perfil). Sem prova => fail-closed, sem
  # olhar/matar 49374, sem claim.
  $emptyProof = Test-PreflightProfileEmptyState -EffEnv $effCheck -ProfileDir $ProfileDir
  if (-not [bool]$emptyProof.Empty) {
    return @{ Ok = $false; Output = ('service set port recusado: perfil sem prova de vazio (possivel servico owned; stop fora de escopo; 49374 global nao consultado): ' + [string]$emptyProof.Detail) }
  }
  # RR-P22-FIX2: marker/profile com ancestry anti-reparse antes de mutar.
  $mfPath = Join-Path $ProfileDir 'manifest.json'
  $mfAnc = Test-PreflightNoReparseAncestry -Path $mfPath -Root $ProfileDir
  if (-not [bool]$mfAnc.Ok) {
    return @{ Ok = $false; Output = ('manifest do perfil com ancestry invalida (mutacao recusada): ' + [string]$mfAnc.Detail) }
  }
  $set = Invoke-PreflightBoundedExe -File $BinaryPath -ArgsLine ('service set port ' + $Port) -WorkDir $wd -EnvTable $effEnv -EnvRemove @($rm) -TimeoutMs $TimeoutMs
  if ([bool]$set.TimedOut -or (-not [bool]$set.Finished)) {
    return @{ Ok = $false; Output = ('service set port timeout apos ' + $TimeoutMs + 'ms (filho direto encerrado; descendants sem prova, BLOCKER RR-P22-FIX2)') }
  }
  if ([bool]$set.Truncated) {
    return @{ Ok = $false; Output = 'service set port com leitura truncada/incompleta (sem claim; fail-closed)' }
  }
  if ([int]$set.ExitCode -ne 0) {
    return @{ Ok = $false; Output = ('service set port exit ' + [int]$set.ExitCode + ': ' + [string]$set.Output) }
  }
  # RR-P22-FIX2: exit 0 do set persiste SOMENTE pending (desired). Sem
  # debug config/warmup/status: efeito nativo nao confirmado nesta phase
  # (confirmacao exigiria prova de instancia, HOLD). Nunca claim applied.
  try {
    $saved = Set-PreflightPersistedPort -ProfileDir $ProfileDir -Port $Port -Source 'service-set-pending' -State 'pending'
    return @{ Ok = $true; Output = ([string]$set.Output + "`n" + 'persistido como pending (desired; applied exige prova de instancia, HOLD RR-P22-FIX2)' + "`n" + 'empty-state: ' + [string]$emptyProof.Detail); PersistedPath = [string]$saved.Path; EmptyStateDetail = [string]$emptyProof.Detail; PreviousDesired = [string]$emptyProof.CurrentDesired }
  }
  catch {
    return @{ Ok = $false; Output = ('set ok mas persistencia pending falhou: ' + $_.Exception.Message) }
  }
}

function Resolve-PreflightNativeExe {
  param(
    [string]$ProfileDir = '',
    [string[]]$Candidates = @(),
    [string]$ExpectedVersion = '',
    $EnvTable = $null,
    [int]$TimeoutMs = 15000
  )
  # RR-P22-WRAPPER: resolve o .exe exato sob o pacote, sem inferencia PATH.
  # O manifest provisionado atual grava o shim .cmd; mutacao exige .exe.
  # Nunca consulta PATH; nunca executa shell. Pin exato via --version bounded.
  $diag = New-Object System.Collections.ArrayList
  if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
    return @{ Ok = $false; Exe = ''; Version = ''; Detail = 'ProfileDir vazio (resolve recusado).' }
  }
  # Pin exato nunca vem de literal desta lib (standalone): ausente = recusado.
  if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    return @{ Ok = $false; Exe = ''; Version = ''; Detail = 'expected version vazia; pin deve vir do registry via chamador (resolve recusado).' }
  }
  $mv = Test-PreflightProfileManifestV2 -ProfileDir $ProfileDir
  if (-not [bool]$mv.Ok) {
    return @{ Ok = $false; Exe = ''; Version = ''; Detail = ('perfil v2 sem prova (resolve recusado): ' + [string]$mv.Detail) }
  }
  $exeCands = New-Object System.Collections.ArrayList
  $seen = @{}
  $allRaw = New-Object System.Collections.ArrayList
  foreach ($c in @($Candidates)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$c)) { [void]$allRaw.Add([string]$c) }
  }
  try {
    if (-not [string]::IsNullOrWhiteSpace([string]$mv.ProvisionedBinary)) { [void]$allRaw.Add([string]$mv.ProvisionedBinary) }
  }
  catch { }
  try {
    $known = Join-Path $ProfileDir 'runtime\node_modules\@opencode\cli\bin\opencode.exe'
    [void]$allRaw.Add($known)
  }
  catch { }
  foreach ($raw in @($allRaw)) {
    $r = [string]$raw
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    if (Test-PreflightCmdMetachars -Text $r) {
      [void]$diag.Add(('candidato com metachar recusado: ' + $r))
      continue
    }
    try {
      if ($r.ToLowerInvariant().EndsWith('.exe')) {
        if (Test-Path -LiteralPath $r -PathType Leaf) {
          $k = ([IO.Path]::GetFullPath($r)).TrimEnd('\').ToLowerInvariant()
          if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$exeCands.Add($r) }
        }
        continue
      }
    }
    catch { }
    try {
      if ($r.ToLowerInvariant().EndsWith('.cmd')) {
        $sameExe = [regex]::Replace($r, '(?i)\.cmd$', '.exe')
        try {
          if (Test-Path -LiteralPath $sameExe -PathType Leaf) {
            $k = ([IO.Path]::GetFullPath($sameExe)).TrimEnd('\').ToLowerInvariant()
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$exeCands.Add($sameExe) }
          }
        }
        catch { }
        try {
          $binDir = Split-Path -Parent $r
          $nodeMods = Split-Path -Parent $binDir
          $runtimeGuess = Split-Path -Parent $nodeMods
          $pkgExe = Join-Path $runtimeGuess 'node_modules\@opencode\cli\bin\opencode.exe'
          if (Test-Path -LiteralPath $pkgExe -PathType Leaf) {
            $k = ([IO.Path]::GetFullPath($pkgExe)).TrimEnd('\').ToLowerInvariant()
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$exeCands.Add($pkgExe) }
          }
        }
        catch { }
        continue
      }
    }
    catch { }
  }
  try {
    $known2 = Join-Path $ProfileDir 'runtime\node_modules\@opencode\cli\bin\opencode.exe'
    if (Test-Path -LiteralPath $known2 -PathType Leaf) {
      $k = ([IO.Path]::GetFullPath($known2)).TrimEnd('\').ToLowerInvariant()
      if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; [void]$exeCands.Add($known2) }
    }
  }
  catch { }
  if ($exeCands.Count -eq 0) {
    return @{ Ok = $false; Exe = ''; Version = ''; Detail = ('nenhum .exe exato sob o pacote (sem PATH; shim .cmd nao prova ownership). ' + (($diag -join '; '))) }
  }
  $baseEnv = $EnvTable
  if ($null -eq $baseEnv) {
    $baseEnv = @{ XDG_CONFIG_HOME = [string]$mv.ConfigRoot }
  }
  $effEnv = Get-PreflightEffectiveEnv -EnvTable $baseEnv -ProfileDir $ProfileDir
  $rx = '(?m)^opencode v' + [regex]::Escape($ExpectedVersion) + '\s*$'
  foreach ($exe in @($exeCands)) {
    # RR-P22-WRAPPER-FIX2: ancestry FULL do candidato ANTES de qualquer
    # processo (--version inclusive). Root = diretorio pai do exe (lexical
    # sob o pai + walk completo ate o volume via lib). Rejeitado => nenhum
    # processo e iniciado (zero invocacoes).
    $exeParent = ''
    try { $exeParent = (Split-Path -Parent $exe) } catch { $exeParent = '' }
    if ([string]::IsNullOrWhiteSpace($exeParent)) {
      [void]$diag.Add(('candidato sem diretorio pai verificavel (sem processo): ' + $exe))
      continue
    }
    $exeAnc = $null
    try { $exeAnc = Test-PreflightNoReparseAncestry -Path $exe -Root $exeParent } catch { $exeAnc = $null }
    if (($null -eq $exeAnc) -or (-not [bool]$exeAnc.Ok)) {
      $dAnc = ''
      try { $dAnc = [string]$exeAnc.Detail } catch { $dAnc = 'ancestry nao verificavel' }
      [void]$diag.Add(('candidato com ancestry invalida (sem processo): ' + $exe + ' (' + $dAnc + ')'))
      continue
    }
    try {
      $exeAttrs = (Get-Item -Force -LiteralPath $exe -ErrorAction Stop).Attributes
      if (($exeAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [void]$diag.Add(('candidato e reparse point (sem processo): ' + $exe))
        continue
      }
    }
    catch {
      [void]$diag.Add(('candidato nao inspecionavel (sem processo): ' + $exe))
      continue
    }
    $ver = Invoke-PreflightBoundedExe -File $exe -ArgsLine '--version' -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $effEnv -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs $TimeoutMs
    if ([bool]$ver.TimedOut -or (-not [bool]$ver.Finished)) { continue }
    if ([int]$ver.ExitCode -ne 0) { continue }
    if ([bool]$ver.Truncated) { continue }
    try {
      if ([regex]::IsMatch([string]$ver.Output, $rx)) {
        $line = (([string]$ver.Output -split "`r?`n" | Select-Object -First 1).Trim())
        return @{ Ok = $true; Exe = $exe; Version = $line; Detail = ('exe exato ' + $ExpectedVersion + ' sob o pacote: ' + $exe) }
      }
    }
    catch { continue }
  }
  return @{ Ok = $false; Exe = ''; Version = ''; Detail = ('nenhum candidato com versao exata ' + $ExpectedVersion + ' (pin exigido; sem PATH).') }
}

function Get-PreflightNativeServicePort {
  param(
    [string]$BinaryPath = '',
    $EnvTable = $null,
    [int]$TimeoutMs = 15000,
    $RunnerOverride = $null
  )
  # Leitura read-only: `service get port` bounded com env isolado.
  # Retorna @{ Ok; Port (0 = default implicito, sem service.json); Raw; Detail }.
  # Ok=false = desconhecido (timeout/incompleto/exit!=0/nao-numerico): bloqueia.
  if ($null -ne $RunnerOverride) {
    try {
      $rr = (& $RunnerOverride)
      if ($null -eq $rr) { return @{ Ok = $false; Port = 0; Raw = ''; Detail = 'override nulo (desconhecido).' } }
      return $rr
    }
    catch {
      return @{ Ok = $false; Port = 0; Raw = ''; Detail = ('override falhou (desconhecido): ' + $_.Exception.Message) }
    }
  }
  if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
    return @{ Ok = $false; Port = 0; Raw = ''; Detail = 'binario vazio (get recusado).' }
  }
  if (-not $BinaryPath.ToLowerInvariant().EndsWith('.exe')) {
    return @{ Ok = $false; Port = 0; Raw = ''; Detail = 'binario deve ser .exe (get recusado; sem shell).' }
  }
  $wd = [IO.Path]::GetTempPath()
  $r = Invoke-PreflightBoundedExe -File $BinaryPath -ArgsLine 'service get port' -WorkDir $wd -EnvTable $EnvTable -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs $TimeoutMs
  if ([bool]$r.TimedOut -or (-not [bool]$r.Finished)) {
    return @{ Ok = $false; Port = 0; Raw = [string]$r.Output; Detail = 'service get port timeout/incompleto (desconhecido; filho direto encerrado).' }
  }
  if ([bool]$r.Truncated) {
    return @{ Ok = $false; Port = 0; Raw = [string]$r.Output; Detail = 'service get port com leitura truncada (desconhecido).' }
  }
  if ([int]$r.ExitCode -ne 0) {
    return @{ Ok = $false; Port = 0; Raw = [string]$r.Output; Detail = ('service get port exit ' + [int]$r.ExitCode + ' (desconhecido).') }
  }
  $t = ([string]$r.Output).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) {
    return @{ Ok = $true; Port = 0; Raw = ''; Detail = 'default implicito (get vazio, exit 0; sem service.json).' }
  }
  $first = (($t -split "`r?`n" | Select-Object -First 1).Trim())
  $n = 0
  try { $n = [int]$first } catch { $n = 0 }
  if (($n -lt 1) -or ($n -gt 65535) -or ([string]$n -cne $first)) {
    return @{ Ok = $false; Port = 0; Raw = $t; Detail = ('service get port nao-numerico (desconhecido): ' + $first) }
  }
  return @{ Ok = $true; Port = $n; Raw = $t; Detail = ('service get port=' + $n) }
}

function Get-PreflightNativeServiceConfig {
  param($EffEnv = $null, [string]$ProfileDir = '')
  # Leitura read-only do service.json NATIVO sob o XDG efetivo (mesmo env final).
  # Retorna @{ Ok; Exists; Port (0 = ausente/sem port); Detail }.
  # Ok=false = ilegivel/invalido/grande/reparse: bloqueia (sem overwrite cego).
  $res = @{ Ok = $false; Exists = $false; Port = 0; Detail = 'nao avaliado.'; Path = '' }
  if ($null -eq $EffEnv) {
    $res.Detail = 'env efetivo ausente (config nao legivel).'
    return $res
  }
  $ch = ''
  try { $ch = [string]$EffEnv['XDG_CONFIG_HOME'] } catch { $ch = '' }
  if ([string]::IsNullOrWhiteSpace($ch)) {
    $res.Detail = 'XDG_CONFIG_HOME efetivo ausente (config nao legivel).'
    return $res
  }
  $svc = ''
  try { $svc = (Join-Path (Join-Path $ch 'opencode') 'service.json') } catch { $svc = '' }
  $res.Path = $svc
  if ([string]::IsNullOrWhiteSpace($svc)) {
    $res.Detail = 'service.json nao normalizavel.'
    return $res
  }
  if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) {
    $anc = Test-PreflightNoReparseAncestry -Path $svc -Root $ProfileDir
    if (-not [bool]$anc.Ok) {
      $res.Detail = ('service.json com ancestry invalida: ' + [string]$anc.Detail)
      return $res
    }
  }
  if (-not (Test-Path -LiteralPath $svc -PathType Leaf)) {
    $res.Ok = $true
    $res.Exists = $false
    $res.Port = 0
    $res.Detail = 'service.json ausente (default implicito).'
    return $res
  }
  $res.Exists = $true
  try {
    $attrs = (Get-Item -Force -LiteralPath $svc -ErrorAction Stop).Attributes
    if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      $res.Detail = 'service.json e reparse point.'
      return $res
    }
  }
  catch {
    $res.Detail = 'service.json nao inspecionavel.'
    return $res
  }
  $raw = ''
  try { $raw = [IO.File]::ReadAllText($svc, [Text.Encoding]::UTF8) } catch { $raw = '' }
  if ($raw.Length -gt 65536) {
    $res.Detail = 'service.json grande demais (leitura bounded).'
    return $res
  }
  $sj = $null
  try { $sj = ($raw | ConvertFrom-Json) } catch { $sj = $null }
  if ($null -eq $sj) {
    $res.Detail = 'service.json ilegivel (sem overwrite cego).'
    return $res
  }
  $hasPort = $false
  try { $hasPort = ($null -ne $sj.port) } catch { $hasPort = $false }
  if (-not $hasPort) {
    $res.Ok = $true
    $res.Port = 0
    $res.Detail = 'service.json sem port (default implicito).'
    return $res
  }
  $pn = 0
  try { $pn = [int]$sj.port } catch { $pn = 0 }
  if (($pn -lt 1) -or ($pn -gt 65535) -or ([string]$pn -cne ([string]$sj.port).Trim())) {
    $last = ''
    try { $last = [string]$sj.port } catch { $last = '' }
    if (($pn -lt 1) -or ($pn -gt 65535)) {
      $res.Detail = ('service.json com port nao-numerico (' + $last + ').')
      return $res
    }
  }
  $res.Ok = $true
  $res.Port = $pn
  $res.Detail = ('service.json port=' + $pn)
  return $res
}

function Ensure-PreflightConfiguredPort {
  param(
    [string]$ProfileDir = '',
    [int]$ExplicitPort = 0,
    [string]$ChosenBinary = '',
    [int]$TimeoutMs = 15000,
    $ListenerOverride = $null,
    $ExcludedRangesOverride = $null,
    [bool]$ExcludedQueryAvailableOverride = $true,
    $NativeGetOverride = $null,
    $NativeConfigOverride = $null,
    $SetPortRunnerOverride = $null,
    $ResolveOverride = $null,
    [string]$ExpectedVersion = ''
  )
  # RR-P22-WRAPPER: gate central do wrapper V2 (lib; sem inline duplicado).
  # Marker pending SOZINHO nunca autoriza: exige get+service.json==desired
  # (configuration-verified) + preflight PORT_FREE. Sem marker => bloqueia com
  # instrucao acionavel (-ServicePort). Desconhecido/ocupado/reservado =>
  # bloqueia. Desired confirmado+livre => permite executar o escolhido.
  # ShouldReuse permanece false mesmo owned (HOLD). Set nativo SOMENTE com
  # empty-state provado + ExplicitPort igual ao desired (nunca default
  # implicito 49374). Recheck get/config apos set; marker segue pending
  # (sem claim applied). Timeout externo 15s; falha desconhecida => blocker.
  $diag = New-Object System.Collections.ArrayList
  $block = {
    param($detail, $hold)
    $o = [ordered]@{
      Permitted = $false
      Exe = ''
      Env = $null
      Desired = 0
      Outcome = 'BLOCKED'
      Detail = [string]$detail
      Diagnostics = @($diag)
      Hold = [string]$hold
    }
    return $o
  }
  try {
    if ([string]::IsNullOrWhiteSpace($ProfileDir)) {
      [void]$diag.Add('ProfileDir vazio.')
      return (& $block 'perfil vazio (startup bloqueado).' 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
      [void]$diag.Add('ProfileDir inexistente.')
      return (& $block ('perfil inexistente: ' + $ProfileDir) 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if (($ExplicitPort -lt 0) -or ($ExplicitPort -gt 65535)) {
      [void]$diag.Add('ExplicitPort fora de 1..65535.')
      return (& $block ('-ServicePort invalida (esperado 1..65535): ' + $ExplicitPort) 'PORT_CONFIGURATION_UNVERIFIED')
    }
    $mv = $null
    # RR-P22-WRAPPER-FIX2: guards manifest/marker ANTES de qualquer READ.
    # Manifest: ancestry full sob o perfil + reparse check antes de ler.
    $mfGatePath = Join-Path $ProfileDir 'manifest.json'
    $mfGateAnc = $null
    try { $mfGateAnc = Test-PreflightNoReparseAncestry -Path $mfGatePath -Root $ProfileDir } catch { $mfGateAnc = $null }
    if (($null -eq $mfGateAnc) -or (-not [bool]$mfGateAnc.Ok)) {
      $dGate = ''
      try { $dGate = [string]$mfGateAnc.Detail } catch { $dGate = 'ancestry nao verificavel' }
      [void]$diag.Add(('manifest com ancestry invalida (leitura recusada): ' + $dGate))
      return (& $block ('perfil v2 sem prova: manifest com ancestry invalida (leitura recusada).') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if (Test-Path -LiteralPath $mfGatePath -PathType Leaf) {
      try {
        $mfGateAttrs = (Get-Item -Force -LiteralPath $mfGatePath -ErrorAction Stop).Attributes
        if (($mfGateAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          [void]$diag.Add('manifest e reparse point (leitura recusada).')
          return (& $block 'perfil v2 sem prova: manifest e reparse point (leitura recusada).' 'PORT_CONFIGURATION_UNVERIFIED')
        }
      }
      catch {
        [void]$diag.Add('manifest nao inspecionavel (leitura recusada).')
        return (& $block 'perfil v2 sem prova: manifest nao inspecionavel (leitura recusada).' 'PORT_CONFIGURATION_UNVERIFIED')
      }
    }
    $mv = Test-PreflightProfileManifestV2 -ProfileDir $ProfileDir
    if (-not [bool]$mv.Ok) {
      [void]$diag.Add([string]$mv.Detail)
      return (& $block ('perfil v2 sem prova: ' + [string]$mv.Detail) 'PORT_CONFIGURATION_UNVERIFIED')
    }
    [void]$diag.Add('manifest v2 ok.')
    $baseTable = @{ XDG_CONFIG_HOME = [string]$mv.ConfigRoot }
    $effEnv = Get-PreflightEffectiveEnv -EnvTable $baseTable -ProfileDir $ProfileDir
    $effCheck = @{}
    foreach ($kk in @($effEnv.Keys)) { $effCheck[[string]$kk] = [string]$effEnv[$kk] }
    $ev = Test-PreflightConfinedEnv -EnvTable $effCheck -ProfileDir $ProfileDir -ConfigRoot ([string]$mv.ConfigRoot)
    if (-not [bool]$ev.Ok) {
      [void]$diag.Add([string]$ev.Detail)
      return (& $block ('env efetivo nao confinado (startup bloqueado): ' + [string]$ev.Detail) 'NATIVE_PORT_CONFIGURATION_HOLD')
    }
    [void]$diag.Add('env efetivo confinado ao perfil (mesmo env final do wrapper).')
    $markerPath = Get-PreflightProfilePortPath -ProfileDir $ProfileDir
    # RR-P22-WRAPPER-FIX2: marker ancestry + symlink guard ANTES do READ.
    $mkGateAnc = $null
    try { $mkGateAnc = Test-PreflightNoReparseAncestry -Path $markerPath -Root $ProfileDir } catch { $mkGateAnc = $null }
    if (($null -eq $mkGateAnc) -or (-not [bool]$mkGateAnc.Ok)) {
      $dMk = ''
      try { $dMk = [string]$mkGateAnc.Detail } catch { $dMk = 'ancestry nao verificavel' }
      [void]$diag.Add(('marker com ancestry invalida (leitura recusada): ' + $dMk))
      return (& $block ('startup bloqueado: marker com ancestry invalida (leitura recusada).') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
      try {
        $mkGateAttrs = (Get-Item -Force -LiteralPath $markerPath -ErrorAction Stop).Attributes
        if (($mkGateAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          [void]$diag.Add('marker e reparse point/symlink (leitura recusada).')
          return (& $block 'startup bloqueado: marker e reparse point/symlink (leitura recusada).' 'PORT_CONFIGURATION_UNVERIFIED')
        }
      }
      catch {
        [void]$diag.Add('marker nao inspecionavel (leitura recusada).')
        return (& $block 'startup bloqueado: marker nao inspecionavel (leitura recusada).' 'PORT_CONFIGURATION_UNVERIFIED')
      }
    }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
      [void]$diag.Add('service-port.json ausente.')
      return (& $block ('startup bloqueado: sem service-port pending neste perfil. Configure com: powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ServicePort <porta-livre-verificada> (nunca 49374 ocupado); depois reinvoque o wrapper com -ServicePort <mesma-porta>.') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    $sjRaw = $null
    try { $sjRaw = (([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json) } catch { $sjRaw = $null }
    $sch = Test-PreflightServicePortSchema -Json $sjRaw
    if (-not [bool]$sch.Ok) {
      [void]$diag.Add([string]$sch.Detail)
      return (& $block ('startup bloqueado: marker sem schema pending exato (' + [string]$sch.Detail + '). Recrie com -ServicePort <porta-livre-verificada>.') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    $desired = [int]$sch.Port
    [void]$diag.Add(('marker pending desired=' + $desired + ' (sem claim applied).'))
    if ($ExplicitPort -eq 0) {
      [void]$diag.Add('ExplicitPort ausente.')
      return (& $block ('startup bloqueado: marker pending desired=' + $desired + ' exige -ServicePort explicito igual ao desired. Reinvoque o wrapper com -ServicePort ' + $desired + ' (nunca default implicito).') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if ([int]$ExplicitPort -ne $desired) {
      [void]$diag.Add(('ExplicitPort divergente do marker (explicit=' + $ExplicitPort + ' desired=' + $desired + ').'))
      return (& $block ('startup bloqueado: -ServicePort explicito (' + $ExplicitPort + ') diverge do desired do perfil (' + $desired + '). Reconcilie via New-OrchestrationProfile -ServicePort <porta-desejada>.') 'PORT_CONFIGURATION_UNVERIFIED')
    }
    if ($desired -eq 49374) {
      [void]$diag.Add('AVISO: desired 49374 e o default com colisao conhecida (AI Memory local); start so se livre e fora de faixa excluida.')
    }
    $resolvedExe = ''
    if ($null -ne $ResolveOverride) {
      try {
        if (-not [bool]$ResolveOverride.Ok) {
          [void]$diag.Add([string]$ResolveOverride.Detail)
          return (& $block ('binario exato indisponivel: ' + [string]$ResolveOverride.Detail) 'NATIVE_PORT_CONFIGURATION_HOLD')
        }
        $resolvedExe = [string]$ResolveOverride.Exe
      }
      catch {
        return (& $block 'resolve override invalido (blocker).' 'NATIVE_PORT_CONFIGURATION_HOLD')
      }
    }
    else {
      $cands = New-Object System.Collections.ArrayList
      if (-not [string]::IsNullOrWhiteSpace($ChosenBinary)) { [void]$cands.Add($ChosenBinary) }
      $rv = Resolve-PreflightNativeExe -ProfileDir $ProfileDir -Candidates @($cands) -ExpectedVersion $ExpectedVersion -EnvTable $baseTable -TimeoutMs $TimeoutMs
      if (-not [bool]$rv.Ok) {
        [void]$diag.Add([string]$rv.Detail)
        return (& $block ('binario exato indisponivel sob o pacote (sem PATH; pin ' + $ExpectedVersion + '): ' + [string]$rv.Detail) 'NATIVE_PORT_CONFIGURATION_HOLD')
      }
      $resolvedExe = [string]$rv.Exe
      [void]$diag.Add(('exe exato do pin: ' + $resolvedExe))
    }
    $getRes = $null
    if ($null -ne $NativeGetOverride) {
      try { $getRes = (& $NativeGetOverride) } catch { $getRes = @{ Ok = $false; Port = 0; Raw = ''; Detail = 'get override falhou.' } }
    }
    else {
      $getRes = Get-PreflightNativeServicePort -BinaryPath $resolvedExe -EnvTable $effEnv -TimeoutMs $TimeoutMs
    }
    [void]$diag.Add(('get: ' + [string]$getRes.Detail))
    $cfgRes = $null
    if ($null -ne $NativeConfigOverride) {
      try { $cfgRes = (& $NativeConfigOverride) } catch { $cfgRes = @{ Ok = $false; Exists = $false; Port = 0; Detail = 'config override falhou.' } }
    }
    else {
      $cfgRes = Get-PreflightNativeServiceConfig -EffEnv $effCheck -ProfileDir $ProfileDir
    }
    [void]$diag.Add(('config: ' + [string]$cfgRes.Detail))
    if ((-not [bool]$getRes.Ok) -or (-not [bool]$cfgRes.Ok)) {
      [void]$diag.Add('get/config desconhecido: fail-closed.')
      return (& $block ('startup bloqueado: configuracao nativa desconhecida (get/config sem prova). ' + [string]$getRes.Detail + ' / ' + [string]$cfgRes.Detail) 'PORT_STALE_OR_UNKNOWN')
    }
    $verified = (([int]$getRes.Port -eq $desired) -and ([int]$cfgRes.Port -eq $desired))
    if (-not $verified) {
      [void]$diag.Add(('mismatch/apenas-desired (get=' + [int]$getRes.Port + ' config=' + [int]$cfgRes.Port + ' desired=' + $desired + '): set SOMENTE com empty-state + explicit.'))
      $emptyProof = Test-PreflightProfileEmptyState -EffEnv $effCheck -ProfileDir $ProfileDir
      if (-not [bool]$emptyProof.Empty) {
        [void]$diag.Add([string]$emptyProof.Detail)
        return (& $block ('startup bloqueado: perfil sem prova de vazio para service set port (possivel servico owned; stop fora de escopo): ' + [string]$emptyProof.Detail) 'NATIVE_PORT_CONFIGURATION_HOLD')
      }
      [void]$diag.Add(('empty-state: ' + [string]$emptyProof.Detail))
      $setRes = $null
      if ($null -ne $SetPortRunnerOverride) {
        try { $setRes = (& $SetPortRunnerOverride) } catch { $setRes = @{ Ok = $false; Output = 'set override falhou.' } }
      }
      else {
        $setRes = Invoke-PreflightServiceSetPort -BinaryPath $resolvedExe -Port $desired -EnvTable $baseTable -ProfileDir $ProfileDir -TimeoutMs $TimeoutMs -ExpectedVersion $ExpectedVersion -RequireExactVersion $true
      }
      if (-not [bool]$setRes.Ok) {
        [void]$diag.Add([string]$setRes.Output)
        return (& $block ('startup bloqueado: service set port falhou: ' + [string]$setRes.Output) 'NATIVE_PORT_CONFIGURATION_HOLD')
      }
      [void]$diag.Add('set ok (pending; sem claim applied). Rechecando get/config.')
      $getRes2 = $null
      $cfgRes2 = $null
      if ($null -ne $NativeGetOverride) {
        try { $getRes2 = (& $NativeGetOverride) } catch { $getRes2 = @{ Ok = $false; Port = 0; Raw = ''; Detail = 'get override falhou no recheck.' } }
      }
      else {
        $getRes2 = Get-PreflightNativeServicePort -BinaryPath $resolvedExe -EnvTable $effEnv -TimeoutMs $TimeoutMs
      }
      if ($null -ne $NativeConfigOverride) {
        try { $cfgRes2 = (& $NativeConfigOverride) } catch { $cfgRes2 = @{ Ok = $false; Exists = $false; Port = 0; Detail = 'config override falhou no recheck.' } }
      }
      else {
        $cfgRes2 = Get-PreflightNativeServiceConfig -EffEnv $effCheck -ProfileDir $ProfileDir
      }
      [void]$diag.Add(('recheck get: ' + [string]$getRes2.Detail + '; recheck config: ' + [string]$cfgRes2.Detail))
      if ((-not [bool]$getRes2.Ok) -or (-not [bool]$cfgRes2.Ok) -or ([int]$getRes2.Port -ne $desired) -or ([int]$cfgRes2.Port -ne $desired)) {
        return (& $block ('startup bloqueado: recheck get/config divergente do desired apos set (sem claim).') 'PORT_STALE_OR_UNKNOWN')
      }
      try {
        $mk2 = (([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
        $sch2 = Test-PreflightServicePortSchema -Json $mk2
        if ((-not [bool]$sch2.Ok) -or ([int]$sch2.Port -ne $desired)) {
          return (& $block 'startup bloqueado: marker divergente apos set (sem claim applied).' 'PORT_CONFIGURATION_UNVERIFIED')
        }
      }
      catch {
        return (& $block 'startup bloqueado: marker ilegivel apos set.' 'PORT_CONFIGURATION_UNVERIFIED')
      }
      [void]$diag.Add('configuration-verified via set+recheck (desired-only; marker segue pending, sem claim applied).')
      $getRes = $getRes2
      $cfgRes = $cfgRes2
    }
    else {
      [void]$diag.Add('configuration-verified: get+service.json==desired (desejado; applied exige prova de start, sem claim).')
    }
    $pf = $null
    if ($null -ne $ListenerOverride -or $null -ne $ExcludedRangesOverride) {
      $exR = @()
      $exAvail = [bool]$ExcludedQueryAvailableOverride
      if ($null -ne $ExcludedRangesOverride) { $exR = @($ExcludedRangesOverride) }
      $pf = Invoke-PreflightPort -Port $desired -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($resolvedExe) -ExpectedProfileDir $ProfileDir -ListenerOverride $ListenerOverride -ExcludedRangesOverride $exR -ExcludedQueryAvailableOverride $exAvail
    }
    else {
      $pf = Invoke-PreflightPort -Port $desired -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($resolvedExe) -ExpectedProfileDir $ProfileDir
    }
    foreach ($d in @($pf.Diagnostics)) { [void]$diag.Add([string]$d) }
    if (([string]$pf.Outcome -eq 'PORT_FREE') -and [bool]$pf.ShouldStart) {
      [void]$diag.Add('PORT_FREE: start permitido (segundo start tambem exige rechecagem; reuse nunca assumido).')
      return [ordered]@{
        Permitted = $true
        Exe = $resolvedExe
        Env = $effCheck
        Desired = $desired
        Outcome = [string]$pf.Outcome
        Detail = ('configuration-verified + PORT_FREE em ' + $desired + ' (marker pending desired; sem claim applied; exe exato do pin ' + $ExpectedVersion + '; mesmo env final).')
        Diagnostics = @($diag)
        Hold = ''
      }
    }
    [void]$diag.Add(('preflight bloqueia start (ShouldReuse=' + [string]$pf.ShouldReuse + ' HOLD mesmo owned).'))
    $holdName = [string]$pf.Outcome
    if ([string]::IsNullOrWhiteSpace($holdName)) { $holdName = 'PORT_STALE_OR_UNKNOWN' }
    $hint = ''
    try { $hint = [string]$pf.CollisionHint } catch { $hint = '' }
    $detail = ('startup bloqueado: porta ' + $desired + ' => ' + [string]$pf.Outcome + ' (ShouldReuse=false HOLD mesmo owned; nunca matar PID).')
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $detail += ' ' + $hint }
    return (& $block $detail $holdName)
  }
  catch {
    try { [void]$diag.Add(('excecao (blocker): ' + $_.Exception.Message)) } catch { }
    $o = [ordered]@{
      Permitted = $false
      Exe = ''
      Env = $null
      Desired = 0
      Outcome = 'BLOCKED'
      Detail = ('startup bloqueado (blocker desconhecido; fail-closed): ' + $_.Exception.Message)
      Diagnostics = @($diag)
      Hold = 'BLOCKER'
    }
    return $o
  }
}

function Test-PreflightConfiguredPort {
  param(
    [string]$ProfileDir = '',
    [int]$ExplicitPort = 0,
    [string]$ChosenBinary = '',
    [int]$TimeoutMs = 15000,
    $ListenerOverride = $null,
    $ExcludedRangesOverride = $null,
    [bool]$ExcludedQueryAvailableOverride = $true,
    $NativeGetOverride = $null,
    $NativeConfigOverride = $null,
    $SetPortRunnerOverride = $null,
    $ResolveOverride = $null,
    # RR-P22-WRAPPER-FIX2: o pin nao nasce nesta lib. Ausente => o resolver
    # central recusa (fail-closed, mensagem explicita), nunca adivinha.
    [string]$ExpectedVersion = ''
  )
  # Alias de nome alternativo para Ensure-PreflightConfiguredPort (tolerancia
  # de chamada do wrapper/testes). Central unica; sem logica duplicada.
  # O pin E ACEITO e ENCAMINHADO (alias inutilizavel sem isso desde o
  # endurecimento do resolver); ausencia continua fail-closed.
  $exR = $null
  if ($null -ne $ExcludedRangesOverride) { $exR = $ExcludedRangesOverride }
  return (Ensure-PreflightConfiguredPort -ProfileDir $ProfileDir -ExplicitPort $ExplicitPort -ChosenBinary $ChosenBinary -TimeoutMs $TimeoutMs -ListenerOverride $ListenerOverride -ExcludedRangesOverride $exR -ExcludedQueryAvailableOverride $ExcludedQueryAvailableOverride -NativeGetOverride $NativeGetOverride -NativeConfigOverride $NativeConfigOverride -SetPortRunnerOverride $SetPortRunnerOverride -ResolveOverride $ResolveOverride -ExpectedVersion $ExpectedVersion)
}
