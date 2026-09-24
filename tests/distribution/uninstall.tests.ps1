# uninstall.tests.ps1 — install em home temp, mutacoes do usuario, uninstall, ownership.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-uninst-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  $ocDir = Join-Path $TmpHome '.config\opencode'
  New-Item -ItemType Directory -Path $ocDir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocDir 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $ocDir 'AGENTS.md'), "# Notas do usuario`n`nConteudo fora dos markers que deve sobreviver.`n", (New-Object Text.UTF8Encoding $false))

  # Install limpo ------------------------------------------------------------
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  Assert ($LASTEXITCODE -eq 0) 'install exit 0'
  $mf = Join-Path $TmpHome '.opencode-orchestration\manifest.json'
  Assert (Test-Path -LiteralPath $mf -PathType Leaf) 'manifest criado pelo install'

  # Mutacoes do usuario apos o install ---------------------------------------
  $extraSkill = Join-Path $ocDir 'skills\hybrid-development\minhas-notas.md'
  [IO.File]::WriteAllText($extraSkill, "# notas do usuario na skill`n", (New-Object Text.UTF8Encoding $false))
  $customAgent = Join-Path $ocDir 'agents\meu-custom.md'
  [IO.File]::WriteAllText($customAgent, "# agente custom do usuario`n", (New-Object Text.UTF8Encoding $false))
  $jsonPath = Join-Path $ocDir 'opencode.json'
  $j = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $j.agent | Add-Member -NotePropertyName 'meu-custom' -NotePropertyValue (([ordered]@{ model = 'foo/bar' } | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
  $j | Add-Member -NotePropertyName 'mcp' -NotePropertyValue (([ordered]@{ 'my-server' = [ordered]@{ type = 'local'; command = @('node', 'srv.js') } } | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
  $j | Add-Member -NotePropertyName 'meu_topo_custom' -NotePropertyValue 'keep-me' -Force
  # Worker managed com permissao extra do usuario (task intacto = "deny") ------
  $j.agent.coder.permission | Add-Member -NotePropertyName 'bash' -NotePropertyValue (([ordered]@{ '*' = 'ask' } | ConvertTo-Json -Depth 8) | ConvertFrom-Json) -Force
  # Plugin com entrada do usuario: ownership passa a ser do usuario ------------
  $j.plugin = @('file://./meu-plugin.ts')
  [IO.File]::WriteAllText($jsonPath, ((($j | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))

  # Uninstall ----------------------------------------------------------------
  $out = & (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $TmpHome *>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0) 'uninstall exit 0'

  # Pacote removido -----------------------------------------------------------
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocDir 'agents\coder.md') -PathType Leaf)) 'managed agents/coder.md removido'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocDir 'skills\hybrid-development\SKILL.md') -PathType Leaf)) 'managed skills/hybrid-development/SKILL.md removido'
  Assert (-not (Test-Path -LiteralPath (Join-Path $ocDir 'plugins\orchestration-enforcement.ts') -PathType Leaf)) 'managed plugin removido'
  $j2 = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  $hasExplorer = ($null -ne ($j2.agent | Get-Member -Name 'explorer' -ErrorAction SilentlyContinue))
  Assert (-not $hasExplorer) 'opencode.json agent.explorer removido (managed intacto; coder tem permissao extra e e avaliado abaixo)'
  $t = [IO.File]::ReadAllText((Join-Path $ocDir 'AGENTS.md'), [Text.Encoding]::UTF8)
  Assert (($t -notmatch 'opencode-orchestration:start') -and ($t -notmatch 'opencode-orchestration:end')) 'AGENTS.md bloco markered removido'
  Assert (-not (Test-Path -LiteralPath $mf -PathType Leaf)) 'manifest removido ao final'
  Assert ($out.Contains('[KEEP] plugin')) 'uninstall lista [KEEP] plugin (conteudo do usuario)'
  Assert ((@($j2.plugin)).Count -eq 1 -and (@($j2.plugin))[0] -eq 'file://./meu-plugin.ts') 'plugin com entrada do usuario preservado (chave inteira mantida)'

  # Permission extra do usuario: task removido, extra mantido, sem orfao -------
  $coderTask = 'ABSENT'
  if (($null -ne $j2.agent.coder) -and ($null -ne $j2.agent.coder.permission)) {
    $tp = $j2.agent.coder.permission.PSObject.Properties['task']
    if ($null -ne $tp) { $coderTask = $tp.Value }
  }
  Assert (($coderTask -eq 'ABSENT') -or ($null -eq $coderTask)) 'worker coder: permission.task managed removido'
  Assert ($j2.agent.coder.permission.bash.'*' -eq 'ask') 'worker coder: permissao extra do usuario preservada'
  $orphans = New-Object System.Collections.ArrayList
  $wk = @('build', 'explorer', 'researcher', 'coder', 'tester', 'reviewer', 'debugger', 'security-reviewer', 'architect', 'docs-manager', 'frontend-engineer', 'backend-engineer', 'database-engineer', 'ai-agent-engineer', 'automation-engineer', 'infra-engineer')
  foreach ($w in $wk) {
    $nd = $j2.agent.$w
    if (($null -ne $nd) -and ($null -ne $nd.permission) -and ($nd.permission -is [System.Management.Automation.PSObject]) -and (@($nd.permission.PSObject.Properties).Count -eq 0)) { [void]$orphans.Add($w) }
  }
  Assert ($orphans.Count -eq 0) 'nenhum permission:{} orfao em workers managed'
  Assert ($null -eq ($j2.agent | Get-Member -Name 'tester' -ErrorAction SilentlyContinue)) 'worker tester sem extra: no vazio removido (permission limpo)'

  # Usuario preservado ---------------------------------------------------------
  Assert (Test-Path -LiteralPath $customAgent -PathType Leaf) 'custom agents/meu-custom.md preservado'
  Assert (Test-Path -LiteralPath $extraSkill -PathType Leaf) 'arquivo extra na skill preservado'
  Assert ($j2.mcp.'my-server'.command[1] -eq 'srv.js') 'mcp.* preservado'
  Assert ($j2.agent.'meu-custom'.model -eq 'foo/bar') 'custom agent no json preservado'
  Assert ($j2.meu_topo_custom -eq 'keep-me') 'chave de topo custom preservada'
  Assert ($t.Contains('Conteudo fora dos markers')) 'AGENTS.md conteudo do usuario preservado'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
