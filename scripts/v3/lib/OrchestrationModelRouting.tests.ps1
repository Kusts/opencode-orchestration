<#!
.SYNOPSIS
    Tests for lib/OrchestrationModelRouting.ps1 (PLAN-F1, issue #99).
.DESCRIPTION
    Hermetic: no network, no dispatch/loop/kernel/flag/policy mutation.
    Record-only: constructs, validates and envelopes ModelRouting
    request/result pairs; asserts zero dispatch effect separately via
    grep (see RETURN_FORMAT). Bracketed output the runner parses.
    Exit 0 on all pass, exit 1 on any fail or unexpected exception.
    PS 5.1 compatible. ASCII-only. Covers the 5 PLAN section 3 cases
    plus the invariants (deny/allowlist/quotas before override; HIGH
    without Planner denies; override skips consultation, never validation).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationModelRouting.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-ModelRouting {
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

function Test-ModelRoutingEnvelopeKeys {
    param($Env)
    $want = @('task_id', 'role', 'task_class', 'risk', 'selected', 'fallback',
        'reason', 'confidence', 'consulted_router', 'fallback_used', 'denied',
        'validation_errors', 'policy_refs', 'evidence_refs', 'escalation_consumed')
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

try {
    function New-ValidRequest {
        param([string]$Risk = 'LOW', [string]$Override = '')
        return (New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
            -Risk $Risk -Candidates @('cheap-a', 'cheap-b') -Fallback 'cheap-a' `
            -UserModelOverride $Override)
    }
    function New-ValidProposal {
        param([string]$Selected = 'cheap-b', [string]$Reason = 'BASELINE_SUFFICIENT', $Confidence = 0.8)
        return (New-ModelRoutingResult -Selected $Selected -Reason $Reason `
            -Confidence $Confidence -Fallback 'cheap-a' `
            -PolicyRefs @('opencode-v2.md:56-64') -EvidenceRefs @('NO_EVIDENCE_YET'))
    }

    # ---------- [C1] valid request -> envelope ok ----------
    $req = New-ValidRequest
    $prop = New-ValidProposal
    Assert-ModelRouting ([bool]$req.is_valid) '[C1a] valid request builds' ((@($req.validation_errors) -join ','))
    Assert-ModelRouting ([bool]$prop.is_valid) '[C1b] valid proposal builds' ((@($prop.validation_errors) -join ','))
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'BASELINE_SUFFICIENT') -and ($e.selected -ceq 'cheap-b') -and ([bool]$e.consulted_router) -and (-not [bool]$e.fallback_used) -and (-not [bool]$e.denied)) '[C1] valid pair accepted with consultation' ($e.reason + '/' + $e.selected)

    # ---------- [C2] override -> OVERRIDE_USER without consultation ----------
    $reqOv = New-ValidRequest -Override 'cheap-b'
    $e = Test-ModelRoutingEnvelope -Request $reqOv -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'OVERRIDE_USER') -and ($e.selected -ceq 'cheap-b') -and (-not [bool]$e.consulted_router) -and (-not [bool]$e.fallback_used)) '[C2] override short-circuits consultation' ($e.reason + '/' + $e.selected)

    # ---------- [C3] outside matrix -> candidate_out_of_envelope ----------
    $propOut = New-ValidProposal -Selected 'strong-z'
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $propOut
    Assert-ModelRouting (($e.reason -ceq 'candidate_out_of_envelope') -and ([bool]$e.denied) -and ([bool]$e.fallback_used) -and ($e.selected -ceq 'cheap-a')) '[C3] out-of-matrix pick refused to baseline' ($e.reason + '/' + $e.selected)

    # ---------- [C4] confidence < 0.5 -> deterministic fallback ----------
    $propLow = New-ValidProposal -Confidence 0.2
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $propLow
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used) -and ($e.selected -ceq 'cheap-a')) '[C4] low confidence falls back' ($e.reason + '/' + $e.selected)
    $propB = New-ModelRoutingResult -Selected 'cheap-b' -Reason 'BASELINE_SUFFICIENT' -Confidence 0.5 -Fallback 'cheap-a'
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $propB
    Assert-ModelRouting (($e.reason -ceq 'BASELINE_SUFFICIENT') -and ($e.selected -ceq 'cheap-b')) '[C4b] confidence boundary 0.5 accepted' ($e.reason + '/' + $e.selected)

    # ---------- [C5] HIGH/CRITICAL without Planner -> DENY_POLICY ----------
    $reqHigh = New-ValidRequest -Risk 'HIGH'
    $e = Test-ModelRoutingEnvelope -Request $reqHigh -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[C5] HIGH without Planner denied' ($e.reason)
    $reqCrit = New-ValidRequest -Risk 'CRITICAL' -Override 'cheap-b'
    $e = Test-ModelRoutingEnvelope -Request $reqCrit -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[C5b] CRITICAL override without Planner still denied' ($e.reason)
    $e = Test-ModelRoutingEnvelope -Request $reqHigh -Proposed $prop -PlannerApproved $true
    Assert-ModelRouting (($e.reason -ceq 'BASELINE_SUFFICIENT') -and (-not [bool]$e.denied)) '[C5c] HIGH with Planner approved proceeds' ($e.reason)

    # ---------- invariants: deny/allowlist/quotas BEFORE override ----------
    $reqDenyOv = New-ValidRequest -Override 'banned-x'
    $e = Test-ModelRoutingEnvelope -Request $reqDenyOv -Proposed $prop -DeniedModels @('banned-x')
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[I1] deny-list beats override' ($e.reason)
    $reqOutOv = New-ValidRequest -Override 'strong-z'
    $e = Test-ModelRoutingEnvelope -Request $reqOutOv -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[I2] out-of-envelope override denied (not just out-of-envelope)' ($e.reason)
    $reqPaidOv = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('cheap-a', 'paid-astra-x') -Fallback 'cheap-a' -UserModelOverride 'paid-astra-x'
    $e = Test-ModelRoutingEnvelope -Request $reqPaidOv -Proposed $prop -PaidAuthorized $false
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[I3] paid override without authorization denied' ($e.reason)
    $e = Test-ModelRoutingEnvelope -Request $reqPaidOv -Proposed $prop -PaidAuthorized $true
    Assert-ModelRouting (($e.reason -ceq 'OVERRIDE_USER') -and ($e.selected -ceq 'paid-astra-x')) '[I3b] paid override with authorization proceeds' ($e.reason + '/' + $e.selected)
    $e = Test-ModelRoutingEnvelope -Request $reqOv -Proposed $prop -QuotaExhausted $true
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[I4] quota-exhausted override denied' ($e.reason)

    # ---------- invariant: override skips consultation, never validation ----------
    $propLowOv = New-ValidProposal -Confidence 0.2
    $e = Test-ModelRoutingEnvelope -Request $reqOv -Proposed $propLowOv
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and (-not [bool]$e.consulted_router) -and ([bool]$e.fallback_used)) '[I5] low-confidence override still falls back, still unconsulted' ($e.reason)

    # ---------- malformed inputs never throw, always closed envelope ----------
    $badReq = New-ModelRoutingRequest -TaskId '' -Role 'nope' -TaskClass 'nope' -Risk 'nope' -Candidates @() -Fallback ''
    Assert-ModelRouting (-not [bool]$badReq.is_valid) '[M1] malformed request marked invalid' ''
    $e = Test-ModelRoutingEnvelope -Request $badReq -Proposed $prop
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used) -and (Test-ModelRoutingEnvelopeKeys -Env $e)) '[M2] invalid request yields closed fallback envelope' ($e.reason)
    $badProp = New-ModelRoutingResult -Selected 'cheap-b' -Reason 'NOPE' -Confidence 'alta' -Fallback ''
    Assert-ModelRouting (-not [bool]$badProp.is_valid) '[M3] malformed proposal marked invalid (strict confidence gate)' ((@($badProp.validation_errors) -join ','))
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $badProp
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and (Test-ModelRoutingEnvelopeKeys -Env $e)) '[M4] invalid proposal yields closed fallback envelope' ($e.reason)
    $eNull = Test-ModelRoutingEnvelope -Request $null -Proposed $null
    Assert-ModelRouting (($eNull.reason -ceq 'FALLBACK_DETERMINISTIC') -and (Test-ModelRoutingEnvelopeKeys -Env $eNull)) '[M5] null inputs yield closed fallback envelope' ($eNull.reason)

    # ---------- envelope shape on every path ----------
    $eOk = Test-ModelRoutingEnvelope -Request $req -Proposed $prop
    $eOv = Test-ModelRoutingEnvelope -Request $reqOv -Proposed $prop
    $eDeny = Test-ModelRoutingEnvelope -Request $reqHigh -Proposed $prop
    Assert-ModelRouting ((Test-ModelRoutingEnvelopeKeys -Env $eOk) -and (Test-ModelRoutingEnvelopeKeys -Env $eOv) -and (Test-ModelRoutingEnvelopeKeys -Env $eDeny)) '[S1] envelope carries all 15 keys on accept/override/deny' ''

    # ---------- REV-F1-LIB: fallback validated against the invariants ----------
    $reqFbBad = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('cheap-a', 'banned-x') -Fallback 'banned-x'
    Assert-ModelRouting ([bool]$reqFbBad.is_valid) '[F1a] request with denylisted fallback still builds (envelope decides)' ''
    $propFbBad = New-ValidProposal -Selected 'strong-z'
    $e = Test-ModelRoutingEnvelope -Request $reqFbBad -Proposed $propFbBad -DeniedModels @('banned-x')
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-deny-list-hit'))) '[F1b] prohibited fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $reqFbGhost = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('cheap-a', 'cheap-b') -Fallback 'ghost-model'
    $e = Test-ModelRoutingEnvelope -Request $reqFbGhost -Proposed $propFbBad
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-out-of-envelope'))) '[F1c] out-of-envelope fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $reqFbPaid = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('paid-astra-x', 'cheap-a') -Fallback 'paid-astra-x'
    $e = Test-ModelRoutingEnvelope -Request $reqFbPaid -Proposed (New-ValidProposal -Selected 'strong-z') -PaidAuthorized $false
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-paid-without-authorization'))) '[F1d] paid fallback without authorization yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $e = Test-ModelRoutingEnvelope -Request $req -Proposed $propOut -DeniedModels @('other-x')
    Assert-ModelRouting (($e.selected -ceq 'cheap-a') -and ([bool]$e.denied)) '[F1e] allowed fallback still selected on deny path' ($e.reason + '/' + $e.selected)
    $reqFbOut = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('permitido') -Fallback 'fora'
    Assert-ModelRouting ([bool]$reqFbOut.is_valid) '[F1f-setup] out-of-envelope fallback still builds (envelope decides)' ((@($reqFbOut.validation_errors) -join ','))
    $badPropOut = New-ModelRoutingResult -Selected 'x' -Reason 'NOPE' -Confidence 'alta' -Fallback ''
    Assert-ModelRouting (-not [bool]$badPropOut.is_valid) '[F1f-setup2] proposal malformed' ''
    $e = Test-ModelRoutingEnvelope -Request $reqFbOut -Proposed $badPropOut
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-out-of-envelope'))) '[F1f] valid request + invalid proposal + out-of-envelope fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $badReqOut = New-ModelRoutingRequest -TaskId '' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('permitido') -Fallback 'fora'
    Assert-ModelRouting (-not [bool]$badReqOut.is_valid) '[F1g-setup] invalid request with out-of-envelope fallback' ''
    $e = Test-ModelRoutingEnvelope -Request $badReqOut -Proposed $prop
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-out-of-envelope'))) '[F1g] invalid request + out-of-envelope fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))

    # ---------- REV-F1-LIB-R3: broken fallback blocks override/valid-pick returns ----------
    $reqOvFbBad = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('cheap-a', 'cheap-b') -Fallback 'ghost-model' -UserModelOverride 'cheap-b'
    $e = Test-ModelRoutingEnvelope -Request $reqOvFbBad -Proposed (New-ValidProposal)
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-out-of-envelope'))) '[F1h] valid override + out-of-envelope fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $reqFbGhostPlain = New-ModelRoutingRequest -TaskId 't-f1' -Role 'coder' -TaskClass 'implementation' `
        -Risk 'LOW' -Candidates @('cheap-a', 'cheap-b') -Fallback 'ghost-model'
    $e = Test-ModelRoutingEnvelope -Request $reqFbGhostPlain -Proposed (New-ValidProposal -Selected 'cheap-b')
    Assert-ModelRouting (([string]$e.selected -ceq '') -and ([bool]$e.denied) -and ((@($e.validation_errors) -contains 'fallback-out-of-envelope'))) '[F1i] valid non-empty pick + out-of-envelope fallback yields empty selection + explicit block' ((@($e.validation_errors) -join ','))
    $idxInternal = -1
    $catchWindow = ''
    try {
        $libTextF1 = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
        $idxInternal = $libTextF1.IndexOf('envelope-internal')
        if ($idxInternal -ge 0) {
            $from = [Math]::Max(0, ($idxInternal - 700))
            $len = [Math]::Min(1400, ($libTextF1.Length - $from))
            $catchWindow = $libTextF1.Substring($from, $len)
        }
    }
    catch { $catchWindow = '' }
    Assert-ModelRouting (($catchWindow -match 'denied\s+=\s+\$true') -and ($catchWindow -match 'envelope-internal')) '[F1j] catch envelope is fail-closed (denied=true)' ''

    # ---------- REV-F1-LIB: fail-closed boundary (is_valid never trusted) ----------
    $reqStrF = New-ValidRequest
    $reqStrF.is_valid = 'false'
    $e = Test-ModelRoutingEnvelope -Request $reqStrF -Proposed (New-ValidProposal)
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used)) '[F2a] is_valid string "false" does not validate' ($e.reason)
    $reqStrT = New-ValidRequest
    $reqStrT.is_valid = 'true'
    $e = Test-ModelRoutingEnvelope -Request $reqStrT -Proposed (New-ValidProposal)
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used)) '[F2b] is_valid string "true" does not validate either' ($e.reason)
    $reqHighS = New-ValidRequest -Risk 'HIGH'
    $e = Test-ModelRoutingEnvelope -Request $reqHighS -Proposed (New-ValidProposal) -PlannerApproved 'false'
    Assert-ModelRouting (($e.reason -ceq 'DENY_POLICY') -and ([bool]$e.denied)) '[F2c] PlannerApproved string "false" never approves HIGH' ($e.reason)
    $propHi = New-ValidProposal
    $propHi.confidence = 2.0
    $propHi.is_valid = $true
    $e = Test-ModelRoutingEnvelope -Request (New-ValidRequest) -Proposed $propHi
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used) -and ((@($e.validation_errors) -contains 'confidence-invalid'))) '[F2d] smuggled confidence >1 rejected at boundary' ((@($e.validation_errors) -join ','))
    $propNaN = New-ValidProposal
    $propNaN.confidence = [double]::NaN
    $propNaN.is_valid = $true
    $e = Test-ModelRoutingEnvelope -Request (New-ValidRequest) -Proposed $propNaN
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used)) '[F2e] smuggled NaN confidence rejected at boundary' ($e.reason)
    $propStrC = New-ValidProposal
    $propStrC.confidence = '0.9'
    $propStrC.is_valid = $true
    $e = Test-ModelRoutingEnvelope -Request (New-ValidRequest) -Proposed $propStrC
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used)) '[F2f] smuggled string confidence rejected at boundary' ($e.reason)
    $reqRiskU = New-ValidRequest
    $reqRiskU.risk = 'UNKNOWN'
    $reqRiskU.is_valid = $true
    $e = Test-ModelRoutingEnvelope -Request $reqRiskU -Proposed (New-ValidProposal)
    Assert-ModelRouting (($e.reason -ceq 'FALLBACK_DETERMINISTIC') -and ([bool]$e.fallback_used) -and ((@($e.validation_errors) -contains 'risk-unknown'))) '[F2g] unknown risk rejected at boundary' ((@($e.validation_errors) -join ','))
    $propEscS = New-ValidProposal
    $propEscS.escalation_consumed = 'false'
    $propEscS.is_valid = $true
    $e = Test-ModelRoutingEnvelope -Request (New-ValidRequest) -Proposed $propEscS -QuotaExhausted $true
    Assert-ModelRouting (($e.reason -ceq 'BASELINE_SUFFICIENT') -and (-not [bool]$e.denied)) '[F2h] escalation string "false" parses strict (no phantom quota deny)' ($e.reason)

    # ---------- hygiene: no network, no dispatch/config/flag touch, ASCII-only ----------
    $libText = [IO.File]::ReadAllText($libPath, [Text.UTF8Encoding]::new($false))
    Assert-ModelRouting ((($libText -notmatch 'Invoke-WebRequest') -and ($libText -notmatch 'Invoke-RestMethod') -and ($libText -notmatch 'HttpClient') -and ($libText -notmatch 'Net\.WebClient') -and ($libText -notmatch 'HttpWebRequest'))) '[NET] model-routing lib has no network primitives' ''
    Assert-ModelRouting ((($libText -notmatch 'New-OrchestrationNativeDispatchIntent') -and ($libText -notmatch 'Invoke-OrchestrationDispatchPipeline') -and ($libText -notmatch '(?m)^\s*\.\s+\S*Dispatch') -and ($libText -notmatch 'Set-Content') -and ($libText -notmatch 'Out-File') -and ($libText -notmatch 'Set-Orchestration'))) '[ISO] record-only: no dispatch read, no config write' ''
    Assert-ModelRouting (($libText -notmatch '(?m)^\$ErrorActionPreference')) '[SCOPE] no script-scope ErrorActionPreference on load (function-local only)' ''
    foreach ($p in @($libPath, $PSCommandPath)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-ModelRouting ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
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
