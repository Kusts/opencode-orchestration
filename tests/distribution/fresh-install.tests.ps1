# fresh-install.tests.ps1 — instalacao limpa em home temporario.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-fresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  New-Item -ItemType Directory -Path (Join-Path $TmpHome '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
  $out = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  $code = $LASTEXITCODE
  Assert ($code -eq 0) 'install exit 0'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $agentsMd = Join-Path $ocDir 'AGENTS.md'
  Assert (Test-Path -LiteralPath $agentsMd -PathType Leaf) 'AGENTS.md criado'
  if (Test-Path -LiteralPath $agentsMd -PathType Leaf) {
    $t = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'AGENTS.md 1 marker start'
    Assert (([regex]::Matches($t, '<!-- opencode-orchestration:end -->')).Count -eq 1) 'AGENTS.md 1 marker end'
    Assert ($t -notmatch '\{\{[^}]+\}\}') 'AGENTS.md sem tokens'
  }
  $agentFiles = @(Get-ChildItem -File (Join-Path $ocDir 'agents\*.md') -ErrorAction SilentlyContinue)
  Assert ($agentFiles.Count -eq 19) ('19 agents instalados (achado ' + $agentFiles.Count + ')')
  $jsonPath = Join-Path $ocDir 'opencode.json'
  Assert (Test-Path -LiteralPath $jsonPath -PathType Leaf) 'opencode.json criado'
  if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
    $j = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ((@($j.agent.PSObject.Properties.Name).Count) -eq 17) 'opencode.json 17 blocos agent'
    $hasBM = ($null -ne ($j.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))
    Assert (-not $hasBM) 'agent.build sem model'
    $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
    Assert ($j.model -eq $models.planner) 'root model = planner'
    Assert ($j.agent.title.model -eq $models.planner) 'title.model = planner'
    Assert ($j.agent.coder.model -eq $models.cheap) 'coder.model = cheap'
    Assert ($j.agent.reviewer.model -eq $models.strong) 'reviewer.model = strong'
  }
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    Assert (Test-Path -LiteralPath (Join-Path $ocDir ('skills\' + $s + '\SKILL.md')) -PathType Leaf) ('skill ' + $s)
  }
  $plug = Join-Path $ocDir 'plugins\orchestration-enforcement.ts'
  Assert (Test-Path -LiteralPath $plug -PathType Leaf) 'plugin instalado'
  if (Test-Path -LiteralPath $plug -PathType Leaf) {
    Assert ([IO.File]::ReadAllText($plug, [Text.Encoding]::UTF8).Contains('orchestration-enforcement')) 'plugin contem marker'
  }
  $mf = Join-Path $TmpHome '.opencode-orchestration\manifest.json'
  Assert (Test-Path -LiteralPath $mf -PathType Leaf) 'manifest criado'
  if (Test-Path -LiteralPath $mf -PathType Leaf) {
    $m = ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    Assert ($m.package_version -eq '1.0.0-hardening') 'manifest package_version'
    Assert ($m.plugin_dependency -eq '@opencode-ai/plugin@1.18.31') 'manifest plugin_dependency'
    Assert (-not [string]::IsNullOrWhiteSpace($m.installed_at)) 'manifest installed_at'
    Assert ($m.target_home -eq $TmpHome) 'manifest target_home'
    Assert ((@($m.managed_files).Count) -gt 20) 'manifest managed_files>20'
    $raw = [IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)
    Assert (($raw -notmatch '(?i)secret') -and ($raw -notmatch 'sk-ant-') -and ($raw -notmatch '(?i)password')) 'manifest sem secrets'
  }
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
