<#
.SYNOPSIS
    Intelligent Advisor Escalation Library (Issue #60, Addendum 2026-10-21).
.DESCRIPTION
    Dot-sourceable library (no execution on load).
    Implements demand-driven escalation from the stable economical Planner (T2/T3)
    to the specialized Engineering Advisor (T2/T3/T4) based on 7 concrete signals.
    Enforces structured consultation contracts, short-lived bounded caching to eliminate
    redundant LLM calls, and strict read-only advisory boundaries.
    The Advisor never issues DONE, never spawns subagents, and never mutates Kernel state.
    PowerShell 5.1 and 7+ compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# The 7 concrete escalation signals
$script:AdvisorValidEscalationSignals = @(
    'consequential_alternatives',
    'repeated_failure_no_new_info',
    'conflicting_evidence',
    'reasoning_gap',
    'complex_cross_component_decision',
    'verified_deadlock',
    'risk_asymmetry'
)

# In-memory bounded cache for advisor consultations: Key -> Response object
if ($null -eq $script:AdvisorConsultationCache) {
    $script:AdvisorConsultationCache = @{}
}

function Test-AdvisorEscalationSignal {
    <#
    .SYNOPSIS
        Validates whether a trigger signal meets the concrete criteria for Advisor escalation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Signal,

        [Parameter(Mandatory = $false)]
        [string]$Justification = '',

        [Parameter(Mandatory = $false)]
        [bool]$InformationMissing = $false
    )

    $cleanSignal = $Signal.Trim().ToLowerInvariant()

    # Rule: Missing information must be retrieved via T0/T2 exploration, not by escalating to Advisor
    if ($InformationMissing) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Information or context is missing. Must retrieve evidence via T0/T2 tools before escalating to Advisor."
            Signal   = $cleanSignal
        }
    }

    # Rule: Escalating purely because complexity is 'complex' is strictly prohibited
    if ($cleanSignal -in @('complex', 'high_complexity', 'task_is_complex')) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Anti-pattern prohibited: Cannot escalate to Advisor solely because task is complex. Requires one of the 7 concrete signals."
            Signal   = $cleanSignal
        }
    }

    if ($script:AdvisorValidEscalationSignals -notcontains $cleanSignal) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Signal '$cleanSignal' is not an allowlisted escalation trigger. Must be one of: $($script:AdvisorValidEscalationSignals -join ', ')."
            Signal   = $cleanSignal
        }
    }

    if ([string]::IsNullOrWhiteSpace($Justification) -or $Justification.Trim().Length -lt 10) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Escalation requires a non-empty factual justification (minimum 10 characters)."
            Signal   = $cleanSignal
        }
    }

    return [pscustomobject]@{
        Admitted = $true
        Reason   = "Escalation signal '$cleanSignal' validated."
        Signal   = $cleanSignal
    }
}

function Get-AdvisorField($obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $default
    }
    $prop = $obj.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $default
}

function Test-OrchestrationOpenCodeAuthenticated {
    <#
    .SYNOPSIS
        Verifica se ha provedores autenticados no OpenCode (env vars, auth.json ou auth list).
    .DESCRIPTION
        Nao depende exclusivamente de variaveis de ambiente e nao expoe segredos.
    #>
    [CmdletBinding()]
    param()

    # 1. Variaveis de ambiente explicitas
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENCODE_GO_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
        return $true
    }

    # 2. Arquivo auth.json local do OpenCode
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        $authPath = Join-Path (Join-Path (Join-Path $homeDir '.local') 'share\opencode') 'auth.json'
        if (Test-Path -LiteralPath $authPath -PathType Leaf) {
            try {
                if ((Get-Item -LiteralPath $authPath).Length -gt 5) {
                    return $true
                }
            } catch { }
        }
    }

    # 3. CLI auth list se disponivel
    try {
        $authLines = @(opencode auth list 2>&1)
        if ($authLines.Count -gt 0 -and ($authLines -match 'stored' -or $authLines -match 'environment')) {
            return $true
        }
    } catch { }

    return $false
}

