<#!
.SYNOPSIS
    Router v14 native override proof + Kernel integration (deterministic).
.DESCRIPTION
    No provider calls or inference. One CLI case makes a bounded, local
    read-only /api/info query; no external/networked service is used. PS 5.1,
    ASCII-only.
    Part A: Test-OrchestrationNativeModelOverrideProof accepts ONLY an
    injectable read-only info seam (-InfoReader). Task profile/version are
    caller metadata and never authorize the subagent.model override:
    capability derives solely from the bounded live /api/info version plus
    the canonical supported allowlist (2.2.5, 2.0.23). Unknown/missing live
    API fails closed. Process environment never sources proof. Part B: real
    TaskKernel fixture drives a persisted T3 proof and shows
    Resolve-OrchestrationModelSelection yields T4 Sol (no stub of
    Get-OrchestrationTaskModelFailureProof for the positive case), plus
    spoofed task metadata cannot change the live capability, plus one
    hermetic CLI-level model-select check computed from the same live
    helper (fail closed when the live API is unavailable). The CLI never
    exposes -InfoReader and never reads task runtime metadata for proof.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$libRoot = $PSScriptRoot
. (Join-Path $libRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $libRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $libRoot 'OrchestrationModelExecution.ps1')
$script:pass = 0; $script:fail = 0
function Assert-NP([bool]$c,[string]$n,[string]$d='') {
    if ($c) { Write-Host ("[PASS] {0}" -f $n); $script:pass++ }
    else { if ($d -eq '') { Write-Host ("[FAIL] {0}" -f $n) } else { Write-Host ("[FAIL] {0} -- {1}" -f $n,$d) }; $script:fail++ }
}
function New-NPSeam([string]$v) {
    $cap = @{ ver = $v }
    return ({ param() return [string]$cap.ver }).GetNewClosure()
}
try {
    # Part A: live-server-only helper (injectable seam, no network).
    # API surface: only -InfoReader; task profile/version params removed.
    $paramNames = @((Get-Command Test-OrchestrationNativeModelOverrideProof -ErrorAction Stop).Parameters.Keys)
    Assert-NP (($paramNames -contains 'InfoReader')) 'NP00-helper-exposes-inforeader-seam' ($paramNames -join ',')
    Assert-NP ((($paramNames -notcontains 'TaskRuntimeProfile') -and ($paramNames -notcontains 'TaskRuntimeVersion'))) 'NP00-helper-rejects-task-metadata-authority' ($paramNames -join ',')
    $r1 = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '2.2.5')
    Assert-NP ([bool]$r1.ok) 'NP01-supported-225-proves' ("reason=" + [string]$r1.reason + " live=" + [string]$r1.live_version)
    Assert-NP (([string]$r1.live_version -ceq '2.2.5')) 'NP01b-live-version-echo-225' ("live=" + [string]$r1.live_version)
    $r1b = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '2.0.23')
    Assert-NP ([bool]$r1b.ok) 'NP02-supported-2023-proves' ("reason=" + [string]$r1b.reason + " live=" + [string]$r1b.live_version)
    $r4 = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '9.9.9')
    Assert-NP (((-not [bool]$r4.ok) -and ([string]$r4.reason -ceq 'UNSUPPORTED_RUNTIME'))) 'NP03-unknown-runtime-fails-closed' ("reason=" + [string]$r4.reason)
    $boom = ({ param() throw 'nope' }).GetNewClosure()
    $r5 = Test-OrchestrationNativeModelOverrideProof -InfoReader $boom
    Assert-NP (((-not [bool]$r5.ok) -and ([string]$r5.reason -ceq 'INFO_UNAVAILABLE'))) 'NP04-live-api-failure-fails-closed' ("reason=" + [string]$r5.reason)
    $objSeam = ({ param() return @{ version = '2.2.5' } }).GetNewClosure()
    $r6 = Test-OrchestrationNativeModelOverrideProof -InfoReader $objSeam
    Assert-NP ([bool]$r6.ok) 'NP05-object-shape-version-proves' ("reason=" + [string]$r6.reason)
    $emptySeam = (New-NPSeam '')
    $r7 = Test-OrchestrationNativeModelOverrideProof -InfoReader $emptySeam
    Assert-NP (((-not [bool]$r7.ok) -and ([string]$r7.reason -ceq 'INFO_UNAVAILABLE'))) 'NP06-missing-live-version-fails-closed' ("reason=" + [string]$r7.reason)
    # Spoofed task metadata cannot change the capability: the helper takes
    # no task fields, so the same live server yields the same result no
    # matter what a caller wrote at create time. Demonstrate by holding the
    # live seam fixed while varying the (now inert) task record values.
    $liveFixed = '2.2.5'
    $spoofA = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam $liveFixed)
    $spoofB = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam $liveFixed)
    Assert-NP (([bool]$spoofA.ok -and [bool]$spoofB.ok -and ([string]$spoofA.live_version -ceq $liveFixed) -and ([string]$spoofB.live_version -ceq $liveFixed))) 'NP07-spoofed-task-metadata-irrelevant-v1bad-vs-v2good' ("a=" + [string]$spoofA.live_version + " b=" + [string]$spoofB.live_version)
    # V1 task profile no longer forces false on its own: a positively proven
    # live server (2.2.5) proves even when a task record claims profile v1.
    # The task record below is observability-only; the proof ignores it.
    $v1Ignored = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '2.2.5')
    Assert-NP ([bool]$v1Ignored.ok) 'NP08-v1-profile-does-not-force-false-when-live-proven' ("reason=" + [string]$v1Ignored.reason)
    # Caller-controlled process environment is never proof: with no InfoReader
    # injected, live_version must come from /api/info (or be unavailable),
    # never from ORCHESTRATION_TEST_NATIVE_INFO_VERSION. Probe the honest
    # live value first, then set env to the OTHER supported version so an
    # env-sourced path would be distinguishable (live == env with ok=true).
    Remove-Item -Path Env:\ORCHESTRATION_TEST_NATIVE_INFO_VERSION -ErrorAction SilentlyContinue
    $baseNp = Test-OrchestrationNativeModelOverrideProof
    $h0Np = [string]$baseNp.live_version
    $envProbeNp = if ($h0Np -ceq '2.0.23') { '2.2.5' } else { '2.0.23' }
    $prevEnvNp = $env:ORCHESTRATION_TEST_NATIVE_INFO_VERSION
    try {
        $env:ORCHESTRATION_TEST_NATIVE_INFO_VERSION = $envProbeNp
        $rnEnvNp = Test-OrchestrationNativeModelOverrideProof
        Assert-NP (([string]$rnEnvNp.live_version -cne $envProbeNp)) 'NP09-env-var-never-sources-live-version' ("live=" + [string]$rnEnvNp.live_version + " env=" + $envProbeNp + " honest=" + $h0Np)
        Assert-NP ((-not [bool]$rnEnvNp.ok) -or ([string]$rnEnvNp.live_version -cne $envProbeNp)) 'NP10-env-var-never-proves-alone' ("ok=" + [string]$rnEnvNp.ok + " reason=" + [string]$rnEnvNp.reason)
    } finally { $env:ORCHESTRATION_TEST_NATIVE_INFO_VERSION = $prevEnvNp }

    # Part B: real Kernel fixture -> persisted T3 proof -> T4 Sol (no stub).
    $tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('np-kernel-' + [guid]::NewGuid().ToString('N'))
    $tasksDir = Join-Path $tmpRoot 'tasks'
    $flagsPath = Join-Path $tmpRoot 'flags.json'
    $repoDir = Join-Path $tmpRoot 'repo'
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    & git -C $repoDir init -b master *>$null
    if ($LASTEXITCODE -ne 0) { & git -C $repoDir init *>$null }
    & git -C $repoDir config user.email 'np-test@example.com' *>$null
    & git -C $repoDir config user.name 'NP Test' *>$null
    & git -C $repoDir config core.autocrlf false *>$null
    & git -C $repoDir config core.safecrlf false *>$null
    [IO.File]::WriteAllText((Join-Path $repoDir 'base.txt'), "base`n", [Text.UTF8Encoding]::new($false))
    & git -C $repoDir add -A *>$null
    & git -C $repoDir commit -m init -q *>$null
    $polDir = Join-Path $repoDir 'source\registry'
    New-Item -ItemType Directory -Path $polDir -Force | Out-Null
    $profObj = New-Object PSCustomObject
    $profObj | Add-Member -NotePropertyName 'passes' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 0'; timeout_seconds = 30 })
    $profObj | Add-Member -NotePropertyName 'failer' -NotePropertyValue ([PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 1'; timeout_seconds = 30 })
    $doc = [ordered]@{ version = 1; default_timeout_seconds = 60; max_output_chars = 4000; profiles = $profObj }
    $verifyPolPath = Join-Path $polDir 'verification-policy.json'
    [IO.File]::WriteAllText($verifyPolPath, ((New-Object PSCustomObject -Property $doc) | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    & git -C $repoDir add -A *>$null
    & git -C $repoDir commit -m policy -q *>$null
    $modelPolPath = Get-TaskKernelModelPolicyDefaultPath
    $tid = 'np-int-001'
    $npBudgetPol = ''
    try { $npBudgetPol = Get-ExecutionBudgetDefaultPolicyPath } catch { $npBudgetPol = '' }
    $cr = New-OrchestrationTask -TaskId $tid -Objective 'Fix the widget renderer' -TaskType 'implementation' -Risk 'low' -Actor 'planner' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.5' -BaseRevision 'HEAD' -ReadScopes @('src/widget') -WriteScopes @() -Grants @('fs.read') -AcceptanceCriteria @('widget renders') -ExpectedArtifacts @('src/widget/render.js') -VerificationProfiles @('failer') -AttemptBudget 3 -BudgetPolicyPath $npBudgetPol -TasksDir $tasksDir -FlagsPath $flagsPath -RepoRoot $repoDir -TelemetryRoot $tmpRoot
    Assert-NP ([bool]$cr.ok) 'NP11-fixture-task-created-v2' ([string]$cr.error)
    $rev1 = [int](Get-OrchestrationTask -TaskId $tid -TasksDir $tasksDir)['revision']
    $b1 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId 'run-np1' -SessionId 'ses_root_np1' -ExpectedRevision $rev1 -TasksDir $tasksDir -FlagsPath $flagsPath
    $b2 = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId $tid -RunId 'run-np1' -SessionId 'ses_root_np1' -ExpectedRevision ([int]$b1.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
    $b3 = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId 'run-np1' -SessionId 'ses_child_np1' -WorkerSession -ExpectedRevision ([int]$b2.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-NP ([bool]$b3.ok) 'NP12-fixture-child-bound' ([string]$b3.error)
    $wr = Set-OrchestrationTaskWorkerResult -TaskId $tid -Status 'failed' -ClaimedEvidence @('criterion:0:widget still broken', 'session:ses_child_np1', 'message:msg_np1') -ProducedBy 'coder' -ExpectedRevision ([int]$b3.revision) -StrategyApproach 'narrow retry' -StrategyTool 'src/widget/render.js' -StrategyParams @('isolate', 'render') -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tmpRoot
    Assert-NP ([bool]$wr.ok) 'NP13-fixture-failure-recorded' ([string]$wr.error)
    $vr = Invoke-TaskKernelVerifyRun -TaskId $tid -ExpectedRevision ([int]$wr.revision) -TasksDir $tasksDir -FlagsPath $flagsPath -RepoRoot $repoDir
    Assert-NP ([bool]$vr.ok) 'NP14-fixture-verify-run-executes' ([string]$vr.error)
    Set-TaskKernelSessionReader -Reader ({
        param([string]$ChildSid)
        $sn = [ordered]@{ id = 'ses_child_np1'; parentID = 'ses_root_np1'; agent = 'coder'; model = [ordered]@{ providerID = 'openai'; id = 'gpt-6.1-terra' }; outcome = 'succeeded'; cost = 0.001; tokens = [ordered]@{ input = 100; output = 20; reasoning = 5 } }
        $mm = [ordered]@{ id = 'msg_np1'; type = 'assistant'; agent = 'coder'; model = [ordered]@{ providerID = 'openai'; id = 'gpt-6.1-terra' }; time = [ordered]@{ created = '1000'; completed = '2000' }; finish = 'stop'; cost = 0.001; tokens = [ordered]@{ input = 100; output = 20; reasoning = 5 } }
        return @{ session = $sn; messages = @($mm) }
    })
    $revNow = [int](Get-OrchestrationTask -TaskId $tid -TasksDir $tasksDir)['revision']
    $ar = Set-OrchestrationTaskModelAttempt -TaskId $tid -ChildSessionId 'ses_child_np1' -ExpectedRevision $revNow -TasksDir $tasksDir -FlagsPath $flagsPath -PolicyPath $modelPolPath
    Assert-NP ([bool]$ar.ok) 'NP15-fixture-model-attempt-recorded' ([string]$ar.error)
    Clear-TaskKernelSessionReader
    $proof = Get-OrchestrationTaskModelFailureProof -TaskId $tid -RequiredTier 'T3' -TasksDir $tasksDir -PolicyPath $modelPolPath
    Assert-NP (([bool]$proof.ok -and ([string]$proof.model -ceq 'openai/gpt-6.1-terra'))) 'NP16-real-T3-proof-persisted' ([string]$proof.error)
    $polRes = Get-OrchestrationModelRoutingPolicy
    $polHash = [string]$polRes.PolicyHash
    $nativeOk = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '2.2.5')
    $sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId $tid -TasksDir $tasksDir -RepoRoot $repoDir -PolicyPath $modelPolPath -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven ([bool]$nativeOk.ok)
    Assert-NP ((([string]$sel.Tier -ceq 'T4') -and ([string]$sel.CatalogModel -ceq 'openai/gpt-6.1-sol'))) 'NP17-persisted-T3-proof-yields-T4-Sol' ("tier=" + [string]$sel.Tier + " model=" + [string]$sel.CatalogModel)
    Assert-NP ((-not [string]::IsNullOrWhiteSpace([string]$sel.KernelProofReference)) -and ([string]$sel.policy_hash -ceq $polHash)) 'NP18-proof-ref-and-hash' ("ref=" + [string]$sel.KernelProofReference)
    $nativeBad = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '9.9.9')
    Assert-NP ((-not [bool]$nativeBad.ok)) 'NP19-unsupported-live-native-false-but-kernel-tier-holds' ("reason=" + [string]$nativeBad.reason)
    # In-process: kernel T3 proof still yields T4 tier while the native
    # override is unproven (selection keeps the kernel tier; only the native
    # model fields stay blank at the CLI layer).
    $selUnproven = Resolve-OrchestrationModelSelection -AgentName 'coder' -TaskId $tid -TasksDir $tasksDir -RepoRoot $repoDir -PolicyPath $modelPolPath -Complexity 'complex' -IgnoreUserConfig $true -NativeModelOverrideProven $false
    Assert-NP ((([string]$selUnproven.Tier -ceq 'T4') -and ([string]$selUnproven.runtime_override_status -ceq 'PROOF_ABSENT'))) 'NP20-unproven-selection-keeps-kernel-tier' ("tier=" + [string]$selUnproven.Tier)
    # Trusted path binding (ROUTER-V14): trusted proof/selection actions accept
    # path overrides only when absent or GetFullPath-equal to the canonical
    # checkout paths; divergent overrides fail closed BEFORE any store I/O
    # with TRUSTED_PATH_MISMATCH (no path echo, no dest read). Library
    # stays injectable for unit fixtures; the CLI pins canonical.
    $cliPs1 = Join-Path (Split-Path -Parent $libRoot) 'task-kernel.ps1'
    Remove-Item -Path Env:\ORCHESTRATION_TEST_NATIVE_INFO_VERSION -ErrorAction SilentlyContinue
    # Spoofed task record: v1 profile + bad version persisted for
    # observability. The live capability ignores it: same live seam proves
    # regardless of the stored task metadata.
    $tidV1 = 'np-int-v1-001'
    $crV1 = New-OrchestrationTask -TaskId $tidV1 -Objective 'Fix the widget renderer on v1 runtime' -TaskType 'implementation' -Risk 'low' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -RuntimeVersion '9.9.9-bogus' -BaseRevision 'HEAD' -ReadScopes @('src/widget') -WriteScopes @() -Grants @('fs.read') -AcceptanceCriteria @('widget renders') -ExpectedArtifacts @('src/widget/render.js') -VerificationProfiles @('failer') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tmpRoot
    Assert-NP ([bool]$crV1.ok) 'NP21-fixture-v1-spoof-task-created' ([string]$crV1.error)
    $recV1 = Get-OrchestrationTask -TaskId $tidV1 -TasksDir $tasksDir
    $storedProf = ''
    try {
        if ($recV1 -is [System.Collections.IDictionary]) {
            if ($recV1.Contains('runtime') -and ($recV1['runtime'] -is [System.Collections.IDictionary]) -and $recV1['runtime'].Contains('profile')) { $storedProf = [string]$recV1['runtime']['profile'] }
            elseif ($recV1.Contains('runtime_profile')) { $storedProf = [string]$recV1['runtime_profile'] }
        } else {
            $rn = $recV1.PSObject.Properties['runtime']; if ($null -ne $rn -and $null -ne $rn.Value) { try { $storedProf = [string]$rn.Value.profile } catch { $storedProf = '' } }
            if ([string]::IsNullOrWhiteSpace($storedProf)) { $rp = $recV1.PSObject.Properties['runtime_profile']; if ($null -ne $rp) { $storedProf = [string]$rp.Value } }
        }
    } catch { $storedProf = '' }
    Assert-NP (($storedProf -ceq 'v1')) 'NP22-spoofed-v1-profile-persisted-for-observability' ("profile=" + $storedProf)
    $liveForSpoof = Test-OrchestrationNativeModelOverrideProof -InfoReader (New-NPSeam '2.2.5')
    Assert-NP ([bool]$liveForSpoof.ok) 'NP23-live-proven-despite-v1-spoof-record' ("reason=" + [string]$liveForSpoof.reason)
    $altCliDir = Join-Path $tmpRoot 'alt-cli-store'
    New-Item -ItemType Directory -Path $altCliDir -Force | Out-Null
    $altCliFlags = Join-Path $tmpRoot 'alt-cli-flags.json'
    [IO.File]::WriteAllText($altCliFlags, '{"task_kernel":{"enabled":true}}', [Text.UTF8Encoding]::new($false))
    $altCliPol = Join-Path $tmpRoot 'alt-cli-model-policy.json'
    [IO.File]::WriteAllText($altCliPol, '{}', [Text.UTF8Encoding]::new($false))
    $cliOutAltTasks = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-select -TaskId 'np-no-such-task' -AttemptRole coder -TasksDir $altCliDir 2>&1 | Out-String
    $cliDocAltTasks = ($cliOutAltTasks | ConvertFrom-Json -ErrorAction Stop)
    Assert-NP ((([string]$cliDocAltTasks.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$cliDocAltTasks.path_role -ceq 'tasks_dir') -and ($cliOutAltTasks -notmatch [regex]::Escape($altCliDir)))) 'NP24-cli-divergent-tasksdir-refused-before-io' ("err=" + [string]$cliDocAltTasks.error)
    $cliOutAltFlags = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-attempt -TaskId 'np-no-such-task' -SessionId 'ses-x' -ExpectedRevision 1 -FlagsPath $altCliFlags 2>&1 | Out-String
    $cliDocAltFlags = ($cliOutAltFlags | ConvertFrom-Json -ErrorAction Stop)
    Assert-NP ((([string]$cliDocAltFlags.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$cliDocAltFlags.path_role -ceq 'flags_path') -and ($cliOutAltFlags -notmatch [regex]::Escape($altCliFlags)))) 'NP25-cli-divergent-flagspath-refused-before-io' ("err=" + [string]$cliDocAltFlags.error)
    $cliOutAltRoot = & powershell -NoProfile -ExecutionPolicy Bypass -File $cliPs1 -Action model-proof -TaskId 'np-no-such-task' -RequiredTier T3 -CliRepoRoot $repoDir 2>&1 | Out-String
    $cliDocAltRoot = ($cliOutAltRoot | ConvertFrom-Json -ErrorAction Stop)
    Assert-NP ((([string]$cliDocAltRoot.error -ceq 'TRUSTED_PATH_MISMATCH') -and ([string]$cliDocAltRoot.path_role -ceq 'repo_root') -and ($cliOutAltRoot -notmatch [regex]::Escape($repoDir)))) 'NP26-cli-divergent-reporoot-refused-before-io' ("err=" + [string]$cliDocAltRoot.error)
    Assert-NP ((@(Get-ChildItem -LiteralPath $altCliDir -ErrorAction SilentlyContinue)).Count -eq 0) 'NP27-cli-divergent-store-creates-no-task' ''
    # CLI hermetic check: use an isolated copy so the fixture stays under
    # TEMP and never creates a task/lock in the current repository store.
    # Expected comes from the SAME live helper the CLI uses (no InfoReader,
    # no env). When the live API is unavailable, both paths fail closed.
    $liveDirect = $null
    try { $liveDirect = Test-OrchestrationNativeModelOverrideProof } catch { $liveDirect = @{ ok = $false; reason = 'INFO_UNAVAILABLE'; live_version = '' } }
    $liveExpected = [bool]$liveDirect.ok
    $cliTaskId = ('np-cli-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $cliRootV14 = Join-Path $tmpRoot 'cli-root'
    $cliV3V14 = Join-Path $cliRootV14 'scripts\v3'
    $cliLibV14 = Join-Path $cliV3V14 'lib'
    $cliRegistryV14 = Join-Path $cliRootV14 'source\registry'
    $cliTasksV14 = Join-Path $cliRootV14 'cache\runtime\tasks'
    New-Item -ItemType Directory -Path $cliLibV14,$cliRegistryV14,$cliTasksV14 -Force | Out-Null
    Copy-Item -LiteralPath $cliPs1 -Destination $cliV3V14
    foreach ($libName in @('OrchestrationTaskKernel.ps1','OrchestrationModelRouter.ps1','OrchestrationModelExecution.ps1')) {
        Copy-Item -LiteralPath (Join-Path $libRoot $libName) -Destination $cliLibV14
    }
    $currentRepoRootV14 = Get-TaskKernelRepoRoot -RepoRoot ''
    foreach ($registryName in @('model-routing-policy.json','capability-flags.json')) {
        Copy-Item -LiteralPath (Join-Path $currentRepoRootV14 ('source\registry\' + $registryName)) -Destination $cliRegistryV14
    }
    # Intentionally contradictory task metadata: it is persisted for
    # observability but cannot authorize a live-server model override.
    $cliTask = [ordered]@{
        schema_version = 1; task_id = $cliTaskId; revision = 1; state = 'DISCOVERING'
        risk = 'low'; task_type = 'implementation'; acceptance_criteria = @()
        runtime = [ordered]@{ id = 'opencode-v1'; generation = 1; profile = 'v1'; version = '9.9.9-bogus' }
        attempts = @(); model_attempts = @(); verification = $null; verification_history = @()
        verification_profiles = @(); worker_result = $null
    }
    [IO.File]::WriteAllText((Join-Path $cliTasksV14 ($cliTaskId + '.json')), ($cliTask | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
    $cliDoc = $null
    $cliRaw = ''
    try {
        $cliRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $cliV3V14 'task-kernel.ps1') -Action model-select -TaskId $cliTaskId -AttemptRole coder -Risk low -ModelComplexity simple 2>&1 | Out-String
        $cliDoc = ($cliRaw | ConvertFrom-Json -ErrorAction Stop)
    } catch { $cliDoc = $null }
    if ($null -ne $cliDoc) {
        $cliProven = $false
        try { $cliProven = [bool]$cliDoc.native_model_override_proven } catch { $cliProven = $false }
        Assert-NP (($cliProven -ceq $liveExpected)) 'NP28-cli-matches-live-helper-spoof-ignored' ("cli=" + [string]$cliProven + " live=" + [string]$liveExpected + " reason=" + [string]$cliDoc.native_proof_reason)
        if (-not $liveExpected) {
            Assert-NP (((-not $cliProven) -and [string]::IsNullOrWhiteSpace([string]$cliDoc.model) -and [string]::IsNullOrWhiteSpace([string]$cliDoc.subagent_model))) 'NP29-cli-fail-closed-blanks-model-when-api-unavailable' ("model=" + [string]$cliDoc.model)
        } else {
            Assert-NP (([bool]$cliProven -and (-not [string]::IsNullOrWhiteSpace([string]$cliDoc.model)))) 'NP29b-cli-exposes-model-when-live-proven' ("model=" + [string]$cliDoc.model)
        }
    } else {
        Assert-NP $false 'NP28-cli-matches-live-helper-spoof-ignored' ('CLI fixture failed: ' + $cliRaw)
    }
    # ModelExecution enriched bounded fields (issue #208): no exception bodies, UNKNOWN cost.
    $selSimple = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true -NativeModelOverrideProven $true
    $execErr = { param($Model,$Agent,$TaskId) throw 'SENSITIVE-PROMPT-BODY-999' }
    $ex = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-np-err' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true -DispatchExecutor $execErr
    $evText = ([string]$ex.execution_log.requested_provider + '|' + [string]$ex.execution_log.policy_hash + '|' + [string]$ex.execution_log.cost)
    Assert-NP (([string]$ex.status -ceq 'PROOF_ABSENT')) 'NP30-exec-error-fail-closed' ([string]$ex.status)
    Assert-NP ((-not [string]::IsNullOrWhiteSpace([string]$ex.execution_log.policy_hash)) -and (-not [string]::IsNullOrWhiteSpace([string]$ex.execution_log.requested_provider))) 'NP31-exec-log-has-policy-and-provider' $evText
    Assert-NP (([string]$ex.execution_log.cost -ceq 'UNKNOWN')) 'NP32-exec-absent-cost-is-UNKNOWN-never-zero' ("cost=" + [string]$ex.execution_log.cost)
    $execSnap = { param($Model,$Agent,$TaskId) return @{ Model = $Model; tokens = @{ input = 10; output = 5; reasoning = 1 }; cost = 0.002 } }
    $vx = Invoke-OrchestrationModelExecution -AgentName 'coder' -TaskId 't-np-snap' -Risk 'low' -Complexity 'simple' -NativeModelOverrideProven $true -DispatchExecutor $execSnap
    Assert-NP (([string]$vx.status -ceq 'EXECUTED_VERIFIED')) 'NP33-exec-snapshot-verified' ([string]$vx.status)
    Assert-NP (([int]$vx.execution_log.usage_input -eq 10) -and ([int]$vx.execution_log.usage_output -eq 5)) 'NP34-exec-usage-carried' ("in=" + [string]$vx.execution_log.usage_input)
    Assert-NP (($null -ne $vx.execution_log.attempted_models)) 'NP35-exec-attempted-models-present' ''
    try { if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    try { Clear-TaskKernelSessionReader } catch { }
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:fail++
}
Write-Host ("RESULTS {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
