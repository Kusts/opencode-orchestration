# objective-step.tests.ps1 -- CLI fina cooperativa de UM passo do caminho produtivo.
# Custom PS 5.1 / PS7 suite, no Pester. Fixtures in owned TEMP. No network,
# no spawn of workers, no model. Bracketed output the runner parses.
# Exit 0 all pass, 1 any fail. ASCII only.
#
# Covers:
#   * dot-source safety (no params => defines helpers, runs nothing, silent)
#   * strict arg validation (exit 2 + JSON error envelope)
#   * static boundary: no subagent/task-tool spawn, no Executor, no legacy
#     Invoke, no Claim/Settle calls, no verifier/reviewer/DONE/grants,
#     authority flags literal false, kernel_mutated computed (never literal)
#   * next: reconcile -> next-move -> PREPARE on ACTIVE goal (receipt written
#     ONLY under explicit ReceiptDir, repo tree untouched, dispatch_intent
#     emitted for the Planner native tool, executor never runs)
#   * next: COMPLETE move => reported, no dispatch; non-dispatchable move
#     (e.g. REPLAN on DRAFT) => reported, no dispatch;
#     unknown goal => goal-reread-failed (exit 0, honest refusal)
#   * settle: candidate envelope + worker-result validated, settlement NOT
#     promoted (kernel_mutated false, task revision unchanged, receipt kept)
#   * settle: verified_pass rejected (status-not-allowed-from-worker)
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')

$ErrorActionPreference = 'Stop'

$v3 = $PSScriptRoot
$cli = Join-Path $v3 'objective-step.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $v3)

$script:childExe = ''
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
    try { $found = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $found = $null }
    if ($null -ne $found) { $script:childExe = 'pwsh' }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) { $script:childExe = 'powershell' }

$script:total = 0
$script:passed = 0

function Assert-That($Condition, $Name, $Detail = '') {
    $script:total++
    if ($Condition) { $script:passed++; Write-Host ("[PASS] {0}" -f $Name) }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
    }
}

function Invoke-StepCli {
    param([string[]]$Argv)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = & $script:childExe -NoProfile -File $cli @Argv
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = ((@($text) | ForEach-Object { "$_" }) -join "`n") }
}

function Read-JsonDoc {
    param([string]$Text)
    try { return (ConvertFrom-Json $Text) } catch { return $null }
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = (($Text -replace "`r`n", "`n") -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Get-StoreFootprint {
    param([string[]]$Dirs)
    $map = @{}
    foreach ($dd in @($Dirs)) {
        if ([string]::IsNullOrWhiteSpace($dd)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $dd -PathType Container)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dd -File -Recurse -ErrorAction SilentlyContinue)) {
                try { $map[[string]$f.FullName] = [long]$f.Length } catch { }
            }
        }
        catch { }
    }
    return $map
}

function Test-FootprintEqual {
    param($Before, $After)
    try {
        if (@($Before.Keys).Count -ne @($After.Keys).Count) { return $false }
        foreach ($k in @($Before.Keys)) {
            if (-not $After.ContainsKey($k)) { return $false }
            if ([long]$After[$k] -ne [long]$Before[$k]) { return $false }
        }
        return $true
    }
    catch { return $false }
}

