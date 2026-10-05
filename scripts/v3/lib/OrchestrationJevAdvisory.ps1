<#!
.SYNOPSIS
    V3 Jev advisory integration kernel-side (Phase 29, slice 1).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the
    kernel-side advisory slice from the V3.1 runtime-reliability
    addendum (PLAN Phase 29 tasks 1-12 kernel side, SPEC section 19):
    Jev persistently available as bounded decision support, never
    an authority source.

      - Flag source/registry/capability-flags.json node
        jev_advisory {enabled:false, shadow:true}: born OFF.
        shadow=true records would-consult without calling.
        Activation follows the same regime as the other flags
        (human decision with evidence).
      - Policy registry source/registry/jev-advisory-policy.json
        (version 1): closed allowed tool set (jev_check, jev_gate,
        jev_score, jev_decide), 30s request budget, 10s
        health/catalog probe budgets, circuit identical to the MCP
        policy (threshold 2, cooldown 300s), criticality default
        optional (JEV_UNAVAILABLE means deterministic fallback,
        never blocks the task), credential_source {type:env,
        name:JEV_API_KEY} and transport {base_url_env:JEV_BASE_URL,
        model_env:JEV_MODEL} carrying the variable NAMES only, never
        a value, and advisory-only authority with an explicit
        cannot list. A missing or divergent policy fails closed
        with JEV_POLICY_INVALID: this file never falls back to
        silent defaults and never proceeds on a drifted catalog.
      - Bounded invoke REUSES the Phase 28 envelope
        (OrchestrationMcpSafety.ps1, class advisory): this lib
        orchestrates (Jev policy check, trigger check, flag check,
        credential check, envelope invoke, advisory mapping) and
        creates no parallel timeout/circuit primitives. A
        caller-supplied -Probe (the synthetic seam used by the
        suite) keeps byte-compatible behaviour. When no probe is
        supplied and a -State plus a configured transport are
        present, the built-in HTTP probe
        (New-JevAdvisoryHttpProbe) runs INSIDE that same envelope,
        so budget, circuit, capacity and telemetry stay governed by
        the envelope; without -State the call is refused
        structured (INVALID_REQUEST, no invented content).
      - Real transport (Phase 29 slice 2) is user-owned environment
        only and fail-closed: Resolve-JevAdvisoryTransportConfig
        requires JEV_BASE_URL (absolute http/https) and defaults
        JEV_MODEL to jev-latest, with no key-prefix routing.
        ConvertTo-JevAdvisoryWireRequest is the pure per-tool wire
        mapping (jev-mcp protocol: POST {model,state,questions} with
        Bearer auth). The probe is SELF-CONTAINED (fresh runspace,
        no caller scope, env vars are visible), uses raw
        HttpWebRequest for PS 5.1, never throws and never returns
        the key or the base URL; every outcome is a structured
        object with a closed error_kind (auth | server | timeout |
        malformed | network | not_configured | internal).
      - Deterministic trigger policy (Test-JevAdvisoryTrigger):
        pure function over a structured descriptor, no LLM.
        trivial_local never consults. Otherwise the first set
        boundary flag wins with a stable trigger_reason.
      - Authority guard (Invoke-JevAdvisoryGrantGate): always
        denies, McpSafetyGrantGate pattern. Any Jev output shape,
        including null or hostile, yields granted=false,
        widened=false, model_selected=false, done_written=false
        with status JEV_ADVISORY_CANNOT_GRANT. Kernel, verifier,
        reviewer and security always win
        (Get-JevAdvisoryEffectiveDecision folds Jev advice under
        the kernel/verifier decision).
      - Advisory evidence (Write-JevAdvisoryEvidence): sanitized
        bounded JSONL (tool, trigger_reason, input hash,
        sanitized output summary with len:value redaction,
        budget_s, circuit state, mode shadow|active, timestamp).
        Reuses the sanitize patterns (CapabilitySanitize when
        loaded, McpSafety field redaction when loaded). The
        sk- canary never leaks. Cap fail-closed (rotation-cap).
        Skipped honestly under lock-busy (shared TelemetryGate
        when the McpSafety cell is loaded, else a session lock).
      - JEV_UNAVAILABLE is a structured result with deterministic
        fallback posture (fallback_continue=true, blocked=false
        under default optional criticality): never an exception
        across the boundary, never blocks the task.

    PowerShell 5.1 compatible. ASCII-only. Expected domain
    results are returned as result objects, never thrown across
    the boundary.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sanitizeLib = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $sanitizeLib -PathType Leaf) {
    . $sanitizeLib
}

$script:JevAdvisoryTelemetryCapBytes = 1048576
$script:JevAdvisoryTelemetryLock = New-Object Object
$script:JevAdvisoryTelemetryLockWaitMs = 250
$script:JevAdvisoryRequiredCannot = @(
    'grant-permission',
    'widen-scope',
    'select-model',
    'bypass-human-approval',
    'override-verifier',
    'override-reviewer',
    'override-security',
    'write-done'
)
$script:JevAdvisoryAllowedTools = @('jev_check', 'jev_gate', 'jev_score', 'jev_decide')
$script:JevAdvisoryToolCapability = @{
    'jev_check'  = 'jev.check'
    'jev_gate'   = 'jev.gate'
    'jev_score'  = 'jev.score'
    'jev_decide' = 'jev.decide'
}
$script:JevAdvisoryTransportBaseUrlEnv = 'JEV_BASE_URL'
$script:JevAdvisoryTransportModelEnv = 'JEV_MODEL'
$script:JevAdvisoryTransportDefaultModel = 'jev-latest'

# ---------- repo / path helpers ----------

function Get-JevAdvisoryRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-JevAdvisoryDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-JevAdvisoryRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\jev-advisory-policy.json')
}

function Get-JevAdvisoryDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-JevAdvisoryRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function Get-JevAdvisoryDefaultMcpPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-JevAdvisoryRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\mcp-request-policy.json')
}

