<#!
.SYNOPSIS
    Contrato de autoridade do Tester: gateway run-v3-tests.ps1 + negacao de rotas alternativas.
.DESCRIPTION
    Suite estatica + funcional (PS 5.1, ASCII puro, [OK]/[FAIL] + exit 0/1), descoberta
    automatica pelo run-v3-tests (scripts/runtime/*.tests.ps1). Prova:
    (A) ALLOW do gateway fixo (bare e com -Name, rel/abs, powershell.exe/pwsh) na
        semantica V1 (most-specific-wins) e V2 (last-match-wins);
    (B) DENY de powershell/pwsh -Command, -File de script arbitrario, cmd/bash/sudo/
        runas/gsudo/doas e invocacao direta de suite (*.tests.ps1);
    (C) SEGURANCA: nenhum padrao equivalente a powershell */pwsh */shell */cmd */sudo */
        runas */bash *; nenhum padrao powershell/pwsh sem o caminho fixo do gateway;
        wildcard somente no fim do padrao; edit e task/subagent continuam deny; guard
        de overlap passa (build V2 nao quebra); gateway rejeita -Name invalido de
        forma fail-closed (exit 2, nenhuma suite executada);
    (D) COMPATIBILIDADE: paridade V1<->V2 para todas as amostras; roundtrip V1 do
        frontmatter do tester preserva as regras; selecao -Name casa suites reais;
    (E) COMPORTAMENTO: corpo do tester.md contra o contrato (gateway primeiro, negacao
        encerra a rota, proibido contorno, VALIDATION_CAPABILITY_UNAVAILABLE, sem
        pedido de shell generico, negacao nao e bug funcional).
    Nao modifica o repo (children apenas leem; invocacoes funcionais do gateway usam
    -Name sem match, que falha fechado antes de executar qualquer suite).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AgentTranslator.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testerPath = Join-Path $repoRoot 'source\agents\tester.md'
$runnerPath = Join-Path $repoRoot 'scripts\v3\run-v3-tests.ps1'
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

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

# Variante absoluta: mesmo tratamento do instalador (substituicao de {{REPO_DIR}}).
$sampleRepo = 'D:\sample-repo'
$cAbs = $cRel.Clone()
$cAbs.ShellRules = @()
foreach ($r in @($cRel.ShellRules)) {
  $p = [string]$r.Pattern
  if ($p.Contains('{{REPO_DIR}}')) { $p = $p.Replace('{{REPO_DIR}}', $sampleRepo) }
  $cAbs.ShellRules = @($cAbs.ShellRules) + @(@{ Pattern = $p; Effect = [string]$r.Effect })
}

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

# ---- (A) ALLOW: gateway fixo, bare e com -Name ---------------------------------

$relGw = 'scripts/v3/run-v3-tests.ps1'
$absGw = ($sampleRepo + '\scripts\v3\run-v3-tests.ps1')

Assert-Effect 'allow' $cRel ('powershell.exe -NoProfile -NonInteractive -File ' + $relGw) 'A: gateway rel bare powershell.exe'
Assert-Effect 'allow' $cRel ('powershell.exe -NoProfile -NonInteractive -File ' + $relGw + ' -Name TaskKernel') 'A: gateway rel -Name TaskKernel powershell.exe'
Assert-Effect 'allow' $cRel ('powershell.exe -NoProfile -NonInteractive -File ' + $relGw + ' -Name OrchestrationRecovery') 'A: gateway rel -Name OrchestrationRecovery powershell.exe'
Assert-Effect 'allow' $cRel ('powershell.exe -NoProfile -NonInteractive -File ' + $relGw + ' -Name *Kernel*') 'A: gateway rel -Name wildcard powershell.exe'
Assert-Effect 'allow' $cRel ('pwsh -NoProfile -NonInteractive -File ' + $relGw + ' -Name TaskKernel') 'A: gateway rel -Name TaskKernel pwsh'
Assert-Effect 'allow' $cRel ('pwsh -NoProfile -NonInteractive -File ' + $relGw + ' -Name OrchestrationRecovery') 'A: gateway rel -Name OrchestrationRecovery pwsh'
Assert-Effect 'allow' $cRel ('pwsh -NoProfile -NonInteractive -File ' + $relGw) 'A: gateway rel bare pwsh'
Assert-Effect 'allow' $cAbs ('powershell.exe -NoProfile -NonInteractive -File ' + $absGw + ' -Name TaskKernel') 'A: gateway abs -Name TaskKernel powershell.exe'
Assert-Effect 'allow' $cAbs ('pwsh -NoProfile -NonInteractive -File ' + $absGw + ' -Name OrchestrationRecovery') 'A: gateway abs -Name OrchestrationRecovery pwsh'
Assert-Effect 'allow' $cAbs ('powershell.exe -NoProfile -NonInteractive -File ' + $absGw) 'A: gateway abs bare powershell.exe'

# ---- (B) DENY: -Command, -File arbitrario, shells alternativos, suite direta ---

Assert-Effect 'deny' $cRel 'powershell.exe -NoProfile -Command "Write-Host hi"' 'B: powershell.exe -Command'
Assert-Effect 'deny' $cRel 'powershell -NoProfile -Command "Write-Host hi"' 'B: powershell -Command'
Assert-Effect 'deny' $cRel 'pwsh -NoProfile -Command "Write-Host hi"' 'B: pwsh -Command'
Assert-Effect 'deny' $cRel 'pwsh -Command Get-Date' 'B: pwsh -Command curto'
Assert-Effect 'deny' $cRel 'powershell.exe -NoProfile -NonInteractive -File scripts/v3/lib/OrchestrationRecovery.tests.ps1' 'B: suite direta powershell.exe'
Assert-Effect 'deny' $cRel 'pwsh -NoProfile -NonInteractive -File scripts/v3/lib/OrchestrationRecovery.tests.ps1' 'B: suite direta pwsh'
Assert-Effect 'deny' $cRel 'powershell -NoProfile -File scripts/v3/lib/OrchestrationRecovery.tests.ps1' 'B: suite direta powershell sem NonInteractive'
Assert-Effect 'deny' $cAbs ('powershell.exe -NoProfile -NonInteractive -File ' + $sampleRepo + '\scripts\v3\lib\OrchestrationRecovery.tests.ps1') 'B: suite direta abs'
Assert-Effect 'deny' $cAbs ('pwsh -NoProfile -NonInteractive -File ' + $sampleRepo + '\scripts\outro-script.ps1') 'B: -File arbitrario abs pwsh'
Assert-Effect 'deny' $cRel 'powershell.exe -NoProfile -NonInteractive -File scripts/outro.ps1' 'B: -File arbitrario rel powershell.exe'
Assert-Effect 'deny' $cRel 'cmd /c powershell -NoProfile -Command "hi"' 'B: cmd /c'
Assert-Effect 'deny' $cRel 'bash -c "powershell -Command hi"' 'B: bash -c'
Assert-Effect 'deny' $cRel 'sudo powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1' 'B: sudo prefixo'
Assert-Effect 'deny' $cRel 'runas /profile powershell -NoProfile -Command hi' 'B: runas prefixo'
Assert-Effect 'deny' $cRel 'gsudo pwsh -NoProfile -Command hi' 'B: gsudo prefixo'
Assert-Effect 'deny' $cRel 'doas pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1' 'B: doas prefixo'

# ---- (C) SEGURANCA: estrutura do mapa, guard V2, fail-closed do gateway --------

$forbiddenEq = @('powershell *', 'powershell.exe *', 'pwsh *', 'pwsh.exe *', 'powershell -Command *', 'powershell.exe -Command *', 'pwsh -Command *', 'powershell -File *', 'powershell.exe -File *', 'pwsh -File *', 'shell *', 'cmd *', 'bash *', 'sh *', 'sudo *', 'runas *', 'gsudo *', 'doas *')
$noEq = $true
$eqDetail = ''
foreach ($r in @($cRel.ShellRules)) {
  $p = ([string]$r.Pattern).ToLowerInvariant()
  foreach ($f in $forbiddenEq) {
    if ($p -ceq $f) { $noEq = $false; $eqDetail += ('padrao proibido: ' + $p + ' ') }
  }
}
Assert-Ok $noEq 'C: nenhum padrao equivalente a powershell */shell */cmd */sudo */runas *' $eqDetail

$psPathOk = $true
$psPathDetail = ''
# Conjunto FECHADO das entradas powershell/pwsh autorizadas (4 exatas + 4 com
# wildcard somente apos o caminho fixo). Qualquer outra regra powershell/pwsh
# no mapa e violacao do contrato (ex.: 'pwsh -Command run-v3-tests.ps1 *').
$gwAuthorized = @(
  'powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1',
  'powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 *',
  'powershell.exe -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1',
  'powershell.exe -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1 *',
  'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1',
  'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 *',
  'pwsh -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1',
  'pwsh -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1 *'
)
foreach ($r in @($cRel.ShellRules)) {
  $p = [string]$r.Pattern
  if ($r.Effect -cne 'allow') { continue }
  if ($p -notmatch '^(powershell(\.exe)?|pwsh(\.exe)?)(\s|$)') { continue }
  $inSet = $false
  foreach ($g in $gwAuthorized) { if ($p -ceq $g) { $inSet = $true; break } }
  if (-not $inSet) {
    $psPathOk = $false
    $psPathDetail += ('allow powershell fora do conjunto fechado: ' + $p + ' ')
  }
}
$missAuth = ''
foreach ($g in $gwAuthorized) {
  $found = $false
  foreach ($r in @($cRel.ShellRules)) {
    if (([string]$r.Pattern -ceq $g) -and ([string]$r.Effect -ceq 'allow')) { $found = $true; break }
  }
  if (-not $found) { $missAuth += ($g + ' ') }
}
if ([string]$missAuth -ne '') { $psPathOk = $false; $psPathDetail += ('faltando: ' + $missAuth) }
Assert-Ok $psPathOk 'C: allows powershell/pwsh == conjunto fechado do gateway (8 entradas)' $psPathDetail

$wildcardPosOk = $true
$wildcardPosDetail = ''
foreach ($r in @($cRel.ShellRules)) {
  $p = [string]$r.Pattern
  $ix = $p.IndexOf('*')
  if ($ix -ge 0) {
    if ($ix -ne ($p.Length - 1)) { $wildcardPosOk = $false; $wildcardPosDetail += ($p + ' ') }
  }
}
Assert-Ok $wildcardPosOk 'C: wildcard somente no fim do padrao (nenhum * interno)' $wildcardPosDetail

$gw4 = @(
  'powershell.exe -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 *',
  'powershell.exe -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1 *',
  'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 *',
  'pwsh -NoProfile -NonInteractive -File {{REPO_DIR}}\scripts\v3\run-v3-tests.ps1 *'
)
$miss4 = ''
foreach ($p in $gw4) {
  $found = $false
  foreach ($r in @($cRel.ShellRules)) {
    if (([string]$r.Pattern -ceq $p) -and ([string]$r.Effect -ceq 'allow')) { $found = $true; break }
  }
  if (-not $found) { $miss4 += ($p + ' ') }
}
Assert-Ok ([string]$miss4 -ceq '') 'C: 4 entradas wildcard do gateway presentes (rel + abs x powershell.exe + pwsh)' $miss4

Assert-Ok (([string]$cRel.Edit -ceq 'deny') -and ([bool]$cRel.EditPresent)) 'C: edit continua deny' ([string]$cRel.Edit)
Assert-Ok (([string]$cRel.TaskKind -ceq 'scalar') -and ([string]$cRel.TaskScalar -ceq 'deny')) 'C: task/subagent continua deny (scalar)' ('kind=' + [string]$cRel.TaskKind + ' task=' + [string]$cRel.TaskScalar)

$guardOk = $true
$guardErr = ''
try { Assert-NoAmbiguousOverlap -ShellRules @($cRel.ShellRules) | Out-Null }
catch { $guardOk = $false; $guardErr = $_.Exception.Message }
try { Assert-NoAmbiguousOverlap -ShellRules @($cRel.TaskRules) | Out-Null }
catch { $guardOk = $false; $guardErr = $_.Exception.Message }
Assert-Ok $guardOk 'C: guard de overlap V2 passa (build nao quebra)' $guardErr

$v2Ok = $true
$v2Err = ''
try { Convert-CanonicalToV2Frontmatter -Canonical $cRel | Out-Null } catch { $v2Ok = $false; $v2Err = $_.Exception.Message }
Assert-Ok $v2Ok 'C: emissao V2 do tester traduz sem erro' $v2Err

# Gateway funcional: -Name invalido (charset) e -Name sem match => exit 2,
# antes de executar qualquer suite (fail-closed).
function Invoke-GatewayName([string]$FilterName) {
  $out = & $psExe -NoProfile -NonInteractive -File $runnerPath -Name $FilterName 2>&1 | Out-String
  return @{ Code = $LASTEXITCODE; Out = $out }
}
$g1 = Invoke-GatewayName 'a;b'
Assert-Ok (([int]$g1.Code -eq 2) -and ([string]$g1.Out -like '*filtro -Name invalido*')) 'C: gateway rejeita -Name com ; (exit 2 fail-closed)' ('exit=' + [string]$g1.Code + ' out=' + ([string]$g1.Out).Trim())
$g2 = Invoke-GatewayName '..\..\fora-do-repo'
Assert-Ok (([int]$g2.Code -eq 2) -and ([string]$g2.Out -like '*filtro -Name invalido*')) 'C: gateway rejeita -Name com caminho (exit 2 fail-closed)' ('exit=' + [string]$g2.Code + ' out=' + ([string]$g2.Out).Trim())
$g3 = Invoke-GatewayName 'zzz-sem-suite-zzz'
Assert-Ok (([int]$g3.Code -eq 2) -and ([string]$g3.Out -like '*nenhuma suite encontrada*')) 'C: gateway sem match sai 2 sem executar suite' ('exit=' + [string]$g3.Code + ' out=' + ([string]$g3.Out).Trim())
$g4 = Invoke-GatewayName "`t"
Assert-Ok (([int]$g4.Code -eq 2) -and ([string]$g4.Out -like '*filtro -Name invalido*')) 'C: gateway rejeita -Name tab-only (exit 2 fail-closed)' ('exit=' + [string]$g4.Code + ' out=' + ([string]$g4.Out).Trim())
$g5 = Invoke-GatewayName ("TaskKernel" + [char]10)
Assert-Ok (([int]$g5.Code -eq 2) -and ([string]$g5.Out -like '*filtro -Name invalido*')) 'C: gateway rejeita -Name com LF final (\A...\z, exit 2)' ('exit=' + [string]$g5.Code + ' out=' + ([string]$g5.Out).Trim())
$g6 = Invoke-GatewayName ' '
Assert-Ok (([int]$g6.Code -eq 2) -and ([string]$g6.Out -like '*nenhuma suite encontrada*')) 'C: gateway -Name espaco-only nao roda todas as suites (exit 2)' ('exit=' + [string]$g6.Code + ' out=' + ([string]$g6.Out).Trim())

# Limitacao documentada (docs/PERMISSIONS.md): o glob e string-matching sobre o
# comando inteiro; contencao de chaining (ex.: ... & cmd /c ...) e planner-enforced,
# nao do glob. Assercao honesta para impedir claim futuro de contencao via glob.
$chainSample = 'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 -Name x & cmd /c echo hi'
Assert-Ok (Test-GlobMatch -Pattern 'pwsh -NoProfile -NonInteractive -File scripts/v3/run-v3-tests.ps1 *' -Text $chainSample) 'C (limitacao): glob casa texto de chaining; contencao e planner-enforced' 'glob deveria casar (limitacao documentada)'

# ---- (D) COMPATIBILIDADE: roundtrip V1 e selecao -Name real --------------------

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
Assert-Ok $roundOk 'D: roundtrip V1 do tester preserva shell rules' $roundErr

# Selecao -Name replica a descoberta do gateway: substring valida encontra suite real.
$disc = @()
$disc += @(Get-ChildItem -File (Join-Path $repoRoot 'scripts\v3\*.tests.ps1') -ErrorAction SilentlyContinue)
$disc += @(Get-ChildItem -File (Join-Path $repoRoot 'scripts\v3\lib\*.tests.ps1') -ErrorAction SilentlyContinue)
$disc += @(Get-ChildItem -File (Join-Path $repoRoot 'scripts\runtime\*.tests.ps1') -ErrorAction SilentlyContinue)
$hitTask = @($disc | Where-Object { $_.Name -like '*TaskKernel*' })
$hitXlate = @($disc | Where-Object { $_.Name -like '*translation*' })
Assert-Ok ((@($hitTask).Count -ge 1) -and (@($hitTask)[0].Name -like '*.tests.ps1')) 'D: -Name TaskKernel seleciona suite real' ((@($hitTask) | ForEach-Object { $_.Name }) -join ',')
Assert-Ok ((@($hitXlate).Count -ge 1) -and (@($hitXlate)[0].Name -like '*.tests.ps1')) 'D: -Name translation seleciona suite real' ((@($hitXlate) | ForEach-Object { $_.Name }) -join ',')

# ---- (E) COMPORTAMENTO: corpo do tester.md contra o contrato -------------------

$body = [string]$parsed.Body
$bodyNorm = ($body -replace "\r?\n", ' ')
function Assert-BodyHas([string]$needle, [string]$name) {
  Assert-Ok ($bodyNorm.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) ('E: corpo ' + $name) ('ausente: ' + $needle)
}
Assert-BodyHas 'run-v3-tests.ps1' 'cita o gateway fixo'
Assert-BodyHas '-Name' 'cita selecao de suite'
Assert-BodyHas 'VALIDATION_CAPABILITY_UNAVAILABLE' 'define blocker estruturado'
Assert-BodyHas 'Permission denied' 'trata negacao como autoridade'
Assert-BodyHas 'ENCERRA' 'negacao encerra a rota'
Assert-BodyHas '-Command' 'proibe powershell -Command'
Assert-BodyHas 'cmd' 'proibe cmd'
Assert-BodyHas 'bash' 'proibe bash'
Assert-BodyHas 'sudo' 'proibe sudo'
Assert-BodyHas 'runas' 'proibe runas'
Assert-BodyHas 'gsudo' 'proibe gsudo'
Assert-BodyHas 'doas' 'proibe doas'
Assert-BodyHas 'bug funcional' 'negacao nao e bug funcional'
Assert-BodyHas 'amplia' 'proibe pedir shell generico'
Assert-BodyHas 'modifique c' 'proibe alterar app para testes passarem'
Assert-BodyHas 'altere c' 'reafirma proibicao de alterar app'
Assert-BodyHas 'AUTHORITY-SAFE COMMAND REFORMULATION' 'nomeia regra canonica'
Assert-BodyHas 'MAX ONE SAFE REFORMULATION' 'limita reformulacao a uma'
Assert-BodyHas 'SAME PRIMARY VALIDATION' 'preserva validacao principal'
Assert-BodyHas 'AUXILIARY OUTPUT STAGE' 'distingue deny auxiliar'
Assert-BodyHas 'VALIDATION CAPABILITY UNAVAILABLE' 'distingue incapacidade principal'
Assert-BodyHas 'TEST FAILED' 'distingue falha funcional'
Assert-BodyHas 'ferramenta de teste direta' 'prioriza teste direto'
Assert-BodyHas 'flags nativas' 'prioriza flags nativas'
Assert-BodyHas 'tail, head, grep, sed' 'nao sugere utilitarios de output'
Assert-BodyHas 'indefinidamente' 'encerra busca por rotas'
Assert-BodyHas 'su' 'proibe su como elevacao'

# F) CONTRATO TEXTUAL + MATCHERS V1/V2 (nao execucao live do agente).
# Package managers permanecem autorizados; teste o conteudo literal do exemplo
# canonico, em vez de simular a saida do modelo com a expectativa como variavel.
foreach ($cmd in @('pnpm --filter @iptv/api exec vitest run test/a.test.ts', 'npm test', 'yarn test', 'bun test')) {
  Assert-Effect 'allow' $cRel $cmd ('F: ferramenta de teste direta preservada: ' + $cmd)
}
Assert-BodyHas 'input `pnpm test | tail-40` -> output `pnpm test`' 'F: exemplo contratual remove apenas tail'
# Nos runtimes suportados, o parser entrega recursos por comando; um deny em
# qualquer segmento bloqueia a invocacao. Estes asserts exercitam os matchers
# com segmentos de fixture, nao o parser/runtime real nem decisao live do agente.
$mainSegment = 'pnpm --filter @iptv/api exec vitest run test/a.test.ts 2>&1'
$auxSegment = 'tail -40'
Assert-Effect 'allow' $cRel $mainSegment 'F: segmento principal autorizado [V1/V2]'
Assert-Effect 'deny' $cRel $auxSegment 'F: tail auxiliar negado [V1/V2]'
$segmentEffects = @((Get-V1Effect $cRel $mainSegment), (Get-V1Effect $cRel $auxSegment))
Assert-Ok ($segmentEffects -contains 'deny') 'F: qualquer segmento negado bloqueia a invocacao no matcher V1'
$segmentEffectsV2 = @((Get-V2Effect $cRel $mainSegment), (Get-V2Effect $cRel $auxSegment))
Assert-Ok ($segmentEffectsV2 -contains 'deny') 'F: qualquer segmento negado bloqueia a invocacao no matcher V2'
Assert-BodyHas 'principal esta autorizada separadamente' 'F: reformulacao exige main autorizado'
Assert-BodyHas 'auxiliar e o unico negado' 'F: reformulacao exige deny auxiliar isolado'
Assert-BodyHas 'NO ALTERNATE OUTPUT UTILITY SEQUENCE' 'F: contrato proibe tentativa sequencial de utilitarios'
Assert-BodyHas 'MAX ONE SAFE REFORMULATION' 'F: contrato limita a uma reformulacao'
Assert-BodyHas 'NO ALTERNATE OUTPUT UTILITY SEQUENCE' 'F: contrato proibe tentativa sequencial de utilitarios'
$deniedPrimary = 'powershell -File teste.ps1'
$forbiddenRewrites = @('powershell -Command "& teste.ps1"', 'cmd /c powershell -File teste.ps1', 'pwsh -Command "& teste.ps1"', 'bash -c "powershell -File teste.ps1"', 'sudo powershell -File teste.ps1', 'runas powershell -File teste.ps1', 'gsudo powershell -File teste.ps1', 'doas powershell -File teste.ps1', 'su -c "powershell -File teste.ps1"')
Assert-Effect 'deny' $cRel $deniedPrimary 'F: deny da operacao principal termina a rota'
foreach ($rewrite in $forbiddenRewrites) {
  Assert-Effect 'deny' $cRel $rewrite ('F: bypass proibido: ' + $rewrite)
}
Assert-BodyHas 'INTENDED VALIDATION' 'blocker inclui validacao pretendida'
Assert-BodyHas 'RESTRICTION FOUND' 'blocker inclui restricao encontrada'
Assert-BodyHas 'SAFE ALTERNATIVE' 'blocker inclui alternativa segura se conhecida'


Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed')
if ($script:passed -ne $script:total) { exit 1 }
exit 0
