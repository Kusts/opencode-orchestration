<#
.SYNOPSIS
    Smoke test do pacote com OpenCode V1 REAL num home isolado.
.DESCRIPTION
    Pinned: OpenCode V1 (npm opencode-ai@1.18.32; default via -OpenCodeSpec).
    V2 (pacote @opencode-ai/cli, comando opencode2) NAO e suportado.

    Fluxo:
      1. Bootstrap de models.jsonc a partir de models.example.jsonc SE ausente
         (CI only; nunca sobrescreve o arquivo do dev).
      2. Roda install.ps1 REAL (sem -WhatIf) com -TargetHome isolado.
      3. Assercoes com o OpenCode filho (SEM --pure, o plugin externo precisa
         carregar) e com USERPROFILE/HOME do filho apontando para $TargetHome.

    Exit codes confiaveis: usa Start-Process -Wait -PassThru (checando
    $proc.ExitCode). NAO usa `opencode ... 2>&1 | ...` porque no PS 5.1 isso
    enrola stderr em ErrorRecord e suja $LASTEXITCODE.

    PS 5.1 compativel: sem ternario, sem ??, sem Invoke-Expression.
    Nao seta variaveis persistentes de usuario/maquina; nada destrutivo fora
    de $TargetHome. O isolamento do filho e efemero (restaura USERPROFILE/HOME
    em finally); script efemero de CI.
.PARAMETER RepoRoot
    Raiz do repositorio do pacote. Default: dois niveis acima deste script
    (scripts/ci -> raiz).
.PARAMETER TargetHome
    Home isolado do smoke. Default: $env:RUNNER_TEMP\oo-smoke-home (CI) ou
    $env:TEMP\oo-smoke-home fora do CI.
.PARAMETER OpenCodeSpec
    Spec npm do OpenCode esperado (so documental/verificacao de major; a
    instalacao global e feita pelo workflow ou pelo dev).
#>
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$TargetHome = '',
  [string]$OpenCodeSpec = 'opencode-ai@1.18.32'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if ([string]::IsNullOrWhiteSpace($TargetHome)) {
  $baseHome = $env:RUNNER_TEMP
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = $env:TEMP }
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = [IO.Path]::GetTempPath() }
  $TargetHome = Join-Path $baseHome 'oo-smoke-home'
}

Write-Host "[smoke] RepoRoot=$RepoRoot"
Write-Host "[smoke] TargetHome=$TargetHome"
Write-Host "[smoke] OpenCodeSpec=$OpenCodeSpec (esperado V1.x)"

function Show-Tail {
  param([string]$Path, [int]$Lines = 40)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Host "(sem arquivo: $Path)"
    return
  }
  Write-Host "--- tail ($Lines linhas): $Path ---"
  $lines = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue
  foreach ($l in $lines) { Write-Host $l }
  Write-Host "--- fim ---"
}

function Show-Diagnostics {
  param([string]$StdoutFile, [string]$StderrFile)
  Write-Host "[smoke] DIAGNOSTICO de falha:"
  Show-Tail -Path $StdoutFile
  Show-Tail -Path $StderrFile
  $stateDir = Join-Path $TargetHome '.opencode-orchestration'
  if (Test-Path -LiteralPath $stateDir) {
    Write-Host "[smoke] conteudo de $stateDir :"
    Get-ChildItem -LiteralPath $stateDir -Force -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  " + $_.Name) }
  }
  else {
    Write-Host "[smoke] (sem diretorio $stateDir)"
  }
}

function New-TempLog {
  param([string]$Tag)
  $tmpBase = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($tmpBase)) { $tmpBase = [IO.Path]::GetTempPath() }
  $suffix = [guid]::NewGuid().ToString('N')
  $o = Join-Path $tmpBase ('oo-smoke-' + $Tag + '-out-' + $suffix + '.log')
  $e = Join-Path $tmpBase ('oo-smoke-' + $Tag + '-err-' + $suffix + '.log')
  return @{ Out = $o; Err = $e }
}

function Get-PsChildExe {
  if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
  return 'powershell'
}

