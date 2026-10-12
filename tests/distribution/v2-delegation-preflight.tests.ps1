<#!
.SYNOPSIS
    Regressao P0 do fix V2-native-subagent-delegation: exemplo valido de
    preflight no AGENTS.md + cobertura total dos allows do build no template.
.DESCRIPTION
    Cobre: (a) AGENTS.md traz exemplo com -Objective (chamada sem params
    falha exit 2); (b) agents{} do template V2 cobre os 19 recursos do allow
    do build (21 blocos: build+title+19 workers); (c) preflight sem params
    sai exit 2. Estilo das suites distribution: 'ok - ...' / 'NOT OK - ...',
    exit 0/1. Somente leitura (mais um spawn do proprio preflight para (c),
    sem escrita); PS 5.1 compativel, ASCII-only.
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
$agentsPath = Join-Path $RepoRoot 'AGENTS.md'
$tmplPath = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'
$preflight = Join-Path $RepoRoot 'scripts\v3\orchestration-preflight.ps1'

Assert (Test-Path -LiteralPath $agentsPath -PathType Leaf) 'AGENTS.md existe'
Assert (Test-Path -LiteralPath $tmplPath -PathType Leaf) 'template opencode.v2.json.tmpl existe'
Assert (Test-Path -LiteralPath $preflight -PathType Leaf) 'scripts/v3/orchestration-preflight.ps1 existe'

# (a) exemplo valido com -Objective + nota de exit 2 + alternativa -TaskFile
try {
  $md = [IO.File]::ReadAllText($agentsPath, [Text.Encoding]::UTF8)
  Assert ($md -match 'orchestration-preflight\.ps1 -Objective') 'AGENTS.md: exemplo com -Objective' ''
  Assert ($md -match 'exit 2') 'AGENTS.md: nota de falha exit 2 sem params' ''
  Assert ($md -match '-TaskFile') 'AGENTS.md: alternativa -TaskFile citada' ''
} catch {
  Assert $false 'AGENTS.md legivel' $_.Exception.Message
}

# (b) agents{} cobre todos os 19 recursos do allow do build
$tmpl = $null
try {
  $raw = [IO.File]::ReadAllText($tmplPath, [Text.Encoding]::UTF8)
  $resolved = $raw.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $tmpl = $resolved | ConvertFrom-Json
  Assert ($null -ne $tmpl) 'template V2 parseia como JSON (tokens resolvidos)'
} catch {
  Assert $false 'template V2 parseia como JSON (tokens resolvidos)' $_.Exception.Message
}
if ($null -ne $tmpl) {
  $blocks = @()
  try { $blocks = @($tmpl.agents.PSObject.Properties | ForEach-Object { $_.Name }) } catch { $blocks = @() }
  Assert ($blocks.Count -eq 21) 'template V2 tem 21 blocos agents' ('obtido: ' + $blocks.Count)
  $allows = @()
  try {
    $allows = @($tmpl.agents.build.permissions | Where-Object { $_.effect -ceq 'allow' } | ForEach-Object { [string]$_.resource })
  } catch { $allows = @() }
  Assert ($allows.Count -eq 19) 'allowlist do build tem 19 allows' ('obtido: ' + $allows.Count)
  $missing = @($allows | Where-Object { $blocks -notcontains $_ })
  Assert ($missing.Count -eq 0) 'todo allow do build tem bloco agents.*' ('sem bloco: ' + ($missing -join ','))
  foreach ($p in @('requirements-analyst', 'engineering-advisor', 'product-designer', 'skeptic')) {
    $node = $null
    try { $node = $tmpl.agents.$p } catch { $node = $null }
    $okNode = ($null -ne $node) -and ([string]$node.mode -ceq 'subagent') -and ([string]$node.model -ceq 'x/cheap')
    Assert $okNode ('planning com bloco cheap: ' + $p)
  }
}

# (c) preflight sem params sai exit 2
try {
  $engineExe = Join-Path $PSHOME 'powershell.exe'
  if ($PSVersionTable.PSEdition -eq 'Core') { $engineExe = Join-Path $PSHOME 'pwsh' }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  & $engineExe -NoProfile -NonInteractive -File $preflight 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  Assert ($code -eq 2) 'preflight sem params sai exit 2' ('exit=' + [string]$code)
} catch {
  try { $ErrorActionPreference = $prevEap } catch { }
  Assert $false 'preflight sem params executou' $_.Exception.Message
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
