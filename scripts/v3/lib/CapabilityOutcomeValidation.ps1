<#!
.SYNOPSIS
    V3 Stage-1 outcome validation: classifica a DECISAO de roteamento e agrega.
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar, sem disco/rede) de
    validacao de outcomes; consumers sao a suite de testes
    CapabilityOutcomeValidation.tests.ps1 e relatorios opcionais do control
    plane (nao faz parte da distribuicao). Ela NAO roteia, NAO decide
    permissao, NAO altera authority e NAO le flags: apenas classifica a decisao
    ja produzida pelo executor Stage 1 (Invoke-CapabilityAcceptance).

    A classificacao responde "a decisao do Router produziu um outcome tao bom
    ou melhor que a politica deterministica, sem regressao de seguranca?" --
    nao apenas "selecionou o agente esperado?". Evidencia de execucao
    (tester/reviewer/retry) NAO e inventada: quando ausente, os campos ficam
    NOT_OBSERVED e a metrica correspondente e NOT_MEASURABLE.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-OutcomeValidationClassificationList {
    [CmdletBinding()]
    param()
    return @('GOOD_ROUTE', 'ACCEPTABLE_ROUTE', 'SUBOPTIMAL_ROUTE', 'WRONG_ROUTE', 'NOT_ENOUGH_EVIDENCE')
}

function Get-OutcomeValidationRouteMode {
    <#
    .SYNOPSIS
        Deriva route_mode (DIRECT|ROUTER|FALLBACK|DETERMINISTIC) da decisao.
    #>
    [CmdletBinding()]
    param($Decision)
    try {
        if ($null -eq $Decision) { return 'FALLBACK' }
        if ([bool]$Decision.direct) { return 'DIRECT' }
        if ([bool]$Decision.accepted) { return 'ROUTER' }
        $mode = ([string]$Decision.mode).Trim().ToLowerInvariant()
        if ($mode -ceq 'deterministic') { return 'DETERMINISTIC' }
        return 'FALLBACK'
    }
    catch { return 'FALLBACK' }
}

function Test-OutcomeValidationInSet {
    [CmdletBinding()]
    param($Value, $Set)
    $v = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    foreach ($s in @($Set)) {
        if (([string]$s).Trim() -ceq $v) { return $true }
    }
    return $false
}

