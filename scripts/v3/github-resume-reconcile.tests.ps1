# github-resume-reconcile.tests.ps1 -- F3 Etapa B/C one-shot reconcile harness.
# Custom PS 5.1 / PS7 suite, no Pester. Hermetic temp dirs, offline only
# (no network, no gh, no daemon). Covers: one-shot shape (no sleep/loop/
# timer/retry/watcher/daemon/scheduler/service/network/merge), authority
# pins (ghwait is transport, Kernel is authority, no second store), per
# ghwait reconcile via Get-OrchestrationGitHubWaits + fresh fixture
# snapshot + Test-OrchestrationGitHubResume with live flags, RESUME-only
# Confirm (CAS) + Kernel unblock referencing the active_wait fingerprint,
# READY notify-only, fault injection (CI pending->success, pending->
# failure, review changes-requested, SHA superseded, duplicate, out of
# order, restart before/after persistence, cancel, expiry, 2 watchers,
# auth failure => HOLD, binding-first kernel-first RESUME (ghwait bound
# to authoritative active_wait, unblock before Confirm, refusal consumes
# nothing), pending-confirm reconcile, fail-closed flags/policy, CAS
# conflict), TDD RED->GREEN, HARNESS_PASS only (never
# AUTO_RESUME_PASS runtime-real), scheduling gap documented.
param()
$ErrorActionPreference = 'Stop'

$script:harness = Join-Path $PSScriptRoot 'github-resume-reconcile.ps1'
if (-not (Test-Path -LiteralPath $script:harness -PathType Leaf)) { throw 'RED: github-resume-reconcile.ps1 not found (expected before GREEN)' }
. $script:harness
try {
    $script:awLib = Join-Path (Join-Path $PSScriptRoot 'lib') 'OrchestrationAutonomyWiring.ps1'
    if (Test-Path -LiteralPath $script:awLib -PathType Leaf) { . $script:awLib }
}
catch { }

$script:passed = 0
$script:failed = 0
function Assert-GRR {
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

# --- 0. one-shot shape: static text gates (harness must stay a CLI harness).
$script:text = [IO.File]::ReadAllText($script:harness, [Text.Encoding]::UTF8)
foreach ($bad in @('Start-Sleep', 'while\s*\(', 'System\.Timers', 'Register-ObjectEvent', 'Start-Job', 'Register-Scheduled', 'New-Service', 'Start-Service', 'FileSystemWatcher', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Command', 'Start-Process', 'gh api', 'gh pr merge', 'gh pr create', '--method POST', '--method PUT', '--method PATCH', '--method DELETE', 'Complete-OrchestrationTask', 'Block-OrchestrationTask', 'New-OrchestrationTask', 'Set-OrchestrationTaskWorkerResult', 'AUTO_RESUME_PASS', 'GH_TOKEN', 'GITHUB_TOKEN', 'Remove-Item')) {
    Assert-GRR ($script:text -cnotmatch $bad) ('harness has no forbidden pattern: ' + $bad)
}
foreach ($need in @('Get-OrchestrationGitHubWaits', 'Test-OrchestrationGitHubResume', 'Confirm-OrchestrationGitHubResumeApplied', 'Invoke-OrchestrationTaskTransition', 'Test-TaskKernelActiveWait', 'scheduling_gap')) {
    Assert-GRR ($script:text -cmatch $need) ('harness carries required call: ' + $need)
}
Assert-GRR ($script:text -cmatch 'IMPLEMENTING') 'harness unblocks toward IMPLEMENTING only (never DONE/merge)'
Assert-GRR ($script:text -cnotmatch 'grants_authority = \$true') 'harness never claims grant authority'
Assert-GRR ($script:text -cnotmatch 'resume_authorized = \$true') 'harness never hardcodes resume authorization'
Assert-GRR ($script:text -cnotmatch 'kernel_mutated\s*=\s*\$true') 'harness never hardcodes kernel mutation'
Assert-GRR ($script:text -cnotmatch 'C:\\Users') 'harness has no machine-specific path'
Assert-GRR ($null -ne (Get-Command Invoke-GitHubResumeReconcile -ErrorAction SilentlyContinue)) 'dot-source exposes Invoke-GitHubResumeReconcile'

# --- fixture helpers (explicit live flags; fail-closed when absent/invalid).
$script:REPO = 'acme/widgets'
$script:PR = 42
$script:SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:NOW = '2026-10-20T12:00:00Z'
$script:FUTURE = '2030-01-01T00:00:00Z'
$script:PAST = '2020-01-01T00:00:00Z'
$script:PolicyPath = Join-Path (Join-Path $PSScriptRoot 'lib') '..\..\..\source\registry\delivery-policy.json'
$script:policy = $null
try { $script:policy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($script:PolicyPath))) } catch { $script:policy = $null }

function Read-GRRJson {
    param([string]$Path)
    return (ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)))
}

function New-GRRRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-grr-' + [guid]::NewGuid().ToString('N'))
    $waits = Join-Path $root 'waits'
    $snaps = Join-Path $root 'snaps'
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $waits -Force | Out-Null
    New-Item -ItemType Directory -Path $snaps -Force | Out-Null
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    [IO.File]::WriteAllText($flags, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
    return @{ root = $root; waits = $waits; snaps = $snaps; tasks = $tasks; flags = $flags }
}

