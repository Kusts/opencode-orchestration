# rollback.tests.ps1 — P9.1: rollback COMPLETO do estado owned/managed.
#
# Contratos exercidos:
# - Falha injetada no apply (apply-half / apply-json) => exit 5
# - Saida DEVE conter ROLLBACK_COMPLETED e NAO DEVE conter ROLLBACK_REQUIRED
# - snapshot(antes) == snapshot(depois) sobre TODO o estado owned/managed:
#   AGENTS.md, opencode.json, agents/*, skills gerenciadas/*, plugin e
#   manifest — inclusive existencia/ausencia de diretorios e arquivos.
# - Cenario A (fresh): arquivos criados no apply deixam de existir.
# - Cenario B (upgrade): estado A pre-existente volta byte/hash-equivalente.
# ROLLBACK_REQUIRED observado em cenario que espera rollback completo = FAIL.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-RelTree([string]$RootDir, [string[]]$ExcludeDirs) {
  # mapa rel -> ('DIR' | sha256). RelativePath composto apenas por Name
  # (imune a canonicalizacao de prefixo do enumerador). Exclui volateis
  # (backups) e dependencia externa do usuario (node_modules).
  $rows = @{}
  if (-not (Test-Path -LiteralPath $RootDir -PathType Container)) { return $rows }
  foreach ($item in @(Get-ChildItem -LiteralPath $RootDir -Force -ErrorAction SilentlyContinue)) {
    if ($ExcludeDirs -contains $item.Name) { continue }
    if ($item.PSIsContainer) {
      $rows[$item.Name] = 'DIR'
      $child = Get-RelTree $item.FullName $ExcludeDirs
      foreach ($k in @($child.Keys)) {
        $rows[($item.Name + '\' + $k)] = $child[$k]
      }
    }
    else {
      $rows[$item.Name] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
  }
  return $rows
}

function Get-ManagedSnapshot([string]$Home2) {
  # estado owned/managed: .config\opencode (menos backups/node_modules) +
  # .opencode-orchestration inteiro (manifest + evidence do usuario).
  $oc = Join-Path $Home2 '.config\opencode'
  $snap = @{}
  $ocTree = Get-RelTree $oc @('backups', 'node_modules')
  foreach ($k in @($ocTree.Keys)) {
    $snap['.config\opencode\' + $k] = $ocTree[$k]
  }
  $mgRoot = Join-Path $Home2 '.opencode-orchestration'
  if (Test-Path -LiteralPath $mgRoot) {
    $mgTree = Get-RelTree $mgRoot @()
    foreach ($k in @($mgTree.Keys)) {
      $snap['.opencode-orchestration\' + $k] = $mgTree[$k]
    }
  }
  else {
    $snap['.opencode-orchestration'] = 'ABSENT'
  }
  return $snap
}

function Test-SnapshotEqual($A, $B) {
  if ($A.Count -ne $B.Count) { return $false }
  foreach ($k in $A.Keys) {
    if (-not $B.ContainsKey($k)) { return $false }
    if ($A[$k] -ne $B[$k]) { return $false }
  }
  return $true
}

function New-SeedHome([string]$Home2) {
  # Cenario B: estado A pre-existente em TODOS os grupos gerenciados.
  # Inclui arquivos em CRLF: o rollback deve restaurar BYTES exatos (F1) —
  # restaurar via texto normalizaria EOL e o hash divergiria.
  $oc = Join-Path $Home2 '.config\opencode'
  New-Item -ItemType Directory -Path (Join-Path $oc 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $utf8 = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $oc 'AGENTS.md'), "# base A do usuario`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $oc 'opencode.json'), ('{"model":"orig/keep","sentinel":"A"}' + "`r`n"), $utf8)
  New-Item -ItemType Directory -Path (Join-Path $oc 'agents') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $oc 'agents\coder.md'), "# coder A`r`n# segunda linha CRLF`r`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $oc 'agents\debugger.md'), "# debugger A`n", $utf8)
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    New-Item -ItemType Directory -Path (Join-Path $oc ('skills\' + $s)) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $oc ('skills\' + $s + '\SKILL.md')), ("# skill A " + $s + "`n"), $utf8)
  }
  New-Item -ItemType Directory -Path (Join-Path $oc 'skills\hybrid-development\references') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $oc 'skills\hybrid-development\references\runtimes.md'), "# ref A`n", $utf8)
  New-Item -ItemType Directory -Path (Join-Path $oc 'plugins') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $oc 'plugins\orchestration-enforcement.ts'), "// pre A`n", $utf8)
  New-Item -ItemType Directory -Path (Join-Path $Home2 '.opencode-orchestration') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $Home2 '.opencode-orchestration\manifest.json'), '{"sentinel":"manifest-A"}' + "`n", $utf8)
}

