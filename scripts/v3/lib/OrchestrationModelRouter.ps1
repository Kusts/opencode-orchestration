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
        DefaultTier      = 'T1'
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
    'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode-go/iceman-contributor-free';  Provider = 'opencode-go'; Authorized = $true; AlternativeModel = 'opencode/mimo-v2.6-flash-free' }
    'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Provider = 'opencode-go'; Authorized = $true; AlternativeModel = 'openai/gpt-6-luna' }
    'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6.1-terra';                   Provider = 'openai';      Authorized = $true; AlternativeModel = 'opencode-go/muse-spark-1.3-contributor' }
    'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6.1-sol';                      Provider = 'openai';      Authorized = $true; ExceptionalModel = 'openai/gpt-6-astra' }
}

$script:CachedRoutingPolicy = $null

# Closed claude-agent DISPATCH-ALIAS map (alias model_id -> dispatch alias
# token). Dispatch identity IS the alias itself: claude-agent/haiku -> haiku,
# claude-agent/sonnet -> sonnet, claude-agent/opus -> opus,
# claude-agent/fable -> fable. The OpenCode catalog never publishes an
# alias->concrete mapping, successful session events expose only the alias, and
# the concrete IDs merely LISTED in this account's local `opencode models` CLI
# inventory are recorded in the policy as catalog_inventory_id (listing /
# provenance ONLY, never read by this router). Alias-to-concrete runtime
# resolution stays runtime-unverified until a successful session event proves
# it: never store a concrete model ID here and never treat one as a mapping
# (no invented 5.5/5.1 IDs; no resolved_model field anywhere).
$script:ClaudeAgentDispatchAliasMap = @{
    'claude-agent/haiku'  = 'haiku'
    'claude-agent/sonnet' = 'sonnet'
    'claude-agent/opus'   = 'opus'
    'claude-agent/fable'  = 'fable'
}

# Effort variants listed per alias in the current OpenCode model catalog
# (tools.opencode.models metadata: low/medium/high/xhigh/max).
# Recorded as catalog metadata only; smoke did not use a variant.
$script:ClaudeAgentEffortVariants = @('low', 'medium', 'high', 'xhigh', 'max')

# Availability/transport fault classes. A claude-agent substitute (Haiku/Sonnet/
# Opus) and every tier escalation are policy-level availability routes only for
# these reasons; capability/incapacity claims (VERIFIED_TASK_FAILURE) and
# ambiguous outcomes (TIMEOUT) are NOT availability and never unlock them.
$script:AvailabilityTriggerReasons = @('RATE_LIMIT', 'PROVIDER_ERROR', 'MODEL_UNAVAILABLE', 'MODEL_ERROR', 'SERVICE_UNAVAILABLE', 'QUOTA_EXCEEDED', 'OFFLINE')

function Test-ClaudeAgentProviderAdmissible {
    <#
    .SYNOPSIS
        Admissibility gate for the claude-agent provider (no second catalog, no new state machine).
    .DESCRIPTION
        The claude-agent provider is allowed only with explicit capability proof: the dispatcher
        must have verified a local authenticated 'claude' executable on the worker machine and
        assert it via -ClaudeAgentProven or -WorkerCapabilities ('claude-agent' /
        'claude-executable-authenticated'). Remote workers without the explicit
        'claude-agent-remote' capability are rejected even when local proof exists.
        Default (no proof) is reject-closed, which keeps all legacy suites deterministic.
        Availability and no-start are checked separately by the caller (this helper
        only answers "is the Claude capability proven for this worker?").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WorkerHost = 'local',

        [Parameter(Mandatory = $false)]
        [string[]]$WorkerCapabilities = @(),

        [Parameter(Mandatory = $false)]
        [bool]$ClaudeAgentProven = $false
    )

    $caps = @($WorkerCapabilities | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $proven = $ClaudeAgentProven -or ($caps -contains 'claude-agent') -or ($caps -contains 'claude-executable-authenticated')
    if (-not $proven) {
        return [pscustomobject]@{ Admissible = $false; Reason = 'CLAUDE_CAPABILITY_UNPROVEN' }
    }

    $hostNorm = ([string]$WorkerHost).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($hostNorm)) { $hostNorm = 'local' }
    if ($hostNorm -ne 'local' -and -not ($caps -contains 'claude-agent-remote')) {
        return [pscustomobject]@{ Admissible = $false; Reason = 'CLAUDE_REMOTE_UNPROVEN' }
    }

    return [pscustomobject]@{ Admissible = $true; Reason = 'CLAUDE_CAPABILITY_PROVEN' }
}

function Resolve-ClaudeAgentAlias {
    <#
    .SYNOPSIS
        Validates the identity of a claude-agent dispatch alias against the policy.
    .DESCRIPTION
        Closed-map identity check ONLY: the requested alias model_id must be a
        known dispatch alias, and the policy's recorded model_id + alias pair
        must match it exactly (case-sensitive). A policy tamper (alias, model_id
        or the entry linkage changed) is rejected by the caller fail-closed with
        CLAUDE_UNKNOWN_ALIAS / CLAUDE_ALIAS_MISSING / CLAUDE_MODEL_ID_MISSING /
        CLAUDE_ALIAS_MISMATCH. This helper never reads catalog_inventory_id or
        any other concrete ID and never claims runtime alias->concrete
        resolution (runtime-unverified until a successful session event proves
        it): an event reporting an unverified concrete ID stays
        PROOF_ABSENT/UNAUTHORIZED_MISMATCH at verification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AliasModelId,

        [Parameter(Mandatory = $false)]
        [string]$PolicyAlias = '',

        [Parameter(Mandatory = $false)]
        [string]$PolicyModelId = ''
    )

    $key = ([string]$AliasModelId).Trim()
    $expected = if ($script:ClaudeAgentDispatchAliasMap.ContainsKey($key)) { [string]$script:ClaudeAgentDispatchAliasMap[$key] } else { '' }
    if ([string]::IsNullOrWhiteSpace($expected)) {
        return [pscustomobject]@{ Known = $false; Expected = ''; Matches = $false; Reason = 'CLAUDE_UNKNOWN_ALIAS' }
    }
    $polAlias = ([string]$PolicyAlias).Trim()
    if ([string]::IsNullOrWhiteSpace($polAlias)) {
        return [pscustomobject]@{ Known = $true; Expected = $expected; Matches = $false; Reason = 'CLAUDE_ALIAS_MISSING' }
    }
    if ($polAlias -cne $expected) {
        return [pscustomobject]@{ Known = $true; Expected = $expected; Matches = $false; Reason = 'CLAUDE_ALIAS_MISMATCH' }
    }
    $polModel = ([string]$PolicyModelId).Trim()
    if ([string]::IsNullOrWhiteSpace($polModel)) {
        return [pscustomobject]@{ Known = $true; Expected = $expected; Matches = $false; Reason = 'CLAUDE_MODEL_ID_MISSING' }
    }
    if ($polModel -cne $key) {
        return [pscustomobject]@{ Known = $true; Expected = $expected; Matches = $false; Reason = 'CLAUDE_ALIAS_MISMATCH' }
    }
    return [pscustomobject]@{ Known = $true; Expected = $expected; Matches = $true; Reason = '' }
}

