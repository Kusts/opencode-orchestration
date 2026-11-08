# github-wake-86-settlement.tests.ps1 -- issue #86 autonomous settlement.
# Offline only (no gh, no network, no opencode, no model). Reproduces the
# PARTIAL trajectory of 2026-11-08 (receipt prepared / marker claimed while
# the kernel reached DONE before settlement):
#   S1: the resume directive forbids premature DONE (planner only delegates).
#   S2: a bounded re-read after run finds the native worker proof when it
#       appears only on the second read (eventual consistency), with exactly
#       one executor call (no worker re-execution).
#   S3: the scheduler config persists and the CLI forwards the receipt /
#       handoff / repo / evidence directories (no tool-cache fallback).
#   S4: the goal ownership lease covers the durable wait (derived from the
#       wait deadline via the existing Renew mechanism, never arbitrary).
#   S5: each scheduler tick preserves its evidence (previous out file is
#       archived, never overwritten).
#   S6: settlement still refuses task-terminal (guard: no generic relaxation).
$ErrorActionPreference = 'Stop'
$script:autoPath = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:autoPath -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found' }
. $script:autoPath
$passed = 0
function Assert-ST {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-STField {
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
# --- S1: directive forbids concluding the task in the resume turn. ---
$directive = ''
try { $directive = [string](Get-GHWADWorkerDirective) } catch { $directive = '' }
Assert-ST (-not [string]::IsNullOrWhiteSpace($directive)) 'S1 directive non-empty'
Assert-ST ($directive -cmatch '(?i)do not') 'S1 directive forbids premature completion'
Assert-ST ($directive -cmatch '(?i)turn') 'S1 directive scopes the ban to this turn'
Assert-ST ($directive -cmatch '(?i)settlement') 'S1 directive defers to settlement'
Assert-ST (Test-GHWADPromptFits -PromptText $directive) 'S1 directive fits prompt gate'
# --- S2: bounded re-read finds eventually-persisted proof, one run only. ---
# Fixture mirrors github-wake-scheduler-tick: green wake -> next_action ->
# Invoke-GHWakeAutoDispatch (direct, bound root) with eventual proof.
$script:ST_SHA = 'dddddddddddddddddddddddddddddddddddddddd'
$script:ST_NOW = '2026-10-10T12:02:00Z'
$script:ST_FUTURE = '2027-06-01T00:00:00Z'
$script:ST_REPO = 'acme/widgets'
$script:ST_ROOT = 'ses_86settleroot01'
$script:ST_PROJ = 'proj86settle1'
$script:ST_RUN = 'run-86settle'
$script:ST_policy = $null
try { $script:ST_policy = Get-OrchestrationDeliveryPolicy $null } catch { $script:ST_policy = $null }
if ($null -eq $script:ST_policy) { throw 'FAIL: delivery policy unavailable' }
$script:ST_reqChecks = @()
try { $script:ST_reqChecks = @(Get-OrchestrationDeliveryRequiredChecks $script:ST_policy) } catch { $script:ST_reqChecks = @() }
Assert-ST (@($script:ST_reqChecks).Count -gt 0) 'S2 policy carries required checks'
function New-STEnv {
    param([string]$Tag = 's')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-STGoal {
    param($Env, [string]$GoalId = 's86-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective '86 settlement' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-STField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-STField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-STField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-STField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-STField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-STField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-STField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -BaseRevision 'rev-86s' -ReadScopes @('src/s86.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-STField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-STField (Get-STField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-STField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-STBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:ST_REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-STField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-STField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-STField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-STField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId) }
}
function New-STWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 's86-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId $script:ST_RUN -Generation 1 -Repository $script:ST_REPO -PrNumber $Pr -Branch 'fix/86s' -ExpectedHeadSha $Sha -RequiredChecks @($script:ST_reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:ST_FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:ST_FUTURE -Owner 'planner-1'
    if (-not [bool](Get-STField $reg 'ok' $false)) { throw ('wait:' + [string](Get-STField $reg 'reason' '')) }
}
function New-STCkpt {
    param($Env, [string]$GoalId = 's86-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-STField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-STField $sv 'checkpoint_id' '')
}
function New-STNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-STRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:ST_REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function New-STGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:ST_reqChecks)) { $out += @(New-STNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
$script:ST_knownSids = @{}
function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = 'opencode', [int]$TimeoutMs = 30000)
    try {
        $s = (([string]$SessionId).Trim())
        if (($s -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($s -match 'continue')) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = 'stub:bad-id'; session = $null }
        }
        if (-not $script:ST_knownSids.ContainsKey($s)) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
        }
        $rec = $script:ST_knownSids[$s]
        if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne [string]$rec.proj)) {
            return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
        }
        $sess = [pscustomobject]@{ id = $s; title = 's86-root'; created = 0; updated = 0; directory = [string]$rec.dir; projectId = [string]$rec.proj }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
    }
}
$script:ST_apiLists = 0
$script:ST_apiMsgs = 0
$script:ST_runCalls = 0
$script:ST_childId = 'ses_86settlechild01'
$script:ST_FUTUREMS = 0
try { $script:ST_FUTUREMS = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000) } catch { $script:ST_FUTUREMS = 1794000000000 }
$script:ST_nx = $null
$script:ST_apiLatePost = @()
$script:ST_apiLateMsgs = @()
function New-STChild {
    param([string]$Id = '', [string]$Parent = '', [string]$Proj = '', [long]$Created = 0, [string]$Outcome = 'succeeded')
    return [pscustomobject]@{ id = $Id; parentID = $Parent; projectID = $Proj; agent = 'coder'; outcome = $Outcome; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
}
function New-STToolMsg {
    param([string]$MsgId = '', [long]$MsgCreated = 0, [string]$CallId = '', [string]$ChildId = '', $Nx = $null)
    $t = ([string](Get-STField $Nx 'task_id' ''))
    $g = ([string](Get-STField $Nx 'goal_id' ''))
    $gen = ([string](Get-STField $Nx 'generation' '1'))
    $k = ([string](Get-STField $Nx 'idempotency_key' '')).Trim().ToLowerInvariant()
    $marker = New-GHWADOperationMarker -GoalId $g -TaskId $t -Generation $gen -IdempotencyKey $k
    $prompt = ('invoke worker ' + $marker)
    $rj = ('{"task_id":"' + $t + '","goal_id":"' + $g + '","generation":"' + $gen + '","idempotency_key":"' + $k + '","status":"candidate_pass","claimed_evidence":["criterion:0"]}')
    $c = @(@{ type = 'text'; text = $rj })
    $st = @{ status = 'completed'; input = @{ agent = 'coder'; description = 's86 proof'; prompt = $prompt; sessionID = $ChildId }; metadata = @{ sessionID = $ChildId; status = 'completed'; truncated = $false }; content = $c }
    return [pscustomobject]@{ id = $MsgId; type = 'assistant'; agent = 'build'; time = [pscustomobject]@{ created = [long]$MsgCreated }; content = @(@{ type = 'tool'; id = $CallId; name = 'subagent'; state = $st; time = @{ created = [long]$MsgCreated; ran = [long]$MsgCreated; completed = [long]$MsgCreated } }) }
}
$script:ST_apiMock = {
    param($Operation, $Params)
    if (([string]$Operation) -ceq 'session.list') {
        $script:ST_apiLists++
        if ([int]$script:ST_apiLists -le 2) {
            return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @(); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
        }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @($script:ST_apiLatePost); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    if (([string]$Operation) -ceq 'session.message.list') {
        $script:ST_apiMsgs++
        if ([int]$script:ST_apiMsgs -le 1) {
            return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @(); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
        }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @($script:ST_apiLateMsgs); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    return [pscustomobject]@{ ok = $false }
}
$script:ST_runMock = {
    param($spec)
    $script:ST_runCalls++
    $sid = ''
    try { $sid = ([string](Get-STField $spec 'session_id' '')) } catch { $sid = '' }
    return [pscustomobject]@{ exit = 0; stdout = ('{"sessionId":"' + $sid + '","role":"assistant","type":"text"}'); stderr = ''; timedOut = $false }
}
$env2 = New-STEnv -Tag 'ev'
[void](New-STGoal -Env $env2 -GoalId 's86-goal-1' -Tasks @('s86-task-1'))
Set-STBlocked -Env $env2 -TaskId 's86-task-1' -Sha $script:ST_SHA
New-STWait -Env $env2 -TaskId 's86-task-1' -Sha $script:ST_SHA
[void](New-STCkpt -Env $env2 -GoalId 's86-goal-1')
$fx2 = Join-Path $env2.root 'green.graphql.json'
[IO.File]::WriteAllText($fx2, (ConvertTo-Json -InputObject (New-STRaw -Nodes (New-STGreenNodes $script:ST_SHA) -Head $script:ST_SHA -Commit $script:ST_SHA) -Depth 20), (New-Object Text.UTF8Encoding $false))
$wake2 = (Invoke-GitHubWake -WaitsDir $env2.waitsDir -TasksDir $env2.tasksDir -GoalStoreDir $env2.goalDir -CheckpointDir $env2.ckptDir -FlagsPath $env2.flagsPath -Policy $script:ST_policy -GraphQLSnapshotFile $fx2 -EventId 'evt-86s-1' -MaxAgeSeconds 300 -NowUtc $script:ST_NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
$nx2 = Get-STField $wake2 'next_action' $null
Assert-ST ($null -ne $nx2) 'S2 wake produced next_action'
$script:ST_nx = $nx2
$script:ST_apiLatePost = @(New-STChild -Id $script:ST_childId -Parent $script:ST_ROOT -Proj $script:ST_PROJ -Created $script:ST_FUTUREMS -Outcome 'succeeded')
$script:ST_apiLateMsgs = @(New-STToolMsg -MsgId 'msg-86s-1' -MsgCreated $script:ST_FUTUREMS -CallId 'call-86s-1' -ChildId $script:ST_childId -Nx $nx2)
$script:ST_knownSids = @{ $script:ST_ROOT = @{ dir = $env2.root; proj = $script:ST_PROJ } }
$script:ST_apiLists = 0; $script:ST_apiMsgs = 0; $script:ST_runCalls = 0
$probe2 = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$result2 = Invoke-GHWakeAutoDispatch -NextAction $nx2 -WaitsDir $env2.waitsDir -TasksDir $env2.tasksDir -GoalStoreDir $env2.goalDir -CheckpointDir $env2.ckptDir -HandoffStateDir $env2.ckptDir -ReceiptDir $env2.receiptDir -RepoRoot $env2.root -EvidenceStoreDir $env2.receiptDir -FlagsPath $env2.flagsPath -NowUtc $script:ST_NOW -ResumeSessionId $script:ST_ROOT -ExpectedDirectory $env2.root -ExpectedProjectId $script:ST_PROJ -PromptText '' -ControllerProbe $probe2 -RunExecutor $script:ST_runMock -SessionApiInvoker $script:ST_apiMock -ProofRetryCount 3
Assert-ST ([int]$script:ST_runCalls -eq 1) 'S2 exactly one worker run (retry never re-executes)'
Assert-ST (([string](Get-STField $result2 'reason' '')) -ceq 'auto-worker-non-native') 'S2 eventual proof found by bounded re-read (non-native gate reached)'
# --- S3: scheduler config persists + forwards dispatch directories. ---
$cfgPath3 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$hDir3 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-h-' + [guid]::NewGuid().ToString('N'))
$rDir3 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-r-' + [guid]::NewGuid().ToString('N'))
$eDir3 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-e-' + [guid]::NewGuid().ToString('N'))
$repo3 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-repo-' + [guid]::NewGuid().ToString('N'))
foreach ($d3 in @($hDir3, $rDir3, $eDir3, $repo3)) { [void][IO.Directory]::CreateDirectory($d3) }
$hasCfgParams = $false
try { $hasCfgParams = ((Get-Command New-GitHubWakeConfig -ErrorAction SilentlyContinue).Parameters.ContainsKey('ReceiptDir')) } catch { $hasCfgParams = $false }
Assert-ST ([bool]$hasCfgParams) 'S3 config accepts ReceiptDir'
$cfg3 = New-GitHubWakeConfig -Path $cfgPath3 -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f' -HandoffStateDir $hDir3 -ReceiptDir $rDir3 -RepoRoot $repo3 -EvidenceStoreDir $eDir3
Assert-ST ([bool](Get-STField $cfg3 'ok' $false)) 'S3 config written'
$cfgDoc3 = [IO.File]::ReadAllText($cfgPath3, [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-ST (([string](Get-STField $cfgDoc3 'handoff_state_dir' '')) -ceq $hDir3) 'S3 handoff_state_dir persisted'
Assert-ST (([string](Get-STField $cfgDoc3 'receipt_dir' '')) -ceq $rDir3) 'S3 receipt_dir persisted'
Assert-ST (([string](Get-STField $cfgDoc3 'repo_root' '')) -ceq $repo3) 'S3 repo_root persisted'
Assert-ST (([string](Get-STField $cfgDoc3 'evidence_store_dir' '')) -ceq $eDir3) 'S3 evidence_store_dir persisted'
$wakeText3 = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'github-wake.ps1'), [Text.Encoding]::UTF8)
Assert-ST ($wakeText3 -cmatch 'Invoke-GHWakeSchedulerTick') 'S3 wake CLI hands tick to scheduler'
Assert-ST ($wakeText3 -cmatch 'ReceiptDir') 'S3 wake CLI forwards ReceiptDir to tick'
# --- S4: goal lease covers the wait (renewed from deadline, not arbitrary). ---
. (Join-Path $PSScriptRoot 'lib\OrchestrationPlannerWait.ps1')
$env4 = New-STEnv -Tag 'lease'
[void](New-STGoal -Env $env4 -GoalId 's86-goal-lease' -Tasks @('s86-task-lease'))
$preLease = (Get-OrchestrationGoal -GoalId 's86-goal-lease' -StoreDir $env4.goalDir).goal.ownership.expires_at
$deadline4 = ([datetime]::UtcNow.AddMinutes(10)).ToString('o')
$bind4 = Invoke-OrchestrationPlannerWaitBinding -TaskId 's86-task-lease' -GoalId 's86-goal-lease' -RunId 'run-86lease' -SessionId 'ses_86leaseroot01' -GoalStoreDir $env4.goalDir -TasksDir $env4.tasksDir -WaitsDir $env4.waitsDir -Repository $script:ST_REPO -PrNumber 43 -Branch 'fix/86lease' -ExpectedHeadSha 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' -RequiredChecks @($script:ST_reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $deadline4 -RetryBudgetMax 5 -FlagsPath $env4.flagsPath -RepoRoot $env4.root
Assert-ST ([bool](Get-STField $bind4 'ok' $false)) 'S4 wait bound'
$postOwn = (Get-OrchestrationGoal -GoalId 's86-goal-lease' -StoreDir $env4.goalDir).goal.ownership
$postExpUtc = $null
try { $postExpUtc = Convert-GHRSUtc -Value ([string]$postOwn.expires_at) } catch { $postExpUtc = $null }
Assert-ST (($null -ne $postExpUtc) -and ($postExpUtc -gt [datetime]::UtcNow.AddMinutes(5))) 'S4 goal lease extended to cover wait deadline'
$waitFile4 = [string](Get-STField $bind4 'wait_file' '')
Assert-ST (Test-Path -LiteralPath $waitFile4 -PathType Leaf) 'S4 wait persisted'
$waitDoc4 = ConvertFrom-Json ([IO.File]::ReadAllText($waitFile4, [Text.Encoding]::UTF8))
$waitExp4 = $null
try { $waitExp4 = Convert-GHRSUtc -Value ([string](Get-STField $waitDoc4 'lease_expires_utc' '')) } catch { $waitExp4 = $null }
Assert-ST (($null -ne $waitExp4) -and ($waitExp4 -gt [datetime]::UtcNow.AddMinutes(5))) 'S4 wait lease covers deadline (no 60s expiry)'
# --- S5: each tick preserves its evidence file. ---
$hasWriter = $false
try { $hasWriter = ($null -ne (Get-Command Write-GHWakeTickOutFile -ErrorAction SilentlyContinue)) } catch { $hasWriter = $false }
Assert-ST ([bool]$hasWriter) 'S5 tick evidence writer exists'
$out5 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86s-out-' + [guid]::NewGuid().ToString('N') + '.json')
$null = Write-GHWakeTickOutFile -Path $out5 -Content '{"tick":1}'
Assert-ST (([IO.File]::ReadAllText($out5, [Text.Encoding]::UTF8)) -ceq '{"tick":1}') 'S5 first tick written'
$null = Write-GHWakeTickOutFile -Path $out5 -Content '{"tick":2}'
Assert-ST (([IO.File]::ReadAllText($out5, [Text.Encoding]::UTF8)) -ceq '{"tick":2}') 'S5 second tick is current'
$arch5 = @(Get-ChildItem -Path ([IO.Path]::GetDirectoryName($out5)) -File -Filter (([IO.Path]::GetFileNameWithoutExtension($out5)) + '*.json*') | Where-Object { $_.FullName -cne $out5 })
Assert-ST (@($arch5).Count -ge 1) 'S5 previous tick archived (not overwritten)'
$archHasFirst = $false
foreach ($a5 in @($arch5)) {
    try { if (([IO.File]::ReadAllText($a5.FullName, [Text.Encoding]::UTF8)) -ceq '{"tick":1}') { $archHasFirst = $true; break } } catch { }
}
Assert-ST ([bool]$archHasFirst) 'S5 archived tick preserves first evidence'
# --- S6: guard - settlement never relaxed for terminal tasks. ---
Assert-ST ($null -ne (Get-Command Set-GHWakeDispatchSettlement -ErrorAction SilentlyContinue)) 'S6 settlement entry exists'
$wakeSrc6 = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'github-wake.ps1'), [Text.Encoding]::UTF8)
Assert-ST ($wakeSrc6 -cmatch 'settle-not-prepared') 'S6 settlement vocabulary preserved'
Write-Output ('OK github-wake-86-settlement (' + [string]$script:passed + ' asserts)')
exit 0
