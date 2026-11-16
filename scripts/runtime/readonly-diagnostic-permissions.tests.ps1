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
$taskFixture = @{
  Description='task-order'; Mode='subagent'; Model='model'
  BashKind='scalar'; BashScalar='deny'; TaskKind='map'
  TaskRules=@(@{Pattern='task *--write*';Effect='deny'},@{Pattern='task *';Effect='allow'})
  EditPresent=$false; Edit=''; HasHidden=$false; Hidden=$false; HasTemperature=$false
  ExtraPermissions=@(); OrchPresent=$false; BuildDelegable=$false; Lifecycle=''; Visibility=''
  Preferred=@(); Forbidden=@()
}
$allowDeny = @(@{ Pattern='git diff *'; Effect='allow' }, @{ Pattern='git diff *--output*'; Effect='deny' })
try {
  Assert-NoAmbiguousOverlap -ShellRules $allowDeny | Out-Null
  $fixture = @{ BashKind='map'; ShellRules=$allowDeny }
  $ordered = @(Get-OrderedV2ShellRules -Canonical $fixture)
  Assert-Ok (([string]$ordered[0].Effect -ceq 'allow') -and ([string]$ordered[1].Effect -ceq 'deny')) 'deny emitted after allow'
  Assert-Ok ((Get-V1RuleEffect -Rules $allowDeny -Command 'git diff --output=x') -ceq 'deny') 'V1 most-specific deny'
  $subsetRejected = -not (Test-GlobSubset -Subset 'git diff ' -Superset 'git diff *')
  $orderedTask = @(Get-OrderedV2TaskRules -Canonical $taskFixture)
  $renderedTask = Convert-CanonicalToV2Frontmatter -Canonical $taskFixture
  $allowPos = $renderedTask.Text.IndexOf('resource: "task *"')
  $denyPos = $renderedTask.Text.IndexOf('resource: "task *--write*"')
  $taskOrdered = ([string]$orderedTask[0].Effect -ceq 'allow') -and ([string]$orderedTask[1].Effect -ceq 'deny') -and ($allowPos -ge 0) -and ($denyPos -gt $allowPos)
  Assert-Ok ($subsetRejected -and $taskOrdered) 'subset length and task guard/emission ordering'
} catch { Assert-Ok $false 'allow broad + trailing deny subset accepted' }
try { Assert-NoAmbiguousOverlap -ShellRules @(@{Pattern='git status *';Effect='allow'},@{Pattern='git diff *--output*';Effect='deny'}) | Out-Null; Assert-Ok $true 'disjoint allow/deny accepted' } catch { Assert-Ok $false 'disjoint allow/deny accepted' }
try { Assert-NoAmbiguousOverlap -ShellRules @(@{Pattern='git diff *--output*';Effect='deny'},@{Pattern='git diff *';Effect='allow'}) | Out-Null; Assert-Ok $false 'deny before allow rejected' } catch { Assert-Ok $true 'deny before allow rejected' }
try { Assert-NoAmbiguousOverlap -ShellRules @(@{Pattern='git diff *';Effect='allow'},@{Pattern='git *--output*';Effect='deny'}) | Out-Null; Assert-Ok $false 'overlapping non-subset deny rejected' } catch { Assert-Ok $true 'overlapping non-subset deny rejected' }
try { Assert-NoAmbiguousOverlap -ShellRules @(@{Pattern='git diff *';Effect='allow'},@{Pattern='git diff *';Effect='ask'}) | Out-Null; Assert-Ok $false 'allow/ask rejected' } catch { Assert-Ok $true 'allow/ask rejected' }
foreach ($name in $profiles) {
  $parsed = $null
  try { $parsed = Read-AgentFileCanonical -Path (Join-Path $repoRoot "source\agents\$name.md") } catch {}
  $sourceText = Get-Content (Join-Path $repoRoot "source\agents\$name.md") -Raw
  $denySourceLines = @($sourceText -split '\r?\n' | Where-Object { $_ -match '^\s+"(git diff \*--output\*|git show \*--output\*|git log \*--output\*|rg \*--pre\*|rg \*--hostname-bin\*)": deny\s*$' })
  $sourceLines = @($sourceText -split '\r?\n')
  $taskLineIndex = -1
  for ($lineIndex = 0; $lineIndex -lt $sourceLines.Count; $lineIndex++) { if ($sourceLines[$lineIndex] -match '^\s+task:') { $taskLineIndex = $lineIndex; break } }
  $immediatelyBeforeTask = $false
  if ($taskLineIndex -ge 5) {
    $immediatelyBeforeTask = (@($sourceLines[($taskLineIndex-5)..($taskLineIndex-1)] | Where-Object { $_ -match '^\s+"(git diff \*--output\*|git show \*--output\*|git log \*--output\*|rg \*--pre\*|rg \*--hostname-bin\*)": deny\s*$' }).Count -eq 5)
  }
  Assert-Ok (($null -ne $parsed) -and ($denySourceLines.Count -eq 5) -and $immediatelyBeforeTask) "$name parses; source denies last before task"
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
  foreach ($cmd in @('git diff --output=x','git diff --output','git show --output=x','git log --output=x','rg --pre x','rg --hostname-bin x')) {
    $a = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok (([string]$a -ceq 'deny') -and ([string]$b -ceq 'deny')) "$name denies write/exec flag: $cmd"
  }
  foreach ($cmd in @('git diff --stat','git diff HEAD~1 -- path','git show --stat','rg -n')) {
    $b = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok ([string]$b -ceq 'allow') "$name permits routine read $cmd"
  }
  $expectedEdit = 'deny'
  if ($name -ceq 'docs-manager') { $expectedEdit = 'allow' }
  Assert-Ok ($c.HasCatchAll -and $c.CatchAllEffect -ceq 'deny' -and $c.Edit -ceq $expectedEdit -and $c.TaskScalar -ceq 'deny') "$name structure"
  try { $ordered = @(Get-OrderedV2ShellRules -Canonical $c); Assert-NoAmbiguousOverlap -ShellRules @($ordered | ForEach-Object { @{ Pattern=[string]$_.Resource; Effect=[string]$_.Effect } }) | Out-Null; Convert-CanonicalToV2Frontmatter -Canonical $c | Out-Null; Assert-Ok $true "$name V2 overlap/translation" } catch { Assert-Ok $false "$name V2 overlap/translation" }
  try {
    $v1 = Convert-CanonicalToV1Frontmatter -Canonical $c
    $v1Lines = @($v1.Text -split '\r?\n')
    $allowIndices = @(); $specificDenyIndices = @()
    for ($lineIndex = 0; $lineIndex -lt $v1Lines.Count; $lineIndex++) {
      if ($v1Lines[$lineIndex] -match '^\s+"[^"]+": (allow|ask)\s*$') { $allowIndices += $lineIndex }
      if ($v1Lines[$lineIndex] -match '^\s+"(git diff \*--output\*|git show \*--output\*|git log \*--output\*|rg \*--pre\*|rg \*--hostname-bin\*)": deny\s*$') { $specificDenyIndices += $lineIndex }
    }
    Assert-Ok (($v1.Text -match '(?m)^\s*["'']?\*\s*["'']?\s*:\s*deny\s*$') -and ($specificDenyIndices.Count -eq 5) -and (($specificDenyIndices | Measure-Object -Minimum).Minimum -gt ($allowIndices | Measure-Object -Maximum).Maximum)) "$name V1 catch-all and specific denies follow allows"
  } catch { Assert-Ok $false "$name V1 translation" }
  $body = Get-Content (Join-Path $repoRoot "source\agents\$name.md") -Raw
  Assert-Ok ($body -match '(?m)^## Shell \(leitura e diagn') "$name body title"
  Assert-Ok $body.Contains('em vez de contornar') "$name body bypass contract"
  Assert-Ok ($body.Contains('Não encadeie comandos') -and -not $body.Contains('Get-Content')) "$name body composition and no shell read list"
}
$untouchedProfiles = @('ai-agent-engineer','automation-engineer','backend-engineer','coder','database-engineer','debugger','frontend-engineer','infra-engineer','tester')
$requiredFlagRules = @('git diff *--output*','git show *--output*','git log *--output*','rg *--pre*','rg *--hostname-bin*')
foreach ($name in $untouchedProfiles) {
  $c = (Read-AgentFileCanonical -Path (Join-Path $repoRoot "source\agents\$name.md")).Canonical
  $patterns = @($c.ShellRules | ForEach-Object { [string]$_.Pattern })
  Assert-Ok (@($requiredFlagRules | Where-Object { $patterns -contains $_ }).Count -eq 0) "$name unchanged flag rules absent"
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
