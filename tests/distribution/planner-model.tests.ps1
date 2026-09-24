# planner-model.tests.ps1 — build sem model; root = planner; legado removido.
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
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  Assert ($LASTEXITCODE -eq 0) 'fresh exit 0'
  $ocDir = Join-Path $TmpHome '.config\opencode'
  $jsonPath = Join-Path $ocDir 'opencode.json'
  $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
  $j = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (($null -eq ($j.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) 'build sem model no output'
  Assert ($j.model -eq $models.planner) 'root model = planner'
  Assert ($j.agent.title.model -eq $models.planner) 'title.model = planner'
  $j.agent.build | Add-Member -NotePropertyName 'model' -NotePropertyValue 'legacy/model' -Force
  [IO.File]::WriteAllText($jsonPath, ((($j | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  Assert ($LASTEXITCODE -eq 0) 're-run exit 0'
  $j2 = ([IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (($null -eq ($j2.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) 'build.model pre-existente removido'
  Assert ($j2.model -eq $models.planner) 'root model ainda = planner'
  Assert ($j2.agent.build.mode -eq 'primary') 'build.mode preservado/atualizado'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
