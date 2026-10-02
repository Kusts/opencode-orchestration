<#!
.SYNOPSIS
    V3 MCP safety envelope and circuit breaker (Phase 28, slice 1).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the MCP
    safety envelope from the V3.1 runtime-reliability addendum (PLAN
    Phase 28, SPEC section 18: all MCP calls bounded; advisory/Jev 30s,
    memory 60s, general remote 120s, long-running under an explicit task
    contract; two consecutive timeout/network failures in one planner
    turn open a temporary circuit; generic mcp_routing stays OFF):

      - Canonical policy file source/registry/mcp-request-policy.json
        (version 1): per-class connect plus execution budgets, the
        jev->advisory alias, failure_threshold 2, circuit cooldown and
        the criticality set (optional | required). A missing or
        malformed policy fails closed with MCP_POLICY_INVALID: this
        file never falls back to silent defaults. Policy-tree
        conversion itself is bounded (max depth 32, max 10000
        nodes, reference-cycle detection): a breaching tree is
        treated as malformed fail-closed, never a throw and never
        unbounded recursion.
      - Bounded invoke seam (Invoke-McpSafetyCall): runs a caller
        supplied self-contained scriptblock inside a fresh runspace
        under the class deadline measured with a wall-clock stopwatch
        (synthetic sleep/thrash fixtures in tests, zero real network).
        Overrun yields structured MCP_TIMEOUT, never a thrown
        exception and never a hang past budget plus settle margin:
        after a timeout the pipeline is stopped with a bounded wait
        (settle margin); when the runspace does not settle in time it
        is deliberately ABANDONED without dispose (an accumulation
        capped by refusal, counted and never reclaimed in-session,
        instead of hanging the caller) and the result carries
        settled=false (consumers must not auto-retry side-effecting
        operations: abandonment performs no rollback and already
        started native code may still complete effects) plus an
        MCP_PROBE_ABANDONED telemetry event.
        A test-only -BudgetSecondsOverride seam tightens the deadline
        (1..policy budget, never wider); production callers omit it.
        -Phase connect|execute selects which per-class budget applies.
        Lock acquisition waits at most McpSafetyLockWaitMaxMs
        (1000ms, never more than the call budget): local contention
        yields structured MCP_LOCK_BUSY immediately, without running
        the seam and without touching the circuit streak (contention
        is not server failure). Capacity (in-flight reservations plus
        abandons) is capped at 8 by ATOMIC reservation against a
        process-shared cell: every probe reserves one unit under a
        dedicated global lock before running; proven settlement
        releases it, abandonment consumes it permanently (never
        reclaimed in-session), so in-flight plus abandoned stays
        <= 8 structurally, even concurrent. The cap holds WHENEVER
        probes execute: without the shared cell (failed load even
        after re-query, or test-only forced simulation) admission
        refuses fail-closed with MCP_CAPACITY_CELL_UNAVAILABLE and
        no probe executes (there is no weaker per-session cap).
        Past the cap new probes are refused fail-closed with
        MCP_ABANDON_LIMIT_REACHED before executing; when even the
        global lock cannot be acquired boundedly the refusal is
        MCP_BUSY_GLOBAL. Every Gate acquisition in this lib is
        bounded; an occupancy read that cannot complete in bound
        yields UNKNOWN (-1), and a release that cannot confirm keeps
        the unit occupied with an honest RELEASE_UNCONFIRMED status
        (conservative direction). Lock order is UNIQUE and documented: global
        capacity lock first, per-key circuit lock second, never the
        reverse, and the global lock is never acquired while holding
        the key lock (the reservation is released only after the key
        lock is exited). Here "bounded" always means bounded wait
        plus accumulation capped by refusal; counters are
        observability, not enforcement or recovery.
        The runspace is NOT a sandbox: only trusted kernel-supplied
        scriptblocks may run through this seam.
      - Circuit (process-shared in-memory cell, per
        server/capability/turn): two
        consecutive timeout/network failures inside the SAME
        caller-declared TurnId open the circuit. OPEN fast-fails with
        MCP_CIRCUIT_OPEN without invoking the seam. After the cooldown
        one half-open probe is allowed: success closes, failure
        re-opens with a renewed cooldown. Records plus per-key locks
        live in the process-shared C# cell, so every runspace in this
        process admits exactly one half-open probe for one key.
        Shared records use an EXACT wire format
        (STATE|consecutive|stamp): a malformed record never reads
        as CLOSED (Invoke refuses fail-closed before any probe
        runs; observability reports honest UNKNOWN).
        Check-and-transition runs
        under a per-key process-shared Monitor lock (single half-open
        probe; a late success only closes its own generation, never a
        newer OPEN), created under the shared KeyGuard with a bounded
        wait (global guard first, per-key second, never the reverse).
        When the shared store is unavailable admission refuses
        fail-closed instead of running split-brain. HOLD: TurnId is
        declared by the caller with no
        identity authentication, and sharing is in-process only
        (cross-process lock is a follow-up, same pattern as the
        watchdog). The cooldown is always measured from the clock
        captured at the CONCLUSION of the failing call, never from
        its start (-NowUtc/-ConcludedAtUtc inject both for tests).
      - Criticality (centrally normalized): optional plus
        unavailable maps to the structured cause as status with
        fallback/continue semantics (typed object, never a fatal
        throw; timeout/network and open circuit surface as
        MCP_UNAVAILABLE with the specific cause in failure,
        execution errors as MCP_ERROR with fallback_continue=true);
        required plus unavailable always maps to the typed blocker
        MCP_REQUIRED_BLOCKED (status/error) with the cause preserved
        in failure and blocked=true, including input-validation,
        long-running-contract, budget re-read and internal errors;
        an invalid policy additionally
        blocks every criticality (nothing proceeds without a policy).
      - Authority guard (Invoke-McpSafetyGrantGate): no circuit or
        policy output ever grants, widens or carries permission: any
        attempt to feed an MCP result into a grant path is denied.
      - Sanitized bounded telemetry to cache/v3/mcp-safety/ daily
        JSONL: pre-size accounting with rotation cap, fail-closed
        under a shared gate acquired with a BOUNDED TryEnter,
        per-field secret redaction (including sk- canaries) and
        len:value fingerprint framing in the watchdog pattern.
        Observability is best-effort: under gate contention the
        event is skipped with an honest lock-busy code and the
        refusal/completion path never blocks on telemetry.
        RELEASE_UNCONFIRMED is internal to the capacity-release path
        only and is never persisted to telemetry (the Status
        allowlist is closed and has no such code).
      - This file never reads or writes capability-flags.json and
        never touches plugins/: mcp_routing stays OFF by construction.

    PowerShell 5.1 compatible. ASCII-only. Expected domain results
    are returned as result objects ({ok, status, error, ...}), never
    thrown across the boundary.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $sanitizePath -PathType Leaf) {
    . $sanitizePath
}

$script:McpSafetyAbandonedCount = 0
$script:McpSafetyTelemetryCapBytes = 1048576
$script:McpSafetyTelemetryLock = New-Object Object
$script:McpSafetySimulateAccountingFailure = $false
$script:McpSafetySimulateReadFailure = $false
$script:McpSafetySimulateReadFailureAfterReads = -1
$script:McpSafetyStoreReadCount = 0
$script:McpSafetySettleMarginMs = 5000
$script:McpSafetyLongRunningMaxBudgetSeconds = 3600
$script:McpSafetyConvertMaxDepth = 32
$script:McpSafetyConvertMaxNodes = 10000
$script:McpSafetyConvertOverflow = $false
$script:McpSafetyConvertNodeCount = 0
$script:McpSafetyLockWaitMaxMs = 1000
$script:McpSafetyTelemetryLockWaitMs = 250
$script:McpSafetyCapacityLimit = 8
$script:McpSafetyCapacityInUse = 0
$script:McpSafetyCapacityLock = New-Object Object
$script:McpSafetyCapacityCellAvailable = $false
$script:McpSafetyCapacityCellForceUnavailable = $false

$script:McpSafetyCapacityCellCode = @'
public static class McpSafetyCapacityCell {
    public static readonly object Gate = new object();
    public static readonly object KeyGuard = new object();
    public static readonly object TelemetryGate = new object();
    public static int InUse = 0;
    public static int Limit = 8;
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> Circuits = new System.Collections.Concurrent.ConcurrentDictionary<string, string>();
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object> KeyLocks = new System.Collections.Concurrent.ConcurrentDictionary<string, object>();
    public static string CircuitRead(string key) {
        try {
            if (key == null) { return null; }
            string v = null;
            if (Circuits.TryGetValue(key, out v)) { return v; }
            return null;
        } catch { return null; }
    }
    public static int TryReadCircuit(string key, out string value) {
        try {
            if (key == null) { value = null; return -1; }
            string v = null;
            if (Circuits.TryGetValue(key, out v)) { value = v; return 1; }
            value = null;
            return 0;
        } catch { value = null; return -1; }
    }
    public static void CircuitWrite(string key, string value) {
        try {
            if (key == null) { return; }
            if (value == null) {
                string oldv = null;
                Circuits.TryRemove(key, out oldv);
            } else { Circuits[key] = value; }
        } catch { }
    }
    public static void CircuitClear() { try { Circuits.Clear(); } catch { } }
    public static object GetKeyLock(string key) {
        try {
            if (key == null) { return null; }
            return KeyLocks.GetOrAdd(key, k => new object());
        } catch { return null; }
    }
    public static void KeyLockClear() { try { KeyLocks.Clear(); } catch { } }
    public static int TryReserveBounded(int timeoutMs, out int current) {
        bool taken = false;
        try {
            System.Threading.Monitor.TryEnter(Gate, timeoutMs, ref taken);
            if (!taken) { current = InUse; return -1; }
            try {
                if (InUse >= Limit) { current = InUse; return 0; }
                InUse = InUse + 1;
                current = InUse;
                return 1;
            } finally { System.Threading.Monitor.Exit(Gate); }
        } catch { current = InUse; return -1; }
    }
    public static bool TryReleaseBounded(int timeoutMs, out int current) {
        bool taken = false;
        try {
            System.Threading.Monitor.TryEnter(Gate, timeoutMs, ref taken);
            if (!taken) { current = InUse; return false; }
            try {
                if (InUse > 0) { InUse = InUse - 1; }
                current = InUse;
                return true;
            } finally { System.Threading.Monitor.Exit(Gate); }
        } catch { current = InUse; return false; }
    }
    public static int ReadBounded(int timeoutMs) {
        bool taken = false;
        try {
            System.Threading.Monitor.TryEnter(Gate, timeoutMs, ref taken);
            if (!taken) { return -1; }
            try { return InUse; }
            finally { System.Threading.Monitor.Exit(Gate); }
        } catch { return -1; }
    }
    public static int SetForTestBounded(int n, int timeoutMs) {
        bool taken = false;
        try {
            System.Threading.Monitor.TryEnter(Gate, timeoutMs, ref taken);
            if (!taken) { return -1; }
            try {
                if (n < 0) { n = 0; }
                if (n > 1000000) { n = 1000000; }
                InUse = n;
                return InUse;
            } finally { System.Threading.Monitor.Exit(Gate); }
        } catch { return -1; }
    }
}
'@

