$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1')
$passed = 0
function Assert-Objective { param([bool]$Condition, [string]$Name) if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++ }
function Get-ObjectiveField {
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

# --- Pure helper: canonical resume-proof.txt Task. ---
$task = [ordered]@{
    objective = 'Create and verify resume-proof.txt inside the authorized write scope.'
    read_scopes = @('src/readme.md')
    write_scopes = @('resume-proof.txt')
    acceptance_criteria = @('Create resume-proof.txt and verify its contents.')
}
$prompt = New-GHWADTaskPrompt -Task $task
Assert-Objective ($prompt.Contains('Create and verify resume-proof.txt')) 'objective preserved'
Assert-Objective ($prompt.Contains('read_scopes: src/readme.md')) 'read scope preserved'
Assert-Objective ($prompt.Contains('write_scopes: resume-proof.txt')) 'authorized write scope preserved'
Assert-Objective ($prompt.Contains('Create resume-proof.txt and verify')) 'write action not prohibited'
Assert-Objective ($prompt.Contains('criterion:0')) 'criterion index included'
$marker = New-GHWADOperationMarker -GoalId 'g86' -TaskId 't86' -Generation '1' -IdempotencyKey ('a' * 32)
$full = $prompt + ' ' + $marker + ' ' + (Get-GHWADWorkerDirective)
Assert-Objective (Test-GHWADPromptFits -PromptText $full) 'full task prompt and directive pass prompt gate'
Assert-Objective ($full.Contains($marker)) 'operation marker preserved'
Assert-Objective ($full.Contains('Verification, review, and DONE run only after settlement.')) 'settlement directive preserved'
Assert-Objective ($null -eq (New-GHWADTaskPrompt -Task @{ objective = ''; read_scopes = @(); write_scopes = @(); acceptance_criteria = @('x') })) 'missing objective fails closed'
# Canonical criterion tokens are not duplicated.
$taskCanonical = [ordered]@{
    objective = 'Create and verify resume-proof.txt inside the authorized write scope.'
    read_scopes = @('src/readme.md')
    write_scopes = @('resume-proof.txt')
    acceptance_criteria = @('criterion:0')
}
$promptCanonical = New-GHWADTaskPrompt -Task $taskCanonical
Assert-Objective ($promptCanonical.Contains('criterion:0')) 'canonical criterion preserved'
Assert-Objective (-not $promptCanonical.Contains('criterion:0 criterion:0')) 'canonical criterion not duplicated'
# Scopes that sanitization would rewrite fail closed instead of corrupting.
Assert-Objective ($null -eq (New-GHWADTaskPrompt -Task @{ objective = 'Create resume-proof.txt'; read_scopes = @('src/*.ps1'); write_scopes = @('resume-proof.txt'); acceptance_criteria = @('criterion:0') })) 'glob read scope fails closed'
Assert-Objective ($null -eq (New-GHWADTaskPrompt -Task @{ objective = 'Create resume-proof.txt'; read_scopes = @('docs\a.md'); write_scopes = @('resume-proof.txt'); acceptance_criteria = @('criterion:0') })) 'backslash scope fails closed'
Assert-Objective ($null -eq (New-GHWADTaskPrompt -Task @{ objective = 'Create resume-proof.txt'; read_scopes = @('src/a.md'); write_scopes = @('a,b'); acceptance_criteria = @('criterion:0') })) 'comma scope fails closed'
Assert-Objective ($null -eq (New-GHWADTaskPrompt -Task @{ objective = 'Create resume-proof.txt'; read_scopes = @('scripts/v3/**'); write_scopes = @('resume-proof.txt'); acceptance_criteria = @('criterion:0') })) 'globstar scope fails closed'
# Empty scopes render explicitly as none (never ambiguous blank).
$promptEmptyScopes = New-GHWADTaskPrompt -Task @{ objective = 'Create resume-proof.txt'; read_scopes = @(); write_scopes = @(); acceptance_criteria = @('criterion:0') }
Assert-Objective (($null -ne $promptEmptyScopes) -and $promptEmptyScopes.Contains('read_scopes: none') -and $promptEmptyScopes.Contains('write_scopes: none')) 'empty scopes render as none'
# Forbidden objective characters degrade safely and still fit.
$promptDirty = New-GHWADTaskPrompt -Task @{ objective = 'Create (resume-proof.txt) and verify contents!'; read_scopes = @('src/readme.md'); write_scopes = @('resume-proof.txt'); acceptance_criteria = @('criterion:0') }
Assert-Objective (($null -ne $promptDirty) -and $promptDirty.Contains('resume-proof.txt') -and (Test-GHWADPromptFits -PromptText $promptDirty)) 'dirty objective still fits gate'

# --- Dispatch level: scheduled resume with empty PromptText. ---
# Mirrors the settlement S2 wake -> auto-dispatch chain with a canonical
# resume-proof.txt Task. The captured RunExecutor prompt must carry the
# objective, scopes, criterion:0, marker and settlement directive.
$script:OBJ_SHA = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$script:OBJ_NOW = '2026-10-10T12:02:00Z'
$script:OBJ_FUTURE = '2027-06-01T00:00:00Z'
$script:OBJ_REPO = 'acme/widgets'
$script:OBJ_ROOT = 'ses_86objectiveroot01'
$script:OBJ_PROJ = 'proj86objective1'
$script:OBJ_RUN = 'run-86objective'
$script:OBJ_policy = $null
try { $script:OBJ_policy = Get-OrchestrationDeliveryPolicy $null } catch { $script:OBJ_policy = $null }
if ($null -eq $script:OBJ_policy) { throw 'FAIL: delivery policy unavailable' }
$script:OBJ_reqChecks = @()
try { $script:OBJ_reqChecks = @(Get-OrchestrationDeliveryRequiredChecks $script:OBJ_policy) } catch { $script:OBJ_reqChecks = @() }
Assert-Objective (@($script:OBJ_reqChecks).Count -gt 0) 'OBJ policy carries required checks'
function New-OBJEnv {
    param([string]$Tag = 'o')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghw86o-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $receiptDir = Join-Path $root 'receipts'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $receiptDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; receiptDir = $receiptDir; flagsPath = $flagsPath }
}
function New-OBJGoal {
    param($Env, [string]$GoalId = 'obj-goal-1', [string]$TaskId = 'obj-task-1')
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective '86 objective prompt' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-ObjectiveField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-ObjectiveField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-ObjectiveField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-ObjectiveField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-ObjectiveField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-ObjectiveField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-ObjectiveField $own 'ok' $false)) { throw 'goal-ownership' }
    $c = New-OrchestrationTask -TaskId $TaskId -Objective 'Create and verify resume-proof.txt inside the authorized write scope.' -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -BaseRevision 'rev-86o' -ReadScopes @('src/readme.md') -WriteScopes @('resume-proof.txt') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-ObjectiveField $c 'ok' $false)) { throw ('task-create:' + $TaskId) }
    $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
    $gen = [long](Get-ObjectiveField (Get-ObjectiveField $own 'ownership' $null) 'generation' 0)
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
    if (-not [bool](Get-ObjectiveField $add 'ok' $false)) { throw ('attach:' + $TaskId) }
}
function Set-OBJBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:OBJ_REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-ObjectiveField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-ObjectiveField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-ObjectiveField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-ObjectiveField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId) }
}
function New-OBJWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'obj-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId $script:OBJ_RUN -Generation 1 -Repository $script:OBJ_REPO -PrNumber $Pr -Branch 'fix/86o' -ExpectedHeadSha $Sha -RequiredChecks @($script:OBJ_reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:OBJ_FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:OBJ_FUTURE -Owner 'planner-1'
    if (-not [bool](Get-ObjectiveField $reg 'ok' $false)) { throw ('wait:' + [string](Get-ObjectiveField $reg 'reason' '')) }
}
function New-OBJCkpt {
    param($Env, [string]$GoalId = 'obj-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-ObjectiveField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-ObjectiveField $sv 'checkpoint_id' '')
}
function New-OBJNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-OBJRaw {
    param($Nodes, [string]$Head, [string]$Commit)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:OBJ_REPO; pullRequest = [pscustomobject]@{ number = 42; state = 'OPEN'; headRefOid = $Head; mergeable = 'MERGEABLE'; reviewDecision = 'APPROVED'; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function New-OBJGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:OBJ_reqChecks)) { $out += @(New-OBJNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
$script:OBJ_knownSids = @{}
function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param([string]$SessionId = '', [string]$ExpectedDirectory = '', [string]$ExpectedProjectId = '', [int]$MaxCount = 100, [string]$BinaryCommand = 'opencode', [int]$TimeoutMs = 30000)
    try {
        $s = (([string]$SessionId).Trim())
        if (($s -cnotmatch '^ses_[A-Za-z0-9]+$') -or ($s -match 'continue')) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = 'stub:bad-id'; session = $null }
        }
        if (-not $script:OBJ_knownSids.ContainsKey($s)) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:unknown-id'; session = $null }
        }
        $rec = $script:OBJ_knownSids[$s]
        if ((-not [string]::IsNullOrWhiteSpace([string]$ExpectedProjectId)) -and ([string]$ExpectedProjectId -cne [string]$rec.proj)) {
            return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; detail = 'stub:project-mismatch'; session = $null }
        }
        $sess = [pscustomobject]@{ id = $s; title = 'obj-root'; created = 0; updated = 0; directory = [string]$rec.dir; projectId = [string]$rec.proj }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $sess }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'stub:error'; session = $null }
    }
}
$script:OBJ_apiMock = {
    param($Operation, $Params)
    if (([string]$Operation) -ceq 'session.list') {
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @(); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    if (([string]$Operation) -ceq 'session.message.list') {
        return [pscustomobject]@{ ok = $true; body = [pscustomobject]@{ data = @(); cursor = [pscustomobject]@{ previous = $null; next = $null } } }
    }
    return [pscustomobject]@{ ok = $false }
}
$script:OBJ_lastPrompt = ''
$script:OBJ_runCalls = 0
$script:OBJ_runMock = {
    param($spec)
    $script:OBJ_runCalls++
    try { $script:OBJ_lastPrompt = ([string](Get-ObjectiveField $spec 'prompt' '')) } catch { $script:OBJ_lastPrompt = '' }
    $sid = ''
    try { $sid = ([string](Get-ObjectiveField $spec 'session_id' '')) } catch { $sid = '' }
    return [pscustomobject]@{ exit = 0; stdout = ('{"sessionId":"' + $sid + '","role":"assistant","type":"text"}'); stderr = ''; timedOut = $false }
}
$envObj = New-OBJEnv -Tag 'obj'
[void](New-OBJGoal -Env $envObj -GoalId 'obj-goal-1' -TaskId 'obj-task-1')
Set-OBJBlocked -Env $envObj -TaskId 'obj-task-1' -Sha $script:OBJ_SHA
New-OBJWait -Env $envObj -TaskId 'obj-task-1' -Sha $script:OBJ_SHA
[void](New-OBJCkpt -Env $envObj -GoalId 'obj-goal-1')
$fxObj = Join-Path $envObj.root 'green.graphql.json'
[IO.File]::WriteAllText($fxObj, (ConvertTo-Json -InputObject (New-OBJRaw -Nodes (New-OBJGreenNodes $script:OBJ_SHA) -Head $script:OBJ_SHA -Commit $script:OBJ_SHA) -Depth 20), (New-Object Text.UTF8Encoding $false))
$wakeObj = (Invoke-GitHubWake -WaitsDir $envObj.waitsDir -TasksDir $envObj.tasksDir -GoalStoreDir $envObj.goalDir -CheckpointDir $envObj.ckptDir -FlagsPath $envObj.flagsPath -Policy $script:OBJ_policy -GraphQLSnapshotFile $fxObj -EventId 'evt-86o-1' -MaxAgeSeconds 300 -NowUtc $script:OBJ_NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
$nxObj = Get-ObjectiveField $wakeObj 'next_action' $null
Assert-Objective ($null -ne $nxObj) 'OBJ wake produced next_action'
$script:OBJ_knownSids = @{ $script:OBJ_ROOT = @{ dir = $envObj.root; proj = $script:OBJ_PROJ } }
$script:OBJ_runCalls = 0; $script:OBJ_lastPrompt = ''
$probeObj = { param($na) return [pscustomobject]@{ dispatched = $true; reason = 'mock-dispatched' } }
$resultObj = Invoke-GHWakeAutoDispatch -NextAction $nxObj -WaitsDir $envObj.waitsDir -TasksDir $envObj.tasksDir -GoalStoreDir $envObj.goalDir -CheckpointDir $envObj.ckptDir -HandoffStateDir $envObj.ckptDir -ReceiptDir $envObj.receiptDir -RepoRoot $envObj.root -EvidenceStoreDir $envObj.receiptDir -FlagsPath $envObj.flagsPath -NowUtc $script:OBJ_NOW -ResumeSessionId $script:OBJ_ROOT -ExpectedDirectory $envObj.root -ExpectedProjectId $script:OBJ_PROJ -PromptText '' -ControllerProbe $probeObj -RunExecutor $script:OBJ_runMock -SessionApiInvoker $script:OBJ_apiMock -ProofRetryCount 1
Assert-Objective ([int]$script:OBJ_runCalls -eq 1) 'OBJ dispatch resumes exactly once with empty PromptText'
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains('resume-proof.txt')) 'OBJ captured prompt carries resume-proof.txt task'
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains('criterion:0')) 'OBJ captured prompt carries criterion:0'
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains('read_scopes:')) 'OBJ captured prompt preserves read_scopes'
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains('write_scopes: resume-proof.txt')) 'OBJ captured prompt preserves write_scopes'
$expMarkerObj = New-GHWADOperationMarker -GoalId ([string](Get-ObjectiveField $nxObj 'goal_id' '')) -TaskId ([string](Get-ObjectiveField $nxObj 'task_id' '')) -Generation ([string](Get-ObjectiveField $nxObj 'generation' '1')) -IdempotencyKey ([string](Get-ObjectiveField $nxObj 'idempotency_key' ''))
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains($expMarkerObj)) 'OBJ captured prompt carries operation marker'
Assert-Objective (([string]$script:OBJ_lastPrompt).Contains('Verification, review, and DONE run only after settlement.')) 'OBJ captured prompt carries settlement directive'
Assert-Objective (Test-GHWADPromptFits -PromptText ([string]$script:OBJ_lastPrompt)) 'OBJ captured prompt passes prompt gate'
# Fail closed before any worker when the canonical objective is gone.
$envObj2 = New-OBJEnv -Tag 'obj2'
[void](New-OBJGoal -Env $envObj2 -GoalId 'obj-goal-2' -TaskId 'obj-task-2')
Set-OBJBlocked -Env $envObj2 -TaskId 'obj-task-2' -Sha $script:OBJ_SHA
New-OBJWait -Env $envObj2 -TaskId 'obj-task-2' -Sha $script:OBJ_SHA -GoalId 'obj-goal-2'
[void](New-OBJCkpt -Env $envObj2 -GoalId 'obj-goal-2')
$fxObj2 = Join-Path $envObj2.root 'green.graphql.json'
[IO.File]::WriteAllText($fxObj2, (ConvertTo-Json -InputObject (New-OBJRaw -Nodes (New-OBJGreenNodes $script:OBJ_SHA) -Head $script:OBJ_SHA -Commit $script:OBJ_SHA) -Depth 20), (New-Object Text.UTF8Encoding $false))
$wakeObj2 = (Invoke-GitHubWake -WaitsDir $envObj2.waitsDir -TasksDir $envObj2.tasksDir -GoalStoreDir $envObj2.goalDir -CheckpointDir $envObj2.ckptDir -FlagsPath $envObj2.flagsPath -Policy $script:OBJ_policy -GraphQLSnapshotFile $fxObj2 -EventId 'evt-86o-2' -MaxAgeSeconds 300 -NowUtc $script:OBJ_NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $true -ExecutorPresent $true -ResolveOwner $true -ResolveLease $true -MaxApiAttempts 3 -TimeoutMs 10000)
$nxObj2 = Get-ObjectiveField $wakeObj2 'next_action' $null
Assert-Objective ($null -ne $nxObj2) 'OBJ2 wake produced next_action'
$taskFile2 = Join-Path $envObj2.tasksDir 'obj-task-2.json'
$taskDoc2 = ConvertFrom-Json ([IO.File]::ReadAllText($taskFile2, [Text.Encoding]::UTF8))
$taskDoc2 | Add-Member -NotePropertyName 'objective' -NotePropertyValue '' -Force
[IO.File]::WriteAllText($taskFile2, (ConvertTo-Json -InputObject $taskDoc2 -Depth 12 -Compress), (New-Object Text.UTF8Encoding $false))
$script:OBJ_knownSids[$script:OBJ_ROOT] = @{ dir = $envObj2.root; proj = $script:OBJ_PROJ }
$script:OBJ_runCalls = 0
$resultObj2 = Invoke-GHWakeAutoDispatch -NextAction $nxObj2 -WaitsDir $envObj2.waitsDir -TasksDir $envObj2.tasksDir -GoalStoreDir $envObj2.goalDir -CheckpointDir $envObj2.ckptDir -HandoffStateDir $envObj2.ckptDir -ReceiptDir $envObj2.receiptDir -RepoRoot $envObj2.root -EvidenceStoreDir $envObj2.receiptDir -FlagsPath $envObj2.flagsPath -NowUtc $script:OBJ_NOW -ResumeSessionId $script:OBJ_ROOT -ExpectedDirectory $envObj2.root -ExpectedProjectId $script:OBJ_PROJ -PromptText '' -ControllerProbe $probeObj -RunExecutor $script:OBJ_runMock -SessionApiInvoker $script:OBJ_apiMock -ProofRetryCount 1
Assert-Objective (([string](Get-ObjectiveField $resultObj2 'reason' '')) -ceq 'auto-objective-unavailable') 'OBJ2 missing objective fails closed'
Assert-Objective ([int]$script:OBJ_runCalls -eq 0) 'OBJ2 zero runs when objective missing'
$marker2 = ([string](Get-ObjectiveField $resultObj2 'marker_path' '')).Trim()
Assert-Objective ((-not [string]::IsNullOrWhiteSpace($marker2)) -and (Test-Path -LiteralPath $marker2 -PathType Leaf)) 'OBJ2 claim marker kept on objective failure'
Write-Output ('OK github-wake-86-objective (' + [string]$script:passed + ' asserts)')