function Get-JevAdvisoryPolicyNode {
    [CmdletBinding()]
    param($Doc, [string]$Name)
    try {
        if ($null -eq $Doc) { return $null }
        if ($Doc -is [System.Collections.IDictionary]) {
            if ($Doc.Contains($Name)) { return $Doc[$Name] }
            return $null
        }
        $p = $Doc.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Read-JevAdvisoryPolicy {
    <#
    .SYNOPSIS
        Reads the Jev advisory policy file. Returns @{found,
        malformed, doc}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $out = @{ found = $false; malformed = $false; doc = $null }
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-JevAdvisoryDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $out.found = $true
        try { $out.doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $out.doc) { $out.malformed = $true; return $out }
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Assert-JevAdvisoryPolicyJson {
    <#
    .SYNOPSIS
        Validates the Jev advisory policy file. Returns @{valid,
        errors}. Closed tool set of 4, request budget exactly 30,
        probe budgets exactly 10, circuit threshold 2 with
        cooldown 300, criticality exactly {optional, required}
        defaulting to optional, credential_source exactly
        {type:env, name:JEV_API_KEY} (name only), transport
        {base_url_env:JEV_BASE_URL, model_env:JEV_MODEL,
        timeout_seconds:30, fail_closed list} carrying env NAMES
        only (never a URL or a credential value, https required with
        http limited to loopback), advisory-only
        authority carrying every required cannot entry. Never
        throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errors.Add('file-missing') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $errors.Add('invalid-json') | Out-Null }
        if ($errors.Count -gt 0) {
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        if ($null -eq $doc) {
            $errors.Add('root-null') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        try { if ([int](Get-JevAdvisoryPolicyNode -Doc $doc -Name 'version') -ne 1) { $errors.Add('version-must-be-1') | Out-Null } }
        catch { $errors.Add('version-must-be-1') | Out-Null }
        $tools = @(Get-JevAdvisoryPolicyNode -Doc $doc -Name 'allowed_tools')
        $tnames = @()
        foreach ($t in $tools) { $tnames += (([string]$t).Trim()) }
        $want = @('jev_check', 'jev_gate', 'jev_score', 'jev_decide')
        $dTools = Compare-Object @($tnames | Sort-Object) @($want | Sort-Object)
        if ($null -ne $dTools) { $errors.Add('allowed_tools-must-be-closed-4') | Out-Null }
        try { if ([int](Get-JevAdvisoryPolicyNode -Doc $doc -Name 'request_budget_seconds') -ne 30) { $errors.Add('request-budget-must-be-30') | Out-Null } }
        catch { $errors.Add('request-budget-must-be-30') | Out-Null }
        try { if ([int](Get-JevAdvisoryPolicyNode -Doc $doc -Name 'health_probe_budget_seconds') -ne 10) { $errors.Add('health-probe-budget-must-be-10') | Out-Null } }
        catch { $errors.Add('health-probe-budget-must-be-10') | Out-Null }
        try { if ([int](Get-JevAdvisoryPolicyNode -Doc $doc -Name 'catalog_probe_budget_seconds') -ne 10) { $errors.Add('catalog-probe-budget-must-be-10') | Out-Null } }
        catch { $errors.Add('catalog-probe-budget-must-be-10') | Out-Null }
        $circuit = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'circuit'
        if (($null -eq $circuit)) { $errors.Add('circuit-missing') | Out-Null }
        else {
            try { if ([int](Get-JevAdvisoryPolicyNode -Doc $circuit -Name 'failure_threshold') -ne 2) { $errors.Add('circuit-threshold-must-be-2') | Out-Null } }
            catch { $errors.Add('circuit-threshold-must-be-2') | Out-Null }
            try { if ([int](Get-JevAdvisoryPolicyNode -Doc $circuit -Name 'cooldown_seconds') -ne 300) { $errors.Add('circuit-cooldown-must-be-300') | Out-Null } }
            catch { $errors.Add('circuit-cooldown-must-be-300') | Out-Null }
        }
        $crit = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'criticality'
        if ($null -eq $crit) { $errors.Add('criticality-missing') | Out-Null }
        else {
            $allowed = @()
            foreach ($e in @(Get-JevAdvisoryPolicyNode -Doc $crit -Name 'allowed')) { $allowed += (([string]$e).Trim()) }
            if ((@($allowed).Count -ne 2) -or ($allowed -notcontains 'optional') -or ($allowed -notcontains 'required')) {
                $errors.Add('criticality-allowed-must-be-optional-required') | Out-Null
            }
            $dflt = ([string](Get-JevAdvisoryPolicyNode -Doc $crit -Name 'default')).Trim()
            if ($dflt -cne 'optional') { $errors.Add('criticality-default-must-be-optional') | Out-Null }
        }
        $cred = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'credential_source'
        if ($null -eq $cred) { $errors.Add('credential_source-missing') | Out-Null }
        else {
            $ctype = ([string](Get-JevAdvisoryPolicyNode -Doc $cred -Name 'type')).Trim()
            if ($ctype -cne 'env') { $errors.Add('credential_source-type-must-be-env') | Out-Null }
            $cname = ([string](Get-JevAdvisoryPolicyNode -Doc $cred -Name 'name')).Trim()
            if ($cname -cne 'JEV_API_KEY') { $errors.Add('credential_source-name-must-be-JEV_API_KEY') | Out-Null }
        }
        $transport = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'transport'
        if ($null -eq $transport) { $errors.Add('transport-missing') | Out-Null }
        else {
            $bue = ([string](Get-JevAdvisoryPolicyNode -Doc $transport -Name 'base_url_env')).Trim()
            if ($bue -cne 'JEV_BASE_URL') { $errors.Add('transport-base_url_env-must-be-JEV_BASE_URL') | Out-Null }
            $men = ([string](Get-JevAdvisoryPolicyNode -Doc $transport -Name 'model_env')).Trim()
            if ($men -cne 'JEV_MODEL') { $errors.Add('transport-model_env-must-be-JEV_MODEL') | Out-Null }
            $tsec = ([string](Get-JevAdvisoryPolicyNode -Doc $transport -Name 'timeout_seconds')).Trim()
            if ($tsec -cne '30') { $errors.Add('transport-timeout-seconds-must-be-30') | Out-Null }
            $tfail = @()
            foreach ($e in @(Get-JevAdvisoryPolicyNode -Doc $transport -Name 'fail_closed')) { $tfail += (([string]$e).Trim()) }
            if (($tfail -notcontains 'base-url-absent') -or ($tfail -notcontains 'base-url-invalid') -or ($tfail -notcontains 'model-invalid') -or ($tfail -notcontains 'http-remote-rejected')) {
                $errors.Add('transport-fail_closed-must-list-the-four-codes') | Out-Null
            }
            $traw = ''
            try { $traw = [string]($transport | ConvertTo-Json -Depth 4 -Compress) } catch { $traw = '' }
            if ($traw -match '(?i)https?://') { $errors.Add('transport-must-carry-env-names-only') | Out-Null }
            if ($traw -match '(?i)sk-[A-Za-z0-9]') { $errors.Add('transport-must-not-carry-a-credential') | Out-Null }
        }
        $auth = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'authority'
        if ($null -eq $auth) { $errors.Add('authority-missing') | Out-Null }
        else {
            $mode = ([string](Get-JevAdvisoryPolicyNode -Doc $auth -Name 'mode')).Trim()
            if ($mode -cne 'advisory-only') { $errors.Add('authority-mode-must-be-advisory-only') | Out-Null }
            $cannot = @()
            foreach ($e in @(Get-JevAdvisoryPolicyNode -Doc $auth -Name 'cannot')) { $cannot += (([string]$e).Trim()) }
            foreach ($req in @($script:JevAdvisoryRequiredCannot)) {
                if ($cannot -notcontains $req) { $errors.Add(('authority-cannot-missing:' + $req)) | Out-Null }
            }
        }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

# ---------- flag ----------

function Get-JevAdvisoryFlag {
    <#
    .SYNOPSIS
        Reads the jev_advisory flag node. Returns @{found,
        enabled, shadow, mode}: mode is shadow when shadow is
        true, active when enabled without shadow, disabled
        otherwise. Canonical born-OFF shape is enabled=false
        plus shadow=true (mode shadow). Never throws.
    #>
    [CmdletBinding()]
    param([string]$FlagsPath = '', [string]$RepoRoot = '')
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-JevAdvisoryDefaultFlagsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return [PSCustomObject]@{ found = $false; enabled = $false; shadow = $false; mode = 'disabled' }
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { return [PSCustomObject]@{ found = $false; enabled = $false; shadow = $false; mode = 'disabled' } }
        $node = Get-JevAdvisoryPolicyNode -Doc $doc -Name 'jev_advisory'
        if ($null -eq $node) {
            return [PSCustomObject]@{ found = $false; enabled = $false; shadow = $false; mode = 'disabled' }
        }
        $en = Get-JevAdvisoryPolicyNode -Doc $node -Name 'enabled'
        $sh = Get-JevAdvisoryPolicyNode -Doc $node -Name 'shadow'
        if ((-not ($en -is [bool])) -or (-not ($sh -is [bool]))) {
            return [PSCustomObject]@{ found = $true; enabled = $false; shadow = $false; mode = 'disabled' }
        }
        $mode = 'disabled'
        if ([bool]$sh) { $mode = 'shadow' }
        elseif ([bool]$en) { $mode = 'active' }
        return [PSCustomObject]@{ found = $true; enabled = [bool]$en; shadow = [bool]$sh; mode = $mode }
    }
    catch { return [PSCustomObject]@{ found = $false; enabled = $false; shadow = $false; mode = 'disabled' } }
}

# ---------- deterministic trigger policy ----------

function Get-JevAdvisoryDescriptorFlag {
    [CmdletBinding()]
    param($Descriptor, [string]$Name)
    try {
        if ($null -eq $Descriptor) { return $false }
        if ($Descriptor -is [System.Collections.IDictionary]) {
            if ($Descriptor.Contains($Name)) { return ([bool]$Descriptor[$Name]) }
            return $false
        }
        $p = $Descriptor.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return ([bool]$p.Value) }
        return $false
    }
    catch { return $false }
}

function Test-JevAdvisoryTrigger {
    <#
    .SYNOPSIS
        Pure deterministic trigger policy over a structured
        descriptor (no LLM, no I/O). trivial_local never
        consults. Otherwise the first set boundary flag wins
        with a stable trigger_reason. Never throws.
    #>
    [CmdletBinding()]
    param($Descriptor)
    try {
        if ([bool](Get-JevAdvisoryDescriptorFlag -Descriptor $Descriptor -Name 'trivial_local')) {
            return [PSCustomObject]@{ should_consult = $false; trigger_reason = 'trivial-local-never-consults' }
        }
        $ordered = @(
            @('route_uncertain', 'route-uncertain'),
            @('model_route_uncertain', 'model-route-uncertain'),
            @('consequential_tool_call', 'consequential-tool-call'),
            @('conflicting_evidence', 'conflicting-evidence'),
            @('completion_uncertainty_substantial', 'completion-uncertainty-substantial'),
            @('recovery_comparison_bounded', 'recovery-comparison-bounded')
        )
        foreach ($pair in $ordered) {
            if ([bool](Get-JevAdvisoryDescriptorFlag -Descriptor $Descriptor -Name ([string]$pair[0]))) {
                return [PSCustomObject]@{ should_consult = $true; trigger_reason = ([string]$pair[1]) }
            }
        }
        return [PSCustomObject]@{ should_consult = $false; trigger_reason = 'no-trigger' }
    }
    catch { return [PSCustomObject]@{ should_consult = $false; trigger_reason = 'no-trigger' } }
}

function Test-JevAdvisoryTurnId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-JevAdvisoryApiKey {
    <#
    .SYNOPSIS
        Credential presence gate (real transport is HOLD): absent
        (null, empty or whitespace-only) means JEV_UNAVAILABLE;
        a control character [\x00-\x1F\x7F] in ANY position of
        the ORIGINAL value (edges included, checked before any
        trim, since Trim would hide edge controls) means
        JEV_AUTH_INVALID; a plain inner space (0x20, not a
        control) is allowed and passes; auth semantics belong
        to the real transport, never to a key format checked
        here. Never throws. Never logs the value.
    #>
    [CmdletBinding()]
    param([string]$ApiKey)
    try {
        $v = ([string]$ApiKey)
        if ([string]::IsNullOrWhiteSpace($v)) {
            return [PSCustomObject]@{ present = $false; valid = $false; status = 'JEV_UNAVAILABLE' }
        }
        if ($v -match '[\x00-\x1F\x7F]') {
            return [PSCustomObject]@{ present = $true; valid = $false; status = 'JEV_AUTH_INVALID' }
        }
        $t = $v.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) {
            return [PSCustomObject]@{ present = $false; valid = $false; status = 'JEV_UNAVAILABLE' }
        }
        return [PSCustomObject]@{ present = $true; valid = $true; status = 'OK' }
    }
    catch { return [PSCustomObject]@{ present = $false; valid = $false; status = 'JEV_UNAVAILABLE' } }
}

# ---------- real transport: config, wire mapping, probe ----------

function Test-JevAdvisoryLoopbackHost {
    <#
    .SYNOPSIS
        Closed loopback test used to allow plain http ONLY on loopback:
        the literal host 'localhost', any 127.0.0.0/8 IPv4 literal and
        the IPv6 loopback in compact or zero-padded expanded form.
        Deliberately NOT IPAddress.IsLoopback: that property returns
        false on PowerShell 5.1 for loopback addresses, which would
        silently reject the hermetic loopback endpoints (and, worse,
        could not be relied on to reject a remote host). Never throws.
    #>
    [CmdletBinding()]
    param([string]$HostName)
    try {
        $h = ([string]$HostName).Trim().ToLowerInvariant().Trim('[', ']')
        if ([string]::IsNullOrWhiteSpace($h)) { return $false }
        if ($h -ceq 'localhost') { return $true }
        if ($h -cmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
            $first = -1
            try { $first = [int]$Matches[1] } catch { return $false }
            return ($first -eq 127)
        }
        if ($h -ceq '::1') { return $true }
        if ($h -ceq '::ffff:127.0.0.1') { return $true }
        $parts = $h.Split(':')
        if ($parts.Count -eq 8) {
            $norm = @()
            foreach ($seg in @($parts)) {
                if ($seg -ceq '') { $norm += '0'; continue }
                $norm += (($seg -replace '^0+(?=[0-9a-f])', '').ToLowerInvariant())
            }
            return (($norm -join ':') -ceq '0:0:0:0:0:0:0:1')
        }
        return $false
    }
    catch { return $false }
}

function Resolve-JevAdvisoryTransportConfig {
    <#
    .SYNOPSIS
        Resolves the real-transport configuration from the
        user-owned environment, NAMES only: JEV_BASE_URL is required
        (absolute https, or http ONLY on a loopback host so the Bearer
        key is never sent in clear to a remote host; inner spaces
        preserved, edges trimmed) and JEV_MODEL is optional (default
        jev-latest, whitespace-only falls back to the default).
        Returns @{ok, status, error_kind, base_url, model,
        base_url_env, model_env}. Fail-closed: absent, blank,
        control-character, non-absolute, non-http(s) or REMOTE-http base
        URL (error_kind 'http-remote-rejected'), or a control character
        in the model (error_kind 'model-invalid'), yields ok=false with
        status JEV_TRANSPORT_NOT_CONFIGURED, which the caller maps to a
        deterministic fallback that never blocks the task. Never throws.
        Never reads, returns or logs the credential value.
    #>
    [CmdletBinding()]
    param()
    try {
        $out = [ordered]@{
            ok = $false; status = 'JEV_TRANSPORT_NOT_CONFIGURED'; error_kind = 'base-url-absent'
            base_url = ''; model = ''
            base_url_env = ([string]$script:JevAdvisoryTransportBaseUrlEnv)
            model_env = ([string]$script:JevAdvisoryTransportModelEnv)
        }
        $raw = ''
        try { $raw = ([string]$env:JEV_BASE_URL) } catch { $raw = '' }
        if ([string]::IsNullOrWhiteSpace($raw)) { return ([PSCustomObject]$out) }
        if ($raw -match '[\x00-\x1F\x7F]') { $out.error_kind = 'base-url-invalid'; return ([PSCustomObject]$out) }
        $base = $raw.Trim()
        $uri = $null
        $parsed = $false
        try { $parsed = [Uri]::TryCreate($base, [UriKind]::Absolute, [ref]$uri) } catch { $parsed = $false }
        if (-not [bool]$parsed) { $out.error_kind = 'base-url-invalid'; return ([PSCustomObject]$out) }
        $scheme = ''
        $endpointHost = ''
        try { $scheme = ([string]$uri.Scheme).ToLowerInvariant(); $endpointHost = ([string]$uri.Host).ToLowerInvariant() } catch { $scheme = ''; $endpointHost = '' }
        if ($scheme -ceq 'https') { }
        elseif ($scheme -ceq 'http') {
            if (-not (Test-JevAdvisoryLoopbackHost -HostName $endpointHost)) {
                $out.error_kind = 'http-remote-rejected'
                return ([PSCustomObject]$out)
            }
        }
        else { $out.error_kind = 'base-url-invalid'; return ([PSCustomObject]$out) }
        $model = ''
        try { $model = ([string]$env:JEV_MODEL) } catch { $model = '' }
        if ([string]::IsNullOrWhiteSpace($model)) { $model = [string]$script:JevAdvisoryTransportDefaultModel }
        elseif ($model -match '[\x00-\x1F\x7F]') { $out.error_kind = 'model-invalid'; return ([PSCustomObject]$out) }
        $out.ok = $true
        $out.status = 'JEV_TRANSPORT_CONFIGURED'
        $out.base_url = $base
        $out.model = $model
        return ([PSCustomObject]$out)
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'JEV_TRANSPORT_NOT_CONFIGURED'; error_kind = 'internal'
            base_url = ''; model = ''
            base_url_env = ([string]$script:JevAdvisoryTransportBaseUrlEnv)
            model_env = ([string]$script:JevAdvisoryTransportModelEnv)
        }
    }
}

function Get-JevAdvisoryToolArg {
    <#
    .SYNOPSIS
        Reads one tool argument from the caller hashtable, returning
        an empty string when absent. Never throws.
    #>
    [CmdletBinding()]
    param($ToolArgs, [string]$Name)
    try {
        if ($null -eq $ToolArgs) { return '' }
        if ($ToolArgs -is [System.Collections.IDictionary]) {
            if ($ToolArgs.Contains($Name)) { return $ToolArgs[$Name] }
            return ''
        }
        $p = $ToolArgs.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return ''
    }
    catch { return '' }
}

function Test-JevAdvisoryEntryCriteria {
    <#
    .SYNOPSIS
        Validates one jev_decide question entry: type must be one of
        choice|score|noul; score requires a criteria array of 2..10
        entries; choice requires a non-empty criteria MAP. Returns
        $true/$false, never throws.
    #>
    [CmdletBinding()]
    param($Entry)
    try {
        if ($null -eq $Entry) { return $false }
        if (-not ($Entry -is [System.Collections.IDictionary])) { return $false }
        $t = ([string](Get-JevAdvisoryToolArg -ToolArgs $Entry -Name 'type')).Trim()
        if (@('choice', 'score', 'noul') -cnotcontains $t) { return $false }
        if ($t -ceq 'score') {
            $c = @()
            try { $c = @(Get-JevAdvisoryToolArg -ToolArgs $Entry -Name 'criteria') } catch { $c = @() }
            if ((@($c).Count -lt 2) -or (@($c).Count -gt 10)) { return $false }
            foreach ($lv in @($c)) { if ([string]::IsNullOrWhiteSpace([string]$lv)) { return $false } }
            return $true
        }
        if ($t -ceq 'choice') {
            $cm = Get-JevAdvisoryToolArg -ToolArgs $Entry -Name 'criteria'
            if (($null -eq $cm) -or (-not ($cm -is [System.Collections.IDictionary]))) { return $false }
            if (@($cm.Keys).Count -lt 1) { return $false }
            return $true
        }
        return $true
    }
    catch { return $false }
}

function ConvertTo-JevAdvisoryWireRequest {
    <#
    .SYNOPSIS
        Pure per-tool wire mapping for the jev-mcp protocol
        (POST body {model, state, questions}), mirroring jev-mcp
        src/index.js exactly:
          jev_check  -> questions.result {type:noul, instructions}
                        output {probability, likely = noul -ge 0.5}
          jev_score  -> questions.result {type:score, instructions,
                        criteria=levels} (2..10 levels)
          jev_decide -> questions passed through (validated map)
          jev_gate   -> state = "Action an autonomous agent is about
                        to perform:" + action (+ Context block) and
                        the closed risk/touches_prod/recommendation
                        question set.
        Returns @{ok, status, error_kind, tool, model, state,
        questions, body_json}. A tool outside the closed set, a
        missing state (except jev_gate, which derives it), or an
        invalid argument shape fails closed with status
        JEV_WIRE_INVALID and a stable error_kind. Never throws, never
        touches the network and never reads a credential.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [string]$State = '',
        $ToolArgs = $null,
        [string]$Model = ''
    )
    try {
        $toolName = ([string]$Tool).Trim().ToLowerInvariant()
        $modelName = ([string]$Model).Trim()
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = [string]$script:JevAdvisoryTransportDefaultModel }
        $bad = { param($kind)
            return [PSCustomObject]@{
                ok = $false; status = 'JEV_WIRE_INVALID'; error_kind = ([string]$kind)
                tool = $toolName; model = $modelName; state = ''; questions = $null; body_json = ''
            }
        }
        if ($script:JevAdvisoryAllowedTools -notcontains $toolName) { return (& $bad 'tool-not-allowed') }
        $argsMap = $ToolArgs
        if ($null -ne $argsMap) {
            if (-not ($argsMap -is [System.Collections.IDictionary])) { return (& $bad 'toolargs-not-a-map') }
        }
        $wireState = ([string]$State)
        $questions = $null
        $lf = [string][char]10
        if ($toolName -ceq 'jev_check') {
            if ([string]::IsNullOrWhiteSpace($wireState)) { return (& $bad 'state-missing') }
            $instructions = ([string](Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'instructions'))
            if ([string]::IsNullOrWhiteSpace($instructions)) { return (& $bad 'instructions-missing') }
            $questions = [ordered]@{ result = [ordered]@{ type = 'noul'; instructions = $instructions } }
        }
        elseif ($toolName -ceq 'jev_score') {
            if ([string]::IsNullOrWhiteSpace($wireState)) { return (& $bad 'state-missing') }
            $instructions = ([string](Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'instructions'))
            if ([string]::IsNullOrWhiteSpace($instructions)) { return (& $bad 'instructions-missing') }
            $levels = @()
            try { $levels = @(Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'levels') } catch { $levels = @() }
            if ((@($levels).Count -lt 2) -or (@($levels).Count -gt 10)) { return (& $bad 'levels-invalid') }
            foreach ($lv in @($levels)) { if ([string]::IsNullOrWhiteSpace([string]$lv)) { return (& $bad 'levels-invalid') } }
            $questions = [ordered]@{ result = [ordered]@{ type = 'score'; instructions = $instructions; criteria = $levels } }
        }
        elseif ($toolName -ceq 'jev_decide') {
            if ([string]::IsNullOrWhiteSpace($wireState)) { return (& $bad 'state-missing') }
            $src = Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'questions'
            if (($null -eq $src) -or (-not ($src -is [System.Collections.IDictionary]))) { return (& $bad 'questions-not-a-map') }
            if (@($src.Keys).Count -lt 1) { return (& $bad 'questions-empty') }
            $rebuilt = [ordered]@{}
            foreach ($qk in @($src.Keys)) {
                $qn = ([string]$qk).Trim()
                if ([string]::IsNullOrWhiteSpace($qn)) { return (& $bad 'questions-empty') }
                $entry = $src[$qk]
                if (-not (Test-JevAdvisoryEntryCriteria -Entry $entry)) { return (& $bad 'questions-entry-invalid') }
                $et = ([string](Get-JevAdvisoryToolArg -ToolArgs $entry -Name 'type')).Trim()
                $out = [ordered]@{
                    type = $et
                    instructions = ([string](Get-JevAdvisoryToolArg -ToolArgs $entry -Name 'instructions'))
                }
                if ($et -ceq 'score') { $out['criteria'] = @(Get-JevAdvisoryToolArg -ToolArgs $entry -Name 'criteria') }
                elseif ($et -ceq 'choice') {
                    $cm = Get-JevAdvisoryToolArg -ToolArgs $entry -Name 'criteria'
                    $cmOut = [ordered]@{}
                    foreach ($ck in @($cm.Keys)) { $cmOut[([string]$ck)] = ([string]$cm[[string]$ck]) }
                    $out['criteria'] = $cmOut
                }
                $rebuilt[$qn] = $out
            }
            $questions = $rebuilt
        }
        else {
            $action = ([string](Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'action'))
            if ([string]::IsNullOrWhiteSpace($action)) { return (& $bad 'action-missing') }
            $ctxText = ([string](Get-JevAdvisoryToolArg -ToolArgs $argsMap -Name 'context'))
            $wireState = 'Action an autonomous agent is about to perform:' + $lf + $action
            if (-not [string]::IsNullOrWhiteSpace($ctxText)) {
                $wireState = $wireState + $lf + $lf + 'Context:' + $lf + $ctxText
            }
            $questions = [ordered]@{
                risk = [ordered]@{
                    type = 'score'
                    instructions = 'How risky is it to run this action automatically?'
                    criteria = @('safe', 'low', 'needs review', 'high - could destroy data or affect prod')
                }
                touches_prod = [ordered]@{
                    type = 'noul'
                    instructions = 'Does this action touch production or delete/overwrite data?'
                }
                recommendation = [ordered]@{
                    type = 'choice'
                    instructions = 'What should the harness do with this action?'
                    criteria = [ordered]@{
                        allow = 'safe to run automatically'
                        confirm = 'pause and ask a human to confirm'
                        block = 'block and require a safer approach'
                    }
                }
            }
        }
        $json = ''
        try { $json = (([ordered]@{ model = $modelName; state = $wireState; questions = $questions }) | ConvertTo-Json -Depth 8 -Compress) }
        catch { return (& $bad 'body-serialize') }
        if ([string]::IsNullOrWhiteSpace($json)) { return (& $bad 'body-serialize') }
        return [PSCustomObject]@{
            ok = $true; status = 'OK'; error_kind = ''
            tool = $toolName; model = $modelName; state = $wireState
            questions = $questions; body_json = $json
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'JEV_WIRE_INVALID'; error_kind = 'internal'
            tool = ([string]$Tool).Trim().ToLowerInvariant(); model = ''; state = ''
            questions = $null; body_json = ''
        }
    }
}

