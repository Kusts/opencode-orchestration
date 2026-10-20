<#!
.SYNOPSIS
    O1 bundle consumer: agent-profile-bundle/v1 loader + Objective pinning
    (PLAN-ORCH O1, SPEC section 5).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Reads and validates the
    immutable bundle produced by Agent Config (C1) WITHOUT dot-sourcing
    cross-repo code and WITHOUT keeping editable forks of the 19 agents.
    Pure loader: no network, no remote fetch, no runtime mutation.

    Overlay rule (O1.3): orchestration-role-overlay carries ONLY dispatch
    metadata (pool, dispatch_hint). Permissions, prompts, modes and any
    authority-bearing field inside an overlay is rejected with
    OVERLAY_REJECTED. No overlay ever edits the canonical profile.

    Pinning (O1.4): an Objective captures bundle_digest/source_commit_sha
    at creation (New-ObjectiveBundlePin). A bundle updated on disk during
    execution NEVER changes the policy of an in-flight effect:
    Test-ObjectiveBundlePin returns PIN_CURRENT or STALE_POLICY (revalidate
    only at checkpoint). Missing/incompatible bundle never yields
    Authorized=true and never degrades HIGH to LOW: it yields
    BUNDLE_UNAVAILABLE / INCOMPATIBLE_BUNDLE / STALE_POLICY plus safe
    alternatives. DEGRADED_PINNED is allowed ONLY for the last valid,
    compatible pinned bundle and only for local/READ_ONLY-compatible work.

    PowerShell 5.1 compatible. ASCII-only on purpose.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:ConsumerSchemaV1 = 'agent-profile-bundle/v1'
$script:ConsumerValidActions = @('edit', 'shell', 'subagent')
$script:ConsumerValidEffects = @('allow', 'ask', 'deny')
$script:ConsumerSecretPattern = '(?i)token|secret|passwd|password|api[_-]?key|gh[op]_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9]{16,}|Bearer\s+[A-Za-z0-9][A-Za-z0-9_\.\-]{8,}'
$script:ConsumerTopKeys = @('schema', 'bundle_id', 'source_repository', 'source_commit_sha', 'payload_digest', 'target_runtime', 'compatibility', 'policy_refs', 'agent_profiles', 'managed_paths', 'legacy_compatibility', 'format_version')
$script:ConsumerCompatKeys = @('dialect', 'minimum_capabilities')
$script:ConsumerPolicyKeys = @('agent_profiles', 'native_permissions', 'risk_requirements', 'capability_catalog')
$script:ConsumerAgentKeys = @('agent_id', 'mode', 'native_permissions')
$script:ConsumerPermKeys = @('action', 'resource', 'effect')
$script:ConsumerManagedKeys = @('resource', 'json_pointer', 'namespace', 'owner')
$script:ConsumerLegacyKeys = @('v1_mutation')
$script:ConsumerOverlayKeys = @('pool', 'dispatch_hint')
$script:ConsumerSupportedCapabilities = @('agents', 'permissions')

function Get-ConsumerCanonicalJson {
    [CmdletBinding()]
    param($Bundle)
    $agents = @($Bundle.agent_profiles | Sort-Object { $_.agent_id } | ForEach-Object {
        $np = @($_.native_permissions | ForEach-Object {
            [ordered]@{ action = [string]$_.action; resource = [string]$_.resource; effect = [string]$_.effect }
        })
        [ordered]@{ agent_id = [string]$_.agent_id; mode = [string]$_.mode; native_permissions = $np }
    })
    $mp = @($Bundle.managed_paths | ForEach-Object {
        $e = [ordered]@{ resource = [string]$_.resource }
        if ($null -ne $_.json_pointer) { $e['json_pointer'] = [string]$_.json_pointer }
        if ($null -ne $_.namespace) { $e['namespace'] = [string]$_.namespace }
        $e['owner'] = [string]$_.owner
        $e
    })
    $o = [ordered]@{
        schema = [string]$Bundle.schema
        bundle_id = [string]$Bundle.bundle_id
        source_repository = [string]$Bundle.source_repository
        source_commit_sha = [string]$Bundle.source_commit_sha
        target_runtime = [string]$Bundle.target_runtime
        compatibility = [ordered]@{
            dialect = [string]$Bundle.compatibility.dialect
            minimum_capabilities = @($Bundle.compatibility.minimum_capabilities | ForEach-Object { [string]$_ })
        }
        policy_refs = [ordered]@{
            agent_profiles = [string]$Bundle.policy_refs.agent_profiles
            native_permissions = [string]$Bundle.policy_refs.native_permissions
            risk_requirements = [string]$Bundle.policy_refs.risk_requirements
            capability_catalog = [string]$Bundle.policy_refs.capability_catalog
        }
        agent_profiles = $agents
        managed_paths = $mp
        legacy_compatibility = [ordered]@{ v1_mutation = [bool]$Bundle.legacy_compatibility.v1_mutation }
        format_version = [int]$Bundle.format_version
    }
    return ($o | ConvertTo-Json -Depth 10 -Compress)
}