function Invoke-OpencodeCapture {
  param([string[]]$Arguments, [string]$StepTag)
  # Isola o filho: no Windows o OpenCode resolve ~ via USERPROFILE. Seta
  # USERPROFILE (e HOME) para o home temporario ANTES de invocar o
  # opencode-filho e restaura depois (finally). Efemero; nada persistente.
  $oldUserProfile = $env:USERPROFILE
  $oldHome = $env:HOME
  $logs = New-TempLog -Tag $StepTag
  $code = -1
  try {
    $env:USERPROFILE = $TargetHome
    $env:HOME = $TargetHome
    # Via cmd /c: no Windows o 'opencode' do npm e um shim .cmd, que o
    # Start-Process nao executa diretamente ("%1 nao e um aplicativo Win32
    # valido"). cmd /c propaga o exit code do filho; stdout/stderr vao para
    # os arquivos de redirect (exit codes confiaveis no PS 5.1).
    $opencodeLine = 'opencode'
    foreach ($a in $Arguments) {
      if ($a -match '\s') { $opencodeLine += ' "' + $a + '"' }
      else { $opencodeLine += ' ' + $a }
    }
    $p = Start-Process -FilePath 'cmd' -ArgumentList @('/c', $opencodeLine) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $logs.Out -RedirectStandardError $logs.Err
    $code = $p.ExitCode
  }
  finally {
    $env:USERPROFILE = $oldUserProfile
    if ([string]::IsNullOrEmpty($oldHome)) {
      Remove-Item Env:\HOME -ErrorAction SilentlyContinue
    }
    else {
      $env:HOME = $oldHome
    }
  }
  $out = ''
  $err = ''
  if (Test-Path -LiteralPath $logs.Out -PathType Leaf) { $out = [IO.File]::ReadAllText($logs.Out) }
  if (Test-Path -LiteralPath $logs.Err -PathType Leaf) { $err = [IO.File]::ReadAllText($logs.Err) }
  return @{ ExitCode = $code; Stdout = $out; Stderr = $err; OutFile = $logs.Out; ErrFile = $logs.Err }
}

function Fail-Smoke {
  param([string]$Message, [string]$StdoutFile = '', [string]$StderrFile = '')
  Write-Host "[smoke] FALHA: $Message"
  Show-Diagnostics -StdoutFile $StdoutFile -StderrFile $StderrFile
  exit 1
}

# ---- 0. precheck: opencode no PATH -------------------------------------------
$opencodeCmd = Get-Command 'opencode' -ErrorAction SilentlyContinue
if ($null -eq $opencodeCmd) {
  Fail-Smoke -Message "binario 'opencode' nao encontrado no PATH. Instale $OpenCodeSpec (ex.: npm install -g $OpenCodeSpec)."
}

# ---- 1. bootstrap models.jsonc (somente se ausente) --------------------------
$modelsPath = Join-Path $RepoRoot 'models.jsonc'
$modelsExample = Join-Path $RepoRoot 'models.example.jsonc'
if (-not (Test-Path -LiteralPath $modelsPath -PathType Leaf)) {
  if (-not (Test-Path -LiteralPath $modelsExample -PathType Leaf)) {
    Fail-Smoke -Message "models.jsonc ausente e models.example.jsonc nao encontrado em $RepoRoot; bootstrap impossivel."
  }
  Write-Host '[smoke] models.jsonc ausente; copiando models.example.jsonc -> models.jsonc (CI only; nao sobrescreve o do dev).'
  Copy-Item -LiteralPath $modelsExample -Destination $modelsPath -Force
}
else {
  Write-Host '[smoke] models.jsonc ja existe; mantido (nao sobrescreve o do dev).'
}

