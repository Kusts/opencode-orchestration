# github-wake-solo.tests.ps1 -- Etapa 6D solo-maintainer GH-WAKE integration.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only (no live network, no gh
# required): every behavior case uses -GraphQLSnapshotFile (raw GraphQL shape
# through the REAL Convert-GHARawToSnapshot normalizer) plus in-process
# Invoke-GitHubWake with an operator-supplied InternalReview object.
# Covers the 8 user minimum cases:
# (1) default wake without GitHub approval stays blocked;
# (2) solo + green + valid internal review reaches technical readiness;
# (3) solo missing/invalid internal review blocked;
# (4) wrong SHA blocked; (5) CHANGES_REQUESTED blocked;
# (6) incompatible wait expectation INVALID; (7) readiness without
# auth/executor causes no NativeResume/settlement; (8) partial-tick recovery
# applies the same gates without duplicate effects.
# Follow-ups (offline, same temp-owned fixture discipline):
# (9) CLI/config end-to-end (solo opt-in + operator review path in config,
# auth/executor only as per-run CLI switches, resolve-owner/lease in config)
# reaches technical readiness/RESUME in a child process;
# (10) wake-level SHA mismatch (green wait/snapshot on SHA_A, valid approved
# review for SHA_B) stays REVIEW_PENDING with internal-review-sha-mismatch.
# Plumbing: explicit operator opt-in only (-DeliveryProfile CLI/config);
# wait/snapshot/next-action payloads can never select the profile; the
# internal record travels from an operator file through the existing
# Test-GHInternalReview validator as QC-only evidence.
# ASCII only.
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')
$ErrorActionPreference = 'Stop'
$script:cli = Join-Path $PSScriptRoot 'github-wake.ps1'
if (-not (Test-Path -LiteralPath $script:cli -PathType Leaf)) { throw 'RED: github-wake.ps1 not found (expected before GREEN)' }
. $script:cli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-SoloField {
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
# --- solo surface exists on the wake CLI (plumbing, RED if missing).
Assert-That ($null -ne (Get-Command Resolve-GHWDeliveryProfile -ErrorAction SilentlyContinue)) 'wake exposes Resolve-GHWDeliveryProfile'
Assert-That ($null -ne (Get-Command Read-GHWInternalReviewFile -ErrorAction SilentlyContinue)) 'wake exposes Read-GHWInternalReviewFile'
Assert-That ($null -ne (Get-Command Invoke-GitHubWake -ErrorAction SilentlyContinue)) 'wake exposes Invoke-GitHubWake'
$cliText = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
Assert-That ($cliText -cmatch 'DeliveryProfile') 'CLI carries DeliveryProfile plumbing'
Assert-That ($cliText -cmatch 'InternalReview') 'CLI carries InternalReview plumbing'
Assert-That ($cliText -cnotmatch 'function Get-OrchestrationGitHubReadiness') 'wake still reuses readiness (never reimplements)'
Assert-That ($cliText -cnotmatch 'function Test-OrchestrationGitHubResume') 'wake still reuses resume caller (never reimplements)'
Assert-That ($cliText -cnotmatch 'function Test-GHInternalReview') 'wake still reuses internal-review validator (never reimplements)'
# --- profile resolver: explicit opt-in only, default unchanged.
$dp0 = Resolve-GHWDeliveryProfile -DeliveryProfile ''
Assert-That (([bool](Get-SoloField $dp0 'ok' $false)) -and ([string](Get-SoloField $dp0 'profile' 'X') -ceq '')) 'empty profile resolves to default (unchanged behavior)'
$dpS = Resolve-GHWDeliveryProfile -DeliveryProfile 'solo-maintainer'
Assert-That (([bool](Get-SoloField $dpS 'ok' $false)) -and ([string](Get-SoloField $dpS 'profile' '') -ceq 'solo-maintainer')) 'solo-maintainer is the explicit opt-in'
$dpB = Resolve-GHWDeliveryProfile -DeliveryProfile 'no-such-profile'
Assert-That ((-not [bool](Get-SoloField $dpB 'ok' $true)) -and ([string](Get-SoloField $dpB 'reason' '') -ceq 'invalid-delivery-profile')) 'unknown profile fails closed'
$dpW = Resolve-GHWDeliveryProfile -DeliveryProfile '  '
Assert-That (([bool](Get-SoloField $dpW 'ok' $false)) -and ([string](Get-SoloField $dpW 'profile' 'X') -ceq '')) 'blank profile normalizes to default'
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
# --- child engine (same family as parent; mirrors github-wake.tests.ps1).
$script:childExe = ''
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
    $foundChild = $null
    try { $foundChild = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $foundChild = $null }
    if (($null -ne $foundChild) -and (-not [string]::IsNullOrWhiteSpace([string]$foundChild.Source))) { $script:childExe = [string]$foundChild.Source }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) {
    $psChildExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psChildExe -PathType Leaf)) { $psChildExe = 'powershell' }
    $script:childExe = $psChildExe
}
if ([string]::IsNullOrWhiteSpace($script:childExe)) { throw 'FAIL: engine unavailable (neither pwsh nor powershell resolved)' }
$script:passed++
function Invoke-SoloChild {
    param([string[]]$CliArgs = @())
    $out = & $script:childExe -NoProfile -File $script:cli @CliArgs 2>$null
    $code = $LASTEXITCODE
    $text = ''
    if ($null -ne $out) { $text = ($out -join "`n").Trim() }
    $childEnv = $null
    try { if (-not [string]::IsNullOrWhiteSpace($text)) { $childEnv = ConvertFrom-Json $text } } catch { $childEnv = $null }
    return @{ code = $code; text = $text; env = $childEnv }
}
function New-SoloEnv {
    param([string]$Tag = 'solo')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghwsolo-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; flagsPath = $flagsPath }
}
function New-SoloGoal {
    param($Env, [string]$GoalId = 'solo-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d solo wake' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-SoloField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-SoloField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-SoloField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-SoloField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-SoloField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-SoloField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-SoloField $own 'ok' $false)) { throw 'goal-ownership' }
    $gen = [long](Get-SoloField (Get-SoloField $own 'ownership' $null) 'generation' 0)
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-solo' -ReadScopes @('src/solo.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-SoloField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-SoloField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
    [void]$gen
}
function Set-SoloBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-SoloField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-SoloField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-SoloField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-SoloField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-SoloField $tr 'error' '')) }
}
function New-SoloWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'solo-goal-1', [string]$ReviewExp = 'ANY')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-solo' -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/solo' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation $ReviewExp -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-SoloField $reg 'ok' $false)) { throw ('wait:' + [string](Get-SoloField $reg 'reason' '')) }
}
function New-SoloCkpt {
    param($Env, [string]$GoalId = 'solo-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-SoloField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-SoloField $sv 'checkpoint_id' '')
}
function New-SoloNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-SoloRaw {
    param($Nodes, [string]$Head, [string]$Commit, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'REVIEW_REQUIRED', [long]$Pr = 42)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = $Pr; state = $State; headRefOid = $Head; mergeable = $Merge; reviewDecision = $Review; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-SoloFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-SoloGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-SoloNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function New-SoloInternal {
    param([bool]$Approved = $true, [string]$Sha = '', [string]$Reviewer = 'reviewer-1', [string]$Author = 'author-1')
    if ([string]::IsNullOrWhiteSpace($Sha)) { $Sha = $script:SHA_A }
    return [pscustomobject]@{ approved = $Approved; head_sha = $Sha; reviewer_identity = $Reviewer; author_identity = $Author }
}
function Invoke-SoloWake {
    param($Env, [string]$Fixture = '', [bool]$Auth = $true, [bool]$Exec = $true, [string]$Profile = '', $Internal = $null, [string]$EventId = 'evt-solo-1')
    $passInternal = $null
    if ($null -ne $Internal) { $passInternal = $Internal }
    return (Invoke-GitHubWake -WaitsDir $Env.waitsDir -TasksDir $Env.tasksDir -GoalStoreDir $Env.goalDir -CheckpointDir $Env.ckptDir -FlagsPath $Env.flagsPath -Policy $script:policy -GraphQLSnapshotFile $Fixture -EventId $EventId -MaxAgeSeconds 300 -NowUtc $script:NOW -ActorIdentitySource 'explicit-cli' -AuthorizationAlive $Auth -ExecutorPresent $Exec -ResolveOwner $true -ResolveLease $true -DeliveryProfile $Profile -InternalReview $passInternal -MaxApiAttempts 3 -TimeoutMs 10000)
}
function Get-SoloItem {
    param($Res)
    $items = @(Get-SoloField $Res 'items' @())
    if (@($items).Count -ne 1) { throw ('expected exactly 1 item, got ' + [string]@($items).Count) }
    return @($items)[0]
}
function Get-SoloTaskState {
    param($Env, [string]$TaskId = '')
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    return ([string](Get-SoloField $t 'state' ''))
}
function Get-SoloAppliedCount {
    param($Env)
    $files = @(Get-ChildItem -LiteralPath $Env.waitsDir -File -Filter 'ghwait-*.json' -ErrorAction Stop)
    if (@($files).Count -ne 1) { throw 'expected exactly 1 wait file' }
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText(@($files)[0].FullName, [Text.Encoding]::UTF8))
    $ap = @(Get-SoloField $doc 'applied_events' @())
    return [long]@($ap).Count
}
try {
    # --- (1) default wake without GitHub approval stays blocked.
    $e1 = New-SoloEnv -Tag 'c1'
    try {
        New-SoloGoal -Env $e1 -Tasks @('task.solo-c1')
        Set-SoloBlocked -Env $e1 -TaskId 'task.solo-c1' -Sha $script:SHA_A
        New-SoloWait -Env $e1 -TaskId 'task.solo-c1' -Sha $script:SHA_A -ReviewExp 'APPROVED'
        New-SoloCkpt -Env $e1 | Out-Null
        $fx1 = Write-SoloFixture -Env $e1 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c1.json'
        $r1 = Invoke-SoloWake -Env $e1 -Fixture $fx1 -Auth $true -Exec $true -Profile '' -Internal $null
        $i1 = Get-SoloItem $r1
        Assert-That (([string](Get-SoloField $i1 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-SoloField $i1 'readiness' '') -ceq 'REVIEW_PENDING')) 'c1: default without GitHub approval stays REVIEW_PENDING'
        Assert-That ((Get-SoloTaskState -Env $e1 -TaskId 'task.solo-c1') -ceq 'BLOCKED') 'c1: kernel stays BLOCKED'
        Assert-That ($null -eq (Get-SoloField $r1 'next_action' 'X')) 'c1: no next_action without approval'
        Assert-That (-not [bool](Get-SoloField $r1 'resume_authorized' $true)) 'c1: resume_authorized false'
    } finally { try { if (Test-Path -LiteralPath $e1.root) { Remove-Item -LiteralPath $e1.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (2) solo + green + valid internal review reaches technical readiness.
    $e2 = New-SoloEnv -Tag 'c2'
    try {
        New-SoloGoal -Env $e2 -Tasks @('task.solo-c2')
        Set-SoloBlocked -Env $e2 -TaskId 'task.solo-c2' -Sha $script:SHA_A
        New-SoloWait -Env $e2 -TaskId 'task.solo-c2' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e2 | Out-Null
        $fx2 = Write-SoloFixture -Env $e2 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c2.json'
        $r2 = Invoke-SoloWake -Env $e2 -Fixture $fx2 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal)
        $i2 = Get-SoloItem $r2
        Assert-That (([string](Get-SoloField $i2 'decision' '') -ceq 'RESUME') -and ([string](Get-SoloField $i2 'readiness' '') -ceq 'READY_FOR_RESUME')) 'c2: solo green + valid internal review => RESUME technical readiness'
        Assert-That ((Get-SoloTaskState -Env $e2 -TaskId 'task.solo-c2') -ceq 'IMPLEMENTING') 'c2: kernel unblocked exactly once'
        Assert-That ($null -ne (Get-SoloField $r2 'next_action' $null)) 'c2: next_action announced'
        Assert-That ([bool](Get-SoloField $r2 'resume_authorized' $false)) 'c2: resume_authorized true'
        Assert-That ((-not [bool](Get-SoloField $r2 'grants_authority' $true)) -and (-not [bool](Get-SoloField $r2 'done_approved' $true)) -and (-not [bool](Get-SoloField $r2 'merge_authority' $true))) 'c2: zero grant/done/merge authority'
    } finally { try { if (Test-Path -LiteralPath $e2.root) { Remove-Item -LiteralPath $e2.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (3) solo missing/invalid internal review blocked.
    $e3 = New-SoloEnv -Tag 'c3'
    try {
        New-SoloGoal -Env $e3 -Tasks @('task.solo-c3a', 'task.solo-c3b')
        Set-SoloBlocked -Env $e3 -TaskId 'task.solo-c3a' -Sha $script:SHA_A
        New-SoloWait -Env $e3 -TaskId 'task.solo-c3a' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e3 | Out-Null
        $fx3 = Write-SoloFixture -Env $e3 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c3.json'
        $r3 = Invoke-SoloWake -Env $e3 -Fixture $fx3 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal $null -EventId 'evt-solo-3a'
        $i3 = Get-SoloItem $r3
        Assert-That (([string](Get-SoloField $i3 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-SoloField $i3 'readiness' '') -ceq 'REVIEW_PENDING')) 'c3: solo missing internal review => REVIEW_PENDING, never RESUME'
        Assert-That ((Get-SoloTaskState -Env $e3 -TaskId 'task.solo-c3a') -ceq 'BLOCKED') 'c3: kernel stays BLOCKED without internal record'
        Assert-That ($null -eq (Get-SoloField $r3 'next_action' 'X')) 'c3: no next_action without internal record'
    } finally { try { if (Test-Path -LiteralPath $e3.root) { Remove-Item -LiteralPath $e3.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    $e3b = New-SoloEnv -Tag 'c3b'
    try {
        New-SoloGoal -Env $e3b -Tasks @('task.solo-c3c')
        Set-SoloBlocked -Env $e3b -TaskId 'task.solo-c3c' -Sha $script:SHA_A
        New-SoloWait -Env $e3b -TaskId 'task.solo-c3c' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e3b | Out-Null
        $fx3b = Write-SoloFixture -Env $e3b -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c3b.json'
        $badSelf = New-SoloInternal -Reviewer 'author-1' -Author 'author-1'
        $r3b = Invoke-SoloWake -Env $e3b -Fixture $fx3b -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal $badSelf -EventId 'evt-solo-3b'
        $i3b = Get-SoloItem $r3b
        Assert-That (([string](Get-SoloField $i3b 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-SoloField $i3b 'readiness' '') -ceq 'REVIEW_PENDING')) 'c3: solo self-review internal record => REVIEW_PENDING, never RESUME'
        Assert-That ((Get-SoloTaskState -Env $e3b -TaskId 'task.solo-c3c') -ceq 'BLOCKED') 'c3: self-review keeps kernel BLOCKED'
        $badShape = 'not-an-object'
        $r3c = Invoke-SoloWake -Env $e3b -Fixture $fx3b -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal $badShape -EventId 'evt-solo-3c'
        $i3c = Get-SoloItem $r3c
        Assert-That (([string](Get-SoloField $i3c 'readiness' '') -ceq 'INCONCLUSIVE')) 'c3: malformed internal record => INCONCLUSIVE fail-closed'
        Assert-That ((Get-SoloTaskState -Env $e3b -TaskId 'task.solo-c3c') -ceq 'BLOCKED') 'c3: malformed record keeps kernel BLOCKED'
    } finally { try { if (Test-Path -LiteralPath $e3b.root) { Remove-Item -LiteralPath $e3b.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (4) wrong SHA blocked.
    $e4 = New-SoloEnv -Tag 'c4'
    try {
        New-SoloGoal -Env $e4 -Tasks @('task.solo-c4')
        Set-SoloBlocked -Env $e4 -TaskId 'task.solo-c4' -Sha $script:SHA_A
        New-SoloWait -Env $e4 -TaskId 'task.solo-c4' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e4 | Out-Null
        $fx4 = Write-SoloFixture -Env $e4 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_B) -Head $script:SHA_B -Commit $script:SHA_B -Review 'REVIEW_REQUIRED') -Name 'c4.json'
        $r4 = Invoke-SoloWake -Env $e4 -Fixture $fx4 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal -Sha $script:SHA_A) -EventId 'evt-solo-4'
        $i4 = Get-SoloItem $r4
        Assert-That (([string](Get-SoloField $i4 'decision' '') -ceq 'TERMINAL') -and ([string](Get-SoloField $i4 'readiness' '') -ceq 'STALE')) 'c4: observed head superseding expected SHA => TERMINAL head-superseded'
        Assert-That ((Get-SoloTaskState -Env $e4 -TaskId 'task.solo-c4') -ceq 'BLOCKED') 'c4: kernel stays BLOCKED on SHA divergence'
        Assert-That ($null -eq (Get-SoloField $r4 'next_action' 'X')) 'c4: no next_action on SHA divergence'
    } finally { try { if (Test-Path -LiteralPath $e4.root) { Remove-Item -LiteralPath $e4.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (5) CHANGES_REQUESTED blocked even under solo.
    $e5 = New-SoloEnv -Tag 'c5'
    try {
        New-SoloGoal -Env $e5 -Tasks @('task.solo-c5')
        Set-SoloBlocked -Env $e5 -TaskId 'task.solo-c5' -Sha $script:SHA_A
        New-SoloWait -Env $e5 -TaskId 'task.solo-c5' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e5 | Out-Null
        $fx5 = Write-SoloFixture -Env $e5 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'CHANGES_REQUESTED') -Name 'c5.json'
        $r5 = Invoke-SoloWake -Env $e5 -Fixture $fx5 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-5'
        $i5 = Get-SoloItem $r5
        Assert-That (([string](Get-SoloField $i5 'decision' '') -ceq 'TERMINAL') -and ([string](Get-SoloField $i5 'readiness' '') -ceq 'REPAIR_REQUIRED')) 'c5: CHANGES_REQUESTED repairs even with solo waiver'
        Assert-That ((Get-SoloTaskState -Env $e5 -TaskId 'task.solo-c5') -ceq 'BLOCKED') 'c5: kernel stays BLOCKED on changes-requested'
        Assert-That ($null -eq (Get-SoloField $r5 'next_action' 'X')) 'c5: no next_action on changes-requested'
    } finally { try { if (Test-Path -LiteralPath $e5.root) { Remove-Item -LiteralPath $e5.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (6) incompatible wait expectation INVALID, never silently migrated.
    $e6 = New-SoloEnv -Tag 'c6'
    try {
        New-SoloGoal -Env $e6 -Tasks @('task.solo-c6')
        Set-SoloBlocked -Env $e6 -TaskId 'task.solo-c6' -Sha $script:SHA_A
        New-SoloWait -Env $e6 -TaskId 'task.solo-c6' -Sha $script:SHA_A -ReviewExp 'APPROVED'
        New-SoloCkpt -Env $e6 | Out-Null
        $fx6 = Write-SoloFixture -Env $e6 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c6.json'
        $r6 = Invoke-SoloWake -Env $e6 -Fixture $fx6 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-6'
        $i6 = Get-SoloItem $r6
        Assert-That (([string](Get-SoloField $i6 'decision' '') -ceq 'INVALID')) 'c6: persisted APPROVED under solo ANY => INVALID policy-diverged'
        Assert-That ((Get-SoloTaskState -Env $e6 -TaskId 'task.solo-c6') -ceq 'BLOCKED') 'c6: kernel stays BLOCKED on policy divergence'
        Assert-That ($null -eq (Get-SoloField $r6 'next_action' 'X')) 'c6: no next_action on policy divergence'
        $wf6 = @(Get-ChildItem -LiteralPath $e6.waitsDir -File -Filter 'ghwait-*.json' -ErrorAction Stop)
        $doc6 = ConvertFrom-Json ([IO.File]::ReadAllText(@($wf6)[0].FullName, [Text.Encoding]::UTF8))
        Assert-That ([string](Get-SoloField $doc6 'review_expectation' '') -ceq 'APPROVED') 'c6: divergent wait file left unmigrated on disk'
    } finally { try { if (Test-Path -LiteralPath $e6.root) { Remove-Item -LiteralPath $e6.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (7) readiness without auth/executor: technical READY only, zero dispatch effects.
    $e7 = New-SoloEnv -Tag 'c7'
    try {
        New-SoloGoal -Env $e7 -Tasks @('task.solo-c7')
        Set-SoloBlocked -Env $e7 -TaskId 'task.solo-c7' -Sha $script:SHA_A
        New-SoloWait -Env $e7 -TaskId 'task.solo-c7' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e7 | Out-Null
        $fx7 = Write-SoloFixture -Env $e7 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c7.json'
        $r7 = Invoke-SoloWake -Env $e7 -Fixture $fx7 -Auth $true -Exec $false -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-7'
        $i7 = Get-SoloItem $r7
        Assert-That (([string](Get-SoloField $i7 'decision' '') -ceq 'READY') -and ([string](Get-SoloField $i7 'readiness' '') -ceq 'READY_FOR_RESUME')) 'c7: solo READY without executor stays observation, never RESUME'
        Assert-That ((Get-SoloTaskState -Env $e7 -TaskId 'task.solo-c7') -ceq 'BLOCKED') 'c7: kernel stays BLOCKED without executor'
        Assert-That ($null -eq (Get-SoloField $r7 'next_action' 'X')) 'c7: no next_action without executor (no NativeResume/settlement input)'
        Assert-That (-not [bool](Get-SoloField $r7 'resume_authorized' $true)) 'c7: resume_authorized false without executor'
        Assert-That ((Get-SoloAppliedCount -Env $e7) -eq 0) 'c7: no Confirm CAS without executor'
        Assert-That ((Get-SoloField $r7 'auto_dispatch' 'ABSENT') -ceq 'ABSENT') 'c7: no auto-dispatch handoff without RESUME'
    } finally { try { if (Test-Path -LiteralPath $e7.root) { Remove-Item -LiteralPath $e7.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    $e7b = New-SoloEnv -Tag 'c7b'
    try {
        New-SoloGoal -Env $e7b -Tasks @('task.solo-c7b')
        Set-SoloBlocked -Env $e7b -TaskId 'task.solo-c7b' -Sha $script:SHA_A
        New-SoloWait -Env $e7b -TaskId 'task.solo-c7b' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e7b | Out-Null
        $fx7b = Write-SoloFixture -Env $e7b -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c7b.json'
        $r7b = Invoke-SoloWake -Env $e7b -Fixture $fx7b -Auth $false -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-7b'
        $i7b = Get-SoloItem $r7b
        Assert-That (([string](Get-SoloField $i7b 'decision' '') -ceq 'TERMINAL')) 'c7: revoked authorization stays TERMINAL even when technically ready'
        Assert-That ((Get-SoloTaskState -Env $e7b -TaskId 'task.solo-c7b') -ceq 'BLOCKED') 'c7: kernel stays BLOCKED without authorization'
        Assert-That ($null -eq (Get-SoloField $r7b 'next_action' 'X')) 'c7: no next_action without authorization'
    } finally { try { if (Test-Path -LiteralPath $e7b.root) { Remove-Item -LiteralPath $e7b.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- planner payload can never select the profile or supply the review.
    $eP = New-SoloEnv -Tag 'cP'
    try {
        New-SoloGoal -Env $eP -Tasks @('task.solo-cp')
        Set-SoloBlocked -Env $eP -TaskId 'task.solo-cp' -Sha $script:SHA_A
        New-SoloWait -Env $eP -TaskId 'task.solo-cp' -Sha $script:SHA_A -ReviewExp 'APPROVED'
        $wfP = @(Get-ChildItem -LiteralPath $eP.waitsDir -File -Filter 'ghwait-*.json' -ErrorAction Stop)
        $docP = ConvertFrom-Json ([IO.File]::ReadAllText(@($wfP)[0].FullName, [Text.Encoding]::UTF8))
        $docP | Add-Member -NotePropertyName 'delivery_profile' -NotePropertyValue 'solo-maintainer' -Force
        $docP | Add-Member -NotePropertyName 'internal_review' -NotePropertyValue (New-SoloInternal) -Force
        [IO.File]::WriteAllText(@($wfP)[0].FullName, (ConvertTo-Json -InputObject $docP -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
        New-SoloCkpt -Env $eP | Out-Null
        $fxP = Write-SoloFixture -Env $eP -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'cp.json'
        $rP = Invoke-SoloWake -Env $eP -Fixture $fxP -Auth $true -Exec $true -Profile '' -Internal $null -EventId 'evt-solo-cp'
        $iP = Get-SoloItem $rP
        Assert-That (([string](Get-SoloField $iP 'readiness' '') -ceq 'REVIEW_PENDING') -and ([string](Get-SoloField $iP 'decision' '') -ceq 'KEEP_WAITING')) 'planner wait payload cannot opt into solo or supply review'
        Assert-That ((Get-SoloTaskState -Env $eP -TaskId 'task.solo-cp') -ceq 'BLOCKED') 'planner payload keeps kernel BLOCKED'
    } finally { try { if (Test-Path -LiteralPath $eP.root) { Remove-Item -LiteralPath $eP.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (8) partial-tick recovery: same gates, no duplicate Confirm/unblock.
    $e8 = New-SoloEnv -Tag 'c8'
    try {
        New-SoloGoal -Env $e8 -Tasks @('task.solo-c8')
        Set-SoloBlocked -Env $e8 -TaskId 'task.solo-c8' -Sha $script:SHA_A
        New-SoloWait -Env $e8 -TaskId 'task.solo-c8' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e8 | Out-Null
        $fx8 = Write-SoloFixture -Env $e8 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c8.json'
        $ddk8 = ''
        $wf8 = @(Get-ChildItem -LiteralPath $e8.waitsDir -File -Filter 'ghwait-*.json' -ErrorAction Stop)
        $doc8 = ConvertFrom-Json ([IO.File]::ReadAllText(@($wf8)[0].FullName, [Text.Encoding]::UTF8))
        $ddk8 = [string](Get-SoloField $doc8 'dedup_key' '')
        $cf8 = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $e8.waitsDir -DedupKey $ddk8 -EventId 'evt-solo-8'
        Assert-That ([bool](Get-SoloField $cf8 'ok' $false)) 'c8: setup Confirm applied (simulated partial tick)'
        Assert-That ((Get-SoloTaskState -Env $e8 -TaskId 'task.solo-c8') -ceq 'BLOCKED') 'c8: task still BLOCKED after partial tick'
        $r8 = Invoke-SoloWake -Env $e8 -Fixture $fx8 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-8'
        $i8 = Get-SoloItem $r8
        Assert-That (([string](Get-SoloField $i8 'decision' '') -ceq 'RESUME') -and ([string](Get-SoloField $i8 'reason' '') -ceq 'reconciled-pending-unblock')) 'c8: recovery revalidates and reconciles exactly once'
        Assert-That (([string](Get-SoloField $i8 'readiness' '') -ceq 'READY_FOR_RESUME')) 'c8: recovery passes the same readiness gate'
        Assert-That ((Get-SoloTaskState -Env $e8 -TaskId 'task.solo-c8') -ceq 'IMPLEMENTING') 'c8: recovery unblocks exactly once'
        Assert-That ((Get-SoloAppliedCount -Env $e8) -eq 1) 'c8: no duplicate Confirm on recovery'
        Assert-That ($null -ne (Get-SoloField $r8 'next_action' $null)) 'c8: recovery announces next_action once'
        $r8b = Invoke-SoloWake -Env $e8 -Fixture $fx8 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal) -EventId 'evt-solo-8'
        $i8b = Get-SoloItem $r8b
        Assert-That (([string](Get-SoloField $i8b 'decision' '') -ceq 'DUPLICATE_NOOP')) 'c8: replay after recovery is DUPLICATE_NOOP (no second unblock)'
        Assert-That ((Get-SoloTaskState -Env $e8 -TaskId 'task.solo-c8') -ceq 'IMPLEMENTING') 'c8: kernel untouched by replay'
        Assert-That ((Get-SoloAppliedCount -Env $e8) -eq 1) 'c8: replay adds no Confirm'
    } finally { try { if (Test-Path -LiteralPath $e8.root) { Remove-Item -LiteralPath $e8.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (9) offline CLI/config end-to-end: solo opt-in via config file.
    # Operator-owned temp internal-review JSON + GraphQL fixture travel in
    # the config; auth/executor booleans come ONLY from explicit per-run
    # CLI switches (never from config). Resolve-owner/lease ride in the
    # config as resolver opt-ins. No scheduler, no live/remote services.
    $e9 = New-SoloEnv -Tag 'c9cfg'
    try {
        New-SoloGoal -Env $e9 -Tasks @('task.solo-c9')
        Set-SoloBlocked -Env $e9 -TaskId 'task.solo-c9' -Sha $script:SHA_A
        New-SoloWait -Env $e9 -TaskId 'task.solo-c9' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e9 | Out-Null
        $fx9 = Write-SoloFixture -Env $e9 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c9.json'
        $revFile9 = Join-Path $e9.root 'internal-review.json'
        [IO.File]::WriteAllText($revFile9, (ConvertTo-Json -InputObject (New-SoloInternal -Sha $script:SHA_A) -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
        $cfg9 = Join-Path $e9.root 'wake-solo.json'
        $cw9 = New-GitHubWakeConfig -Path $cfg9 -WaitsDir $e9.waitsDir -TasksDir $e9.tasksDir -GoalStoreDir $e9.goalDir -CheckpointDir $e9.ckptDir -FlagsPath $e9.flagsPath -GraphQLSnapshotFile $fx9 -DeliveryProfile 'solo-maintainer' -InternalReviewPath $revFile9 -ResolveOwner $true -ResolveLease $true
        Assert-That ([bool](Get-SoloField $cw9 'ok' $false)) 'c9: solo config with resolve-owner/lease opt-ins written'
        $cfgDoc9 = ConvertFrom-Json ([IO.File]::ReadAllText($cfg9, [Text.Encoding]::UTF8))
        Assert-That ([string](Get-SoloField $cfgDoc9 'delivery_profile' '') -ceq 'solo-maintainer') 'c9: config carries delivery_profile opt-in'
        Assert-That ([string](Get-SoloField $cfgDoc9 'internal_review_path' '') -ceq $revFile9) 'c9: config carries operator review path (never review content)'
        Assert-That ((Get-SoloField $cfgDoc9 'internal_review' 'ABSENT') -ceq 'ABSENT') 'c9: config never embeds review content'
        Assert-That ((-not [bool](Get-SoloField $cfgDoc9 'authorization_alive' $true)) -and (-not [bool](Get-SoloField $cfgDoc9 'executor_present' $true))) 'c9: config never persists auth/executor as true'
        Assert-That (([bool](Get-SoloField $cfgDoc9 'resolve_owner' $false)) -and ([bool](Get-SoloField $cfgDoc9 'resolve_lease' $false))) 'c9: config carries resolve-owner/lease opt-ins'
        $cfgPoison9 = ConvertFrom-Json ([IO.File]::ReadAllText($cfg9, [Text.Encoding]::UTF8))
        $cfgPoison9 | Add-Member -NotePropertyName 'authorization_alive' -NotePropertyValue $true -Force
        $cfgPoison9 | Add-Member -NotePropertyName 'executor_present' -NotePropertyValue $true -Force
        [IO.File]::WriteAllText($cfg9, (ConvertTo-Json -InputObject $cfgPoison9 -Depth 4 -Compress), (New-Object Text.UTF8Encoding $false))
        $r9n1 = Invoke-SoloChild -CliArgs @('-ConfigFile', $cfg9, '-NowUtc', $script:NOW, '-EventId', 'evt-solo-c9n1')
        Assert-That ([int]$r9n1.code -eq 0) 'c9: poisoned config without CLI switches exits 0 (fail-closed, never crash)'
        Assert-That (($null -ne $r9n1.env) -and ([string](Get-SoloField $r9n1.env 'verdict' '') -ceq 'WAKE_PASS')) 'c9: poisoned config without CLI switches => WAKE_PASS envelope'
        $items9n1 = @(Get-SoloField $r9n1.env 'items' @())
        Assert-That ((@($items9n1).Count -eq 1) -and ([string](Get-SoloField @($items9n1)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-SoloField @($items9n1)[0] 'reason' '') -ceq 'authorization-revoked')) 'c9: config-persisted true booleans grant no authorization (TERMINAL authorization-revoked)'
        Assert-That ((Get-SoloTaskState -Env $e9 -TaskId 'task.solo-c9') -ceq 'BLOCKED') 'c9: poisoned config without switches keeps kernel BLOCKED'
        Assert-That ($null -eq (Get-SoloField $r9n1.env 'next_action' 'X')) 'c9: no next_action without explicit authorization'
        Assert-That (-not [bool](Get-SoloField $r9n1.env 'resume_authorized' $true)) 'c9: resume_authorized false without explicit authorization'
        Assert-That ((Get-SoloAppliedCount -Env $e9) -eq 0) 'c9: poisoned config without switches performs no Confirm CAS'
        $r9n2 = Invoke-SoloChild -CliArgs @('-ConfigFile', $cfg9, '-NowUtc', $script:NOW, '-EventId', 'evt-solo-c9n2', '-AuthorizationAlive')
        Assert-That ([int]$r9n2.code -eq 0) 'c9: auth-only child tick exits 0'
        $items9n2 = @(Get-SoloField $r9n2.env 'items' @())
        Assert-That ((@($items9n2).Count -eq 1) -and ([string](Get-SoloField @($items9n2)[0] 'decision' '') -ceq 'READY') -and ([string](Get-SoloField @($items9n2)[0] 'readiness' '') -ceq 'READY_FOR_RESUME')) 'c9: auth without executor stays READY observation, never RESUME'
        Assert-That ((Get-SoloTaskState -Env $e9 -TaskId 'task.solo-c9') -ceq 'BLOCKED') 'c9: auth-only tick keeps kernel BLOCKED'
        Assert-That ($null -eq (Get-SoloField $r9n2.env 'next_action' 'X')) 'c9: no next_action without executor (no NativeResume/settlement input)'
        Assert-That ((Get-SoloField $r9n2.env 'auto_dispatch' 'ABSENT') -ceq 'ABSENT') 'c9: no auto-dispatch handoff without RESUME'
        Assert-That (-not [bool](Get-SoloField $r9n2.env 'resume_authorized' $true)) 'c9: resume_authorized false without executor'
        Assert-That ((Get-SoloAppliedCount -Env $e9) -eq 0) 'c9: auth-only tick performs no Confirm CAS'
        $r9 = Invoke-SoloChild -CliArgs @('-ConfigFile', $cfg9, '-NowUtc', $script:NOW, '-AuthorizationAlive', '-ExecutorPresent')
        Assert-That ([int]$r9.code -eq 0) 'c9: config-file child tick exits 0'
        Assert-That (($null -ne $r9.env) -and ([string](Get-SoloField $r9.env 'verdict' '') -ceq 'WAKE_PASS')) 'c9: config-file child tick => WAKE_PASS'
        $items9 = @(Get-SoloField $r9.env 'items' @())
        Assert-That ((@($items9).Count -eq 1) -and ([string](Get-SoloField @($items9)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-SoloField @($items9)[0] 'readiness' '') -ceq 'READY_FOR_RESUME')) 'c9: solo valid record via config file reaches technical readiness/RESUME'
        Assert-That ([bool](Get-SoloField $r9.env 'resume_authorized' $false)) 'c9: config-file RESUME carries resume_authorized'
        Assert-That ($null -ne (Get-SoloField $r9.env 'next_action' $null)) 'c9: config-file RESUME announces next_action'
        Assert-That ((Get-SoloTaskState -Env $e9 -TaskId 'task.solo-c9') -ceq 'IMPLEMENTING') 'c9: config-file RESUME unblocks kernel exactly once'
    } finally { try { if (Test-Path -LiteralPath $e9.root) { Remove-Item -LiteralPath $e9.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- (10) wake-level SHA mismatch: green wait/snapshot on SHA_A, valid
    # approved internal review for SHA_B. Never READY/RESUME; readiness
    # REVIEW_PENDING with internal-review-sha-mismatch; kernel BLOCKED;
    # no next_action.
    $e10 = New-SoloEnv -Tag 'c10mm'
    try {
        New-SoloGoal -Env $e10 -Tasks @('task.solo-c10')
        Set-SoloBlocked -Env $e10 -TaskId 'task.solo-c10' -Sha $script:SHA_A
        New-SoloWait -Env $e10 -TaskId 'task.solo-c10' -Sha $script:SHA_A -ReviewExp 'ANY'
        New-SoloCkpt -Env $e10 | Out-Null
        $fx10 = Write-SoloFixture -Env $e10 -Raw (New-SoloRaw -Nodes (New-SoloGreenNodes -Sha $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'c10.json'
        $r10 = Invoke-SoloWake -Env $e10 -Fixture $fx10 -Auth $true -Exec $true -Profile 'solo-maintainer' -Internal (New-SoloInternal -Sha $script:SHA_B) -EventId 'evt-solo-10'
        $i10 = Get-SoloItem $r10
        Assert-That (([string](Get-SoloField $i10 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-SoloField $i10 'readiness' '') -ceq 'REVIEW_PENDING')) 'c10: review for other SHA stays REVIEW_PENDING, never READY/RESUME'
        Assert-That ((([string](Get-SoloField $i10 'decision' '') -cne 'RESUME') -and ([string](Get-SoloField $i10 'decision' '') -cne 'READY')) -and ([string](Get-SoloField $i10 'readiness' '') -cne 'READY_FOR_RESUME')) 'c10: no RESUME/READY decision or technical readiness on SHA mismatch'
        Assert-That ((Get-SoloTaskState -Env $e10 -TaskId 'task.solo-c10') -ceq 'BLOCKED') 'c10: kernel stays BLOCKED on SHA mismatch'
        Assert-That ($null -eq (Get-SoloField $r10 'next_action' 'X')) 'c10: no next_action on SHA mismatch'
        Assert-That (-not [bool](Get-SoloField $r10 'resume_authorized' $true)) 'c10: resume_authorized false on SHA mismatch'
        $rawBack10 = ConvertFrom-Json ([IO.File]::ReadAllText($fx10, [Text.Encoding]::UTF8))
        $norm10 = Convert-GHARawToSnapshot -Raw $rawBack10 -Repository $script:REPO -PrNumber 42 -ObservedAt $script:NOW
        Assert-That ([bool](Get-SoloField $norm10 'ok' $false)) 'c10: fixture normalizes through the real normalizer'
        $val10 = Get-OrchestrationGitHubReadiness -Repository $script:REPO -PrNumber 42 -ExpectedHeadSha $script:SHA_A -Snapshot (Get-SoloField $norm10 'snapshot' $null) -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300 -DeliveryProfile 'solo-maintainer' -InternalReview (New-SoloInternal -Sha $script:SHA_B)
        Assert-That (([string](Get-SoloField $val10 'readiness' '') -ceq 'REVIEW_PENDING') -and (@(Get-SoloField $val10 'reasons' @()) -contains 'internal-review-sha-mismatch')) 'c10: validator pins REVIEW_PENDING with internal-review-sha-mismatch'
    } finally { try { if (Test-Path -LiteralPath $e10.root) { Remove-Item -LiteralPath $e10.root -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- operator file loading: valid file parses, garbage fails closed.
    $tmpRev = Join-Path ([IO.Path]::GetTempPath()) ('ghwsolo-rev-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($tmpRev, (ConvertTo-Json -InputObject (New-SoloInternal) -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
        $lr = Read-GHWInternalReviewFile -Path $tmpRev
        Assert-That (([bool](Get-SoloField $lr 'ok' $false)) -and ($null -ne (Get-SoloField $lr 'review' $null))) 'operator review file loads'
        $lrMissing = Read-GHWInternalReviewFile -Path ''
        Assert-That (([bool](Get-SoloField $lrMissing 'ok' $false)) -and ($null -eq (Get-SoloField $lrMissing 'review' 'X'))) 'absent review file loads as absent (blocks downstream, never crashes)'
        [IO.File]::WriteAllText($tmpRev, '{not json', (New-Object Text.UTF8Encoding $false))
        $lrBad = Read-GHWInternalReviewFile -Path $tmpRev
        Assert-That (-not [bool](Get-SoloField $lrBad 'ok' $true)) 'garbage review file fails closed'
    } finally { try { if (Test-Path -LiteralPath $tmpRev) { Remove-Item -LiteralPath $tmpRev -Force -ErrorAction SilentlyContinue } } catch { } }
    # --- config round-trip carries the operator opt-in (never the review content).
    $cfgSolo = Join-Path ([IO.Path]::GetTempPath()) ('ghwsolo-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $cw = New-GitHubWakeConfig -Path $cfgSolo -WaitsDir 'C:\w' -TasksDir 'C:\t' -GoalStoreDir 'C:\g' -CheckpointDir 'C:\c' -DeliveryProfile 'solo-maintainer' -InternalReviewPath 'C:\r\review.json'
        Assert-That ([bool](Get-SoloField $cw 'ok' $false)) 'config writer accepts solo opt-in'
        $cfgDoc = ConvertFrom-Json ([IO.File]::ReadAllText($cfgSolo, [Text.Encoding]::UTF8))
        Assert-That ([string](Get-SoloField $cfgDoc 'delivery_profile' '') -ceq 'solo-maintainer') 'config persists delivery_profile opt-in'
        Assert-That ([string](Get-SoloField $cfgDoc 'internal_review_path' '') -ceq 'C:\r\review.json') 'config persists internal review path'
        Assert-That ((Get-SoloField $cfgDoc 'internal_review' 'ABSENT') -ceq 'ABSENT') 'config never embeds review content'
    } finally { try { if (Test-Path -LiteralPath $cfgSolo) { Remove-Item -LiteralPath $cfgSolo -Force -ErrorAction SilentlyContinue } } catch { } }
    Write-Output "PASS: $($script:passed) assertions"
    exit 0
}
catch {
    Write-Output ("FAIL: " + $_.Exception.Message)
    exit 1
}
