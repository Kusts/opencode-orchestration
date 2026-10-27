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
    'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)';                    Provider = 'none';        Authorized = $true }
    'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode-go/beam-free';                  Provider = 'opencode-go'; Authorized = $true }
    'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Provider = 'opencode-go'; Authorized = $true; AlternativeModel = 'openai/gpt-6-luna' }
    'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6-luna';                      Provider = 'openai';      Authorized = $true; AlternativeModel = 'openai/gpt-6.1-terra' }
    'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6.1-sol';                      Provider = 'openai';      Authorized = $false; ExceptionalModel = 'openai/gpt-6-astra' }
}

$script:CachedRoutingPolicy = $null

function Get-ModelProviderFromId {
    <#
    .SYNOPSIS
        Determines the canonical provider string for a given model ID.
    #>
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return 'unknown' }
    $m = $ModelId.Trim().ToLowerInvariant()
    if ($m.StartsWith('opencode-go/')) { return 'opencode-go' }
    if ($m.StartsWith('opencode/')) { return 'opencode' }
    if ($m.StartsWith('openai/')) { return 'openai' }
    if ($m.StartsWith('jev-') -or $m.Contains('systemone')) { return 'opencode' }
    if ($m -in @('none', 'none (deterministic)', 'none_direct_verified')) { return 'none' }
    return 'unknown'
}

function Get-OrchestrationModelRoutingPolicy {
    <#
    .SYNOPSIS
        Loads the canonical model routing policy registry (source/registry/model-routing-policy.json).
    .DESCRIPTION
        Returns the parsed policy object, including PolicyHash (SHA256) and policy metadata.
        Caches policy in session memory to eliminate redundant IO.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$PolicyPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$ForceReload = $false
    )

    if (-not $ForceReload -and $null -ne $script:CachedRoutingPolicy -and [string]::IsNullOrWhiteSpace($PolicyPath)) {
        return $script:CachedRoutingPolicy
    }

    $candPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
        $candPaths += $PolicyPath
    }
    if ($PSScriptRoot) {
        $candPaths += (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\source\registry') -ErrorAction SilentlyContinue) 'model-routing-policy.json')
    }
    $candPaths += (Join-Path (Get-Location) 'source\registry\model-routing-policy.json')

    $resolvedPath = $null
    foreach ($cp in $candPaths) {
        if (-not [string]::IsNullOrWhiteSpace($cp) -and (Test-Path -LiteralPath $cp -PathType Leaf)) {
            $resolvedPath = $cp
            break
        }
    }

    if ($null -eq $resolvedPath) {
        return [pscustomobject]@{
            Status        = 'POLICY_MISSING'
            PolicyHash    = ''
            PolicyVersion = '1.2.0'
            Policy        = $null
        }
    }

    try {
        $rawBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($rawBytes)
        $hashStr = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

        $rawText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
        $parsed = ConvertFrom-Json -InputObject $rawText -ErrorAction Stop

        $res = [pscustomobject]@{
            Status        = 'POLICY_LOADED'
            PolicyPath    = $resolvedPath
            PolicyHash    = $hashStr
            PolicyVersion = if ($parsed.policy_version) { [string]$parsed.policy_version } else { '1.2.0' }
            Policy        = $parsed
        }

        if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
            $script:CachedRoutingPolicy = $res
        }
        return $res
    }
    catch {
        return [pscustomobject]@{
            Status        = 'POLICY_INVALID'
            PolicyPath    = $resolvedPath
            PolicyHash    = ''
            PolicyVersion = 'unknown'
            Policy        = $null
            Error         = $_.Exception.Message
        }
    }
}

