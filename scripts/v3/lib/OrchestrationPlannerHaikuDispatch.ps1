<#
.SYNOPSIS
    Planner Haiku productive dispatch: model-select -> single session -> evidence.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PowerShell 5.1 compatible. ASCII-only.
    Connects task-kernel model-select to a productive Planner session caller:
      1. Claims a run idempotency ledger entry (exactly-once: a second call with
         the same RunId is refused, never dispatched).
      2. Creates (or reuses) the kernel task with the Planner-supplied
         immutable verification plan (non-empty profiles + criteria required).
      3. Runs the pre-run Claude capability probe (local 'claude' executable +
         `opencode models` inventory listing claude-agent/haiku), recorded in
         the ledger. No session exists yet at this point.
      4. Selects the Planner model in-process via Resolve-OrchestrationModelSelection
         (role build: primary claude-agent/haiku T2). A blank model (override
         unproven) fails closed with MODEL_OVERRIDE_UNPROVEN and no dispatch.
      5. Dispatches EXACTLY ONE `opencode run` session with the selected
         provider/model (or the policy Luna fallback when the probe
         demonstrated Haiku unavailable pre-run). Timeout, provider error,
         missing telemetry, ambiguous outcome or caller-supplied no-start
         yield UNKNOWN/PROOF_ABSENT with no retry and no fallback.
      6. Records session/message evidence via Set-OrchestrationTaskModelAttempt
         (independently observed), a candidate_pass worker result carrying the
         session:/message: refs, and runs verify-run against the committed plan.
      7. Returns the pending-review state: independent review (a reviewer
         session distinct from the producer) and DONE stay Planner-owned; the
         kernel refuses self-review (SELF_REVIEW_FORBIDDEN).
    Cost for claude-agent subscription reports is recorded UNKNOWN, never zero.
    Productive execution (a real dispatched session) is Planner-owned: this
    library performs no inference by itself; tests inject -DispatchExecutor and
    -CapabilityProbe seams plus an isolated session reader.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Test-PlannerHaikuPreRunCapability {
    <#
    .SYNOPSIS
        Pre-run Claude capability probe (read-only, no inference).
    .DESCRIPTION
        Observes (never asserts): local 'claude' executable on PATH plus the
        `opencode models` inventory listing claude-agent/haiku. A custom
        -CapabilityProbe scriptblock may replace both observations in tests;
        it must return @{ executable_found = [bool]; inventory_lists_haiku = [bool] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [scriptblock]$CapabilityProbe = $null
    )
    if ($null -ne $CapabilityProbe) {
        try { return (& $CapabilityProbe) } catch { return @{ executable_found = $false; inventory_lists_haiku = $false; reason = 'probe-error' } }
    }
    $exeFound = $false
    try { $exeFound = ($null -ne (Get-Command 'claude' -ErrorAction SilentlyContinue)) } catch { $exeFound = $false }
    $inInventory = $false
    try {
        $bin = if ($IsWindows -or $env:OS -like '*Windows*') { 'opencode.cmd' } else { 'opencode' }
        $raw = & $bin models 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            foreach ($line in ($raw -split "`r?`n")) {
                if (([string]$line).Trim() -ceq 'claude-agent/haiku') { $inInventory = $true; break }
            }
        }
    } catch { $inInventory = $false }
    $reason = 'HAIKU_CAPABILITY_PROVEN'
    if (-not $exeFound) { $reason = 'HAIKU_EXECUTABLE_MISSING' }
    elseif (-not $inInventory) { $reason = 'HAIKU_NOT_IN_CATALOG' }
    return @{ executable_found = [bool]$exeFound; inventory_lists_haiku = [bool]$inInventory; reason = $reason }
}

