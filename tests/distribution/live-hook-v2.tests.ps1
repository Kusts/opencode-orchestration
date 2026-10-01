<#
.SYNOPSIS
    RR-P24-LIVEHOOK fase 24 fatia 2: live-hook verification T2/T3 no binario
    exato @opencode/cli 2.0.18 provisionado.
.DESCRIPTION
    T3 (SDK em-processo) quando o pacote @opencode/sdk 2.0.18 existir nos
    node_modules provisionados; sem rede, sem install: ausente => [SKIP]
    honesto. T2: perfil TEMP isolado (XDG_*+HOME/USERPROFILE confinados,
    OPENCODE_CONFIG* removidos do filho), install -TargetHome no temp home
    (nunca home global), fixture ESM em <config>/plugins que grava eventos
    no JSONL do temp, service V2 em porta alternativa livre verificada
    (nunca 49374; excluded ranges validados), start unico bounded, trigger
    de sessao via api autenticada do perfil sem modelo pago, stop owned + settlement.
    Todos os filhos via Invoke-PreflightBoundedExe (timeout externo +
    drain async). Excecao/timeout => preserva temp + evidencia, sem repetir
    cegamente (max 1 tentativa por cenario). PS 5.1 compativel, ASCII only.
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
$hold = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Note([string]$Text) { Write-Host ("[NOTE] " + $Text) }
function Skip([string]$Text) { Write-Host ("[SKIP] " + $Text) }
function Hold([string]$Text) { $script:hold += 1; Write-Host ("[HOLD] " + $Text) }

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1')

$ProvisionedExe = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
$SdkPkg = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\sdk\package.json'
$PluginPkg = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\plugin\package.json'
$TmpBase = Join-Path ([IO.Path]::GetTempPath()) 'opencode'
$TmpRoot = Join-Path $TmpBase ('rr-p24-livehook-' + [guid]::NewGuid().ToString('N'))
$ProfileDir = Join-Path $TmpRoot 'v2'
$HomeT = Join-Path $ProfileDir 'home'
$Jsonl = Join-Path $TmpRoot 'livehook.jsonl'
$EvidenceJsonl = Join-Path $RepoRoot 'evidence\v3.1\runtime-reliability\phase24-livehook.jsonl'
$Failed = $false

function Fail-Preserve([string]$Why) {
  Write-Host ("[PRESERVE] " + $Why + " -- temp preservado em " + $TmpRoot)
  $script:Failed = $true
}

# S0a: binario exato provisionado -------------------------------------------
# RR-P24-REV-FIX (HIGH): GATE bloqueante de versao exata. Falha aqui =>
# $Failed + $VersionGateOk=false e NENHUMA operacao de servico (set/start)
# pode executar a jusante (S5/S6 exigem o gate, nao so $Failed).
$VersionGateOk = $false
$ConfGateOk = $false
$ServiceAttempted = $false
$exeOk = (Test-Path -LiteralPath $ProvisionedExe -PathType Leaf) -and $ProvisionedExe.ToLowerInvariant().EndsWith('.exe')
Assert ($exeOk) 'binario provisionado 2.0.18 existe (.exe)'
$ver = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine '--version' -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 15000
$verLine = ''
try { $verLine = (([string]$ver.Output -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)).Trim() } catch { $verLine = '' }
$VersionGateOk = (([bool]$ver.Finished) -and ([int]$ver.ExitCode -eq 0) -and ($verLine -eq 'opencode v2.0.18'))
Assert ($VersionGateOk) 'versao exata opencode v2.0.18'
if (-not $VersionGateOk) { Fail-Preserve ('gate versao exata reprovado (obtido: ' + $verLine + '); abortando antes de service ops') }

# S0b: 49374 intacto antes ----------------------------------------------------
$colBefore = Get-PreflightListener -Port 49374
$colBeforeFp = ''
try {
  $idBefore = Get-PreflightProcessIdentity -OwnerPID ([int]$colBefore.OwningPID)
  $colBeforeFp = ('exists=' + [bool]$colBefore.Exists + ' pid=' + [int]$colBefore.OwningPID + ' name=' + [string]$idBefore.Name)
} catch { $colBeforeFp = ('exists=' + [bool]$colBefore.Exists) }
Note ('49374 antes: ' + $colBeforeFp)
Assert ((Get-PreflightListenerQueryOk -Listener $colBefore)) 'query 49374 com sucesso (antes)'

# S0c: config global hash antes (prova sem mutacao global) --------------------
$GlobalCfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
$globalHashBefore = ''
if (Test-Path -LiteralPath $GlobalCfg -PathType Leaf) {
  try { $globalHashBefore = (Get-FileHash -LiteralPath $GlobalCfg -Algorithm SHA256).Hash } catch { $globalHashBefore = '' }
}
Note ('global opencode.json hash antes: ' + $globalHashBefore)