function Get-OrchestrationSessionHostEvidence {
    <#
    .SYNOPSIS
        Extrai evidencias de execucao real de uma sessao nativa via opencode session export.
    .DESCRIPTION
        Coleta SessionId, Agent, ModelEffective, Tokens, Cost e Outcome reais do host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionId,

        [Parameter(Mandatory = $false)]
        [string]$OpencodeBin = ''
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }

    $bin = if (-not [string]::IsNullOrWhiteSpace($OpencodeBin)) { $OpencodeBin } else { 'opencode' }
    try {
        $raw = & $bin session export --sanitize $SessionId 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match 'error:') { return $null }
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        if ($null -eq $parsed -or $null -eq $parsed.info) { return $null }

        $effModel = $null
        if ($parsed.info.model) {
            $pId = [string]$parsed.info.model.providerID
            $mId = [string]$parsed.info.model.id
            $effModel = if (-not [string]::IsNullOrWhiteSpace($pId) -and -not [string]::IsNullOrWhiteSpace($mId)) { "$pId/$mId" } else { $mId }
        }

        $assistantText = ''
        if ($parsed.messages) {
            foreach ($msg in @($parsed.messages)) {
                if ($msg.type -eq 'assistant' -and -not [string]::IsNullOrWhiteSpace([string]$msg.text)) {
                    $assistantText = [string]$msg.text
                }
            }
        }

        $tokensIn = 0; $tokensOut = 0; $tokensReas = 0
        if ($parsed.info.tokens) {
            try { $tokensIn = [int]$parsed.info.tokens.input } catch { }
            try { $tokensOut = [int]$parsed.info.tokens.output } catch { }
            try { $tokensReas = [int]$parsed.info.tokens.reasoning } catch { }
        }
        $costUsd = 0.0
        try { $costUsd = [double]$parsed.info.cost } catch { }

        return [pscustomobject]@{
            SessionId        = [string]$parsed.info.id
            Agent            = [string]$parsed.info.agent
            Outcome          = [string]$parsed.info.outcome
            EffectiveModel   = $effModel
            TokensInput      = $tokensIn
            TokensOutput     = $tokensOut
            TokensReasoning  = $tokensReas
            CostUsd          = $costUsd
            AssistantMessage = $assistantText
            RawError         = if ($parsed.info.outcome -eq 'failed') { "Session outcome reported failed" } else { $null }
        }
    } catch {
        return $null
    }
}

function Get-AdvisorConsultationCacheKey {
    <#
    .SYNOPSIS
        Computes a deterministic SHA256 cache key from bounded consultation inputs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [string]$Signal,

        [Parameter(Mandatory = $true)]
        [string]$Question,

        [Parameter(Mandatory = $false)]
        [string]$HeadSha = ''
    )

    $canonicalString = "task:$($TaskId.Trim().ToLowerInvariant())|signal:$($Signal.Trim().ToLowerInvariant())|q:$($Question.Trim().ToLowerInvariant())|head:$($HeadSha.Trim().ToLowerInvariant())"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalString)
    $hashBytes = $hasher.ComputeHash($bytes)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $hashBytes) {
        [void]$sb.Append($b.ToString("x2"))
    }
    return $sb.ToString()
}