try {
    Assert-That (-not [string]::IsNullOrWhiteSpace($script:childExe)) 'child engine resolved' "Engine=$Engine"
    Assert-That (Test-Path -LiteralPath $cli -PathType Leaf) 'CLI file exists' "Missing $cli"
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        throw 'CLI missing, remaining assertions cannot run'
    }

    # ---------- static boundary (text-level guarantees) ----------
    $cliText = [IO.File]::ReadAllText($cli, [Text.Encoding]::UTF8)
    foreach ($bad in @('subagent', 'Start-Process', 'Start-Job', 'Start-Service', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Remove-Item', 'Complete-OrchestrationTask', 'Set-OrchestrationTaskWorkerResult', 'Set-OrchestrationGoalState', 'New-OrchestrationDispatchIntent ', 'Test-OrchestrationGoalTransition', 'Add-OrchestrationGoalTask', 'Acquire-OrchestrationGoalOwnership', 'Invoke-OrchestrationNativeDispatchClaim', 'Invoke-OrchestrationNativeDispatchSettle', 'Test-OrchestrationTaskCompletion', 'execution-grants', 'Get-ExecutionGrant', 'Set-ExecutionGrant', 'Invoke-OrchestrationAutonomousObjective', 'Invoke-OrchestrationObjectiveStep', 'Test-TaskKernelTerminalState')) {
        Assert-That ($cliText -cnotmatch $bad) ("CLI has no authority/effect pattern: " + $bad) 'found in CLI text'
    }
    Assert-That ($cliText -cnotmatch 'Invoke-OrchestrationNativeDispatch(\s|"|$)') 'CLI never calls legacy dispatch path' 'legacy invoke present'
    Assert-That ($cliText -cnotmatch 'Executor') 'CLI never mentions an executor seam' 'executor token present'
    Assert-That ($cliText -cnotmatch 'grants_authority = \$true') 'CLI never grants authority (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch 'done_approved = \$true') 'CLI never approves done (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch 'verified_pass = \$true') 'CLI never emits verified_pass (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch 'kernel_mutated = \$true') 'CLI never hardcodes kernel_mutated true' 'literal true present'
    Assert-That ($cliText -cmatch 'grants_authority\s+=\s+\$false') 'CLI pins grants_authority false' 'missing'
    Assert-That ($cliText -cmatch 'done_approved\s+=\s+\$false') 'CLI pins done_approved false' 'missing'
    Assert-That ($cliText -cmatch 'verified_pass\s+=\s+\$false') 'CLI pins verified_pass false' 'missing'
    Assert-That ($cliText -cnotmatch 'C:\\Users') 'CLI has no machine-specific path' 'found'
    # Non-ASCII guard: file must be pure ASCII.
    $rawBytes = [IO.File]::ReadAllBytes($cli)
    $nonAscii = 0
    foreach ($b in $rawBytes) { if ([int]$b -gt 127) { $nonAscii++ } }
    Assert-That ($nonAscii -eq 0) 'CLI is ASCII-only' ("non-ascii bytes: " + $nonAscii)

    # ---------- dot-source safety: defines helpers, runs nothing ----------
    . $cli
    Assert-That ($null -ne (Get-Command Read-OSJsonFile -ErrorAction SilentlyContinue)) 'dot-source exposes json reader' 'missing'
    Assert-That ($null -ne (Get-Command Write-OSEnvelope -ErrorAction SilentlyContinue)) 'dot-source exposes envelope writer' 'missing'
    Assert-That (Test-OSTaskIdShape -Value 'os-task-abc') 'pure: kernel task shape accepted' 'rejected'
    Assert-That (-not (Test-OSTaskIdShape -Value 'sk-SYNTHETICSECRET-01')) 'pure: canary task shape rejected' 'accepted'
    Assert-That (-not (Test-OSTaskIdShape -Value 'https://example.invalid/t')) 'pure: URL task shape rejected' 'accepted'
    Assert-That (Test-OSReferenceShape -Value 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'pure: opaque 32hex reference accepted' 'rejected'
    Assert-That (-not (Test-OSReferenceShape -Value 'https://example.invalid/r')) 'pure: URL reference rejected' 'accepted'
    Assert-That (-not (Test-OSCanonicalToken -Value ("a`nbc") -MaxLength 128)) 'pure: control char rejected' 'accepted'
    Assert-That (-not (Test-OSTaskIdShape -Value ("os-task-abc`n"))) 'pure: terminal LF in task id rejected' 'accepted'
    Assert-That (-not (Test-OSReferenceShape -Value ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n"))) 'pure: terminal LF in reference rejected' 'accepted'
    Assert-That (-not (Test-OSCanonicalToken -Value ("abc`n") -MaxLength 128)) 'pure: terminal LF in token rejected' 'accepted'

    # ---------- fresh process, no args => silent exit 0 ----------
    $rNone = Invoke-StepCli -Argv @()
    Assert-That (($rNone.Code -eq 0) -and ([string]::IsNullOrWhiteSpace($rNone.Text))) 'no args => silent exit 0 (dot-source safe)' ("Exit $($rNone.Code) :: $($rNone.Text)")

    # ---------- invalid action => exit 2 + JSON error ----------
    $rBad = Invoke-StepCli -Argv @('-Action', 'launch')
    $dBad = Read-JsonDoc -Text $rBad.Text
    Assert-That (($rBad.Code -eq 2) -and ($null -ne $dBad) -and (-not [bool]$dBad.ok)) 'invalid action => exit 2 with ok:false' ("Exit $($rBad.Code) :: $($rBad.Text)")
    if ($null -ne $dBad) {
        Assert-That (([bool]$dBad.grants_authority -eq $false) -and ([bool]$dBad.done_approved -eq $false) -and ([bool]$dBad.verified_pass -eq $false) -and ([bool]$dBad.kernel_mutated -eq $false)) 'error envelope carries zero authority' $rBad.Text
    }

    # ---------- invalid action value is fixed, never reflected ----------
    $rCanAct = Invoke-StepCli -Argv @('-Action', 'sk-SYNTHETICSECRET-03')
    $dCanAct = Read-JsonDoc -Text $rCanAct.Text
    Assert-That (($rCanAct.Code -eq 2) -and ($null -ne $dCanAct) -and (-not [bool]$dCanAct.ok) -and ([string]$dCanAct.action -ceq 'unknown')) 'canary action => exit 2 with fixed action' ("Exit $($rCanAct.Code) :: $($rCanAct.Text)")
    Assert-That ($rCanAct.Text -cnotmatch 'SYNTHETICSECRET') 'canary action never echoed to stdout' 'canary leaked'

    # ---------- next with missing params => exit 2 ----------
    $rMiss = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', 'nope')
    $dMiss = Read-JsonDoc -Text $rMiss.Text
    Assert-That (($rMiss.Code -eq 2) -and ($null -ne $dMiss) -and (-not [bool]$dMiss.ok)) 'next missing stores => exit 2' ("Exit $($rMiss.Code) :: $($rMiss.Text)")

    # ---------- settle with missing file => exit 2 ----------
    $rSMiss = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', 'Z:\nope\env.json', '-ResultFile', 'Z:\nope\res.json')
    $dSMiss = Read-JsonDoc -Text $rSMiss.Text
    Assert-That (($rSMiss.Code -eq 2) -and ($null -ne $dSMiss) -and (-not [bool]$dSMiss.ok)) 'settle missing files => exit 2' ("Exit $($rSMiss.Code) :: $($rSMiss.Text)")

    # ---------- next with malformed goal id => exit 2, no echo ----------
    $rCanGoal = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', 'https://example.invalid/g', '-GoalStoreDir', ([IO.Path]::GetTempPath()))
    $dCanGoal = Read-JsonDoc -Text $rCanGoal.Text
    Assert-That (($rCanGoal.Code -eq 2) -and ($null -ne $dCanGoal) -and (-not [bool]$dCanGoal.ok)) 'URL goal id => exit 2' ("Exit $($rCanGoal.Code) :: $($rCanGoal.Text)")
    Assert-That ($rCanGoal.Text -cnotmatch 'example\.invalid') 'URL goal id never echoed to stdout' 'url leaked'

    # ---------- fixtures in owned TEMP ----------
    . (Join-Path $v3 'lib\OrchestrationNativeDispatch.ps1')

    # ---------- MEDIUM residue: listing failure must refuse measurement ----------
    # A cmdlet-faithful mock: $PSCmdlet.WriteError honors the caller's
    # -ErrorAction, so it discriminates swallowed (SilentlyContinue => bug:
    # ok=true on a blind map) from fail-closed (Stop => ok=false).
    $mockHash = Get-NativeDispatchHash32 'os-goal-mock-1'
    Assert-That (-not [string]::IsNullOrWhiteSpace($mockHash)) '[F] mock namespace hash' 'empty'
    $mockRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-objstep-mockroot-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $mockRoot $mockHash) -Force | Out-Null
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath = '', [switch]$File, [string]$Filter = '')
        $er = New-Object System.Management.Automation.ErrorRecord(
            (New-Object System.Exception('simulated-listing-denied')),
            'SimulatedListingDenied',
            [System.Management.Automation.ErrorCategory]::ReadError,
            $null)
        $PSCmdlet.WriteError($er)
    }
    $fpMock = $null
    try { $fpMock = Get-OSOperationFootprint -ReceiptDir $mockRoot -GoalId 'os-goal-mock-1' } catch { $fpMock = $null }
    try { Remove-Item function:Get-ChildItem -ErrorAction SilentlyContinue } catch { }
    Assert-That (($null -ne $fpMock) -and ([bool]$fpMock.ok -eq $false)) 'listing failure => measurement refused (ok=false)' 'false-negative risk'
    try { Remove-Item -LiteralPath $mockRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-objstep-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $tempRoot 'goals'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    Write-Fixture -Path $flagsPath -Text '{"task_kernel":{"enabled":true,"shadow":false}}'

    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8).ToLowerInvariant()
    $goalId = ('os-goal-' + $suffix)
    $taskId = ('os-task-' + $suffix)
    $owner = 'planner-1'

    $g = New-OrchestrationGoal -GoalId $goalId -Objective ('passo cooperativo ' + $suffix) -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-That ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
    $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
    Assert-That ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
    $own = Acquire-OrchestrationGoalOwnership -GoalId $goalId -OwnerId $owner -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
    Assert-That ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
    $gen = [long]$own.ownership['generation']

    $t = New-OrchestrationTask -TaskId $taskId -Objective ('obj ' + $taskId) -TaskType 'implementation' `
        -Risk 'low' -Actor $owner -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
    Assert-That ([bool]$t.ok) '[F] kernel task created' ([string]$t.error)
    $slot = Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $goalId -TaskId $taskId -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    Assert-That ([bool]$add.ok) '[F] task attached to goal' ([string]$add.reason)

    $ph = Get-NativeDispatchHash32 ('objstep-prompt-' + $suffix)
    $authDoc = [ordered]@{ explicit_allow = $true; goal_id = $goalId; owner = $owner; generation = $gen; source = 'planner' }
    $authFile = Join-Path $tempRoot 'auth.json'
    Write-Fixture -Path $authFile -Text (($authDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $intentDoc = [ordered]@{
        task_id = $taskId; task_expected_revision = [long]1; agent = 'coder'; prompt_hash = $ph
        scope = @('src/a.ps1'); acceptance_criteria = @('criterion:0')
        owner = $owner; ownership_generation = $gen; base_revision = 'rev-a'
    }
    $intentFile = Join-Path $tempRoot 'intent.json'
    Write-Fixture -Path $intentFile -Text (($intentDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")

    # ---------- next happy path: reconcile -> next-move -> PREPARE ----------
    $rNext = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $goalId, '-GoalStoreDir', $goalDir, '-TasksDir', $tasksDir, '-ReceiptDir', $receiptDir, '-FlagsPath', $flagsPath, '-AuthorizationFile', $authFile, '-IntentFile', $intentFile, '-SessionId', 'ses-test-01')
    $dNext = Read-JsonDoc -Text $rNext.Text
    Assert-That (($rNext.Code -eq 0) -and ($null -ne $dNext) -and ([bool]$dNext.ok) -and ($dNext.action -ceq 'next')) 'next happy => exit 0 ok:true action:next' ("Exit $($rNext.Code) :: $($rNext.Text)")
    if ($null -ne $dNext) {
        Assert-That (([string]$dNext.next_move.move -ceq 'CONTINUE') -or ([string]$dNext.next_move.move -ceq 'RETRY')) 'next_move is dispatchable (CONTINUE/RETRY)' $rNext.Text
        Assert-That ([string]$dNext.dispatch_intent.task_id -ceq $taskId) 'dispatch_intent binds the task' $rNext.Text
        Assert-That (-not [string]::IsNullOrWhiteSpace([string]$dNext.prepare.reference)) 'prepare reference emitted (opaque, planner-owned)' $rNext.Text
        Assert-That ([int]$dNext.prepare.executor_calls -eq 0) 'no worker executed (executor_calls 0)' $rNext.Text
        Assert-That (([bool]$dNext.grants_authority -eq $false) -and ([bool]$dNext.done_approved -eq $false) -and ([bool]$dNext.verified_pass -eq $false)) 'next envelope carries zero authority' $rNext.Text
        Assert-That ([bool]$dNext.kernel_mutated -eq $true) 'prepared receipt counts as reservation (kernel_mutated true)' $rNext.Text
        Assert-That ([string]$dNext.mutation_note -ceq 'receipt-reservation-not-settlement') 'mutation documented as reservation, not settlement' $rNext.Text
        Assert-That ([bool]$dNext.receipt_written -eq $true) 'effective receipt persistence reported' $rNext.Text
        Assert-That ([bool]$dNext.activation_log_written -eq $true) 'gate activation log write reported' $rNext.Text
    }
    # Receipt persisted ONLY under the explicit dir: exactly one receipt file.
    $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $goalId
    $gotFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($sub)) { $gotFiles = @(Get-ChildItem -File (Join-Path $sub '*.json') -ErrorAction SilentlyContinue) }
    Assert-That (@($gotFiles).Count -eq 1) 'exactly one prepared receipt under explicit ReceiptDir' ("count=" + @($gotFiles).Count)
    # Repo tree untouched: default receipt root must not hold this goal.
    $defaultRoot = Join-Path (Join-Path $repo 'cache') 'native-dispatch-receipts'
    $defaultSub = ''
    try { $hh = Get-NativeDispatchHash32 $goalId; if (-not [string]::IsNullOrWhiteSpace($hh)) { $defaultSub = Join-Path $defaultRoot $hh } } catch { $defaultSub = '' }
    $defaultHit = $false
    if ((-not [string]::IsNullOrWhiteSpace($defaultSub)) -and (Test-Path -LiteralPath $defaultSub -PathType Container)) {
        $hits = @(Get-ChildItem -File (Join-Path $defaultSub '*.json') -ErrorAction SilentlyContinue)
        if (@($hits).Count -gt 0) { $defaultHit = $true }
    }
    Assert-That (-not $defaultHit) 'repo default receipt root untouched' $defaultSub
    # Save the next envelope for the settle candidate below.
    $nextEnvFile = Join-Path $tempRoot 'next-envelope.json'
    Write-Fixture -Path $nextEnvFile -Text ($rNext.Text + "`n")

    # ---------- HIGH: consult A with B's authorization => refuse, zero writes ----------
    $bSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8).ToLowerInvariant()
    $goalB = ('os-goal-b-' + $bSuffix)
    $gb = New-OrchestrationGoal -GoalId $goalB -Objective ('objetivo B ' + $bSuffix) -Criteria @('criterio-b') -StoreDir $goalDir
    Assert-That ([bool]$gb.ok) '[F] goal B created' ([string]$gb.reason)
    $bAct = Set-OrchestrationGoalState -Goal $gb.goal -ToState 'ACTIVE'
    $bSv = Save-OrchestrationGoal -Goal $bAct.goal -StoreDir $goalDir
    $bOwn = Acquire-OrchestrationGoalOwnership -GoalId $goalB -OwnerId $owner -ExpectedRevision ([long]$bSv.revision) -StoreDir $goalDir
    Assert-That (([bool]$bSv.ok) -and ([bool]$bOwn.ok)) '[F] goal B active+owned' ([string]$bOwn.reason)
    $bGen = [long]$bOwn.ownership['generation']
    $authBDoc = [ordered]@{ explicit_allow = $true; goal_id = $goalB; owner = $owner; generation = $bGen; source = 'planner' }
    $authBFile = Join-Path $tempRoot 'auth-b.json'
    Write-Fixture -Path $authBFile -Text (($authBDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $fpBefore = Get-StoreFootprint -Dirs @($goalDir, $tasksDir, $receiptDir)
    $rMismatch = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $goalId, '-GoalStoreDir', $goalDir, '-TasksDir', $tasksDir, '-ReceiptDir', $receiptDir, '-FlagsPath', $flagsPath, '-AuthorizationFile', $authBFile, '-IntentFile', $intentFile, '-SessionId', 'ses-test-01')
    $dMismatch = Read-JsonDoc -Text $rMismatch.Text
    Assert-That (($rMismatch.Code -eq 0) -and ($null -ne $dMismatch) -and (-not [bool]$dMismatch.ok) -and ([string]$dMismatch.reason -ceq 'authorization-goal-mismatch')) 'auth of B for goal A => refused before prepare' ("Exit $($rMismatch.Code) :: $($rMismatch.Text)")
    if ($null -ne $dMismatch) {
        Assert-That (([bool]$dMismatch.kernel_mutated -eq $false) -and ([bool]$dMismatch.activation_log_written -eq $false) -and ([bool]$dMismatch.receipt_written -eq $false)) 'mismatch refusal wrote nothing' $rMismatch.Text
        Assert-That ($rMismatch.Text -cnotmatch [regex]::Escape($goalB)) 'foreign goal id never echoed' 'foreign id leaked'
    }
    $fpAfter = Get-StoreFootprint -Dirs @($goalDir, $tasksDir, $receiptDir)
    Assert-That (Test-FootprintEqual -Before $fpBefore -After $fpAfter) 'mismatch refusal left all stores byte-identical' 'store changed'

    # ---------- MEDIUM: rival owner reaches the gate => refused WITH log, no receipt ----------
    $authRivalDoc = [ordered]@{ explicit_allow = $true; goal_id = $goalId; owner = 'planner-2'; generation = $gen; source = 'planner' }
    $authRivalFile = Join-Path $tempRoot 'auth-rival.json'
    Write-Fixture -Path $authRivalFile -Text (($authRivalDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rRival = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $goalId, '-GoalStoreDir', $goalDir, '-TasksDir', $tasksDir, '-ReceiptDir', $receiptDir, '-FlagsPath', $flagsPath, '-AuthorizationFile', $authRivalFile, '-IntentFile', $intentFile, '-SessionId', 'ses-test-01')
    $dRival = Read-JsonDoc -Text $rRival.Text
    Assert-That (($rRival.Code -eq 0) -and ($null -ne $dRival) -and (-not [bool]$dRival.ok)) 'rival owner => prepare refused' ("Exit $($rRival.Code) :: $($rRival.Text)")
    if ($null -ne $dRival) {
        Assert-That (([bool]$dRival.kernel_mutated -eq $false) -and ([bool]$dRival.receipt_written -eq $false)) 'gate refusal persists no receipt' $rRival.Text
        Assert-That ([bool]$dRival.activation_log_written -eq $true) 'gate refusal reports the activation log write' $rRival.Text
    }
    $gotFilesRival = @(Get-ChildItem -File (Join-Path $sub '*.json') -ErrorAction SilentlyContinue)
    Assert-That (@($gotFilesRival).Count -eq 1) 'gate refusal added no receipt' ("count=" + @($gotFilesRival).Count)

    # ---------- MEDIUM: identical reentry reuses without rewriting ----------
    $rReentry = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $goalId, '-GoalStoreDir', $goalDir, '-TasksDir', $tasksDir, '-ReceiptDir', $receiptDir, '-FlagsPath', $flagsPath, '-AuthorizationFile', $authFile, '-IntentFile', $intentFile, '-SessionId', 'ses-test-01')
    $dReentry = Read-JsonDoc -Text $rReentry.Text
    Assert-That (($rReentry.Code -eq 0) -and ($null -ne $dReentry) -and ([bool]$dReentry.ok) -and ([bool]$dReentry.prepare.reused -eq $true)) 'identical reentry => reused reservation' ("Exit $($rReentry.Code) :: $($rReentry.Text)")
    if ($null -ne $dReentry) {
        Assert-That (([bool]$dReentry.kernel_mutated -eq $false) -and ([bool]$dReentry.receipt_written -eq $false)) 'reused reservation reports no effective receipt write' $rReentry.Text
        Assert-That ([string]$dReentry.prepare.reference -ceq [string]$dNext.prepare.reference) 'reentry returns the same reference' $rReentry.Text
    }
    $gotFilesReentry = @(Get-ChildItem -File (Join-Path $sub '*.json') -ErrorAction SilentlyContinue)
    Assert-That (@($gotFilesReentry).Count -eq 1) 'reentry wrote no second receipt' ("count=" + @($gotFilesReentry).Count)

    # ---------- MEDIUM: flooded namespace => measurement refused, never false-negative ----------
    $fSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8).ToLowerInvariant()
    $goalF = ('os-goal-flood-' + $fSuffix)
    $taskF = ('os-task-flood-' + $fSuffix)
    $gf = New-OrchestrationGoal -GoalId $goalF -Objective ('inundado ' + $fSuffix) -Criteria @('criterio-f') -StoreDir $goalDir
    Assert-That ([bool]$gf.ok) '[F] flood goal created' ([string]$gf.reason)
    $fAct = Set-OrchestrationGoalState -Goal $gf.goal -ToState 'ACTIVE'
    $fSv = Save-OrchestrationGoal -Goal $fAct.goal -StoreDir $goalDir
    $fOwn = Acquire-OrchestrationGoalOwnership -GoalId $goalF -OwnerId $owner -ExpectedRevision ([long]$fSv.revision) -StoreDir $goalDir
    Assert-That (([bool]$fSv.ok) -and ([bool]$fOwn.ok)) '[F] flood goal active+owned' ([string]$fOwn.reason)
    $fGen = [long]$fOwn.ownership['generation']
    $tf = New-OrchestrationTask -TaskId $taskF -Objective ('obj ' + $taskF) -TaskType 'implementation' `
        -Risk 'low' -Actor $owner -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
    Assert-That ([bool]$tf.ok) '[F] flood task created' ([string]$tf.error)
    $fSlot = Get-OrchestrationGoal -GoalId $goalF -StoreDir $goalDir
    $fAdd = Add-OrchestrationGoalTaskPersisted -GoalId $goalF -TaskId $taskF -ExpectedRevision ([long]$fSlot.goal['revision']) -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $fGen
    Assert-That ([bool]$fAdd.ok) '[F] flood task attached' ([string]$fAdd.reason)
    $authFDoc = [ordered]@{ explicit_allow = $true; goal_id = $goalF; owner = $owner; generation = $fGen; source = 'planner' }
    $authFFile = Join-Path $tempRoot 'auth-flood.json'
    Write-Fixture -Path $authFFile -Text (($authFDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $intentFDoc = [ordered]@{
        task_id = $taskF; task_expected_revision = [long]1; agent = 'coder'; prompt_hash = $ph
        scope = @('src/a.ps1'); acceptance_criteria = @('criterion:0')
        owner = $owner; ownership_generation = $fGen; base_revision = 'rev-a'
    }
    $intentFFile = Join-Path $tempRoot 'intent-flood.json'
    Write-Fixture -Path $intentFFile -Text (($intentFDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $fHash = Get-NativeDispatchHash32 $goalF
    Assert-That (-not [string]::IsNullOrWhiteSpace($fHash)) '[F] flood namespace hash' 'empty'
    $fNsDir = Join-Path $receiptDir $fHash
    New-Item -ItemType Directory -Path $fNsDir -Force | Out-Null
    for ($fi = 1; $fi -le 150; $fi++) {
        Write-Fixture -Path (Join-Path $fNsDir ('flood-' + ([string]$fi).PadLeft(4, '0') + '.json')) -Text '{"flood":true}'
    }
    $rFlood = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $goalF, '-GoalStoreDir', $goalDir, '-TasksDir', $tasksDir, '-ReceiptDir', $receiptDir, '-FlagsPath', $flagsPath, '-AuthorizationFile', $authFFile, '-IntentFile', $intentFFile, '-SessionId', 'ses-test-01')
    $dFlood = Read-JsonDoc -Text $rFlood.Text
    Assert-That (($rFlood.Code -eq 0) -and ($null -ne $dFlood) -and ([bool]$dFlood.ok) -and ([string]$dFlood.reason -ceq 'snapshot-incomplete') -and ([bool]$dFlood.kernel_mutated -eq $true)) 'flooded namespace => conservative unknown, never false-negative' ("Exit $($rFlood.Code) :: $($rFlood.Text)")
    if ($null -ne $dFlood) {
        Assert-That (-not [string]::IsNullOrWhiteSpace([string]$dFlood.prepare.reference)) 'flooded prepare still reserved the receipt' $rFlood.Text
    }

    # ---------- next on CANCELLED goal => complete, no dispatch ----------
    $cSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8).ToLowerInvariant()
    $cGoal = ('os-goal-cancel-' + $cSuffix)
    $cg = New-OrchestrationGoal -GoalId $cGoal -Objective ('cancelado ' + $cSuffix) -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-That ([bool]$cg.ok) '[F] cancel goal created' ([string]$cg.reason)
    $cAct = Set-OrchestrationGoalState -Goal $cg.goal -ToState 'ACTIVE'
    $cSv = Save-OrchestrationGoal -Goal $cAct.goal -StoreDir $goalDir
    $cOwn = Acquire-OrchestrationGoalOwnership -GoalId $cGoal -OwnerId $owner -ExpectedRevision ([long]$cSv.revision) -StoreDir $goalDir
    $cSlot = Get-OrchestrationGoal -GoalId $cGoal -StoreDir $goalDir
    $cFin = Set-OrchestrationGoalStatePersisted -GoalId $cGoal -ToState 'CANCELLED' -ExpectedRevision ([long]$cSlot.goal['revision']) -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration ([long]$cOwn.ownership['generation'])
    Assert-That ([bool]$cFin.ok) '[F] goal cancelled' ([string]$cFin.reason)
    $rCancel = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $cGoal, '-GoalStoreDir', $goalDir)
    $dCancel = Read-JsonDoc -Text $rCancel.Text
    Assert-That (($rCancel.Code -eq 0) -and ($null -ne $dCancel) -and ([string]$dCancel.action -ceq 'next') -and ([string]$dCancel.next_move.move -ceq 'COMPLETE')) 'cancelled goal => COMPLETE move, no dispatch' ("Exit $($rCancel.Code) :: $($rCancel.Text)")
    if ($null -ne $dCancel) {
        Assert-That (([bool]$dCancel.kernel_mutated -eq $false) -and ([bool]$dCancel.ok -eq $true)) 'complete path mutates nothing' $rCancel.Text
    }

    # ---------- next on DRAFT goal => no-dispatch (reconcile+next-move only) ----------
    $dSuffix = [guid]::NewGuid().ToString('N').Substring(0, 8).ToLowerInvariant()
    $dGoal = ('os-goal-draft-' + $dSuffix)
    $dg = New-OrchestrationGoal -GoalId $dGoal -Objective ('rascunho ' + $dSuffix) -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-That ([bool]$dg.ok) '[F] draft goal created' ([string]$dg.reason)
    $dSv = Save-OrchestrationGoal -Goal $dg.goal -StoreDir $goalDir
    Assert-That ([bool]$dSv.ok) '[F] draft goal saved' ([string]$dSv.reason)
    $rDraft = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', $dGoal, '-GoalStoreDir', $goalDir)
    $dDraft = Read-JsonDoc -Text $rDraft.Text
    Assert-That (($rDraft.Code -eq 0) -and ($null -ne $dDraft) -and ([string]$dDraft.action -ceq 'next') -and ([string]$dDraft.next_move.move -ceq 'REPLAN') -and ($null -eq $dDraft.prepare)) 'draft goal => REPLAN move, no-dispatch' ("Exit $($rDraft.Code) :: $($rDraft.Text)")
    if ($null -ne $dDraft) {
        Assert-That ([bool]$dDraft.kernel_mutated -eq $false) 'no-dispatch path mutates nothing' $rDraft.Text
    }

    # ---------- next on unknown goal => honest refusal, exit 0 ----------
    $rGhost = Invoke-StepCli -Argv @('-Action', 'next', '-GoalId', ('os-goal-ghost-' + $suffix), '-GoalStoreDir', $goalDir)
    $dGhost = Read-JsonDoc -Text $rGhost.Text
    Assert-That (($rGhost.Code -eq 0) -and ($null -ne $dGhost) -and (-not [bool]$dGhost.ok) -and ([string]$dGhost.reason -ceq 'goal-reread-failed')) 'unknown goal => goal-reread-failed' ("Exit $($rGhost.Code) :: $($rGhost.Text)")

    # ---------- settle candidate: envelope + worker-result, NOT promoted ----------
    $taskBefore = Get-OrchestrationTask -TaskId $taskId -TasksDir $tasksDir
    $revBefore = [long]$taskBefore.revision
    $resDoc = [ordered]@{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
    $resFile = Join-Path $tempRoot 'worker-result.json'
    Write-Fixture -Path $resFile -Text (($resDoc | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rSettle = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $nextEnvFile, '-ResultFile', $resFile)
    $dSettle = Read-JsonDoc -Text $rSettle.Text
    Assert-That (($rSettle.Code -eq 0) -and ($null -ne $dSettle) -and ([bool]$dSettle.ok) -and ([string]$dSettle.action -ceq 'settle')) 'settle candidate => exit 0 ok:true' ("Exit $($rSettle.Code) :: $($rSettle.Text)")
    if ($null -ne $dSettle) {
        Assert-That ([string]$dSettle.settle_candidate.worker_status -ceq 'candidate_pass') 'candidate status echoed' $rSettle.Text
        Assert-That ([string]$dSettle.settle_candidate.task_id -ceq $taskId) 'candidate binds the prepared task' $rSettle.Text
        Assert-That ([bool]$dSettle.settlement_promoted -eq $false) 'settlement NOT promoted to canonical' $rSettle.Text
        Assert-That (([bool]$dSettle.grants_authority -eq $false) -and ([bool]$dSettle.done_approved -eq $false) -and ([bool]$dSettle.verified_pass -eq $false) -and ([bool]$dSettle.kernel_mutated -eq $false)) 'settle envelope carries zero authority' $rSettle.Text
    }
    $taskAfter = Get-OrchestrationTask -TaskId $taskId -TasksDir $tasksDir
    Assert-That ([long]$taskAfter.revision -eq $revBefore) 'settle candidate left the kernel task untouched' ("rev before=$revBefore after=$([long]$taskAfter.revision)")
    $gotFiles2 = @(Get-ChildItem -File (Join-Path $sub '*.json') -ErrorAction SilentlyContinue)
    Assert-That (@($gotFiles2).Count -eq 1) 'settle candidate left the receipt untouched' ("count=" + @($gotFiles2).Count)

    # ---------- settle rejects verified_pass (never from worker) ----------
    $badRes = [ordered]@{ status = 'verified_pass'; claimed_evidence = @('criterion:0') }
    $badResFile = Join-Path $tempRoot 'worker-result-bad.json'
    Write-Fixture -Path $badResFile -Text (($badRes | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rBadSettle = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $nextEnvFile, '-ResultFile', $badResFile)
    $dBadSettle = Read-JsonDoc -Text $rBadSettle.Text
    Assert-That (($rBadSettle.Code -eq 0) -and ($null -ne $dBadSettle) -and (-not [bool]$dBadSettle.ok) -and ([string]$dBadSettle.reason -ceq 'status-not-allowed-from-worker')) 'settle rejects verified_pass' ("Exit $($rBadSettle.Code) :: $($rBadSettle.Text)")
    if ($null -ne $dBadSettle) {
        Assert-That ([bool]$dBadSettle.kernel_mutated -eq $false) 'rejected settle mutates nothing' $rBadSettle.Text
    }

    # ---------- settle with malformed result => exit 2 ----------
    $uglyFile = Join-Path $tempRoot 'worker-result-ugly.json'
    Write-Fixture -Path $uglyFile -Text "{not json"
    $rUgly = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $nextEnvFile, '-ResultFile', $uglyFile)
    $dUgly = Read-JsonDoc -Text $rUgly.Text
    Assert-That (($rUgly.Code -eq 2) -and ($null -ne $dUgly) -and (-not [bool]$dUgly.ok)) 'settle malformed result => exit 2' ("Exit $($rUgly.Code) :: $($rUgly.Text)")

    # ---------- LOW: canary/URL in declared fields => unbound, never echoed ----------
    $goodKey = ([string]$dNext.dispatch_intent.idempotency_key)
    $goodRef = ([string]$dNext.prepare.reference)
    $goodFp = ([string]$dNext.prepare.prepared_fingerprint)
    $envCanaryTask = [ordered]@{ task_id = 'sk-SYNTHETICSECRET-01'; idempotency_key = $goodKey; reference = $goodRef; prepared_fingerprint = $goodFp }
    $envCanaryTaskFile = Join-Path $tempRoot 'env-canary-task.json'
    Write-Fixture -Path $envCanaryTaskFile -Text (($envCanaryTask | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rCanTask = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envCanaryTaskFile, '-ResultFile', $resFile)
    $dCanTask = Read-JsonDoc -Text $rCanTask.Text
    Assert-That (($rCanTask.Code -eq 0) -and ($null -ne $dCanTask) -and (-not [bool]$dCanTask.ok) -and ([string]$dCanTask.reason -ceq 'envelope-unbound')) 'canary task id => envelope-unbound' ("Exit $($rCanTask.Code) :: $($rCanTask.Text)")
    Assert-That ($rCanTask.Text -cnotmatch 'SYNTHETICSECRET') 'canary task id never echoed to stdout' 'canary leaked'
    $envUrlRef = [ordered]@{ task_id = $taskId; idempotency_key = $goodKey; reference = 'https://example.invalid/r'; prepared_fingerprint = $goodFp }
    $envUrlRefFile = Join-Path $tempRoot 'env-url-ref.json'
    Write-Fixture -Path $envUrlRefFile -Text (($envUrlRef | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rUrlRef = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envUrlRefFile, '-ResultFile', $resFile)
    $dUrlRef = Read-JsonDoc -Text $rUrlRef.Text
    Assert-That (($rUrlRef.Code -eq 0) -and ($null -ne $dUrlRef) -and (-not [bool]$dUrlRef.ok) -and ([string]$dUrlRef.reason -ceq 'envelope-unbound')) 'URL reference => envelope-unbound' ("Exit $($rUrlRef.Code) :: $($rUrlRef.Text)")
    Assert-That ($rUrlRef.Text -cnotmatch 'example\.invalid') 'URL reference never echoed to stdout' 'url leaked'
    $envUrlTask = [ordered]@{ task_id = 'https://example.invalid/t'; idempotency_key = $goodKey; reference = $goodRef; prepared_fingerprint = $goodFp }
    $envUrlTaskFile = Join-Path $tempRoot 'env-url-task.json'
    Write-Fixture -Path $envUrlTaskFile -Text (($envUrlTask | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rUrlTask = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envUrlTaskFile, '-ResultFile', $resFile)
    $dUrlTask = Read-JsonDoc -Text $rUrlTask.Text
    Assert-That (($rUrlTask.Code -eq 0) -and ($null -ne $dUrlTask) -and (-not [bool]$dUrlTask.ok)) 'URL task id => rejected' ("Exit $($rUrlTask.Code) :: $($rUrlTask.Text)")
    Assert-That ($rUrlTask.Text -cnotmatch 'example\.invalid') 'URL task id never echoed to stdout' 'url leaked'
    # ---------- LOW: terminal LF sneaks past ^...$ in .NET => must refuse ----------
    $envLfTask = [ordered]@{ task_id = ($taskId + "`n"); idempotency_key = $goodKey; reference = $goodRef; prepared_fingerprint = $goodFp }
    $envLfTaskFile = Join-Path $tempRoot 'env-lf-task.json'
    Write-Fixture -Path $envLfTaskFile -Text (($envLfTask | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rLfTask = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envLfTaskFile, '-ResultFile', $resFile)
    $dLfTask = Read-JsonDoc -Text $rLfTask.Text
    Assert-That (($rLfTask.Code -eq 0) -and ($null -ne $dLfTask) -and (-not [bool]$dLfTask.ok) -and ([string]$dLfTask.reason -ceq 'envelope-unbound')) 'LF-suffixed task id => envelope-unbound' ("Exit $($rLfTask.Code)")
    Assert-That ($rLfTask.Text -cnotmatch [regex]::Escape($taskId)) 'LF-suffixed task id never echoed' 'value leaked'
    $envLfRef = [ordered]@{ task_id = $taskId; idempotency_key = $goodKey; reference = ($goodRef + "`n"); prepared_fingerprint = $goodFp }
    $envLfRefFile = Join-Path $tempRoot 'env-lf-ref.json'
    Write-Fixture -Path $envLfRefFile -Text (($envLfRef | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rLfRef = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envLfRefFile, '-ResultFile', $resFile)
    $dLfRef = Read-JsonDoc -Text $rLfRef.Text
    Assert-That (($rLfRef.Code -eq 0) -and ($null -ne $dLfRef) -and (-not [bool]$dLfRef.ok) -and ([string]$dLfRef.reason -ceq 'envelope-unbound')) 'LF-suffixed reference => envelope-unbound' ("Exit $($rLfRef.Code)")
    Assert-That ($rLfRef.Text -cnotmatch [regex]::Escape($goodRef)) 'LF-suffixed reference never echoed' 'value leaked'
    $envLfKey = [ordered]@{ task_id = $taskId; idempotency_key = ($goodKey + "`n"); reference = $goodRef; prepared_fingerprint = $goodFp }
    $envLfKeyFile = Join-Path $tempRoot 'env-lf-key.json'
    Write-Fixture -Path $envLfKeyFile -Text (($envLfKey | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rLfKey = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envLfKeyFile, '-ResultFile', $resFile)
    $dLfKey = Read-JsonDoc -Text $rLfKey.Text
    Assert-That (($rLfKey.Code -eq 0) -and ($null -ne $dLfKey) -and (-not [bool]$dLfKey.ok) -and ([string]$dLfKey.reason -ceq 'envelope-unbound')) 'LF-suffixed key => envelope-unbound' ("Exit $($rLfKey.Code)")
    Assert-That ($rLfKey.Text -cnotmatch [regex]::Escape($goodKey)) 'LF-suffixed key never echoed' 'value leaked'
    $envLfFp = [ordered]@{ task_id = $taskId; idempotency_key = $goodKey; reference = $goodRef; prepared_fingerprint = ($goodFp + "`n") }
    $envLfFpFile = Join-Path $tempRoot 'env-lf-fp.json'
    Write-Fixture -Path $envLfFpFile -Text (($envLfFp | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $rLfFp = Invoke-StepCli -Argv @('-Action', 'settle', '-EnvelopeFile', $envLfFpFile, '-ResultFile', $resFile)
    $dLfFp = Read-JsonDoc -Text $rLfFp.Text
    Assert-That (($rLfFp.Code -eq 0) -and ($null -ne $dLfFp) -and (-not [bool]$dLfFp.ok) -and ([string]$dLfFp.reason -ceq 'envelope-unbound')) 'LF-suffixed fingerprint => envelope-unbound' ("Exit $($rLfFp.Code)")
    Assert-That ($rLfFp.Text -cnotmatch [regex]::Escape($goodFp)) 'LF-suffixed fingerprint never echoed' 'value leaked'
}
catch {
    Assert-That $false 'suite completed without harness error' ($_.Exception.Message)
}
finally {
    try {
        if ((-not [string]::IsNullOrWhiteSpace($tempRoot)) -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

Write-Host ("TOTAL: {0} / PASS: {1} / FAIL: {2}" -f $script:total, $script:passed, ($script:total - $script:passed))
if ($script:total -eq 0) { exit 1 }
if ($script:passed -ne $script:total) { exit 1 }
exit 0
