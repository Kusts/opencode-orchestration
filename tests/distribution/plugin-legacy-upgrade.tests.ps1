# plugin-legacy-upgrade.tests.ps1 - V31-R2 F1: upgrade de install pre-bundle.
# Home com plugins/orchestration-enforcement.ts legado + arquivos .ts/.js
# desconhecidos (user-owned): install adota o legado para o backup, remove
# do plugins dir, instala o bundle .js e registra legacy_removed no
# manifest; desconhecidos intactos; reinstall idempotente; uninstall remove
# o .js sem recriar o .ts.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# RR-VERSIONS-REGISTRY: o stub da dependencia abaixo declara ser a versao
# pinada, entao vem do registry unico (evita rede; nenhuma assercao compara a
# versao -- o "legacy" deste teste e o arquivo .ts pre-bundle, nao o pacote).
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
$pluginV1Version = (Get-OrchestrationRuntimeVersion -Name plugin_v1 -RepoRoot $RepoRoot).Version
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-legacy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $plugDir = Join-Path $ocDir 'plugins'
  New-Item -ItemType Directory -Path $plugDir -Force | Out-Null
  # Stub da dependencia do plugin (versao pinada => sem tentativa de rede).
  $depDir = Join-Path $ocDir 'node_modules\@opencode-ai\plugin'
  New-Item -ItemType Directory -Path $depDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $depDir 'package.json'), ('{"name":"@opencode-ai/plugin","version":"' + $pluginV1Version + '"}'), (New-Object Text.UTF8Encoding $false))
  # Legado pre-bundle + arquivos do usuario.
  $legacyContent = "// legado pre-bundle do usuario (fake)`nexport const legacy = 1;`n"
  $legacyPath = Join-Path $plugDir 'orchestration-enforcement.ts'
  [IO.File]::WriteAllText($legacyPath, $legacyContent, (New-Object Text.UTF8Encoding $false))
  $legacyHash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash
  $userTs = Join-Path $plugDir 'meu-plugin.ts'
  [IO.File]::WriteAllText($userTs, "// plugin do usuario`n", (New-Object Text.UTF8Encoding $false))
  $userJs = Join-Path $plugDir 'custom.js'
  [IO.File]::WriteAllText($userJs, "// js do usuario`n", (New-Object Text.UTF8Encoding $false))

  $out1 = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'install (upgrade) exit 0'

  # (i) legado fora do plugins dir, bundle presente, backup com o legado.
  Assert (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) 'legado .ts removido do plugins dir'
  Assert (Test-Path -LiteralPath (Join-Path $plugDir 'orchestration-enforcement.js') -PathType Leaf) 'bundle .js presente'
  $bakLegacy = @(Get-ChildItem -File (Join-Path $ocDir 'backups') -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ceq 'orchestration-enforcement.ts' })
  Assert ($bakLegacy.Count -eq 1) 'legado adotado para o backup do install'
  if ($bakLegacy.Count -eq 1) {
    Assert (((Get-FileHash -LiteralPath $bakLegacy[0].FullName -Algorithm SHA256).Hash) -eq $legacyHash) 'backup do legado com hash original'
  }
  Assert ($out1 -match '\[REMOVE\] plugins/orchestration-enforcement\.ts') 'plano mostra REMOVE do legado'
  Assert (([IO.File]::ReadAllText($userTs, [Text.Encoding]::UTF8)) -eq "// plugin do usuario`n") 'meu-plugin.ts do usuario intacto'
  Assert (([IO.File]::ReadAllText($userJs, [Text.Encoding]::UTF8)) -eq "// js do usuario`n") 'custom.js do usuario intacto'

  # Manifest: .js como managed, .ts como legacy-removed (nao re-criado).
  $mf = Join-Path $TmpHome '.opencode-orchestration\manifest.json'
  Assert (Test-Path -LiteralPath $mf -PathType Leaf) 'manifest criado'
  $m1 = ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $managedRels = @($m1.managed_files | ForEach-Object { ([string]$_.relative) -replace '/', '\' })
  Assert ($managedRels -contains 'plugins\orchestration-enforcement.js') 'manifest lista .js como managed'
  Assert (-not ($managedRels -contains 'plugins\orchestration-enforcement.ts')) 'manifest NAO lista .ts como managed'
  $leg = @($m1.legacy_removed | Where-Object { ([string]$_.relative) -replace '/', '\' -ceq 'plugins\orchestration-enforcement.ts' })
  Assert ($leg.Count -eq 1) 'manifest registra legacy_removed do .ts'
  if ($leg.Count -eq 1) {
    Assert ($leg[0].sha256 -eq $legacyHash) 'legacy_removed com hash original'
    Assert ([string]$leg[0].status -ceq 'legacy-removed') 'legacy_removed com status legacy-removed'
  }

  # (ii) install repetido idempotente.
  Start-Sleep -Seconds 2
  $out2 = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'run2 exit 0'
  Assert (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) 'run2: legado continua ausente'
  Assert ($out2 -notmatch '\[REMOVE\] plugins/orchestration-enforcement\.ts') 'run2: sem novo REMOVE do legado'
  $m2 = ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $m1copy = ($m1 | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  $m2copy = ($m2 | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  $m1copy.installed_at = 'X'
  $m2copy.installed_at = 'X'
  Assert ((($m1copy | ConvertTo-Json -Depth 32)) -eq (($m2copy | ConvertTo-Json -Depth 32))) 'manifest estavel entre runs (exceto installed_at)'

  # (iii) uninstall apos upgrade: remove .js, nao recria .ts, preserva usuario.
  $null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $TmpHome 2>&1
  Assert ($LASTEXITCODE -eq 0) 'uninstall exit 0'
  Assert (-not (Test-Path -LiteralPath (Join-Path $plugDir 'orchestration-enforcement.js') -PathType Leaf)) 'uninstall remove .js'
  Assert (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) 'uninstall NAO recria .ts'
  Assert (Test-Path -LiteralPath $userTs -PathType Leaf) 'uninstall preserva meu-plugin.ts'
  Assert (Test-Path -LiteralPath $userJs -PathType Leaf) 'uninstall preserva custom.js'

  # (iv) V31-R2-RESIDUAL R1: CAS_CONFLICT (exit 4) nao remove o legado.
  $TmpCas = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-legacy-cas-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $TmpCas -Force | Out-Null
  try {
    $ocCas = Join-Path $TmpCas '.config\opencode'
    $plugCas = Join-Path $ocCas 'plugins'
    New-Item -ItemType Directory -Path $plugCas -Force | Out-Null
    $depCas = Join-Path $ocCas 'node_modules\@opencode-ai\plugin'
    New-Item -ItemType Directory -Path $depCas -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $depCas 'package.json'), ('{"name":"@opencode-ai/plugin","version":"' + $pluginV1Version + '"}'), (New-Object Text.UTF8Encoding $false))
    $legacyCasContent = "// legado pre-bundle (cas)`nexport const legacy = 1;`n"
    $legacyCasPath = Join-Path $plugCas 'orchestration-enforcement.ts'
    [IO.File]::WriteAllText($legacyCasPath, $legacyCasContent, (New-Object Text.UTF8Encoding $false))
    $outCas = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpCas -InjectFailureAfter 'cas' *>&1 | Out-String
    Assert ($LASTEXITCODE -eq 4) 'cas exit 4'
    Assert ($outCas -match 'CAS_CONFLICT') 'cas anuncia CAS_CONFLICT'
    Assert (Test-Path -LiteralPath $legacyCasPath -PathType Leaf) 'R1: legado intacto apos CAS_CONFLICT'
    Assert (([IO.File]::ReadAllText($legacyCasPath, [Text.Encoding]::UTF8)) -eq $legacyCasContent) 'R1: conteudo do legado inalterado apos CAS_CONFLICT'
    Assert (-not (Test-Path -LiteralPath (Join-Path $plugCas 'orchestration-enforcement.js') -PathType Leaf)) 'R1: bundle nao aplicado apos CAS_CONFLICT'
  }
  finally {
    if (Test-Path -LiteralPath $TmpCas) { Remove-Item -LiteralPath $TmpCas -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
