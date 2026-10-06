<#!
.SYNOPSIS
    Contrato Phase 2A do coder: subconjunto seguro de hardening (Format-Volume/diskpart deny).
.DESCRIPTION
    Suite estatica (PS 5.1 compativel, 'ok - ...' / 'NOT OK - ...', exit 0/1).
    Prova: (A) DENY novo: Format-Volume* e diskpart* negados em V1 e V2 com
    paridade; (B) REGRESSAO: rm -rf continua ask, git push continua ask (nao
    deny), git status nao negado (allow via catch-all); (C) ESTRUTURA: guard
    Assert-NoAmbiguousOverlap passa e emissao V2 traduz sem erro.
    Somente leitura; nao altera source/templates/registry/flags.

    HOLD honesto (decisao arquitetural do Planner, nao assert que falha):
    pares amplo-x-estreito com efeito distinto sao PROIBIDOS pelo guard
    ambiguous-permission-overlap e NAO foram aplicados nesta fatia:
      - "git push --force*" deny sob "git push *" ask (testemunha comum);
      - "docker system prune*" deny sob "docker system*" ask (testemunha comum).
    Qualquer tentativa desses pares quebra o build (fail closed) — por isso
    esta suite NAO os exige; documenta-se aqui o HOLD para a proxima fatia
    decidir (renomear padrao amplo, estreitar efeito, ou aceitar ask).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\runtime\lib\AgentTranslator.ps1')

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$coderPath = Join-Path $RepoRoot 'source\agents\coder.md'

$script:pass = 0
$script:fail = 0
function Assert($Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass += 1; Write-Host ('ok - ' + $Name) }
  else {
    $script:fail += 1
    $line = ('NOT OK - ' + $Name)
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + ' -- ' + $Detail }
    Write-Host $line
  }
}

$parsed = $null
$parseErr = ''
try { $parsed = Read-AgentFileCanonical -Path $coderPath }
catch { $parseErr = $_.Exception.Message }
Assert (($null -ne $parsed) -and ([string]$parsed.Canonical.Id -ceq 'coder')) 'parse coder.md' $parseErr
if ($null -eq $parsed) { Write-Host ('PASS: ' + $script:pass + ' / FAIL: ' + $script:fail); exit 1 }
$c = $parsed.Canonical

function Get-E1($cmd) {
  return (Get-V1RuleEffect -Rules @($c.ShellRules) -HasCatchAll ([bool]$c.HasCatchAll) -CatchAllEffect ([string]$c.CatchAllEffect) -Command $cmd)
}
function Get-E2($cmd) {
  $rules = @(Get-OrderedV2ShellRules -Canonical $c)
  return (Get-V2RuleEffect -V2Rules $rules -Action 'shell' -Command $cmd)
}
function Assert-Effect([string]$Expect, [string]$Cmd, [string]$Label) {
  $e1 = Get-E1 $Cmd
  $e2 = Get-E2 $Cmd
  Assert ([string]$e1 -ceq $Expect) ($Label + ' [V1]') ('cmd=' + $Cmd + ' eff=' + $e1)
  Assert ([string]$e2 -ceq $Expect) ($Label + ' [V2]') ('cmd=' + $Cmd + ' eff=' + $e2)
  Assert ([string]$e1 -ceq [string]$e2) ($Label + ' [paridade V1=V2]') ('v1=' + $e1 + ' v2=' + $e2)
}

# ---- (A) DENY novo: Format-Volume / diskpart ---------------------------------
Assert-Effect 'deny' 'Format-Volume -DriveLetter C' 'A: Format-Volume negado'
Assert-Effect 'deny' 'format-volume C:' 'A: format-volume (case-insensitive) negado'
Assert-Effect 'deny' 'diskpart' 'A: diskpart negado'
Assert-Effect 'deny' 'diskpart /s script.txt' 'A: diskpart com args negado'

# ---- (B) REGRESSAO: contratos preexistentes preservados ----------------------
Assert-Effect 'ask' 'rm -rf build' 'B: rm -rf continua ask'
Assert-Effect 'ask' 'git push origin main' 'B: git push continua ask (nao deny)'
Assert-Effect 'ask' 'git push --tags' 'B: git push com flags continua ask (nao deny)'
Assert-Effect 'allow' 'git status' 'B: git status nao negado (allow via catch-all)'

# ---- (C) ESTRUTURA: guard + emissao V2 ---------------------------------------
$guardOk = $true
$guardErr = ''
try { Assert-NoAmbiguousOverlap -ShellRules @($c.ShellRules) | Out-Null }
catch { $guardOk = $false; $guardErr = $_.Exception.Message }
Assert $guardOk 'C: guard Assert-NoAmbiguousOverlap passa' $guardErr

$v2Ok = $true
$v2Err = ''
try { Convert-CanonicalToV2Frontmatter -Canonical $c | Out-Null }
catch { $v2Ok = $false; $v2Err = $_.Exception.Message }
Assert $v2Ok 'C: emissao V2 do coder traduz sem erro' $v2Err

Write-Host ('PASS: ' + $script:pass + ' / FAIL: ' + $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
