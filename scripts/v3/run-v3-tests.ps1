<#!
.SYNOPSIS
    Runner oficial das suites V3 (*.tests.ps1 em scripts/v3 + lib).
.DESCRIPTION
    Descobre suites deterministicamente (FullName alfabetico), executa cada
    uma isolada (powershell -NoProfile -File, timeout 300s/suite), coleta
    exit code + duracao e imprime PASS/FAIL/SKIP por suite + resumo final.
    PS 5.1 compativel. Nao altera as suites.
    SKIP = suite que imprime [SKIP] e sai 0 (padrao P5: passed+skipped==total).
    Exit codes: 0 = nenhuma FAIL e nenhum erro interno (SKIP nao e fail); 1 = alguma suite EXECUTOU e falhou; 2 = falha do runner ou qualquer internal_error de infra (Process.Start lancou, log ilegivel/ausente). internal_error nunca vira FAIL.
#>
param(
  [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$SuiteTimeoutMs = 300000

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
  $all = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -File (Join-Path $v3 '*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  foreach ($f in @(Get-ChildItem -File (Join-Path $v3 'lib\*.tests.ps1') -ErrorAction SilentlyContinue)) {
    [void]$all.Add($f)
  }
  $suites = @($all | Sort-Object { $_.FullName })
  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $pat = $Name
    if ($pat -notmatch '[\*\?]') { $pat = '*' + $pat + '*' }
    $suites = @($suites | Where-Object { $_.Name -like $pat })
  }
  if ($suites.Count -eq 0) {
    Write-Host ('RUNNER FAILED: nenhuma suite encontrada (filtro "' + $Name + '").') -ForegroundColor Red
    exit 2
  }

  Write-Host ('Runner V3: ' + $suites.Count + ' suite(s), timeout 300s/suite, cwd isolado por processo.')
  $nPass = 0
  $nFail = 0
  $nSkip = 0
  $nInternal = 0
  $logDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-runner-' + [guid]::NewGuid().ToString('N'))
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
      $psi.Arguments = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + $s.FullName + '" > "' + $logFile + '" 2>&1'
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $false
      $psi.RedirectStandardError = $false
      $psi.CreateNoWindow = $true
      $psi.WorkingDirectory = $v3
      $p = [System.Diagnostics.Process]::Start($psi)
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
      Write-SuiteResult 'FAIL' $s.Name $ms 'TIMEOUT 300s (processo morto)'
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
