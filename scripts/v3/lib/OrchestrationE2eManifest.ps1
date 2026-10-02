<#
.SYNOPSIS
    Phase 42 slice 1: manifest + harness for the 40 end-to-end scenarios and the
    19-step rollout checklist declared in the plan addendum section 19.
.DESCRIPTION
    Two separate claims, never merged:

      1. The MANIFEST classifies all 40 scenarios honestly as
         runnable-synthetic | requires-operator-runtime |
         requires-flag-activation | requires-real-transport.
      2. The HARNESS executes the runnable-synthetic subset with REAL checks
         against the delivered libraries using synthetic inputs on this host.
         A passing scenario reports pass-synthetic. A failing one reports
         failed-synthetic and is never a pass. Every blocked scenario stays
         blocked with the reason it is blocked.

    This harness does NOT close the release gate. The real V2 Windows lane,
    every capability flag activation and every real transport remain
    operator-owned and are reported as blocked. A synthetic pass proves one
    library invariant offline; it is never evidence for the V2 lane.

    Zero network. No process is ever started or killed by this harness; the
    watchdog check only proves a refusal path for an absent PID.
    Writes are confined to a caller-supplied work root (default: a fresh
    directory under the user temp) which is removed in a finally block.
    Output is sanitized, bounded and deterministic: the caller supplies
    TimestampUtc as a validated ISO-8601 VALUE. No public API takes a
    scriptblock callback, and no check reports a wall-clock value of its
    own. An unparseable TimestampUtc is never echoed and never coerced into
    a stamp: the harness falls back to its OWN internal UTC instant, sets
    timestamp_valid = $false and adds an explicit hold note, so the invalid
    input stays visible without ever becoming a claimed value.
    PowerShell 5.1 compatible; ASCII-only.
#>
[CmdletBinding()]
param()

function Get-E2eManifestRepoRoot {
    [CmdletBinding()] param()
    try {
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    } catch { return '' }
}

function Get-E2eSafeText {
    [CmdletBinding()] param($Value, [int]$Max = 160)
    try {
        if ($null -eq $Value) { return '' }
        $v = [string]$Value
        $v = $v -replace '(?i)sk-[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace '(?i)(token|secret|password|key)\s*[=:]\s*[^\s,;]+', '$1=[REDACTED]'
        $v = $v -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b', '[REDACTED-HOST]'
        $v = $v -replace '[\x00-\x1f]', ' '
        $v = $v.Trim()
        if ($v.Length -gt $Max) { $v = $v.Substring(0, $Max) }
        return $v
    } catch { return '' }
}

function Get-E2eManifestValue {
    [CmdletBinding()] param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    } catch { return $Default }
}

function Resolve-E2eTimestampUtc {
    <#
    .SYNOPSIS
        Validates a caller-supplied ISO-8601 instant into a UTC value.
    .DESCRIPTION
        A VALUE seam, not a callback: there is no scriptblock parameter on any
        public API. Returns { stamp = [DateTime]; valid = [bool] }.

        An empty or omitted value resolves to the current UTC instant with
        valid = $true, because no caller claim was involved. A parseable value
        resolves to its own UTC instant with valid = $true. An UNPARSEABLE value
        is never echoed and never coerced: the harness substitutes its own
        internal UTC instant with valid = $false, and the caller reports that
        with timestamp_valid = $false plus an explicit hold note. Same
        DateTimeOffset.TryParse contract as the other libraries.
    #>
    [CmdletBinding()] param([string]$TimestampUtc = '')
    try {
        if ([string]::IsNullOrWhiteSpace($TimestampUtc)) {
            return [pscustomobject]@{ stamp = [DateTime]::UtcNow; valid = $true }
        }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($TimestampUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return [pscustomobject]@{ stamp = [DateTime]::UtcNow; valid = $false }
        }
        return [pscustomobject]@{ stamp = $parsed.UtcDateTime; valid = $true }
    } catch {
        return [pscustomobject]@{ stamp = [DateTime]::UtcNow; valid = $false }
    }
}

function Get-E2eArtifactState {
    <#
    .SYNOPSIS
        Classifies one repository-relative artifact as absent | unparseable | present.
    .DESCRIPTION
        Existence alone is never proof: a JSON proof or evidence record counts
        only when it parses. The three states stay distinguishable so a caller
        can state an honest reason instead of collapsing every defect into one
        generic 'missing'. Never throws.
    #>
    [CmdletBinding()] param([string]$RepoRoot, [string]$RelativePath)
    try {
        if ([string]::IsNullOrWhiteSpace($RelativePath)) { return [pscustomobject]@{ state = 'absent'; present = $false; doc = $null } }
        $full = Join-Path $RepoRoot $RelativePath
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return [pscustomobject]@{ state = 'absent'; present = $false; doc = $null } }
        $doc = $null
        try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($full))) } catch { return [pscustomobject]@{ state = 'unparseable'; present = $false; doc = $null } }
        if ($null -eq $doc) { return [pscustomobject]@{ state = 'unparseable'; present = $false; doc = $null } }
        return [pscustomobject]@{ state = 'present'; present = $true; doc = $doc }
    } catch { return [pscustomobject]@{ state = 'unparseable'; present = $false; doc = $null } }
}

# Closed vocabularies. A value outside a closed set is a manifest defect and
# fails the whole manifest closed rather than being coerced into a class.
$script:E2eClassifications = @('runnable-synthetic', 'requires-operator-runtime', 'requires-flag-activation', 'requires-real-transport')
$script:E2eBlockedStatus = @{
    'requires-operator-runtime' = 'blocked-requires-operator'
    'requires-flag-activation'  = 'blocked-requires-flag'
    'requires-real-transport'   = 'blocked-requires-transport'
}
$script:E2eLibMap = @{
    'mcp-healthy'                = 'OrchestrationMcpSafety.ps1'
    'mcp-circuit'                = 'OrchestrationMcpSafety.ps1'
    'level-l0'                   = 'OrchestrationValidationPolicy.ps1'
    'level-l1'                   = 'OrchestrationValidationPolicy.ps1'
    'level-l2'                   = 'OrchestrationValidationPolicy.ps1'
    'level-l3'                   = 'OrchestrationValidationPolicy.ps1'
    'evidence-reuse'             = 'OrchestrationEvidenceStore.ps1'
    'reviewer-bundle'            = 'OrchestrationValidationPolicy.ps1'
    'no-bonus-work'              = 'OrchestrationSimplicityPolicy.ps1'
    'change-budget'              = 'OrchestrationSimplicityPolicy.ps1'
    'budget-fanout'              = 'OrchestrationPlannerLoop.ps1'
    'capability-fallback'        = 'OrchestrationCapabilityDoctor.ps1'
    'capability-windows-unsupported' = 'OrchestrationCapabilityDoctor.ps1'
    'no-widen-grants'            = 'OrchestrationTaskKernel.ps1'
    'jev-cannot-grant'           = 'OrchestrationJevAdvisory.ps1'
    'no-subdelegation'           = 'OrchestrationPreflight.ps1'
    'v2-native-no-evidence'      = 'OrchestrationV2NativeGating.ps1'
    'watchdog-unknown-pid'       = 'OrchestrationRuntimeWatchdog.ps1'
}

function Test-E2eFunctionAvailable {
    [CmdletBinding()] param([string]$Name, [string]$LibName)
    try {
        if (-not [string]::IsNullOrWhiteSpace($LibName) -and $script:E2eMissingLibs -contains $LibName) {
            return [pscustomobject]@{ available = $false; reason = ('library-absent:' + $LibName) }
        }
        $cmd = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return [pscustomobject]@{ available = $false; reason = ('function-absent:' + $Name) }
        }
        return [pscustomobject]@{ available = $true; reason = '' }
    } catch {
        return [pscustomobject]@{ available = $false; reason = ('function-absent:' + (Get-E2eSafeText $Name 80)) }
    }
}