try {
    $cellType = ([System.Management.Automation.PSTypeName]'McpSafetyCapacityCell').Type
    if ($null -eq $cellType) {
        Add-Type -TypeDefinition $script:McpSafetyCapacityCellCode -Language CSharp -ErrorAction Stop | Out-Null
        $cellType = ([System.Management.Automation.PSTypeName]'McpSafetyCapacityCell').Type
    }
    $script:McpSafetyCapacityCellAvailable = ($null -ne $cellType)
}
catch { $script:McpSafetyCapacityCellAvailable = $false }

# ---------- repo / path helpers ----------

function Get-McpSafetyRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-McpSafetyDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-McpSafetyRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\mcp-request-policy.json')
}

function New-McpSafetyError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Status, $Extra)
    $r = [ordered]@{ ok = $false; status = $Status; error = $Status; failure = $Status; settled = $true }
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

function Clear-McpSafetyState {
    <#
    .SYNOPSIS
        Resets in-memory circuit state (tests). Never throws.
    #>
    [CmdletBinding()]
    param()
    try { $script:McpSafetyConvertOverflow = $false } catch { }
    try { $script:McpSafetyConvertNodeCount = 0 } catch { }
    try {
        if (Update-McpSafetyCellAvailability) {
            try { [void][McpSafetyCapacityCell]::CircuitClear() } catch { }
            try { [void][McpSafetyCapacityCell]::KeyLockClear() } catch { }
        }
    }
    catch { }
    try { $script:McpSafetyAbandonedCount = 0 } catch { }
    try { $script:McpSafetySimulateReadFailure = $false } catch { }
    try { $script:McpSafetySimulateReadFailureAfterReads = -1 } catch { }
    try { $script:McpSafetyStoreReadCount = 0 } catch { }
    try { $script:McpSafetyCapacityCellForceUnavailable = $false } catch { }
    try { [void](Set-McpSafetyCapacityInUse -Count 0) } catch { }
}

function Update-McpSafetyCellAvailability {
    <#
    .SYNOPSIS
        Re-queries the shared capacity cell once (a concurrent
        session may have loaded it after this session). Honors the
        test-only force-unavailable flag. Never throws.
    #>
    [CmdletBinding()]
    param()
    try {
        if ([bool]$script:McpSafetyCapacityCellForceUnavailable) { return $false }
        if ([bool]$script:McpSafetyCapacityCellAvailable) { return $true }
        $t = $null
        try { $t = ([System.Management.Automation.PSTypeName]'McpSafetyCapacityCell').Type } catch { $t = $null }
        $script:McpSafetyCapacityCellAvailable = ($null -ne $t)
        return ([bool]$script:McpSafetyCapacityCellAvailable)
    }
    catch { return $false }
}

function Set-McpSafetyCapacityCellUnavailable {
    <#
    .SYNOPSIS
        TEST-ONLY seam: simulates a missing shared capacity cell.
        While forced, admission refuses fail-closed
        (MCP_CAPACITY_CELL_UNAVAILABLE) and no probe executes.
        Call with $false to restore. Never throws.
    #>
    [CmdletBinding()]
    param([bool]$Unavailable = $true)
    try {
        $script:McpSafetyCapacityCellForceUnavailable = [bool]$Unavailable
        return [PSCustomObject]@{ ok = $true; forced_unavailable = ([bool]$script:McpSafetyCapacityCellForceUnavailable) }
    }
    catch { return [PSCustomObject]@{ ok = $false; forced_unavailable = $false } }
}

function Set-McpSafetyCapacityInUse {
    <#
    .SYNOPSIS
        TEST-ONLY seam: sets the capacity occupancy counter
        directly (in-flight reservations plus abandons). Production
        code never calls this; it exists so tests can deterministically
        reach the capacity cap without leaking real runspaces.
        Occupancy is never reclaimed except by proven settlement or
        this hook. Bounded Gate acquisition; failure returns ok=false.
        Never throws.
    #>
    [CmdletBinding()]
    param([int]$Count = 0)
    try {
        $n = [int]$Count
        if ($n -lt 0) { $n = 0 }
        if ($n -gt 1000000) { $n = 1000000 }
        if (Update-McpSafetyCellAvailability) {
            try {
                $v = [int][McpSafetyCapacityCell]::SetForTestBounded($n, 1000)
                if ($v -lt 0) { return [PSCustomObject]@{ ok = $false; occupancy = (Get-McpSafetyCapacityInUse) } }
                return [PSCustomObject]@{ ok = $true; occupancy = $v }
            }
            catch { return [PSCustomObject]@{ ok = $false; occupancy = (Get-McpSafetyCapacityInUse) } }
        }
        else {
            $script:McpSafetyCapacityInUse = $n
        }
        return [PSCustomObject]@{ ok = $true; occupancy = (Get-McpSafetyCapacityInUse) }
    }
    catch { return [PSCustomObject]@{ ok = $false; occupancy = -1 } }
}

function Get-McpSafetyCapacityInUse {
    <#
    .SYNOPSIS
        Reads the capacity occupancy counter through a BOUNDED Gate
        acquisition (shared process-wide cell when loaded, else this
        session only). Returns -1 (UNKNOWN) when the Gate cannot be
        acquired within the bound. No lib path blocks on Gate. Never
        throws.
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 1000)
    try {
        $ms = [int]$TimeoutMs
        if ($ms -lt 0) { $ms = 0 }
        if ($ms -gt 10000) { $ms = 10000 }
        if (Update-McpSafetyCellAvailability) {
            try { return ([int][McpSafetyCapacityCell]::ReadBounded($ms)) } catch { return -1 }
        }
        try { return ([int]$script:McpSafetyCapacityInUse) } catch { return -1 }
    }
    catch { return -1 }
}

function Request-McpSafetyCapacity {
    <#
    .SYNOPSIS
        Atomically reserves one capacity unit. Returns @{admitted,
        reason, occupancy}: admitted, or full
        (MCP_ABANDON_LIMIT_REACHED), or global-busy
        (MCP_BUSY_GLOBAL). Lock order: this global step always runs
        BEFORE any per-key lock acquisition. Never throws.
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 1000)
    try {
        $ms = [int]$TimeoutMs
        if ($ms -lt 0) { $ms = 0 }
        if ($ms -gt 10000) { $ms = 10000 }
        if (-not (Update-McpSafetyCellAvailability)) {
            return [PSCustomObject]@{ admitted = $false; reason = 'MCP_CAPACITY_CELL_UNAVAILABLE'; occupancy = (Get-McpSafetyCapacityInUse) }
        }
        try {
            $cur = 0
            $rc = [McpSafetyCapacityCell]::TryReserveBounded($ms, [ref]$cur)
            if ([int]$rc -eq 1) { return [PSCustomObject]@{ admitted = $true; reason = ''; occupancy = [int]$cur } }
            if ([int]$rc -eq 0) { return [PSCustomObject]@{ admitted = $false; reason = 'MCP_ABANDON_LIMIT_REACHED'; occupancy = [int]$cur } }
            return [PSCustomObject]@{ admitted = $false; reason = 'MCP_BUSY_GLOBAL'; occupancy = [int]$cur }
        }
        catch { return [PSCustomObject]@{ admitted = $false; reason = 'MCP_BUSY_GLOBAL'; occupancy = (Get-McpSafetyCapacityInUse) } }
    }
    catch { return [PSCustomObject]@{ admitted = $false; reason = 'MCP_BUSY_GLOBAL'; occupancy = -1 } }
}

function Release-McpSafetyCapacity {
    <#
    .SYNOPSIS
        Releases one capacity unit after proven settlement. Called
        only AFTER the per-key lock is exited (lock order). Bounded
        retries; a failed release leaves the unit occupied (safe
        direction). Never throws.
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 1000)
    try {
        $ms = [int]$TimeoutMs
        if ($ms -lt 0) { $ms = 0 }
        if ($ms -gt 10000) { $ms = 10000 }
        if (-not (Update-McpSafetyCellAvailability)) {
            return [PSCustomObject]@{ released = $true; status = 'RELEASED'; occupancy = (Get-McpSafetyCapacityInUse) }
        }
        for ($i = 0; $i -lt 3; $i++) {
            try {
                $cur = 0
                $ok = [McpSafetyCapacityCell]::TryReleaseBounded($ms, [ref]$cur)
                if ([bool]$ok) { return [PSCustomObject]@{ released = $true; status = 'RELEASED'; occupancy = [int]$cur } }
            }
            catch { }
        }
        $readBack = -1
        try { $readBack = (Get-McpSafetyCapacityInUse -TimeoutMs $ms) } catch { $readBack = -1 }
        return [PSCustomObject]@{ released = $false; status = 'RELEASE_UNCONFIRMED'; occupancy = $readBack }
    }
    catch { return [PSCustomObject]@{ released = $false; status = 'RELEASE_UNCONFIRMED'; occupancy = -1 } }
}

# ---------- strict policy load ----------

