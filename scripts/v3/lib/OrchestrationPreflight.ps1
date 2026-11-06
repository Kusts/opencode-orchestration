<#!
.SYNOPSIS
    V3 mandatory orchestration preflight (canonical): single-worker vs multi-worker vs persistent-goal vs deterministic fallback.
.DESCRIPTION
    Dot-sourceable library (no execution on load). Decides BEFORE any
    delegation whether the Planner must delegate to one cheap worker
    (single-worker trivial), to multiple workers (non-trivial), or to a
    persistent goal owner, or must take a deterministic fallback
    (underspecified task, hard exclusion, unhealthy router, stale
    registry). Never executes MCP, never loads skills, never changes
    authority/allowlist/permissions/flags/registry. Telemetry uses
    tokens only (no free text). PowerShell 5.1. ASCII-only. Never throws
    on operational paths (fail-safe => DETERMINISTIC_FALLBACK).

    Contract split (review-hardened):
      - PRE-decision (Get-OrchestrationPreflight): plans only. MULTI_WORKER
        and PERSISTENT_GOAL carry
        bypass_verdict=UNVERIFIED_POST_EXECUTION_REQUIRED and a
        post_execution_check hint; they never attest compliance.
      - POST-verdict (Test-OrchestrationDoneCompliance): the DONE gate,
        called with OBSERVED worker participation / deterministic-owner
        execution (and, for trivial work, the observed ExecutionShape).
        Only COMPLIANT here allows a compliant DONE claim.
      - Health inputs ($RouterHealthy/$RegistryFresh/$RegistryOk) are
        produced by the executor layer (Invoke-CapabilityAcceptance),
        which owns timeout/exception/malformed-response handling and
        already falls back deterministically on all of them; absent
        signals default to healthy, MALFORMED signals are fail-closed
        (see CLI converter).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Convert-OrchestrationNormalizedText {
    [CmdletBinding()]
    param([string]$Text)
    try {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $formD = ([string]$Text).Normalize([System.Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder ($formD.Length)
        foreach ($ch in $formD.ToCharArray()) {
            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
            if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { $sb.Append($ch) | Out-Null }
        }
        return ($sb.ToString().ToLowerInvariant())
    }
    catch { return '' }
}

function Test-OrchestrationKeyword {
    [CmdletBinding()]
    param([string]$Blob, [string[]]$Words, [string[]]$Exact = @())
    try {
        $tokens = @(([string]$Blob) -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $exactSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($e in @($Exact)) {
            $es = ([string]$e).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($es)) { $exactSet.Add($es) | Out-Null }
        }
        if ($exactSet.Count -gt 0) {
            foreach ($tok in $tokens) { if ($exactSet.Contains($tok)) { return $true } }
        }
        foreach ($w in @($Words)) {
            $kw = ([string]$w).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($kw)) { continue }
            if ($kw -match '^[a-z0-9]+$') {
                foreach ($tok in $tokens) { if ($tok.StartsWith($kw)) { return $true } }
            }
            else {
                if (([string]$Blob).Contains($kw)) { return $true }
            }
        }
    }
    catch { }
    return $false
}

function Get-OrchestrationDirectTokens {
    [CmdletBinding()]
    param()
    # v0.1.0: deprecated, fail-closed.
    return @()
}

function Test-OrchestrationDirectReason {
    [CmdletBinding()]
    param([string]$Reason)
    # v0.1.0: deprecated, fail-closed. Any input (including legacy
    # DIRECT_* tokens) returns $false; trivial work is proven by
    # ExecutionShape SINGLE_WORKER in Test-OrchestrationDoneCompliance.
    return $false
}

function Test-OrchestrationBypass {
    [CmdletBinding()]
    param(
        [string]$TaskClass = '',
        [int]$WorkerParticipation = 0
    )
    try {
        $c = ([string]$TaskClass).Trim().ToLowerInvariant()
        $n = 0
        try { $n = [int]$WorkerParticipation } catch { $n = 0 }
        if ($c -cne 'non_trivial') { return $false }
        if ($n -le 0) { return $true }
        return $false
    }
    catch { return $false }
}

function Test-OrchestrationDoneCompliance {
    <#
    .SYNOPSIS
        Porta de DONE: verificacao POS-execucao. A pre-decision (MULTI_WORKER,
        PERSISTENT_GOAL, DETERMINISTIC_FALLBACK) apenas planeja; somente esta
        funcao, chamada com a participacao real observada, pode atestar
        compliance. Trabalho trivial exige Decision SINGLE_WORKER, o
        ExecutionShape observado SINGLE_WORKER e participacao observada
        maior que zero; classe fora de trivial/non_trivial e falha
        fechada (NON_COMPLIANT_INVALID_TASK_CLASS). Tokens DIRECT_*
        legados sao rejeitados como NON_COMPLIANT_DEPRECATED_DIRECT
        (fail-closed).
    #>
    [CmdletBinding()]
    param(
        [string]$TaskClass = '',
        [string]$Decision = '',
        [int]$ActualWorkerParticipation = 0,
        [bool]$DeterministicOwnerExecuted = $false,
        [string]$DirectReason = '',
        [string]$ExecutionShape = ''
    )
    try {
        $c = ([string]$TaskClass).Trim().ToLowerInvariant()
        $d = ([string]$Decision).Trim().ToUpperInvariant()
        # TDR-F1-11: classe desconhecida (vazia ou fora de trivial/non_trivial)
        # e falha fechada antes de qualquer outro ramo.
        if (($c -cne 'trivial') -and ($c -cne 'non_trivial')) { return 'NON_COMPLIANT_INVALID_TASK_CLASS' }
        if ($c -ceq 'trivial') {
            $dr = ([string]$DirectReason).Trim()
            $shape = ([string]$ExecutionShape).Trim()

            # Rota formal DIRECT_VERIFIED para tarefas comprovadamente triviais e de baixo risco
            if ($d -ceq 'DIRECT_VERIFIED') {
                if ($shape -ieq 'DIRECT_VERIFIED') {
                    if ($dr -like 'DIRECT_VERIFIED_*') {
                        return 'COMPLIANT'
                    }
                    if ([string]::IsNullOrWhiteSpace($dr)) {
                        return 'NON_COMPLIANT_MISSING_DIRECT_REASON'
                    }
                    return 'NON_COMPLIANT_INVALID_DIRECT_REASON'
                }
                return 'NON_COMPLIANT_INVALID_DECISION'
            }

            if (-not [string]::IsNullOrWhiteSpace($dr)) {
                if ($dr -like 'DIRECT_*') { return 'NON_COMPLIANT_DEPRECATED_DIRECT' }
                return 'NON_COMPLIANT_INVALID_DIRECT_REASON'
            }
            # TDR-F1-11: ramo trivial exige Decision SINGLE_WORKER (vazia cai aqui).
            if ($d -cne 'SINGLE_WORKER') { return 'NON_COMPLIANT_INVALID_DECISION' }
            if ([string]::IsNullOrWhiteSpace($shape)) { return 'NON_COMPLIANT_MISSING_DIRECT_REASON' }
            if ($shape -ieq 'SINGLE_WORKER') {
                # TDR-F1-11: trivial tambem exige participacao observada.
                $tn = 0
                try { $tn = [int]$ActualWorkerParticipation } catch { $tn = 0 }
                if ($tn -le 0) { return 'ORCHESTRATION_POLICY_BYPASS' }
                return 'COMPLIANT'
            }
            return 'NON_COMPLIANT_DEPRECATED_DIRECT'
        }
        if ($d -ceq 'BLOCKED') { return 'ORCHESTRATION_POLICY_BYPASS' }
        if ($d -ceq 'DETERMINISTIC_FALLBACK') {
            if ($DeterministicOwnerExecuted) { return 'COMPLIANT' }
            return 'ORCHESTRATION_POLICY_BYPASS'
        }
        $n = 0
        try { $n = [int]$ActualWorkerParticipation } catch { $n = 0 }
        if ($n -le 0) { return 'ORCHESTRATION_POLICY_BYPASS' }
        return 'COMPLIANT'
    }
    catch { return 'ORCHESTRATION_POLICY_BYPASS' }
}

function Test-OrchestrationSubdelegation {
    [CmdletBinding()]
    param(
        [bool]$IsWorker = $false,
        [bool]$Worker = $false
    )
    try {
        if ($IsWorker -or $Worker) { return 'denied' }
        return 'allowed'
    }
    catch { return 'denied' }
}

function Test-OrchestrationRouterHealth {
    [CmdletBinding()]
    param(
        [bool]$Healthy = $true,
        [bool]$RouterHealthy = $true,
        [bool]$RegistryFresh = $true,
        [bool]$RegistryOk = $true
    )
    try {
        if (-not $Healthy) { return $false }
        if (-not $RouterHealthy) { return $false }
        if (-not $RegistryFresh) { return $false }
        if (-not $RegistryOk) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-OrchestrationHardExclusions {
    [CmdletBinding()]
    param(
        [string]$Objective = '',
        [string]$TaskType = '',
        [string]$Domain = '',
        [string[]]$SecondaryDomains = @(),
        [string]$Risk = '',
        [string]$ReadWrite = ''
    )
    $tokens = New-Object System.Collections.Generic.List[string]
    try {
        $secBlob = ''
        try { $secBlob = ((@($SecondaryDomains) | ForEach-Object { [string]$_ }) -join ' ') } catch { $secBlob = '' }
        $raw = (([string]$Objective) + ' ' + ([string]$Domain) + ' ' + ([string]$TaskType) + ' ' + $secBlob)
        $blob = Convert-OrchestrationNormalizedText -Text $raw
        $add = { param([string]$t) if (-not $tokens.Contains($t)) { $tokens.Add($t) | Out-Null } }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('authority', 'allowlist', 'authority change', 'control-plane', 'control plane', 'capability-flags', 'capability_router', 'ativacao', 'activation')) { & $add 'authority_change' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('permission', 'permissions', 'permissao', 'permissoes', 'opencode.json', 'agent.build.permission')) { & $add 'permission_change' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('security', 'seguranca', 'autentic', 'authent', 'autoriz', 'vulnerab', 'owasp', 'pentest', 'exploit', 'csrf', 'xss', 'sqli', 'idor', 'ssrf', 'saml', 'oauth', 'session', 'sessao', 'cookie', 'webhook', '2fa', 'mfa', 'rate limit', 'criptograf', 'encrypt', 'privacidade', 'privacy', 'lgpd', 'pii', 'pci', 'gdpr', 'command injection', 'shell injection', 'code injection', 'code execution', 'remote code execution', 'path traversal', 'traversal', 'deserializ', 'xxe', 'prototype pollution', 'supply chain', 'malware', 'backdoor', 'privilege escalation', 'cve-') -Exact @('auth')) { & $add 'security_sensitive' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('secret', 'segredo', 'credencial', 'credential', 'password', 'senha', 'api key', 'apikey', 'private key', 'access key', 'refresh token', 'bearer') -Exact @('token', 'tokens')) { & $add 'credentials' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('destrutiv', 'destructive', 'drop table', 'truncate', 'purge', 'wipe', 'rm -rf', 'delete all', 'apagar tudo')) { & $add 'destructive' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('irrevers', 'irreversible', 'migra', 'migration', 'migrate')) {
            $rw = ([string]$ReadWrite).Trim().ToLowerInvariant()
            if (($rw -ceq 'write') -or $blob.Contains('migra') -or $blob.Contains('irrevers')) { & $add 'irreversible_migration' }
        }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('deploy', 'deployment', 'producao', 'production', 'rollout', 'terraform apply', 'kubectl apply', 'infra mutation')) { & $add 'infra_mutation' }
        # H3 hardening (aligned with CapabilityAcceptance): isolated 'release'
        # is not a mutation nor control-plane; deployment verbs above govern.
        if (Test-OrchestrationKeyword -Blob $blob -Words @('control-plane', 'control plane', 'runtime governance', 'registry governance', 'routing governance')) { & $add 'control_plane' }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('mcp', 'tool execution', 'executar tool', 'execute tool', 'mcp execution')) { & $add 'mcp_execution' }
        try {
            $dom = Convert-OrchestrationNormalizedText -Text ([string]$Domain).Trim()
            $rk = ([string]$Risk).Trim().ToLowerInvariant()
            $rw2 = ([string]$ReadWrite).Trim().ToLowerInvariant()
            if (($dom -ceq 'infra') -and (($rk -ceq 'high') -or ($rk -ceq 'critical')) -and ($rw2 -ceq 'write')) { & $add 'infra_mutation' }
        }
        catch { }
    }
    catch { }
    $arr = [string[]]$tokens.ToArray()
    return [PSCustomObject]@{ Excluded = ($tokens.Count -gt 0); Tokens = $arr }
}

