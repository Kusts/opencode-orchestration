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
# Impressao digital SOMENTE LEITURA de um ClaudeHome: alvos gerenciados + nomes
# de topo. Usada para provar que o guardrail nao escreveu/removeu nada no perfil
# real nem no perfil sandboxado. Nunca imprime conteudo de arquivo.
function Get-ClaudeStamp([string]$Home_) {
  if (-not (Test-Path -LiteralPath $Home_)) { return 'ABSENT' }
  $lines = New-Object System.Collections.ArrayList
  foreach ($rel in @('CLAUDE.md', '.opencode-orchestration-claude.json', 'settings.json', 'skills\hybrid-orchestration\SKILL.md')) {
    $p = Join-Path $Home_ $rel
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $it = Get-Item -LiteralPath $p -Force
      $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
      [void]$lines.Add(($rel + '|' + $it.Length + '|' + $it.LastWriteTimeUtc.Ticks + '|' + $h))
    } else { [void]$lines.Add(($rel + '|ABSENT')) }
  }
  $top = @(Get-ChildItem -LiteralPath $Home_ -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
  [void]$lines.Add(('TOP|' + ($top -join ',')))
  return ($lines -join "`n")
}
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
  Assert (($r.code -eq 0) -and ($before -ceq $after) -and (($r.out -match 'Nada a fazer') -or ($r.out -match '\[SKIP\]')) -and ($r.out -notmatch '\[(UPDATE|CREATE|ADOPT|CONFLICT)\]')) 'segundo run sem mudanca'

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

  # --- 9. P1-04: install.ps1 -ClaudeHybrid ponta a ponta em homes temporarios ---
  $inst = Join-Path $RepoRoot 'install.ps1'
  $oc9 = Join-Path $root 'p104-oc'
  $ch9 = Join-Path $root 'p104-claude'
  New-Item -ItemType Directory -Path $oc9 -Force | Out-Null
  New-Item -ItemType Directory -Path $ch9 -Force | Out-Null
  $r = & $engine -NoProfile -File $inst -ClaudeHybrid -TargetHome $oc9 -ClaudeHome $ch9 -WhatIf 2>&1
  $code9 = $LASTEXITCODE
  Assert ($code9 -eq 0) 'P1-04.1: install.ps1 -ClaudeHybrid -WhatIf exit 0'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ch9 'CLAUDE.md'))) 'P1-04.1: WhatIf nao escreve CLAUDE.md'
  $r = & $engine -NoProfile -File $inst -ClaudeHybrid -TargetHome $oc9 -ClaudeHome $ch9 2>&1
  $code9 = $LASTEXITCODE
  Assert ($code9 -eq 0) 'P1-04.2: install.ps1 -ClaudeHybrid aplica exit 0'
  Assert ((Test-Path -LiteralPath (Join-Path $ch9 'skills\hybrid-orchestration\SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $oc9 '.opencode-orchestration\manifest.json'))) 'P1-04.2: OpenCode + Claude instalados'
  $skill9 = [IO.File]::ReadAllText((Join-Path $ch9 'skills\hybrid-orchestration\SKILL.md'), [Text.Encoding]::UTF8)
  Assert (($skill9 -match '(?m)^name:\s*hybrid-orchestration\s*$') -and ($skill9 -match '(?m)^description:')) 'P1-04.3: SKILL.md com frontmatter name/description valido'
  $scratch9 = Join-Path $root 'p104-scratch'
  New-Item -ItemType Directory -Path (Join-Path $scratch9 'source') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'source\claude') -Destination (Join-Path $scratch9 'source\claude') -Recurse -Force
  [IO.File]::AppendAllText((Join-Path $scratch9 'source\claude\skills\hybrid-orchestration\SKILL.md'), "`n<!-- CERT-UPDATE-MARKER -->", $Utf8)
  $r = & $engine -NoProfile -File $Script -RepoRoot $scratch9 -ClaudeHome $ch9 2>&1
  $code9 = $LASTEXITCODE
  $text9 = ($r -join "`n")
  Assert (($code9 -eq 0) -and ($text9 -match '\[UPDATE\] skills/hybrid-orchestration/SKILL.md')) 'P1-04.4: fonte alterada gera UPDATE'
  $skill9b = [IO.File]::ReadAllText((Join-Path $ch9 'skills\hybrid-orchestration\SKILL.md'), [Text.Encoding]::UTF8)
  Assert ($skill9b.Contains('CERT-UPDATE-MARKER')) 'P1-04.4: conteudo atualizado copiado'
  $r = Run-Uninstaller $oc9 $ch9
  Assert (($r.code -eq 0) -and (-not (Test-Path -LiteralPath (Join-Path $ch9 'skills\hybrid-orchestration')))) 'P1-04.5: uninstall -ClaudeHybrid remove skill'

  # --- 10. Guardrail de destino no uninstall.ps1 -ClaudeHybrid ------------------
  # NUNCA usa o perfil real como destino: USERPROFILE/HOME sao sandboxados apenas
  # nos processos filhos. O perfil real e apenas inspecionado (leitura) antes/depois.
  $realProfile = [Environment]::GetFolderPath('UserProfile')
  $realClaude = Join-Path $realProfile '.claude'
  $realBefore = Get-ClaudeStamp $realClaude

  $sbRoot = Join-Path $root 'guard'
  $sbProfile = Join-Path $sbRoot 'profile'
  $sbClaude = Join-Path $sbProfile '.claude'
  New-Item -ItemType Directory -Path $sbClaude -Force | Out-Null
  $r = Run-Installer $sbClaude @()
  Assert ($r.code -eq 0) 'GUARD setup: install no ClaudeHome do perfil sandboxado'
  $sbBefore = Get-ClaudeStamp $sbClaude

  $oldUser = $env:USERPROFILE
  $oldHome = $env:HOME
  try {
    $env:USERPROFILE = $sbProfile
    $env:HOME = $sbProfile

    # (a) sem -ClaudeHome e sem a flag: falha do guard ANTES de qualquer escrita.
    # O stderr esperado vira ErrorRecord no PS 5.1 com 2>&1 + EAP=Stop; abrir
    # o escopo apenas nesta chamada (restaurado no finally).
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $out = & $engine -NoProfile -File (Join-Path $RepoRoot 'uninstall.ps1') -ClaudeHybrid 2>&1
      $gCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    $gText = ($out -join "`n")
    Assert ($gCode -ne 0) 'GUARD: sem -ClaudeHome e sem flag => exit != 0'
    Assert ($gText -match 'MUTATING_TARGET_REQUIRES_EXPLICIT_PATH') 'GUARD: codigo MUTATING_TARGET_REQUIRES_EXPLICIT_PATH na saida'
    Assert ($gText -notmatch 'Claude hybrid ->') 'GUARD: desinstalador Claude nao foi invocado (falha previa)'
    Assert ((Get-ClaudeStamp $sbClaude) -ceq $sbBefore) 'GUARD: perfil sandboxado intacto (nenhuma escrita/remocao)'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sbClaude 'backups'))) 'GUARD: nenhum backup criado no sandbox'
    Assert ((Get-ClaudeStamp $realClaude) -ceq $realBefore) 'GUARD: ~/.claude real intacto (hash/metadados)'

    # (b) opt-in explicito apontando ao perfil sandboxado: funciona
    $out = & $engine -NoProfile -File (Join-Path $RepoRoot 'uninstall.ps1') -ClaudeHybrid -ClaudeHome $sbClaude -AllowUserProfileTarget 2>&1
    Assert ($LASTEXITCODE -eq 0) 'GUARD: -AllowUserProfileTarget no perfil sandboxado => exit 0'
    $sbText = [IO.File]::ReadAllText((Join-Path $sbClaude 'CLAUDE.md'), [Text.Encoding]::UTF8)
    Assert ((-not $sbText.Contains($Start)) -and (-not $sbText.Contains($End))) 'GUARD: bloco removido com opt-in'
    Assert (-not (Test-Path (Join-Path $sbClaude '.opencode-orchestration-claude.json'))) 'GUARD: manifest removido com opt-in'
    Assert ((Get-ClaudeStamp $realClaude) -ceq $realBefore) 'GUARD: ~/.claude real intacto apos opt-in no sandbox'
  }
  finally {
    $env:USERPROFILE = $oldUser
    $env:HOME = $oldHome
  }

  # (c) regressao: -ClaudeHome temporario explicito continua funcionando sem flag
  $hc10 = Join-Path $root 'guard-explicit-temp'
  New-Item -ItemType Directory -Path $hc10 -Force | Out-Null
  $r = Run-Installer $hc10 @()
  Assert ($r.code -eq 0) 'GUARD setup: install em ClaudeHome temporario explicito'
  $r = Run-Uninstaller $root $hc10
  $txt10 = [IO.File]::ReadAllText((Join-Path $hc10 'CLAUDE.md'), [Text.Encoding]::UTF8)
  Assert (($r.code -eq 0) -and (-not $txt10.Contains($Start))) 'GUARD: -ClaudeHome temporario sem flag => exit 0 e bloco removido (regressao P0-02)'
  Assert ((Get-ClaudeStamp $realClaude) -ceq $realBefore) 'GUARD: ~/.claude real intacto ao final da secao'

  # --- 11. Fonte Claude única: fidelidade, upgrade, idempotência e policy -------
  $h11 = Join-Path $root 'source-fidelity'
  New-Item -ItemType Directory -Path $h11 -Force | Out-Null
  $r = Run-Installer $h11 @()
  Assert ($r.code -eq 0) 'AC1: install em ClaudeHome vazio'
  $sourceSkill = Join-Path $RepoRoot 'source\claude\skills\hybrid-orchestration'
  $targetSkill = Join-Path $h11 'skills\hybrid-orchestration'
  foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceSkill -Recurse -File)) {
    $relative = $sourceFile.FullName.Substring($sourceSkill.Length).TrimStart('\','/').Replace('\','/')
    $targetFile = Join-Path $targetSkill ($relative.Replace('/','\'))
    $sameHash = (Test-Path -LiteralPath $targetFile -PathType Leaf) -and
      ((Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash)
    Assert $sameHash ('AC1: SHA256 instalado igual à fonte: ' + $relative)
  }
  $sourceBlock = [IO.File]::ReadAllText((Join-Path $RepoRoot 'source\claude\CLAUDE.hybrid.md'), [Text.Encoding]::UTF8)
  $targetBlock = [IO.File]::ReadAllText((Join-Path $h11 'CLAUDE.md'), [Text.Encoding]::UTF8)
  $startAt = $targetBlock.IndexOf($Start) + $Start.Length
  $endAt = $targetBlock.IndexOf($End)
  $installedBody = $targetBlock.Substring($startAt, $endAt - $startAt)
  $normalize = { param($s) (($s -replace "`r`n", "`n").Trim()) }
  Assert ((& $normalize $installedBody) -ceq (& $normalize $sourceBlock)) 'AC1: corpo instalado igual à fonte (EOL normalizado/Trim)'
  $r = Run-Installer $h11 @()
  Assert (($r.code -eq 0) -and ($r.out -notmatch '\[(UPDATE|CREATE|ADOPT|CONFLICT)\]') -and (($r.out -match '\[SKIP\]') -or ($r.out -match 'Nada a fazer'))) 'AC2: segunda instalação idempotente'

  $scratch11 = Join-Path $root 'upgrade-scratch'
  New-Item -ItemType Directory -Path (Join-Path $scratch11 'source') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'source\claude') -Destination (Join-Path $scratch11 'source\claude') -Recurse -Force
  $oldContent = [IO.File]::ReadAllText((Join-Path $scratch11 'source\claude\skills\hybrid-orchestration\SKILL.md'), [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText((Join-Path $scratch11 'source\claude\skills\hybrid-orchestration\SKILL.md'), ($oldContent + "`n<!-- upgrade-fixture -->"), $Utf8)
  $upgradeHome = Join-Path $root 'upgrade-home'
  New-Item -ItemType Directory -Path $upgradeHome -Force | Out-Null
  $r = & $engine -NoProfile -File $Script -RepoRoot $scratch11 -ClaudeHome $upgradeHome 2>&1
  $oldCode = $LASTEXITCODE
  $r = Run-Installer $upgradeHome @()
  Assert (($oldCode -eq 0) -and ($r.code -eq 0) -and ($r.out -match '\[UPDATE\] skills/hybrid-orchestration/SKILL.md')) 'AC2: upgrade genérico reporta UPDATE'

  $policyFiles = @((Join-Path $RepoRoot 'source\claude\skills\hybrid-orchestration\SKILL.md')) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'source\claude\skills\hybrid-orchestration\references') -Filter '*.md' -File | ForEach-Object { $_.FullName })
  $policyText = ($policyFiles | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`n"
  $placementRows = @($policyText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\|.*(new-child|new-top-level).*\|$' })
  Assert (($placementRows.Count -ge 2) -and ($policyText -match 'checkout exclusivo')) 'AC4: placement current restrito e new-child/new-top-level definidos'
  $unsafeCurrent = @($policyText -split "`n" | Where-Object { $_ -match '--worktree\s+current' -and $_ -notmatch 'só para leitura|somente.*leitura|único escritor|escritor único|checkout exclusivo' })
  Assert ($unsafeCurrent.Count -eq 0) 'AC4: sem current como padrão geral de escrita'
  Assert (($policyText -notmatch '(?i)edição trivial direta em missão') -and ($policyText -notmatch '(?i)edição trivial.*direto.*híbrido')) 'AC4: sem autorização de edição trivial direta em missão'
  $terminalSendReferences = @($policyText -split "`n" | Where-Object { $_ -match 'terminal send.*--enter' })
  $sendInConfirmation = [IO.File]::ReadAllText((Join-Path $RepoRoot 'source\claude\skills\hybrid-orchestration\references\dispatch-confirmation.md'), [Text.Encoding]::UTF8)
  Assert (($terminalSendReferences.Count -eq 1) -and ($sendInConfirmation -match 'terminal send.*--enter')) 'AC4: terminal send --enter só na referência de exceção'
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("claude-hybrid: pass=" + $pass + " fail=" + $fail)
if ($fail -gt 0) { exit 1 }
exit 0
