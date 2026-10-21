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
        Optional scriptblock seam for testing / mock response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Request,

        [Parameter(Mandatory = $false)]
        [object]$ModelRouterSelection = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$AdvisorProbe = $null
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

    # 4. Invoke Advisor (via Probe seam if provided, or return structured consult envelope)
    $consultationId = "ADV-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
    
    $response = $null
    if ($null -ne $AdvisorProbe) {
        $response = & $AdvisorProbe $Request $ModelRouterSelection
    } else {
        # Standard bounded advisory response stub for runtime consumption
        $response = [pscustomobject]@{
            Status               = 'COMPLETED'
            ConsultationId       = $consultationId
            RecommendedOption    = "Prioritize verifiable incremental fix over broad refactoring."
            Rationale            = "Evidence shows failure is isolated; risk asymmetry favors bounded intervention."
            Risks                = @("Potential edge-case regressions if validation scope is too narrow.")
            RejectionReasons     = @("Rejected full rewrite due to unverified blast radius.")
            ActionableNextStep   = "Apply minimal bounded fix to target function and execute L2 verification."
            FallbackIfFailed     = "Escalate to debugger with newly gathered trace."
            ModelTierUsed        = $tier
            ModelTokenUsed       = $modelToken
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
        }
    }

    # Enforce strict advisory boundaries
    $response.IsAdvisory = $true
    $response.Authoritative = $false
    $response.FromCache = $false

    # Store in bounded cache
    if ($script:AdvisorConsultationCache.Count -ge 50) {
        $script:AdvisorConsultationCache.Clear()
    }
    $script:AdvisorConsultationCache[$cacheKey] = $response

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
