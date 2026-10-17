# session-real-lane-post17gate.tests.ps1 -- F1 (isolamento pos-16/17).
# Testes offline do predicado Test-LaneNeedsPost17Gate em
# scripts/ci/session-real-lane-v2.ps1: puro (sem spawn/rede/estado),
# exercitado em memoria com doubles; resto asserts estaticos.
# Sem Pester. Sem servico/modelo. PS 5.1 e PS7 compativel. ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
try {
    Assert-That (Test-Path -LiteralPath $script:LanePath -PathType Leaf) 'lane file exists' $script:LanePath
    $text = ''
    try { $text = [IO.File]::ReadAllText($script:LanePath) } catch { $text = '' }
    Assert-That (-not [string]::IsNullOrEmpty($text)) 'lane text readable' 'empty'
    $tokens = $null
    $parseErrors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors) } catch { $ast = $null }
    Assert-That (($null -ne $ast) -and ($null -ne $parseErrors) -and (@($parseErrors).Count -eq 0)) 'lane parses without syntax errors' ('errors=' + @($parseErrors).Count)
    $funcs = @{}
    try {
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($f in @($found)) { $funcs[[string]$f.Name] = [string]$f.Extent.Text }
    } catch { }
    Assert-That ($funcs.ContainsKey('Test-LaneNeedsPost17Gate')) 'helper Test-LaneNeedsPost17Gate exists' 'ausente na lane'
    if ($funcs.ContainsKey('Test-LaneNeedsPost17Gate')) {
        Invoke-Expression $funcs['Test-LaneNeedsPost17Gate']
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('16'))) 'filtro so-16 pula gate pos-16/17' 'gate executaria'
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('17'))) 'filtro so-17 pula gate pos-16/17' 'gate executaria'
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('16', '17'))) 'filtro 16+17 pula gate pos-16/17' 'gate executaria'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @())) 'filtro vazio executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('18'))) 'filtro so-18 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('21'))) 'filtro so-21 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('19'))) 'filtro so-19 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('20'))) 'filtro so-20 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('22'))) 'filtro so-22 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('16', '21'))) 'filtro 16+21 executa gate pos-16/17' 'gate pulado'
    }
    Assert-That ($text.Contains('if (Test-LaneNeedsPost17Gate -Filter $ScenarioFilter)')) 'gate pos-16/17 gated no predicado' 'wrap ausente'
    Assert-That ($text.Contains("Fail-Lane 'servico indisponivel apos cenarios 16/17; lane abortada.'")) 'falha do gate pos-16/17 preservada (dentro do if)' 'mensagem ausente'
    $noPre19 = $true
    try { $noPre19 = (-not $text.Contains('function Test-LaneNeedsPre19Gate')) } catch { $noPre19 = $false }
    Assert-That ($noPre19) 'sem predicado alheio Pre19Gate (fora do escopo)' 'acoplamento indevido'
} catch {
    Write-Host ("[FAIL] harness -- " + $_.Exception.Message)
}
Write-Host ("[post17gate-tests] " + $script:passed + "/" + $script:total + " PASS")
if ($script:passed -ne $script:total) { exit 1 }