function Get-OrchestrationNativeAdvisorExecutor {
    <#
    .SYNOPSIS
        Returns the native OpenCode V2 executor for engineering-advisor consultations.
    .DESCRIPTION
        Reutiliza a infraestrutura de execucao nativa do OpenCode V2 sem duplicar dispatchers.
        Se o ambiente nativo estiver indisponivel, falha fechado com PROOF_ABSENT.
        Registra SessionId, Agent, ModelRequested, ModelEffective e ResponseRef.
    #>
    [CmdletBinding()]
    param()

    return {
        param($Req, $ModelSel)

        $taskId = [string](Get-AdvisorField $Req 'task_id' 'advisor-task')
        $question = [string](Get-AdvisorField $Req 'question' '')
        $context = [string](Get-AdvisorField $Req 'context_summary' '')
        $justification = [string](Get-AdvisorField $Req 'justification' '')
        $reqModel = if ($ModelSel) { [string]$ModelSel.CatalogModel } else { 'MODEL_STRONG' }
        $reqTier = if ($ModelSel) { [string]$ModelSel.Tier } else { 'T3' }

        # 1. Checagem de disponibilidade do runtime nativo OpenCode V2
        $opencodeBin = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$env:OPENCODE_BIN) -and (Test-Path -LiteralPath ([string]$env:OPENCODE_BIN) -PathType Leaf)) {
            $opencodeBin = [string]$env:OPENCODE_BIN
        } else {
            $cmd = Get-Command opencode -ErrorAction SilentlyContinue
            if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
                $opencodeBin = [string]$cmd.Source
            }
        }

        $consultationId = "ADV-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"

        if ([string]::IsNullOrWhiteSpace($opencodeBin)) {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
                ConsultationId       = $consultationId
                SessionId            = $null
                Agent                = 'engineering-advisor'
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "Native OpenCode binary unavailable. Proof of execution absent."
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'NONE'
            }
        }

        # 2. Checagem de disponibilidade de provider/credencial para o modelo solicitado
        $isAuth = Test-OrchestrationOpenCodeAuthenticated
        if (-not $isAuth) {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'MODEL_PROVIDER_CREDENTIAL_ABSENT'
                ConsultationId       = $consultationId
                SessionId            = $null
                Agent                = 'engineering-advisor'
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "No active model provider credentials detected via environment or auth storage. Execution unperformed."
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'NONE'
            }
        }

        # 3. Timeout configuravel (default 30s, sem timeout rigido de 10s)
        $timeoutMs = 30000
        $reqTimeout = Get-AdvisorField $Req 'timeout_ms' $null
        if ($null -ne $reqTimeout -and [int]$reqTimeout -gt 0) {
            $timeoutMs = [int]$reqTimeout
        } else {
            $budgetSec = Get-AdvisorField $Req 'budget_seconds' $null
            if ($null -ne $budgetSec -and [int]$budgetSec -gt 0) {
                $timeoutMs = [int]($budgetSec * 1000)
            }
        }

        # 4. Resolucao de sessao nativa: reaproveita sessao pai do Planner se disponivel;
        #    se nova sessao, NAO inventa ID falso (evita corromper storage do OpenCode).
        $parentSession = Get-AdvisorField $Req 'parent_session_id' $null
        if ([string]::IsNullOrWhiteSpace($parentSession) -and -not [string]::IsNullOrWhiteSpace($env:OPENCODE_SESSION_ID)) {
            $parentSession = [string]$env:OPENCODE_SESSION_ID
        }

        # 5. Execucao nativa quando binario e credenciais disponiveis
        try {
            $prompt = @"
[CONSULTATION: $consultationId]
TASK: $taskId
QUESTION: $question
JUSTIFICATION: $justification
CONTEXT: $context
"@
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $opencodeBin
            $argParts = @('run', '--agent', 'engineering-advisor', '--model', "`"$reqModel`"", '--title', "`"Advisor: $consultationId`"")
            if (-not [string]::IsNullOrWhiteSpace($parentSession)) {
                $argParts += @('--session', "`"$parentSession`"")
            }
            $safePrompt = $prompt.Replace('"', '\"')
            $argParts += "`"$safePrompt`""
            $psi.Arguments = ($argParts -join ' ')
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $completed = $proc.WaitForExit($timeoutMs)

            if (-not $completed) {
                try { $proc.Kill() } catch { }
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_DISPATCH_TIMEOUT'
                    ConsultationId       = $consultationId
                    SessionId            = $parentSession
                    Agent                = 'engineering-advisor'
                    ModelRequested       = $reqModel
                    ModelEffective       = $null
                    ResponseRef          = $null
                    RecommendedOption    = $null
                    Rationale            = "Native advisor execution exceeded bounded timeout of $($timeoutMs)ms."
                    Risks                = @()
                    RejectionReasons     = @()
                    ActionableNextStep   = $null
                    ModelTierUsed        = $reqTier
                    ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                    IsAdvisory           = $true
                    Authoritative        = $false
                    FromCache            = $false
                    ExecutionProofType   = 'NONE'
                }
            }

            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $exitCode = $proc.ExitCode
            $combinedOutput = "$stdout`n$stderr".Trim()

            if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($combinedOutput)) {
                # Tentar extrair session ID e telemetria real do host via session export
                $targetSessionId = $parentSession
                if ([string]::IsNullOrWhiteSpace($targetSessionId) -and $combinedOutput -match '(?i)session[:\s]+([a-zA-Z0-9_-]+)') {
                    $targetSessionId = $matches[1]
                }

                $hostEvidence = if (-not [string]::IsNullOrWhiteSpace($targetSessionId)) {
                    Get-OrchestrationSessionHostEvidence -SessionId $targetSessionId -OpencodeBin $opencodeBin
                } else { $null }

                $effModel = if ($null -ne $hostEvidence -and -not [string]::IsNullOrWhiteSpace($hostEvidence.EffectiveModel)) {
                    $hostEvidence.EffectiveModel
                } else {
                    $null
                }

                $proofType = if ($null -ne $effModel) { 'NATIVE_OPENCODE_V2' } else { 'PARTIAL' }

                return [pscustomobject]@{
                    Status               = 'COMPLETED'
                    Reason               = 'NATIVE_DISPATCH_EXECUTED'
                    ConsultationId       = $consultationId
                    SessionId            = if ($hostEvidence) { $hostEvidence.SessionId } else { $targetSessionId }
                    Agent                = 'engineering-advisor'
                    ModelRequested       = $reqModel
                    ModelEffective       = $effModel
                    ResponseRef          = "resp-$consultationId"
                    RecommendedOption    = $combinedOutput
                    Rationale            = "Native execution via OpenCode V2 engineering-advisor."
                    Risks                = @()
                    RejectionReasons     = @()
                    ActionableNextStep   = "Follow recommendation from engineering-advisor."
                    ModelTierUsed        = $reqTier
                    ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                    IsAdvisory           = $true
                    Authoritative        = $false
                    FromCache            = $false
                    ExecutionProofType   = $proofType
                    TokensInput          = if ($hostEvidence) { $hostEvidence.TokensInput } else { 0 }
                    TokensOutput         = if ($hostEvidence) { $hostEvidence.TokensOutput } else { 0 }
                    CostUsd              = if ($hostEvidence) { $hostEvidence.CostUsd } else { 0.0 }
                }
            } else {
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_EXECUTION_FAILED_OR_NO_OUTPUT'
                    ConsultationId       = $consultationId
                    SessionId            = $parentSession
                    Agent                = 'engineering-advisor'
                    ModelRequested       = $reqModel
                    ModelEffective       = $null
                    ResponseRef          = $null
                    RecommendedOption    = $null
                    Rationale            = "OpenCode process exited with code $exitCode or produced empty output."
                    Risks                = @()
                    RejectionReasons     = @()
                    ActionableNextStep   = $null
                    ModelTierUsed        = $reqTier
                    ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                    IsAdvisory           = $true
                    Authoritative        = $false
                    FromCache            = $false
                    ExecutionProofType   = 'NONE'
                }
            }
        } catch {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
                ConsultationId       = $consultationId
                SessionId            = $sessionId
                Agent                = 'engineering-advisor'
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "Exception during native dispatch: $($_.Exception.Message)"
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'DISPATCH_EXCEPTION'
            }
        }
    }
}

