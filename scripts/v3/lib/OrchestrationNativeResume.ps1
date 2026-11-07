<#!
.SYNOPSIS
    Native resume adapter (P1): pre-effect resume probe over an existing
    OpenCode V2 session. Dot-sourceable, no execution on load.
.DESCRIPTION
    Minimal adapter for resuming work in a NATIVE session that already
    exists. Reuses the existing building blocks by dot-source only, never
    duplicating them:

      - OrchestrationNativeSessionAdapter.ps1: Get-NativeSessionIdentity,
        Test-NativeSessionIdFormat, Resolve-NativeSessionDirectory.
      - OrchestrationNativeDispatch.ps1: New-OrchestrationNativeDispatchIntent,
        Invoke-OrchestrationNativeDispatchPrepare/Claim/Settle (called by the
        CALLER, never here).
      - OrchestrationGoalCheckpoint.ps1: Load-OrchestrationGoalCheckpoint,
        Test-OrchestrationCheckpointResume.
      - OrchestrationTaskKernel.ps1: Get-OrchestrationTask (read-only here).
      - scripts/v3/github-wake.ps1: New-GHWakeDispatchIntent,
        Get-GHWakeHandoffSessionToken, Set-GHWakeDispatchSettlement are only
        a REFERENCE for the settlement path. This file never duplicates
        settlement logic and never marks dispatched/executed.

    There is NO second Planner, NO second Kernel, NO state machine and NO
    parallel executor here. The only effect is ONE `opencode run --session`
    invocation (or ONE injected RunExecutor call in tests), strictly AFTER
    all pre-checks pass. Pre-check failure NEVER invokes the run.

    The resume command NEVER uses --continue or --fork. Only
    `opencode run --session <id> --format json <prompt>` with the child
    working directory set to <canon> (run has no --dir flag in v2.2.5).

    STABLE REASON CODES (fail-closed):
      session-id-invalid      SessionId empty, without ses_ prefix, or
                              containing 'continue' (--continue is never a
                              valid resume path).
      invalid-idempotency-key IdempotencyKey not ^[a-f0-9]{32}$ (lowercase).
      invalid-prompt          PromptText empty, longer than 2000 chars, or
                              carrying shell metacharacters. Fail-closed set:
                              & | < > ( ) ^ % ! ; $ " backtick CR LF.
                              Prompt must be Kernel-built only (ids hex,
                              task ids, fixed words); never free text with
                              quotes or operators.
      session-not-found       Pre-check direct lookup has no such session id.
      session-archived        Pre-check direct lookup found the session but it
                              is archived; a resume must not proceed.
      project-mismatch        Live session projectId != ExpectedProjectId.
      directory-mismatch      Live session directory != ExpectedDirectory.
      authorization-denied    Authorization given but not explicitly
                              allowing (explicit_allow must be bool $true;
                              test-callback never authorizes; goal binding
                              diverged; stale generation/lease fencing:
                              generation mismatch, lease_owner mismatch,
                              or lease_expires_utc past/unparseable;
                              reason stays authorization-denied).
                              MANDATORY FENCING: when Generation or
                              LeaseOwner is non-empty, Authorization must
                              be present AND carry the matching
                              generation/expected_generation and/or
                              lease_owner/expected_lease_owner field;
                              absent token or absent field denies.
                              Legacy path (Generation and LeaseOwner both
                              empty, Authorization null) stays allowed.
      checkpoint-not-found    Checkpoint id invalid, unreadable, or record
                              invalid; GoalId binding diverged.
      resume-not-resumable    Checkpoint loads but resume plan refuses
                              (stale revision, goal missing, store
                              unverifiable).
      kernel-not-ready        Task unreadable or in a state other than
                              BLOCKED/IMPLEMENTING (DONE has its own code).
      already-done            Task is DONE: never re-executed. A second call
                              after settlement lands here (no blind resend).
      session-not-found-post  Run returned empty stdout with a
                              session-missing marker on stderr
                              (Session not found | NotFoundError |
                              starts_with | Expected a string). RECONCILE.
      timeout-unknown         Run timed out: outcome unknown, never resend
                              blindly. RECONCILE.
      resume-unproven         Exit != 0 or stdout without native execution
                              evidence (also covers MODEL_UNAVAILABLE and
                              CREDENTIAL_ABSENT markers). RECONCILE.
      identity-diverged       Post-run identity differs from the pre-run
                              identity (id, directory or projectId changed).
                              RECONCILE.
      '' (empty)              Success: action=proceed.

    ACTIONS: proceed (ok, evidence found), blocked (HOLD, run never
    invoked), reconcile (run attempted or post-check failed; the caller
    must reconcile via the supported Claim+Settle path, never resend
    blindly). timeout-unknown NEVER authorizes a blind resend.

    PS 5.1 compatible. ASCII-only. No network and no process spawn on
    load. Never throws on operational paths: every failure is an envelope
    with ok=$false and a stable reason. Secrets are never logged: only
    stdout length and a 200-char redacted stderr diagnostic are kept
    (Protect-NRDiag truncates to 200 chars and replaces known secret
    shapes with [redacted]).

    NO CMD SHIM FOR THE RUN: Get-NativeSessionList (adapter) keeps its
    cmd.exe shim because its args are fixed (session list -n <MaxCount>
    --format json) with no free text. This resume run NEVER uses cmd.exe:
    PromptText is free text and must not cross a shell. When the resolved
    binary is a .cmd/.bat shim, the runner looks for a .ps1 sibling of the
    same basename in the same directory and invokes it via a PowerShell
    host (powershell.exe, fallback pwsh) with -NoProfile -ExecutionPolicy
    Bypass -File "<ps1>" + run args. With no .ps1 sibling and no direct
    exe, the run fails closed (LAUNCH_ERROR) instead of spawning cmd.exe.
    Direct exe paths run without any shell.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $NRLibDir = $PSScriptRoot
    if ($null -eq (Get-Command Get-NativeSessionIdentity -ErrorAction SilentlyContinue)) {
        $p = Join-Path $NRLibDir 'OrchestrationNativeSessionAdapter.ps1'
        if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
    }
    if ($null -eq (Get-Command Load-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue)) {
        $p = Join-Path $NRLibDir 'OrchestrationGoalCheckpoint.ps1'
        if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
    }
    if ($null -eq (Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue)) {
        $p = Join-Path $NRLibDir 'OrchestrationTaskKernel.ps1'
        if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
    }
}
catch { }

