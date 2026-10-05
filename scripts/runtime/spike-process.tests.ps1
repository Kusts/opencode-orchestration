<#!
.SYNOPSIS
    Regressao do helper de subprocesso isolado (SpikeProcess, Phase 5/8 V3.1).
.DESCRIPTION
    Cobre: exit code verdadeiro (0 e nao-zero), timeout com diagnostico
    parcial, dreno limitado com deadline (C#, sem .Result cego; descendente
    segura pipe + flood), env/cwd so do filho (pai intacto), clean env sem
    segredos herdados, quoting argv (CommandLineToArgvW) + integracao,
    shim .cmd (resolve .exe real; recusa meta-char/injection), versao estrita
    compartilhada, raizes por-run (sentinela/confinamento) e stop com gates.
    Harness [PASS]/[FAIL] + exit 0/1, PS 5.1 e PS7, ASCII puro. Descoberta
    automatica pelo run-v3-tests (scripts/runtime/*.tests.ps1). Escreve so
    em TEMP; nunca toca o repo.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\SpikeProcess.ps1')

$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('spike-proc-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
$cwdT = Join-Path $base 'cwd'
New-Item -ItemType Directory -Path $cwdT -Force | Out-Null

$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total += 1
  if ($condition) { $script:passed += 1; Write-Host ('[PASS] ' + $name) }
  else { Write-Host ('[FAIL] ' + $name + ' -- ' + $detail) }
}

function Get-ProcByMarker([string]$Marker) {
  try {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { ([string]$_.CommandLine).Contains($Marker) })
  }
  catch { return @() }
}

function Stop-ProcByMarker([string]$Marker) {
  foreach ($pr in @(Get-ProcByMarker $Marker)) {
    try { & taskkill /PID $pr.ProcessId /T /F 2>$null | Out-Null } catch { }
  }
}

try {
  # --- 1. exit 0 passa com stdout ---
  $r0 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'hello-zero'") -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (((-not [bool]$r0.TimedOut) -and ([int]$r0.ExitCode -eq 0)) -and ([string]$r0.Stdout -match 'hello-zero')) 'exit 0 com stdout' ('rc=' + $r0.ExitCode + ' timeout=' + $r0.TimedOut + ' out=' + [string]$r0.Stdout)

  # --- 2. exit nao-zero verdadeiro ---
  $r5 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'before-fail'; exit 5") -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (((-not [bool]$r5.TimedOut) -and ([int]$r5.ExitCode -eq 5)) -and ([string]$r5.Stdout -match 'before-fail')) 'exit 5 verdadeiro com stdout parcial' ('rc=' + $r5.ExitCode + ' timeout=' + $r5.TimedOut + ' out=' + [string]$r5.Stdout)

  # --- 3. timeout preserva diagnostico parcial limitado ---
  $marker3 = 'spike-partial-' + [guid]::NewGuid().ToString('N')
  $r3 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', ("Write-Output '" + $marker3 + "'; Start-Sleep -Seconds 120")) -WorkingDirectory $cwdT -TimeoutMs 5000
  Assert-That (([bool]$r3.TimedOut) -and ([string]$r3.Stdout -match $marker3)) 'timeout retem stdout parcial' ('timeout=' + $r3.TimedOut + ' out=' + [string]$r3.Stdout)
  Assert-That ([int]$r3.ExitCode -eq -1) 'timeout reporta ExitCode -1 (sem inventar codigo)' ('rc=' + $r3.ExitCode)
  Start-Sleep -Seconds 3
  $left3 = @(Get-ProcByMarker $marker3)
  Assert-That ($left3.Count -eq 0) 'timeout mata a arvore (sem orfao)' ('restantes=' + $left3.Count)

  # --- 4. env so do filho: override visivel no filho, pai intacto ---
  $sentinel = 'OO_SPIKE_PARENT_' + ([guid]::NewGuid().ToString('N') -replace '-', '')
  $envVal = 'parent-value-keep'
  [Environment]::SetEnvironmentVariable($sentinel, $envVal, 'Process')
  try {
    $cmd4 = 'Write-Output (' + '''child-sees=''' + ' + $env:' + $sentinel + ')'
    $r4 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', $cmd4) -EnvSet @{ $sentinel = 'child-override' } -WorkingDirectory $cwdT -TimeoutMs 30000
  }
  finally {
    $afterParent = [Environment]::GetEnvironmentVariable($sentinel, 'Process')
    [Environment]::SetEnvironmentVariable($sentinel, $null, 'Process')
  }
  Assert-That ([string]$r4.Stdout -match 'child-sees=child-override') 'filho ve override' ([string]$r4.Stdout)
  Assert-That ($afterParent -ceq $envVal) 'pai inalterado apos override do filho' ('pai=' + $afterParent)

  # --- 5. EnvRemove: filho sem a variavel, pai intacto ---
  [Environment]::SetEnvironmentVariable($sentinel, $envVal, 'Process')
  try {
    $cmd5 = 'if ([string]::IsNullOrEmpty($env:' + $sentinel + ')) { Write-Output ' + '''child-removed''' + ' } else { Write-Output ' + '''child-leak''' + ' }'
    $r5e = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', $cmd5) -EnvRemove @($sentinel) -WorkingDirectory $cwdT -TimeoutMs 30000
  }
  finally {
    $afterParent2 = [Environment]::GetEnvironmentVariable($sentinel, 'Process')
    [Environment]::SetEnvironmentVariable($sentinel, $null, 'Process')
  }
  Assert-That ([string]$r5e.Stdout -match 'child-removed') 'filho sem variavel removida' ([string]$r5e.Stdout)
  Assert-That ($afterParent2 -ceq $envVal) 'pai inalterado apos EnvRemove do filho' ('pai=' + $afterParent2)

  # --- 6. stdin fechado ---
  $cmd6 = '$t = [Console]::In.ReadToEnd(); Write-Output (''stdin-len='' + $t.Length)'
  $r6 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', $cmd6) -WorkingDirectory $cwdT -TimeoutMs 15000
  Assert-That (((-not [bool]$r6.TimedOut) -and ([string]$r6.Stdout -match 'stdin-len=0'))) 'stdin fechado (ReadToEnd vazio, sem travar)' ('timeout=' + $r6.TimedOut + ' out=' + [string]$r6.Stdout)

  # --- 7. caminhos com espaco: exe via junction + arg com espaco ---
  $spaceDir = Join-Path $base 'dir com espaco'
  New-Item -ItemType Directory -Path $spaceDir -Force | Out-Null
  $linkDir = Join-Path $spaceDir 'winhome'
  $spacedExeOk = $false
  $spacedDetail = ''
  try {
    New-Item -ItemType Junction -Path $linkDir -Target $env:windir -Force | Out-Null
    $spacedExe = Join-Path $linkDir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $spacedExe -PathType Leaf) {
      $r7 = Invoke-SpikeChild -FilePath $spacedExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'arg with spaces ok'") -WorkingDirectory $cwdT -TimeoutMs 30000
      $spacedExeOk = (((-not [bool]$r7.TimedOut) -and ([int]$r7.ExitCode -eq 0)) -and ([string]$r7.Stdout -match 'arg with spaces ok'))
      $spacedDetail = ('rc=' + $r7.ExitCode + ' timeout=' + $r7.TimedOut + ' out=' + [string]$r7.Stdout)
    }
    else {
      $spacedDetail = ('exe via junction ausente: ' + $spacedExe)
    }
  }
  catch {
    $spacedDetail = ('junction falhou: ' + $_.Exception.Message)
  }
  Assert-That $spacedExeOk 'exe e args com espaco' $spacedDetail

  # --- 8. shim .cmd seguro (args safe): exit code real ---
  $shimDir = Join-Path $base 'shim com espaco'
  New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
  $shimPath = Join-Path $shimDir 'probe-shim.cmd'
  [IO.File]::WriteAllText($shimPath, ('@echo off' + "`r`n" + 'echo shim-out-ok' + "`r`n" + 'exit /b 7' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $r8 = Invoke-SpikeChild -FilePath $shimPath -ArgumentList @('a b', 'plain') -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (((-not [bool]$r8.TimedOut) -and ([int]$r8.ExitCode -eq 7)) -and ([string]$r8.Stdout -match 'shim-out-ok')) 'shim .cmd: exit 7 verdadeiro + stdout' ('rc=' + $r8.ExitCode + ' timeout=' + $r8.TimedOut + ' out=' + [string]$r8.Stdout)

  # --- 9. quoting seguro no .exe: arg com & | nao executa nada extra ---
  $r9 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'X'", 'bogus & echo INJECTED | echo PIPE') -WorkingDirectory $cwdT -TimeoutMs 30000
  $noInject = ((([string]$r9.Stdout) -notmatch 'INJECTED') -and (([string]$r9.Stdout) -notmatch 'PIPE'))
  Assert-That $noInject 'sem shell injection via ArgumentList (.exe)' ('out=' + [string]$r9.Stdout + ' err=' + [string]$r9.Stderr)

  # --- 10. cwd isolado do filho ---
  $r10 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', '(Get-Location).Path') -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That ([string]$r10.Stdout -match [regex]::Escape($cwdT)) 'cwd do filho isolado' ([string]$r10.Stdout)

  # --- 11. saida limitada: cap + marcador de truncamento ---
  $r11 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output (('Z' * 70000) -join '')") -WorkingDirectory $cwdT -TimeoutMs 30000 -OutputCapChars 1024
  Assert-That (([string]$r11.Stdout -match 'truncado em 1024 chars') -and ([string]$r11.Stdout.Length -lt 70000)) 'cap de saida com marcador' ('len=' + [string]$r11.Stdout.Length)

  # --- 12. binario inexistente: falha clara sem travar ---
  $r12 = Invoke-SpikeChild -FilePath (Join-Path $base 'nao-existe\bin-missing.exe') -ArgumentList @() -WorkingDirectory $cwdT -TimeoutMs 10000
  Assert-That (((-not [bool]$r12.Started) -and ([int]$r12.ExitCode -eq -3)) -and (-not [string]::IsNullOrWhiteSpace([string]$r12.Note))) 'start falho claro (sem travar)' ('started=' + $r12.Started + ' note=' + [string]$r12.Note)

  # --- 13. quoting argv (vetores unitarios, CommandLineToArgvW) ---
  $q1 = ConvertTo-SpikeArguments -ArgumentList @('plain')
  $q2 = ConvertTo-SpikeArguments -ArgumentList @('a b')
  $q3 = ConvertTo-SpikeArguments -ArgumentList @('')
  $q4 = ConvertTo-SpikeArguments -ArgumentList @('C:\a\')
  $q4b = ConvertTo-SpikeArguments -ArgumentList @('C:\a b\')
  $q5 = ConvertTo-SpikeArguments -ArgumentList @('a"b')
  $q6 = ConvertTo-SpikeArguments -ArgumentList @('a\\b')
  Assert-That ($q1 -ceq 'plain') 'quote: simples intacto' $q1
  Assert-That ($q2 -ceq '"a b"') 'quote: espaco envolve' $q2
  Assert-That ($q3 -ceq '""') 'quote: vazio vira ""' $q3
  Assert-That ($q4 -ceq 'C:\a\') 'quote: backslash sem espaco intacto (argv nao exige quote)' $q4
  Assert-That ($q4b -ceq '"C:\a b\\"') 'quote: backslash final dobrado sob quote' $q4b
  Assert-That ($q5 -ceq '"a\"b"') 'quote: aspa escapada' $q5
  Assert-That ($q6 -ceq 'a\\b') 'quote: backslash sem espaco intacto' $q6

  # --- 14. quoting argv (integracao: round-trip pelo filho via -File) ---
  # NOTA: powershell -Command consome todos os args restantes como script
  # (sem $args); round-trip de args usa -File, que entrega o resto em $args.
  $echoScript = Join-Path $base 'echoargs.ps1'
  [IO.File]::WriteAllText($echoScript, ('foreach ($x in $args) { Write-Output (''ARG:'' + $x) }' + "`r`n" + 'Write-Output (''COUNT:'' + $args.Count)' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $r14 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-File', $echoScript, 'a b', 'C:\temp\', 'q"q') -WorkingDirectory $cwdT -TimeoutMs 30000
  $t14ok = ((([string]$r14.Stdout -match 'COUNT:3') -and ([string]$r14.Stdout -match 'ARG:a b')) -and (([string]$r14.Stdout -match 'ARG:C:\\temp\\') -and ([string]$r14.Stdout -match 'ARG:q"q')))
  Assert-That $t14ok 'quote: round-trip espaco/backslash/aspa' ([string]$r14.Stdout)

  # --- 15. shim npm resolvido para o .exe real ---
  $npmDir = Join-Path $base 'npm com espaco'
  $npmBin = Join-Path $npmDir '.bin'
  $npmReal = Join-Path $npmDir 'pkg\bin'
  New-Item -ItemType Directory -Path $npmBin -Force | Out-Null
  New-Item -ItemType Directory -Path $npmReal -Force | Out-Null
  Copy-Item -LiteralPath $psExe -Destination (Join-Path $npmReal 'tool.exe') -Force
  $npmShim = Join-Path $npmBin 'tool.cmd'
  [IO.File]::WriteAllText($npmShim, ('@ECHO off' + "`r`n" + '"%dp0%\..\pkg\bin\tool.exe"   %*' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $r15 = Invoke-SpikeChild -FilePath $npmShim -ArgumentList @('-NoProfile', '-Command', "Write-Output 'resolved-ok'") -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (([bool]$r15.ShimResolved) -and (-not [bool]$r15.ViaCmd) -and ([string]$r15.Stdout -match 'resolved-ok')) 'shim npm resolve .exe real (sem cmd)' ('resolved=' + $r15.ShimResolved + ' viacmd=' + $r15.ViaCmd + ' out=' + [string]$r15.Stdout)
  Assert-That ([string]$r15.ExecPath -like '*pkg\bin\tool.exe') 'shim npm: ExecPath e o .exe' ([string]$r15.ExecPath)

  # --- 16. shim irresoluvel com meta-char: recusa sem executar ---
  $evilDir = Join-Path $base 'evil com espaco'
  New-Item -ItemType Directory -Path $evilDir -Force | Out-Null
  $evilMarker = Join-Path $evilDir 'RAN.marker'
  if (Test-Path -LiteralPath $evilMarker) { Remove-Item -LiteralPath $evilMarker -Force }
  $evilShim = Join-Path $evilDir 'evil.cmd'
  [IO.File]::WriteAllText($evilShim, ('@echo off' + "`r`n" + 'echo RAN > "' + $evilMarker + '"' + "`r`n" + 'exit /b 0' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $r16a = Invoke-SpikeChild -FilePath $evilShim -ArgumentList @('x&echo PWNED') -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (((-not [bool]$r16a.Started) -and (-not (Test-Path -LiteralPath $evilMarker -PathType Leaf)))) 'shim: arg com & recusado, shim nao executa' ('started=' + $r16a.Started + ' note=' + [string]$r16a.Note)
  $r16b = Invoke-SpikeChild -FilePath ($evilShim + '&whoami') -ArgumentList @() -WorkingDirectory $cwdT -TimeoutMs 10000
  Assert-That (-not [bool]$r16b.Started) 'shim: caminho com & recusado' ('started=' + $r16b.Started + ' note=' + [string]$r16b.Note)
  $r16c = Invoke-SpikeChild -FilePath $evilShim -ArgumentList @('%PATH%') -WorkingDirectory $cwdT -TimeoutMs 30000
  Assert-That (-not [bool]$r16c.Started) 'shim: arg com % recusado' ('started=' + $r16c.Started + ' note=' + [string]$r16c.Note)

  # --- 17. shim irresoluvel com args safe: semantica preservada ---
  $logShim = Join-Path $evilDir 'log.cmd'
  $logFile = Join-Path $evilDir 'args.log'
  if (Test-Path -LiteralPath $logFile) { Remove-Item -LiteralPath $logFile -Force }
  if (Test-Path -LiteralPath $evilMarker) { Remove-Item -LiteralPath $evilMarker -Force }
  [IO.File]::WriteAllText($logShim, ('@echo off' + "`r`n" + 'echo ARGS:%*>>"' + $logFile + '"' + "`r`n" + 'echo RAN > "' + $evilMarker + '"' + "`r`n" + 'exit /b 3' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $r17 = Invoke-SpikeChild -FilePath $logShim -ArgumentList @('service', 'hello world') -WorkingDirectory $cwdT -TimeoutMs 30000
  $logged = ''
  if (Test-Path -LiteralPath $logFile -PathType Leaf) { $logged = [IO.File]::ReadAllText($logFile) }
  Assert-That ((([int]$r17.ExitCode -eq 3) -and ([bool]$r17.ViaCmd)) -and ($logged.Contains('hello world'))) 'shim safe: exit real + args com espaco preservados' ('rc=' + $r17.ExitCode + ' viacmd=' + $r17.ViaCmd + ' logged=' + $logged)

  # --- 17b. StdinNul: EOF via NUL atraves da camada cmd ---
  # NOTA: a camada cmd rejeita parens nos args; o leitor de stdin vive num
  # script -File (uso realista), nunca inline.
  $stdinScript = Join-Path $base 'stdinecho.ps1'
  $stdinLines = @(
    '$t = [Console]::In.ReadToEnd()',
    '$n = 0',
    'if ($null -ne $t) { $n = $t.Length }',
    'Write-Output ("stdin-len=" + $n)'
  )
  $stdinText = (($stdinLines -join "`r`n") + "`r`n")
  [IO.File]::WriteAllText($stdinScript, $stdinText, (New-Object Text.UTF8Encoding $false))
  $rNul = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-File', $stdinScript) -WorkingDirectory $cwdT -TimeoutMs 30000 -StdinNul
  Assert-That (((-not [bool]$rNul.TimedOut) -and ([bool]$rNul.ViaCmd)) -and ([string]$rNul.Stdout -match 'stdin-len=0')) 'stdinnul: EOF entregue, sem travar' ('timeout=' + $rNul.TimedOut + ' out=' + [string]$rNul.Stdout)
  $rNulEcho = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-File', $echoScript, 'nul arg', 'plain') -WorkingDirectory $cwdT -TimeoutMs 30000 -StdinNul
  $nulEchoOk = (([string]$rNulEcho.Stdout -match 'COUNT:2') -and ([string]$rNulEcho.Stdout -match 'ARG:nul arg'))
  Assert-That $nulEchoOk 'stdinnul: args com espaco preservados na camada' ([string]$rNulEcho.Stdout)
  $rNulBad = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('x|echo PWNED') -WorkingDirectory $cwdT -TimeoutMs 15000 -StdinNul
  Assert-That (-not [bool]$rNulBad.Started) 'stdinnul: arg com meta recusado' ('started=' + $rNulBad.Started + ' note=' + [string]$rNulBad.Note)

  # --- 18. versao estrita compartilhada (vetores) ---
  $vOk = (Test-SpikeExactVersion -Text 'opencode v2.0.18' -Version '2.0.18')
  $vNl = (Test-SpikeExactVersion -Text ("opencode v2.0.18`r`n") -Version '2.0.18')
  $vBare = (Test-SpikeExactVersion -Text '2.0.18' -Version '2.0.18')
  $vLong = (Test-SpikeExactVersion -Text 'opencode v2.0.180' -Version '2.0.18')
  $vBeta = (Test-SpikeExactVersion -Text 'opencode v2.0.18-beta' -Version '2.0.18')
  $vMention = (Test-SpikeExactVersion -Text 'my opencode v2.0.18 fork' -Version '2.0.18')
  $vEmpty = (Test-SpikeExactVersion -Text '' -Version '2.0.18')
  $vMulti = (Test-SpikeExactVersion -Text ("banner`nopencode v2.0.18`nok") -Version '2.0.18')
  Assert-That ($vOk -and $vNl) 'versao estrita: formato observado aceito' ('ok=' + $vOk + ' nl=' + $vNl)
  Assert-That ((-not $vBare) -and (-not $vLong) -and (-not $vBeta)) 'versao estrita: rejeita bare/2.0.180/-beta' ('bare=' + $vBare + ' long=' + $vLong + ' beta=' + $vBeta)
  Assert-That ((-not $vMention) -and (-not $vEmpty) -and $vMulti) 'versao estrita: rejeita mencao/vazio; aceita multilinha' ('mention=' + $vMention + ' empty=' + $vEmpty + ' multi=' + $vMulti)

  # --- 19. F1: descendente segura pipe + flood concorrente; retorno limitado ---
  # Mecanismo observado (.NET): neto powershell nao herda o pipe de stdout
  # redirecionado (saida do neto para o pipe se perde), mas MANTEM pipe
  # aberto (dreno stderr nao ve EOF => DrainIncomplete). O flood e provado
  # por arquivo: o neto inunda um log enquanto segura o pipe; o coletor deve
  # retornar no deadline, sem .Result cego, com memoria limitada.
  $floodMarker = 'FLOOD-' + [guid]::NewGuid().ToString('N')
  $floodFile = Join-Path $base 'flood.log'
  if (Test-Path -LiteralPath $floodFile) { Remove-Item -LiteralPath $floodFile -Force }
  $flooder = Join-Path $base 'flooder.ps1'
  $flooderLines = @(
    '$o = $args[1]',
    '$fs = [IO.File]::OpenWrite($o)',
    '$w = New-Object IO.StreamWriter($fs)',
    '$w.AutoFlush = $true',
    'while($true) { $w.WriteLine($args[0]) }'
  )
  [IO.File]::WriteAllText($flooder, (($flooderLines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $launcher = Join-Path $base 'flood-launcher.ps1'
  $grandArgsFile = Join-Path $base 'grand.args'
  [IO.File]::WriteAllLines($grandArgsFile, @('-NoProfile', '-File', $flooder, $floodMarker, $floodFile), (New-Object Text.UTF8Encoding $false))
  $launcherTpl = @(
    '$psi = New-Object System.Diagnostics.ProcessStartInfo',
    '$psi.FileName = "powershell"',
    '$argFile = "ARGSFILE"',
    '$psi.Arguments = (Get-Content -LiteralPath $argFile) -join " "',
    '$psi.UseShellExecute = $false',
    '$psi.RedirectStandardOutput = $false',
    '$psi.RedirectStandardError = $false',
    '$psi.CreateNoWindow = $true',
    '[void][System.Diagnostics.Process]::Start($psi)'
  )
  $launcherText = (($launcherTpl -join "`r`n") + "`r`n") -replace 'ARGSFILE', $grandArgsFile
  if ($launcherText -match '[`r`n]{3,}') {
    Assert-That $false 'flood: launcher sem quebras espurias' 'blocos vazios no launcher gerado'
  }
  [IO.File]::WriteAllText($launcher, $launcherText, (New-Object Text.UTF8Encoding $false))
  try {
    $r19 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-File', $launcher, $floodMarker) -WorkingDirectory $cwdT -TimeoutMs 10000 -OutputCapChars 8192 -DrainMs 5000
    Assert-That ((-not [bool]$r19.TimedOut) -and ([long]$r19.ElapsedMs -lt 25000)) 'flood: raiz sai, retorno em tempo limitado' ('timeout=' + $r19.TimedOut + ' elapsed=' + $r19.ElapsedMs)
    Assert-That ([string]$r19.Stdout.Length -le (8192 + 128)) 'flood: saida do pipe limitada ao teto' ('len=' + [string]$r19.Stdout.Length)
    Assert-That ([bool]$r19.DrainIncomplete) 'flood: dreno incompleto sinalizado (pipe preso pelo descendente)' ('incomplete=' + $r19.DrainIncomplete)
    $floodBytes = 0
    if (Test-Path -LiteralPath $floodFile -PathType Leaf) {
      $floodBytes = (Get-Item -LiteralPath $floodFile).Length
    }
    Assert-That ($floodBytes -gt 65536) 'flood: descendente inundou concorrente ao dreno' ('bytes=' + $floodBytes)
  }
  finally {
    Stop-ProcByMarker $floodMarker
    Start-Sleep -Seconds 2
    $left19 = @(Get-ProcByMarker $floodMarker)
    Assert-That ($left19.Count -eq 0) 'flood: limpeza do descendente' ('restantes=' + $left19.Count)
  }

  # --- 20. F7: clean env sem segredos herdados; pai intacto ---
  $synKey = 'OO_SYNTH_TOKEN_' + ([guid]::NewGuid().ToString('N') -replace '-', '')
  [Environment]::SetEnvironmentVariable($synKey, 'sk-SYNTHETICSECRET-abc123', 'Process')
  [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', 'oo-synthetic-key', 'Process')
  try {
    $cmd20 = '$env:TMP | Out-Null; Get-ChildItem Env: | ForEach-Object { Write-Output ($_.Name + [string][char]61 + $_.Value) }'
    $isoKey = 'OO_SYNTH_ISO_' + ([guid]::NewGuid().ToString('N') -replace '-', '')
    $r20 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', $cmd20) -EnvSet @{ $isoKey = 'iso-present' } -EnvRemove @() -WorkingDirectory $cwdT -TimeoutMs 120000 -CleanEnvironment
    $dump20 = ([string]$r20.Stdout + "`n" + [string]$r20.Stderr)
    $noSynth = ((($dump20 -notmatch 'sk-SYNTHETICSECRET') -and ($dump20 -notmatch 'oo-synthetic-key')) -and (($dump20 -notmatch $synKey) -and ($dump20 -notmatch 'OPENCODE_API_KEY')))
    $hasIso = ($dump20 -match [regex]::Escape($isoKey + '=iso-present'))
    $hasPath = ($dump20 -match '(?m)^PATH=')
    Assert-That ($noSynth -and $hasIso) 'clean env: sem segredos, com isolamento' ('rc=' + $r20.ExitCode + ' timeout=' + $r20.TimedOut + ' ms=' + $r20.ElapsedMs)
    Assert-That $hasPath 'clean env: PATH de runtime preservado' ('PATH ausente no filho rc=' + $r20.ExitCode + ' timeout=' + $r20.TimedOut + ' ms=' + $r20.ElapsedMs)
  }
  finally {
    $afterSyn = [Environment]::GetEnvironmentVariable($synKey, 'Process')
    [Environment]::SetEnvironmentVariable($synKey, $null, 'Process')
    [Environment]::SetEnvironmentVariable('OPENCODE_API_KEY', $null, 'Process')
  }
  Assert-That ($afterSyn -ceq 'sk-SYNTHETICSECRET-abc123') 'clean env: pai intacto' ('pai=' + $afterSyn)

  # --- 21. F5: run-child sentinela + confinamento ---
  $runBase = Join-Path $base 'runs'
  New-Item -ItemType Directory -Path $runBase -Force | Out-Null
  $sentDir = Join-Path $runBase 'sentinel-run'
  New-Item -ItemType Directory -Path $sentDir -Force | Out-Null
  $sentFile = Join-Path $sentDir 'keep.txt'
  [IO.File]::WriteAllText($sentFile, 'sentinel-content', (New-Object Text.UTF8Encoding $false))
  $rc1 = New-SpikeRunChild -BaseDir $runBase -FixedName 'sentinel-run'
  $sentKept = ((Test-Path -LiteralPath $sentFile -PathType Leaf) -and ([IO.File]::ReadAllText($sentFile) -ceq 'sentinel-content'))
  Assert-That (((-not [bool]$rc1.Created) -and $sentKept)) 'run-child: colisao recusa, sentinela intacta' ([string]$rc1.Reason)
  $rc2 = New-SpikeRunChild -BaseDir $runBase -Prefix 'oo-test-'
  Assert-That (([bool]$rc2.Created) -and (Test-Path -LiteralPath ([string]$rc2.Path) -PathType Container)) 'run-child: filho unico criado' ([string]$rc2.Path)
  $outside = Join-Path $base 'outside-victim'
  New-Item -ItemType Directory -Path $outside -Force | Out-Null
  $rrOut = Remove-SpikeRunChild -Path $outside -BaseDir $runBase
  Assert-That (((-not [bool]$rrOut.Removed) -and (Test-Path -LiteralPath $outside -PathType Container))) 'run-child: remocao fora da base recusada' ([string]$rrOut.Reason)
  $rrOk = Remove-SpikeRunChild -Path ([string]$rc2.Path) -BaseDir $runBase
  Assert-That (([bool]$rrOk.Removed) -and (-not (Test-Path -LiteralPath ([string]$rc2.Path))) -and (Test-Path -LiteralPath $runBase -PathType Container)) 'run-child: remove so o filho owned' ([string]$rrOk.Reason)

  # --- 22. F6: stop com gates (simulacao com shim registrador) ---
  $gateDir = Join-Path $base 'gate com espaco'
  New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
  $gateLog = Join-Path $gateDir 'calls.log'
  if (Test-Path -LiteralPath $gateLog) { Remove-Item -LiteralPath $gateLog -Force }
  $gateShim = Join-Path $gateDir 'svc.cmd'
  [IO.File]::WriteAllText($gateShim, ('@echo off' + "`r`n" + 'echo %*>>"' + $gateLog + '"' + "`r`n" + 'if "%1"=="service" if "%2"=="status" echo http://127.0.0.1:55555' + "`r`n" + 'exit /b 0' + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $g1 = Invoke-SpikeServiceStopIfOwned -FilePath $gateShim -WorkingDirectory $cwdT -IsolationProved $false -PortConfigured $false -Port 55555 -WarmupAttempted $false -TimeoutMs 15000
  $noCalls = (-not (Test-Path -LiteralPath $gateLog -PathType Leaf))
  Assert-That (((-not [bool]$g1.Attempted) -and $noCalls)) 'stop: gates falhos => nenhuma invocacao' ('attempted=' + $g1.Attempted + ' reason=' + [string]$g1.Reason)
  $g2 = Invoke-SpikeServiceStopIfOwned -FilePath $gateShim -WorkingDirectory $cwdT -IsolationProved $true -PortConfigured $true -Port 55555 -WarmupAttempted $true -TimeoutMs 15000
  $logged2 = ''
  if (Test-Path -LiteralPath $gateLog -PathType Leaf) { $logged2 = [IO.File]::ReadAllText($gateLog) }
  Assert-That (([bool]$g2.Attempted) -and ([bool]$g2.Stopped) -and ($logged2.Contains('service status')) -and ($logged2.Contains('service stop'))) 'stop: gates ok + status owned => stop invocado' ('attempted=' + $g2.Attempted + ' stopped=' + $g2.Stopped + ' logged=' + $logged2)
  if (Test-Path -LiteralPath $gateLog) { Remove-Item -LiteralPath $gateLog -Force }
  $g3 = Invoke-SpikeServiceStopIfOwned -FilePath $gateShim -WorkingDirectory $cwdT -IsolationProved $true -PortConfigured $true -Port 9999 -WarmupAttempted $true -TimeoutMs 15000
  $logged3 = ''
  if (Test-Path -LiteralPath $gateLog -PathType Leaf) { $logged3 = [IO.File]::ReadAllText($gateLog) }
  Assert-That (((-not [bool]$g3.Stopped) -and ($logged3.Contains('service status')) -and (-not ($logged3.Contains('service stop'))))) 'stop: status sem endpoint => stop ausente' ('stopped=' + $g3.Stopped + ' reason=' + [string]$g3.Reason)

  # --- 23. RR-P22-JOB-OBJECTS follow-up: timeout NUNCA por taskkill/PID ---
  # 23a. Com job: a ARVORE morre (neto incluido, por heranca) e TreeKill='job'.
  # O neto existe de verdade (PID real em hand-off), nao um claim.
  $jobLib = Join-Path $PSScriptRoot 'lib\RuntimeJobObject.ps1'
  $hasJobLib = (Test-Path -LiteralPath $jobLib -PathType Leaf)
  if ($hasJobLib) { . $jobLib }
  $mk = 'SPIKETK-' + [guid]::NewGuid().ToString('N')
  $netPidFile = Join-Path $base ('net-' + $mk + '.pid')
  $sigFile = Join-Path $base ('sig-' + $mk)
  $childFile = Join-Path $base ('child-' + $mk + '.ps1')
  $childLines = @(
    'param([string]$NetPidFile, [string]$SignalFile, [string]$Marker)',
    '$psi = New-Object System.Diagnostics.ProcessStartInfo',
    ('$psi.FileName = "' + ($psExe -replace '\\', '\\') + '"'),
    '$psi.Arguments = ''-NoProfile -Command "Start-Sleep -Seconds 60 # '' + $Marker + ''"''',
    '$psi.UseShellExecute = $false',
    '$psi.CreateNoWindow = $true',
    '$net = [System.Diagnostics.Process]::Start($psi)',
    '[IO.File]::WriteAllText($NetPidFile, [string]$net.Id)',
    'while (-not (Test-Path -LiteralPath $SignalFile)) { Start-Sleep -Milliseconds 200 }',
    'Start-Sleep -Seconds 60'
  )
  [IO.File]::WriteAllText($childFile, (($childLines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
  $job = $null
  # Anonimo, como as libs de producao agora fazem (nome fixo abriria job compartilhado).
  if ($hasJobLib) { $job = New-RuntimeJobObject }
  $t23 = $null
  $netPid = 0
  try {
    Assert-That ([bool]$job.Ok) '23: job criado para o teste de arvore' ([string]$job.Reason)
    $t23 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-File', $childFile, '-NetPidFile', $netPidFile, '-SignalFile', $sigFile, '-Marker', $mk) -WorkingDirectory $cwdT -TimeoutMs 9000 -JobObject $job
    Assert-That ([bool]$t23.JobAssigned) '23: filho atributo ao job antes do spawn do neto' ('note=' + [string]$t23.JobNote)
    Assert-That ([bool]$t23.TimedOut) '23: timeout real do filho' ('timeout=' + $t23.TimedOut + ' ms=' + $t23.ElapsedMs)
    Assert-That ([string]$t23.TreeKill -eq 'job') '23: TreeKill=job (kill-on-close cobre a arvore, nao PID historico)' ('tree=' + [string]$t23.TreeKill + ' note=' + [string]$t23.JobNote)
    $netPid = 0
    $deadlineNet = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadlineNet) {
      if (Test-Path -LiteralPath $netPidFile -PathType Leaf) {
        try { $netPid = [int]([IO.File]::ReadAllText($netPidFile)) } catch { $netPid = 0 }
        if ($netPid -gt 0) { break }
      }
      Start-Sleep -Milliseconds 150
    }
    Assert-That ($netPid -gt 0) '23: neto existiu de verdade (PID real em hand-off)' ('net_pid=' + $netPid)
    $leftNet = @(Get-ProcByMarker $mk)
    Assert-That ($leftNet.Count -eq 0) '23: neto morto pelo job (heranca provada, nao /T)' ('restantes=' + $leftNet.Count + ' net_pid=' + $netPid)
  }
  finally {
    try { [void](Close-RuntimeJobObject -Job $job) } catch { }
    Stop-ProcByMarker $mk
  }

  # 23b. SEM job: fallback root-only pelo handle do spawn PROPRIO. O filho e
  # root sem descendente, entao root morto e o unico fato que se prova; nenhum
  # claim de tree kill e feito.
  $mk2 = 'SPIKEROOT-' + [guid]::NewGuid().ToString('N')
  $r23b = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Seconds 60 # ' + $mk2)) -WorkingDirectory $cwdT -TimeoutMs 3000
  Assert-That (([bool]$r23b.TimedOut) -and ([string]$r23b.TreeKill -eq 'root-only')) '23: sem job => TreeKill=root-only (fallback honesto)' ('tree=' + [string]$r23b.TreeKill + ' timeout=' + $r23b.TimedOut)
  Assert-That ((-not [bool]$r23b.JobAssigned) -and ([string]$r23b.JobNote -eq '')) '23: sem -JobObject nada de job e criado' ('assigned=' + $r23b.JobAssigned + ' note=' + [string]$r23b.JobNote)
  $leftRoot = @(Get-ProcByMarker $mk2)
  Assert-That ($leftRoot.Count -eq 0) '23: root encerrado pelo handle do spawn proprio' ('restantes=' + $leftRoot.Count)

  # 23c. GUARDA: a lib de producao nao pode voltar a matar por PID historico.
  # NAO-VACUOSO: leitura falha => FAIL honesto. Sem esta exigencia uma lib
  # ausente/ilegivel devolveria string vazia e o -notmatch passaria por engano.
  function Read-LibText([string]$Path, [string]$Label) {
    $body = ''
    $readOk = $false
    $why = ''
    try {
      if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $why = 'arquivo ausente' }
      else {
        $body = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $readOk = ($body.Length -gt 0)
        if (-not $readOk) { $why = 'conteudo vazio' }
      }
    }
    catch { $why = ('leitura falhou: ' + [string]$_.Exception.Message) }
    Assert-That $readOk ('GUARD-LEITURA: ' + $Label + ' lida e nao vazia (guard nao pode ser vacuo)') ('motivo=' + $why + ' len=' + $body.Length)
    return $body
  }
  $spikeLibText = Read-LibText (Join-Path $PSScriptRoot 'lib\SpikeProcess.ps1') 'SpikeProcess.ps1'
  Assert-That (($spikeLibText -notmatch '(?i)taskkill')) 'GUARD: SpikeProcess.ps1 nunca usa taskkill (kill por handle/job)' ('len=' + $spikeLibText.Length)
  $verifierLibText = Read-LibText (Join-Path (Split-Path -Parent $PSScriptRoot) 'v3\lib\OrchestrationVerifier.ps1') 'OrchestrationVerifier.ps1'
  Assert-That (($verifierLibText -notmatch '(?i)taskkill')) 'GUARD: OrchestrationVerifier.ps1 nunca usa taskkill' ('len=' + $verifierLibText.Length)
  $profileLibText = Read-LibText (Join-Path $PSScriptRoot 'New-OrchestrationProfile.ps1') 'New-OrchestrationProfile.ps1'
  Assert-That (($profileLibText -notmatch '(?i)taskkill')) 'GUARD: New-OrchestrationProfile.ps1 nunca usa taskkill' ('len=' + $profileLibText.Length)

  # 23d. ISOLAMENTO entre jobs: o timeout de um filho NAO pode matar o filho de
  # outro job. Este e o teste que pega nome de job FIXO (CreateJobObjectW abriria
  # o job preexistente e os dois filhos cairiam no mesmo job).
  $mkA = 'SPIKEISOA-' + [guid]::NewGuid().ToString('N')
  $mkB = 'SPIKEISOB-' + [guid]::NewGuid().ToString('N')
  $markerB = Join-Path $base ('iso-b-' + $mkB + '.marker')
  $jobA = $null
  $jobB = $null
  $rA = $null
  $procB = $null
  # SEAM DE TESTE (nunca setado no CI): se a variavel de ambiente abaixo
  # apontar um nome, os DOIS jobs sao criados COM esse nome fixo, reproduzindo
  # o bug original (CreateJobObjectW ABRE o job preexistente e os dois filhos
  # caem no mesmo job). Existe para o controle negativo do bloco 23d provar que
  # o teste pega a regressao; a lib de producao segue anonima.
  $sharedJobName = [Environment]::GetEnvironmentVariable('SPIKE_TEST_SHARED_JOB_NAME', 'Process')
  try {
    if ($hasJobLib) {
      if ([string]::IsNullOrWhiteSpace($sharedJobName)) {
        # Anonimo, como as libs de producao fazem.
        $jobA = New-RuntimeJobObject
        $jobB = New-RuntimeJobObject
      }
      else {
        $jobA = New-RuntimeJobObject -Name $sharedJobName
        $jobB = New-RuntimeJobObject -Name $sharedJobName
      }
    }
    Assert-That (([bool]$jobA.Ok) -and ([bool]$jobB.Ok)) '23: dois jobs criados (anonimos por padrao)' ('a=' + [string]$jobA.Ok + ' b=' + [string]$jobB.Ok + ' nome_compartilhado=' + [string]$sharedJobName)
    # B e spawnado DIRETO (nao via Invoke-SpikeChild) para que o teste controle
    # o momento: B precisa estar VIVO quando A estourar o timeout. B dorme ~6s,
    # imprime 'iso-b-ok' e grava o marker SO no fim.
    $bPsi = New-Object System.Diagnostics.ProcessStartInfo
    $bPsi.FileName = $psExe
    $bCmd = ('Start-Sleep -Seconds 6; Write-Output ''iso-b-ok''; [IO.File]::WriteAllText(''' + $markerB + ''', ''done'') # ' + $mkB)
    $bPsi.Arguments = '-NoProfile -Command "' + $bCmd + '"'
    $bPsi.UseShellExecute = $false
    $bPsi.RedirectStandardOutput = $true
    $bPsi.RedirectStandardError = $true
    $bPsi.CreateNoWindow = $true
    $bPsi.WorkingDirectory = $cwdT
    $procB = [System.Diagnostics.Process]::Start($bPsi)
    $bPid = [int]$procB.Id
    if ($null -ne $jobB -and [bool]$jobB.Ok) {
      [void](Add-RuntimeJobProcess -Job $jobB -Process $procB)
    }
    Assert-That (-not (Test-Path -LiteralPath $markerB -PathType Leaf)) '23: B vivo e marker de B ainda ausente' ('pid=' + $bPid)
    # A estoura o timeout (3s) e morre pelo SEU job.
    $rA = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Seconds 60 # ' + $mkA)) -WorkingDirectory $cwdT -TimeoutMs 3000 -JobObject $jobA
    Assert-That (([bool]$rA.TimedOut) -and ([string]$rA.TreeKill -eq 'job')) '23: A estoura o timeout e mata pelo seu job' ('tree=' + [string]$rA.TreeKill + ' timeout=' + $rA.TimedOut)
    # PROVA DO ISOLAMENTO: se A e B dividissem o job, o Terminate de A teria
    # matado B e o marker NUNCA apareceria. B ainda tem de estar vivo.
    $bAlive = (-not $procB.HasExited)
    $markerAbsent = (-not (Test-Path -LiteralPath $markerB -PathType Leaf))
    Assert-That ($bAlive -and $markerAbsent) '23: isolamento REAL: B continua VIVO depois do stop de A' ('b_vivo=' + $bAlive + ' marker_ausente=' + $markerAbsent + ' pid=' + $bPid)
    # B termina sozinho: espera bounded e o marker tem de aparecer.
    $bDone = $false
    $bDeadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $bDeadline) {
      if (Test-Path -LiteralPath $markerB -PathType Leaf) { $bDone = $true; break }
      if ($procB.HasExited) { break }
      Start-Sleep -Milliseconds 200
    }
    try { $null = $procB.WaitForExit(10000) } catch { }
    $bOut = ''
    try { $bOut = [string]$procB.StandardOutput.ReadToEnd() } catch { $bOut = '' }
    $bCode = -1
    try { $bCode = [int]$procB.ExitCode } catch { $bCode = -1 }
    Assert-That (($bDone) -and ($bCode -eq 0) -and ($bOut -match 'iso-b-ok')) '23: B completou SO depois do stop de A (marker + exit 0 + stdout)' ('marker=' + [string]$bDone + ' rc=' + $bCode + ' out=[' + $bOut.Trim() + ']')
    $leftA = @(Get-ProcByMarker $mkA)
    Assert-That ($leftA.Count -eq 0) '23: stop de A nao deixou residuo' ('restantes_a=' + $leftA.Count)
  }
  finally {
    try { [void](Close-RuntimeJobObject -Job $jobA) } catch { }
    try { [void](Close-RuntimeJobObject -Job $jobB) } catch { }
    # Cleanup de B pelo HANDLE do nosso proprio spawn (Kill no .NET Process),
    # nunca por arvore de PID. B ja terminou em Pass; o guard cobre so o caso
    # de orfao por falha do teste.
    if ($null -ne $procB) {
      try { if (-not $procB.HasExited) { $procB.Kill(); [void]$procB.WaitForExit(8000) } } catch { }
      try { $procB.Close(); $procB.Dispose() } catch { }
    }
    # A tambem nao passa por arvore de PID: o Close do job A e o backstop
    # (KILL_ON_JOB_CLOSE) e ja cobre o filho de A.
  }
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed')
if ($script:passed -ne $script:total) { exit 1 }
exit 0
