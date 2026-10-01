<#!
.SYNOPSIS
    Fixtures deterministicas de stall/repeticao (Phase 21, sem modelo).
.DESCRIPTION
    Reproduz de forma controlada e sem custo de LLM os dois modos de falha
    que a Phase 21 precisa observar antes de qualquer enforcement:
      1. worker que nunca retorna (fake tool bloqueado via child sleep);
      2. loop de acao repetida + ciclo curto (funcao pura de fingerprint).
    Harness [PASS]/[FAIL] + exit 0/1, PS 5.1 e PS7, ASCII puro.
    Escreve so em TEMP; nunca toca o repo fora desta evidencia.
    Nao habilita enforcement: apenas prova que stall/repeticao sao
    detectaveis deterministicamente (base para watchdog shadow, Phase 25).
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rr = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here)))
$lib = Join-Path $rr 'scripts\runtime\lib\SpikeProcess.ps1'
. $lib

$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$base = Join-Path ([IO.Path]::GetTempPath()) ('rr21-fixtures-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
  $script:total += 1
  if ($condition) { $script:passed += 1; Write-Host ('[PASS] ' + $name) }
  else { Write-Host ('[FAIL] ' + $name + ' -- ' + $detail) }
}

function Get-Sha256Hex([string]$Text) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  finally { $sha.Dispose() }
}

function Get-ActionFingerprint([string]$Tool, [string]$Args, [string]$Resource) {
  $t = ([string]$Tool).Trim().ToLowerInvariant() -replace '\s+', ' '
  $a = ([string]$Args).Trim() -replace '\s+', ' '
  $r = ([string]$Resource).Trim().ToLowerInvariant() -replace '\\', '/'
  $joined = $t + '|' + $a + '|' + $r
  # Redacao antes de persistir: valores de segredo nunca entram no hash legivel.
  $joined = $joined -replace '(?i)(token|api[_-]?key|secret|password)\s*=\s*\S+', '$1=<redacted>'
  $joined = $joined -replace 'sk-[A-Za-z0-9\-_]+', '<redacted>'
  $joined = $joined -replace 'JEV_API_KEY\s+\S+', 'JEV_API_KEY <redacted>'
  return Get-Sha256Hex $joined
}

function Test-RepetitionClass([string[]]$Fingerprints, [bool[]]$ProgressFlags) {
  # Retorna: NONE | STALL_SUSPECTED | HARD_STALL | REPEATED_CYCLE
  # Sufixo pos-progresso (residual RR-P21-FIX): descarta o prefixo ate o
  # ultimo meaningful progress (inclusive) e classifica apenas as acoes
  # sem progresso. Progresso antigo nunca mascara stall posterior, nem
  # quando a primeira acao do trailing run carrega o proprio progresso.
  if ($Fingerprints.Count -eq 0) { return 'NONE' }
  $n = $Fingerprints.Count
  $m = $ProgressFlags.Count
  $cut = 0
  for ($k = 0; $k -lt $n; $k++) {
    if (($k -lt $m) -and ([bool]$ProgressFlags[$k])) { $cut = $k + 1 }
  }
  $s = $n - $cut
  if ($s -le 0) { return 'NONE' }
  # 1. trailing run de acao identica no sufixo sem progresso (soft=3, hard=5)
  $run = 1
  for ($i = ($n - 1); $i -gt $cut; $i--) {
    if ($Fingerprints[$i] -ceq $Fingerprints[$i - 1]) { $run += 1 } else { break }
  }
  if ($run -ge 5) { return 'HARD_STALL' }
  if ($run -ge 3) { return 'STALL_SUSPECTED' }
  # 2. ciclo curto 2-4 repetido 3x no tail do sufixo sem progresso
  foreach ($len in @(2, 3, 4)) {
    if ($s -lt ($len * 3)) { continue }
    $tail = @($Fingerprints[($n - $len * 3)..($n - 1)])
    $c1 = ($tail[0..($len - 1)] -join ',')
    $c2 = ($tail[$len..($len * 2 - 1)] -join ',')
    $c3 = ($tail[($len * 2)..($len * 3 - 1)] -join ',')
    if (($c1 -ceq $c2) -and ($c2 -ceq $c3)) { return 'REPEATED_CYCLE' }
  }
  return 'NONE'
}