function Test-OrchestrationVague {
    [CmdletBinding()]
    param(
        [string]$Objective = '',
        [string]$TaskType = '',
        [string]$Domain = '',
        [string]$Risk = '',
        [string]$ReadWrite = ''
    )
    try {
        $obj = ([string]$Objective).Trim()
        $tt = ([string]$TaskType).Trim().ToLowerInvariant()
        $dom = ([string]$Domain).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($obj)) { return $true }
        if ([string]::IsNullOrWhiteSpace($tt) -and [string]::IsNullOrWhiteSpace($dom)) { return $true }
        $rk = ([string]$Risk).Trim().ToLowerInvariant()
        $rw = ([string]$ReadWrite).Trim().ToLowerInvariant()
        $rkUnclear = ([string]::IsNullOrWhiteSpace($rk) -or ($rk -ceq 'unknown'))
        $rwUnclear = ([string]::IsNullOrWhiteSpace($rw) -or ($rw -ceq 'unknown'))
        if ($rkUnclear -and $rwUnclear -and ($obj.Length -lt 20)) {
            $blob = Convert-OrchestrationNormalizedText -Text $obj
            $verbs = @('fix', 'add', 'implement', 'review', 'test', 'audit', 'document', 'analy', 'refactor', 'update', 'create', 'build', 'investigat', 'correct', 'change', 'write', 'read', 'check', 'validat', 'verif', 'corrig', 'revis', 'implement', 'avali', 'migrat', 'pesquis', 'explor')
            if (-not (Test-OrchestrationKeyword -Blob $blob -Words $verbs)) { return $true }
        }
    }
    catch { return $true }
    return $false
}