function Get-GRRChecks {
    try { return (Get-OrchestrationDeliveryRequiredChecks $null) } catch { return $null }
}

function New-GRRSnapshot {
    param([string]$HeadSha, [string]$Review = 'APPROVED', [string]$Mode = 'success')
    $checks = New-Object System.Collections.ArrayList
    foreach ($n in @(Get-GRRChecks)) {
        $st = 'COMPLETED'
        $con = 'success'
        if ($Mode -ceq 'pending') { $st = 'IN_PROGRESS'; $con = $null }
        elseif ($Mode -ceq 'failure') { $con = 'failure' }
        $e = [ordered]@{ name = ([string]$n); head_sha = ([string]$HeadSha); status = $st; conclusion = $con }
        [void]$checks.Add($e)
    }
    $cc = $true
    if ($Mode -ceq 'pending') { $cc = $false }
    return [ordered]@{
        repository = $script:REPO; pr_number = [long]$script:PR
        head_sha = ([string]$HeadSha); commit_sha = ([string]$HeadSha)
        observed_at = $script:NOW; pr_state = 'OPEN'; mergeable = 'MERGEABLE'
        review_decision = ([string]$Review); checks_complete = $cc
        checks = @($checks.ToArray())
    }
}

function Write-GRRJson {
    param([string]$Path, $Doc)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $j = ConvertTo-Json -InputObject $Doc -Depth 10 -Compress
    [IO.File]::WriteAllText($Path, $j, (New-Object Text.UTF8Encoding $false))
}

