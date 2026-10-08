# profile-isolation.tests.ps1 -- Phase 7 (V3.1): perfis isolados V1/V2.
# (a) New-OrchestrationProfile v1+v2: manifests corretos, config roots disjuntos.
# (a2) Coerencia manifest-por-ultimo: todo manifest de perfil tem wrapper.
# (b) Isolamento real: debug paths com XDG do perfil resolve config no perfil.
# (c) Cross-leak: arquivo do perfil v2 nao aparece no v1.
# (d) Wrapper v2 --version => 2.x; env do pai inalterado.
# (d2) Override persistido: -BinaryPath grava binary_path + provenance.
# (e) Re-run v1 nao toca v2 (hashes estaveis).
# (f) Remove-P7Profile v1 => v2 intacto.
# (f2) Remove-P7Profile sem prova de ownership falha e preserva o diretorio.
# (g) install -Runtime Both sem binario e sem -ProvisionRuntime => exit 6.
# (h) ProfileRoot com espaco no caminho (fixture: todo o suite usa path c/ espaco).
# PS 5.1 compativel. SKIP graceful quando binario ausente. ASCII only.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Skip([string]$Name, [string]$Why) {
  $script:pass += 1
  Write-Host ("ok - " + $Name + " (SKIP: " + $Why + ")")
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$utf8 = New-Object Text.UTF8Encoding $false
. (Join-Path $RepoRoot 'scripts\runtime\New-OrchestrationProfile.ps1')
# Pin do runtime para o gate do bloco (d): leitura explicita do registry
# unico (somente leitura; o pin continua canonico em source/).
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')