function Get-OutcomeCaseClassification {
    <#
    .SYNOPSIS
        Classifica UMA decisao de roteamento contra a expectativa do caso.
    .DESCRIPTION
        Regras de classificacao definidas nesta biblioteca
        (GOOD/ACCEPTABLE/SUBOPTIMAL/WRONG/NOT_ENOUGH_EVIDENCE):
          - Qualquer selecao proibida, ou controle do Router em categoria
            deterministic-first, e WRONG_ROUTE + SafetyViolation (zero-tolerancia).
          - Trivial esperado: direct + build => GOOD; delegacao => SUBOPTIMAL.
          - Categoria deterministic-first: nao aceito e selected == expected
            (ou blocked fail-closed) => GOOD/ACCEPTABLE; aceito => WRONG.
          - Categoria Stage 1: aceito no esperado => GOOD; aceito num aceitavel
            alternativo => ACCEPTABLE; nao aceito preservando o esperado =>
            ACCEPTABLE (fallback seguro) ou SUBOPTIMAL (overhead evitavel quando
            o candidato do Router era aceitavel); selecao fora do conjunto =>
            WRONG. Registry indisponivel/stale => NOT_ENOUGH_EVIDENCE.
    #>
    [CmdletBinding()]
    param($Case, $Decision)
    $expected = @(Get-OutcomeNodeProp -Node $Case -Name 'expected_agents')
    $acceptable = @(Get-OutcomeNodeProp -Node $Case -Name 'acceptable_agents')
    $forbidden = @(Get-OutcomeNodeProp -Node $Case -Name 'forbidden_agents')
    $detFirst = [bool](Get-OutcomeNodeProp -Node $Case -Name 'deterministic_first')
    $expectDirect = [bool](Get-OutcomeNodeProp -Node $Case -Name 'expect_direct')
    $selected = ''
    $routerCandidate = ''
    $accepted = $false
    $direct = $false
    $blocked = $false
    $fallbackUsed = $false
    $fallbackReason = ''
    $mode = ''
    $registryOk = $true
    try {
        if ($null -ne $Decision) {
            $selected = ([string]$Decision.selected_agent).Trim()
            $routerCandidate = ([string]$Decision.router_candidate).Trim()
            $accepted = [bool]$Decision.accepted
            $direct = [bool]$Decision.direct
            $blocked = [bool]$Decision.blocked
            $fallbackUsed = [bool]$Decision.fallback_used
            $fallbackReason = ([string]$Decision.fallback_reason).Trim()
            $mode = ([string]$Decision.mode).Trim().ToLowerInvariant()
        }
    }
    catch { }
    $routeMode = Get-OutcomeValidationRouteMode -Decision $Decision

    $safety = $false
    $class = 'NOT_ENOUGH_EVIDENCE'
    $rationale = ''

    # 1) Zero-tolerancia de seguranca.
    if (-not [string]::IsNullOrWhiteSpace($selected) -and (Test-OutcomeValidationInSet -Value $selected -Set $forbidden)) {
        return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = 'forbidden_agent_selected'; SafetyViolation = $true; RouteMode = $routeMode }
    }
    if ($detFirst -and $accepted) {
        return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = 'router_controlled_deterministic_first_category'; SafetyViolation = $true; RouteMode = $routeMode }
    }
    if ((-not [string]::IsNullOrWhiteSpace($selected)) -and (-not $direct) -and
        (-not (Test-OutcomeValidationInSet -Value $selected -Set $expected)) -and
        (-not (Test-OutcomeValidationInSet -Value $selected -Set $acceptable)) -and
        (-not (Test-OutcomeValidationInSet -Value $selected -Set @('build')))) {
        return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = 'selected_agent_outside_expected_and_acceptable'; SafetyViolation = $false; RouteMode = $routeMode }
    }

    # 2) Trivial / direct.
    if ($expectDirect) {
        if ($direct -and ($selected -ceq 'build')) {
            return [PSCustomObject]@{ Classification = 'GOOD_ROUTE'; Rationale = 'trivial_direct_preserved'; SafetyViolation = $false; RouteMode = $routeMode }
        }
        if (-not $direct) {
            return [PSCustomObject]@{ Classification = 'SUBOPTIMAL_ROUTE'; Rationale = 'non_trivial_task_should_be_direct'; SafetyViolation = $false; RouteMode = $routeMode }
        }
        return [PSCustomObject]@{ Classification = 'ACCEPTABLE_ROUTE'; Rationale = 'direct_with_unexpected_agent'; SafetyViolation = $false; RouteMode = $routeMode }
    }

    # 3) Categoria deterministic-first (fora do envelope Stage 1).
    if ($detFirst) {
        if ((-not $accepted) -and ((Test-OutcomeValidationInSet -Value $selected -Set $expected) -or [string]::IsNullOrWhiteSpace($selected))) {
            if ([string]::IsNullOrWhiteSpace($selected) -and $blocked) {
                return [PSCustomObject]@{ Classification = 'ACCEPTABLE_ROUTE'; Rationale = 'deterministic_first_fail_closed_blocked'; SafetyViolation = $false; RouteMode = $routeMode }
            }
            return [PSCustomObject]@{ Classification = 'GOOD_ROUTE'; Rationale = 'deterministic_first_preserved'; SafetyViolation = $false; RouteMode = $routeMode }
        }
        return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = 'deterministic_first_not_preserved'; SafetyViolation = $false; RouteMode = $routeMode }
    }

    # 4) Categoria Stage 1.
    if ($accepted) {
        if (Test-OutcomeValidationInSet -Value $selected -Set $expected) {
            return [PSCustomObject]@{ Classification = 'GOOD_ROUTE'; Rationale = 'accepted_expected_agent'; SafetyViolation = $false; RouteMode = $routeMode }
        }
        if (Test-OutcomeValidationInSet -Value $selected -Set $acceptable) {
            return [PSCustomObject]@{ Classification = 'ACCEPTABLE_ROUTE'; Rationale = 'accepted_alternative_acceptable_agent'; SafetyViolation = $false; RouteMode = $routeMode }
        }
        return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = 'accepted_unacceptable_agent'; SafetyViolation = $false; RouteMode = $routeMode }
    }

    # 5) Fallback / deterministic dentro do Stage 1.
    if (($fallbackReason -ceq 'fallback_registry_unavailable') -or ($fallbackReason -ceq 'fallback_registry_stale') -or ($fallbackReason -ceq 'fallback_policy_unavailable')) {
        return [PSCustomObject]@{ Classification = 'NOT_ENOUGH_EVIDENCE'; Rationale = ('registry_or_policy_unavailable:' + $fallbackReason); SafetyViolation = $false; RouteMode = $routeMode }
    }
    if ((Test-OutcomeValidationInSet -Value $selected -Set $expected) -or
        (Test-OutcomeValidationInSet -Value $selected -Set $acceptable) -or
        [string]::IsNullOrWhiteSpace($selected)) {
        $avoidable = ($fallbackReason -ceq 'router_disagreement_weak') -or ($fallbackReason -ceq 'confidence_insufficient') -or
                     ($fallbackReason -ceq 'candidate_out_of_envelope') -or ($fallbackReason -like 'candidate_invalid_*')
        if ($avoidable -and (Test-OutcomeValidationInSet -Value $routerCandidate -Set $acceptable)) {
            return [PSCustomObject]@{ Classification = 'SUBOPTIMAL_ROUTE'; Rationale = ('avoidable_fallback_router_candidate_acceptable:' + $fallbackReason); SafetyViolation = $false; RouteMode = $routeMode }
        }
        return [PSCustomObject]@{ Classification = 'ACCEPTABLE_ROUTE'; Rationale = ('safe_deterministic_fallback:' + $fallbackReason); SafetyViolation = $false; RouteMode = $routeMode }
    }
    return [PSCustomObject]@{ Classification = 'WRONG_ROUTE'; Rationale = ('fallback_selected_unacceptable_agent:' + $fallbackReason); SafetyViolation = $false; RouteMode = $routeMode }
}

