# planner-model.tests.ps1 — build uses per-agent Planner model; global root/title stay Luna.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-plan-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  New-Item -ItemType Directory -Path (Join-Path $TmpHome '.config\opencode\node_modules\@opencode-ai\plugin') -Force | Out-Null
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome -Runtime V1 2>&1
  Assert ($LASTEXITCODE -eq 0) 'fresh exit 0'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $jsonPath = Join-Path $ocDir 'opencode.json'
  $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
  $j = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ([string]$j.agent.build.model -eq $models.planner) 'build.model = Planner model no output'
  Assert ($j.model -eq 'openai/gpt-6-luna') 'root model permanece Luna literal'
  Assert ($j.agent.title.model -eq 'openai/gpt-6-luna') 'title.model permanece Luna literal'
  $j.agent.build.model = 'legacy/model'
  [IO.File]::WriteAllText($jsonPath, ((($j | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome -Runtime V1 2>&1
  Assert ($LASTEXITCODE -eq 0) 're-run exit 0'
  $j2 = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ([string]$j2.agent.build.model -eq $models.planner) 'build.model pre-existente restaurado para Planner model'
  Assert ($j2.model -eq 'openai/gpt-6-luna') 'root model ainda = Luna literal'
  Assert ($j2.agent.title.model -eq 'openai/gpt-6-luna') 'title.model ainda = Luna literal'
  Assert ($j2.agent.build.mode -eq 'primary') 'build.mode preservado/atualizado'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
