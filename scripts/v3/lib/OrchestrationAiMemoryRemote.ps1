<#!
.SYNOPSIS
    V3 AI Memory remote kernel-side slice (Phase 30, slice 1: kernel side).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the
    kernel-side remote dependency from the V3.1 runtime-reliability
    addendum (PLAN Phase 30 tasks 1-9 kernel side, SPEC memory
    section): a bounded REMOTE-ONLY AI Memory dependency with
    user-owned endpoint config, bounded health probe, circuit via
    the Phase 28 envelope (class memory), optional-continue vs
    required-blocker semantics, and sanitized telemetry.

      - Policy registry source/registry/ai-memory-remote-policy.json
        (version 1): endpoint schema {url (empty or the
        __USER_OWNED__ placeholder means UNCONFIGURED), auth
        {type:env, name:AIMEMORY_REMOTE_TOKEN} carrying the
        variable NAME only, never a value, tls_verify fixed true},
        60s retrieval budget, 10s health probe budget, circuit
        identical to the canonical envelope (threshold 2, cooldown
        300s), scoping {workspace plus project always together,
        forbid_local_fallback}, criticality default optional.
        A missing or divergent policy fails closed with
        AIMEMORY_POLICY_INVALID: this file never falls back to
        silent URL defaults and never proceeds on drift.
      - Bounded invoke REUSES the Phase 28 envelope
        (OrchestrationMcpSafety.ps1, class memory): this lib
        orchestrates (policy gate, scope gate, endpoint gate,
        credential gate, envelope invoke, outcome mapping) and
        creates no parallel timeout/circuit primitives and owns
        zero network primitives. Probes are caller-supplied
        self-contained scriptblocks (synthetic seam in tests, zero
        real network). Real VPS transport activation is HOLD.
      - The fixed local listener is NEVER touched by this slice:
        absence of remote config yields AIMEMORY_UNCONFIGURED
        (optional continues, required blocks typed), never a
        silent fallback to any local endpoint. Remote-only by
        config: a loopback endpoint URL is rejected fail-closed.
      - Semantics: optional plus unavailable maps to
        AIMEMORY_UNAVAILABLE with fallback_continue=true and
        blocked=false; required plus unavailable maps to
        AIMEMORY_REQUIRED_BLOCKED with blocked=true in EVERY
        branch (timeout, circuit, auth, 5xx, unconfigured, dns,
        network, envelope contention). No path degrades required.
        AIMEMORY_POLICY_INVALID additionally blocks every
        criticality (nothing proceeds without a policy).
      - Sanitized bounded telemetry to
        cache/v3/ai-memory-remote/ daily JSONL: pre-size
        accounting with rotation cap, fail-closed under a gate
        acquired with a BOUNDED TryEnter (shared TelemetryGate
        when the McpSafety cell is loaded, else a session lock),
        per-field secret redaction (including sk- canaries) and
        len:value framing. The endpoint URL is never logged
        whole: host plus len:port only. Workspace/project travel
        as a hash plus presence flag, never raw. Under gate
        contention the event is SKIPPED with an honest lock-busy
        code and the caller path never blocks.

    PowerShell 5.1 compatible. ASCII-only. Expected domain
    results are returned as result objects, never thrown across
    the boundary.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sanitizeLibPath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $sanitizeLibPath -PathType Leaf) {
    . $sanitizeLibPath
}

$script:AiMemoryRemoteTelemetryCapBytes = 1048576
$script:AiMemoryRemoteTelemetryLock = New-Object Object
$script:AiMemoryRemoteTelemetryLockWaitMs = 250
$script:AiMemoryRemoteServerId = 'aimemory-remote'
$script:AiMemoryRemoteRecallCapability = 'aimemory.recall'
$script:AiMemoryRemoteHealthCapability = 'aimemory.health'
$script:AiMemoryRemoteUnconfiguredMarker = '__USER_OWNED__'

# ---------- repo / path helpers ----------

function Get-AiMemoryRemoteRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-AiMemoryRemoteDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-AiMemoryRemoteRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\ai-memory-remote-policy.json')
}

function Get-AiMemoryRemoteDefaultMcpPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-AiMemoryRemoteRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\mcp-request-policy.json')
}

function Get-AiMemoryRemotePolicyNode {
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

function Test-AiMemoryRemoteInt {
    [CmdletBinding()]
    param($Value, [int]$Min = 1, [int]$Max = 2147483647)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
        $n = [long]$Value
        return (($n -ge [long]$Min) -and ($n -le [long]$Max))
    }
    catch { return $false }
}

function Test-AiMemoryRemoteConfiguredUrl {
    <#
    .SYNOPSIS
        Classifies an endpoint URL without ever connecting.
        Returns @{configured, valid, reason}: empty or the
        __USER_OWNED__ placeholder means unconfigured (valid
        registry state, not an error); otherwise the URL must be
        an absolute http/https URI and must not be loopback
        (remote-only by config). Never throws. Never logs the URL.
    #>
    [CmdletBinding()]
    param([string]$Url)
    try {
        $u = ([string]$Url).Trim()
        if ([string]::IsNullOrWhiteSpace($u)) {
            return [PSCustomObject]@{ configured = $false; valid = $true; reason = 'AIMEMORY_UNCONFIGURED' }
        }
        if ($u -ceq $script:AiMemoryRemoteUnconfiguredMarker) {
            return [PSCustomObject]@{ configured = $false; valid = $true; reason = 'AIMEMORY_UNCONFIGURED' }
        }
        $uri = $null
        try { $uri = [System.Uri]::new($u) } catch { $uri = $null }
        if (($null -eq $uri) -or (-not $uri.IsAbsoluteUri)) {
            return [PSCustomObject]@{ configured = $true; valid = $false; reason = 'AIMEMORY_ENDPOINT_INVALID' }
        }
        $scheme = ([string]$uri.Scheme).Trim().ToLowerInvariant()
        if (($scheme -cne 'http') -and ($scheme -cne 'https')) {
            return [PSCustomObject]@{ configured = $true; valid = $false; reason = 'AIMEMORY_ENDPOINT_INVALID' }
        }
        try {
            if ([bool]$uri.IsLoopback) {
                return [PSCustomObject]@{ configured = $true; valid = $false; reason = 'AIMEMORY_ENDPOINT_INVALID' }
            }
        }
        catch {
            return [PSCustomObject]@{ configured = $true; valid = $false; reason = 'AIMEMORY_ENDPOINT_INVALID' }
        }
        return [PSCustomObject]@{ configured = $true; valid = $true; reason = '' }
    }
    catch { return [PSCustomObject]@{ configured = $false; valid = $false; reason = 'AIMEMORY_ENDPOINT_INVALID' } }
}