function Get-ConsumerDigest {
    [CmdletBinding()]
    param([string]$CanonicalJson)
    $bytes = [Text.Encoding]::UTF8.GetBytes($CanonicalJson)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ('sha256:' + (($hash | ForEach-Object { $_.ToString('x2') }) -join ''))
    }
    finally { $sha.Dispose() }
}

function Test-ConsumerUnknownKeys {
    [CmdletBinding()]
    param($Object, [string[]]$Allowed, $AddFinding, [string]$Where)
    if ($null -eq $Object) { return }
    foreach ($prop in @($Object.PSObject.Properties)) {
        if ($Allowed -notcontains $prop.Name) {
            & $AddFinding 'UNKNOWN_FIELD' ("unknown property $Where.$($prop.Name)")
        }
    }
}

function Read-AgentProfileBundle {
    <#
    .SYNOPSIS
        Loads + fully validates a bundle.json file. Never throws on
        content. Returns @{ Ok; Code; Bundle; Findings } where Code is
        BUNDLE_OK | BUNDLE_UNAVAILABLE | INCOMPATIBLE_BUNDLE |
        BUNDLE_INTEGRITY_FAILED | INVALID_AGENT | INVALID_PERMISSION |
        INVALID_PATH | UNKNOWN_FIELD | SECRET_SUSPECT | INVALID_JSON.
        Absence or incompatibility is data, never an exception, and
        never implies authorization.
    #>
    [CmdletBinding()]
    param([string]$LiteralPath)
    $findings = New-Object System.Collections.ArrayList
    $add = { param($c, $m) [void]$findings.Add([ordered]@{ Code = $c; Message = $m }) }.GetNewClosure()
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf))) {
        & $add 'BUNDLE_UNAVAILABLE' 'no bundle file at path (offline snapshot required for fallback)'
        return @{ Ok = $false; Code = 'BUNDLE_UNAVAILABLE'; Bundle = $null; Findings = $findings.ToArray() }
    }
    try { $raw = [IO.File]::ReadAllText($LiteralPath, [Text.Encoding]::UTF8) }
    catch {
        & $add 'BUNDLE_UNAVAILABLE' ("unreadable bundle: " + $_.Exception.Message)
        return @{ Ok = $false; Code = 'BUNDLE_UNAVAILABLE'; Bundle = $null; Findings = $findings.ToArray() }
    }
    try { $b = $raw | ConvertFrom-Json }
    catch {
        & $add 'INVALID_JSON' $_.Exception.Message
        return @{ Ok = $false; Code = 'INVALID_JSON'; Bundle = $null; Findings = $findings.ToArray() }
    }
    if ($raw -match $script:ConsumerSecretPattern) { & $add 'SECRET_SUSPECT' 'secret-looking token in payload' }
    Test-ConsumerUnknownKeys -Object $b -Allowed $script:ConsumerTopKeys -AddFinding $add -Where 'bundle'
    if ($b.schema -cne $script:ConsumerSchemaV1) { & $add 'INCOMPATIBLE_BUNDLE' ("schema must be $($script:ConsumerSchemaV1)") }
    if ([string]::IsNullOrWhiteSpace([string]$b.bundle_id)) { & $add 'INVALID_AGENT' 'missing: bundle_id' }
    if ($b.source_repository -cne 'kust-projetos/agent-config') { & $add 'INCOMPATIBLE_BUNDLE' 'foreign source_repository' }
    foreach ($f in @('payload_digest', 'target_runtime', 'compatibility', 'policy_refs', 'agent_profiles', 'managed_paths', 'legacy_compatibility', 'format_version')) {
        if ($null -eq $b.$f) { & $add 'INVALID_AGENT' ("missing: $f") }
    }
    if (($null -ne $b.source_commit_sha) -and ($b.source_commit_sha -notmatch '^[0-9a-f]{40}$')) { & $add 'INVALID_AGENT' 'source_commit_sha must be 40 hex' }
    if (($null -ne $b.target_runtime) -and ($b.target_runtime -cne 'opencode-v2')) { & $add 'INCOMPATIBLE_BUNDLE' 'target_runtime must be opencode-v2' }
    if (($null -ne $b.format_version) -and (([string]$b.format_version) -notmatch '^\d{1,9}$')) { & $add 'INCOMPATIBLE_BUNDLE' 'format_version must be integer 1' }
    else {
        $fv = 0
        if (($null -ne $b.format_version) -and (-not [int]::TryParse([string]$b.format_version, [ref]$fv))) { & $add 'INCOMPATIBLE_BUNDLE' 'format_version must be integer 1' }
        elseif (($null -ne $b.format_version) -and ($fv -ne 1)) { & $add 'INCOMPATIBLE_BUNDLE' 'format_version must be 1' }
    }
    if ($null -ne $b.compatibility) {
        Test-ConsumerUnknownKeys -Object $b.compatibility -Allowed $script:ConsumerCompatKeys -AddFinding $add -Where 'compatibility'
        if ($b.compatibility.dialect -cne 'v2') { & $add 'INCOMPATIBLE_BUNDLE' 'compatibility.dialect must be v2' }
        $caps = @($b.compatibility.minimum_capabilities)
        if (($caps.Count -eq 0) -or (@($caps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)) { & $add 'INVALID_AGENT' 'minimum_capabilities must list at least one' }
        foreach ($cap in @($caps)) {
            if ($script:ConsumerSupportedCapabilities -notcontains [string]$cap) { & $add 'INCOMPATIBLE_BUNDLE' ("unsupported capability: $cap") }
        }
    }
    if ($null -ne $b.policy_refs) {
        Test-ConsumerUnknownKeys -Object $b.policy_refs -Allowed $script:ConsumerPolicyKeys -AddFinding $add -Where 'policy_refs'
    }
    if ($null -ne $b.legacy_compatibility) {
        Test-ConsumerUnknownKeys -Object $b.legacy_compatibility -Allowed $script:ConsumerLegacyKeys -AddFinding $add -Where 'legacy_compatibility'
        $vm = $b.legacy_compatibility.v1_mutation
        if (($vm -isnot [bool]) -or ([bool]$vm -ne $false)) { & $add 'INCOMPATIBLE_BUNDLE' 'v1_mutation must be boolean false' }
    }
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($a in @($b.agent_profiles)) {
        Test-ConsumerUnknownKeys -Object $a -Allowed $script:ConsumerAgentKeys -AddFinding $add -Where 'agent_profiles[]'
        if (($null -eq $a.agent_id) -or ($a.agent_id -notmatch '^[a-z][a-z0-9-]*$')) { & $add 'INVALID_AGENT' ("bad agent_id") }
        elseif (-not $ids.Add([string]$a.agent_id)) { & $add 'INVALID_AGENT' ("duplicate: $($a.agent_id)") }
        if ([string]::IsNullOrWhiteSpace([string]$a.mode)) { & $add 'MISSING_FIELD' ("agent $($a.agent_id) without mode") }
        $npList = @($a.native_permissions)
        if ($npList.Count -eq 0) { & $add 'INVALID_AGENT' ("agent $($a.agent_id) without native permissions (explicit deny-all required if intended)") }
        foreach ($p in @($a.native_permissions)) {
            Test-ConsumerUnknownKeys -Object $p -Allowed $script:ConsumerPermKeys -AddFinding $add -Where 'permission'
            if (($script:ConsumerValidActions -notcontains $p.action) -or ($script:ConsumerValidEffects -notcontains $p.effect) -or ([string]::IsNullOrWhiteSpace($p.resource))) {
                & $add 'INVALID_PERMISSION' ("bad permission on $($a.agent_id)")
            }
        }
    }
    foreach ($m in @($b.managed_paths)) {
        Test-ConsumerUnknownKeys -Object $m -Allowed $script:ConsumerManagedKeys -AddFinding $add -Where 'managed_paths[]'
        $res = [string]$m.resource
        if ([string]::IsNullOrWhiteSpace($res) -or ($res -match '\.\.') -or ($res -match '^[a-zA-Z]:') -or ($res -match '^\\\\') -or ($res -match '^/')) {
            & $add 'INVALID_PATH' ("bad resource path: $res")
        }
        if (($null -ne $m.owner) -and ($m.owner -cne 'agent-config')) { & $add 'INVALID_PATH' ("foreign owner: $($m.owner)") }
    }
    $blocking = @($findings | Where-Object { $_.Code -cne 'SECRET_SUSPECT' })
    if ($blocking.Count -eq 0) {
        try {
            $canon = Get-ConsumerCanonicalJson -Bundle $b
            if ((Get-ConsumerDigest -CanonicalJson $canon) -cne $b.payload_digest) {
                & $add 'BUNDLE_INTEGRITY_FAILED' 'payload_digest mismatch'
            }
        }
        catch { & $add 'BUNDLE_INTEGRITY_FAILED' ("canonicalize failed: " + $_.Exception.Message) }
    }
    $arr = $findings.ToArray()
    if ($arr.Count -gt 0) {
        $code = $arr[0].Code
        return @{ Ok = $false; Code = $code; Bundle = $null; Findings = $arr }
    }
    return @{ Ok = $true; Code = 'BUNDLE_OK'; Bundle = $b; Findings = @() }
}