function Invoke-AdvisorConsultation {
    <#
    .SYNOPSIS
        Orchestrates bounded consultation to engineering-advisor with contract validation and caching.
    .PARAMETER Request
        Hashtable or PSObject containing:
          - task_id (string)
          - trigger_signal (string)
          - justification (string)
          - question (string)
          - context_summary (string)
          - alternatives_evaluated (array)
          - constraints (array)
          - known_evidence (array)
          - head_sha (string)
    .PARAMETER ModelRouterSelection
        Selection object from Resolve-OrchestrationModelSelection for engineering-advisor.
    .PARAMETER AdvisorProbe
        Optional scriptblock seam for testing / simulated probe (strictly separated from production).
    .PARAMETER NativeExecutor
        Optional scriptblock seam for native execution override.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Request,

        [Parameter(Mandatory = $false)]
        [object]$ModelRouterSelection = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$AdvisorProbe = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$NativeExecutor = $null
    )

    function Get-Field($obj, [string]$name, $default = $null) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] }
            return $default
        }
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
        return $default
    }

    $taskId = [string](Get-Field $Request 'task_id' 'unknown-task')
    $signal = [string](Get-Field $Request 'trigger_signal' '')
    $justification = [string](Get-Field $Request 'justification' '')
    $question = [string](Get-Field $Request 'question' '')
    $contextSummary = [string](Get-Field $Request 'context_summary' '')
    $alternatives = @(Get-Field $Request 'alternatives_evaluated' @())
    $constraints = @(Get-Field $Request 'constraints' @())
    $knownEvidence = @(Get-Field $Request 'known_evidence' @())
    $headSha = [string](Get-Field $Request 'head_sha' '')
    $infoMissing = [bool](Get-Field $Request 'information_missing' $false)

    # 1. Validate Escalation Trigger
    $signalCheck = Test-AdvisorEscalationSignal -Signal $signal -Justification $justification -InformationMissing $infoMissing
    if (-not $signalCheck.Admitted) {
        return [pscustomobject]@{
            Status               = 'REJECTED'
            ConsultationId       = "ADV-ERR-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            SessionId            = $null
            Agent                = 'engineering-advisor'
            ModelRequested       = $null
            ModelEffective       = $null
            ResponseRef          = $null
            RejectionReason      = $signalCheck.Reason
            RecommendedOption    = $null
            ActionableNextStep   = 'Retrieve missing evidence or formulate concrete escalation signal.'
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
        }
    }

    # 2. Check Cache
    $cacheKey = Get-AdvisorConsultationCacheKey -TaskId $taskId -Signal $signal -Question $question -HeadSha $headSha
    if ($script:AdvisorConsultationCache.ContainsKey($cacheKey)) {
        $cached = $script:AdvisorConsultationCache[$cacheKey]
        $cached.FromCache = $true
        return $cached
    }

    # 3. Resolve Model Tier if not provided
    if ($null -eq $ModelRouterSelection) {
        $routerLib = Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1'
        if (Test-Path -LiteralPath $routerLib) {
            . $routerLib
            $ModelRouterSelection = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex'
        }
    }

    $tier = if ($ModelRouterSelection) { $ModelRouterSelection.Tier } else { 'T3' }
    $modelToken = if ($ModelRouterSelection) { $ModelRouterSelection.ModelToken } else { 'MODEL_STRONG' }
    $modelCatalog = if ($ModelRouterSelection) { [string]$ModelRouterSelection.CatalogModel } else { 'openai/gpt-6.1-sol' }

    # 4. Invoke Advisor:
    #    (a) AdvisorProbe seam if provided (strictly for harness tests)
    #    (b) NativeExecutor seam if provided
    #    (c) Default native executor via OpenCode V2
    #    (d) If unexecutable, fail-closed with PROOF_ABSENT envelope
    $consultationId = "ADV-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
    
    $response = $null
    if ($null -ne $AdvisorProbe) {
        # Strict separation: test probes are executed here only
        $response = & $AdvisorProbe $Request $ModelRouterSelection
    } elseif ($null -ne $NativeExecutor) {
        $response = & $NativeExecutor $Request $ModelRouterSelection
    } else {
        # Attempt default native executor
        $defaultExec = Get-OrchestrationNativeAdvisorExecutor
        if ($null -ne $defaultExec) {
            $response = & $defaultExec $Request $ModelRouterSelection
        }
    }

    if ($null -eq $response) {
        # Standalone runtime without native execution: fail-closed with PROOF_ABSENT.
        # Fabricated recommendations are never returned as real consultations.
        $response = [pscustomobject]@{
            Status               = 'PROOF_ABSENT'
            Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
            ConsultationId       = $consultationId
            SessionId            = $null
            Agent                = 'engineering-advisor'
            ModelRequested       = $modelCatalog
            ModelEffective       = $null
            ResponseRef          = $null
            RecommendedOption    = $null
            Rationale            = "Native dispatch of engineering-advisor not executed or proof absent."
            Risks                = @()
            RejectionReasons     = @()
            ActionableNextStep   = $null
            FallbackIfFailed     = $null
            ModelTierUsed        = $tier
            ModelTokenUsed       = $modelToken
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
            ExecutionProofType   = 'PROOF_ABSENT'
        }
    }

    # Enforce strict advisory boundaries
    $response.IsAdvisory = $true
    $response.Authoritative = $false
    $response.FromCache = $false

    # Store in bounded cache (only completed consultations are cached)
    if ($response.Status -eq 'COMPLETED') {
        if ($script:AdvisorConsultationCache.Count -ge 50) {
            $script:AdvisorConsultationCache.Clear()
        }
        $script:AdvisorConsultationCache[$cacheKey] = $response
    }

    return $response
}

function Clear-AdvisorConsultationCache {
    <#
    .SYNOPSIS
        Clears the in-memory advisor consultation cache.
    #>
    [CmdletBinding()]
    param()
    $script:AdvisorConsultationCache.Clear()
}
