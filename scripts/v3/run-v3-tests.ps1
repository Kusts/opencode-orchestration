<#!
.SYNOPSIS
    Runner oficial das suites V3 (*.tests.ps1 em scripts/v3 + lib).
.DESCRIPTION
    Descobre suites deterministicamente (FullName alfabetico), executa cada
    uma isolada (powershell -NoProfile -File, timeout padrao 300s/suite com
    override por suite quando justificado), coleta
    exit code + duracao e imprime PASS/FAIL/SKIP por suite + resumo final.
    Filtro -Name com charset validado (fail-closed, exit 2): so seleciona
    suites ja descobertas nos roots fixos, nunca resolve caminho nem executa
    outro script. Sem match = exit 2.
    PS 5.1 compativel. Nao altera as suites.
    SKIP = suite que imprime [SKIP] e sai 0 (padrao P5: passed+skipped==total).
    Exit codes: 0 = nenhuma FAIL e nenhum erro interno (SKIP nao e fail); 1 = alguma suite EXECUTOU e falhou; 2 = falha do runner ou qualquer internal_error de infra (Process.Start lancou, log ilegivel/ausente). internal_error nunca vira FAIL.
#>
param(
  [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot

# Timeout por suite: default global + overrides justificados por BaseName.
# Chave = FileInfo.BaseName (nome sem a ultima extensao, ex.:
# "OrchestrationNativeDispatchHandoff.tests" para "...tests.ps1").
$SuiteTimeoutDefaultMs = 300000
$SuiteTimeoutOverrides = @{
  # OrchestrationNativeDispatchHandoff: corridas oficiais PS5.1 observaram
  # 197s, 261s, 284s e um timeout real de 300.7s/301.5s. A suite hoje tem
  # ~1745 assertions (cobertura de regressao de seguranca), com cauda
  # intermitente que pode passar dos 300s. Sobe SO esta suite para 420s (7
  # min). Elevar o default global NAO e apropriado: a cauda e especifica do
  # volume desta suite; um default maior mascararia hangs reais nas demais
  # suites e atrasaria a deteccao de falha. As outras suites seguem em 300s.
  'OrchestrationNativeDispatchHandoff.tests' = 420000
}
function Get-SuiteTimeoutMs([string]$BaseName) {
  if ($SuiteTimeoutOverrides.ContainsKey($BaseName)) { return [int]$SuiteTimeoutOverrides[$BaseName] }
  return [int]$SuiteTimeoutDefaultMs
}

function Write-SuiteResult([string]$Verdict, [string]$SuiteName, [long]$Ms, [string]$Note) {
  $line = $Verdict + ' ' + $SuiteName + ' ' + $Ms + 'ms'
  if (-not [string]::IsNullOrWhiteSpace($Note)) { $line = $line + ' -- ' + $Note }
  Write-Host $line
}

try {
  if ([string]::IsNullOrWhiteSpace($v3) -or (-not (Test-Path -LiteralPath $v3 -PathType Container))) {
    Write-Host 'RUNNER FAILED: diretorio v3 nao encontrado.' -ForegroundColor Red
    exit 2
  }

  # Bootstrap: checkout limpo nao traz models.jsonc (gerado, gitignored), mas o
  # precheck do installer exige o arquivo no repo; sem ele o PRECHECK sai 3 e
  # derruba as suites de runtime-adapters e de perfil/wrapper v2. Precedente exato:
  # tests/distribution/run-distribution-tests.ps1 (run 36083266782). Criacao
  # EXCLUSIVA a prova de corrida: [IO.File]::Copy com overwrite=$false nao
  # sobrescreve um models.jsonc existente, nem um que surja entre o Test-Path e a
  # copia; nesse caso o arquivo da corrida e preservado e o runner segue.
  $repoDir = Split-Path -Parent (Split-Path -Parent $v3)
  $modelsJsonc = Join-Path $repoDir 'models.jsonc'
  if (-not (Test-Path -LiteralPath $modelsJsonc -PathType Leaf)) {
    $modelsExample = Join-Path $repoDir 'models.example.jsonc'
    if (-not (Test-Path -LiteralPath $modelsExample -PathType Leaf)) {
      Write-Host 'RUNNER FAILED: models.jsonc ausente e models.example.jsonc indisponivel para bootstrap.' -ForegroundColor Red
      exit 2
    }
    $bootstrapCreated = $false
    try {
      # overwrite=$false: se o destino ja existir a copia NAO acontece.
      [IO.File]::Copy($modelsExample, $modelsJsonc, $false)
      $bootstrapCreated = $true
    }
    catch [System.IO.IOException] {
      if (Test-Path -LiteralPath $modelsJsonc -PathType Leaf) {
        Write-Host 'Bootstrap: models.jsonc surgiu durante a corrida; arquivo existente preservado.'
      }
      else {
        Write-Host ('RUNNER FAILED: bootstrap de models.jsonc falhou: ' + $_.Exception.Message) -ForegroundColor Red
        exit 2
      }
    }
    catch {
      Write-Host ('RUNNER FAILED: bootstrap de models.jsonc falhou: ' + $_.Exception.Message) -ForegroundColor Red
      exit 2
    }
    if ($bootstrapCreated) {
      Write-Host 'Bootstrap: models.jsonc ausente no checkout; criado a partir de models.example.jsonc.'
    }
  }
  $all = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -File (Join-Path $v3 '*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  foreach ($f in @(Get-ChildItem -File (Join-Path $v3 'lib\*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  $runtimeDir = Join-Path (Split-Path -Parent $v3) 'runtime'
  foreach ($f in @(Get-ChildItem -File (Join-Path $runtimeDir '*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  # F3 fixture suites live outside scripts/v3 (tests/f3). Same discovery
  # pattern as the loops above: fixed root, file glob only, sorted later by
  # FullName. No timeout, order or filter semantic change.
  $f3Dir = Join-Path $repoDir 'tests\f3'
  foreach ($f in @(Get-ChildItem -File (Join-Path $f3Dir '*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  $suites = @($all | Sort-Object { $_.FullName })
  if ($Name.Length -gt 0) {
    # Charset fechado: letras, digitos, ponto, traco, underscore, espaco e
    # curingas * ?. Qualquer outro caractere e fail-closed (exit 2): o filtro
    # so seleciona suites ja descobertas nos roots fixos acima, nunca resolve
    # caminho, nunca executa outro script. \A...\z (nao $) para nao aceitar
    # LF final; guard por Length (nao IsNullOrWhiteSpace) para whitespace-only
    # tambem passar pelo filtro (e falhar fechado no sem-match abaixo).
    if ($Name -notmatch '\A[A-Za-z0-9_\-\. \*\?]+\z') {
      Write-Host ('RUNNER FAILED: filtro -Name invalido (permitido: letras, digitos, ponto, traco, underscore, espaco, curingas * ?): "' + $Name + '".') -ForegroundColor Red
      exit 2
    }
    $pat = $Name
    if ($pat -notmatch '[\*\?]') { $pat = '*' + $pat + '*' }
    $suites = @($suites | Where-Object { $_.Name -like $pat })
  }
  if ($suites.Count -eq 0) {
    Write-Host ('RUNNER FAILED: nenhuma suite encontrada (filtro "' + $Name + '").') -ForegroundColor Red
    exit 2
  }

  $defSec = [int]($SuiteTimeoutDefaultMs / 1000)
  $banner = 'Runner V3: ' + $suites.Count + ' suite(s), timeout padrao ' + $defSec + 's/suite'
  $activeOverrides = @()
  foreach ($s in $suites) {
    if ($SuiteTimeoutOverrides.ContainsKey($s.BaseName)) {
      $activeOverrides += ($s.Name + '=' + [int]($SuiteTimeoutOverrides[$s.BaseName] / 1000) + 's')
    }
  }
  if ($activeOverrides.Count -gt 0) { $banner = $banner + '; override ativo: ' + ($activeOverrides -join ', ') }
  $banner = $banner + '; cwd isolado por processo.'
  Write-Host $banner
  $nPass = 0
  $nFail = 0
  $nSkip = 0
  $nInternal = 0
  $logDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-runner-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
  foreach ($s in $suites) {
    $suiteTimeoutMs = Get-SuiteTimeoutMs $s.BaseName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = -1
    $text = ''
    $timedOut = $false
    $isInternal = $false
    $logFile = Join-Path $logDir ($s.BaseName + '.log')
    try {
      # cmd /c com redirecionamento para arquivo: evita deadlock de pipe
      # (suite verbosa bloqueia se o pai nao drenar stdout durante WaitForExit).
      # Console oculto HERDAVEL (UseShellExecute + WindowStyle Hidden): a
      # suite e os netos `& powershell` herdam o console oculto. Com
      # CreateNoWindow os netos sem console ganhavam janela visivel no host.
      # Start-Process com redirecionamento nativo: evita o problema de handle
      # herdado do cmd.exe (o handle do arquivo de log nao era liberado quando
      # WaitForExit retornava, porque o powershell filho herdava o handle).
      # cmd.exe com redirecionamento de stdin de NUL: garante que o stdin e
      # completamente vazio (NUL = /dev/null no Windows). Redirecionamento de
      # stdout/stderr para o arquivo de log via cmd.exe. O handle do arquivo
      # pode ser herdado pelo powershell filho, mas o runner tenta ler com retry.
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = 'cmd.exe'
      # FIX CI ps7: filho 5.1 herdaria PSModulePath do host pwsh e perderia
      # autoload dos modulos padrao (Get-FileHash); fixa para os modulos do 5.1.
      $psi.Arguments = '/c set "PSModulePath=%windir%\System32\WindowsPowerShell\v1.0\Modules" && powershell -NoProfile -ExecutionPolicy Bypass -File "' + $s.FullName + '" > "' + $logFile + '" 2>&1 < NUL'
      $psi.UseShellExecute = $true
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      $psi.WorkingDirectory = $v3
      $p = [System.Diagnostics.Process]::Start($psi)
      $finished = $p.WaitForExit($suiteTimeoutMs)
      if (-not $finished) {
        $timedOut = $true
        try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
        try { $p.WaitForExit(10000) } catch { }
      }
      else {
        $code = $p.ExitCode
      }
      try { $p.Close() } catch { }
      $logOk = $false
      # O cmd.exe/powershell filho pode ainda segurar o handle do arquivo de
      # log quando WaitForExit retorna. Matar a arvore de processos e aguardar
      # a liberacao do handle antes de ler.
      try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
      for ($r = 0; $r -lt 20 -and -not $logOk; $r++) {
        try {
          if (Test-Path -LiteralPath $logFile -PathType Leaf) {
            $text = [IO.File]::ReadAllText($logFile, [Text.Encoding]::UTF8)
            $logOk = $true
          }
          else {
            Start-Sleep -Milliseconds 50
          }
        }
        catch {
          $logOk = $false
          Start-Sleep -Milliseconds 100
        }
      }
      if ((-not $timedOut) -and (-not $logOk)) {
        $isInternal = $true
        $text = 'RUNNER ERROR: log ilegivel/ausente para ' + $s.Name
      }
      if ((-not $timedOut) -and (-not $logOk)) {
        $isInternal = $true
        $text = 'RUNNER ERROR: log ilegivel/ausente para ' + $s.Name
      }
    }
    catch {
      $text = 'RUNNER ERROR: ' + $_.Exception.Message
      $code = -1
      $isInternal = $true
    }
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    if (-not [string]::IsNullOrEmpty($text)) {
      $trimmed = $text.Trim()
      if ($trimmed.Length -gt 0) { Write-Host $trimmed }
    }
    $hasFail = ($text -match '(?m)^\[FAIL\]') -or ($text -match 'NOT OK -')
    $hasSkip = ($text -match '(?m)^\[SKIP\]')
    if ($isInternal) {
      $nInternal += 1
      Write-SuiteResult 'ERROR' $s.Name $ms ('INTERNAL_ERROR exit ' + $code)
    }
    elseif ($timedOut) {
      $nFail += 1
      Write-SuiteResult 'FAIL' $s.Name $ms ('TIMEOUT ' + [int]($suiteTimeoutMs / 1000) + 's (processo morto)')
    }
    elseif (($code -ne 0) -or $hasFail) {
      $nFail += 1
      Write-SuiteResult 'FAIL' $s.Name $ms ('exit ' + $code)
    }
    elseif ($hasSkip) {
      $nSkip += 1
      Write-SuiteResult 'SKIP' $s.Name $ms ('exit ' + $code + ', com [SKIP] e sem [FAIL]')
    }
    else {
      $nPass += 1
      Write-SuiteResult 'PASS' $s.Name $ms ('exit ' + $code)
    }
    try {
      $teleVerdict = 'PASS'
      if ($isInternal) { $teleVerdict = 'ERROR' }
      elseif ($timedOut) { $teleVerdict = 'FAIL' }
      elseif (($code -ne 0) -or $hasFail) { $teleVerdict = 'FAIL' }
      elseif ($hasSkip) { $teleVerdict = 'SKIP' }
      $teleLib = Join-Path $v3 'lib\DevTelemetry.ps1'
      if (Test-Path -LiteralPath $teleLib -PathType Leaf) {
        . $teleLib
        $null = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite $s.BaseName -Verdict $teleVerdict -ExitCode $code -DurationMs $ms -Engine 'ps51' -RepoRoot $repoDir
      }
    } catch { }
  }
  $totalWatch.Stop()
  $totalSec = [Math]::Round($totalWatch.Elapsed.TotalSeconds, 1)
  try { if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
  Write-Host ''
  Write-Host ('PASS: ' + $nPass + ' / FAIL: ' + $nFail + ' / SKIP: ' + $nSkip + ' / INTERNAL_ERROR: ' + $nInternal + ' / TOTAL: ' + $suites.Count)
  Write-Host ('Tempo total: ' + $totalSec + 's')
  if ($nInternal -gt 0) { exit 2 }
  if ($nFail -gt 0) { exit 1 }
  exit 0
}
catch {
  Write-Host ('RUNNER FAILED: ' + $_.Exception.Message) -ForegroundColor Red
  exit 2
}
