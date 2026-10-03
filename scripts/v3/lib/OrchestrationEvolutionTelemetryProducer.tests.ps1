<#!
.SYNOPSIS
    Tests for lib/OrchestrationEvolutionTelemetryProducer.ps1
    (Phase 41 slice 2, RR-P41-S2-TELEMETRY-PRODUCERS).
.DESCRIPTION
    Hermetic: every dir/file lives under a GUID temp root, cleanup in
    finally. Bracketed output the runner parses. Exit 0 on all pass, exit 1
    on any fail or unexpected exception. PS 5.1. ASCII-only. No network, no
    spawned process (the G9 concurrent-append fixture uses ONE in-process
    background runspace).

    Acceptance coverage:
      AC1 the slice is exactly two new files and no existing lib changed
          (the producer never writes outside the given dirs; asserted by the
          repo-inventory check at the end);
      AC2 honest mapping from synthetic task records + watchdog JSONL to
          counters, and a declared reason for every counter without a real
          source - never a fabricated or zero-filled value;
      AC3 end-to-end with the REAL policy
          source/registry/evolution-policy.json: production into a temp
          -OutDir, then the slice-1 consumer
          (Get-OrchestrationEvolutionSignals / ConvertTo-EvolutionCounters)
          accepts the record with ok=$true;
      AC4 record-only by default (file inventory identical before/after),
          one bounded line per production with -OutDir;
      AC5 bounds: over-cap line refused whole, over-cap file refused
          fail-closed through the exclusive handle, contended handle skipped,
          MaxTaskFiles cap reported (never silent);
      AC6 sanitization: hostile task record fields never leak;
      AC7 determinism: same injected Now => byte-identical record.

    Fixtures use the REAL kernel task-record schema (schema_version, task_id,
    state, review, attempts[].n / .strategy_fingerprint,
    execution_runtime.attempt_role / .attempt_n /
    gate_evidence.strategy_fingerprint, history[], created_at/updated_at), the
    REAL watchdog line shape (task_hash16, class, event, shadow, attempt_n)
    and the REAL OrchestrationEvidenceStore reuse-metrics shape (metric). The
    gate object carries NO attempt number, exactly like the kernel writes it
    (OrchestrationTaskKernel.ps1 L3671-3677): the attempt identity is
    execution_runtime.attempt_n (L3843).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationEvolutionTelemetryProducer.ps1'
$loopPath = Join-Path $PSScriptRoot 'OrchestrationEvolutionLoop.ps1'
. $libPath
# The slice-1 consumer is loaded explicitly on purpose: the producer must not
# need it pre-loaded (it lazy dot-sources it), but the integration assertions
# below verify the real cross-slice contract.
. $loopPath

$script:passed = 0
$script:failed = 0

function Assert-Producer {
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

function Write-TelemetryFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Write-TelemetryJson {
    param([Parameter(Mandatory = $true)][string]$Path, $Doc)
    Write-TelemetryFile -Path $Path -Text (ConvertTo-Json -InputObject $Doc -Depth 10)
}

function Write-TelemetryJsonLines {
    param([Parameter(Mandatory = $true)][string]$Path, [object[]]$Rows, [string[]]$RawLines = @())
    $parts = @()
    foreach ($r in @($Rows)) { $parts += (ConvertTo-Json -InputObject $r -Depth 8 -Compress) }
    foreach ($raw in @($RawLines)) { $parts += [string]$raw }
    Write-TelemetryFile -Path $Path -Text (($parts -join "`n") + "`n")
}

function Copy-EvolutionPolicyWithCaps {
    <#
    .SYNOPSIS
        Real policy with only caps overridden (used for the bound tests).
        Reads the REAL repo policy, so a shape change upstream fails here.
    #>
    param([Parameter(Mandatory = $true)][string]$PolicyPath, [hashtable]$Caps = @{})
    $doc = [IO.File]::ReadAllText($PolicyPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    foreach ($k in @($Caps.Keys)) { $doc.caps.([string]$k) = $Caps[$k] }
    return (ConvertTo-EvolutionOrdered -Node $doc)
}

function Get-TelemetryMapKeys {
    <#
    .SYNOPSIS
        Key list of an accounting map, whether it is still an ordered
        dictionary (in-memory record) or a PSCustomObject (after JSON).
    #>
    param($Map)
    if ($null -eq $Map) { return @() }
    if ($Map -is [System.Collections.IDictionary]) { return @(@($Map.Keys) | ForEach-Object { [string]$_ }) }
    return @(@($Map.PSObject.Properties) | ForEach-Object { [string]$_.Name })
}

function New-TelemetrySizedLine {
    <#
    .SYNOPSIS
        One ASCII JSON object line whose UTF-8 length WITHOUT the terminator is
        exactly -TotalBytes. Used to pin the line cap at exact cap and cap+1.
    #>
    param([Parameter(Mandatory = $true)][int]$TotalBytes, [string]$Hash = 'h')
    $prefix = ('{"task_hash16":"' + $Hash + '","class":"REPEATED_CYCLE","attempt_n":1,"pad":"')
    $suffix = '"}'
    $pad = $TotalBytes - $prefix.Length - $suffix.Length
    if ($pad -lt 1) { throw 'TotalBytes too small for the line envelope' }
    return ($prefix + ('p' * $pad) + $suffix)
}

function Get-TelemetryInventory {
    param([Parameter(Mandatory = $true)][string]$Root)
    $items = @()
    if (Test-Path -LiteralPath $Root) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File)) { $items += ([string]$f.FullName + '|' + [string]$f.Length) }
    }
    return (($items | Sort-Object) -join ';')
}

function New-TelemetryTaskRecord {
    <#
    .SYNOPSIS
        One synthetic-but-real-shaped kernel task record.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$State = 'DONE',
        [string]$Role = '',
        [string[]]$Fingerprints = @(),
        [string]$GateFingerprint = '',
        [int]$RuntimeAttemptN = -1,
        [string]$CreatedAt = '2026-01-02T03:00:00.0000000Z',
        [string]$UpdatedAt = '2026-01-02T03:00:00.0000000Z',
        [string]$ReviewStatus = '',
        [string[]]$HistoryTo = @(),
        [string]$Objective = 'objective text'
    )
    $attempts = @()
    $n = 0
    foreach ($fp in @($Fingerprints)) {
        $n++
        $attempts += [ordered]@{ n = $n; status = 'failed'; strategy_fingerprint = $fp; failure_class = 'unknown'; at = $UpdatedAt }
    }
    $hist = @()
    foreach ($to in @($HistoryTo)) { $hist += [ordered]@{ from = 'EXECUTING'; to = $to; actor = 'task-kernel'; at = $UpdatedAt; revision = 2 } }
    $rec = [ordered]@{
        schema_version    = 1
        task_id           = $TaskId
        objective         = $Objective
        state             = $State
        revision          = 2
        attempt_budget    = 3
        created_at        = $CreatedAt
        updated_at        = $UpdatedAt
        attempts          = @($attempts)
        history           = @($hist)
    }
    if (-not [string]::IsNullOrWhiteSpace($Role)) {
        # REAL kernel shape: the failure recorder appends to attempts[] and
        # writes the record back WITHOUT touching execution_runtime
        # (OrchestrationTaskKernel.ps1 L1661-1682), so the DEFAULT is the
        # post-failure copy (execution_runtime.attempt_n still names the last
        # recorded failure). Pass -RuntimeAttemptN to model the moment the
        # attempt entry point started the NEXT attempt (L3836-3846), which is
        # the only shape in which the persisted gate describes a real attempt
        # that is not in attempts[] yet.
        $rtN = [int]$RuntimeAttemptN
        if ($rtN -lt 1) { $rtN = [int]$n }
        if ($rtN -lt 1) { $rtN = 1 }
        $rec['execution_runtime'] = [ordered]@{
            session_id   = 'sess-1'
            attempt_role = $Role
            attempt_n    = $rtN
            started_at   = $CreatedAt
        }
        # gate_evidence carries NO attempt number: the real gate object
        # (OrchestrationTaskKernel.ps1 L3671-3677) is debugger_refs,
        # new_evidence_refs, strategy_id, strategy_fingerprint, hypothesis.
        if (-not [string]::IsNullOrWhiteSpace($GateFingerprint)) {
            $rec['execution_runtime']['gate_evidence'] = [ordered]@{
                debugger_refs        = @()
                new_evidence_refs    = @()
                strategy_id          = 'sid'
                strategy_fingerprint = $GateFingerprint
                hypothesis           = 'hyp'
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ReviewStatus)) {
        $rec['review'] = [ordered]@{ status = $ReviewStatus; by = 'reviewer-1'; candidate_revision = 2; at = $UpdatedAt; revision = 2 }
    }
    return $rec
}