function Resolve-BundleAgentProfile {
    <#
    .SYNOPSIS
        Resolves one agent from a loaded (Ok) bundle. Optional -Overlay
        carries dispatch metadata ONLY (pool, dispatch_hint); any
        permissions/prompt/mode/authority key is rejected with
        OVERLAY_REJECTED. Returns @{ Ok; Code; Profile } with
        UNKNOWN_AGENT when the id is absent.
    #>
    [CmdletBinding()]
    param($Bundle, [string]$AgentId, $Overlay = $null)
    if (($null -eq $Bundle) -or ([string]::IsNullOrWhiteSpace($AgentId))) {
        return @{ Ok = $false; Code = 'UNKNOWN_AGENT'; Profile = $null }
    }
    $hit = @($Bundle.agent_profiles | Where-Object { $_.agent_id -ceq $AgentId }) | Select-Object -First 1
    if ($null -eq $hit) {
        return @{ Ok = $false; Code = 'UNKNOWN_AGENT'; Profile = $null }
    }
    $ov = [ordered]@{}
    if ($null -ne $Overlay) {
        foreach ($prop in @($Overlay.PSObject.Properties)) {
            if ($script:ConsumerOverlayKeys -notcontains $prop.Name) {
                return @{ Ok = $false; Code = 'OVERLAY_REJECTED'; Profile = $null }
            }
            $ov[$prop.Name] = $prop.Value
        }
    }
    $np = @($hit.native_permissions | ForEach-Object {
        [ordered]@{ action = [string]$_.action; resource = [string]$_.resource; effect = [string]$_.effect }
    })
    return @{ Ok = $true; Code = 'BUNDLE_OK'; Profile = [ordered]@{
        agent_id = [string]$hit.agent_id
        mode = [string]$hit.mode
        native_permissions = $np
        overlay = $ov
    } }
}

