<#!
.SYNOPSIS
    Tests for the Task Kernel model-attempt / failure-proof slice (Router v1.4).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP, fixture flags files, cleanup in
    finally. Bracketed output the runner parses. Exit 0 on all pass,
    exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
    No model dispatch, no network, no paid inference. Trust boundary:
    ONLY Invoke-TaskKernelVerifyRun (real in-process verifier execution
    against the task's OWN repo + committed verification plan) can
    persist kernel-executed marks; Set-OrchestrationTaskVerification JSON
    input is always caller-supplied and can never yield proof. Profiles
    are committed at task creation (no run-time selection); the
    verification root is always the task's canonical root (no repo flag).
    The native session reader seam simulates exact host response shapes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-ModelProof {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-ModelProofFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-ModelProofTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-task-kernel-proof-' + [guid]::NewGuid().ToString('N'))
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    Write-ModelProofFixture -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; tasks = $tasks; flags = $flags }
}

function New-VerifyRunRepo {
    param([string]$Name = 'vr')
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('vkr-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -b master *>$null
    if ($LASTEXITCODE -ne 0) { & git -C $dir init *>$null }
    & git -C $dir config user.email 'proof-test@example.com' *>$null
    & git -C $dir config user.name 'Proof Test' *>$null
    & git -C $dir config core.autocrlf false *>$null
    & git -C $dir config core.safecrlf false *>$null
    Write-ModelProofFixture -Path (Join-Path $dir 'base.txt') -Text "base`n"
    & git -C $dir add -A *>$null
    & git -C $dir commit -m init -q *>$null
    return $dir
}

function New-RepoTaskRoot {
    param([string]$Name = 'rt')
    $outer = Join-Path ([IO.Path]::GetTempPath()) ('v3-rt-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path $outer 'repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -b master *>$null
    if ($LASTEXITCODE -ne 0) { & git -C $repo init *>$null }
    & git -C $repo config user.email 'proof-test@example.com' *>$null
    & git -C $repo config user.name 'Proof Test' *>$null
    & git -C $repo config core.autocrlf false *>$null
    & git -C $repo config core.safecrlf false *>$null
    Write-ModelProofFixture -Path (Join-Path $repo 'base.txt') -Text "base`n"
    & git -C $repo add -A *>$null
    & git -C $repo commit -m init -q *>$null
    $tasks = Join-Path $outer 'tasks-kernel'
    $flags = Join-Path $outer 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    Write-ModelProofFixture -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    $poldir = Join-Path $repo 'source\registry'
    New-Item -ItemType Directory -Path $poldir -Force | Out-Null
    $profObj = New-Object PSCustomObject
    $profObj | Add-Member -NotePropertyName 'passes' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 0'; timeout_seconds = 30 })
    $profObj | Add-Member -NotePropertyName 'failer' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 1'; timeout_seconds = 30 })
    $doc = [ordered]@{ version = 1; default_timeout_seconds = 60; max_output_chars = 4000; profiles = $profObj }
    $polPath = Join-Path $poldir 'verification-policy.json'
    $json = (New-Object PSCustomObject -Property $doc | ConvertTo-Json -Depth 8 -Compress)
    Write-ModelProofFixture -Path $polPath -Text $json
    & git -C $repo add -A *>$null
    & git -C $repo commit -m policy -q *>$null
    return @{ root = $outer; repo = $repo; tasks = $tasks; flags = $flags; policy = $polPath }
}

function New-ProofVerifierJson {
    param(
        [string]$Status = 'verification_failed',
        [bool]$Ok = $true,
        [string]$CriterionWord = 'unverified',
        [string]$ProfileStatus = 'failed',
        [int]$ExitCode = 1,
        [string[]]$Evidence = $null,
        $Profiles = $null,
        $MapWord = $null
    )
    if ($Status -ceq 'verified_pass') {
        if ([string]::IsNullOrWhiteSpace($CriterionWord)) { $CriterionWord = 'verified' }
        if ([string]::IsNullOrWhiteSpace($ProfileStatus)) { $ProfileStatus = 'verified' }
        $ExitCode = 0
    }
    if ($Status -ceq 'manual_verification_required') {
        $o = [ordered]@{
            ok = $false; task_id = 'fixture'; status = $Status; reason = 'manual'
            scope = $null; profiles = @(); criterion_map = [ordered]@{}
            evidence = @('manual review required'); command_classes = @()
        }
        return (($o | ConvertTo-Json -Depth 8 -Compress))
    }
    if ($null -eq $Evidence) {
        $Evidence = @()
        $Evidence += ('passes:' + $ProfileStatus + ':' + [string]$ExitCode)
        $Evidence += ('criterion:0:' + $CriterionWord)
        $Evidence += '1 profile(s) executed: passes'
    }
    if ($null -eq $Profiles) {
        $Profiles = @([ordered]@{ profile = 'passes'; status = $ProfileStatus; exit_code = $ExitCode })
    }
    $mw = $CriterionWord
    if ($null -ne $MapWord) { $mw = [string]$MapWord }
    $map = [ordered]@{}
    $map['0'] = [ordered]@{ profiles = @('passes'); status = $mw }
    $o = [ordered]@{
        ok = [bool]$Ok; task_id = 'fixture'; status = $Status; reason = ''
        scope = [ordered]@{ files = @('src/widget') }; profiles = $Profiles; criterion_map = $map
        evidence = $Evidence; command_classes = @('test')
    }
    return (($o | ConvertTo-Json -Depth 8 -Compress))
}

function New-RawSessionNode {
    param([string]$Session, [string]$Parent, [string]$Provider, [string]$ModelShort, [string]$Outcome = 'succeeded')
    return [ordered]@{
        id = $Session; parentID = $Parent; agent = 'coder'
        model = [ordered]@{ providerID = $Provider; id = $ModelShort }
        outcome = $Outcome; cost = 0.001
        tokens = [ordered]@{ input = 100; output = 20; reasoning = 5 }
    }
}

function New-RawMessage {
    param([string]$Id, [string]$Provider, [string]$ModelShort, [string]$Created, [string]$Completed, [string]$Agent = 'coder')
    return [ordered]@{
        id = $Id; type = 'assistant'; agent = $Agent
        model = [ordered]@{ providerID = $Provider; id = $ModelShort }
        time = [ordered]@{ created = $Created; completed = $Completed }
        finish = 'stop'; cost = 0.001
        tokens = [ordered]@{ input = 100; output = 20; reasoning = 5 }
    }
}

function New-StaticSeam {
    param([string]$Session, [string]$Parent, [string]$Provider, [string]$ModelShort, [string]$Message)
    $cap = @{ session = $Session; parent = $Parent; provider = $Provider; model = $ModelShort; message = $Message }
    return ({
        param([string]$ChildSid)
        $sn = New-RawSessionNode -Session $cap.session -Parent $cap.parent -Provider $cap.provider -ModelShort $cap.model
        $mm = New-RawMessage -Id $cap.message -Provider $cap.provider -ModelShort $cap.model -Created '1000' -Completed '2000'
        return @{ session = $sn; messages = @($mm) }
    }).GetNewClosure()
}

function New-TerraSeam {
    param([string]$Session, [string]$Parent, [string]$Message)
    return (New-StaticSeam -Session $Session -Parent $Parent -Provider 'openai' -ModelShort 'gpt-6.1-terra' -Message $Message)
}

function New-SolSeam {
    param([string]$Session, [string]$Parent, [string]$Message)
    return (New-StaticSeam -Session $Session -Parent $Parent -Provider 'openai' -ModelShort 'gpt-6.1-sol' -Message $Message)
}

function New-GrowingSeam {
    param([string]$Session, [string]$Parent, [string]$Provider, [string]$ModelShort, [string[]]$Messages)
    $state = @{ n = 0 }
    $cap = @{ session = $Session; parent = $Parent; provider = $Provider; model = $ModelShort; messages = @($Messages) }
    return ({
        param([string]$ChildSid)
        $state.n++
        $k = [Math]::Min($state.n, $cap.messages.Count)
        $msgs = @()
        for ($i = 0; $i -lt $k; $i++) {
            $tt = (1000 + ($i * 100))
            $msgs += (New-RawMessage -Id $cap.messages[$i] -Provider $cap.provider -ModelShort $cap.model -Created ([string]$tt) -Completed ([string]($tt + 10)))
        }
        $sn = New-RawSessionNode -Session $cap.session -Parent $cap.parent -Provider $cap.provider -ModelShort $cap.model
        return @{ session = $sn; messages = $msgs }
    }).GetNewClosure()
}

function Get-TaskRevNow {
    param($T, [string]$Id)
    return ([int](Get-OrchestrationTask -TaskId $Id -TasksDir $T.tasks)['revision'])
}

function New-ModelProofTask {
    param($T, $PolPath, [string]$Id, [int]$Budget = 3, [string]$BaseRevision = '', [string[]]$WriteScopes = @('src/widget'), [string[]]$VerProfiles = @())
    return (New-OrchestrationTask -TaskId $Id -Objective 'Fix the widget renderer' -TaskType 'implementation' `
        -Risk 'low' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -RuntimeVersion '1.18.32' -BaseRevision $BaseRevision -ReadScopes @('src/widget') -WriteScopes $WriteScopes `
        -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('widget renders') -ExpectedArtifacts @('src/widget/render.js') `
        -VerificationProfiles $VerProfiles `
        -AttemptBudget $Budget -TasksDir $T.tasks -FlagsPath $T.flags -TelemetryRoot $T.root)
}

function Invoke-ProofBindFlow {
    param($T, [string]$Id, [string]$Run, [string]$Root, [string]$Child, [int]$Rev)
    $b1 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $Id -RunId $Run -SessionId $Root -ExpectedRevision $Rev -TasksDir $T.tasks -FlagsPath $T.flags
    $b2 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId $Id -RunId $Run -SessionId $Root -ExpectedRevision ([int]$b1.revision) -TasksDir $T.tasks -FlagsPath $T.flags
    $b3 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $Id -RunId $Run -SessionId $Child -WorkerSession -ExpectedRevision ([int]$b2.revision) -TasksDir $T.tasks -FlagsPath $T.flags
    return $b3
}

function Invoke-ProofFailResult {
    param($T, [string]$Id, [int]$Rev, [string]$Evidence = 'criterion:0:widget still broken', [string]$WorkerStatus = 'failed', [string]$Approach = 'narrow retry', [string]$Tool = 'src/widget/render.js', [string]$SessionRef = '', [string[]]$MessageRefs = @())
    $claimed = @($Evidence)
    if (-not [string]::IsNullOrWhiteSpace($SessionRef)) { $claimed += ('session:' + $SessionRef) }
    foreach ($mr in @($MessageRefs)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$mr)) { $claimed += ('message:' + [string]$mr) }
    }
    $wArgs = @{
        TaskId = $Id; Status = $WorkerStatus; ClaimedEvidence = $claimed; ProducedBy = 'coder'
        ExpectedRevision = $Rev; TasksDir = $T.tasks; FlagsPath = $T.flags; TelemetryRoot = $T.root
    }
    if ($WorkerStatus -ceq 'failed') {
        $wArgs['StrategyApproach'] = $Approach
        $wArgs['StrategyTool'] = $Tool
        $wArgs['StrategyParams'] = @('isolate', 'render')
    }
    return (Set-OrchestrationTaskWorkerResult @wArgs)
}

