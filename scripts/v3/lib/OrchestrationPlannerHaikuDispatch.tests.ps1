<#
.SYNOPSIS
    Planner Haiku dispatch chain tests (hermetic, no provider calls, no inference).
.DESCRIPTION
    Covers Invoke-PlannerHaikuDispatch with isolated task store, temp git repo
    (verification policy with a passing profile), injected session-reader seam,
    fake capability probe and fake single-call dispatch executor:
      - happy path: Haiku selected, one dispatch, task/session/message/provider/
        model/tier correlation, UNKNOWN cost, model-attempt + worker result +
        kernel-executed verify-run recorded, pending independent review
      - exactly-once: second call with the same RunId refused, executor still
        one call total
      - pre-run unavailability: Luna fallback authorized and dispatched
      - timeout / ambiguous telemetry / override-unproven / model mismatch /
        missing plan: PROOF_ABSENT or fail-closed, never a retry or fallback
      - review trust boundary: producer self-approval refused, independent
        reviewer approval recorded
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationPlannerHaikuDispatch.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationPlannerHaikuDispatch.ps1')

$script:pass = 0
$script:fail = 0
function Assert-HD([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

function New-HdRoot {
    $outer = Join-Path ([IO.Path]::GetTempPath()) ('v3-hd-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path $outer 'repo'
    $tasks = Join-Path $outer 'tasks'
    $ledger = Join-Path $outer 'runs'
    $flags = Join-Path $outer 'flags.json'
    New-Item -ItemType Directory -Path $repo, $tasks, $ledger -Force | Out-Null
    [IO.File]::WriteAllText($flags, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    & git -C $repo init -b master *>$null
    if ($LASTEXITCODE -ne 0) { & git -C $repo init *>$null }
    & git -C $repo config user.email 'hd-test@example.com' *>$null
    & git -C $repo config user.name 'HD Test' *>$null
    & git -C $repo config core.autocrlf false *>$null
    & git -C $repo config core.safecrlf false *>$null
    [IO.File]::WriteAllText((Join-Path $repo 'base.txt'), "base`n", [Text.UTF8Encoding]::new($false))
    $poldir = Join-Path $repo 'source\registry'
    New-Item -ItemType Directory -Path $poldir -Force | Out-Null
    $profObj = New-Object PSCustomObject
    $profObj | Add-Member -NotePropertyName 'passes' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 0'; timeout_seconds = 30 })
    $doc = [ordered]@{ version = 1; default_timeout_seconds = 60; max_output_chars = 4000; profiles = $profObj }
    $json = (New-Object PSCustomObject -Property $doc | ConvertTo-Json -Depth 8 -Compress)
    [IO.File]::WriteAllText((Join-Path $poldir 'verification-policy.json'), $json, [Text.UTF8Encoding]::new($false))
    & git -C $repo add -A *>$null
    & git -C $repo commit -m init -q *>$null
    & git -C $repo commit -m policy -q --allow-empty *>$null
    return @{ outer = $outer; repo = $repo; tasks = $tasks; ledger = $ledger; flags = $flags }
}

function New-HdSeam {
    param([string]$Session, [string]$Provider, [string]$ModelShort, [string]$Message)
    $cap = @{ session = $Session; provider = $Provider; model = $ModelShort; message = $Message }
    return ({
        param([string]$ChildSid)
        $sn = [ordered]@{ id = $cap.session; parentID = 'ses_parent_hd'; agent = 'build'; model = [ordered]@{ providerID = $cap.provider; id = $cap.model }; outcome = 'succeeded'; cost = 0; tokens = [ordered]@{ input = 10; output = 5; reasoning = 0 } }
        $mm = [ordered]@{ id = $cap.message; type = 'assistant'; agent = 'build'; model = [ordered]@{ providerID = $cap.provider; id = $cap.model }; time = [ordered]@{ created = '1000'; completed = '2000' }; finish = 'stop'; cost = 0; tokens = [ordered]@{ input = 10; output = 5; reasoning = 0 } }
        return @{ session = $sn; messages = @($mm) }
    }).GetNewClosure()
}

function New-HdExecutor {
    param([string]$SessionId, [string]$FailureClass = '')
    $state = @{ calls = 0; models = @() }
    $cap = @{ sid = $SessionId; fcls = $FailureClass }
    $exec = ({
        param([string]$Model, [string]$Agent, [string]$Prompt, [string]$Title, [int]$TimeoutMs)
        $state.calls++
        $state.models += $Model
        if (-not [string]::IsNullOrWhiteSpace($cap.fcls)) {
            return @{ ok = $false; failure_class = $cap.fcls; session_id = $null }
        }
        return @{ ok = $true; session_id = $cap.sid }
    }).GetNewClosure()
    return @{ executor = $exec; state = $state }
}

$probeAvailable = { return @{ executable_found = $true; inventory_lists_haiku = $true; reason = 'HAIKU_CAPABILITY_PROVEN' } }
$probeUnavailable = { return @{ executable_found = $false; inventory_lists_haiku = $false; reason = 'HAIKU_EXECUTABLE_MISSING' } }

try {
    . (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')

    # 1. Happy path: Haiku primary, one dispatch, full correlation.
    $t = New-HdRoot
    try {
        Set-TaskKernelSessionReader -Reader (New-HdSeam -Session 'ses_hd_1' -Provider 'claude-agent' -ModelShort 'haiku' -Message 'msg_hd_1')
        $ex = New-HdExecutor -SessionId 'ses_hd_1'
        $r = Invoke-PlannerHaikuDispatch -TaskId 'hd-001' -Objective 'Probe planner dispatch' `
            -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
            -RunId 'run-hd-001' -TasksDir $t.tasks -FlagsPath $t.flags -RepoRoot $t.repo -RunLedgerDir $t.ledger `
            -DispatchExecutor $ex.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true
        Assert-HD ([bool]$r.ok -and [string]$r.status -ceq 'DISPATCHED') 'hd-happy-dispatched'
        Assert-HD ([string]$r.task_id -ceq 'hd-001' -and [string]$r.session_id -ceq 'ses_hd_1') 'hd-task-session-correlation'
        Assert-HD ([string]$r.provider -ceq 'claude-agent' -and [string]$r.model -ceq 'claude-agent/haiku' -and [string]$r.tier -ceq 'T2') 'hd-provider-model-tier'
        Assert-HD ([string]$r.cost -ceq 'UNKNOWN') 'hd-subscription-cost-unknown'
        Assert-HD ([int]$ex.state.calls -eq 1 -and @($ex.state.models).Count -eq 1 -and ([string]$ex.state.models[0] -ceq 'claude-agent/haiku')) 'hd-exactly-one-haiku-call'
        Assert-HD ([string]$r.verify_run_status -ceq 'verified_pass') 'hd-verify-run-kernel-executed-pass'
        Assert-HD ([string]$r.review_state -ceq 'pending-independent-review') 'hd-review-pending'
        $rec = Get-OrchestrationTask -TaskId 'hd-001' -TasksDir $t.tasks
        Assert-HD ((@($rec['model_attempts'])).Count -ge 1) 'hd-model-attempt-recorded'
        $wr = $rec['worker_result']
        Assert-HD (($null -ne $wr) -and ([string]$wr['status'] -ceq 'candidate_pass')) 'hd-worker-result-candidate-pass'
        $claimed = @($wr['claimed_evidence'])
        Assert-HD (($claimed -contains 'session:ses_hd_1') -and ($claimed -contains 'message:msg_hd_1')) 'hd-session-message-refs'
        $vsrc = ''
        try { if ($null -ne $rec['verification']) { $vsrc = ([string]$rec['verification']['verification_source']).Trim() } } catch { $vsrc = '' }
        Assert-HD ($vsrc -ceq 'kernel-executed') 'hd-verification-kernel-executed'
    } finally { Clear-TaskKernelSessionReader }

    # 2. Exactly-once: same RunId refused, executor untouched.
    try {
        Set-TaskKernelSessionReader -Reader (New-HdSeam -Session 'ses_hd_1' -Provider 'claude-agent' -ModelShort 'haiku' -Message 'msg_hd_1')
        $ex2 = New-HdExecutor -SessionId 'ses_hd_1'
        $rDup = Invoke-PlannerHaikuDispatch -TaskId 'hd-001' -Objective 'Probe planner dispatch' `
            -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
            -RunId 'run-hd-001' -TasksDir $t.tasks -FlagsPath $t.flags -RepoRoot $t.repo -RunLedgerDir $t.ledger `
            -DispatchExecutor $ex2.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true
        Assert-HD (([string]$rDup.status -ceq 'DUPLICATE_RUN_REFUSED') -and (-not [bool]$rDup.ok)) 'hd-duplicate-refused'
        Assert-HD ([int]$ex2.state.calls -eq 0) 'hd-duplicate-no-second-call'
    } finally { Clear-TaskKernelSessionReader }

    # 3. Pre-run unavailability: Luna fallback dispatched, never generic Muse.
    $t3 = New-HdRoot
    try {
        Set-TaskKernelSessionReader -Reader (New-HdSeam -Session 'ses_hd_3' -Provider 'openai' -ModelShort 'gpt-6-luna' -Message 'msg_hd_3')
        $ex3 = New-HdExecutor -SessionId 'ses_hd_3'
        $rFb = Invoke-PlannerHaikuDispatch -TaskId 'hd-003' -Objective 'Probe planner fallback' `
            -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
            -RunId 'run-hd-003' -TasksDir $t3.tasks -FlagsPath $t3.flags -RepoRoot $t3.repo -RunLedgerDir $t3.ledger `
            -DispatchExecutor $ex3.executor -CapabilityProbe $probeUnavailable -NativeModelOverrideProven $true
        Assert-HD ([bool]$rFb.ok -and [string]$rFb.status -ceq 'DISPATCHED') 'hd-fallback-dispatched'
        Assert-HD ([bool]$rFb.fallback_used -and ([string]$ex3.state.models[0] -ceq 'openai/gpt-6-luna')) 'hd-fallback-luna-dispatched'
        Assert-HD ([string]$rFb.provider -ceq 'openai') 'hd-fallback-provider-openai'
    } finally { Clear-TaskKernelSessionReader }

    # 4. Timeout: PROOF_ABSENT, one call, no retry, no fallback.
    $t4 = New-HdRoot
    $ex4 = New-HdExecutor -SessionId '' -FailureClass 'TIMEOUT_AMBIGUOUS'
    $rTo = Invoke-PlannerHaikuDispatch -TaskId 'hd-004' -Objective 'Probe timeout' `
        -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
        -RunId 'run-hd-004' -TasksDir $t4.tasks -FlagsPath $t4.flags -RepoRoot $t4.repo -RunLedgerDir $t4.ledger `
        -DispatchExecutor $ex4.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true
    Assert-HD ((([string]$rTo.status -ceq 'PROOF_ABSENT')) -and (-not [bool]$rTo.ok)) 'hd-timeout-proof-absent'
    Assert-HD ([int]$ex4.state.calls -eq 1) 'hd-timeout-single-call-no-retry'
    Assert-HD ([string]$rTo.cost -ceq 'UNKNOWN') 'hd-timeout-cost-unknown'

    # 5. Ambiguous telemetry (ok but no session): PROOF_ABSENT TELEMETRY_MISSING.
    $t5 = New-HdRoot
    $ex5state = @{ calls = 0 }
    $ex5 = ({ param([string]$Model,[string]$Agent,[string]$Prompt,[string]$Title,[int]$TimeoutMs) $ex5state.calls++; return @{ ok = $true; session_id = $null } }).GetNewClosure()
    $rAmb = Invoke-PlannerHaikuDispatch -TaskId 'hd-005' -Objective 'Probe ambiguous' `
        -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
        -RunId 'run-hd-005' -TasksDir $t5.tasks -FlagsPath $t5.flags -RepoRoot $t5.repo -RunLedgerDir $t5.ledger `
        -DispatchExecutor $ex5 -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true
    Assert-HD (([string]$rAmb.status -ceq 'PROOF_ABSENT') -and ([string]$rAmb.reason -ceq 'TELEMETRY_MISSING')) 'hd-ambiguous-telemetry-missing'
    Assert-HD ([int]$ex5state.calls -eq 1) 'hd-ambiguous-single-call'

    # 6. Override unproven: no dispatch at all.
    $t6 = New-HdRoot
    $ex6 = New-HdExecutor -SessionId 'ses_hd_6'
    $rUnp = Invoke-PlannerHaikuDispatch -TaskId 'hd-006' -Objective 'Probe unproven' `
        -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
        -RunId 'run-hd-006' -TasksDir $t6.tasks -FlagsPath $t6.flags -RepoRoot $t6.repo -RunLedgerDir $t6.ledger `
        -DispatchExecutor $ex6.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $false
    Assert-HD ([string]$rUnp.status -ceq 'MODEL_OVERRIDE_UNPROVEN') 'hd-override-unproven-fail-closed'
    Assert-HD ([int]$ex6.state.calls -eq 0) 'hd-override-unproven-no-dispatch'

    # 7. CLI divergence: ExpectedModel mismatch fails closed before dispatch.
    $t7 = New-HdRoot
    try {
        Set-TaskKernelSessionReader -Reader (New-HdSeam -Session 'ses_hd_7' -Provider 'claude-agent' -ModelShort 'haiku' -Message 'msg_hd_7')
        $ex7 = New-HdExecutor -SessionId 'ses_hd_7'
        $rMm = Invoke-PlannerHaikuDispatch -TaskId 'hd-007' -Objective 'Probe mismatch' `
            -VerificationProfiles @('passes') -AcceptanceCriteria @('planner session evidence recorded') `
            -RunId 'run-hd-007' -TasksDir $t7.tasks -FlagsPath $t7.flags -RepoRoot $t7.repo -RunLedgerDir $t7.ledger `
            -DispatchExecutor $ex7.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true -ExpectedModel 'openai/gpt-6-luna'
        Assert-HD ([string]$rMm.status -ceq 'MODEL_MISMATCH') 'hd-expected-model-mismatch-fail-closed'
        Assert-HD ([int]$ex7.state.calls -eq 0) 'hd-mismatch-no-dispatch'
    } finally { Clear-TaskKernelSessionReader }

    # 8. Missing plan: fail-closed before any side effect beyond ledger dirs.
    $t8 = New-HdRoot
    $ex8 = New-HdExecutor -SessionId 'ses_hd_8'
    $rPlan = Invoke-PlannerHaikuDispatch -TaskId 'hd-008' -Objective 'Probe plan' `
        -VerificationProfiles @() -AcceptanceCriteria @('x') `
        -RunId 'run-hd-008' -TasksDir $t8.tasks -FlagsPath $t8.flags -RepoRoot $t8.repo -RunLedgerDir $t8.ledger `
        -DispatchExecutor $ex8.executor -CapabilityProbe $probeAvailable -NativeModelOverrideProven $true
    Assert-HD ([string]$rPlan.status -ceq 'PLAN_REQUIRED') 'hd-plan-required'
    Assert-HD ([int]$ex8.state.calls -eq 0) 'hd-plan-no-dispatch'

    # 9. Review trust boundary on the dispatched task: self-approval refused,
    #    independent reviewer approval recorded.
    $revNow = ([int](Get-OrchestrationTask -TaskId 'hd-001' -TasksDir $t.tasks)['revision'])
    $selfRev = Set-OrchestrationTaskReview -TaskId 'hd-001' -Kind 'reviewer' -Status 'approved' -By 'build' -ExpectedRevision $revNow -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-HD (((-not [bool]$selfRev.ok) -and ([string]$selfRev.error -ceq 'SELF_REVIEW_FORBIDDEN'))) 'hd-self-review-forbidden'
    $indRev = Set-OrchestrationTaskReview -TaskId 'hd-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer-session-ses_rev_1' -ExpectedRevision $revNow -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-HD ([bool]$indRev.ok) 'hd-independent-review-recorded'
# 10. CLI contract (static, hermetic): model-select exposes planner fallback
#     fields and the wrapper binds the CLI-returned model as ExpectedModel.
$cliText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\task-kernel.ps1'), [Text.UTF8Encoding]::new($false))
Assert-HD (($cliText -match 'planner_fallback_model') -and ($cliText -match 'planner_fallback_provider')) 'hd-cli-planner-fallback-fields'
$wrapText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\invoke-planner-haiku-session.ps1'), [Text.UTF8Encoding]::new($false))
Assert-HD (($wrapText -match 'model-select') -and ($wrapText -match 'ExpectedModel') -and ($wrapText -match 'AttemptRole') ) 'hd-wrapper-cli-model-binding'
} finally {
    try { Clear-TaskKernelSessionReader } catch { }
}

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