function Get-OrchestrationE2eManifest {
    <#
    .SYNOPSIS
        Loads and structurally validates the 41-scenario / 19-step manifest.
    .DESCRIPTION
        Fail-closed. Returns status 'ok' only when the file parses, every
        scenario carries the required fields, the 41 ordinals are contiguous
        from 1 (the plan's 40 scenarios keep ordinals 1..40; ordinal 41 is the
        harness addendum that keeps the synthetic V2 gating invariant covered),
        every classification is in the closed set, every runnable-synthetic
        scenario names a known check, ids are unique and the rollout order is
        exactly 19 contiguous steps. Any defect returns status 'invalid' with
        the first reason and no scenarios, so a damaged manifest can never be
        reported as a set of verified scenarios.
    #>
    [CmdletBinding()]
    param([string]$ManifestPath = '', [string]$RepoRoot = '')
    try {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-E2eManifestRepoRoot }
        if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $RepoRoot 'source/registry/e2e-scenarios.json' }
        $empty = [pscustomobject]@{ status = 'invalid'; reason = ''; record = $null; scenarios = @(); rollout_steps = @() }
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
            return [pscustomobject]@{ status = 'invalid'; reason = 'manifest-absent'; record = $null; scenarios = @(); rollout_steps = @() }
        }
        $doc = $null
        try { $doc = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($ManifestPath))) } catch {
            return [pscustomobject]@{ status = 'invalid'; reason = 'manifest-unreadable'; record = $null; scenarios = @(); rollout_steps = @() }
        }
        if ($null -eq $doc) {
            return [pscustomobject]@{ status = 'invalid'; reason = 'manifest-unreadable'; record = $null; scenarios = @(); rollout_steps = @() }
        }
        $scenarios = @()
        try {
            if ($doc.scenarios -isnot [System.Collections.IEnumerable] -or $doc.scenarios -is [string]) { throw 'scenarios-not-an-array' }
            $scenarios = @($doc.scenarios)
        } catch {
            return [pscustomobject]@{ status = 'invalid'; reason = 'scenarios-not-an-array'; record = $null; scenarios = @(); rollout_steps = @() }
        }
        if ($scenarios.Count -ne 41) {
            return [pscustomobject]@{ status = 'invalid'; reason = ('scenario-count:' + $scenarios.Count); record = $null; scenarios = @(); rollout_steps = @() }
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $norm = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $scenarios.Count; $i++) {
            $s = $scenarios[$i]
            $id = Get-E2eSafeText (Get-E2eManifestValue $s 'scenario_id' '') 40
            $ordinal = Get-E2eManifestValue $s 'ordinal' (-1)
            $class = [string](Get-E2eManifestValue $s 'classification' '')
            $check = [string](Get-E2eManifestValue $s 'check' '')
            if (-not $id) { return [pscustomobject]@{ status = 'invalid'; reason = ('scenario-missing-id:' + $i); record = $null; scenarios = @(); rollout_steps = @() } }
            if (-not $seen.Add($id)) { return [pscustomobject]@{ status = 'invalid'; reason = ('duplicate-scenario-id:' + $id); record = $null; scenarios = @(); rollout_steps = @() } }
            if ([int]$ordinal -ne ($i + 1)) { return [pscustomobject]@{ status = 'invalid'; reason = ('scenario-ordinal-gap:' + $id); record = $null; scenarios = @(); rollout_steps = @() } }
            if ($class -notin $script:E2eClassifications) { return [pscustomobject]@{ status = 'invalid'; reason = ('unknown-classification:' + $id); record = $null; scenarios = @(); rollout_steps = @() } }
            if ($class -eq 'runnable-synthetic') {
                if (-not $check) { return [pscustomobject]@{ status = 'invalid'; reason = ('runnable-without-check:' + $id); record = $null; scenarios = @(); rollout_steps = @() } }
                if (-not $script:E2eLibMap.ContainsKey($check)) { return [pscustomobject]@{ status = 'invalid'; reason = ('unknown-check:' + $id); record = $null; scenarios = @(); rollout_steps = @() } }
            } elseif ($check) {
                return [pscustomobject]@{ status = 'invalid'; reason = ('blocked-with-check:' + $id); record = $null; scenarios = @(); rollout_steps = @() }
            }
            [void]$norm.Add([pscustomobject]@{
                    scenario_id        = $id
                    ordinal            = [int]$ordinal
                    category           = Get-E2eSafeText (Get-E2eManifestValue $s 'category' '') 40
                    description        = Get-E2eSafeText (Get-E2eManifestValue $s 'description' '') 160
                    classification     = $class
                    check              = $check
                    mapped_component   = Get-E2eSafeText (Get-E2eManifestValue $s 'mapped_component' '') 240
                    required_activation = Get-E2eSafeText (Get-E2eManifestValue $s 'required_activation' '') 300
                    evidence_ref       = Get-E2eSafeText (Get-E2eManifestValue $s 'evidence_ref' '') 240
                })
        }
        $steps = @()
        try { if ($doc.rollout_steps -is [System.Collections.IEnumerable] -and $doc.rollout_steps -isnot [string]) { $steps = @($doc.rollout_steps) } } catch { $steps = @() }
        if ($steps.Count -ne 19) {
            return [pscustomobject]@{ status = 'invalid'; reason = ('rollout-count:' + $steps.Count); record = $null; scenarios = @(); rollout_steps = @() }
        }
        $normSteps = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $st = $steps[$i]
            if ([int](Get-E2eManifestValue $st 'step' (-1)) -ne ($i + 1)) {
                return [pscustomobject]@{ status = 'invalid'; reason = ('rollout-step-gap:' + $i); record = $null; scenarios = @(); rollout_steps = @() }
            }
            if (-not (Get-E2eManifestValue $st 'lib' '')) {
                return [pscustomobject]@{ status = 'invalid'; reason = ('rollout-step-missing-lib:' + $i); record = $null; scenarios = @(); rollout_steps = @() }
            }
            if (-not (Get-E2eManifestValue $st 'proof' '')) {
                return [pscustomobject]@{ status = 'invalid'; reason = ('rollout-step-missing-proof:' + $i); record = $null; scenarios = @(); rollout_steps = @() }
            }
            [void]$normSteps.Add([pscustomobject]@{
                    step              = ($i + 1)
                    name              = Get-E2eSafeText (Get-E2eManifestValue $st 'name' '') 80
                    lib               = Get-E2eSafeText (Get-E2eManifestValue $st 'lib' '') 240
                    evidence          = Get-E2eSafeText (Get-E2eManifestValue $st 'evidence' '') 240
                    proof             = Get-E2eSafeText (Get-E2eManifestValue $st 'proof' '') 240
                    flag              = Get-E2eSafeText (Get-E2eManifestValue $st 'flag' '') 64
                    shadow_flag       = Get-E2eSafeText (Get-E2eManifestValue $st 'shadow_flag' '') 64
                    shadow_sufficient = [bool](Get-E2eManifestValue $st 'shadow_sufficient' $false)
                    note              = Get-E2eSafeText (Get-E2eManifestValue $st 'note' '') 300
                })
        }
        return [pscustomobject]@{ status = 'ok'; reason = ''; record = $doc; scenarios = @($norm.ToArray()); rollout_steps = @($normSteps.ToArray()) }
    } catch {
        return [pscustomobject]@{ status = 'invalid'; reason = 'manifest-parse-failed'; record = $null; scenarios = @(); rollout_steps = @() }
    }
}

