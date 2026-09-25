# config-format.tests.ps1 — suporte opencode.json/opencode.jsonc + trim de ownership.
# (a) home sem config -> cria opencode.json trimmed (sem skills/plugin/autoupdate);
# (b) home com opencode.jsonc (comentarios // e /* */ + trailing comma) -> merge
#     DENTRO do jsonc, NAO cria opencode.json, resultado parseia e mantem usuario;
# (c) home com json + jsonc -> alvo e o jsonc, opencode.json intacto (byte-exato);
# (d) uninstall sobre jsonc -> remove so chaves managed, preserva usuario.
# PS 5.1 compativel (sem ternario, sem ??, sem Invoke-Expression).
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$utf8 = New-Object Text.UTF8Encoding $false

function New-TestHome([string]$Tag) {
  $h = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-cfg-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $h -Force | Out-Null
  $plugDir = Join-Path $h '.config\opencode\node_modules\@opencode-ai\plugin'
  New-Item -ItemType Directory -Path $plugDir -Force | Out-Null
  # Pin local da dependencia: evita tentativa de rede (best-effort) nos testes.
  [IO.File]::WriteAllText((Join-Path $plugDir 'package.json'), '{"name":"@opencode-ai/plugin","version":"1.18.32"}', $utf8)
  return $h
}

function Get-JsoncFixture() {
  # Fixture JSONC: comentarios // e /* */, trailing commas, chaves do usuario
  # (mcp, agente custom, plugin com entrada, skills.paths, autoupdate) e uma
  # string contendo // para provar que o conversor respeita literais.
  $lines = @(
    '{',
    '  // comentario de linha do usuario',
    '  "$schema": "https://opencode.ai/config.json",',
    '  /* bloco de comentario',
    '     em duas linhas */',
    '  "model": "user/planner-model",',
    '  "notas": "http://exemplo/ com // dentro de string",',
    '  "agent": {',
    '    "build": { "mode": "primary", },',
    '    "coder": { "mode": "subagent", "model": "old/model", },',
    '    "meu-custom": { "model": "foo/bar" },',
    '  },',
    '  "mcp": { "my-server": { "type": "local", "command": ["node", "srv.js"] } },',
    '  "plugin": ["my-plugin"],',
    '  "skills": { "paths": ["~/minhas-skills"] },',
    '  "autoupdate": true,',
    '  "meu_topo_custom": "keep-me",',
    '}'
  )
  return ($lines -join "`n") + "`n"
}