function Invoke-PlannerHaikuNativeRun {
    <#
    .SYNOPSIS
        Default productive dispatch seam: exactly one `opencode run` call.
    .DESCRIPTION
        Single `opencode run --agent build --model <model> --format json` call
        with a bounded timeout. No retry, no fallback, no second call. Returns
        a result contract the caller records honestly (success or fail-closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Title = '',
        [int]$TimeoutMs = 600000
    )
    $bin = if ($IsWindows -or $env:OS -like '*Windows*') { 'opencode.cmd' } else { 'opencode' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    $argList = @('run', '--format', 'json', '--agent', 'build')
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $argList += @('--model', $Model) }
    if (-not [string]::IsNullOrWhiteSpace($Title)) { $argList += @('--title', $Title) }
    $argList += $Prompt
    $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '[\s"]') { "`"$($_ -replace '"', '\"')`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch {
        return @{ ok = $false; failure_class = 'DISPATCH_SPAWN_FAILED'; session_id = $null; elapsed_ms = $sw.ElapsedMilliseconds }
    }
    try { $proc.StandardInput.Close() } catch { }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $completed = $proc.WaitForExit($TimeoutMs)
    $sw.Stop()
    $stdout = ''; $stderr = ''
    try { if ($stdoutTask.Wait(5000)) { $stdout = $stdoutTask.GetAwaiter().GetResult() } } catch { }
    try { if ($stderrTask.Wait(5000)) { $stderr = $stderrTask.GetAwaiter().GetResult() } } catch { }
    if (-not $completed) {
        try { $proc.Kill() } catch { }
        return @{ ok = $false; failure_class = 'TIMEOUT_AMBIGUOUS'; session_id = $null; elapsed_ms = $sw.ElapsedMilliseconds; raw_excerpt = (($stdout + "`n" + $stderr).Trim()) }
    }
    $exitCode = $proc.ExitCode
    $combined = ($stdout + "`n" + $stderr).Trim()
    if ($exitCode -ne 0) {
        $cls = 'PROVIDER_ERROR'
        if ($combined -match 'usage_limit_exceeded|usage_limit_reached|subscription_sharing_usage_limit_exceeded|resource_exhausted|provider\.quota|The usage limit') { $cls = 'QUOTA_EXCEEDED' }
        elseif ($combined -match 'rate_limit|RATE_LIMIT|429') { $cls = 'RATE_LIMIT' }
        elseif ($combined -match 'MODEL_UNAVAILABLE|model_not_found|not found') { $cls = 'MODEL_UNAVAILABLE' }
        return @{ ok = $false; failure_class = $cls; session_id = $null; elapsed_ms = $sw.ElapsedMilliseconds; exit_code = $exitCode }
    }
    $sid = $null
    if ($combined -match '"sessionID"\s*:\s*"(ses_[a-zA-Z0-9_-]+)"') { $sid = $matches[1] }
    return @{ ok = $true; session_id = $sid; elapsed_ms = $sw.ElapsedMilliseconds; exit_code = $exitCode }
}

