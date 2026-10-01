<#!
.SYNOPSIS
    Tests for Phase 27 slice 1 (strategy-aware recovery, typed waits,
    idempotent work) in lib/OrchestrationTaskKernel.ps1.
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP for fixture flags + kernel task
    dirs, cleanup in finally. Bracketed output the runner parses. Exit 0
    on all pass, exit 1 on any fail or unexpected exception. PS 5.1
    compatible. ASCII-only.

    No scenario shells out except scenario 16, which races two creates
    through a real external-deadline harness (Start-Job + Wait-Job
    -Timeout with Stop/Remove cleanup, restricted to own temp dirs);
    every other call is in-process against the kernel lib, and the file
    lock is bounded inside the lib (20 x 100ms). A whole-file Stopwatch
    is reported in [SUMMARY]; there is no infinite wait in this file.

    Covers (PLAN Phase 27 required tests + slice acceptance):
      1. wording variants of the same failure share one recovery
         fingerprint (rewording never resets counts);
      2. same stalled strategy without evidence is rejected
         (STALLED_STRATEGY_REJECTED), revision untouched;
      3. materially different strategy is allowed;
      4. second material failure surfaces DEBUGGER_REQUIRED when the
         debugger trace is missing (kernel records the requirement,
         dispatches nobody);
      5. invalid third attempt without novelty becomes EXHAUSTED;
      6. typed human_decision wait accepted with fingerprint;
      7. typed external_dependency wait accepted (dependency id is
         part of the fingerprint);
      8. declared-but-invalid typed wait is rejected
         (WAIT_TYPED_REQUIRED), state untouched; real prose-only
         rejection lives on strict tasks (scenario 15);
      9. duplicate active work is refused (DUPLICATE_ACTIVE_WORK with
         existing_task_id, nothing created, never merged);
     10. distinct scope does not dedupe (creates normally);
     11. re-block with the same wait fingerprint is idempotent;
     12. legacy records (no new fields) stay readable and operable;
     13. third attempt WITH novelty opens (no EXHAUSTED);
     14. unblock out of BLOCKED without a wait reference is rejected;
     15. strict task (require_typed_waits) rejects prose-only BLOCKED
         while legacy tasks keep the prose lane (F-A);
     16. concurrent creates with distinct ids and one work
         fingerprint yield exactly one winner (F-B);
     17. framed fingerprints separate structural collisions but keep
         equivalent inputs equal (F-C);
     18. replayed evidence refs are not novelty, fresh refs are (F-D);
     19. worker result inherits the attempt-bound strategy and
         rejects divergent fingerprints (F-E);
     20. third attempt opened with novelty records without
         artificial switches (F-F);
     21. corrupt active_wait fails closed with MALFORMED_WAIT (F-G).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $libPath

$script:passed = 0
$script:failed = 0
$script:watch = [System.Diagnostics.Stopwatch]::StartNew()

function Assert-Recovery {
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

function Write-RecoveryFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-RecoveryRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-recovery-' + [guid]::NewGuid().ToString('N'))
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    Write-RecoveryFixture -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; tasks = $tasks; flags = $flags }
}

function New-RecoveryTask {
    param(
        [string]$TasksDir, [string]$FlagsPath, [string]$Root, [string]$Id,
        [string]$Objective = 'Recover the widget renderer',
        [string[]]$Read = @('src/widget'), [string[]]$Write = @('src/widget'),
        [string[]]$Dod = @('widget renders again'), [string]$Project = 'proj-test',
        [switch]$StrictWaits
    )
    $a = @{
        TaskId = $Id; Objective = $Objective; TaskType = 'implementation'
        Risk = 'low'; Actor = 'planner'; Project = $Project
        RuntimeId = 'opencode-v1'; RuntimeGeneration = 1; RuntimeProfile = 'v1'
        ReadScopes = $Read; WriteScopes = $Write; Grants = @('fs.read', 'fs.write')
        AcceptanceCriteria = $Dod; AttemptBudget = 3; TasksDir = $TasksDir; FlagsPath = $FlagsPath; TelemetryRoot = $Root
    }
    if ($StrictWaits) { $a['RequireTypedWaits'] = $true }
    return (New-OrchestrationTask @a)
}

function Move-RecoveryToImplementing {
    param([string]$Id, [string]$TasksDir, [string]$FlagsPath, [string]$Root)
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' `
        -ExpectedRevision 1 -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Root
    $s = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Root
    return ([int]$s.revision)
}

function Get-RecoveryBytes {
    param([string]$Path)
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)
}

function Start-RecoveryAttempt {
    param(
        [string]$Id, [string]$Session, [int]$Rev, [string]$TasksDir, [string]$FlagsPath, [string]$Root,
        [string]$Approach = '', [string]$Tool = '', [string[]]$Params = @(), [string]$Fingerprint = '',
        [string]$Hypothesis = '', [string[]]$EvidenceRefs = $null, [string[]]$DebuggerRefs = $null
    )
    $a = @{
        TaskId = $Id; AttemptRole = 'coder'; SessionId = $Session; Actor = 'planner'
        ExpectedRevision = $Rev; ActorIdentitySource = 'explicit-cli'
        TasksDir = $TasksDir; FlagsPath = $FlagsPath; TelemetryRoot = $Root
    }
    if (-not [string]::IsNullOrWhiteSpace($Approach)) { $a['StrategyApproach'] = $Approach }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) { $a['StrategyTool'] = $Tool }
    if (($null -ne $Params) -and ((@($Params)).Count -gt 0)) { $a['StrategyParams'] = $Params }
    if (-not [string]::IsNullOrWhiteSpace($Fingerprint)) { $a['StrategyFingerprint'] = $Fingerprint }
    if (-not [string]::IsNullOrWhiteSpace($Hypothesis)) { $a['AttemptHypothesis'] = $Hypothesis }
    if ($null -ne $EvidenceRefs) { $a['NewEvidenceRefs'] = $EvidenceRefs }
    if ($null -ne $DebuggerRefs) { $a['DebuggerEvidenceRefs'] = $DebuggerRefs }
    return (Start-OrchestrationTaskAttempt @a)
}