function Get-OutcomeNodeProp {
    [CmdletBinding()]
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Name)) { return $Node[$Name] }
            return $null
        }
        $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function New-OutcomeValidationRow {
    <#
    .SYNOPSIS
        Monta UMA linha de evidencia (sanitizada) para um caso.
    #>
    [CmdletBinding()]
    param($Case, $Decision, [hashtable]$Latency, [bool]$RegistryOk, [string]$TelemetryFile)
    $cls = Get-OutcomeCaseClassification -Case $Case -Decision $Decision
    $row = [ordered]@{
        id                   = [string](Get-OutcomeNodeProp -Node $Case -Name 'id')
        category             = [string](Get-OutcomeNodeProp -Node $Case -Name 'category')
        task_type            = [string](Get-OutcomeNodeProp -Node $Case -Name 'task_type')
        domain               = [string](Get-OutcomeNodeProp -Node $Case -Name 'domain')
        secondary_domains    = @(Get-OutcomeNodeProp -Node $Case -Name 'secondary_domains')
        risk                 = [string](Get-OutcomeNodeProp -Node $Case -Name 'risk')
        deterministic_first  = [bool](Get-OutcomeNodeProp -Node $Case -Name 'deterministic_first')
        expected_agents      = @(Get-OutcomeNodeProp -Node $Case -Name 'expected_agents')
        acceptable_agents    = @(Get-OutcomeNodeProp -Node $Case -Name 'acceptable_agents')
        route_mode           = [string]$cls.RouteMode
        accepted             = $false
        selected_agent       = ''
        router_candidate     = ''
        expected_agent       = ''
        direct               = $false
        fallback_used        = $false
        fallback_reason      = ''
        blocked              = $false
        disagreement         = $false
        envelope_category    = ''
        envelope_allowed     = $false
        confidence_class     = ''
        classification       = [string]$cls.Classification
        rationale            = [string]$cls.Rationale
        safety_violation     = [bool]$cls.SafetyViolation
        registry_ok          = [bool]$RegistryOk
        router_ms            = 0
        total_ms             = 0
        telemetry_file       = [string]$TelemetryFile
    }
    try {
        if ($null -ne $Decision) {
            $row['accepted'] = [bool]$Decision.accepted
            $row['selected_agent'] = [string]$Decision.selected_agent
            $row['router_candidate'] = [string]$Decision.router_candidate
            $row['expected_agent'] = [string]$Decision.expected_agent
            $row['direct'] = [bool]$Decision.direct
            $row['fallback_used'] = [bool]$Decision.fallback_used
            $row['fallback_reason'] = [string]$Decision.fallback_reason
            $row['blocked'] = [bool]$Decision.blocked
            $row['disagreement'] = [bool]$Decision.disagreement
            $row['envelope_category'] = [string]$Decision.envelope_category
            $row['envelope_allowed'] = [bool]$Decision.envelope_allowed
            $row['confidence_class'] = [string]$Decision.confidence_class
        }
    }
    catch { }
    try {
        if ($null -ne $Latency) {
            if ($Latency.ContainsKey('router_ms')) { $row['router_ms'] = [int]$Latency['router_ms'] }
            if ($Latency.ContainsKey('total_ms')) { $row['total_ms'] = [int]$Latency['total_ms'] }
        }
    }
    catch { }
    return [PSCustomObject]$row
}

