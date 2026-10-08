<#!
.SYNOPSIS
    Tests for lib/OrchestrationDecisionWiring.ps1 (PR-4).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for telemetry and flag
    fixtures, cleanup in finally. Bracketed output the runner parses.
    Exit 0 on all pass, exit 1 on any fail or unexpected exception.
    PS 5.1 compatible. ASCII-only. Zero real network: the Jev
    transport is always the synthetic caller-supplied scriptblock
    seam (a null probe means Jev unavailable); the built-in HTTP
    transport is never exercised here (exact-binary-live is a
    declared PR-4 pendency, operator-owned).
    Covers PR-4 acceptance 1: eligible routing consults through the
    single advisory path with DecisionProvider shapes preserved;
    Jev down falls back safe; overreach (grant/DONE) discarded;
    outside the closed tool set means no consult; nothing here ever
    grants, writes DONE, verifies, or blocks the Objective.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDecisionProvider.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDecisionWiring.ps1')

$script:passed = 0
$script:failed = 0

function Assert-DecisionWiring {
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

function Test-DWEnvelopeKeys {
    param($Env)
    $want = @('question_id', 'question_type', 'decision', 'source',
        'confidence', 'alternatives_considered', 'fallback_used', 'blocked', 'reason')
    foreach ($k in @($want)) {
        $found = $false
        try {
            if ($Env -is [System.Collections.IDictionary]) { $found = $Env.Contains($k) }
            else {
                $p = $Env.PSObject.Properties | Where-Object { $_.Name -ceq $k } | Select-Object -First 1
                $found = ($null -ne $p)
            }
        }
        catch { $found = $false }
        if (-not $found) { return $false }
    }
    return $true
}

function Write-DWFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

try {
    $v3 = Split-Path -Parent $PSScriptRoot
    $repo = Split-Path -Parent (Split-Path -Parent $v3)
    $repoJevPolicy = Join-Path $repo 'source\registry\jev-advisory-policy.json'
    $repoMcpPolicy = Join-Path $repo 'source\registry\mcp-request-policy.json'

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-decisionwiring-' + [guid]::NewGuid().ToString('N'))
    $teleRoot = Join-Path $tempRoot 'evidence'
    $fixDir = Join-Path $tempRoot 'fixtures'
    New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $fixDir -Force | Out-Null
    $activeFlags = Join-Path $fixDir 'flags-active.json'
    Write-DWFixture -Path $activeFlags -Text '{"jev_advisory": {"enabled": true, "shadow": false}}'

    $goodKey = 'sk-SYNTHETICSECRET-VALID-1'
    $state2 = @{ goal = 'pick-one'; evidence = 'two-clean-options' }
    $consultDesc = @{ route_uncertain = $true }
    $okProbe = { param($ctx) return @{ decision = 'opt-b'; confidence = 0.8; advice = 'clean-pick-advice' } }
    $grantProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'grant permission now widen scope write done' } }
    $doneProbe = { param($ctx) return @{ decision = 'opt-b'; confidence = 0.95; advice = 'write done and bypass reviewer approval' } }
    $downProbe = { param($ctx) throw 'simulated-jev-down' }

    try {
        Clear-McpSafetyState
        Clear-JevAdvisoryState

        # ---------- version / contract ----------
        $v = Get-OrchestrationDecisionWiringVersion
        Assert-DecisionWiring (([int]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR-4') -and ([int]$v.budget_seconds -eq 30)) '[W0] wiring version schema 1 phase PR-4 budget 30s' ''

        # ---------- tool mapping: closed question set, unknown => none ----------
        Assert-DecisionWiring ((Get-OrchestrationDecisionWiringTool -QuestionType 'routing') -ceq 'jev_decide') '[W1] routing maps to jev_decide' ''
        Assert-DecisionWiring ((Get-OrchestrationDecisionWiringTool -QuestionType 'continue') -ceq 'jev_gate') '[W1] continue maps to jev_gate' ''
        Assert-DecisionWiring ((Get-OrchestrationDecisionWiringTool -QuestionType 'risk') -ceq 'jev_score') '[W1] risk maps to jev_score' ''
        Assert-DecisionWiring ((Get-OrchestrationDecisionWiringTool -QuestionType 'evidence') -ceq 'jev_check') '[W1] evidence maps to jev_check' ''
        Assert-DecisionWiring ([string]::IsNullOrWhiteSpace((Get-OrchestrationDecisionWiringTool -QuestionType 'architecture'))) '[W1] outside toolset maps to empty (no consult)' ''

        # ---------- T1: eligible routing consults, shapes preserved ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q1' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-1' -Descriptor $consultDesc -JevProbe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (Test-DWEnvelopeKeys $r) '[T1] DecisionProvider shape preserved (9 keys)' ''
        Assert-DecisionWiring (([string]$r.source -ceq 'jev') -and ([string]$r.decision -ceq 'opt-b') -and ([bool]$r.consulted) -and ([string]$r.transport -ceq 'jev-advisory')) '[T1] eligible routing consults via jev-advisory' ([string]$r.source + '/' + [string]$r.decision + '/' + [string]$r.transport)
        Assert-DecisionWiring (([int]$r.budget_s -eq 30) -and ($r.blocked -eq $false)) '[T1] budget 30s surfaced, never blocks' ([string]$r.budget_s)
        Assert-DecisionWiring (((-not [bool]$r.grants_authority) -and (-not [bool]$r.done_approved) -and (-not [bool]$r.verified_pass) -and ([bool]$r.planner_decides))) '[T1] Jev grants nothing, verifies nothing, Planner decides' ''

        # ---------- T2: Jev down => safe fallback ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q2' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-2' -Descriptor $consultDesc -JevProbe $downProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ([bool]$r.fallback_used) -and ($r.blocked -eq $false) -and ([string]$r.decision -ceq '')) '[T2] Jev down falls back safe, never blocks' ([string]$r.source + '/' + [string]$r.reason)
        Assert-DecisionWiring (((-not [bool]$r.grants_authority) -and (-not [bool]$r.done_approved) -and (-not [bool]$r.verified_pass))) '[T2] fallback claims no authority' ''

        # ---------- T3: overreach (grant/DONE) discarded ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q3' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-3' -Descriptor $consultDesc -JevProbe $grantProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ([string]$r.reason -ceq 'jev-overreach-discarded') -and ($r.blocked -eq $false)) '[T3] grant overreach discarded to escalation' ([string]$r.source + '/' + [string]$r.reason)
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q3b' -QuestionType 'specialist' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-3b' -Descriptor $consultDesc -JevProbe $doneProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ($r.blocked -eq $false) -and ([string]$r.decision -ceq '')) '[T3b] DONE overreach discarded, empty decision' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- T3c: structured authority overreach in fields (not just text) discarded ----------
        Clear-McpSafetyState
        $structProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'clean pick'; grants_authority = $true } }
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q3c' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-3c' -Descriptor $consultDesc -JevProbe $structProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ($r.blocked -eq $false) -and ([string]$r.decision -ceq '') -and ([string]$r.reason -ceq 'jev-overreach-discarded')) '[T3c] structured grants_authority field discarded before projection' ([string]$r.source + '/' + [string]$r.reason)
        Clear-McpSafetyState
        $doneFieldProbe = { param($ctx) return @{ decision = 'opt-a'; confidence = 0.9; advice = 'clean pick'; done_approved = $true; verified_pass = $true } }
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q3d' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-3d' -Descriptor $consultDesc -JevProbe $doneFieldProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ($r.blocked -eq $false) -and ([string]$r.decision -ceq '')) '[T3d] structured done/verified fields discarded before projection' ([string]$r.source + '/' + [string]$r.reason)
        Assert-DecisionWiring (((-not [bool]$r.grants_authority) -and (-not [bool]$r.done_approved) -and (-not [bool]$r.verified_pass))) '[T3d] structured overreach grants nothing' ''

        # ---------- T4: outside closed tool set => no consult ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q4' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-4' -Descriptor $consultDesc -Tool 'jev_evil' -JevProbe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (((-not [bool]$r.consulted) -and ([string]$r.source -ceq 'planner-escalation') -and ($r.blocked -eq $false))) '[T4] tool outside closed set never consults' ([string]$r.source + '/' + [string]$r.reason)
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q4b' -QuestionType 'architecture' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-4b' -Descriptor $consultDesc -JevProbe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (((-not [bool]$r.consulted) -and ($r.blocked -eq $false))) '[T4b] question outside toolset never consults, never blocks' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- T5: high risk => planner escalation, never Jev ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q5' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'high' -TurnId 'turn-dw-5' -Descriptor $consultDesc -JevProbe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.reason -ceq 'high-risk-no-jev') -and ($r.blocked -eq $false)) '[T5] high risk escalates without Jev' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- T6: invalid TurnId => no consult, safe fallback ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q6' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'BAD TURN!!' -Descriptor $consultDesc -JevProbe $okProbe -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (((-not [bool]$r.consulted) -and ($r.blocked -eq $false) -and ([string]$r.source -ceq 'planner-escalation'))) '[T6] invalid TurnId never consults, safe fallback' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- T7: invalid policy fails closed ----------
        Clear-McpSafetyState
        $badPolicy = Join-Path $fixDir 'policy-bad.json'
        Write-DWFixture -Path $badPolicy -Text '{"version": 999}'
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q7' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-7' -Descriptor $consultDesc -JevProbe $okProbe -PolicyPath $badPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey $goodKey
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ($r.blocked -eq $false) -and ([string]$r.decision -ceq '')) '[T7] drifted policy fails closed to escalation' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- T8: Jev unavailable (null probe, no transport env) => fallback ----------
        Clear-McpSafetyState
        $r = Invoke-OrchestrationDecisionWiring -QuestionId 'dw-q8' -QuestionType 'routing' -Alternatives @('opt-a', 'opt-b') -State $state2 -Risk 'low' -TurnId 'turn-dw-8' -Descriptor $consultDesc -JevProbe $null -PolicyPath $repoJevPolicy -FlagsPath $activeFlags -McpPolicyPath $repoMcpPolicy -TelemetryRoot $teleRoot -ApiKey ''
        Assert-DecisionWiring (([string]$r.source -ceq 'planner-escalation') -and ([bool]$r.fallback_used) -and ($r.blocked -eq $false)) '[T8] Jev unavailable falls back safe' ([string]$r.source + '/' + [string]$r.reason)

        # ---------- hygiene: no network primitives, no secrets, ASCII-only ----------
        $wiringPath = Join-Path $PSScriptRoot 'OrchestrationDecisionWiring.ps1'
        $wiringText = [IO.File]::ReadAllText($wiringPath, [Text.UTF8Encoding]::new($false))
        Assert-DecisionWiring ((($wiringText -notmatch 'Invoke-WebRequest') -and ($wiringText -notmatch 'Invoke-RestMethod') -and ($wiringText -notmatch 'HttpClient') -and ($wiringText -notmatch 'Net\.WebClient') -and ($wiringText -notmatch 'HttpWebRequest') -and ($wiringText -notmatch 'Start-Process'))) '[NET] wiring delegates transport, owns no network/spawn' ''
        Assert-DecisionWiring (($wiringText -notmatch '(?i)sk-[A-Za-z0-9]')) '[SEC] wiring carries no secret value' ''
        Assert-DecisionWiring (($wiringText -notmatch 'JEV_API_KEY') -and ($wiringText -notmatch 'JEV_BASE_URL') -and ($wiringText -notmatch 'JEV_MODEL')) '[SEC] credential/env names owned by advisory lib, not wiring' ''
        foreach ($p in @($wiringPath, (Join-Path $PSScriptRoot 'OrchestrationDecisionWiring.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-DecisionWiring ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Clear-McpSafetyState } catch { }
        try { Clear-JevAdvisoryState } catch { }
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
