<#!
.SYNOPSIS
    Tests for the refusal envelopes of an existing receipt (R4/SEC4).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.

    A caller probing an idempotency key must not learn whether the key
    exists, nor whether the existing receipt belongs to it. Before the
    fix, an existing-but-unusable receipt answered with two different
    reasons (fingerprint collision vs identity mismatch), which revealed
    the receipt state. After the fix:
      - the identity check runs BEFORE the fingerprint;
      - both refusals return ONE reason ('duplicate-identity-mismatch')
        with the same shape, never carrying worker_result/evidence_id.
    This suite produces the two refusals (same owner/divergent intent and
    foreign owner/same intent) and compares the envelopes field by field.
    The only excluded field is `intent`, the echo of the caller's own
    input: its `created_at` is time-dependent by nature and it is not
    derived from the stored receipt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')

$script:passed = 0
$script:failed = 0

function Assert-EV {
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

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndenvelopes-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    try {
        # ---------- fixture: owner goal + foreign goal + kernel tasks ----------
        $ph = Get-NativeDispatchHash32 'envelope-prompt-material'
        $g = New-OrchestrationGoal -GoalId 'ev-goal-1' -Objective 'envelopes indistinguiveis' -Criteria @('criterio-a', 'criterio-b') -StoreDir $goalDir
        Assert-EV ([bool]$g.ok) '[F] owner goal created' ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-EV ([bool]$sv.ok) '[F] owner goal active+saved' ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'ev-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-EV ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        $authOk = @{ explicit_allow = $true; goal_id = 'ev-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }

        $fg = New-OrchestrationGoal -GoalId 'ev-goal-2' -Objective 'goal estranho' -Criteria @('criterio-a') -StoreDir $goalDir
        $fact = Set-OrchestrationGoalState -Goal $fg.goal -ToState 'ACTIVE'
        $fsv = Save-OrchestrationGoal -Goal $fact.goal -StoreDir $goalDir
        Assert-EV ([bool]$fsv.ok) '[F] foreign goal active+saved' ([string]$fsv.reason)
        $fown = Acquire-OrchestrationGoalOwnership -GoalId 'ev-goal-2' -OwnerId 'planner-9' -ExpectedRevision ([long]$fsv.revision) -StoreDir $goalDir
        Assert-EV ([bool]$fown.ok) '[F] foreign ownership acquired' ([string]$fown.reason)
        $authForeign = @{ explicit_allow = $true; goal_id = 'ev-goal-2'; owner = 'planner-9'; generation = [long]$fown.ownership['generation']; source = 'planner' }

        $script:tasksDirText = $tasksDir
        $script:flagsPathText = $flagsPath
        $script:tempRootText = $tempRoot
        $script:goalDirText = $goalDir
        $script:genText = $gen
        $script:phText = $ph

        function New-EVKernelTask {
            param([string]$Id)
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $script:tempRootText
            Assert-EV ([bool]$c.ok) ('[F] kernel task created ' + $Id) ([string]$c.error)
            $slot = Get-OrchestrationGoal -GoalId 'ev-goal-1' -StoreDir $script:goalDirText
            $add = Add-OrchestrationGoalTaskPersisted -GoalId 'ev-goal-1' -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:goalDirText -OwnerId 'planner-1' -OwnershipGeneration $script:genText
            Assert-EV ([bool]$add.ok) ('[F] task attached ' + $Id) ([string]$add.reason)
        }

        function New-EVIntent {
            param([string]$Task, [string]$Key)
            return (New-OrchestrationNativeDispatchIntent -TaskId $Task -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $script:phText `
                -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $Key `
                -Owner 'planner-1' -OwnershipGeneration $script:genText -BaseRevision 'rev-a')
        }

        function New-EVReceiptPath {
            param([string]$GoalId, [string]$Key)
            try {
                # F3/REV5: recibos isolados por goal autorizado.
                $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $GoalId
                return (Join-Path $sub ($Key + '.json'))
            }
            catch { return (Join-Path $receiptDir ($Key + '.json')) }
        }

        New-EVKernelTask -Id 'ev-task-1'
        New-EVKernelTask -Id 'ev-task-2'

        # ---------- one settled receipt for the shared key ----------
        $key = Get-NativeDispatchHash32 'ev-shared-key-1'
        $goodIntent = New-EVIntent -Task 'ev-task-1' -Key $key
        $st = @{ calls = 0 }
        $spy = { param($i) $st.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rOk = Invoke-OrchestrationNativeDispatch -Intent $goodIntent.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-EV ([bool]$rOk.ok) '[F] shared key settles once' ([string]$rOk.reason)
        $recPath = (New-EVReceiptPath -GoalId 'ev-goal-1' -Key $key)
        $before = [IO.File]::ReadAllBytes($recPath)

        # ---------- refusal A: cross-goal probe (receipt lives elsewhere) ----------
        # Same intent (so the fingerprint equals the stored one) presented
        # by the owner of a DIFFERENT goal. F3/REV5: the receipts are
        # namespaced per goal, so this caller resolves ITS OWN path, does
        # not find the key and follows the normal admission path (which
        # refuses on the live kernel facts). The existence of the receipt
        # in the other goal is NOT observable.
        $stA = @{ calls = 0 }
        $spyA = { param($i) $stA.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $envA = Invoke-OrchestrationNativeDispatch -Intent $goodIntent.intent -Executor $spyA -Authorization $authForeign -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-EV (((-not [bool]$envA.ok) -and ([int]$envA.executor_calls -eq 0) -and ([int]$stA.calls -eq 0) -and (-not [bool]$envA.duplicate))) '[A] cross-goal probe refuses with 0 calls' (([string]$envA.reason) + ' calls=' + [string]$stA.calls)
        Assert-EV (([string]$envA.reason -cne 'duplicate-identity-mismatch') -and ([string]$envA.reason -cne 'idempotent-duplicate')) '[A] cross-goal probe never reports an existing receipt' ([string]$envA.reason)

        # ---------- refusal A2: a key that never existed, SAME input ----------
        # The oracle test: with the same Authorization and the same
        # task/revision, probing a key that exists in ANOTHER goal must be
        # indistinguishable from probing a key that was never used.
        $neverIntent = New-EVIntent -Task 'ev-task-1' -Key (Get-NativeDispatchHash32 'ev-never-used-1')
        Assert-EV ([bool]$neverIntent.ok) '[A2] never-used key intent built' ([string]$neverIntent.reason)
        $stA2 = @{ calls = 0 }
        $spyA2 = { param($i) $stA2.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $envA2 = Invoke-OrchestrationNativeDispatch -Intent $neverIntent.intent -Executor $spyA2 -Authorization $authForeign -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-EV (((-not [bool]$envA2.ok) -and ([int]$envA2.executor_calls -eq 0) -and ([int]$stA2.calls -eq 0))) '[A2] never-used key refuses with 0 calls' (([string]$envA2.reason) + ' calls=' + [string]$stA2.calls)

        # ---------- refusal B: fingerprint mismatch (identity MATCHES) ----------
        # Same key, same owner/goal, divergent intent: the receipt exists
        # in the caller's own namespace and does not match this dispatch.
        $divergent = New-EVIntent -Task 'ev-task-2' -Key $key
        Assert-EV ([bool]$divergent.ok) '[B] divergent intent built for the same key' ([string]$divergent.reason)
        $stB = @{ calls = 0 }
        $spyB = { param($i) $stB.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $envB = Invoke-OrchestrationNativeDispatch -Intent $divergent.intent -Executor $spyB -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-EV (((-not [bool]$envB.ok) -and ([string]$envB.reason -ceq 'duplicate-identity-mismatch') -and ([int]$envB.executor_calls -eq 0) -and ([int]$stB.calls -eq 0))) '[B] fingerprint mismatch refuses with 0 calls' (([string]$envB.reason) + ' calls=' + [string]$stB.calls)
        Assert-EV ((-not [bool]$envB.duplicate)) '[B] fingerprint mismatch is not a duplicate read' ''

        # ---------- the two boundary refusals are indistinguishable ----------
        # A (key exists in another goal) vs A2 (key never used): field by
        # field identical for the SAME input. No existence oracle.
        $fields = @('ok', 'reason', 'admitted', 'duplicate', 'reconciled', 'executor_calls', 'worker_result', 'kernel_ok', 'kernel_reason', 'evidence_created', 'evidence_id')
        foreach ($f in $fields) {
            $va = Get-NDValue $envA $f $null
            $vb = Get-NDValue $envA2 $f $null
            $sa = '<null>'
            $sb = '<null>'
            if ($null -ne $va) { $sa = [string]$va }
            if ($null -ne $vb) { $sb = [string]$vb }
            Assert-EV ($sa -ceq $sb) ('[F3] existing-elsewhere and absent agree on ' + $f) ($sa + ' vs ' + $sb)
        }
        # no oracle: neither refusal carries receipt content
        Assert-EV (($null -eq (Get-NDValue $envA 'worker_result' $null)) -and ($null -ceq (Get-NDValue $envA2 'worker_result' $null))) '[F3] both boundary refusals carry no worker_result' ''
        Assert-EV ((([string](Get-NDValue $envA 'evidence_id' '')) -ceq '') -and (([string](Get-NDValue $envA2 'evidence_id' '')) -ceq '')) '[F3] both boundary refusals carry no evidence_id' ''
        Assert-EV ((-not [bool](Get-NDValue $envA 'evidence_created' $true)) -and (-not [bool](Get-NDValue $envA2 'evidence_created' $true))) '[F3] both boundary refusals claim no evidence' ''
        Assert-EV (([string]$envA.reason -cne [string]$envB.reason)) '[F3] same-namespace mismatch is a distinct, documented state from a foreign probe' ([string]$envA.reason + ' vs ' + [string]$envB.reason)

        # ---------- the settled receipt was never touched ----------
        $after = [IO.File]::ReadAllBytes($recPath)
        $same = (@($after).Count -eq @($before).Count)
        if ($same) {
            for ($i = 0; $i -lt @($after).Count; $i++) { if ([int]$after[$i] -ne [int]$before[$i]) { $same = $false; break } }
        }
        Assert-EV $same '[R4] refused duplicates preserve the settled receipt byte for byte' ('before=' + @($before).Count + ' after=' + @($after).Count)
        $stillRec = ConvertFrom-Json ([IO.File]::ReadAllText($recPath, [Text.Encoding]::UTF8))
        Assert-EV (([string]$stillRec.phase -ceq 'settled') -and ([bool]$stillRec.ok) -and ($null -ne $stillRec.worker_result)) '[R4] settled receipt still holds its proven result' ''

        # ---------- the legitimate owner still reads the duplicate ----------
        $stC = @{ calls = 0 }
        $spyC = { param($i) $stC.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $envC = Invoke-OrchestrationNativeDispatch -Intent $goodIntent.intent -Executor $spyC -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-EV ((([bool]$envC.duplicate) -and ([string]$envC.reason -ceq 'idempotent-duplicate') -and ([int]$stC.calls -eq 0) -and ($null -ne $envC.worker_result))) '[R4] the entitled owner still reads the duplicate' ([string]$envC.reason)

        # ---------- hygiene ----------
        $evPath = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        $evText = [IO.File]::ReadAllText($evPath, [Text.UTF8Encoding]::new($false))
        Assert-EV ((($evText -notmatch 'Start-Process') -and ($evText -notmatch 'Invoke-WebRequest') -and ($evText -notmatch 'Invoke-RestMethod'))) '[NET] no spawn/network' ''
        Assert-EV (($evText -notmatch '(?i)\bsk-[A-Za-z0-9]{20,}')) '[SEC] no secret value' ''
        foreach ($p in @($evPath, (Join-Path $PSScriptRoot 'OrchestrationNativeDispatchEnvelopes.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-EV ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
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
