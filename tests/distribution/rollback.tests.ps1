# rollback.tests.ps1 — apply-half restaura original; CAS_CONFLICT com mutacao.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# Parte A: falha no meio do apply -> estado original restaurado ---------------
$TmpA = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbA-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpA -Force | Out-Null
try {
  $ocA = Join-Path $TmpA '.config\opencode'
  New-Item -ItemType Directory -Path $ocA -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocA 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $origText = '{"model":"orig/keep","sentinel":"A1"}' + "`n"
  [IO.File]::WriteAllText((Join-Path $ocA 'opencode.json'), $origText, (New-Object Text.UTF8Encoding $false))
  $origHash = (Get-FileHash -LiteralPath (Join-Path $ocA 'opencode.json') -Algorithm SHA256).Hash
  $outA = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpA -InjectFailureAfter 'apply-half' 2>&1 | Out-String
  $codeA = $LASTEXITCODE
  Assert ($codeA -eq 5) 'apply-half exit 5'
  Assert ($outA -match 'ROLLBACK_COMPLETED') 'ROLLBACK_COMPLETED registrado'
  $afterHash = (Get-FileHash -LiteralPath (Join-Path $ocA 'opencode.json') -Algorithm SHA256).Hash
  Assert ($afterHash -eq $origHash) 'opencode.json original restaurado'
  $dbg = Join-Path $ocA 'agents\debugger.md'
  Assert (-not (Test-Path -LiteralPath $dbg -PathType Leaf)) 'arquivos criados no apply removidos no rollback'
}
finally {
  if (Test-Path -LiteralPath $TmpA) { Remove-Item -LiteralPath $TmpA -Recurse -Force -ErrorAction SilentlyContinue }
}

# Parte A2: falha APOS escrever opencode.json -> JSON + arquivos já alterados restaurados
$TmpA2 = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbA2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpA2 -Force | Out-Null
try {
  $ocA2 = Join-Path $TmpA2 '.config\opencode'
  New-Item -ItemType Directory -Path $ocA2 -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocA2 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $preFiles = @(
    'AGENTS.md',
    'opencode.json',
    'agents\coder.md',
    'agents\debugger.md',
    'skills\hybrid-development\SKILL.md',
    'plugins\orchestration-enforcement.ts'
  )
  [IO.File]::WriteAllText((Join-Path $ocA2 'AGENTS.md'), "# base pre-existente`n", (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText((Join-Path $ocA2 'opencode.json'), '{"model":"orig/keep","sentinel":"A2"}' + "`n", (New-Object Text.UTF8Encoding $false))
  $agDir = Join-Path $ocA2 'agents'
  New-Item -ItemType Directory -Path $agDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $agDir 'coder.md'), "# coder pre`n", (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText((Join-Path $agDir 'debugger.md'), "# debugger pre`n", (New-Object Text.UTF8Encoding $false))
  $skDir = Join-Path $ocA2 'skills\hybrid-development'
  New-Item -ItemType Directory -Path $skDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $skDir 'SKILL.md'), "# skill pre`n", (New-Object Text.UTF8Encoding $false))
  $plDir = Join-Path $ocA2 'plugins'
  New-Item -ItemType Directory -Path $plDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $plDir 'orchestration-enforcement.ts'), "// pre-existente`n", (New-Object Text.UTF8Encoding $false))
  $origHashes = @{}
  foreach ($rel in $preFiles) {
    $p = Join-Path $ocA2 $rel
    $origHashes[$rel] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
  }
  $outA2 = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpA2 -InjectFailureAfter 'apply-json' 2>&1 | Out-String
  $codeA2 = $LASTEXITCODE
  Assert ($codeA2 -eq 5) 'apply-json exit 5'
  Assert ($outA2 -match 'ROLLBACK_COMPLETED') 'apply-json ROLLBACK_COMPLETED'
  foreach ($rel in $preFiles) {
    $p = Join-Path $ocA2 $rel
    $h = ''
    if (Test-Path -LiteralPath $p -PathType Leaf) { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    Assert ($h -eq $origHashes[$rel]) ('apply-json restaura ' + $rel)
  }
  $mfA2 = Join-Path $TmpA2 '.opencode-orchestration\manifest.json'
  Assert (-not (Test-Path -LiteralPath $mfA2 -PathType Leaf)) 'apply-json sem manifest parcial'
}
finally {
  if (Test-Path -LiteralPath $TmpA2) { Remove-Item -LiteralPath $TmpA2 -Recurse -Force -ErrorAction SilentlyContinue }
}

# Parte B: CAS_CONFLICT com mutacao entre preview e apply ----------------------
$TmpB = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rbB-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpB -Force | Out-Null
try {
  $ocB = Join-Path $TmpB '.config\opencode'
  New-Item -ItemType Directory -Path $ocB -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocB 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $ocB 'AGENTS.md'), "# base`n", (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText((Join-Path $ocB 'opencode.json'), '{"model":"base/0"}' + "`n", (New-Object Text.UTF8Encoding $false))
  $installPs = Join-Path $RepoRoot 'install.ps1'
  $mutJob = Start-Job -ScriptBlock {
    param([string]$OcDir)
    for ($i = 0; $i -lt 400; $i++) {
      $baks = @(Get-ChildItem -Directory (Join-Path $OcDir 'backups\oo-*') -ErrorAction SilentlyContinue)
      if ($baks.Count -gt 0) {
        $p = Join-Path $OcDir 'opencode.json'
        [IO.File]::WriteAllText($p, '{"model":"mutated/concurrent"}' + "`n", (New-Object Text.UTF8Encoding $false))
        break
      }
      Start-Sleep -Milliseconds 50
    }
  } -ArgumentList $ocB
  try {
    $outB = powershell -NoProfile -ExecutionPolicy Bypass -File $installPs -TargetHome $TmpB 2>&1 | Out-String
    $codeB = $LASTEXITCODE
  }
  finally {
    Wait-Job $mutJob | Out-Null
    Remove-Job $mutJob -Force -ErrorAction SilentlyContinue
  }
  Assert ($codeB -eq 4) 'CAS mutacao exit 4'
  Assert ($outB -match 'CAS_CONFLICT') 'CAS_CONFLICT listado'
  $curB = [IO.File]::ReadAllText((Join-Path $ocB 'opencode.json'), [Text.Encoding]::UTF8)
  Assert ($curB -match 'mutated/concurrent') 'destino mutado nao foi sobrescrito (sem rollback)'
}
finally {
  if (Test-Path -LiteralPath $TmpB) { Remove-Item -LiteralPath $TmpB -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
