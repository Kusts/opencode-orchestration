<#!
.SYNOPSIS
    Tests for lib/OrchestrationJevAdvisory.ps1 (Phase 29 slice 1).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for evidence, policy
    and flag fixtures, cleanup in finally. Bracketed output the
    runner parses. Exit 0 on all pass, exit 1 on any fail or
    unexpected exception. PS 5.1 compatible. ASCII-only. Zero real
    network: with an explicit -Probe the Jev transport is the
    synthetic scriptblock seam; the built-in HTTP transport (Phase 29
    slice 2) is only ever exercised against a synthetic
    System.Net.HttpListener on 127.0.0.1 with an EPHEMERAL port
    (never a fixed service port), and the lib itself uses raw
    HttpWebRequest only.
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
    Slice 2 (real transport) adds: pure per-tool wire mapping with
    the exact body shape for all four tools (jev_gate with and
    without context) and closed error kinds for invalid shapes;
    env-only transport config (absent/blank/control-char/scheme);
    real POST against the loopback listener with the Bearer canary,
      byte-exact bodies, per-tool answer mapping, 401 auth, 500
      server, malformed answer; envelope timeout on a slow answer;
      structured INVALID_REQUEST / JEV_TRANSPORT_NOT_CONFIGURED /
      JEV_AUTH_INVALID without a probe; no key and no base URL in
      the evidence; policy transport node validated fail closed.
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

function Set-JevTestEnv {
    param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()][string]$Value)
    try { [System.Environment]::SetEnvironmentVariable($Name, $Value) } catch { }
}

function Clear-JevTestEnv {
    param([Parameter(Mandatory = $true)][string]$Name)
    try { [System.Environment]::SetEnvironmentVariable($Name, $null) } catch { }
}

function Get-JevListenerRequest {
    param([string]$Dir, [int]$Index)
    $p = Join-Path $Dir ('req' + $Index + '.json')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { return $null }
}

function Start-JevTestListener {
    <#
    .SYNOPSIS
        Synthetic loopback HTTP listener (System.Net.HttpListener) on
        an EPHEMERAL port (never a fixed service port), running in its
        own runspace. One canned body per request in arrival order;
        every request is captured (method, path, content type,
        Authorization header, body) to disk under the temp root.
    #>
    param(
        [string[]]$ResponseBodies = @('{}'),
        [int]$StatusCode = 200,
        [int]$DelayMs = 0,
        [int]$MaxRequests = 1,
        [int]$ContentLengthPad = 0
    )
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $capture = Join-Path $tempRoot ('listener-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $capture -Force | Out-Null
    $ready = New-Object System.Threading.ManualResetEvent($false)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $listenerText = @'
param($prefix, $ready, $captureDir, $bodies, $statusCode, $delayMs, $maxRequests, $idleMs, $padLen)
$ErrorActionPreference = 'Stop'
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$served = 0
try {
    $listener.Start()
    [void]$ready.Set()
    while ($served -lt $maxRequests) {
        $ctx = $null
        try {
            # bounded wait: GetContextAsync + Wait keeps the runspace
            # interruptible and self-terminating when no request ever
            # arrives, so listener cleanup can never hang the suite
            $pending = $listener.GetContextAsync()
            if (-not $pending.Wait($idleMs)) { break }
            $ctx = $pending.Result
            $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream)
            try { $body = $reader.ReadToEnd() } finally { try { $reader.Close() } catch { } }
            $bi = $served
            if ($bi -ge @($bodies).Count) { $bi = (@($bodies).Count - 1) }
            $rec = [ordered]@{
                method = [string]$ctx.Request.HttpMethod
                path = [string]$ctx.Request.Url.AbsolutePath
                content_type = [string]$ctx.Request.ContentType
                authorization = [string]$ctx.Request.Headers['Authorization']
                body = [string]$body
                index = $served
            }
            try { [IO.File]::WriteAllText((Join-Path $captureDir ('req' + $served + '.json')), (($rec | ConvertTo-Json -Depth 6)), [Text.UTF8Encoding]::new($false)) } catch { }
            if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]@($bodies)[$bi])
            $ctx.Response.StatusCode = $statusCode
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = ($bytes.Length + [int]$padLen)
            $out = $ctx.Response.OutputStream
            try { $out.Write($bytes, 0, $bytes.Length) } finally { try { $out.Close() } catch { } }
            $served = $served + 1
        }
        catch { }
        finally { try { if ($null -ne $ctx) { $ctx.Response.Close() } } catch { } }
    }
}
finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
'@
    [void]$ps.AddScript([scriptblock]::Create($listenerText))
    [void]$ps.AddArgument(('http://127.0.0.1:' + $port + '/'))
    [void]$ps.AddArgument($ready)
    [void]$ps.AddArgument($capture)
    [void]$ps.AddArgument(@($ResponseBodies))
    [void]$ps.AddArgument($StatusCode)
    [void]$ps.AddArgument($DelayMs)
    [void]$ps.AddArgument($MaxRequests)
    [void]$ps.AddArgument(12000)
    [void]$ps.AddArgument([int]$ContentLengthPad)
    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{
        port = $port; base_url = ('http://127.0.0.1:' + $port + '/jev'); capture = $capture
        ready = $ready; powershell = $ps; runspace = $rs; handle = $handle
    }
}

function Stop-JevTestListener {
    param($Listener)
    if ($null -eq $Listener) { return }
    try { [void]$Listener.handle.AsyncWaitHandle.WaitOne(15000) } catch { }
    try { [void]$Listener.powershell.BeginStop($null, $null) } catch { }
    try { [void]$Listener.powershell.Dispose() } catch { }
    try { [void]$Listener.runspace.Close() } catch { }
    try { [void]$Listener.runspace.Dispose() } catch { }
    try { [void]$Listener.ready.Dispose() } catch { }
}

