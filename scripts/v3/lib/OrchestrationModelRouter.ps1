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

# Standard Model Catalog mapping tiers to catalog definitions and default authorization
$script:DefaultModelCatalog = @{
    'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)';                    Authorized = $true }
    'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode/beam-free';                     Authorized = $true }
    'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Authorized = $true }
    'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6.1-sol';                      Authorized = $true }
    'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6.1-sol-fast';                 Authorized = $false } # T4 requires explicit cost authorization
}

function Get-OrchestrationUserConfigCatalog {
    <#
    .SYNOPSIS
        Discovers effective models from user configuration (models.jsonc / models.json / env).
    .DESCRIPTION
        Reads effective model catalog from:
          1. -ConfigPath if provided
          2. models.jsonc / models.json in current directory or ~/.config/opencode/
          3. Environment variables (MODEL_PLANNER, MODEL_CHEAP, MODEL_STRONG, MODEL_FRONTIER)
          4. Fallback to documented defaults from models.example.jsonc
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = ''
    )

    $cat = @{
        'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)';                    Authorized = $true }
        'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode/beam-free';                     Authorized = $true }
        'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Authorized = $true }
        'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6.1-sol';                      Authorized = $true }
        'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6.1-sol-fast';                 Authorized = $false }
    }

    $candPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $candPaths += $ConfigPath }
    $candPaths += (Join-Path (Get-Location) 'models.jsonc')
    $candPaths += (Join-Path (Get-Location) 'models.json')
    if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
        $candPaths += (Join-Path (Join-Path ([string]$env:USERPROFILE) '.config\opencode') 'models.jsonc')
        $candPaths += (Join-Path (Join-Path ([string]$env:USERPROFILE) '.config\opencode') 'models.json')
    }

    foreach ($p in $candPaths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
                # Strip simple // comments if jsonc
                $jsonText = $raw -replace '(?m)^\s*//.*$', ''
                $parsed = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
                if ($null -ne $parsed) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.free)) {
                        $cat['T1'].CatalogModel = [string]$parsed.free
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.cheap)) {
                        $cat['T2'].CatalogModel = [string]$parsed.cheap
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.strong)) {
                        $cat['T3'].CatalogModel = [string]$parsed.strong
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$parsed.frontier)) {
                        $cat['T4'].CatalogModel = [string]$parsed.frontier
                    }
                    break
                }
            } catch { }
        }
    }

    # Environment overrides
    if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_FREE))     { $cat['T1'].CatalogModel = [string]$env:MODEL_FREE }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_CHEAP))    { $cat['T2'].CatalogModel = [string]$env:MODEL_CHEAP }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_STRONG))   { $cat['T3'].CatalogModel = [string]$env:MODEL_STRONG }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_FRONTIER)) { $cat['T4'].CatalogModel = [string]$env:MODEL_FRONTIER }

    # Cost authorization flag from environment
    if ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true') {
        $cat['T4'].Authorized = $true
    }

    return $cat
}

function Resolve-CatalogModel {
    <#
    .SYNOPSIS
        Resolves catalog model entry, token and authorization for a requested tier.
    .DESCRIPTION
        Separates technical admissibility from provider/cost authorization.
        T4 is NEVER authorized merely by task risk or failure count; explicit cost authorization is required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tier,

        [Parameter(Mandatory = $false)]
        $Catalog = $null,

        [Parameter(Mandatory = $false)]
        [int]$FailureCount = 0,

        [Parameter(Mandatory = $false)]
        [string]$Risk = 'medium',

        [Parameter(Mandatory = $false)]
        [bool]$ProviderCostAuthorized = $false
    )

    $cat = if ($null -ne $Catalog) { $Catalog } else { Get-OrchestrationUserConfigCatalog }
    $entry = if ($cat.ContainsKey($Tier)) { $cat[$Tier] } else { $cat['T2'] }

    $token = [string]$entry.Token
    $catModel = [string]$entry.CatalogModel
    $authorized = [bool]$entry.Authorized

    # Strict separation of technical admissibility vs provider/cost authorization:
    # High risk or repeated failures justify T4 technically, but cost authorization MUST be explicit.
    if ($Tier -eq 'T4') {
        if ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true')) {
            $authorized = $true
        } else {
            # Never authorize T4 solely by risk or failure count
            $authorized = $false
        }
    }

    return [pscustomobject]@{
        Tier                   = $Tier
        ModelToken             = $token
        CatalogModel           = $catModel
        IsAuthorized           = $authorized
        ProviderCostAuthorized = ($authorized -or $ProviderCostAuthorized)
        FallbackTier           = if ($Tier -eq 'T4' -and -not $authorized) { 'T3' } else { $Tier }
    }
}