# ---- Cenario A: fresh state — arquivos criados no apply deixam de existir ----
$TmpA = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbA-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $TmpA '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
try {
  $ocA = Join-Path $TmpA '.config\opencode'
  $utf8 = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $ocA 'opencode.json'), '{"model":"orig/keep","sentinel":"A1"}' + "`n", $utf8)
  $beforeA = Get-ManagedSnapshot $TmpA
  $outA = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpA -InjectFailureAfter 'apply-half' 2>&1 | Out-String
  $codeA = $LASTEXITCODE
  Assert ($codeA -eq 5) 'A: apply-half exit 5'
  Assert ($outA -match 'ROLLBACK_COMPLETED') 'A: ROLLBACK_COMPLETED registrado'
  Assert ($outA -notmatch 'ROLLBACK_REQUIRED') 'A: ROLLBACK_REQUIRED ausente'
  $afterA = Get-ManagedSnapshot $TmpA
  Assert (Test-SnapshotEqual $beforeA $afterA) 'A: snapshot managed integral antes==depois (agents, skills, plugin, AGENTS.md, opencode.json, manifest, dirs)'
  $dbg = Join-Path $ocA 'agents\debugger.md'
  Assert (-not (Test-Path -LiteralPath $dbg -PathType Leaf)) 'A: arquivos criados no apply removidos no rollback'
  $skDir = Join-Path $ocA 'skills\hybrid-development'
  Assert (-not (Test-Path -LiteralPath $skDir -PathType Container)) 'A: diretorio de skill criado no apply removido (sem dir orfao)'
  $mfA = Join-Path $TmpA '.opencode-orchestration\manifest.json'
  Assert (-not (Test-Path -LiteralPath $mfA -PathType Leaf)) 'A: sem manifest parcial'
}
finally {
  if (Test-Path -LiteralPath $TmpA) { Remove-Item -LiteralPath $TmpA -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- Cenario B: upgrade — estado A volta byte/hash-equivalente ----------------
$TmpB = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbB-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpB -Force | Out-Null
try {
  New-SeedHome $TmpB
  $beforeB = Get-ManagedSnapshot $TmpB
  $outB = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpB -InjectFailureAfter 'apply-json' 2>&1 | Out-String
  $codeB = $LASTEXITCODE
  Assert ($codeB -eq 5) 'B: apply-json exit 5 (falha apos escrever opencode.json, ultimo op)'
  Assert ($outB -match 'ROLLBACK_COMPLETED') 'B: ROLLBACK_COMPLETED registrado'
  Assert ($outB -notmatch 'ROLLBACK_REQUIRED') 'B: ROLLBACK_REQUIRED ausente'
  $afterB = Get-ManagedSnapshot $TmpB
  Assert (Test-SnapshotEqual $beforeB $afterB) 'B: snapshot managed integral antes==depois (todas as skills restauradas)'
  $ocB = Join-Path $TmpB '.config\opencode'
  foreach ($rel in @(
    'AGENTS.md',
    'agents\coder.md',
    'agents\debugger.md',
    'skills\dispatching-parallel-agents\SKILL.md',
    'skills\hybrid-development\SKILL.md',
    'skills\hybrid-development\references\runtimes.md',
    'skills\subagent-driven-development\SKILL.md',
    'skills\using-superpowers\SKILL.md',
    'skills\verification-before-completion\SKILL.md',
    'plugins\orchestration-enforcement.ts')) {
    if ($rel -eq 'opencode.json') { continue }
    $p = Join-Path $ocB $rel
    Assert (Test-Path -LiteralPath $p -PathType Leaf) ('B: estado A presente apos rollback: ' + $rel)
  }
  $cur = [IO.File]::ReadAllText((Join-Path $ocB 'opencode.json'), [Text.Encoding]::UTF8)
  Assert ($cur -match 'sentinel') 'B: opencode.json conteudo A restaurado'
}
finally {
  if (Test-Path -LiteralPath $TmpB) { Remove-Item -LiteralPath $TmpB -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- Cenario C: CAS_CONFLICT nao e rollback (nada aplicado, sem mensagem) -----
# Mutacao concorrente real via Start-Job: corre uma corrida com o install.
# Para evitar flake de agendamento, ate 3 tentativas; o install filho usa o
# MESMO engine do pai (cada engine exercita o proprio caminho CAS).
$TmpC = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbC-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpC -Force | Out-Null
try {
  $ocC = Join-Path $TmpC '.config\opencode'
  New-Item -ItemType Directory -Path (Join-Path $ocC 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $utf8 = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $ocC 'AGENTS.md'), "# base`n", $utf8)
  [IO.File]::WriteAllText((Join-Path $ocC 'opencode.json'), '{"model":"base/0"}' + "`n", $utf8)
  $installPs = Join-Path $RepoRoot 'install.ps1'
  $engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
  $codeC = -1
  $outC = ''
  $attempts = 0
  while (($codeC -ne 4) -and ($attempts -lt 3)) {
    $attempts += 1
    if ($attempts -gt 1) {
      # Reset COMPLETO: uma tentativa anterior pode ter concluido install
      # (exit 0, mutacao nao venceu a corrida) e alterado o home.
      Remove-Item -LiteralPath $TmpC -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Path (Join-Path $ocC 'node_modules\@opencode-ai\plugin') -Force | Out-Null
      [IO.File]::WriteAllText((Join-Path $ocC 'AGENTS.md'), "# base`n", $utf8)
    }
    # estado base por tentativa
    [IO.File]::WriteAllText((Join-Path $ocC 'opencode.json'), '{"model":"base/0"}' + "`n", $utf8)
    foreach ($stale in @(Get-ChildItem -Directory (Join-Path $ocC 'backups\oo-*') -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $mutJob = Start-Job -ScriptBlock {
      param([string]$OcDir)
      for ($i = 0; $i -lt 600; $i++) {
        $baks = @(Get-ChildItem -Directory (Join-Path $OcDir 'backups\oo-*') -ErrorAction SilentlyContinue)
        if ($baks.Count -gt 0) {
          $p = Join-Path $OcDir 'opencode.json'
          [IO.File]::WriteAllText($p, '{"model":"mutated/concurrent"}' + "`n", (New-Object Text.UTF8Encoding $false))
          break
        }
        Start-Sleep -Milliseconds 25
      }
    } -ArgumentList $ocC
    try {
      $outC = & $engine -NoProfile -ExecutionPolicy Bypass -File $installPs -TargetHome $TmpC 2>&1 | Out-String
      $codeC = $LASTEXITCODE
    }
    finally {
      Wait-Job $mutJob | Out-Null
      Remove-Job $mutJob -Force -ErrorAction SilentlyContinue
    }
  }
  Assert ($codeC -eq 4) ('C: CAS mutacao exit 4 (tentativas: ' + $attempts + ')')
  Assert ($outC -match 'CAS_CONFLICT') 'C: CAS_CONFLICT listado'
  Assert ($outC -notmatch 'ROLLBACK_REQUIRED') 'C: CAS aborta SEM rollback (nenhuma mensagem de rollback)'
  $curC = [IO.File]::ReadAllText((Join-Path $ocC 'opencode.json'), [Text.Encoding]::UTF8)
  Assert ($curC -match 'mutated/concurrent') 'C: destino mutado nao foi sobrescrito'
}
finally {
  if (Test-Path -LiteralPath $TmpC) { Remove-Item -LiteralPath $TmpC -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- Cenario D: falha na gravacao do manifest — evidence do usuario intacto --
$TmpD = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbD-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpD -Force | Out-Null
try {
  $ocD = Join-Path $TmpD '.config\opencode'
  New-Item -ItemType Directory -Path (Join-Path $ocD 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $utf8 = New-Object Text.UTF8Encoding $false
  [IO.File]::WriteAllText((Join-Path $ocD 'opencode.json'), '{"model":"orig/keep","sentinel":"D"}' + "`n", $utf8)
  # evidence pre-existente do usuario sob .opencode-orchestration
  New-Item -ItemType Directory -Path (Join-Path $TmpD '.opencode-orchestration\evidence') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $TmpD '.opencode-orchestration\evidence\meus-dados.txt'), "dados do usuario`n", $utf8)
  $beforeD = Get-ManagedSnapshot $TmpD
  $outD = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpD -InjectFailureAfter 'manifest' 2>&1 | Out-String
  $codeD = $LASTEXITCODE
  Assert ($codeD -eq 5) 'D: manifest-injected exit 5'
  Assert ($outD -match 'ROLLBACK_COMPLETED') 'D: ROLLBACK_COMPLETED registrado'
  Assert ($outD -notmatch 'ROLLBACK_REQUIRED') 'D: ROLLBACK_REQUIRED ausente'
  $afterD = Get-ManagedSnapshot $TmpD
  Assert (Test-SnapshotEqual $beforeD $afterD) 'D: snapshot managed integral antes==depois (opencode.json restaurado; sem manifest; evidence preservada)'
  Assert (Test-Path -LiteralPath (Join-Path $TmpD '.opencode-orchestration\evidence\meus-dados.txt') -PathType Leaf) 'D: evidence do usuario preservada'
  Assert (-not (Test-Path -LiteralPath (Join-Path $TmpD '.opencode-orchestration\manifest.json') -PathType Leaf)) 'D: sem manifest parcial'
  $curD = [IO.File]::ReadAllText((Join-Path $ocD 'opencode.json'), [Text.Encoding]::UTF8)
  Assert ($curD -match 'sentinel') 'D: opencode.json conteudo original restaurado'
}
finally {
  if (Test-Path -LiteralPath $TmpD) { Remove-Item -LiteralPath $TmpD -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
