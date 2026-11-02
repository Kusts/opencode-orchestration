# github-wake-auto-dispatch.tests.ps1 -- native worker-proof integration.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only: no gh, no network,
# no real opencode, no live run, no model quota. The RunExecutor mock
# CANNOT generate proof or a worker id and can NEVER cause dispatched=true:
# every driver call below injects a synthetic session-API transport, which
# the driver marks non-native, so even a fully validating payload
# reconciles as auto-worker-non-native with dispatched=false. Productive
# settlement (dispatched=true from native evidence) is live-only and is
# NOT exercised here. Pure validator unit tests (Find-GHWADNativeWorkerProof
# on synthetic native-shaped objects) cover shape logic without settling.
# Proves: N1 (valid Planner JSONL with no subagent => auto-worker-unproven),
# stale/pre-existing child exclusion, task/operation mismatch, result
# unproven, transport failures handled before/after the run, and that the
# pre-snapshot happens BEFORE any resume run. ASCII only.
$ErrorActionPreference = 'Stop'
$script:autoCli = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:autoCli -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found (expected before GREEN)' }
. $script:autoCli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-ADField {
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
Assert-That ($null -ne (Get-Command Invoke-GHWakeAutoDispatch -ErrorAction SilentlyContinue)) 'dot-source exposes Invoke-GHWakeAutoDispatch'
Assert-That ($null -ne (Get-Command Find-GHWADNativeWorkerProof -ErrorAction SilentlyContinue)) 'dot-source exposes Find-GHWADNativeWorkerProof'
Assert-That ($null -ne (Get-Command Get-GHWADChildSnapshot -ErrorAction SilentlyContinue)) 'dot-source exposes Get-GHWADChildSnapshot'
$autoText = [IO.File]::ReadAllText($script:autoCli, [Text.Encoding]::UTF8)
foreach ($bad in @('while\s*\(', 'Start-Job', 'Start-Sleep', 'Start-Process', 'System\.Timers', 'Register-ObjectEvent', 'FileSystemWatcher', 'Register-ScheduledTask', 'Start-Service', 'New-Service', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', '--continue', '--fork', 'GH_TOKEN', 'GITHUB_TOKEN', 'WorkerSessionId', 'WorkerParentSessionId', 'WorkerIdempotencyKey', 'WorkerProofSource', 'WorkerTaskId', 'WorkerResultStatus', 'Test-GHWakeWorkerProof', 'C:\\Users')) {
    Assert-That ($autoText -cnotmatch $bad) ('auto dispatch has no daemon/spawn/self-attestation pattern: ' + $bad)
}
foreach ($need in @('Invoke-GHWakeControllerHandoff', 'Invoke-OrchestrationNativeResume', 'Find-GHWADNativeWorkerProof', 'Find-GHWADWorkerResultObject', 'New-GHWADOperationMarker', 'Get-GHWADWorkerDirective', 'Test-GHWADPromptFits', 'Get-GHWADChildSnapshot', 'Get-GHWADResumeMessages', 'session.list', 'session.message.list', 'parentID', 'RunExecutor', 'SessionApiInvoker', 'ghw-handoff-', 'ghw-op goal=', 'idempotency_key', 'reconcile', 'already-done', 'auto-worker-unproven', 'auto-worker-non-native', 'auto-worker-api-unavailable', 'auto-prompt-unfittable', 'auto-replay-unproven', 'Remove-GHWakeHandoffClaim')) {
    Assert-That ($autoText -cmatch [regex]::Escape($need)) ('auto dispatch pins required surface: ' + $need)
}
Assert-That ($autoText -cmatch 'proceed') 'auto dispatch names the proceed gate'
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
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2027-06-01T00:00:00Z'
$script:REPO = 'acme/widgets'
$script:SID = 'ses_AutoDispatch001'
$script:PROJ = 'proj-auto-1'
$script:ADFuture = 0
try { $script:ADFuture = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000) } catch { $script:ADFuture = 1794000000000 }
function New-ADEnv {
    param([string]$Tag = 'a')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwad-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-ADGoal {
    param($Env, [string]$GoalId = 'ghwad-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d auto dispatch' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-ADField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-ADField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-ADField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-ADField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-ADField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-ADField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-ADField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-ghwad' -ReadScopes @('src/ghwad.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-ADField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-ADField (Get-ADField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-ADField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-ADBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-ADField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-ADField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-ADField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-ADField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-ADField $tr 'error' '')) }
}
function New-ADWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'ghwad-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-ghwad' -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/ghwad' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-ADField $reg 'ok' $false)) { throw ('wait:' + [string](Get-ADField $reg 'reason' '')) }
}
function New-ADCkpt {
    param($Env, [string]$GoalId = 'ghwad-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-ADField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-ADField $sv 'checkpoint_id' '')
}
function New-ADNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-ADRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-ADFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-ADGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-ADNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Invoke-ADWake {
    param($Env, [string]$Fixture = '', [string]$Evt = 'evt-ghwad-1')
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:policy -GraphQLSnapshotFile $Fixture -EventId $Evt -MaxAgeSeconds 300 -NowUtc $script:NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
}
function New-ADCase {
    param([string]$Tag = 'a', [string]$GoalId = 'ghwad-goal-1', [string]$TaskId = 'ghwad-task-a', [string]$Evt = 'evt-ghwad-1')
    $env = New-ADEnv -Tag $Tag
    $script:ADBindDir = $env.root
    [void](New-ADGoal -Env $env -GoalId $GoalId -Tasks @($TaskId))
    Set-ADBlocked -Env $env -TaskId $TaskId -Sha $script:SHA_A
    New-ADWait -Env $env -TaskId $TaskId -Sha $script:SHA_A -GoalId $GoalId
    [void](New-ADCkpt -Env $env -GoalId $GoalId)
    $fx = Write-ADFixture -Env $env -Raw (New-ADRaw -Nodes (New-ADGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
    $w = Invoke-ADWake -Env $env -Fixture $fx -Evt $Evt
    $nx = Get-ADField $w 'next_action' $null
    if ($null -eq $nx) { throw ('case-setup-missing-next-action:' + $Tag) }
    return @{ env = $env; nx = $nx; idem = ([string](Get-ADField $nx 'idempotency_key' '')).Trim().ToLowerInvariant() }
}
# --- stub session identity: offline binding, no process spawn ---
$script:ADBindSid = $script:SID
$script:ADBindProj = $script:PROJ
$script:ADBindDir = ''
function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = 'opencode', [int]$TimeoutMs = 30000)
    try {
        $s = (([string]$SessionId).Trim())
        if (($s -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($s -match 'continue')) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = 'stub:bad-id'; session = $null }
        }
        if ($s -cne $script:ADBindSid) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
        }
        if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne $script:ADBindProj)) {
            return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
        }
        $sess = [pscustomobject]@{ id = $script:ADBindSid; title = 'auto-dispatch-binding'; created = 0; updated = 0; directory = $script:ADBindDir; projectId = $script:ADBindProj }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
    }
}
# --- synthetic native API transport (injected => NEVER settles) ---
$script:ADApi = @{ pre = @(); post = @(); msgs = @(); fail = ''; calls = @(); lists = 0 }
$script:ADApiMock = {
    param($Operation, $Params)
    $script:ADApi.calls += @(([string]$Operation))
    if (([string]$Operation) -ceq 'session.list') {
        $script:ADApi.lists++
        if (([string]$script:ADApi.fail) -ceq 'pre' -and ([int]$script:ADApi.lists) -eq 1) {
            return [pscustomobject]@{ ok = $false }
        }
        if (([string]$script:ADApi.fail) -ceq 'post' -and ([int]$script:ADApi.lists) -ge 2) {
            return [pscustomobject]@{ ok = $false }
        }
        $arr = @($script:ADApi.pre)
        if ([int]$script:ADApi.lists -ge 2) { $arr = @($script:ADApi.post) }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = $arr; cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    if (([string]$Operation) -ceq 'session.message.list') {
        if (([string]$script:ADApi.fail) -ceq 'msg') {
            return [pscustomobject]@{ ok = $false }
        }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @($script:ADApi.msgs); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    return [pscustomobject]@{ ok = $false }
}
$script:mockRunCalls = 0
$script:lastRunPrompt = ''
$script:mockRun = {
    param($spec)
    $script:mockRunCalls++
    try { $script:lastRunPrompt = ([string](Get-ADField $spec 'prompt' '')) } catch { $script:lastRunPrompt = '' }
    $body = ('{"sessionId":"' + $script:SID + '","role":"assistant","type":"text"}')
    return [pscustomobject]@{ exit = 0; stdout = $body; stderr = ''; timedOut = $false }
}
$script:probe = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
function New-ADChild {
    param([string]$Id = '', [string]$Parent = '', [string]$Proj = '', [long]$Created = 0, [string]$Outcome = 'succeeded')
    $o = $Outcome
    if ([string]::IsNullOrWhiteSpace($o)) { $o = $null }
    return [pscustomobject]@{ id = $Id; parentID = $Parent; projectID = $Proj; agent = 'coder'; outcome = $o; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
}
function New-ADToolMsg {
    param([string]$MsgId = '', [long]$MsgCreated = 0, [string]$CallId = '', [string]$Status = 'completed', [string]$ChildId = '', $Nx = $null, [string]$ResultStatus = 'candidate_pass', [bool]$WithContent = $true, [string]$PromptOverride = '')
    $t = ([string](Get-ADField $Nx 'task_id' ''))
    $g = ([string](Get-ADField $Nx 'goal_id' ''))
    $gen = ([string](Get-ADField $Nx 'generation' '1'))
    $k = ([string](Get-ADField $Nx 'idempotency_key' '')).Trim().ToLowerInvariant()
    $marker = New-GHWADOperationMarker -GoalId $g -TaskId $t -Generation $gen -IdempotencyKey $k
    $prompt = ('invoke worker ' + $marker)
    if ($PromptOverride -cne '') { $prompt = $PromptOverride }
    $rj = ('{"task_id":"' + $t + '","goal_id":"' + $g + '","generation":"' + $gen + '","idempotency_key":"' + $k + '","status":"' + $ResultStatus + '","claimed_evidence":["criterion:0"]}')
    $c = $null
    if ([bool]$WithContent) { $c = @(@{ type = 'text'; text = $rj }) }
    $st = @{ status = $Status; input = @{ agent = 'coder'; description = 'auto dispatch'; prompt = $prompt; sessionID = $ChildId }; metadata = @{ sessionID = $ChildId; status = 'completed'; truncated = $false }; content = $c }
    return [pscustomobject]@{ id = $MsgId; type = 'assistant'; agent = 'build'; time = [pscustomobject]@{ created = [long]$MsgCreated }; content = @(@{ type = 'tool'; id = $CallId; name = 'subagent'; state = $st; time = @{ created = [long]$MsgCreated; ran = [long]$MsgCreated; completed = [long]$MsgCreated } }) }
}
function Invoke-ADDriver {
    param($Case, [string]$Summary = 'auto dispatch proof run')
    $e = $Case.env; $nx = $Case.nx
    $prompt = ('resume goal ' + [string](Get-ADField $nx 'goal_id' '') + ' task ' + [string](Get-ADField $nx 'task_id' '') + ' checkpoint ' + [string](Get-ADField $nx 'checkpoint_id' '') + ' generation ' + [string](Get-ADField $nx 'generation' '1'))
    return (Invoke-GHWakeAutoDispatch -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NOW -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -RepoRoot $e.root -ResumeSessionId $script:SID -ExpectedDirectory $e.root -ExpectedProjectId $script:PROJ -PromptText $prompt -ControllerProbe $script:probe -RunExecutor $script:mockRun -SessionApiInvoker $script:ADApiMock -SettleResultSummary $Summary)
}
function Reset-ADApi {
    $script:ADApi.pre = @(); $script:ADApi.post = @(); $script:ADApi.msgs = @()
    $script:ADApi.fail = ''; $script:ADApi.calls = @(); $script:ADApi.lists = 0
    $script:mockRunCalls = 0
    $script:lastRunPrompt = ''
}
function Assert-ADNoDispatch {
    param($R, [string]$Name = '')
    Assert-That (-not [bool](Get-ADField $R 'dispatched' $true)) ($Name + ': never dispatched')
    Assert-That (-not [bool](Get-ADField $R 'executed' $true)) ($Name + ': never marked executed')
    Assert-That ((-not [bool](Get-ADField $R 'grants_authority' $true)) -and (-not [bool](Get-ADField $R 'done_approved' $true)) -and (-not [bool](Get-ADField $R 'merge_authority' $true))) ($Name + ': authority pins stay false')
    Assert-That (([string](Get-ADField $R 'harness' '')) -ceq 'github-wake-auto-dispatch-v2') ($Name + ': harness v2 envelope')
}
# --- T1 N1: valid Planner JSONL with NO subagent => auto-worker-unproven ---
$case1 = New-ADCase -Tag 't1' -GoalId 'ghwad-goal-t1' -TaskId 'ghwad-task-t1' -Evt 'evt-ghwad-t1'
Reset-ADApi
$r1 = Invoke-ADDriver -Case $case1
Assert-That ([int]$script:mockRunCalls -eq 1) 'T1: single resume run counted once, never resent'
Assert-That ([int]@($script:ADApi.calls).Count -ge 3) 'T1: pre + post + messages reads happened'
Assert-ADNoDispatch -R $r1 -Name 'T1'
Assert-That ([string](Get-ADField $r1 'decision' '') -ceq 'reconcile') 'T1: decision reconcile'
Assert-That ([string](Get-ADField $r1 'reason' '') -ceq 'auto-worker-unproven') 'T1: NATIVE_SESSION_RESUMED alone => auto-worker-unproven'
Assert-That ([string](Get-ADField $r1 'resume_action' '') -ceq 'proceed') 'T1: resume proceed recorded, not conflated with dispatch'
$marker1 = ([string](Get-ADField $r1 'marker_path' '')).Trim()
Assert-That ((-not [string]::IsNullOrWhiteSpace($marker1)) -and (Test-Path -LiteralPath $marker1 -PathType Leaf)) 'T1: claim marker kept for operator reconciliation'
Assert-That ([string](Get-ADField (ConvertFrom-Json ([IO.File]::ReadAllText($marker1, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'T1: marker stays claimed, no settle'
# --- T2: fully validating INJECTED payload still never settles ---
$case2 = New-ADCase -Tag 't2' -GoalId 'ghwad-goal-t2' -TaskId 'ghwad-task-t2' -Evt 'evt-ghwad-t2'
Reset-ADApi
$wid2 = 'ses_AutoDispatchW02'
$script:ADApi.post = @(New-ADChild -Id $wid2 -Parent $script:SID -Proj $script:PROJ -Created $script:ADFuture -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t2a1' -MsgCreated $script:ADFuture -CallId 'call_t2a1' -Status 'completed' -ChildId $wid2 -Nx $case2.nx)
$r2 = Invoke-ADDriver -Case $case2
Assert-That ([int]$script:mockRunCalls -eq 1) 'T2: single resume run counted once, never resent'
Assert-ADNoDispatch -R $r2 -Name 'T2'
Assert-That ([string](Get-ADField $r2 'decision' '') -ceq 'reconcile') 'T2: decision reconcile'
Assert-That ([string](Get-ADField $r2 'reason' '') -ceq 'auto-worker-non-native') 'T2: injected transport never settles (auto-worker-non-native)'
Assert-That ([string](Get-ADField (ConvertFrom-Json ([IO.File]::ReadAllText(([string](Get-ADField $r2 'marker_path' '')), [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'T2: marker stays claimed'
# --- T12: the spec effectively passed to run carries marker + directive ---
# (captured from the injected RunExecutor input: no live execution)
$expMarker12 = New-GHWADOperationMarker -GoalId ([string](Get-ADField $case2.nx 'goal_id' '')) -TaskId ([string](Get-ADField $case2.nx 'task_id' '')) -Generation ([string](Get-ADField $case2.nx 'generation' '1')) -IdempotencyKey $case2.idem
Assert-That (-not [string]::IsNullOrWhiteSpace($expMarker12)) 'T12 setup: expected marker builds'
Assert-That (([string]$script:lastRunPrompt).Contains($expMarker12)) 'T12: run prompt carries the EXACT operation marker'
Assert-That (([string]$script:lastRunPrompt).Contains('subagent')) 'T12: run prompt instructs native subagent delegation'
Assert-That (([string]$script:lastRunPrompt).Contains('Forward the marker exactly')) 'T12: run prompt instructs exact marker forwarding'
Assert-That (([string]$script:lastRunPrompt).Contains('JSON object')) 'T12: run prompt requires the worker JSON result object'
Assert-That (([string]$script:lastRunPrompt).Contains('claimed_evidence')) 'T12: run prompt names the criterion refs'
Assert-That (([string]$script:lastRunPrompt).Contains('Never substitute your own result')) 'T12: run prompt forbids Planner result substitution'
Assert-That (Test-GHWADPromptFits -PromptText ([string]$script:lastRunPrompt)) 'T12: effective prompt fits the NativeResume gate'
# --- T3: stale child (created before the run) => operation-mismatch ---
$case3 = New-ADCase -Tag 't3' -GoalId 'ghwad-goal-t3' -TaskId 'ghwad-task-t3' -Evt 'evt-ghwad-t3'
Reset-ADApi
$wid3 = 'ses_AutoDispatchW03'
$script:ADApi.post = @(New-ADChild -Id $wid3 -Parent $script:SID -Proj $script:PROJ -Created 1 -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t3a1' -MsgCreated $script:ADFuture -CallId 'call_t3a1' -Status 'completed' -ChildId $wid3 -Nx $case3.nx)
$r3 = Invoke-ADDriver -Case $case3
Assert-ADNoDispatch -R $r3 -Name 'T3'
Assert-That ([string](Get-ADField $r3 'reason' '') -ceq 'auto-worker-operation-mismatch') 'T3: stale child => auto-worker-operation-mismatch'
# --- T4: pre-existing child excluded => unproven ---
$case4 = New-ADCase -Tag 't4' -GoalId 'ghwad-goal-t4' -TaskId 'ghwad-task-t4' -Evt 'evt-ghwad-t4'
Reset-ADApi
$wid4 = 'ses_AutoDispatchW04'
$old4 = New-ADChild -Id $wid4 -Parent $script:SID -Proj $script:PROJ -Created $script:ADFuture -Outcome 'succeeded'
$script:ADApi.pre = @($old4)
$script:ADApi.post = @($old4)
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t4a1' -MsgCreated $script:ADFuture -CallId 'call_t4a1' -Status 'completed' -ChildId $wid4 -Nx $case4.nx)
$r4 = Invoke-ADDriver -Case $case4
Assert-ADNoDispatch -R $r4 -Name 'T4'
Assert-That ([string](Get-ADField $r4 'reason' '') -ceq 'auto-worker-unproven') 'T4: pre-existing child excluded => auto-worker-unproven'
# --- T5: prompt without operation bindings => operation-mismatch ---
$case5 = New-ADCase -Tag 't5' -GoalId 'ghwad-goal-t5' -TaskId 'ghwad-task-t5' -Evt 'evt-ghwad-t5'
Reset-ADApi
$wid5 = 'ses_AutoDispatchW05'
$script:ADApi.post = @(New-ADChild -Id $wid5 -Parent $script:SID -Proj $script:PROJ -Created $script:ADFuture -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t5a1' -MsgCreated $script:ADFuture -CallId 'call_t5a1' -Status 'completed' -ChildId $wid5 -Nx $case5.nx -PromptOverride 'unrelated prompt without bindings')
$r5 = Invoke-ADDriver -Case $case5
Assert-ADNoDispatch -R $r5 -Name 'T5'
Assert-That ([string](Get-ADField $r5 'reason' '') -ceq 'auto-worker-operation-mismatch') 'T5: task-incompatible prompt => auto-worker-operation-mismatch'
# --- T7: foreign project child => operation-mismatch ---
$case7 = New-ADCase -Tag 't7' -GoalId 'ghwad-goal-t7' -TaskId 'ghwad-task-t7' -Evt 'evt-ghwad-t7'
Reset-ADApi
$wid7 = 'ses_AutoDispatchW07'
$script:ADApi.post = @(New-ADChild -Id $wid7 -Parent $script:SID -Proj 'proj-foreign-9' -Created $script:ADFuture -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t7a1' -MsgCreated $script:ADFuture -CallId 'call_t7a1' -Status 'completed' -ChildId $wid7 -Nx $case7.nx)
$r7 = Invoke-ADDriver -Case $case7
Assert-ADNoDispatch -R $r7 -Name 'T7'
Assert-That ([string](Get-ADField $r7 'reason' '') -ceq 'auto-worker-operation-mismatch') 'T7: foreign project child => auto-worker-operation-mismatch'
# --- T8: completed tool without structured content => result-unproven ---
$case8 = New-ADCase -Tag 't8' -GoalId 'ghwad-goal-t8' -TaskId 'ghwad-task-t8' -Evt 'evt-ghwad-t8'
Reset-ADApi
$wid8 = 'ses_AutoDispatchW08'
$script:ADApi.post = @(New-ADChild -Id $wid8 -Parent $script:SID -Proj $script:PROJ -Created $script:ADFuture -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t8a1' -MsgCreated $script:ADFuture -CallId 'call_t8a1' -Status 'completed' -ChildId $wid8 -Nx $case8.nx -WithContent $false)
$r8 = Invoke-ADDriver -Case $case8
Assert-ADNoDispatch -R $r8 -Name 'T8'
Assert-That ([string](Get-ADField $r8 'reason' '') -ceq 'auto-worker-result-unproven') 'T8: contentless tool result => auto-worker-result-unproven'
# --- T9: running (not completed) tool => unproven ---
$case9 = New-ADCase -Tag 't9' -GoalId 'ghwad-goal-t9' -TaskId 'ghwad-task-t9' -Evt 'evt-ghwad-t9'
Reset-ADApi
$wid9 = 'ses_AutoDispatchW09'
$script:ADApi.post = @(New-ADChild -Id $wid9 -Parent $script:SID -Proj $script:PROJ -Created $script:ADFuture -Outcome 'succeeded')
$script:ADApi.msgs = @(New-ADToolMsg -MsgId 'msg_t9a1' -MsgCreated $script:ADFuture -CallId 'call_t9a1' -Status 'running' -ChildId $wid9 -Nx $case9.nx)
$r9 = Invoke-ADDriver -Case $case9
Assert-ADNoDispatch -R $r9 -Name 'T9'
Assert-That ([string](Get-ADField $r9 'reason' '') -ceq 'auto-worker-unproven') 'T9: running tool is not proof => auto-worker-unproven'
# --- T10: resume timeout reconciles with zero settle ---
$case10 = New-ADCase -Tag 't10' -GoalId 'ghwad-goal-t10' -TaskId 'ghwad-task-t10' -Evt 'evt-ghwad-t10'
Reset-ADApi
$script:mockRunCalls = 0
$mockTimeout = {
    param($spec)
    $script:mockRunCalls++
    return [pscustomobject]@{ exit = -1; stdout = ''; stderr = 'TIMEOUT'; timedOut = $true }
}
$e10 = $case10.env; $nx10 = $case10.nx
$prompt10 = ('resume goal ghwad-goal-t10 task ghwad-task-t10 checkpoint ' + [string](Get-ADField $nx10 'checkpoint_id' '') + ' generation 1')
$r10 = Invoke-GHWakeAutoDispatch -NextAction $nx10 -WaitsDir $e10.waitsDir -TasksDir $e10.tasksDir -GoalStoreDir $e10.goalDir -CheckpointDir $e10.ckptDir -FlagsPath $e10.flagsPath -NowUtc $script:NOW -HandoffStateDir $e10.ckptDir -ReceiptDir $e10.receiptDir -RepoRoot $e10.root -ResumeSessionId $script:SID -ExpectedDirectory $e10.root -ExpectedProjectId $script:PROJ -PromptText $prompt10 -ControllerProbe $script:probe -RunExecutor $mockTimeout -SessionApiInvoker $script:ADApiMock -SettleResultSummary 'auto dispatch timeout proof'
Assert-That ([int]$script:mockRunCalls -eq 1) 'T10: single attempt counted once, never resent'
Assert-That ([int]@($script:ADApi.calls).Count -ge 1) 'T10: pre-snapshot happened before the run'
Assert-ADNoDispatch -R $r10 -Name 'T10'
Assert-That ([string](Get-ADField $r10 'decision' '') -ceq 'reconcile') 'T10: decision reconcile'
Assert-That ([string](Get-ADField $r10 'reason' '') -ceq 'auto-reconcile-timeout-unknown') 'T10: stable timeout-unknown reason'
# --- T11: executor throws => resume-unproven, claim kept, no settle ---
$case11 = New-ADCase -Tag 't11' -GoalId 'ghwad-goal-t11' -TaskId 'ghwad-task-t11' -Evt 'evt-ghwad-t11'
Reset-ADApi
$script:mockRunCalls = 0
$mockThrow = {
    param($spec)
    $script:mockRunCalls++
    throw 'boom-executor'
}
$e11 = $case11.env; $nx11 = $case11.nx
$prompt11 = ('resume goal ghwad-goal-t11 task ghwad-task-t11 checkpoint ' + [string](Get-ADField $nx11 'checkpoint_id' '') + ' generation 1')
$r11 = Invoke-GHWakeAutoDispatch -NextAction $nx11 -WaitsDir $e11.waitsDir -TasksDir $e11.tasksDir -GoalStoreDir $e11.goalDir -CheckpointDir $e11.ckptDir -FlagsPath $e11.flagsPath -NowUtc $script:NOW -HandoffStateDir $e11.ckptDir -ReceiptDir $e11.receiptDir -RepoRoot $e11.root -ResumeSessionId $script:SID -ExpectedDirectory $e11.root -ExpectedProjectId $script:PROJ -PromptText $prompt11 -ControllerProbe $script:probe -RunExecutor $mockThrow -SessionApiInvoker $script:ADApiMock -SettleResultSummary 'auto dispatch throw proof'
Assert-That ([int]$script:mockRunCalls -eq 1) 'T11: single attempt counted once, never resent'
Assert-ADNoDispatch -R $r11 -Name 'T11'
Assert-That ([string](Get-ADField $r11 'reason' '') -ceq 'auto-reconcile-resume-unproven') 'T11: throw => resume-unproven reconcile'
$marker11 = ([string](Get-ADField $r11 'marker_path' '')).Trim()
Assert-That ([string](Get-ADField (ConvertFrom-Json ([IO.File]::ReadAllText($marker11, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') 'T11: marker stays claimed'
# --- N5 + V: pure validator/parser unit tests (shape logic only, never settlement) ---
# N5 is the structural positive: a fully-shaped native evidence set
# (distinct worker, parent link, exact operation result, agreed status).
# Synthetic fixtures test ONLY the pure parser; no mock ever settles.
function New-VChild {
    param([string]$Id = '', [string]$Parent = '', [string]$Proj = '', [long]$Created = 0, $Outcome = 'succeeded')
    return [pscustomobject]@{ id = $Id; parentID = $Parent; projectID = $Proj; agent = 'coder'; outcome = $Outcome; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
}
function New-VResultJson {
    param([string]$TaskId = 'vt-1', [string]$GoalId = 'vg-1', [string]$Gen = '1', [string]$Key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', [string]$Status = 'candidate_pass')
    return ('{"task_id":"' + $TaskId + '","goal_id":"' + $GoalId + '","generation":"' + $Gen + '","idempotency_key":"' + $Key + '","status":"' + $Status + '","claimed_evidence":["criterion:0","criterion:1"]}')
}
function New-VMsg {
    param([string]$ChildId = '', [long]$Created = 0, [string]$Status = 'completed', [string]$Prompt = '', [string]$ResultJson = '', [bool]$WithContent = $true)
    $c = $null
    if ([bool]$WithContent) {
        $rj = $ResultJson
        if ([string]::IsNullOrWhiteSpace($rj)) { $rj = New-VResultJson }
        $c = @(@{ type = 'text'; text = ('worker report ' + $rj + ' done') })
    }
    return [pscustomobject]@{ id = 'msg_v1'; type = 'assistant'; time = [pscustomobject]@{ created = [long]$Created }; content = @(@{ type = 'tool'; id = 'call_v1'; name = 'subagent'; state = @{ status = $Status; input = @{ agent = 'coder'; description = 'd'; prompt = $Prompt; sessionID = $ChildId }; metadata = @{ sessionID = $ChildId; status = 'completed'; truncated = $false }; content = $c }; time = @{ created = [long]$Created } }) }
}
$vRunStart = 1000
$vMarkerFull = New-GHWADOperationMarker -GoalId 'vg-1' -TaskId 'vt-1' -Generation '1' -IdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Assert-That (-not [string]::IsNullOrWhiteSpace($vMarkerFull)) 'N5 setup: exact operation marker builds'
$vPromptFull = ('run it ' + $vMarkerFull + ' now')
# --- N5: structural positive on the complete shape ---
$vChildOk = New-VChild -Id 'ses_VWorker01' -Parent $script:SID -Proj $script:PROJ -Created 2000 -Outcome 'succeeded'
$vMsgOk = New-VMsg -ChildId 'ses_VWorker01' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson)
$vById = @{ 'ses_VWorker01' = $vChildOk }
$n5 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById $vById -Messages @($vMsgOk) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([bool](Get-ADField $n5 'ok' $false)) 'N5: full structured native shape validates'
Assert-That ([string](Get-ADField $n5 'worker_session_id' '') -ceq 'ses_VWorker01') 'N5: worker id extracted from native evidence'
Assert-That ([string](Get-ADField $n5 'worker_session_id' '') -cne $script:SID) 'N5: worker identity distinct from resume identity'
Assert-That ([bool](Get-ADField $n5 'result_ok' $false)) 'N5: succeeded outcome + candidate_pass status => result_ok'
$vChildFail = New-VChild -Id 'ses_VWorker02' -Parent $script:SID -Proj $script:PROJ -Created 2000 -Outcome 'failed'
$vMsgFail = New-VMsg -ChildId 'ses_VWorker02' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson -Status 'failed')
$v2 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker02' = $vChildFail } -Messages @($vMsgFail) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([bool](Get-ADField $v2 'ok' $false)) 'V2: failed worker still proves execution'
Assert-That (-not [bool](Get-ADField $v2 'result_ok' $true)) 'V2: failed outcome + failed status => result_ok false'
$vChildPar = New-VChild -Id 'ses_VWorker03' -Parent 'ses_OtherParent01' -Proj $script:PROJ -Created 2000 -Outcome 'succeeded'
$vMsgPar = New-VMsg -ChildId 'ses_VWorker03' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson)
$v3 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker03' = $vChildPar } -Messages @($vMsgPar) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v3 'reason' '') -ceq 'auto-worker-parent-mismatch') 'V3: divergent parent => parent-mismatch'
$vChildStale = New-VChild -Id 'ses_VWorker04' -Parent $script:SID -Proj $script:PROJ -Created 500 -Outcome 'succeeded'
$vMsgStale = New-VMsg -ChildId 'ses_VWorker04' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson)
$v4 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker04' = $vChildStale } -Messages @($vMsgStale) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v4 'reason' '') -ceq 'auto-worker-operation-mismatch') 'V4: stale child time => operation-mismatch'
$vChildNoOut = New-VChild -Id 'ses_VWorker05' -Parent $script:SID -Proj $script:PROJ -Created 2000 -Outcome $null
$vMsgNoOut = New-VMsg -ChildId 'ses_VWorker05' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson)
$v5 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker05' = $vChildNoOut } -Messages @($vMsgNoOut) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v5 'reason' '') -ceq 'auto-worker-result-unproven') 'V5: missing outcome => result-unproven'
$vChildMismatch = New-VChild -Id 'ses_VWorker06' -Parent $script:SID -Proj $script:PROJ -Created 2000 -Outcome 'succeeded'
$vMsgMismatch = New-VMsg -ChildId 'ses_VWorker06' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson -Status 'verified_pass')
$v5b = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker06' = $vChildMismatch } -Messages @($vMsgMismatch) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v5b 'reason' '') -ceq 'auto-worker-result-unproven') 'V5b: non-worker status (verified_pass) => result-unproven'
$vChildWrongOp = New-VChild -Id 'ses_VWorker07' -Parent $script:SID -Proj $script:PROJ -Created 2000 -Outcome 'succeeded'
$vMsgWrongOp = New-VMsg -ChildId 'ses_VWorker07' -Created 2000 -Status 'completed' -Prompt $vPromptFull -ResultJson (New-VResultJson -TaskId 'vt-other')
$v5c = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @() -PostChildrenById @{ 'ses_VWorker07' = $vChildWrongOp } -Messages @($vMsgWrongOp) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v5c 'reason' '') -ceq 'auto-worker-result-unproven') 'V5c: result bound to another operation => result-unproven'
$v6 = Find-GHWADNativeWorkerProof -ResumeSessionId $script:SID -PreChildIds @('ses_VWorker01') -PostChildrenById $vById -Messages @($vMsgOk) -ExpectedTaskId 'vt-1' -ExpectedGoalId 'vg-1' -ExpectedGeneration '1' -ExpectedIdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ExpectedProjectId $script:PROJ -RunStartMs $vRunStart
Assert-That ([string](Get-ADField $v6 'reason' '') -ceq 'auto-worker-unproven') 'V6: pre-existing child excluded => unproven'
Assert-That (-not (Test-GHWADPromptFits -PromptText (('x' * 2001)))) 'VF: over-length prompt never fits'
Assert-That ([string](New-GHWADOperationMarker -GoalId 'bad goal!' -TaskId 'vt-1' -Generation '1' -IdempotencyKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') -ceq '') 'VF: marker with bad charset never builds'
Write-Output ('GREEN: github-wake-auto-dispatch native proof suite passed (' + [string]$script:passed + ' checks)')