function Get-NRValue {
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

function Protect-NRDiag {
    param([string]$Text)
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        $t = ([string]$Text).Trim()
        # Redact well-known secret shapes BEFORE truncating, so a secret
        # straddling the 200-char boundary cannot leak partially. Local
        # regexes on purpose: no new dependency on CapabilitySanitize.
        try {
            $t = ($t -replace 'sk-[A-Za-z0-9_-]+', '[redacted]')
            $t = ($t -replace 'ghp_[A-Za-z0-9_]+', '[redacted]')
            $t = ($t -replace 'github_pat_[A-Za-z0-9_]+', '[redacted]')
            $t = ($t -creplace 'AKIA[0-9A-Z]+', '[redacted]')
            $t = ($t -replace 'xox[bap]-[A-Za-z0-9-]+', '[redacted]')
            $t = ($t -replace '(?i)Bearer\s+\S+', 'Bearer [redacted]')
            $t = ($t -replace '(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*\S+', '$1=[redacted]')
        }
        catch { }
        if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
        return $t
    }
    catch { return '' }
}

function Test-NativeResumeSessionId {
    <#
    .SYNOPSIS
        $true only for ^ses_[A-Za-z0-9]+$ WITHOUT any 'continue' marker.
    .DESCRIPTION
        Rejects empty, prefix-less, and any string containing 'continue'
        (case-insensitive): --continue is never a valid resume path.
        Pure validation, no IO. Never throws.
    #>
    [CmdletBinding()]
    param([string]$SessionId = '')
    try {
        $s = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s -match 'continue') { return $false }
        return ($s -cmatch '^ses_[A-Za-z0-9]+$')
    }
    catch { return $false }
}