$script:JevAdvisoryHttpProbeTemplate = @'
param($tool, $state, $toolArgs, $timeoutSeconds)

# Self-contained Jev advisory HTTP probe (Phase 29 slice 2).
# Runs inside the reused Phase 28 envelope in a FRESH runspace: no
# caller scope, process environment only.
#
# CONTRACT (reviewer/security rev 11):
#   * SUCCESS returns a CLOSED TYPED PROJECTION only: primitives the
#     kernel knows per tool. Unknown keys and free API text are dropped.
#   * FAILURE throws a CLOSED TOKEN. Never free text, never the
#     credential, never the base URL, never the response body.
#   * The envelope counts a thrown probe as a failure (circuit 2/300s):
#       timeout  -> MCP_TIMEOUT       (counted toward the circuit)
#       network  -> MCP_NETWORK_ERROR (counted toward the circuit)
#       auth | server | malformed | oversize | not-configured
#                -> MCP_ERROR (closed cause; Invoke-JevAdvisoryCall maps
#                   the auth token to the published JEV_AUTH_REJECTED)
#     and Invoke-JevAdvisoryCall turns every non-OK envelope result into
#     JEV_UNAVAILABLE with fallback_continue=true. No false success.
#   * Endpoint: https required. http is allowed ONLY for loopback
#     (127.0.0.1, localhost, [::1]) so a Bearer key is never sent in clear
#     to a remote host. No redirect is ever followed, so the
#     Authorization header cannot travel to another destination.
$ErrorActionPreference = 'Stop'