function Test-OrchestrationArchitectureDecision {
    [CmdletBinding()]
    param([string]$Objective = '', [string]$TaskType = '', [string]$Domain = '')
    try {
        $blob = Convert-OrchestrationNormalizedText -Text (([string]$Objective) + ' ' + ([string]$TaskType) + ' ' + ([string]$Domain))
        return (Test-OrchestrationKeyword -Blob $blob -Words @('architect', 'arquitet', 'adr', 'protocol', 'tradeoff', 'trade-off', 'decision', 'decisao', 'migration plan', 'plano de migracao', 'data model', 'modelo de dados', 'concurrency model'))
    }
    catch { return $false }
}

function Get-OrchestrationSelectedAgents {
    [CmdletBinding()]
    param(
        [string]$TaskType = '',
        [string]$Domain = '',
        [string]$Objective = '',
        [string[]]$SecondaryDomains = @()
    )
    try {
        $secBlob = ''
        try { $secBlob = ((@($SecondaryDomains) | ForEach-Object { [string]$_ }) -join ' ') } catch { $secBlob = '' }
        $tt = Convert-OrchestrationNormalizedText -Text ([string]$TaskType).Trim()
        $dom = Convert-OrchestrationNormalizedText -Text ([string]$Domain).Trim()
        $blob = Convert-OrchestrationNormalizedText -Text (([string]$TaskType) + ' ' + ([string]$Domain) + ' ' + $secBlob + ' ' + ([string]$Objective))
        # Explicit work-type first: keywords never override structured signals.
        if ($tt -ceq 'review') { return @('reviewer') }
        # v0.1.0: trivial work-types resolve to the single worker, so the
        # SINGLE_WORKER gate never returns an empty selected_agents.
        if (($tt -ceq 'lookup') -or ($tt -ceq 'read')) { return @('explorer') }
        if (($tt -ceq 'cosmetic') -or ($tt -ceq 'formatting') -or ($tt -ceq 'trivial')) { return @('coder') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('research', 'pesquisa'))) { return @('researcher') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('discovery', 'exploration', 'exploracao', 'codebase', 'impacto'))) {
            if (($tt -ceq 'discovery') -or ($tt -ceq 'exploration') -or ($dom -ceq 'exploration') -or ($dom -ceq 'discovery')) { return @('explorer') }
        }
        if (($tt -ceq 'discovery') -or ($tt -ceq 'exploration')) { return @('explorer') }
        if (($tt -ceq 'test') -or ($tt -ceq 'testing') -or ($tt -ceq 'validation') -or ($dom -ceq 'testing')) { return @('tester') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('validation', 'validacao', 'qa')) -and (($tt -ceq '') -or ($tt -ceq 'validation') -or ($tt -ceq 'test') -or ($tt -ceq 'testing'))) { return @('tester') }
        if ($tt -ceq 'planning') { return @('requirements-analyst') }
        if (Test-OrchestrationKeyword -Blob $blob -Words @('architect', 'arquitet')) { return @('architect') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('infra', 'devops', 'deploy', 'pipeline'))) { return @('infra-engineer') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('automation', 'automacao', 'workflow'))) { return @('automation-engineer') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('ai-agent', 'agent workflow', 'prompt', 'evaluation', 'memory architecture'))) { return @('ai-agent-engineer') }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('ai', 'agente de ia')) -and (($dom -ceq 'ai') -or ($tt -ceq 'ai'))) { return @('ai-agent-engineer') }
        return @('coder')
    }
    catch { return @('coder') }
}

