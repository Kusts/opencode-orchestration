# runtime-install.tests.ps1 — Phase 6 (V3.1): installer runtime-aware.
# (a) fresh V2: shape nativo agents/permissions/experimental + manifest runtime v2.
# (b) fresh V1: invariantes atuais + manifest runtime v1 (regression guard).
# (c) user-owned preservado nos dois runtimes (fixture mcp/plugin/autoupdate/custom).
# (d) JSONC input nos dois runtimes (merge no jsonc, sem criar opencode.json).
# (e) repeat V2 idempotente (segundo run exit 0, config estavel).
# (f) uninstall V2: so package-owned sai, fixture do usuario permanece.
# (g) manifest legacy 1.0.0 sem runtime: uninstall funciona como v1; -Runtime V2 => exit 6.
# (h) V2 InjectFailureAfter=apply-json: exit 5 + ROLLBACK_COMPLETED.
# (i) -Runtime Both segue bloqueado (exit 6).
# (j) -Runtime Auto com binario V2 no PATH segue o fluxo V2.
# (k) uninstall cross-check: install V1 + uninstall -Runtime V2 => exit 6, nada tocado.
# (k2) explicit wins: install -Runtime V2 com binario V1 global no PATH => exit 0.
# PS 5.1 compativel. Install 100% offline: sem pin local de node_modules;
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# RR-VERSIONS-REGISTRY: os plugin_dependency esperados nos manifests vem do
# registry unico (source/registry/runtime-versions.json), igual ao install.ps1
# -- sem literal aqui que envelheceria em silencio apos um bump.
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
$pluginSpecV1 = (Get-OrchestrationRuntimeVersion -Name plugin_v1 -RepoRoot $RepoRoot).Spec
$pluginSpecV2 = (Get-OrchestrationRuntimeVersion -Name plugin_v2 -RepoRoot $RepoRoot).Spec
# O shim (k2) simula um BINARIO v1 no PATH: versao do runtime, nao do plugin.
$runtimeV1Version = (Get-OrchestrationRuntimeVersion -Name v1 -RepoRoot $RepoRoot).Version
$utf8 = New-Object Text.UTF8Encoding $false
$homes = New-Object System.Collections.ArrayList

function New-TestHome([string]$Tag, [string]$Rt) {
  # Install 100% offline: home limpo, sem node_modules pre-seedado. Rt mantido
  # na assinatura por compatibilidade com as chamadas existentes.
  $h = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-rt-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $h -Force | Out-Null
  [void]$homes.Add($h)
  return $h
}