function Get-AiMemoryRemoteEndpointSummary {
    <#
    .SYNOPSIS
        Sanitized endpoint summary for telemetry: host plus
        len:port only, never the whole URL, never credentials.
        Returns @{host, port_len}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Url)
    try {
        $u = ([string]$Url).Trim()
        if ([string]::IsNullOrWhiteSpace($u)) {
            return [PSCustomObject]@{ host = 'unconfigured'; port_len = 'len:0' }
        }
        if ($u -ceq $script:AiMemoryRemoteUnconfiguredMarker) {
            return [PSCustomObject]@{ host = 'unconfigured'; port_len = 'len:0' }
        }
        $uri = $null
        try { $uri = [System.Uri]::new($u) } catch { $uri = $null }
        if (($null -eq $uri) -or (-not $uri.IsAbsoluteUri)) {
            return [PSCustomObject]@{ host = 'unparseable'; port_len = 'len:0' }
        }
        $h = ([string]$uri.Host).Trim().ToLowerInvariant()
        $h = Get-AiMemoryRemoteFieldRedaction -Value $h
        if ([string]::IsNullOrWhiteSpace($h)) { $h = 'unparseable' }
        if ($h.Length -gt 64) { $h = $h.Substring(0, 64) }
        $plen = 'len:0'
        try { $plen = ('len:' + ([string]([string]$uri.Port).Length)) } catch { $plen = 'len:0' }
        return [PSCustomObject]@{ host = $h; port_len = $plen }
    }
    catch { return [PSCustomObject]@{ host = 'unparseable'; port_len = 'len:0' } }
}

function Read-AiMemoryRemotePolicy {
    <#
    .SYNOPSIS
        Reads the remote policy file. Returns @{found,
        malformed, doc}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $out = @{ found = $false; malformed = $false; doc = $null }
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-AiMemoryRemoteDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $out.found = $true
        try { $out.doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $out.doc) { $out.malformed = $true; return $out }
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Assert-AiMemoryRemotePolicyJson {
    <#
    .SYNOPSIS
        Validates the remote policy file. Returns @{valid,
        errors}. Endpoint schema {url string (empty or
        __USER_OWNED__ means unconfigured; otherwise absolute
        http/https non-loopback), auth exactly {type:env,
        name:AIMEMORY_REMOTE_TOKEN} with no value-bearing keys,
        tls_verify exactly true}, retrieval budget exactly 60,
        health probe budget exactly 10, circuit threshold 2 with
        cooldown 300, scoping with require_both_together and
        forbid_local_fallback exactly true, criticality exactly
        {optional, required} defaulting to optional. Never throws.
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
        try { if ([int](Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'version') -ne 1) { $errors.Add('version-must-be-1') | Out-Null } }
        catch { $errors.Add('version-must-be-1') | Out-Null }
        $ep = Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'endpoint'
        if ($null -eq $ep) { $errors.Add('endpoint-missing') | Out-Null }
        else {
            $urlNode = Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'url'
            if (($null -ne $urlNode) -and (-not ($urlNode -is [string]))) {
                $errors.Add('endpoint-url-must-be-string') | Out-Null
            }
            else {
                $cls = Test-AiMemoryRemoteConfiguredUrl -Url ([string]$urlNode)
                if (([bool]$cls.configured) -and (-not [bool]$cls.valid)) {
                    $errors.Add('endpoint-url-invalid-or-not-remote') | Out-Null
                }
            }
            $auth = Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'auth'
            if ($null -eq $auth) { $errors.Add('auth-missing') | Out-Null }
            else {
                $atype = ([string](Get-AiMemoryRemotePolicyNode -Doc $auth -Name 'type')).Trim()
                if ($atype -cne 'env') { $errors.Add('auth-type-must-be-env') | Out-Null }
                $aname = ([string](Get-AiMemoryRemotePolicyNode -Doc $auth -Name 'name')).Trim()
                if ($aname -cne 'AIMEMORY_REMOTE_TOKEN') { $errors.Add('auth-name-must-be-AIMEMORY_REMOTE_TOKEN') | Out-Null }
                $akeys = @()
                try {
                    if ($auth -is [System.Collections.IDictionary]) { foreach ($k in @($auth.Keys)) { $akeys += ([string]$k).Trim().ToLowerInvariant() } }
                    else { foreach ($pp in @($auth.PSObject.Properties)) { $akeys += (([string]$pp.Name).Trim().ToLowerInvariant()) } }
                }
                catch { }
                foreach ($forbidden in @('value', 'token', 'secret', 'password')) {
                    if ($akeys -contains $forbidden) { $errors.Add(('auth-must-not-carry-value:' + $forbidden)) | Out-Null }
                }
            }
            $tls = Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'tls_verify'
            if ((-not ($tls -is [bool])) -or (-not [bool]$tls)) {
                $errors.Add('tls_verify-must-be-true') | Out-Null
            }
        }
        try { if ([int](Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'retrieval_budget_seconds') -ne 60) { $errors.Add('retrieval-budget-must-be-60') | Out-Null } }
        catch { $errors.Add('retrieval-budget-must-be-60') | Out-Null }
        try { if ([int](Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'health_probe_budget_seconds') -ne 10) { $errors.Add('health-probe-budget-must-be-10') | Out-Null } }
        catch { $errors.Add('health-probe-budget-must-be-10') | Out-Null }
        $circuit = Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'circuit'
        if ($null -eq $circuit) { $errors.Add('circuit-missing') | Out-Null }
        else {
            try { if ([int](Get-AiMemoryRemotePolicyNode -Doc $circuit -Name 'failure_threshold') -ne 2) { $errors.Add('circuit-threshold-must-be-2') | Out-Null } }
            catch { $errors.Add('circuit-threshold-must-be-2') | Out-Null }
            try { if ([int](Get-AiMemoryRemotePolicyNode -Doc $circuit -Name 'cooldown_seconds') -ne 300) { $errors.Add('circuit-cooldown-must-be-300') | Out-Null } }
            catch { $errors.Add('circuit-cooldown-must-be-300') | Out-Null }
        }
        $scoping = Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'scoping'
        if ($null -eq $scoping) { $errors.Add('scoping-missing') | Out-Null }
        else {
            $both = Get-AiMemoryRemotePolicyNode -Doc $scoping -Name 'require_both_together'
            if ((-not ($both -is [bool])) -or (-not [bool]$both)) {
                $errors.Add('scoping-require_both_together-must-be-true') | Out-Null
            }
            $nolocal = Get-AiMemoryRemotePolicyNode -Doc $scoping -Name 'forbid_local_fallback'
            if ((-not ($nolocal -is [bool])) -or (-not [bool]$nolocal)) {
                $errors.Add('scoping-forbid_local_fallback-must-be-true') | Out-Null
            }
        }
        $crit = Get-AiMemoryRemotePolicyNode -Doc $doc -Name 'criticality'
        if ($null -eq $crit) { $errors.Add('criticality-missing') | Out-Null }
        else {
            $allowed = @()
            foreach ($e in @(Get-AiMemoryRemotePolicyNode -Doc $crit -Name 'allowed')) { $allowed += (([string]$e).Trim()) }
            if ((@($allowed).Count -ne 2) -or ($allowed -notcontains 'optional') -or ($allowed -notcontains 'required')) {
                $errors.Add('criticality-allowed-must-be-optional-required') | Out-Null
            }
            $dflt = ([string](Get-AiMemoryRemotePolicyNode -Doc $crit -Name 'default')).Trim()
            if ($dflt -cne 'optional') { $errors.Add('criticality-default-must-be-optional') | Out-Null }
        }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

# ---------- scope / credential gates ----------

function Test-AiMemoryRemoteTurnId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-AiMemoryRemoteScope {
    <#
    .SYNOPSIS
        Project scoping gate: workspace and project travel
        together always (both present or both absent); exactly
        one supplied means AIMEMORY_SCOPE_INVALID. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Workspace, [string]$Project)
    try {
        $w = ([string]$Workspace).Trim()
        $p = ([string]$Project).Trim()
        $hasW = (-not [string]::IsNullOrWhiteSpace($w))
        $hasP = (-not [string]::IsNullOrWhiteSpace($p))
        if ($hasW -eq $hasP) {
            return [PSCustomObject]@{ ok = $true; status = 'OK'; scoped = $hasW }
        }
        return [PSCustomObject]@{ ok = $false; status = 'AIMEMORY_SCOPE_INVALID'; scoped = $false }
    }
    catch { return [PSCustomObject]@{ ok = $false; status = 'AIMEMORY_SCOPE_INVALID'; scoped = $false } }
}

function Test-AiMemoryRemoteToken {
    <#
    .SYNOPSIS
        Credential presence gate (real transport is HOLD):
        absent (null, empty or whitespace-only) means
        AIMEMORY_AUTH_MISSING; a control character in ANY
        position of the ORIGINAL value (checked before any
        trim) means AIMEMORY_AUTH_INVALID; auth semantics
        belong to the real transport, never to a value format
        checked here. Never throws. Never logs the value.
    #>
    [CmdletBinding()]
    param([string]$Token)
    try {
        $v = ([string]$Token)
        if ([string]::IsNullOrWhiteSpace($v)) {
            return [PSCustomObject]@{ present = $false; valid = $false; status = 'AIMEMORY_AUTH_MISSING' }
        }
        if ($v -match '[\x00-\x1F\x7F]') {
            return [PSCustomObject]@{ present = $true; valid = $false; status = 'AIMEMORY_AUTH_INVALID' }
        }
        $t = $v.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) {
            return [PSCustomObject]@{ present = $false; valid = $false; status = 'AIMEMORY_AUTH_MISSING' }
        }
        return [PSCustomObject]@{ present = $true; valid = $true; status = 'OK' }
    }
    catch { return [PSCustomObject]@{ present = $false; valid = $false; status = 'AIMEMORY_AUTH_MISSING' } }
}