function Get-JevProbeNode {
    param($Node, [string]$Name)
    try {
        if ($null -eq $Node) { return $null }
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Name)) { return $Node[$Name] }
            return $null
        }
        $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Get-JevProbeText {
    param($Node, [string]$Name)
    try {
        $v = Get-JevProbeNode -Node $Node -Name $Name
        if ($null -eq $v) { return '' }
        return ([string]$v)
    }
    catch { return '' }
}

function Get-JevProbeBoundedText {
    # Only a printable, control-char-free string no longer than $Max is
    # accepted from the API; anything else is malformed (never echoed).
    param($Node, [string]$Name, [int]$Max = 64)
    try {
        $v = Get-JevProbeNode -Node $Node -Name $Name
        if ($null -eq $v) { return $null }
        if (-not ($v -is [string])) { return $null }
        if ($v -match '[\x00-\x1F\x7F]') { return $null }
        if ($v.Length -gt $Max) { return $null }
        return $v
    }
    catch { return $null }
}

function Get-JevProbeNumber {
    param($Node, [string]$Name)
    try {
        $v = Get-JevProbeNode -Node $Node -Name $Name
        if ($null -eq $v) { return $null }
        if ($v -is [string]) { return $null }
        if ($v -is [bool]) { return $null }
        return ([double]$v)
    }
    catch { return $null }
}

function Test-JevProbeEndpoint {
    # Returns $true only for https, or for http on a loopback host.
    # Loopback is spelled out (never IPAddress.IsLoopback, which returns
    # false on PS 5.1): localhost, 127.0.0.0/8 and the IPv6 loopback in
    # compact or zero-padded expanded form.
    param([string]$Url)
    try {
        $u = $null
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
        $scheme = ([string]$u.Scheme).ToLowerInvariant()
        if ($scheme -ceq 'https') { return $true }
        if ($scheme -cne 'http') { return $false }
        $h = ([string]$u.Host).ToLowerInvariant().Trim('[', ']')
        if ([string]::IsNullOrWhiteSpace($h)) { return $false }
        if ($h -ceq 'localhost') { return $true }
        if ($h -cmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
            $first = -1
            try { $first = [int]$Matches[1] } catch { return $false }
            return ($first -eq 127)
        }
        if ($h -ceq '::1') { return $true }
        if ($h -ceq '::ffff:127.0.0.1') { return $true }
        $parts = $h.Split(':')
        if ($parts.Count -eq 8) {
            $norm = @()
            foreach ($seg in @($parts)) {
                if ($seg -ceq '') { $norm += '0'; continue }
                $norm += (($seg -replace '^0+(?=[0-9a-f])', '').ToLowerInvariant())
            }
            return (($norm -join ':') -ceq '0:0:0:0:0:0:0:1')
        }
        return $false
    }
    catch { return $false }
}

function New-JevProbeNumericMap {
    # Ordered numeric projection: only numeric values under a conservative
    # name, bounded count. Any text field is dropped.
    param($Node)
    $out = [ordered]@{}
    try {
        if ($null -eq $Node) { return $out }
        $pairs = @()
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in @($Node.Keys)) { $pairs += , @(([string]$k), $Node[$k]) }
        }
        else {
            foreach ($p in @($Node.PSObject.Properties)) { $pairs += , @(([string]$p.Name), $p.Value) }
        }
        $n = 0
        foreach ($pair in @($pairs)) {
            if ($n -ge 16) { break }
            $k = [string]$pair[0]
            $v = $pair[1]
            if ($k -cnotmatch '^[A-Za-z0-9_]{1,32}$') { continue }
            if ($null -eq $v) { continue }
            if (($v -is [string]) -or ($v -is [bool])) { continue }
            try { $out[$k] = [double]$v } catch { continue }
            $n = $n + 1
        }
    }
    catch { return ([ordered]@{}) }
    return $out
}

function New-JevProbeLegend {
    # Ordered numeric legend: numeric values only, bounded count.
    param($Node)
    $out = @()
    try {
        if ($null -eq $Node) { return , ([double[]]@()) }
        $vals = @()
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in @($Node.Keys)) { $vals += , $Node[$k] }
        }
        elseif ($Node -is [System.Collections.IEnumerable]) {
            foreach ($v in @($Node)) { $vals += , $v }
        }
        foreach ($v in @($vals)) {
            if (@($out).Count -ge 16) { break }
            if ($null -eq $v) { continue }
            if (($v -is [string]) -or ($v -is [bool])) { continue }
            try { $out += , ([double]$v) } catch { continue }
        }
    }
    catch { return , ([double[]]@()) }
    return , ([double[]]$out)
}