# (h) fixture: espaco no caminho do perfil root.
$ProfileRoot = Join-Path ([IO.Path]::GetTempPath()) ('oo p7 profiles ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ProfileRoot -Force | Out-Null
$ExtraDirs = New-Object System.Collections.ArrayList
[void]$ExtraDirs.Add($ProfileRoot)

function Get-DirHashes([string]$Dir) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $map }
  foreach ($f in @(Get-ChildItem -File -LiteralPath $Dir -Recurse -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($Dir.Length)
    try { $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
  }
  return $map
}

try {
  # (a) cria v1+v2 ------------------------------------------------------------
  $i1 = $null
  $i2 = $null
  try { $i1 = New-OrchestrationProfile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -RuntimeId 'opencode-v1' }
  catch { Assert $false ('a: profile v1 criado (' + $_.Exception.Message + ')') }
  try { $i2 = New-OrchestrationProfile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -RuntimeId 'opencode-v2' }
  catch { Assert $false ('a: profile v2 criado (' + $_.Exception.Message + ')') }
  Assert (($null -ne $i1) -and ($null -ne $i2)) 'a: ambos os perfis retornaram info'
  $m1 = Get-P7Profile -ProfileRoot $ProfileRoot -Profile 'v1'
  $m2 = Get-P7Profile -ProfileRoot $ProfileRoot -Profile 'v2'
  Assert (($null -ne $m1) -and ([string]$m1.runtime_id -eq 'opencode-v1') -and ([int]$m1.generation -eq 1)) 'a: manifest v1 correto'
  Assert (($null -ne $m2) -and ([string]$m2.runtime_id -eq 'opencode-v2') -and ([int]$m2.generation -eq 2)) 'a: manifest v2 correto'
  Assert (([string]$m1.config_root -cne [string]$m2.config_root) -and ([string]$m1.home_dir -cne [string]$m2.home_dir)) 'a: config roots e homes disjuntos'
  Assert ((Test-Path -LiteralPath ([string]$m1.install_manifest) -PathType Leaf) -and (Test-Path -LiteralPath ([string]$m2.install_manifest) -PathType Leaf)) 'a: install manifests nos homes dos perfis'
  Assert ((Test-Path -LiteralPath (Join-Path ([string]$m1.home_dir) '.config\opencode\opencode.json') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path ([string]$m2.home_dir) '.config\opencode\opencode.json') -PathType Leaf)) 'a: opencode.json em ambos os perfis'
  $j1 = (([IO.File]::ReadAllText((Join-Path ([string]$m1.home_dir) '.config\opencode\opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json)
  $j2 = (([IO.File]::ReadAllText((Join-Path ([string]$m2.home_dir) '.config\opencode\opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json)
  Assert (($null -ne $j1.agent) -and ($null -eq ($j1 | Get-Member -Name 'agents' -ErrorAction SilentlyContinue))) 'a: perfil v1 com dialeto V1'
  Assert (($null -ne $j2.agents) -and ($null -eq ($j2 | Get-Member -Name 'agent' -ErrorAction SilentlyContinue))) 'a: perfil v2 com dialeto V2'
  Assert ((Test-Path -LiteralPath (Join-Path $ProfileRoot 'bin\opencode-v1.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $ProfileRoot 'bin\opencode-v2.ps1') -PathType Leaf)) 'a: wrappers gerados (path com espaco ok)'

  # (a2) coerencia manifest-por-ultimo --------------------------------------------
  $a2ok = $true
  foreach ($ppA2 in @('v1', 'v2')) {
    if (Test-Path -LiteralPath (Join-Path $ProfileRoot ($ppA2 + '\manifest.json')) -PathType Leaf) {
      if (-not (Test-Path -LiteralPath (Join-Path $ProfileRoot ('bin\opencode-' + $ppA2 + '.ps1')) -PathType Leaf)) { $a2ok = $false }
    }
  }
  Assert ($a2ok) 'a2: todo manifest de perfil existente tem wrapper correspondente'

  # Localiza binarios reais ----------------------------------------------------
  $v1bin = ''
  try {
    $gc1 = @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)
    $pick1 = $null
    foreach ($c in $gc1) {
      if ($c.CommandType -eq 'Application') { $pick1 = $c; break }
    }
    if (($null -eq $pick1) -and ($gc1.Count -gt 0)) { $pick1 = $gc1[0] }
    if (($null -ne $pick1) -and (-not [string]::IsNullOrWhiteSpace([string]$pick1.Source))) {
      $pv1 = Invoke-P7Process -File ([string]$pick1.Source) -ArgsLine '--version' -TimeoutMs 20000
      if (([int]$pv1.ExitCode -eq 0) -and ((Get-P7Major $pv1.Output) -eq 1)) { $v1bin = [string]$pick1.Source }
    }
  }
  catch { $v1bin = '' }
  $v2bin = Join-Path $RepoRoot 'cache\v2-probe\node_modules\.bin\opencode.cmd'
  if (-not (Test-Path -LiteralPath $v2bin -PathType Leaf)) { $v2bin = '' }

  # (b) isolamento real ---------------------------------------------------------
  if ($v2bin -ne '') {
    $t2 = Test-P7Isolation -BinaryPath $v2bin -Generation 2
    Assert ($t2.Ok) ('b: V2 isolado por XDG (' + [string]$t2.Reason + ')')
    $envT2 = @{ XDG_CONFIG_HOME = [string]$m2.config_root }
    $dp2 = Invoke-P7Process -File $v2bin -ArgsLine 'debug paths' -EnvTable $envT2 -TimeoutMs 30000
    $homeV2s = ([string]$m2.home_dir -replace '\\', '/')
    $homeV2b = ([string]$m2.home_dir -replace '/', '\')
    Assert (([int]$dp2.ExitCode -eq 0) -and (([string]$dp2.Output).Contains($homeV2s) -or ([string]$dp2.Output).Contains($homeV2b))) 'b: V2 debug paths resolve config dentro do perfil v2'
  }
  else { Skip 'b: V2 isolado por XDG' 'cache\v2-probe ausente' }
  if ($v1bin -ne '') {
    $t1 = Test-P7Isolation -BinaryPath $v1bin -Generation 1
    Assert ($t1.Ok) ('b: V1 isolado por XDG (' + [string]$t1.Reason + ')')
    $envT1 = @{ XDG_CONFIG_HOME = [string]$m1.config_root }
    $dp1 = Invoke-P7Process -File $v1bin -ArgsLine 'debug paths' -EnvTable $envT1 -TimeoutMs 30000
    $homeV1s = ([string]$m1.home_dir -replace '\\', '/')
    $homeV1b = ([string]$m1.home_dir -replace '/', '\')
    Assert (([int]$dp1.ExitCode -eq 0) -and (([string]$dp1.Output).Contains($homeV1s) -or ([string]$dp1.Output).Contains($homeV1b))) 'b: V1 debug paths resolve config dentro do perfil v1'
  }
  else { Skip 'b: V1 isolado por XDG' 'binario V1 ausente no PATH' }

  # (c) cross-leak ---------------------------------------------------------------
  $canary = Join-Path ([string]$m2.config_root) 'opencode\canary-p7.txt'
  [IO.File]::WriteAllText($canary, "canary`n", $utf8)
  $leak = Join-Path ([string]$m1.config_root) 'opencode\canary-p7.txt'
  Assert (-not (Test-Path -LiteralPath $leak -PathType Leaf)) 'c: canary do perfil v2 nao aparece no perfil v1'
  Remove-Item -LiteralPath $canary -Force -ErrorAction SilentlyContinue
  Assert (-not (Test-Path -LiteralPath $canary -PathType Leaf)) 'c: canary removido (limpeza)'

  # (d) wrapper v2 ---------------------------------------------------------------
  # Gate de pin-exato: o wrapper exige o binario do pin (fail-closed, exit 6
  # sem ele). O cache e gitignored e pode estar divergente do pin; sem rede
  # nao ha como provisionar o binario exato. Divergencia => SKIP honesto
  # (AMBIENTAL), nunca PASS forcado. Sem divergencia, asserts normais.
  $wrapV2 = Join-Path $ProfileRoot 'bin\opencode-v2.ps1'
  if ($v2bin -ne '') {
    $v2verD = ''
    try {
      $pvD = Invoke-P7Process -File $v2bin -ArgsLine '--version' -TimeoutMs 20000
      if ([int]$pvD.ExitCode -eq 0) {
        $mD = [regex]::Match([string]$pvD.Output, '(\d+\.\d+\.\d+)')
        if ($mD.Success) { $v2verD = $mD.Groups[1].Value }
      }
    }
    catch { $v2verD = '' }
    $pinV2D = ''
    try { $pinV2D = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Version } catch { $pinV2D = '' }
    if (($v2verD -ne '') -and ($pinV2D -ne '') -and ($v2verD -cne $pinV2D)) {
      Skip 'd: wrapper v2 --version' ('AMBIENTAL: binario V2 em cache ' + $v2verD + ' diverge do pin ' + $pinV2D + ' (cache gitignored, sem rede para provisionar)')
      Skip 'd: XDG_CONFIG_HOME do pai inalterado apos wrapper' ('AMBIENTAL: pre-requisito (wrapper v2 com pin exato) indisponivel')
    }
    else {
    $hadXdg = Test-Path Env:\XDG_CONFIG_HOME
    $oldXdg = $env:XDG_CONFIG_HOME
    $outW = & $wrapV2 -BinaryPath $v2bin --version 2>&1 | Out-String
    $codeW = $LASTEXITCODE
    Assert (($codeW -eq 0) -and ($outW -match '2\.\d+\.\d+')) 'd: wrapper v2 --version => 2.x'
    $stillHad = Test-Path Env:\XDG_CONFIG_HOME
    $stillSame = $true
    if ($hadXdg -ne $stillHad) { $stillSame = $false }
    elseif ($hadXdg -and ([string]$env:XDG_CONFIG_HOME -cne [string]$oldXdg)) { $stillSame = $false }
    Assert ($stillSame) 'd: XDG_CONFIG_HOME do pai inalterado apos wrapper'
    }
  }
  else { Skip 'd: wrapper v2 --version' 'binario V2 ausente (cache\v2-probe)' }

  # (d2) override persistido --------------------------------------------------------
  if ($v2bin -ne '') {
    $profD2 = Join-Path ([IO.Path]::GetTempPath()) ('oo p7 override ' + [guid]::NewGuid().ToString('N'))
    [void]$ExtraDirs.Add($profD2)
    try {
      $null = New-OrchestrationProfile -RepoRoot $RepoRoot -ProfileRoot $profD2 -RuntimeId 'opencode-v2' -BinaryOverride $v2bin
      $mD2 = Get-P7Profile -ProfileRoot $profD2 -Profile 'v2'
      Assert (($null -ne $mD2) -and ($null -ne $mD2.provisioned) -and ([string]$mD2.provisioned.binary_path -eq $v2bin) -and ([string]$mD2.provisioned.provenance -ceq 'override')) 'd2: manifest v2 grava binary_path + provenance override'
    }
    catch { Assert $false ('d2: perfil v2 com BinaryOverride (' + $_.Exception.Message + ')') }
  }
  else { Skip 'd2: perfil v2 com BinaryOverride' 'binario V2 ausente (cache\v2-probe)' }

  # (e) re-run v1 nao toca v2 ------------------------------------------------------
  $beforeV2 = Get-DirHashes (Join-Path $ProfileRoot 'v2')
  Assert ($beforeV2.Count -gt 0) 'e: baseline de hashes do perfil v2 nao vazia'
  try {
    $null = New-OrchestrationProfile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -RuntimeId 'opencode-v1'
    Assert $true 'e: re-run perfil v1 exit ok'
  }
  catch { Assert $false ('e: re-run perfil v1 (' + $_.Exception.Message + ')') }
  $afterV2 = Get-DirHashes (Join-Path $ProfileRoot 'v2')
  $diffV2 = @(@($afterV2.Keys) | Where-Object { (-not $beforeV2.ContainsKey($_)) -or ($beforeV2[$_] -cne $afterV2[$_]) })
  $diffV2 += @(@($beforeV2.Keys) | Where-Object { -not $afterV2.ContainsKey($_) })
  Assert ($diffV2.Count -eq 0) ('e: perfil v2 intacto apos update v1 (' + $afterV2.Count + ' arquivos)')

  # (f) remove v1 => v2 intacto ------------------------------------------------------
  try {
    Remove-P7Profile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -Profile 'v1'
    Assert $true 'f: Remove-P7Profile v1 ok'
  }
  catch { Assert $false ('f: Remove-P7Profile v1 (' + $_.Exception.Message + ')') }
  Assert (-not (Test-Path -LiteralPath (Join-Path $ProfileRoot 'v1') -PathType Container)) 'f: diretorio v1 removido'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ProfileRoot 'bin\opencode-v1.ps1') -PathType Leaf)) 'f: wrapper v1 removido'
  $m2b = Get-P7Profile -ProfileRoot $ProfileRoot -Profile 'v2'
  Assert (($null -ne $m2b) -and (Test-Path -LiteralPath ([string]$m2b.install_manifest) -PathType Leaf)) 'f: perfil v2 intacto (manifest + install)'
  Assert (Test-Path -LiteralPath (Join-Path $ProfileRoot 'bin\opencode-v2.ps1') -PathType Leaf) 'f: wrapper v2 intacto'

  # (f2) remove sem prova de ownership falha e preserva --------------------------------
  # Caso A: dir sem nenhum manifest => recusa.
  $fakeV1 = Join-Path $ProfileRoot 'v1'
  New-Item -ItemType Directory -Path $fakeV1 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fakeV1 'junk.txt'), "junk`n", $utf8)
  try {
    $f2threw = $false
    try { Remove-P7Profile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -Profile 'v1' }
    catch { $f2threw = $true }
    Assert ($f2threw) 'f2-A: Remove-P7Profile v1 sem manifest falha (fail-closed)'
    Assert ((Test-Path -LiteralPath $fakeV1 -PathType Container) -and (Test-Path -LiteralPath (Join-Path $fakeV1 'junk.txt') -PathType Leaf)) 'f2-A: diretorio fake preservado (nada removido)'
  }
  finally {
    if (Test-Path -LiteralPath $fakeV1) { Remove-Item -LiteralPath $fakeV1 -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # Caso B1: install-manifest com JSON invalido => recusa.
  $fakeB1 = Join-Path $ProfileRoot 'v1'
  New-Item -ItemType Directory -Path $fakeB1 -Force | Out-Null
  $homeB1 = Join-Path $fakeB1 'home'
  $imDirB1 = Join-Path $homeB1 '.opencode-orchestration'
  New-Item -ItemType Directory -Path $imDirB1 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $imDirB1 'manifest.json'), "{ not-json`n", $utf8)
  try {
    $f2b1threw = $false
    try { Remove-P7Profile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -Profile 'v1' }
    catch { $f2b1threw = $true }
    Assert ($f2b1threw) 'f2-B1: Remove-P7Profile v1 com install-manifest invalido falha (fail-closed)'
    Assert (Test-Path -LiteralPath $fakeB1 -PathType Container) 'f2-B1: diretorio fake preservado (nada removido)'
  }
  finally {
    if (Test-Path -LiteralPath $fakeB1) { Remove-Item -LiteralPath $fakeB1 -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # Caso B2: install-manifest valido mas sem identidade => recusa.
  $fakeB2 = Join-Path $ProfileRoot 'v1'
  New-Item -ItemType Directory -Path $fakeB2 -Force | Out-Null
  $homeB2 = Join-Path $fakeB2 'home'
  $imDirB2 = Join-Path $homeB2 '.opencode-orchestration'
  New-Item -ItemType Directory -Path $imDirB2 -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $imDirB2 'manifest.json'), "{`"note`":`"no identity`"`n}`n", $utf8)
  try {
    $f2b2threw = $false
    try { Remove-P7Profile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -Profile 'v1' }
    catch { $f2b2threw = $true }
    Assert ($f2b2threw) 'f2-B2: Remove-P7Profile v1 com install-manifest sem identidade falha (fail-closed)'
    Assert (Test-Path -LiteralPath $fakeB2 -PathType Container) 'f2-B2: diretorio fake preservado (nada removido)'
  }
  finally {
    if (Test-Path -LiteralPath $fakeB2) { Remove-Item -LiteralPath $fakeB2 -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # Caso C: install-manifest valido mas home e junction para fora => recusa e fora intacto.
  $fakeC = Join-Path $ProfileRoot 'v1'
  if (Test-Path -LiteralPath $fakeC) { Remove-Item -LiteralPath $fakeC -Recurse -Force -ErrorAction SilentlyContinue }
  $outsideC = Join-Path ([IO.Path]::GetTempPath()) ('oo p7 outside ' + [guid]::NewGuid().ToString('N'))
  $homeC = Join-Path $fakeC 'home'
  New-Item -ItemType Directory -Path $fakeC -Force | Out-Null
  New-Item -ItemType Directory -Path $outsideC -Force | Out-Null
  $canaryC = Join-Path $outsideC 'sentinel.txt'
  [IO.File]::WriteAllText($canaryC, "outside`n", $utf8)
  try {
    $imDirC = Join-Path $outsideC '.opencode-orchestration'
    New-Item -ItemType Directory -Path $imDirC -Force | Out-Null
    $maniC = [ordered]@{
      package_version = '9.9.9'
      installed_at = 'f2c'
      source_revision = 'f2c'
      target_home = $homeC
      runtime = [ordered]@{ id = 'opencode-v1'; generation = 1; profile = 'test' }
      managed_files = @()
      managed_config_paths = @()
      adopted_paths = @()
      legacy_removed = @()
      config_snapshot = @{}
      models = [ordered]@{ planner = 'x'; cheap = 'x'; strong = 'x' }
      plugin_dependency = 'x'
    }
    [IO.File]::WriteAllText((Join-Path $imDirC 'manifest.json'), ((($maniC | ConvertTo-Json -Depth 8).TrimEnd()) + "`n"), $utf8)
    $junctOk = $true
    try { New-Item -ItemType Junction -Path $homeC -Target $outsideC -Force | Out-Null }
    catch { $junctOk = $false }
    Assert ($junctOk) 'f2-C: junction de teste criada (pre-requisito)'
    if ($junctOk) {
      $f2cthrew = $false
      try { Remove-P7Profile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -Profile 'v1' }
      catch { $f2cthrew = $true }
      Assert ($f2cthrew) 'f2-C: Remove-P7Profile v1 com home junction para fora falha (fail-closed)'
      Assert (Test-Path -LiteralPath $fakeC -PathType Container) 'f2-C: diretorio fake preservado'
      $canaryOkC = $false
      try { $canaryOkC = (([IO.File]::ReadAllText($canaryC, [Text.Encoding]::UTF8)).Trim() -eq 'outside') } catch { $canaryOkC = $false }
      Assert ($canaryOkC) 'f2-C: nada fora do perfil foi tocado (canary intacto)'
    }
  }
  finally {
    # Junction: NUNCA Remove-Item (PS 5.1 pode bloquear em prompt de host
    # nao-interativo). [IO.Directory]::Delete(path, false) remove so o
    # reparse point, sem atravessar o alvo.
    try { if (Test-Path -LiteralPath $homeC) { [IO.Directory]::Delete($homeC, $false) } } catch { }
    if (Test-Path -LiteralPath $fakeC) { Remove-Item -LiteralPath $fakeC -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $outsideC) { Remove-Item -LiteralPath $outsideC -Recurse -Force -ErrorAction SilentlyContinue }
  }

  # (g) Both sem binario e sem provision => exit 6 ------------------------------------
  $hG = Join-Path ([IO.Path]::GetTempPath()) ('oo p7 both ' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $hG -Force | Out-Null
  [void]$ExtraDirs.Add($hG)
  $profG = Join-Path ([IO.Path]::GetTempPath()) ('oo p7 bothprof ' + [guid]::NewGuid().ToString('N'))
  [void]$ExtraDirs.Add($profG)
  $sysParts = @($env:PATH -split ';' | Where-Object { $_ -ne '' })
  $dropG = @{}
  foreach ($gBin in @(Get-Command 'opencode' -All -ErrorAction SilentlyContinue)) {
    try {
      $srcG = [string]$gBin.Source
      if (-not [string]::IsNullOrWhiteSpace($srcG)) { $dropG[(Split-Path -Parent $srcG)] = $true }
    }
    catch { }
  }
  $cleanParts = @($sysParts | Where-Object { -not $dropG.ContainsKey($_) })
  $cleanPath = ($cleanParts -join ';')
  # Anti-deadlock: nunca pipe direto (mesma regra da lib). Invoke-P7Process
  # redireciona a saida do filho para arquivo e respeita timeout real.
  $engineG = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $envG = @{ PATH = $cleanPath; PSModulePath = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" }
  $resG = Invoke-P7Process -File $engineG -ArgsLine ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $RepoRoot 'install.ps1') + '" -TargetHome "' + $hG + '" -Runtime Both -ProfileRoot "' + $profG + '"') -WorkDir $RepoRoot -EnvTable $envG -TimeoutMs 180000
  $codeG = $resG.ExitCode
  $bothG = [string]$resG.Output
  Assert ($codeG -eq 6) ('g: Both sem binario => exit 6 (achado ' + $codeG + ')')
  Assert (($bothG -match 'unproven') -and ($bothG -match 'ProvisionRuntime')) 'g: diagnostico claro (unproven + ProvisionRuntime)'
  Assert (-not (Test-Path -LiteralPath (Join-Path $profG 'v1') -PathType Container) -and (-not (Test-Path -LiteralPath (Join-Path $profG 'v2') -PathType Container))) 'g: nada escrito nos perfis com Both falhado'
}
finally {
  foreach ($d in @($ExtraDirs)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