function Resolve-NativeResumeDirectory {
    <#
    .SYNOPSIS
        Canonical directory wrapper over Resolve-NativeSessionDirectory.
    .DESCRIPTION
        Empty input returns ''. Otherwise delegates to the existing
        adapter resolver (dot-sourced). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Path = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        $cmd = Get-Command Resolve-NativeSessionDirectory -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            try { return ([IO.Path]::GetFullPath(([string]$Path).Trim())) }
            catch { return ([string]$Path).Trim() }
        }
        return ([string](Resolve-NativeSessionDirectory -Path ([string]$Path)))
    }
    catch { return '' }
}

function Test-NativeResumeEvidence {
    <#
    .SYNOPSIS
        Pure stdout/stderr evidence check. No IO. Never throws.
    .DESCRIPTION
        Hardened rule (P1): stdout must carry at least one NATIVE event
        object parsed from JSON (single doc or JSONL event stream, one
        object per line, as `opencode run --format json` emits) that binds
        to the expected session AND carries a native execution pointer.

        Binding: the event object must expose one of the session keys
        (sessionId | sessionID | session_id | id) whose value -ceq the
        expected SessionId. When SessionId is empty (legacy callers), the
        value must match ^ses_[A-Za-z0-9]+$ instead. An event bound to a
        different session never counts, even when the expected id appears
        elsewhere as plain text.

        Pointer: the same event object must expose a non-empty role or
        type key. Mere field-name text (JSON or not) without such a bound
        event object is NEVER proof. Plain textual output is NEVER proof.

        Stderr (or stdout) carrying a session-missing marker fails closed.
        Compatible with real OpenCode v2.2.5 JSONL (type + sessionID) and
        with the offline mock shape (role + sessionId).
    #>
    [CmdletBinding()]
    param([string]$Stdout = '', [string]$Stderr = '', [string]$SessionId = '')
    try {
        $o = ([string]$Stdout)
        if ([string]::IsNullOrWhiteSpace($o)) { return $false }
        if (([string]$Stderr) -match 'Session not found|NotFoundError') { return $false }
        if ($o -match 'Session not found|NotFoundError') { return $false }
        $exp = (([string]$SessionId).Trim())
        $lines = @($o -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) { return $false }
        if ($lines.Count -eq 1) {
            $one = ([string]$lines[0]).Trim()
            if (-not ($one.StartsWith('[') -or $one.StartsWith('{'))) { return $false }
        }
        foreach ($ln in $lines) {
            $p = $null
            try { $p = ([string]$ln | ConvertFrom-Json) } catch { continue }
            if ($null -eq $p) { continue }
            if ($p -is [System.Array]) { $cands = @($p) }
            else { $cands = @($p) }
            foreach ($ev in $cands) {
                if ($null -eq $ev) { continue }
                $bound = ''
                foreach ($k in @('sessionId', 'sessionID', 'session_id', 'id')) {
                    try {
                        $v = $null
                        if ($ev -is [System.Collections.IDictionary]) { $v = $ev[$k] }
                        else { $v = $ev.$k }
                        if (($null -ne $v) -and (-not [string]::IsNullOrWhiteSpace(([string]$v)))) { $bound = ([string]$v); break }
                    }
                    catch { }
                }
                if ([string]::IsNullOrWhiteSpace($bound)) { continue }
                if (-not [string]::IsNullOrWhiteSpace($exp)) {
                    if ($bound -cne $exp) { continue }
                }
                elseif ($bound -cnotmatch '^ses_[A-Za-z0-9]+$') { continue }
                $ptr = ''
                foreach ($k in @('role', 'type')) {
                    try {
                        $v = $null
                        if ($ev -is [System.Collections.IDictionary]) { $v = $ev[$k] }
                        else { $v = $ev.$k }
                        if (($null -ne $v) -and (-not [string]::IsNullOrWhiteSpace(([string]$v)))) { $ptr = ([string]$v); break }
                    }
                    catch { }
                }
                if ([string]::IsNullOrWhiteSpace($ptr)) { continue }
                return $true
            }
        }
        return $false
    }
    catch { return $false }
}