try {
    $toolName = ([string]$tool).Trim().ToLowerInvariant()
    if (@('jev_check', 'jev_gate', 'jev_score', 'jev_decide') -cnotcontains $toolName) { throw 'jev-transport-not-configured' }
    # ---- config resolved INSIDE the runspace (process env is visible) ----
    $base = ''
    try { $base = ([string]$env:JEV_BASE_URL) } catch { $base = '' }
    if ([string]::IsNullOrWhiteSpace($base)) { throw 'jev-transport-not-configured' }
    if ($base -match '[\x00-\x1F\x7F]') { throw 'jev-transport-not-configured' }
    $base = $base.Trim()
    if (-not (Test-JevProbeEndpoint -Url $base)) { throw 'jev-transport-not-configured' }
    $model = ''
    try { $model = ([string]$env:JEV_MODEL) } catch { $model = '' }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'jev-latest' }
    elseif ($model -match '[\x00-\x1F\x7F]') { throw 'jev-transport-not-configured' }
    $apiKey = ''
    try { $apiKey = ([string]$env:JEV_API_KEY) } catch { $apiKey = '' }
    if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'jev-transport-not-configured' }
    if ($apiKey -match '[\x00-\x1F\x7F]') { throw 'jev-transport-not-configured' }
    # Effective budget: the factory bakes the envelope budget in; a smaller
    # explicit budget wins. This only bounds the HttpWebRequest socket
    # wait (budget + 500ms margin) so the ENVELOPE wall clock stays the
    # authoritative deadline and may stop the probe earlier; it is not a
    # guaranteed total deadline for the call.
    $budget = 0
    try { $budget = [int]$timeoutSeconds } catch { $budget = 0 }
    if (($budget -lt 1) -or ($budget -gt 600)) { $budget = __JEV_PROBE_TIMEOUT_SECONDS__ }
    $httpTimeoutMs = ($budget * 1000) + 500
    # ---- pure wire mapping mirrored from ConvertTo-JevAdvisoryWireRequest ----
    $argsMap = $toolArgs
    if ($null -ne $argsMap) {
        if (-not ($argsMap -is [System.Collections.IDictionary])) { throw 'jev-transport-not-configured' }
    }
    $lf = [string][char]10
    $wireState = ([string]$state)
    $questions = $null
    if ($toolName -ceq 'jev_check') {
        if ([string]::IsNullOrWhiteSpace($wireState)) { throw 'jev-transport-not-configured' }
        $instructions = Get-JevProbeText -Node $argsMap -Name 'instructions'
        if ([string]::IsNullOrWhiteSpace($instructions)) { throw 'jev-transport-not-configured' }
        $questions = [ordered]@{ result = [ordered]@{ type = 'noul'; instructions = $instructions } }
    }
    elseif ($toolName -ceq 'jev_score') {
        if ([string]::IsNullOrWhiteSpace($wireState)) { throw 'jev-transport-not-configured' }
        $instructions = Get-JevProbeText -Node $argsMap -Name 'instructions'
        if ([string]::IsNullOrWhiteSpace($instructions)) { throw 'jev-transport-not-configured' }
        $levels = @()
        try { $levels = @(Get-JevProbeNode -Node $argsMap -Name 'levels') } catch { $levels = @() }
        if ((@($levels).Count -lt 2) -or (@($levels).Count -gt 10)) { throw 'jev-transport-not-configured' }
        foreach ($lv in @($levels)) { if ([string]::IsNullOrWhiteSpace([string]$lv)) { throw 'jev-transport-not-configured' } }
        $questions = [ordered]@{ result = [ordered]@{ type = 'score'; instructions = $instructions; criteria = $levels } }
    }
    elseif ($toolName -ceq 'jev_decide') {
        if ([string]::IsNullOrWhiteSpace($wireState)) { throw 'jev-transport-not-configured' }
        $src = Get-JevProbeNode -Node $argsMap -Name 'questions'
        if (($null -eq $src) -or (-not ($src -is [System.Collections.IDictionary]))) { throw 'jev-transport-not-configured' }
        if (@($src.Keys).Count -lt 1) { throw 'jev-transport-not-configured' }
        $rebuilt = [ordered]@{}
        foreach ($qk in @($src.Keys)) {
            $qn = ([string]$qk).Trim()
            if ($qn -cnotmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'jev-transport-not-configured' }
            $entry = $src[$qk]
            if (($null -eq $entry) -or (-not ($entry -is [System.Collections.IDictionary]))) { throw 'jev-transport-not-configured' }
            $et = (Get-JevProbeText -Node $entry -Name 'type').Trim()
            if (@('choice', 'score', 'noul') -cnotcontains $et) { throw 'jev-transport-not-configured' }
            $entryOut = [ordered]@{ type = $et; instructions = (Get-JevProbeText -Node $entry -Name 'instructions') }
            if ($et -ceq 'score') {
                $crit = @()
                try { $crit = @(Get-JevProbeNode -Node $entry -Name 'criteria') } catch { $crit = @() }
                if ((@($crit).Count -lt 2) -or (@($crit).Count -gt 10)) { throw 'jev-transport-not-configured' }
                foreach ($cv in @($crit)) { if ([string]::IsNullOrWhiteSpace([string]$cv)) { throw 'jev-transport-not-configured' } }
                $entryOut['criteria'] = $crit
            }
            elseif ($et -ceq 'choice') {
                $cmap = Get-JevProbeNode -Node $entry -Name 'criteria'
                if (($null -eq $cmap) -or (-not ($cmap -is [System.Collections.IDictionary]))) { throw 'jev-transport-not-configured' }
                if (@($cmap.Keys).Count -lt 1) { throw 'jev-transport-not-configured' }
                $cmapOut = [ordered]@{}
                foreach ($ck in @($cmap.Keys)) { $cmapOut[([string]$ck)] = ([string]$cmap[[string]$ck]) }
                $entryOut['criteria'] = $cmapOut
            }
            $rebuilt[$qn] = $entryOut
        }
        $questions = $rebuilt
    }
    else {
        $action = Get-JevProbeText -Node $argsMap -Name 'action'
        if ([string]::IsNullOrWhiteSpace($action)) { throw 'jev-transport-not-configured' }
        $ctxText = Get-JevProbeText -Node $argsMap -Name 'context'
        $wireState = 'Action an autonomous agent is about to perform:' + $lf + $action
        if (-not [string]::IsNullOrWhiteSpace($ctxText)) {
            $wireState = $wireState + $lf + $lf + 'Context:' + $lf + $ctxText
        }
        $questions = [ordered]@{
            risk = [ordered]@{
                type = 'score'
                instructions = 'How risky is it to run this action automatically?'
                criteria = @('safe', 'low', 'needs review', 'high - could destroy data or affect prod')
            }
            touches_prod = [ordered]@{
                type = 'noul'
                instructions = 'Does this action touch production or delete/overwrite data?'
            }
            recommendation = [ordered]@{
                type = 'choice'
                instructions = 'What should the harness do with this action?'
                criteria = [ordered]@{
                    allow = 'safe to run automatically'
                    confirm = 'pause and ask a human to confirm'
                    block = 'block and require a safer approach'
                }
            }
        }
    }
    $bodyJson = ''
    try {
        $bodyJson = (([ordered]@{ model = $model; state = $wireState; questions = $questions }) | ConvertTo-Json -Depth 8 -Compress)
    }
    catch { throw 'jev-transport-not-configured' }
    if ([string]::IsNullOrWhiteSpace($bodyJson)) { throw 'jev-transport-not-configured' }
    # ---- transport: raw HttpWebRequest (PS 5.1 safe), TLS12 only added ----
    try {
        $sp = [System.Net.ServicePointManager]::SecurityProtocol
        if (([int]$sp -band [int][System.Net.SecurityProtocolType]::Tls12) -eq 0) {
            [System.Net.ServicePointManager]::SecurityProtocol = ($sp -bor [System.Net.SecurityProtocolType]::Tls12)
        }
    }
    catch { }
    $status = 0
    $text = ''
    $oversize = $false
    $truncated = $false
    $okResponse = $null
    $okStream = $null
    $errResponse = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create([Uri]$base)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json'
        $req.AllowAutoRedirect = $false
        $req.KeepAlive = $false
        $req.Timeout = $httpTimeoutMs
        $req.ReadWriteTimeout = $httpTimeoutMs
        $req.Headers.Add('Authorization', ('Bearer ' + $apiKey))
        $bytes = [Text.Encoding]::UTF8.GetBytes($bodyJson)
        $req.ContentLength = $bytes.Length
        $requestStream = $req.GetRequestStream()
        try { $requestStream.Write($bytes, 0, $bytes.Length) }
        finally { try { $requestStream.Close() } catch { } }
        $okResponse = $req.GetResponse()
        try {
            $status = [int]$okResponse.StatusCode
            $okStream = $okResponse.GetResponseStream()
            $declared = -1
            try { $declared = [int]$okResponse.ContentLength } catch { $declared = -1 }
            # bounded read: 256KB cap on the ACCUMULATED length, enforced
            # BEFORE any further read, so an oversized body never depends on
            # how a given engine reacts after the last byte
            $cap = 262144
            $chunk = 8192
            $buf = New-Object byte[] $chunk
            $acc = New-Object System.IO.MemoryStream
            while ($true) {
                # an oversized body is malformed BY DECLARATION as soon as the
                # announced length is over the cap, so the verdict never
                # depends on how an engine reacts to a later read
                if (($acc.Length -gt $cap) -or ($declared -gt $cap)) { $oversize = $true; break }
                # a body already as long as announced is COMPLETE: from here on
                # a read error is legitimate end-of-stream, not a transport fault
                if (($declared -ge 0) -and ([long]$acc.Length -ge [long]$declared)) { break }
                $read = 0
                $readFailed = $false
                try { $read = $okStream.Read($buf, 0, $chunk) } catch { $readFailed = $true }
                if ($readFailed) {
                    if ($declared -gt $cap) { $oversize = $true; break }
                    if (($declared -ge 0) -and ([long]$acc.Length -ge [long]$declared)) { break }
                    $truncated = $true
                    break
                }
                # only a real $read -le 0 is legitimate EOF
                if ($read -le 0) { break }
                $acc.Write($buf, 0, $read)
            }
            if ((-not $oversize) -and ($acc.Length -gt $cap)) { $oversize = $true }
            if (-not $oversize) { $text = [Text.Encoding]::UTF8.GetString($acc.ToArray()) }
            # a body shorter than the declared Content-Length is a truncated
            # transport, never a complete answer
            if ((-not $oversize) -and ($declared -ge 0) -and ([long]$acc.Length -ne [long]$declared)) { $truncated = $true }
        }
        finally {
            try { if ($null -ne $okStream) { $okStream.Close() } } catch { }
            try { if ($null -ne $okResponse) { $okResponse.Close() } } catch { }
        }
    }
    catch [System.Net.WebException] {
        $code = 0
        try { $errResponse = $_.Exception.Response; if ($null -ne $errResponse) { $code = [int]$errResponse.StatusCode } } catch { $code = 0 }
        if (($code -eq 401) -or ($code -eq 403)) { throw 'jev-transport-auth-401' }
        if ($code -gt 0) { throw 'jev-transport-server-5xx' }
        $wstatus = ''
        try { $wstatus = [string]$_.Exception.Status } catch { $wstatus = '' }
        $wmsg = ''
        try { $wmsg = ([string]$_.Exception.Message).ToLowerInvariant() } catch { $wmsg = '' }
        if (($wstatus -cmatch 'timeout') -or ($wmsg -cmatch 'timed out') -or ($wmsg -cmatch 'timeout')) { throw 'jev-transport-timeout' }
        throw 'jev-transport-network'
    }
    catch {
        $gmsg = ''
        try { $gmsg = ([string]$_.Exception.Message).ToLowerInvariant() } catch { $gmsg = '' }
        if (($gmsg -cmatch 'timed out') -or ($gmsg -cmatch 'timeout')) { throw 'jev-transport-timeout' }
        throw 'jev-transport-network'
    }
    finally {
        # the error response is closed here even when reading its status failed
        try { if ($null -ne $errResponse) { $errResponse.Close() } } catch { }
    }
    if ($oversize) { throw 'jev-transport-malformed' }
    if ($truncated) { throw 'jev-transport-network-read' }
    # status gate BEFORE any interpretation of the body: with redirects
    # disabled a 3xx comes back as a normal response, so a valid JSON body
    # behind a redirect must never be read as an answer
    if (($status -lt 200) -or ($status -gt 299)) {
        if (($status -ge 300) -and ($status -le 399)) { throw 'jev-transport-server-3xx' }
        throw 'jev-transport-server-5xx'
    }
    # ---- CLOSED TYPED PROJECTION per tool (no free API text) ----
    $doc = $null
    try { $doc = ($text | ConvertFrom-Json) }
    catch { throw 'jev-transport-malformed' }
    if ($null -eq $doc) { throw 'jev-transport-malformed' }
    $answers = Get-JevProbeNode -Node $doc -Name 'answers'
    if ($null -eq $answers) { throw 'jev-transport-malformed' }
    if ($toolName -ceq 'jev_check') {
        $prob = Get-JevProbeNumber -Node (Get-JevProbeNode -Node $answers -Name 'result') -Name 'noul'
        if ($null -eq $prob) { throw 'jev-transport-malformed' }
        return ([PSCustomObject]@{ probability = [double]$prob; likely = ([double]$prob -ge 0.5) })
    }
    if ($toolName -ceq 'jev_score') {
        $res = Get-JevProbeNode -Node $answers -Name 'result'
        if ($null -eq $res) { throw 'jev-transport-malformed' }
        $scoreValue = Get-JevProbeNumber -Node $res -Name 'score'
        if ($null -eq $scoreValue) { throw 'jev-transport-malformed' }
        return ([PSCustomObject]@{
            score = [double]$scoreValue
            confidence = (Get-JevProbeNumber -Node $res -Name 'confidence')
            legend = (New-JevProbeLegend (Get-JevProbeNode -Node $res -Name 'legend'))
        })
    }
    if ($toolName -ceq 'jev_gate') {
        $recNode = Get-JevProbeNode -Node $answers -Name 'recommendation'
        $choice = [string](Get-JevProbeBoundedText -Node $recNode -Name 'choice' -Max 16)
        if (@('allow', 'confirm', 'block') -cnotcontains $choice) { throw 'jev-transport-malformed' }
        $risk = Get-JevProbeNumber -Node (Get-JevProbeNode -Node $answers -Name 'risk') -Name 'score'
        $touches = Get-JevProbeNumber -Node (Get-JevProbeNode -Node $answers -Name 'touches_prod') -Name 'noul'
        if (($null -eq $risk) -or ($null -eq $touches)) { throw 'jev-transport-malformed' }
        return ([PSCustomObject]@{
            recommendation = $choice
            confidence = (Get-JevProbeNumber -Node $recNode -Name 'confidence')
            risk_score = [double]$risk
            touches_prod = ([double]$touches -ge 0.5)
            touches_prod_probability = [double]$touches
        })
    }
    # jev_decide: per answer {type, choice|score|noul, confidence} + numeric usage
    $names = @()
    if ($answers -is [System.Collections.IDictionary]) { $names = @($answers.Keys) }
    else {
        foreach ($p in @($answers.PSObject.Properties)) { $names += , ([string]$p.Name) }
    }
    if ((@($names).Count -lt 1) -or (@($names).Count -gt 16)) { throw 'jev-transport-malformed' }
    $projected = [ordered]@{}
    foreach ($nm in @($names)) {
        $qn = ([string]$nm)
        if ($qn -cnotmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'jev-transport-malformed' }
        if (($null -eq $questions) -or (-not ($questions -is [System.Collections.IDictionary])) -or (-not $questions.Contains($qn))) { throw 'jev-transport-malformed' }
        $entry = Get-JevProbeNode -Node $answers -Name $qn
        # the question as SENT is the trust anchor: the received type must
        # equal it, and a choice must be one of the criteria that were sent
        $sentEntry = Get-JevProbeNode -Node $questions -Name $qn
        $sentType = (Get-JevProbeText -Node $sentEntry -Name 'type').Trim()
        $et = ([string](Get-JevProbeBoundedText -Node $entry -Name 'type' -Max 16)).Trim()
        if (@('choice', 'score', 'noul') -cnotcontains $et) { throw 'jev-transport-malformed' }
        if ($sentType -cne $et) { throw 'jev-transport-malformed' }
        $projectedEntry = [ordered]@{ type = $et }
        if ($et -ceq 'choice') {
            $cv = Get-JevProbeBoundedText -Node $entry -Name 'choice' -Max 64
            if ($null -eq $cv) { throw 'jev-transport-malformed' }
            # case sensitive, no trim: free API text can never cross
            $sentCrit = Get-JevProbeNode -Node $sentEntry -Name 'criteria'
            if (($null -eq $sentCrit) -or (-not ($sentCrit -is [System.Collections.IDictionary]))) { throw 'jev-transport-malformed' }
            $critKeys = @()
            foreach ($ck in @($sentCrit.Keys)) { $critKeys += ([string]$ck) }
            if ((@($critKeys).Count -lt 1) -or (-not ($critKeys -ccontains $cv))) { throw 'jev-transport-malformed' }
            $projectedEntry['choice'] = $cv
        }
        elseif ($et -ceq 'score') {
            $sv = Get-JevProbeNumber -Node $entry -Name 'score'
            if ($null -eq $sv) { throw 'jev-transport-malformed' }
            $projectedEntry['score'] = [double]$sv
        }
        else {
            $nv = Get-JevProbeNumber -Node $entry -Name 'noul'
            if ($null -eq $nv) { throw 'jev-transport-malformed' }
            $projectedEntry['noul'] = [double]$nv
        }
        $projectedEntry['confidence'] = (Get-JevProbeNumber -Node $entry -Name 'confidence')
        $projected[$qn] = [PSCustomObject]$projectedEntry
    }
    return ([PSCustomObject]@{
        answers = [PSCustomObject]$projected
        usage = [PSCustomObject](New-JevProbeNumericMap (Get-JevProbeNode -Node $doc -Name 'usage'))
    })
}
catch {
    # closed tokens pass through untouched; anything unexpected collapses to
    # a closed token (no free text ever crosses the boundary)
    $m = ''
    try { $m = ([string]$_.Exception.Message) } catch { $m = '' }
    if ($m -clike 'jev-transport-*') { throw $m }
    throw 'jev-transport-malformed'
}
'@

