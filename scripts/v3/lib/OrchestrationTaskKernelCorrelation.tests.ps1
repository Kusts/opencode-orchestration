<#!
.SYNOPSIS
    Tests for the F6 correlation envelope (New-CorrelationEnvelope +
    TASK_CREATED/TASK_DONE emission in lib/OrchestrationTaskKernel.ps1).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP, fixture flags files, cleanup in
    finally. Bracketed output the runner parses. Exit 0 on all pass,
    exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
    Authority surface untouched: gate/DONE/flags/registry are only
    exercised through the pre-existing happy path, never modified.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-Correlation {
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

function Write-CorrFixture {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-CorrTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-corr-' + [guid]::NewGuid().ToString('N'))
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    Write-CorrFixture -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; tasks = $tasks; flags = $flags }
}

function New-CorrVerifierJson {
    param([string]$Status = 'verified_pass', [string[]]$Evidence = @('criterion:0:verified'))
    $o = [ordered]@{
        ok = $true; task_id = 'fixture'; status = $Status; reason = ''
        scope = $null; profiles = @(); evidence = $Evidence; command_classes = @('test')
    }
    return (($o | ConvertTo-Json -Depth 8 -Compress))
}

function Get-CorrTelemetryLines {
    param([string]$Root, [string]$EventType)
    $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
    $f = Join-Path $Root ('cache\v3\telemetry\events-' + $stamp + '.jsonl')
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return @() }
    $out = @()
    foreach ($line in ([IO.File]::ReadAllLines($f))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $ev = ($line | ConvertFrom-Json)
            if ([string]$ev.event_type -ceq $EventType) { $out += $ev }
        }
        catch { }
    }
    return $out
}

$roots = New-Object System.Collections.ArrayList