function ConvertTo-McpSafetyOrdered {
    <#
    .SYNOPSIS
        Copies a policy tree into ordered dictionaries. BOUNDED:
        max depth 32, max 10000 nodes, reference-cycle detection
        for dictionaries and enumerables. On bound breach sets
        $script:McpSafetyConvertOverflow and returns $null (every
        policy-load caller treats that as malformed fail-closed).
        Never throws.
    #>
    [CmdletBinding()]
    param($Node, [int]$Depth = 0, $Seen = $null)
    try {
        if ([int]$Depth -eq 0) {
            $script:McpSafetyConvertOverflow = $false
            $script:McpSafetyConvertNodeCount = 0
            $Seen = @()
        }
        try { $script:McpSafetyConvertNodeCount = ([int]$script:McpSafetyConvertNodeCount + 1) } catch { }
        if ([int]$script:McpSafetyConvertNodeCount -gt [int]$script:McpSafetyConvertMaxNodes) {
            $script:McpSafetyConvertOverflow = $true
            return $null
        }
        if ([int]$Depth -gt [int]$script:McpSafetyConvertMaxDepth) {
            $script:McpSafetyConvertOverflow = $true
            return $null
        }
        if ($null -eq $Node) { return $null }
        if ($Node -is [string]) { return [string]$Node }
        if ($Node -is [bool]) { return [bool]$Node }
        $isRef = (($Node -is [System.Collections.IDictionary]) -or ($Node -is [System.Collections.IEnumerable]) -or ($Node -is [PSCustomObject]))
        if ($isRef -and ($null -ne $Seen)) {
            foreach ($s in @($Seen)) {
                $same = $false
                try { $same = [object]::ReferenceEquals($s, $Node) } catch { $same = $false }
                if ([bool]$same) {
                    $script:McpSafetyConvertOverflow = $true
                    return $null
                }
            }
        }
        if ($Node -is [System.Collections.IDictionary]) {
            $childSeen = (New-Object System.Collections.ArrayList)
            foreach ($s in @($Seen)) { [void]$childSeen.Add($s) }
            [void]$childSeen.Add($Node)
            $o = [ordered]@{}
            foreach ($k in @($Node.Keys)) {
                $o[[string]$k] = (ConvertTo-McpSafetyOrdered -Node $Node[$k] -Depth ([int]$Depth + 1) -Seen $childSeen)
                if ([bool]$script:McpSafetyConvertOverflow) { return $null }
            }
            return $o
        }
        if ($Node -is [System.ValueType]) { return $Node }
        if ($Node -is [System.Collections.IEnumerable]) {
            $childSeen = (New-Object System.Collections.ArrayList)
            foreach ($s in @($Seen)) { [void]$childSeen.Add($s) }
            [void]$childSeen.Add($Node)
            $a = @()
            foreach ($e in $Node) {
                $a += (ConvertTo-McpSafetyOrdered -Node $e -Depth ([int]$Depth + 1) -Seen $childSeen)
                if ([bool]$script:McpSafetyConvertOverflow) { return $null }
            }
            return $a
        }
        $childSeen = (New-Object System.Collections.ArrayList)
        foreach ($s in @($Seen)) { [void]$childSeen.Add($s) }
        [void]$childSeen.Add($Node)
        $o = [ordered]@{}
        foreach ($p in @($Node.PSObject.Properties)) {
            $o[$p.Name] = (ConvertTo-McpSafetyOrdered -Node $p.Value -Depth ([int]$Depth + 1) -Seen $childSeen)
            if ([bool]$script:McpSafetyConvertOverflow) { return $null }
        }
        return $o
    }
    catch {
        $script:McpSafetyConvertOverflow = $true
        return $null
    }
}

function Read-McpSafetyPolicy {
    <#
    .SYNOPSIS
        Reads the canonical policy file. Returns @{found, malformed,
        doc}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $out = @{ found = $false; malformed = $false; doc = $null }
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-McpSafetyDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $out.found = $true
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $doc) { $out.malformed = $true; return $out }
        $rec = ConvertTo-McpSafetyOrdered -Node $doc
        try { if ([bool]$script:McpSafetyConvertOverflow) { $out.malformed = $true; return $out } } catch { $out.malformed = $true; return $out }
        if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { $out.malformed = $true; return $out }
        $out.doc = $rec
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Test-McpSafetyInt {
    <#
    .SYNOPSIS
        Strict integer check: only [int]/[long] (never bool/string/
        double), within [Min, Max]. Never throws.
    #>
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

function Get-McpSafetyPolicyNode {
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

function Assert-McpSafetyPolicyJson {
    <#
    .SYNOPSIS
        Validates the canonical policy file. Returns @{valid,
        errors}. Exact execution budgets (advisory 30, memory 60,
        remote 120), long_running under explicit contract only,
        failure_threshold exactly 2, cooldown in [60,1800],
        criticality exactly {optional, required} defaulting to
        optional. Never throws.
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
        $rec = ConvertTo-McpSafetyOrdered -Node $doc
        try { if ([bool]$script:McpSafetyConvertOverflow) { $errors.Add('unbounded-tree') | Out-Null } } catch { $errors.Add('unbounded-tree') | Out-Null }
        if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) {
            $errors.Add('root-must-be-object') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        try { if ([int]$rec['version'] -ne 1) { $errors.Add('version-must-be-1') | Out-Null } }
        catch { $errors.Add('version-must-be-1') | Out-Null }
        $classes = Get-McpSafetyPolicyNode -Doc $rec -Name 'classes'
        if (($null -eq $classes) -or (-not ($classes -is [System.Collections.IDictionary]))) {
            $errors.Add('classes-missing') | Out-Null
        }
        else {
            $wantExec = [ordered]@{ 'advisory' = 30; 'memory' = 60; 'remote' = 120 }
            foreach ($ck in @($wantExec.Keys)) {
                $slot = Get-McpSafetyPolicyNode -Doc $classes -Name ([string]$ck)
                if (($null -eq $slot) -or (-not ($slot -is [System.Collections.IDictionary]))) {
                    $errors.Add(('class-missing:' + [string]$ck)) | Out-Null
                    continue
                }
                $ex = Get-McpSafetyPolicyNode -Doc $slot -Name 'execution_timeout_seconds'
                if (-not (Test-McpSafetyInt -Value $ex -Min 1 -Max 3600)) {
                    $errors.Add(('class-not-int:' + [string]$ck + ':execution_timeout_seconds')) | Out-Null
                }
                elseif ([int]$ex -ne [int]$wantExec[$ck]) {
                    $errors.Add(('class-budget-mismatch:' + [string]$ck + ':' + [string]$ex)) | Out-Null
                }
                $co = Get-McpSafetyPolicyNode -Doc $slot -Name 'connect_timeout_seconds'
                if (-not (Test-McpSafetyInt -Value $co -Min 1 -Max 120)) {
                    $errors.Add(('class-not-int:' + [string]$ck + ':connect_timeout_seconds')) | Out-Null
                }
                elseif ([int]$co -gt [int]$wantExec[$ck]) {
                    $errors.Add(('class-connect-exceeds-execution:' + [string]$ck)) | Out-Null
                }
            }
            $lr = Get-McpSafetyPolicyNode -Doc $classes -Name 'long_running'
            if (($null -eq $lr) -or (-not ($lr -is [System.Collections.IDictionary]))) {
                $errors.Add('class-missing:long_running') | Out-Null
            }
            else {
                $lex = Get-McpSafetyPolicyNode -Doc $lr -Name 'execution_timeout_seconds'
                if ($null -eq $lex) { $errors.Add('long_running-execution-missing') | Out-Null }
                elseif (($lex -is [int] -or $lex -is [long]) -and ([long]$lex -eq 0)) { }
                else { $errors.Add('long_running-execution-must-be-0') | Out-Null }
                $lreq = Get-McpSafetyPolicyNode -Doc $lr -Name 'requires_explicit_task_contract'
                if (-not ($lreq -is [bool]) -or (-not [bool]$lreq)) {
                    $errors.Add('long_running-must-require-contract') | Out-Null
                }
                $lco = Get-McpSafetyPolicyNode -Doc $lr -Name 'connect_timeout_seconds'
                if (-not (Test-McpSafetyInt -Value $lco -Min 1 -Max 120)) {
                    $errors.Add('class-not-int:long_running:connect_timeout_seconds') | Out-Null
                }
            }
        }
        $aliases = Get-McpSafetyPolicyNode -Doc $rec -Name 'class_aliases'
        if (($null -eq $aliases) -or (-not ($aliases -is [System.Collections.IDictionary]))) {
            $errors.Add('class_aliases-missing') | Out-Null
        }
        else {
            $jv = Get-McpSafetyPolicyNode -Doc $aliases -Name 'jev'
            if (([string]$jv).Trim() -cne 'advisory') { $errors.Add('alias-jev-must-map-advisory') | Out-Null }
        }
        $ft = Get-McpSafetyPolicyNode -Doc $rec -Name 'failure_threshold'
        if (-not (Test-McpSafetyInt -Value $ft -Min 1 -Max 100)) {
            $errors.Add('failure_threshold-not-int') | Out-Null
        }
        elseif ([int]$ft -ne 2) {
            $errors.Add('failure_threshold-must-be-2') | Out-Null
        }
        $circuit = Get-McpSafetyPolicyNode -Doc $rec -Name 'circuit'
        if (($null -eq $circuit) -or (-not ($circuit -is [System.Collections.IDictionary]))) {
            $errors.Add('circuit-missing') | Out-Null
        }
        else {
            $cd = Get-McpSafetyPolicyNode -Doc $circuit -Name 'cooldown_seconds'
            if (-not (Test-McpSafetyInt -Value $cd -Min 60 -Max 1800)) {
                $errors.Add('circuit-cooldown-invalid') | Out-Null
            }
        }
        $crit = Get-McpSafetyPolicyNode -Doc $rec -Name 'criticality'
        if (($null -eq $crit) -or (-not ($crit -is [System.Collections.IDictionary]))) {
            $errors.Add('criticality-missing') | Out-Null
        }
        else {
            $allowed = Get-McpSafetyPolicyNode -Doc $crit -Name 'allowed'
            $names = @()
            if ($null -ne $allowed) {
                foreach ($e in @($allowed)) { $names += ([string]$e).Trim() }
            }
            if ((@($names).Count -ne 2) -or ($names -notcontains 'optional') -or ($names -notcontains 'required')) {
                $errors.Add('criticality-allowed-must-be-optional-required') | Out-Null
            }
            $dflt = ([string](Get-McpSafetyPolicyNode -Doc $crit -Name 'default')).Trim()
            if ($dflt -cne 'optional') { $errors.Add('criticality-default-must-be-optional') | Out-Null }
        }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

function Test-McpSafetyPolicyFull {
    <#
    .SYNOPSIS
        Full policy gate reusing the file validator. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $r = Assert-McpSafetyPolicyJson -Path $Path
        return ([bool]$r.valid)
    }
    catch { return $false }
}

# ---------- closed input validation ----------

function Test-McpSafetyServerId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{0,63}$')
    }
    catch { return $false }
}

function Test-McpSafetyCapabilityId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 64) { return $false }
        return ($v -match '^[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)+$')
    }
    catch { return $false }
}

function Test-McpSafetyTurnId {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Get-McpSafetyNormalizedClass {
    [CmdletBinding()]
    param([string]$Class)
    try {
        $c = ([string]$Class).Trim().ToLowerInvariant()
        if ($c -ceq 'jev') { return 'advisory' }
        if (@('advisory', 'memory', 'remote', 'long_running') -ccontains $c) { return $c }
        return ''
    }
    catch { return '' }
}

function Get-McpSafetyUtcNow {
    [CmdletBinding()]
    param($AtUtc)
    try {
        if ($null -ne $AtUtc) {
            if ($AtUtc -is [DateTime]) { return ([DateTime]$AtUtc).ToUniversalTime() }
            $s = ([string]$AtUtc).Trim()
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $dto = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($s, [ref]$dto)) { return $dto.UtcDateTime }
            }
        }
    }
    catch { }
    try { return ((Get-Date).ToUniversalTime()) }
    catch { return ([DateTime]::UtcNow) }
}