function Fail-RecoveryAttempt {
    param(
        [string]$Id, [int]$Rev, [string]$TasksDir, [string]$FlagsPath, [string]$Root,
        [string]$Approach = '', [string]$Tool = '', [string[]]$Params = @(),
        [string]$FailureClass = '', [string]$FailureDetail = '', [string]$Hypothesis = '',
        [string[]]$EvidenceRefs = $null
    )
    $a = @{
        TaskId = $Id; Status = 'failed'; ClaimedEvidence = @('criterion:0:attempt log')
        ProducedBy = 'coder'; ExpectedRevision = $Rev
        TasksDir = $TasksDir; FlagsPath = $FlagsPath; TelemetryRoot = $Root
    }
    if (-not [string]::IsNullOrWhiteSpace($Approach)) { $a['StrategyApproach'] = $Approach }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) { $a['StrategyTool'] = $Tool }
    if ((@($Params)).Count -gt 0) { $a['StrategyParams'] = $Params }
    if (-not [string]::IsNullOrWhiteSpace($FailureClass)) { $a['FailureClass'] = $FailureClass }
    if (-not [string]::IsNullOrWhiteSpace($FailureDetail)) { $a['FailureDetail'] = $FailureDetail }
    if (-not [string]::IsNullOrWhiteSpace($Hypothesis)) { $a['Hypothesis'] = $Hypothesis }
    if ($null -ne $EvidenceRefs) { $a['NewEvidenceRefs'] = $EvidenceRefs }
    return (Set-OrchestrationTaskWorkerResult @a)
}

$roots = New-Object System.Collections.ArrayList

