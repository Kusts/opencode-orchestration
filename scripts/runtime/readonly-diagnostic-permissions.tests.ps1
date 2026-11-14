<#
.SYNOPSIS
    Read-only diagnostic permission contract for ten worker profiles.
.DESCRIPTION
    Static PS 5.1, ASCII-only suite using [OK]/[FAIL] and exit 0/1. Checks
    parsing, V1/V2 allow/deny parity, structure, grants, V1/V2 translation,
    agent-body constraints, and writer permission exceptions. Read-only;
    does not modify the repository.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AgentTranslator.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$profiles = @('reviewer','security-reviewer','architect','engineering-advisor','product-designer','requirements-analyst','skeptic','explorer','researcher','docs-manager')
$total = 0; $passed = 0
function Assert-Ok($ok, $label) {
  $script:total++
  if ($ok) { $script:passed++; Write-Host "[OK] $label" }
  else { Write-Host "[FAIL] $label" }
}
foreach ($name in $profiles) {
  $parsed = $null
  try { $parsed = Read-AgentFileCanonical -Path (Join-Path $repoRoot "source\agents\$name.md") } catch {}
  Assert-Ok ($null -ne $parsed) "$name parses"
  if ($null -eq $parsed) { continue }
  $c = $parsed.Canonical
  $commands = @('git diff --stat','git log --oneline -5','git show HEAD:file','git status --short','rg TODO src','grep -n x file','Select-String -Path x -Pattern y','Get-Content README.md','Get-ChildItem docs','Test-Path README.md','git config --get user.name')
  foreach ($cmd in $commands) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'allow') -and ([string]$b -ceq 'allow') -and ([string]$a -ceq [string]$b)) "$name allows $cmd V1/V2"
  }
  foreach ($cmd in @('Set-Content x.txt y','Out-File x.txt','git commit -m x','git push origin main','npm publish','rm -rf build','Remove-Item -Recurse -Force .','pwsh -NoProfile -Command "Get-ChildItem"','node script.js','npm test','curl -X POST https://x','git reset --hard','dropdb x')) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'deny') -and ([string]$b -ceq 'deny')) "$name denies $cmd"
  }
  $expectedEdit = 'deny'
  if ($name -ceq 'docs-manager') { $expectedEdit = 'allow' }
  Assert-Ok ($c.HasCatchAll -and $c.CatchAllEffect -ceq 'deny' -and $c.Edit -ceq $expectedEdit -and $c.TaskScalar -ceq 'deny') "$name structure"
  try { Assert-NoAmbiguousOverlap -ShellRules @($c.ShellRules) | Out-Null; Convert-CanonicalToV2Frontmatter -Canonical $c | Out-Null; Assert-Ok $true "$name V2 overlap/translation" } catch { Assert-Ok $false "$name V2 overlap/translation" }
  try {
    $v1 = Convert-CanonicalToV1Frontmatter -Canonical $c
    Assert-Ok ($v1.Text -match '(?m)^\s*["'']?\*\s*["'']?\s*:\s*deny\s*$') "$name V1 catch-all deny"
  } catch { Assert-Ok $false "$name V1 translation" }
  $body = Get-Content (Join-Path $repoRoot "source\agents\$name.md") -Raw
  Assert-Ok ($body -match '(?m)^## Shell \(leitura e diagn') "$name body title"
  Assert-Ok $body.Contains('em vez de contornar') "$name body bypass contract"
  Assert-Ok (-not $body.Contains('Set-Content')) "$name body excludes Set-Content"
}
$writers = @('coder','frontend-engineer','backend-engineer','database-engineer','ai-agent-engineer','automation-engineer','infra-engineer')
foreach ($name in $writers) {
  $c = (Read-AgentFileCanonical -Path (Join-Path $repoRoot "source\agents\$name.md")).Canonical
  foreach ($case in @(
    @{ Command='git rebase main'; Effect='allow' },
    @{ Command='git push origin main'; Effect='ask' },
    @{ Command='Format-Volume C: x'; Effect='deny' },
    @{ Command='diskpart'; Effect='deny' }
  )) {
    $v1 = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $case.Command
    $v2 = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $case.Command
    Assert-Ok ([string]$v1 -ceq $case.Effect) "$name V1 $($case.Command) $($case.Effect)"
    Assert-Ok ([string]$v2 -ceq $case.Effect) "$name V2 $($case.Command) $($case.Effect)"
  }
  Assert-Ok ($c.HasCatchAll -and $c.CatchAllEffect -ceq 'allow') "$name catch-all allow"
}
$doc = Get-Content (Join-Path $repoRoot 'docs\PERMISSIONS.md') -Raw
Assert-Ok ($doc.Contains('read-only') -and $doc.Contains('allowlist') -and $doc.Contains('subagent_depth')) 'permissions documentation'
$grants = Get-Content (Join-Path $repoRoot 'source\registry\execution-grants.json') -Raw | ConvertFrom-Json
foreach ($name in $profiles) { Assert-Ok (@($grants.role_baselines.$name) -contains 'shell.diagnostic') "$name diagnostic grant" }
Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }; exit 0