function Get-McpSafetyClassBudget {
    <#
    .SYNOPSIS
        Resolves the per-class, per-phase budget seconds from policy.
        Phase connect|execute. Never throws; invalid policy fails
        closed with MCP_POLICY_INVALID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Class,
        [string]$Phase = 'execute',
        [string]$PolicyPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $c = Get-McpSafetyNormalizedClass -Class $Class
        if ([string]::IsNullOrWhiteSpace($c)) {
            return (New-McpSafetyError -Status 'INVALID_CLASS' -Extra @{ class = ([string]$Class) })
        }
        $ph = ([string]$Phase).Trim().ToLowerInvariant()
        if (($ph -cne 'connect') -and ($ph -cne 'execute')) {
            return (New-McpSafetyError -Status 'INVALID_PHASE' -Extra @{ phase = ([string]$Phase) })
        }
        if (($c -ceq 'long_running') -and ($ph -ceq 'execute')) {
            return (New-McpSafetyError -Status 'MCP_LONG_RUNNING_REQUIRES_CONTRACT')
        }
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-McpSafetyDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-McpSafetyPolicyFull -Path $pp)) {
            return (New-McpSafetyError -Status 'MCP_POLICY_INVALID')
        }
        $slot = Read-McpSafetyPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$slot.found) { return (New-McpSafetyError -Status 'MCP_POLICY_INVALID') }
        if ([bool]$slot.malformed) { return (New-McpSafetyError -Status 'MCP_POLICY_INVALID') }
        $classes = Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'classes'
        $entry = Get-McpSafetyPolicyNode -Doc $classes -Name $c
        $field = 'execution_timeout_seconds'
        if ($ph -ceq 'connect') { $field = 'connect_timeout_seconds' }
        $secs = Get-McpSafetyPolicyNode -Doc $entry -Name $field
        if (-not (Test-McpSafetyInt -Value $secs -Min 1 -Max 3600)) {
            return (New-McpSafetyError -Status 'MCP_POLICY_INVALID')
        }
        $ft = Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'failure_threshold'
        $cd = 300
        try {
            $cn = Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'circuit'
            $cd = [int](Get-McpSafetyPolicyNode -Doc $cn -Name 'cooldown_seconds')
        }
        catch { $cd = 300 }
        return [PSCustomObject]@{
            ok = $true; status = 'OK'; error = ''
            class = $c; phase = $ph
            budget_s = [int]$secs
            failure_threshold = [int]$ft
            cooldown_s = [int]$cd
        }
    }
    catch { return (New-McpSafetyError -Status 'MCP_POLICY_INVALID') }
}

# ---------- circuit ----------

function Get-McpSafetyCircuitKey {
    [CmdletBinding()]
    param([string]$Server, [string]$Capability, [string]$TurnId)
    $s = ([string]$Server).Trim()
    $c = ([string]$Capability).Trim().ToLowerInvariant()
    $t = ([string]$TurnId).Trim()
    return ($s + "`0" + $c + "`0" + $t)
}

function Get-McpSafetyCircuitSharedAvailable {
    <#
    .SYNOPSIS
        Reports whether the process-shared circuit store (C# cell
        Circuits plus KeyLocks) is usable. Never throws.
    #>
    [CmdletBinding()]
    param()
    try {
        if (-not (Update-McpSafetyCellAvailability)) { return $false }
        $t = $null
        try { $t = ([System.Management.Automation.PSTypeName]'McpSafetyCapacityCell').Type } catch { $t = $null }
        if ($null -eq $t) { return $false }
        try { if ($null -eq $t.GetMethod('CircuitRead')) { return $false } } catch { return $false }
        try { if ($null -eq $t.GetMethod('GetKeyLock')) { return $false } } catch { return $false }
        return $true
    }
    catch { return $false }
}

function ConvertTo-McpSafetyCircuitWire {
    <#
    .SYNOPSIS
        Encodes a circuit record as STATE|consecutive|stamp for the
        shared store. Never throws.
    #>
    [CmdletBinding()]
    param([string]$State, [int]$Consecutive, $OpenedAtUtc)
    try {
        $st = ([string]$State).Trim().ToUpperInvariant()
        if (@('OPEN', 'HALF_OPEN', 'CLOSED') -cnotcontains $st) { $st = 'CLOSED' }
        $stamp = ConvertTo-McpSafetyStamp -Value $OpenedAtUtc
        return ($st + '|' + ([string][int]$Consecutive) + '|' + $stamp)
    }
    catch { return 'CLOSED|0|' }
}

function ConvertFrom-McpSafetyCircuitWire {
    <#
    .SYNOPSIS
        Decodes a shared-store circuit wire value with EXACT format
        validation: at most 4096 chars (longer refuses before any
        Split allocation), exactly 3 pipe fields, state in
        {CLOSED,OPEN,HALF_OPEN}, consecutive an integer 0..1000000,
        stamp empty for CLOSED and a parseable UTC instant for
        OPEN/HALF_OPEN. Anything else yields valid=$false (callers
        fail closed: Invoke refuses, observability reports UNKNOWN).
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Wire)
    try {
        $raw = ([string]$Wire)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
        }
        if ([int]$raw.Length -gt 4096) {
            return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
        }
        $parts = @($raw.Split('|'))
        if (@($parts).Count -ne 3) {
            return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
        }
        $st = ([string]$parts[0]).Trim().ToUpperInvariant()
        if (@('OPEN', 'HALF_OPEN', 'CLOSED') -cnotcontains $st) {
            return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
        }
        $consec = -1
        try {
            $ntext = ([string]$parts[1]).Trim()
            if ($ntext -cmatch '^[0-9]+$') {
                $nn = [long]$ntext
                if (($nn -ge 0) -and ($nn -le 1000000)) { $consec = [int]$nn }
            }
        }
        catch { $consec = -1 }
        if ($consec -lt 0) {
            return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
        }
        $stamp = ([string]$parts[2])
        if (($st -ceq 'OPEN') -or ($st -ceq 'HALF_OPEN')) {
            if ([string]::IsNullOrWhiteSpace($stamp)) {
                return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
            }
            $dto = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse($stamp, [ref]$dto)) {
                return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
            }
            $stamp = ($dto.UtcDateTime.ToString('o'))
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($stamp)) {
                return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' }
            }
            $stamp = ''
        }
        return [PSCustomObject]@{ valid = $true; state = $st; consecutive = $consec; opened_at_utc = $stamp }
    }
    catch { return [PSCustomObject]@{ valid = $false; state = 'UNKNOWN'; consecutive = 0; opened_at_utc = '' } }
}

function Read-McpSafetyCircuitStore {
    <#
    .SYNOPSIS
        Reads one shared circuit record distinguishing ABSENCE
        (ok plus found=false, legitimately CLOSED) from READ
        FAILURE (ok=false, fail-closed UNKNOWN). Honors the
        test-only $script:McpSafetySimulateReadFailure seam
        (default false, never enabled in production) or the
        $script:McpSafetySimulateReadFailureAfterReads countdown
        (fail reads after the first N succeed; -1 disables).
        Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)
    try {
        try {
            $afterReads = -1
            try { $afterReads = [int]$script:McpSafetySimulateReadFailureAfterReads } catch { $afterReads = -1 }
            if ([int]$afterReads -ge 0) {
                try { $script:McpSafetyStoreReadCount = ([int]$script:McpSafetyStoreReadCount + 1) } catch { $script:McpSafetyStoreReadCount = 1 }
                if ([int]$script:McpSafetyStoreReadCount -gt [int]$afterReads) {
                    return @{ ok = $false; found = $false; wire = $null }
                }
            }
        }
        catch { }
        try {
            if ([bool]$script:McpSafetySimulateReadFailure) {
                return @{ ok = $false; found = $false; wire = $null }
            }
        }
        catch { }
        $val = $null
        $rc = -1
        try { $rc = [McpSafetyCapacityCell]::TryReadCircuit($Key, [ref]$val) } catch { $rc = -1 }
        if ([int]$rc -eq 1) {
            return @{ ok = $true; found = $true; wire = ([string]$val) }
        }
        if ([int]$rc -eq 0) {
            return @{ ok = $true; found = $false; wire = $null }
        }
        return @{ ok = $false; found = $false; wire = $null }
    }
    catch { return @{ ok = $false; found = $false; wire = $null } }
}

function Get-McpSafetyCircuitState {
    <#
    .SYNOPSIS
        Reports the circuit for (server, capability, turn): CLOSED,
        OPEN or HALF_OPEN (cooldown expired, one probe allowed), or
        honest UNKNOWN when the shared record is malformed or the
        shared store is unavailable (never a silent local CLOSED).
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Capability,
        [Parameter(Mandatory = $true)][string]$TurnId,
        $NowUtc = $null,
        [int]$CooldownSeconds = 300,
        [int]$FailureThreshold = 2
    )
    try {
        $now = Get-McpSafetyUtcNow -AtUtc $NowUtc
        $key = Get-McpSafetyCircuitKey -Server $Server -Capability $Capability -TurnId $TurnId
        $cd = [int]$CooldownSeconds
        if ($cd -lt 1) { $cd = 300 }
        $entryState = 'CLOSED'
        $consecInit = 0
        $stampInit = ''
        $haveEntry = $false
        if (Get-McpSafetyCircuitSharedAvailable) {
            $rd = Read-McpSafetyCircuitStore -Key $key
            if (-not [bool]$rd.ok) {
                return [PSCustomObject]@{
                    state = 'UNKNOWN'; consecutive = 0; opened_at_utc = ''
                    cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
                }
            }
            if (-not [bool]$rd.found) {
                return [PSCustomObject]@{
                    state = 'CLOSED'; consecutive = 0; opened_at_utc = ''
                    cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
                }
            }
            $dec = ConvertFrom-McpSafetyCircuitWire -Wire ([string]$rd.wire)
            if (-not [bool]$dec.valid) {
                return [PSCustomObject]@{
                    state = 'UNKNOWN'; consecutive = 0; opened_at_utc = ''
                    cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
                }
            }
            $entryState = ([string]$dec.state)
            $consecInit = ([int]$dec.consecutive)
            $stampInit = ([string]$dec.opened_at_utc)
            $haveEntry = $true
        }
        else {
            return [PSCustomObject]@{
                state = 'UNKNOWN'; consecutive = 0; opened_at_utc = ''
                cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
            }
        }
        if (-not [bool]$haveEntry) {
            return [PSCustomObject]@{
                state = 'CLOSED'; consecutive = 0; opened_at_utc = ''
                cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
            }
        }
        $consec = $consecInit
        $st = $entryState
        if ($st -cne 'OPEN') {
            return [PSCustomObject]@{
                state = 'CLOSED'; consecutive = $consec; opened_at_utc = ''
                cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
            }
        }
        $opened = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($stampInit)) { $opened = [DateTime]$stampInit }
        }
        catch { $opened = $null }
        try {
            if ($null -ne $opened) { $opened = (([DateTime]$opened).ToUniversalTime()) }
        }
        catch { }
        $stamp = ''
        try { $stamp = ([DateTime]$opened).ToUniversalTime().ToString('o') } catch { $stamp = '' }
        if (($null -ne $opened) -and ($now -ge (([DateTime]$opened).AddSeconds([double]$cd)))) {
            return [PSCustomObject]@{
                state = 'HALF_OPEN'; consecutive = $consec; opened_at_utc = $stamp
                cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
            }
        }
        return [PSCustomObject]@{
            state = 'OPEN'; consecutive = $consec; opened_at_utc = $stamp
            cooldown_s = $cd; failure_threshold = [int]$FailureThreshold
        }
    }
    catch {
        return [PSCustomObject]@{
            state = 'UNKNOWN'; consecutive = 0; opened_at_utc = ''
            cooldown_s = 300; failure_threshold = 2
        }
    }
}

