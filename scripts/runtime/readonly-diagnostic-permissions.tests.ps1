<#
.SYNOPSIS
    Shell-livre e limites de edit/task dos perfis de leitura e docs-manager.
.DESCRIPTION
    Suite estática PS 5.1: confere shell único "*": allow em dez perfis,
    ausência de regras shell específicas, paridade V1/V2 e limites de papel.
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
  $path = Join-Path $repoRoot "source\agents\$name.md"
  $parsed = $null
  try { $parsed = Read-AgentFileCanonical -Path $path } catch {}
  Assert-Ok ($null -ne $parsed) "$name parses"
  if ($null -eq $parsed) { continue }
  $c = $parsed.Canonical
  $expectedEdit = if ($name -eq 'docs-manager') { 'allow' } else { 'deny' }
  Assert-Ok ($c.EditPresent -and $c.Edit -ceq $expectedEdit) "$name edit=$expectedEdit"
  Assert-Ok ($c.TaskKind -ceq 'scalar' -and $c.TaskScalar -ceq 'deny') "$name task deny"
  Assert-Ok ($c.BashKind -ceq 'map' -and $c.ShellRules.Count -eq 1 -and
    $c.ShellRules[0].Pattern -ceq '*' -and $c.ShellRules[0].Effect -ceq 'allow') "$name only bash * allow"

  foreach ($cmd in @('git status','npm test','Set-Content x y','git push','rm -rf build','sudo rm -rf build','kubectl apply -f x','wrangler deploy')) {
    $v1 = Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd
    $v2 = Get-V2RuleEffect -V2Rules @(Get-OrderedV2ShellRules -Canonical $c) -Action shell -Command $cmd
    Assert-Ok ([string]$v1 -ceq 'allow' -and [string]$v2 -ceq 'allow') "$name shell allows $cmd in V1/V2"
  }

  try {
    Convert-CanonicalToV2Frontmatter -Canonical $c | Out-Null
    $v1 = Convert-CanonicalToV1Frontmatter -Canonical $c
    Convert-AgentFrontmatterYamlToCanonical -FrontmatterText $v1.Text -SourceName $name | Out-Null
    Assert-Ok $true "$name V1/V2 translation"
  } catch { Assert-Ok $false "$name V1/V2 translation" }

}

$doc = Get-Content (Join-Path $repoRoot 'docs\PERMISSIONS.md') -Raw
Assert-Ok ($doc.Contains('shell irrestrito') -and $doc.Contains('edit: deny') -and
  $doc.Contains('task: deny') -and $doc.Contains('subagent: * deny') -and
  $doc.Contains('externas')) 'permission docs state current shell and retained boundaries'

$grants = Get-Content (Join-Path $repoRoot 'source\registry\execution-grants.json') -Raw | ConvertFrom-Json
foreach ($name in $profiles) {
  $g = @($grants.role_baselines.$name)
  Assert-Ok ($g -contains 'shell.diagnostic') "$name diagnostic grant retained"
  foreach ($forbidden in @('git.push','git.commit','secrets.read','destructive.fs')) {
    Assert-Ok ($g -notcontains $forbidden) "$name excludes $forbidden grant"
  }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }; exit 0
