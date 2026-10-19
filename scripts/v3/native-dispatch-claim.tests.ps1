# native-dispatch-claim.tests.ps1 -- bridge CLI claim (F1-S1, isolated fixture only).
# Custom PS 5.1 / PS7 suite, no Pester. Fixtures in owned TEMP. No network,
# no spawn of workers, no model. Bracketed output the runner parses.
# Exit 0 all pass, 1 any fail. ASCII only.
#
# Covers:
#   * static boundary: dot-source safe, strict action, ASCII, single library
#     CLAIM call site, authority pins false, no spawn/network/secret/grant
#     patterns, no repo defaults, libs resolved via PSScriptRoot
#   * positive: real PREPARE in temp stores -> bridge (child process, stdin)
#     -> receipt claimed; zero worker-result/verification/DONE; kernel task
#     untouched; repo default receipt root untouched
#   * negatives: expired lease, stale generation, forged authorization,
#     replay, prompt/target/args divergence, invalid JSON, oversized
#     request, missing context, unknown request field, invalid action
#   * transport: missing bridge file, tampered fingerprint, lock timeout,
#     non-zero exit; post-CLAIM the reservation is kept and retry is blocked
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')

$ErrorActionPreference = 'Stop'

$v3 = $PSScriptRoot
$cli = Join-Path $v3 'native-dispatch-claim.ps1'
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

function Invoke-BridgeCli {
    param([string]$RequestText = '', [string]$ContextPath = '', [string]$Action = 'claim', [string]$CliPath = '')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $useCli = $cli
    if (-not [string]::IsNullOrWhiteSpace($CliPath)) { $useCli = $CliPath }
    $argv = @('-Action', $Action, '-ContextFile', $ContextPath)
    if ([string]::IsNullOrEmpty($RequestText)) {
        $text = & $script:childExe -NoProfile -File $useCli @argv
    }
    else {
        $text = $RequestText | & $script:childExe -NoProfile -File $useCli @argv
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = ((@($text) | ForEach-Object { "$_" }) -join "`n") }
}

