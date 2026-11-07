# github-wake-scheduler.tests.ps1 -- Fatia B: bound-root-session resolver + scheduler opt-in.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only: no gh, no network,
# no real opencode, no live run, no model quota. The injected RunExecutor
# and session-API transport are marked non-native by the driver, so even a
# fully validating payload reconciles as auto-worker-non-native with
# dispatched=false: productive settlement (dispatched=true from native
# evidence) is live-only and is NOT exercised here. The positive case proves
# the recovered root session is the session the auto-dispatch run uses
# (captured spec.session_id + resume_session_id), with exactly one executor
# call and zero settlement. Negative cases prove zero executor effect and no
# marker side effects. ASCII only.
$ErrorActionPreference = 'Stop'
$script:schedCli = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:schedCli -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found (expected before GREEN)' }
. $script:schedCli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-SCField {
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
Assert-That ($null -ne (Get-Command Resolve-GHWakeBoundRootSession -ErrorAction SilentlyContinue)) 'scheduler exposes Resolve-GHWakeBoundRootSession'
Assert-That ($null -ne (Get-Command Invoke-GHWakeSchedulerDispatch -ErrorAction SilentlyContinue)) 'scheduler exposes Invoke-GHWakeSchedulerDispatch'
$autoText = [IO.File]::ReadAllText($script:schedCli, [Text.Encoding]::UTF8)
foreach ($pin in @('UseBoundRootSession', 'auto-dispatch-disabled', 'auto-resume-id-forbidden', 'scheduler-binding-detached', 'scheduler-binding-cross-task', 'scheduler-identity-missing', 'SchedulerMode')) {
    Assert-That ($autoText -cmatch [regex]::Escape($pin)) ('scheduler pins surface: ' + $pin)
}
Assert-That ($autoText -cmatch 'caller-supplied session id is a fail-closed args refusal') 'scheduler mode forbids resume id'
$script:wakeCli = Join-Path $PSScriptRoot 'github-wake.ps1'
$wakeText = [IO.File]::ReadAllText($script:wakeCli, [Text.Encoding]::UTF8)
Assert-That ($wakeText -cmatch 'run_id') 'wake carries run_id'
Assert-That ($wakeText -cmatch 'auto_dispatch_enabled') 'wake config carries auto_dispatch_enabled'
Assert-That ($wakeText -cmatch 'resume_session_id') 'wake config rejects resume_session_id'
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
$script:SHA_S = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2027-06-01T00:00:00Z'
$script:REPO = 'acme/widgets'
$script:ROOT = 'ses_schedroot01'
$script:PROJ = 'proj-sched-1'
$script:RUN = 'run-sched-1'
$script:knownSids = @{}
function New-SCEnv {
    param([string]$Tag = 's')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwsched-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-SCGoal {
    param($Env, [string]$GoalId = 'sched-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d scheduler' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-SCField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-SCField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-SCField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-SCField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-SCField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-SCField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-SCField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-sched' -ReadScopes @('src/sched.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-SCField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-SCField (Get-SCField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-SCField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-SCBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-SCField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-SCField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-SCField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-SCField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId) }
}
function New-SCWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'sched-goal-1', [string]$RunId = '')
    $rid = $RunId
    if ([string]::IsNullOrWhiteSpace($rid)) { $rid = $script:RUN }
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId $rid -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/sched' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-SCField $reg 'ok' $false)) { throw ('wait:' + [string](Get-SCField $reg 'reason' '')) }
}
function New-SCCkpt {
    param($Env, [string]$GoalId = 'sched-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-SCField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-SCField $sv 'checkpoint_id' '')
}
function New-SCNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-SCRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-SCFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-SCGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-SCNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Invoke-SCWake {
    param($Env, [string]$Fixture = '', [string]$Evt = 'evt-sched-1')
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:policy -GraphQLSnapshotFile $Fixture -EventId $Evt -MaxAgeSeconds 300 -NowUtc $script:NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
}
function New-SCCase {
    param([string]$Tag = 'a', [string]$GoalId = 'sched-goal-1', [string]$TaskId = 'sched-task-a', [string]$Evt = 'evt-sched-1')
    $env = New-SCEnv -Tag $Tag
    $script:knownSids = @{}
    [void](New-SCGoal -Env $env -GoalId $GoalId -Tasks @($TaskId))
    Set-SCBlocked -Env $env -TaskId $TaskId -Sha $script:SHA_S
    New-SCWait -Env $env -TaskId $TaskId -Sha $script:SHA_S -GoalId $GoalId
    [void](New-SCCkpt -Env $env -GoalId $GoalId)
    $fx = Write-SCFixture -Env $env -Raw (New-SCRaw -Nodes (New-SCGreenNodes $script:SHA_S) -Head $script:SHA_S -Commit $script:SHA_S) -Name 'green.graphql.json'
    $w = Invoke-SCWake -Env $env -Fixture $fx -Evt $Evt
    $nx = Get-SCField $w 'next_action' $null
    if ($null -eq $nx) { throw ('case-setup-missing-next-action:' + $Tag) }
    return @{ env = $env; nx = $nx }
}
function Bind-SCRoot {
    param($Env, [string]$TaskId = '', [string]$Sid = '', [string]$RunId = '')
    $rid = $RunId
    if ([string]::IsNullOrWhiteSpace($rid)) { $rid = $script:RUN }
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-SCField $t 'revision' 0)
    $b = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $TaskId -RunId $rid -SessionId $Sid -ExpectedRevision $rev -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -RepoRoot $Env.root
    if (-not [bool](Get-SCField $b 'ok' $false)) { throw ('bind:' + [string](Get-SCField $b 'error' '')) }
}
function Get-SCTaskFile {
    param($Env, [string]$TaskId = '')
    $found = @(Get-ChildItem -LiteralPath $Env.tasksDir -File -Filter '*.json' | Where-Object { $_.BaseName -like ('*' + $TaskId + '*') })
    if (@($found).Count -lt 1) { throw ('task-file-missing:' + $TaskId) }
    return @($found)[0].FullName
}
function New-SCSessions {
    param($Env, [string]$Sid = '', [string]$Proj = '')
    $entry = [pscustomobject]@{ id = $Sid; title = 'sched-root'; created = 0; updated = 0; directory = $Env.root; projectId = $Proj }
    return [pscustomobject]@{ ok = $true; sessions = @($entry) }
}
# --- stub session identity: offline binding, no process spawn ---
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
        $sess = [pscustomobject]@{ id = $s; title = 'sched-binding'; created = 0; updated = 0; directory = [string]$rec.dir; projectId = [string]$rec.proj }
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
    try { $script:runSid = ([string](Get-SCField $spec 'session_id' '')) } catch { $script:runSid = '' }
    $body = ('{"sessionId":"' + $script:runSid + '","role":"assistant","type":"text"}')
    return [pscustomobject]@{ exit = 0; stdout = $body; stderr = ''; timedOut = $false }
}
$script:FUTUREMS = 0
try { $script:FUTUREMS = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000) } catch { $script:FUTUREMS = 1794000000000 }
function New-SCChild {
    param([string]$Id = '', [string]$Parent = '', [string]$Proj = '', [long]$Created = 0, [string]$Outcome = 'succeeded')
    $o = $Outcome
    if ([string]::IsNullOrWhiteSpace($o)) { $o = $null }
    return [pscustomobject]@{ id = $Id; parentID = $Parent; projectID = $Proj; agent = 'coder'; outcome = $o; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
}
function New-SCToolMsg {
    param([string]$MsgId = '', [long]$MsgCreated = 0, [string]$CallId = '', [string]$ChildId = '', $Nx = $null)
    $t = ([string](Get-SCField $Nx 'task_id' ''))
    $g = ([string](Get-SCField $Nx 'goal_id' ''))
    $gen = ([string](Get-SCField $Nx 'generation' '1'))
    $k = ([string](Get-SCField $Nx 'idempotency_key' '')).Trim().ToLowerInvariant()
    $marker = New-GHWADOperationMarker -GoalId $g -TaskId $t -Generation $gen -IdempotencyKey $k
    $prompt = ('invoke worker ' + $marker)
    $rj = ('{"task_id":"' + $t + '","goal_id":"' + $g + '","generation":"' + $gen + '","idempotency_key":"' + $k + '","status":"candidate_pass","claimed_evidence":["criterion:0"]}')
    $c = @(@{ type = 'text'; text = $rj })
    $st = @{ status = 'completed'; input = @{ agent = 'coder'; description = 'sched proof'; prompt = $prompt; sessionID = $ChildId }; metadata = @{ sessionID = $ChildId; status = 'completed'; truncated = $false }; content = $c }
    return [pscustomobject]@{ id = $MsgId; type = 'assistant'; agent = 'build'; time = [pscustomobject]@{ created = [long]$MsgCreated }; content = @(@{ type = 'tool'; id = $CallId; name = 'subagent'; state = $st; time = @{ created = [long]$MsgCreated; ran = [long]$MsgCreated; completed = [long]$MsgCreated } }) }
}
function Set-SCProof {
    param($Case, [string]$ChildId = 'ses_schedchild01')
    $nx = $Case.nx
    $script:apiPre = @()
    $script:apiPost = @(New-SCChild -Id $ChildId -Parent $script:ROOT -Proj $script:PROJ -Created $script:FUTUREMS -Outcome 'succeeded')
    $script:apiMsgs = @(New-SCToolMsg -MsgId 'msg-sched-1' -MsgCreated $script:FUTUREMS -CallId 'call-sched-1' -ChildId $ChildId -Nx $nx)
}
$script:probe = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
function Reset-SCSeams {
    $script:runCalls = 0; $script:runSid = ''; $script:apiCalls = 0; $script:apiLists = 0
    $script:apiPre = @(); $script:apiPost = @(); $script:apiMsgs = @()
}
function Invoke-SCSched {
    param($Case, [string]$Summary = 'sched proof', $Sessions = $null, [switch]$NoSessions, [bool]$Enabled = $true, [string]$DirOverride = $null, [string]$ProjOverride = $null)
    $e = $Case.env; $nx = $Case.nx
    $d = $e.root; if ($PSBoundParameters.ContainsKey('DirOverride')) { $d = $DirOverride }
    $p = $script:PROJ; if ($PSBoundParameters.ContainsKey('ProjOverride')) { $p = $ProjOverride }
    $s = $Sessions; if ($null -eq $s -and -not $NoSessions) { $s = New-SCSessions -Env $e -Sid $script:ROOT -Proj $script:PROJ }
    return (Invoke-GHWakeSchedulerDispatch -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -RepoRoot $e.root -ExpectedDirectory $d -ExpectedProjectId $p -PromptText 'sched resume' -AutoDispatchEnabled $Enabled -ControllerProbe $script:probe -RunExecutor $script:runMock -SessionApiInvoker $script:apiMock -NativeSessionsResult $s -SettleResultSummary $Summary)
}
function Get-SCMarkers {
    param($Env)
    return @(Get-ChildItem -LiteralPath $Env.ckptDir -File -Filter 'ghw-handoff-*.json' -ErrorAction SilentlyContinue)
}
# --- S1: next_action carries run_id sourced from the actual Wait ---
$case1 = New-SCCase -Tag 's1' -TaskId 'sched-task-s1' -Evt 'evt-sched-s1'
Assert-That (([string](Get-SCField $case1.nx 'run_id' '')) -ceq $script:RUN) 'S1 next_action run_id equals wait run_id'
$shape1 = Test-GHWakeHandoffShape -NextAction $case1.nx
Assert-That ([bool](Get-SCField $shape1 'ok' $false)) 'S1 shape validates run_id'
$bad1 = $case1.nx | Select-Object *
$bad1.run_id = ''
$shapeBad1 = Test-GHWakeHandoffShape -NextAction $bad1
Assert-That ((-not [bool](Get-SCField $shapeBad1 'ok' $true)) -and (([string](Get-SCField $shapeBad1 'reason' '')) -ceq 'invalid-next-action-shape')) 'S1 empty run_id fails shape'
# --- S2: config defaults disabled, stores identities, never resume id ---
$cfgPath2 = Join-Path ([IO.Path]::GetTempPath()) ('sched-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg2 = New-GitHubWakeConfig -Path $cfgPath2 -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f'
Assert-That ([bool](Get-SCField $cfg2 'ok' $false)) 'S2 config created'
$cfgDoc2 = Get-Content -LiteralPath $cfgPath2 -Raw | ConvertFrom-Json
Assert-That (-not [bool](Get-SCField $cfgDoc2 'auto_dispatch_enabled' $true)) 'S2 auto_dispatch defaults false'
Assert-That ($null -eq (Get-SCField $cfgDoc2 'resume_session_id' $null)) 'S2 config stores no resume_session_id'
$cfgPath2b = Join-Path ([IO.Path]::GetTempPath()) ('sched-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg2b = New-GitHubWakeConfig -Path $cfgPath2b -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f' -AutoDispatchEnabled $true -AutoDispatchExpectedDirectory 'd' -AutoDispatchExpectedProjectId 'p'
Assert-That ([bool](Get-SCField $cfg2b 'ok' $false)) 'S2 opt-in config created'
$cfgDoc2b = Get-Content -LiteralPath $cfgPath2b -Raw | ConvertFrom-Json
Assert-That ([bool](Get-SCField $cfgDoc2b 'auto_dispatch_enabled' $false)) 'S2 opt-in persisted'
Assert-That ((([string](Get-SCField $cfgDoc2b 'auto_dispatch_expected_directory' '')) -ceq 'd') -and (([string](Get-SCField $cfgDoc2b 'auto_dispatch_expected_project_id' '')) -ceq 'p')) 'S2 identities persisted'
# --- S3: positive scheduler path uses recovered root session, one run, no settle ---
$case3 = New-SCCase -Tag 's3' -TaskId 'sched-task-s3' -Evt 'evt-sched-s3'
Bind-SCRoot -Env $case3.env -TaskId 'sched-task-s3' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case3.env.root; proj = $script:PROJ } }
Reset-SCSeams
Set-SCProof -Case $case3
$r3 = Invoke-SCSched -Case $case3
Assert-That (([string]$script:runSid) -ceq $script:ROOT) 'S3 run used recovered root session'
Assert-That (([string](Get-SCField $r3 'resume_session_id' '')) -ceq $script:ROOT) 'S3 resume_session_id is root'
Assert-That ([int]$script:runCalls -eq 1) 'S3 exactly one executor call'
Assert-That ((-not [bool](Get-SCField $r3 'dispatched' $true)) -and (-not [bool](Get-SCField $r3 'executed' $true))) 'S3 zero productive effect'
Assert-That (([string](Get-SCField $r3 'reason' '')) -ceq 'auto-worker-non-native') 'S3 injected seams stay non-native'
function Get-NativeSessionById { param([string]$SessionId, [string]$BinaryCommand, [int]$TimeoutMs) return (New-SCSessions -Env $script:lookupEnv -Sid $SessionId -Proj $script:PROJ) }
function Get-NativeSessionList { throw 'limited session list must not be used' }
Reset-SCSeams
$case3direct = New-SCCase -Tag 's3-direct' -TaskId 'sched-task-s3-direct' -Evt 'evt-sched-s3-direct'
Bind-SCRoot -Env $case3direct.env -TaskId 'sched-task-s3-direct' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $case3direct.env.root; proj = $script:PROJ } }
$script:lookupEnv = $case3direct.env
Set-SCProof -Case $case3direct
$r3direct = Invoke-SCSched -Case $case3direct -NoSessions
Assert-That ($script:runSid -ceq $script:ROOT -and $script:runCalls -eq 1) 'S3 direct lookup recovers root once'
Assert-That ((Get-SCField $r3direct 'reason' '') -ceq 'auto-worker-non-native' -and -not (Get-SCField $r3direct 'dispatched' $true)) 'S3 direct lookup zero productive effect'
# Archived root is refused without executor, marker, or task-file mutation.
$caseArch = New-SCCase -Tag 'arch' -TaskId 'sched-task-arch' -Evt 'evt-sched-arch'
Bind-SCRoot -Env $caseArch.env -TaskId 'sched-task-arch' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseArch.env.root; proj = $script:PROJ } }
$taskArch = Get-SCTaskFile -Env $caseArch.env -TaskId 'sched-task-arch'
$beforeBytes = [IO.File]::ReadAllBytes($taskArch); $sha = [Security.Cryptography.SHA256]::Create(); $beforeHash = [BitConverter]::ToString($sha.ComputeHash($beforeBytes))
$beforeReceipts = @(Get-ChildItem -LiteralPath $caseArch.env.receiptDir -File -ErrorAction SilentlyContinue).Count
$archSessions = New-SCSessions -Env $caseArch.env -Sid $script:ROOT -Proj $script:PROJ
$archSessions.sessions[0] | Add-Member -NotePropertyName archived -NotePropertyValue $true
Reset-SCSeams
$rArch = Invoke-SCSched -Case $caseArch -Sessions $archSessions
$afterBytes = [IO.File]::ReadAllBytes($taskArch); $afterHash = [BitConverter]::ToString($sha.ComputeHash($afterBytes))
$afterReceipts = @(Get-ChildItem -LiteralPath $caseArch.env.receiptDir -File -ErrorAction SilentlyContinue).Count
Assert-That ((Get-SCField $rArch 'reason' '') -ceq 'auto-session-archived' -and $script:runCalls -eq 0) 'archived session refused before executor'
Assert-That (@(Get-SCMarkers $caseArch.env).Count -eq 0 -and $beforeHash -ceq $afterHash -and $beforeBytes.Length -eq $afterBytes.Length -and $beforeReceipts -eq $afterReceipts) 'archived session no marker, task, lease or receipt mutation'
# --- S4: disabled scheduler blocks structured with zero effect ---
Reset-SCSeams
$r4 = Invoke-SCSched -Case $case3 -Enabled $false
Assert-That (([string](Get-SCField $r4 'decision' '')) -ceq 'blocked') 'S4 disabled blocks'
Assert-That (([string](Get-SCField $r4 'reason' '')) -ceq 'auto-dispatch-disabled') 'S4 disabled reason'
Assert-That ([int]$script:runCalls -eq 0) 'S4 zero executor effect'
# --- S5: resolver mode rejects caller resume id ---
Reset-SCSeams
$r5 = Invoke-GHWakeAutoDispatch -NextAction $case3.nx -WaitsDir $case3.env.waitsDir -TasksDir $case3.env.tasksDir -GoalStoreDir $case3.env.goalDir -CheckpointDir $case3.env.ckptDir -FlagsPath $case3.env.flagsPath -NowUtc $script:NOW -HandoffStateDir $case3.env.ckptDir -ReceiptDir $case3.env.receiptDir -RepoRoot $case3.env.root -ResumeSessionId $script:ROOT -ExpectedDirectory $case3.env.root -ExpectedProjectId $script:PROJ -PromptText 'sched resume' -ControllerProbe $script:probe -RunExecutor $script:runMock -SessionApiInvoker $script:apiMock -UseBoundRootSession -NativeSessionsResult (New-SCSessions -Env $case3.env -Sid $script:ROOT -Proj $script:PROJ) -SettleResultSummary 'sched s5'
Assert-That (([string](Get-SCField $r5 'reason' '')) -ceq 'auto-resume-id-forbidden') 'S5 caller resume id forbidden'
Assert-That ([int]$script:runCalls -eq 0) 'S5 zero executor effect'
# --- S6: negatives cause zero run effect and no marker ---
function Assert-SCNegative {
    param($Case, [string]$Name, [string]$WantReason, $Sessions = $null, [string]$DirOverride, [string]$ProjOverride)
    Reset-SCSeams
    $before = @((Get-SCMarkers -Env $Case.env)).Count
    $fwd = @{}
    if ($PSBoundParameters.ContainsKey('DirOverride')) { $fwd['DirOverride'] = $DirOverride }
    if ($PSBoundParameters.ContainsKey('ProjOverride')) { $fwd['ProjOverride'] = $ProjOverride }
    if ($PSBoundParameters.ContainsKey('Sessions')) { $fwd['Sessions'] = $Sessions }
    $r = Invoke-SCSched -Case $Case @fwd
    if ([string](Get-SCField $r 'reason' '') -cne $WantReason) { throw ("FAIL: " + $Name + " reason=" + [string](Get-SCField $r 'reason' '')) }
    $script:passed++
    if ([int]$script:runCalls -ne 0) { throw ("FAIL: " + $Name + " executor effect") }
    $script:passed++
    $after = @((Get-SCMarkers -Env $Case.env)).Count
    if ([int]$after -ne [int]$before) { throw ("FAIL: " + $Name + " marker side effect") }
    $script:passed++
    if ([bool](Get-SCField $r 'dispatched' $true)) { throw ("FAIL: " + $Name + " dispatched") }
    $script:passed++
}
# S6a absent binding
$caseA = New-SCCase -Tag 's6a' -TaskId 'sched-task-s6a' -Evt 'evt-sched-s6a'
$script:knownSids = @{ $script:ROOT = @{ dir = $caseA.env.root; proj = $script:PROJ } }
Assert-SCNegative -Case $caseA -Name 'S6a absent' -WantReason 'auto-scheduler-binding-absent'
# S6b detached binding
$caseB = New-SCCase -Tag 's6b' -TaskId 'sched-task-s6b' -Evt 'evt-sched-s6b'
Bind-SCRoot -Env $caseB.env -TaskId 'sched-task-s6b' -Sid $script:ROOT
$tb = Get-OrchestrationTask -TaskId 'sched-task-s6b' -TasksDir $caseB.env.tasksDir -RepoRoot $caseB.env.root
$revB = [long](Get-SCField $tb 'revision' 0)
$detB = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'sched-task-s6b' -RunId $script:RUN -SessionId $script:ROOT -ExpectedRevision $revB -TasksDir $caseB.env.tasksDir -FlagsPath $caseB.env.flagsPath -RepoRoot $caseB.env.root
if (-not [bool](Get-SCField $detB 'ok' $false)) { throw 'detach-setup' }
$script:knownSids = @{ $script:ROOT = @{ dir = $caseB.env.root; proj = $script:PROJ } }
Assert-SCNegative -Case $caseB -Name 'S6b detached' -WantReason 'auto-scheduler-binding-detached'
# S6c run mismatch (tampered next_action run)
$caseC = New-SCCase -Tag 's6c' -TaskId 'sched-task-s6c' -Evt 'evt-sched-s6c'
Bind-SCRoot -Env $caseC.env -TaskId 'sched-task-s6c' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseC.env.root; proj = $script:PROJ } }
$caseC.nx.run_id = 'run-tampered-9'
Assert-SCNegative -Case $caseC -Name 'S6c run-mismatch' -WantReason 'auto-scheduler-run-mismatch'
# S6d wait not found
$caseD = New-SCCase -Tag 's6d' -TaskId 'sched-task-s6d' -Evt 'evt-sched-s6d'
Bind-SCRoot -Env $caseD.env -TaskId 'sched-task-s6d' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseD.env.root; proj = $script:PROJ } }
foreach ($wf in @(Get-ChildItem -LiteralPath $caseD.env.waitsDir -File -Filter 'ghwait-*.json')) { Remove-Item -LiteralPath $wf.FullName -Force }
Assert-SCNegative -Case $caseD -Name 'S6d wait-not-found' -WantReason 'auto-scheduler-wait-not-found'
# S6e session not found (native list lacks root)
$caseE = New-SCCase -Tag 's6e' -TaskId 'sched-task-s6e' -Evt 'evt-sched-s6e'
Bind-SCRoot -Env $caseE.env -TaskId 'sched-task-s6e' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseE.env.root; proj = $script:PROJ } }
$emptySess = [pscustomobject]@{ ok = $true; sessions = @() }
Assert-SCNegative -Case $caseE -Name 'S6e session-not-found' -WantReason 'auto-session-not-found' -Sessions $emptySess
# S6f identity missing
$caseF = New-SCCase -Tag 's6f' -TaskId 'sched-task-s6f' -Evt 'evt-sched-s6f'
Bind-SCRoot -Env $caseF.env -TaskId 'sched-task-s6f' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseF.env.root; proj = $script:PROJ } }
Assert-SCNegative -Case $caseF -Name 'S6f identity-missing' -WantReason 'auto-scheduler-identity-missing' -DirOverride ''
# S6g owner mismatch (revoked: active owner differs from bound root)
$caseG = New-SCCase -Tag 's6g' -TaskId 'sched-task-s6g' -Evt 'evt-sched-s6g'
Bind-SCRoot -Env $caseG.env -TaskId 'sched-task-s6g' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseG.env.root; proj = $script:PROJ } }
$tfG = Get-SCTaskFile -Env $caseG.env -TaskId 'sched-task-s6g'
$docG = Get-Content -LiteralPath $tfG -Raw | ConvertFrom-Json
$docG.bindings.active_execution_owner = 'ses_schedother02'
[IO.File]::WriteAllText($tfG, (ConvertTo-Json -InputObject $docG -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Assert-SCNegative -Case $caseG -Name 'S6g owner-mismatch' -WantReason 'auto-scheduler-binding-owner-mismatch'
# S6h cross-task conflict (same root bound on another task)
$caseH = New-SCCase -Tag 's6h' -TaskId 'sched-task-s6h' -Evt 'evt-sched-s6h' -GoalId 'sched-goal-s6h'
[void](New-SCGoal -Env $caseH.env -GoalId 'sched-goal-s6h-b' -Tasks @('sched-task-s6h-b'))
Set-SCBlocked -Env $caseH.env -TaskId 'sched-task-s6h-b' -Sha $script:SHA_S
Bind-SCRoot -Env $caseH.env -TaskId 'sched-task-s6h' -Sid $script:ROOT
Bind-SCRoot -Env $caseH.env -TaskId 'sched-task-s6h-b' -Sid $script:ROOT -RunId 'run-sched-b'
$script:knownSids = @{ $script:ROOT = @{ dir = $caseH.env.root; proj = $script:PROJ } }
Assert-SCNegative -Case $caseH -Name 'S6h cross-task' -WantReason 'auto-scheduler-binding-cross-task'
# S6i ambiguous binding (two runs share the run id)
$caseI = New-SCCase -Tag 's6i' -TaskId 'sched-task-s6i' -Evt 'evt-sched-s6i'
Bind-SCRoot -Env $caseI.env -TaskId 'sched-task-s6i' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseI.env.root; proj = $script:PROJ } }
$tfI = Get-SCTaskFile -Env $caseI.env -TaskId 'sched-task-s6i'
$docI = Get-Content -LiteralPath $tfI -Raw | ConvertFrom-Json
$dup = $docI.bindings.runs[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$docI.bindings.runs = @($docI.bindings.runs[0], $dup)
[IO.File]::WriteAllText($tfI, (ConvertTo-Json -InputObject $docI -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Assert-SCNegative -Case $caseI -Name 'S6i ambiguous' -WantReason 'auto-scheduler-binding-ambiguous'
# S6j legacy no-root (attached entry without root session)
$caseJ = New-SCCase -Tag 's6j' -TaskId 'sched-task-s6j' -Evt 'evt-sched-s6j'
Bind-SCRoot -Env $caseJ.env -TaskId 'sched-task-s6j' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseJ.env.root; proj = $script:PROJ } }
$tfJ = Get-SCTaskFile -Env $caseJ.env -TaskId 'sched-task-s6j'
$docJ = Get-Content -LiteralPath $tfJ -Raw | ConvertFrom-Json
$docJ.bindings.runs[0].root_session = ''
$docJ.bindings.active_execution_owner = ''
[IO.File]::WriteAllText($tfJ, (ConvertTo-Json -InputObject $docJ -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Assert-SCNegative -Case $caseJ -Name 'S6j no-root' -WantReason 'auto-scheduler-binding-no-root'
# S6k invalid record (missing task_id hiding the selected root session) fails closed
$caseK = New-SCCase -Tag 's6k' -TaskId 'sched-task-s6k' -Evt 'evt-sched-s6k'
Bind-SCRoot -Env $caseK.env -TaskId 'sched-task-s6k' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseK.env.root; proj = $script:PROJ } }
$evilK = Join-Path $caseK.env.tasksDir 'evil-orphan.json'
$evilDocK = [ordered]@{ task_id = ''; revision = 1; bindings = [ordered]@{ runs = @(@{ run_id = 'run-evil-k'; root_session = $script:ROOT; worker_sessions = @(); status = 'attached' }); active_execution_owner = $script:ROOT } }
[IO.File]::WriteAllText($evilK, (ConvertTo-Json -InputObject $evilDocK -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Assert-SCNegative -Case $caseK -Name 'S6k invalid-record' -WantReason 'auto-scheduler-binding-scan-unavailable'
# S6l filename/task_id mismatch fails closed
$caseL = New-SCCase -Tag 's6l' -TaskId 'sched-task-s6l' -Evt 'evt-sched-s6l'
Bind-SCRoot -Env $caseL.env -TaskId 'sched-task-s6l' -Sid $script:ROOT
$script:knownSids = @{ $script:ROOT = @{ dir = $caseL.env.root; proj = $script:PROJ } }
$evilL = Join-Path $caseL.env.tasksDir 'mismatch-name.json'
$evilDocL = [ordered]@{ task_id = 'sched-task-s6l-x'; revision = 1; bindings = [ordered]@{ runs = @(@{ run_id = 'run-evil-l'; root_session = $script:ROOT; worker_sessions = @(); status = 'attached' }); active_execution_owner = $script:ROOT } }
[IO.File]::WriteAllText($evilL, (ConvertTo-Json -InputObject $evilDocL -Depth 20 -Compress), (New-Object Text.UTF8Encoding $false))
Assert-SCNegative -Case $caseL -Name 'S6l filename-mismatch' -WantReason 'auto-scheduler-binding-scan-unavailable'
# --- S6m: target exclusion is ordinal (case-sensitive) after GetFullPath ---
Assert-That ($null -ne (Get-Command Test-GHWADIsTargetPath -ErrorAction SilentlyContinue)) 'S6m helper exists'
$script:targetProbe = [IO.Path]::GetFullPath((Join-Path $caseL.env.tasksDir 'sched-task-s6l.json'))
$script:exactProbe = [IO.Path]::GetFullPath((Join-Path $caseL.env.tasksDir 'sched-task-s6l.json'))
Assert-That (Test-GHWADIsTargetPath -CandidateFull $script:exactProbe -TargetFull $script:targetProbe) 'S6m exact canonical path is target'
$script:aliasProbe = ([string]$script:targetProbe).Replace('sched-task-s6l', 'SCHED-TASK-S6L')
Assert-That (([string]$script:aliasProbe) -cne ([string]$script:targetProbe)) 'S6m alias differs by case only'
Assert-That (-not (Test-GHWADIsTargetPath -CandidateFull $script:aliasProbe -TargetFull $script:targetProbe)) 'S6m case-only alias is not target'
# --- S7: one-shot mode (opt-in -OneShot, DryRun only, no schtasks mutation) ---
. (Join-Path $PSScriptRoot 'github-wake.ps1')
$script:wakeCliPath = Join-Path $PSScriptRoot 'github-wake.ps1'
Assert-That ($null -ne (Get-Command Get-GHWSchtasksXml -ErrorAction SilentlyContinue)) 'S7 scheduler xml helper exposed'
Assert-That ($null -ne (Get-Command Register-GitHubWakeSchedule -ErrorAction SilentlyContinue)) 'S7 scheduler register exposed'
$dryDef7 = Register-GitHubWakeSchedule -TaskName 'ghw-oneshot-def' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -DryRun
Assert-That ([bool](Get-SCField $dryDef7 'ok' $false)) 'S7 default dry-run ok'
$dryDefXml7 = [string](Get-SCField $dryDef7 'xml' '')
Assert-That ($dryDefXml7 -cmatch '<Repetition>') 'S7 default xml retains Repetition'
$dryOne7 = Register-GitHubWakeSchedule -TaskName 'ghw-oneshot-one' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -OneShot -DryRun
Assert-That ([bool](Get-SCField $dryOne7 'ok' $false)) 'S7 one-shot dry-run ok'
$oneXml7 = [string](Get-SCField $dryOne7 'xml' '')
Assert-That ($oneXml7 -cnotmatch 'Repetition') 'S7 one-shot xml omits Repetition element'
Assert-That (($oneXml7 -cmatch '<StartBoundary>') -and ($oneXml7 -cmatch '<ExecutionTimeLimit>') -and ($oneXml7 -cmatch '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>') -and ($oneXml7 -cmatch '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>') -and ($oneXml7 -cmatch 'InteractiveToken') -and ($oneXml7 -cmatch 'LeastPrivilege')) 'S7 one-shot xml retains start boundary, time limit, battery and privilege pins'
$cfInt7 = Register-GitHubWakeSchedule -TaskName 'ghw-oneshot-cf' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -OneShot -IntervalMinutes 5 -DryRun
Assert-That ((-not [bool](Get-SCField $cfInt7 'ok' $true)) -and (([string](Get-SCField $cfInt7 'reason' '')) -ceq 'oneshot-schedule-conflict')) 'S7 one-shot explicit interval rejected'
$cfDur7 = Register-GitHubWakeSchedule -TaskName 'ghw-oneshot-cf' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -OneShot -DurationHours 12 -DryRun
Assert-That ((-not [bool](Get-SCField $cfDur7 'ok' $true)) -and (([string](Get-SCField $cfDur7 'reason' '')) -ceq 'oneshot-schedule-conflict')) 'S7 one-shot explicit duration rejected'
$rawDef7 = Get-GHWSchtasksXml -TaskName 'ghw-oneshot-raw' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5
Assert-That ($rawDef7 -cmatch '<Repetition>') 'S7 raw default xml retains Repetition'
$rawOne7 = Get-GHWSchtasksXml -TaskName 'ghw-oneshot-raw' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -ExecutionTimeLimitMinutes 5 -OneShot
Assert-That (([string]$rawOne7 -cnotmatch 'Repetition') -and (-not [string]::IsNullOrWhiteSpace([string]$rawOne7))) 'S7 raw one-shot xml omits Repetition'
# --- S8: one-shot compatibility + owned decision (pure only, no schtasks mutation) ---
Assert-That ($null -ne (Get-Command Test-GHWScheduleOneShotCompatible -ErrorAction SilentlyContinue)) 'S8 compatibility helper exposed'
Assert-That ($null -ne (Get-Command Get-GHWScheduleOwnedDecision -ErrorAction SilentlyContinue)) 'S8 owned decision helper exposed'
$repXml8 = Get-GHWSchtasksXml -TaskName 'ghw-mode-rep' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5
$oneXml8 = Get-GHWSchtasksXml -TaskName 'ghw-mode-one' -WakeScript $script:wakeCliPath -ConfigFile $script:wakeCliPath -ExecutionTimeLimitMinutes 5 -OneShot
Assert-That ([bool](Test-GHWScheduleOneShotCompatible -Xml $oneXml8)) 'S8 generated one-shot xml compatible'
Assert-That (-not [bool](Test-GHWScheduleOneShotCompatible -Xml $repXml8)) 'S8 repeating xml incompatible'
Assert-That (-not [bool](Test-GHWScheduleOneShotCompatible -Xml '')) 'S8 empty xml incompatible'
Assert-That (-not [bool](Test-GHWScheduleOneShotCompatible -Xml 'not xml at all <>>>')) 'S8 garbage xml incompatible'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Owned $true -ExistingXml $repXml8)) -ceq 'oneshot-mode-conflict') 'S8 oneshot vs repeating owned conflicts'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Owned $true -ExistingXml $oneXml8)) -ceq 'already-registered') 'S8 oneshot vs compatible owned reuses'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Force $true -Owned $true -ExistingXml $repXml8)) -ceq 'replace-owned') 'S8 oneshot force regenerates owned'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $false -Owned $true -ExistingXml $repXml8)) -ceq 'already-registered') 'S8 default vs repeating owned unchanged'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $false -Owned $true -ExistingXml $oneXml8)) -ceq 'already-registered') 'S8 default vs one-shot owned unchanged'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $false -Force $true -Owned $true -ExistingXml $repXml8)) -ceq 'replace-owned') 'S8 default force regenerates owned'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Owned $true -ExistingXml '')) -ceq 'oneshot-mode-conflict') 'S8 oneshot vs unreadable owned conflicts'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $false -Owned $false -ExistingXml $repXml8)) -ceq 'task-name-conflict') 'S8 unowned without force conflicts'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $false -Force $true -Owned $false -ExistingXml $repXml8)) -ceq 'task-name-conflict') 'S8 unowned with force still conflicts'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Force $true -Owned $false -ExistingXml $oneXml8)) -ceq 'task-name-conflict') 'S8 oneshot unowned with force still conflicts'
# --- S9: trigger-count shape (pure only, no schtasks mutation) ---
$noTrigXml9 = (([string]$oneXml8) -replace '(?s)<TimeTrigger>.*?</TimeTrigger>', '')
Assert-That (-not [bool](Test-GHWScheduleOneShotCompatible -Xml $noTrigXml9)) 'S9 missing TimeTrigger incompatible'
$multiXml9 = (([string]$oneXml8).Replace('</TimeTrigger>', '</TimeTrigger><TimeTrigger><StartBoundary>2030-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger>'))
Assert-That (-not [bool](Test-GHWScheduleOneShotCompatible -Xml $multiXml9)) 'S9 multiple TimeTriggers incompatible'
Assert-That (([string](Get-GHWScheduleOwnedDecision -OneShot $true -Owned $true -ExistingXml $multiXml9)) -ceq 'oneshot-mode-conflict') 'S9 oneshot vs multi-trigger owned conflicts'
Write-Output ('SCHEDULER_PASS passed=' + [string]$script:passed)