function Get-OrchestrationPreflight {
    [CmdletBinding()]
    param(
        [string]$Objective = '',
        [string]$TaskType = '',
        [string]$Domain = '',
        [string]$Risk = 'unknown',
        [string]$ReadWrite = '',
        [string[]]$SecondaryDomains = @(),
        [bool]$RouterHealthy = $true,
        [bool]$RegistryFresh = $true,
        [bool]$RegistryOk = $true,
        [string[]]$Allowlist,
        [string]$ExecutionStrategy = ''
    )
    try {
        $obj = ([string]$Objective)
        $objTrim = $obj.Trim()
        $tt = ([string]$TaskType).Trim().ToLowerInvariant()
        $dom = ([string]$Domain).Trim().ToLowerInvariant()
        $rk = ([string]$Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($rk)) { $rk = 'unknown' }
        $rw = ([string]$ReadWrite).Trim().ToLowerInvariant()
        $sec = @()
        try { foreach ($v in @($SecondaryDomains)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $sec += ([string]$v).Trim() } } } catch { $sec = @() }

        $mkResult = {
            param([string]$Decision, [string]$Class, [string]$Direct, [string[]]$Agents, [string]$Fallback, [string]$Bypass, [string]$PostCheck = '')
            return [PSCustomObject]@{
                orchestration_decision = $Decision
                task_class             = $Class
                direct_reason          = $Direct
                selected_agents        = @($Agents)
                fallback_reason        = $Fallback
                bypass_verdict         = $Bypass
                post_execution_check   = $PostCheck
            }
        }

        $checkMulti = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision MULTI_WORKER -ActualWorkerParticipation <actual_workers>'
        $checkSingle = 'Test-OrchestrationDoneCompliance -TaskClass trivial -Decision SINGLE_WORKER -ExecutionShape SINGLE_WORKER -ActualWorkerParticipation <actual_workers>'
        $checkGoal = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision PERSISTENT_GOAL -ActualWorkerParticipation <actual_workers>'
        $checkFallback = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision DETERMINISTIC_FALLBACK -DeterministicOwnerExecuted $<owner_ran>'

        if ($PSBoundParameters.ContainsKey('Allowlist')) {
            $al = @($Allowlist | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($al.Count -eq 0) {
                return (& $mkResult 'BLOCKED' 'non_trivial' '' @() 'empty_allowlist' 'ORCHESTRATION_POLICY_BYPASS')
            }
        }

        $excl = Get-OrchestrationHardExclusions -Objective $obj -TaskType $tt -Domain $dom -SecondaryDomains $sec -Risk $rk -ReadWrite $rw
        if ([bool]$excl.Excluded) {
            $first = ''
            if (@($excl.Tokens).Count -gt 0) { $first = [string](@($excl.Tokens)[0]) }
            $reason = 'hard_exclusion_' + $first
            return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() $reason 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
        }

        if (Test-OrchestrationVague -Objective $obj -TaskType $tt -Domain $dom -Risk $rk -ReadWrite $rw) {
            return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'vague_task_underspecified' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
        }

        # v0.1.0: goal promotion AFTER hard exclusions/vague and
        # BEFORE the trivial gate (a goal outranks trivial). Explicit
        # goal task-types promote directly; a spec+plan objective promotes
        # via keyword, in the same keyword style as this file.
        $goalExplicit = (($tt -ceq 'goal') -or ($tt -ceq 'persistent-goal'))
        $goalSpecPlan = $false
        try {
            # TDR-F1-12: word-boundary para nao casar substrings
            # ('plant'/'planilha' nao sao 'plan'; 'special' nao e 'spec').
            $blobGoal = Convert-OrchestrationNormalizedText -Text $obj
            $hasSpec = ($blobGoal -match '\bspec\b')
            $hasPlan = (($blobGoal -match '\bplan\b') -or ($blobGoal -match '\bplans\b') -or ($blobGoal -match '\bfases\b') -or ($blobGoal -match '\bphases\b') -or ($blobGoal.Contains('implementacao completa')) -or ($blobGoal.Contains('implement complete')) -or ($blobGoal -match '\bgoal\b'))
            if ($hasSpec -and $hasPlan) { $goalSpecPlan = $true }
        }
        catch { $goalSpecPlan = $false }

        if ($goalExplicit -or $goalSpecPlan) {
            # #201-fatia3: goal tambem despacha workers, entao honra a saude do
            # router/registry como o gate abaixo (reason local, mesmo mapeamento).
            if (-not (Test-OrchestrationRouterHealth -Healthy $RouterHealthy -RegistryFresh $RegistryFresh -RegistryOk $RegistryOk)) {
                $gr = 'router_unhealthy'
                if (-not $RouterHealthy) { $gr = 'router_unavailable' }
                elseif (-not $RegistryFresh) { $gr = 'registry_stale' }
                return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() $gr 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
            }
            $goalAgents = @(Get-OrchestrationSelectedAgents -TaskType $tt -Domain $dom -Objective $obj -SecondaryDomains $sec)
            if (@($goalAgents).Count -eq 0) { $goalAgents = @('coder') }
            $goalReason = 'goal_promotion_spec_plan'
            if ($goalExplicit) { $goalReason = 'goal_promotion_explicit' }
            return (& $mkResult 'PERSISTENT_GOAL' 'non_trivial' '' @($goalAgents) $goalReason 'UNVERIFIED_POST_EXECUTION_REQUIRED' $checkGoal)
        }

        $isTrivial = $false
        $directReason = 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED'
        try {
            $lenOk = (($objTrim.Length -gt 0) -and ($objTrim.Length -le 140))
            $riskOk = ($rk -ceq 'low')
            $typeOk = (($tt -ceq 'trivial') -or ($tt -ceq 'lookup') -or ($tt -ceq 'read') -or ($tt -ceq 'cosmetic') -or ($tt -ceq 'formatting') -or ($tt -ceq 'typo') -or ($tt -ceq 'micro_edit'))
            $localizedOk = (@($sec).Count -le 1)
            $archHit = Test-OrchestrationArchitectureDecision -Objective $obj -TaskType $tt -Domain $dom
            $blob = Convert-OrchestrationNormalizedText -Text (([string]$obj) + ' ' + ([string]$tt) + ' ' + ([string]$dom))
            $sensitiveHit = Test-OrchestrationKeyword -Blob $blob -Words @('permission', 'permissions', 'permissao', 'permissoes', 'security', 'auth', 'secret', 'credential', 'token', 'opencode.json', 'kernel', 'protect-master', 'delete', 'drop', 'database', 'migration')
            # #201-correcao: intento substantivo no Objective rejeita a rota direta,
            # mesmo com metadados triviais (usa o predicado existente, sem classificador novo).
            $objSubstantiveBlob = Convert-OrchestrationNormalizedText -Text ([string]$obj)
            $substantiveHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('implement', 'build', 'creat', 'develop', 'design', 'refactor', 'rewrit', 'rework', 'extend', 'integrat', 'migrat', 'overhaul', 'analy', 'analis', 'audit', 'investig', 'research', 'pesquis', 'review', 'revis', 'compar', 'evaluat', 'avali', 'optimiz', 'otimiz', 'diagnos', 'bottleneck', 'performance bottleneck', 'new workflow', 'new feature', 'new module', 'new endpoint', 'new service', 'new pipeline', 'new system', 'add new', 'add feature', 'add module', 'add endpoint', 'add service', 'add workflow')
            # #201-segunda-revisao: direta exige evidencia objetiva de leitura
            # pontual/microedicao no Objective e rejeita escopo amplo mesmo com
            # verbo de consulta presente (mesmo predicado existente, sem funcao nova).
            # #201-terceira-revisao: direta exige evidencia objetiva de point
            # lookup limitado OU microedicao especifica no Objective (predicado
            # existente, sem funcao nova). Verbo generico fix/correct sozinho
            # e substantivos como system/error/workflow nao estabelecem
            # trivialidade; typo preserva microedicao existente.
            $pointLookupHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('where', 'defined', 'defin', 'lookup', 'inspect', 'inspec', 'locate', 'localiz', 'point lookup', 'specific symbol', 'onde', 'qual arquivo', 'qual campo', 'qual simbolo')
            $microEditHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('typo', 'spelling', 'grammar', 'punctuation', 'comma', 'period', 'whitespace', 'spacing', 'heading', 'label text', 'one-word', 'one word', 'single-line', 'single line', 'comment', 'virgula', 'pontuac', 'ortograf', 'gramat')
            # F2: functional code micro-edits need explicit evidence in the
            # objective (a named focused test), never metadata alone. Word
            # boundaries keep 'unfocused test' from counting as evidence.
            $focusedTestHit = $false
            try {
                if ($objSubstantiveBlob -match '\b(?:focused (?:unit )?test|teste (?:unitario )?focado)\b') { $focusedTestHit = $true }
            }
            catch { $focusedTestHit = $false }
            # Negation is checked BOTH before the test phrase (without/no need/
            # never/nao/sem/nenhum) and after it ('test will not run'), so a
            # positive phrase plus a later negation still blocks. Explicit 'no'
            # phrases stay separate: bare 'no' is a Portuguese preposition.
            $focusedTestNegated = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('without focused test', 'without a focused test', 'without any focused test', 'no focused test', 'no focused unit test', 'sem teste')
            try {
                if (-not $focusedTestNegated) {
                    if ($objSubstantiveBlob -match '\b(without|no need(?: for| to)?|never|not|do not|don''?t|sem|nao|nenhum)\b[^.;!?]{0,48}\b(?:focused |unit |focused unit )?(?:test|teste)') { $focusedTestNegated = $true }
                }
                if (-not $focusedTestNegated) {
                    # Skip/ignore/avoid negate only when the TEST is the object;
                    # 'skip preflight ... run focused test' stays direct.
                    if ($objSubstantiveBlob -match '\b(?:skip(?:ping|s|ped)?|pular|pulando|ignorar|ignorando|ignore|ignoring|ignores|ignored|avoid|avoiding|avoids|avoided|evitar|evite|evitando|evitamos|dispensar|dispensando|dispense)\b(?:\s+(?:the|a|an|o|os|as|um|uma|this|that|estes?|estas?|my|meu|minha|focused|unit|unitario|focado|flaky|slow|optional|preflight|unstable|instavel|lento|rapido|whole|entire|failing|failed|broken|e2e))*\s+(?:(?:run(?:ning)?|execut(?:e|ing)|rodar|rodando|executar|executando)\s+(?:it|isso|ele)\b|(?:test|teste)\b)') { $focusedTestNegated = $true }
                }
                if (-not $focusedTestNegated) {
                    if ($objSubstantiveBlob -match '\b(?:test|teste)\b[^.;!?]{0,32}\b(?:will not(?: be)?|won t|cannot|can not|never run|do not run|don''?t run|no need|not needed|not run|nao vai|nao sera|nao rodar|nao executar|nao foi|sem rodar|sem executar|sem necessidade|nenhum)\b') { $focusedTestNegated = $true }
                }
                if (-not $focusedTestNegated) {
                    # Sentence punctuation ('.'/';') must not hide execution
                    # negation either; each alternative still requires an
                    # execution verb or the low-risk no-need markers.
                    if ($objSubstantiveBlob -match '\b(?:test|teste)\b.{0,40}\b(?:will not(?: be)? run|won t run|cannot run|can not run|never run|not run|without run(?:ning)?|don''?t run|pode ficar para depois|ficar para depois|adiar|nao vai rodar|nao sera executado|nao rodar|nao executar|sem rodar|sem executar|sem necessidade|no need|not needed|nao precisa(?:mos)?)\b') { $focusedTestNegated = $true }
                }
                if (-not $focusedTestNegated) {
                    # Post-test skip/ignore/avoid must point at the test itself
                    # (it/the focused test/teste), never at preflight or lint.
                    if ($objSubstantiveBlob -match '\b(?:test|teste)\b.{0,40}\b(?:skip(?:ping|s|ped)?|ignore|ignoring|ignores|ignored|avoid|avoiding|avoids|avoided|pular|pulando|ignorar|ignorando|evitar|evite|evitando|evitamos|dispensar|dispensando|dispense)\b\s+(?:(?:it|isso|ele|(?:run(?:ning)?|execut(?:e|ing)|rodar|rodando|executar|executando)\s+(?:it|isso|ele))\b|(?:the|this|that|o|a|um|uma)\b(?:\s+(?:focused|unit|flaky|slow|optional|preflight|whole|entire|failing|failed|broken|e2e|instavel|lento|rapido))*\s+(?:test|teste)\b)') { $focusedTestNegated = $true }
                }
            }
            catch { }
            # A direct code micro-edit needs BOTH a single-file scope and one
            # code unit (function/branch/condition/expression), never either/or.
            $microFileScopeHit = $false
            $microUnitScopeHit = $false
            try {
                # Word-boundary matching: 'um arquivo' must not match inside
                # 'algum arquivo', nor 'um branch' inside 'algum branch'.
                $microFileScopeHit = ($objSubstantiveBlob -match '\b(?:one file|single file|um arquivo|arquivo unico|um unico arquivo)\b')
                $microUnitScopeHit = ($objSubstantiveBlob -match '\b(?:one function|single function|one branch|single branch|one condition|single condition|one expression|single expression|um branch|um ramo|ramo unico|uma funcao|uma condicao|uma expressao)\b')
            }
            catch { $microFileScopeHit = $false; $microUnitScopeHit = $false }
            $microCodeScopeNegated = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('without a single file', 'without single file', 'without a single-file', 'without single-file', 'no single file', 'no single-file', 'not a single file', 'not a single-file', 'not single file', 'not single-file', 'not in a single file', 'not one file', 'not in one file', 'not only one file', 'not only a single file', 'not just one file', 'not just a single file', 'without one file', 'no one file', 'one more file', 'two files', 'three files', 'more than one file', 'both files', 'other file', 'other files', 'second file', 'second files', 'callers', 'another file', 'another module', 'dois arquivos', 'duas arquivos', 'mais de um arquivo', 'sem arquivo', 'sem um arquivo')
            # Whole-token financial terms for words that prefix-match common
            # non-financial words (feed(fee)back, load balancer(balance),
            # taxonomy(tax)). PT-BR terms mirror the active adapter vocabulary.
            $microCodeFinancialHit = Test-OrchestrationKeyword -Blob $blob -Words @('payment', 'payments', 'billing', 'invoice', 'invoices', 'invoicing', 'charge', 'charges', 'charging', 'refund', 'refunds', 'money', 'financial', 'financeiro', 'financeira', 'price', 'pricing', 'checkout', 'transaction', 'transactions', 'transacao', 'transacoes', 'taxa', 'taxas', 'subscription', 'subscriptions', 'payout', 'paga', 'pago', 'cobranca', 'cobrancas', 'cobrand', 'cobrar', 'cobrou', 'cobrador', 'fatura', 'faturas', 'preco', 'precos', 'assinatura', 'assinaturas', 'estorno', 'estornos', 'estorn', 'saldo', 'saldos', 'imposto', 'impostos', 'order total') -Exact @('fee', 'fees', 'tax', 'taxes', 'balance', 'balances')
            # Code-local PT-BR credential terms; the shared sensitiveHit list
            # stays untouched so docs/read direct behavior is unchanged.
            $microCodePtSensitiveHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('credencial', 'credenciais', 'segredo', 'segredos', 'senha', 'senhas')
            # Protected surfaces: standalone terms are word-bounded (so 'please'
            # and 'release' are not hits); CamelCase compounds are detected only
            # inside file tokens with a known extension. 'preflight' is therefore
            # protected only as a file name, keeping 'skip preflight' direct.
            $microCodeProtectedHit = $false
            try {
                if ($objSubstantiveBlob -match '\b(?:kernel|taskkernel|lease|leases|worktree|worktrees|grant|grants|verifier|verification|permission|permissions|auth|authz|authentication|authorization|credential|credentials|secret|secrets|enforcement|mandate|registry|capability|policy|policies|settings|dotenv|opencode)\b') { $microCodeProtectedHit = $true }
                if (-not $microCodeProtectedHit -and $objSubstantiveBlob -match '\.env\b') { $microCodeProtectedHit = $true }
                if (-not $microCodeProtectedHit -and $objSubstantiveBlob -match '\b(?:orchestrationtaskkernel|taskkernel|worktreelease|leasemanager|executiongrant|grantpolicy|verifierprofiles|permissiongate|orchestrationpreflight|orchestrationdonecompliance|capabilityacceptance|mcpsafety)\b') { $microCodeProtectedHit = $true }
                if (-not $microCodeProtectedHit) {
                    foreach ($protectedPath in [regex]::Matches($objSubstantiveBlob, '\b[\w./-]+\.(?:ps1|psm1|js|ts|tsx|jsx|json|cs|py|go|rs|java|sh)\b')) {
                        if ($protectedPath.Value -match '(?:kernel|taskkernel|lease|worktree|grant|verifier|verification|permission|auth|authz|authentication|authorization|credential|secret|enforcement|mandate|registry|capability|policy|preflight|settings|opencode|dotenv)') { $microCodeProtectedHit = $true; break }
                    }
                }
            }
            catch { $microCodeProtectedHit = $true }
            # Code-route authz/security/concurrency vocabulary (LOW review
            # findings). Kept local so the docs/read branch and the shared
            # $sensitiveHit semantics are unchanged.
            $microCodeSensitiveHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('login', 'logon', 'role', 'rbac', 'acl', 'access control', 'access-control', 'jwt', 'sanitiz', 'sql', 'hash', 'hmac', 'signature', 'cors', 'concurrent', 'concurrency', 'race', 'mutex', 'lock', 'lease', 'worktree', 'shared file', 'shared-file')
            # Two distinct code/test paths are multi-file scope; one path (even
            # repeated) stays eligible. The extension list is deliberately
            # bounded to code/test artifacts.
            $microCodeMultiPathHit = $false
            try {
                $pathSet = @{}
                foreach ($pathMatch in [regex]::Matches($objSubstantiveBlob, '\b[\w./-]+\.(?:ps1|psm1|js|ts|tsx|jsx|json|cs|py|go|rs|java|sh)\b')) { $pathSet[$pathMatch.Value] = $true }
                if ($pathSet.Count -ge 2) { $microCodeMultiPathHit = $true }
            }
            catch { $microCodeMultiPathHit = $true }
            # Removal/cleanup uses bounded stems so inflections (removing,
            # deleting, erasing, pruning, apagando, excluindo) are covered
            # without broad prefixes; 'clean'/'cleanup' stay whole-token so a
            # 'cleaner helper' is not hit.
            $microCodeDestructiveHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('remov', 'delet', 'eras', 'prun', 'apag', 'exclu', 'wipe', 'limpar', 'limpeza', 'limpando', 'clean up', 'cleanup') -Exact @('clean')
            # Quantificadores por casamento exato: o modo -Words usa starts-with
            # e 'all' casa 'allow'/'allocate'. Frases de escopo amplo seguem por
            # substring/prefixo (fail-closed para delegacao).
            $broadScopeHit = Test-OrchestrationKeyword -Blob $objSubstantiveBlob -Words @('across', 'throughout', 'entire', 'whole', 'codebase', 'repository', 'repositorio', 'modules', 'modulos', 'usages', 'usage', 'inteir', 'varios', 'varias', 'repo-wide', 'repo wide', 'throughout the repository', 'throughout the codebase', 'throughout the repo') -Exact @('all', 'every', 'multiple', 'several', 'various', 'todos', 'todas', 'everywhere', 'globally', 'globalmente')

            $isReadTrivial = ($lenOk -and $riskOk -and ($rw -ceq 'read') -and $typeOk -and $localizedOk -and (-not $archHit) -and (-not $substantiveHit) -and ($pointLookupHit -or $microEditHit) -and (-not $broadScopeHit))
            $isMicroEditWrite = ($lenOk -and $riskOk -and ($rw -ceq 'write') -and $typeOk -and $localizedOk -and (-not $archHit) -and (-not $sensitiveHit) -and (-not $substantiveHit) -and $microEditHit -and (-not $broadScopeHit) -and ($dom -in @('docs', 'documentation', 'comments', 'formatting', 'metadata', 'chore')))
            # F2 narrow routing change: one localized functional code micro-edit
            # with an explicit focused test. Requires explicit trivial/code
            # metadata plus every existing safety cue; no new parameter, flag or
            # stage, and the docs/read branches above stay unchanged.
            $isCodeMicroEditWrite = ($lenOk -and $riskOk -and ($rw -ceq 'write') -and ($tt -ceq 'trivial') -and ($dom -ceq 'code') -and $localizedOk -and (-not $archHit) -and (-not $sensitiveHit) -and (-not $microCodeProtectedHit) -and (-not $microCodeSensitiveHit) -and (-not $microCodePtSensitiveHit) -and (-not $microCodeDestructiveHit) -and (-not $microCodeFinancialHit) -and (-not $substantiveHit) -and $microFileScopeHit -and $microUnitScopeHit -and (-not $microCodeScopeNegated) -and (-not $microCodeMultiPathHit) -and $focusedTestHit -and (-not $focusedTestNegated) -and (-not $broadScopeHit))

            if ($isReadTrivial) {
                $isTrivial = $true
                $directReason = 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED'
            } elseif ($isMicroEditWrite) {
                $isTrivial = $true
                $directReason = 'DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK'
            } elseif ($isCodeMicroEditWrite) {
                $isTrivial = $true
                $directReason = 'DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK'
            }
        }
        catch { $isTrivial = $false }

        # #201/#201-fatia2: eligible safe trivial with omitted or DIRECT_VERIFIED
        # strategy takes the existing DIRECT_VERIFIED route (zero workers). The
        # classifier above (low risk, localized, known task type, no architecture
        # decision, read or docs-only micro-edit without sensitive keywords) is
        # pure-local and needs no router/registry, so it returns before the
        # health check below.
        if ($isTrivial -and ([string]::IsNullOrWhiteSpace($ExecutionStrategy) -or ($ExecutionStrategy -ieq 'DIRECT_VERIFIED'))) {
            $checkDirect = "Test-OrchestrationDoneCompliance -TaskClass trivial -Decision DIRECT_VERIFIED -ExecutionShape DIRECT_VERIFIED -DirectReason $directReason"
            return (& $mkResult 'DIRECT_VERIFIED' 'trivial' $directReason @() '' 'OK' $checkDirect)
        }

        # #201-fatia2: router/registry health gates explicit SINGLE_WORKER
        # delegation and all non-trivial worker routing below, never the direct
        # route above. A non-empty strategy other than DIRECT_VERIFIED (including
        # explicit SINGLE_WORKER) stays delegated and is gated here too.
        if (-not (Test-OrchestrationRouterHealth -Healthy $RouterHealthy -RegistryFresh $RegistryFresh -RegistryOk $RegistryOk)) {
            if (-not $RouterHealthy) {
                return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'router_unavailable' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
            }
            if (-not $RegistryFresh) {
                return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'registry_stale' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
            }
            return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'router_unhealthy' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
        }

        if ($isTrivial) {
            $swAgents = @(Get-OrchestrationSelectedAgents -TaskType $tt -Domain $dom -Objective $obj -SecondaryDomains $sec)
            if (@($swAgents).Count -eq 0) { $swAgents = @('coder') }
            return (& $mkResult 'SINGLE_WORKER' 'trivial' '' @($swAgents) '' 'OK' $checkSingle)
        }

        $agents = @(Get-OrchestrationSelectedAgents -TaskType $tt -Domain $dom -Objective $obj -SecondaryDomains $sec)
        if (@($agents).Count -eq 0) { $agents = @('coder') }
        # Pre-decision only plans: compliance requires the post-execution
        # DONE gate (Test-OrchestrationDoneCompliance) with observed workers.
        return (& $mkResult 'MULTI_WORKER' 'non_trivial' '' @($agents) '' 'UNVERIFIED_POST_EXECUTION_REQUIRED' $checkMulti)
    }
    catch {
        return [PSCustomObject]@{
            orchestration_decision = 'DETERMINISTIC_FALLBACK'
            task_class             = 'non_trivial'
            direct_reason          = ''
            selected_agents        = @()
            fallback_reason        = 'preflight_internal_error'
            bypass_verdict         = 'PENDING_DETERMINISTIC_OWNER'
            post_execution_check   = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision DETERMINISTIC_FALLBACK -DeterministicOwnerExecuted $<owner_ran>'
        }
    }
}