function Get-AiMemoryRemoteEffectiveToken {
    <#
    .SYNOPSIS
        Resolves the credential by NAME only: an explicit
        -Token argument wins, otherwise the user-owned
        AIMEMORY_REMOTE_TOKEN environment variable. The value
        never enters policy, telemetry or evidence. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Token, [bool]$TokenBound = $false)
    try {
        if ([bool]$TokenBound) { return ([string]$Token) }
        try { return ([string]$env:AIMEMORY_REMOTE_TOKEN) } catch { return '' }
    }
    catch { return '' }
}

# ---------- criticality mapping ----------

function Get-AiMemoryRemoteCriticality {
    [CmdletBinding()]
    param([string]$Criticality)
    try {
        $c = ([string]$Criticality).Trim().ToLowerInvariant()
        if ($c -ceq 'required') { return 'required' }
        return 'optional'
    }
    catch { return 'optional' }
}

function ConvertTo-AiMemoryRemoteOutcome {
    <#
    .SYNOPSIS
        Central optional-continue vs required-blocker mapping.
        Transport/config causes (unconfigured, dns, timeout,
        network, auth, 5xx, circuit, envelope contention):
        optional yields AIMEMORY_UNAVAILABLE with the cause in
        failure, fallback_continue=true, blocked=false;
        required yields AIMEMORY_REQUIRED_BLOCKED with the cause
        in failure and blocked=true. No path degrades required.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Cause,
        [string]$Criticality = 'optional'
    )
    try {
        $crit = Get-AiMemoryRemoteCriticality -Criticality $Criticality
        $cause = ([string]$Cause).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($cause)) { $cause = 'AIMEMORY_ERROR' }
        if ($crit -ceq 'required') {
            return [PSCustomObject]@{
                status = 'AIMEMORY_REQUIRED_BLOCKED'; ok = $false; failure = $cause
                fallback_continue = $false; blocked = $true
            }
        }
        return [PSCustomObject]@{
            status = 'AIMEMORY_UNAVAILABLE'; ok = $true; failure = $cause
            fallback_continue = $true; blocked = $false
        }
    }
    catch {
        return [PSCustomObject]@{
            status = 'AIMEMORY_REQUIRED_BLOCKED'; ok = $false; failure = 'AIMEMORY_ERROR'
            fallback_continue = $false; blocked = $true
        }
    }
}