# ---- 2. install.ps1 REAL (sem -WhatIf) no home isolado -----------------------
if (-not (Test-Path -LiteralPath $TargetHome)) {
  New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
}
$installScript = Join-Path $RepoRoot 'install.ps1'
if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
  Fail-Smoke -Message "install.ps1 nao encontrado em $RepoRoot."
}
$psExe = Get-PsChildExe
$installLogs = New-TempLog -Tag 'install'
$quotedRepo = '"' + $RepoRoot + '"'
$quotedHome = '"' + $TargetHome + '"'
$installArgs = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installScript + '"'), '-RepoRoot', $quotedRepo, '-TargetHome', $quotedHome)
Write-Host "[smoke] rodando install.ps1 REAL no home isolado (engine filho: $psExe)..."
$installProc = Start-Process -FilePath $psExe -ArgumentList $installArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $installLogs.Out -RedirectStandardError $installLogs.Err
if ($installProc.ExitCode -ne 0) {
  Fail-Smoke -Message ("install.ps1 REAL falhou com exit " + $installProc.ExitCode + ".") -StdoutFile $installLogs.Out -StderrFile $installLogs.Err
}
Write-Host '[smoke] install.ps1 OK (exit 0).'

# ---- 3. assercoes com OpenCode REAL (SEM --pure) ------------------------------
# i. opencode --version sai 0 e casa ^1.
Write-Host '[smoke] (i) opencode --version ...'
$r = Invoke-OpencodeCapture -Arguments @('--version') -StepTag 'version'
$verText = ($r.Stdout + "`n" + $r.Stderr).Trim()
Write-Host "[smoke] version output: $verText"
if ($r.ExitCode -ne 0) {
  Fail-Smoke -Message ("'opencode --version' saiu com exit " + $r.ExitCode + " (esperado 0).") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
if ([string]::IsNullOrWhiteSpace($verText)) {
  Fail-Smoke -Message 'OpenCode V2 nao e suportado por este pacote; esperado V1.x (versao vazia).' -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
if ($verText -match '(?m)^\s*2\.') {
  Fail-Smoke -Message ("OpenCode V2 nao e suportado por este pacote; esperado V1.x (obtido: $verText).") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
if (-not ($verText -match '(?m)^\s*1\.')) {
  Fail-Smoke -Message ("Versao inesperada do OpenCode (obtido: $verText); esperado V1.x.") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
Write-Host '[smoke] (i) OK.'

# ii. opencode debug config sai 0 e contem "default_agent" e "build".
Write-Host '[smoke] (ii) opencode debug config ...'
$r = Invoke-OpencodeCapture -Arguments @('debug', 'config') -StepTag 'debug-config'
if ($r.ExitCode -ne 0) {
  Fail-Smoke -Message ("'opencode debug config' saiu com exit " + $r.ExitCode + " (esperado 0; config possivelmente invalida).") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
$cfgText = $r.Stdout + "`n" + $r.Stderr
if (($cfgText -notmatch 'default_agent') -or ($cfgText -notmatch 'build')) {
  Fail-Smoke -Message "'opencode debug config' nao contem 'default_agent' + 'build' (config instalada incompleta?)." -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
Write-Host '[smoke] (ii) OK.'

# iii. opencode debug agent coder sai 0 (worker resolvido pela config).
Write-Host '[smoke] (iii) opencode debug agent coder ...'
$r = Invoke-OpencodeCapture -Arguments @('debug', 'agent', 'coder') -StepTag 'debug-agent-coder'
if ($r.ExitCode -ne 0) {
  Fail-Smoke -Message ("'opencode debug agent coder' saiu com exit " + $r.ExitCode + " (esperado 0; worker 'coder' nao resolvido).") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
Write-Host '[smoke] (iii) OK.'

# iv. opencode debug skill sai 0 e contem hybrid-development (skill-core).
Write-Host '[smoke] (iv) opencode debug skill ...'
$r = Invoke-OpencodeCapture -Arguments @('debug', 'skill') -StepTag 'debug-skill'
if ($r.ExitCode -ne 0) {
  Fail-Smoke -Message ("'opencode debug skill' saiu com exit " + $r.ExitCode + " (esperado 0).") -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
$skillText = $r.Stdout + "`n" + $r.Stderr
if ($skillText -notmatch 'hybrid-development') {
  Fail-Smoke -Message "'opencode debug skill' nao lista 'hybrid-development' (skill-core nao descoberta?)." -StdoutFile $r.OutFile -StderrFile $r.ErrFile
}
Write-Host '[smoke] (iv) OK.'

Write-Host '[smoke] PASS: todas as assercoes com OpenCode REAL passaram (SEM --pure; plugin externo carregado).'
exit 0