$AT = '2026-01-02T03:04:05.0000000Z'
$DAY = '20260102'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$realPolicyPath = Join-Path $repoRoot 'source\registry\evolution-policy.json'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-evo-telemetry-' + [guid]::NewGuid().ToString('N'))

try {
    Assert-Producer (Test-Path -LiteralPath $libPath -PathType Leaf) 'AC1 producer library exists'
    Assert-Producer (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'OrchestrationEvolutionTelemetryProducer.tests.ps1') -PathType Leaf) 'AC1 producer test suite exists'
    Assert-Producer (Test-Path -LiteralPath $realPolicyPath -PathType Leaf) 'AC3 real evolution policy is present'

    $tasksDir = Join-Path $tempRoot 'tasks'
    $watchdogDir = Join-Path $tempRoot 'watchdog'
    $metricsPath = Join-Path $tempRoot 'evidence\reuse-metrics.jsonl'
    $outDir = Join-Path $tempRoot 'out'
    foreach ($d in @($tasksDir, $watchdogDir, (Split-Path -Parent $metricsPath), $outDir)) { [void][IO.Directory]::CreateDirectory($d) }

    $realPolicy = [IO.File]::ReadAllText($realPolicyPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json

    # ---------- fixtures (real shapes) ----------
    # Every task record below uses the REAL kernel identity of an attempt:
    # execution_runtime.attempt_n, never a gate field (the real gate object has
    # none). Two shapes are reproduced:
    #   BEFORE the next failure - the attempt entry point started attempt n+1,
    #     so attempts[] holds only n and execution_runtime.attempt_n = n+1: the
    #     persisted gate describes a REAL active attempt and must count.
    #   AFTER a failure - the failure recorder left execution_runtime alone, so
    #     attempts[n] and the gate hold the SAME fingerprint with the SAME
    #     execution_runtime.attempt_n = n: one attempt, one observation.
    # task-1  tester, A/n1 recorded and A/n2 ACTIVE (before next failure): one
    #         real duplicated strategy (2 observations, 1 distinct).
    # task-2  coder, two distinct fingerprints, EXHAUSTED via history.
    # task-3  reviewer, D/n1 + D/n2 recorded, gate D still persisted after the
    #         second failure (execution_runtime.attempt_n = 2): stays 1.
    # task-4  tester, P/n1 + Q/n2 recorded, gate Q persisted after the failure:
    #         no duplication at all.
    # task-5  coder with an approved reviewer verdict only: rounds > findings.
    # task-6  coder, E/n1 recorded, gate E persisted right after that failure
    #         (execution_runtime.attempt_n = 1): still ONE observation.
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-1.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-1' -State 'DONE' -Role 'tester' -Fingerprints @('fp-alpha') -GateFingerprint 'fp-alpha' -RuntimeAttemptN 2 -ReviewStatus 'changes_required' -CreatedAt '2026-01-02T03:00:00.0000000Z' -UpdatedAt '2026-01-02T03:01:00.0000000Z')
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-2.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-2' -State 'EXHAUSTED' -Role 'coder' -Fingerprints @('fp-b', 'fp-c') -HistoryTo @('EXECUTING', 'EXHAUSTED') -CreatedAt '2026-01-02T03:00:00.0000000Z' -UpdatedAt '2026-01-02T03:00:30.0000000Z')
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-3.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-3' -State 'EXECUTING' -Role 'reviewer' -Fingerprints @('fp-d', 'fp-d') -GateFingerprint 'fp-d' -CreatedAt 'not-a-timestamp' -UpdatedAt 'also-not-a-timestamp')
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-4.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-4' -State 'DONE' -Role 'tester' -Fingerprints @('fp-p', 'fp-q') -GateFingerprint 'fp-q' -ReviewStatus 'approved' -CreatedAt '2026-01-02T03:00:00.0000000Z' -UpdatedAt '2026-01-02T03:00:20.0000000Z')
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-5.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-5' -State 'DONE' -Role 'coder' -ReviewStatus 'approved' -CreatedAt '2026-01-02T03:00:00.0000000Z' -UpdatedAt '2026-01-02T03:00:10.0000000Z')
    Write-TelemetryJson -Path (Join-Path $tasksDir 'task-6.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-6' -State 'EXECUTING' -Role 'coder' -Fingerprints @('fp-e') -GateFingerprint 'fp-e')

    # Real watchdog classes only (REPEATED_CYCLE is what the watchdog emits);
    # the bare 'CYCLE' and 'SOMETHING_ELSE' rows are unrecognized and must land
    # in 'other' without counting. The 1 MB line is far over the 4096 cap.
    $hugeLine = '{' + ('"pad":"' + ('x' * 1000000) + '"') + '}'
    Write-TelemetryJsonLines -Path (Join-Path $watchdogDir 'watchdog-20260101.jsonl') -Rows @(
        [ordered]@{ ts = '2026-01-02T03:00:00.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h1'; attempt_n = 1; class = 'REPEATED_ACTION'; would_interrupt = $true; steps = 3; elapsed_s = 10 },
        [ordered]@{ ts = '2026-01-02T03:00:01.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h1'; attempt_n = 2; class = 'REPEATED_ACTION'; would_interrupt = $true; steps = 4; elapsed_s = 20 },
        [ordered]@{ ts = '2026-01-02T03:00:02.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h2'; attempt_n = 1; class = 'REPEATED_CYCLE'; would_interrupt = $true; steps = 2; elapsed_s = 15 },
        [ordered]@{ ts = '2026-01-02T03:00:03.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h6'; attempt_n = 1; class = 'REPEATED_CYCLE'; would_interrupt = $true; steps = 1; elapsed_s = 9 },
        [ordered]@{ ts = '2026-01-02T03:00:04.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'BUDGET_NEAR_LIMIT'; task_hash16 = 'h3'; attempt_n = 1; class = 'BUDGET_NEAR_LIMIT'; would_interrupt = $false; steps = 5; elapsed_s = 30 },
        [ordered]@{ ts = '2026-01-02T03:00:05.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'BUDGET_NEAR_LIMIT'; task_hash16 = 'h5'; attempt_n = 1; class = 'BUDGET_NEAR_LIMIT'; would_interrupt = $false; steps = 6; elapsed_s = 31 },
        [ordered]@{ ts = '2026-01-02T03:00:06.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h4'; attempt_n = 1; class = 'HARD_TIMEOUT'; would_interrupt = $true; steps = 0; elapsed_s = 60 },
        [ordered]@{ ts = '2026-01-02T03:00:07.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h4'; attempt_n = 2; class = 'NO_PROGRESS'; would_interrupt = $true; steps = 1; elapsed_s = 21 },
        [ordered]@{ ts = '2026-01-02T03:00:08.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'WATCHDOG_WOULD_INTERRUPT'; task_hash16 = 'h7'; attempt_n = 1; class = 'CYCLE'; would_interrupt = $true; steps = 1; elapsed_s = 5 },
        [ordered]@{ ts = '2026-01-02T03:00:09.0000000Z'; source = 'watchdog-shadow'; shadow = $true; event = 'UNKNOWN_EVENT'; task_hash16 = 'h8'; attempt_n = 1; class = 'SOMETHING_ELSE'; would_interrupt = $true; steps = 1; elapsed_s = 6 }
    ) -RawLines @('not-json-at-all', '', $hugeLine)

    Write-TelemetryJsonLines -Path $metricsPath -Rows @(
        [ordered]@{ timestamp = '2026-01-02T03:00:00.0000000Z'; metric = 'records_created'; reason = '' },
        [ordered]@{ timestamp = '2026-01-02T03:00:01.0000000Z'; metric = 'records_created'; reason = '' },
        [ordered]@{ timestamp = '2026-01-02T03:00:02.0000000Z'; metric = 'reuse_hits'; reason = '' },
        [ordered]@{ timestamp = '2026-01-02T03:00:03.0000000Z'; metric = 'reuse_misses'; reason = 'source-changed' }
    )

    # ---------- AC2: honest mapping ----------
    $full = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -Now $AT
    Assert-Producer ([bool]$full.ok) 'AC2 production ok with all three real sources' ([string]$full.error)
    $c = $full.counters
    Assert-Producer ([int]$c.tasks -eq 6) 'AC2 tasks = valid records examined' ([string]$c.tasks)
    Assert-Producer ([int]$c.wall_time_s -eq 120) 'AC2 wall_time_s = sum of observed task lifetimes' ([string]$c.wall_time_s)
    Assert-Producer ([int]$c.reviewer_rounds -eq 3) 'AC2 reviewer_rounds = records with a reviewer verdict' ([string]$c.reviewer_rounds)
    Assert-Producer ([int]$c.reviewer_findings -eq 1) 'G10 reviewer_findings = changes_required verdicts (1, a value no other role counter carries)' ([string]$c.reviewer_findings)
    Assert-Producer ([int]$c.tester_rounds -eq 2) 'AC2 tester_rounds = records bound to the tester role' ([string]$c.tester_rounds)
    # G10: the three role counters are pairwise distinct in this fixture (3/1/2),
    # so every assert above fails if two fields were swapped, aliased or filled
    # from the same source. Equal values would make the mapping unverifiable.
    Assert-Producer (([int]$c.reviewer_rounds -ne [int]$c.reviewer_findings) -and ([int]$c.reviewer_rounds -ne [int]$c.tester_rounds) -and ([int]$c.reviewer_findings -ne [int]$c.tester_rounds)) 'G10 reviewer_rounds, reviewer_findings and tester_rounds are genuinely distinct in this fixture' ("rounds=$($c.reviewer_rounds) findings=$($c.reviewer_findings) tester=$($c.tester_rounds)")
    Assert-Producer ([int]$c.tester_duplication_events -eq 1) 'AC2 tester_duplication_events = repeated strategy fingerprints on tester tasks' ([string]$c.tester_duplication_events)
    Assert-Producer ([int]$c.tool_loop_tasks -eq 3) 'G1/AC2 tool_loop_tasks owned by the watchdog source (distinct hashes, REPEATED_ACTION|REPEATED_CYCLE)' ([string]$c.tool_loop_tasks)
    Assert-Producer ([int]$c.budget_exceeded_tasks -eq 1) 'G3/AC2 budget_exceeded_tasks from EXHAUSTED task records, never from BUDGET_NEAR_LIMIT' ([string]$c.budget_exceeded_tasks)
    Assert-Producer ([int]$c.evidence_available -eq 2) 'AC2 evidence_available = records_created metric lines' ([string]$c.evidence_available)
    Assert-Producer ([int]$c.evidence_reused -eq 1) 'AC2 evidence_reused = reuse_hits metric lines' ([string]$c.evidence_reused)
    Assert-Producer ([string]$full.ownership.tool_loop_tasks -ceq 'watchdog') 'AC2 tool_loop_tasks ownership declared as watchdog'
    Assert-Producer ([string]$full.ownership.budget_exceeded_tasks -ceq 'tasks') 'G3 budget_exceeded_tasks ownership is the task records, not the watchdog'
    Assert-Producer ([string]$full.ownership.tasks -ceq 'tasks') 'AC2 tasks ownership declared as tasks'

    # counters with no real source: absent + declared reason, never 0
    foreach ($name in @('jev_calls', 'jev_useful_calls', 'user_interventions')) {
        $present = @($c.PSObject.Properties.Name) -ccontains $name
        $reason = ''
        foreach ($p in @($full.record.unavailable_counters)) { if ([string]$p.counter -ceq $name) { $reason = [string]$p.reason } }
        Assert-Producer ((-not $present) -and ($reason -cmatch '^no-real-source:[a-z-]+$')) ("AC2 counter without real source stays absent with a declared reason: " + $name) $reason
    }
    $fullJson = ConvertTo-Json -InputObject $full.record -Depth 6 -Compress
    Assert-Producer (($fullJson -notmatch '"jev_calls":0') -and ($fullJson -notmatch '"user_interventions":0') -and ($fullJson -notmatch '"jev_useful_calls":0')) 'AC2 never zero-fills a counter without a source'

    # task-owned fallback when the watchdog is not configured (no summing)
    $tasksOnly = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -EvidenceMetricsPath $metricsPath -Now $AT
    Assert-Producer ([int]$tasksOnly.counters.tool_loop_tasks -eq 2) 'AC2 tool_loop_tasks falls back to the task-record derivation' ([string]$tasksOnly.counters.tool_loop_tasks)
    Assert-Producer ([int]$tasksOnly.counters.budget_exceeded_tasks -eq 1) 'AC2 budget_exceeded_tasks = EXHAUSTED task records' ([string]$tasksOnly.counters.budget_exceeded_tasks)
    Assert-Producer ([string]$tasksOnly.ownership.tool_loop_tasks -ceq 'tasks') 'AC2 fallback ownership declared as tasks'

    # ---------- AC6: sanitization ----------
    $hostileDir = Join-Path $tempRoot 'hostile-tasks'
    [void][IO.Directory]::CreateDirectory($hostileDir)
    $hostile = New-TelemetryTaskRecord -TaskId 'task-hostile' -State 'DONE' -Role 'sk-SYNTHETICSECRET' -Fingerprints @('sk-SYNTHETICSECRET') -ReviewStatus 'approved' -Objective 'token=sk-SYNTHETICSECRET' -HistoryTo @('EXHAUSTED')
    Write-TelemetryJson -Path (Join-Path $hostileDir 'task-hostile.json') -Doc $hostile
    $hostileOut = Join-Path $tempRoot 'out-hostile'
    $hostileRun = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $hostileDir -OutDir $hostileOut -Now $AT
    $hostileFile = [IO.File]::ReadAllText((Join-Path $hostileOut ('evolution-telemetry-' + $DAY + '.jsonl')), [Text.UTF8Encoding]::new($false))
    $hostileJson = ConvertTo-Json -InputObject $hostileRun.record -Depth 6 -Compress
    Assert-Producer (($hostileJson -notmatch 'SYNTHETICSECRET') -and ($hostileFile -notmatch 'SYNTHETICSECRET')) 'AC6 canary in hostile task record fields never leaks into the record or the JSONL'
    Assert-Producer ([int]$hostileRun.counters.tester_rounds -eq 0) 'AC6 hostile attempt role does not match the closed tester vocabulary'
    Assert-Producer ([int]$hostileRun.counters.tasks -eq 1) 'AC6 hostile record is still counted as one real task'
    Assert-Producer ([int]$hostileRun.counters.budget_exceeded_tasks -eq 1) 'AC6 budget exhaustion read from history, not from actor text'

    # ---------- AC3: end-to-end with the REAL policy ----------
    $integrationOut = Join-Path $tempRoot 'out-integration'
    $integrated = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -OutDir $integrationOut -Now $AT
    Assert-Producer ([bool]$integrated.written) 'AC3 one line written into the explicit OutDir' ([string]$integrated.write_state)
    $conv = ConvertTo-EvolutionCounters -Record $integrated.record -Policy $realPolicy
    Assert-Producer ([bool]$conv.ok) 'AC3 slice-1 ConvertTo-EvolutionCounters accepts the produced record' ([string]$conv.reason)
    Assert-Producer (@($conv.counters.Keys).Count -eq 10) 'AC3 every produced counter is a declared strict int' ([string]@($conv.counters.Keys).Count)
    $sig = Get-OrchestrationEvolutionSignals -TelemetryDir $integrationOut -PolicyPath $realPolicyPath
    Assert-Producer ([bool]$sig.ok) 'AC3 slice-1 Get-OrchestrationEvolutionSignals ok on the produced telemetry' ([string]$sig.error)
    Assert-Producer ([int]$sig.records_read -eq 1) 'AC3 signals consumed the produced line' ([string]$sig.records_read)
    Assert-Producer ([int]$sig.records_skipped -eq 0) 'AC3 signals skipped nothing (the line was not rejected)' ([string]$sig.records_skipped)
    $byTarget = @{}
    foreach ($t in @($sig.targets)) { $byTarget[[string]$t.target] = $t }
    Assert-Producer ([string]$byTarget['tool_loop_rate'].status -ceq 'ok') 'AC3 tool_loop_rate has data'
    Assert-Producer ([string]$byTarget['tool_loop_rate'].value_text -ceq '0.500000') 'AC3 tool_loop_rate = 3 watchdog loop tasks / 6 tasks' ([string]$byTarget['tool_loop_rate'].value_text)
    Assert-Producer ([string]$byTarget['task_wall_time'].value_text -ceq '20.000000') 'AC3 task_wall_time = 120s / 6 tasks' ([string]$byTarget['task_wall_time'].value_text)
    Assert-Producer ([string]$byTarget['tester_duplication_rate'].value_text -ceq '0.500000') 'AC3 tester_duplication_rate = 1/2' ([string]$byTarget['tester_duplication_rate'].value_text)
    Assert-Producer ([string]$byTarget['reviewer_finding_rate'].value_text -ceq '0.333333') 'G10/AC3 reviewer_finding_rate = 1/3 (findings distinct from rounds)' ([string]$byTarget['reviewer_finding_rate'].value_text)
    Assert-Producer ([string]$byTarget['change_budget_exceed_rate'].value_text -ceq '0.166667') 'AC3 change_budget_exceed_rate = 1/6 (one EXHAUSTED task)' ([string]$byTarget['change_budget_exceed_rate'].value_text)
    Assert-Producer ([string]$byTarget['evidence_reuse_rate'].value_text -ceq '0.500000') 'AC3 evidence_reuse_rate = 1/2' ([string]$byTarget['evidence_reuse_rate'].value_text)
    # Slice-1 aggregation sums records that carry the DENOMINATOR, so a target
    # whose numerator is legitimately absent still aggregates as 0. That is
    # the unchanged slice-1 contract; the producer's own boundary stays honest
    # (the numerator is ABSENT + declared, never emitted as 0). Asserted here
    # so the downstream consequence is visible instead of silently inherited.
    Assert-Producer ([string]$byTarget['user_intervention_rate'].status -ceq 'ok') 'AC3 user_intervention_rate aggregates on the real denominator (slice-1 semantics)'
    Assert-Producer ([string]$byTarget['user_intervention_rate'].value_text -ceq '0.000000') 'AC3 user_intervention_rate downstream value comes from an absent numerator, not an emitted 0'
    $declaredUserIntervention = ''
    foreach ($p in @($integrated.record.unavailable_counters)) { if ([string]$p.counter -ceq 'user_interventions') { $declaredUserIntervention = [string]$p.reason } }
    Assert-Producer ($declaredUserIntervention -cmatch '^no-real-source:human-intervention-signal-not-recorded$') 'AC3 user_interventions is declared unavailable in the record itself' $declaredUserIntervention
    Assert-Producer ([string]$byTarget['jev_useful_call_rate'].status -ceq 'no-data') 'AC3 jev_useful_call_rate is no-data, never 0'

    # ---------- AC4: record-only default + one bounded line ----------
    $roRoot = Join-Path $tempRoot 'record-only'
    $roTasks = Join-Path $roRoot 'tasks'
    [void][IO.Directory]::CreateDirectory($roTasks)
    Write-TelemetryJson -Path (Join-Path $roTasks 'task-ro.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-ro' -State 'DONE' -Role 'coder' -CreatedAt '2026-01-02T03:00:00.0000000Z' -UpdatedAt '2026-01-02T03:00:05.0000000Z')
    $before = Get-TelemetryInventory -Root $roRoot
    $ro = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -Now $AT
    $after = Get-TelemetryInventory -Root $roRoot
    Assert-Producer (([bool]$ro.ok) -and ([bool]$ro.written) -eq $false) 'AC4 record-only run returns the derived record'
    Assert-Producer ([string]$ro.write_state -ceq 'record-only') 'AC4 without -OutDir the write state is record-only' ([string]$ro.write_state)
    Assert-Producer ($before -ceq $after) 'AC4 without -OutDir the file inventory is byte-identical before/after'
    Assert-Producer ([int]$ro.counters.tasks -eq 1) 'AC4 record-only still derives counters'

    $appendOut = Join-Path $tempRoot 'out-append'
    $a1 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -OutDir $appendOut -Now $AT
    $f1 = Join-Path $appendOut ('evolution-telemetry-' + $DAY + '.jsonl')
    $len1 = ([IO.FileInfo]::new($f1)).Length
    $a2 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -OutDir $appendOut -Now $AT
    $len2 = ([IO.FileInfo]::new($f1)).Length
    Assert-Producer (([string]$a1.out_file -ceq ('evolution-telemetry-' + $DAY + '.jsonl')) -and ([long]$a2.line_bytes -gt 0)) 'AC3/AC4 output file name derives from the injected instant'
    Assert-Producer ($len2 -eq ($len1 + [long]$a2.line_bytes)) 'AC4 one bounded line appended per production' ("$len1 -> $len2")
    $lines = @([IO.File]::ReadAllLines($f1) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-Producer ($lines.Count -eq 2) 'AC4 exactly two lines after two productions' ([string]$lines.Count)
    Assert-Producer ([long]$a1.line_bytes -le 4096) 'AC4/AC5 produced line is within max_telemetry_line_bytes' ([string]$a1.line_bytes)

    # ---------- AC7: determinism ----------
    $detA = Join-Path $tempRoot 'det-a'
    $detB = Join-Path $tempRoot 'det-b'
    $d1 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -OutDir $detA -Now $AT
    $d2 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -OutDir $detB -Now $AT
    $detFile = ('evolution-telemetry-' + $DAY + '.jsonl')
    $bytesA = [IO.File]::ReadAllBytes((Join-Path $detA $detFile))
    $bytesB = [IO.File]::ReadAllBytes((Join-Path $detB $detFile))
    $same = ($bytesA.Length -eq $bytesB.Length)
    if ($same) { for ($i = 0; $i -lt $bytesA.Length; $i++) { if ($bytesA[$i] -ne $bytesB[$i]) { $same = $false; break } } }
    Assert-Producer $same 'AC7 two productions with the same Now are byte-identical' ("$($bytesA.Length) vs $($bytesB.Length)")
    $d3 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -Now $AT
    Assert-Producer ((ConvertTo-Json -InputObject $d1.record -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject $d3.record -Depth 6 -Compress)) 'AC7 record-only serialization is identical to the written one'

    # ---------- AC5: bounds ----------
    $tinyLine = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath -Caps @{ max_telemetry_line_bytes = 64 }
    $lineOut = Join-Path $tempRoot 'out-linecap'
    [void][IO.Directory]::CreateDirectory($lineOut)
    $capped = Invoke-OrchestrationTelemetryProduction -Policy $tinyLine -TasksDir $roTasks -OutDir $lineOut -Now $AT
    Assert-Producer (([bool]$capped.written) -eq $false) 'AC5 over-cap line is refused whole'
    Assert-Producer ([string]$capped.write_state -ceq 'refused-line-cap') 'AC5 over-cap line reports refused-line-cap' ([string]$capped.write_state)
    Assert-Producer ([string]$capped.write_error -ceq 'EVOLUTION_TELEMETRY_LINE_CAP') 'AC5 over-cap line reports the bounded error code' ([string]$capped.write_error)
    Assert-Producer ((@(Get-ChildItem -LiteralPath $lineOut -File)).Count -eq 0) 'AC5 nothing is written when the line is over cap'
    Assert-Producer ([bool]$capped.ok) 'AC5 a refused write still returns the derived record'

    $tinyFile = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath -Caps @{ max_telemetry_file_bytes = 4096 }
    $fileOut = Join-Path $tempRoot 'out-filecap'
    [void][IO.Directory]::CreateDirectory($fileOut)
    $target = Join-Path $fileOut ('evolution-telemetry-' + $DAY + '.jsonl')
    [IO.File]::WriteAllText($target, (('x' * 4090) + "`n"), [Text.UTF8Encoding]::new($false))
    $fileCapped = Invoke-OrchestrationTelemetryProduction -Policy $tinyFile -TasksDir (Join-Path $tempRoot 'empty-tasks') -OutDir $fileOut -Now $AT
    Assert-Producer ([string]$fileCapped.write_state -ceq 'refused-file-cap') 'AC5 file cap refuses the append fail-closed' ([string]$fileCapped.write_state)
    Assert-Producer ([string]$fileCapped.write_error -ceq 'EVOLUTION_TELEMETRY_FILE_CAP') 'AC5 file cap reports the bounded error code' ([string]$fileCapped.write_error)
    Assert-Producer (([long]([IO.FileInfo]::new($target)).Length) -eq 4091) 'AC5 the capped file is left untouched'
    [void][IO.Directory]::CreateDirectory((Join-Path $tempRoot 'empty-tasks'))

    $lockOut = Join-Path $tempRoot 'out-locked'
    [void][IO.Directory]::CreateDirectory($lockOut)
    $lockPath = Join-Path $lockOut ('evolution-telemetry-' + $DAY + '.jsonl')
    [IO.File]::WriteAllText($lockPath, '', [Text.UTF8Encoding]::new($false))
    $handle = $null
    try {
        $handle = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $locked = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -OutDir $lockOut -Now $AT
        Assert-Producer (([bool]$locked.written) -eq $false) 'AC5 a contended exclusive handle is skipped, never crashed'
        Assert-Producer ([string]$locked.write_state -ceq 'refused-locked') 'AC5 contended handle reports refused-locked' ([string]$locked.write_state)
        Assert-Producer ([bool]$locked.ok) 'AC5 a contended handle still returns the derived record'
    }
    finally { try { if ($null -ne $handle) { $handle.Dispose() } } catch { } }
    Assert-Producer (([long]([IO.FileInfo]::new($lockPath)).Length) -eq 0) 'AC5 the contended file stays empty'

    $capDir = Join-Path $tempRoot 'cap-tasks'
    [void][IO.Directory]::CreateDirectory($capDir)
    for ($i = 1; $i -le 5; $i++) {
        Write-TelemetryJson -Path (Join-Path $capDir ('task-{0:D2}.json' -f $i)) -Doc (New-TelemetryTaskRecord -TaskId ('task-' + $i) -State 'DONE' -Role 'coder')
    }
    $cappedFiles = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $capDir -MaxTaskFiles 3 -Now $AT
    Assert-Producer ([int]$cappedFiles.record.sources.tasks.files_total -eq 5) 'AC5 MaxTaskFiles reports the declared total'
    Assert-Producer ([int]$cappedFiles.record.sources.tasks.files_examined -eq 3) 'AC5 MaxTaskFiles examines only the cap'
    Assert-Producer ([bool]$cappedFiles.record.sources.tasks.truncated) 'AC5 MaxTaskFiles truncation is never silent'
    Assert-Producer ([int]$cappedFiles.counters.tasks -eq 3) 'AC5 only examined records are counted'

    # hostile task files: unreadable / no identity / over cap, all bounded
    $junkDir = Join-Path $tempRoot 'junk-tasks'
    [void][IO.Directory]::CreateDirectory($junkDir)
    Write-TelemetryFile -Path (Join-Path $junkDir 'a-not-json.json') -Text 'not-json'
    Write-TelemetryJson -Path (Join-Path $junkDir 'b-no-identity.json') -Doc ([ordered]@{ objective = 'no identity here' })
    Write-TelemetryJson -Path (Join-Path $junkDir 'c-empty.json') -Doc ([ordered]@{ schema_version = 1; task_id = '' })
    $junk = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $junkDir -Now $AT
    Assert-Producer ([bool]$junk.ok) 'AC2 hostile task files do not throw'
    Assert-Producer ([int]$junk.counters.tasks -eq 0) 'AC2 records without the kernel identity are not counted as tasks'
    $junkReasons = @(Get-TelemetryMapKeys -Map $junk.record.sources.tasks.skipped_by_reason)
    Assert-Producer (($junkReasons -ccontains 'unparsable-record') -and ($junkReasons -ccontains 'missing-identity')) 'AC2 skip reasons are declared for the hostile records' ($junkReasons -join ',')

    $tinyRecord = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath -Caps @{ max_telemetry_file_bytes = 256 }
    $bigRecord = Invoke-OrchestrationTelemetryProduction -Policy $tinyRecord -TasksDir $tasksDir -Now $AT
    $bigReasons = @(Get-TelemetryMapKeys -Map $bigRecord.record.sources.tasks.skipped_by_reason)
    Assert-Producer (($bigReasons -ccontains 'record-too-large')) 'AC5 an over-cap task record is ignored and counted' ($bigReasons -join ',')

    # watchdog line accounting (bounded reads, every line counted)
    $wdReasons = @(Get-TelemetryMapKeys -Map $full.record.sources.watchdog.skipped_by_reason)
    Assert-Producer (($wdReasons -ccontains 'line-too-long') -and ($wdReasons -ccontains 'unparsable-line') -and ($wdReasons -ccontains 'blank-line')) 'AC5 hostile watchdog lines are counted by reason' ($wdReasons -join ',')
    $emptyForWd = Join-Path $tempRoot 'empty-for-wd'
    $gatePostDir = Join-Path $tempRoot 'gate-post-failure'
    $gateActiveDir = Join-Path $tempRoot 'gate-active'
    foreach ($d in @($emptyForWd, $gatePostDir, $gateActiveDir)) { [void][IO.Directory]::CreateDirectory($d) }
    # AFTER a failure: the gate still holds the fingerprint the failure recorder
    # already copied into attempts[n], and execution_runtime.attempt_n is still
    # n because that recorder does not touch execution_runtime.
    Write-TelemetryJson -Path (Join-Path $gatePostDir 'task-gate-post.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-gate-post' -State 'EXECUTING' -Role 'tester' -Fingerprints @('fp-r') -GateFingerprint 'fp-r')
    # BEFORE the next failure: the attempt entry point started attempt 2, so
    # execution_runtime.attempt_n = 2 names a REAL active attempt that is not in
    # attempts[] yet. This is the shape a gate-only attempt_n lookup can never
    # see, because the real gate object carries no attempt number.
    Write-TelemetryJson -Path (Join-Path $gateActiveDir 'task-gate-active.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-gate-active' -State 'EXECUTING' -Role 'tester' -Fingerprints @('fp-r') -GateFingerprint 'fp-r' -RuntimeAttemptN 2)
    Assert-Producer ([int]$full.record.sources.watchdog.events_by_class.HARD_TIMEOUT -eq 1) 'AC2 HARD_TIMEOUT events are accounted but map to no policy counter'
    Assert-Producer ([int]$full.record.sources.watchdog.events_by_class.NO_PROGRESS -eq 1) 'AC2 NO_PROGRESS events are accounted but map to no policy counter'
    Assert-Producer ([string]$full.record.sources.watchdog.state -ceq 'examined') 'AC2 watchdog source state is declared'
    Assert-Producer ([int]$full.record.sources.tasks.timestamps_invalid -eq 1) 'AC2 unparsable task timestamps contribute 0 and are counted'

    # ---------- G1: the real class vocabulary discriminates ----------
    $wdClasses = $full.record.sources.watchdog.events_by_class
    Assert-Producer ([int]$wdClasses.REPEATED_CYCLE -eq 2) 'G1 REPEATED_CYCLE (the class the watchdog really emits) is recognized'
    Assert-Producer ([int]$wdClasses.REPEATED_ACTION -eq 2) 'G1 REPEATED_ACTION is recognized'
    Assert-Producer ([int]$wdClasses.other -eq 2) 'G1 unrecognized classes (CYCLE, SOMETHING_ELSE) are counted as other'
    Assert-Producer ([int]$wdClasses.BUDGET_NEAR_LIMIT -eq 2) 'G3 BUDGET_NEAR_LIMIT is still accounted observationally'
    Assert-Producer ([int]$full.counters.tool_loop_tasks -eq 3) 'G1 REPEATED_CYCLE hashes count toward tool_loop_tasks (bare CYCLE must not)'
    $watchdogOnly = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir (Join-Path $tempRoot 'empty-for-wd') -WatchdogDir $watchdogDir -Now $AT
    Assert-Producer ([int]$watchdogOnly.counters.tool_loop_tasks -eq 3) 'G1 watchdog alone counts REPEATED_ACTION + REPEATED_CYCLE distinct hashes' ([string]$watchdogOnly.counters.tool_loop_tasks)
    Assert-Producer ([int]$watchdogOnly.counters.budget_exceeded_tasks -eq 0) 'G3 BUDGET_NEAR_LIMIT alone never produces budget_exceeded_tasks' ([string]$watchdogOnly.counters.budget_exceeded_tasks)
    Assert-Producer ([string]$watchdogOnly.record.sources.watchdog.counters_derived -cnotcontains 'budget_exceeded_tasks') 'G3 the watchdog source does not declare budget_exceeded_tasks as derived'

    # ---------- G2: one real attempt is never counted twice ----------
    $taskReasons = @(Get-TelemetryMapKeys -Map $full.record.sources.tasks.skipped_by_reason)
    Assert-Producer (($taskReasons -ccontains 'gate-already-recorded')) 'G2 a gate whose execution_runtime.attempt_n is already recorded is counted, not summed' ($taskReasons -join ',')
    Assert-Producer ([int]$full.counters.tester_duplication_events -eq 1) 'G2 a real ACTIVE gate (task-1: A/n1 recorded + A/n2 active) yields exactly 1 duplicated strategy' ([string]$full.counters.tester_duplication_events)
    Assert-Producer ([int]$tasksOnly.counters.tester_duplication_events -eq 1) 'G2 the duplicated-strategy count survives without the watchdog source' ([string]$tasksOnly.counters.tester_duplication_events)
    Assert-Producer ([int]$tasksOnly.counters.tool_loop_tasks -eq 2) 'G2 a gate already recorded does not manufacture a tool loop (task-4/task-6 stay clean)' ([string]$tasksOnly.counters.tool_loop_tasks)
    Assert-Producer ([int]$tasksOnly.counters.tester_rounds -eq 2) 'G2 the tester-bound task with a distinct-fingerprint gate is still a tester round' ([string]$tasksOnly.counters.tester_rounds)
    $gatePost = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $gatePostDir -Now $AT
    Assert-Producer ([int]$gatePost.counters.tool_loop_tasks -eq 0) 'G2 the post-failure gate copy (execution_runtime.attempt_n == recorded n) is one observation, not a second strategy' ([string]$gatePost.counters.tool_loop_tasks)
    Assert-Producer ([int]$gatePost.counters.tester_duplication_events -eq 0) 'G2 the post-failure gate copy contributes no duplication at all' ([string]$gatePost.counters.tester_duplication_events)

    # ---------- G6: attempt identity is read from execution_runtime ----------
    # The real gate object (OrchestrationTaskKernel.ps1 L3671-3677) carries no
    # attempt number; the kernel writes it on execution_runtime (L3843). Reading
    # the gate instead finds nothing on EVERY real record, so a real ACTIVE gate
    # would be dropped as gate-already-recorded and genuine duplication hidden.
    $gateActive = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $gateActiveDir -Now $AT
    Assert-Producer ([int]$gateActive.counters.tester_duplication_events -eq 1) 'G6 REAL active gate: A/n1 failed + A/n2 active (execution_runtime.attempt_n=2) = 1 duplication' ([string]$gateActive.counters.tester_duplication_events)
    Assert-Producer ([int]$gateActive.counters.tool_loop_tasks -eq 1) 'G6 the same active gate is a real tool loop, not a discarded gate' ([string]$gateActive.counters.tool_loop_tasks)
    $gateActiveReasons = @(Get-TelemetryMapKeys -Map $gateActive.record.sources.tasks.skipped_by_reason)
    Assert-Producer ($gateActiveReasons -cnotcontains 'gate-already-recorded') 'G6 an active gate is never counted as gate-already-recorded' ($gateActiveReasons -join ',')
    $postReasons = @(Get-TelemetryMapKeys -Map $gatePost.record.sources.tasks.skipped_by_reason)
    Assert-Producer ($postReasons -ccontains 'gate-already-recorded') 'G6 the post-failure copy is still accounted as gate-already-recorded, so the fix did not simply count every gate' ($postReasons -join ',')
    $gateRec = Get-EvolutionValue ((New-TelemetryTaskRecord -TaskId 'probe' -Role 'tester' -Fingerprints @('fp-z') -GateFingerprint 'fp-z' -RuntimeAttemptN 2)) 'execution_runtime' $null
    $realGateKeys = @(Get-TelemetryMapKeys -Map (Get-EvolutionValue $gateRec 'gate_evidence' $null))
    Assert-Producer ($realGateKeys -cnotcontains 'attempt_n') 'G6 the fixture reproduces the REAL gate object: no attempt_n inside gate_evidence' ($realGateKeys -join ',')
    Assert-Producer ((@(Get-TelemetryMapKeys -Map $gateRec)) -ccontains 'attempt_n') 'G6 the attempt number lives on execution_runtime, exactly where the producer reads it' (@(Get-TelemetryMapKeys -Map $gateRec) -join ',')
    $postTwoDir = Join-Path $tempRoot 'gate-post-two'
    [void][IO.Directory]::CreateDirectory($postTwoDir)
    Write-TelemetryJson -Path (Join-Path $postTwoDir 'task-gate-post-two.json') -Doc (New-TelemetryTaskRecord -TaskId 'task-gate-post-two' -State 'EXECUTING' -Role 'tester' -Fingerprints @('fp-t', 'fp-t') -GateFingerprint 'fp-t')
    $postTwo = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $postTwoDir -Now $AT
    Assert-Producer ([int]$postTwo.counters.tester_duplication_events -eq 1) 'G6 the post-failure copy of A/n2 (attempts[] = A/n1 + A/n2, execution_runtime.attempt_n = 2) does not double the duplication' ([string]$postTwo.counters.tester_duplication_events)

    # ---------- G3: no budget owner when the task source is absent ----------
    $noTaskSource = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir (Join-Path $tempRoot 'no-such-tasks-dir') -WatchdogDir $watchdogDir -Now $AT
    Assert-Producer (-not (@($noTaskSource.counters.PSObject.Properties.Name) -ccontains 'budget_exceeded_tasks')) 'G3 budget_exceeded_tasks absent when no real source can prove an overrun'
    Assert-Producer ([string]$noTaskSource.unavailable.budget_exceeded_tasks -ceq 'source-absent') 'G3 the absent budget source carries a declared reason' ([string]$noTaskSource.unavailable.budget_exceeded_tasks)

    # ---------- G4: effective memory bound + single-handle caps ----------
    Assert-Producer ([int]$full.record.sources.watchdog.lines_skipped -ge 1) 'G4 an over-cap line is counted' ([string]$full.record.sources.watchdog.lines_skipped)
    $wdReasonsG4 = @(Get-TelemetryMapKeys -Map $full.record.sources.watchdog.skipped_by_reason)
    Assert-Producer (($wdReasonsG4 -ccontains 'line-too-long') -and ($wdReasonsG4 -ccontains 'unparsable-line') -and ($wdReasonsG4 -ccontains 'blank-line')) 'G4 hostile watchdog lines are counted by reason' ($wdReasonsG4 -join ',')
    Assert-Producer ([int]$full.record.sources.watchdog.lines_examined -eq 13) 'G4 every line is still accounted, the 1 MB one included' ([string]$full.record.sources.watchdog.lines_examined)
    Assert-Producer ([int]$full.counters.tool_loop_tasks -eq 3) 'G4 the 1 MB line is discarded without losing the remaining lines'
    Assert-Producer ([long]$full.line_bytes -lt 4096) 'G4 a 1 MB hostile line does not inflate the produced record' ([string]$full.line_bytes)
    $noTerminator = Join-Path $watchdogDir 'watchdog-noterm.jsonl'
    Write-TelemetryFile -Path $noTerminator -Text ('{"task_hash16":"h9","class":"REPEATED_CYCLE","attempt_n":1}')
    $noTermRun = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir (Join-Path $tempRoot 'empty-for-wd') -WatchdogDir $watchdogDir -Now $AT
    Assert-Producer ([int]$noTermRun.counters.tool_loop_tasks -eq 4) 'G4 an unterminated line within the cap is processed' ([string]$noTermRun.counters.tool_loop_tasks)
    Remove-Item -LiteralPath $noTerminator -Force
    $atCap = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath -Caps @{ max_telemetry_file_bytes = 65536 }
    $bigWatchdog = Invoke-OrchestrationTelemetryProduction -Policy $atCap -TasksDir $tasksDir -WatchdogDir $watchdogDir -Now $AT
    $bigWdReasons = @(Get-TelemetryMapKeys -Map $bigWatchdog.record.sources.watchdog.skipped_by_reason)
    Assert-Producer (($bigWdReasons -ccontains 'file-too-large')) 'G4 the JSONL file cap is enforced on the read handle' ($bigWdReasons -join ',')
    Assert-Producer ([int]$bigWatchdog.record.sources.watchdog.files_read -eq 0) 'G4 an over-cap file is never claimed as read'
    Assert-Producer ([int]$bigWatchdog.counters.tool_loop_tasks -eq 2) 'G4 a watchdog over the file cap falls back to the task records' ([string]$bigWatchdog.counters.tool_loop_tasks)
    $heldRecord = Join-Path $gatePostDir 'task-held.json'
    Write-TelemetryJson -Path $heldRecord -Doc (New-TelemetryTaskRecord -TaskId 'task-held' -State 'DONE' -Role 'coder')
    $held = $null
    try {
        $held = [IO.File]::Open($heldRecord, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $heldRun = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $gatePostDir -Now $AT
        $heldReasons = @(Get-TelemetryMapKeys -Map $heldRun.record.sources.tasks.skipped_by_reason)
        Assert-Producer (($heldReasons -ccontains 'file-unreadable')) 'G4 a contended task record is counted fail-closed, never read' ($heldReasons -join ',')
        Assert-Producer ([int]$heldRun.counters.tasks -eq 1) 'G4 the contended record is not counted as a task'
    }
    finally { try { if ($null -ne $held) { $held.Dispose() } } catch { } }

    # ---------- G5: an all-unreadable watchdog source stays unavailable ----------
    $lockedWd = Join-Path $tempRoot 'watchdog-locked'
    [void][IO.Directory]::CreateDirectory($lockedWd)
    $lockedFiles = @()
    for ($i = 1; $i -le 2; $i++) { $lockedFiles += (Join-Path $lockedWd ('watchdog-2026010' + $i + '.jsonl')) }
    foreach ($lf in $lockedFiles) { Write-TelemetryJsonLines -Path $lf -Rows @([ordered]@{ ts = '2026-01-02T03:00:00.0000000Z'; task_hash16 = 'hz'; class = 'REPEATED_CYCLE'; attempt_n = 1 }) }
    $wdHandles = @()
    $g5 = $null
    try {
        foreach ($lf in $lockedFiles) { $wdHandles += [IO.File]::Open($lf, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        $g5 = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $lockedWd -Now $AT
    }
    finally { foreach ($h in @($wdHandles)) { try { if ($null -ne $h) { $h.Dispose() } } catch { } } }
    Assert-Producer ([string]$g5.record.sources.watchdog.state -ceq 'unreadable') 'G5 an all-unreadable watchdog source is unavailable, not zero' ([string]$g5.record.sources.watchdog.state)
    Assert-Producer ([int]$g5.record.sources.watchdog.files_examined -eq 2) 'G5 the discovered files are still reported' ([string]$g5.record.sources.watchdog.files_examined)
    Assert-Producer ([int]$g5.record.sources.watchdog.files_read -eq 0) 'G5 no watchdog file was read'
    Assert-Producer ([int]$g5.counters.tool_loop_tasks -eq 2) 'G5 the task-record fallback prevails instead of being suppressed by zeros' ([string]$g5.counters.tool_loop_tasks)
    Assert-Producer ([string]$g5.ownership.tool_loop_tasks -ceq 'tasks') 'G5 ownership falls back to the task records' ([string]$g5.ownership.tool_loop_tasks)

    # ---------- G7: the line cap holds on BOTH accumulation paths ----------
    # Direct calls to the bounded reader: the segment that ends at a terminator
    # INSIDE the buffer used to be appended without the cap check, so a valid
    # 4096-byte line followed by an LF (or a line larger than the 4 KB buffer)
    # was accumulated and PROCESSED instead of being drained as line-too-long.
    $g7Dir = Join-Path $tempRoot 'g7-linecap'
    [void][IO.Directory]::CreateDirectory($g7Dir)
    $g7Exact = Join-Path $g7Dir 'exact-cap.jsonl'
    [IO.File]::WriteAllText($g7Exact, ((New-TelemetrySizedLine -TotalBytes 512) + "`n"), [Text.UTF8Encoding]::new($false))
    $g7Over = Join-Path $g7Dir 'over-cap.jsonl'
    [IO.File]::WriteAllText($g7Over, ((New-TelemetrySizedLine -TotalBytes 513) + "`n"), [Text.UTF8Encoding]::new($false))
    # a line LARGER than the 4 KB read buffer, so the capped segment is split
    # across several buffer fills and the terminator lands mid-buffer
    $g7BigExact = Join-Path $g7Dir 'exact-cap-8k.jsonl'
    [IO.File]::WriteAllText($g7BigExact, ((New-TelemetrySizedLine -TotalBytes 8192) + "`n"), [Text.UTF8Encoding]::new($false))
    $g7BigOver = Join-Path $g7Dir 'over-cap-8k.jsonl'
    [IO.File]::WriteAllText($g7BigOver, ((New-TelemetrySizedLine -TotalBytes 8193) + "`n"), [Text.UTF8Encoding]::new($false))
    $g7ExactRun = Read-EvolutionTelemetryJsonLines -Path $g7Exact -MaxLines 100 -MaxLineBytes 512 -MaxFileBytes 65536
    Assert-Producer (([bool]$g7ExactRun.ok) -and (@($g7ExactRun.lines).Count -eq 1) -and (@(Get-TelemetryMapKeys -Map $g7ExactRun.skipped_by_reason) -cnotcontains 'line-too-long')) 'G7 a line of EXACTLY max_telemetry_line_bytes with its terminator is accepted whole' (@($g7ExactRun.lines).Count)
    $g7OverRun = Read-EvolutionTelemetryJsonLines -Path $g7Over -MaxLines 100 -MaxLineBytes 512 -MaxFileBytes 65536
    Assert-Producer ((@($g7OverRun.lines).Count -eq 0) -and ((@(Get-TelemetryMapKeys -Map $g7OverRun.skipped_by_reason)) -ccontains 'line-too-long')) 'G7 max_telemetry_line_bytes + 1 with a terminator is refused as line-too-long' (@(Get-TelemetryMapKeys -Map $g7OverRun.skipped_by_reason) -join ',')
    $g7BigExactRun = Read-EvolutionTelemetryJsonLines -Path $g7BigExact -MaxLines 100 -MaxLineBytes 8192 -MaxFileBytes 65536
    Assert-Producer (([bool]$g7BigExactRun.ok) -and (@($g7BigExactRun.lines).Count -eq 1) -and (@(Get-TelemetryMapKeys -Map $g7BigExactRun.skipped_by_reason) -cnotcontains 'line-too-long')) 'G7 a line spanning several buffer fills is still accepted at exactly the cap' (@($g7BigExactRun.lines).Count)
    $g7BigOverRun = Read-EvolutionTelemetryJsonLines -Path $g7BigOver -MaxLines 100 -MaxLineBytes 8192 -MaxFileBytes 65536
    Assert-Producer ((@($g7BigOverRun.lines).Count -eq 0) -and ((@(Get-TelemetryMapKeys -Map $g7BigOverRun.skipped_by_reason)) -ccontains 'line-too-long')) 'G7 a line LARGER than the 4 KB buffer is drained, never materialized past the cap' (@(Get-TelemetryMapKeys -Map $g7BigOverRun.skipped_by_reason) -join ',')

    # ---------- G8: MaxLines is checked BEFORE the line is converted ----------
    $g8Lf = Join-Path $g7Dir 'max-lines-lf.jsonl'
    $g8NoLf = Join-Path $g7Dir 'max-lines-no-lf.jsonl'
    $g8Pair = ((New-TelemetrySizedLine -TotalBytes 128 -Hash 'ha') + "`n") + ((New-TelemetrySizedLine -TotalBytes 128 -Hash 'hb') + "`n")
    [IO.File]::WriteAllText($g8Lf, $g8Pair, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($g8NoLf, ($g8Pair.Substring(0, $g8Pair.Length - 1)), [Text.UTF8Encoding]::new($false))
    $g8LfRun = Read-EvolutionTelemetryJsonLines -Path $g8Lf -MaxLines 1 -MaxLineBytes 4096 -MaxFileBytes 65536
    Assert-Producer (@($g8LfRun.lines).Count -eq 1) 'G8 MaxLines=1 returns exactly one line from a two-LF-terminated file' (@($g8LfRun.lines).Count)
    Assert-Producer (([int]$g8LfRun.examined -eq 2) -and ([bool]$g8LfRun.truncated)) 'G8 the second line is still counted and the truncation is declared' ([string]$g8LfRun.examined)
    Assert-Producer ((@(Get-TelemetryMapKeys -Map $g8LfRun.skipped_by_reason)) -ccontains 'max-lines-reached') 'G8 the excess line is accounted by a declared reason' (@(Get-TelemetryMapKeys -Map $g8LfRun.skipped_by_reason) -join ',')
    $g8NoLfRun = Read-EvolutionTelemetryJsonLines -Path $g8NoLf -MaxLines 1 -MaxLineBytes 4096 -MaxFileBytes 65536
    Assert-Producer ((@($g8NoLfRun.lines).Count -eq 1) -and ([int]$g8NoLfRun.examined -eq 2) -and ([bool]$g8NoLfRun.truncated)) 'G8 parity with the unterminated EOF branch: the same content without the final LF gives the same accounting' (@($g8NoLfRun.lines).Count)

    # ---------- G9: the read is confined to the measured snapshot ----------
    # The read handle allows concurrent writers (FileShare.ReadWrite), so a
    # length checked only once at open cannot bound what is consumed: a file
    # appended to DURING the read would be read past the measured cap and
    # nothing else would notice. One in-process background runspace appends
    # complete watchdog lines while the producer reads; the producer must stop
    # at the snapshot it measured. The fixture anchors on the FIRST appended
    # line before the production starts, so the appender is provably mid-loop
    # (and not finished) when the producer measures, and the assertion is a
    # BOUND: the file holds far more complete lines than the reader may see.
    $g9Dir = Join-Path $tempRoot 'g9-snapshot'
    [void][IO.Directory]::CreateDirectory($g9Dir)
    $g9File = Join-Path $g9Dir 'watchdog-grow.jsonl'
    $g9HeadBytes = 4194304
    $g9LineBytes = 67
    [IO.File]::WriteAllText($g9File, ('{"pad":"' + ('x' * $g9HeadBytes) + '"'), [Text.UTF8Encoding]::new($false))
    $g9StopFlag = Join-Path $g9Dir 'stop.flag'
    $g9AppendScript = {
        param($target, $maxLines, $stopFlag, $lineBytes)
        $h = $null
        $seed = 0
        try {
            $h = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            [void]$h.Seek(0, [IO.SeekOrigin]::End)
            $batch = New-Object System.Collections.ArrayList
            while ($seed -lt $maxLines) {
                if ([IO.File]::Exists($stopFlag)) { break }
                $batch.Clear()
                # The FIRST batch is a single line so the test anchor observes
                # the growth almost immediately; every later batch is paced, so
                # the appender is provably still running when the producer
                # measures its snapshot.
                $size = 25
                if ($seed -eq 0) { $size = 1 }
                for ($i = 0; $i -lt $size; $i++) {
                    if ($seed -ge $maxLines) { break }
                    $seed++
                    $zeros = $seed.ToString('00000')
                    [void]$batch.Add([Text.Encoding]::UTF8.GetBytes(('{"task_hash16":"grown' + $zeros + '","class":"REPEATED_CYCLE","attempt_n":1}' + "`n")))
                }
                foreach ($chunk in @($batch.ToArray())) { $h.Write($chunk, 0, $chunk.Length) }
                $h.Flush()
                Start-Sleep -Milliseconds 5
            }
        }
        catch { }
        finally { try { if ($null -ne $h) { $h.Dispose() } } catch { } }
    }
    $g9Policy = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath -Caps @{ max_telemetry_file_bytes = 33554432 }
    $g9Runner = [powershell]::Create()
    $g9Async = $null
    $g9Run = $null
    $g9AnchorMs = -1
    try {
        $null = $g9Runner.AddScript($g9AppendScript.ToString()).AddArgument($g9File).AddArgument(20000).AddArgument($g9StopFlag).AddArgument($g9LineBytes)
        $g9Async = $g9Runner.BeginInvoke()
        $g9Anchor = [Diagnostics.Stopwatch]::StartNew()
        while (([IO.FileInfo]::new($g9File)).Length -le $g9HeadBytes) {
            if ($g9Anchor.ElapsedMilliseconds -gt 30000) { break }
            Start-Sleep -Milliseconds 1
        }
        $g9AnchorMs = [int]$g9Anchor.ElapsedMilliseconds
        $g9Run = Invoke-OrchestrationTelemetryProduction -Policy $g9Policy -TasksDir $emptyForWd -WatchdogDir $g9Dir -Now $AT
    }
    finally {
        [IO.File]::WriteAllText($g9StopFlag, 'stop')
        if ($null -ne $g9Async) { try { $null = $g9Runner.EndInvoke($g9Async) } catch { } }
        $g9Runner.Dispose()
    }
    $g9FinalBytes = [long]([IO.FileInfo]::new($g9File)).Length
    $g9AppendedLines = [int](($g9FinalBytes - [long]$g9HeadBytes) / [long]$g9LineBytes)
    $g9Bound = ([int]($g9AppendedLines / 3) + 5)
    Assert-Producer (([bool]$g9Run.ok) -and ([string]$g9Run.record.sources.watchdog.state -ceq 'examined')) 'G9 the growing file is read, not refused' ([string]$g9Run.record.sources.watchdog.state)
    Assert-Producer (($g9AnchorMs -lt 30000) -and ($g9AppendedLines -ge 200)) 'G9 the fixture really grew while the producer was reading' ("anchorMs=$g9AnchorMs appended=$g9AppendedLines")
    Assert-Producer ([int]$g9Run.record.sources.watchdog.lines_examined -le $g9Bound) 'G9 the read stops at the measured snapshot instead of following the concurrent appends' ("examined=$($g9Run.record.sources.watchdog.lines_examined) bound=$g9Bound")
    Assert-Producer ([int]$g9Run.counters.tool_loop_tasks -le $g9Bound) 'G9 no watchdog event from beyond the snapshot reaches tool_loop_tasks' ("tool_loop=$($g9Run.counters.tool_loop_tasks) bound=$g9Bound")
    Assert-Producer ((@(Get-TelemetryMapKeys -Map $g9Run.record.sources.watchdog.skipped_by_reason)) -ccontains 'line-too-long') 'G9 the partial over-cap line at the snapshot boundary is handled by the existing line rules' (@(Get-TelemetryMapKeys -Map $g9Run.record.sources.watchdog.skipped_by_reason) -join ',')

    # missing sources: unavailable with a reason, not zero
    $missing = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir (Join-Path $tempRoot 'no-such-dir') -WatchdogDir (Join-Path $tempRoot 'no-such-dir') -EvidenceMetricsPath (Join-Path $tempRoot 'no-such-file.jsonl') -Now $AT
    Assert-Producer ([bool]$missing.ok) 'AC2 a missing source directory is not fatal'
    Assert-Producer (-not (@($missing.counters.PSObject.Properties.Name) -ccontains 'tasks')) 'AC2 tasks absent when the task source does not exist'
    Assert-Producer ([string]$missing.unavailable.tasks -ceq 'source-absent') 'AC2 absent source reason is declared' ([string]$missing.unavailable.tasks)
    Assert-Producer ([string]$missing.record.sources.tasks.state -ceq 'absent') 'AC2 absent source state is declared'

    # evidence without a real reuse metric: unavailable, never invented
    $noReuse = Join-Path $tempRoot 'evidence\no-reuse.jsonl'
    Write-TelemetryJsonLines -Path $noReuse -Rows @([ordered]@{ timestamp = '2026-01-02T03:00:00.0000000Z'; metric = 'records_created'; reason = '' })
    $noReuseRun = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -EvidenceMetricsPath $noReuse -Now $AT
    Assert-Producer ([int]$noReuseRun.counters.evidence_available -eq 1) 'AC2 evidence_available still measured'
    Assert-Producer (-not (@($noReuseRun.counters.PSObject.Properties.Name) -ccontains 'evidence_reused')) 'AC2 evidence_reused absent without a real reuse metric'
    Assert-Producer ([string]$noReuseRun.unavailable.evidence_reused -ceq 'no-source-configured') 'AC2 evidence_reused absent reason is declared' ([string]$noReuseRun.unavailable.evidence_reused)

    # ---------- policy fail-closed ----------
    $badPolicy = Copy-EvolutionPolicyWithCaps -PolicyPath $realPolicyPath
    $badPolicy['automatic_promotion'] = $true
    $badPolicy['authority']['automatic_promotion'] = $true
    $bad = Invoke-OrchestrationTelemetryProduction -Policy $badPolicy -TasksDir $roTasks -Now $AT
    Assert-Producer ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'EVOLUTION_POLICY_INVALID')) 'AC3 invalid policy fails closed, never defaulted' ([string]$bad.error)
    $noPolicy = Invoke-OrchestrationTelemetryProduction -Policy $null -TasksDir $roTasks -Now $AT
    Assert-Producer ([bool]$noPolicy.ok) 'AC3 omitted policy resolves the repo default policy' ([string]$noPolicy.error)

    # invalid injected instant falls back to internal UTC with a note
    $badNow = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $roTasks -Now 'not-an-instant'
    Assert-Producer ([bool]$badNow.ok) 'AC7 an unparsable Now does not fail the production'
    Assert-Producer ([string]$badNow.record.clock_note -ceq 'invalid-now-fallback-to-internal-utc') 'AC7 an unparsable Now leaves a declared clock note' ([string]$badNow.record.clock_note)
    Assert-Producer ([bool]$badNow.ok -and ([string]$badNow.write_state -ceq 'record-only')) 'AC7 record-only holds with an unparsable Now'

    # ---------- AC1: nothing outside the given dirs ----------
    $tasksInventory = Get-TelemetryInventory -Root $tasksDir
    $null = Invoke-OrchestrationTelemetryProduction -Policy $realPolicy -TasksDir $tasksDir -WatchdogDir $watchdogDir -EvidenceMetricsPath $metricsPath -OutDir (Join-Path $tempRoot 'out-isolation') -Now $AT
    Assert-Producer ((Get-TelemetryInventory -Root $tasksDir) -ceq $tasksInventory) 'AC1 source dirs are never mutated by production'
    $repoPolicyAfter = [IO.File]::ReadAllText($realPolicyPath, [Text.UTF8Encoding]::new($false))
    Assert-Producer ($repoPolicyAfter -ceq [IO.File]::ReadAllText($realPolicyPath, [Text.UTF8Encoding]::new($false))) 'AC1 the repo evolution policy is untouched'
}
catch {
    Write-Host ("[FAIL] unexpected exception -- " + $_.Exception.Message)
    $script:failed++
}
finally {
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ('RESULT evolution-telemetry-producer: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0