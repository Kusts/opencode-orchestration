<#!
.SYNOPSIS
    Tests for lib/OrchestrationEvolutionLoop.ps1 (Phase 41 slice 1).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP for the evolution store, telemetry
    and eval fixtures; cleanup in finally. Bracketed output the runner
    parses. Exit 0 on all pass, exit 1 on any fail or unexpected exception.
    PS 5.1. ASCII-only.

    Covers the addendum section 18 required tests:
      1. one anecdote does not produce a promotable rule;
      2. repeated evidence (>= min_sample_threshold) creates a candidate;
      3. candidate regression blocks promotion;
      4. successful shadow can be promoted explicitly (with review marker);
      5. rollback restores prior behavior (history recorded).
    Plus: one-at-a-time, missing review marker, sanitization (canary never
    persisted), determinism, hostile telemetry/fixtures (bounded, no
    throw), policy fail-closed, history cap fail-closed, and proof that
    nothing automatic touches the repo policy / capability flags.

    Reviewer/security hardening (directed tests per finding):
      H1 creation is rolled back when its history append fails, so a record
         that cannot be audited never exists;
      H2 'pass' requires FULL declared-target coverage;
      H3 the candidate store is bounded: creation rejects at the cap and
         promotion over an incomplete enumeration fails closed;
      M1 a partially malformed target list invalidates the whole policy;
      M2 telemetry is read incrementally under an explicit load budget;
      M3 candidate identity is immutable content, not the wall clock;
      M4 promotion/rollback re-read the record INSIDE the store lock;
      M5 a failed history append restores VERIFIED, an unverifiable restore
         locks the store until intervention;
      T  mutation tests: real history field values (not variable names) and
         one-at-a-time blocking the candidates on BOTH sides of the promoted
         one.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationEvolutionLoop.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-Evolution {
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

function Write-EvolutionFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-EvolutionPolicyFile {
    <#
    .SYNOPSIS
        Minimal but shape-valid policy for tests (threshold 2, distinct 2,
        tolerance 0.05). Tests override the specific field they exercise.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [hashtable]$Overrides = @{})
    $doc = [ordered]@{
        version                   = 1
        min_sample_threshold      = 2
        min_distinct_refs         = 2
        shadow_comparison_tolerance = 0.05
        promotion_requires        = [ordered]@{ review_marker = $true; shadow_comparison = 'pass' }
        eval                      = [ordered]@{ min_samples_per_variant = 2; require_no_regression = $true; verdicts = @('pass', 'regression', 'inconclusive') }
        eval_targets              = @(
            [ordered]@{ id = 'tester_duplication_rate'; kind = 'rate'; numerator = 'dup_events'; denominator = 'tester_rounds'; direction = 'lower_is_better' },
            [ordered]@{ id = 'task_wall_time'; kind = 'average'; numerator = 'wall_time_s'; denominator = 'tasks'; direction = 'lower_is_better' },
            [ordered]@{ id = 'evidence_reuse_rate'; kind = 'rate'; numerator = 'evidence_reused'; denominator = 'evidence_available'; direction = 'higher_is_better' }
        )
        authority                 = [ordered]@{ mode = 'observation-and-decision-record-only'; automatic_promotion = $false; writes_production_policy = $false }
        caps                      = [ordered]@{
            max_evidence_refs = 20; max_text_length = 500; max_ref_length = 128
            max_review_marker_length = 120; max_reason_length = 240; max_record_bytes = 32768
            max_history_bytes = 1048576; max_candidate_files = 500; max_telemetry_files = 64
            max_telemetry_records = 2000; max_telemetry_line_bytes = 4096; max_telemetry_file_bytes = 4194304
            max_metric_value = 1000000; lock_timeout_ms = 200
        }
    }
    foreach ($k in @($Overrides.Keys)) {
        if ($k -ceq 'promotion_requires') { $doc['promotion_requires'] = [ordered]@{ review_marker = [bool]$Overrides[$k]; shadow_comparison = 'pass' } }
        elseif ($k -ceq 'eval') { $doc['eval'] = $Overrides[$k] }
        elseif ($k -ceq 'caps') { foreach ($ck in @($Overrides[$k].Keys)) { $doc['caps'][[string]$ck] = $Overrides[$k][$ck] } }
        else { $doc[[string]$k] = $Overrides[$k] }
    }
    Write-EvolutionFixture -Path $Path -Text (ConvertTo-Json -InputObject $doc -Depth 8)
    return $Path
}

function New-EvolutionStore {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$Name = 'store')
    $p = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Get-EvolutionTestInstant {
    <#
    .SYNOPSIS
        Normalizes a timestamp VALUE to an ISO-8601 UTC string. PS 7.5
        ConvertFrom-Json materializes date-like JSON strings as [DateTime],
        so an engine-independent comparison needs this seam.
    #>
    param($Value)
    try {
        if ($null -eq $Value) { return '' }
        if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString('o') }
        if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).UtcDateTime.ToString('o') }
        $dto = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)) {
            return $dto.UtcDateTime.ToString('o')
        }
        return [string]$Value
    }
    catch { return '' }
}

$AT = '2026-01-02T03:04:05.0000000Z'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-evolution-' + [guid]::NewGuid().ToString('N'))
$repoPolicy = Join-Path $tempRoot 'policy.json'
$policyNoMarker = Join-Path $tempRoot 'policy-nomarker.json'
$policyMalformed = Join-Path $tempRoot 'policy-malformed.json'
$policyMissing = Join-Path $tempRoot 'policy-missing.json'
$policyDupTarget = Join-Path $tempRoot 'policy-dup-target.json'
$policyNoDirection = Join-Path $tempRoot 'policy-no-direction.json'
$policyBadTarget = Join-Path $tempRoot 'policy-bad-target.json'
$policyTwoTargets = Join-Path $tempRoot 'policy-two-targets.json'
$policyTinyFileBytes = Join-Path $tempRoot 'policy-tiny-file-bytes.json'
$policyCap2 = Join-Path $tempRoot 'policy-cap2.json'
$policyCap3 = Join-Path $tempRoot 'policy-cap3.json'
$teleDir = Join-Path $tempRoot 'telemetry'
New-Item -ItemType Directory -Path $teleDir -Force | Out-Null

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
[void](New-EvolutionPolicyFile -Path $repoPolicy)
[void](New-EvolutionPolicyFile -Path $policyNoMarker -Overrides @{ promotion_requires = $false })
Write-EvolutionFixture -Path $policyMalformed -Text '{"version":1,"min_sample_threshold":"5"'
# V1: a policy whose target list is partially malformed is invalid as a whole
# (never repaired by dropping the bad entry or defaulting its direction).
$threeTargets = @(
    [ordered]@{ id = 'tester_duplication_rate'; kind = 'rate'; numerator = 'dup_events'; denominator = 'tester_rounds'; direction = 'lower_is_better' }
    [ordered]@{ id = 'task_wall_time'; kind = 'average'; numerator = 'wall_time_s'; denominator = 'tasks'; direction = 'lower_is_better' }
    [ordered]@{ id = 'evidence_reuse_rate'; kind = 'rate'; numerator = 'evidence_reused'; denominator = 'evidence_available'; direction = 'higher_is_better' }
)
[void](New-EvolutionPolicyFile -Path $policyDupTarget -Overrides @{ eval_targets = @($threeTargets[0], $threeTargets[1], $threeTargets[0]) })
[void](New-EvolutionPolicyFile -Path $policyNoDirection -Overrides @{ eval_targets = @([ordered]@{ id = 'tester_duplication_rate'; kind = 'rate'; numerator = 'dup_events'; denominator = 'tester_rounds' }, $threeTargets[1]) })
[void](New-EvolutionPolicyFile -Path $policyBadTarget -Overrides @{ eval_targets = @([ordered]@{ id = 'Bad Id!'; kind = 'rate'; numerator = 'dup_events'; denominator = 'tester_rounds'; direction = 'lower_is_better' }, $threeTargets[1]) })
[void](New-EvolutionPolicyFile -Path $policyTwoTargets -Overrides @{ eval_targets = @($threeTargets[0], $threeTargets[2]) })
[void](New-EvolutionPolicyFile -Path $policyTinyFileBytes -Overrides @{ caps = @{ max_telemetry_file_bytes = 64 } })
[void](New-EvolutionPolicyFile -Path $policyCap2 -Overrides @{ caps = @{ max_candidate_files = 2 } })
[void](New-EvolutionPolicyFile -Path $policyCap3 -Overrides @{ caps = @{ max_candidate_files = 3 } })
$teleLines = @(
    '{"dup_events":2,"tester_rounds":4,"wall_time_s":100,"tasks":1,"evidence_reused":1,"evidence_available":4}'
    '{"dup_events":1,"tester_rounds":4,"wall_time_s":140,"tasks":1,"evidence_reused":2,"evidence_available":4}'
)
Write-EvolutionFixture -Path (Join-Path $teleDir 'telemetry-001.jsonl') -Text ($teleLines -join "`n")

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoEvolutionPolicy = Join-Path $repo 'source\registry\evolution-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'
$repoPolicyBefore = ''
$repoFlagsBefore = ''
try {
    $repoPolicyBefore = [IO.File]::ReadAllText($repoEvolutionPolicy, [Text.UTF8Encoding]::new($false))
    $repoFlagsBefore = [IO.File]::ReadAllText($repoFlags, [Text.UTF8Encoding]::new($false))
}
catch { }

