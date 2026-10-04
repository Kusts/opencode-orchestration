# runtime-port-preflight-wrapper.tests.ps1 -- Phase 22 RR-P22-WRAPPER (V3.1).
# Integracao da prova native-start-contract ao wrapper V2 (sem HOLD universal
# quando o contrato permite iniciar safely). Lib central
# Ensure/Test-PreflightConfiguredPort (sem inline duplicado; lib copiada aos
# perfis). Mocks deterministicos + fixture E2E real isolado (opt-in).
# PS 5.1 e PS7 compativel. ASCII only. Sem rede, sem segredo, sem kill de PID
# desconhecido, sem config global, sem commit/install. Mutacao nativa real
# SOMENTE com RR_P22_RUN_NATIVE=1; default sem mutacao (pin --version read-only).
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'lib\RuntimePortPreflight.ps1'
. $lib
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$profLib = Join-Path $repoRoot 'scripts\runtime\New-OrchestrationProfile.ps1'
. $profLib
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
$base = Join-Path ([IO.Path]::GetTempPath()) ('rr-p22w-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
# RR-P22-WRAPPER-FIX1: harness nunca deleta temp perfil com runtime unsettled;
# preserva evidence path para cleanup manual (fail-closed do harness).
$script:unsettled = $false
$script:unsettledDetail = ''
$script:evidenceKeep = ''

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
  else { Write-Host "[FAIL] $name -- $detail" }
}