function Get-E2eFlagState {
    <#
    .SYNOPSIS
        Resolves a dotted capability-flag path to its activation boolean.
    .DESCRIPTION
        Returns the activation leaf of a flag object (.enabled, then .active,
        else the boolean itself). A leaf counts ONLY when it is EXACTLY of type
        [bool]. A string, a number, $null or an object is NEVER coerced: in
        PowerShell [bool]'false' is $true and [bool]@{} is $true, so coercion
        would promote a disabled or unreadable flag to shipped.

        Any other declared leaf type resolves to $null and is NOT skipped in
        favour of a later leaf, so a malformed 'enabled' can never be masked by a
        well-formed 'active'. A node with no activation leaf at all, and a path
        that does not exist, resolve to $null as well.

        $null is the unknown state: callers must never read it as OFF, and the
        checklist reports it as blocked-evidence with reason
        'flag-state-unresolvable'.
    #>
    [CmdletBinding()] param($Flags, [string]$Path)
    try {
        if ($null -eq $Flags -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
        $node = $Flags
        foreach ($part in ($Path -split '\.')) {
            if ($null -eq $node) { return $null }
            if ($node -is [System.Collections.IDictionary]) {
                if (-not $node.Contains($part)) { return $null }
                $node = $node[$part]
            } else {
                $p = $node.PSObject.Properties[$part]
                if ($null -eq $p) { return $null }
                $node = $p.Value
            }
        }
        if ($node -is [bool]) { return [bool]$node }
        $ep = $node.PSObject.Properties['enabled']
        if ($null -ne $ep) { if ($ep.Value -is [bool]) { return [bool]$ep.Value } else { return $null } }
        $ap = $node.PSObject.Properties['active']
        if ($null -ne $ap) { if ($ap.Value -is [bool]) { return [bool]$ap.Value } else { return $null } }
        return $null
    } catch { return $null }
}

function Get-E2eShadowState {
    <#
    .SYNOPSIS
        Resolves a dotted capability-flag path to its shadow boolean.
    .DESCRIPTION
        Same strict contract as Get-E2eFlagState: the node itself when it is a
        real boolean, else its 'shadow' leaf, and that leaf counts ONLY when it
        is EXACTLY of type [bool]. A string, a number, $null or an object
        resolves to $null and is never coerced, so a shadow leg can only ever be
        reported as ON from a genuine boolean.
    #>
    [CmdletBinding()] param($Flags, [string]$Path)
    try {
        if ($null -eq $Flags -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
        $node = $Flags
        foreach ($part in ($Path -split '\.')) {
            if ($null -eq $node) { return $null }
            if ($node -is [System.Collections.IDictionary]) {
                if (-not $node.Contains($part)) { return $null }
                $node = $node[$part]
            } else {
                $p = $node.PSObject.Properties[$part]
                if ($null -eq $p) { return $null }
                $node = $p.Value
            }
        }
        if ($node -is [bool]) { return [bool]$node }
        $sp = $node.PSObject.Properties['shadow']
        if ($null -ne $sp) { if ($sp.Value -is [bool]) { return [bool]$sp.Value } else { return $null } }
        return $null
    } catch { return $null }
}

function Test-E2eFlagPath {
    <#
    .SYNOPSIS
        Reports whether a dotted flag path resolves to a NODE in the registry.
    .DESCRIPTION
        Separates "the policy does not declare this flag" from "the policy
        declares it but its state cannot be resolved to a boolean". The first is
        an honest activation gap; the second is an unknown resolution that must
        never be read as OFF, let alone as shipped.
    #>
    [CmdletBinding()] param($Flags, [string]$Path)
    try {
        if ($null -eq $Flags -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
        $node = $Flags
        foreach ($part in ($Path -split '\.')) {
            if ($null -eq $node) { return $false }
            if ($node -is [System.Collections.IDictionary]) {
                if (-not $node.Contains($part)) { return $false }
                $node = $node[$part]
            } else {
                $p = $node.PSObject.Properties[$part]
                if ($null -eq $p) { return $false }
                $node = $p.Value
            }
        }
        return ($null -ne $node)
    } catch { return $false }
}

# ---------- real checks ----------
# Each returns { ok = bool; detail = bounded sanitized string }. A check that
# cannot run returns ok=$false with a reason; it never returns a soft pass.

function Invoke-E2eCheckMcpHealthy {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Invoke-McpSafetyCall' -LibName 'mcp-healthy'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $r = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.check' -TurnId $C.McpHealthyTurn -Class 'advisory' `
            -Criticality 'optional' -Probe { 'synthetic-healthy' } -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if (-not [bool]$r.ok) { return (New-E2eCheckResult $false ('refused:' + (Get-E2eSafeText $r.status 40))) }
        if ([string]$r.status -ne 'OK') { return (New-E2eCheckResult $false ('status:' + (Get-E2eSafeText $r.status 40))) }
        if ([bool]$r.fallback_continue) { return (New-E2eCheckResult $false 'optional-call-degraded') }
        if ([string]$r.circuit -ne 'CLOSED') { return (New-E2eCheckResult $false ('circuit:' + (Get-E2eSafeText $r.circuit 16))) }
        return (New-E2eCheckResult $true 'synthetic probe OK inside bounded envelope')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckMcpCircuit {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Invoke-McpSafetyCall' -LibName 'mcp-circuit'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $marker = Join-Path $C.Work 'mcp-probe-ran.marker'
        # 'mcp_sim_network' and 'mcp_sim_timeout' are closed classifier tokens:
        # the two throws are classified network and timeout respectively, never
        # each other, so a timeout proves the timeout leg and still counts
        # toward the per-turn failure streak.
        $probe = [scriptblock]::Create('param($p) if($p){[IO.File]::WriteAllText($p,''ran'')}; throw ''mcp_sim_network''')
        $timeoutProbe = [scriptblock]::Create('param($p) if($p){[IO.File]::WriteAllText($p,''ran'')}; throw ''mcp_sim_timeout''')

        # Timeout leg, on its own turn: the first timeout must be classified
        # timeout (not network, not other), degrade an optional call and leave
        # the circuit closed.
        $t1 = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpTimeoutTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $timeoutProbe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if ([string]$t1.failure_class -ne 'timeout') { return (New-E2eCheckResult $false ('timeout-failure-class:' + (Get-E2eSafeText $t1.failure_class 24))) }
        if ([string]$t1.failure -ne 'MCP_TIMEOUT') { return (New-E2eCheckResult $false ('timeout-failure:' + (Get-E2eSafeText $t1.failure 24))) }
        if ([string]$t1.status -ne 'MCP_UNAVAILABLE' -or -not [bool]$t1.fallback_continue) {
            return (New-E2eCheckResult $false ('timeout-degradation:' + (Get-E2eSafeText $t1.status 24)))
        }
        if ([string]$t1.circuit -ne 'CLOSED') { return (New-E2eCheckResult $false ('timeout-first-circuit:' + (Get-E2eSafeText $t1.circuit 16))) }
        if (-not (Test-Path -LiteralPath $marker)) { return (New-E2eCheckResult $false 'timeout-probe-never-ran') }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

        # Second timeout in the same turn: the streak opens the circuit, so a
        # timeout is a circuit input and not a soft no-op.
        $t2 = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpTimeoutTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $timeoutProbe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if ([string]$t2.failure_class -ne 'timeout') { return (New-E2eCheckResult $false ('timeout-second-class:' + (Get-E2eSafeText $t2.failure_class 24))) }
        if (-not [bool]$t2.circuit_open -or [string]$t2.circuit -ne 'OPEN') {
            return (New-E2eCheckResult $false ('timeout-circuit-not-opened:' + (Get-E2eSafeText $t2.circuit 16)))
        }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        # Third call on the timed-out turn: an OPEN circuit must refuse before
        # the probe seam runs, so the marker must still be absent afterwards.
        $null = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpTimeoutTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $timeoutProbe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if (Test-Path -LiteralPath $marker) { return (New-E2eCheckResult $false 'timeout-open-circuit-ran-probe') }

        # Network leg on its own turn: it must stay a DISTINCT classification, so
        # a network failure can never be reported as the timeout result.
        $one = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpCircuitTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $probe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if ([string]$one.failure_class -ne 'network') { return (New-E2eCheckResult $false ('first-failure-class:' + (Get-E2eSafeText $one.failure_class 24))) }
        if ([string]$one.failure -eq 'MCP_TIMEOUT') { return (New-E2eCheckResult $false 'network-failure-reported-as-timeout') }
        if ([string]$one.circuit -ne 'CLOSED') { return (New-E2eCheckResult $false ('first-circuit:' + (Get-E2eSafeText $one.circuit 16))) }
        $two = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpCircuitTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $probe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if (-not [bool]$two.circuit_open -or [string]$two.circuit -ne 'OPEN') {
            return (New-E2eCheckResult $false ('circuit-not-opened:' + (Get-E2eSafeText $two.circuit 16)))
        }
        # The first two calls must have really executed the seam, otherwise the
        # circuit below would be proving nothing.
        if (-not (Test-Path -LiteralPath $marker)) { return (New-E2eCheckResult $false 'probe-never-ran') }
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        # Third call in the same turn: the OPEN circuit must refuse before the
        # probe seam runs, so the marker must still be absent afterwards.
        $null = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId $C.McpCircuitTurn -Class 'advisory' `
            -Criticality 'optional' -Probe $probe -ProbeArgs @($marker) -TelemetryRoot $C.Work -RepoRoot $C.RepoRoot -BudgetSecondsOverride 5
        if (Test-Path -LiteralPath $marker) { return (New-E2eCheckResult $false 'open-circuit-ran-probe') }
        return (New-E2eCheckResult $true 'timeout and network stay distinct classes; each opens the per-turn circuit after two failures')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckLevel {
    param($C, [string]$Check, [string]$Expected, $Descriptor, [string]$ExpectTrigger = '')
    $dep = Test-E2eFunctionAvailable -Name 'Get-OrchestrationValidationLevel' -LibName $Check
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $r = Get-OrchestrationValidationLevel -Descriptor $Descriptor
        if ([string]$r.status -ne 'ok') { return (New-E2eCheckResult $false ('status:' + (Get-E2eSafeText $r.status 32))) }
        if ([string]$r.level -ne $Expected) { return (New-E2eCheckResult $false ('level:' + (Get-E2eSafeText $r.level 8)) + '/expected:' + $Expected) }
        if (@($r.required_roles).Count -eq 0) { return (New-E2eCheckResult $false 'no-required-roles') }
        if ($ExpectTrigger -and (@($r.triggers) -notcontains $ExpectTrigger)) { return (New-E2eCheckResult $false 'hard-trigger-absent') }
        return (New-E2eCheckResult $true ('level ' + $Expected + ' with ' + @($r.required_roles).Count + ' required role(s)'))
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckEvidenceReuse {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'New-OrchestrationEvidenceRecord' -LibName 'evidence-reuse'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $store = Join-Path $C.Work 'evidence-store'
        $fingerprint = 'fp-' + (Get-E2eManifestHash 'rr-e2e-27')
        $evidence = @{
            task_id               = 'RR-E2E-27'
            run_id                = 'rr-e2e-run-27'
            worker_id             = 'coder'
            base_revision         = 'base-27'
            source_fingerprints   = @{ 'lib/Sample.ps1' = $fingerprint }
            scope                 = @('scenario-27')
            command               = 'pwsh -NoProfile synthetic.ps1'
            environment           = @{ runtime = 'pwsh'; version = 'synthetic' }
            result                = @{ summary = 'synthetic evidence for scenario 27'; raw_ref = 'raw/27.txt' }
            created_at            = '2026-01-02T03:04:05Z'
            provenance            = @{ created_by = 'coder'; kernel_task_ref = 'RR-E2E-27' }
            invalidation_conditions = @(@{ type = 'source-changed'; paths = @('lib/Sample.ps1') })
        }
        $created = New-OrchestrationEvidenceRecord -Evidence $evidence -StoreDir $store
        if (-not [bool]$created.created) { return (New-E2eCheckResult $false ('record-not-created:' + (Get-E2eSafeText $created.reason 40))) }
        $same = Find-ReusableOrchestrationEvidence -StoreDir $store -Scope @('scenario-27') `
            -CurrentSourceFingerprints @{ 'lib/Sample.ps1' = $fingerprint } -CurrentBaseRevision 'base-27' `
            -CurrentCriteriaHash '' -CurrentEnv @{ runtime = 'pwsh'; version = 'synthetic' } -Now '2026-01-02T03:09:05Z'
        if (@($same).Count -ne 1) { return (New-E2eCheckResult $false 'unchanged-source-not-reused') }
        $changed = Find-ReusableOrchestrationEvidence -StoreDir $store -Scope @('scenario-27') `
            -CurrentSourceFingerprints @{ 'lib/Sample.ps1' = 'fp-changed' } -CurrentBaseRevision 'base-27' `
            -CurrentCriteriaHash '' -CurrentEnv @{ runtime = 'pwsh'; version = 'synthetic' } -Now '2026-01-02T03:09:05Z'
        if (@($changed).Count -ne 0) { return (New-E2eCheckResult $false 'changed-source-still-reused') }
        $scopeMiss = Find-ReusableOrchestrationEvidence -StoreDir $store -Scope @('scenario-99') `
            -CurrentSourceFingerprints @{ 'lib/Sample.ps1' = $fingerprint } -CurrentBaseRevision 'base-27' `
            -CurrentCriteriaHash '' -CurrentEnv @{ runtime = 'pwsh'; version = 'synthetic' } -Now '2026-01-02T03:09:05Z'
        if (@($scopeMiss).Count -ne 0) { return (New-E2eCheckResult $false 'out-of-scope-evidence-reused') }
        return (New-E2eCheckResult $true 'reuse hits unchanged source and invalidates on source or scope change')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckReviewerBundle {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Get-OrchestrationReviewerBundle' -LibName 'reviewer-bundle'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $first = Get-OrchestrationReviewerBundle -ChangedFiles @('lib/B.ps1', 'lib/A.ps1', 'lib/A.ps1') -RelatedFiles @('lib/A.tests.ps1', 'lib/Unrelated.ps1')
        $second = Get-OrchestrationReviewerBundle -ChangedFiles @('lib/A.ps1', 'lib/B.ps1') -RelatedFiles @('lib/A.tests.ps1', 'lib/Unrelated.ps1', 'lib/A.ps1')
        $a = @($first); $b = @($second)
        if ($a.Count -ne 3) { return (New-E2eCheckResult $false ('bundle-size:' + $a.Count)) }
        if ((ConvertTo-Json -InputObject $a -Compress) -cne (ConvertTo-Json -InputObject $b -Compress)) {
            return (New-E2eCheckResult $false 'bundle-not-order-independent')
        }
        if ($a[0] -cne 'lib/A.ps1' -or $a[1] -cne 'lib/A.tests.ps1' -or $a[2] -cne 'lib/B.ps1') {
            return (New-E2eCheckResult $false 'bundle-not-canonical')
        }
        if ($a -contains 'lib/Unrelated.ps1') { return (New-E2eCheckResult $false 'unrelated-file-included') }
        return (New-E2eCheckResult $true 'reviewer bundle is deduplicated, sorted and order independent')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckNoBonusWork {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Build-OrchestrationWorkerContractFields' -LibName 'no-bonus-work'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $r = Build-OrchestrationWorkerContractFields -Descriptor @{ summary = 'Bounded manifest fix'; non_goals = @('No unrelated refactor') }
        if (-not [string]$r.no_bonus_work) { return (New-E2eCheckResult $false 'no-bonus-work-missing') }
        if (@($r.principles) -notcontains 'no-bonus-work') { return (New-E2eCheckResult $false 'no-bonus-work-not-a-principle') }
        if (@($r.non_goals).Count -lt 1) { return (New-E2eCheckResult $false 'non-goals-empty') }
        if (-not [string]$r.minimum_sufficient_change) { return (New-E2eCheckResult $false 'minimum-sufficient-change-missing') }
        $default = Build-OrchestrationWorkerContractFields -Descriptor @{ summary = 'Bounded manifest fix' }
        if (@($default.non_goals).Count -lt 1) { return (New-E2eCheckResult $false 'default-non-goals-empty') }
        $keys = @($r.PSObject.Properties.Name)
        if ($keys.Count -ne $default.PSObject.Properties.Name.Count) { return (New-E2eCheckResult $false 'contract-shape-drift') }
        return (New-E2eCheckResult $true 'no-bonus-work principle and explicit non-goals always present')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckChangeBudget {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Test-OrchestrationChangeBudget' -LibName 'change-budget'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $small = Test-OrchestrationChangeBudget -ChangedFiles @(@{ path = 'lib/Small.ps1'; additions = 5; deletions = 1 })
        if (-not [bool]$small.within_budget) { return (New-E2eCheckResult $false 'small-change-rejected') }
        $big = Test-OrchestrationChangeBudget -ChangedFiles @(@{ path = 'lib/Big.ps1'; additions = 900; deletions = 400 })
        if ([bool]$big.within_budget) { return (New-E2eCheckResult $false 'oversize-change-accepted-without-rationale') }
        if ([bool]$big.rationale_required -ne $true) { return (New-E2eCheckResult $false 'rationale-not-required') }
        $accepted = Test-OrchestrationChangeBudget -ChangedFiles @(@{ path = 'lib/Big.ps1'; additions = 900; deletions = 400 }) -Rationale 'Bounded synthetic overage for scenario 30.'
        if ([string]$accepted.exceeded -notmatch 'accepted') { return (New-E2eCheckResult $false ('rationale-not-accepted:' + (Get-E2eSafeText $accepted.exceeded 24))) }
        return (New-E2eCheckResult $true 'over-budget change is refused without rationale and accepted only with one')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckBudgetFanout {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Invoke-OrchestrationPlannerLoop' -LibName 'budget-fanout'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $descriptor = @{
            objective                  = 'Bounded fan-out decision for scenario 31.'
            risk                       = 'medium'
            work_independent           = $true
            ownership_clear            = $true
            shared_state               = $false
            latency_benefit            = $true
            synthesis_affordable       = $true
            validation_budget_available = $true
        }
        $parallel = Invoke-OrchestrationPlannerLoop -Descriptor $descriptor -Options @{ timestamp = '2026-01-02T03:04:05Z' }
        if ([string]$parallel.status -ne 'ok') { return (New-E2eCheckResult $false ('planner-status:' + (Get-E2eSafeText $parallel.status 24))) }
        if (-not [bool]$parallel.plan.dispatch_plan.parallel_ok) { return (New-E2eCheckResult $false 'fan-out-refused-with-budget') }
        if ([string]$parallel.plan.budget_reservation.status -ne 'record-only') { return (New-E2eCheckResult $false 'budget-not-record-only') }
        $serial = @{}
        foreach ($k in $descriptor.Keys) { $serial[$k] = $descriptor[$k] }
        $serial['validation_budget_available'] = $false
        $bounded = Invoke-OrchestrationPlannerLoop -Descriptor $serial -Options @{ timestamp = '2026-01-02T03:04:05Z' }
        if ([bool]$bounded.plan.dispatch_plan.parallel_ok) { return (New-E2eCheckResult $false 'fan-out-allowed-without-budget') }
        if (@($bounded.plan.dispatch_plan.workers).Count -ne 1) { return (New-E2eCheckResult $false 'unbudgeted-fanout-not-collapsed') }
        return (New-E2eCheckResult $true 'fan-out follows the budget and stays record-only')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckCapabilityFallback {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Get-OrchestrationCapabilityFallback' -LibName 'capability-fallback'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $policy = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $C.RepoRoot 'source/registry/capability-doctor-policy.json')))
        $fallback = Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health unavailable -Policy $policy
        if (-not [bool]$fallback.use_fallback) { return (New-E2eCheckResult $false 'no-fallback-selected') }
        if ([string]$fallback.fallback_to -ne 'local-project-search') { return (New-E2eCheckResult $false ('fallback-target:' + (Get-E2eSafeText $fallback.fallback_to 40))) }
        if ([bool]$fallback.blocked) { return (New-E2eCheckResult $false 'fallback-also-blocked') }
        $healthy = Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health healthy -Policy $policy
        if ([bool]$healthy.use_fallback) { return (New-E2eCheckResult $false 'fallback-taken-while-healthy') }
        return (New-E2eCheckResult $true 'unavailable primary resolves to the declared deterministic fallback')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckCapabilityWindowsUnsupported {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Invoke-OrchestrationCapabilityDoctor' -LibName 'capability-windows-unsupported'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $policy = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $C.RepoRoot 'source/registry/capability-doctor-policy.json')))
        # No -Clock callback is handed to the doctor: this harness reads only the
        # capability verdict below, never a doctor timestamp, so injecting one
        # would buy no determinism and would keep a scriptblock seam alive.
        $report = Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform windows -Probe { param($name, $budget) throw 'probe-must-not-run' }
        $semantic = $report.capabilities.'semantic-discovery'
        if ([string]$semantic.health -ne 'unsupported') { return (New-E2eCheckResult $false ('health:' + (Get-E2eSafeText $semantic.health 24))) }
        $fb = Get-OrchestrationCapabilityFallback -Capability 'semantic-discovery' -Health unsupported -Policy $policy -Platform 'windows'
        if (-not [bool]$fb.use_fallback -or [string]$fb.fallback_to -ne 'direct-search') {
            return (New-E2eCheckResult $false ('fallback:' + (Get-E2eSafeText $fb.fallback_to 32)))
        }
        return (New-E2eCheckResult $true 'optional semantic discovery reports unsupported on windows and falls back')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckNoWidenGrants {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Get-OrchestrationEffectiveGrants' -LibName 'no-widen-grants'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $requested = @('fs.read', 'deploy.production', 'git.push', 'secrets.read', 'destructive.fs')
        $granted = @(Get-OrchestrationEffectiveGrants -Role coder -TaskGrants $requested -RepoRoot $C.RepoRoot)
        if ($granted -notcontains 'fs.read') { return (New-E2eCheckResult $false 'baseline-grant-lost') }
        foreach ($sensitive in @('deploy.production', 'git.push', 'secrets.read', 'destructive.fs')) {
            if ($granted -contains $sensitive) { return (New-E2eCheckResult $false ('sensitive-grant-widened:' + $sensitive)) }
        }
        # Human approval alone must still not widen: a missing authorization
        # set is what excludes the sensitive grant, not the switch.
        $approvedOnly = @(Get-OrchestrationEffectiveGrants -Role coder -TaskGrants $requested -HumanApproved -RepoRoot $C.RepoRoot)
        if ($approvedOnly -contains 'deploy.production') { return (New-E2eCheckResult $false 'approval-alone-widened-grants') }
        $unknownRole = @(Get-OrchestrationEffectiveGrants -Role 'no-such-role' -TaskGrants $requested -RepoRoot $C.RepoRoot)
        if ($unknownRole.Count -ne 0) { return (New-E2eCheckResult $false 'unknown-role-granted') }
        $mcpGate = Invoke-McpSafetyGrantGate -McpResult ([pscustomobject]@{ status = 'OK'; granted = $true; widened = $true })
        if ([string]$mcpGate.status -ne 'MCP_RESULT_CANNOT_GRANT' -or [bool]$mcpGate.granted -or [bool]$mcpGate.widened) {
            return (New-E2eCheckResult $false 'mcp-result-granted-authority')
        }
        return (New-E2eCheckResult $true 'worker cannot widen: intersection only, and an MCP result never grants')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckJevCannotGrant {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Invoke-JevAdvisoryGrantGate' -LibName 'jev-cannot-grant'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $hostile = @(
            @{ label = 'forged-ok'; result = [pscustomobject]@{ status = 'OK'; granted = $true; widened = $true; done = 'DONE' } },
            @{ label = 'null'; result = $null },
            @{ label = 'scalar'; result = 'granted' },
            @{ label = 'empty-dictionary'; result = @{} }
        )
        foreach ($case in $hostile) {
            $r = Invoke-JevAdvisoryGrantGate -JevResult $case.result
            if ([string]$r.status -ne 'JEV_ADVISORY_CANNOT_GRANT') { return (New-E2eCheckResult $false ('status:' + (Get-E2eSafeText $case.label 24))) }
            if ([bool]$r.granted -or [bool]$r.widened -or [bool]$r.model_selected -or [bool]$r.done_written) {
                return (New-E2eCheckResult $false ('granted-via:' + (Get-E2eSafeText $case.label 24)))
            }
        }
        return (New-E2eCheckResult $true 'Jev output never grants, widens, selects a model or writes DONE')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckNoSubdelegation {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Test-OrchestrationSubdelegation' -LibName 'no-subdelegation'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        if ([string](Test-OrchestrationSubdelegation -IsWorker $true) -ne 'denied') { return (New-E2eCheckResult $false 'worker-subdelegation-allowed') }
        if ([string](Test-OrchestrationSubdelegation -Worker $true) -ne 'denied') { return (New-E2eCheckResult $false 'worker-flag-subdelegation-allowed') }
        if ([string](Test-OrchestrationSubdelegation) -ne 'allowed') { return (New-E2eCheckResult $false 'planner-subdelegation-denied') }
        return (New-E2eCheckResult $true 'background child cannot subdelegate; planner delegation is unaffected')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckV2NativeNoEvidence {
    <#
    .SYNOPSIS
        Synthetic invariant for the data-driven V2 native gating: it refuses
        EVERY declared candidate while no exact-binary evidence exists.
    .DESCRIPTION
        This is NOT the plan's "V2 policy deny where validated" scenario, which
        needs the real V2 runtime and stays requires-operator-runtime. What is
        decidable offline is narrower and is asserted here: with no evidence
        registry the gate never enables a candidate, never loses its structured
        reason, and never turns a hostile or undeclared id into authority.
    #>
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Get-OrchestrationV2NativeFeatures' -LibName 'v2-native-no-evidence'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $feature = Get-OrchestrationV2NativeFeature -feature_id 'experimental-policies-hard-deny'
        if ([bool]$feature.enabled) { return (New-E2eCheckResult $false 'feature-enabled-without-evidence') }
        if ([string]$feature.status -ne 'not-proven') { return (New-E2eCheckResult $false ('status:' + (Get-E2eSafeText $feature.status 24))) }
        if ([string]::IsNullOrWhiteSpace([string]$feature.reason)) { return (New-E2eCheckResult $false 'refusal-without-a-reason') }
        # The refusal must be data driven: EVERY declared candidate is refused,
        # not only the one this check names first.
        $all = @(Get-OrchestrationV2NativeFeatures)
        if ($all.Count -eq 0) { return (New-E2eCheckResult $false 'no-declared-candidates-read') }
        foreach ($f in $all) {
            if ([bool]$f.enabled) { return (New-E2eCheckResult $false ('candidate-enabled:' + (Get-E2eSafeText $f.feature_id 40))) }
            if ([string]$f.status -ne 'not-proven') { return (New-E2eCheckResult $false ('candidate-status:' + (Get-E2eSafeText $f.status 24))) }
            if ([string]::IsNullOrWhiteSpace([string]$f.reason)) { return (New-E2eCheckResult $false 'candidate-refused-without-a-reason') }
            if ([string]$f.authority_impact -eq 'widening') { return (New-E2eCheckResult $false 'authority-widening-declared') }
        }
        $hostile = Get-OrchestrationV2NativeFeature -feature_id '../../etc/passwd?x=1'
        if ([bool]$hostile.enabled) { return (New-E2eCheckResult $false 'hostile-id-enabled') }
        if ($hostile.PSObject.Properties['reason'].Value -ne 'feature-id-missing') { return (New-E2eCheckResult $false 'hostile-id-reason') }
        if ([string]$hostile.feature_id -match '[\\/]') { return (New-E2eCheckResult $false 'hostile-id-echoed') }
        $missing = Get-OrchestrationV2NativeFeature -feature_id 'not-a-declared-candidate'
        if ([bool]$missing.enabled) { return (New-E2eCheckResult $false 'undeclared-feature-enabled') }
        # A damaged evidence registry is the same refusal, not a silent pass.
        $damaged = Get-OrchestrationV2NativeFeature -feature_id 'experimental-policies-hard-deny' `
            -evidence_registry_path ([IO.Path]::Combine($C.Work, 'v2-evidence-damaged.json'))
        if ([bool]$damaged.enabled) { return (New-E2eCheckResult $false 'feature-enabled-on-a-damaged-registry') }
        if ([string]::IsNullOrWhiteSpace([string]$damaged.reason)) { return (New-E2eCheckResult $false 'damaged-registry-refused-without-a-reason') }
        return (New-E2eCheckResult $true ('every one of ' + $all.Count + ' declared V2 candidates stays not-proven without exact-binary evidence'))
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function Invoke-E2eCheckWatchdogUnknownPid {
    param($C)
    $dep = Test-E2eFunctionAvailable -Name 'Test-WatchdogProcessOwnership' -LibName 'watchdog-unknown-pid'
    if (-not $dep.available) { return (New-E2eCheckResult $false $dep.reason) }
    try {
        $absent = 0
        foreach ($candidate in 4190000..4190099) {
            if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absent = $candidate; break }
        }
        if ($absent -lt 1) { return (New-E2eCheckResult $false 'no-absent-pid-available') }
        $execution = @{ attempt_n = 1; process = @{ process_id = $absent } }
        # Ownership first: an absent PID must be proven gone, never owned.
        $own = Test-WatchdogProcessOwnership -Execution $execution
        if ([bool]$own.owned) { return (New-E2eCheckResult $false 'absent-pid-claimed-owned') }
        if ([string]$own.reason -ne 'WATCHDOG_PROCESS_GONE') { return (New-E2eCheckResult $false ('ownership-reason:' + (Get-E2eSafeText $own.reason 40))) }
        $noIdentity = Test-WatchdogProcessOwnership -Execution @{ process = @{ process_id = 0 } }
        if ([bool]$noIdentity.owned) { return (New-E2eCheckResult $false 'invalid-pid-claimed-owned') }
        $r = Invoke-WatchdogProcessInterrupt -TaskId 'RR-E2E-40' -Execution $execution -Classification 'HARD_TIMEOUT' `
            -ElapsedSeconds 30 -Steps 2 -TelemetryRoot (Join-Path $C.Work 'watchdog-telemetry') -RepoRoot $C.RepoRoot
        if ([bool]$r.ok) { return (New-E2eCheckResult $false 'interrupt-accepted-for-unknown-pid') }
        if ([string]$r.error -ne 'WATCHDOG_INTERRUPT_REFUSED') { return (New-E2eCheckResult $false ('error:' + (Get-E2eSafeText $r.error 40))) }
        if ($r.PSObject.Properties['interrupted'] -and [bool]$r.interrupted) { return (New-E2eCheckResult $false 'interrupt-claimed-kill') }
        if ($null -ne (Get-Process -Id $absent -ErrorAction SilentlyContinue)) { return (New-E2eCheckResult $false 'pid-space-mutated') }
        return (New-E2eCheckResult $true 'unknown PID proven gone, interrupt refused, nothing killed')
    } catch { return (New-E2eCheckResult $false ('throw:' + (Get-E2eSafeText $_.Exception.Message 80))) }
}

function New-E2eCheckResult {
    [CmdletBinding()] param([bool]$Ok, [string]$Detail)
    return [pscustomobject]@{ ok = [bool]$Ok; detail = (Get-E2eSafeText $Detail 200) }
}

function Get-E2eManifestHash {
    [CmdletBinding()] param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hex = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        return $hex.Substring(0, 16)
    } catch { return 'e2e0000000000000' }
}

function Invoke-E2eScenarioCheck {
    [CmdletBinding()] param([string]$Check, $Context)
    # Closed dispatcher. An unregistered id is a harness defect and fails closed.
    switch ($Check) {
        'mcp-healthy' { return (Invoke-E2eCheckMcpHealthy $Context) }
        'mcp-circuit' { return (Invoke-E2eCheckMcpCircuit $Context) }
        'level-l0' { return (Invoke-E2eCheckLevel $Context 'level-l0' 'L0' @{ trivial_direct = $true; risk = 'low' }) }
        'level-l1' { return (Invoke-E2eCheckLevel $Context 'level-l1' 'L1' @{ localized = $true; risk = 'low' }) }
        'level-l2' { return (Invoke-E2eCheckLevel $Context 'level-l2' 'L2' @{ risk = 'medium' }) }
        'level-l3' { return (Invoke-E2eCheckLevel $Context 'level-l3' 'L3' @{ risk = 'high'; risk_triggers = @('auth') } 'auth') }
        'evidence-reuse' { return (Invoke-E2eCheckEvidenceReuse $Context) }
        'reviewer-bundle' { return (Invoke-E2eCheckReviewerBundle $Context) }
        'no-bonus-work' { return (Invoke-E2eCheckNoBonusWork $Context) }
        'change-budget' { return (Invoke-E2eCheckChangeBudget $Context) }
        'budget-fanout' { return (Invoke-E2eCheckBudgetFanout $Context) }
        'capability-fallback' { return (Invoke-E2eCheckCapabilityFallback $Context) }
        'capability-windows-unsupported' { return (Invoke-E2eCheckCapabilityWindowsUnsupported $Context) }
        'no-widen-grants' { return (Invoke-E2eCheckNoWidenGrants $Context) }
        'jev-cannot-grant' { return (Invoke-E2eCheckJevCannotGrant $Context) }
        'no-subdelegation' { return (Invoke-E2eCheckNoSubdelegation $Context) }
        'v2-native-no-evidence' { return (Invoke-E2eCheckV2NativeNoEvidence $Context) }
        'watchdog-unknown-pid' { return (Invoke-E2eCheckWatchdogUnknownPid $Context) }
        default { return [pscustomobject]@{ ok = $false; detail = 'unregistered-check' } }
    }
}

function Invoke-OrchestrationE2eManifest {
    <#
    .SYNOPSIS
        Executes the Phase 42 scenario harness and reports one honest row per
        scenario plus aggregate counts.
    .DESCRIPTION
        Returns status 'ok' when the manifest is valid AND every
        runnable-synthetic scenario really passed. 'failed' when at least one
        real check failed or the manifest is invalid; 'error' on an unexpected
        internal failure. A non-ok status is never a pass.

        A blocked scenario is never executed and never reported as a pass. The
        release gate field is a constant reminder: this harness does not close
        it. Pass-synthetic proves one library invariant offline with synthetic
        inputs on this host; it is not evidence for the real V2 Windows lane,
        for a flag activation, or for a real transport.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath = '',
        [string]$RepoRoot = '',
        [string]$WorkRoot = '',
        [string]$TimestampUtc = ''
    )
    try {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-E2eManifestRepoRoot }
        $manifest = Get-OrchestrationE2eManifest -ManifestPath $ManifestPath -RepoRoot $RepoRoot
        if ([string]$manifest.status -ne 'ok') {
            return [pscustomobject]@{
                status         = 'invalid-manifest'
                reason         = (Get-E2eSafeText $manifest.reason 80)
                release_gate   = 'open-pending-operator'
                generated_at   = ''
                timestamp_valid = $true
                counts         = [pscustomobject]@{ total = 0; pass_synthetic = 0; failed_synthetic = 0; blocked_requires_operator = 0; blocked_requires_flag = 0; blocked_requires_transport = 0 }
                scenarios      = @()
                holds          = @('Manifest invalid: no scenario result is claimed.')
            }
        }
        $stamp = Resolve-E2eTimestampUtc -TimestampUtc $TimestampUtc
        $timestampValid = [bool]$stamp.valid
        $generated = Get-E2eSafeText ($stamp.stamp.ToString('o')) 40

        $script:E2eLibDir = Join-Path $RepoRoot 'scripts/v3/lib'
        # Import every library the runnable-synthetic checks need into THIS
        # scope, so the check functions resolve them by ordinary scope lookup.
        # Dot-sourcing inside a helper would bind them to that helper's scope
        # and lose them on return, which is why the loop is inline.
        $script:E2eMissingLibs = @()
        foreach ($libName in @($script:E2eLibMap.Values | Sort-Object -Unique)) {
            $libPath = Join-Path $script:E2eLibDir $libName
            if (-not (Test-Path -LiteralPath $libPath -PathType Leaf)) { $script:E2eMissingLibs += $libName; continue }
            try { . $libPath } catch { $script:E2eMissingLibs += $libName }
        }

        $ownsWork = $false
        $work = $WorkRoot
        if ([string]::IsNullOrWhiteSpace($work)) {
            $work = Join-Path ([IO.Path]::GetTempPath()) ('orchestration-e2e-' + (Get-E2eManifestHash ([Guid]::NewGuid().ToString('N'))))
            $ownsWork = $true
        }
        # A per-invocation nonce keeps the MCP per-turn circuit key unique, so a
        # repeated run in the same process starts from the same closed state and
        # the reported row stays deterministic. It is never emitted.
        $nonce = Get-E2eManifestHash ([Guid]::NewGuid().ToString('N') + '|' + $generated)
        $context = @{
            RepoRoot       = $RepoRoot
            Work           = $work
            Nonce          = $nonce
            McpHealthyTurn = ('rr-e2e-11-' + $nonce)
            McpCircuitTurn = ('rr-e2e-12-' + $nonce)
            McpTimeoutTurn = ('rr-e2e-12t-' + $nonce)
        }
        try { if (-not (Test-Path -LiteralPath $work -PathType Container)) { [void][IO.Directory]::CreateDirectory($work) } } catch { }

        $rows = New-Object System.Collections.ArrayList
        $counts = [ordered]@{ total = 0; pass_synthetic = 0; failed_synthetic = 0; blocked_requires_operator = 0; blocked_requires_flag = 0; blocked_requires_transport = 0 }
        try {
            foreach ($s in $manifest.scenarios) {
                $counts.total++
                if ($s.classification -ne 'runnable-synthetic') {
                    $status = $script:E2eBlockedStatus[$s.classification]
                    switch ($status) {
                        'blocked-requires-operator' { $counts.blocked_requires_operator++ }
                        'blocked-requires-flag' { $counts.blocked_requires_flag++ }
                        'blocked-requires-transport' { $counts.blocked_requires_transport++ }
                    }
                    [void]$rows.Add([pscustomobject]@{
                            scenario_id       = $s.scenario_id
                            ordinal           = $s.ordinal
                            category          = $s.category
                            classification    = $s.classification
                            status            = $status
                            detail            = $s.required_activation
                            evidence_ref      = $s.evidence_ref
                            mapped_component  = $s.mapped_component
                            required_activation = $s.required_activation
                        })
                    continue
                }
                $check = Invoke-E2eScenarioCheck -Check $s.check -Context $context
                $ok = [bool]$check.ok
                if ($ok) { $counts.pass_synthetic++ } else { $counts.failed_synthetic++ }
                [void]$rows.Add([pscustomobject]@{
                        scenario_id       = $s.scenario_id
                        ordinal           = $s.ordinal
                        category          = $s.category
                        classification    = $s.classification
                        status            = $(if ($ok) { 'pass-synthetic' } else { 'failed-synthetic' })
                        detail            = $check.detail
                        evidence_ref      = $s.evidence_ref
                        mapped_component  = $s.mapped_component
                        required_activation = $s.required_activation
                    })
            }
        } finally {
            if ($ownsWork) {
                try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
        $status = 'ok'
        if ($counts.failed_synthetic -gt 0) { $status = 'failed' }
        $holds = @(
            'Real V2 Windows lane (scenarios 01-10, 16-22, 39) is operator-owned and unproven on this host.',
            'Every capability flag activation stays OFF; no activation was performed here.',
            'Real transports (Jev service, AI Memory remote VPS) were never contacted; zero network.',
            'pass-synthetic proves one library invariant offline with synthetic inputs; it is not release-gate evidence.'
        )
        if (-not $timestampValid) {
            $holds = @($holds + 'TimestampUtc was not a parseable ISO-8601 instant; the supplied value was not echoed and this internal UTC instant is reported with timestamp_valid = false.')
        }
        return [pscustomobject]@{
            status       = $status
            reason       = ''
            release_gate = 'open-pending-operator'
            generated_at = $generated
            timestamp_valid = $timestampValid
            counts       = [pscustomobject]$counts
            scenarios    = @($rows.ToArray())
            holds        = $holds
        }
    } catch {
        return [pscustomobject]@{
            status       = 'error'
            reason       = (Get-E2eSafeText $_.Exception.Message 120)
            release_gate = 'open-pending-operator'
            generated_at = ''
            timestamp_valid = $true
            counts       = [pscustomobject]@{ total = 0; pass_synthetic = 0; failed_synthetic = 0; blocked_requires_operator = 0; blocked_requires_flag = 0; blocked_requires_transport = 0 }
            scenarios    = @()
            holds        = @('Unexpected harness error; no scenario result is claimed.')
        }
    }
}

function Get-OrchestrationRolloutChecklist {
    <#
    .SYNOPSIS
        Derives the 19-step rollout checklist from real repository state.
    .DESCRIPTION
        Status is derived, never declared:

        shipped           the library, its proof record and its evidence record
                          all PARSE, and the step either carries no activation
                          flag or its declared flag is already active.
        shadow-ready      proof and evidence parse, the activation flag is OFF,
                          and the declared shadow leg is sufficient and on.
        blocked-activation proof and evidence parse, and activation is genuinely
                          pending: the declared flag resolves OFF, or the policy
                          does not declare that flag at all.
        blocked-evidence  nothing is claimed. The library is absent, the proof
                          or evidence record is absent OR does not parse, the
                          capability-flag registry is unreadable/corrupted, or a
                          declared flag path resolves to no readable state: the
                          node carries no activation leaf, or the leaf it
                          declares is not exactly a boolean. An activation or
                          shadow leaf is never coerced, because [bool]'false'
                          is $true and would promote a disabled flag.

        A damaged configuration can never promote a step. In particular an
        unresolvable flag is NOT an absent flag: only a READABLE registry that
        does not declare the path yields blocked-activation, and no code path
        reaches 'shipped' without a parsed proof record.

        A shipped step means the library and its evidence record were delivered;
        it is never a claim that the corresponding V2 lane result is green.

        TimestampUtc is a validated value, not a callback: an unparseable value
        is never echoed, the internal UTC instant is reported instead and the
        holds array states it.
    #>
    [CmdletBinding()]
    param(
        [string]$ManifestPath = '',
        [string]$RepoRoot = '',
        [string]$TimestampUtc = ''
    )
    try {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-E2eManifestRepoRoot }
        $manifest = Get-OrchestrationE2eManifest -ManifestPath $ManifestPath -RepoRoot $RepoRoot
        if ([string]$manifest.status -ne 'ok') {
            return [pscustomobject]@{
                status       = 'invalid-manifest'
                reason       = (Get-E2eSafeText $manifest.reason 80)
                generated_at = ''
                timestamp_valid = $true
                counts       = [pscustomobject]@{ total = 0; shipped = 0; shadow_ready = 0; blocked_activation = 0; blocked_evidence = 0 }
                steps        = @()
                holds        = @('Manifest invalid: no rollout step is claimed.')
            }
        }
        $stamp = Resolve-E2eTimestampUtc -TimestampUtc $TimestampUtc
        $timestampValid = [bool]$stamp.valid
        $generated = Get-E2eSafeText ($stamp.stamp.ToString('o')) 40
        # The registry is resolved ONCE and its own health is a precondition: a
        # corrupted flag file must never look like "no flag declared".
        $registry = Get-E2eArtifactState -RepoRoot $RepoRoot -RelativePath 'source/registry/capability-flags.json'
        $counts = [ordered]@{ total = 0; shipped = 0; shadow_ready = 0; blocked_activation = 0; blocked_evidence = 0 }
        $rows = New-Object System.Collections.ArrayList
        foreach ($st in $manifest.rollout_steps) {
            $counts.total++
            $libPresent = Test-Path -LiteralPath (Join-Path $RepoRoot $st.lib) -PathType Leaf
            # Existence is not proof: a proof or evidence record counts only
            # when it parses, and the two defects keep distinct reasons.
            $proof = Get-E2eArtifactState -RepoRoot $RepoRoot -RelativePath $st.proof
            $evidence = Get-E2eArtifactState -RepoRoot $RepoRoot -RelativePath $st.evidence
            $active = Get-E2eFlagState -Flags $registry.doc -Path $st.flag
            $shadow = Get-E2eShadowState -Flags $registry.doc -Path $st.shadow_flag
            $flagDeclared = Test-E2eFlagPath -Flags $registry.doc -Path $st.flag
            $status = ''
            $reason = ''
            if (-not $libPresent) {
                $status = 'blocked-evidence'; $reason = 'library-absent'
            } elseif ($proof.state -ne 'present') {
                $status = 'blocked-evidence'; $reason = ('proof-artifact-' + $proof.state)
            } elseif ($evidence.state -ne 'present') {
                $status = 'blocked-evidence'; $reason = ('evidence-record-' + $evidence.state)
            } elseif (-not $registry.present) {
                $status = 'blocked-evidence'; $reason = 'flag-registry-unreadable'
            } elseif ($st.flag -and $null -eq $active -and $flagDeclared) {
                # Declared in the policy, but no readable ON/OFF state: unknown
                # is not OFF and never shipped.
                $status = 'blocked-evidence'; $reason = 'flag-state-unresolvable'
            } elseif ($st.flag -and $null -eq $active) {
                $status = 'blocked-activation'; $reason = 'flag-not-declared-in-policy'
            } elseif ($st.flag -and ($active -is [bool]) -and $active) {
                # The resolver already returned a genuine boolean or $null: this
                # branch must not coerce anything back into a claim of ON.
                $status = 'shipped'; $reason = 'flag-active-with-evidence'
            } elseif ($st.shadow_sufficient -and ($shadow -is [bool]) -and $shadow) {
                $status = 'shadow-ready'; $reason = 'shadow-leg-sufficient'
            } elseif ($st.flag) {
                $status = 'blocked-activation'; $reason = 'activation-flag-off'
            } else {
                $status = 'shipped'; $reason = 'delivered-with-evidence'
            }
            switch ($status) {
                'shipped' { $counts.shipped++ }
                'shadow-ready' { $counts.shadow_ready++ }
                'blocked-activation' { $counts.blocked_activation++ }
                'blocked-evidence' { $counts.blocked_evidence++ }
            }
            [void]$rows.Add([pscustomobject]@{
                    step           = $st.step
                    name           = $st.name
                    status         = $status
                    reason         = $reason
                    lib            = $st.lib
                    lib_present    = $libPresent
                    evidence_ref   = $st.evidence
                    evidence_present = $evidence.present
                    proof_ref      = $st.proof
                    proof_present  = $proof.present
                    flag           = $st.flag
                    flag_active    = $active
                    flag_declared  = $flagDeclared
                    flag_registry_present = $registry.present
                    shadow_flag    = $st.shadow_flag
                    shadow_on      = $shadow
                    note           = $st.note
                })
        }
        $holds = @()
        if (-not $timestampValid) {
            $holds = @('TimestampUtc was not a parseable ISO-8601 instant; the supplied value was not echoed and this internal UTC instant is reported with timestamp_valid = false.')
        }
        return [pscustomobject]@{
            status       = 'ok'
            reason       = ''
            generated_at = $generated
            timestamp_valid = $timestampValid
            counts       = [pscustomobject]$counts
            steps        = @($rows.ToArray())
            holds        = $holds
        }
    } catch {
        return [pscustomobject]@{
            status       = 'error'
            reason       = (Get-E2eSafeText $_.Exception.Message 120)
            generated_at = ''
            timestamp_valid = $true
            counts       = [pscustomobject]@{ total = 0; shipped = 0; shadow_ready = 0; blocked_activation = 0; blocked_evidence = 0 }
            steps        = @()
            holds        = @('Unexpected checklist error; no rollout step is claimed.')
        }
    }
}