function Get-OrchestrationUserConfigCatalog {
    <#
    .SYNOPSIS
        Discovers effective models from user configuration (models.jsonc / models.json / env / policy registry).
    .DESCRIPTION
        Reads effective model catalog from:
          1. -ConfigPath if provided
          2. Canonical policy registry source/registry/model-routing-policy.json
          3. models.jsonc / models.json in current directory or ~/.config/opencode/
          4. Environment variables (MODEL_PLANNER, MODEL_CHEAP, MODEL_STRONG, MODEL_FRONTIER)
          5. Fallback to documented defaults from models.example.jsonc
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = '',

        [Parameter(Mandatory = $false)]
        [string]$PolicyPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$IgnoreUserConfig = $false,

        [Parameter(Mandatory = $false)]
        [Alias('RequiresVisual', 'VisualTask', 'Visual', 'NeedsVisualAnalysis')]
        [bool]$RequiresVisualAnalysis = $false,

        [Parameter(Mandatory = $false)]
        [Alias('Capability', 'Capabilities')]
        [string]$RequiredCapability = ''
    )

    $policyRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
    $pol = if ($policyRes.Status -eq 'POLICY_LOADED') { $policyRes.Policy } else { $null }

    $mBeam = if ($null -ne $pol -and $pol.models.beam) { [string]$pol.models.beam.model_id } else { 'opencode-go/beam-free' }
    $mMuse = if ($null -ne $pol -and $pol.models.muse) { [string]$pol.models.muse.model_id } else { 'opencode-go/muse-spark-1.3-contributor' }
    $mTerra = if ($null -ne $pol -and $pol.models.terra) { [string]$pol.models.terra.model_id } else { 'openai/gpt-6.1-terra' }
    $mLuna = if ($null -ne $pol -and $pol.models.luna) { [string]$pol.models.luna.model_id } else { 'openai/gpt-6-luna' }
    $mSol = if ($null -ne $pol -and $pol.models.sol) { [string]$pol.models.sol.model_id } else { 'openai/gpt-6.1-sol' }
    $mAstra = if ($null -ne $pol -and $pol.models.astra) { [string]$pol.models.astra.model_id } else { 'openai/gpt-6-astra' }

    $cat = @{
        'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)';                    Provider = 'none';        Authorized = $true }
        'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = $mBeam;                                   Provider = (Get-ModelProviderFromId $mBeam); Authorized = $true }
        'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = $mMuse;                                   Provider = (Get-ModelProviderFromId $mMuse); Authorized = $true; AlternativeModel = $mLuna }
        'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = $mLuna;                                   Provider = 'openai';      Authorized = $true; AlternativeModel = $mTerra }
        'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = $mSol;                                    Provider = 'openai';      Authorized = $false; ExceptionalModel = $mAstra }
    }

    if (-not $IgnoreUserConfig) {
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
                            $cat['T1'].Provider = Get-ModelProviderFromId ([string]$parsed.free)
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$parsed.cheap)) {
                            $cat['T2'].CatalogModel = [string]$parsed.cheap
                            $cat['T2'].Provider = Get-ModelProviderFromId ([string]$parsed.cheap)
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$parsed.strong)) {
                            $cat['T3'].CatalogModel = [string]$parsed.strong
                            $cat['T3'].Provider = Get-ModelProviderFromId ([string]$parsed.strong)
                        }
                        if (-not [string]::IsNullOrWhiteSpace([string]$parsed.frontier)) {
                            $cat['T4'].CatalogModel = [string]$parsed.frontier
                            $cat['T4'].Provider = Get-ModelProviderFromId ([string]$parsed.frontier)
                        }
                        break
                    }
                } catch { }
            }
        }

        # Environment overrides
        if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_FREE)) {
            $cat['T1'].CatalogModel = [string]$env:MODEL_FREE
            $cat['T1'].Provider = Get-ModelProviderFromId ([string]$env:MODEL_FREE)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_CHEAP)) {
            $cat['T2'].CatalogModel = [string]$env:MODEL_CHEAP
            $cat['T2'].Provider = Get-ModelProviderFromId ([string]$env:MODEL_CHEAP)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_STRONG)) {
            $cat['T3'].CatalogModel = [string]$env:MODEL_STRONG
            $cat['T3'].Provider = Get-ModelProviderFromId ([string]$env:MODEL_STRONG)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:MODEL_FRONTIER)) {
            $cat['T4'].CatalogModel = [string]$env:MODEL_FRONTIER
            $cat['T4'].Provider = Get-ModelProviderFromId ([string]$env:MODEL_FRONTIER)
        }
    }

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
        T4 and Astra are NEVER authorized merely by task risk or failure count; explicit cost authorization is required.
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
        [bool]$ProviderCostAuthorized = $false,

        [Parameter(Mandatory = $false)]
        [string]$PolicyPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$IgnoreUserConfig = $false,

        [Parameter(Mandatory = $false)]
        [Alias('RequiresVisual', 'VisualTask', 'Visual', 'NeedsVisualAnalysis')]
        [bool]$RequiresVisualAnalysis = $false,

        [Parameter(Mandatory = $false)]
        [Alias('Capability', 'Capabilities')]
        [string]$RequiredCapability = ''
    )

    $cat = if ($null -ne $Catalog) { $Catalog } else { Get-OrchestrationUserConfigCatalog -PolicyPath $PolicyPath -IgnoreUserConfig $IgnoreUserConfig }
    $entry = if ($cat.ContainsKey($Tier)) { $cat[$Tier] } else { $cat['T2'] }

    $token = [string]$entry.Token
    $catModel = [string]$entry.CatalogModel
    $provider = if ($entry.Provider) { [string]$entry.Provider } else { Get-ModelProviderFromId $catModel }
    $authorized = [bool]$entry.Authorized
    $authSource = 'STANDARD_CATALOG'
    $authEvidence = 'catalog:default'
    $budget = if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_T4_BUDGET_USD)) { [string]$env:OPENCODE_T4_BUDGET_USD } else { 'standard_tier_budget' }

    $policyRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
    $polHash = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyHash } else { '' }
    $polVer = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyVersion } else { '1.2.0' }

    # Strict separation of technical admissibility vs provider/cost authorization:
    # High risk or repeated failures justify T4 technically, but cost authorization MUST be explicit.
    # Exceptional Astra check: Astra strictly requires OPENCODE_ASTRA_AUTHORIZED='true',
    # and general T4 cost authorization alone does NOT authorize Astra.
    if ($Tier -eq 'T4') {
        if ($catModel -match 'astra') {
            $astraAuth = ([string]$env:OPENCODE_ASTRA_AUTHORIZED -ieq 'true')
            if ($astraAuth) {
                $authorized = $true
                $authSource = 'GLOBAL_ENV_OPENCODE_ASTRA_AUTHORIZED'
                $authEvidence = 'env:OPENCODE_ASTRA_AUTHORIZED=true'
            } else {
                $authorized = $false
                $authSource = 'ASTRA_EXCEPTIONAL_BUDGET_REQUIRED'
                $authEvidence = 'none'
            }
        } elseif ($ProviderCostAuthorized) {
            $authorized = $true
            $authSource = 'EXPLICIT_PARAMETER'
            $authEvidence = 'parameter:ProviderCostAuthorized=true'
        } elseif ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true') {
            $authorized = $true
            $authSource = 'GLOBAL_ENV_OPENCODE_T4_AUTHORIZED'
            $authEvidence = 'env:OPENCODE_T4_AUTHORIZED=true'
        } else {
            # Never authorize T4 solely by risk or failure count
            $authorized = $false
            $authSource = 'NONE_UNAUTHORIZED'
            $authEvidence = 'none'
        }
    } elseif ($catModel -match 'astra') {
        $astraAuth = ([string]$env:OPENCODE_ASTRA_AUTHORIZED -ieq 'true')
        if ($astraAuth) {
            $authorized = $true
            $authSource = 'GLOBAL_ENV_OPENCODE_ASTRA_AUTHORIZED'
            $authEvidence = 'env:OPENCODE_ASTRA_AUTHORIZED=true'
        } else {
            $authorized = $false
            $authSource = 'ASTRA_EXCEPTIONAL_BUDGET_REQUIRED'
            $authEvidence = 'none'
        }
    }

    $candidates = switch ($Tier) {
        'T1' { @('opencode-go/beam-free') }
        'T2' { @('opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna') }
        'T3' { @('openai/gpt-6-luna', 'openai/gpt-6.1-terra', 'openai/gpt-6.1-sol') }
        'T4' { @('openai/gpt-6.1-sol', 'openai/gpt-6-astra') }
        default { @('none (deterministic)') }
    }

    return [pscustomobject]@{
        Tier                      = $Tier
        ModelToken                = $token
        CatalogModel              = $catModel
        Provider                  = $provider
        IsAuthorized              = $authorized
        ProviderCostAuthorized    = $authorized
        CostAuthorizationSource   = $authSource
        CostAuthorizationEvidence = $authEvidence
        CostBudget                = $budget
        FallbackTier              = if ($Tier -eq 'T4' -and -not $authorized) { 'T3' } else { $Tier }
        FallbackCandidates        = $candidates
        PolicyHash                = $polHash
        PolicyVersion             = $polVer
    }
}