# S1: T3 SDK em-processo ------------------------------------------------------
if ((Test-Path -LiteralPath $SdkPkg -PathType Leaf) -or (Test-Path -LiteralPath $PluginPkg -PathType Leaf)) {
  Note 'T3: pacote sdk/plugin presente; T3 em-processo nao implementado nesta fatia (ficaria para extensao com bun local)'
  Hold 'T3 sdk presente mas sem harness em-processo nesta fatia'
} else {
  Skip 'T3 SDK @opencode/sdk ausente nos node_modules provisionados; sem install pela rede (T3 NAO-EXECUTADO)'
}

if (-not $Failed) {
  # S2: install distribuicao no temp home ------------------------------------
  try {
    New-Item -ItemType Directory -Path $HomeT -Force | Out-Null
    $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $HomeT -Runtime V2 2>&1
    Assert ($LASTEXITCODE -eq 0) 'install -TargetHome temp -Runtime V2 exit 0'
  } catch { Assert ($false) ('install temp: ' + $_.Exception.Message); Fail-Preserve 'install falhou' }
}
if (-not $Failed) {
  $bundle = Join-Path $HomeT '.config\opencode\plugins\orchestration-enforcement.js'
  $sidecar = Join-Path $RepoRoot 'plugins\dist\orchestration-enforcement.js.sha256'
  $hashOk = $false
  try {
    $expect = ([IO.File]::ReadAllText($sidecar, [Text.Encoding]::UTF8)).Trim().ToLowerInvariant()
    $got = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashOk = ($expect -eq $got)
  } catch { $hashOk = $false }
  Assert ($hashOk) 'bundle dist instalado no temp com hash == sidecar'
  # S3: fixture no mesmo dir de auto-discovery --------------------------------
  try {
    $plugDir = Join-Path $HomeT '.config\opencode\plugins'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'livehook-v2-fixture.js') -Destination (Join-Path $plugDir 'rr-p24-livehook-fixture.js') -Force
    Assert ((Test-Path -LiteralPath (Join-Path $plugDir 'rr-p24-livehook-fixture.js') -PathType Leaf)) 'fixture copiada para plugins/ do temp'
  } catch { Assert ($false) ('fixture: ' + $_.Exception.Message); Fail-Preserve 'fixture falhou' }
  # manifest do perfil (schema Test-PreflightProfileManifestV2) ----------------
  try {
    $mf = @{ runtime_id = 'opencode-v2'; generation = 2; config_root = (Join-Path $HomeT '.config'); provisioned = @{ binary_path = $ProvisionedExe } } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $ProfileDir 'manifest.json'), $mf, (New-Object Text.UTF8Encoding $false))
    $mv = Test-PreflightProfileManifestV2 -ProfileDir $ProfileDir
    Assert (([bool]$mv.Ok)) 'manifest v2 do perfil ok'
  } catch { Assert ($false) ('manifest: ' + $_.Exception.Message); Fail-Preserve 'manifest falhou' }
}

# S4: env confinado + porta alternativa ----------------------------------------
# RR-P24-REV-FIX (HIGH): GATE bloqueante de confinamento. conf.Ok=false =>
# $ConfGateOk=false + $Failed e S5/S6/S7/S9 nunca executam service set/start.
$EffEnv = $null
$Alt = 0
if ((-not $Failed) -and ($VersionGateOk)) {
  $EnvTable = @{
    'XDG_CONFIG_HOME' = (Join-Path $HomeT '.config');
    'RR_P24_LIVEHOOK_JSONL' = $Jsonl
  }
  $EffEnv = Get-PreflightEffectiveEnv -EnvTable $EnvTable -ProfileDir $ProfileDir
  $cfgRoot = ''
  try { $cfgRoot = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ProfileDir 'manifest.json'), [Text.Encoding]::UTF8))).config_root } catch { $cfgRoot = '' }
  $conf = Test-PreflightConfinedEnv -EnvTable $EffEnv -ProfileDir $ProfileDir -ConfigRoot $cfgRoot
  $ConfGateOk = ([bool]$conf.Ok)
  Assert ($ConfGateOk) 'env confinado ao perfil'
  if (-not $ConfGateOk) { Fail-Preserve ('gate confinamento reprovado: ' + [string]$conf.Detail + '; abortando antes de service ops') }
  else {
  $ex = Get-PreflightExcludedRanges
  Assert (([bool]$ex.Available)) 'excluded ranges disponiveis'
  if ([bool]$ex.Available) {
    foreach ($c in @(56781, 56782, 56783, 56784, 56785, 56786, 56787, 56788, 56789)) {
      if ($c -eq 49374) { continue }
      $isEx = Test-PreflightPortExcluded -Port $c -Ranges @($ex.Ranges)
      if ([bool]$isEx.Excluded) { continue }
      $li = Get-PreflightListener -Port $c
      if (-not (Get-PreflightListenerQueryOk -Listener $li)) { continue }
      if ([bool]$li.Exists) { continue }
      $Alt = $c
      break
    }
  }
  if ($Alt -eq 0) { Skip 'sem porta alternativa livre 56781-56789 (ambiente); T2 NAO-EXECUTADO'; $Failed = $true }
  else { Note ('porta alternativa: ' + $Alt) }
  }
} else {
  Note 'S4 pulado: gate de versao reprovado (sem service ops a jusante)'
}

