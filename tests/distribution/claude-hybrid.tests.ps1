# claude-hybrid.tests.ps1 — instalador Claude hybrid em ClaudeHome temporario (nunca toca ~/.claude).
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Script = Join-Path $RepoRoot 'scripts\claude\install-claude-hybrid.ps1'
$Utf8 = New-Object Text.UTF8Encoding $false
$Ch = @{ ccedil = [string][char]0x00E7; atilde = [string][char]0x00E3; iacute = [string][char]0x00ED }
$LegacyHeading = '## Orquestra' + $Ch.ccedil + $Ch.atilde + 'o h' + $Ch.iacute + 'brida (Claude + Orca + OpenCode)'
$engine = 'powershell'; if ($PSVersionTable.PSEdition -eq 'Core') { $engine = 'pwsh' }
function Run-Installer([string]$Home_, [string[]]$Extra) {
  $out = & $engine -NoProfile -File $Script -RepoRoot $RepoRoot -ClaudeHome $Home_ @Extra 2>&1
  return @{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
function Run-Uninstaller([string]$OcHome_, [string]$ClaudeHome_) {
  $un = Join-Path $RepoRoot 'uninstall.ps1'
  $out = & $engine -NoProfile -File $un -TargetHome $OcHome_ -ClaudeHome $ClaudeHome_ -ClaudeHybrid 2>&1
  return @{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
function Count([string]$Text, [string]$Needle) { return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count }
$Start = '<!-- opencode-orchestration:claude-hybrid:start -->'
$End = '<!-- opencode-orchestration:claude-hybrid:end -->'

$root = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-claude-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
  # --- 1. fresh install em home vazio + WhatIf nao escreve --------------------
  $h1 = Join-Path $root 'fresh'
  New-Item -ItemType Directory -Path $h1 -Force | Out-Null
  $r = Run-Installer $h1 @('-WhatIf')
  Assert (($r.code -eq 0) -and (-not (Test-Path (Join-Path $h1 'CLAUDE.md')))) 'WhatIf nao escreve nada'
  $r = Run-Installer $h1 @()
  Assert ($r.code -eq 0) 'fresh install exit 0'
  $md = [IO.File]::ReadAllText((Join-Path $h1 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert (((Count $md $Start) -eq 1) -and ((Count $md $End) -eq 1)) 'CLAUDE.md com exatamente 1 bloco marcado'
  foreach ($f in @('SKILL.md', 'references\dispatch-confirmation.md', 'references\opencode-contract.md', 'references\resume.md')) {
    Assert (Test-Path -LiteralPath (Join-Path $h1 ('skills\hybrid-orchestration\' + $f)) -PathType Leaf) ('skill instalada: ' + $f)
  }
  Assert (Test-Path (Join-Path $h1 '.opencode-orchestration-claude.json')) 'manifest criado'
  Assert (-not (Test-Path (Join-Path $h1 'settings.json'))) 'nenhum hook/settings.json criado'

  # --- 2. idempotencia ---------------------------------------------------------
  $before = [IO.File]::ReadAllText((Join-Path $h1 'CLAUDE.md'), [Text.Encoding]::UTF8)
  $r = Run-Installer $h1 @()
  $after = [IO.File]::ReadAllText((Join-Path $h1 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert (($r.code -eq 0) -and ($before -ceq $after) -and ($r.out -match 'Nada a fazer')) 'segundo run sem mudanca'

  # --- 3. preservacao + adocao da secao legada sem marcadores ------------------
  $h2 = Join-Path $root 'legacy'
  New-Item -ItemType Directory -Path (Join-Path $h2 'skills\outra-skill') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $h2 'hooks') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $h2 'skills\outra-skill\SKILL.md'), "outra`n", $Utf8)
  [IO.File]::WriteAllText((Join-Path $h2 'hooks\meu.ps1'), "# hook`n", $Utf8)
  [IO.File]::WriteAllText((Join-Path $h2 'settings.json'), "{`"x`":1}`n", $Utf8)
  $legacy = "# Meu CLAUDE`n`n## Regras do usuario`n`n- nao mexer`n`n" + $LegacyHeading + "`n`n- texto antigo da secao`n`n## Final do usuario`n`n- tambem fica`n"
  [IO.File]::WriteAllText((Join-Path $h2 'CLAUDE.md'), $legacy, $Utf8)
  $r = Run-Installer $h2 @()
  $md = [IO.File]::ReadAllText((Join-Path $h2 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert ($r.code -eq 0 -and $r.out -match 'ADOPT') 'adocao reportada'
  Assert ((Count $md $LegacyHeading) -eq 1) 'secao legada nao duplicada (1 heading)'
  Assert (((Count $md $Start) -eq 1) -and (-not $md.Contains('texto antigo da secao'))) 'legado substituido pelo bloco marcado'
  Assert ($md.Contains('## Regras do usuario') -and $md.Contains('- nao mexer') -and $md.Contains('## Final do usuario') -and $md.Contains('- tambem fica')) 'secoes do usuario antes e depois preservadas'
  Assert (((Get-Content -LiteralPath (Join-Path $h2 'settings.json') -Raw).Trim()) -eq '{"x":1}') 'settings.json intacto'
  Assert ((Test-Path (Join-Path $h2 'skills\outra-skill\SKILL.md')) -and (Test-Path (Join-Path $h2 'hooks\meu.ps1'))) 'outras skills/hooks intactos'
  $bak = @(Get-ChildItem -LiteralPath (Join-Path $h2 'backups\opencode-orchestration-claude') -Recurse -Filter 'CLAUDE.md' -ErrorAction SilentlyContinue)
  Assert (($bak.Count -eq 1) -and (([IO.File]::ReadAllText($bak[0].FullName, [Text.Encoding]::UTF8)) -ceq $legacy)) 'backup byte-exato do CLAUDE.md original'

  # --- 4. skill editada pelo usuario e preservada (CONFLICT) -------------------
  $skillFile = Join-Path $h2 'skills\hybrid-orchestration\SKILL.md'
  [IO.File]::WriteAllText($skillFile, "# minha versao`n", $Utf8)
  $r = Run-Installer $h2 @()
  Assert (($r.code -eq 0) -and ($r.out -match 'CONFLICT') -and ((Get-Content -LiteralPath $skillFile -Raw).Trim() -eq '# minha versao')) 'skill editada preservada e reportada como CONFLICT'

  # --- 5. uninstall: remove so o gerenciado ------------------------------------
  $r = Run-Installer $h2 @('-Uninstall')
  $md = [IO.File]::ReadAllText((Join-Path $h2 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert ($r.code -eq 0 -and (-not $md.Contains($Start)) -and (-not $md.Contains($End))) 'uninstall remove o bloco'
  Assert ($md.Contains('## Regras do usuario') -and $md.Contains('## Final do usuario')) 'uninstall preserva secoes do usuario'
  Assert ((Test-Path $skillFile) -and (-not (Test-Path (Join-Path $h2 'skills\hybrid-orchestration\references')))) 'uninstall preserva skill editada e remove arquivos gerenciados intactos'
  Assert (Test-Path (Join-Path $h2 '.opencode-orchestration-claude.json')) 'uninstall parcial preserva manifest (registro de conflito da skill)'
  $r = Run-Installer $h1 @('-Uninstall')
  Assert (($r.code -eq 0) -and (-not (Test-Path (Join-Path $h1 'skills\hybrid-orchestration'))) -and (-not (Test-Path (Join-Path $h1 '.opencode-orchestration-claude.json')))) 'uninstall limpo remove skill e manifest (rollback standalone)'

  # --- 6. standalone: install.ps1 sem -ClaudeHome/-ClaudeHybrid nao referencia ~/.claude
  $inst = Get-Content -LiteralPath (Join-Path $RepoRoot 'install.ps1') -Raw
  Assert ($inst -match 'ClaudeHybrid') 'install.ps1 expoe switch -ClaudeHybrid'

  # --- 7. P0-01: bloco editado diverge do manifest -> CONFLICT preservado -----
  $h3 = Join-Path $root 'conflict-block'
  New-Item -ItemType Directory -Path $h3 -Force | Out-Null
  $r = Run-Installer $h3 @()
  Assert ($r.code -eq 0) 'P0-01 setup: install em home temporario'
  $bakDir3 = Join-Path $h3 'backups\opencode-orchestration-claude\preexistente'
  New-Item -ItemType Directory -Path $bakDir3 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $bakDir3 'CLAUDE.md'), "backup original`n", $Utf8)
  $md3 = Join-Path $h3 'CLAUDE.md'
  $orig = [IO.File]::ReadAllText($md3, [Text.Encoding]::UTF8)
  $customLine = '- LINHA CUSTOMIZADA PELO USUARIO'
  $pos = $orig.IndexOf($Start) + $Start.Length
  $edited = $orig.Substring(0, $pos) + "`n`n" + $customLine + "`n" + $orig.Substring($pos)
  [IO.File]::WriteAllText($md3, $edited, $Utf8)
  $r = Run-Installer $h3 @()
  $after = [IO.File]::ReadAllText($md3, [Text.Encoding]::UTF8)
  Assert (($r.code -eq 0) -and ($r.out -match 'CONFLICT')) 'P0-01.2: update reporta CONFLICT'
  Assert ($after.Contains($customLine)) 'P0-01.2: conteudo personalizado preservado no update'
  Assert (((Count $after $Start) -eq 1) -and ((Count $after $End) -eq 1)) 'P0-01.3: bloco marcado intacto (nao reescrito)'
  $bakKept = (Test-Path (Join-Path $bakDir3 'CLAUDE.md')) -and ([IO.File]::ReadAllText((Join-Path $bakDir3 'CLAUDE.md'), [Text.Encoding]::UTF8) -ceq "backup original`n")
  Assert $bakKept 'P0-01.4: backup existente preservado'
  $r = Run-Installer $h3 @('-Uninstall')
  $afterUn = [IO.File]::ReadAllText($md3, [Text.Encoding]::UTF8)
  Assert (($r.code -eq 0) -and ($r.out -match 'CONFLICT')) 'P0-01.2/3: uninstall reporta CONFLICT'
  Assert ($afterUn.Contains($customLine)) 'P0-01.2/3: uninstall preserva bloco editado'
  Assert (Test-Path (Join-Path $h3 '.opencode-orchestration-claude.json')) 'P0-01.5: manifest preservado na desinstalacao parcial'

  # --- 8. P0-02: uninstall -ClaudeHybrid preserva instalacao OpenCode ---------
  $hoc = Join-Path $root 'oc-home'
  $ocDir = Join-Path $hoc '.config\opencode'
  New-Item -ItemType Directory -Path (Join-Path $ocDir 'agents') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocDir 'plugins') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $hoc '.opencode-orchestration') -Force | Out-Null
  $agentPath = Join-Path $ocDir 'agents\coder.md'
  $pluginPath = Join-Path $ocDir 'plugins\orchestration-enforcement.js'
  $cfgPath = Join-Path $ocDir 'opencode.json'
  [IO.File]::WriteAllText($agentPath, "# coder`n", $Utf8)
  [IO.File]::WriteAllText($pluginPath, "// plugin`n", $Utf8)
  [IO.File]::WriteAllText($cfgPath, "{`"model`":`"x`",`"mcp`":{}}`n", $Utf8)
  $mf = [ordered]@{
    schema = 1
    runtime = [ordered]@{ id = 'opencode-v2' }
    managed_files = @(
      [ordered]@{ relative = 'agents/coder.md'; sha256 = (Get-FileHash -LiteralPath $agentPath -Algorithm SHA256).Hash }
      [ordered]@{ relative = 'plugins/orchestration-enforcement.js'; sha256 = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash }
    )
    config_snapshot = [ordered]@{}
  }
  [IO.File]::WriteAllText((Join-Path $hoc '.opencode-orchestration\manifest.json'), (($mf | ConvertTo-Json -Depth 8) + "`n"), $Utf8)
  $hc = Join-Path $root 'claude-only'
  New-Item -ItemType Directory -Path $hc -Force | Out-Null
  $r = Run-Installer $hc @()
  Assert ($r.code -eq 0) 'P0-02 setup: integracao Claude instalada'
  $r = Run-Uninstaller $hoc $hc
  $ocManifest = Join-Path $hoc '.opencode-orchestration\manifest.json'
  Assert ($r.code -eq 0) 'P0-02: uninstall -ClaudeHybrid exit 0'
  Assert ((Test-Path $agentPath) -and (Test-Path $pluginPath) -and (Test-Path $cfgPath) -and (Test-Path $ocManifest)) 'P0-02: instalacao OpenCode preservada (agentes, plugin, config, manifest)'
  Assert (($r.out -notmatch '\[uninstall\] runtime=') -and ($r.out -notmatch 'Backup pre-uninstall')) 'P0-02: fluxo OpenCode uninstall nao executado'
  $hcText = [IO.File]::ReadAllText((Join-Path $hc 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert ((-not $hcText.Contains($Start)) -and (-not $hcText.Contains($End))) 'P0-02: bloco Claude removido'
  Assert ((-not (Test-Path (Join-Path $hc 'skills\hybrid-orchestration'))) -and (-not (Test-Path (Join-Path $hc '.opencode-orchestration-claude.json')))) 'P0-02: skill e manifest Claude removidos'
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("claude-hybrid: pass=" + $pass + " fail=" + $fail)
if ($fail -gt 0) { exit 1 }
exit 0
