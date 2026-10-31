# github-wake.tests.ps1 -- Etapa 6D GH-WAKE real single-shot CLI + schtasks scheduler.
# Custom PS 5.1 / PS7 suite, no Pester. Fixtures in owned TEMP. Offline only
# (no live network, no gh required): every behavior case uses
# -GraphQLSnapshotFile (raw GraphQL shape through the REAL
# Convert-GHARawToSnapshot normalizer). Live transport is proven only in
# full-delivery-etapa6d-proof.ps1. Covers: strict arg validation (exit 2),
# one-shot shape (no daemon/loop-unbounded/sleep-outside-backoff/merge/deploy),
# transport+readiness reuse (never reimplemented), bounded retry budget
# (max 3 attempts), scheduler XML via schtasks.exe (dry-run, no module),
# RESUME + CAS + unblock, DUPLICATE_NOOP, already-done, stale SHA TERMINAL,
# closed PR TERMINAL, red-checks diagnostic (no unblock), pending
# KEEP_WAITING, authz-revoked TERMINAL, no-executor READY, graphql-errors
# api-failure, stale checkpoint HOLD. ASCII only.
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
# --- dot-source safety: helpers exposed, nothing executed on load.
Assert-That ($null -ne (Get-Command Register-GitHubWakeSchedule -ErrorAction SilentlyContinue)) 'dot-source exposes Register-GitHubWakeSchedule'
Assert-That ($null -ne (Get-Command Unregister-GitHubWakeSchedule -ErrorAction SilentlyContinue)) 'dot-source exposes Unregister-GitHubWakeSchedule'
Assert-That ($null -ne (Get-Command New-GitHubWakeConfig -ErrorAction SilentlyContinue)) 'dot-source exposes New-GitHubWakeConfig'
Assert-That ($null -ne (Get-Command Invoke-GitHubWake -ErrorAction SilentlyContinue)) 'dot-source exposes Invoke-GitHubWake core'
# --- one-shot shape + reuse pins.
$cliText = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
foreach ($bad in @('while\s*\(', 'Start-Job', 'System\.Timers', 'Register-ObjectEvent', 'FileSystemWatcher', 'Register-ScheduledTask', 'Import-Module ScheduledTasks', 'New-Service', 'Start-Service', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', 'Start-Process', 'gh pr merge', 'gh pr create', 'gh pr comment', 'gh pr edit', 'gh pr close', '--method POST', '--method PUT', '--method PATCH', '--method DELETE', 'Complete-OrchestrationTask', 'Set-OrchestrationGoal', 'New-OrchestrationTask', 'grants_authority = \$true', 'merge_authority = \$true', 'done_approved = \$true', 'GH_TOKEN', 'GITHUB_TOKEN', 'function Convert-GHARawToSnapshot', 'function Invoke-GHAChildTransport', 'function Get-GHAGhArgs', 'function Get-OrchestrationGitHubReadiness', 'function Test-OrchestrationGitHubResume', 'function Confirm-OrchestrationGitHubResumeApplied', 'C:\\Users')) {
    Assert-That ($cliText -cnotmatch $bad) ('CLI has no daemon/mutation/secret/reimplementation pattern: ' + $bad)
}
foreach ($need in @('github-await\.ps1', 'Convert-GHARawToSnapshot', 'Get-OrchestrationGitHubReadiness', 'Test-OrchestrationGitHubResume', 'Confirm-OrchestrationGitHubResumeApplied', 'Invoke-OrchestrationTaskTransition', 'Load-OrchestrationGoalCheckpoint', 'Test-OrchestrationCheckpointResume', 'schtasks')) {
    Assert-That ($cliText -cmatch $need) ('CLI reuses/pins required surface: ' + $need)
}
# Bounded retry: exactly one backoff sleep, capped attempts.
$sleepCount = ([regex]::Matches($cliText, 'Start-Sleep')).Count
Assert-That ($sleepCount -le 1) 'at most one Start-Sleep (bounded api backoff only)'
Assert-That ($cliText -cmatch 'MaxApiAttempts') 'retry budget parameter exists'
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
function Invoke-GHWChild {
    param([string[]]$CliArgs = @())
    $out = & $script:childExe -NoProfile -File $script:cli @CliArgs 2>$null
    $code = $LASTEXITCODE
    $text = ''
    if ($null -ne $out) { $text = ($out -join "`n").Trim() }
    $env = $null
    try { if (-not [string]::IsNullOrWhiteSpace($text)) { $env = ConvertFrom-Json $text } } catch { $env = $null }
    return @{ code = $code; text = $text; env = $env }
}
function Get-GHWField {
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
$script:reqChecks = @()
try { $script:reqChecks = @(Get-OrchestrationDeliveryRequiredChecks $script:policy) } catch { $script:reqChecks = @() }
Assert-That (@($script:reqChecks).Count -gt 0) 'policy carries required checks'
$script:SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:SHA_C = 'cccccccccccccccccccccccccccccccccccccccc'
$script:NOW = '2026-10-10T12:02:00Z'
$script:FUTURE = '2026-10-11T00:00:00Z'
$script:REPO = 'acme/widgets'
function New-GHWEnv {
    param([string]$Tag = 'w')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('ghw-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $root 'goals'; $ckptDir = Join-Path $root 'ckpts'
    $tasksDir = Join-Path $root 'tasks'; $waitsDir = Join-Path $root 'waits'
    foreach ($d in @($root, $goalDir, $ckptDir, $tasksDir, $waitsDir)) { [void][IO.Directory]::CreateDirectory($d) }
    $flagsPath = Join-Path $root 'flags.json'
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    return @{ root = $root; goalDir = $goalDir; ckptDir = $ckptDir; tasksDir = $tasksDir; waitsDir = $waitsDir; flagsPath = $flagsPath }
}
function New-GHWGoal {
    param($Env, [string]$GoalId = 'ghw-goal-1', [string[]]$Tasks = @())
    $g = New-OrchestrationGoal -GoalId $GoalId -Objective 'etapa 6d wake' -Criteria @('c1') -TotalPhases 1 -StoreDir $Env.goalDir
    if (-not [bool](Get-GHWField $g 'ok' $false)) { throw ('goal-create:' + [string](Get-GHWField $g 'reason' '')) }
    $svNew = Save-OrchestrationGoal -Goal (Get-GHWField $g 'goal' $null) -StoreDir $Env.goalDir
    if (-not [bool](Get-GHWField $svNew 'ok' $false)) { throw 'goal-save' }
    $slot0 = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir
    $goal0 = Get-GHWField $slot0 'goal' $null
    $sv0 = Save-OrchestrationGoal -Goal (Set-OrchestrationGoalState -Goal $goal0 -ToState 'ACTIVE').goal -StoreDir $Env.goalDir
    if (-not [bool](Get-GHWField $sv0 'ok' $false)) { throw 'goal-activate' }
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $own = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$live['revision']) -StoreDir $Env.goalDir
    if (-not [bool](Get-GHWField $own 'ok' $false)) { throw 'goal-ownership' }
    $gen = [long](Get-GHWField (Get-GHWField $own 'ownership' $null) 'generation' 0)
    foreach ($tid in @($Tasks)) {
        $c = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.3' -BaseRevision 'rev-ghw' -ReadScopes @('src/ghw.ps1') -Grants @('fs.read') -AcceptanceCriteria @('criterion:0') -AttemptBudget 3 -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-GHWField $c 'ok' $false)) { throw ('task-create:' + $tid) }
        $curRev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal['revision']
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $tid -ExpectedRevision $curRev -StoreDir $Env.goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        if (-not [bool](Get-GHWField $add 'ok' $false)) { throw ('attach:' + $tid) }
    }
    return @{ generation = $gen }
}
function Set-GHWBlocked {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42)
    $dep = ('github-ci:v1:' + $script:REPO + ':' + [string]$Pr + ':' + $Sha)
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-GHWField $t 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-GHWField $tr 'ok' $false)) { throw ('to-planning:' + $TaskId) }
    $rev = [long](Get-GHWField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'BLOCKED' -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root -WaitType 'external_dependency' -WaitOwner 'planner-1' -WaitAction 'revalidate-github-ci' -WaitDependencyId $dep
    if (-not [bool](Get-GHWField $tr 'ok' $false)) { throw ('to-blocked:' + $TaskId + ':' + [string](Get-GHWField $tr 'error' '')) }
}
function Set-GHWDone {
    param($Env, [string]$TaskId = '')
    $t = Get-OrchestrationTask -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root
    $rev = [long](Get-GHWField $t 'revision' 0)
    foreach ($st in @('PLANNING', 'IMPLEMENTING')) {
        $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState $st -Actor 'planner' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
        if (-not [bool](Get-GHWField $tr 'ok' $false)) { throw ('pre:' + $st) }
        $rev = [long](Get-GHWField $tr 'revision' 0)
    }
    $wr = Set-OrchestrationTaskWorkerResult -TaskId $TaskId -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision $rev -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    $rev = [long](Get-GHWField $wr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'VALIDATING' -Actor 'coder' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    $rev = [long](Get-GHWField $tr 'revision' 0)
    $tr = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState 'REVIEWING' -Actor 'tester' -ExpectedRevision $rev -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    $rev = [long](Get-GHWField $tr 'revision' 0)
    $vr = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson '{"ok":true,"task_id":"ghw","status":"verified_pass","reason":"","scope":null,"profiles":[],"evidence":["criterion:0:verified"],"command_classes":["test"]}' -ExpectedRevision $rev -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath
    $rev = [long](Get-GHWField $vr 'revision' 0)
    $rw = Set-OrchestrationTaskReview -TaskId $TaskId -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision $rev -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath
    $rev = [long](Get-GHWField $rw 'revision' 0)
    $gate = Test-OrchestrationTaskCompletion -TaskId $TaskId -TasksDir $Env.tasksDir -RepoRoot $Env.root -OrchestrationCompliance 'COMPLIANT' -Actor 'planner' -ResidualRisks @('none') -AcceptEmptyResidualRisks
    if (-not [bool](Get-GHWField $gate 'complete' $false)) { throw 'gate' }
    $dn = Complete-OrchestrationTask -TaskId $TaskId -Actor 'planner' -ExpectedRevision $rev -ResidualRisks @('none') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $Env.tasksDir -FlagsPath $Env.flagsPath -TelemetryRoot $Env.root
    if (-not [bool](Get-GHWField $dn 'ok' $false)) { throw 'done' }
}
function New-GHWWait {
    param($Env, [string]$TaskId = '', [string]$Sha = '', [long]$Pr = 42, [string]$GoalId = 'ghw-goal-1')
    $reg = Register-OrchestrationGitHubWait -WaitsDir $Env.waitsDir -ObjectiveId $GoalId -TaskId $TaskId -RunId 'run-ghw' -Generation 1 -Repository $script:REPO -PrNumber $Pr -Branch 'fix/ghw' -ExpectedHeadSha $Sha -RequiredChecks @($script:reqChecks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $script:FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1'
    if (-not [bool](Get-GHWField $reg 'ok' $false)) { throw ('wait:' + [string](Get-GHWField $reg 'reason' '')) }
}
function New-GHWCkpt {
    param($Env, [string]$GoalId = 'ghw-goal-1')
    $live = (Get-OrchestrationGoal -GoalId $GoalId -StoreDir $Env.goalDir).goal
    $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $live
    if ($null -eq $ckpt) { throw 'ckpt-new' }
    $sv = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $Env.ckptDir
    if (-not [bool](Get-GHWField $sv 'ok' $false)) { throw 'ckpt-save' }
    return [string](Get-GHWField $sv 'checkpoint_id' '')
}
function New-GHWNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion; checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } } }
}
function New-GHWRaw {
    param($Nodes, [string]$Head, [string]$Commit, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'APPROVED', [long]$Pr = 42)
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'C1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:REPO; pullRequest = [pscustomobject]@{ number = $Pr; state = $State; headRefOid = $Head; mergeable = $Merge; reviewDecision = $Review; commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) } } } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-GHWFixture {
    param($Env, $Raw, [string]$Name)
    $p = Join-Path $Env.root $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
function New-GHWGreenNodes {
    param([string]$Sha)
    $out = @()
    foreach ($n in @($script:reqChecks)) { $out += @(New-GHWNode $n 'COMPLETED' 'SUCCESS' $Sha) }
    return $out
}
function Invoke-GHWCase {
    param($Env, [string]$Fixture = '', [bool]$Auth = $false, [bool]$Exec = $false)
    $a = @('-WaitsDir', $Env.waitsDir, '-TasksDir', $Env.tasksDir, '-GoalStoreDir', $Env.goalDir, '-CheckpointDir', $Env.ckptDir, '-FlagsPath', $Env.flagsPath, '-NowUtc', $script:NOW)
    if (-not [string]::IsNullOrWhiteSpace($Fixture)) { $a += @('-GraphQLSnapshotFile', $Fixture) }
    if ($Auth) { $a += @('-AuthorizationAlive') }
    if ($Exec) { $a += @('-ExecutorPresent') }
    return (Invoke-GHWChild -CliArgs $a)
}
# --- exit 2: strict arg validation; no-arg invocation stays silent (dot-source safe).
$r = Invoke-GHWChild @()
Assert-That (([int]$r.code -eq 0) -and [string]::IsNullOrWhiteSpace($r.text)) 'no args => silent (dot-source safe, nothing executed)'
$r = Invoke-GHWChild @('-WaitsDir', 'Z:\nope\missing', '-TasksDir', 'Z:\nope\missing')
Assert-That (([int]$r.code -eq 2) -and ($null -ne $r.env) -and ([string](Get-GHWField $r.env 'verdict' '') -ceq 'WAKE_FAIL')) 'missing dirs on disk => exit 2 WAKE_FAIL'
# --- scheduler pure surface (dry-run, no schtasks mutation).
$badName = Register-GitHubWakeSchedule -TaskName 'bad name!' -WakeScript $script:cli -ConfigFile $script:cli
Assert-That ((-not [bool](Get-GHWField $badName 'ok' $true)) -and ([string](Get-GHWField $badName 'reason' '') -ceq 'invalid-task-name')) 'scheduler refuses bad task name'
$dry = Register-GitHubWakeSchedule -TaskName 'ghw-wake-test' -WakeScript $script:cli -ConfigFile $script:cli -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5 -DryRun
Assert-That ([bool](Get-GHWField $dry 'ok' $false)) 'scheduler dry-run ok'
$dryXml = [string](Get-GHWField $dry 'xml' '')
Assert-That (($dryXml -cmatch 'PT5M') -and ($dryXml -cmatch 'PT12H') -and ($dryXml -cmatch 'ExecutionTimeLimit') -and ($dryXml -cmatch 'DisallowStartIfOnBatteries') -and ($dryXml -cmatch 'StopIfGoingOnBatteries') -and ($dryXml -cmatch 'schtasks') -or ($dryXml -cmatch 'powershell')) 'scheduler xml carries bounded repetition + battery pins + action'
Assert-That ($dryXml -cmatch 'false') 'scheduler xml disables battery blocks'
Assert-That ($dryXml -cnotmatch '<AllowStartIfOnBatteries>') 'scheduler xml omits invalid AllowStartIfOnBatteries (schtasks schema rejects it: 29,7)'
Assert-That (($dryXml -cmatch '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>') -and ($dryXml -cmatch '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>')) 'scheduler xml keeps valid battery pins disabled'
$sbM = [regex]::Match($dryXml, '<StartBoundary>([^<]+)</StartBoundary>')
Assert-That ($sbM.Success) 'scheduler xml carries StartBoundary'
$sbText = $sbM.Groups[1].Value
Assert-That (($sbText -cnotmatch 'Z$') -and ($sbText -cnotmatch '[+-]\d{2}:\d{2}$')) 'StartBoundary is local wall-clock (no zone suffix; Scheduler parses local time)'
$sbParsed = [datetime]::MinValue
Assert-That ([datetime]::TryParse($sbText, [ref]$sbParsed)) 'StartBoundary parseable as local datetime'
$sbDeltaMin = ($sbParsed - [datetime]::Now).TotalMinutes
Assert-That (($sbDeltaMin -ge 1) -and ($sbDeltaMin -le 5)) 'StartBoundary is now+2min (1-5min future window)'
$sbXmlDoc = $null
try { $sbXmlDoc = [xml]$dryXml } catch { $sbXmlDoc = $null }
Assert-That ($null -ne $sbXmlDoc) 'scheduler dry-run xml parses via [xml]'
Assert-That ([bool](Test-GHWScheduleOwner -ExistingXml $dryXml -WakeScript $script:cli -ConfigFile $script:cli)) 'scheduler dry-run xml still ownership-checked (owned Exec Command+Arguments)'
$dryCmd = [string](Get-GHWField $dry 'command' '')
Assert-That ($dryCmd -cmatch 'schtasks') 'scheduler dry-run shows schtasks command'
$un = Unregister-GitHubWakeSchedule -TaskName 'ghw-wake-test' -DryRun
Assert-That ([bool](Get-GHWField $un 'ok' $false)) 'unregister dry-run ok'
$cfgPath = Join-Path ([IO.Path]::GetTempPath()) ('ghw-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg = New-GitHubWakeConfig -Path $cfgPath -WaitsDir 'C:\w' -TasksDir 'C:\t' -GoalStoreDir 'C:\g' -CheckpointDir 'C:\c' -AuthorizationAlive $true -ExecutorPresent $false
Assert-That ((Test-Path -LiteralPath $cfgPath -PathType Leaf) -and [bool](Get-GHWField $cfg 'ok' $false)) 'config writer persists JSON'
$cfgDocCheck = $null
try { $cfgDocCheck = ConvertFrom-Json ([IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)) } catch { $cfgDocCheck = $null }
Assert-That (($null -ne $cfgDocCheck) -and (-not [bool](Get-GHWField $cfgDocCheck 'authorization_alive' $true)) -and (-not [bool](Get-GHWField $cfgDocCheck 'executor_present' $true)) -and (-not [bool](Get-GHWField $cfgDocCheck 'cancel_requested' $true))) 'config never persists authz/executor/cancel as true (fail-closed)'
Assert-That ($cliText -cnotmatch "cfgDoc 'authorization_alive'") 'CLI never promotes authorization_alive from config'
Assert-That ($cliText -cnotmatch 'confirm-failed-after-unblock') 'irrecoverable confirm-after-unblock window removed'
Assert-That (($cliText -cmatch 'reconciled-pending-confirm') -and ($cliText -cmatch "'reconciled'")) 'reconciliation path announces reconciled-pending-confirm with kernel=reconciled'
Assert-That ($cliText -cmatch 'task-name-conflict') 'scheduler fail-closed conflict reason pinned'
Assert-That ($null -ne (Get-Command Test-GHWScheduleOwner -ErrorAction SilentlyContinue)) 'scheduler owner helper exposed'
$xmlOwned = Get-GHWSchtasksXml -TaskName 'ghw-owner-ok' -WakeScript $script:cli -ConfigFile $script:cli -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5
Assert-That ([bool](Test-GHWScheduleOwner -ExistingXml $xmlOwned -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: owned Exec Command+Arguments => true'
Assert-That ([bool](Test-GHWScheduleOwner -ExistingXml $xmlOwned -WakeScript $script:cli.ToUpperInvariant() -ConfigFile $script:cli.ToUpperInvariant())) 'owner normalization: Windows paths match case-insensitively'
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlOwned -WakeScript $script:cli -ConfigFile 'C:\other\foreign.json')) 'owner exact match: divergent config token => false'
$xmlDivCmd = ([string]$xmlOwned).Replace('powershell.exe', 'cmd.exe')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlDivCmd -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: divergent Command => false'
$descOnlyXml = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>Etapa 6D GH-WAKE single-shot: ' + $script:cli + ' ' + $script:cli + '</Description></RegistrationInfo><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "C:\other\foreign.ps1" -ConfigFile "C:\other\foreign.json"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $descOnlyXml -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: paths only in Description (not Exec.Arguments) => false'
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml 'unrelated xml' -WakeScript $script:cli -ConfigFile $script:cli)) 'owner helper false on foreign xml (conflict)'
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml '' -WakeScript $script:cli -ConfigFile $script:cli)) 'owner helper false on empty xml (fail-closed)'
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml 'not xml at all <>>>' -WakeScript $script:cli -ConfigFile $script:cli)) 'owner fail-closed: invalid xml => false'
$xmlTwoExec = ([string]$xmlOwned).Replace('</Exec>', '</Exec><Exec><Command>C:\Windows\System32\cmd.exe</Command><Arguments>/c evil</Arguments></Exec>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlTwoExec -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: two Exec actions => false (fail-closed)'
$xmlNoFileFlag = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile "' + $script:cli + '" "' + $script:cli + '"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlNoFileFlag -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: paths without -File pair => false'
$xmlDivFile = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "C:\other\foreign.ps1" -ConfigFile "' + $script:cli + '"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlDivFile -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: divergent -File value => false'
$xmlNoCfg = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "' + $script:cli + '"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlNoCfg -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: missing -ConfigFile pair => false'
Assert-That ([bool](Test-GHWScheduleOwner -ExistingXml $xmlOwned -WakeScript $script:cli.ToLowerInvariant() -ConfigFile $script:cli.ToLowerInvariant())) 'owner exact match: valid owned with different case => true'
$xmlQuotedCmd = (([string]$xmlOwned).Replace('<Command>', '<Command>"').Replace('powershell.exe</Command>', 'powershell.exe"</Command>'))
Assert-That ([bool](Test-GHWScheduleOwner -ExistingXml $xmlQuotedCmd -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: quoted powershell.exe Command => true'
$xmlDupFile = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile -File "C:\evil\run.ps1" -File "' + $script:cli + '" -ConfigFile "' + $script:cli + '"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlDupFile -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: foreign first -File with second -File => false'
$xmlDupCfg = ('<?xml version="1.0" encoding="UTF-16"?><Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Actions><Exec><Command>C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe</Command><Arguments>-NoProfile -File "' + $script:cli + '" -ConfigFile "' + $script:cli + '" -ConfigFile "' + $script:cli + '"</Arguments></Exec></Actions></Task>')
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlDupCfg -WakeScript $script:cli -ConfigFile $script:cli)) 'owner exact match: duplicate -ConfigFile => false'
$resumeIdxPin = $cliText.IndexOf('$dName -ceq')
$confirmIdxPin = -1
$transIdxPin = -1
if ($resumeIdxPin -ge 0) {
    $confirmIdxPin = $cliText.IndexOf('Confirm-OrchestrationGitHubResumeApplied', $resumeIdxPin)
    $transIdxPin = $cliText.IndexOf('Invoke-OrchestrationTaskTransition', $resumeIdxPin)
}
Assert-That (($resumeIdxPin -ge 0) -and ($confirmIdxPin -gt $resumeIdxPin) -and ($transIdxPin -gt $confirmIdxPin)) 'Confirm-before-Unblock pinned: primary RESUME confirms CAS before unblock transition'
Assert-That (($dryXml -cmatch [regex]::Escape($script:cli))) 'scheduler xml embeds wake script and config paths'
# --- behavior: green RESUME + CAS + unblock (single wait env).
$e = New-GHWEnv -Tag 'green'
[void](New-GHWGoal -Env $e -GoalId 'ghw-goal-1' -Tasks @('ghw-task-b'))
Set-GHWBlocked -Env $e -TaskId 'ghw-task-b' -Sha $script:SHA_A
New-GHWWait -Env $e -TaskId 'ghw-task-b' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e -GoalId 'ghw-goal-1')
$fxGreen = Write-GHWFixture -Env $e -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$revBefore = [long](Get-OrchestrationTask -TaskId 'ghw-task-b' -TasksDir $e.tasksDir -RepoRoot $e.root).revision
$r = Invoke-GHWCase -Env $e -Fixture $fxGreen -Auth $true -Exec $true
Assert-That ([int]$r.code -eq 0) 'green wake => exit 0'
Assert-That (($null -ne $r.env) -and ([string](Get-GHWField $r.env 'verdict' '') -ceq 'WAKE_PASS')) 'green wake => WAKE_PASS'
Assert-That ([bool](Get-GHWField $r.env 'kernel_mutated' $false)) 'green wake => kernel mutated'
$items = @(Get-GHWField $r.env 'items' @())
Assert-That ((@($items).Count -eq 1) -and ([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'RESUME')) 'green wake => single RESUME item'
Assert-That ([string](Get-GHWField @($items)[0] 'kernel' '') -ceq 'unblocked') 'green wake => kernel unblocked'
Assert-That ([bool](Get-GHWField @($items)[0] 'confirmed' $false)) 'green wake => wait confirmed'
$nx = Get-GHWField $r.env 'next_action' $null
Assert-That (($null -ne $nx) -and ([string](Get-GHWField $nx 'task_id' '') -ceq 'ghw-task-b')) 'green wake => next action announces task'
Assert-That ((-not [bool](Get-GHWField $r.env 'grants_authority' $true)) -and (-not [bool](Get-GHWField $r.env 'merge_authority' $true)) -and (-not [bool](Get-GHWField $r.env 'done_approved' $true))) 'green wake => authority pins stay false'
$tAfter = Get-OrchestrationTask -TaskId 'ghw-task-b' -TasksDir $e.tasksDir -RepoRoot $e.root
Assert-That (([string](Get-GHWField $tAfter 'state' '') -ceq 'IMPLEMENTING') -and ([long](Get-GHWField $tAfter 'revision' 0) -gt $revBefore)) 'green wake => BLOCKED->IMPLEMENTING applied'
# --- duplicate: same event re-invoked => DUPLICATE_NOOP, no further mutation.
$revDup = [long](Get-OrchestrationTask -TaskId 'ghw-task-b' -TasksDir $e.tasksDir -RepoRoot $e.root).revision
$r = Invoke-GHWCase -Env $e -Fixture $fxGreen -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([int]$r.code -eq 0) -and ([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'DUPLICATE_NOOP')) 'repeat event => DUPLICATE_NOOP'
$revDupAfter = [long](Get-OrchestrationTask -TaskId 'ghw-task-b' -TasksDir $e.tasksDir -RepoRoot $e.root).revision
Assert-That ($revDupAfter -eq $revDup) 'duplicate => kernel untouched'
# --- DONE task wait => HOLD already-done (fresh env).
$e2 = New-GHWEnv -Tag 'done'
[void](New-GHWGoal -Env $e2 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-a'))
Set-GHWDone -Env $e2 -TaskId 'ghw-task-a'
New-GHWWait -Env $e2 -TaskId 'ghw-task-a' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e2 -GoalId 'ghw-goal-1')
$fx2 = Write-GHWFixture -Env $e2 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$revA = [long](Get-OrchestrationTask -TaskId 'ghw-task-a' -TasksDir $e2.tasksDir -RepoRoot $e2.root).revision
$r = Invoke-GHWCase -Env $e2 -Fixture $fx2 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'HOLD') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'already-done')) 'DONE task => HOLD already-done'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghw-task-a' -TasksDir $e2.tasksDir -RepoRoot $e2.root).revision -eq $revA) 'DONE task => never reexecuted'
# --- stale SHA => TERMINAL head-superseded, still BLOCKED.
$e3 = New-GHWEnv -Tag 'stale'
[void](New-GHWGoal -Env $e3 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-c'))
Set-GHWBlocked -Env $e3 -TaskId 'ghw-task-c' -Sha $script:SHA_A
New-GHWWait -Env $e3 -TaskId 'ghw-task-c' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e3 -GoalId 'ghw-goal-1')
$fx3 = Write-GHWFixture -Env $e3 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_B) -Head $script:SHA_B -Commit $script:SHA_B) -Name 'stale.graphql.json'
$r = Invoke-GHWCase -Env $e3 -Fixture $fx3 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'head-superseded')) 'stale SHA => TERMINAL head-superseded'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-c' -TasksDir $e3.tasksDir -RepoRoot $e3.root).state -ceq 'BLOCKED') 'stale SHA => still BLOCKED'
# --- closed PR => TERMINAL pr-terminal, still BLOCKED.
$e4 = New-GHWEnv -Tag 'closed'
[void](New-GHWGoal -Env $e4 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-d'))
Set-GHWBlocked -Env $e4 -TaskId 'ghw-task-d' -Sha $script:SHA_A
New-GHWWait -Env $e4 -TaskId 'ghw-task-d' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e4 -GoalId 'ghw-goal-1')
$fx4 = Write-GHWFixture -Env $e4 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A -State 'CLOSED') -Name 'closed.graphql.json'
$r = Invoke-GHWCase -Env $e4 -Fixture $fx4 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'pr-terminal')) 'closed PR => TERMINAL pr-terminal'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-d' -TasksDir $e4.tasksDir -RepoRoot $e4.root).state -ceq 'BLOCKED') 'closed PR => still BLOCKED'
# --- red checks => diagnostic TERMINAL, no unblock, no confirm.
$e5 = New-GHWEnv -Tag 'red'
[void](New-GHWGoal -Env $e5 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-e'))
Set-GHWBlocked -Env $e5 -TaskId 'ghw-task-e' -Sha $script:SHA_A
New-GHWWait -Env $e5 -TaskId 'ghw-task-e' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e5 -GoalId 'ghw-goal-1')
$redNodes = New-GHWGreenNodes $script:SHA_A
$redNodes[0] = New-GHWNode $script:reqChecks[0] 'COMPLETED' 'FAILURE' $script:SHA_A
$fx5 = Write-GHWFixture -Env $e5 -Raw (New-GHWRaw -Nodes $redNodes -Head $script:SHA_A -Commit $script:SHA_A) -Name 'red.graphql.json'
$r = Invoke-GHWCase -Env $e5 -Fixture $fx5 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'diagnostic')) 'red checks => TERMINAL diagnostic'
Assert-That (([string](Get-OrchestrationTask -TaskId 'ghw-task-e' -TasksDir $e5.tasksDir -RepoRoot $e5.root).state -ceq 'BLOCKED') -and (-not [bool](Get-GHWField @($items)[0] 'confirmed' $true))) 'red checks => no unblock, no confirm'
# --- pending checks => KEEP_WAITING, still BLOCKED.
$e6 = New-GHWEnv -Tag 'pending'
[void](New-GHWGoal -Env $e6 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-f'))
Set-GHWBlocked -Env $e6 -TaskId 'ghw-task-f' -Sha $script:SHA_A
New-GHWWait -Env $e6 -TaskId 'ghw-task-f' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e6 -GoalId 'ghw-goal-1')
$pendNodes = New-GHWGreenNodes $script:SHA_A
$pendNodes[0] = New-GHWNode $script:reqChecks[0] 'IN_PROGRESS' $null $script:SHA_A
$fx6 = Write-GHWFixture -Env $e6 -Raw (New-GHWRaw -Nodes $pendNodes -Head $script:SHA_A -Commit $script:SHA_A) -Name 'pending.graphql.json'
$r = Invoke-GHWCase -Env $e6 -Fixture $fx6 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That ([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'KEEP_WAITING') 'pending checks => KEEP_WAITING'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-f' -TasksDir $e6.tasksDir -RepoRoot $e6.root).state -ceq 'BLOCKED') 'pending => still BLOCKED'
# --- revoked authorization => TERMINAL, no unblock.
$r = Invoke-GHWCase -Env $e6 -Fixture $fx6 -Auth $false -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'authorization-revoked')) 'revoked authz => TERMINAL authorization-revoked'
# --- green without executor => READY observable, still BLOCKED.
$e7 = New-GHWEnv -Tag 'ready'
[void](New-GHWGoal -Env $e7 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-g'))
Set-GHWBlocked -Env $e7 -TaskId 'ghw-task-g' -Sha $script:SHA_A
New-GHWWait -Env $e7 -TaskId 'ghw-task-g' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e7 -GoalId 'ghw-goal-1')
$fx7 = Write-GHWFixture -Env $e7 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$r = Invoke-GHWCase -Env $e7 -Fixture $fx7 -Auth $true -Exec $false
$items = @(Get-GHWField $r.env 'items' @())
Assert-That ([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'READY') 'green without executor => READY'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-g' -TasksDir $e7.tasksDir -RepoRoot $e7.root).state -ceq 'BLOCKED') 'READY => still BLOCKED, durable observable'
# --- graphql errors payload => HOLD api-failure.
$e8 = New-GHWEnv -Tag 'apifail'
[void](New-GHWGoal -Env $e8 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-h'))
Set-GHWBlocked -Env $e8 -TaskId 'ghw-task-h' -Sha $script:SHA_A
New-GHWWait -Env $e8 -TaskId 'ghw-task-h' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e8 -GoalId 'ghw-goal-1')
$errRaw = [pscustomobject]@{ errors = @([pscustomobject]@{ type = 'FORBIDDEN'; message = 'x' }) }
$fx8 = Write-GHWFixture -Env $e8 -Raw $errRaw -Name 'errors.graphql.json'
$r = Invoke-GHWCase -Env $e8 -Fixture $fx8 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'HOLD') -and ([string](Get-GHWField @($items)[0] 'reason' '') -ceq 'api-failure')) 'graphql errors => HOLD api-failure'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-h' -TasksDir $e8.tasksDir -RepoRoot $e8.root).state -ceq 'BLOCKED') 'api failure => still BLOCKED'
# --- stale checkpoint (goal revised after checkpoint) => HOLD, no unblock.
$e9 = New-GHWEnv -Tag 'stckpt'
$setup9 = New-GHWGoal -Env $e9 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-i')
Set-GHWBlocked -Env $e9 -TaskId 'ghw-task-i' -Sha $script:SHA_A
New-GHWWait -Env $e9 -TaskId 'ghw-task-i' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e9 -GoalId 'ghw-goal-1')
$liveG = (Get-OrchestrationGoal -GoalId 'ghw-goal-1' -StoreDir $e9.goalDir).goal
$genNow = [long]$setup9.generation
$upd = Update-OrchestrationGoal -GoalId 'ghw-goal-1' -ExpectedRevision ([long]$liveG['revision']) -Fields @{ progress = @{ satisfied = 1; total = 1 } } -StoreDir $e9.goalDir -OwnerId 'planner-1' -OwnershipGeneration $genNow
Assert-That ([bool](Get-GHWField $upd 'ok' $false)) 'setup: goal revision bumped past checkpoint'
$fx9 = Write-GHWFixture -Env $e9 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$r = Invoke-GHWCase -Env $e9 -Fixture $fx9 -Auth $true -Exec $true
$items = @(Get-GHWField $r.env 'items' @())
Assert-That (([string](Get-GHWField @($items)[0] 'decision' '') -ceq 'HOLD') -and ([string](Get-GHWField @($items)[0] 'reason' '') -cmatch 'checkpoint-not-resumable')) 'stale checkpoint => HOLD checkpoint-not-resumable'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-i' -TasksDir $e9.tasksDir -RepoRoot $e9.root).state -ceq 'BLOCKED') 'stale checkpoint => still BLOCKED'
# --- config fail-closed: persisted true must NOT authorize a config-file run.
$efc = New-GHWEnv -Tag 'cfgclosed'
[void](New-GHWGoal -Env $efc -GoalId 'ghw-goal-1' -Tasks @('ghw-task-j'))
Set-GHWBlocked -Env $efc -TaskId 'ghw-task-j' -Sha $script:SHA_A
New-GHWWait -Env $efc -TaskId 'ghw-task-j' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $efc -GoalId 'ghw-goal-1')
$fxfc = Write-GHWFixture -Env $efc -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$cfgFcPath = Join-Path $efc.root 'wake.json'
$cfgFc = New-GitHubWakeConfig -Path $cfgFcPath -WaitsDir $efc.waitsDir -TasksDir $efc.tasksDir -GoalStoreDir $efc.goalDir -CheckpointDir $efc.ckptDir -FlagsPath $efc.flagsPath -GraphQLSnapshotFile $fxfc -AuthorizationAlive $true -ExecutorPresent $true
Assert-That ([bool](Get-GHWField $cfgFc 'ok' $false)) 'fail-closed setup: config written'
$rfc = Invoke-GHWChild -CliArgs @('-ConfigFile', $cfgFcPath, '-NowUtc', $script:NOW)
$itemsFc = @(Get-GHWField $rfc.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsFc)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsFc)[0] 'reason' '') -ceq 'authorization-revoked')) 'config persisted true => still TERMINAL authorization-revoked (fail-closed)'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-j' -TasksDir $efc.tasksDir -RepoRoot $efc.root).state -ceq 'BLOCKED') 'fail-closed => still BLOCKED, no unblock from config'
# --- legacy reconcile: IMPLEMENTING task with unconfirmed wait => Confirm only, no re-transition.
$er = New-GHWEnv -Tag 'recon'
[void](New-GHWGoal -Env $er -GoalId 'ghw-goal-1' -Tasks @('ghw-task-k'))
Set-GHWBlocked -Env $er -TaskId 'ghw-task-k' -Sha $script:SHA_A
New-GHWWait -Env $er -TaskId 'ghw-task-k' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $er -GoalId 'ghw-goal-1')
$fxr = Write-GHWFixture -Env $er -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$rr1 = Invoke-GHWCase -Env $er -Fixture $fxr -Auth $true -Exec $true
$itemsR1 = @(Get-GHWField $rr1.env 'items' @())
Assert-That ([string](Get-GHWField @($itemsR1)[0] 'decision' '') -ceq 'RESUME') 'reconcile setup: first wake RESUMEs'
$revRecon = [long](Get-OrchestrationTask -TaskId 'ghw-task-k' -TasksDir $er.tasksDir -RepoRoot $er.root).revision
$waitFiles = @(Get-ChildItem -LiteralPath $er.waitsDir -File -Filter 'ghwait-*.json')
Assert-That (@($waitFiles).Count -ge 1) 'reconcile setup: wait file present'
$wfDoc = ConvertFrom-Json ([IO.File]::ReadAllText($waitFiles[0].FullName, [Text.Encoding]::UTF8))
$wfDoc.applied_events = @()
[IO.File]::WriteAllText($waitFiles[0].FullName, (ConvertTo-Json -InputObject $wfDoc -Depth 20), (New-Object Text.UTF8Encoding $false))
$rr2 = Invoke-GHWCase -Env $er -Fixture $fxr -Auth $true -Exec $true
$itemsR2 = @(Get-GHWField $rr2.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsR2)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-GHWField @($itemsR2)[0] 'reason' '') -ceq 'reconciled-pending-confirm')) 'legacy IMPLEMENTING+unconfirmed => RESUME reconciled-pending-confirm'
Assert-That ([string](Get-GHWField @($itemsR2)[0] 'kernel' '') -ceq 'reconciled') 'reconcile => kernel=reconciled, never re-transitions'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghw-task-k' -TasksDir $er.tasksDir -RepoRoot $er.root).revision -eq $revRecon) 'reconcile => kernel revision untouched (no duplicate unblock)'
Assert-That ([bool](Get-GHWField @($itemsR2)[0] 'confirmed' $false)) 'reconcile => wait confirmed'
# --- Confirm failure is fail-closed: event-log-full => HOLD, kernel not attempted.
$ec = New-GHWEnv -Tag 'conffail'
[void](New-GHWGoal -Env $ec -GoalId 'ghw-goal-1' -Tasks @('ghw-task-m'))
Set-GHWBlocked -Env $ec -TaskId 'ghw-task-m' -Sha $script:SHA_A
New-GHWWait -Env $ec -TaskId 'ghw-task-m' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $ec -GoalId 'ghw-goal-1')
$fxc = Write-GHWFixture -Env $ec -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$waitFilesC = @(Get-ChildItem -LiteralPath $ec.waitsDir -File -Filter 'ghwait-*.json')
$wfC = ConvertFrom-Json ([IO.File]::ReadAllText($waitFilesC[0].FullName, [Text.Encoding]::UTF8))
$fillC = @()
for ($i = 0; $i -lt 128; $i++) { $fillC += @('evt-fill-' + [string]$i) }
$wfC.applied_events = $fillC
[IO.File]::WriteAllText($waitFilesC[0].FullName, (ConvertTo-Json -InputObject $wfC -Depth 20), (New-Object Text.UTF8Encoding $false))
$revCBefore = [long](Get-OrchestrationTask -TaskId 'ghw-task-m' -TasksDir $ec.tasksDir -RepoRoot $ec.root).revision
$rc = Invoke-GHWCase -Env $ec -Fixture $fxc -Auth $true -Exec $true
$itemsC = @(Get-GHWField $rc.env 'items' @())
Assert-That (([int]$rc.code -eq 0) -and ([string](Get-GHWField @($itemsC)[0] 'decision' '') -ceq 'HOLD')) 'confirm-full => exit 0 HOLD'
Assert-That ([string](Get-GHWField @($itemsC)[0] 'reason' '') -ceq 'confirm-failed:event-log-full') 'confirm-full => HOLD confirm-failed:event-log-full'
Assert-That ([string](Get-GHWField @($itemsC)[0] 'kernel' '') -ceq 'not-attempted') 'confirm failure => kernel not-attempted (unblock never tried)'
Assert-That (-not [bool](Get-GHWField @($itemsC)[0] 'confirmed' $true)) 'confirm failure => confirmed false'
Assert-That (-not [bool](Get-GHWField $rc.env 'kernel_mutated' $true)) 'confirm failure => envelope kernel_mutated false'
Assert-That (([string](Get-OrchestrationTask -TaskId 'ghw-task-m' -TasksDir $ec.tasksDir -RepoRoot $ec.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'ghw-task-m' -TasksDir $ec.tasksDir -RepoRoot $ec.root).revision -eq $revCBefore)) 'confirm failure => task still BLOCKED, revision untouched'
# --- Unblock failure after Confirm: kernel disabled => HOLD unblock-refused, no mutation.
$eu = New-GHWEnv -Tag 'unblockfail'
[void](New-GHWGoal -Env $eu -GoalId 'ghw-goal-1' -Tasks @('ghw-task-n'))
Set-GHWBlocked -Env $eu -TaskId 'ghw-task-n' -Sha $script:SHA_A
New-GHWWait -Env $eu -TaskId 'ghw-task-n' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $eu -GoalId 'ghw-goal-1')
$fxu = Write-GHWFixture -Env $eu -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$revUBefore = [long](Get-OrchestrationTask -TaskId 'ghw-task-n' -TasksDir $eu.tasksDir -RepoRoot $eu.root).revision
[IO.File]::WriteAllText($eu.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$ru = Invoke-GHWCase -Env $eu -Fixture $fxu -Auth $true -Exec $true
$itemsU = @(Get-GHWField $ru.env 'items' @())
Assert-That (([int]$ru.code -eq 0) -and ([string](Get-GHWField @($itemsU)[0] 'decision' '') -ceq 'HOLD')) 'unblock-fail => exit 0 HOLD'
Assert-That ([string](Get-GHWField @($itemsU)[0] 'reason' '') -ceq 'unblock-refused:KERNEL_DISABLED') 'unblock failure => HOLD unblock-refused:KERNEL_DISABLED'
Assert-That ([string](Get-GHWField @($itemsU)[0] 'kernel' '') -ceq 'unblock-failed') 'unblock failure => kernel=unblock-failed'
Assert-That ([bool](Get-GHWField @($itemsU)[0] 'confirmed' $false)) 'unblock failure => Confirm ran first (confirmed true)'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-n' -TasksDir $eu.tasksDir -RepoRoot $eu.root).state -ceq 'BLOCKED') 'unblock failure => task still BLOCKED'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghw-task-n' -TasksDir $eu.tasksDir -RepoRoot $eu.root).revision -eq $revUBefore) 'unblock failure => revision untouched'
# --- Liveness recovery: Confirm ok + unblock fail, then retry same event => RESUME reconciled-pending-unblock.
$e2 = New-GHWEnv -Tag 'unblockrec'
[void](New-GHWGoal -Env $e2 -GoalId 'ghw-goal-1' -Tasks @('ghw-task-p'))
Set-GHWBlocked -Env $e2 -TaskId 'ghw-task-p' -Sha $script:SHA_A
New-GHWWait -Env $e2 -TaskId 'ghw-task-p' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $e2 -GoalId 'ghw-goal-1')
$fx2 = Write-GHWFixture -Env $e2 -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$revPBefore = [long](Get-OrchestrationTask -TaskId 'ghw-task-p' -TasksDir $e2.tasksDir -RepoRoot $e2.root).revision
[IO.File]::WriteAllText($e2.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$rp1 = Invoke-GHWCase -Env $e2 -Fixture $fx2 -Auth $true -Exec $true
$itemsP1 = @(Get-GHWField $rp1.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsP1)[0] 'reason' '') -ceq 'unblock-refused:KERNEL_DISABLED') -and [bool](Get-GHWField @($itemsP1)[0] 'confirmed' $false)) 'recovery setup: Confirm applied, unblock refused, event recorded'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-p' -TasksDir $e2.tasksDir -RepoRoot $e2.root).state -ceq 'BLOCKED') 'recovery setup: task still BLOCKED after failed unblock'
[IO.File]::WriteAllText($e2.flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$rp2 = Invoke-GHWCase -Env $e2 -Fixture $fx2 -Auth $true -Exec $true
$itemsP2 = @(Get-GHWField $rp2.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsP2)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-GHWField @($itemsP2)[0] 'reason' '') -ceq 'reconciled-pending-unblock')) 'liveness: retry after failed unblock => RESUME reconciled-pending-unblock (no eternal DUPLICATE_NOOP)'
Assert-That ([string](Get-GHWField @($itemsP2)[0] 'kernel' '') -ceq 'unblocked') 'liveness: recovery unblocks the kernel exactly once'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-p' -TasksDir $e2.tasksDir -RepoRoot $e2.root).state -ceq 'IMPLEMENTING') 'liveness: task leaves BLOCKED after recovery'
Assert-That ([long](Get-OrchestrationTask -TaskId 'ghw-task-p' -TasksDir $e2.tasksDir -RepoRoot $e2.root).revision -eq ($revPBefore + 1)) 'liveness: exactly one unblock transition across both ticks'
Assert-That ([bool](Get-GHWField $rp2.env 'kernel_mutated' $false)) 'liveness: recovery envelope reports kernel_mutated'
# --- Unregister is fail-closed: existing task without -Force => confirmation-required, never deletes.
$unAbs = Unregister-GitHubWakeSchedule -TaskName 'ghw-wake-absent-9f3a2b1c' 
Assert-That (([bool](Get-GHWField $unAbs 'ok' $false)) -and ([string](Get-GHWField $unAbs 'reason' '') -ceq 'not-found')) 'unregister absent task => not-found (idempotent, no Force needed)'
Assert-That ($null -ne (Get-Command Unregister-GitHubWakeSchedule -ErrorAction SilentlyContinue)) 'unregister command still exposed'
$unSrc = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
Assert-That ($unSrc -cmatch 'confirmation-required') 'unregister fail-closed reason pinned'
Assert-That ($unSrc -cmatch 'param\(\[string\]\$TaskName[^)]*\[switch\]\$Force') 'unregister requires explicit -Force for deletion'
# --- resolver helpers (offline, fixtures only).
function Write-GHWProof {
    param([string]$Path = '', [string]$Json = '{}')
    [IO.File]::WriteAllText($Path, $Json, (New-Object Text.UTF8Encoding $false))
}
function Get-GHWWaitFile {
    param($Env)
    $found = @(Get-ChildItem -LiteralPath $Env.waitsDir -File -Filter 'ghwait-*.json')
    if (@($found).Count -eq 0) { throw 'wait-missing' }
    return @($found)[0].FullName
}
function Set-GHWWaitField {
    param($Env, [string]$Name = '', $Value = $null)
    $wf = Get-GHWWaitFile -Env $Env
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($wf, [Text.Encoding]::UTF8))
    $doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    [IO.File]::WriteAllText($wf, (ConvertTo-Json -InputObject $doc -Depth 20), (New-Object Text.UTF8Encoding $false))
}
function Invoke-GHWDirect {
    param($Env, [string]$Fixture = '', [hashtable]$Extra = @{})
    $base = @{
        WaitsDir = $Env.waitsDir; TasksDir = $Env.tasksDir; GoalStoreDir = $Env.goalDir
        CheckpointDir = $Env.ckptDir; FlagsPath = $Env.flagsPath; Policy = $script:policy
        GraphQLSnapshotFile = $Fixture; MaxAgeSeconds = 300; NowUtc = $script:NOW
        ActorIdentitySource = 'explicit-cli'; AuthorizationAlive = $false; ExecutorPresent = $false
        CancelRequested = $false; MaxApiAttempts = 3; TimeoutMs = 10000
    }
    foreach ($k in @($Extra.Keys)) { $base[$k] = $Extra[$k] }
    return (Invoke-GitHubWake @base)
}
Assert-That ($null -ne (Get-Command Resolve-GHWLeaseAlive -ErrorAction SilentlyContinue)) 'resolver Resolve-GHWLeaseAlive exposed'
Assert-That ($null -ne (Get-Command Resolve-GHWOwnerAlive -ErrorAction SilentlyContinue)) 'resolver Resolve-GHWOwnerAlive exposed'
Assert-That ($null -ne (Get-Command Resolve-GHWAuthorizationAlive -ErrorAction SilentlyContinue)) 'resolver Resolve-GHWAuthorizationAlive exposed'
Assert-That ($null -ne (Get-Command Resolve-GHWExecutorAlive -ErrorAction SilentlyContinue)) 'resolver Resolve-GHWExecutorAlive exposed'
# --- unit: lease resolver (wait-document facts only).
$ghwNowObj = Convert-GHWUtc -Value $script:NOW
$wOkDoc = @{ lease_expires_utc = $script:FUTURE; deadline_utc = $script:FUTURE }
$rOkDoc = Resolve-GHWLeaseAlive -Wait $wOkDoc -NowObj $ghwNowObj
Assert-That ([bool](Get-GHWField $rOkDoc 'alive' $false)) 'lease resolver: valid lease+deadline => alive'
$wExpDoc = @{ lease_expires_utc = '2020-01-01T00:00:00Z'; deadline_utc = $script:FUTURE }
$rExpDoc = Resolve-GHWLeaseAlive -Wait $wExpDoc -NowObj $ghwNowObj
Assert-That ((-not [bool](Get-GHWField $rExpDoc 'alive' $true)) -and ([string](Get-GHWField $rExpDoc 'reason' '') -ceq 'lease-expired')) 'lease resolver: past lease => lease-expired'
$wDlDoc = @{ lease_expires_utc = $script:FUTURE; deadline_utc = '2020-01-01T00:00:00Z' }
$rDlDoc = Resolve-GHWLeaseAlive -Wait $wDlDoc -NowObj $ghwNowObj
Assert-That ((-not [bool](Get-GHWField $rDlDoc 'alive' $true)) -and ([string](Get-GHWField $rDlDoc 'reason' '') -ceq 'wait-expired')) 'lease resolver: past deadline => wait-expired'
# --- unit: authorization resolver (trusted source + live proof/flags).
$ezu = New-GHWEnv -Tag 'rsun'
$authProofOk = Join-Path $ezu.root 'auth.ok.json'
Write-GHWProof -Path $authProofOk -Json '{"authorization_alive":true,"actor_identity_source":"explicit-cli"}'
$raOk = Resolve-GHWAuthorizationAlive -ActorIdentitySource 'explicit-cli' -FlagsPath $ezu.flagsPath -AuthorizationProofPath $authProofOk
Assert-That ([bool](Get-GHWField $raOk 'alive' $false)) 'auth resolver: matching proof file => alive'
$authProofBad = Join-Path $ezu.root 'auth.bad.json'
Write-GHWProof -Path $authProofBad -Json '{"authorization_alive":true,"actor_identity_source":"foreign-actor"}'
$raBad = Resolve-GHWAuthorizationAlive -ActorIdentitySource 'explicit-cli' -FlagsPath $ezu.flagsPath -AuthorizationProofPath $authProofBad
Assert-That ((-not [bool](Get-GHWField $raBad 'alive' $true)) -and ([string](Get-GHWField $raBad 'reason' '') -ceq 'authorization-revoked')) 'auth resolver: divergent proof identity => authorization-revoked'
$raFlags = Resolve-GHWAuthorizationAlive -ActorIdentitySource 'explicit-cli' -FlagsPath $ezu.flagsPath -AuthorizationProofPath ''
Assert-That ([bool](Get-GHWField $raFlags 'alive' $false)) 'auth resolver: enabled kernel flags => alive (no proof file)'
[IO.File]::WriteAllText($ezu.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$raOff = Resolve-GHWAuthorizationAlive -ActorIdentitySource 'explicit-cli' -FlagsPath $ezu.flagsPath -AuthorizationProofPath ''
Assert-That ((-not [bool](Get-GHWField $raOff 'alive' $true)) -and ([string](Get-GHWField $raOff 'reason' '') -ceq 'authorization-revoked')) 'auth resolver: disabled kernel flags => authorization-revoked'
$raSrc = Resolve-GHWAuthorizationAlive -ActorIdentitySource 'untrusted-src' -FlagsPath $ezu.flagsPath -AuthorizationProofPath $authProofOk
Assert-That (-not [bool](Get-GHWField $raSrc 'alive' $true)) 'auth resolver: untrusted identity source => not alive'
# --- unit: executor resolver (explicit proof only, never scheduler-implied).
$execProofOk = Join-Path $ezu.root 'exec.ok.json'
Write-GHWProof -Path $execProofOk -Json ('{"executor_present":true,"observed_at":"' + $script:NOW + '"}')
$reOk = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofOk -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That (([bool](Get-GHWField $reOk 'alive' $false)) -and ([string](Get-GHWField $reOk 'reason' 'X') -ceq '')) 'executor resolver: fresh proof true+observed_at NOW => alive'
$execProofStale = Join-Path $ezu.root 'exec.stale.json'
Write-GHWProof -Path $execProofStale -Json '{"executor_present":true,"observed_at":"2020-01-01T00:00:00Z"}'
$reStale = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofStale -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That ((-not [bool](Get-GHWField $reStale 'alive' $true)) -and ([string](Get-GHWField $reStale 'reason' '') -ceq 'no-executor')) 'executor resolver: stale proof => no-executor'
$execProofFuture = Join-Path $ezu.root 'exec.future.json'
Write-GHWProof -Path $execProofFuture -Json '{"executor_present":true,"observed_at":"2026-10-10T13:02:00Z"}'
$reFuture = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofFuture -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That ((-not [bool](Get-GHWField $reFuture 'alive' $true)) -and ([string](Get-GHWField $reFuture 'reason' '') -ceq 'executor-proof-future')) 'executor resolver: future proof => executor-proof-future'
$reAbsent = Resolve-GHWExecutorAlive -ExecutorProofPath '' -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That ((-not [bool](Get-GHWField $reAbsent 'alive' $true)) -and ([string](Get-GHWField $reAbsent 'reason' '') -ceq 'no-executor')) 'executor resolver: absent proof => no-executor (never scheduler-implied)'
$execProofFalse = Join-Path $ezu.root 'exec.false.json'
Write-GHWProof -Path $execProofFalse -Json '{"executor_present":false}'
$reFalse = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofFalse -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That (-not [bool](Get-GHWField $reFalse 'alive' $true)) 'executor resolver: proof false => not alive'
$execProofNoObs = Join-Path $ezu.root 'exec.noobs.json'
Write-GHWProof -Path $execProofNoObs -Json '{"executor_present":true}'
$reNoObs = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofNoObs -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That ((-not [bool](Get-GHWField $reNoObs 'alive' $true)) -and ([string](Get-GHWField $reNoObs 'reason' '') -ceq 'no-executor')) 'executor resolver: present true without observed_at => no-executor'
$execProofBadDate = Join-Path $ezu.root 'exec.baddate.json'
Write-GHWProof -Path $execProofBadDate -Json '{"executor_present":true,"observed_at":"not-a-date"}'
$reBadDate = Resolve-GHWExecutorAlive -ExecutorProofPath $execProofBadDate -NowUtc $script:NOW -MaxAgeSeconds 300
Assert-That ((-not [bool](Get-GHWField $reBadDate 'alive' $true)) -and ([string](Get-GHWField $reBadDate 'reason' '') -ceq 'no-executor')) 'executor resolver: invalid observed_at => no-executor'
# --- e2e: RESUME via resolvers, no live booleans (flags + executor proof).
$ez = New-GHWEnv -Tag 'rsolve'
[void](New-GHWGoal -Env $ez -GoalId 'ghw-goal-1' -Tasks @('ghw-task-r'))
Set-GHWBlocked -Env $ez -TaskId 'ghw-task-r' -Sha $script:SHA_A
New-GHWWait -Env $ez -TaskId 'ghw-task-r' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $ez -GoalId 'ghw-goal-1')
$fxz = Write-GHWFixture -Env $ez -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$execProofZ = Join-Path $ez.root 'exec.proof.json'
Write-GHWProof -Path $execProofZ -Json ('{"executor_present":true,"observed_at":"' + $script:NOW + '"}')
$rz = Invoke-GHWChild -CliArgs @('-WaitsDir', $ez.waitsDir, '-TasksDir', $ez.tasksDir, '-GoalStoreDir', $ez.goalDir, '-CheckpointDir', $ez.ckptDir, '-FlagsPath', $ez.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fxz, '-ResolveAuthorization', '-ResolveExecutor', '-ExecutorProofPath', $execProofZ, '-ResolveOwner', '-LeaseFromWait')
$itemsZ = @(Get-GHWField $rz.env 'items' @())
Assert-That (([int]$rz.code -eq 0) -and ([string](Get-GHWField @($itemsZ)[0] 'decision' '') -ceq 'RESUME')) 'resolver opt-in => RESUME without live booleans'
Assert-That ([string](Get-GHWField @($itemsZ)[0] 'kernel' '') -ceq 'unblocked') 'resolver RESUME => kernel unblocked'
Assert-That ([bool](Get-GHWField $rz.env 'resume_authorized' $false)) 'resolver RESUME => envelope resume_authorized'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-r' -TasksDir $ez.tasksDir -RepoRoot $ez.root).state -ceq 'IMPLEMENTING') 'resolver RESUME => BLOCKED->IMPLEMENTING'
# --- e2e: resolver auth fail-closed (disabled flags => authorization-revoked).
$eaz = New-GHWEnv -Tag 'rsauth'
[void](New-GHWGoal -Env $eaz -GoalId 'ghw-goal-1' -Tasks @('ghw-task-s'))
Set-GHWBlocked -Env $eaz -TaskId 'ghw-task-s' -Sha $script:SHA_A
New-GHWWait -Env $eaz -TaskId 'ghw-task-s' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $eaz -GoalId 'ghw-goal-1')
$fxaz = Write-GHWFixture -Env $eaz -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
[IO.File]::WriteAllText($eaz.flagsPath, '{"task_kernel":{"enabled":false,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
$raz = Invoke-GHWChild -CliArgs @('-WaitsDir', $eaz.waitsDir, '-TasksDir', $eaz.tasksDir, '-GoalStoreDir', $eaz.goalDir, '-CheckpointDir', $eaz.ckptDir, '-FlagsPath', $eaz.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fxaz, '-ResolveAuthorization')
$itemsAz = @(Get-GHWField $raz.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsAz)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsAz)[0] 'reason' '') -ceq 'authorization-revoked')) 'resolver with disabled flags => TERMINAL authorization-revoked'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-s' -TasksDir $eaz.tasksDir -RepoRoot $eaz.root).state -ceq 'BLOCKED') 'authz-revoked via resolver => still BLOCKED'
# --- e2e: partial resolvers (auth resolved, no executor proof => READY).
$erd = New-GHWEnv -Tag 'rsready'
[void](New-GHWGoal -Env $erd -GoalId 'ghw-goal-1' -Tasks @('ghw-task-t'))
Set-GHWBlocked -Env $erd -TaskId 'ghw-task-t' -Sha $script:SHA_A
New-GHWWait -Env $erd -TaskId 'ghw-task-t' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $erd -GoalId 'ghw-goal-1')
$fxrd = Write-GHWFixture -Env $erd -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$rrd = Invoke-GHWChild -CliArgs @('-WaitsDir', $erd.waitsDir, '-TasksDir', $erd.tasksDir, '-GoalStoreDir', $erd.goalDir, '-CheckpointDir', $erd.ckptDir, '-FlagsPath', $erd.flagsPath, '-NowUtc', $script:NOW, '-GraphQLSnapshotFile', $fxrd, '-ResolveAuthorization')
$itemsRd = @(Get-GHWField $rrd.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsRd)[0] 'decision' '') -ceq 'READY') -and ([string](Get-GHWField @($itemsRd)[0] 'reason' '') -ceq 'ready-no-executor')) 'auth resolved without executor proof => READY ready-no-executor'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-t' -TasksDir $erd.tasksDir -RepoRoot $erd.root).state -ceq 'BLOCKED') 'READY via resolvers => still BLOCKED'
# --- direct: lease-expired blocks RESUME.
$elx = New-GHWEnv -Tag 'rslease'
[void](New-GHWGoal -Env $elx -GoalId 'ghw-goal-1' -Tasks @('ghw-task-u'))
Set-GHWBlocked -Env $elx -TaskId 'ghw-task-u' -Sha $script:SHA_A
New-GHWWait -Env $elx -TaskId 'ghw-task-u' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $elx -GoalId 'ghw-goal-1')
$fxlx = Write-GHWFixture -Env $elx -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
Set-GHWWaitField -Env $elx -Name 'lease_expires_utc' -Value '2020-01-01T00:00:00Z'
$rlx = Invoke-GHWDirect -Env $elx -Fixture $fxlx -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true }
$itemsLx = @(Get-GHWField $rlx 'items' @())
Assert-That (([string](Get-GHWField @($itemsLx)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsLx)[0] 'reason' '') -ceq 'lease-expired')) 'past lease => TERMINAL lease-expired'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-u' -TasksDir $elx.tasksDir -RepoRoot $elx.root).state -ceq 'BLOCKED') 'lease-expired => still BLOCKED'
# --- direct: owner-mismatch blocks RESUME (lease_owner diverged, binding intact).
$eow = New-GHWEnv -Tag 'rsowner'
[void](New-GHWGoal -Env $eow -GoalId 'ghw-goal-1' -Tasks @('ghw-task-v'))
Set-GHWBlocked -Env $eow -TaskId 'ghw-task-v' -Sha $script:SHA_A
New-GHWWait -Env $eow -TaskId 'ghw-task-v' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $eow -GoalId 'ghw-goal-1')
$fxow = Write-GHWFixture -Env $eow -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
Set-GHWWaitField -Env $eow -Name 'lease_owner' -Value 'intruder-9'
$row = Invoke-GHWDirect -Env $eow -Fixture $fxow -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true }
$itemsOw = @(Get-GHWField $row 'items' @())
Assert-That (([string](Get-GHWField @($itemsOw)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsOw)[0] 'reason' '') -ceq 'owner-mismatch')) 'diverged lease_owner => TERMINAL owner-mismatch'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-v' -TasksDir $eow.tasksDir -RepoRoot $eow.root).state -ceq 'BLOCKED') 'owner-mismatch => still BLOCKED'
# --- direct: cancelled blocks RESUME.
$ecx = New-GHWEnv -Tag 'rscancel'
[void](New-GHWGoal -Env $ecx -GoalId 'ghw-goal-1' -Tasks @('ghw-task-w'))
Set-GHWBlocked -Env $ecx -TaskId 'ghw-task-w' -Sha $script:SHA_A
New-GHWWait -Env $ecx -TaskId 'ghw-task-w' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $ecx -GoalId 'ghw-goal-1')
$fxcx = Write-GHWFixture -Env $ecx -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$rcx = Invoke-GHWDirect -Env $ecx -Fixture $fxcx -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true; CancelRequested = $true }
$itemsCx = @(Get-GHWField $rcx 'items' @())
Assert-That (([string](Get-GHWField @($itemsCx)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsCx)[0] 'reason' '') -ceq 'cancelled')) 'cancel requested => TERMINAL cancelled'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-w' -TasksDir $ecx.tasksDir -RepoRoot $ecx.root).state -ceq 'BLOCKED') 'cancelled => still BLOCKED'
# --- direct: wait-expired blocks RESUME.
$ewe = New-GHWEnv -Tag 'rswait'
[void](New-GHWGoal -Env $ewe -GoalId 'ghw-goal-1' -Tasks @('ghw-task-x'))
Set-GHWBlocked -Env $ewe -TaskId 'ghw-task-x' -Sha $script:SHA_A
New-GHWWait -Env $ewe -TaskId 'ghw-task-x' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $ewe -GoalId 'ghw-goal-1')
$fxwe = Write-GHWFixture -Env $ewe -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
Set-GHWWaitField -Env $ewe -Name 'deadline_utc' -Value '2020-01-01T00:00:00Z'
$rwe = Invoke-GHWDirect -Env $ewe -Fixture $fxwe -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true }
$itemsWe = @(Get-GHWField $rwe 'items' @())
Assert-That (([string](Get-GHWField @($itemsWe)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsWe)[0] 'reason' '') -ceq 'wait-expired')) 'past deadline => TERMINAL wait-expired'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-x' -TasksDir $ewe.tasksDir -RepoRoot $ewe.root).state -ceq 'BLOCKED') 'wait-expired => still BLOCKED'
# --- direct: retry-budget-exhausted blocks RESUME on pending checks.
$erb = New-GHWEnv -Tag 'rsbudget'
[void](New-GHWGoal -Env $erb -GoalId 'ghw-goal-1' -Tasks @('ghw-task-y'))
Set-GHWBlocked -Env $erb -TaskId 'ghw-task-y' -Sha $script:SHA_A
New-GHWWait -Env $erb -TaskId 'ghw-task-y' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $erb -GoalId 'ghw-goal-1')
$pendRb = New-GHWGreenNodes $script:SHA_A
$pendRb[0] = New-GHWNode $script:reqChecks[0] 'IN_PROGRESS' $null $script:SHA_A
$fxrb = Write-GHWFixture -Env $erb -Raw (New-GHWRaw -Nodes $pendRb -Head $script:SHA_A -Commit $script:SHA_A) -Name 'pending.graphql.json'
Set-GHWWaitField -Env $erb -Name 'retry_used' -Value 5
$rrb = Invoke-GHWDirect -Env $erb -Fixture $fxrb -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true }
$itemsRb = @(Get-GHWField $rrb 'items' @())
Assert-That (([string](Get-GHWField @($itemsRb)[0] 'decision' '') -ceq 'TERMINAL') -and ([string](Get-GHWField @($itemsRb)[0] 'reason' '') -ceq 'retry-budget-exhausted')) 'exhausted retry budget on pending => TERMINAL retry-budget-exhausted'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-y' -TasksDir $erb.tasksDir -RepoRoot $erb.root).state -ceq 'BLOCKED') 'budget-exhausted => still BLOCKED'
# --- direct: policy-diverged blocks RESUME (INVALID, never unblocks).
$epd = New-GHWEnv -Tag 'rspolicy'
[void](New-GHWGoal -Env $epd -GoalId 'ghw-goal-1' -Tasks @('ghw-task-z'))
Set-GHWBlocked -Env $epd -TaskId 'ghw-task-z' -Sha $script:SHA_A
New-GHWWait -Env $epd -TaskId 'ghw-task-z' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $epd -GoalId 'ghw-goal-1')
$fxpd = Write-GHWFixture -Env $epd -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$polDiv = ConvertFrom-Json (ConvertTo-Json $script:policy -Depth 20)
$polDiv.required_checks = @(@($polDiv.required_checks) + 'extra-divergent-check')
$rpd = Invoke-GHWDirect -Env $epd -Fixture $fxpd -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $true; Policy = $polDiv }
$itemsPd = @(Get-GHWField $rpd 'items' @())
Assert-That (([string](Get-GHWField @($itemsPd)[0] 'decision' '') -ceq 'INVALID') -and ([string](Get-GHWField @($itemsPd)[0] 'reason' '') -ceq 'policy-diverged')) 'divergent policy => INVALID policy-diverged'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-z' -TasksDir $epd.tasksDir -RepoRoot $epd.root).state -ceq 'BLOCKED') 'policy-diverged => still BLOCKED'
Assert-That (-not [bool](Get-GHWField $rpd 'kernel_mutated' $true)) 'policy-diverged => kernel untouched'
# --- config scheduled path with resolver opt-ins + proofs => RESUME.
$ecfg = New-GHWEnv -Tag 'rscfg'
[void](New-GHWGoal -Env $ecfg -GoalId 'ghw-goal-1' -Tasks @('ghw-task-q'))
Set-GHWBlocked -Env $ecfg -TaskId 'ghw-task-q' -Sha $script:SHA_A
New-GHWWait -Env $ecfg -TaskId 'ghw-task-q' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $ecfg -GoalId 'ghw-goal-1')
$fxcfg = Write-GHWFixture -Env $ecfg -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$execProofCfg = Join-Path $ecfg.root 'exec.proof.json'
Write-GHWProof -Path $execProofCfg -Json ('{"executor_present":true,"observed_at":"' + $script:NOW + '"}')
$cfgResPath = Join-Path $ecfg.root 'wake-resolve.json'
$cfgRes = New-GitHubWakeConfig -Path $cfgResPath -WaitsDir $ecfg.waitsDir -TasksDir $ecfg.tasksDir -GoalStoreDir $ecfg.goalDir -CheckpointDir $ecfg.ckptDir -FlagsPath $ecfg.flagsPath -GraphQLSnapshotFile $fxcfg -ResolveAuthorization $true -ResolveExecutor $true -ExecutorProofPath $execProofCfg -AuthorizationAlive $true -ExecutorPresent $true
Assert-That ([bool](Get-GHWField $cfgRes 'ok' $false)) 'resolver config: written'
$cfgResDoc = $null
try { $cfgResDoc = ConvertFrom-Json ([IO.File]::ReadAllText($cfgResPath, [Text.Encoding]::UTF8)) } catch { $cfgResDoc = $null }
Assert-That (($null -ne $cfgResDoc) -and (-not [bool](Get-GHWField $cfgResDoc 'authorization_alive' $true)) -and (-not [bool](Get-GHWField $cfgResDoc 'executor_present' $true))) 'resolver config: still never persists authz/executor as true'
Assert-That (([bool](Get-GHWField $cfgResDoc 'resolve_authorization' $false)) -and ([bool](Get-GHWField $cfgResDoc 'resolve_executor' $false)) -and ([string](Get-GHWField $cfgResDoc 'executor_proof_path' '') -ceq $execProofCfg)) 'resolver config: opt-ins and proof path persisted (not authority)'
$rcfg = Invoke-GHWChild -CliArgs @('-ConfigFile', $cfgResPath, '-NowUtc', $script:NOW)
$itemsCfg = @(Get-GHWField $rcfg.env 'items' @())
Assert-That (([string](Get-GHWField @($itemsCfg)[0] 'decision' '') -ceq 'RESUME') -and ([string](Get-GHWField @($itemsCfg)[0] 'kernel' '') -ceq 'unblocked')) 'scheduled ConfigFile with resolver opt-ins => RESUME (no live switches)'
Assert-That ([string](Get-OrchestrationTask -TaskId 'ghw-task-q' -TasksDir $ecfg.tasksDir -RepoRoot $ecfg.root).state -ceq 'IMPLEMENTING') 'scheduled resolver RESUME => BLOCKED->IMPLEMENTING'
# --- objetivo 4 lacunas (a)(b)(c): recuperacao e limites, offline, sem schtasks real nem rede.
# Ja cobertos, nao duplicados (referencia por linha existente deste arquivo):
# (d) cancelamento => TERMINAL cancelled (linha 659); (e) duplicacao => DUPLICATE_NOOP
# sem mutacao kernel (linhas 299-301); (f) SHA divergente => TERMINAL head-superseded
# (linhas 323-324); (g) lease expirado => TERMINAL lease-expired (linha 636);
# (h) falha da API => HOLD api-failure (linha 387). Handoff: duplicate-noop (linhas
# 231-234), lease-expired (linhas 283-284) em github-wake-controller.tests.ps1.
# (a) principal sem usuario interativo: XML fixa InteractiveToken/LeastPrivilege,
# sem segredo S4S simulado. HOLD honesto: sem sessao interativa no host, o registro
# real exige logon interativo; DryRun nunca alega prova viva.
Assert-That ($dryXml -cmatch '<LogonType>InteractiveToken</LogonType>') 'sched principal: InteractiveToken pinned in XML'
Assert-That ($dryXml -cmatch '<RunLevel>LeastPrivilege</RunLevel>') 'sched principal: LeastPrivilege pinned in XML'
Assert-That ($dryXml -cnotmatch 'Password|S4U|ServiceAccount|<UserId>') 'sched principal: no S4S/service secret simulated'
Assert-That (($dryXml -cmatch '<Principal id="Author">') -and ($dryXml -cmatch '<Actions Context="Author">')) 'sched principal: single Author principal bound to action context'
$xmlForeignCmd = (([string]$xmlOwned).Replace('powershell.exe', 'cmd.exe'))
Assert-That (-not [bool](Test-GHWScheduleOwner -ExistingXml $xmlForeignCmd -WakeScript $script:cli -ConfigFile $script:cli)) 'sched principal: foreign Command refused by owner check (offline, sem schtasks)'
# (b) duracao e renovacao: limites exatos no XML + renovacao idempotente sem duplicar.
Assert-That ($dryXml -cmatch '<Interval>PT5M</Interval>') 'sched bounds: Interval 5min pinned'
Assert-That ($dryXml -cmatch '<Duration>PT12H</Duration>') 'sched bounds: Duration 12h pinned'
Assert-That ($dryXml -cmatch '<ExecutionTimeLimit>PT5M</ExecutionTimeLimit>') 'sched bounds: ExecutionTimeLimit 5min pinned'
Assert-That ($dryXml -cmatch '<StopAtDurationEnd>true</StopAtDurationEnd>') 'sched bounds: StopAtDurationEnd pinned (no runaway)'
Assert-That ($dryXml -cmatch '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>') 'sched bounds: IgnoreNew pinned (sem estados paralelos)'
Assert-That ($cliText -cmatch 'replaced-owned') 'renewal path pinned: replaced-owned (re-registro idempotente)'
Assert-That ($cliText -cmatch 'already-registered') 'renewal path pinned: already-registered (sem duplicar)'
$dryRe = Register-GitHubWakeSchedule -TaskName 'ghw-wake-test' -WakeScript $script:cli -ConfigFile $script:cli -IntervalMinutes 5 -DurationHours 12 -ExecutionTimeLimitMinutes 5 -DryRun
$dryReXml = [string](Get-GHWField $dryRe 'xml' '')
Assert-That (([bool](Get-GHWField $dryRe 'ok' $false)) -and ($dryReXml -cmatch '<Interval>PT5M</Interval>') -and ($dryReXml -cmatch '<Duration>PT12H</Duration>') -and ($dryReXml -cmatch '<ExecutionTimeLimit>PT5M</ExecutionTimeLimit>')) 'renewal dry-run: re-registro gera os mesmos limites (idempotente; DryRun nao e prova viva)'
# (c) falha do executor nunca vira TERMINAL indevido: stale/future/ausente/invalida => READY.
$exf = New-GHWEnv -Tag 'exfail'
[void](New-GHWGoal -Env $exf -GoalId 'ghw-goal-1' -Tasks @('ghw-task-xf'))
Set-GHWBlocked -Env $exf -TaskId 'ghw-task-xf' -Sha $script:SHA_A
New-GHWWait -Env $exf -TaskId 'ghw-task-xf' -Sha $script:SHA_A
[void](New-GHWCkpt -Env $exf -GoalId 'ghw-goal-1')
$fxex = Write-GHWFixture -Env $exf -Raw (New-GHWRaw -Nodes (New-GHWGreenNodes $script:SHA_A) -Head $script:SHA_A -Commit $script:SHA_A) -Name 'green.graphql.json'
$revXfBefore = [long](Get-OrchestrationTask -TaskId 'ghw-task-xf' -TasksDir $exf.tasksDir -RepoRoot $exf.root).revision
$proofXStale = Join-Path $exf.root 'exec.stale.json'
Write-GHWProof -Path $proofXStale -Json '{"executor_present":true,"observed_at":"2020-01-01T00:00:00Z"}'
$proofXFuture = Join-Path $exf.root 'exec.future.json'
Write-GHWProof -Path $proofXFuture -Json '{"executor_present":true,"observed_at":"2026-10-10T13:02:00Z"}'
$proofXBad = Join-Path $exf.root 'exec.bad.json'
Write-GHWProof -Path $proofXBad -Json '{{not-json'
foreach ($px in @($proofXStale, $proofXFuture, $proofXBad)) {
    $rxf = Invoke-GHWDirect -Env $exf -Fixture $fxex -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $false; ResolveExecutor = $true; ExecutorProofPath = $px }
    $itemsXf = @(Get-GHWField $rxf 'items' @())
    Assert-That (([string](Get-GHWField @($itemsXf)[0] 'decision' '') -ceq 'READY') -and ([string](Get-GHWField @($itemsXf)[0] 'reason' '') -ceq 'ready-no-executor')) ('executor proof failure => READY ready-no-executor (never TERMINAL): ' + $px)
    Assert-That ([string](Get-GHWField @($itemsXf)[0] 'decision' '') -cne 'TERMINAL') ('executor proof failure => never TERMINAL: ' + $px)
    Assert-That (-not [bool](Get-GHWField $rxf 'resume_authorized' $true)) ('executor proof failure => resume_authorized false: ' + $px)
}
$rxf0 = Invoke-GHWDirect -Env $exf -Fixture $fxex -Extra @{ AuthorizationAlive = $true; ExecutorPresent = $false; ResolveExecutor = $true }
$itemsXf0 = @(Get-GHWField $rxf0 'items' @())
Assert-That (([string](Get-GHWField @($itemsXf0)[0] 'decision' '') -ceq 'READY') -and ([string](Get-GHWField @($itemsXf0)[0] 'decision' '') -cne 'TERMINAL')) 'executor proof absent with ResolveExecutor => READY (never TERMINAL, never RESUME)'
Assert-That (([string](Get-OrchestrationTask -TaskId 'ghw-task-xf' -TasksDir $exf.tasksDir -RepoRoot $exf.root).state -ceq 'BLOCKED') -and ([long](Get-OrchestrationTask -TaskId 'ghw-task-xf' -TasksDir $exf.tasksDir -RepoRoot $exf.root).revision -eq $revXfBefore)) 'executor failures => still BLOCKED, revision untouched'
Write-Output ('github-wake tests PASS: ' + [string]$script:passed)
