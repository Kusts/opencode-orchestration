<#
.SYNOPSIS
    Orchestration Model Router vNext: dynamic model tier resolution by task and risk.
.DESCRIPTION
    Dot-sourceable library (no execution on load).
    Implements model tier selection (T0..T4) and admissibility matrix for all 19 agents
    as defined in docs/specs/MODEL-ROUTER-vNext-SPEC.md (Issues #99, #102, #146).
    Replaces static model binding with adaptive tier resolution based on task complexity,
    risk level, prior worker failures, and safety constraints.
    Supports fail-closed fallback when model parameter capability lacks operational proof.
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Define standard model tiers
$script:ModelTiers = @{
    'T0' = @{ Name = 'Deterministic'; RelativeCost = 0.0;  Description = 'Scripts, AST, ArtifactRef, deterministic execution' }
    'T1' = @{ Name = 'UltraLight';    RelativeCost = 0.01; Description = 'Free/micro models, simple extraction or triage' }
    'T2' = @{ Name = 'Economical';    RelativeCost = 0.10; Description = 'Flash/cheap models, standard coding and routine tasks' }
    'T3' = @{ Name = 'Capable';       RelativeCost = 1.00; Description = 'Intermediate capable models, complex refactoring and design' }
    'T4' = @{ Name = 'Frontier';      RelativeCost = 8.00; Description = 'Deep reasoning/frontier models, deadlocks and critical security' }
}

# Admissibility Matrix by agent role
$script:AgentModelAdmissibility = @{
    'build' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T2', 'T3')
        ProhibitedTiers  = @('T4')
        ProhibitionNotes = 'Continuous T4 prohibited for Planner loop to prevent token exhaustion; rotation prohibited.'
    }
    'engineering-advisor' = @{
        DefaultTier      = 'T3'
        AdmissibleTiers  = @('T2', 'T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1')
        ProhibitionNotes = 'Advisor requires at least T2 for technical clarity; T0/T1 lacks reasoning capability.'
    }
    'coder' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T1', 'T2', 'T3', 'T4')
        ProhibitedTiers  = @()
        ProhibitionNotes = 'T4 prohibited without prior demonstrated failure + debugger escalation.'
    }
    'explorer' = @{
        DefaultTier      = 'T1'
        AdmissibleTiers  = @('T0', 'T1', 'T2')
        ProhibitedTiers  = @('T3', 'T4')
        ProhibitionNotes = 'Repository navigation and reading does not justify intermediate or frontier models.'
    }
    'researcher' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T1', 'T2', 'T3')
        ProhibitedTiers  = @('T4')
        ProhibitionNotes = 'Synthesis and web/code research does not justify T4.'
    }
    'tester' = @{
        DefaultTier      = 'T0'
        AdmissibleTiers  = @('T0', 'T1', 'T2')
        ProhibitedTiers  = @('T3', 'T4')
        ProhibitionNotes = 'Executing test suites must use T0 (exit codes) or T2 (test authoring); T3/T4 prohibited.'
    }
    'reviewer' = @{
        DefaultTier      = 'T3'
        AdmissibleTiers  = @('T2', 'T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1')
        ProhibitionNotes = 'Review requires independent semantic scrutiny; T0/T1 prohibited. T2 prohibited for HIGH/CRITICAL risk.'
    }
    'debugger' = @{
        DefaultTier      = 'T3'
        AdmissibleTiers  = @('T2', 'T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1')
        ProhibitionNotes = 'Root cause investigation requires at least T2. T4 prohibited for obvious syntax/stacktrace.'
    }
    'security-reviewer' = @{
        DefaultTier      = 'T3'
        AdmissibleTiers  = @('T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1', 'T2')
        ProhibitionNotes = 'Security verification cannot be degraded to economical tiers; T0, T1 and T2 strictly prohibited.'
    }
    'architect' = @{
        DefaultTier      = 'T3'
        AdmissibleTiers  = @('T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1', 'T2')
        ProhibitionNotes = 'System architecture and boundary definition requires capable reasoning; T0/T1/T2 prohibited.'
    }
    'docs-manager' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T0', 'T1', 'T2')
        ProhibitedTiers  = @('T3', 'T4')
        ProhibitionNotes = 'Documentation updates do not justify T3/T4.'
    }
    'frontend-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T1', 'T2', 'T3')
        ProhibitedTiers  = @('T4')
        ProhibitionNotes = 'Frontend implementation does not justify T4 without explicit high-risk waiver.'
    }
    'backend-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T2', 'T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1')
        ProhibitionNotes = 'Backend business logic requires at least T2. T4 prohibited for standard CRUD.'
    }
    'database-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T2', 'T3', 'T4')
        ProhibitedTiers  = @('T0', 'T1')
        ProhibitionNotes = 'Database schema and migrations require at least T2. T1/T2 prohibited for destructive migrations.'
    }
    'infra-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T0', 'T2', 'T3')
        ProhibitedTiers  = @('T4')
        ProhibitionNotes = 'Infrastructure automation does not justify T4.'
    }
    'ai-agent-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T2', 'T3')
        ProhibitedTiers  = @('T0', 'T1', 'T4')
        ProhibitionNotes = 'Agent prompting and wiring requires balanced T2/T3.'
    }
    'automation-engineer' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T0', 'T1', 'T2')
        ProhibitedTiers  = @('T3', 'T4')
        ProhibitionNotes = 'Routine automation scripts do not justify T3/T4.'
    }
    'requirements-analyst' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T1', 'T2', 'T3')
        ProhibitedTiers  = @('T0', 'T4')
        ProhibitionNotes = 'Requirements decomposition does not justify T4.'
    }
    'skeptic' = @{
        DefaultTier      = 'T2'
        AdmissibleTiers  = @('T2', 'T3')
        ProhibitedTiers  = @('T0', 'T1', 'T4')
        ProhibitionNotes = 'Critique role operates in balanced T2/T3.'
    }
}