function New-NRResumeEnvelope {
    param(
        [bool]$Ok = $false,
        [string]$Action = 'blocked',
        [string]$Reason = 'internal-error',
        $Session = $null,
        [string]$IdempotencyKey = '',
        [string]$Generation = '',
        [string]$LeaseOwner = '',
        $EvidenceSummary = $null,
        $Run = $null
    )
    try {
        if ($null -eq $EvidenceSummary) {
            $EvidenceSummary = [pscustomobject]@{ stdout_len = 0; stderr_diag = '' }
        }
        if ($null -eq $Run) {
            $Run = [pscustomobject]@{ exit = -1; stdout_len = 0; stderr_diag = ''; timed_out = $false }
        }
        return [pscustomobject][ordered]@{
            ok = [bool]$Ok
            action = ([string]$Action)
            reason = ([string]$Reason)
            session = $Session
            evidence_summary = $EvidenceSummary
            run = $Run
            idempotency_key = ([string]$IdempotencyKey)
            generation = ([string]$Generation)
            lease_owner = ([string]$LeaseOwner)
            executed = $false
            dispatched = $false
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            ok = $false; action = 'blocked'; reason = 'internal-error'
            session = $null
            evidence_summary = [pscustomobject]@{ stdout_len = 0; stderr_diag = '' }
            run = [pscustomobject]@{ exit = -1; stdout_len = 0; stderr_diag = ''; timed_out = $false }
            idempotency_key = ''; generation = ''; lease_owner = ''
            executed = $false; dispatched = $false
        }
    }
}

function Invoke-NRRealResumeRun {
    <#
    .SYNOPSIS
        Production runner: ONE `opencode run --session` call. No --continue.
    .DESCRIPTION
        Builds `opencode run --session <id> --format json <prompt>`
        with the child working directory set to <canon> (run has no
        --dir flag), via ProcessStartInfo with timeout, NUL stdin, and
        captured stdout/stderr/exit. Never throws: timeout and launch
        failures are data. NEVER uses cmd.exe: a resolved .cmd/.bat shim
        is replaced by a same-basename .ps1 sibling run under a
        PowerShell host; without a .ps1 sibling (and no direct exe) the
        call fails closed with LAUNCH_ERROR instead of spawning a shell.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$CanonDir = '',
        [string]$PromptText = '',
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        $resolved = ([string]$BinaryCommand).Trim()
        if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'opencode' }
        if ($resolved -ceq 'opencode') {
            $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
            if (-not $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
            if ($cmd) {
                $resolved = ([string]$cmd.Source)
            }
        }
        $isCmdShim = (($resolved -like '*.cmd') -or ($resolved -like '*.bat'))
        $psHostPath = $null
        $ps1Path = $null
        if ($isCmdShim) {
            try { $ps1Path = ([IO.Path]::ChangeExtension($resolved, '.ps1')) }
            catch { $ps1Path = $null }
            $hasPs1 = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace($ps1Path)) {
                    $hasPs1 = (Test-Path -LiteralPath $ps1Path -PathType Leaf)
                }
            }
            catch { $hasPs1 = $false }
            if ($hasPs1) {
                $h = Get-Command powershell.exe -ErrorAction SilentlyContinue
                if (-not $h) { $h = Get-Command pwsh.exe -ErrorAction SilentlyContinue }
                if (-not $h) { $h = Get-Command pwsh -ErrorAction SilentlyContinue }
                if ($h) { $psHostPath = ([string]$h.Source) }
            }
            if ([string]::IsNullOrWhiteSpace($psHostPath)) {
                $exe = Get-Command opencode.exe -ErrorAction SilentlyContinue
                if ($exe -and -not [string]::IsNullOrWhiteSpace(([string]$exe.Source))) {
                    $es = ([string]$exe.Source)
                    if (($es -notlike '*.cmd') -and ($es -notlike '*.bat')) {
                        $resolved = $es
                        $isCmdShim = $false
                    }
                }
            }
            if ($isCmdShim -and [string]::IsNullOrWhiteSpace($psHostPath)) {
                return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = 'LAUNCH_ERROR:no-ps1-sibling-for-cmd-shim' }
            }
        }
        $argList = New-Object System.Collections.ArrayList
        [void]$argList.Add('run')
        [void]$argList.Add('--session'); [void]$argList.Add(([string]$SessionId))
        [void]$argList.Add('--format'); [void]$argList.Add('json')
        # NOTE: `opencode run` (v2.2.5) has no --dir flag (unrecognized-flag
        # error). The session project is resolved from the child working
        # directory instead (set on ProcessStartInfo below). Never re-add
        # --dir here: see B20 regression test.
        [void]$argList.Add(([string]$PromptText))
        $quoted = New-Object System.Collections.ArrayList
        foreach ($a in $argList) {
            $s = ([string]$a)
            $needs = ($s -match '[\s"]')
            if ($needs) {
                $e = $s -replace '"', '\"'
                [void]$quoted.Add(('"' + $e + '"'))
            }
            else { [void]$quoted.Add($s) }
        }
        $argStr = ([string[]]$quoted.ToArray() -join ' ')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if (-not [string]::IsNullOrWhiteSpace($psHostPath)) {
            $psi.FileName = $psHostPath
            $escPs1 = ($ps1Path -replace '"', '""')
            $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $escPs1 + '" ' + $argStr)
        }
        else {
            $psi.FileName = $resolved
            $psi.Arguments = $argStr
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $cd = (([string]$CanonDir)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($cd)) {
            $cdOk = $false
            try { $cdOk = (Test-Path -LiteralPath $cd -PathType Container) } catch { $cdOk = $false }
            if (-not $cdOk) {
                return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = 'LAUNCH_ERROR:working-directory-missing' }
            }
            try { $psi.WorkingDirectory = $cd } catch {
                return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('LAUNCH_ERROR:' + (Protect-NRDiag $_.Exception.Message)) }
            }
        }
        $proc = $null
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch {
            return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('LAUNCH_ERROR:' + (Protect-NRDiag $_.Exception.Message)) }
        }
        try { $proc.StandardInput.Close() } catch { }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $ms = [int]$TimeoutMs
        if ($ms -lt 100) { $ms = 100 }
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
        return [pscustomobject]@{ ok = $true; timedOut = $false; exit = -1; stdout = ''; stderr = ('RUNNER_ERROR:' + (Protect-NRDiag $_.Exception.Message)) }
    }
}

