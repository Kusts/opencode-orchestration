# github-wake-controller.tests.ps1 -- Etapa 6D GH-WAKE controller handoff.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only (no live network, no
# gh required). Covers: dot-source exposure of the handoff surface,
# single-shot driver shape (no daemon/loop/sleep/spawn), extended
# next_action envelope (generation, task_id, checkpoint_id, goal_id,
# wait_dedup_key, lease_owner/lease_expires_utc, event_id, kernel_state,
# idempotency_key derived via hash, announce preserved), valid handoff
# dispatch via mock controller probe, binding-diverged refusal, missing
# checkpoint refusal, expired lease refusal, duplicate idempotency without
# replay, and IMPLEMENTING-without-handoff never counting as execution.
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
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; flagsPath = $flagsPath }
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
# --- valid handoff dispatches via mock controller probe, no kernel mutation.
$script:probeCalls = 0
$probe = { param($na) $script:probeCalls++; return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$revBefore = [long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision
$h = Invoke-GHWakeControllerHandoff -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ObjectiveStepProbe $probe
Assert-That (([bool](Get-CTField $h 'dispatched' $false)) -and ([string](Get-CTField $h 'decision' '') -ceq 'dispatched')) 'valid handoff: dispatched'
Assert-That (([string](Get-CTField $h 'reason' '') -ceq 'controller-dispatched') -and ([bool](Get-CTField $h 'executed' $false))) 'valid handoff: executed with typed reason'
Assert-That ([int]$script:probeCalls -eq 1) 'valid handoff: controller invoked exactly once'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision -eq $revBefore) 'valid handoff: kernel untouched (no replay of transition)'
Assert-That ((-not [bool](Get-CTField $h 'grants_authority' $true)) -and (-not [bool](Get-CTField $h 'done_approved' $true)) -and (-not [bool](Get-CTField $h 'merge_authority' $true))) 'valid handoff: authority pins stay false'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).state -cne 'DONE') 'valid handoff: task never auto-completed'
# --- duplicate re-invocation: DUPLICATE_NOOP, no replay, probe untouched.
$h2 = Invoke-GHWakeControllerHandoff -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ObjectiveStepProbe $probe
Assert-That ((-not [bool](Get-CTField $h2 'dispatched' $true)) -and ([string](Get-CTField $h2 'reason' '') -ceq 'duplicate-noop')) 'duplicate handoff: DUPLICATE_NOOP without replay'
Assert-That ([int]$script:probeCalls -eq 1) 'duplicate handoff: controller not re-invoked'
Assert-That (-not [bool](Get-CTField $h2 'executed' $true)) 'duplicate handoff: executed false'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghwc-task-a' -TasksDir $e.tasksDir -RepoRoot $e.root).revision -eq $revBefore) 'duplicate handoff: kernel still untouched'
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
$hb = Invoke-GHWakeControllerHandoff -NextAction $nxb -WaitsDir $eb.waitsDir -TasksDir $eb.tasksDir -GoalStoreDir $eb.goalDir -CheckpointDir $eb.ckptDir -FlagsPath $eb.flagsPath -NowUtc $script:NOW -HandoffStateDir $eb.ckptDir -ObjectiveStepProbe $probeB
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
$hl = Invoke-GHWakeControllerHandoff -NextAction $nxl -WaitsDir $el.waitsDir -TasksDir $el.tasksDir -GoalStoreDir $el.goalDir -CheckpointDir $el.ckptDir -FlagsPath $el.flagsPath -NowUtc $script:NOW -HandoffStateDir $el.ckptDir -ObjectiveStepProbe $probeL
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
$ht1 = Invoke-GHWakeControllerHandoff -NextAction $nxBadTask -WaitsDir $et.waitsDir -TasksDir $et.tasksDir -GoalStoreDir $et.goalDir -CheckpointDir $et.ckptDir -FlagsPath $et.flagsPath -NowUtc $script:NOW -HandoffStateDir $et.ckptDir -ObjectiveStepProbe $probeT
Assert-That ((-not [bool](Get-CTField $ht1 'dispatched' $true)) -and ([string](Get-CTField $ht1 'reason' '') -ceq 'handoff-task-mismatch')) 'tampered task: refused handoff-task-mismatch'
Assert-That ([int]$script:probeCallsT -eq 0) 'tampered task: controller never invoked'
Assert-That (-not [bool](Get-CTField $ht1 'executed' $true)) 'tampered task: executed false'
$nxBadGoal = (ConvertFrom-Json (ConvertTo-Json -InputObject $nxt -Depth 20))
$nxBadGoal.goal_id = 'ghwc-goal-evil'
$ht2 = Invoke-GHWakeControllerHandoff -NextAction $nxBadGoal -WaitsDir $et.waitsDir -TasksDir $et.tasksDir -GoalStoreDir $et.goalDir -CheckpointDir $et.ckptDir -FlagsPath $et.flagsPath -NowUtc $script:NOW -HandoffStateDir $et.ckptDir -ObjectiveStepProbe $probeT
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
$ha1 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ObjectiveStepProbe $probeA
Assert-That (([bool](Get-CTField $ha1 'dispatched' $false)) -and ([string](Get-CTField $ha1 'reason' '') -ceq 'controller-dispatched')) 'atomic: first dispatch succeeds'
$ha2 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ObjectiveStepProbe $probeA
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
$ha3 = Invoke-GHWakeControllerHandoff -NextAction $nxa -WaitsDir $ea.waitsDir -TasksDir $ea.tasksDir -GoalStoreDir $ea.goalDir -CheckpointDir $ea.ckptDir -FlagsPath $ea.flagsPath -NowUtc $script:NOW -HandoffStateDir $ea.ckptDir -ObjectiveStepProbe $probeA
Assert-That ((-not [bool](Get-CTField $ha3 'dispatched' $true)) -and ([string](Get-CTField $ha3 'reason' '') -ceq 'duplicate-noop')) 'probeOnly replay with applied event: HOLD duplicate-noop'
Assert-That ([int]$script:probeCallsA -eq 1) 'probeOnly replay with applied event: no second probe'
# --- driver single-shot end-to-end (real read-only controller path, no probe).
$nxFile = Join-Path $e.root 'next-action.json'
[IO.File]::WriteAllText($nxFile, (ConvertTo-Json -InputObject $nx -Depth 10), (New-Object Text.UTF8Encoding $false))
$drvArgs = @('-NoProfile', '-File', $script:ctrlCli, '-NextActionFile', $nxFile, '-WaitsDir', $e.waitsDir, '-TasksDir', $e.tasksDir, '-GoalStoreDir', $e.goalDir, '-CheckpointDir', $e.ckptDir, '-FlagsPath', $e.flagsPath, '-NowUtc', $script:NOW)
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
Write-Output ('github-wake-controller tests PASS: ' + [string]$script:passed)
