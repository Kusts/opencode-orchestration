<#!
.SYNOPSIS
    Tests for lib/OrchestrationTaskKernel.ps1 (Phases 9-11).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP, fixture flags files, cleanup in
    finally. Bracketed output the runner parses. Exit 0 on all pass,
    exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-TaskKernel {
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

function Write-TaskKernelFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-TaskKernelTestRoot {
    param([bool]$Enabled = $true)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-task-kernel-' + [guid]::NewGuid().ToString('N'))
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    $flagText = '{"task_kernel":{"enabled":false,"shadow":false}}'
    if ($Enabled) { $flagText = '{"task_kernel":{"enabled":true,"shadow":false}}' }
    Write-TaskKernelFixture -Path $flags -Text $flagText
    return @{ root = $root; tasks = $tasks; flags = $flags }
}

function New-VerifierResultJson {
    param([string]$Status = 'verified_pass', [string[]]$Evidence = @('criterion:0:verified'), [string[]]$CommandClasses = @('test'))
    $o = [ordered]@{
        ok = $true; task_id = 'fixture'; status = $Status; reason = ''
        scope = $null; profiles = @(); evidence = $Evidence; command_classes = $CommandClasses
    }
    return (($o | ConvertTo-Json -Depth 8 -Compress))
}

function Get-TaskBytesHash {
    param([string]$Path)
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)
}