function Resolve-OrchestrationModelSelection {
    <#
    .SYNOPSIS
        Selects model tier and token for an agent based on task criteria and safety invariants.
    .PARAMETER AgentName
        Canonical agent role name (e.g. coder, reviewer, engineering-advisor).
    .PARAMETER Risk
        Task risk level: low, medium, high, critical. Default is medium.
    .PARAMETER Complexity
        Task complexity: trivial, simple, medium, complex. Default is medium.
    .PARAMETER FailureCount
        Number of previous failed attempts on this task. Default is 0.
    .PARAMETER IsTrivialDirect
        Whether the task is running via DIRECT_VERIFIED (Tier T0).
    .PARAMETER NativeModelOverrideProven
        Whether native OpenCode V2 supports model parameter in subagent tool calls.
        Default is $false (fail-closed fallback to standard template token).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AgentName,

        [Parameter(Mandatory = $false)]
        [ValidateSet('low', 'medium', 'high', 'critical')]
        [string]$Risk = 'medium',

        [Parameter(Mandatory = $false)]
        [ValidateSet('trivial', 'simple', 'medium', 'complex')]
        [string]$Complexity = 'medium',

        [Parameter(Mandatory = $false)]
        [int]$FailureCount = 0,

        [Parameter(Mandatory = $false)]
        [bool]$IsTrivialDirect = $false,

        [Parameter(Mandatory = $false)]
        [bool]$NativeModelOverrideProven = $false
    )

    $cleanAgent = $AgentName.Trim().ToLowerInvariant()
    if (-not $script:AgentModelAdmissibility.ContainsKey($cleanAgent)) {
        return [pscustomobject]@{
            Status           = 'REJECTED'
            Reason           = "Unknown or unregistered agent: '$cleanAgent'"
            Agent            = $cleanAgent
            Tier             = $null
            ModelToken       = $null
            FallbackTier     = 'T2'
            FallbackToken    = 'MODEL_CHEAP'
            IsCompliant      = $false
        }
    }

    $admissibility = $script:AgentModelAdmissibility[$cleanAgent]
    $admissibleTiers = @($admissibility.AdmissibleTiers)
    $prohibitedTiers = @($admissibility.ProhibitedTiers)

    # DIRECT_VERIFIED bypass: execution without model / subagent
    if ($IsTrivialDirect) {
        return [pscustomobject]@{
            Status                    = 'SELECTED'
            Agent                     = $cleanAgent
            Tier                      = 'T0'
            TierName                  = 'Deterministic'
            ModelToken                = 'NONE_DIRECT_VERIFIED'
            AdmissibleTiers           = @('T0')
            SelectionReason           = 'Task is trivial, local and low-risk. Running via DIRECT_VERIFIED without model tokens.'
            EstimatedCostMultiplier   = 0.0
            FallbackTier              = 'T0'
            FallbackToken             = 'NONE_DIRECT_VERIFIED'
            NativeModelOverrideProven = $NativeModelOverrideProven
            IsCompliant               = $true
        }
    }

    # Dynamic tier selection logic
    $selectedTier = $admissibility.DefaultTier
    $reason = "Default tier '$selectedTier' for agent '$cleanAgent'."

    if ($cleanAgent -eq 'reviewer') {
        if ($Risk -in @('high', 'critical')) {
            $selectedTier = 'T4'
            $reason = "Elevated to T4 due to $Risk risk on reviewer role."
        } elseif ($Risk -eq 'low' -and $Complexity -in @('trivial', 'simple')) {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 admitted for low-risk, simple review."
        } else {
            $selectedTier = 'T3'
            $reason = "Standard capable tier T3 for medium review."
        }
    }
    elseif ($cleanAgent -eq 'security-reviewer') {
        if ($Risk -in @('high', 'critical') -or $Complexity -eq 'complex') {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 selected for high/critical security review."
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for standard security review."
        }
    }
    elseif ($cleanAgent -eq 'engineering-advisor') {
        if ($FailureCount -ge 2 -or $Complexity -eq 'complex') {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 selected for deadlock consult or complex advisor query."
        } elseif ($Complexity -in @('trivial', 'simple') -and $Risk -eq 'low') {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 selected for simple technical clarity check."
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for standard engineering feasibility consultation."
        }
    }
    elseif ($cleanAgent -eq 'coder') {
        if ($FailureCount -ge 2 -and $Complexity -eq 'complex') {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 escalated after $FailureCount prior failures on complex task."
        } elseif ($Complexity -eq 'complex' -or $FailureCount -eq 1) {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for complex coding or retry."
        } else {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 default for routine coder."
        }
    }
    elseif ($cleanAgent -eq 'debugger') {
        if ($FailureCount -ge 2 -or $Risk -in @('high', 'critical')) {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 escalated for persistent bug after $FailureCount failures."
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 for root-cause debugging."
        }
    }

    # Strict safety invariant check: ensure selected tier is admissible
    if ($admissibleTiers -notcontains $selectedTier -or $prohibitedTiers -contains $selectedTier) {
        # Fallback to default tier
        $selectedTier = $admissibility.DefaultTier
        $reason = "Requested tier was prohibited. Fallen back to admissible default '$selectedTier'."
    }

    # Security check: security-reviewer NEVER T1 or T2
    if ($cleanAgent -eq 'security-reviewer' -and $selectedTier -in @('T0', 'T1', 'T2')) {
        $selectedTier = 'T3'
        $reason = "Security invariant enforced: security-reviewer forced to T3 minimum."
    }

    # Coder T4 check: coder NEVER T4 without prior failure
    if ($cleanAgent -eq 'coder' -and $selectedTier -eq 'T4' -and $FailureCount -lt 2) {
        $selectedTier = 'T3'
        $reason = "Cost invariant enforced: coder prohibited from T4 without at least 2 demonstrated failures."
    }

    # Resolve token name
    $modelToken = if ($selectedTier -in @('T3', 'T4')) { 'MODEL_STRONG' } else { 'MODEL_CHEAP' }
    $tierMeta = $script:ModelTiers[$selectedTier]

    # Handle native override proof
    # If native subagent model override is NOT proven, we must inform caller
    # and provide conservative fallback token for standard template resolution
    $effectiveToken = $modelToken
    $overrideNote = ''
    if (-not $NativeModelOverrideProven) {
        $overrideNote = 'Native subagent model parameter unproven in OpenCode V2. Using conservative template token fallback.'
    }

    return [pscustomobject]@{
        Status                    = 'SELECTED'
        Agent                     = $cleanAgent
        Tier                      = $selectedTier
        TierName                  = $tierMeta.Name
        ModelToken                = $effectiveToken
        AdmissibleTiers           = $admissibleTiers
        SelectionReason           = $reason
        EstimatedCostMultiplier   = $tierMeta.RelativeCost
        FallbackTier              = $admissibility.DefaultTier
        FallbackToken             = if ($admissibility.DefaultTier -in @('T3', 'T4')) { 'MODEL_STRONG' } else { 'MODEL_CHEAP' }
        NativeModelOverrideProven = $NativeModelOverrideProven
        OverrideNote              = $overrideNote
        IsCompliant               = $true
    }
}