function New-AiMemoryRemoteResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [bool]$Ok = $false,
        [string]$Failure = '',
        [string]$Operation = '',
        [string]$Criticality = 'optional',
        [string]$EndpointHost = '',
        [string]$EndpointPortLen = 'len:0',
        [bool]$ScopePresent = $false,
        [string]$ScopeHash = '',
        [string]$TurnHash16 = '',
        [bool]$Consulted = $false,
        [bool]$FallbackContinue = $false,
        [bool]$Blocked = $false,
        [string]$Circuit = 'CLOSED',
        [int]$Consecutive = 0,
        [int]$BudgetS = 0,
        [int]$ElapsedMs = 0,
        $Output = $null
    )
    try {
        return [PSCustomObject]@{
            ok = [bool]$Ok; status = $Status; error = $Status; failure = ([string]$Failure)
            operation = ([string]$Operation); criticality = (Get-AiMemoryRemoteCriticality -Criticality $Criticality)
            endpoint_host = ([string]$EndpointHost); endpoint_port_len = ([string]$EndpointPortLen)
            scope_present = [bool]$ScopePresent; scope_hash = ([string]$ScopeHash); turn_hash16 = ([string]$TurnHash16)
            consulted = [bool]$Consulted
            fallback_continue = [bool]$FallbackContinue; blocked = [bool]$Blocked
            circuit = ([string]$Circuit); consecutive = [int]$Consecutive
            budget_s = [int]$BudgetS; elapsed_ms = [int]$ElapsedMs; output = $Output
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'AIMEMORY_REQUIRED_BLOCKED'; error = 'AIMEMORY_REQUIRED_BLOCKED'; failure = 'AIMEMORY_ERROR'
            operation = ''; criticality = 'required'
            endpoint_host = ''; endpoint_port_len = 'len:0'
            scope_present = $false; scope_hash = ''; turn_hash16 = ''
            consulted = $false; fallback_continue = $false; blocked = $true
            circuit = 'CLOSED'; consecutive = 0; budget_s = 0; elapsed_ms = 0; output = $null
        }
    }
}

# ---------- sanitized evidence ----------

function Get-AiMemoryRemoteFieldRedaction {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = ([string]$Value)
        try {
            if ((Get-Command Get-McpSafetyFieldRedaction -ErrorAction SilentlyContinue) -ne $null) {
                $s = (Get-McpSafetyFieldRedaction -Value $s)
            }
        }
        catch { }
        $s = $s -replace '(?i)AIMEMORY_REMOTE_TOKEN\s*[=:\s]+[^\s|]+', 'AIMEMORY_REMOTE_TOKEN <redacted>'
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
        try {
            $bare = ''
            try { $bare = ([string]$env:AIMEMORY_REMOTE_TOKEN) } catch { $bare = '' }
            if ((-not [string]::IsNullOrEmpty($bare)) -and ($bare.Length -ge 4) -and ($s.Contains($bare))) {
                $s = $s.Replace($bare, '<redacted>')
            }
        }
        catch { }
        return $s
    }
    catch { return '[REDACTED]' }
}

function Get-AiMemoryRemoteScopeHash {
    <#
    .SYNOPSIS
        Canonical sha256 over the len:value-framed sanitized
        workspace|project pair. Only the hex digest is kept; raw
        scope names never enter telemetry. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Workspace, [string]$Project)
    try {
        $w = Get-AiMemoryRemoteFieldRedaction -Value (([string]$Workspace).Trim().ToLowerInvariant())
        if ($w.Length -gt 64) { $w = $w.Substring(0, 64) }
        $p = Get-AiMemoryRemoteFieldRedaction -Value (([string]$Project).Trim().ToLowerInvariant())
        if ($p.Length -gt 64) { $p = $p.Substring(0, 64) }
        $joined = ([string]$w.Length) + ':' + $w + '|' + ([string]$p.Length) + ':' + $p
        $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
    }
    catch { return '' }
}