try {
    # 1. wording variants share one recovery fingerprint (counts never reset)
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $s1 = Get-OrchestrationStrategyFingerprint -Approach '  Patch   Widget RENDERER in place' -ToolOrPath 'SRC/widget/render.js' -KeyParams @('mode=strict', 'target=dom')
    $s2 = Get-OrchestrationStrategyFingerprint -Approach 'patch widget renderer in place' -ToolOrPath 'src/widget/render.js' -KeyParams @('target=dom', 'mode=strict')
    Assert-Recovery (([bool]$s1.ok) -and ([bool]$s2.ok) -and ([string]$s1.fingerprint -ceq [string]$s2.fingerprint)) 'same strategy words in other order/case share fingerprint'
    Assert-Recovery (([string]$s1.fingerprint -cmatch '^sha256:[0-9a-f]{64}$')) 'strategy fingerprint is sha256 closed-charset'
    $s3 = Get-OrchestrationStrategyFingerprint -Approach 'Rewrite widget renderer from scratch' -ToolOrPath 'src/widget/render.js' -KeyParams @('mode=strict', 'target=dom')
    Assert-Recovery (([string]$s3.fingerprint -cne [string]$s1.fingerprint)) 'materially different approach yields a different fingerprint'
    $c = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fp-001'
    Assert-Recovery ([bool]$c.ok) 'recovery setup create ok'
    $rev = Move-RecoveryToImplementing -Id 'rec-fp-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fp-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('mode=strict', 'target=dom') `
        -FailureClass 'timeout' -FailureDetail 'timeout after 30s waiting for api'
    $f2 = Fail-RecoveryAttempt -Id 'rec-fp-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('target=dom', 'mode=strict') `
        -FailureClass 'timeout' -FailureDetail 'API   TIMEOUT   after thirty seconds, same root cause'
    $g = Get-OrchestrationTask -TaskId 'rec-fp-001' -TasksDir $t.tasks
    $atts = @($g['attempts'])
    Assert-Recovery (([bool]$f1.ok) -and ([bool]$f2.ok) -and ($atts.Count -eq 2) -and ([int]$atts[0]['n'] -eq 1) -and ([int]$atts[1]['n'] -eq 2)) 'two failures keep counting n=1,2 (no reset)'
    Assert-Recovery (([string]$atts[0]['recovery_fingerprint'] -ceq [string]$atts[1]['recovery_fingerprint']) -and ([string]$atts[0]['recovery_fingerprint'] -cmatch '^sha256:[0-9a-f]{64}$')) 'reworded failure detail keeps the same recovery fingerprint'
    Assert-Recovery ((-not [bool]$atts[0]['changed_from_previous']) -and (-not [bool]$atts[1]['changed_from_previous'])) 'same strategy twice means changed_from_previous stays false'

    # 2. same stalled strategy without evidence is rejected
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-stall-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-stall-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-stall-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('mode=strict') -FailureClass 'worker_failed'
    $file = Join-Path $t.tasks 'rec-stall-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $st = Start-RecoveryAttempt -Id 'rec-stall-001' -Session 'sess-stall-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('mode=strict')
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$st.ok) -and ([string]$st.error -ceq 'STALLED_STRATEGY_REJECTED') -and ($pre -ceq $post))) 'same stalled strategy without evidence rejected without write'
    $st2 = Start-RecoveryAttempt -Id 'rec-stall-001' -Session 'sess-stall-b' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('mode=strict') `
        -EvidenceRefs @('criterion:0:fresh log line')
    Assert-Recovery (([bool]$st2.ok) -and ([int]$st2.revision -eq ([int]$f1.revision + 1))) 'same strategy with fresh evidence refs opens'

    # 3. materially different strategy is allowed
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-diff-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-diff-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-diff-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -Params @('mode=strict') -FailureClass 'worker_failed'
    $op = Start-RecoveryAttempt -Id 'rec-diff-001' -Session 'sess-diff-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' -Params @('mode=strict')
    $g = Get-OrchestrationTask -TaskId 'rec-diff-001' -TasksDir $t.tasks
    $lastFp = [string](@($g['attempts'])[0]['strategy_fingerprint'])
    $gateFp = [string]$g['execution_runtime']['gate_evidence']['strategy_fingerprint']
    Assert-Recovery (([bool]$op.ok) -and (-not [string]::IsNullOrWhiteSpace($gateFp)) -and ($gateFp -cne $lastFp)) 'materially different strategy opens with a new recorded fingerprint'

    # 4. second material failure surfaces DEBUGGER_REQUIRED (kernel records, dispatches nobody)
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-dbg-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-dbg-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-dbg-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $f2 = Fail-RecoveryAttempt -Id 'rec-dbg-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $g2 = Get-OrchestrationTask -TaskId 'rec-dbg-001' -TasksDir $t.tasks
    Assert-Recovery ([bool](@($g2['attempts'])[1]['debugger_required'])) 'second failure flags debugger_required on the record'
    $file = Join-Path $t.tasks 'rec-dbg-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $rq = Start-RecoveryAttempt -Id 'rec-dbg-001' -Session 'sess-dbg-a' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:fresh log line')
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$rq.ok) -and ([string]$rq.error -ceq 'DEBUGGER_REQUIRED') -and ($pre -ceq $post))) 'novelty without debugger trace after second failure is refused without write'
    $rq2 = Start-RecoveryAttempt -Id 'rec-dbg-001' -Session 'sess-dbg-b' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:fresh log line') -DebuggerRefs @('criterion:0:debugger trace')
    Assert-Recovery ([bool]$rq2.ok) 'debugger trace plus novelty opens the next attempt'

    # 5. invalid third attempt without novelty becomes EXHAUSTED
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-exh-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-exh-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-exh-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $f2 = Fail-RecoveryAttempt -Id 'rec-exh-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $ex = Start-RecoveryAttempt -Id 'rec-exh-001' -Session 'sess-exh-a' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js'
    $g = Get-OrchestrationTask -TaskId 'rec-exh-001' -TasksDir $t.tasks
    Assert-Recovery (((-not [bool]$ex.ok) -and ([string]$ex.error -ceq 'EXHAUSTED') -and ([string]$g['state'] -ceq 'EXHAUSTED'))) 'third attempt without novelty exhausts and persists EXHAUSTED'
    $after = Start-RecoveryAttempt -Id 'rec-exh-001' -Session 'sess-exh-b' -Rev ([int]$g['revision']) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Approach 'Anything new'
    Assert-Recovery (((-not [bool]$after.ok) -and ([string]$after.error -ceq 'ILLEGAL_TRANSITION'))) 'EXHAUSTED stays terminal'

    # 6. typed human_decision wait accepted with fingerprint
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-wait-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-wait-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $b = Block-OrchestrationTask -TaskId 'rec-wait-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'need product decision before continuing' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $exp = Get-OrchestrationWaitFingerprint -Type 'human_decision' -Owner 'user' -Action 'choose_database'
    $g = Get-OrchestrationTask -TaskId 'rec-wait-001' -TasksDir $t.tasks
    Assert-Recovery (([bool]$b.ok) -and ([string]$b.wait_fingerprint -ceq [string]$exp.fingerprint) -and ([string]$g['state'] -ceq 'BLOCKED')) 'typed human_decision wait accepted with stable fingerprint'
    Assert-Recovery (([string]$g['active_wait']['type'] -ceq 'human_decision') -and ([string]$g['active_wait']['fingerprint'] -ceq [string]$exp.fingerprint)) 'active wait node persisted on the record'

    # 7. typed external_dependency wait accepted (dependency id is part of the fingerprint)
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-wait-002'
    $rev = Move-RecoveryToImplementing -Id 'rec-wait-002' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $b = Block-OrchestrationTask -TaskId 'rec-wait-002' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'vendor api still down' -WaitType 'external_dependency' -WaitOwner 'vendor' -WaitAction 'restore_api' -WaitDependencyId 'vendor-api-7' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $withDep = Get-OrchestrationWaitFingerprint -Type 'external_dependency' -Owner 'vendor' -Action 'restore_api' -DependencyId 'vendor-api-7'
    $withoutDep = Get-OrchestrationWaitFingerprint -Type 'external_dependency' -Owner 'vendor' -Action 'restore_api'
    Assert-Recovery (([bool]$b.ok) -and ([string]$b.wait_fingerprint -ceq [string]$withDep.fingerprint) -and ([string]$withDep.fingerprint -cne [string]$withoutDep.fingerprint)) 'typed external_dependency wait accepted and dependency id changes the fingerprint'

    # 8. prose-only block on the typed path is rejected
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-wait-003'
    $rev = Move-RecoveryToImplementing -Id 'rec-wait-003' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $file = Join-Path $t.tasks 'rec-wait-003.json'
    $pre = Get-RecoveryBytes -Path $file
    $noAction = Block-OrchestrationTask -TaskId 'rec-wait-003' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'waiting for something' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction '' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $badType = Block-OrchestrationTask -TaskId 'rec-wait-003' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'waiting for something' -WaitType 'telepathy' -WaitOwner 'user' -WaitAction 'decide' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-wait-003' -TasksDir $t.tasks
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$noAction.ok) -and ([string]$noAction.error -ceq 'WAIT_TYPED_REQUIRED') -and (-not [bool]$badType.ok) -and ([string]$badType.error -ceq 'WAIT_TYPED_REQUIRED') -and ([string]$g['state'] -ceq 'IMPLEMENTING') -and ($pre -ceq $post))) 'declared-but-invalid typed wait rejected with state untouched'

    # 9. duplicate active work is refused (never merged)
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $a = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'dup-work-001' `
        -Objective 'Ship billing export' -Read @('src/billing') -Write @('src/billing') -Dod @('export csv downloads') -Project 'proj-x'
    Assert-Recovery ([bool]$a.ok) 'first work unit created'
    $dup = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'dup-work-002' `
        -Objective '  SHIP   billing EXPORT ' -Read @('src/billing') -Write @('src/billing') -Dod @('export csv downloads') -Project 'PROJ-X'
    $dupFile = Join-Path $t.tasks 'dup-work-002.json'
    Assert-Recovery (((-not [bool]$dup.ok) -and ([string]$dup.error -ceq 'DUPLICATE_ACTIVE_WORK') -and ([string]$dup.existing_task_id -ceq 'dup-work-001') -and (-not (Test-Path -LiteralPath $dupFile)))) 'duplicate active work refused with existing_task_id and nothing created'

    # 10. distinct scope does not dedupe
    $ok = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'dup-work-003' `
        -Objective 'Ship billing export' -Read @('src/billing') -Write @('src/refunds') -Dod @('export csv downloads') -Project 'proj-x'
    Assert-Recovery ([bool]$ok.ok) 'distinct scope creates normally'

    # 11. re-block with the same wait fingerprint is idempotent
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-reblock-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-reblock-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $b1 = Block-OrchestrationTask -TaskId 'rec-reblock-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'need product decision' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $b2 = Block-OrchestrationTask -TaskId 'rec-reblock-001' -Actor 'planner' -ExpectedRevision ([int]$b1.revision) `
        -Reason 'need product decision again' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-reblock-001' -TasksDir $t.tasks
    Assert-Recovery (([bool]$b2.ok) -and ([bool]$b2.idempotent) -and ([int]$b2.revision -eq [int]$b1.revision) -and ((@($g['blockers'])).Count -eq 1)) 'same wait fingerprint re-block is idempotent with no extra entry'

    # 12. legacy records without new fields stay readable and operable
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $legacy = '{"schema_version":1,"task_id":"legacy-001","parent_task_id":"","trace_id":"","objective":"Legacy objective","task_type":"implementation","risk":"low","state":"DISCOVERING","revision":1,"orchestration_decision":"","actor":"planner","current_owner":"planner","runtime":{"id":"opencode-v1","generation":1,"profile":"v1","version":""},"base_revision":"","read_scopes":[],"write_scopes":[],"grants":[],"environment_authorization":{"allowed_environments":[],"production_authorized":false},"acceptance_criteria":[],"expected_artifacts":[],"attempt_budget":3,"attempts":[],"worker_result":null,"verification":null,"review":null,"security_review":null,"blockers":[],"residual_risks":[],"closure_reason":"","compliance_verdict":"","worktree":"","history":[],"created_at":"2026-01-01T00:00:00.0000000Z","updated_at":"2026-01-01T00:00:00.0000000Z"}'
    Write-RecoveryFixture -Path (Join-Path $t.tasks 'legacy-001.json') -Text $legacy
    $lg = Get-OrchestrationTask -TaskId 'legacy-001' -TasksDir $t.tasks
    $lread = (([string]$lg['task_id'] -ceq 'legacy-001') -and ([string]$lg['state'] -ceq 'DISCOVERING'))
    Assert-Recovery $lread 'legacy record reads without error'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'legacy-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $li = Invoke-OrchestrationTaskTransition -TaskId 'legacy-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $lw = Set-OrchestrationTaskWorkerResult -TaskId 'legacy-001' -Status 'failed' -ClaimedEvidence @('criterion:0:old log') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $lg2 = Get-OrchestrationTask -TaskId 'legacy-001' -TasksDir $t.tasks
    $lfp = [string](Get-TaskKernelAttemptField -Attempt (@($lg2['attempts'])[0]) -Name 'strategy_fingerprint')
    $ls = Start-OrchestrationTaskAttempt -TaskId 'legacy-001' -AttemptRole 'coder' -SessionId 'sess-legacy-a' -Actor 'planner' -ExpectedRevision ([int]$lw.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery (([bool]$li.ok) -and ([bool]$lw.ok) -and ([string]::IsNullOrWhiteSpace($lfp)) -and ([bool]$ls.ok)) 'legacy record transitions, fails, and restarts without strategy fields'

    # 13. third attempt WITH novelty opens (no EXHAUSTED)
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-novel-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-novel-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-novel-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $f2 = Fail-RecoveryAttempt -Id 'rec-novel-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $op = Start-RecoveryAttempt -Id 'rec-novel-001' -Session 'sess-novel-a' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:fresh log line') -DebuggerRefs @('criterion:0:debugger trace')
    $g = Get-OrchestrationTask -TaskId 'rec-novel-001' -TasksDir $t.tasks
    Assert-Recovery (([bool]$op.ok) -and ([string]$g['state'] -ceq 'IMPLEMENTING') -and ([int]$g['execution_runtime']['attempt_n'] -eq 3)) 'third attempt with novelty opens at attempt 3'

    # 14. unblock out of BLOCKED requires a wait reference
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-unblock-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-unblock-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $b = Block-OrchestrationTask -TaskId 'rec-unblock-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'need product decision' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $fp = [string]$b.wait_fingerprint
    $bare = Invoke-OrchestrationTaskTransition -TaskId 'rec-unblock-001' -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$b.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-unblock-001' -TasksDir $t.tasks
    Assert-Recovery (((-not [bool]$bare.ok) -and ([string]$bare.error -ceq 'UNBLOCK_REF_REQUIRED') -and ([string]$g['state'] -ceq 'BLOCKED'))) 'unblock without wait reference rejected, still BLOCKED'
    $ref = Invoke-OrchestrationTaskTransition -TaskId 'rec-unblock-001' -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$b.revision) -ActorIdentitySource 'explicit-cli' -WaitFingerprint $fp `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g2 = Get-OrchestrationTask -TaskId 'rec-unblock-001' -TasksDir $t.tasks
    Assert-Recovery (([bool]$ref.ok) -and ([string]$g2['state'] -ceq 'IMPLEMENTING') -and ((@($g2['blockers'])).Count -eq 0) -and ((@($g2['wait_history'])).Count -eq 1)) 'unblock with wait fingerprint succeeds and archives the wait'
    $b2 = Block-OrchestrationTask -TaskId 'rec-unblock-001' -Actor 'planner' -ExpectedRevision ([int]$ref.revision) `
        -Reason 'need decision again' -WaitType 'approval' -WaitOwner 'tech-lead' -WaitAction 'approve_rollout' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $act = Invoke-OrchestrationTaskTransition -TaskId 'rec-unblock-001' -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$b2.revision) -ActorIdentitySource 'explicit-cli' -UnblockAction 'tech-lead approved rollout in review' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery ([bool]$act.ok) 'unblock with a concrete action succeeds'

    # 15. strict task rejects prose-only BLOCKED, legacy keeps the prose lane
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-strict-001' -StrictWaits
    $rev = Move-RecoveryToImplementing -Id 'rec-strict-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $file = Join-Path $t.tasks 'rec-strict-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $prose = Block-OrchestrationTask -TaskId 'rec-strict-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'waiting for something' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $proseTr = Invoke-OrchestrationTaskTransition -TaskId 'rec-strict-001' -ToState 'BLOCKED' -Actor 'planner' `
        -ExpectedRevision $rev -Reason 'waiting for something' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-strict-001' -TasksDir $t.tasks
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$prose.ok) -and ([string]$prose.error -ceq 'WAIT_TYPED_REQUIRED') -and (-not [bool]$proseTr.ok) -and ([string]$proseTr.error -ceq 'WAIT_TYPED_REQUIRED') -and ([string]$g['state'] -ceq 'IMPLEMENTING') -and ($pre -ceq $post))) 'strict task rejects prose-only BLOCKED on both paths with state untouched'
    $typed = Block-OrchestrationTask -TaskId 'rec-strict-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'need product decision' -WaitType 'approval' -WaitOwner 'tech-lead' -WaitAction 'approve_rollout' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery ([bool]$typed.ok) 'strict task accepts a valid typed wait'
    $bare = Invoke-OrchestrationTaskTransition -TaskId 'rec-strict-001' -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$typed.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery (((-not [bool]$bare.ok) -and ([string]$bare.error -ceq 'UNBLOCK_REF_REQUIRED'))) 'strict task unblock still requires a wait reference'
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-prose-001' `
        -Objective 'Legacy prose lane stays open'
    $revP = Move-RecoveryToImplementing -Id 'rec-prose-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $legacy = Block-OrchestrationTask -TaskId 'rec-prose-001' -Actor 'planner' -ExpectedRevision $revP `
        -Reason 'waiting on vendor' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery (([bool]$legacy.ok) -and ([string](Get-OrchestrationTask -TaskId 'rec-prose-001' -TasksDir $t.tasks)['state'] -ceq 'BLOCKED')) 'legacy task keeps the prose-only lane'

    # 16. concurrent creates with distinct ids and one work fingerprint
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $raceScript = {
        param($Lib, $Tasks, $Flags, $Roo, $Tid)
        . $Lib
        $tries = 0
        while ($tries -lt 120) {
            $tries++
            $r = New-OrchestrationTask -TaskId $Tid -Objective 'Race the dedupe gate' -Actor 'planner' -Project 'proj-race' `
                -ReadScopes @('src/race') -WriteScopes @('src/race') -AcceptanceCriteria @('single winner') `
                -TasksDir $Tasks -FlagsPath $Flags -TelemetryRoot $Roo
            if (([string]$r.error -ceq 'LOCK_TIMEOUT') -and (-not [bool]$r.ok)) {
                Start-Sleep -Milliseconds 250
                continue
            }
            return $r
        }
        return $r
    }
    $j1 = Start-Job -ScriptBlock $raceScript -ArgumentList @($libPath, $t.tasks, $t.flags, $t.root, 'race-dedupe-aaa')
    $j2 = Start-Job -ScriptBlock $raceScript -ArgumentList @($libPath, $t.tasks, $t.flags, $t.root, 'race-dedupe-bbb')
    $done = Wait-Job -Job @($j1, $j2) -Timeout 120
    $r1 = $null
    $r2 = $null
    try { $r1 = @(Receive-Job -Job $j1 -ErrorAction SilentlyContinue)[-1] } catch { }
    try { $r2 = @(Receive-Job -Job $j2 -ErrorAction SilentlyContinue)[-1] } catch { }
    try { Stop-Job -Job @($j1, $j2) -ErrorAction SilentlyContinue } catch { }
    try { Remove-Job -Job @($j1, $j2) -Force -ErrorAction SilentlyContinue } catch { }
    $winners = @()
    $dups = @()
    foreach ($r in @($r1, $r2)) {
        if (($null -ne $r) -and [bool]$r.ok) { $winners += $r }
        elseif (($null -ne $r) -and ([string]$r.error -ceq 'DUPLICATE_ACTIVE_WORK')) { $dups += $r }
    }
    Assert-Recovery ((($done.Count -eq 2) -and ($winners.Count -eq 1) -and ($dups.Count -eq 1))) 'concurrent duplicate creates yield exactly one winner and one DUPLICATE_ACTIVE_WORK'

    # 17. framed fingerprints separate structural collisions
    $colA = Get-OrchestrationWorkFingerprint -Objective 'o' -Scope @('a,b') -DefinitionOfDone @('d') -Project 'p'
    $colB = Get-OrchestrationWorkFingerprint -Objective 'o' -Scope @('a', 'b') -DefinitionOfDone @('d') -Project 'p'
    $colC = Get-OrchestrationWorkFingerprint -Objective 'a|scope=b' -Scope @() -DefinitionOfDone @('d') -Project 'p'
    $colD = Get-OrchestrationWorkFingerprint -Objective 'a' -Scope @('scope=b') -DefinitionOfDone @('d') -Project 'p'
    $eqA = Get-OrchestrationWorkFingerprint -Objective '  Ship  IT ' -Scope @('s2', 's1') -DefinitionOfDone @('d') -Project 'P'
    $eqB = Get-OrchestrationWorkFingerprint -Objective 'ship it' -Scope @('s1', 's2') -DefinitionOfDone @('d') -Project 'p'
    Assert-Recovery (([bool]$colA.ok) -and ([bool]$colB.ok) -and ([string]$colA.fingerprint -cne [string]$colB.fingerprint)) 'one scope item with comma differs from two items'
    Assert-Recovery (([string]$colC.fingerprint -cne [string]$colD.fingerprint)) 'pipe inside objective cannot shift the scope field'
    Assert-Recovery (([string]$eqA.fingerprint -ceq [string]$eqB.fingerprint)) 'equivalent inputs in other order/case still share the fingerprint'

    # 18. replayed evidence is not novelty, fresh refs are
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-replay-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-replay-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-replay-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed' `
        -EvidenceRefs @('criterion:0:used log line')
    $file = Join-Path $t.tasks 'rec-replay-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $replay = Start-RecoveryAttempt -Id 'rec-replay-001' -Session 'sess-replay-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:used log line')
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$replay.ok) -and ([string]$replay.error -ceq 'STALLED_STRATEGY_REJECTED') -and ($pre -ceq $post))) 'replay of a used evidence ref is not novelty'
    $fresh = Start-RecoveryAttempt -Id 'rec-replay-001' -Session 'sess-replay-b' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:brand new log line')
    Assert-Recovery ([bool]$fresh.ok) 'an unseen evidence ref opens the retry'

    # 19. worker result inherits the bound strategy, divergent rejected
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-bind-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-bind-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-bind-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-bind-001' -Session 'sess-bind-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:bind log')
    Assert-Recovery ([bool]$st.ok) 'bound strategy start opens'
    $boundFp = [string](Get-OrchestrationTask -TaskId 'rec-bind-001' -TasksDir $t.tasks)['execution_runtime']['gate_evidence']['strategy_fingerprint']
    $rBare = Set-OrchestrationTaskWorkerResult -TaskId 'rec-bind-001' -Status 'failed' -ClaimedEvidence @('criterion:0:bind result') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$st.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-bind-001' -TasksDir $t.tasks
    $recFp = [string](@($g['attempts'])[1]['strategy_fingerprint'])
    Assert-Recovery (([bool]$rBare.ok) -and ($recFp -ceq $boundFp) -and (-not [string]::IsNullOrWhiteSpace($recFp))) 'fieldless result inherits the attempt-bound strategy'
    $otherFp = [string](Get-OrchestrationStrategyFingerprint -Approach 'Unrelated third approach' -ToolOrPath 'src/other.js').fingerprint
    $file = Join-Path $t.tasks 'rec-bind-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $div = Set-OrchestrationTaskWorkerResult -TaskId 'rec-bind-001' -Status 'failed' -ClaimedEvidence @('criterion:0:rogue result') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$rBare.revision) -StrategyFingerprint $otherFp `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$div.ok) -and ([string]$div.error -ceq 'STRATEGY_MISMATCH') -and ($pre -ceq $post))) 'divergent worker fingerprint rejected without write'

    # 20. third attempt opened with novelty records without switches
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-noflag-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-noflag-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-noflag-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $f2 = Fail-RecoveryAttempt -Id 'rec-noflag-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $op = Start-RecoveryAttempt -Id 'rec-noflag-001' -Session 'sess-noflag-a' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -Hypothesis 'fresh decomposition path' -DebuggerRefs @('criterion:0:debugger trace')
    Assert-Recovery ([bool]$op.ok) 'novelty start opens attempt 3'
    $cp = Set-OrchestrationTaskWorkerResult -TaskId 'rec-noflag-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$op.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery (([bool]$cp.ok) -and ([string]$cp.worker_status -ceq 'candidate_pass')) 'authorized third attempt records candidate_pass without switches'

    # 21. corrupt active_wait fails closed
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-corrupt-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-corrupt-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $b = Block-OrchestrationTask -TaskId 'rec-corrupt-001' -Actor 'planner' -ExpectedRevision $rev `
        -Reason 'need product decision' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $file = Join-Path $t.tasks 'rec-corrupt-001.json'
    $raw = [IO.File]::ReadAllText($file, [Text.UTF8Encoding]::new($false))
    $cut = ($raw -replace '"type":"human_decision"', '"type":"bogus"')
    Assert-Recovery (($cut -cne $raw)) 'corruption fixture applied'
    [IO.File]::WriteAllText($file, $cut, [Text.UTF8Encoding]::new($false))
    $pre = Get-RecoveryBytes -Path $file
    $un = Invoke-OrchestrationTaskTransition -TaskId 'rec-corrupt-001' -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision ([int]$b.revision) -ActorIdentitySource 'explicit-cli' -WaitFingerprint ([string]$b.wait_fingerprint) `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $rb = Block-OrchestrationTask -TaskId 'rec-corrupt-001' -Actor 'planner' -ExpectedRevision ([int]$b.revision) `
        -Reason 'same wait again' -WaitType 'human_decision' -WaitOwner 'user' -WaitAction 'choose_database' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-corrupt-001' -TasksDir $t.tasks
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$un.ok) -and ([string]$un.error -ceq 'MALFORMED_WAIT') -and (-not [bool]$rb.ok) -and ([string]$rb.error -ceq 'MALFORMED_WAIT') -and ([string]$g['state'] -ceq 'BLOCKED') -and ($pre -ceq $post))) 'corrupt active wait blocks unblock and re-block without mutation'

    # 22. FIX2-1 session binding intact with historical refs
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix21-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix21-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix21-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed' `
        -EvidenceRefs @('criterion:0:historical ref one')
    $st = Start-RecoveryAttempt -Id 'rec-fix21-001' -Session 'sess-fix21-want' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:fresh ref two')
    $g = Get-OrchestrationTask -TaskId 'rec-fix21-001' -TasksDir $t.tasks
    Assert-Recovery (([bool]$st.ok) -and ([string]$g['execution_runtime']['session_id'] -ceq 'sess-fix21-want')) 'historical refs do not clobber the requested session binding'
    $idem = Start-RecoveryAttempt -Id 'rec-fix21-001' -Session 'sess-fix21-want' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:fresh ref two')
    Assert-Recovery (([bool]$idem.ok) -and ([bool]$idem.idempotent)) 'same session plus role stays idempotent after FIX2-1'

    # 23. FIX2-2 kernel-consumed refs are not novelty even when worker omits them
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix22-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix22-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix22-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $s1 = Start-RecoveryAttempt -Id 'rec-fix22-001' -Session 'sess-c1' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:consumed ref R')
    Assert-Recovery ([bool]$s1.ok) 'first authorized retry consumes ref R'
    $r1 = Fail-RecoveryAttempt -Id 'rec-fix22-001' -Rev ([int]$s1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    Assert-Recovery ([bool]$r1.ok) 'failed result without refs records normally'
    $replay = Start-RecoveryAttempt -Id 'rec-fix22-001' -Session 'sess-c2' -Rev ([int]$r1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:consumed ref R') -DebuggerRefs @('criterion:0:debugger trace one')
    $g = Get-OrchestrationTask -TaskId 'rec-fix22-001' -TasksDir $t.tasks
    Assert-Recovery (((-not [bool]$replay.ok) -and (([string]$replay.error -ceq 'STALLED_STRATEGY_REJECTED') -or ([string]$replay.error -ceq 'EXHAUSTED')))) 'replay of kernel-consumed ref alone is rejected'
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix22-002'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix22-002' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $h1 = Fail-RecoveryAttempt -Id 'rec-fix22-002' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $k1 = Start-RecoveryAttempt -Id 'rec-fix22-002' -Session 'sess-c1' -Rev ([int]$h1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:consumed ref R')
    $k2 = Fail-RecoveryAttempt -Id 'rec-fix22-002' -Rev ([int]$k1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $mixed = Start-RecoveryAttempt -Id 'rec-fix22-002' -Session 'sess-c3' -Rev ([int]$k2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -EvidenceRefs @('criterion:0:consumed ref R', 'criterion:0:brand new ref S') -DebuggerRefs @('criterion:0:debugger trace one')
    Assert-Recovery ([bool]$mixed.ok) 'mixed replay with one fresh ref opens'

    # 24. FIX2-3a strategy-less aware start inherits the last strategy
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix23a-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix23a-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix23a-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $f2 = Fail-RecoveryAttempt -Id 'rec-fix23a-001' -Rev ([int]$f1.revision) -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $lastFp = [string](Get-TaskKernelAttemptField -Attempt (@((Get-OrchestrationTask -TaskId 'rec-fix23a-001' -TasksDir $t.tasks)['attempts'])[1]) -Name 'strategy_fingerprint')
    $op = Start-RecoveryAttempt -Id 'rec-fix23a-001' -Session 'sess-inherit-a' -Rev ([int]$f2.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -EvidenceRefs @('criterion:0:inherited strategy fresh log') -DebuggerRefs @('criterion:0:debugger trace two')
    $g = Get-OrchestrationTask -TaskId 'rec-fix23a-001' -TasksDir $t.tasks
    $gateFp = [string]$g['execution_runtime']['gate_evidence']['strategy_fingerprint']
    Assert-Recovery (([bool]$op.ok) -and (-not [string]::IsNullOrWhiteSpace($gateFp)) -and ($gateFp -ceq $lastFp)) 'strategy-less aware start opens with the inherited fingerprint bound'
    $cp = Set-OrchestrationTaskWorkerResult -TaskId 'rec-fix23a-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$op.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Recovery (([bool]$cp.ok) -and ([string]$cp.worker_status -ceq 'candidate_pass')) 'bare result on an inherited binding records candidate_pass'

    # 25. FIX2-3b bound hypothesis wins over divergent worker hypothesis
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix23b-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix23b-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix23b-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed' -Hypothesis 'old root cause guess'
    $st = Start-RecoveryAttempt -Id 'rec-fix23b-001' -Session 'sess-hyp-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -Hypothesis 'bound decomposition path' -EvidenceRefs @('criterion:0:hyp bind log')
    $boundFp = [string](Get-OrchestrationTask -TaskId 'rec-fix23b-001' -TasksDir $t.tasks)['execution_runtime']['gate_evidence']['strategy_fingerprint']
    $div = Set-OrchestrationTaskWorkerResult -TaskId 'rec-fix23b-001' -Status 'failed' -ClaimedEvidence @('criterion:0:rogue result') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$st.revision) -StrategyFingerprint $boundFp -Hypothesis 'rogue divergent guess' `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g = Get-OrchestrationTask -TaskId 'rec-fix23b-001' -TasksDir $t.tasks
    $lastAtt = (@($g['attempts']))[(@($g['attempts'])).Count - 1]
    Assert-Recovery (([bool]$div.ok) -and ([string]$lastAtt['hypothesis'] -ceq 'bound decomposition path') -and ([string]$lastAtt['worker_hypothesis'] -ceq 'rogue divergent guess')) 'divergent worker hypothesis is quarantined and the bound hypothesis wins'
    $t2 = New-RecoveryRoot
    [void]$roots.Add($t2.root)
    $null = New-RecoveryTask -TasksDir $t2.tasks -FlagsPath $t2.flags -Root $t2.root -Id 'rec-fix23b-002'
    $rev2 = Move-RecoveryToImplementing -Id 'rec-fix23b-002' -TasksDir $t2.tasks -FlagsPath $t2.flags -Root $t2.root
    $g1 = Fail-RecoveryAttempt -Id 'rec-fix23b-002' -Rev $rev2 -TasksDir $t2.tasks -FlagsPath $t2.flags -Root $t2.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed' -Hypothesis 'old root cause guess'
    $st2 = Start-RecoveryAttempt -Id 'rec-fix23b-002' -Session 'sess-hyp-b' -Rev ([int]$g1.revision) `
        -TasksDir $t2.tasks -FlagsPath $t2.flags -Root $t2.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -Hypothesis 'bound decomposition path' -EvidenceRefs @('criterion:0:hyp bind log two')
    $boundFp2 = [string](Get-OrchestrationTask -TaskId 'rec-fix23b-002' -TasksDir $t2.tasks)['execution_runtime']['gate_evidence']['strategy_fingerprint']
    $inh = Set-OrchestrationTaskWorkerResult -TaskId 'rec-fix23b-002' -Status 'failed' -ClaimedEvidence @('criterion:0:plain result') `
        -ProducedBy 'coder' -ExpectedRevision ([int]$st2.revision) -StrategyFingerprint $boundFp2 `
        -TasksDir $t2.tasks -FlagsPath $t2.flags -TelemetryRoot $t2.root
    $g2 = Get-OrchestrationTask -TaskId 'rec-fix23b-002' -TasksDir $t2.tasks
    $lastAtt2 = (@($g2['attempts']))[(@($g2['attempts'])).Count - 1]
    Assert-Recovery (([bool]$inh.ok) -and ([string]$lastAtt2['hypothesis'] -ceq 'bound decomposition path')) 'omitted worker hypothesis inherits the bound hypothesis'

    # 26. FIX3 same session with divergent params is never idempotent
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix3a-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix3a-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix3a-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-fix3a-001' -Session 'sess-fix3-a' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log a')
    $ra = Start-RecoveryAttempt -Id 'rec-fix3a-001' -Session 'sess-fix3-a' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Rewrite widget renderer from scratch' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log a')
    Assert-Recovery (([bool]$ra.ok) -and (-not [bool]$ra.idempotent) -and ([int]$ra.revision -eq ([int]$st.revision + 1))) 'changed strategy on the same session is re-authorized, never idempotent'
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix3b-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix3b-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix3b-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-fix3b-001' -Session 'sess-fix3-b' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log b')
    $rb = Start-RecoveryAttempt -Id 'rec-fix3b-001' -Session 'sess-fix3-b' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'second guess path' -EvidenceRefs @('criterion:0:fix3 log b')
    Assert-Recovery (([bool]$rb.ok) -and (-not [bool]$rb.idempotent) -and ([int]$rb.revision -eq ([int]$st.revision + 1))) 'changed hypothesis on the same session is re-authorized, never idempotent'
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix3c-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix3c-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix3c-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-fix3c-001' -Session 'sess-fix3-c' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log c')
    $rc = Start-RecoveryAttempt -Id 'rec-fix3c-001' -Session 'sess-fix3-c' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 fresh c')
    Assert-Recovery (([bool]$rc.ok) -and (-not [bool]$rc.idempotent) -and ([int]$rc.revision -eq ([int]$st.revision + 1))) 'changed evidence refs on the same session are re-authorized, never idempotent'
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix3d-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix3d-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix3d-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-fix3d-001' -Session 'sess-fix3-d' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log d')
    $file = Join-Path $t.tasks 'rec-fix3d-001.json'
    $pre = Get-RecoveryBytes -Path $file
    $rd = Start-RecoveryAttempt -Id 'rec-fix3d-001' -Session 'sess-fix3-d' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Fingerprint 'not-a-fingerprint'
    $post = Get-RecoveryBytes -Path $file
    Assert-Recovery (((-not [bool]$rd.ok) -and ([string]$rd.error -ceq 'INVALID_STRATEGY_FINGERPRINT') -and ($pre -ceq $post))) 'invalid fingerprint on the same session gets a structured error without write, never idempotent'
    $t = New-RecoveryRoot
    [void]$roots.Add($t.root)
    $null = New-RecoveryTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'rec-fix3e-001'
    $rev = Move-RecoveryToImplementing -Id 'rec-fix3e-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root
    $f1 = Fail-RecoveryAttempt -Id 'rec-fix3e-001' -Rev $rev -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' -FailureClass 'worker_failed'
    $st = Start-RecoveryAttempt -Id 'rec-fix3e-001' -Session 'sess-fix3-e' -Rev ([int]$f1.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log e')
    $re = Start-RecoveryAttempt -Id 'rec-fix3e-001' -Session 'sess-fix3-e' -Rev ([int]$st.revision) `
        -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root `
        -Approach 'Patch widget renderer in place' -Tool 'src/widget/render.js' `
        -Hypothesis 'first guess path' -EvidenceRefs @('criterion:0:fix3 log e')
    Assert-Recovery (([bool]$re.ok) -and ([bool]$re.idempotent) -and ([string](Get-OrchestrationTask -TaskId 'rec-fix3e-001' -TasksDir $t.tasks)['execution_runtime']['session_id'] -ceq 'sess-fix3-e')) 'byte-identical retry stays idempotent with the session binding intact'
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
}
finally {
    foreach ($rd in $roots) {
        if (Test-Path -LiteralPath $rd) { Remove-Item -LiteralPath $rd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$script:watch.Stop()
Write-Host ("[SUMMARY] Recovery: {0} passed, {1} failed in {2}ms" -f $script:passed, $script:failed, $script:watch.ElapsedMilliseconds)
Write-Host ("Recovery: {0} / {1} tests passed" -f $script:passed, ($script:passed + $script:failed))
if ($script:failed -gt 0) { exit 1 }
exit 0