function New-EvolutionRefs {
    param([int]$Count, [string]$Prefix = 'ev')
    $refs = @()
    for ($i = 1; $i -le $Count; $i++) { $refs += ($Prefix + '-' + $i.ToString('000')) }
    return ,$refs
}

try {
    # ---- policy (R1) ----
    $shape = Resolve-EvolutionPolicy -PolicyPath $repoPolicy
    Assert-Evolution ([bool]$shape.ok) 'R1 policy shape valid' ([string]$shape.error)
    $missing = Resolve-EvolutionPolicy -PolicyPath $policyMissing
    Assert-Evolution ((-not [bool]$missing.ok) -and ([string]$missing.error -ceq 'EVOLUTION_POLICY_UNAVAILABLE')) 'R1 missing policy fails closed' ([string]$missing.error)
    $malformed = Resolve-EvolutionPolicy -PolicyPath $policyMalformed
    Assert-Evolution ((-not [bool]$malformed.ok) -and ([string]$malformed.error -ceq 'EVOLUTION_POLICY_MALFORMED')) 'R1 malformed policy fails closed' ([string]$malformed.error)
    $repoSlot = Read-EvolutionPolicy -PolicyPath $repoEvolutionPolicy
    $repoTargets = @()
    if ([bool]$repoSlot.found -and -not [bool]$repoSlot.malformed) { $repoTargets = @(Get-EvolutionTargetSpec -Policy $repoSlot.doc) }
    $repoTargetIds = @($repoTargets | ForEach-Object { [string]$_.id })
    $expectedIds = @('tester_duplication_rate', 'tool_loop_rate', 'task_wall_time', 'reviewer_finding_rate', 'change_budget_exceed_rate', 'user_intervention_rate', 'jev_useful_call_rate', 'evidence_reuse_rate')
    $missingIds = @($expectedIds | Where-Object { $repoTargetIds -cnotcontains $_ })
    Assert-Evolution (($repoTargets.Count -eq $expectedIds.Count) -and ($missingIds.Count -eq 0)) 'R1 repo policy declares the 8 addendum eval targets' ($repoTargetIds -join ',')

# V1 (M1): partially malformed target list => whole policy rejected
$dupShape = Resolve-EvolutionPolicy -PolicyPath $policyDupTarget
Assert-Evolution ((-not [bool]$dupShape.ok) -and ([string]$dupShape.error -ceq 'EVOLUTION_POLICY_INVALID')) 'M1 duplicated target invalidates the whole policy' ([string]$dupShape.error)
$dirShape = Resolve-EvolutionPolicy -PolicyPath $policyNoDirection
Assert-Evolution ((-not [bool]$dirShape.ok) -and ([string]$dirShape.error -ceq 'EVOLUTION_POLICY_INVALID')) 'M1 target without direction invalidates the whole policy (no default)' ([string]$dirShape.error)
$badTargetShape = Resolve-EvolutionPolicy -PolicyPath $policyBadTarget
Assert-Evolution ((-not [bool]$badTargetShape.ok) -and ([string]$badTargetShape.error -ceq 'EVOLUTION_POLICY_INVALID')) 'M1 illegal target id invalidates the whole policy' ([string]$badTargetShape.error)
$dupSignals = Get-OrchestrationEvolutionSignals -TelemetryDir $teleDir -PolicyPath $policyDupTarget -AtUtc $AT
Assert-Evolution ((-not [bool]$dupSignals.ok) -and ([string]$dupSignals.error -ceq 'EVOLUTION_POLICY_INVALID')) 'M1 signals also fail closed on a partially malformed policy' ([string]$dupSignals.error)
$validShape = Resolve-EvolutionPolicy -PolicyPath $policyTwoTargets
Assert-Evolution ([bool]$validShape.ok) 'M1 two-target control policy still valid' ([string]$validShape.error)

    # ---- signals (R2) ----
    $signals = Get-OrchestrationEvolutionSignals -TelemetryDir $teleDir -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$signals.ok) 'R2 signals ok' ([string]$signals.error)
    $byTarget = @{}
    foreach ($t in @($signals.targets)) { $byTarget[[string]$t.target] = $t }
    $dup = $byTarget['tester_duplication_rate']
    Assert-Evolution (([int]$dup.numerator -eq 3) -and ([int]$dup.denominator -eq 8) -and ([string]$dup.value_text -ceq '0.375000')) 'R2 rate = sum(num)/sum(den)' ("" + $dup.value_text)
    $wall = $byTarget['task_wall_time']
    Assert-Evolution (([int]$wall.numerator -eq 240) -and ([int]$wall.denominator -eq 2) -and ([string]$wall.value_text -ceq '120.000000')) 'R2 average over tasks' ("" + $wall.value_text)
    Assert-Evolution (([string]$byTarget['evidence_reuse_rate'].value_text -ceq '0.375000')) 'R2 reuse rate aggregated' ("" + $byTarget['evidence_reuse_rate'].value_text)
    $noData = $byTarget['evidence_reuse_rate']
    Assert-Evolution ((@($signals.targets).Count -eq 3) -and (@($signals.targets | Where-Object { [string]$_.status -ceq 'no-data' }).Count -eq 0)) 'R2 all declared targets present, none no-data'

    $fixtureSignals = Get-OrchestrationEvolutionSignals -Fixtures @(
        @{ dup_events = 1; tester_rounds = 5 }, @{ dup_events = 0; tester_rounds = 5 }
    ) -PolicyPath $repoPolicy -AtUtc $AT
    $fxTarget = $null
    foreach ($t in @($fixtureSignals.targets)) { if ([string]$t.target -ceq 'tester_duplication_rate') { $fxTarget = $t } }
    Assert-Evolution (([int]$fixtureSignals.records_read -eq 2) -and ([string]$fxTarget.value_text -ceq '0.100000')) 'R2 injected fixtures aggregate without files' ("" + $fxTarget.value_text)

    $emptySignals = Get-OrchestrationEvolutionSignals -Fixtures @() -PolicyPath $repoPolicy -AtUtc $AT
    $nd = $null
    foreach ($t in @($emptySignals.targets)) { if ([string]$t.target -ceq 'task_wall_time') { $nd = $t } }
    Assert-Evolution (([string]$nd.status -ceq 'no-data') -and ($null -eq $nd.value) -and ([string]$nd.value_text -ceq '')) 'R2 zero denominator is no-data, never 0' ("" + $nd.status)

    $signals2 = Get-OrchestrationEvolutionSignals -TelemetryDir $teleDir -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([string]$signals.signals_hash16 -ceq [string]$signals2.signals_hash16) -and ($signals.signals_hash16 -cmatch '^[0-9a-f]{16}$')) 'R2 signals hash deterministic + stable' ("" + $signals.signals_hash16)
    $sigJson1 = ConvertTo-Json -InputObject $signals -Depth 8 -Compress
    $sigJson2 = ConvertTo-Json -InputObject $signals2 -Depth 8 -Compress
    Assert-Evolution ($sigJson1 -ceq $sigJson2) 'R2 signals byte-identical across runs (same -AtUtc)'

    # hostile telemetry: junk lines, oversized line, non-integer counter, huge value, unknown keys
    $hostileDir = Join-Path $tempRoot 'telemetry-hostile'
    New-Item -ItemType Directory -Path $hostileDir -Force | Out-Null
    $big = ('x' * 5000)
    $hostileLines = @(
        'not json at all'
        ('{"dup_events":"many","tester_rounds":4}')
        ('{"dup_events":99999999,"tester_rounds":4}')
        ('{"unknown_counter":3,"tester_rounds":4}')
        ('{"tasks":1,"wall_time_s":' + $big + '}')
        '{"dup_events":2,"tester_rounds":4,"tasks":1,"wall_time_s":10}'
    )
    Write-EvolutionFixture -Path (Join-Path $hostileDir 'a-001.jsonl') -Text ($hostileLines -join "`n")
    $hostile = Get-OrchestrationEvolutionSignals -TelemetryDir $hostileDir -PolicyPath $repoPolicy -AtUtc $AT
    $hReasons = @($hostile.skipped_by_reason.PSObject.Properties.Name)
    Assert-Evolution ([bool]$hostile.ok) 'R2 hostile telemetry returns ok (no throw)' ([string]$hostile.error)
    Assert-Evolution (([int]$hostile.records_read -eq 2) -and ($hReasons -ccontains 'unparsable-line') -and ($hReasons -ccontains 'invalid-counter:dup_events') -and ($hReasons -ccontains 'line-too-long')) 'R2 hostile lines bounded + counted, invalid counter rejects whole record' (($hReasons -join ',') + ' read=' + $hostile.records_read)
    $hTarget = $null
    foreach ($t in @($hostile.targets)) { if ([string]$t.target -ceq 'tester_duplication_rate') { $hTarget = $t } }
    Assert-Evolution (([string]$hTarget.value_text -ceq '0.250000')) 'R2 hostile run keeps only valid aggregation' ("" + $hTarget.value_text)

    $badDir = Get-OrchestrationEvolutionSignals -TelemetryDir (Join-Path $tempRoot 'nope') -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$badDir.ok) -and ([string]$badDir.error -ceq 'EVOLUTION_TELEMETRY_UNAVAILABLE')) 'R2 missing telemetry dir structured error'
    $badPolicySignals = Get-OrchestrationEvolutionSignals -TelemetryDir $teleDir -PolicyPath $policyMalformed -AtUtc $AT
    Assert-Evolution ((-not [bool]$badPolicySignals.ok) -and ([string]$badPolicySignals.error -ceq 'EVOLUTION_POLICY_MALFORMED')) 'R2 signals fail closed on malformed policy'

    # ---- V2/V7/SEC-4 (M2): bounded incremental load, budget fail-closed ----
    $junkDir = Join-Path $tempRoot 'telemetry-junk'
    New-Item -ItemType Directory -Path $junkDir -Force | Out-Null
    $junkLine = '{"dup_events":"not-an-int","tester_rounds":4}'
    Write-EvolutionFixture -Path (Join-Path $junkDir 'z-999.jsonl') -Text ((1..10000 | ForEach-Object { $junkLine }) -join "`n")
    $junk = Get-OrchestrationEvolutionSignals -TelemetryDir $junkDir -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$junk.ok) -and ([string]$junk.error -ceq 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED')) 'M2 10000 junk lines => structured budget error (invalid lines count against the budget)' ([string]$junk.error)
    Assert-Evolution (([string]$junk.budget -ceq 'max_telemetry_records') -and ([int]$junk.limit -gt 0) -and ($null -eq $junk.targets)) 'M2 budget error names the exceeded budget and returns no partial aggregation' ("" + $junk.budget)
    $oversized = Get-OrchestrationEvolutionSignals -TelemetryDir $teleDir -PolicyPath $policyTinyFileBytes -AtUtc $AT
    Assert-Evolution ((-not [bool]$oversized.ok) -and ([string]$oversized.error -ceq 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED') -and ([string]$oversized.budget -ceq 'max_telemetry_file_bytes')) 'M2 per-file byte budget fails closed (max_telemetry_file_bytes)' ("" + $oversized.budget)
    $fixtureFlood = @()
    for ($i = 1; $i -le 2001; $i++) { $fixtureFlood += @{ dup_events = 1; tester_rounds = 4 } }
    $fixtureBudget = Get-OrchestrationEvolutionSignals -Fixtures $fixtureFlood -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$fixtureBudget.ok) -and ([string]$fixtureBudget.error -ceq 'EVOLUTION_TELEMETRY_BUDGET_EXCEEDED')) 'M2 injected fixtures share the same record budget' ([string]$fixtureBudget.error)
    $boundedDir = Join-Path $tempRoot 'telemetry-bounded'
    New-Item -ItemType Directory -Path $boundedDir -Force | Out-Null
    Write-EvolutionFixture -Path (Join-Path $boundedDir 'b-001.jsonl') -Text (($teleLines -join "`n") + "`n" + '{"dup_events":1,"tester_rounds":2}')
    $bounded = Get-OrchestrationEvolutionSignals -TelemetryDir $boundedDir -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$bounded.ok) -and ([int]$bounded.records_read -eq 3)) 'M2 incremental read still aggregates a normal file completely' ("" + $bounded.records_read)

    # ---- required test 1: one anecdote does not produce a promotable rule (R3) ----
    $store1 = New-EvolutionStore -Root $tempRoot -Name 'store-anecdote'
    $anecdote = New-OrchestrationEvolutionCandidate -Problem 'tester re-ran the same suite once' `
        -RepeatedEvidenceRefs @('ev-001') -GeneralizedCause 'possible slow tester path' `
        -ProposedChange 'cache suite result' -ExpectedEffect 'fewer reruns' `
        -Risk 'low' -RollbackPlan 'drop the cache' -StoreDir $store1 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$anecdote.ok) -and ([string]$anecdote.status -ceq 'rejected-threshold') -and ([int]$anecdote.sample_count -eq 1)) 'T1 one anecdote rejected-threshold (structured)' ("" + $anecdote.status)
    Assert-Evolution (([string]$anecdote.error -ceq '') -and ([int]$anecdote.min_sample_threshold -eq 2) -and ([string]$anecdote.production_mutation -ceq 'none')) 'T1 rejection reports threshold + no production mutation'
    $list1 = @(Get-OrchestrationEvolutionCandidateList -StoreDir $store1 -Policy $repoPolicy)
    Assert-Evolution (($list1.Count -eq 0) -and (-not (Test-Path -LiteralPath (Join-Path $store1 'candidates') -PathType Container))) 'T1 nothing written below threshold'
    $hist1 = Get-OrchestrationEvolutionHistory -StoreDir $store1
    Assert-Evolution (([int]$hist1.count -eq 0)) 'T1 no history event below threshold'
    $promoteAnecdote = Approve-OrchestrationEvolutionCandidate -CandidateId 'evc-0000000000000000' -ReviewMarker 'review:REV1' -EvalVerdict 'pass' -StoreDir $store1 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteAnecdote.ok) -and ([string]$promoteAnecdote.error -ceq 'EVOLUTION_CANDIDATE_NOT_FOUND')) 'T1 no promotable id without a stored candidate'

    # duplicate refs (one anecdote repeated) must not pass the distinct guard
    $storeDup = New-EvolutionStore -Root $tempRoot -Name 'store-duprefs'
    $dupRefs = New-OrchestrationEvolutionCandidate -Problem 'same single incident repeated' `
        -RepeatedEvidenceRefs @('ev-001', 'ev-001', 'ev-001', 'ev-001') -GeneralizedCause 'unknown yet' `
        -ProposedChange 'tighten the contract' -ExpectedEffect 'clearer failures' `
        -Risk 'low' -RollbackPlan 'revert prompt' -StoreDir $storeDup -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$dupRefs.ok) -and ([int]$dupRefs.sample_count -eq 4) -and ([int]$dupRefs.distinct_refs -eq 1)) 'T1 duplicated refs are not repeated evidence' ("" + $dupRefs.distinct_refs)

    # ---- required test 2: repeated evidence creates a candidate (R3) ----
    $store2 = New-EvolutionStore -Root $tempRoot -Name 'store-repeated'
    $created = New-OrchestrationEvolutionCandidate -Problem 'tester re-ran the same suite repeatedly' `
        -RepeatedEvidenceRefs (New-EvolutionRefs -Count 4) -GeneralizedCause 'tester loop lacks a cached suite result' `
        -ProposedChange 'add a bounded suite-result cache' -ExpectedEffect 'lower tester duplication rate' `
        -Risk 'medium: stale cache' -RollbackPlan 'remove the cache file and revert the prompt line' `
        -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$created.ok) 'T2 repeated evidence creates candidate' ([string]$created.error)
    Assert-Evolution (([string]$created.status -ceq 'candidate') -and ([int]$created.sample_count -eq 4) -and ([string]$created.candidate_id -cmatch '^evc-[0-9a-f]{16}$')) 'T2 candidate id is a stable hash' ("" + $created.candidate_id)
    $stored = Get-OrchestrationEvolutionCandidate -StoreDir $store2 -CandidateId ([string]$created.candidate_id)
    Assert-Evolution ([bool]$stored.ok) 'T2 candidate persisted' ([string]$stored.error)
    $rec = $stored.record
    $recordText = ConvertTo-Json -InputObject $rec -Depth 8 -Compress
    Assert-Evolution (([string]$rec.record_type -ceq 'EVOLUTION_CANDIDATE') -and ([string]$rec.status -ceq 'candidate') -and ([string]$rec.automatic_promotion -ceq 'False') -and ([string]$rec.production_mutation -ceq 'none')) 'T2 record shape: candidate + no automatic promotion'
    Assert-Evolution ((@($rec.repeated_evidence).Count -eq 4) -and (-not [string]::IsNullOrWhiteSpace([string]$rec.rollback_plan))) 'T2 repeated evidence + rollback plan recorded'
    $idempotent = New-OrchestrationEvolutionCandidate -Problem 'tester re-ran the same suite repeatedly' `
        -RepeatedEvidenceRefs (New-EvolutionRefs -Count 4) -GeneralizedCause 'tester loop lacks a cached suite result' `
        -ProposedChange 'add a bounded suite-result cache' -ExpectedEffect 'lower tester duplication rate' `
        -Risk 'medium: stale cache' -RollbackPlan 'remove the cache file and revert the prompt line' `
        -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$idempotent.ok) -and ([string]$idempotent.candidate_id -ceq [string]$created.candidate_id)) 'T2 identical candidate is idempotent (content-addressed)' ("" + $idempotent.candidate_id)
    $hist2 = Get-OrchestrationEvolutionHistory -StoreDir $store2 -CandidateId ([string]$created.candidate_id)
    Assert-Evolution (([int]$hist2.count -eq 1) -and ([string]$hist2.events[0].event -ceq 'created')) 'T2 creation recorded in history' ("" + $hist2.count)

    # ---- V3 (M3): identity is immutable content, not the wall clock ----
    $recreated = New-OrchestrationEvolutionCandidate -Problem 'tester re-ran the same suite repeatedly' `
        -RepeatedEvidenceRefs (New-EvolutionRefs -Count 4) -GeneralizedCause 'tester loop lacks a cached suite result' `
        -ProposedChange 'add a bounded suite-result cache' -ExpectedEffect 'lower tester duplication rate' `
        -Risk 'medium: stale cache' -RollbackPlan 'remove the cache file and revert the prompt line' `
        -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc '2026-06-07T08:09:10.0000000Z'
    Assert-Evolution (([bool]$recreated.ok) -and ([string]$recreated.candidate_id -ceq [string]$created.candidate_id)) 'M3 same payload at a different instant is idempotent, not a conflict' ("" + $recreated.error)
    $afterRecreate = Get-OrchestrationEvolutionCandidate -StoreDir $store2 -CandidateId ([string]$created.candidate_id)
    Assert-Evolution ((Get-EvolutionTestInstant $afterRecreate.record.created_at) -ceq (Get-EvolutionTestInstant $AT)) 'M3 the stored record is preserved (first instant kept)' ("" + $afterRecreate.record.created_at)
    $hist2b = Get-OrchestrationEvolutionHistory -StoreDir $store2 -CandidateId ([string]$created.candidate_id)
    Assert-Evolution ([int]$hist2b.count -eq 1) 'M3 idempotent re-creation does not duplicate history' ("" + $hist2b.count)

    # sanitization: secret canary must never be persisted anywhere
    $storeSan = New-EvolutionStore -Root $tempRoot -Name 'store-sanitize'
    $sanitized = New-OrchestrationEvolutionCandidate -Problem 'token=sk-SYNTHETICSECRET123 leaked into the retry loop' `
        -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'ref') -GeneralizedCause 'secret in log context' `
        -ProposedChange 'redact before hashing' -ExpectedEffect 'no secret in evidence' `
        -Risk 'low' -RollbackPlan 'revert redaction call' -StoreDir $storeSan -PolicyPath $repoPolicy -AtUtc $AT
    $sanRec = Get-OrchestrationEvolutionCandidate -StoreDir $storeSan -CandidateId ([string]$sanitized.candidate_id)
    $sanText = ConvertTo-Json -InputObject $sanRec.record -Depth 8 -Compress
    $sanHist = Get-OrchestrationEvolutionHistory -StoreDir $storeSan
    $sanHistText = ConvertTo-Json -InputObject @($sanHist.events) -Depth 8 -Compress
    Assert-Evolution ((-not $sanText.Contains('sk-SYNTHETICSECRET123')) -and (-not $sanHistText.Contains('sk-SYNTHETICSECRET123')) -and ($sanText.Contains('[REDACTED]'))) 'R6 secret canary redacted in record + history'

    $badRefs = New-OrchestrationEvolutionCandidate -Problem 'hostile refs' -RepeatedEvidenceRefs @('good-1', "bad ref`nwith newline", 'good-2') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' `
        -StoreDir $storeSan -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$badRefs.ok) 'R6 hostile ref chars dropped, valid refs kept' ([string]$badRefs.error)
    Assert-Evolution (([int]$badRefs.record.repeated_evidence.Count -eq 2) -and ([int]$badRefs.refs_rejected -ge 1)) 'R6 rejected refs counted (not silent)' ("" + $badRefs.refs_rejected)

    $emptyProblem = New-OrchestrationEvolutionCandidate -Problem '   ' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3) `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' `
        -StoreDir $storeSan -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$emptyProblem.ok) -and ([string]$emptyProblem.error -ceq 'EVOLUTION_INVALID_PROBLEM')) 'R6 blank required field rejected'

    # ---- required test 4 support: eval fixtures (R4) ----
    $baselineFixture = [ordered]@{
        label   = 'baseline'
        samples = 10
        metrics = [ordered]@{
            tester_duplication_rate = 0.50
            task_wall_time          = 120.0
            evidence_reuse_rate     = 0.25
        }
    }
    $betterFixture = [ordered]@{
        label   = 'candidate'
        samples = 10
        metrics = [ordered]@{
            tester_duplication_rate = 0.30
            task_wall_time          = 100.0
            evidence_reuse_rate     = 0.40
        }
    }
    $worseFixture = [ordered]@{
        label   = 'candidate'
        samples = 10
        metrics = [ordered]@{
            tester_duplication_rate = 0.90
            task_wall_time          = 130.0
            evidence_reuse_rate     = 0.10
        }
    }
    $evalPass = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $betterFixture -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$evalPass.ok) -and ([string]$evalPass.verdict -ceq 'pass')) 'R4 improvement within tolerance => pass' ("" + $evalPass.verdict)
    Assert-Evolution (([int]$evalPass.compared -eq 3) -and ([int]$evalPass.improved -eq 3) -and ([int]$evalPass.regressed -eq 0)) 'R4 per-target deltas classified' ("" + $evalPass.compared)
    $evalReg = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $worseFixture -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$evalReg.ok) -and ([string]$evalReg.verdict -ceq 'regression') -and ([int]$evalReg.regressed -eq 3)) 'R4 regression detected (all 3 targets)' ("" + $evalReg.verdict)
    $deltaOk = $true
    foreach ($d in @($evalReg.deltas)) {
        if ([string]$d.target -ceq 'evidence_reuse_rate') {
            $deltaOk = ([string]$d.direction -ceq 'higher_is_better') -and ([string]$d.comparison -ceq 'regression') -and ([double]$d.delta -lt 0)
        }
    }
    Assert-Evolution $deltaOk 'R4 direction honoured per target (higher_is_better)'
    $withinTol = [ordered]@{ label = 'c'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.53; task_wall_time = 120.0; evidence_reuse_rate = 0.25 } }
    $evalTol = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $withinTol -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([string]$evalTol.verdict -ceq 'pass') -and ([int]$evalTol.improved -eq 0) -and ([int]$evalTol.unchanged -eq 3)) 'R4 delta within tolerance is not a regression' ("" + $evalTol.verdict)
    $smallSample = [ordered]@{ label = 'c'; samples = 1; metrics = [ordered]@{ tester_duplication_rate = 0.10 } }
    $evalFloor = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $smallSample -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([string]$evalFloor.verdict -ceq 'inconclusive') -and (@($evalFloor.reasons) -ccontains 'samples-below-floor')) 'R4 below sample floor => inconclusive' ("" + $evalFloor.verdict)
    $noCommon = [ordered]@{ label = 'c'; samples = 10; metrics = [ordered]@{ unrelated_metric = 1 } }
    $evalNoCommon = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $noCommon -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([string]$evalNoCommon.verdict -ceq 'inconclusive') -and (@($evalNoCommon.missing_targets).Count -eq 3)) 'R4 no comparable target => inconclusive, missing listed' ("" + $evalNoCommon.verdict)
    $shadowWorse = [ordered]@{ label = 'shadow'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.95; task_wall_time = 120.0; evidence_reuse_rate = 0.25 } }
    $evalShadow = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $betterFixture -ShadowFixture $shadowWorse -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([string]$evalShadow.verdict -ceq 'regression') -and (@($evalShadow.reasons) -ccontains 'shadow-regression')) 'R4 shadow/A-B regression blocks pass too' ("" + $evalShadow.verdict)
    $evalShadowOk = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $betterFixture -ShadowFixture $betterFixture -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([string]$evalShadowOk.verdict -ceq 'pass') 'R4 healthy shadow keeps pass' ("" + $evalShadowOk.verdict)

    # fixture files + hostile fixtures
    $fxDir = Join-Path $tempRoot 'fixtures'
    New-Item -ItemType Directory -Path $fxDir -Force | Out-Null
    Write-EvolutionFixture -Path (Join-Path $fxDir 'baseline.json') -Text (ConvertTo-Json -InputObject $baselineFixture -Depth 6)
    Write-EvolutionFixture -Path (Join-Path $fxDir 'candidate.json') -Text (ConvertTo-Json -InputObject $betterFixture -Depth 6)
    Write-EvolutionFixture -Path (Join-Path $fxDir 'broken.json') -Text '{"samples":10,"metrics":'
    $evalFiles = Invoke-OrchestrationEvolutionEval -BaselineFixture (Join-Path $fxDir 'baseline.json') -CandidateFixture (Join-Path $fxDir 'candidate.json') -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([string]$evalFiles.verdict -ceq 'pass') 'R4 eval reads fixtures from disk' ("" + $evalFiles.verdict)
    $evalBroken = Invoke-OrchestrationEvolutionEval -BaselineFixture (Join-Path $fxDir 'broken.json') -CandidateFixture (Join-Path $fxDir 'candidate.json') -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$evalBroken.ok) -and ([string]$evalBroken.error -ceq 'EVOLUTION_FIXTURE_MALFORMED')) 'R4 malformed fixture structured error'
    $evalGone = Invoke-OrchestrationEvolutionEval -BaselineFixture (Join-Path $fxDir 'nope.json') -CandidateFixture (Join-Path $fxDir 'candidate.json') -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$evalGone.ok) -and ([string]$evalGone.error -ceq 'EVOLUTION_FIXTURE_UNREADABLE')) 'R4 missing fixture structured error'
    $hostileFixture = [ordered]@{ label = 'c'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 'NaN'; task_wall_time = $true; evidence_reuse_rate = -5 } }
    $evalHostile = Invoke-OrchestrationEvolutionEval -BaselineFixture $baselineFixture -CandidateFixture $hostileFixture -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$evalHostile.ok) -and ([int]$evalHostile.compared -eq 0) -and ([int]$evalHostile.missing_targets.Count -eq 3)) 'R4 hostile metric values ignored, verdict inconclusive' ("" + $evalHostile.verdict)

    # ---- V4 (H2): 'pass' requires FULL target coverage ----
    $twoBase = [ordered]@{ label = 'baseline'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.50; evidence_reuse_rate = 0.25 } }
    $twoBoth = [ordered]@{ label = 'candidate'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.30; evidence_reuse_rate = 0.40 } }
    $twoPartial = [ordered]@{ label = 'candidate'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.30 } }
    $evalTwoPass = Invoke-OrchestrationEvolutionEval -BaselineFixture $twoBase -CandidateFixture $twoBoth -PolicyPath $policyTwoTargets -AtUtc $AT
    Assert-Evolution (([string]$evalTwoPass.verdict -ceq 'pass') -and ([int]$evalTwoPass.compared -eq 2)) 'H2 control: all targets comparable => pass' ("" + $evalTwoPass.verdict)
    $evalTwoPartial = Invoke-OrchestrationEvolutionEval -BaselineFixture $twoBase -CandidateFixture $twoPartial -PolicyPath $policyTwoTargets -AtUtc $AT
    Assert-Evolution (([string]$evalTwoPartial.verdict -ceq 'inconclusive') -and (@($evalTwoPartial.reasons) -ccontains 'incomplete-target-coverage')) 'H2 1 of 2 comparable targets => inconclusive (never pass)' ("" + $evalTwoPartial.verdict)
    Assert-Evolution ((@($evalTwoPartial.missing_targets).Count -eq 1) -and ([string]$evalTwoPartial.missing_targets[0] -ceq 'evidence_reuse_rate')) 'H2 the uncovered target is named, not silently dropped' ("" + (@($evalTwoPartial.missing_targets) -join ','))
    $twoPartialShadow = Invoke-OrchestrationEvolutionEval -BaselineFixture $twoBase -CandidateFixture $twoBoth -ShadowFixture $twoPartial -PolicyPath $policyTwoTargets -AtUtc $AT
    Assert-Evolution (([string]$twoPartialShadow.verdict -ceq 'inconclusive') -and (@($twoPartialShadow.reasons) -ccontains 'shadow-incomplete-target-coverage')) 'H2 partial shadow coverage also blocks pass' ("" + $twoPartialShadow.verdict)
    $twoPartialWorse = [ordered]@{ label = 'candidate'; samples = 10; metrics = [ordered]@{ tester_duplication_rate = 0.90 } }
    $evalPartialRegression = Invoke-OrchestrationEvolutionEval -BaselineFixture $twoBase -CandidateFixture $twoPartialWorse -PolicyPath $policyTwoTargets -AtUtc $AT
    Assert-Evolution (([string]$evalPartialRegression.verdict -ceq 'regression') -and (@($evalPartialRegression.reasons) -ccontains 'candidate-regression')) 'H2 inconclusive coverage never masks a measured regression' ("" + $evalPartialRegression.verdict)

    # ---- required test 3: candidate regression blocks promotion (R5) ----
    $promoteReg = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$created.candidate_id) -ReviewMarker 'review:REV1' -EvalVerdict 'regression' -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteReg.ok) -and ([string]$promoteReg.status -ceq 'rejected') -and ([string]$promoteReg.error -ceq 'EVOLUTION_EVAL_REGRESSION_BLOCKS_PROMOTION')) 'T3 regression verdict blocks promotion' ("" + $promoteReg.error)
    $afterReg = Get-OrchestrationEvolutionCandidate -StoreDir $store2 -CandidateId ([string]$created.candidate_id)
    Assert-Evolution ([string]$afterReg.record.status -ceq 'candidate') 'T3 blocked promotion leaves status untouched'
    $promoteIncon = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$created.candidate_id) -ReviewMarker 'review:REV1' -EvalVerdict 'inconclusive' -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteIncon.ok) -and ([string]$promoteIncon.error -ceq 'EVOLUTION_EVAL_INCONCLUSIVE_BLOCKS_PROMOTION')) 'T3 inconclusive verdict blocks promotion' ("" + $promoteIncon.error)
    $promoteNoMarker = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$created.candidate_id) -EvalVerdict 'pass' -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteNoMarker.ok) -and ([string]$promoteNoMarker.error -ceq 'EVOLUTION_REVIEW_MARKER_REQUIRED') -and ([string]$promoteNoMarker.review_marker -ceq '')) 'T4 missing review marker rejects promotion' ("" + $promoteNoMarker.error)
    $promoteBadVerdict = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$created.candidate_id) -ReviewMarker 'review:REV1' -EvalVerdict 'approved' -StoreDir $store2 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteBadVerdict.ok) -and ([string]$promoteBadVerdict.error -ceq 'EVOLUTION_EVAL_VERDICT_INVALID')) 'R6 unknown eval verdict rejected (closed set)'

    # ---- required test 4: successful shadow promoted explicitly (R5) ----
    $store3 = New-EvolutionStore -Root $tempRoot -Name 'store-promote'
    $second = New-OrchestrationEvolutionCandidate -Problem 'tool loop recurs on flaky suites' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 5 -Prefix 'tl') `
        -GeneralizedCause 'no no-progress guard on repeated tool calls' -ProposedChange 'warn on repeated action soft limit' `
        -ExpectedEffect 'lower tool_loop_rate' -Risk 'low' -RollbackPlan 'remove the warning' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$second.ok) 'T4 second candidate created' ([string]$second.error)
    $promoted = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$second.candidate_id) -ReviewMarker 'review:REV7-security:APPROVED' -EvalVerdict 'pass' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$promoted.ok) -and ([string]$promoted.status -ceq 'promoted')) 'T4 successful shadow promoted explicitly with marker' ("" + $promoted.error)
    Assert-Evolution (([bool]$promoted.applied -eq $false) -and ([string]$promoted.production_mutation -ceq 'none') -and ([string]$promoted.apply_path -ceq 'reviewed-code-change')) 'T4 promotion is a decision record only (nothing applied)'
    $promotedRec = Get-OrchestrationEvolutionCandidate -StoreDir $store3 -CandidateId ([string]$second.candidate_id)
    Assert-Evolution ([string]$promotedRec.record.status -ceq 'promoted') 'T4 stored status promoted'
    $again = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$second.candidate_id) -ReviewMarker 'review:REV8' -EvalVerdict 'pass' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$again.ok) -and ([string]$again.error -ceq 'EVOLUTION_CANDIDATE_ALREADY_PROMOTED')) 'T4 double promotion of the same candidate rejected'

    # one at a time
    $otherCandidate = New-OrchestrationEvolutionCandidate -Problem 'reviewer findings repeat' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 6 -Prefix 'rv') `
        -GeneralizedCause 'diff summary hides the risky hunk' -ProposedChange 'include the hunk list in the reviewer bundle' `
        -ExpectedEffect 'lower reviewer_finding_rate' -Risk 'low' -RollbackPlan 'revert bundle change' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    $oneAtATime = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$otherCandidate.candidate_id) -ReviewMarker 'review:REV9' -EvalVerdict 'pass' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$oneAtATime.ok) -and ([string]$oneAtATime.error -ceq 'EVOLUTION_ONE_CHANGE_AT_A_TIME')) 'T4 one-at-a-time blocks a second promoted change' ("" + $oneAtATime.error)
    $otherStill = Get-OrchestrationEvolutionCandidate -StoreDir $store3 -CandidateId ([string]$otherCandidate.candidate_id)
    Assert-Evolution ([string]$otherStill.record.status -ceq 'candidate') 'T4 blocked second promotion leaves status untouched'

    # ---- required test 5: rollback restores prior behavior (R5) ----
    $noReason = Rollback-OrchestrationEvolutionCandidate -CandidateId ([string]$second.candidate_id) -Reason '   ' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$noReason.ok) -and ([string]$noReason.error -ceq 'EVOLUTION_REASON_REQUIRED')) 'T5 rollback without reason rejected'
    $rollback = Rollback-OrchestrationEvolutionCandidate -CandidateId ([string]$second.candidate_id) -Reason 'duplication rate regressed in shadow after 2 runs' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$rollback.ok) -and ([string]$rollback.status -ceq 'rolled_back') -and ([string]$rollback.restored_candidate_state -ceq 'candidate')) 'T5 rollback returns the candidate to its prior state' ("" + $rollback.error)
    Assert-Evolution (([bool]$rollback.applied -eq $false) -and (-not [string]::IsNullOrWhiteSpace([string]$rollback.rollback_plan))) 'T5 rollback carries the recorded rollback plan'
    $rolledRec = Get-OrchestrationEvolutionCandidate -StoreDir $store3 -CandidateId ([string]$second.candidate_id)
    Assert-Evolution (([string]$rolledRec.record.status -ceq 'rolled_back') -and ([string]$rolledRec.record.rollback_reason).Length -gt 0) 'T5 stored status rolled_back with reason'
    $hist3 = Get-OrchestrationEvolutionHistory -StoreDir $store3 -CandidateId ([string]$second.candidate_id)
    $events = @($hist3.events | ForEach-Object { [string]$_.event })
    Assert-Evolution ((@($hist3.events).Count -eq 3) -and ($events -ccontains 'created') -and ($events -ccontains 'promoted') -and ($events -ccontains 'rolled_back')) 'T5 history has created + promoted + rolled_back' (($events -join ','))
    $histJson = ConvertTo-Json -InputObject @($hist3.events) -Depth 8 -Compress
    Assert-Evolution ($histJson.Contains('duplication rate regressed in shadow') -and ($histJson.Contains('review:REV7'))) 'T5 history keeps reason + review marker'
    $promotedEvent = @($hist3.events | Where-Object { [string]$_.event -ceq 'promoted' })[0]
    Assert-Evolution (([string]$promotedEvent.status_before -ceq 'candidate') -and ([string]$promotedEvent.status_after -ceq 'promoted') -and ([string]$promotedEvent.production_mutation -ceq 'none')) 'T5 history records the exact transition'
    $doubleRollback = Rollback-OrchestrationEvolutionCandidate -CandidateId ([string]$second.candidate_id) -Reason 'again' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$doubleRollback.ok) -and ([string]$doubleRollback.error -ceq 'EVOLUTION_CANDIDATE_NOT_PROMOTED')) 'T5 rollback of a non-promoted candidate rejected'
    $secondNow = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$otherCandidate.candidate_id) -ReviewMarker 'review:REV9' -EvalVerdict 'pass' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (([bool]$secondNow.ok) -and ([string]$secondNow.status -ceq 'promoted')) 'T5 after rollback the one-at-a-time slot is free again' ("" + $secondNow.error)

    # policy variant without review-marker requirement (explicit gate only)
    $store4 = New-EvolutionStore -Root $tempRoot -Name 'store-nomarker'
    $noMarkerCand = New-OrchestrationEvolutionCandidate -Problem 'user intervention repeats' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 4 -Prefix 'ui') `
        -GeneralizedCause 'planner turn budget too small for wide tasks' -ProposedChange 'raise planner-turn step budget' `
        -ExpectedEffect 'lower user_intervention_rate' -Risk 'medium' -RollbackPlan 'revert budget change' -StoreDir $store4 -PolicyPath $repoPolicy -AtUtc $AT
    $noMarkerPromote = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$noMarkerCand.candidate_id) -EvalVerdict 'pass' -StoreDir $store4 -PolicyPath $policyNoMarker -AtUtc $AT
    Assert-Evolution ([bool]$noMarkerPromote.ok) 'R1 promotion_requires.review_marker=false honoured (policy-driven gate)' ([string]$noMarkerPromote.error)
    $promoteMissingPolicy = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$noMarkerCand.candidate_id) -ReviewMarker 'review:REV1' -EvalVerdict 'pass' -StoreDir $store4 -PolicyPath $policyMissing -AtUtc $AT
    Assert-Evolution ((-not [bool]$promoteMissingPolicy.ok) -and ([string]$promoteMissingPolicy.error -ceq 'EVOLUTION_POLICY_UNAVAILABLE')) 'R6 promotion fails closed without policy'

    # ---- history cap fail-closed (bounded store) ----
    $storeCap = New-EvolutionStore -Root $tempRoot -Name 'store-cap'
    [IO.File]::WriteAllText((Join-Path $storeCap 'evolution-history.jsonl'), (('x' * 1048576)), [Text.UTF8Encoding]::new($false))
    $capCand = New-OrchestrationEvolutionCandidate -Problem 'cap probe' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'cp') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$capCand.ok) -and ([string]$capCand.error -ceq 'EVOLUTION_HISTORY_CAP')) 'R6 history cap fail-closed (no silent promotion)' ("" + $capCand.error)
    # H1: a creation whose history append failed leaves NO promotable record.
    $capCandidatesDir = Get-EvolutionCandidateDir -StoreDir $storeCap
    $capLeftovers = @()
    if (Test-Path -LiteralPath $capCandidatesDir -PathType Container) { $capLeftovers = @([IO.Directory]::GetFiles($capCandidatesDir, '*.json')) }
    Assert-Evolution (($capLeftovers.Count -eq 0) -and ([bool]$capCand.rolled_back)) 'H1 history failure rolls the candidate record back (no promotable record without its created event)' ("" + $capLeftovers.Count)
    $capLookup = Get-OrchestrationEvolutionCandidate -StoreDir $storeCap -CandidateId ([string]$capCand.candidate_id)
    Assert-Evolution ((-not [bool]$capLookup.ok) -and ([string]$capLookup.error -ceq 'EVOLUTION_CANDIDATE_NOT_FOUND')) 'H1 the candidate is absent from the store after the failed history append' ([string]$capLookup.error)

    # ---- H3 (V5/V7): bounded candidate store, one-at-a-time over the WHOLE store ----
    $storeCap2 = New-EvolutionStore -Root $tempRoot -Name 'store-candidate-cap'
    $c1 = New-OrchestrationEvolutionCandidate -Problem 'cap probe one' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'k1') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap2 -PolicyPath $policyCap2 -AtUtc $AT
    $c2 = New-OrchestrationEvolutionCandidate -Problem 'cap probe two' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'k2') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap2 -PolicyPath $policyCap2 -AtUtc $AT
    $c3 = New-OrchestrationEvolutionCandidate -Problem 'cap probe three' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'k3') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap2 -PolicyPath $policyCap2 -AtUtc $AT
    Assert-Evolution (([bool]$c1.ok) -and ([bool]$c2.ok)) 'H3 candidates up to the cap are created' ("" + $c1.error + $c2.error)
    Assert-Evolution ((-not [bool]$c3.ok) -and ([string]$c3.error -ceq 'EVOLUTION_STORE_CANDIDATE_LIMIT') -and ([int]$c3.cap -eq 2)) 'H3 creation rejected at the candidate-file cap (no unbounded growth)' ("" + $c3.error)
    $cap3Path = Get-EvolutionCandidatePath -StoreDir $storeCap2 -CandidateId ([string]$c3.candidate_id)
    Assert-Evolution (-not (Test-Path -LiteralPath $cap3Path -PathType Leaf)) 'H3 the rejected candidate leaves no file behind' ("" + $cap3Path)

    $storeCap3 = New-EvolutionStore -Root $tempRoot -Name 'store-enum-window'
    $w1 = New-OrchestrationEvolutionCandidate -Problem 'window probe one' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'w1') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap3 -PolicyPath $policyCap3 -AtUtc $AT
    $w2 = New-OrchestrationEvolutionCandidate -Problem 'window probe two' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'w2') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap3 -PolicyPath $policyCap3 -AtUtc $AT
    $w3 = New-OrchestrationEvolutionCandidate -Problem 'window probe three' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'w3') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeCap3 -PolicyPath $policyCap3 -AtUtc $AT
    Assert-Evolution (([bool]$w1.ok) -and ([bool]$w2.ok) -and ([bool]$w3.ok)) 'H3 three candidates stored under a cap of 3' ("" + $w3.error)
    $promotedOutsideWindow = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$w1.candidate_id) -ReviewMarker 'review:REV11' -EvalVerdict 'pass' `
        -StoreDir $storeCap3 -PolicyPath $policyCap2 -AtUtc $AT
    Assert-Evolution ((-not [bool]$promotedOutsideWindow.ok) -and ([string]$promotedOutsideWindow.error -ceq 'EVOLUTION_ENUMERATION_INCOMPLETE')) 'H3 promotion over an incomplete enumeration fails closed' ("" + $promotedOutsideWindow.error)
    $w1After = Get-OrchestrationEvolutionCandidate -StoreDir $storeCap3 -CandidateId ([string]$w1.candidate_id)
    Assert-Evolution ([string]$w1After.record.status -ceq 'candidate') 'H3 the blocked promotion left the status untouched' ("" + $w1After.record.status)

    # ---- V8 (T): mutation tests for the two auto-fixed bugs ----
    $storeMut = New-EvolutionStore -Root $tempRoot -Name 'store-mutation'
    $m1c = New-OrchestrationEvolutionCandidate -Problem 'mutation probe first' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'm1') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    $m2c = New-OrchestrationEvolutionCandidate -Problem 'mutation probe middle' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'm2') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    $m3c = New-OrchestrationEvolutionCandidate -Problem 'mutation probe last' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'm3') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    $m2promoted = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$m2c.candidate_id) -ReviewMarker 'review:REV12' -EvalVerdict 'pass' `
        -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$m2promoted.ok) 'T one-at-a-time control: the middle candidate promotes' ("" + $m2promoted.error)
    $mutList = @(Get-OrchestrationEvolutionCandidateList -StoreDir $storeMut -Policy $repoPolicy)
    $mutPromotedIds = @($mutList | Where-Object { [string]$_.status -ceq 'promoted' } | ForEach-Object { [string]$_.candidate_id })
    Assert-Evolution (($mutList.Count -eq 3) -and ($mutPromotedIds.Count -eq 1) -and ([string]$mutPromotedIds[0] -ceq [string]$m2c.candidate_id)) 'T enumeration sees every candidate and the promoted one is not the first' ("" + (@($mutList | ForEach-Object { [string]$_.candidate_id }) -join ','))
    $mutFirst = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$m1c.candidate_id) -ReviewMarker 'review:REV13' -EvalVerdict 'pass' -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    $mutLast = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$m3c.candidate_id) -ReviewMarker 'review:REV14' -EvalVerdict 'pass' -StoreDir $storeMut -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (((-not [bool]$mutFirst.ok) -and ([string]$mutFirst.error -ceq 'EVOLUTION_ONE_CHANGE_AT_A_TIME')) -and ((-not [bool]$mutLast.ok) -and ([string]$mutLast.error -ceq 'EVOLUTION_ONE_CHANGE_AT_A_TIME'))) 'T one-at-a-time blocks BOTH candidates around the promoted one (catches an inverted id comparison)' ("" + $mutFirst.error + '/' + $mutLast.error)
    $rawHistory = [IO.File]::ReadAllText((Get-EvolutionHistoryPath -StoreDir $storeMut), [Text.UTF8Encoding]::new($false))
    Assert-Evolution (($rawHistory.Contains('"event":"created"')) -and ($rawHistory.Contains('"event":"promoted"'))) 'T history serializes the real event names, not a variable name' ("" + $rawHistory.Substring(0, [Math]::Min(80, $rawHistory.Length)))
    Assert-Evolution ((-not $rawHistory.Contains('$event')) -and (-not $rawHistory.Contains('$NewStatus')) -and (-not $rawHistory.Contains('$status_after')) -and ($rawHistory.Contains('"status_before":"candidate"')) -and ($rawHistory.Contains('"status_after":"promoted"'))) 'T history carries real field values, not PS variable placeholders'
    Assert-Evolution ($rawHistory.Contains('mutation probe middle')) 'T the created event stores the real problem text (reason is a value, not a type name)' ("" + $rawHistory.Length)

    # ---- V5 (M4): a stale pre-lock read must not authorize a promotion ----
    $storeRace = New-EvolutionStore -Root $tempRoot -Name 'store-race'
    $raceCand = New-OrchestrationEvolutionCandidate -Problem 'race probe candidate' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'rc') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeRace -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$raceCand.ok) 'M4 race candidate created' ("" + $raceCand.error)
    # A concurrent actor promotes the very same candidate before our call.
    $raceDoc = ConvertTo-EvolutionOrdered -Node (Get-OrchestrationEvolutionCandidate -StoreDir $storeRace -CandidateId ([string]$raceCand.candidate_id)).record
    $raceDoc['status'] = 'promoted'
    $raceDoc['promoted_at'] = '2026-01-02T03:04:06.0000000Z'
    [IO.File]::WriteAllText((Get-EvolutionCandidatePath -StoreDir $storeRace -CandidateId ([string]$raceCand.candidate_id)), (ConvertTo-Json -InputObject $raceDoc -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    # Force the pre-lock read to serve a STALE snapshot (status 'candidate'),
    # i.e. exactly what a caller that read before the concurrent decision sees.
    $realReader = ${function:Get-OrchestrationEvolutionCandidate}
    $script:staleServed = $false
    function Get-OrchestrationEvolutionCandidate {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$CandidateId)
        if (-not $script:staleServed) {
            $script:staleServed = $true
            $stale = ConvertTo-EvolutionOrdered -Node $raceDoc
            $stale['status'] = 'candidate'
            return [PSCustomObject]@{ ok = $true; error = ''; record = [PSCustomObject]$stale }
        }
        return (& $realReader -StoreDir $StoreDir -CandidateId $CandidateId)
    }
    try {
        $raceResult = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$raceCand.candidate_id) -ReviewMarker 'review:RACE' -EvalVerdict 'pass' `
            -StoreDir $storeRace -PolicyPath $repoPolicy -AtUtc $AT
    }
    finally { Set-Item -Path 'Function:\Get-OrchestrationEvolutionCandidate' -Value $realReader -Force }
    Assert-Evolution (([bool]$script:staleServed) -and ((-not [bool]$raceResult.ok) -and ([string]$raceResult.error -ceq 'EVOLUTION_CANDIDATE_ALREADY_PROMOTED'))) 'M4 stale pre-lock read rejected: the decision is re-validated inside the lock' ("" + $raceResult.error)

    # ---- V5 (M5): verifiable restore on transition + locked store ----
    $storeRestore = New-EvolutionStore -Root $tempRoot -Name 'store-restore'
    $restoreCand = New-OrchestrationEvolutionCandidate -Problem 'restore probe candidate' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'rs') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeRestore -PolicyPath $repoPolicy -AtUtc $AT
    [IO.File]::WriteAllText((Join-Path $storeRestore 'evolution-history.jsonl'), (('x' * 1048576)), [Text.UTF8Encoding]::new($false))
    $restoreFail = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$restoreCand.candidate_id) -ReviewMarker 'review:REV15' -EvalVerdict 'pass' `
        -StoreDir $storeRestore -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$restoreFail.ok) -and ([string]$restoreFail.error -ceq 'EVOLUTION_HISTORY_CAP') -and ([string]$restoreFail.restored -ceq 'verified')) 'M5 failed history append restores the record and VERIFIES the restore' ("" + $restoreFail.error + '/' + $restoreFail.restored)
    $restoreRec = Get-OrchestrationEvolutionCandidate -StoreDir $storeRestore -CandidateId ([string]$restoreCand.candidate_id)
    Assert-Evolution (([string]$restoreRec.record.status -ceq 'candidate') -and (-not (Test-EvolutionStoreLocked -StoreDir $storeRestore))) 'M5 verified restore leaves the prior status and does not lock the store' ("" + $restoreRec.record.status)

    $storeLocked = New-EvolutionStore -Root $tempRoot -Name 'store-locked'
    $lockCand = New-OrchestrationEvolutionCandidate -Problem 'locked probe one' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'lk') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeLocked -PolicyPath $repoPolicy -AtUtc $AT
    $lockCand2 = New-OrchestrationEvolutionCandidate -Problem 'locked probe two' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'l2') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeLocked -PolicyPath $repoPolicy -AtUtc $AT
    $lockPromoted = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$lockCand.candidate_id) -ReviewMarker 'review:REV16' -EvalVerdict 'pass' `
        -StoreDir $storeLocked -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ([bool]$lockPromoted.ok) 'M5 control promotion before locking' ("" + $lockPromoted.error)
    Assert-Evolution (Set-EvolutionStoreLocked -StoreDir $storeLocked -Reason 'composite-failure probe') 'M5 store can be locked (marker written and readable)'
    $lockedPromote = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$lockCand2.candidate_id) -ReviewMarker 'review:REV17' -EvalVerdict 'pass' `
        -StoreDir $storeLocked -PolicyPath $repoPolicy -AtUtc $AT
    $lockedRollback = Rollback-OrchestrationEvolutionCandidate -CandidateId ([string]$lockCand.candidate_id) -Reason 'should be refused' `
        -StoreDir $storeLocked -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution (((-not [bool]$lockedPromote.ok) -and ([string]$lockedPromote.error -ceq 'EVOLUTION_STORE_LOCKED')) -and ((-not [bool]$lockedRollback.ok) -and ([string]$lockedRollback.error -ceq 'EVOLUTION_STORE_LOCKED'))) 'M5 a locked store blocks new transitions until intervention' ("" + $lockedPromote.error + '/' + $lockedRollback.error)

    # Composite failure: the creation rollback itself fails => the store is
    # locked instead of being left silently inconsistent.
    $storeComposite = New-EvolutionStore -Root $tempRoot -Name 'store-composite'
    [IO.File]::WriteAllText((Join-Path $storeComposite 'evolution-history.jsonl'), (('x' * 1048576)), [Text.UTF8Encoding]::new($false))
    $realRemover = ${function:Remove-EvolutionCandidateRecord}
    function Remove-EvolutionCandidateRecord {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][string]$StoreDir, [Parameter(Mandatory = $true)][string]$CandidateId)
        return [PSCustomObject]@{ ok = $false; removed = $false }
    }
    try {
        $compositeResult = New-OrchestrationEvolutionCandidate -Problem 'composite failure probe' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'cf') `
            -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeComposite -PolicyPath $repoPolicy -AtUtc $AT
    }
    finally { Set-Item -Path 'Function:\Remove-EvolutionCandidateRecord' -Value $realRemover -Force }
    Assert-Evolution ((-not [bool]$compositeResult.ok) -and ([string]$compositeResult.error -ceq 'EVOLUTION_STORE_LOCKED') -and (Test-EvolutionStoreLocked -StoreDir $storeComposite)) 'M5/H1 a failed rollback locks the store (composite failure, no silent state)' ("" + $compositeResult.error)