function Resolve-ClaudeAgentUsageCost {
    <#
    .SYNOPSIS
        Maps a reported claude-agent cost to a recorded usage cost.
    .DESCRIPTION
        Subscription metering may report 0; a zero/empty/unparseable report must be recorded
        as UNKNOWN cost, never as 0 (enforces the zero_cost_on_unknown prohibition).
    #>
    [CmdletBinding()]
    param($ReportedCost = $null)

    $s = if ($null -eq $ReportedCost) { '' } else { ([string]$ReportedCost).Trim() }
    if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
    if ($s -ieq 'unknown') { return 'UNKNOWN' }
    $n = 0.0
    if ([double]::TryParse($s, [ref]$n)) {
        if ($n -eq 0) { return 'UNKNOWN' }
        return $s
    }
    return 'UNKNOWN'
}

function New-ClaudeAgentProviderSwitchHandoff {
    <#
    .SYNOPSIS
        Builds a context-preserving provider-switch handoff payload.
    .DESCRIPTION
        Carries objective, task id and attempt history across a provider switch so the
        receiving worker resumes with full context. Payload only; emits no dispatch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$TaskId = '',

        [Parameter(Mandatory = $false)]
        [string]$Objective = '',

        [Parameter(Mandatory = $false)]
        [string]$FromModel = '',

        [Parameter(Mandatory = $false)]
        [string]$ToModel = '',

        [Parameter(Mandatory = $false)]
        [string]$FailureClass = '',

        [Parameter(Mandatory = $false)]
        [string[]]$AttemptedModels = @(),

        [Parameter(Mandatory = $false)]
        [string]$PolicyHash = '',

        [Parameter(Mandatory = $false)]
        [string]$PolicyVersion = ''
    )

    if ([string]::IsNullOrWhiteSpace(([string]$TaskId).Trim())) {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; handoff = $null }
    }
    if ([string]::IsNullOrWhiteSpace(([string]$Objective).Trim())) {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; handoff = $null }
    }
    if ([string]::IsNullOrWhiteSpace(([string]$ToModel).Trim())) {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-to-model'; handoff = $null }
    }
    $handoff = [ordered]@{
        schema_version    = 1
        kind              = 'provider-switch'
        task_id           = ([string]$TaskId).Trim()
        objective         = ([string]$Objective).Trim()
        from_model        = ([string]$FromModel).Trim()
        from_provider     = (Get-ModelProviderFromId ([string]$FromModel).Trim())
        to_model          = ([string]$ToModel).Trim()
        to_provider       = (Get-ModelProviderFromId ([string]$ToModel).Trim())
        failure_class     = ([string]$FailureClass).Trim()
        attempted_models  = @($AttemptedModels)
        attempt_count     = @($AttemptedModels).Count
        policy_hash       = ([string]$PolicyHash).Trim()
        policy_version    = ([string]$PolicyVersion).Trim()
        created_at        = ([DateTime]::UtcNow).ToString('o')
    }
    return [pscustomobject]@{ ok = $true; reason = ''; handoff = $handoff }
}

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
    if ($m.StartsWith('claude-agent/')) { return 'claude-agent' }
    if ($m -match '^claude-(haiku|sonnet|opus|fable)') { return 'claude-agent' }
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
            PolicyVersion = '1.3.0'
            Policy        = $null
        }
    }

    try {
        $rawBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha.ComputeHash($rawBytes)
        $hashStr = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

        $rawText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
        # Strip a leading UTF-8 BOM so Windows PowerShell 5.1 (which otherwise
        # rejects the document) parses exactly like PowerShell 7.
        $rawText = $rawText.TrimStart([char]0xFEFF)
        $parsed = ConvertFrom-Json -InputObject $rawText -ErrorAction Stop

        $res = [pscustomobject]@{
            Status        = 'POLICY_LOADED'
            PolicyPath    = $resolvedPath
            PolicyHash    = $hashStr
            PolicyVersion = if ($parsed.policy_version) { [string]$parsed.policy_version } else { '1.3.0' }
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

    $mIceman = if ($null -ne $pol -and $pol.models.iceman) { [string]$pol.models.iceman.model_id } elseif ($null -ne $pol -and $pol.models.beam) { [string]$pol.models.beam.model_id } else { 'opencode-go/iceman-contributor-free' }
    $mMuse = if ($null -ne $pol -and $pol.models.muse) { [string]$pol.models.muse.model_id } else { 'opencode-go/muse-spark-1.3-contributor' }
    $mTerra = if ($null -ne $pol -and $pol.models.terra) { [string]$pol.models.terra.model_id } else { 'openai/gpt-6.1-terra' }
    $mLuna = if ($null -ne $pol -and $pol.models.luna) { [string]$pol.models.luna.model_id } else { 'openai/gpt-6-luna' }
    $mSol = if ($null -ne $pol -and $pol.models.sol) { [string]$pol.models.sol.model_id } else { 'openai/gpt-6.1-sol' }
    $mAstra = if ($null -ne $pol -and $pol.models.astra) { [string]$pol.models.astra.model_id } else { 'openai/gpt-6-astra' }

    $cat = @{
        'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)';                    Provider = 'none';        Authorized = $true }
        'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = $mIceman;                                 Provider = (Get-ModelProviderFromId $mIceman); Authorized = $true; AlternativeModel = 'opencode/mimo-v2.6-flash-free' }
        'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = $mMuse;                                   Provider = (Get-ModelProviderFromId $mMuse); Authorized = $true; AlternativeModel = $mLuna }
        'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = $mTerra;                                  Provider = 'openai';      Authorized = $true; AlternativeModel = $mMuse }
        'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = $mSol;                                    Provider = 'openai';      Authorized = $true; ExceptionalModel = $mAstra }
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
    $polVer = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyVersion } else { '1.3.0' }

    # T4 is a policy-authorized tier; the caller must prove T3 non-resolution before selection.
    # Astra cannot be selected directly: it is only a fallback after a verified Sol failure.
    if ($Tier -eq 'T4') {
        $authorized = $true
        $authSource = 'AUTO_ROUTER_POLICY_V14'
        $authEvidence = 'policy:t3-verified-failure-gate'
        if ($catModel -match 'astra') {
            $authorized = $false
            $authSource = 'ASTRA_REQUIRES_VERIFIED_SOL_FAILURE'
            $authEvidence = 'none'
        }
    }

    $candidates = switch ($Tier) {
        'T1' { @('opencode-go/iceman-contributor-free', 'opencode/mimo-v2.6-flash-free') }
        'T2' { @('opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna', 'claude-agent/haiku', 'opencode-go/deepseek-v4.1-flash') }
        'T3' { @('openai/gpt-6.1-terra', 'claude-agent/sonnet', 'opencode-go/muse-spark-1.3-contributor', 'opencode-go/deepseek-v4.1-flash') }
        'T4' { @('openai/gpt-6.1-sol', 'openai/gpt-6-astra', 'claude-agent/opus', 'claude-agent/fable', 'opencode-go/muse-spark-1.3-contributor', 'opencode-go/deepseek-v4.1-flash') }
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

function Test-OrchestrationModelKernelFailureProof {
    <#
    .SYNOPSIS
        Kernel-owned failure-proof gate for T3->Sol (T4) and Sol->Astra escalation.
    .DESCRIPTION
        Read-only. Calls Get-OrchestrationTaskModelFailureProof for TaskId +
        RequiredTier and requires: proof ok, policy_hash equals current routing
        policy hash, and proof model/provider equal the canonical required
        model/provider for that tier. Arbitrary bool/string receipts
        (T3FailureVerified, T3FailureReceipt, VerifiedFailureReceipt) are
        DEPRECATED_UNTRUSTED and never authorize escalation.
        Never throws; returns @{ ok, proof, error }.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$RequiredTier = 'T3',
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$PolicyPath = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return @{ ok = $false; proof = $null; error = 'NO_TASK_ID' } }
        $tier = ([string]$RequiredTier).Trim()
        if (($tier -cne 'T3') -and ($tier -cne 'T4')) { return @{ ok = $false; proof = $null; error = 'INVALID_TIER' } }
        $polRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
        if ($polRes.Status -ne 'POLICY_LOADED') { return @{ ok = $false; proof = $null; error = 'POLICY_UNKNOWN' } }
        $polHash = [string]$polRes.PolicyHash
        $pol = $polRes.Policy
        $canonModel = ''
        $canonProvider = ''
        try {
            if ($tier -ceq 'T3' -and $null -ne $pol.models.terra) { $canonModel = [string]$pol.models.terra.model_id; $canonProvider = [string]$pol.models.terra.provider }
            elseif ($tier -ceq 'T4' -and $null -ne $pol.models.sol) { $canonModel = [string]$pol.models.sol.model_id; $canonProvider = [string]$pol.models.sol.provider }
        } catch { $canonModel = ''; $canonProvider = '' }
        if ([string]::IsNullOrWhiteSpace($canonModel)) { return @{ ok = $false; proof = $null; error = 'CANON_UNKNOWN' } }
        $hasFn = (Get-Command Get-OrchestrationTaskModelFailureProof -ErrorAction SilentlyContinue)
        if ($null -eq $hasFn) {
            try {
                $kernelLib = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
                if (Test-Path -LiteralPath $kernelLib -PathType Leaf) { . $kernelLib }
            } catch { }
        }
        $hasFn2 = (Get-Command Get-OrchestrationTaskModelFailureProof -ErrorAction SilentlyContinue)
        if ($null -eq $hasFn2) { return @{ ok = $false; proof = $null; error = 'KERNEL_PROOF_UNAVAILABLE' } }
        $proof = $null
        try { $proof = Get-OrchestrationTaskModelFailureProof -TaskId $tid -RequiredTier $tier -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath } catch { $proof = $null }
        if ($null -eq $proof) { return @{ ok = $false; proof = $null; error = 'PROOF_ABSENT' } }
        $pok = $false
        try { $pok = [bool]$proof.ok } catch { $pok = $false }
        if (-not $pok) { return @{ ok = $false; proof = $proof; error = 'PROOF_NOT_OK' } }
        if ([string]$proof.policy_hash -cne $polHash) { return @{ ok = $false; proof = $proof; error = 'POLICY_HASH_MISMATCH' } }
        if ([string]$proof.model -cne $canonModel) { return @{ ok = $false; proof = $proof; error = 'MODEL_MISMATCH' } }
        if ([string]$proof.provider -cne $canonProvider) { return @{ ok = $false; proof = $proof; error = 'PROVIDER_MISMATCH' } }
        return @{ ok = $true; proof = $proof; error = '' }
    } catch { return @{ ok = $false; proof = $null; error = 'INTERNAL_ERROR' } }
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
        [string]$PolicyPath = '',

        [Parameter(Mandatory = $false)]
        [string]$VerifiedFailureReceipt = '',

        [Parameter(Mandatory = $false)]
        [bool]$NoExecutionStarted = $false,

        [Parameter(Mandatory = $false)]
        [string]$WorkerHost = 'local',

        [Parameter(Mandatory = $false)]
        [string[]]$WorkerCapabilities = @(),

        [Parameter(Mandatory = $false)]
        [bool]$ClaudeAgentProven = $false,

        [Parameter(Mandatory = $false)]
        [string]$TaskId = '',

        [Parameter(Mandatory = $false)]
        [string]$TasksDir = '',

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = ''
    )

    # DEPRECATED_UNTRUSTED: VerifiedFailureReceipt is never trusted. Astra/Sol
    # escalation requires kernel-owned Get-OrchestrationTaskModelFailureProof
    # for TaskId + RequiredTier with matching policy_hash/model/provider.

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
    $costAuth = $true # T4 uses verified-failure policy gates rather than per-call cost approval

    # Admissibilidade estrita por papel do agente
    $admiss = if ($script:AgentModelAdmissibility.ContainsKey($cleanAgent)) { $script:AgentModelAdmissibility[$cleanAgent] } else { $null }

    # Funcao para obter candidatos dinamicos por tier a partir da politica efetiva
    $GetDynamicCandidatesForTier = {
        param([string]$TargetTier)
        $cands = [System.Collections.Generic.List[PSCustomObject]]::new()
        # Insertion sequence: Windows PowerShell 5.1 Sort-Object is not stable
        # for equal Priority keys, so Seq (policy-file order) breaks ties
        # deterministically and identically on PS 5.1 and PS 7.
        $seq = 0

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
                    Seq           = $seq
                })
                $seq++
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
                        Seq           = $seq
                    })
                    $seq++
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
                        Seq           = $seq
                    })
                    $seq++
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
                        Seq           = $seq
                    })
                    $seq++
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
                        Seq           = $seq
                    })
                    $seq++
                }
            }
        }

        return @($cands | Sort-Object Priority, Seq)
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

        # 4b. claude-agent provider gate (policy-level route; productive native
        # dispatch stays HOLD). Every condition is NECESSARY and none alone
        # authorizes a substitute: capability proof (local authenticated 'claude'),
        # remote capability for remote workers, an allowlisted availability reason,
        # proved pre-execution no-start, and exact dispatch-alias identity
        # (model_id + alias; no concrete/inventory ID is ever compared).
        if ($CandObj.Provider -eq 'claude-agent') {
            $capCheck = Test-ClaudeAgentProviderAdmissible -WorkerHost $WorkerHost -WorkerCapabilities $WorkerCapabilities -ClaudeAgentProven $ClaudeAgentProven
            if (-not $capCheck.Admissible) {
                & $RecordExclusion $mId $tier $capCheck.Reason
                return $null
            }
            if ($script:AvailabilityTriggerReasons -notcontains $TriggerReason) {
                & $RecordExclusion $mId $tier 'CLAUDE_AVAILABILITY_REQUIRED'
                return $null
            }
            if (-not [bool]$NoExecutionStarted) {
                & $RecordExclusion $mId $tier 'CLAUDE_NO_START_PROOF_REQUIRED'
                return $null
            }
            # Exact dispatch-alias identity (closed map): the policy entry linked
            # by LogicalId must keep the exact model_id + alias pair. The
            # catalog_inventory_id (local CLI listing) is provenance only and is
            # never read here: no alias->concrete mapping is claimed while
            # resolution stays runtime-unverified.
            $polAlias = ''
            $polModelId = ''
            $logicalId = ([string]$CandObj.LogicalId).Trim()
            if ($null -ne $policy -and $null -ne $policy.models -and -not [string]::IsNullOrWhiteSpace($logicalId)) {
                $lp = $policy.models.PSObject.Properties[$logicalId]
                if ($null -ne $lp -and $null -ne $lp.Value) {
                    if ($null -ne $lp.Value.alias) { $polAlias = [string]$lp.Value.alias }
                    if ($null -ne $lp.Value.model_id) { $polModelId = [string]$lp.Value.model_id }
                }
            }
            $aliasCheck = Resolve-ClaudeAgentAlias -AliasModelId $mId -PolicyAlias $polAlias -PolicyModelId $polModelId
            if (-not $aliasCheck.Matches) {
                & $RecordExclusion $mId $tier $aliasCheck.Reason
                return $null
            }
        }

        # 4c. Fable gate: only as an Astra availability fallback with proved
        # pre-execution evidence (canonical Astra FailedModel + allowlisted
        # availability reason + NoExecutionStarted + Astra attempted + Claude
        # capability/alias proof). A generic Task Kernel receipt
        # (VERIFIED_TASK_FAILURE) NEVER authorizes Fable: the kernel proves
        # T3/T4 Sol, never Astra.
        if ($CandObj.LogicalId -eq 'claude_fable' -or $mId -eq 'claude-agent/fable') {
            $fableAstraCanonical = 'openai/gpt-6-astra'
            $fableAvailOk = (($FailedModel -ceq $fableAstraCanonical) -and
                ($script:AvailabilityTriggerReasons -contains $TriggerReason) -and
                [bool]$NoExecutionStarted -and
                $reallyAttempted.Contains($fableAstraCanonical))
            if (-not $fableAvailOk) {
                & $RecordExclusion $mId $tier 'FABLE_REQUIRES_ASTRA_FAILURE'
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

        # T4 is a capability escalation, never a reaction to a transient provider outage.
        # Kernel-owned gate: requires T3 failure proof for the exact task.
        if ($tier -eq 'T4' -and $reqTier -ne 'T4') {
            if ($TriggerReason -ne 'VERIFIED_TASK_FAILURE') {
                & $RecordExclusion $mId $tier 'T3_FAILURE_PROOF_REQUIRED'
                return $null
            }
            $kpT3 = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T3' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            if (-not [bool]$kpT3.ok) {
                & $RecordExclusion $mId $tier 'T3_FAILURE_PROOF_REQUIRED'
                return $null
            }
        }

        # Astra is not a generic outage fallback. It requires kernel-owned T4
        # (Sol) failure proof for the exact task plus attempted Sol.
        if ($CandObj.Exceptional -or $mId -match 'astra') {
            $kpT4 = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T4' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            if ($reqTier -ne 'T4' -or $TriggerReason -ne 'VERIFIED_TASK_FAILURE' -or
                (-not [bool]$kpT4.ok) -or
                (-not $reallyAttempted.Contains('openai/gpt-6.1-sol'))) {
                & $RecordExclusion $mId $tier 'SOL_VERIFIED_FAILURE_REQUIRED'
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
            ProviderCostAuthorized = $true
            AttemptsCount          = [Math]::Max(1, $reallyAttempted.Count)
            IsDowngrade            = $IsDown
            ReallyAttemptedModels  = @($reallyAttempted)
            PreventivelyExcluded   = @($preventivelyExcluded)
        }
    }

    # Fable e o unico fallback de Astra: honra astra.fallback_candidates ou fail-closed.
    # Quando FailedModel e o Astra canonico, nenhum T4 generico (ex. Opus) pode
    # passar na frente. Somente indisponibilidade provada pre-execucao autoriza
    # Fable; qualquer outro caso fail-closed sem fallback generico. A kernel-owned
    # incapacity path (T3->Sol, Sol->Astra) permanece separada e nao e substituida
    # por este caminho de disponibilidade.
    $astraCanonicalId = 'openai/gpt-6-astra'
    $astraAvailReasons = $script:AvailabilityTriggerReasons
    $isAstraFailed = ($FailedModel -ceq $astraCanonicalId)
    if ($isAstraFailed) {
        $astraProofOk = (($astraAvailReasons -contains $TriggerReason) -and [bool]$NoExecutionStarted -and $reallyAttempted.Contains($astraCanonicalId))
        if (-not $astraProofOk) {
            & $RecordExclusion 'claude-agent/fable' 'T4' 'FABLE_REQUIRES_ASTRA_FAILURE'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Astra failure without proved pre-execution availability proof authorizes no fallback (FABLE_REQUIRES_ASTRA_FAILURE).'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $astraOrder = @()
        if ($null -ne $policy -and $null -ne $policy.models -and $null -ne $policy.models.astra -and $null -ne $policy.models.astra.fallback_candidates) {
            $astraOrder = @($policy.models.astra.fallback_candidates)
        }
        if ($astraOrder.Count -eq 0) { $astraOrder = @('claude_fable', 'muse', 'deepseek_go') }
        foreach ($logical in $astraOrder) {
            $lid = [string]$logical
            $entry = $null
            $entryTier = ''
            if ($null -ne $policy -and $null -ne $policy.models) {
                $prop = $policy.models.PSObject.Properties[$lid]
                if ($null -ne $prop -and $null -ne $prop.Value) {
                    $entry = $prop.Value
                    $tp = @($entry.tier_profiles)
                    if ($tp.Count -gt 0) { $entryTier = [string]$tp[0] }
                }
            }
            if ($null -eq $entry) { continue }
            $candModelId = [string]$entry.model_id
            if ([string]::IsNullOrWhiteSpace($candModelId)) { continue }
            $candTier = $entryTier
            if ([string]::IsNullOrWhiteSpace($candTier)) {
                if ($candModelId -ceq 'claude-agent/fable') { $candTier = 'T4' } else { $candTier = 'T2' }
            }
            $candPrio = 99
            try { if ($null -ne $entry.priority) { $candPrio = [int]$entry.priority } } catch { $candPrio = 99 }
            $candRoles = @()
            try { $candRoles = @($entry.eligible_roles) } catch { $candRoles = @() }
            $candReq = $false
            $candExc = $false
            try { $candReq = [bool]($entry.cost_profile.requires_authorization) } catch { $candReq = $false }
            try { $candExc = [bool]($entry.cost_profile.exceptional_budget_required) } catch { $candExc = $false }
            $candEnabled = $true
            try { $candEnabled = [bool]$entry.enabled } catch { $candEnabled = $true }
            $candObj = [pscustomobject]@{
                ModelId = $candModelId; LogicalId = [string]$entry.id; Provider = [string]$entry.provider
                Enabled = $candEnabled; Priority = $candPrio; EligibleRoles = $candRoles
                RequiresCost = $candReq; Exceptional = $candExc; Tier = $candTier; Seq = 0
            }
            $valid = & $EvaluateCandidate $candObj
            if ($null -ne $valid) {
                $isDown = ($candTier -ne $reqTier)
                return (& $BuildAuthorizedResult $valid.ModelId $candTier "Astra availability fallback to '$($valid.ModelId)' per astra.fallback_candidates order after $TriggerReason (pre-execution proved)." $isDown)
            }
        }
        return [pscustomobject]@{
            Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
            AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
            OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
            TriggerReason=$TriggerReason; Reason='Astra fallback order exhausted; no generic T4 fallback permitted (FABLE_REQUIRES_ASTRA_FAILURE).'
            AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
            AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
            ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
        }
    }

    # Planner (build) dedicated fail-closed path: Luna primary, Haiku specialized
    # fallback (T2-only, build-eligible). Policy-level only until the productive
    # native dispatcher calls it (native pre-dispatch fallback stays HOLD).
    # Never send build through generic T2/T3 candidate enumeration; never silently
    # choose Muse/DeepSeek; build is prohibited from T4.
    if ($cleanAgent -eq 'build') {
        $plannerLunaCanonical = 'openai/gpt-6-luna'
        $plannerAvailReasons = $script:AvailabilityTriggerReasons
        $plannerHaikuAlias = 'claude-agent/haiku'
        if ($FailedModel -cne $plannerLunaCanonical) {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_REQUIRES_LUNA_FAILURE'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner fallback requires exact canonical Luna failure (PLANNER_REQUIRES_LUNA_FAILURE); no generic Muse/DeepSeek fallback.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        if ($plannerAvailReasons -notcontains $TriggerReason) {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_AVAILABILITY_REQUIRED'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner fallback requires an allowlisted availability reason (PLANNER_AVAILABILITY_REQUIRED); ambiguous or capability-failure claims without a model/task-bound T2 kernel proof authorize nothing.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        if (-not [bool]$NoExecutionStarted) {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_NO_START_PROOF_REQUIRED'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner fallback requires proved pre-execution failure (NoExecutionStarted=true); no replay on ambiguous outcome (PLANNER_NO_START_PROOF_REQUIRED).'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $plannerNode = $null
        if ($null -ne $policy -and $null -ne $policy.planner) { $plannerNode = $policy.planner }
        $cfgAlias = ''
        $cfgAliasToken = ''
        if ($null -ne $plannerNode) {
            if ($null -ne $plannerNode.fallback_model_id) { $cfgAlias = [string]$plannerNode.fallback_model_id }
            if ($null -ne $plannerNode.fallback_alias) { $cfgAliasToken = [string]$plannerNode.fallback_alias }
        }
        if ([string]::IsNullOrWhiteSpace($cfgAlias) -or ($cfgAlias -cne $plannerHaikuAlias)) {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_FALLBACK_NOT_HAIKU'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner policy fallback is not the configured Haiku alias (PLANNER_FALLBACK_NOT_HAIKU); no generic Muse/DeepSeek substitution.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $haikuEntry = $null
        if ($null -ne $policy -and $null -ne $policy.models) {
            $lp = $policy.models.PSObject.Properties['claude_haiku']
            if ($null -ne $lp -and $null -ne $lp.Value) { $haikuEntry = $lp.Value }
        }
        if ($null -eq $haikuEntry) {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_HAIKU_UNAVAILABLE'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner Haiku entry unavailable in policy (PLANNER_HAIKU_UNAVAILABLE); no generic Muse/DeepSeek fallback.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        # Exact build-fallback dispatch-alias identity, fail-closed:
        #   planner.fallback_model_id == 'claude-agent/haiku' (checked above),
        #   planner.fallback_alias == 'haiku',
        #   linked claude_haiku entry model_id + alias matching the closed map,
        #   and claude_haiku.resolution_status still 'runtime-unverified'.
        # planner.fallback_catalog_inventory_id (local CLI listing) is provenance
        # only and is NEVER compared: alias->concrete stays runtime-unverified and
        # no concrete/inventory ID is ever treated as a mapping.
        $entryAlias = ''
        $entryModelId = ''
        $entryResolutionStatus = ''
        if ($null -ne $haikuEntry) {
            if ($null -ne $haikuEntry.alias) { $entryAlias = [string]$haikuEntry.alias }
            if ($null -ne $haikuEntry.model_id) { $entryModelId = [string]$haikuEntry.model_id }
            if ($null -ne $haikuEntry.resolution_status) { $entryResolutionStatus = [string]$haikuEntry.resolution_status }
        }
        $plannerAliasReason = ''
        if ([string]::IsNullOrWhiteSpace($cfgAliasToken) -or ($cfgAliasToken -cne 'haiku')) {
            $plannerAliasReason = 'CLAUDE_ALIAS_MISMATCH'
        } else {
            $plannerAliasCheck = Resolve-ClaudeAgentAlias -AliasModelId $cfgAlias -PolicyAlias $entryAlias -PolicyModelId $entryModelId
            if (-not $plannerAliasCheck.Matches) { $plannerAliasReason = [string]$plannerAliasCheck.Reason }
            elseif ($entryResolutionStatus -cne 'runtime-unverified') { $plannerAliasReason = 'CLAUDE_RESOLUTION_STATUS_INVALID' }
        }
        if (-not [string]::IsNullOrWhiteSpace($plannerAliasReason)) {
            & $RecordExclusion $plannerHaikuAlias 'T2' $plannerAliasReason
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason="Planner Haiku dispatch-alias identity check failed ($plannerAliasReason); no alias->concrete mapping is claimed (runtime-unverified) and no generic fallback."
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $plannerCap = Test-ClaudeAgentProviderAdmissible -WorkerHost $WorkerHost -WorkerCapabilities $WorkerCapabilities -ClaudeAgentProven $ClaudeAgentProven
        if (-not $plannerCap.Admissible) {
            & $RecordExclusion $plannerHaikuAlias 'T2' $plannerCap.Reason
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason="Planner Haiku requires local Claude capability proof ($($plannerCap.Reason)); no generic Muse/DeepSeek fallback."
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $haikuTier = 'T2'
        try {
            $tp = @($haikuEntry.tier_profiles)
            if ($tp.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$tp[0])) { $haikuTier = [string]$tp[0] }
        } catch { $haikuTier = 'T2' }
        if ($haikuTier -cne 'T2') {
            & $RecordExclusion $plannerHaikuAlias 'T2' 'PLANNER_HAIKU_NOT_T2'
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner Haiku fallback must stay T2 (PLANNER_HAIKU_NOT_T2); build never routes to T3/T4.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $haikuRoles = @()
        try { $haikuRoles = @($haikuEntry.eligible_roles) } catch { $haikuRoles = @() }
        $haikuPrio = 3
        try { if ($null -ne $haikuEntry.priority) { $haikuPrio = [int]$haikuEntry.priority } } catch { $haikuPrio = 3 }
        $haikuEnabled = $true
        try { $haikuEnabled = [bool]$haikuEntry.enabled } catch { $haikuEnabled = $true }
        $haikuReq = $false
        $haikuExc = $false
        try { $haikuReq = [bool]($haikuEntry.cost_profile.requires_authorization) } catch { $haikuReq = $false }
        try { $haikuExc = [bool]($haikuEntry.cost_profile.exceptional_budget_required) } catch { $haikuExc = $false }
        $haikuCand = [pscustomobject]@{
            ModelId = [string]$haikuEntry.model_id; LogicalId = [string]$haikuEntry.id; Provider = [string]$haikuEntry.provider
            Enabled = $haikuEnabled; Priority = $haikuPrio; EligibleRoles = $haikuRoles
            RequiresCost = $haikuReq; Exceptional = $haikuExc; Tier = $haikuTier; Seq = 0
        }
        $validPlanner = & $EvaluateCandidate $haikuCand
        if ($null -eq $validPlanner) {
            return [pscustomobject]@{
                Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason='Planner Haiku unavailable (already attempted, disabled, ineligible, capability/no-start unproven or provider not allowed); no generic Muse/DeepSeek fallback and never T4.'
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$false
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$false
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        return (& $BuildAuthorizedResult $validPlanner.ModelId $haikuTier "Planner Luna availability fallback to '$($validPlanner.ModelId)' per planner policy after $TriggerReason (pre-execution proved)." $false)
    }

    # On availability/transport faults, T3/T4 first try an explicitly admitted
    # SAME-TIER availability substitute (Sonnet for T3, Opus for T4; claude-agent
    # capability + proved no-start required), never treating a downgrade as equal
    # capability. Only when no same-tier candidate remains may T2 be used as
    # degraded transport recovery. Security and high-risk review retain their
    # no-downgrade invariant. Availability never escalates tier: reaching T3/T4
    # from below requires an explicit, bound incapacity proof (kernel-owned),
    # never a transport/availability reason.
    $transientReasons = $script:AvailabilityTriggerReasons
    if ($reqTier -in @('T3','T4') -and $transientReasons -contains $TriggerReason) {
        $sameTierAvail = & $GetDynamicCandidatesForTier $reqTier
        foreach ($sc in $sameTierAvail) {
            $validSame = & $EvaluateCandidate $sc
            if ($null -ne $validSame) {
                return (& $BuildAuthorizedResult $validSame.ModelId $reqTier "Availability fallback within $reqTier after $TriggerReason (same tier, degraded capability)." $false)
            }
        }
        $downAllowed = $null -ne $admiss -and $admiss.AdmissibleTiers -contains 'T2' -and $admiss.ProhibitedTiers -notcontains 'T2'
        if ($cleanAgent -eq 'reviewer' -and [string]$RequestedSelection.Risk -ne 'low') { $downAllowed = $false }
        if ($cleanAgent -eq 'security-reviewer') { $downAllowed = $false }
        if (-not $downAllowed) {
            foreach ($mc in @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash')) {
                & $RecordExclusion $mc 'T2' 'DOWNGRADE_PROHIBITED'
            }
            return [pscustomobject]@{
                Status='REJECTED_DOWNGRADE_FORBIDDEN'; IsAuthorized=$false; FallbackModel=$null
                AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
                OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
                TriggerReason=$TriggerReason; Reason="Tier $reqTier transport fallback to T2 prohibited for agent '$cleanAgent'."
                AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$true
                AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$true
                ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
            }
        }
        $downCandidates = & $GetDynamicCandidatesForTier 'T2'
        foreach ($mc in @('opencode-go/muse-spark-1.3-contributor','opencode-go/deepseek-v4.1-flash')) {
            foreach ($dc in $downCandidates) {
                if ($dc.ModelId -ne $mc) { continue }
                $validDown = & $EvaluateCandidate $dc
                if ($null -ne $validDown) {
                    return (& $BuildAuthorizedResult $validDown.ModelId 'T2' "Fallback from $reqTier after $TriggerReason (degraded capability)." $true)
                }
            }
        }
        # Do not escalate to Sol/Astra for transport failures or silently retry the same model.
        return [pscustomobject]@{
            Status='EXHAUSTED_NO_ELIGIBLE_FALLBACK'; IsAuthorized=$false; FallbackModel=$null
            AuthorizedModel=$null; FallbackTier=$null; OriginalModel=$origModel
            OriginalProvider=$origProvider; FallbackProvider=$null; IsCrossProvider=$false
            TriggerReason=$TriggerReason; Reason='No eligible T2 transport fallback remains.'
            AuthorizationSource='ROUTER_POLICY'; ProviderCostAuthorized=$true
            AttemptsCount=[Math]::Max(1,$reallyAttempted.Count); IsDowngrade=$true
            ReallyAttemptedModels=@($reallyAttempted); PreventivelyExcluded=@($preventivelyExcluded)
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
            # T3 is a CAPABILITY escalation, never a fallback reaction. It requires
            # an explicit, BOUND incapacity proof (kernel-owned: TaskId + policy
            # hash + canonical model/provider), so a transport/availability reason
            # or a caller-supplied string can never open it. T4/Astra keep their
            # own kernel-owned proof gates below.
            if ($nextTier -ceq 'T3') {
                $kpT3Esc = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T3' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
                if (-not [bool]$kpT3Esc.ok) {
                    foreach ($candBlocked in $upCands) {
                        & $RecordExclusion $candBlocked.ModelId 'T3' 'T3_ESCALATION_REQUIRES_INCAPACITY_PROOF'
                    }
                    continue
                }
            }
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

        # T4 uses policy-approved escalation. A fallback decision is still mandatory.
        if ($effTier -eq 'T4') {
            $t4CostAuth = ([bool]$fb.ProviderCostAuthorized -and ([string]$fb.AuthorizationSource -in @('EXPLICIT_PARAMETER', 'GLOBAL_ENV_OPENCODE_T4_AUTHORIZED', 'ROUTER_POLICY', 'AUTO_ROUTER_POLICY_V14') -or [string]$env:OPENCODE_T4_AUTHORIZED -ieq 'true'))
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
        [bool]$T3FailureVerified = $false,

        [Parameter(Mandatory = $false)]
        [string]$T3FailureReceipt = '',

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
        [string]$RequiredCapability = '',

        [Parameter(Mandatory = $false)]
        [string]$TasksDir = '',

        [Parameter(Mandatory = $false)]
        [string]$RepoRoot = ''
    )

    # DEPRECATED_UNTRUSTED (backward-compat only): T3FailureVerified,
    # T3FailureReceipt, FailureCount are IGNORED for escalation. T4 needs kernel proof.

    $cleanAgent = $AgentName.Trim().ToLowerInvariant()
    $policyRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $PolicyPath
    $polHash = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyHash } else { '' }
    $polVer = if ($policyRes.Status -eq 'POLICY_LOADED') { [string]$policyRes.PolicyVersion } else { '1.3.0' }

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

    # DIRECT_VERIFIED bypass: direct execution by the Planner LLM (no subagent).
    # This is NOT deterministic T0: the Planner LLM still consumes tokens, so it
    # must not be accounted as zero-cost / no-provider. T0 stays exclusive to
    # deterministic execution without any LLM.
    if ($IsTrivialDirect) {
        return [pscustomobject]@{
            Status                    = 'SELECTED'
            Agent                     = $cleanAgent
            requested_role            = $cleanAgent
            Tier                      = 'T0'
            selected_tier             = 'T0'
            TierName                  = 'DirectVerified'
            ModelToken                = 'NONE_DIRECT_VERIFIED'
            EffectiveModelToken       = 'NONE_DIRECT_VERIFIED'
            CatalogModel              = 'planner (inherited)'
            selected_model_id         = 'planner (inherited)'
            selected_provider         = 'planner'
            Provider                  = 'planner'
            AuthorizedSelection       = $true
            Authorized                = $true
            RuntimeTierProven         = $true
            runtime_override_status   = 'PROVEN'
            ProofStatus               = 'PROVEN_DIRECT_VERIFIED'
            AdmissibleTiers           = @('T0')
            SelectionReason           = 'Task is trivial, local and low-risk. Running via DIRECT_VERIFIED on the Planner LLM (cost attributed to Planner, not zero).'
            selection_reason          = 'Task is trivial, local and low-risk. Running via DIRECT_VERIFIED on the Planner LLM (cost attributed to Planner, not zero).'
            EstimatedCostMultiplier   = 1.0
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

    # Planner is pinned to Luna, classified T2 regardless of general T2 Muse pool.
    if ($cleanAgent -eq 'build') {
        $selectedTier = 'T2'
        $reason = 'Planner build is stable on GPT-6 Luna under operational tier T2.'
    }
    elseif ($cleanAgent -eq 'reviewer') {
        if ($Risk -eq 'low' -and $Complexity -in @('trivial','simple')) {
            $selectedTier = 'T2'
            $reason = 'Economical T2 for simple low-risk review.'
        } else {
            $selectedTier = 'T3'
            $reason = 'Capable T3 Terra for review.'
        }
    }
    elseif ($cleanAgent -eq 'security-reviewer') {
        $selectedTier = 'T3'
        $reason = 'Security-reviewer starts at T3 Terra; no T2 downgrade.'
    }
    elseif ($cleanAgent -eq 'engineering-advisor') {
        if ($Complexity -in @('trivial','simple') -and $Risk -eq 'low' -and $FailureCount -eq 0) {
            $selectedTier = 'T2'
            $reason = 'Economical T2 for a simple advisor consultation.'
        } else {
            $selectedTier = 'T3'
            $reason = 'Engineering-advisor uses T3 Terra.'
        }
    }
    elseif ($cleanAgent -eq 'coder') {
        if ($FailureCount -ge 1 -or $Complexity -eq 'complex') {
            $selectedTier = 'T3'
            $reason = 'Coder escalates to T3 Terra for complex work or prior verified failure.'
        } else {
            $selectedTier = 'T2'
            $reason = 'Coder defaults to economical T2 Muse.'
        }
    }
    elseif ($cleanAgent -eq 'debugger') {
        $selectedTier = 'T3'
        $reason = 'Debugger uses T3 Terra for root-cause analysis.'
    }

    elseif ($cleanAgent -eq 'tester') {
        if ($RequiresLlm -and $Complexity -eq 'trivial' -and $Risk -eq 'low') {
            $selectedTier = 'T1'
            $reason = 'Tester uses ultralight T1 for trivial LLM-assisted checks.'
        } elseif ($RequiresLlm -or $Complexity -in @('simple', 'medium', 'complex')) {
            $selectedTier = 'T2'
            $reason = 'Tester uses T2 for test authoring and nontrivial checks.'
        } else {
            $selectedTier = 'T0'
            $reason = 'Tester uses deterministic T0 with no LLM.'
        }
    }

    # Automatic frontier escalation requires kernel-owned failure proof for
    # the exact task (policy_hash + canonical model/provider match).
    # DEPRECATED_UNTRUSTED T3FailureVerified/T3FailureReceipt/FailureCount are
    # ignored. model-select is the Planner entry point for T3->Sol and,
    # after a persisted failed Sol attempt, Sol->Astra. The T4 check runs
    # FIRST: after Sol fails, the head attempt is Sol (T4) while the valid
    # T3 proof lives in verification_history, so a head T3 check alone
    # would hide the Astra escalation.
    $selUsesAstra = $false
    $selT4Proof = $null
    $selT3Proof = $null
    if ($cleanAgent -ne 'build' -and
        $admissibleTiers -contains 'T4' -and $prohibitedTiers -notcontains 'T4') {
        $kpT4Sel = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T4' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
        if ([bool]$kpT4Sel.ok) {
            $astraOk = $false
            try {
                $polA = $policyRes.Policy
                $aEntry = $null
                if ($null -ne $polA -and $null -ne $polA.models -and $null -ne $polA.models.astra) { $aEntry = $polA.models.astra }
                if ($null -ne $aEntry -and [bool]$aEntry.enabled) {
                    $elig = @($aEntry.eligible_roles)
                    $roleOk = ($elig.Count -eq 0) -or ($elig -contains $cleanAgent)
                    $provOk = $true
                    if ($null -ne $polA.providers) {
                        $ppA = $polA.providers.PSObject.Properties[[string]$aEntry.provider]
                        if ($null -ne $ppA -and $null -ne $ppA.Value -and $ppA.Value.enabled -eq $false) { $provOk = $false }
                    }
                    if ($roleOk -and $provOk) { $astraOk = $true }
                }
            } catch { $astraOk = $false }
            if ($astraOk) {
                $selectedTier = 'T4'
                $reason = 'Kernel-owned T4 (Sol) failure proof; policy escalates to T4 Astra.'
                $selUsesAstra = $true
                $selT4Proof = $kpT4Sel.proof
            } else {
                $selectedTier = 'T4'
                $reason = 'Kernel-owned T4 (Sol) failure proof; Astra unavailable, fail closed to T4 Sol.'
                $selT4Proof = $kpT4Sel.proof
            }
        } else {
            $kpT3Sel = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T3' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            if ([bool]$kpT3Sel.ok) {
                $selectedTier = 'T4'
                $reason = 'Kernel-owned T3 failure proof; policy escalates to T4 Sol.'
                $selT3Proof = $kpT3Sel.proof
            }
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

    # Coder T4 check: coder NEVER T4 without kernel-owned proof (T3 for Sol,
    # T4 for Astra). FailureCount alone never authorizes; proof implies
    # persisted failures. T4 is checked first so the Astra path survives its
    # own head (Sol) while the T3 proof lives in history.
    if ($cleanAgent -eq 'coder' -and $selectedTier -eq 'T4') {
        $coderKeep = $false
        if ($selUsesAstra -or ($null -ne $selT4Proof) -or ($null -ne $selT3Proof)) {
            $coderKeep = $true
        } else {
            $kpCT4 = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T4' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            if ([bool]$kpCT4.ok) {
                $coderKeep = $true
                $selT4Proof = $kpCT4.proof
            } else {
                $kpCoder = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T3' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
                if ([bool]$kpCoder.ok) {
                    $coderKeep = $true
                    $selT3Proof = $kpCoder.proof
                }
            }
        }
        if (-not $coderKeep) {
            $selectedTier = 'T3'
            $reason = "Cost invariant enforced: coder prohibited from T4 without kernel-owned T3 failure proof."
            $selUsesAstra = $false
            $selT4Proof = $null
            $selT3Proof = $null
        }
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
    if (-not $selUsesAstra -and $visualRequested -and ($terraEligibleAgents -contains $cleanAgent) -and ($admissibleTiers -contains 'T3')) {
        $selectedTier = 'T3'
        $reason = "Capable tier T3 selected for visual/document capability (Terra)."
    }

    # Catalog and authorization check: separate technical justification from explicit cost authorization
    $catalogRes = Resolve-CatalogModel -Tier $selectedTier -Catalog $ModelCatalog -FailureCount $FailureCount -Risk $Risk -ProviderCostAuthorized $ProviderCostAuthorized -PolicyPath $PolicyPath -IgnoreUserConfig $IgnoreUserConfig
    if ($selUsesAstra -and $selectedTier -eq 'T4') {
        $astraId = ''
        $astraProv = ''
        try {
            if ($null -ne $policyRes.Policy -and $null -ne $policyRes.Policy.models -and $null -ne $policyRes.Policy.models.astra) {
                $astraId = [string]$policyRes.Policy.models.astra.model_id
                $astraProv = [string]$policyRes.Policy.models.astra.provider
            }
        } catch { $astraId = ''; $astraProv = '' }
        if (-not [string]::IsNullOrWhiteSpace($astraId)) {
            $catalogRes.CatalogModel = $astraId
            $catalogRes.Provider = if (-not [string]::IsNullOrWhiteSpace($astraProv)) { $astraProv } else { Get-ModelProviderFromId $astraId }
            $catalogRes.CostAuthorizationSource = 'AUTO_ROUTER_POLICY_V14'
            $catalogRes.CostAuthorizationEvidence = 'policy:t4-verified-failure-gate'
            $catalogRes.IsAuthorized = $true
            $catalogRes.ProviderCostAuthorized = $true
        } else {
            $selUsesAstra = $false
            $reason = 'Kernel-owned T4 (Sol) failure proof; Astra unavailable, fail closed to T4 Sol.'
        }
    }
    if ($cleanAgent -eq 'build') {
        # Planner is not the general T2 pool. Keep Luna and its dedicated token.
        # Recorded fallback: Luna -> Haiku only (claude-agent, T2-only, build
        # eligible, capability + proved no-start required). Never silently remap
        # Planner to Muse or DeepSeek Go; DeepSeek Go is additionally blocked
        # (ZDR_EXPIRED_UNCONFIRMED). Build never routes to T4.
        $catalogRes.CatalogModel = 'openai/gpt-6-luna'
        $catalogRes.ModelToken = 'MODEL_PLANNER'
        $catalogRes.Provider = 'openai'
        $catalogRes.FallbackCandidates = @('claude-agent/haiku')
    }
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

    if ($cleanAgent -eq 'build') { $fallbackDefaultToken = 'MODEL_PLANNER' }
    $effectiveToken = if ($NativeModelOverrideProven) { $modelToken } else { $fallbackDefaultToken }
    $overrideNote = ''
    $proofStatus = if ($NativeModelOverrideProven) { 'PROVEN' } else { 'PROOF_ABSENT' }
    $runtimeTierProven = [bool]$NativeModelOverrideProven

    if (-not $NativeModelOverrideProven) {
        $overrideNote = 'Native subagent model parameter unproven in OpenCode V2. Using conservative template token fallback.'
    }

    $kernelProofRef = ''
    $kernelProofDigest = ''
    if ($selectedTier -eq 'T4') {
        $refProof = $null
        if ($null -ne $selT4Proof) {
            $refProof = $selT4Proof
        } elseif ($null -ne $selT3Proof) {
            $refProof = $selT3Proof
        } else {
            $kpRT4 = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T4' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            if ([bool]$kpRT4.ok -and $null -ne $kpRT4.proof) {
                $refProof = $kpRT4.proof
            } else {
                $kpRT3 = Test-OrchestrationModelKernelFailureProof -TaskId $TaskId -RequiredTier 'T3' -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath
                if ([bool]$kpRT3.ok -and $null -ne $kpRT3.proof) {
                    $refProof = $kpRT3.proof
                }
            }
        }
        if ($null -ne $refProof) {
            $kernelProofRef = [string]$refProof.reference
            $kernelProofDigest = [string]$refProof.digest
        }
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
        KernelProofReference      = $kernelProofRef
        KernelProofDigest         = $kernelProofDigest
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

function Test-OrchestrationNativeModelOverrideProof {
    <#
    .SYNOPSIS
        Narrow native subagent.model override proof (fail-closed, live-server only).
    .DESCRIPTION
        Returns @{ ok, reason, live_version }.
        ok is true ONLY when the CURRENT live local OpenCode server version,
        retrieved read-only via `opencode api get /api/info`, is exactly in
        the canonical supported allowlist (2.2.5, 2.0.23; both official raw
        tags contain SubagentTool.Input.model with override ?? agent.model ??
        parent.model). TaskKernel runtime profile/version metadata is caller
        supplied at create time and NEVER authorizes this capability; this
        helper accepts no task profile/version parameters.
        Unknown versions and unavailable live API fail closed. Never infers
        proof from a caller boolean, profile, or task record. Never throws.
        Bounded reason codes only, no payloads. Test seam: -InfoReader
        scriptblock returning a version string or an object with a version
        field. The seam is an in-process function parameter for direct unit
        tests only; the task-kernel CLI never exposes it. No
        environment-variable override exists: a caller cannot supply proof
        via the process environment, and any
        ORCHESTRATION_TEST_NATIVE_INFO_VERSION value is ignored and
        never sources live_version.
        Residual assumption: local `opencode api get /api/info` reaches the
        same local OpenCode server that receives the Planner's subsequent
        native `subagent` call. No session/dispatch-endpoint binding is proven.
    #>
    [CmdletBinding()]
    param(
        $InfoReader = $null
    )
    try {
        $live = ''
        $usedReader = $false
        try {
            if ($null -ne $InfoReader -and ($InfoReader -is [scriptblock])) {
                $usedReader = $true
                $raw = & $InfoReader
                if ($null -ne $raw) {
                    if ($raw -is [string]) { $live = ([string]$raw).Trim() }
                    elseif ($raw -is [System.Collections.IDictionary]) {
                        foreach ($k in @('version', 'Version', 'server_version', 'opencode_version')) {
                            if ($raw.Contains($k) -and (-not [string]::IsNullOrWhiteSpace([string]$raw[$k]))) { $live = ([string]$raw[$k]).Trim(); break }
                        }
                        if ([string]::IsNullOrWhiteSpace($live) -and $raw.Contains('data')) {
                            $d = $raw['data']
                            if ($d -is [System.Collections.IDictionary]) {
                                foreach ($k in @('version', 'Version')) {
                                    if ($d.Contains($k) -and (-not [string]::IsNullOrWhiteSpace([string]$d[$k]))) { $live = ([string]$d[$k]).Trim(); break }
                                }
                            }
                        }
                    }
                    else {
                        $p = $null
                        try { $p = $raw.PSObject.Properties['version'] } catch { $p = $null }
                        if ($null -ne $p -and (-not [string]::IsNullOrWhiteSpace([string]$p.Value))) { $live = ([string]$p.Value).Trim() }
                        else {
                            try { $p = $raw.PSObject.Properties['Version'] } catch { $p = $null }
                            if ($null -ne $p -and (-not [string]::IsNullOrWhiteSpace([string]$p.Value))) { $live = ([string]$p.Value).Trim() }
                        }
                    }
                }
            }
        } catch { $live = '' }
        if ([string]::IsNullOrWhiteSpace($live) -and (-not $usedReader)) {
            try {
                $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
                if ($null -eq $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
                $resolved = ''
                if (($null -ne $cmd) -and (-not [string]::IsNullOrWhiteSpace([string]$cmd.Source))) { $resolved = ([string]$cmd.Source) }
                if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = 'cmd.exe'
                    $psi.Arguments = '/s /c ""' + $resolved + '" api get /api/info"'
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow = $true
                    $proc = [System.Diagnostics.Process]::Start($psi)
                    if ($null -ne $proc) {
                        $outTask = $proc.StandardOutput.ReadToEndAsync()
                        $null = $proc.StandardError.ReadToEndAsync()
                        if ($proc.WaitForExit(15000)) {
                            $stdout = ''
                            try { $stdout = ([string]$outTask.Result) } catch { $stdout = '' }
                            if (-not [string]::IsNullOrWhiteSpace($stdout) -and $stdout.Length -lt 65536) {
                                try {
                                    $doc = ($stdout | ConvertFrom-Json -ErrorAction Stop)
                                    $cand = @()
                                    try { $cand += [string]$doc.version } catch { }
                                    try { $cand += [string]$doc.Version } catch { }
                                    try { if ($null -ne $doc.data) { $cand += [string]$doc.data.version } catch { } } catch { }
                                    foreach ($c in $cand) {
                                        if (-not [string]::IsNullOrWhiteSpace($c)) { $live = ([string]$c).Trim(); break }
                                    }
                                } catch { $live = '' }
                                if ([string]::IsNullOrWhiteSpace($live)) {
                                    $m = [regex]::Match($stdout, '\d+\.\d+\.\d+')
                                    if ($m.Success) { $live = $m.Value.Trim() }
                                }
                            }
                        }
                        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
                    }
                }
            } catch { $live = '' }
        }
        if ([string]::IsNullOrWhiteSpace($live)) {
            return @{ ok = $false; reason = 'INFO_UNAVAILABLE'; live_version = '' }
        }
        if ($live.Length -gt 64) { $live = $live.Substring(0, 64) }
        $live = $live.Trim()
        if ($live -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$') {
            return @{ ok = $false; reason = 'INFO_UNAVAILABLE'; live_version = '' }
        }
        $supported = @('2.2.5', '2.0.23')
        if ($supported -cnotcontains $live) {
            return @{ ok = $false; reason = 'UNSUPPORTED_RUNTIME'; live_version = $live }
        }
        return @{ ok = $true; reason = ''; live_version = $live }
    } catch { return @{ ok = $false; reason = 'INTERNAL_ERROR'; live_version = '' } }
}