function New-DemoTask {
    param([string]$TasksDir, [string]$FlagsPath, [string]$Root, [string]$Id = 'demo-task-001', [string]$Risk = 'low')
    return (New-OrchestrationTask -TaskId $Id -Objective 'Fix the widget renderer' -TaskType 'implementation' `
        -Risk $Risk -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -RuntimeVersion '1.18.32' -ReadScopes @('src/widget') -WriteScopes @('src/widget') `
        -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('widget renders') -ExpectedArtifacts @('src/widget/render.js') `
        -AttemptBudget 3 -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Root)
}

$roots = New-Object System.Collections.ArrayList

try {
    # 1. create + roundtrip, all fields survive
    $t = New-TaskKernelTestRoot
    [void]$roots.Add($t.root)
    $r = New-OrchestrationTask -TaskId 'round-trip-001' -Objective 'Migrate the cache layer' -TaskType 'implementation' `
        -Risk 'medium' -ParentTaskId 'parent-001' -TraceId 'trace-abc' -OrchestrationDecision 'MULTI_WORKER' -Actor 'planner' `
        -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.0.18' -BaseRevision 'abc123' `
        -ReadScopes @('src/a', 'src/b') -WriteScopes @('src/a') -Grants @('fs.read', 'fs.write') `
        -AcceptanceCriteria @('cache migrates', 'tests green') -ExpectedArtifacts @('src/a/cache.js') `
        -EnvironmentAllowed @('dev') -AttemptBudget 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$r.ok -and ([int]$r.revision -eq 1) -and ([string]$r.state -ceq 'DISCOVERING')) 'create returns ok revision 1 DISCOVERING'
    $g = Get-OrchestrationTask -TaskId 'round-trip-001' -TasksDir $t.tasks
    $rtOk = (([string]$g['task_id'] -ceq 'round-trip-001') -and ([string]$g['objective'] -ceq 'Migrate the cache layer') `
        -and ([string]$g['parent_task_id'] -ceq 'parent-001') -and ([string]$g['trace_id'] -ceq 'trace-abc') `
        -and ([string]$g['risk'] -ceq 'medium') -and ([int]$g['revision'] -eq 1) -and ([int]$g['schema_version'] -eq 1) `
        -and ([string]$g['current_owner'] -ceq 'planner'))
    Assert-TaskKernel $rtOk 'roundtrip preserves scalar fields'
    $rtNested = (([string]$g['runtime']['id'] -ceq 'opencode-v2') -and ([int]$g['runtime']['generation'] -eq 2) `
        -and ((@($g['read_scopes']) -join ',') -ceq 'src/a,src/b') -and ((@($g['write_scopes']) -join ',') -ceq 'src/a') `
        -and ((@($g['acceptance_criteria']) -join '|') -ceq 'cache migrates|tests green') `
        -and ((@($g['environment_authorization']['allowed_environments']) -join ',') -ceq 'dev') `
        -and ([int]$g['attempt_budget'] -eq 3) -and ((@($g['grants']) -join ',') -ceq 'fs.read,fs.write'))
    Assert-TaskKernel $rtNested 'roundtrip preserves nested runtime/scopes/grants'

    # 2. duplicate create: ALREADY_EXISTS with zero byte change, no tmp residue
    $dupFile = Join-Path $t.tasks 'round-trip-001.json'
    $beforeDup = Get-TaskBytesHash -Path $dupFile
    $d = New-OrchestrationTask -TaskId 'round-trip-001' -Objective 'Again' -Actor 'planner' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $afterDup = Get-TaskBytesHash -Path $dupFile
    Assert-TaskKernel ((-not [bool]$d.ok) -and ([string]$d.error -ceq 'ALREADY_EXISTS') -and ($beforeDup -ceq $afterDup)) 'duplicate create returns ALREADY_EXISTS with zero byte change'
    $tmpLeft = @(Get-ChildItem -LiteralPath $t.tasks -File -Filter '*.tmp' -ErrorAction SilentlyContinue)
    Assert-TaskKernel (($tmpLeft.Count -eq 0)) 'duplicate create leaves no temp residue'

    # 3. legal chain DISCOVERING -> PLANNING -> IMPLEMENTING -> VALIDATING -> REVIEWING
    $c = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'chain-001'
    Assert-TaskKernel ([bool]$c.ok) 'chain setup create ok'
    $s1 = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $s2 = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $s3 = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision 3 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $s4 = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision 4 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel (([bool]$s1.ok -and ([int]$s1.revision -eq 2)) -and ([bool]$s2.ok -and ([int]$s2.revision -eq 3)) -and ([bool]$s3.ok -and ([int]$s3.revision -eq 4)) -and ([bool]$s4.ok -and ([int]$s4.revision -eq 5) -and ([string]$s4.to -ceq 'REVIEWING'))) 'legal chain to REVIEWING bumps revision each step'

    # 4. illegal transition, no write
    $file4 = Join-Path $t.tasks 'chain-001.json'
    $before4 = Get-TaskBytesHash -Path $file4
    $ill = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 5 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $after4 = Get-TaskBytesHash -Path $file4
    Assert-TaskKernel ((-not [bool]$ill.ok) -and ([string]$ill.error -ceq 'ILLEGAL_TRANSITION') -and ($before4 -ceq $after4)) 'illegal REVIEWING->IMPLEMENTING rejected with bytes unchanged'

    # 5. CAS conflict, no write
    $cas = Invoke-OrchestrationTaskTransition -TaskId 'chain-001' -ToState 'FIXING' -Actor 'reviewer' -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $after5 = Get-TaskBytesHash -Path $file4
    Assert-TaskKernel ((-not [bool]$cas.ok) -and ([string]$cas.error -ceq 'CAS_CONFLICT') -and ($after4 -ceq $after5)) 'stale ExpectedRevision returns CAS_CONFLICT with bytes unchanged'

    # 6. malformed JSON never throws
    Write-TaskKernelFixture -Path (Join-Path $t.tasks 'broken-001.json') -Text 'not-json{{{'
    $m = Get-OrchestrationTask -TaskId 'broken-001' -TasksDir $t.tasks
    Assert-TaskKernel ((-not [bool]$m.ok) -and ([string]$m.error -ceq 'MALFORMED')) 'malformed file returns MALFORMED without throwing'
    $mn = Get-OrchestrationTask -TaskId 'no-such-task-zzz' -TasksDir $t.tasks
    Assert-TaskKernel ((-not [bool]$mn.ok) -and ([string]$mn.error -ceq 'NOT_FOUND')) 'missing task returns NOT_FOUND'

    # 7. worker result accepts the 3 statuses
    $w = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'worker-001'
    Assert-TaskKernel ([bool]$w.ok) 'worker setup create ok'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'worker-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'worker-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $wr1 = Set-OrchestrationTaskWorkerResult -TaskId 'worker-001' -Status 'blocked' -ClaimedEvidence @('criterion:0:waiting on api') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$wr1.ok -and ([string]$wr1.worker_status -ceq 'blocked')) 'worker blocked accepted'
    $wr2 = Set-OrchestrationTaskWorkerResult -TaskId 'worker-001' -Status 'failed' -ClaimedEvidence @('criterion:0:attempt one log') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$wr2.ok -and ([int]$wr2.attempts -eq 1)) 'worker failed accepted with attempt bookkeeping'
    $wr3 = Set-OrchestrationTaskWorkerResult -TaskId 'worker-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders now') -ProducedBy 'coder' -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$wr3.ok -and ([string]$wr3.worker_status -ceq 'candidate_pass')) 'worker candidate_pass accepted'

    # 8. worker rejects writer-side final claims
    $rj1 = Set-OrchestrationTaskWorkerResult -TaskId 'worker-001' -Status 'verified_pass' -ProducedBy 'coder' -ExpectedRevision 6 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$rj1.ok) -and ([string]$rj1.error -ceq 'STATUS_NOT_ALLOWED_FROM_WORKER')) 'worker verified_pass rejected'
    $rj2 = Set-OrchestrationTaskWorkerResult -TaskId 'worker-001' -Status 'done' -ProducedBy 'coder' -ExpectedRevision 6 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$rj2.ok) -and ([string]$rj2.error -ceq 'STATUS_NOT_ALLOWED_FROM_WORKER')) 'worker done rejected'

    # 9. attempt gates: blocked until debugger/new-evidence flags provided
    $e = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'exhaust-001'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $f1 = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try one') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $f2 = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try two') -ProducedBy 'coder' -ExpectedRevision 4 -Hypothesis 'retry narrower' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g2 = Get-OrchestrationTask -TaskId 'exhaust-001' -TasksDir $t.tasks
    $second = @($g2['attempts'])[1]
    Assert-TaskKernel (([bool]$f1.ok) -and ([bool]$f2.ok) -and ([bool]$second['debugger_required']) -and ([bool]$second['requires_new_evidence'])) 'second failure flags debugger_required and requires_new_evidence'
    $f3blocked = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try three no news') -ProducedBy 'coder' -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$f3blocked.ok) -and ([string]$f3blocked.error -ceq 'ATTEMPT_GATE_FAILED') -and ([string]$f3blocked.reason -ceq 'debugger_required')) 'third attempt without debugger flag blocked (debugger_required)'
    $f3evonly = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try three dbg only') -ProducedBy 'coder' -ExpectedRevision 5 -DebuggerInvoked -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$f3evonly.ok) -and ([string]$f3evonly.error -ceq 'ATTEMPT_GATE_FAILED') -and ([string]$f3evonly.reason -ceq 'new_evidence_required')) 'third attempt with debugger but no new evidence blocked (new_evidence_required)'
    $f3 = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try three with news') -ProducedBy 'coder' -ExpectedRevision 5 -DebuggerInvoked -NewEvidence -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $g3 = Get-OrchestrationTask -TaskId 'exhaust-001' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$f3.ok) -and (-not [bool]$f3.exhausted) -and ([bool](@($g3['attempts'])[2])['debugger_invoked']) -and ([bool](@($g3['attempts'])[2])['new_evidence'])) 'providing both flags unblocks and records them on the attempt'
    $postEx = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-001' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision 6 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$postEx.ok) 'task still alive after gated retry'

    # 9b. EXHAUSTED still fires on budget without new evidence (budget 2)
    $ex2 = New-OrchestrationTask -TaskId 'exhaust-002' -Objective 'Fix the widget renderer' -Actor 'planner' `
        -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -AttemptBudget 2 `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-002' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-002' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-002' -Status 'failed' -ClaimedEvidence @('criterion:0:a') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $fEx = Set-OrchestrationTaskWorkerResult -TaskId 'exhaust-002' -Status 'failed' -ClaimedEvidence @('criterion:0:b no news') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gEx = Get-OrchestrationTask -TaskId 'exhaust-002' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$fEx.ok) -and ([bool]$fEx.exhausted) -and ([string]$gEx['state'] -ceq 'EXHAUSTED')) 'budget-2 second failure without new evidence moves to EXHAUSTED'
    $postEx2 = Invoke-OrchestrationTaskTransition -TaskId 'exhaust-002' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 5 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$postEx2.ok) -and ([string]$postEx2.error -ceq 'ILLEGAL_TRANSITION')) 'EXHAUSTED is terminal'

    # 10. third attempt WITH new evidence survives
    $v = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'retry-001'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'retry-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'retry-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'retry-001' -Status 'failed' -ClaimedEvidence @('criterion:0:a') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'retry-001' -Status 'failed' -ClaimedEvidence @('criterion:0:b') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $f3e = Set-OrchestrationTaskWorkerResult -TaskId 'retry-001' -Status 'failed' -ClaimedEvidence @('criterion:0:c with new hypothesis') -ProducedBy 'coder' -ExpectedRevision 5 -Hypothesis 'new approach' -DebuggerInvoked -NewEvidence -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gv = Get-OrchestrationTask -TaskId 'retry-001' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$f3e.ok) -and (-not [bool]$f3e.exhausted) -and ([string]$gv['state'] -ceq 'IMPLEMENTING') -and ((@($gv['attempts'])).Count -eq 3)) 'third failure with -NewEvidence avoids EXHAUSTED'

    # 11. verification is only written via the verify path
    $p = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'veronly-001'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'veronly-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'veronly-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'veronly-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gp = Get-OrchestrationTask -TaskId 'veronly-001' -TasksDir $t.tasks
    Assert-TaskKernel ($null -eq $gp['verification']) 'verification stays null after worker result alone'
    $vv = Set-OrchestrationTaskVerification -TaskId 'veronly-001' -VerifierEvidenceJson (New-VerifierResultJson -Evidence @('criterion:0:verified by test run')) -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags
    $gp2 = Get-OrchestrationTask -TaskId 'veronly-001' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$vv.ok) -and ([bool]$gp2['verification']['passed']) -and ([string]$gp2['verification']['source'] -ceq 'orchestration-verifier') -and (-not [string]::IsNullOrWhiteSpace([string]$gp2['verification']['result_digest']))) 'verification is written only via Set-OrchestrationTaskVerification with verifier provenance'
    $mm = Set-OrchestrationTaskVerification -TaskId 'veronly-001' -VerifierEvidenceJson (New-VerifierResultJson -Status 'verification_failed' -Evidence @('criterion:0:nope')) -Passed $true -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-TaskKernel ((-not [bool]$mm.ok) -and ([string]$mm.error -ceq 'VERIFIER_RESULT_MISMATCH')) 'caller -Passed true with status verification_failed fails closed'
    $mi = Set-OrchestrationTaskVerification -TaskId 'veronly-001' -VerifierEvidenceJson '{"ok":true,"no_status_here":1}' -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-TaskKernel ((-not [bool]$mi.ok) -and ([string]$mi.error -ceq 'INVALID_VERIFIER_RESULT')) 'verifier result without status rejected'

    # helper: drive a task to REVIEWING with candidate result
    function Invoke-GateFixture {
        param([string]$Id, [string]$Risk = 'low', [string]$Evidence = 'criterion:0:widget renders')
        $null = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id $Id -Risk $Risk
        $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
        $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
        $null = Set-OrchestrationTaskWorkerResult -TaskId $Id -Status 'candidate_pass' -ClaimedEvidence @($Evidence) -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
        $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision 4 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
        $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision 5 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    }

    function Invoke-VerifyFixture {
        param([string]$Id, [int]$Rev, [string]$Evidence = 'criterion:0:verified')
        return (Set-OrchestrationTaskVerification -TaskId $Id -VerifierEvidenceJson (New-VerifierResultJson -Evidence @($Evidence)) -ExpectedRevision $Rev -TasksDir $t.tasks -FlagsPath $t.flags)
    }

    # 12. gate: candidate without verification blocks DONE; DONE only from REVIEWING
    Invoke-GateFixture -Id 'gate-noverify-001'
    $early = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'gate-early-001'
    $ce = Complete-OrchestrationTask -TaskId 'gate-early-001' -Actor 'planner' -ExpectedRevision 1 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$ce.ok) -and ([string]$ce.error -ceq 'ILLEGAL_COMPLETION_STATE')) 'Complete outside REVIEWING rejected with ILLEGAL_COMPLETION_STATE'
    $c1 = Complete-OrchestrationTask -TaskId 'gate-noverify-001' -Actor 'planner' -ExpectedRevision 6 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$c1.ok) -and ([string]$c1.error -ceq 'COMPLETION_GATE_FAILED') -and (@($c1.reasons) -contains 'verification-not-passed')) 'gate blocks DONE when verification is missing'
    $c1b = Complete-OrchestrationTask -TaskId 'gate-noverify-001' -Actor 'planner' -ExpectedRevision 6 -ResidualRisks @('none') -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((@($c1b.reasons) -contains 'orchestration-compliance-missing-or-not-compliant')) 'gate requires COMPLIANT orchestration verdict'

    # 13. gate: verification without review blocks DONE
    Invoke-GateFixture -Id 'gate-noreview-001'
    $null = Invoke-VerifyFixture -Id 'gate-noreview-001' -Rev 6
    $c2 = Complete-OrchestrationTask -TaskId 'gate-noreview-001' -Actor 'planner' -ExpectedRevision 7 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$c2.ok) -and (@($c2.reasons) -contains 'review-not-approved')) 'gate blocks DONE when review is missing'

    # 14. gate: worker claimed evidence alone never satisfies criteria
    Invoke-GateFixture -Id 'gate-nocritev-001' -Evidence 'unrelated worker note'
    $null = Invoke-VerifyFixture -Id 'gate-nocritev-001' -Rev 6 -Evidence 'some log without refs'
    $null = Set-OrchestrationTaskReview -TaskId 'gate-nocritev-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $c3 = Complete-OrchestrationTask -TaskId 'gate-nocritev-001' -Actor 'planner' -ExpectedRevision 8 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$c3.ok) -and (@($c3.reasons) -contains 'criterion-evidence-missing:0')) 'gate blocks DONE when verification evidence lacks criterion refs (claimed ignored)'

    # 15. gate: unresolved blockers block DONE (direct gate on BLOCKED record)
    Invoke-GateFixture -Id 'gate-blocked-001'
    $null = Invoke-VerifyFixture -Id 'gate-blocked-001' -Rev 6
    $null = Set-OrchestrationTaskReview -TaskId 'gate-blocked-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $null = Block-OrchestrationTask -TaskId 'gate-blocked-001' -Actor 'planner' -ExpectedRevision 8 -Reason 'waiting on vendor' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gBlocked = Test-OrchestrationTaskCompletion -TaskId 'gate-blocked-001' -TasksDir $t.tasks -OrchestrationCompliance 'COMPLIANT' -ResidualRisks @('none')
    Assert-TaskKernel ((-not [bool]$gBlocked.complete) -and (@($gBlocked.reasons) -contains 'blockers-unresolved')) 'gate blocks DONE when blockers are unresolved'

    # 16. gate: high risk without security approval blocks DONE
    Invoke-GateFixture -Id 'gate-nosec-001' -Risk 'high'
    $null = Invoke-VerifyFixture -Id 'gate-nosec-001' -Rev 6
    $null = Set-OrchestrationTaskReview -TaskId 'gate-nosec-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $c5 = Complete-OrchestrationTask -TaskId 'gate-nosec-001' -Actor 'planner' -ExpectedRevision 8 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$c5.ok) -and (@($c5.reasons) -contains 'security-review-not-approved')) 'gate blocks high-risk DONE without security approval'

    # 17. happy path e2e writes DONE only when the full gate passes (REAL verifier output)
    . (Join-Path $PSScriptRoot 'OrchestrationVerifier.ps1')
    $hRepo = Join-Path $t.root 'happy-repo'
    New-Item -ItemType Directory -Path $hRepo -Force | Out-Null
    & git -C $hRepo init -b master *>$null
    if ($LASTEXITCODE -ne 0) { & git -C $hRepo init *>$null }
    & git -C $hRepo config user.email 'happy@example.com' *>$null
    & git -C $hRepo config user.name 'Happy Test' *>$null
    & git -C $hRepo config core.autocrlf false *>$null
    & git -C $hRepo config core.safecrlf false *>$null
    Write-TaskKernelFixture -Path (Join-Path $hRepo 'base.txt') -Text "base`n"
    & git -C $hRepo add -A *>$null
    & git -C $hRepo commit -m init -q *>$null
    $hPol = Join-Path $t.root 'happy-policy.json'
    $hProfObj = New-Object PSCustomObject
    $hProfObj | Add-Member -NotePropertyName 'passes' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 0'; timeout_seconds = 60 })
    $hDoc = [ordered]@{ version = 1; default_timeout_seconds = 120; max_output_chars = 4000; profiles = $hProfObj }
    $hJson = (New-Object PSCustomObject -Property $hDoc | ConvertTo-Json -Depth 6 -Compress)
    Write-TaskKernelFixture -Path $hPol -Text $hJson
    $h = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'happy-001'
    Assert-TaskKernel ([bool]$h.ok) 'happy path create ok'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'happy-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'happy-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'happy-001' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision 3 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'happy-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders') -ProducedBy 'coder' -ExpectedRevision 4 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $hv = Invoke-OrchestrationVerifier -TaskId 'happy-001' -RepoRoot $hRepo -BaseRevision 'HEAD' -WriteScopes @() -ProfileNames @('passes') -PolicyPath $hPol -AcceptanceCriteria @('widget renders')
    Assert-TaskKernel (([string]$hv.status -ceq 'verified_pass') -and ((@($hv.evidence) -join '|') -match 'criterion:0:verified')) 'real verifier emits criterion:0:verified for happy path'
    $hvJson = ($hv | ConvertTo-Json -Depth 16 -Compress)
    $null = Set-OrchestrationTaskVerification -TaskId 'happy-001' -VerifierEvidenceJson $hvJson -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags
    $null = Invoke-OrchestrationTaskTransition -TaskId 'happy-001' -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision 6 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskReview -TaskId 'happy-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $done = Complete-OrchestrationTask -TaskId 'happy-001' -Actor 'planner' -ExpectedRevision 8 -ResidualRisks @('none outstanding') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gd = Get-OrchestrationTask -TaskId 'happy-001' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$done.ok) -and ([string]$gd['state'] -ceq 'DONE') -and ([int]$gd['revision'] -eq 9) -and ((@($gd['residual_risks']) -join ',') -ceq 'none outstanding')) 'happy path writes DONE with residual risks and bumped revision'

    # 18. DONE is terminal
    $fileDone = Join-Path $t.tasks 'happy-001.json'
    $beforeDone = Get-TaskBytesHash -Path $fileDone
    $td1 = Invoke-OrchestrationTaskTransition -TaskId 'happy-001' -ToState 'FIXING' -Actor 'planner' -ExpectedRevision 9 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $td2 = Cancel-OrchestrationTask -TaskId 'happy-001' -Actor 'planner' -ExpectedRevision 9 -Reason 'late cancel' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $afterDone = Get-TaskBytesHash -Path $fileDone
    Assert-TaskKernel ((-not [bool]$td1.ok) -and ([string]$td1.error -ceq 'ILLEGAL_TRANSITION') -and (-not [bool]$td2.ok) -and ([string]$td2.error -ceq 'ILLEGAL_TRANSITION') -and ($beforeDone -ceq $afterDone)) 'DONE is immutable for transitions and cancel'

    # 19. grants: effective set is the intersection
    $repoGrants = Get-TaskKernelDefaultGrantsPath
    $eff1 = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read') -GrantsPath $repoGrants)
    Assert-TaskKernel ((($eff1 -join ',')) -ceq 'fs.read') 'task grant outside baseline drops out of effective set'
    $eff2 = @(Get-OrchestrationEffectiveGrants -Role 'reviewer' -TaskGrants @('fs.read', 'fs.write') -GrantsPath $repoGrants)
    Assert-TaskKernel ((($eff2 -join ',')) -ceq 'fs.read') 'read-only role never receives fs.write through intersection'
    $eff3 = @(Get-OrchestrationEffectiveGrants -Role 'no-such-role' -TaskGrants @('fs.read') -GrantsPath $repoGrants)
    Assert-TaskKernel ($eff3.Count -eq 0) 'unknown role yields empty effective set'
    $eff4 = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read', 'destructive.fs') -GrantsPath $repoGrants)
    Assert-TaskKernel ($eff4 -cnotcontains 'destructive.fs') 'sensitive grant without human approval stays out'
    $eff5 = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read', 'destructive.fs') -HumanApproved -GrantsPath $repoGrants)
    Assert-TaskKernel ($eff5 -cnotcontains 'destructive.fs') 'sensitive grant with task grant plus approval but missing runtime/env sets stays out'
    $eff5b = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read', 'destructive.fs') -RuntimeCapabilityGrants @('fs.read', 'destructive.fs') -EnvironmentAuthorizationGrants @('fs.read', 'destructive.fs') -HumanApproved -GrantsPath $repoGrants)
    Assert-TaskKernel (($eff5b -ccontains 'destructive.fs') -and ($eff5b -ccontains 'fs.read')) 'sensitive grant admitted only with all three sets plus approval'
    $eff5c = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read', 'destructive.fs') -RuntimeCapabilityGrants @('fs.read') -EnvironmentAuthorizationGrants @('fs.read', 'destructive.fs') -HumanApproved -GrantsPath $repoGrants)
    Assert-TaskKernel ($eff5c -cnotcontains 'destructive.fs') 'sensitive grant missing from runtime set stays out'
    $effT = @(Get-OrchestrationEffectiveGrants -Role 'tester' -TaskGrants @('fs.read', 'fs.write', 'shell.validation') -RuntimeCapabilityGrants @('fs.read', 'fs.write', 'shell.validation') -EnvironmentAuthorizationGrants @('fs.read', 'fs.write', 'shell.validation') -HumanApproved -GrantsPath $repoGrants)
    Assert-TaskKernel (($effT -cnotcontains 'fs.write') -and ($effT -ccontains 'fs.read')) 'read-only tester role never receives fs.write regardless of inputs'
    $eff6 = @(Get-OrchestrationEffectiveGrants -Role 'coder' -TaskGrants @('fs.read', 'fs.write') -RuntimeCapabilityGrants @() -GrantsPath $repoGrants)
    Assert-TaskKernel ($eff6.Count -eq 0) 'empty runtime capability set empties the intersection'
    $ga = Assert-OrchestrationGrantsJson -Path $repoGrants
    Assert-TaskKernel ([bool]$ga.valid) 'execution-grants.json passes schema assertion'

    # 20. actor identity: untrusted source denied on privileged transitions
    $u = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'ident-001'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'ident-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $fileU = Join-Path $t.tasks 'ident-001.json'
    $beforeU = Get-TaskBytesHash -Path $fileU
    $uu = Invoke-OrchestrationTaskTransition -TaskId 'ident-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'unknown' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $afterU = Get-TaskBytesHash -Path $fileU
    Assert-TaskKernel ((-not [bool]$uu.ok) -and ([string]$uu.error -ceq 'UNTRUSTED_IDENTITY') -and ($beforeU -ceq $afterU)) 'unknown identity denied on privileged transition without write'
    $ut = Invoke-OrchestrationTaskTransition -TaskId 'ident-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'runtime-v2-tool-event' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$ut.ok) 'trusted runtime identity source allowed on privileged transition'
    $uc = Complete-OrchestrationTask -TaskId 'ident-001' -Actor 'planner' -ExpectedRevision 3 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'unknown' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$uc.ok) -and ([string]$uc.error -ceq 'UNTRUSTED_IDENTITY')) 'Complete requires trusted identity'

    # 21. cancel: owner may cancel, non-owner needs trusted identity
    $k = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'cancel-001'
    $kc = Cancel-OrchestrationTask -TaskId 'cancel-001' -Actor 'planner' -ExpectedRevision 1 -Reason 'no longer needed' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gk = Get-OrchestrationTask -TaskId 'cancel-001' -TasksDir $t.tasks
    Assert-TaskKernel (([bool]$kc.ok) -and ([string]$gk['state'] -ceq 'CANCELLED')) 'owner cancel succeeds'
    $k2 = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'cancel-002'
    $kc2 = Cancel-OrchestrationTask -TaskId 'cancel-002' -Actor 'intruder' -ExpectedRevision 1 -Reason 'takeover' -ActorIdentitySource 'unknown' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$kc2.ok) -and ([string]$kc2.error -ceq 'UNTRUSTED_IDENTITY')) 'non-owner cancel with unknown identity denied'
    $kc3 = Cancel-OrchestrationTask -TaskId 'cancel-002' -Actor 'intruder' -ExpectedRevision 1 -Reason 'takeover' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$kc3.ok) 'non-owner cancel with trusted identity succeeds'

    # 22. flags disabled: mutations blocked without write, reads allowed
    $off = New-TaskKernelTestRoot -Enabled $false
    [void]$roots.Add($off.root)
    $no = New-OrchestrationTask -TaskId 'off-001' -Objective 'x' -Actor 'planner' -TasksDir $off.tasks -FlagsPath $off.flags -TelemetryRoot $off.root
    $leftovers = @(Get-ChildItem -LiteralPath $off.tasks -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Assert-TaskKernel ((-not [bool]$no.ok) -and ([string]$no.error -ceq 'KERNEL_DISABLED') -and ($leftovers.Count -eq 0)) 'disabled kernel blocks create without writing'
    $ngo = Get-OrchestrationTask -TaskId 'off-001' -TasksDir $off.tasks
    Assert-TaskKernel ((-not [bool]$ngo.ok) -and ([string]$ngo.error -ceq 'NOT_FOUND')) 'reads stay allowed while kernel is disabled'

    # 23. V1 and V2 records share transition semantics
    $v1 = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'gen-one-001'
    Assert-TaskKernel ([bool]$v1.ok) 'V1 record create ok'
    $v2r = New-OrchestrationTask -TaskId 'gen-two-001' -Objective 'Fix the widget renderer' -Actor 'planner' `
        -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$v2r.ok) 'V2 record create ok'
    $a1 = Invoke-OrchestrationTaskTransition -TaskId 'gen-one-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $b1 = Invoke-OrchestrationTaskTransition -TaskId 'gen-two-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $a2 = Invoke-OrchestrationTaskTransition -TaskId 'gen-one-001' -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision 2 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $b2 = Invoke-OrchestrationTaskTransition -TaskId 'gen-two-001' -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision 2 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $a3 = Invoke-OrchestrationTaskTransition -TaskId 'gen-one-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 3 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $b3 = Invoke-OrchestrationTaskTransition -TaskId 'gen-two-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 3 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel (([bool]$a1.ok -and [bool]$a2.ok -and [bool]$a3.ok) -and ([bool]$b1.ok -and [bool]$b2.ok -and [bool]$b3.ok)) 'V1 and V2 records behave identically across generations'

    # 24. compact status view
    $st = Get-OrchestrationTaskStatus -TaskId 'happy-001' -TasksDir $t.tasks
    Assert-TaskKernel (([string]$st.state -ceq 'DONE') -and ([int]$st.revision -eq 9) -and ([string]$st.worker_status -ceq 'candidate_pass') -and ([bool]$st.verification_passed) -and ([string]$st.review_status -ceq 'approved')) 'status returns compact DONE view'

    # 25. verification_stale: new worker result after verify invalidates the gate
    Invoke-GateFixture -Id 'stale-ver-001'
    $null = Invoke-VerifyFixture -Id 'stale-ver-001' -Rev 6
    $null = Set-OrchestrationTaskReview -TaskId 'stale-ver-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'stale-ver-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:reworked') -ProducedBy 'coder' -ExpectedRevision 8 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskReview -TaskId 'stale-ver-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 9 -TasksDir $t.tasks -FlagsPath $t.flags
    $cStale = Complete-OrchestrationTask -TaskId 'stale-ver-001' -Actor 'planner' -ExpectedRevision 10 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$cStale.ok) -and (@($cStale.reasons) -contains 'verification_stale')) 'new worker result after verify yields verification_stale'

    # 26. review_stale: worker result recorded after approval invalidates review
    Invoke-GateFixture -Id 'stale-rev-001'
    $null = Invoke-VerifyFixture -Id 'stale-rev-001' -Rev 6
    $null = Set-OrchestrationTaskReview -TaskId 'stale-rev-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'stale-rev-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:reworked again') -ProducedBy 'coder' -ExpectedRevision 8 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-VerifyFixture -Id 'stale-rev-001' -Rev 9 -Evidence 'criterion:0:re-verified'
    $cStaleR = Complete-OrchestrationTask -TaskId 'stale-rev-001' -Actor 'planner' -ExpectedRevision 10 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$cStaleR.ok) -and (@($cStaleR.reasons) -contains 'review_stale')) 'worker result after approval yields review_stale even with fresh verification'

    # 27. runtime profile/generation pairing enforced by the gate
    $mm1 = New-OrchestrationTask -TaskId 'prof-mismatch-001' -Objective 'Fix the widget renderer' -Actor 'planner' `
        -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v2' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$mm1.ok) 'mismatched profile record still creatable'
    $gProf = Test-OrchestrationTaskCompletion -TaskId 'prof-mismatch-001' -TasksDir $t.tasks -OrchestrationCompliance 'COMPLIANT' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    Assert-TaskKernel ((@($gProf.reasons) -contains 'runtime_profile_mismatch')) 'generation 1 with profile v2 yields runtime_profile_mismatch'

    # 28. base_stale via -CurrentBaseRevision
    Invoke-GateFixture -Id 'base-stale-001'
    $null = Invoke-VerifyFixture -Id 'base-stale-001' -Rev 6
    $null = Set-OrchestrationTaskReview -TaskId 'base-stale-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $cBase = Complete-OrchestrationTask -TaskId 'base-stale-001' -Actor 'planner' -ExpectedRevision 8 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -CurrentBaseRevision 'deadbeef-moved' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ((-not [bool]$cBase.ok) -and (@($cBase.reasons) -contains 'base_stale')) 'moved base revision yields base_stale'

    # 29. ownership_conflict via -LeasesDir
    . (Join-Path $PSScriptRoot 'OrchestrationOwnership.ps1')
    $leaseRoot = Join-Path $t.root 'leases'
    New-Item -ItemType Directory -Path $leaseRoot -Force | Out-Null
    $lzA = New-OrchestrationWriteLease -TaskId 'owner-task-a' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src/widget') -LocksDir $leaseRoot -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$lzA.ok) 'ownership fixture lease acquired'
    $gOwn = Test-OrchestrationTaskCompletion -TaskId 'gate-noverify-001' -TasksDir $t.tasks -OrchestrationCompliance 'COMPLIANT' -ResidualRisks @('none') -LeasesDir $leaseRoot
    Assert-TaskKernel ((@($gOwn.reasons) -contains 'ownership_conflict')) 'foreign active lease on write scopes yields ownership_conflict'

    # 30. secrets: canary redacted before persistence (objective, task_type, artifacts, evidence)
    $canary = 'sk-SYNTHETICSECRET canary-marker-001'
    $sec1 = New-OrchestrationTask -TaskId 'secret-001' -Objective ('Migrate with token ' + $canary) -Actor 'planner' `
        -TaskType ('custom-type ' + $canary) -ExpectedArtifacts @(('src/art-' + $canary + '.js')) `
        -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-TaskKernel ([bool]$sec1.ok) 'task with secret-like objective creatable'
    $secFile = Join-Path $t.tasks 'secret-001.json'
    $secText = [IO.File]::ReadAllText($secFile, [Text.UTF8Encoding]::new($false))
    Assert-TaskKernel (($secText -notmatch 'sk-SYNTHETICSECRET') -and ($secText -match '\[REDACTED\]')) 'objective/task_type/artifacts canaries persisted redacted'
    $null = Invoke-OrchestrationTaskTransition -TaskId 'secret-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'secret-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'secret-001' -Status 'blocked' -ClaimedEvidence @(('criterion:0:saw ' + $canary)) -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $secText2 = [IO.File]::ReadAllText($secFile, [Text.UTF8Encoding]::new($false))
    Assert-TaskKernel (($secText2 -notmatch 'sk-SYNTHETICSECRET')) 'claimed evidence canary persisted redacted'

    # 31. concurrency: two child processes racing one CAS revision => exactly one wins
    $cc = New-DemoTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'race-001'
    Assert-TaskKernel ([bool]$cc.ok) 'race fixture create ok'
    $cliPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'task-kernel.ps1'
    $childOut1 = Join-Path $t.root 'race1.json'
    $childOut2 = Join-Path $t.root 'race2.json'
    $argTpl = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Action transition -TaskId race-001 -ToState PLANNING -Actor planner -ExpectedRevision 1 -TasksDir "{1}" -FlagsPath "{2}"'
    $psi1 = New-Object System.Diagnostics.ProcessStartInfo
    $psi1.FileName = 'cmd.exe'
    $psi1.Arguments = ($argTpl -f $cliPath, $t.tasks, $t.flags) + (' > "{0}" 2>&1' -f $childOut1)
    $psi1.UseShellExecute = $false
    $psi1.CreateNoWindow = $true
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = 'cmd.exe'
    $psi2.Arguments = ($argTpl -f $cliPath, $t.tasks, $t.flags) + (' > "{0}" 2>&1' -f $childOut2)
    $psi2.UseShellExecute = $false
    $psi2.CreateNoWindow = $true
    $p1 = [System.Diagnostics.Process]::Start($psi1)
    $p2 = [System.Diagnostics.Process]::Start($psi2)
    $p1.WaitForExit(60000)
    $p2.WaitForExit(60000)
    $c1e = $p1.ExitCode
    $c2e = $p2.ExitCode
    try { $p1.Close() } catch { }
    try { $p2.Close() } catch { }
    $codes = @($c1e, $c2e) | Sort-Object
    Assert-TaskKernel ((($codes -join ',') -ceq '0,3')) 'concurrent same-revision transitions: exactly one wins (0) and one CAS_CONFLICT (3)'
    $gRace = Get-OrchestrationTask -TaskId 'race-001' -TasksDir $t.tasks
    Assert-TaskKernel (([int]$gRace['revision'] -eq 2) -and ([string]$gRace['state'] -ceq 'PLANNING')) 'raced record consistent at revision 2'
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

Write-Host ("TaskKernel: {0} / {1} tests passed" -f $script:passed, ($script:passed + $script:failed))
if ($script:failed -gt 0) { exit 1 }
exit 0
