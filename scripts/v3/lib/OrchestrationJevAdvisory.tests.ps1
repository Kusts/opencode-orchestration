<#!
.SYNOPSIS
    Tests for lib/OrchestrationJevAdvisory.ps1 (Phase 29 slice 1).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for evidence, policy
    and flag fixtures, cleanup in finally. Bracketed output the
    runner parses. Exit 0 on all pass, exit 1 on any fail or
    unexpected exception. PS 5.1 compatible. ASCII-only. Zero real
    network: the Jev transport is a synthetic scriptblock seam
    through the reused Phase 28 envelope (no Invoke-WebRequest,
    no HttpClient anywhere in the lib).
    Covers the plan section 6 kernel-side slice:
      healthy seam; missing key; bad key; timeout; two failures
      open the circuit; OPEN fast-fails with 0 seam runs;
      cooldown half-open rearm; catalog drift fails closed to a
      structured policy-invalid; Jev allow plus kernel deny means
      kernel wins; Jev complete plus verifier fail means DONE
      denied; trivial local never consults; uncertain route
      consults when required (would-consult recorded in shadow,
      never calling); flag born OFF with shadow; advisory-only
      authority gate denies every shape; evidence sanitized
      (sk-SYNTHETICSECRET canary redacted), fingerprinted,
      bounded cap fail-closed, honest lock-busy skip.
    NOTE on harness: plain deterministic script executed by
    scripts/v3/run-v3-tests.ps1, same convention as the
    OrchestrationMcpSafety suite (no Pester anywhere in repo).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$mcpLib = Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1'
. $mcpLib
$libPath = Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-JevAdvisory {
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

function Write-JevFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-JevHits {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        return @([regex]::Matches($t, 'hit')).Count
    }
    catch { return -1 }
}

