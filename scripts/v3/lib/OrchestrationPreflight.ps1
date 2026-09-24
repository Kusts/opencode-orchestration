<#!
.SYNOPSIS
    V3 mandatory orchestration preflight (canonical): trivial/direct vs delegated vs deterministic fallback.
.DESCRIPTION
    Dot-sourceable library (no execution on load). Decides BEFORE any
    delegation whether the Planner may act directly (trivial) or must
    delegate (non-trivial), or must take a deterministic fallback
    (underspecified task, hard exclusion, unhealthy router, stale
    registry). Never executes MCP, never loads skills, never changes
    authority/allowlist/permissions/flags/registry. Telemetry uses
    tokens only (no free text). PowerShell 5.1. ASCII-only. Never throws
    on operational paths (fail-safe => DETERMINISTIC_FALLBACK).

    Contract split (review-hardened):
      - PRE-decision (Get-OrchestrationPreflight): plans only. DELEGATED
        carries bypass_verdict=UNVERIFIED_POST_EXECUTION_REQUIRED and a
        post_execution_check hint; it never attests compliance.
      - POST-verdict (Test-OrchestrationDoneCompliance): the DONE gate,
        called with OBSERVED worker participation / deterministic-owner
        execution. Only COMPLIANT here allows a compliant DONE claim.
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
    return @(
        'DIRECT_TRIVIAL_LOCALIZED',
        'DIRECT_READ_ONLY_POINT_LOOKUP',
        'DIRECT_COSMETIC_NO_LOGIC',
        'DIRECT_FORMATTING_ONLY'
    )
}

function Test-OrchestrationDirectReason {
    [CmdletBinding()]
    param([string]$Reason)
    try {
        $s = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        $allowed = @(Get-OrchestrationDirectTokens)
        foreach ($a in $allowed) { if ($s -ceq $a) { return $true } }
    }
    catch { }
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
        Porta de DONE: verificacao POS-execucao. A pre-decision (DELEGATED,
        DETERMINISTIC_FALLBACK) apenas planeja; somente esta funcao, chamada
        com a participacao real observada, pode atestar compliance.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskClass = '',
        [string]$Decision = '',
        [int]$ActualWorkerParticipation = 0,
        [bool]$DeterministicOwnerExecuted = $false,
        [string]$DirectReason = ''
    )
    try {
        $c = ([string]$TaskClass).Trim().ToLowerInvariant()
        $d = ([string]$Decision).Trim().ToUpperInvariant()
        if ($d -ceq 'BLOCKED') { return 'ORCHESTRATION_POLICY_BYPASS' }
        if ($c -cne 'non_trivial') {
            if ([string]::IsNullOrWhiteSpace($DirectReason)) { return 'NON_COMPLIANT_MISSING_DIRECT_REASON' }
            if (-not (Test-OrchestrationDirectReason -Reason $DirectReason)) { return 'NON_COMPLIANT_INVALID_DIRECT_REASON' }
            return 'COMPLIANT'
        }
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

function Get-OrchestrationDirectReasonToken {
    [CmdletBinding()]
    param([string]$Objective = '', [string]$TaskType = '')
    try {
        $blob = Convert-OrchestrationNormalizedText -Text (([string]$Objective) + ' ' + ([string]$TaskType))
        if ($blob.Contains('format')) { return 'DIRECT_FORMATTING_ONLY' }
        if ((Test-OrchestrationKeyword -Blob $blob -Words @('typo', 'cosmet', 'cosmetic', 'typos'))) { return 'DIRECT_COSMETIC_NO_LOGIC' }
        $tt = ([string]$TaskType).Trim().ToLowerInvariant()
        if (($tt -ceq 'lookup') -or ($tt -ceq 'read') -or (Test-OrchestrationKeyword -Blob $blob -Words @('lookup', 'point lookup', 'leitura pontual', 'small read', 'where defined', 'where is'))) { return 'DIRECT_READ_ONLY_POINT_LOOKUP' }
        return 'DIRECT_TRIVIAL_LOCALIZED'
    }
    catch { return 'DIRECT_TRIVIAL_LOCALIZED' }
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
        [string[]]$Allowlist
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

        $checkDelegated = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision DELEGATED -ActualWorkerParticipation <actual_workers>'
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

        if (-not (Test-OrchestrationRouterHealth -Healthy $RouterHealthy -RegistryFresh $RegistryFresh -RegistryOk $RegistryOk)) {
            if (-not $RouterHealthy) {
                return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'router_unavailable' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
            }
            if (-not $RegistryFresh) {
                return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'registry_stale' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
            }
            return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'router_unhealthy' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
        }

        if (Test-OrchestrationVague -Objective $obj -TaskType $tt -Domain $dom -Risk $rk -ReadWrite $rw) {
            return (& $mkResult 'DETERMINISTIC_FALLBACK' 'non_trivial' '' @() 'vague_task_underspecified' 'PENDING_DETERMINISTIC_OWNER' $checkFallback)
        }

        $isTrivial = $false
        try {
            $lenOk = (($objTrim.Length -gt 0) -and ($objTrim.Length -le 140))
            $riskOk = ($rk -ceq 'low')
            $rwOk = ($rw -ceq 'read')
            # Triviality requires an EXPLICIT trivial work-type; prose words
            # only corroborate (they pick the token) and never establish it.
            $typeOk = (($tt -ceq 'trivial') -or ($tt -ceq 'lookup') -or ($tt -ceq 'read') -or ($tt -ceq 'cosmetic') -or ($tt -ceq 'formatting'))
            $localizedOk = (@($sec).Count -le 1)
            $archHit = Test-OrchestrationArchitectureDecision -Objective $obj -TaskType $tt -Domain $dom
            if ($lenOk -and $riskOk -and $rwOk -and $typeOk -and $localizedOk -and (-not $archHit)) { $isTrivial = $true }
        }
        catch { $isTrivial = $false }

        if ($isTrivial) {
            $tok = Get-OrchestrationDirectReasonToken -Objective $obj -TaskType $tt
            return (& $mkResult 'TRIVIAL_DIRECT' 'trivial' $tok @() '' 'OK')
        }

        $agents = @(Get-OrchestrationSelectedAgents -TaskType $tt -Domain $dom -Objective $obj -SecondaryDomains $sec)
        if (@($agents).Count -eq 0) { $agents = @('coder') }
        # Pre-decision only plans: compliance requires the post-execution
        # DONE gate (Test-OrchestrationDoneCompliance) with observed workers.
        return (& $mkResult 'DELEGATED' 'non_trivial' '' @($agents) '' 'UNVERIFIED_POST_EXECUTION_REQUIRED' $checkDelegated)
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
