# github-wake-controller.tests.ps1 -- Etapa 6D GH-WAKE controller handoff.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only (no live network, no
# gh required). Covers: dot-source exposure of the handoff surface,
# single-shot driver shape (no daemon/loop/sleep/spawn), extended
# next_action envelope (generation, task_id, checkpoint_id, goal_id,
# wait_dedup_key, lease_owner/lease_expires_utc, event_id, kernel_state,
# idempotency_key derived via hash, announce preserved), probe-positive
# as controller-responded (never dispatched; marker stays claimed),
# intent-ready prepare (valid intent + pending receipt, no execution),
# Planner settlement via Set-GHWakeDispatchSettlement (Claim+Settle with
# a real session id flips claimed to dispatched; replay is idempotent),
# binding-diverged refusal, missing checkpoint refusal, expired lease
# refusal, duplicate idempotency without replay, and
# IMPLEMENTING-without-handoff never counting as execution.
# Authority pins stay false everywhere (no merge/deploy/DONE/grants).
# ASCII only.
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')
$ErrorActionPreference = 'Stop'
$script:wakeCli = Join-Path $PSScriptRoot 'github-wake.ps1'
$script:ctrlCli = Join-Path $PSScriptRoot 'github-wake-controller.ps1'
if (-not (Test-Path -LiteralPath $script:wakeCli -PathType Leaf)) { throw 'RED: github-wake.ps1 not found (expected before GREEN)' }
if (-not (Test-Path -LiteralPath $script:ctrlCli -PathType Leaf)) { throw 'RED: github-wake-controller.ps1 not found (expected before GREEN)' }
. $script:wakeCli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-CTField {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}
# --- dot-source safety: handoff surface exposed, nothing executed on load.
Assert-That ($null -ne (Get-Command Invoke-GHWakeControllerHandoff -ErrorAction SilentlyContinue)) 'dot-source exposes Invoke-GHWakeControllerHandoff'
Assert-That ($null -ne (Get-Command Get-GHWakeIdempotencyKey -ErrorAction SilentlyContinue)) 'dot-source exposes Get-GHWakeIdempotencyKey'
Assert-That ($null -ne (Get-Command New-GHWakeNextAction -ErrorAction SilentlyContinue)) 'dot-source exposes New-GHWakeNextAction'
Assert-That ($null -ne (Get-Command Invoke-GitHubWake -ErrorAction SilentlyContinue)) 'dot-source still exposes Invoke-GitHubWake core'
# --- driver single-shot shape (no daemon/loop-unbounded/spawn/merge/deploy).
$ctrlText = [IO.File]::ReadAllText($script:ctrlCli, [Text.Encoding]::UTF8)
foreach ($bad in @('while\s*\(', 'Start-Job', 'System\.Timers', 'Register-ObjectEvent', 'FileSystemWatcher', 'Register-ScheduledTask', 'Start-Service', 'New-Service', 'Start-Process', 'Start-Sleep', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', 'gh pr merge', 'gh pr create', '--method POST', '--method PUT', '--method PATCH', '--method DELETE', 'GH_TOKEN', 'GITHUB_TOKEN', 'C:\\Users')) {
    Assert-That ($ctrlText -cnotmatch $bad) ('controller driver has no daemon/spawn/mutation pattern: ' + $bad)
}
foreach ($need in @('github-wake\.ps1', 'Invoke-GHWakeControllerHandoff', 'Get-OrchestrationGoalNextMove', 'IMPLEMENTING', 'awaits-planner-dispatch', 'duplicate-noop')) {
    Assert-That ($ctrlText -cmatch $need) ('controller driver pins required surface: ' + $need)
}
$wakeText = [IO.File]::ReadAllText($script:wakeCli, [Text.Encoding]::UTF8)
foreach ($pin in @('function Invoke-GHWakeControllerHandoff', 'function Get-GHWakeIdempotencyKey', 'function New-GHWakeNextAction', 'New-GHWakeNextAction -Wait')) {
    Assert-That ($wakeText -cmatch [regex]::Escape($pin)) ('wake pins handoff surface: ' + $pin)
}
Assert-That ($wakeText -cmatch 'IMPLEMENTING alone is never execution') 'wake documents IMPLEMENTING-is-not-execution'
# --- child engine (same family as parent).
$script:childExe = ''
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
    $found = $null
    try { $found = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $found = $null }
    if (($null -ne $found) -and (-not [string]::IsNullOrWhiteSpace([string]$found.Source))) { $script:childExe = [string]$found.Source }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) {
    $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $script:childExe = $psExe
}
if ([string]::IsNullOrWhiteSpace($script:childExe)) { throw 'FAIL: engine unavailable (neither pwsh nor powershell resolved)' }
$script:passed++
Write-Output ('engine: ' + $script:childExe)
# --- shared temp env builder (goal+checkpoint+tasks+waits via canonical libs).
$script:libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $script:libDir 'OrchestrationGoalKernel.ps1')
. (Join-Path $script:libDir 'OrchestrationTaskKernel.ps1')
. (Join-Path $script:libDir 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $script:libDir 'OrchestrationGitHubResume.ps1')
$script:policy = $null
try { $script:policy = Get-OrchestrationDeliveryPolicy $null } catch { $script:policy = $null }
if ($null -eq $script:policy) { throw 'FAIL: delivery policy unavailable' }
$script:reqChecks = @()
try { $script:reqChecks = @(Get-OrchestrationDeliveryRequiredChecks $script:policy) } catch { $script:reqChecks = @() }
Assert-That (@($script:reqChecks).Count -gt 0) 'policy carries required checks'
$script:SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2026-10-11T00:00:00Z'
$script:REPO = 'acme/widgets'
function New-CTEnv {
    param([string]$Tag = 'c')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwc-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-CTGoal {
    param($Env, [string]$GoalId = 'ghwc-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d controller' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-CTField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-CTField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-CTField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-CTField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-CTField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-CTField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-CTField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-ghwc' -ReadScopes @('src/ghwc.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-CTField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-CTField (Get-CTField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-CTField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-CTBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-CTField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-CTField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-CTField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-CTField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-CTField $tr 'error' '')) }
}
function New-CTWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'ghwc-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-ghwc' -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/ghwc' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-CTField $reg 'ok' $false)) { throw ('wait:' + [string](Get-CTField $reg 'reason' '')) }
}
function New-CTCkpt {
    param($Env, [string]$GoalId = 'ghwc-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-CTField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-CTField $sv 'checkpoint_id' '')
}
function New-CTNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-CTRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-CTFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-CTGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-CTNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Get-CTWaitFile {
    param($Env)
    $found = @(Get-ChildItem -LiteralPath $Env.waitsDir -File -Filter 'ghwait-*.json')
    if (@($found).Count -eq 0) { throw 'wait-missing' }
    return @($found)[0].FullName
}
function Set-CTWaitField {
    param($Env, [string]$Name = '', $Value = $null)
    $wf = Get-CTWaitFile -Env $Env
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($wf, [Text.Encoding]::UTF8))
    $doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    [IO.File]::WriteAllText($wf, (ConvertTo-Json -InputObject $doc -Depth 20), (New-Object Text.UTF8Encoding $false))
}
function Invoke-CTWake {
    param($Env, [string]$Fixture = '', [string]$Evt = 'evt-ghwc-1')
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:policy -GraphQLSnapshotFile $Fixture -EventId $Evt -MaxAgeSeconds 300 -NowUtc $script:NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
}
# --- unit: idempotency key is a 32-hex hash of dedup_key + event_id.
$k1 = Get-GHWakeIdempotencyKey -DedupKey 'd1' -EventId 'evt-1'
$k2 = Get-GHWakeIdempotencyKey -DedupKey 'd1' -EventId 'evt-1'
$k3 = Get-GHWakeIdempotencyKey -DedupKey 'd1' -EventId 'evt-2'
Assert-That (($k1 -cmatch '^[a-f0-9]{32}$') -and ($k1 -ceq $k2) -and ($k1 -cne $k3)) 'idempotency key deterministic 32-hex, event-sensitive'
Assert-That ([string](Get-GHWakeIdempotencyKey -DedupKey '' -EventId 'evt-1') -ceq '') 'idempotency key empty on missing dedup'
Assert-That ([string](Get-GHWakeIdempotencyKey -DedupKey 'd1' -EventId '') -ceq '') 'idempotency key empty on missing event'
# --- green wake produces the extended next_action envelope.
$e = New-CTEnv -Tag 'ext'
[void](New-CTGoal -Env $e -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-a'))
Set-CTBlocked -Env $e -TaskId 'ghwc-task-a' -Sha $script:SHA_A
New-CTWait -Env $e -TaskId 'ghwc-task-a' -Sha $script:SHA_A
[void](New-CTCkpt -Env $e -GoalId 'ghwc-goal-1')
$fx = Write-CTFixture -Env $e -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$w = Invoke-CTWake -Env $e -Fixture $fx -Evt 'evt-ghwc-1'
$items = @(Get-CTField $w 'items' @())
Assert-That (([string](Get-CTField @($items)[0] 'decision' '') -ceq 'RESUME')) 'setup wake: green RESUME'
$nx = Get-CTField $w 'next_action' $null
Assert-That ($null -ne $nx) 'extended envelope: next_action present'
Assert-That (([string](Get-CTField $nx 'task_id' '') -ceq 'ghwc-task-a')) 'extended envelope: task_id'
Assert-That (([string](Get-CTField $nx 'checkpoint_id' '') -cmatch '^[a-f0-9]{16}$')) 'extended envelope: checkpoint_id 16-hex'
Assert-That (([string](Get-CTField $nx 'goal_id' '') -ceq 'ghwc-goal-1')) 'extended envelope: goal_id'
Assert-That (-not [string]::IsNullOrWhiteSpace([string](Get-CTField $nx 'wait_dedup_key' ''))) 'extended envelope: wait_dedup_key'
Assert-That ([long](Get-CTField $nx 'generation' -1) -eq 1) 'extended envelope: generation from wait'
Assert-That (([string](Get-CTField $nx 'lease_owner' '') -ceq 'planner-1')) 'extended envelope: lease_owner from wait'
Assert-That (-not [string]::IsNullOrWhiteSpace([string](Get-CTField $nx 'lease_expires_utc' ''))) 'extended envelope: lease_expires_utc from wait'
Assert-That (([string](Get-CTField $nx 'event_id' '') -ceq 'evt-ghwc-1')) 'extended envelope: event_id'
Assert-That (([string](Get-CTField $nx 'kernel_state' '') -ceq 'IMPLEMENTING')) 'extended envelope: kernel_state IMPLEMENTING'
$expIdem = Get-GHWakeIdempotencyKey -DedupKey ([string](Get-CTField $nx 'wait_dedup_key' '')) -EventId 'evt-ghwc-1'
Assert-That ((([string](Get-CTField $nx 'idempotency_key' '')) -cmatch '^[a-f0-9]{32}$') -and (([string](Get-CTField $nx 'idempotency_key' '')) -ceq $expIdem)) 'extended envelope: idempotency_key derived hash, no collision surface'
Assert-That (([string](Get-CTField $nx 'announce' '')) -cmatch 'next-action task=ghwc-task-a checkpoint=') 'extended envelope: announce preserved for existing consumers'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).state -ceq 'IMPLEMENTING') 'setup wake: task unblocked to IMPLEMENTING'
# --- valid handoff: probe-positive is controller-responded, NEVER dispatched.
# --- intent+prepare are attached; marker stays claimed until Planner settle.
$script:probeCalls = 0
$probe = { param($na) $script:probeCalls++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$revBefore = [long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision
$h = Invoke-GHWakeControllerHandoff -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -ObjectiveStepProbe $probe
Assert-That ((-not [bool](Get-CTField $h 'dispatched' $true)) -and ([string](Get-CTField $h 'decision' '') -ceq 'controller-responded')) 'probe-positive: controller-responded, never dispatched'
Assert-That (([string](Get-CTField $h 'reason' '') -ceq 'mock-dispatched') -and (-not [bool](Get-CTField $h 'executed' $true))) 'probe-positive: probe reason surfaced, executed false'
Assert-That ([int]$script:probeCalls -eq 1) 'probe-positive: controller invoked exactly once'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision -eq $revBefore) 'probe-positive: kernel untouched (no replay of transition)'
Assert-That ((-not [bool](Get-CTField $h 'grants_authority' $true)) -and (-not [bool](Get-CTField $h 'done_approved' $true)) -and (-not [bool](Get-CTField $h 'merge_authority' $true))) 'probe-positive: authority pins stay false'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).state -cne 'DONE') 'probe-positive: task never auto-completed'
$hIntent = Get-CTField $h 'dispatch_intent' $null
$hPrep = Get-CTField $h 'prepare' $null
Assert-That (($null -ne $hIntent) -and ($null -ne $hPrep)) 'probe-positive: intent+prepare attached'
Assert-That (([bool](Get-CTField $hPrep 'admitted' $false)) -and ([string](Get-CTField $hPrep 'phase' '') -ceq 'prepared')) 'probe-positive: receipt pending prepared (not executed)'
Assert-That (([string](Get-CTField $hIntent 'agent' '') -ceq 'coder') -and ([string](Get-CTField $hIntent 'idempotency_key' '') -ceq [string](Get-CTField $nx 'idempotency_key' ''))) 'probe-positive: intent carries documented coder default + handoff key'
$hMarker = [string](Get-CTField $h 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hMarker)) -and (Test-Path -LiteralPath $hMarker -PathType Leaf)) 'probe-positive: claim marker persisted'
$hMarkDoc = ConvertFrom-Json ([IO.File]::ReadAllText($hMarker, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $hMarkDoc 'status' '') -ceq 'claimed') 'probe-positive: marker stays claimed (settle flips it later)'
# --- duplicate re-invocation: DUPLICATE_NOOP, no replay, probe untouched.
$h2 = Invoke-GHWakeControllerHandoff -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -ObjectiveStepProbe $probe
Assert-That ((-not [bool](Get-CTField $h2 'dispatched' $true)) -and ([string](Get-CTField $h2 'reason' '') -ceq 'duplicate-noop')) 'duplicate handoff: DUPLICATE_NOOP without replay'
Assert-That ([int]$script:probeCalls -eq 1) 'duplicate handoff: controller not re-invoked'
Assert-That (-not [bool](Get-CTField $h2 'executed' $true)) 'duplicate handoff: executed false'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision -eq $revBefore) 'duplicate handoff: kernel still untouched'
Assert-That ($null -eq (Get-CTField $h2 'prepare' $null)) 'duplicate handoff: no second intent prepared'
# --- settlement: no session id is refused; marker stays claimed.
$sNoSess = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId '' -ResultOk $true -ResultSummary 'x' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath
Assert-That ((-not [bool](Get-CTField $sNoSess 'dispatched' $true)) -and ([string](Get-CTField $sNoSess 'reason' '') -ceq 'settle-session-invalid')) 'settle without session: refused settle-session-invalid'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'settle without session: marker stays claimed'
# --- settlement: Planner-attested session completes the loop (Claim+Settle).
$sOk = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId 'sess-child-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-a'
Assert-That (([bool](Get-CTField $sOk 'ok' $false)) -and ([bool](Get-CTField $sOk 'dispatched' $false)) -and ([bool](Get-CTField $sOk 'settled' $false))) 'settle with session: ok dispatched settled'
Assert-That ([string](Get-CTField $sOk 'reason' '') -ceq 'planner-settled') 'settle with session: typed planner-settled reason'
Assert-That ([bool](Get-CTField $sOk 'executed' $false)) 'settle with session: executed true only here'
$sMarkDoc = ConvertFrom-Json ([IO.File]::ReadAllText($hMarker, [Text.Encoding]::UTF8))
Assert-That ((([string](Get-CTField $sMarkDoc 'status' '') -ceq 'dispatched') -and ([string](Get-CTField $sMarkDoc 'session_id' '') -ceq 'sess-child-1'))) 'settle with session: marker dispatched with real session id'
# --- settlement replay: same session is idempotent duplicate, no second intent.
$sDup = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId 'sess-child-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-a'
Assert-That (([bool](Get-CTField $sDup 'dispatched' $false)) -and ([bool](Get-CTField $sDup 'duplicate' $false)) -and ([string](Get-CTField $sDup 'reason' '') -ceq 'settle-duplicate')) 'settle replay: settle-duplicate, no second intent'
$sOther = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId 'sess-child-2' -ResultOk $true -ResultSummary 'other' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-a'
Assert-That ((-not [bool](Get-CTField $sOther 'dispatched' $true)) -and ([string](Get-CTField $sOther 'reason' '') -ceq 'settle-session-mismatch')) 'settle replay: divergent session refused'
# --- HIGH-6D-DISP-F: recovery (receipt settled, marker back to claimed) with a
# --- divergent session is refused fail-closed; marker stays claimed.
$recDoc = ConvertFrom-Json ([IO.File]::ReadAllText($hMarker, [Text.Encoding]::UTF8))
$recDoc.status = 'claimed'
[IO.File]::WriteAllText($hMarker, (ConvertTo-Json -InputObject $recDoc -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$sRecOther = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId 'sess-child-2' -ResultOk $true -ResultSummary 'other session recovery' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-a'
Assert-That ((-not [bool](Get-CTField $sRecOther 'dispatched' $true)) -and ([string](Get-CTField $sRecOther 'reason' '') -ceq 'settle-session-mismatch')) 'settle recovery: divergent session refused settle-session-mismatch'
Assert-That (-not [bool](Get-CTField $sRecOther 'executed' $true)) 'settle recovery: divergent session never executed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'settle recovery: divergent session leaves marker claimed'
$sRecSame = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId 'sess-child-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e.receiptDir -GoalStoreDir $e.goalDir -TasksDir $e.tasksDir -FlagsPath $e.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-a'
Assert-That (([bool](Get-CTField $sRecSame 'dispatched' $false)) -and ([string](Get-CTField $sRecSame 'reason' '') -ceq 'settle-duplicate')) 'settle recovery: same session completes marker flip as settle-duplicate'
# --- HIGH-6D-DISP-F34: marker dispatched alone never confirms dispatch.
# --- Receipt is conferring: absent receipt or divergent settle child fails
# --- closed; only receipt+marker agreeing with sid confirms duplicate.
$ef = New-CTEnv -Tag 'dupf'
[void](New-CTGoal -Env $ef -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-f'))
Set-CTBlocked -Env $ef -TaskId 'ghwc-task-f' -Sha $script:SHA_A
New-CTWait -Env $ef -TaskId 'ghwc-task-f' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ef -GoalId 'ghwc-goal-1')
$fxf = Write-CTFixture -Env $ef -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wf = Invoke-CTWake -Env $ef -Fixture $fxf -Evt 'evt-ghwc-dupf'
$nxp = Get-CTField $wf 'next_action' $null
Assert-That ($null -ne $nxp) 'dupfix setup: next_action present'
$script:probeCallsF = 0
$probeF = { param($na) $script:probeCallsF++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hf = Invoke-GHWakeControllerHandoff -NextAction $nxp -WaitsDir $ef.waitsDir -TasksDir $ef.tasksDir -GoalStoreDir $ef.goalDir -CheckpointDir $ef.ckptDir -FlagsPath $ef.flagsPath -NowUtc $script:NOW -HandoffStateDir $ef.ckptDir -ReceiptDir $ef.receiptDir -ObjectiveStepProbe $probeF
$hfMarker = [string](Get-CTField $hf 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hfMarker)) -and (Test-Path -LiteralPath $hfMarker -PathType Leaf)) 'dupfix setup: marker claimed'
$sfOk = Set-GHWakeDispatchSettlement -MarkerPath $hfMarker -SessionId 'sess-fix-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $ef.receiptDir -GoalStoreDir $ef.goalDir -TasksDir $ef.tasksDir -FlagsPath $ef.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f'
Assert-That ([string](Get-CTField $sfOk 'reason' '') -ceq 'planner-settled') 'dupfix setup: first settle planner-settled, receipt settled'
$sfDup = Set-GHWakeDispatchSettlement -MarkerPath $hfMarker -SessionId 'sess-fix-1' -ResultOk $true -ResultSummary 'concordant replay' -ReceiptDir $ef.receiptDir -GoalStoreDir $ef.goalDir -TasksDir $ef.tasksDir -FlagsPath $ef.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f'
Assert-That (([bool](Get-CTField $sfDup 'dispatched' $false)) -and ([bool](Get-CTField $sfDup 'duplicate' $false)) -and ([string](Get-CTField $sfDup 'reason' '') -ceq 'settle-duplicate')) 'dupfix concordant: receipt+marker agree with sid is settle-duplicate'
$emptyRcpt = Join-Path $ef.root 'empty-receipts'
[void][IO.Directory]::CreateDirectory($emptyRcpt)
$sfNoRcpt = Set-GHWakeDispatchSettlement -MarkerPath $hfMarker -SessionId 'sess-fix-1' -ResultOk $true -ResultSummary 'marker only, no receipt' -ReceiptDir $emptyRcpt -GoalStoreDir $ef.goalDir -TasksDir $ef.tasksDir -FlagsPath $ef.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f'
Assert-That ((-not [bool](Get-CTField $sfNoRcpt 'dispatched' $true)) -and (-not [bool](Get-CTField $sfNoRcpt 'executed' $true)) -and ([string](Get-CTField $sfNoRcpt 'reason' '') -ceq 'settle-not-prepared')) 'dupfix absent receipt: marker dispatched without receipt is fail-closed settle-not-prepared'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hfMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'dispatched') 'dupfix absent receipt: marker stays dispatched, never flipped'
$tamF = ConvertFrom-Json ([IO.File]::ReadAllText($hfMarker, [Text.Encoding]::UTF8))
$tamF.session_id = 'sess-fix-9'
[IO.File]::WriteAllText($hfMarker, (ConvertTo-Json -InputObject $tamF -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$sfDiv = Set-GHWakeDispatchSettlement -MarkerPath $hfMarker -SessionId 'sess-fix-9' -ResultOk $true -ResultSummary 'marker A receipt B' -ReceiptDir $ef.receiptDir -GoalStoreDir $ef.goalDir -TasksDir $ef.tasksDir -FlagsPath $ef.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f'
Assert-That ((-not [bool](Get-CTField $sfDiv 'dispatched' $true)) -and (-not [bool](Get-CTField $sfDiv 'executed' $true)) -and ([string](Get-CTField $sfDiv 'reason' '') -ceq 'settle-session-mismatch')) 'dupfix divergent: marker A with receipt settled by B is fail-closed settle-session-mismatch'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hfMarker, [Text.Encoding]::UTF8))) 'session_id' '') -ceq 'sess-fix-9') 'dupfix divergent: marker untouched on refusal'
# --- MEDIUM-6D-DISP-F8: entry-dispatched with divergent ddk is fail-closed
# --- settle-identity-diverged (recomputed ddk:evt key breaks); marker never
# --- overwritten, dispatched=false, executed=false.
$ef8 = New-CTEnv -Tag 'ddkev'
[void](New-CTGoal -Env $ef8 -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-e8'))
Set-CTBlocked -Env $ef8 -TaskId 'ghwc-task-e8' -Sha $script:SHA_A
New-CTWait -Env $ef8 -TaskId 'ghwc-task-e8' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ef8 -GoalId 'ghwc-goal-1')
$fx8 = Write-CTFixture -Env $ef8 -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$w8 = Invoke-CTWake -Env $ef8 -Fixture $fx8 -Evt 'evt-ghwc-ddkev'
$nx8 = Get-CTField $w8 'next_action' $null
Assert-That ($null -ne $nx8) 'ddkev setup: next_action present'
$script:probeCalls8 = 0
$probe8 = { param($na) $script:probeCalls8++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$h8 = Invoke-GHWakeControllerHandoff -NextAction $nx8 -WaitsDir $ef8.waitsDir -TasksDir $ef8.tasksDir -GoalStoreDir $ef8.goalDir -CheckpointDir $ef8.ckptDir -FlagsPath $ef8.flagsPath -NowUtc $script:NOW -HandoffStateDir $ef8.ckptDir -ReceiptDir $ef8.receiptDir -ObjectiveStepProbe $probe8
$h8Marker = [string](Get-CTField $h8 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($h8Marker)) -and (Test-Path -LiteralPath $h8Marker -PathType Leaf)) 'ddkev setup: marker claimed'
$s8Ok = Set-GHWakeDispatchSettlement -MarkerPath $h8Marker -SessionId 'sess-e8-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $ef8.receiptDir -GoalStoreDir $ef8.goalDir -TasksDir $ef8.tasksDir -FlagsPath $ef8.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-e8'
Assert-That ([string](Get-CTField $s8Ok 'reason' '') -ceq 'planner-settled') 'ddkev setup: first settle planner-settled, receipt settled'
$orig8Doc = ConvertFrom-Json ([IO.File]::ReadAllText($h8Marker, [Text.Encoding]::UTF8))
$orig8Ddk = ([string](Get-CTField $orig8Doc 'wait_dedup_key' ''))
$orig8Evt = ([string](Get-CTField $orig8Doc 'event_id' ''))
$tam8 = ConvertFrom-Json ([IO.File]::ReadAllText($h8Marker, [Text.Encoding]::UTF8))
$tam8.wait_dedup_key = 'ddk-tampered-8'
[IO.File]::WriteAllText($h8Marker, (ConvertTo-Json -InputObject $tam8 -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s8Ddk = Set-GHWakeDispatchSettlement -MarkerPath $h8Marker -SessionId 'sess-e8-1' -ResultOk $true -ResultSummary 'entry replay divergent ddk' -ReceiptDir $ef8.receiptDir -GoalStoreDir $ef8.goalDir -TasksDir $ef8.tasksDir -FlagsPath $ef8.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-e8'
Assert-That ((-not [bool](Get-CTField $s8Ddk 'dispatched' $true)) -and (-not [bool](Get-CTField $s8Ddk 'executed' $true)) -and ([string](Get-CTField $s8Ddk 'reason' '') -ceq 'settle-identity-diverged')) 'ddkev divergent ddk: fail-closed settle-identity-diverged'
$after8Ddk = ConvertFrom-Json ([IO.File]::ReadAllText($h8Marker, [Text.Encoding]::UTF8))
Assert-That ((([string](Get-CTField $after8Ddk 'status' '') -ceq 'dispatched') -and ([string](Get-CTField $after8Ddk 'session_id' '') -ceq 'sess-e8-1') -and ([string](Get-CTField $after8Ddk 'wait_dedup_key' '') -ceq 'ddk-tampered-8'))) 'ddkev divergent ddk: marker untouched on refusal'
# --- MEDIUM-6D-DISP-F8: entry-dispatched with divergent event_id is fail-closed
# --- settle-identity-diverged; marker never overwritten.
$rst8 = ConvertFrom-Json ([IO.File]::ReadAllText($h8Marker, [Text.Encoding]::UTF8))
$rst8.wait_dedup_key = $orig8Ddk
$rst8.event_id = 'evt-tampered-8'
[IO.File]::WriteAllText($h8Marker, (ConvertTo-Json -InputObject $rst8 -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s8Evt = Set-GHWakeDispatchSettlement -MarkerPath $h8Marker -SessionId 'sess-e8-1' -ResultOk $true -ResultSummary 'entry replay divergent evt' -ReceiptDir $ef8.receiptDir -GoalStoreDir $ef8.goalDir -TasksDir $ef8.tasksDir -FlagsPath $ef8.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-e8'
Assert-That ((-not [bool](Get-CTField $s8Evt 'dispatched' $true)) -and (-not [bool](Get-CTField $s8Evt 'executed' $true)) -and ([string](Get-CTField $s8Evt 'reason' '') -ceq 'settle-identity-diverged')) 'ddkev divergent evt: fail-closed settle-identity-diverged'
$after8Evt = ConvertFrom-Json ([IO.File]::ReadAllText($h8Marker, [Text.Encoding]::UTF8))
Assert-That ((([string](Get-CTField $after8Evt 'status' '') -ceq 'dispatched') -and ([string](Get-CTField $after8Evt 'session_id' '') -ceq 'sess-e8-1') -and ([string](Get-CTField $after8Evt 'event_id' '') -ceq 'evt-tampered-8') -and ([string](Get-CTField $after8Evt 'wait_dedup_key' '') -ceq $orig8Ddk))) 'ddkev divergent evt: marker untouched on refusal'
# --- HIGH-6D-DISP-F4: receipt settled + marker re-read as dispatched by a
# --- divergent session (concurrent flip between entry read and re-read) is
# --- fail-closed settle-session-mismatch; marker stays claimed.
$er = New-CTEnv -Tag 'race'
[void](New-CTGoal -Env $er -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-r'))
Set-CTBlocked -Env $er -TaskId 'ghwc-task-r' -Sha $script:SHA_A
New-CTWait -Env $er -TaskId 'ghwc-task-r' -Sha $script:SHA_A
[void](New-CTCkpt -Env $er -GoalId 'ghwc-goal-1')
$fxr = Write-CTFixture -Env $er -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wr = Invoke-CTWake -Env $er -Fixture $fxr -Evt 'evt-ghwc-race'
$nxr = Get-CTField $wr 'next_action' $null
Assert-That ($null -ne $nxr) 'race setup: next_action present'
$script:probeCallsR = 0
$probeR = { param($na) $script:probeCallsR++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hr = Invoke-GHWakeControllerHandoff -NextAction $nxr -WaitsDir $er.waitsDir -TasksDir $er.tasksDir -GoalStoreDir $er.goalDir -CheckpointDir $er.ckptDir -FlagsPath $er.flagsPath -NowUtc $script:NOW -HandoffStateDir $er.ckptDir -ReceiptDir $er.receiptDir -ObjectiveStepProbe $probeR
$hrMarker = [string](Get-CTField $hr 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hrMarker)) -and (Test-Path -LiteralPath $hrMarker -PathType Leaf)) 'race setup: marker claimed'
$srOk = Set-GHWakeDispatchSettlement -MarkerPath $hrMarker -SessionId 'sess-race-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $er.receiptDir -GoalStoreDir $er.goalDir -TasksDir $er.tasksDir -FlagsPath $er.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-r'
Assert-That ([string](Get-CTField $srOk 'reason' '') -ceq 'planner-settled') 'race setup: first settle planner-settled, receipt settled'
$recRace = ConvertFrom-Json ([IO.File]::ReadAllText($hrMarker, [Text.Encoding]::UTF8))
$recRace.status = 'claimed'
[IO.File]::WriteAllText($hrMarker, (ConvertTo-Json -InputObject $recRace -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$script:ghwRdCount = 0
$script:ghwRdOrig = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCount++
    $d = (& $script:ghwRdOrig -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCount -ge 2) {
        try { $d.status = 'dispatched'; $d.session_id = 'sess-race-9' } catch { }
    }
    return $d
}
$srRace = Set-GHWakeDispatchSettlement -MarkerPath $hrMarker -SessionId 'sess-race-1' -ResultOk $true -ResultSummary 'concurrent flip by divergent session' -ReceiptDir $er.receiptDir -GoalStoreDir $er.goalDir -TasksDir $er.tasksDir -FlagsPath $er.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-r'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrig
Assert-That ((-not [bool](Get-CTField $srRace 'dispatched' $true)) -and ([string](Get-CTField $srRace 'reason' '') -ceq 'settle-session-mismatch')) 'race: divergent re-read refused settle-session-mismatch'
Assert-That (-not [bool](Get-CTField $srRace 'executed' $true)) 'race: divergent re-read never executed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hrMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'race: divergent re-read leaves marker claimed'
# --- MEDIUM-6D-DISP-F6: concurrent identity tamper between entry read and
# --- post-settle re-read (divergent task_id) is fail-closed
# --- settle-identity-diverged; marker never overwritten, dispatched=false.
$ei = New-CTEnv -Tag 'ident'
[void](New-CTGoal -Env $ei -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-i'))
Set-CTBlocked -Env $ei -TaskId 'ghwc-task-i' -Sha $script:SHA_A
New-CTWait -Env $ei -TaskId 'ghwc-task-i' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ei -GoalId 'ghwc-goal-1')
$fxi = Write-CTFixture -Env $ei -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wi = Invoke-CTWake -Env $ei -Fixture $fxi -Evt 'evt-ghwc-ident'
$nxi = Get-CTField $wi 'next_action' $null
Assert-That ($null -ne $nxi) 'ident setup: next_action present'
$script:probeCallsI = 0
$probeI = { param($na) $script:probeCallsI++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hi = Invoke-GHWakeControllerHandoff -NextAction $nxi -WaitsDir $ei.waitsDir -TasksDir $ei.tasksDir -GoalStoreDir $ei.goalDir -CheckpointDir $ei.ckptDir -FlagsPath $ei.flagsPath -NowUtc $script:NOW -HandoffStateDir $ei.ckptDir -ReceiptDir $ei.receiptDir -ObjectiveStepProbe $probeI
$hiMarker = [string](Get-CTField $hi 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hiMarker)) -and (Test-Path -LiteralPath $hiMarker -PathType Leaf)) 'ident setup: marker claimed'
$hiOrig = ConvertFrom-Json ([IO.File]::ReadAllText($hiMarker, [Text.Encoding]::UTF8))
$hiOrigTask = ([string](Get-CTField $hiOrig 'task_id' ''))
$hiOrigIdem = ([string](Get-CTField $hiOrig 'idempotency_key' ''))
$script:ghwRdCountI = 0
$script:ghwRdOrigI = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountI++
    $d = (& $script:ghwRdOrigI -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountI -ge 2) {
        try { $d.task_id = 'ghwc-task-tampered' } catch { }
    }
    return $d
}
$siDiv = Set-GHWakeDispatchSettlement -MarkerPath $hiMarker -SessionId 'sess-ident-1' -ResultOk $true -ResultSummary 'concurrent task tamper' -ReceiptDir $ei.receiptDir -GoalStoreDir $ei.goalDir -TasksDir $ei.tasksDir -FlagsPath $ei.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-i'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigI
Assert-That ((-not [bool](Get-CTField $siDiv 'dispatched' $true)) -and ([string](Get-CTField $siDiv 'reason' '') -ceq 'settle-identity-diverged')) 'ident: tampered task_id refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $siDiv 'executed' $true)) 'ident: tampered task_id never executed'
$hiAfter = ConvertFrom-Json ([IO.File]::ReadAllText($hiMarker, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $hiAfter 'status' '') -ceq 'claimed') 'ident: tampered re-read leaves marker claimed on disk'
Assert-That (([string](Get-CTField $hiAfter 'task_id' '') -ceq $hiOrigTask) -and ([string](Get-CTField $hiAfter 'idempotency_key' '') -ceq $hiOrigIdem)) 'ident: marker identity fields not overwritten'
# --- MEDIUM-6D-DISP-F: mechanism response without child_session_id is fail-closed.
$em = New-CTEnv -Tag 'miss'
[void](New-CTGoal -Env $em -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-m'))
Set-CTBlocked -Env $em -TaskId 'ghwc-task-m' -Sha $script:SHA_A
New-CTWait -Env $em -TaskId 'ghwc-task-m' -Sha $script:SHA_A
[void](New-CTCkpt -Env $em -GoalId 'ghwc-goal-1')
$fxm = Write-CTFixture -Env $em -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wm = Invoke-CTWake -Env $em -Fixture $fxm -Evt 'evt-ghwc-miss'
$nxm = Get-CTField $wm 'next_action' $null
Assert-That ($null -ne $nxm) 'missing child setup: next_action present'
$script:probeCallsM = 0
$probeM = { param($na) $script:probeCallsM++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hm = Invoke-GHWakeControllerHandoff -NextAction $nxm -WaitsDir $em.waitsDir -TasksDir $em.tasksDir -GoalStoreDir $em.goalDir -CheckpointDir $em.ckptDir -FlagsPath $em.flagsPath -NowUtc $script:NOW -HandoffStateDir $em.ckptDir -ReceiptDir $em.receiptDir -ObjectiveStepProbe $probeM
$hmMarker = [string](Get-CTField $hm 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hmMarker)) -and (Test-Path -LiteralPath $hmMarker -PathType Leaf)) 'missing child setup: marker claimed'
$script:origSettleSb = (Get-Command Invoke-OrchestrationNativeDispatchSettle).ScriptBlock
function Invoke-OrchestrationNativeDispatchSettle {
    param([string]$IdempotencyKey = '', $Authorization = $null, [string]$ChildSessionId = '', [string]$SessionId = '', [string]$MessageId = '', [string]$CallId = '', [string]$CallerAgent = '', [string]$TargetAgent = '', [string]$PreparedFingerprint = '', [string]$Reference = '', [string]$TaskId = '', $Result = $null, [string]$ReceiptDir = '', [string]$RepoRoot = '', [string]$GoalStoreDir = '', [string]$EvidenceStoreDir = '', [string]$TasksDir = '', [string]$FlagsPath = '', [int]$LockTimeoutMs = 60000, $ProvenanceProof = $null, [switch]$StrictProvenance, [switch]$EmitAdmission)
    return [pscustomobject]@{ ok = $true; settled = $true; duplicate = $false; reason = '' }
}
$sMiss = Set-GHWakeDispatchSettlement -MarkerPath $hmMarker -SessionId 'sess-miss-1' -ResultOk $true -ResultSummary 'mechanism omits child' -ReceiptDir $em.receiptDir -GoalStoreDir $em.goalDir -TasksDir $em.tasksDir -FlagsPath $em.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-m'
${function:Invoke-OrchestrationNativeDispatchSettle} = $script:origSettleSb
Assert-That ((-not [bool](Get-CTField $sMiss 'dispatched' $true)) -and ([string](Get-CTField $sMiss 'reason' '') -ceq 'settle-session-mismatch')) 'missing child: refused settle-session-mismatch'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hmMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'missing child: marker stays claimed'
# --- MEDIUM-6D-DISP-F2: normal mechanism response with divergent child is refused.
$ed = New-CTEnv -Tag 'div'
[void](New-CTGoal -Env $ed -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-v'))
Set-CTBlocked -Env $ed -TaskId 'ghwc-task-v' -Sha $script:SHA_A
New-CTWait -Env $ed -TaskId 'ghwc-task-v' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ed -GoalId 'ghwc-goal-1')
$fxd = Write-CTFixture -Env $ed -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wd = Invoke-CTWake -Env $ed -Fixture $fxd -Evt 'evt-ghwc-div'
$nxd = Get-CTField $wd 'next_action' $null
Assert-That ($null -ne $nxd) 'divergent child setup: next_action present'
$script:probeCallsD = 0
$probeD = { param($na) $script:probeCallsD++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hd = Invoke-GHWakeControllerHandoff -NextAction $nxd -WaitsDir $ed.waitsDir -TasksDir $ed.tasksDir -GoalStoreDir $ed.goalDir -CheckpointDir $ed.ckptDir -FlagsPath $ed.flagsPath -NowUtc $script:NOW -HandoffStateDir $ed.ckptDir -ReceiptDir $ed.receiptDir -ObjectiveStepProbe $probeD
$hdMarker = [string](Get-CTField $hd 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hdMarker)) -and (Test-Path -LiteralPath $hdMarker -PathType Leaf)) 'divergent child setup: marker claimed'
$script:origSettleSbD = (Get-Command Invoke-OrchestrationNativeDispatchSettle).ScriptBlock
function Invoke-OrchestrationNativeDispatchSettle {
    param([string]$IdempotencyKey = '', $Authorization = $null, [string]$ChildSessionId = '', [string]$SessionId = '', [string]$MessageId = '', [string]$CallId = '', [string]$CallerAgent = '', [string]$TargetAgent = '', [string]$PreparedFingerprint = '', [string]$Reference = '', [string]$TaskId = '', $Result = $null, [string]$ReceiptDir = '', [string]$RepoRoot = '', [string]$GoalStoreDir = '', [string]$EvidenceStoreDir = '', [string]$TasksDir = '', [string]$FlagsPath = '', [int]$LockTimeoutMs = 60000, $ProvenanceProof = $null, [switch]$StrictProvenance, [switch]$EmitAdmission)
    return [pscustomobject]@{ ok = $true; settled = $true; duplicate = $false; reason = ''; child_session_id = 'sess-divergent-9' }
}
$sDiv = Set-GHWakeDispatchSettlement -MarkerPath $hdMarker -SessionId 'sess-div-1' -ResultOk $true -ResultSummary 'mechanism diverges child' -ReceiptDir $ed.receiptDir -GoalStoreDir $ed.goalDir -TasksDir $ed.tasksDir -FlagsPath $ed.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-v'
${function:Invoke-OrchestrationNativeDispatchSettle} = $script:origSettleSbD
Assert-That ((-not [bool](Get-CTField $sDiv 'dispatched' $true)) -and ([string](Get-CTField $sDiv 'reason' '') -ceq 'settle-session-mismatch')) 'divergent child: refused settle-session-mismatch'
Assert-That (-not [bool](Get-CTField $sDiv 'executed' $true)) 'divergent child: never executed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hdMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'divergent child: marker stays claimed'
# --- binding diverged refuses before controller.
$eb = New-CTEnv -Tag 'bind'
[void](New-CTGoal -Env $eb -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-b'))
Set-CTBlocked -Env $eb -TaskId 'ghwc-task-b' -Sha $script:SHA_A
New-CTWait -Env $eb -TaskId 'ghwc-task-b' -Sha $script:SHA_A
[void](New-CTCkpt -Env $eb -GoalId 'ghwc-goal-1')
$fxb = Write-CTFixture -Env $eb -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wb = Invoke-CTWake -Env $eb -Fixture $fxb -Evt 'evt-ghwc-2'
$nxb = Get-CTField $wb 'next_action' $null
Assert-That ($null -ne $nxb) 'binding setup: next_action present'
Set-CTWaitField -Env $eb -Name 'lease_owner' -Value 'intruder-9'
$script:probeCallsB = 0
$probeB = { param($na) $script:probeCallsB++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hb = Invoke-GHWakeControllerHandoff -NextAction $nxb -WaitsDir $eb.waitsDir -TasksDir $eb.tasksDir -GoalStoreDir $eb.goalDir -CheckpointDir $eb.ckptDir -FlagsPath $eb.flagsPath -NowUtc $script:NOW -HandoffStateDir $eb.ckptDir -ReceiptDir $eb.receiptDir -ObjectiveStepProbe $probeB
Assert-That ((-not [bool](Get-CTField $hb 'dispatched' $true)) -and ([string](Get-CTField $hb 'reason' '') -ceq 'binding-diverged')) 'diverged binding: refused binding-diverged'
Assert-That ([int]$script:probeCallsB -eq 0) 'diverged binding: controller never invoked'
# --- checkpoint absent refuses fail-closed.
$ec = New-CTEnv -Tag 'ckpt'
[void](New-CTGoal -Env $ec -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-c'))
Set-CTBlocked -Env $ec -TaskId 'ghwc-task-c' -Sha $script:SHA_A
New-CTWait -Env $ec -TaskId 'ghwc-task-c' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ec -GoalId 'ghwc-goal-1')
$fxc = Write-CTFixture -Env $ec -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wc = Invoke-CTWake -Env $ec -Fixture $fxc -Evt 'evt-ghwc-3'
$nzc = Get-CTField $wc 'next_action' $null
Assert-That ($null -ne $nzc) 'checkpoint setup: next_action present'
$emptyCkpt = Join-Path $ec.root 'empty-ckpts'
[void][IO.Directory]::CreateDirectory($emptyCkpt)
$script:probeCallsC = 0
$probeC = { param($na) $script:probeCallsC++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hc = Invoke-GHWakeControllerHandoff -NextAction $nzc -WaitsDir $ec.waitsDir -TasksDir $ec.tasksDir -GoalStoreDir $ec.goalDir -CheckpointDir $emptyCkpt -FlagsPath $ec.flagsPath -NowUtc $script:NOW -HandoffStateDir $emptyCkpt -ObjectiveStepProbe $probeC
Assert-That ((-not [bool](Get-CTField $hc 'dispatched' $true)) -and ([string](Get-CTField $hc 'reason' '') -ceq 'checkpoint-missing')) 'absent checkpoint: refused checkpoint-missing'
Assert-That ([int]$script:probeCallsC -eq 0) 'absent checkpoint: controller never invoked'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghwc-task-c' -TasksDir $ec.tasksDir -RepoRoot $ec.root).state -ceq 'IMPLEMENTING') 'absent checkpoint: no kernel rollback attempted'
# --- expired lease refuses fail-closed.
$el = New-CTEnv -Tag 'lease'
[void](New-CTGoal -Env $el -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-d'))
Set-CTBlocked -Env $el -TaskId 'ghwc-task-d' -Sha $script:SHA_A
New-CTWait -Env $el -TaskId 'ghwc-task-d' -Sha $script:SHA_A
[void](New-CTCkpt -Env $el -GoalId 'ghwc-goal-1')
$fxl = Write-CTFixture -Env $el -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wl = Invoke-CTWake -Env $el -Fixture $fxl -Evt 'evt-ghwc-4'
$nxl = Get-CTField $wl 'next_action' $null
Assert-That ($null -ne $nxl) 'lease setup: next_action present'
Set-CTWaitField -Env $el -Name 'lease_expires_utc' -Value '2020-01-01T00:00:00Z'
$script:probeCallsL = 0
$probeL = { param($na) $script:probeCallsL++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hl = Invoke-GHWakeControllerHandoff -NextAction $nxl -WaitsDir $el.waitsDir -TasksDir $el.tasksDir -GoalStoreDir $el.goalDir -CheckpointDir $el.ckptDir -FlagsPath $el.flagsPath -NowUtc $script:NOW -HandoffStateDir $el.ckptDir -ReceiptDir $el.receiptDir -ObjectiveStepProbe $probeL
Assert-That ((-not [bool](Get-CTField $hl 'dispatched' $true)) -and ([string](Get-CTField $hl 'reason' '') -ceq 'lease-expired')) 'expired lease: refused lease-expired'
Assert-That ([int]$script:probeCallsL -eq 0) 'expired lease: controller never invoked'
# --- IMPLEMENTING without handoff is never execution.
$hn = Invoke-GHWakeControllerHandoff -NextAction $null -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir
Assert-That ((-not [bool](Get-CTField $hn 'dispatched' $true)) -and (-not [bool](Get-CTField $hn 'executed' $true)) -and ([string](Get-CTField $hn 'reason' '') -ceq 'no-next-action')) 'no handoff envelope: not-dispatched no-next-action'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).state -ceq 'IMPLEMENTING') 'IMPLEMENTING kernel state alone persists without execution claim'
# --- HIGH-1: tampered envelope task/goal refused before probe, no mutation.
$et = New-CTEnv -Tag 'tamper'
[void](New-CTGoal -Env $et -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-t'))
Set-CTBlocked -Env $et -TaskId 'ghwc-task-t' -Sha $script:SHA_A
New-CTWait -Env $et -TaskId 'ghwc-task-t' -Sha $script:SHA_A
[void](New-CTCkpt -Env $et -GoalId 'ghwc-goal-1')
$fxt = Write-CTFixture -Env $et -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wt = Invoke-CTWake -Env $et -Fixture $fxt -Evt 'evt-ghwc-tamper'
$nxt = Get-CTField $wt 'next_action' $null
Assert-That ($null -ne $nxt) 'tamper setup: next_action present'
$revT = [long](Get-OrchestrationTask -TaskId 'ghwc-task-t' -TasksDir $et.tasksDir -RepoRoot $et.root).revision
$script:probeCallsT = 0
$probeT = { param($na) $script:probeCallsT++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$nxBadTask = (ConvertFrom-Json (ConvertTo-Json -InputObject $nxt -Depth 20))
$nxBadTask.task_id = 'ghwc-task-evil'
$ht1 = Invoke-GHWakeControllerHandoff -NextAction $nxBadTask -WaitsDir $et.waitsDir -TasksDir $et.tasksDir -GoalStoreDir $et.goalDir -CheckpointDir $et.ckptDir -FlagsPath $et.flagsPath -NowUtc $script:NOW -HandoffStateDir $et.ckptDir -ReceiptDir $et.receiptDir -ObjectiveStepProbe $probeT
Assert-That ((-not [bool](Get-CTField $ht1 'dispatched' $true)) -and ([string](Get-CTField $ht1 'reason' '') -ceq 'handoff-task-mismatch')) 'tampered task: refused handoff-task-mismatch'
Assert-That ([int]$script:probeCallsT -eq 0) 'tampered task: controller never invoked'
Assert-That (-not [bool](Get-CTField $ht1 'executed' $true)) 'tampered task: executed false'
$nxBadGoal = (ConvertFrom-Json (ConvertTo-Json -InputObject $nxt -Depth 20))
$nxBadGoal.goal_id = 'ghwc-goal-evil'
$ht2 = Invoke-GHWakeControllerHandoff -NextAction $nxBadGoal -WaitsDir $et.waitsDir -TasksDir $et.tasksDir -GoalStoreDir $et.goalDir -CheckpointDir $et.ckptDir -FlagsPath $et.flagsPath -NowUtc $script:NOW -HandoffStateDir $et.ckptDir -ReceiptDir $et.receiptDir -ObjectiveStepProbe $probeT
Assert-That ((-not [bool](Get-CTField $ht2 'dispatched' $true)) -and ([string](Get-CTField $ht2 'reason' '') -ceq 'handoff-goal-mismatch')) 'tampered goal: refused handoff-goal-mismatch'
Assert-That ([int]$script:probeCallsT -eq 0) 'tampered goal: controller never invoked'
Assert-That (-not [bool](Get-CTField $ht2 'executed' $true)) 'tampered goal: executed false'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghwc-task-t' -TasksDir $et.tasksDir -RepoRoot $et.root).revision -eq $revT) 'tampered envelope: kernel untouched'
# --- HIGH-2: atomic claim before probe; sequential re-invocation never re-probes; persist failure holds without probe.
$ea = New-CTEnv -Tag 'atomic'
[void](New-CTGoal -Env $ea -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-x'))
Set-CTBlocked -Env $ea -TaskId 'ghwc-task-x' -Sha $script:SHA_A
New-CTWait -Env $ea -TaskId 'ghwc-task-x' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ea -GoalId 'ghwc-goal-1')
$fxa = Write-CTFixture -Env $ea -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wa = Invoke-CTWake -Env $ea -Fixture $fxa -Evt 'evt-ghwc-atomic'
$nxa = Get-CTField $wa 'next_action' $null
Assert-That ($null -ne $nxa) 'atomic setup: next_action present'
$script:probeCallsA = 0
$probeA = { param($na) $script:probeCallsA++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$ha1 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ReceiptDir $ea.receiptDir -ObjectiveStepProbe $probeA
Assert-That ((-not [bool](Get-CTField $ha1 'dispatched' $true)) -and ([string](Get-CTField $ha1 'decision' '') -ceq 'controller-responded')) 'atomic: probe-positive is controller-responded, marker claimed'
Assert-That ($null -ne (Get-CTField $ha1 'prepare' $null)) 'atomic: first call prepares a pending receipt'
$ha1mk = [string](Get-CTField $ha1 'marker_path' '')
$ha1set = Set-GHWakeDispatchSettlement -MarkerPath $ha1mk -SessionId 'sess-atomic-1' -ResultOk $true -ResultSummary 'atomic settle' -ReceiptDir $ea.receiptDir -GoalStoreDir $ea.goalDir -TasksDir $ea.tasksDir -FlagsPath $ea.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-x'
Assert-That (([bool](Get-CTField $ha1set 'dispatched' $false)) -and ([string](Get-CTField $ha1set 'reason' '') -ceq 'planner-settled')) 'atomic: settle flips claimed to dispatched'
$ha2 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ReceiptDir $ea.receiptDir -ObjectiveStepProbe $probeA
Assert-That ((-not [bool](Get-CTField $ha2 'dispatched' $true)) -and ([string](Get-CTField $ha2 'reason' '') -ceq 'duplicate-noop')) 'atomic: sequential re-invocation duplicate-noop'
Assert-That ([int]$script:probeCallsA -eq 1) 'atomic: probe invoked exactly once across sequential invocations'
$blockFile = Join-Path $ea.root 'blockfile'
[IO.File]::WriteAllText($blockFile, 'x', (New-Object Text.UTF8Encoding $false))
$badHsd = Join-Path $blockFile 'sub'
$script:probeCallsP = 0
$probeP = { param($na) $script:probeCallsP++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hp = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $badHsd -ObjectiveStepProbe $probeP
Assert-That ((-not [bool](Get-CTField $hp 'dispatched' $true)) -and ([string](Get-CTField $hp 'reason' '') -ceq 'handoff-persist-failed')) 'persist failure: HOLD handoff-persist-failed'
Assert-That ([int]$script:probeCallsP -eq 0) 'persist failure: controller never invoked'
# --- HIGH-3: empty MarkerPath never claims ok; missing state dirs HOLD before probe.
$cEmpty = New-GHWakeHandoffClaim -MarkerPath '' -TaskId 'ghwc-task-x' -DedupKey 'ddk-x' -EventId 'evt-x' -IdempotencyKey 'idem-x'
Assert-That ((-not [bool](Get-CTField $cEmpty 'ok' $true)) -and ([string](Get-CTField $cEmpty 'reason' '') -ceq 'handoff-persist-failed')) 'empty marker: claim HOLD handoff-persist-failed, never ok'
$cBlank = New-GHWakeHandoffClaim -MarkerPath '   ' -TaskId 'ghwc-task-x' -DedupKey 'ddk-x' -EventId 'evt-x' -IdempotencyKey 'idem-x'
Assert-That ((-not [bool](Get-CTField $cBlank 'ok' $true)) -and ([string](Get-CTField $cBlank 'reason' '') -ceq 'handoff-persist-failed')) 'blank marker: claim HOLD handoff-persist-failed, never ok'
$script:probeCallsN = 0
$probeN = { param($na) $script:probeCallsN++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hn2 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir '' -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir '' -ObjectiveStepProbe $probeN
Assert-That ((-not [bool](Get-CTField $hn2 'dispatched' $true)) -and ([string](Get-CTField $hn2 'reason' '') -ceq 'handoff-persist-failed')) 'missing state dirs: HOLD handoff-persist-failed'
Assert-That ([int]$script:probeCallsN -eq 0) 'missing state dirs: controller never invoked'
# --- MEDIUM-1: real I/O failure is persist-failed, never duplicate.
$mcBad = New-GHWakeHandoffClaim -MarkerPath (Join-Path $badHsd 'ghw-handoff-direct.json') -TaskId 'ghwc-task-x' -DedupKey 'ddk-x' -EventId 'evt-x' -IdempotencyKey 'idem-x'
Assert-That ((-not [bool](Get-CTField $mcBad 'ok' $true)) -and ([string](Get-CTField $mcBad 'reason' '') -ceq 'handoff-persist-failed') -and (-not [bool](Get-CTField $mcBad 'duplicate' $true))) 'io failure: real persist failure, never duplicate'
# --- MEDIUM-2 (REVIEW-6D-2F2): existing marker with unreadable/malformed content is persist-failed, never duplicate-noop.
$corrHsd = Join-Path $ea.root 'corr-hsd'
[void][IO.Directory]::CreateDirectory($corrHsd)
$corrIdem = ([string](Get-CTField $nxa 'idempotency_key' '')).Trim().ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $corrHsd ('ghw-handoff-' + $corrIdem + '.json')), '{{not-json', (New-Object Text.UTF8Encoding $false))
$mcCorr = New-GHWakeHandoffClaim -MarkerPath (Join-Path $corrHsd ('ghw-handoff-' + $corrIdem + '.json')) -TaskId 'ghwc-task-x' -DedupKey 'ddk-x' -EventId 'evt-x' -IdempotencyKey 'idem-x'
Assert-That ((-not [bool](Get-CTField $mcCorr 'ok' $true)) -and ([string](Get-CTField $mcCorr 'reason' '') -ceq 'handoff-persist-failed') -and (-not [bool](Get-CTField $mcCorr 'duplicate' $true))) 'corrupt marker: persist-failed, never duplicate'
$script:probeCallsC = 0
$probeC = { param($na) $script:probeCallsC++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hc = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $corrHsd -ObjectiveStepProbe $probeC
Assert-That ((-not [bool](Get-CTField $hc 'dispatched' $true)) -and ([string](Get-CTField $hc 'reason' '') -ceq 'handoff-persist-failed')) 'corrupt marker: HOLD handoff-persist-failed, never duplicate-noop'
Assert-That ([int]$script:probeCallsC -eq 0) 'corrupt marker: controller never invoked'
# --- MEDIUM-3 (REVIEW-6D-2F3): parseable marker with required fields missing/empty is persist-failed, never duplicate-noop.
$incHsd = Join-Path $ea.root 'inc-hsd'
[void][IO.Directory]::CreateDirectory($incHsd)
$incTid = ([string](Get-CTField $nxa 'task_id' '')).Trim()
$incDdk = ([string](Get-CTField $nxa 'wait_dedup_key' '')).Trim()
$incEvt = ([string](Get-CTField $nxa 'event_id' '')).Trim()
$incIdem = ([string](Get-CTField $nxa 'idempotency_key' '')).Trim().ToLowerInvariant()
$incPayload = [ordered]@{ task_id = $incTid; wait_dedup_key = $incDdk; event_id = ''; idempotency_key = ''; status = 'claimed' }
[IO.File]::WriteAllText((Join-Path $incHsd ('ghw-handoff-' + $incIdem + '.json')), (ConvertTo-Json -InputObject $incPayload -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$mcInc = New-GHWakeHandoffClaim -MarkerPath (Join-Path $incHsd ('ghw-handoff-' + $incIdem + '.json')) -TaskId $incTid -DedupKey $incDdk -EventId $incEvt -IdempotencyKey $incIdem
Assert-That ((-not [bool](Get-CTField $mcInc 'ok' $true)) -and ([string](Get-CTField $mcInc 'reason' '') -ceq 'handoff-persist-failed') -and (-not [bool](Get-CTField $mcInc 'duplicate' $true))) 'incomplete marker: persist-failed, never duplicate'
$script:probeCallsI = 0
$probeI = { param($na) $script:probeCallsI++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hi = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $incHsd -ObjectiveStepProbe $probeI
Assert-That ((-not [bool](Get-CTField $hi 'dispatched' $true)) -and ([string](Get-CTField $hi 'reason' '') -ceq 'handoff-persist-failed')) 'incomplete marker: HOLD handoff-persist-failed, never duplicate-noop'
Assert-That ([int]$script:probeCallsI -eq 0) 'incomplete marker: controller never invoked'
# --- MEDIUM-4 (REVIEW-6D-2F4): marker with diverged task_id/wait_dedup_key is
# --- idempotency-collision fail-closed, never ok/duplicate-noop, no probe.
$colHsd = Join-Path $ea.root 'col-hsd'
[void][IO.Directory]::CreateDirectory($colHsd)
$colTid = ([string](Get-CTField $nxa 'task_id' '')).Trim()
$colDdk = ([string](Get-CTField $nxa 'wait_dedup_key' '')).Trim()
$colEvt = ([string](Get-CTField $nxa 'event_id' '')).Trim()
$colIdem = ([string](Get-CTField $nxa 'idempotency_key' '')).Trim().ToLowerInvariant()
$colPayload = [ordered]@{ task_id = ($colTid + '-other'); wait_dedup_key = $colDdk; event_id = $colEvt; idempotency_key = $colIdem; status = 'claimed' }
[IO.File]::WriteAllText((Join-Path $colHsd ('ghw-handoff-' + $colIdem + '.json')), (ConvertTo-Json -InputObject $colPayload -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$mcCol = New-GHWakeHandoffClaim -MarkerPath (Join-Path $colHsd ('ghw-handoff-' + $colIdem + '.json')) -TaskId $colTid -DedupKey $colDdk -EventId $colEvt -IdempotencyKey $colIdem
Assert-That ((-not [bool](Get-CTField $mcCol 'ok' $true)) -and ([string](Get-CTField $mcCol 'reason' '') -ceq 'idempotency-collision') -and (-not [bool](Get-CTField $mcCol 'duplicate' $true))) 'collision task: fail-closed idempotency-collision, never duplicate-noop'
$colHsd2 = Join-Path $ea.root 'col-hsd2'
[void][IO.Directory]::CreateDirectory($colHsd2)
$colPayload2 = [ordered]@{ task_id = $colTid; wait_dedup_key = ($colDdk + '-other'); event_id = $colEvt; idempotency_key = $colIdem; status = 'claimed' }
[IO.File]::WriteAllText((Join-Path $colHsd2 ('ghw-handoff-' + $colIdem + '.json')), (ConvertTo-Json -InputObject $colPayload2 -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$mcCol2 = New-GHWakeHandoffClaim -MarkerPath (Join-Path $colHsd2 ('ghw-handoff-' + $colIdem + '.json')) -TaskId $colTid -DedupKey $colDdk -EventId $colEvt -IdempotencyKey $colIdem
Assert-That ((-not [bool](Get-CTField $mcCol2 'ok' $true)) -and ([string](Get-CTField $mcCol2 'reason' '') -ceq 'idempotency-collision') -and (-not [bool](Get-CTField $mcCol2 'duplicate' $true))) 'collision dedup: fail-closed idempotency-collision, never duplicate-noop'
$script:probeCallsCol = 0
$probeCol = { param($na) $script:probeCallsCol++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hcol = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $colHsd -ObjectiveStepProbe $probeCol
Assert-That ((-not [bool](Get-CTField $hcol 'dispatched' $true)) -and ([string](Get-CTField $hcol 'reason' '') -ceq 'idempotency-collision')) 'collision task: HOLD idempotency-collision, never dispatched'
Assert-That ([int]$script:probeCallsCol -eq 0) 'collision task: controller never invoked'
# --- LOW-1: probeOnly replay with event already applied never re-probes.
$evtA = [string](Get-CTField $nxa 'event_id' '')
Assert-That (-not [string]::IsNullOrWhiteSpace($evtA)) 'probeOnly replay setup: event_id present'
Set-CTWaitField -Env $ea -Name 'applied_events' -Value @($evtA)
$ha3 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ReceiptDir $ea.receiptDir -ObjectiveStepProbe $probeA
Assert-That ((-not [bool](Get-CTField $ha3 'dispatched' $true)) -and ([string](Get-CTField $ha3 'reason' '') -ceq 'duplicate-noop')) 'probeOnly replay with applied event: HOLD duplicate-noop'
Assert-That ([int]$script:probeCallsA -eq 1) 'probeOnly replay with applied event: no second probe'
# --- intent-ready (no probe): valid intent + pending receipt, never dispatched.
$ei = New-CTEnv -Tag 'intent'
[void](New-CTGoal -Env $ei -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-i'))
Set-CTBlocked -Env $ei -TaskId 'ghwc-task-i' -Sha $script:SHA_A
New-CTWait -Env $ei -TaskId 'ghwc-task-i' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ei -GoalId 'ghwc-goal-1')
$fxi = Write-CTFixture -Env $ei -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wi = Invoke-CTWake -Env $ei -Fixture $fxi -Evt 'evt-ghwc-intent'
$nxi = Get-CTField $wi 'next_action' $null
Assert-That ($null -ne $nxi) 'intent-ready setup: next_action present'
$hi = Invoke-GHWakeControllerHandoff -NextAction $nxi -WaitsDir $ei.waitsDir -TasksDir $ei.tasksDir -GoalStoreDir $ei.goalDir -CheckpointDir $ei.ckptDir -FlagsPath $ei.flagsPath -NowUtc $script:NOW -HandoffStateDir $ei.ckptDir -ReceiptDir $ei.receiptDir
Assert-That ((-not [bool](Get-CTField $hi 'dispatched' $true)) -and ([string](Get-CTField $hi 'decision' '') -ceq 'intent-ready')) 'intent-ready: decision intent-ready, dispatched false'
Assert-That ([string](Get-CTField $hi 'reason' '') -ceq 'prepared-awaits-planner-dispatch') 'intent-ready: typed reason awaits planner'
Assert-That (($null -ne (Get-CTField $hi 'dispatch_intent' $null)) -and ([string](Get-CTField (Get-CTField $hi 'prepare' $null) 'phase' '') -ceq 'prepared')) 'intent-ready: valid intent + pending receipt, no execution'
Assert-That (-not [bool](Get-CTField $hi 'executed' $true)) 'intent-ready: executed false'
$hiMk = [string](Get-CTField $hi 'marker_path' '')
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hiMk, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'intent-ready: marker claimed'
$hiS = Set-GHWakeDispatchSettlement -MarkerPath $hiMk -SessionId 'sess-intent-1' -ResultOk $false -ResultSummary 'planner reports failed candidate' -ReceiptDir $ei.receiptDir -GoalStoreDir $ei.goalDir -TasksDir $ei.tasksDir -FlagsPath $ei.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-i'
Assert-That (([bool](Get-CTField $hiS 'dispatched' $false)) -and ([string](Get-CTField $hiS 'reason' '') -ceq 'planner-settled')) 'intent-ready settle: failed candidate still settles the loop'
# --- declined probe releases the claim; retry reuses the prepared receipt.
$er = New-CTEnv -Tag 'reuse'
[void](New-CTGoal -Env $er -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-r'))
Set-CTBlocked -Env $er -TaskId 'ghwc-task-r' -Sha $script:SHA_A
New-CTWait -Env $er -TaskId 'ghwc-task-r' -Sha $script:SHA_A
[void](New-CTCkpt -Env $er -GoalId 'ghwc-goal-1')
$fxr = Write-CTFixture -Env $er -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wr = Invoke-CTWake -Env $er -Fixture $fxr -Evt 'evt-ghwc-reuse'
$nxr = Get-CTField $wr 'next_action' $null
Assert-That ($null -ne $nxr) 'reuse setup: next_action present'
$decProbe = { param($na) return [pscustomobject]@{ dispatched = $false; reason = 'mock-declined' } }
$hr1 = Invoke-GHWakeControllerHandoff -NextAction $nxr -WaitsDir $er.waitsDir -TasksDir $er.tasksDir -GoalStoreDir $er.goalDir -CheckpointDir $er.ckptDir -FlagsPath $er.flagsPath -NowUtc $script:NOW -HandoffStateDir $er.ckptDir -ReceiptDir $er.receiptDir -ObjectiveStepProbe $decProbe
Assert-That ((-not [bool](Get-CTField $hr1 'dispatched' $true)) -and ([string](Get-CTField $hr1 'reason' '') -ceq 'mock-declined')) 'declined probe: not-dispatched, claim released'
$hr1mk = [string](Get-CTField $hr1 'marker_path' '')
Assert-That (-not (Test-Path -LiteralPath $hr1mk -PathType Leaf)) 'declined probe: marker removed, receipt stays prepared'
$fp1 = [string](Get-CTField (Get-CTField $hr1 'prepare' $null) 'prepared_fingerprint' '')
Assert-That ($fp1 -cmatch '^[a-f0-9]{32}$') 'declined probe: first prepare fingerprint recorded'
$script:probeCallsR = 0
$posProbe = { param($na) $script:probeCallsR++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hr2 = Invoke-GHWakeControllerHandoff -NextAction $nxr -WaitsDir $er.waitsDir -TasksDir $er.tasksDir -GoalStoreDir $er.goalDir -CheckpointDir $er.ckptDir -FlagsPath $er.flagsPath -NowUtc $script:NOW -HandoffStateDir $er.ckptDir -ReceiptDir $er.receiptDir -ObjectiveStepProbe $posProbe
Assert-That (([string](Get-CTField $hr2 'decision' '') -ceq 'controller-responded') -and (-not [bool](Get-CTField $hr2 'dispatched' $true))) 'reuse: retry is controller-responded, never dispatched'
$hr2prep = Get-CTField $hr2 'prepare' $null
Assert-That (([bool](Get-CTField $hr2prep 'reused' $false)) -and ([string](Get-CTField $hr2prep 'prepared_fingerprint' '') -ceq $fp1)) 'reuse: second call reuses the same prepared receipt (no second intent)'
Assert-That ([int]$script:probeCallsR -eq 1) 'reuse: probe invoked once on retry'
# --- driver single-shot end-to-end (real read-only controller path, no probe).
$nxFile = Join-Path $e.root 'next-action.json'
[IO.File]::WriteAllText($nxFile, (ConvertTo-Json -InputObject $nx -Depth 10), (New-Object Text.UTF8Encoding $false))
$drvArgs = @('-NoProfile', '-File', $script:ctrlCli, '-NextActionFile', $nxFile, '-WaitsDir', $e.waitsDir, '-TasksDir', $e.tasksDir, '-GoalStoreDir', $e.goalDir, '-CheckpointDir', $e.ckptDir, '-ReceiptDir', $e.receiptDir, '-FlagsPath', $e.flagsPath, '-NowUtc', $script:NOW)
$drvOut = & $script:childExe @drvArgs 2>$null
$drvCode = $LASTEXITCODE
$drvText = ''
if ($null -ne $drvOut) { $drvText = ($drvOut -join "`n").Trim() }
$drvEnv = $null
try { if (-not [string]::IsNullOrWhiteSpace($drvText)) { $drvEnv = ConvertFrom-Json $drvText } } catch { $drvEnv = $null }
Assert-That (([int]$drvCode -eq 0) -and ($null -ne $drvEnv)) 'driver single-shot: exit 0 with JSON envelope'
Assert-That ([string](Get-CTField $drvEnv 'harness' '') -ceq 'github-wake-controller-v1') 'driver envelope: harness pinned'
Assert-That (-not [bool](Get-CTField $drvEnv 'dispatched' $true)) 'driver without executor: honest not-dispatched (no native spawn)'
Assert-That (([string](Get-CTField $drvEnv 'reason' '') -cmatch 'duplicate-noop|awaits-planner-dispatch') -and (-not [bool](Get-CTField $drvEnv 'executed' $true))) 'driver without executor: typed HOLD reason, executed false'
Assert-That ((-not [bool](Get-CTField $drvEnv 'grants_authority' $true)) -and (-not [bool](Get-CTField $drvEnv 'done_approved' $true)) -and (-not [bool](Get-CTField $drvEnv 'merge_authority' $true))) 'driver envelope: authority pins stay false'
# --- driver settle E2E: prepare via driver, settle via driver (Planner loop).
$ed = New-CTEnv -Tag 'drvset'
[void](New-CTGoal -Env $ed -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-s'))
Set-CTBlocked -Env $ed -TaskId 'ghwc-task-s' -Sha $script:SHA_A
New-CTWait -Env $ed -TaskId 'ghwc-task-s' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ed -GoalId 'ghwc-goal-1')
$fxd = Write-CTFixture -Env $ed -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wd = Invoke-CTWake -Env $ed -Fixture $fxd -Evt 'evt-ghwc-drvset'
$nxd = Get-CTField $wd 'next_action' $null
Assert-That ($null -ne $nxd) 'driver settle setup: next_action present'
$nxdFile = Join-Path $ed.root 'next-action.json'
[IO.File]::WriteAllText($nxdFile, (ConvertTo-Json -InputObject $nxd -Depth 10), (New-Object Text.UTF8Encoding $false))
$drvBase = @('-NoProfile', '-File', $script:ctrlCli, '-NextActionFile', $nxdFile, '-WaitsDir', $ed.waitsDir, '-TasksDir', $ed.tasksDir, '-GoalStoreDir', $ed.goalDir, '-CheckpointDir', $ed.ckptDir, '-HandoffStateDir', $ed.ckptDir, '-ReceiptDir', $ed.receiptDir, '-FlagsPath', $ed.flagsPath, '-NowUtc', $script:NOW)
$drvOut1 = & $script:childExe @drvBase 2>$null
$drvCode1 = $LASTEXITCODE
$drvEnv1 = $null
try { if (($null -ne $drvOut1) -and (-not [string]::IsNullOrWhiteSpace(($drvOut1 -join "`n").Trim()))) { $drvEnv1 = ConvertFrom-Json (($drvOut1 -join "`n").Trim()) } } catch { $drvEnv1 = $null }
Assert-That (([int]$drvCode1 -eq 0) -and ($null -ne $drvEnv1)) 'driver settle step1: exit 0 with JSON envelope'
Assert-That (([string](Get-CTField $drvEnv1 'decision' '') -ceq 'intent-ready') -and (-not [bool](Get-CTField $drvEnv1 'dispatched' $true))) 'driver settle step1: intent-ready, preparing receipts is not dispatch'
$drvMk = [string](Get-CTField $drvEnv1 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($drvMk)) -and (Test-Path -LiteralPath $drvMk -PathType Leaf)) 'driver settle step1: marker path surfaced for the Planner loop'
$drvOut2 = & $script:childExe @($drvBase + @('-SettleSessionId', 'sess-driver-1', '-SettleResultOk', 'true', '-SettleResultSummary', 'driver e2e settle')) 2>$null
$drvCode2 = $LASTEXITCODE
$drvEnv2 = $null
try { if (($null -ne $drvOut2) -and (-not [string]::IsNullOrWhiteSpace(($drvOut2 -join "`n").Trim()))) { $drvEnv2 = ConvertFrom-Json (($drvOut2 -join "`n").Trim()) } } catch { $drvEnv2 = $null }
Assert-That (([int]$drvCode2 -eq 0) -and ($null -ne $drvEnv2)) 'driver settle step2: exit 0 with JSON envelope'
Assert-That (([bool](Get-CTField $drvEnv2 'dispatched' $false)) -and ([string](Get-CTField $drvEnv2 'decision' '') -ceq 'dispatched') -and ([bool](Get-CTField $drvEnv2 'executed' $false))) 'driver settle step2: Planner settle flips to dispatched+executed'
Assert-That ([string](Get-CTField $drvEnv2 'reason' '') -ceq 'planner-settled') 'driver settle step2: typed planner-settled reason'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($drvMk, [Text.Encoding]::UTF8))) 'session_id' '') -ceq 'sess-driver-1') 'driver settle step2: marker carries the real session id'
$drvOut3 = & $script:childExe @($drvBase + @('-SettleSessionId', 'sess-driver-1', '-SettleResultOk', 'true', '-SettleResultSummary', 'driver e2e settle')) 2>$null
$drvEnv3 = $null
try { if (($null -ne $drvOut3) -and (-not [string]::IsNullOrWhiteSpace(($drvOut3 -join "`n").Trim()))) { $drvEnv3 = ConvertFrom-Json (($drvOut3 -join "`n").Trim()) } } catch { $drvEnv3 = $null }
Assert-That (([bool](Get-CTField $drvEnv3 'dispatched' $false)) -and ([string](Get-CTField $drvEnv3 'reason' '') -ceq 'settle-duplicate')) 'driver settle step3: replay is idempotent settle-duplicate'
# --- MEDIUM-6D-DISP-F7: fin re-read dispatched with tampered task_id is
# --- fail-closed settle-identity-diverged; marker never overwritten.
$efT = New-CTEnv -Tag 'fint'
[void](New-CTGoal -Env $efT -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-ft'))
Set-CTBlocked -Env $efT -TaskId 'ghwc-task-ft' -Sha $script:SHA_A
New-CTWait -Env $efT -TaskId 'ghwc-task-ft' -Sha $script:SHA_A
[void](New-CTCkpt -Env $efT -GoalId 'ghwc-goal-1')
$fxfT = Write-CTFixture -Env $efT -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wfT = Invoke-CTWake -Env $efT -Fixture $fxfT -Evt 'evt-ghwc-fint'
$nfT = Get-CTField $wfT 'next_action' $null
Assert-That ($null -ne $nfT) 'fin task setup: next_action present'
$script:probeCallsFT = 0
$probeFT = { param($na) $script:probeCallsFT++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hfT = Invoke-GHWakeControllerHandoff -NextAction $nfT -WaitsDir $efT.waitsDir -TasksDir $efT.tasksDir -GoalStoreDir $efT.goalDir -CheckpointDir $efT.ckptDir -FlagsPath $efT.flagsPath -NowUtc $script:NOW -HandoffStateDir $efT.ckptDir -ReceiptDir $efT.receiptDir -ObjectiveStepProbe $probeFT
$hfTMk = [string](Get-CTField $hfT 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hfTMk)) -and (Test-Path -LiteralPath $hfTMk -PathType Leaf)) 'fin task setup: marker claimed'
$sfTok = Set-GHWakeDispatchSettlement -MarkerPath $hfTMk -SessionId 'sess-fint-1' -ResultOk $true -ResultSummary 'first settle' -ReceiptDir $efT.receiptDir -GoalStoreDir $efT.goalDir -TasksDir $efT.tasksDir -FlagsPath $efT.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-ft'
Assert-That ([string](Get-CTField $sfTok 'reason' '') -ceq 'planner-settled') 'fin task setup: first settle planner-settled'
$recFT = ConvertFrom-Json ([IO.File]::ReadAllText($hfTMk, [Text.Encoding]::UTF8))
$origFTTask = ([string](Get-CTField $recFT 'task_id' ''))
$origFTIdem = ([string](Get-CTField $recFT 'idempotency_key' ''))
$recFT.status = 'claimed'
[IO.File]::WriteAllText($hfTMk, (ConvertTo-Json -InputObject $recFT -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$script:ghwRdCountFT = 0
$script:ghwRdOrigFT = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountFT++
    $d = (& $script:ghwRdOrigFT -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountFT -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-fint-1' -Force } catch { }
        try { $d.task_id = 'ghwc-task-tampered' } catch { }
    }
    return $d
}
$sfTDiv = Set-GHWakeDispatchSettlement -MarkerPath $hfTMk -SessionId 'sess-fint-1' -ResultOk $true -ResultSummary 'fin replay tampered task' -ReceiptDir $efT.receiptDir -GoalStoreDir $efT.goalDir -TasksDir $efT.tasksDir -FlagsPath $efT.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-ft'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigFT
Assert-That ((-not [bool](Get-CTField $sfTDiv 'dispatched' $true)) -and ([string](Get-CTField $sfTDiv 'reason' '') -ceq 'settle-identity-diverged')) 'fin tampered task: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $sfTDiv 'executed' $true)) 'fin tampered task: never executed'
$sfTAfter = ConvertFrom-Json ([IO.File]::ReadAllText($hfTMk, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $sfTAfter 'status' '') -ceq 'claimed') 'fin tampered task: marker stays claimed'
Assert-That ((([string](Get-CTField $sfTAfter 'task_id' '') -ceq $origFTTask) -and ([string](Get-CTField $sfTAfter 'idempotency_key' '') -ceq $origFTIdem))) 'fin tampered task: marker identity not overwritten'
# --- MEDIUM-6D-DISP-F7: fin re-read dispatched with tampered idempotency_key
# --- is fail-closed settle-identity-diverged; marker never overwritten.
$efI = New-CTEnv -Tag 'fini'
[void](New-CTGoal -Env $efI -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-fi'))
Set-CTBlocked -Env $efI -TaskId 'ghwc-task-fi' -Sha $script:SHA_A
New-CTWait -Env $efI -TaskId 'ghwc-task-fi' -Sha $script:SHA_A
[void](New-CTCkpt -Env $efI -GoalId 'ghwc-goal-1')
$fxfI = Write-CTFixture -Env $efI -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wfI = Invoke-CTWake -Env $efI -Fixture $fxfI -Evt 'evt-ghwc-fini'
$nfI = Get-CTField $wfI 'next_action' $null
Assert-That ($null -ne $nfI) 'fin idem setup: next_action present'
$script:probeCallsFI = 0
$probeFI = { param($na) $script:probeCallsFI++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hfI = Invoke-GHWakeControllerHandoff -NextAction $nfI -WaitsDir $efI.waitsDir -TasksDir $efI.tasksDir -GoalStoreDir $efI.goalDir -CheckpointDir $efI.ckptDir -FlagsPath $efI.flagsPath -NowUtc $script:NOW -HandoffStateDir $efI.ckptDir -ReceiptDir $efI.receiptDir -ObjectiveStepProbe $probeFI
$hfIMk = [string](Get-CTField $hfI 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hfIMk)) -and (Test-Path -LiteralPath $hfIMk -PathType Leaf)) 'fin idem setup: marker claimed'
$sfIok = Set-GHWakeDispatchSettlement -MarkerPath $hfIMk -SessionId 'sess-fini-1' -ResultOk $true -ResultSummary 'first settle' -ReceiptDir $efI.receiptDir -GoalStoreDir $efI.goalDir -TasksDir $efI.tasksDir -FlagsPath $efI.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-fi'
Assert-That ([string](Get-CTField $sfIok 'reason' '') -ceq 'planner-settled') 'fin idem setup: first settle planner-settled'
$recFI = ConvertFrom-Json ([IO.File]::ReadAllText($hfIMk, [Text.Encoding]::UTF8))
$origFITask = ([string](Get-CTField $recFI 'task_id' ''))
$origFIIdem = ([string](Get-CTField $recFI 'idempotency_key' ''))
$recFI.status = 'claimed'
[IO.File]::WriteAllText($hfIMk, (ConvertTo-Json -InputObject $recFI -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$script:ghwRdCountFI = 0
$script:ghwRdOrigFI = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountFI++
    $d = (& $script:ghwRdOrigFI -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountFI -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-fini-1' -Force } catch { }
        try { $d.idempotency_key = 'ffffffffffffffffffffffffffffffff' } catch { }
    }
    return $d
}
$sfIDiv = Set-GHWakeDispatchSettlement -MarkerPath $hfIMk -SessionId 'sess-fini-1' -ResultOk $true -ResultSummary 'fin replay tampered idem' -ReceiptDir $efI.receiptDir -GoalStoreDir $efI.goalDir -TasksDir $efI.tasksDir -FlagsPath $efI.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-fi'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigFI
Assert-That ((-not [bool](Get-CTField $sfIDiv 'dispatched' $true)) -and ([string](Get-CTField $sfIDiv 'reason' '') -ceq 'settle-identity-diverged')) 'fin tampered idem: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $sfIDiv 'executed' $true)) 'fin tampered idem: never executed'
$sfIAfter = ConvertFrom-Json ([IO.File]::ReadAllText($hfIMk, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $sfIAfter 'status' '') -ceq 'claimed') 'fin tampered idem: marker stays claimed'
Assert-That ((([string](Get-CTField $sfIAfter 'task_id' '') -ceq $origFITask) -and ([string](Get-CTField $sfIAfter 'idempotency_key' '') -ceq $origFIIdem))) 'fin tampered idem: marker identity not overwritten'
# --- MEDIUM-6D-DISP-F7: fin re-read dispatched with tampered goal_id is
# --- fail-closed settle-identity-diverged; marker never overwritten.
$efG = New-CTEnv -Tag 'fing'
[void](New-CTGoal -Env $efG -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-fg'))
Set-CTBlocked -Env $efG -TaskId 'ghwc-task-fg' -Sha $script:SHA_A
New-CTWait -Env $efG -TaskId 'ghwc-task-fg' -Sha $script:SHA_A
[void](New-CTCkpt -Env $efG -GoalId 'ghwc-goal-1')
$fxfG = Write-CTFixture -Env $efG -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wfG = Invoke-CTWake -Env $efG -Fixture $fxfG -Evt 'evt-ghwc-fing'
$nfG = Get-CTField $wfG 'next_action' $null
Assert-That ($null -ne $nfG) 'fin goal setup: next_action present'
$script:probeCallsFG = 0
$probeFG = { param($na) $script:probeCallsFG++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hfG = Invoke-GHWakeControllerHandoff -NextAction $nfG -WaitsDir $efG.waitsDir -TasksDir $efG.tasksDir -GoalStoreDir $efG.goalDir -CheckpointDir $efG.ckptDir -FlagsPath $efG.flagsPath -NowUtc $script:NOW -HandoffStateDir $efG.ckptDir -ReceiptDir $efG.receiptDir -ObjectiveStepProbe $probeFG
$hfGMk = [string](Get-CTField $hfG 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hfGMk)) -and (Test-Path -LiteralPath $hfGMk -PathType Leaf)) 'fin goal setup: marker claimed'
$sfGok = Set-GHWakeDispatchSettlement -MarkerPath $hfGMk -SessionId 'sess-fing-1' -ResultOk $true -ResultSummary 'first settle' -ReceiptDir $efG.receiptDir -GoalStoreDir $efG.goalDir -TasksDir $efG.tasksDir -FlagsPath $efG.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-fg'
Assert-That ([string](Get-CTField $sfGok 'reason' '') -ceq 'planner-settled') 'fin goal setup: first settle planner-settled'
$recFG = ConvertFrom-Json ([IO.File]::ReadAllText($hfGMk, [Text.Encoding]::UTF8))
$origFGGoal = ([string](Get-CTField $recFG 'goal_id' ''))
$recFG.status = 'claimed'
[IO.File]::WriteAllText($hfGMk, (ConvertTo-Json -InputObject $recFG -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$script:ghwRdCountFG = 0
$script:ghwRdOrigFG = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountFG++
    $d = (& $script:ghwRdOrigFG -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountFG -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-fing-1' -Force } catch { }
        try { $d.goal_id = 'ghwc-goal-evil' } catch { }
    }
    return $d
}
$sfGDiv = Set-GHWakeDispatchSettlement -MarkerPath $hfGMk -SessionId 'sess-fing-1' -ResultOk $true -ResultSummary 'fin replay tampered goal' -ReceiptDir $efG.receiptDir -GoalStoreDir $efG.goalDir -TasksDir $efG.tasksDir -FlagsPath $efG.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-fg'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigFG
Assert-That ((-not [bool](Get-CTField $sfGDiv 'dispatched' $true)) -and ([string](Get-CTField $sfGDiv 'reason' '') -ceq 'settle-identity-diverged')) 'fin tampered goal: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $sfGDiv 'executed' $true)) 'fin tampered goal: never executed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hfGMk, [Text.Encoding]::UTF8))) 'goal_id' '') -ceq $origFGGoal) 'fin tampered goal: marker goal not overwritten'
# --- MEDIUM-6D-DISP-F7: cur re-read dispatched with tampered task_id is
# --- fail-closed settle-identity-diverged; marker never overwritten.
$ecT = New-CTEnv -Tag 'curt'
[void](New-CTGoal -Env $ecT -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-ct'))
Set-CTBlocked -Env $ecT -TaskId 'ghwc-task-ct' -Sha $script:SHA_A
New-CTWait -Env $ecT -TaskId 'ghwc-task-ct' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ecT -GoalId 'ghwc-goal-1')
$fxcT = Write-CTFixture -Env $ecT -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wcT = Invoke-CTWake -Env $ecT -Fixture $fxcT -Evt 'evt-ghwc-curt'
$ncT = Get-CTField $wcT 'next_action' $null
Assert-That ($null -ne $ncT) 'cur task setup: next_action present'
$script:probeCallsCT = 0
$probeCT = { param($na) $script:probeCallsCT++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hcT = Invoke-GHWakeControllerHandoff -NextAction $ncT -WaitsDir $ecT.waitsDir -TasksDir $ecT.tasksDir -GoalStoreDir $ecT.goalDir -CheckpointDir $ecT.ckptDir -FlagsPath $ecT.flagsPath -NowUtc $script:NOW -HandoffStateDir $ecT.ckptDir -ReceiptDir $ecT.receiptDir -ObjectiveStepProbe $probeCT
$hcTMk = [string](Get-CTField $hcT 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hcTMk)) -and (Test-Path -LiteralPath $hcTMk -PathType Leaf)) 'cur task setup: marker claimed'
$hcTOrig = ConvertFrom-Json ([IO.File]::ReadAllText($hcTMk, [Text.Encoding]::UTF8))
$origCTTask = ([string](Get-CTField $hcTOrig 'task_id' ''))
$origCTIdem = ([string](Get-CTField $hcTOrig 'idempotency_key' ''))
$script:ghwRdCountCT = 0
$script:ghwRdOrigCT = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountCT++
    $d = (& $script:ghwRdOrigCT -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountCT -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-curt-1' -Force } catch { }
        try { $d.task_id = 'ghwc-task-tampered' } catch { }
    }
    return $d
}
$scTDiv = Set-GHWakeDispatchSettlement -MarkerPath $hcTMk -SessionId 'sess-curt-1' -ResultOk $true -ResultSummary 'cur replay tampered task' -ReceiptDir $ecT.receiptDir -GoalStoreDir $ecT.goalDir -TasksDir $ecT.tasksDir -FlagsPath $ecT.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-ct'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigCT
Assert-That ((-not [bool](Get-CTField $scTDiv 'dispatched' $true)) -and ([string](Get-CTField $scTDiv 'reason' '') -ceq 'settle-identity-diverged')) 'cur tampered task: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $scTDiv 'executed' $true)) 'cur tampered task: never executed'
$scTAfter = ConvertFrom-Json ([IO.File]::ReadAllText($hcTMk, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $scTAfter 'status' '') -ceq 'claimed') 'cur tampered task: marker stays claimed'
Assert-That ((([string](Get-CTField $scTAfter 'task_id' '') -ceq $origCTTask) -and ([string](Get-CTField $scTAfter 'idempotency_key' '') -ceq $origCTIdem))) 'cur tampered task: marker identity not overwritten'
# --- MEDIUM-6D-DISP-F7: cur re-read dispatched with tampered idempotency_key
# --- is fail-closed settle-identity-diverged; marker never overwritten.
$ecI = New-CTEnv -Tag 'curi'
[void](New-CTGoal -Env $ecI -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-ci'))
Set-CTBlocked -Env $ecI -TaskId 'ghwc-task-ci' -Sha $script:SHA_A
New-CTWait -Env $ecI -TaskId 'ghwc-task-ci' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ecI -GoalId 'ghwc-goal-1')
$fxcI = Write-CTFixture -Env $ecI -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wcI = Invoke-CTWake -Env $ecI -Fixture $fxcI -Evt 'evt-ghwc-curi'
$ncI = Get-CTField $wcI 'next_action' $null
Assert-That ($null -ne $ncI) 'cur idem setup: next_action present'
$script:probeCallsCI = 0
$probeCI = { param($na) $script:probeCallsCI++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hcI = Invoke-GHWakeControllerHandoff -NextAction $ncI -WaitsDir $ecI.waitsDir -TasksDir $ecI.tasksDir -GoalStoreDir $ecI.goalDir -CheckpointDir $ecI.ckptDir -FlagsPath $ecI.flagsPath -NowUtc $script:NOW -HandoffStateDir $ecI.ckptDir -ReceiptDir $ecI.receiptDir -ObjectiveStepProbe $probeCI
$hcIMk = [string](Get-CTField $hcI 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hcIMk)) -and (Test-Path -LiteralPath $hcIMk -PathType Leaf)) 'cur idem setup: marker claimed'
$hcIOrig = ConvertFrom-Json ([IO.File]::ReadAllText($hcIMk, [Text.Encoding]::UTF8))
$origCITask = ([string](Get-CTField $hcIOrig 'task_id' ''))
$origCIIdem = ([string](Get-CTField $hcIOrig 'idempotency_key' ''))
$script:ghwRdCountCI = 0
$script:ghwRdOrigCI = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountCI++
    $d = (& $script:ghwRdOrigCI -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountCI -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-curi-1' -Force } catch { }
        try { $d.idempotency_key = 'ffffffffffffffffffffffffffffffff' } catch { }
    }
    return $d
}
$scIDiv = Set-GHWakeDispatchSettlement -MarkerPath $hcIMk -SessionId 'sess-curi-1' -ResultOk $true -ResultSummary 'cur replay tampered idem' -ReceiptDir $ecI.receiptDir -GoalStoreDir $ecI.goalDir -TasksDir $ecI.tasksDir -FlagsPath $ecI.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-ci'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigCI
Assert-That ((-not [bool](Get-CTField $scIDiv 'dispatched' $true)) -and ([string](Get-CTField $scIDiv 'reason' '') -ceq 'settle-identity-diverged')) 'cur tampered idem: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $scIDiv 'executed' $true)) 'cur tampered idem: never executed'
$scIAfter = ConvertFrom-Json ([IO.File]::ReadAllText($hcIMk, [Text.Encoding]::UTF8))
Assert-That ([string](Get-CTField $scIAfter 'status' '') -ceq 'claimed') 'cur tampered idem: marker stays claimed'
Assert-That ((([string](Get-CTField $scIAfter 'task_id' '') -ceq $origCITask) -and ([string](Get-CTField $scIAfter 'idempotency_key' '') -ceq $origCIIdem))) 'cur tampered idem: marker identity not overwritten'
# --- MEDIUM-6D-DISP-F7: cur re-read dispatched with tampered wait_dedup_key
# --- is fail-closed settle-identity-diverged; marker never overwritten.
$ecD = New-CTEnv -Tag 'curd'
[void](New-CTGoal -Env $ecD -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-cd'))
Set-CTBlocked -Env $ecD -TaskId 'ghwc-task-cd' -Sha $script:SHA_A
New-CTWait -Env $ecD -TaskId 'ghwc-task-cd' -Sha $script:SHA_A
[void](New-CTCkpt -Env $ecD -GoalId 'ghwc-goal-1')
$fxcD = Write-CTFixture -Env $ecD -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$wcD = Invoke-CTWake -Env $ecD -Fixture $fxcD -Evt 'evt-ghwc-curd'
$ncD = Get-CTField $wcD 'next_action' $null
Assert-That ($null -ne $ncD) 'cur dedup setup: next_action present'
$script:probeCallsCD = 0
$probeCD = { param($na) $script:probeCallsCD++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$hcD = Invoke-GHWakeControllerHandoff -NextAction $ncD -WaitsDir $ecD.waitsDir -TasksDir $ecD.tasksDir -GoalStoreDir $ecD.goalDir -CheckpointDir $ecD.ckptDir -FlagsPath $ecD.flagsPath -NowUtc $script:NOW -HandoffStateDir $ecD.ckptDir -ReceiptDir $ecD.receiptDir -ObjectiveStepProbe $probeCD
$hcDMk = [string](Get-CTField $hcD 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($hcDMk)) -and (Test-Path -LiteralPath $hcDMk -PathType Leaf)) 'cur dedup setup: marker claimed'
$hcDOrig = ConvertFrom-Json ([IO.File]::ReadAllText($hcDMk, [Text.Encoding]::UTF8))
$origCDDdk = ([string](Get-CTField $hcDOrig 'wait_dedup_key' ''))
$script:ghwRdCountCD = 0
$script:ghwRdOrigCD = (Get-Command Read-GHWakeMarkerDoc).ScriptBlock
function Read-GHWakeMarkerDoc {
    param([string]$MarkerPath = '')
    $script:ghwRdCountCD++
    $d = (& $script:ghwRdOrigCD -MarkerPath $MarkerPath)
    if ([int]$script:ghwRdCountCD -ge 2) {
        try { $d.status = 'dispatched' } catch { }
        try { $d | Add-Member -NotePropertyName 'session_id' -NotePropertyValue 'sess-curd-1' -Force } catch { }
        try { $d.wait_dedup_key = 'ddk-tampered' } catch { }
    }
    return $d
}
$scDDiv = Set-GHWakeDispatchSettlement -MarkerPath $hcDMk -SessionId 'sess-curd-1' -ResultOk $true -ResultSummary 'cur replay tampered dedup' -ReceiptDir $ecD.receiptDir -GoalStoreDir $ecD.goalDir -TasksDir $ecD.tasksDir -FlagsPath $ecD.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-cd'
${function:Read-GHWakeMarkerDoc} = $script:ghwRdOrigCD
Assert-That ((-not [bool](Get-CTField $scDDiv 'dispatched' $true)) -and ([string](Get-CTField $scDDiv 'reason' '') -ceq 'settle-identity-diverged')) 'cur tampered dedup: refused settle-identity-diverged'
Assert-That (-not [bool](Get-CTField $scDDiv 'executed' $true)) 'cur tampered dedup: never executed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($hcDMk, [Text.Encoding]::UTF8))) 'wait_dedup_key' '') -ceq $origCDDdk) 'cur tampered dedup: marker dedup not overwritten'
# --- MEDIUM-6D-DISP-F9: upfront gate on the claimed path (a): receipt
# --- goal divergent or absent with marker claimed is fail-closed
# --- settle-identity-diverged; marker stays claimed, receipt unmutated
# --- (a later legitimate settle still completes, proving no Claim was
# --- consumed by the refused attempts).
$e9a = New-CTEnv -Tag 'f9a'
[void](New-CTGoal -Env $e9a -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-f9a'))
Set-CTBlocked -Env $e9a -TaskId 'ghwc-task-f9a' -Sha $script:SHA_A
New-CTWait -Env $e9a -TaskId 'ghwc-task-f9a' -Sha $script:SHA_A
[void](New-CTCkpt -Env $e9a -GoalId 'ghwc-goal-1')
$fx9a = Write-CTFixture -Env $e9a -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$w9a = Invoke-CTWake -Env $e9a -Fixture $fx9a -Evt 'evt-ghwc-f9a'
$nx9a = Get-CTField $w9a 'next_action' $null
Assert-That ($null -ne $nx9a) 'f9a setup: next_action present'
$script:probeCalls9a = 0
$probe9a = { param($na) $script:probeCalls9a++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$h9a = Invoke-GHWakeControllerHandoff -NextAction $nx9a -WaitsDir $e9a.waitsDir -TasksDir $e9a.tasksDir -GoalStoreDir $e9a.goalDir -CheckpointDir $e9a.ckptDir -FlagsPath $e9a.flagsPath -NowUtc $script:NOW -HandoffStateDir $e9a.ckptDir -ReceiptDir $e9a.receiptDir -ObjectiveStepProbe $probe9a
$h9aMarker = [string](Get-CTField $h9a 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($h9aMarker)) -and (Test-Path -LiteralPath $h9aMarker -PathType Leaf)) 'f9a setup: marker claimed'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($h9aMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'f9a setup: marker status claimed before settle'
$h9aDoc = ConvertFrom-Json ([IO.File]::ReadAllText($h9aMarker, [Text.Encoding]::UTF8))
$h9aIdem = ([string](Get-CTField $h9aDoc 'idempotency_key' '')).Trim().ToLowerInvariant()
$rc9aRoot = Get-OrchestrationDispatchReceiptDir -ReceiptDir $e9a.receiptDir -RepoRoot ''
$rc9aState = Resolve-NDGoalReceiptDir -RootDir $rc9aRoot -GoalId 'ghwc-goal-1'
$rc9aDir = [string](Get-CTField $rc9aState 'dir' '')
Assert-That (-not [string]::IsNullOrWhiteSpace($rc9aDir)) 'f9a setup: receipt dir resolved'
$rc9aPath = Join-Path $rc9aDir ($h9aIdem + '.json')
Assert-That (Test-Path -LiteralPath $rc9aPath -PathType Leaf) 'f9a setup: prepared receipt present'
$rc9aDoc = ConvertFrom-Json ([IO.File]::ReadAllText($rc9aPath, [Text.Encoding]::UTF8))
$rc9aGoal = ([string](Get-CTField $rc9aDoc 'goal_id' ''))
Assert-That ($rc9aGoal -ceq 'ghwc-goal-1') 'f9a setup: receipt goal matches marker goal'
$rc9aDoc.goal_id = 'ghwc-goal-9'
[IO.File]::WriteAllText($rc9aPath, (ConvertTo-Json -InputObject $rc9aDoc -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
$s9aDiv = Set-GHWakeDispatchSettlement -MarkerPath $h9aMarker -SessionId 'sess-f9a-1' -ResultOk $true -ResultSummary 'receipt goal divergent' -ReceiptDir $e9a.receiptDir -GoalStoreDir $e9a.goalDir -TasksDir $e9a.tasksDir -FlagsPath $e9a.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9a'
Assert-That ((-not [bool](Get-CTField $s9aDiv 'dispatched' $true)) -and (-not [bool](Get-CTField $s9aDiv 'executed' $true)) -and ([string](Get-CTField $s9aDiv 'reason' '') -ceq 'settle-identity-diverged')) 'f9a divergent receipt goal: fail-closed settle-identity-diverged'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($h9aMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'f9a divergent receipt goal: marker stays claimed'
$rc9aDoc2 = ConvertFrom-Json ([IO.File]::ReadAllText($rc9aPath, [Text.Encoding]::UTF8))
$rc9aDoc2.goal_id = ''
[IO.File]::WriteAllText($rc9aPath, (ConvertTo-Json -InputObject $rc9aDoc2 -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
$s9aAbs = Set-GHWakeDispatchSettlement -MarkerPath $h9aMarker -SessionId 'sess-f9a-1' -ResultOk $true -ResultSummary 'receipt goal absent' -ReceiptDir $e9a.receiptDir -GoalStoreDir $e9a.goalDir -TasksDir $e9a.tasksDir -FlagsPath $e9a.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9a'
Assert-That ((-not [bool](Get-CTField $s9aAbs 'dispatched' $true)) -and (-not [bool](Get-CTField $s9aAbs 'executed' $true)) -and ([string](Get-CTField $s9aAbs 'reason' '') -ceq 'settle-identity-diverged')) 'f9a absent receipt goal: fail-closed settle-identity-diverged'
Assert-That ([string](Get-CTField (ConvertFrom-Json ([IO.File]::ReadAllText($h9aMarker, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'f9a absent receipt goal: marker stays claimed'
$rc9aDoc3 = ConvertFrom-Json ([IO.File]::ReadAllText($rc9aPath, [Text.Encoding]::UTF8))
$rc9aDoc3.goal_id = 'ghwc-goal-1'
[IO.File]::WriteAllText($rc9aPath, (ConvertTo-Json -InputObject $rc9aDoc3 -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
$s9aOk = Set-GHWakeDispatchSettlement -MarkerPath $h9aMarker -SessionId 'sess-f9a-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e9a.receiptDir -GoalStoreDir $e9a.goalDir -TasksDir $e9a.tasksDir -FlagsPath $e9a.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9a'
Assert-That (([bool](Get-CTField $s9aOk 'dispatched' $false)) -and ([string](Get-CTField $s9aOk 'reason' '') -ceq 'planner-settled')) 'f9a restored: legitimate settle still planner-settled, refusals mutated nothing'
# --- MEDIUM-6D-DISP-F9: upfront gate on the claimed path (b): divergent
# --- wait_dedup_key with marker claimed is fail-closed
# --- settle-identity-diverged (recomputed key breaks); marker stays
# --- claimed and a later legitimate settle still completes.
$e9b = New-CTEnv -Tag 'f9b'
[void](New-CTGoal -Env $e9b -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-f9b'))
Set-CTBlocked -Env $e9b -TaskId 'ghwc-task-f9b' -Sha $script:SHA_A
New-CTWait -Env $e9b -TaskId 'ghwc-task-f9b' -Sha $script:SHA_A
[void](New-CTCkpt -Env $e9b -GoalId 'ghwc-goal-1')
$fx9b = Write-CTFixture -Env $e9b -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$w9b = Invoke-CTWake -Env $e9b -Fixture $fx9b -Evt 'evt-ghwc-f9b'
$nx9b = Get-CTField $w9b 'next_action' $null
Assert-That ($null -ne $nx9b) 'f9b setup: next_action present'
$script:probeCalls9b = 0
$probe9b = { param($na) $script:probeCalls9b++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$h9b = Invoke-GHWakeControllerHandoff -NextAction $nx9b -WaitsDir $e9b.waitsDir -TasksDir $e9b.tasksDir -GoalStoreDir $e9b.goalDir -CheckpointDir $e9b.ckptDir -FlagsPath $e9b.flagsPath -NowUtc $script:NOW -HandoffStateDir $e9b.ckptDir -ReceiptDir $e9b.receiptDir -ObjectiveStepProbe $probe9b
$h9bMarker = [string](Get-CTField $h9b 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($h9bMarker)) -and (Test-Path -LiteralPath $h9bMarker -PathType Leaf)) 'f9b setup: marker claimed'
$h9bDoc = ConvertFrom-Json ([IO.File]::ReadAllText($h9bMarker, [Text.Encoding]::UTF8))
$orig9bDdk = ([string](Get-CTField $h9bDoc 'wait_dedup_key' ''))
$tam9b = ConvertFrom-Json ([IO.File]::ReadAllText($h9bMarker, [Text.Encoding]::UTF8))
$tam9b.wait_dedup_key = 'ddk-tampered-f9b'
[IO.File]::WriteAllText($h9bMarker, (ConvertTo-Json -InputObject $tam9b -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s9bDdk = Set-GHWakeDispatchSettlement -MarkerPath $h9bMarker -SessionId 'sess-f9b-1' -ResultOk $true -ResultSummary 'claimed replay divergent ddk' -ReceiptDir $e9b.receiptDir -GoalStoreDir $e9b.goalDir -TasksDir $e9b.tasksDir -FlagsPath $e9b.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9b'
Assert-That ((-not [bool](Get-CTField $s9bDdk 'dispatched' $true)) -and (-not [bool](Get-CTField $s9bDdk 'executed' $true)) -and ([string](Get-CTField $s9bDdk 'reason' '') -ceq 'settle-identity-diverged')) 'f9b divergent ddk on claimed: fail-closed settle-identity-diverged'
$after9b = ConvertFrom-Json ([IO.File]::ReadAllText($h9bMarker, [Text.Encoding]::UTF8))
Assert-That ((([string](Get-CTField $after9b 'status' '') -ceq 'claimed') -and ([string](Get-CTField $after9b 'wait_dedup_key' '') -ceq 'ddk-tampered-f9b'))) 'f9b divergent ddk on claimed: marker untouched on refusal'
$rst9b = ConvertFrom-Json ([IO.File]::ReadAllText($h9bMarker, [Text.Encoding]::UTF8))
$rst9b.wait_dedup_key = $orig9bDdk
[IO.File]::WriteAllText($h9bMarker, (ConvertTo-Json -InputObject $rst9b -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s9bOk = Set-GHWakeDispatchSettlement -MarkerPath $h9bMarker -SessionId 'sess-f9b-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e9b.receiptDir -GoalStoreDir $e9b.goalDir -TasksDir $e9b.tasksDir -FlagsPath $e9b.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9b'
Assert-That (([bool](Get-CTField $s9bOk 'dispatched' $false)) -and ([string](Get-CTField $s9bOk 'reason' '') -ceq 'planner-settled')) 'f9b restored: legitimate settle still planner-settled, refusal mutated nothing'
# --- MEDIUM-6D-DISP-F9: upfront gate on the claimed path (c): divergent
# --- event_id with marker claimed is fail-closed
# --- settle-identity-diverged (recomputed key breaks plus shape);
# --- marker stays claimed and a later legitimate settle still completes.
$e9c = New-CTEnv -Tag 'f9c'
[void](New-CTGoal -Env $e9c -GoalId 'ghwc-goal-1' -Tasks @('ghwc-task-f9c'))
Set-CTBlocked -Env $e9c -TaskId 'ghwc-task-f9c' -Sha $script:SHA_A
New-CTWait -Env $e9c -TaskId 'ghwc-task-f9c' -Sha $script:SHA_A
[void](New-CTCkpt -Env $e9c -GoalId 'ghwc-goal-1')
$fx9c = Write-CTFixture -Env $e9c -Raw (New-CTRaw -Nodes (New-CTGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$w9c = Invoke-CTWake -Env $e9c -Fixture $fx9c -Evt 'evt-ghwc-f9c'
$nx9c = Get-CTField $w9c 'next_action' $null
Assert-That ($null -ne $nx9c) 'f9c setup: next_action present'
$script:probeCalls9c = 0
$probe9c = { param($na) $script:probeCalls9c++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$h9c = Invoke-GHWakeControllerHandoff -NextAction $nx9c -WaitsDir $e9c.waitsDir -TasksDir $e9c.tasksDir -GoalStoreDir $e9c.goalDir -CheckpointDir $e9c.ckptDir -FlagsPath $e9c.flagsPath -NowUtc $script:NOW -HandoffStateDir $e9c.ckptDir -ReceiptDir $e9c.receiptDir -ObjectiveStepProbe $probe9c
$h9cMarker = [string](Get-CTField $h9c 'marker_path' '')
Assert-That ((-not [string]::IsNullOrWhiteSpace($h9cMarker)) -and (Test-Path -LiteralPath $h9cMarker -PathType Leaf)) 'f9c setup: marker claimed'
$h9cDoc = ConvertFrom-Json ([IO.File]::ReadAllText($h9cMarker, [Text.Encoding]::UTF8))
$orig9cEvt = ([string](Get-CTField $h9cDoc 'event_id' ''))
$tam9c = ConvertFrom-Json ([IO.File]::ReadAllText($h9cMarker, [Text.Encoding]::UTF8))
$tam9c.event_id = 'evt-tampered-f9c'
[IO.File]::WriteAllText($h9cMarker, (ConvertTo-Json -InputObject $tam9c -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s9cEvt = Set-GHWakeDispatchSettlement -MarkerPath $h9cMarker -SessionId 'sess-f9c-1' -ResultOk $true -ResultSummary 'claimed replay divergent evt' -ReceiptDir $e9c.receiptDir -GoalStoreDir $e9c.goalDir -TasksDir $e9c.tasksDir -FlagsPath $e9c.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9c'
Assert-That ((-not [bool](Get-CTField $s9cEvt 'dispatched' $true)) -and (-not [bool](Get-CTField $s9cEvt 'executed' $true)) -and ([string](Get-CTField $s9cEvt 'reason' '') -ceq 'settle-identity-diverged')) 'f9c divergent evt on claimed: fail-closed settle-identity-diverged'
$after9c = ConvertFrom-Json ([IO.File]::ReadAllText($h9cMarker, [Text.Encoding]::UTF8))
Assert-That ((([string](Get-CTField $after9c 'status' '') -ceq 'claimed') -and ([string](Get-CTField $after9c 'event_id' '') -ceq 'evt-tampered-f9c'))) 'f9c divergent evt on claimed: marker untouched on refusal'
$rst9c = ConvertFrom-Json ([IO.File]::ReadAllText($h9cMarker, [Text.Encoding]::UTF8))
$rst9c.event_id = $orig9cEvt
[IO.File]::WriteAllText($h9cMarker, (ConvertTo-Json -InputObject $rst9c -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$s9cOk = Set-GHWakeDispatchSettlement -MarkerPath $h9cMarker -SessionId 'sess-f9c-1' -ResultOk $true -ResultSummary 'planner ran coder via subagent' -ReceiptDir $e9c.receiptDir -GoalStoreDir $e9c.goalDir -TasksDir $e9c.tasksDir -FlagsPath $e9c.flagsPath -ExpectedGoalId 'ghwc-goal-1' -ExpectedTaskId 'ghwc-task-f9c'
Assert-That (([bool](Get-CTField $s9cOk 'dispatched' $false)) -and ([string](Get-CTField $s9cOk 'reason' '') -ceq 'planner-settled')) 'f9c restored: legitimate settle still planner-settled, refusal mutated nothing'
Write-Output ('github-wake-controller tests PASS: ' + [string]$script:passed)
