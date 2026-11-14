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
  if ($name -ceq 'researcher') {
    $extras = @($c.ExtraPermissions)
    $extraNames = @($extras | ForEach-Object { [string]$_.Name } | Sort-Object)
    $extraEffects = @{}
    foreach ($extra in $extras) { $extraEffects[[string]$extra.Name] = [string]$extra.Effect }
    Assert-Ok (($extras.Count -eq 2) -and (($extraNames -join ',') -ceq 'webfetch,websearch') -and
      ($extraEffects.webfetch -ceq 'allow') -and ($extraEffects.websearch -ceq 'allow')) 'researcher has exactly webfetch/websearch allow extras'
    $bashText = @($c.ShellRules | ForEach-Object { [string]$_.Pattern }) -join "`n"
    Assert-Ok ($bashText -notmatch '(?i)webfetch|websearch') 'researcher bash excludes webfetch/websearch'
  }
  $commands = @('git diff','git diff --stat','git log --oneline -5','git show HEAD:file','git status --short','git blame file','rg TODO src','grep -n x file','Select-String pattern file','git config --get user.name','node --version','npm ls','bun --version','opencode --version','opencode debug agents')
  foreach ($cmd in $commands) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'allow') -and ([string]$b -ceq 'allow') -and ([string]$a -ceq [string]$b)) "$name allows $cmd V1/V2"
  }
  foreach ($cmd in @('Set-Content x y','git grep -O pwsh x','git cat-file --textconv HEAD:f','Get-Content a > b','git difftool','opencode debug config','pwsh -NoProfile -Command x','npm test','git commit -m x','git push')) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'deny') -and ([string]$b -ceq 'deny')) "$name denies $cmd"
  }
  foreach ($cmd in @('git diff --output=x','rg --pre pwsh x')) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'allow') -and ([string]$b -ceq 'allow')) "$name known-residual: flag escrita/execucao nao contida pelo glob (prompt-enforced): $cmd"
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
  Assert-Ok ($body.Contains('Não encadeie comandos') -and -not $body.Contains('Get-Content')) "$name body composition and no shell read list"
}
$writers = @('coder','frontend-engineer','backend-engineer','database-engineer','ai-agent-engineer','automation-engineer','infra-engineer')
foreach ($name in $writers) {
  $c = (Read-AgentFileCanonical -Path (Join-Path $repoRoot "source\agents\$name.md")).Canonical
  foreach ($case in @(
    @{ Command='git rebase main'; Effect='allow' },
    @{ Command='git push'; Effect='ask' },
    @{ Command='git push origin main'; Effect='ask' },
    @{ Command='Format-Volume C: x'; Effect='deny' },
    @{ Command='diskpart'; Effect='deny' },
    @{ Command='git reset --hard HEAD'; Effect='deny' },
    @{ Command='git clean -fdx'; Effect='deny' },
    @{ Command='kubectl apply -f x'; Effect='ask' },
    @{ Command='wrangler deploy'; Effect='ask' },
    @{ Command='gh auth login'; Effect='ask' },
    @{ Command='npm publish'; Effect='ask' },
    @{ Command='curl -X POST https://x'; Effect='ask' },
    @{ Command='dropdb x'; Effect='deny' },
    @{ Command='Remove-Item -Recurse .'; Effect='ask' }
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
foreach ($name in $profiles) { $g=@($grants.role_baselines.$name); Assert-Ok ($g -contains 'shell.diagnostic') "$name diagnostic grant"; foreach($forbidden in @('git.push','git.commit','secrets.read','destructive.fs')) { Assert-Ok ($g -notcontains $forbidden) "$name excludes $forbidden grant" } }
Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }; exit 0