# Junction-safe delete. Remove-Item -Force numa junction cujo alvo tem filhos
# TRAVA o processo quando o console e oculto e a saida esta redirecionada
# (ShouldContinue sem resposta; -ErrorAction nao suprime): foi o que matou esta
# suite no runner com todos os asserts ja completos. Medido em PS 5.1: hang > 60s
# contra 4ms para [IO.Directory]::Delete(path, $false), que remove SO o reparse
# point, sem seguir o alvo e sem prompt.
function Remove-TestReparse([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  try { if (Test-Path -LiteralPath $Path) { [IO.Directory]::Delete($Path, $false) } } catch { }
}

function New-WTempProfileDir([string]$Root, [int]$MarkerPort) {
  $pd = Join-Path $Root ('prof-' + [guid]::NewGuid().ToString('N'))
  $homeD = Join-Path $pd 'home'
  $cfg = Join-Path $homeD '.config'
  New-Item -ItemType Directory -Path $cfg -Force | Out-Null
  $mf = [ordered]@{
    profile = 'v2'
    runtime_id = 'opencode-v2'
    generation = 2
    home_dir = $homeD
    config_root = $cfg
    runtime_dir = (Join-Path $pd 'runtime')
    install_manifest = ''
    wrapper = ''
    service_port = $null
    preflight_lib = ''
    created_at = '2026-09-30T00:00:00Z'
    source_revision = 'test'
    provisioned = $null
  }
  $mfPath = Join-Path $pd 'manifest.json'
  [IO.File]::WriteAllText($mfPath, ((($mf | ConvertTo-Json -Depth 8).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))
  if ($MarkerPort -ne 0) {
    $sv = Set-PreflightPersistedPort -ProfileDir $pd -Port $MarkerPort -Source 'test' -State 'pending'
  }
  return $pd
}

function Invoke-BoundedPs([string]$ScriptFile, [string]$Arguments, [int]$TimeoutMs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:psExe
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptFile + '" ' + $Arguments
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
  try { $finished = $p.WaitForExit($TimeoutMs) } catch { $finished = $false }
  if (-not $finished) {
    try { $p.Kill() } catch { }
    try { $p.WaitForExit(5000) } catch { }
  }
  $o = ''
  $e = ''
  try { if (($null -ne $soTask) -and ($soTask.Wait(5000))) { $o = [string]$soTask.Result } } catch { $o = '' }
  try { if (($null -ne $seTask) -and ($seTask.Wait(5000))) { $e = [string]$seTask.Result } } catch { $e = '' }
  $c = -1
  try { if ($finished) { $c = $p.ExitCode } } catch { $c = -1 }
  try { $p.Close() } catch { }
  return @{ Code = $c; Out = ($o + "`n" + $e); Finished = $finished; TimedOut = (-not $finished) }
}

try {
  $noRanges = @()
  $lisFree = @{ Exists = $false; OwningPID = 0; LocalAddress = ''; Source = 'override'; Detail = 'livre (fixture)'; QuerySucceeded = $true }
  $fakeExe = 'C:\fake\rr-p22w\opencode.exe'
  $resolveOk = @{ Ok = $true; Exe = $fakeExe; Version = 'opencode v2.0.18'; Detail = 'fixture resolve ok' }
  $getOk = { return @{ Ok = $true; Port = 56777; Raw = '56777'; Detail = 'fixture get=56777' } }
  $cfgOk = { return @{ Ok = $true; Exists = $true; Port = 56777; Detail = 'fixture config=56777' } }
  $setOk = { return @{ Ok = $true; Output = 'fixture set ok (pending)' } }

  # 1. schema pending exato ok; sem state => invalido.
  $schOk = Test-PreflightServicePortSchema -Json ([pscustomobject]@{ port = 56777; state = 'pending'; source = 'test' })
  Assert-That ([bool]$schOk.Ok -and ([int]$schOk.Port -eq 56777)) 'w1: schema pending exato ok' 'schema deveria aceitar pending'
  $schOld = Test-PreflightServicePortSchema -Json ([pscustomobject]@{ port = 56777 })
  Assert-That (-not [bool]$schOld.Ok) 'w1: marker antigo sem state invalido' 'sem state deveria recusar'

  # 2. sem marker => bloqueia com instrucao acionavel -ServicePort.
  $pd2 = New-WTempProfileDir $base 0
  $r2 = Ensure-PreflightConfiguredPort -ProfileDir $pd2 -ExplicitPort 0 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r2.Permitted) -and ([string]$r2.Detail -match 'ServicePort')) 'w2: sem marker bloqueia com instrucao -ServicePort' ([string]$r2.Detail)

  # 3. marker pending sem explicit => bloqueia exigindo -ServicePort explicito.
  $pd3 = New-WTempProfileDir $base 56777
  $r3 = Ensure-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 0 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r3.Permitted) -and ([string]$r3.Detail -match 'ServicePort 56777')) 'w3: marker sem explicit bloqueia exigindo -ServicePort igual' ([string]$r3.Detail)

  # 4. explicit divergente do marker => bloqueia.
  $r4 = Ensure-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 56778 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r4.Permitted) -and ([string]$r4.Detail -match 'diverge')) 'w4: explicit divergente bloqueia' ([string]$r4.Detail)

  # 5. desired confirmado + livre => permite executar o escolhido.
  $r5 = Ensure-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ([bool]$r5.Permitted -and ([string]$r5.Outcome -eq 'PORT_FREE') -and ([string]$r5.Exe -eq $fakeExe)) 'w5: desired confirmado+livre permite' ([string]$r5.Detail)
  Assert-That (($null -ne $r5.Env) -and (-not [string]::IsNullOrWhiteSpace([string]$r5.Env['XDG_CONFIG_HOME']))) 'w5: env final confinado retornado (mesmo env)' 'env ausente'

  # 6. ocupado mesmo owned => bloqueia HOLD, ShouldReuse false (REUSE HOLD).
  $lisBusy = @{ Exists = $true; OwningPID = 999999; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'listener 127.0.0.1:56777 PID 999999'; QuerySucceeded = $true }
  $procGone = @{ Exists = $false; PID = 999999; Name = ''; Path = ''; Detail = 'processo PID 999999 nao resolvido (fixture)' }
  $r6 = Ensure-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisBusy -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r6.Permitted)) 'w6: ocupado bloqueia (HOLD mesmo owned)' ([string]$r6.Detail)
  # REUSE HOLD direto no preflight: expected+ownership+health exata => STALE, sem reuse.
  $lisOwn = @{ Exists = $true; OwningPID = 4242; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'listener 127.0.0.1:56777 PID 4242'; QuerySucceeded = $true }
  $procOwn = @{ Exists = $true; PID = 4242; Name = 'opencode'; Path = $fakeExe; Detail = 'fixture owned' }
  $healthExact = @{ Checked = $true; Healthy = $true; Detail = 'http://127.0.0.1:56777' }
  $rHold = Invoke-PreflightPort -Port 56777 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($fakeExe) -ExpectedProfileDir $pd3 -ListenerOverride $lisOwn -ProcessOverride $procOwn -ExcludedRangesOverride $noRanges -HealthOverride $healthExact
  Assert-That (([string]$rHold.Outcome -eq 'PORT_STALE_OR_UNKNOWN') -and (-not [bool]$rHold.ShouldReuse) -and (-not [bool]$rHold.ShouldStart)) 'w6: REUSE HOLD owned exato => STALE sem reuse/start' ([string]$rHold.Outcome)

  # 7. marker sozinho nunca basta: mismatch + state nao-vazio => bloqueia (sem set).
  $pd7 = New-WTempProfileDir $base 56777
  $stOp7 = Join-Path ([string](Get-PreflightEffectiveEnv -EnvTable @{ XDG_CONFIG_HOME = (Join-Path (Join-Path $pd7 'home') '.config') } -ProfileDir $pd7)['XDG_STATE_HOME']) 'opencode'
  New-Item -ItemType Directory -Path $stOp7 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $stOp7 'busy.txt'), "busy`n", (New-Object Text.UTF8Encoding $false))
  $getEmpty = { return @{ Ok = $true; Port = 0; Raw = ''; Detail = 'fixture default implicito' } }
  $cfgEmpty = { return @{ Ok = $true; Exists = $false; Port = 0; Detail = 'fixture sem service.json' } }
  $r7 = Ensure-PreflightConfiguredPort -ProfileDir $pd7 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getEmpty -NativeConfigOverride $cfgEmpty -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r7.Permitted) -and ([string]$r7.Detail -match 'vazio')) 'w7: marker sozinho nao autoriza (state nao-vazio bloqueia set)' ([string]$r7.Detail)

  # 8. mismatch + empty + set ok + recheck verificado + livre => permite (desired-only, sem applied).
  $pd8 = New-WTempProfileDir $base 56777
  $script:getCalls8 = 0
  $script:cfgCalls8 = 0
  $getFlap8 = { if ($script:getCalls8 -eq 0) { $script:getCalls8++; return @{ Ok = $true; Port = 0; Raw = ''; Detail = 'fixture pre-set default' } } else { return @{ Ok = $true; Port = 56777; Raw = '56777'; Detail = 'fixture pos-set 56777' } } }
  $cfgFlap8 = { if ($script:cfgCalls8 -eq 0) { $script:cfgCalls8++; return @{ Ok = $true; Exists = $false; Port = 0; Detail = 'fixture pre-set sem config' } } else { return @{ Ok = $true; Exists = $true; Port = 56777; Detail = 'fixture pos-set config 56777' } } }
  $r8 = Ensure-PreflightConfiguredPort -ProfileDir $pd8 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getFlap8 -NativeConfigOverride $cfgFlap8 -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ([bool]$r8.Permitted -and ([string]$r8.Outcome -eq 'PORT_FREE')) 'w8: mismatch+empty+set+recheck permite (desired-only)' ([string]$r8.Detail)

  # 9. desconhecido => blocker (fail-closed).
  $getUnknown = { return @{ Ok = $false; Port = 0; Raw = ''; Detail = 'fixture desconhecido' } }
  $r9 = Ensure-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getUnknown -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ((-not [bool]$r9.Permitted)) 'w9: get desconhecido => blocker' ([string]$r9.Detail)

  # 10. alias Test- chama o central (sem logica duplicada).
  $r10 = Test-PreflightConfiguredPort -ProfileDir $pd3 -ExplicitPort 56777 -TimeoutMs 15000 -ResolveOverride $resolveOk -NativeGetOverride $getOk -NativeConfigOverride $cfgOk -SetPortRunnerOverride $setOk -ListenerOverride $lisFree -ExcludedRangesOverride $noRanges
  Assert-That ([bool]$r10.Permitted) 'w10: alias Test- permite igual ao Ensure' ([string]$r10.Detail)

  # 11. wrapper gerado V2 seleciona exe exato e usa mesmo env (sem rede; BinaryOverride).
  $realExe = 'C:\Users\walis\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
  if (-not (Test-Path -LiteralPath $realExe -PathType Leaf)) {
    Write-Host '[SKIP] w11: exe exato 2.0.18 ausente neste host'
  } else {
    $profRoot11 = Join-Path $base ('profroot-' + [guid]::NewGuid().ToString('N'))
    $info11 = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $profRoot11 -RuntimeId 'opencode-v2' -BinaryOverride $realExe
    $wrap11 = [string]$info11.WrapperPath
    $pd11 = [string]$info11.ProfileDir
    Assert-That ((Test-Path -LiteralPath $wrap11 -PathType Leaf)) 'w11: wrapper V2 gerado' 'wrapper ausente'
    $libSrc = Join-Path $repoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1'
    $libDst = Join-Path $pd11 'lib\RuntimePortPreflight.ps1'
    $hashOk11 = $false
    try { $hashOk11 = ((Get-FileHash -LiteralPath $libSrc -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $libDst -Algorithm SHA256).Hash) } catch { $hashOk11 = $false }
    Assert-That ($hashOk11) 'w11: lib copiada ao perfil com hash igual' 'hash divergente'
    $hasParam11 = $false
    try { $hasParam11 = (([IO.File]::ReadAllText($wrap11, [Text.Encoding]::UTF8)) -match 'Ensure-PreflightConfiguredPort') } catch { $hasParam11 = $false }
    Assert-That ($hasParam11) 'w11: wrapper chama gate central (sem inline)' 'wrapper sem Ensure'
    $diag11 = Invoke-BoundedPs $wrap11 '--version' 15000
    Assert-That (([int]$diag11.Code -eq 0) -and ([string]$diag11.Out -match 'opencode v2\.0\.18')) 'w11: wrapper --version diagnostico exato 2.0.18' ([string]$diag11.Out)
    $block11 = Invoke-BoundedPs $wrap11 'service start' 15000
    Assert-That (([int]$block11.Code -eq 2)) 'w11: wrapper service start sem -ServicePort bloqueia exit 2' ([string]$block11.Out)
  }

  # 13. FIX1 negatives via wrapper real (sem mocks de lancamento; bounded 15s).
  # Mutadores nunca encaminhados; dest-opts recusadas; unknown/TUI bloqueado
  # com reason honesta; 49374 ocupado nunca inicia; shim .cmd resolve .exe.
  if (-not (Test-Path -LiteralPath $realExe -PathType Leaf)) {
    Write-Host '[SKIP] w13: negatives exigem exe exato 2.0.18 neste host'
  } else {
    $profRoot13 = Join-Path $base ('neg-' + [guid]::NewGuid().ToString('N'))
    $info13 = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $profRoot13 -RuntimeId 'opencode-v2' -BinaryOverride $realExe
    $wrap13 = [string]$info13.WrapperPath
    $mutStop = Invoke-BoundedPs $wrap13 'service stop' 15000
    Assert-That (([int]$mutStop.Code -eq 2) -and ([string]$mutStop.Out -match 'stop/restart fora de escopo|mutador service stop')) 'w13: service stop bruto recusado (sem wrapper->stop)' ([string]$mutStop.Out)
    $mutRestart = Invoke-BoundedPs $wrap13 'service restart' 15000
    Assert-That (([int]$mutRestart.Code -eq 2) -and ([string]$mutRestart.Out -match 'mutador service restart')) 'w13: service restart bruto recusado' ([string]$mutRestart.Out)
    $mutSet = Invoke-BoundedPs $wrap13 'service set port 56777' 15000
    Assert-That (([int]$mutSet.Code -eq 2) -and ([string]$mutSet.Out -match 'mutador service set|helper protected')) 'w13: service set bruto recusado (so helper protected)' ([string]$mutSet.Out)
    $mutStopEx = Invoke-BoundedPs $wrap13 '-ServicePort 56777 service stop' 15000
    Assert-That (([int]$mutStopEx.Code -eq 2) -and ([string]$mutStopEx.Out -match 'stop/restart fora de escopo|mutador service stop')) 'w13: -ServicePort explicito nao autoriza raw stop' ([string]$mutStopEx.Out)
    $destOpt = Invoke-BoundedPs $wrap13 'service start --port 56777' 15000
    Assert-That (([int]$destOpt.Code -eq 2) -and ([string]$destOpt.Out -match 'opt de destino recusada')) 'w13: opt destino --port recusada antes de execucao' ([string]$destOpt.Out)
    $unk = Invoke-BoundedPs $wrap13 'foobar-baz' 15000
    Assert-That (([int]$unk.Code -eq 2) -and ([string]$unk.Out -match 'desconhecido/nao suportado')) 'w13: unknown bloqueado com reason honesta' ([string]$unk.Out)
    $tui = Invoke-BoundedPs $wrap13 '' 15000
    Assert-That (([int]$tui.Code -eq 2) -and ([string]$tui.Out -match 'desconhecido/nao suportado|interativa TUI')) 'w13: TUI default bloqueado honesto (phase22 sem lifetime interativo)' ([string]$tui.Out)
    # 49374 ocupado => nunca inicia (sem mock de lancamento; override de listener).
    $pd13 = [string]$info13.ProfileDir
    $busy49374 = @{ Exists = $true; OwningPID = 999998; LocalAddress = '127.0.0.1'; Source = 'override'; Detail = 'listener 127.0.0.1:49374 PID 999998'; QuerySucceeded = $true }
    $script:setCalled49374 = $false
    $setNever = { $script:setCalled49374 = $true; return @{ Ok = $false; Output = 'set nao deveria ser chamado (fail do teste)' } }
    $r49374 = Ensure-PreflightConfiguredPort -ProfileDir $pd13 -ExplicitPort 49374 -TimeoutMs 15000 -ResolveOverride @{ Ok = $true; Exe = $realExe; Version = 'opencode v2.0.18'; Detail = 'fixture' } -NativeGetOverride { return @{ Ok = $true; Port = 49374; Raw = '49374'; Detail = 'fixture get=49374' } } -NativeConfigOverride { return @{ Ok = $true; Exists = $true; Port = 49374; Detail = 'fixture config=49374' } } -SetPortRunnerOverride $setNever -ListenerOverride $busy49374 -ExcludedRangesOverride $noRanges
    Assert-That ((-not [bool]$r49374.Permitted) -and (-not $script:setCalled49374)) 'w13: D->49374 ocupado nunca lanca/set (HOLD)' ([string]$r49374.Detail)
    # Manifest .cmd shim (provenance npm) resolve para .exe central correto.
    # Usa o shim global provisionado (npm) como input .cmd; o resolver central
    # deve selecionar o .exe exato (sem override, sem shell).
    try {
      $globalShim = 'C:\Users\walis\.opencode-orchestration\profiles\v2\runtime\node_modules\.bin\opencode.cmd'
      if ((Test-Path -LiteralPath $globalShim -PathType Leaf)) {
        $rvCmd = Resolve-PreflightNativeExe -ProfileDir $pd13 -Candidates @($globalShim) -ExpectedVersion '2.0.18' -TimeoutMs 15000
        Assert-That (([bool]$rvCmd.Ok) -and ([string]$rvCmd.Exe).ToLowerInvariant().EndsWith('.exe') -and ([string]$rvCmd.Version -match '(?m)^opencode v2\.0\.18\s*$')) 'w13: shim .cmd npm resolve .exe exato central (sem shell)' ([string]$rvCmd.Detail)
      } else {
        Write-Host '[SKIP] w13: shim .cmd global ausente neste host'
      }
    } catch {
      Assert-That $false 'w13: shim .cmd npm resolve .exe exato central (sem shell)' $_.Exception.Message
    }
    # Runner bounded real: comando hung nao settle => deadline esperado.
    $hang = Invoke-PreflightBoundedExe -File $psExe -ArgsLine '-NoProfile -Command "Start-Sleep -Seconds 25"' -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 2000
    Assert-That (([bool]$hang.TimedOut) -and (-not [bool]$hang.Finished)) 'w13: hung nao-interativo atinge deadline (BLOCKER, sem settle)' ([string]$hang.Output)
    # Junction input: path via reparse => negado, nunca executa.
    try {
      $jTarget = Join-Path $base ('jt-' + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $jTarget -Force | Out-Null
      $jLink = Join-Path $base ('jl-' + [guid]::NewGuid().ToString('N'))
      $jCreated = $false
      try { New-Item -ItemType Junction -Path $jLink -Target $jTarget -ErrorAction Stop | Out-Null; $jCreated = $true } catch { $jCreated = $false }
      if ($jCreated) {
        $jExe = Join-Path $jLink 'opencode.exe'
        $jWrap = Invoke-BoundedPs $wrap13 ('-BinaryPath "' + $jExe + '" --version') 15000
        Assert-That (([int]$jWrap.Code -ne 0)) 'w13: input via junction negado (sem execucao)' ([string]$jWrap.Out)
      } else {
        Write-Host '[SKIP] w13: junction indisponivel neste host (sem privilegio)'
      }
    } catch {
      Write-Host '[SKIP] w13: junction indisponivel neste host (excecao)'
    }
  }

  # 12. E2E nativo real via wrapper (opt-in RR_P22_RUN_NATIVE=1; timeout 15s; 49374 intacto).
  if ([string]$env:RR_P22_RUN_NATIVE -ne '1') {
    Write-Host '[SKIP] w12: E2E nativo real exige RR_P22_RUN_NATIVE=1 (default sem mutacao)'
  } else {
    $realExe2 = 'C:\Users\walis\.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
    $vr = Invoke-PreflightBoundedExe -File $realExe2 -ArgsLine '--version' -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 15000
    if ((-not [bool]$vr.Finished) -or ([int]$vr.ExitCode -ne 0) -or (-not ([string]$vr.Output -match '(?m)^opencode v2\.0\.18\s*$'))) {
      Assert-That $false 'w12: pin exato 2.0.18 responde --version' ([string]$vr.Output)
    } else {
      Assert-That $true 'w12: pin exato 2.0.18 responde --version' ''
      $profRoot12 = Join-Path $base ('e2e-' + [guid]::NewGuid().ToString('N'))
      $info12 = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $profRoot12 -RuntimeId 'opencode-v2' -BinaryOverride $realExe2
      $wrap12 = [string]$info12.WrapperPath
      $pd12 = [string]$info12.ProfileDir
      $mf12 = (([IO.File]::ReadAllText((Join-Path $pd12 'manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json)
      $cfg12 = [string]$mf12.config_root
      $lis0 = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
      $free12 = 0
      try { $lis0.Start(); $free12 = [int]$lis0.LocalEndpoint.Port } finally { try { $lis0.Stop() } catch { } }
      Assert-That (($free12 -ge 1024) -and ($free12 -ne 49374)) 'w12: porta alternativa verificada (nunca 49374)' ("porta=" + $free12)
      $info12b = New-OrchestrationProfile -RepoRoot $repoRoot -ProfileRoot $profRoot12 -RuntimeId 'opencode-v2' -BinaryOverride $realExe2 -ServicePort $free12
      $eff12 = Get-PreflightEffectiveEnv -EnvTable @{ XDG_CONFIG_HOME = $cfg12 } -ProfileDir $pd12
      $pre12 = Invoke-PreflightPort -Port $free12 -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($realExe2) -ExpectedProfileDir $pd12
      if (([string]$pre12.Outcome -ne 'PORT_FREE') -or (-not [bool]$pre12.ShouldStart)) {
        Assert-That $false 'w12: porta alternativa livre antes do start' ([string]$pre12.Outcome)
      } else {
        Assert-That $true 'w12: porta alternativa livre antes do start' ''
        # RR-P22-WRAPPER-FIX2: unsettled=true ANTES da tentativa de startup;
        # false SOMENTE com settlement provado (stopped+sem listener+query
        # ok). Excecao/ownership desconhecida preserva a base (sem delete).
        $script:unsettled = $true
        $script:unsettledDetail = ('w12 pending: porta=' + $free12 + ' perfil=' + $pd12)
        $script:evidenceKeep = (Join-Path $pd12 'e2e-unsettled.json')
        $st12 = Invoke-BoundedPs $wrap12 ('-ServicePort ' + $free12 + ' service start') 15000
        Assert-That (([int]$st12.Code -eq 0)) 'w12: wrapper service start permitido (configuration-verified+free)' ([string]$st12.Out)
        Start-Sleep -Milliseconds 1500
        $status12 = Invoke-PreflightBoundedExe -File $realExe2 -ArgsLine 'service status' -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $eff12 -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs 15000
        $epOk12 = $false
        try { $epOk12 = Test-PreflightExactEndpoint -Detail ([string]$status12.Output) -Port $free12 } catch { $epOk12 = $false }
        Assert-That (([int]$status12.ExitCode -eq 0) -and $epOk12) 'w12: service status com endpoint exato' ([string]$status12.Output)
        $lis12 = Get-PreflightListener -Port $free12
        $owned12 = $false
        $ownerPid12 = 0
        try { $ownerPid12 = [int]$lis12.OwningPID } catch { $ownerPid12 = 0 }
        if ((Get-PreflightListenerQueryOk -Listener $lis12) -and [bool]$lis12.Exists -and ($ownerPid12 -gt 0)) {
          $pi12 = Get-PreflightProcessIdentity -OwnerPID $ownerPid12
          $owned12 = (Test-PreflightOwnershipProven -Process $pi12 -ExpectedBinaryPaths @($realExe2) -ExpectedProfileDir $pd12)
        }
        Assert-That ($owned12) 'w12: listener owned pelo exe exato do perfil' ([string]$lis12.Detail)
        if ($owned12) {
          # Cleanup E2E pelo harness com prova de ownership DIRETA (nunca via
          # wrapper: wrapper recusa service stop; stop aqui e bounded 15s).
          $stop12 = Invoke-PreflightBoundedExe -File $realExe2 -ArgsLine 'service stop' -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $eff12 -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs 15000
          Assert-That (([int]$stop12.ExitCode -eq 0)) 'w12: service stop owned' ([string]$stop12.Output)
          Start-Sleep -Milliseconds 1500
          $post12 = Invoke-PreflightBoundedExe -File $realExe2 -ArgsLine 'service status' -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $eff12 -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs 15000
          $lisPost12 = Get-PreflightListener -Port $free12
          $settled12 = (([string]$post12.Output -match 'stopped') -and (-not [bool]$lisPost12.Exists) -and (Get-PreflightListenerQueryOk -Listener $lisPost12))
          Assert-That ($settled12) 'w12: settlement pos-stop (stopped+sem listener)' ([string]$post12.Output)
          if ($settled12) {
            $script:unsettled = $false
            $script:unsettledDetail = ''
            $script:evidenceKeep = ''
          } else {
            $script:unsettled = $true
            $script:unsettledDetail = ('w12 unsettled: porta=' + $free12 + ' perfil=' + $pd12)
            $script:evidenceKeep = (Join-Path $pd12 'e2e-unsettled.json')
            try {
              $ev = [ordered]@{ date = ((Get-Date).ToString('o')); port = $free12; profile_dir = $pd12; status_output = ([string]$post12.Output).Substring(0, [Math]::Min(2000, ([string]$post12.Output).Length)); listener = $lisPost12; note = 'runtime unsettled: temp perfil PRESERVADO para cleanup manual; nao deletar.' }
              [IO.File]::WriteAllText($script:evidenceKeep, ((($ev | ConvertTo-Json -Depth 8).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))
            } catch { }
          }
        } else {
          # Ownership desconhecida/excecao: preserva a base (unsettled segue
          # true desde antes do start; sem delete, sem claim).
          $script:unsettled = $true
          $script:unsettledDetail = ('w12 ownership desconhecida: porta=' + $free12 + ' perfil=' + $pd12 + ' (base preservada)')
          Assert-That $false 'w12: service stop owned (sem ownership, sem stop)' 'ownership nao provada; stop omitido'
        }
      }
    }
  }

  # w12b. invariante do cleanup do harness (independente; sem simular
  # unknown live): unsettled=true (setado ANTES do start) preserva a base;
  # false SOMENTE com settlement provado. Nenhum delete e feito aqui.
  $invBaseKept = ([bool]$script:unsettled -and (Test-Path -LiteralPath $base -PathType Container))
  $invSettledClean = $true
  if ([string]$env:RR_P22_RUN_NATIVE -ne '1') {
    $invSettledClean = (-not [bool]$script:unsettled)
  }
  Assert-That (($invBaseKept -or $invSettledClean)) 'w12b: invariante cleanup (unsettled preserva base; settled libera)' ('unsettled=' + [string]$script:unsettled)

  # w14. FIX2: exe EXISTENTE via junction => resolver recusa SEM processo
  # (zero invocacoes provado). .exe sintetico compilado C# (--version grava
  # canary + marker de ausencia); canary pre-existe; alias junction aponta
  # para o dir do exe; resolver com candidato via alias deve recusar e NAO
  # tocar canary/marker. Sem privilegio/compilador => SKIP honesto.
  $w14dir = Join-Path $base ('w14-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $w14dir -Force | Out-Null
  $w14canary = Join-Path $w14dir 'canary-count.txt'
  $w14absence = Join-Path $w14dir 'probe-invoked.marker'
  [IO.File]::WriteAllText($w14canary, "0`n", (New-Object Text.UTF8Encoding $false))
  if (Test-Path -LiteralPath $w14absence) { Remove-Item -LiteralPath $w14absence -Force -ErrorAction SilentlyContinue }
  $w14target = Join-Path $w14dir 'target'
  New-Item -ItemType Directory -Path $w14target -Force | Out-Null
  $w14cs = @'
using System;
using System.IO;
public static class W14Probe {
  public static int Main(string[] args) {
    try { File.AppendAllText("CANARYPH", "invoked\n"); } catch { }
    try { File.WriteAllText("ABSENCEPH", "invoked"); } catch { }
    foreach (string a in args) {
      if (a == "--version") { Console.WriteLine("opencode v2.0.18"); return 0; }
    }
    Console.WriteLine("opencode v2.0.18");
    return 0;
  }
}
'@
  $w14cs = $w14cs.Replace('CANARYPH', $w14canary.Replace('\', '\\'))
  $w14cs = $w14cs.Replace('ABSENCEPH', $w14absence.Replace('\', '\\'))
  $w14exe = Join-Path $w14target 'w14probe.exe'
  $w14compiled = $false
  try {
    Add-Type -TypeDefinition $w14cs -OutputAssembly $w14exe -OutputType ConsoleApplication -ErrorAction Stop
    $w14compiled = (Test-Path -LiteralPath $w14exe -PathType Leaf)
  }
  catch { $w14compiled = $false }
  if (-not $w14compiled) {
    Write-Host '[SKIP] w14: compilador C# indisponivel (sem claim de zero-invocacao)'
    Assert-That $true 'SKIP w14 (sem csc; sem claim)' 'skip honesto'
  } else {
    $w14link = Join-Path $w14dir 'alias-link'
    $w14linkMade = $false
    try { New-Item -ItemType Junction -Path $w14link -Target $w14target -ErrorAction Stop | Out-Null; $w14linkMade = $true } catch { $w14linkMade = $false }
    if (-not $w14linkMade) {
      Write-Host '[SKIP] w14: junction indisponivel (sem privilegio; sem claim)'
      Assert-That $true 'SKIP w14 junction (sem privilegio; sem claim)' 'skip honesto'
    } else {
      $w14pd = New-WTempProfileDir $base 56799
      $w14aliasExe = Join-Path $w14link 'w14probe.exe'
      $canBefore = ''
      try { $canBefore = [IO.File]::ReadAllText($w14canary, [Text.Encoding]::UTF8) } catch { $canBefore = '' }
      $rv14 = $null
      try { $rv14 = Resolve-PreflightNativeExe -ProfileDir $w14pd -Candidates @($w14aliasExe) -ExpectedVersion '2.0.18' -TimeoutMs 15000 } catch { $rv14 = $null }
      Assert-That ((($null -ne $rv14) -and (-not [bool]$rv14.Ok))) 'w14: resolver recusa exe via junction (sem processo)' 'resolveu indevido'
      $canAfter = ''
      try { $canAfter = [IO.File]::ReadAllText($w14canary, [Text.Encoding]::UTF8) } catch { $canAfter = '' }
      Assert-That (($canAfter -eq $canBefore)) 'w14: canary intacto (zero invocacoes; probe NAO executado)' ('before=[' + $canBefore + '] after=[' + $canAfter + ']')
      Assert-That (-not (Test-Path -LiteralPath $w14absence -PathType Leaf)) 'w14: marker de ausencia intacto (prova independente de nao-execucao)' $w14absence
      Remove-TestReparse $w14link
    }
  }
}
finally {
  if ([bool]$script:unsettled) {
    Write-Host ('[HOLD] runtime unsettled: temp perfil PRESERVADO em ' + $base + ' (' + [string]$script:unsettledDetail + '); evidence: ' + [string]$script:evidenceKeep)
  } elseif (Test-Path -LiteralPath $base) {
    # Sweep junction-safe ANTES da remocao recursiva: deleta cada reparse point
    # encontrado sob a base sem seguir o alvo (a deletao recursiva de uma arvore
    # com junctions e o caminho classico de travessia de alvo). Um reparse point
    # remanescente de um teste que nao chegou a limpar tb cai aqui.
    $wLinks = @()
    try { $wLinks = @(Get-ChildItem -LiteralPath $base -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue) } catch { $wLinks = @() }
    foreach ($wLink in $wLinks) { Remove-TestReparse $wLink.FullName }
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Write-Host ("PASS: " + $passed + " / TOTAL: " + $total)
if ($passed -ne $total) { exit 1 } else { exit 0 }