function New-ObjectiveBundlePin {
    <#
    .SYNOPSIS
        Captures the bundle identity into an Objective envelope.
        Pure constructor: no store writes.
    #>
    [CmdletBinding()]
    param($Bundle, [string]$ObjectiveId)
    if (($null -eq $Bundle) -or ([string]::IsNullOrWhiteSpace($ObjectiveId))) { return $null }
    return [ordered]@{
        objective_id = $ObjectiveId
        bundle_digest = [string]$Bundle.payload_digest
        source_commit_sha = [string]$Bundle.source_commit_sha
        bundle_id = [string]$Bundle.bundle_id
        status = 'PIN_CURRENT'
    }
}

function Test-ObjectiveBundlePin {
    <#
    .SYNOPSIS
        Compares a pin against a freshly loaded bundle. Returns
        PIN_CURRENT | STALE_POLICY | BUNDLE_UNAVAILABLE |
        INCOMPATIBLE_BUNDLE. A changed bundle NEVER silently upgrades
        an in-flight objective: STALE_POLICY forces revalidation at
        checkpoint. Never returns authorization.
    #>
    [CmdletBinding()]
    param($Pin, $BundleLoad)
    if ($null -eq $Pin) { return 'BUNDLE_UNAVAILABLE' }
    if (($null -eq $BundleLoad) -or (-not $BundleLoad.Ok)) {
        if (($null -ne $BundleLoad) -and ($BundleLoad.Code -ceq 'INCOMPATIBLE_BUNDLE')) { return 'INCOMPATIBLE_BUNDLE' }
        return 'BUNDLE_UNAVAILABLE'
    }
    $b = $BundleLoad.Bundle
    if (($b.payload_digest -cne $Pin.bundle_digest) -or ($b.source_commit_sha -cne $Pin.source_commit_sha)) {
        return 'STALE_POLICY'
    }
    return 'PIN_CURRENT'
}
