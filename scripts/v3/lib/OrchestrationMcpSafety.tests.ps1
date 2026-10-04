<#!
.SYNOPSIS
    Tests for lib/OrchestrationMcpSafety.ps1 (Phase 28 slice 1).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for telemetry, policy
    fixtures and probe markers, cleanup in finally. Bracketed output
    the runner parses. Exit 0 on all pass, exit 1 on any fail or
    unexpected exception. PS 5.1 compatible. ASCII-only. Zero real
    network: probes are synthetic scriptblocks (fast return, simulated
    timeout/network throws, short sleeps under tightened budgets).
    Covers AC1..AC11 (AC12 is the phase28.json evidence record,
    verified outside this suite) plus FIX1 regressions R1..R6
    plus FIX2 residuals F1..F4:
      R1 settle-bounded stop with deliberate abandon (settled=false
        plus MCP_PROBE_ABANDONED) for non-cooperative probes;
      R2 cooldown measured from the conclusion clock;
      R3 per-key in-process lock with generation-guarded close;
      R4 per-phase budget (connect always from policy);
      R5 closed allowlists plus redaction on every persisted field;
      R6 probe-error redaction/truncation at the result boundary.
      F1 bounded lock wait with MCP_LOCK_BUSY (never runs the seam,
        never touches the streak);
      F2 abandon cap with fail-closed MCP_ABANDON_LIMIT_REACHED
        refusal (never reclaimed in-session);
      F3 required plus ordinary error blocks with error cause.
      FX3 FIX3 concurrent cap boundary (atomic reservation,
        settlement release, no-reclaim) with occupancy hook.
      G1 FIX4 bounded Gate reads with UNKNOWN sentinel and honest
        RELEASE_UNCONFIRMED on unconfirmable release.
      G2 FIX4 missing shared cell fails closed without executing.
      G3 FIX4 true simultaneous barrier race with deterministic
        exactly-one-admitted invariants.
      H1 FIX5 bounded guard/telemetry acquisition with structured
        refusal and honest telemetry skip.
      H3 FIX5 internal-only codes never persist to telemetry.
      RR6 FIX6 H1 bounded tree conversion (depth 32, node budget,
        cycle detection) failing closed as malformed;
      RR6 FIX6 H3 process-shared circuit records plus per-key locks
        (same-key half-open admits exactly one probe across
        runspaces, consistent view);
      RR6 FIX6 H6 centralized criticality normalization (required
        always MCP_REQUIRED_BLOCKED with cause in failure;
        policy-invalid always blocked; optional keeps structured
        cause with fallback_continue, including MCP_ERROR).
      RR6 FIX7 H3-R exact shared-wire validation (malformed never
        reads CLOSED: Invoke refuses fail-closed, observability
        reports UNKNOWN, no local fallback);
      RR6 FIX7 H6-R remaining returns normalized (validation,
        long-running contract, budget re-read, override, outer
        catch); H7-R regressions for both.
      RR8 FIX8 R8-1 TryRead absence-vs-error plus SimulateReadFailure
        seam (UNKNOWN everywhere on error, incl. outer catch);
      RR8 FIX8 R8-2 UNKNOWN gate releases via finally after key-lock
        exit (no early release); R8-3 immediate leak measurement plus
        read-error and generation-close-no-write regressions.
      RR9 FIX9 R9-1 pre-probe streak read (post-admission read failure
        preserves the record, fail-closed, zero probes) plus
        AfterReads countdown seam; R9-2 generation close with
        unavailable store writes nothing; R9-3 per-call occupancy.
      RR10 FIX10 SEC-1 circuit records and per-key locks live ONLY
        in the private shared cell (private C# fields, methods-only
        access, no script-scope dictionaries); SEC-2 wire length cap
        before Split plus giant-wire fixture.
      AC1 canonical policy budgets, threshold, cooldown,
        criticality, fail-closed on missing/malformed/tampered policy;
      AC2 bounded seam: success, structured MCP_TIMEOUT on overrun,
        no throw, bounded elapsed, override cannot widen;
      AC3 two consecutive timeout/network failures in one turn open;
      AC4 OPEN fast-fails without invoking the seam (marker proves 0);
      AC5 cooldown half-open probe closes on success, re-opens on fail;
      AC6 optional plus unavailable yields MCP_UNAVAILABLE fallback;
      AC7 required plus unavailable yields MCP_REQUIRED_BLOCKED;
      AC8 grant gate denies every MCP result shape;
      AC9 telemetry sanitized (sk-SYNTHETICSECRET canary redacted),
        fingerprinted len:value, bounded cap fail-closed;
      AC10 mcp_routing stays OFF, flags bytes untouched, no new flags,
        no plugin files;
      AC11 streak reset on success/other-error, turn isolation,
        long-running contract gate, ASCII-only files.
    NOTE on harness: this suite intentionally follows the repository
    convention (plain deterministic script executed by
    scripts/v3/run-v3-tests.ps1) instead of Pester Describe blocks:
    no Pester usage exists anywhere in this repo and the runner parses
    [PASS]/[FAIL] plus exit codes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-McpSafety {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-McpSafetyFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-McpSafetyHits {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        return @([regex]::Matches($t, 'hit')).Count
    }
    catch { return -1 }
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoPolicy = Join-Path $repo 'source\registry\mcp-request-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-mcpsafety-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'telemetry'
$polDir = Join-Path $tempRoot 'policy'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $polDir -Force | Out-Null

$okProbe = { 'probe-ok' }
$failTimeoutProbe = { throw 'MCP_SIM_TIMEOUT boom' }
$failNetworkProbe = { throw 'MCP_SIM_NETWORK dns fail' }
$failOtherProbe = { throw 'plain application error' }
$slowProbe = { Start-Sleep -Seconds 8; 'too-late' }

try {
    Clear-McpSafetyState

    # ---------- AC1: canonical policy ----------
    $a1 = Assert-McpSafetyPolicyJson -Path $repoPolicy
    Assert-McpSafety ([bool]$a1.valid) '[AC1] canonical policy validates' ((@($a1.errors) -join '|'))
    $bAdv = Get-McpSafetyClassBudget -Class 'advisory' -PolicyPath $repoPolicy
    $bJev = Get-McpSafetyClassBudget -Class 'jev' -PolicyPath $repoPolicy
    $bMem = Get-McpSafetyClassBudget -Class 'memory' -PolicyPath $repoPolicy
    $bRem = Get-McpSafetyClassBudget -Class 'remote' -PolicyPath $repoPolicy
    Assert-McpSafety (([bool]$bAdv.ok) -and ([int]$bAdv.budget_s -eq 30)) '[AC1] advisory execution budget 30s' ([string]$bAdv.budget_s)
    Assert-McpSafety (([bool]$bJev.ok) -and ([int]$bJev.budget_s -eq 30) -and ([string]$bJev.class -ceq 'advisory')) '[AC1] jev aliases advisory 30s' ([string]$bJev.budget_s)
    Assert-McpSafety (([bool]$bMem.ok) -and ([int]$bMem.budget_s -eq 60)) '[AC1] memory execution budget 60s' ([string]$bMem.budget_s)
    Assert-McpSafety (([bool]$bRem.ok) -and ([int]$bRem.budget_s -eq 120)) '[AC1] general remote execution budget 120s' ([string]$bRem.budget_s)
    $cAdv = Get-McpSafetyClassBudget -Class 'advisory' -Phase 'connect' -PolicyPath $repoPolicy
    $cMem = Get-McpSafetyClassBudget -Class 'memory' -Phase 'connect' -PolicyPath $repoPolicy
    $cRem = Get-McpSafetyClassBudget -Class 'remote' -Phase 'connect' -PolicyPath $repoPolicy
    Assert-McpSafety (([int]$cAdv.budget_s -eq 10) -and ([int]$cMem.budget_s -eq 15) -and ([int]$cRem.budget_s -eq 20)) '[AC1] connect budgets 10/15/20s' (([string]$cAdv.budget_s + '/' + [string]$cMem.budget_s + '/' + [string]$cRem.budget_s))
    $lr = Get-McpSafetyClassBudget -Class 'long_running' -PolicyPath $repoPolicy
    Assert-McpSafety (([string]$lr.status -ceq 'MCP_LONG_RUNNING_REQUIRES_CONTRACT') -and (-not [bool]$lr.ok)) '[AC1] long-running has no default budget, contract required' ([string]$lr.status)
    $slot = Read-McpSafetyPolicy -PolicyPath $repoPolicy
    $ft = 0
    $cd = 0
    try { $ft = [int](Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'failure_threshold') } catch { $ft = 0 }
    try { $cd = [int](Get-McpSafetyPolicyNode -Doc (Get-McpSafetyPolicyNode -Doc $slot.doc -Name 'circuit') -Name 'cooldown_seconds') } catch { $cd = 0 }
    Assert-McpSafety (($ft -eq 2) -and ($cd -ge 60) -and ($cd -le 1800)) '[AC1] failure_threshold 2 with cooldown' (($ft.ToString()) + '/' + ($cd.ToString()))
    $badCrit = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac1-1' -Class 'advisory' -Criticality 'maybe' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$badCrit.status -ceq 'INVALID_CRITICALITY') '[AC1] unknown criticality rejected closed' ([string]$badCrit.status)
    $missing = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac1-2' -Class 'advisory' -Probe $okProbe -PolicyPath (Join-Path $polDir 'no-such.json') -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$missing.status -ceq 'MCP_POLICY_INVALID') '[AC1] missing policy fails closed' ([string]$missing.status)
    $badJson = Join-Path $polDir 'bad.json'
    Write-McpSafetyFixture -Path $badJson -Text '{not json'
    $malformed = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac1-3' -Class 'advisory' -Probe $okProbe -PolicyPath $badJson -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$malformed.status -ceq 'MCP_POLICY_INVALID') '[AC1] malformed policy fails closed, no silent defaults' ([string]$malformed.status)
    $tampered = Join-Path $polDir 'tampered.json'
    $rawTamper = [IO.File]::ReadAllText($repoPolicy, [Text.UTF8Encoding]::new($false)) -replace '"execution_timeout_seconds": 30', '"execution_timeout_seconds": 999'
    Write-McpSafetyFixture -Path $tampered -Text $rawTamper
    $tamp = Assert-McpSafetyPolicyJson -Path $tampered
    Assert-McpSafety (-not [bool]$tamp.valid) '[AC1] tampered budget rejected' ((@($tamp.errors) -join '|'))

    # ---------- AC2: bounded seam ----------
    $rOk = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac2-1' -Class 'advisory' -Probe $okProbe -BudgetSecondsOverride 5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([bool]$rOk.ok) -and ([string]$rOk.status -ceq 'OK') -and ([string]$rOk.output -ceq 'probe-ok')) '[AC2] fast probe returns OK with output' ([string]$rOk.status)
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = $false
    $rSlow = $null
    try {
        $rSlow = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac2-2' -Class 'advisory' -Criticality 'required' -Probe $slowProbe -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    }
    catch { $threw = $true }
    $sw2.Stop()
    Assert-McpSafety ((-not $threw) -and ($null -ne $rSlow) -and ([string]$rSlow.failure -ceq 'MCP_TIMEOUT')) '[AC2] overrun yields structured MCP_TIMEOUT, never throws' ([string]$rSlow.failure)
    Assert-McpSafety ([int]$rSlow.elapsed_ms -lt (1 * 1000 + $script:McpSafetySettleMarginMs)) '[AC2] bounded: elapsed within budget plus settle margin' ([string]$rSlow.elapsed_ms)
    Assert-McpSafety ([int]$sw2.Elapsed.TotalSeconds -lt 30) '[AC2] wall clock never hangs' ([string][int]$sw2.Elapsed.TotalSeconds)
    $wide = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac2-3' -Class 'advisory' -Probe $okProbe -BudgetSecondsOverride 9999 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$wide.status -ceq 'INVALID_OVERRIDE') '[AC2] override cannot widen past policy' ([string]$wide.status)
    $seam = Invoke-McpSafetyProbe -Probe $slowProbe -TimeoutMs 1000
    Assert-McpSafety ((-not [bool]$seam.completed) -and ([string]::IsNullOrWhiteSpace([string]$seam.failure_class))) '[AC2] seam reports incomplete on overrun' ([string]$seam.elapsed_ms)

    # ---------- AC3: two failures open the circuit in one turn ----------
    Clear-McpSafetyState
    $f1 = Invoke-McpSafetyCall -Server 'srv-b' -Capability 'test.probe' -TurnId 'turn-ac3-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([int]$f1.consecutive -eq 1) -and ([string]$f1.circuit -ceq 'CLOSED')) '[AC3] first timeout consecutive 1, still closed' (([string]$f1.consecutive + '/' + [string]$f1.circuit))
    $f2 = Invoke-McpSafetyCall -Server 'srv-b' -Capability 'test.probe' -TurnId 'turn-ac3-1' -Class 'advisory' -Probe $failNetworkProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([int]$f2.consecutive -eq 2) -and ([string]$f2.circuit -ceq 'OPEN')) '[AC3] second timeout/network failure opens circuit' (([string]$f2.consecutive + '/' + [string]$f2.circuit))
    $st3 = Get-McpSafetyCircuitState -Server 'srv-b' -Capability 'test.probe' -TurnId 'turn-ac3-1' -CooldownSeconds 300
    Assert-McpSafety ([string]$st3.state -ceq 'OPEN') '[AC3] circuit state query reports OPEN' ([string]$st3.state)

    # ---------- AC4: OPEN fast-fails without invoking the seam ----------
    $marker4 = Join-Path $tempRoot 'hits4.txt'
    $code4 = "[IO.File]::AppendAllText('$marker4', 'hit;')"
    $markProbe4 = [scriptblock]::Create($code4)
    $ff = Invoke-McpSafetyCall -Server 'srv-b' -Capability 'test.probe' -TurnId 'turn-ac3-1' -Class 'advisory' -Probe $markProbe4 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$ff.failure -ceq 'MCP_CIRCUIT_OPEN') '[AC4] open circuit fast-fails MCP_CIRCUIT_OPEN' ([string]$ff.failure)
    Assert-McpSafety ((Get-McpSafetyHits -Path $marker4) -eq 0) '[AC4] seam invoked 0 times after opening' ([string](Get-McpSafetyHits -Path $marker4))

    # ---------- AC5: cooldown half-open probe ----------
    Clear-McpSafetyState
    $t0 = [DateTime]::UtcNow
    [void](Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $t0)
    [void](Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $t0)
    $marker5 = Join-Path $tempRoot 'hits5.txt'
    $markOk5 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker5', 'hit;'); 'recovered'")
    $early = Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $markOk5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $t0
    Assert-McpSafety (([string]$early.failure -ceq 'MCP_CIRCUIT_OPEN') -and ((Get-McpSafetyHits -Path $marker5) -eq 0)) '[AC5] before cooldown still fast-fails, probe not run' ([string]$early.failure)
    $late = Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $markOk5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc ($t0.AddSeconds(301))
    Assert-McpSafety (([string]$late.status -ceq 'OK') -and ((Get-McpSafetyHits -Path $marker5) -eq 1)) '[AC5] expired cooldown allows half-open probe, success rearms CLOSED' ([string]$late.status)
    $st5 = Get-McpSafetyCircuitState -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -NowUtc ($t0.AddSeconds(301)) -CooldownSeconds 300
    Assert-McpSafety ([string]$st5.state -ceq 'CLOSED') '[AC5] success probe closes circuit' ([string]$st5.state)
    [void](Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc ($t0.AddSeconds(301)))
    [void](Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc ($t0.AddSeconds(301)))
    $reProbe = Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc ($t0.AddSeconds(602))
    Assert-McpSafety (([string]$reProbe.circuit -ceq 'OPEN') -and ([int]$reProbe.consecutive -ge 2)) '[AC5] failed half-open probe re-opens with renewed cooldown' ([string]$reProbe.circuit)
    $afterRe = Invoke-McpSafetyCall -Server 'srv-c' -Capability 'test.probe' -TurnId 'turn-ac5-1' -Class 'advisory' -Probe $markOk5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc ($t0.AddSeconds(602))
    Assert-McpSafety (([string]$afterRe.failure -ceq 'MCP_CIRCUIT_OPEN') -and ((Get-McpSafetyHits -Path $marker5) -eq 1)) '[AC5] renewed cooldown fast-fails again, no new probe' ([string]$afterRe.failure)

    # ---------- AC6: optional fallback ----------
    Clear-McpSafetyState
    $u1 = Invoke-McpSafetyCall -Server 'srv-d' -Capability 'test.probe' -TurnId 'turn-ac6-1' -Class 'memory' -Criticality 'optional' -Probe $failTimeoutProbe -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$u1.status -ceq 'MCP_UNAVAILABLE') -and ([bool]$u1.ok) -and ([bool]$u1.fallback_continue) -and (-not [bool]$u1.blocked)) '[AC6] optional timeout yields MCP_UNAVAILABLE fallback' ([string]$u1.status)

    # ---------- AC7: required blocker ----------
    Clear-McpSafetyState
    $b1 = Invoke-McpSafetyCall -Server 'srv-e' -Capability 'test.probe' -TurnId 'turn-ac7-1' -Class 'memory' -Criticality 'required' -Probe $failTimeoutProbe -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$b1.status -ceq 'MCP_REQUIRED_BLOCKED') -and (-not [bool]$b1.ok) -and ([bool]$b1.blocked)) '[AC7] required timeout yields MCP_REQUIRED_BLOCKED' ([string]$b1.status)
    [void](Invoke-McpSafetyCall -Server 'srv-e' -Capability 'test.probe' -TurnId 'turn-ac7-1' -Class 'memory' -Criticality 'required' -Probe $failTimeoutProbe -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $bOpen = Invoke-McpSafetyCall -Server 'srv-e' -Capability 'test.probe' -TurnId 'turn-ac7-1' -Class 'memory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$bOpen.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$bOpen.failure -ceq 'MCP_CIRCUIT_OPEN')) '[AC7] required plus open circuit stays blocked' ([string]$bOpen.status)

    # ---------- AC11 adjuncts: reset, isolation, long-running, inputs ----------
    Clear-McpSafetyState
    [void](Invoke-McpSafetyCall -Server 'srv-f' -Capability 'test.probe' -TurnId 'turn-ac11-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $midOk = Invoke-McpSafetyCall -Server 'srv-f' -Capability 'test.probe' -TurnId 'turn-ac11-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    $afterOk = Invoke-McpSafetyCall -Server 'srv-f' -Capability 'test.probe' -TurnId 'turn-ac11-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$midOk.status -ceq 'OK') -and ([int]$afterOk.consecutive -eq 1) -and ([string]$afterOk.circuit -ceq 'CLOSED')) '[AC11] success resets consecutive streak' (([string]$afterOk.consecutive + '/' + [string]$afterOk.circuit))
    $oth = Invoke-McpSafetyCall -Server 'srv-f' -Capability 'test.probe' -TurnId 'turn-ac11-2' -Class 'advisory' -Probe $failOtherProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$oth.status -ceq 'MCP_ERROR') -and ([int]$oth.consecutive -eq 0)) '[AC11] non-timeout error yields MCP_ERROR and resets streak' ([string]$oth.status)
    Clear-McpSafetyState
    [void](Invoke-McpSafetyCall -Server 'srv-g' -Capability 'test.probe' -TurnId 'turn-iso-a' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    [void](Invoke-McpSafetyCall -Server 'srv-g' -Capability 'test.probe' -TurnId 'turn-iso-a' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $isoB = Invoke-McpSafetyCall -Server 'srv-g' -Capability 'test.probe' -TurnId 'turn-iso-b' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([int]$isoB.consecutive -eq 1) -and ([string]$isoB.circuit -ceq 'CLOSED')) '[AC11] circuits isolated per turn' (([string]$isoB.consecutive + '/' + [string]$isoB.circuit))
    $noContract = Invoke-McpSafetyCall -Server 'srv-h' -Capability 'test.long' -TurnId 'turn-ac11-3' -Class 'long_running' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$noContract.status -ceq 'MCP_LONG_RUNNING_REQUIRES_CONTRACT') '[AC11] long-running without contract refused' ([string]$noContract.status)
    $withContract = Invoke-McpSafetyCall -Server 'srv-h' -Capability 'test.long' -TurnId 'turn-ac11-3' -Class 'long_running' -TaskContractId 'contract-1' -BudgetSeconds 5 -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$withContract.status -ceq 'OK') -and ([int]$withContract.budget_s -eq 5)) '[AC11] long-running with explicit contract runs bounded' ([string]$withContract.status)
    $badSrv = Invoke-McpSafetyCall -Server 'BAD SERVER!!' -Capability 'test.probe' -TurnId 'turn-ac11-4' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$badSrv.status -ceq 'INVALID_SERVER_ID') '[AC11] free-text server rejected' ([string]$badSrv.status)
    $badCap = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'nodots' -TurnId 'turn-ac11-5' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$badCap.status -ceq 'INVALID_CAPABILITY') '[AC11] non-dotted capability rejected' ([string]$badCap.status)
    $badTurn = Invoke-McpSafetyCall -Server 'srv-a' -Capability 'test.probe' -TurnId 'x' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$badTurn.status -ceq 'INVALID_TURN_ID') '[AC11] short turn id rejected' ([string]$badTurn.status)

    # ---------- AC8: authority guard ----------
    $samples = @(
        ([PSCustomObject]@{ ok = $true; status = 'OK' }),
        ([PSCustomObject]@{ ok = $true; status = 'MCP_UNAVAILABLE'; failure = 'MCP_TIMEOUT' }),
        ([PSCustomObject]@{ ok = $false; status = 'MCP_REQUIRED_BLOCKED'; failure = 'MCP_TIMEOUT' }),
        ([PSCustomObject]@{ ok = $true; status = 'MCP_UNAVAILABLE'; failure = 'MCP_CIRCUIT_OPEN' }),
        ([PSCustomObject]@{ ok = $false; status = 'MCP_ERROR'; failure = 'MCP_ERROR' }),
        ([PSCustomObject]@{ ok = $false; status = 'MCP_POLICY_INVALID'; failure = 'MCP_POLICY_INVALID' })
    )
    $denyAll = $true
    foreach ($smp in $samples) {
        $g = Invoke-McpSafetyGrantGate -McpResult $smp
        if (([bool]$g.granted) -or ([bool]$g.widened) -or ([bool]$g.ok)) { $denyAll = $false }
    }
    Assert-McpSafety $denyAll '[AC8] no circuit/policy output grants or widens authority' ''
    $gNull = Invoke-McpSafetyGrantGate -McpResult $null
    Assert-McpSafety ((-not [bool]$gNull.granted) -and ([string]$gNull.status -ceq 'MCP_RESULT_CANNOT_GRANT')) '[AC8] null input still denied' ([string]$gNull.status)

    # ---------- AC9: sanitized bounded telemetry ----------
    $teleSecret = Join-Path $tempRoot 'telemetry-secret'
    New-Item -ItemType Directory -Path $teleSecret -Force | Out-Null
    $w1 = Write-McpSafetyTelemetryEvent -EventName 'MCP_TIMEOUT' -Server 'mcp-test sk-SYNTHETICSECRET-9 token=abc123' -Capability 'test.probe extra sk-SYNTHETICSECRET-9' -TurnId 'turn-ac9-1' -Class 'advisory' -Criticality 'optional' -Status 'MCP_TIMEOUT' -ElapsedMs 1000 -BudgetS 1 -Consecutive 1 -Circuit 'CLOSED' -TelemetryRoot $teleSecret -RepoRoot $repo
    Assert-McpSafety ([bool]$w1.ok) '[AC9] secret-bearing event accepted for write' ([string]$w1.skipped)
    $teleText = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $teleSecret -Filter 'mcp-safety-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $teleText += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    Assert-McpSafety ((($teleText -notmatch 'SYNTHETICSECRET') -and ($teleText -notmatch 'abc123')) -and (($teleText -match 'REDACTED') -or ($teleText -match 'redacted'))) '[AC9] canary and secret redacted in JSONL' ''
    Assert-McpSafety (($teleText -match 'MCP_TIMEOUT') -and ($teleText -match 'mcp-safety')) '[AC9] event tokens persisted' ''
    $fpA = Get-McpSafetyCallFingerprint -Server 'srv-x' -Capability 'test.probe token=AAA111' -TurnId 'turn-ac9-2'
    $fpB = Get-McpSafetyCallFingerprint -Server 'srv-x' -Capability 'test.probe token=BBB222' -TurnId 'turn-ac9-2'
    $fpC = Get-McpSafetyCallFingerprint -Server 'srv-y' -Capability 'test.probe token=BBB222' -TurnId 'turn-ac9-2'
    Assert-McpSafety ((($fpA -ceq $fpB) -and ($fpA -cmatch '^[0-9a-f]{64}$')) -and ($fpA -notmatch 'AAA111')) '[AC9] fingerprint len:value converges secrets, 64-hex' ($fpA)
    Assert-McpSafety (($fpA -cne $fpC) -and ($fpC -notmatch 'BBB222')) '[AC9] fingerprint diverges per server' ''
    $teleCap = Join-Path $tempRoot 'telemetry-cap'
    New-Item -ItemType Directory -Path $teleCap -Force | Out-Null
    $savedCap = $script:McpSafetyTelemetryCapBytes
    $script:McpSafetyTelemetryCapBytes = 600
    try {
        $cw1 = Write-McpSafetyTelemetryEvent -EventName 'MCP_CALL_OK' -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac9-3' -TelemetryRoot $teleCap -RepoRoot $repo
        Assert-McpSafety ([bool]$cw1.ok) '[AC9] first cap event written' ([string]$cw1.skipped)
        $targetCap = Get-McpSafetyTelemetryFile -TelemetryRoot $teleCap -RepoRoot $repo
        $curLen = ([IO.FileInfo]::new($targetCap)).Length
        $script:McpSafetyTelemetryCapBytes = ($curLen + 10)
        $cw2 = Write-McpSafetyTelemetryEvent -EventName 'MCP_CALL_OK' -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac9-3' -TelemetryRoot $teleCap -RepoRoot $repo
        Assert-McpSafety (((-not [bool]$cw2.ok)) -and ([string]$cw2.skipped -ceq 'rotation-cap')) '[AC9] overflowing event honestly dropped' ([string]$cw2.skipped)
        $finalLen = ([IO.FileInfo]::new($targetCap)).Length
        Assert-McpSafety ($finalLen -le ($curLen + 10)) '[AC9] bounded file never exceeds cap' ([string]$finalLen)
    }
    finally { $script:McpSafetyTelemetryCapBytes = $savedCap }
    $teleAcct = Join-Path $tempRoot 'telemetry-acct'
    New-Item -ItemType Directory -Path $teleAcct -Force | Out-Null
    $script:McpSafetySimulateAccountingFailure = $true
    try {
        $af = Write-McpSafetyTelemetryEvent -EventName 'MCP_CALL_OK' -Server 'srv-a' -Capability 'test.probe' -TurnId 'turn-ac9-4' -TelemetryRoot $teleAcct -RepoRoot $repo
        Assert-McpSafety (((-not [bool]$af.ok)) -and ([string]$af.skipped -ceq 'accounting-unavailable')) '[AC9] accounting failure refuses write fail-closed' ([string]$af.skipped)
        $acctFiles = @(Get-ChildItem -LiteralPath $teleAcct -Filter 'mcp-safety-*.jsonl' -File -ErrorAction SilentlyContinue)
        Assert-McpSafety (@($acctFiles).Count -eq 0) '[AC9] failed accounting wrote nothing' ''
    }
    finally { $script:McpSafetySimulateAccountingFailure = $false }

    # ---------- FIX1 R1: non-cooperative probe abandoned, caller never hangs ----------
    Clear-McpSafetyState
    $savedSettle = 5000
    try { $savedSettle = [int]$script:McpSafetySettleMarginMs } catch { $savedSettle = 5000 }
    $script:McpSafetySettleMarginMs = 2000
    $abBefore = 0
    try { $abBefore = [int]$script:McpSafetyAbandonedCount } catch { $abBefore = 0 }
    $mtxName = ('McpSafetyR1' + [guid]::NewGuid().ToString('N'))
    $mtx = New-Object System.Threading.Mutex($false, $mtxName)
    [void]$mtx.WaitOne()
    try {
        $ncCode = '$m = New-Object System.Threading.Mutex($false, ''' + $mtxName + '''); [void]$m.WaitOne(); ''never-reached'''
        $ncProbe = [scriptblock]::Create($ncCode)
        $swR1 = [System.Diagnostics.Stopwatch]::StartNew()
        $rNc = Invoke-McpSafetyCall -Server 'srv-r1' -Capability 'test.probe' -TurnId 'turn-fixr1-1' -Class 'advisory' -Criticality 'required' -Probe $ncProbe -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        $swR1.Stop()
        Assert-McpSafety (([string]$rNc.failure -ceq 'MCP_TIMEOUT') -and (-not [bool]$rNc.settled)) '[R1] non-cooperative overrun abandoned with settled=false' (([string]$rNc.failure + '/' + [string]$rNc.settled))
        Assert-McpSafety ([int]$swR1.Elapsed.TotalMilliseconds -lt (1000 + 2000 + 3000)) '[R1] caller returns within budget plus settle plus slack' ([string][int]$swR1.Elapsed.TotalMilliseconds)
        $abAfter = 0
        try { $abAfter = [int]$script:McpSafetyAbandonedCount } catch { $abAfter = 0 }
        Assert-McpSafety ($abAfter -eq ($abBefore + 1)) '[R1] abandon counter bumped exactly once' (($abBefore.ToString()) + '->' + ($abAfter.ToString()))
        $abText = ''
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $teleRoot -Filter 'mcp-safety-*.jsonl' -File -ErrorAction SilentlyContinue)) {
                $abText += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
            }
        }
        catch { }
        Assert-McpSafety ($abText -match 'MCP_PROBE_ABANDONED') '[R1] abandon telemetry event persisted' ''
    }
    finally {
        try { $mtx.ReleaseMutex() } catch { }
        try { $mtx.Dispose() } catch { }
        $script:McpSafetySettleMarginMs = $savedSettle
    }
    $rAfter = Invoke-McpSafetyCall -Server 'srv-r1' -Capability 'test.probe' -TurnId 'turn-fixr1-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$rAfter.status -ceq 'OK') -and ([bool]$rAfter.settled)) '[R1] orchestration not stuck: subsequent call works' ([string]$rAfter.status)
    Assert-McpSafety ([bool]$rSlow.settled) '[R1] cooperative sleep settles normally with settled=true' ''

    # ---------- FIX1 R2: cooldown measured from conclusion ----------
    Clear-McpSafetyState
    $pol60 = Join-Path $polDir 'cooldown60.json'
    $raw60 = [IO.File]::ReadAllText($repoPolicy, [Text.UTF8Encoding]::new($false)) -replace '"cooldown_seconds": 300', '"cooldown_seconds": 60'
    Write-McpSafetyFixture -Path $pol60 -Text $raw60
    $v60 = Assert-McpSafetyPolicyJson -Path $pol60
    Assert-McpSafety ([bool]$v60.valid) '[R2] cooldown-60 fixture policy validates' ((@($v60.errors) -join '|'))
    $t2 = [DateTime]::UtcNow
    $end2 = $t2.AddSeconds(120)
    [void](Invoke-McpSafetyCall -Server 'srv-r2' -Capability 'test.probe' -TurnId 'turn-fixr2-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $pol60 -TelemetryRoot $teleRoot -NowUtc $t2 -ConcludedAtUtc $end2)
    $r2b = Invoke-McpSafetyCall -Server 'srv-r2' -Capability 'test.probe' -TurnId 'turn-fixr2-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $pol60 -TelemetryRoot $teleRoot -NowUtc $t2 -ConcludedAtUtc $end2
    Assert-McpSafety ([string]$r2b.circuit -ceq 'OPEN') '[R2] two slow failures open circuit' ([string]$r2b.circuit)
    $stR2 = Get-McpSafetyCircuitState -Server 'srv-r2' -Capability 'test.probe' -TurnId 'turn-fixr2-1' -NowUtc ($t2.AddSeconds(150)) -CooldownSeconds 60
    Assert-McpSafety ([string]$stR2.state -ceq 'OPEN') '[R2] cooldown counts from conclusion: still OPEN 30s after end' ([string]$stR2.state)
    $openStamp = [DateTimeOffset]::MinValue
    try { $openStamp = [DateTimeOffset]::Parse([string]$stR2.opened_at_utc) } catch { }
    Assert-McpSafety (($openStamp.UtcDateTime -eq $end2)) '[R2] opened_at equals conclusion clock' ([string]$stR2.opened_at_utc)

    # ---------- FIX1 R3: guarded close never overwrites newer OPEN ----------
    Clear-McpSafetyState
    $t3 = [DateTime]::UtcNow
    [void](Invoke-McpSafetyCall -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $t3)
    [void](Invoke-McpSafetyCall -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $t3)
    $keyR3 = Get-McpSafetyCircuitKey -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1'
    $stGen1 = Get-McpSafetyCircuitState -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1' -NowUtc $t3 -CooldownSeconds 300
    Assert-McpSafety ([string]$stGen1.state -ceq 'OPEN') '[R3] gen1 open recorded' ([string]$stGen1.state)
    Set-McpSafetyCircuitRecord -Key $keyR3 -Consecutive 5 -State 'OPEN' -OpenedAtUtc ($t3.AddSeconds(10))
    $stale = Set-McpSafetyCircuitClosedIfGeneration -Key $keyR3 -ExpectedOpenedAtUtc ([string]$stGen1.opened_at_utc) -ExpectedConsecutive ([int]$stGen1.consecutive)
    $stAfter = Get-McpSafetyCircuitState -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1' -NowUtc ($t3.AddSeconds(11)) -CooldownSeconds 300
    Assert-McpSafety (((-not $stale)) -and ([string]$stAfter.state -ceq 'OPEN') -and ([int]$stAfter.consecutive -eq 5)) '[R3] stale success never overwrites newer OPEN' ([string]$stAfter.consecutive)
    $fresh2 = Set-McpSafetyCircuitClosedIfGeneration -Key $keyR3 -ExpectedOpenedAtUtc ([string]$stAfter.opened_at_utc) -ExpectedConsecutive ([int]$stAfter.consecutive)
    $stClosed = Get-McpSafetyCircuitState -Server 'srv-r3' -Capability 'test.probe' -TurnId 'turn-fixr3-1' -NowUtc ($t3.AddSeconds(11)) -CooldownSeconds 300
    Assert-McpSafety (([bool]$fresh2) -and ([string]$stClosed.state -ceq 'CLOSED') -and ([int]$stClosed.consecutive -eq 0)) '[R3] current generation still closes' ([string]$stClosed.state)

    # ---------- FIX1 R4: long-running connect uses policy connect budget ----------
    Clear-McpSafetyState
    $r4c = Invoke-McpSafetyCall -Server 'srv-r4' -Capability 'test.long' -TurnId 'turn-fixr4-1' -Class 'long_running' -Phase 'connect' -TaskContractId 'contract-9' -BudgetSeconds 3600 -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$r4c.status -ceq 'OK') -and ([int]$r4c.budget_s -eq 20)) '[R4] long-running connect uses policy connect budget, not contract seconds' ([string]$r4c.budget_s)
    $r4e = Invoke-McpSafetyCall -Server 'srv-r4' -Capability 'test.long' -TurnId 'turn-fixr4-2' -Class 'long_running' -Phase 'execute' -TaskContractId 'contract-9' -BudgetSeconds 3600 -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$r4e.status -ceq 'OK') -and ([int]$r4e.budget_s -eq 3600)) '[R4] long-running execute keeps explicit contract budget' ([string]$r4e.budget_s)

    # ---------- FIX1 R5: every persisted text field sanitized, class/status allowlisted ----------
    $teleR5 = Join-Path $tempRoot 'telemetry-r5'
    New-Item -ItemType Directory -Path $teleR5 -Force | Out-Null
    $wR5 = Write-McpSafetyTelemetryEvent -EventName 'MCP_TIMEOUT' -Server 'srv-r5 sk-SYNTHETICSECRET-1 token=abc123' -Capability 'test.probe sk-SYNTHETICSECRET-2 token=abc123' -TurnId 'turn-fixr5-1' -Class 'advisory token=abc123 sk-SYNTHETICSECRET-3' -Criticality 'optional' -Status 'MCP_TIMEOUT token=abc123 sk-SYNTHETICSECRET-4' -ElapsedMs 5 -BudgetS 1 -Consecutive 1 -Circuit 'CLOSED' -TelemetryRoot $teleR5 -RepoRoot $repo
    Assert-McpSafety ([bool]$wR5.ok) '[R5] hostile-fields event accepted' ([string]$wR5.skipped)
    $r5Text = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $teleR5 -Filter 'mcp-safety-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $r5Text += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    Assert-McpSafety ((($r5Text -notmatch 'SYNTHETICSECRET') -and ($r5Text -notmatch 'abc123')) -and ($r5Text -match 'INVALID')) '[R5] every text field sanitized, class/status mapped to INVALID' ''

    # ---------- FIX1 R6: probe error redacted at the boundary ----------
    Clear-McpSafetyState
    $evilProbe = { throw 'kaboom sk-SYNTHETICSECRET-5 token=abc123' }
    $r6 = Invoke-McpSafetyCall -Server 'srv-r6' -Capability 'test.probe' -TurnId 'turn-fixr6-1' -Class 'advisory' -Probe $evilProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$r6.status -ceq 'MCP_ERROR') -and (($r6.probe_error -notmatch 'SYNTHETICSECRET') -and ($r6.probe_error -notmatch 'abc123')) -and (([string]$r6.probe_error).Length -le 256)) '[R6] probe error redacted and truncated at boundary' ([string]$r6.probe_error)

    # ---------- FIX2 F1: bounded lock wait, busy never runs the seam ----------
    Clear-McpSafetyState
    $keyF1 = Get-McpSafetyCircuitKey -Server 'srv-f1' -Capability 'test.probe' -TurnId 'turn-fixf1-1'
    $lkF1 = Get-McpSafetyCircuitLock -Key $keyF1
    $acqF1 = New-Object System.Threading.ManualResetEvent($false)
    $relF1 = New-Object System.Threading.ManualResetEvent($false)
    $bgRs = $null
    $bgPs = $null
    $bgHandle = $null
    try {
        $bgRs = [runspacefactory]::CreateRunspace()
        $bgRs.Open()
        $bgPs = [powershell]::Create()
        $bgPs.Runspace = $bgRs
        [void]$bgPs.AddScript({
            param($lk, $acq, $rel)
            [System.Threading.Monitor]::Enter($lk)
            try { [void]$acq.Set() } catch { }
            try { [void]$rel.WaitOne(15000) } catch { }
            try { [System.Threading.Monitor]::Exit($lk) } catch { }
        })
        [void]$bgPs.AddArgument($lkF1)
        [void]$bgPs.AddArgument($acqF1)
        [void]$bgPs.AddArgument($relF1)
        $bgHandle = $bgPs.BeginInvoke()
        $heldF1 = $false
        try { $heldF1 = $acqF1.WaitOne(10000) } catch { $heldF1 = $false }
        Assert-McpSafety ([bool]$heldF1) '[F1] background holder acquired the key lock' ''
        $markerF1 = Join-Path $tempRoot 'hitsf1.txt'
        $markF1 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerF1', 'hit;'); 'ran'")
        $swF1 = [System.Diagnostics.Stopwatch]::StartNew()
        $rBusy = Invoke-McpSafetyCall -Server 'srv-f1' -Capability 'test.probe' -TurnId 'turn-fixf1-1' -Class 'advisory' -Criticality 'optional' -Probe $markF1 -BudgetSecondsOverride 5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        $swF1.Stop()
        Assert-McpSafety (([string]$rBusy.status -ceq 'MCP_LOCK_BUSY') -and (-not [bool]$rBusy.ok) -and ([bool]$rBusy.fallback_continue) -and (-not [bool]$rBusy.blocked)) '[F1] contention yields immediate MCP_LOCK_BUSY fallback' ([string]$rBusy.status)
        Assert-McpSafety ([int]$swF1.Elapsed.TotalMilliseconds -lt 5000) '[F1] busy returns within bounded lock wait' ([string][int]$swF1.Elapsed.TotalMilliseconds)
        Assert-McpSafety ((Get-McpSafetyHits -Path $markerF1) -eq 0) '[F1] seam invoked 0 times on lock-busy' ([string](Get-McpSafetyHits -Path $markerF1))
        $stF1 = Get-McpSafetyCircuitState -Server 'srv-f1' -Capability 'test.probe' -TurnId 'turn-fixf1-1' -CooldownSeconds 300
        Assert-McpSafety (([string]$stF1.state -ceq 'CLOSED') -and ([int]$stF1.consecutive -eq 0)) '[F1] contention never touches the circuit streak' (([string]$stF1.state + '/' + [string]$stF1.consecutive))
        $rBusyReq = Invoke-McpSafetyCall -Server 'srv-f1' -Capability 'test.probe' -TurnId 'turn-fixf1-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -BudgetSecondsOverride 5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        Assert-McpSafety (([string]$rBusyReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$rBusyReq.failure -ceq 'MCP_LOCK_BUSY') -and ([bool]$rBusyReq.blocked)) '[F1] required plus contention stays blocked with lock cause' ([string]$rBusyReq.status)
    }
    finally {
        try { [void]$relF1.Set() } catch { }
        try {
            if (($null -ne $bgPs) -and ($null -ne $bgHandle)) { $bgPs.EndInvoke($bgHandle) | Out-Null }
        }
        catch { }
        try { if ($null -ne $bgPs) { $bgPs.Dispose() } } catch { }
        try { if ($null -ne $bgRs) { $bgRs.Close() } } catch { }
        try { if ($null -ne $bgRs) { $bgRs.Dispose() } } catch { }
    }
    $rFree = Invoke-McpSafetyCall -Server 'srv-f1' -Capability 'test.probe' -TurnId 'turn-fixf1-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$rFree.status -ceq 'OK') '[F1] call works after lock release' ([string]$rFree.status)

    # ---------- FIX2 F2: abandon cap refuses fail-closed, never recovers ----------
    Clear-McpSafetyState
    $hook0 = Set-McpSafetyCapacityInUse -Count 8
    Assert-McpSafety (([bool]$hook0.ok) -and ([int]$hook0.occupancy -eq 8)) '[F2] test hook sets occupancy' ([string]$hook0.occupancy)
    $capOpt = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-1' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$capOpt.status -ceq 'MCP_ABANDON_LIMIT_REACHED') -and (-not [bool]$capOpt.ok) -and ([bool]$capOpt.fallback_continue) -and (-not [bool]$capOpt.blocked)) '[F2] at cap optional refused with fallback' ([string]$capOpt.status)
    $capReq = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$capReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$capReq.failure -ceq 'MCP_ABANDON_LIMIT_REACHED') -and (-not [bool]$capReq.ok) -and ([bool]$capReq.blocked) -and (-not [bool]$capReq.fallback_continue)) '[F2] at cap required refused blocked' (([string]$capReq.status + '/' + [string]$capReq.failure))
    [void](Set-McpSafetyCapacityInUse -Count 7)
    $belowCap = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$belowCap.status -ceq 'OK') -and ([int](Get-McpSafetyCapacityInUse) -eq 7)) '[F2] below cap executes and releases back' ([string]$belowCap.status)
    [void](Set-McpSafetyCapacityInUse -Count 1)
    $settleOne = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-2' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$settleOne.status -ceq 'OK') -and ([int](Get-McpSafetyCapacityInUse) -eq 1)) '[F2] proven settlement releases back to baseline' ([string]$settleOne.status)
    [void](Set-McpSafetyCapacityInUse -Count 0)
    $settleZero = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-4' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$settleZero.status -ceq 'OK') -and ([int](Get-McpSafetyCapacityInUse) -eq 0)) '[F2] proven settlement releases to zero' ([string]$settleZero.status)
    [void](Set-McpSafetyCapacityInUse -Count 8)
    $stillCapped = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-3' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$stillCapped.status -ceq 'MCP_ABANDON_LIMIT_REACHED') '[F2] cap never reclaims without settlement' ([string]$stillCapped.status)
    $savedSettle2 = 5000
    try { $savedSettle2 = [int]$script:McpSafetySettleMarginMs } catch { $savedSettle2 = 5000 }
    $script:McpSafetySettleMarginMs = 2000
    $mtxName2 = ('McpSafetyF2B' + [guid]::NewGuid().ToString('N'))
    $mtx2 = New-Object System.Threading.Mutex($false, $mtxName2)
    [void]$mtx2.WaitOne()
    try {
        [void](Set-McpSafetyCapacityInUse -Count 7)
        $ncCode2 = '$m = New-Object System.Threading.Mutex($false, ''' + $mtxName2 + '''); [void]$m.WaitOne(); ''never-reached'''
        $ncProbe2 = [scriptblock]::Create($ncCode2)
        $rAb = Invoke-McpSafetyCall -Server 'srv-f2' -Capability 'test.probe' -TurnId 'turn-fixf2-5' -Class 'advisory' -Criticality 'required' -Probe $ncProbe2 -BudgetSecondsOverride 1 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        Assert-McpSafety (([string]$rAb.failure -ceq 'MCP_TIMEOUT') -and (-not [bool]$rAb.settled) -and ([int](Get-McpSafetyCapacityInUse) -eq 8)) '[F2] abandonment consumes capacity permanently' (([string]$rAb.failure + '/' + [string](Get-McpSafetyCapacityInUse)))
    }
    finally {
        try { $mtx2.ReleaseMutex() } catch { }
        try { $mtx2.Dispose() } catch { }
        $script:McpSafetySettleMarginMs = $savedSettle2
    }
    Clear-McpSafetyState

    # ---------- FIX4 G1: bounded Gate reads, honest unconfirmed release ----------
    Clear-McpSafetyState
    $gateObj = $null
    try { $gateObj = [McpSafetyCapacityCell]::Gate } catch { $gateObj = $null }
    Assert-McpSafety ($null -ne $gateObj) '[G1] shared Gate object reachable' ''
    $gAcq = New-Object System.Threading.ManualResetEvent($false)
    $gRel = New-Object System.Threading.ManualResetEvent($false)
    $gRs = $null
    $gPs = $null
    $gH = $null
    try {
        $gRs = [runspacefactory]::CreateRunspace()
        $gRs.Open()
        $gPs = [powershell]::Create()
        $gPs.Runspace = $gRs
        [void]$gPs.AddScript({
            param($gate, $acq, $rel)
            [System.Threading.Monitor]::Enter($gate)
            try { [void]$acq.Set() } catch { }
            try { [void]$rel.WaitOne(25000) } catch { }
            try { [System.Threading.Monitor]::Exit($gate) } catch { }
        })
        [void]$gPs.AddArgument($gateObj)
        [void]$gPs.AddArgument($gAcq)
        [void]$gPs.AddArgument($gRel)
        $gH = $gPs.BeginInvoke()
        $gHeld = $false
        try { $gHeld = $gAcq.WaitOne(10000) } catch { $gHeld = $false }
        Assert-McpSafety ([bool]$gHeld) '[G1] background holder owns Gate' ''
        $swG1 = [System.Diagnostics.Stopwatch]::StartNew()
        $relG1 = Release-McpSafetyCapacity -TimeoutMs 1000
        $swG1.Stop()
        Assert-McpSafety (((-not [bool]$relG1.released)) -and ([string]$relG1.status -ceq 'RELEASE_UNCONFIRMED')) '[G1] release under held Gate stays honest unconfirmed' ([string]$relG1.status)
        Assert-McpSafety ([int]$swG1.Elapsed.TotalMilliseconds -lt 8000) '[G1] unconfirmed release returns bounded' ([string][int]$swG1.Elapsed.TotalMilliseconds)
        Assert-McpSafety ([int](Get-McpSafetyCapacityInUse -TimeoutMs 1000) -eq -1) '[G1] occupancy reads UNKNOWN while Gate held' ([string](Get-McpSafetyCapacityInUse -TimeoutMs 1000))
    }
    finally {
        try { [void]$gRel.Set() } catch { }
        try {
            if (($null -ne $gPs) -and ($null -ne $gH)) { $gPs.EndInvoke($gH) | Out-Null }
        }
        catch { }
        try { if ($null -ne $gPs) { $gPs.Dispose() } } catch { }
        try { if ($null -ne $gRs) { $gRs.Close() } } catch { }
        try { if ($null -ne $gRs) { $gRs.Dispose() } } catch { }
    }
    $relOk = Release-McpSafetyCapacity -TimeoutMs 1000
    Assert-McpSafety (([bool]$relOk.released) -and ([string]$relOk.status -ceq 'RELEASED')) '[G1] operations normal after Gate release' ([string]$relOk.status)
    Clear-McpSafetyState

    # ---------- FIX4 G2: missing cell fails closed, never executes ----------
    Clear-McpSafetyState
    [void](Set-McpSafetyCapacityCellUnavailable $true)
    $markerG2 = Join-Path $tempRoot 'hitsg2.txt'
    $markG2 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerG2', 'hit;'); 'ran'")
    $cellOpt = Invoke-McpSafetyCall -Server 'srv-g2' -Capability 'test.probe' -TurnId 'turn-fixg2-1' -Class 'advisory' -Criticality 'optional' -Probe $markG2 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$cellOpt.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([string]$cellOpt.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$cellOpt.ok) -and ([bool]$cellOpt.fallback_continue) -and (-not [bool]$cellOpt.blocked)) '[G2] forced-missing cell refuses optional with fallback' (([string]$cellOpt.status + '/' + [string]$cellOpt.failure))
    $cellReq = Invoke-McpSafetyCall -Server 'srv-g2' -Capability 'test.probe' -TurnId 'turn-fixg2-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$cellReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$cellReq.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$cellReq.ok) -and ([bool]$cellReq.blocked) -and (-not [bool]$cellReq.fallback_continue)) '[G2] forced-missing cell refuses required blocked' (([string]$cellReq.status + '/' + [string]$cellReq.failure))
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerG2) -eq 0) '[G2] no seam runs without the shared cell' ([string](Get-McpSafetyHits -Path $markerG2))
    [void](Set-McpSafetyCapacityCellUnavailable $false)
    $cellBack = Invoke-McpSafetyCall -Server 'srv-g2' -Capability 'test.probe' -TurnId 'turn-fixg2-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$cellBack.status -ceq 'OK') '[G2] restored cell executes normally' ([string]$cellBack.status)
    Clear-McpSafetyState

    # ---------- FIX5 H1: guard contention refuses bounded without seam ----------
    Clear-McpSafetyState
    $keyGuard = Get-McpSafetySharedGate -Name 'KeyGuard'
    Assert-McpSafety ($null -ne $keyGuard) '[H1] shared KeyGuard reachable' ''
    $kgAcq = New-Object System.Threading.ManualResetEvent($false)
    $kgRel = New-Object System.Threading.ManualResetEvent($false)
    $kgRs = $null
    $kgPs = $null
    $kgH = $null
    try {
        $kgRs = [runspacefactory]::CreateRunspace()
        $kgRs.Open()
        $kgPs = [powershell]::Create()
        $kgPs.Runspace = $kgRs
        [void]$kgPs.AddScript({
            param($gate, $acq, $rel)
            [System.Threading.Monitor]::Enter($gate)
            try { [void]$acq.Set() } catch { }
            try { [void]$rel.WaitOne(25000) } catch { }
            try { [System.Threading.Monitor]::Exit($gate) } catch { }
        })
        [void]$kgPs.AddArgument($keyGuard)
        [void]$kgPs.AddArgument($kgAcq)
        [void]$kgPs.AddArgument($kgRel)
        $kgH = $kgPs.BeginInvoke()
        $kgHeld = $false
        try { $kgHeld = $kgAcq.WaitOne(10000) } catch { $kgHeld = $false }
        Assert-McpSafety ([bool]$kgHeld) '[H1] background holder owns KeyGuard' ''
        $occBase = [int](Get-McpSafetyCapacityInUse)
        $markerH1 = Join-Path $tempRoot 'hitsh1.txt'
        $markH1 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerH1', 'hit;'); 'ran'")
        $swH1 = [System.Diagnostics.Stopwatch]::StartNew()
        $rGuard = Invoke-McpSafetyCall -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-1' -Class 'advisory' -Criticality 'optional' -Probe $markH1 -BudgetSecondsOverride 5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        $swH1.Stop()
        Assert-McpSafety (([string]$rGuard.status -ceq 'MCP_LOCK_BUSY') -and (-not [bool]$rGuard.ok) -and ([bool]$rGuard.fallback_continue)) '[H1] guard contention yields bounded MCP_LOCK_BUSY' ([string]$rGuard.status)
        Assert-McpSafety ([int]$swH1.Elapsed.TotalMilliseconds -lt 5000) '[H1] guard refusal returns bounded' ([string][int]$swH1.Elapsed.TotalMilliseconds)
        Assert-McpSafety ((Get-McpSafetyHits -Path $markerH1) -eq 0) '[H1] guard refusal runs 0 seam' ([string](Get-McpSafetyHits -Path $markerH1))
        $rGuardReq = Invoke-McpSafetyCall -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -BudgetSecondsOverride 5 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        Assert-McpSafety (([string]$rGuardReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$rGuardReq.failure -ceq 'MCP_LOCK_BUSY')) '[H1] guard contention blocks required with lock cause' ([string]$rGuardReq.status)
        Assert-McpSafety ([int](Get-McpSafetyCapacityInUse) -eq $occBase) '[H1] guard refusal leaks no capacity' ([string](Get-McpSafetyCapacityInUse))
        $stH1 = Get-McpSafetyCircuitState -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-1' -CooldownSeconds 300
        Assert-McpSafety (([string]$stH1.state -ceq 'CLOSED') -and ([int]$stH1.consecutive -eq 0)) '[H1] guard refusal never touches streak' ''
    }
    finally {
        try { [void]$kgRel.Set() } catch { }
        try {
            if (($null -ne $kgPs) -and ($null -ne $kgH)) { $kgPs.EndInvoke($kgH) | Out-Null }
        }
        catch { }
        try { if ($null -ne $kgPs) { $kgPs.Dispose() } } catch { }
        try { if ($null -ne $kgRs) { $kgRs.Close() } } catch { }
        try { if ($null -ne $kgRs) { $kgRs.Dispose() } } catch { }
    }
    $rGuardFree = Invoke-McpSafetyCall -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-1' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety ([string]$rGuardFree.status -ceq 'OK') '[H1] call works after guard release' ([string]$rGuardFree.status)
    Clear-McpSafetyState

    # ---------- FIX5 H1: telemetry contention skips, never blocks ----------
    $teleGate = Get-McpSafetySharedGate -Name 'TelemetryGate'
    Assert-McpSafety ($null -ne $teleGate) '[H1] shared TelemetryGate reachable' ''
    $tgAcq = New-Object System.Threading.ManualResetEvent($false)
    $tgRel = New-Object System.Threading.ManualResetEvent($false)
    $tgRs = $null
    $tgPs = $null
    $tgH = $null
    try {
        $tgRs = [runspacefactory]::CreateRunspace()
        $tgRs.Open()
        $tgPs = [powershell]::Create()
        $tgPs.Runspace = $tgRs
        [void]$tgPs.AddScript({
            param($gate, $acq, $rel)
            [System.Threading.Monitor]::Enter($gate)
            try { [void]$acq.Set() } catch { }
            try { [void]$rel.WaitOne(25000) } catch { }
            try { [System.Threading.Monitor]::Exit($gate) } catch { }
        })
        [void]$tgPs.AddArgument($teleGate)
        [void]$tgPs.AddArgument($tgAcq)
        [void]$tgPs.AddArgument($tgRel)
        $tgH = $tgPs.BeginInvoke()
        $tgHeld = $false
        try { $tgHeld = $tgAcq.WaitOne(10000) } catch { $tgHeld = $false }
        Assert-McpSafety ([bool]$tgHeld) '[H1] background holder owns TelemetryGate' ''
        $teleHeld = Join-Path $tempRoot 'telemetry-held'
        New-Item -ItemType Directory -Path $teleHeld -Force | Out-Null
        $wHeld = Write-McpSafetyTelemetryEvent -EventName 'MCP_CALL_OK' -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-2' -TelemetryRoot $teleHeld -RepoRoot $repo
        Assert-McpSafety (((-not [bool]$wHeld.ok)) -and ([string]$wHeld.skipped -ceq 'lock-busy')) '[H1] contended telemetry honestly skipped' ([string]$wHeld.skipped)
        $swTele = [System.Diagnostics.Stopwatch]::StartNew()
        $rTeleOk = Invoke-McpSafetyCall -Server 'srv-h1' -Capability 'test.probe' -TurnId 'turn-fixh1-3' -Class 'advisory' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleHeld
        $swTele.Stop()
        Assert-McpSafety (([string]$rTeleOk.status -ceq 'OK') -and ([int]$swTele.Elapsed.TotalMilliseconds -lt 8000)) '[H1] call path never blocks on telemetry' ([string]$rTeleOk.status)
    }
    finally {
        try { [void]$tgRel.Set() } catch { }
        try {
            if (($null -ne $tgPs) -and ($null -ne $tgH)) { $tgPs.EndInvoke($tgH) | Out-Null }
        }
        catch { }
        try { if ($null -ne $tgPs) { $tgPs.Dispose() } } catch { }
        try { if ($null -ne $tgRs) { $tgRs.Close() } } catch { }
        try { if ($null -ne $tgRs) { $tgRs.Dispose() } } catch { }
    }

    # ---------- FIX5 H3: internal-only codes never persist ----------
    $teleH3 = Join-Path $tempRoot 'telemetry-h3'
    New-Item -ItemType Directory -Path $teleH3 -Force | Out-Null
    $wH3 = Write-McpSafetyTelemetryEvent -EventName 'MCP_CALL_OK' -Server 'srv-h3' -Capability 'test.probe' -TurnId 'turn-fixh3-1' -Class 'advisory' -Criticality 'optional' -Status 'RELEASE_UNCONFIRMED' -TelemetryRoot $teleH3 -RepoRoot $repo
    Assert-McpSafety ([bool]$wH3.ok) '[H3] probe status accepted for write' ([string]$wH3.skipped)
    $h3Text = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $teleH3 -Filter 'mcp-safety-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $h3Text += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    Assert-McpSafety (($h3Text -match '"status":"INVALID"') -and ($h3Text -notmatch 'RELEASE_UNCONFIRMED')) '[H3] internal-only code maps to INVALID, never persists raw' ''

    # ---------- FIX3/FIX4 FX3: simultaneous barrier honors the atomic cap ----------
    Clear-McpSafetyState
    [void](Set-McpSafetyCapacityInUse -Count 7)
    Assert-McpSafety ([int](Get-McpSafetyCapacityInUse) -eq 7) '[FX3] boundary occupancy staged at 7' ([string](Get-McpSafetyCapacityInUse))
    $mtxName3 = ('McpSafetyFX3' + [guid]::NewGuid().ToString('N'))
    $mtx3 = New-Object System.Threading.Mutex($false, $mtxName3)
    [void]$mtx3.WaitOne()
    $markerA = Join-Path $tempRoot 'hitsfx3a.txt'
    $markerB = Join-Path $tempRoot 'hitsfx3b.txt'
    $codeA = "[IO.File]::AppendAllText('$markerA', 'hit;'); " + '$m = New-Object System.Threading.Mutex($false, ''' + $mtxName3 + '''); [void]$m.WaitOne(); ''slow-never'''
    $codeB = "[IO.File]::AppendAllText('$markerB', 'hit;'); " + '$m = New-Object System.Threading.Mutex($false, ''' + $mtxName3 + '''); [void]$m.WaitOne(); ''slow-never'''
    $readyA = New-Object System.Threading.ManualResetEvent($false)
    $readyB = New-Object System.Threading.ManualResetEvent($false)
    $startGate = New-Object System.Threading.ManualResetEvent($false)
    $bgA = $null
    $psA = $null
    $hA = $null
    $bgB = $null
    $psB = $null
    $hB = $null
    $rA = $null
    $rB = $null
    try {
        $bgA = [runspacefactory]::CreateRunspace()
        $bgA.Open()
        $psA = [powershell]::Create()
        $psA.Runspace = $bgA
        [void]$psA.AddScript({
            param($lib, $policy, $tele, $code, $turn, $ready, $gate)
            . $lib
            try { [void]$ready.Set() } catch { }
            try { [void]$gate.WaitOne(15000) } catch { }
            $probe = [scriptblock]::Create($code)
            $fxCall = Invoke-McpSafetyCall -Server 'srv-fx3' -Capability 'test.probe' -TurnId $turn -Class 'advisory' -Criticality 'optional' -Probe $probe -BudgetSecondsOverride 1 -PolicyPath $policy -TelemetryRoot $tele
            $fxState = Get-McpSafetyCircuitState -Server 'srv-fx3' -Capability 'test.probe' -TurnId $turn -CooldownSeconds 300
            $fxCall
            $fxState
        })
        [void]$psA.AddArgument($libPath)
        [void]$psA.AddArgument($repoPolicy)
        [void]$psA.AddArgument($teleRoot)
        [void]$psA.AddArgument($codeA)
        [void]$psA.AddArgument('turn-fx3-a')
        [void]$psA.AddArgument($readyA)
        [void]$psA.AddArgument($startGate)
        $hA = $psA.BeginInvoke()
        $bgB = [runspacefactory]::CreateRunspace()
        $bgB.Open()
        $psB = [powershell]::Create()
        $psB.Runspace = $bgB
        [void]$psB.AddScript({
            param($lib, $policy, $tele, $code, $turn, $ready, $gate)
            . $lib
            try { [void]$ready.Set() } catch { }
            try { [void]$gate.WaitOne(15000) } catch { }
            $probe = [scriptblock]::Create($code)
            $fxCall = Invoke-McpSafetyCall -Server 'srv-fx3' -Capability 'test.probe' -TurnId $turn -Class 'advisory' -Criticality 'optional' -Probe $probe -BudgetSecondsOverride 1 -PolicyPath $policy -TelemetryRoot $tele
            $fxState = Get-McpSafetyCircuitState -Server 'srv-fx3' -Capability 'test.probe' -TurnId $turn -CooldownSeconds 300
            $fxCall
            $fxState
        })
        [void]$psB.AddArgument($libPath)
        [void]$psB.AddArgument($repoPolicy)
        [void]$psB.AddArgument($teleRoot)
        [void]$psB.AddArgument($codeB)
        [void]$psB.AddArgument('turn-fx3-b')
        [void]$psB.AddArgument($readyB)
        [void]$psB.AddArgument($startGate)
        $hB = $psB.BeginInvoke()
        $rdA = $false
        $rdB = $false
        try { $rdA = $readyA.WaitOne(15000) } catch { $rdA = $false }
        try { $rdB = $readyB.WaitOne(15000) } catch { $rdB = $false }
        Assert-McpSafety (([bool]$rdA) -and ([bool]$rdB)) '[FX3] both racers ready at the barrier' ''
        try { [void]$startGate.Set() } catch { }
        try { $rA = $psA.EndInvoke($hA) } catch { $rA = $null }
        try { $rB = $psB.EndInvoke($hB) } catch { $rB = $null }
    }
    finally {
        try { $mtx3.ReleaseMutex() } catch { }
        try { $mtx3.Dispose() } catch { }
        try { if ($null -ne $psA) { $psA.Dispose() } } catch { }
        try { if ($null -ne $bgA) { $bgA.Close() } } catch { }
        try { if ($null -ne $bgA) { $bgA.Dispose() } } catch { }
        try { if ($null -ne $psB) { $psB.Dispose() } } catch { }
        try { if ($null -ne $bgB) { $bgB.Close() } } catch { }
        try { if ($null -ne $bgB) { $bgB.Dispose() } } catch { }
    }
    $stA = ''
    $stB = ''
    $rstA = ''
    $rcoA = -1
    $rstB = ''
    $rcoB = -1
    if ($null -ne $rA) {
        $arrA = @($rA)
        try { $stA = ([string]$arrA[0].status) } catch { $stA = '' }
        try { $rstA = ([string]$arrA[1].state) } catch { $rstA = '' }
        try { $rcoA = [int]$arrA[1].consecutive } catch { $rcoA = -1 }
    }
    if ($null -ne $rB) {
        $arrB = @($rB)
        try { $stB = ([string]$arrB[0].status) } catch { $stB = '' }
        try { $rstB = ([string]$arrB[1].state) } catch { $rstB = '' }
        try { $rcoB = [int]$arrB[1].consecutive } catch { $rcoB = -1 }
    }
    $refusals = @('MCP_ABANDON_LIMIT_REACHED', 'MCP_BUSY_GLOBAL')
    $admittedCount = 0
    $refusedCount = 0
    foreach ($st in @($stA, $stB)) {
        if ($refusals -contains $st) { $refusedCount++ }
        elseif ($st -cne '') { $admittedCount++ }
    }
    Assert-McpSafety (($admittedCount -eq 1) -and ($refusedCount -eq 1)) '[FX3] exactly 1 admitted, 1 refused' (($stA + '/' + $stB))
    $seamRuns = ((Get-McpSafetyHits -Path $markerA) + (Get-McpSafetyHits -Path $markerB))
    Assert-McpSafety ($seamRuns -eq 1) '[FX3] refused racer never ran its seam' ([string]$seamRuns)
    $occFinal = [int](Get-McpSafetyCapacityInUse)
    Assert-McpSafety ($occFinal -eq 8) '[FX3] abandon keeps the last unit, cap holds' ([string]$occFinal)
    $refusedSideOk = $false
    $admittedClosed = $false
    if (($refusals -contains $stA) -and ($refusals -notcontains $stB)) {
        $refusedSideOk = (($rstA -ceq 'CLOSED') -and ($rcoA -eq 0))
        $admittedClosed = ($rstB -ceq 'CLOSED')
    }
    elseif (($refusals -contains $stB) -and ($refusals -notcontains $stA)) {
        $refusedSideOk = (($rstB -ceq 'CLOSED') -and ($rcoB -eq 0))
        $admittedClosed = ($rstA -ceq 'CLOSED')
    }
    Assert-McpSafety ([bool]$refusedSideOk) '[FX3] refused racer streak intact in its own session' (($rstA + '/' + $rcoA + '|' + $rstB + '/' + $rcoB))
    Assert-McpSafety ([bool]$admittedClosed) '[FX3] admitted racer never opens' ''
    Clear-McpSafetyState

    # ---------- FIX2 F3: required plus ordinary error blocks ----------
    $evilReq = Invoke-McpSafetyCall -Server 'srv-f3' -Capability 'test.probe' -TurnId 'turn-fixf3-1' -Class 'advisory' -Criticality 'required' -Probe $failOtherProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$evilReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$evilReq.failure -ceq 'MCP_ERROR') -and ([bool]$evilReq.blocked) -and (-not [bool]$evilReq.ok)) '[F3] required plus ordinary error yields blocked with error cause' ([string]$evilReq.status)

    # ---------- RR6 FIX6 H1: bounded tree conversion ----------
    Clear-McpSafetyState
    $cycleH = @{}
    $cycleH['self'] = $cycleH
    $cycleH['name'] = 'loop'
    $swCyc = [System.Diagnostics.Stopwatch]::StartNew()
    $cycOut = ConvertTo-McpSafetyOrdered -Node $cycleH
    $swCyc.Stop()
    Assert-McpSafety (($null -eq $cycOut) -and ([bool]$script:McpSafetyConvertOverflow) -and ([int]$swCyc.Elapsed.TotalSeconds -lt 10)) '[RR6-H1] self-referential hashtable terminates as structured overflow' ([string][int]$swCyc.Elapsed.TotalMilliseconds)
    $deepNest = 'leaf'
    for ($di = 0; $di -lt 50; $di++) { $deepNest = @{ level = $di; child = $deepNest } }
    $swDeep = [System.Diagnostics.Stopwatch]::StartNew()
    $deepOut = ConvertTo-McpSafetyOrdered -Node $deepNest
    $swDeep.Stop()
    Assert-McpSafety (($null -eq $deepOut) -and ([bool]$script:McpSafetyConvertOverflow) -and ([int]$swDeep.Elapsed.TotalSeconds -lt 10)) '[RR6-H1] nesting above depth cap terminates bounded' ([string][int]$swDeep.Elapsed.TotalMilliseconds)
    $wideH = @{}
    for ($wi = 0; $wi -lt 10100; $wi++) { $wideH[('k' + $wi)] = $wi }
    $wideOut = ConvertTo-McpSafetyOrdered -Node $wideH
    Assert-McpSafety (($null -eq $wideOut) -and ([bool]$script:McpSafetyConvertOverflow)) '[RR6-H1] node budget caps wide trees'
    $deepJsonText = ''
    for ($dj = 0; $dj -lt 45; $dj++) { $deepJsonText += '{ "wrap": ' }
    $deepJsonText += '1'
    for ($dj = 0; $dj -lt 45; $dj++) { $deepJsonText += '}' }
    $deepJsonPath = Join-Path $polDir 'deep.json'
    Write-McpSafetyFixture -Path $deepJsonPath -Text $deepJsonText
    $deepValid = Assert-McpSafetyPolicyJson -Path $deepJsonPath
    Assert-McpSafety (-not [bool]$deepValid.valid) '[RR6-H1] deep policy tree rejected as invalid, never throws' ((@($deepValid.errors) -join '|'))
    $deepCall = Invoke-McpSafetyCall -Server 'srv-dj' -Capability 'test.probe' -TurnId 'turn-rr6h1-1' -Class 'advisory' -Probe $okProbe -PolicyPath $deepJsonPath -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$deepCall.status -ceq 'MCP_POLICY_INVALID') -and ([bool]$deepCall.blocked) -and ([bool]$deepCall.fallback_continue)) '[RR6-H1] deep policy fails closed at the call boundary' ([string]$deepCall.status)
    $normSlot = Read-McpSafetyPolicy -PolicyPath $repoPolicy
    Assert-McpSafety (([bool]$normSlot.found) -and (-not [bool]$normSlot.malformed) -and (-not [bool]$script:McpSafetyConvertOverflow)) '[RR6-H1] normal policy still loads after bounded conversion'
    Clear-McpSafetyState

    # ---------- RR6 FIX6 H6: required matrix, every cause blocks ----------
    $reqTimeout = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-1' -Class 'advisory' -Criticality 'required' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqTimeout.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqTimeout.failure -ceq 'MCP_TIMEOUT') -and ([bool]$reqTimeout.blocked) -and (-not [bool]$reqTimeout.fallback_continue)) '[RR6-H6] required timeout blocks' (([string]$reqTimeout.status + '/' + [string]$reqTimeout.failure))
    [void](Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-2' -Class 'advisory' -Criticality 'required' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    [void](Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-2' -Class 'advisory' -Criticality 'required' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $reqOpen = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-2' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqOpen.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqOpen.failure -ceq 'MCP_CIRCUIT_OPEN') -and ([bool]$reqOpen.blocked)) '[RR6-H6] required circuit-open blocks' (([string]$reqOpen.status + '/' + [string]$reqOpen.failure))
    [void](Set-McpSafetyCapacityInUse -Count 8)
    $reqCap = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-3' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqCap.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqCap.failure -ceq 'MCP_ABANDON_LIMIT_REACHED') -and ([bool]$reqCap.blocked)) '[RR6-H6] required abandon-limit blocks' (([string]$reqCap.status + '/' + [string]$reqCap.failure))
    [void](Set-McpSafetyCapacityInUse -Count 0)
    [void](Set-McpSafetyCapacityCellUnavailable $true)
    $reqCell = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-4' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqCell.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqCell.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$reqCell.blocked)) '[RR6-H6] required cell-unavailable blocks' (([string]$reqCell.status + '/' + [string]$reqCell.failure))
    [void](Set-McpSafetyCapacityCellUnavailable $false)
    $reqPol = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-5' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $badJson -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqPol.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqPol.failure -ceq 'MCP_POLICY_INVALID') -and ([bool]$reqPol.blocked)) '[RR6-H6] required policy-invalid blocks' (([string]$reqPol.status + '/' + [string]$reqPol.failure))
    $reqExec = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6req-6' -Class 'advisory' -Criticality 'required' -Probe $failOtherProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqExec.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqExec.failure -ceq 'MCP_ERROR') -and ([bool]$reqExec.blocked)) '[RR6-H6] required exec-error blocks' (([string]$reqExec.status + '/' + [string]$reqExec.failure))

    # ---------- RR6 FIX6 H6: optional matrix, structured cause plus fallback ----------
    $optTimeout = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-1' -Class 'advisory' -Criticality 'optional' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optTimeout.status -ceq 'MCP_UNAVAILABLE') -and ([string]$optTimeout.failure -ceq 'MCP_TIMEOUT') -and ([bool]$optTimeout.fallback_continue) -and (-not [bool]$optTimeout.blocked)) '[RR6-H6] optional timeout falls back' (([string]$optTimeout.status + '/' + [string]$optTimeout.failure))
    [void](Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-2' -Class 'advisory' -Criticality 'optional' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    [void](Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-2' -Class 'advisory' -Criticality 'optional' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $optOpen = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-2' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optOpen.status -ceq 'MCP_UNAVAILABLE') -and ([string]$optOpen.failure -ceq 'MCP_CIRCUIT_OPEN') -and ([bool]$optOpen.fallback_continue) -and (-not [bool]$optOpen.blocked)) '[RR6-H6] optional circuit-open falls back' (([string]$optOpen.status + '/' + [string]$optOpen.failure))
    [void](Set-McpSafetyCapacityInUse -Count 8)
    $optCap = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-3' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optCap.status -ceq 'MCP_ABANDON_LIMIT_REACHED') -and ([string]$optCap.failure -ceq 'MCP_ABANDON_LIMIT_REACHED') -and ([bool]$optCap.fallback_continue) -and (-not [bool]$optCap.blocked)) '[RR6-H6] optional abandon-limit falls back' ([string]$optCap.status)
    [void](Set-McpSafetyCapacityInUse -Count 0)
    [void](Set-McpSafetyCapacityCellUnavailable $true)
    $optCell = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-4' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optCell.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$optCell.fallback_continue) -and (-not [bool]$optCell.blocked)) '[RR6-H6] optional cell-unavailable falls back' ([string]$optCell.status)
    [void](Set-McpSafetyCapacityCellUnavailable $false)
    $optPol = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-5' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $badJson -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optPol.status -ceq 'MCP_POLICY_INVALID') -and ([bool]$optPol.blocked) -and ([bool]$optPol.fallback_continue)) '[RR6-H6] optional policy-invalid still blocks with fallback' ([string]$optPol.status)
    $optExec = Invoke-McpSafetyCall -Server 'srv-m6' -Capability 'test.probe' -TurnId 'turn-rr6opt-6' -Class 'advisory' -Criticality 'optional' -Probe $failOtherProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optExec.status -ceq 'MCP_ERROR') -and ([string]$optExec.failure -ceq 'MCP_ERROR') -and ([bool]$optExec.fallback_continue) -and (-not [bool]$optExec.blocked)) '[RR6-H6] optional exec-error falls back' ([string]$optExec.status)
    Clear-McpSafetyState

    # ---------- RR6 FIX6 H3: same-key half-open admits exactly one probe across runspaces ----------
    Clear-McpSafetyState
    $tHx = [DateTime]::UtcNow
    [void](Invoke-McpSafetyCall -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $tHx)
    [void](Invoke-McpSafetyCall -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot -NowUtc $tHx)
    $tHalf = $tHx.AddSeconds(301)
    $markerHx = Join-Path $tempRoot 'hitshx.txt'
    $codeHx = "Start-Sleep -Milliseconds 2000; [IO.File]::AppendAllText('$markerHx', 'hit;'); 'recovered'"
    $readyH1 = New-Object System.Threading.ManualResetEvent($false)
    $readyH2 = New-Object System.Threading.ManualResetEvent($false)
    $gateHx = New-Object System.Threading.ManualResetEvent($false)
    $bgH1 = $null
    $psH1 = $null
    $hH1 = $null
    $bgH2 = $null
    $psH2 = $null
    $hH2 = $null
    $rH1 = $null
    $rH2 = $null
    try {
        $bgH1 = [runspacefactory]::CreateRunspace()
        $bgH1.Open()
        $psH1 = [powershell]::Create()
        $psH1.Runspace = $bgH1
        [void]$psH1.AddScript({
            param($lib, $policy, $tele, $code, $atUtc, $ready, $gate)
            . $lib
            try { [void]$ready.Set() } catch { }
            try { [void]$gate.WaitOne(15000) } catch { }
            $probe = [scriptblock]::Create($code)
            $hxCall = Invoke-McpSafetyCall -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -Class 'advisory' -Criticality 'optional' -Probe $probe -BudgetSecondsOverride 5 -PolicyPath $policy -TelemetryRoot $tele -NowUtc $atUtc
            $hxState = Get-McpSafetyCircuitState -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -NowUtc $atUtc -CooldownSeconds 300
            $hxCall
            $hxState
        })
        [void]$psH1.AddArgument($libPath)
        [void]$psH1.AddArgument($repoPolicy)
        [void]$psH1.AddArgument($teleRoot)
        [void]$psH1.AddArgument($codeHx)
        [void]$psH1.AddArgument($tHalf)
        [void]$psH1.AddArgument($readyH1)
        [void]$psH1.AddArgument($gateHx)
        $hH1 = $psH1.BeginInvoke()
        $bgH2 = [runspacefactory]::CreateRunspace()
        $bgH2.Open()
        $psH2 = [powershell]::Create()
        $psH2.Runspace = $bgH2
        [void]$psH2.AddScript({
            param($lib, $policy, $tele, $code, $atUtc, $ready, $gate)
            . $lib
            try { [void]$ready.Set() } catch { }
            try { [void]$gate.WaitOne(15000) } catch { }
            $probe = [scriptblock]::Create($code)
            $hxCall = Invoke-McpSafetyCall -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -Class 'advisory' -Criticality 'optional' -Probe $probe -BudgetSecondsOverride 5 -PolicyPath $policy -TelemetryRoot $tele -NowUtc $atUtc
            $hxState = Get-McpSafetyCircuitState -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -NowUtc $atUtc -CooldownSeconds 300
            $hxCall
            $hxState
        })
        [void]$psH2.AddArgument($libPath)
        [void]$psH2.AddArgument($repoPolicy)
        [void]$psH2.AddArgument($teleRoot)
        [void]$psH2.AddArgument($codeHx)
        [void]$psH2.AddArgument($tHalf)
        [void]$psH2.AddArgument($readyH2)
        [void]$psH2.AddArgument($gateHx)
        $hH2 = $psH2.BeginInvoke()
        $rdH1 = $false
        $rdH2 = $false
        try { $rdH1 = $readyH1.WaitOne(15000) } catch { $rdH1 = $false }
        try { $rdH2 = $readyH2.WaitOne(15000) } catch { $rdH2 = $false }
        Assert-McpSafety (([bool]$rdH1) -and ([bool]$rdH2)) '[RR6-H3] both same-key racers ready at the barrier' ''
        try { [void]$gateHx.Set() } catch { }
        try { $rH1 = $psH1.EndInvoke($hH1) } catch { $rH1 = $null }
        try { $rH2 = $psH2.EndInvoke($hH2) } catch { $rH2 = $null }
    }
    finally {
        try { if ($null -ne $psH1) { $psH1.Dispose() } } catch { }
        try { if ($null -ne $bgH1) { $bgH1.Close() } } catch { }
        try { if ($null -ne $bgH1) { $bgH1.Dispose() } } catch { }
        try { if ($null -ne $psH2) { $psH2.Dispose() } } catch { }
        try { if ($null -ne $bgH2) { $bgH2.Close() } } catch { }
        try { if ($null -ne $bgH2) { $bgH2.Dispose() } } catch { }
    }
    $hxSt1 = ''
    $hxSt2 = ''
    $hxRst1 = ''
    $hxRst2 = ''
    if ($null -ne $rH1) {
        $arrH1 = @($rH1)
        try { $hxSt1 = ([string]$arrH1[0].status) } catch { $hxSt1 = '' }
        try { $hxRst1 = ([string]$arrH1[1].state) } catch { $hxRst1 = '' }
    }
    if ($null -ne $rH2) {
        $arrH2 = @($rH2)
        try { $hxSt2 = ([string]$arrH2[0].status) } catch { $hxSt2 = '' }
        try { $hxRst2 = ([string]$arrH2[1].state) } catch { $hxRst2 = '' }
    }
    Assert-McpSafety ((($hxSt1 -ceq 'OK') -and ($hxSt2 -ceq 'MCP_LOCK_BUSY')) -or (($hxSt1 -ceq 'MCP_LOCK_BUSY') -and ($hxSt2 -ceq 'OK'))) '[RR6-H3] same-key half-open admits exactly one probe' (($hxSt1 + '/' + $hxSt2))
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerHx) -eq 1) '[RR6-H3] losing racer never ran its seam' ([string](Get-McpSafetyHits -Path $markerHx))
    $winRst = $hxRst1
    $loseRst = $hxRst2
    if ($hxSt2 -ceq 'OK') { $winRst = $hxRst2; $loseRst = $hxRst1 }
    Assert-McpSafety ($winRst -ceq 'CLOSED') '[RR6-H3] winning probe closes the shared circuit' ($winRst)
    $hxMain = Get-McpSafetyCircuitState -Server 'srv-hx' -Capability 'test.probe' -TurnId 'turn-fixhx-1' -NowUtc $tHalf -CooldownSeconds 300
    Assert-McpSafety (([string]$hxMain.state -ceq 'CLOSED') -and ([string]$hxMain.state -ceq $winRst)) '[RR6-H3] main runspace agrees with racers' ([string]$hxMain.state)
    Assert-McpSafety ((($loseRst -ceq 'HALF_OPEN') -or ($loseRst -ceq 'CLOSED'))) '[RR6-H3] loser view never diverges to a phantom state' ($loseRst)
    Clear-McpSafetyState

    # ---------- RR6 FIX7 H7-R (a): malformed shared wire fails closed ----------
    Clear-McpSafetyState
    $goodStamp7 = '2026-10-02T03:26:26.7826435Z'
    $badWires7 = @(
        'GARBAGE',
        'OPEN|2',
        ('BOGUS|2|' + $goodStamp7),
        ('OPEN|-1|' + $goodStamp7),
        ('OPEN|abc|' + $goodStamp7),
        'OPEN|2|junk-stamp',
        'OPEN|2|',
        ('OPEN|2|' + $goodStamp7 + '|x'),
        ('CLOSED|0|' + $goodStamp7)
    )
    $markerW7 = Join-Path $tempRoot 'hitsw7.txt'
    $wi7 = 0
    foreach ($bw7 in $badWires7) {
        $wi7++
        $turnW7 = ('turn-rr7w-' + $wi7)
        $keyW7 = Get-McpSafetyCircuitKey -Server 'srv-w' -Capability 'test.probe' -TurnId $turnW7
        [void][McpSafetyCapacityCell]::CircuitWrite($keyW7, $bw7)
        $stW7 = Get-McpSafetyCircuitState -Server 'srv-w' -Capability 'test.probe' -TurnId $turnW7 -CooldownSeconds 300
        Assert-McpSafety ([string]$stW7.state -ceq 'UNKNOWN') ('[RR6-H7] malformed wire reads UNKNOWN ' + $bw7) ([string]$stW7.state)
        $markW7 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerW7', 'hit;'); 'ran'")
        $optW7 = Invoke-McpSafetyCall -Server 'srv-w' -Capability 'test.probe' -TurnId $turnW7 -Class 'advisory' -Criticality 'optional' -Probe $markW7 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        Assert-McpSafety (([string]$optW7.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$optW7.ok) -and ([bool]$optW7.fallback_continue) -and (-not [bool]$optW7.blocked)) ('[RR6-H7] malformed wire refuses optional ' + $bw7) ([string]$optW7.status)
        $reqW7 = Invoke-McpSafetyCall -Server 'srv-w' -Capability 'test.probe' -TurnId $turnW7 -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
        Assert-McpSafety (([string]$reqW7.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqW7.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$reqW7.blocked) -and (-not [bool]$reqW7.fallback_continue)) ('[RR6-H7] malformed wire blocks required ' + $bw7) (([string]$reqW7.status + '/' + [string]$reqW7.failure))
    }
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerW7) -eq 0) '[RR6-H7] malformed wire never admits a probe' ([string](Get-McpSafetyHits -Path $markerW7))
    Clear-McpSafetyState

    # ---------- RR6 FIX7 H7-R (b): newly normalized required branches ----------
    $reqNoContract = Invoke-McpSafetyCall -Server 'srv-m7' -Capability 'test.long' -TurnId 'turn-rr7b-1' -Class 'long_running' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqNoContract.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqNoContract.failure -ceq 'MCP_LONG_RUNNING_REQUIRES_CONTRACT') -and ([bool]$reqNoContract.blocked) -and (-not [bool]$reqNoContract.fallback_continue)) '[RR6-H7] required long-running without contract blocks' (([string]$reqNoContract.status + '/' + [string]$reqNoContract.failure))
    $reqBadSrv = Invoke-McpSafetyCall -Server 'BAD SERVER!!' -Capability 'test.probe' -TurnId 'turn-rr7b-2' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqBadSrv.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqBadSrv.failure -ceq 'INVALID_SERVER_ID') -and ([bool]$reqBadSrv.blocked)) '[RR6-H7] required validation error blocks with cause' (([string]$reqBadSrv.status + '/' + [string]$reqBadSrv.failure))
    function Get-McpSafetyClassBudget { return (New-McpSafetyError -Status 'MCP_POLICY_INVALID') }
    $mockReq = Invoke-McpSafetyCall -Server 'srv-m7' -Capability 'test.probe' -TurnId 'turn-rr7b-3' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$mockReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$mockReq.failure -ceq 'MCP_POLICY_INVALID') -and ([bool]$mockReq.blocked)) '[RR6-H7] required budget re-read failure blocks' (([string]$mockReq.status + '/' + [string]$mockReq.failure))
    $mockOpt = Invoke-McpSafetyCall -Server 'srv-m7' -Capability 'test.probe' -TurnId 'turn-rr7b-4' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$mockOpt.status -ceq 'MCP_POLICY_INVALID') -and ([bool]$mockOpt.blocked) -and ([bool]$mockOpt.fallback_continue)) '[RR6-H7] optional budget re-read failure blocks with fallback' ([string]$mockOpt.status)
    . $libPath
    Clear-McpSafetyState
    $occBeforeThrow = Get-McpSafetyCapacityInUse
    function Invoke-McpSafetyProbe { throw 'mock runner failure' }
    $throwReq = Invoke-McpSafetyCall -Server 'srv-m7' -Capability 'test.probe' -TurnId 'turn-rr7b-5' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    $occAfterReq = Get-McpSafetyCapacityInUse
    Assert-McpSafety (([string]$throwReq.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$throwReq.failure -ceq 'INTERNAL_ERROR') -and ([bool]$throwReq.blocked)) '[RR6-H7] required runner throw normalizes blocked' (([string]$throwReq.status + '/' + [string]$throwReq.failure))
    Assert-McpSafety ([int]$occAfterReq -eq [int]$occBeforeThrow) '[RR6-H7] required throw leaks no capacity' (([string]$occBeforeThrow + '->' + [string]$occAfterReq))
    $throwOpt = Invoke-McpSafetyCall -Server 'srv-m7' -Capability 'test.probe' -TurnId 'turn-rr7b-6' -Class 'advisory' -Criticality 'optional' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    $occAfterOpt = Get-McpSafetyCapacityInUse
    Assert-McpSafety (([string]$throwOpt.status -ceq 'INTERNAL_ERROR') -and ([string]$throwOpt.failure -ceq 'INTERNAL_ERROR') -and ([bool]$throwOpt.fallback_continue) -and (-not [bool]$throwOpt.blocked)) '[RR6-H7] optional runner throw falls back with cause' (([string]$throwOpt.status + '/' + [string]$throwOpt.failure))
    Assert-McpSafety ([int]$occAfterOpt -eq [int]$occBeforeThrow) '[RR6-H7] optional throw leaks no capacity' (([string]$occBeforeThrow + '->' + [string]$occAfterOpt))
    . $libPath
    Clear-McpSafetyState

    # ---------- RR8 FIX8 R8-1 (a): forced read failure fails closed ----------
    Clear-McpSafetyState
    $occBeforeRead = Get-McpSafetyCapacityInUse
    $script:McpSafetySimulateReadFailure = $true
    $stRead = Get-McpSafetyCircuitState -Server 'srv-r8' -Capability 'test.probe' -TurnId 'turn-rr8r-1' -CooldownSeconds 300
    Assert-McpSafety ([string]$stRead.state -ceq 'UNKNOWN') '[RR8-R1] forced read failure reports UNKNOWN' ([string]$stRead.state)
    $markerR8 = Join-Path $tempRoot 'hitsr8.txt'
    $markR8 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerR8', 'hit;'); 'ran'")
    $optRead = Invoke-McpSafetyCall -Server 'srv-r8' -Capability 'test.probe' -TurnId 'turn-rr8r-1' -Class 'advisory' -Criticality 'optional' -Probe $markR8 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    $occAfterOptRead = Get-McpSafetyCapacityInUse
    Assert-McpSafety (([string]$optRead.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$optRead.ok) -and ([bool]$optRead.fallback_continue) -and (-not [bool]$optRead.blocked)) '[RR8-R1] read failure refuses optional' ([string]$optRead.status)
    Assert-McpSafety ([int]$occAfterOptRead -eq [int]$occBeforeRead) '[RR8-R1] optional read-failure refusal leaks no capacity' (([string]$occBeforeRead + '->' + [string]$occAfterOptRead))
    $reqRead = Invoke-McpSafetyCall -Server 'srv-r8' -Capability 'test.probe' -TurnId 'turn-rr8r-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    $occAfterReqRead = Get-McpSafetyCapacityInUse
    Assert-McpSafety (([string]$reqRead.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqRead.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$reqRead.blocked)) '[RR8-R1] read failure blocks required' (([string]$reqRead.status + '/' + [string]$reqRead.failure))
    Assert-McpSafety ([int]$occAfterReqRead -eq [int]$occBeforeRead) '[RR8-R1] required read-failure refusal leaks no capacity' (([string]$occBeforeRead + '->' + [string]$occAfterReqRead))
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerR8) -eq 0) '[RR8-R1] read failure never admits a probe' ([string](Get-McpSafetyHits -Path $markerR8))
    $script:McpSafetySimulateReadFailure = $false
    Clear-McpSafetyState

    # ---------- RR8 FIX8 R8-1 (b): generation close never writes on malformed wire ----------
    Clear-McpSafetyState
    $keyGen8 = Get-McpSafetyCircuitKey -Server 'srv-g8' -Capability 'test.probe' -TurnId 'turn-rr8gen-1'
    [void][McpSafetyCapacityCell]::CircuitWrite($keyGen8, ('OPEN|abc|' + $goodStamp7))
    $rawBeforeGen = [McpSafetyCapacityCell]::CircuitRead($keyGen8)
    $genRes8 = Set-McpSafetyCircuitClosedIfGeneration -Key $keyGen8 -ExpectedOpenedAtUtc $goodStamp7 -ExpectedConsecutive 2
    $rawAfterGen = [McpSafetyCapacityCell]::CircuitRead($keyGen8)
    Assert-McpSafety (-not [bool]$genRes8) '[RR8-R1] generation close refuses malformed wire' ([string]$genRes8)
    Assert-McpSafety (([string]$rawAfterGen -ceq [string]$rawBeforeGen)) '[RR8-R1] malformed wire left untouched' ([string]$rawAfterGen)
    Clear-McpSafetyState

    # ---------- RR9 FIX9 R9-1: post-admission read failure preserves the record ----------
    Clear-McpSafetyState
    [void](Invoke-McpSafetyCall -Server 'srv-r9' -Capability 'test.probe' -TurnId 'turn-rr9p-1' -Class 'advisory' -Probe $failTimeoutProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot)
    $keyR9 = Get-McpSafetyCircuitKey -Server 'srv-r9' -Capability 'test.probe' -TurnId 'turn-rr9p-1'
    $rawBeforeR9 = [McpSafetyCapacityCell]::CircuitRead($keyR9)
    $markerR9 = Join-Path $tempRoot 'hitsr9.txt'
    $markR9 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerR9', 'hit;'); 'ran'")
    $script:McpSafetyStoreReadCount = 0
    $script:McpSafetySimulateReadFailureAfterReads = 1
    $reqR9 = Invoke-McpSafetyCall -Server 'srv-r9' -Capability 'test.probe' -TurnId 'turn-rr9p-1' -Class 'advisory' -Criticality 'required' -Probe $markR9 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqR9.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqR9.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$reqR9.blocked) -and (-not [bool]$reqR9.fallback_continue)) '[RR9-R1] post-admission read failure blocks required' (([string]$reqR9.status + '/' + [string]$reqR9.failure))
    $script:McpSafetyStoreReadCount = 0
    $script:McpSafetySimulateReadFailureAfterReads = 1
    $optR9 = Invoke-McpSafetyCall -Server 'srv-r9' -Capability 'test.probe' -TurnId 'turn-rr9p-1' -Class 'advisory' -Criticality 'optional' -Probe $markR9 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optR9.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$optR9.ok) -and ([bool]$optR9.fallback_continue) -and (-not [bool]$optR9.blocked)) '[RR9-R1] post-admission read failure refuses optional' ([string]$optR9.status)
    $rawAfterR9 = [McpSafetyCapacityCell]::CircuitRead($keyR9)
    Assert-McpSafety (([string]$rawAfterR9 -ceq [string]$rawBeforeR9)) '[RR9-R1] pre-existing record byte-identical' ([string]$rawAfterR9)
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerR9) -eq 0) '[RR9-R1] failed accounting admits zero probes' ([string](Get-McpSafetyHits -Path $markerR9))
    $script:McpSafetySimulateReadFailureAfterReads = -1
    $script:McpSafetyStoreReadCount = 0
    Clear-McpSafetyState

    # ---------- RR9 FIX9 R9-2: generation close with unavailable store writes nothing ----------
    Clear-McpSafetyState
    [void](Set-McpSafetyCapacityCellUnavailable $true)
    $keySto9 = Get-McpSafetyCircuitKey -Server 'srv-g9' -Capability 'test.probe' -TurnId 'turn-rr9gen-2'
    $stoRes9 = Set-McpSafetyCircuitClosedIfGeneration -Key $keySto9 -ExpectedOpenedAtUtc '' -ExpectedConsecutive 0
    Assert-McpSafety (-not [bool]$stoRes9) '[RR9-R2] generation close refuses unavailable store' ([string]$stoRes9)
    [void](Set-McpSafetyCapacityCellUnavailable $false)
    $stoRaw9 = [McpSafetyCapacityCell]::CircuitRead($keySto9)
    Assert-McpSafety ($null -eq $stoRaw9) '[RR9-R2] unavailable store left unwritten' ([string]$stoRaw9)
    Clear-McpSafetyState

    # ---------- RR10 FIX10 SEC-2: giant wire refuses before Split ----------
    Clear-McpSafetyState
    $keyHuge10 = Get-McpSafetyCircuitKey -Server 'srv-huge' -Capability 'test.probe' -TurnId 'turn-rr10huge-1'
    $hugeWire10 = ('|' * 1048576)
    [void][McpSafetyCapacityCell]::CircuitWrite($keyHuge10, $hugeWire10)
    $decHuge10 = ConvertFrom-McpSafetyCircuitWire -Wire $hugeWire10
    Assert-McpSafety (-not [bool]$decHuge10.valid) '[RR10-SEC2] giant wire decodes invalid without Split' ''
    $stHuge10 = Get-McpSafetyCircuitState -Server 'srv-huge' -Capability 'test.probe' -TurnId 'turn-rr10huge-1' -CooldownSeconds 300
    Assert-McpSafety ([string]$stHuge10.state -ceq 'UNKNOWN') '[RR10-SEC2] giant wire reads UNKNOWN' ([string]$stHuge10.state)
    $markerHuge10 = Join-Path $tempRoot 'hitshuge10.txt'
    $markHuge10 = [scriptblock]::Create("[IO.File]::AppendAllText('$markerHuge10', 'hit;'); 'ran'")
    $optHuge10 = Invoke-McpSafetyCall -Server 'srv-huge' -Capability 'test.probe' -TurnId 'turn-rr10huge-1' -Class 'advisory' -Criticality 'optional' -Probe $markHuge10 -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$optHuge10.status -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and (-not [bool]$optHuge10.ok) -and ([bool]$optHuge10.fallback_continue) -and (-not [bool]$optHuge10.blocked)) '[RR10-SEC2] giant wire refuses optional' ([string]$optHuge10.status)
    $reqHuge10 = Invoke-McpSafetyCall -Server 'srv-huge' -Capability 'test.probe' -TurnId 'turn-rr10huge-1' -Class 'advisory' -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -TelemetryRoot $teleRoot
    Assert-McpSafety (([string]$reqHuge10.status -ceq 'MCP_REQUIRED_BLOCKED') -and ([string]$reqHuge10.failure -ceq 'MCP_CAPACITY_CELL_UNAVAILABLE') -and ([bool]$reqHuge10.blocked)) '[RR10-SEC2] giant wire blocks required' (([string]$reqHuge10.status + '/' + [string]$reqHuge10.failure))
    Assert-McpSafety ((Get-McpSafetyHits -Path $markerHuge10) -eq 0) '[RR10-SEC2] giant wire never admits a probe' ([string](Get-McpSafetyHits -Path $markerHuge10))
    [void][McpSafetyCapacityCell]::CircuitWrite($keyHuge10, $null)
    Clear-McpSafetyState

    # ---------- AC10: mcp_routing stays OFF, flags untouched ----------
    $flagsText = [IO.File]::ReadAllText($repoFlags, [Text.UTF8Encoding]::new($false))
    $flags = ($flagsText | ConvertFrom-Json)
    Assert-McpSafety ((($flags.mcp_routing.enabled -is [bool])) -and ($flags.mcp_routing.enabled -eq $false)) '[AC10] mcp_routing.enabled is boolean false' ([string]$flags.mcp_routing.enabled)
    $topNames = @($flags.PSObject.Properties.Name | Sort-Object)
    $wantTop = @('adaptive_ranking', 'bounded_execution', 'capability_reconciler', 'capability_registry', 'capability_router', 'jev_advisory', 'mcp_routing', 'routing_telemetry', 'runtime_grant_enforcement', 'runtime_support', 'skill_routing', 'task_kernel', 'version', 'watchdog', 'worktree_isolation')
    $dTop = Compare-Object $topNames $wantTop
    Assert-McpSafety (($null -eq $dTop) -and ($flagsText -notmatch 'mcp_safety') -and ($flagsText -notmatch 'mcp_safety_envelope')) '[AC10] flags shape canonical incl jev_advisory, no other new node' (($topNames -join ','))
    Assert-McpSafety (((($flags.jev_advisory.enabled -is [bool])) -and ($flags.jev_advisory.enabled -eq $true)) -and ((($flags.jev_advisory.shadow -is [bool])) -and ($flags.jev_advisory.shadow -eq $false))) '[AC10] jev_advisory ativada 2026-10-04 (decisao do operador; autoridade sempre nao-autoritativa)' (([string]$flags.jev_advisory.enabled + '/' + [string]$flags.jev_advisory.shadow))
    $stray = @(Get-ChildItem -Path (Join-Path $repo 'plugins') -Recurse -Filter '*McpSafety*' -ErrorAction SilentlyContinue)
    Assert-McpSafety (@($stray).Count -eq 0) '[AC10] no plugin files touched' ([string]@($stray).Count)

    # ---------- ASCII-only new files ----------
    foreach ($p in @($libPath, $repoPolicy, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-McpSafety ($bad -eq 0) ('[AC11] ASCII-only ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
finally {
    try { Clear-McpSafetyState } catch { }
    try { $script:McpSafetySimulateAccountingFailure = $false } catch { }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