function Format-JevAdvisoryNumber {
    <#
    .SYNOPSIS
        Culture-invariant bounded number rendering for advisory
        summaries. Returns an empty string for a null or unusable
        value (never a raw or free-form value). Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return '' }
        return ([double]$Value).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch { return '' }
}

function Get-JevAdvisoryOutputSummary {
    <#
    .SYNOPSIS
        Builds the evidence summary from the CLOSED TYPED projection
        only (no regex pass over free API text), per tool:
          check  -> 'check p=<..> likely=<true|false>'
          score  -> 'score s=<..> conf=<..> legend=<n>'
          gate   -> 'gate rec=<allow|confirm|block> conf=<..>
                    risk=<..> prod=<true|false>/<..>'
          decide -> 'decide answers=<n> usage=<n>'
        Any output that does not carry the recognized typed shape falls
        back to the legacy rendering, so caller-supplied probes keep
        their previous summary byte for byte. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Tool, $Output)
    try {
        $legacy = ''
        try { $legacy = ([string]$Output) } catch { $legacy = '' }
        if ($null -eq $Output) { return 'advisory-ok' }
        $t = ([string]$Tool).Trim().ToLowerInvariant()
        $s = ''
        if ($t -ceq 'jev_check') {
            $p = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'probability'
            if ($null -ne $p) {
                $l = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'likely'
                $s = 'check p=' + (Format-JevAdvisoryNumber -Value $p) + ' likely=' + (([string]$l).ToLowerInvariant())
            }
        }
        elseif ($t -ceq 'jev_score') {
            $v = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'score'
            if ($null -ne $v) {
                $c = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'confidence'
                $l = @()
                try { $l = @(Get-JevAdvisoryPolicyNode -Doc $Output -Name 'legend') } catch { $l = @() }
                $s = 'score s=' + (Format-JevAdvisoryNumber -Value $v) + ' conf=' + (Format-JevAdvisoryNumber -Value $c) + ' legend=' + ([string]@($l).Count)
            }
        }
        elseif ($t -ceq 'jev_gate') {
            $r = [string](Get-JevAdvisoryPolicyNode -Doc $Output -Name 'recommendation')
            if (@('allow', 'confirm', 'block') -ccontains $r) {
                $c = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'confidence'
                $k = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'risk_score'
                $tp = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'touches_prod_probability'
                $s = 'gate rec=' + $r + ' conf=' + (Format-JevAdvisoryNumber -Value $c) + ' risk=' + (Format-JevAdvisoryNumber -Value $k) + ' prod=' + (Format-JevAdvisoryNumber -Value $tp)
            }
        }
        elseif ($t -ceq 'jev_decide') {
            $a = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'answers'
            if ($null -ne $a) {
                $n = 0
                try { $n = @($a.PSObject.Properties).Count } catch { $n = 0 }
                $u = Get-JevAdvisoryPolicyNode -Doc $Output -Name 'usage'
                $un = 0
                try { $un = @($u.PSObject.Properties).Count } catch { $un = 0 }
                $s = 'decide answers=' + ([string]$n) + ' usage=' + ([string]$un)
            }
        }
        if ([string]::IsNullOrWhiteSpace($s)) { return $legacy }
        return $s
    }
    catch {
        try { return ([string]$Output) } catch { return 'advisory-ok' }
    }
}

function New-JevAdvisoryHttpProbe {
    <#
    .SYNOPSIS
        Builds the SELF-CONTAINED HTTP probe scriptblock consumed by
        the reused Phase 28 envelope (the envelope runs it in a fresh
        runspace, so it must not close over any session variable;
        the process environment IS visible there).
    .DESCRIPTION
        Positional arguments are (tool, state, toolArgs hashtable,
        optional budgetSeconds). Inside the runspace the probe
        resolves JEV_BASE_URL / JEV_MODEL / JEV_API_KEY again,
        builds the wire body from the pure per-tool mapping and POSTs
        it with Bearer auth through raw HttpWebRequest (PS 5.1 safe).
        SUCCESS returns a closed typed projection (no unknown keys, no
        free API text). FAILURE throws a CLOSED token so the envelope
        counts it: timeout -> MCP_TIMEOUT, network ->
        MCP_NETWORK_ERROR (both counted by the circuit), auth/server/
        malformed/oversize/not-configured -> MCP_ERROR. Tokens are
        'jev-transport-auth-401', 'jev-transport-server-5xx',
        'jev-transport-server-3xx', 'jev-transport-malformed',
        'jev-transport-network', 'jev-transport-network-read',
        'jev-transport-timeout', 'jev-transport-not-configured':
        never a key, a base URL, a body or free text.
        Endpoint: https required; http only for loopback (127.0.0.1,
        localhost, [::1]) so a Bearer key is never sent in clear to a
        remote host; redirects are never followed. A response is only
        interpreted when its status is 200-299: a 3xx behind a disabled
        redirect is a failure, never an answer even with a valid JSON
        body. A body shorter than the declared Content-Length, or a read
        error, is a transport failure and never a whole answer.
        A jev_decide answer is bound to the question that was SENT: the
        received type must equal the sent type, and a choice must be one
        of the sent criteria keys (case sensitive, no trim). Free API
        text and type substitution are malformed, never advice.
        TimeoutSeconds is the EFFECTIVE budget (already the envelope
        budget, or a smaller explicit one). It bounds the
        HttpWebRequest socket wait as that budget plus a documented
        500ms margin; it is NOT a guaranteed total deadline. The
        AUTHORITATIVE wall clock is the envelope's, which may stop the
        probe earlier, and name resolution or connection setup are only
        bounded by the same HttpWebRequest.Timeout.
        Body reading verdicts are engine-independent by construction: a
        body declared over the 256KB cap (or whose accumulated length
        passes it) is malformed without depending on any later read; a
        body already as long as announced is complete, so a read error
        there is legitimate end-of-stream; and a read error or a short
        body while the announced length is still unmet is the specific
        network-read failure.
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 0)
    try {
        $ts = [int]$TimeoutSeconds
        if (($ts -lt 1) -or ($ts -gt 600)) { $ts = 30 }
        $text = ([string]$script:JevAdvisoryHttpProbeTemplate).Replace('__JEV_PROBE_TIMEOUT_SECONDS__', ([string]$ts))
        return ([scriptblock]::Create($text))
    }
    catch {
        return ([scriptblock]::Create('param($tool, $state, $toolArgs, $timeoutSeconds) [PSCustomObject]@{ ok = $false; error_kind = ''internal''; http_status = 0 }'))
    }
}

# ---------- authority guard ----------

function Invoke-JevAdvisoryGrantGate {
    <#
    .SYNOPSIS
        Advisory authority gate: a Jev result can never grant,
        widen, select a model or write DONE. Any input shape,
        including null or hostile, yields denial with status
        JEV_ADVISORY_CANNOT_GRANT. Never throws.
    #>
    [CmdletBinding()]
    param($JevResult)
    try {
        $st = ''
        try {
            if ($null -ne $JevResult) {
                if ($JevResult -is [System.Collections.IDictionary]) {
                    if ($JevResult.Contains('status')) { $st = ([string]$JevResult['status']).Trim() }
                }
                else {
                    $pp = $JevResult.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                    if ($null -ne $pp) { $st = ([string]$pp.Value).Trim() }
                }
            }
        }
        catch { $st = '' }
        return [PSCustomObject]@{
            ok = $false; status = 'JEV_ADVISORY_CANNOT_GRANT'; error = 'JEV_ADVISORY_CANNOT_GRANT'
            granted = $false; widened = $false; model_selected = $false; done_written = $false
            jev_status = $st
            note = 'jev-output-is-advisory-only: kernel verifier reviewer security always win'
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'JEV_ADVISORY_CANNOT_GRANT'; error = 'JEV_ADVISORY_CANNOT_GRANT'
            granted = $false; widened = $false; model_selected = $false; done_written = $false
            jev_status = ''
            note = 'jev-output-is-advisory-only: kernel verifier reviewer security always win'
        }
    }
}

