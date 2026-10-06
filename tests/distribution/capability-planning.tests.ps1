<#!
.SYNOPSIS
    Suite do contrato planning + discovery V2 (Fase 2A fatia 1): 17 + 19 + 19.
.DESCRIPTION
    Restaura em arquivo proprio os asserts de planning descritos em
    docs/capability-planning-v2.md (contrato canonico: 17 blocos no template
    V2, 19 .md em source/agents, 19 allows na allowlist do build, com os 4
    papeis de planning file-based + allowlisted e sem bloco JSON).
    Estilo das suites distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
    Somente leitura; nao altera templates/agents/registry/flags; PS 5.1 compativel.
    Nome propositalmente distinto de capability-registry-v2.tests.ps1 (fatia 2).
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else {
    $script:fail += 1
    $line = ("NOT OK - " + $Name)
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + " -- " + $Detail }
    Write-Host $line
  }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$agentsDir = Join-Path $RepoRoot 'source\agents'
$tmplPath = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'

Assert (Test-Path -LiteralPath $agentsDir -PathType Container) 'dir source/agents existe'
Assert (Test-Path -LiteralPath $tmplPath -PathType Leaf) 'template opencode.v2.json.tmpl existe'

$mdNames = @()
try {
  $mdNames = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File | ForEach-Object { $_.BaseName })
} catch {
  $mdNames = @()
}
Assert ($mdNames.Count -eq 19) 'source/agents tem 19 .md' ('obtido: ' + $mdNames.Count)

$tmpl = $null
try {
  $raw = [IO.File]::ReadAllText($tmplPath, [Text.Encoding]::UTF8)
  $resolved = $raw.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $tmpl = $resolved | ConvertFrom-Json
  Assert ($null -ne $tmpl) 'template V2 parseia como JSON (tokens resolvidos)'
} catch {
  Assert $false 'template V2 parseia como JSON (tokens resolvidos)' $_.Exception.Message
}

$planning = @('requirements-analyst', 'engineering-advisor', 'product-designer', 'skeptic')

if ($null -ne $tmpl) {
  $blocks = @()
  try { $blocks = @($tmpl.agents.PSObject.Properties | ForEach-Object { $_.Name }) } catch { $blocks = @() }
  Assert ($blocks.Count -eq 17) 'template V2 tem 17 blocos agents' ('obtido: ' + $blocks.Count)

  $allows = @()
  try {
    $allows = @($tmpl.agents.build.permissions | Where-Object { $_.effect -ceq 'allow' } | ForEach-Object { [string]$_.resource })
  } catch { $allows = @() }
  Assert ($allows.Count -eq 19) 'allowlist do build tem 19 allows' ('obtido: ' + $allows.Count)

  foreach ($p in $planning) {
    Assert ($allows -contains $p) ('allowlist inclui planning: ' + $p)
  }

  $mdOk = @($planning | Where-Object { $mdNames -contains $_ })
  Assert ($mdOk.Count -eq 4) '4 planning tem .md em source/agents' ('obtidos: ' + ($mdOk -join ','))
  $noBlock = @($planning | Where-Object { $blocks -notcontains $_ })
  Assert ($noBlock.Count -eq 4) '4 planning sem bloco agents.* no template V2 (file-based)' ('com bloco: ' + ((@($planning | Where-Object { $blocks -contains $_ }) -join ',')))
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