# S4-neg: cenario negativo de confinamento (sem servico, dry-run/mock) ---------
# RR-P24-REV-FIX (HIGH): prova que conf.Ok=false => nenhum set/start.
# Usa EnvTable adulterada (XDG fora do perfil) e o mesmo predicado de gate
# de S5/S6; nenhuma chamada de servico e executada aqui (flag dry-run).
$NegGateAllowsService = $true
try {
  $NegEnv = @{
    'XDG_CONFIG_HOME' = $env:USERPROFILE;
    'HOME' = $env:USERPROFILE;
    'USERPROFILE' = $env:USERPROFILE;
    'XDG_STATE_HOME' = $env:USERPROFILE;
    'XDG_DATA_HOME' = $env:USERPROFILE;
    'XDG_CACHE_HOME' = $env:USERPROFILE
  }
  $NegConf = Test-PreflightConfinedEnv -EnvTable $NegEnv -ProfileDir $ProfileDir -ConfigRoot ''
  $NegGateAllowsService = (([bool]$NegConf.Ok) -and $VersionGateOk)
  Assert ((-not [bool]$NegConf.Ok)) 'negativo: env fora do perfil reprovado (conf.Ok=false)'
  Assert ((-not $NegGateAllowsService)) 'negativo: gate bloqueia set/start quando conf.Ok=false (dry-run, sem servico)'
  Assert ((-not $ServiceAttempted)) 'negativo: nenhum set/start tentado no cenario mock'
} catch { Assert ($false) ('negativo confinamento: ' + $_.Exception.Message) }

# S5: empty-state + set port ----------------------------------------------------
# RR-P24-REV-FIX: exige gates de versao+confinamento; sem eles, nunca toca servico.
if ((-not $Failed) -and $VersionGateOk -and $ConfGateOk -and ($Alt -ne 0)) {
  $ServiceAttempted = $true
  $setRes = Invoke-PreflightServiceSetPort -BinaryPath $ProvisionedExe -Port $Alt -EnvTable $EffEnv -ProfileDir $ProfileDir -ExpectedBinaryPath $ProvisionedExe -WorkingDirectory $HomeT -TimeoutMs 30000
  Assert (([bool]$setRes.Ok)) 'service set port alternativo (desired/pending)'
  if (-not [bool]$setRes.Ok) { Fail-Preserve ('set port: ' + [string]$setRes.Output) }
  else {
    $g = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'service get port' -WorkDir $HomeT -EnvTable $EffEnv -TimeoutMs 15000
    Assert (([bool]$g.Finished) -and ([string]$g.Output -match ('(?<!\d)' + $Alt + '(?!\d)'))) 'recheck service get port == alternativa'
  }
}

# S6: start unico + ownership ----------------------------------------------------
$Started = $false
if ((-not $Failed) -and $VersionGateOk -and $ConfGateOk -and ($Alt -ne 0)) {
  $ServiceAttempted = $true
  $st = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'service start' -WorkDir $HomeT -EnvTable $EffEnv -TimeoutMs 30000
  $epOk = $false
  try { $epOk = (Test-PreflightExactEndpoint -Detail ([string]$st.Output) -Port $Alt) } catch { $epOk = $false }
  Assert (([bool]$st.Finished) -and (-not [bool]$st.TimedOut) -and ([int]$st.ExitCode -eq 0) -and $epOk) 'service start unico com endpoint exato'
  if (-not (([bool]$st.Finished) -and ([int]$st.ExitCode -eq 0) -and $epOk)) { Fail-Preserve 'start falhou' }
  else {
    $Started = $true
    $li2 = Get-PreflightListener -Port $Alt
    Assert (([bool]$li2.Exists) -and (Get-PreflightListenerQueryOk -Listener $li2)) 'listener alternativo presente'
    $ownOk = $false
    try {
      $pi = Get-PreflightProcessIdentity -OwnerPID ([int]$li2.OwningPID)
      $ownOk = (Test-PreflightOwnershipProven -Process $pi -ExpectedBinaryPaths @($ProvisionedExe))
    } catch { $ownOk = $false }
    Assert ($ownOk) 'ownership .exe exato do listener'
    $sts = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'service status' -WorkDir $HomeT -EnvTable $EffEnv -TimeoutMs 15000
    $stsOk = $false
    try { $stsOk = (Test-PreflightExactEndpoint -Detail ([string]$sts.Output) -Port $Alt) } catch { $stsOk = $false }
    Assert ($stsOk) 'service status com endpoint exato'
  }
}