function Get-Models() {
  $raw = [IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8)
  return (($raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
}
$models = Get-Models

# PATH sanitizado para higiene dos fluxos explicitos (reversivel ao final);
# V31-P6-FIX-EXPLICIT: explicito vence sem probe, entao binario global NAO
# gera mais conflito com -Runtime V1/V2. O caso com binario presente e
# coberto em (j) via prepend sobre a base sanitizada e em (k2) via shim V1.
$origPath = $env:PATH
try {
  $dropDirs = @{}
  foreach ($gBin in @(Get-Command 'opencode' -All -ErrorAction SilentlyContinue)) {
    try {
      $srcBin = [string]$gBin.Source
      if (-not [string]::IsNullOrWhiteSpace($srcBin)) {
        $dropDirs[(Split-Path -Parent $srcBin)] = $true
      }
    }
    catch { }
  }
  if ($dropDirs.Count -gt 0) {
    $parts = @($env:PATH -split ';' | Where-Object { ($_ -ne '') -and (-not $dropDirs.ContainsKey($_)) })
    $env:PATH = ($parts -join ';')
  }
}
catch { }

# (a) fresh V2 ---------------------------------------------------------------
$hA = New-TestHome 'a' 'V2'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hA -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 0) 'a: install V2 exit 0'
$ocA = Join-Path $hA '.config\opencode'
$jA = ([IO.File]::ReadAllText((Join-Path $ocA 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ((@($jA.agents.PSObject.Properties.Name).Count) -eq 17) 'a: 17 blocos agents'
Assert (($null -ne ($jA.agents.build | Get-Member -Name 'permissions' -ErrorAction SilentlyContinue))) 'a: build tem permissions'
Assert (($null -eq ($jA.agents.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) 'a: build sem model'
Assert (([string]$jA.agents.build.permissions[0].effect -ceq 'deny') -and ([string]$jA.agents.build.permissions[0].resource -ceq '*')) 'a: build.permissions[0] deny-*'
Assert ((@($jA.agents.build.permissions).Count) -eq 20) 'a: build.permissions 20 entradas'
Assert ([int]$jA.experimental.subagent_depth -eq 1) 'a: experimental.subagent_depth=1'
Assert (($null -eq ($jA | Get-Member -Name 'agent' -ErrorAction SilentlyContinue))) 'a: sem chave legada agent'
Assert (($null -eq ($jA | Get-Member -Name 'subagent_depth' -ErrorAction SilentlyContinue))) 'a: sem subagent_depth no topo'
Assert ([string]$jA.agents.title.model -eq [string]$models.planner) 'a: title.model=planner'
Assert ([string]$jA.agents.coder.model -eq [string]$models.cheap) 'a: coder.model=cheap'
Assert ([string]$jA.agents.reviewer.model -eq [string]$models.strong) 'a: reviewer.model=strong'
$mdA = [IO.File]::ReadAllText((Join-Path $ocA 'AGENTS.md'), [Text.Encoding]::UTF8)
Assert (([regex]::Matches($mdA, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'a: AGENTS.md 1 marker'
Assert ($mdA -notmatch '\{\{[^}]+\}\}') 'a: AGENTS.md sem tokens'
Assert ($mdA.Contains('Adaptador OpenCode V2')) 'a: AGENTS.md com adapter V2'
$agentFilesA = @(Get-ChildItem -File (Join-Path $ocA 'agents\*.md') -ErrorAction SilentlyContinue)
Assert ($agentFilesA.Count -eq 19) ('a: 19 agents .md (achado ' + $agentFilesA.Count + ')')
$coderMd = [IO.File]::ReadAllText((Join-Path $ocA 'agents\coder.md'), [Text.Encoding]::UTF8)
$fmA = [regex]::Match($coderMd, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*')
Assert ($fmA.Success -and $fmA.Groups[1].Value.Contains('permissions:')) 'a: coder.md frontmatter V2 com permissions'
Assert ($coderMd -notmatch '(?m)^orchestration:\s*$') 'a: coder.md sem bloco orchestration'
Assert (Test-Path -LiteralPath (Join-Path $ocA 'plugins\orchestration-enforcement.js') -PathType Leaf) 'a: plugin bundle instalado'
$mA = ([IO.File]::ReadAllText((Join-Path $hA '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ($mA.package_version -eq '1.1.0') 'a: manifest package_version 1.1.0'
Assert ($mA.runtime.id -eq 'opencode-v2') 'a: manifest runtime.id v2'
Assert ([int]$mA.runtime.generation -eq 2) 'a: manifest runtime.generation 2'
Assert ($mA.plugin_dependency -eq $pluginSpecV2) 'a: manifest plugin_dependency V2'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocA 'node_modules') -PathType Container)) 'a: sem node_modules no TargetHome (install offline)'

# (b) fresh V1 (regression guard) ---------------------------------------------
$hB = New-TestHome 'b' 'V1'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hB -Runtime V1 2>&1
Assert ($LASTEXITCODE -eq 0) 'b: install V1 exit 0'
$ocB = Join-Path $hB '.config\opencode'
$jB = ([IO.File]::ReadAllText((Join-Path $ocB 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ((@($jB.agent.PSObject.Properties.Name).Count) -eq 17) 'b: 17 blocos agent'
Assert (($null -eq ($jB | Get-Member -Name 'agents' -ErrorAction SilentlyContinue))) 'b: sem chave agents (plural)'
Assert ([int]$jB.subagent_depth -eq 1) 'b: subagent_depth=1 no topo'
Assert (($null -eq ($jB.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) 'b: build sem model'
$mB = ([IO.File]::ReadAllText((Join-Path $hB '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ($mB.package_version -eq '1.1.0') 'b: manifest package_version 1.1.0'
Assert ($mB.runtime.id -eq 'opencode-v1') 'b: manifest runtime.id v1'
Assert ($mB.plugin_dependency -eq $pluginSpecV1) 'b: manifest plugin_dependency V1'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocB 'node_modules') -PathType Container)) 'b: sem node_modules no TargetHome (install offline)'
$mdB = [IO.File]::ReadAllText((Join-Path $ocB 'AGENTS.md'), [Text.Encoding]::UTF8)
Assert ($mdB.Contains('Adaptador OpenCode') -and (-not $mdB.Contains('Adaptador OpenCode V2'))) 'b: AGENTS.md com adapter V1'

# (c) user-owned preservado nos dois ------------------------------------------
foreach ($rt in @('V1', 'V2')) {
  $hC = New-TestHome ('c' + $rt) $rt
  $ocC = Join-Path $hC '.config\opencode'
  New-Item -ItemType Directory -Path $ocC -Force | Out-Null
  if ($rt -eq 'V1') {
    $fx = '{ "mcp": { "srv": { "type": "local", "command": ["node", "s.js"] } }, "plugin": ["file://./meu.ts"], "autoupdate": false, "meu_topo": "keep", "agent": { "meu-custom": { "model": "foo/bar" } } }'
  }
  else {
    $fx = '{ "mcp": { "srv": { "type": "local", "command": ["node", "s.js"] } }, "plugin": ["file://./meu.ts"], "autoupdate": false, "meu_topo": "keep", "permission": { "edit": "deny" }, "experimental": { "outra": true }, "agents": { "meu-custom": { "model": "foo/bar" } } }'
  }
  [IO.File]::WriteAllText((Join-Path $ocC 'opencode.json'), ($fx.TrimEnd() + "`n"), $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hC -Runtime $rt 2>&1
  Assert ($LASTEXITCODE -eq 0) ('c' + $rt + ': install exit 0 sobre fixture')
  $jC = ([IO.File]::ReadAllText((Join-Path $ocC 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ([string]$jC.meu_topo -eq 'keep') ('c' + $rt + ': topo custom preservado')
  Assert (($null -ne $jC.mcp) -and ($null -ne $jC.mcp.srv)) ('c' + $rt + ': mcp preservado')
  Assert ((@($jC.plugin)).Count -eq 1) ('c' + $rt + ': plugin preservado')
  Assert ([string]$jC.autoupdate -eq 'False') ('c' + $rt + ': autoupdate preservado')
  if ($rt -eq 'V2') {
    Assert ([string]$jC.permission.edit -eq 'deny') 'cV2: permission legada preservada no install'
  }
  if ($rt -eq 'V1') {
    Assert ([string]$jC.agent.'meu-custom'.model -eq 'foo/bar') 'cV1: agente custom preservado'
    Assert ((@($jC.agent.PSObject.Properties.Name).Count) -gt 17) 'cV1: agentes gerenciados somados ao custom'
  }
  else {
    Assert ([string]$jC.agents.'meu-custom'.model -eq 'foo/bar') 'cV2: agente custom preservado'
    Assert ((@($jC.agents.PSObject.Properties.Name).Count) -gt 17) 'cV2: agentes gerenciados somados ao custom'
    Assert ([string]$jC.experimental.outra -eq 'True') 'cV2: experimental.outra preservado'
  }
  if ($rt -eq 'V2') {
    $null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hC -Runtime V2 2>&1
    Assert ($LASTEXITCODE -eq 0) 'cV2: uninstall exit 0'
    $jCu = ([IO.File]::ReadAllText((Join-Path $ocC 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ([string]$jCu.permission.edit -eq 'deny') 'cV2: permission legada preservada no uninstall'
    Assert ([string]$jCu.meu_topo -eq 'keep') 'cV2: topo custom preservado no uninstall'
  }
}

# (d) JSONC nos dois ------------------------------------------------------------
foreach ($rt in @('V1', 'V2')) {
  $hD = New-TestHome ('d' + $rt) $rt
  $ocD = Join-Path $hD '.config\opencode'
  New-Item -ItemType Directory -Path $ocD -Force | Out-Null
  if ($rt -eq 'V1') {
    $bodyD = "{`n  // nota do usuario`n  `"model`": `"x/y`",`n  `"agent`": { `"meu-custom`": { `"model`": `"foo/bar`" }, },`n}`n"
  }
  else {
    $bodyD = "{`n  // nota do usuario`n  `"model`": `"x/y`",`n  `"agents`": { `"meu-custom`": { `"model`": `"foo/bar`" }, },`n}`n"
  }
  [IO.File]::WriteAllText((Join-Path $ocD 'opencode.jsonc'), $bodyD, $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hD -Runtime $rt 2>&1
  Assert ($LASTEXITCODE -eq 0) ('d' + $rt + ': install sobre jsonc exit 0')
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocD 'opencode.json') -PathType Leaf)) ('d' + $rt + ': nao cria opencode.json junto do jsonc')
  $jD = ([IO.File]::ReadAllText((Join-Path $ocD 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  if ($rt -eq 'V1') {
    Assert ((@($jD.agent.PSObject.Properties.Name).Count) -gt 1) 'dV1: merge somou agentes no jsonc'
  }
  else {
    Assert ((@($jD.agents.PSObject.Properties.Name).Count) -gt 1) 'dV2: merge somou agents no jsonc'
  }
}

# (e) repeat V2 idempotente ------------------------------------------------------
$hE = New-TestHome 'e' 'V2'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hE -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 0) 'e: primeiro install V2 exit 0'
$hashE1 = (Get-FileHash -LiteralPath (Join-Path $hE '.config\opencode\opencode.json') -Algorithm SHA256).Hash
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hE -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 0) 'e: segundo install V2 exit 0'
$hashE2 = (Get-FileHash -LiteralPath (Join-Path $hE '.config\opencode\opencode.json') -Algorithm SHA256).Hash
Assert ($hashE1 -eq $hashE2) 'e: config estavel entre runs'

# (f) uninstall V2 ---------------------------------------------------------------
$hF = New-TestHome 'f' 'V2'
$ocF = Join-Path $hF '.config\opencode'
New-Item -ItemType Directory -Path $ocF -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ocF 'AGENTS.md'), "# Notas do usuario`n", $utf8)
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hF -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 0) 'f: install V2 exit 0'
[IO.File]::WriteAllText((Join-Path $ocF 'agents\meu-custom.md'), "# custom`n", $utf8)
[IO.File]::WriteAllText((Join-Path $ocF 'skills\hybrid-development\nota.md'), "# nota`n", $utf8)
$jF = ([IO.File]::ReadAllText((Join-Path $ocF 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
$jF.agents | Add-Member -NotePropertyName 'meu-custom' -NotePropertyValue (([ordered]@{ model = 'foo/bar' } | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
$jF | Add-Member -NotePropertyName 'mcp' -NotePropertyValue (([ordered]@{ srv = [ordered]@{ type = 'local' } } | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
[IO.File]::WriteAllText((Join-Path $ocF 'opencode.json'), ((($jF | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), $utf8)
$null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hF 2>&1
Assert ($LASTEXITCODE -eq 0) 'f: uninstall V2 (via manifest) exit 0'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocF 'agents\coder.md') -PathType Leaf)) 'f: managed agents/coder.md removido'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocF 'plugins\orchestration-enforcement.js') -PathType Leaf)) 'f: plugin bundle removido'
Assert (Test-Path -LiteralPath (Join-Path $ocF 'agents\meu-custom.md') -PathType Leaf) 'f: agente custom permanece'
Assert (Test-Path -LiteralPath (Join-Path $ocF 'skills\hybrid-development\nota.md') -PathType Leaf) 'f: nota do usuario na skill permanece'
$jF2 = ([IO.File]::ReadAllText((Join-Path $ocF 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ([string]$jF2.agents.'meu-custom'.model -eq 'foo/bar') 'f: agents.meu-custom permanece no config'
Assert (($null -ne $jF2.mcp) -and ($null -ne $jF2.mcp.srv)) 'f: mcp permanece no config'
Assert (($null -eq ($jF2.agents | Get-Member -Name 'coder' -ErrorAction SilentlyContinue))) 'f: agents.coder removido do config'
Assert (($null -eq ($jF2 | Get-Member -Name '$schema' -ErrorAction SilentlyContinue))) 'f: $schema package-owned removido do config'
$tF = [IO.File]::ReadAllText((Join-Path $ocF 'AGENTS.md'), [Text.Encoding]::UTF8)
Assert (($tF -notmatch 'opencode-orchestration:start') -and ($tF.Contains('Notas do usuario'))) 'f: bloco removido, resto do usuario permanece'
Assert (-not (Test-Path -LiteralPath (Join-Path $hF '.opencode-orchestration\manifest.json') -PathType Leaf)) 'f: manifest removido ao final'

# (f2) uninstall V2 preserva $schema custom do usuario ---------------------------
$hF2 = New-TestHome 'f2' 'V2'
$ocF2 = Join-Path $hF2 '.config\opencode'
New-Item -ItemType Directory -Path $ocF2 -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ocF2 'opencode.json'), ('{ "$schema": "https://example.com/custom.json" }' + "`n"), $utf8)
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hF2 -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 0) 'f2: install V2 sobre $schema custom exit 0'
$jF2a = ([IO.File]::ReadAllText((Join-Path $ocF2 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ([string]$jF2a.'$schema' -eq 'https://opencode.ai/config.json') 'f2: install assume $schema do pacote'
[IO.File]::WriteAllText((Join-Path $ocF2 'opencode.json'), (((($jF2a | ConvertTo-Json -Depth 32).TrimEnd()) + "`n").Replace('https://opencode.ai/config.json', 'https://example.com/custom.json')), $utf8)
$null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hF2 2>&1
Assert ($LASTEXITCODE -eq 0) 'f2: uninstall V2 exit 0'
$jF2b = ([IO.File]::ReadAllText((Join-Path $ocF2 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
Assert ([string]$jF2b.'$schema' -eq 'https://example.com/custom.json') 'f2: $schema custom preservado no uninstall'

# (g) manifest legacy --------------------------------------------------------------
$hG = New-TestHome 'g' 'V1'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hG -Runtime V1 2>&1
Assert ($LASTEXITCODE -eq 0) 'g: install V1 exit 0'
$mfG = Join-Path $hG '.opencode-orchestration\manifest.json'
$mG = ([IO.File]::ReadAllText($mfG, [Text.Encoding]::UTF8)) | ConvertFrom-Json
$mG.package_version = '1.0.0'
$mG.PSObject.Properties.Remove('runtime')
[IO.File]::WriteAllText($mfG, ((($mG | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), $utf8)
$null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hG 2>&1
Assert ($LASTEXITCODE -eq 0) 'g: uninstall sobre manifest legacy exit 0 (como v1)'
Assert (-not (Test-Path -LiteralPath (Join-Path $hG '.config\opencode\agents\coder.md') -PathType Leaf)) 'g: managed removido via legacy'
$hG2 = New-TestHome 'g2' 'V1'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hG2 -Runtime V1 2>&1
Assert ($LASTEXITCODE -eq 0) 'g2: install V1 exit 0'
$mfG2 = Join-Path $hG2 '.opencode-orchestration\manifest.json'
$mG2 = ([IO.File]::ReadAllText($mfG2, [Text.Encoding]::UTF8)) | ConvertFrom-Json
$mG2.package_version = '1.0.0'
$mG2.PSObject.Properties.Remove('runtime')
[IO.File]::WriteAllText($mfG2, ((($mG2 | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), $utf8)
$null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hG2 -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 6) 'g2: uninstall -Runtime V2 sobre legacy => exit 6'
Assert (Test-Path -LiteralPath $mfG2 -PathType Leaf) 'g2: manifest intacto apos exit 6'

# (h) rollback V2 --------------------------------------------------------------------
$hH = New-TestHome 'h' 'V2'
$outH = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hH -Runtime V2 -InjectFailureAfter 'apply-json' 2>&1 | Out-String
Assert ($LASTEXITCODE -eq 5) 'h: V2 apply-json => exit 5'
Assert ($outH -match 'ROLLBACK_COMPLETED') 'h: ROLLBACK_COMPLETED'
Assert ($outH -notmatch 'ROLLBACK_REQUIRED') 'h: sem ROLLBACK_REQUIRED'
Assert (-not (Test-Path -LiteralPath (Join-Path $hH '.config\opencode\opencode.json') -PathType Leaf)) 'h: config revertido (ausente em fresh)'
Assert (-not (Test-Path -LiteralPath (Join-Path $hH '.opencode-orchestration\manifest.json') -PathType Leaf)) 'h: manifest ausente apos rollback'

# (i) Both bloqueado --------------------------------------------------------------------
$hI = New-TestHome 'i' 'V1'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hI -Runtime Both 2>&1
Assert ($LASTEXITCODE -eq 6) 'i: -Runtime Both => exit 6'
Assert (-not (Test-Path -LiteralPath (Join-Path $hI '.opencode-orchestration\manifest.json') -PathType Leaf)) 'i: nada escrito com Both'

# (j) Auto com binario V2 ---------------------------------------------------------------
# Processo-filho com PATH contendo SO o .bin do probe V2: Write-Host do
# install (5.1, console direto) so e capturavel no nivel do SO.
$hJ = New-TestHome 'j' 'V2'
$probeBin = Join-Path $RepoRoot 'cache\v2-probe\node_modules\.bin'
$oldPath = $env:PATH
try {
  if (Test-Path -LiteralPath $probeBin -PathType Container) {
    $psiJ = New-Object System.Diagnostics.ProcessStartInfo
    $psiJ.FileName = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psiJ.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $RepoRoot 'install.ps1') + '" -TargetHome "' + $hJ + '" -Runtime Auto'
    $psiJ.UseShellExecute = $false
    $psiJ.RedirectStandardOutput = $true
    $psiJ.RedirectStandardError = $true
    $psiJ.CreateNoWindow = $true
    $psiJ.WorkingDirectory = $RepoRoot
    try { $psiJ.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
    $psiJ.EnvironmentVariables['PATH'] = $probeBin
    $pJ = [System.Diagnostics.Process]::Start($psiJ)
    $outJ = $pJ.StandardOutput.ReadToEnd()
    $errJ = $pJ.StandardError.ReadToEnd()
    $pJ.WaitForExit(120000)
    $codeJ = $pJ.ExitCode
    try { $pJ.Close() } catch { }
    $bothJ = ($outJ + "`n" + $errJ)
    Write-Host $bothJ
    Assert ($codeJ -eq 0) 'j: Auto com V2 no PATH exit 0'
    Assert ($bothJ -match 'version 2\.x reconhecida') 'j: smoke reconheceu version 2.x'
    Assert ($bothJ -match 'debug paths resolve config dentro do TargetHome') 'j: smoke debug paths ok'
    $mJ = ([IO.File]::ReadAllText((Join-Path $hJ '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ($mJ.runtime.id -eq 'opencode-v2') 'j: Auto resolveu para v2'
  }
  else {
    Write-Host 'ok - j: probe V2 ausente no repo (skip ambiental)'
    $script:pass += 1
  }
}
finally {
  $env:PATH = $oldPath
}

# (k) cross-check uninstall ----------------------------------------------------------------
# (k2) V31-P6-FIX-EXPLICIT: -Runtime V2 com binario V1 global presente segue V2 (explicit wins)
$hK = New-TestHome 'k' 'V1'
$null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hK -Runtime V1 2>&1
Assert ($LASTEXITCODE -eq 0) 'k: install V1 exit 0'
$null = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $hK -Runtime V2 2>&1
Assert ($LASTEXITCODE -eq 6) 'k: uninstall -Runtime V2 sobre manifest v1 => exit 6'
Assert (Test-Path -LiteralPath (Join-Path $hK '.opencode-orchestration\manifest.json') -PathType Leaf) 'k: manifest intacto apos exit 6'

# (k2) explicit wins com binario oposto no PATH ----------------------------------
$hK2 = New-TestHome 'k2' 'V2'
$shimK2 = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-shimv1-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $shimK2 -Force | Out-Null
[void]$homes.Add($shimK2)
[IO.File]::WriteAllText((Join-Path $shimK2 'opencode.cmd'), ("@echo off`n" + 'echo ' + $runtimeV1Version + "`n"), $utf8)
$oldK2 = $env:PATH
try {
  $env:PATH = $shimK2 + ';' + $env:PATH
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $hK2 -Runtime V2 2>&1
  Assert ($LASTEXITCODE -eq 0) 'k2: install V2 com V1 global no PATH exit 0 (explicit wins)'
  $mK2 = ([IO.File]::ReadAllText((Join-Path $hK2 '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($mK2.runtime.id -eq 'opencode-v2') 'k2: manifest runtime.id v2 apesar do V1 global'
}
finally {
  $env:PATH = $oldK2
}

# (l) reconcile com fonte ausente => exit 6 sem escrita -------------------------
$hL = New-TestHome 'l' 'V1'
$ocL = Join-Path $hL '.config\opencode'
$genL = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-gen-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $genL -Force | Out-Null
[void]$homes.Add($genL)
$recL = Join-Path $RepoRoot 'scripts\reconcile-opencode-config.ps1'
$outL = & $recL -Runtime V2 -GeneratedRoot $genL -UserProfileRoot $hL *>&1 | Out-String
Assert ($LASTEXITCODE -eq 6) 'l: reconcile -Runtime V2 sem fonte => exit 6'
Assert ($outL -match 'render-opencode-config') 'l: mensagem orienta renderize'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocL 'AGENTS.md') -PathType Leaf)) 'l: nada escrito sem fonte V2'
$outL1 = & $recL -Runtime V1 -GeneratedRoot $genL -UserProfileRoot $hL *>&1 | Out-String
Assert ($LASTEXITCODE -eq 6) 'l: reconcile -Runtime V1 sem fonte => exit 6'
Assert (-not (Test-Path -LiteralPath (Join-Path $ocL 'AGENTS.md') -PathType Leaf)) 'l: nada escrito sem fonte V1'

# (o) reconcile SAME/DIFFERENT + anti-regressao [{0}] (BUG1) ----------------
$genO = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-gen-o-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $genO 'opencode\v2') -Force | Out-Null
[void]$homes.Add($genO)
$srcO = @'
<!-- GENERATED FILE: direct edits will be overwritten. -->
<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->
<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->

# conteudo de teste reconcile
linha dois sem tokens
'@
[IO.File]::WriteAllText((Join-Path $genO 'opencode\v2\AGENTS.md'), ($srcO.TrimEnd() + "`n"), $utf8)
$hO = New-TestHome 'o' 'V2'
$ocO = Join-Path $hO '.config\opencode'
New-Item -ItemType Directory -Path $ocO -Force | Out-Null
$divO = "# Notas do usuario`n`n<!-- opencode-orchestration:start -->`nconteudo antigo divergente`n<!-- opencode-orchestration:end -->`n"
[IO.File]::WriteAllText((Join-Path $ocO 'AGENTS.md'), $divO, $utf8)
$recO = Join-Path $RepoRoot 'scripts\reconcile-opencode-config.ps1'
$hashBeforeO = (Get-FileHash -LiteralPath (Join-Path $ocO 'AGENTS.md') -Algorithm SHA256).Hash
$outDiffO = & $recO -Runtime V2 -GeneratedRoot $genO -UserProfileRoot $hO *>&1 | Out-String
Assert ($LASTEXITCODE -eq 0) 'o: preview DIFFERENT exit 0'
Assert ($outDiffO -match '\[DIFFERENT\]') 'o: preview imprime [DIFFERENT]'
Assert ($outDiffO -notmatch '\[\{0\}\]') 'o: sem literal [{0}] (BUG1)'
$mO = [regex]::Match($outDiffO, 'current\s+([0-9A-F]{12})\s*;\s*desired\s+([0-9A-F]{12})')
Assert ($mO.Success -and ($mO.Groups[1].Value -ne $mO.Groups[2].Value)) 'o: current != desired no DIFFERENT'
$hashAfterPreviewO = (Get-FileHash -LiteralPath (Join-Path $ocO 'AGENTS.md') -Algorithm SHA256).Hash
Assert ($hashBeforeO -eq $hashAfterPreviewO) 'o: preview nao escreve'

# (p) reconcile desired final == aplicado + SAME seguinte (BUG2) ------------
$desiredShortO = $mO.Groups[2].Value
$outApplyO = & $recO -Runtime V2 -GeneratedRoot $genO -UserProfileRoot $hO -Apply *>&1 | Out-String
Assert ($LASTEXITCODE -eq 0) 'p: apply exit 0'
Assert ($outApplyO -notmatch '\[\{0\}\]') 'p: apply sem literal [{0}]'
$fileHashO = (Get-FileHash -LiteralPath (Join-Path $ocO 'AGENTS.md') -Algorithm SHA256).Hash
Assert ($fileHashO.Substring(0, 12) -eq $desiredShortO) 'p: hash aplicado == desired do preview (BUG2)'
$outSameO = & $recO -Runtime V2 -GeneratedRoot $genO -UserProfileRoot $hO *>&1 | Out-String
Assert ($LASTEXITCODE -eq 0) 'p: preview pos-apply exit 0'
Assert ($outSameO -match '\[SAME\]') 'p: preview seguinte imprime [SAME]'
Assert ($outSameO -notmatch '\[\{0\}\]') 'p: SAME sem literal [{0}]'
$hashAfterSameO = (Get-FileHash -LiteralPath (Join-Path $ocO 'AGENTS.md') -Algorithm SHA256).Hash
Assert ($hashAfterSameO -eq $fileHashO) 'p: preview SAME nao altera arquivo'

# (m) F3: selecao de templates por runtime (unit + estatico) --------------------
# Carrega as funcoes reais do install.ps1 via AST no escopo do script (sem
# executar o instalador): FindAll + dot-source em nivel de script, pois
# definir dentro de funcao auxiliar limitaria ao escopo local.
$mErrs = $null
$mToks = $null
$mAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'install.ps1'), [ref]$mToks, [ref]$mErrs)
foreach ($mFn in @('Has-Member', 'Resolve-Tokens', 'Count-TokenMarkers', 'Read-Utf8', 'Validate-TemplateV2', 'Get-RequiredTemplatesForRuntime')) {
  $mFound = @($mAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -eq $mFn })
  if ($mFound.Count -eq 0) { throw ('funcao nao encontrada em install.ps1: ' + $mFn) }
  . ([scriptblock]::Create($mFound[0].Extent.Text))
}
$tV1 = @(Get-RequiredTemplatesForRuntime 'opencode-v1')
Assert (($tV1.Count -eq 1) -and ($tV1[0] -eq 'templates\opencode.v1.json.tmpl')) 'm: runtime v1 exige so template v1'
$tV2 = @(Get-RequiredTemplatesForRuntime 'opencode-v2')
Assert (($tV2.Count -eq 1) -and ($tV2[0] -eq 'templates\opencode.v2.json.tmpl')) 'm: runtime v2 exige so template v2'
$installText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'install.ps1'), [Text.Encoding]::UTF8)
Assert ($installText.Contains('if ($preIsV2)')) 'm: validacao de template usa runtime resolvido (preIsV2)'
Assert ($installText.Contains('Validate-RequiredFiles $RepoRoot $preTemplates')) 'm: precheck de arquivos usa templates do runtime'

# (n) F4: templates V2 adulterados falham sem escrita ---------------------------
$tmplReal = [IO.File]::ReadAllText((Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'), [Text.Encoding]::UTF8)
function New-TamperRoot([string]$Tag, [scriptblock]$Mutate) {
  $tr = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-tmpl-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $tr 'templates') -Force | Out-Null
  [void]$homes.Add($tr)
  $tresolved = $tmplReal.Replace('{{MODEL_PLANNER}}', 'a/b').Replace('{{MODEL_CHEAP}}', 'c/d').Replace('{{MODEL_STRONG}}', 'e/f').Replace('{{HOME}}', 'C:/x').Replace('{{REPO_DIR}}', 'C:/y')
  $tobj = $tresolved | ConvertFrom-Json
  & $Mutate $tobj | Out-Null
  [IO.File]::WriteAllText((Join-Path $tr 'templates\opencode.v2.json.tmpl'), ((($tobj | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), $utf8)
  return $tr
}
$rN1 = New-TamperRoot 'n1' { param($o) $null = $o.experimental.PSObject.Properties.Remove('subagent_depth') }
$vN1 = Validate-TemplateV2 $rN1 'a/b' 'c/d' 'e/f'
Assert (-not $vN1.Ok) 'n: subagent_depth ausente => invalido'
Assert ((@($vN1.Errors | Where-Object { $_ -match 'subagent_depth' }).Count) -gt 0) 'n: erro cita subagent_depth'
$rN2 = New-TamperRoot 'n2' { param($o) $o.agents.coder.permissions = (New-Object PSObject) }
$vN2 = Validate-TemplateV2 $rN2 'a/b' 'c/d' 'e/f'
Assert (-not $vN2.Ok) 'n: permissions como objeto => invalido'
Assert ((@($vN2.Errors | Where-Object { $_ -match 'permissions.*array' }).Count) -gt 0) 'n: erro cita permissions array'
$rN3 = New-TamperRoot 'n3' { param($o) $o.agents.coder.permissions[0].effect = 'maybe' }
$vN3 = Validate-TemplateV2 $rN3 'a/b' 'c/d' 'e/f'
Assert (-not $vN3.Ok) 'n: effect invalido => invalido'
Assert ((@($vN3.Errors | Where-Object { $_ -match 'allow\|ask\|deny' }).Count) -gt 0) 'n: erro cita allow|ask|deny'

foreach ($h in @($homes)) {
  if (Test-Path -LiteralPath $h) { Remove-Item -LiteralPath $h -Recurse -Force -ErrorAction SilentlyContinue }
}
$env:PATH = $origPath
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
