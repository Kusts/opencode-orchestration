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
        $sessionId = "sess-adv-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

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
        $hasKey = (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_API_KEY) -or `
                   -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY) -or `
                   -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or `
                   -not [string]::IsNullOrWhiteSpace($env:OPENCODE_GO_API_KEY))

        if (-not $hasKey) {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'MODEL_PROVIDER_CREDENTIAL_ABSENT'
                ConsultationId       = $consultationId
                SessionId            = $sessionId
                Agent                = 'engineering-advisor'
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "No active model provider API key detected in environment. Execution unperformed."
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

        # 3. Execucao nativa quando binario e credenciais disponiveis (com timeout estrito de 10s)
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
            $psi.Arguments = "run --agent engineering-advisor --model `"$reqModel`" --session `"$sessionId`" `"$prompt`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $completed = $proc.WaitForExit(10000)

            if (-not $completed) {
                try { $proc.Kill() } catch { }
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_DISPATCH_TIMEOUT'
                    ConsultationId       = $consultationId
                    SessionId            = $sessionId
                    Agent                = 'engineering-advisor'
                    ModelRequested       = $reqModel
                    ModelEffective       = $null
                    ResponseRef          = $null
                    RecommendedOption    = $null
                    Rationale            = "Native advisor execution exceeded bounded timeout of 10000ms."
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
                return [pscustomobject]@{
                    Status               = 'COMPLETED'
                    Reason               = 'NATIVE_DISPATCH_EXECUTED'
                    ConsultationId       = $consultationId
                    SessionId            = $sessionId
                    Agent                = 'engineering-advisor'
                    ModelRequested       = $reqModel
                    ModelEffective       = $reqModel
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
                    ExecutionProofType   = 'NATIVE_OPENCODE_V2'
                }
            } else {
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_EXECUTION_FAILED_OR_NO_OUTPUT'
                    ConsultationId       = $consultationId
                    SessionId            = $sessionId
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