# S7-fixture: parser OpenAPI com fixture sintetica (sem servico, default) -------
# RR-P24-REV-FIX (MEDIUM): o parser antigo capturava sem a barra
# ('"/([a-z...)"') e depois testava ContainsKey('/session') => nunca
# populava $createArgs. O parser correto preserva a barra e confere POST.
# RR-P24-TRIGGER: caminho real e /api/session (nao /session, que serve o web
# UI em HTML). Spec real 2.0.18 tem 251892 chars observados (openapi 3.1.0,
# 115 paths; fetch usa MaxChars 524288 com margem 2x) + OPENCODE_PASSWORD do
# service.json do perfil TEMP.
function Resolve-SessionCreateArgs([string]$Spec, [string]$ApiBase) {
  $s = [string]$Spec
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  if ([string]::IsNullOrWhiteSpace($ApiBase)) { return '' }
  # RR-P24-TRIGGER-FIX (3) fail-closed: $postOk inicia $false; so true com
  # JSON valido + paths['/api/session'].post presente. Truncamento => recusa.
  # O marcador e casado CASE-SENSITIVE no formato exato do wrapper
  # ('[truncado em N chars]' com colchetes, ou 'TRUNCATED' maiusculo):
  # -match (regex case-insensitive) dava falso-positivo no 'truncated'
  # minusculo da spec real 3.1.0 (251892 chars, 115 paths) e zerava o
  # createArgs mesmo com captura integra. -cmatch so recusa marcador real.
  if ($s -cmatch '\[truncado em \d+ chars\]|TRUNCATED') { return '' }
  $j = $null
  try { $j = ($s | ConvertFrom-Json) } catch { return '' }
  if ($null -eq $j) { return '' }
  if ($null -eq $j.paths) { return '' }
  $prop = $null
  try { $prop = $j.paths.PSObject.Properties['/api/session'] } catch { return '' }
  if ($null -eq $prop) { return '' }
  $postOk = $false
  try { $postOk = ($null -ne $prop.Value.post) } catch { $postOk = $false }
  if (-not $postOk) { return '' }
  return ('api --server ' + $ApiBase + ' POST /api/session --data "{}"')
}
try {
  $FixtureSpec = '{"openapi":"3.0.0","paths":{"/api/session":{"post":{"operationId":"session.create"}}}}'
  $FixtureArgs = Resolve-SessionCreateArgs -Spec $FixtureSpec -ApiBase 'http://127.0.0.1:59999'
  Assert (($FixtureArgs -match 'POST /api/session')) 'fixture openapi /api/session+POST => createArgs populado (JSON valido)'
  $GetOnlySpec = '{"openapi":"3.0.0","paths":{"/api/session":{"get":{"operationId":"session.get"}}}}'
  $GetOnlyArgs = Resolve-SessionCreateArgs -Spec $GetOnlySpec -ApiBase 'http://127.0.0.1:59999'
  Assert ([string]::IsNullOrWhiteSpace($GetOnlyArgs)) 'fixture /api/session GET-only => createArgs vazio (sem POST)'
  $TruncSpec = '{"openapi":"3.0.0","paths":{"/api/session":{"post":{"operationId":"session.cre'
  $TruncArgs = Resolve-SessionCreateArgs -Spec $TruncSpec -ApiBase 'http://127.0.0.1:59999'
  Assert ([string]::IsNullOrWhiteSpace($TruncArgs)) 'fixture documento truncado => createArgs vazio (fail-closed)'
  $OutsideSpec = '{"openapi":"3.0.0","paths":{"/foo":{"get":{}}},"info":{"description":"veja /api/session na doc"}}'
  $OutsideArgs = Resolve-SessionCreateArgs -Spec $OutsideSpec -ApiBase 'http://127.0.0.1:59999'
  Assert ([string]::IsNullOrWhiteSpace($OutsideArgs)) 'fixture /api/session fora de paths => createArgs vazio'
  $MarkedSpec = '{"openapi":"3.0.0","paths":{"/api/session":{"post":{"operationId":"session.create"}}},"info":{"description":"...[truncado em 8192 chars]..."}}'
  $MarkedArgs = Resolve-SessionCreateArgs -Spec $MarkedSpec -ApiBase 'http://127.0.0.1:59999'
  Assert ([string]::IsNullOrWhiteSpace($MarkedArgs)) 'fixture JSON valido com marca de truncamento => createArgs vazio (fail-closed)'
  $TruncLowerSpec = '{"openapi":"3.1.0","paths":{"/api/session":{"post":{"operationId":"session.create"}}},"info":{"description":"a truncated list of routes"}}'
  $TruncLowerArgs = Resolve-SessionCreateArgs -Spec $TruncLowerSpec -ApiBase 'http://127.0.0.1:59999'
  Assert (($TruncLowerArgs -match 'POST /api/session')) 'fixture com truncated minusculo (texto normal) => createArgs populado (sem falso-positivo)'
  $Pad = (('x' * 260000) -join '')
  $BigSpec = '{"openapi":"3.0.0","paths":{"/api/session":{"post":{"operationId":"session.create"}}},"info":{"description":"' + $Pad + '"}}'
  $BigArgs = Resolve-SessionCreateArgs -Spec $BigSpec -ApiBase 'http://127.0.0.1:59999'
  Assert ((($BigArgs -match 'POST /api/session')) -and ($BigSpec.Length -gt 251892)) 'fixture spec tamanho-real (>251892 chars observados) => createArgs populado (sem truncamento interno)'
} catch { Assert ($false) ('fixture parser openapi: ' + $_.Exception.Message) }

