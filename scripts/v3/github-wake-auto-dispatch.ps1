<#!
.SYNOPSIS
    Etapa 6D GH-WAKE auto dispatch: single-shot tick-to-worker bridge.
.DESCRIPTION
    Single-shot CLI, dot-source safe. Consumes ONE wake next_action
    envelope (object or file) and closes the gap between a scheduled wake
    tick and the next worker step WITHOUT manual Planner action:

      wake envelope -> Invoke-GHWakeControllerHandoff (prepare/claim/probe)
      -> pre-snapshot  (native children of the resume session)
      -> Invoke-OrchestrationNativeResume (ONE run, injectable executor)
      -> post-snapshot + native messages (same resume session)
      -> Find-GHWADNativeWorkerProof (P0 native gate)
      -> Set-GHWakeDispatchSettlement (NATIVE worker id only)

    Native proof (OpenCode v2.2.5, read-only API, no model call):
      `opencode api session.list --param parentID=<resume>`
        children carry id / parentID / agent / projectID / outcome /
        time.created. Pre-existing child ids are excluded by pre/post
        diff; a stale child (created before the run) is refused.
      `opencode api session.message.list --param sessionID=<resume>`
        assistant messages carry native tool parts
        {type=tool, name=subagent, id=call_..., state, time}: a NEW
        (created after the run started) part with state.status=completed
        identifies the invocation; the child id comes from
        state.metadata.sessionID (or state.input.sessionID); the
        operation binds through an EXACT prompt marker
        (ghw-op goal=<gid> task=<tid> gen=<gen> key=<key>, embedded by
        this driver in the resume prompt) followed by a short
        delegation directive (delegate via the native subagent tool,
        forward the marker exactly, require the worker JSON result,
        never substitute your own result) plus a STRUCTURED worker
        result: state.content must carry a parseable JSON object with
        task_id + goal_id + generation + idempotency_key compared
        EXACTLY against the current operation, status
        candidate_pass/failed/blocked, and criterion refs; the child
        outcome (succeeded => settle ok, failed => settle failed,
        missing/interrupted => unproven) completes the verdict.

    Fail-closed rules (stable reasons, ASCII-only):
      - Every refusal carries a stable reason; nothing is dispatched on
        doubt. proceed from resume is NEVER dispatched by itself
        (NATIVE_SESSION_RESUMED alone reconciles as auto-worker-unproven).
        Only a NATIVE worker proof (new child, parent-linked, operation
        bound, completed tool result with structured content) settles,
        with the NATIVE child id as settle_child_session_id.
      - Caller-supplied worker fields do not exist: there are NO caller
        worker identity inputs, and a mocked RunExecutor can never
        fabricate productive proof. An injected session-API transport
        (tests) is marked non-native: even a fully validating payload
        reconciles as auto-worker-non-native and never settles. A mocked
        resume WITHOUT an injected API transport is gated even earlier
        (before any native query and before any run): reconcile
        auto-worker-non-native with zero executor effect, so no
        mocked/test execution can ever reach Set-GHWakeDispatchSettlement.
      - Unknown effects reconcile without blind resend: resume actions
        timeout-unknown, resume-unproven, identity-diverged and
        session-not-found-post return decision reconcile, keep the claim
        marker, and never call the executor again in this pass. A null
        envelope or an exception escaping Invoke-OrchestrationNativeResume
        is the same reconcile case (auto-resume-internal-error): the claim
        marker is kept, never released, never settled, never rerun here.
      - Resume blocked (pre-check refusal, zero effect) releases the claim
        marker so a later tick can retry fresh; reconcile and settle
        refusals keep the claim for operator reconciliation.
      - Duplicate key never runs twice: a claimed marker returns
        duplicate-noop; an already-dispatched marker replays idempotently
        (settle-duplicate) from its OWN stored worker session, with no
        caller attestation and no new run.
      - The native transport may fail: pre/post snapshot or message read
        failures reconcile as auto-worker-api-unavailable (claim kept,
        no settle). A pre-snapshot failure is detected BEFORE the resume
        run, so no run happens without a sound pre/post comparison.
      - No second Planner, no second Kernel, no parallel executor, no new
        daemon/infra, no plugin, no global config: one pass, then exit.
        The ONLY effect is at most ONE resume run through the existing
        NativeResume adapter (real opencode run in production via the
        caller, mock RunExecutor in tests) plus read-only native API
        queries (real `opencode api` in production, injected invoker in
        tests, which never settles).
      - Idempotency reuses the existing claim-once marker
        (ghw-handoff-<key>.json) plus the SHA256 idempotency_key and the
        existing Prepare/Claim/Settle receipts. Nothing new is invented.

    PS 5.1 and PS7 compatible. ASCII-only. Offline testable: no gh, no
    network, no real opencode required when RunExecutor and the session
    API invoker are injected (injected transports never settle).

    Usage (CLI, production: real resume run, no mock):
      powershell -NoProfile -File github-wake-auto-dispatch.ps1 `
        -WakeEnvelopeFile <wake.json> -WaitsDir <dir> -TasksDir <dir> `
        -GoalStoreDir <dir> -CheckpointDir <dir> -FlagsPath <flags> `
        -ResumeSessionId <ses_id> -ExpectedDirectory <dir> `
        -ExpectedProjectId <proj> -PromptText '<kernel-built prompt>'

    Exit 0 = pass evaluated (dispatched/already-done/not-dispatched data).
    Exit 1 = reconcile or refusal needing the operator. Exit 2 = args.
    Stdout carries exactly one JSON envelope. Dot-source safe: without
    -WakeEnvelopeFile, -NextActionFile and -NextActionJson this file
    defines functions only.