function Get-JevEvidenceText {
    param([string]$Dir)
    $t = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'jev-advisory-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $t += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    return $t
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoJevPolicy = Join-Path $repo 'source\registry\jev-advisory-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'
$repoMcpPolicy = Join-Path $repo 'source\registry\mcp-request-policy.json'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-jevadvisory-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'evidence'
$fixDir = Join-Path $tempRoot 'fixtures'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $fixDir -Force | Out-Null

$activeFlags = Join-Path $fixDir 'flags-active.json'
Write-JevFixture -Path $activeFlags -Text '{"jev_advisory": {"enabled": true, "shadow": false}}'
$disabledFlags = Join-Path $fixDir 'flags-disabled.json'
Write-JevFixture -Path $disabledFlags -Text '{"jev_advisory": {"enabled": false, "shadow": false}}'

$goodKey = 'sk-SYNTHETICSECRET-VALID-1'
$consultDesc = @{ route_uncertain = $true }
$okProbe = { 'decide-ok' }
$failTimeoutProbe = { throw 'MCP_SIM_TIMEOUT boom' }
$slowProbe = { Start-Sleep -Seconds 8; 'too-late' }

try {
    Clear-McpSafetyState
    Clear-JevAdvisoryState

    # ---------- R1: flag born OFF with shadow ----------
    $canon = Get-JevAdvisoryFlag -FlagsPath $repoFlags
    Assert-JevAdvisory (([bool]$canon.found) -and (-not [bool]$canon.enabled) -and ([bool]$canon.shadow) -and ([string]$canon.mode -ceq 'shadow')) '[R1] canonical flag born OFF (enabled=false, shadow=true)' (([string]$canon.enabled + '/' + [string]$canon.shadow + '/' + [string]$canon.mode))
    $flagText = [IO.File]::ReadAllText($repoFlags, [Text.UTF8Encoding]::new($false))
    $flagDoc = ($flagText | ConvertFrom-Json)
    Assert-JevAdvisory (($flagDoc.mcp_routing.enabled -eq $false)) '[R1] mcp_routing stays OFF' ([string]$flagDoc.mcp_routing.enabled)

    # ---------- R2: policy registry validates ----------
    $pa = Assert-JevAdvisoryPolicyJson -Path $repoJevPolicy
    Assert-JevAdvisory ([bool]$pa.valid) '[R2] canonical Jev policy validates' ((@($pa.errors) -join '|'))
    $slot = Read-JevAdvisoryPolicy -PolicyPath $repoJevPolicy
    $tools = @()
    foreach ($t in @(Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'allowed_tools')) { $tools += (([string]$t).Trim()) }
    Assert-JevAdvisory ((@($tools).Count -eq 4) -and ($tools -contains 'jev_check') -and ($tools -contains 'jev_gate') -and ($tools -contains 'jev_score') -and ($tools -contains 'jev_decide')) '[R2] closed tool set of 4' (($tools -join ','))
    Assert-JevAdvisory (([int](Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'request_budget_seconds') -eq 30)) '[R2] request budget 30s' ''
    Assert-JevAdvisory ((([int](Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'health_probe_budget_seconds') -eq 10) -and ([int](Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'catalog_probe_budget_seconds') -eq 10))) '[R2] health/catalog probe budgets 10s' ''
    $jcir = Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'circuit'
    Assert-JevAdvisory ((([int](Get-JevAdvisoryPolicyNode -Doc $jcir -Name 'failure_threshold') -eq 2) -and ([int](Get-JevAdvisoryPolicyNode -Doc $jcir -Name 'cooldown_seconds') -eq 300))) '[R2] circuit identical to MCP (2/300s)' ''
    $jcrit = Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'criticality'
    Assert-JevAdvisory (([string](Get-JevAdvisoryPolicyNode -Doc $jcrit -Name 'default') -ceq 'optional')) '[R2] criticality default optional' ''
    $jcred = Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'credential_source'
    Assert-JevAdvisory ((([string](Get-JevAdvisoryPolicyNode -Doc $jcred -Name 'type') -ceq 'env') -and ([string](Get-JevAdvisoryPolicyNode -Doc $jcred -Name 'name') -ceq 'JEV_API_KEY'))) '[R2] credential source names the env var only' ''
    $jauth = Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'authority'
    Assert-JevAdvisory (([string](Get-JevAdvisoryPolicyNode -Doc $jauth -Name 'mode') -ceq 'advisory-only') -and (@(Get-JevAdvisoryPolicyNode -Doc $jauth -Name 'cannot').Count -ge 8)) '[R2] advisory-only authority with explicit cannot list' ''
    $polText = [IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false))
    Assert-JevAdvisory (($polText -notmatch 'sk-[A-Za-z0-9]')) '[R2] policy file carries no credential value' ''

    # ---------- R4: deterministic trigger policy (pure) ----------
    $triv = Test-JevAdvisoryTrigger -Descriptor @{ trivial_local = $true; route_uncertain = $true }
    Assert-JevAdvisory (((-not [bool]$triv.should_consult) -and ([string]$triv.trigger_reason -ceq 'trivial-local-never-consults'))) '[R4] trivial_local never consults even with route uncertainty' ([string]$triv.trigger_reason)
    $trivOnly = Test-JevAdvisoryTrigger -Descriptor @{ trivial_local = $true }
    Assert-JevAdvisory (-not [bool]$trivOnly.should_consult) '[R4] trivial alone never consults' ([string]$trivOnly.trigger_reason)
    $ru = Test-JevAdvisoryTrigger -Descriptor @{ route_uncertain = $true }
    Assert-JevAdvisory (([bool]$ru.should_consult) -and ([string]$ru.trigger_reason -ceq 'route-uncertain')) '[R4] route uncertainty consults' ([string]$ru.trigger_reason)
    $mru = Test-JevAdvisoryTrigger -Descriptor @{ model_route_uncertain = $true }
    Assert-JevAdvisory (([bool]$mru.should_consult) -and ([string]$mru.trigger_reason -ceq 'model-route-uncertain')) '[R4] model route uncertainty consults' ([string]$mru.trigger_reason)
    $ctc = Test-JevAdvisoryTrigger -Descriptor @{ consequential_tool_call = $true }
    Assert-JevAdvisory (([bool]$ctc.should_consult) -and ([string]$ctc.trigger_reason -ceq 'consequential-tool-call')) '[R4] consequential tool call consults' ([string]$ctc.trigger_reason)
    $ce = Test-JevAdvisoryTrigger -Descriptor @{ conflicting_evidence = $true }
    Assert-JevAdvisory (([bool]$ce.should_consult) -and ([string]$ce.trigger_reason -ceq 'conflicting-evidence')) '[R4] conflicting evidence consults' ([string]$ce.trigger_reason)
    $cu = Test-JevAdvisoryTrigger -Descriptor @{ completion_uncertainty_substantial = $true }
    Assert-JevAdvisory (([bool]$cu.should_consult) -and ([string]$cu.trigger_reason -ceq 'completion-uncertainty-substantial')) '[R4] substantial completion uncertainty consults' ([string]$cu.trigger_reason)
    $rc = Test-JevAdvisoryTrigger -Descriptor @{ recovery_comparison_bounded = $true }
    Assert-JevAdvisory (([bool]$rc.should_consult) -and ([string]$rc.trigger_reason -ceq 'recovery-comparison-bounded')) '[R4] bounded recovery comparison consults' ([string]$rc.trigger_reason)
    $nt = Test-JevAdvisoryTrigger -Descriptor @{}
    Assert-JevAdvisory (((-not [bool]$nt.should_consult) -and ([string]$nt.trigger_reason -ceq 'no-trigger'))) '[R4] empty descriptor has no trigger' ([string]$nt.trigger_reason)
    $ntNull = Test-JevAdvisoryTrigger -Descriptor $null
    Assert-JevAdvisory (-not [bool]$ntNull.should_consult) '[R4] null descriptor never throws, no trigger' ([string]$ntNull.trigger_reason)
    $hostileDesc = @{
        trivial_local = @(1, 2)
        route_uncertain = 'yes'
        model_route_uncertain = $null
        consequential_tool_call = 0
        conflicting_evidence = @{ nested = 'x' }
    }
    $threwHostile = $false
    $hos1 = $null
    $hos2 = $null
    try {
        $hos1 = Test-JevAdvisoryTrigger -Descriptor $hostileDesc
        $hos2 = Test-JevAdvisoryTrigger -Descriptor $hostileDesc
    }
    catch { $threwHostile = $true }
    Assert-JevAdvisory (((-not $threwHostile) -and ($null -ne $hos1) -and ($null -ne $hos2) -and ([string]$hos1.trigger_reason -ceq [string]$hos2.trigger_reason) -and ([bool]$hos1.should_consult -eq [bool]$hos2.should_consult))) '[F3] hostile descriptor never throws, stable decision' (([string]$hos1.trigger_reason + '/' + [string]$hos1.should_consult))
    $hosNoTriv = @{ route_uncertain = @(1); conflicting_evidence = @{ nested = 'x' } }
    $hnt1 = Test-JevAdvisoryTrigger -Descriptor $hosNoTriv
    $hnt2 = Test-JevAdvisoryTrigger -Descriptor $hosNoTriv
    Assert-JevAdvisory (([bool]$hnt1.should_consult) -and ([string]$hnt1.trigger_reason -ceq [string]$hnt2.trigger_reason)) '[F3] hostile non-trivial descriptor consults stably' ([string]$hnt1.trigger_reason)

    # ---------- healthy seam (active flag fixture, synthetic probe) ----------
    Clear-McpSafetyState
    $healthy = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-1' -Descriptor $consultDesc -Probe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([bool]$healthy.ok) -and ([string]$healthy.status -ceq 'JEV_ADVISORY_OK') -and ([bool]$healthy.consulted) -and ([string]$healthy.output -ceq 'decide-ok') -and ([string]$healthy.mode -ceq 'active')) '[T-healthy] seam returns advisory OK with output' (([string]$healthy.status + '/' + [string]$healthy.output))

    # ---------- missing key => structured JEV_UNAVAILABLE ----------
    Clear-McpSafetyState
    $threwMiss = $false
    $miss = $null
    try {
        $miss = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-2' -Descriptor $consultDesc -Probe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey ''
    }
    catch { $threwMiss = $true }
    Assert-JevAdvisory (((-not $threwMiss) -and ($null -ne $miss) -and ([string]$miss.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$miss.fallback_continue) -and (-not [bool]$miss.blocked))) '[T-missing-key] absent credential yields structured fallback, never throws' ([string]$miss.status)

    # ---------- bad key => structured refusal (synthetically malformed seam value) ----------
    Clear-McpSafetyState
    $badSeamKey = ('bad' + [char]10 + 'key')
    $bad = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-3' -Descriptor $consultDesc -Probe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $badSeamKey
    Assert-JevAdvisory (([string]$bad.status -ceq 'JEV_AUTH_INVALID') -and (-not [bool]$bad.ok) -and ([bool]$bad.fallback_continue) -and (-not [bool]$bad.blocked) -and (-not [bool]$bad.consulted)) '[T-bad-key] malformed credential refused structured' ([string]$bad.status)
    $kAbsent = Test-JevAdvisoryApiKey -ApiKey ''
    $kBlank = Test-JevAdvisoryApiKey -ApiKey '   '
    $kNull = Test-JevAdvisoryApiKey -ApiKey $null
    Assert-JevAdvisory ((([string]$kAbsent.status -ceq 'JEV_UNAVAILABLE') -and ([string]$kBlank.status -ceq 'JEV_UNAVAILABLE') -and ([string]$kNull.status -ceq 'JEV_UNAVAILABLE'))) '[F1] empty/blank/null credential means unavailable' ''
    $kCtl = Test-JevAdvisoryApiKey -ApiKey ('a' + [char]9 + 'b')
    Assert-JevAdvisory (([string]$kCtl.status -ceq 'JEV_AUTH_INVALID') -and ([bool]$kCtl.present) -and (-not [bool]$kCtl.valid)) '[F1] control-char credential rejected without format check' ([string]$kCtl.status)
    $kEdge = @(
        ('opaque-key' + [char]10),
        ([char]9 + 'opaque-key'),
        ('opaque' + [char]13 + [char]10 + 'key'),
        ('a' + [char]0 + 'b'),
        ('a' + [char]127 + 'b')
    )
    $edgeAllInvalid = $true
    foreach ($kv in $kEdge) {
        $kr = Test-JevAdvisoryApiKey -ApiKey $kv
        if ([string]$kr.status -cne 'JEV_AUTH_INVALID') { $edgeAllInvalid = $false }
    }
    Assert-JevAdvisory $edgeAllInvalid '[F2-1] CR/LF/tab/NUL/DEL at edges or middle all AUTH_INVALID' ''
    $kInnerSpace = Test-JevAdvisoryApiKey -ApiKey 'opaque key 9f8e'
    Assert-JevAdvisory ([string]$kInnerSpace.status -ceq 'OK') '[F2-1] plain inner space (0x20, not control) passes' ([string]$kInnerSpace.status)
    $kOpaque = Test-JevAdvisoryApiKey -ApiKey 'user-owned-opaque-key-9f8e'
    $kCanary = Test-JevAdvisoryApiKey -ApiKey $goodKey
    Assert-JevAdvisory ((([string]$kOpaque.status -ceq 'OK') -and ([string]$kCanary.status -ceq 'OK'))) '[F1] gate accepts opaque values, no canary coupling' (([string]$kOpaque.status + '/' + [string]$kCanary.status))

    # ---------- timeout under tightened budget ----------
    Clear-McpSafetyState
    $swT = [System.Diagnostics.Stopwatch]::StartNew()
    $threwTo = $false
    $to = $null
    try {
        $to = Invoke-JevAdvisoryCall -Tool 'jev_score' -TurnId 'turn-jevt-4' -Descriptor $consultDesc -Probe $slowProbe -BudgetSecondsOverride 1 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    }
    catch { $threwTo = $true }
    $swT.Stop()
    Assert-JevAdvisory (((-not $threwTo) -and ([string]$to.status -ceq 'JEV_UNAVAILABLE') -and ([string]$to.failure -ceq 'MCP_TIMEOUT') -and ([bool]$to.fallback_continue))) '[T-timeout] slow seam maps to JEV_UNAVAILABLE/MCP_TIMEOUT' (([string]$to.status + '/' + [string]$to.failure))
    Assert-JevAdvisory ([int]$swT.Elapsed.TotalSeconds -lt 30) '[T-timeout] bounded wall clock' ([string][int]$swT.Elapsed.TotalSeconds)

    # ---------- two failures open the circuit ----------
    Clear-McpSafetyState
    $j1 = Invoke-JevAdvisoryCall -Tool 'jev_gate' -TurnId 'turn-jevt-5' -Descriptor $consultDesc -Probe $failTimeoutProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([int]$j1.consecutive -eq 1) -and ([string]$j1.circuit -ceq 'CLOSED')) '[T-circuit] first failure consecutive 1, still closed' (([string]$j1.consecutive + '/' + [string]$j1.circuit))
    $j2 = Invoke-JevAdvisoryCall -Tool 'jev_gate' -TurnId 'turn-jevt-5' -Descriptor $consultDesc -Probe $failTimeoutProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([int]$j2.consecutive -eq 2) -and ([string]$j2.circuit -ceq 'OPEN')) '[T-circuit] second failure opens circuit' (([string]$j2.consecutive + '/' + [string]$j2.circuit))

    # ---------- OPEN impedes hammering (0 seam runs) ----------
    $marker6 = Join-Path $tempRoot 'hits6.txt'
    $markProbe6 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker6', 'hit;'); 'ran'")
    $jOpen = Invoke-JevAdvisoryCall -Tool 'jev_gate' -TurnId 'turn-jevt-5' -Descriptor $consultDesc -Probe $markProbe6 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$jOpen.failure -ceq 'MCP_CIRCUIT_OPEN') -and ([string]$jOpen.status -ceq 'JEV_UNAVAILABLE')) '[T-open] open circuit fast-fails structured' (([string]$jOpen.status + '/' + [string]$jOpen.failure))
    Assert-JevAdvisory ((Get-JevHits -Path $marker6) -eq 0) '[T-open] seam invoked 0 times after opening' ([string](Get-JevHits -Path $marker6))

    # ---------- cooldown half-open rearm ----------
    Clear-McpSafetyState
    $t0 = [DateTime]::UtcNow
    [void](Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-6' -Descriptor $consultDesc -Probe $failTimeoutProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey -NowUtc $t0)
    [void](Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-6' -Descriptor $consultDesc -Probe $failTimeoutProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey -NowUtc $t0)
    $marker7 = Join-Path $tempRoot 'hits7.txt'
    $markOk7 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker7', 'hit;'); 'recovered'")
    $early = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-6' -Descriptor $consultDesc -Probe $markOk7 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey -NowUtc $t0
    Assert-JevAdvisory (([string]$early.failure -ceq 'MCP_CIRCUIT_OPEN') -and ((Get-JevHits -Path $marker7) -eq 0)) '[T-cooldown] before cooldown fast-fails, probe not run' ([string]$early.failure)
    $late = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-6' -Descriptor $consultDesc -Probe $markOk7 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey -NowUtc ($t0.AddSeconds(301))
    Assert-JevAdvisory (([string]$late.status -ceq 'JEV_ADVISORY_OK') -and ((Get-JevHits -Path $marker7) -eq 1) -and ([string]$late.circuit -ceq 'CLOSED')) '[T-cooldown] expired cooldown rearms CLOSED on success' ([string]$late.status)

    # ---------- catalog drift fails closed ----------
    Clear-McpSafetyState
    $driftPath = Join-Path $fixDir 'jev-policy-drift.json'
    $rawDrift = [IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false)) -replace '"request_budget_seconds": 30', '"request_budget_seconds": 999'
    Write-JevFixture -Path $driftPath -Text $rawDrift
    $driftValid = Assert-JevAdvisoryPolicyJson -Path $driftPath
    Assert-JevAdvisory (-not [bool]$driftValid.valid) '[T-drift] drifted budget rejected' ((@($driftValid.errors) -join '|'))
    $marker8 = Join-Path $tempRoot 'hits8.txt'
    $markProbe8 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker8', 'hit;'); 'ran'")
    $drift = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-7' -Descriptor $consultDesc -Probe $markProbe8 -PolicyPath $driftPath -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$drift.status -ceq 'JEV_POLICY_INVALID') -and (-not [bool]$drift.consulted) -and ([bool]$drift.fallback_continue)) '[T-drift] drift fails closed structured, never proceeds' ([string]$drift.status)
    Assert-JevAdvisory ((Get-JevHits -Path $marker8) -eq 0) '[T-drift] drifted policy runs 0 probes' ([string](Get-JevHits -Path $marker8))
    $driftTools = Join-Path $fixDir 'jev-policy-drift-tools.json'
    $rawDriftTools = [IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false)) -replace '"jev_decide"', '"jev_evil"'
    Write-JevFixture -Path $driftTools -Text $rawDriftTools
    $driftToolsValid = Assert-JevAdvisoryPolicyJson -Path $driftTools
    Assert-JevAdvisory (-not [bool]$driftToolsValid.valid) '[T-drift] widened tool set rejected' ((@($driftToolsValid.errors) -join '|'))

    # ---------- R5: authority guard always denies ----------
    $gateShapes = @(
        ([PSCustomObject]@{ ok = $true; status = 'allow'; decision = 'allow' }),
        ([PSCustomObject]@{ ok = $true; status = 'complete'; decision = 'complete' }),
        ([PSCustomObject]@{ ok = $true; status = 'OK'; grant = $true }),
        'hostile-string-shape',
        42,
        $null
    )
    $denyAll = $true
    foreach ($shape in $gateShapes) {
        $g = Invoke-JevAdvisoryGrantGate -JevResult $shape
        if (([bool]$g.granted) -or ([bool]$g.widened) -or ([bool]$g.model_selected) -or ([bool]$g.done_written) -or ([bool]$g.ok)) { $denyAll = $false }
        if ([string]$g.status -cne 'JEV_ADVISORY_CANNOT_GRANT') { $denyAll = $false }
    }
    Assert-JevAdvisory $denyAll '[R5] every Jev output shape denied (incl null/hostile)' ''
    $effDeny = Get-JevAdvisoryEffectiveDecision -JevWantsAllow $true -KernelAllows $false -JevWantsComplete $false -VerifierPasses $false
    Assert-JevAdvisory (((-not [bool]$effDeny.effective_allow) -and ([bool]$effDeny.kernel_wins))) '[R5] Jev allow plus kernel deny means kernel wins' ([string]$effDeny.effective_allow)
    $effDone = Get-JevAdvisoryEffectiveDecision -JevWantsAllow $false -KernelAllows $true -JevWantsComplete $true -VerifierPasses $false
    Assert-JevAdvisory (-not [bool]$effDone.effective_done) '[R5] Jev complete plus verifier fail means DONE denied' ([string]$effDone.effective_done)
    $effOk = Get-JevAdvisoryEffectiveDecision -JevWantsAllow $true -KernelAllows $true -JevWantsComplete $true -VerifierPasses $true
    Assert-JevAdvisory (([bool]$effOk.effective_allow) -and ([bool]$effOk.effective_done)) '[R5] gate never vetoes a legitimate kernel/verifier pass' ''

    # ---------- trivial never consults end-to-end ----------
    Clear-McpSafetyState
    $marker11 = Join-Path $tempRoot 'hits11.txt'
    $markProbe11 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker11', 'hit;'); 'ran'")
    $trivial = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-8' -Descriptor @{ trivial_local = $true; route_uncertain = $true } -Probe $markProbe11 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$trivial.status -ceq 'JEV_NOT_TRIGGERED') -and (-not [bool]$trivial.consulted) -and ([string]$trivial.trigger_reason -ceq 'trivial-local-never-consults')) '[T-trivial] trivial task does not consult' ([string]$trivial.status)
    Assert-JevAdvisory ((Get-JevHits -Path $marker11) -eq 0) '[T-trivial] trivial runs 0 probes' ([string](Get-JevHits -Path $marker11))

    # ---------- uncertain route would-consults in shadow, never calls ----------
    Clear-McpSafetyState
    $marker12 = Join-Path $tempRoot 'hits12.txt'
    $markProbe12 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker12', 'hit;'); 'ran'")
    $shadow = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-9' -Descriptor $consultDesc -Probe $markProbe12 -PolicyPath $repoJevPolicy -FlagsPath $repoFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$shadow.status -ceq 'JEV_WOULD_CONSULT') -and ([bool]$shadow.would_consult) -and (-not [bool]$shadow.consulted) -and ([string]$shadow.trigger_reason -ceq 'route-uncertain') -and ([string]$shadow.mode -ceq 'shadow')) '[T-shadow] uncertain route would-consults in shadow' (([string]$shadow.status + '/' + [string]$shadow.trigger_reason))
    Assert-JevAdvisory ((Get-JevHits -Path $marker12) -eq 0) '[T-shadow] shadow runs 0 probes' ([string](Get-JevHits -Path $marker12))

    # ---------- R6: evidence sanitized, fingerprinted, bounded ----------
    $evText = Get-JevEvidenceText -Dir $teleRoot
    Assert-JevAdvisory (($evText -match 'JEV_WOULD_CONSULT') -and ($evText -match 'route-uncertain') -and ($evText -match '"mode":"shadow"')) '[R6] would-consult plus reason plus mode recorded' ''
    Assert-JevAdvisory ((($evText -notmatch 'SYNTHETICSECRET')) -and ($evText -match 'input_hash')) '[R6] evidence carries input hash, no canary value' ''
    $h1 = Get-JevAdvisoryInputHash -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc
    Assert-JevAdvisory (($h1 -cmatch '^[0-9a-f]{64}$')) '[R6] input hash is 64-hex' ($h1)
    $h1b = Get-JevAdvisoryInputHash -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc
    Assert-JevAdvisory (($h1b -ceq $h1)) '[F2] same input yields same hash on repeat' ''
    $hDiff = Get-JevAdvisoryInputHash -Tool 'jev_decide' -TriggerReason 'model-route-uncertain' -Descriptor $consultDesc
    Assert-JevAdvisory ((($hDiff -cmatch '^[0-9a-f]{64}$') -and ($hDiff -cne $h1))) '[F2] different reason yields different hash' ''
    $evilSummary = 'leak sk-SYNTHETICSECRET-9 token=abc123'
    $wEvil = Write-JevAdvisoryEvidence -EventName 'JEV_ADVISORY_OK' -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc -OutputSummary $evilSummary -Mode 'active' -TelemetryRoot $teleRoot
    Assert-JevAdvisory ([bool]$wEvil.ok) '[R6] hostile summary accepted for write' ([string]$wEvil.skipped)
    $evText2 = Get-JevEvidenceText -Dir $teleRoot
    Assert-JevAdvisory ((($evText2 -notmatch 'SYNTHETICSECRET') -and ($evText2 -notmatch 'abc123'))) '[R6] hostile summary redacted in JSONL' ''
    $teleCap = Join-Path $tempRoot 'evidence-cap'
    New-Item -ItemType Directory -Path $teleCap -Force | Out-Null
    $savedCap = $script:JevAdvisoryTelemetryCapBytes
    $script:JevAdvisoryTelemetryCapBytes = 600
    try {
        $cw1 = Write-JevAdvisoryEvidence -EventName 'JEV_WOULD_CONSULT' -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc -Mode 'shadow' -TelemetryRoot $teleCap
        Assert-JevAdvisory ([bool]$cw1.ok) '[R6] first cap event written' ([string]$cw1.skipped)
        $targetCap = Get-JevAdvisoryEvidenceFile -TelemetryRoot $teleCap
        $curLen = ([IO.FileInfo]::new($targetCap)).Length
        $script:JevAdvisoryTelemetryCapBytes = ($curLen + 10)
        $cw2 = Write-JevAdvisoryEvidence -EventName 'JEV_WOULD_CONSULT' -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc -Mode 'shadow' -TelemetryRoot $teleCap
        Assert-JevAdvisory (((-not [bool]$cw2.ok)) -and ([string]$cw2.skipped -ceq 'rotation-cap')) '[R6] overflowing event honestly dropped' ([string]$cw2.skipped)
        $finalLen = ([IO.FileInfo]::new($targetCap)).Length
        Assert-JevAdvisory ($finalLen -le ($curLen + 10)) '[R6] bounded file never exceeds cap' ([string]$finalLen)
    }
    finally { $script:JevAdvisoryTelemetryCapBytes = $savedCap }

    # ---------- R6: lock-busy skip, never blocks ----------
    $teleGate = $null
    try { $teleGate = Get-McpSafetySharedGate -Name 'TelemetryGate' } catch { $teleGate = $null }
    Assert-JevAdvisory ($null -ne $teleGate) '[R6] shared TelemetryGate reachable' ''
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
        Assert-JevAdvisory ([bool]$tgHeld) '[R6] background holder owns TelemetryGate' ''
        $teleHeld = Join-Path $tempRoot 'evidence-held'
        New-Item -ItemType Directory -Path $teleHeld -Force | Out-Null
        $swHeld = [System.Diagnostics.Stopwatch]::StartNew()
        $wHeld = Write-JevAdvisoryEvidence -EventName 'JEV_WOULD_CONSULT' -Tool 'jev_decide' -TriggerReason 'route-uncertain' -Descriptor $consultDesc -Mode 'shadow' -TelemetryRoot $teleHeld
        $swHeld.Stop()
        Assert-JevAdvisory (((-not [bool]$wHeld.ok)) -and ([string]$wHeld.skipped -ceq 'lock-busy')) '[R6] contended evidence honestly skipped' ([string]$wHeld.skipped)
        Assert-JevAdvisory ([int]$swHeld.Elapsed.TotalMilliseconds -lt 8000) '[R6] skip returns bounded' ([string][int]$swHeld.Elapsed.TotalMilliseconds)
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

    # ---------- R7: unavailable never blocks, invalid tool closed ----------
    Clear-McpSafetyState
    $un = Invoke-JevAdvisoryCall -Tool 'jev_score' -TurnId 'turn-jevt-10' -Descriptor $consultDesc -Probe $failTimeoutProbe -BudgetSecondsOverride 1 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$un.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$un.fallback_continue) -and (-not [bool]$un.blocked)) '[R7] unavailable falls back without blocking' ([string]$un.status)
    $badTool = Invoke-JevAdvisoryCall -Tool 'jev_evil' -TurnId 'turn-jevt-11' -Descriptor $consultDesc -Probe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory ([string]$badTool.status -ceq 'INVALID_TOOL') '[R7] tool outside closed set rejected' ([string]$badTool.status)
    $dis = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-12' -Descriptor $consultDesc -Probe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $disabledFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$dis.status -ceq 'JEV_DISABLED') -and (-not [bool]$dis.consulted)) '[R7] disabled flag refuses without calling' ([string]$dis.status)

    # ---------- zero real network in the lib ----------
    $libText = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
    Assert-JevAdvisory ((($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'Invoke-RestMethod') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'Net\.WebClient'))) '[NET] lib has no network primitives' ''

    # ---------- ASCII-only new/edited files ----------
    foreach ($p in @($libPath, $repoJevPolicy, $repoFlags, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-JevAdvisory ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
finally {
    try { Clear-McpSafetyState } catch { }
    try { Clear-JevAdvisoryState } catch { }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
