<#!
.SYNOPSIS
    Tests for lib/OrchestrationAiMemoryRemote.ps1 (Phase 30 slice 1).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for evidence, policy
    fixtures, cleanup in finally. Bracketed output the runner
    parses. Exit 0 on all pass, exit 1 on any fail or unexpected
    exception. PS 5.1 compatible. ASCII-only. Zero real network:
    the remote transport is a synthetic scriptblock seam through
    the reused Phase 28 envelope class memory (no
    Invoke-WebRequest, no HttpClient, no runspace primitives in
    the lib; the fixed local listener is never touched).
    Covers the plan section 7 kernel-side slice:
      policy registry (endpoint schema, 60s retrieval, 10s
      health probe, circuit 2/300, scope both-together,
      criticality default optional, name-only credential, fixed
      TLS verify); unconfigured placeholder/empty handling with
      zero seam runs and no local fallback; scope gate;
      credential gate incl. env-name wiring; healthy recall seam;
      DNS failure; connect timeout; auth failure; 5xx; circuit
      opens with 2 failures and impedes hammering (0 seam runs);
      cooldown/rearm; independent health circuit; optional
      continues in every branch; required blocks in every
      branch; no credential leakage (canary never in JSONL);
      endpoint URL never logged whole (host plus len:port
      only); scope/turn hashed; cap fail-closed; honest
      lock-busy skip; drifted/loopback policy rejected
      fail-closed.
    NOTE on harness: plain deterministic script executed by
    scripts/v3/run-v3-tests.ps1, same convention as the
    OrchestrationMcpSafety and OrchestrationJevAdvisory suites
    (no Pester anywhere in repo).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$mcpLib = Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1'
. $mcpLib
$libPath = Join-Path $PSScriptRoot 'OrchestrationAiMemoryRemote.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-AiMemoryRemote {
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

function Write-AiMemoryFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-AiMemoryHits {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        $t = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        return @([regex]::Matches($t, 'hit')).Count
    }
    catch { return -1 }
}