try {
    # 1. full envelope: complete correlation, hashes only, never raw
    $e = New-CorrelationEnvelope -GoalId 'goal-42' -Objective 'Fix the widget renderer' `
        -RunId 'run-7' -SessionId 'sess-abc-123' -AttemptN 3 `
        -DecisionRef 'MULTI_WORKER' -SettlementState 'settled'
    $keys = @($e.Keys)
    Assert-Correlation (($keys -contains 'corr_goal') -and ($keys -contains 'corr_objective') `
        -and ($keys -contains 'corr_run') -and ($keys -contains 'corr_sess') `
        -and ($keys -contains 'corr_attempt') -and ($keys -contains 'corr_decision') `
        -and ($keys -contains 'corr_settlement')) 'full envelope exposes all seven corr_* fields'
    Assert-Correlation (([string]$e['corr_objective'] -cmatch '^sha256:[0-9a-f]{64}$')) 'objective_hash is sha256 over framed text'
    Assert-Correlation ((([string]$e['corr_goal'] -cmatch '^h:[0-9a-f]{16}$') -and ([string]$e['corr_run'] -cmatch '^h:[0-9a-f]{16}$') `
        -and ([string]$e['corr_sess'] -cmatch '^h:[0-9a-f]{16}$') -and ([string]$e['corr_decision'] -cmatch '^h:[0-9a-f]{16}$') `
        -and ([string]$e['corr_settlement'] -cmatch '^h:[0-9a-f]{16}$')) -and ([int]$e['corr_attempt'] -eq 3)) 'ids hashed via sanitizer, attempt kept as int in range'
    $flat = (($e.Values | ForEach-Object { [string]$_ }) -join '|').ToLowerInvariant()
    Assert-Correlation ((($flat -notmatch 'widget') -and ($flat -notmatch 'goal-42') -and ($flat -notmatch 'sess-abc')) -and ($flat -notmatch 'multi_worker')) 'envelope carries no raw objective/id text'

    # 2. omitted-when-absent + range guards
    $empty = New-CorrelationEnvelope
    Assert-Correlation ((@($empty.Keys).Count -eq 0)) 'empty input yields empty envelope'
    $blank = New-CorrelationEnvelope -GoalId '   ' -Objective '' -AttemptN 0 -DecisionRef '' -SettlementState $null
    Assert-Correlation ((@($blank.Keys).Count -eq 0)) 'blank/zero input yields empty envelope'
    $hi = New-CorrelationEnvelope -Objective 'x' -AttemptN 150
    Assert-Correlation ((-not $hi.Contains('corr_attempt'))) 'attempt_n above range omitted, never clamped into authority data'
    $neg = New-CorrelationEnvelope -Objective 'x' -AttemptN 'abc'
    Assert-Correlation ((-not $neg.Contains('corr_attempt'))) 'non-numeric attempt_n omitted without throwing'

    # 3. never throws on garbage
    $threw = $false
    try { $null = New-CorrelationEnvelope -GoalId $null -Objective $null -RunId $null -SessionId $null -AttemptN @('a', 'b') -DecisionRef $null -SettlementState $null } catch { $threw = $true }
    Assert-Correlation (-not $threw) 'garbage input never throws'
    $sendThrew = $false
    try { $null = Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId 'corr-001' -Runtime $null -TelemetryRoot '' -Correlation 'not-a-dict' } catch { $sendThrew = $true }
    Assert-Correlation (-not $sendThrew) 'garbage correlation never throws the telemetry path'

    # 4. TASK_CREATED emits envelope; telemetry holds no raw text
    $t = New-CorrTestRoot
    [void]$roots.Add($t.root)
    $obj = 'Correlate the zebra widget pipeline'
    $c = New-OrchestrationTask -TaskId 'corr-001' -Objective $obj -TaskType 'implementation' `
        -Risk 'low' -Actor 'planner' -OrchestrationDecision 'SINGLE_WORKER' -RuntimeId 'opencode-v1' `
        -RuntimeGeneration 1 -RuntimeProfile 'v1' -ReadScopes @('src/zebra') -WriteScopes @('src/zebra') `
        -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('zebra renders') -ExpectedArtifacts @('src/zebra/render.js') `
        -AttemptBudget 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Correlation ([bool]$c.ok) 'create ok with envelope wired'
    $created = @(Get-CorrTelemetryLines -Root $t.root -EventType 'TASK_CREATED')
    Assert-Correlation (($created.Count -ge 1)) 'TASK_CREATED telemetry persisted'
    $cm = $created[0].metadata
    $cprops = @($cm.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Correlation ((($cprops -contains 'corr_objective') -and ($cprops -contains 'corr_decision')) -and ($cprops -contains 'corr_settlement')) 'created event carries objective/decision/settlement correlation'
    Assert-Correlation (-not ($cprops -contains 'corr_sess')) 'created event omits absent session'
    Assert-Correlation ((@($cprops).Count -le 10)) 'created metadata respects the ten-key cap'
    $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
    $jf = Join-Path $t.root ('cache\v3\telemetry\events-' + $stamp + '.jsonl')
    $raw = [IO.File]::ReadAllText($jf)
    Assert-Correlation ((($raw -notmatch [regex]::Escape($obj)) -and ($raw -notmatch 'zebra/widget')) -and ($raw -notmatch 'SINGLE_WORKER')) 'telemetry file holds no raw objective/path/decision text'
    $createdObj = [string]($created | Where-Object { [string]$_.task_id -match '^[a-z0-9:]+$' } | Select-Object -First 1).metadata.corr_objective

    # 5. TASK_DONE carries the SAME corr_objective (objective->settlement link)
    $null = Invoke-OrchestrationTaskTransition -TaskId 'corr-001' -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'corr-001' -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'corr-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:zebra renders') -ProducedBy 'coder' -ExpectedRevision 3 -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Invoke-OrchestrationTaskTransition -TaskId 'corr-001' -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision 4 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskVerification -TaskId 'corr-001' -VerifierEvidenceJson (New-CorrVerifierJson -Evidence @('criterion:0:verified zebra')) -ExpectedRevision 5 -TasksDir $t.tasks -FlagsPath $t.flags
    $null = Invoke-OrchestrationTaskTransition -TaskId 'corr-001' -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision 6 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $null = Set-OrchestrationTaskReview -TaskId 'corr-001' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 7 -TasksDir $t.tasks -FlagsPath $t.flags
    $done = Complete-OrchestrationTask -TaskId 'corr-001' -Actor 'planner' -ExpectedRevision 8 -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Correlation ([bool]$done.ok) 'DONE still completes with envelope wired (gate untouched)'
    $dones = @(Get-CorrTelemetryLines -Root $t.root -EventType 'TASK_DONE')
    Assert-Correlation (($dones.Count -ge 1)) 'TASK_DONE telemetry persisted'
    $dm = $dones[0].metadata
    $dprops = @($dm.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-Correlation ((($dprops -contains 'corr_objective') -and ($dprops -contains 'corr_decision')) -and ($dprops -contains 'corr_settlement')) 'done event carries objective/decision/settlement correlation'
    Assert-Correlation (([string]$dm.corr_objective -ceq $createdObj) -and (-not [string]::IsNullOrWhiteSpace($createdObj))) 'done corr_objective equals created corr_objective'
    Assert-Correlation (([string]$dm.corr_decision -ceq [string]$cm.corr_decision)) 'done corr_decision equals created corr_decision'
    Assert-Correlation ((@($dprops).Count -le 10)) 'done metadata respects the ten-key cap'

    # 6. write failure never breaks the flow (blocked JSONL target)
    $b = New-CorrTestRoot
    [void]$roots.Add($b.root)
    $bstamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
    $btarget = Join-Path $b.root ('cache\v3\telemetry\events-' + $bstamp + '.jsonl')
    New-Item -ItemType Directory -Path $btarget -Force | Out-Null
    $bw = $false
    try {
        $bc = New-OrchestrationTask -TaskId 'corr-002' -Objective 'Blocked telemetry still creates' -Actor 'planner' `
            -TasksDir $b.tasks -FlagsPath $b.flags -TelemetryRoot $b.root
        $bw = [bool]$bc.ok
    }
    catch { $bw = $false }
    Assert-Correlation ($bw) 'create succeeds even when the telemetry write fails'

    # 7. F6-FIX1: full runtime (4 base) + full envelope (7 corr) persists
    # all 7 corr_* including corr_settlement, read back from the JSONL file
    $f = New-CorrTestRoot
    [void]$roots.Add($f.root)
    $fullEnv = New-CorrelationEnvelope -GoalId 'goal-42' -Objective 'Full runtime keeps settlement' `
        -RunId 'run-7' -SessionId 'sess-abc-123' -AttemptN 3 `
        -DecisionRef 'MULTI_WORKER' -SettlementState 'settled'
    Assert-Correlation ((@($fullEnv.Keys).Count -eq 7)) 'fix1 precondition: envelope carries seven corr keys'
    $fullRt = [ordered]@{ id = 'opencode-v1'; generation = 2; profile = 'v1' }
    $sentFull = $false
    try {
        $sentFull = [bool](Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId 'corr-full-001' -Runtime $fullRt -TelemetryRoot $f.root -Correlation $fullEnv)
    }
    catch { $sentFull = $false }
    Assert-Correlation ($sentFull) 'full runtime + full envelope telemetry write succeeds'
    $fullLines = @(Get-CorrTelemetryLines -Root $f.root -EventType 'TASK_CREATED')
    Assert-Correlation (($fullLines.Count -ge 1)) 'full envelope event read back from JSONL file'
    if ($fullLines.Count -ge 1) {
        $fm = $fullLines[0].metadata
        $fprops = @($fm.PSObject.Properties | ForEach-Object { $_.Name })
        $seven = @('corr_goal', 'corr_objective', 'corr_run', 'corr_sess', 'corr_attempt', 'corr_decision', 'corr_settlement')
        $missing = @($seven | Where-Object { $fprops -notcontains $_ })
        Assert-Correlation (($missing.Count -eq 0)) 'all seven corr_* present with full runtime, including corr_settlement'
        Assert-Correlation ((@($fprops).Count -le 10)) 'full envelope metadata still respects the ten-key cap'
        $fstamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        $fjf = Join-Path $f.root ('cache\v3\telemetry\events-' + $fstamp + '.jsonl')
        $fraw = [IO.File]::ReadAllText($fjf)
        Assert-Correlation ((($fraw -notmatch 'goal-42') -and ($fraw -notmatch 'sess-abc')) -and ($fraw -notmatch 'MULTI_WORKER')) 'full envelope file holds no raw id text'
    }

    # 8. F6-FIX1: no-correlation path keeps the exact base key order
    $n = New-CorrTestRoot
    [void]$roots.Add($n.root)
    $baseRt = [ordered]@{ id = 'opencode-v1'; generation = 1; profile = 'v1' }
    $sentBase = $false
    try {
        $sentBase = [bool](Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId 'corr-base-001' -Runtime $baseRt -TelemetryRoot $n.root)
    }
    catch { $sentBase = $false }
    Assert-Correlation ($sentBase) 'base-only telemetry write succeeds'
    $baseLines = @(Get-CorrTelemetryLines -Root $n.root -EventType 'TASK_CREATED')
    Assert-Correlation (($baseLines.Count -ge 1)) 'base-only event read back from JSONL file'
    if ($baseLines.Count -ge 1) {
        $bm = $baseLines[0].metadata
        $bprops = @($bm.PSObject.Properties | ForEach-Object { $_.Name })
        $expectedBase = @('task_id_hash', 'runtime_id', 'runtime_generation', 'profile')
        $sameOrder = (($bprops.Count -eq $expectedBase.Count))
        if ($sameOrder) {
            for ($bi = 0; $bi -lt $expectedBase.Count; $bi++) {
                if ([string]$bprops[$bi] -cne [string]$expectedBase[$bi]) { $sameOrder = $false; break }
            }
        }
        Assert-Correlation ($sameOrder) 'no-correlation metadata keeps exact base order (byte-identical path)'
    }
    $e2 = New-CorrTestRoot
    [void]$roots.Add($e2.root)
    $sentEmpty = $false
    try {
        $emptyCorr = [ordered]@{}
        $sentEmpty = [bool](Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId 'corr-base-001' -Runtime $baseRt -TelemetryRoot $e2.root -Correlation $emptyCorr)
    }
    catch { $sentEmpty = $false }
    Assert-Correlation ($sentEmpty) 'empty-dict correlation behaves like absent correlation'
    $emptyLines = @(Get-CorrTelemetryLines -Root $e2.root -EventType 'TASK_CREATED')
    if (($baseLines.Count -ge 1) -and ($emptyLines.Count -ge 1)) {
        $eprops = @($emptyLines[0].metadata.PSObject.Properties | ForEach-Object { $_.Name })
        $bprops2 = @($baseLines[0].metadata.PSObject.Properties | ForEach-Object { $_.Name })
        Assert-Correlation ((($eprops -join ',') -ceq ($bprops2 -join ','))) 'empty correlation yields identical base key sequence'
    }
    else {
        Assert-Correlation $false 'empty correlation event read back for comparison'
    }
}
finally {
    foreach ($r in @($roots)) {
        try { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Host ("[SUMMARY] passed={0} failed={1}" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
