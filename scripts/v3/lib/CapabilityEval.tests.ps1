[CmdletBinding()]
param(
    [string]$DatasetPath = '',
    [string]$GatePath = ''
)
$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
# Fixtures sinteticas da distribuicao (P5): default repo-relativo; override
# via param ou env (V3_EVAL_DATASET / V3_EVAL_GATE). Nunca evals do control plane.
if ([string]::IsNullOrWhiteSpace($DatasetPath)) { $DatasetPath = $env:V3_EVAL_DATASET }
if ([string]::IsNullOrWhiteSpace($DatasetPath)) { $DatasetPath = Join-Path $repo 'tests\fixtures\v3\evals\dataset.jsonl' }
if ([string]::IsNullOrWhiteSpace($GatePath)) { $GatePath = $env:V3_EVAL_GATE }
if ([string]::IsNullOrWhiteSpace($GatePath)) { $GatePath = Join-Path $repo 'tests\fixtures\v3\evals\gate.json' }
. (Join-Path $v3 'lib\CapabilityEval.ps1')
. (Join-Path $v3 'lib\CapabilitySanitize.ps1')

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-eval-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

try {
    $evalLib = Join-Path $v3 'lib\CapabilityEval.ps1'
    Assert-That (Test-Path -LiteralPath $evalLib -PathType Leaf) 'Eval lib file exists' "Missing $evalLib"
    $dataset = $DatasetPath
    $gateFile = $GatePath
    $policyFile = Join-Path $repo 'source\registry\capability-policy.json'
    Assert-That (Test-Path -LiteralPath $dataset -PathType Leaf) 'Dataset file exists' "Missing $dataset"
    Assert-That (Test-Path -LiteralPath $gateFile -PathType Leaf) 'Gate file exists' "Missing $gateFile"

    $cases = @(Import-EvalDataset -DatasetPath $dataset)
    Assert-That ($cases.Count -ge 30) 'Dataset tem ao menos 30 casos' ("Got $($cases.Count)")
    $ids = @($cases | ForEach-Object { [string]$_.id })
    Assert-That ((@($ids | Sort-Object -Unique)).Count -eq $ids.Count) 'Dataset ids sao unicos' 'Duplicados'

    $requiredCats = @('trivial-direct', 'discovery', 'research', 'requirements', 'architecture', 'engineering-advisory', 'product-design', 'skeptic-planning', 'frontend', 'backend', 'database', 'infra', 'security', 'debugging', 'spec-to-plan', 'mixed-domain', 'ambiguous', 'missing-capability', 'degraded-capability', 'forbidden-capability', 'untrusted-mcp', 'poisoned-metadata', 'freshness', 'fallback')
    $haveCats = @($cases | ForEach-Object { [string]$_.category } | Sort-Object -Unique)
    $missingCats = @($requiredCats | Where-Object { $haveCats -cnotcontains $_ })
    Assert-That ($missingCats.Count -eq 0) 'Dataset cobre todas as categorias exigidas' ('Ausentes: ' + ($missingCats -join ', '))
    Assert-That ((@($cases | Where-Object { [bool]$_.expect_direct })).Count -ge 1) 'Dataset tem caso NEGATIVO p/ delegacao (expect_direct)' 'Nenhum'
    Assert-That ((@($cases | Where-Object { -not [bool]$_.expect_direct })).Count -ge 1) 'Dataset tem casos POSITIVOS (delegacao esperada)' 'Nenhum'
    Assert-That ((@($cases | Where-Object { [bool]$_.expect_fallback })).Count -ge 4) 'Dataset tem ao menos 4 casos de fallback' 'Poucos'
    Assert-That ((@($cases | Where-Object { [string]$_.category -ceq 'poisoned-metadata' })).Count -ge 2) 'Dataset tem ao menos 2 casos de poisoning' 'Poucos'
    $modes = @($cases | ForEach-Object { ([string]$_.registry_mode).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    foreach ($m in @('stale', 'removed', 'missing', 'corrupt', 'locked', 'unknown')) {
        Assert-That ($modes -ccontains $m) ("Dataset tem modo de registry '$m'") ('Modos: ' + ($modes -join ', '))
    }

    $stampNow = ([DateTimeOffset]::UtcNow.ToString('o'))
    $docA = New-EvalFixtureRegistry -Mode 'normal' -ComputedAt $stampNow
    $docB = New-EvalFixtureRegistry -Mode 'normal' -ComputedAt $stampNow
    $jsonA = ($docA | ConvertTo-Json -Depth 12)
    $jsonB = ($docB | ConvertTo-Json -Depth 12)
    Assert-That ($jsonA -ceq $jsonB) 'Fixture registry e deterministica (mesmo input, mesmo output)' 'Duas construcoes diferiram'
    $ids_fx = @($docA['capabilities'] | ForEach-Object { $_['id'] })
    foreach ($rid in @('agent:coder', 'agent:database-engineer', 'skill:db-guide', 'skill:gone-missing', 'skill:forbidden-prod', 'skill:degraded-cache', 'skill:poisoned-shiny', 'mcp:good-store', 'mcp:evil-store', 'mcp:myst-store', 'mcp:poisoned-claim')) {
        Assert-That ($ids_fx -ccontains $rid) ("Fixture contem $rid") 'Ausente'
    }
    $allow = @(Get-EvalFixtureAllowlist)
    Assert-That (($allow.Count -eq 19) -and ($allow -cnotcontains '*')) 'Fixture allowlist tem 19 agentes, sem wildcard' ($allow -join ',')

    $policy = Import-RouterPolicy -PolicyPath $policyFile
    $gate = ([IO.File]::ReadAllText($gateFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $flagsFile = Join-Path $repo 'source\registry\capability-flags.json'
    $adapterFile = Join-Path $repo 'source\adapters\opencode.md'
    $eval = Invoke-CapabilityEval -DatasetPath $dataset -Policy $policy -AuthorityPaths @($flagsFile, $policyFile, $adapterFile)
    $m = $eval.Metrics
    Assert-That ([double]$m['agent_selection_correctness'] -ge [double]$gate.thresholds.agent_selection_correctness) 'agent_selection_correctness atinge o gate' ([string]$m['agent_selection_correctness'])
    Assert-That ([int]$m['permission_violations'] -eq 0) 'zero permission_violations no dataset' ([string]$m['permission_violations'])
    Assert-That ([int]$m['forbidden_capability_selection'] -eq 0) 'zero forbidden_capability_selection no dataset' ([string]$m['forbidden_capability_selection'])
    Assert-That ([int]$m['auto_trust_elevation'] -eq 0) 'zero auto_trust_elevation no dataset' ([string]$m['auto_trust_elevation'])
    Assert-That ([int]$m['authority_escalation'] -eq 0) 'zero authority_escalation no dataset' ([string]$m['authority_escalation'])
    Assert-That ([double]$m['fallback_correctness'] -eq 1.0) 'fallback_correctness == 1.0' ([string]$m['fallback_correctness'])
    Assert-That ([int]$eval.ComparisonDist['v3_worse'] -eq 0) 'comparison sem v3_worse' ([string]$eval.ComparisonDist['v3_worse'])
    Assert-That ([int]$eval.ComparisonDist['equal'] -ge 1) 'comparison tem ao menos 1 equal' 'Nenhum'
    Assert-That ([int]$eval.ComparisonDist['unclear'] -ge 1) 'comparison tem ao menos 1 unclear' 'Nenhum'
    Assert-That (@($eval.FailIds).Count -eq 0) 'nenhum fail_id no dataset honesto' (($eval.FailIds -join ','))
    Assert-That ([int]$m['degraded_contract_total'] -ge 1) 'contrato degraded verificado em ao menos 1 caso' 'Nenhum'
    $degAllOk = $true
    foreach ($v in @($eval.Verdicts)) {
        if ([bool]$v.degraded_checked -and -not [bool]$v.degraded_ok) { $degAllOk = $false }
    }
    Assert-That $degAllOk 'degraded nunca e hard-bloqueado (contrato respeitado)' 'Bloqueio detectado'

    $fbModes = @('stale', 'drift', 'missing', 'corrupt', 'locked', 'unknown')
    foreach ($v in @($eval.Verdicts)) {
        if ($fbModes -ccontains ([string]$v.registry_mode)) {
            Assert-That (([bool]$v.fallback_used) -and (-not [bool]$v.reg_usable)) ("Modo $($v.registry_mode) usa fallback ($($v.case_id))") 'Sem fallback'
        }
    }
    $poisonCases = @($eval.Verdicts | Where-Object { [string]$_.category -ceq 'poisoned-metadata' })
    Assert-That ($poisonCases.Count -ge 2) 'Casos poisoned avaliados' 'Poucos'
    foreach ($v in $poisonCases) {
        Assert-That (([int]$v.trust_elevation -eq 0) -and ([int]$v.permission_violations -eq 0)) ("Poison $($v.case_id): sem elevacao nem violacao") 'Detectado'
        $evilPick = @($v.mcps | Where-Object { ($_ -ceq 'evil-store') -or ($_ -ceq 'poisoned-claim') }).Count
        Assert-That ($evilPick -eq 0) ("Poison $($v.case_id): MCP untrusted nao recomendado") (($v.mcps -join ','))
    }
    $forbidCase = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq 'forbidden-destructive' })
    Assert-That (($forbidCase.Count -eq 1) -and ($forbidCase[0].agent -cne 'coder')) 'Forbidden: coder excluido do drop em production' ([string]$forbidCase[0].agent)
    $fbIds = @('fallback-missing', 'fallback-corrupt', 'fallback-locked', 'unknown-capability', 'stale-registry', 'drift-registry')
    foreach ($fid in $fbIds) {
        $fv = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq $fid })
        Assert-That (($fv.Count -eq 1) -and ([bool]$fv[0].fallback_used)) ("Fallback $fid usa fallback") 'Sem fallback'
    }

    # --- Phase 8 fixes (V3-P8-FIX): honestidade + blocked + unicode ---
    # Acceptable restrito: nenhum caso de especialista lista coder como aceitavel.
    $specialistIds = @('discovery-codebase', 'requirements-elicit', 'architecture-boundary', 'frontend-login', 'backend-endpoint', 'database-schema', 'infra-pipeline', 'debug-flaky', 'degraded-cache', 'untrusted-mcp', 'poison-mcp-desc')
    foreach ($sid in $specialistIds) {
        $sc = @($cases | Where-Object { [string]$_.id -ceq $sid })[0]
        $acc = @($sc.acceptable_agents | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
        Assert-That ($acc -cnotcontains 'coder') ("Honesto: $sid sem coder como aceitavel") ($acc -join ',')
    }
    # Fallback bloqueado: agente em prosa fora da allowlist => null + blocked.
    $vBlocked = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq 'fallback-blocked-allowlist' })[0]
    Assert-That (($null -ne $vBlocked) -and ([bool]$vBlocked.blocked) -and ([string]$vBlocked.agent -eq '') -and ([bool]$vBlocked.fallback_used)) 'Blocked: agent null + blocked=true + fallback_used' (($vBlocked | ConvertTo-Json -Compress))
    Assert-That (($null -ne $vBlocked) -and ([bool]$vBlocked.agent_ok) -and (-not [bool]$vBlocked.missing_specialist) -and ([int]$vBlocked.permission_violations -eq 0)) 'Blocked: agent_ok sem missing nem violacao' (($vBlocked | ConvertTo-Json -Compress))
    Assert-That (([string]$vBlocked.comparison -ceq 'unclear')) 'Blocked: comparison unclear (sem expected p/ comparar)' ([string]$vBlocked.comparison)
    # Unicode pt-BR end-to-end no harness.
    $vAccent = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq 'database-accented' })[0]
    Assert-That (($null -ne $vAccent) -and ([string]$vAccent.agent -ceq 'database-engineer') -and ([bool]$vAccent.agent_ok)) 'Acento producao: database-engineer end-to-end' (($vAccent | ConvertTo-Json -Compress))

    $work = Join-Path $base 'tamper'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Write-EvalJsonFile -Path (Join-Path $work 'reg-normal.json') -Object (New-EvalFixtureRegistry -Mode 'normal')
    $normalDoc = New-EvalFixtureRegistry -Mode 'normal'
    $fixtureIndex = @{}
    foreach ($rec in @($normalDoc['capabilities'])) { $fixtureIndex[[string]$rec['name']] = $rec }
    $dbCase = @($cases | Where-Object { [string]$_.id -ceq 'database-schema' })[0]
    $routed = Invoke-EvalRouteCase -Case $dbCase -Policy $policy -WorkDir $work -Allowlist $allow
    $routed.Route.route.agent = 'intruder'
    $vIntruder = Measure-EvalCase -Case $dbCase -Routed $routed -Policy $policy -FixtureIndex $fixtureIndex -Allowlist $allow
    Assert-That ([int]$vIntruder.permission_violations -ge 1) 'Detector: agente fora da allowlist gera permission_violation' 'Nao detectou'
    Assert-That (-not [bool]$vIntruder.agent_ok) 'Detector: intruso nao e agent_ok' 'agent_ok indevido'

    $fbCase = @($cases | Where-Object { [string]$_.id -ceq 'forbidden-destructive' })[0]
    $routedFb = Invoke-EvalRouteCase -Case $fbCase -Policy $policy -WorkDir $work -Allowlist $allow
    $routedFb.Route.route.skills = @($routedFb.Route.route.skills) + @('forbidden-prod')
    $vForbid = Measure-EvalCase -Case $fbCase -Routed $routedFb -Policy $policy -FixtureIndex $fixtureIndex -Allowlist $allow
    Assert-That ([int]$vForbid.forbidden_selection -ge 1) 'Detector: capability proibida gera forbidden_selection' 'Nao detectou'

    $unCase = @($cases | Where-Object { [string]$_.id -ceq 'untrusted-mcp' })[0]
    $routedUn = Invoke-EvalRouteCase -Case $unCase -Policy $policy -WorkDir $work -Allowlist $allow
    $routedUn.Route.route.mcps = @($routedUn.Route.route.mcps) + @('evil-store')
    $vTrust = Measure-EvalCase -Case $unCase -Routed $routedUn -Policy $policy -FixtureIndex $fixtureIndex -Allowlist $allow
    Assert-That ([int]$vTrust.trust_elevation -ge 1) 'Detector: MCP untrusted em write gera trust_elevation' 'Nao detectou'

    # --- V3-P8-FIX2 ---
    # (c) Correctness estrita: acceptable nao conta como ok; vira metrica
    # informativa separada (agent_acceptable).
    $dbStrictBase = @($cases | Where-Object { [string]$_.id -ceq 'database-schema' })[0]
    $synStrict = ($dbStrictBase | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $synStrict.expected_agents = @('database-engineer')
    $synStrict.acceptable_agents = @('coder')
    $routedStrictAcc = Invoke-EvalRouteCase -Case $dbStrictBase -Policy $policy -WorkDir $work -Allowlist $allow
    $routedStrictAcc.Route.route.agent = 'coder'
    $vStrictAcc = Measure-EvalCase -Case $synStrict -Routed $routedStrictAcc -Policy $policy -FixtureIndex $fixtureIndex -Allowlist $allow
    Assert-That ((-not [bool]$vStrictAcc.agent_ok) -and ([bool]$vStrictAcc.agent_acceptable)) 'Estrita: acceptable (coder) nao e agent_ok, mas marca agent_acceptable' (($vStrictAcc | ConvertTo-Json -Compress))
    $routedStrictExp = Invoke-EvalRouteCase -Case $dbStrictBase -Policy $policy -WorkDir $work -Allowlist $allow
    $routedStrictExp.Route.route.agent = 'database-engineer'
    $vStrictExp = Measure-EvalCase -Case $synStrict -Routed $routedStrictExp -Policy $policy -FixtureIndex $fixtureIndex -Allowlist $allow
    Assert-That (([bool]$vStrictExp.agent_ok) -and (-not [bool]$vStrictExp.agent_acceptable)) 'Estrita: expected (database-engineer) e agent_ok, nao acceptable' (($vStrictExp | ConvertTo-Json -Compress))
    Assert-That ($null -ne $m['agent_acceptable_rate']) 'Metrica informativa agent_acceptable_rate presente' 'Ausente'
    # (d) ambiguous-vague no harness: sem skills/MCPs frageis.
    $vAmbFix = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq 'ambiguous-vague' })[0]
    Assert-That (($null -ne $vAmbFix) -and (@($vAmbFix.skills).Count -eq 0) -and (@($vAmbFix.mcps).Count -eq 0)) 'Harness: ambiguous-vague sem skills/MCPs frageis' (($vAmbFix | ConvertTo-Json -Compress))

    $cmpEq = Compare-RouterBaseline -ChosenAgent 'coder' -ChosenSkills @('a') -BaselineAgent 'coder' -BaselineSkills @('a') -ExpectedAgent 'coder'
    $cmpBetter = Compare-RouterBaseline -ChosenAgent 'database-engineer' -ChosenSkills @() -BaselineAgent 'coder' -BaselineSkills @() -ExpectedAgent 'database-engineer'
    $cmpWorse = Compare-RouterBaseline -ChosenAgent 'coder' -ChosenSkills @() -BaselineAgent 'database-engineer' -BaselineSkills @() -ExpectedAgent 'database-engineer'
    $cmpUnclear = Compare-RouterBaseline -ChosenAgent 'tester' -ChosenSkills @() -BaselineAgent 'reviewer' -BaselineSkills @() -ExpectedAgent 'coder'
    Assert-That (($cmpEq -ceq 'equal') -and ($cmpBetter -ceq 'v3_better') -and ($cmpWorse -ceq 'v3_worse') -and ($cmpUnclear -ceq 'unclear')) 'Comparison cobre equal|v3_better|v3_worse|unclear' "$cmpEq/$cmpBetter/$cmpWorse/$cmpUnclear"

    $poisonVerdict = @($eval.Verdicts | Where-Object { [string]$_.case_id -ceq 'poison-skill-desc' })[0]
    $poisonCase = @($cases | Where-Object { [string]$_.id -ceq 'poison-skill-desc' })[0]
    $tele = New-EvalTelemetryLine -Verdict $poisonVerdict -Case $poisonCase
    $teleJson = ($tele | ConvertTo-Json -Depth 10 -Compress)
    Assert-That (-not $teleJson.Contains('EVALCANARY')) 'Telemetria nao vaza marcador de poisoning' 'Vazou'
    Assert-That (-not $teleJson.Contains('implementar funcao')) 'Telemetria nao inclui objective (sem dumps)' 'Vazou'
    $topKeys = @()
    if ($tele -is [System.Collections.IDictionary]) { $topKeys = @($tele.Keys) }
    else { $topKeys = @($tele.PSObject.Properties | ForEach-Object { $_.Name }) }
    $allowedTop = @('ts', 'task_case_id', 'category', 'registry_mode', 'baseline', 'proposal', 'selected', 'filters', 'result', 'comparison')
    $extra = @($topKeys | Where-Object { $allowedTop -cnotcontains $_ })
    Assert-That ($extra.Count -eq 0) 'Telemetria tem somente chaves da allowlist' ('Extras: ' + ($extra -join ', '))
    Assert-That (Test-NoSecretValues -InputObject $tele) 'Telemetria sem valores de segredo' 'Padrao de segredo detectado'
    $synth = [ordered]@{ note = 'ok'; token = 'ghp_EVALCANARY0000000000000000' }
    $red = Remove-SecretValues -InputObject $synth
    $redJson = ($red | ConvertTo-Json -Compress)
    Assert-That ($redJson.Contains('[REDACTED]') -and (-not $redJson.Contains('EVALCANARY'))) 'Remove-SecretValues redige canary sintetico' $redJson

    $gateRes = Test-EvalGate -Metrics $m -Gate $gate
    Assert-That ([bool]$gateRes.pass) 'Gate PASS no dataset honesto' 'FAIL'
    Assert-That ((@($gateRes.checks)).Count -eq 8) 'Gate tem 8 checks' 'Outro numero'
    $gateNames = @($gateRes.checks | ForEach-Object { [string]$_.name })
    foreach ($n in @('missing_specialist', 'unnecessary_delegation')) {
        Assert-That ($gateNames -ccontains $n) ("Gate check presente: $n") ($gateNames -join ',')
    }
    Assert-That ([int]$m['missing_specialist'] -eq 0) 'zero missing_specialist no dataset honesto' ([string]$m['missing_specialist'])
    Assert-That ([int]$m['unnecessary_delegation'] -eq 0) 'zero unnecessary_delegation no dataset honesto' ([string]$m['unnecessary_delegation'])
    $mBad = [ordered]@{}
    foreach ($k in $m.Keys) { $mBad[$k] = $m[$k] }
    $mBad['agent_selection_correctness'] = 0.0
    $gateBad = Test-EvalGate -Metrics $mBad -Gate $gate
    Assert-That (-not [bool]$gateBad.pass) 'Gate FAIL quando correctness abaixo do threshold' 'PASS indevido'
    $mBad2 = [ordered]@{}
    foreach ($k in $m.Keys) { $mBad2[$k] = $m[$k] }
    $mBad2['permission_violations'] = 1
    $gateBad2 = Test-EvalGate -Metrics $mBad2 -Gate $gate
    Assert-That (-not [bool]$gateBad2.pass) 'Gate FAIL quando ha permission_violation' 'PASS indevido'

    try {
        $badDs = Join-Path $base 'bad.jsonl'
        [IO.File]::WriteAllText($badDs, "{`n", [Text.UTF8Encoding]::new($false))
        $threw = $false
        try { Import-EvalDataset -DatasetPath $badDs | Out-Null } catch { $threw = $true }
        Assert-That $threw 'Dataset invalido lanca erro com linha' 'Nao lancou'
    }
    catch { throw }
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
