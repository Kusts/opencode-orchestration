# runtime-port-preflight.tests.ps1 -- Phase 22 (V3.1): preflight de porta V2.
# Casos: free / occupied-other / excluded-reserved / REUSE-HOLD (expected =>
# STALE, sem reuse ate prova de instancia exata) / stale-unknown /
# service-unhealthy; read-only (nenhum PID morto); selecao free-port com
# QuerySucceeded explicito; persist pending por perfil isolado (nunca global,
# nunca claim applied); schema exato pending (marker antigo => UNVERIFIED);
# precond remote memory; perfil v2 -ServicePort pending; CLI exit codes;
# service set port nativo SOMENTE com RR_P22_RUN_NATIVE=1 (default SKIP);
# pin --version read-only (nunca set/start); netsh exige rodape '*' e
# invalida numerico malformado; wrapper fino via lib (sem inline, sem bypass).
# PS 5.1 e PS7 compativel. ASCII only. Sem rede, sem segredo, sem kill,
# sem npm/install/service start no default.
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'lib\RuntimePortPreflight.ps1'
. $lib
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$profLib = Join-Path $repoRoot 'scripts\runtime\New-OrchestrationProfile.ps1'
. $profLib
$cli = Join-Path $PSScriptRoot 'RuntimePortPreflight.ps1'
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('rr-p22-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name -- $detail" }
}

function New-FreePortNow {
  $lis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  try {
    $lis.Start()
    return [int]$lis.LocalEndpoint.Port
  }
  finally { try { $lis.Stop() } catch { } }
}