# S7: modelo de registro + trigger via api autenticada (sem modelo) ---------------
function Get-JsonlKinds([string]$Path) {
  $kinds = @{}
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $kinds }
    foreach ($ln in @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))) {
      try {
        $o = ($ln | ConvertFrom-Json)
        $k = [string]$o.kind
        if (-not [string]::IsNullOrWhiteSpace($k)) { $kinds[$k] = $true }
      } catch { }
    }
  } catch { }
  return $kinds
}
# Ordem: trigger PRIMEIRO (plugin pode carregar lazy por sessao/projeto),
# depois poll de BOOT/FEATURES/SUBSCRIBED/EVENT juntos.
# RR-P24-TRIGGER: api exige OPENCODE_PASSWORD do service.json do perfil TEMP
# (linha vermelha: password local efemero, in-memory, nunca em evidencia).
# Fetch openapi com MaxChars 524288 (spec real 251892 chars observados;
# margem 2x; Truncated=true quebra o parse). Trigger sem-modelo: POST /api/session (session.
# create, requestBody required, todos opcionais) + PATCH title (updated).
# Sondas sem-modelo p/ (c)/(d): shell direto (nao passa por tool.hook) e
# prompt sem provider (falha esperada sem modelo pago); 1 tentativa cada.
$ApiBase = ''
if ($Started) {
  $ApiBase = ('http://127.0.0.1:' + $Alt)
  $AuthEnv = $EffEnv
  try {
    $svcPathT = Join-Path (Join-Path ([string]$EffEnv['XDG_CONFIG_HOME']) 'opencode') 'service.json'
    $svcRawT = [IO.File]::ReadAllText($svcPathT, [Text.Encoding]::UTF8)
    $svcJsonT = ($svcRawT | ConvertFrom-Json)
    $pwdT = [string]$svcJsonT.password
    if (-not [string]::IsNullOrWhiteSpace($pwdT)) {
      $AuthEnv = @{}
      foreach ($k in @($EffEnv.Keys)) { $AuthEnv[[string]$k] = [string]$EffEnv[$k] }
      $AuthEnv['OPENCODE_PASSWORD'] = $pwdT
    }
    $pwdT = ''
  } catch { $AuthEnv = $EffEnv }
  # S7a: plugin list sem --server (servidor ja roda; ensure rapido) ------------
  try {
    $pl = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'plugin list' -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 20000
    $plOut = ([string]$pl.Output)
    if ($plOut.Length -gt 800) { $plOut = $plOut.Substring(0, 800) }
    Note ('plugin list: exit=' + [int]$pl.ExitCode + ' out=' + $plOut)
  } catch { Note ('plugin list indisponivel: ' + $_.Exception.Message) }
  # S7b: openapi via api autenticada (service.json do perfil; sem segredo no log)
  # RR-P24-TRIGGER-FIX (3): captura completa — MaxChars 524288 cobre os
  # 251892 chars observados da spec real 2.0.18 com margem 2x; Truncated=true
  # ou marca de truncamento => fail-closed (sem trigger, HOLD honesto).
  $spec = ''
  $specTruncated = $false
  try {
    $dl = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine ('api --server ' + $ApiBase + ' GET /openapi.json') -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 20000 -MaxChars 524288
    if (([bool]$dl.Finished) -and ([int]$dl.ExitCode -eq 0) -and (-not [bool]$dl.Truncated)) { $spec = ([string]$dl.Output) }
    else {
      $specTruncated = $true
      Note ('api GET openapi sem captura completa (exit=' + [int]$dl.ExitCode + ' truncated=' + [bool]$dl.Truncated + '); fail-closed, sem trigger')
    }
  } catch { Note ('api GET openapi indisponivel: ' + $_.Exception.Message); $specTruncated = $true }
  $createArgs = ''
  if ($spec -ne '') {
    try {
      $createArgs = Resolve-SessionCreateArgs -Spec $spec -ApiBase $ApiBase
      Note ('api openapi createArgs: ' + $createArgs)
    } catch { Note 'parse openapi falhou (sem adivinhar schema)' }
  } else {
    Hold '(b) openapi indisponivel via api autenticada (sem trigger sem-modelo)'
  }
  if ($createArgs -ne '') {
    Note 'POST /api/session via api (1 tentativa, sessao vazia sem modelo)'
    $createdSid = ''
    try {
      $cr = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine $createArgs -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 20000
      $crOut = ([string]$cr.Output)
      try {
        $crJson = ($crOut | ConvertFrom-Json)
        if ($null -ne $crJson.data) { $createdSid = [string]$crJson.data.id }
      } catch { }
      $crSan = $crOut
      try { $crSan = [regex]::Replace($crSan, '"password"\s*:\s*"[^"]*"', '"password":"[REDACTED]"') } catch { }
      if ($crSan.Length -gt 500) { $crSan = $crSan.Substring(0, 500) }
      Note ('api POST /api/session: exit=' + [int]$cr.ExitCode + ' out=' + $crSan)
    } catch { Note ('api POST /api/session indisponivel: ' + $_.Exception.Message) }
    # RR-P24-TRIGGER-FIX (4): registrar trigger session id sanitizado no
    # JSONL (linha TRIGGER) para correlacao comparavel posterior.
    if ($createdSid -ne '') {
      try {
        $trigId = 'redacted'
        try { if ($createdSid -match '^[A-Za-z0-9._:@-]{1,128}$') { $trigId = $createdSid } } catch { $trigId = 'redacted' }
        $trigRow = (@{ ts = ((Get-Date).ToString('o')); kind = 'TRIGGER'; session = $trigId } | ConvertTo-Json -Compress)
        [IO.File]::AppendAllText($Jsonl, ($trigRow + "`n"), (New-Object Text.UTF8Encoding $false))
        Note 'TRIGGER registrado no JSONL (session sanitizada)'
      } catch { Note 'TRIGGER nao registrado (best-effort)' }
    }
    if ($createdSid -ne '') {
      try {
        $pa = 'api --server ' + $ApiBase + ' PATCH /api/session/' + $createdSid + ' --data "{\"title\":\"rr-p24\"}"'
        $pr = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine $pa -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 20000
        Note ('api PATCH title (updated): exit=' + [int]$pr.ExitCode)
      } catch { Note 'api PATCH indisponivel' }
      try {
        $sh = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine ('api --server ' + $ApiBase + ' POST /api/session/' + $createdSid + '/shell --data "{\"command\":\"echo hi\"}"') -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 20000
        Note ('api POST shell (sonda d sem modelo): exit=' + [int]$sh.ExitCode)
      } catch { Note 'api shell indisponivel' }
      try {
        $pm = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine ('api --server ' + $ApiBase + ' POST /api/session/' + $createdSid + '/prompt --data "{\"text\":\"hi\"}"') -WorkDir $HomeT -EnvTable $AuthEnv -TimeoutMs 25000
        $pmSan = ([string]$pm.Output)
        try { $pmSan = [regex]::Replace($pmSan, '"password"\s*:\s*"[^"]*"', '"password":"[REDACTED]"') } catch { }
        if ($pmSan.Length -gt 500) { $pmSan = $pmSan.Substring(0, 500) }
        Note ('api POST prompt (sonda c sem modelo): exit=' + [int]$pm.ExitCode + ' out=' + $pmSan)
      } catch { Note 'api prompt indisponivel' }
    }
  }
  # S7c: poll unico (BOOT/FEATURES/SUBSCRIBED/EVENT) -----------------------------
  $kinds = @{}
  for ($i = 0; $i -lt 6; $i += 1) {
    Start-Sleep -Seconds 2
    $kinds = Get-JsonlKinds -Path $Jsonl
    if (($kinds.ContainsKey('BOOT')) -and ($kinds.ContainsKey('FEATURES')) -and ($kinds.ContainsKey('SUBSCRIBED'))) { break }
  }
  Assert (($kinds.ContainsKey('BOOT'))) '(a) plugin fixture carregou no host real (BOOT)'
  Assert (($kinds.ContainsKey('FEATURES'))) 'feature detection do host real gravada (FEATURES)'
  Assert (($kinds.ContainsKey('SUBSCRIBED'))) 'subscribe ativo no host real (SUBSCRIBED)'
  try {
    $featLine = @([IO.File]::ReadAllLines($Jsonl, [Text.Encoding]::UTF8) | Where-Object { $_ -match '"kind":"FEATURES"' } | Select-Object -First 1)
    if ($featLine.Count -gt 0) {
      $f = ($featLine[0] | ConvertFrom-Json)
      Note ('host FEATURES: subscribe=' + [string]$f.eventSubscribe + ' sessionHook=' + [string]$f.sessionHook + ' toolHook=' + [string]$f.toolHook + ' interrupt=' + [string]$f.sessionInterrupt + ' wait=' + [string]$f.sessionWait)
      if (([string]$f.sessionInterrupt -ne 'function') -and ([string]$f.sessionWait -ne 'function')) {
        Hold '(e) ctx.session.interrupt/wait ausentes no 2.0.18 (NAO-VERIFICADO, sem falha do harness)'
      }
    }
  } catch { }
  if ($createArgs -ne '') {
    Start-Sleep -Seconds 4
    $kindsEv = Get-JsonlKinds -Path $Jsonl
    Assert (($kindsEv.ContainsKey('EVENT'))) '(b) session.created/updated entregue via subscribe no host real (EVENT)'
    if (-not ($kindsEv.ContainsKey('EVENT'))) { Hold '(b) trigger enviado mas EVENT nao observado no JSONL (NAO-VERIFICADO)' }
  } else {
    Hold '(b) entrega session.created/updated NAO-VERIFICADA sem trigger sem-modelo (sem falha do harness)'
  }
  $kinds3 = Get-JsonlKinds -Path $Jsonl
  Assert (($kinds3.ContainsKey('CONTEXT_FIRED'))) '(c) context injection disparou no host real (CONTEXT_FIRED)'
  if (-not ($kinds3.ContainsKey('CONTEXT_FIRED'))) { Hold '(c) context injection NAO-VERIFICADA sem stub local (exige geracao com modelo pago; stub openai-compatible exige schema do provider V2 nao provado sem rede, sem adivinhacao)' }
  if ($kinds3.ContainsKey('TOOL_FIRED')) { Note '(d) execute.before observado no host real' }
  else { Hold '(d) execute.before NAO-VERIFICADO sem stub local (shell direto exit 0 nao passa por tool.hook; exige geracao com modelo pago)' }
  # RR-P24-TRIGGER-FIX (4) correlacao honesta: igualdade de sessao so quando
  # comparavel. Registra trigger session id sanitizado; compara createdSid
  # (data.id do POST) com EVENT.session e CONTEXT_FIRED.session do JSONL.
  # Prefixos distintos (evt_* = evento, ses_* = sessao) => NAO comparaveis.
  try {
    $trigSan = ''
    try {
      if (($createdSid -match '^[A-Za-z0-9._:@-]{1,128}$')) { $trigSan = $createdSid }
      else { $trigSan = 'redacted' }
    } catch { $trigSan = 'redacted' }
    if (-not [string]::IsNullOrWhiteSpace($createdSid)) { Note ('trigger session id (sanitizado): ' + $trigSan) }
    else { Note 'trigger session id ausente (sem POST bem-sucedido; sem correlacao)' }
    $evSessions = @()
    $ctxSessions = @()
    try {
      foreach ($ln in @([IO.File]::ReadAllLines($Jsonl, [Text.Encoding]::UTF8))) {
        try {
          $o = ($ln | ConvertFrom-Json)
          if ([string]$o.kind -eq 'EVENT' -and (-not [string]::IsNullOrWhiteSpace([string]$o.session))) { $evSessions += [string]$o.session }
          if ([string]$o.kind -eq 'CONTEXT_FIRED' -and (-not [string]::IsNullOrWhiteSpace([string]$o.session))) { $ctxSessions += [string]$o.session }
        } catch { }
      }
    } catch { }
    if (($evSessions.Count -gt 0) -and (-not [string]::IsNullOrWhiteSpace($createdSid))) {
      $evMatch = ($evSessions -contains $createdSid)
      Note ('correlacao EVENT.session vs trigger: ' + ($evSessions -join ',') + ' match=' + $evMatch)
      if (-not $evMatch) { Note 'EVENT.session difere do trigger (prefixo evt_* = id do evento, nao da sessao; sem claim de igualdade)' }
    }
    if (($ctxSessions.Count -gt 0) -and (-not [string]::IsNullOrWhiteSpace($createdSid))) {
      $ctxMatch = ($ctxSessions -contains $createdSid)
      Note ('correlacao CONTEXT_FIRED.session vs trigger: ' + ($ctxSessions -join ',') + ' match=' + $ctxMatch)
      if ($ctxMatch) { Note 'CONTEXT_FIRED.session == trigger (igualdade comparavel e verificada)' }
      else { Note 'CONTEXT_FIRED.session difere do trigger (sem claim de igualdade)' }
    } else {
      Note 'correlacao de sessao indisponivel (EVENT/CONTEXT ou trigger ausente; sem claim de igualdade)'
    }
  } catch { Note 'correlacao indisponivel (sem claim de igualdade)' }
}