function Invoke-BridgeFile {
    # Byte-exact stdin delivery via redirected file (no pipe re-encoding):
    # writes $Bytes verbatim to a temp file and runs the bridge with that
    # file as stdin. Returns @{ Code, Text }.
    param([byte[]]$Bytes, [string]$ContextPath = '', [string]$Action = 'claim', [string]$CliPath = '')
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $useCli = $cli
    if (-not [string]::IsNullOrWhiteSpace($CliPath)) { $useCli = $CliPath }
    $fbRoot = ''
    try {
        $fbRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndclaim-fb-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fbRoot -Force | Out-Null
        $inFile = Join-Path $fbRoot 'stdin.bin'
        $outFile = Join-Path $fbRoot 'stdout.txt'
        $errFile = Join-Path $fbRoot 'stderr.txt'
        [IO.File]::WriteAllBytes($inFile, $Bytes)
        $argList = @('-NoProfile', '-File', $useCli, '-Action', $Action, '-ContextFile', $ContextPath)
        $proc = Start-Process -FilePath $script:childExe -ArgumentList $argList -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
        $code = [int]$proc.ExitCode
        $text = ''
        try { $text = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) } catch { $text = '' }
        return @{ Code = $code; Text = ([string]$text).Trim() }
    }
    finally {
        $ErrorActionPreference = $prevEap
        try {
            if ((-not [string]::IsNullOrWhiteSpace($fbRoot)) -and (Test-Path -LiteralPath $fbRoot -PathType Container)) {
                Remove-Item -LiteralPath $fbRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }
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

function New-ClaimFixture {
    param([string]$Suffix = '')
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndclaim-' + $Suffix + '-' + [guid]::NewGuid().ToString('N'))
    $goalDir = Join-Path $tempRoot 'goals'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    Write-Fixture -Path $flagsPath -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    $goalId = ('cl-goal-' + $Suffix)
    $taskId = ('cl-task-' + $Suffix)
    $owner = 'planner-1'
    $session = ('ses-claim-' + $Suffix)
    $promptText = ('claim-fixture-prompt-' + $Suffix)
    $g = New-OrchestrationGoal -GoalId $goalId -Objective ('objetivo claim ' + $Suffix) -Criteria @('criterio-a') -StoreDir $goalDir
    if (-not [bool]$g.ok) { throw ('goal-create:' + [string]$g.reason) }
    $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
    if (-not [bool]$sv.ok) { throw ('goal-save:' + [string]$sv.reason) }
    $own = Acquire-OrchestrationGoalOwnership -GoalId $goalId -OwnerId $owner -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
    if (-not [bool]$own.ok) { throw ('ownership:' + [string]$own.reason) }
    $gen = [long]$own.ownership['generation']
    $t = New-OrchestrationTask -TaskId $taskId -Objective ('obj ' + $taskId) -TaskType 'implementation' `
        -Risk 'low' -Actor $owner -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
        -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
        -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
    if (-not [bool]$t.ok) { throw ('task-create:' + [string]$t.error) }
    $slot = Get-OrchestrationGoal -GoalId $goalId -StoreDir $goalDir
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $goalId -TaskId $taskId -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId $owner -OwnershipGeneration $gen
    if (-not [bool]$add.ok) { throw ('task-attach:' + [string]$add.reason) }
    $ph = Get-NativeDispatchHash32 $promptText
    if ([string]::IsNullOrWhiteSpace($ph)) { throw 'prompt-hash-empty' }
    $intentRes = New-OrchestrationNativeDispatchIntent -TaskId $taskId -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph `
        -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner $owner -OwnershipGeneration $gen -BaseRevision 'rev-a'
    if (-not [bool]$intentRes.ok) { throw ('intent:' + [string]$intentRes.reason) }
    $auth = [ordered]@{ explicit_allow = $true; goal_id = $goalId; owner = $owner; generation = $gen; source = 'planner' }
    $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $intentRes.intent -Authorization $auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -LockTimeoutMs 10000
    if (-not [bool]$prep.ok) { throw ('prepare:' + [string]$prep.reason) }
    $pkey = ''
    try { $pkey = ([string]$intentRes.intent.idempotency_key) } catch { $pkey = '' }
    return [pscustomobject]@{
        tempRoot = $tempRoot; goalDir = $goalDir; tasksDir = $tasksDir; receiptDir = $receiptDir; flagsPath = $flagsPath
        goalId = $goalId; taskId = $taskId; owner = $owner; gen = $gen; session = $session
        promptText = $promptText; auth = $auth; key = $pkey
        prep = $prep
    }
}

function Get-NCValueShim {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-ClaimKey {
    param($Prep)
    try { return ([string]$Prep.intent['idempotency_key']) } catch { return '' }
}

function Write-ClaimContext {
    param($Fx, [string]$PreparedFp = '', [string]$PromptHash = '', $TemplateOverride = $null, [string]$AuthOverridePath = '')
    $pfp = $PreparedFp
    if ([string]::IsNullOrWhiteSpace($pfp)) { $pfp = ([string]$Fx.prep.prepared_fingerprint) }
    $eh = $PromptHash
    if ([string]::IsNullOrWhiteSpace($eh)) { $eh = Get-NativeDispatchHash32 ([string]$Fx.promptText) }
    $tmpl = [ordered]@{ prompt = ([string]$Fx.promptText); agent = 'coder'; note = 's1' }
    if ($null -ne $TemplateOverride) { $tmpl = $TemplateOverride }
    $key = ([string]$Fx.key)
    $authPath = Join-Path ([string]$Fx.tempRoot) 'auth.json'
    if (-not [string]::IsNullOrWhiteSpace($AuthOverridePath)) { $authPath = $AuthOverridePath }
    else { Write-Fixture -Path $authPath -Text (([pscustomobject]$Fx.auth | ConvertTo-Json -Depth 6 -Compress) + "`n") }
    $ctx = [ordered]@{
        schema_version = 1
        receipt_dir = ([string]$Fx.receiptDir)
        goal_store_dir = ([string]$Fx.goalDir)
        tasks_dir = ([string]$Fx.tasksDir)
        flags_path = ([string]$Fx.flagsPath)
        authorization_file = $authPath
        idempotency_key = $key
        prepared_fingerprint = $pfp
        expected_caller_agent = 'planner'
        expected_target_agent = 'coder'
        expected_prompt_hash = $eh
        expected_args_template = $tmpl
    }
    $ctxPath = Join-Path ([string]$Fx.tempRoot) ('claim-context-' + [guid]::NewGuid().ToString('N') + '.json')
    Write-Fixture -Path $ctxPath -Text (([pscustomobject]$ctx | ConvertTo-Json -Depth 6 -Compress) + "`n")
    return $ctxPath
}

function New-ClaimRequest {
    param($Fx, [string]$Caller = 'planner', [string]$Target = 'coder', [string]$Tool = 'subagent', $ArgsOverride = $null, [string]$Message = '', [string]$Call = '')
    $mid = $Message
    if ([string]::IsNullOrWhiteSpace($mid)) { $mid = ('msg-claim-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    $cid = $Call
    if ([string]::IsNullOrWhiteSpace($cid)) { $cid = ('call-claim-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
    $args = [ordered]@{ prompt = ([string]$Fx.promptText); agent = 'coder'; note = 's1' }
    if ($null -ne $ArgsOverride) { $args = $ArgsOverride }
    $req = [ordered]@{
        schema_version = 1
        session_id = ([string]$Fx.session)
        message_id = $mid
        call_id = $cid
        caller_agent = $Caller
        target_agent = $Target
        tool = $Tool
        args = $args
    }
    return ([pscustomobject]$req | ConvertTo-Json -Depth 6 -Compress)
}

function Get-ReceiptDoc {
    param($Fx)
    try {
        $sub = Get-NDGoalReceiptDir -RootDir ([string]$Fx.receiptDir) -GoalId ([string]$Fx.goalId)
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        $rp = Join-Path $sub (([string]$Fx.key) + '.json')
        if (-not (Test-Path -LiteralPath $rp -PathType Leaf)) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($rp, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

try {
    Assert-That (-not [string]::IsNullOrWhiteSpace($script:childExe)) 'child engine resolved' "Engine=$Engine"
    Assert-That (Test-Path -LiteralPath $cli -PathType Leaf) 'CLI file exists' "Missing $cli"
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'CLI missing, remaining assertions cannot run' }

    # ---------- static boundary ----------
    $cliText = [IO.File]::ReadAllText($cli, [Text.Encoding]::UTF8)
    foreach ($bad in @('Invoke-OrchestrationNativeDispatchPrepare', 'Invoke-OrchestrationNativeDispatchSettle', 'Invoke-OrchestrationDispatchResultShape', 'Set-OrchestrationTaskWorkerResult', 'Complete-OrchestrationTask', 'New-ExecutionGrant', 'Test-OrchestrationTaskCompletion', 'Invoke-Expression', 'Start-Process', 'Start-Job', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Remove-Item', 'New-Object System.Net', 'AutonomousLoop', 'DispatchSpec', 'native-dispatch-receipts')) {
        Assert-That ($cliText -cnotmatch $bad) ("CLI has no authority/effect pattern: " + $bad) 'found in CLI text'
    }
    Assert-That ($cliText -cnotmatch 'Invoke-OrchestrationNativeDispatch(\s|"''|$)') 'CLI never calls legacy dispatch path' 'legacy invoke present'
    Assert-That (([regex]::Matches($cliText, 'Invoke-OrchestrationNativeDispatchClaim\s+-IdempotencyKey')).Count -eq 1) 'CLI calls the CLAIM entrypoint exactly once' 'call-site count differs'
    Assert-That ($cliText -cmatch 'grants_authority\s+=\s+\$false') 'CLI pins grants_authority false' 'missing'
    Assert-That ($cliText -cmatch 'done_approved\s+=\s+\$false') 'CLI pins done_approved false' 'missing'
    Assert-That ($cliText -cmatch 'verified_pass\s+=\s+\$false') 'CLI pins verified_pass false' 'missing'
    Assert-That ($cliText -cnotmatch 'grants_authority = \$true') 'CLI never grants authority (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch 'done_approved = \$true') 'CLI never approves done (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch 'verified_pass = \$true') 'CLI never emits verified_pass (literal)' 'literal true present'
    Assert-That ($cliText -cnotmatch '\s-Command[\s"''`]') 'CLI never uses -Command' 'found'
    Assert-That ($cliText -cmatch '\$PSScriptRoot') 'CLI resolves libs via PSScriptRoot' 'missing'
    Assert-That ($cliText -cnotmatch 'C:\\Users') 'CLI has no machine-specific path' 'found'
    $rawBytes = [IO.File]::ReadAllBytes($cli)
    $nonAscii = 0
    foreach ($b in $rawBytes) { if ([int]$b -gt 127) { $nonAscii++ } }
    Assert-That ($nonAscii -eq 0) 'CLI is ASCII-only' ("non-ascii bytes: " + $nonAscii)

    # ---------- dot-source safety ----------
    . $cli
    Assert-That ($null -ne (Get-Command Read-NCJsonFile -ErrorAction SilentlyContinue)) 'dot-source exposes json reader' 'missing'
    Assert-That ($null -ne (Get-Command Write-NCEnvelope -ErrorAction SilentlyContinue)) 'dot-source exposes envelope writer' 'missing'
    Assert-That (Test-NCHex32 -Value 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'pure: 32hex accepted' 'rejected'
    Assert-That (-not (Test-NCHex32 -Value 'https://example.invalid/r')) 'pure: URL rejected as key' 'accepted'

    # ---------- fresh process, no args => silent exit 0 ----------
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tNone = & $script:childExe -NoProfile -File $cli
    $cNone = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $tNoneText = ((@($tNone) | ForEach-Object { "$_" }) -join "`n")
    Assert-That (($cNone -eq 0) -and ([string]::IsNullOrWhiteSpace($tNoneText))) 'no args => silent exit 0' ("Exit $cNone :: $tNoneText")

    # ---------- invalid action => exit 2 ----------
    $rBad = Invoke-BridgeCli -RequestText '' -ContextPath ([IO.Path]::GetTempPath()) -Action 'settle'
    $dBad = Read-JsonDoc -Text $rBad.Text
    Assert-That (($rBad.Code -eq 2) -and ($null -ne $dBad) -and (-not [bool]$dBad.ok)) 'invalid action => exit 2 with ok:false' ("Exit $($rBad.Code) :: $($rBad.Text)")

    # ---------- lib for fixtures ----------
    . (Join-Path $v3 'lib\OrchestrationNativeDispatch.ps1')

    # ---------- POSITIVE ----------
    $fx = New-ClaimFixture -Suffix 's1pos'
    $ctxPath = Write-ClaimContext -Fx $fx
    $reqText = New-ClaimRequest -Fx $fx
    $taskBefore = Get-OrchestrationTask -TaskId ([string]$fx.taskId) -TasksDir ([string]$fx.tasksDir)
    $revBefore = [long]$taskBefore.revision
    $rPos = Invoke-BridgeCli -RequestText $reqText -ContextPath $ctxPath
    $dPos = Read-JsonDoc -Text $rPos.Text
    Assert-That (($rPos.Code -eq 0) -and ($null -ne $dPos) -and ([bool]$dPos.ok) -and ([bool]$dPos.claimed)) 'positive claim => exit 0 ok:true claimed:true' ("Exit $($rPos.Code) :: $($rPos.Text)")
    if ($null -ne $dPos) {
        Assert-That (([string]$dPos.operation -ceq 'claim') -and ([string]$dPos.reason -ceq '')) 'positive envelope carries operation + empty reason' $rPos.Text
        Assert-That (([bool]$dPos.grants_authority -eq $false) -and ([bool]$dPos.done_approved -eq $false) -and ([bool]$dPos.verified_pass -eq $false)) 'positive envelope carries zero authority' $rPos.Text
        Assert-That ((Test-NCHex32 -Value ([string]$dPos.idempotency_key)) -and (Test-NCHex32 -Value ([string]$dPos.prepared_fingerprint)) -and (Test-NCHex32 -Value ([string]$dPos.call_fingerprint))) 'positive envelope carries hex bindings' $rPos.Text
        Assert-That (([string]$dPos.session_id -ceq [string]$fx.session)) 'positive envelope echoes the session' $rPos.Text
        Assert-That (([string]$dPos.target_agent -ceq 'coder') -and ([string]$dPos.tool -ceq 'subagent')) 'positive envelope echoes target agent + tool' $rPos.Text
        $matOk = $false
        try {
            $matText = ([string]$dPos.call_binding_material)
            $reFp = Get-NativeDispatchHash32 $matText
            $matOk = ((-not [string]::IsNullOrWhiteSpace($matText)) -and ($reFp -ceq ([string]$dPos.call_fingerprint)))
        }
        catch { $matOk = $false }
        Assert-That $matOk 'call_fingerprint recomputes from call_binding_material' $rPos.Text
        $lines = @($rPos.Text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-That (@($lines).Count -eq 1) 'positive output is a single JSON line' ("lines=" + @($lines).Count)
        Assert-That ($rPos.Text.Length -le 65536) 'positive output within 64 KiB' ("len=" + $rPos.Text.Length)
    }
    $rcPos = Get-ReceiptDoc -Fx $fx
    Assert-That (($null -ne $rcPos) -and ([string]$rcPos.phase -ceq 'claimed') -and ([string]$rcPos.handoff_state -ceq 'DISPATCH_UNCERTAIN')) 'receipt transitioned prepared -> claimed' 'phase mismatch'
    if ($null -ne $rcPos) {
        $rnames = @()
        try { foreach ($p in @($rcPos.PSObject.Properties)) { $rnames += @([string]$p.Name) } } catch { }
        $leak = $false
        foreach ($rn in @($rnames)) {
            if ($rn -cmatch 'worker_result|worker_status|verified|done|settl|evidence') { $leak = $true; break }
        }
        Assert-That (-not $leak) 'claimed receipt carries zero worker-result/verification/DONE' ($rnames -join ',')
    }
    $taskAfter = Get-OrchestrationTask -TaskId ([string]$fx.taskId) -TasksDir ([string]$fx.tasksDir)
    Assert-That ([long]$taskAfter.revision -eq $revBefore) 'claim left the kernel task untouched' ("rev before=$revBefore after=$([long]$taskAfter.revision)")
    $defaultRoot = Join-Path (Join-Path $repo 'cache') 'native-dispatch-receipts'
    $defaultHit = $false
    try {
        $hh = Get-NativeDispatchHash32 ([string]$fx.goalId)
        if (-not [string]::IsNullOrWhiteSpace($hh)) {
            $ds = Join-Path $defaultRoot $hh
            if (Test-Path -LiteralPath $ds -PathType Container) {
                $hits = @(Get-ChildItem -File (Join-Path $ds '*.json') -ErrorAction SilentlyContinue)
                if (@($hits).Count -gt 0) { $defaultHit = $true }
            }
        }
    } catch { }
    Assert-That (-not $defaultHit) 'repo default receipt root untouched' $defaultRoot

    # ---------- REPLAY: same binding again => consumed, reservation kept ----------
    $rRep = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fx -Message 'msg-replay-01' -Call 'call-replay-01') -ContextPath $ctxPath
    $dRep = Read-JsonDoc -Text $rRep.Text
    Assert-That (($rRep.Code -eq 0) -and ($null -ne $dRep) -and (-not [bool]$dRep.ok) -and ([string]$dRep.reason -ceq 'claim-already-consumed')) 'replay => claim-already-consumed' ("Exit $($rRep.Code) :: $($rRep.Text)")
    $rcRep = Get-ReceiptDoc -Fx $fx
    Assert-That (($null -ne $rcRep) -and ([string]$rcRep.phase -ceq 'claimed')) 'replay kept the claimed reservation' 'phase changed'

    # ---------- NEGATIVE: expired lease ----------
    $fxL = New-ClaimFixture -Suffix 's1lease'
    $shr = Renew-OrchestrationGoalOwnership -GoalId ([string]$fxL.goalId) -OwnerId 'planner-1' -Generation ([long]$fxL.gen) -StoreDir ([string]$fxL.goalDir) -LeaseTtlMs 1
    Assert-That (([bool]$shr.ok)) '[F] lease shrunk to force expiry' ([string]$shr.reason)
    Start-Sleep -Milliseconds 400
    $ctxL = Write-ClaimContext -Fx $fxL
    $rL = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxL) -ContextPath $ctxL
    $dL = Read-JsonDoc -Text $rL.Text
    Assert-That (($rL.Code -eq 0) -and ($null -ne $dL) -and (-not [bool]$dL.ok) -and (-not [bool]$dL.claimed)) 'expired lease => refused exit 0' ("Exit $($rL.Code) :: $($rL.Text)")
    $rcL = Get-ReceiptDoc -Fx $fxL
    Assert-That (($null -ne $rcL) -and ([string]$rcL.phase -ceq 'prepared')) 'expired lease never consumes the prepared receipt' 'phase changed'

    # ---------- NEGATIVE: stale generation ----------
    $fxG = New-ClaimFixture -Suffix 's1gen'
    $authG = [ordered]@{ explicit_allow = $true; goal_id = ([string]$fxG.goalId); owner = 'planner-1'; generation = ([long]$fxG.gen + 7); source = 'planner' }
    $authGPath = Join-Path ([string]$fxG.tempRoot) 'auth-stale.json'
    Write-Fixture -Path $authGPath -Text (([pscustomobject]$authG | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $ctxG = Write-ClaimContext -Fx $fxG -AuthOverridePath $authGPath
    $rG = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxG) -ContextPath $ctxG
    $dG = Read-JsonDoc -Text $rG.Text
    Assert-That (($rG.Code -eq 0) -and ($null -ne $dG) -and (-not [bool]$dG.ok)) 'stale generation => refused' ("Exit $($rG.Code) :: $($rG.Text)")

    # ---------- NEGATIVE: forged authorization (rival owner) ----------
    $fxF = New-ClaimFixture -Suffix 's1forge'
    $authF = [ordered]@{ explicit_allow = $true; goal_id = ([string]$fxF.goalId); owner = 'planner-2'; generation = ([long]$fxF.gen); source = 'planner' }
    $authFPath = Join-Path ([string]$fxF.tempRoot) 'auth-forge.json'
    Write-Fixture -Path $authFPath -Text (([pscustomobject]$authF | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $ctxF = Write-ClaimContext -Fx $fxF -AuthOverridePath $authFPath
    $rF = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxF) -ContextPath $ctxF
    $dF = Read-JsonDoc -Text $rF.Text
    Assert-That (($rF.Code -eq 0) -and ($null -ne $dF) -and (-not [bool]$dF.ok)) 'forged authorization => refused' ("Exit $($rF.Code) :: $($rF.Text)")
    $rcF = Get-ReceiptDoc -Fx $fxF
    Assert-That (($null -ne $rcF) -and ([string]$rcF.phase -ceq 'prepared')) 'forgery never consumes the prepared receipt' 'phase changed'

    # ---------- NEGATIVE: stale task revision (kernel advanced past prepare) ----------
    $fxR = New-ClaimFixture -Suffix 's1rev'
    $wr = Set-OrchestrationTaskWorkerResult -TaskId ([string]$fxR.taskId) -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir ([string]$fxR.tasksDir) -FlagsPath ([string]$fxR.flagsPath) -TelemetryRoot ([string]$fxR.tempRoot)
    $taskRAdv = $null
    try { $taskRAdv = Get-OrchestrationTask -TaskId ([string]$fxR.taskId) -TasksDir ([string]$fxR.tasksDir) } catch { $taskRAdv = $null }
    Assert-That (($null -ne $taskRAdv) -and ([long]$taskRAdv.revision -gt 1)) '[F] kernel task advanced past the prepared revision' 'revision did not move'
    $ctxR = Write-ClaimContext -Fx $fxR
    $rR = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxR) -ContextPath $ctxR
    $dR = Read-JsonDoc -Text $rR.Text
    Assert-That (($rR.Code -eq 0) -and ($null -ne $dR) -and (-not [bool]$dR.ok)) 'stale revision => refused' ("Exit $($rR.Code) :: $($rR.Text)")

    # ---------- NEGATIVE: prompt divergence ----------
    $fxP = New-ClaimFixture -Suffix 's1prompt'
    $ctxP = Write-ClaimContext -Fx $fxP
    $argsP = [ordered]@{ prompt = 'tampered-prompt-text'; agent = 'coder'; note = 's1' }
    $rP = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxP -ArgsOverride $argsP) -ContextPath $ctxP
    $dP = Read-JsonDoc -Text $rP.Text
    Assert-That (($rP.Code -eq 0) -and ($null -ne $dP) -and (-not [bool]$dP.ok) -and ([string]$dP.reason -ceq 'claim-args-template-mismatch')) 'prompt divergence => template refused before the library' ("Exit $($rP.Code) :: $($rP.Text)")
    $rcP = Get-ReceiptDoc -Fx $fxP
    Assert-That (($null -ne $rcP) -and ([string]$rcP.phase -ceq 'prepared')) 'prompt divergence wrote nothing' 'phase changed'

    # ---------- NEGATIVE: target divergence ----------
    $fxT = New-ClaimFixture -Suffix 's1target'
    $ctxT = Write-ClaimContext -Fx $fxT
    $argsT = [ordered]@{ prompt = ([string]$fxT.promptText); agent = 'tester'; note = 's1' }
    $rT = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxT -Target 'tester' -ArgsOverride $argsT) -ContextPath $ctxT
    $dT = Read-JsonDoc -Text $rT.Text
    Assert-That (($rT.Code -eq 0) -and ($null -ne $dT) -and (-not [bool]$dT.ok) -and ([string]$dT.reason -ceq 'claim-target-mismatch')) 'target divergence => refused' ("Exit $($rT.Code) :: $($rT.Text)")

    # ---------- NEGATIVE: args divergence (extra key) ----------
    $fxA = New-ClaimFixture -Suffix 's1args'
    $ctxA = Write-ClaimContext -Fx $fxA
    $argsA = [ordered]@{ prompt = ([string]$fxA.promptText); agent = 'coder'; note = 's1'; extra = 'nope' }
    $rA = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxA -ArgsOverride $argsA) -ContextPath $ctxA
    $dA = Read-JsonDoc -Text $rA.Text
    Assert-That (($rA.Code -eq 0) -and ($null -ne $dA) -and (-not [bool]$dA.ok) -and ([string]$dA.reason -ceq 'claim-args-template-mismatch')) 'extra arg => refused' ("Exit $($rA.Code) :: $($rA.Text)")

    # ---------- NEGATIVE: invalid JSON ----------
    $fxJ = New-ClaimFixture -Suffix 's1json'
    $ctxJ = Write-ClaimContext -Fx $fxJ
    $rJ = Invoke-BridgeCli -RequestText '{not json' -ContextPath $ctxJ
    $dJ = Read-JsonDoc -Text $rJ.Text
    Assert-That (($rJ.Code -eq 2) -and ($null -ne $dJ) -and (-not [bool]$dJ.ok)) 'invalid JSON => exit 2' ("Exit $($rJ.Code) :: $($rJ.Text)")

    # ---------- NEGATIVE: oversized request ----------
    $bigNote = ('x' * 70000)
    $argsBig = [ordered]@{ prompt = ([string]$fxJ.promptText); agent = 'coder'; note = $bigNote }
    $bigReq = New-ClaimRequest -Fx $fxJ -ArgsOverride $argsBig
    $bigBytes = [Text.Encoding]::UTF8.GetBytes($bigReq)
    $rBig = Invoke-BridgeFile -Bytes $bigBytes -ContextPath $ctxJ
    $dBig = Read-JsonDoc -Text $rBig.Text
    Assert-That (($rBig.Code -eq 2) -and ($null -ne $dBig) -and (-not [bool]$dBig.ok) -and ([string]$dBig.reason -ceq 'request-too-large')) 'oversized request => exit 2' ("Exit $($rBig.Code) :: len=$($bigReq.Length)")

    # ---------- NEGATIVE: missing context ----------
    $rMiss = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxJ) -ContextPath (Join-Path ([string]$fxJ.tempRoot) 'no-such-context.json')
    $dMiss = Read-JsonDoc -Text $rMiss.Text
    Assert-That (($rMiss.Code -eq 2) -and ($null -ne $dMiss) -and (-not [bool]$dMiss.ok)) 'missing context => exit 2' ("Exit $($rMiss.Code) :: $($rMiss.Text)")

    # ---------- NEGATIVE: unknown request field ----------
    $reqExtra = [ordered]@{
        schema_version = 1; session_id = ([string]$fxJ.session); message_id = 'msg-x-01'; call_id = 'call-x-01'
        caller_agent = 'planner'; target_agent = 'coder'; tool = 'subagent'
        args = [ordered]@{ prompt = ([string]$fxJ.promptText); agent = 'coder'; note = 's1' }
        injected = 'nope'
    }
    $rX = Invoke-BridgeCli -RequestText (([pscustomobject]$reqExtra | ConvertTo-Json -Depth 6 -Compress)) -ContextPath $ctxJ
    $dX = Read-JsonDoc -Text $rX.Text
    Assert-That (($rX.Code -eq 2) -and ($null -ne $dX) -and (-not [bool]$dX.ok)) 'unknown request field => exit 2' ("Exit $($rX.Code) :: $($rX.Text)")

    # ---------- R3: strict JSON types (exit 2, nothing coerced) ----------
    $fxS = New-ClaimFixture -Suffix 's1types'
    $ctxS = Write-ClaimContext -Fx $fxS
    $baseReq = New-ClaimRequest -Fx $fxS
    foreach ($svCase in @('1.4', '1.0', '"1"')) {
        $tCase = $baseReq -replace '"schema_version":1', ('"schema_version":' + $svCase)
        $rCase = Invoke-BridgeCli -RequestText $tCase -ContextPath $ctxS
        $dCase = Read-JsonDoc -Text $rCase.Text
        Assert-That (($rCase.Code -eq 2) -and ($null -ne $dCase) -and (-not [bool]$dCase.ok)) ("schema_version $svCase => exit 2, never coerced") ("Exit $($rCase.Code) :: $($rCase.Text)")
    }
    $tNum = $baseReq -replace '"session_id":"[^"]*"', '"session_id":123'
    $rNum = Invoke-BridgeCli -RequestText $tNum -ContextPath $ctxS
    $dNum = Read-JsonDoc -Text $rNum.Text
    Assert-That (($rNum.Code -eq 2) -and ($null -ne $dNum) -and (-not [bool]$dNum.ok) -and ([string]$dNum.reason -ceq 'invalid-request-value')) 'numeric session_id => exit 2' ("Exit $($rNum.Code) :: $($rNum.Text)")
    $argsBool = [ordered]@{ prompt = ([string]$fxS.promptText); agent = 'coder'; note = $true }
    $rBool = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxS -ArgsOverride $argsBool) -ContextPath $ctxS
    $dBool = Read-JsonDoc -Text $rBool.Text
    Assert-That (($rBool.Code -eq 2) -and ($null -ne $dBool) -and (-not [bool]$dBool.ok) -and ([string]$dBool.reason -ceq 'invalid-args-value')) 'bool arg => exit 2 (schema, not binding)' ("Exit $($rBool.Code) :: $($rBool.Text)")
    $argsArr = [ordered]@{ prompt = ([string]$fxS.promptText); agent = 'coder'; note = @('s1') }
    $rArr = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxS -ArgsOverride $argsArr) -ContextPath $ctxS
    $dArr = Read-JsonDoc -Text $rArr.Text
    Assert-That (($rArr.Code -eq 2) -and ($null -ne $dArr) -and (-not [bool]$dArr.ok) -and ([string]$dArr.reason -ceq 'invalid-args-value')) 'array arg => exit 2' ("Exit $($rArr.Code) :: $($rArr.Text)")
    $argsObj = [ordered]@{ prompt = ([string]$fxS.promptText); agent = 'coder'; note = [ordered]@{ x = 'y' } }
    $rObj = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxS -ArgsOverride $argsObj) -ContextPath $ctxS
    $dObj = Read-JsonDoc -Text $rObj.Text
    Assert-That (($rObj.Code -eq 2) -and ($null -ne $dObj) -and (-not [bool]$dObj.ok) -and ([string]$dObj.reason -ceq 'invalid-args-value')) 'object arg => exit 2' ("Exit $($rObj.Code) :: $($rObj.Text)")
    $argsNbr = [ordered]@{ prompt = ([string]$fxS.promptText); agent = 'coder'; note = 7 }
    $rNbr = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxS -ArgsOverride $argsNbr) -ContextPath $ctxS
    $dNbr = Read-JsonDoc -Text $rNbr.Text
    Assert-That (($rNbr.Code -eq 2) -and ($null -ne $dNbr) -and (-not [bool]$dNbr.ok) -and ([string]$dNbr.reason -ceq 'invalid-args-value')) 'number arg => exit 2' ("Exit $($rNbr.Code) :: $($rNbr.Text)")
    $tBig = $baseReq -replace '"note":"s1"', '"note":1234567890123456789012345678901234567890'
    $rBigN = Invoke-BridgeCli -RequestText $tBig -ContextPath $ctxS
    $dBigN = Read-JsonDoc -Text $rBigN.Text
    Assert-That (($rBigN.Code -eq 2) -and ($null -ne $dBigN) -and (-not [bool]$dBigN.ok) -and ([string]$dBigN.reason -ceq 'invalid-args-value')) 'big number arg => exit 2' ("Exit $($rBigN.Code) :: $($rBigN.Text)")
    $ctxTextS = [IO.File]::ReadAllText($ctxS, [Text.Encoding]::UTF8)
    $ctxBadVer = Join-Path ([string]$fxS.tempRoot) 'ctx-badver.json'
    Write-Fixture -Path $ctxBadVer -Text ($ctxTextS -replace '"schema_version":1', '"schema_version":"1"')
    $rCtxV = Invoke-BridgeCli -RequestText $baseReq -ContextPath $ctxBadVer
    $dCtxV = Read-JsonDoc -Text $rCtxV.Text
    Assert-That (($rCtxV.Code -eq 2) -and ($null -ne $dCtxV) -and (-not [bool]$dCtxV.ok) -and ([string]$dCtxV.reason -ceq 'invalid-context')) 'string schema_version in context => exit 2' ("Exit $($rCtxV.Code) :: $($rCtxV.Text)")

    # ---------- R3b: one-element arrays must not unroll through the pipeline ----------
    $tVerArr = $baseReq -replace '"schema_version":1', '"schema_version":[1]'
    $rVerArr = Invoke-BridgeCli -RequestText $tVerArr -ContextPath $ctxS
    $dVerArr = Read-JsonDoc -Text $rVerArr.Text
    Assert-That (($rVerArr.Code -eq 2) -and ($null -ne $dVerArr) -and (-not [bool]$dVerArr.ok)) 'schema_version [1] => exit 2, array preserved' ("Exit $($rVerArr.Code) :: $($rVerArr.Text)")
    $tArgsArr = $baseReq -replace '"args":\{', '"args":[{'
    $tArgsArr = $tArgsArr.Substring(0, $tArgsArr.Length - 1) + ']}'
    $rArgsArr = Invoke-BridgeCli -RequestText $tArgsArr -ContextPath $ctxS
    $dArgsArr = Read-JsonDoc -Text $rArgsArr.Text
    Assert-That (($rArgsArr.Code -eq 2) -and ($null -ne $dArgsArr) -and (-not [bool]$dArgsArr.ok)) 'args [{...}] => exit 2, array preserved' ("Exit $($rArgsArr.Code) :: $($rArgsArr.Text)")
    $ctxTextArr = $ctxTextS.TrimEnd()
    $ctxTextArr = $ctxTextArr -replace '"expected_args_template":\{', '"expected_args_template":[{'
    $ctxTextArr = $ctxTextArr.Substring(0, $ctxTextArr.Length - 1) + ']}'
    $ctxArrPath = Join-Path ([string]$fxS.tempRoot) 'ctx-arr.json'
    Write-Fixture -Path $ctxArrPath -Text ($ctxTextArr + "`n")
    $rCtxArr = Invoke-BridgeCli -RequestText $baseReq -ContextPath $ctxArrPath
    $dCtxArr = Read-JsonDoc -Text $rCtxArr.Text
    Assert-That (($rCtxArr.Code -eq 2) -and ($null -ne $dCtxArr) -and (-not [bool]$dCtxArr.ok) -and ([string]$dCtxArr.reason -ceq 'invalid-context')) 'template [{...}] => exit 2, array preserved' ("Exit $($rCtxArr.Code) :: $($rCtxArr.Text)")

    # ---------- R4: byte limits + strict decoding (no pipe re-encoding) ----------
    $fxB = New-ClaimFixture -Suffix 's1bytes'
    $ctxB = Write-ClaimContext -Fx $fxB
    $okReq = New-ClaimRequest -Fx $fxB
    $okBytes = [Text.Encoding]::UTF8.GetBytes($okReq)
    $padLen = 65536 - $okBytes.Length
    Assert-That ($padLen -gt 0) '[F] fixture request leaves room for limit padding' ("padLen=$padLen")
    $exact = New-Object byte[] 65536
    [Array]::Copy($okBytes, $exact, $okBytes.Length)
    for ($i = $okBytes.Length; $i -lt 65536; $i++) { $exact[$i] = 32 }
    $rExact = Invoke-BridgeFile -Bytes $exact -ContextPath $ctxB
    $dExact = Read-JsonDoc -Text $rExact.Text
    Assert-That (($rExact.Code -eq 0) -and ($null -ne $dExact)) 'exactly 65536 bytes => size gate passes (exit 0)' ("Exit $($rExact.Code) :: $($rExact.Text)")
    $over = New-Object byte[] 65537
    [Array]::Copy($okBytes, $over, $okBytes.Length)
    for ($i = $okBytes.Length; $i -lt 65537; $i++) { $over[$i] = 32 }
    $rOver = Invoke-BridgeFile -Bytes $over -ContextPath $ctxB
    $dOver = Read-JsonDoc -Text $rOver.Text
    Assert-That (($rOver.Code -eq 2) -and ($null -ne $dOver) -and (-not [bool]$dOver.ok) -and ([string]$dOver.reason -ceq 'request-too-large')) '65537 bytes => exit 2 without draining' ("Exit $($rOver.Code) :: $($rOver.Text)")
    $badUtf = [byte[]]@(123, 34, 97, 34, 58, 255, 254, 125)
    $rUtf = Invoke-BridgeFile -Bytes $badUtf -ContextPath $ctxB
    $dUtf = Read-JsonDoc -Text $rUtf.Text
    Assert-That (($rUtf.Code -eq 2) -and ($null -ne $dUtf) -and (-not [bool]$dUtf.ok) -and ([string]$dUtf.reason -ceq 'request-invalid-encoding')) 'invalid UTF-8 bytes => exit 2' ("Exit $($rUtf.Code) :: $($rUtf.Text)")
    $ctxRawBytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($ctxB, [Text.Encoding]::UTF8))
    $ctxBadEnc = New-Object byte[] ($ctxRawBytes.Length + 1)
    [Array]::Copy($ctxRawBytes, 0, $ctxBadEnc, 0, 10)
    $ctxBadEnc[10] = 255
    [Array]::Copy($ctxRawBytes, 10, $ctxBadEnc, 11, ($ctxRawBytes.Length - 10))
    $ctxBadEncPath = Join-Path ([string]$fxB.tempRoot) 'ctx-badenc.json'
    [IO.File]::WriteAllBytes($ctxBadEncPath, $ctxBadEnc)
    $rCtxBad = Invoke-BridgeCli -RequestText $okReq -ContextPath $ctxBadEncPath
    $dCtxBad = Read-JsonDoc -Text $rCtxBad.Text
    Assert-That (($rCtxBad.Code -eq 2) -and ($null -ne $dCtxBad) -and (-not [bool]$dCtxBad.ok) -and ([string]$dCtxBad.reason -ceq 'invalid-context-file')) 'invalid UTF-8 context => exit 2' ("Exit $($rCtxBad.Code) :: $($rCtxBad.Text)")

    # ---------- R5: library failure escapes only through the fixed envelope ----------
    $fxR5 = New-ClaimFixture -Suffix 's1lib'
    $ctxR5 = Write-ClaimContext -Fx $fxR5
    $libDir = Join-Path ([string]$fxR5.tempRoot) 'nolib'
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    $cliCopy = Join-Path $libDir 'native-dispatch-claim.ps1'
    Copy-Item -LiteralPath $cli -Destination $cliCopy -Force
    $rNoLib = Invoke-BridgeCli -RequestText '' -ContextPath $ctxR5 -CliPath $cliCopy
    $dNoLib = Read-JsonDoc -Text $rNoLib.Text
    Assert-That (($rNoLib.Code -eq 1) -and ($null -ne $dNoLib) -and (-not [bool]$dNoLib.ok) -and ([string]$dNoLib.reason -ceq 'lib-unavailable')) 'missing library => exit 1 lib-unavailable' ("Exit $($rNoLib.Code) :: $($rNoLib.Text)")
    $libDir2 = Join-Path ([string]$fxR5.tempRoot) 'badlib'
    New-Item -ItemType Directory -Path (Join-Path $libDir2 'lib') -Force | Out-Null
    $cliCopy2 = Join-Path $libDir2 'native-dispatch-claim.ps1'
    Copy-Item -LiteralPath $cli -Destination $cliCopy2 -Force
    [IO.File]::WriteAllText((Join-Path $libDir2 'lib\OrchestrationNativeDispatch.ps1'), "throw 'boom-canary-lib-xyz'", [Text.UTF8Encoding]::new($false))
    $rThrow = Invoke-BridgeCli -RequestText '' -ContextPath $ctxR5 -CliPath $cliCopy2
    $dThrow = Read-JsonDoc -Text $rThrow.Text
    Assert-That (($rThrow.Code -eq 1) -and ($null -ne $dThrow) -and (-not [bool]$dThrow.ok) -and ([string]$dThrow.reason -ceq 'lib-unavailable')) 'throwing library => exit 1 lib-unavailable' ("Exit $($rThrow.Code) :: $($rThrow.Text)")
    Assert-That ($rThrow.Text -cnotmatch 'boom-canary-lib-xyz') 'throwing library leaks no exception text' 'canary leaked'

    # ---------- SEC1: context-swapped prompt binds to the durable receipt ----------
    $fxE = New-ClaimFixture -Suffix 's1evil'
    $evilPrompt = 'evil-prompt-not-prepared'
    $evilHash = Get-NativeDispatchHash32 $evilPrompt
    Assert-That (-not [string]::IsNullOrWhiteSpace($evilHash)) '[F] evil prompt hash' 'empty'
    $tmplEvil = [ordered]@{ prompt = $evilPrompt; agent = 'coder'; note = 's1' }
    $ctxE = Write-ClaimContext -Fx $fxE -PromptHash $evilHash -TemplateOverride $tmplEvil
    $argsEvil = [ordered]@{ prompt = $evilPrompt; agent = 'coder'; note = 's1' }
    $rE = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxE -ArgsOverride $argsEvil) -ContextPath $ctxE
    $dE = Read-JsonDoc -Text $rE.Text
    Assert-That (($rE.Code -eq 0) -and ($null -ne $dE) -and (-not [bool]$dE.ok) -and ([string]$dE.reason -ceq 'receipt-prompt-mismatch')) 'swapped context prompt => durable refusal' ("Exit $($rE.Code) :: $($rE.Text)")
    $rcE = Get-ReceiptDoc -Fx $fxE
    Assert-That (($null -ne $rcE) -and ([string]$rcE.phase -ceq 'prepared')) 'durable refusal consumes nothing' 'phase changed'

    # ---------- TRANSPORT: missing bridge executable ----------
    $prevEap2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tMiss = & $script:childExe -NoProfile -File (Join-Path $v3 'no-such-bridge.ps1') -Action claim -ContextFile $ctxJ
    $cMiss = $LASTEXITCODE
    $ErrorActionPreference = $prevEap2
    Assert-That ($cMiss -ne 0) 'missing bridge executable => non-zero exit' ("Exit $cMiss")

    # ---------- TRANSPORT: tampered fingerprint ----------
    $fxH = New-ClaimFixture -Suffix 's1hash'
    $goodFp = ([string]$fxH.prep.prepared_fingerprint)
    $lastCh = $goodFp.Substring(31, 1)
    $flipCh = '0'
    if ($lastCh -ceq '0') { $flipCh = '1' }
    $badFp = $goodFp.Substring(0, 31) + $flipCh
    $ctxH = Write-ClaimContext -Fx $fxH -PreparedFp $badFp
    $rH = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxH) -ContextPath $ctxH
    $dH = Read-JsonDoc -Text $rH.Text
    Assert-That (($rH.Code -eq 0) -and ($null -ne $dH) -and (-not [bool]$dH.ok) -and ([string]$dH.reason -ceq 'claim-fingerprint-mismatch')) 'tampered fingerprint => refused' ("Exit $($rH.Code) :: $($rH.Text)")
    $rcH = Get-ReceiptDoc -Fx $fxH
    Assert-That (($null -ne $rcH) -and ([string]$rcH.phase -ceq 'prepared')) 'tampered fingerprint wrote nothing' 'phase changed'

    # ---------- TRANSPORT: lock timeout (receipt lock held) ----------
    $fxK = New-ClaimFixture -Suffix 's1lock'
    $ctxK = Write-ClaimContext -Fx $fxK
    $nsK = Get-NDGoalReceiptDir -RootDir ([string]$fxK.receiptDir) -GoalId ([string]$fxK.goalId)
    Assert-That (-not [string]::IsNullOrWhiteSpace($nsK)) '[F] receipt namespace resolved' 'empty'
    $held = $null
    try { $held = [IO.File]::Open((Join-Path $nsK '.dispatch.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $held = $null }
    Assert-That ($null -ne $held) '[F] receipt lock held for the timeout window' 'open failed'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rK = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxK) -ContextPath $ctxK
    $sw.Stop()
    try { $held.Dispose() } catch { }
    $dK = Read-JsonDoc -Text $rK.Text
    Assert-That (($rK.Code -eq 0) -and ($null -ne $dK) -and (-not [bool]$dK.ok) -and ([string]$dK.reason -ceq 'lock-busy')) 'held lock => lock-busy refused' ("Exit $($rK.Code) :: $($rK.Text)")
    Assert-That ((($sw.ElapsedMilliseconds -ge 1500) -and ($sw.ElapsedMilliseconds -lt 25000))) 'lock wait honored the 2 s budget' ("elapsed ms=" + $sw.ElapsedMilliseconds)
    $rcK = Get-ReceiptDoc -Fx $fxK
    Assert-That (($null -ne $rcK) -and ([string]$rcK.phase -ceq 'prepared')) 'lock timeout left the prepared reservation intact' 'phase changed'
    # post-timeout the legitimate claim still succeeds: timeout never consumed.
    $rK2 = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxK -Message 'msg-after-lock' -Call 'call-after-lock') -ContextPath $ctxK
    $dK2 = Read-JsonDoc -Text $rK2.Text
    Assert-That (($rK2.Code -eq 0) -and ($null -ne $dK2) -and ([bool]$dK2.ok) -and ([bool]$dK2.claimed)) 'claim after the lock window succeeds' ("Exit $($rK2.Code) :: $($rK2.Text)")
    # ... and a later retry stays blocked: the reservation is kept.
    $rK3 = Invoke-BridgeCli -RequestText (New-ClaimRequest -Fx $fxK -Message 'msg-retry-01' -Call 'call-retry-01') -ContextPath $ctxK
    $dK3 = Read-JsonDoc -Text $rK3.Text
    Assert-That (($rK3.Code -eq 0) -and ($null -ne $dK3) -and (-not [bool]$dK3.ok) -and ([string]$dK3.reason -ceq 'claim-already-consumed')) 'post-CLAIM retry stays blocked' ("Exit $($rK3.Code) :: $($rK3.Text)")
}
catch {
    Assert-That $false 'suite completed without harness error' ($_.Exception.Message)
}
finally {
    try {
        foreach ($root in @($fx.tempRoot, $fxL.tempRoot, $fxG.tempRoot, $fxF.tempRoot, $fxR.tempRoot, $fxP.tempRoot, $fxT.tempRoot, $fxA.tempRoot, $fxJ.tempRoot, $fxH.tempRoot, $fxK.tempRoot, $fxS.tempRoot, $fxB.tempRoot, $fxR5.tempRoot, $fxE.tempRoot)) {
            if ((-not [string]::IsNullOrWhiteSpace($root)) -and (Test-Path -LiteralPath $root -PathType Container)) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

Write-Host ("TOTAL: {0} / PASS: {1} / FAIL: {2}" -f $script:total, $script:passed, ($script:total - $script:passed))
if ($script:total -eq 0) { exit 1 }
if ($script:passed -ne $script:total) { exit 1 }
exit 0