function New-GRRCase {
    param($Root, [string]$Id, [string]$Mode = 'success', [string]$Review = 'APPROVED', $Flags = $null, [string]$Deadline = '')
    if ([string]::IsNullOrWhiteSpace($Deadline)) { $Deadline = $script:FUTURE }
    $dl = $Deadline
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Root.waits -ObjectiveId ('goal-' + $Id) `
        -TaskId $Id -RunId ('run-' + $Id) -Generation 0 -Repository $script:REPO `
        -PrNumber $script:PR -Branch 'feat/x' -ExpectedHeadSha $script:SHA_A `
        -RequiredChecks @(Get-GRRChecks) -ReviewExpectation 'APPROVED' -Cursor '' `
        -DeadlineUtc $dl -RetryBudgetMax 3 -LeaseOwner 'kernel-owner' `
        -LeaseExpiresUtc $script:FUTURE -Owner 'kernel-owner'
    if (-not [bool]$reg.ok) { throw ('RED register failed: ' + [string]$reg.reason) }
    $nt = New-OrchestrationTask -TaskId $Id -Objective ('Reconcile ' + $Id) -TaskType 'implementation' `
        -Risk 'low' -Actor 'planner' -Project 'proj-grr' -RuntimeId 'opencode-v1' `
        -RuntimeGeneration 1 -RuntimeProfile 'v1' -ReadScopes @('src/a') -WriteScopes @('src/a') `
        -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('reconciled') -AttemptBudget 3 `
        -TasksDir $Root.tasks -FlagsPath $Root.flags -TelemetryRoot $Root.root
    if (-not [bool]$nt.ok) { throw ('RED task create failed: ' + [string]$nt.error) }
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' `
        -ExpectedRevision ([int]$nt.revision) -TasksDir $Root.tasks -FlagsPath $Root.flags -TelemetryRoot $Root.root
    $toImpl = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' `
        -ExpectedRevision (([int]$nt.revision) + 1) -ActorIdentitySource 'explicit-cli' `
        -TasksDir $Root.tasks -FlagsPath $Root.flags -TelemetryRoot $Root.root
    if (-not [bool]$toImpl.ok) { throw ('RED to-implementing failed: ' + [string]$toImpl.error) }
    $wr = New-OrchestrationGitHubWaitRequest -Repository $script:REPO -PrNumber $script:PR `
        -ExpectedHeadSha $script:SHA_A -Owner 'kernel-owner'
    if (-not [bool]$wr.ok) { throw 'RED wait request failed' }
    $bl = Block-OrchestrationTask -TaskId $Id -Actor 'planner' -ExpectedRevision ([int]$toImpl.revision) `
        -Reason 'github-ci-wait' -WaitType 'external_dependency' -WaitOwner 'kernel-owner' `
        -WaitAction 'revalidate-github-ci' -WaitDependencyId ([string]$wr.WaitDependencyId) `
        -TasksDir $Root.tasks -FlagsPath $Root.flags -TelemetryRoot $Root.root
    if (-not [bool]$bl.ok) { throw ('RED block failed: ' + [string]$bl.error) }
    Write-GRRJson -Path (Join-Path $Root.snaps ($Id + '.snapshot.json')) -Doc (New-GRRSnapshot -HeadSha $script:SHA_A -Review $Review -Mode $Mode)
    $baseFlags = [ordered]@{
        lease_alive = $true; owner_alive = $true; authorization_alive = $true
        executor_present = $true; cancel_requested = $false; github_auth_ok = $true
    }
    if ($null -ne $Flags) {
        if ($Flags -is [System.Collections.IDictionary]) {
            foreach ($k in @($Flags.Keys)) { $baseFlags[[string]$k] = $Flags[[string]$k] }
        }
        else {
            foreach ($pp in @($Flags.PSObject.Properties)) { $baseFlags[[string]$pp.Name] = $pp.Value }
        }
    }
    Write-GRRJson -Path (Join-Path $Root.snaps ($Id + '.flags.json')) -Doc $baseFlags
    return @{ wait = $reg.wait; depid = ([string]$wr.WaitDependencyId) }
}

function Get-GRRTaskState {
    param($Root, [string]$Id)
    $f = Join-Path $Root.tasks ($Id + '.json')
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
    return ([string]$doc.state)
}

function Get-GRRItem {
    param($Out, [string]$Id)
    foreach ($i in @($Out.items)) {
        if ([string]$i.task_id -ceq $Id) { return $i }
    }
    return $null
}

# --- 1. CI pending -> KEEP_WAITING: no Confirm, kernel stays BLOCKED.
$script:r1 = New-GRRRoot
$null = New-GRRCase -Root $script:r1 -Id 'f3-rec-pending' -Mode 'pending'
$script:o1 = Invoke-GitHubResumeReconcile -WaitsDir $script:r1.waits -SnapshotsDir $script:r1.snaps `
    -TasksDir $script:r1.tasks -FlagsPath $script:r1.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i1 = Get-GRRItem $script:o1 'f3-rec-pending'
Assert-GRR (([bool]$script:o1.ok) -and ([string]$script:o1.verdict -ceq 'HARNESS_PASS')) 'pending run keeps HARNESS_PASS'
Assert-GRR (([string]$script:i1.decision -ceq 'KEEP_WAITING')) 'CI pending => KEEP_WAITING'
Assert-GRR ((-not [bool]$script:i1.confirmed) -and ([string]$script:i1.kernel -ceq 'not-attempted')) 'KEEP_WAITING performs no Confirm and no kernel write'
Assert-GRR ((Get-GRRTaskState $script:r1 'f3-rec-pending') -ceq 'BLOCKED') 'kernel stays BLOCKED while checks pending'

# --- 2. pending -> success: RESUME confirms (CAS) + Kernel unblocks with fingerprint.
$snapOk = New-GRRSnapshot -HeadSha $script:SHA_A -Review 'APPROVED' -Mode 'success'
Write-GRRJson -Path (Join-Path $script:r1.snaps 'f3-rec-pending.snapshot.json') -Doc $snapOk
$script:o2 = Invoke-GitHubResumeReconcile -WaitsDir $script:r1.waits -SnapshotsDir $script:r1.snaps `
    -TasksDir $script:r1.tasks -FlagsPath $script:r1.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i2 = Get-GRRItem $script:o2 'f3-rec-pending'
Assert-GRR (([string]$script:i2.decision -ceq 'RESUME')) 'CI success + APPROVED => RESUME'
Assert-GRR (([bool]$script:i2.confirmed) -and ([string]$script:i2.kernel -ceq 'unblocked') -and [bool]$script:i2.kernel_mutated) 'RESUME confirms (CAS) and unblocks the Kernel'
Assert-GRR ((Get-GRRTaskState $script:r1 'f3-rec-pending') -ceq 'IMPLEMENTING') 'kernel advances BLOCKED->IMPLEMENTING only via fingerprint reference'
Assert-GRR ([bool]$script:o2.kernel_mutated) 'envelope reports kernel_mutated on RESUME unblock'

# --- 3. restart after persistence: same event => DUPLICATE_NOOP, no double advance.
$script:o3 = Invoke-GitHubResumeReconcile -WaitsDir $script:r1.waits -SnapshotsDir $script:r1.snaps `
    -TasksDir $script:r1.tasks -FlagsPath $script:r1.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i3 = Get-GRRItem $script:o3 'f3-rec-pending'
Assert-GRR (([string]$script:i3.decision -ceq 'DUPLICATE_NOOP')) 'restart after Confirm => DUPLICATE_NOOP (idempotent)'
Assert-GRR (([string]$script:i3.kernel -ceq 'not-attempted')) 'duplicate performs no second kernel write'
Assert-GRR ((Get-GRRTaskState $script:r1 'f3-rec-pending') -ceq 'IMPLEMENTING') 'kernel advances exactly once'

# --- 4. pending -> failure: TERMINAL diagnostic, no Confirm, kernel untouched.
$script:r4 = New-GRRRoot
$null = New-GRRCase -Root $script:r4 -Id 'f3-rec-fail' -Mode 'failure'
$script:o4 = Invoke-GitHubResumeReconcile -WaitsDir $script:r4.waits -SnapshotsDir $script:r4.snaps `
    -TasksDir $script:r4.tasks -FlagsPath $script:r4.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i4 = Get-GRRItem $script:o4 'f3-rec-fail'
Assert-GRR (([string]$script:i4.decision -ceq 'TERMINAL')) 'CI failure => TERMINAL (diagnostic)'
Assert-GRR ((-not [bool]$script:i4.confirmed) -and ([string]$script:i4.kernel -ceq 'not-attempted')) 'TERMINAL performs no Confirm and no kernel write'
Assert-GRR ((Get-GRRTaskState $script:r4 'f3-rec-fail') -ceq 'BLOCKED') 'kernel stays BLOCKED on diagnostic terminal'

# --- 5. review changes-requested => TERMINAL, no Confirm.
$script:r5 = New-GRRRoot
$null = New-GRRCase -Root $script:r5 -Id 'f3-rec-review' -Mode 'success' -Review 'CHANGES_REQUESTED'
$script:o5 = Invoke-GitHubResumeReconcile -WaitsDir $script:r5.waits -SnapshotsDir $script:r5.snaps `
    -TasksDir $script:r5.tasks -FlagsPath $script:r5.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i5 = Get-GRRItem $script:o5 'f3-rec-review'
Assert-GRR (([string]$script:i5.decision -ceq 'TERMINAL')) 'changes-requested => TERMINAL'
Assert-GRR (-not [bool]$script:i5.confirmed) 'changes-requested performs no Confirm'

# --- 6. SHA superseded => TERMINAL head-superseded, no Confirm.
$script:r6 = New-GRRRoot
$null = New-GRRCase -Root $script:r6 -Id 'f3-rec-sha' -Mode 'success'
Write-GRRJson -Path (Join-Path $script:r6.snaps 'f3-rec-sha.snapshot.json') -Doc (New-GRRSnapshot -HeadSha $script:SHA_B -Review 'APPROVED' -Mode 'success')
$script:o6 = Invoke-GitHubResumeReconcile -WaitsDir $script:r6.waits -SnapshotsDir $script:r6.snaps `
    -TasksDir $script:r6.tasks -FlagsPath $script:r6.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i6 = Get-GRRItem $script:o6 'f3-rec-sha'
Assert-GRR (([string]$script:i6.decision -ceq 'TERMINAL')) 'SHA mismatch => TERMINAL'
Assert-GRR ((-not [bool]$script:i6.confirmed) -and ([string]$script:i6.kernel -ceq 'not-attempted')) 'superseded wait performs no Confirm and no kernel write'

# --- 7. out-of-order event => OUT_OF_ORDER, no Confirm.
$script:r7 = New-GRRRoot
$null = New-GRRCase -Root $script:r7 -Id 'f3-rec-ooo' -Mode 'success' -Flags ([ordered]@{ event_dedup_key = 'github-resume:v1:other/repo:9:cccccccccccccccccccccccccccccccccccccccc:0' })
$script:o7 = Invoke-GitHubResumeReconcile -WaitsDir $script:r7.waits -SnapshotsDir $script:r7.snaps `
    -TasksDir $script:r7.tasks -FlagsPath $script:r7.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i7 = Get-GRRItem $script:o7 'f3-rec-ooo'
Assert-GRR (([string]$script:i7.decision -ceq 'OUT_OF_ORDER')) 'foreign event key => OUT_OF_ORDER'
Assert-GRR (-not [bool]$script:i7.confirmed) 'out-of-order performs no Confirm'

# --- 8. restart before persistence: Test alone persists nothing; reconcile then RESUMEs.
$script:r8 = New-GRRRoot
$null = New-GRRCase -Root $script:r8 -Id 'f3-rec-restart' -Mode 'success'
$lw8 = Get-OrchestrationGitHubWaits -WaitsDir $script:r8.waits
$w8 = $null
foreach ($cand in @($lw8.waits)) { if ([string]$cand.task_id -ceq 'f3-rec-restart') { $w8 = $cand } }
$snap8 = Read-GRRJson -Path (Join-Path $script:r8.snaps 'f3-rec-restart.snapshot.json')
$dec8 = Test-OrchestrationGitHubResume -Wait $w8 -Snapshot $snap8 -Policy $script:policy -NowUtc $script:NOW `
    -MaxAgeSeconds 300 -LeaseAlive $true -OwnerAlive $true -AuthorizationAlive $true `
    -ExecutorPresent $true -CancelRequested $false -AlreadyApplied $false -EventDedupKey ''
$lw8b = Get-OrchestrationGitHubWaits -WaitsDir $script:r8.waits
$w8b = $null
foreach ($cand in @($lw8b.waits)) { if ([string]$cand.task_id -ceq 'f3-rec-restart') { $w8b = $cand } }
$ap8 = @()
try { $ap8 = @($w8b.applied_events) } catch { $ap8 = @() }
Assert-GRR (([string]$dec8.decision -ceq 'RESUME') -and (@($ap8).Count -eq 0)) 'decision without Confirm persists nothing (restart-before safe)'
$script:o8 = Invoke-GitHubResumeReconcile -WaitsDir $script:r8.waits -SnapshotsDir $script:r8.snaps `
    -TasksDir $script:r8.tasks -FlagsPath $script:r8.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i8 = Get-GRRItem $script:o8 'f3-rec-restart'
Assert-GRR (([string]$script:i8.decision -ceq 'RESUME') -and [bool]$script:i8.confirmed) 'post-restart reconcile RESUMEs and confirms once'

# --- 9. cancel => TERMINAL cancelled, no Confirm.
$script:r9 = New-GRRRoot
$null = New-GRRCase -Root $script:r9 -Id 'f3-rec-cancel' -Mode 'success' -Flags ([ordered]@{ cancel_requested = $true })
$script:o9 = Invoke-GitHubResumeReconcile -WaitsDir $script:r9.waits -SnapshotsDir $script:r9.snaps `
    -TasksDir $script:r9.tasks -FlagsPath $script:r9.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i9 = Get-GRRItem $script:o9 'f3-rec-cancel'
Assert-GRR (([string]$script:i9.decision -ceq 'TERMINAL') -and (-not [bool]$script:i9.confirmed)) 'cancel => TERMINAL without Confirm'

# --- 10. expiry => TERMINAL wait-expired, no Confirm.
$script:r10 = New-GRRRoot
$null = New-GRRCase -Root $script:r10 -Id 'f3-rec-expire' -Mode 'success' -Deadline $script:PAST
$script:o10 = Invoke-GitHubResumeReconcile -WaitsDir $script:r10.waits -SnapshotsDir $script:r10.snaps `
    -TasksDir $script:r10.tasks -FlagsPath $script:r10.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i10 = Get-GRRItem $script:o10 'f3-rec-expire'
Assert-GRR (([string]$script:i10.decision -ceq 'TERMINAL') -and (-not [bool]$script:i10.confirmed)) 'expired deadline => TERMINAL without Confirm'

# --- 11. two watchers, same event: second Confirm is duplicate-suppressed (dedupe).
$script:r11 = New-GRRRoot
$case11 = New-GRRCase -Root $script:r11 -Id 'f3-rec-race' -Mode 'success'
$ddk11 = ([string]$case11.wait.dedup_key)
$cfA = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r11.waits -DedupKey $ddk11 -EventId 'evt-f3-rec-race'
$cfB = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r11.waits -DedupKey $ddk11 -EventId 'evt-f3-rec-race'
Assert-GRR (([bool]$cfA.ok -and (-not [bool]$cfA.reused)) -and ([bool]$cfB.ok -and [bool]$cfB.reused)) 'concurrent watchers dedupe: exactly one applier, other duplicate-suppressed'

# --- 12. second watcher, new event: harness RESUMEs once (direct Confirms never
# unblock); a third event afterwards is Confirm-applied but Kernel-refused.
[IO.File]::WriteAllText((Join-Path $script:r11.snaps 'f3-rec-race.eventid.txt'), 'evt-f3-rec-race-second', (New-Object Text.UTF8Encoding $false))
$script:o12 = Invoke-GitHubResumeReconcile -WaitsDir $script:r11.waits -SnapshotsDir $script:r11.snaps `
    -TasksDir $script:r11.tasks -FlagsPath $script:r11.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i12 = Get-GRRItem $script:o12 'f3-rec-race'
Assert-GRR (([string]$script:i12.decision -ceq 'RESUME') -and ([string]$script:i12.kernel -ceq 'unblocked')) 'second watcher event RESUMEs exactly once via the harness'
Assert-GRR ((Get-GRRTaskState $script:r11 'f3-rec-race') -ceq 'IMPLEMENTING') 'kernel advances exactly once (direct Confirms never unblock)'
[IO.File]::WriteAllText((Join-Path $script:r11.snaps 'f3-rec-race.eventid.txt'), 'evt-f3-rec-race-third', (New-Object Text.UTF8Encoding $false))
$script:o12b = Invoke-GitHubResumeReconcile -WaitsDir $script:r11.waits -SnapshotsDir $script:r11.snaps `
    -TasksDir $script:r11.tasks -FlagsPath $script:r11.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i12b = Get-GRRItem $script:o12b 'f3-rec-race'
Assert-GRR (([string]$script:i12b.decision -ceq 'HOLD') -and ([string]$script:i12b.kernel -cnotmatch 'unblocked') -and (-not [bool]$script:i12b.kernel_mutated)) 'late third event after resume => HOLD, no second kernel mutation'
Assert-GRR ((Get-GRRTaskState $script:r11 'f3-rec-race') -ceq 'IMPLEMENTING') 'kernel stays IMPLEMENTING (no double advance)'

# --- 13. auth failure => HOLD github-auth-failed, no Test side effect, no Confirm, kernel BLOCKED.
$script:r13 = New-GRRRoot
$null = New-GRRCase -Root $script:r13 -Id 'f3-rec-auth' -Mode 'success' -Flags ([ordered]@{ github_auth_ok = $false })
$script:o13 = Invoke-GitHubResumeReconcile -WaitsDir $script:r13.waits -SnapshotsDir $script:r13.snaps `
    -TasksDir $script:r13.tasks -FlagsPath $script:r13.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i13 = Get-GRRItem $script:o13 'f3-rec-auth'
Assert-GRR (([string]$script:i13.decision -ceq 'HOLD') -and ([string]$script:i13.reason -ceq 'github-auth-failed')) 'auth failure => HOLD github-auth-failed'
Assert-GRR ((-not [bool]$script:i13.confirmed) -and ([string]$script:i13.kernel -ceq 'not-attempted')) 'auth HOLD performs no Confirm and no kernel write'
Assert-GRR ((Get-GRRTaskState $script:r13 'f3-rec-auth') -ceq 'BLOCKED') 'kernel stays BLOCKED on auth HOLD'

# --- 14. READY without executor: notify only, no Confirm, kernel BLOCKED.
$script:r14 = New-GRRRoot
$null = New-GRRCase -Root $script:r14 -Id 'f3-rec-ready' -Mode 'success' -Flags ([ordered]@{ executor_present = $false })
$script:o14 = Invoke-GitHubResumeReconcile -WaitsDir $script:r14.waits -SnapshotsDir $script:r14.snaps `
    -TasksDir $script:r14.tasks -FlagsPath $script:r14.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i14 = Get-GRRItem $script:o14 'f3-rec-ready'
Assert-GRR (([string]$script:i14.decision -ceq 'READY')) 'ready snapshot without executor => READY (observation only)'
Assert-GRR ((-not [bool]$script:i14.confirmed) -and ([string]$script:i14.kernel -ceq 'not-attempted') -and (-not [string]::IsNullOrWhiteSpace([string]$script:i14.notify))) 'READY only notifies'
Assert-GRR ((Get-GRRTaskState $script:r14 'f3-rec-ready') -ceq 'BLOCKED') 'kernel stays BLOCKED on READY'

# --- 15. envelope pins: HARNESS_PASS only, gap documented, no runtime-real claim.
Assert-GRR (([string]$script:o2.verdict -ceq 'HARNESS_PASS')) 'harness declares HARNESS_PASS'
Assert-GRR (([string]$script:o2.verdict -cne 'AUTO_RESUME_PASS')) 'harness never declares AUTO_RESUME_PASS'
Assert-GRR ((-not [bool]$script:o2.grants_authority) -and (-not [bool]$script:o2.done_approved) -and (-not [bool]$script:o2.merge_authority)) 'envelope carries authority pins false'
Assert-GRR (-not [string]::IsNullOrWhiteSpace([string]$script:o2.scheduling_gap)) 'envelope documents the scheduling/wake gap'

# --- 16. R1 pending-confirm reconcile: event Confirm-applied but Kernel
# still BLOCKED (crash window) => next run heals via unblock, exactly once.
$script:r16 = New-GRRRoot
$case16 = New-GRRCase -Root $script:r16 -Id 'f3-rec-pendheal' -Mode 'success'
$cf16 = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r16.waits -DedupKey ([string]$case16.wait.dedup_key) -EventId 'evt-f3-rec-pendheal'
Assert-GRR ([bool]$cf16.ok) 'pending-heal setup: direct Confirm applies the event'
Assert-GRR ((Get-GRRTaskState $script:r16 'f3-rec-pendheal') -ceq 'BLOCKED') 'pending-heal setup: kernel still BLOCKED (crash window)'
$script:o16 = Invoke-GitHubResumeReconcile -WaitsDir $script:r16.waits -SnapshotsDir $script:r16.snaps `
    -TasksDir $script:r16.tasks -FlagsPath $script:r16.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i16 = Get-GRRItem $script:o16 'f3-rec-pendheal'
Assert-GRR (([string]$script:i16.decision -ceq 'RESUME') -and ([string]$script:i16.reason -ceq 'reconciled-pending-confirm')) 'pending Confirm with matching BLOCKED wait reconciles to RESUME'
Assert-GRR (([string]$script:i16.kernel -ceq 'unblocked') -and [bool]$script:i16.kernel_mutated -and [bool]$script:i16.confirmed) 'pending reconcile unblocks exactly once and keeps the event marked'
Assert-GRR ((Get-GRRTaskState $script:r16 'f3-rec-pendheal') -ceq 'IMPLEMENTING') 'kernel advances BLOCKED->IMPLEMENTING on reconcile'
Assert-GRR ([bool]$script:o16.resume_authorized) 'envelope resume_authorized is effective-only (true after proven unblock)'

# --- 16b. duplicate recovery revalidates: revoked authorization => HOLD, no unblock.
$script:r16b = New-GRRRoot
$case16b = New-GRRCase -Root $script:r16b -Id 'f3-rec-dupauth' -Mode 'success'
$cf16b = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r16b.waits -DedupKey ([string]$case16b.wait.dedup_key) -EventId 'evt-f3-rec-dupauth'
Assert-GRR ([bool]$cf16b.ok) 'dup-auth setup: direct Confirm applies the event'
$fb16b = Read-GRRJson -Path (Join-Path $script:r16b.snaps 'f3-rec-dupauth.flags.json')
$fb16b.authorization_alive = $false
Write-GRRJson -Path (Join-Path $script:r16b.snaps 'f3-rec-dupauth.flags.json') -Doc $fb16b
$script:o16b = Invoke-GitHubResumeReconcile -WaitsDir $script:r16b.waits -SnapshotsDir $script:r16b.snaps `
    -TasksDir $script:r16b.tasks -FlagsPath $script:r16b.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i16b = Get-GRRItem $script:o16b 'f3-rec-dupauth'
Assert-GRR (([string]$script:i16b.decision -ceq 'HOLD') -and ([string]$script:i16b.reason -clike 'revalidation-hold:*')) 'duplicate with revoked authorization => HOLD revalidation-hold'
Assert-GRR (([string]$script:i16b.kernel -cnotmatch 'unblocked') -and (-not [bool]$script:i16b.kernel_mutated)) 'revoked authorization performs no kernel unblock'
Assert-GRR ((Get-GRRTaskState $script:r16b 'f3-rec-dupauth') -ceq 'BLOCKED') 'kernel stays BLOCKED on revoked-authorization duplicate'
Assert-GRR ([bool]$script:i16b.confirmed) 'event stays marked (dedup stands, authorization refused)'

# --- 16c. duplicate recovery revalidates: absent executor => HOLD, no unblock.
$script:r16c = New-GRRRoot
$case16c = New-GRRCase -Root $script:r16c -Id 'f3-rec-dupexec' -Mode 'success'
$cf16c = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r16c.waits -DedupKey ([string]$case16c.wait.dedup_key) -EventId 'evt-f3-rec-dupexec'
Assert-GRR ([bool]$cf16c.ok) 'dup-executor setup: direct Confirm applies the event'
$fb16c = Read-GRRJson -Path (Join-Path $script:r16c.snaps 'f3-rec-dupexec.flags.json')
$fb16c.executor_present = $false
Write-GRRJson -Path (Join-Path $script:r16c.snaps 'f3-rec-dupexec.flags.json') -Doc $fb16c
$script:o16c = Invoke-GitHubResumeReconcile -WaitsDir $script:r16c.waits -SnapshotsDir $script:r16c.snaps `
    -TasksDir $script:r16c.tasks -FlagsPath $script:r16c.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i16c = Get-GRRItem $script:o16c 'f3-rec-dupexec'
Assert-GRR (([string]$script:i16c.decision -ceq 'HOLD') -and ([string]$script:i16c.reason -clike 'revalidation-hold:*')) 'duplicate without executor => HOLD revalidation-hold'
Assert-GRR (([string]$script:i16c.kernel -cnotmatch 'unblocked') -and (-not [bool]$script:i16c.kernel_mutated)) 'absent executor performs no kernel unblock'
Assert-GRR ((Get-GRRTaskState $script:r16c 'f3-rec-dupexec') -ceq 'BLOCKED') 'kernel stays BLOCKED on executor-absent duplicate'

# --- 16d. duplicate recovery revalidates: divergent policy => HOLD, no unblock.
$script:r16d = New-GRRRoot
$case16d = New-GRRCase -Root $script:r16d -Id 'f3-rec-duppol' -Mode 'success'
$cf16d = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r16d.waits -DedupKey ([string]$case16d.wait.dedup_key) -EventId 'evt-f3-rec-duppol'
Assert-GRR ([bool]$cf16d.ok) 'dup-policy setup: direct Confirm applies the event'
$script:pol16d = ConvertFrom-Json (ConvertTo-Json -InputObject $script:policy -Depth 10 -Compress)
$script:pol16d.required_checks = @(@($script:pol16d.required_checks) + @('CI (phantom-diverged-check)'))
$script:o16d = Invoke-GitHubResumeReconcile -WaitsDir $script:r16d.waits -SnapshotsDir $script:r16d.snaps `
    -TasksDir $script:r16d.tasks -FlagsPath $script:r16d.flags -Policy $script:pol16d -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i16d = Get-GRRItem $script:o16d 'f3-rec-duppol'
Assert-GRR (([string]$script:i16d.decision -ceq 'HOLD') -and ([string]$script:i16d.reason -clike 'revalidation-hold:*policy-diverged*')) 'duplicate with divergent policy => HOLD revalidation-hold:policy-diverged'
Assert-GRR (([string]$script:i16d.kernel -cnotmatch 'unblocked') -and (-not [bool]$script:i16d.kernel_mutated)) 'divergent policy performs no kernel unblock'
Assert-GRR ((Get-GRRTaskState $script:r16d 'f3-rec-duppol') -ceq 'BLOCKED') 'kernel stays BLOCKED on policy-diverged duplicate'

# --- 16e. duplicate recovery revalidates: stale snapshot (head superseded) => HOLD, no unblock.
$script:r16e = New-GRRRoot
$case16e = New-GRRCase -Root $script:r16e -Id 'f3-rec-dupstale' -Mode 'success'
$cf16e = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r16e.waits -DedupKey ([string]$case16e.wait.dedup_key) -EventId 'evt-f3-rec-dupstale'
Assert-GRR ([bool]$cf16e.ok) 'dup-stale setup: direct Confirm applies the event'
Write-GRRJson -Path (Join-Path $script:r16e.snaps 'f3-rec-dupstale.snapshot.json') -Doc (New-GRRSnapshot -HeadSha $script:SHA_B -Review 'APPROVED' -Mode 'success')
$script:o16e = Invoke-GitHubResumeReconcile -WaitsDir $script:r16e.waits -SnapshotsDir $script:r16e.snaps `
    -TasksDir $script:r16e.tasks -FlagsPath $script:r16e.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i16e = Get-GRRItem $script:o16e 'f3-rec-dupstale'
Assert-GRR (([string]$script:i16e.decision -ceq 'HOLD') -and ([string]$script:i16e.reason -clike 'revalidation-hold:*')) 'duplicate with stale snapshot => HOLD revalidation-hold'
Assert-GRR (([string]$script:i16e.kernel -cnotmatch 'unblocked') -and (-not [bool]$script:i16e.kernel_mutated)) 'stale snapshot performs no kernel unblock'
Assert-GRR ((Get-GRRTaskState $script:r16e 'f3-rec-dupstale') -ceq 'BLOCKED') 'kernel stays BLOCKED on stale-snapshot duplicate'

# --- 17. R2/S1 divergent active wait: Confirm must not run, kernel untouched.
$script:r17 = New-GRRRoot
$null = New-GRRCase -Root $script:r17 -Id 'f3-rec-diverge' -Mode 'success'
$tf17 = Join-Path $script:r17.tasks 'f3-rec-diverge.json'
$doc17 = Read-GRRJson -Path $tf17
$evilDep17 = 'github-ci:v1:evil/repo:9:cccccccccccccccccccccccccccccccccccccccc'
$fp17 = Get-OrchestrationWaitFingerprint -Type 'external_dependency' -Owner 'kernel-owner' -Action 'revalidate-github-ci' -DependencyId $evilDep17
$doc17.active_wait.dependency_id = $evilDep17
$doc17.active_wait.fingerprint = ([string]$fp17.fingerprint)
$j17 = ConvertTo-Json -InputObject $doc17 -Depth 10 -Compress
[IO.File]::WriteAllText($tf17, $j17, (New-Object Text.UTF8Encoding $false))
$script:o17 = Invoke-GitHubResumeReconcile -WaitsDir $script:r17.waits -SnapshotsDir $script:r17.snaps `
    -TasksDir $script:r17.tasks -FlagsPath $script:r17.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i17 = Get-GRRItem $script:o17 'f3-rec-diverge'
Assert-GRR (([string]$script:i17.decision -ceq 'HOLD') -and ([string]$script:i17.reason -clike 'wait-binding-mismatch*')) 'divergent active wait => HOLD wait-binding-mismatch'
Assert-GRR ((-not [bool]$script:i17.confirmed) -and ([string]$script:i17.kernel -ceq 'not-attempted')) 'binding refusal consumes no event and attempts no kernel write'
Assert-GRR ((Get-GRRTaskState $script:r17 'f3-rec-diverge') -ceq 'BLOCKED') 'kernel stays BLOCKED on binding refusal'
Assert-GRR (-not [bool]$script:o17.resume_authorized) 'envelope resume_authorized stays false on refusal'
$lw17 = Get-OrchestrationGitHubWaits -WaitsDir $script:r17.waits
$w17 = $null
foreach ($cand in @($lw17.waits)) { if ([string]$cand.task_id -ceq 'f3-rec-diverge') { $w17 = $cand } }
Assert-GRR ((@($w17.applied_events).Count -eq 0) -and (-not [bool]$script:o17.kernel_mutated)) 'no event consumed and no kernel mutation on refusal'

# --- 18. S2 fail-closed flags: invalid value and missing file => HOLD, nothing consumed.
$script:r18 = New-GRRRoot
$null = New-GRRCase -Root $script:r18 -Id 'f3-rec-badflag' -Mode 'success' -Flags ([ordered]@{ lease_alive = 'yes' })
$script:o18 = Invoke-GitHubResumeReconcile -WaitsDir $script:r18.waits -SnapshotsDir $script:r18.snaps `
    -TasksDir $script:r18.tasks -FlagsPath $script:r18.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i18 = Get-GRRItem $script:o18 'f3-rec-badflag'
Assert-GRR (([string]$script:i18.decision -ceq 'HOLD') -and ([string]$script:i18.reason -ceq 'flag-invalid-lease_alive')) 'non-bool flag => HOLD flag-invalid-lease_alive'
Assert-GRR ((-not [bool]$script:i18.confirmed) -and ([string]$script:i18.kernel -ceq 'not-attempted')) 'invalid flag consumes no event and attempts no kernel write'
Assert-GRR ((Get-GRRTaskState $script:r18 'f3-rec-badflag') -ceq 'BLOCKED') 'kernel stays BLOCKED on invalid flag'
Remove-Item -LiteralPath (Join-Path $script:r18.snaps 'f3-rec-badflag.flags.json') -Force
$script:o18b = Invoke-GitHubResumeReconcile -WaitsDir $script:r18.waits -SnapshotsDir $script:r18.snaps `
    -TasksDir $script:r18.tasks -FlagsPath $script:r18.flags -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300
$script:i18b = Get-GRRItem $script:o18b 'f3-rec-badflag'
Assert-GRR (([string]$script:i18b.decision -ceq 'HOLD') -and ([string]$script:i18b.reason -ceq 'flags-missing')) 'missing flags file => HOLD flags-missing'

# --- 19. S3 policy path: provided-but-invalid fails closed (never silent default).
$pol19a = Resolve-GRRPolicyFile -PolicyPath ''
Assert-GRR (([bool]$pol19a.ok) -and (-not [bool]$pol19a.provided)) 'omitted policy path resolves to default policy'
$pol19b = Resolve-GRRPolicyFile -PolicyPath (Join-Path $script:r18.root 'does-not-exist.json')
Assert-GRR ((-not [bool]$pol19b.ok) -and ([bool]$pol19b.provided) -and ([string]$pol19b.reason -ceq 'policy-invalid')) 'missing policy file => policy-invalid (never silent default)'
Assert-GRR ($script:text -cmatch 'policy-invalid') 'harness fails closed on provided-but-invalid policy'

# --- 20. S4 CAS conflict: stale OriginalBytes never silently overwrite.
$script:r20 = New-GRRRoot
$case20 = New-GRRCase -Root $script:r20 -Id 'f3-rec-cas' -Mode 'success'
$w20path = ''
foreach ($f in @(Get-ChildItem -LiteralPath $script:r20.waits -File -Filter 'ghwait-*.json')) { $w20path = $f.FullName }
$w20bytes = [IO.File]::ReadAllText($w20path, [Text.Encoding]::UTF8)
$w20doc = ConvertFrom-Json $w20bytes
$cf20 = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $script:r20.waits -DedupKey ([string]$case20.wait.dedup_key) -EventId 'evt-f3-rec-cas'
Assert-GRR ([bool]$cf20.ok) 'CAS setup: first Confirm applies'
$wr20 = Write-GHRSWaitDocument -Path $w20path -OriginalBytes $w20bytes -Document $w20doc
Assert-GRR ((-not [bool]$wr20.ok) -and ([string]$wr20.reason -ceq 'wait-modified')) 'stale revision write is refused (wait-modified, no silent loss)'

Write-Host ("[SUMMARY] passed={0} failed={1}" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