function Set-McpSafetyCircuitRecord {
    <#
    .SYNOPSIS
        Writes the circuit record to the process-shared store when
        available. Circuit records live ONLY in the private shared
        cell (accessed via its methods, never via script-scope
        dictionaries). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Key, [int]$Consecutive, [string]$State, $OpenedAtUtc)
    try {
        $st = ([string]$State).Trim().ToUpperInvariant()
        if (@('OPEN', 'HALF_OPEN', 'CLOSED') -cnotcontains $st) { $st = 'CLOSED' }
        $wire = ConvertTo-McpSafetyCircuitWire -State $st -Consecutive ([int]$Consecutive) -OpenedAtUtc $OpenedAtUtc
        if (Get-McpSafetyCircuitSharedAvailable) {
            try { [void][McpSafetyCapacityCell]::CircuitWrite($Key, $wire) } catch { }
        }
    }
    catch { }
}

function Get-McpSafetySharedGate {
    <#
    .SYNOPSIS
        Returns a process-shared gate object (KeyGuard or
        TelemetryGate) from the capacity cell, or $null when the
        cell is unavailable (callers use their session-local
        fallback, still with bounded acquisition). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        if (-not (Update-McpSafetyCellAvailability)) { return $null }
        $f = $null
        try { $f = ([System.Management.Automation.PSTypeName]'McpSafetyCapacityCell').Type.GetField($Name) } catch { $f = $null }
        if ($null -eq $f) { return $null }
        return $f.GetValue($null)
    }
    catch { return $null }
}

function Get-McpSafetyCircuitLock {
    <#
    .SYNOPSIS
        Returns the per-circuit Monitor lock object from the private
        process-shared cell (every runspace in this process sees one
        probe per key), created once under the shared KeyGuard
        acquired with a BOUNDED TryEnter (lock order global-guard
        first, per-key second). Returns $null when the shared store
        or guard is unavailable, or the guard cannot be acquired in
        bound (callers refuse fail-closed without running the seam).
        No session-local fallback: per-key locks live ONLY in the
        shared cell. In-process only (HOLD). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key, [int]$TimeoutMs = 1000)
    try {
        $ms = [int]$TimeoutMs
        if ($ms -lt 0) { $ms = 0 }
        if ($ms -gt 10000) { $ms = 10000 }
        $guard = Get-McpSafetySharedGate -Name 'KeyGuard'
        if ($null -eq $guard) { return $null }
        $taken = $false
        try {
            [void][System.Threading.Monitor]::TryEnter($guard, $ms, [ref]$taken)
            if (-not [bool]$taken) { return $null }
            try {
                if (-not (Get-McpSafetyCircuitSharedAvailable)) { return $null }
                $shared = $null
                try { $shared = [McpSafetyCapacityCell]::GetKeyLock($Key) } catch { $shared = $null }
                if ($null -eq $shared) { return $null }
                return $shared
            }
            finally {
                try { [System.Threading.Monitor]::Exit($guard) } catch { }
            }
        }
        catch { return $null }
    }
    catch {
        return $null
    }
}

function ConvertTo-McpSafetyStamp {
    <#
    .SYNOPSIS
        Normalizes an opened_at value (DateTime or ISO string) to a
        canonical UTC round-trip string for generation comparison.
        Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return '' }
        if ($Value -is [DateTime]) {
            return (([DateTime]$Value).ToUniversalTime().ToString('o'))
        }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($s, [ref]$dto)) {
            return (($dto.UtcDateTime).ToString('o'))
        }
        return $s
    }
    catch { return ([string]$Value) }
}

function Set-McpSafetyCircuitClosedIfGeneration {
    <#
    .SYNOPSIS
        Guarded close: resets to CLOSED only when the live record
        still belongs to the expected generation (opened_at plus
        consecutive). A stale success never overwrites a newer OPEN.
        A missing or malformed shared record, an unreadable store,
        or an unavailable store leaves everything untouched and
        returns $false (never writes). Returns $true when closed.
        Callers must hold the per-key lock. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$ExpectedOpenedAtUtc = '',
        [int]$ExpectedConsecutive = 0
    )
    try {
        $liveState = 'MISSING'
        $liveStamp = ''
        $liveConsec = 0
        if (Get-McpSafetyCircuitSharedAvailable) {
            $rdc = Read-McpSafetyCircuitStore -Key $Key
            if (-not [bool]$rdc.ok) { return $false }
            if (-not [bool]$rdc.found) {
                Set-McpSafetyCircuitRecord -Key $Key -Consecutive 0 -State 'CLOSED' -OpenedAtUtc $null
                return $true
            }
            $dec = ConvertFrom-McpSafetyCircuitWire -Wire ([string]$rdc.wire)
            if (-not [bool]$dec.valid) { return $false }
            $liveState = ([string]$dec.state)
            $liveStamp = ([string]$dec.opened_at_utc)
            $liveConsec = ([int]$dec.consecutive)
        }
        else {
            return $false
        }
        $st = $liveState
        if ($st -cne 'OPEN') {
            Set-McpSafetyCircuitRecord -Key $Key -Consecutive 0 -State 'CLOSED' -OpenedAtUtc $null
            return $true
        }
        $wantStamp = ConvertTo-McpSafetyStamp -Value $ExpectedOpenedAtUtc
        if (($liveStamp -ceq $wantStamp) -and ($liveConsec -eq [int]$ExpectedConsecutive)) {
            Set-McpSafetyCircuitRecord -Key $Key -Consecutive 0 -State 'CLOSED' -OpenedAtUtc $null
            return $true
        }
        return $false
    }
    catch { return $false }
}

function Get-McpSafetyProbeErrorRedaction {
    <#
    .SYNOPSIS
        Redacts and truncates probe error text before it crosses the
        result boundary (probe content never travels raw). Never
        throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = Get-McpSafetyFieldRedaction -Value ([string]$Value)
        if ($s.Length -gt 256) { $s = $s.Substring(0, 256) }
        return $s
    }
    catch { return '[REDACTED]' }
}

# ---------- sanitized fingerprint (watchdog pattern) ----------

function Get-McpSafetyFieldRedaction {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = ([string]$Value)
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
    catch { return ([string]$Value) }
}

function Get-McpSafetyCallFingerprint {
    <#
    .SYNOPSIS
        Canonical sha256 over len:value-framed sanitized
        server|capability|turn. Only the hex digest is returned.
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Server, [string]$Capability, [string]$TurnId)
    try {
        $s = ([string]$Server).Trim().ToLowerInvariant() -replace '\s+', ' '
        $s = Get-McpSafetyFieldRedaction -Value $s
        if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
        $c = ([string]$Capability).Trim().ToLowerInvariant() -replace '\s+', ' '
        $c = Get-McpSafetyFieldRedaction -Value $c
        if ($c.Length -gt 64) { $c = $c.Substring(0, 64) }
        $t = ([string]$TurnId).Trim() -replace '\s+', ' '
        $t = Get-McpSafetyFieldRedaction -Value $t
        if ($t.Length -gt 64) { $t = $t.Substring(0, 64) }
        if ([string]::IsNullOrWhiteSpace($s) -or [string]::IsNullOrWhiteSpace($c)) { return '' }
        $joined = ([string]$s.Length) + ':' + $s + '|' + ([string]$c.Length) + ':' + $c + '|' + ([string]$t.Length) + ':' + $t
        $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($bytes) }
        finally { try { $sha.Dispose() } catch { } }
        return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
    }
    catch { return '' }
}

# ---------- sanitized bounded telemetry ----------