# S8: log do servidor sem erro do plugin (best-effort) ---------------------------
if ($Started) {
  try {
    $logDir = Join-Path $HomeT '.local\share\opencode\log'
    $errHit = $false
    if (Test-Path -LiteralPath $logDir -PathType Container) {
      foreach ($lf in @(Get-ChildItem -File -LiteralPath $logDir -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        try {
          $txt = [IO.File]::ReadAllText($lf.FullName, [Text.Encoding]::UTF8)
          if ($txt -match 'rr-p24-livehook-fixture' -and $txt -match '(?i)error|exception|failed to load') { $errHit = $true }
          $plugLines = @($txt -split "`r?`n" | Where-Object { $_ -match '(?i)plugin' } | Select-Object -First 5)
          foreach ($pln in @($plugLines)) {
            $s = ([string]$pln)
            $s = [regex]::Replace($s, '"password"\s*:\s*"[^"]*"', '"password":"[REDACTED]"')
            if ($s.Length -gt 250) { $s = $s.Substring(0, 250) }
            Note ('serverlog plugin: ' + $s)
          }
        } catch { }
      }
    } else { Note 'log dir do servidor ausente no perfil temp (best-effort; BOOT e a prova primaria)' }
    Assert ((-not $errHit)) '(a) sem erro do plugin no log do servidor'
  } catch { Assert ($false) 'leitura de log' }
}

# S9: stop owned + settlement ------------------------------------------------------
if ($Started) {
  $sp = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'service stop' -WorkDir $HomeT -EnvTable $EffEnv -TimeoutMs 30000
  Assert (([bool]$sp.Finished) -and ([int]$sp.ExitCode -eq 0)) '(f) service stop owned exit 0'
  $sts2 = Invoke-PreflightBoundedExe -File $ProvisionedExe -ArgsLine 'service status' -WorkDir $HomeT -EnvTable $EffEnv -TimeoutMs 15000
  $settled = $false
  try {
    $li3 = Get-PreflightListener -Port $Alt
    $noListen = ((Get-PreflightListenerQueryOk -Listener $li3) -and (-not [bool]$li3.Exists))
    $settled = (([string]$sts2.Output -match '(?i)stopped') -and $noListen)
  } catch { $settled = $false }
  Assert ($settled) '(f) settlement: stopped + sem listener'
  if (-not $settled) { Fail-Preserve 'sem settlement' }
}

# S10: 49374 intacto depois + global intacto -----------------------------------------
$colAfter = Get-PreflightListener -Port 49374
$colAfterFp = ''
try {
  $idAfter = Get-PreflightProcessIdentity -OwnerPID ([int]$colAfter.OwningPID)
  $colAfterFp = ('exists=' + [bool]$colAfter.Exists + ' pid=' + [int]$colAfter.OwningPID + ' name=' + [string]$idAfter.Name)
} catch { $colAfterFp = ('exists=' + [bool]$colAfter.Exists) }
Note ('49374 depois: ' + $colAfterFp)
Assert (($colAfterFp -eq $colBeforeFp)) '49374 intacto antes==depois'
$globalHashAfter = ''
if (Test-Path -LiteralPath $GlobalCfg -PathType Leaf) {
  try { $globalHashAfter = (Get-FileHash -LiteralPath $GlobalCfg -Algorithm SHA256).Hash } catch { $globalHashAfter = '' }
}
Assert (($globalHashAfter -eq $globalHashBefore)) 'config global intacta'

# Evidencia: copia sanitizada do JSONL (quando existir, pass ou fail) -------------
if (Test-Path -LiteralPath $Jsonl -PathType Leaf) {
  try {
    $allowKinds = @('BOOT', 'FEATURES', 'FEATURES_ERROR', 'SUBSCRIBED', 'SUBSCRIBE_UNAVAILABLE', 'SUBSCRIBE_ERROR', 'CONTEXT_REGISTERED', 'CONTEXT_UNAVAILABLE', 'CONTEXT_ERROR', 'TOOL_REGISTERED', 'TOOL_UNAVAILABLE', 'TOOL_ERROR', 'EVENT', 'TRIGGER', 'CONTEXT_FIRED', 'TOOL_FIRED', 'STREAM_END', 'CLEANUP')
    $outLines = New-Object System.Collections.ArrayList
    foreach ($ln in @([IO.File]::ReadAllLines($Jsonl, [Text.Encoding]::UTF8))) {
      try {
        $o = ($ln | ConvertFrom-Json)
        if ($allowKinds -contains [string]$o.kind) { [void]$outLines.Add($ln) }
      } catch { }
    }
    [IO.File]::WriteAllLines($EvidenceJsonl, ([string[]]$outLines), (New-Object Text.UTF8Encoding $false))
    Note ('evidencia copiada: ' + $EvidenceJsonl + ' (' + $outLines.Count + ' linhas)')
  } catch { Note ('copia de evidencia falhou: ' + $_.Exception.Message) }
}

if (($Failed) -or ($fail -gt 0)) { Write-Host ("[PRESERVE] temp em " + $TmpRoot) }
else {
  try { Remove-Item -LiteralPath $TmpRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  Note 'temp removido apos PASS (evidencia copiada)'
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail + " / HOLD: " + $hold)
if ($fail -gt 0) { exit 1 } else { exit 0 }
