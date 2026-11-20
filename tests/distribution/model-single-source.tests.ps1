# model-single-source.tests.ps1 — P1-03 / issue #287
# Fonte unica dos modelos: policy canonica + override explicito do operador.
# Fixture temporaria (copia do repo sem .git/models.jsonc); NENHUM arquivo real
# do checkout e alterado. Exercita install + Router + Planner derivados da
# policy e o caso de override explicito preservado.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
function Write-JsonNoBom([string]$Path, $Value) {
  $json = ($Value | ConvertTo-Json -Depth 40)
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}
function Read-Json([string]$Path) {
  return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
function New-RepoCopy([string]$Root, [string]$Dest) {
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null
  foreach ($item in @('install.ps1', 'source', 'scripts', 'templates', 'skills-core', 'plugins')) {
    Copy-Item -LiteralPath (Join-Path $Root $item) -Destination (Join-Path $Dest $item) -Recurse -Force
  }
  # models.jsonc propositalmente NAO copiado: ausencia deve ser valida.
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-single-source-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
$savedEnv = @{}
foreach ($n in @('MODEL_FREE', 'MODEL_CHEAP', 'MODEL_STRONG', 'MODEL_FRONTIER')) {
  $savedEnv[$n] = [string](Get-Item ('env:' + $n) -ErrorAction SilentlyContinue).Value
  Set-Item ('env:' + $n) -Value '' -ErrorAction SilentlyContinue
}
try {
  # --------------------------------------------------------------------------
  # Caso 1: alterar os 4 primarios T1-T4 na policy; aplicar uma vez; verificar
  # Router, Planner e configuracao gerada refletem os novos valores.
  # --------------------------------------------------------------------------
  $repoA = Join-Path $Tmp 'repo-policy'
  New-RepoCopy $RepoRoot $repoA
  $polPathA = Join-Path $repoA 'source\registry\model-routing-policy.json'
  $policyA = Read-Json $polPathA
  $policyA.tiers.T1.primary = 'mimo'
  $policyA.tiers.T2.primary = 'deepseek_go'
  $policyA.tiers.T3.primary = 'claude_sonnet'
  $policyA.tiers.T4.primary = 'claude_opus'
  Write-JsonNoBom $polPathA $policyA

  $expA = @{
    T1 = [string]$policyA.models.mimo.model_id
    T2 = [string]$policyA.models.deepseek_go.model_id
    T3 = [string]$policyA.models.claude_sonnet.model_id
    T4 = [string]$policyA.models.claude_opus.model_id
  }
  Assert (-not (Test-Path -LiteralPath (Join-Path $repoA 'models.jsonc') -PathType Leaf)) 'case1: fixture sem models.jsonc (ausencia permitida)'

  $homeA = Join-Path $Tmp 'home-policy'
  $outA = & (Join-Path $repoA 'install.ps1') -RepoRoot $repoA -TargetHome $homeA -Runtime V2 2>&1 | Out-String
  $codeA = $LASTEXITCODE
  Assert ($codeA -eq 0) ('case1: install sem models.jsonc exit 0 (obtido ' + $codeA + ')')
  if ($codeA -ne 0) { Write-Host $outA }

  $cfgPathA = Join-Path $homeA '.config\opencode\opencode.json'
  if (Test-Path -LiteralPath $cfgPathA -PathType Leaf) {
    $cfgA = Read-Json $cfgPathA
    Assert ([string]$cfgA.model -ceq $expA.T1) 'case1: model global = novo primario T1'
    Assert ([string]$cfgA.agents.build.model -ceq $expA.T1) 'case1: agents.build.model = novo primario T1 (Planner)'
    Assert ([string]$cfgA.agents.explorer.model -ceq $expA.T1) 'case1: pool T1 = novo primario T1'
    Assert ([string]$cfgA.agents.title.model -ceq $expA.T2) 'case1: title segue o pool T2 derivado'
    Assert ([string]$cfgA.agents.coder.model -ceq $expA.T2) 'case1: pool T2 = novo primario T2'
    Assert ([string]$cfgA.agents.reviewer.model -ceq $expA.T3) 'case1: pool T3 = novo primario T3'
  }
  else { Assert $false 'case1: opencode.json gerado' }

  # Router + Planner devem derivar da MESMA policy (um unico arquivo editado).
  . (Join-Path $repoA 'scripts\v3\lib\OrchestrationModelRouter.ps1')
  $catA = Get-OrchestrationUserConfigCatalog -PolicyPath $polPathA -IgnoreUserConfig $true
  Assert ([string]$catA['T1'].CatalogModel -ceq $expA.T1) 'case1: Router T1 = novo primario'
  Assert ([string]$catA['T2'].CatalogModel -ceq $expA.T2) 'case1: Router T2 = novo primario'
  Assert ([string]$catA['T3'].CatalogModel -ceq $expA.T3) 'case1: Router T3 = novo primario'
  Assert ([string]$catA['T4'].CatalogModel -ceq $expA.T4) 'case1: Router T4 = novo primario'
  $selA = Resolve-OrchestrationModelSelection -AgentName 'build' -PolicyPath $polPathA -IgnoreUserConfig $true -NativeModelOverrideProven $true
  Assert ([string]$selA.selected_model_id -ceq $expA.T1) 'case1: Planner = novo primario T1 (sem planner.model_id duplicado)'
  $polCheckA = Get-OrchestrationModelRoutingPolicy -PolicyPath $polPathA
  $plannerNodeA = $polCheckA.Policy.planner
  Assert ($null -eq $plannerNodeA.PSObject.Properties['model_id'] -and $null -eq $plannerNodeA.PSObject.Properties['primary'] -and $null -eq $plannerNodeA.PSObject.Properties['provider']) 'case1: policy sem identidade duplicada do Planner'

  # --------------------------------------------------------------------------
  # Caso 2: override explicito do operador e respeitado (install + Router) e
  # nao e sobrescrito pelos defaults da policy.
  # --------------------------------------------------------------------------
  $repoB = Join-Path $Tmp 'repo-override'
  New-RepoCopy $RepoRoot $repoB
  $overridePath = Join-Path $repoB 'models.jsonc'
  $override = [ordered]@{
    planner  = 'openai/gpt-6-luna'
    cheap    = 'opencode-go/muse-spark-1.3-contributor'
    strong   = 'openai/gpt-6.1-sol'
    free     = 'opencode/mimo-v2.6-flash-free'
    frontier = 'openai/gpt-6-astra'
  }
  Write-JsonNoBom $overridePath $override

  $homeB = Join-Path $Tmp 'home-override'
  $outB = & (Join-Path $repoB 'install.ps1') -RepoRoot $repoB -TargetHome $homeB -Runtime V2 2>&1 | Out-String
  $codeB = $LASTEXITCODE
  Assert ($codeB -eq 0) ('case2: install com override exit 0 (obtido ' + $codeB + ')')
  if ($codeB -ne 0) { Write-Host $outB }

  $cfgPathB = Join-Path $homeB '.config\opencode\opencode.json'
  if (Test-Path -LiteralPath $cfgPathB -PathType Leaf) {
    $cfgB = Read-Json $cfgPathB
    Assert ([string]$cfgB.model -ceq $override.free) 'case2: model global respeita override free'
    Assert ([string]$cfgB.agents.build.model -ceq $override.planner) 'case2: Planner respeita override planner'
    Assert ([string]$cfgB.agents.title.model -ceq $override.cheap) 'case2: title respeita override cheap'
    Assert ([string]$cfgB.agents.coder.model -ceq $override.cheap) 'case2: pool T2 respeita override cheap'
    Assert ([string]$cfgB.agents.reviewer.model -ceq $override.strong) 'case2: pool T3 respeita override strong'
  }
  else { Assert $false 'case2: opencode.json gerado' }

  # O arquivo de override NAO pode ser alterado pelo instalador.
  $afterB = Read-Json $overridePath
  Assert ([string]$afterB.planner -ceq $override.planner -and [string]$afterB.free -ceq $override.free -and [string]$afterB.frontier -ceq $override.frontier) 'case2: models.jsonc de override preservado (nao sobrescrito)'

  $catB = Get-OrchestrationUserConfigCatalog -PolicyPath (Join-Path $repoB 'source\registry\model-routing-policy.json') -ConfigPath $overridePath
  Assert ([string]$catB['T1'].CatalogModel -ceq $override.free) 'case2: Router T1 respeita override'
  Assert ([string]$catB['T2'].CatalogModel -ceq $override.cheap) 'case2: Router T2 respeita override'
  Assert ([string]$catB['T3'].CatalogModel -ceq $override.strong) 'case2: Router T3 respeita override'
  Assert ([string]$catB['T4'].CatalogModel -ceq $override.frontier) 'case2: Router T4 respeita override'
}
finally {
  foreach ($n in $savedEnv.Keys) { Set-Item ('env:' + $n) -Value ([string]$savedEnv[$n]) -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 }
exit 0