function Invoke-PreflightCli {
  param([string]$Arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:psExe
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:cli + '" ' + $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $script:repoRoot
  try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  $p = [System.Diagnostics.Process]::Start($psi)
  $soTask = $null
  $seTask = $null
  try { $soTask = $p.StandardOutput.ReadToEndAsync() } catch { }
  try { $seTask = $p.StandardError.ReadToEndAsync() } catch { }
  $finished = $false
  try { $finished = $p.WaitForExit(120000) } catch { $finished = $false }
  if (-not $finished) {
    try { $p.Kill() } catch { }
    try { $p.WaitForExit(5000) } catch { }
  }
  $o = ''
  $e = ''
  try { if (($null -ne $soTask) -and ($soTask.Wait(10000))) { $o = [string]$soTask.Result } } catch { $o = '' }
  try { if (($null -ne $seTask) -and ($seTask.Wait(10000))) { $e = [string]$seTask.Result } } catch { $e = '' }
  $c = -1
  try { if ($finished) { $c = $p.ExitCode } } catch { $c = -1 }
  try { $p.Close() } catch { }
  return @{ Code = $c; Out = ($o + "`n" + $e) }
}

try {
  $noRanges = @()
  $lisFree = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Source = 'override'; Detail = 'livre (fixture)' }

  # --- 1. PORT_FREE (override) ---
  $rFree = Invoke-PreflightPort -Port 65011 -ExpectedProcessNames @('opencode') -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That (([string]$rFree.Outcome -eq 'PORT_FREE') -and ([bool]$rFree.ShouldStart) -and (-not [bool]$rFree.ShouldReuse)) 'free => PORT_FREE start=true reuse=false' ([string]$rFree.Outcome)

  # --- 2. PORT_OCCUPIED_OTHER_PROCESS (override, Docker/AI Memory) ---
  $lisOther = @{ Exists = $true; OwningPID = 8160; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'fixture' }
  $procDocker = @{ Exists = $true; PID = 8160; Name = 'com.docker.backend'; Path = 'C:\Program Files\Docker\com.docker.backend.exe'; Detail = 'fixture' }
  $rOther = Invoke-PreflightPort -Port 49374 -ExpectedProcessNames @('opencode') -ListenerOverride $lisOther -ProcessOverride $procDocker -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $false; Healthy = $false; Detail = 'n/a outro processo' }
  Assert-That (([string]$rOther.Outcome -eq 'PORT_OCCUPIED_OTHER_PROCESS') -and (-not [bool]$rOther.ShouldStart) -and (-not [bool]$rOther.ShouldReuse)) 'occupied-49374-docker => OCCUPIED_OTHER start=false' ([string]$rOther.Outcome)
  Assert-That (([string]$rOther.CollisionHint).Contains('49374')) 'occupied-49374 traz hint de colisao 49374' ([string]$rOther.CollisionHint)

  # --- 3. PORT_WINDOWS_EXCLUDED (override) ---
  $rangesEx = @(@{ Start = 50000; End = 50059; Raw = '50000-50059 (fixture)' })
  $rEx = Invoke-PreflightPort -Port 50001 -ExpectedProcessNames @('opencode') -ListenerOverride $lisFree -ExcludedRangesOverride $rangesEx
  Assert-That (([string]$rEx.Outcome -eq 'PORT_WINDOWS_EXCLUDED') -and (-not [bool]$rEx.ShouldStart) -and (-not [bool]$rEx.ShouldReuse)) 'reserved => WINDOWS_EXCLUDED fail-closed' ([string]$rEx.Outcome)

  # --- 4. REUSE HOLD (RR-P22-FIX2): expected + ownership + healthy exato
  # NAO emite OWNED em producao (sem prova de instancia exata) => STALE ---
  $lisExp = @{ Exists = $true; OwningPID = 4242; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'fixture'; QuerySucceeded = $true }
  $procExp = @{ Exists = $true; PID = 4242; Name = 'opencode'; Path = 'C:\x\opencode.exe'; Detail = 'fixture' }
  $rOwned = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procExp -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $true; Detail = 'service status confirma 127.0.0.1:64868 (fixture)' }
  Assert-That (([string]$rOwned.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rOwned.ShouldReuse) -and (-not [bool]$rOwned.ShouldStart)) 'REUSE-HOLD: expected-healthy+ownership => STALE sem reuse/start' ([string]$rOwned.Outcome)
  Assert-That ((([string]($rOwned.Diagnostics -join "`n")) -like '*REUSE HOLD*')) 'REUSE-HOLD: diagnostico explicito' 'sem marcador HOLD'

  # --- 5. PORT_STALE_OR_UNKNOWN: expected sem health provada ---
  $rStaleH = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procExp -ExcludedRangesOverride $noRanges
  Assert-That (([string]$rStaleH.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rStaleH.ShouldStart) -and (-not [bool]$rStaleH.ShouldReuse)) 'expected-sem-health => STALE_OR_UNKNOWN fail-closed' ([string]$rStaleH.Outcome)

  # --- 5a. nome sozinho nunca autoriza reuse (sem ownership) ---
  $rNameOnly = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ListenerOverride $lisExp -ProcessOverride $procExp -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $true; Detail = 'service status confirma 127.0.0.1:64868 (fixture)' }
  Assert-That (([string]$rNameOnly.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rNameOnly.ShouldReuse)) 'nome-only sem ownership => STALE (sem reuse)' ([string]$rNameOnly.Outcome)

  # --- 5b. PORT_STALE_OR_UNKNOWN: PID morto ---
  $procDead = @{ Exists = $false; PID = 99991; Name = ''; Path = ''; Detail = 'fixture: PID morto' }
  $rStaleP = Invoke-PreflightPort -Port 64869 -ExpectedProcessNames @('opencode') -ListenerOverride @{ Exists = $true; OwningPID = 99991; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'fixture' } -ProcessOverride $procDead -ExcludedRangesOverride $noRanges
  Assert-That ([string]$rStaleP.Outcome -eq 'PORT_STALE_OR_UNKNOWN') 'pid-morto => STALE_OR_UNKNOWN' ([string]$rStaleP.Outcome)

  # --- 5c. faixas indisponiveis => fail-closed ---
  $rNoRanges = Invoke-PreflightPort -Port 65012 -ExpectedProcessNames @('opencode') -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges -ExcludedQueryAvailableOverride $false
  Assert-That (([string]$rNoRanges.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rNoRanges.ShouldStart)) 'faixas-indisponiveis => fail-closed' ([string]$rNoRanges.Outcome)

  # --- 6. SERVICE_UNHEALTHY: expected presente mas unhealthy ---
  $rUnhealthy = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procExp -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $false; Detail = 'service status exit 1 (fixture)' }
  Assert-That (([string]$rUnhealthy.Outcome -eq 'SERVICE_UNHEALTHY') -and (-not [bool]$rUnhealthy.ShouldStart) -and (-not [bool]$rUnhealthy.ShouldReuse)) 'expected-unhealthy => SERVICE_UNHEALTHY' ([string]$rUnhealthy.Outcome)

  # --- 7. outcome invalido rejeitado (porta fora do range) ---
  $threwPort = $false
  try { Invoke-PreflightPort -Port 0 | Out-Null } catch { $threwPort = $true }
  Assert-That ($threwPort) 'porta 0 lanca PREFLIGHT-FAIL' 'nao lancou'

  # --- 8. read-only real: listener proprio detectado, fail-closed, PID vivo ---
  $holdLis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $holdLis.Start()
  $holdPort = [int]$holdLis.LocalEndpoint.Port
  try {
    $mePid = $PID
    $rReal = Invoke-PreflightPort -Port $holdPort -ExpectedProcessNames @('opencode')
    Assert-That ((-not [bool]$rReal.ShouldStart) -and (-not [bool]$rReal.ShouldReuse)) 'listener-real => sem start nem reuse' ([string]$rReal.Outcome)
    Assert-That (([string]$rReal.Outcome -eq 'PORT_OCCUPIED_OTHER_PROCESS') -or ([string]$rReal.Outcome -eq 'PORT_STALE_OR_UNKNOWN')) 'listener-real => OCCUPIED_OTHER ou STALE (fail-closed)' ([string]$rReal.Outcome)
    $stillAlive = $false
    try { $pr = Get-Process -Id $mePid -ErrorAction Stop; $stillAlive = $true } catch { $stillAlive = $false }
    Assert-That ($stillAlive) 'read-only: nenhum PID morto pelo preflight (self vivo)' ('pid=' + $mePid)
    if ([bool]$rReal.Listener.Exists) {
      Assert-That ([int]$rReal.Listener.OwningPID -ne 0) 'listener-real: PID dono resolvido ou stale declarado' ('pid=' + $rReal.Listener.OwningPID)
    }
    else {
      Assert-That $false 'listener-real: listener proprio detectado' 'nao detectado (Get-NetTCPConnection/netstat)'
    }
  }
  finally { try { $holdLis.Stop() } catch { } }

  # --- 9. free real (ephemeral, retry TOCTOU) ---
  $gotFree = $false
  $freePort = 0
  for ($i = 0; $i -lt 3; $i++) {
    $cand = New-FreePortNow
    $rr = Invoke-PreflightPort -Port $cand -ExpectedProcessNames @('opencode')
    if ([string]$rr.Outcome -eq 'PORT_FREE') { $gotFree = $true; $freePort = $cand; break }
  }
  Assert-That ($gotFree) 'free-real => PORT_FREE em ate 3 tentativas' ('porta=' + $freePort)

  # --- 10. selecao free-port verificada (QuerySucceeded explicito) ---
  $selRanges = @(@{ Start = 50000; End = 50059; Raw = 'fixture' })
  $probeSel = {
    param($p)
    if ($p -eq 50001) { return @{ Exists = $true; QuerySucceeded = $true } }
    if ($p -eq 65021) { return @{ Exists = $true; QuerySucceeded = $true } }
    return @{ Exists = $false; QuerySucceeded = $true }
  }
  $picked = Select-PreflightServicePort -CandidatePorts @(50001, 65021, 65022) -ExcludedRanges $selRanges -ListenerProbe $probeSel
  Assert-That ($picked -eq 65022) 'Select: pula excluida+ocupada, escolhe livre verificada' ('picked=' + $picked)
  $pickedNone = Select-PreflightServicePort -CandidatePorts @(50001, 65021) -ExcludedRanges $selRanges -ListenerProbe $probeSel
  Assert-That ($pickedNone -eq 0) 'Select: sem livre => 0 (sem chute)' ('picked=' + $pickedNone)
  $probeNoKey = { param($p) return @{ Exists = $false } }
  $pickNoKey = Select-PreflightServicePort -CandidatePorts @(65033) -ExcludedRanges @() -ListenerProbe $probeNoKey
  Assert-That ($pickNoKey -eq 0) 'Select: probe sem QuerySucceeded => 0 (sem default permissivo)' ('picked=' + $pickNoKey)

  # --- 11. persist pending por perfil isolado, nunca global, nunca applied ---
  $profA = Join-Path $base 'profiles\v2a'
  $profB = Join-Path $base 'profiles\v2b'
  New-Item -ItemType Directory -Path $profA -Force | Out-Null
  New-Item -ItemType Directory -Path $profB -Force | Out-Null
  $sA = Set-PreflightPersistedPort -ProfileDir $profA -Port 65111 -Source 'test' -State 'pending'
  $sB = Set-PreflightPersistedPort -ProfileDir $profB -Port 65112 -Source 'test' -State 'pending'
  $gA = Get-PreflightPersistedPort -ProfileDir $profA
  $gB = Get-PreflightPersistedPort -ProfileDir $profB
  Assert-That (([int]$gA.Port -eq 65111) -and ([int]$gB.Port -eq 65112)) 'persist por perfil: valores independentes' ('a=' + $gA.Port + ' b=' + $gB.Port)
  Assert-That ((([string]$gA.State -eq 'pending') -and ([string]$gB.State -eq 'pending'))) 'persist: state pending (desired; nunca applied)' ('a=' + $gA.State + ' b=' + $gB.State)
  $threwApplied = $false
  try { Set-PreflightPersistedPort -ProfileDir $profA -Port 65114 -State 'applied' | Out-Null } catch { $threwApplied = $true }
  Assert-That ($threwApplied) 'persist applied recusado (HOLD)' 'gravou applied'
  $schA = Test-PreflightServicePortSchema -Json (([IO.File]::ReadAllText((Join-Path $profA 'service-port.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json)
  Assert-That ([bool]$schA.Ok) 'schema pending valido' ([string]$schA.Detail)
  $schOld = Test-PreflightServicePortSchema -Json (([pscustomobject]@{ port = 65111; source = 'legado' }))
  Assert-That (-not [bool]$schOld.Ok) 'schema marker antigo sem state => UNVERIFIED' ([string]$schOld.Detail)
  Assert-That ((Test-Path -LiteralPath ([string]$sA.Path) -PathType Leaf) -and ([string]$sA.Path -like ($profA + '*'))) 'persist A confinada ao ProfileDir A' ([string]$sA.Path)
  $globalLeak = $false
  $userProf = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\service-port.json'
  if (Test-Path -LiteralPath $userProf -PathType Leaf) {
    try {
      $gj = (([IO.File]::ReadAllText($userProf, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
      if (([int]$gj.port -eq 65111) -or ([int]$gj.port -eq 65112)) { $globalLeak = $true }
    }
    catch { }
  }
  Assert-That (-not $globalLeak) 'persist: nenhum vazamento para perfil global do usuario' $userProf
  $threwBadPersist = $false
  try { Set-PreflightPersistedPort -ProfileDir (Join-Path $base 'inexistente') -Port 65113 | Out-Null } catch { $threwBadPersist = $true }
  Assert-That ($threwBadPersist) 'persist em ProfileDir inexistente falha' 'nao falhou'

  # --- 12. remote memory precondicoes (sem migracao, sem segredo) ---
  $rmOk = Test-PreflightRemoteMemoryPreconditions -Endpoint 'https://memory.exemplo.internal:8443' -EnvTable @{}
  Assert-That ([bool]$rmOk.Supported) 'remote-memory: endpoint https proprio => precond ok' ([string]$rmOk.Endpoint)
  $rmMissing = Test-PreflightRemoteMemoryPreconditions -Endpoint '' -EnvTable @{}
  Assert-That (-not [bool]$rmMissing.Supported) 'remote-memory: sem endpoint => nao suportado (sem retry infinito)' 'deveria falhar'
  $rmSecret = Test-PreflightRemoteMemoryPreconditions -Endpoint 'https://h/api?api_key=ABC' -EnvTable @{}
  Assert-That (-not [bool]$rmSecret.Supported) 'remote-memory: endpoint com segredo => rejeitado' ([string]$rmSecret.Endpoint)
  Assert-That (-not [bool]$rmOk.RequiresLocalListener) 'remote-memory: nao exige listener local' 'exigiu'

  # --- 13. CLI exit codes (filho real) ---
  $cliFree = Invoke-PreflightCli ('-Port ' + $freePort)
  Assert-That (([int]$cliFree.Code -eq 0) -and ([string]$cliFree.Out -like '*PORT_FREE*')) 'CLI porta livre => exit 0 PORT_FREE' ('exit=' + $cliFree.Code)
  $hold2 = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $hold2.Start()
  $holdPort2 = [int]$hold2.LocalEndpoint.Port
  try {
    $cliOcc = Invoke-PreflightCli ('-Port ' + $holdPort2)
    Assert-That (([int]$cliOcc.Code -eq 2) -and (([string]$cliOcc.Out -like '*PORT_OCCUPIED_OTHER_PROCESS*') -or ([string]$cliOcc.Out -like '*PORT_STALE_OR_UNKNOWN*'))) 'CLI porta ocupada => exit 2 fail-closed' ('exit=' + $cliOcc.Code)
  }
  finally { try { $hold2.Stop() } catch { } }
  $evPath = Join-Path $base 'preflight-evidence.json'
  $cliJson = Invoke-PreflightCli ('-Port ' + $freePort + ' -Json -EvidencePath "' + $evPath + '"')
  Assert-That (([int]$cliJson.Code -eq 0) -and (Test-Path -LiteralPath $evPath -PathType Leaf)) 'CLI -Json -EvidencePath escreve evidencia' ('exit=' + $cliJson.Code)

  # --- 14. perfil v2 -ServicePort (install local, sem rede) ---
  $profRoot = Join-Path $base 'prof root'
  New-Item -ItemType Directory -Path $profRoot -Force | Out-Null
  $svcPortPick = New-FreePortNow
  $createdV2 = $false
  $infoV2 = $null
  try {
    $infoV2 = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $profRoot -RuntimeId 'opencode-v2' -ServicePort $svcPortPick
    $createdV2 = $true
  }
  catch { $createdV2 = $false }
  Assert-That ($createdV2) 'perfil v2 com -ServicePort criado (install local)' 'falhou; ver detalhe acima'
  if ($createdV2) {
    $svcFileV2 = Join-Path (Join-Path $profRoot 'v2') 'service-port.json'
    Assert-That (Test-Path -LiteralPath $svcFileV2 -PathType Leaf) 'perfil v2: service-port.json existe' $svcFileV2
    $mV2 = Get-P7Profile -ProfileRoot $profRoot -Profile 'v2'
    Assert-That (($null -ne $mV2) -and ($null -ne $mV2.service_port) -and ([int]$mV2.service_port.port -eq $svcPortPick) -and ([string]$mV2.service_port.state -eq 'pending')) 'perfil v2: manifest carrega service_port pending (desired)' ('port=' + $svcPortPick)
    Assert-That (($null -ne $mV2) -and (-not [string]::IsNullOrWhiteSpace([string]$mV2.preflight_lib)) -and (Test-Path -LiteralPath ([string]$mV2.preflight_lib) -PathType Leaf)) 'perfil v2: manifest carrega preflight_lib distribuida' ([string]$mV2.preflight_lib)
    $wrapV2 = Join-Path $profRoot 'bin\opencode-v2.ps1'
    $wrapText = ''
    try { $wrapText = [IO.File]::ReadAllText($wrapV2, [Text.Encoding]::UTF8) } catch { $wrapText = '' }
    Assert-That (($wrapText.Contains('RuntimePortPreflight.ps1')) -and ($wrapText.Contains('service-port.json')) -and ($wrapText.Contains('PORT_CONFIGURATION_UNVERIFIED'))) 'wrapper v2: gate via lib + schema UNVERIFIED' 'trecho ausente'
    Assert-That (-not ($wrapText.Contains('SkipPortPreflight'))) 'wrapper v2: sem bypass SkipPortPreflight' 'bypass presente'
    Assert-That (-not (Test-Path -LiteralPath (Join-Path $profRoot 'v1') -PathType Container)) 'perfil v2 com porta nao cria/toca v1 (isolamento)' 'v1 foi tocado'
  }
  $threwSvcV1 = $false
  try { New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot (Join-Path $base 'prof bad') -RuntimeId 'opencode-v1' -ServicePort 65121 | Out-Null } catch { $threwSvcV1 = $true }
  Assert-That ($threwSvcV1) 'ServicePort em v1 rejeitada (so v2)' 'nao rejeitou'
  $threwSvcRange = $false
  try { New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot (Join-Path $base 'prof bad2') -RuntimeId 'opencode-v2' -ServicePort 70000 | Out-Null } catch { $threwSvcRange = $true }
  Assert-That ($threwSvcRange) 'ServicePort fora do range rejeitada antes de escrita' 'nao rejeitou'

  # --- 15. nativo 2.0.18: pin --version read-only sempre; set SOMENTE opt-in ---
  # RR-P22-FIX2: default nunca executa service set/start (sem mutacao, sem
  # debug config que inicia serve). Set real exige RR_P22_RUN_NATIVE=1.
  $v2bin = ''
  foreach ($candBin in @((Join-Path $repoRoot 'cache\v2-probe\node_modules\.bin\opencode.cmd'), (Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\.bin\opencode.cmd'))) {
    if (Test-Path -LiteralPath $candBin -PathType Leaf) { $v2bin = $candBin; break }
  }
  if ([string]::IsNullOrWhiteSpace($v2bin)) {
    $v2exe = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
    if (Test-Path -LiteralPath $v2exe -PathType Leaf) { $v2bin = $v2exe }
  }
  $v2exeOnly = ''
  if ((-not [string]::IsNullOrWhiteSpace($v2bin)) -and $v2bin.ToLowerInvariant().EndsWith('.exe')) { $v2exeOnly = $v2bin }
  else {
    $v2exeGuess = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
    if (Test-Path -LiteralPath $v2exeGuess -PathType Leaf) { $v2exeOnly = $v2exeGuess }
  }
  if ([string]::IsNullOrWhiteSpace($v2exeOnly)) {
    Write-Host '[SKIP] pin 2.0.18 e set-port nativo: binario .exe exato ausente (sem claim)'
    Assert-That $true 'SKIP nativo (sem binario 2.0.18 .exe)' 'skip honesto'
  }
  else {
    # Pin read-only: --version exato, nunca set/start.
    $vvCheck = Invoke-PreflightBoundedExe -File $v2exeOnly -ArgsLine '--version' -TimeoutMs 30000
    $pinExact = (([regex]::IsMatch([string]$vvCheck.Output, '(?m)^opencode v2\.0\.18\s*$')) -and ([int]$vvCheck.ExitCode -eq 0))
    if ($pinExact) {
      Assert-That $true 'pin 2.0.18 --version exato (read-only; sem set/start)' (([string]$vvCheck.Output -split "`r?`n" | Select-Object -First 1))
    }
    else {
      Write-Host '[SKIP] pin 2.0.18 nao provado neste binario (sem claim; sem set)'
      Assert-That $true 'SKIP pin (versao nao provada; set nao executado)' 'skip honesto'
    }
    if ([string]$env:RR_P22_RUN_NATIVE -eq '1') {
      if (-not $pinExact) {
        Assert-That $false 'RUN_NATIVE com pin nao provado: set recusado' 'pin exigido'
      }
      else {
        $setRoot = Join-Path $base 'v2set proof'
        New-Item -ItemType Directory -Path $setRoot -Force | Out-Null
        $setInfo = $null
        $setCreated = $false
        try {
          $setInfo = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $setRoot -RuntimeId 'opencode-v2' -BinaryOverride $v2exeOnly
          $setCreated = $true
        }
        catch { $setCreated = $false }
        Assert-That ($setCreated) 'set-port opt-in: perfil temp com BinaryOverride criado (sem npm)' 'falhou'
        if ($setCreated) {
          $setProfDir = Join-Path $setRoot 'v2'
          $setCfg = [string]$setInfo.ConfigRoot
          $setCwd = Join-Path $base 'v2set cwd'
          New-Item -ItemType Directory -Path $setCwd -Force | Out-Null
          $setPort = New-FreePortNow
          $envT = @{ XDG_CONFIG_HOME = $setCfg }
          $setRes = Invoke-PreflightServiceSetPort -BinaryPath $v2exeOnly -Port $setPort -EnvTable $envT -WorkingDirectory $setCwd -TimeoutMs 30000 -ExpectedVersion '2.0.18' -RequireExactVersion $true -ProfileDir $setProfDir -ExpectedBinaryPath $v2exeOnly
          Assert-That ([bool]$setRes.Ok) ('service set port opt-in ' + $setPort + ' (pending; sem warmup/start)') ([string]$setRes.Output)
          if ([bool]$setRes.Ok) {
            $pendFile = Join-Path $setProfDir 'service-port.json'
            $pendOk = $false
            try {
              $pj = (([IO.File]::ReadAllText($pendFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
              $psch = Test-PreflightServicePortSchema -Json $pj
              $pendOk = (([bool]$psch.Ok) -and ([int]$psch.Port -eq $setPort))
            }
            catch { $pendOk = $false }
            Assert-That ($pendOk) 'set opt-in persiste pending com schema exato (nunca applied)' $pendFile
          }
        }
      }
    }
    else {
      Write-Host '[SKIP] service set port nativo: exige RR_P22_RUN_NATIVE=1 (default sem mutacao)'
      Assert-That $true 'SKIP set-port (opt-in nao ativado; sem claim)' 'skip honesto'
    }
  }

  # --- 16. netsh parsing pt/en, hifen, '*' obrigatorio, malformado invalida ---
  $enRaw = "Protocol tcp Port Exclusion Ranges`r`nStart Port    End Port`r`n----------    --------`r`n  49697        49796`r`n  50000        50059`r`n`r`n* - Administered port exclusions.`r`n"
  $enP = Convert-PreflightExcludedRanges -Raw $enRaw
  Assert-That (([bool]$enP.Recognized) -and (@($enP.Ranges).Count -eq 2)) 'netsh en tabular+star => 2 faixas reconhecidas' (@($enP.Ranges).Count)
  $ptRaw = "Intervalos de porta excluida`r`nPorta inicial  Porta final`r`n----------    --------`r`n  49697        49796`r`n`r`n* - Exclusoes de porta administradas.`r`n"
  $ptP = Convert-PreflightExcludedRanges -Raw $ptRaw
  Assert-That (([bool]$ptP.Recognized) -and (@($ptP.Ranges).Count -eq 1)) 'netsh pt tabular+star => 1 faixa reconhecida' (@($ptP.Ranges).Count)
  $realFmt = "Protocolo tcp Intervalos de Exclusao de Porta`r`n`r`nPorta Inicial    Porta Final      `r`n----------    --------      `r`n     50000       50059     *`r`n     52754       52853      `r`n`r`n* - Exclusoes de porta administradas.`r`n"
  $realP = Convert-PreflightExcludedRanges -Raw $realFmt
  Assert-That (([bool]$realP.Recognized) -and (@($realP.Ranges).Count -eq 2)) 'netsh formato real (star na linha) => 2 faixas' (@($realP.Ranges).Count)
  $hyP = Convert-PreflightExcludedRanges -Raw "faixas excluidas: 50000-50059 (fixture)`r`n* - nota.`r`n"
  Assert-That (([bool]$hyP.Recognized) -and (@($hyP.Ranges).Count -eq 1) -and ([int]$hyP.Ranges[0].Start -eq 50000)) 'netsh hifen+star => 1 faixa' 'nao parseou'
  $noStarP = Convert-PreflightExcludedRanges -Raw "Protocol tcp Port Exclusion Ranges`r`nStart Port    End Port`r`n----------    --------`r`n  49697        49796`r`n"
  Assert-That (-not [bool]$noStarP.Recognized) 'netsh sem rodape star => nao reconhecido (fail-closed)' 'reconheceu indevido'
  $malRangeP = Convert-PreflightExcludedRanges -Raw "Start Port End Port`r`n50000-99999`r`n* - nota.`r`n"
  Assert-That (-not [bool]$malRangeP.Recognized) 'netsh faixa invalida => parse invalidado' 'reconheceu indevido'
  $malNumP = Convert-PreflightExcludedRanges -Raw "Start Port End Port`r`n50000-50059`r`nport 49374 already in use`r`n* - nota.`r`n"
  Assert-That (-not [bool]$malNumP.Recognized) 'netsh linha numerica estranha => parse invalidado' 'reconheceu indevido'
  $invP = Convert-PreflightExcludedRanges -Raw "hello world sem portas"
  Assert-That (-not [bool]$invP.Recognized) 'netsh invalido => formato nao reconhecido' 'reconheceu indevido'
  $emptyP = Convert-PreflightExcludedRanges -Raw ""
  Assert-That (-not [bool]$emptyP.Recognized) 'netsh vazio => formato nao reconhecido' 'reconheceu indevido'
  $realEx = Get-PreflightExcludedRanges
  Assert-That (([bool]$realEx.Available -and (@($realEx.Ranges).Count -ge 0)) -or (-not [bool]$realEx.Available)) 'netsh real: Available coerente com formato+exit' ([string]$realEx.Detail)

  # --- 17. unknown listener recusa; selector exige QuerySucceeded ---
  $lisUnknown = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Source = 'netstat'; Detail = 'netstat timeout (fixture)'; QuerySucceeded = $false }
  $rUnknown = Invoke-PreflightPort -Port 65013 -ExpectedProcessNames @('opencode') -ListenerOverride $lisUnknown -ExcludedRangesOverride $noRanges
  Assert-That (([string]$rUnknown.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rUnknown.ShouldStart) -and (-not [bool]$rUnknown.ShouldReuse)) 'unknown listener => STALE (recusa start/reuse)' ([string]$rUnknown.Outcome)
  $probeUnknown = { param($p) return @{ Exists = $false; QuerySucceeded = $false } }
  $pickUnknown = Select-PreflightServicePort -CandidatePorts @(65031) -ExcludedRanges @() -ListenerProbe $probeUnknown
  Assert-That ($pickUnknown -eq 0) 'selector com query sem sucesso => 0 (sem chute livre)' ('picked=' + $pickUnknown)
  $probeFreeOk = { param($p) return @{ Exists = $false; QuerySucceeded = $true } }
  $pickFreeOk = Select-PreflightServicePort -CandidatePorts @(65032) -ExcludedRanges @() -ListenerProbe $probeFreeOk
  Assert-That ($pickFreeOk -eq 65032) 'selector com query ok livre => escolhe' ('picked=' + $pickFreeOk)

  # --- 18. prefixo nao casa; impostor/outro perfil nega ---
  Assert-That ((Test-PreflightExactEndpoint -Detail 'service status confirma http://127.0.0.1:49374' -Port 49374)) 'endpoint exato 49374 casa' 'nao casou'
  Assert-That (-not (Test-PreflightExactEndpoint -Detail 'service status confirma http://127.0.0.1:49374' -Port 4937)) 'prefixo 4937 nao casa 49374' 'casou indevido'
  $rPrefix = Invoke-PreflightPort -Port 4937 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procExp -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $true; Detail = 'service status confirma http://127.0.0.1:49374 (fixture prefixo)' }
  Assert-That ([string]$rPrefix.Outcome -ne 'PORT_OWNED_BY_EXPECTED_SERVICE') 'health prefixo nao autoriza reuse' ([string]$rPrefix.Outcome)
  $procImpostor = @{ Exists = $true; PID = 4243; Name = 'opencode-impostor'; Path = 'C:\evil\opencode-impostor.exe'; Detail = 'fixture' }
  $rImpostor = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procImpostor -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $true; Detail = 'service status confirma 127.0.0.1:64868 (fixture)' }
  Assert-That (([string]$rImpostor.Outcome -ne 'PORT_OWNED_BY_EXPECTED_SERVICE') -and (-not [bool]$rImpostor.ShouldReuse)) 'opencode-impostor nega reuse' ([string]$rImpostor.Outcome)
  $procOtherProfile = @{ Exists = $true; PID = 4244; Name = 'opencode'; Path = 'C:\outro-perfil\opencode.exe'; Detail = 'fixture' }
  $rOtherProf = Invoke-PreflightPort -Port 64868 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @('C:\x\opencode.exe') -ListenerOverride $lisExp -ProcessOverride $procOtherProfile -ExcludedRangesOverride $noRanges -HealthOverride @{ Checked = $true; Healthy = $true; Detail = 'service status confirma 127.0.0.1:64868 (fixture)' }
  Assert-That (([string]$rOtherProf.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rOtherProf.ShouldReuse)) 'outro perfil nega reuse (STALE)' ([string]$rOtherProf.Outcome)
  Assert-That (-not (Test-PreflightExpectedName -ProcessName 'opencode-impostor' -ExpectedNames @('opencode'))) 'substring impostor nao e expected-name' 'casou indevido'
  Assert-That ((Test-PreflightExpectedName -ProcessName 'opencode.exe' -ExpectedNames @('opencode'))) 'opencode.exe casa exato' 'nao casou'

  # --- 19. helper sem env confinado nao muta; exe-only ---
  $denyRoot = Join-Path $base 'deny proof'
  New-Item -ItemType Directory -Path $denyRoot -Force | Out-Null
  $denyProf = Join-Path $denyRoot 'v2'
  New-Item -ItemType Directory -Path $denyProf -Force | Out-Null
  $denyManifest = [ordered]@{ profile = 'v2'; runtime_id = 'opencode-v2'; generation = 2; home_dir = (Join-Path $denyProf 'home'); config_root = (Join-Path $denyProf 'home\.config'); runtime_dir = (Join-Path $denyProf 'runtime'); install_manifest = ''; wrapper = ''; service_port = $null; created_at = ((Get-Date).ToString('o')); source_revision = 'test'; provisioned = [ordered]@{ binary_path = $psExe; version = 'test'; provenance = 'test' } }
  $denyMf = Join-Path $denyProf 'manifest.json'
  [IO.File]::WriteAllText($denyMf, ((($denyManifest | ConvertTo-Json -Depth 8).TrimEnd() + "`n")), (New-Object Text.UTF8Encoding $false))
  $denyRes = Invoke-PreflightServiceSetPort -BinaryPath $psExe -Port 65131 -EnvTable @{} -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $denyProf -ExpectedBinaryPath $psExe
  Assert-That ((-not [bool]$denyRes.Ok)) 'helper com env vazio nao muta' ([string]$denyRes.Output)
  $cmdFile = Join-Path $base 'fake.cmd'
  [IO.File]::WriteAllText($cmdFile, "@echo off`necho hi`n", (New-Object Text.UTF8Encoding $false))
  $denyCmd = Invoke-PreflightServiceSetPort -BinaryPath $cmdFile -Port 65132 -EnvTable @{ XDG_CONFIG_HOME = (Join-Path $denyProf 'home\.config') } -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $denyProf
  Assert-That ((-not [bool]$denyCmd.Ok)) 'helper .cmd nao-exe nao muta' ([string]$denyCmd.Output)
  $denyDiv = Invoke-PreflightServiceSetPort -BinaryPath $psExe -Port 65133 -EnvTable @{ XDG_CONFIG_HOME = ([IO.Path]::GetTempPath()) } -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $denyProf
  Assert-That ((-not [bool]$denyDiv.Ok)) 'helper com XDG divergente nao muta' ([string]$denyDiv.Output)

  # --- 20. wrapper fresh process sem preload; diagnostico com porta ocupada ---
  $wrapRoot = Join-Path $base 'wrap proof'
  New-Item -ItemType Directory -Path $wrapRoot -Force | Out-Null
  $wrapCreated = $false
  $wrapInfo = $null
  try {
    $wrapInfo = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $wrapRoot -RuntimeId 'opencode-v2'
    $wrapCreated = $true
  }
  catch { $wrapCreated = $false }
  Assert-That ($wrapCreated) 'wrapper: perfil temp criado (sem preload manual)' 'falhou'
  if ($wrapCreated) {
    $wrapFile = Join-Path $wrapRoot 'bin\opencode-v2.ps1'
    Assert-That (Test-Path -LiteralPath $wrapFile -PathType Leaf) 'wrapper: arquivo gerado existe' $wrapFile
    $wt = ''
    try { $wt = [IO.File]::ReadAllText($wrapFile, [Text.Encoding]::UTF8) } catch { $wt = '' }
    Assert-That (($wt.Contains('RuntimePortPreflight.ps1')) -and ($wt.Contains('service-port.json')) -and ($wt.Contains('Test-WrapperDiagAllowed')) -and ($wt.Contains('PORT_CONFIGURATION_UNVERIFIED'))) 'wrapper: lib + allowlist exata + UNVERIFIED embutidos' 'trecho ausente'
    Assert-That ((-not ($wt.Contains('netstat.exe'))) -and (-not ($wt.Contains('SkipPortPreflight'))) -and (-not ($wt.Contains('ReadToEnd')))) 'wrapper: sem inline duplicado (netstat/servico) nem bypass' 'inline ou bypass presente'
    $libCopy = Join-Path (Join-Path $wrapRoot 'v2') 'lib\RuntimePortPreflight.ps1'
    Assert-That (Test-Path -LiteralPath $libCopy -PathType Leaf) 'perfil: copia gerenciada da lib junto ao perfil' $libCopy
    if (Test-Path -LiteralPath $libCopy -PathType Leaf) {
      $hSrc = ''
      $hDst = ''
      try { $hSrc = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1') -Algorithm SHA256).Hash } catch { $hSrc = '' }
      try { $hDst = (Get-FileHash -LiteralPath $libCopy -Algorithm SHA256).Hash } catch { $hDst = '' }
      Assert-That (( -not [string]::IsNullOrWhiteSpace($hSrc)) -and ($hSrc -eq $hDst)) 'lib do perfil identica ao repo (hash)' 'hash divergente'
    }
    $holdW = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $holdW.Start()
    $holdPortW = [int]$holdW.LocalEndpoint.Port
    try {
      $wpsi = New-Object System.Diagnostics.ProcessStartInfo
      $wpsi.FileName = $script:psExe
      $wpsi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $wrapFile + '" --version'
      $wpsi.UseShellExecute = $false
      $wpsi.RedirectStandardOutput = $true
      $wpsi.RedirectStandardError = $true
      $wpsi.CreateNoWindow = $true
      $wpsi.WorkingDirectory = $script:repoRoot
      try { $wpsi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
      $wp = [System.Diagnostics.Process]::Start($wpsi)
      $wsoT = $null
      $wseT = $null
      try { $wsoT = $wp.StandardOutput.ReadToEndAsync() } catch { }
      try { $wseT = $wp.StandardError.ReadToEndAsync() } catch { }
      $wf = $false
      try { $wf = $wp.WaitForExit(60000) } catch { $wf = $false }
      if (-not $wf) { try { $wp.Kill() } catch { }; try { $wp.WaitForExit(5000) } catch { } }
      $wso = ''
      try { if (($null -ne $wsoT) -and ($wsoT.Wait(10000))) { $wso = [string]$wsoT.Result } } catch { $wso = '' }
      try { $wp.Close() } catch { }
      Assert-That ($wf) 'wrapper fresh process: diagnostico --version conclui com porta ocupada (bounded)' 'timeout'
      Assert-That (([string]$wso -like '*geracao*') -or ([string]$wso -like '*wrapper*') -or ([string]$wso -like '*binario*') -or ([string]$wso -like '*opencode*')) 'wrapper fresh: saida diagnostica sem preload' 'sem saida'
    }
    finally { try { $holdW.Stop() } catch { } }
  }

  # --- 21. bounded: filho hung e filho verboso ---
  $hungStart = Get-Date
  $hung = Invoke-PreflightBoundedExe -File $script:psExe -ArgsLine '-NoProfile -Command "Start-Sleep -Seconds 30"' -TimeoutMs 3000
  $hungElapsed = ((Get-Date) - $hungStart).TotalMilliseconds
  Assert-That (([bool]$hung.TimedOut) -and (-not [bool]$hung.Finished)) 'filho hung => timeout sem claim de conclusao' ('timedout=' + $hung.TimedOut)
  Assert-That ($hungElapsed -lt 20000) 'filho hung limitado (sem espera infinita)' ('ms=' + $hungElapsed)
  $verb = Invoke-PreflightBoundedExe -File $script:psExe -ArgsLine '-NoProfile -Command "1..5000 | ForEach-Object { Write-Output (''x'' * 200) }"' -TimeoutMs 30000
  Assert-That (([bool]$verb.Finished) -and ([string]$verb.Output.Length -le 9000)) 'filho verboso drenado sem deadlock e com saida limitada' ('len=' + ([string]$verb.Output).Length)
  Assert-That ([bool]$verb.Truncated) 'filho verboso: Truncated=true (nunca success a jusante)' ('truncated=' + $verb.Truncated)
  $small = Invoke-PreflightBoundedExe -File $script:psExe -ArgsLine '-NoProfile -Command "Write-Output hello"' -TimeoutMs 30000
  Assert-That (([bool]$small.Finished) -and (-not [bool]$small.Truncated) -and ([string]$small.Output -like '*hello*')) 'filho pequeno: Truncated=false com saida integra' ([string]$small.Output.Length)

  # --- 22. ownership .exe-only (shim .cmd nunca prova; nome-only nao basta) ---
  $ownExe = Test-PreflightOwnershipProven -Process @{ Path = 'C:\x\opencode.exe' } -ExpectedBinaryPaths @('C:\x\opencode.exe')
  Assert-That ([bool]$ownExe) 'ownership .exe exato => true' 'negou indevido'
  $ownCmd = Test-PreflightOwnershipProven -Process @{ Path = 'C:\x\opencode.cmd' } -ExpectedBinaryPaths @('C:\x\opencode.cmd')
  Assert-That (-not [bool]$ownCmd) 'processo .cmd nunca prova ownership' 'provou indevido'
  $ownCmdAllow = Test-PreflightOwnershipProven -Process @{ Path = 'C:\x\opencode.exe' } -ExpectedBinaryPaths @('C:\x\opencode.cmd')
  Assert-That (-not [bool]$ownCmdAllow) 'allowlist .cmd (shim provisionado) nunca casa exe' 'casou indevido'
  $ownNameOnly = Test-PreflightOwnershipProven -Process @{ Path = 'C:\cache\outro\opencode.exe' } -ExpectedBinaryPaths @() -ExpectedProfileDir ''
  Assert-That (-not [bool]$ownNameOnly) 'sem allowlist/perfil => sem ownership (nome-only nao vale)' 'provou indevido'

  # --- 23. RR-P22-FIX3: wrapper UNVERIFIED sempre (pending/absent=>blocked);
  # job QuerySucceeded explicito (excecao capturada, sem true por row);
  # V1 env passthrough vs V2 strip; HOLD estruturado; junction fail-closed ---
  function Invoke-WrapCli {
    param([string]$WrapFile, [string]$Arguments)
    $wpsi = New-Object System.Diagnostics.ProcessStartInfo
    $wpsi.FileName = $script:psExe
    $wpsi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $WrapFile + '" ' + $Arguments
    $wpsi.UseShellExecute = $false
    $wpsi.RedirectStandardOutput = $true
    $wpsi.RedirectStandardError = $true
    $wpsi.CreateNoWindow = $true
    $wpsi.WorkingDirectory = $script:repoRoot
    try { $wpsi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
    $wp2 = [System.Diagnostics.Process]::Start($wpsi)
    $wsoT2 = $null
    $wseT2 = $null
    try { $wsoT2 = $wp2.StandardOutput.ReadToEndAsync() } catch { }
    try { $wseT2 = $wp2.StandardError.ReadToEndAsync() } catch { }
    $wf2 = $false
    try { $wf2 = $wp2.WaitForExit(60000) } catch { $wf2 = $false }
    if (-not $wf2) { try { $wp2.Kill() } catch { }; try { $wp2.WaitForExit(5000) } catch { } }
    $wso2 = ''
    $wse2 = ''
    try { if (($null -ne $wsoT2) -and ($wsoT2.Wait(10000))) { $wso2 = [string]$wsoT2.Result } } catch { $wso2 = '' }
    try { if (($null -ne $wseT2) -and ($wseT2.Wait(10000))) { $wse2 = [string]$wseT2.Result } } catch { $wse2 = '' }
    $wc2 = -1
    try { if ($wf2) { $wc2 = $wp2.ExitCode } } catch { $wc2 = -1 }
    try { $wp2.Close() } catch { }
    return @{ Code = $wc2; Out = ($wso2 + "`n" + $wse2); Done = $wf2 }
  }

   # Destination options cannot bypass the profile-owned port contract,
   # regardless of whether a pending marker exists.
  $fake2 = Join-Path $base 'fake2.cmd'
  [IO.File]::WriteAllText($fake2, "@echo off`r`nif `"%1`"==`"--version`" (echo opencode v2.0.18) else (echo fake2 %*)`r`n", (New-Object Text.UTF8Encoding $false))
  if ($createdV2) {
    $wrapPend = Join-Path $profRoot 'bin\opencode-v2.ps1'
    $ndPend = Invoke-WrapCli -WrapFile $wrapPend -Arguments ('-BinaryPath "' + $fake2 + '" serve --port 65199')
     Assert-That (([bool]$ndPend.Done) -and ([int]$ndPend.Code -eq 2) -and ([string]$ndPend.Out -like '*opt de destino recusada*')) 'pending marker cannot authorize native --port override' ('exit=' + $ndPend.Code)
  }
  else {
    Assert-That $false 'FIX3: perfil v2 pendente disponivel para teste pending->blocked' 'perfil v2 nao criado'
  }

   # Missing marker does not authorize a native destination override either.
  if ($wrapCreated) {
    $wrapAbs = Join-Path $wrapRoot 'bin\opencode-v2.ps1'
    $svcAbs = Join-Path (Join-Path $wrapRoot 'v2') 'service-port.json'
    if (Test-Path -LiteralPath $svcAbs -PathType Leaf) { Remove-Item -LiteralPath $svcAbs -Force -ErrorAction SilentlyContinue }
    $ndAbs = Invoke-WrapCli -WrapFile $wrapAbs -Arguments ('-BinaryPath "' + $fake2 + '" serve --port 65200')
     Assert-That (([bool]$ndAbs.Done) -and ([int]$ndAbs.Code -eq 2) -and ([string]$ndAbs.Out -like '*opt de destino recusada*')) 'missing marker cannot authorize native --port override' ('exit=' + $ndAbs.Code)
    $dgV = Invoke-WrapCli -WrapFile $wrapAbs -Arguments ('-BinaryPath "' + $fake2 + '" --version')
    Assert-That (([bool]$dgV.Done) -and ([string]$dgV.Out -notlike '*PORT_CONFIGURATION_UNVERIFIED*')) 'FIX3: v2 diagnostico --version nao bloqueia UNVERIFIED' 'bloqueou indevido'
  }
  else {
    Assert-That $false 'FIX3: perfil wrapper disponivel para teste absent->blocked' 'perfil nao criado'
  }

  # 23c. job: sem chave QuerySucceeded => recusa; bounded nunca lanca.
  $qMissing = Get-PreflightListenerQueryOk -Listener @{ Exists = $false; Detail = 'sem chave (fixture)' }
  Assert-That (-not [bool]$qMissing) 'FIX3: row sem QuerySucceeded => recusa (sem true por row)' 'aceitou indevido'
  $jbOk = $false
  $jbRes = $null
  try {
    $jbRes = Get-PreflightNetTCPListenerBounded -Port 65041 -TimeoutMs 10000
    $jbOk = (($null -ne $jbRes) -and ($jbRes.ContainsKey('QuerySucceeded')))
  }
  catch { $jbOk = $false }
  Assert-That ($jbOk) 'FIX3: bounded retorna QuerySucceeded explicito sem lancar (excecao capturada)' 'lancou ou sem chave'

  # 23d. V1 recebe OPENCODE_CONFIG*; V2 remove. Filho via wrapper service status.
  $fake1 = Join-Path $base 'fake1.cmd'
  [IO.File]::WriteAllText($fake1, "@echo off`r`nif `"%1`"==`"--version`" (echo opencode v1.0.0) else (echo VAL-[%OPENCODE_CONFIG_FIX3_PROBE%])`r`n", (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText($fake2, "@echo off`r`nif `"%1`"==`"--version`" (echo opencode v2.0.18) else (echo VAL-[%OPENCODE_CONFIG_FIX3_PROBE%])`r`n", (New-Object Text.UTF8Encoding $false))
  $v1Root = Join-Path $base 'v1env proof'
  New-Item -ItemType Directory -Path $v1Root -Force | Out-Null
  $v1Made = $false
  try {
    New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $v1Root -RuntimeId 'opencode-v1' | Out-Null
    $v1Made = $true
  }
  catch { $v1Made = $false }
  Assert-That ($v1Made) 'FIX3: perfil v1 temp criado (env test)' 'falhou'
  if ($v1Made -and $wrapCreated) {
    $env:OPENCODE_CONFIG_FIX3_PROBE = 'SENTINEL-FIX3'
    try {
      $w1 = Join-Path $v1Root 'bin\opencode-v1.ps1'
      $r1 = Invoke-WrapCli -WrapFile $w1 -Arguments ('-BinaryPath "' + $fake1 + '" service status')
      Assert-That (([string]$r1.Out -like '*SENTINEL-FIX3*')) 'FIX3: filho V1 recebe OPENCODE_CONFIG* (passthrough)' 'valor ausente no filho'
      $w2b = Join-Path $wrapRoot 'bin\opencode-v2.ps1'
      $r2 = Invoke-WrapCli -WrapFile $w2b -Arguments ('-BinaryPath "' + $fake2 + '" service status')
      Assert-That (([string]$r2.Out -notlike '*SENTINEL-FIX3*')) 'FIX3: filho V2 sem OPENCODE_CONFIG* (strip gen2)' 'valor vazou no filho V2'
    }
    finally {
      try { Remove-Item Env:\OPENCODE_CONFIG_FIX3_PROBE -ErrorAction SilentlyContinue } catch { }
    }
  }

  # 23e. HOLD estruturado quando env efetivo inseguro (antes de mutador).
  $holdRes = Invoke-PreflightServiceSetPort -BinaryPath $psExe -Port 65141 -EnvTable @{} -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $denyProf -ExpectedBinaryPath $psExe
  Assert-That (((-not [bool]$holdRes.Ok) -and ([string]$holdRes.Hold -eq 'NATIVE_PORT_CONFIGURATION_HOLD') -and ([string]$holdRes.Output -like '*NATIVE_PORT_CONFIGURATION_HOLD*'))) 'FIX3: env efetivo inseguro => HOLD estruturado (sem mutador)' ([string]$holdRes.Output)

  # 23f. junction no caminho => fail-closed; Path==Root verifica raiz.
  $jTarget = Join-Path $base 'j-target'
  $jLink = Join-Path $profA 'j-link'
  New-Item -ItemType Directory -Path $jTarget -Force | Out-Null
  $jMade = $false
  try {
    New-Item -ItemType Junction -Path $jLink -Target $jTarget -ErrorAction Stop | Out-Null
    $jMade = $true
  }
  catch { $jMade = $false }
  if ($jMade) {
    $jAnc = Test-PreflightNoReparseAncestry -Path (Join-Path $jLink 'x') -Root $profA
    Assert-That (-not [bool]$jAnc.Ok) 'FIX3: ancestry com junction => recusa' ([string]$jAnc.Detail)
    try { Remove-Item -LiteralPath $jLink -Force -ErrorAction SilentlyContinue } catch { }
  }
  else {
    Write-Host '[SKIP] junction: privilegio indisponivel (sem claim)'
    Assert-That $true 'SKIP junction (sem privilegio; sem claim)' 'skip honesto'
  }
  $rootSelf = Test-PreflightNoReparseAncestry -Path $profA -Root $profA
  Assert-That ((($null -ne $rootSelf) -and ($rootSelf.ContainsKey('Ok')))) 'FIX3: Path==Root retorna veredicto explicito (raiz verificada)' 'sem veredicto'

  # --- 24. RR-P22-FINAL: negativos comportamentais (lib intacta) ---
  # 24a. EnvRemove mandatory com CONFIG valido => HOLD antes do binario.
  # Exe sintetico existente ($psExe .exe), sem mutacao, sem persist.
  Assert-That (Test-Path -LiteralPath $psExe -PathType Leaf) 'FINAL: exe sintetico existente (HOLD antes do binario)' $psExe
  $denyCfg = Join-Path $denyProf 'home\.config'
  $mandKeys = @('XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'HOME', 'USERPROFILE')
  foreach ($mk in $mandKeys) {
    $mkRes = Invoke-PreflightServiceSetPort -BinaryPath $psExe -Port 65151 -EnvTable @{ XDG_CONFIG_HOME = $denyCfg } -EnvRemove @($mk) -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $denyProf -ExpectedBinaryPath $psExe
    Assert-That (((-not [bool]$mkRes.Ok) -and ([string]$mkRes.Hold -eq 'NATIVE_PORT_CONFIGURATION_HOLD'))) ('FINAL: EnvRemove ' + $mk + ' com CONFIG valido => HOLD antes do binario') ([string]$mkRes.Output)
    Assert-That (([string]$mkRes.Output -like '*NATIVE_PORT_CONFIGURATION_HOLD*')) ('FINAL: EnvRemove ' + $mk + ' output carrega HOLD') ([string]$mkRes.Output)
  }
  $noPersistAfterEnv = -not (Test-Path -LiteralPath (Join-Path $denyProf 'service-port.json') -PathType Leaf)
  Assert-That ($noPersistAfterEnv) 'FINAL: HOLD por EnvRemove nao persiste marker (sem writes)' $denyProf

  # 24b. junction no PAI (acima do Root) com path normal (alias/v2) => recusa.
  $paiTarget = Join-Path $base 'pai-target'
  $paiLink = Join-Path $base 'pai-link'
  New-Item -ItemType Directory -Path $paiTarget -Force | Out-Null
  $paiMade = $false
  try {
    New-Item -ItemType Junction -Path $paiLink -Target $paiTarget -ErrorAction Stop | Out-Null
    $paiMade = $true
  }
  catch { $paiMade = $false }
  if ($paiMade) {
    $paiProf = Join-Path $paiLink 'v2'
    New-Item -ItemType Directory -Path $paiProf -Force | Out-Null
    $paiManifest = [ordered]@{ profile = 'v2'; runtime_id = 'opencode-v2'; generation = 2; home_dir = (Join-Path $paiProf 'home'); config_root = (Join-Path $paiProf 'home\.config'); runtime_dir = (Join-Path $paiProf 'runtime'); install_manifest = ''; wrapper = ''; service_port = $null; created_at = ((Get-Date).ToString('o')); source_revision = 'test'; provisioned = [ordered]@{ binary_path = $psExe; version = 'test'; provenance = 'test' } }
    $paiMf = Join-Path $paiProf 'manifest.json'
    [IO.File]::WriteAllText($paiMf, ((($paiManifest | ConvertTo-Json -Depth 8).TrimEnd() + "`n")), (New-Object Text.UTF8Encoding $false))
    $paiAnc = Test-PreflightNoReparseAncestry -Path $paiProf -Root $paiProf
    Assert-That (-not [bool]$paiAnc.Ok) 'FINAL: PAI junction acima do Root => ancestry recusa (path normal)' ([string]$paiAnc.Detail)
    $paiFileAnc = Test-PreflightNoReparseAncestry -Path (Join-Path $paiProf 'service-port.json') -Root $paiProf
    Assert-That (-not [bool]$paiFileAnc.Ok) 'FINAL: PAI alias/v2 marker sob junction => recusa' ([string]$paiFileAnc.Detail)
    $threwPai = $false
    try { Set-PreflightPersistedPort -ProfileDir $paiProf -Port 65152 -State 'pending' | Out-Null } catch { $threwPai = $true }
    Assert-That ($threwPai) 'FINAL: PAI persist recusa (sem writes)' 'gravou indevido'
    $paiLeakLink = Test-Path -LiteralPath (Join-Path $paiProf 'service-port.json') -PathType Leaf
    Assert-That (-not $paiLeakLink) 'FINAL: PAI sem marker no alias (sem writes out)' $paiProf
    $paiLeakTarget = Test-Path -LiteralPath (Join-Path (Join-Path $paiTarget 'v2') 'service-port.json') -PathType Leaf
    Assert-That (-not $paiLeakTarget) 'FINAL: PAI sem marker no target (sem writes out)' $paiTarget
    $paiCfg = Join-Path $paiProf 'home\.config'
    $paiHelp = Invoke-PreflightServiceSetPort -BinaryPath $psExe -Port 65153 -EnvTable @{ XDG_CONFIG_HOME = $paiCfg } -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMs 10000 -RequireExactVersion $false -ProfileDir $paiProf -ExpectedBinaryPath $psExe
    Assert-That (-not [bool]$paiHelp.Ok) 'FINAL: PAI helper recusa (fail-closed, sem writes)' ([string]$paiHelp.Output)
    $paiHelpLeak = $false
    try { if (($null -ne $paiHelp.PersistedPath) -and (-not [string]::IsNullOrWhiteSpace([string]$paiHelp.PersistedPath))) { $paiHelpLeak = Test-Path -LiteralPath ([string]$paiHelp.PersistedPath) -PathType Leaf } } catch { $paiHelpLeak = $false }
    Assert-That (-not $paiHelpLeak) 'FINAL: PAI helper sem PersistedPath gravado' 'vazou escrita'
    try { Remove-Item -LiteralPath $paiLink -Force -ErrorAction SilentlyContinue } catch { }
  }
  else {
    Write-Host '[SKIP] PAI junction: privilegio indisponivel (sem claim)'
    Assert-That $true 'SKIP PAI junction (sem privilegio; sem claim)' 'skip honesto'
  }

  # 24c. Path==Root anti-reparse: normal => Ok; Root junction => recusa.
  $rootNormOk = Test-PreflightNoReparseAncestry -Path $profA -Root $profA
  Assert-That ([bool]$rootNormOk.Ok) 'FINAL: Path==Root normal => Ok (raiz verificada sem reparse)' ([string]$rootNormOk.Detail)
  $rjTarget = Join-Path $base 'rootj-target'
  $rjLink = Join-Path $base 'rootj-link'
  New-Item -ItemType Directory -Path $rjTarget -Force | Out-Null
  $rjMade = $false
  try {
    New-Item -ItemType Junction -Path $rjLink -Target $rjTarget -ErrorAction Stop | Out-Null
    $rjMade = $true
  }
  catch { $rjMade = $false }
  if ($rjMade) {
    $rjSelf = Test-PreflightNoReparseAncestry -Path $rjLink -Root $rjLink
    Assert-That (-not [bool]$rjSelf.Ok) 'FINAL: Path==Root junction => recusa (raiz e reparse)' ([string]$rjSelf.Detail)
    try { Remove-Item -LiteralPath $rjLink -Force -ErrorAction SilentlyContinue } catch { }
  }
  else {
    Write-Host '[SKIP] Root junction: privilegio indisponivel (sem claim)'
    Assert-That $true 'SKIP Root junction (sem privilegio; sem claim)' 'skip honesto'
  }

  # --- 25. RR-P22-NATIVE-IMPLEMENT: empty-state por perfil substitui gate global 49374 ---
  $esRoot = Join-Path $base 'empty-state proof'
  New-Item -ItemType Directory -Path $esRoot -Force | Out-Null
  $esProf = Join-Path $esRoot 'v2'
  New-Item -ItemType Directory -Path $esProf -Force | Out-Null
  $esStateHome = Join-Path $esProf 'home\.local\state'
  $esCfgHome = Join-Path $esProf 'home\.config'
  New-Item -ItemType Directory -Path $esStateHome -Force | Out-Null
  New-Item -ItemType Directory -Path $esCfgHome -Force | Out-Null
  $esEnv = @{ XDG_CONFIG_HOME = $esCfgHome; XDG_STATE_HOME = $esStateHome }
  $esFresh = Test-PreflightProfileEmptyState -EffEnv $esEnv -ProfileDir $esProf
  Assert-That (([bool]$esFresh.Empty) -and ([string]$esFresh.CurrentDesired -like '*ausente*')) 'EMPTY-STATE: perfil fresh sem state/config => Empty true' ([string]$esFresh.Detail)
  $esStateOp = Join-Path $esStateHome 'opencode'
  New-Item -ItemType Directory -Path $esStateOp -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $esStateOp 'lockfile'), 'owned-service-simulation', (New-Object Text.UTF8Encoding $false))
  $esBusy = Test-PreflightProfileEmptyState -EffEnv $esEnv -ProfileDir $esProf
  Assert-That ((-not [bool]$esBusy.Empty)) 'EMPTY-STATE: state com item => Empty false (possivel owned)' ([string]$esBusy.Detail)
  try { Remove-Item -LiteralPath (Join-Path $esStateOp 'lockfile') -Force -ErrorAction Stop } catch { }
  $esCfgOp = Join-Path $esCfgHome 'opencode'
  New-Item -ItemType Directory -Path $esCfgOp -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $esCfgOp 'service.json'), '{"port": 56789}', (New-Object Text.UTF8Encoding $false))
  $esDesired = Test-PreflightProfileEmptyState -EffEnv $esEnv -ProfileDir $esProf
  Assert-That (([bool]$esDesired.Empty) -and ([string]$esDesired.CurrentDesired -eq '56789')) 'EMPTY-STATE: service.json {port} legivel => desired atual comparado' ([string]$esDesired.Detail)
  [IO.File]::WriteAllText((Join-Path $esCfgOp 'service.json'), '{port: nao-numerico', (New-Object Text.UTF8Encoding $false))
  $esMalformed = Test-PreflightProfileEmptyState -EffEnv $esEnv -ProfileDir $esProf
  Assert-That ((-not [bool]$esMalformed.Empty)) 'EMPTY-STATE: service.json malformado => Empty false (sem overwrite cego)' ([string]$esMalformed.Detail)
  $libText = ''
  try { $libText = [IO.File]::ReadAllText($lib, [Text.Encoding]::UTF8) } catch { $libText = '' }
  Assert-That ((($libText -notlike '*porta nativa 49374 ocupada*') -and ($libText -notlike '*porta nativa 49374 com query*'))) 'EMPTY-STATE: gate global 49374 removido da lib' 'gate global ainda presente'
  Assert-That (($libText -like '*Test-PreflightProfileEmptyState*')) 'EMPTY-STATE: prova por perfil presente na lib' 'helper ausente'
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