#>
param(
    [string]$WakeEnvelopeFile = '',
    [string]$NextActionFile = '',
    [string]$NextActionJson = '',
    [string]$WaitsDir = '',
    [string]$TasksDir = '',
    [string]$GoalStoreDir = '',
    [string]$CheckpointDir = '',
    [string]$HandoffStateDir = '',
    [string]$ReceiptDir = '',
    [string]$RepoRoot = '',
    [string]$EvidenceStoreDir = '',
    [string]$FlagsPath = '',
    [string]$NowUtc = '',
    [string]$ResumeSessionId = '',
    [string]$ExpectedDirectory = '',
    [string]$ExpectedProjectId = '',
    [string]$PromptText = '',
    [string]$SettleResultSummary = 'gh-wake auto dispatch via native resume',
    [int]$ResumeTimeoutMs = 30000,
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

$GHWAD_SavedWakeEnvelopeFile = $WakeEnvelopeFile
$GHWAD_SavedNextActionFile = $NextActionFile
$GHWAD_SavedNextActionJson = $NextActionJson
$GHWAD_SavedWaitsDir = $WaitsDir
$GHWAD_SavedTasksDir = $TasksDir
$GHWAD_SavedGoalStoreDir = $GoalStoreDir
$GHWAD_SavedCheckpointDir = $CheckpointDir
$GHWAD_SavedHandoffStateDir = $HandoffStateDir
$GHWAD_SavedReceiptDir = $ReceiptDir
$GHWAD_SavedRepoRoot = $RepoRoot
$GHWAD_SavedEvidenceStoreDir = $EvidenceStoreDir
$GHWAD_SavedFlagsPath = $FlagsPath
$GHWAD_SavedNowUtc = $NowUtc
$GHWAD_SavedResumeSessionId = $ResumeSessionId
$GHWAD_SavedExpectedDirectory = $ExpectedDirectory
$GHWAD_SavedExpectedProjectId = $ExpectedProjectId
$GHWAD_SavedPromptText = $PromptText
$GHWAD_SavedSettleResultSummary = $SettleResultSummary
$GHWAD_SavedResumeTimeoutMs = $ResumeTimeoutMs
$GHWAD_SavedOutFile = $OutFile
. (Join-Path $PSScriptRoot 'github-wake.ps1')
$WakeEnvelopeFile = $GHWAD_SavedWakeEnvelopeFile
$NextActionFile = $GHWAD_SavedNextActionFile
$NextActionJson = $GHWAD_SavedNextActionJson
$WaitsDir = $GHWAD_SavedWaitsDir
$TasksDir = $GHWAD_SavedTasksDir
$GoalStoreDir = $GHWAD_SavedGoalStoreDir
$CheckpointDir = $GHWAD_SavedCheckpointDir
$HandoffStateDir = $GHWAD_SavedHandoffStateDir
$ReceiptDir = $GHWAD_SavedReceiptDir
$RepoRoot = $GHWAD_SavedRepoRoot
$EvidenceStoreDir = $GHWAD_SavedEvidenceStoreDir
$FlagsPath = $GHWAD_SavedFlagsPath
$NowUtc = $GHWAD_SavedNowUtc
$ResumeSessionId = $GHWAD_SavedResumeSessionId
$ExpectedDirectory = $GHWAD_SavedExpectedDirectory
$ExpectedProjectId = $GHWAD_SavedExpectedProjectId
$PromptText = $GHWAD_SavedPromptText
$SettleResultSummary = $GHWAD_SavedSettleResultSummary
$ResumeTimeoutMs = $GHWAD_SavedResumeTimeoutMs
$OutFile = $GHWAD_SavedOutFile
$GHWAD_ResumeLib = Join-Path $PSScriptRoot 'lib\OrchestrationNativeResume.ps1'
if (Test-Path -LiteralPath $GHWAD_ResumeLib -PathType Leaf) { . $GHWAD_ResumeLib }
Remove-Variable -Name GHWAD_SavedWakeEnvelopeFile, GHWAD_SavedNextActionFile, GHWAD_SavedNextActionJson, GHWAD_SavedWaitsDir, GHWAD_SavedTasksDir, GHWAD_SavedGoalStoreDir, GHWAD_SavedCheckpointDir, GHWAD_SavedHandoffStateDir, GHWAD_SavedReceiptDir, GHWAD_SavedRepoRoot, GHWAD_SavedEvidenceStoreDir, GHWAD_SavedFlagsPath, GHWAD_SavedNowUtc, GHWAD_SavedResumeSessionId, GHWAD_SavedExpectedDirectory, GHWAD_SavedExpectedProjectId, GHWAD_SavedPromptText, GHWAD_SavedSettleResultSummary, GHWAD_SavedResumeTimeoutMs, GHWAD_SavedOutFile, GHWAD_ResumeLib -ErrorAction SilentlyContinue

function Get-GHWADValue {
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

function Read-GHWADJsonFile {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $fi = Get-Item -LiteralPath $Path -Force
        if ([long]$fi.Length -le 0 -or [long]$fi.Length -gt 262144) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function Test-GHWADSessionId {
    param([string]$SessionId = '')
    try {
        $s = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s -match 'continue') { return $false }
        return ($s -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Test-GHWADNativeSessionId {
    # Strict native id shape for API embedding: ^ses_[A-Za-z0-9]+$
    # without any 'continue' marker. Shape only, never proof.
    param([string]$SessionId = '')
    try {
        $s = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s -match 'continue') { return $false }
        return ($s -cmatch '^ses_[A-Za-z0-9]+$')
    }
    catch { return $false }
}

function New-GHWADOperationMarker {
    # Exact textual operation token embedded by THIS driver in the resume
    # prompt so the Planner can forward it to the worker: the worker's
    # structured result must echo these identities back EXACTLY.
    # Format: ghw-op goal=<gid> task=<tid> gen=<gen> key=<key>.
    # Fail-closed: any component outside its strict alphabet returns ''.
    param(
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$Generation = '',
        [string]$IdempotencyKey = ''
    )
    try {
        $g = (([string]$GoalId).Trim())
        $t = (([string]$TaskId).Trim())
        $gen = (([string]$Generation).Trim())
        $key = (([string]$IdempotencyKey).Trim().ToLowerInvariant())
        if (($g -cnotmatch '^[A-Za-z0-9._-]{1,128}$') -or ($t -cnotmatch '^[A-Za-z0-9._-]{1,128}$')) { return '' }
        if (($gen -cnotmatch '^[0-9]{1,10}$') -or ($key -cnotmatch '^[a-f0-9]{32}$')) { return '' }
        return ('ghw-op goal=' + $g + ' task=' + $t + ' gen=' + $gen + ' key=' + $key)
    }
    catch { return '' }
}

function Get-GHWADWorkerDirective {
    # Short Planner instruction appended after the operation marker. It
    # tells the resumed Planner to delegate via the native subagent
    # tool, forward the marker exactly, and require the worker result
    # object the parser enforces — the Planner must never substitute
    # its own result. Fixed ASCII text inside the NativeResume prompt
    # gate charset; the driver fail-closes when the final prompt cannot
    # travel. Never throws.
    [CmdletBinding()]
    param()
    try {
        return 'Delegate via the native subagent tool. Forward the marker exactly. Require the worker to return one JSON object with task_id, goal_id, generation, idempotency_key, status of candidate_pass failed blocked, claimed_evidence as criterion refs. Never substitute your own result for the worker result.'
    }
    catch { return '' }
}

function Test-GHWADPromptFits {
    # Mirrors the Invoke-OrchestrationNativeResume prompt gate (fail-closed
    # charset + 2000-char bound) so a marker-augmented prompt that cannot
    # travel is refused BEFORE any run. Never throws.
    param([string]$PromptText = '')
    try {
        $p = ([string]$PromptText)
        if ([string]::IsNullOrWhiteSpace($p) -or ($p.Length -gt 2000)) { return $false }
        if ($p.Contains('`')) { return $false }
        if ($p.Contains([string][char]13) -or $p.Contains([string][char]10)) { return $false }
        if ($p -match '[&|<>^%!;$\(\)"]') { return $false }
        return $true
    }
    catch { return $false }
}

function Find-GHWADWorkerResultObject {
    # Pure parser over native tool-result text (no IO, never throws).
    # Extracts a STRUCTURED worker result object: tries the full text,
    # then ```json fenced blocks, then brace-balanced spans containing
    # "task_id". The first object validating EXACTLY against the current
    # operation wins: task_id/goal_id/generation/idempotency_key exact
    # match, status in candidate_pass/failed/blocked, claimed_evidence
    # refs criterion:<idx> (same shape the dispatch settle path enforces).
    # verified_pass/done/approved or any adulterated field never validates.
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [string]$ExpectedTaskId = '',
        [string]$ExpectedGoalId = '',
        [string]$ExpectedGeneration = '',
        [string]$ExpectedIdempotencyKey = ''
    )
    $mkRes = {
        param([bool]$Ok, [string]$Status, $Refs)
        return [pscustomobject]@{ ok = [bool]$Ok; status = ([string]$Status); refs = @($Refs) }
    }
    try {
        $expTask = (([string]$ExpectedTaskId).Trim())
        $expGoal = (([string]$ExpectedGoalId).Trim())
        $expGen = (([string]$ExpectedGeneration).Trim())
        $expKey = (([string]$ExpectedIdempotencyKey).Trim().ToLowerInvariant())
        if ([string]::IsNullOrWhiteSpace($expTask) -or [string]::IsNullOrWhiteSpace($expGoal) -or `
            [string]::IsNullOrWhiteSpace($expGen) -or [string]::IsNullOrWhiteSpace($expKey)) {
            return (& $mkRes -Ok $false -Status '' -Refs @())
        }
        $txt = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($txt) -or ($txt.Length -gt 65536)) {
            return (& $mkRes -Ok $false -Status '' -Refs @())
        }
        $cands = @()
        $trimmed = $txt.Trim()
        if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) { $cands += @($trimmed) }
        try {
            $fence = [regex]::Matches($txt, '```(?:json)?\s*(.*?)\s*```', ([System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
            foreach ($fm in @($fence)) {
                if (@($cands).Count -ge 20) { break }
                try {
                    $fbody = (([string]$fm.Groups[1].Value).Trim())
                    if ((-not [string]::IsNullOrWhiteSpace($fbody)) -and ($fbody.Length -le 65536)) { $cands += @($fbody) }
                }
                catch { }
            }
        }
        catch { }
        if (@($cands).Count -lt 20) {
            try {
                $depth = 0
                $start = -1
                for ($i = 0; $i -lt $txt.Length; $i++) {
                    $ch = $txt[$i]
                    if ($ch -ceq '{') {
                        if ($depth -eq 0) { $start = $i }
                        $depth++
                    }
                    elseif ($ch -ceq '}') {
                        if ($depth -gt 0) {
                            $depth--
                            if (($depth -eq 0) -and ($start -ge 0)) {
                                $len = ($i - $start + 1)
                                if (($len -ge 16) -and ($len -le 8192) -and (@($cands).Count -lt 20)) {
                                    try {
                                        $span = $txt.Substring($start, $len)
                                        if ($span.Contains('"task_id"')) { $cands += @($span) }
                                    }
                                    catch { }
                                }
                                $start = -1
                            }
                        }
                    }
                }
            }
            catch { }
        }
        foreach ($cj in @($cands)) {
            $o = $null
            try { $o = ConvertFrom-Json $cj } catch { continue }
            if ($null -eq $o) { continue }
            $ot = (([string](Get-GHWADValue $o 'task_id' '')).Trim())
            $og = (([string](Get-GHWADValue $o 'goal_id' '')).Trim())
            $ogen = (([string](Get-GHWADValue $o 'generation' '')).Trim())
            $okey = (([string](Get-GHWADValue $o 'idempotency_key' '')).Trim().ToLowerInvariant())
            $ost = (([string](Get-GHWADValue $o 'status' '')).Trim().ToLowerInvariant())
            if (($ot -cne $expTask) -or ($og -cne $expGoal) -or ($ogen -cne $expGen) -or ($okey -cne $expKey)) { continue }
            if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $ost) { continue }
            $refs = @(Get-GHWADValue $o 'claimed_evidence' @())
            if (@($refs).Count -lt 1) { continue }
            $refsOk = $true
            foreach ($r in @($refs)) {
                if (($r -isnot [string]) -or (([string]$r).Trim() -cnotmatch '^criterion:[0-9]+$')) { $refsOk = $false; break }
            }
            if (-not [bool]$refsOk) { continue }
            return (& $mkRes -Ok $true -Status $ost -Refs @($refs | ForEach-Object { ([string]$_).Trim() }))
        }
        return (& $mkRes -Ok $false -Status '' -Refs @())
    }
    catch {
        return (& $mkRes -Ok $false -Status '' -Refs @())
    }
}

function Protect-GHWADDiag {
    param([string]$Text)
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        $t = ([string]$Text).Trim()
        if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
        return $t
    }
    catch { return '' }
}

function Invoke-GHWADApi {
    # Real native transport: `opencode api <operation> --param k=v ...`.
    # Operation-ID form (server-side filtering); the `api get <path>`
    # form ignores query params and MUST NOT be used here. Args are
    # fixed-shape plus strictly charset-validated values (no spaces,
    # quotes or shell metacharacters), the same category the
    # NativeSessionAdapter already runs through the cmd shim. The `&`
    # character never appears (params travel as --param pairs, never
    # embedded in a query string). Never throws: transport outcomes are
    # data (ok/timedOut/exit/stdout/stderr).
    [CmdletBinding()]
    param(
        [string]$Operation = '',
        [hashtable]$Params = @{},
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        $op = (([string]$Operation).Trim())
        if (@('session.list', 'session.get', 'session.message.list') -cnotcontains $op) {
            return [pscustomobject]@{ ok = $false; timedOut = $false; exit = -1; stdout = ''; stderr = 'OP_NOT_ALLOWED' }
        }
        $args = @('api', $op)
        foreach ($k in @($Params.Keys)) {
            $kn = (([string]$k).Trim())
            if (@('parentID', 'sessionID', 'limit', 'order') -cnotcontains $kn) {
                return [pscustomobject]@{ ok = $false; timedOut = $false; exit = -1; stdout = ''; stderr = 'PARAM_NOT_ALLOWED' }
            }
            $v = (([string]$Params[$k]).Trim())
            if ($v -cnotmatch '^[A-Za-z0-9_.-]{1,128}$') {
                return [pscustomobject]@{ ok = $false; timedOut = $false; exit = -1; stdout = ''; stderr = 'PARAM_VALUE_INVALID' }
            }
            $args += @('--param', ($kn + '=' + $v))
        }
        $resolved = ([string]$BinaryCommand).Trim()
        if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'opencode' }
        if ($resolved -ceq 'opencode') {
            $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
            if (-not $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
            if ($cmd) { $resolved = ([string]$cmd.Source) }
        }
        $useCmdShim = (($resolved -like '*.cmd') -or ($resolved -like '*.bat'))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($useCmdShim) {
            $psi.FileName = 'cmd.exe'
            $quoted = @()
            foreach ($a in $args) { $quoted += @('"' + (($a -replace '"', '""')) + '"') }
            $esc = ($resolved -replace '"', '""')
            $psi.Arguments = '/c ""' + $esc + '" ' + ($quoted -join ' ') + '"'
        }
        else {
            $psi.FileName = $resolved
            $quoted = @()
            foreach ($a in $args) {
                if ($a -match '[\s"]') { $quoted += @('"' + (($a -replace '"', '\"')) + '"') }
                else { $quoted += @($a) }
            }
            $psi.Arguments = ($quoted -join ' ')
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $ms = [int]$TimeoutMs
        if ($ms -lt 100) { $ms = 100 }
        $proc = $null
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch {
            return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('LAUNCH_ERROR:' + (Protect-GHWADDiag $_.Exception.Message)) }
        }
        try { $proc.StandardInput.Close() } catch { }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($ms)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ ok = $true; timedOut = $true; exit = -1; stdout = ''; stderr = 'TIMEOUT' }
        }
        $so = ''
        $se = ''
        try { $so = [string]$outTask.Result } catch { $so = '' }
        try { $se = [string]$errTask.Result } catch { $se = '' }
        return [pscustomobject]@{ ok = $true; timedOut = $false; exit = [int]$proc.ExitCode; stdout = $so; stderr = $se }
    }
    catch {
        return [pscustomobject]@{ ok = $false; timedOut = $false; exit = -1; stdout = ''; stderr = 'TRANSPORT_ERROR' }
    }
}

function Read-GHWADSessionApi {
    # One native read, real or injected. An injected ApiInvoker (tests)
    # returns synthetic payloads for reason-path coverage and is ALWAYS
    # marked native=$false: injected transports NEVER settle productive
    # state, even when the payload fully validates. Only the real
    # `opencode api` path yields native=$true. Never throws.
    [CmdletBinding()]
    param(
        [string]$Operation = '',
        [hashtable]$Params = @{},
        $ApiInvoker = $null,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        if ($null -ne $ApiInvoker) {
            $fake = $null
            try { $fake = & $ApiInvoker $Operation $Params }
            catch { $fake = $null }
            if (($null -eq $fake) -or (-not [bool](Get-GHWADValue $fake 'ok' $false))) {
                return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $false; body = $null }
            }
            $fb = Get-GHWADValue $fake 'body' $null
            if ($fb -is [string]) {
                try { $fb = ConvertFrom-Json $fb }
                catch { return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $false; body = $null } }
            }
            if ($null -eq $fb) {
                return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $false; body = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; native = $false; body = $fb }
        }
        $t = Invoke-GHWADApi -Operation $Operation -Params $Params -BinaryCommand $BinaryCommand -TimeoutMs $TimeoutMs
        if (($null -eq $t) -or (-not [bool](Get-GHWADValue $t 'ok' $false)) -or [bool](Get-GHWADValue $t 'timedOut' $false)) {
            return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $true; body = $null }
        }
        if ([int](Get-GHWADValue $t 'exit' -1) -ne 0) {
            return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $true; body = $null }
        }
        $raw = ([string](Get-GHWADValue $t 'stdout' ''))
        if ([string]::IsNullOrWhiteSpace($raw) -or ($raw.Length -gt 8388608)) {
            return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $true; body = $null }
        }
        $doc = $null
        try { $doc = ConvertFrom-Json $raw }
        catch { $doc = $null }
        if ($null -eq $doc) {
            return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $true; body = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; native = $true; body = $doc }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; native = $false; body = $null }
    }
}

function Get-GHWADChildSnapshot {
    # Native children of ONE resume session. Every entry is filtered
    # client-side (parentID -ceq resume): the server filter is a
    # convenience, never the proof. Divergent entries are ignored, not
    # trusted. Never throws.
    [CmdletBinding()]
    param(
        [string]$ResumeSessionId = '',
        $ApiInvoker = $null,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    $mkSnap = {
        param([bool]$Ok, [string]$Reason)
        return [pscustomobject]@{ ok = [bool]$Ok; reason = ([string]$Reason); ids = @(); byId = @{} }
    }
    try {
        $resume = (([string]$ResumeSessionId).Trim())
        if (-not (Test-GHWADNativeSessionId -SessionId $resume)) {
            return (& $mkSnap -Ok $false -Reason 'auto-worker-api-unavailable')
        }
        $rd = Read-GHWADSessionApi -Operation 'session.list' -Params @{ parentID = $resume; limit = '200' } -ApiInvoker $ApiInvoker -BinaryCommand $BinaryCommand -TimeoutMs $TimeoutMs
        if (($null -eq $rd) -or (-not [bool](Get-GHWADValue $rd 'ok' $false))) {
            $why = 'auto-worker-api-unavailable'
            try {
                $wr = ([string](Get-GHWADValue $rd 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($wr)) { $why = $wr }
            }
            catch { }
            return (& $mkSnap -Ok $false -Reason $why)
        }
        $data = Get-GHWADValue (Get-GHWADValue $rd 'body' $null) 'data' @()
        $ids = @()
        $byId = @{}
        foreach ($s in @($data)) {
            if ($null -eq $s) { continue }
            $cid = (([string](Get-GHWADValue $s 'id' '')).Trim())
            if (-not (Test-GHWADNativeSessionId -SessionId $cid)) { continue }
            $par = (([string](Get-GHWADValue $s 'parentID' '')).Trim())
            if ($par -cne $resume) { continue }
            if ($byId.ContainsKey($cid)) { continue }
            $byId[$cid] = $s
            $ids += @($cid)
        }
        $out = (& $mkSnap -Ok $true -Reason '')
        $out.ids = $ids
        $out.byId = $byId
        return $out
    }
    catch {
        return (& $mkSnap -Ok $false -Reason 'auto-worker-api-unavailable')
    }
}

function Get-GHWADResumeMessages {
    # Native messages of ONE resume session, newest first. Raw objects;
    # validation happens in Find-GHWADNativeWorkerProof. Never throws.
    [CmdletBinding()]
    param(
        [string]$ResumeSessionId = '',
        $ApiInvoker = $null,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        $resume = (([string]$ResumeSessionId).Trim())
        if (-not (Test-GHWADNativeSessionId -SessionId $resume)) {
            return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; messages = @() }
        }
        $rd = Read-GHWADSessionApi -Operation 'session.message.list' -Params @{ sessionID = $resume; limit = '200'; order = 'desc' } -ApiInvoker $ApiInvoker -BinaryCommand $BinaryCommand -TimeoutMs $TimeoutMs
        if (($null -eq $rd) -or (-not [bool](Get-GHWADValue $rd 'ok' $false))) {
            $why = 'auto-worker-api-unavailable'
            try {
                $wr = ([string](Get-GHWADValue $rd 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($wr)) { $why = $wr }
            }
            catch { }
            return [pscustomobject]@{ ok = $false; reason = $why; messages = @() }
        }
        $data = Get-GHWADValue (Get-GHWADValue $rd 'body' $null) 'data' @()
        return [pscustomobject]@{ ok = $true; reason = ''; messages = @($data) }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'auto-worker-api-unavailable'; messages = @() }
    }
}

function Find-GHWADNativeWorkerProof {
    # P0 native gate: pure validator over native-shaped evidence (no IO,
    # never throws, ASCII-only). Binds ONE new child session to ONE new
    # completed subagent tool invocation and to the CURRENT operation:
    #   - child id NOT in the pre-run set (pre-existing excluded) AND
    #     child time.created >= run start (stale child refused);
    #   - child parentID == resume session (server filter re-verified);
    #   - child projectID == expected project (when both known);
    #   - tool part {type=tool, name=subagent} in the SAME resume session
    #     with time.created >= run start, state.status=completed, naming
    #     the child via state.metadata.sessionID (or state.input.sessionID);
    #   - state.input.prompt carries the EXACT operation marker embedded
    #     by this driver (New-GHWADOperationMarker);
    #   - state.content carries a STRUCTURED worker result object
    #     (Find-GHWADWorkerResultObject) with task_id + goal_id +
    #     generation + idempotency_key EXACTLY equal to the current
    #     operation, status candidate_pass/failed/blocked and
    #     criterion refs;
    #   - child outcome succeeded => result_ok true, failed => result_ok
    #     false (settle records the failure); missing/interrupted/other
    #     => result-unproven.
    # First full match wins; otherwise the most specific refusal seen
    # (parent > operation > result > unproven) is returned.
    [CmdletBinding()]
    param(
        [string]$ResumeSessionId = '',
        [string[]]$PreChildIds = @(),
        $PostChildrenById = @{},
        $Messages = @(),
        [string]$ExpectedTaskId = '',
        [string]$ExpectedGoalId = '',
        [string]$ExpectedGeneration = '',
        [string]$ExpectedIdempotencyKey = '',
        [string]$ExpectedProjectId = '',
        [long]$RunStartMs = 0
    )
    $mkProof = {
        param([bool]$Ok, [string]$Reason, [string]$Worker, [bool]$ResultOk)
        return [pscustomobject]@{ ok = [bool]$Ok; reason = ([string]$Reason); worker_session_id = ([string]$Worker); result_ok = [bool]$ResultOk }
    }
    try {
        $resume = (([string]$ResumeSessionId).Trim())
        if (-not (Test-GHWADNativeSessionId -SessionId $resume)) {
            return (& $mkProof -Ok $false -Reason 'auto-worker-unproven' -Worker '' -ResultOk $false)
        }
        $pre = @{}
        foreach ($p in @($PreChildIds)) {
            $t = (([string]$p).Trim())
            if (-not [string]::IsNullOrWhiteSpace($t)) { $pre[$t] = $true }
        }
        $post = @{}
        try {
            if ($PostChildrenById -is [System.Collections.IDictionary]) {
                foreach ($k in @($PostChildrenById.Keys)) { $post[([string]$k)] = $PostChildrenById[$k] }
            }
        }
        catch { }
        $newIds = @()
        foreach ($k in @($post.Keys)) {
            if (-not $pre.ContainsKey(([string]$k))) { $newIds += @(([string]$k)) }
        }
        if (@($newIds).Count -lt 1) {
            return (& $mkProof -Ok $false -Reason 'auto-worker-unproven' -Worker '' -ResultOk $false)
        }
        $expTask = (([string]$ExpectedTaskId).Trim())
        $expGoal = (([string]$ExpectedGoalId).Trim())
        $expGen = (([string]$ExpectedGeneration).Trim())
        $expKey = (([string]$ExpectedIdempotencyKey).Trim().ToLowerInvariant())
        $expProj = (([string]$ExpectedProjectId).Trim())
        $opMarker = New-GHWADOperationMarker -GoalId $expGoal -TaskId $expTask -Generation $expGen -IdempotencyKey $expKey
        $seenParent = $false
        $seenOperation = $false
        $seenResult = $false
        foreach ($m in @($Messages)) {
            if ($null -eq $m) { continue }
            if (([string](Get-GHWADValue $m 'type' '')).Trim() -cne 'assistant') { continue }
            $mCreated = [long]0
            try { $mCreated = [long](Get-GHWADValue (Get-GHWADValue $m 'time' $null) 'created' 0) } catch { $mCreated = 0 }
            if (($RunStartMs -gt 0) -and ($mCreated -lt $RunStartMs)) { continue }
            foreach ($part in @(Get-GHWADValue $m 'content' @())) {
                if ($null -eq $part) { continue }
                if (([string](Get-GHWADValue $part 'type' '')).Trim() -cne 'tool') { continue }
                if (([string](Get-GHWADValue $part 'name' '')).Trim() -cne 'subagent') { continue }
                $state = Get-GHWADValue $part 'state' $null
                if ($null -eq $state) { continue }
                if (([string](Get-GHWADValue $state 'status' '')).Trim() -cne 'completed') { continue }
                $childId = (([string](Get-GHWADValue (Get-GHWADValue $state 'metadata' $null) 'sessionID' '')).Trim())
                if ([string]::IsNullOrWhiteSpace($childId)) {
                    $childId = (([string](Get-GHWADValue (Get-GHWADValue $state 'input' $null) 'sessionID' '')).Trim())
                }
                if ((-not (Test-GHWADNativeSessionId -SessionId $childId)) -or (-not $post.ContainsKey($childId))) { continue }
                if ($childId -ceq $resume) { continue }
                $child = $post[$childId]
                $cParent = (([string](Get-GHWADValue $child 'parentID' '')).Trim())
                if ($cParent -cne $resume) { $seenParent = $true; continue }
                $cProj = (([string](Get-GHWADValue $child 'projectID' '')).Trim())
                if ((-not [string]::IsNullOrWhiteSpace($expProj)) -and (-not [string]::IsNullOrWhiteSpace($cProj)) -and ($cProj -cne $expProj)) {
                    $seenOperation = $true; continue
                }
                $cCreated = [long]0
                try { $cCreated = [long](Get-GHWADValue (Get-GHWADValue $child 'time' $null) 'created' 0) } catch { $cCreated = 0 }
                if (($RunStartMs -gt 0) -and ($cCreated -lt $RunStartMs)) { $seenOperation = $true; continue }
                $prompt = Get-GHWADValue (Get-GHWADValue $state 'input' $null) 'prompt' $null
                $promptText = ''
                if ($prompt -is [string]) { $promptText = ([string]$prompt) }
                $bound = ((-not [string]::IsNullOrWhiteSpace($promptText)) -and `
                    (-not [string]::IsNullOrWhiteSpace($opMarker)) -and $promptText.Contains($opMarker))
                if (-not [bool]$bound) { $seenOperation = $true; continue }
                $resObj = $null
                try {
                    $resTexts = @()
                    $rawContent = Get-GHWADValue $state 'content' $null
                    foreach ($ci in @($rawContent)) {
                        if ($null -eq $ci) { continue }
                        if ($ci -is [string]) {
                            if (-not [string]::IsNullOrWhiteSpace(([string]$ci))) { $resTexts += @(([string]$ci)) }
                            continue
                        }
                        $ct = ([string](Get-GHWADValue $ci 'type' '')).Trim()
                        if ($ct -cne 'text') { continue }
                        $ctext = ([string](Get-GHWADValue $ci 'text' ''))
                        if (-not [string]::IsNullOrWhiteSpace($ctext)) { $resTexts += @($ctext) }
                    }
                    foreach ($rt in @($resTexts)) {
                        $cand = $null
                        try {
                            $cand = Find-GHWADWorkerResultObject -Text $rt -ExpectedTaskId $expTask -ExpectedGoalId $expGoal `
                                -ExpectedGeneration $expGen -ExpectedIdempotencyKey $expKey
                        }
                        catch { $cand = $null }
                        if (($null -ne $cand) -and [bool](Get-GHWADValue $cand 'ok' $false)) { $resObj = $cand; break }
                    }
                }
                catch { $resObj = $null }
                if (($null -eq $resObj) -or (-not [bool](Get-GHWADValue $resObj 'ok' $false))) { $seenResult = $true; continue }
                $wStatus = (([string](Get-GHWADValue $resObj 'status' '')).Trim().ToLowerInvariant())
                $outcome = (([string](Get-GHWADValue $child 'outcome' '')).Trim().ToLowerInvariant())
                # Strict agreement: the native outcome and the worker-declared
                # status must say the same thing, otherwise fail closed.
                if (($wStatus -ceq 'candidate_pass') -and ($outcome -ceq 'succeeded')) {
                    return (& $mkProof -Ok $true -Reason 'worker-proven-native' -Worker $childId -ResultOk $true)
                }
                if ((($wStatus -ceq 'failed') -or ($wStatus -ceq 'blocked')) -and ($outcome -ceq 'failed')) {
                    return (& $mkProof -Ok $true -Reason 'worker-proven-native' -Worker $childId -ResultOk $false)
                }
                $seenResult = $true
            }
        }
        if ([bool]$seenParent) {
            return (& $mkProof -Ok $false -Reason 'auto-worker-parent-mismatch' -Worker '' -ResultOk $false)
        }
        if ([bool]$seenOperation) {
            return (& $mkProof -Ok $false -Reason 'auto-worker-operation-mismatch' -Worker '' -ResultOk $false)
        }
        if ([bool]$seenResult) {
            return (& $mkProof -Ok $false -Reason 'auto-worker-result-unproven' -Worker '' -ResultOk $false)
        }
        return (& $mkProof -Ok $false -Reason 'auto-worker-unproven' -Worker '' -ResultOk $false)
    }
    catch {
        return (& $mkProof -Ok $false -Reason 'auto-worker-unproven' -Worker '' -ResultOk $false)
    }
}

function Invoke-GHWakeAutoDispatch {
    [CmdletBinding()]
    param(
        $NextAction = $null,
        [string]$WaitsDir = '',
        [string]$TasksDir = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointDir = '',
        [string]$HandoffStateDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$EvidenceStoreDir = '',
        [string]$FlagsPath = '',
        [string]$NowUtc = '',
        [string]$ResumeSessionId = '',
        [string]$ExpectedDirectory = '',
        [string]$ExpectedProjectId = '',
        [string]$PromptText = '',
        $ControllerProbe = $null,
        $RunExecutor = $null,
        $SessionApiInvoker = $null,
        [string]$SettleResultSummary = 'gh-wake auto dispatch via native resume',
        [int]$ResumeTimeoutMs = 30000,
        [int]$SessionApiTimeoutMs = 30000
    )
    $mkAuto = {
        param([bool]$Ok, [string]$Verdict, [bool]$Dispatched, [string]$Decision, [string]$Reason, [string]$Controller, [string]$SessionId, [string]$MarkerPath, [string]$ResumeAction, [bool]$Duplicate)
        $tidOut = ''
        $idemOut = ''
        try { $tidOut = ([string](Get-GHWADValue $NextAction 'task_id' '')) } catch { $tidOut = '' }
        try { $idemOut = ([string](Get-GHWADValue $NextAction 'idempotency_key' '')) } catch { $idemOut = '' }
        $resumeOut = ''
        try { $resumeOut = (([string]$ResumeSessionId).Trim()) } catch { $resumeOut = '' }
        return [pscustomobject]@{
            ok = [bool]$Ok; harness = 'github-wake-auto-dispatch-v2'; verdict = ([string]$Verdict)
            dispatched = [bool]$Dispatched; decision = ([string]$Decision); reason = ([string]$Reason)
            controller = ([string]$Controller); task_id = $tidOut; idempotency_key = $idemOut
            session_id = ([string]$SessionId); marker_path = ([string]$MarkerPath)
            resume_session_id = $resumeOut; worker_session_id = ([string]$SessionId)
            resume_action = ([string]$ResumeAction); duplicate = [bool]$Duplicate
            executed = [bool]$Dispatched
            grants_authority = $false; done_approved = $false; merge_authority = $false
            next_action = $NextAction
        }
    }
    try {
        if ($null -eq $NextAction) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-invalid-next-action' -Controller 'none' -SessionId '' -MarkerPath '' -ResumeAction '' -Duplicate $false)
        }
        $hsd = ([string]$HandoffStateDir).Trim()
        if ([string]::IsNullOrWhiteSpace($hsd)) { $hsd = ([string]$CheckpointDir).Trim() }
        $handoff = $null
        try {
            if ($null -ne $ControllerProbe) {
                $handoff = Invoke-GHWakeControllerHandoff -NextAction $NextAction `
                    -WaitsDir $WaitsDir -TasksDir $TasksDir -GoalStoreDir $GoalStoreDir `
                    -CheckpointDir $CheckpointDir -FlagsPath $FlagsPath -NowUtc $NowUtc `
                    -HandoffStateDir $hsd -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot `
                    -EvidenceStoreDir $EvidenceStoreDir -ObjectiveStepProbe $ControllerProbe
            }
            else {
                $handoff = Invoke-GHWakeControllerHandoff -NextAction $NextAction `
                    -WaitsDir $WaitsDir -TasksDir $TasksDir -GoalStoreDir $GoalStoreDir `
                    -CheckpointDir $CheckpointDir -FlagsPath $FlagsPath -NowUtc $NowUtc `
                    -HandoffStateDir $hsd -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot `
                    -EvidenceStoreDir $EvidenceStoreDir
            }
        }
        catch { $handoff = $null }
        if ($null -eq $handoff) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-handoff-internal-error' -Controller 'none' -SessionId '' -MarkerPath '' -ResumeAction '' -Duplicate $false)
        }
        $hDec = ([string](Get-GHWADValue $handoff 'decision' '')).Trim()
        $hReason = ([string](Get-GHWADValue $handoff 'reason' '')).Trim()
        $hCtrl = ([string](Get-GHWADValue $handoff 'controller' 'none')).Trim()
        if ([string]::IsNullOrWhiteSpace($hCtrl)) { $hCtrl = 'none' }
        $hMarker = ([string](Get-GHWADValue $handoff 'marker_path' '')).Trim()
        $hOk = $false
        try { $hOk = [bool](Get-GHWADValue $handoff 'ok' $false) } catch { $hOk = $false }
        $isDuplicate = (($hDec -ceq 'duplicate-noop') -or (($hDec -ceq 'not-dispatched') -and ($hReason -ceq 'duplicate-noop')))
        if ([bool]$isDuplicate) {
            $idemDup = ([string](Get-GHWADValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant()
            $candDup = ''
            if ($idemDup -cmatch '^[a-f0-9]{32}$') {
                $candDup = Join-Path $hsd ('ghw-handoff-' + $idemDup + '.json')
            }
            if ((-not [string]::IsNullOrWhiteSpace($candDup)) -and (Test-Path -LiteralPath $candDup -PathType Leaf)) {
                $dupDoc = Read-GHWADJsonFile -Path $candDup
                $dupStat = ([string](Get-GHWADValue $dupDoc 'status' '')).Trim()
                $dupSess = ([string](Get-GHWADValue $dupDoc 'session_id' '')).Trim()
                if (($dupStat -ceq 'dispatched') -and (Test-GHWADNativeSessionId -SessionId $dupSess)) {
                    # Idempotent replay from the marker's OWN stored session:
                    # the stored session, parent, completed tool, exact
                    # operation binding and structured result are REVALIDATED
                    # against CURRENT native state before any Settle call.
                    # Old markers (e.g. resume id as child, or a child with
                    # no proof for THIS operation) never replay: reconcile
                    # with dispatched=false and zero Settle calls. Injected
                    # (non-native) transports never replay either.
                    $rpSid = (([string]$ResumeSessionId).Trim())
                    $rpGoal = ([string](Get-GHWADValue $NextAction 'goal_id' '')).Trim()
                    $rpTask = ([string](Get-GHWADValue $NextAction 'task_id' '')).Trim()
                    $rpKey = ([string](Get-GHWADValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant()
                    $rpGen = ''
                    try { $rpGen = ([string][long](Get-GHWADValue $NextAction 'generation' -1)) } catch { $rpGen = '' }
                    $rpTO = [int]$SessionApiTimeoutMs
                    if ($rpTO -lt 100) { $rpTO = 100 }
                    $rpProof = $null
                    try {
                        if ((Test-GHWADNativeSessionId -SessionId $rpSid) -and (-not [string]::IsNullOrWhiteSpace($rpGoal)) -and `
                            (-not [string]::IsNullOrWhiteSpace($rpTask)) -and ($rpKey -cmatch '^[a-f0-9]{32}$') -and ($null -eq $SessionApiInvoker)) {
                            $rpSnap = Get-GHWADChildSnapshot -ResumeSessionId $rpSid -ApiInvoker $SessionApiInvoker -TimeoutMs $rpTO
                            $rpById = @{}
                            if (($null -ne $rpSnap) -and [bool](Get-GHWADValue $rpSnap 'ok' $false)) {
                                try {
                                    $rpRaw = Get-GHWADValue $rpSnap 'byId' @{}
                                    if ($rpRaw -is [System.Collections.IDictionary]) {
                                        foreach ($k in @($rpRaw.Keys)) { $rpById[([string]$k)] = $rpRaw[$k] }
                                    }
                                }
                                catch { }
                            }
                            $rpMsgs = Get-GHWADResumeMessages -ResumeSessionId $rpSid -ApiInvoker $SessionApiInvoker -TimeoutMs $rpTO
                            if ((@($rpById.Keys).Count -gt 0) -and ($null -ne $rpMsgs) -and [bool](Get-GHWADValue $rpMsgs 'ok' $false)) {
                                $rpProof = Find-GHWADNativeWorkerProof -ResumeSessionId $rpSid -PreChildIds @() -PostChildrenById $rpById `
                                    -Messages @(Get-GHWADValue $rpMsgs 'messages' @()) -ExpectedTaskId $rpTask -ExpectedGoalId $rpGoal `
                                    -ExpectedGeneration $rpGen -ExpectedIdempotencyKey $rpKey `
                                    -ExpectedProjectId ([string]$ExpectedProjectId).Trim() -RunStartMs 0
                            }
                        }
                    }
                    catch { $rpProof = $null }
                    $rpOk = (($null -ne $rpProof) -and [bool](Get-GHWADValue $rpProof 'ok' $false))
                    $rpWorker = ''
                    try { $rpWorker = (([string](Get-GHWADValue $rpProof 'worker_session_id' '')).Trim()) } catch { $rpWorker = '' }
                    if (([bool]$rpOk) -and (-not [string]::IsNullOrWhiteSpace($rpWorker)) -and ($rpWorker -ceq $dupSess)) {
                        $rpResultOk = $false
                        try { $rpResultOk = [bool](Get-GHWADValue $rpProof 'result_ok' $false) } catch { $rpResultOk = $false }
                        $expGoalD = ([string](Get-GHWADValue $NextAction 'goal_id' '')).Trim()
                        $expTaskD = ([string](Get-GHWADValue $NextAction 'task_id' '')).Trim()
                        $reSettle = $null
                        try {
                            $reSettle = Set-GHWakeDispatchSettlement -MarkerPath $candDup -SessionId $dupSess `
                                -ResultOk ([bool]$rpResultOk) -ResultSummary ([string]$SettleResultSummary).Trim() `
                                -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir `
                                -TasksDir $TasksDir -EvidenceStoreDir $EvidenceStoreDir -FlagsPath $FlagsPath `
                                -ExpectedGoalId $expGoalD -ExpectedTaskId $expTaskD
                        }
                        catch { $reSettle = $null }
                        $reOk = (($null -ne $reSettle) -and [bool](Get-GHWADValue $reSettle 'ok' $false) -and [bool](Get-GHWADValue $reSettle 'dispatched' $false))
                        if ([bool]$reOk) {
                            return (& $mkAuto -Ok $true -Verdict 'AUTO_PASS' -Dispatched $true -Decision 'already-done' -Reason 'settle-duplicate' -Controller $hCtrl -SessionId $dupSess -MarkerPath $candDup -ResumeAction '' -Duplicate $true)
                        }
                        $reWhy = 'settle-refused'
                        try {
                            $rr = ([string](Get-GHWADValue $reSettle 'reason' ''))
                            if (-not [string]::IsNullOrWhiteSpace($rr)) { $reWhy = $rr }
                        }
                        catch { }
                        return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason ('auto-settle-' + $reWhy) -Controller $hCtrl -SessionId $dupSess -MarkerPath $candDup -ResumeAction '' -Duplicate $false)
                    }
                    return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-replay-unproven' -Controller $hCtrl -SessionId '' -MarkerPath $candDup -ResumeAction '' -Duplicate $false)
                }
            }
            return (& $mkAuto -Ok $true -Verdict 'AUTO_PASS' -Dispatched $false -Decision 'not-dispatched' -Reason 'duplicate-noop' -Controller $hCtrl -SessionId '' -MarkerPath $candDup -ResumeAction '' -Duplicate $true)
        }
        $ready = ((($hDec -ceq 'intent-ready') -or ($hDec -ceq 'controller-responded')) -and [bool]$hOk)
        if (-not [bool]$ready) {
            $hr = 'auto-handoff-refused'
            if (-not [string]::IsNullOrWhiteSpace($hReason)) { $hr = ('auto-handoff-' + $hReason) }
            $rok = [bool]$hOk
            return (& $mkAuto -Ok $rok -Verdict $(if ($rok) { 'AUTO_PASS' } else { 'AUTO_FAIL' }) -Dispatched $false -Decision 'not-dispatched' -Reason $hr -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        if ([string]::IsNullOrWhiteSpace($hMarker)) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-handoff-marker-missing' -Controller $hCtrl -SessionId '' -MarkerPath '' -ResumeAction '' -Duplicate $false)
        }
        $sid = ([string]$ResumeSessionId).Trim()
        if (-not (Test-GHWADSessionId -SessionId $sid)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $hMarker } catch { }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-session-invalid' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $gid = ([string](Get-GHWADValue $NextAction 'goal_id' '')).Trim()
        $tid = ([string](Get-GHWADValue $NextAction 'task_id' '')).Trim()
        $cid = ([string](Get-GHWADValue $NextAction 'checkpoint_id' '')).Trim()
        $idem = ([string](Get-GHWADValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant()
        $genLong = [long]0
        try { $genLong = [long](Get-GHWADValue $NextAction 'generation' -1) } catch { $genLong = -1 }
        $lown = ([string](Get-GHWADValue $NextAction 'lease_owner' '')).Trim()
        $lexp = ([string](Get-GHWADValue $NextAction 'lease_expires_utc' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($tid) -or [string]::IsNullOrWhiteSpace($cid)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $hMarker } catch { }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-invalid-next-action' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        if (-not (Test-GHWADNativeSessionId -SessionId $sid)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $hMarker } catch { }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-session-invalid' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $apiTO = [int]$SessionApiTimeoutMs
        if ($apiTO -lt 100) { $apiTO = 100 }
        if (($null -ne $RunExecutor) -and ($null -eq $SessionApiInvoker)) {
            # Mocked resume without an injected (non-native) API transport:
            # gated BEFORE any native query and before any run, so no
            # mocked/test execution can ever reach the native API or the
            # settlement path. Claim kept for operator reconciliation.
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-worker-non-native' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        # Pre-run native snapshot (BEFORE any run): without it the
        # pre/post comparison is unsound, so a transport failure here
        # reconciles with zero executor effect.
        $preSnap = $null
        try {
            $preSnap = Get-GHWADChildSnapshot -ResumeSessionId $sid -ApiInvoker $SessionApiInvoker -TimeoutMs $apiTO
        }
        catch { $preSnap = $null }
        if (($null -eq $preSnap) -or (-not [bool](Get-GHWADValue $preSnap 'ok' $false))) {
            $preWhy = 'auto-worker-api-unavailable'
            try {
                $pr = ([string](Get-GHWADValue $preSnap 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($pr)) { $preWhy = $pr }
            }
            catch { }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason $preWhy -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $preIds = @()
        try { $preIds = @((Get-GHWADValue $preSnap 'ids' @())) } catch { $preIds = @() }
        $prompt = ([string]$PromptText).Trim()
        if ([string]::IsNullOrWhiteSpace($prompt)) {
            $prompt = ('resume goal ' + $gid + ' task ' + $tid + ' checkpoint ' + $cid + ' generation ' + [string]$genLong)
        }
        # Exact operation marker for the Planner to forward to the worker,
        # plus the delegation directive; the worker's structured result
        # must echo these identities back. Fail-closed BEFORE any run
        # when the marker, the directive, or the final prompt cannot
        # travel through the NativeResume prompt gate.
        $opMarker = New-GHWADOperationMarker -GoalId $gid -TaskId $tid -Generation ([string]$genLong) -IdempotencyKey $idem
        if ([string]::IsNullOrWhiteSpace($opMarker)) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-prompt-unfittable' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $opDirective = ''
        try { $opDirective = ([string](Get-GHWADWorkerDirective)).Trim() } catch { $opDirective = '' }
        if ([string]::IsNullOrWhiteSpace($opDirective)) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-prompt-unfittable' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $prompt = (([string]$prompt).Trim() + ' ' + $opMarker + ' ' + $opDirective)
        if (-not (Test-GHWADPromptFits -PromptText $prompt)) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-prompt-unfittable' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $auth = [pscustomobject][ordered]@{
            goal_id = $gid; owner = $lown; generation = ([string]$genLong)
            lease_owner = $lown; lease_expires_utc = $lexp
            explicit_allow = $true; source = 'gh-wake-auto-dispatch'
        }
        $toMs = [int]$ResumeTimeoutMs
        if ($toMs -lt 100) { $toMs = 100 }
        $runStartMs = [long]0
        try { $runStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } catch { $runStartMs = 0 }
        $resume = $null
        try {
            if ($null -ne $RunExecutor) {
                $resume = Invoke-OrchestrationNativeResume -SessionId $sid -ExpectedDirectory ([string]$ExpectedDirectory).Trim() `
                    -ExpectedProjectId ([string]$ExpectedProjectId).Trim() -GoalId $gid -TaskId $tid -CheckpointId $cid `
                    -CheckpointDir ([string]$CheckpointDir).Trim() -GoalStoreDir ([string]$GoalStoreDir).Trim() `
                    -TasksDir ([string]$TasksDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() -IdempotencyKey $idem `
                    -Generation ([string]$genLong) -LeaseOwner $lown -Authorization $auth -PromptText $prompt `
                    -BinaryCommand 'opencode' -TimeoutMs $toMs -RunExecutor $RunExecutor
            }
            else {
                $resume = Invoke-OrchestrationNativeResume -SessionId $sid -ExpectedDirectory ([string]$ExpectedDirectory).Trim() `
                    -ExpectedProjectId ([string]$ExpectedProjectId).Trim() -GoalId $gid -TaskId $tid -CheckpointId $cid `
                    -CheckpointDir ([string]$CheckpointDir).Trim() -GoalStoreDir ([string]$GoalStoreDir).Trim() `
                    -TasksDir ([string]$TasksDir).Trim() -RepoRoot ([string]$RepoRoot).Trim() -IdempotencyKey $idem `
                    -Generation ([string]$genLong) -LeaseOwner $lown -Authorization $auth -PromptText $prompt `
                    -BinaryCommand 'opencode' -TimeoutMs $toMs
            }
        }
        catch { $resume = $null }
        if ($null -eq $resume) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-resume-internal-error' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction '' -Duplicate $false)
        }
        $rAction = ([string](Get-GHWADValue $resume 'action' 'blocked')).Trim()
        $rReason = ([string](Get-GHWADValue $resume 'reason' 'internal-error')).Trim()
        if ([string]::IsNullOrWhiteSpace($rReason)) { $rReason = 'internal-error' }
        $rOk = $false
        try { $rOk = [bool](Get-GHWADValue $resume 'ok' $false) } catch { $rOk = $false }
        if (($rAction -ceq 'proceed') -and [bool]$rOk) {
            $rsess = $null
            try { $rsess = Get-GHWADValue $resume 'session' $null } catch { $rsess = $null }
            $proven = ''
            try {
                foreach ($pk in @('id', 'sessionId', 'sessionID', 'session_id')) {
                    $pv = Get-GHWADValue $rsess $pk ''
                    if (-not [string]::IsNullOrWhiteSpace(([string]$pv))) { $proven = ([string]$pv).Trim(); break }
                }
                if ([string]::IsNullOrWhiteSpace($proven)) {
                    $fv = Get-GHWADValue $resume 'session_id' ''
                    if (-not [string]::IsNullOrWhiteSpace(([string]$fv))) { $proven = ([string]$fv).Trim() }
                }
                if ([string]::IsNullOrWhiteSpace($proven)) {
                    $fv2 = Get-GHWADValue $resume 'sessionId' ''
                    if (-not [string]::IsNullOrWhiteSpace(([string]$fv2))) { $proven = ([string]$fv2).Trim() }
                }
            }
            catch { $proven = '' }
            if ([string]::IsNullOrWhiteSpace($proven) -or ($proven -cne $sid)) {
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-identity-unproven' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            # P0 native worker gate. resume.session.id NEVER proves the
            # worker: only native post-run evidence (new child + new
            # completed subagent tool invocation + current-operation
            # binding + structured result) settles, with the NATIVE
            # child id. NATIVE_SESSION_RESUMED alone reconciles as
            # auto-worker-unproven (claim kept, no settle).
            $postSnap = $null
            try {
                $postSnap = Get-GHWADChildSnapshot -ResumeSessionId $sid -ApiInvoker $SessionApiInvoker -TimeoutMs $apiTO
            }
            catch { $postSnap = $null }
            if (($null -eq $postSnap) -or (-not [bool](Get-GHWADValue $postSnap 'ok' $false))) {
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-worker-api-unavailable' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            $postById = @{}
            try {
                $rawById = Get-GHWADValue $postSnap 'byId' @{}
                if ($rawById -is [System.Collections.IDictionary]) {
                    foreach ($k in @($rawById.Keys)) { $postById[([string]$k)] = $rawById[$k] }
                }
            }
            catch { }
            $msgRead = $null
            try {
                $msgRead = Get-GHWADResumeMessages -ResumeSessionId $sid -ApiInvoker $SessionApiInvoker -TimeoutMs $apiTO
            }
            catch { $msgRead = $null }
            if (($null -eq $msgRead) -or (-not [bool](Get-GHWADValue $msgRead 'ok' $false))) {
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-worker-api-unavailable' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            $wproof = $null
            try {
                $wproof = Find-GHWADNativeWorkerProof -ResumeSessionId $sid -PreChildIds $preIds -PostChildrenById $postById `
                    -Messages @(Get-GHWADValue $msgRead 'messages' @()) -ExpectedTaskId $tid -ExpectedGoalId $gid `
                    -ExpectedGeneration ([string]$genLong) -ExpectedIdempotencyKey $idem `
                    -ExpectedProjectId ([string]$ExpectedProjectId).Trim() -RunStartMs ([long]$runStartMs)
            }
            catch { $wproof = $null }
            $wOk = (($null -ne $wproof) -and [bool](Get-GHWADValue $wproof 'ok' $false))
            if (-not [bool]$wOk) {
                $wWhy = 'auto-worker-unproven'
                try {
                    $wr = ([string](Get-GHWADValue $wproof 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($wr)) { $wWhy = $wr }
                }
                catch { }
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason $wWhy -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            if (($null -ne $SessionApiInvoker) -or ($null -ne $RunExecutor)) {
                # Injected (non-native) transport or mocked resume: a fully
                # validating payload still never settles productive state.
                # Mocks cannot fabricate a productive settlement.
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-worker-non-native' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            $workerSid = ''
            try { $workerSid = (([string](Get-GHWADValue $wproof 'worker_session_id' '')).Trim()) } catch { $workerSid = '' }
            if (-not (Test-GHWADNativeSessionId -SessionId $workerSid)) {
                return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-worker-unproven' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
            }
            $wResultOk = $false
            try { $wResultOk = [bool](Get-GHWADValue $wproof 'result_ok' $false) } catch { $wResultOk = $false }
            $settle = $null
            try {
                $settle = Set-GHWakeDispatchSettlement -MarkerPath $hMarker -SessionId $workerSid `
                    -ResultOk ([bool]$wResultOk) -ResultSummary ([string]$SettleResultSummary).Trim() `
                    -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir `
                    -TasksDir $TasksDir -EvidenceStoreDir $EvidenceStoreDir -FlagsPath $FlagsPath `
                    -ExpectedGoalId $gid -ExpectedTaskId $tid
            }
            catch { $settle = $null }
            $sOk = (($null -ne $settle) -and [bool](Get-GHWADValue $settle 'ok' $false) -and [bool](Get-GHWADValue $settle 'dispatched' $false))
            $sWhy = 'settle-refused'
            try {
                $sr = ([string](Get-GHWADValue $settle 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($sr)) { $sWhy = $sr }
            }
            catch { }
            if ([bool]$sOk) {
                $sDup = $false
                try { $sDup = [bool](Get-GHWADValue $settle 'duplicate' $false) } catch { $sDup = $false }
                return (& $mkAuto -Ok $true -Verdict 'AUTO_PASS' -Dispatched $true -Decision 'dispatched' -Reason $sWhy -Controller $hCtrl -SessionId $workerSid -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $sDup)
            }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason ('auto-settle-' + $sWhy) -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'proceed' -Duplicate $false)
        }
        $hasAction = $false
        try {
            if ($resume -is [System.Collections.IDictionary]) { $hasAction = $resume.Contains('action') }
            else { $hasAction = ($null -ne $resume.PSObject.Properties['action']) }
        }
        catch { $hasAction = $false }
        $hasOk = $false
        try {
            if ($resume -is [System.Collections.IDictionary]) { $hasOk = $resume.Contains('ok') }
            else { $hasOk = ($null -ne $resume.PSObject.Properties['ok']) }
        }
        catch { $hasOk = $false }
        $knownAction = (($rAction -ceq 'proceed') -or ($rAction -ceq 'reconcile') -or ($rAction -ceq 'blocked'))
        $envelopeSane = ([bool]$hasAction -and [bool]$hasOk -and [bool]$knownAction)
        if (($rAction -ceq 'reconcile') -and (-not [bool]$rOk) -and [bool]$envelopeSane) {
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason ('auto-reconcile-' + $rReason) -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction 'reconcile' -Duplicate $false)
        }
        $knownBlocked = @('session-id-invalid','invalid-idempotency-key','invalid-prompt','session-not-found','project-mismatch','directory-mismatch','authorization-denied','checkpoint-not-found','resume-not-resumable','kernel-not-ready','already-done','internal-error')
        if (($rAction -ceq 'blocked') -and (-not [bool]$rOk) -and [bool]$envelopeSane -and ($knownBlocked -contains $rReason)) {
            try { Remove-GHWakeHandoffClaim -MarkerPath $hMarker } catch { }
            return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason ('auto-resume-' + $rReason) -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction $rAction -Duplicate $false)
        }
        return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'reconcile' -Reason 'auto-unknown-resume-outcome' -Controller $hCtrl -SessionId '' -MarkerPath $hMarker -ResumeAction $rAction -Duplicate $false)
    }
    catch {
        try { return (& $mkAuto -Ok $false -Verdict 'AUTO_FAIL' -Dispatched $false -Decision 'not-dispatched' -Reason 'auto-internal-error' -Controller 'none' -SessionId '' -MarkerPath '' -ResumeAction '' -Duplicate $false) } catch { return $null }
    }
}

if ((-not [string]::IsNullOrWhiteSpace($WakeEnvelopeFile)) -or (-not [string]::IsNullOrWhiteSpace($NextActionFile)) -or (-not [string]::IsNullOrWhiteSpace($NextActionJson))) {
    function Write-GHWADEnvelope {
        param($Envelope)
        try {
            Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
        }
        catch {
            Write-Output '{"ok":false,"harness":"github-wake-auto-dispatch-v2","verdict":"AUTO_FAIL","dispatched":false,"decision":"not-dispatched","reason":"encode-failed","controller":"none","executed":false,"grants_authority":false,"done_approved":false,"merge_authority":false}'
        }
    }
    function New-GHWADErrorEnvelope {
        param([string]$Reason)
        return [pscustomobject]@{
            ok = $false; harness = 'github-wake-auto-dispatch-v2'; verdict = 'AUTO_FAIL'
            dispatched = $false; decision = 'not-dispatched'; reason = $Reason
            controller = 'none'; task_id = ''; idempotency_key = ''
            session_id = ''; marker_path = ''; resume_action = ''; duplicate = $false
            executed = $false; grants_authority = $false; done_approved = $false; merge_authority = $false
            next_action = $null
        }
    }
    try {
        $effAction = $null
        if (-not [string]::IsNullOrWhiteSpace($NextActionJson)) {
            try { $effAction = ConvertFrom-Json ([string]$NextActionJson) } catch { $effAction = $null }
            if ($null -eq $effAction) {
                Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-invalid-next-action-json')
                exit 2
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($NextActionFile)) {
            $doc = Read-GHWADJsonFile -Path ([string]$NextActionFile).Trim()
            if ($null -eq $doc) {
                Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-invalid-next-action-file')
                exit 2
            }
            $maybe = Get-GHWADValue $doc 'next_action' $null
            if ($null -ne $maybe) { $effAction = $maybe } else { $effAction = $doc }
        }
        else {
            $envDoc = Read-GHWADJsonFile -Path ([string]$WakeEnvelopeFile).Trim()
            if ($null -eq $envDoc) {
                Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-invalid-wake-envelope')
                exit 2
            }
            $effAction = Get-GHWADValue $envDoc 'next_action' $null
        }
        if ([string]::IsNullOrWhiteSpace($WaitsDir) -or (-not (Test-Path -LiteralPath ([string]$WaitsDir).Trim() -PathType Container))) {
            Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-invalid-waits-dir')
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($TasksDir) -or (-not (Test-Path -LiteralPath ([string]$TasksDir).Trim() -PathType Container))) {
            Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-invalid-tasks-dir')
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($ResumeSessionId)) {
            Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-session-invalid')
            exit 2
        }
        $result = Invoke-GHWakeAutoDispatch -NextAction $effAction `
            -WaitsDir ([string]$WaitsDir).Trim() -TasksDir ([string]$TasksDir).Trim() `
            -GoalStoreDir ([string]$GoalStoreDir).Trim() -CheckpointDir ([string]$CheckpointDir).Trim() `
            -HandoffStateDir ([string]$HandoffStateDir).Trim() -ReceiptDir ([string]$ReceiptDir).Trim() `
            -RepoRoot ([string]$RepoRoot).Trim() -EvidenceStoreDir ([string]$EvidenceStoreDir).Trim() `
            -FlagsPath ([string]$FlagsPath).Trim() -NowUtc ([string]$NowUtc).Trim() `
            -ResumeSessionId ([string]$ResumeSessionId).Trim() -ExpectedDirectory ([string]$ExpectedDirectory).Trim() `
            -ExpectedProjectId ([string]$ExpectedProjectId).Trim() -PromptText ([string]$PromptText).Trim() `
            -SettleResultSummary ([string]$SettleResultSummary).Trim() -ResumeTimeoutMs ([int]$ResumeTimeoutMs)
        if ($null -eq $result) {
            Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-internal-error')
            exit 1
        }
        $effOut = ([string]$OutFile).Trim()
        if (-not [string]::IsNullOrWhiteSpace($effOut)) {
            try {
                $json = ConvertTo-Json -InputObject $result -Depth 10 -Compress
                [IO.File]::WriteAllText($effOut, $json, (New-Object Text.UTF8Encoding $false))
            }
            catch { }
        }
        Write-GHWADEnvelope -Envelope $result
        if ([bool]$result.ok) { exit 0 } else { exit 1 }
    }
    catch {
        try {
            Write-GHWADEnvelope (New-GHWADErrorEnvelope -Reason 'auto-internal-error')
        }
        catch { }
        exit 1
    }
}