function Get-AiMemoryRemoteTurnHash16 {
    [CmdletBinding()]
    param([string]$TurnId)
    try {
        $tb = [Text.Encoding]::UTF8.GetBytes(([string]$TurnId).Trim())
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $dg = $sha.ComputeHash($tb) }
        finally { try { $sha.Dispose() } catch { } }
        return (((($dg | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant()).Substring(0, 16))
    }
    catch { return 'unavailable' }
}

function Get-AiMemoryRemoteEvidenceFile {
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot)
    try {
        $dir = $TelemetryRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $repo = Get-AiMemoryRemoteRepoRoot -RepoRoot $RepoRoot
            $dir = Join-Path $repo 'cache\v3\ai-memory-remote'
        }
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $dir ('ai-memory-remote-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-AiMemoryRemoteEvidence {
    <#
    .SYNOPSIS
        Appends one sanitized evidence record to the daily
        ai-memory-remote JSONL. Pre-size accounting with a
        rotation cap, fail-closed under a gate acquired with a
        BOUNDED TryEnter (shared TelemetryGate when the McpSafety
        cell is loaded, else a session lock): under contention
        the event is SKIPPED with an honest lock-busy code and
        the caller path never blocks. The endpoint URL is never
        persisted whole (host plus len:port only); scope travels
        as hash plus presence; the turn travels as hash16.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$EndpointHost = '',
        [string]$EndpointPortLen = 'len:0',
        [string]$Workspace = '',
        [string]$Project = '',
        [bool]$ScopePresent = $false,
        [string]$TurnId = '',
        [string]$Criticality = '',
        [string]$Failure = '',
        [int]$BudgetS = 0,
        [int]$ElapsedMs = 0,
        [int]$Consecutive = 0,
        [string]$Circuit = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = ''
    )
    try {
        $allowed = @('AIMEMORY_OK', 'AIMEMORY_HEALTH_OK', 'AIMEMORY_UNAVAILABLE', 'AIMEMORY_REQUIRED_BLOCKED', 'AIMEMORY_POLICY_INVALID', 'AIMEMORY_SCOPE_INVALID', 'INVALID_TURN_ID', 'INVALID_OPERATION', 'INVALID_PROBE')
        $ev = ([string]$EventName).Trim().ToUpperInvariant()
        if ($allowed -cnotcontains $ev) {
            return [PSCustomObject]@{ ok = $false; skipped = 'bad-event' }
        }
        $op = ([string]$Operation).Trim().ToLowerInvariant()
        if (@('recall', 'health') -cnotcontains $op) {
            return [PSCustomObject]@{ ok = $false; skipped = 'bad-operation' }
        }
        $hostSan = Get-AiMemoryRemoteFieldRedaction -Value ([string]$EndpointHost)
        if ([string]::IsNullOrWhiteSpace($hostSan)) { $hostSan = 'unconfigured' }
        if ($hostSan.Length -gt 64) { $hostSan = $hostSan.Substring(0, 64) }
        $plen = ([string]$EndpointPortLen).Trim()
        if ($plen -cnotmatch '^len:[0-9]{1,6}$') { $plen = 'len:0' }
        $crit = ([string]$Criticality).Trim().ToLowerInvariant()
        if (@('optional', 'required', '') -cnotcontains $crit) { $crit = '' }
        $fail = Get-AiMemoryRemoteFieldRedaction -Value ([string]$Failure)
        if ($fail.Length -gt 64) { $fail = $fail.Substring(0, 64) }
        $cir = ([string]$Circuit).Trim().ToUpperInvariant()
        if (@('CLOSED', 'OPEN', 'HALF_OPEN', '') -cnotcontains $cir) { $cir = '' }
        $doc = [ordered]@{
            ts                = ([DateTimeOffset]::UtcNow.ToString('o'))
            source            = 'ai-memory-remote'
            event             = $ev
            operation         = $op
            endpoint_host     = $hostSan
            endpoint_port_len = $plen
            scope_hash        = (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project)
            scope_present     = [bool]$ScopePresent
            turn_hash16       = (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId)
            criticality       = $crit
            failure           = $fail
            budget_s          = [int]$BudgetS
            elapsed_ms        = [int]$ElapsedMs
            consecutive       = [int]$Consecutive
            circuit           = $cir
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        $target = Get-AiMemoryRemoteEvidenceFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($target)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $gate = $script:AiMemoryRemoteTelemetryLock
        try {
            if ((Get-Command Get-McpSafetySharedGate -ErrorAction SilentlyContinue) -ne $null) {
                $shared = Get-McpSafetySharedGate -Name 'TelemetryGate'
                if ($null -ne $shared) { $gate = $shared }
            }
        }
        catch { }
        $waitMs = 250
        try { $waitMs = [int]$script:AiMemoryRemoteTelemetryLockWaitMs } catch { $waitMs = 250 }
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
                if (($currentLen + [long]$eventBytes) -gt [long]$script:AiMemoryRemoteTelemetryCapBytes) {
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

function Clear-AiMemoryRemoteState {
    <#
    .SYNOPSIS
        Resets AI Memory remote session seams (circuit state
        lives in the reused McpSafety cell: use
        Clear-McpSafetyState for that). Never throws.
    #>
    [CmdletBinding()]
    param()
    try { $script:AiMemoryRemoteTelemetryLockWaitMs = 250 } catch { }
}

# ---------- probe outcome classification ----------

function Get-AiMemoryRemoteProbeOutcome {
    <#
    .SYNOPSIS
        Reads the synthetic probe contract outcome from an
        envelope success output: a dictionary/PSObject carrying
        aimem_outcome (ok | dns-failure | auth-failure |
        server-5xx), or a plain string outcome. Anything else
        means AIMEMORY_PROBE_ERROR. Never throws. Never logs
        credential-adjacent content beyond a truncated redacted
        summary owned by the caller.
    #>
    [CmdletBinding()]
    param($Output)
    try {
        if ($null -eq $Output) { return 'AIMEMORY_PROBE_ERROR' }
        if ($Output -is [string]) {
            $s = ([string]$Output).Trim().ToLowerInvariant()
            if ($s -ceq 'ok') { return 'ok' }
            if ($s -ceq 'dns-failure') { return 'dns-failure' }
            if ($s -ceq 'auth-failure') { return 'auth-failure' }
            if ($s -ceq 'server-5xx') { return 'server-5xx' }
            return 'AIMEMORY_PROBE_ERROR'
        }
        $raw = $null
        if ($Output -is [System.Collections.IDictionary]) {
            if ($Output.Contains('aimem_outcome')) { $raw = $Output['aimem_outcome'] }
        }
        else {
            $pp = $Output.PSObject.Properties | Where-Object { $_.Name -ceq 'aimem_outcome' } | Select-Object -First 1
            if ($null -ne $pp) { $raw = $pp.Value }
        }
        $s = ([string]$raw).Trim().ToLowerInvariant()
        if ($s -ceq 'ok') { return 'ok' }
        if ($s -ceq 'dns-failure') { return 'dns-failure' }
        if ($s -ceq 'auth-failure') { return 'auth-failure' }
        if ($s -ceq 'server-5xx') { return 'server-5xx' }
        return 'AIMEMORY_PROBE_ERROR'
    }
    catch { return 'AIMEMORY_PROBE_ERROR' }
}

function Get-AiMemoryRemoteProbeData {
    <#
    .SYNOPSIS
        Extracts the redacted data payload from a probe success
        output (truncated, redacted; tokens can never pass).
        Never throws.
    #>
    [CmdletBinding()]
    param($Output)
    try {
        if ($null -eq $Output) { return '' }
        if ($Output -is [string]) {
            $s = Get-AiMemoryRemoteFieldRedaction -Value ([string]$Output)
            if ($s.Length -gt 256) { $s = $s.Substring(0, 256) }
            return $s
        }
        $raw = $null
        if ($Output -is [System.Collections.IDictionary]) {
            if ($Output.Contains('data')) { $raw = $Output['data'] }
        }
        else {
            $pp = $Output.PSObject.Properties | Where-Object { $_.Name -ceq 'data' } | Select-Object -First 1
            if ($null -ne $pp) { $raw = $pp.Value }
        }
        $s = Get-AiMemoryRemoteFieldRedaction -Value ([string]$raw)
        if ($s.Length -gt 256) { $s = $s.Substring(0, 256) }
        return $s
    }
    catch { return '[REDACTED]' }
}

# ---------- bounded remote recall (envelope reuse) ----------

function Invoke-AiMemoryRemoteCall {
    <#
    .SYNOPSIS
        Bounded remote AI Memory recall reusing the Phase 28 MCP
        safety envelope (class memory). Never throws: every
        outcome is a structured result object.
    .DESCRIPTION
        Order: policy gate (fail-closed, blocks every
        criticality), turn/scope gates (workspace plus project
        together), endpoint gate (empty/placeholder means
        AIMEMORY_UNCONFIGURED: optional continues, required
        blocks typed; never a silent local fallback), credential
        gate (name-only env wiring; absent means auth-missing,
        malformed means auth-invalid), then the envelope invoke
        with a caller-supplied self-contained synthetic probe.
        Outcome mapping is central: optional yields
        AIMEMORY_UNAVAILABLE with fallback_continue=true;
        required yields AIMEMORY_REQUIRED_BLOCKED with
        blocked=true in every branch. Evidence is recorded on
        every terminal path. Zero real network.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TurnId,
        [string]$Workspace = '',
        [string]$Project = '',
        [string]$Criticality = 'optional',
        [scriptblock]$Probe = $null,
        [object[]]$ProbeArgs = @(),
        [string]$EndpointUrl = '',
        [string]$PolicyPath = '',
        [string]$McpPolicyPath = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [int]$BudgetSecondsOverride = 0,
        [string]$Token = $null,
        $NowUtc = $null,
        $ConcludedAtUtc = $null
    )
    $crit = Get-AiMemoryRemoteCriticality -Criticality $Criticality
    $sum = [PSCustomObject]@{ host = 'unconfigured'; port_len = 'len:0' }
    $scopeChecked = $false
    try {
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-AiMemoryRemoteDefaultPolicyPath -RepoRoot $RepoRoot }
        $gate = Assert-AiMemoryRemotePolicyJson -Path $pp
        if (-not [bool]$gate.valid) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_POLICY_INVALID' -Operation 'recall' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_POLICY_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_POLICY_INVALID' -Ok $false -Failure 'AIMEMORY_POLICY_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
        }
        if (-not (Test-AiMemoryRemoteTurnId -Value $TurnId)) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'INVALID_TURN_ID' -Operation 'recall' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId '' -Criticality $crit -Failure 'INVALID_TURN_ID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            if ($crit -ceq 'required') {
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'INVALID_TURN_ID' -Operation 'recall' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            return (New-AiMemoryRemoteResult -Status 'INVALID_TURN_ID' -Ok $false -Failure 'INVALID_TURN_ID' -Operation 'recall' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $scope = Test-AiMemoryRemoteScope -Workspace $Workspace -Project $Project
        $scopeChecked = [bool]$scope.scoped
        if (-not [bool]$scope.ok) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_SCOPE_INVALID' -Operation 'recall' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_SCOPE_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            if ($crit -ceq 'required') {
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'AIMEMORY_SCOPE_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_SCOPE_INVALID' -Ok $false -Failure 'AIMEMORY_SCOPE_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $rawUrl = $EndpointUrl
        if ([string]::IsNullOrWhiteSpace($rawUrl)) {
            $slot = Read-AiMemoryRemotePolicy -PolicyPath $pp -RepoRoot $RepoRoot
            try {
                $epNode = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'endpoint'
                $rawUrl = ([string](Get-AiMemoryRemotePolicyNode -Doc $epNode -Name 'url'))
            }
            catch { $rawUrl = '' }
        }
        $cls = Test-AiMemoryRemoteConfiguredUrl -Url ([string]$rawUrl)
        $sum = Get-AiMemoryRemoteEndpointSummary -Url ([string]$rawUrl)
        if (-not [bool]$cls.configured) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_UNCONFIGURED' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_UNCONFIGURED' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_UNCONFIGURED' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if (-not [bool]$cls.valid) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ENDPOINT_INVALID' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_ENDPOINT_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ENDPOINT_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        $tokenBound = $PSBoundParameters.ContainsKey('Token')
        $effToken = Get-AiMemoryRemoteEffectiveToken -Token $Token -TokenBound ([bool]$tokenBound)
        $tk = Test-AiMemoryRemoteToken -Token ([string]$effToken)
        if (-not [bool]$tk.present) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_AUTH_MISSING' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_AUTH_MISSING' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_AUTH_MISSING' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if (-not [bool]$tk.valid) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_AUTH_INVALID' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_AUTH_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_AUTH_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if ((Get-Command Invoke-McpSafetyCall -ErrorAction SilentlyContinue) -eq $null) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ENVELOPE_UNAVAILABLE' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_ENVELOPE_UNAVAILABLE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ENVELOPE_UNAVAILABLE' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if ($null -eq $Probe) {
            if ($crit -ceq 'required') {
                [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_REQUIRED_BLOCKED' -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'INVALID_PROBE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'INVALID_PROBE' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            [void](Write-AiMemoryRemoteEvidence -EventName 'INVALID_PROBE' -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'INVALID_PROBE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'INVALID_PROBE' -Ok $false -Failure 'INVALID_PROBE' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $mcpPath = $McpPolicyPath
        if ([string]::IsNullOrWhiteSpace($mcpPath)) { $mcpPath = Get-AiMemoryRemoteDefaultMcpPolicyPath -RepoRoot $RepoRoot }
        $envResult = Invoke-McpSafetyCall -Server ([string]$script:AiMemoryRemoteServerId) -Capability ([string]$script:AiMemoryRemoteRecallCapability) -TurnId ([string]$TurnId).Trim() -Class 'memory' -Criticality 'optional' -Probe $Probe -ProbeArgs $ProbeArgs -BudgetSecondsOverride ([int]$BudgetSecondsOverride) -PolicyPath $mcpPath -RepoRoot $RepoRoot -TelemetryRoot $TelemetryRoot -NowUtc $NowUtc -ConcludedAtUtc $ConcludedAtUtc
        $budget = 60
        $elapsed = 0
        $cir = 'CLOSED'
        $consec = 0
        try { $budget = [int]$envResult.budget_s } catch { $budget = 60 }
        try { $elapsed = [int]$envResult.elapsed_ms } catch { $elapsed = 0 }
        try { $cir = ([string]$envResult.circuit).Trim().ToUpperInvariant() } catch { $cir = 'CLOSED' }
        try { $consec = [int]$envResult.consecutive } catch { $consec = 0 }
        if (([bool]$envResult.ok) -and ([string]$envResult.status -ceq 'OK')) {
            $outcome = Get-AiMemoryRemoteProbeOutcome -Output $envResult.output
            if ($outcome -ceq 'ok') {
                $data = Get-AiMemoryRemoteProbeData -Output $envResult.output
                [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_OK' -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure '' -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_OK' -Ok $true -Failure '' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue $false -Blocked $false -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed -Output $data)
            }
            $cause = 'AIMEMORY_PROBE_ERROR'
            if ($outcome -ceq 'dns-failure') { $cause = 'AIMEMORY_DNS_FAILURE' }
            elseif ($outcome -ceq 'auth-failure') { $cause = 'AIMEMORY_AUTH_INVALID' }
            elseif ($outcome -ceq 'server-5xx') { $cause = 'AIMEMORY_SERVER_ERROR' }
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause $cause -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure $cause -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure $cause -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked) -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
        }
        $envFailure = ''
        try { $envFailure = ([string]$envResult.failure).Trim().ToUpperInvariant() } catch { $envFailure = '' }
        $envStatus = ''
        try { $envStatus = ([string]$envResult.status).Trim().ToUpperInvariant() } catch { $envStatus = '' }
        if (($envFailure -ceq 'MCP_POLICY_INVALID') -or ($envStatus -ceq 'MCP_POLICY_INVALID')) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_POLICY_INVALID' -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_POLICY_INVALID' -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_POLICY_INVALID' -Ok $false -Failure 'AIMEMORY_POLICY_INVALID' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
        }
        $cause = 'AIMEMORY_NETWORK_ERROR'
        if ($envFailure -ceq 'MCP_TIMEOUT') { $cause = 'AIMEMORY_TIMEOUT' }
        elseif ($envFailure -ceq 'MCP_NETWORK_ERROR') { $cause = 'AIMEMORY_NETWORK_ERROR' }
        elseif ($envFailure -ceq 'MCP_CIRCUIT_OPEN') { $cause = 'AIMEMORY_CIRCUIT_OPEN' }
        elseif ($envFailure -ceq 'MCP_ERROR') { $cause = 'AIMEMORY_PROBE_ERROR' }
        elseif (-not [string]::IsNullOrWhiteSpace($envFailure)) { $cause = ('ENVELOPE_' + $envFailure) }
        elseif (-not [string]::IsNullOrWhiteSpace($envStatus)) { $cause = ('ENVELOPE_' + $envStatus) }
        $o = ConvertTo-AiMemoryRemoteOutcome -Cause $cause -Criticality $crit
        [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'recall' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure $cause -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure $cause -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked) -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
    }
    catch {
        $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ERROR' -Criticality $crit
        return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ERROR' -Operation 'recall' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
    }
}

# ---------- bounded health probe (separate) ----------

function Invoke-AiMemoryRemoteHealth {
    <#
    .SYNOPSIS
        Bounded remote health probe reusing the Phase 28 envelope
        (class memory, connect phase, health budget). Separate
        capability (aimemory.health) so its circuit is
        independent from recall. Same gates and semantics as
        recall; success yields AIMEMORY_HEALTHY. Never throws.
        Zero real network: synthetic seam only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TurnId,
        [string]$Workspace = '',
        [string]$Project = '',
        [string]$Criticality = 'optional',
        [scriptblock]$Probe = $null,
        [object[]]$ProbeArgs = @(),
        [string]$EndpointUrl = '',
        [string]$PolicyPath = '',
        [string]$McpPolicyPath = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [string]$Token = $null,
        $NowUtc = $null,
        $ConcludedAtUtc = $null
    )
    $crit = Get-AiMemoryRemoteCriticality -Criticality $Criticality
    $sum = [PSCustomObject]@{ host = 'unconfigured'; port_len = 'len:0' }
    $scopeChecked = $false
    try {
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-AiMemoryRemoteDefaultPolicyPath -RepoRoot $RepoRoot }
        $gate = Assert-AiMemoryRemotePolicyJson -Path $pp
        if (-not [bool]$gate.valid) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_POLICY_INVALID' -Operation 'health' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_POLICY_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_POLICY_INVALID' -Ok $false -Failure 'AIMEMORY_POLICY_INVALID' -Operation 'health' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
        }
        if (-not (Test-AiMemoryRemoteTurnId -Value $TurnId)) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'INVALID_TURN_ID' -Operation 'health' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId '' -Criticality $crit -Failure 'INVALID_TURN_ID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            if ($crit -ceq 'required') {
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'INVALID_TURN_ID' -Operation 'health' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            return (New-AiMemoryRemoteResult -Status 'INVALID_TURN_ID' -Ok $false -Failure 'INVALID_TURN_ID' -Operation 'health' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $scope = Test-AiMemoryRemoteScope -Workspace $Workspace -Project $Project
        $scopeChecked = [bool]$scope.scoped
        if (-not [bool]$scope.ok) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_SCOPE_INVALID' -Operation 'health' -EndpointHost 'unconfigured' -EndpointPortLen 'len:0' -Workspace $Workspace -Project $Project -ScopePresent $false -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_SCOPE_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            if ($crit -ceq 'required') {
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'AIMEMORY_SCOPE_INVALID' -Operation 'health' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_SCOPE_INVALID' -Ok $false -Failure 'AIMEMORY_SCOPE_INVALID' -Operation 'health' -Criticality $crit -EndpointHost 'unconfigured' -ScopePresent $false -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $rawUrl = $EndpointUrl
        if ([string]::IsNullOrWhiteSpace($rawUrl)) {
            $slot = Read-AiMemoryRemotePolicy -PolicyPath $pp -RepoRoot $RepoRoot
            try {
                $epNode = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'endpoint'
                $rawUrl = ([string](Get-AiMemoryRemotePolicyNode -Doc $epNode -Name 'url'))
            }
            catch { $rawUrl = '' }
        }
        $cls = Test-AiMemoryRemoteConfiguredUrl -Url ([string]$rawUrl)
        $sum = Get-AiMemoryRemoteEndpointSummary -Url ([string]$rawUrl)
        if (-not [bool]$cls.configured) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_UNCONFIGURED' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_UNCONFIGURED' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_UNCONFIGURED' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if (-not [bool]$cls.valid) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ENDPOINT_INVALID' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_ENDPOINT_INVALID' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ENDPOINT_INVALID' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        $tokenBound = $PSBoundParameters.ContainsKey('Token')
        $effToken = Get-AiMemoryRemoteEffectiveToken -Token $Token -TokenBound ([bool]$tokenBound)
        $tk = Test-AiMemoryRemoteToken -Token ([string]$effToken)
        if ((-not [bool]$tk.present) -or (-not [bool]$tk.valid)) {
            $cause = 'AIMEMORY_AUTH_MISSING'
            if ([bool]$tk.present) { $cause = 'AIMEMORY_AUTH_INVALID' }
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause $cause -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure $cause -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure $cause -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if ((Get-Command Invoke-McpSafetyCall -ErrorAction SilentlyContinue) -eq $null) {
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ENVELOPE_UNAVAILABLE' -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_ENVELOPE_UNAVAILABLE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ENVELOPE_UNAVAILABLE' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
        }
        if ($null -eq $Probe) {
            if ($crit -ceq 'required') {
                [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_REQUIRED_BLOCKED' -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'INVALID_PROBE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_REQUIRED_BLOCKED' -Ok $false -Failure 'INVALID_PROBE' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true)
            }
            [void](Write-AiMemoryRemoteEvidence -EventName 'INVALID_PROBE' -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'INVALID_PROBE' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'INVALID_PROBE' -Ok $false -Failure 'INVALID_PROBE' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $true -Blocked $false)
        }
        $mcpPath = $McpPolicyPath
        if ([string]::IsNullOrWhiteSpace($mcpPath)) { $mcpPath = Get-AiMemoryRemoteDefaultMcpPolicyPath -RepoRoot $RepoRoot }
        $healthBudget = 10
        try {
            $pslot = Read-AiMemoryRemotePolicy -PolicyPath $pp -RepoRoot $RepoRoot
            $hb = [int](Get-AiMemoryRemotePolicyNode -Doc $pslot.doc -Name 'health_probe_budget_seconds')
            if (($hb -ge 1) -and ($hb -le 3600)) { $healthBudget = $hb }
        }
        catch { $healthBudget = 10 }
        $connectBudget = 0
        try {
            $cb = Get-McpSafetyClassBudget -Class 'memory' -Phase 'connect' -PolicyPath $mcpPath -RepoRoot $RepoRoot
            if ([bool]$cb.ok) { $connectBudget = [int]$cb.budget_s }
        }
        catch { $connectBudget = 0 }
        $override = 0
        if (($connectBudget -ge 1) -and ($healthBudget -ge 1)) {
            $override = $healthBudget
            if ($override -gt $connectBudget) { $override = $connectBudget }
        }
        $envResult = Invoke-McpSafetyCall -Server ([string]$script:AiMemoryRemoteServerId) -Capability ([string]$script:AiMemoryRemoteHealthCapability) -TurnId ([string]$TurnId).Trim() -Class 'memory' -Phase 'connect' -Criticality 'optional' -Probe $Probe -ProbeArgs $ProbeArgs -BudgetSecondsOverride $override -PolicyPath $mcpPath -RepoRoot $RepoRoot -TelemetryRoot $TelemetryRoot -NowUtc $NowUtc -ConcludedAtUtc $ConcludedAtUtc
        $budget = $healthBudget
        $elapsed = 0
        $cir = 'CLOSED'
        $consec = 0
        try { $budget = [int]$envResult.budget_s } catch { $budget = $healthBudget }
        try { $elapsed = [int]$envResult.elapsed_ms } catch { $elapsed = 0 }
        try { $cir = ([string]$envResult.circuit).Trim().ToUpperInvariant() } catch { $cir = 'CLOSED' }
        try { $consec = [int]$envResult.consecutive } catch { $consec = 0 }
        if (([bool]$envResult.ok) -and ([string]$envResult.status -ceq 'OK')) {
            $outcome = Get-AiMemoryRemoteProbeOutcome -Output $envResult.output
            if ($outcome -ceq 'ok') {
                [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_HEALTH_OK' -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure '' -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                return (New-AiMemoryRemoteResult -Status 'AIMEMORY_HEALTHY' -Ok $true -Failure '' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue $false -Blocked $false -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
            }
            $cause = 'AIMEMORY_PROBE_ERROR'
            if ($outcome -ceq 'dns-failure') { $cause = 'AIMEMORY_DNS_FAILURE' }
            elseif ($outcome -ceq 'auth-failure') { $cause = 'AIMEMORY_AUTH_INVALID' }
            elseif ($outcome -ceq 'server-5xx') { $cause = 'AIMEMORY_SERVER_ERROR' }
            $o = ConvertTo-AiMemoryRemoteOutcome -Cause $cause -Criticality $crit
            [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure $cause -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure $cause -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked) -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
        }
        $envFailure = ''
        try { $envFailure = ([string]$envResult.failure).Trim().ToUpperInvariant() } catch { $envFailure = '' }
        $envStatus = ''
        try { $envStatus = ([string]$envResult.status).Trim().ToUpperInvariant() } catch { $envStatus = '' }
        if (($envFailure -ceq 'MCP_POLICY_INVALID') -or ($envStatus -ceq 'MCP_POLICY_INVALID')) {
            [void](Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_POLICY_INVALID' -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure 'AIMEMORY_POLICY_INVALID' -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-AiMemoryRemoteResult -Status 'AIMEMORY_POLICY_INVALID' -Ok $false -Failure 'AIMEMORY_POLICY_INVALID' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $false -FallbackContinue $false -Blocked $true -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
        }
        $cause = 'AIMEMORY_NETWORK_ERROR'
        if ($envFailure -ceq 'MCP_TIMEOUT') { $cause = 'AIMEMORY_TIMEOUT' }
        elseif ($envFailure -ceq 'MCP_NETWORK_ERROR') { $cause = 'AIMEMORY_NETWORK_ERROR' }
        elseif ($envFailure -ceq 'MCP_CIRCUIT_OPEN') { $cause = 'AIMEMORY_CIRCUIT_OPEN' }
        elseif ($envFailure -ceq 'MCP_ERROR') { $cause = 'AIMEMORY_PROBE_ERROR' }
        elseif (-not [string]::IsNullOrWhiteSpace($envFailure)) { $cause = ('ENVELOPE_' + $envFailure) }
        $o = ConvertTo-AiMemoryRemoteOutcome -Cause $cause -Criticality $crit
        [void](Write-AiMemoryRemoteEvidence -EventName ([string]$o.status) -Operation 'health' -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -Workspace $Workspace -Project $Project -ScopePresent $scopeChecked -TurnId $TurnId -Criticality $crit -Failure $cause -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure $cause -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -ScopeHash (Get-AiMemoryRemoteScopeHash -Workspace $Workspace -Project $Project) -TurnHash16 (Get-AiMemoryRemoteTurnHash16 -TurnId $TurnId) -Consulted $true -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked) -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
    }
    catch {
        $o = ConvertTo-AiMemoryRemoteOutcome -Cause 'AIMEMORY_ERROR' -Criticality $crit
        return (New-AiMemoryRemoteResult -Status ([string]$o.status) -Ok ([bool]$o.ok) -Failure 'AIMEMORY_ERROR' -Operation 'health' -Criticality $crit -EndpointHost ([string]$sum.host) -EndpointPortLen ([string]$sum.port_len) -ScopePresent $scopeChecked -Consulted $false -FallbackContinue ([bool]$o.fallback_continue) -Blocked ([bool]$o.blocked))
    }
}