function Invoke-OrchestrationNativeResume {
    <#
    .SYNOPSIS
        Pre-effect resume probe over an existing native session.
    .DESCRIPTION
        Ordered fail-closed steps: validate inputs, pre-check session
        identity, checkpoint resumability, kernel task state, then at most
        ONE run (real or injected). Never marks dispatched/executed;
        settlement stays with the supported Claim+Settle path owned by the
        caller. Never throws on operational paths.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$ExpectedDirectory = '',
        [string]$ExpectedProjectId = '',
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$CheckpointId = '',
        [string]$CheckpointDir = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$IdempotencyKey = '',
        [string]$Generation = '',
        [string]$LeaseOwner = '',
        $Authorization = $null,
        [string]$PromptText = '',
        [int]$MaxCount = 100,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000,
        [scriptblock]$RunExecutor = $null
    )
    try {
        $key = (([string]$IdempotencyKey).Trim()).ToLowerInvariant()
        $mc = [int]$MaxCount
        if ($mc -lt 1) { $mc = 1 }
        if ($mc -gt 1000) { $mc = 1000 }
        $bin = ([string]$BinaryCommand).Trim()
        if ([string]::IsNullOrWhiteSpace($bin)) { $bin = 'opencode' }
        $to = [int]$TimeoutMs
        if ($to -lt 100) { $to = 100 }

        # (a) input validation, before any IO or run.
        if (-not (Test-NativeResumeSessionId -SessionId ([string]$SessionId))) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'session-id-invalid' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $sid = (([string]$SessionId).Trim())
        if ($key -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'invalid-idempotency-key' -IdempotencyKey (([string]$IdempotencyKey).Trim()) -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $prompt = ([string]$PromptText)
        if ([string]::IsNullOrWhiteSpace($prompt) -or ($prompt.Length -gt 2000)) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'invalid-prompt' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $promptBad = $false
        try {
            if ($prompt.Contains('`')) { $promptBad = $true }
            elseif ($prompt.Contains([string][char]13) -or $prompt.Contains([string][char]10)) { $promptBad = $true }
            elseif ($prompt -match '[&|<>^%!;$\(\)"]') { $promptBad = $true }
        }
        catch { $promptBad = $true }
        if ($promptBad) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'invalid-prompt' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }

        # Mandatory fencing: Generation/LeaseOwner require Authorization.
        $genTrim = (([string]$Generation).Trim())
        $leaseTrim = (([string]$LeaseOwner).Trim())
        $needsFencing = ((-not [string]::IsNullOrWhiteSpace($genTrim)) -or (-not [string]::IsNullOrWhiteSpace($leaseTrim)))
        if ($needsFencing -and ($null -eq $Authorization)) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        if ($needsFencing -and ($null -ne $Authorization)) {
            if (-not [string]::IsNullOrWhiteSpace($genTrim)) {
                $hasGenField = $false
                foreach ($gk in @('generation', 'expected_generation')) {
                    $gv = Get-NRValue $Authorization $gk $null
                    if (($null -ne $gv) -and (-not [string]::IsNullOrWhiteSpace(([string]$gv)))) { $hasGenField = $true }
                }
                if (-not $hasGenField) {
                    return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($leaseTrim)) {
                $hasLeaseField = $false
                foreach ($lk in @('lease_owner', 'expected_lease_owner')) {
                    $lv = Get-NRValue $Authorization $lk $null
                    if (($null -ne $lv) -and (-not [string]::IsNullOrWhiteSpace(([string]$lv)))) { $hasLeaseField = $true }
                }
                if (-not $hasLeaseField) {
                    return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
                }
            }
        }

        # Authorization gate (caller-owned fencing token). Absent is only
        # allowed on the legacy path (Generation and LeaseOwner both
        # empty); any fencing use requires a present token (enforced
        # above). Present token must allow explicitly.
        if ($null -ne $Authorization) {
            $explicit = Get-NRValue $Authorization 'explicit_allow' $null
            if (($explicit -isnot [bool]) -or (-not $explicit)) {
                return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
            }
            $src = (([string](Get-NRValue $Authorization 'source' '')).Trim()).ToLowerInvariant()
            if (($src -ceq 'test-callback') -or [bool](Get-NRValue $Authorization 'test_callback_only' $false)) {
                return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
            }
            $authGoal = (([string](Get-NRValue $Authorization 'goal_id' '')).Trim())
            if ((-not [string]::IsNullOrWhiteSpace($authGoal)) -and (-not [string]::IsNullOrWhiteSpace(([string]$GoalId).Trim())) -and ($authGoal -cne (([string]$GoalId).Trim()))) {
                return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
            }
            foreach ($gk in @('generation', 'expected_generation')) {
                $gv = Get-NRValue $Authorization $gk $null
                if (($null -ne $gv) -and (-not [string]::IsNullOrWhiteSpace(([string]$gv)))) {
                    if (([string]$gv).Trim() -cne (([string]$Generation).Trim())) {
                        return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
                    }
                }
            }
            foreach ($lk in @('lease_owner', 'expected_lease_owner')) {
                $lv = Get-NRValue $Authorization $lk $null
                if (($null -ne $lv) -and (-not [string]::IsNullOrWhiteSpace(([string]$lv)))) {
                    if (([string]$lv).Trim() -cne (([string]$LeaseOwner).Trim())) {
                        return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
                    }
                }
            }
            foreach ($ek in @('lease_expires_utc', 'expected_lease_expires_utc')) {
                $ev2 = Get-NRValue $Authorization $ek $null
                if (($null -ne $ev2) -and (-not [string]::IsNullOrWhiteSpace(([string]$ev2)))) {
                    $expired = $true
                    try {
                        $sty = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                        $expUtc = [DateTime]::Parse((([string]$ev2).Trim()), [System.Globalization.CultureInfo]::InvariantCulture, $sty)
                        $expired = ($expUtc -lt [DateTime]::UtcNow)
                    }
                    catch { $expired = $true }
                    if ($expired) {
                        return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'authorization-denied' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
                    }
                }
            }
        }

        # (b) pre-check session identity. HOLD on any refusal: never run.
        $identCmd = Get-Command Get-NativeSessionIdentity -ErrorAction SilentlyContinue
        if ($null -eq $identCmd) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'session-not-found' -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $pre = $null
        try {
            $pre = Get-NativeSessionIdentity -SessionId $sid -ExpectedDirectory ([string]$ExpectedDirectory) -ExpectedProjectId ([string]$ExpectedProjectId) -MaxCount $mc -BinaryCommand $bin -TimeoutMs $to
        }
        catch { $pre = $null }
        if (($null -eq $pre) -or (-not [bool](Get-NRValue $pre 'ok' $false))) {
            $why = 'session-not-found'
            try {
                $r = ([string](Get-NRValue $pre 'reason' ''))
                if (($r -ceq 'project-mismatch') -or ($r -ceq 'directory-mismatch') -or ($r -ceq 'session-id-invalid') -or ($r -ceq 'session-not-found') -or ($r -ceq 'session-archived')) { $why = $r }
            }
            catch { }
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason $why -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $sess = Get-NRValue $pre 'session' $null

        # (c) checkpoint load + resume gate. HOLD on any refusal.
        $loadCmd = Get-Command Load-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue
        $resumeCmd = Get-Command Test-OrchestrationCheckpointResume -ErrorAction SilentlyContinue
        if (($null -eq $loadCmd) -or ($null -eq $resumeCmd)) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'checkpoint-not-found' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $cid = (([string]$CheckpointId).Trim())
        $load = $null
        try { $load = Load-OrchestrationGoalCheckpoint -CheckpointId $cid -StoreDir ([string]$CheckpointDir) }
        catch { $load = $null }
        if (($null -eq $load) -or (-not [bool](Get-NRValue $load 'ok' $false))) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'checkpoint-not-found' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $ckpt = Get-NRValue $load 'checkpoint' $null
        $gidWant = (([string]$GoalId).Trim())
        if (-not [string]::IsNullOrWhiteSpace($gidWant)) {
            $gidGot = ''
            try { $gidGot = ([string](Get-NRValue $ckpt 'goal_id' '')) } catch { $gidGot = '' }
            if ([string]::IsNullOrWhiteSpace($gidGot) -or ($gidGot -cne $gidWant)) {
                return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'checkpoint-not-found' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
            }
        }
        $resume = $null
        try { $resume = Test-OrchestrationCheckpointResume -Checkpoint $ckpt -GoalStoreDir ([string]$GoalStoreDir) }
        catch { $resume = $null }
        if (($null -eq $resume) -or (-not [bool](Get-NRValue $resume 'resumable' $false))) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'resume-not-resumable' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }

        # (d) kernel task state. DONE never re-executes; only BLOCKED or
        # IMPLEMENTING may resume; anything else is not ready.
        $taskCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $taskCmd) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'kernel-not-ready' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId ([string]$TaskId) -TasksDir ([string]$TasksDir) -RepoRoot ([string]$RepoRoot) }
        catch { $task = $null }
        if ($null -eq $task) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'kernel-not-ready' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $taskErr = ([string](Get-NRValue $task 'error' ''))
        if (-not [string]::IsNullOrWhiteSpace($taskErr)) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'kernel-not-ready' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        $state = ''
        try { $state = (([string](Get-NRValue $task 'state' '')).Trim()).ToUpperInvariant() } catch { $state = '' }
        if ($state -ceq 'DONE') {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'already-done' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }
        if (($state -cne 'BLOCKED') -and ($state -cne 'IMPLEMENTING')) {
            return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'kernel-not-ready' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
        }

        # (e) run: exactly one invocation, only after all pre-checks.
        $canonDir = ''
        try {
            $sessDir = ([string](Get-NRValue $sess 'directory' ''))
            $canonDir = Resolve-NativeResumeDirectory -Path $sessDir
            if ([string]::IsNullOrWhiteSpace($canonDir)) {
                $canonDir = Resolve-NativeResumeDirectory -Path ([string]$ExpectedDirectory)
            }
        }
        catch { $canonDir = '' }
        $spec = [pscustomobject][ordered]@{
            session_id = $sid
            directory = $canonDir
            prompt = $prompt
            binary_command = $bin
            timeout_ms = $to
            args = @('run', '--session', $sid, '--format', 'json')
        }
        $runOut = $null
        if ($null -ne $RunExecutor) {
            try { $runOut = & $RunExecutor $spec }
            catch {
                $runOut = [pscustomobject]@{ exit = -1; stdout = ''; stderr = ('EXECUTOR_ERROR:' + (Protect-NRDiag $_.Exception.Message)); timedOut = $false }
            }
        }
        else {
            $runOut = Invoke-NRRealResumeRun -SessionId $sid -CanonDir $canonDir -PromptText $prompt -BinaryCommand $bin -TimeoutMs $to
        }
        if ($null -eq $runOut) {
            $runOut = [pscustomobject]@{ exit = -1; stdout = ''; stderr = 'EXECUTOR_EMPTY'; timedOut = $false }
        }
        $timedOut = [bool](Get-NRValue $runOut 'timedOut' $false)
        if (-not $timedOut) {
            try { if ([bool](Get-NRValue $runOut 'timed_out' $false)) { $timedOut = $true } } catch { }
        }
        $exit = -1
        try { $exit = [int](Get-NRValue $runOut 'exit' -1) } catch { $exit = -1 }
        $stdout = ([string](Get-NRValue $runOut 'stdout' ''))
        if ([string]::IsNullOrWhiteSpace($stdout)) {
            try {
                $alt = Get-NRValue $runOut 'output' $null
                if ($null -ne $alt) { $stdout = ([string]$alt) }
            }
            catch { }
        }
        if ($null -eq $stdout) { $stdout = '' } else { $stdout = ([string]$stdout) }
        $stderr = ([string](Get-NRValue $runOut 'stderr' ''))
        if ($null -eq $stderr) { $stderr = '' } else { $stderr = ([string]$stderr) }
        $ev = [pscustomobject]@{ stdout_len = $stdout.Length; stderr_diag = (Protect-NRDiag $stderr) }
        $rk = [pscustomobject]@{ exit = $exit; stdout_len = $stdout.Length; stderr_diag = (Protect-NRDiag $stderr); timed_out = [bool]$timedOut }

        if ($timedOut) {
            # Outcome unknown: reconcile, never blind resend.
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'timeout-unknown' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }
        if ([string]::IsNullOrWhiteSpace($stdout) -and ($stderr -match 'Session not found|NotFoundError|starts_with|Expected a string')) {
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'session-not-found-post' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }
        if ($exit -ne 0) {
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'resume-unproven' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }

        # (f) post-run identity: same session must still exist unchanged.
        $post = $null
        try {
            $post = Get-NativeSessionIdentity -SessionId $sid -ExpectedDirectory ([string]$ExpectedDirectory) -ExpectedProjectId ([string]$ExpectedProjectId) -MaxCount $mc -BinaryCommand $bin -TimeoutMs $to
        }
        catch { $post = $null }
        if (($null -eq $post) -or (-not [bool](Get-NRValue $post 'ok' $false))) {
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'identity-diverged' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }
        $postSess = Get-NRValue $post 'session' $null
        try {
            $prePid = ([string](Get-NRValue $sess 'projectId' ''))
            $postPid = ([string](Get-NRValue $postSess 'projectId' ''))
            if ($prePid -cne $postPid) {
                return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'identity-diverged' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
            }
            $preDir = Resolve-NativeResumeDirectory -Path ([string](Get-NRValue $sess 'directory' ''))
            $postDir = Resolve-NativeResumeDirectory -Path ([string](Get-NRValue $postSess 'directory' ''))
            if ((-not [string]::IsNullOrWhiteSpace($preDir)) -and (-not [string]::IsNullOrWhiteSpace($postDir)) -and ($preDir -ine $postDir)) {
                return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'identity-diverged' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
            }
        }
        catch {
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'identity-diverged' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }

        # (g) native execution evidence is required.
        if (-not (Test-NativeResumeEvidence -Stdout $stdout -Stderr $stderr -SessionId $sid)) {
            return (New-NRResumeEnvelope -Ok $false -Action 'reconcile' -Reason 'resume-unproven' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
        }

        # (h) proceed. Settlement (Claim+Settle) stays with the caller;
        # this envelope never declares dispatched/executed.
        return (New-NRResumeEnvelope -Ok $true -Action 'proceed' -Reason '' -Session $sess -IdempotencyKey $key -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner) -EvidenceSummary $ev -Run $rk)
    }
    catch {
        return (New-NRResumeEnvelope -Ok $false -Action 'blocked' -Reason 'internal-error' -IdempotencyKey (([string]$IdempotencyKey).Trim()) -Generation ([string]$Generation) -LeaseOwner ([string]$LeaseOwner))
    }
}