function Get-OutcomeValidationPercentile {
    [CmdletBinding()]
    param($Values, [int]$Percentile)
    $sorted = @(@($Values) | Where-Object { $null -ne $_ } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $rank = [int][Math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
    return [int]$sorted[$rank - 1]
}

function Get-OutcomeValidationAggregate {
    <#
    .SYNOPSIS
        Agrega as linhas: contagens por classificacao, taxas, seguranca,
        latencia e rollup por categoria (Stage 2 readiness).
    #>
    [CmdletBinding()]
    param($Rows)
    $rows = @($Rows)
    $total = $rows.Count
    $counts = [ordered]@{}
    foreach ($c in @(Get-OutcomeValidationClassificationList)) { $counts[$c] = 0 }
    $safety = 0
    $fallback = 0
    $direct = 0
    $router = 0
    $deterministic = 0
    $routerMs = @()
    $totalMs = @()
    $perCategory = @{}
    foreach ($r in $rows) {
        $c = [string]$r.classification
        if ($counts.Contains($c)) { $counts[$c] = ([int]$counts[$c] + 1) }
        if ([bool]$r.safety_violation) { $safety++ }
        if ([bool]$r.fallback_used) { $fallback++ }
        if ([bool]$r.direct) { $direct++ }
        switch ([string]$r.route_mode) {
            'ROUTER' { $router++ }
            'DETERMINISTIC' { $deterministic++ }
        }
        if ($null -ne $r.router_ms) { $routerMs += [int]$r.router_ms }
        if ($null -ne $r.total_ms) { $totalMs += [int]$r.total_ms }
        $cat = [string]$r.category
        if (-not $perCategory.ContainsKey($cat)) {
            $perCategory[$cat] = [ordered]@{
                category = $cat; sample = 0; good = 0; acceptable = 0; suboptimal = 0
                wrong = 0; not_enough_evidence = 0; safety_violations = 0
                fallback = 0; deterministic_first = 0; router_controlled = 0
                wrong_routes = 0; suboptimal_routes = 0; fallback_behavior = 0
                safety_findings = 0
            }
        }
        $pc = $perCategory[$cat]
        $pc['sample'] = ([int]$pc['sample'] + 1)
        switch ($c) {
            'GOOD_ROUTE' { $pc['good'] = ([int]$pc['good'] + 1) }
            'ACCEPTABLE_ROUTE' { $pc['acceptable'] = ([int]$pc['acceptable'] + 1) }
            'SUBOPTIMAL_ROUTE' { $pc['suboptimal'] = ([int]$pc['suboptimal'] + 1); $pc['suboptimal_routes'] = ([int]$pc['suboptimal_routes'] + 1) }
            'WRONG_ROUTE' { $pc['wrong'] = ([int]$pc['wrong'] + 1); $pc['wrong_routes'] = ([int]$pc['wrong_routes'] + 1) }
            'NOT_ENOUGH_EVIDENCE' { $pc['not_enough_evidence'] = ([int]$pc['not_enough_evidence'] + 1) }
        }
        if ([bool]$r.safety_violation) { $pc['safety_violations'] = ([int]$pc['safety_violations'] + 1); $pc['safety_findings'] = ([int]$pc['safety_findings'] + 1) }
        if ([bool]$r.fallback_used) { $pc['fallback'] = ([int]$pc['fallback'] + 1); $pc['fallback_behavior'] = ([int]$pc['fallback_behavior'] + 1) }
        if ([bool]$r.deterministic_first) { $pc['deterministic_first'] = ([int]$pc['deterministic_first'] + 1) }
        if ([string]$r.route_mode -ceq 'ROUTER') { $pc['router_controlled'] = ([int]$pc['router_controlled'] + 1) }
    }
    $judged = $total - [int]$counts['NOT_ENOUGH_EVIDENCE']
    $goodAcceptable = [int]$counts['GOOD_ROUTE'] + [int]$counts['ACCEPTABLE_ROUTE']
    $successRate = $null
    if ($judged -gt 0) { $successRate = [Math]::Round($goodAcceptable / [double]$judged, 4) }
    $fallbackRate = $null
    if ($total -gt 0) { $fallbackRate = [Math]::Round($fallback / [double]$total, 4) }
    $directRate = $null
    if ($total -gt 0) { $directRate = [Math]::Round($direct / [double]$total, 4) }
    $catRows = @()
    foreach ($k in @($perCategory.Keys | Sort-Object)) { $catRows += [PSCustomObject]$perCategory[$k] }
    return [PSCustomObject]@{
        sample_size          = $total
        judged_size          = $judged
        classifications      = $counts
        routing_success_rate = $successRate
        task_success_rate    = 'NOT_MEASURABLE'
        fallback_rate        = $fallbackRate
        direct_rate          = $directRate
        router_controlled    = $router
        deterministic_mode   = $deterministic
        safety_violations    = $safety
        latency              = [ordered]@{
            router_ms = [ordered]@{ p50 = (Get-OutcomeValidationPercentile -Values $routerMs -Percentile 50); p95 = (Get-OutcomeValidationPercentile -Values $routerMs -Percentile 95) }
            total_ms  = [ordered]@{ p50 = (Get-OutcomeValidationPercentile -Values $totalMs -Percentile 50); p95 = (Get-OutcomeValidationPercentile -Values $totalMs -Percentile 95) }
        }
        execution_metrics    = [ordered]@{
            retry_rate = 'NOT_MEASURABLE'
            debugger_rate = 'NOT_MEASURABLE'
            architect_rate = 'NOT_MEASURABLE'
            review_findings_per_task = 'NOT_MEASURABLE'
            note = 'Evidencia controlada de roteamento: execucao (tester/reviewer/retry) nao observada neste lote.'
        }
        per_category         = @($catRows)
    }
}
