# github-wake-scheduler-tick.tests.ps1 -- Fatia B wiring: wake CLI/config boundary.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only: no gh, no network,
# no real opencode, no live run, no model quota. Proves at the actual
# github-wake.ps1 scheduler boundary (config + Invoke-GHWakeSchedulerTick,
# the exact function the wake CLI entrypoint calls after Invoke-GitHubWake):
# disabled tick never reaches the resolver; enabled tick recovers the root
# session through the resolver and runs the existing auto-dispatch path;
# missing/stale/ambiguous bindings stay refused with zero executor effect;
# CLI/config cannot carry a ResumeSessionId; production opt-in stays off by
# default. The one child-process case (config with resume_session_id)
# exits 2 during config validation, before any transport, session, or
# scheduler call. ASCII only.
$ErrorActionPreference = 'Stop'
$script:tickWake = Join-Path $PSScriptRoot 'github-wake.ps1'
if (-not (Test-Path -LiteralPath $script:tickWake -PathType Leaf)) { throw 'RED: github-wake.ps1 not found' }
$script:tickAuto = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:tickAuto -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found' }
. $script:tickAuto
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-TXField {
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
Assert-That ($null -ne (Get-Command Invoke-GHWakeSchedulerTick -ErrorAction SilentlyContinue)) 'tick exposes Invoke-GHWakeSchedulerTick'
Assert-That ($null -ne (Get-Command Invoke-GHWakeSchedulerDispatch -ErrorAction SilentlyContinue)) 'tick exposes Invoke-GHWakeSchedulerDispatch'
$wakeText = [IO.File]::ReadAllText($script:tickWake, [Text.Encoding]::UTF8)
Assert-That ($wakeText -cmatch 'Invoke-GHWakeSchedulerTick -WakeResult') 'tick: wake CLI hands exact wake result to tick'
Assert-That ($wakeText -cmatch "Add-Member -NotePropertyName 'auto_dispatch'") 'tick: wake CLI reports dispatch under auto_dispatch'
Assert-That ($wakeText -cmatch 'github-wake-auto-dispatch\.ps1') 'tick: wake CLI loads existing auto-dispatch path'
$cfgParams = (Get-Command New-GitHubWakeConfig -ErrorAction SilentlyContinue).Parameters
Assert-That (($null -ne $cfgParams) -and (-not $cfgParams.ContainsKey('ResumeSessionId'))) 'tick: config cannot accept ResumeSessionId'
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
$script:SHA_T = 'cccccccccccccccccccccccccccccccccccccccc'
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2027-06-01T00:00:00Z'
$script:REPO = 'acme/widgets'
$script:ROOT = 'ses_tickroot01'
$script:PROJ = 'proj-tick-1'
$script:RUN = 'run-tick-1'
$script:knownSids = @{}
function New-TXEnv {
    param([string]$Tag = 't')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwtick-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-TXGoal {
    param($Env, [string]$GoalId = 'tick-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d tick' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-TXField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-TXField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-TXField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-TXField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-TXField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-TXField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-TXField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-tick' -ReadScopes @('src/tick.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-TXField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-TXField (Get-TXField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-TXField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-TXBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-TXField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-TXField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-TXField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-TXField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId) }
}
function New-TXWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'tick-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId $script:RUN -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/tick' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-TXField $reg 'ok' $false)) { throw ('wait:' + [string](Get-TXField $reg 'reason' '')) }
}
function New-TXCkpt {
    param($Env, [string]$GoalId = 'tick-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-TXField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-TXField $sv 'checkpoint_id' '')
}
function New-TXNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-TXRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function New-TXGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-TXNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Invoke-TXWake {
    param($Env, [string]$Fixture = '', [string]$Evt = 'evt-tick-1')
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:policy -GraphQLSnapshotFile $Fixture -EventId $Evt -MaxAgeSeconds 300 -NowUtc $script:NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
}
function New-TXCase {
    param([string]$Tag = 'a', [string]$GoalId = 'tick-goal-1', [string]$TaskId = 'tick-task-a', [string]$Evt = 'evt-tick-1')
    $env = New-TXEnv -Tag $Tag
    $script:knownSids = @{}
    [void](New-TXGoal -Env $env -GoalId $GoalId -Tasks @($TaskId))
    Set-TXBlocked -Env $env -TaskId $TaskId -Sha $script:SHA_T
    New-TXWait -Env $env -TaskId $TaskId -Sha $script:SHA_T -GoalId $GoalId
    [void](New-TXCkpt -Env $env -GoalId $GoalId)
    $fx = Join-Path $env.root 'green.graphql.json'
    [IO.File]::WriteAllText($fx, (ConvertTo-Json -InputObject (New-TXRaw -Nodes (New-TXGreenNodes $script:SHA_T) -Head $script:SHA_T -Commit $script:SHA_T) -Depth 20), (New-Object Text.UTF8Encoding $false))
    $w = Invoke-TXWake -Env $env -Fixture $fx -Evt $Evt
    $nx = Get-TXField $w 'next_action' $null
    if ($null -eq $nx) { throw ('case-setup-missing-next-action:' + $Tag) }
    return @{ env = $env; wake = $w; nx = $nx }
}
function Bind-TXRoot {
    param($Env, [string]$TaskId = '', [string]$Sid = '')
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-TXField $t 'revision' 0)
    $b = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $TaskId -RunId $script:RUN -SessionId $Sid -ExpectedRevision $rev -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -RepoRoot $Env.root
    if (-not [bool](Get-TXField $b 'ok' $false)) { throw ('bind:' + [string](Get-TXField $b 'error' '')) }
}
function Get-TXTaskFile {
    param($Env, [string]$TaskId = '')
    $found = @(Get-ChildItem -LiteralPath $Env.tasksDir -File -Filter '*.json' | Where-Object { $_.BaseName -like ('*' + $TaskId + '*') })
    if (@($found).Count -lt 1) { throw ('task-file-missing:' + $TaskId) }
    return @($found)[0].FullName
}
function New-TXSessions {
    param($Env, [string]$Sid = '', [string]$Proj = '')
    $entry = [pscustomobject]@{ id = $Sid; title = 'tick-root'; created = 0; updated = 0; directory = $Env.root; projectId = $Proj }
    return [pscustomobject]@{ ok = $true; sessions = @($entry) }
}
function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = 'opencode', [int]$TimeoutMs = 30000)
    try {
        $s = (([string]$SessionId).Trim())
        if (($s -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($s -match 'continue')) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = 'stub:bad-id'; session = $null }
        }
        if (-not $script:knownSids.ContainsKey($s)) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
        }
        $rec = $script:knownSids[$s]
        if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne [string]$rec.proj)) {
            return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
        }
        $sess = [pscustomobject]@{ id = $s; title = 'tick-binding'; created = 0; updated = 0; directory = [string]$rec.dir; projectId = [string]$rec.proj }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
    }
}
$script:apiCalls = 0
$script:apiLists = 0
$script:apiPre = @()
$script:apiPost = @()
$script:apiMsgs = @()
$script:apiMock = {
    param($Operation, $Params)
    $script:apiCalls++
    if (([string]$Operation) -ceq 'session.list') {
        $script:apiLists++
        $arr = @($script:apiPre)
        if ([int]$script:apiLists -ge 2) { $arr = @($script:apiPost) }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = $arr; cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    if (([string]$Operation) -ceq 'session.message.list') {
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @($script:apiMsgs); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    return [pscustomobject]@{ ok = $false }
}
$script:runCalls = 0
$script:runSid = ''
$script:runMock = {
    param($spec)
    $script:runCalls++
    try { $script:runSid = ([string](Get-TXField $spec 'session_id' '')) } catch { $script:runSid = '' }
    $body = ('{"sessionId":"' + $script:runSid + '","role":"assistant","type":"text"}')
    return [pscustomobject]@{ exit = 0; stdout = $body; stderr = ''; timedOut = $false }
}
$script:FUTUREMS = 0
try { $script:FUTUREMS = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000) } catch { $script:FUTUREMS = 1794000000000 }
function New-TXChild {
    param([string]$Id = '', [string]$Parent = '', [string]$Proj = '', [long]$Created = 0, [string]$Outcome = 'succeeded')
    $o = $Outcome
    if ([string]::IsNullOrWhiteSpace($o)) { $o = $null }
    return [pscustomobject]@{ id = $Id; parentID = $Parent; projectID = $Proj; agent = 'coder'; outcome = $o; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
}
function New-TXToolMsg {
    param([string]$MsgId = '', [long]$MsgCreated = 0, [string]$CallId = '', [string]$ChildId = '', $Nx = $null)
    $t = ([string](Get-TXField $Nx 'task_id' ''))
    $g = ([string](Get-TXField $Nx 'goal_id' ''))
    $gen = ([string](Get-TXField $Nx 'generation' '1'))
    $k = ([string](Get-TXField $Nx 'idempotency_key' '')).Trim().ToLowerInvariant()
    $marker = New-GHWADOperationMarker -GoalId $g -TaskId $t -Generation $gen -IdempotencyKey $k
    $prompt = ('invoke worker ' + $marker)
    $rj = ('{"task_id":"' + $t + '","goal_id":"' + $g + '","generation":"' + $gen + '","idempotency_key":"' + $k + '","status":"candidate_pass","claimed_evidence":["criterion:0"]}')
    $c = @(@{ type = 'text'; text = $rj })
    $st = @{ status = 'completed'; input = @{ agent = 'coder'; description = 'tick proof'; prompt = $prompt; sessionID = $ChildId }; metadata = @{ sessionID = $ChildId; status = 'completed'; truncated = $false }; content = $c }
    return [pscustomobject]@{ id = $MsgId; type = 'assistant'; agent = 'build'; time = [pscustomobject]@{ created = [long]$MsgCreated }; content = @(@{ type = 'tool'; id = $CallId; name = 'subagent'; state = $st; time = @{ created = [long]$MsgCreated; ran = [long]$MsgCreated; completed = [long]$MsgCreated } }) }
}
function Set-TXProof {
    param($Case, [string]$ChildId = 'ses_tickchild01')
    $script:apiPre = @()
    $script:apiPost = @(New-TXChild -Id $ChildId -Parent $script:ROOT -Proj $script:PROJ -Created $script:FUTUREMS -Outcome 'succeeded')
    $script:apiMsgs = @(New-TXToolMsg -MsgId 'msg-tick-1' -MsgCreated $script:FUTUREMS -CallId 'call-tick-1' -ChildId $ChildId -Nx $Case.nx)
}
function Reset-TXSeams {
    $script:runCalls = 0; $script:runSid = ''; $script:apiCalls = 0; $script:apiLists = 0
    $script:apiPre = @(); $script:apiPost = @(); $script:apiMsgs = @()
}
function Invoke-TXTick {
    param($Case, $WakeResult = $null, [bool]$Enabled = $false, $Sessions = $null)
    $e = $Case.env
    $wr = $WakeResult
    if ($null -eq $wr) { $wr = $Case.wake }
    $s = $Sessions
    if ($null -eq $s) { $s = New-TXSessions -Env $e -Sid $script:ROOT -Proj $script:PROJ }
    $script:probe = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
    return (Invoke-GHWakeSchedulerTick -WakeResult $wr -AutoDispatchEnabled $Enabled `
        -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir `
        -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -RepoRoot $e.root -EvidenceStoreDir $e.receiptDir `
        -FlagsPath $e.flagsPath -NowUtc $script:NOW -ExpectedDirectory $e.root -ExpectedProjectId $script:PROJ `
        -PromptText '' -ControllerProbe $script:probe -RunExecutor $script:runMock `
        -SessionApiInvoker $script:apiMock -NativeSessionsResult $s -SettleResultSummary 'tick proof')
}
function Get-TXMarkers {
    param($Env)
    return @(Get-ChildItem -LiteralPath $Env.ckptDir -File -Filter 'ghw-handoff-*.json' -ErrorAction SilentlyContinue)
}
# --- B2: CLI/config boundary refuses ResumeSessionId in a live child process ---
$badCfg = Join-Path ([IO.Path]::GetTempPath()) ('tick-badcfg-' + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($badCfg, '{"waits_dir":"w","tasks_dir":"t","resume_session_id":"ses_tickroot01"}', (New-Object Text.UTF8Encoding $false))
$cliOut = ''
$cliCode = -1
try {
    $cliOut = (& powershell -NoProfile -File $script:tickWake -ConfigFile $badCfg 2>&1 | Out-String)
    $cliCode = $LASTEXITCODE
}
catch { $cliCode = -1 }
Assert-That ([int]$cliCode -eq 2) 'B2 CLI exits 2 on resume_session_id config'
Assert-That ($cliOut -cmatch 'invalid-config-file') 'B2 CLI reports invalid-config-file'
Remove-Item -LiteralPath $badCfg -Force -ErrorAction SilentlyContinue
# --- B4: enabled tick recovers root and runs existing auto-dispatch path ---
$case4 = New-TXCase -Tag 'b4' -TaskId 'tick-task-b4' -Evt 'evt-tick-b4'
Bind-TXRoot -Env $case4.env -TaskId 'tick-task-b4' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case4.env.root; proj = $script:PROJ } }
Reset-TXSeams
Set-TXProof -Case $case4
$r4 = Invoke-TXTick -Case $case4 -Enabled $true
Assert-That ([bool](Get-TXField $r4 'invoked' $false)) 'B4 enabled tick invokes dispatch'
$ad4 = Get-TXField $r4 'auto_dispatch' $null
Assert-That ($null -ne $ad4) 'B4 tick carries auto_dispatch result'
Assert-That (([string](Get-TXField $ad4 'resume_session_id' '')) -ceq $script:ROOT) 'B4 root session passed to auto-dispatch'
Assert-That (([string]$script:runSid) -ceq $script:ROOT) 'B4 run used recovered root session'
Assert-That ([int]$script:runCalls -eq 1) 'B4 exactly one executor call'
Assert-That ((-not [bool](Get-TXField $ad4 'dispatched' $true)) -and (-not [bool](Get-TXField $ad4 'executed' $true))) 'B4 zero productive effect'
Assert-That (([string](Get-TXField $ad4 'reason' '')) -ceq 'auto-worker-non-native') 'B4 injected seams stay non-native'
$case4.wake | Add-Member -NotePropertyName 'auto_dispatch' -NotePropertyValue $ad4 -Force
Assert-That (([string](Get-TXField (Get-TXField $case4.wake 'auto_dispatch' $null) 'resume_session_id' '')) -ceq $script:ROOT) 'B4 wake envelope carries auto_dispatch'
# --- B5: enabled tick, absent binding stays refused with zero effect ---
$case5 = New-TXCase -Tag 'b5' -TaskId 'tick-task-b5' -Evt 'evt-tick-b5'
$script:knownSids = @{ $script:ROOT = @{ dir = $case5.env.root; proj = $script:PROJ } }
Reset-TXSeams
$before5 = @((Get-TXMarkers -Env $case5.env)).Count
$r5 = Invoke-TXTick -Case $case5 -Enabled $true
Assert-That ([bool](Get-TXField $r5 'invoked' $false)) 'B5 tick invokes dispatch path'
Assert-That (([string](Get-TXField (Get-TXField $r5 'auto_dispatch' $null) 'reason' '')) -ceq 'auto-scheduler-binding-absent') 'B5 absent binding refused'
Assert-That ([int]$script:runCalls -eq 0) 'B5 zero executor effect'
Assert-That ([int]@((Get-TXMarkers -Env $case5.env)).Count -eq [int]$before5) 'B5 no marker side effect'
# --- B6: enabled tick, detached binding stays refused with zero effect ---
$case6 = New-TXCase -Tag 'b6' -TaskId 'tick-task-b6' -Evt 'evt-tick-b6'
Bind-TXRoot -Env $case6.env -TaskId 'tick-task-b6' -Sid $script:ROOT
$tb6 = Get-OrchestrationTask -TaskId 'tick-task-b6' -TasksDir $case6.env.tasksDir -RepoRoot $case6.env.root
$rev6 = [long](Get-TXField $tb6 'revision' 0)
$det6 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'tick-task-b6' -RunId $script:RUN -SessionId $script:ROOT -ExpectedRevision $rev6 -TasksDir $case6.env.tasksDir -FlagsPath $case6.env.flagsPath -RepoRoot $case6.env.root
if (-not [bool](Get-TXField $det6 'ok' $false)) { throw 'detach-setup' }
$script:knownSids = @{ $script:ROOT = @{ dir = $case6.env.root; proj = $script:PROJ } }
Reset-TXSeams
$before6 = @((Get-TXMarkers -Env $case6.env)).Count
$r6 = Invoke-TXTick -Case $case6 -Enabled $true
Assert-That (([string](Get-TXField (Get-TXField $r6 'auto_dispatch' $null) 'reason' '')) -ceq 'auto-scheduler-binding-detached') 'B6 detached binding refused'
Assert-That ([int]$script:runCalls -eq 0) 'B6 zero executor effect'
Assert-That ([int]@((Get-TXMarkers -Env $case6.env)).Count -eq [int]$before6) 'B6 no marker side effect'
# --- B7: enabled tick, ambiguous binding stays refused with zero effect ---
$case7 = New-TXCase -Tag 'b7' -TaskId 'tick-task-b7' -Evt 'evt-tick-b7'
Bind-TXRoot -Env $case7.env -TaskId 'tick-task-b7' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case7.env.root; proj = $script:PROJ } }
$tf7 = Get-TXTaskFile -Env $case7.env -TaskId 'tick-task-b7'
$doc7 = Get-Content -LiteralPath $tf7 -Raw | ConvertFrom-Json
$dup7 = $doc7.bindings.runs[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$doc7.bindings.runs = @($doc7.bindings.runs[0], $dup7)
[IO.File]::WriteAllText($tf7, (ConvertTo-Json -InputObject $doc7 -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Reset-TXSeams
$before7 = @((Get-TXMarkers -Env $case7.env)).Count
$r7 = Invoke-TXTick -Case $case7 -Enabled $true
Assert-That (([string](Get-TXField (Get-TXField $r7 'auto_dispatch' $null) 'reason' '')) -ceq 'auto-scheduler-binding-ambiguous') 'B7 ambiguous binding refused'
Assert-That ([int]$script:runCalls -eq 0) 'B7 zero executor effect'
Assert-That ([int]@((Get-TXMarkers -Env $case7.env)).Count -eq [int]$before7) 'B7 no marker side effect'
# --- B8: enabled tick with HOLD (no next_action) never dispatches ---
$case8 = New-TXCase -Tag 'b8' -TaskId 'tick-task-b8' -Evt 'evt-tick-b8'
Bind-TXRoot -Env $case8.env -TaskId 'tick-task-b8' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case8.env.root; proj = $script:PROJ } }
Reset-TXSeams
$holdWake = [pscustomobject]@{ ok = $true; next_action = $null }
$r8 = Invoke-TXTick -Case $case8 -WakeResult $holdWake -Enabled $true
Assert-That (-not [bool](Get-TXField $r8 'invoked' $true)) 'B8 no action never dispatches'
Assert-That ([int]$script:runCalls -eq 0) 'B8 zero executor effect'
# --- B9: production opt-in stays off by default ---
$cfgPath9 = Join-Path ([IO.Path]::GetTempPath()) ('tick-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg9 = New-GitHubWakeConfig -Path $cfgPath9 -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f'
Assert-That ([bool](Get-TXField $cfg9 'ok' $false)) 'B9 config created'
$cfgDoc9 = Get-Content -LiteralPath $cfgPath9 -Raw | ConvertFrom-Json
Assert-That (-not [bool](Get-TXField $cfgDoc9 'auto_dispatch_enabled' $true)) 'B9 production opt-in false by default'
$case9 = New-TXCase -Tag 'b9' -TaskId 'tick-task-b9' -Evt 'evt-tick-b9'
Bind-TXRoot -Env $case9.env -TaskId 'tick-task-b9' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case9.env.root; proj = $script:PROJ } }
Reset-TXSeams
Set-TXProof -Case $case9
$r9 = Invoke-GHWakeSchedulerDispatch -NextAction $case9.nx -WaitsDir $case9.env.waitsDir -TasksDir $case9.env.tasksDir -GoalStoreDir $case9.env.goalDir -CheckpointDir $case9.env.ckptDir -FlagsPath $case9.env.flagsPath -NowUtc $script:NOW -HandoffStateDir $case9.env.ckptDir -ReceiptDir $case9.env.receiptDir -RepoRoot $case9.env.root -ExpectedDirectory $case9.env.root -ExpectedProjectId $script:PROJ -PromptText '' -ControllerProbe ({ param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock' } }) -RunExecutor $script:runMock -SessionApiInvoker $script:apiMock -NativeSessionsResult (New-TXSessions -Env $case9.env -Sid $script:ROOT -Proj $script:PROJ) -SettleResultSummary 'tick b9'
Assert-That (([string](Get-TXField $r9 'decision' '')) -ceq 'blocked') 'B9 default dispatch stays blocked'
Assert-That (([string](Get-TXField $r9 'reason' '')) -ceq 'auto-dispatch-disabled') 'B9 default disabled reason'
Assert-That ([int]$script:runCalls -eq 0) 'B9 zero executor effect'
# --- B10: real child CLI, enabled tick, absent binding: proves config -> wake tick -> resolver -> auto-dispatch wiring end to end. Fails closed before any native call (no session list, no resume, no spawn): safe offline. ---
$case10 = New-TXCase -Tag 'b10' -TaskId 'tick-task-b10' -Evt 'evt-tick-b10'
$script:knownSids = @{}
$cfgPath10 = Join-Path $case10.env.root 'sched.json'
$cfg10 = New-GitHubWakeConfig -Path $cfgPath10 -WaitsDir $case10.env.waitsDir -TasksDir $case10.env.tasksDir -GoalStoreDir $case10.env.goalDir -CheckpointDir $case10.env.ckptDir -FlagsPath $case10.env.flagsPath -GraphQLSnapshotFile (Join-Path $case10.env.root 'green.graphql.json') -EventId 'evt-tick-b10-cli' -MaxAgeSeconds 300 -NowUtc $script:NOW -ResolveOwner $true -ResolveLease $true -AutoDispatchEnabled $true -AutoDispatchExpectedDirectory $case10.env.root -AutoDispatchExpectedProjectId $script:PROJ
if (-not [bool](Get-TXField $cfg10 'ok' $false)) { throw 'tick-cfg10' }
$cliOut10 = ''
$cliCode10 = -1
try {
    $cliOut10 = (& powershell -NoProfile -File $script:tickWake -ConfigFile $cfgPath10 -AuthorizationAlive -ExecutorPresent 2>&1 | Out-String)
    $cliCode10 = $LASTEXITCODE
}
catch { $cliCode10 = -1 }
Assert-That ([int]$cliCode10 -eq 0) 'B10 child CLI tick exits 0'
Assert-That ($cliOut10 -cmatch '"auto_dispatch":') 'B10 envelope carries auto_dispatch'
Assert-That ($cliOut10 -cmatch 'auto-scheduler-binding-absent') 'B10 enabled tick refused absent binding'
Assert-That ($cliOut10 -cnotmatch '"dispatched":true') 'B10 zero productive effect'
# --- B3 (last): disabled tick never reaches the resolver ---
function Resolve-GHWakeBoundRootSession { throw 'tick-must-not-resolve-when-disabled' }
Reset-TXSeams
$r3 = Invoke-TXTick -Case $case4 -Enabled $false
Assert-That (-not [bool](Get-TXField $r3 'invoked' $true)) 'B3 disabled tick never dispatches'
Assert-That ($null -eq (Get-TXField $r3 'auto_dispatch' 'x')) 'B3 disabled tick carries no dispatch'
Assert-That ([int]$script:runCalls -eq 0) 'B3 zero executor effect'
Write-Output ('TICK_PASS passed=' + [string]$script:passed)