function Get-McpSafetyTelemetryFile {
    [CmdletBinding()]
    param([string]$TelemetryRoot, [string]$RepoRoot)
    try {
        $dir = $TelemetryRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $repo = Get-McpSafetyRepoRoot -RepoRoot $RepoRoot
            $dir = Join-Path $repo 'cache\v3\mcp-safety'
        }
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $dir ('mcp-safety-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-McpSafetyTelemetryEvent {
    <#
    .SYNOPSIS
        Appends one sanitized event to the daily mcp-safety JSONL.
        Check (pre-size accounting) plus append run atomically under
        a shared gate acquired with a BOUNDED TryEnter (best-effort
        observability: under contention the event is SKIPPED with an
        honest lock-busy code and the caller path never blocks).
        Fail-closed: mkdir failure, accounting failure or overflow
        refuse the write. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Capability,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [string]$Class = '',
        [string]$Criticality = '',
        [string]$Status = '',
        [int]$ElapsedMs = 0,
        [int]$BudgetS = 0,
        [int]$Consecutive = 0,
        [string]$Circuit = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = ''
    )
    try {
        $allowed = @('MCP_CALL_OK', 'MCP_TIMEOUT', 'MCP_NETWORK_ERROR', 'MCP_ERROR', 'MCP_UNAVAILABLE', 'MCP_REQUIRED_BLOCKED', 'MCP_CIRCUIT_OPEN', 'MCP_CIRCUIT_CLOSED', 'MCP_POLICY_INVALID', 'MCP_LONG_RUNNING_REQUIRES_CONTRACT', 'MCP_PROBE_ABANDONED', 'MCP_LOCK_BUSY', 'MCP_BUSY_GLOBAL', 'MCP_ABANDON_LIMIT_REACHED', 'MCP_CAPACITY_CELL_UNAVAILABLE')
        $ev = ([string]$EventName).Trim().ToUpperInvariant()
        if ($allowed -cnotcontains $ev) {
            return [PSCustomObject]@{ ok = $false; skipped = 'bad-event' }
        }
        $srv = Get-McpSafetyFieldRedaction -Value ([string]$Server)
        if ($srv.Length -gt 64) { $srv = $srv.Substring(0, 64) }
        $cap = Get-McpSafetyFieldRedaction -Value ([string]$Capability)
        if ($cap.Length -gt 64) { $cap = $cap.Substring(0, 64) }
        $clsRaw = ([string]$Class).Trim().ToLowerInvariant()
        if (@('', 'advisory', 'memory', 'remote', 'long_running') -cnotcontains $clsRaw) { $clsRaw = 'INVALID' }
        $cls = Get-McpSafetyFieldRedaction -Value $clsRaw
        if ($cls.Length -gt 32) { $cls = $cls.Substring(0, 32) }
        $crit = ([string]$Criticality).Trim().ToLowerInvariant()
        if ((@('optional', 'required', '') -cnotcontains $crit)) { $crit = '' }
        $stRaw = ([string]$Status).Trim().ToUpperInvariant()
        $stAllowed = @('', 'OK', 'MCP_CALL_OK', 'MCP_TIMEOUT', 'MCP_NETWORK_ERROR', 'MCP_ERROR', 'MCP_UNAVAILABLE', 'MCP_REQUIRED_BLOCKED', 'MCP_CIRCUIT_OPEN', 'MCP_CIRCUIT_CLOSED', 'MCP_POLICY_INVALID', 'MCP_LONG_RUNNING_REQUIRES_CONTRACT', 'MCP_PROBE_ABANDONED', 'MCP_LOCK_BUSY', 'MCP_BUSY_GLOBAL', 'MCP_ABANDON_LIMIT_REACHED', 'MCP_CAPACITY_CELL_UNAVAILABLE', 'INVALID')
        if ($stAllowed -cnotcontains $stRaw) { $stRaw = 'INVALID' }
        $st = Get-McpSafetyFieldRedaction -Value $stRaw
        if ($st.Length -gt 48) { $st = $st.Substring(0, 48) }
        $cir = ([string]$Circuit).Trim().ToUpperInvariant()
        if (@('CLOSED', 'OPEN', 'HALF_OPEN', '') -cnotcontains $cir) { $cir = '' }
        $fp = Get-McpSafetyCallFingerprint -Server $Server -Capability $Capability -TurnId $TurnId
        $th = ''
        try {
            $tb = [Text.Encoding]::UTF8.GetBytes(([string]$TurnId).Trim())
            $sha2 = [System.Security.Cryptography.SHA256]::Create()
            try { $dg = $sha2.ComputeHash($tb) }
            finally { try { $sha2.Dispose() } catch { } }
            $th = ((($dg | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant()).Substring(0, 16)
        }
        catch { $th = 'unavailable' }
        $doc = [ordered]@{
            ts               = ([DateTimeOffset]::UtcNow.ToString('o'))
            source           = 'mcp-safety'
            event            = $ev
            server           = $srv
            capability       = $cap
            turn_hash16      = $th
            call_fingerprint = $fp
            class            = $cls
            criticality      = $crit
            status           = $st
            elapsed_ms       = [int]$ElapsedMs
            budget_s         = [int]$BudgetS
            consecutive      = [int]$Consecutive
            circuit          = $cir
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) }
        catch { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        if ([string]::IsNullOrWhiteSpace($text)) { return [PSCustomObject]@{ ok = $false; skipped = 'serialize' } }
        $target = Get-McpSafetyTelemetryFile -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($target)) { return [PSCustomObject]@{ ok = $false; skipped = 'no-target' } }
        $teleGate = Get-McpSafetySharedGate -Name 'TelemetryGate'
        if ($null -eq $teleGate) { $teleGate = $script:McpSafetyTelemetryLock }
        $teleWaitMs = 250
        try { $teleWaitMs = [int]$script:McpSafetyTelemetryLockWaitMs } catch { $teleWaitMs = 250 }
        if ($teleWaitMs -lt 0) { $teleWaitMs = 0 }
        if ($teleWaitMs -gt 10000) { $teleWaitMs = 10000 }
        $lockTaken = $false
        try {
            [void][System.Threading.Monitor]::TryEnter($teleGate, $teleWaitMs, [ref]$lockTaken)
            if (-not [bool]$lockTaken) {
                return [PSCustomObject]@{ ok = $false; skipped = 'lock-busy' }
            }
            try {
                $parent = Split-Path -Parent $target
                if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            }
            catch { return [PSCustomObject]@{ ok = $false; skipped = 'mkdir' } }
            try {
                if ([bool]$script:McpSafetySimulateAccountingFailure) {
                    throw [System.IO.IOException]::new('simulated accounting failure')
                }
                $eventBytes = [Text.Encoding]::UTF8.GetByteCount(($text + "`n"))
                $currentLen = [long]0
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $currentLen = ([IO.FileInfo]::new($target)).Length
                }
                if (($currentLen + [long]$eventBytes) -gt [long]$script:McpSafetyTelemetryCapBytes) {
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
                try { [System.Threading.Monitor]::Exit($teleGate) } catch { }
            }
        }
    }
    catch { return [PSCustomObject]@{ ok = $false; skipped = 'internal' } }
}

# ---------- bounded probe runner ----------

function Classify-McpSafetyProbeError {
    <#
    .SYNOPSIS
        Maps a probe exception message to timeout | network | other
        (closed token lists, case-insensitive). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Message)
    try {
        $m = ([string]$Message).ToLowerInvariant()
        $timeoutTokens = @('mcp_sim_timeout', 'timed out', 'timeout', 'deadline exceeded', 'deadline_exceeded')
        foreach ($tk in $timeoutTokens) {
            if ($m.Contains($tk)) { return 'timeout' }
        }
        $netTokens = @('mcp_sim_network', 'network', 'connection refused', 'connection reset', 'connect failure', 'connection failure', 'dns', 'unreachable', 'socket', 'connection timed out')
        foreach ($tk in $netTokens) {
            if ($m.Contains($tk)) { return 'network' }
        }
        return 'other'
    }
    catch { return 'other' }
}

function Invoke-McpSafetyProbe {
    <#
    .SYNOPSIS
        Runs a self-contained scriptblock in a fresh runspace under a
        wall-clock deadline. Overrun yields completed=$false
        (caller maps to MCP_TIMEOUT); a thrown probe error is
        classified timeout | network | other. The post-timeout stop
        itself is bounded by the settle margin: when the runspace
        does not settle in time it is deliberately ABANDONED without
        dispose (settled=$false, abandon counter bumped) instead of
        hanging the caller. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Probe,
        [object[]]$ProbeArgs = @(),
        [int]$TimeoutMs = 30000
    )
    try {
        $ms = [int]$TimeoutMs
        if ($ms -lt 100) { $ms = 100 }
        if ($ms -gt 3600000) { $ms = 3600000 }
        $settle = 5000
        try { $settle = [int]$script:McpSafetySettleMarginMs } catch { $settle = 5000 }
        if ($settle -lt 500) { $settle = 500 }
        if ($settle -gt 30000) { $settle = 30000 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rs = $null
        $ps = $null
        $abandoned = $false
        $completed = $false
        $settled = $true
        $output = $null
        $probeError = ''
        try {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($Probe)
            foreach ($a in @($ProbeArgs)) {
                try { [void]$ps.AddArgument($a) } catch { }
            }
            $handle = $ps.BeginInvoke()
            $done = $false
            try { $done = $handle.AsyncWaitHandle.WaitOne($ms) }
            catch { $done = $false }
            if (-not $done) {
                try { $done = $handle.AsyncWaitHandle.WaitOne(0) } catch { $done = $false }
            }
            if (-not $done) {
                $stopOk = $false
                try {
                    $stopAsync = $ps.BeginStop($null, $null)
                    try { $stopOk = $stopAsync.AsyncWaitHandle.WaitOne($settle) } catch { $stopOk = $false }
                    if ($stopOk) { try { $ps.EndStop($stopAsync) } catch { } }
                }
                catch { $stopOk = $false }
                if (-not $stopOk) {
                    $abandoned = $true
                    $completed = $false
                    $settled = $false
                    try { $script:McpSafetyAbandonedCount = ([int]$script:McpSafetyAbandonedCount + 1) } catch { }
                }
                else {
                    $completed = $false
                    $settled = $true
                }
            }
            else {
                try {
                    $rows = $ps.EndInvoke($handle)
                    if (($null -ne $ps.Streams.Error) -and (@($ps.Streams.Error).Count -gt 0)) {
                        $first = @($ps.Streams.Error)[0]
                        $probeError = ([string]$first.Exception.Message)
                        if ([string]::IsNullOrWhiteSpace($probeError)) { $probeError = ([string]$first.ToString()) }
                        $completed = $true
                    }
                    else {
                        $vals = @($rows)
                        if ($vals.Count -eq 1) { $output = $vals[0] }
                        elseif ($vals.Count -gt 1) { $output = $vals }
                        $completed = $true
                    }
                }
                catch {
                    $probeError = ([string]$_.Exception.Message)
                    if ([string]::IsNullOrWhiteSpace($probeError)) { $probeError = 'probe-failed' }
                    $completed = $true
                }
            }
        }
        finally {
            if (-not $abandoned) {
                try { if ($null -ne $ps) { $ps.Dispose() } } catch { }
                try { if ($null -ne $rs) { $rs.Close() } } catch { }
                try { if ($null -ne $rs) { $rs.Dispose() } } catch { }
            }
        }
        $sw.Stop()
        $failureClass = ''
        if (($completed) -and (-not [string]::IsNullOrWhiteSpace($probeError))) {
            $failureClass = Classify-McpSafetyProbeError -Message $probeError
        }
        return [PSCustomObject]@{
            completed = [bool]$completed; output = $output; probe_error = $probeError
            failure_class = $failureClass; elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
            settled = [bool]$settled
        }
    }
    catch {
        return [PSCustomObject]@{
            completed = $false; output = $null; probe_error = 'runner-internal'
            failure_class = ''; elapsed_ms = 0; settled = $true
        }
    }
}

# ---------- main bounded call ----------

function New-McpSafetyNormalizedRefusal {
    <#
    .SYNOPSIS
        Central criticality normalization for every refusal path.
        required always yields status/error MCP_REQUIRED_BLOCKED
        with the cause preserved in failure and blocked=true;
        optional keeps the structured cause as status with
        fallback_continue=true (MCP_POLICY_INVALID additionally
        blocks every criticality: nothing proceeds without a
        policy). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Cause,
        [Parameter(Mandatory = $true)][string]$Criticality,
        [string]$Server = '',
        [string]$Capability = '',
        [string]$TurnId = '',
        [string]$Class = '',
        [int]$BudgetS = 0,
        [string]$Circuit = 'CLOSED',
        [int]$Consecutive = 0,
        [int]$ElapsedMs = 0,
        $Extra = $null
    )
    try {
        $crit = ([string]$Criticality).Trim().ToLowerInvariant()
        if ($crit -cne 'required') { $crit = 'optional' }
        $cause = ([string]$Cause).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($cause)) { $cause = 'MCP_ERROR' }
        $status = $cause
        if ($crit -ceq 'required') { $status = 'MCP_REQUIRED_BLOCKED' }
        $blocked = ($crit -ceq 'required')
        if ($cause -ceq 'MCP_POLICY_INVALID') { $blocked = $true }
        $fallback = ($crit -cne 'required')
        $cir = ([string]$Circuit).Trim().ToUpperInvariant()
        if (@('OPEN', 'HALF_OPEN', 'CLOSED') -cnotcontains $cir) { $cir = 'CLOSED' }
        $r = [ordered]@{
            ok = $false; status = $status; error = $status; failure = $cause
            server = ([string]$Server)
            capability = ([string]$Capability).Trim().ToLowerInvariant()
            turn = ([string]$TurnId); class = ([string]$Class); criticality = $crit
            circuit = $cir; circuit_open = ($cir -ceq 'OPEN'); blocked = [bool]$blocked
            fallback_continue = [bool]$fallback; elapsed_ms = [int]$ElapsedMs; budget_s = [int]$BudgetS
            consecutive = [int]$Consecutive; settled = $true
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
    catch { return (New-McpSafetyError -Status 'INTERNAL_ERROR') }
}