$afterLockCreate = New-OrchestrationEvolutionCandidate -Problem 'post-lock probe' -RepeatedEvidenceRefs (New-EvolutionRefs -Count 3 -Prefix 'pl') `
        -GeneralizedCause 'x' -ProposedChange 'y' -ExpectedEffect 'z' -Risk 'low' -RollbackPlan 'w' -StoreDir $storeComposite -PolicyPath $repoPolicy -AtUtc $AT
$afterLockApprove = Approve-OrchestrationEvolutionCandidate -CandidateId ([string]$compositeResult.candidate_id) -ReviewMarker 'review:REV18' -EvalVerdict 'pass' `
        -StoreDir $storeComposite -PolicyPath $repoPolicy -AtUtc $AT
Assert-Evolution (((-not [bool]$afterLockCreate.ok) -and ([string]$afterLockCreate.error -ceq 'EVOLUTION_STORE_LOCKED')) -and ((-not [bool]$afterLockApprove.ok) -and ([string]$afterLockApprove.error -ceq 'EVOLUTION_STORE_LOCKED'))) 'M5 a locked store blocks creation and promotion too, until intervention' ("" + $afterLockCreate.error + '/' + $afterLockApprove.error)

    # ---- id / store hostility ----
    $badIdApprove = Approve-OrchestrationEvolutionCandidate -CandidateId '../../../etc/passwd' -ReviewMarker 'review:REV1' -EvalVerdict 'pass' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$badIdApprove.ok) -and ([string]$badIdApprove.error -ceq 'EVOLUTION_INVALID_CANDIDATE_ID')) 'R6 path-traversal candidate id rejected'
    $badIdRollback = Rollback-OrchestrationEvolutionCandidate -CandidateId 'nope' -Reason 'x' -StoreDir $store3 -PolicyPath $repoPolicy -AtUtc $AT
    Assert-Evolution ((-not [bool]$badIdRollback.ok) -and ([string]$badIdRollback.error -ceq 'EVOLUTION_INVALID_CANDIDATE_ID')) 'R6 invalid id rejected on rollback too'
    $missingHistory = Get-OrchestrationEvolutionHistory -StoreDir (Join-Path $tempRoot 'no-such-store')
    Assert-Evolution (([bool]$missingHistory.ok) -and ([int]$missingHistory.count -eq 0)) 'R6 history read on empty store returns empty, not throw'

    # ---- R6: nothing automatic touched the repo ----
    $repoPolicyAfter = ''
    $repoFlagsAfter = ''
    try {
        $repoPolicyAfter = [IO.File]::ReadAllText($repoEvolutionPolicy, [Text.UTF8Encoding]::new($false))
        $repoFlagsAfter = [IO.File]::ReadAllText($repoFlags, [Text.UTF8Encoding]::new($false))
    }
    catch { }
    Assert-Evolution (($repoPolicyAfter -ceq $repoPolicyBefore) -and ($repoFlagsAfter -ceq $repoFlagsBefore)) 'R6 repo evolution policy + capability flags unchanged by the full loop'

    # store isolation: nothing written outside the given store dir
    $storeFileCount = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $store3 -Recurse -File)) { if ([string]$f.Name -ne '.evolution.lock') { $storeFileCount++ } }
    Assert-Evolution (($storeFileCount -eq 3) -and (Test-Path -LiteralPath (Join-Path $store3 'evolution-history.jsonl'))) 'R6 store contains only candidates + history (+lock)' ("" + $storeFileCount)
}
catch {
    Write-Host ("[FAIL] unexpected exception -- " + $_.Exception.Message)
    $script:failed++
}
finally {
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ('RESULT evolution-loop: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