function Get-JevAdvisoryEffectiveDecision {
    <#
    .SYNOPSIS
        Folds Jev advice under kernel/verifier authority: the
        effective allow follows the kernel grant only, and the
        effective completion follows the verifier only. Jev
        inputs are recorded for evidence but never flip either
        outcome. Never throws.
    #>
    [CmdletBinding()]
    param(
        [bool]$JevWantsAllow = $false,
        [bool]$KernelAllows = $false,
        [bool]$JevWantsComplete = $false,
        [bool]$VerifierPasses = $false
    )
    try {
        return [PSCustomObject]@{
            effective_allow = [bool]$KernelAllows
            effective_done = [bool]$VerifierPasses
            kernel_wins = $true
            jev_wants_allow = [bool]$JevWantsAllow
            jev_wants_complete = [bool]$JevWantsComplete
        }
    }
    catch {
        return [PSCustomObject]@{
            effective_allow = $false; effective_done = $false; kernel_wins = $true
            jev_wants_allow = $false; jev_wants_complete = $false
        }
    }
}

# ---------- sanitized evidence ----------

function Get-JevAdvisoryFieldRedaction {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = ([string]$Value)
        try {
            if ((Get-Command Get-McpSafetyFieldRedaction -ErrorAction SilentlyContinue) -ne $null) {
                return (Get-McpSafetyFieldRedaction -Value $s)
            }
        }
        catch { }
        $s = $s -replace '(?i)JEV_API_KEY\s*[=:\s]+[^\s|]+', 'JEV_API_KEY <redacted>'
        $s = $s -replace '(?i)(token|api[_-]?key|secret|password)\s*=\s*[^\s|]+', '$1=<redacted>'
        $s = $s -replace '(?i)sk-[A-Za-z0-9\-_]+', '<redacted>'
        try {
            if ((Get-Command Get-SecretValuePattern -ErrorAction SilentlyContinue) -ne $null) {
                $pat = (Get-SecretValuePattern)
                if (-not [string]::IsNullOrWhiteSpace([string]$pat)) {
                    $s = ([regex]::Replace($s, [string]$pat, '[REDACTED]'))
                }
            }
        }
        catch { }
        return $s
    }
    catch { return '[REDACTED]' }
}

function Get-JevAdvisoryInputHash {
    <#
    .SYNOPSIS
        Canonical sha256 over the len:value-framed sanitized
        tool|reason|descriptor JSON. Only the hex digest is kept.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Tool, [string]$TriggerReason, $Descriptor)
    try {
        $t = Get-JevAdvisoryFieldRedaction -Value (([string]$Tool).Trim().ToLowerInvariant())
        if ($t.Length -gt 64) { $t = $t.Substring(0, 64) }
        $r = Get-JevAdvisoryFieldRedaction -Value (([string]$TriggerReason).Trim().ToLowerInvariant())
        if ($r.Length -gt 64) { $r = $r.Substring(0, 64) }
        $dj = ''
        try {
            if ($null -ne $Descriptor) { $dj = ($Descriptor | ConvertTo-Json -Depth 4 -Compress) }
        }
        catch { $dj = '' }
        $dj = Get-JevAdvisoryFieldRedaction -Value ([string]$dj)
        if ($dj.Length -gt 512) { $dj = $dj.Substring(0, 512) }
        $joined = ([string]$t.Length) + ':' + $t + '|' + ([string]$r.Length) + ':' + $r + '|' + ([string]$dj.Length) + ':' + $dj
        $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
    }
    catch { return '' }
}

function Get-JevAdvisoryEvidenceFile {
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot)
    try {
        $dir = $TelemetryRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $repo = Get-JevAdvisoryRepoRoot -RepoRoot $RepoRoot
            $dir = Join-Path $repo 'cache\v3\jev-advisory'
        }
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $dir ('jev-advisory-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-JevAdvisoryEvidence {
    <#
    .SYNOPSIS
        Appends one sanitized advisory evidence record to the
        daily jev-advisory JSONL. Pre-size accounting with a
        rotation cap, fail-closed under a gate acquired with a
        BOUNDED TryEnter (shared TelemetryGate when the McpSafety
        cell is loaded, else a session lock): under contention
        the event is SKIPPED with an honest lock-busy code and
        the caller path never blocks. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Tool,
        [string]$TriggerReason = '',
        $Descriptor = $null,
        [string]$OutputSummary = '',
        [int]$BudgetS = 0,
        [int]$ElapsedMs = 0,
        [int]$Consecutive = 0,
        [string]$Circuit = '',
        [string]$Mode = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = ''
    )
    try {
        $allowed = @('JEV_WOULD_CONSULT', 'JEV_NOT_TRIGGERED', 'JEV_ADVISORY_OK', 'JEV_UNAVAILABLE', 'JEV_AUTH_INVALID', 'JEV_POLICY_INVALID', 'JEV_DISABLED', 'JEV_FLAG_INVALID', 'INVALID_TOOL', 'INVALID_TURN_ID')
        $ev = ([string]$EventName).Trim().ToUpperInvariant()
        if ($allowed -cnotcontains $ev) {
            return [PSCustomObject]@{ ok = $false; skipped = 'bad-event' }
        }
        $tool = Get-JevAdvisoryFieldRedaction -Value (([string]$Tool).Trim().ToLowerInvariant())
        if ($tool.Length -gt 64) { $tool = $tool.Substring(0, 64) }
        $reason = Get-JevAdvisoryFieldRedaction -Value (([string]$TriggerReason).Trim().ToLowerInvariant())
        if ($reason.Length -gt 64) { $reason = $reason.Substring(0, 64) }
        $summary = Get-JevAdvisoryFieldRedaction -Value ([string]$OutputSummary)
        if ($summary.Length -gt 256) { $summary = $summary.Substring(0, 256) }
        $cir = ([string]$Circuit).Trim().ToUpperInvariant()
        if (@('CLOSED', 'OPEN', 'HALF_OPEN', '') -cnotcontains $cir) { $cir = '' }
        $mode = ([string]$Mode).Trim().ToLowerInvariant()
        if (@('shadow', 'active', 'disabled', '') -cnotcontains $mode) { $mode = '' }
        $hash = Get-JevAdvisoryInputHash -Tool $Tool -TriggerReason $TriggerReason -Descriptor $Descriptor
        $doc = [ordered]@{
            ts             = ([DateTimeOffset]::UtcNow.ToString('o'))
            source         = 'jev-advisory'
            event          = $ev
            tool           = $tool
            trigger_reason = $reason
            input_hash     = $hash
            output_summary = $summary
            budget_s       = [int]$BudgetS
            elapsed_ms     = [int]$ElapsedMs
            consecutive    = [int]$Consecutive
            circuit        = $cir
            mode           = $mode
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        $target = Get-JevAdvisoryEvidenceFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($target)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $gate = $script:JevAdvisoryTelemetryLock
        try {
            if ((Get-Command Get-McpSafetySharedGate -ErrorAction SilentlyContinue) -ne $null) {
                $shared = Get-McpSafetySharedGate -Name 'TelemetryGate'
                if ($null -ne $shared) { $gate = $shared }
            }
        }
        catch { }
        $waitMs = 250
        try { $waitMs = [int]$script:JevAdvisoryTelemetryLockWaitMs } catch { $waitMs = 250 }
        if ($waitMs -lt 0) { $waitMs = 0 }
        if ($waitMs -gt 10000) { $waitMs = 10000 }
        $lockTaken = $false
        try {
            [void][System.Threading.Monitor]::TryEnter($gate, $waitMs, [ref]$lockTaken)
            if (-not [bool]$lockTaken) {
                return [PSCustomObject]@{ ok = $false; skipped = 'lock-busy' }
            }
            try {
                $parent = Split-Path -Parent $target
                if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'mkdir' } }
            try {
                $eventBytes = [Text.Encoding]::UTF8.GetByteCount(($text + "`n"))
                $currentLen = [long]0
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $currentLen = ([IO.FileInfo]::new($target)).Length
                }
                if (($currentLen + [long]$eventBytes) -gt [long]$script:JevAdvisoryTelemetryCapBytes) {
                    return [PSCustomObject]@{ ok = $false; skipped = 'rotation-cap' }
                }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'accounting-unavailable' } }
            try {
                [IO.File]::AppendAllText($target, ($text + "`n"), [Text.UTF8Encoding]::new($false))
                return [PSCustomObject]@{ ok = $true; skipped = '' }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'write' } }
        }
        finally {
            if ($lockTaken) {
                try { [System.Threading.Monitor]::Exit($gate) } catch { }
            }
        }
    }
    catch { return [PSCustomObject]@{ ok = $false; skipped = 'internal' } }
}

function Clear-JevAdvisoryState {
    <#
    .SYNOPSIS
        Resets Jev advisory session seams (circuit state lives
        in the reused McpSafety cell: use Clear-McpSafetyState
        for that). Never throws.
    #>
    [CmdletBinding()]
    param()
    try { $script:JevAdvisoryTelemetryLockWaitMs = 250 } catch { }
}

# ---------- bounded advisory call (envelope reuse) ----------

function New-JevAdvisoryResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [bool]$Ok = $false,
        [string]$Failure = '',
        [string]$Tool = '',
        [string]$TriggerReason = '',
        [bool]$Consulted = $false,
        [bool]$WouldConsult = $false,
        [bool]$FallbackContinue = $false,
        [bool]$Blocked = $false,
        [string]$Mode = '',
        [string]$Circuit = 'CLOSED',
        [int]$Consecutive = 0,
        [int]$BudgetS = 0,
        [int]$ElapsedMs = 0,
        $Output = $null,
        $Extra = $null
    )
    try {
        $r = [ordered]@{
            ok = [bool]$Ok; status = $Status; error = $Status; failure = ([string]$Failure)
            tool = ([string]$Tool); trigger_reason = ([string]$TriggerReason)
            consulted = [bool]$Consulted; would_consult = [bool]$WouldConsult
            fallback_continue = [bool]$FallbackContinue; blocked = [bool]$Blocked
            mode = ([string]$Mode); circuit = ([string]$Circuit); consecutive = [int]$Consecutive
            budget_s = [int]$BudgetS; elapsed_ms = [int]$ElapsedMs; output = $Output
        }
        if ($null -ne $Extra) {
            if ($Extra -is [System.Collections.IDictionary]) {
                foreach ($k in @($Extra.Keys)) { $r[[string]$k] = $Extra[$k] }
            }
            else {
                foreach ($p in @($Extra.PSObject.Properties)) { $r[$p.Name] = $p.Value }
            }
        }
        return ([PSCustomObject]$r)
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'JEV_UNAVAILABLE'; error = 'JEV_UNAVAILABLE'; failure = 'JEV_UNAVAILABLE'
            tool = ''; trigger_reason = ''; consulted = $false; would_consult = $false
            fallback_continue = $true; blocked = $false; mode = ''; circuit = 'CLOSED'
            consecutive = 0; budget_s = 0; elapsed_ms = 0; output = $null
        }
    }
}