function Test-ExecutedModelVerification {
    <#
    .SYNOPSIS
        Verifies whether the actual executed model matches the requested model routing.
    .DESCRIPTION
        Fails closed: if NativeModelOverrideProven is false or no proof of dynamic override exists,
        flags that the runtime tier is unproven and records PROOF_ABSENT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $RequestedSelection,

        [Parameter(Mandatory = $false)]
        $ExecutedModelEvent = $null,

        [Parameter(Mandatory = $false)]
        [bool]$NativeModelOverrideProven = $false
    )

    $reqTier = [string]$RequestedSelection.Tier
    $reqModel = [string]$RequestedSelection.CatalogModel
    $reqToken = [string]$RequestedSelection.ModelToken

    if (-not $NativeModelOverrideProven) {
        return [pscustomobject]@{
            VerifiedMatch       = $false
            ProofStatus         = 'PROOF_ABSENT'
            RuntimeTierProven   = $false
            Reason              = 'Native dynamic model override unproven in current runtime. Falling back to host template configuration.'
            RequestedTier       = $reqTier
            EffectiveTier       = [string]$RequestedSelection.FallbackTier
            EffectiveModelToken = [string]$RequestedSelection.FallbackToken
        }
    }

    if ($null -eq $ExecutedModelEvent) {
        return [pscustomobject]@{
            VerifiedMatch       = $false
            ProofStatus         = 'EXECUTION_UNVERIFIED'
            RuntimeTierProven   = $false
            Reason              = 'No executed model event or telemetry provided for verification.'
            RequestedTier       = $reqTier
            EffectiveTier       = $null
            EffectiveModelToken = $null
        }
    }

    $actModel = [string]$ExecutedModelEvent.Model
    if ([string]::IsNullOrWhiteSpace($actModel)) {
        $actModel = [string]$ExecutedModelEvent.model
    }

    $isMatch = ($actModel -eq $reqModel -or $actModel -eq $reqToken)

    return [pscustomobject]@{
        VerifiedMatch       = $isMatch
        ProofStatus         = if ($isMatch) { 'VERIFIED_MATCH' } else { 'TIER_MISMATCH' }
        RuntimeTierProven   = $isMatch
        Reason              = if ($isMatch) { 'Executed model matches requested tier.' } else { "Executed model '$actModel' does not match requested model '$reqModel'." }
        RequestedTier       = $reqTier
        EffectiveTier       = if ($isMatch) { $reqTier } else { 'UNKNOWN' }
        EffectiveModelToken = $actModel
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
    .PARAMETER ModelCatalog
        Optional catalog mapping tier to model definitions.
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
        [bool]$NativeModelOverrideProven = $false,

        [Parameter(Mandatory = $false)]
        [bool]$ProviderCostAuthorized = $false,

        [Parameter(Mandatory = $false)]
        $ModelCatalog = $null
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
            EffectiveModelToken       = 'NONE_DIRECT_VERIFIED'
            CatalogModel              = 'none (deterministic)'
            AuthorizedSelection       = $true
            RuntimeTierProven         = $true
            ProofStatus               = 'PROVEN_DIRECT_VERIFIED'
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
        if ($Risk -in @('high', 'critical') -and ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true'))) {
            $selectedTier = 'T4'
            $reason = "Elevated to T4 due to $Risk risk on reviewer role with explicit cost authorization."
        } elseif ($Risk -eq 'low' -and $Complexity -in @('trivial', 'simple')) {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 admitted for low-risk, simple review."
        } else {
            $selectedTier = 'T3'
            $reason = "Standard capable tier T3 for review."
        }
    }
    elseif ($cleanAgent -eq 'security-reviewer') {
        if ($Risk -in @('high', 'critical') -and ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true'))) {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 selected for high/critical security review with explicit cost authorization."
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for standard security review."
        }
    }
    elseif ($cleanAgent -eq 'engineering-advisor') {
        if ($FailureCount -ge 2 -and ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true'))) {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 selected for deadlock consult after $FailureCount prior failures with explicit cost authorization."
        } elseif ($Complexity -in @('trivial', 'simple') -and $Risk -eq 'low') {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 selected for simple technical clarity check."
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for standard engineering feasibility consultation."
        }
    }
    elseif ($cleanAgent -eq 'coder') {
        if ($FailureCount -ge 2) {
            $selectedTier = 'T4'
            $reason = "Frontier tier T4 escalated after $FailureCount prior failures."
        } elseif ($FailureCount -eq 1 -or $Complexity -eq 'complex') {
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

    # Catalog and authorization check: separate technical justification from explicit cost authorization
    $catalogRes = Resolve-CatalogModel -Tier $selectedTier -Catalog $ModelCatalog -FailureCount $FailureCount -Risk $Risk -ProviderCostAuthorized $ProviderCostAuthorized
    if (-not $catalogRes.IsAuthorized) {
        $degradedTier = if ($selectedTier -eq 'T4') { 'T3' } else { $admissibility.DefaultTier }
        $reason = "Tier '$($catalogRes.Tier)' was unauthorized (cost/provider authorization absent). Degraded to '$degradedTier'."
        $selectedTier = $degradedTier
        $catalogRes = Resolve-CatalogModel -Tier $selectedTier -Catalog $ModelCatalog -FailureCount $FailureCount -Risk $Risk -ProviderCostAuthorized $ProviderCostAuthorized
    }

    # Resolve token name directly from resolved catalog entry (no reduction to cheap/strong pool)
    $modelToken = [string]$catalogRes.ModelToken
    $tierMeta = $script:ModelTiers[$selectedTier]

    $fallbackDefaultTier = $admissibility.DefaultTier
    $fallbackDefaultToken = switch ($fallbackDefaultTier) {
        'T4' { 'MODEL_FRONTIER' }
        'T3' { 'MODEL_STRONG' }
        'T1' { 'MODEL_FREE' }
        default { 'MODEL_CHEAP' }
    }

    # Handle native override proof
    # If native subagent model override is NOT proven, we inform caller
    # and provide conservative fallback token for standard template resolution
    $effectiveToken = if ($NativeModelOverrideProven) { $modelToken } else { $fallbackDefaultToken }
    $overrideNote = ''
    $proofStatus = if ($NativeModelOverrideProven) { 'PROVEN' } else { 'PROOF_ABSENT' }
    $runtimeTierProven = [bool]$NativeModelOverrideProven

    if (-not $NativeModelOverrideProven) {
        $overrideNote = 'Native subagent model parameter unproven in OpenCode V2. Using conservative template token fallback.'
    }

    return [pscustomobject]@{
        Status                    = 'SELECTED'
        Agent                     = $cleanAgent
        Tier                      = $selectedTier
        TierName                  = $tierMeta.Name
        ModelToken                = $modelToken
        EffectiveModelToken       = $effectiveToken
        CatalogModel              = $catalogRes.CatalogModel
        AuthorizedSelection       = $catalogRes.IsAuthorized
        RuntimeTierProven         = $runtimeTierProven
        ProofStatus               = $proofStatus
        AdmissibleTiers           = $admissibleTiers
        SelectionReason           = $reason
        EstimatedCostMultiplier   = $tierMeta.RelativeCost
        FallbackTier              = $fallbackDefaultTier
        FallbackToken             = $fallbackDefaultToken
        NativeModelOverrideProven = $NativeModelOverrideProven
        OverrideNote              = $overrideNote
        IsCompliant               = $true
    }
}
