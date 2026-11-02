# github-wake-auto-dispatch-negatives.tests.ps1 -- driver refusal suite.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only: no gh, no network,
# no real opencode, no live run, no model quota. Every call injects a
# synthetic session-API transport (non-native), so NOTHING here can
# settle: all cases assert reconcile/not-dispatched with dispatched=false.
# Covers the paths outside the worker-proof matrix: native transport
# failure before the run (zero executor effect), after the run, message
# read failure, claimed-marker replay (duplicate-noop, no second run),
# KEEP_WAITING no-op (no next_action, no API, no run), invalid session
# (claim released), and handoff refusal (generation mismatch, no claim
# consumed). Fail-closed: every refusal keeps a stable reason and never
# invents execution. ASCII only.
$ErrorActionPreference = 'Stop'
$script:negCli = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:negCli -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found (expected before GREEN)' }
. $script:negCli
$script:passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-NEGField {
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
$negText = [IO.File]::ReadAllText($script:negCli, [Text.Encoding]::UTF8)
foreach ($bad in @('while\s*\(', 'Start-Job', 'Start-Sleep', 'Start-Process', 'System\.Timers', 'Register-ObjectEvent', 'FileSystemWatcher', 'Register-ScheduledTask', 'Start-Service', 'New-Service', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', '--continue', '--fork', 'GH_TOKEN', 'GITHUB_TOKEN', 'WorkerSessionId', 'Test-GHWakeWorkerProof', 'C:\\Users')) {
    Assert-That ($negText -cnotmatch $bad) ('auto dispatch has no daemon/spawn/self-attestation pattern: ' + $bad)
}
foreach ($need in @('Invoke-GHWakeControllerHandoff', 'Invoke-OrchestrationNativeResume', 'Find-GHWADNativeWorkerProof', 'Find-GHWADWorkerResultObject', 'New-GHWADOperationMarker', 'Get-GHWADChildSnapshot', 'session.list', 'session.message.list', 'SessionApiInvoker', 'reconcile', 'auto-worker-api-unavailable', 'auto-worker-non-native', 'auto-replay-unproven', 'auto-prompt-unfittable', 'duplicate-noop', 'Remove-GHWakeHandoffClaim')) {
    Assert-That ($negText -cmatch [regex]::Escape($need)) ('auto dispatch pins required surface: ' + $need)
}
Assert-That ($negText -cmatch 'proceed') 'auto dispatch names the proceed gate'
$script:negLibDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $script:negLibDir 'OrchestrationGoalKernel.ps1')
. (Join-Path $script:negLibDir 'OrchestrationTaskKernel.ps1')
. (Join-Path $script:negLibDir 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $script:negLibDir 'OrchestrationGitHubResume.ps1')
$script:negPolicy = $null
try { $script:negPolicy = Get-OrchestrationDeliveryPolicy $null } catch { $script:negPolicy = $null }
if ($null -eq $script:negPolicy) { throw 'FAIL: delivery policy unavailable' }
$script:negReqChecks = @()
try { $script:negReqChecks = @(Get-OrchestrationDeliveryRequiredChecks $script:negPolicy) } catch { $script:negReqChecks = @() }
Assert-That (@($script:negReqChecks).Count -gt 0) 'policy carries required checks'
$script:NEG_SHA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:NEG_NOW = '2026-10-10T12:02:00Z'
$script:NEG_FUTURE = '2027-06-01T00:00:00Z'
$script:NEG_REPO = 'acme/widgets'
$script:NEG_SID = 'ses_NegDispatch001'
$script:NEG_PROJ = 'proj-neg-1'
function New-NEGEnv {
    param([string]$Tag = 'n')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwneg-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-NEGGoal {
    param($Env, [string]$GoalId = 'neg-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d negatives' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-NEGField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-NEGField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-NEGField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-NEGField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-NEGField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-NEGField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-NEGField $own 'ok' $false)) { throw 'goal-ownership' }
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-ghwneg' -ReadScopes @('src/ghwneg.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-NEGField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $gen = [long](Get-NEGField (Get-NEGField $own 'ownership' $null) 'generation' 0)
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-NEGField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
}
function Set-NEGBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:NEG_REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-NEGField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-NEGField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-NEGField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-NEGField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-NEGField $tr 'error' '')) }
}
function New-NEGWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'neg-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-ghwneg' -Generation 1 -Repository $script:NEG_REPO -PrNumber $Pr -Branch 'fix/ghwneg' -ExpectedHeadSha $Sha -RequiredChecks @($script:negReqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:NEG_FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:NEG_FUTURE -Owner 'planner-1'
    if (-not [bool](Get-NEGField $reg 'ok' $false)) { throw ('wait:' + [string](Get-NEGField $reg 'reason' '')) }
}
function New-NEGCkpt {
    param($Env, [string]$GoalId = 'neg-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-NEGField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-NEGField $sv 'checkpoint_id' '')
}
function New-NEGNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-NEGRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:NEG_REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-NEGFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-NEGGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:negReqChecks)) { $out += @(New-NEGNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Invoke-NEGWake {
    param($Env, [string]$Fixture = '', [string]$Evt = 'evt-ghwneg-1')
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:negPolicy -GraphQLSnapshotFile $Fixture -EventId $Evt -MaxAgeSeconds 300 -NowUtc $script:NEG_NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
}
function New-NEGCase {
    param([string]$Tag = 'n', [string]$GoalId = 'neg-goal-1', [string]$TaskId = 'neg-task-1', [string]$Evt = 'evt-ghwneg-1')
    $env = New-NEGEnv -Tag $Tag
    $script:NEGBindDir = $env.root
    [void](New-NEGGoal -Env $env -GoalId $GoalId -Tasks @($TaskId))
    Set-NEGBlocked -Env $env -TaskId $TaskId -Sha $script:NEG_SHA
    New-NEGWait -Env $env -TaskId $TaskId -Sha $script:NEG_SHA -GoalId $GoalId
    [void](New-NEGCkpt -Env $env -GoalId $GoalId)
    $fx = Write-NEGFixture -Env $env -Raw (New-NEGRaw -Nodes (New-NEGGreenNodes $script:NEG_SHA) -Head $script:NEG_SHA -Commit $script:NEG_SHA) -Name 'green.graphql.json'
    $w = Invoke-NEGWake -Env $env -Fixture $fx -Evt $Evt
    $nx = Get-NEGField $w 'next_action' $null
    if ($null -eq $nx) { throw ('neg-case-setup-missing-next-action:' + $Tag) }
    return @{ env = $env; nx = $nx }
}
# --- stub session identity: offline binding, no process spawn ---
$script:NEGBindSid = $script:NEG_SID
$script:NEGBindProj = $script:NEG_PROJ
$script:NEGBindDir = ''
function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = 'opencode', [int]$TimeoutMs = 30000)
    try {
        $s = (([string]$SessionId).Trim())
        if (($s -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($s -match 'continue')) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = 'stub:bad-id'; session = $null }
        }
        if ($s -cne $script:NEGBindSid) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
        }
        if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne $script:NEGBindProj)) {
            return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
        }
        $sess = [pscustomobject]@{ id = $script:NEGBindSid; title = 'neg-binding'; created = 0; updated = 0; directory = $script:NEGBindDir; projectId = $script:NEGBindProj }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
    }
}
# --- synthetic native API transport (injected => NEVER settles) ---
$script:NEGApi = @{ pre = @(); post = @(); msgs = @(); fail = ''; calls = @(); lists = 0 }
$script:NEGApiMock = {
    param($Operation, $Params)
    $script:NEGApi.calls += @(([string]$Operation))
    if (([string]$Operation) -ceq 'session.list') {
        $script:NEGApi.lists++
        if (([string]$script:NEGApi.fail) -ceq 'pre' -and ([int]$script:NEGApi.lists) -eq 1) {
            return [pscustomobject]@{ ok = $false }
        }
        if (([string]$script:NEGApi.fail) -ceq 'post' -and ([int]$script:NEGApi.lists) -ge 2) {
            return [pscustomobject]@{ ok = $false }
        }
        $arr = @($script:NEGApi.pre)
        if ([int]$script:NEGApi.lists -ge 2) { $arr = @($script:NEGApi.post) }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = $arr; cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    if (([string]$Operation) -ceq 'session.message.list') {
        if (([string]$script:NEGApi.fail) -ceq 'msg') {
            return [pscustomobject]@{ ok = $false }
        }
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @($script:NEGApi.msgs); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    return [pscustomobject]@{ ok = $false }
}
$script:negProbe = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$script:negRunCalls = 0
$script:negMockRun = {
    param($spec)
    $script:negRunCalls++
    $body = ('{"sessionId":"' + $script:NEG_SID + '","role":"assistant","type":"text"}')
    return [pscustomobject]@{ exit = 0; stdout = $body; stderr = ''; timedOut = $false }
}
function Reset-NEGApi {
    $script:NEGApi.pre = @(); $script:NEGApi.post = @(); $script:NEGApi.msgs = @()
    $script:NEGApi.fail = ''; $script:NEGApi.calls = @(); $script:NEGApi.lists = 0
    $script:negRunCalls = 0
}
function Invoke-NEGDriver {
    param($Case, [string]$Summary = 'neg proof run', $RunExecutor = $null)
    $e = $Case.env; $nx = $Case.nx
    $exec = $RunExecutor
    if ($null -eq $exec) { $exec = $script:negMockRun }
    $prompt = ('resume goal ' + [string](Get-NEGField $nx 'goal_id' '') + ' task ' + [string](Get-NEGField $nx 'task_id' '') + ' checkpoint ' + [string](Get-NEGField $nx 'checkpoint_id' '') + ' generation ' + [string](Get-NEGField $nx 'generation' '1'))
    return (Invoke-GHWakeAutoDispatch -NextAction $nx -WaitsDir $e.waitsDir -TasksDir $e.tasksDir -GoalStoreDir $e.goalDir -CheckpointDir $e.ckptDir -FlagsPath $e.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $e.ckptDir -ReceiptDir $e.receiptDir -RepoRoot $e.root -ResumeSessionId $script:NEG_SID -ExpectedDirectory $e.root -ExpectedProjectId $script:NEG_PROJ -PromptText $prompt -ControllerProbe $script:negProbe -RunExecutor $exec -SessionApiInvoker $script:NEGApiMock -SettleResultSummary $Summary)
}
function Assert-NEGNoDispatch {
    param($R, [string]$Name = '')
    Assert-That (-not [bool](Get-NEGField $R 'dispatched' $true)) ($Name + ': never dispatched')
    Assert-That (-not [bool](Get-NEGField $R 'executed' $true)) ($Name + ': never marked executed')
    Assert-That ((-not [bool](Get-NEGField $R 'grants_authority' $true)) -and (-not [bool](Get-NEGField $R 'done_approved' $true)) -and (-not [bool](Get-NEGField $R 'merge_authority' $true))) ($Name + ': authority pins stay false')
}
function Assert-NEGClaimed {
    param($R, [string]$Name = '')
    $mk = ([string](Get-NEGField $R 'marker_path' '')).Trim()
    Assert-That ((-not [string]::IsNullOrWhiteSpace($mk)) -and (Test-Path -LiteralPath $mk -PathType Leaf)) ($Name + ': claim marker kept')
    Assert-That ([string](Get-NEGField (ConvertFrom-Json ([IO.File]::ReadAllText($mk, [Text.Encoding]::UTF8))) 'status' '') -ceq 'claimed') ($Name + ': marker stays claimed')
}
# --- A: pre-run transport failure => zero executor effect, reconcile ---
$caseA = New-NEGCase -Tag 'a' -GoalId 'neg-goal-a' -TaskId 'neg-task-a' -Evt 'evt-ghwneg-a'
Reset-NEGApi
$script:NEGApi.fail = 'pre'
$rA = Invoke-NEGDriver -Case $caseA
Assert-That ([int]$script:negRunCalls -eq 0) 'A: pre-snapshot failure runs nothing'
Assert-That ([int]@($script:NEGApi.calls).Count -ge 1) 'A: the failed read is the pre-snapshot'
Assert-NEGNoDispatch -R $rA -Name 'A'
Assert-That ([string](Get-NEGField $rA 'decision' '') -ceq 'reconcile') 'A: decision reconcile'
Assert-That ([string](Get-NEGField $rA 'reason' '') -ceq 'auto-worker-api-unavailable') 'A: stable api-unavailable reason'
Assert-NEGClaimed -R $rA -Name 'A'
# --- B: post-run transport failure => reconcile, no settle ---
$caseB = New-NEGCase -Tag 'b' -GoalId 'neg-goal-b' -TaskId 'neg-task-b' -Evt 'evt-ghwneg-b'
Reset-NEGApi
$script:NEGApi.fail = 'post'
$rB = Invoke-NEGDriver -Case $caseB
Assert-That ([int]$script:negRunCalls -eq 1) 'B: single resume run counted once, never resent'
Assert-NEGNoDispatch -R $rB -Name 'B'
Assert-That ([string](Get-NEGField $rB 'reason' '') -ceq 'auto-worker-api-unavailable') 'B: stable api-unavailable reason'
Assert-NEGClaimed -R $rB -Name 'B'
# --- C: message read failure => reconcile, no settle ---
$caseC = New-NEGCase -Tag 'c' -GoalId 'neg-goal-c' -TaskId 'neg-task-c' -Evt 'evt-ghwneg-c'
Reset-NEGApi
$script:NEGApi.fail = 'msg'
$rC = Invoke-NEGDriver -Case $caseC
Assert-That ([int]$script:negRunCalls -eq 1) 'C: single resume run counted once, never resent'
Assert-NEGNoDispatch -R $rC -Name 'C'
Assert-That ([string](Get-NEGField $rC 'reason' '') -ceq 'auto-worker-api-unavailable') 'C: stable api-unavailable reason'
Assert-NEGClaimed -R $rC -Name 'C'
# --- D: claimed replay => duplicate-noop, no second run ---
$caseD = New-NEGCase -Tag 'd' -GoalId 'neg-goal-d' -TaskId 'neg-task-d' -Evt 'evt-ghwneg-d'
Reset-NEGApi
$rD1 = Invoke-NEGDriver -Case $caseD
Assert-That ([int]$script:negRunCalls -eq 1) 'D: first pass runs once'
Assert-That ([string](Get-NEGField $rD1 'reason' '') -ceq 'auto-worker-unproven') 'D: first pass reconciles unproven'
$rD2 = Invoke-NEGDriver -Case $caseD
Assert-That ([int]$script:negRunCalls -eq 1) 'D: replay runs nothing more'
Assert-NEGNoDispatch -R $rD2 -Name 'D'
Assert-That ([bool](Get-NEGField $rD2 'duplicate' $false)) 'D: duplicate flagged'
Assert-That ([string](Get-NEGField $rD2 'reason' '') -ceq 'duplicate-noop') 'D: stable duplicate-noop reason'
# --- E: KEEP_WAITING produces no next_action and no native/API effect ---
$eE = New-NEGEnv -Tag 'e'
$script:NEGBindDir = $eE.root
[void](New-NEGGoal -Env $eE -GoalId 'neg-goal-e' -Tasks @('neg-task-e'))
Set-NEGBlocked -Env $eE -TaskId 'neg-task-e' -Sha $script:NEG_SHA
New-NEGWait -Env $eE -TaskId 'neg-task-e' -Sha $script:NEG_SHA -GoalId 'neg-goal-e'
[void](New-NEGCkpt -Env $eE -GoalId 'neg-goal-e')
$pendNodes = New-NEGGreenNodes $script:NEG_SHA
$pendNodes[0] = New-NEGNode $script:negReqChecks[0] 'IN_PROGRESS' $null $script:NEG_SHA
$fxE = Write-NEGFixture -Env $eE -Raw (New-NEGRaw -Nodes $pendNodes -Head $script:NEG_SHA -Commit $script:NEG_SHA) -Name 'pending.graphql.json'
$wE = Invoke-NEGWake -Env $eE -Fixture $fxE -Evt 'evt-ghwneg-e'
$itemsE = @(Get-NEGField $wE 'items' @())
Assert-That ([string](Get-NEGField @($itemsE)[0] 'decision' '') -ceq 'KEEP_WAITING') 'E: pending checks keep waiting'
Assert-That ($null -eq (Get-NEGField $wE 'next_action' $null)) 'E: waiting wake carries no next_action'
Assert-That ([string](Get-OrchestrationTask -TaskId 'neg-task-e' -TasksDir $eE.tasksDir -RepoRoot $eE.root).state -ceq 'BLOCKED') 'E: pending task stays blocked'
Reset-NEGApi
$script:negRunCalls = 0
$rE = Invoke-GHWakeAutoDispatch -NextAction $null -WaitsDir $eE.waitsDir -TasksDir $eE.tasksDir -GoalStoreDir $eE.goalDir -CheckpointDir $eE.ckptDir -FlagsPath $eE.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $eE.ckptDir -ReceiptDir $eE.receiptDir -RepoRoot $eE.root -ResumeSessionId $script:NEG_SID -ExpectedDirectory $eE.root -ExpectedProjectId $script:NEG_PROJ -PromptText '' -ControllerProbe $script:negProbe -RunExecutor $script:negMockRun -SessionApiInvoker $script:NEGApiMock -SettleResultSummary 'neg e proof'
Assert-NEGNoDispatch -R $rE -Name 'E'
Assert-That ([string](Get-NEGField $rE 'decision' '') -ceq 'not-dispatched') 'E: decision not-dispatched'
Assert-That ([string](Get-NEGField $rE 'reason' '') -ceq 'auto-invalid-next-action') 'E: stable invalid-next-action reason'
Assert-That ([int]$script:negRunCalls -eq 0) 'E: zero runs invoked'
Assert-That ([int]@($script:NEGApi.calls).Count -eq 0) 'E: zero native reads without an operation'
# --- F: invalid resume session => claim released, no run, no API ---
$caseF = New-NEGCase -Tag 'f' -GoalId 'neg-goal-f' -TaskId 'neg-task-f' -Evt 'evt-ghwneg-f'
Reset-NEGApi
$script:negRunCalls = 0
$eF = $caseF.env; $nxF = $caseF.nx
$promptF = ('resume goal neg-goal-f task neg-task-f checkpoint ' + [string](Get-NEGField $nxF 'checkpoint_id' '') + ' generation 1')
$rF = Invoke-GHWakeAutoDispatch -NextAction $nxF -WaitsDir $eF.waitsDir -TasksDir $eF.tasksDir -GoalStoreDir $eF.goalDir -CheckpointDir $eF.ckptDir -FlagsPath $eF.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $eF.ckptDir -ReceiptDir $eF.receiptDir -RepoRoot $eF.root -ResumeSessionId 'bad id with spaces' -ExpectedDirectory $eF.root -ExpectedProjectId $script:NEG_PROJ -PromptText $promptF -ControllerProbe $script:negProbe -RunExecutor $script:negMockRun -SessionApiInvoker $script:NEGApiMock -SettleResultSummary 'neg f proof'
Assert-NEGNoDispatch -R $rF -Name 'F'
Assert-That ([string](Get-NEGField $rF 'reason' '') -ceq 'auto-session-invalid') 'F: stable session-invalid reason'
Assert-That ([int]$script:negRunCalls -eq 0) 'F: zero runs invoked'
Assert-That ([int]@($script:NEGApi.calls).Count -eq 0) 'F: zero native reads on invalid session'
# --- G: tampered generation never runs, never reads native state ---
$caseG = New-NEGCase -Tag 'g' -GoalId 'neg-goal-g' -TaskId 'neg-task-g' -Evt 'evt-ghwneg-g'
Reset-NEGApi
$script:negRunCalls = 0
$badG = ConvertFrom-Json (ConvertTo-Json -InputObject $caseG.nx -Depth 20)
$badG.generation = ([long](Get-NEGField $caseG.nx 'generation' 1) + 99)
$eG = $caseG.env
$promptG = ('resume goal neg-goal-g task neg-task-g checkpoint ' + [string](Get-NEGField $badG 'checkpoint_id' '') + ' generation 100')
$rG = Invoke-GHWakeAutoDispatch -NextAction $badG -WaitsDir $eG.waitsDir -TasksDir $eG.tasksDir -GoalStoreDir $eG.goalDir -CheckpointDir $eG.ckptDir -FlagsPath $eG.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $eG.ckptDir -ReceiptDir $eG.receiptDir -RepoRoot $eG.root -ResumeSessionId $script:NEG_SID -ExpectedDirectory $eG.root -ExpectedProjectId $script:NEG_PROJ -PromptText $promptG -ControllerProbe $script:negProbe -RunExecutor $script:negMockRun -SessionApiInvoker $script:NEGApiMock -SettleResultSummary 'neg g proof'
Assert-NEGNoDispatch -R $rG -Name 'G'
Assert-That ([string](Get-NEGField $rG 'decision' '') -ceq 'not-dispatched') 'G: decision not-dispatched'
Assert-That ([string](Get-NEGField $rG 'reason' '') -ceq 'auto-handoff-generation-mismatch') 'G: stable generation-mismatch reason'
Assert-That ([int]$script:negRunCalls -eq 0) 'G: tampered generation invokes zero runs'
Assert-That ([int]@($script:NEGApi.calls).Count -eq 0) 'G: zero native reads on refused handoff'
# --- H: mocked resume WITHOUT injected API => early non-native gate ---
# No native query is opened and no run happens: a mocked resume can never
# reach the productive settlement path, even with a live server around.
$caseH = New-NEGCase -Tag 'h' -GoalId 'neg-goal-h' -TaskId 'neg-task-h' -Evt 'evt-ghwneg-h'
Reset-NEGApi
$script:negRunCalls = 0
$eH = $caseH.env; $nxH = $caseH.nx
$promptH = ('resume goal neg-goal-h task neg-task-h checkpoint ' + [string](Get-NEGField $nxH 'checkpoint_id' '') + ' generation 1')
$rH = Invoke-GHWakeAutoDispatch -NextAction $nxH -WaitsDir $eH.waitsDir -TasksDir $eH.tasksDir -GoalStoreDir $eH.goalDir -CheckpointDir $eH.ckptDir -FlagsPath $eH.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $eH.ckptDir -ReceiptDir $eH.receiptDir -RepoRoot $eH.root -ResumeSessionId $script:NEG_SID -ExpectedDirectory $eH.root -ExpectedProjectId $script:NEG_PROJ -PromptText $promptH -ControllerProbe $script:negProbe -RunExecutor $script:negMockRun -SettleResultSummary 'neg h proof'
Assert-NEGNoDispatch -R $rH -Name 'H'
Assert-That ([string](Get-NEGField $rH 'decision' '') -ceq 'reconcile') 'H: decision reconcile'
Assert-That ([string](Get-NEGField $rH 'reason' '') -ceq 'auto-worker-non-native') 'H: mocked resume without API transport => auto-worker-non-native'
Assert-That ([int]$script:negRunCalls -eq 0) 'H: zero runs invoked (gate before any query and any run)'
Assert-NEGClaimed -R $rH -Name 'H'
# --- I: unfittable prompt (marker overflows the NativeResume gate) ---
$caseI = New-NEGCase -Tag 'i' -GoalId 'neg-goal-i' -TaskId 'neg-task-i' -Evt 'evt-ghwneg-i'
Reset-NEGApi
$script:negRunCalls = 0
$eI = $caseI.env; $nxI = $caseI.nx
$promptI = (('x' * 1900) + ' resume goal neg-goal-i task neg-task-i checkpoint')
$rI = Invoke-GHWakeAutoDispatch -NextAction $nxI -WaitsDir $eI.waitsDir -TasksDir $eI.tasksDir -GoalStoreDir $eI.goalDir -CheckpointDir $eI.ckptDir -FlagsPath $eI.flagsPath -NowUtc $script:NEG_NOW -HandoffStateDir $eI.ckptDir -ReceiptDir $eI.receiptDir -RepoRoot $eI.root -ResumeSessionId $script:NEG_SID -ExpectedDirectory $eI.root -ExpectedProjectId $script:NEG_PROJ -PromptText $promptI -ControllerProbe $script:negProbe -RunExecutor $script:negMockRun -SessionApiInvoker $script:NEGApiMock -SettleResultSummary 'neg i proof'
Assert-NEGNoDispatch -R $rI -Name 'I'
Assert-That ([string](Get-NEGField $rI 'decision' '') -ceq 'reconcile') 'I: decision reconcile'
Assert-That ([string](Get-NEGField $rI 'reason' '') -ceq 'auto-prompt-unfittable') 'I: marker-augmented prompt over the gate => auto-prompt-unfittable'
Assert-That ([int]$script:negRunCalls -eq 0) 'I: zero runs invoked'
Assert-NEGClaimed -R $rI -Name 'I'
# --- J: old dispatched marker (resume id as child, no current proof) ---
# Simulates a legacy settlement: marker says dispatched with the RESUME
# id as child, but native state carries no proof for THIS operation.
# The replay must revalidate via native API and refuse WITHOUT calling
# Settle: dispatched=false, marker bytes unchanged, no new run.
$caseJ = New-NEGCase -Tag 'j' -GoalId 'neg-goal-j' -TaskId 'neg-task-j' -Evt 'evt-ghwneg-j'
Reset-NEGApi
$rJ1 = Invoke-NEGDriver -Case $caseJ
Assert-That ([string](Get-NEGField $rJ1 'reason' '') -ceq 'auto-worker-unproven') 'J: setup pass reconciles unproven'
$markerJ = ([string](Get-NEGField $rJ1 'marker_path' '')).Trim()
$rawBefore = [IO.File]::ReadAllBytes($markerJ)
$docJ = ConvertFrom-Json ([IO.File]::ReadAllText($markerJ, [Text.Encoding]::UTF8))
$docJ.status = 'dispatched'
$docJ | Add-Member -NotePropertyName 'session_id' -NotePropertyValue $script:NEG_SID -Force
[IO.File]::WriteAllText($markerJ, (ConvertTo-Json -InputObject $docJ -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
$markerJLegacy = [IO.File]::ReadAllBytes($markerJ)
Assert-That ([int]$markerJLegacy.Length -gt 0) 'J: legacy dispatched marker staged'
Reset-NEGApi
$script:negRunCalls = 0
$eJ = $caseJ.env
$rJ2 = Invoke-NEGDriver -Case $caseJ
Assert-NEGNoDispatch -R $rJ2 -Name 'J'
Assert-That ([int]$script:negRunCalls -eq 0) 'J: replay performs no new run'
Assert-That ([string](Get-NEGField $rJ2 'decision' '') -ceq 'reconcile') 'J: decision reconcile (not duplicate-noop: proof was re-attempted)'
Assert-That ([string](Get-NEGField $rJ2 'reason' '') -ceq 'auto-replay-unproven') 'J: old marker without current native proof => auto-replay-unproven'
$rawAfter = [IO.File]::ReadAllBytes($markerJ)
Assert-That ([string]([Convert]::ToBase64String($rawAfter)) -ceq ([string]([Convert]::ToBase64String($markerJLegacy)))) 'J: marker bytes unchanged (zero Settle effects)'
Write-Output ('GREEN: github-wake-auto-dispatch negatives passed (' + [string]$script:passed + ' checks)')