function Invoke-PlannerHaikuDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Objective,
        [string[]]$VerificationProfiles = $null,
        [string[]]$AcceptanceCriteria = $null,
        [string]$RunId = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$PolicyPath = '',
        [string]$RunLedgerDir = '',
        [string]$EvidenceOut = '',
        [int]$TimeoutMs = 600000,
        [scriptblock]$DispatchExecutor = $null,
        [scriptblock]$CapabilityProbe = $null,
        $NativeModelOverrideProven = $null,
        [string]$ExpectedModel = '',
        [string]$BaseRevision = ''
    )
    $libDir = $PSScriptRoot
    try { . (Join-Path $libDir 'OrchestrationModelRouter.ps1') } catch { return [pscustomobject]@{ ok = $false; status = 'ROUTER_LOAD_FAILED'; reason = 'model router library failed to load' } }
    try { . (Join-Path $libDir 'OrchestrationTaskKernel.ps1') } catch { return [pscustomobject]@{ ok = $false; status = 'KERNEL_LOAD_FAILED'; reason = 'task kernel library failed to load' } }

    $tid = ([string]$TaskId).Trim()
    $runId = ([string]$RunId).Trim()
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = $tid }
    $profList = @($VerificationProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($profList.Count -lt 1) {
        return [pscustomobject]@{ ok = $false; status = 'PLAN_REQUIRED'; reason = 'non-empty VerificationProfiles required (scoped verify-run plan is immutable at creation)' }
    }
    $critList = @($AcceptanceCriteria | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($critList.Count -lt 1) {
        return [pscustomobject]@{ ok = $false; status = 'PLAN_REQUIRED'; reason = 'non-empty AcceptanceCriteria required (verify-run criterion coverage)' }
    }

    $canonTasks = ''; $canonFlags = ''; $canonRoot = ''; $canonPol = ''
    try { $canonTasks = Get-TaskKernelDefaultTasksDir -RepoRoot '' } catch { $canonTasks = '' }
    try { $canonFlags = Get-TaskKernelDefaultFlagsPath -RepoRoot '' } catch { $canonFlags = '' }
    try { $canonRoot = Get-TaskKernelRepoRoot -RepoRoot '' } catch { $canonRoot = '' }
    try { $canonPol = Get-TaskKernelModelPolicyDefaultPath -RepoRoot '' } catch { $canonPol = '' }
    $effTasks = if ([string]::IsNullOrWhiteSpace($TasksDir)) { $canonTasks } else { [string]$TasksDir }
    $effFlags = if ([string]::IsNullOrWhiteSpace($FlagsPath)) { $canonFlags } else { [string]$FlagsPath }
    $effRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $canonRoot } else { [string]$RepoRoot }
    $effPol = if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $canonPol } else { [string]$PolicyPath }
    $ledgerDir = if ([string]::IsNullOrWhiteSpace($RunLedgerDir)) { Join-Path (Split-Path $effTasks -Parent) 'planner-haiku-runs' } else { [string]$RunLedgerDir }
    try { if (-not (Test-Path -LiteralPath $ledgerDir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($ledgerDir) } } catch {
        return [pscustomobject]@{ ok = $false; status = 'LEDGER_UNAVAILABLE'; reason = 'run ledger directory cannot be created' }
    }
    $safeRun = ($runId -replace '[^a-zA-Z0-9._-]', '_')
    $ledgerFile = Join-Path $ledgerDir ($safeRun + '.json')
    if (Test-Path -LiteralPath $ledgerFile -PathType Leaf) {
        return [pscustomobject]@{ ok = $false; status = 'DUPLICATE_RUN_REFUSED'; reason = 'RunId already claimed: exactly-once, no second dispatch'; run_id = $runId }
    }

    $polRes = Get-OrchestrationModelRoutingPolicy -PolicyPath $effPol
    if ($polRes.Status -ne 'POLICY_LOADED') {
        return [pscustomobject]@{ ok = $false; status = 'POLICY_UNAVAILABLE'; reason = 'routing policy failed to load' }
    }
    $polHash = [string]$polRes.PolicyHash
    $polVer = [string]$polRes.PolicyVersion

    # Base revision for the committed plan: explicit or current repo HEAD.
    $effBase = ([string]$BaseRevision).Trim()
    if ([string]::IsNullOrWhiteSpace($effBase)) {
        try {
            $gitOut = & git -C $effRoot rev-parse HEAD 2>&1 | Out-String
            $effBase = ([string]$gitOut).Trim()
        } catch { $effBase = '' }
        if ([string]::IsNullOrWhiteSpace($effBase)) {
            return [pscustomobject]@{ ok = $false; status = 'BASE_REVISION_UNRESOLVED'; reason = 'repo HEAD could not be resolved for the verification plan'; run_id = $runId; task_id = $tid; policy_hash = $polHash }
        }
    }

    # Intent first: create (or reuse) the kernel task with the committed plan.
    $createArgs = @{
        TaskId = $tid; Objective = ([string]$Objective); TaskType = 'implementation'; Risk = 'medium'
        Actor = 'planner-dispatch'; RuntimeId = 'opencode-v2'; RuntimeGeneration = 2; RuntimeProfile = 'v2'
        BaseRevision = $effBase; AcceptanceCriteria = $critList; VerificationProfiles = $profList
        TasksDir = $effTasks; FlagsPath = $effFlags
    }
    $created = New-OrchestrationTask @createArgs
    $rev = -1
    if ([bool]$created.ok) { $rev = [int]$created.revision }
    else {
        $existing = Get-OrchestrationTask -TaskId $tid -TasksDir $effTasks
        $found = $false
        try { $found = ($null -ne $existing -and $null -eq $existing.PSObject.Properties['error']) } catch { $found = $false }
        if (-not $found) {
            return [pscustomobject]@{ ok = $false; status = 'TASK_CREATE_FAILED'; reason = 'kernel task intent could not be recorded' }
        }
        try {
            if ($null -ne $existing['model_attempts'] -and (@($existing['model_attempts'])).Count -gt 0) {
                return [pscustomobject]@{ ok = $false; status = 'DUPLICATE_RUN_REFUSED'; reason = 'task already carries a model attempt: exactly-once, no second dispatch'; run_id = $runId }
            }
        } catch { }
        try { $rev = [int]$existing['revision'] } catch { $rev = -1 }
    }

    # Claim the run BEFORE any session exists (exactly-once).
    $claim = [ordered]@{ run_id = $runId; task_id = $tid; status = 'claimed'; claimed_at = ([DateTime]::UtcNow).ToString('o'); policy_hash = $polHash; policy_version = $polVer; task_revision = $rev }
    # Atomic exclusive claim: FileMode.CreateNew fails if another caller won the
    # race between the existence check above and this write (exactly-once).
    $claimBytes = [System.Text.Encoding]::UTF8.GetBytes(($claim | ConvertTo-Json -Depth 6 -Compress))
    try {
        $claimStream = New-Object System.IO.FileStream($ledgerFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $claimStream.Write($claimBytes, 0, $claimBytes.Length) } finally { $claimStream.Dispose() }
    } catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $ledgerFile -PathType Leaf) {
            return [pscustomobject]@{ ok = $false; status = 'DUPLICATE_RUN_REFUSED'; reason = 'RunId claimed by a concurrent caller: exactly-once, no second dispatch'; run_id = $runId }
        }
        return [pscustomobject]@{ ok = $false; status = 'LEDGER_UNAVAILABLE'; reason = 'run claim could not be persisted' }
    } catch {
        return [pscustomobject]@{ ok = $false; status = 'LEDGER_UNAVAILABLE'; reason = 'run claim could not be persisted' }
    }

    # Pre-run capability probe (read-only): no session exists yet.
    $probe = Test-PlannerHaikuPreRunCapability -CapabilityProbe $CapabilityProbe
    $probeAvailable = $false
    try { $probeAvailable = ([bool]$probe.executable_found) -and ([bool]$probe.inventory_lists_haiku) } catch { $probeAvailable = $false }
    $probeReason = ''
    try { $probeReason = [string]$probe.reason } catch { $probeReason = '' }

    # Live native-override proof (read-only /api/info); tests may pin it.
    $proven = $false
    if ($null -ne $NativeModelOverrideProven) { $proven = [bool]$NativeModelOverrideProven }
    else {
        try { $np = Test-OrchestrationNativeModelOverrideProof; $proven = [bool]$np.ok } catch { $proven = $false }
    }

    # Selection: Planner/build primary is claude-agent/haiku T2.
    $sel = $null
    try { $sel = Resolve-OrchestrationModelSelection -AgentName 'build' -TaskId $tid -TasksDir $effTasks -RepoRoot $effRoot -PolicyPath $effPol -IgnoreUserConfig $true -NativeModelOverrideProven $proven } catch { $sel = $null }
    if (($null -eq $sel) -or ([string]$sel.Status -cne 'SELECTED')) {
        return [pscustomobject]@{ ok = $false; status = 'MODEL_SELECTION_FAILED'; reason = 'router selection failed'; run_id = $runId; task_id = $tid; policy_hash = $polHash }
    }
    if (([string]$sel.Tier -cne 'T2') -or ([string]$sel.CatalogModel -cne 'claude-agent/haiku')) {
        return [pscustomobject]@{ ok = $false; status = 'MODEL_SELECTION_FAILED'; reason = 'planner selection diverged from Haiku T2 primary'; run_id = $runId; task_id = $tid; policy_hash = $polHash }
    }
    if (-not $proven -or [string]::IsNullOrWhiteSpace([string]$sel.CatalogModel)) {
        return [pscustomobject]@{ ok = $false; status = 'MODEL_OVERRIDE_UNPROVEN'; reason = 'native model override unproven: no dispatch without router model'; run_id = $runId; task_id = $tid; policy_hash = $polHash }
    }

    # Effective model: Haiku, or policy Luna fallback on demonstrated pre-run
    # unavailability. Nothing else is ever dispatched for build.
    $effective = 'claude-agent/haiku'
    $usedFallback = $false
    if (-not $probeAvailable) {
        $fb = $null
        try {
            $fb = Resolve-OrchestrationModelFallback -RequestedSelection $sel -FailedModel 'claude-agent/haiku' -TriggerReason 'PRE_RUN_UNAVAILABLE' -IgnoreUserConfig $true -HaikuPreRunUnavailable $true -TasksDir $effTasks -RepoRoot $effRoot -PolicyPath $effPol
        } catch { $fb = $null }
        if (($null -eq $fb) -or ([string]$fb.Status -cne 'AUTHORIZED') -or ([string]$fb.FallbackModel -cne 'openai/gpt-6-luna')) {
            return [pscustomobject]@{ ok = $false; status = 'FALLBACK_REFUSED'; reason = 'pre-run unavailability without authorized Luna fallback'; run_id = $runId; task_id = $tid; policy_hash = $polHash; probe_reason = $probeReason }
        }
        $effective = [string]$fb.FallbackModel
        $usedFallback = $true
    }
    $effProv = Get-ModelProviderFromId $effective
    $expTrim = ([string]$ExpectedModel).Trim()
    if (-not [string]::IsNullOrWhiteSpace($expTrim) -and ($effective -cne $expTrim)) {
        return [pscustomobject]@{ ok = $false; status = 'MODEL_MISMATCH'; reason = 'effective model diverged from task-kernel model-select output: no dispatch'; run_id = $runId; task_id = $tid; policy_hash = $polHash; model = $effective; expected_model = $expTrim }
    }

    # Exactly ONE dispatch. No retry, no fallback, no second call.
    $title = ('planner-haiku:' + $runId)
    $prompt = ([string]$Objective)
    $dr = $null
    try {
        if ($null -ne $DispatchExecutor) {
            $dr = (& $DispatchExecutor -Model $effective -Agent 'build' -Prompt $prompt -Title $title -TimeoutMs $TimeoutMs)
        } else {
            $dr = (Invoke-PlannerHaikuNativeRun -Model $effective -Prompt $prompt -Title $title -TimeoutMs $TimeoutMs)
        }
    } catch { $dr = $null }
    $drOk = $false
    try { $drOk = [bool]$dr.ok } catch { $drOk = $false }
    $drSid = ''
    try { if ($null -ne $dr.session_id) { $drSid = ([string]$dr.session_id).Trim() } } catch { $drSid = '' }
    if ((-not $drOk) -or [string]::IsNullOrWhiteSpace($drSid)) {
        $fcls = 'TELEMETRY_MISSING'
        try { if ($null -ne $dr.failure_class -and -not [string]::IsNullOrWhiteSpace([string]$dr.failure_class)) { $fcls = ([string]$dr.failure_class).Trim() } } catch { }
        if ($fcls -cnotmatch '^[A-Z][A-Z0-9_]{1,63}$') { $fcls = 'DISPATCH_FAILED' }
        return [pscustomobject]@{ ok = $false; status = 'PROOF_ABSENT'; reason = $fcls; run_id = $runId; task_id = $tid; policy_hash = $polHash; model = $effective; provider = $effProv; tier = 'T2'; fallback_used = $usedFallback; probe_reason = $probeReason; cost = 'UNKNOWN' }
    }

    # Independently-observed session evidence (seam in tests, native API reads
    # in production). No dispatch has a second chance: observation failure,
    # unverified parent, or missing completion all fail closed here.
    $obsSlot = $null
    try { $obsSlot = Invoke-TaskKernelSessionObservation -ChildSessionId $drSid } catch { $obsSlot = $null }
    $obsOk = $false
    try { $obsOk = [bool]$obsSlot.ok } catch { $obsOk = $false }
    if (-not $obsOk) {
        $obsErr = 'SESSION_OBSERVATION_FAILED'
        try { if ($null -ne $obsSlot.error -and -not [string]::IsNullOrWhiteSpace([string]$obsSlot.error)) { $obsErr = ([string]$obsSlot.error).Trim() } } catch { }
        if ($obsErr -cnotmatch '^[A-Z][A-Z0-9_]{1,63}$') { $obsErr = 'SESSION_OBSERVATION_FAILED' }
        return [pscustomobject]@{ ok = $false; status = 'PROOF_ABSENT'; reason = $obsErr; run_id = $runId; task_id = $tid; policy_hash = $polHash; model = $effective; provider = $effProv; tier = 'T2'; fallback_used = $usedFallback; probe_reason = $probeReason; cost = 'UNKNOWN' }
    }
    $obs = $null
    try { $obs = $obsSlot.observation } catch { $obs = $null }
    $obsSid = ''; $obsParent = ''; $obsMsgId = ''; $obsProv = ''; $obsModel = ''
    $obsTokIn = 'UNKNOWN'; $obsTokOut = 'UNKNOWN'; $obsCost = 'UNKNOWN'
    try {
        if ($null -ne $obs) {
            if ($null -ne $obs['session_id']) { $obsSid = ([string]$obs['session_id']).Trim() }
            if ($null -ne $obs['parent_session_id']) { $obsParent = ([string]$obs['parent_session_id']).Trim() }
            if ($null -ne $obs['message_id']) { $obsMsgId = ([string]$obs['message_id']).Trim() }
            if ($null -ne $obs['model_provider']) { $obsProv = ([string]$obs['model_provider']).Trim() }
            if ($null -ne $obs['model_id']) { $obsModel = ([string]$obs['model_id']).Trim() }
            if ($null -ne $obs['usage_input']) { $obsTokIn = [int]$obs['usage_input'] }
            if ($null -ne $obs['usage_output']) { $obsTokOut = [int]$obs['usage_output'] }
            if ($null -ne $obs['cost']) { $obsCost = $obs['cost'] }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($obsSid) -or ($obsSid -cne $drSid) -or [string]::IsNullOrWhiteSpace($obsParent) -or [string]::IsNullOrWhiteSpace($obsMsgId)) {
        return [pscustomobject]@{ ok = $false; status = 'PROOF_ABSENT'; reason = 'SESSION_CORRELATION_INCOMPLETE'; run_id = $runId; task_id = $tid; policy_hash = $polHash; model = $effective; provider = $effProv; tier = 'T2'; fallback_used = $usedFallback; probe_reason = $probeReason; cost = 'UNKNOWN' }
    }
    if ([string]::IsNullOrWhiteSpace($obsModel)) { $obsModel = $effective }
    if ([string]::IsNullOrWhiteSpace($obsProv)) { $obsProv = Get-ModelProviderFromId $obsModel }
    if ($obsProv -ceq 'claude-agent') {
        try { $obsCost = Resolve-ClaudeAgentUsageCost -ReportedCost $obsCost } catch { $obsCost = 'UNKNOWN' }
    }

    # Bind the observed session to the run (root + worker), then record the
    # candidate carrying the observed session:/message: refs, then the
    # independently-observed model attempt. Revision is threaded CAS-style.
    $revNow = $rev
    try {
        $cur = Get-OrchestrationTask -TaskId $tid -TasksDir $effTasks
        if ($null -ne $cur) { $revNow = [int]$cur['revision'] }
    } catch { }
    # Run/session binding (kernel P27 pattern: bind root, detach, bind worker).
    # The run root is the observed parent; the dispatched session is the
    # worker. model-attempt requires exactly this attached correlation.
    $bindRoot = $null
    try { $bindRoot = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $obsParent -ParentId $obsParent -RootId $obsParent -ExpectedRevision $revNow -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $effTasks -FlagsPath $effFlags -RepoRoot $effRoot } catch { $bindRoot = $null }
    $bindOk = $false
    try { $bindOk = [bool]$bindRoot.ok; if ($bindOk) { $revNow = [int]$bindRoot.revision } } catch { $bindOk = $false }
    if (-not $bindOk) {
        return [pscustomobject]@{ ok = $false; status = 'BINDING_FAILED'; reason = 'session binding could not be recorded'; run_id = $runId; task_id = $tid; policy_hash = $polHash; session_id = $drSid; cost = 'UNKNOWN' }
    }
    $detachRoot = $null
    try { $detachRoot = Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId $tid -RunId $runId -SessionId $obsParent -ExpectedRevision $revNow -TasksDir $effTasks -FlagsPath $effFlags -RepoRoot $effRoot } catch { $detachRoot = $null }
    $detachOk = $false
    try { $detachOk = [bool]$detachRoot.ok; if ($detachOk) { $revNow = [int]$detachRoot.revision } } catch { $detachOk = $false }
    if (-not $detachOk) {
        return [pscustomobject]@{ ok = $false; status = 'BINDING_FAILED'; reason = 'run detach could not be recorded'; run_id = $runId; task_id = $tid; policy_hash = $polHash; session_id = $drSid; cost = 'UNKNOWN' }
    }
    $bindWorker = $null
    try { $bindWorker = Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $tid -RunId $runId -SessionId $drSid -ParentId $obsParent -RootId $obsParent -WorkerSession -ExpectedRevision $revNow -Runtime 'opencode-v2' -Version 'native-run' -TasksDir $effTasks -FlagsPath $effFlags -RepoRoot $effRoot } catch { $bindWorker = $null }
    $bindWOk = $false
    try { $bindWOk = [bool]$bindWorker.ok; if ($bindWOk) { $revNow = [int]$bindWorker.revision } } catch { $bindWOk = $false }
    if (-not $bindWOk) {
        return [pscustomobject]@{ ok = $false; status = 'BINDING_FAILED'; reason = 'worker session binding could not be recorded'; run_id = $runId; task_id = $tid; policy_hash = $polHash; session_id = $drSid; cost = 'UNKNOWN' }
    }
    $refs = @(('session:' + $drSid), ('message:' + $obsMsgId))
    $wres = $null
    try {
        $wres = Set-OrchestrationTaskWorkerResult -TaskId $tid -Status 'candidate_pass' -ClaimedEvidence $refs -ProducedBy 'build' -ExpectedRevision $revNow -TasksDir $effTasks -FlagsPath $effFlags
    } catch { $wres = $null }
    $wresOk = $false
    try { $wresOk = [bool]$wres.ok; if ($wresOk) { $revNow = [int]$wres.revision } } catch { $wresOk = $false }
    if (-not $wresOk) {
        $wErr = 'WORKER_RESULT_FAILED'
        try { if ($null -ne $wres.error -and -not [string]::IsNullOrWhiteSpace([string]$wres.error)) { $wErr = ([string]$wres.error).Trim() } } catch { }
        return [pscustomobject]@{ ok = $false; status = 'PROOF_ABSENT'; reason = $wErr; run_id = $runId; task_id = $tid; policy_hash = $polHash; session_id = $drSid; message_id = $obsMsgId; cost = 'UNKNOWN' }
    }
    $attempt = $null
    try { $attempt = Set-OrchestrationTaskModelAttempt -TaskId $tid -ChildSessionId $drSid -ExpectedRevision $revNow -TasksDir $effTasks -FlagsPath $effFlags -RepoRoot $effRoot -PolicyPath $effPol } catch { $attempt = $null }
    $attemptOk = $false
    $attemptErr = ''
    try { $attemptOk = [bool]$attempt.ok; if (-not $attemptOk -and $null -ne $attempt.error) { $attemptErr = ([string]$attempt.error).Trim() } } catch { $attemptOk = $false }
    try {
        $cur2 = Get-OrchestrationTask -TaskId $tid -TasksDir $effTasks
        if ($null -ne $cur2) { $revNow = [int]$cur2['revision'] }
    } catch { }
    if (-not $attemptOk) {
        if ([string]::IsNullOrWhiteSpace($attemptErr)) { $attemptErr = 'MODEL_ATTEMPT_FAILED' }
        return [pscustomobject]@{ ok = $false; status = 'PROOF_ABSENT'; reason = $attemptErr; run_id = $runId; task_id = $tid; policy_hash = $polHash; session_id = $drSid; message_id = $obsMsgId; provider = $obsProv; model = $obsModel; cost = $obsCost }
    }
    $vrun = $null
    try { $vrun = Invoke-TaskKernelVerifyRun -TaskId $tid -ExpectedRevision $revNow -TasksDir $effTasks -FlagsPath $effFlags -RepoRoot $effRoot } catch { $vrun = $null }
    $vrunOk = $false; $vrunStatus = ''
    try { $vrunOk = [bool]$vrun.ok } catch { }
    try { $vrunStatus = [string]$vrun.status } catch { }

    $record = [ordered]@{
        run_id = $runId; task_id = $tid; status = 'dispatched'; task_revision = $revNow
        policy_hash = $polHash; policy_version = $polVer
        session_id = $drSid; message_id = $obsMsgId
        provider = $obsProv; model = $obsModel; tier = 'T2'
        requested_model = 'claude-agent/haiku'; effective_model = $effective
        fallback_used = $usedFallback; probe_reason = $probeReason
        tokens_input = $obsTokIn; tokens_output = $obsTokOut; cost = $obsCost
        model_attempt_recorded = $attemptOk
        worker_result_recorded = $wresOk
        verify_run_ok = $vrunOk; verify_run_status = $vrunStatus
        review_state = 'pending-independent-review'
        dispatched_at = ([DateTime]::UtcNow).ToString('o')
    }
    try { [System.IO.File]::WriteAllText($ledgerFile, (($record | ConvertTo-Json -Depth 8 -Compress)), [System.Text.Encoding]::UTF8) } catch { }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceOut)) {
        try {
            $evDir = Split-Path $EvidenceOut -Parent
            if (-not [string]::IsNullOrWhiteSpace($evDir) -and -not (Test-Path -LiteralPath $evDir -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($evDir) }
            [System.IO.File]::WriteAllText($EvidenceOut, (($record | ConvertTo-Json -Depth 8)), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    return [pscustomobject]@{
        ok = ([bool]$attemptOk); status = 'DISPATCHED'; run_id = $runId; task_id = $tid
        policy_hash = $polHash; session_id = $drSid; message_id = $obsMsgId
        provider = $obsProv; model = $obsModel; tier = 'T2'
        tokens_input = $obsTokIn; tokens_output = $obsTokOut; cost = $obsCost
        fallback_used = $usedFallback; verify_run_status = $vrunStatus
        review_state = 'pending-independent-review'
    }
}