# ---- (a) home sem config -> cria opencode.json trimmed -----------------------
$TmpA = New-TestHome 'a'
try {
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpA 2>&1
  Assert ($LASTEXITCODE -eq 0) 'a: install exit 0'
  $ocA = Join-Path $TmpA '.config\opencode'
  Assert (Test-Path -LiteralPath (Join-Path $ocA 'opencode.json') -PathType Leaf) 'a: opencode.json criado'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocA 'opencode.jsonc') -PathType Leaf)) 'a: opencode.jsonc NAO criado'
  $ja = ([IO.File]::ReadAllText((Join-Path $ocA 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (($null -eq ($ja | Get-Member -Name 'skills' -ErrorAction SilentlyContinue))) 'a: sem chave skills (trim)'
  Assert (($null -eq ($ja | Get-Member -Name 'plugin' -ErrorAction SilentlyContinue))) 'a: sem chave plugin (trim)'
  Assert (($null -eq ($ja | Get-Member -Name 'autoupdate' -ErrorAction SilentlyContinue))) 'a: sem chave autoupdate (trim)'
  Assert ((@($ja.agent.PSObject.Properties.Name).Count) -eq 17) 'a: 17 blocos agent (chaves geridas)'
  Assert (($null -ne ($ja | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) 'a: root model gerido presente'
}
finally {
  if (Test-Path -LiteralPath $TmpA) { Remove-Item -LiteralPath $TmpA -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- (b) home com opencode.jsonc -> merge dentro do jsonc --------------------
$TmpB = New-TestHome 'b'
try {
  $ocB = Join-Path $TmpB '.config\opencode'
  [IO.File]::WriteAllText((Join-Path $ocB 'opencode.jsonc'), (Get-JsoncFixture), $utf8)
  # *>&1 (nao 2>&1): plano/AVISOs saem via Write-Host (information stream).
  $outB = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpB *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'b: install exit 0'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocB 'opencode.json') -PathType Leaf)) 'b: opencode.json NAO criado (alvo e o jsonc)'
  $rawB = [IO.File]::ReadAllText((Join-Path $ocB 'opencode.jsonc'), [Text.Encoding]::UTF8)
  $jb = $null
  $parseOk = $true
  try { $jb = $rawB | ConvertFrom-Json } catch { $parseOk = $false }
  Assert ($parseOk) 'b: jsonc resultante parseia como JSON puro'
  $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
  Assert ($jb.model -eq $models.planner) 'b: root model gerenciado aplicado'
  Assert ($jb.agent.coder.model -eq $models.cheap) 'b: coder.model gerenciado aplicado'
  Assert ($jb.mcp.'my-server'.command[1] -eq 'srv.js') 'b: mcp.* do usuario preservado'
  Assert ($jb.agent.'meu-custom'.model -eq 'foo/bar') 'b: agente custom preservado'
  Assert ($jb.meu_topo_custom -eq 'keep-me') 'b: topo custom preservado'
  Assert ($jb.notas -eq 'http://exemplo/ com // dentro de string') 'b: string com // intacta (conversor respeita literais)'
  Assert ((@($jb.plugin)).Count -eq 1 -and (@($jb.plugin))[0] -eq 'my-plugin') 'b: plugin do usuario intacto (sem ownership)'
  Assert ((@($jb.skills.paths)).Count -eq 1 -and (@($jb.skills.paths))[0] -eq '~/minhas-skills') 'b: skills.paths do usuario intacto'
  Assert ($jb.autoupdate -eq $true) 'b: autoupdate do usuario intacto'
  Assert ($outB -match 'comentarios do seu opencode\.jsonc foram normalizados') 'b: AVISO de normalizacao emitido'
  Assert ($outB -match '\[UPDATE\] opencode\.jsonc \(merged; comentarios normalizados\)') 'b: plano com [UPDATE] opencode.jsonc (merged; comentarios normalizados)'
}
finally {
  if (Test-Path -LiteralPath $TmpB) { Remove-Item -LiteralPath $TmpB -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- (c) json + jsonc -> alvo e o jsonc; json intacto -------------------------
$TmpC = New-TestHome 'c'
try {
  $ocC = Join-Path $TmpC '.config\opencode'
  $jsonSentinel = '{"model":"sentinel/json","sentinel":"C-json"}' + "`n"
  [IO.File]::WriteAllText((Join-Path $ocC 'opencode.json'), $jsonSentinel, $utf8)
  [IO.File]::WriteAllText((Join-Path $ocC 'opencode.jsonc'), (Get-JsoncFixture), $utf8)
  $hashBefore = (Get-FileHash -LiteralPath (Join-Path $ocC 'opencode.json') -Algorithm SHA256).Hash
  $outC = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpC *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'c: install exit 0'
  $hashAfter = (Get-FileHash -LiteralPath (Join-Path $ocC 'opencode.json') -Algorithm SHA256).Hash
  Assert ($hashBefore -eq $hashAfter) 'c: opencode.json intacto (byte/hash-exato)'
  Assert ($outC -match '\[PRESERVE\] opencode\.json \(presente junto de jsonc') 'c: plano com [PRESERVE] opencode.json (jsonc vence)'
  $jc = ([IO.File]::ReadAllText((Join-Path $ocC 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($jc.agent.'meu-custom'.model -eq 'foo/bar') 'c: jsonc foi o alvo do merge (usuario preservado + geridas aplicadas)'
}
finally {
  if (Test-Path -LiteralPath $TmpC) { Remove-Item -LiteralPath $TmpC -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- (d) uninstall sobre jsonc -> so managed sai, usuario fica ---------------
$TmpD = New-TestHome 'd'
try {
  $ocD = Join-Path $TmpD '.config\opencode'
  [IO.File]::WriteAllText((Join-Path $ocD 'opencode.jsonc'), (Get-JsoncFixture), $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpD 2>&1
  Assert ($LASTEXITCODE -eq 0) 'd: install exit 0'
  $outD = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $TmpD *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'd: uninstall exit 0'
  Assert (Test-Path -LiteralPath (Join-Path $ocD 'opencode.jsonc') -PathType Leaf) 'd: opencode.jsonc mantido (nao apagado)'
  $jd = ([IO.File]::ReadAllText((Join-Path $ocD 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $hasExplorer = ($null -ne ($jd.agent | Get-Member -Name 'explorer' -ErrorAction SilentlyContinue))
  Assert (-not $hasExplorer) 'd: agent.explorer managed removido'
  Assert ($jd.mcp.'my-server'.command[1] -eq 'srv.js') 'd: mcp.* preservado'
  Assert ($jd.agent.'meu-custom'.model -eq 'foo/bar') 'd: agente custom preservado'
  Assert ($jd.meu_topo_custom -eq 'keep-me') 'd: topo custom preservado'
  Assert ((@($jd.plugin))[0] -eq 'my-plugin') 'd: plugin do usuario preservado'
  Assert ((@($jd.skills.paths))[0] -eq '~/minhas-skills') 'd: skills.paths do usuario preservado'
  Assert ($jd.autoupdate -eq $true) 'd: autoupdate do usuario preservado'
}
finally {
  if (Test-Path -LiteralPath $TmpD) { Remove-Item -LiteralPath $TmpD -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- (e) JSONC edge: virgula + comentario antes do fechamento -------------
# Regressao duas fases: o lookahead de virgula no texto ORIGINAL enxergava
# '/' de comentario e nao removia a virgula (exit 3 no precheck).
$TmpE1 = New-TestHome 'e1'
try {
  $ocE1 = Join-Path $TmpE1 '.config\opencode'
  $e1 = '{' + "`n" + '  "a": 1, // comentario de linha' + "`n" + '}' + "`n"
  [IO.File]::WriteAllText((Join-Path $ocE1 'opencode.jsonc'), $e1, $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpE1 2>&1
  Assert ($LASTEXITCODE -eq 0) 'e1: install exit 0 (virgula + // antes de })'
  $je1 = ([IO.File]::ReadAllText((Join-Path $ocE1 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($je1.a -eq 1) 'e1: chave preservada apos strip duas fases'
}
finally {
  if (Test-Path -LiteralPath $TmpE1) { Remove-Item -LiteralPath $TmpE1 -Recurse -Force -ErrorAction SilentlyContinue }
}

$TmpE2 = New-TestHome 'e2'
try {
  $ocE2 = Join-Path $TmpE2 '.config\opencode'
  $e2 = '{' + "`n" + '  "a": [1, 2, /* bloco */ ]' + "`n" + '}' + "`n"
  [IO.File]::WriteAllText((Join-Path $ocE2 'opencode.jsonc'), $e2, $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpE2 2>&1
  Assert ($LASTEXITCODE -eq 0) 'e2: install exit 0 (virgula + /* bloco */ antes de ])'
  $je2 = ([IO.File]::ReadAllText((Join-Path $ocE2 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ((@($je2.a)).Count -eq 2 -and (@($je2.a))[1] -eq 2) 'e2: array preservado apos strip duas fases'
}
finally {
  if (Test-Path -LiteralPath $TmpE2) { Remove-Item -LiteralPath $TmpE2 -Recurse -Force -ErrorAction SilentlyContinue }
}

$TmpE3 = New-TestHome 'e3'
try {
  $ocE3 = Join-Path $TmpE3 '.config\opencode'
  $e3lines = @(
    '{',
    '  "a": 1 /* comentario',
    '     multiline */,',
    '  "b": 2,',
    '}'
  )
  [IO.File]::WriteAllText((Join-Path $ocE3 'opencode.jsonc'), (($e3lines -join "`n") + "`n"), $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpE3 2>&1
  Assert ($LASTEXITCODE -eq 0) 'e3: install exit 0 (virgula apos bloco multiline + trailing)'
  $je3 = ([IO.File]::ReadAllText((Join-Path $ocE3 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (($je3.a -eq 1) -and ($je3.b -eq 2)) 'e3: chaves preservadas apos bloco multiline'
}
finally {
  if (Test-Path -LiteralPath $TmpE3) { Remove-Item -LiteralPath $TmpE3 -Recurse -Force -ErrorAction SilentlyContinue }
}

$TmpE4 = New-TestHome 'e4'
try {
  $ocE4 = Join-Path $TmpE4 '.config\opencode'
  $e4lines = @(
    '{',
    '  "s1": "a // b",',
    '  "s2": "x /* y */ z",',
    '}'
  )
  [IO.File]::WriteAllText((Join-Path $ocE4 'opencode.jsonc'), (($e4lines -join "`n") + "`n"), $utf8)
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpE4 2>&1
  Assert ($LASTEXITCODE -eq 0) 'e4: install exit 0 (marcadores dentro de string)'
  $je4 = ([IO.File]::ReadAllText((Join-Path $ocE4 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($je4.s1 -eq 'a // b') 'e4: // dentro de string intacto'
  Assert ($je4.s2 -eq 'x /* y */ z') 'e4: /* */ dentro de string intacto'
}
finally {
  if (Test-Path -LiteralPath $TmpE4) { Remove-Item -LiteralPath $TmpE4 -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- (f) uninstall respeita o arquivo do manifest apos troca de formato -----
# install gere opencode.json; usuario cria opencode.jsonc depois; uninstall
# deve operar o ARQUIVO DO MANIFEST (json), deixando o jsonc intacto.
$TmpF = New-TestHome 'f'
try {
  $ocF = Join-Path $TmpF '.config\opencode'
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpF 2>&1
  Assert ($LASTEXITCODE -eq 0) 'f: install exit 0 (cria opencode.json)'
  Assert (Test-Path -LiteralPath (Join-Path $ocF 'opencode.json') -PathType Leaf) 'f: opencode.json criado pelo install'
  $manF = ([IO.File]::ReadAllText((Join-Path $TmpF '.opencode-orchestration\manifest.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $manRels = @($manF.managed_files | ForEach-Object { ([string]$_.relative) -replace '/', '\' })
  Assert ($manRels -contains 'opencode.json') 'f: manifest registra opencode.json'
  $userJsonc = '{"agent":{"meu-custom":{"model":"foo/bar"}},"meu_topo":"keep"}' + "`n"
  [IO.File]::WriteAllText((Join-Path $ocF 'opencode.jsonc'), $userJsonc, $utf8)
  $hashFBefore = (Get-FileHash -LiteralPath (Join-Path $ocF 'opencode.jsonc') -Algorithm SHA256).Hash
  $outF = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $TmpF *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'f: uninstall exit 0'
  $hashFAfter = (Get-FileHash -LiteralPath (Join-Path $ocF 'opencode.jsonc') -Algorithm SHA256).Hash
  Assert ($hashFBefore -eq $hashFAfter) 'f: opencode.jsonc do usuario intacto (manifest vence deteccao)'
  $jf = ([IO.File]::ReadAllText((Join-Path $ocF 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $hasExplorerF = ($null -ne ($jf.agent | Get-Member -Name 'explorer' -ErrorAction SilentlyContinue))
  Assert (-not $hasExplorerF) 'f: agent.explorer managed removido do opencode.json (arquivo do manifest)'
  $jf2 = ([IO.File]::ReadAllText((Join-Path $ocF 'opencode.jsonc'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($jf2.agent.'meu-custom'.model -eq 'foo/bar') 'f: agente custom no jsonc preservado'
  Assert ($jf2.meu_topo -eq 'keep') 'f: topo custom no jsonc preservado'
}
finally {
  if (Test-Path -LiteralPath $TmpF) { Remove-Item -LiteralPath $TmpF -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