function Invoke-McpSafetyCall {
    <#
    .SYNOPSIS
        Bounded MCP call with circuit breaker and criticality mapping.
        Never throws: every outcome is a structured result object.
    .DESCRIPTION
        -PolicyPath defaults to the canonical registry policy; a
        missing or malformed policy returns MCP_POLICY_INVALID.
        -TurnId is caller-declared (HOLD: no identity proof).
        -Probe must be a self-contained scriptblock (fresh runspace,
        no caller scope; synthetic fixtures in tests, zero network).
        Long-running class requires -TaskContractId plus
        -BudgetSeconds (1..3600) for the execute phase; the connect
        phase always uses the per-class policy budget. The budget
        resolution is per phase: connect always takes
        connect_timeout_seconds from the policy class (never the
        contract seconds). -BudgetSecondsOverride only
        tightens (1..policy budget) for deterministic tests.
        -NowUtc fixes the decision clock; -ConcludedAtUtc fixes the
        clock captured at the conclusion of the call (cooldown is
        measured from the conclusion, never from the start). Without
        overrides both are the real UTC clock. Admission reserves
        one capacity unit atomically under the global lock first;
        the per-key lock second (bounded waits; global unavailability
        yields MCP_BUSY_GLOBAL). Proven settlement releases the
        reservation after the key lock is exited; abandonment keeps
        it permanently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Capability,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Class,
        [string]$Criticality = 'optional',
        [string]$Phase = 'execute',
        [scriptblock]$Probe = $null,
        [object[]]$ProbeArgs = @(),
        [string]$TaskContractId = '',
        [int]$BudgetSeconds = 0,
        [int]$BudgetSecondsOverride = 0,
        [string]$PolicyPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = '',
        $NowUtc = $null,
        $ConcludedAtUtc = $null
    )
    try {
        $pp = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-McpSafetyDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-McpSafetyPolicyFull -Path $pp)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_POLICY_INVALID' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId))
        }
        $slot = Read-McpSafetyPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if ((-not [bool]$slot.found) -or ([bool]$slot.malformed)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_POLICY_INVALID' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId))
        }
        if (-not (Test-McpSafetyServerId -Value $Server)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_SERVER_ID' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId))
        }
        if (-not (Test-McpSafetyCapabilityId -Value $Capability)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_CAPABILITY' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Extra @{ capability = ([string]$Capability) })
        }
        if (-not (Test-McpSafetyTurnId -Value $TurnId)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_TURN_ID' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId))
        }
        $c = Get-McpSafetyNormalizedClass -Class $Class
        if ([string]::IsNullOrWhiteSpace($c)) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_CLASS' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Extra @{ class = ([string]$Class) })
        }
        $crit = ([string]$Criticality).Trim().ToLowerInvariant()
        if (($crit -cne 'optional') -and ($crit -cne 'required')) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_CRITICALITY' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -Extra @{ criticality = ([string]$Criticality) })
        }
        $ph = ([string]$Phase).Trim().ToLowerInvariant()
        if (($ph -cne 'connect') -and ($ph -cne 'execute')) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_PHASE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -Extra @{ phase = ([string]$Phase) })
        }
        if ($null -eq $Probe) {
            return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_PROBE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c)
        }
        $threshold = 2
        $cooldown = 300
        try { $threshold = [int](Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'failure_threshold') } catch { $threshold = 2 }
        try {
            $cn = Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'circuit'
            $cooldown = [int](Get-McpSafetyPolicyNode -Doc $cn -Name 'cooldown_seconds')
        }
        catch { $cooldown = 300 }
        $budget = 0
        $contract = ([string]$TaskContractId).Trim()
        if ($ph -ceq 'connect') {
            if (($c -ceq 'long_running') -and (([string]::IsNullOrWhiteSpace($contract)) -or (-not (Test-McpSafetyTurnId -Value $contract)))) {
                return (New-McpSafetyNormalizedRefusal -Cause 'MCP_LONG_RUNNING_REQUIRES_CONTRACT' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c)
            }
            $b = Get-McpSafetyClassBudget -Class $c -Phase 'connect' -PolicyPath $pp -RepoRoot $RepoRoot
            if (-not [bool]$b.ok) {
                $bcConnect = 'MCP_POLICY_INVALID'
                try {
                    $btConnect = ([string]$b.status).Trim().ToUpperInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($btConnect)) { $bcConnect = $btConnect }
                }
                catch { $bcConnect = 'MCP_POLICY_INVALID' }
                return (New-McpSafetyNormalizedRefusal -Cause $bcConnect -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS 0)
            }
            $budget = [int]$b.budget_s
        }
        elseif ($c -ceq 'long_running') {
            if ([string]::IsNullOrWhiteSpace($contract) -or (-not (Test-McpSafetyTurnId -Value $contract))) {
                return (New-McpSafetyNormalizedRefusal -Cause 'MCP_LONG_RUNNING_REQUIRES_CONTRACT' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c)
            }
            if (-not (Test-McpSafetyInt -Value $BudgetSeconds -Min 1 -Max $script:McpSafetyLongRunningMaxBudgetSeconds)) {
                return (New-McpSafetyNormalizedRefusal -Cause 'MCP_LONG_RUNNING_REQUIRES_CONTRACT' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c)
            }
            $budget = [int]$BudgetSeconds
        }
        else {
            $b = Get-McpSafetyClassBudget -Class $c -Phase $ph -PolicyPath $pp -RepoRoot $RepoRoot
            if (-not [bool]$b.ok) {
                $bcExec = 'MCP_POLICY_INVALID'
                try {
                    $btExec = ([string]$b.status).Trim().ToUpperInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($btExec)) { $bcExec = $btExec }
                }
                catch { $bcExec = 'MCP_POLICY_INVALID' }
                return (New-McpSafetyNormalizedRefusal -Cause $bcExec -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS 0)
            }
            $budget = [int]$b.budget_s
        }
        if ([int]$BudgetSecondsOverride -ne 0) {
            if (-not (Test-McpSafetyInt -Value $BudgetSecondsOverride -Min 1 -Max $budget)) {
                return (New-McpSafetyNormalizedRefusal -Cause 'INVALID_OVERRIDE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Extra @{ budget_s = $budget })
            }
            $budget = [int]$BudgetSecondsOverride
        }
        $now = Get-McpSafetyUtcNow -AtUtc $NowUtc
        $key = Get-McpSafetyCircuitKey -Server $Server -Capability $Capability -TurnId $TurnId
        $lockWaitMs = 1000
        try { $lockWaitMs = [int]$script:McpSafetyLockWaitMaxMs } catch { $lockWaitMs = 1000 }
        if ($lockWaitMs -lt 0) { $lockWaitMs = 0 }
        $budgetWaitMs = ($budget * 1000)
        if ($lockWaitMs -gt $budgetWaitMs) { $lockWaitMs = $budgetWaitMs }
        $resv = Request-McpSafetyCapacity -TimeoutMs $lockWaitMs
        if (-not [bool]$resv.admitted) {
            $refState = Get-McpSafetyCircuitState -Server $Server -Capability $Capability -TurnId $TurnId -NowUtc $now -CooldownSeconds $cooldown -FailureThreshold $threshold
            $refCode = ([string]$resv.reason).Trim().ToUpperInvariant()
            if (@('MCP_ABANDON_LIMIT_REACHED', 'MCP_CAPACITY_CELL_UNAVAILABLE') -cnotcontains $refCode) { $refCode = 'MCP_BUSY_GLOBAL' }
            [void](Write-McpSafetyTelemetryEvent -EventName $refCode -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status $refCode -ElapsedMs 0 -BudgetS $budget -Consecutive ([int]$refState.consecutive) -Circuit ([string]$refState.state) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-McpSafetyNormalizedRefusal -Cause $refCode -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit ([string]$refState.state) -Consecutive ([int]$refState.consecutive))
        }
        $releaseCapacity = $true
        if (-not (Get-McpSafetyCircuitSharedAvailable)) {
            [void](Release-McpSafetyCapacity -TimeoutMs $lockWaitMs)
            $releaseCapacity = $false
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_CAPACITY_CELL_UNAVAILABLE' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_CAPACITY_CELL_UNAVAILABLE' -ElapsedMs 0 -BudgetS $budget -Consecutive 0 -Circuit '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_CAPACITY_CELL_UNAVAILABLE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit 'CLOSED' -Consecutive 0)
        }
        $circuitLock = Get-McpSafetyCircuitLock -Key $key -TimeoutMs $lockWaitMs
        $circuitLockTaken = $false
        try {
            $lockGot = $false
            if ($null -eq $circuitLock) {
                $lockGot = $false
            }
            else {
                try {
                    [void][System.Threading.Monitor]::TryEnter($circuitLock, $lockWaitMs, [ref]$circuitLockTaken)
                    $lockGot = [bool]$circuitLockTaken
                }
                catch { $lockGot = $false }
            }
            if (-not $lockGot) {
                $busyState = Get-McpSafetyCircuitState -Server $Server -Capability $Capability -TurnId $TurnId -NowUtc $now -CooldownSeconds $cooldown -FailureThreshold $threshold
                [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_LOCK_BUSY' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_LOCK_BUSY' -ElapsedMs 0 -BudgetS $budget -Consecutive ([int]$busyState.consecutive) -Circuit ([string]$busyState.state) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
                [void](Release-McpSafetyCapacity -TimeoutMs $lockWaitMs)
                $releaseCapacity = $false
                return (New-McpSafetyNormalizedRefusal -Cause 'MCP_LOCK_BUSY' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit ([string]$busyState.state) -Consecutive ([int]$busyState.consecutive))
            }
        $state = Get-McpSafetyCircuitState -Server $Server -Capability $Capability -TurnId $TurnId -NowUtc $now -CooldownSeconds $cooldown -FailureThreshold $threshold
        if ([string]$state.state -ceq 'UNKNOWN') {
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_CAPACITY_CELL_UNAVAILABLE' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_CAPACITY_CELL_UNAVAILABLE' -ElapsedMs 0 -BudgetS $budget -Consecutive 0 -Circuit '' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_CAPACITY_CELL_UNAVAILABLE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit 'CLOSED' -Consecutive 0)
        }
        $wasHalfOpen = ([string]$state.state -ceq 'HALF_OPEN')
        if ([string]$state.state -ceq 'OPEN') {
            $ev = 'MCP_CIRCUIT_OPEN'
            [void](Write-McpSafetyTelemetryEvent -EventName $ev -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status $ev -ElapsedMs 0 -BudgetS $budget -Consecutive ([int]$state.consecutive) -Circuit 'OPEN' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            if ($crit -ceq 'required') {
                return (New-McpSafetyNormalizedRefusal -Cause 'MCP_CIRCUIT_OPEN' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit 'OPEN' -Consecutive ([int]$state.consecutive))
            }
            return [PSCustomObject]@{
                ok = $true; status = 'MCP_UNAVAILABLE'; error = ''
                server = ([string]$Server); capability = ([string]$Capability).Trim().ToLowerInvariant()
                turn = ([string]$TurnId); class = $c; criticality = $crit
                circuit = 'OPEN'; circuit_open = $true; blocked = $false
                fallback_continue = $true; elapsed_ms = 0; budget_s = $budget
                consecutive = ([int]$state.consecutive); failure = 'MCP_CIRCUIT_OPEN'; settled = $true
            }
        }
        $prior = 0
        $priorReadOk = $true
        if ($wasHalfOpen) { $prior = ([int]$state.consecutive) }
        else {
            try {
                if (Get-McpSafetyCircuitSharedAvailable) {
                    $rdp = Read-McpSafetyCircuitStore -Key $key
                    if (([bool]$rdp.ok) -and ([bool]$rdp.found)) {
                        $pdec = ConvertFrom-McpSafetyCircuitWire -Wire ([string]$rdp.wire)
                        if ([bool]$pdec.valid) { $prior = [int]$pdec.consecutive }
                        else { $priorReadOk = $false }
                    }
                    elseif (-not [bool]$rdp.ok) { $priorReadOk = $false }
                }
            }
            catch { $prior = 0 }
        }
        if (-not [bool]$priorReadOk) {
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_CAPACITY_CELL_UNAVAILABLE' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_CAPACITY_CELL_UNAVAILABLE' -ElapsedMs 0 -BudgetS $budget -Consecutive ([int]$state.consecutive) -Circuit ([string]$state.state) -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_CAPACITY_CELL_UNAVAILABLE' -Criticality $crit -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit ([string]$state.state) -Consecutive ([int]$state.consecutive))
        }
        $run = Invoke-McpSafetyProbe -Probe $Probe -ProbeArgs $ProbeArgs -TimeoutMs ($budget * 1000)
        $capNorm = ([string]$Capability).Trim().ToLowerInvariant()
        $endNow = Get-McpSafetyUtcNow -AtUtc $ConcludedAtUtc
        if (($null -eq $ConcludedAtUtc) -and ($null -ne $NowUtc)) { $endNow = $now }
        if (([bool]$run.completed) -and ([string]::IsNullOrWhiteSpace([string]$run.probe_error))) {
            $closedNow = Set-McpSafetyCircuitClosedIfGeneration -Key $key -ExpectedOpenedAtUtc ([string]$state.opened_at_utc) -ExpectedConsecutive ([int]$state.consecutive)
            $evName = 'MCP_CALL_OK'
            $cirName = 'CLOSED'
            if (-not [bool]$closedNow) {
                try {
                    $fresh = Get-McpSafetyCircuitState -Server $Server -Capability $Capability -TurnId $TurnId -NowUtc $endNow -CooldownSeconds $cooldown -FailureThreshold $threshold
                    $cirName = ([string]$fresh.state)
                }
                catch { $cirName = 'OPEN' }
            }
            if ($wasHalfOpen -and ([string]$cirName -ceq 'CLOSED')) { $evName = 'MCP_CIRCUIT_CLOSED' }
            [void](Write-McpSafetyTelemetryEvent -EventName $evName -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'OK' -ElapsedMs ([int]$run.elapsed_ms) -BudgetS $budget -Consecutive 0 -Circuit $cirName -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return [PSCustomObject]@{
                ok = $true; status = 'OK'; error = ''; failure = ''
                server = ([string]$Server); capability = $capNorm
                turn = ([string]$TurnId); class = $c; criticality = $crit
                circuit = $cirName; circuit_open = $false; blocked = $false
                fallback_continue = $false; elapsed_ms = ([int]$run.elapsed_ms); budget_s = $budget
                consecutive = 0; output = $run.output; settled = ([bool]$run.settled)
            }
        }
        $fclass = 'timeout'
        $evFail = 'MCP_TIMEOUT'
        if (-not [bool]$run.completed) {
            $fclass = 'timeout'
            $evFail = 'MCP_TIMEOUT'
        }
        elseif ([string]$run.failure_class -ceq 'network') {
            $fclass = 'network'
            $evFail = 'MCP_NETWORK_ERROR'
        }
        elseif ([string]$run.failure_class -ceq 'timeout') {
            $fclass = 'timeout'
            $evFail = 'MCP_TIMEOUT'
        }
        else {
            $errClosed = Set-McpSafetyCircuitClosedIfGeneration -Key $key -ExpectedOpenedAtUtc ([string]$state.opened_at_utc) -ExpectedConsecutive ([int]$state.consecutive)
            $errCir = 'CLOSED'
            $errConsec = 0
            if (-not [bool]$errClosed) {
                try {
                    $errFresh = Get-McpSafetyCircuitState -Server $Server -Capability $Capability -TurnId $TurnId -NowUtc $endNow -CooldownSeconds $cooldown -FailureThreshold $threshold
                    $errCir = ([string]$errFresh.state)
                    $errConsec = ([int]$errFresh.consecutive)
                }
                catch { $errCir = 'CLOSED'; $errConsec = 0 }
            }
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_ERROR' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_ERROR' -ElapsedMs ([int]$run.elapsed_ms) -BudgetS $budget -Consecutive $errConsec -Circuit $errCir -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
            return (New-McpSafetyNormalizedRefusal -Cause 'MCP_ERROR' -Criticality $crit -Server ([string]$Server) -Capability $capNorm -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit $errCir -Consecutive $errConsec -ElapsedMs ([int]$run.elapsed_ms) -Extra @{
                failure_class = 'other'
                probe_error = (Get-McpSafetyProbeErrorRedaction -Value ([string]$run.probe_error))
                settled = ([bool]$run.settled)
            })
        }
        $next = ($prior + 1)
        $cirNow = 'CLOSED'
        $openedStamp = $null
        if ([int]$next -ge [int]$threshold) {
            $cirNow = 'OPEN'
            $openedStamp = $endNow
        }
        Set-McpSafetyCircuitRecord -Key $key -Consecutive $next -State $cirNow -OpenedAtUtc $openedStamp
        [void](Write-McpSafetyTelemetryEvent -EventName $evFail -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status $evFail -ElapsedMs ([int]$run.elapsed_ms) -BudgetS $budget -Consecutive $next -Circuit $cirNow -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        if (-not [bool]$run.settled) {
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_PROBE_ABANDONED' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_PROBE_ABANDONED' -ElapsedMs ([int]$run.elapsed_ms) -BudgetS $budget -Consecutive $next -Circuit $cirNow -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        }
        if ([string]$cirNow -ceq 'OPEN') {
            [void](Write-McpSafetyTelemetryEvent -EventName 'MCP_CIRCUIT_OPEN' -Server $Server -Capability $Capability -TurnId $TurnId -Class $c -Criticality $crit -Status 'MCP_CIRCUIT_OPEN' -ElapsedMs ([int]$run.elapsed_ms) -BudgetS $budget -Consecutive $next -Circuit 'OPEN' -TelemetryRoot $TelemetryRoot -RepoRoot $RepoRoot)
        }
        $abNote = ''
        if (-not [bool]$run.settled) {
            $abNote = 'settled=false: abandoned probe may still complete side effects; do not auto-retry side-effecting operations'
            $releaseCapacity = $false
        }
        if ($crit -ceq 'required') {
            return (New-McpSafetyNormalizedRefusal -Cause $evFail -Criticality $crit -Server ([string]$Server) -Capability $capNorm -TurnId ([string]$TurnId) -Class $c -BudgetS $budget -Circuit $cirNow -Consecutive $next -ElapsedMs ([int]$run.elapsed_ms) -Extra @{
                failure_class = $fclass
                failure = $evFail
                settled = ([bool]$run.settled)
                note = $abNote
            })
        }
        return [PSCustomObject]@{
            ok = $true; status = 'MCP_UNAVAILABLE'; error = ''
            server = ([string]$Server); capability = $capNorm
            turn = ([string]$TurnId); class = $c; criticality = $crit
            circuit = $cirNow; circuit_open = ([string]$cirNow -ceq 'OPEN'); blocked = $false
            fallback_continue = $true; elapsed_ms = ([int]$run.elapsed_ms); budget_s = $budget
            consecutive = $next; failure_class = $fclass; failure = $evFail
            settled = ([bool]$run.settled); note = $abNote
        }
        }
            finally {
                if ($circuitLockTaken) {
                    try { [System.Threading.Monitor]::Exit($circuitLock) } catch { }
                }
                if ($releaseCapacity) {
                    try { [void](Release-McpSafetyCapacity -TimeoutMs $lockWaitMs) } catch { }
                }
            }
    }
    catch {
        return (New-McpSafetyNormalizedRefusal -Cause 'INTERNAL_ERROR' -Criticality ([string]$Criticality) -Server ([string]$Server) -Capability ([string]$Capability) -TurnId ([string]$TurnId))
    }
}

# ---------- authority guard ----------

function Invoke-McpSafetyGrantGate {
    <#
    .SYNOPSIS
        Grant-path gate: an MCP result can never grant, widen or
        carry permission. Any input yields denial. Never throws.
    #>
    [CmdletBinding()]
    param($McpResult)
    try {
        $st = ''
        try {
            if ($null -ne $McpResult) {
                if ($McpResult -is [System.Collections.IDictionary]) {
                    if ($McpResult.Contains('status')) { $st = ([string]$McpResult['status']).Trim() }
                }
                else {
                    $pp = $McpResult.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                    if ($null -ne $pp) { $st = ([string]$pp.Value).Trim() }
                }
            }
        }
        catch { $st = '' }
        return [PSCustomObject]@{
            ok = $false; status = 'MCP_RESULT_CANNOT_GRANT'; error = 'MCP_RESULT_CANNOT_GRANT'
            granted = $false; widened = $false; mcp_status = $st
            note = 'mcp-output-never-grants: circuit and policy outputs carry no authority'
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; status = 'MCP_RESULT_CANNOT_GRANT'; error = 'MCP_RESULT_CANNOT_GRANT'
            granted = $false; widened = $false; mcp_status = ''
            note = 'mcp-output-never-grants: circuit and policy outputs carry no authority'
        }
    }
}
