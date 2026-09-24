$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$sample = Join-Path $v3 'shadow-sample.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-shadowsample-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Get-StabilityProjection {
    param($Doc)
    $rows = @($Doc.results | Sort-Object { [string]$_.task_id } | ForEach-Object {
        $pa = $null
        try { if ($null -ne $_.proposed_agent -and -not [string]::IsNullOrWhiteSpace([string]$_.proposed_agent)) { $pa = [string]$_.proposed_agent } } catch { $pa = $null }
        $paKey = '<null>'
        if ($null -ne $pa) { $paKey = [string]$pa }
        ([string]$_.task_id + '|' + [string]$_.status + '|' + $paKey + '|' + [string]$_.comparison + '|' + ([bool]$_.fallback_used).ToString() + '|' + ([bool]$_.degraded).ToString())
    })
    return $rows
}

try {
    Assert-That (Test-Path -LiteralPath $sample -PathType Leaf) 'Sample file exists' "Missing $sample"

    $sampleText = [IO.File]::ReadAllText($sample, [Text.UTF8Encoding]::new($false))
    $requiredCats = @('trivial-direct', 'ambiguous-requirements', 'architecture', 'engineering-feasibility', 'product-ux', 'skeptic-high-risk-plan', 'frontend', 'backend', 'database', 'research', 'security-sensitive', 'debugging', 'mixed-domain', 'fallback-degraded')
    $missingCats = @()
    foreach ($c in $requiredCats) {
        if (-not $sampleText.Contains($c)) { $missingCats += $c }
    }
    Assert-That ($missingCats.Count -eq 0) 'Sample cobre as 14 categorias controladas' ('Ausentes: ' + ($missingCats -join ','))
    Assert-That ($sampleText.Contains('no-baseline')) 'Sample inclui caso sem baseline (NOT_COMPARABLE)' 'Ausente'
    Assert-That ($sampleText.Contains('evidence\v3\shadow')) 'Sample confina report em evidence/v3/shadow' 'Ausente'
    Assert-That ($sampleText.Contains('cache\v3\telemetry')) 'Sample usa telemetria em cache/v3/telemetry' 'Ausente'
    Assert-That (-not $sampleText.Contains('Start-Job')) 'Sample nao usa Start-Job' 'Achou'
    Assert-That ($sampleText.Contains('stale')) 'Sample exercita registry stale no caso degradado' 'Ausente'
    Assert-That ($sampleText.Contains('[int]$TimeoutSeconds = 20')) 'Sample usa o mesmo timeout da bridge (20s) por caso' 'Outro default'

    $flagsFile = Join-Path $repo 'source\registry\capability-flags.json'
    $policyFile = Join-Path $repo 'source\registry\capability-policy.json'
    $adapterFile = Join-Path $repo 'source\adapters\opencode.md'
    $liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    $snapBefore = @{}
    foreach ($p in @($flagsFile, $policyFile, $adapterFile, $liveConfig)) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $snapBefore[$p] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
        else { $snapBefore[$p] = 'MISSING' }
    }

    $report = Join-Path $repo 'evidence\v3\shadow\tmp-sample-test-report.json'
    $telemetry = Join-Path $repo 'cache\v3\telemetry\tmp-sample-test-tel.jsonl'
    # Amostra e OFFLINE/advisory: com os flags distribuidos safe-by-default
    # (shadow=false) ela desabilita tudo por desenho. O teste opta pelo shadow
    # via -FlagsPath fixture (shadow=true, sem skill/mcp) e allowlist fixture
    # (19 IDs + *=deny) para metricas deterministicas em qualquer maquina.
    $sampleFlags = Join-Path $base 'sample-flags.json'
    Write-Fixture -Path $sampleFlags -Text '{"version":1,"capability_registry":{"enabled":true},"capability_reconciler":{"enabled":false},"capability_router":{"shadow":true,"active":false},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false},"routing_telemetry":{"enabled":false,"retention_days":30},"adaptive_ranking":{"enabled":false}}'
    $sampleConfig = Join-Path $base 'sample-config.json'
    $sampleTask = [ordered]@{}
    foreach ($n in @('ai-agent-engineer', 'architect', 'automation-engineer', 'backend-engineer', 'coder', 'database-engineer', 'debugger', 'docs-manager', 'engineering-advisor', 'explorer', 'frontend-engineer', 'infra-engineer', 'product-designer', 'requirements-analyst', 'researcher', 'reviewer', 'security-reviewer', 'skeptic', 'tester')) { $sampleTask[$n] = 'allow' }
    $sampleTask['*'] = 'deny'
    Write-Fixture -Path $sampleConfig -Text ((([ordered]@{ agent = [ordered]@{ build = [ordered]@{ permission = [ordered]@{ task = $sampleTask } } } } | ConvertTo-Json -Depth 10) + "`n"))
    if (Test-Path -LiteralPath $report -PathType Leaf) { Remove-Item -LiteralPath $report -Force }
    if (Test-Path -LiteralPath $telemetry -PathType Leaf) { Remove-Item -LiteralPath $telemetry -Force }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -ReportPath $report -TelemetryPath $telemetry -FlagsPath $sampleFlags -ConfigPath $sampleConfig | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($code -eq 0) 'Sample roda offline com exit 0' ("Exit $code")
    Assert-That (Test-Path -LiteralPath $report -PathType Leaf) 'Sample escreve report.json' "Missing $report"

    $doc = $null
    try { $doc = ([IO.File]::ReadAllText($report, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) } catch { $doc = $null }
    Assert-That ($null -ne $doc) 'Report e JSON valido' 'Parse falhou'
    if ($null -ne $doc) {
        Assert-That ($doc.offline -eq $true) 'Report marca offline=true' 'Ausente'
        Assert-That ((@($doc.results)).Count -ge 14) 'Report tem >= 14 casos' ("Got $((@($doc.results)).Count)")
        $cats = @($doc.results | ForEach-Object { [string]$_.category })
        $missingInReport = @()
        foreach ($c in $requiredCats) {
            if ($cats -cnotcontains $c) { $missingInReport += $c }
        }
        Assert-That ($missingInReport.Count -eq 0) 'Report contem as 14 categorias' ('Ausentes: ' + ($missingInReport -join ','))
        Assert-That ($null -ne $doc.metrics) 'Report tem metrics' 'Ausente'
        foreach ($m in @('shadow_queries_total', 'shadow_success', 'shadow_failure', 'shadow_timeout', 'shadow_degraded', 'equal', 'v3_better', 'v3_worse', 'unclear', 'not_comparable', 'no_delegation_rate', 'router_latency_p50', 'router_latency_p95', 'fallback_success', 'permission_violations', 'authority_changes')) {
            $has = $false
            try {
                if ($doc.metrics -is [System.Collections.IDictionary]) { $has = $doc.metrics.Contains($m) }
                else { $has = ($null -ne ($doc.metrics.PSObject.Properties | Where-Object { $_.Name -ceq $m } | Select-Object -First 1)) }
            }
            catch { $has = $false }
            Assert-That $has ("Metrica presente: $m") 'Ausente'
        }
        $sum = [int]$doc.metrics.equal + [int]$doc.metrics.v3_better + [int]$doc.metrics.v3_worse + [int]$doc.metrics.unclear + [int]$doc.metrics.not_comparable
        Assert-That ($sum -eq [int]$doc.metrics.shadow_queries_total) 'Soma de comparisons bate com total' ("Sum $sum total $($doc.metrics.shadow_queries_total)")
        Assert-That ([int]$doc.metrics.authority_changes -eq 0) 'authority_changes = 0 (sem ativacao)' ([string]$doc.metrics.authority_changes)
        Assert-That ([int]$doc.metrics.permission_violations -eq 0) 'permission_violations = 0' ([string]$doc.metrics.permission_violations)
        Assert-That ([int]$doc.metrics.shadow_timeout -eq 0) 'Sample: timeout = 0 (isolado completa no budget)' ([string]$doc.metrics.shadow_timeout)
        Assert-That ([int]$doc.metrics.shadow_degraded -ge 1) 'Sample: degraded >= 1 (caso fallback-degraded real)' ([string]$doc.metrics.shadow_degraded)
        Assert-That ([int]$doc.metrics.shadow_success -ge 13) 'Sample: success alto (>= 13/15)' ([string]$doc.metrics.shadow_success)
        $degCase = @($doc.results | Where-Object { [string]$_.category -ceq 'fallback-degraded' } | Select-Object -First 1)
        $degOk = $false
        $degDetail = 'ausente'
        if ($degCase.Count -gt 0) {
            $d = $degCase[0]
            $degDetail = ('status=' + [string]$d.status + ' fb=' + [string]$d.fallback_used + ' cmp=' + [string]$d.comparison)
            if ((([string]$d.status -ceq 'degraded') -or ([string]$d.status -ceq 'failed')) -and ([bool]$d.fallback_used) -and ([string]$d.comparison -ceq 'NOT_COMPARABLE')) { $degOk = $true }
        }
        Assert-That $degOk 'Caso degradado real: stale => degraded/failed + fallback + NOT_COMPARABLE' $degDetail
        $degNullOk = $false
        $degNullDetail = 'ausente'
        if ($degCase.Count -gt 0) {
            $d = $degCase[0]
            $hasProp = $false
            try {
                if ($d -is [System.Collections.IDictionary]) { $hasProp = $d.Contains('proposed_agent') }
                else { $hasProp = ($null -ne ($d.PSObject.Properties | Where-Object { $_.Name -ceq 'proposed_agent' } | Select-Object -First 1)) }
            }
            catch { $hasProp = $false }
            $pv = $null
            try {
                if ($d -is [System.Collections.IDictionary]) { $pv = $d['proposed_agent'] }
                else { $pv = $d.proposed_agent }
            }
            catch { $pv = 'ERR' }
            $degNullDetail = ('hasProp=' + [string]$hasProp + ' isNull=' + ([string]($null -eq $pv)))
            if ($hasProp -and ($null -eq $pv)) { $degNullOk = $true }
        }
        Assert-That $degNullOk 'SHADOW-014: proposed_agent preservado como null (nao string vazia)' $degNullDetail
        Assert-That ([int]$doc.metrics.fallback_used -eq 1) 'Sample: fallback_used = 1 (caso degradado)' ([string]$doc.metrics.fallback_used)
        Assert-That ([double]$doc.metrics.fallback_success -eq 1.0) 'Sample: fallback_success = 1.0 (fallback seguro = 100%, Sec 28)' ([string]$doc.metrics.fallback_success)
        $reqAudit = @('id', 'status', 'fallback_used', 'comparison', 'proposed_agent', 'degraded')
        $missingAudit = @()
        $degAuditOk = $false
        foreach ($r in @($doc.results)) {
            $rnames = @($r.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($f in $reqAudit) {
                if ($rnames -cnotcontains $f) { $missingAudit += ([string]$r.task_id + ':' + $f) }
            }
            if (([string]$r.category -ceq 'fallback-degraded') -and ([string]$r.id -ceq [string]$r.task_id) -and ([bool]$r.degraded) -and ([bool]$r.fallback_used)) { $degAuditOk = $true }
        }
        Assert-That ($missingAudit.Count -eq 0) 'Report por caso e auditavel (id/status/fallback_used/comparison/proposed_agent/degraded)' ($missingAudit -join ',')
        Assert-That $degAuditOk 'Caso degradado auditavel: id=task_id + degraded=true + fallback_used=true' 'Ausente'
        $usedN = @(@($doc.results) | Where-Object { [bool]$_.fallback_used }).Count
        $safeN = @(@($doc.results) | Where-Object { ([bool]$_.fallback_used) -and (@('degraded', 'failed', 'timeout') -ccontains [string]$_.status) }).Count
        $rateN = 1.0
        if ($usedN -gt 0) { $rateN = [Math]::Round(([double]$safeN / [double]$usedN), 4) }
        Assert-That ($rateN -eq [double]$doc.metrics.fallback_success) 'fallback_success confere com fracao de fallbacks seguros' ("metric=$($doc.metrics.fallback_success) recomputed=$rateN")
        $ratePlus = [Math]::Round(([double]($safeN + 1) / [double]($usedN + 1)), 4)
        Assert-That ($ratePlus -eq 1.0) 'Fallback seguro adicional mantem 100%' ([string]$ratePlus)
    }

    $reportText = ''
    if (Test-Path -LiteralPath $report -PathType Leaf) { $reportText = [IO.File]::ReadAllText($report, [Text.UTF8Encoding]::new($false)) }
    Assert-That (-not $reportText.Contains('EVALCANARY')) 'Report sem marcador de poisoning' 'Vazou'
    Assert-That (-not $reportText.Contains('Bearer ')) 'Report sem segredo' 'Vazou'

    $drift = $false
    foreach ($p in @($flagsFile, $policyFile, $adapterFile, $liveConfig)) {
        $h = 'MISSING'
        if (Test-Path -LiteralPath $p -PathType Leaf) { $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
        if ($h -cne $snapBefore[$p]) { $drift = $true }
    }
    Assert-That (-not $drift) 'Sample nao altera flags/policy/adapter/opencode.json' 'Drift detectado'

    $outsideReport = Join-Path $base 'outside-report.json'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -ReportPath $outsideReport -TelemetryPath $telemetry 2>$null | Out-Null
    $codeOutside = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($codeOutside -eq 2) 'Confinamento: -ReportPath fora do dir recusa com exit 2' ("Exit $codeOutside")
    Assert-That (-not (Test-Path -LiteralPath $outsideReport -PathType Leaf)) 'Confinamento: nada escrito fora do dir' 'Arquivo criado'

    $outsideCanonical = Join-Path $base 'outside-canonical.json'
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -CanonicalPath $outsideCanonical 2>$null | Out-Null
    $codeCanon = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($codeCanon -eq 2) 'Confinamento: -CanonicalPath fora do dir recusa com exit 2' ("Exit $codeCanon")
    Assert-That (-not (Test-Path -LiteralPath $outsideCanonical -PathType Leaf)) 'Confinamento: -CanonicalPath fora do dir nada escreve' 'Arquivo criado'

    $shadowAllowed = Join-Path $repo 'evidence\v3\shadow'
    $telAllowed = Join-Path $repo 'cache\v3\telemetry'
    $junctionTarget = Join-Path $base 'junction-outside'
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionLink = Join-Path $shadowAllowed ('tmp-junction-' + [guid]::NewGuid().ToString('N'))
    $telJunctionLink = Join-Path $telAllowed ('tmp-junction-' + [guid]::NewGuid().ToString('N'))
    $junctionOk = $true
    try { New-Item -ItemType Junction -Path $junctionLink -Target $junctionTarget -ErrorAction Stop | Out-Null } catch { $junctionOk = $false }
    $telJunctionOk = $true
    if ($junctionOk) {
        try { New-Item -ItemType Junction -Path $telJunctionLink -Target $junctionTarget -ErrorAction Stop | Out-Null } catch { $telJunctionOk = $false }
    }
    if ($junctionOk) {
        $viaReport = Join-Path $junctionLink 'via-report.json'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & powershell -NoProfile -File $sample -ReportPath $viaReport -TelemetryPath $telemetry 2>$null | Out-Null
        $codeViaReport = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Assert-That ($codeViaReport -eq 2) 'Reparse: -ReportPath via junction recusa com exit 2' ("Exit $codeViaReport")
        Assert-That (-not (Test-Path -LiteralPath $viaReport -PathType Leaf)) 'Reparse: -ReportPath via junction nada escreve' 'Arquivo criado'
        $leaked = @(Get-ChildItem -LiteralPath $junctionTarget -Force -ErrorAction SilentlyContinue)
        Assert-That ($leaked.Count -eq 0) 'Reparse: nada vaza para o alvo da junction (report)' ($leaked.Count)
        $viaCanon = Join-Path $junctionLink 'via-canonical.json'
        $canonRep = Join-Path $repo 'evidence\v3\shadow\tmp-sample-junction-report.json'
        if (Test-Path -LiteralPath $canonRep -PathType Leaf) { Remove-Item -LiteralPath $canonRep -Force }
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & powershell -NoProfile -File $sample -CanonicalPath $viaCanon -ReportPath $canonRep -TelemetryPath $telemetry 2>$null | Out-Null
        $codeViaCanon = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        Assert-That ($codeViaCanon -eq 2) 'Reparse: -CanonicalPath via junction recusa com exit 2' ("Exit $codeViaCanon")
        Assert-That (-not (Test-Path -LiteralPath $viaCanon -PathType Leaf)) 'Reparse: -CanonicalPath via junction nada escreve' 'Arquivo criado'
        Assert-That (-not (Test-Path -LiteralPath $canonRep -PathType Leaf)) 'Reparse: report nao escrito quando canonical bloqueia' 'Arquivo criado'
        if ($telJunctionOk) {
            $viaTel = Join-Path $telJunctionLink 'via-tel.jsonl'
            $telRep = Join-Path $repo 'evidence\v3\shadow\tmp-sample-junction-tel-report.json'
            if (Test-Path -LiteralPath $telRep -PathType Leaf) { Remove-Item -LiteralPath $telRep -Force }
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & powershell -NoProfile -File $sample -ReportPath $telRep -TelemetryPath $viaTel 2>$null | Out-Null
            $codeViaTel = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            Assert-That ($codeViaTel -eq 2) 'Reparse: -TelemetryPath via junction recusa com exit 2' ("Exit $codeViaTel")
            Assert-That (-not (Test-Path -LiteralPath $viaTel -PathType Leaf)) 'Reparse: -TelemetryPath via junction nada escreve' 'Arquivo criado'
            Assert-That (-not (Test-Path -LiteralPath $telRep -PathType Leaf)) 'Reparse: report nao escrito quando telemetry bloqueia' 'Arquivo criado'
            if (Test-Path -LiteralPath $telRep -PathType Leaf) { Remove-Item -LiteralPath $telRep -Force -ErrorAction SilentlyContinue }
        } else {
            Write-Host '[WARN] Junction de telemetria indisponivel; skip do caso -TelemetryPath via junction'
            Assert-That ($true) 'Reparse: -TelemetryPath via junction (skip sem privilegio)' 'skip'
        }
        if (Test-Path -LiteralPath $canonRep -PathType Leaf) { Remove-Item -LiteralPath $canonRep -Force -ErrorAction SilentlyContinue }
    } else {
        Write-Host '[WARN] Junction indisponivel neste ambiente; skip dos casos reparse (report/canonical/telemetry)'
        Assert-That ($true) 'Reparse: -ReportPath via junction (skip sem privilegio)' 'skip'
        Assert-That ($true) 'Reparse: -CanonicalPath via junction (skip sem privilegio)' 'skip'
        Assert-That ($true) 'Reparse: -TelemetryPath via junction (skip sem privilegio)' 'skip'
    }
    if (Test-Path -LiteralPath $junctionLink) { Remove-Item -LiteralPath $junctionLink -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $telJunctionLink) { Remove-Item -LiteralPath $telJunctionLink -Force -ErrorAction SilentlyContinue }

    $insideCanonical = Join-Path $repo 'evidence\v3\shadow\tmp-sample-canonical.json'
    $insideCanonReport = Join-Path $repo 'evidence\v3\shadow\tmp-sample-canonical-report.json'
    foreach ($tmpf in @($insideCanonical, $insideCanonReport)) { if (Test-Path -LiteralPath $tmpf -PathType Leaf) { Remove-Item -LiteralPath $tmpf -Force } }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -CanonicalPath $insideCanonical -ReportPath $insideCanonReport -TelemetryPath $telemetry -FlagsPath $sampleFlags -ConfigPath $sampleConfig 2>$null | Out-Null
    $codeCanonOk = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($codeCanonOk -eq 0) 'Confinamento: -CanonicalPath dentro do dir aceita (exit 0)' ("Exit $codeCanonOk")
    Assert-That (Test-Path -LiteralPath $insideCanonical -PathType Leaf) 'Confinamento: -CanonicalPath dentro do dir escreve projecao' 'Arquivo ausente'
    foreach ($tmpf in @($insideCanonical, $insideCanonReport)) { if (Test-Path -LiteralPath $tmpf -PathType Leaf) { Remove-Item -LiteralPath $tmpf -Force } }

    $activeFlags = Join-Path $base 'active-flags.json'
    Write-Fixture -Path $activeFlags -Text '{"capability_router":{"shadow":true,"active":true},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false}}'
    $guardReport = Join-Path $repo 'evidence\v3\shadow\tmp-sample-guard-report.json'
    if (Test-Path -LiteralPath $guardReport -PathType Leaf) { Remove-Item -LiteralPath $guardReport -Force }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -ReportPath $guardReport -TelemetryPath $telemetry -FlagsPath $activeFlags 2>$null | Out-Null
    $codeGuard = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($codeGuard -eq 0) 'Guard: router_active sozinho e permitido (exit 0; shadow continua)' ("Exit $codeGuard")
    # skill_routing.enabled=true (sem executor) recusa exit 2.
    $skillGuardFlags = Join-Path $base 'skill-guard-flags.json'
    Write-Fixture -Path $skillGuardFlags -Text '{"capability_router":{"shadow":true,"active":false},"skill_routing":{"enabled":true},"mcp_routing":{"enabled":false}}'
    $skillGuardReport = Join-Path $repo 'evidence\v3\shadow\tmp-sample-skillguard-report.json'
    if (Test-Path -LiteralPath $skillGuardReport -PathType Leaf) { Remove-Item -LiteralPath $skillGuardReport -Force }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -ReportPath $skillGuardReport -TelemetryPath $telemetry -FlagsPath $skillGuardFlags 2>$null | Out-Null
    $codeSkillGuard = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That ($codeSkillGuard -eq 2) 'Guard: skill_routing.enabled recusa com exit 2' ("Exit $codeSkillGuard")
    Assert-That (-not (Test-Path -LiteralPath $skillGuardReport -PathType Leaf)) 'Guard: nada escrito quando recusa skill' 'Report criado'
    foreach ($tmpf in @($guardReport, $skillGuardReport, $skillGuardFlags)) { if (Test-Path -LiteralPath $tmpf -PathType Leaf) { Remove-Item -LiteralPath $tmpf -Force -ErrorAction SilentlyContinue } }

    $repA = Join-Path $repo 'evidence\v3\shadow\tmp-sample-stability-A.json'
    $repB = Join-Path $repo 'evidence\v3\shadow\tmp-sample-stability-B.json'
    $telA = Join-Path $repo 'cache\v3\telemetry\tmp-sample-stability-A.jsonl'
    $telB = Join-Path $repo 'cache\v3\telemetry\tmp-sample-stability-B.jsonl'
    $stabilityFile = Join-Path $repo 'evidence\v3\shadow\stability.json'
    foreach ($tmp in @($repA, $repB, $telA, $telB)) {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force }
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -File $sample -ReportPath $repA -TelemetryPath $telA -FlagsPath $sampleFlags -ConfigPath $sampleConfig | Out-Null
    $codeA = $LASTEXITCODE
    & powershell -NoProfile -File $sample -ReportPath $repB -TelemetryPath $telB -FlagsPath $sampleFlags -ConfigPath $sampleConfig | Out-Null
    $codeB = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    Assert-That (($codeA -eq 0) -and ($codeB -eq 0)) 'Determinismo: amostra roda 2x com exit 0' ("A=$codeA B=$codeB")
    $docA = $null
    $docB = $null
    try { $docA = ([IO.File]::ReadAllText($repA, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) } catch { $docA = $null }
    try { $docB = ([IO.File]::ReadAllText($repB, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) } catch { $docB = $null }
    Assert-That (($null -ne $docA) -and ($null -ne $docB)) 'Determinismo: ambos os reports sao JSON valido' 'Parse falhou'
    if (($null -ne $docA) -and ($null -ne $docB)) {
        $projA = @(Get-StabilityProjection -Doc $docA)
        $projB = @(Get-StabilityProjection -Doc $docB)
        $diff = @(Compare-Object -ReferenceObject $projA -DifferenceObject $projB)
        $match = ($diff.Count -eq 0) -and ($projA.Count -eq $projB.Count) -and ($projA.Count -ge 14)
        Assert-That $match 'Determinismo: projecao canonica identica nas 2 runs (id/status/proposed_agent/comparison/fallback_used/degraded)' ('diff=' + $diff.Count + ' nA=' + $projA.Count + ' nB=' + $projB.Count)
        $canonA = @($docA.results | Sort-Object { [string]$_.task_id } | ForEach-Object {
            $pa = $null
            try { if ($null -ne $_.proposed_agent -and -not [string]::IsNullOrWhiteSpace([string]$_.proposed_agent)) { $pa = [string]$_.proposed_agent } } catch { $pa = $null }
            [ordered]@{ id = [string]$_.task_id; status = [string]$_.status; proposed_agent = $pa; comparison = [string]$_.comparison; fallback_used = [bool]$_.fallback_used; degraded = [bool]$_.degraded }
        })
        $canonB = @($docB.results | Sort-Object { [string]$_.task_id } | ForEach-Object {
            $pa = $null
            try { if ($null -ne $_.proposed_agent -and -not [string]::IsNullOrWhiteSpace([string]$_.proposed_agent)) { $pa = [string]$_.proposed_agent } } catch { $pa = $null }
            [ordered]@{ id = [string]$_.task_id; status = [string]$_.status; proposed_agent = $pa; comparison = [string]$_.comparison; fallback_used = [bool]$_.fallback_used; degraded = [bool]$_.degraded }
        })
        $stabDoc = [ordered]@{ generated_at = ([DateTimeOffset]::UtcNow.ToString('o')); match = [bool]$match; runs = [int]2; projection_a = @($canonA); projection_b = @($canonB) }
        $stabJson = ((($stabDoc | ConvertTo-Json -Depth 10) + "`n") -replace "`r`n", "`n" -replace "`r", "`n")
        $stabParent = Split-Path -Parent $stabilityFile
        New-Item -ItemType Directory -Path $stabParent -Force | Out-Null
        [IO.File]::WriteAllText($stabilityFile, $stabJson, [Text.UTF8Encoding]::new($false))
        Assert-That ([bool]$match) 'Determinismo: stability.json registra match=true' ([string]$match)
        Assert-That (Test-Path -LiteralPath $stabilityFile -PathType Leaf) 'Determinismo: stability.json escrito em evidence/v3/shadow' "Missing $stabilityFile"
        $noLat = $true
        try {
            $st = [IO.File]::ReadAllText($stabilityFile, [Text.UTF8Encoding]::new($false))
            if ($st.Contains('router_latency_ms') -or $st.Contains('router_latency_p50')) { $noLat = $false }
        }
        catch { $noLat = $false }
        Assert-That $noLat 'Determinismo: projecao canonica exclui latencias' 'Vazou latencia'
    }
}
finally {
    foreach ($tmp in @($report, $telemetry, $guardReport, $repA, $repB, $telA, $telB)) {
        if ((-not [string]::IsNullOrWhiteSpace($tmp)) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