function Get-AiMemoryEvidenceText {
    param([string]$Dir)
    $t = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'ai-memory-remote-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $t += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    return $t
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoPolicy = Join-Path $repo 'source\registry\ai-memory-remote-policy.json'
$repoMcpPolicy = Join-Path $repo 'source\registry\mcp-request-policy.json'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-aimemremote-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'evidence'
$fixDir = Join-Path $tempRoot 'fixtures'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $fixDir -Force | Out-Null

$canonText = [IO.File]::ReadAllText($repoPolicy, [Text.UTF8Encoding]::new($false))
$cfgPolicy = Join-Path $fixDir 'aimem-policy-configured.json'
Write-AiMemoryFixture -Path $cfgPolicy -Text ($canonText -replace '"url": ""', '"url": "https://memory.example.com:8443/v1"')

$canaryToken = 'sk-SYNTHETICSECRET-VALID-1'
$scopeWs = 'ws-scope-zz9canary'
$scopeProj = 'proj-scope-zz9canary'
$okProbe = { return @{ aimem_outcome = 'ok'; data = 'recall-ok' } }
$healthOkProbe = { return @{ aimem_outcome = 'ok' } }
$dnsProbe = { return @{ aimem_outcome = 'dns-failure' } }
$authProbe = { return @{ aimem_outcome = 'auth-failure' } }
$err5xxProbe = { return @{ aimem_outcome = 'server-5xx' } }
$failTimeoutProbe = { throw 'MCP_SIM_TIMEOUT boom' }
$failNetworkProbe = { throw 'MCP_SIM_NETWORK socket boom' }
$slowProbe = { Start-Sleep -Seconds 8; return @{ aimem_outcome = 'ok' } }

$savedEnvToken = $null
try { $savedEnvToken = $env:AIMEMORY_REMOTE_TOKEN } catch { $savedEnvToken = $null }

try {
    Clear-McpSafetyState
    Clear-AiMemoryRemoteState

    # ---------- R1: policy registry ----------
    $pa = Assert-AiMemoryRemotePolicyJson -Path $repoPolicy
    Assert-AiMemoryRemote ([bool]$pa.valid) '[R1] canonical remote policy validates' ((@($pa.errors) -join '|'))
    $slot = Read-AiMemoryRemotePolicy -PolicyPath $repoPolicy
    Assert-AiMemoryRemote (([bool]$slot.found) -and (-not [bool]$slot.malformed)) '[R1] canonical policy readable' ''
    $ep = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'endpoint'
    Assert-AiMemoryRemote (([string](Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'url')) -ceq '') '[R1] canonical endpoint ships unconfigured (empty url)' ''
    $auth = Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'auth'
    Assert-AiMemoryRemote ((([string](Get-AiMemoryRemotePolicyNode -Doc $auth -Name 'type') -ceq 'env') -and ([string](Get-AiMemoryRemotePolicyNode -Doc $auth -Name 'name') -ceq 'AIMEMORY_REMOTE_TOKEN'))) '[R1] auth names the env var only' ''
    Assert-AiMemoryRemote ((Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'tls_verify') -is [bool]) '[R1] tls_verify is a bool' ''
    Assert-AiMemoryRemote (([bool](Get-AiMemoryRemotePolicyNode -Doc $ep -Name 'tls_verify')) -eq $true) '[R1] tls_verify fixed true' ''
    Assert-AiMemoryRemote (([int](Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'retrieval_budget_seconds') -eq 60)) '[R1] retrieval budget 60s' ''
    Assert-AiMemoryRemote (([int](Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'health_probe_budget_seconds') -eq 10)) '[R1] health probe budget 10s' ''
    $cir = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'circuit'
    Assert-AiMemoryRemote ((([int](Get-AiMemoryRemotePolicyNode -Doc $cir -Name 'failure_threshold') -eq 2) -and ([int](Get-AiMemoryRemotePolicyNode -Doc $cir -Name 'cooldown_seconds') -eq 300))) '[R1] circuit identical to canonical (2/300s)' ''
    $scoping = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'scoping'
    Assert-AiMemoryRemote ((([bool](Get-AiMemoryRemotePolicyNode -Doc $scoping -Name 'require_both_together')) -and ([bool](Get-AiMemoryRemotePolicyNode -Doc $scoping -Name 'forbid_local_fallback')))) '[R1] scoping both-together plus no local fallback' ''
    $crit = Get-AiMemoryRemotePolicyNode -Doc $slot.doc -Name 'criticality'
    Assert-AiMemoryRemote (([string](Get-AiMemoryRemotePolicyNode -Doc $crit -Name 'default') -ceq 'optional')) '[R1] criticality default optional' ''
    Assert-AiMemoryRemote (($canonText -notmatch 'sk-[A-Za-z0-9]')) '[R1] registry carries no credential value' ''
    Assert-AiMemoryRemote (($canonText -notmatch '49374')) '[R1] registry carries no local default port' ''
    Assert-AiMemoryRemote (($canonText -notmatch '127\.0\.0\.1')) '[R1] registry carries no local default address' ''
    $mcpDoc = ([IO.File]::ReadAllText($repoMcpPolicy, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    Assert-AiMemoryRemote (([int]$mcpDoc.classes.memory.execution_timeout_seconds -eq 60)) '[R1] envelope memory class budget aligns (60s)' ''

    # ---------- R2: envelope reuse, no network primitives, no local literals in lib ----------
    $libText = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
    Assert-AiMemoryRemote (($libText -match 'Invoke-McpSafetyCall')) '[R2] lib reuses the P28 envelope' ''
    Assert-AiMemoryRemote (($libText -match "'memory'")) '[R2] lib reuses envelope class memory' ''
    Assert-AiMemoryRemote ((($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'Invoke-RestMethod') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'Net\.WebClient'))) '[R2] lib owns zero network primitives' ''
    Assert-AiMemoryRemote ((($libText -notmatch 'CreateRunspace') -and ($libText -notmatch '\[powershell\]::Create'))) '[R2] lib creates no parallel timeout/circuit primitives' ''
    Assert-AiMemoryRemote (($libText -notmatch '49374')) '[R2] lib holds no local port literal' ''
    Assert-AiMemoryRemote (($libText -notmatch '127\.0\.0\.1')) '[R2] lib holds no local address literal' ''

    # ---------- R2: policy load fail-closed ----------
    Clear-McpSafetyState
    $missingPol = Join-Path $fixDir 'does-not-exist.json'
    $miss = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-pol-1' -Probe $okProbe -PolicyPath $missingPol -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$miss.status -ceq 'AIMEMORY_POLICY_INVALID') -and ([bool]$miss.blocked) -and (-not [bool]$miss.consulted)) '[R2] absent policy fails closed blocked' ([string]$miss.status)
    $badJson = Join-Path $fixDir 'aimem-policy-badjson.json'
    Write-AiMemoryFixture -Path $badJson -Text '{not json'
    $bad = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-pol-2' -Probe $okProbe -PolicyPath $badJson -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$bad.status -ceq 'AIMEMORY_POLICY_INVALID') -and ([bool]$bad.blocked)) '[R2] malformed policy fails closed blocked' ([string]$bad.status)
    $driftBudget = Join-Path $fixDir 'aimem-policy-drift-budget.json'
    Write-AiMemoryFixture -Path $driftBudget -Text ($canonText -replace '"retrieval_budget_seconds": 60', '"retrieval_budget_seconds": 999')
    $driftValid = Assert-AiMemoryRemotePolicyJson -Path $driftBudget
    Assert-AiMemoryRemote (-not [bool]$driftValid.valid) '[R2] drifted budget rejected' ((@($driftValid.errors) -join '|'))
    $driftTls = Join-Path $fixDir 'aimem-policy-drift-tls.json'
    Write-AiMemoryFixture -Path $driftTls -Text ($canonText -replace '"tls_verify": true', '"tls_verify": false')
    $driftTlsValid = Assert-AiMemoryRemotePolicyJson -Path $driftTls
    Assert-AiMemoryRemote (-not [bool]$driftTlsValid.valid) '[R2] relaxed TLS rejected (fixed true)' ((@($driftTlsValid.errors) -join '|'))
    $driftAuth = Join-Path $fixDir 'aimem-policy-drift-auth.json'
    Write-AiMemoryFixture -Path $driftAuth -Text ($canonText -replace '"name": "AIMEMORY_REMOTE_TOKEN"', '"name": "AIMEMORY_REMOTE_TOKEN", "value": "sk-SYNTHETICSECRET-9"')
    $driftAuthValid = Assert-AiMemoryRemotePolicyJson -Path $driftAuth
    Assert-AiMemoryRemote (-not [bool]$driftAuthValid.valid) '[R2] value-bearing auth rejected' ((@($driftAuthValid.errors) -join '|'))
    $driftScope = Join-Path $fixDir 'aimem-policy-drift-scope.json'
    Write-AiMemoryFixture -Path $driftScope -Text ($canonText -replace '"require_both_together": true', '"require_both_together": false')
    $driftScopeValid = Assert-AiMemoryRemotePolicyJson -Path $driftScope
    Assert-AiMemoryRemote (-not [bool]$driftScopeValid.valid) '[R2] relaxed scoping rejected' ((@($driftScopeValid.errors) -join '|'))
    $loopPol = Join-Path $fixDir 'aimem-policy-loopback.json'
    Write-AiMemoryFixture -Path $loopPol -Text ($canonText -replace '"url": ""', '"url": "http://127.0.0.1:9/v1"')
    $loopValid = Assert-AiMemoryRemotePolicyJson -Path $loopPol
    Assert-AiMemoryRemote (-not [bool]$loopValid.valid) '[R2] loopback endpoint rejected fail-closed' ((@($loopValid.errors) -join '|'))
    $markerPol = Join-Path $tempRoot 'hits-pol.txt'
    $markProbePol = [scriptblock]::Create(("[IO.File]::AppendAllText('" + ($markerPol -replace "'", "''") + "', 'hit;'); return @{ aimem_outcome = 'ok' }"))
    $driftCall = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-pol-3' -Probe $markProbePol -PolicyPath $driftBudget -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$driftCall.status -ceq 'AIMEMORY_POLICY_INVALID') -and ([bool]$driftCall.blocked) -and ((Get-AiMemoryHits -Path $markerPol) -eq 0)) '[R2] drifted policy runs 0 probes, blocks' ([string]$driftCall.status)

    # ---------- R2/R3: unconfigured => structured, never local, zero seam runs ----------
    Clear-McpSafetyState
    $markerUnc = Join-Path $tempRoot 'hits-unc.txt'
    $markProbeUnc = [scriptblock]::Create(("[IO.File]::AppendAllText('" + ($markerUnc -replace "'", "''") + "', 'hit;'); return @{ aimem_outcome = 'ok' }"))
    $uncOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-unc-1' -Workspace $scopeWs -Project $scopeProj -Probe $markProbeUnc -PolicyPath $repoPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$uncOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$uncOpt.failure -ceq 'AIMEMORY_UNCONFIGURED') -and ([bool]$uncOpt.fallback_continue) -and (-not [bool]$uncOpt.blocked) -and (-not [bool]$uncOpt.consulted)) '[R3] unconfigured optional continues structured' (([string]$uncOpt.status + '/' + [string]$uncOpt.failure))
    Assert-AiMemoryRemote ((Get-AiMemoryHits -Path $markerUnc) -eq 0) '[R3] unconfigured runs 0 probes (no local touch)' ([string](Get-AiMemoryHits -Path $markerUnc))
    $uncReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-unc-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $okProbe -PolicyPath $repoPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$uncReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$uncReq.failure -ceq 'AIMEMORY_UNCONFIGURED') -and ([bool]$uncReq.blocked) -and (-not [bool]$uncReq.fallback_continue)) '[R3] unconfigured required blocks typed' ([string]$uncReq.status)
    $phOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-unc-3' -Probe $okProbe -EndpointUrl '__USER_OWNED__' -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$phOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$phOpt.failure -ceq 'AIMEMORY_UNCONFIGURED')) '[R3] placeholder marker means unconfigured' ([string]$phOpt.failure)

    # ---------- scope gate: together always ----------
    Clear-McpSafetyState
    $scopeWsOnly = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-scope-1' -Workspace $scopeWs -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$scopeWsOnly.status -ceq 'AIMEMORY_SCOPE_INVALID') -and ([bool]$scopeWsOnly.fallback_continue) -and (-not [bool]$scopeWsOnly.blocked) -and (-not [bool]$scopeWsOnly.consulted)) '[SCOPE] workspace-only rejected, optional continues' ([string]$scopeWsOnly.status)
    $scopeProjOnly = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-scope-2' -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$scopeProjOnly.status -ceq 'AIMEMORY_SCOPE_INVALID')) '[SCOPE] project-only rejected' ([string]$scopeProjOnly.status)
    $scopeReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-scope-3' -Workspace $scopeWs -Criticality 'required' -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$scopeReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$scopeReq.failure -ceq 'AIMEMORY_SCOPE_INVALID') -and ([bool]$scopeReq.blocked)) '[SCOPE] split scope required blocks typed' ([string]$scopeReq.failure)

    # ---------- credential gate ----------
    Clear-McpSafetyState
    $noTok = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-tok-1' -Workspace $scopeWs -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token ''
    Assert-AiMemoryRemote (([string]$noTok.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$noTok.failure -ceq 'AIMEMORY_AUTH_MISSING') -and ([bool]$noTok.fallback_continue) -and (-not [bool]$noTok.consulted)) '[AUTH] absent token optional continues' ([string]$noTok.failure)
    $noTokReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-tok-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token '   '
    Assert-AiMemoryRemote (([string]$noTokReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$noTokReq.failure -ceq 'AIMEMORY_AUTH_MISSING') -and ([bool]$noTokReq.blocked)) '[AUTH] absent token required blocks' ([string]$noTokReq.failure)
    $badTok = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-tok-3' -Workspace $scopeWs -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token ('bad' + [char]10 + 'token')
    Assert-AiMemoryRemote (([string]$badTok.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$badTok.failure -ceq 'AIMEMORY_AUTH_INVALID')) '[AUTH] malformed token refused structured' ([string]$badTok.failure)
    try {
        $env:AIMEMORY_REMOTE_TOKEN = $null
        $envMiss = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-tok-4' -Workspace $scopeWs -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot
        Assert-AiMemoryRemote (([string]$envMiss.failure -ceq 'AIMEMORY_AUTH_MISSING')) '[AUTH] env-name wiring: no var means missing' ([string]$envMiss.failure)
        $env:AIMEMORY_REMOTE_TOKEN = $canaryToken
        $envHit = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-tok-5' -Workspace $scopeWs -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot
        Assert-AiMemoryRemote (([string]$envHit.status -ceq 'AIMEMORY_OK')) '[AUTH] env-name wiring: var value flows without registry value' ([string]$envHit.status)
    }
    finally {
        try { $env:AIMEMORY_REMOTE_TOKEN = $savedEnvToken } catch { }
    }

    # ---------- healthy recall seam ----------
    Clear-McpSafetyState
    $healthy = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-ok-1' -Workspace $scopeWs -Project $scopeProj -Probe $okProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([bool]$healthy.ok) -and ([string]$healthy.status -ceq 'AIMEMORY_OK') -and ([bool]$healthy.consulted) -and ([string]$healthy.output -ceq 'recall-ok') -and (-not [bool]$healthy.blocked) -and ([string]$healthy.endpoint_host -ceq 'memory.example.com')) '[T-healthy] seam returns recall OK' (([string]$healthy.status + '/' + [string]$healthy.output))

    # ---------- DNS failure seam ----------
    Clear-McpSafetyState
    $dnsOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-dns-1' -Workspace $scopeWs -Project $scopeProj -Probe $dnsProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$dnsOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$dnsOpt.failure -ceq 'AIMEMORY_DNS_FAILURE') -and ([bool]$dnsOpt.fallback_continue) -and (-not [bool]$dnsOpt.blocked)) '[T-dns] optional continues' ([string]$dnsOpt.failure)
    $dnsReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-dns-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $dnsProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$dnsReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$dnsReq.failure -ceq 'AIMEMORY_DNS_FAILURE') -and ([bool]$dnsReq.blocked)) '[T-dns] required blocks' ([string]$dnsReq.failure)

    # ---------- connect timeout (slow seam under tightened budget) ----------
    Clear-McpSafetyState
    $swT = [System.Diagnostics.Stopwatch]::StartNew()
    $toOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-to-1' -Workspace $scopeWs -Project $scopeProj -Probe $slowProbe -BudgetSecondsOverride 1 -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    $swT.Stop()
    Assert-AiMemoryRemote (([string]$toOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$toOpt.failure -ceq 'AIMEMORY_TIMEOUT') -and ([bool]$toOpt.fallback_continue)) '[T-timeout] slow seam maps to TIMEOUT, optional continues' ([string]$toOpt.failure)
    Assert-AiMemoryRemote ([int]$swT.Elapsed.TotalSeconds -lt 30) '[T-timeout] bounded wall clock' ([string][int]$swT.Elapsed.TotalSeconds)
    $toReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-to-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $slowProbe -BudgetSecondsOverride 1 -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$toReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$toReq.failure -ceq 'AIMEMORY_TIMEOUT') -and ([bool]$toReq.blocked)) '[T-timeout] required blocks' ([string]$toReq.failure)

    # ---------- auth failure + 5xx + network ----------
    Clear-McpSafetyState
    $authFailOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-af-1' -Workspace $scopeWs -Project $scopeProj -Probe $authProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$authFailOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$authFailOpt.failure -ceq 'AIMEMORY_AUTH_INVALID') -and ([bool]$authFailOpt.fallback_continue)) '[T-auth] server auth rejection optional continues' ([string]$authFailOpt.failure)
    $authFailReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-af-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $authProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$authFailReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$authFailReq.failure -ceq 'AIMEMORY_AUTH_INVALID') -and ([bool]$authFailReq.blocked)) '[T-auth] server auth rejection required blocks' ([string]$authFailReq.failure)
    $e5Opt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-5xx-1' -Workspace $scopeWs -Project $scopeProj -Probe $err5xxProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$e5Opt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$e5Opt.failure -ceq 'AIMEMORY_SERVER_ERROR') -and ([bool]$e5Opt.fallback_continue)) '[T-5xx] optional continues' ([string]$e5Opt.failure)
    $e5Req = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-5xx-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $err5xxProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$e5Req.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$e5Req.failure -ceq 'AIMEMORY_SERVER_ERROR') -and ([bool]$e5Req.blocked)) '[T-5xx] required blocks' ([string]$e5Req.failure)
    $netOpt = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-net-1' -Workspace $scopeWs -Project $scopeProj -Probe $failNetworkProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$netOpt.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$netOpt.failure -ceq 'AIMEMORY_NETWORK_ERROR')) '[T-network] optional continues' ([string]$netOpt.failure)
    $netReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-net-2' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $failNetworkProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$netReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([bool]$netReq.blocked)) '[T-network] required blocks' ([string]$netReq.failure)

    # ---------- circuit: 2 failures open, hammering impeded ----------
    Clear-McpSafetyState
    $c1 = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-circ-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([int]$c1.consecutive -eq 1) -and ([string]$c1.circuit -ceq 'CLOSED')) '[T-circuit] first failure consecutive 1, still closed' (([string]$c1.consecutive + '/' + [string]$c1.circuit))
    $c2 = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-circ-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([int]$c2.consecutive -eq 2) -and ([string]$c2.circuit -ceq 'OPEN') -and ([string]$c2.failure -ceq 'AIMEMORY_TIMEOUT')) '[T-circuit] second failure opens circuit' (([string]$c2.consecutive + '/' + [string]$c2.circuit))
    $markerCirc = Join-Path $tempRoot 'hits-circ.txt'
    $markProbeCirc = [scriptblock]::Create(("[IO.File]::AppendAllText('" + ($markerCirc -replace "'", "''") + "', 'hit;'); return @{ aimem_outcome = 'ok' }"))
    $cOpen = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-circ-1' -Workspace $scopeWs -Project $scopeProj -Probe $markProbeCirc -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$cOpen.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$cOpen.failure -ceq 'AIMEMORY_CIRCUIT_OPEN') -and ([bool]$cOpen.fallback_continue)) '[T-circuit] open fast-fails structured' ([string]$cOpen.failure)
    Assert-AiMemoryRemote ((Get-AiMemoryHits -Path $markerCirc) -eq 0) '[T-circuit] open circuit runs 0 probes (no hammering)' ([string](Get-AiMemoryHits -Path $markerCirc))
    $cOpenReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-circ-1' -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $markProbeCirc -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$cOpenReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$cOpenReq.failure -ceq 'AIMEMORY_CIRCUIT_OPEN') -and ([bool]$cOpenReq.blocked)) '[T-circuit] open required blocks typed' ([string]$cOpenReq.failure)
    Assert-AiMemoryRemote ((Get-AiMemoryHits -Path $markerCirc) -eq 0) '[T-circuit] required open still runs 0 probes' ([string](Get-AiMemoryHits -Path $markerCirc))

    # ---------- cooldown / rearm ----------
    Clear-McpSafetyState
    $t0 = [DateTime]::UtcNow
    [void](Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-cool-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken -NowUtc $t0)
    [void](Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-cool-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken -NowUtc $t0)
    $markerCool = Join-Path $tempRoot 'hits-cool.txt'
    $markOkCool = [scriptblock]::Create(("[IO.File]::AppendAllText('" + ($markerCool -replace "'", "''") + "', 'hit;'); return @{ aimem_outcome = 'ok'; data = 'recovered' }"))
    $early = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-cool-1' -Workspace $scopeWs -Project $scopeProj -Probe $markOkCool -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken -NowUtc $t0
    Assert-AiMemoryRemote (([string]$early.failure -ceq 'AIMEMORY_CIRCUIT_OPEN') -and ((Get-AiMemoryHits -Path $markerCool) -eq 0)) '[T-cooldown] before cooldown fast-fails, probe not run' ([string]$early.failure)
    $late = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-cool-1' -Workspace $scopeWs -Project $scopeProj -Probe $markOkCool -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken -NowUtc ($t0.AddSeconds(301))
    Assert-AiMemoryRemote (([string]$late.status -ceq 'AIMEMORY_OK') -and ((Get-AiMemoryHits -Path $markerCool) -eq 1) -and ([string]$late.circuit -ceq 'CLOSED')) '[T-cooldown] expired cooldown rearms CLOSED on success' ([string]$late.status)

    # ---------- health probe: bounded, separate circuit ----------
    Clear-McpSafetyState
    $hOk = Invoke-AiMemoryRemoteHealth -TurnId 'turn-aimem-h-1' -Workspace $scopeWs -Project $scopeProj -Probe $healthOkProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$hOk.status -ceq 'AIMEMORY_HEALTHY') -and ([bool]$hOk.ok) -and ([bool]$hOk.consulted) -and (-not [bool]$hOk.blocked)) '[T-health] healthy seam' ([string]$hOk.status)
    $hDns = Invoke-AiMemoryRemoteHealth -TurnId 'turn-aimem-h-2' -Probe $dnsProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$hDns.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$hDns.failure -ceq 'AIMEMORY_DNS_FAILURE') -and ([bool]$hDns.fallback_continue)) '[T-health] dns failure optional continues' ([string]$hDns.failure)
    $hUnc = Invoke-AiMemoryRemoteHealth -TurnId 'turn-aimem-h-3' -Probe $healthOkProbe -PolicyPath $repoPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$hUnc.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$hUnc.failure -ceq 'AIMEMORY_UNCONFIGURED')) '[T-health] unconfigured health continues' ([string]$hUnc.failure)
    $hUncReq = Invoke-AiMemoryRemoteHealth -TurnId 'turn-aimem-h-4' -Criticality 'required' -Probe $healthOkProbe -PolicyPath $repoPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$hUncReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([bool]$hUncReq.blocked)) '[T-health] unconfigured required blocks' ([string]$hUncReq.status)
    Clear-McpSafetyState
    [void](Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-sep-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken)
    [void](Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-sep-1' -Workspace $scopeWs -Project $scopeProj -Probe $failTimeoutProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken)
    $hSep = Invoke-AiMemoryRemoteHealth -TurnId 'turn-aimem-sep-1' -Workspace $scopeWs -Project $scopeProj -Probe $healthOkProbe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$hSep.status -ceq 'AIMEMORY_HEALTHY')) '[T-health] recall circuit does not trip health (separate key)' ([string]$hSep.status)

    # ---------- optional continues in every branch; required blocks in every branch ----------
    Clear-McpSafetyState
    $branchSet = @(
        @{ name = 'dns'; probe = $dnsProbe; failure = 'AIMEMORY_DNS_FAILURE' },
        @{ name = 'auth'; probe = $authProbe; failure = 'AIMEMORY_AUTH_INVALID' },
        @{ name = '5xx'; probe = $err5xxProbe; failure = 'AIMEMORY_SERVER_ERROR' },
        @{ name = 'network'; probe = $failNetworkProbe; failure = 'AIMEMORY_NETWORK_ERROR' }
    )
    $bi = 0
    foreach ($b in $branchSet) {
        $bi++
        $tid = ('turn-aimem-br-' + [string]$bi)
        $ro = Invoke-AiMemoryRemoteCall -TurnId $tid -Workspace $scopeWs -Project $scopeProj -Probe $b.probe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
        Assert-AiMemoryRemote (([string]$ro.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$ro.failure -ceq [string]$b.failure) -and ([bool]$ro.fallback_continue) -and (-not [bool]$ro.blocked)) ('[OPT] optional continues on ' + [string]$b.name) ([string]$ro.failure)
        Clear-McpSafetyState
        $rr = Invoke-AiMemoryRemoteCall -TurnId ($tid + 'r') -Workspace $scopeWs -Project $scopeProj -Criticality 'required' -Probe $b.probe -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
        Assert-AiMemoryRemote (([string]$rr.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$rr.failure -ceq [string]$b.failure) -and ([bool]$rr.blocked) -and (-not [bool]$rr.fallback_continue)) ('[REQ] required blocks on ' + [string]$b.name) ([string]$rr.failure)
        Clear-McpSafetyState
    }

    # ---------- endpoint override hygiene ----------
    Clear-McpSafetyState
    $badUrl = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-eu-1' -Probe $okProbe -EndpointUrl 'not-a-url' -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$badUrl.status -ceq 'AIMEMORY_UNAVAILABLE') -and ([string]$badUrl.failure -ceq 'AIMEMORY_ENDPOINT_INVALID')) '[URL] malformed override optional continues' ([string]$badUrl.failure)
    $badUrlReq = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-eu-2' -Criticality 'required' -Probe $okProbe -EndpointUrl 'ftp://memory.example.com/x' -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$badUrlReq.status -ceq 'AIMEMORY_REQUIRED_BLOCKED') -and ([string]$badUrlReq.failure -ceq 'AIMEMORY_ENDPOINT_INVALID')) '[URL] non-http override required blocks' ([string]$badUrlReq.failure)
    $loopUrl = Invoke-AiMemoryRemoteCall -TurnId 'turn-aimem-eu-3' -Probe $okProbe -EndpointUrl 'http://127.0.0.1:9/v1' -PolicyPath $cfgPolicy -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -Token $canaryToken
    Assert-AiMemoryRemote (([string]$loopUrl.failure -ceq 'AIMEMORY_ENDPOINT_INVALID')) '[URL] loopback override rejected (remote-only)' ([string]$loopUrl.failure)

    # ---------- R4/R5: telemetry sanitized, bounded ----------
    $evText = Get-AiMemoryEvidenceText -Dir $teleRoot
    Assert-AiMemoryRemote (($evText -match 'AIMEMORY_OK') -and ($evText -match 'memory.example.com') -and ($evText -match 'len:4')) '[R4] host plus len:port recorded' ''
    Assert-AiMemoryRemote ((($evText -notmatch 'SYNTHETICSECRET'))) '[R4] canary token never in JSONL' ''
    Assert-AiMemoryRemote (($evText -notmatch 'memory.example.com:8443')) '[R4] endpoint URL never logged whole' ''
    Assert-AiMemoryRemote (($evText -notmatch 'zz9canary')) '[R4] raw scope names never in JSONL' ''
    Assert-AiMemoryRemote (($evText -match 'scope_hash')) '[R4] scope travels as hash' ''
    Assert-AiMemoryRemote (($evText -match 'turn_hash16')) '[R4] turn travels as hash16' ''
    $sh1 = Get-AiMemoryRemoteScopeHash -Workspace $scopeWs -Project $scopeProj
    Assert-AiMemoryRemote (($sh1 -cmatch '^[0-9a-f]{64}$')) '[R4] scope hash is 64-hex' ($sh1)
    $sh1b = Get-AiMemoryRemoteScopeHash -Workspace $scopeWs -Project $scopeProj
    Assert-AiMemoryRemote (($sh1b -ceq $sh1)) '[R4] same scope yields same hash' ''
    $shDiff = Get-AiMemoryRemoteScopeHash -Workspace $scopeWs -Project 'other-proj'
    Assert-AiMemoryRemote ((($shDiff -cmatch '^[0-9a-f]{64}$') -and ($shDiff -cne $sh1))) '[R4] different project yields different hash' ''
    $evilSummary = 'leak sk-SYNTHETICSECRET-9 token=abc123'
    $wEvil = Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_UNAVAILABLE' -Operation 'recall' -EndpointHost $evilSummary -Workspace $scopeWs -Project $scopeProj -TurnId 'turn-aimem-ev-1' -Criticality 'optional' -Failure $evilSummary -TelemetryRoot $teleRoot
    Assert-AiMemoryRemote ([bool]$wEvil.ok) '[R4] hostile fields accepted for write' ([string]$wEvil.skipped)
    $evText2 = Get-AiMemoryEvidenceText -Dir $teleRoot
    Assert-AiMemoryRemote ((($evText2 -notmatch 'SYNTHETICSECRET') -and ($evText2 -notmatch 'abc123'))) '[R4] hostile fields redacted in JSONL' ''
    Assert-AiMemoryRemote (($evText2 -notmatch 'turn-aimem-ev-1')) '[R4] raw turn id never in JSONL' ''
    $teleCap = Join-Path $tempRoot 'evidence-cap'
    New-Item -ItemType Directory -Path $teleCap -Force | Out-Null
    $savedCap = $script:AiMemoryRemoteTelemetryCapBytes
    $script:AiMemoryRemoteTelemetryCapBytes = 600
    try {
        $cw1 = Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_OK' -Operation 'recall' -EndpointHost 'memory.example.com' -TurnId 'turn-aimem-cap-1' -TelemetryRoot $teleCap
        Assert-AiMemoryRemote ([bool]$cw1.ok) '[R4] first cap event written' ([string]$cw1.skipped)
        $targetCap = Get-AiMemoryRemoteEvidenceFile -TelemetryRoot $teleCap
        $curLen = ([IO.FileInfo]::new($targetCap)).Length
        $script:AiMemoryRemoteTelemetryCapBytes = ($curLen + 10)
        $cw2 = Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_OK' -Operation 'recall' -EndpointHost 'memory.example.com' -TurnId 'turn-aimem-cap-2' -TelemetryRoot $teleCap
        Assert-AiMemoryRemote (((-not [bool]$cw2.ok)) -and ([string]$cw2.skipped -ceq 'rotation-cap')) '[R4] overflowing event honestly dropped' ([string]$cw2.skipped)
        $finalLen = ([IO.FileInfo]::new($targetCap)).Length
        Assert-AiMemoryRemote ($finalLen -le ($curLen + 10)) '[R4] bounded file never exceeds cap' ([string]$finalLen)
    }
    finally { $script:AiMemoryRemoteTelemetryCapBytes = $savedCap }

    # ---------- R4: lock-busy skip, never blocks ----------
    $teleGate = $null
    try { $teleGate = Get-McpSafetySharedGate -Name 'TelemetryGate' } catch { $teleGate = $null }
    Assert-AiMemoryRemote ($null -ne $teleGate) '[R4] shared TelemetryGate reachable' ''
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
        Assert-AiMemoryRemote ([bool]$tgHeld) '[R4] background holder owns TelemetryGate' ''
        $teleHeld = Join-Path $tempRoot 'evidence-held'
        New-Item -ItemType Directory -Path $teleHeld -Force | Out-Null
        $swHeld = [System.Diagnostics.Stopwatch]::StartNew()
        $wHeld = Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_OK' -Operation 'recall' -EndpointHost 'memory.example.com' -TurnId 'turn-aimem-held-1' -TelemetryRoot $teleHeld
        $swHeld.Stop()
        Assert-AiMemoryRemote (((-not [bool]$wHeld.ok)) -and ([string]$wHeld.skipped -ceq 'lock-busy')) '[R4] contended evidence honestly skipped' ([string]$wHeld.skipped)
        Assert-AiMemoryRemote ([int]$swHeld.Elapsed.TotalMilliseconds -lt 8000) '[R4] skip returns bounded' ([string][int]$swHeld.Elapsed.TotalMilliseconds)
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

    # ---------- F1: envelope policy invalid preserved fail-closed (8/8 matrix, 0 probes) ----------
    Clear-McpSafetyState
    $missingMcp = Join-Path $fixDir 'mcp-does-not-exist.json'
    $badMcp = Join-Path $fixDir 'mcp-badjson.json'
    Write-AiMemoryFixture -Path $badMcp -Text '{not json'
    $f1Matrix = @(
        @{ name = 'recall/optional/ausente';   op = 'recall'; crit = 'optional'; pol = 'missing';   turn = 'turn-aimem-f1-1' },
        @{ name = 'recall/optional/malformado'; op = 'recall'; crit = 'optional'; pol = 'bad';     turn = 'turn-aimem-f1-2' },
        @{ name = 'recall/required/ausente';   op = 'recall'; crit = 'required'; pol = 'missing';   turn = 'turn-aimem-f1-3' },
        @{ name = 'recall/required/malformado'; op = 'recall'; crit = 'required'; pol = 'bad';     turn = 'turn-aimem-f1-4' },
        @{ name = 'health/optional/ausente';   op = 'health'; crit = 'optional'; pol = 'missing';   turn = 'turn-aimem-f1-5' },
        @{ name = 'health/optional/malformado'; op = 'health'; crit = 'optional'; pol = 'bad';     turn = 'turn-aimem-f1-6' },
        @{ name = 'health/required/ausente';   op = 'health'; crit = 'required'; pol = 'missing';   turn = 'turn-aimem-f1-7' },
        @{ name = 'health/required/malformado'; op = 'health'; crit = 'required'; pol = 'bad';     turn = 'turn-aimem-f1-8' }
    )
    foreach ($cell in $f1Matrix) {
        $polPath = $missingMcp
        if ([string]$cell.pol -ceq 'bad') { $polPath = $badMcp }
        $mkF1 = Join-Path $tempRoot ('hits-f1-' + [string]$cell.turn + '.txt')
        if (Test-Path -LiteralPath $mkF1) { Remove-Item -LiteralPath $mkF1 -Force -ErrorAction SilentlyContinue | Out-Null }
        $mkProbeF1 = [scriptblock]::Create(("[IO.File]::AppendAllText('" + ($mkF1 -replace "'", "''") + "', 'hit;'); return @{ aimem_outcome = 'ok' }"))
        if ([string]$cell.op -ceq 'recall') {
            $rf1 = Invoke-AiMemoryRemoteCall -TurnId ([string]$cell.turn) -Workspace $scopeWs -Project $scopeProj -Criticality ([string]$cell.crit) -Probe $mkProbeF1 -PolicyPath $cfgPolicy -McpPolicyPath $polPath -TelemetryRoot $teleRoot -Token $canaryToken
        }
        else {
            $rf1 = Invoke-AiMemoryRemoteHealth -TurnId ([string]$cell.turn) -Workspace $scopeWs -Project $scopeProj -Criticality ([string]$cell.crit) -Probe $mkProbeF1 -PolicyPath $cfgPolicy -McpPolicyPath $polPath -TelemetryRoot $teleRoot -Token $canaryToken
        }
        $hitsF1 = Get-AiMemoryHits -Path $mkF1
        Assert-AiMemoryRemote (([string]$rf1.status -ceq 'AIMEMORY_POLICY_INVALID') -and ([string]$rf1.failure -ceq 'AIMEMORY_POLICY_INVALID') -and ([bool]$rf1.blocked) -and (-not [bool]$rf1.fallback_continue) -and (-not [bool]$rf1.consulted) -and ($hitsF1 -eq 0)) ('[F1] ' + [string]$cell.name + ' blocks, 0 probes') (([string]$rf1.status + '/' + [string]$rf1.failure + '/hits=' + [string]$hitsF1))
    }

    # ---------- F2: token-name plus bare-value redaction on every evidence path ----------
    $bareCanary = 'opaque123zz9'
    try {
        $env:AIMEMORY_REMOTE_TOKEN = $bareCanary
        $rBare = Get-AiMemoryRemoteFieldRedaction -Value ('denied for ' + $bareCanary + ' retry')
        Assert-AiMemoryRemote (($rBare -notmatch 'opaque123zz9')) '[F2] bare token-shaped value redacted without sk- prefix' ''
        $rName = Get-AiMemoryRemoteFieldRedaction -Value ('fail at AIMEMORY_REMOTE_TOKEN=' + $bareCanary + ' end')
        Assert-AiMemoryRemote ((($rName -notmatch 'opaque123zz9') -and ($rName -match 'AIMEMORY_REMOTE_TOKEN <redacted>'))) '[F2] token name=value redacted with env set' ''
        $wBare = Write-AiMemoryRemoteEvidence -EventName 'AIMEMORY_UNAVAILABLE' -Operation 'recall' -EndpointHost 'memory.example.com' -Workspace $scopeWs -Project $scopeProj -TurnId 'turn-aimem-f2-1' -Criticality 'optional' -Failure ('server rejected ' + $bareCanary + ' for AIMEMORY_REMOTE_TOKEN=' + $bareCanary) -TelemetryRoot $teleRoot
        Assert-AiMemoryRemote ([bool]$wBare.ok) '[F2] hostile token-bearing failure accepted for write' ([string]$wBare.skipped)
    }
    finally {
        try { $env:AIMEMORY_REMOTE_TOKEN = $savedEnvToken } catch { }
    }
    $evText3 = Get-AiMemoryEvidenceText -Dir $teleRoot
    Assert-AiMemoryRemote (($evText3 -notmatch 'opaque123zz9')) '[F2] bare canary never in JSONL on any path' ''

    # ---------- ASCII-only new files ----------
    foreach ($p in @($libPath, $repoPolicy, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-AiMemoryRemote ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }
}
finally {
    try { $env:AIMEMORY_REMOTE_TOKEN = $savedEnvToken } catch { }
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ("[SUMMARY] passed={0} failed={1}" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