function Invoke-ProofVerifyRun {
    param($T, [string]$Id, [int]$Rev, [string]$PolPath = '')
    $vrArgs = @{
        TaskId = $Id; ExpectedRevision = $Rev
        TasksDir = $T.tasks; FlagsPath = $T.flags; RepoRoot = $T.repo
    }
    if (-not [string]::IsNullOrWhiteSpace($PolPath)) { $vrArgs['VerificationPolicyPath'] = $PolPath }
    return (Invoke-TaskKernelVerifyRun @vrArgs)
}

function Get-ModelProofBytesHash {
    param([string]$Path)
    return (Get-TaskKernelStringHash -Text ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))))
}

function Get-ModelAttemptCountTolerant {
    param($Record)
    try {
        if (($null -ne $Record) -and ($Record -is [System.Collections.IDictionary]) -and $Record.Contains('model_attempts') -and ($null -ne $Record['model_attempts'])) {
            return ((@($Record['model_attempts'])).Count)
        }
    }
    catch { }
    return 0
}

$roots = New-Object System.Collections.ArrayList

try {
    Clear-TaskKernelSessionReader
    $polPath = Get-TaskKernelModelPolicyDefaultPath

    # 0. forged bool/string surface: no proof params or selectors exist
    $setParams = (Get-Command Set-OrchestrationTaskModelAttempt).Parameters
    $proofParams = (Get-Command Get-OrchestrationTaskModelFailureProof).Parameters
    $runParams = (Get-Command Invoke-TaskKernelVerifyRun).Parameters
    $setHasAll = ($setParams.ContainsKey('TaskId') -and $setParams.ContainsKey('ChildSessionId') -and $setParams.ContainsKey('ExpectedRevision'))
    $setHasNone = ((-not $setParams.ContainsKey('Passed')) -and (-not $setParams.ContainsKey('Proof')) -and (-not $setParams.ContainsKey('Receipt')) -and (-not $setParams.ContainsKey('VerifiedPass')) -and (-not $setParams.ContainsKey('Status')))
    Assert-ModelProof ($setHasAll -and $setHasNone) 'model-attempt exposes only TaskId/ChildSessionId/ExpectedRevision (no bool/receipt proof params)'
    $proofHasNone = ((-not $proofParams.ContainsKey('Receipt')) -and (-not $proofParams.ContainsKey('Proof')) -and (-not $proofParams.ContainsKey('Passed')) -and (-not $proofParams.ContainsKey('Evidence')) -and (-not $proofParams.ContainsKey('Status')) -and (-not $proofParams.ContainsKey('SessionId')))
    $proofHasAll = ($proofParams.ContainsKey('TaskId') -and $proofParams.ContainsKey('RequiredTier'))
    Assert-ModelProof ($proofHasAll -and $proofHasNone) 'model-proof exposes only TaskId/RequiredTier (no boolean/string proof params)'
    $runHasNone = ((-not $runParams.ContainsKey('VerifierProfiles')) -and (-not $runParams.ContainsKey('VerificationRepoRoot')) -and (-not $runParams.ContainsKey('VerifierResultJson')) -and (-not $runParams.ContainsKey('VerifierResultFile')) -and (-not $runParams.ContainsKey('VerificationSource')) -and (-not $runParams.ContainsKey('VerifierExecuted')) -and (-not $runParams.ContainsKey('Passed')) -and (-not $runParams.ContainsKey('Status')))
    $runHasAll = ($runParams.ContainsKey('TaskId') -and $runParams.ContainsKey('ExpectedRevision'))
    Assert-ModelProof ($runHasAll -and $runHasNone) 'verify-run takes no profiles/repo/result/source selectors (plan + root are task-bound)'
    $tryOverride = $false
    try {
        $null = Invoke-TaskKernelVerifyRun -TaskId 'x' -ExpectedRevision 1 -VerifierProfiles @('failer') -TasksDir 't' -FlagsPath 'f' -RepoRoot 'r'
    }
    catch { $tryOverride = $true }
    Assert-ModelProof ([bool]$tryOverride) 'no caller override of verification profiles exists at run time'

    # 1. forged caller JSON can never yield T3 proof
    $t = New-ModelProofTestRoot
    [void]$roots.Add($t.root)
    $fr = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-forged-001'
    $bfr = Invoke-ProofBindFlow -T $t -Id 'proof-forged-001' -Run 'run-fr' -Root 'ses_root_fr' -Child 'ses_child_fr' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-forged-001' -Rev ([int]$bfr.revision) -SessionRef 'ses_child_fr' -MessageRefs @('msg_fr_1')
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_fr' -Parent 'ses_root_fr' -Message 'msg_fr_1')
    $rfr = Set-OrchestrationTaskModelAttempt -TaskId 'proof-forged-001' -ChildSessionId 'ses_child_fr' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-forged-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rfr.ok) 'forged fixture attempt recorded'
    $vfr = Set-OrchestrationTaskVerification -TaskId 'proof-forged-001' -VerifierEvidenceJson (New-ProofVerifierJson -Status 'verification_failed') -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-forged-001') -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-ModelProof ([bool]$vfr.ok) 'forged caller JSON stored (readable, untrusted)'
    $gfr = Get-OrchestrationTask -TaskId 'proof-forged-001' -TasksDir $t.tasks
    Assert-ModelProof (([string]$gfr['verification']['verification_source'] -ceq 'caller-supplied') -and (-not [bool]$gfr['verification']['verifier_executed'])) 'caller verify persists explicit untrusted marks'
    $pfr = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-forged-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pfr.ok) -and ([string]$pfr.error -ceq 'PROOF_VERIFIER_UNTRUSTED'))) 'forged caller JSON cannot yield T3 proof'
    Clear-TaskKernelSessionReader

    # 2. committed plan is immutable: verify-run executes exactly the plan
    $rt = New-RepoTaskRoot -Name 'plan'
    [void]$roots.Add($rt.root)
    $pt = New-ModelProofTask -T $rt -PolPath $polPath -Id 'proof-plan-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $gpt = Get-OrchestrationTask -TaskId 'proof-plan-001' -TasksDir $rt.tasks
    Assert-ModelProof (((@($gpt['verification_profiles'])).Count -eq 1) -and ([string](@($gpt['verification_profiles'])[0]) -ceq 'failer')) 'creation commits the verification plan'
    $bpt = Invoke-ProofBindFlow -T $rt -Id 'proof-plan-001' -Run 'run-pt' -Root 'ses_root_pt' -Child 'ses_child_pt' -Rev 1
    $null = Invoke-ProofFailResult -T $rt -Id 'proof-plan-001' -Rev ([int]$bpt.revision) -SessionRef 'ses_child_pt' -MessageRefs @('msg_pt_1')
    $vpt = Invoke-ProofVerifyRun -T $rt -Id 'proof-plan-001' -Rev (Get-TaskRevNow -T $rt -Id 'proof-plan-001')
    Assert-ModelProof (([bool]$vpt.ok) -and ([string]$vpt.status -ceq 'verification_failed') -and ([string]$vpt.verification_source -ceq 'kernel-executed')) 'verify-run executes the committed plan (real verifier, kernel-executed marks)'
    $gpt2 = Get-OrchestrationTask -TaskId 'proof-plan-001' -TasksDir $rt.tasks
    $pev = @($gpt2['verification']['evidence'])
    $hasFailer = $false
    foreach ($e in $pev) { if ([string]$e -cmatch '^failer:') { $hasFailer = $true; break } }
    Assert-ModelProof ([bool]$hasFailer) 'executed evidence carries the planned profile identity'
    Assert-ModelProof (((@($gpt2['verification_profiles'])).Count -eq 1) -and ([string](@($gpt2['verification_profiles'])[0]) -ceq 'failer')) 'plan immutable across verify-run'

    # 3. creation rejects malformed plans with zero mutation
    $badPlans = @(@(''), @('failer', 'failer'), @('FAILER', 'failer'), @('x' * 129), @('bad profile!'))
    $badIdx = 0
    foreach ($bp in $badPlans) {
        $badIdx++
        $bid = ('proof-badplan-' + [string]$badIdx)
        $br = New-OrchestrationTask -TaskId $bid -Objective 'Fix the widget renderer' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -VerificationProfiles @($bp) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
        $bj = Join-Path $t.tasks ($bid + '.json')
        Assert-ModelProof (((-not [bool]$br.ok) -and ([string]$br.error -ceq 'INVALID_VERIFICATION_PROFILES') -and (-not (Test-Path -LiteralPath $bj)))) 'malformed plan rejected with zero mutation'
    }
    $many = @()
    for ($i = 0; $i -lt 17; $i++) { $many += ('p' + [string]$i) }
    $bmany = New-OrchestrationTask -TaskId 'proof-badplan-many' -Objective 'Fix the widget renderer' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -VerificationProfiles $many -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-ModelProof (((-not [bool]$bmany.ok) -and ([string]$bmany.error -ceq 'INVALID_VERIFICATION_PROFILES'))) 'oversized plan rejected'

    # 4. task without committed plan cannot trusted-verify (incl. legacy shape)
    $np = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-noplan-001' -BaseRevision 'HEAD' -WriteScopes @()
    $null = Invoke-ProofBindFlow -T $t -Id 'proof-noplan-001' -Run 'run-np' -Root 'ses_root_np' -Child 'ses_child_np' -Rev 1
    $npr = Invoke-TaskKernelVerifyRun -TaskId 'proof-noplan-001' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-noplan-001') -TasksDir $t.tasks -FlagsPath $t.flags -RepoRoot $t.repo
    Assert-ModelProof (((-not [bool]$npr.ok) -and ([string]$npr.error -ceq 'VERIFIER_PLAN_MISSING'))) 'missing plan fails closed'
    $npDoc = ([IO.File]::ReadAllText((Join-Path $t.tasks 'proof-noplan-001.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $npRec = ConvertTo-TaskKernelOrdered -Node $npDoc
    $npRec.Remove('verification_profiles')
    $npw = Write-TaskKernelRecord -Record $npRec -TaskFile (Join-Path $t.tasks 'proof-noplan-001.json')
    Assert-ModelProof ([bool]$npw.ok) 'legacy shape fixture written (no plan key)'
    $npr2 = Invoke-TaskKernelVerifyRun -TaskId 'proof-noplan-001' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-noplan-001') -TasksDir $t.tasks -FlagsPath $t.flags
    Assert-ModelProof (((-not [bool]$npr2.ok) -and ([string]$npr2.error -ceq 'VERIFIER_PLAN_MISSING'))) 'legacy record without plan cannot trusted-verify'

    # 5. unknown profile in committed plan fails with zero mutation
    $ru = New-RepoTaskRoot -Name 'unk'
    [void]$roots.Add($ru.root)
    $uu = New-ModelProofTask -T $ru -PolPath $polPath -Id 'proof-unkprof-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('no-such-profile')
    $null = Invoke-ProofBindFlow -T $ru -Id 'proof-unkprof-001' -Run 'run-uu' -Root 'ses_root_uu' -Child 'ses_child_uu' -Rev 1
    $null = Invoke-ProofFailResult -T $ru -Id 'proof-unkprof-001' -Rev (Get-TaskRevNow -T $ru -Id 'proof-unkprof-001') -SessionRef 'ses_child_uu' -MessageRefs @('msg_uu_1')
    $fuu = Join-Path $ru.tasks 'proof-unkprof-001.json'
    $beforeUu = Get-ModelProofBytesHash -Path $fuu
    $uvu = Invoke-ProofVerifyRun -T $ru -Id 'proof-unkprof-001' -Rev (Get-TaskRevNow -T $ru -Id 'proof-unkprof-001')
    $afterUu = Get-ModelProofBytesHash -Path $fuu
    Assert-ModelProof (((-not [bool]$uvu.ok) -and ([string]$uvu.error -ceq 'UNKNOWN_VERIFIER_PROFILE') -and ($beforeUu -ceq $afterUu))) 'unknown profile fails with zero mutation'

    # 6. unrelated policy tree cannot produce trusted marks
    $ro = New-RepoTaskRoot -Name 'out'
    [void]$roots.Add($ro.root)
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('vkr-outside-' + [guid]::NewGuid().ToString('N') + '.json')
    [void]$roots.Add($outside)
    Write-ModelProofFixture -Path $outside -Text '{"version":1,"default_timeout_seconds":60,"max_output_chars":4000,"profiles":{"failer":{"class":"test","command":"powershell -NoProfile -Command exit 1","timeout_seconds":30}}}'
    $ou = New-ModelProofTask -T $ro -PolPath $polPath -Id 'proof-outpol-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $null = Invoke-ProofBindFlow -T $ro -Id 'proof-outpol-001' -Run 'run-oo' -Root 'ses_root_oo' -Child 'ses_child_oo' -Rev 1
    $ovo = Invoke-TaskKernelVerifyRun -TaskId 'proof-outpol-001' -ExpectedRevision (Get-TaskRevNow -T $ro -Id 'proof-outpol-001') -VerificationPolicyPath $outside -TasksDir $ro.tasks -FlagsPath $ro.flags -RepoRoot $ro.repo
    Assert-ModelProof (((-not [bool]$ovo.ok) -and ([string]$ovo.error -ceq 'VERIFICATION_POLICY_OUT_OF_ROOT'))) 'unrelated policy tree cannot produce trusted marks'
    $rm = New-RepoTaskRoot -Name 'mis'
    [void]$roots.Add($rm.root)
    $mu = New-ModelProofTask -T $rm -PolPath $polPath -Id 'proof-mispol-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $null = Invoke-ProofBindFlow -T $rm -Id 'proof-mispol-001' -Run 'run-mm' -Root 'ses_root_mm' -Child 'ses_child_mm' -Rev 1
    $mvu = Invoke-TaskKernelVerifyRun -TaskId 'proof-mispol-001' -ExpectedRevision (Get-TaskRevNow -T $rm -Id 'proof-mispol-001') -TasksDir $rm.tasks -FlagsPath $rm.flags -RepoRoot $rm.repo
    Assert-ModelProof ([bool]$mvu.ok) 'in-root canonical policy verifies (control)'

    # 7. verify-run guards: non-git repo, missing policy, empty criteria, CAS, terminal
    $ng = Join-Path ([IO.Path]::GetTempPath()) ('vkr-nogit-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ng -Force | Out-Null
    [void]$roots.Add($ng)
    Write-ModelProofFixture -Path (Join-Path $ng 'flags.json') -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    New-Item -ItemType Directory -Path (Join-Path $ng 'tasks') -Force | Out-Null
    $ngt = @{ root = $ng; tasks = (Join-Path $ng 'tasks'); flags = (Join-Path $ng 'flags.json') }
    $ngp = Join-Path $ng 'source\registry\verification-policy.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $ngp) -Force | Out-Null
    Write-ModelProofFixture -Path $ngp -Text (Get-Content -LiteralPath (Join-Path $rt.repo 'source\registry\verification-policy.json') -Raw -Encoding UTF8)
    $ngu = New-ModelProofTask -T $ngt -PolPath $polPath -Id 'proof-nongit-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $null = Invoke-ProofBindFlow -T $ngt -Id 'proof-nongit-001' -Run 'run-ng' -Root 'ses_root_ng' -Child 'ses_child_ng' -Rev 1
    $ngv = Invoke-TaskKernelVerifyRun -TaskId 'proof-nongit-001' -ExpectedRevision (Get-TaskRevNow -T $ngt -Id 'proof-nongit-001') -TasksDir $ngt.tasks -FlagsPath $ngt.flags -RepoRoot $ng
    Assert-ModelProof (((-not [bool]$ngv.ok) -and ([string]$ngv.error -ceq 'VERIFY_RUN_NOT_EXECUTED'))) 'non-git repo fails closed without write'
    $mp = New-RepoTaskRoot -Name 'mis2'
    [void]$roots.Add($mp.root)
    Remove-Item -LiteralPath (Join-Path $mp.repo 'source\registry\verification-policy.json') -Force
    $mpu = New-ModelProofTask -T $mp -PolPath $polPath -Id 'proof-mispol2-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $null = Invoke-ProofBindFlow -T $mp -Id 'proof-mispol2-001' -Run 'run-m2' -Root 'ses_root_m2' -Child 'ses_child_m2' -Rev 1
    $mpv = Invoke-TaskKernelVerifyRun -TaskId 'proof-mispol2-001' -ExpectedRevision (Get-TaskRevNow -T $mp -Id 'proof-mispol2-001') -TasksDir $mp.tasks -FlagsPath $mp.flags -RepoRoot $mp.repo
    Assert-ModelProof (((-not [bool]$mpv.ok) -and ([string]$mpv.error -ceq 'VERIFICATION_POLICY_NOT_FOUND'))) 'missing canonical policy fails closed'
    $nc = New-RepoTaskRoot -Name 'ncrit'
    [void]$roots.Add($nc.root)
    $ncu = New-ModelProofTask -T $nc -PolPath $polPath -Id 'proof-nocrit-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $ncrec = Get-OrchestrationTask -TaskId 'proof-nocrit-001' -TasksDir $nc.tasks
    $ncrec['acceptance_criteria'] = @()
    $ncj = Join-Path $nc.tasks 'proof-nocrit-001.json'
    $ncjson = ($ncrec | ConvertTo-Json -Depth 12)
    Write-ModelProofFixture -Path $ncj -Text $ncjson
    $ncv = Invoke-TaskKernelVerifyRun -TaskId 'proof-nocrit-001' -ExpectedRevision (Get-TaskRevNow -T $nc -Id 'proof-nocrit-001') -TasksDir $nc.tasks -FlagsPath $nc.flags -RepoRoot $nc.repo
    Assert-ModelProof (((-not [bool]$ncv.ok) -and ([string]$ncv.error -ceq 'INVALID_CRITERIA'))) 'empty acceptance criteria fails closed'
    $sv = Invoke-TaskKernelVerifyRun -TaskId 'proof-plan-001' -ExpectedRevision 1 -TasksDir $rt.tasks -FlagsPath $rt.flags -RepoRoot $rt.repo
    Assert-ModelProof (((-not [bool]$sv.ok) -and ([string]$sv.error -ceq 'CAS_CONFLICT'))) 'stale revision fails closed before execution'
    $tc = New-RepoTaskRoot -Name 'term'
    [void]$roots.Add($tc.root)
    $tcu = New-ModelProofTask -T $tc -PolPath $polPath -Id 'proof-term-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $null = Invoke-ProofBindFlow -T $tc -Id 'proof-term-001' -Run 'run-vt' -Root 'ses_root_vt' -Child 'ses_child_vt' -Rev 1
    $null = Cancel-OrchestrationTask -TaskId 'proof-term-001' -Actor 'planner' -ExpectedRevision 4 -Reason 'done' -TasksDir $tc.tasks -FlagsPath $tc.flags
    $tvr = Invoke-TaskKernelVerifyRun -TaskId 'proof-term-001' -ExpectedRevision (Get-TaskRevNow -T $tc -Id 'proof-term-001') -TasksDir $tc.tasks -FlagsPath $tc.flags -RepoRoot $tc.repo
    Assert-ModelProof (((-not [bool]$tvr.ok) -and ([string]$tvr.error -ceq 'ILLEGAL_TRANSITION'))) 'verify-run on terminal task refused'

    # 8. status trio via caller path stays untrusted but readable
    $m = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-status-002'
    $bm = Invoke-ProofBindFlow -T $t -Id 'proof-status-002' -Run 'run-s2' -Root 'ses_root_s2' -Child 'ses_child_s2' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-status-002' -Rev ([int]$bm.revision) -Status 'manual' -Evidence 'criterion:0:needs human eyes'
    $vmArgs = @{ TaskId = 'proof-status-002'; VerifierEvidenceJson = (New-ProofVerifierJson -Status 'manual_verification_required'); ExpectedRevision = (Get-TaskRevNow -T $t -Id 'proof-status-002'); TasksDir = $t.tasks; FlagsPath = $t.flags }
    $fvm = Set-OrchestrationTaskVerification @vmArgs
    $gm = Get-OrchestrationTask -TaskId 'proof-status-002' -TasksDir $t.tasks
    Assert-ModelProof (([bool]$fvm.ok) -and (-not [bool]$gm['verification']['passed']) -and ([string]$gm['verification']['status'] -ceq 'manual_verification_required') -and ([string]$gm['verification']['verification_source'] -ceq 'caller-supplied')) 'manual_verification_required persists caller-supplied marks'
    $p = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-status-003'
    $bp = Invoke-ProofBindFlow -T $t -Id 'proof-status-003' -Run 'run-s3' -Root 'ses_root_s3' -Child 'ses_child_s3' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-status-003' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:widget renders now') -ProducedBy 'coder' -ExpectedRevision ([int]$bp.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $vp = Set-OrchestrationTaskVerification -TaskId 'proof-status-003' -VerifierEvidenceJson (New-ProofVerifierJson -Status 'verified_pass' -CriterionWord 'verified' -ProfileStatus 'verified' -ExitCode 0) -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-status-003') -TasksDir $t.tasks -FlagsPath $t.flags
    $gp = Get-OrchestrationTask -TaskId 'proof-status-003' -TasksDir $t.tasks
    Assert-ModelProof (([bool]$vp.ok) -and ([bool]$gp['verification']['passed']) -and ([string]$gp['verification']['source'] -ceq 'caller-supplied')) 'verified_pass via caller path stays caller-supplied'

    # 9. trusted verification without recorded model attempts fails closed
    $np = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-plan-001' -RequiredTier 'T3' -TasksDir $rt.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$np.ok) -and ([string]$np.error -ceq 'PROOF_NO_MODEL_ATTEMPT'))) 'trusted verification without recorded model attempts fails closed'

    # 10. missing binding fails closed with zero bytes changed (and no runtime call)
    $ub = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-nobind-001'
    $fu2 = Join-Path $t.tasks 'proof-nobind-001.json'
    $beforeU2 = Get-ModelProofBytesHash -Path $fu2
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_orphan_1' -Parent 'ses_root_x' -Message 'msg_orphan_1')
    $ru = Set-OrchestrationTaskModelAttempt -TaskId 'proof-nobind-001' -ChildSessionId 'ses_orphan_1' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    $afterU2 = Get-ModelProofBytesHash -Path $fu2
    Assert-ModelProof (((-not [bool]$ru.ok) -and ([string]$ru.error -ceq 'MODEL_ATTEMPT_SESSION_NOT_BOUND') -and ($beforeU2 -ceq $afterU2))) 'unbound child session rejected with bytes unchanged'
    Clear-TaskKernelSessionReader
    $ru2 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-nobind-001' -ChildSessionId 'ses_orphan_1' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$ru2.ok) -and ([string]$ru2.error -ceq 'MODEL_ATTEMPT_SESSION_NOT_BOUND'))) 'unbound session fails before any runtime read (cleared seam, no CLI spawned)'

    # 11. candidate without refs cannot record: bound but unnamed
    $nn = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-unnamed-001'
    $bn = Invoke-ProofBindFlow -T $t -Id 'proof-unnamed-001' -Run 'run-n1' -Root 'ses_root_n1' -Child 'ses_child_n1' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-unnamed-001' -Rev ([int]$bn.revision)
    $fnj = Join-Path $t.tasks 'proof-unnamed-001.json'
    $beforeN = Get-ModelProofBytesHash -Path $fnj
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_n1' -Parent 'ses_root_n1' -Message 'msg_n1')
    $rn = Set-OrchestrationTaskModelAttempt -TaskId 'proof-unnamed-001' -ChildSessionId 'ses_child_n1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-unnamed-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    $afterN = Get-ModelProofBytesHash -Path $fnj
    Assert-ModelProof (((-not [bool]$rn.ok) -and ([string]$rn.error -ceq 'MODEL_ATTEMPT_SESSION_UNCORRELATED') -and ($beforeN -ceq $afterN))) 'bound child unnamed by failing candidate cannot record'

    # 12. message mismatch: candidate names msg_A, host returns msg_B
    $mm = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-msgmm-001'
    $bmm = Invoke-ProofBindFlow -T $t -Id 'proof-msgmm-001' -Run 'run-mm' -Root 'ses_root_mm2' -Child 'ses_child_mm2' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-msgmm-001' -Rev ([int]$bmm.revision) -SessionRef 'ses_child_mm2' -MessageRefs @('msg_named_a')
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_mm2' -Parent 'ses_root_mm2' -Message 'msg_other_b')
    $rmm = Set-OrchestrationTaskModelAttempt -TaskId 'proof-msgmm-001' -ChildSessionId 'ses_child_mm2' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-msgmm-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rmm.ok) -and ([string]$rmm.error -ceq 'MODEL_ATTEMPT_MESSAGE_MISMATCH'))) 'named message mismatch with host observation fails closed'
    Clear-TaskKernelSessionReader

    # 13. foreign parent fails closed
    $f = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-foreign-001'
    $bf = Invoke-ProofBindFlow -T $t -Id 'proof-foreign-001' -Run 'run-f1' -Root 'ses_root_f1' -Child 'ses_child_f1' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-foreign-001' -Rev ([int]$bf.revision) -SessionRef 'ses_child_f1' -MessageRefs @('msg_f1')
    $ff = Join-Path $t.tasks 'proof-foreign-001.json'
    $beforeF = Get-ModelProofBytesHash -Path $ff
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_f1' -Parent 'ses_foreign_parent' -Message 'msg_f1')
    $rf = Set-OrchestrationTaskModelAttempt -TaskId 'proof-foreign-001' -ChildSessionId 'ses_child_f1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-foreign-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    $afterF = Get-ModelProofBytesHash -Path $ff
    Assert-ModelProof (((-not [bool]$rf.ok) -and ([string]$rf.error -ceq 'SESSION_PARENT_MISMATCH') -and ($beforeF -ceq $afterF))) 'foreign parent session rejected with bytes unchanged'

    # 14. unknown model fails closed via canonical policy
    Set-TaskKernelSessionReader -Reader ({
        param([string]$ChildSid)
        $sn = New-RawSessionNode -Session 'ses_child_f1' -Parent 'ses_root_f1' -Provider 'openai' -ModelShort 'unknown-nope-1'
        $mm2 = New-RawMessage -Id 'msg_f1b' -Provider 'openai' -ModelShort 'unknown-nope-1' -Created '1000' -Completed '2000'
        return @{ session = $sn; messages = @($mm2) }
    })
    $rk = Set-OrchestrationTaskModelAttempt -TaskId 'proof-foreign-001' -ChildSessionId 'ses_child_f1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-foreign-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rk.ok) -and ([string]$rk.error -ceq 'MODEL_POLICY_UNKNOWN'))) 'unknown model identity fails closed via canonical policy'

    # 15. incomplete / ambiguous evidence rejected, no write
    Set-TaskKernelSessionReader -Reader ({
        param([string]$ChildSid)
        $sn = New-RawSessionNode -Session 'ses_child_f1' -Parent 'ses_root_f1' -Provider 'openai' -ModelShort 'gpt-6.1-terra'
        $mm2 = New-RawMessage -Id 'msg_f1c' -Provider 'openai' -ModelShort 'gpt-6.1-terra' -Created '1000' -Completed ''
        return @{ session = $sn; messages = @($mm2) }
    })
    $ri = Set-OrchestrationTaskModelAttempt -TaskId 'proof-foreign-001' -ChildSessionId 'ses_child_f1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-foreign-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$ri.ok) -and ([string]$ri.error -ceq 'SESSION_MESSAGE_NOT_COMPLETED'))) 'incomplete assistant message rejected'
    Set-TaskKernelSessionReader -Reader ({
        param([string]$ChildSid)
        $sn = New-RawSessionNode -Session 'ses_child_f1' -Parent 'ses_root_f1' -Provider 'openai' -ModelShort 'gpt-6.1-terra'
        $m1 = New-RawMessage -Id 'msg_f1a' -Provider 'openai' -ModelShort 'gpt-6.1-terra' -Created '1000' -Completed '2000'
        $m2 = New-RawMessage -Id 'msg_f1b' -Provider 'openai' -ModelShort 'gpt-6.1-sol' -Created '1500' -Completed '2500'
        return @{ session = $sn; messages = @($m1, $m2) }
    })
    $ra = Set-OrchestrationTaskModelAttempt -TaskId 'proof-foreign-001' -ChildSessionId 'ses_child_f1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-foreign-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$ra.ok) -and ([string]$ra.error -ceq 'SESSION_MESSAGE_AMBIGUOUS'))) 'ambiguous session evidence rejected'
    Set-TaskKernelSessionReader -Reader ({ param([string]$ChildSid) return @{ ok = $false; error = 'SESSION_READER_TIMEOUT' } })
    $rt = Set-OrchestrationTaskModelAttempt -TaskId 'proof-foreign-001' -ChildSessionId 'ses_child_f1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-foreign-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rt.ok) -and ([string]$rt.error -ceq 'SESSION_READER_TIMEOUT'))) 'reader timeout fails closed without write'
    $afterF2 = Get-ModelProofBytesHash -Path $ff
    Assert-ModelProof (($beforeF -ceq $afterF2)) 'all evidence rejections leave bytes unchanged'
    Clear-TaskKernelSessionReader

    # 16. budgets: per-candidate retry cap, duplicate, task-total cap
    $q = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-cap-001' -Budget 10
    $bq = Invoke-ProofBindFlow -T $t -Id 'proof-cap-001' -Run 'run-q1' -Root 'ses_root_q1' -Child 'ses_child_q1' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-cap-001' -Rev ([int]$bq.revision) -WorkerStatus 'candidate_pass' -SessionRef 'ses_child_q1' -MessageRefs @('msg_q1', 'msg_q2', 'msg_q3')
    Set-TaskKernelSessionReader -Reader (New-GrowingSeam -Session 'ses_child_q1' -Parent 'ses_root_q1' -Provider 'openai' -ModelShort 'gpt-6.1-terra' -Messages @('msg_q1', 'msg_q2', 'msg_q3'))
    $rq1 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-cap-001' -ChildSessionId 'ses_child_q1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-cap-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rq1.ok) 'first model attempt within per-candidate budget recorded'
    $rq2 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-cap-001' -ChildSessionId 'ses_child_q1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-cap-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rq2.ok) 'second model attempt within per-candidate budget recorded'
    $rq3 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-cap-001' -ChildSessionId 'ses_child_q1' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-cap-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rq3.ok) -and ([string]$rq3.error -ceq 'MODEL_ATTEMPT_BUDGET_EXHAUSTED'))) 'third observation of same candidate rejected (per-candidate cap)'
    $qd = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-dup-001' -Budget 10
    $bqd = Invoke-ProofBindFlow -T $t -Id 'proof-dup-001' -Run 'run-qd' -Root 'ses_root_qd' -Child 'ses_child_qd' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-dup-001' -Rev ([int]$bqd.revision) -WorkerStatus 'candidate_pass' -SessionRef 'ses_child_qd' -MessageRefs @('msg_qd_1')
    Set-TaskKernelSessionReader -Reader (New-StaticSeam -Session 'ses_child_qd' -Parent 'ses_root_qd' -Provider 'openai' -ModelShort 'gpt-6.1-terra' -Message 'msg_qd_1')
    $rqd1 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-dup-001' -ChildSessionId 'ses_child_qd' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-dup-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rqd1.ok) 'duplicate fixture first record ok'
    $rqd2 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-dup-001' -ChildSessionId 'ses_child_qd' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-dup-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rqd2.ok) -and ([string]$rqd2.error -ceq 'MODEL_ATTEMPT_DUPLICATE'))) 'exact duplicate record rejected'
    $gqd = Get-OrchestrationTask -TaskId 'proof-dup-001' -TasksDir $t.tasks
    Assert-ModelProof ((Get-ModelAttemptCountTolerant -Record $gqd) -eq 1) 'duplicate rejection preserves single persisted node'
    Clear-TaskKernelSessionReader

    # 17. CAS conflict on stale revision
    $rq5 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-cap-001' -ChildSessionId 'ses_child_q1' -ExpectedRevision 1 -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$rq5.ok) -and ([string]$rq5.error -ceq 'CAS_CONFLICT'))) 'stale revision rejected with CAS_CONFLICT'

    # 18. positive T3 path via plan-bound verify-run: exact refs, digest stable
    $s3 = New-RepoTaskRoot -Name 'vr3'
    [void]$roots.Add($s3.root)
    $s = New-ModelProofTask -T $s3 -PolPath $polPath -Id 'proof-t3-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bs = Invoke-ProofBindFlow -T $s3 -Id 'proof-t3-001' -Run 'run-t3a' -Root 'ses_root_t3a' -Child 'ses_child_t3a' -Rev 1
    $null = Invoke-ProofFailResult -T $s3 -Id 'proof-t3-001' -Rev ([int]$bs.revision) -SessionRef 'ses_child_t3a' -MessageRefs @('msg_t3a_1')
    $vvs = Invoke-ProofVerifyRun -T $s3 -Id 'proof-t3-001' -Rev (Get-TaskRevNow -T $s3 -Id 'proof-t3-001')
    Assert-ModelProof ([bool]$vvs.ok) 'verify-run executes planned failing profile'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_t3a' -Parent 'ses_root_t3a' -Message 'msg_t3a_1')
    $rs = Set-OrchestrationTaskModelAttempt -TaskId 'proof-t3-001' -ChildSessionId 'ses_child_t3a' -ExpectedRevision (Get-TaskRevNow -T $s3 -Id 'proof-t3-001') -TasksDir $s3.tasks -FlagsPath $s3.flags -PolicyPath $polPath
    $envOk = (([bool]$rs.ok) -and ([string]$rs.model -ceq 'openai/gpt-6.1-terra') -and ([string]$rs.provider -ceq 'openai') `
        -and ([string]$rs.tier -ceq 'T3') -and ([string]$rs.session_id -ceq 'ses_child_t3a') `
        -and ([string]$rs.parent_session_id -ceq 'ses_root_t3a') -and ([string]$rs.message_id -ceq 'msg_t3a_1') `
        -and ([string]$rs.policy_hash -cmatch '^[0-9a-f]{64}$') -and ([int]$rs.worker_revision -gt 0))
    Assert-ModelProof $envOk 'model attempt persists exact refs + policy hash (no dispatch)'
    $ps1 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-t3-001' -RequiredTier 'T3' -TasksDir $s3.tasks -PolicyPath $polPath
    $proofOk = (([bool]$ps1.ok) -and ([string]$ps1.model -ceq 'openai/gpt-6.1-terra') -and ([string]$ps1.tier -ceq 'T3') `
        -and ([string]$ps1.session_id -ceq 'ses_child_t3a') -and ([string]$ps1.message_id -ceq 'msg_t3a_1') `
        -and ([string]$ps1.reference -cmatch '^modelproof:proof-t3-001:T3:1:[0-9]+$') -and ([string]$ps1.digest -cmatch '^sha256:[0-9a-f]{64}$'))
    Assert-ModelProof $proofOk 'T3 failure proof returns persisted reference/digest'
    . $libPath
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_t3a' -Parent 'ses_root_t3a' -Message 'msg_t3a_1')
    $ps2 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-t3-001' -RequiredTier 'T3' -TasksDir $s3.tasks -PolicyPath $polPath
    Assert-ModelProof (([bool]$ps2.ok) -and ([string]$ps2.digest -ceq [string]$ps1.digest)) 'proof digest stable across re-read (restart-safe persisted refs)'
    Clear-TaskKernelSessionReader

    # 19. candidate_pass + kernel-executed verifier failure proves non-resolution
    $s4 = New-RepoTaskRoot -Name 'vr4'
    [void]$roots.Add($s4.root)
    $cp = New-ModelProofTask -T $s4 -PolPath $polPath -Id 'proof-candpass-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bcp = Invoke-ProofBindFlow -T $s4 -Id 'proof-candpass-001' -Run 'run-cp' -Root 'ses_root_cp' -Child 'ses_child_cp' -Rev 1
    $null = Invoke-ProofFailResult -T $s4 -Id 'proof-candpass-001' -Rev ([int]$bcp.revision) -WorkerStatus 'candidate_pass' -SessionRef 'ses_child_cp' -MessageRefs @('msg_cp_1') -Evidence 'criterion:0:widget renders (claimed)'
    $vcp = Invoke-ProofVerifyRun -T $s4 -Id 'proof-candpass-001' -Rev (Get-TaskRevNow -T $s4 -Id 'proof-candpass-001')
    Assert-ModelProof ([bool]$vcp.ok) 'candidate_pass verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_cp' -Parent 'ses_root_cp' -Message 'msg_cp_1')
    $rcp = Set-OrchestrationTaskModelAttempt -TaskId 'proof-candpass-001' -ChildSessionId 'ses_child_cp' -ExpectedRevision (Get-TaskRevNow -T $s4 -Id 'proof-candpass-001') -TasksDir $s4.tasks -FlagsPath $s4.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rcp.ok) 'candidate_pass observation recorded'
    $gcp = Get-OrchestrationTask -TaskId 'proof-candpass-001' -TasksDir $s4.tasks
    Assert-ModelProof ((Get-ModelAttemptCountTolerant -Record $gcp) -eq 1) 'candidate_pass path records observation'
    $pcp = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-candpass-001' -RequiredTier 'T3' -TasksDir $s4.tasks -PolicyPath $polPath
    Assert-ModelProof (([bool]$pcp.ok) -and ([string]$pcp.model -ceq 'openai/gpt-6.1-terra')) 'candidate_pass + verifier failure proves non-resolution'
    Clear-TaskKernelSessionReader

    # 20. fabricated session record cannot create proof
    $fj = Join-Path $s3.tasks 'proof-t3-001.json'
    $fdoc = ([IO.File]::ReadAllText($fj, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $frec = ConvertTo-TaskKernelOrdered -Node $fdoc
    $falist = @($frec['model_attempts'])
    $falist[0]['session_id'] = 'ses_forged_1'
    $frec['model_attempts'] = $falist
    $fw = Write-TaskKernelRecord -Record $frec -TaskFile $fj
    Assert-ModelProof ([bool]$fw.ok) 'fabricated fixture written (simulates out-of-kernel tamper)'
    $pf = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-t3-001' -RequiredTier 'T3' -TasksDir $s3.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pf.ok) -and ([string]$pf.error -ceq 'PROOF_SESSION_UNBOUND'))) 'fabricated session record cannot return proof'

    # 21. record without verification fails closed
    $nv = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-nover-001'
    $bnv = Invoke-ProofBindFlow -T $t -Id 'proof-nover-001' -Run 'run-nv' -Root 'ses_root_nv' -Child 'ses_child_nv' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-nover-001' -Status 'failed' -ClaimedEvidence @('criterion:0:broke', 'session:ses_child_nv', 'message:msg_nv_1') -ProducedBy 'coder' -ExpectedRevision ([int]$bnv.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $pnv = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-nover-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pnv.ok) -and ([string]$pnv.error -ceq 'PROOF_VERIFICATION_MISSING'))) 'record without verification fails closed'

    # 22. pre-slice shape with legacy source claim is untrusted (digest is not signature)
    $og = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-oldshape-001'
    $bog = Invoke-ProofBindFlow -T $t -Id 'proof-oldshape-001' -Run 'run-os' -Root 'ses_root_os' -Child 'ses_child_os' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-oldshape-001' -Rev ([int]$bog.revision) -SessionRef 'ses_child_os' -MessageRefs @('msg_os_1')
    $null = Set-OrchestrationTaskVerification -TaskId 'proof-oldshape-001' -VerifierEvidenceJson (New-ProofVerifierJson -Status 'verification_failed') -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-oldshape-001') -TasksDir $t.tasks -FlagsPath $t.flags
    $ogj = Join-Path $t.tasks 'proof-oldshape-001.json'
    $ogdoc = ([IO.File]::ReadAllText($ogj, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $ogrec = ConvertTo-TaskKernelOrdered -Node $ogdoc
    $ogrec['verification']['source'] = 'orchestration-verifier'
    $ogrec['verification']['verifier_ok'] = $true
    $ogrec['verification'].Remove('verification_source')
    $ogrec['verification'].Remove('verifier_executed')
    $ogw = Write-TaskKernelRecord -Record $ogrec -TaskFile $ogj
    Assert-ModelProof ([bool]$ogw.ok) 'pre-slice shape fixture written (legacy source claim)'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_os' -Parent 'ses_root_os' -Message 'msg_os_1')
    $rog = Set-OrchestrationTaskModelAttempt -TaskId 'proof-oldshape-001' -ChildSessionId 'ses_child_os' -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-oldshape-001') -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rog.ok) 'old-shape fixture attempt recorded'
    $pog = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-oldshape-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pog.ok) -and ([string]$pog.error -ceq 'PROOF_VERIFIER_UNTRUSTED'))) 'legacy orchestration-verifier marks never trusted (digest is not signature)'
    Clear-TaskKernelSessionReader

    # 23. stale candidate revision fails closed
    $s5 = New-RepoTaskRoot -Name 'vr5'
    [void]$roots.Add($s5.root)
    $st = New-ModelProofTask -T $s5 -PolPath $polPath -Id 'proof-stale-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bst = Invoke-ProofBindFlow -T $s5 -Id 'proof-stale-001' -Run 'run-st' -Root 'ses_root_st' -Child 'ses_child_st' -Rev 1
    $null = Invoke-ProofFailResult -T $s5 -Id 'proof-stale-001' -Rev ([int]$bst.revision) -SessionRef 'ses_child_st' -MessageRefs @('msg_st_1')
    $null = Invoke-ProofVerifyRun -T $s5 -Id 'proof-stale-001' -Rev (Get-TaskRevNow -T $s5 -Id 'proof-stale-001')
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_st' -Parent 'ses_root_st' -Message 'msg_st_1')
    $rst = Set-OrchestrationTaskModelAttempt -TaskId 'proof-stale-001' -ChildSessionId 'ses_child_st' -ExpectedRevision (Get-TaskRevNow -T $s5 -Id 'proof-stale-001') -TasksDir $s5.tasks -FlagsPath $s5.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rst.ok) 'stale fixture attempt ok'
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-stale-001' -Status 'failed' -ClaimedEvidence @('criterion:0:second failure', 'session:ses_child_st', 'message:msg_st_2') -ProducedBy 'coder' -ExpectedRevision ([int]$rst.revision) -Hypothesis 'another angle' -DebuggerInvoked -NewEvidence -TasksDir $s5.tasks -FlagsPath $s5.flags -TelemetryRoot $s5.root
    $pst = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-stale-001' -RequiredTier 'T3' -TasksDir $s5.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pst.ok) -and ([string]$pst.error -ceq 'PROOF_CANDIDATE_STALE'))) 'superseded candidate revision fails closed'
    Clear-TaskKernelSessionReader

    # 24. legacy record (no status, no model_attempts, no history, no plan) stays readable, proof fails closed
    $lg = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-legacy-001'
    $blg = Invoke-ProofBindFlow -T $t -Id 'proof-legacy-001' -Run 'run-lg' -Root 'ses_root_lg' -Child 'ses_child_lg' -Rev 1
    $null = Invoke-ProofFailResult -T $t -Id 'proof-legacy-001' -Rev ([int]$blg.revision) -SessionRef 'ses_child_lg' -MessageRefs @('msg_lg_1')
    $null = Set-OrchestrationTaskVerification -TaskId 'proof-legacy-001' -VerifierEvidenceJson (New-ProofVerifierJson -Status 'verification_failed') -ExpectedRevision (Get-TaskRevNow -T $t -Id 'proof-legacy-001') -TasksDir $t.tasks -FlagsPath $t.flags
    $lgj = Join-Path $t.tasks 'proof-legacy-001.json'
    $lgdoc = ([IO.File]::ReadAllText($lgj, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $lgrec = ConvertTo-TaskKernelOrdered -Node $lgdoc
    $lgrec.Remove('model_attempts')
    $lgrec.Remove('verification_history')
    $lgrec.Remove('verification_profiles')
    $lgver = $lgrec['verification']
    $lgver.Remove('status')
    $lgw = Write-TaskKernelRecord -Record $lgrec -TaskFile $lgj
    Assert-ModelProof ([bool]$lgw.ok) 'legacy fixture written (status/model_attempts/history/plan stripped)'
    $glg = Get-OrchestrationTask -TaskId 'proof-legacy-001' -TasksDir $t.tasks
    Assert-ModelProof (([string]$glg['state'] -ceq 'DISCOVERING') -and ((@($glg['attempts'])).Count -eq 1)) 'legacy record remains readable with attempts intact'
    $plg = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-legacy-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$plg.ok) -and ([string]$plg.error -ceq 'LEGACY_VERIFICATION_UNKNOWN'))) 'legacy record without status fails closed as unknown'

    # 25. transport/downgrade model never satisfies a T3 proof
    $s6 = New-RepoTaskRoot -Name 'vr6'
    [void]$roots.Add($s6.root)
    $dg = New-ModelProofTask -T $s6 -PolPath $polPath -Id 'proof-downgrade-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bdg = Invoke-ProofBindFlow -T $s6 -Id 'proof-downgrade-001' -Run 'run-dg' -Root 'ses_root_dg' -Child 'ses_child_dg' -Rev 1
    $null = Invoke-ProofFailResult -T $s6 -Id 'proof-downgrade-001' -Rev ([int]$bdg.revision) -SessionRef 'ses_child_dg' -MessageRefs @('msg_dg_1')
    $null = Invoke-ProofVerifyRun -T $s6 -Id 'proof-downgrade-001' -Rev (Get-TaskRevNow -T $s6 -Id 'proof-downgrade-001')
    Set-TaskKernelSessionReader -Reader ({
        param([string]$ChildSid)
        $sn = New-RawSessionNode -Session 'ses_child_dg' -Parent 'ses_root_dg' -Provider 'opencode-go' -ModelShort 'muse-spark-1.3-contributor'
        $mm2 = New-RawMessage -Id 'msg_dg_1' -Provider 'opencode-go' -ModelShort 'muse-spark-1.3-contributor' -Created '1000' -Completed '2000'
        return @{ session = $sn; messages = @($mm2) }
    })
    $rdg = Set-OrchestrationTaskModelAttempt -TaskId 'proof-downgrade-001' -ChildSessionId 'ses_child_dg' -ExpectedRevision (Get-TaskRevNow -T $s6 -Id 'proof-downgrade-001') -TasksDir $s6.tasks -FlagsPath $s6.flags -PolicyPath $polPath
    Assert-ModelProof (([bool]$rdg.ok) -and ([string]$rdg.tier -ceq 'T2')) 'transport fallback observation records its true T2 tier'
    $pdg = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-downgrade-001' -RequiredTier 'T3' -TasksDir $s6.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pdg.ok) -and ([string]$pdg.error -ceq 'PROOF_NO_MODEL_ATTEMPT'))) 'transport/downgrade model never satisfies a T3 proof'
    Clear-TaskKernelSessionReader

    # 26. caller-supplied shapes never yield proof (finding 7 negatives)
    $fi = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-fakeidx-001'
    $bfi = Invoke-ProofBindFlow -T $t -Id 'proof-fakeidx-001' -Run 'run-fi' -Root 'ses_root_fi' -Child 'ses_child_fi' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-fakeidx-001' -Status 'failed' -ClaimedEvidence @('criterion:0:x', 'session:ses_child_fi', 'message:msg_fi_1') -ProducedBy 'coder' -ExpectedRevision ([int]$bfi.revision) -StrategyApproach 'narrow retry' -StrategyTool 'src/widget/render.js' -StrategyParams @('isolate', 'render') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gfi = Get-OrchestrationTask -TaskId 'proof-fakeidx-001' -TasksDir $t.tasks
    $vfiJson = New-ProofVerifierJson -Status 'verification_failed' -Evidence @('passes:failed:1', 'criterion:99:unverified', 'x')
    $null = Set-OrchestrationTaskVerification -TaskId 'proof-fakeidx-001' -VerifierEvidenceJson $vfiJson -ExpectedRevision ([int]$gfi.revision) -TasksDir $t.tasks -FlagsPath $t.flags
    $gfi2 = Get-OrchestrationTask -TaskId 'proof-fakeidx-001' -TasksDir $t.tasks
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_fi' -Parent 'ses_root_fi' -Message 'msg_fi_1')
    $rfi = Set-OrchestrationTaskModelAttempt -TaskId 'proof-fakeidx-001' -ChildSessionId 'ses_child_fi' -ExpectedRevision ([int]$gfi2.revision) -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rfi.ok) 'fake-index fixture attempt recorded'
    $pfi = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-fakeidx-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pfi.ok) -and ([string]$pfi.error -ceq 'PROOF_VERIFIER_UNTRUSTED'))) 'forged criterion index cannot yield proof'
    $av = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-allver-001'
    $bav = Invoke-ProofBindFlow -T $t -Id 'proof-allver-001' -Run 'run-av' -Root 'ses_root_av' -Child 'ses_child_av' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-allver-001' -Status 'failed' -ClaimedEvidence @('criterion:0:x', 'session:ses_child_av', 'message:msg_av_1') -ProducedBy 'coder' -ExpectedRevision ([int]$bav.revision) -StrategyApproach 'narrow retry' -StrategyTool 'src/widget/render.js' -StrategyParams @('isolate', 'render') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gav = Get-OrchestrationTask -TaskId 'proof-allver-001' -TasksDir $t.tasks
    $vavJson = New-ProofVerifierJson -Status 'verification_failed' -CriterionWord 'verified' -ProfileStatus 'failed' -ExitCode 1
    $null = Set-OrchestrationTaskVerification -TaskId 'proof-allver-001' -VerifierEvidenceJson $vavJson -ExpectedRevision ([int]$gav.revision) -TasksDir $t.tasks -FlagsPath $t.flags
    $gav2 = Get-OrchestrationTask -TaskId 'proof-allver-001' -TasksDir $t.tasks
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_av' -Parent 'ses_root_av' -Message 'msg_av_1')
    $rav = Set-OrchestrationTaskModelAttempt -TaskId 'proof-allver-001' -ChildSessionId 'ses_child_av' -ExpectedRevision ([int]$gav2.revision) -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rav.ok) 'all-verified fixture attempt recorded'
    $pav = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-allver-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$pav.ok) -and ([string]$pav.error -ceq 'PROOF_VERIFIER_UNTRUSTED'))) 'inconsistent caller verdict cannot yield proof'
    $pv = New-ModelProofTask -T $t -PolPath $polPath -Id 'proof-prov-001'
    $bpv = Invoke-ProofBindFlow -T $t -Id 'proof-prov-001' -Run 'run-pv' -Root 'ses_root_pv' -Child 'ses_child_pv' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-prov-001' -Status 'failed' -ClaimedEvidence @('criterion:0:x', 'session:ses_child_pv', 'message:msg_pv_1') -ProducedBy 'coder' -ExpectedRevision ([int]$bpv.revision) -StrategyApproach 'narrow retry' -StrategyTool 'src/widget/render.js' -StrategyParams @('isolate', 'render') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $gpv = Get-OrchestrationTask -TaskId 'proof-prov-001' -TasksDir $t.tasks
    $vpvJson = New-ProofVerifierJson -Status 'verification_failed' -Profiles @()
    $null = Set-OrchestrationTaskVerification -TaskId 'proof-prov-001' -VerifierEvidenceJson $vpvJson -ExpectedRevision ([int]$gpv.revision) -TasksDir $t.tasks -FlagsPath $t.flags
    $gpv2 = Get-OrchestrationTask -TaskId 'proof-prov-001' -TasksDir $t.tasks
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_pv' -Parent 'ses_root_pv' -Message 'msg_pv_1')
    $rpv = Set-OrchestrationTaskModelAttempt -TaskId 'proof-prov-001' -ChildSessionId 'ses_child_pv' -ExpectedRevision ([int]$gpv2.revision) -TasksDir $t.tasks -FlagsPath $t.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rpv.ok) 'no-profiles fixture attempt recorded'
    $ppv = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-prov-001' -RequiredTier 'T3' -TasksDir $t.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$ppv.ok) -and ([string]$ppv.error -ceq 'PROOF_VERIFIER_UNTRUSTED'))) 'caller shape without executed provenance cannot yield proof'
    Clear-TaskKernelSessionReader

    # 27. T4 Sol without prior T3 proof fails closed
    $s7 = New-RepoTaskRoot -Name 'vr7'
    [void]$roots.Add($s7.root)
    $o = New-ModelProofTask -T $s7 -PolPath $polPath -Id 'proof-sol-alone-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bo = Invoke-ProofBindFlow -T $s7 -Id 'proof-sol-alone-001' -Run 'run-o1' -Root 'ses_root_o1' -Child 'ses_child_o1' -Rev 1
    $null = Invoke-ProofFailResult -T $s7 -Id 'proof-sol-alone-001' -Rev ([int]$bo.revision) -Evidence 'criterion:0:sol output incomplete' -SessionRef 'ses_child_o1' -MessageRefs @('msg_o1_1')
    $vvo = Invoke-ProofVerifyRun -T $s7 -Id 'proof-sol-alone-001' -Rev (Get-TaskRevNow -T $s7 -Id 'proof-sol-alone-001')
    Assert-ModelProof ([bool]$vvo.ok) 'sol verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-SolSeam -Session 'ses_child_o1' -Parent 'ses_root_o1' -Message 'msg_o1_1')
    $ro = Set-OrchestrationTaskModelAttempt -TaskId 'proof-sol-alone-001' -ChildSessionId 'ses_child_o1' -ExpectedRevision (Get-TaskRevNow -T $s7 -Id 'proof-sol-alone-001') -TasksDir $s7.tasks -FlagsPath $s7.flags -PolicyPath $polPath
    Assert-ModelProof (([bool]$ro.ok) -and ([string]$ro.tier -ceq 'T4')) 'sol observation records T4 tier'
    $po = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-sol-alone-001' -RequiredTier 'T4' -TasksDir $s7.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$po.ok) -and ([string]$po.error -ceq 'T3_PROOF_REQUIRED'))) 'sol proof without prior T3 proof fails closed'
    Clear-TaskKernelSessionReader

    # 28. T4 Sol with prior valid T3 proof succeeds (both kernel-executed)
    $s8 = New-RepoTaskRoot -Name 'vr8'
    [void]$roots.Add($s8.root)
    $w = New-ModelProofTask -T $s8 -PolPath $polPath -Id 'proof-sol-chain-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bw = Invoke-ProofBindFlow -T $s8 -Id 'proof-sol-chain-001' -Run 'run-w1' -Root 'ses_root_w1' -Child 'ses_child_w1' -Rev 1
    $null = Invoke-ProofFailResult -T $s8 -Id 'proof-sol-chain-001' -Rev ([int]$bw.revision) -Evidence 'criterion:0:terra output wrong' -SessionRef 'ses_child_w1' -MessageRefs @('msg_w1_t3')
    $vvw = Invoke-ProofVerifyRun -T $s8 -Id 'proof-sol-chain-001' -Rev (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001')
    Assert-ModelProof ([bool]$vvw.ok) 'chain: terra verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_w1' -Parent 'ses_root_w1' -Message 'msg_w1_t3')
    $rw = Set-OrchestrationTaskModelAttempt -TaskId 'proof-sol-chain-001' -ChildSessionId 'ses_child_w1' -ExpectedRevision (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001') -TasksDir $s8.tasks -FlagsPath $s8.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rw.ok) 'chain: terra attempt recorded'
    $pwT3 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-sol-chain-001' -RequiredTier 'T3' -TasksDir $s8.tasks -PolicyPath $polPath
    Assert-ModelProof ([bool]$pwT3.ok) 'chain: T3 proof valid before escalation'
    $bw2 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'proof-sol-chain-001' -RunId 'run-w1' -SessionId 'ses_child_w1' -ExpectedRevision (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001') -TasksDir $s8.tasks -FlagsPath $s8.flags
    $bw3 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'proof-sol-chain-001' -RunId 'run-w2' -SessionId 'ses_root_w1' -ExpectedRevision ([int]$bw2.revision) -TasksDir $s8.tasks -FlagsPath $s8.flags
    $bw4 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'proof-sol-chain-001' -RunId 'run-w2' -SessionId 'ses_root_w1' -ExpectedRevision ([int]$bw3.revision) -TasksDir $s8.tasks -FlagsPath $s8.flags
    $bw5 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'proof-sol-chain-001' -RunId 'run-w2' -SessionId 'ses_child_w2' -WorkerSession -ExpectedRevision ([int]$bw4.revision) -TasksDir $s8.tasks -FlagsPath $s8.flags
    Assert-ModelProof ([bool]$bw5.ok) 'chain: second run bound for sol attempt'
    $null = Invoke-ProofFailResult -T $s8 -Id 'proof-sol-chain-001' -Rev (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001') -Evidence 'criterion:0:sol output incomplete' -Approach 'broad context' -Tool 'src/model/sol.js' -SessionRef 'ses_child_w2' -MessageRefs @('msg_w1_sol')
    $vvw2 = Invoke-ProofVerifyRun -T $s8 -Id 'proof-sol-chain-001' -Rev (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001')
    Assert-ModelProof ([bool]$vvw2.ok) 'chain: sol verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-SolSeam -Session 'ses_child_w2' -Parent 'ses_root_w1' -Message 'msg_w1_sol')
    $rw2 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-sol-chain-001' -ChildSessionId 'ses_child_w2' -ExpectedRevision (Get-TaskRevNow -T $s8 -Id 'proof-sol-chain-001') -TasksDir $s8.tasks -FlagsPath $s8.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rw2.ok) 'chain: sol attempt recorded'
    $pwT4 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-sol-chain-001' -RequiredTier 'T4' -TasksDir $s8.tasks -PolicyPath $polPath
    $t4ok = (([bool]$pwT4.ok) -and ([string]$pwT4.model -ceq 'openai/gpt-6.1-sol') -and ([string]$pwT4.tier -ceq 'T4') `
        -and ([string]$pwT4.session_id -ceq 'ses_child_w2') -and ([string]$pwT4.digest -cmatch '^sha256:[0-9a-f]{64}$'))
    Assert-ModelProof $t4ok 'chain: T4 sol proof valid with prior T3 proof'
    Clear-TaskKernelSessionReader

    # 29. terra pass then sol failed refuses T4 (no failed kernel-executed T3 record)
    $s9 = New-RepoTaskRoot -Name 'vr9'
    [void]$roots.Add($s9.root)
    Write-ModelProofFixture -Path (Join-Path $s9.repo 'flip.ps1') -Text "if (Test-Path -LiteralPath 'seq-state/flip.txt') { exit 1 }`nNew-Item -ItemType Directory -Path 'seq-state' -Force | Out-Null`nSet-Content -LiteralPath 'seq-state/flip.txt' -Value '1'`nexit 0`n"
    Write-ModelProofFixture -Path (Join-Path $s9.repo 'source\registry\verification-policy.json') -Text '{"version":1,"default_timeout_seconds":60,"max_output_chars":4000,"profiles":{"passes":{"class":"test","command":"powershell -NoProfile -Command exit 0","timeout_seconds":30},"failer":{"class":"test","command":"powershell -NoProfile -Command exit 1","timeout_seconds":30},"flipflop":{"class":"test","command":"powershell -NoProfile -ExecutionPolicy Bypass -File flip.ps1","timeout_seconds":30}}}'
    & git -C $s9.repo add -A *>$null
    & git -C $s9.repo commit -m flipflop -q *>$null
    $tp = New-ModelProofTask -T $s9 -PolPath $polPath -Id 'proof-terrapass-001' -BaseRevision 'HEAD' -WriteScopes @('seq-state') -VerProfiles @('flipflop')
    $btp = Invoke-ProofBindFlow -T $s9 -Id 'proof-terrapass-001' -Run 'run-tp1' -Root 'ses_root_tp1' -Child 'ses_child_tp1' -Rev 1
    $null = Set-OrchestrationTaskWorkerResult -TaskId 'proof-terrapass-001' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0:terra renders', 'session:ses_child_tp1', 'message:msg_tp_t3') -ProducedBy 'coder' -ExpectedRevision ([int]$btp.revision) -TasksDir $s9.tasks -FlagsPath $s9.flags -TelemetryRoot $s9.root
    $vtp = Invoke-TaskKernelVerifyRun -TaskId 'proof-terrapass-001' -ExpectedRevision (Get-TaskRevNow -T $s9 -Id 'proof-terrapass-001') -TasksDir $s9.tasks -FlagsPath $s9.flags -RepoRoot $s9.repo
    Assert-ModelProof (([bool]$vtp.ok) -and ([string]$vtp.status -ceq 'verified_pass') -and ([string]$vtp.verification_source -ceq 'kernel-executed')) 'terra pass verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_tp1' -Parent 'ses_root_tp1' -Message 'msg_tp_t3')
    $rtp = Set-OrchestrationTaskModelAttempt -TaskId 'proof-terrapass-001' -ChildSessionId 'ses_child_tp1' -ExpectedRevision (Get-TaskRevNow -T $s9 -Id 'proof-terrapass-001') -TasksDir $s9.tasks -FlagsPath $s9.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rtp.ok) 'terra pass observation recorded'
    $btp2 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'proof-terrapass-001' -RunId 'run-tp1' -SessionId 'ses_child_tp1' -ExpectedRevision ([int]$rtp.revision) -TasksDir $s9.tasks -FlagsPath $s9.flags
    $btp3 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'proof-terrapass-001' -RunId 'run-tp2' -SessionId 'ses_root_tp1' -ExpectedRevision ([int]$btp2.revision) -TasksDir $s9.tasks -FlagsPath $s9.flags
    $btp4 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId 'proof-terrapass-001' -RunId 'run-tp2' -SessionId 'ses_root_tp1' -ExpectedRevision ([int]$btp3.revision) -TasksDir $s9.tasks -FlagsPath $s9.flags
    $btp5 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId 'proof-terrapass-001' -RunId 'run-tp2' -SessionId 'ses_child_tp2' -WorkerSession -ExpectedRevision ([int]$btp4.revision) -TasksDir $s9.tasks -FlagsPath $s9.flags
    $null = Invoke-ProofFailResult -T $s9 -Id 'proof-terrapass-001' -Rev (Get-TaskRevNow -T $s9 -Id 'proof-terrapass-001') -Evidence 'criterion:0:sol output incomplete' -Approach 'broad context' -Tool 'src/model/sol.js' -SessionRef 'ses_child_tp2' -MessageRefs @('msg_tp_sol')
    $vtp2 = Invoke-ProofVerifyRun -T $s9 -Id 'proof-terrapass-001' -Rev (Get-TaskRevNow -T $s9 -Id 'proof-terrapass-001')
    Assert-ModelProof (([bool]$vtp2.ok) -and ([string]$vtp2.status -ceq 'verification_failed') -and ([string]$vtp2.verification_source -ceq 'kernel-executed')) 'sol verify-run executes after terra pass'
    Set-TaskKernelSessionReader -Reader (New-SolSeam -Session 'ses_child_tp2' -Parent 'ses_root_tp1' -Message 'msg_tp_sol')
    $rtp2 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-terrapass-001' -ChildSessionId 'ses_child_tp2' -ExpectedRevision (Get-TaskRevNow -T $s9 -Id 'proof-terrapass-001') -TasksDir $s9.tasks -FlagsPath $s9.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rtp2.ok) 'sol observation recorded after terra pass'
    $ptp = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-terrapass-001' -RequiredTier 'T4' -TasksDir $s9.tasks -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$ptp.ok) -and ([string]$ptp.error -ceq 'T3_PROOF_REQUIRED'))) 'terra pass then sol failed refuses T4 (no failed T3 record)'
    Clear-TaskKernelSessionReader

    # 29A. persisted Kernel -> Router model-select (real store + real verify-run + seam; no stubs)
    . (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
    $rpolA = Get-OrchestrationModelRoutingPolicy -PolicyPath $polPath
    $canonSolA = [string]$rpolA.Policy.models.sol.model_id
    $canonAstraA = [string]$rpolA.Policy.models.astra.model_id
    $selA = New-RepoTaskRoot -Name 'selA'
    [void]$roots.Add($selA.root)
    $sa = New-ModelProofTask -T $selA -PolPath $polPath -Id 'proof-sel-t3-001' -BaseRevision 'HEAD' -WriteScopes @() -VerProfiles @('failer')
    $bsa = Invoke-ProofBindFlow -T $selA -Id 'proof-sel-t3-001' -Run 'run-sa' -Root 'ses_root_sa' -Child 'ses_child_sa' -Rev 1
    $null = Invoke-ProofFailResult -T $selA -Id 'proof-sel-t3-001' -Rev ([int]$bsa.revision) -SessionRef 'ses_child_sa' -MessageRefs @('msg_sa_1')
    $vsa = Invoke-ProofVerifyRun -T $selA -Id 'proof-sel-t3-001' -Rev (Get-TaskRevNow -T $selA -Id 'proof-sel-t3-001')
    Assert-ModelProof ([bool]$vsa.ok) 'select: t3-only verify-run executes'
    Set-TaskKernelSessionReader -Reader (New-TerraSeam -Session 'ses_child_sa' -Parent 'ses_root_sa' -Message 'msg_sa_1')
    $rsa = Set-OrchestrationTaskModelAttempt -TaskId 'proof-sel-t3-001' -ChildSessionId 'ses_child_sa' -ExpectedRevision (Get-TaskRevNow -T $selA -Id 'proof-sel-t3-001') -TasksDir $selA.tasks -FlagsPath $selA.flags -PolicyPath $polPath
    Assert-ModelProof ([bool]$rsa.ok) 'select: t3-only attempt recorded'
    Clear-TaskKernelSessionReader
    $psaT3 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-sel-t3-001' -RequiredTier 'T3' -TasksDir $selA.tasks -PolicyPath $polPath
    Assert-ModelProof ([bool]$psaT3.ok) 'select: t3-only proof valid before model-select'
    $selSol = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'proof-sel-t3-001' -TasksDir $selA.tasks -RepoRoot $selA.repo -PolicyPath $polPath -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
    Assert-ModelProof ((([string]$selSol.Tier -ceq 'T4') -and ([string]$selSol.CatalogModel -ceq $canonSolA))) 'select: T3 proof yields Sol'
    Assert-ModelProof ((([string]$selSol.KernelProofReference -ceq [string]$psaT3.reference) -and ([string]$selSol.KernelProofDigest -ceq [string]$psaT3.digest))) 'select: Sol receipt exposes T3 proof ref/digest'
    $selAstra = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'proof-sol-chain-001' -TasksDir $s8.tasks -RepoRoot $s8.repo -PolicyPath $polPath -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
    Assert-ModelProof ((([string]$selAstra.Tier -ceq 'T4') -and ([string]$selAstra.CatalogModel -ceq $canonAstraA))) 'select: Sol proof yields Astra'
    Assert-ModelProof ((([string]$selAstra.KernelProofReference -ceq [string]$pwT4.reference) -and ([string]$selAstra.KernelProofDigest -ceq [string]$pwT4.digest) -and ([string]$selAstra.KernelProofReference -cne [string]$pwT3.reference))) 'select: Astra receipt exposes T4 proof ref/digest (not older T3 ref)'
    $selNoAstra = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId 'proof-terrapass-001' -TasksDir $s9.tasks -RepoRoot $s9.repo -PolicyPath $polPath -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $true
    Assert-ModelProof ([string]$selNoAstra.CatalogModel -cne $canonAstraA) 'select: T3-pass/Sol-failed chain yields no Astra'

    # 30. explicit missing RepoRoot fails closed
    $er1 = Set-OrchestrationTaskModelAttempt -TaskId 'proof-t3-001' -ChildSessionId 'ses_child_t3a' -ExpectedRevision 999 -TasksDir $s3.tasks -FlagsPath $s3.flags -RepoRoot 'Z:\no-such-dir-xyz-001' -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$er1.ok) -and ([string]$er1.error -ceq 'INVALID_REPO_ROOT'))) 'model-attempt with missing explicit RepoRoot fails closed'
    $er2 = Get-OrchestrationTaskModelFailureProof -TaskId 'proof-t3-001' -RequiredTier 'T3' -TasksDir $s3.tasks -RepoRoot 'Z:\no-such-dir-xyz-001' -PolicyPath $polPath
    Assert-ModelProof (((-not [bool]$er2.ok) -and ([string]$er2.error -ceq 'INVALID_REPO_ROOT'))) 'model-proof with missing explicit RepoRoot fails closed'
    $er3 = Invoke-TaskKernelVerifyRun -TaskId 'proof-t3-001' -ExpectedRevision (Get-TaskRevNow -T $s3 -Id 'proof-t3-001') -TasksDir $s3.tasks -FlagsPath $s3.flags -RepoRoot 'Z:\no-such-dir-xyz-001'
    Assert-ModelProof (((-not [bool]$er3.ok) -and ([string]$er3.error -ceq 'INVALID_REPO_ROOT'))) 'verify-run with missing explicit RepoRoot fails closed'
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
}
finally {
    try { Clear-TaskKernelSessionReader } catch { }
    foreach ($rd in $roots) {
        if (Test-Path -LiteralPath $rd) { Remove-Item -LiteralPath $rd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ("ModelProof: {0} / {1} tests passed" -f $script:passed, ($script:passed + $script:failed))
if ($script:failed -gt 0) { exit 1 }
exit 0
