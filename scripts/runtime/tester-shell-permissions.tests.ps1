<#!
.SYNOPSIS
    Contrato de autoridade do Tester: shell irrestrito, mantendo edit/task deny.
.DESCRIPTION
    Suite estatica (PS 5.1, ASCII puro, [OK]/[FAIL] + exit 0/1), descoberta
    automatica pelo run-v3-tests (scripts/runtime/*.tests.ps1). Prova:
    (A) ALLOW: ferramentas de teste diretas (npm/pnpm/yarn/bun/pytest/go/cargo/
        dotnet/ruff/mypy), leitura Git, gateways de validacao do repo via
        -File, powershell/pwsh -Command, pipes/utilitarios de apresentacao —
        na semantica V1 (most-specific-wins) e V2 (last-match-wins);
    (B) SHELL LIVRE: comandos comuns, destrutivos, de elevacao e deploy
        resultam em allow; nenhum deny/ask especifico;
    (C) ESTRUTURA: catch-all "*" presente com efeito allow; edit deny; task
        deny scalar; somente uma regra bash; guard de overlap V2
        passa; emissao V2 traduz sem erro;
    (E) COMPATIBILIDADE: paridade V1<->V2 para todas as amostras; roundtrip V1
        do frontmatter do tester preserva as regras;
    (F) COMPORTAMENTO: corpo do tester.md preserva o mandato de validar sem
        editar a aplicacao e sem criar subagentes.
    Nao modifica o repo (children apenas leem).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AgentTranslator.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testerPath = Join-Path $repoRoot 'source\agents\tester.md'

$script:total = 0
$script:passed = 0
function Assert-Ok($condition, $name, $detail) {
  $script:total += 1
  if ($condition) {
    $script:passed += 1
    Write-Host ('[OK] ' + $name)
  }
  else {
    Write-Host ('[FAIL] ' + $name + ' -- ' + $detail)
  }
}

$parsed = $null
$parseErr = ''
try { $parsed = Read-AgentFileCanonical -Path $testerPath }
catch { $parseErr = $_.Exception.Message }
Assert-Ok (($null -ne $parsed) -and ([string]$parsed.Canonical.Id -ceq 'tester')) 'parse tester.md' $parseErr
if ($null -eq $parsed) { Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed'); exit 1 }
$cRel = $parsed.Canonical

function Get-V1Effect($canonical, $cmd) {
  return (Get-V1RuleEffect -Rules @($canonical.ShellRules) -HasCatchAll ([bool]$canonical.HasCatchAll) -CatchAllEffect ([string]$canonical.CatchAllEffect) -Command $cmd)
}
function Get-V2Effect($canonical, $cmd) {
  $rules = @(Get-OrderedV2ShellRules -Canonical $canonical)
  return (Get-V2RuleEffect -V2Rules $rules -Action 'shell' -Command $cmd)
}
function Assert-Effect($expect, $canonical, $cmd, $label) {
  $e1 = Get-V1Effect $canonical $cmd
  $e2 = Get-V2Effect $canonical $cmd
  Assert-Ok ([string]$e1 -ceq $expect) ($label + ' [V1]') ('cmd=' + $cmd + ' eff=' + $e1)
  Assert-Ok ([string]$e2 -ceq $expect) ($label + ' [V2]') ('cmd=' + $cmd + ' eff=' + $e2)
  Assert-Ok ([string]$e1 -ceq [string]$e2) ($label + ' [paridade V1=V2]') ('v1=' + $e1 + ' v2=' + $e2)
}

# ---- (A) ALLOW: shell amplo para validacao --------------------------------------

foreach ($cmd in @(
  'npm test',
  'npm run build',
  'pnpm test',
  'pnpm --filter api exec vitest run test/a.test.ts',
  'yarn test',
  'bun test',
  'npx vitest run',
  'pytest -q',
  'python -m pytest',
  'ruff check .',
  'mypy .',
  'go test ./...',
  'go vet ./...',
  'cargo test',
  'dotnet test',
  'git status',
  'git diff',
  'git log',
  'powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1',
  'powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 -Name TaskKernel',
  'pwsh -NoProfile -NonInteractive -File scripts/test-package-consistency.ps1',
  'pwsh -NoProfile -NonInteractive -File tests/distribution/run-distribution-tests.ps1',
  'pwsh -NoProfile -NonInteractive -File scripts/validacao-local.ps1',
  'pwsh -NoProfile -Command Get-Date',
  'powershell -NoProfile -Command "Write-Host hi"',
  'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 -Name x | Select-Object -First 40',
  'tail -40',
  'echo sample'
)) {
  Assert-Effect 'allow' $cRel $cmd ('A: shell de validacao permitido: ' + $cmd)
}

# ---- (B) SHELL LIVRE: destruicao, elevacao, mutacao Git/infra -------------------

foreach ($cmd in @(
  'rm -rf build',
  'rm temporario.txt',
  'del /q temporario.txt',
  'erase temporario.txt',
  'rd /s /q build',
  'rmdir build',
  'ri temporario.txt',
  'Remove-Item -Recurse -Force build',
  'Remove-Item C:\dados -Recurse',
  'truncate -s 0 arquivo.log',
  'shred arquivo.log',
  'dd if=/dev/zero of=arquivo.img',
  'format C:',
  'sudo npm test',
  'sudo',
  'su root',
  'su',
  'runas /user:admin pwsh',
  'gsudo pwsh -Command hi',
  'doas make test',
  'git push origin main',
  'git push',
  'git reset --hard',
  'git reset HEAD~1',
  'git reset',
  'git clean -fd',
  'git clean',
  'git rebase main',
  'git rebase',
  'git merge feature',
  'git merge',
  'git commit -m x',
  'git commit',
  'git branch -D feature',
  'dropdb app_test',
  'terraform destroy -auto-approve',
  'kubectl delete pod x'
)) {
  Assert-Effect 'allow' $cRel $cmd ('B: shell irrestrito permite: ' + $cmd)
}

# ---- (C) SHELL LIVRE: deploy/publish/infra --------------------------------------

foreach ($cmd in @(
  'kubectl apply -f deploy.yaml',
  'docker rm container-aplicacao',
  'wrangler deploy',
  'npm run deploy',
  'npm publish',
  'gh release create v1.0.0',
  'gh auth login'
)) {
  Assert-Effect 'allow' $cRel $cmd ('C: shell irrestrito permite: ' + $cmd)
}

# ---- (D) ESTRUTURA: catch-all, edit/task, wildcard, guard V2 --------------------

Assert-Ok (([bool]$cRel.HasCatchAll) -and ([string]$cRel.CatchAllEffect -ceq 'allow')) 'D: catch-all * allow (shell amplo)' ([string]$cRel.CatchAllEffect)
Assert-Ok (([string]$cRel.Edit -ceq 'deny') -and ([bool]$cRel.EditPresent)) 'D: edit continua deny' ([string]$cRel.Edit)
Assert-Ok (([string]$cRel.TaskKind -ceq 'scalar') -and ([string]$cRel.TaskScalar -ceq 'deny')) 'D: task/subagent continua deny (scalar)' ('kind=' + [string]$cRel.TaskKind + ' task=' + [string]$cRel.TaskScalar)
Assert-Ok ([string]$cRel.BashKind -ceq 'map') 'D: bash em mapa' ([string]$cRel.BashKind)
Assert-Ok ((@($cRel.ShellRules)).Count -eq 1 -and [string]$cRel.ShellRules[0].Pattern -ceq '*' -and [string]$cRel.ShellRules[0].Effect -ceq 'allow') 'D: shell contém somente "*": allow'

$guardOk = $true
$guardErr = ''
try { Assert-NoAmbiguousOverlap -ShellRules @($cRel.ShellRules) | Out-Null }
catch { $guardOk = $false; $guardErr = $_.Exception.Message }
try { Assert-NoAmbiguousOverlap -ShellRules @($cRel.TaskRules) | Out-Null }
catch { $guardOk = $false; $guardErr = $_.Exception.Message }
Assert-Ok $guardOk 'D: guard de overlap V2 passa (build nao quebra)' $guardErr

$v2Ok = $true
$v2Err = ''
try { Convert-CanonicalToV2Frontmatter -Canonical $cRel | Out-Null } catch { $v2Ok = $false; $v2Err = $_.Exception.Message }
Assert-Ok $v2Ok 'D: emissao V2 do tester traduz sem erro' $v2Err

# ---- (E) COMPATIBILIDADE: roundtrip V1 ------------------------------------------

$roundOk = $true
$roundErr = ''
try {
  $v1 = Convert-CanonicalToV1Frontmatter -Canonical $cRel
  $back = Convert-AgentFrontmatterYamlToCanonical -FrontmatterText $v1.Text -SourceName 'tester'
  $a = @(@($cRel.ShellRules) | ForEach-Object { ([string]$_.Pattern) + '=' + ([string]$_.Effect) } | Sort-Object) -join '|'
  $b = @(@($back.ShellRules) | ForEach-Object { ([string]$_.Pattern) + '=' + ([string]$_.Effect) } | Sort-Object) -join '|'
  if ($a -cne $b) { $roundOk = $false; $roundErr = 'ShellRules divergem apos roundtrip' }
}
catch { $roundOk = $false; $roundErr = $_.Exception.Message }
Assert-Ok $roundOk 'E: roundtrip V1 do tester preserva shell rules' $roundErr

# ---- (F) COMPORTAMENTO: mandato do tester preservado ----------------------------

$body = [string]$parsed.Body
$bodyNorm = ($body -replace "\r?\n", ' ')
function Assert-BodyHas([string]$needle, [string]$name) {
  Assert-Ok ($bodyNorm.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) ('F: corpo ' + $name) ('ausente: ' + $needle)
}
Assert-BodyHas 'modifique c' 'proibe alterar app para testes passarem'
Assert-BodyHas 'crie subagentes' 'hierarquia rasa'

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed')
if ($script:passed -ne $script:total) { exit 1 }
exit 0