function Invoke-JevAdvisoryCall {
    <#
    .SYNOPSIS
        Bounded Jev advisory call reusing the Phase 28 MCP safety
        envelope (class advisory). Never throws: every outcome is
        a structured result object with deterministic fallback
        posture (JEV_UNAVAILABLE never blocks the task).
    .DESCRIPTION
        Order: Jev policy gate, tool allowlist, deterministic
        trigger, flag mode (shadow records would-consult without
        calling; disabled refuses without calling), credential
        gate (absent means JEV_UNAVAILABLE, malformed means
        JEV_AUTH_INVALID), then the envelope invoke. Advisory
        evidence is recorded on every terminal path. Zero real
        network when -Probe is supplied (the synthetic seam used
        by the suite, unchanged behaviour).
    .DESCRIPTION
        When -Probe is NOT supplied the built-in HTTP transport is
        used, still inside the same envelope: -State is required
        (missing means a structured INVALID_REQUEST with no
        invented content), the transport must be configured
        (JEV_TRANSPORT_NOT_CONFIGURED otherwise) and the wire
        request must be mappable (INVALID_REQUEST otherwise).
        A caller-supplied -Probe always wins over the transport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$TurnId,
        $Descriptor = $null,
        [string]$State = '',
        $ToolArgs = $null,
        [scriptblock]$Probe = $null,
        [object[]]$ProbeArgs = @(),
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$McpPolicyPath = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [int]$BudgetSecondsOverride = 0,
        [string]$ApiKey = $null,
        $NowUtc = $null,
        $ConcludedAtUtc = $null
    )
    try {
        $tool = ([string]$Tool).Trim().ToLowerInvariant()
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-JevAdvisoryDefaultPolicyPath -RepoRoot $RepoRoot }
        $gate = Assert-JevAdvisoryPolicyJson -Path $pp
        if (-not [bool]$gate.valid) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_POLICY_INVALID' -Tool $tool -TriggerReason '' -Descriptor $Descriptor -OutputSummary ((@($gate.errors) -join '|')) -Mode '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_POLICY_INVALID' -Ok $false -Failure 'JEV_POLICY_INVALID' -Tool $tool -Consulted $false -FallbackContinue $true -Blocked $false -Extra @{ policy_errors = @($gate.errors) })
        }
        if ($script:JevAdvisoryAllowedTools -notcontains $tool) {
            [void](Write-JevAdvisoryEvidence -EventName 'INVALID_TOOL' -Tool $tool -TriggerReason '' -Descriptor $Descriptor -OutputSummary 'tool-not-in-closed-set' -Mode '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'INVALID_TOOL' -Ok $false -Failure 'INVALID_TOOL' -Tool $tool -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        if (-not (Test-JevAdvisoryTurnId -Value $TurnId)) {
            [void](Write-JevAdvisoryEvidence -EventName 'INVALID_TURN_ID' -Tool $tool -TriggerReason '' -Descriptor $Descriptor -OutputSummary 'turn-id-rejected' -Mode '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'INVALID_TURN_ID' -Ok $false -Failure 'INVALID_TURN_ID' -Tool $tool -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $trig = Test-JevAdvisoryTrigger -Descriptor $Descriptor
        $reason = ([string]$trig.trigger_reason)
        if (-not [bool]$trig.should_consult) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_NOT_TRIGGERED' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'no-consult' -Mode '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_NOT_TRIGGERED' -Ok $true -Failure '' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $flag = Get-JevAdvisoryFlag -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flag.found) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_FLAG_INVALID' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'flag-node-missing' -Mode '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_FLAG_INVALID' -Ok $false -Failure 'JEV_FLAG_INVALID' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        if ([string]$flag.mode -ceq 'shadow') {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_WOULD_CONSULT' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'would-consult-shadow-no-call' -Mode 'shadow' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_WOULD_CONSULT' -Ok $true -Failure '' -Tool $tool -TriggerReason $reason -Consulted $false -WouldConsult $true -FallbackContinue $true -Blocked $false -Mode 'shadow')
        }
        if ([string]$flag.mode -cne 'active') {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_DISABLED' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'flag-disabled-no-call' -Mode 'disabled' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_DISABLED' -Ok $true -Failure '' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'disabled')
        }
        $key = $null
        if ($PSBoundParameters.ContainsKey('ApiKey')) { $key = $ApiKey }
        else {
            try { $key = $env:JEV_API_KEY } catch { $key = $null }
        }
        $kc = Test-JevAdvisoryApiKey -ApiKey ([string]$key)
        if (-not [bool]$kc.present) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'credential-absent-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
        }
        if (-not [bool]$kc.valid) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_AUTH_INVALID' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'credential-rejected-structured' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_AUTH_INVALID' -Ok $false -Failure 'JEV_AUTH_INVALID' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
        }
        if ((Get-Command Invoke-McpSafetyCall -ErrorAction SilentlyContinue) -eq $null) {
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'envelope-unavailable-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_ENVELOPE_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
        }
        if ($null -eq $Probe) {
            $stateText = ([string]$State).Trim()
            if ([string]::IsNullOrWhiteSpace($stateText)) {
                [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'state-missing-invalid-request-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'INVALID_REQUEST' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
            }
            $tcfg = Resolve-JevAdvisoryTransportConfig
            if (-not [bool]$tcfg.ok) {
                [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'transport-not-configured-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_TRANSPORT_NOT_CONFIGURED' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active' -Extra @{ transport_error_kind = ([string]$tcfg.error_kind) })
            }
            $envKey = $null
            try { $envKey = $env:JEV_API_KEY } catch { $envKey = $null }
            $ekc = Test-JevAdvisoryApiKey -ApiKey ([string]$envKey)
            if (-not [bool]$ekc.present) {
                [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'transport-credential-absent-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
            }
            if (-not [bool]$ekc.valid) {
                [void](Write-JevAdvisoryEvidence -EventName 'JEV_AUTH_INVALID' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'transport-credential-rejected-structured' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-JevAdvisoryResult -Status 'JEV_AUTH_INVALID' -Ok $false -Failure 'JEV_AUTH_INVALID' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
            }
            if ($PSBoundParameters.ContainsKey('ApiKey')) {
                $givenKey = ([string]$ApiKey).Trim()
                if ((-not [string]::IsNullOrWhiteSpace($givenKey)) -and ($givenKey -cne ([string]$envKey).Trim())) {
                    [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'transport-credential-source-mismatch-invalid-request' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                    return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'INVALID_REQUEST' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
                }
            }
            $wire = ConvertTo-JevAdvisoryWireRequest -Tool $tool -State $stateText -ToolArgs $ToolArgs -Model ([string]$tcfg.model)
            if (-not [bool]$wire.ok) {
                [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary ('wire-invalid:' + ([string]$wire.error_kind)) -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'INVALID_REQUEST' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active' -Extra @{ wire_error_kind = ([string]$wire.error_kind) })
            }
            $probeBudget = 30
            if (([int]$BudgetSecondsOverride -gt 0) -and ([int]$BudgetSecondsOverride -lt $probeBudget)) { $probeBudget = [int]$BudgetSecondsOverride }
            $Probe = New-JevAdvisoryHttpProbe -TimeoutSeconds $probeBudget
            $ProbeArgs = @($tool, $stateText, $ToolArgs)
        }
        $cap = ([string]$script:JevAdvisoryToolCapability[$tool])
        if ([string]::IsNullOrWhiteSpace($cap)) { $cap = 'jev.decide' }
        $mcpPath = $McpPolicyPath
        if ([string]::IsNullOrWhiteSpace($mcpPath)) { $mcpPath = Get-JevAdvisoryDefaultMcpPolicyPath -RepoRoot $RepoRoot }
        $envResult = Invoke-McpSafetyCall -Server 'jev' -Capability $cap -TurnId ([string]$TurnId).Trim() -Class 'advisory' -Criticality 'optional' -Probe $Probe -ProbeArgs $ProbeArgs -BudgetSecondsOverride ([int]$BudgetSecondsOverride) -PolicyPath $mcpPath -RepoRoot $RepoRoot -TelemetryRoot $TelemetryRoot -NowUtc $NowUtc -ConcludedAtUtc $ConcludedAtUtc
        $budget = 30
        $elapsed = 0
        $cir = 'CLOSED'
        $consec = 0
        try { $budget = [int]$envResult.budget_s } catch { $budget = 30 }
        try { $elapsed = [int]$envResult.elapsed_ms } catch { $elapsed = 0 }
        try { $cir = ([string]$envResult.circuit).Trim().ToUpperInvariant() } catch { $cir = 'CLOSED' }
        try { $consec = [int]$envResult.consecutive } catch { $consec = 0 }
        if (([bool]$envResult.ok) -and ([string]$envResult.status -ceq 'OK')) {
            $summary = Get-JevAdvisoryOutputSummary -Tool $tool -Output $envResult.output
            if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'advisory-ok' }
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_ADVISORY_OK' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary $summary -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_ADVISORY_OK' -Ok $true -Failure '' -Tool $tool -TriggerReason $reason -Consulted $true -FallbackContinue $false -Blocked $false -Mode 'active' -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed -Output $envResult.output)
        }
        $cause = 'JEV_UNAVAILABLE'
        try {
            $fc = ([string]$envResult.failure).Trim().ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($fc)) { $cause = $fc }
        }
        catch { $cause = 'JEV_UNAVAILABLE' }
        # A rejected credential is never an advisory success and never an
        # ordinary transport error: the envelope already refused the call
        # (MCP_ERROR), so the CLOSED probe token is translated into the
        # published auth cause. No legacy probe can produce this token.
        if ($cause -ceq 'MCP_ERROR') {
            try {
                $pe = ([string]$envResult.probe_error)
                # the envelope reports probe_error wrapped by PowerShell
                # ("Exception calling EndInvoke ... : 'token'"), so the closed
                # token is matched as a substring, never as a prefix
                if ($pe -match 'jev-transport-auth') { $cause = 'JEV_AUTH_REJECTED' }
            }
            catch { }
        }
        [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary ('envelope-cause:' + $cause) -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure $cause -Tool $tool -TriggerReason $reason -Consulted $true -FallbackContinue $true -Blocked $false -Mode 'active' -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
    }
    catch {
        return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_UNAVAILABLE' -Tool ([string]$Tool) -Consulted $false -FallbackContinue $true -Blocked $false)
    }
}
