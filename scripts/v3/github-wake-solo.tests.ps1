# github-wake-solo.tests.ps1 -- Etapa 6D solo-maintainer wake integration.
# Custom PS 5.1 / PS7 suite, no Pester. Offline only (no live network, no gh
# required): every behavior case uses -GraphQLSnapshotFile (raw GraphQL
# shape through the REAL Convert-GHARawToSnapshot normalizer) plus
# operator-owned internal-review JSON files. Covers the eight delegated
# scenarios: default unchanged without GitHub approval (S1), explicit
# operator opt-in only with Planner data never activating solo (S2), solo
# happy path with technical readiness documented as internal-agent (S3),
# missing/invalid/sha-mismatch review plus CHANGES_REQUESTED and stale SHA
# blocks (S4), ANY expectation with APPROVED persisted => INVALID without
# migration (S5), partial-tick recovery reusing the same gates (S6),
# readiness without executor/authorization never advancing (S7), unknown or
# malformed profile failing closed (S8). ASCII only.
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
# --- integration pins: validators reused, never reimplemented here.
$script:cliText = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
foreach ($need in @('Test-OrchestrationGitHubWakeSoloProfile', 'Read-GHWSoloInternalReview', 'Invoke-GHWResumeDecision')) {
    Assert-That ($script:cliText -cmatch $need) ('wake exposes solo integration surface: ' + $need)
}
foreach ($dup in @('function Get-OrchestrationGitHubReadiness', 'function Test-OrchestrationGitHubResume', 'function Test-GHInternalReview')) {
    Assert-That ($script:cliText -cnotmatch $dup) ('wake never reimplements validators: ' + $dup)
}
Assert-That ($script:cliText -cmatch 'delivery_profile') 'wake config carries delivery_profile opt-in (never planner data)'
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
function Invoke-GHSChild {
    param([string[]]$CliArgs = @())
    $out = & $script:childExe -NoProfile -File $script:cli @CliArgs 2>$null
    $code = $LASTEXITCODE
    $text = ''
    if ($null -ne $out) { $text = ($out -join "`n").Trim() }
    $env = $null
    try { if (-not [string]::IsNullOrWhiteSpace($text)) { $env = ConvertFrom-Json $text } } catch { $env = $null }
    return @{ code = $code; text = $text; env = $env }
}
function Get-GHSField {
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
# --- shared temp env builder (goal+checkpoint+tasks+waits via canonical libs).
$script:libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $script:libDir 'OrchestrationGoalKernel.ps1')
. (Join-Path $script:libDir 'OrchestrationTaskKernel.ps1')
. (Join-Path $script:libDir 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $script:libDir 'OrchestrationGitHubResume.ps1')
$script:policy = $null
try { $script:policy = Get-OrchestrationDeliveryPolicy $null } catch { $script:policy = $null }
if ($null -eq $script:policy) { throw 'FAIL: delivery policy unavailable' }
$script:SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2026-10-11T00:00:00Z'
$script:REPO = 'acme/widgets'
function New-GHSEnv {
    param([string]$Tag = 's')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghws-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    $reviewsDir = Join-Path $root 'reviews'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir, $reviewsDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; reviewsDir = $reviewsDir; flagsPath = $flagsPath }
}
function New-GHSGoal {
    param($Env, [string]$GoalId = 'ghw-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d wake solo' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-GHSField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-GHSField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-GHSField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-GHSField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-GHSField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-GHSField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-GHSField $own 'ok' $false)) { throw 'goal-ownership' }
    $gen = [long](Get-GHSField (Get-GHSField $own 'ownership' $null) 'generation' 0)
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-ghs' -ReadScopes @('src/ghs.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-GHSField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-GHSField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
    return @{ generation = $gen }
}
function Set-GHSBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-GHSField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-GHSField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-GHSField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-GHSField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-GHSField $tr 'error' '')) }
}
function New-GHSWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'ghw-goal-1', [string]$ReviewExpectation = 'ANY')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-ghs' -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/ghs' -ExpectedHeadSha $Sha -RequiredChecks @($script:policy.required_checks) -ReviewExpectation $ReviewExpectation -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-GHSField $reg 'ok' $false)) { throw ('wait:' + [string](Get-GHSField $reg 'reason' '')) }
}
function Get-GHSWaitFile {
    param($Env)
    $found = @(Get-ChildItem -LiteralPath $Env.waitsDir -File -Filter 'ghwait-*.json')
    if (@($found).Count -eq 0) { throw 'wait-missing' }
    return @($found)[0].FullName
}
function Set-GHSWaitField {
    param($Env, [string]$Name = '', $Value = $null)
    $wf = Get-GHSWaitFile -Env $Env
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($wf, [Text.Encoding]::UTF8))
    $doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    [IO.File]::WriteAllText($wf, (ConvertTo-Json -InputObject $doc -Depth 20), (New-Object Text.UTF8Encoding $false))
}
function New-GHSCkpt {
    param($Env, [string]$GoalId = 'ghw-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-GHSField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-GHSField $sv 'checkpoint_id' '')
}
function New-GHSNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-GHSRaw {
    param($Nodes, [string]$Head, [string]$Commit, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'REVIEW_REQUIRED', [long]$Pr = 42)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = $Pr; state = $State; headRefOid = $Head; mergeable = $Merge; reviewDecision = $Review; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-GHSFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-GHSGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:policy.required_checks)) { $out += @(New-GHSNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Write-GHSReview {
    param($Env, [string]$TaskId = '', [bool]$Approved = $true, [string]$Sha = '', [string]$Reviewer = 'reviewer-1', [string]$Author = 'author-1')
    if ([string]::IsNullOrWhiteSpace($Sha)) { $Sha = $script:SHA_A }
    $doc = [pscustomobject]@{ approved = $Approved; head_sha = $Sha; reviewer_identity = $Reviewer; author_identity = $Author }
    [IO.File]::WriteAllText((Join-Path $Env.reviewsDir ($TaskId + '.json')), (ConvertTo-Json -InputObject $doc -Depth 5), (New-Object Text.UTF8Encoding $false))
}
function Invoke-GHSDirect {
    param($Env, [string]$Fixture = '', [hashtable]$Extra = @{})
    $base = @{
        WaitsDir = $Env.waitsDir; TasksDir = $Env.tasksDir; GoalStoreDir = $Env.goalDir
        CheckpointDir = $Env.ckptDir; FlagsPath = $Env.flagsPath; Policy = $script:policy
        GraphQLSnapshotFile = $Fixture; MaxAgeSeconds = 300; NowUtc = $script:NOW
        ActorIdentitySource = 'explicit-cli'; AuthorizationAlive = $true; ExecutorPresent = $true
        CancelRequested = $false; MaxApiAttempts = 3; TimeoutMs = 10000
        DeliveryProfile = ''; SoloInternalReviewsDir = ''
    }
    foreach ($k in @($Extra.Keys)) { $base[$k] = $Extra[$k] }
    return (Invoke-GitHubWake @base)
}
# --- S1: default profile stays blocked without GitHub approval (unchanged).
$e1 = New-GHSEnv -Tag 's1'
[void](New-GHSGoal -Env $e1 -GoalId 'ghw-goal-1' -Tasks @('solo-task-1'))
Set-GHSBlocked -Env $e1 -TaskId 'solo-task-1' -Sha $script:SHA_A
New-GHSWait -Env $e1 -TaskId 'solo-task-1' -Sha $script:SHA_A -ReviewExpectation 'APPROVED'
[void](New-GHSCkpt -Env $e1 -GoalId 'ghw-goal-1')
$fx1 = Write-GHSFixture -Env $e1 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev1Before = [long](Get-OrchestrationTask -TaskId 'solo-task-1' -TasksDir $e1.tasksDir -RepoRoot $e1.root).revision
$r1 = Invoke-GHSDirect -Env $e1 -Fixture $fx1
$items1 = @(Get-GHSField $r1 'items' @())
Assert-That (([string](Get-GHSField @($items1)[0] 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-GHSField @($items1)[0] 'readiness' '') -ceq 'REVIEW_PENDING')) 'S1 default without GitHub approval => KEEP_WAITING REVIEW_PENDING'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-1' -TasksDir $e1.tasksDir -RepoRoot $e1.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-1' -TasksDir $e1.tasksDir -RepoRoot $e1.root).revision -eq $rev1Before)) 'S1 default => still BLOCKED, revision untouched'
Assert-That (-not [bool](Get-GHSField $r1 'resume_authorized' $true)) 'S1 default => resume_authorized false'
# --- S2: planner data never activates solo; only explicit opt-in selects it.
$e2a = New-GHSEnv -Tag 's2a'
[void](New-GHSGoal -Env $e2a -GoalId 'ghw-goal-1' -Tasks @('solo-task-2'))
Set-GHSBlocked -Env $e2a -TaskId 'solo-task-2' -Sha $script:SHA_A
New-GHSWait -Env $e2a -TaskId 'solo-task-2' -Sha $script:SHA_A -ReviewExpectation 'APPROVED'
Set-GHSWaitField -Env $e2a -Name 'delivery_profile' -Value 'solo-maintainer'
Write-GHSReview -Env $e2a -TaskId 'solo-task-2'
[void](New-GHSCkpt -Env $e2a -GoalId 'ghw-goal-1')
$fx2a = Write-GHSFixture -Env $e2a -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev2aBefore = [long](Get-OrchestrationTask -TaskId 'solo-task-2' -TasksDir $e2a.tasksDir -RepoRoot $e2a.root).revision
$r2a = Invoke-GHSDirect -Env $e2a -Fixture $fx2a
$items2a = @(Get-GHSField $r2a 'items' @())
Assert-That (([string](Get-GHSField @($items2a)[0] 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-GHSField @($items2a)[0] 'readiness' '') -ceq 'REVIEW_PENDING')) 'S2 planner wait field never activates solo => still KEEP_WAITING REVIEW_PENDING'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-2' -TasksDir $e2a.tasksDir -RepoRoot $e2a.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-2' -TasksDir $e2a.tasksDir -RepoRoot $e2a.root).revision -eq $rev2aBefore)) 'S2 planner field => still BLOCKED, revision untouched'
Assert-That (-not [bool](Get-GHSField $r2a 'resume_authorized' $true)) 'S2 planner field => resume_authorized false'
$e2b = New-GHSEnv -Tag 's2b'
[void](New-GHSGoal -Env $e2b -GoalId 'ghw-goal-1' -Tasks @('solo-task-2'))
Set-GHSBlocked -Env $e2b -TaskId 'solo-task-2' -Sha $script:SHA_A
New-GHSWait -Env $e2b -TaskId 'solo-task-2' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e2b -TaskId 'solo-task-2'
[void](New-GHSCkpt -Env $e2b -GoalId 'ghw-goal-1')
$fx2b = Write-GHSFixture -Env $e2b -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$r2b = Invoke-GHSDirect -Env $e2b -Fixture $fx2b -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e2b.reviewsDir }
$items2b = @(Get-GHSField $r2b 'items' @())
Assert-That ([string](Get-GHSField @($items2b)[0] 'decision' '') -ceq 'RESUME') 'S2 explicit operator opt-in => RESUME under solo'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-2' -TasksDir $e2b.tasksDir -RepoRoot $e2b.root).state -ceq 'IMPLEMENTING') 'S2 explicit opt-in => BLOCKED->IMPLEMENTING'
# --- S3: solo happy path end-to-end (real CLI) + technical readiness documented.
$e3 = New-GHSEnv -Tag 's3'
[void](New-GHSGoal -Env $e3 -GoalId 'ghw-goal-1' -Tasks @('solo-task-3'))
Set-GHSBlocked -Env $e3 -TaskId 'solo-task-3' -Sha $script:SHA_A
New-GHSWait -Env $e3 -TaskId 'solo-task-3' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e3 -TaskId 'solo-task-3'
[void](New-GHSCkpt -Env $e3 -GoalId 'ghw-goal-1')
$fx3 = Write-GHSFixture -Env $e3 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev3Before = [long](Get-OrchestrationTask -TaskId 'solo-task-3' -TasksDir $e3.tasksDir -RepoRoot $e3.root).revision
$r3 = Invoke-GHSChild -CliArgs @('-WaitsDir', $e3.waitsDir, '-TasksDir', $e3.tasksDir, '-GoalStoreDir', $e3.goalDir, '-CheckpointDir', $e3.ckptDir, '-FlagsPath', $e3.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fx3, '-AuthorizationAlive', '-ExecutorPresent', '-DeliveryProfile', 'solo-maintainer', '-SoloInternalReviewsDir', $e3.reviewsDir)
$items3 = @(Get-GHSField $r3.env 'items' @())
Assert-That (([int]$r3.code -eq 0) -and ([string](Get-GHSField @($items3)[0] 'decision' '') -ceq 'RESUME')) 'S3 solo CLI green+valid review => RESUME'
Assert-That ([string](Get-GHSField @($items3)[0] 'kernel' '') -ceq 'unblocked') 'S3 solo CLI => kernel unblocked'
Assert-That ([bool](Get-GHSField $r3.env 'resume_authorized' $false)) 'S3 solo RESUME => envelope resume_authorized'
Assert-That ((-not [bool](Get-GHSField $r3.env 'grants_authority' $true)) -and (-not [bool](Get-GHSField $r3.env 'merge_authority' $true)) -and (-not [bool](Get-GHSField $r3.env 'done_approved' $true))) 'S3 solo RESUME => zero grants/merge/done authority'
$nx3 = Get-GHSField $r3.env 'next_action' $null
Assert-That (($null -ne $nx3) -and ([string](Get-GHSField $nx3 'task_id' '') -ceq 'solo-task-3')) 'S3 solo RESUME => next action announces task'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-3' -TasksDir $e3.tasksDir -RepoRoot $e3.root).state -ceq 'IMPLEMENTING') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-3' -TasksDir $e3.tasksDir -RepoRoot $e3.root).revision -eq ($rev3Before + 1))) 'S3 solo => exactly one BLOCKED->IMPLEMENTING transition'
$snapChecks = @()
foreach ($n in @($script:policy.required_checks)) { $snapChecks += @([pscustomobject]@{ name = [string]$n; head_sha = $script:SHA_A; status = 'COMPLETED'; conclusion = 'success' }) }
$snapSolo = [pscustomobject]@{ repository = $script:REPO; pr_number = 42; head_sha = $script:SHA_A; commit_sha = $script:SHA_A; observed_at = $script:NOW; pr_state = 'OPEN'; mergeable = 'MERGEABLE'; review_decision = 'REVIEW_REQUIRED'; checks_complete = $true; checks = @($snapChecks) }
$int3 = [pscustomobject]@{ approved = $true; head_sha = $script:SHA_A; reviewer_identity = 'reviewer-1'; author_identity = 'author-1' }
$rdy3 = Get-OrchestrationGitHubReadiness -Repository $script:REPO -PrNumber 42 -ExpectedHeadSha $script:SHA_A -Snapshot $snapSolo -Policy $script:policy -NowUtc $script:NOW -MaxAgeSeconds 300 -DeliveryProfile 'solo-maintainer' -InternalReview $int3
Assert-That (($null -ne $rdy3) -and [bool](Get-GHSField $rdy3 'ok' $false) -and ([string](Get-GHSField $rdy3 'readiness' '') -ceq 'READY_FOR_RESUME')) 'S3 solo validators => READY_FOR_RESUME (existing validators, green CI + correct SHA + valid review)'
Assert-That (([string](Get-GHSField $rdy3 'review_basis' '') -ceq 'internal-agent') -and (-not [string]::IsNullOrWhiteSpace([string](Get-GHSField $rdy3 'review_detail' '')))) 'S3 solo readiness documents origin (review_basis internal-agent, QC-only limits)'
Assert-That ((-not [bool](Get-GHSField $rdy3 'grants_authority' $true)) -and (-not [bool](Get-GHSField $rdy3 'resume_authorized' $true))) 'S3 readiness carries no operational authorization (technical only)'
# --- S3 config-file path: scheduled config carries the operator opt-in.
$e3c = New-GHSEnv -Tag 's3c'
[void](New-GHSGoal -Env $e3c -GoalId 'ghw-goal-1' -Tasks @('solo-task-3'))
Set-GHSBlocked -Env $e3c -TaskId 'solo-task-3' -Sha $script:SHA_A
New-GHSWait -Env $e3c -TaskId 'solo-task-3' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e3c -TaskId 'solo-task-3'
[void](New-GHSCkpt -Env $e3c -GoalId 'ghw-goal-1')
$fx3c = Write-GHSFixture -Env $e3c -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$cfg3Path = Join-Path $e3c.root 'wake-solo.json'
$cfg3 = New-GitHubWakeConfig -Path $cfg3Path -WaitsDir $e3c.waitsDir -TasksDir $e3c.tasksDir -GoalStoreDir $e3c.goalDir -CheckpointDir $e3c.ckptDir -FlagsPath $e3c.flagsPath -GraphQLSnapshotFile $fx3c -DeliveryProfile 'solo-maintainer' -SoloInternalReviewsDir $e3c.reviewsDir
Assert-That ([bool](Get-GHSField $cfg3 'ok' $false)) 'S3 scheduled config with solo opt-in: written'
$cfg3Doc = $null
try { $cfg3Doc = ConvertFrom-Json ([IO.File]::ReadAllText($cfg3Path, [Text.Encoding]::UTF8)) } catch { $cfg3Doc = $null }
Assert-That (($null -ne $cfg3Doc) -and ([string](Get-GHSField $cfg3Doc 'delivery_profile' '') -ceq 'solo-maintainer')) 'S3 config persists delivery_profile opt-in (not authority)'
$r3c = Invoke-GHSChild -CliArgs @('-ConfigFile', $cfg3Path, '-NowUtc', $script:NOW, '-AuthorizationAlive', '-ExecutorPresent')
$items3c = @(Get-GHSField $r3c.env 'items' @())
Assert-That (([string](Get-GHSField @($items3c)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-GHSField @($items3c)[0] 'kernel' '') -ceq 'unblocked')) 'S3 scheduled ConfigFile with solo opt-in => RESUME (no per-tick profile flag)'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-3' -TasksDir $e3c.tasksDir -RepoRoot $e3c.root).state -ceq 'IMPLEMENTING') 'S3 config RESUME => BLOCKED->IMPLEMENTING'
# --- S4: missing/invalid/sha-divergent review and CHANGES_REQUESTED/stale blocks.
$e4a = New-GHSEnv -Tag 's4a'
[void](New-GHSGoal -Env $e4a -GoalId 'ghw-goal-1' -Tasks @('solo-task-4'))
Set-GHSBlocked -Env $e4a -TaskId 'solo-task-4' -Sha $script:SHA_A
New-GHSWait -Env $e4a -TaskId 'solo-task-4' -Sha $script:SHA_A -ReviewExpectation 'ANY'
[void](New-GHSCkpt -Env $e4a -GoalId 'ghw-goal-1')
$fx4a = Write-GHSFixture -Env $e4a -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$r4a = Invoke-GHSDirect -Env $e4a -Fixture $fx4a -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e4a.reviewsDir }
$items4a = @(Get-GHSField $r4a 'items' @())
Assert-That (([string](Get-GHSField @($items4a)[0] 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-GHSField @($items4a)[0] 'readiness' '') -ceq 'REVIEW_PENDING')) 'S4 missing internal review => KEEP_WAITING REVIEW_PENDING'
$e4b = New-GHSEnv -Tag 's4b'
[void](New-GHSGoal -Env $e4b -GoalId 'ghw-goal-1' -Tasks @('solo-task-4'))
Set-GHSBlocked -Env $e4b -TaskId 'solo-task-4' -Sha $script:SHA_A
New-GHSWait -Env $e4b -TaskId 'solo-task-4' -Sha $script:SHA_A -ReviewExpectation 'ANY'
[IO.File]::WriteAllText((Join-Path $e4b.reviewsDir 'solo-task-4.json'), '{"approved":"yes","head_sha":"cccccccccccccccccccccccccccccccccccccccc","reviewer_identity":"reviewer-1","author_identity":"author-1"}', (New-Object Text.UTF8Encoding $false))
[void](New-GHSCkpt -Env $e4b -GoalId 'ghw-goal-1')
$fx4b = Write-GHSFixture -Env $e4b -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$r4b = Invoke-GHSDirect -Env $e4b -Fixture $fx4b -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e4b.reviewsDir }
$items4b = @(Get-GHSField $r4b 'items' @())
Assert-That (([string](Get-GHSField @($items4b)[0] 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-GHSField @($items4b)[0] 'readiness' '') -ceq 'INCONCLUSIVE')) 'S4 malformed internal review => KEEP_WAITING INCONCLUSIVE, never RESUME'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4b.tasksDir -RepoRoot $e4b.root).state -ceq 'BLOCKED') 'S4 malformed review => still BLOCKED'
$e4c = New-GHSEnv -Tag 's4c'
[void](New-GHSGoal -Env $e4c -GoalId 'ghw-goal-1' -Tasks @('solo-task-4'))
Set-GHSBlocked -Env $e4c -TaskId 'solo-task-4' -Sha $script:SHA_A
New-GHSWait -Env $e4c -TaskId 'solo-task-4' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e4c -TaskId 'solo-task-4' -Sha $script:SHA_B
[void](New-GHSCkpt -Env $e4c -GoalId 'ghw-goal-1')
$fx4c = Write-GHSFixture -Env $e4c -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev4cBefore = [long](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4c.tasksDir -RepoRoot $e4c.root).revision
$r4c = Invoke-GHSDirect -Env $e4c -Fixture $fx4c -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e4c.reviewsDir }
$items4c = @(Get-GHSField $r4c 'items' @())
Assert-That (([string](Get-GHSField @($items4c)[0] 'decision' '') -ceq 'KEEP_WAITING') -and ([string](Get-GHSField @($items4c)[0] 'readiness' '') -ceq 'REVIEW_PENDING')) 'S4 review SHA mismatch => KEEP_WAITING REVIEW_PENDING (fail-closed, never RESUME)'
Assert-That ([string](Get-GHSField @($items4c)[0] 'notify' '') -cmatch 'internal-review-sha-mismatch') 'S4 review SHA mismatch => notify carries internal-review-sha-mismatch'
Assert-That (-not [bool](Get-GHSField $r4c 'resume_authorized' $true)) 'S4 review SHA mismatch => resume_authorized false'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4c.tasksDir -RepoRoot $e4c.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4c.tasksDir -RepoRoot $e4c.root).revision -eq $rev4cBefore)) 'S4 review SHA mismatch => still BLOCKED, revision untouched'
$e4d = New-GHSEnv -Tag 's4d'
[void](New-GHSGoal -Env $e4d -GoalId 'ghw-goal-1' -Tasks @('solo-task-4'))
Set-GHSBlocked -Env $e4d -TaskId 'solo-task-4' -Sha $script:SHA_A
New-GHSWait -Env $e4d -TaskId 'solo-task-4' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e4d -TaskId 'solo-task-4'
[void](New-GHSCkpt -Env $e4d -GoalId 'ghw-goal-1')
$fx4d = Write-GHSFixture -Env $e4d -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'CHANGES_REQUESTED') -Name 'changes.graphql.json'
$r4d = Invoke-GHSDirect -Env $e4d -Fixture $fx4d -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e4d.reviewsDir }
$items4d = @(Get-GHSField $r4d 'items' @())
Assert-That (([string](Get-GHSField @($items4d)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHSField @($items4d)[0] 'reason' '') -ceq 'diagnostic')) 'S4 CHANGES_REQUESTED under solo => TERMINAL diagnostic'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4d.tasksDir -RepoRoot $e4d.root).state -ceq 'BLOCKED') 'S4 CHANGES_REQUESTED => still BLOCKED'
$e4e = New-GHSEnv -Tag 's4e'
[void](New-GHSGoal -Env $e4e -GoalId 'ghw-goal-1' -Tasks @('solo-task-4'))
Set-GHSBlocked -Env $e4e -TaskId 'solo-task-4' -Sha $script:SHA_A
New-GHSWait -Env $e4e -TaskId 'solo-task-4' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e4e -TaskId 'solo-task-4'
[void](New-GHSCkpt -Env $e4e -GoalId 'ghw-goal-1')
$fx4e = Write-GHSFixture -Env $e4e -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_B) -Head $script:SHA_B -Commit $script:SHA_B -Review 'REVIEW_REQUIRED') -Name 'stale.graphql.json'
$r4e = Invoke-GHSDirect -Env $e4e -Fixture $fx4e -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e4e.reviewsDir }
$items4e = @(Get-GHSField $r4e 'items' @())
Assert-That (([string](Get-GHSField @($items4e)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHSField @($items4e)[0] 'reason' '') -ceq 'head-superseded')) 'S4 stale snapshot SHA under solo => TERMINAL head-superseded'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-4' -TasksDir $e4e.tasksDir -RepoRoot $e4e.root).state -ceq 'BLOCKED') 'S4 stale SHA => still BLOCKED'
# --- S5: solo waits use ANY; persisted APPROVED is INVALID, never migrated.
$e5 = New-GHSEnv -Tag 's5'
[void](New-GHSGoal -Env $e5 -GoalId 'ghw-goal-1' -Tasks @('solo-task-5'))
Set-GHSBlocked -Env $e5 -TaskId 'solo-task-5' -Sha $script:SHA_A
New-GHSWait -Env $e5 -TaskId 'solo-task-5' -Sha $script:SHA_A -ReviewExpectation 'APPROVED'
Write-GHSReview -Env $e5 -TaskId 'solo-task-5'
[void](New-GHSCkpt -Env $e5 -GoalId 'ghw-goal-1')
$fx5 = Write-GHSFixture -Env $e5 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev5Before = [long](Get-OrchestrationTask -TaskId 'solo-task-5' -TasksDir $e5.tasksDir -RepoRoot $e5.root).revision
$r5 = Invoke-GHSDirect -Env $e5 -Fixture $fx5 -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e5.reviewsDir }
$items5 = @(Get-GHSField $r5 'items' @())
Assert-That (([string](Get-GHSField @($items5)[0] 'decision' '') -ceq 'INVALID') -and ([string](Get-GHSField @($items5)[0] 'reason' '') -ceq 'policy-diverged')) 'S5 persisted APPROVED under solo ANY => INVALID policy-diverged'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-5' -TasksDir $e5.tasksDir -RepoRoot $e5.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-5' -TasksDir $e5.tasksDir -RepoRoot $e5.root).revision -eq $rev5Before)) 'S5 INVALID => still BLOCKED, revision untouched'
Assert-That (-not [bool](Get-GHSField $r5 'kernel_mutated' $true)) 'S5 INVALID => kernel untouched'
Assert-That ([IO.File]::ReadAllText((Get-GHSWaitFile -Env $e5), [Text.Encoding]::UTF8) -cmatch 'APPROVED') 'S5 divergent wait file left unmigrated on disk'
# --- S6: partial-tick recovery reuses the same gates (no duplication).
$e6 = New-GHSEnv -Tag 's6'
[void](New-GHSGoal -Env $e6 -GoalId 'ghw-goal-1' -Tasks @('solo-task-6'))
Set-GHSBlocked -Env $e6 -TaskId 'solo-task-6' -Sha $script:SHA_A
New-GHSWait -Env $e6 -TaskId 'solo-task-6' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e6 -TaskId 'solo-task-6'
[void](New-GHSCkpt -Env $e6 -GoalId 'ghw-goal-1')
$fx6 = Write-GHSFixture -Env $e6 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev6Before = [long](Get-OrchestrationTask -TaskId 'solo-task-6' -TasksDir $e6.tasksDir -RepoRoot $e6.root).revision
[IO.File]::WriteAllText($e6.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$rp1 = Invoke-GHSDirect -Env $e6 -Fixture $fx6 -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e6.reviewsDir }
$itemsP1 = @(Get-GHSField $rp1 'items' @())
Assert-That (([string](Get-GHSField @($itemsP1)[0] 'reason' '') -ceq 'unblock-refused:KERNEL_DISABLED') -and [bool](Get-GHSField @($itemsP1)[0] 'confirmed' $false)) 'S6 setup: confirm applied, unblock refused, event recorded'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-6' -TasksDir $e6.tasksDir -RepoRoot $e6.root).state -ceq 'BLOCKED') 'S6 setup: task still BLOCKED after failed unblock'
[IO.File]::WriteAllText($e6.flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$rp2 = Invoke-GHSDirect -Env $e6 -Fixture $fx6 -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e6.reviewsDir }
$itemsP2 = @(Get-GHSField $rp2 'items' @())
Assert-That (([string](Get-GHSField @($itemsP2)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-GHSField @($itemsP2)[0] 'reason' '') -ceq 'reconciled-pending-unblock')) 'S6 recovery under solo => RESUME reconciled-pending-unblock (same gates, no eternal DUPLICATE_NOOP)'
Assert-That ([string](Get-GHSField @($itemsP2)[0] 'kernel' '') -ceq 'unblocked') 'S6 recovery => kernel unblocked exactly once'
Assert-That ([long](Get-OrchestrationTask -TaskId 'solo-task-6' -TasksDir $e6.tasksDir -RepoRoot $e6.root).revision -eq ($rev6Before + 1)) 'S6 recovery => exactly one unblock transition across both ticks'
$e6b = New-GHSEnv -Tag 's6b'
[void](New-GHSGoal -Env $e6b -GoalId 'ghw-goal-1' -Tasks @('solo-task-6'))
Set-GHSBlocked -Env $e6b -TaskId 'solo-task-6' -Sha $script:SHA_A
New-GHSWait -Env $e6b -TaskId 'solo-task-6' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e6b -TaskId 'solo-task-6'
[void](New-GHSCkpt -Env $e6b -GoalId 'ghw-goal-1')
$fx6b = Write-GHSFixture -Env $e6b -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
[IO.File]::WriteAllText($e6b.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$rq1 = Invoke-GHSDirect -Env $e6b -Fixture $fx6b -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e6b.reviewsDir }
Assert-That ([string](Get-GHSField @(@(Get-GHSField $rq1 'items' @()))[0] 'reason' '') -ceq 'unblock-refused:KERNEL_DISABLED') 'S6 negative setup: first tick confirms then refuses unblock'
[IO.File]::WriteAllText($e6b.flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
Remove-Item -LiteralPath (Join-Path $e6b.reviewsDir 'solo-task-6.json') -Force
$rq2 = Invoke-GHSDirect -Env $e6b -Fixture $fx6b -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e6b.reviewsDir }
$itemsQ2 = @(Get-GHSField $rq2 'items' @())
Assert-That ([string](Get-GHSField @($itemsQ2)[0] 'decision' '') -ceq 'DUPLICATE_NOOP') 'S6 recovery without valid review => DUPLICATE_NOOP (same gates, no unblock)'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-6' -TasksDir $e6b.tasksDir -RepoRoot $e6b.root).state -ceq 'BLOCKED') 'S6 recovery without review => still BLOCKED'
# --- S7: technical readiness without executor/authorization never advances.
$e7 = New-GHSEnv -Tag 's7'
[void](New-GHSGoal -Env $e7 -GoalId 'ghw-goal-1' -Tasks @('solo-task-7'))
Set-GHSBlocked -Env $e7 -TaskId 'solo-task-7' -Sha $script:SHA_A
New-GHSWait -Env $e7 -TaskId 'solo-task-7' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e7 -TaskId 'solo-task-7'
[void](New-GHSCkpt -Env $e7 -GoalId 'ghw-goal-1')
$fx7 = Write-GHSFixture -Env $e7 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev7Before = [long](Get-OrchestrationTask -TaskId 'solo-task-7' -TasksDir $e7.tasksDir -RepoRoot $e7.root).revision
$r7a = Invoke-GHSDirect -Env $e7 -Fixture $fx7 -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e7.reviewsDir; ExecutorPresent = $false }
$items7a = @(Get-GHSField $r7a 'items' @())
Assert-That (([string](Get-GHSField @($items7a)[0] 'decision' '') -ceq 'READY') -and ([string](Get-GHSField @($items7a)[0] 'reason' '') -ceq 'ready-no-executor')) 'S7 solo without executor => READY ready-no-executor (observation only)'
Assert-That ($null -eq (Get-GHSField $r7a 'next_action' $null)) 'S7 READY => no next action (no NativeResume, no settlement)'
Assert-That (-not [bool](Get-GHSField $r7a 'resume_authorized' $true)) 'S7 READY => resume_authorized false'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-7' -TasksDir $e7.tasksDir -RepoRoot $e7.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-7' -TasksDir $e7.tasksDir -RepoRoot $e7.root).revision -eq $rev7Before)) 'S7 READY => still BLOCKED, revision untouched'
$r7b = Invoke-GHSDirect -Env $e7 -Fixture $fx7 -Extra @{ DeliveryProfile = 'solo-maintainer'; SoloInternalReviewsDir = $e7.reviewsDir; AuthorizationAlive = $false }
$items7b = @(Get-GHSField $r7b 'items' @())
Assert-That (([string](Get-GHSField @($items7b)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHSField @($items7b)[0] 'reason' '') -ceq 'authorization-revoked')) 'S7 solo with revoked authorization => TERMINAL authorization-revoked'
Assert-That (($null -eq (Get-GHSField $r7b 'next_action' $null)) -and (-not [bool](Get-GHSField $r7b 'resume_authorized' $true))) 'S7 revoked authz => no next action, resume_authorized false'
Assert-That ([string](Get-OrchestrationTask -TaskId 'solo-task-7' -TasksDir $e7.tasksDir -RepoRoot $e7.root).state -ceq 'BLOCKED') 'S7 revoked authz => still BLOCKED'
# --- S8: unknown or malformed profile fails closed.
$e8 = New-GHSEnv -Tag 's8'
[void](New-GHSGoal -Env $e8 -GoalId 'ghw-goal-1' -Tasks @('solo-task-8'))
Set-GHSBlocked -Env $e8 -TaskId 'solo-task-8' -Sha $script:SHA_A
New-GHSWait -Env $e8 -TaskId 'solo-task-8' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e8 -TaskId 'solo-task-8'
[void](New-GHSCkpt -Env $e8 -GoalId 'ghw-goal-1')
$fx8 = Write-GHSFixture -Env $e8 -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$rev8Before = [long](Get-OrchestrationTask -TaskId 'solo-task-8' -TasksDir $e8.tasksDir -RepoRoot $e8.root).revision
$r8 = Invoke-GHSDirect -Env $e8 -Fixture $fx8 -Extra @{ DeliveryProfile = 'no-such-profile'; SoloInternalReviewsDir = $e8.reviewsDir }
$items8 = @(Get-GHSField $r8 'items' @())
Assert-That (([string](Get-GHSField @($items8)[0] 'decision' '') -ceq 'INVALID') -and ([string](Get-GHSField @($items8)[0] 'reason' '') -ceq 'policy-invalid')) 'S8 unknown profile => INVALID policy-invalid'
Assert-That (([string](Get-OrchestrationTask -TaskId 'solo-task-8' -TasksDir $e8.tasksDir -RepoRoot $e8.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'solo-task-8' -TasksDir $e8.tasksDir -RepoRoot $e8.root).revision -eq $rev8Before)) 'S8 unknown profile => still BLOCKED, revision untouched'
$r8b = Invoke-GHSChild -CliArgs @('-WaitsDir', $e8.waitsDir, '-TasksDir', $e8.tasksDir, '-GoalStoreDir', $e8.goalDir, '-CheckpointDir', $e8.ckptDir, '-FlagsPath', $e8.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fx8, '-AuthorizationAlive', '-ExecutorPresent', '-DeliveryProfile', 'evil profile!')
Assert-That (([int]$r8b.code -eq 2) -and ($null -ne $r8b.env) -and ([string](Get-GHSField $r8b.env 'reason' '') -ceq 'invalid-delivery-profile')) 'S8 malformed profile value => exit 2 invalid-delivery-profile'
# --- S8c: solo opt-in without operator reviews dir fails closed (CLI + config).
$r8c = Invoke-GHSChild -CliArgs @('-WaitsDir', $e8.waitsDir, '-TasksDir', $e8.tasksDir, '-GoalStoreDir', $e8.goalDir, '-CheckpointDir', $e8.ckptDir, '-FlagsPath', $e8.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fx8, '-AuthorizationAlive', '-ExecutorPresent', '-DeliveryProfile', 'solo-maintainer')
Assert-That (([int]$r8c.code -eq 2) -and ($null -ne $r8c.env) -and ([string](Get-GHSField $r8c.env 'reason' '') -ceq 'invalid-solo-reviews-dir')) 'S8 solo CLI without reviews dir => exit 2 invalid-solo-reviews-dir'
$e8c = New-GHSEnv -Tag 's8c'
[void](New-GHSGoal -Env $e8c -GoalId 'ghw-goal-1' -Tasks @('solo-task-8'))
Set-GHSBlocked -Env $e8c -TaskId 'solo-task-8' -Sha $script:SHA_A
New-GHSWait -Env $e8c -TaskId 'solo-task-8' -Sha $script:SHA_A -ReviewExpectation 'ANY'
Write-GHSReview -Env $e8c -TaskId 'solo-task-8'
[void](New-GHSCkpt -Env $e8c -GoalId 'ghw-goal-1')
$fx8c = Write-GHSFixture -Env $e8c -Raw (New-GHSRaw -Nodes (New-GHSGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -Review 'REVIEW_REQUIRED') -Name 'pending-review.graphql.json'
$cfg8Path = Join-Path $e8c.root 'wake-solo-nodir.json'
$cfg8 = New-GitHubWakeConfig -Path $cfg8Path -WaitsDir $e8c.waitsDir -TasksDir $e8c.tasksDir -GoalStoreDir $e8c.goalDir -CheckpointDir $e8c.ckptDir -FlagsPath $e8c.flagsPath -GraphQLSnapshotFile $fx8c -DeliveryProfile 'solo-maintainer'
Assert-That ([bool](Get-GHSField $cfg8 'ok' $false)) 'S8 scheduled config without reviews dir: written'
$r8d = Invoke-GHSChild -CliArgs @('-ConfigFile', $cfg8Path, '-NowUtc', $script:NOW, '-AuthorizationAlive', '-ExecutorPresent')
Assert-That (([int]$r8d.code -eq 2) -and ($null -ne $r8d.env) -and ([string](Get-GHSField $r8d.env 'reason' '') -ceq 'invalid-solo-reviews-dir')) 'S8 scheduled config without reviews dir => exit 2 invalid-solo-reviews-dir'
Write-Output ('github-wake-solo tests PASS: ' + [string]$script:passed)
