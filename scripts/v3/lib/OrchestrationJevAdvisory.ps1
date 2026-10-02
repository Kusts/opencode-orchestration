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
        name:JEV_API_KEY} carrying the variable NAME only, never
        a value, and advisory-only authority with an explicit
        cannot list. A missing or divergent policy fails closed
        with JEV_POLICY_INVALID: this file never falls back to
        silent defaults and never proceeds on a drifted catalog.
      - Bounded invoke REUSES the Phase 28 envelope
        (OrchestrationMcpSafety.ps1, class advisory): this lib
        orchestrates (Jev policy check, trigger check, flag check,
        credential check, envelope invoke, advisory mapping) and
        creates no parallel timeout/circuit primitives. The probe
        is a caller-supplied self-contained scriptblock (synthetic
        seam in tests, zero real network). Real transport
        activation is HOLD.
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
        {type:env, name:JEV_API_KEY} (name only), advisory-only
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
        network: the probe is a caller-supplied self-contained
        scriptblock (synthetic seam in tests).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$TurnId,
        $Descriptor = $null,
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
            [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary 'probe-missing-deterministic-fallback' -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'INVALID_PROBE' -Tool $tool -TriggerReason $reason -Consulted $false -FallbackContinue $true -Blocked $false -Mode 'active')
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
            $summary = ''
            try { $summary = ([string]$envResult.output) } catch { $summary = '' }
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
        [void](Write-JevAdvisoryEvidence -EventName 'JEV_UNAVAILABLE' -Tool $tool -TriggerReason $reason -Descriptor $Descriptor -OutputSummary ('envelope-cause:' + $cause) -BudgetS $budget -ElapsedMs $elapsed -Consecutive $consec -Circuit $cir -Mode 'active' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure $cause -Tool $tool -TriggerReason $reason -Consulted $true -FallbackContinue $true -Blocked $false -Mode 'active' -Circuit $cir -Consecutive $consec -BudgetS $budget -ElapsedMs $elapsed)
    }
    catch {
        return (New-JevAdvisoryResult -Status 'JEV_UNAVAILABLE' -Ok $true -Failure 'JEV_UNAVAILABLE' -Tool ([string]$Tool) -Consulted $false -FallbackContinue $true -Blocked $false)
    }
}
