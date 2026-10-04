<#!
.SYNOPSIS
    Regressao da lib de Job Objects fail-closed (RR-P22-JOB-OBJECTS, V3.1).
.DESCRIPTION
    Fecha o BLOCKER documentado da P22 (cleanup de descendants sem Job
    Objects) provando os DOIS cenarios que o walk por ParentProcessId perde,
    alem das garantias de fail-closed:

      T1 escape pos-snapshot: filho no job cria neto DEPOIS da coleta =>
          Stop-RuntimeJobObject encerra os dois (membership pega spawn tardio).
      T2 orfao: filho no job morre deixando neto vivo => o neto AINDA consta no
          member list e e encerrado (reparenting nao escapa).
      T3 nao-descendente: processo efemero PROPRIO FORA do job nunca aparece no
          member list e nunca e terminado.
      T4 breakaway negado: as limit flags do job NAO contem BREAKAWAY_OK /
          SILENT_BREAKAWAY_OK (query real) e contem KILL_ON_JOB_CLOSE.
      T5 fail-closed: handle invalido na seam => resultado estruturado
          ok=false, NENHUMA excecao, sem efeito parcial, e o job real segue
          integro.
      T6 kill-on-close: handle fechado sem Stop explicito => filhos
          encerrados pelo SO (backstop final).
      T7 integracao: Invoke-SpikeChild com -JobObject atribui e reporta
          JobAssigned; SEM -JobObject o resultado e identico ao atual (A/B:
          mesmas chaves, JobAssigned=false).
      T8 (F7) fechamento: Close-RuntimeJobObject com membros encerra todos
          (kill-on-close), marca o job como fechado, e o repeat e no-op.
      T9 (H-D) root morto + descendente vivo => Wait-MarkerGone NAO retorna
          true (a prova de ausencia exige consulta conclusiva com zero matches).
      T10 (H-B) consulta CIM lenta => QuerySucceeded=false dentro do bound,
          filho PROPRIO morto pelo handle retido, sem residuo.
      T11 (K2) atribuicao INJETADA falha => nenhum spawn de descendente fora do
          job (sinal nunca escrito), filho sai com codigo 3, residuo zero.

    FIX1 (reviewer + security-reviewer):
      F1 contrato publico SEM atribuicao por PID: Add-RuntimeJobProcess exige
         o System.Diagnostics.Process do spawn proprio; nulo/tipo errado/host
         /handle indisponivel => recusa estruturada (T5b).
      F2 cleanup NUNCA por taskkill/PID historico: membros vao por
         Close/Stop do job (handle, kill-on-close); o neto FORA do job e
         encerrado pelo PROPRIO filho (que detem o handle) via signal-file, e o
         harness so VERIFICA ausencia por marker unico (T1/T2/T3/T5e/T6/T8/T9/T11).
      F3 deadline absoluto: retorna no bound mesmo com PollMs enorme (T5c).
      F4 consulta que falha no settlement => Ok=false com Api/Reason
         propagados, Terminated preservado (T5d).
      F5 cap PARAMETRO: cap=1/2 com 3+ membros => lista PARCIAL + Truncated=true
         e Assigned preservado (T5e).
      F8 orfao espera signal-file: o neto nasce DEPOIS da atribuicao provada
         (T2).
      F9 mascara correta: SILENT_BREAKAWAY_OK = 0x00001000 (T4).
      FIX2/G1 overflow le os contadores do SEGUNDO buffer: cap=1 com 3+ membros
         devolve EXATAMENTE 1 PID real e cap=2 devolve EXATAMENTE 2 (zero nao e
         aceitavel); todos pertencem ao snapshot completo (T5e).
      FIX2/G2 T5c tem membro REAL presente durante as esperas (o Terminate e
         injetado como no-op, mas a aritmetica de deadline e a de producao);
         T5d falha SO a consulta pos-Terminate (Terminated=true preservado).
      FIX2/G3 Wait-MarkerGone distingue consulta INCONCLUSIVA de ausencia e
         prefere o fato direto do handle retido (HasExited).
      FIX2/G4 atribuicao falha => sinal de spawn NAO e liberado e o finally
         encerra o root pelo handle retido; ausencia e PROVADA, nao assumida.
      FIX3/H-A: no overflow o cap limita SO a quantidade de slots extraidos;
      Assigned preserva o CONTADOR REAL do SO (cap=1 com 5 membros => 1 PID +
      Assigned=5 + Truncated=true).
    FIX3/H-C: o corpo de T1/T2 ABORTA de verdade quando a atribuicao falha
      (o WriteAllText do sinal esta dentro do ramo `if ($assigned)`), e o filho
      sai sem spawnar neto se o sinal nao chegar no prazo.
    FIX3/H-D: Wait-MarkerGone so conclui por consulta CONCLUSIVA com zero
      matches; HasExited do root nao encerra a espera.
    FIX3/H-E: a injecao de falha de consulta usa um dicionario LOCAL de handle
      zero, sem mutar o job real (que antes VAZAVA o handle nativo).

    FIX4/K1 (smoke): Finalize-Job memoizada, uma unica execucao por run.
    FIX4/K2: o sinal de spawn de T1/T2/T9 so e escrito com atribuicao ok; T11
      injeta a FALHA de atribuicao e prova que nenhum descendente nasce fora
      do job (o ramo de abort so e exercitado com falha real).
    FIX4/K3: a checagem residual de T10 usa a PROPRIA seam bounded e conclusiva
      (Get-OwnProcByMarker); consulta inconclusiva => a prova FALHA, nunca
      aprova ausencia.
    FIX4/K4: o TEMP do probe CIM e limpo no finally EXTERNO da suite.

    Filhos efemeros PROPRIOS com marker unico por caso. O harness so encerra
    processo pelo HANDLE que ele proprio reteve (Process do proprio spawn) ou
    pelo job que ele proprio criou; PID e so lido/verificado, nunca alvo de
    kill. 49374 nunca e lido nem tocado. Harness [PASS]/[FAIL] + exit 0/1,
    PS 5.1 e PS7, ASCII puro. Descoberta automatica pelo run-v3-tests
    (scripts/runtime/*.tests.ps1). Escreve so em TEMP; nunca toca o repo.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\SpikeProcess.ps1')
. (Join-Path $PSScriptRoot 'lib\RuntimeJobObject.ps1')

$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('runtime-job-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total += 1
  if ($condition) { $script:passed += 1; Write-Host ('[PASS] ' + $name) }
  else { Write-Host ('[FAIL] ' + $name + ' -- ' + $detail) }
}

# Le a proxima linha nao-vazia de um arquivo de hand-off (o filho escreve o
# PID real que criou; nunca inventamos PID).
function Read-HandOff([string]$Path, [int]$TimeoutMs = 20000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $txt = ''
      try { $txt = [IO.File]::ReadAllText($Path) } catch { $txt = '' }
      $txt = $txt.Trim()
      if ($txt -match '^\d+$') { return [int]$txt }
    }
    Start-Sleep -Milliseconds 100
  }
  return 0
}

function Test-PidAlive([int]$ProcId) {
  # Parametro NAO se chama $Pid: $PID e variavel automatica somente-leitura.
  if ($ProcId -le 0) { return $false }
  try {
    $p = Get-Process -Id $ProcId -ErrorAction Stop
    return ($null -ne $p)
  }
  catch { return $false }
}

function Wait-PidGone([int]$ProcId, [int]$TimeoutMs = 15000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (-not (Test-PidAlive $ProcId)) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return (-not (Test-PidAlive $ProcId))
}

$script:cimProbeScript = $null

function Get-OwnProcByMarker([string]$Marker, [int]$TimeoutMs = 4000, [int]$ProbeDelayMs = 0) {
  # FIX2/G3 + FIX3/H-B: distingue CONSULTA INCONCLUSIVA de "nada encontrado".
  # Uma CIM indisponivel/erro NAO vira lista vazia (seria prova falsa de
  # ausencia).
  # FIX3/H-B: a consulta roda como FILHO PROPRIO (powershell -NoProfile
  # -Command) com handle retido e WaitForExit(restante). Get-CimInstance e
  # BLOQUEANTE e pode estourar qualquer deadline no processo do harness; como
  # filho, o harness sempre tem um handle para .Kill() no deadline (padrao da
  # propria fatia: matar somente por handle retido, nunca por PID nu).
  # -ProbeDelayMs injeta latencia deliberada no filho (usado para provar que o
  # bound e respeitado).
  # Retorna @{ QuerySucceeded; Found; ElapsedMs; TimedOut }.
  $res = @{ QuerySucceeded = $false; Found = @(); ElapsedMs = 0; TimedOut = $false }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $child = $null
  try {
    if ($TimeoutMs -lt 50) { $TimeoutMs = 50 }
    if ($null -eq $script:cimProbeScript) {
      # O probe e um script em disco: -Command nao e usado para logica (o
      # quoting de aspas duplas atravessaria dois niveis de shell).
      $probeDir = Join-Path ([IO.Path]::GetTempPath()) ('cim-probe-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
      $script:cimProbeScript = Join-Path $probeDir 'cim-probe.ps1'
      # O probe EXCLUI o proprio PID ($PID dentro do probe): o marker viaja na
      # CommandLine do filho, entao sem a exclusao o probe casaria o proprio
      # marcador para sempre e Wait-MarkerGone nunca provaria ausencia.
      $lines = @(
        'param([string]$Marker, [int]$DelayMs)',
        '$ErrorActionPreference = ''Stop''',
        'if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }',
        '$rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)',
        'foreach ($r in $rows) {',
        '  if ([int]$r.ProcessId -eq $PID) { continue }',
        '  $c = [string]$r.CommandLine',
        '  if ($c.Contains($Marker)) { Write-Output (''HIT|'' + [string]$r.ProcessId) }',
        '}',
        'Write-Output ''ENDOFQUERY'''
      )
      [IO.File]::WriteAllText($script:cimProbeScript, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    }
    $psExeCim = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExeCim -PathType Leaf)) { $psExeCim = 'powershell' }
    $psiCim = New-Object System.Diagnostics.ProcessStartInfo
    $psiCim.FileName = $psExeCim
    $psiCim.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:cimProbeScript + '" -Marker "' + $Marker.Replace('"', '') + '" -DelayMs ' + [int]$ProbeDelayMs
    $psiCim.UseShellExecute = $false
    $psiCim.RedirectStandardOutput = $true
    $psiCim.RedirectStandardError = $true
    $psiCim.CreateNoWindow = $true
    try { $child = [System.Diagnostics.Process]::Start($psiCim) }
    catch {
      return $res
    }
    $finished = $false
    try { $finished = $child.WaitForExit($TimeoutMs) } catch { $finished = $false }
    if (-not $finished) {
      # Bound estourado: o filho PROPRIO e morto pelo handle retido.
      $res.TimedOut = $true
      try { $child.Kill() } catch { }
      try { [void]$child.WaitForExit(5000) } catch { }
      return $res
    }
    $out = ''
    try { $out = [string]$child.StandardOutput.ReadToEnd() } catch { $out = '' }
    # Conclusiva SO com a marca de fim: sem ela, a leitura foi truncada.
    if ($out -notmatch 'ENDOFQUERY') { return $res }
    $found = New-Object System.Collections.ArrayList
    foreach ($ln in @($out -split "`r?`n")) {
      if ($ln -match '^HIT\|(\d+)$') { [void]$found.Add([int]$Matches[1]) }
    }
    $res.QuerySucceeded = $true
    $res.Found = @($found)
    return $res
  }
  finally {
    if ($null -ne $child) {
      try { $child.Close(); $child.Dispose() } catch { }
    }
    try { $sw.Stop() } catch { }
    $res.ElapsedMs = [long]$sw.ElapsedMilliseconds
  }
}

function Wait-MarkerGone([string]$Marker, [int]$TimeoutMs = 20000, $RetainedProc = $null) {
  # FIX2/G3 + FIX3/H-D: prova de ausencia do MARKER INTEIRO.
  # FIX3/H-D: HasExited prova apenas a ausencia DAQUELE processo (o root). Em
  # T2 o root morre DE PROPONSO com o neto vivo, entao tratar HasExited como
  # "marker inteiro ausente" seria prova falsa. Por isso HasExited NAO encerra
  # a espera por si: so uma consulta CONCLUSIVA com zero matches prova a
  # ausencia do marker completo. HasExited eearly-out legitimo apenas quando
  # o marcador NAO pode reaparecer e nao ha descendente possivel, o que o
  # harness nao assume: entao ele nao e usado como prova aqui.
  # Sem handle retido, uma consulta inconclusiva NUNCA comprova ausencia: o
  # loop repete dentro do deadline e devolve false se nunca houve prova.
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $inconclusive = 0
  $queries = 0
  while ([DateTime]::UtcNow -lt $deadline) {
    $remainingMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMs -le 0) { break }
    $queryMs = $remainingMs
    if ($queryMs -gt 4000) { $queryMs = 4000 }
    $queries += 1
    $q = Get-OwnProcByMarker -Marker $Marker -TimeoutMs $queryMs
    if ([bool]$q.QuerySucceeded) {
      # Unica prova valida de ausencia: consulta CONCLUSIVA + zero matches.
      if (@($q.Found).Count -eq 0) { return $true }
    }
    else {
      # Inconclusiva (inclui timeout do filho CIM): NAO prova ausencia. O loop
      # repete; no maximo o deadline inteiro vai para a ultima consulta final.
      $inconclusive++
    }
    $sleepMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($sleepMs -gt 150) { $sleepMs = 150 }
    if ($sleepMs -le 0) { break }
    Start-Sleep -Milliseconds $sleepMs
  }
  # Ultimo recurso bounded: uma consulta conclusiva final com o tempo restante
  # (pode ser 0; nesse caso nao ha prova => false).
  $leftMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
  if ($leftMs -gt 300) {
    $q = Get-OwnProcByMarker -Marker $Marker -TimeoutMs $leftMs
    $queries += 1
    if ([bool]$q.QuerySucceeded) {
      if (@($q.Found).Count -eq 0) { return $true }
    }
    else { $inconclusive++ }
  }
  return $false
}

# Corpo do filho: cria UM neto e reporta o PID REAL do neto (o PID vem do
# proprio Start do filho: nenhum PID e inventado pelo teste). Sem dependencia
# de lib do repo (o filho vive em TEMP): so ProcessStartInfo.
# FIX1/F8: 'orphan' ESPERA o signal-file antes de criar o neto, igual a
# 'parent': o neto so nasce DEPOIS da atribuicao provada do filho ao job
# (sem isso haveria corrida com o assign do harness).
# FIX1/F2: 'parent' tambem honra um signal de PARADA (StopSignalFile): quando o
# arquivo aparece, o proprio filho - que DETEM o handle do neto - mata o neto
# via .NET Kill() e sai. Esse e o unico caminho de cleanup do neto FORA do job
# (janela pre-assign): o harness so VERIFICA a ausencia, nunca mata por PID.
$childScript = Join-Path $base 'child.ps1'
$childTpl = @(
  'param([string]$Role, [string]$NetPidFile, [string]$SignalFile, [string]$StopSignalFile, [string]$MyMarker)',
  '$ErrorActionPreference = ''Stop''',
  'if ($Role -eq ''neto'') { Start-Sleep -Seconds 120; exit 0 }',
  '# FIX1/F8: AMBOS os papeis (parent E orphan) esperam o signal-file: o neto',
  '# so nasce DEPOIS da atribuicao provada do filho ao job. Sem isso o neto',
  '# correria com o assign do harness e o teste nao provaria o cenario.',
  '$wait = [DateTime]::UtcNow.AddSeconds(30)',
  'while ((-not (Test-Path -LiteralPath $SignalFile)) -and ([DateTime]::UtcNow -lt $wait)) { Start-Sleep -Milliseconds 100 }',
  '# FIX3/H-C: sinal NAO chegou no prazo => sai SEM spawnar neto (antes, o neto',
  '# nascia mesmo sem sinal apos os 30s, tirando o controle do harness).',
  'if (-not (Test-Path -LiteralPath $SignalFile)) { exit 3 }',
  '$psi = New-Object System.Diagnostics.ProcessStartInfo',
  '$psi.FileName = (Join-Path $env:windir ''System32\WindowsPowerShell\v1.0\powershell.exe'')',
  '$psi.Arguments = ''-NoProfile -File "'' + $PSCommandPath + ''" -Role neto -MyMarker '' + $MyMarker',
  '$psi.UseShellExecute = $false',
  '$psi.CreateNoWindow = $true',
  '$np = [System.Diagnostics.Process]::Start($psi)',
  '[IO.File]::WriteAllText($NetPidFile, [string]$np.Id)',
  'if ($Role -eq ''orphan'') { exit 0 }',
  '# parent: aguarda o signal de parada e mata o PROPRIO neto pelo handle que',
  '# DETEM (nenhum PID e killing por terceiro; nenhum PID historico).',
  'if (-not [string]::IsNullOrWhiteSpace($StopSignalFile)) {',
  '  $wait2 = [DateTime]::UtcNow.AddSeconds(60)',
  '  while ((-not (Test-Path -LiteralPath $StopSignalFile)) -and ([DateTime]::UtcNow -lt $wait2)) { Start-Sleep -Milliseconds 150 }',
  '  try { $np.Kill() } catch { }',
  '  try { [void]$np.WaitForExit(10000) } catch { }',
  '  try { $np.Close(); $np.Dispose() } catch { }',
  '}',
  'Start-Sleep -Seconds 120',
  'exit 0'
)
[IO.File]::WriteAllText($childScript, (($childTpl -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))

try {
  # --- T1: escape pos-snapshot (spawn do neto DEPOIS da coleta) ---
  $m1 = 'JOBT1-' + [guid]::NewGuid().ToString('N')
  $f1 = Join-Path $base 't1-net.pid'
  $job1 = New-RuntimeJobObject
  Assert-That ([bool]$job1.Ok) 'T1: job criado' ([string]$job1.Reason)
  $psi1 = New-Object System.Diagnostics.ProcessStartInfo
  $psi1.FileName = $psExe
  $sig1 = Join-Path $base 't1-signal'
  $stop1sig = Join-Path $base 't1-stop'
  $psi1.Arguments = '-NoProfile -File "' + $childScript + '" -Role parent -NetPidFile "' + $f1 + '" -SignalFile "' + $sig1 + '" -StopSignalFile "' + $stop1sig + '" -MyMarker ' + $m1
  $psi1.UseShellExecute = $false
  $psi1.RedirectStandardOutput = $true
  $psi1.RedirectStandardError = $true
  $psi1.CreateNoWindow = $true
  $parent1 = [System.Diagnostics.Process]::Start($psi1)
  $assigned1 = $false
  try {
    $as1 = Add-RuntimeJobProcess -Job $job1 -Process $parent1
    $assigned1 = [bool]$as1.Ok
    Assert-That $assigned1 'T1: filho atribuido ao job' ([string]$as1.Reason)
    # FIX3/H-C: ABORT REAL. O corpo do caso so segue quando a atribuicao
    # passou; caso contrario NAO libera o sinal (o neto nunca nasce) e o
    # `finally` (ainda executado) encerra o root pelo handle retido. Um
    # `Assert-That $false` NAO interrompe o fluxo e escreveria o sinal depois.
    if ($assigned1) {
      Start-Sleep -Milliseconds 800
    # "Coleta" (o snapshot que a arvore por ParentProcessId faria): o neto AINDA
    # nao existe neste instante (o filho so cria o neto DEPOIS do sinal).
    $snap1 = Get-RuntimeJobMemberPids -Job $job1
    $netPid1 = 0
    # FIX2/G4: consulta falha NAO e prova de nada => exige snap1.Ok=true. O job
    # pode conter o conhost.exe gerado pelo proprio filho (herdado pela arvore
    # de criacao), entao o invariante e "neto ainda nao existe" (hand-off
    # ausente), nao uma contagem fixa de membros.
    Assert-That ([bool]$snap1.Ok) 'G4: consulta de membros CONCLUSIVA antes do spawn (falha de query nao e prova)' ('ok=' + [string]$snap1.Ok + ' reason=' + [string]$snap1.Reason)
    Assert-That ((-not (Test-Path -LiteralPath $f1))) 'T1: coleta antes do neto (snapshot pos-snapshot)' ('membros=' + [string]$snap1.Count + ' hand_off_presente=' + [string](Test-Path -LiteralPath $f1))
    # Libera o spawn TARDIO: o neto nasce DEPOIS da coleta acima.
    [IO.File]::WriteAllText($sig1, 'go')
    $netPid1 = Read-HandOff -Path $f1 -TimeoutMs 25000
    Assert-That ($netPid1 -gt 0) 'T1: neto existiu (PID real reportado pelo filho)' ('net_pid=' + $netPid1)
    Assert-That (Test-PidAlive $netPid1) 'T1: neto vivo antes do stop' ('net_pid=' + $netPid1)
    # Prova do gap: o neto NAO estava no member list do snapshot.
    $atSnap = $false
    foreach ($q in @($snap1.Pids)) { if ([int]$q -eq $netPid1) { $atSnap = $true } }
    Assert-That ((-not $atSnap)) 'T1: neto AUSENTE no snapshot (gap do walk por PPID)' ('net_pid=' + $netPid1 + ' snap_pids=' + (@($snap1.Pids) -join ','))
    # Agora membership DEVE incluir o neto (criado depois do assign).
    $deadline1 = [DateTime]::UtcNow.AddSeconds(15)
    $mAfter1 = $null
    while ([DateTime]::UtcNow -lt $deadline1) {
      $mAfter1 = Get-RuntimeJobMemberPids -Job $job1
      $has = $false
      foreach ($q in @($mAfter1.Pids)) { if ([int]$q -eq $netPid1) { $has = $true } }
      if ($has) { break }
      Start-Sleep -Milliseconds 150
    }
    $hasNet1 = $false
    foreach ($q in @($mAfter1.Pids)) { if ([int]$q -eq $netPid1) { $hasNet1 = $true } }
    Assert-That $hasNet1 'T1: membership pega o neto criado DEPOIS do snapshot' ('snap=' + (@($snap1.Pids) -join ',') + ' depois=' + (@($mAfter1.Pids) -join ','))
    $stop1 = Stop-RuntimeJobObject -Job $job1 -TimeoutMs 20000
    Assert-That (([bool]$stop1.Ok) -and ([bool]$stop1.Settled)) 'T1: Stop-RuntimeJobObject settled' ([string]$stop1.Reason)
    Assert-That (Wait-PidGone $netPid1 15000) 'T1: neto tardio encerrado pelo job' ('net_pid=' + $netPid1)
    Assert-That (Wait-PidGone ([int]$parent1.Id) 15000) 'T1: filho encerrado pelo job' ('pid=' + $parent1.Id)
    }
  }
  finally {
    # FIX1/F2: cleanup SOMENTE por handle que o harness detem (o job, via
    # kill-on-close) ou por instrucao ao proprio filho (que detem o handle do
    # neto). NUNCA taskkill por PID historico.
    # FIX2/G4: se a atribuicao falhou, o finally precisa ENCERRAR o root pelo
    # handle retido (Kill no .NET Process) - senao ele dormiria 120s alem da
    # suite. E a ausencia do residuo e PROVADA, nunca assumida.
    [void](Close-RuntimeJobObject -Job $job1)
    try { [IO.File]::WriteAllText($stop1sig, 'stop') } catch { }
    if (-not $assigned1) {
      try { if ($parent1.HasExited) { } else { $parent1.Kill(); [void]$parent1.WaitForExit(15000) } } catch { }
    }
    $t1clean = Wait-MarkerGone -Marker $m1 -TimeoutMs 25000 -RetainedProc $parent1
    Assert-That $t1clean 'T1: sem residuo PROVADO do marcador apos cleanup por handle' ('marker=' + $m1 + ' atribuicao=' + [string]$assigned1)
    try { if (-not $parent1.HasExited) { $parent1.Kill() } } catch { }
    try { $parent1.Close(); $parent1.Dispose() } catch { }
  }

  # --- T2: orfao (filho morre, neto reparentado continua no job) ---
  $m2 = 'JOBT2-' + [guid]::NewGuid().ToString('N')
  $f2 = Join-Path $base 't2-net.pid'
  $job2 = New-RuntimeJobObject
  Assert-That ([bool]$job2.Ok) 'T2: job criado' ([string]$job2.Reason)
  $psi2 = New-Object System.Diagnostics.ProcessStartInfo
  $psi2.FileName = $psExe
  $sig2 = Join-Path $base 't2-signal'
  $psi2.Arguments = '-NoProfile -File "' + $childScript + '" -Role orphan -NetPidFile "' + $f2 + '" -SignalFile "' + $sig2 + '" -StopSignalFile "" -MyMarker ' + $m2
  $psi2.UseShellExecute = $false
  $psi2.RedirectStandardOutput = $true
  $psi2.RedirectStandardError = $true
  $psi2.CreateNoWindow = $true
  $parent2 = [System.Diagnostics.Process]::Start($psi2)
  $parentPid2 = [int]$parent2.Id
  $assigned2 = $false
  try {
    $as2 = Add-RuntimeJobProcess -Job $job2 -Process $parent2
    $assigned2 = [bool]$as2.Ok
    Assert-That $assigned2 'T2: filho atribuido ao job ANTES do spawn do neto (F8)' ([string]$as2.Reason)
    # FIX3/H-C: ABORT REAL (o corpo so segue com atribuicao ok).
    if ($assigned2) {
    # FIX1/F8: libera o spawn do neto SO DEPOIS da atribuicao provada; sem o
    # sinal, o neto nao existe e nao haveria corrida com o assign.
    $pre2 = Get-RuntimeJobMemberPids -Job $job2
    # FIX2/G4: consulta inconclusiva nao e prova => exige Ok=true.
    Assert-That ([bool]$pre2.Ok) 'G4: pre-consulta CONCLUSIVA (falha de query nao e prova)' ('ok=' + [string]$pre2.Ok + ' reason=' + [string]$pre2.Reason)
    # O job pode conter tambem o conhost.exe que o proprio filho gerou (herdado
    # pela arvore de criacao), entao o invariante NAO e "1 membro": e "o pai esta
    # no job E o neto ainda nao existe" (hand-off ausente).
    $preHasParent = $false
    foreach ($dq in @($pre2.Pids)) { if ([int]$dq -eq $parentPid2) { $preHasParent = $true } }
    Assert-That ($preHasParent -and (-not (Test-Path -LiteralPath $f2))) 'T2: pre-snapshot tem o pai e NENHUM neto (neto ainda nao criado)' ('membros=' + [string]$pre2.Count + ' pids=' + (@($pre2.Pids) -join ',') + ' parent=' + $parentPid2 + ' hand_off_presente=' + [string](Test-Path -LiteralPath $f2))
    [IO.File]::WriteAllText($sig2, 'go')
    $netPid2 = Read-HandOff -Path $f2 -TimeoutMs 25000
    Assert-That ($netPid2 -gt 0) 'T2: neto existiu (PID real reportado)' ('net_pid=' + $netPid2)
    # Pai morre (role=orphan); neto fica orfao (reparentado pelo SO).
    $parentGone2 = Wait-PidGone $parentPid2 20000
    Assert-That $parentGone2 'T2: pai morto (orfao de verdade)' ('pid=' + $parentPid2)
    Start-Sleep -Milliseconds 800
    Assert-That (Test-PidAlive $netPid2) 'T2: neto vivo apos a morte do pai (reparentado)' ('net_pid=' + $netPid2)
    # Membership por arvore de criacao: o neto segue no job apesar do reparent.
    $deadline2 = [DateTime]::UtcNow.AddSeconds(15)
    $hasNet2 = $false
    $mem2 = $null
    while ([DateTime]::UtcNow -lt $deadline2) {
      $mem2 = Get-RuntimeJobMemberPids -Job $job2
      $hasNet2 = $false
      foreach ($q in @($mem2.Pids)) { if ([int]$q -eq $netPid2) { $hasNet2 = $true } }
      if ($hasNet2) { break }
      Start-Sleep -Milliseconds 150
    }
    Assert-That $hasNet2 'T2: neto orfao AINDA no member list (reparenting nao escapa)' ('mem_pids=' + (@($mem2.Pids) -join ',') + ' net_pid=' + $netPid2)
    $stop2 = Stop-RuntimeJobObject -Job $job2 -TimeoutMs 20000
    Assert-That (([bool]$stop2.Ok) -and ([bool]$stop2.Settled)) 'T2: Stop-RuntimeJobObject settled' ([string]$stop2.Reason)
    Assert-That (Wait-PidGone $netPid2 15000) 'T2: orfao encerrado pelo job' ('net_pid=' + $netPid2)
    }
  }
  finally {
    # FIX1/F2: cleanup por handle (kill-on-close do job); sem taskkill por PID.
    # FIX2/G4: atribuicao falhou => encerrar o root pelo handle retido.
    [void](Close-RuntimeJobObject -Job $job2)
    if (-not $assigned2) {
      try { if ($parent2.HasExited) { } else { $parent2.Kill(); [void]$parent2.WaitForExit(15000) } } catch { }
    }
    $t2clean = Wait-MarkerGone -Marker $m2 -TimeoutMs 25000 -RetainedProc $parent2
    Assert-That $t2clean 'T2: sem residuo PROVADO do marcador apos cleanup por handle' ('marker=' + $m2 + ' atribuicao=' + [string]$assigned2)
    try { if (-not $parent2.HasExited) { $parent2.Kill() } } catch { }
    try { $parent2.Close(); $parent2.Dispose() } catch { }
  }

  # --- T3: nao-descendente fora do job nunca aparece nem e terminado ---
  $m3 = 'JOBT3-' + [guid]::NewGuid().ToString('N')
  $job3 = New-RuntimeJobObject
  $psi3 = New-Object System.Diagnostics.ProcessStartInfo
  $psi3.FileName = $psExe
  $psi3.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # ' + $m3 + '"'
  $psi3.UseShellExecute = $false
  $psi3.CreateNoWindow = $true
  $out3 = [System.Diagnostics.Process]::Start($psi3)
  $outPid3 = [int]$out3.Id
  try {
    # Job com um membro proprio (o pai), para que o stop tenha o que fazer.
    $own3 = $null
    $psi3b = New-Object System.Diagnostics.ProcessStartInfo
    $psi3b.FileName = $psExe
    $psi3b.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # ' + $m3 + 'IN"'
    $psi3b.UseShellExecute = $false
    $psi3b.CreateNoWindow = $true
    $own3 = [System.Diagnostics.Process]::Start($psi3b)
    $as3 = Add-RuntimeJobProcess -Job $job3 -Process $own3
    Assert-That ([bool]$as3.Ok) 'T3: membro proprio atribuido ao job' ([string]$as3.Reason)
    Start-Sleep -Milliseconds 500
    $mem3 = Get-RuntimeJobMemberPids -Job $job3
    $leak3 = $false
    foreach ($q in @($mem3.Pids)) { if ([int]$q -eq $outPid3) { $leak3 = $true } }
    Assert-That ((-not $leak3) -and (Test-PidAlive $outPid3)) 'T3: processo fora do job NUNCA aparece no member list' ('mem=' + (@($mem3.Pids) -join ',') + ' out_pid=' + $outPid3)
    $stop3 = Stop-RuntimeJobObject -Job $job3 -TimeoutMs 20000
    Assert-That (([bool]$stop3.Ok) -and ([bool]$stop3.Settled)) 'T3: job encerrado e settled' ([string]$stop3.Reason)
    Assert-That (Test-PidAlive $outPid3) 'T3: processo fora do job SOBREVIVEU ao stop do job' ('out_pid=' + $outPid3 + ' vivo=' + (Test-PidAlive $outPid3))
    Assert-That (Wait-PidGone ([int]$own3.Id) 15000) 'T3: membro do job foi encerrado' ('pid=' + $own3.Id)
    try { $own3.Close(); $own3.Dispose() } catch { }
  }
  finally {
    # FIX1/F2: o processo FORA do job so pode ser encerrado pelo handle que o
    # harness reteve do SEU proprio spawn (.NET Kill no handle vivo; falha se
    # ja saiu). Jamais por PID nu.
    try { if ($out3.HasExited) { } else { $out3.Kill(); [void]$out3.WaitForExit(10000) } } catch { }
    try { $out3.Close(); $out3.Dispose() } catch { }
    [void](Close-RuntimeJobObject -Job $job3)
  }

  # --- T4: breakaway negado (query real das limit flags) ---
  $job4 = New-RuntimeJobObject
  try {
    $fl4 = Get-RuntimeJobLimitFlags -Job $job4
    Assert-That ([bool]$fl4.Ok) 'T4: QueryInformationJobObject de flags ok' ([string]$fl4.Reason)
    Assert-That ([bool]$fl4.KillOnClose) 'T4: KILL_ON_JOB_CLOSE presente' ('flags=0x' + ([uint32]$fl4.LimitFlags).ToString('x'))
    Assert-That ((-not [bool]$fl4.BreakawayOk) -and (-not [bool]$fl4.SilentBreakawayOk)) 'T4: BREAKAWAY_OK / SILENT_BREAKAWAY_OK NAO setados' ('breakaway=' + [string]$fl4.BreakawayOk + ' silent=' + [string]$fl4.SilentBreakawayOk)
    # FIX1/F9 + FIX2/G6: mascara de SILENT_BREAKAWAY_OK e 0x00001000. A mascara
    # 0x00004000 e JOB_OBJECT_LIMIT_SUBSET_AFFINITY (nao KILL_ON_JOB_CLOSE, que
    # e 0x00002000); ambas ficam ausentes por construcao, mas a que este teste
    # exercita como breakaway e a 0x1000.
    Assert-That (([uint32]$fl4.LimitFlags -band [uint32]0x00000800) -eq 0) 'T4: mascara BREAKAWAY_OK 0x800 ausente nas flags' ('flags=0x' + ([uint32]$fl4.LimitFlags).ToString('x'))
    Assert-That (([uint32]$fl4.LimitFlags -band [uint32]0x00001000) -eq 0) 'T4: mascara SILENT_BREAKAWAY_OK 0x1000 ausente nas flags' ('flags=0x' + ([uint32]$fl4.LimitFlags).ToString('x'))
    Assert-That (([uint32]$fl4.LimitFlags -band [uint32]0x00002000) -eq [uint32]0x00002000) 'T4/G6: KILL_ON_JOB_CLOSE = 0x2000 presente (a mascara testada e 0x1000)' ('flags=0x' + ([uint32]$fl4.LimitFlags).ToString('x'))
    Assert-That (([uint32]$fl4.LimitFlags -band [uint32]0x00004000) -eq 0) 'T4/G6: SUBSET_AFFINITY 0x4000 ausente (flag nao relacionada, nao confundida com kill-on-close)' ('flags=0x' + ([uint32]$fl4.LimitFlags).ToString('x'))
  }
  finally { [void](Close-RuntimeJobObject -Job $job4) }

  # --- T5: fail-closed na seam (handle invalido => estruturado, sem excecao) ---
  $job5 = New-RuntimeJobObject
  try {
    $bad = @{ Ok = $true; Handle = [IntPtr]::Zero; Closed = $false }
    $noThrow = $true
    $rAdd = $null; $rStop = $null; $rMem = $null; $rFlags = $null; $rClose = $null
    try {
      $rAdd = Add-RuntimeJobProcess -Job $bad -Process ([System.Diagnostics.Process]::GetCurrentProcess())
      $rStop = Stop-RuntimeJobObject -Job $bad -TimeoutMs 2000
      $rMem = Get-RuntimeJobMemberPids -Job $bad
      $rFlags = Get-RuntimeJobLimitFlags -Job $bad
      $rClose = Close-RuntimeJobObject -Job $bad
    }
    catch { $noThrow = $false }
    Assert-That $noThrow 'T5: handle invalido nao lanca excecao atraves da seam' ('falhou com excecao')
    Assert-That ((-not [bool]$rAdd.Ok) -and (-not [string]::IsNullOrWhiteSpace([string]$rAdd.Reason))) 'T5: Add com handle invalido => ok=false estruturado' ('ok=' + [string]$rAdd.Ok + ' reason=' + [string]$rAdd.Reason)
    Assert-That ((-not [bool]$rStop.Ok) -and (-not [bool]$rStop.Terminated)) 'T5: Stop com handle invalido => ok=false, nada terminado' ('ok=' + [string]$rStop.Ok + ' term=' + [string]$rStop.Terminated + ' reason=' + [string]$rStop.Reason)
    Assert-That ((-not [bool]$rMem.Ok) -and (@($rMem.Pids).Count -eq 0)) 'T5: GetMember com handle invalido => ok=false, lista vazia' ('ok=' + [string]$rMem.Ok)
    Assert-That ((-not [bool]$rFlags.Ok)) 'T5: GetLimitFlags com handle invalido => ok=false' ('ok=' + [string]$rFlags.Ok)
    Assert-That ((-not [bool]$rClose.Ok)) 'T5: Close com handle invalido => ok=false' ('ok=' + [string]$rClose.Ok)
    # Sem efeito parcial: o job real criado no inicio segue integro.
    $stillOk = $false
    try {
      $fl5 = Get-RuntimeJobLimitFlags -Job $job5
      $mem5 = Get-RuntimeJobMemberPids -Job $job5
      $stillOk = ([bool]$fl5.Ok -and [bool]$mem5.Ok)
    }
    catch { $stillOk = $false }
    Assert-That $stillOk 'T5: job real intacto apos as falhas injetadas (sem efeito parcial)' ('still_ok=' + $stillOk)
  }
  finally { [void](Close-RuntimeJobObject -Job $job5) }

  # --- T5b (F1): contrato publico sem atribricao por PID ---
  # Nao existe caminho publico por PID: -Process ausente, tipo errado, host
  # proprio e handle indisponivel => recusa estruturada {Ok=false}.
  $job5b = New-RuntimeJobObject
  try {
    $nullProc = $null
    $rNoProc = Add-RuntimeJobProcess -Job $job5b -Process $nullProc
    Assert-That ((-not [bool]$rNoProc.Ok) -and ([string]$rNoProc.Reason -match 'nunca atribui')) 'F1: -Process nulo => recusa estruturada (PID nu nunca atribui)' ('ok=' + [string]$rNoProc.Ok + ' reason=' + [string]$rNoProc.Reason)
    $rWrongType = Add-RuntimeJobProcess -Job $job5b -Process 4321
    Assert-That ((-not [bool]$rWrongType.Ok) -and ([string]$rWrongType.Reason -match 'System.Diagnostics.Process')) 'F1: -Process nao-Process => recusa estruturada' ('ok=' + [string]$rWrongType.Ok + ' reason=' + [string]$rWrongType.Reason)
    $selfProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $rSelf = Add-RuntimeJobProcess -Job $job5b -Process $selfProc
    Assert-That ((-not [bool]$rSelf.Ok) -and ([string]$rSelf.Reason -match 'host')) 'F1: processo atual (host) => recusa estruturada' ('ok=' + [string]$rSelf.Ok + ' reason=' + [string]$rSelf.Reason)
    # Contrato: nenhum parametro publico aceita PID (F1). Um -ProcessId nao
    # pode nem serVinculado: prova de que o caminho por PID saiu do contrato.
    $hasPidParam = $false
    $p = (Get-Command Add-RuntimeJobProcess).Parameters.Keys
    foreach ($k in @($p)) { if ([string]$k -match 'ProcessId') { $hasPidParam = $true } }
    Assert-That ((-not $hasPidParam)) 'F1: parametro publico -ProcessId REMOVIDO do contrato' ('params=' + (@($p) -join ','))
    # Handle indisponivel => recusa estruturada (fail-closed, sem PID).
    $rFakeProc = @{ Handle = $null; Id = 12345 }
    $rNoHandle = Add-RuntimeJobProcess -Job $job5b -Process $rFakeProc
    Assert-That ((-not [bool]$rNoHandle.Ok)) 'F1: handle indisponivel => recusa (fail-closed)' ('ok=' + [string]$rNoHandle.Ok + ' reason=' + [string]$rNoHandle.Reason)
    try { $selfProc.Close(); $selfProc.Dispose() } catch { }
  }
  finally { [void](Close-RuntimeJobObject -Job $job5b) }

  # --- T5c (F3/G2): deadline ABSOLUTO com membro REAL presente nas esperas ---
  # Sem o fix (Start-Sleep -Milliseconds $PollMs), PollMs=60000 dormiria ~60s e
  # o assert de bound falharia. Aqui o membro esta VIVO durante TODAS as
  # esperas (o Terminate e injetado como no-op, mas a aritmetica de deadline e
  # a mesma de producao), entao o laco realmente espera e realmente volta.
  $job5c = New-RuntimeJobObject
  $p5c = $null
  try {
    $psi5c = New-Object System.Diagnostics.ProcessStartInfo
    $psi5c.FileName = $psExe
    $psi5c.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # JOBT5C-' + [guid]::NewGuid().ToString('N') + '"'
    $psi5c.UseShellExecute = $false
    $psi5c.CreateNoWindow = $true
    $p5c = [System.Diagnostics.Process]::Start($psi5c)
    $as5c = Add-RuntimeJobProcess -Job $job5c -Process $p5c
    Assert-That ([bool]$as5c.Ok) 'F3: membro real atribuido ao job do teste de deadline' ([string]$as5c.Reason)
    Start-Sleep -Milliseconds 400
    $memBefore = Get-RuntimeJobMemberPids -Job $job5c
    Assert-That ([int]$memBefore.Count -ge 1) 'F3: membro presente ANTES das esperas' ('count=' + [string]$memBefore.Count)
    $sw5c = [DateTime]::UtcNow
    $rBound = Stop-RuntimeJobObject -Job $job5c -TimeoutMs 700 -PollMs 60000 -FaultInjectSkipTerminate
    $elapsedBound = [long]([DateTime]::UtcNow - $sw5c).TotalMilliseconds
    # Com o clamp, o elapsed fica no deadline (~700ms, medido 702-760). Sem o
    # clamp, o PollMs (capado em 2000) domina e o elapsed vai a ~2000ms; sem o
    # cap, vai a ~60s. O limite de 1500ms separa os tres casos e falha se o
    # clamp for removido.
    Assert-That ($elapsedBound -lt 1500) 'F3/G2: TimeoutMs=700 + PollMs=60000 retorna no deadline (nao 2s nem ~60s)' ('elapsed_ms=' + $elapsedBound + ' reason=' + [string]$rBound.Reason)
    Assert-That ($elapsedBound -ge 400) 'F3/G2: esperou de verdade ate o deadline (nao saiu antes)' ('elapsed_ms=' + $elapsedBound)
    Assert-That ([int]$rBound.PollCount -ge 1) 'F3/G2: settlement polled com membro presente' ('polls=' + [string]$rBound.PollCount + ' remaining=' + [string]$rBound.Remaining)
    Assert-That ((-not [bool]$rBound.Settled) -and ([bool]$rBound.Ok)) 'F3/G2: membership persistente => settlement PENDENTE honesto (Ok=true)' ('settled=' + [string]$rBound.Settled + ' ok=' + [string]$rBound.Ok + ' reason=' + [string]$rBound.Reason)
    Assert-That (Test-PidAlive ([int]$p5c.Id)) 'F3/G2: membro REAL sobreviveu (as esperas viram membro presente)' ('pid=' + $p5c.Id)
  }
  finally {
    [void](Close-RuntimeJobObject -Job $job5c)
    if ($null -ne $p5c) { try { if ($p5c.HasExited) { } else { $p5c.Kill(); [void]$p5c.WaitForExit(10000) } } catch { } }
    try { if ($null -ne $p5c) { $p5c.Close(); $p5c.Dispose() } } catch { }
  }

  # --- T5d (F4/G2): consulta falha APOS o Terminate => Ok=false propagado ---
  # O Terminate roda de verdade num job real com membro real; SO a consulta de
  # settlement e injetada como falha. Sem o fix de F4, o $res.Ok=$true no fim
  # sobrescreveria a falha e estes asserts falhariam (Ok=false seria esperado
  # mas viria true). Discrimina tambem contra Terminate=false: Terminated
  # precisa ser true (o terminate rodou) enquanto QueryFailed=true.
  $job5d = New-RuntimeJobObject
  $p5d = $null
  try {
    $psi5d = New-Object System.Diagnostics.ProcessStartInfo
    $psi5d.FileName = $psExe
    $psi5d.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # JOBT5D-' + [guid]::NewGuid().ToString('N') + '"'
    $psi5d.UseShellExecute = $false
    $psi5d.CreateNoWindow = $true
    $p5d = [System.Diagnostics.Process]::Start($psi5d)
    $as5d = Add-RuntimeJobProcess -Job $job5d -Process $p5d
    Assert-That ([bool]$as5d.Ok) 'F4: membro real atribuido ao job do fault de consulta' ([string]$as5d.Reason)
    Start-Sleep -Milliseconds 400
    $rQ = Stop-RuntimeJobObject -Job $job5d -TimeoutMs 3000 -PollMs 50 -FaultInjectQueryAfterTerminate
    Assert-That ([bool]$rQ.Terminated) 'F4/G2: Terminated=true preservado (o terminate rodou de verdade)' ('term=' + [string]$rQ.Terminated + ' reason=' + [string]$rQ.Reason)
    Assert-That ([bool]$rQ.QueryFailed) 'F4/G2: QueryFailed=true sinaliza a falha de settlement' ('qfail=' + [string]$rQ.QueryFailed)
    Assert-That ((-not [bool]$rQ.Ok)) 'F4/G2: Ok=false (sem o fix, o Ok=true final sobrescreveria)' ('ok=' + [string]$rQ.Ok)
    Assert-That ((-not [string]::IsNullOrWhiteSpace([string]$rQ.Api)) -and ([string]$rQ.Api -match 'QueryInformationJobObject')) 'F4/G2: Api da consulta propagada' ('api=' + [string]$rQ.Api)
    Assert-That ((-not [string]::IsNullOrWhiteSpace([string]$rQ.Reason)) -and ([string]$rQ.Reason -match 'NAO comprovado')) 'F4/G2: Reason honesto (settlement nao comprovado)' ('reason=' + [string]$rQ.Reason)
    Assert-That ((-not [bool]$rQ.Settled)) 'F4/G2: Settled=false (nada afirmar sem prova de consulta)' ('settled=' + [string]$rQ.Settled)
    # FIX3/H-E: a injecao NAO pode destruir o handle nativo do job. Se ela
    # mutasse o dicionario real, o handle viraria zero, o CloseHandle do
    # finally fecharia zero e o Job Object VAZARIA (handle nativo orfao).
    # Prova: apos a injecao, Close-RuntimeJobObject no job REAL precisa fechar
    # de verdade (Ok + Closed + handle zerado no estado do job).
    $memAfterInject = Get-RuntimeJobMemberPids -Job $job5d
    Assert-That ([bool]$memAfterInject.Ok) 'H-E: handle REAL do job intacto apos a injecao (query funciona)' ('ok=' + [string]$memAfterInject.Ok + ' reason=' + [string]$memAfterInject.Reason)
    $close5d = Close-RuntimeJobObject -Job $job5d
    Assert-That (([bool]$close5d.Ok) -and ([bool]$close5d.Closed)) 'H-E: job REAL fecha com sucesso apos injecao (sem leak de handle nativo)' ('ok=' + [string]$close5d.Ok + ' closed=' + [string]$close5d.Closed + ' reason=' + [string]$close5d.Reason)
    $memAfterClose5d = Get-RuntimeJobMemberPids -Job $job5d
    Assert-That ((-not [bool]$memAfterClose5d.Ok)) 'H-E: apos fechar, o handle NAO e reaproveitado (consulta recusa)' ('ok=' + [string]$memAfterClose5d.Ok + ' reason=' + [string]$memAfterClose5d.Reason)
  }
  finally {
    if ($null -ne $p5d) {
      try { if ($p5d.HasExited) { } else { $p5d.Kill(); [void]$p5d.WaitForExit(10000) } } catch { }
      try { $p5d.Close(); $p5d.Dispose() } catch { }
    }
  }

  # --- T5e (F5): cap PARAMETRO => lista PARCIAL + Truncated=true ---
  # cap=1 com 2+ membros: a enumeracao devolve o que coube (1) marcada como
  # truncada, e o contador Assigned preserva a contagem real.
  $m5e = 'JOBT5E-' + [guid]::NewGuid().ToString('N')
  $job5e = New-RuntimeJobObject
  $q5e = New-Object System.Collections.ArrayList
  try {
    for ($i = 0; $i -lt 3; $i++) {
      $psiq = New-Object System.Diagnostics.ProcessStartInfo
      $psiq.FileName = $psExe
      $psiq.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # ' + $m5e + $i + '"'
      $psiq.UseShellExecute = $false
      $psiq.CreateNoWindow = $true
      $pq = [System.Diagnostics.Process]::Start($psiq)
      [void]$q5e.Add($pq)
      $asq = Add-RuntimeJobProcess -Job $job5e -Process $pq
      if (-not [bool]$asq.Ok) { Assert-That $false 'F5: membro atribuido' ([string]$asq.Reason) }
    }
    Start-Sleep -Milliseconds 700
    $full5e = Get-RuntimeJobMemberPids -Job $job5e
    Assert-That (([bool]$full5e.Ok) -and ([int]$full5e.Count -ge 3) -and (-not [bool]$full5e.Truncated)) 'F5: cap default traz os 3 membros sem truncamento' ('count=' + [string]$full5e.Count + ' trunc=' + [string]$full5e.Truncated + ' reason=' + [string]$full5e.Reason)
    $cap1 = Get-RuntimeJobMemberPids -Job $job5e -Cap 1
    Assert-That (([bool]$cap1.Ok) -and ([int]$cap1.Cap -eq 1)) 'F5: cap e PARAMETRO (aceita 1)' ('cap=' + [string]$cap1.Cap)
    Assert-That (([bool]$cap1.Truncated) -and ([int]$cap1.Count -eq 1)) 'G1: cap=1 com 3+ membros => EXATAMENTE 1 PID (zero nao e aceitavel)' ('count=' + [string]$cap1.Count + ' trunc=' + [string]$cap1.Truncated + ' reason=' + [string]$cap1.Reason)
    Assert-That (@($cap1.Pids) -contains (@($full5e.Pids)[0])) 'G1: o PID de cap=1 pertence ao snapshot completo (membro real)' ('pids=' + (@($cap1.Pids) -join ',') + ' full=' + (@($full5e.Pids) -join ','))
    # FIX3/H-A: Assigned e o CONTADOR REAL do SO. Com 3+ membros e cap=1,
    # rebaixar Assigned ao cap devolveria 1 (contador corrompido) em vez de 3.
    $fullCount5e = [int]$full5e.Count
    Assert-That ([int]$cap1.Assigned -eq $fullCount5e) 'H-A: cap=1 => Assigned preserva o CONTADOR REAL (nao rebaixado ao cap)' ('assigned=' + [string]$cap1.Assigned + ' esperado=' + [string]$fullCount5e + ' count=' + [string]$cap1.Count)
    $cap2 = Get-RuntimeJobMemberPids -Job $job5e -Cap 2
    Assert-That (([bool]$cap2.Truncated) -and ([int]$cap2.Count -eq 2)) 'G1: cap=2 => EXATAMENTE 2 PIDs (zero nao e aceitavel)' ('count=' + [string]$cap2.Count + ' trunc=' + [string]$cap2.Truncated)
    $cap2Real = 0
    foreach ($q in @($cap2.Pids)) { if (@($full5e.Pids) -contains $q) { $cap2Real++ } }
    Assert-That ($cap2Real -eq 2) 'G1: os 2 PIDs de cap=2 sao membros reais do snapshot' ('pids=' + (@($cap2.Pids) -join ',') + ' full=' + (@($full5e.Pids) -join ','))
    Assert-That ([int]$cap2.Assigned -eq $fullCount5e) 'H-A: cap=2 => Assigned preserva o CONTADOR REAL' ('assigned=' + [string]$cap2.Assigned + ' esperado=' + [string]$fullCount5e + ' count=' + [string]$cap2.Count)
    $cap99 = Get-RuntimeJobMemberPids -Job $job5e -Cap 99
    Assert-That (([bool]$cap99.Ok) -and (-not [bool]$cap99.Truncated) -and ([int]$cap99.Count -ge 3)) 'G1: cap folgado => lista completa sem truncamento' ('count=' + [string]$cap99.Count + ' trunc=' + [string]$cap99.Truncated)
    # Cleanup SEM PID: fecha o job (kill-on-close) e so verifica por marker.
  }
  finally {
    [void](Close-RuntimeJobObject -Job $job5e)
    foreach ($pq2 in @($q5e)) {
      try { if ($pq2.HasExited) { } else { $pq2.Kill(); [void]$pq2.WaitForExit(10000) } } catch { }
      try { $pq2.Close(); $pq2.Dispose() } catch { }
    }
    $f5eClean = $false
    $r5eClean = Wait-MarkerGone -Marker $m5e -TimeoutMs 20000
    $f5eClean = [bool]$r5eClean
    Assert-That $f5eClean 'F5: sem residuo apos cleanup por handle' ('marker=' + $m5e + ' limpo=' + [string]$f5eClean)
  }

  # --- T6: kill-on-close (fecha handle sem Stop => SO encerra filhos) ---
  $m6 = 'JOBT6-' + [guid]::NewGuid().ToString('N')
  $job6 = New-RuntimeJobObject
  $p6 = $null
  try {
    $psi6 = New-Object System.Diagnostics.ProcessStartInfo
    $psi6.FileName = $psExe
    $psi6.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # ' + $m6 + '"'
    $psi6.UseShellExecute = $false
    $psi6.CreateNoWindow = $true
    $p6 = [System.Diagnostics.Process]::Start($psi6)
    $as6 = Add-RuntimeJobProcess -Job $job6 -Process $p6
    Assert-That ([bool]$as6.Ok) 'T6: filho atribuido ao job' ([string]$as6.Reason)
    Start-Sleep -Milliseconds 400
    Assert-That (Test-PidAlive ([int]$p6.Id)) 'T6: filho vivo antes do close' ('pid=' + $p6.Id)
    # Fecha o handle SEM Stop: KILL_ON_JOB_CLOSE e o backstop final.
    $cl6 = Close-RuntimeJobObject -Job $job6
    Assert-That ([bool]$cl6.Ok) 'T6: CloseHandle ok' ([string]$cl6.Reason)
    Assert-That (Wait-PidGone ([int]$p6.Id) 20000) 'T6: kill-on-close encerrou o filho (sem Stop explicito)' ('pid=' + $p6.Id)
  }
  finally {
    if ($null -ne $p6) { try { if ($p6.HasExited) { } else { $p6.Kill(); [void]$p6.WaitForExit(10000) } } catch { } }
    try { $p6.Close(); $p6.Dispose() } catch { }
    [void](Close-RuntimeJobObject -Job $job6)
  }

  # --- T7: integracao Invoke-SpikeChild com/sem -JobObject (A/B) ---
  $job7 = New-RuntimeJobObject
  try {
    # A: com -JobObject
    $a7 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'job-a-ok'") -TimeoutMs 30000 -JobObject $job7
    Assert-That ((-not [bool]$a7.TimedOut) -and ([int]$a7.ExitCode -eq 0) -and ([string]$a7.Stdout -match 'job-a-ok')) 'T7: A: Invoke-SpikeChild com -JobObject executa normal' ('rc=' + $a7.ExitCode + ' out=' + [string]$a7.Stdout)
    Assert-That ([bool]$a7.JobAssigned) 'T7: A: JobAssigned=true reportado' ('nota=' + [string]$a7.JobNote)
    # O filho de A saiu (exit 0) mas a atribuicao ocorreu; provamos pelo note.
    Assert-That ([string]$a7.JobNote -match 'atribuido ao job') 'T7: A: JobNote registra a atribuicao' ('nota=' + [string]$a7.JobNote)
  }
  finally { [void](Close-RuntimeJobObject -Job $job7) }

  # B: SEM -JobObject (comportamento atual preservado) - A/B de shape
  $b7 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'job-b-ok'") -TimeoutMs 30000
  Assert-That ((-not [bool]$b7.TimedOut) -and ([int]$b7.ExitCode -eq 0) -and ([string]$b7.Stdout -match 'job-b-ok')) 'T7: B: Invoke-SpikeChild sem -JobObject executa normal' ('rc=' + $b7.ExitCode + ' out=' + [string]$b7.Stdout)
  Assert-That ((-not [bool]$b7.JobAssigned) -and ([string]::IsNullOrWhiteSpace([string]$b7.JobNote))) 'T7: B: sem -JobObject => JobAssigned=false e JobNote vazio' ('assigned=' + [string]$b7.JobAssigned + ' nota=' + [string]$b7.JobNote)
  # Mesmas chaves nos dois retornos (contrato estavel para chamadores antigos).
  $keysA = @($a7.Keys | Sort-Object)
  $keysB = @($b7.Keys | Sort-Object)
  $keysMatch = (($keysA.Count -eq $keysB.Count) -and (($keysA -join '|') -eq ($keysB -join '|')))
  Assert-That $keysMatch 'T7: A/B mesmas chaves no resultado (shape estavel)' ('A=' + ($keysA -join ',') + ' B=' + ($keysB -join ','))

  # B2: sem a lib carregada e com -JobObject => falha honesta, sem excecao.
  # (a lib esta carregada nesta suite; simulamos a ausencia via job invalido)
  $b2 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'job-b2-ok'") -TimeoutMs 30000 -JobObject @{ Ok = $true; Handle = [IntPtr]::Zero; Closed = $false }
  Assert-That ((-not [bool]$b2.TimedOut) -and ([int]$b2.ExitCode -eq 0) -and ([string]$b2.Stdout -match 'job-b2-ok')) 'T7: B2: -JobObject invalido => filho roda, atribuicao falha (fail-closed, sem excecao)' ('rc=' + $b2.ExitCode + ' assigned=' + [string]$b2.JobAssigned)
  Assert-That ((-not [bool]$b2.JobAssigned) -and ([string]$b2.JobNote -match 'atribuicao falhou')) 'T7: B2: nota honesta de falha de atribuicao' ('nota=' + [string]$b2.JobNote)

  # --- T8 (F7): fechamento do job com membros => kill-on-close observavel ---
  # Equivalente unitario do passo final do smoke: Close-RuntimeJobObject
  # com membros vivos encerra todos, e o job fica marcado como fechado
  # (evidencia de fechamento real, nao um flag assumido).
  $m8 = 'JOBT8-' + [guid]::NewGuid().ToString('N')
  $job8 = New-RuntimeJobObject
  $p8a = $null; $p8b = $null
  try {
    $psi8 = New-Object System.Diagnostics.ProcessStartInfo
    $psi8.FileName = $psExe
    $psi8.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 60 # ' + $m8 + '"'
    $psi8.UseShellExecute = $false
    $psi8.CreateNoWindow = $true
    $p8a = [System.Diagnostics.Process]::Start($psi8)
    $as8a = Add-RuntimeJobProcess -Job $job8 -Process $p8a
    Assert-That ([bool]$as8a.Ok) 'F7: membro A atribuido ao job do fechamento' ([string]$as8a.Reason)
    Start-Sleep -Milliseconds 400
    $before8 = Get-RuntimeJobMemberPids -Job $job8
    Assert-That ([int]$before8.Count -ge 1) 'F7: membros visiveis antes do fechamento' ('count=' + [string]$before8.Count)
    $cl8 = Close-RuntimeJobObject -Job $job8
    Assert-That (([bool]$cl8.Ok) -and ([bool]$cl8.Closed)) 'F7: fechamento ok + marcador de fechado real' ('ok=' + [string]$cl8.Ok + ' closed=' + [string]$cl8.Closed + ' reason=' + [string]$cl8.Reason)
    Assert-That (Wait-PidGone ([int]$p8a.Id) 20000) 'F7: kill-on-close encerrou o membro ao fechar (sem Stop)' ('pid=' + $p8a.Id)
    # Idempotencia: o finally chama Close de novo e precisa ser no-op honesto.
    $cl8b = Close-RuntimeJobObject -Job $job8
    Assert-That (([bool]$cl8b.Ok) -and ([string]$cl8b.Reason -match 'idempotente')) 'F7: fechamento repetido e no-op idempotente' ('reason=' + [string]$cl8b.Reason)
    # Query no job fechado => recusa estruturada (nada e re-terminado).
    $mem8 = Get-RuntimeJobMemberPids -Job $job8
    Assert-That ((-not [bool]$mem8.Ok)) 'F7: query em job fechado => recusa estruturada' ('ok=' + [string]$mem8.Ok + ' reason=' + [string]$mem8.Reason)
  }
  finally {
    [void](Close-RuntimeJobObject -Job $job8)
    if ($null -ne $p8a) { try { if ($p8a.HasExited) { } else { $p8a.Kill(); [void]$p8a.WaitForExit(10000) } } catch { } }
    if ($null -ne $p8b) { try { if ($p8b.HasExited) { } else { $p8b.Kill(); [void]$p8b.WaitForExit(10000) } } catch { } }
    try { if ($null -ne $p8a) { $p8a.Close(); $p8a.Dispose() } } catch { }
    try { if ($null -ne $p8b) { $p8b.Close(); $p8b.Dispose() } } catch { }
    $f7Clean = [bool](Wait-MarkerGone -Marker $m8 -TimeoutMs 20000 -RetainedProc $p8a)
    Assert-That $f7Clean 'F7: sem residuo apos fechamento do job' ('marker=' + $m8 + ' limpo=' + [string]$f7Clean)
  }

  # --- T9 (H-D): root morto + descendente VIVO => Wait-MarkerGone NAO pode
  # retornar true. HasExited prova so a ausencia DAQUELE processo; tratar a
  # morte do root como "marker inteiro ausente" seria prova FALSA (e era
  # exatamente o cenario de T2, onde o neto fica orfao por proposito).
  $m9 = 'JOBT9-' + [guid]::NewGuid().ToString('N')
  $f9 = Join-Path $base 't9-net.pid'
  $sig9 = Join-Path $base 't9-signal'
  $job9 = New-RuntimeJobObject
  $root9 = $null
  $netPid9 = 0
  $assigned9 = $false
  try {
    $psi9 = New-Object System.Diagnostics.ProcessStartInfo
    $psi9.FileName = $psExe
    $psi9.Arguments = '-NoProfile -File "' + $childScript + '" -Role orphan -NetPidFile "' + $f9 + '" -SignalFile "' + $sig9 + '" -StopSignalFile "" -MyMarker ' + $m9
    $psi9.UseShellExecute = $false
    $psi9.CreateNoWindow = $true
    $root9 = [System.Diagnostics.Process]::Start($psi9)
    $as9 = Add-RuntimeJobProcess -Job $job9 -Process $root9
    $assigned9 = [bool]$as9.Ok
    Assert-That $assigned9 'H-D: root atribuido ao job' ([string]$as9.Reason)
    # FIX4/K2: o sinal de spawn fica DENTRO do ramo de atribuicao ok (o mesmo
    # gate efetivo de T1/T2). Assign-fail => o neto nunca nasce, e o finally
    # encerra o root pelo handle retido. Sem este gate, um assign-fail liberaria
    # o spawn de um descendente FORA do job (o bug que H-C corrigiu em T1/T2 e
    # que havia voltado neste teste novo).
    if ($assigned9) {
      [IO.File]::WriteAllText($sig9, 'go')
      $netPid9 = Read-HandOff -Path $f9 -TimeoutMs 25000
      Assert-That ($netPid9 -gt 0) 'H-D: descendente criado (PID real)' ('net_pid=' + $netPid9)
      $rootGone9 = Wait-PidGone ([int]$root9.Id) 20000
      Assert-That $rootGone9 'H-D: root morto DE PROPOSITO (neto fica vivo)' ('pid=' + $root9.Id)
      Start-Sleep -Milliseconds 500
      Assert-That (Test-PidAlive $netPid9) 'H-D: descendente VIVO com root morto' ('net_pid=' + $netPid9)
      $probe9 = Get-OwnProcByMarker -Marker $m9 -TimeoutMs 4000
      Assert-That (([bool]$probe9.QuerySucceeded) -and (@($probe9.Found).Count -ge 1)) 'H-D: consulta CONCLUSIVA ve o descendente vivo (comando tem o marker)' ('ok=' + [string]$probe9.QuerySucceeded + ' encontrados=' + (@($probe9.Found) -join ','))
      # O helper NAO pode afirmar "sem residuo": o descendente ainda casa o marker.
      $t9clean = [bool](Wait-MarkerGone -Marker $m9 -TimeoutMs 3000 -RetainedProc $root9)
      Assert-That ((-not $t9clean)) 'K2/H-D: root morto + descendente vivo => Wait-MarkerGone NAO retorna true (prova falsa impedida)' ('retornou=' + [string]$t9clean + ' net_pid=' + $netPid9 + ' atribuicao=' + [string]$assigned9)
    }
  }
  finally {
    # Descendente esta NO JOB: cleanup por handle (kill-on-close).
    [void](Close-RuntimeJobObject -Job $job9)
    if (-not $assigned9) {
      try { if ($root9.HasExited) { } else { $root9.Kill(); [void]$root9.WaitForExit(15000) } } catch { }
    }
    $t9after = [bool](Wait-MarkerGone -Marker $m9 -TimeoutMs 25000)
    Assert-That $t9after 'H-D: depois do cleanup por handle, ausencia e PROVADA' ('limpo=' + [string]$t9after + ' net_pid=' + $netPid9)
    try { if ($null -ne $root9) { if (-not $root9.HasExited) { $root9.Kill() } } } catch { }
    try { if ($null -ne $root9) { $root9.Close(); $root9.Dispose() } } catch { }
  }

  # --- T10 (H-B): consulta CIM deliberadamente lenta => QuerySucceeded=false
  # dentro do bound, com o filho PROPRIO morto pelo handle retido e SEM
  # processo residual. Prova que a seam e efetivamente interrompivel: sem o
  # filho proprio + WaitForExit + Kill, um Get-CimInstance bloqueante estouraria
  # o deadline sem devolver nada.
  # --- T11 (K2): atribuicao FALHA de verdade => nenhum spawn, nenhum residuo.
  # Este e o caso que discrimina o gate de T1/T2/T9: num host saudavel a
  # atribuicao sempre tem sucesso, entao o ramo de abort nunca era exercitado.
  # Aqui a falha e INJETADA (job com handle invalido => recusa estruturada de
  # Add-RuntimeJobProcess), e o que se prova e:
  #   (a) o sinal de spawn NUNCA e escrito (neto nao nasce FORA do job);
  #   (b) o filho sai sozinho com o codigo de "sinal ausente" (exit 3);
  #   (c) nenhum processo com o marker sobrevive.
  # Sem o gate, o harness escreveria 'go' assim mesmo, o neto nasceria fora do
  # job e (a)/(b) falhariam.
  $m11 = 'JOBT11-' + [guid]::NewGuid().ToString('N')
  $f11 = Join-Path $base 't11-net.pid'
  $sig11 = Join-Path $base 't11-signal'
  $badJob = @{ Ok = $true; Handle = [IntPtr]::Zero; Closed = $false }
  $root11 = $null
  try {
    $psi11 = New-Object System.Diagnostics.ProcessStartInfo
    $psi11.FileName = $psExe
    $psi11.Arguments = '-NoProfile -File "' + $childScript + '" -Role parent -NetPidFile "' + $f11 + '" -SignalFile "' + $sig11 + '" -StopSignalFile "" -MyMarker ' + $m11
    $psi11.UseShellExecute = $false
    $psi11.CreateNoWindow = $true
    $root11 = [System.Diagnostics.Process]::Start($psi11)
    $as11 = Add-RuntimeJobProcess -Job $badJob -Process $root11
    Assert-That ((-not [bool]$as11.Ok)) 'K2: atribuicao injetada FALHA (recusa estruturada, sem excecao)' ('ok=' + [string]$as11.Ok + ' reason=' + [string]$as11.Reason)
    $assigned11 = [bool]$as11.Ok
    # Gate efetivo: o sinal so e liberado com atribuicao ok.
    if ($assigned11) { [IO.File]::WriteAllText($sig11, 'go') }
    Assert-That ((-not (Test-Path -LiteralPath $sig11))) 'K2: assign-fail => sinal de spawn NUNCA escrito (nenhum descendente fora do job)' ('sinal_presente=' + [string](Test-Path -LiteralPath $sig11))
    # O filho (role=parent) espera o sinal, nao o recebe e sai com exit 3.
    $exited11 = $root11.WaitForExit(45000)
    Assert-That $exited11 'K2: filho saiu sozinho apos expirar a espera do sinal' ('exited=' + [string]$exited11)
    $code11 = -1
    try { $code11 = [int]$root11.ExitCode } catch { $code11 = -1 }
    Assert-That ($code11 -eq 3) 'K2: filho saiu com codigo 3 (sinal ausente; nenhum neto criado)' ('exit_code=' + [string]$code11)
    Assert-That ((-not (Test-Path -LiteralPath $f11))) 'K2: nenhum hand-off de neto (o spawn nunca ocorreu)' ('handoff_presente=' + [string](Test-Path -LiteralPath $f11))
  }
  finally {
    try { if ($null -ne $root11) { if (-not $root11.HasExited) { $root11.Kill(); [void]$root11.WaitForExit(10000) } } } catch { }
    try { if ($null -ne $root11) { $root11.Close(); $root11.Dispose() } } catch { }
    $t11clean = [bool](Wait-MarkerGone -Marker $m11 -TimeoutMs 25000)
    Assert-That $t11clean 'K2: nenhum residuo do marcador apos o abort' ('limpo=' + [string]$t11clean + ' marcador=' + $m11)
  }

  # --- T10 (H-B): consulta CIM deliberadamente lenta => QuerySucceeded=false
  # dentro do bound, com o filho PROPRIO morto pelo handle retido e SEM
  # processo residual. Prova que a seam e efetivamente interrompivel: sem o
  # filho proprio + WaitForExit + Kill, um Get-CimInstance bloqueante estouraria
  # o deadline sem devolver nada.
  # Sem try/finally proprio: o teardown do probe CIM (K4) vive no finally
  # EXTERNO da suite, entao um try aqui ficaria sem handler util.
  $m10 = 'JOBT10-' + [guid]::NewGuid().ToString('N')
  $sw10 = [DateTime]::UtcNow
  $slow10 = Get-OwnProcByMarker -Marker $m10 -TimeoutMs 1500 -ProbeDelayMs 20000
  $el10 = [long]([DateTime]::UtcNow - $sw10).TotalMilliseconds
  Assert-That ((-not [bool]$slow10.QuerySucceeded) -and ([bool]$slow10.TimedOut)) 'H-B: consulta lenta => QuerySucceeded=false + TimedOut (nao prova de ausencia)' ('ok=' + [string]$slow10.QuerySucceeded + ' timed_out=' + [string]$slow10.TimedOut)
  Assert-That ($el10 -lt 10000) 'H-B: retorno dentro do bound (filho CIM morto no deadline, nao 20s)' ('elapsed_ms=' + $el10)
  # Aproximacao generosa (startup do powershell ~0.7s + CIM ~0.4s medidos):
  # aqui o ponto e ser CONCLUSIVO, nao rapido.
  $wait10 = [bool](Wait-MarkerGone -Marker $m10 -TimeoutMs 8000)
  Assert-That $wait10 'H-B: marker ausente => conclusivo true (CIM via filho proprio)' ('limpo=' + [string]$wait10)
  # FIX4/K3: sem residuo de cim-probe, verificado pela PROPRIA seam bounded e
  # conclusiva desta suite (filho proprio + WaitForExit + marcador unico desta
  # execucao). Nao se usa Get-CimInstance bloqueante com SilentlyContinue:
  # ele nao tem deadline e, se falhasse, "Count -eq 0" aprovaria uma prova
  # falsa de ausencia. Consulta inconclusiva => a comprovacao FALHA.
  $probeDir10 = ''
  if ($null -ne $script:cimProbeScript) { $probeDir10 = Split-Path -Parent $script:cimProbeScript }
  $residProbe = Get-OwnProcByMarker -Marker ([IO.Path]::GetFileName($probeDir10)) -TimeoutMs 6000
  Assert-That ([bool]$residProbe.QuerySucceeded) 'K3: consulta residual CONCLUSIVA (inconclusiva nunca prova ausencia)' ('ok=' + [string]$residProbe.QuerySucceeded + ' timed_out=' + [string]$residProbe.TimedOut)
  Assert-That (@($residProbe.Found).Count -eq 0) 'K3: nenhum processo cim-probe residual apos timeout (bounded, conclusivo)' ('residuos=' + (@($residProbe.Found) -join ','))
  # K3 doutrina: o veredito de "sem residuo" so pode ser Verdadeiro com
  # consulta CONCLUSIVA. Uma consulta INCONCLUSIVA tem de reprovar o veredito,
  # nunca aprova-lo. Exercitado com uma latencia que estoura o bound de proposito:
  # com o padrao antigo (CIM bloqueante + Count -eq 0) uma falha de CIM
  # apareceria como lista vazia e APROVARIA a prova de ausencia.
  $verdictGood = ([bool]$residProbe.QuerySucceeded) -and (@($residProbe.Found).Count -eq 0)
  $inconclusive10 = Get-OwnProcByMarker -Marker $m10 -TimeoutMs 300 -ProbeDelayMs 15000
  $verdictInconclusive = ([bool]$inconclusive10.QuerySucceeded) -and (@($inconclusive10.Found).Count -eq 0)
  Assert-That ((-not [bool]$inconclusive10.QuerySucceeded)) 'K3: consulta fora do bound => inconclusiva' ('ok=' + [string]$inconclusive10.QuerySucceeded + ' timed_out=' + [string]$inconclusive10.TimedOut)
  Assert-That ((-not $verdictInconclusive) -and $verdictGood) 'K3: inconclusiva REPROVA o veredito de ausencia (so conclusiva aprova)' ('verdict_inconclusiva=' + [string]$verdictInconclusive + ' verdict_conclusiva=' + [string]$verdictGood)
}
finally {
  # FIX4/K4: o TEMP do probe CIM e removido no teardown EXTERNO da suite, para
  # que uma excecao em qualquer caso anterior tambem o limpe.
  if ($null -ne $script:cimProbeScript) {
    $pdir = Split-Path -Parent $script:cimProbeScript
    if (Test-Path -LiteralPath $pdir) { Remove-Item -LiteralPath $pdir -Recurse -Force -ErrorAction SilentlyContinue }
    $script:cimProbeScript = $null
  }
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed')
if ($script:passed -ne $script:total) { exit 1 }
exit 0