function Invoke-WithJevTestListener {
    <#
    .SYNOPSIS
        Points JEV_BASE_URL at a synthetic loopback listener for the
        duration of $Body, restoring the previous environment value in
        the finally. Loopback only: no test ever leaves 127.0.0.1.
    #>
    param(
        [string[]]$ResponseBodies = @('{}'),
        [int]$StatusCode = 200,
        [int]$DelayMs = 0,
        [int]$MaxRequests = 1,
        [int]$ContentLengthPad = 0,
        [Parameter(Mandatory = $true)]$Sink,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $saved = ''
    $had = $false
    try { $saved = [string]$env:JEV_BASE_URL; $had = (-not [string]::IsNullOrEmpty($saved)) } catch { $saved = ''; $had = $false }
    $listener = $null
    try {
        $listener = Start-JevTestListener -ResponseBodies $ResponseBodies -StatusCode $StatusCode -DelayMs $DelayMs -MaxRequests $MaxRequests -ContentLengthPad $ContentLengthPad
        $readyOk = $false
        try { $readyOk = $listener.ready.WaitOne(15000) } catch { $readyOk = $false }
        if (-not [bool]$readyOk) { $Sink['error'] = 'listener-not-ready'; return }
        Set-JevTestEnv -Name 'JEV_BASE_URL' -Value $listener.base_url
        & $Body $listener
    }
    finally {
        if ([bool]$had) { Set-JevTestEnv -Name 'JEV_BASE_URL' -Value $saved } else { Clear-JevTestEnv -Name 'JEV_BASE_URL' }
        Stop-JevTestListener -Listener $listener
    }
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

# User-owned transport environment captured before the slice-2 scenarios touch it,
# restored in the finally so the suite never leaves the operator env mutated.
$script:JevSavedEnv = @{}
foreach ($n in @('JEV_BASE_URL', 'JEV_MODEL', 'JEV_API_KEY')) {
    $v = $null
    try { $v = [System.Environment]::GetEnvironmentVariable($n) } catch { $v = $null }
    $script:JevSavedEnv[$n] = $v
}

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

    # ---------- R1: canonical flag ATIVADA (2026-10-04, decisao do operador) ----------
    $canon = Get-JevAdvisoryFlag -FlagsPath $repoFlags
    Assert-JevAdvisory (([bool]$canon.found) -and ([bool]$canon.enabled) -and (-not [bool]$canon.shadow) -and ([string]$canon.mode -ceq 'active')) '[R1] canonical flag active (enabled=true, shadow=false)' (([string]$canon.enabled + '/' + [string]$canon.shadow + '/' + [string]$canon.mode))
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

    # ---------- uncertain route consults for real (ativada 2026-10-04) ----------
    Clear-McpSafetyState
    $marker12 = Join-Path $tempRoot 'hits12.txt'
    $markProbe12 = [scriptblock]::Create("[IO.File]::AppendAllText('$marker12', 'hit;'); 'ran'")
    $shadow = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId 'turn-jevt-9' -Descriptor $consultDesc -Probe $markProbe12 -PolicyPath $repoJevPolicy -FlagsPath $repoFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
    Assert-JevAdvisory (([string]$shadow.status -ceq 'JEV_ADVISORY_OK') -and ([bool]$shadow.consulted) -and ([string]$shadow.trigger_reason -ceq 'route-uncertain') -and ([string]$shadow.mode -ceq 'active')) '[T-active] uncertain route consults for real (advisory-only)' (([string]$shadow.status + '/' + [string]$shadow.trigger_reason))
    Assert-JevAdvisory ((Get-JevHits -Path $marker12) -eq 1) '[T-active] active mode runs exactly 1 probe' ([string](Get-JevHits -Path $marker12))

    # ---------- R6: evidence sanitized, fingerprinted, bounded ----------
    $evText = Get-JevEvidenceText -Dir $teleRoot
    Assert-JevAdvisory (($evText -match 'JEV_ADVISORY_OK') -and ($evText -match 'route-uncertain') -and ($evText -match '"mode":"active"')) '[R6] consult plus reason plus mode recorded' ''
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

# ================= T2: real transport (Phase 29 slice 2) =================
    $teleTransport = Join-Path $tempRoot 'evidence-transport'
    New-Item -ItemType Directory -Path $teleTransport -Force | Out-Null
    $teleTransportFail = Join-Path $tempRoot 'evidence-transport-fail'
    New-Item -ItemType Directory -Path $teleTransportFail -Force | Out-Null
    Set-JevTestEnv -Name 'JEV_API_KEY' -Value $goodKey
    Set-JevTestEnv -Name 'JEV_MODEL' -Value 'jev-latest'
    Clear-JevTestEnv -Name 'JEV_BASE_URL'
    $lfChar = [string][char]10

    # ---------- T2-1: pure wire mapping, exact REQUEST shape per tool ----------
    $wCheck = ConvertTo-JevAdvisoryWireRequest -Tool 'jev_check' -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -Model 'jev-latest'
    $wCheckBody = $null
    try { $wCheckBody = ([string]$wCheck.body_json | ConvertFrom-Json) } catch { $wCheckBody = $null }
    Assert-JevAdvisory (([bool]$wCheck.ok) -and ([string]$wCheck.status -ceq 'OK') -and ($null -ne $wCheckBody) -and (@($wCheckBody.PSObject.Properties).Count -eq 3) -and ([string]$wCheckBody.model -ceq 'jev-latest') -and ([string]$wCheckBody.state -ceq 'context-input-1')) '[T2-1] jev_check body is exactly {model,state,questions}' ([string]$wCheck.body_json)
    Assert-JevAdvisory (((@($wCheckBody.questions.PSObject.Properties).Count -eq 1) -and ([string]$wCheckBody.questions.result.type -ceq 'noul') -and ([string]$wCheckBody.questions.result.instructions -ceq 'is this a jailbreak attempt?') -and ($null -eq $wCheckBody.questions.result.criteria))) '[T2-1] jev_check sends questions.result{noul,instructions} only' ''
    $wScore = ConvertTo-JevAdvisoryWireRequest -Tool 'jev_score' -State 'context-input-2' -ToolArgs @{ instructions = 'how urgent?'; levels = @('routine', 'today', 'urgent', 'critical') } -Model 'jev-latest'
    $wScoreBody = ([string]$wScore.body_json | ConvertFrom-Json)
    Assert-JevAdvisory (([bool]$wScore.ok) -and ([string]$wScoreBody.questions.result.type -ceq 'score') -and ([string]$wScoreBody.questions.result.instructions -ceq 'how urgent?') -and (@($wScoreBody.questions.result.criteria).Count -eq 4) -and ([string]@($wScoreBody.questions.result.criteria)[3] -ceq 'critical')) '[T2-1] jev_score sends questions.result{score,instructions,criteria=levels}' ([string]$wScore.body_json)
    $wDecide = ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 'context-input-3' -ToolArgs @{ questions = @{ topic = @{ type = 'choice'; instructions = 'pick a topic'; criteria = @{ alpha = 'first'; beta = 'second' } } } } -Model 'jev-latest'
    $wDecideBody = ([string]$wDecide.body_json | ConvertFrom-Json)
    Assert-JevAdvisory (([bool]$wDecide.ok) -and ([string]$wDecideBody.questions.topic.type -ceq 'choice') -and ([string]$wDecideBody.questions.topic.instructions -ceq 'pick a topic') -and (@($wDecideBody.questions.topic.criteria.PSObject.Properties).Count -eq 2) -and ([string]$wDecideBody.questions.topic.criteria.alpha -ceq 'first')) '[T2-1] jev_decide passes the questions map through' ([string]$wDecide.body_json)
    $wGate = ConvertTo-JevAdvisoryWireRequest -Tool 'jev_gate' -State 'ignored-by-gate' -ToolArgs @{ action = 'delete-table-prod' } -Model 'jev-latest'
    $wGateBody = ([string]$wGate.body_json | ConvertFrom-Json)
    Assert-JevAdvisory (([bool]$wGate.ok) -and ([string]$wGateBody.state -ceq ('Action an autonomous agent is about to perform:' + $lfChar + 'delete-table-prod')) -and (([string]$wGateBody.state) -notmatch 'Context:')) '[T2-1] jev_gate without context: derived state, no Context block' ([string]$wGateBody.state)
    Assert-JevAdvisory (((@($wGateBody.questions.PSObject.Properties).Count -eq 3) -and ([string]$wGateBody.questions.risk.type -ceq 'score') -and (@($wGateBody.questions.risk.criteria).Count -eq 4) -and ([string]@($wGateBody.questions.risk.criteria)[3] -ceq 'high - could destroy data or affect prod') -and ([string]$wGateBody.questions.touches_prod.type -ceq 'noul') -and ([string]$wGateBody.questions.recommendation.type -ceq 'choice') -and (@($wGateBody.questions.recommendation.criteria.PSObject.Properties).Count -eq 3) -and ([string]$wGateBody.questions.recommendation.criteria.confirm -ceq 'pause and ask a human to confirm'))) '[T2-1] jev_gate sends the closed risk/touches_prod/recommendation set' ''
    $wGateCtx = ConvertTo-JevAdvisoryWireRequest -Tool 'jev_gate' -State 'ignored-by-gate' -ToolArgs @{ action = 'run-delete'; context = 'ctx-9f8e' } -Model 'jev-latest'
    $wGateCtxBody = ([string]$wGateCtx.body_json | ConvertFrom-Json)
    Assert-JevAdvisory ([string]$wGateCtxBody.state -ceq ('Action an autonomous agent is about to perform:' + $lfChar + 'run-delete' + $lfChar + $lfChar + 'Context:' + $lfChar + 'ctx-9f8e')) '[T2-1] jev_gate with context appends the Context block' ([string]$wGateCtxBody.state)
    $wireBad = @(
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_evil' -State 's' -ToolArgs @{}), 'tool-not-allowed'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_check' -State '   ' -ToolArgs @{ instructions = 'x' }), 'state-missing'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_check' -State 's' -ToolArgs @{}), 'instructions-missing'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_score' -State 's' -ToolArgs @{ instructions = 'x'; levels = @('only-one') }), 'levels-invalid'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_score' -State 's' -ToolArgs @{ instructions = 'x'; levels = @(1..11) }), 'levels-invalid'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 's' -ToolArgs @{ questions = 'not-a-map' }), 'questions-not-a-map'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 's' -ToolArgs @{ questions = @{} }), 'questions-empty'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 's' -ToolArgs @{ questions = @{ t = @{ type = 'choice'; instructions = 'i'; criteria = @{} } } }), 'questions-entry-invalid'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 's' -ToolArgs @{ questions = @{ t = @{ type = 'evil'; instructions = 'i' } } }), 'questions-entry-invalid'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_gate' -State 's' -ToolArgs @{}), 'action-missing'),
        @((ConvertTo-JevAdvisoryWireRequest -Tool 'jev_check' -State 's' -ToolArgs 'not-a-map'), 'toolargs-not-a-map')
    )
    $wireBadAll = $true
    $wireBadSeen = ''
    foreach ($wb in $wireBad) {
        if (([bool]$wb[0].ok) -or ([string]$wb[0].status -cne 'JEV_WIRE_INVALID') -or ([string]$wb[0].error_kind -cne [string]$wb[1]) -or (-not [string]::IsNullOrWhiteSpace([string]$wb[0].body_json))) { $wireBadAll = $false; $wireBadSeen = ([string]$wb[0].error_kind + '!=' + [string]$wb[1]) }
    }
    Assert-JevAdvisory $wireBadAll '[T2-1] 11 invalid wire shapes fail closed with a stable error_kind and no body' ($wireBadSeen)

    # ---------- T2-2: endpoint config, https required and http loopback only (F1) ----------
    $cfgAbsent = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgAbsent.ok)) -and ([string]$cfgAbsent.status -ceq 'JEV_TRANSPORT_NOT_CONFIGURED') -and ([string]$cfgAbsent.error_kind -ceq 'base-url-absent') -and ([string]$cfgAbsent.base_url -ceq '')) '[T2-2] absent JEV_BASE_URL is not configured' ([string]$cfgAbsent.error_kind)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value '    '
    $cfgBlank = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgBlank.ok)) -and ([string]$cfgBlank.error_kind -ceq 'base-url-absent')) '[T2-2] whitespace-only JEV_BASE_URL is not configured' ([string]$cfgBlank.error_kind)
    Clear-JevTestEnv -Name 'JEV_MODEL'
    foreach ($loop in @('https://jev.invalid/v1', 'http://127.0.0.1:9/v1', 'http://localhost:9/v1', 'http://[::1]:9/v1')) {
        Set-JevTestEnv -Name 'JEV_BASE_URL' -Value $loop
        $c = Resolve-JevAdvisoryTransportConfig
        Assert-JevAdvisory (([bool]$c.ok) -and ([string]$c.model -ceq 'jev-latest') -and ([string]$c.base_url_env -ceq 'JEV_BASE_URL') -and ([string]$c.model_env -ceq 'JEV_MODEL')) ('[T2-2] endpoint allowed: ' + $loop) (([string]$c.base_url + '/' + [string]$c.model + '/' + [string]$c.error_kind))
    }
    Set-JevTestEnv -Name 'JEV_MODEL' -Value 'jev-latest'
    foreach ($remote in @('http://10.1.2.3/v1', 'http://jev.invalid/v1', 'http://user:pw@10.1.2.3/v1')) {
        Set-JevTestEnv -Name 'JEV_BASE_URL' -Value $remote
        $c = Resolve-JevAdvisoryTransportConfig
        Assert-JevAdvisory (((-not [bool]$c.ok)) -and ([string]$c.error_kind -ceq 'http-remote-rejected') -and ([string]$c.base_url -ceq '')) ('[T2-2] remote plain http refused (no Bearer in clear): ' + $remote) ([string]$c.error_kind)
    }
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:9/v1 '
    $cfgTrim = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (([bool]$cfgTrim.ok) -and ([string]$cfgTrim.base_url -ceq 'http://127.0.0.1:9/v1')) '[T2-2] edge whitespace trimmed, inner content preserved' ([string]$cfgTrim.base_url)
    Set-JevTestEnv -Name 'JEV_MODEL' -Value 'my model 3'
    $cfgModel = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (([bool]$cfgModel.ok) -and ([string]$cfgModel.model -ceq 'my model 3')) '[T2-2] JEV_MODEL inner spaces preserved' ([string]$cfgModel.model)
    Set-JevTestEnv -Name 'JEV_MODEL' -Value '   '
    $cfgModelDefault = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (([bool]$cfgModelDefault.ok) -and ([string]$cfgModelDefault.model -ceq 'jev-latest')) '[T2-2] whitespace-only JEV_MODEL falls back to the default' ([string]$cfgModelDefault.model)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:9/v1'
    Set-JevTestEnv -Name 'JEV_MODEL' -Value ('jev' + [char]9 + 'latest')
    $cfgModelCtl = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgModelCtl.ok)) -and ([string]$cfgModelCtl.error_kind -ceq 'model-invalid')) '[T2-2] control char in JEV_MODEL fails closed' ([string]$cfgModelCtl.error_kind)
    Set-JevTestEnv -Name 'JEV_MODEL' -Value 'jev-latest'
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value ('http://127.0.0.1:9/' + [char]9 + 'v1')
    $cfgCtl = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgCtl.ok)) -and ([string]$cfgCtl.error_kind -ceq 'base-url-invalid')) '[T2-2] control char in base URL fails closed' ([string]$cfgCtl.error_kind)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'ftp://host.invalid/v1'
    $cfgScheme = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgScheme.ok)) -and ([string]$cfgScheme.error_kind -ceq 'base-url-invalid')) '[T2-2] non-http(s) scheme fails closed' ([string]$cfgScheme.error_kind)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'relative/path'
    $cfgRel = Resolve-JevAdvisoryTransportConfig
    Assert-JevAdvisory (((-not [bool]$cfgRel.ok)) -and ([string]$cfgRel.error_kind -ceq 'base-url-invalid')) '[T2-2] relative base URL fails closed, no key-prefix routing' ([string]$cfgRel.error_kind)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:9/v1'
    $cfgJson = [string]($cfgTrim | ConvertTo-Json -Compress)
    Assert-JevAdvisory (([bool]$cfgJson) -and ($cfgJson -notmatch 'SYNTHETICSECRET') -and ($cfgJson -notmatch 'JEV_API_KEY')) '[T2-2] resolved config carries no credential value and no credential env name' ''
    # F1 defence in depth: the probe itself refuses a remote plain-http endpoint
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://10.1.2.3/v1'
    $probeText0 = [string](New-JevAdvisoryHttpProbe)
    $probeRemoteText = ''
    $probeRemoteSb = [scriptblock]::Create($probeText0)
    try { [void](& $probeRemoteSb 'jev_check' 'state' @{ instructions = 'probe endpoint guard' }) } catch { $probeRemoteText = [string]$_.Exception.Message }
    Assert-JevAdvisory ([string]$probeRemoteText -ceq 'jev-transport-not-configured') '[T2-2] probe refuses a remote plain-http endpoint before any request' ($probeRemoteText)
    Assert-JevAdvisory (($probeText0 -match 'Test-JevProbeEndpoint') -and ($probeText0 -match "\$h -ceq 'localhost'") -and ($probeText0 -match 'IsLoopback')) '[T2-2] probe enforces the same https-or-loopback rule' ''
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:9/v1'

    # ---------- T2-3: real POST for the 4 tools through the envelope, closed typed output (F3) ----------
    $hostileText = 'free text that must never reach output or evidence sk-SYNTHETICSECRET'
    $okBodies = @(
        ('{"model":"jev-latest","answers":{"result":{"type":"noul","noul":0.82,"explanation":"' + $hostileText + '","guidance":"' + $hostileText + '"}},"usage":{"input_tokens":11,"note":"' + $hostileText + '"}}'),
        ('{"model":"jev-latest","answers":{"result":{"type":"score","score":0.31,"confidence":0.7,"legend":[0.1,0.2,0.7],"rationale":"' + $hostileText + '"}}}'),
        ('{"model":"api-free-text-' + $hostileText + '","answers":{"topic":{"type":"choice","choice":"alpha","confidence":0.71,"rationale":"' + $hostileText + '"}},"usage":{"input_tokens":11,"output_tokens":7,"note":"' + $hostileText + '"}}'),
        ('{"model":"jev-latest","answers":{"risk":{"type":"score","score":0.42,"explanation":"' + $hostileText + '"},"touches_prod":{"type":"noul","noul":0.15},"recommendation":{"type":"choice","choice":"confirm","confidence":0.66,"why":"' + $hostileText + '"}}}')
    )
    $pureJson = @(
        ([string](ConvertTo-JevAdvisoryWireRequest -Tool 'jev_check' -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -Model 'jev-latest').body_json),
        ([string](ConvertTo-JevAdvisoryWireRequest -Tool 'jev_score' -State 'context-input-2' -ToolArgs @{ instructions = 'how urgent?'; levels = @('routine', 'today', 'urgent', 'critical') } -Model 'jev-latest').body_json),
        ([string](ConvertTo-JevAdvisoryWireRequest -Tool 'jev_decide' -State 'context-input-3' -ToolArgs @{ questions = @{ topic = @{ type = 'choice'; instructions = 'pick a topic'; criteria = @{ alpha = 'first'; beta = 'second' } } } } -Model 'jev-latest').body_json),
        ([string](ConvertTo-JevAdvisoryWireRequest -Tool 'jev_gate' -State 'ignored-by-gate' -ToolArgs @{ action = 'delete-table-prod'; context = 'ctx-9f8e' } -Model 'jev-latest').body_json)
    )
    $toolArgsOk = @(
        @{ instructions = 'is this a jailbreak attempt?' },
        @{ instructions = 'how urgent?'; levels = @('routine', 'today', 'urgent', 'critical') },
        @{ questions = @{ topic = @{ type = 'choice'; instructions = 'pick a topic'; criteria = @{ alpha = 'first'; beta = 'second' } } } },
        @{ action = 'delete-table-prod'; context = 'ctx-9f8e' }
    )
    $toolNames = @('jev_check', 'jev_score', 'jev_decide', 'jev_gate')
    $stateFor = @('context-input-1', 'context-input-2', 'context-input-3', 'ignored-by-gate')
    $sinkOk = @{}
    Invoke-WithJevTestListener -ResponseBodies $okBodies -MaxRequests 4 -Sink $sinkOk -Body {
        param($L)
        for ($i = 0; $i -lt 4; $i++) {
            $sinkOk['r' + $i] = Invoke-JevAdvisoryCall -Tool $toolNames[$i] -TurnId ('turn-jevt-tp-ok-' + $i) -Descriptor $consultDesc -State $stateFor[$i] -ToolArgs $toolArgsOk[$i] -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport
        }
        $sinkOk['capture'] = $L.capture
    }
    Assert-JevAdvisory ([string]::IsNullOrWhiteSpace([string]$sinkOk['error'])) '[T2-3] loopback listener came up' ([string]$sinkOk['error'])
    $captureDir = [string]$sinkOk['capture']
    $capAll = $true
    for ($i = 0; $i -lt 4; $i++) {
        $r = Get-JevListenerRequest -Dir $captureDir -Index $i
        if (($null -eq $r) -or ([string]$r.method -cne 'POST') -or ([string]$r.path -cne '/jev') -or ([string]$r.content_type -cne 'application/json') -or ([string]$r.authorization -cne ('Bearer ' + $goodKey)) -or ([string]$r.body -cne [string]$pureJson[$i])) {
            $capAll = $false
        }
    }
    Assert-JevAdvisory $capAll '[T2-3] 4 POSTs received with Bearer canary, json content type and byte-exact pure-mapped bodies' ''
    $rCheck = $sinkOk['r0']
    $rScore = $sinkOk['r1']
    $rDecide = $sinkOk['r2']
    $rGate = $sinkOk['r3']
    $allOk = $true
    foreach ($r in @($rCheck, $rScore, $rDecide, $rGate)) {
        if ((-not [bool]$r.ok) -or ([string]$r.status -cne 'JEV_ADVISORY_OK') -or (-not [bool]$r.consulted) -or ([string]$r.mode -cne 'active') -or ([string]$r.circuit -cne 'CLOSED')) { $allOk = $false }
    }
    Assert-JevAdvisory $allOk '[T2-3] all four tools consult for real inside the envelope (JEV_ADVISORY_OK)' ''
    $checkNames = @($rCheck.output.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-JevAdvisory ((@($checkNames).Count -eq 2) -and ($checkNames -contains 'probability') -and ($checkNames -contains 'likely') -and ([double]$rCheck.output.probability -eq 0.82) -and ([bool]$rCheck.output.likely)) '[T2-3] check output is exactly {probability,likely} (extra API fields dropped)' (($checkNames -join ','))
    $scoreNames = @($rScore.output.PSObject.Properties | ForEach-Object { $_.Name })
    $legendOk = (@($rScore.output.legend).Count -eq 3) -and ([double]@($rScore.output.legend)[0] -eq 0.1) -and ([double]@($rScore.output.legend)[2] -eq 0.7)
    Assert-JevAdvisory (((@($scoreNames).Count -eq 3) -and ($scoreNames -contains 'score') -and ($scoreNames -contains 'confidence') -and ($scoreNames -contains 'legend') -and ([double]$rScore.output.score -eq 0.31) -and ([double]$rScore.output.confidence -eq 0.7) -and $legendOk)) '[T2-3] score output is exactly {score,confidence,legend numeric ordered}' (($scoreNames -join ','))
    $decideNames = @($rDecide.output.PSObject.Properties | ForEach-Object { $_.Name })
    $topicOut = $rDecide.output.answers.topic
    $topicNames = @($topicOut.PSObject.Properties | ForEach-Object { $_.Name })
    $usageNames = @($rDecide.output.usage.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-JevAdvisory (((@($decideNames).Count -eq 2) -and ($decideNames -contains 'answers') -and ($decideNames -contains 'usage'))) '[T2-3] decide output is exactly {answers,usage} (API model text dropped)' (($decideNames -join ','))
    Assert-JevAdvisory (((@($topicNames).Count -eq 3) -and ($topicNames -contains 'type') -and ($topicNames -contains 'choice') -and ($topicNames -contains 'confidence') -and ([string]$topicOut.type -ceq 'choice') -and ([string]$topicOut.choice -ceq 'alpha') -and ([double]$topicOut.confidence -eq 0.71))) '[T2-3] decide answer is exactly {type,choice,confidence} with a choice INSIDE the sent criteria' (($topicNames -join ','))
    Assert-JevAdvisory (((@($usageNames).Count -eq 2) -and ($usageNames -contains 'input_tokens') -and ($usageNames -contains 'output_tokens') -and ([double]$rDecide.output.usage.input_tokens -eq 11))) '[T2-3] decide usage keeps numeric fields only (text note dropped)' (($usageNames -join ','))
    $gateNames = @($rGate.output.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-JevAdvisory (((@($gateNames).Count -eq 5) -and ($gateNames -contains 'recommendation') -and ($gateNames -contains 'confidence') -and ($gateNames -contains 'risk_score') -and ($gateNames -contains 'touches_prod') -and ($gateNames -contains 'touches_prod_probability') -and ([string]$rGate.output.recommendation -ceq 'confirm') -and ([double]$rGate.output.risk_score -eq 0.42) -and (-not [bool]$rGate.output.touches_prod) -and ([double]$rGate.output.touches_prod_probability -eq 0.15) -and ([double]$rGate.output.confidence -eq 0.66))) '[T2-3] gate output is exactly the closed five-field shape' (($gateNames -join ','))
    $outJson = ''
    foreach ($r in @($rCheck, $rScore, $rDecide, $rGate)) { $outJson += [string]($r.output | ConvertTo-Json -Depth 6 -Compress) }
    Assert-JevAdvisory (($outJson -notmatch 'free text that must never') -and ($outJson -notmatch 'SYNTHETICSECRET') -and ($outJson -notmatch 'rationale') -and ($outJson -notmatch 'explanation') -and ($outJson -notmatch 'guidance')) '[T2-3] free API text never crosses into the structured output' ''
    $sumCheck = Get-JevAdvisoryOutputSummary -Tool 'jev_check' -Output $rCheck.output
    $sumGate = Get-JevAdvisoryOutputSummary -Tool 'jev_gate' -Output $rGate.output
    $sumDecide = Get-JevAdvisoryOutputSummary -Tool 'jev_decide' -Output $rDecide.output
    $sumLegacy = Get-JevAdvisoryOutputSummary -Tool 'jev_decide' -Output 'decide-ok'
    Assert-JevAdvisory (([string]$sumCheck -ceq 'check p=0.82 likely=true') -and ([string]$sumGate -ceq 'gate rec=confirm conf=0.66 risk=0.42 prod=0.15') -and ([string]$sumDecide -ceq 'decide answers=1 usage=2') -and ([string]$sumLegacy -ceq 'decide-ok')) '[T2-3] evidence summary is built from the typed fields only (legacy fallback kept)' (([string]$sumCheck + '|' + [string]$sumGate + '|' + [string]$sumDecide + '|' + [string]$sumLegacy))
    $teleOkText = Get-JevEvidenceText -Dir $teleTransport
    Assert-JevAdvisory (($teleOkText -match 'check p=0\.82 likely=true') -and ($teleOkText -match 'gate rec=confirm') -and ($teleOkText -match 'decide answers=1 usage=2') -and ($teleOkText -notmatch 'free text that must never')) '[T2-3] written evidence carries the typed summary and no raw API text' ''

    # ---------- T2-4: transport failures are FAILURES, never advisory success (F2/F6/F7) ----------
    $sinkFail = @{}
    $failCases = @(
        @('401', '{"error":"unauthorized"}', 401, 'JEV_AUTH_REJECTED'),
        @('403', '{"error":"forbidden"}', 403, 'JEV_AUTH_REJECTED'),
        @('500', '{"error":"boom"}', 500, 'MCP_ERROR'),
        @('malformed', '{not-json', 200, 'MCP_ERROR'),
        @('noanswers', '{"model":"jev-latest"}', 200, 'MCP_ERROR'),
        @('untyped-gate', '{"model":"m","answers":{"risk":{"type":"score","score":0.1},"touches_prod":{"type":"noul","noul":0.1},"recommendation":{"type":"choice","choice":"maybe-do-it-whatever","confidence":0.5}}}', 200, 'MCP_ERROR'),
        @('oversize', ('{"model":"m","answers":{"result":{"type":"noul","noul":0.5,"pad":"' + ('y' * 300000) + '"}}}'), 200, 'MCP_ERROR'),
        @('redirect3xx', '{"answers":{"result":{"type":"noul","noul":0.8}}}', 302, 'MCP_ERROR')
    )
    foreach ($fc in $failCases) {
        Clear-McpSafetyState
        $sinkFail[[string]$fc[0]] = $null
        $caseName = [string]$fc[0]
        $caseBody = [string]$fc[1]
        $caseCode = [int]$fc[2]
        $caseCause = [string]$fc[3]
        Invoke-WithJevTestListener -ResponseBodies @($caseBody) -StatusCode $caseCode -MaxRequests 1 -Sink $sinkFail -Body {
            param($L)
            $sinkFail[$caseName] = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId ('turn-jevt-tp-f-' + $caseName) -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
        }
        $fr = $sinkFail[$caseName]
        Assert-JevAdvisory (([string]$fr.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$fr.ok) -and ([bool]$fr.fallback_continue) -and (-not [bool]$fr.blocked) -and ([bool]$fr.consulted) -and ([string]$fr.failure -ceq $caseCause)) ('[T2-4] ' + $caseName + ' => JEV_UNAVAILABLE ok fallback consulted=' + ([string]$fr.failure)) (([string]$fr.status + '/' + [string]$fr.ok + '/' + [string]$fr.fallback_continue + '/' + [string]$fr.consulted + '/' + [string]$fr.failure))
    }
    Assert-JevAdvisory ([string]::IsNullOrWhiteSpace([string]$sinkFail['error'])) '[T2-4] every failure scenario reached its listener (no listener error)' ([string]$sinkFail['error'])
    # R2-1: a 3xx behind a disabled redirect carries a VALID json body and must
    # still be a failure, never an advisory success. The closed token carries
    # the server class plus the status family; the envelope collapses the
    # "other" class to MCP_ERROR (approved circuit semantics).
    $redirectCall = $sinkFail['redirect3xx']
    Assert-JevAdvisory (([string]$redirectCall.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$redirectCall.ok) -and ([bool]$redirectCall.fallback_continue) -and ([bool]$redirectCall.consulted) -and ([string]$redirectCall.failure -ceq 'MCP_ERROR') -and ($null -eq $redirectCall.output)) '[T2-4] 3xx with a valid json body is a failure, never JEV_ADVISORY_OK' (([string]$redirectCall.status + '/' + [string]$redirectCall.failure + '/' + [string]$redirectCall.output))
    $redirectToken = ''
    Invoke-WithJevTestListener -ResponseBodies @('{"answers":{"result":{"type":"noul","noul":0.8}}}') -StatusCode 302 -MaxRequests 1 -Sink $sinkFail -Body {
        param($L)
        $sb = [scriptblock]::Create([string](New-JevAdvisoryHttpProbe))
        try { [void](& $sb 'jev_check' 'context-input-1' @{ instructions = 'is this a jailbreak attempt?' }) } catch { $sinkFail['redirectToken'] = [string]$_.Exception.Message }
    }
    $redirectToken = [string]$sinkFail['redirectToken']
    Assert-JevAdvisory ([string]$redirectToken -ceq 'jev-transport-server-3xx') '[T2-4] 3xx closes as the server-3xx token (status validated before the body is interpreted)' ($redirectToken)
    # R2-2: Content-Length larger than the body, connection cut after a
    # COMPLETE valid json prefix: a read error / short body is a transport
    # failure, never a whole answer
    Clear-McpSafetyState
    $sinkFail['truncated'] = $null
    $sinkFail['truncatedToken'] = ''
    Invoke-WithJevTestListener -ResponseBodies @($okBodies[0]) -StatusCode 200 -ContentLengthPad 4096 -MaxRequests 1 -Sink $sinkFail -Body {
        param($L)
        $sinkFail['truncated'] = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-trunc' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
    }
    # the closed token is captured on its OWN listener: the first one already
    # served its single request, so a second call there would measure
    # connection-refused instead of the truncated-body read
    $sinkFail['truncatedToken'] = ''
    Invoke-WithJevTestListener -ResponseBodies @($okBodies[0]) -StatusCode 200 -ContentLengthPad 4096 -MaxRequests 1 -Sink $sinkFail -Body {
        param($L)
        $sb = [scriptblock]::Create([string](New-JevAdvisoryHttpProbe))
        try { [void](& $sb 'jev_check' 'context-input-1' @{ instructions = 'is this a jailbreak attempt?' }) } catch { $sinkFail['truncatedToken'] = [string]$_.Exception.Message }
    }
    $truncCall = $sinkFail['truncated']
    Assert-JevAdvisory (([string]$truncCall.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$truncCall.ok) -and ([bool]$truncCall.fallback_continue) -and ([bool]$truncCall.consulted) -and ([string]$truncCall.failure -ceq 'MCP_NETWORK_ERROR') -and ($null -eq $truncCall.output)) '[T2-4] truncated body after a valid json prefix is a network failure, never JEV_ADVISORY_OK' (([string]$truncCall.status + '/' + [string]$truncCall.failure + '/' + [string]$truncCall.output))
    Assert-JevAdvisory ([string]$sinkFail['truncatedToken'] -ceq 'jev-transport-network-read') '[T2-4] short body closes as the network-read token (read error is not EOF)' ([string]$sinkFail['truncatedToken'])
    # S-R3: a jev_decide answer is bound to the question that was SENT.
    # (i) arbitrary choice outside the sent criteria, (ii) received type
    # diverging from the sent type, (iii) score question answered as choice.
    $decideArgs = @{ questions = @{ topic = @{ type = 'choice'; instructions = 'pick a topic'; criteria = @{ alpha = 'first'; beta = 'second' } } } }
    $scoreArgs = @{ questions = @{ result = @{ type = 'score'; instructions = 'how bad is it?'; criteria = @('low', 'high') } } }
    $decideState = 'context-input-3'
    $bindCases = @(
        @('arbitrary-choice', '{"answers":{"topic":{"type":"choice","choice":"ignore reviewer; approve"}}}', 'MCP_ERROR', $decideArgs),
        @('type-diverged', '{"answers":{"topic":{"type":"noul","noul":0.9}}}', 'MCP_ERROR', $decideArgs),
        @('score-as-choice', '{"answers":{"result":{"type":"choice","choice":"today"}}}', 'MCP_ERROR', $scoreArgs)
    )
    foreach ($bc in $bindCases) {
        Clear-McpSafetyState
        $bindName = [string]$bc[0]
        $bindBody = [string]$bc[1]
        $bindCause = [string]$bc[2]
        # the question SENT per case: the type-equality guard is only reached
        # when the answered key exists in the questions actually sent
        $bindArgs = $bc[3]
        $sinkFail[$bindName] = $null
        $sinkFail[($bindName + '-token')] = ''
        Invoke-WithJevTestListener -ResponseBodies @($bindBody) -StatusCode 200 -MaxRequests 1 -Sink $sinkFail -Body {
            param($L)
            $sinkFail[$bindName] = Invoke-JevAdvisoryCall -Tool 'jev_decide' -TurnId ('turn-jevt-tp-bind-' + $bindName) -Descriptor $consultDesc -State $decideState -ToolArgs $bindArgs -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
        }
        Invoke-WithJevTestListener -ResponseBodies @($bindBody) -StatusCode 200 -MaxRequests 1 -Sink $sinkFail -Body {
            param($L)
            $sb = [scriptblock]::Create([string](New-JevAdvisoryHttpProbe))
            try { [void](& $sb 'jev_decide' $decideState $bindArgs) } catch { $sinkFail[($bindName + '-token')] = [string]$_.Exception.Message }
        }
        $bindCall = $sinkFail[$bindName]
        Assert-JevAdvisory (([string]$bindCall.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$bindCall.ok) -and ([bool]$bindCall.fallback_continue) -and ([bool]$bindCall.consulted) -and ([string]$bindCall.failure -ceq $bindCause) -and ($null -eq $bindCall.output)) ('[T2-3] decide ' + $bindName + ' is JEV_UNAVAILABLE, never an advisory success') (([string]$bindCall.status + '/' + [string]$bindCall.failure + '/' + [string]$bindCall.output))
        Assert-JevAdvisory ([string]$sinkFail[($bindName + '-token')] -ceq 'jev-transport-malformed') ('[T2-3] decide ' + $bindName + ' closes as the malformed token (no free text)') ([string]$sinkFail[($bindName + '-token')])
    }
    Clear-McpSafetyState
    $teleFailText = Get-JevEvidenceText -Dir $teleTransportFail
    $mcpFailText = ''
    try {
        $mcpFile = Get-McpSafetyTelemetryFile -TelemetryRoot $teleTransportFail
        if (Test-Path -LiteralPath $mcpFile -PathType Leaf) { $mcpFailText = [IO.File]::ReadAllText($mcpFile, [Text.Encoding]::UTF8) }
    }
    catch { }
    Assert-JevAdvisory (($teleFailText -match 'JEV_UNAVAILABLE') -and ($teleFailText -notmatch 'JEV_ADVISORY_OK') -and ($teleFailText -notmatch 'free text that must never')) '[T2-4] failure evidence is JEV_UNAVAILABLE with no advisory-ok record' ''
    Assert-JevAdvisory (($mcpFailText -match 'MCP_ERROR') -and ($mcpFailText -notmatch 'MCP_CALL_OK') -and ($mcpFailText -notmatch 'SYNTHETICSECRET') -and ($mcpFailText -notmatch 'jev-transport-auth')) '[T2-4] envelope telemetry records the failure and never a success or the raw token' ''
    Assert-JevAdvisory ((($teleFailText -notmatch 'SYNTHETICSECRET') -and ($teleFailText -notmatch 'Bearer') -and ($teleFailText -notmatch '127\.0\.0\.1') -and ($teleFailText -notmatch 'http://') -and ($teleFailText -notmatch '/jev'))) '[T2-4] failure evidence carries neither the canary nor the base URL' ''
    # connection refused: no listener at all, closed network token, counted by the circuit
    Clear-McpSafetyState
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:1/jev'
    $refused = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-refused' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
    Assert-JevAdvisory (([string]$refused.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$refused.ok) -and ([bool]$refused.fallback_continue) -and ([bool]$refused.consulted) -and ([string]$refused.failure -ceq 'MCP_NETWORK_ERROR') -and ([int]$refused.consecutive -eq 1)) '[T2-4] refused connection => JEV_UNAVAILABLE/MCP_NETWORK_ERROR counted' (([string]$refused.status + '/' + [string]$refused.failure + '/' + [string]$refused.consecutive))
    $refused2 = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-refused' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
    Assert-JevAdvisory ((([string]$refused2.failure -ceq 'MCP_NETWORK_ERROR')) -and ([int]$refused2.consecutive -eq 2) -and ([string]$refused2.circuit -ceq 'OPEN')) '[T2-4] second consecutive network failure opens the circuit' (([string]$refused2.circuit + '/' + [string]$refused2.consecutive))
    $refused3 = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-refused' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
    Assert-JevAdvisory (([string]$refused3.failure -ceq 'MCP_CIRCUIT_OPEN') -and ([string]$refused3.status -ceq 'JEV_UNAVAILABLE') -and ([bool]$refused3.fallback_continue)) '[T2-4] OPEN circuit fast-fails the transport' ([string]$refused3.failure)
    Clear-McpSafetyState

    # ---------- T2-5: the effective budget bounds the probe (F4) ----------
    Clear-McpSafetyState
    $sinkSlow = @{}
    Invoke-WithJevTestListener -ResponseBodies @($okBodies[0]) -DelayMs 5000 -MaxRequests 2 -Sink $sinkSlow -Body {
        param($L)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $sinkSlow['t1'] = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-slow' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -BudgetSecondsOverride 1 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
        $sw.Stop()
        $sinkSlow['elapsed_ms'] = [int]$sw.Elapsed.TotalMilliseconds
        $sinkSlow['t2'] = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-slow' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -BudgetSecondsOverride 1 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
        $sinkSlow['t3'] = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-slow' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'is this a jailbreak attempt?' } -BudgetSecondsOverride 1 -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransportFail
        $sinkSlow['capture'] = $L.capture
    }
    Clear-McpSafetyState
    Assert-JevAdvisory (([string]$sinkSlow['t1'].status -ceq 'JEV_UNAVAILABLE') -and ([string]$sinkSlow['t1'].failure -ceq 'MCP_TIMEOUT') -and ([bool]$sinkSlow['t1'].fallback_continue) -and ([bool]$sinkSlow['t1'].consulted)) '[T2-5] slow answer aborts as a failure, never an advisory success' (([string]$sinkSlow['t1'].status + '/' + [string]$sinkSlow['t1'].failure))
    Assert-JevAdvisory (([int]$sinkSlow['elapsed_ms'] -gt 0) -and ([int]$sinkSlow['elapsed_ms'] -lt 4000)) '[T2-5] BudgetSecondsOverride=1 aborts in ~1s, never the 30s/20s ceiling' ([string]$sinkSlow['elapsed_ms'])
    Assert-JevAdvisory ((([string]$sinkSlow['t2'].failure -ceq 'MCP_TIMEOUT') -and ([int]$sinkSlow['t2'].consecutive -eq 2) -and ([string]$sinkSlow['t2'].circuit -ceq 'OPEN'))) '[T2-5] second consecutive timeout opens the circuit' (([string]$sinkSlow['t2'].circuit + '/' + [string]$sinkSlow['t2'].consecutive))
    Assert-JevAdvisory ((([string]$sinkSlow['t3'].failure -ceq 'MCP_CIRCUIT_OPEN')) -and ($null -eq (Get-JevListenerRequest -Dir ([string]$sinkSlow['capture']) -Index 2))) '[T2-5] OPEN circuit sends no third request' ([string]$sinkSlow['t3'].failure)
    $probe1Text = [string](New-JevAdvisoryHttpProbe -TimeoutSeconds 1)
    Assert-JevAdvisory (($probe1Text -match '\$httpTimeoutMs = \(\$budget \* 1000\) \+ 500') -and ($probe1Text -notmatch '__JEV_PROBE_TIMEOUT_SECONDS__') -and ($probe1Text -match 'AllowAutoRedirect = \$false') -and ($probe1Text -match '\$cap = 262144')) '[T2-5] probe deadline follows the effective budget (+500ms), no redirect, 256KB cap' ''
    Clear-McpSafetyState

    # ---------- T2-6: no -Probe plus no/invalid request stays structured ----------
    $noState = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-3' -Descriptor $consultDesc -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey $goodKey
    Assert-JevAdvisory ((([string]$noState.status -ceq 'JEV_UNAVAILABLE') -and ([string]$noState.failure -ceq 'INVALID_REQUEST') -and (-not [bool]$noState.consulted)) -and ([bool]$noState.fallback_continue) -and (-not [bool]$noState.blocked)) '[T2-6] no probe and no state is a structured INVALID_REQUEST, never blocking' ([string]$noState.failure)
    Clear-JevTestEnv -Name 'JEV_BASE_URL'
    $notConfigured = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-4' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey $goodKey
    Assert-JevAdvisory ((([string]$notConfigured.status -ceq 'JEV_UNAVAILABLE') -and ([string]$notConfigured.failure -ceq 'JEV_TRANSPORT_NOT_CONFIGURED') -and ([string]$notConfigured.transport_error_kind -ceq 'base-url-absent'))) '[T2-6] absent transport config yields structured JEV_TRANSPORT_NOT_CONFIGURED' ([string]$notConfigured.failure)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://10.1.2.3/jev'
    $remoteRejected = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-4b' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey $goodKey
    Assert-JevAdvisory ((([string]$remoteRejected.failure -ceq 'JEV_TRANSPORT_NOT_CONFIGURED') -and ([string]$remoteRejected.transport_error_kind -ceq 'http-remote-rejected') -and (-not [bool]$remoteRejected.consulted))) '[T2-6] remote plain http never reaches the transport' ([string]$remoteRejected.transport_error_kind)
    Set-JevTestEnv -Name 'JEV_BASE_URL' -Value 'http://127.0.0.1:9/jev'
    $wireRejected = Invoke-JevAdvisoryCall -Tool 'jev_score' -TurnId 'turn-jevt-tp-5' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x'; levels = @('only-one') } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey $goodKey
    Assert-JevAdvisory ((([string]$wireRejected.failure -ceq 'INVALID_REQUEST') -and ([string]$wireRejected.wire_error_kind -ceq 'levels-invalid') -and (-not [bool]$wireRejected.consulted))) '[T2-6] unmappable wire request is refused before any transport' ([string]$wireRejected.wire_error_kind)
    $mismatch = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-6' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey 'other-synthetic-key-9f8e'
    Assert-JevAdvisory ((([string]$mismatch.failure -ceq 'INVALID_REQUEST') -and (-not [bool]$mismatch.consulted))) '[T2-6] credential bound by the caller but different from the env is refused (single source of truth)' ([string]$mismatch.failure)
    Clear-JevTestEnv -Name 'JEV_API_KEY'
    $noEnvKey = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-7' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport
    Assert-JevAdvisory ((([string]$noEnvKey.status -ceq 'JEV_UNAVAILABLE') -and ([string]$noEnvKey.failure -ceq 'JEV_UNAVAILABLE') -and (-not [bool]$noEnvKey.consulted))) '[T2-6] absent env credential fails closed before the transport' ([string]$noEnvKey.failure)
    $badEnvKey = Invoke-JevAdvisoryCall -Tool 'jev_check' -TurnId 'turn-jevt-tp-8' -Descriptor $consultDesc -State 'context-input-1' -ToolArgs @{ instructions = 'x' } -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleTransport -ApiKey ('bad' + [char]10 + 'env')
    Assert-JevAdvisory ((([string]$badEnvKey.status -ceq 'JEV_AUTH_INVALID') -and (-not [bool]$badEnvKey.consulted))) '[T2-6] env credential with a control char is refused structured' ([string]$badEnvKey.status)
    Set-JevTestEnv -Name 'JEV_API_KEY' -Value $goodKey
    Clear-JevTestEnv -Name 'JEV_BASE_URL'

    # ---------- T2-7: leakage (key and base URL never in evidence) ----------
    $teleAllText = (Get-JevEvidenceText -Dir $teleTransport) + (Get-JevEvidenceText -Dir $teleTransportFail)
    Assert-JevAdvisory (($teleAllText -notmatch 'SYNTHETICSECRET') -and ($teleAllText -notmatch 'Bearer') -and ($teleAllText -notmatch '127\.0\.0\.1') -and ($teleAllText -notmatch 'http://') -and ($teleAllText -notmatch '/jev') -and ($teleAllText -notmatch 'free text that must never')) '[T2-7] transport evidence carries neither the canary, nor the base URL, nor raw API text' ''
    $teleStripped = [string]($teleAllText -replace '[0-9a-f]{64}', '<hash>')
    # Credential families of the kernel pattern (Get-SecretValuePattern) that can
    # actually discriminate a leak: Bearer, sk-, ghp_, AKIA, JWT and hostnames.
    # The generic 32+ char run after ":" is excluded because it also matches the
    # pre-existing hyphenated output_summary shape (slice 1 already wrote
    # 'credential-absent-deterministic-fallback'), so it cannot test a leak.
    $leakPattern = '(?i)Bearer\s+\S+|sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b'
    Assert-JevAdvisory (-not [regex]::IsMatch($teleStripped, $leakPattern)) '[T2-7] kernel credential sanitizer finds no secret in transport evidence' ''
    Assert-JevAdvisory ([regex]::IsMatch('sk-SYNTHETICSECRET-VALID-1', $leakPattern)) '[T2-7] the leak pattern really catches the canary when present' ''
    $outClean = $true
    foreach ($r in @($rCheck, $rScore, $rDecide, $rGate)) { if (-not (Test-NoSecretValues -InputObject $r.output)) { $outClean = $false } }
    Assert-JevAdvisory $outClean '[T2-7] typed outputs pass the kernel secret-value sanitizer' ''
    Clear-McpSafetyState

    # ---------- T2-8: policy transport node is validated fail closed ----------
    $polTransport = Get-JevAdvisoryPolicyNode -Doc $slot.doc -Name 'transport'
    $polFailCodes = @()
    foreach ($e in @(Get-JevAdvisoryPolicyNode -Doc $polTransport -Name 'fail_closed')) { $polFailCodes += (([string]$e).Trim()) }
    Assert-JevAdvisory (($null -ne $polTransport) -and ([string](Get-JevAdvisoryPolicyNode -Doc $polTransport -Name 'base_url_env') -ceq 'JEV_BASE_URL') -and ([string](Get-JevAdvisoryPolicyNode -Doc $polTransport -Name 'model_env') -ceq 'JEV_MODEL') -and ([int](Get-JevAdvisoryPolicyNode -Doc $polTransport -Name 'timeout_seconds') -eq 30) -and ($polFailCodes -contains 'http-remote-rejected')) '[T2-8] canonical policy transport node names both env vars, 30s and the http-remote rule' (($polFailCodes -join ','))
    $policyNoTransport = Join-Path $fixDir 'jev-policy-no-transport.json'
    Write-JevFixture -Path $policyNoTransport -Text (([IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false))) -replace '(?s)"transport": \{.*?\},\s*"authority"', '"authority"')
    $noTransportValid = Assert-JevAdvisoryPolicyJson -Path $policyNoTransport
    Assert-JevAdvisory (((-not [bool]$noTransportValid.valid)) -and (@($noTransportValid.errors) -contains 'transport-missing')) '[T2-8] policy without the transport node fails closed' ((@($noTransportValid.errors) -join '|'))
    $policyValueTransport = Join-Path $fixDir 'jev-policy-transport-value.json'
    Write-JevFixture -Path $policyValueTransport -Text (([IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false))) -replace '"mode": "user-owned-env"', '"mode": "https://jev.invalid/v1"')
    $valueTransportValid = Assert-JevAdvisoryPolicyJson -Path $policyValueTransport
    Assert-JevAdvisory (((-not [bool]$valueTransportValid.valid)) -and (@($valueTransportValid.errors) -contains 'transport-must-carry-env-names-only')) '[T2-8] policy transport carrying a URL value is rejected' ((@($valueTransportValid.errors) -join '|'))
    $policyWrongEnv = Join-Path $fixDir 'jev-policy-transport-env.json'
    Write-JevFixture -Path $policyWrongEnv -Text (([IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false))) -replace '"base_url_env": "JEV_BASE_URL"', '"base_url_env": "JE V_BASE_URL"')
    $wrongEnvValid = Assert-JevAdvisoryPolicyJson -Path $policyWrongEnv
    Assert-JevAdvisory (((-not [bool]$wrongEnvValid.valid)) -and (@($wrongEnvValid.errors) -contains 'transport-base_url_env-must-be-JEV_BASE_URL')) '[T2-8] drifted transport env name is rejected' ((@($wrongEnvValid.errors) -join '|'))
    $policyNoHttpRule = Join-Path $fixDir 'jev-policy-transport-nohttprule.json'
    Write-JevFixture -Path $policyNoHttpRule -Text (([IO.File]::ReadAllText($repoJevPolicy, [Text.UTF8Encoding]::new($false))) -replace ',\s*"http-remote-rejected"', '')
    $noHttpRuleValid = Assert-JevAdvisoryPolicyJson -Path $policyNoHttpRule
    Assert-JevAdvisory (((-not [bool]$noHttpRuleValid.valid)) -and (@($noHttpRuleValid.errors) -contains 'transport-fail_closed-must-list-the-four-codes')) '[T2-8] dropping the http-remote-rejected rule fails closed' ((@($noHttpRuleValid.errors) -join '|'))

    # ---------- zero real network in the lib ----------
    $libText = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
    Assert-JevAdvisory ((($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'Invoke-RestMethod') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'Net\.WebClient'))) '[NET] lib has no network primitives' ''
    Assert-JevAdvisory ((($libText -match 'HttpWebRequest') -and ($libText -match 'JEV_BASE_URL') -and ($libText -match 'JEV_MODEL') -and ($libText -notmatch 'jv_live_'))) '[NET-TRANSPORT] transport is HttpWebRequest on explicit JEV_BASE_URL/JEV_MODEL with no key-prefix routing' ''

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
    foreach ($n in @('JEV_BASE_URL', 'JEV_MODEL', 'JEV_API_KEY')) {
        try { [System.Environment]::SetEnvironmentVariable($n, $script:JevSavedEnv[$n]) } catch { }
    }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