try {
  # --- 1. stall: fake tool que nunca resolve (child sleep, deadline curta) ---
  $r1 = Invoke-SpikeChild -FilePath $psExe -ArgumentList @('-NoProfile', '-Command', "Write-Output 'HEARTBEAT-noprogress'; Start-Sleep -Seconds 120") -WorkingDirectory $base -TimeoutMs 6000
  Assert-That (([bool]$r1.TimedOut) -and ([string]$r1.Stdout -match 'HEARTBEAT-noprogress')) 'stall sem retorno: timeout com evidencia parcial' ('timeout=' + $r1.TimedOut + ' out=' + [string]$r1.Stdout)
  Assert-That ([int]$r1.ExitCode -eq -1) 'stall sem retorno: ExitCode -1 (sem inventar codigo)' ('rc=' + $r1.ExitCode)

  # --- 2. heartbeats sem mudanca de estado NAO resetam o relogio no-progress ---
  $t0 = [datetime]'2026-09-30T15:00:00Z'
  $heartbeats = @($t0.AddSeconds(60), $t0.AddSeconds(120), $t0.AddSeconds(180))
  $lastProgressAt = $t0  # nenhum evento significativo apos t0
  $now = $t0.AddSeconds(301)
  $noProgressBudget = 300
  $elapsed = ($now - $lastProgressAt).TotalSeconds
  Assert-That ($elapsed -gt $noProgressBudget) 'no-progress medido desde ultimo progresso real, nao do heartbeat' ('elapsed=' + $elapsed)
  $sinceHeartbeat = ($now - $heartbeats[$heartbeats.Count - 1]).TotalSeconds
  Assert-That ($sinceHeartbeat -lt $noProgressBudget) 'guarda: heartbeat recente sozinho nao mascara o stall' ('sinceHeartbeat=' + $sinceHeartbeat)

  # --- 3. acao identica 3x sem progresso => STALL_SUSPECTED; 5x => HARD_STALL ---
  $fp = Get-ActionFingerprint 'shell' 'git status --short' 'repo'
  $seq3 = @($fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $seq3 @($false, $false, $false)) -ceq 'STALL_SUSPECTED') '3x identico sem progresso => STALL_SUSPECTED' (Test-RepetitionClass $seq3 @($false, $false, $false))
  $seq5 = @($fp, $fp, $fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $seq5 @($false, $false, $false, $false, $false)) -ceq 'HARD_STALL') '5x identico sem progresso => HARD_STALL' (Test-RepetitionClass $seq5 @($false, $false, $false, $false, $false))

  # --- 4. ciclo curto A-B-A-B-A-B sem delta => REPEATED_CYCLE ---
  $fa = Get-ActionFingerprint 'shell' 'git status --short' 'repo'
  $fb = Get-ActionFingerprint 'read' 'opencode.json' 'repo'
  $cyc = @($fa, $fb, $fa, $fb, $fa, $fb)
  Assert-That ((Test-RepetitionClass $cyc @($false, $false, $false, $false, $false, $false)) -ceq 'REPEATED_CYCLE') 'ciclo A-B 3x sem delta => REPEATED_CYCLE' (Test-RepetitionClass $cyc @($false, $false, $false, $false, $false, $false))

  # --- 5. iterador limitado declarado com progresso NAO dispara falso positivo ---
  $it = @()
  $pg = @()
  for ($i = 1; $i -le 5; $i++) {
    $it += Get-ActionFingerprint 'shell' ('git diff HEAD~' + $i) 'repo'
    $pg += $true  # cada iteracao entrega evidencia nova (marcador de progresso)
  }
  Assert-That ((Test-RepetitionClass $it $pg) -ceq 'NONE') 'iterador limitado com progresso => NONE' (Test-RepetitionClass $it $pg)

  # --- 6. segredos redigidos antes de persistir o fingerprint ---
  $f1 = Get-ActionFingerprint 'mcp' 'call memory token=abc123' 'remote'
  $f2 = Get-ActionFingerprint 'mcp' 'call memory token=zzz999' 'remote'
  Assert-That (($f1 -ceq $f2) -and ($f1 -notmatch 'abc123') -and ($f1 -notmatch 'zzz999')) 'segredo redigido: tokens distintos geram mesmo fingerprint sem vazar' ($f1)
  $f3a = Get-ActionFingerprint 'shell' 'echo sk-SYNTHETICSECRET-1' 'repo'
  $f3b = Get-ActionFingerprint 'shell' 'echo sk-SYNTHETICSECRET-2' 'repo'
  $f3r = Get-ActionFingerprint 'shell' 'echo <redacted>' 'repo'
  Assert-That (($f3a -ceq $f3b) -and ($f3a -ceq $f3r)) 'canario redigido: segredos distintos convergem para versao redigida' ($f3a + ' vs ' + $f3r)

  # --- 7. progresso real no meio da sequencia quebra a suspeita ---
  $mix = @($fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $mix @($false, $false, $true)) -ceq 'NONE') 'progresso real invalida STALL_SUSPECTED' (Test-RepetitionClass $mix @($false, $false, $true))

  # --- 8. progresso antigo fora da janela NAO mascara stall (review RR-P21-FIX) ---
  $fx = Get-ActionFingerprint 'read' 'CHANGELOG.md' 'repo'
  $stallOld = @($fx, $fp, $fp, $fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $stallOld @($true, $false, $false, $false, $false, $false)) -ceq 'HARD_STALL') 'X,A x5 com progresso so em X => HARD_STALL' (Test-RepetitionClass $stallOld @($true, $false, $false, $false, $false, $false))
  $stallOld3 = @($fx, $fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $stallOld3 @($true, $false, $false, $false)) -ceq 'STALL_SUSPECTED') 'X,A x3 com progresso so em X => STALL_SUSPECTED' (Test-RepetitionClass $stallOld3 @($true, $false, $false, $false))

  # --- 9. ciclo com progresso antigo fora da janela ainda => REPEATED_CYCLE ---
  $cycOld = @($fx, $fa, $fb, $fa, $fb, $fa, $fb)
  Assert-That ((Test-RepetitionClass $cycOld @($true, $false, $false, $false, $false, $false, $false)) -ceq 'REPEATED_CYCLE') 'X,A,B x3 com progresso so em X => REPEATED_CYCLE' (Test-RepetitionClass $cycOld @($true, $false, $false, $false, $false, $false, $false))

  # --- 10. residual review: mesma identidade no progresso inicial nao mascara (sufixo pos-progresso) ---
  $sameSoft = @($fp, $fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $sameSoft @($true, $false, $false, $false)) -ceq 'STALL_SUSPECTED') 'A x4 mesma identidade, progresso so na 1a => STALL_SUSPECTED (sufixo A x3)' (Test-RepetitionClass $sameSoft @($true, $false, $false, $false))
  $sameHard = @($fp, $fp, $fp, $fp, $fp, $fp)
  Assert-That ((Test-RepetitionClass $sameHard @($true, $false, $false, $false, $false, $false)) -ceq 'HARD_STALL') 'A x6 mesma identidade, progresso so na 1a => HARD_STALL (sufixo A x5)' (Test-RepetitionClass $sameHard @($true, $false, $false, $false, $false, $false))
  $cycSame = @($fa, $fb, $fa, $fb, $fa, $fb, $fa)
  Assert-That ((Test-RepetitionClass $cycSame @($true, $false, $false, $false, $false, $false, $false)) -ceq 'REPEATED_CYCLE') 'ciclo mesma identidade no inicio com progresso => REPEATED_CYCLE (sufixo B,A x3)' (Test-RepetitionClass $cycSame @($true, $false, $false, $false, $false, $false, $false))

  Write-Host ''
  Write-Host ('[SUMMARY] pass ' + $script:passed + '/' + $script:total)
  if ($script:passed -ne $script:total) { exit 1 }
  exit 0
}
finally {
  try { if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
