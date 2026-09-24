<#!
.SYNOPSIS
    Runner oficial das distribution suites (*.tests.ps1 em tests/distribution).
.DESCRIPTION
    Descobre suites deterministicamente (FullName alfabetico), executa cada
    uma isolada (mesmo engine do pai via cmd /c, timeout 300s/suite, log por
    suite), coleta exit code + duracao e imprime PASS/FAIL/SKIP por suite +
    resumo final. PS 5.1 compativel. Nao altera as suites.
    Mesmo engine do pai: sob powershell 5.1 as suites rodam em powershell,
    sob pwsh rodam em pwsh (o CI exercita os dois engines de verdade).
    SKIP = suite que imprime [SKIP] e sai 0 sem [FAIL]/NOT OK.
    Exit codes: 0 = nenhuma FAIL e nenhum erro interno; 1 = alguma suite
    falhou; 2 = algum INTERNAL_ERROR (timeout, log ausente/ilegivel,
    excecao do runner, processo nao iniciou). 2 tem precedencia sobre 1.
#>
$ErrorActionPreference = 'Stop'
$distDir = $PSScriptRoot
$SuiteTimeoutMs = 300000
if ($PSVersionTable.PSEdition -eq 'Core') { $engine = 'pwsh' } else { $engine = 'powershell' }

function Write-SuiteResult([string]$Verdict, [string]$SuiteName, [long]$Ms, [string]$Note) {
  $line = $Verdict + ' ' + $SuiteName + ' ' + $Ms + 'ms'
  if (-not [string]::IsNullOrWhiteSpace($Note)) { $line = $line + ' -- ' + $Note }
  Write-Host $line
}

try {
  if ([string]::IsNullOrWhiteSpace($distDir) -or (-not (Test-Path -LiteralPath $distDir -PathType Container))) {
    Write-Host 'RUNNER FAILED: diretorio distribution nao encontrado.' -ForegroundColor Red
    exit 2
  }
  $suites = @(Get-ChildItem -File (Join-Path $distDir '*.tests.ps1') -ErrorAction SilentlyContinue | Sort-Object { $_.FullName })
  if ($suites.Count -eq 0) {
    Write-Host 'RUNNER FAILED: nenhuma suite encontrada em tests/distribution.' -ForegroundColor Red
    exit 2
  }

  Write-Host ('Runner distribution: ' + $suites.Count + ' suite(s), engine ' + $engine + ', timeout 300s/suite.')
  $nPass = 0
  $nFail = 0
  $nSkip = 0
  $nInternal = 0
  $logDir = Join-Path ([IO.Path]::GetTempPath()) ('dist-runner-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()
  foreach ($s in $suites) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = -1
    $text = ''
    $timedOut = $false
    $isInternal = $false
    $logFile = Join-Path $logDir ($s.BaseName + '.log')
    try {
      # cmd /c com redirecionamento para arquivo: evita deadlock de pipe
      # (suite verbosa bloqueia se o pai nao drenar stdout durante WaitForExit).
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = 'cmd.exe'
      $psi.Arguments = '/c ' + $engine + ' -NoProfile -ExecutionPolicy Bypass -File "' + $s.FullName + '" > "' + $logFile + '" 2>&1'
      $psi.UseShellExecute = $false
      # FIX filho 5.1 sob host pwsh: herdaria PSModulePath do pwsh e perderia
      # autoload dos modulos padrao. So aplica quando o filho e powershell;
      # filho pwsh mantem o PSModulePath herdado (modulos do pwsh).
      if ($engine -eq 'powershell') {
        $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules"
      }
      $psi.RedirectStandardOutput = $false
      $psi.RedirectStandardError = $false
      $psi.CreateNoWindow = $true
      $psi.WorkingDirectory = $distDir
      $p = [System.Diagnostics.Process]::Start($psi)
      if ($null -eq $p) {
        $isInternal = $true
        $text = 'RUNNER ERROR: processo nao iniciou para ' + $s.Name
      }
      else {
        $finished = $p.WaitForExit($SuiteTimeoutMs)
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
        try {
          if (Test-Path -LiteralPath $logFile -PathType Leaf) {
            $text = [IO.File]::ReadAllText($logFile, [Text.Encoding]::UTF8)
            $logOk = $true
          }
        }
        catch { $logOk = $false }
        if ((-not $timedOut) -and (-not $logOk)) {
          $isInternal = $true
          $text = 'RUNNER ERROR: log ilegivel/ausente para ' + $s.Name
        }
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
    if ($isInternal -or $timedOut) {
      $nInternal += 1
      if ($timedOut) {
        Write-SuiteResult 'ERROR' $s.Name $ms 'INTERNAL_ERROR TIMEOUT 300s (processo morto)'
      }
      else {
        Write-SuiteResult 'ERROR' $s.Name $ms ('INTERNAL_ERROR exit ' + $code)
      }
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
  }
  $totalWatch.Stop()
  $totalSec = [Math]::Round($totalWatch.Elapsed.TotalSeconds, 1)
  try { if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
  Write-Host ''
  Write-Host ('PASS: ' + $nPass + ' / FAIL: ' + $nFail + ' / SKIP: ' + $nSkip + ' / INTERNAL_ERROR: ' + $nInternal + ' / TOTAL: ' + $suites.Count + ' (suites: ' + $suites.Count + ')')
  Write-Host ('Tempo total: ' + $totalSec + 's')
  if ($nInternal -gt 0) { exit 2 }
  if ($nFail -gt 0) { exit 1 }
  exit 0
}
catch {
  Write-Host ('RUNNER FAILED: ' + $_.Exception.Message) -ForegroundColor Red
  exit 2
}