function Resolve-OrchestrationModelFallback {
    <#
    .SYNOPSIS
        Resolves an authorized fallback model when a requested model encounters rate limits or provider errors.
    .DESCRIPTION
        Enforces router policy:
          - Consults agent admissibility matrix.
          - Strictly prohibits downgrades for Reviewer and Security-Reviewer when violating policy.
          - Checks cost authorization for T4 and exceptional budget for Astra.
          - Excludes already attempted models to prevent cyclic loops.
          - Tracks cross-provider transitions (opencode, opencode-go, openai).
          - When no permitted model is available, returns a structured recoverable status.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $RequestedSelection,

        [Parameter(Mandatory = $false)]
        [string]$FailedModel = '',

        [Parameter(Mandatory = $false)]
        [string]$TriggerReason = 'RATE_LIMIT',

        [Parameter(Mandatory = $false)]
        [string[]]$AttemptedModels = @(),

        [Parameter(Mandatory = $false)]
        [bool]$ProviderCostAuthorized = $false,

        [Parameter(Mandatory = $false)]
        $ModelCatalog = $null,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedProviders = @(),

        [Parameter(Mandatory = $false)]
        [bool]$IgnoreUserConfig = $false,

        [Parameter(Mandatory = $false)]
        [string]$PolicyPath = ''
    )

    $ignoreUser = $IgnoreUserConfig
    if ($RequestedSelection -and $RequestedSelection.PSObject.Properties['IgnoreUserConfig'] -and $RequestedSelection.IgnoreUserConfig) {
        $ignoreUser = $true
    }

    $agent = [string]$RequestedSelection.Agent
    if ([string]::IsNullOrWhiteSpace($agent)) {
        $agent = [string]$RequestedSelection.AgentName
    }
    $cleanAgent = if (-not [string]::IsNullOrWhiteSpace($agent)) { $agent.Trim().ToLowerInvariant() } else { 'coder' }
    $reqTier = [string]$RequestedSelection.Tier
    $reqModel = [string]$RequestedSelection.CatalogModel
    $origModel = if (-not [string]::IsNullOrWhiteSpace($FailedModel)) { $FailedModel } else { $reqModel }
    $origProvider = Get-ModelProviderFromId $origModel

    # 1. Carrega politica dinamica canonica
    $polResult = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
    $policy = if ($polResult -and $polResult.Status -eq 'POLICY_LOADED') { $polResult.Policy } else { $null }

    # 2. Tracking estrito de modelos realmente tentados (passados em AttemptedModels ou FailedModel)
    $reallyAttempted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $AttemptedModels) {
        foreach ($m in $AttemptedModels) {
            if (-not [string]::IsNullOrWhiteSpace($m)) { [void]$reallyAttempted.Add($m.Trim()) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FailedModel)) {
        [void]$reallyAttempted.Add($FailedModel.Trim())
    }

    # Tracking de exclusoes preventivas (candidatos descartados antes de qualquer tentativa)
    $preventivelyExcluded = [System.Collections.Generic.List[PSCustomObject]]::new()
    $RecordExclusion = {
        param([string]$Model, [string]$Tier, [string]$Reason)
        if ([string]::IsNullOrWhiteSpace($Model)) { return }
        $already = $preventivelyExcluded | Where-Object { $_.Model -eq $Model -and $_.Reason -eq $Reason }
        if (-not $already) {
            $preventivelyExcluded.Add([pscustomobject]@{
                Model  = $Model
                Tier   = $Tier
                Reason = $Reason
            })
        }
    }

    # Determina autorizacao de custo para T4
    $costAuth = ($ProviderCostAuthorized -or ($reqTier -eq 'T4' -and [bool]$RequestedSelection.ProviderCostAuthorized) -or [string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true')

    # Admissibilidade estrita por papel do agente
    $admiss = if ($script:AgentModelAdmissibility.ContainsKey($cleanAgent)) { $script:AgentModelAdmissibility[$cleanAgent] } else { $null }

    # Funcao para obter candidatos dinamicos por tier a partir da politica efetiva
    $GetDynamicCandidatesForTier = {
        param([string]$TargetTier)
        $cands = [System.Collections.Generic.List[PSCustomObject]]::new()

        if ($null -ne $policy -and $null -ne $policy.models) {
            foreach ($prop in $policy.models.PSObject.Properties) {
                $m = $prop.Value
                if ($null -eq $m) { continue }
                $mId = [string]$m.model_id
                if ([string]::IsNullOrWhiteSpace($mId)) { continue }

                $profiles = @($m.tier_profiles)
                if ($profiles -notcontains $TargetTier) { continue }

                $cands.Add([pscustomobject]@{
                    ModelId       = $mId
                    LogicalId     = [string]$m.id
                    Provider      = [string]$m.provider
                    Enabled       = [bool]$m.enabled
                    Priority      = if ($null -ne $m.priority) { [int]$m.priority } else { 99 }
                    EligibleRoles = @($m.eligible_roles)
                    RequiresCost  = [bool]($m.cost_profile.requires_authorization)
                    Exceptional   = [bool]($m.cost_profile.exceptional_budget_required)
                    Tier          = $TargetTier
                })
            }
        } else {
            # Fallback defensivo a partir do script:DefaultModelCatalog se a politica JSON nao puder ser lida
            if ($script:DefaultModelCatalog.ContainsKey($TargetTier)) {
                $entry = $script:DefaultModelCatalog[$TargetTier]
                if ($entry.CatalogModel -and $entry.CatalogModel -notmatch 'none') {
                    $cands.Add([pscustomobject]@{
                        ModelId       = [string]$entry.CatalogModel
                        LogicalId     = [string]$entry.CatalogModel
                        Provider      = [string]$entry.Provider
                        Enabled       = $true
                        Priority      = 1
                        EligibleRoles = @()
                        RequiresCost  = ($TargetTier -eq 'T4')
                        Exceptional   = $false
                        Tier          = $TargetTier
                    })
                }
                if ($entry.AlternativeModel) {
                    $cands.Add([pscustomobject]@{
                        ModelId       = [string]$entry.AlternativeModel
                        LogicalId     = [string]$entry.AlternativeModel
                        Provider      = Get-ModelProviderFromId $entry.AlternativeModel
                        Enabled       = $true
                        Priority      = 2
                        EligibleRoles = @()
                        RequiresCost  = $false
                        Exceptional   = $false
                        Tier          = $TargetTier
                    })
                }
                if ($entry.ExceptionalModel) {
                    $cands.Add([pscustomobject]@{
                        ModelId       = [string]$entry.ExceptionalModel
                        LogicalId     = [string]$entry.ExceptionalModel
                        Provider      = Get-ModelProviderFromId $entry.ExceptionalModel
                        Enabled       = $true
                        Priority      = 2
                        EligibleRoles = @()
                        RequiresCost  = $true
                        Exceptional   = $true
                        Tier          = $TargetTier
                    })
                }
            }
        }

        # Incorporacao de modelo customizado do catalogo do usuario se houver e nao estiver ignorando
        if (-not $ignoreUser) {
            $cat = if ($null -ne $ModelCatalog) { $ModelCatalog } else { Get-OrchestrationUserConfigCatalog }
            if ($null -ne $cat -and $cat.ContainsKey($TargetTier) -and -not [string]::IsNullOrWhiteSpace($cat[$TargetTier].CatalogModel)) {
                $userModel = [string]$cat[$TargetTier].CatalogModel
                $exists = $cands | Where-Object { $_.ModelId -eq $userModel }
                if (-not $exists) {
                    $cands.Add([pscustomobject]@{
                        ModelId       = $userModel
                        LogicalId     = $userModel
                        Provider      = (Get-ModelProviderFromId $userModel)
                        Enabled       = $true
                        Priority      = 50
                        EligibleRoles = @()
                        RequiresCost  = ($TargetTier -eq 'T4')
                        Exceptional   = ($userModel -match 'astra')
                        Tier          = $TargetTier
                    })
                }
            }
        }

        return @($cands | Sort-Object Priority)
    }

    # Avaliacao de candidatos contra regras da politica efetiva
    $EvaluateCandidate = {
        param([pscustomobject]$CandObj)
        $mId = $CandObj.ModelId
        $tier = $CandObj.Tier

        # 1. Se ja foi realmente tentado (em AttemptedModels ou FailedModel)
        if ($reallyAttempted.Contains($mId)) {
            & $RecordExclusion $mId $tier 'ALREADY_ATTEMPTED'
            return $null
        }

        # 2. Se e o modelo original que falhou nesta rodada ou requisitado diretamente
        if ($mId -eq $origModel -or ($reallyAttempted.Count -eq 0 -and $mId -eq $reqModel)) {
            & $RecordExclusion $mId $tier 'CURRENT_REQUESTED_MODEL'
            return $null
        }

        # 3. Se o modelo esta administrativamente desabilitado na politica
        if (-not $CandObj.Enabled) {
            & $RecordExclusion $mId $tier 'MODEL_DISABLED'
            return $null
        }

        # 4. Se o provider esta administrativamente desabilitado na politica
        if ($null -ne $policy -and $null -ne $policy.providers) {
            $provProp = $policy.providers.PSObject.Properties[$CandObj.Provider]
            if ($null -ne $provProp -and $null -ne $provProp.Value -and $provProp.Value.enabled -eq $false) {
                & $RecordExclusion $mId $tier 'PROVIDER_DISABLED'
                return $null
            }
        }

        # 5. Se AllowedProviders foi informado e nao inclui o provider do candidato
        if ($null -ne $AllowedProviders -and $AllowedProviders.Count -gt 0) {
            if ($AllowedProviders -notcontains $CandObj.Provider) {
                & $RecordExclusion $mId $tier 'PROVIDER_NOT_ALLOWED'
                return $null
            }
        }

        # 6. Admissibilidade por papel do agente (eligible_roles no modelo)
        if ($CandObj.EligibleRoles.Count -gt 0 -and $CandObj.EligibleRoles -notcontains $cleanAgent) {
            & $RecordExclusion $mId $tier 'AGENT_NOT_ELIGIBLE'
            return $null
        }

        # 7. Admissibilidade por tier do agente ($admiss)
        if ($null -ne $admiss) {
            if ($admiss.ProhibitedTiers -contains $tier) {
                & $RecordExclusion $mId $tier 'AGENT_NOT_ELIGIBLE'
                return $null
            }
            if ($admiss.AdmissibleTiers.Count -gt 0 -and $admiss.AdmissibleTiers -notcontains $tier) {
                & $RecordExclusion $mId $tier 'AGENT_NOT_ELIGIBLE'
                return $null
            }
        }

        # 8. Autorizacao de custo para T4
        if ($tier -eq 'T4' -or $CandObj.RequiresCost) {
            if (-not $costAuth) {
                & $RecordExclusion $mId $tier 'UNAUTHORIZED_T4_COST'
                return $null
            }
        }

        # 9. Autorizacao excepcional para Astra
        if ($CandObj.Exceptional -or $mId -match 'astra') {
            if ([string]$env:OPENCODE_ASTRA_AUTHORIZED -ine 'true') {
                & $RecordExclusion $mId $tier 'UNAUTHORIZED_ASTRA_EXCEPTIONAL'
                return $null
            }
        }

        return $CandObj
    }

    # Helper function to build success result
    $BuildAuthorizedResult = {
        param([string]$ChosenModel, [string]$TargetTier, [string]$ReasonMsg, [bool]$IsDown)
        $chosenProv = Get-ModelProviderFromId $ChosenModel
        $isCross = ($origProvider -ne $chosenProv -and $origProvider -ne 'unknown' -and $chosenProv -ne 'unknown')
        return [pscustomobject]@{
            Status                 = 'AUTHORIZED'
            IsAuthorized           = $true
            FallbackModel          = $ChosenModel
            AuthorizedModel        = $ChosenModel
            FallbackTier           = $TargetTier
            OriginalModel          = $origModel
            OriginalProvider       = $origProvider
            FallbackProvider       = $chosenProv
            IsCrossProvider        = $isCross
            TriggerReason          = $TriggerReason
            Reason                 = $ReasonMsg
            AuthorizationSource    = 'ROUTER_POLICY'
            ProviderCostAuthorized = [bool]$RequestedSelection.ProviderCostAuthorized
            AttemptsCount          = [Math]::Max(1, $reallyAttempted.Count)
            IsDowngrade            = $IsDown
            ReallyAttemptedModels  = @($reallyAttempted)
            PreventivelyExcluded   = @($preventivelyExcluded)
        }
    }

    # Politica de fallback por papel e regras de admissibilidade:
    # 1. Reviewer / Security-Reviewer: Downgrade abaixo dos tiers admitidos e estritamente proibido!
    if ($cleanAgent -in @('reviewer', 'security-reviewer')) {
        $isDowngradeProhibited = $true
        if ($cleanAgent -eq 'reviewer' -and [string]$RequestedSelection.Risk -eq 'low') {
            $isDowngradeProhibited = $false
        }

        # Tenta candidatos no mesmo tier ($reqTier)
        $sameTierCands = & $GetDynamicCandidatesForTier $reqTier
        $validSameTierCand = $null
        foreach ($cand in $sameTierCands) {
            $valid = & $EvaluateCandidate $cand
            if ($null -ne $valid) {
                $validSameTierCand = $valid.ModelId
                break
            }
        }

        if ($null -ne $validSameTierCand) {
            return (& $BuildAuthorizedResult $validSameTierCand $reqTier "Router authorized same-tier fallback to '$validSameTierCand' for agent '$cleanAgent'." $false)
        }

        # Sem alternativa no mesmo tier. Reviewer pode escalar para T4 se autorizado por custo
        if ($cleanAgent -eq 'reviewer' -and $reqTier -eq 'T3') {
            $t4Cands = & $GetDynamicCandidatesForTier 'T4'
            foreach ($cand in $t4Cands) {
                $valid = & $EvaluateCandidate $cand
                if ($null -ne $valid) {
                    return (& $BuildAuthorizedResult $valid.ModelId 'T4' "Router authorized tier escalation to '$($valid.ModelId)' (T4) for agent '$cleanAgent'." $false)
                }
            }
        }

        # Se downgrade for proibido, registra preventivamente os modelos de tiers inferiores e rejeita fail-closed
        if ($isDowngradeProhibited) {
            foreach ($lowerTier in @('T2', 'T1')) {
                $lowerCands = & $GetDynamicCandidatesForTier $lowerTier
                foreach ($lc in $lowerCands) {
                    & $RecordExclusion $lc.ModelId $lowerTier 'DOWNGRADE_PROHIBITED'
                }
            }
            return [pscustomobject]@{
                Status                 = 'REJECTED_DOWNGRADE_FORBIDDEN'
                IsAuthorized           = $false
                FallbackModel          = $null
                AuthorizedModel        = $null
                FallbackTier           = $null
                OriginalModel          = $origModel
                OriginalProvider       = $origProvider
                FallbackProvider       = $null
                IsCrossProvider        = $false
                TriggerReason          = $TriggerReason
                Reason                 = "Downgrade below tier $reqTier for agent '$cleanAgent' is prohibited by security policy."
                AuthorizationSource    = 'ROUTER_POLICY'
                ProviderCostAuthorized = $false
                AttemptsCount          = [Math]::Max(1, $reallyAttempted.Count)
                IsDowngrade            = $true
                ReallyAttemptedModels  = @($reallyAttempted)
                PreventivelyExcluded   = @($preventivelyExcluded)
            }
        }
    }

    # 2. Agentes gerais: tenta candidatos no mesmo tier primeiro
    $sameTierCands = & $GetDynamicCandidatesForTier $reqTier
    foreach ($cand in $sameTierCands) {
        $valid = & $EvaluateCandidate $cand
        if ($null -ne $valid) {
            return (& $BuildAuthorizedResult $valid.ModelId $reqTier "Router authorized same-tier alternative '$($valid.ModelId)' for agent '$cleanAgent'." $false)
        }
    }

    # 3. Se o mesmo tier esta esgotado, verifica se o agente permite escalonamento de tier (upgrade)
    if ($null -ne $admiss) {
        $candidateUpgradeTiers = switch ($reqTier) {
            'T1' { @('T2', 'T3', 'T4') }
            'T2' { @('T3', 'T4') }
            'T3' { @('T4') }
            default { @() }
        }
        foreach ($nextTier in $candidateUpgradeTiers) {
            $upCands = & $GetDynamicCandidatesForTier $nextTier
            foreach ($candUp in $upCands) {
                $validUp = & $EvaluateCandidate $candUp
                if ($null -ne $validUp) {
                    return (& $BuildAuthorizedResult $validUp.ModelId $nextTier "Router authorized tier escalation to '$($validUp.ModelId)' ($nextTier) for agent '$cleanAgent'." $false)
                }
            }
        }
    }

    # 4. Se todas as opcoes foram esgotadas
    return [pscustomobject]@{
        Status                 = 'EXHAUSTED_NO_ELIGIBLE_FALLBACK'
        IsAuthorized           = $false
        FallbackModel          = $null
        AuthorizedModel        = $null
        FallbackTier           = $null
        OriginalModel          = $origModel
        OriginalProvider       = $origProvider
        FallbackProvider       = $null
        IsCrossProvider        = $false
        TriggerReason          = $TriggerReason
        Reason                 = "All admissible and authorized fallback models for agent '$cleanAgent' have been exhausted."
        AuthorizationSource    = 'ROUTER_POLICY'
        ProviderCostAuthorized = $false
        AttemptsCount          = [Math]::Max(1, $reallyAttempted.Count)
        IsDowngrade            = $false
        ReallyAttemptedModels  = @($reallyAttempted)
        PreventivelyExcluded   = @($preventivelyExcluded)
    }
}

function Test-ExecutedModelVerification {
    <#
    .SYNOPSIS
        Verifies whether the actual executed model matches the requested model routing or an authorized fallback.
    .DESCRIPTION
        Fails closed:
          - EXACT_MATCH: actual model strictly equals requested model/token and host identity is confirmed.
          - AUTHORIZED_FALLBACK: actual model differs from requested, but a valid authorized fallback decision
            prior to execution is proven, admissible for the agent, and matches actual host model.
          - UNAUTHORIZED_MISMATCH: actual model differs without authorized fallback proof or violates admissibility.
          - PROOF_ABSENT: insufficient evidence or override unproven in current runtime.
        Audits cross-provider transitions and ensures T0 strictly forbids LLM execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $RequestedSelection,

        [Parameter(Mandatory = $false)]
        $ExecutedModelEvent = $null,

        [Parameter(Mandatory = $false)]
        [bool]$NativeModelOverrideProven = $false,

        [Parameter(Mandatory = $false)]
        $AuthorizedFallback = $null
    )

    $reqTier = [string]$RequestedSelection.Tier
    $reqModel = [string]$RequestedSelection.CatalogModel
    $reqToken = [string]$RequestedSelection.ModelToken
    $reqProvider = if ($RequestedSelection.Provider) { [string]$RequestedSelection.Provider } else { Get-ModelProviderFromId $reqModel }

    if (-not $NativeModelOverrideProven) {
        return [pscustomobject]@{
            VerifiedMatch        = $false
            ProofStatus          = 'PROOF_ABSENT'
            MatchKind            = 'PROOF_ABSENT'
            IsExactMatch         = $false
            IsAuthorizedFallback = $false
            RuntimeTierProven    = $false
            Reason               = 'Native dynamic model override unproven in current runtime. Falling back to host template configuration.'
            RequestedTier        = $reqTier
            EffectiveTier        = [string]$RequestedSelection.FallbackTier
            EffectiveModelToken  = [string]$RequestedSelection.FallbackToken
            RequestedProvider    = $reqProvider
            EffectiveProvider    = 'unknown'
            IsCrossProvider      = $false
        }
    }

    if ($null -eq $ExecutedModelEvent) {
        return [pscustomobject]@{
            VerifiedMatch        = $false
            ProofStatus          = 'PROOF_ABSENT'
            MatchKind            = 'PROOF_ABSENT'
            IsExactMatch         = $false
            IsAuthorizedFallback = $false
            RuntimeTierProven    = $false
            Reason               = 'No executed model event or telemetry provided for verification.'
            RequestedTier        = $reqTier
            EffectiveTier        = $null
            EffectiveModelToken  = $null
            RequestedProvider    = $reqProvider
            EffectiveProvider    = 'unknown'
            IsCrossProvider      = $false
        }
    }

    $actModel = [string]$ExecutedModelEvent.Model
    if ([string]::IsNullOrWhiteSpace($actModel)) {
        $actModel = [string]$ExecutedModelEvent.model
    }

    if ([string]::IsNullOrWhiteSpace($actModel)) {
        return [pscustomobject]@{
            VerifiedMatch        = $false
            ProofStatus          = 'PROOF_ABSENT'
            MatchKind            = 'PROOF_ABSENT'
            IsExactMatch         = $false
            IsAuthorizedFallback = $false
            RuntimeTierProven    = $false
            Reason               = 'Actual executed model identity is empty or unrecorded in event.'
            RequestedTier        = $reqTier
            EffectiveTier        = $null
            EffectiveModelToken  = $null
            RequestedProvider    = $reqProvider
            EffectiveProvider    = 'unknown'
            IsCrossProvider      = $false
        }
    }

    $actProvider = Get-ModelProviderFromId $actModel
    $isCrossProvider = ($reqProvider -ne $actProvider -and $reqProvider -ne 'unknown' -and $actProvider -ne 'unknown')

    # T0 check: Deterministic execution without LLM
    if ($reqTier -eq 'T0') {
        $isDeterministic = ($actModel -in @('none', 'none (deterministic)', 'NONE_DIRECT_VERIFIED') -or [string]::IsNullOrWhiteSpace($actModel))
        if (-not $isDeterministic) {
            return [pscustomobject]@{
                VerifiedMatch        = $false
                ProofStatus          = 'UNAUTHORIZED_MISMATCH'
                MatchKind            = 'UNAUTHORIZED_MISMATCH'
                IsExactMatch         = $false
                IsAuthorizedFallback = $false
                RuntimeTierProven    = $false
                Reason               = "Tier T0 is strictly deterministic and does not permit LLM execution ('$actModel')."
                RequestedTier        = 'T0'
                EffectiveTier        = 'UNKNOWN'
                EffectiveModelToken  = $actModel
                RequestedProvider    = 'none'
                EffectiveProvider    = $actProvider
                IsCrossProvider      = $true
            }
        } else {
            return [pscustomobject]@{
                VerifiedMatch        = $true
                ProofStatus          = 'EXACT_MATCH'
                MatchKind            = 'EXACT_MATCH'
                IsExactMatch         = $true
                IsAuthorizedFallback = $false
                RuntimeTierProven    = $true
                Reason               = 'Executed model matches requested deterministic T0.'
                RequestedTier        = 'T0'
                EffectiveTier        = 'T0'
                EffectiveModelToken  = $actModel
                RequestedProvider    = 'none'
                EffectiveProvider    = 'none'
                IsCrossProvider      = $false
            }
        }
    }

    # Check for EXACT_MATCH
    $isExact = ($actModel -eq $reqModel -or $actModel -eq $reqToken)
    if ($isExact) {
        return [pscustomobject]@{
            VerifiedMatch        = $true
            ProofStatus          = 'EXACT_MATCH'
            MatchKind            = 'EXACT_MATCH'
            IsExactMatch         = $true
            IsAuthorizedFallback = $false
            RuntimeTierProven    = $true
            Reason               = "Executed model '$actModel' exactly matches requested model '$reqModel'."
            RequestedTier        = $reqTier
            EffectiveTier        = $reqTier
            EffectiveModelToken  = $actModel
            RequestedProvider    = $reqProvider
            EffectiveProvider    = $actProvider
            IsCrossProvider      = $false
        }
    }

    # Not an exact match. Check for AUTHORIZED_FALLBACK
    $fb = if ($null -ne $AuthorizedFallback) { $AuthorizedFallback } elseif ($ExecutedModelEvent.AuthorizedFallback) { $ExecutedModelEvent.AuthorizedFallback } elseif ($ExecutedModelEvent.fallback_decision) { $ExecutedModelEvent.fallback_decision } else { $null }

    if ($null -ne $fb) {
        $fbAuthorized = [bool]($fb.IsAuthorized -or $fb.Authorized -or $fb.Status -eq 'AUTHORIZED')
        $fbModel = if ($fb.AuthorizedModel) { [string]$fb.AuthorizedModel } elseif ($fb.FallbackModel) { [string]$fb.FallbackModel } else { '' }
        $agent = [string]$RequestedSelection.Agent
        if ([string]::IsNullOrWhiteSpace($agent)) { $agent = [string]$RequestedSelection.AgentName }
        $cleanAgent = if (-not [string]::IsNullOrWhiteSpace($agent)) { $agent.Trim().ToLowerInvariant() } else { '' }

        # Verify whether the fallback model matches actual host model
        $modelMatchesFallback = ($actModel -eq $fbModel)

        # Verify admissibility for the agent
        $admissibilityOk = $true
        $effTier = if ($fb.FallbackTier) { [string]$fb.FallbackTier } else { $reqTier }
        if (-not [string]::IsNullOrWhiteSpace($cleanAgent) -and $script:AgentModelAdmissibility.ContainsKey($cleanAgent)) {
            $admiss = $script:AgentModelAdmissibility[$cleanAgent]
            if ($admiss.ProhibitedTiers -contains $effTier -or ($admiss.AdmissibleTiers.Count -gt 0 -and $admiss.AdmissibleTiers -notcontains $effTier)) {
                $admissibilityOk = $false
            }
            # Reviewer check: T2 prohibited unless low risk
            if ($cleanAgent -eq 'reviewer' -and $effTier -eq 'T2' -and [string]$RequestedSelection.Risk -ne 'low') {
                $admissibilityOk = $false
            }
            # Security-Reviewer check: T0, T1, T2 strictly prohibited
            if ($cleanAgent -eq 'security-reviewer' -and $effTier -in @('T0', 'T1', 'T2')) {
                $admissibilityOk = $false
            }
        }

        # T4 cost authorization check
        if ($effTier -eq 'T4') {
            $t4CostAuth = ([bool]$fb.ProviderCostAuthorized -and ([string]$fb.AuthorizationSource -in @('EXPLICIT_PARAMETER', 'GLOBAL_ENV_OPENCODE_T4_AUTHORIZED', 'ROUTER_POLICY') -or [string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true'))
            if (-not $t4CostAuth -and [string]$RequestedSelection.CostAuthorizationSource -in @('EXPLICIT_PARAMETER', 'GLOBAL_ENV_OPENCODE_T4_AUTHORIZED')) {
                $t4CostAuth = $true
            }
            if (-not $t4CostAuth) {
                $admissibilityOk = $false
            }
        }

        if ($fbAuthorized -and $modelMatchesFallback -and $admissibilityOk) {
            return [pscustomobject]@{
                VerifiedMatch        = $true
                ProofStatus          = 'AUTHORIZED_FALLBACK'
                MatchKind            = 'AUTHORIZED_FALLBACK'
                IsExactMatch         = $false
                IsAuthorizedFallback = $true
                RuntimeTierProven    = $true
                Reason               = "Executed model '$actModel' is an authorized fallback from '$reqModel' (Trigger: $($fb.TriggerReason))."
                RequestedTier        = $reqTier
                EffectiveTier        = $effTier
                EffectiveModelToken  = $actModel
                RequestedProvider    = $reqProvider
                EffectiveProvider    = $actProvider
                IsCrossProvider      = ($reqProvider -ne $actProvider)
                FallbackDecision     = $fb
            }
        }
    }

    # If neither EXACT_MATCH nor AUTHORIZED_FALLBACK, it is UNAUTHORIZED_MISMATCH
    return [pscustomobject]@{
        VerifiedMatch        = $false
        ProofStatus          = 'UNAUTHORIZED_MISMATCH'
        MatchKind            = 'UNAUTHORIZED_MISMATCH'
        IsExactMatch         = $false
        IsAuthorizedFallback = $false
        RuntimeTierProven    = $false
        Reason               = "Executed model '$actModel' does not match requested model '$reqModel' and no authorized fallback was proven."
        RequestedTier        = $reqTier
        EffectiveTier        = 'UNKNOWN'
        EffectiveModelToken  = $actModel
        RequestedProvider    = $reqProvider
        EffectiveProvider    = $actProvider
        IsCrossProvider      = $isCrossProvider
    }
}

function Resolve-OrchestrationModelSelection {
    <#
    .SYNOPSIS
        Selects model tier, provider and model ID for an agent based on task criteria, policy and safety invariants.
    .DESCRIPTION
        Implements Dynamic Model Routing & Intelligent Advisory v1.1.
        Preserves backward compatibility while providing full structured ModelSelectionDecision output.
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
        $ModelCatalog = $null,

        [Parameter(Mandatory = $false)]
        [bool]$RequiresLlm = $false,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedProviders = @(),

        [Parameter(Mandatory = $false)]
        [string]$TaskType = '',

        [Parameter(Mandatory = $false)]
        [string]$TaskId = '',

        [Parameter(Mandatory = $false)]
        [string]$GoalId = '',

        [Parameter(Mandatory = $false)]
        [string]$PolicyPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$IgnoreUserConfig = $false,

        [Parameter(Mandatory = $false)]
        [Alias('RequiresVisual', 'VisualTask', 'Visual', 'NeedsVisualAnalysis')]
        [bool]$RequiresVisualAnalysis = $false,

        [Parameter(Mandatory = $false)]
        [Alias('Capability', 'Capabilities')]
        [string]$RequiredCapability = ''
    )

    $cleanAgent = $AgentName.Trim().ToLowerInvariant()
    $policyRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
    $polHash = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyHash } else { '' }
    $polVer = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyVersion } else { '1.2.0' }

    if (-not $script:AgentModelAdmissibility.ContainsKey($cleanAgent)) {
        return [pscustomobject]@{
            Status                    = 'REJECTED'
            DecisionStatus            = 'NO_ELIGIBLE_MODEL'
            Reason                    = "Unknown or unregistered agent: '$cleanAgent'"
            selection_reason          = "Unknown or unregistered agent: '$cleanAgent'"
            Agent                     = $cleanAgent
            requested_role            = $cleanAgent
            Tier                      = $null
            selected_tier             = $null
            ModelToken                = $null
            selected_model_id         = $null
            selected_provider         = 'none'
            FallbackTier              = 'T2'
            FallbackToken             = 'MODEL_CHEAP'
            IsCompliant               = $false
            Authorized                = $false
            policy_version            = $polVer
            policy_hash               = $polHash
            fallback_candidates       = @()
            runtime_override_status   = if ($NativeModelOverrideProven) { 'PROVEN' } else { 'PROOF_ABSENT' }
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
            requested_role            = $cleanAgent
            Tier                      = 'T0'
            selected_tier             = 'T0'
            TierName                  = 'Deterministic'
            ModelToken                = 'NONE_DIRECT_VERIFIED'
            EffectiveModelToken       = 'NONE_DIRECT_VERIFIED'
            CatalogModel              = 'none (deterministic)'
            selected_model_id         = 'none (deterministic)'
            selected_provider         = 'none'
            Provider                  = 'none'
            AuthorizedSelection       = $true
            Authorized                = $true
            RuntimeTierProven         = $true
            runtime_override_status   = 'PROVEN'
            ProofStatus               = 'PROVEN_DIRECT_VERIFIED'
            AdmissibleTiers           = @('T0')
            SelectionReason           = 'Task is trivial, local and low-risk. Running via DIRECT_VERIFIED without model tokens.'
            selection_reason          = 'Task is trivial, local and low-risk. Running via DIRECT_VERIFIED without model tokens.'
            EstimatedCostMultiplier   = 0.0
            FallbackTier              = 'T0'
            FallbackToken             = 'NONE_DIRECT_VERIFIED'
            NativeModelOverrideProven = $NativeModelOverrideProven
            IsCompliant               = $true
            policy_version            = $polVer
            policy_hash               = $polHash
            fallback_candidates       = @()
        }
    }

    # Dynamic tier selection logic based on SPEC v1.1
    $selectedTier = $admissibility.DefaultTier
    $reason = "Default tier '$selectedTier' for agent '$cleanAgent'."

    # Planner 'build' is stable on T3 (Luna)
    if ($cleanAgent -eq 'build') {
        $selectedTier = 'T3'
        $reason = "Planner build is stable on Capable tier T3 (Luna) during objective."
    }
    elseif ($cleanAgent -eq 'reviewer') {
        if ($Risk -in @('high', 'critical')) {
            if ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true')) {
                $selectedTier = 'T4'
                $reason = "Elevated to T4 due to $Risk risk on reviewer role with explicit cost authorization."
            } else {
                $selectedTier = 'T3'
                $reason = "Tier 'T4' was unauthorized (provider_cost_authorized=false) for reviewer under $Risk risk. Degraded to 'T3'."
            }
        } elseif ($Risk -eq 'low' -and $Complexity -in @('trivial', 'simple')) {
            $selectedTier = 'T2'
            $reason = "Economical tier T2 admitted for low-risk, simple review."
        } else {
            $selectedTier = 'T3'
            $reason = "Standard capable tier T3 for review."
        }
    }
    elseif ($cleanAgent -eq 'security-reviewer') {
        if ($Risk -in @('high', 'critical')) {
            if ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true')) {
                $selectedTier = 'T4'
                $reason = "Frontier tier T4 selected for high/critical security review with explicit cost authorization."
            } else {
                $selectedTier = 'T3'
                $reason = "Tier 'T4' was unauthorized (provider_cost_authorized=false) for security review under $Risk risk. Degraded to 'T3'."
            }
        } else {
            $selectedTier = 'T3'
            $reason = "Capable tier T3 selected for standard security review."
        }
    }
    elseif ($cleanAgent -eq 'engineering-advisor') {
        if ($FailureCount -ge 2) {
            if ($ProviderCostAuthorized -or ([string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true')) {
                $selectedTier = 'T4'
                $reason = "Frontier tier T4 selected for deadlock consult after $FailureCount prior failures with explicit cost authorization."
            } else {
                $selectedTier = 'T3'
                $reason = "Tier 'T4' was unauthorized (provider_cost_authorized=false) for engineering-advisor with $FailureCount failures. Degraded to 'T3'."
            }
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
    elseif ($cleanAgent -eq 'tester') {
        if ($RequiresLlm -or $Complexity -in @('simple', 'medium', 'complex')) {
            $selectedTier = 'T2'
            $reason = "Authorized LLM tier T2 selected for tester subagent execution."
        } else {
            # T0: verificacao deterministica sem LLM (exit codes, scripts, AST)
            $selectedTier = 'T0'
            $reason = "Deterministic verification tier T0 (no LLM) for tester."
        }
    }

    # Strict safety invariant check: ensure selected tier is admissible
    if ($admissibleTiers -notcontains $selectedTier -or $prohibitedTiers -contains $selectedTier) {
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

    # Visual capability upgrade: eligible agents may use T3 (Terra) for visual/document tasks
    $visualRequested = $RequiresVisualAnalysis
    if (-not $visualRequested -and -not [string]::IsNullOrWhiteSpace($RequiredCapability)) {
        if ($RequiredCapability -match 'visual|ui|image|document|screen|interface') { $visualRequested = $true }
    }
    if (-not $visualRequested -and -not [string]::IsNullOrWhiteSpace($TaskType)) {
        if ($TaskType -match 'visual|ui|image|document|screen|interface') { $visualRequested = $true }
    }
    $terraEligibleAgents = @('frontend-engineer','product-designer','researcher','architect')
    if ($visualRequested -and ($terraEligibleAgents -contains $cleanAgent) -and ($admissibleTiers -contains 'T3')) {
        $selectedTier = 'T3'
        $reason = "Capable tier T3 selected for visual/document capability (Terra)."
    }

    # Catalog and authorization check: separate technical justification from explicit cost authorization
    $catalogRes = Resolve-CatalogModel -Tier $selectedTier -Catalog $ModelCatalog -FailureCount $FailureCount -Risk $Risk -ProviderCostAuthorized $ProviderCostAuthorized -PolicyPath $PolicyPath -IgnoreUserConfig $IgnoreUserConfig
    if (-not $catalogRes.IsAuthorized) {
        $degradedTier = if ($selectedTier -eq 'T4') { 'T3' } else { $admissibility.DefaultTier }
        $reason = "Tier '$($catalogRes.Tier)' was unauthorized (cost/provider authorization absent). Degraded to '$degradedTier'."
        $selectedTier = $degradedTier
        $catalogRes = Resolve-CatalogModel -Tier $selectedTier -Catalog $ModelCatalog -FailureCount $FailureCount -Risk $Risk -ProviderCostAuthorized $ProviderCostAuthorized -PolicyPath $PolicyPath -IgnoreUserConfig $IgnoreUserConfig
    }

    # Check AllowedProviders constraint if provided
    $selectedProv = Get-ModelProviderFromId $catalogRes.CatalogModel
    if ($null -ne $AllowedProviders -and $AllowedProviders.Count -gt 0) {
        if ($AllowedProviders -notcontains $selectedProv) {
            # Try to find candidate in same tier with allowed provider
            $foundAlt = $null
            foreach ($cand in $catalogRes.FallbackCandidates) {
                if ($AllowedProviders -contains (Get-ModelProviderFromId $cand)) {
                    $foundAlt = $cand
                    break
                }
            }
            if ($null -ne $foundAlt) {
                $catalogRes.CatalogModel = $foundAlt
                $selectedProv = Get-ModelProviderFromId $foundAlt
                $reason += " Fallback to allowed provider '$selectedProv' model '$foundAlt'."
            } else {
                return [pscustomobject]@{
                    Status                    = 'PROVIDER_UNAVAILABLE'
                    Agent                     = $cleanAgent
                    requested_role            = $cleanAgent
                    Tier                      = $selectedTier
                    selected_tier             = $selectedTier
                    Reason                    = "Selected provider '$selectedProv' is not in allowed_providers: ($($AllowedProviders -join ', '))"
                    selection_reason          = "Selected provider '$selectedProv' is not in allowed_providers: ($($AllowedProviders -join ', '))"
                    AuthorizedSelection       = $false
                    Authorized                = $false
                    IsCompliant               = $false
                    policy_version            = $polVer
                    policy_hash               = $polHash
                    selected_provider         = $selectedProv
                    selected_model_id         = $catalogRes.CatalogModel
                    fallback_candidates       = $catalogRes.FallbackCandidates
                    runtime_override_status   = if ($NativeModelOverrideProven) { 'PROVEN' } else { 'PROOF_ABSENT' }
                }
            }
        }
    }

    # Terra specialization: prefer GPT-6.1 Terra for eligible visual/document tasks when explicitly requested
    $visualRequested = $RequiresVisualAnalysis
    if (-not $visualRequested -and -not [string]::IsNullOrWhiteSpace($RequiredCapability)) {
        if ($RequiredCapability -match 'visual|ui|image|document|screen|interface') { $visualRequested = $true }
    }
    if (-not $visualRequested -and -not [string]::IsNullOrWhiteSpace($TaskType)) {
        if ($TaskType -match 'visual|ui|image|document|screen|interface') { $visualRequested = $true }
    }
    $terraEligibleAgents = @('frontend-engineer','product-designer','researcher','architect')
    if ($selectedTier -eq 'T3' -and $visualRequested) {
        $terraEligibleAgents = @('frontend-engineer','product-designer','researcher','architect')
        if ($terraEligibleAgents -contains $cleanAgent) {
            $polRes2 = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
            $terraEnabled = $true
            if ($polRes2.Status -eq 'POLICY_LOADED' -and $null -ne $polRes2.Policy.models.terra) {
                $terraEnabled = [bool]$polRes2.Policy.models.terra.enabled
            }
            if ($terraEnabled) {
                $catalogRes.CatalogModel = 'openai/gpt-6.1-terra'
                $selectedProv = 'openai'
                $reason += " Terra selected for visual/document capability."
            }
        }
    }

    $modelToken = [string]$catalogRes.ModelToken
    $tierMeta = $script:ModelTiers[$selectedTier]

    $fallbackDefaultTier = $admissibility.DefaultTier
    $fallbackDefaultToken = switch ($fallbackDefaultTier) {
        'T4' { 'MODEL_FRONTIER' }
        'T3' { 'MODEL_STRONG' }
        'T1' { 'MODEL_FREE' }
        'T0' { 'NONE_DIRECT_VERIFIED' }
        default { 'MODEL_CHEAP' }
    }

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
        requested_role            = $cleanAgent
        Risk                      = $Risk
        Complexity                = $Complexity
        Tier                      = $selectedTier
        selected_tier             = $selectedTier
        TierName                  = $tierMeta.Name
        ModelToken                = $modelToken
        EffectiveModelToken       = $effectiveToken
        CatalogModel              = $catalogRes.CatalogModel
        selected_model_id         = $catalogRes.CatalogModel
        selected_provider         = $selectedProv
        Provider                  = $selectedProv
        AuthorizedSelection       = $catalogRes.IsAuthorized
        Authorized                = $catalogRes.IsAuthorized
        ProviderCostAuthorized    = [bool]$catalogRes.ProviderCostAuthorized
        CostAuthorizationSource   = [string]$catalogRes.CostAuthorizationSource
        authorization_source      = [string]$catalogRes.CostAuthorizationSource
        CostAuthorizationEvidence = [string]$catalogRes.CostAuthorizationEvidence
        CostBudget                = [string]$catalogRes.CostBudget
        RuntimeTierProven         = $runtimeTierProven
        runtime_override_status   = $proofStatus
        ProofStatus               = $proofStatus
        AdmissibleTiers           = $admissibleTiers
        SelectionReason           = $reason
        selection_reason          = $reason
        EstimatedCostMultiplier   = $tierMeta.RelativeCost
        FallbackTier              = $fallbackDefaultTier
        FallbackToken             = $fallbackDefaultToken
        NativeModelOverrideProven = $NativeModelOverrideProven
        OverrideNote              = $overrideNote
        IsCompliant               = $true
        policy_version            = $polVer
        policy_hash               = $polHash
        fallback_candidates       = $catalogRes.FallbackCandidates
        IgnoreUserConfig          = [bool]$IgnoreUserConfig
    }
}

function Get-OrchestrationModelRouterReceipt {
    <#
    .SYNOPSIS
        Generates an authoritative, verifiable receipt for a model routing selection.
    .DESCRIPTION
        Enforces that T4 selections record the explicit or global authorization source,
        budget, and evidence. Ensures that a receipt never contains Tier T4 with
        provider_cost_authorized=false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Selection
    )

    if ($null -eq $Selection) {
        throw "Selection cannot be null."
    }

    $tier = [string]$Selection.Tier
    $isCostAuth = [bool]$Selection.ProviderCostAuthorized
    $authSource = [string]$Selection.CostAuthorizationSource
    $authEv = [string]$Selection.CostAuthorizationEvidence
    $budget = [string]$Selection.CostBudget

    if ($tier -eq 'T4' -and -not $isCostAuth) {
        throw "INVARIANT_VIOLATION: A model routing receipt cannot have Tier T4 with provider_cost_authorized=false."
    }

    if ($tier -eq 'T4' -and [string]::IsNullOrWhiteSpace($authSource)) {
        throw "INVARIANT_VIOLATION: A model routing receipt cannot have Tier T4 with missing or presumed authorization_source."
    }

    $finalAuthSource = if (-not [string]::IsNullOrWhiteSpace($authSource)) { $authSource } else { if ($tier -eq 'T4') { 'NONE_UNAUTHORIZED' } else { 'STANDARD_CATALOG' } }
    $finalAuthEv = if (-not [string]::IsNullOrWhiteSpace($authEv)) { $authEv } else { if ($tier -eq 'T4') { 'none' } else { 'catalog:default' } }

    return [ordered]@{
        stage                    = 'model_routing'
        agent                    = [string]$Selection.Agent
        tier                     = $tier
        catalog_model            = [string]$Selection.CatalogModel
        model_token              = [string]$Selection.ModelToken
        provider_cost_authorized = $isCostAuth
        authorization_source     = $finalAuthSource
        authorization_evidence   = $finalAuthEv
        budget                   = if (-not [string]::IsNullOrWhiteSpace($budget)) { $budget } else { 'standard_tier_budget' }
        timestamp                = [DateTime]::UtcNow.ToString('o')
    }
}
