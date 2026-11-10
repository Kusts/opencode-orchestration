<#!
.SYNOPSIS
    V3 Task Kernel: runtime-neutral persistent task state (Phases 9-11).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the CAS-backed
    task record kernel from ORCHESTRATION-V3.1-KERNEL-HARDENING (plan Phases
    9/10/11, SPEC sections 18-22):

      - Task records under cache/runtime/tasks/<TASK_ID>.json (schema v1).
      - Every mutation requires -ExpectedRevision (CAS); stale writes return
        CAS_CONFLICT without disk mutation.
      - Explicit state machine; illegal transitions return ILLEGAL_TRANSITION
        without disk mutation. DONE/EXHAUSTED/CANCELLED are terminal.
      - Evidence contract: workers may only record candidate_pass/failed/
        blocked; anything else returns STATUS_NOT_ALLOWED_FROM_WORKER.
      - Only Complete-OrchestrationTask may persist DONE (kernel-authorized),
        after Test-OrchestrationTaskCompletion passes.
      - Execution grants: effective authority is the INTERSECTION of role
        baseline, task grants, runtime capability and environment grants
        (never union). Sensitive grants (destructive.fs, deploy.production,
        secrets.read, git.push) are in NO role baseline and require the
        grant in ALL THREE sets (task + runtime + environment) plus
        -HumanApproved; omitting any set excludes them.
      - Privileged mutations (transitions into IMPLEMENTING/VALIDATING/
        REVIEWING, Complete always, Cancel by non-owner) require a trusted
        -ActorIdentitySource; otherwise UNTRUSTED_IDENTITY.
      - Flag seam (Phase 19): task_kernel{enabled,shadow} read from
        -FlagsPath (default source/registry/capability-flags.json). When
        disabled, every mutation returns KERNEL_DISABLED without writing;
        reads/status stay allowed. This file never writes capability flags.
      - Telemetry is best-effort via CapabilityObservability (events
        TASK_CREATED, TASK_STATE_CHANGED, CANDIDATE_RESULT_RECORDED,
        TASK_DONE, TASK_EXHAUSTED, TASK_CANCELLED); failure never blocks.
        TASK_CREATED/TASK_DONE carry a hashes-only correlation envelope
        (New-CorrelationEnvelope: objective sha256 over len:value framed
        canonical text + hashed goal/run/session/decision/settlement +
        attempt_n, all omitted-when-absent, caps inherited from the
        observability sanitizer).
      - Concurrency: every mutation serializes read-check-write under an
        interprocess lock file (<task>.lock) opened with FileShare.None
        plus bounded retry (20 x 100ms); timeout returns LOCK_TIMEOUT.
        ExpectedRevision is re-checked INSIDE the critical section and the
        write (temp+move) happens while holding the lock. Creation holds
        the same lock with CreateNew semantics (ALREADY_EXISTS, no
        overwrite).
      - Free-text fields are secret-redacted (CapabilitySanitize value
        pattern) and capped at 2000 chars before persistence.
      - Verification is never self-attested: Set-OrchestrationTaskVerification
        requires the parsed Invoke-OrchestrationVerifier result
        (-VerifierEvidenceJson); Passed derives from its status field and
        only 'verified_pass' counts as passed. Mismatch with a caller
        -Passed value fails closed (VERIFIER_RESULT_MISMATCH). Caller input
        is NEVER trusted for escalation: that path always persists
        verification_source='caller-supplied' and verifier_executed=false
        (plus source='caller-supplied'); only the kernel-executed
        verify-run path may persist kernel-executed marks.
        Test-OrchestrationTaskCompletion (and therefore
        Complete-OrchestrationTask) additionally requires coherent
        kernel-executed verification: verification_source AND source are
        exactly 'kernel-executed', verifier_executed is true, status is
        exactly 'verified_pass' with passed true, and the persisted
        criterion evidence maps every acceptance criterion with status
        'verified' agreeing with the persisted criterion_map. Anything
        else fails closed with 'verification-untrusted' (caller-supplied
        verified_pass included: readable data, never DONE-capable).
      - Test-OrchestrationTaskCompletion keeps the -OrchestrationCompliance
        param (preflight runs in-process upstream and cannot be re-run by
        the kernel without its inputs); a provided verdict must equal
        'COMPLIANT' and the verdict is recorded on completion. RESIDUAL:
        compliance verdict provenance is the caller's preflight invocation;
        the final CLI is the integration point.
      - Reuses CapabilitySchema (ConvertTo-DeterministicJson, Get-LogicalHash)
        and OrchestrationPreflight (Test-OrchestrationDoneCompliance verdict
        strings) by dot-sourcing; never duplicates them.
      - Phase 27 slice 1 (kernel-side): optional strategy/recovery fields
        on failed attempts with canonical SHA-256 fingerprints (strategy,
        recovery, typed wait, work unit); stall gates on attempt start
        (STALLED_STRATEGY_REJECTED, DEBUGGER_REQUIRED, EXHAUSTED);
        typed BLOCKED waits with idempotent re-block and referenced
         unblock; active-work dedupe (DUPLICATE_ACTIVE_WORK, never merge).
         Legacy calls/records without the new fields behave as before.
      - Phase 32 session bindings live in the task record; the kernel is
        canonical and plugin indexes are disposable. active_execution_owner
        is task-scoped (stricter than work-unit scope) because P27 dedupe and
        idempotency are task-scoped; multiple work units per task are future
        work. Cross-process binding coordination remains HOLD.
      - Verification/model root binding: New-OrchestrationTask persists a
        normalized verification_repo_root (GetFullPath of the canonical
        RepoRoot/default at creation). Invoke-TaskKernelVerifyRun,
        Set-OrchestrationTaskModelAttempt and
        Get-OrchestrationTaskModelFailureProof require that stored root;
        a record without it (every task created before this field) fails
        closed with *_ROOT_UNBOUND and no mutation. A nonempty caller
        -RepoRoot is only an assertion: it must resolve to the stored root
        or the call fails closed with *_ROOT_MISMATCH and no mutation; an
        omitted/empty -RepoRoot uses the stored root for verification
        policy/profile/model policy execution. TasksDir/FlagsPath stay
        independent (explicit TasksDir still locates the file; flags still
        resolve from the caller). No implicit migration or rebind.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects ({ok:$false, error:'CODE'}), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$taskKernelSchemaPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if (Test-Path -LiteralPath $taskKernelSchemaPath -PathType Leaf) {
    . $taskKernelSchemaPath
}
$taskKernelObservabilityPath = Join-Path $PSScriptRoot 'CapabilityObservability.ps1'
if (Test-Path -LiteralPath $taskKernelObservabilityPath -PathType Leaf) {
    . $taskKernelObservabilityPath
}
$taskKernelPreflightPath = Join-Path $PSScriptRoot 'OrchestrationPreflight.ps1'
if (Test-Path -LiteralPath $taskKernelPreflightPath -PathType Leaf) {
    . $taskKernelPreflightPath
}
$taskKernelSanitizePath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $taskKernelSanitizePath -PathType Leaf) {
    . $taskKernelSanitizePath
}
$taskKernelOwnershipPath = Join-Path $PSScriptRoot 'OrchestrationOwnership.ps1'
if (Test-Path -LiteralPath $taskKernelOwnershipPath -PathType Leaf) {
    . $taskKernelOwnershipPath
}
$taskKernelBudgetPath = Join-Path $PSScriptRoot 'OrchestrationExecutionBudget.ps1'
if (Test-Path -LiteralPath $taskKernelBudgetPath -PathType Leaf) {
    . $taskKernelBudgetPath
}

# ---------- repo / path helpers ----------

function Get-TaskKernelRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-TaskKernelDefaultTasksDir {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-TaskKernelRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'cache\runtime\tasks')
}

function Get-TaskKernelDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-TaskKernelRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function Get-TaskKernelDefaultGrantsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-TaskKernelRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\execution-grants.json')
}

function Get-TaskKernelFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return ([IO.Path]::GetFullPath($Path)) }
    catch { return $Path }
}

function Test-TaskKernelId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    return ([string]$TaskId -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
}

function Test-TaskKernelPathHasReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while (-not [string]::IsNullOrWhiteSpace($current) -and $guard -lt 128) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    $linkType = [string]$item.LinkType
                    if ($item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -ine 'HardLink') { return $true }
                } catch { }
            } catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-TaskKernelFilePath {
    <#
    .SYNOPSIS
        Resolves the confined task file path, or '' when invalid.
    #>
    [CmdletBinding()]
    param([string]$TaskId, [string]$TasksDir, [string]$RepoRoot)
    if (-not (Test-TaskKernelId -TaskId $TaskId)) { return '' }
    $dir = $TasksDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-TaskKernelDefaultTasksDir -RepoRoot $RepoRoot }
    $fullDir = ''
    $fullFile = ''
    try {
        $fullDir = [IO.Path]::GetFullPath($dir)
        $fullFile = [IO.Path]::GetFullPath((Join-Path $fullDir ([string]$TaskId + '.json')))
    }
    catch { return '' }
    $sep = $fullDir.TrimEnd('\', '/') + '\'
    if (-not $fullFile.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $fullFile
}

function Test-TaskKernelWriteBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskFile)
    try {
        $parent = Split-Path -Parent $TaskFile
        foreach ($p in @($TaskFile, $parent)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-TaskKernelPathHasReparsePoint -Path $p) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-TaskKernelStringHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
}

function Get-TaskKernelTimestamp {
    [CmdletBinding()]
    param()
    return ((Get-Date).ToUniversalTime().ToString('o'))
}

function New-TaskKernelError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code, $Extra)
    $r = [ordered]@{ ok = $false; error = $Code }
    if ($null -ne $Extra) {
        if ($Extra -is [System.Collections.IDictionary]) {
            foreach ($k in @($Extra.Keys)) { $r[[string]$k] = $Extra[$k] }
        }
        else {
            foreach ($p in @($Extra.PSObject.Properties)) { $r[$p.Name] = $p.Value }
        }
    }
    return ([PSCustomObject]$r)
}

# ---------- flags (Phase 19 seam, read-only) ----------

function Get-TaskKernelFlagState {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $out = @{ enabled = $false; shadow = $false }
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-TaskKernelDefaultFlagsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        if ($null -eq $doc) { return $out }
        $tk = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('task_kernel')) { $tk = $doc['task_kernel'] }
        }
        else {
            $prop = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'task_kernel' } | Select-Object -First 1
            if ($null -ne $prop) { $tk = $prop.Value }
        }
        if ($null -eq $tk) { return $out }
        foreach ($field in @('enabled', 'shadow')) {
            $slot = $null
            if ($tk -is [System.Collections.IDictionary]) {
                if ($tk.Contains($field)) { $slot = $tk[$field] }
            }
            else {
                $fp = $tk.PSObject.Properties | Where-Object { $_.Name -ceq $field } | Select-Object -First 1
                if ($null -ne $fp) { $slot = $fp.Value }
            }
            if (($null -ne $slot) -and ($slot -is [bool])) {
                if ($field -ceq 'enabled') { $out.enabled = [bool]$slot }
                else { $out.shadow = [bool]$slot }
            }
        }
    }
    catch { return $out }
    return $out
}

# ---------- record IO ----------

function ConvertTo-TaskKernelOrdered {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return [string]$Node }
    if ($Node -is [bool]) { return [bool]$Node }
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Node.Keys)) {
            $o[[string]$k] = (ConvertTo-TaskKernelOrdered -Node $Node[$k])
        }
        return $o
    }
    if ($Node -is [System.ValueType]) { return $Node }
    if ($Node -is [System.Collections.IEnumerable]) {
        $a = @()
        foreach ($e in $Node) { $a += (ConvertTo-TaskKernelOrdered -Node $e) }
        # Comma wrap: a zero/single/multiple element array must reach the
        # caller as an ARRAY (a plain `return $a` unwraps singletons to a
        # scalar and empties to $null through the pipeline). `Write-Output
        # -NoEnumerate` is NOT used here: in PS 5.1 the value it returns is
        # serialized by ConvertTo-Json as {"value":[...],"Count":n}.
        return ,$a
    }
    $o = [ordered]@{}
    foreach ($p in @($Node.PSObject.Properties)) {
        $o[$p.Name] = (ConvertTo-TaskKernelOrdered -Node $p.Value)
    }
    return $o
}

function Read-TaskKernelRecord {
    <#
    .SYNOPSIS
        Reads a task file. Returns @{found, malformed, record, revision}.
        Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskFile)
    $out = @{ found = $false; malformed = $false; record = $null; revision = 0 }
    try {
        if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) { return $out }
        $out.found = $true
        $text = ''
        try { $text = [IO.File]::ReadAllText($TaskFile, [Text.UTF8Encoding]::new($false)) }
        catch { $out.malformed = $true; return $out }
        $doc = $null
        try { $doc = ($text | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $doc) { $out.malformed = $true; return $out }
        $rec = ConvertTo-TaskKernelOrdered -Node $doc
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary])) { $out.malformed = $true; return $out }
        $out.record = $rec
        try { $out.revision = [int]$rec['revision'] } catch { $out.revision = 0 }
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Write-TaskKernelRecord {
    <#
    .SYNOPSIS
        Atomic write: temp file in same dir + move + post-write hash check.
        UTF-8 no BOM, LF only. Returns @{ok, error}.
    #>
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory = $true)][string]$TaskFile)
    try {
        $parent = Split-Path -Parent $TaskFile
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = ConvertTo-DeterministicJson -InputObject $Record
        if ([string]::IsNullOrWhiteSpace($json)) { return @{ ok = $false; error = 'WRITE_FAILED' } }
        $text = ($json + "`n")
        $tmp = Join-Path $parent (([IO.Path]::GetFileName($TaskFile)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        try {
            Move-Item -LiteralPath $tmp -Destination $TaskFile -Force
        }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
            return @{ ok = $false; error = 'WRITE_FAILED' }
        }
        try {
            $back = [IO.File]::ReadAllText($TaskFile, [Text.UTF8Encoding]::new($false))
            if ((Get-TaskKernelStringHash -Text $text) -cne (Get-TaskKernelStringHash -Text $back)) {
                return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' }
            }
            $null = ($back | ConvertFrom-Json)
        }
        catch { return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' } }
        return @{ ok = $true; error = '' }
    }
    catch { return @{ ok = $false; error = 'WRITE_FAILED' } }
}

function Write-TaskKernelRecordCreateNew {
    <#
    .SYNOPSIS
        Creation-only atomic write: temp file + [IO.File]::Move (CreateNew).
        On .NET Framework File.Move THROWS when destination exists, which
        yields ALREADY_EXISTS without overwrite. Never uses Move-Item -Force.
        Returns @{ok, error}. Cleans temp residue on failure. Never throws.
    #>
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory = $true)][string]$TaskFile)
    $tmp = ''
    try {
        $parent = Split-Path -Parent $TaskFile
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = ConvertTo-DeterministicJson -InputObject $Record
        if ([string]::IsNullOrWhiteSpace($json)) { return @{ ok = $false; error = 'WRITE_FAILED' } }
        $text = ($json + "`n")
        $tmp = Join-Path $parent (([IO.Path]::GetFileName($TaskFile)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        try {
            [IO.File]::Move($tmp, $TaskFile)
        }
        catch [System.IO.IOException] {
            try { if (-not [string]::IsNullOrWhiteSpace($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            if (Test-Path -LiteralPath $TaskFile -PathType Leaf) {
                return @{ ok = $false; error = 'ALREADY_EXISTS' }
            }
            return @{ ok = $false; error = 'WRITE_FAILED' }
        }
        catch {
            try { if (-not [string]::IsNullOrWhiteSpace($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            if (Test-Path -LiteralPath $TaskFile -PathType Leaf) {
                return @{ ok = $false; error = 'ALREADY_EXISTS' }
            }
            return @{ ok = $false; error = 'WRITE_FAILED' }
        }
        $tmp = ''
        try {
            $back = [IO.File]::ReadAllText($TaskFile, [Text.UTF8Encoding]::new($false))
            if ((Get-TaskKernelStringHash -Text $text) -cne (Get-TaskKernelStringHash -Text $back)) {
                return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' }
            }
            $null = ($back | ConvertFrom-Json)
        }
        catch { return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' } }
        return @{ ok = $true; error = '' }
    }
    catch {
        try { if (-not [string]::IsNullOrWhiteSpace($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
        if (Test-Path -LiteralPath $TaskFile -PathType Leaf) {
            return @{ ok = $false; error = 'ALREADY_EXISTS' }
        }
        return @{ ok = $false; error = 'WRITE_FAILED' }
    }
}

# ---------- interprocess file lock (F1) ----------

function Enter-TaskKernelFileLock {
    <#
    .SYNOPSIS
        Opens <TaskFile>.lock with FileShare.None (bounded retry).
        Returns @{acquired, handle, lockFile}. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskFile,
        [int]$Retries = 80,
        [int]$DelayMs = 100
    )
    $out = @{ acquired = $false; handle = $null; lockFile = ([string]$TaskFile + '.lock') }
    try {
        $parent = Split-Path -Parent $TaskFile
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $tries = [int]$Retries
        if ($tries -lt 1) { $tries = 1 }
        for ($i = 0; $i -lt $tries; $i++) {
            try {
                $fs = [IO.File]::Open(
                    [string]$out.lockFile,
                    [IO.FileMode]::OpenOrCreate,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None)
                $out.handle = $fs
                $out.acquired = $true
                return $out
            }
            catch [System.IO.IOException] {
                if ($i -ge ($tries - 1)) { break }
                Start-Sleep -Milliseconds ([int]$DelayMs)
            }
            catch {
                if ($i -ge ($tries - 1)) { break }
                Start-Sleep -Milliseconds ([int]$DelayMs)
            }
        }
    }
    catch { }
    return $out
}

function Exit-TaskKernelFileLock {
    <#
    .SYNOPSIS
        Releases the handle and deletes the lock file best-effort.
        Never throws.
    #>
    [CmdletBinding()]
    param($Handle, [string]$LockFile)
    try {
        if ($null -ne $Handle) {
            try { $Handle.Close() } catch { }
            try { $Handle.Dispose() } catch { }
        }
    }
    catch { }
    try {
        if (-not [string]::IsNullOrWhiteSpace($LockFile)) {
            Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

# ---------- free-text sanitize (F8) ----------

function Protect-TaskKernelText {
    <#
    .SYNOPSIS
        Secret-value redaction (CapabilitySanitize pattern, substring
        preserving) + 2000 char cap. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    $t = [string]$Text
    try {
        if ((Get-Command Get-SecretValuePattern -ErrorAction SilentlyContinue) -ne $null) {
            $pat = Get-SecretValuePattern
            if (-not [string]::IsNullOrWhiteSpace([string]$pat)) {
                $t = ([regex]::Replace($t, [string]$pat, '[REDACTED]'))
            }
        }
    }
    catch { $t = [string]$Text }
    try {
        if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) }
    }
    catch { }
    return $t
}

function Protect-TaskKernelStringList {
    <#
    .SYNOPSIS
        Applies Protect-TaskKernelText to every item of a string array.
        Never throws.
    #>
    [CmdletBinding()]
    param([string[]]$Items)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($s in @($Items)) {
            $out.Add((Protect-TaskKernelText -Text ([string]$s))) | Out-Null
        }
    }
    catch { }
    return ([string[]]$out.ToArray())
}

# ---------- correlation envelope (objective -> settlement, best-effort) ----------
# F6 envelope: links TASK_CREATED to TASK_DONE with zero raw text. Every id
# is hashed, the objective is a sha256 over len:value framed canonical text
# (P25 convention, never raw). Keys use the corr_* namespace with
# sanitizer-safe aliases (corr_sess, never session_id: the observability
# sanitizer drops keys matching the sensitive pattern, which includes
# 'session'). All fields optional/omitted-when-absent. Persisted values go
# through Get-ObservabilitySanitizedMetadata (<=10 keys, strings re-hashed
# to h:<16hex>, ints kept, retry/duration clamped by New-ObservabilityEvent),
# so caps are inherited here, never reimplemented. Never throws.

function Get-TaskKernelCorrelationHash16 {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ((Get-Command Get-ObservabilityHash16 -ErrorAction SilentlyContinue) -ne $null) {
            return ([string](Get-ObservabilityHash16 -Text $s))
        }
        if ((Get-Command Get-TaskKernelStringHash -ErrorAction SilentlyContinue) -ne $null) {
            $h = ([string](Get-TaskKernelStringHash -Text $s.ToLowerInvariant()))
            if ($h.Length -ge 16) { return ('h:' + $h.Substring(0, 16)) }
        }
    }
    catch { }
    return ''
}

function New-CorrelationEnvelope {
    <#
    .SYNOPSIS
        Builds the objective->settlement correlation envelope (hashes only).
        Every field optional/omitted-when-absent. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$Objective = '',
        [string]$RunId = '',
        [string]$SessionId = '',
        $AttemptN = $null,
        [string]$DecisionRef = '',
        [string]$SettlementState = ''
    )
    $env = [ordered]@{}
    try {
        $g = Get-TaskKernelCorrelationHash16 -Text ([string]$GoalId)
        if (-not [string]::IsNullOrWhiteSpace($g)) { $env['corr_goal'] = $g }
        try {
            $canon = ''
            if ((Get-Command Get-TaskKernelCanonicalText -ErrorAction SilentlyContinue) -ne $null) {
                $canon = ([string](Get-TaskKernelCanonicalText -Text ([string]$Objective))).Trim()
            }
            else {
                $canon = (([string]$Objective).Trim().ToLowerInvariant())
            }
            if (-not [string]::IsNullOrWhiteSpace($canon)) {
                $frame = ''
                if ((Get-Command Get-TaskKernelFrame -ErrorAction SilentlyContinue) -ne $null) {
                    $frame = ([string](Get-TaskKernelFrame -Text $canon))
                }
                else {
                    $frame = ($canon.Length.ToString([Globalization.CultureInfo]::InvariantCulture) + ':' + $canon)
                }
                $hex = ''
                if ((Get-Command Get-TaskKernelStringHash -ErrorAction SilentlyContinue) -ne $null) {
                    $hex = ([string](Get-TaskKernelStringHash -Text $frame)).ToLowerInvariant()
                }
                if ($hex -cmatch '^[0-9a-f]{64}$') { $env['corr_objective'] = ('sha256:' + $hex) }
            }
        }
        catch { }
        $r = Get-TaskKernelCorrelationHash16 -Text ([string]$RunId)
        if (-not [string]::IsNullOrWhiteSpace($r)) { $env['corr_run'] = $r }
        $sess = Get-TaskKernelCorrelationHash16 -Text ([string]$SessionId)
        if (-not [string]::IsNullOrWhiteSpace($sess)) { $env['corr_sess'] = $sess }
        try {
            if ($null -ne $AttemptN) {
                $n = 0
                if ([int]::TryParse(([string]$AttemptN).Trim(), [ref]$n)) {
                    if (($n -ge 1) -and ($n -le 99)) { $env['corr_attempt'] = [int]$n }
                }
            }
        }
        catch { }
        $d = Get-TaskKernelCorrelationHash16 -Text ([string]$DecisionRef)
        if (-not [string]::IsNullOrWhiteSpace($d)) { $env['corr_decision'] = $d }
        $st = Get-TaskKernelCorrelationHash16 -Text ([string]$SettlementState)
        if (-not [string]::IsNullOrWhiteSpace($st)) { $env['corr_settlement'] = $st }
    }
    catch { }
    return $env
}

# ---------- telemetry (best-effort, never blocks) ----------

function Send-TaskKernelTelemetry {
    [CmdletBinding()]
    param([string]$EventType, [string]$TaskId, $Runtime, [string]$TelemetryRoot, $Correlation = $null)
    try {
        if ((Get-Command New-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        if ((Get-Command Write-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        $rid = ''
        $gen = 0
        $prof = ''
        try {
            if ($null -ne $Runtime) {
                if ($Runtime -is [System.Collections.IDictionary]) {
                    if ($null -ne $Runtime['id']) { $rid = [string]$Runtime['id'] }
                    if ($null -ne $Runtime['generation']) { $gen = [int]$Runtime['generation'] }
                    if ($null -ne $Runtime['profile']) { $prof = [string]$Runtime['profile'] }
                }
                else {
                    $pi = $Runtime.PSObject.Properties | Where-Object { $_.Name -ceq 'id' } | Select-Object -First 1
                    if ($null -ne $pi) { $rid = [string]$pi.Value }
                    $pg = $Runtime.PSObject.Properties | Where-Object { $_.Name -ceq 'generation' } | Select-Object -First 1
                    if ($null -ne $pg) { $gen = [int]$pg.Value }
                    $pp = $Runtime.PSObject.Properties | Where-Object { $_.Name -ceq 'profile' } | Select-Object -First 1
                    if ($null -ne $pp) { $prof = [string]$pp.Value }
                }
            }
        }
        catch { }
        $tidHash = ''
        try {
            if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -ne $null) {
                $tidHash = Get-LogicalHash -InputObject ([string]$TaskId)
            }
        }
        catch { $tidHash = '' }
        # F6-FIX1: correlation-first ordering so the 7 corr_* keys hold
        # precedence within the inherited 10-key sanitizer cap. With a
        # complete runtime (4 base + 7 corr = 11) the sanitizer keeps the
        # first 10 in insertion order, which silently discarded
        # corr_settlement. Corr-first keeps all 7 corr_* plus the first
        # 3 base keys; the no-correlation path below reuses $baseMeta
        # untouched (byte-for-byte identical). Cap itself unchanged.
        $baseMeta = [ordered]@{
            task_id_hash       = $tidHash
            runtime_id         = $rid
            runtime_generation = $gen
            profile            = $prof
        }
        $corrPairs = @()
        try {
            if (($null -ne $Correlation) -and ($Correlation -is [System.Collections.IDictionary])) {
                foreach ($k in @($Correlation.Keys)) {
                    $ck = ([string]$k).Trim()
                    if ([string]::IsNullOrWhiteSpace($ck)) { continue }
                    if ($baseMeta.Contains($ck)) { continue }
                    $corrPairs += ,@($ck, $Correlation[$k])
                }
            }
        }
        catch { $corrPairs = @() }
        $meta = $null
        try {
            if (@($corrPairs).Count -gt 0) {
                $meta = [ordered]@{}
                foreach ($pair in $corrPairs) { $meta[[string]$pair[0]] = $pair[1] }
                foreach ($bk in @($baseMeta.Keys)) { $meta[[string]$bk] = $baseMeta[$bk] }
            }
            else {
                $meta = $baseMeta
            }
        }
        catch { $meta = $baseMeta }
        $ev = New-ObservabilityEvent -TaskId ([string]$TaskId) -EventType ([string]$EventType) -Metadata $meta
        if ($null -eq $ev) { return $false }
        if ([string]::IsNullOrWhiteSpace($TelemetryRoot)) {
            return ([bool](Write-ObservabilityEvent -Event $ev))
        }
        return ([bool](Write-ObservabilityEvent -Event $ev -RepoRoot ([string]$TelemetryRoot)))
    }
    catch { return $false }
}

# ---------- validation helpers ----------

function Get-TaskKernelCleanList {
    <#
    .SYNOPSIS
        Trims string lists; returns @{valid, items}. Empty input is valid (@()).
    #>
    [CmdletBinding()]
    param($Value)
    $flat = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -eq $Value) { return @{ valid = $true; items = ([string[]]@()) } }
        foreach ($item in @($Value)) {
            if ($null -eq $item) { return @{ valid = $false; items = ([string[]]@()) } }
            if (($item -is [System.Collections.IEnumerable]) -and -not ($item -is [string])) {
                foreach ($sub in $item) {
                    if ($null -eq $sub) { return @{ valid = $false; items = ([string[]]@()) } }
                    $t = ([string]$sub).Trim()
                    if ([string]::IsNullOrWhiteSpace($t)) { return @{ valid = $false; items = ([string[]]@()) } }
                    $flat.Add($t) | Out-Null
                }
            }
            else {
                $t = ([string]$item).Trim()
                if ([string]::IsNullOrWhiteSpace($t)) { return @{ valid = $false; items = ([string[]]@()) } }
                $flat.Add($t) | Out-Null
            }
        }
    }
    catch { return @{ valid = $false; items = ([string[]]@()) } }
    return @{ valid = $true; items = ([string[]]$flat.ToArray()) }
}

function Get-TaskKernelEvidenceList {
    <#
    .SYNOPSIS
        Evidence strings preserved verbatim (prefix matching depends on it);
        rejects non-strings and blank entries.
    #>
    [CmdletBinding()]
    param($Value)
    $flat = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -eq $Value) { return @{ valid = $true; items = ([string[]]@()) } }
        foreach ($item in @($Value)) {
            if ($null -eq $item) { return @{ valid = $false; items = ([string[]]@()) } }
            if (($item -is [System.Collections.IEnumerable]) -and -not ($item -is [string])) {
                foreach ($sub in $item) {
                    if (-not ($sub -is [string])) { return @{ valid = $false; items = ([string[]]@()) } }
                    if ([string]::IsNullOrWhiteSpace([string]$sub)) { return @{ valid = $false; items = ([string[]]@()) } }
                    $flat.Add([string]$sub) | Out-Null
                }
            }
            else {
                if (-not ($item -is [string])) { return @{ valid = $false; items = ([string[]]@()) } }
                if ([string]::IsNullOrWhiteSpace([string]$item)) { return @{ valid = $false; items = ([string[]]@()) } }
                $flat.Add([string]$item) | Out-Null
            }
        }
    }
    catch { return @{ valid = $false; items = ([string[]]@()) } }
    return @{ valid = $true; items = ([string[]]$flat.ToArray()) }
}

function Get-OrchestrationTrustedIdentitySources {
    [CmdletBinding()]
    param()
    return @('runtime-v1-session-map', 'runtime-v1-input-probe', 'runtime-v2-session-context', 'runtime-v2-tool-event', 'explicit-cli')
}

function Test-OrchestrationActorIdentitySource {
    [CmdletBinding()]
    param([string]$Source)
    try {
        $s = ([string]$Source).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        return ((@(Get-OrchestrationTrustedIdentitySources) -ccontains $s))
    }
    catch { return $false }
}

function Get-TaskKernelSensitiveGrants {
    [CmdletBinding()]
    param()
    return @('destructive.fs', 'deploy.production', 'secrets.read', 'git.push')
}

function Get-OrchestrationTaskAllowedTransitions {
    [CmdletBinding()]
    param()
    return @{
        'DISCOVERING'  = @('PLANNING', 'BLOCKED', 'CANCELLED')
        'PLANNING'     = @('IMPLEMENTING', 'BLOCKED', 'CANCELLED')
        'IMPLEMENTING' = @('VALIDATING', 'BLOCKED', 'CANCELLED')
        'VALIDATING'   = @('REVIEWING', 'FIXING', 'BLOCKED', 'CANCELLED')
        'REVIEWING'    = @('FIXING', 'BLOCKED', 'CANCELLED')
        'FIXING'       = @('VALIDATING', 'BLOCKED', 'EXHAUSTED', 'CANCELLED')
        'BLOCKED'      = @('IMPLEMENTING', 'CANCELLED')
        'DONE'         = @()
        'EXHAUSTED'    = @()
        'CANCELLED'    = @()
    }
}

function Test-TaskKernelTerminalState {
    [CmdletBinding()]
    param([string]$State)
    $s = ([string]$State).Trim().ToUpperInvariant()
    return (($s -ceq 'DONE') -or ($s -ceq 'EXHAUSTED') -or ($s -ceq 'CANCELLED'))
}

# ---------- grants registry ----------

function Read-TaskKernelGrantsDoc {
    [CmdletBinding()]
    param([string]$GrantsPath, [string]$RepoRoot)
    try {
        $p = $GrantsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-TaskKernelDefaultGrantsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        if ($null -eq $doc) { return $null }
        return (ConvertTo-TaskKernelOrdered -Node $doc)
    }
    catch { return $null }
}

function Get-OrchestrationRoleBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [string]$GrantsPath,
        [string]$RepoRoot
    )
    try {
        $key = ([string]$Role).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { return ([string[]]@()) }
        $doc = Read-TaskKernelGrantsDoc -GrantsPath $GrantsPath -RepoRoot $RepoRoot
        if ($null -eq $doc) { return ([string[]]@()) }
        $baselines = $doc['role_baselines']
        if ($null -eq $baselines -or -not ($baselines -is [System.Collections.IDictionary])) { return ([string[]]@()) }
        $entry = $null
        foreach ($k in @($baselines.Keys)) {
            if ([string]$k -ceq $key) { $entry = $baselines[$k]; break }
        }
        if ($null -eq $entry) {
            foreach ($k in @($baselines.Keys)) {
                if (([string]$k).ToLowerInvariant() -ceq $key.ToLowerInvariant()) { $entry = $baselines[$k]; break }
            }
        }
        if ($null -eq $entry) { return ([string[]]@()) }
        $clean = Get-TaskKernelCleanList -Value $entry
        if (-not [bool]$clean.valid) { return ([string[]]@()) }
        $arr = ([string[]]$clean.items)
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        return $arr
    }
    catch { return ([string[]]@()) }
}

function Assert-OrchestrationGrantsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $errors = New-Object System.Collections.Generic.List[string]
    # PS 5.1 ConvertFrom-Json unwraps single-element JSON arrays into a
    # scalar, so every list here is normalized (scalar => one item).
    $toArray = {
        param($Value)
        if ($null -eq $Value) { return ([object[]]@()) }
        if ($Value -is [array]) { return ([object[]]$Value) }
        return ([object[]]@($Value))
    }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $errors.Add('file-missing') | Out-Null
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { $errors.Add('invalid-json') | Out-Null }
        if ($errors.Count -gt 0) {
            return [PSCustomObject]@{ valid = $false; errors = ([string[]]$errors.ToArray()) }
        }
        $rec = ConvertTo-TaskKernelOrdered -Node $doc
        try { if ([int]$rec['version'] -ne 1) { $errors.Add('version-must-be-1') | Out-Null } }
        catch { $errors.Add('version-must-be-1') | Out-Null }
        $expected = @('fs.read', 'fs.write', 'shell.validation', 'shell.diagnostic', 'git.diff', 'git.commit', 'git.branch', 'git.worktree', 'git.push', 'docs.write', 'db.migration.create', 'deploy.staging', 'deploy.production', 'secrets.reference', 'secrets.read', 'destructive.fs')
        $universe = @(& $toArray $rec['grants'])
        foreach ($g in $expected) {
            if ($universe -cnotcontains $g) { $errors.Add(('grants-missing:' + $g)) | Out-Null }
        }
        $baselines = $rec['role_baselines']
        if ($null -eq $baselines -or -not ($baselines -is [System.Collections.IDictionary])) {
            $errors.Add('role_baselines-missing') | Out-Null
        }
        else {
            $sensitive = @(Get-TaskKernelSensitiveGrants)
            foreach ($rk in @($baselines.Keys)) {
                $entry = @(& $toArray $baselines[$rk])
                if ($entry.Count -eq 0) { $errors.Add(('baseline-not-array:' + [string]$rk)) | Out-Null; continue }
                foreach ($g in @($entry)) {
                    if ([string]::IsNullOrWhiteSpace([string]$g)) { $errors.Add(('baseline-blank-grant:' + [string]$rk)) | Out-Null; break }
                    if ($universe -cnotcontains ([string]$g)) { $errors.Add(('baseline-unknown-grant:' + [string]$rk + ':' + [string]$g)) | Out-Null }
                    if ($sensitive -ccontains ([string]$g)) { $errors.Add(('sensitive-in-baseline:' + [string]$rk + ':' + [string]$g)) | Out-Null }
                }
            }
            $probe = $null
            foreach ($k in @($baselines.Keys)) { if ([string]$k -ceq 'explorer') { $probe = $baselines[$k]; break } }
            if ($null -ne $probe -and (@($probe) -ccontains 'fs.write')) { $errors.Add('readonly-baseline-has-fs.write:explorer') | Out-Null }
            $probe = $null
            foreach ($k in @($baselines.Keys)) { if ([string]$k -ceq 'reviewer') { $probe = $baselines[$k]; break } }
            if ($null -ne $probe -and (@($probe) -ccontains 'fs.write')) { $errors.Add('readonly-baseline-has-fs.write:reviewer') | Out-Null }
            $probe = $null
            foreach ($k in @($baselines.Keys)) { if ([string]$k -ceq 'tester') { $probe = $baselines[$k]; break } }
            if ($null -ne $probe -and (@($probe) -ccontains 'fs.write')) { $errors.Add('readonly-baseline-has-fs.write:tester') | Out-Null }
        }
        $sources = $rec['actor_identity_sources']
        if ($null -eq $sources -or -not ($sources -is [System.Collections.IDictionary])) {
            $errors.Add('actor_identity_sources-missing') | Out-Null
        }
        else {
            $trusted = @(& $toArray $sources['trusted'])
            foreach ($t in @(Get-OrchestrationTrustedIdentitySources)) {
                if ($trusted -cnotcontains $t) { $errors.Add(('identity-source-missing:' + $t)) | Out-Null }
            }
            $untrusted = @(& $toArray $sources['untrusted'])
            if ($untrusted -cnotcontains 'unknown') { $errors.Add('identity-source-missing:unknown') | Out-Null }
        }
    }
    catch { $errors.Add('internal-error') | Out-Null }
    $arr = ([string[]]$errors.ToArray())
    return [PSCustomObject]@{ valid = ($arr.Count -eq 0); errors = $arr }
}

function Get-OrchestrationEffectiveGrants {
    <#
    .SYNOPSIS
        Effective grants = INTERSECTION of role baseline, task grants,
        runtime capability grants and environment grants (never union).
        Unknown/missing role => empty set. Approval is a RESTRICTION,
        never a source: sensitive grants (destructive.fs,
        deploy.production, secrets.read, git.push) are in no baseline and
        join only when -TaskGrants AND -RuntimeCapabilityGrants AND
        -EnvironmentAuthorizationGrants ALL contain them AND -HumanApproved
        is set; omitting any of the three sets excludes them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [string[]]$TaskGrants,
        [string[]]$RuntimeCapabilityGrants,
        [string[]]$EnvironmentAuthorizationGrants,
        [switch]$HumanApproved,
        [string]$GrantsPath,
        [string]$RepoRoot
    )
    try {
        $baseline = @(Get-OrchestrationRoleBaseline -Role $Role -GrantsPath $GrantsPath -RepoRoot $RepoRoot)
        if ($baseline.Count -eq 0) { return ([string[]]@()) }
        $current = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($g in $baseline) { $current.Add([string]$g) | Out-Null }
        $sets = New-Object System.Collections.ArrayList
        if ($PSBoundParameters.ContainsKey('TaskGrants')) { [void]$sets.Add(@($TaskGrants)) }
        if ($PSBoundParameters.ContainsKey('RuntimeCapabilityGrants')) { [void]$sets.Add(@($RuntimeCapabilityGrants)) }
        if ($PSBoundParameters.ContainsKey('EnvironmentAuthorizationGrants')) { [void]$sets.Add(@($EnvironmentAuthorizationGrants)) }
        foreach ($s in $sets) {
            $next = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($g in @($s)) {
                $t = ([string]$g).Trim()
                if ($current.Contains($t)) { $next.Add($t) | Out-Null }
            }
            $current = $next
        }
        if ($PSBoundParameters.ContainsKey('TaskGrants') -and [bool]$HumanApproved `
            -and $PSBoundParameters.ContainsKey('RuntimeCapabilityGrants') `
            -and $PSBoundParameters.ContainsKey('EnvironmentAuthorizationGrants')) {
            $taskSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($g in @($TaskGrants)) { $taskSet.Add(([string]$g).Trim()) | Out-Null }
            $runtimeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($g in @($RuntimeCapabilityGrants)) { $runtimeSet.Add(([string]$g).Trim()) | Out-Null }
            $envSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($g in @($EnvironmentAuthorizationGrants)) { $envSet.Add(([string]$g).Trim()) | Out-Null }
            foreach ($s in @(Get-TaskKernelSensitiveGrants)) {
                if (-not $taskSet.Contains($s)) { continue }
                if (-not $runtimeSet.Contains($s)) { continue }
                if (-not $envSet.Contains($s)) { continue }
                $current.Add($s) | Out-Null
            }
        }
        $arr = @($current)
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        return ([string[]]$arr)
    }
    catch { return ([string[]]@()) }
}

# ---------- task operations ----------

function New-OrchestrationTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Objective,
        [string]$TaskType = 'implementation',
        [string]$Risk = 'medium',
        [string]$ParentTaskId = '',
        [string]$TraceId = '',
        [string]$OrchestrationDecision = '',
        [string]$Project = '',
        [switch]$RequireTypedWaits,
        [string]$SettlementPolicy = '',
        [string]$Actor = '',
        [string]$RuntimeId = 'opencode-v1',
        [int]$RuntimeGeneration = 1,
        [string]$RuntimeProfile = 'v1',
        [string]$RuntimeVersion = '',
        [string]$BaseRevision = '',
        [string[]]$ReadScopes = @(),
        [string[]]$WriteScopes = @(),
        [string[]]$Grants = @(),
        [string[]]$AcceptanceCriteria = @(),
        [string[]]$ExpectedArtifacts = @(),
        [string[]]$VerificationProfiles = @(),
        [string[]]$EnvironmentAllowed = @(),
        [bool]$ProductionAuthorized = $false,
        $AttemptBudget = 3,
        [string]$BudgetProfile = '',
        [string]$BudgetPolicyPath = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-TaskKernelId -TaskId $tid)) {
            return (New-TaskKernelError -Code 'INVALID_TASK_ID')
        }
        $budgetPolicyPath = $BudgetPolicyPath
        if ([string]::IsNullOrWhiteSpace($budgetPolicyPath)) {
            $budgetPolicyPath = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot
        }
        $budgetExplicit = ($PSBoundParameters.ContainsKey('BudgetProfile') -and (-not [string]::IsNullOrWhiteSpace([string]$BudgetProfile)))
        $budgetProfileName = ([string]$BudgetProfile).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($budgetProfileName)) {
            $budgetProfileName = 'standard-write'
        }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $budgetPolicyPath)) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        $budgetSlot = Get-ExecutionBudgetProfileBudget -Profile $budgetProfileName -PolicyPath $budgetPolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$budgetSlot.ok) {
            $code = ([string]$budgetSlot.error)
            if ([string]::IsNullOrWhiteSpace($code)) { $code = 'INVALID_BUDGET' }
            if ($code -ceq 'INVALID_PROFILE') { $code = 'INVALID_BUDGET' }
            return (New-TaskKernelError -Code $code)
        }
        $budgetRecord = $budgetSlot.budget
        $objective = ([string]$Objective).Trim()
        if ([string]::IsNullOrWhiteSpace($objective)) {
            return (New-TaskKernelError -Code 'INVALID_OBJECTIVE')
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $risk = ([string]$Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'medium' }
        if (@('low', 'medium', 'high', 'critical', 'unknown') -cnotcontains $risk) {
            return (New-TaskKernelError -Code 'INVALID_RISK')
        }
        if (([int]$RuntimeGeneration -ne 1) -and ([int]$RuntimeGeneration -ne 2)) {
            return (New-TaskKernelError -Code 'INVALID_RUNTIME')
        }
        if (-not (Test-ExecutionBudgetInt -Value $AttemptBudget -Min 1 -Max 100)) {
            return (New-TaskKernelError -Code 'INVALID_BUDGET')
        }
        $taskType = ([string]$TaskType).Trim()
        if ([string]::IsNullOrWhiteSpace($taskType)) { $taskType = 'implementation' }
        $reads = Get-TaskKernelCleanList -Value $ReadScopes
        if (-not [bool]$reads.valid) { return (New-TaskKernelError -Code 'INVALID_SCOPES') }
        $writes = Get-TaskKernelCleanList -Value $WriteScopes
        if (-not [bool]$writes.valid) { return (New-TaskKernelError -Code 'INVALID_SCOPES') }
        $grantList = Get-TaskKernelCleanList -Value $Grants
        if (-not [bool]$grantList.valid) { return (New-TaskKernelError -Code 'INVALID_GRANTS') }
        $universe = @('fs.read', 'fs.write', 'shell.validation', 'shell.diagnostic', 'git.diff', 'git.commit', 'git.branch', 'git.worktree', 'git.push', 'docs.write', 'db.migration.create', 'deploy.staging', 'deploy.production', 'secrets.reference', 'secrets.read', 'destructive.fs')
        foreach ($g in @($grantList.items)) {
            if ($universe -cnotcontains $g) { return (New-TaskKernelError -Code 'INVALID_GRANTS') }
        }
        $criteria = Get-TaskKernelCleanList -Value $AcceptanceCriteria
        if (-not [bool]$criteria.valid) { return (New-TaskKernelError -Code 'INVALID_CRITERIA') }
        $verProfiles = @()
        try {
            foreach ($vp in @($VerificationProfiles)) {
                if ($null -eq $vp) { return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES') }
                if (($vp -is [System.Collections.IEnumerable]) -and -not ($vp -is [string])) {
                    return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES')
                }
                $vt = ([string]$vp).Trim()
                if ([string]::IsNullOrWhiteSpace($vt) -or ($vt.Length -gt 128) -or ($vt -cnotmatch '^[A-Za-z0-9._-]+$')) {
                    return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES')
                }
                if (@($verProfiles) -inotcontains $vt) { $verProfiles += $vt }
                else { return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES') }
            }
            if ((@($verProfiles)).Count -gt 16) { return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES') }
        }
        catch { return (New-TaskKernelError -Code 'INVALID_VERIFICATION_PROFILES') }
        $artifacts = Get-TaskKernelCleanList -Value $ExpectedArtifacts
        if (-not [bool]$artifacts.valid) { return (New-TaskKernelError -Code 'INVALID_ARTIFACTS') }
        $envAllowed = Get-TaskKernelCleanList -Value $EnvironmentAllowed
        if (-not [bool]$envAllowed.valid) { return (New-TaskKernelError -Code 'INVALID_ENVIRONMENTS') }
        $projectCanon = Get-TaskKernelCanonicalText -Text ([string]$Project)
        $settlePolicyCanon = ([string]$SettlementPolicy).Trim()
        if ([string]::IsNullOrWhiteSpace($settlePolicyCanon)) { $settlePolicyCanon = '' }
        if (($settlePolicyCanon -cne '') -and ($settlePolicyCanon -cne 'canonical-native-settle')) {
            return (New-TaskKernelError -Code 'INVALID_SETTLEMENT_POLICY')
        }
        $scopeAll = @(@($reads.items) + @($writes.items))
        $workSlot = Get-OrchestrationWorkFingerprint -Objective $objective -Scope $scopeAll -DefinitionOfDone ([string[]]$criteria.items) -Project ([string]$Project)
        if (-not [bool]$workSlot.ok) {
            return (New-TaskKernelError -Code ([string]$workSlot.error))
        }
        $workFp = ([string]$workSlot.fingerprint)

        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'INVALID_TASK_ID')
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $dedupeLock = $null
        if (-not [string]::IsNullOrWhiteSpace($projectCanon)) {
            $dedupeAnchor = $taskFile
            try { $dedupeAnchor = Join-Path (Split-Path -Parent $taskFile) 'WORKDEDUPE' } catch { $dedupeAnchor = $taskFile }
            $dedupeLock = Enter-TaskKernelFileLock -TaskFile $dedupeAnchor
            if (-not [bool]$dedupeLock.acquired) {
                return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
            }
        }
        try {
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
            if (Test-Path -LiteralPath $taskFile -PathType Leaf) {
                return (New-TaskKernelError -Code 'ALREADY_EXISTS')
            }
            if (-not [string]::IsNullOrWhiteSpace($projectCanon)) {
                $dup = Get-OrchestrationDuplicateWork -WorkFingerprint $workFp -TasksDir $TasksDir -RepoRoot $RepoRoot -ExcludeTaskId $tid
                if ([bool]$dup.found) {
                    return (New-TaskKernelError -Code 'DUPLICATE_ACTIVE_WORK' -Extra @{ existing_task_id = ([string]$dup.existing_task_id) })
                }
            }
            $objective = Protect-TaskKernelText -Text $objective
            $criteriaItems = Protect-TaskKernelStringList -Items ([string[]]$criteria.items)
            $artifactItems = Protect-TaskKernelStringList -Items ([string[]]$artifacts.items)
            $verProfileItems = Protect-TaskKernelStringList -Items ([string[]]$verProfiles)
            $taskTypeSafe = Protect-TaskKernelText -Text $taskType
            $parentSafe = Protect-TaskKernelText -Text (([string]$ParentTaskId).Trim())
            $traceSafe = Protect-TaskKernelText -Text (([string]$TraceId).Trim())
            $projectSafe = Protect-TaskKernelText -Text (([string]$Project).Trim())
            $decisionSafe = Protect-TaskKernelText -Text (([string]$OrchestrationDecision).Trim())
            $actorSafe = Protect-TaskKernelText -Text $actor
            $runtimeIdSafe = Protect-TaskKernelText -Text (([string]$RuntimeId).Trim())
            $runtimeProfileSafe = Protect-TaskKernelText -Text (([string]$RuntimeProfile).Trim())
            $runtimeVersionSafe = Protect-TaskKernelText -Text (([string]$RuntimeVersion).Trim())
            $baseRevSafe = Protect-TaskKernelText -Text (([string]$BaseRevision).Trim())
            $readItemsSafe = Protect-TaskKernelStringList -Items ([string[]]$reads.items)
            $writeItemsSafe = Protect-TaskKernelStringList -Items ([string[]]$writes.items)
            $grantItemsSafe = Protect-TaskKernelStringList -Items ([string[]]$grantList.items)
            $envItemsSafe = Protect-TaskKernelStringList -Items ([string[]]$envAllowed.items)
            $stamp = Get-TaskKernelTimestamp
            $verifyRepoRoot = ''
            try { $verifyRepoRoot = Get-TaskKernelFullPath -Path (Get-TaskKernelRepoRoot -RepoRoot $RepoRoot) } catch { $verifyRepoRoot = '' }
        $record = [ordered]@{
            schema_version            = 1
            task_id                   = $tid
            verification_repo_root    = $verifyRepoRoot
            parent_task_id            = $parentSafe
            trace_id                  = $traceSafe
            objective                 = $objective
            task_type                 = $taskTypeSafe
            risk                      = $risk
            state                     = 'DISCOVERING'
            revision                  = 1
            orchestration_decision    = $decisionSafe
            actor                     = $actorSafe
            current_owner             = $actorSafe
            runtime                   = [ordered]@{
                id         = $runtimeIdSafe
                generation = [int]$RuntimeGeneration
                profile    = $runtimeProfileSafe
                version    = $runtimeVersionSafe
            }
            base_revision             = $baseRevSafe
            read_scopes               = ([string[]]$readItemsSafe)
            write_scopes              = ([string[]]$writeItemsSafe)
            grants                    = ([string[]]$grantItemsSafe)
            environment_authorization = [ordered]@{
                allowed_environments   = ([string[]]$envItemsSafe)
                production_authorized  = [bool]$ProductionAuthorized
            }
            acceptance_criteria       = ([string[]]$criteriaItems)
            expected_artifacts        = ([string[]]$artifactItems)
            verification_profiles     = ([string[]]$verProfileItems)
            completion_verification_contract = $(if (@($verProfileItems).Count -gt 0) { 'router-v1.4-kernel' } else { '' })
            attempt_budget            = [int]$AttemptBudget
            execution_budget          = [ordered]@{
                profile                    = ([string]$budgetRecord['profile'])
                step_budget                = [int]$budgetRecord['step_budget']
                wall_clock_seconds         = [int]$budgetRecord['wall_clock_seconds']
                no_progress_seconds        = [int]$budgetRecord['no_progress_seconds']
                repeated_action_soft_limit = [int]$budgetRecord['repeated_action_soft_limit']
                repeated_action_hard_limit = [int]$budgetRecord['repeated_action_hard_limit']
                cycle_repeat_limit         = [int]$budgetRecord['cycle_repeat_limit']
                provider_retry_limit       = [int]$budgetRecord['provider_retry_limit']
            }
            execution_budget_source   = $(if ($budgetExplicit) { 'explicit' } else { 'derived' })
            execution_runtime         = [ordered]@{
                session_id             = ''
                started_at             = ''
                deadline_at            = ''
                last_progress_at       = ''
                last_progress_revision = 0
                attempt_role           = ''
                attempt_n              = 0
                budget_snapshot        = $null
            }
            planner_turn              = [ordered]@{
                turn_id    = ''
                started_at = ''
                signal     = ''
                budget_snapshot = $null
            }
            planner_turn_history      = @()
            planner_turn_seq          = 0
            attempts                  = @()
            model_attempts            = @()
            worker_result             = $null
            verification              = $null
            verification_history      = @()
            review                    = $null
            security_review           = $null
            blockers                  = @()
            residual_risks            = @()
            closure_reason            = ''
            project                   = $projectSafe
            work_fingerprint          = $workFp
            require_typed_waits       = [bool]$RequireTypedWaits
            settlement_policy         = (Protect-TaskKernelText -Text $settlePolicyCanon)
            active_wait               = $null
            wait_history              = @()
            compliance_verdict        = ''
            worktree                  = ''
            history                   = @()
            created_at                = $stamp
            updated_at                = $stamp
        }
        $wr = Write-TaskKernelRecordCreateNew -Record $record -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $corrCreated = $null
        try { $corrCreated = New-CorrelationEnvelope -Objective ([string]$record['objective']) -DecisionRef ([string]$record['orchestration_decision']) -SettlementState 'pending' } catch { $corrCreated = $null }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId $tid -Runtime $record['runtime'] -TelemetryRoot $TelemetryRoot -Correlation $corrCreated
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = 1; state = 'DISCOVERING' }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
        }
        finally {
            if ($null -ne $dedupeLock) {
                Exit-TaskKernelFileLock -Handle $dedupeLock.handle -LockFile $dedupeLock.lockFile
            }
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$TasksDir = '',
        [string]$RepoRoot = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        return $slot.record
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

# Session bindings are canonical task-record data. Plugin-side indexes are
# disposable and must be rebuilt by reading this section.
function Get-OrchestrationTaskBindings {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$TaskId,[string]$TasksDir='',[string]$RepoRoot='')
    try {
        $task = Get-OrchestrationTask -TaskId $TaskId -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ($null -eq $task -or $task.PSObject.Properties['error']) { return $task }
        if ($task.Contains('bindings')) { return [PSCustomObject]@{ ok=$true; task_id=$TaskId; bindings=$task['bindings'] } }
        return [PSCustomObject]@{ ok=$true; task_id=$TaskId; bindings=[ordered]@{ runs=@(); active_execution_owner='' } }
    } catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Test-TaskKernelBindingId {
    [CmdletBinding()]
    param([string]$Value, [switch]$Optional)
    if ([string]::IsNullOrEmpty($Value)) { return [bool]$Optional }
    return ($Value.Length -le 128 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Invoke-OrchestrationTaskSessionBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateSet('bind','rebind','detach')][string]$Operation,
        [Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$RunId,
        [string]$SessionId='', [int]$ExpectedRevision=-1, [string]$SeatId='',
        [string]$Runtime='',[string]$Version='',[string]$ParentId='',[string]$RootId='',
        [switch]$WorkerSession,[string]$TasksDir='', [string]$FlagsPath='', [string]$RepoRoot='')
    try {
        $flags=Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not $flags.enabled) { return (New-TaskKernelError -Code 'KERNEL_DISABLED') }
        $tid=$TaskId.Trim(); $run=$RunId; $sid=$SessionId
        if (-not (Test-TaskKernelBindingId -Value ([string]$run))) { return (New-TaskKernelError -Code 'BIND_INVALID_ID') }
        foreach($idValue in @($sid,$SeatId,$ParentId,$RootId)) {
            if (-not (Test-TaskKernelBindingId -Value ([string]$idValue) -Optional)) { return (New-TaskKernelError -Code 'BIND_INVALID_ID') }
        }
        if (-not (Test-TaskKernelId $tid) -or [string]::IsNullOrEmpty($sid)) { return (New-TaskKernelError -Code 'BIND_INVALID_ID') }
        $file=Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($file)) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        $lock=Enter-TaskKernelFileLock -TaskFile $file
        if (-not $lock.acquired) { return (New-TaskKernelError -Code 'LOCK_TIMEOUT') }
        try {
            $slot=Read-TaskKernelRecord -TaskFile $file
            if (-not $slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
            if ($slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
            $rec=$slot.record
            if ($ExpectedRevision -lt 0 -or [int]$rec['revision'] -ne $ExpectedRevision) { return (New-TaskKernelError -Code 'CAS_CONFLICT') }
            $b=$rec['bindings']; if ($null -eq $b) { $b=[ordered]@{runs=@();active_execution_owner=''} }
            $runs=@($b['runs']); $idx=-1
            for($i=0;$i -lt $runs.Count;$i++){if([string]$runs[$i]['run_id'] -ceq $run){$idx=$i;break}}
            # Cross-run uniqueness. A worker session belongs to one run of this task:
            # no other run may claim it, and no other run's root may become a worker.
            # A root may continue into a later run of the same task (the Planner is
            # one session across escalation attempts), but no other run's worker may
            # become a root. Detached runs keep their sessions, hence this check.
            if ($Operation -ne 'detach') {
                foreach ($otherRun in $runs) {
                    if ([string]$otherRun['run_id'] -ceq $run) { continue }
                    $otherRoot = [string]$otherRun['root_session']
                    $otherWorkers = @(@($otherRun['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) })
                    $claimConflict = $false
                    if ($WorkerSession) { $claimConflict = (($otherRoot -ceq $sid) -or ($otherWorkers -ccontains $sid)) }
                    else { $claimConflict = ($otherWorkers -ccontains $sid) }
                    if ($claimConflict) {
                        return (New-TaskKernelError -Code 'BIND_CONFLICT' -Extra @{ existing_owner_id = [string]$otherRun['run_id']; scope = 'cross-run' })
                    }
                }
            }
            if ($Operation -eq 'rebind' -and $idx -lt 0) { return (New-TaskKernelError -Code 'REBIND_RUN_MISMATCH') }
            if ($Operation -eq 'detach') {
                if($idx -lt 0){return (New-TaskKernelError -Code 'NOT_FOUND')}
                $entry=$runs[$idx]
                $sessions=@(@($entry['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) }) + @($entry['root_session'])
                if([string]$entry['status'] -eq 'detached'){
                    $registered=@(@($entry['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) }) + @([string]$entry['root_session'])
                    if($registered -cnotcontains $sid){return (New-TaskKernelError -Code 'BIND_CONFLICT' -Extra @{existing_owner_id=[string]$entry['root_session']})}
                    return [PSCustomObject]@{ok=$true;task_id=$tid;run_id=$run;revision=[int]$rec['revision'];idempotent=$true}
                }
                if($sessions -cnotcontains $sid){return (New-TaskKernelError -Code 'NOT_FOUND')}
                $entry['status']='detached';$entry['detached_at']=Get-TaskKernelTimestamp
                if([string]$b['active_execution_owner'] -ceq $sid){$b['active_execution_owner']=''}
            } elseif ($Operation -eq 'rebind') {
                $entry=$runs[$idx]; $old=[string]$entry['root_session']
                if($old -ceq $sid -and [string]$entry['status'] -eq 'attached'){return [PSCustomObject]@{ok=$true;task_id=$tid;run_id=$run;revision=[int]$rec['revision'];idempotent=$true}}
                if([string]$entry['status'] -ne 'detached'){
                    return (New-TaskKernelError -Code 'BIND_CONFLICT' -Extra @{existing_owner_id=[string]$b['active_execution_owner']})
                }
                $entry['root_session']=$sid;$entry['status']='attached';$entry.Remove('detached_at')
                $b['active_execution_owner']=$sid
            } else {
                if($idx -lt 0){$entry=[ordered]@{run_id=$run;root_session='';worker_sessions=@();seat_id=$SeatId;status='attached';provenance=[ordered]@{runtime=(Protect-TaskKernelText $Runtime);version=(Protect-TaskKernelText $Version);parent_id=(Protect-TaskKernelText $ParentId);root_id=(Protect-TaskKernelText $RootId)};bound_at=(Get-TaskKernelTimestamp)}; $runs+=,$entry;$idx=$runs.Count-1}
                $entry=$runs[$idx]
                if($WorkerSession){$ws=@(@($entry['worker_sessions']) | Where-Object { ($_ -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$_)) });if($ws -ccontains $sid){return [PSCustomObject]@{ok=$true;task_id=$tid;run_id=$run;revision=[int]$rec['revision'];idempotent=$true}};if(-not [string]::IsNullOrWhiteSpace([string]$b['active_execution_owner']) -and [string]$b['active_execution_owner'] -cne $sid){return (New-TaskKernelError -Code 'BIND_CONFLICT' -Extra @{existing_owner_id=[string]$b['active_execution_owner']})};$entry['worker_sessions']=@($ws + $sid)}else{if([string]$entry['root_session'] -ceq $sid){return [PSCustomObject]@{ok=$true;task_id=$tid;run_id=$run;revision=[int]$rec['revision'];idempotent=$true}};if(-not [string]::IsNullOrWhiteSpace([string]$b['active_execution_owner']) -and [string]$b['active_execution_owner'] -cne $sid){return (New-TaskKernelError -Code 'BIND_CONFLICT' -Extra @{existing_owner_id=[string]$b['active_execution_owner']})};$entry['root_session']=$sid};$entry['status']='attached';$b['active_execution_owner']=$sid
            }
            $b['runs']=$runs;$rec['bindings']=$b;$rec['revision']=[int]$rec['revision']+1;$rec['updated_at']=Get-TaskKernelTimestamp
            $wr=Write-TaskKernelRecord -Record $rec -TaskFile $file
            if(-not $wr.ok){return (New-TaskKernelError -Code $wr.error)}
            return [PSCustomObject]@{ok=$true;task_id=$tid;run_id=$run;revision=[int]$rec['revision'];bindings=$b}
        } finally { Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile }
    } catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Bind-OrchestrationTaskSession { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][string]$SessionId,[Parameter(Mandatory=$true)][int]$ExpectedRevision,[string]$SeatId='',[string]$Runtime='',[string]$Version='',[string]$ParentId='',[string]$RootId='',[switch]$WorkerSession,[string]$TasksDir='',[string]$FlagsPath='',[string]$RepoRoot=''); Invoke-OrchestrationTaskSessionBinding -Operation bind -TaskId $TaskId -RunId $RunId -SessionId $SessionId -ExpectedRevision $ExpectedRevision -SeatId $SeatId -Runtime $Runtime -Version $Version -ParentId $ParentId -RootId $RootId -WorkerSession:$WorkerSession -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot }
function Rebind-OrchestrationTaskSession { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][string]$RunId,[Parameter(Mandatory=$true)][string]$SessionId,[Parameter(Mandatory=$true)][int]$ExpectedRevision,[string]$TasksDir='',[string]$FlagsPath='',[string]$RepoRoot=''); Invoke-OrchestrationTaskSessionBinding -Operation rebind -TaskId $TaskId -RunId $RunId -SessionId $SessionId -ExpectedRevision $ExpectedRevision -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot }
function Detach-OrchestrationTaskSession { [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][AllowEmptyString()][string]$RunId,[Parameter(Mandatory=$true)][string]$SessionId,[Parameter(Mandatory=$true)][int]$ExpectedRevision,[string]$TasksDir='',[string]$FlagsPath='',[string]$RepoRoot=''); Invoke-OrchestrationTaskSessionBinding -Operation detach -TaskId $TaskId -RunId $RunId -SessionId $SessionId -ExpectedRevision $ExpectedRevision -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot }

function Invoke-OrchestrationTaskTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$ToState,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$Reason = '',
        [string]$ActorIdentitySource = 'unknown',
        [string]$WaitType = '',
        [string]$WaitOwner = '',
        [string]$WaitAction = '',
        [string]$WaitDependencyId = '',
        [string]$WaitFingerprint = '',
        [string]$UnblockAction = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $to = ([string]$ToState).Trim().ToUpperInvariant()
        $map = Get-OrchestrationTaskAllowedTransitions
        if (-not $map.ContainsKey($to)) {
            return (New-TaskKernelError -Code 'UNKNOWN_STATE')
        }
        if ($to -ceq 'DONE') {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'DONE is kernel-authorized via Complete-OrchestrationTask only' })
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $from = ([string]$rec['state']).Trim().ToUpperInvariant()
        if (Test-TaskKernelTerminalState -State $from) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not $map.ContainsKey($from)) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'unknown current state' })
        }
        if ((@($map[$from]) -ccontains $to) -ne $true) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION')
        }
        if ((@('IMPLEMENTING', 'VALIDATING', 'REVIEWING') -ccontains $to) -and (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource))) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        if ((Test-TaskKernelTerminalState -State $to) -and (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec))) {
            return (New-TaskKernelError -Code 'SETTLEMENT_REQUIRED' -Extra @{ detail = 'watchdog interrupt engaged without confirmed settlement' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $waitDeclared = Test-TaskKernelWaitDeclared -Type $WaitType -Owner $WaitOwner -Action $WaitAction -DependencyId $WaitDependencyId
        $typedWait = $null
        if (($to -ceq 'BLOCKED') -and $waitDeclared) {
            $wslot = New-TaskKernelTypedWait -Type $WaitType -Owner $WaitOwner -Action $WaitAction -DependencyId $WaitDependencyId
            if (-not [bool]$wslot.ok) {
                return (New-TaskKernelError -Code ([string]$wslot.error))
            }
            $typedWait = $wslot.wait
        }
        if (($to -ceq 'BLOCKED') -and (-not $waitDeclared) -and (Test-TaskKernelRequireTypedWaits -Record $rec)) {
            return (New-TaskKernelError -Code 'WAIT_TYPED_REQUIRED' -Extra @{ detail = 'task requires typed waits; prose-only BLOCKED is rejected' })
        }
        if (($from -ceq 'BLOCKED') -and ($to -ceq 'IMPLEMENTING')) {
            $unChk = Test-TaskKernelActiveWait -Record $rec
            if ([string]$unChk.presence -ceq 'malformed') {
                return (New-TaskKernelError -Code 'MALFORMED_WAIT' -Extra @{ detail = 'active wait node is present but corrupt; unblock is blocked' })
            }
            $activeFp = ([string]$unChk.fingerprint)
            if (-not [string]::IsNullOrWhiteSpace($activeFp)) {
                $refFp = ConvertTo-TaskKernelFingerprint -Value ([string]$WaitFingerprint)
                $actRef = ([string]$UnblockAction).Trim()
                if ((([string]::IsNullOrWhiteSpace($refFp)) -or ($refFp -cne $activeFp)) -and ([string]::IsNullOrWhiteSpace($actRef))) {
                    return (New-TaskKernelError -Code 'UNBLOCK_REF_REQUIRED' -Extra @{ detail = 'unblock must reference the active wait fingerprint or a concrete action' })
                }
                $wh = @()
                if ($null -ne $rec['wait_history']) { $wh = @($rec['wait_history']) }
                $wh += $rec['active_wait']
                $rec['wait_history'] = $wh
                $rec['active_wait'] = $null
            }
        }
        $reasonClean = Protect-TaskKernelText -Text ([string]$Reason)
        $newRev = ([int]$rec['revision'] + 1)
        $hist = @()
        if ($null -ne $rec['history']) { $hist = @($rec['history']) }
        $hist += [ordered]@{
            from     = $from
            to       = $to
            actor    = $actor
            at       = (Get-TaskKernelTimestamp)
            revision = $newRev
            reason   = $reasonClean
        }
        if (($to -ceq 'BLOCKED') -and ($null -ne $typedWait)) {
            $tbl = @()
            if ($null -ne $rec['blockers']) { $tbl = @($rec['blockers']) }
            $tbl += [ordered]@{ reason = $reasonClean; actor = $actor; at = (Get-TaskKernelTimestamp); wait = $typedWait }
            $rec['blockers'] = $tbl
            $rec['active_wait'] = $typedWait
        }
        $rec['history'] = $hist
        $rec['state'] = $to
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        if (($from -ceq 'BLOCKED') -and ($to -ceq 'IMPLEMENTING')) {
            $rec['blockers'] = @()
        }
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_STATE_CHANGED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; from = $from; to = $to; revision = $newRev }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Get-TaskKernelSettlementValue {
    <#
    .SYNOPSIS
        Reads one settlement-context field without throwing.
    #>
    param($Object, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Test-TaskKernelSettlementHex32 {
    param([string]$Value = '')
    try { return (([string]$Value).Trim().ToLowerInvariant() -cmatch '^[a-f0-9]{32}$') }
    catch { return $false }
}

function Test-TaskKernelSettlementRefsEqual {
    <#
    .SYNOPSIS
        Order-insensitive ordinal comparison of two evidence ref lists.
    #>
    param($A = $null, $B = $null)
    try {
        $la = @()
        foreach ($e in @($A)) { $la += ([string]$e) }
        $lb = @()
        foreach ($e in @($B)) { $lb += ([string]$e) }
        if (@($la).Count -ne @($lb).Count) { return $false }
        $sa = (@($la | Sort-Object) -join "`n")
        $sb = (@($lb | Sort-Object) -join "`n")
        return ($sa -ceq $sb)
    }
    catch { return $false }
}

function Test-TaskKernelSettlementContext {
    <#
    .SYNOPSIS
        F1-S2: validates the canonical settlement context + live goal binding.
    .DESCRIPTION
        Fail-closed. Validates shape (all native-settle fields explicit, no
        fabricated identity: every id is carried, none derived from the
        SessionId/binding of another path), then the LIVE goal binding:
        goal ACTIVE, owner/generation/lease held, live goal revision at or
        past the observed revision, and task membership in the goal when the
        goal tracks it. Finally, for tasks carrying a settlement policy,
        the durable receipt proof
        (`Test-OrchestrationNativeDispatchSettlementProof`): the context
        must match a REAL claimed receipt with the attempt/evidence
        markers written by ND-Settle immediately before the kernel write.
        A directly fabricated context (valid 32-hex, no receipt) is
        refused here as SETTLEMENT_CONTEXT_UNVERIFIED.

        Ordering contract (goal -> task): callers invoke this BEFORE taking
        the task file lock and AGAIN under it. The goal read
        (`Get-OrchestrationGoal`) is LOCK-FREE: there is no cross-resource
        atomicity between the goal observation and the task write, and the
        task lock does not serialize goal mutation. The double
        revalidation (pre-lock + under-lock) plus the durable receipt
        proof and ND fencing only NARROW the residual window: a takeover
        after the last revalidation still settles inside it (same honest
        boundary as the ND-Settle fencing it mirrors).

        Returns @{ok, reason, detail, task_id, goal_id, owner, generation,
        goal_revision}. Never throws.
    #>
    [CmdletBinding()]
    param(
        $Context = $null,
        [string]$TaskId = '',
        [string]$Status = '',
        [string]$ProducedBy = '',
        [string[]]$ClaimedEvidence = @(),
        [long]$ExpectedRevision = 0
    )
    $refuse = {
        param([string]$Why, [string]$Detail = '')
        return [pscustomobject]@{ ok = $false; reason = $Why; detail = ([string]$Detail); task_id = ''; goal_id = ''; owner = ''; generation = [long]0; goal_revision = [long]0 }
    }
    try {
        if ($null -eq $Context) { return (& $refuse 'SETTLEMENT_CONTEXT_MISSING' 'no settlement context supplied') }
        $tid = ([string](Get-TaskKernelSettlementValue $Context 'task_id')).Trim()
        $gid = ([string](Get-TaskKernelSettlementValue $Context 'goal_id')).Trim()
        $own = ([string](Get-TaskKernelSettlementValue $Context 'owner')).Trim()
        $gsdir = ([string](Get-TaskKernelSettlementValue $Context 'goal_store_dir')).Trim()
        $rroot = ([string](Get-TaskKernelSettlementValue $Context 'receipt_root')).Trim()
        $evdir = ([string](Get-TaskKernelSettlementValue $Context 'evidence_store_dir')).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'task_id') }
        if ([string]::IsNullOrWhiteSpace($gid)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'goal_id') }
        if ([string]::IsNullOrWhiteSpace($own)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'owner') }
        if ([string]::IsNullOrWhiteSpace($gsdir)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'goal_store_dir') }
        if ([string]::IsNullOrWhiteSpace($rroot)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'receipt_root') }
        if ([string]::IsNullOrWhiteSpace($evdir)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'evidence_store_dir') }
        $gen = [long]-1
        try { $gen = [long](Get-TaskKernelSettlementValue $Context 'generation') } catch { $gen = [long]-1 }
        if ($gen -lt 1) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'generation') }
        $grev = [long]-1
        try { $grev = [long](Get-TaskKernelSettlementValue $Context 'goal_revision') } catch { $grev = [long]-1 }
        if ($grev -lt 1) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'goal_revision') }
        $key = ([string](Get-TaskKernelSettlementValue $Context 'idempotency_key')).Trim().ToLowerInvariant()
        if (-not (Test-TaskKernelSettlementHex32 $key)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'idempotency_key') }
        $fp = ([string](Get-TaskKernelSettlementValue $Context 'prepared_fingerprint')).Trim().ToLowerInvariant()
        if (-not (Test-TaskKernelSettlementHex32 $fp)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'prepared_fingerprint') }
        $parent = ([string](Get-TaskKernelSettlementValue $Context 'parent_session_id')).Trim()
        $msg = ([string](Get-TaskKernelSettlementValue $Context 'message_id')).Trim()
        $call = ([string](Get-TaskKernelSettlementValue $Context 'call_id')).Trim()
        $caller = ([string](Get-TaskKernelSettlementValue $Context 'caller_agent')).Trim()
        $target = ([string](Get-TaskKernelSettlementValue $Context 'target_agent')).Trim()
        $child = ([string](Get-TaskKernelSettlementValue $Context 'child_session_id')).Trim()
        if ([string]::IsNullOrWhiteSpace($parent)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'parent_session_id') }
        if ([string]::IsNullOrWhiteSpace($msg)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'message_id') }
        if ([string]::IsNullOrWhiteSpace($call)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'call_id') }
        if ([string]::IsNullOrWhiteSpace($caller)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'caller_agent') }
        if ([string]::IsNullOrWhiteSpace($target)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'target_agent') }
        if ([string]::IsNullOrWhiteSpace($child)) { return (& $refuse 'SETTLEMENT_CONTEXT_INCOMPLETE' 'child_session_id') }
        if ($child -ceq $parent) { return (& $refuse 'SETTLEMENT_CONTEXT_DIVERGENT' 'child_session_id') }
        if ($caller -ceq $target) { return (& $refuse 'SETTLEMENT_CONTEXT_DIVERGENT' 'caller_agent') }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            return (& $refuse 'SETTLEMENT_GOAL_UNAVAILABLE' 'goal kernel unavailable')
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $gsdir }
        catch { $slot = $null }
        $slotOk = $false
        try { $slotOk = [bool](Get-TaskKernelSettlementValue $slot 'ok') } catch { $slotOk = $false }
        if (($null -eq $slot) -or (-not $slotOk)) {
            $why = 'goal-read-failed'
            try {
                $r = ([string](Get-TaskKernelSettlementValue $slot 'reason')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            return (& $refuse 'SETTLEMENT_GOAL_READ_FAILED' $why)
        }
        $live = Get-TaskKernelSettlementValue $slot 'goal'
        if ($null -eq $live) { return (& $refuse 'SETTLEMENT_GOAL_READ_FAILED' 'goal-record-missing') }
        $gstate = ''
        try { $gstate = (([string](Get-TaskKernelSettlementValue $live 'state')).Trim().ToUpperInvariant()) } catch { $gstate = '' }
        if ($gstate -cne 'ACTIVE') { return (& $refuse 'SETTLEMENT_GOAL_NOT_ACTIVE' $gstate) }
        $held = $false
        try {
            $ownSlot = Test-OrchestrationGoalOwnership -Goal $live -OwnerId $own -Generation $gen
            $held = [bool](Get-TaskKernelSettlementValue $ownSlot 'held')
        }
        catch { $held = $false }
        if (-not $held) { return (& $refuse 'SETTLEMENT_OWNERSHIP_NOT_HELD' '') }
        $liveRev = [long]-1
        try { $liveRev = [long](Get-TaskKernelSettlementValue $live 'revision') } catch { $liveRev = [long]-1 }
        if ($liveRev -lt 1) { return (& $refuse 'SETTLEMENT_GOAL_REVISION_UNKNOWN' '') }
        if ($liveRev -lt $grev) { return (& $refuse 'SETTLEMENT_GOAL_REVISION_MISMATCH' ('live=' + [string]$liveRev + ' observed=' + [string]$grev)) }
        $activeList = $null
        $hasActive = $false
        try {
            if ($live -is [System.Collections.IDictionary]) {
                if ($live.Contains('active_tasks')) { $hasActive = $true; $activeList = @($live['active_tasks']) }
            }
            else {
                $pp = $live.PSObject.Properties['active_tasks']
                if ($null -ne $pp) { $hasActive = $true; $activeList = @($pp.Value) }
            }
        }
        catch { $hasActive = $false; $activeList = $null }
        if ($hasActive) {
            $member = $false
            try { foreach ($t in @($activeList)) { if ($tid -ceq ([string]$t)) { $member = $true; break } } } catch { $member = $false }
            if (-not $member) { return (& $refuse 'SETTLEMENT_TASK_NOT_IN_GOAL' '') }
        }
        # F1-S2-FIX1: prova do recibo duravel. O contexto sozinho (mesmo
        # com 32-hex validos e goal vivo) nao autoriza escrita: tem de
        # corresponder a um claim REAL com os marcadores de tentativa e
        # evidencia que o ND-Settle persiste antes do kernel.
        $proofCmd = Get-Command Test-OrchestrationNativeDispatchSettlementProof -ErrorAction SilentlyContinue
        if ($null -eq $proofCmd) { return (& $refuse 'SETTLEMENT_PROOF_UNAVAILABLE' 'native dispatch proof unavailable') }
        $proof = $null
        try { $proof = Test-OrchestrationNativeDispatchSettlementProof -SettlementContext $Context -TaskId $TaskId -Status $Status -ProducedBy $ProducedBy -ClaimedEvidence $ClaimedEvidence -ExpectedRevision $ExpectedRevision }
        catch { $proof = $null }
        if (($null -eq $proof) -or (-not [bool](Get-TaskKernelSettlementValue $proof 'ok'))) {
            $why = 'proof-refused'
            try {
                $pr = ([string](Get-TaskKernelSettlementValue $proof 'reason')).Trim()
                if (-not [string]::IsNullOrWhiteSpace($pr)) { $why = $pr }
            }
            catch { }
            return (& $refuse 'SETTLEMENT_CONTEXT_UNVERIFIED' $why)
        }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; task_id = $tid; goal_id = $gid; owner = $own; generation = $gen; goal_revision = $liveRev }
    }
    catch { return (& $refuse 'SETTLEMENT_CONTEXT_INVALID' 'internal-error') }
}

function Set-OrchestrationTaskWorkerResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Status,
        [string[]]$ClaimedEvidence = @(),
        [Parameter(Mandatory = $true)][string]$ProducedBy,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$Hypothesis = '',
        [switch]$NewEvidence,
        [switch]$DebuggerInvoked,
        [string]$StrategyId = '',
        [string]$StrategyApproach = '',
        [string]$StrategyTool = '',
        [string[]]$StrategyParams = @(),
        [string]$StrategyFingerprint = '',
        [string]$FailureClass = '',
        [string]$FailureDetail = '',
        [string]$RecoverySource = '',
        [string[]]$NewEvidenceRefs = @(),
        [string]$ProposedBudgetJson = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = '',
        $SettlementContext = $null
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        # F1-S2 (goal -> task order): when a canonical settlement context is
        # presented for a task that CARRIES a settlement policy, the live
        # goal binding is validated BEFORE taking the task file lock, then
        # revalidated under it. The goal read is lock-free (no internal
        # goal-store lock is held); the double revalidation plus the
        # durable receipt proof only narrow the residual window, without
        # cross-resource atomicity. The
        # pre-lock peek is advisory only (the record field is immutable;
        # the under-lock gate stays authoritative): legacy tasks (no
        # settlement_policy) skip this entirely and keep the historical
        # path byte-for-byte, even with a stray context presented.
        if ($null -ne $SettlementContext) {
            $peekPolicy = ''
            try {
                $peekTid = ([string]$TaskId).Trim()
                $peekFile = Get-TaskKernelFilePath -TaskId $peekTid -TasksDir $TasksDir -RepoRoot $RepoRoot
                if (-not [string]::IsNullOrWhiteSpace($peekFile)) {
                    $peekSlot = Read-TaskKernelRecord -TaskFile $peekFile
                    if (([bool]$peekSlot.found) -and (-not [bool]$peekSlot.malformed) -and ($null -ne $peekSlot.record)) {
                        $peekRec = $peekSlot.record
                        if ($peekRec -is [System.Collections.IDictionary]) {
                            if ($peekRec.Contains('settlement_policy')) { $peekPolicy = ([string]$peekRec['settlement_policy']).Trim() }
                        }
                        else {
                            $peekProp = $peekRec.PSObject.Properties['settlement_policy']
                            if ($null -ne $peekProp) { $peekPolicy = ([string]$peekProp.Value).Trim() }
                        }
                    }
                }
            }
            catch { $peekPolicy = '' }
            if (-not [string]::IsNullOrWhiteSpace($peekPolicy)) {
                $preCtx = Test-TaskKernelSettlementContext -Context $SettlementContext -TaskId $peekTid -Status $Status -ProducedBy $ProducedBy -ClaimedEvidence $ClaimedEvidence -ExpectedRevision ([long]$ExpectedRevision)
                if (-not [bool]$preCtx.ok) {
                    return (New-TaskKernelError -Code ([string]$preCtx.reason) -Extra @{ detail = ([string]$preCtx.detail) })
                }
            }
        }
        $status = ([string]$Status).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $status) {
            return (New-TaskKernelError -Code 'STATUS_NOT_ALLOWED_FROM_WORKER')
        }
        $producer = ([string]$ProducedBy).Trim()
        if ([string]::IsNullOrWhiteSpace($producer)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ProposedBudgetJson)) {
            return (New-TaskKernelError -Code 'BUDGET_IMMUTABLE' -Extra @{ detail = 'workers cannot widen execution budgets' })
        }
        $ev = Get-TaskKernelEvidenceList -Value $ClaimedEvidence
        if (-not [bool]$ev.valid) { return (New-TaskKernelError -Code 'INVALID_EVIDENCE') }
        $p27Strat = Resolve-TaskKernelStrategyFingerprint -Explicit $StrategyFingerprint -Approach $StrategyApproach -ToolOrPath $StrategyTool -KeyParams $StrategyParams
        if (-not [bool]$p27Strat.ok) {
            return (New-TaskKernelError -Code ([string]$p27Strat.error))
        }
        $p27Fp = ([string]$p27Strat.fingerprint)
        $p27Class = 'unknown'
        if (-not [string]::IsNullOrWhiteSpace(([string]$FailureClass).Trim())) {
            $cc = ([string]$FailureClass).Trim().ToLowerInvariant()
            if ((@(Get-OrchestrationFailureClasses) -cnotcontains $cc)) {
                return (New-TaskKernelError -Code 'INVALID_FAILURE_CLASS')
            }
            $p27Class = $cc
        }
        $p27Source = ([string]$RecoverySource).Trim().ToLowerInvariant()
        if ((-not [string]::IsNullOrWhiteSpace($p27Source)) -and ((@(Get-OrchestrationRecoverySources) -cnotcontains $p27Source))) {
            return (New-TaskKernelError -Code 'INVALID_RECOVERY_SOURCE')
        }
        $p27Refs = @()
        $refCount = 0
        foreach ($e in @($NewEvidenceRefs)) { if ($null -ne $e) { $refCount++ } }
        if ($refCount -gt 0) {
            $rl = Get-TaskKernelEvidenceList -Value $NewEvidenceRefs
            if (-not [bool]$rl.valid) { return (New-TaskKernelError -Code 'INVALID_EVIDENCE') }
            $p27Refs = Protect-TaskKernelStringList -Items ([string[]]$rl.items)
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $from = ([string]$rec['state']).Trim().ToUpperInvariant()
        if (Test-TaskKernelTerminalState -State $from) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        # F1-S2: durable settlement policy. Tasks created without a policy
        # (including every task created before this slice) keep the legacy
        # contract: a presented context is ignored. Tasks marked
        # 'canonical-native-settle' settle ONLY through the canonical owner
        # (ND-Settle), which forwards the correlated native context; a
        # missing, incomplete or divergent context, a goal that is not
        # ACTIVE/held/bound, or a context without a matching durable
        # claimed receipt (durable proof), is refused here with a stable
        # reason and ZERO writes. Unknown policy values fail closed
        # (never migrated).
        $settlePolicy = ''
        try {
            if ($rec -is [System.Collections.IDictionary]) {
                if ($rec.Contains('settlement_policy')) { $settlePolicy = ([string]$rec['settlement_policy']).Trim() }
            }
            else {
                $spp = $rec.PSObject.Properties['settlement_policy']
                if ($null -ne $spp) { $settlePolicy = ([string]$spp.Value).Trim() }
            }
        }
        catch { $settlePolicy = '' }
        if (-not [string]::IsNullOrWhiteSpace($settlePolicy)) {
            if ($settlePolicy -cne 'canonical-native-settle') {
                return (New-TaskKernelError -Code 'SETTLEMENT_POLICY_UNKNOWN' -Extra @{ detail = 'refusing rather than migrating' })
            }
            if ($null -eq $SettlementContext) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_MISSING' -Extra @{ detail = 'canonical settle requires a correlated native context' })
            }
            $ctxGate = Test-TaskKernelSettlementContext -Context $SettlementContext -TaskId $tid -Status $status -ProducedBy $producer -ClaimedEvidence @($ev.items) -ExpectedRevision ([long]$ExpectedRevision)
            if (-not [bool]$ctxGate.ok) {
                return (New-TaskKernelError -Code ([string]$ctxGate.reason) -Extra @{ detail = ([string]$ctxGate.detail) })
            }
            if ([string]$ctxGate.task_id -cne $tid) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_DIVERGENT' -Extra @{ detail = 'task_id' })
            }
            $ctxStatus = ([string](Get-TaskKernelSettlementValue $SettlementContext 'status')).Trim().ToLowerInvariant()
            if ($ctxStatus -cne $status) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_DIVERGENT' -Extra @{ detail = 'status' })
            }
            $ctxProd = ([string](Get-TaskKernelSettlementValue $SettlementContext 'produced_by')).Trim()
            if (([string]::IsNullOrWhiteSpace($ctxProd)) -or ($ctxProd -cne $producer)) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_DIVERGENT' -Extra @{ detail = 'produced_by' })
            }
            $ctxTarget = ([string](Get-TaskKernelSettlementValue $SettlementContext 'target_agent')).Trim()
            if (([string]::IsNullOrWhiteSpace($ctxTarget)) -or ($ctxTarget -cne $producer)) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_DIVERGENT' -Extra @{ detail = 'target_agent' })
            }
            $ctxRefsRaw = Get-TaskKernelSettlementValue $SettlementContext 'claimed_evidence'
            if ($null -eq $ctxRefsRaw) { $ctxRefsRaw = Get-TaskKernelSettlementValue $SettlementContext 'evidence' }
            if (-not (Test-TaskKernelSettlementRefsEqual -A @($ctxRefsRaw) -B @($ev.items))) {
                return (New-TaskKernelError -Code 'SETTLEMENT_CONTEXT_DIVERGENT' -Extra @{ detail = 'claimed_evidence' })
            }
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $boundFp = ''
        $boundId = ''
        $boundHyp = ''
        $geDbgPresent = $false
        $geEvRefs = @()
        try {
            $rt = $rec['execution_runtime']
            if (($null -ne $rt) -and ($rt -is [System.Collections.IDictionary]) -and ($null -ne $rt['gate_evidence'])) {
                $ge = $rt['gate_evidence']
                if (($null -ne $ge) -and ($ge -is [System.Collections.IDictionary]) -and $ge.Contains('strategy_fingerprint')) {
                    $boundFp = ConvertTo-TaskKernelFingerprint -Value ([string]$ge['strategy_fingerprint'])
                    if ($ge.Contains('strategy_id') -and ($null -ne $ge['strategy_id'])) { $boundId = ([string]$ge['strategy_id']).Trim() }
                    if ($ge.Contains('hypothesis') -and ($null -ne $ge['hypothesis'])) { $boundHyp = ([string]$ge['hypothesis']) }
                    try {
                        if ($ge.Contains('debugger_refs')) {
                            foreach ($e in @($ge['debugger_refs'])) {
                                if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) { $geDbgPresent = $true }
                            }
                        }
                    }
                    catch { }
                    try {
                        if ($ge.Contains('new_evidence_refs')) {
                            foreach ($e in @($ge['new_evidence_refs'])) {
                                if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) { $geEvRefs += ([string]$e) }
                            }
                        }
                    }
                    catch { }
                }
            }
        }
        catch {
            $boundFp = ''
            $boundId = ''
            $boundHyp = ''
            $geDbgPresent = $false
            $geEvRefs = @()
        }
        if ((-not [string]::IsNullOrWhiteSpace($boundFp)) -and (-not [string]::IsNullOrWhiteSpace($p27Fp)) -and ($p27Fp -cne $boundFp)) {
            return (New-TaskKernelError -Code 'STRATEGY_MISMATCH' -Extra @{ detail = 'worker strategy does not match the attempt-bound strategy' })
        }
        $rtN = 0
        try {
            $rt = $rec['execution_runtime']
            if (($null -ne $rt) -and ($rt -is [System.Collections.IDictionary]) -and ($null -ne $rt['attempt_n'])) { $rtN = [int]$rt['attempt_n'] }
        }
        catch { $rtN = 0 }
        $attCount = 0
        try { if ($null -ne $rec['attempts']) { $attCount = (@($rec['attempts'])).Count } } catch { $attCount = 0 }
        $p27Auth = ((-not [string]::IsNullOrWhiteSpace($boundFp)) -and ($rtN -gt 0) -and ($rtN -eq ($attCount + 1)))
        $p27AuthNovel = $false
        if ($p27Auth) {
            $lastFpA = ''
            $lastHypA = ''
            try {
                if ($attCount -gt 0) {
                    $la = (@($rec['attempts']))[$attCount - 1]
                    $lastFpA = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $la -Name 'strategy_fingerprint'))
                    $lhA = Get-TaskKernelAttemptField -Attempt $la -Name 'hypothesis'
                    if ($null -ne $lhA) { $lastHypA = ([string]$lhA) }
                }
            }
            catch { }
            if ((@($geEvRefs)).Count -gt 0) { $p27AuthNovel = $true }
            if (($boundFp -cne $lastFpA)) { $p27AuthNovel = $true }
            if ((-not [string]::IsNullOrWhiteSpace($boundHyp)) -and ((Get-TaskKernelCanonicalText -Text $boundHyp) -cne (Get-TaskKernelCanonicalText -Text $lastHypA))) { $p27AuthNovel = $true }
        }
        $effDbgInvoked = ([bool]$DebuggerInvoked -or ([bool]$p27Auth -and [bool]$geDbgPresent))
        $effNewEv = ([bool]$NewEvidence -or ([bool]$p27Auth -and [bool]$p27AuthNovel))
        $priorAttempts = @()
        if ($null -ne $rec['attempts']) { $priorAttempts = @($rec['attempts']) }
        if ($priorAttempts.Count -gt 0) {
            $last = $priorAttempts[$priorAttempts.Count - 1]
            $needDbg = $false
            $needEv = $false
            try {
                if ($last -is [System.Collections.IDictionary]) {
                    if ($null -ne $last['debugger_required']) { $needDbg = [bool]$last['debugger_required'] }
                    if ($null -ne $last['requires_new_evidence']) { $needEv = [bool]$last['requires_new_evidence'] }
                }
                else {
                    if ($null -ne $last.debugger_required) { $needDbg = [bool]$last.debugger_required }
                    if ($null -ne $last.requires_new_evidence) { $needEv = [bool]$last.requires_new_evidence }
                }
            }
            catch { }
            if ($needDbg -and (-not $effDbgInvoked)) {
                return (New-TaskKernelError -Code 'ATTEMPT_GATE_FAILED' -Extra @{ reason = 'debugger_required' })
            }
            if ($needEv -and (-not $effNewEv)) {
                return (New-TaskKernelError -Code 'ATTEMPT_GATE_FAILED' -Extra @{ reason = 'new_evidence_required' })
            }
        }
        $effStrategyId = ([string]$StrategyId).Trim()
        $workerHypRaw = ([string]$Hypothesis)
        $effHypothesis = $workerHypRaw
        $workerHypDivergent = ''
        if ((-not [string]::IsNullOrWhiteSpace($boundFp)) -and [string]::IsNullOrWhiteSpace($p27Fp)) {
            $p27Fp = $boundFp
            $effStrategyId = $boundId
        }
        if ((-not [string]::IsNullOrWhiteSpace($boundFp)) -and (-not [string]::IsNullOrWhiteSpace($p27Fp)) -and ($p27Fp -ceq $boundFp) -and (-not [string]::IsNullOrWhiteSpace($boundHyp))) {
            $wTrim = ([string]$workerHypRaw).Trim()
            if ([string]::IsNullOrWhiteSpace($wTrim)) {
                $effHypothesis = $boundHyp
            }
            elseif ((Get-TaskKernelCanonicalText -Text $wTrim) -cne (Get-TaskKernelCanonicalText -Text $boundHyp)) {
                $workerHypDivergent = (Protect-TaskKernelText -Text $workerHypRaw)
                $effHypothesis = $boundHyp
            }
            else {
                $effHypothesis = $boundHyp
            }
        }
        $claimedItems = Protect-TaskKernelStringList -Items ([string[]]$ev.items)
        $hypClean = Protect-TaskKernelText -Text $effHypothesis
        $newRev = ([int]$rec['revision'] + 1)
        $stamp = Get-TaskKernelTimestamp
        $rec['worker_result'] = [ordered]@{
            status           = $status
            claimed_evidence = ([string[]]$claimedItems)
            produced_by      = $producer
            at               = $stamp
            revision         = $newRev
        }
        $attempts = @()
        if ($null -ne $rec['attempts']) { $attempts = @($rec['attempts']) }
        $exhausted = $false
        if ($status -ceq 'failed') {
            $n = ($attempts.Count + 1)
            $budget = 3
            try { $budget = [int]$rec['attempt_budget'] } catch { $budget = 3 }
            if ($budget -lt 1) { $budget = 3 }
            $prevFp = ''
            if ($attempts.Count -gt 0) {
                $prevFp = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $attempts[$attempts.Count - 1] -Name 'strategy_fingerprint'))
            }
            $p27Changed = $false
            if ((-not [string]::IsNullOrWhiteSpace($p27Fp)) -and (-not [string]::IsNullOrWhiteSpace($prevFp)) -and ($p27Fp -cne $prevFp)) {
                $p27Changed = $true
            }
            $p27Scope = @()
            try { $p27Scope = @(@($rec['read_scopes']) + @($rec['write_scopes'])) } catch { $p27Scope = @() }
            $p27RecFp = ''
            $p27RecSlot = Get-OrchestrationRecoveryFingerprint -FailureClass $p27Class -StrategyFingerprint $p27Fp -Scope $p27Scope
            if ([bool]$p27RecSlot.ok) { $p27RecFp = ([string]$p27RecSlot.fingerprint) }
            $attempts += [ordered]@{
                n                      = $n
                status                 = 'failed'
                hypothesis             = $hypClean
                worker_hypothesis      = $workerHypDivergent
                debugger_invoked       = [bool]$effDbgInvoked
                debugger_required      = ($n -ge 2)
                new_evidence           = [bool]$effNewEv
                requires_new_evidence  = ($n -ge 2)
                strategy_id            = (Protect-TaskKernelText -Text $effStrategyId)
                strategy_fingerprint   = $p27Fp
                failure_class          = $p27Class
                failure_detail         = (Protect-TaskKernelText -Text ([string]$FailureDetail))
                recovery_source        = $p27Source
                new_evidence_refs      = ([string[]]$p27Refs)
                recovery_fingerprint   = $p27RecFp
                changed_from_previous  = [bool]$p27Changed
                at                     = $stamp
            }
            $rec['attempts'] = $attempts
            if (($n -ge $budget) -and (-not $effNewEv)) {
                if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
                    return (New-TaskKernelError -Code 'SETTLEMENT_REQUIRED' -Extra @{ detail = 'watchdog interrupt engaged without confirmed settlement' })
                }
                $hist = @()
                if ($null -ne $rec['history']) { $hist = @($rec['history']) }
                $hist += [ordered]@{
                    from     = $from
                    to       = 'EXHAUSTED'
                    actor    = 'task-kernel'
                    at       = $stamp
                    revision = $newRev
                }
                $rec['history'] = $hist
                $rec['state'] = 'EXHAUSTED'
                $exhausted = $true
            }
        }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'CANDIDATE_RESULT_RECORDED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        if ($exhausted) {
            $null = Send-TaskKernelTelemetry -EventType 'TASK_EXHAUSTED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; worker_status = $status; attempts = $attempts.Count; exhausted = $exhausted }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Get-TaskKernelSanitizedVerifierProfiles {
    <#
    .SYNOPSIS
        Sanitizes verifier profile results for persistence: keeps only
        profile/status/exit_code per entry (drops commands, outputs and
        any other free text), caps 32 entries. Never throws.
    #>
    [CmdletBinding()]
    param($Profiles = @())
    $profClean = @()
    try {
        foreach ($pr in @($Profiles)) {
            if (@($profClean).Count -ge 32) { break }
            if ($null -eq $pr) { continue }
            $pn = ''
            $pst = ''
            $pec = 0
            try {
                if ($pr -is [System.Collections.IDictionary]) {
                    if ($null -ne $pr['profile']) { $pn = ([string]$pr['profile']).Trim() }
                    if ($null -ne $pr['status']) { $pst = ([string]$pr['status']).Trim() }
                    if ($null -ne $pr['exit_code']) { $pec = [int]$pr['exit_code'] }
                }
                else {
                    $qpn = $pr.PSObject.Properties | Where-Object { $_.Name -ceq 'profile' } | Select-Object -First 1
                    if ($null -ne $qpn) { $pn = ([string]$qpn.Value).Trim() }
                    $qps = $pr.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                    if ($null -ne $qps) { $pst = ([string]$qps.Value).Trim() }
                    $qpe = $pr.PSObject.Properties | Where-Object { $_.Name -ceq 'exit_code' } | Select-Object -First 1
                    if ($null -ne $qpe) { $pec = [int]$qpe.Value }
                }
            }
            catch { continue }
            if ([string]::IsNullOrWhiteSpace($pn) -or ([string]$pn).Length -gt 128) { continue }
            if ([string]::IsNullOrWhiteSpace($pst) -or ([string]$pst).Length -gt 64) { continue }
            $profClean += [ordered]@{ profile = $pn; status = $pst; exit_code = $pec }
        }
    }
    catch { $profClean = @() }
    return $profClean
}

function Get-TaskKernelSanitizedCriterionMap {
    <#
    .SYNOPSIS
        Sanitizes a verifier criterion map for persistence: keeps only
        numeric-index keys with word statuses, caps 64 entries.
        Never throws.
    #>
    [CmdletBinding()]
    param($MapRaw = $null)
    $mapClean = [ordered]@{}
    try {
        $mapPairs = @()
        if ($null -ne $MapRaw) {
            if ($MapRaw -is [System.Collections.IDictionary]) {
                foreach ($k in @($MapRaw.Keys)) { $mapPairs += ,@([string]$k, $MapRaw[$k]) }
            }
            else {
                foreach ($pp2 in @($MapRaw.PSObject.Properties)) { $mapPairs += ,@([string]$pp2.Name, $pp2.Value) }
            }
        }
        foreach ($pair in $mapPairs) {
            if (@($mapClean.Keys).Count -ge 64) { break }
            try {
                $mk = ([string]$pair[0]).Trim()
                if ($mk -cnotmatch '^[0-9]+$') { continue }
                $mv = $pair[1]
                $ms = ''
                if ($mv -is [System.Collections.IDictionary]) {
                    if ($null -ne $mv['status']) { $ms = ([string]$mv['status']).Trim() }
                }
                elseif ($mv -is [string]) { $ms = ([string]$mv).Trim() }
                else {
                    $qms = $mv.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                    if ($null -ne $qms) { $ms = ([string]$qms.Value).Trim() }
                }
                if ([string]::IsNullOrWhiteSpace($ms) -or ($ms.Length -gt 64)) { continue }
                if (-not $mapClean.Contains($mk)) { $mapClean[$mk] = $ms }
            }
            catch { }
        }
    }
    catch { $mapClean = [ordered]@{} }
    return $mapClean
}

function Set-OrchestrationTaskVerification {
    <#
    .SYNOPSIS
        Records caller-supplied verifier output (UNTRUSTED).
        -VerifierEvidenceJson (a claimed Invoke-OrchestrationVerifier
        result or its JSON string) is REQUIRED; Passed derives from its
        status field and only 'verified_pass' counts as passed. A legacy
        -Passed value that disagrees with the derived value fails closed
        (VERIFIER_RESULT_MISMATCH). The exact normalized verifier status
        string is persisted alongside passed/evidence/digest (missing on
        legacy records means unknown). Caller input is NEVER trusted for
        escalation: this path always persists
        verification_source='caller-supplied' and verifier_executed=false
        (plus source='caller-supplied'); only the kernel-executed
        verify-run path may persist kernel-executed marks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)]$VerifierEvidenceJson,
        [bool]$Passed = $false,
        [string[]]$Evidence = @(),
        [string[]]$CommandClasses = @(),
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $vnode = $null
        try {
            if ($VerifierEvidenceJson -is [string]) {
                $raw = ([string]$VerifierEvidenceJson).Trim()
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    return (New-TaskKernelError -Code 'INVALID_VERIFIER_RESULT')
                }
                $vnode = ($raw | ConvertFrom-Json)
            }
            else {
                $vnode = $VerifierEvidenceJson
            }
        }
        catch { return (New-TaskKernelError -Code 'INVALID_VERIFIER_RESULT') }
        if ($null -eq $vnode) { return (New-TaskKernelError -Code 'INVALID_VERIFIER_RESULT') }
        $vstatus = ''
        $vidence = @()
        $vclasses = @()
        $vok = $false
        $vprofiles = @()
        $vmapRaw = $null
        try {
            if ($vnode -is [System.Collections.IDictionary]) {
                if ($null -ne $vnode['status']) { $vstatus = ([string]$vnode['status']).Trim() }
                if ($null -ne $vnode['evidence']) { $vidence = @($vnode['evidence']) }
                if ($null -ne $vnode['command_classes']) { $vclasses = @($vnode['command_classes']) }
                if ($null -ne $vnode['ok']) { $vok = [bool]$vnode['ok'] }
                if ($null -ne $vnode['profiles']) { $vprofiles = @($vnode['profiles']) }
                if ($vnode.Contains('criterion_map')) { $vmapRaw = $vnode['criterion_map'] }
            }
            else {
                $ps = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                if ($null -ne $ps) { $vstatus = ([string]$ps.Value).Trim() }
                $pe = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'evidence' } | Select-Object -First 1
                if ($null -ne $pe) { $vidence = @($pe.Value) }
                $pc = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'command_classes' } | Select-Object -First 1
                if ($null -ne $pc) { $vclasses = @($pc.Value) }
                $po = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'ok' } | Select-Object -First 1
                if ($null -ne $po) { $vok = [bool]$po.Value }
                $pp = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'profiles' } | Select-Object -First 1
                if ($null -ne $pp) { $vprofiles = @($pp.Value) }
                $pm = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'criterion_map' } | Select-Object -First 1
                if ($null -ne $pm) { $vmapRaw = $pm.Value }
            }
        }
        catch { return (New-TaskKernelError -Code 'INVALID_VERIFIER_RESULT') }
        if ([string]::IsNullOrWhiteSpace($vstatus)) {
            return (New-TaskKernelError -Code 'INVALID_VERIFIER_RESULT')
        }
        $derived = ($vstatus -ceq 'verified_pass')
        if ($PSBoundParameters.ContainsKey('Passed') -and ([bool]$Passed -ne $derived)) {
            return (New-TaskKernelError -Code 'VERIFIER_RESULT_MISMATCH')
        }
        $ev = Get-TaskKernelEvidenceList -Value $vidence
        if (-not [bool]$ev.valid) { return (New-TaskKernelError -Code 'INVALID_EVIDENCE') }
        $cmd = Get-TaskKernelCleanList -Value $vclasses
        if (-not [bool]$cmd.valid) { return (New-TaskKernelError -Code 'INVALID_EVIDENCE') }
        $digest = ''
        try {
            if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -ne $null) {
                $digest = Get-LogicalHash -InputObject $vnode
            }
        }
        catch { $digest = '' }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $candRev = [int]$rec['revision']
        try {
            $wrk = $rec['worker_result']
            if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary]) -and ($null -ne $wrk['revision'])) {
                $candRev = [int]$wrk['revision']
            }
        }
        catch { }
        $evClean = Protect-TaskKernelStringList -Items ([string[]]$ev.items)
        $profClean = @(Get-TaskKernelSanitizedVerifierProfiles -Profiles @($vprofiles))
        $mapClean = Get-TaskKernelSanitizedCriterionMap -MapRaw $vmapRaw
        $newRev = ([int]$rec['revision'] + 1)
        $rec['verification'] = [ordered]@{
            passed              = $derived
            status              = $vstatus
            verifier_ok         = $false
            verification_source = 'caller-supplied'
            verifier_executed   = $false
            evidence            = ([string[]]$evClean)
            command_classes     = ([string[]]$cmd.items)
            profiles            = $profClean
            criterion_map       = $mapClean
            source              = 'caller-supplied'
            result_digest       = $digest
            candidate_revision  = $candRev
            at                  = (Get-TaskKernelTimestamp)
            revision            = $newRev
        }
        $vhist = @()
        try { if ($null -ne $rec['verification_history']) { $vhist = @($rec['verification_history']) } } catch { $vhist = @() }
        $vhist += [ordered]@{
            status              = $vstatus
            passed              = $derived
            verification_source = 'caller-supplied'
            verifier_executed   = $false
            candidate_revision  = $candRev
            revision            = $newRev
            result_digest       = $digest
            at                  = (Get-TaskKernelTimestamp)
        }
        while (@($vhist).Count -gt 64) { $vhist = @($vhist | Select-Object -Skip 1) }
        $rec['verification_history'] = $vhist
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; passed = $derived; status = $vstatus }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Invoke-TaskKernelVerifyRun {
    <#
    .SYNOPSIS
        Kernel-executed verification (TRUSTED path for escalation).
    .DESCRIPTION
        Reads task_id/base_revision/write_scopes/acceptance_criteria and
        the immutable verification_profiles plan committed at task
        creation from the canonical task record (read snapshot), validates
        every planned profile against the canonical verification-policy
        allowlist, executes Invoke-OrchestrationVerifier in-process with
        the task's real scopes/base/criteria IN THE TASK'S OWN BOUND ROOT
        (verification_repo_root persisted at creation; a nonempty caller
        -RepoRoot is only an assertion that must match it, an empty one
        uses the stored root; no migration or rebind for legacy tasks
        missing the field, which fail closed with
        VERIFY_RUN_ROOT_UNBOUND), no task lock is held while external
        verifier profiles run, then stores the produced result under
        lock+CAS with verification_source='kernel-executed' and
        verifier_executed=true -- and ONLY when the run actually executed
        (ok plus verified_pass/verification_failed plus full criterion
        mapping). Tasks without a committed plan fail closed
        (VERIFIER_PLAN_MISSING); unknown profiles, policies outside the
        task root, manual/error/timeout outcomes, invalid repo/policy,
        missing criterion mapping and CAS drift fail closed with NO write.
        There is no flag or parameter that selects profiles, repo or
        source: plan and root are task-bound. TasksDir/FlagsPath stay
        independent (explicit TasksDir still locates the file; flags
        resolve from the caller). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$VerificationPolicyPath = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $effRoot = ''
        $effRootSlot = Resolve-TaskKernelExplicitRepoRoot -RepoRoot $RepoRoot
        if (-not [bool]$effRootSlot.ok) {
            return (New-TaskKernelError -Code ([string]$effRootSlot.error))
        }
        $effRoot = ([string]$effRootSlot.root)
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $effRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-TaskKernelId -TaskId $tid)) {
            return (New-TaskKernelError -Code 'INVALID_TASK_ID')
        }
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $effRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $snap = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$snap.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$snap.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $snapRec = $snap.record
        $boundVerify = Get-TaskKernelBoundVerificationRoot -Record $snapRec -CallerRepoRoot $RepoRoot -UnboundCode 'VERIFY_RUN_ROOT_UNBOUND' -MismatchCode 'VERIFY_RUN_ROOT_MISMATCH'
        if (-not [bool]$boundVerify.ok) {
            return (New-TaskKernelError -Code ([string]$boundVerify.error))
        }
        $vrepo = ([string]$boundVerify.root)
        $rev0 = [int]$snapRec['revision']
        if ([int]$ExpectedRevision -ne $rev0) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$snapRec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        $names = @()
        try {
            if (($snapRec -is [System.Collections.IDictionary]) -and ($null -ne $snapRec['verification_profiles'])) {
                foreach ($pp3 in @($snapRec['verification_profiles'])) {
                    if ($null -eq $pp3) { continue }
                    if (($pp3 -is [System.Collections.IEnumerable]) -and -not ($pp3 -is [string])) { continue }
                    $t3 = ([string]$pp3).Trim()
                    if ([string]::IsNullOrWhiteSpace($t3)) { continue }
                    if ($names -cnotcontains $t3) { $names += $t3 }
                }
            }
        }
        catch { $names = @() }
        if ((@($names)).Count -eq 0) {
            return (New-TaskKernelError -Code 'VERIFIER_PLAN_MISSING')
        }
        $baseRev = ''
        try { if ($null -ne $snapRec['base_revision']) { $baseRev = ([string]$snapRec['base_revision']).Trim() } } catch { $baseRev = '' }
        if ([string]::IsNullOrWhiteSpace($baseRev)) {
            return (New-TaskKernelError -Code 'INVALID_BASE_REVISION')
        }
        $scopes = @()
        try { if ($null -ne $snapRec['write_scopes']) { $scopes = @($snapRec['write_scopes']) } } catch { $scopes = @() }
        $criteria = @()
        try { if ($null -ne $snapRec['acceptance_criteria']) { $criteria = @($snapRec['acceptance_criteria']) } } catch { $criteria = @() }
        if ((@($criteria)).Count -eq 0) {
            return (New-TaskKernelError -Code 'INVALID_CRITERIA')
        }
        $polPath = ([string]$VerificationPolicyPath).Trim()
        if ([string]::IsNullOrWhiteSpace($polPath)) {
            $polPath = (Join-Path $vrepo 'source\registry\verification-policy.json')
        }
        $polFull = ''
        try { $polFull = [IO.Path]::GetFullPath($polPath) } catch { $polFull = '' }
        if ([string]::IsNullOrWhiteSpace($polFull) -or (-not (Test-Path -LiteralPath $polFull -PathType Leaf))) {
            return (New-TaskKernelError -Code 'VERIFICATION_POLICY_NOT_FOUND')
        }
        $rootSep = ([string]$vrepo).TrimEnd('\', '/')
        if (($polFull -cne $vrepo) -and (-not $polFull.StartsWith(($rootSep + [IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase))) {
            return (New-TaskKernelError -Code 'VERIFICATION_POLICY_OUT_OF_ROOT')
        }
        $polPath = $polFull
        $verLib = Join-Path $PSScriptRoot 'OrchestrationVerifier.ps1'
        if (-not (Test-Path -LiteralPath $verLib -PathType Leaf)) {
            return (New-TaskKernelError -Code 'VERIFIER_UNAVAILABLE')
        }
        try { . $verLib } catch { return (New-TaskKernelError -Code 'VERIFIER_UNAVAILABLE') }
        if (((Get-Command Get-OrchestrationVerificationPolicy -ErrorAction SilentlyContinue) -eq $null) -or ((Get-Command Invoke-OrchestrationVerifier -ErrorAction SilentlyContinue) -eq $null)) {
            return (New-TaskKernelError -Code 'VERIFIER_UNAVAILABLE')
        }
        $polSlot = $null
        try { $polSlot = Get-OrchestrationVerificationPolicy -PolicyPath $polPath -RepoRoot $vrepo }
        catch { $polSlot = $null }
        $polOk = $false
        $allowKeys = @()
        try {
            if ($null -ne $polSlot) {
                if ($polSlot -is [System.Collections.IDictionary]) {
                    if ($null -ne $polSlot['ok']) { $polOk = [bool]$polSlot['ok'] }
                }
                else {
                    $pok = $polSlot.PSObject.Properties | Where-Object { $_.Name -ceq 'ok' } | Select-Object -First 1
                    if ($null -ne $pok) { $polOk = [bool]$pok.Value }
                }
            }
            if ([bool]$polOk) {
                $pnode = Get-TaskKernelNodeField -Object (Get-TaskKernelNodeField -Object $polSlot -Name 'policy') -Name 'profiles'
                if (($null -ne $pnode) -and ($pnode -is [System.Collections.IDictionary])) { $allowKeys = @($pnode.Keys) }
                elseif ($null -ne $pnode) {
                    foreach ($qp4 in @($pnode.PSObject.Properties)) { $allowKeys += ([string]$qp4.Name) }
                }
            }
        }
        catch { $polOk = $false; $allowKeys = @() }
        if (-not [bool]$polOk) {
            return (New-TaskKernelError -Code 'VERIFICATION_POLICY_INVALID')
        }
        foreach ($n in $names) {
            if (@($allowKeys) -inotcontains $n) {
                return (New-TaskKernelError -Code 'UNKNOWN_VERIFIER_PROFILE' -Extra @{ profile = ([string]$n) })
            }
        }
        $vr = $null
        try {
            $vr = Invoke-OrchestrationVerifier -TaskId $tid -RepoRoot $vrepo -BaseRevision $baseRev -WriteScopes ([string[]]$scopes) -ProfileNames ([string[]]$names) -PolicyPath $polPath -AcceptanceCriteria ([string[]]$criteria)
        }
        catch { return (New-TaskKernelError -Code 'VERIFIER_INTERNAL') }
        if ($null -eq $vr) { return (New-TaskKernelError -Code 'VERIFIER_INTERNAL') }
        $vrOk = $false
        $vrStatus = ''
        try {
            $vrOk = [bool](Get-TaskKernelNodeField -Object $vr -Name 'ok')
            $vrStatus = ([string](Get-TaskKernelNodeField -Object $vr -Name 'status')).Trim()
        }
        catch { return (New-TaskKernelError -Code 'VERIFIER_INTERNAL') }
        if ((-not [bool]$vrOk) -or (($vrStatus -cne 'verified_pass') -and ($vrStatus -cne 'verification_failed'))) {
            return (New-TaskKernelError -Code 'VERIFY_RUN_NOT_EXECUTED' -Extra @{ status = $vrStatus })
        }
        $vrEvidence = @()
        try {
            $veRaw = Get-TaskKernelNodeField -Object $vr -Name 'evidence'
            if ($null -ne $veRaw) { $vrEvidence = @($veRaw) }
        }
        catch { $vrEvidence = @() }
        $covSlot = Test-TaskKernelCriterionCoverage -Evidence $vrEvidence -CriterionCount (@($criteria).Count)
        if (-not [bool]$covSlot.ok) {
            return (New-TaskKernelError -Code 'VERIFY_RUN_CRITERION_UNMAPPED' -Extra @{ detail = ([string]$covSlot.error) })
        }
        $fresh = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$fresh.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$fresh.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        if ([int]$fresh.record['revision'] -ne $rev0) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
            $slot2 = Read-TaskKernelRecord -TaskFile $taskFile
            if (-not [bool]$slot2.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
            if ([bool]$slot2.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
            $rec = $slot2.record
            if ([int]$rec['revision'] -ne $rev0) {
                return (New-TaskKernelError -Code 'CAS_CONFLICT')
            }
            if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
                return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
            }
            if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
                return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
            }
            $candRev = [int]$rec['revision']
            try {
                $wrk = $rec['worker_result']
                if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary]) -and ($null -ne $wrk['revision'])) {
                    $candRev = [int]$wrk['revision']
                }
            }
            catch { }
            $vrProfiles = @()
            try {
                $vpRaw = Get-TaskKernelNodeField -Object $vr -Name 'profiles'
                if ($null -ne $vpRaw) { $vrProfiles = @($vpRaw) }
            }
            catch { $vrProfiles = @() }
            $profClean = @(Get-TaskKernelSanitizedVerifierProfiles -Profiles $vrProfiles)
            $vrMapRaw = Get-TaskKernelNodeField -Object $vr -Name 'criterion_map'
            $mapClean = Get-TaskKernelSanitizedCriterionMap -MapRaw $vrMapRaw
            $evList = Get-TaskKernelEvidenceList -Value $vrEvidence
            if (-not [bool]$evList.valid) {
                return (New-TaskKernelError -Code 'VERIFY_RUN_CRITERION_UNMAPPED')
            }
            $evClean = Protect-TaskKernelStringList -Items ([string[]]$evList.items)
            $cmdRaw = Get-TaskKernelNodeField -Object $vr -Name 'command_classes'
            $cmdList = @()
            if ($null -ne $cmdRaw) { $cmdList = @($cmdRaw) }
            $cmd = Get-TaskKernelCleanList -Value $cmdList
            if (-not [bool]$cmd.valid) {
                return (New-TaskKernelError -Code 'VERIFY_RUN_CRITERION_UNMAPPED')
            }
            $vdigest = ''
            try {
                if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -ne $null) {
                    $vdigest = Get-LogicalHash -InputObject $vr
                }
            }
            catch { $vdigest = '' }
            $derived = ($vrStatus -ceq 'verified_pass')
            $newRev = ([int]$rec['revision'] + 1)
            $rec['verification'] = [ordered]@{
                passed              = $derived
                status              = $vrStatus
                verifier_ok         = $true
                verification_source = 'kernel-executed'
                verifier_executed   = $true
                evidence            = ([string[]]$evClean)
                command_classes     = ([string[]]$cmd.items)
                profiles            = $profClean
                criterion_map       = $mapClean
                source              = 'kernel-executed'
                result_digest       = $vdigest
                candidate_revision  = $candRev
                at                  = (Get-TaskKernelTimestamp)
                revision            = $newRev
            }
            $vhist = @()
            try { if ($null -ne $rec['verification_history']) { $vhist = @($rec['verification_history']) } } catch { $vhist = @() }
            $vhist += [ordered]@{
                status              = $vrStatus
                passed              = $derived
                verification_source = 'kernel-executed'
                verifier_executed   = $true
                candidate_revision  = $candRev
                revision            = $newRev
                result_digest       = $vdigest
                at                  = (Get-TaskKernelTimestamp)
            }
            while (@($vhist).Count -gt 64) { $vhist = @($vhist | Select-Object -Skip 1) }
            $rec['verification_history'] = $vhist
            $rec['revision'] = $newRev
            $rec['updated_at'] = (Get-TaskKernelTimestamp)
            $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
            if (-not [bool]$wr.ok) {
                return (New-TaskKernelError -Code ([string]$wr.error))
            }
            return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; passed = $derived; status = $vrStatus; verification_source = 'kernel-executed' }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function ConvertTo-TaskKernelReviewFindings {
    <#
    .SYNOPSIS
        Validates and normalizes reviewer findings (anchored schema).
    .DESCRIPTION
        Untrusted caller JSON. Bounded (max 50 findings, 256 KiB, message
        2000 chars). Uses the shared anchor helper so file/line/commit and
        owner routing stay identical to the rest of the review flow.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$FindingsJson = '', [string]$TaskId = '')
    try {
        if ([string]::IsNullOrWhiteSpace($FindingsJson)) { return @{ ok = $true; findings = @(); error = '' } }
        if ($FindingsJson.Length -gt 262144) { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_TOO_LARGE' } }
        $parsed = $null
        try { $parsed = ($FindingsJson | ConvertFrom-Json) } catch { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_INVALID' } }
        $items = @($parsed)
        if ($items.Count -gt 50) { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_TOO_MANY' } }
        $anchorLib = Join-Path $PSScriptRoot 'OrchestrationReviewAnchor.ps1'
        if (-not (Test-Path -LiteralPath $anchorLib -PathType Leaf)) { return @{ ok = $false; findings = @(); error = 'REVIEW_ANCHOR_LIB_MISSING' } }
        . $anchorLib
        $out = New-Object System.Collections.ArrayList
        foreach ($item in $items) {
            if ($null -eq $item) { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_INVALID' } }
            $fid = [string](Get-TaskKernelNodeField -Object $item -Name 'finding_id')
            $file = [string](Get-TaskKernelNodeField -Object $item -Name 'file')
            $commit = [string](Get-TaskKernelNodeField -Object $item -Name 'commit_sha')
            $msg = [string](Get-TaskKernelNodeField -Object $item -Name 'message')
            $sev = [string](Get-TaskKernelNodeField -Object $item -Name 'severity')
            if ([string]::IsNullOrWhiteSpace($sev)) { $sev = 'medium' }
            $lineRaw = Get-TaskKernelNodeField -Object $item -Name 'line'
            $line = 0
            if ($null -ne $lineRaw) { try { $line = [int]$lineRaw } catch { $line = -1 } }
            if ($msg.Length -gt 2000) { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_INVALID' } }
            $norm = New-OrchestrationReviewFinding -FindingId $fid -File $file -CommitSha $commit -Message $msg -Severity $sev -Line $line -TaskId $TaskId
            if (-not [bool]$norm.ok) { return @{ ok = $false; findings = @(); error = ('REVIEW_FINDINGS_INVALID:' + [string]$norm.error) } }
            [void]$out.Add([ordered]@{
                finding_id = [string]$norm.finding_id
                file       = [string]$norm.file
                line       = [int]$norm.line
                commit_sha = [string]$norm.commit_sha
                severity   = [string]$norm.severity
                message    = Protect-TaskKernelText -Text ([string]$norm.message)
                owner      = [string]$norm.worker
                owner_reason = [string]$norm.owner_reason
                file_sha256 = [string]$norm.file_sha256
                anchor     = [string]$norm.anchor
            })
        }
        return @{ ok = $true; findings = @($out.ToArray()); error = '' }
    }
    catch { return @{ ok = $false; findings = @(); error = 'REVIEW_FINDINGS_INVALID' } }
}

function Set-OrchestrationTaskReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$By,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$FindingsJson = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $kind = ([string]$Kind).Trim().ToLowerInvariant()
        if (@('reviewer', 'security') -cnotcontains $kind) {
            return (New-TaskKernelError -Code 'INVALID_REVIEW')
        }
        $status = ([string]$Status).Trim().ToLowerInvariant()
        if (@('approved', 'changes_required') -cnotcontains $status) {
            return (New-TaskKernelError -Code 'INVALID_REVIEW')
        }
        $by = ([string]$By).Trim()
        if ([string]::IsNullOrWhiteSpace($by)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $tid = ([string]$TaskId).Trim()
        $findingsSlot = ConvertTo-TaskKernelReviewFindings -FindingsJson $FindingsJson -TaskId $tid
        if (-not [bool]$findingsSlot.ok) {
            return (New-TaskKernelError -Code ([string]$findingsSlot.error))
        }
        $findings = @($findingsSlot.findings)
        if ($status -ceq 'approved' -and @($findings).Count -gt 0) {
            return (New-TaskKernelError -Code 'REVIEW_FINDINGS_ON_APPROVED')
        }
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $candRev = [int]$rec['revision']
        try {
            $wrk = $rec['worker_result']
            if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary]) -and ($null -ne $wrk['revision'])) {
                $candRev = [int]$wrk['revision']
            }
        }
        catch { }
        $byClean = Protect-TaskKernelText -Text $by
        # Review independence: the reviewer identity must differ from the
        # recorded worker-result producer. Self-approval is rejected
        # fail-closed (SELF_REVIEW_FORBIDDEN) so an E2E caller can never
        # fabricate independence by recording its own approval. When no worker
        # result exists yet there is no producer to conflict with.
        try {
            $wrkNode = $rec['worker_result']
            if (($null -ne $wrkNode) -and ($wrkNode -is [System.Collections.IDictionary]) -and ($null -ne $wrkNode['produced_by'])) {
                $producerName = ([string]$wrkNode['produced_by']).Trim()
                if ((-not [string]::IsNullOrWhiteSpace($producerName)) -and ($by -ieq $producerName)) {
                    return (New-TaskKernelError -Code 'SELF_REVIEW_FORBIDDEN' -Extra @{ detail = 'reviewer identity equals worker-result producer' })
                }
            }
        }
        catch { }
        $newRev = ([int]$rec['revision'] + 1)
        $entry = [ordered]@{
            status             = $status
            by                 = $byClean
            candidate_revision = $candRev
            findings_count     = @($findings).Count
            findings           = @($findings)
            at                 = (Get-TaskKernelTimestamp)
            revision           = $newRev
        }
        # Preserve prior review rounds (including their anchored findings).
        # The current review stays in `review`/`security_review`; history is
        # bounded so a long retry loop cannot grow the task without limit.
        $histKey = 'review_history'
        $history = New-Object System.Collections.ArrayList
        try {
            if ($kind -ceq 'security') { $histKey = 'security_review_history' }
            if ($null -ne $rec[$histKey]) { foreach ($h in @($rec[$histKey])) { [void]$history.Add($h) } }
            $prevKey = 'review'
            if ($kind -ceq 'security') { $prevKey = 'security_review' }
            if ($null -ne $rec[$prevKey]) { [void]$history.Add($rec[$prevKey]) }
            while ($history.Count -gt 20) { $history.RemoveAt(0) }
        }
        catch { $history = New-Object System.Collections.ArrayList }
        $rec[$histKey] = @($history.ToArray())
        if ($kind -ceq 'reviewer') { $rec['review'] = $entry }
        else { $rec['security_review'] = $entry }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; kind = $kind; status = $status }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Block-OrchestrationTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$WaitType = '',
        [string]$WaitOwner = '',
        [string]$WaitAction = '',
        [string]$WaitDependencyId = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $reason = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            return (New-TaskKernelError -Code 'INVALID_REASON')
        }
        $waitDeclared = Test-TaskKernelWaitDeclared -Type $WaitType -Owner $WaitOwner -Action $WaitAction -DependencyId $WaitDependencyId
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $from = ([string]$rec['state']).Trim().ToUpperInvariant()
        if (Test-TaskKernelTerminalState -State $from) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if ($from -ceq 'BLOCKED') {
            if (-not $waitDeclared) {
                return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'already BLOCKED' })
            }
            $reWait = New-TaskKernelTypedWait -Type $WaitType -Owner $WaitOwner -Action $WaitAction -DependencyId $WaitDependencyId
            if (-not [bool]$reWait.ok) {
                return (New-TaskKernelError -Code ([string]$reWait.error))
            }
            $reChk = Test-TaskKernelActiveWait -Record $rec
            if ([string]$reChk.presence -ceq 'malformed') {
                return (New-TaskKernelError -Code 'MALFORMED_WAIT' -Extra @{ detail = 'active wait node is present but corrupt; unblock is blocked' })
            }
            if (([string]$reChk.presence -ceq 'valid') -and ([string]$reChk.fingerprint -ceq ([string]$reWait.wait['fingerprint']))) {
                return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = ([int]$rec['revision']); state = 'BLOCKED'; wait_fingerprint = ([string]$reChk.fingerprint); idempotent = $true }
            }
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'already BLOCKED on a different wait; unblock first' })
        }
        $map = Get-OrchestrationTaskAllowedTransitions
        if ((-not $map.ContainsKey($from)) -or ((@($map[$from]) -ccontains 'BLOCKED') -ne $true)) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION')
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $strictBlock = Test-TaskKernelRequireTypedWaits -Record $rec
        if ($strictBlock -and (-not $waitDeclared)) {
            return (New-TaskKernelError -Code 'WAIT_TYPED_REQUIRED' -Extra @{ detail = 'task requires typed waits; prose-only BLOCKED is rejected' })
        }
        $reasonClean = Protect-TaskKernelText -Text $reason
        $newRev = ([int]$rec['revision'] + 1)
        $stamp = Get-TaskKernelTimestamp
        $typedWait = $null
        if ($waitDeclared) {
            $wslot = New-TaskKernelTypedWait -Type $WaitType -Owner $WaitOwner -Action $WaitAction -DependencyId $WaitDependencyId
            if (-not [bool]$wslot.ok) {
                return (New-TaskKernelError -Code ([string]$wslot.error))
            }
            $typedWait = $wslot.wait
        }
        $blockers = @()
        if ($null -ne $rec['blockers']) { $blockers = @($rec['blockers']) }
        $blockerEntry = [ordered]@{ reason = $reasonClean; actor = $actor; at = $stamp }
        if ($null -ne $typedWait) { $blockerEntry['wait'] = $typedWait }
        $blockers += $blockerEntry
        $rec['blockers'] = $blockers
        if ($null -ne $typedWait) { $rec['active_wait'] = $typedWait }
        $hist = @()
        if ($null -ne $rec['history']) { $hist = @($rec['history']) }
        $hist += [ordered]@{ from = $from; to = 'BLOCKED'; actor = $actor; at = $stamp; revision = $newRev }
        $rec['history'] = $hist
        $rec['state'] = 'BLOCKED'
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_STATE_CHANGED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        $blockOut = [ordered]@{ ok = $true; task_id = $tid; revision = $newRev; state = 'BLOCKED' }
        if ($null -ne $typedWait) { $blockOut['wait_fingerprint'] = ([string]$typedWait['fingerprint']) }
        return ([PSCustomObject]$blockOut)
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Cancel-OrchestrationTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$ActorIdentitySource = 'unknown',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $reason = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            return (New-TaskKernelError -Code 'INVALID_REASON')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
            return (New-TaskKernelError -Code 'SETTLEMENT_REQUIRED' -Extra @{ detail = 'watchdog interrupt engaged without confirmed settlement' })
        }
        $owner = ([string]$rec['current_owner']).Trim()
        if (($actor -cne $owner) -and (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource))) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $from = ([string]$rec['state']).Trim().ToUpperInvariant()
        if (Test-TaskKernelTerminalState -State $from) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        $map = Get-OrchestrationTaskAllowedTransitions
        if ((-not $map.ContainsKey($from)) -or ((@($map[$from]) -ccontains 'CANCELLED') -ne $true)) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION')
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $reasonClean = Protect-TaskKernelText -Text $reason
        $newRev = ([int]$rec['revision'] + 1)
        $stamp = Get-TaskKernelTimestamp
        $hist = @()
        if ($null -ne $rec['history']) { $hist = @($rec['history']) }
        $hist += [ordered]@{ from = $from; to = 'CANCELLED'; actor = $actor; at = $stamp; revision = $newRev }
        $rec['history'] = $hist
        $rec['state'] = 'CANCELLED'
        $rec['closure_reason'] = $reasonClean
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_CANCELLED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; state = 'CANCELLED' }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

# ---------- strategy-aware recovery, typed waits, idempotent work (Phase 27 slice 1) ----------
#
# Kernel-side slice only: canonical fingerprints, stall gates, typed wait
# contract, work dedupe. Planner dispatch/prompt wiring is out of this
# slice. All new inputs are value-detected (non-empty after trim): legacy
# calls that never pass strategy/wait/project fields take unchanged
# paths. Reads of legacy records (missing new keys) stay valid via
# tolerant field access. Never throws; domain errors are
# {ok:$false,error:'CODE'}. ASCII-only, PS 5.1.
#
# Canonicalization is lexical and deterministic (trim, single spaces,
# lowercase, sorted params): rewording with the same words in a
# different order/case/whitespace yields the same fingerprint, so
# rewording never resets counts. Real synonyms are NOT canonical
# (residual, documented in phase27.json). Every serialization that
# feeds SHA-256 uses len:value framing (P25 convention) so structural
# boundaries can never collide: 'a,b' as one item differs from the two
# items 'a' and 'b', and '|' inside values cannot shift fields.

function Get-TaskKernelCanonicalText {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        $t = ([regex]::Replace($t, '\s+', ' '))
        return ($t.ToLowerInvariant())
    }
    catch { return '' }
}

function Get-TaskKernelCanonicalList {
    <#
    .SYNOPSIS
        Canonical list fingerprint input: cleaned, canonicalized,
        ordinal-sorted items in len:value framing with an explicit
        item count. Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        $clean = Get-TaskKernelCleanList -Value $Value
        if (-not [bool]$clean.valid) { return '0:' }
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($s in @($clean.items)) {
            $c = Get-TaskKernelCanonicalText -Text ([string]$s)
            if (-not [string]::IsNullOrWhiteSpace($c)) { $list.Add($c) | Out-Null }
        }
        $list.Sort([System.StringComparer]::Ordinal)
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($s in $list.ToArray()) { $parts.Add((Get-TaskKernelFrame -Text $s)) | Out-Null }
        return (($parts.Count.ToString([Globalization.CultureInfo]::InvariantCulture)) + ':' + ($parts.ToArray() -join ','))
    }
    catch { return '0:' }
}

function Get-TaskKernelFrame {
    <#
    .SYNOPSIS
        len:value framing for one canonical field (length in UTF-16
        code units, invariant digits). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = [string]$Text
        return ($t.Length.ToString([Globalization.CultureInfo]::InvariantCulture) + ':' + $t)
    }
    catch { return '0:' }
}

function New-TaskKernelFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Canonical)
    return ('sha256:' + (Get-TaskKernelStringHash -Text ([string]$Canonical)))
}

function ConvertTo-TaskKernelFingerprint {
    <#
    .SYNOPSIS
        Normalizes to 'sha256:<hex>' or '' when invalid. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim().ToLowerInvariant()
        if ($v.StartsWith('sha256:')) { $v = $v.Substring(7) }
        if ($v -cmatch '^[0-9a-f]{64}$') { return ('sha256:' + $v) }
    }
    catch { }
    return ''
}

function Get-OrchestrationFailureClasses {
    [CmdletBinding()]
    param()
    return @('timeout', 'no_progress', 'repeated_action', 'repeated_cycle', 'worker_failed', 'verification_failed', 'review_rejected', 'external_dependency', 'unknown')
}

function Get-OrchestrationRecoverySources {
    [CmdletBinding()]
    param()
    return @('planner', 'debugger', 'watchdog', 'worker', 'manual')
}

function Get-OrchestrationWaitTypes {
    [CmdletBinding()]
    param()
    return @('human_decision', 'external_dependency', 'worker', 'review', 'approval', 'runtime_recovery')
}

function Get-OrchestrationStrategyFingerprint {
    <#
    .SYNOPSIS
        Canonical strategy fingerprint: SHA-256 over the canonical
        descriptor (normalized approach + primary tool/path + ordinal
        sorted key params). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Approach = '', [string]$ToolOrPath = '', $KeyParams = @())
    try {
        $a = Get-TaskKernelCanonicalText -Text ([string]$Approach)
        if ([string]::IsNullOrWhiteSpace($a)) {
            return ([PSCustomObject]@{ ok = $false; error = 'INVALID_STRATEGY'; fingerprint = '' })
        }
        $tool = Get-TaskKernelCanonicalText -Text ([string]$ToolOrPath)
        $params = Get-TaskKernelCanonicalList -Value $KeyParams
        $canon = ('v1|approach=' + (Get-TaskKernelFrame -Text $a) + '|tool=' + (Get-TaskKernelFrame -Text $tool) + '|params=' + $params)
        return ([PSCustomObject]@{ ok = $true; error = ''; fingerprint = (New-TaskKernelFingerprint -Canonical $canon) })
    }
    catch { return ([PSCustomObject]@{ ok = $false; error = 'INTERNAL_ERROR'; fingerprint = '' }) }
}

function Get-OrchestrationRecoveryFingerprint {
    <#
    .SYNOPSIS
        Canonical failure/recovery fingerprint: SHA-256 over closed
        failure class + strategy fingerprint + canonical scope. The
        free-text failure detail is NOT an input, so rewording the
        same failure keeps the fingerprint (counts never reset).
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$FailureClass = '', [string]$StrategyFingerprint = '', $Scope = @())
    try {
        $cls = ([string]$FailureClass).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($cls)) { $cls = 'unknown' }
        if ((@(Get-OrchestrationFailureClasses) -cnotcontains $cls)) {
            return ([PSCustomObject]@{ ok = $false; error = 'INVALID_FAILURE_CLASS'; fingerprint = '' })
        }
        $fp = ConvertTo-TaskKernelFingerprint -Value ([string]$StrategyFingerprint)
        $scopeCanon = Get-TaskKernelCanonicalList -Value $Scope
        $canon = ('v1|failure_class=' + (Get-TaskKernelFrame -Text $cls) + '|strategy=' + (Get-TaskKernelFrame -Text $fp) + '|scope=' + $scopeCanon)
        return ([PSCustomObject]@{ ok = $true; error = ''; fingerprint = (New-TaskKernelFingerprint -Canonical $canon); failure_class = $cls })
    }
    catch { return ([PSCustomObject]@{ ok = $false; error = 'INTERNAL_ERROR'; fingerprint = '' }) }
}

function Get-OrchestrationWaitFingerprint {
    <#
    .SYNOPSIS
        Canonical typed-wait fingerprint: SHA-256 over closed wait
        type + owner + action (+ dependency id when present).
        Never throws.
    #>
    [CmdletBinding()]
    param([string]$Type = '', [string]$Owner = '', [string]$Action = '', [string]$DependencyId = '')
    try {
        $t = ([string]$Type).Trim().ToLowerInvariant()
        if ((@(Get-OrchestrationWaitTypes) -cnotcontains $t)) {
            return ([PSCustomObject]@{ ok = $false; error = 'WAIT_TYPED_REQUIRED'; fingerprint = '' })
        }
        $o = Get-TaskKernelCanonicalText -Text ([string]$Owner)
        $a = Get-TaskKernelCanonicalText -Text ([string]$Action)
        if ([string]::IsNullOrWhiteSpace($o) -or [string]::IsNullOrWhiteSpace($a)) {
            return ([PSCustomObject]@{ ok = $false; error = 'WAIT_TYPED_REQUIRED'; fingerprint = '' })
        }
        $d = Get-TaskKernelCanonicalText -Text ([string]$DependencyId)
        $canon = ('v1|type=' + (Get-TaskKernelFrame -Text $t) + '|owner=' + (Get-TaskKernelFrame -Text $o) + '|action=' + (Get-TaskKernelFrame -Text $a) + '|dependency_id=' + (Get-TaskKernelFrame -Text $d))
        return ([PSCustomObject]@{ ok = $true; error = ''; fingerprint = (New-TaskKernelFingerprint -Canonical $canon) })
    }
    catch { return ([PSCustomObject]@{ ok = $false; error = 'INTERNAL_ERROR'; fingerprint = '' }) }
}

function New-TaskKernelTypedWait {
    <#
    .SYNOPSIS
        Builds the sanitized typed-wait node (type/owner/action/
        dependency_id/fingerprint) or WAIT_TYPED_REQUIRED. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Type = '', [string]$Owner = '', [string]$Action = '', [string]$DependencyId = '')
    try {
        $slot = Get-OrchestrationWaitFingerprint -Type $Type -Owner $Owner -Action $Action -DependencyId $DependencyId
        if (-not [bool]$slot.ok) {
            return ([PSCustomObject]@{ ok = $false; error = ([string]$slot.error); wait = $null })
        }
        $wait = [ordered]@{
            type          = (([string]$Type).Trim().ToLowerInvariant())
            owner         = (Protect-TaskKernelText -Text (([string]$Owner).Trim()))
            action        = (Protect-TaskKernelText -Text (([string]$Action).Trim()))
            dependency_id = (Protect-TaskKernelText -Text (([string]$DependencyId).Trim()))
            fingerprint   = ([string]$slot.fingerprint)
        }
        return ([PSCustomObject]@{ ok = $true; error = ''; wait = $wait })
    }
    catch { return ([PSCustomObject]@{ ok = $false; error = 'INTERNAL_ERROR'; wait = $null }) }
}

function Test-TaskKernelWaitDeclared {
    <#
    .SYNOPSIS
        Value-based detection: a typed wait is declared when any wait
        field carries a non-blank value. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Type = '', [string]$Owner = '', [string]$Action = '', [string]$DependencyId = '')
    try {
        foreach ($v in @($Type, $Owner, $Action, $DependencyId)) {
            if (-not [string]::IsNullOrWhiteSpace(([string]$v).Trim())) { return $true }
        }
    }
    catch { }
    return $false
}

function Get-OrchestrationWorkFingerprint {
    <#
    .SYNOPSIS
        Canonical work-unit fingerprint: SHA-256 over canonical
        objective + ordinal-sorted scope + ordinal-sorted definition
        of done + project identity. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Objective = '', $Scope = @(), $DefinitionOfDone = @(), [string]$Project = '')
    try {
        $obj = Get-TaskKernelCanonicalText -Text ([string]$Objective)
        if ([string]::IsNullOrWhiteSpace($obj)) {
            return ([PSCustomObject]@{ ok = $false; error = 'INVALID_OBJECTIVE'; fingerprint = '' })
        }
        $scopeCanon = Get-TaskKernelCanonicalList -Value $Scope
        $dodCanon = Get-TaskKernelCanonicalList -Value $DefinitionOfDone
        $proj = Get-TaskKernelCanonicalText -Text ([string]$Project)
        $canon = ('v1|objective=' + (Get-TaskKernelFrame -Text $obj) + '|scope=' + $scopeCanon + '|definition_of_done=' + $dodCanon + '|project=' + (Get-TaskKernelFrame -Text $proj))
        return ([PSCustomObject]@{ ok = $true; error = ''; fingerprint = (New-TaskKernelFingerprint -Canonical $canon) })
    }
    catch { return ([PSCustomObject]@{ ok = $false; error = 'INTERNAL_ERROR'; fingerprint = '' }) }
}

function Get-TaskKernelAttemptField {
    <#
    .SYNOPSIS
        Tolerant attempt-field read (legacy attempts miss new keys).
        Returns $null when absent. Never throws.
    #>
    [CmdletBinding()]
    param($Attempt, [string]$Name)
    try {
        if ($Attempt -is [System.Collections.IDictionary]) {
            if ($Attempt.Contains($Name)) { return $Attempt[$Name] }
            return $null
        }
        $p = $Attempt.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function Get-TaskKernelActiveWaitFingerprint {
    <#
    .SYNOPSIS
        Normalized active-wait fingerprint or '' (legacy records have
        no active_wait node). Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        if (($null -eq $Record) -or (-not ($Record -is [System.Collections.IDictionary]))) { return '' }
        if (-not $Record.Contains('active_wait')) { return '' }
        $w = $Record['active_wait']
        if (($null -eq $w) -or (-not ($w -is [System.Collections.IDictionary]))) { return '' }
        if (-not $w.Contains('fingerprint')) { return '' }
        return (ConvertTo-TaskKernelFingerprint -Value ([string]$w['fingerprint']))
    }
    catch { return '' }
}

function Test-TaskKernelActiveWait {
    <#
    .SYNOPSIS
        Distinguishes absent (no node or null: legacy, gate-free) from
        valid (closed type, non-blank owner/action, well-formed
        fingerprint) and malformed (present but corrupt: fail-closed).
        Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    $out = @{ presence = 'absent'; fingerprint = '' }
    try {
        if (($null -eq $Record) -or (-not ($Record -is [System.Collections.IDictionary]))) { return $out }
        if (-not $Record.Contains('active_wait')) { return $out }
        $w = $Record['active_wait']
        if ($null -eq $w) { return $out }
        if (-not ($w -is [System.Collections.IDictionary])) {
            $out.presence = 'malformed'
            return $out
        }
        $wt = ''
        $wo = ''
        $wa = ''
        $wf = ''
        try {
            if ($w.Contains('type')) { $wt = ([string]$w['type']).Trim().ToLowerInvariant() }
            if ($w.Contains('owner')) { $wo = ([string]$w['owner']).Trim() }
            if ($w.Contains('action')) { $wa = ([string]$w['action']).Trim() }
            if ($w.Contains('fingerprint')) { $wf = ConvertTo-TaskKernelFingerprint -Value ([string]$w['fingerprint']) }
        }
        catch { $out.presence = 'malformed'; return $out }
        if (((@(Get-OrchestrationWaitTypes) -cnotcontains $wt)) -or ([string]::IsNullOrWhiteSpace($wo)) -or ([string]::IsNullOrWhiteSpace($wa)) -or ([string]::IsNullOrWhiteSpace($wf))) {
            $out.presence = 'malformed'
            return $out
        }
        $out.presence = 'valid'
        $out.fingerprint = $wf
        return $out
    }
    catch { $out.presence = 'malformed'; return $out }
}

function Test-TaskKernelRequireTypedWaits {
    <#
    .SYNOPSIS
        Sticky per-task strict flag (F-A): true only when the record
        carries require_typed_waits as a $true bool. Absent (legacy)
        or any other shape reads as false. Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        if (($null -eq $Record) -or (-not ($Record -is [System.Collections.IDictionary]))) { return $false }
        if (-not $Record.Contains('require_typed_waits')) { return $false }
        $v = $Record['require_typed_waits']
        return ((($v -is [bool]) -and [bool]$v))
    }
    catch { return $false }
}

function Resolve-TaskKernelStrategyFingerprint {
    <#
    .SYNOPSIS
        Resolves the incoming strategy fingerprint: explicit value
        wins (validated), else computed from the descriptor, else ''
        when nothing was supplied (legacy). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Explicit = '', [string]$Approach = '', [string]$ToolOrPath = '', $KeyParams = @())
    try {
        $explicitBound = (-not [string]::IsNullOrWhiteSpace(([string]$Explicit).Trim()))
        $hasDesc = $false
        foreach ($v in @(([string]$Approach), ([string]$ToolOrPath))) {
            if (-not [string]::IsNullOrWhiteSpace($v)) { $hasDesc = $true }
        }
        try {
            foreach ($e in @($KeyParams)) {
                if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) { $hasDesc = $true }
            }
        }
        catch { }
        if ($explicitBound) {
            $exp = ConvertTo-TaskKernelFingerprint -Value ([string]$Explicit)
            if ([string]::IsNullOrWhiteSpace($exp)) {
                return @{ ok = $false; fingerprint = ''; error = 'INVALID_STRATEGY_FINGERPRINT' }
            }
            if ($hasDesc) {
                $dslot = Get-OrchestrationStrategyFingerprint -Approach $Approach -ToolOrPath $ToolOrPath -KeyParams $KeyParams
                if (-not [bool]$dslot.ok) { return @{ ok = $false; fingerprint = ''; error = ([string]$dslot.error) } }
                if ([string]$dslot.fingerprint -cne $exp) {
                    return @{ ok = $false; fingerprint = ''; error = 'STRATEGY_MISMATCH' }
                }
            }
            return @{ ok = $true; fingerprint = $exp; error = '' }
        }
        if (-not $hasDesc) { return @{ ok = $true; fingerprint = ''; error = '' } }
        $slot = Get-OrchestrationStrategyFingerprint -Approach $Approach -ToolOrPath $ToolOrPath -KeyParams $KeyParams
        if (-not [bool]$slot.ok) { return @{ ok = $false; fingerprint = ''; error = ([string]$slot.error) } }
        return @{ ok = $true; fingerprint = ([string]$slot.fingerprint); error = '' }
    }
    catch { return @{ ok = $false; fingerprint = ''; error = 'INTERNAL_ERROR' } }
}

function Get-OrchestrationDuplicateWork {
    <#
    .SYNOPSIS
        Scans the tasks dir for an ACTIVE (non-terminal) task with the
        same work fingerprint. Malformed/unreadable rows are skipped
        (fail-open for create); only exact fingerprint matches dedupe.
        The kernel never merges: it reports existing_task_id and the
        Planner decides attach/resume. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkFingerprint,
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$ExcludeTaskId = ''
    )
    $out = @{ found = $false; existing_task_id = '' }
    try {
        $fp = ConvertTo-TaskKernelFingerprint -Value ([string]$WorkFingerprint)
        if ([string]::IsNullOrWhiteSpace($fp)) { return $out }
        $dir = $TasksDir
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-TaskKernelDefaultTasksDir -RepoRoot $RepoRoot }
        $fullDir = ''
        try { $fullDir = [IO.Path]::GetFullPath($dir) } catch { return $out }
        if (-not (Test-Path -LiteralPath $fullDir -PathType Container)) { return $out }
        $excl = ([string]$ExcludeTaskId).Trim()
        foreach ($f in @(Get-ChildItem -LiteralPath $fullDir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                if ((-not [string]::IsNullOrWhiteSpace($excl)) -and ($base -ceq $excl)) { continue }
                $slot = Read-TaskKernelRecord -TaskFile $f.FullName
                if ((-not [bool]$slot.found) -or ([bool]$slot.malformed)) { continue }
                $rec = $slot.record
                if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { continue }
                if (-not $rec.Contains('work_fingerprint')) { continue }
                $cand = ConvertTo-TaskKernelFingerprint -Value ([string]$rec['work_fingerprint'])
                if ([string]::IsNullOrWhiteSpace($cand) -or ($cand -cne $fp)) { continue }
                $st = ''
                try { $st = ([string]$rec['state']).Trim().ToUpperInvariant() } catch { $st = '' }
                if (Test-TaskKernelTerminalState -State $st) { continue }
                $tid = ''
                try { $tid = ([string]$rec['task_id']).Trim() } catch { $tid = '' }
                if ([string]::IsNullOrWhiteSpace($tid)) { $tid = $base }
                $out.found = $true
                $out.existing_task_id = $tid
                return $out
            }
            catch { continue }
        }
    }
    catch { }
    return $out
}

# ---------- watchdog settlement seam (Phase 26) ----------

function Test-TaskKernelWatchdogSettlementClear {
    <#
    .SYNOPSIS
        Fail-closed settlement gate (Phase 26, hardened P26-FIX1 F7).
        Returns $true ONLY when no watchdog interrupt is pending
        settlement: the watchdog_interrupt node is ABSENT, or it is a
        well-formed dict whose engaged flag is a $false bool, or whose
        engaged=$true bool pairs with a settled=$true bool. EVERYTHING
        else blocks: null/non-dict record, present-but-null/non-dict
        node, missing/non-bool engaged/settled flags, engaged without
        confirmed settlement, and any inspection exception. A malformed
        node NEVER reads as 'free'. Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    try {
        if (($null -eq $Record) -or (-not ($Record -is [System.Collections.IDictionary]))) { return $false }
        if (-not $Record.Contains('watchdog_interrupt')) { return $true }
        $node = $Record['watchdog_interrupt']
        if (($null -eq $node) -or (-not ($node -is [System.Collections.IDictionary]))) { return $false }
        if (-not $node.Contains('engaged')) { return $false }
        $rawEngaged = $node['engaged']
        if (-not ($rawEngaged -is [bool])) { return $false }
        if (-not [bool]$rawEngaged) { return $true }
        if (-not $node.Contains('settled')) { return $false }
        $rawSettled = $node['settled']
        if (-not ($rawSettled -is [bool])) { return $false }
        return ([bool]$rawSettled)
    }
    catch { return $false }
}

function Set-OrchestrationTaskWatchdogInterrupt {
    <#
    .SYNOPSIS
        Records a watchdog interrupt engagement on the task record
        (Phase 26 seam): attempt_n + closed-class token + telemetry FILE
        reference (leaf name only, never content) + engaged mark with
        settled=$false. A pending (engaged, unsettled) mark blocks
        Complete/Cancel with SETTLEMENT_REQUIRED until
        Confirm-OrchestrationTaskWatchdogSettlement runs. Re-engaging
        while a mark is pending returns WATCHDOG_ALREADY_ENGAGED without
        mutation; engaging after settlement starts a fresh mark. Planner/
        build + trusted identity + CAS + lock. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        $AttemptN = $null,
        [Parameter(Mandatory = $true)][string]$Class,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$TelemetryFile = '',
        [string]$ActorIdentitySource = 'unknown',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        if (-not (Test-ExecutionBudgetInt -Value $AttemptN -Min 1 -Max 1000000)) {
            return (New-TaskKernelError -Code 'INVALID_ATTEMPT')
        }
        $cls = ([string]$Class).Trim().ToUpperInvariant()
        if (($cls -cne 'HARD_TIMEOUT') -and ($cls -cne 'NO_PROGRESS') -and ($cls -cne 'REPEATED_ACTION') -and ($cls -cne 'REPEATED_CYCLE')) {
            return (New-TaskKernelError -Code 'INVALID_WATCHDOG_CLASS')
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $actorLow = $actor.ToLowerInvariant()
        if (($actorLow -cne 'planner') -and ($actorLow -cne 'build')) {
            return (New-TaskKernelError -Code 'BUDGET_WIDEN_DENIED' -Extra @{ detail = 'watchdog interrupt mark is planner/kernel only' })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $leaf = ([string]$TelemetryFile).Trim()
        if (-not [string]::IsNullOrWhiteSpace($leaf)) {
            try { $leaf = Split-Path -Leaf $leaf } catch { }
            $leaf = ([string]$leaf).Trim()
            if ($leaf.Length -gt 256) { $leaf = $leaf.Substring(0, 256) }
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        try {
            $closeCheck = $null
            try { $closeCheck = $rec['watchdog_interrupt'] } catch { $closeCheck = $null }
            if (($null -ne $closeCheck) -and ($closeCheck -is [System.Collections.IDictionary])) {
                $cEng = (($null -ne $closeCheck['engaged']) -and ($closeCheck['engaged'] -is [bool]) -and [bool]$closeCheck['engaged'])
                $cSet = (($null -ne $closeCheck['settled']) -and ($closeCheck['settled'] -is [bool]) -and [bool]$closeCheck['settled'])
                $cDisp = ''
                try { if ($null -ne $closeCheck['settled_disposition']) { $cDisp = ([string]$closeCheck['settled_disposition']).Trim().ToLowerInvariant() } } catch { $cDisp = '' }
                if (([bool]$cEng) -and ([bool]$cSet) -and ($cDisp -ceq 'close')) {
                    return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog settlement closed without retry; no further interrupts' })
                }
            }
        }
        catch { }
        if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
            return (New-TaskKernelError -Code 'WATCHDOG_ALREADY_ENGAGED')
        }
        $newRev = ([int]$rec['revision'] + 1)
        $rec['watchdog_interrupt'] = [ordered]@{
            engaged        = $true
            attempt_n      = [int][long]$AttemptN
            class          = $cls
            telemetry_file = (Protect-TaskKernelText -Text $leaf)
            engaged_at     = (Get-TaskKernelTimestamp)
            engaged_by     = (Protect-TaskKernelText -Text $actor)
            settled        = $false
            settled_at     = ''
        }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; watchdog_engaged = $true; class = $cls }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Confirm-OrchestrationTaskWatchdogSettlement {
    <#
    .SYNOPSIS
        Confirms post-interrupt settlement (Phase 26 seam): flips a
        pending watchdog_interrupt mark to settled=$true so release/
        complete may proceed. -Disposition RETRY (default) settles as
        retryable: any later attempt still passes the ATTEMPT_GATE
        (hypothesis/new-evidence). CLOSE settles as terminal-without-
        retry: Start-OrchestrationTaskAttempt then rejects every later
        attempt with WATCHDOG_CLOSED_NO_RETRY, so the task can only be
        released/completed, never retried. Idempotent: repeats and
        confirms on a never-engaged record succeed without mutation
        (repeats report the stored disposition). Planner/build +
        trusted identity + CAS + lock. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$ActorIdentitySource = 'unknown',
        [string]$Disposition = 'RETRY',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $disp = ([string]$Disposition).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($disp)) { $disp = 'RETRY' }
        if (($disp -cne 'RETRY') -and ($disp -cne 'CLOSE')) {
            return (New-TaskKernelError -Code 'INVALID_WATCHDOG_DISPOSITION')
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $actorLow = $actor.ToLowerInvariant()
        if (($actorLow -cne 'planner') -and ($actorLow -cne 'build')) {
            return (New-TaskKernelError -Code 'BUDGET_WIDEN_DENIED' -Extra @{ detail = 'watchdog settlement confirm is planner/kernel only' })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        if (Test-TaskKernelWatchdogSettlementClear -Record $rec) {
            $noopDisp = 'retry'
            try {
                $noopNode = $rec['watchdog_interrupt']
                if (($null -ne $noopNode) -and ($noopNode -is [System.Collections.IDictionary]) -and ($null -ne $noopNode['settled_disposition'])) {
                    $noopRaw = ([string]$noopNode['settled_disposition']).Trim().ToLowerInvariant()
                    if ($noopRaw -ceq 'close') { $noopDisp = 'close' }
                }
            }
            catch { $noopDisp = 'retry' }
            return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = ([int]$rec['revision']); watchdog_settled = $true; noop = $true; disposition = $noopDisp }
        }
        $node = $rec['watchdog_interrupt']
        if (($null -eq $node) -or (-not ($node -is [System.Collections.IDictionary]))) {
            return (New-TaskKernelError -Code 'MALFORMED')
        }
        $node['settled'] = $true
        $node['settled_at'] = (Get-TaskKernelTimestamp)
        $node['settled_disposition'] = ($disp.ToLowerInvariant())
        $newRev = ([int]$rec['revision'] + 1)
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; watchdog_settled = $true; disposition = ($disp.ToLowerInvariant()) }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

# ---------- completion gate (Phase 13 seam) ----------

function Test-OrchestrationTaskCompletion {
    <#
    .SYNOPSIS
        Higher-level DONE gate. Returns @{complete, reasons}.
        -OrchestrationCompliance must equal 'COMPLIANT' (caller passes the
        Test-OrchestrationDoneCompliance verdict). Criterion satisfaction
        counts ONLY verification.evidence (worker claimed_evidence is
        provenance only). Verification and review records must not be stale
        relative to the current worker_result revision. UNIVERSAL DONE
        CONTRACT (P0-207): every Kernel-managed task concludes DONE only on
        trusted kernel-executed proof (status verified_pass with
        verification_source AND source exactly 'kernel-executed',
        verifier_executed true, passed true, and full criterion coverage via
        Invoke-TaskKernelVerifyRun). Caller-supplied verification
        (Set-OrchestrationTaskVerification) stays readable as UNTRUSTED
        input but never satisfies the gate, regardless of
        verification_profiles, model_attempts, or the legacy
        completion_verification_contract marker. Caller-supplied input
        alone cannot satisfy the gate. For a plan-less legacy record with
        no existing valid kernel-executed proof, fresh verify-run fails
        VERIFIER_PLAN_MISSING and no migration or rebind is performed, so
        it remains blocked but readable and history-preserved; if a
        coherent trusted kernel proof already exists, the universal gate
        may accept it. Caller-supplied JSON never creates model proof.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$OrchestrationCompliance = '',
        [string]$Actor = '',
        [string[]]$ResidualRisks = @(),
        [switch]$AcceptEmptyResidualRisks,
        [string]$LeasesDir = '',
        [string]$CurrentBaseRevision = ''
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            $reasons.Add('task-not-found') | Out-Null
            return [PSCustomObject]@{ complete = $false; reasons = ([string[]]$reasons.ToArray()) }
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) {
            $reasons.Add('task-not-found') | Out-Null
            return [PSCustomObject]@{ complete = $false; reasons = ([string[]]$reasons.ToArray()) }
        }
        if ([bool]$slot.malformed) {
            $reasons.Add('task-malformed') | Out-Null
            return [PSCustomObject]@{ complete = $false; reasons = ([string[]]$reasons.ToArray()) }
        }
        $rec = $slot.record
        if ([string]$OrchestrationCompliance -cne 'COMPLIANT') {
            $reasons.Add('orchestration-compliance-missing-or-not-compliant') | Out-Null
        }
        $rt = $rec['runtime']
        $rtId = ''
        $rtGen = 0
        $rtProf = ''
        try {
            if (($null -ne $rt) -and ($rt -is [System.Collections.IDictionary])) {
                if ($null -ne $rt['id']) { $rtId = ([string]$rt['id']).Trim() }
                if ($null -ne $rt['generation']) { $rtGen = [int]$rt['generation'] }
                if ($null -ne $rt['profile']) { $rtProf = ([string]$rt['profile']).Trim() }
            }
        }
        catch { }
        if ([string]::IsNullOrWhiteSpace($rtId) -or (($rtGen -ne 1) -and ($rtGen -ne 2))) {
            $reasons.Add('runtime-block-incomplete') | Out-Null
        }
        else {
            $expectedProf = 'v1'
            if ([int]$rtGen -eq 2) { $expectedProf = 'v2' }
            if ($rtProf -cne $expectedProf) {
                $reasons.Add('runtime_profile_mismatch') | Out-Null
            }
        }
        if ($PSBoundParameters.ContainsKey('CurrentBaseRevision') -and (-not [string]::IsNullOrWhiteSpace($CurrentBaseRevision))) {
            $wantBase = ([string]$CurrentBaseRevision).Trim()
            $recBase = ''
            try { $recBase = ([string]$rec['base_revision']).Trim() } catch { $recBase = '' }
            if ($wantBase -cne $recBase) {
                $reasons.Add('base_stale') | Out-Null
            }
        }
        $map = Get-OrchestrationTaskAllowedTransitions
        $hist = @()
        if ($null -ne $rec['history']) { $hist = @($rec['history']) }
        foreach ($h in $hist) {
            $hf = ''
            $ht = ''
            try {
                if ($h -is [System.Collections.IDictionary]) {
                    if ($null -ne $h['from']) { $hf = ([string]$h['from']).Trim().ToUpperInvariant() }
                    if ($null -ne $h['to']) { $ht = ([string]$h['to']).Trim().ToUpperInvariant() }
                }
                else {
                    if ($null -ne $h.from) { $hf = ([string]$h.from).Trim().ToUpperInvariant() }
                    if ($null -ne $h.to) { $ht = ([string]$h.to).Trim().ToUpperInvariant() }
                }
            }
            catch { }
            if ((-not $map.ContainsKey($hf)) -or ((@($map[$hf]) -ccontains $ht) -ne $true)) {
                # Kernel-authorized terminal writes (DONE/EXHAUSTED targets)
                # bypass the generic map; they stay legal history.
                if (-not ((($ht -ceq 'DONE') -or ($ht -ceq 'EXHAUSTED')) -and $map.ContainsKey($hf))) {
                    $reasons.Add(('illegal-history-transition:' + $hf + '->' + $ht)) | Out-Null
                }
            }
        }
        try {
            $fresh = Read-TaskKernelRecord -TaskFile $taskFile
            if (-not [bool]$fresh.found -or [bool]$fresh.malformed -or ([int]$fresh.revision -ne [int]$rec['revision'])) {
                $reasons.Add('revision-changed-cas-conflict') | Out-Null
            }
        }
        catch { $reasons.Add('revision-changed-cas-conflict') | Out-Null }
        $workerStatus = ''
        $workerRev = 0
        try {
            $wrk = $rec['worker_result']
            if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary])) {
                if ($null -ne $wrk['status']) { $workerStatus = ([string]$wrk['status']).Trim().ToLowerInvariant() }
                if ($null -ne $wrk['revision']) { $workerRev = [int]$wrk['revision'] }
            }
        }
        catch { }
        if ($workerStatus -cne 'candidate_pass') {
            $reasons.Add('worker-result-not-candidate-pass') | Out-Null
        }
        $verPassed = $false
        $verEvidence = @()
        $verCandRev = -1
        $verStatus = ''
        $verSource = ''
        $verExecuted = $false
        try {
            $ver = $rec['verification']
            if (($null -ne $ver) -and ($ver -is [System.Collections.IDictionary])) {
                if ($null -ne $ver['passed']) { $verPassed = [bool]$ver['passed'] }
                if ($null -ne $ver['evidence']) { $verEvidence = @($ver['evidence']) }
                if ($null -ne $ver['candidate_revision']) { $verCandRev = [int]$ver['candidate_revision'] }
                if ($null -ne $ver['status']) { $verStatus = ([string]$ver['status']).Trim() }
                if ($null -ne $ver['verification_source']) { $verSource = ([string]$ver['verification_source']).Trim() }
                if ($null -ne $ver['verifier_executed']) { $verExecuted = [bool]$ver['verifier_executed'] }
            }
        }
        catch { }
        if (-not $verPassed) {
            $reasons.Add('verification-not-passed') | Out-Null
        }
        elseif (($workerStatus -ceq 'candidate_pass') -and ([int]$verCandRev -ne [int]$workerRev)) {
            $reasons.Add('verification_stale') | Out-Null
        }
        # Universal DONE contract (P0-207): kernel-executed proof is required
        # for EVERY task. No plan/attempt/marker scoping remains: a plan-less
        # legacy task lacking existing valid trusted proof remains blocked
        # (fresh verify-run requires the committed plan, no migration), but
        # an already-existing coherent kernel-executed proof ($verTrusted)
        # still satisfies the universal gate independent of plan. The legacy
        # completion_verification_contract marker, when present, is inert
        # provenance only, never a gate input.
        if (-not (($verStatus -ceq 'verified_pass') -and ($verSource -ceq 'kernel-executed') -and ([bool]$verExecuted))) {
            $reasons.Add('verification-not-kernel-executed') | Out-Null
        }
        $criteria = @()
        if ($null -ne $rec['acceptance_criteria']) { $criteria = @($rec['acceptance_criteria']) }
        if ($criteria.Count -eq 0) {
            $reasons.Add('acceptance-criteria-empty') | Out-Null
        }
        else {
            $pool = New-Object System.Collections.Generic.List[string]
            foreach ($e in @($verEvidence)) { $pool.Add([string]$e) | Out-Null }
            for ($i = 0; $i -lt $criteria.Count; $i++) {
                $prefix = ('criterion:' + [string]$i + ':')
                $hit = $false
                foreach ($e in $pool) {
                    if ([string]$e -ne $null -and ([string]$e).StartsWith($prefix, [System.StringComparison]::Ordinal)) { $hit = $true; break }
                }
                if (-not $hit) { $reasons.Add(('criterion-evidence-missing:' + [string]$i)) | Out-Null }
            }
        }
        $verTrustStatus = ''
        $verTrustSource = ''
        $verTrustSource2 = ''
        $verTrustExecuted = $false
        try {
            $verTrustNode = $rec['verification']
            if (($null -ne $verTrustNode) -and ($verTrustNode -is [System.Collections.IDictionary])) {
                if ($null -ne $verTrustNode['status']) { $verTrustStatus = ([string]$verTrustNode['status']).Trim() }
                if ($null -ne $verTrustNode['verification_source']) { $verTrustSource = ([string]$verTrustNode['verification_source']).Trim() }
                if ($null -ne $verTrustNode['source']) { $verTrustSource2 = ([string]$verTrustNode['source']).Trim() }
                if ($null -ne $verTrustNode['verifier_executed']) { $verTrustExecuted = [bool]$verTrustNode['verifier_executed'] }
            }
        }
        catch { }
        $verTrusted = $false
        if ($verPassed -and ($verTrustStatus -ceq 'verified_pass') -and ([bool]$verTrustExecuted) -and ($verTrustSource -ceq 'kernel-executed') -and ($verTrustSource2 -ceq 'kernel-executed')) {
            $covTrust = Test-TaskKernelCriterionCoverage -Evidence $verEvidence -CriterionCount (@($criteria).Count)
            if ([bool]$covTrust.ok) {
                $allTrustVerified = $true
                foreach ($ckTrust in @($covTrust.statuses.Keys)) {
                    if ([string]$covTrust.statuses[$ckTrust] -cne 'verified') { $allTrustVerified = $false; break }
                }
                if ([bool]$allTrustVerified) {
                    $mapTrustNode = $null
                    try {
                        $verTrustRaw = $rec['verification']
                        if (($null -ne $verTrustRaw) -and ($verTrustRaw -is [System.Collections.IDictionary]) -and $verTrustRaw.Contains('criterion_map')) {
                            $mapTrustNode = $verTrustRaw['criterion_map']
                        }
                    }
                    catch { $mapTrustNode = $null }
                    if (($null -ne $mapTrustNode) -and ($mapTrustNode -is [System.Collections.IDictionary])) {
                        $mapTrustKeys = @($mapTrustNode.Keys)
                        $covTrustKeys = @($covTrust.statuses.Keys)
                        if ((@($mapTrustKeys).Count -eq @($covTrustKeys).Count) -and (@($mapTrustKeys).Count -gt 0)) {
                            $mapTrustOk = $true
                            foreach ($ckTrust2 in @($covTrustKeys)) {
                                $foundTrust = $false
                                $wordTrust = ''
                                foreach ($mkTrust in $mapTrustKeys) {
                                    if ([string]$mkTrust -ceq [string]$ckTrust2) {
                                        $foundTrust = $true
                                        try {
                                            $mvTrust = $mapTrustNode[$mkTrust]
                                            if ($mvTrust -is [System.Collections.IDictionary]) {
                                                if ($null -ne $mvTrust['status']) { $wordTrust = ([string]$mvTrust['status']).Trim().ToLowerInvariant() }
                                            }
                                            else { $wordTrust = ([string]$mvTrust).Trim().ToLowerInvariant() }
                                        }
                                        catch { $wordTrust = '' }
                                        break
                                    }
                                }
                                if ((-not $foundTrust) -or ($wordTrust -cne 'verified')) { $mapTrustOk = $false; break }
                            }
                            if ([bool]$mapTrustOk) { $verTrusted = $true }
                        }
                    }
                }
            }
        }
        # Universal contract: caller-supplied verification is UNTRUSTED for
        # every task and cannot create trusted proof. Only coherent
        # kernel-executed proof (status AND both sources AND executed flag
        # AND full criterion coverage, enforced by
        # verification-not-kernel-executed above) is DONE-capable. Legacy
        # plan-less records stay readable; without existing valid trusted
        # proof they cannot DONE, but valid pre-existing kernel proof may
        # still be accepted.
        if (-not $verTrusted) {
            $reasons.Add('verification-untrusted') | Out-Null
        }
        $revStatus = ''
        $revCandRev = -1
        try {
            $rev = $rec['review']
            if (($null -ne $rev) -and ($rev -is [System.Collections.IDictionary])) {
                if ($null -ne $rev['status']) {
                    $revStatus = ([string]$rev['status']).Trim().ToLowerInvariant()
                }
                if ($null -ne $rev['candidate_revision']) { $revCandRev = [int]$rev['candidate_revision'] }
            }
        }
        catch { }
        if ($revStatus -cne 'approved') {
            $reasons.Add('review-not-approved') | Out-Null
        }
        elseif (($workerStatus -ceq 'candidate_pass') -and ([int]$revCandRev -lt [int]$workerRev)) {
            $reasons.Add('review_stale') | Out-Null
        }
        $risk = ''
        try { $risk = ([string]$rec['risk']).Trim().ToLowerInvariant() } catch { }
        if (($risk -ceq 'high') -or ($risk -ceq 'critical')) {
            $secStatus = ''
            $secCandRev = -1
            try {
                $sec = $rec['security_review']
                if (($null -ne $sec) -and ($sec -is [System.Collections.IDictionary])) {
                    if ($null -ne $sec['status']) {
                        $secStatus = ([string]$sec['status']).Trim().ToLowerInvariant()
                    }
                    if ($null -ne $sec['candidate_revision']) { $secCandRev = [int]$sec['candidate_revision'] }
                }
            }
            catch { }
            if ($secStatus -cne 'approved') {
                $reasons.Add('security-review-not-approved') | Out-Null
            }
            elseif (($workerStatus -ceq 'candidate_pass') -and ([int]$secCandRev -lt [int]$workerRev)) {
                $reasons.Add('review_stale') | Out-Null
            }
        }
        $blockers = @()
        if ($null -ne $rec['blockers']) { $blockers = @($rec['blockers']) }
        if ($blockers.Count -gt 0) {
            $reasons.Add('blockers-unresolved') | Out-Null
        }
        if ($PSBoundParameters.ContainsKey('LeasesDir') -and (-not [string]::IsNullOrWhiteSpace($LeasesDir))) {
            try {
                if ((Get-Command Get-OrchestrationActiveLeases -ErrorAction SilentlyContinue) -ne $null) {
                    $ownScopes = @()
                    if ($null -ne $rec['write_scopes']) { $ownScopes = @($rec['write_scopes']) }
                    if (@($ownScopes).Count -gt 0) {
                        $act = Get-OrchestrationActiveLeases -LocksDir $LeasesDir -RepoRoot $RepoRoot
                        if (($null -ne $act) -and [bool]$act.ok) {
                            foreach ($lz in @($act.leases)) {
                                $lzId = ''
                                $lzScopes = @()
                                try {
                                    if ($lz -is [System.Collections.IDictionary]) {
                                        if ($null -ne $lz['task_id']) { $lzId = ([string]$lz['task_id']).Trim() }
                                        if ($null -ne $lz['write_scopes']) { $lzScopes = @($lz['write_scopes']) }
                                    }
                                    else {
                                        if ($null -ne $lz.task_id) { $lzId = ([string]$lz.task_id).Trim() }
                                        if ($null -ne $lz.write_scopes) { $lzScopes = @($lz.write_scopes) }
                                    }
                                }
                                catch { continue }
                                if ([string]::IsNullOrWhiteSpace($lzId) -or ($lzId -ceq $tid)) { continue }
                                if ((Get-Command Get-OrchestrationScopeOverlap -ErrorAction SilentlyContinue) -ne $null) {
                                    if (Get-OrchestrationScopeOverlap -ScopesA ([string[]]$ownScopes) -ScopesB ([string[]]$lzScopes)) {
                                        $reasons.Add('ownership_conflict') | Out-Null
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
            catch { $reasons.Add('ownership-check-failed') | Out-Null }
        }
        $budget = 3
        try { $budget = [int]$rec['attempt_budget'] } catch { $budget = 3 }
        if ($budget -lt 1) { $budget = 3 }
        $attempts = @()
        if ($null -ne $rec['attempts']) { $attempts = @($rec['attempts']) }
        if ($attempts.Count -gt $budget) {
            $reasons.Add('attempt-budget-exceeded') | Out-Null
        }
        $rr = @()
        if ($null -ne $ResidualRisks) { $rr = @($ResidualRisks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
        if ($rr.Count -eq 0 -and -not [bool]$AcceptEmptyResidualRisks) {
            $reasons.Add('residual-risks-not-recorded') | Out-Null
        }
        # Issue #106: Evidence Freshness check before DONE (evaluating evidence, evidence_items, evidence_refs)
        $evItems = @()
        if ($null -ne $rec['evidence']) { $evItems += @($rec['evidence']) }
        if ($null -ne $rec['evidence_items']) { $evItems += @($rec['evidence_items']) }
        if ($null -ne $rec['evidence_refs']) { $evItems += @($rec['evidence_refs']) }
        if ($evItems.Count -gt 0) {
            try {
                $freshnessLib = Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1'
                if (Test-Path -LiteralPath $freshnessLib -PathType Leaf) {
                    . $freshnessLib
                    $evEval = Test-OrchestrationDoneAllowedByEvidence -EvidenceItems $evItems -CurrentHeadSha $CurrentBaseRevision
                    if (-not [bool]$evEval.allowed) {
                        $reasons.Add('EVIDENCE_STALE_BLOCKED') | Out-Null
                    }
                }
            }
            catch { $reasons.Add('evidence-freshness-check-failed') | Out-Null }
        }

        if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
            $reasons.Add('watchdog-settlement-pending') | Out-Null
        }
    }
    catch { $reasons.Add('internal-error') | Out-Null }
    $arr = ([string[]]$reasons.ToArray())
    return [PSCustomObject]@{ complete = ($arr.Count -eq 0); reasons = $arr }
}

function Complete-OrchestrationTask {
    <#
    .SYNOPSIS
        The ONLY writer of state DONE. Fails closed with
        COMPLETION_GATE_FAILED + reasons when the gate does not pass.
        A pending watchdog interrupt without confirmed settlement fails
        closed with SETTLEMENT_REQUIRED (Phase 26 seam) before the gate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string[]]$ResidualRisks = @(),
        [switch]$AcceptEmptyResidualRisks,
        [string]$OrchestrationCompliance = '',
        [string]$ActorIdentitySource = 'unknown',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = '',
        [string]$LeasesDir = '',
        [string]$CurrentBaseRevision = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $rrClean = Get-TaskKernelCleanList -Value $ResidualRisks
        if (-not [bool]$rrClean.valid) { return (New-TaskKernelError -Code 'INVALID_RESIDUAL_RISKS') }
        $rrItems = Protect-TaskKernelStringList -Items ([string[]]$rrClean.items)
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
            return (New-TaskKernelError -Code 'SETTLEMENT_REQUIRED' -Extra @{ detail = 'watchdog interrupt engaged without confirmed settlement' })
        }
        $from = ([string]$rec['state']).Trim().ToUpperInvariant()
        if (Test-TaskKernelTerminalState -State $from) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if ($from -cne 'REVIEWING') {
            return (New-TaskKernelError -Code 'ILLEGAL_COMPLETION_STATE')
        }
        $gate = $null
        $gateArgs = @{
            TaskId = $tid; TasksDir = $TasksDir; RepoRoot = $RepoRoot
            OrchestrationCompliance = $OrchestrationCompliance; Actor = $actor
            ResidualRisks = ([string[]]$rrItems)
        }
        if ([bool]$AcceptEmptyResidualRisks) { $gateArgs['AcceptEmptyResidualRisks'] = $true }
        if ($PSBoundParameters.ContainsKey('LeasesDir')) { $gateArgs['LeasesDir'] = $LeasesDir }
        if ($PSBoundParameters.ContainsKey('CurrentBaseRevision')) { $gateArgs['CurrentBaseRevision'] = $CurrentBaseRevision }
        $gate = Test-OrchestrationTaskCompletion @gateArgs
        if (-not [bool]$gate.complete) {
            return (New-TaskKernelError -Code 'COMPLETION_GATE_FAILED' -Extra @{ reasons = ([string[]]$gate.reasons) })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $fresh = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$fresh.found -or [bool]$fresh.malformed -or ([int]$fresh.revision -ne [int]$ExpectedRevision)) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $rec = $fresh.record
        $newRev = ([int]$rec['revision'] + 1)
        $stamp = Get-TaskKernelTimestamp
        $hist = @()
        if ($null -ne $rec['history']) { $hist = @($rec['history']) }
        $hist += [ordered]@{ from = $from; to = 'DONE'; actor = $actor; at = $stamp; revision = $newRev }
        $rec['history'] = $hist
        $rec['state'] = 'DONE'
        $rec['residual_risks'] = ([string[]]$rrItems)
        $rec['compliance_verdict'] = ([string]$OrchestrationCompliance).Trim()
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $corrDone = $null
        try {
            $corrSess = ''
            $corrN = $null
            try {
                $corrRt = $rec['execution_runtime']
                if (($null -ne $corrRt) -and ($corrRt -is [System.Collections.IDictionary])) {
                    if ($null -ne $corrRt['session_id']) { $corrSess = ([string]$corrRt['session_id']).Trim() }
                    if ($null -ne $corrRt['attempt_n']) { $corrN = $corrRt['attempt_n'] }
                }
            }
            catch { $corrSess = ''; $corrN = $null }
            $corrDone = New-CorrelationEnvelope -Objective ([string]$rec['objective']) -SessionId $corrSess -AttemptN $corrN -DecisionRef ([string]$rec['orchestration_decision']) -SettlementState 'settled'
        }
        catch { $corrDone = $null }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_DONE' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot -Correlation $corrDone
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; state = 'DONE' }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationTaskStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$TasksDir = '',
        [string]$RepoRoot = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        $workerStatus = ''
        $verPassed = $false
        $revStatus = ''
        $secStatus = ''
        $rtId = ''
        $rtGen = 0
        try {
            $wrk = $rec['worker_result']
            if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary]) -and ($null -ne $wrk['status'])) {
                $workerStatus = ([string]$wrk['status']).Trim()
            }
        } catch { }
        try {
            $ver = $rec['verification']
            if (($null -ne $ver) -and ($ver -is [System.Collections.IDictionary]) -and ($null -ne $ver['passed'])) {
                $verPassed = [bool]$ver['passed']
            }
        } catch { }
        try {
            $rev = $rec['review']
            if (($null -ne $rev) -and ($rev -is [System.Collections.IDictionary]) -and ($null -ne $rev['status'])) {
                $revStatus = ([string]$rev['status']).Trim()
            }
        } catch { }
        try {
            $sec = $rec['security_review']
            if (($null -ne $sec) -and ($sec -is [System.Collections.IDictionary]) -and ($null -ne $sec['status'])) {
                $secStatus = ([string]$sec['status']).Trim()
            }
        } catch { }
        try {
            $rt = $rec['runtime']
            if (($null -ne $rt) -and ($rt -is [System.Collections.IDictionary])) {
                if ($null -ne $rt['id']) { $rtId = ([string]$rt['id']).Trim() }
                if ($null -ne $rt['generation']) { $rtGen = [int]$rt['generation'] }
            }
        } catch { }
        $blockerCount = 0
        $attemptCount = 0
        try { if ($null -ne $rec['blockers']) { $blockerCount = (@($rec['blockers'])).Count } } catch { }
        try { if ($null -ne $rec['attempts']) { $attemptCount = (@($rec['attempts'])).Count } } catch { }
        return [PSCustomObject]@{
            task_id              = ([string]$rec['task_id'])
            state                = ([string]$rec['state'])
            revision             = ([int]$rec['revision'])
            actor                = ([string]$rec['actor'])
            current_owner        = ([string]$rec['current_owner'])
            runtime_id           = $rtId
            runtime_generation   = $rtGen
            worker_status        = $workerStatus
            verification_passed  = $verPassed
            review_status        = $revStatus
            security_review      = $secStatus
            blockers_count       = $blockerCount
            attempts             = $attemptCount
            attempt_budget       = ([int]$rec['attempt_budget'])
            updated_at           = ([string]$rec['updated_at'])
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

# ---------- execution budgets (Phase 23, shadow record-only) ----------

function Get-OrchestrationTaskBudget {
    <#
    .SYNOPSIS
        Reads the canonical execution_budget. Old records without one get
        a safely derived default (read-only, never writes). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$BudgetPolicyPath = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        $stored = $null
        try {
            if ($rec -is [System.Collections.IDictionary]) {
                if ($rec.Contains('execution_budget')) { $stored = $rec['execution_budget'] }
            }
        }
        catch { $stored = $null }
        if ($null -ne $stored) {
            $check = Test-ExecutionBudgetObject -Budget $stored
            if ([bool]$check.valid) {
                return [PSCustomObject]@{ ok = $true; task_id = $tid; profile = ([string]$stored['profile']); budget = $stored; derived = $false }
            }
        }
        $pp = $BudgetPolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        $d = Get-ExecutionBudgetDerivedDefault -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$d.ok) { return $d }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; profile = ([string]$d.profile); budget = $d.budget; derived = $true }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Test-TaskKernelStartRequestEquivalent {
    <#
    .SYNOPSIS
        FIX3: true only when the caller request is effectively identical
        to the persisted attempt binding: same session/role/attempt_n
        plus same effective strategy fingerprint (omitted inherits the
        last attempt fingerprint, same rule as the gate), strategy id,
        hypothesis and evidence-ref set, all normalized with trim (and
        the same Protect pipeline used at bind time). Resolve or
        evidence-list failure returns false so the caller falls through
        to the gate for the structured error. Never throws.
    #>
    [CmdletBinding()]
    param(
        $Record,
        [string]$SessionId = '',
        [string]$Role = '',
        [string]$StrategyFingerprint = '',
        [string]$StrategyApproach = '',
        [string]$StrategyTool = '',
        $StrategyParams = @(),
        [string]$StrategyId = '',
        [string]$AttemptHypothesis = '',
        $NewEvidenceRefs = $null
    )
    try {
        $sid = ([string]$SessionId).Trim()
        $role = ([string]$Role).Trim()
        if ([string]::IsNullOrWhiteSpace($sid)) { return $false }
        if ([string]::IsNullOrWhiteSpace($role)) { return $false }
        if (($null -eq $Record) -or (-not ($Record -is [System.Collections.IDictionary]))) { return $false }
        $attCount = 0
        try { if ($null -ne $Record['attempts']) { $attCount = (@($Record['attempts'])).Count } } catch { $attCount = 0 }
        $nextN = ($attCount + 1)
        if ($nextN -lt 1) { $nextN = 1 }
        $rt = $null
        try {
            if ($Record.Contains('execution_runtime')) { $rt = $Record['execution_runtime'] }
        }
        catch { $rt = $null }
        if (($null -eq $rt) -or (-not ($rt -is [System.Collections.IDictionary]))) { return $false }
        $bSess = ''
        $bRole = ''
        $bN = 0
        try {
            if ($null -ne $rt['session_id']) { $bSess = ([string]$rt['session_id']).Trim() }
            if ($null -ne $rt['attempt_role']) { $bRole = ([string]$rt['attempt_role']).Trim() }
            if ($null -ne $rt['attempt_n']) { $bN = [int]$rt['attempt_n'] }
        }
        catch { return $false }
        if ([string]::IsNullOrWhiteSpace($bSess)) { return $false }
        if (($bN -ne $nextN) -or ($bN -le 0)) { return $false }
        if (($bSess -cne $sid) -or ($bRole -cne $role)) { return $false }
        $rs = Resolve-TaskKernelStrategyFingerprint -Explicit $StrategyFingerprint -Approach $StrategyApproach -ToolOrPath $StrategyTool -KeyParams $StrategyParams
        if (($null -eq $rs) -or (-not [bool]$rs.ok)) { return $false }
        $inFp = ([string]$rs.fingerprint)
        $lastFp = ''
        $lastSid = ''
        try {
            if ($attCount -gt 0) {
                $la = (@($Record['attempts']))[$attCount - 1]
                $lastFp = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $la -Name 'strategy_fingerprint'))
                $lsx = Get-TaskKernelAttemptField -Attempt $la -Name 'strategy_id'
                if ($null -ne $lsx) { $lastSid = ([string]$lsx).Trim() }
            }
        }
        catch { }
        $effFp = $inFp
        if ([string]::IsNullOrWhiteSpace($effFp)) { $effFp = $lastFp }
        $effSid = (([string]$StrategyId).Trim())
        if ([string]::IsNullOrWhiteSpace($effSid) -and (-not [string]::IsNullOrWhiteSpace($effFp)) -and ($effFp -ceq $lastFp)) { $effSid = $lastSid }
        $effHyp = (([string]$AttemptHypothesis).Trim())
        $rl = Get-TaskKernelEvidenceList -Value $NewEvidenceRefs
        if (($null -eq $rl) -or (-not [bool]$rl.valid)) { return $false }
        $effEv = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($e in @($rl.items)) {
                if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) {
                    $t = (Protect-TaskKernelText -Text ([string]$e)).Trim()
                    if ((-not [string]::IsNullOrWhiteSpace($t)) -and (-not $effEv.Contains($t))) { $effEv.Add($t) | Out-Null }
                }
            }
        }
        catch { return $false }
        $ge = $null
        try {
            if ($null -ne $rt['gate_evidence']) { $ge = $rt['gate_evidence'] }
        }
        catch { $ge = $null }
        $bFp = ''
        $bSid = ''
        $bHyp = ''
        $bEv = New-Object System.Collections.Generic.List[string]
        try {
            if (($null -ne $ge) -and ($ge -is [System.Collections.IDictionary])) {
                if ($ge.Contains('strategy_fingerprint') -and ($null -ne $ge['strategy_fingerprint'])) { $bFp = ConvertTo-TaskKernelFingerprint -Value ([string]$ge['strategy_fingerprint']) }
                if ($ge.Contains('strategy_id') -and ($null -ne $ge['strategy_id'])) { $bSid = ([string]$ge['strategy_id']).Trim() }
                if ($ge.Contains('hypothesis') -and ($null -ne $ge['hypothesis'])) { $bHyp = ([string]$ge['hypothesis']).Trim() }
                if ($ge.Contains('new_evidence_refs') -and ($null -ne $ge['new_evidence_refs'])) {
                    foreach ($e in @($ge['new_evidence_refs'])) {
                        if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) {
                            $t = ([string]$e).Trim()
                            if (-not $bEv.Contains($t)) { $bEv.Add($t) | Out-Null }
                        }
                    }
                }
            }
        }
        catch { return $false }
        if ($bFp -cne $effFp) { return $false }
        if ($bSid -cne (Protect-TaskKernelText -Text $effSid)) { return $false }
        if ($bHyp -cne (Protect-TaskKernelText -Text $effHyp)) { return $false }
        if ($bEv.Count -ne $effEv.Count) { return $false }
        foreach ($e in $effEv.ToArray()) {
            if (-not $bEv.Contains($e)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Start-OrchestrationTaskAttempt {
    <#
    .SYNOPSIS
        Initializes execution_runtime on active start (CAS + lock + trusted
        planner/build actor). Phase 23 shadow record-only: no enforcement.
        Budget snapshot is kernel-resolved (explicit or legacy stored budget
        retained; derived/provisional default resolves from AttemptRole;
        absent budget defaults to role), never caller-supplied. Requires
        state IMPLEMENTING. A retry-blocked attempt (debugger_required /
        requires_new_evidence on the last kernel attempt) is rejected
        (ATTEMPT_GATE_FAILED, no markers written) UNLESS the planner
        supplies BOTH -DebuggerEvidenceRefs (debugger trace) AND
        -NewEvidenceRefs (novelty evidence): non-empty, validated with the
        existing evidence-list helper and sanitized, recorded as
        planner-attested gate evidence bound to the next attempt number
        under the same CAS+lock snapshot. A debugger-role actor can never
        start attempts (planner/build only), so debugger output cannot
        self-approve. Same attempt_n + same session/role + identical
        effective request (strategy fingerprint with lastFp inheritance,
        strategy id, hypothesis, evidence refs, all normalized) is
        idempotent (no deadline extension, no write); same session/role
        with divergent params falls through to the gate (rejected or
        re-authorized, never ambiguous success); same attempt_n with a
        different session is rejected. Deadline assigned exactly once
        per attempt_n. Strategy index has no runtime source: HOLD
        documented (attempt_role recorded; no invented strategy).
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$AttemptRole,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$ActorIdentitySource = 'unknown',
        [string[]]$DebuggerEvidenceRefs = @(),
        [string[]]$NewEvidenceRefs = @(),
        [string]$StrategyId = '',
        [string]$StrategyApproach = '',
        [string]$StrategyTool = '',
        [string[]]$StrategyParams = @(),
        [string]$StrategyFingerprint = '',
        [string]$AttemptHypothesis = '',
        [string]$BudgetPolicyPath = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $role = ([string]$AttemptRole).Trim()
        if ([string]::IsNullOrWhiteSpace($role)) {
            return (New-TaskKernelError -Code 'INVALID_ROLE')
        }
        $sid = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($sid)) {
            return (New-TaskKernelError -Code 'INVALID_SESSION')
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $actorLow = $actor.ToLowerInvariant()
        if (($actorLow -cne 'planner') -and ($actorLow -cne 'build')) {
            return (New-TaskKernelError -Code 'BUDGET_WIDEN_DENIED' -Extra @{ detail = 'attempt start is planner/build only (trusted administrative boundary)' })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        $curState = ([string]$rec['state']).Trim().ToUpperInvariant()
        if ($curState -cne 'IMPLEMENTING') {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'attempt start requires IMPLEMENTING' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        # S5 CLOSE: a settlement confirmed with disposition CLOSE ends
        # the task without retry. Any later attempt start is rejected
        # here, before idempotency and before the ATTEMPT_GATE, so the
        # task can only be released/completed afterwards. RETRY
        # settlements (and records predating dispositions) flow through
        # unchanged. Fail-closed: a present-but-malformed node (non-dict,
        # missing/non-bool engaged/settled, inspection exception) blocks
        # with WATCHDOG_CLOSED_NO_RETRY instead of reading as not-closed.
        # Absent/null-free record (no watchdog_interrupt key) allows.
        # Never throws.
        try {
            $hasWdKey = $false
            try { $hasWdKey = $rec.Contains('watchdog_interrupt') } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: key inspection failed' }) }
            if ([bool]$hasWdKey) {
                $closeNode = $null
                try { $closeNode = $rec['watchdog_interrupt'] } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: node inspection failed' }) }
                if ($null -eq $closeNode) {
                    return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: malformed node' })
                }
                    if (-not ($closeNode -is [System.Collections.IDictionary])) {
                        return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: malformed node' })
                    }
                    $hasEng = $false
                    $hasSet = $false
                    try { $hasEng = $closeNode.Contains('engaged') } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: engaged inspection failed' }) }
                    try { $hasSet = $closeNode.Contains('settled') } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: settled inspection failed' }) }
                    if ((-not [bool]$hasEng) -or (-not [bool]$hasSet)) {
                        return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: malformed node' })
                    }
                    $rawEng = $null
                    $rawSet = $null
                    try { $rawEng = $closeNode['engaged'] } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: engaged read failed' }) }
                    try { $rawSet = $closeNode['settled'] } catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: settled read failed' }) }
                    if ((-not ($rawEng -is [bool])) -or (-not ($rawSet -is [bool]))) {
                        return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: malformed flags' })
                    }
                    $closeEngaged = [bool]$rawEng
                    $closeSettled = [bool]$rawSet
                    $closeDisp = ''
                    try {
                        if ($null -ne $closeNode['settled_disposition']) {
                            $closeDisp = ([string]$closeNode['settled_disposition']).Trim().ToLowerInvariant()
                        }
                    }
                    catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed: disposition read failed' }) }
                    if (([bool]$closeEngaged) -and ([bool]$closeSettled) -and ($closeDisp -ceq 'close')) {
                        return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog settlement closed without retry; no further attempts' })
                    }
            }
        }
        catch { return (New-TaskKernelError -Code 'WATCHDOG_CLOSED_NO_RETRY' -Extra @{ detail = 'watchdog close gate fail-closed' }) }
        $pp = $BudgetPolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        try {
            $idemNextN = 1
            if ($null -ne $rec['attempts']) { $idemNextN = (@($rec['attempts'])).Count + 1 }
            if ($idemNextN -lt 1) { $idemNextN = 1 }
            $idemRt = $null
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('execution_runtime')) { $idemRt = $rec['execution_runtime'] }
            $idemSess = ''
            $idemRole = ''
            $idemN = 0
            $idemDeadline = ''
            $idemProf = ''
            if (($null -ne $idemRt) -and ($idemRt -is [System.Collections.IDictionary])) {
                if ($null -ne $idemRt['session_id']) { $idemSess = ([string]$idemRt['session_id']).Trim() }
                if ($null -ne $idemRt['attempt_role']) { $idemRole = ([string]$idemRt['attempt_role']).Trim() }
                if ($null -ne $idemRt['attempt_n']) { $idemN = [int]$idemRt['attempt_n'] }
                if ($null -ne $idemRt['deadline_at']) { $idemDeadline = ([string]$idemRt['deadline_at']).Trim() }
                try {
                    if (($null -ne $idemRt['budget_snapshot']) -and ($idemRt['budget_snapshot'] -is [System.Collections.IDictionary]) -and ($null -ne $idemRt['budget_snapshot']['profile'])) { $idemProf = ([string]$idemRt['budget_snapshot']['profile']) }
                }
                catch { $idemProf = '' }
            }
            if ((-not [string]::IsNullOrWhiteSpace($idemSess)) -and ($idemN -eq $idemNextN) -and ($idemN -gt 0) -and ($idemSess -ceq $sid) -and ($idemRole -ceq $role) -and (Test-TaskKernelStartRequestEquivalent -Record $rec -SessionId $sid -Role $role -StrategyFingerprint $StrategyFingerprint -StrategyApproach $StrategyApproach -StrategyTool $StrategyTool -StrategyParams $StrategyParams -StrategyId $StrategyId -AttemptHypothesis $AttemptHypothesis -NewEvidenceRefs $NewEvidenceRefs)) {
                return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = ([int]$rec['revision']); profile = $idemProf; deadline_at = $idemDeadline; idempotent = $true }
            }
        }
        catch { }
        $gateEvidence = $null
        $skipLegacyGate = $false
        $p27GateExt = $null
        $p27Start = Resolve-TaskKernelStrategyFingerprint -Explicit $StrategyFingerprint -Approach $StrategyApproach -ToolOrPath $StrategyTool -KeyParams $StrategyParams
        if (-not [bool]$p27Start.ok) {
            return (New-TaskKernelError -Code ([string]$p27Start.error))
        }
        $inFp = ([string]$p27Start.fingerprint)
        $p27Prior = @()
        if ($null -ne $rec['attempts']) { $p27Prior = @($rec['attempts']) }
        $lastFp = ''
        $lastHyp = ''
        $lastSid = ''
        $lastDbgReq = $false
        if ($p27Prior.Count -gt 0) {
            $p27Last = $p27Prior[$p27Prior.Count - 1]
            $lastFp = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $p27Last -Name 'strategy_fingerprint'))
            try {
                $lh = Get-TaskKernelAttemptField -Attempt $p27Last -Name 'hypothesis'
                if ($null -ne $lh) { $lastHyp = ([string]$lh) }
            }
            catch { }
            try {
                $ls = Get-TaskKernelAttemptField -Attempt $p27Last -Name 'strategy_id'
                if ($null -ne $ls) { $lastSid = ([string]$ls).Trim() }
            }
            catch { }
            try {
                if ($p27Last -is [System.Collections.IDictionary]) {
                    if ($null -ne $p27Last['debugger_required']) { $lastDbgReq = [bool]$p27Last['debugger_required'] }
                }
            }
            catch { }
        }
        $p27Aware = ((-not [string]::IsNullOrWhiteSpace($lastFp)) -or (-not [string]::IsNullOrWhiteSpace($inFp)))
        if ($p27Aware) {
            $p27DbgRefs = @()
            try {
                $p27dl = Get-TaskKernelEvidenceList -Value $DebuggerEvidenceRefs
                if ([bool]$p27dl.valid) { $p27DbgRefs = @($p27dl.items) }
            }
            catch { $p27DbgRefs = @() }
            $p27EvRefs = @()
            try {
                $p27nl = Get-TaskKernelEvidenceList -Value $NewEvidenceRefs
                if ([bool]$p27nl.valid) { $p27EvRefs = @($p27nl.items) }
            }
            catch { $p27EvRefs = @() }
            $p27DbgOk = ((@($p27DbgRefs)).Count -gt 0)
            $p27Seen = New-Object System.Collections.Generic.List[string]
            try {
                foreach ($pa in @($p27Prior)) {
                    $pr = Get-TaskKernelAttemptField -Attempt $pa -Name 'new_evidence_refs'
                    foreach ($e in @($pr)) {
                        if (($null -ne $e) -and (-not [string]::IsNullOrWhiteSpace([string]$e))) {
                            $refId = ([string]$e).Trim()
                            if (-not $p27Seen.Contains($refId)) { $p27Seen.Add($refId) | Out-Null }
                        }
                    }
                }
                try {
                    if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('consumed_evidence_refs') -and ($null -ne $rec['consumed_evidence_refs'])) {
                        foreach ($ce in @($rec['consumed_evidence_refs'])) {
                            if (($null -ne $ce) -and (-not [string]::IsNullOrWhiteSpace([string]$ce))) {
                                $crefId = ([string]$ce).Trim()
                                if (-not $p27Seen.Contains($crefId)) { $p27Seen.Add($crefId) | Out-Null }
                            }
                        }
                    }
                }
                catch { }
            }
            catch { }
            $p27EvNovel = $false
            foreach ($e in @($p27EvRefs)) {
                $nid = ([string]$e).Trim()
                if ((-not [string]::IsNullOrWhiteSpace($nid)) -and (-not $p27Seen.Contains($nid))) { $p27EvNovel = $true }
            }
            $p27HypBound = (-not [string]::IsNullOrWhiteSpace(([string]$AttemptHypothesis).Trim()))
            $p27HypNovel = ($p27HypBound -and ((Get-TaskKernelCanonicalText -Text ([string]$AttemptHypothesis)) -cne (Get-TaskKernelCanonicalText -Text $lastHyp)))
            $p27StratNovel = ((-not [string]::IsNullOrWhiteSpace($inFp)) -and (([string]::IsNullOrWhiteSpace($lastFp)) -or ($inFp -cne $lastFp)))
            $p27Novelty = ([bool]$p27EvNovel -or [bool]$p27HypNovel -or [bool]$p27StratNovel)
            $p27NextN = ($p27Prior.Count + 1)
            if ((-not $p27Novelty) -and ($p27NextN -ge 3)) {
                if (-not (Test-TaskKernelWatchdogSettlementClear -Record $rec)) {
                    return (New-TaskKernelError -Code 'SETTLEMENT_REQUIRED' -Extra @{ detail = 'watchdog interrupt engaged without confirmed settlement' })
                }
                $p27Stamp = Get-TaskKernelTimestamp
                $p27Rev = ([int]$rec['revision'] + 1)
                $p27Hist = @()
                if ($null -ne $rec['history']) { $p27Hist = @($rec['history']) }
                $p27Hist += [ordered]@{
                    from     = $curState
                    to       = 'EXHAUSTED'
                    actor    = 'task-kernel'
                    at       = $p27Stamp
                    revision = $p27Rev
                }
                $rec['history'] = $p27Hist
                $rec['state'] = 'EXHAUSTED'
                $rec['revision'] = $p27Rev
                $rec['updated_at'] = (Get-TaskKernelTimestamp)
                $p27wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
                if (-not [bool]$p27wr.ok) {
                    return (New-TaskKernelError -Code ([string]$p27wr.error))
                }
                $null = Send-TaskKernelTelemetry -EventType 'TASK_EXHAUSTED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
                return (New-TaskKernelError -Code 'EXHAUSTED' -Extra @{ task_id = $tid; revision = $p27Rev; attempted_n = $p27NextN })
            }
            if ($lastDbgReq -and (-not $p27DbgOk)) {
                return (New-TaskKernelError -Code 'DEBUGGER_REQUIRED' -Extra @{ reason = 'second material failure requires debugger trace'; attempt_n = $p27NextN })
            }
            if (-not $p27Novelty) {
                return (New-TaskKernelError -Code 'STALLED_STRATEGY_REJECTED' -Extra @{ reason = 'same strategy without new evidence or hypothesis'; attempt_n = $p27NextN })
            }
            $skipLegacyGate = $true
            $effInFp = $inFp
            if ([string]::IsNullOrWhiteSpace($effInFp)) { $effInFp = $lastFp }
            $effStratId = (([string]$StrategyId).Trim())
            if ([string]::IsNullOrWhiteSpace($effStratId) -and (-not [string]::IsNullOrWhiteSpace($effInFp)) -and ($effInFp -ceq $lastFp)) { $effStratId = $lastSid }
            $p27GateExt = [ordered]@{
                debugger_refs        = ([string[]](Protect-TaskKernelStringList -Items ([string[]]@($p27DbgRefs))))
                new_evidence_refs    = ([string[]](Protect-TaskKernelStringList -Items ([string[]]@($p27EvRefs))))
                strategy_id          = (Protect-TaskKernelText -Text $effStratId)
                strategy_fingerprint = $effInFp
                hypothesis           = (Protect-TaskKernelText -Text (([string]$AttemptHypothesis).Trim()))
            }
        }
        if (-not $skipLegacyGate) {
        try {
            $prior = @()
            if ($null -ne $rec['attempts']) { $prior = @($rec['attempts']) }
            if ($prior.Count -gt 0) {
                $last = $prior[$prior.Count - 1]
                $needDbg = $false
                $needEv = $false
                try {
                    if ($last -is [System.Collections.IDictionary]) {
                        if ($null -ne $last['debugger_required']) { $needDbg = [bool]$last['debugger_required'] }
                        if ($null -ne $last['requires_new_evidence']) { $needEv = [bool]$last['requires_new_evidence'] }
                    }
                }
                catch { }
                if ($needDbg -or $needEv) {
                    $dbgOk = $false
                    $evOk = $false
                    $dbgItems = @()
                    $evItems = @()
                    if ($needDbg) {
                        if ($PSBoundParameters.ContainsKey('DebuggerEvidenceRefs')) {
                            $dl = Get-TaskKernelEvidenceList -Value $DebuggerEvidenceRefs
                            if ([bool]$dl.valid -and (@($dl.items)).Count -gt 0) {
                                $dbgItems = Protect-TaskKernelStringList -Items ([string[]]$dl.items)
                                if ((@($dbgItems)).Count -gt 0) { $dbgOk = $true }
                            }
                        }
                    }
                    else { $dbgOk = $true }
                    if ($needEv) {
                        if ($PSBoundParameters.ContainsKey('NewEvidenceRefs')) {
                            $nl = Get-TaskKernelEvidenceList -Value $NewEvidenceRefs
                            if ([bool]$nl.valid -and (@($nl.items)).Count -gt 0) {
                                $evItems = Protect-TaskKernelStringList -Items ([string[]]$nl.items)
                                if ((@($evItems)).Count -gt 0) { $evOk = $true }
                            }
                        }
                    }
                    else { $evOk = $true }
                    if (-not ($dbgOk -and $evOk)) {
                        return (New-TaskKernelError -Code 'ATTEMPT_GATE_FAILED' -Extra @{ reason = 'retry gate blocked: planner must supply debugger trace AND novelty evidence refs' })
                    }
                    $gateEvidence = [ordered]@{
                        debugger_refs    = ([string[]]$dbgItems)
                        new_evidence_refs = ([string[]]$evItems)
                    }
                }
            }
        }
        catch { }
        }
        $nextN = 1
        try {
            if ($null -ne $rec['attempts']) { $nextN = (@($rec['attempts'])).Count + 1 }
        } catch { $nextN = 1 }
        if ($nextN -lt 1) { $nextN = 1 }
        $curRt = $null
        try {
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('execution_runtime')) { $curRt = $rec['execution_runtime'] }
        }
        catch { $curRt = $null }
        $curSess = ''
        $curRole = ''
        $curN = 0
        $curDeadline = ''
        try {
            if (($null -ne $curRt) -and ($curRt -is [System.Collections.IDictionary])) {
                if ($null -ne $curRt['session_id']) { $curSess = ([string]$curRt['session_id']).Trim() }
                if ($null -ne $curRt['attempt_role']) { $curRole = ([string]$curRt['attempt_role']).Trim() }
                if ($null -ne $curRt['attempt_n']) { $curN = [int]$curRt['attempt_n'] }
                if ($null -ne $curRt['deadline_at']) { $curDeadline = ([string]$curRt['deadline_at']).Trim() }
            }
        }
        catch { }
        if ((-not [string]::IsNullOrWhiteSpace($curSess)) -and ($curN -eq $nextN) -and ($curN -gt 0)) {
            $sameBinding = (($curSess -ceq $sid) -and ($curRole -ceq $role))
            if ($sameBinding -and (Test-TaskKernelStartRequestEquivalent -Record $rec -SessionId $sid -Role $role -StrategyFingerprint $StrategyFingerprint -StrategyApproach $StrategyApproach -StrategyTool $StrategyTool -StrategyParams $StrategyParams -StrategyId $StrategyId -AttemptHypothesis $AttemptHypothesis -NewEvidenceRefs $NewEvidenceRefs)) {
                return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = ([int]$rec['revision']); profile = ([string]$curRt['budget_snapshot']['profile']); deadline_at = $curDeadline; idempotent = $true }
            }
            if (-not $sameBinding) {
                return (New-TaskKernelError -Code 'SESSION_MISMATCH' -Extra @{ detail = 'attempt already bound to a different session; deadline assigned once per attempt' })
            }
        }
        $snap = $null
        $profName = ''
        $src = ''
        try {
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('execution_budget_source')) { $src = ([string]$rec['execution_budget_source']).Trim().ToLowerInvariant() }
        }
        catch { $src = '' }
        $storedValid = $null
        try {
            $stored = $null
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('execution_budget')) { $stored = $rec['execution_budget'] }
            if ($null -ne $stored) {
                $chk = Test-ExecutionBudgetObject -Budget $stored
                if ([bool]$chk.valid) { $storedValid = $stored }
            }
        }
        catch { $storedValid = $null }
        if (($null -ne $storedValid) -and (($src -ceq 'explicit') -or [string]::IsNullOrWhiteSpace($src))) {
            $snap = $storedValid
        }
        else {
            $rb = Get-ExecutionBudgetForRole -Role $role -PolicyPath $pp -RepoRoot $RepoRoot
            if ([bool]$rb.ok) { $snap = $rb.budget }
            elseif ($null -ne $storedValid) { $snap = $storedValid }
            else {
                $d = Get-ExecutionBudgetDerivedDefault -PolicyPath $pp -RepoRoot $RepoRoot
                if (-not [bool]$d.ok) { return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID') }
                $snap = $d.budget
            }
        }
        try { $profName = ([string]$snap['profile']).Trim() } catch { $profName = '' }
        $snapshot = [ordered]@{
            profile                    = $profName
            step_budget                = [int]$snap['step_budget']
            wall_clock_seconds         = [int]$snap['wall_clock_seconds']
            no_progress_seconds        = [int]$snap['no_progress_seconds']
            repeated_action_soft_limit = [int]$snap['repeated_action_soft_limit']
            repeated_action_hard_limit = [int]$snap['repeated_action_hard_limit']
            cycle_repeat_limit         = [int]$snap['cycle_repeat_limit']
            provider_retry_limit       = [int]$snap['provider_retry_limit']
        }
        $now = (Get-Date).ToUniversalTime()
        $startText = $now.ToString('o')
        $deadlineText = ($now.AddSeconds([double][int]$snap['wall_clock_seconds'])).ToString('o')
        $newRev = ([int]$rec['revision'] + 1)
        $effGate = $gateEvidence
        if ($null -ne $p27GateExt) { $effGate = $p27GateExt }
        try {
            $toConsume = @()
            if (($null -ne $effGate) -and ($effGate -is [System.Collections.IDictionary]) -and ($null -ne $effGate['new_evidence_refs'])) { $toConsume = @($effGate['new_evidence_refs']) }
            if ((@($toConsume)).Count -gt 0) {
                $merged = New-Object System.Collections.Generic.List[string]
                try {
                    if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('consumed_evidence_refs') -and ($null -ne $rec['consumed_evidence_refs'])) {
                        foreach ($ce in @($rec['consumed_evidence_refs'])) {
                            if (($null -ne $ce) -and (-not [string]::IsNullOrWhiteSpace([string]$ce))) {
                                $cid = ([string]$ce).Trim()
                                if (-not $merged.Contains($cid)) { $merged.Add($cid) | Out-Null }
                            }
                        }
                    }
                }
                catch { }
                foreach ($ne in @($toConsume)) {
                    if (($null -ne $ne) -and (-not [string]::IsNullOrWhiteSpace([string]$ne))) {
                        $nid2 = ([string]$ne).Trim()
                        if (-not $merged.Contains($nid2)) { $merged.Add($nid2) | Out-Null }
                    }
                }
                $rec['consumed_evidence_refs'] = ([string[]]$merged)
            }
        }
        catch { }
        $rec['execution_runtime'] = [ordered]@{
            session_id             = (Protect-TaskKernelText -Text $sid)
            started_at             = $startText
            deadline_at            = $deadlineText
            last_progress_at       = $startText
            last_progress_revision = $newRev
            attempt_role           = (Protect-TaskKernelText -Text $role)
            attempt_n              = [int]$nextN
            gate_evidence          = $effGate
            budget_snapshot        = $snapshot
        }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_STATE_CHANGED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; profile = $profName; deadline_at = $deadlineText }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Set-OrchestrationTaskBudget {
    <#
    .SYNOPSIS
        Planner/kernel-only PARTIAL budget update within explicit policy
        bounds. Raw values preserved (no [int] coercion): each supplied
        numeric must be an exact integral type (int/long), else INVALID_BUDGET
        with no mutation. Absence detected via PSBoundParameters (no 0/-1
        sentinel). Without an explicit -BudgetProfile the current valid
        stored budget is preserved (no canonical reset). Workers denied
        (BUDGET_WIDEN_DENIED). CAS + lock + trusted actor. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$BudgetProfile = '',
        $BudgetStepBudget = $null,
        $BudgetWallSeconds = $null,
        $BudgetNoProgressSeconds = $null,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$ActorIdentitySource = 'unknown',
        [string]$BudgetPolicyPath = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $actorLow = $actor.ToLowerInvariant()
        if (($actorLow -cne 'planner') -and ($actorLow -cne 'build')) {
            return (New-TaskKernelError -Code 'BUDGET_WIDEN_DENIED' -Extra @{ detail = 'budget override is planner/kernel only' })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $pp = $BudgetPolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        $profileExplicit = ($PSBoundParameters.ContainsKey('BudgetProfile') -and (-not [string]::IsNullOrWhiteSpace([string]$BudgetProfile)))
        $baseProf = ([string]$BudgetProfile).Trim().ToLowerInvariant()
        $curStored = $null
        try {
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('execution_budget')) { $curStored = $rec['execution_budget'] }
        }
        catch { $curStored = $null }
        $curValid = $null
        try {
            if ($null -ne $curStored) {
                $chk0 = Test-ExecutionBudgetObject -Budget $curStored
                if ([bool]$chk0.valid) { $curValid = $curStored }
            }
        }
        catch { $curValid = $null }
        if ($profileExplicit) {
            if ([string]::IsNullOrWhiteSpace((Get-ExecutionBudgetProfileName -Profile $baseProf))) {
                return (New-TaskKernelError -Code 'INVALID_BUDGET')
            }
        }
        elseif ($null -ne $curValid) {
            $baseProf = ([string]$curValid['profile']).Trim().ToLowerInvariant()
        }
        else {
            if ([string]::IsNullOrWhiteSpace($baseProf)) { $baseProf = 'standard-write' }
        }
        $base = Get-ExecutionBudgetProfileBudget -Profile $baseProf -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$base.ok) {
            return (New-TaskKernelError -Code 'INVALID_BUDGET')
        }
        if ($profileExplicit) {
            $cand = [ordered]@{
                profile                    = ([string]$base.budget['profile'])
                step_budget                = [int]$base.budget['step_budget']
                wall_clock_seconds         = [int]$base.budget['wall_clock_seconds']
                no_progress_seconds        = [int]$base.budget['no_progress_seconds']
                repeated_action_soft_limit = [int]$base.budget['repeated_action_soft_limit']
                repeated_action_hard_limit = [int]$base.budget['repeated_action_hard_limit']
                cycle_repeat_limit         = [int]$base.budget['cycle_repeat_limit']
                provider_retry_limit       = [int]$base.budget['provider_retry_limit']
            }
        }
        elseif ($null -ne $curValid) {
            $cand = [ordered]@{
                profile                    = ([string]$curValid['profile'])
                step_budget                = [int]$curValid['step_budget']
                wall_clock_seconds         = [int]$curValid['wall_clock_seconds']
                no_progress_seconds        = [int]$curValid['no_progress_seconds']
                repeated_action_soft_limit = [int]$curValid['repeated_action_soft_limit']
                repeated_action_hard_limit = [int]$curValid['repeated_action_hard_limit']
                cycle_repeat_limit         = [int]$curValid['cycle_repeat_limit']
                provider_retry_limit       = [int]$curValid['provider_retry_limit']
            }
        }
        else {
            $cand = [ordered]@{
                profile                    = ([string]$base.budget['profile'])
                step_budget                = [int]$base.budget['step_budget']
                wall_clock_seconds         = [int]$base.budget['wall_clock_seconds']
                no_progress_seconds        = [int]$base.budget['no_progress_seconds']
                repeated_action_soft_limit = [int]$base.budget['repeated_action_soft_limit']
                repeated_action_hard_limit = [int]$base.budget['repeated_action_hard_limit']
                cycle_repeat_limit         = [int]$base.budget['cycle_repeat_limit']
                provider_retry_limit       = [int]$base.budget['provider_retry_limit']
            }
        }
        if ($PSBoundParameters.ContainsKey('BudgetStepBudget')) {
            if (-not (Test-ExecutionBudgetInt -Value $BudgetStepBudget -Min 1 -Max 86400)) {
                return (New-TaskKernelError -Code 'INVALID_BUDGET')
            }
            $cand['step_budget'] = [int]$BudgetStepBudget
        }
        if ($PSBoundParameters.ContainsKey('BudgetWallSeconds')) {
            if (-not (Test-ExecutionBudgetInt -Value $BudgetWallSeconds -Min 1 -Max 86400)) {
                return (New-TaskKernelError -Code 'INVALID_BUDGET')
            }
            $cand['wall_clock_seconds'] = [int]$BudgetWallSeconds
        }
        if ($PSBoundParameters.ContainsKey('BudgetNoProgressSeconds')) {
            if (-not (Test-ExecutionBudgetInt -Value $BudgetNoProgressSeconds -Min 1 -Max 86400)) {
                return (New-TaskKernelError -Code 'INVALID_BUDGET')
            }
            $cand['no_progress_seconds'] = [int]$BudgetNoProgressSeconds
        }
        $isPlanner = ([string]$cand['profile'] -ceq 'planner-turn')
        $ov = Test-ExecutionBudgetOverride -Budget $cand -IsPlannerTurn:$isPlanner -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$ov.valid) {
            return (New-TaskKernelError -Code 'INVALID_BUDGET' -Extra @{ reasons = ([string[]]$ov.errors) })
        }
        $newRev = ([int]$rec['revision'] + 1)
        $rec['execution_budget'] = $cand
        $rec['execution_budget_source'] = 'explicit'
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_STATE_CHANGED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; profile = ([string]$cand['profile']) }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Start-OrchestrationPlannerTurn {
    <#
    .SYNOPSIS
        Starts a new planner turn on a trusted administrative boundary event
        (NEW turn id + NEW event id + strictly increasing task-bound sequence).
        Phase 23 shadow record-only. The -UserInputSignal parameter carries an
        event identity (compat name), NOT free-text proof: it must be a
        closed-charset id and is rejected otherwise (no secret stdout;
        sanitized ids only). -UserInputSequence is mandatory: an exact
        integral type (int/long, never bool/string/fraction), strictly
        positive and strictly greater than the persisted task-bound
        high-water mark (old records without one start at 0). Any sequence
        replay (<= high-water) is rejected without mutation, regardless of
        bounded history retention: the high-water mark (single integer,
        CAS+lock guarded) closes the evicted-history replay gap. Reuse of
        ANY previous turn id and replay of ANY retained event id are also
        rejected. Bounded history (last 20, each entry with its seq) is
        retained for audit only. Actor trust is the explicit administrative
        CLI boundary (planner/build + trusted identity source); it does not
        prove runtime auth. CAS + lock + planner/build + trusted source.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$UserInputSignal = '',
        $UserInputSequence = $null,
        [string]$ActorIdentitySource = 'unknown',
        [string]$BudgetPolicyPath = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $turn = ([string]$TurnId).Trim()
        if (-not (Test-ExecutionBudgetEventId -Value $turn)) {
            return (New-TaskKernelError -Code 'INVALID_TURN')
        }
        $signal = ([string]$UserInputSignal).Trim()
        if ([string]::IsNullOrWhiteSpace($signal)) {
            return (New-TaskKernelError -Code 'PLANNER_TURN_SIGNAL_REQUIRED' -Extra @{ detail = 'new user input signal starts a new turn' })
        }
        if (-not (Test-ExecutionBudgetEventId -Value $signal)) {
            return (New-TaskKernelError -Code 'INVALID_SIGNAL' -Extra @{ detail = 'signal must be a closed-charset event id, not free text' })
        }
        if ($turn -ceq $signal) {
            return (New-TaskKernelError -Code 'INVALID_SIGNAL' -Extra @{ detail = 'turn id and event id must be distinct' })
        }
        if (-not $PSBoundParameters.ContainsKey('UserInputSequence')) {
            return (New-TaskKernelError -Code 'PLANNER_TURN_SEQUENCE_REQUIRED' -Extra @{ detail = 'strictly increasing task-bound input sequence is mandatory' })
        }
        if (-not (Test-ExecutionBudgetInt -Value $UserInputSequence -Min 1 -Max 2147483647)) {
            return (New-TaskKernelError -Code 'INVALID_SEQUENCE' -Extra @{ detail = 'sequence must be an exact positive integer (no bool/string/fraction)' })
        }
        $seqWant = [long]$UserInputSequence
        $actor = ([string]$Actor).Trim()
        if ([string]::IsNullOrWhiteSpace($actor)) {
            return (New-TaskKernelError -Code 'INVALID_ACTOR')
        }
        $actorLow = $actor.ToLowerInvariant()
        if (($actorLow -cne 'planner') -and ($actorLow -cne 'build')) {
            return (New-TaskKernelError -Code 'BUDGET_WIDEN_DENIED' -Extra @{ detail = 'planner turn is planner only' })
        }
        if (-not (Test-OrchestrationActorIdentitySource -Source $ActorIdentitySource)) {
            return (New-TaskKernelError -Code 'UNTRUSTED_IDENTITY')
        }
        $tid = ([string]$TaskId).Trim()
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        if ([int]$rec['revision'] -ne [int]$ExpectedRevision) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
            return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
        }
        if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
            return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
        }
        $highWater = [long]0
        try {
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('planner_turn_seq') -and ($null -ne $rec['planner_turn_seq'])) {
                $hv = $rec['planner_turn_seq']
                if (($hv -is [int]) -or ($hv -is [long])) { $highWater = [long]$hv }
            }
        }
        catch { $highWater = [long]0 }
        if ($highWater -lt [long]0) { $highWater = [long]0 }
        if ($seqWant -le $highWater) {
            return (New-TaskKernelError -Code 'PLANNER_TURN_SEQUENCE_REPLAY' -Extra @{ detail = 'sequence must exceed the persisted task-bound high-water mark' })
        }
        $curTurn = ''
        $curSignal = ''
        try {
            $pt = $null
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('planner_turn')) { $pt = $rec['planner_turn'] }
            if (($null -ne $pt) -and ($pt -is [System.Collections.IDictionary])) {
                if ($null -ne $pt['turn_id']) { $curTurn = ([string]$pt['turn_id']).Trim() }
                if ($null -ne $pt['signal']) { $curSignal = ([string]$pt['signal']).Trim() }
            }
        }
        catch { }
        $hist = @()
        try {
            if (($rec -is [System.Collections.IDictionary]) -and $rec.Contains('planner_turn_history') -and ($null -ne $rec['planner_turn_history'])) {
                $hist = @($rec['planner_turn_history'])
            }
        }
        catch { $hist = @() }
        $seenTurns = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        $seenSignals = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if (-not [string]::IsNullOrWhiteSpace($curTurn)) { $seenTurns.Add($curTurn) | Out-Null }
        if (-not [string]::IsNullOrWhiteSpace($curSignal)) { $seenSignals.Add($curSignal) | Out-Null }
        foreach ($h in @($hist)) {
            try {
                if ($h -is [System.Collections.IDictionary]) {
                    if ($null -ne $h['turn_id']) {
                        $ht = ([string]$h['turn_id']).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($ht)) { $seenTurns.Add($ht) | Out-Null }
                    }
                    if ($null -ne $h['signal']) {
                        $hs = ([string]$h['signal']).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($hs)) { $seenSignals.Add($hs) | Out-Null }
                    }
                }
            }
            catch { }
        }
        if ($seenTurns.Contains($turn)) {
            return (New-TaskKernelError -Code 'PLANNER_TURN_DUPLICATE' -Extra @{ detail = 'turn id already used' })
        }
        if ($seenSignals.Contains($signal)) {
            return (New-TaskKernelError -Code 'PLANNER_TURN_SIGNAL_REPLAY' -Extra @{ detail = 'event id already used' })
        }
        $pp = $BudgetPolicyPath
        if ([string]::IsNullOrWhiteSpace($pp)) { $pp = Get-ExecutionBudgetDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-ExecutionBudgetPolicyFull -Path $pp)) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        $pb = Get-ExecutionBudgetProfileBudget -Profile 'planner-turn' -PolicyPath $pp -RepoRoot $RepoRoot
        if (-not [bool]$pb.ok) {
            return (New-TaskKernelError -Code 'BUDGET_POLICY_INVALID')
        }
        $snapshot = [ordered]@{
            profile                    = 'planner-turn'
            step_budget                = [int]$pb.budget['step_budget']
            wall_clock_seconds         = [int]$pb.budget['wall_clock_seconds']
            no_progress_seconds        = [int]$pb.budget['no_progress_seconds']
            repeated_action_soft_limit = [int]$pb.budget['repeated_action_soft_limit']
            repeated_action_hard_limit = [int]$pb.budget['repeated_action_hard_limit']
            cycle_repeat_limit         = [int]$pb.budget['cycle_repeat_limit']
            provider_retry_limit       = [int]$pb.budget['provider_retry_limit']
        }
        $newRev = ([int]$rec['revision'] + 1)
        $turnSafe = Protect-TaskKernelText -Text $turn
        $sigSafe = Protect-TaskKernelText -Text $signal
        if ((-not [string]::IsNullOrWhiteSpace($curTurn)) -or (-not [string]::IsNullOrWhiteSpace($curSignal))) {
            $hist = @($hist) + @([ordered]@{ turn_id = (Protect-TaskKernelText -Text $curTurn); signal = (Protect-TaskKernelText -Text $curSignal); seq = [long]$highWater; at = (Get-TaskKernelTimestamp) })
        }
        while (@($hist).Count -gt 20) { $hist = @($hist | Select-Object -Skip 1) }
        $rec['planner_turn_history'] = $hist
        $rec['planner_turn_seq'] = [long]$seqWant
        $rec['planner_turn'] = [ordered]@{
            turn_id         = $turnSafe
            started_at      = (Get-TaskKernelTimestamp)
            signal          = $sigSafe
            seq             = [long]$seqWant
            budget_snapshot = $snapshot
        }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        $null = Send-TaskKernelTelemetry -EventType 'TASK_STATE_CHANGED' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; turn_id = $turnSafe; signal = $sigSafe; seq = [long]$seqWant }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

# ---------- model attempt observation + failure proof (Router v1.4 slice) ----------
#
# Kernel-owned durable evidence that a worker model call really executed.
# A model attempt is recorded ONLY after the kernel independently observes
# the native OpenCode child session (production: read-only local
# `opencode api get` session-info + assistant-message reads, byte-capped,
# identity/usage only) through a narrow injectable READ-ONLY
# session-reader seam (tests simulate the exact host response shapes;
# production default is the actual CLI). No agent-supplied bool, receipt,
# or string is ever accepted as proof: every persisted ref (session,
# parent, message, model, usage) comes from the observed host response,
# and the candidate must name the exact child/message via
# session:/message: refs. No model dispatch or retry happens here.
#
# Lock discipline: snapshot task/revision/bindings under a plain read,
# query the runtime OUTSIDE any lock, then reacquire the lock and
# CAS-revalidate the same binding/revision before writing. No extra
# sidecar store: model_attempts live in the task record, bounded per
# worker candidate by the task execution budget (provider_retry_limit)
# and in total by attempt_budget x provider_retry_limit (duplicates and
# overflow are rejected, never silently dropped).
#
# Get-OrchestrationTaskModelFailureProof recomputes from the persisted
# record only (read-only, no dispatch, no bool/string proof params) and
# returns a persisted reference/digest only when every check holds.
# Verifier origin is established by executed-shape (verifier_ok, executed
# profiles with a non-verified status, exact per-criterion verified/
# unverified words covering all acceptance criteria and agreeing with the
# persisted criterion map) -- not by cryptographic attestation; the
# trust boundary is the CAS-guarded kernel mutation, same as worker
# results and reviews. Secrets, prompts, message text and error payloads
# are never echoed.

function Get-TaskKernelModelPolicyDefaultPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-TaskKernelRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\model-routing-policy.json')
}

function Read-TaskKernelModelPolicy {
    <#
    .SYNOPSIS
        Loads the canonical model routing policy (raw bytes hashed).
        Returns @{ok, policy, policy_hash, policy_version}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath = '', [string]$RepoRoot = '')
    try {
        $p = ([string]$PolicyPath).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-TaskKernelModelPolicyDefaultPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; policy = $null; policy_hash = ''; policy_version = '' }
        }
        $raw = [IO.File]::ReadAllBytes($p)
        if (($null -eq $raw) -or ($raw.Length -eq 0)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; policy = $null; policy_hash = ''; policy_version = '' }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = $sha.ComputeHash($raw) }
        finally { $sha.Dispose() }
        $hash = ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
        $text = [Text.Encoding]::UTF8.GetString($raw)
        $doc = ($text | ConvertFrom-Json)
        if ($null -eq $doc) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; policy = $null; policy_hash = ''; policy_version = '' }
        }
        $pol = ConvertTo-TaskKernelOrdered -Node $doc
        $ver = ''
        try {
            if (($null -ne $pol) -and ($pol -is [System.Collections.IDictionary]) -and ($null -ne $pol['policy_version'])) {
                $ver = ([string]$pol['policy_version']).Trim()
            }
        }
        catch { $ver = '' }
        return @{ ok = $true; error = ''; policy = $pol; policy_hash = $hash; policy_version = $ver }
    }
    catch { return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; policy = $null; policy_hash = ''; policy_version = '' } }
}

function Get-TaskKernelPolicyNode {
    [CmdletBinding()]
    param($Policy, [string]$Name)
    try {
        if ($null -eq $Policy) { return $null }
        if ($Policy -is [System.Collections.IDictionary]) {
            if ($Policy.Contains($Name)) { return $Policy[$Name] }
            return $null
        }
        $p = $Policy.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function Get-TaskKernelCanonicalModelForTier {
    <#
    .SYNOPSIS
        Canonical required model/provider for a tier (tier primary catalog
        entry). Returns @{ok, model_id, provider}. Never throws.
    #>
    [CmdletBinding()]
    param($Policy, [string]$Tier)
    try {
        $t = ([string]$Tier).Trim()
        if (($t -cne 'T3') -and ($t -cne 'T4')) { return @{ ok = $false; error = 'INVALID_TIER'; model_id = ''; provider = '' } }
        $tiers = Get-TaskKernelPolicyNode -Policy $Policy -Name 'tiers'
        $models = Get-TaskKernelPolicyNode -Policy $Policy -Name 'models'
        if (($null -eq $tiers) -or ($null -eq $models)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' }
        }
        $tierNode = Get-TaskKernelPolicyNode -Policy $tiers -Name $t
        if ($null -eq $tierNode) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' }
        }
        $primaryKey = ([string](Get-TaskKernelPolicyNode -Policy $tierNode -Name 'primary')).Trim()
        if ([string]::IsNullOrWhiteSpace($primaryKey)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' }
        }
        $modelNode = Get-TaskKernelPolicyNode -Policy $models -Name $primaryKey
        if ($null -eq $modelNode) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' }
        }
        $mid = ([string](Get-TaskKernelPolicyNode -Policy $modelNode -Name 'model_id')).Trim()
        $prov = ([string](Get-TaskKernelPolicyNode -Policy $modelNode -Name 'provider')).Trim()
        if ([string]::IsNullOrWhiteSpace($mid) -or [string]::IsNullOrWhiteSpace($prov)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' }
        }
        return @{ ok = $true; error = ''; model_id = $mid; provider = $prov }
    }
    catch { return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; model_id = ''; provider = '' } }
}

function Get-TaskKernelTierForModelId {
    <#
    .SYNOPSIS
        Infers the selected tier for an exact model ID from the canonical
        policy (exact case-sensitive match, first tier_profiles entry).
        Returns @{ok, tier, provider}. Never throws.
    #>
    [CmdletBinding()]
    param($Policy, [string]$ModelId)
    try {
        $mid = ([string]$ModelId).Trim()
        if ([string]::IsNullOrWhiteSpace($mid)) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' }
        }
        $models = Get-TaskKernelPolicyNode -Policy $Policy -Name 'models'
        if ($null -eq $models) {
            return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' }
        }
        $keys = @()
        try {
            if ($models -is [System.Collections.IDictionary]) { $keys = @($models.Keys) }
            else { $keys = @($models.PSObject.Properties | ForEach-Object { $_.Name }) }
        }
        catch { return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' } }
        foreach ($k in $keys) {
            $node = Get-TaskKernelPolicyNode -Policy $models -Name ([string]$k)
            if ($null -eq $node) { continue }
            $nodeId = ([string](Get-TaskKernelPolicyNode -Policy $node -Name 'model_id')).Trim()
            if ($nodeId -cne $mid) { continue }
            $prov = ([string](Get-TaskKernelPolicyNode -Policy $node -Name 'provider')).Trim()
            $profiles = @(Get-TaskKernelPolicyNode -Policy $node -Name 'tier_profiles')
            $tier = ''
            foreach ($tp in $profiles) {
                if (($null -ne $tp) -and ($tp -is [System.Collections.IEnumerable]) -and -not ($tp -is [string])) {
                    foreach ($sub in $tp) {
                        $t = ([string]$sub).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($t)) { $tier = $t; break }
                    }
                }
                else {
                    $t = ([string]$tp).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($t)) { $tier = $t; break }
                }
                if (-not [string]::IsNullOrWhiteSpace($tier)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($tier)) {
                return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' }
            }
            return @{ ok = $true; error = ''; tier = $tier; provider = $prov }
        }
        return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' }
    }
    catch { return @{ ok = $false; error = 'MODEL_POLICY_UNKNOWN'; tier = ''; provider = '' } }
}

function Set-TaskKernelSessionReader {
    <#
    .SYNOPSIS
        Installs the narrow READ-ONLY session-reader seam (tests only).
        Production default (cleared seam) is the actual local OpenCode CLI.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Reader)
    $script:TaskKernelSessionReader = $Reader
}

function Clear-TaskKernelSessionReader {
    [CmdletBinding()]
    param()
    $script:TaskKernelSessionReader = $null
}

function Test-TaskKernelModelRef {
    [CmdletBinding()]
    param([string]$Value)
    try {
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s.Length -gt 256) { return $false }
        return ($s -cmatch '^[A-Za-z0-9._/:-]+$')
    }
    catch { return $false }
}

function Get-TaskKernelNodeField {
    <#
    .SYNOPSIS
        Tolerant single-field read (IDictionary or PSObject). Never throws.
    #>
    [CmdletBinding()]
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function Get-TaskKernelReaderErrorCode {
    <#
    .SYNOPSIS
        Extracts a bounded seam error code, '' when not an error envelope.
        Never throws; never echoes payloads.
    #>
    [CmdletBinding()]
    param($Raw)
    try {
        if ($null -eq $Raw) { return 'SESSION_READER_FAILED' }
        if ($Raw -is [System.Collections.IDictionary]) {
            if ($Raw.Contains('ok') -and (-not [bool]$Raw['ok'])) {
                $code = 'SESSION_READER_FAILED'
                if (($Raw.Contains('error')) -and ($null -ne $Raw['error'])) {
                    $c = ([string]$Raw['error']).Trim()
                    if ($c -cmatch '^[A-Z][A-Z0-9_]{1,63}$') { $code = $c }
                }
                return $code
            }
            return ''
        }
        $okProp = $Raw.PSObject.Properties | Where-Object { $_.Name -ceq 'ok' } | Select-Object -First 1
        if (($null -ne $okProp) -and (-not [bool]$okProp.Value)) {
            $code = 'SESSION_READER_FAILED'
            $ep = $Raw.PSObject.Properties | Where-Object { $_.Name -ceq 'error' } | Select-Object -First 1
            if ($null -ne $ep) {
                $c = ([string]$ep.Value).Trim()
                if ($c -cmatch '^[A-Z][A-Z0-9_]{1,63}$') { $code = $c }
            }
            return $code
        }
        return ''
    }
    catch { return 'SESSION_READER_FAILED' }
}

function ConvertTo-TaskKernelSessionObservation {
    <#
    .SYNOPSIS
        Normalizes raw native session docs to the bounded observation
        (ids/model/usage only; message text, prompts and error payloads
        are never carried). The seam and the production api-get reader
        supply the SAME shapes: $SessionNode is the session-info `data`
        object (/api/session/<id>), $MessageNodes is the assistant
        message `data` array (/api/session/<id>/message --param
        type=assistant). Latest completed assistant message wins (ties
        resolve to the last entry); distinct executed models fail closed
        as ambiguous. Returns @{ok, observation/error}. Never throws.
    #>
    [CmdletBinding()]
    param($SessionNode = $null, $MessageNodes = @())
    try {
        if ($null -eq $SessionNode) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $sid = ([string](Get-TaskKernelNodeField -Object $SessionNode -Name 'id')).Trim()
        if ([string]::IsNullOrWhiteSpace($sid)) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $parentId = ''
        foreach ($pk in @('parentID', 'parent_id', 'parent_session_id')) {
            try {
                $pv = ([string](Get-TaskKernelNodeField -Object $SessionNode -Name $pk)).Trim()
                if (-not [string]::IsNullOrWhiteSpace($pv)) { $parentId = $pv; break }
            }
            catch { }
        }
        $agent = ([string](Get-TaskKernelNodeField -Object $SessionNode -Name 'agent')).Trim()
        $outcome = ([string](Get-TaskKernelNodeField -Object $SessionNode -Name 'outcome')).Trim()
        $sessCostRaw = Get-TaskKernelNodeField -Object $SessionNode -Name 'cost'
        $list = @($MessageNodes)
        if (@($list).Count -gt 1024) { return @{ ok = $false; error = 'SESSION_EVIDENCE_TOO_LARGE' } }
        $assistants = @()
        foreach ($m in $list) {
            try {
                if ($null -eq $m) { continue }
                if ([string]::IsNullOrWhiteSpace([string](Get-TaskKernelNodeField -Object $m -Name 'id'))) { continue }
                $mtype = ([string](Get-TaskKernelNodeField -Object $m -Name 'type')).Trim()
                if ($mtype -cne 'assistant') { continue }
                $assistants += $m
            }
            catch { }
        }
        if (@($assistants).Count -eq 0) { return @{ ok = $false; error = 'SESSION_MESSAGE_MISSING' } }
        $completed = @()
        $completedWhen = @()
        foreach ($m in $assistants) {
            try {
                $mmodel = Get-TaskKernelNodeField -Object $m -Name 'model'
                $mprov = ''
                $mmid = ''
                if ($null -ne $mmodel) {
                    $mprov = ([string](Get-TaskKernelNodeField -Object $mmodel -Name 'providerID')).Trim()
                    $mmid = ([string](Get-TaskKernelNodeField -Object $mmodel -Name 'id')).Trim()
                }
                if ([string]::IsNullOrWhiteSpace($mprov) -or [string]::IsNullOrWhiteSpace($mmid)) { continue }
                $mtime = Get-TaskKernelNodeField -Object $m -Name 'time'
                $mdone = ''
                if ($null -ne $mtime) { $mdone = ([string](Get-TaskKernelNodeField -Object $mtime -Name 'completed')).Trim() }
                if ([string]::IsNullOrWhiteSpace($mdone)) { continue }
                $when = [long]0
                try { [long]::TryParse($mdone, [ref]$when) | Out-Null } catch { $when = [long]0 }
                $completed += $m
                $completedWhen += [long]$when
            }
            catch { }
        }
        if (@($completed).Count -eq 0) { return @{ ok = $false; error = 'SESSION_MESSAGE_NOT_COMPLETED' } }
        $distinct = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($m in $completed) {
            try {
                $mmodel = Get-TaskKernelNodeField -Object $m -Name 'model'
                $mprov = ([string](Get-TaskKernelNodeField -Object $mmodel -Name 'providerID')).Trim()
                $mmid = ([string](Get-TaskKernelNodeField -Object $mmodel -Name 'id')).Trim()
                $distinct.Add(($mprov + '/' + $mmid)) | Out-Null
            }
            catch { }
        }
        if (@($distinct).Count -gt 1) { return @{ ok = $false; error = 'SESSION_MESSAGE_AMBIGUOUS' } }
        $best = 0
        for ($i = 1; $i -lt @($completed).Count; $i++) {
            if ([long]$completedWhen[$i] -ge [long]$completedWhen[$best]) { $best = $i }
        }
        $sel = (@($completed))[$best]
        $smodel = Get-TaskKernelNodeField -Object $sel -Name 'model'
        $sprov = ([string](Get-TaskKernelNodeField -Object $smodel -Name 'providerID')).Trim()
        $smid = ([string](Get-TaskKernelNodeField -Object $smodel -Name 'id')).Trim()
        $smsgId = ([string](Get-TaskKernelNodeField -Object $sel -Name 'id')).Trim()
        $sagent = ([string](Get-TaskKernelNodeField -Object $sel -Name 'agent')).Trim()
        if ([string]::IsNullOrWhiteSpace($smsgId)) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        if ([string]::IsNullOrWhiteSpace($sagent)) { return @{ ok = $false; error = 'SESSION_AGENT_MISSING' } }
        $ui = 'UNKNOWN'
        $uo = 'UNKNOWN'
        $ur = 'UNKNOWN'
        $ucr = 'UNKNOWN'
        $ucw = 'UNKNOWN'
        $costRaw = $null
        try {
            $stok = Get-TaskKernelNodeField -Object $sel -Name 'tokens'
            if ($null -ne $stok) {
                $n = 0
                $ti = Get-TaskKernelNodeField -Object $stok -Name 'input'
                if (($null -ne $ti) -and ([int]::TryParse(([string]$ti).Trim(), [ref]$n)) -and ($n -ge 0)) { $ui = $n }
                $n = 0
                $to = Get-TaskKernelNodeField -Object $stok -Name 'output'
                if (($null -ne $to) -and ([int]::TryParse(([string]$to).Trim(), [ref]$n)) -and ($n -ge 0)) { $uo = $n }
                $n = 0
                $tr = Get-TaskKernelNodeField -Object $stok -Name 'reasoning'
                if (($null -ne $tr) -and ([int]::TryParse(([string]$tr).Trim(), [ref]$n)) -and ($n -ge 0)) { $ur = $n }
                # Cache counters live under tokens.cache (read/write); absent
                # stays UNKNOWN, never zero-filled. No message text stored.
                $tcr = $null
                $tcw = $null
                $tc = Get-TaskKernelNodeField -Object $stok -Name 'cache'
                if ($null -ne $tc) {
                    $tcr = Get-TaskKernelNodeField -Object $tc -Name 'read'
                    $tcw = Get-TaskKernelNodeField -Object $tc -Name 'write'
                }
                if ($null -eq $tcr) { $tcr = Get-TaskKernelNodeField -Object $stok -Name 'cache.read' }
                if ($null -eq $tcw) { $tcw = Get-TaskKernelNodeField -Object $stok -Name 'cache.write' }
                $n = 0
                if (($null -ne $tcr) -and ([int]::TryParse(([string]$tcr).Trim(), [ref]$n)) -and ($n -ge 0)) { $ucr = $n }
                $n = 0
                if (($null -ne $tcw) -and ([int]::TryParse(([string]$tcw).Trim(), [ref]$n)) -and ($n -ge 0)) { $ucw = $n }
            }
            $sc = Get-TaskKernelNodeField -Object $sel -Name 'cost'
            if ($null -ne $sc) { $costRaw = $sc }
            if ($null -eq $costRaw) { $costRaw = $sessCostRaw }
        }
        catch { }
        $obs = [ordered]@{}
        $obs['session_id'] = $sid
        $obs['parent_session_id'] = $parentId
        $obs['agent'] = $agent
        $obs['message_agent'] = $sagent
        $obs['message_id'] = $smsgId
        $obs['model_provider'] = $sprov
        $obs['model_id'] = ($sprov + '/' + $smid)
        $obs['message_completed'] = $true
        $obs['session_completed'] = (-not [string]::IsNullOrWhiteSpace($outcome))
        $obs['session_outcome'] = $outcome
        $obs['usage_input'] = $ui
        $obs['usage_output'] = $uo
        $obs['usage_reasoning'] = $ur
        $obs['usage_cache_read'] = $ucr
        $obs['usage_cache_write'] = $ucw
        $obs['cost'] = 'UNKNOWN'
        try {
            if ($null -ne $costRaw) {
                $cs = ([string]$costRaw).Trim()
                if ((-not [string]::IsNullOrWhiteSpace($cs)) -and ($cs -cne 'UNKNOWN')) {
                    $dd = 0.0
                    if ([double]::TryParse($cs, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dd) -and ($dd -ge 0.0)) {
                        # Subscription host (claude-agent) reports zero cost for
                        # billed-through-subscription calls; a displayed zero
                        # is not unlimited, so keep UNKNOWN. Other providers
                        # keep their observed zero.
                        if (($sprov -ceq 'claude-agent') -and ($dd -eq 0.0)) {
                            $obs['cost'] = 'UNKNOWN'
                        }
                        else {
                            $obs['cost'] = $dd
                        }
                    }
                }
            }
        }
        catch { $obs['cost'] = 'UNKNOWN' }
        return @{ ok = $true; error = ''; observation = $obs }
    }
    catch { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
}

function Invoke-TaskKernelNativeApi {
    <#
    .SYNOPSIS
        Runs one read-only local `opencode api get ...` call with a
        bounded timeout. Returns @{ok, code, stdout, error}. Never throws.
        Never echoes CLI payloads: errors are codes only, stdout is
        returned to the caller for capped parsing and never logged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CliArgs, [int]$TimeoutMs = 15000)
    try {
        $resolved = ''
        try {
            $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
            if ($null -eq $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
            if (($null -ne $cmd) -and (-not [string]::IsNullOrWhiteSpace([string]$cmd.Source))) {
                $resolved = ([string]$cmd.Source)
            }
        }
        catch { $resolved = '' }
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            return @{ ok = $false; code = -1; stdout = ''; error = 'LAUNCH' }
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/s /c ""' + $resolved + '" ' + $CliArgs + '"'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = $null
        try { $proc = [System.Diagnostics.Process]::Start($psi) }
        catch { return @{ ok = $false; code = -1; stdout = ''; error = 'LAUNCH' } }
        if ($null -eq $proc) { return @{ ok = $false; code = -1; stdout = ''; error = 'LAUNCH' } }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch { }
            return @{ ok = $false; code = -1; stdout = ''; error = 'TIMEOUT' }
        }
        $stdout = ''
        try { $stdout = ([string]$outTask.Result) } catch { $stdout = '' }
        try { $null = $errTask.Result } catch { }
        return @{ ok = $true; code = [int]$proc.ExitCode; stdout = $stdout; error = '' }
    }
    catch { return @{ ok = $false; code = -1; stdout = ''; error = 'LAUNCH' } }
}

function Read-TaskKernelNativeSession {
    <#
    .SYNOPSIS
        Production session reader: two read-only local
        `opencode api get` calls (session info + latest assistant
        messages). Strict raw byte caps fail closed BEFORE parsing;
        only Session.Info plus the exact/latest completed assistant
        message identity/usage are extracted -- message text is never
        retained, stored or echoed. Never throws.
        Verified against OpenCode v2.2.5: /api/session/<id> returns the
        info envelope (id, parentID, model, outcome, ...);
        /api/session/<id>/message --param type=assistant returns the
        assistant message list (id, agent, model, finish, cost, tokens).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ChildSessionId, [int]$TimeoutMs = 15000)
    try {
        $sid = ([string]$ChildSessionId).Trim()
        if (-not (Test-TaskKernelBindingId -Value $sid)) {
            return @{ ok = $false; error = 'MODEL_ATTEMPT_INVALID_SESSION' }
        }
        $info = Invoke-TaskKernelNativeApi -CliArgs ('api get /api/session/' + $sid) -TimeoutMs $TimeoutMs
        if ((-not [bool]$info.ok) -and ([string]$info.error -ceq 'TIMEOUT')) {
            return @{ ok = $false; error = 'SESSION_READER_TIMEOUT' }
        }
        if (-not [bool]$info.ok) {
            return @{ ok = $false; error = 'SESSION_READER_UNAVAILABLE' }
        }
        if ([int]$info.code -ne 0) { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
        $infoText = ([string]$info.stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($infoText)) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        if ($infoText.Length -gt 16384) { return @{ ok = $false; error = 'SESSION_EVIDENCE_TOO_LARGE' } }
        if (-not $infoText.StartsWith('{')) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $infoDoc = $null
        try { $infoDoc = ($infoText | ConvertFrom-Json) }
        catch { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $sdata = Get-TaskKernelNodeField -Object $infoDoc -Name 'data'
        if ($null -eq $sdata) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $msg = Invoke-TaskKernelNativeApi -CliArgs ('api get /api/session/' + $sid + '/message --param type=assistant') -TimeoutMs $TimeoutMs
        if ((-not [bool]$msg.ok) -and ([string]$msg.error -ceq 'TIMEOUT')) {
            return @{ ok = $false; error = 'SESSION_READER_TIMEOUT' }
        }
        if (-not [bool]$msg.ok) {
            return @{ ok = $false; error = 'SESSION_READER_UNAVAILABLE' }
        }
        if ([int]$msg.code -ne 0) { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
        $msgText = ([string]$msg.stdout).Trim()
        if ([string]::IsNullOrWhiteSpace($msgText)) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        if ($msgText.Length -gt 65536) { return @{ ok = $false; error = 'SESSION_EVIDENCE_TOO_LARGE' } }
        if (-not $msgText.StartsWith('{')) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $msgDoc = $null
        try { $msgDoc = ($msgText | ConvertFrom-Json) }
        catch { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        $mdata = Get-TaskKernelNodeField -Object $msgDoc -Name 'data'
        if ($null -eq $mdata) { return @{ ok = $false; error = 'SESSION_EVIDENCE_MALFORMED' } }
        return (ConvertTo-TaskKernelSessionObservation -SessionNode $sdata -MessageNodes @($mdata))
    }
    catch { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
}

function Invoke-TaskKernelSessionObservation {
    <#
    .SYNOPSIS
        Reads one child session through the seam (tests) or the actual
        local OpenCode CLI (production). The seam supplies the SAME raw
        shapes as production: @{session=<info data>; messages=<message
        data array>} or @{ok=$false; error=<CODE>}. Read-only.
        Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ChildSessionId)
    try {
        $seam = $null
        try { $seam = $script:TaskKernelSessionReader } catch { $seam = $null }
        if ($null -ne $seam) {
            $raw = $null
            try { $raw = (& $seam ([string]$ChildSessionId)) }
            catch { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
            $ecode = Get-TaskKernelReaderErrorCode -Raw $raw
            if (-not [string]::IsNullOrWhiteSpace($ecode)) { return @{ ok = $false; error = $ecode } }
            if ($null -eq $raw) { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
            $snode = Get-TaskKernelNodeField -Object $raw -Name 'session'
            $mnode = Get-TaskKernelNodeField -Object $raw -Name 'messages'
            $mlist = @()
            if ($null -ne $mnode) { $mlist = @($mnode) }
            return (ConvertTo-TaskKernelSessionObservation -SessionNode $snode -MessageNodes $mlist)
        }
        return (Read-TaskKernelNativeSession -ChildSessionId ([string]$ChildSessionId))
    }
    catch { return @{ ok = $false; error = 'SESSION_READER_FAILED' } }
}

function Get-TaskKernelBoundRunForSession {
    <#
    .SYNOPSIS
        Finds attached runs binding a child session. Returns @{count,
        run_id, root_session}. Never throws.
    #>
    [CmdletBinding()]
    param($Record, [string]$ChildSessionId)
    $out = @{ count = 0; run_id = ''; root_session = '' }
    try {
        $sid = ([string]$ChildSessionId).Trim()
        $b = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains('bindings')) { $b = $Record['bindings'] }
        }
        if ($null -eq $b) { return $out }
        $runs = @()
        try {
            if ($b -is [System.Collections.IDictionary]) {
                if ($null -ne $b['runs']) { $runs = @($b['runs']) }
            }
        }
        catch { return $out }
        $hits = @()
        foreach ($r in $runs) {
            try {
                if ($null -eq $r) { continue }
                $status = ''
                $rid = ''
                $root = ''
                $ws = @()
                if ($r -is [System.Collections.IDictionary]) {
                    if ($null -ne $r['status']) { $status = ([string]$r['status']).Trim() }
                    if ($null -ne $r['run_id']) { $rid = ([string]$r['run_id']).Trim() }
                    if ($null -ne $r['root_session']) { $root = ([string]$r['root_session']).Trim() }
                    if ($null -ne $r['worker_sessions']) { $ws = @($r['worker_sessions']) }
                }
                else { continue }
                if ($status -cne 'attached') { continue }
                $found = $false
                foreach ($w in $ws) {
                    if ([string]$w -ceq $sid) { $found = $true; break }
                }
                if (-not $found) { continue }
                $hits += [ordered]@{ run_id = $rid; root_session = $root }
            }
            catch { }
        }
        $out.count = (@($hits).Count)
        if (@($hits).Count -eq 1) {
            $out.run_id = ([string]$hits[0]['run_id'])
            $out.root_session = ([string]$hits[0]['root_session'])
        }
        return $out
    }
    catch { return $out }
}

function Resolve-TaskKernelExplicitRepoRoot {
    <#
    .SYNOPSIS
        Resolves the repo root for kernel file/policy lookups. An
        explicit -RepoRoot must exist (fail closed); empty resolves to
        the library-root canonical path (never the process CWD).
        Returns @{ok, root, error}. Never throws.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        $r = ([string]$RepoRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) {
            return @{ ok = $true; error = ''; root = (Get-TaskKernelRepoRoot -RepoRoot '') }
        }
        $full = ''
        try { $full = [IO.Path]::GetFullPath($r) } catch { $full = '' }
        if ([string]::IsNullOrWhiteSpace($full)) {
            return @{ ok = $false; error = 'INVALID_REPO_ROOT'; root = '' }
        }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            return @{ ok = $false; error = 'INVALID_REPO_ROOT'; root = '' }
        }
        return @{ ok = $true; error = ''; root = $full }
    }
    catch { return @{ ok = $false; error = 'INVALID_REPO_ROOT'; root = '' } }
}

function Get-TaskKernelBoundVerificationRoot {
    <#
    .SYNOPSIS
        Resolves the task-bound verification/model root. Reads the
        persisted verification_repo_root; a missing/blank stored root
        (every task created before the field existed) fails closed with
        -UnboundCode. A nonempty caller -RepoRoot is only an assertion:
        it must normalize to the stored root or the call fails closed
        with -MismatchCode. An omitted/empty caller root uses the stored
        root. No migration, no rebind. Returns @{ok, root, error}. Never
        throws. Comparison is ordinal-ignore-case on full paths with
        trailing separators trimmed.
    #>
    [CmdletBinding()]
    param($Record, [string]$CallerRepoRoot = '', [string]$UnboundCode = 'VERIFY_RUN_ROOT_UNBOUND', [string]$MismatchCode = 'VERIFY_RUN_ROOT_MISMATCH')
    try {
        $stored = ''
        try {
            if (($null -ne $Record) -and ($Record -is [System.Collections.IDictionary]) -and ($null -ne $Record['verification_repo_root'])) {
                $stored = ([string]$Record['verification_repo_root']).Trim()
            }
        }
        catch { $stored = '' }
        if ([string]::IsNullOrWhiteSpace($stored)) {
            return @{ ok = $false; error = ([string]$UnboundCode); root = '' }
        }
        $storedFull = ''
        try { $storedFull = [IO.Path]::GetFullPath($stored) } catch { $storedFull = $stored }
        $caller = ([string]$CallerRepoRoot).Trim()
        if ([string]::IsNullOrWhiteSpace($caller)) {
            return @{ ok = $true; error = ''; root = $storedFull }
        }
        $callerFull = ''
        try { $callerFull = [IO.Path]::GetFullPath($caller) } catch { $callerFull = '' }
        if ([string]::IsNullOrWhiteSpace($callerFull)) {
            return @{ ok = $false; error = ([string]$MismatchCode); root = '' }
        }
        $normStored = ([string]$storedFull).TrimEnd('\', '/')
        $normCaller = ([string]$callerFull).TrimEnd('\', '/')
        if ($normCaller -cne $normStored -and ([string]::Compare($normCaller, $normStored, $true) -ne 0)) {
            return @{ ok = $false; error = ([string]$MismatchCode); root = '' }
        }
        return @{ ok = $true; error = ''; root = $storedFull }
    }
    catch { return @{ ok = $false; error = ([string]$UnboundCode); root = '' } }
}

function Get-TaskKernelClaimedRefs {
    <#
    .SYNOPSIS
        Extracts exact kernel-correlation refs from worker claimed
        evidence (entries exactly `session:<id>` / `message:<id>`,
        binding-id charset, deduplicated). Returns string[]. Never throws.
    #>
    [CmdletBinding()]
    param($Claimed = @(), [string]$Prefix = '')
    $out = @()
    try {
        $pfx = ([string]$Prefix).Trim()
        if ([string]::IsNullOrWhiteSpace($pfx)) { return @() }
        foreach ($e in @($Claimed)) {
            try {
                $s = ([string]$e)
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                if (-not $s.StartsWith($pfx, [System.StringComparison]::Ordinal)) { continue }
                $v = $s.Substring($pfx.Length)
                if (-not (Test-TaskKernelBindingId -Value $v)) { continue }
                if ($out -cnotcontains $v) { $out += $v }
            }
            catch { }
        }
    }
    catch { }
    return $out
}

function Test-TaskKernelCriterionCoverage {
    <#
    .SYNOPSIS
        Maps strict `criterion:<idx>:<verified|unverified>` evidence
        entries against the task acceptance-criteria count. The index set
        must equal exactly {0..count-1} (no missing, no out-of-range, no
        malformed criterion:-prefixed entry; duplicates must agree).
        Returns @{ok, error, statuses}. Never throws.
    #>
    [CmdletBinding()]
    param($Evidence = @(), [int]$CriterionCount = 0)
    try {
        if ([int]$CriterionCount -lt 1) {
            return @{ ok = $false; error = 'PROOF_NO_ACCEPTANCE_CRITERIA'; statuses = $null }
        }
        $map = [ordered]@{}
        foreach ($e in @($Evidence)) {
            try {
                $s = ([string]$e)
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                if (-not ($s -cmatch '^criterion:')) { continue }
                if (-not ($s -cmatch '^criterion:([0-9]+):(verified|unverified)$')) {
                    return @{ ok = $false; error = 'PROOF_CRITERION_MALFORMED'; statuses = $null }
                }
                $idx = [int]$Matches[1]
                $word = ([string]$Matches[2]).Trim().ToLowerInvariant()
                if (($idx -lt 0) -or ($idx -ge [int]$CriterionCount)) {
                    return @{ ok = $false; error = 'PROOF_CRITERION_COVERAGE_MISMATCH'; statuses = $null }
                }
                $k = [string]$idx
                if ($map.Contains($k)) {
                    if ([string]$map[$k] -cne $word) {
                        return @{ ok = $false; error = 'PROOF_CRITERION_MALFORMED'; statuses = $null }
                    }
                    continue
                }
                $map[$k] = $word
            }
            catch { return @{ ok = $false; error = 'PROOF_CRITERION_MALFORMED'; statuses = $null } }
        }
        for ($i = 0; $i -lt [int]$CriterionCount; $i++) {
            if (-not $map.Contains([string]$i)) {
                return @{ ok = $false; error = 'PROOF_CRITERION_COVERAGE_MISMATCH'; statuses = $null }
            }
        }
        return @{ ok = $true; error = ''; statuses = $map }
    }
    catch { return @{ ok = $false; error = 'PROOF_CRITERION_MALFORMED'; statuses = $null } }
}

function Set-OrchestrationTaskModelAttempt {
    <#
    .SYNOPSIS
        Records one independently-observed worker model call.
    .DESCRIPTION
        Contract (fail-closed, never throws):
        - Requires TaskId + child SessionId; the parent/run/session binding
          must already exist in the task record (child in an attached run's
          worker_sessions with a non-empty root_session). The CURRENT
          worker result must be a final candidate (failed/candidate_pass)
          that names this exact child/message via kernel-correlation refs
          (`session:<child>` exactly once plus >=1 `message:<id>` entry in
          claimed_evidence); an observed session the candidate does not
          name is refused. Callers must record the attempt AFTER the
          worker result it observes: the current worker_result.revision is
          pinned into the node and the proof requires it to still be
          current.
        - The session is read OUTSIDE any lock through
          Invoke-TaskKernelSessionObservation (seam for tests, actual
          local `opencode api get` reads in production: session info +
          assistant message list, byte-capped, identity/usage only).
          Agent-supplied bools/receipts are not parameters and are never
          consulted.
        - Validates SessionInfo.id, parentID (must equal the bound root),
          agent consistency, the latest completed assistant message
          model.providerID/id, message + session completion, and infers
          the tier from the canonical policy by exact model ID (unknown
          model fails closed).
        - Persists under the existing task lock+CAS (revalidates revision,
          the same binding and the named refs before writing). Bounded
          per worker candidate by the task execution budget
          (provider_retry_limit) and in total by
          attempt_budget x provider_retry_limit; duplicates and overflow
          are rejected, never silently dropped. No dispatch, no retry,
          no message text, no secrets.
        - Root binding: the persisted verification_repo_root is required;
          a missing stored root fails closed with
          MODEL_ATTEMPT_ROOT_UNBOUND. A nonempty caller -RepoRoot is only
          an assertion and must match the stored root
          (MODEL_ATTEMPT_ROOT_MISMATCH); an omitted/empty caller root
          uses the stored root for model-policy resolution. No migration
          or rebind for legacy tasks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$ChildSessionId,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$PolicyPath = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $effRoot = ''
        $effRootSlot = Resolve-TaskKernelExplicitRepoRoot -RepoRoot $RepoRoot
        if (-not [bool]$effRootSlot.ok) {
            return (New-TaskKernelError -Code ([string]$effRootSlot.error))
        }
        $effRoot = ([string]$effRootSlot.root)
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $effRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-TaskKernelId -TaskId $tid)) {
            return (New-TaskKernelError -Code 'INVALID_TASK_ID')
        }
        $child = ([string]$ChildSessionId).Trim()
        if (-not (Test-TaskKernelBindingId -Value $child)) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_INVALID_SESSION')
        }
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $effRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $snap = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$snap.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$snap.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $snapRec = $snap.record
        $boundRootAttempt = Get-TaskKernelBoundVerificationRoot -Record $snapRec -CallerRepoRoot $RepoRoot -UnboundCode 'MODEL_ATTEMPT_ROOT_UNBOUND' -MismatchCode 'MODEL_ATTEMPT_ROOT_MISMATCH'
        if (-not [bool]$boundRootAttempt.ok) {
            return (New-TaskKernelError -Code ([string]$boundRootAttempt.error))
        }
        $modelRoot = ([string]$boundRootAttempt.root)
        $rev0 = [int]$snapRec['revision']
        if ([int]$ExpectedRevision -ne $rev0) {
            return (New-TaskKernelError -Code 'CAS_CONFLICT')
        }
        $bound = Get-TaskKernelBoundRunForSession -Record $snapRec -ChildSessionId $child
        if ([int]$bound.count -eq 0) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_SESSION_NOT_BOUND')
        }
        if ([int]$bound.count -gt 1) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_SESSION_AMBIGUOUS')
        }
        if ([string]::IsNullOrWhiteSpace([string]$bound.root_session)) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_PARENT_UNBOUND')
        }
        $wrkSnap = $null
        try {
            if (($snapRec -is [System.Collections.IDictionary]) -and $snapRec.Contains('worker_result')) { $wrkSnap = $snapRec['worker_result'] }
        }
        catch { $wrkSnap = $null }
        if (($null -eq $wrkSnap) -or -not ($wrkSnap -is [System.Collections.IDictionary])) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_CANDIDATE_MISSING')
        }
        $wrkStatus = ''
        $wrkRevSnap = 0
        $wrkClaimed = @()
        try {
            if ($null -ne $wrkSnap['status']) { $wrkStatus = ([string]$wrkSnap['status']).Trim().ToLowerInvariant() }
            if ($null -ne $wrkSnap['revision']) { $wrkRevSnap = [int]$wrkSnap['revision'] }
            if ($null -ne $wrkSnap['claimed_evidence']) { $wrkClaimed = @($wrkSnap['claimed_evidence']) }
        }
        catch { }
        if ((($wrkStatus -cne 'failed') -and ($wrkStatus -cne 'candidate_pass')) -or ($wrkRevSnap -le 0)) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_CANDIDATE_NOT_FINAL')
        }
        $namedSessions = @(Get-TaskKernelClaimedRefs -Claimed $wrkClaimed -Prefix 'session:')
        if (@($namedSessions).Count -eq 0) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_SESSION_UNCORRELATED')
        }
        if (@($namedSessions).Count -gt 1) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_SESSION_AMBIGUOUS')
        }
        if ([string]$namedSessions[0] -cne $child) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_SESSION_UNCORRELATED')
        }
        $namedMessages = @(Get-TaskKernelClaimedRefs -Claimed $wrkClaimed -Prefix 'message:')
        if (@($namedMessages).Count -eq 0) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_MESSAGE_UNCORRELATED')
        }
        $retryCap = 2
        try {
            $ebSnap = $null
            if (($snapRec -is [System.Collections.IDictionary]) -and ($null -ne $snapRec['execution_budget'])) { $ebSnap = $snapRec['execution_budget'] }
            if (($null -ne $ebSnap) -and ($ebSnap -is [System.Collections.IDictionary]) -and ($null -ne $ebSnap['provider_retry_limit'])) {
                $rcSnap = [int]$ebSnap['provider_retry_limit']
                if ($rcSnap -ge 1) { $retryCap = $rcSnap }
            }
        }
        catch { $retryCap = 2 }
        $taskBudget = 3
        try { $taskBudget = [int]$snapRec['attempt_budget'] } catch { $taskBudget = 3 }
        if ($taskBudget -lt 1) { $taskBudget = 3 }
        $totalCap = ([int]$taskBudget * [int]$retryCap)
        $modelList0 = @()
        try { if ($null -ne $snapRec['model_attempts']) { $modelList0 = @($snapRec['model_attempts']) } } catch { $modelList0 = @() }
        $perCount0 = 0
        foreach ($pa in $modelList0) {
            try {
                if (($null -ne $pa) -and ($pa -is [System.Collections.IDictionary]) -and ($null -ne $pa['worker_revision']) -and ([int]$pa['worker_revision'] -eq [int]$wrkRevSnap)) { $perCount0++ }
            }
            catch { }
        }
        if ($perCount0 -ge $retryCap) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_BUDGET_EXHAUSTED' -Extra @{ scope = 'per-candidate' })
        }
        if ((@($modelList0).Count) -ge $totalCap) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_BUDGET_EXHAUSTED' -Extra @{ scope = 'task-total' })
        }
        $pol = Read-TaskKernelModelPolicy -PolicyPath $PolicyPath -RepoRoot $modelRoot
        if (-not [bool]$pol.ok) {
            return (New-TaskKernelError -Code ([string]$pol.error))
        }
        $slot = Invoke-TaskKernelSessionObservation -ChildSessionId $child
        if (-not [bool]$slot.ok) {
            return (New-TaskKernelError -Code ([string]$slot.error))
        }
        $obs = $slot.observation
        if ([string]$obs['session_id'] -cne $child) {
            return (New-TaskKernelError -Code 'SESSION_ID_MISMATCH')
        }
        if ([string]::IsNullOrWhiteSpace([string]$obs['parent_session_id'])) {
            return (New-TaskKernelError -Code 'SESSION_PARENT_UNVERIFIED')
        }
        if ([string]$obs['parent_session_id'] -cne ([string]$bound.root_session)) {
            return (New-TaskKernelError -Code 'SESSION_PARENT_MISMATCH')
        }
        $agent = ([string]$obs['agent']).Trim()
        $msgAgent = ([string]$obs['message_agent']).Trim()
        if ([string]::IsNullOrWhiteSpace($msgAgent)) {
            return (New-TaskKernelError -Code 'SESSION_AGENT_MISSING')
        }
        if ((-not [string]::IsNullOrWhiteSpace($agent)) -and ($agent -cne $msgAgent)) {
            return (New-TaskKernelError -Code 'SESSION_AGENT_MISMATCH')
        }
        $prov = ([string]$obs['model_provider']).Trim()
        $mid = ([string]$obs['model_id']).Trim()
        if (([string]::IsNullOrWhiteSpace($prov)) -or (-not (Test-TaskKernelModelRef -Value $mid))) {
            return (New-TaskKernelError -Code 'MODEL_IDENTITY_MISSING')
        }
        $fullId = $mid
        if ($mid -notmatch '/') { $fullId = ($prov + '/' + $mid) }
        $tierSlot = Get-TaskKernelTierForModelId -Policy $pol.policy -ModelId $fullId
        if (-not [bool]$tierSlot.ok) {
            return (New-TaskKernelError -Code ([string]$tierSlot.error))
        }
        if ([string]$obs['message_id'] -ceq '') {
            return (New-TaskKernelError -Code 'SESSION_MESSAGE_MISSING')
        }
        if (-not [bool]$obs['message_completed']) {
            return (New-TaskKernelError -Code 'SESSION_MESSAGE_NOT_COMPLETED')
        }
        if ((-not [bool]$obs['session_completed']) -and ([string]::IsNullOrWhiteSpace([string]$obs['session_outcome']))) {
            return (New-TaskKernelError -Code 'SESSION_NOT_COMPLETED')
        }
        $obsMsgId = ([string]$obs['message_id']).Trim()
        if (@($namedMessages) -cnotcontains $obsMsgId) {
            return (New-TaskKernelError -Code 'MODEL_ATTEMPT_MESSAGE_MISMATCH')
        }
        $lock = Enter-TaskKernelFileLock -TaskFile $taskFile
        if (-not [bool]$lock.acquired) {
            return (New-TaskKernelError -Code 'LOCK_TIMEOUT')
        }
        try {
            $slot2 = Read-TaskKernelRecord -TaskFile $taskFile
            if (-not [bool]$slot2.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
            if ([bool]$slot2.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
            $rec = $slot2.record
            if ([int]$rec['revision'] -ne $rev0) {
                return (New-TaskKernelError -Code 'CAS_CONFLICT')
            }
            if (Test-TaskKernelTerminalState -State ([string]$rec['state'])) {
                return (New-TaskKernelError -Code 'ILLEGAL_TRANSITION' -Extra @{ detail = 'terminal state is immutable' })
            }
            if (-not (Test-TaskKernelWriteBoundary -TaskFile $taskFile)) {
                return (New-TaskKernelError -Code 'PATH_NOT_CONFINED')
            }
            $bound2 = Get-TaskKernelBoundRunForSession -Record $rec -ChildSessionId $child
            if (([int]$bound2.count -ne 1) -or ([string]$bound2.run_id -cne ([string]$bound.run_id)) -or ([string]$bound2.root_session -cne ([string]$bound.root_session))) {
                return (New-TaskKernelError -Code 'MODEL_ATTEMPT_BINDING_CHANGED')
            }
            $modelList = @()
            try { if ($null -ne $rec['model_attempts']) { $modelList = @($rec['model_attempts']) } } catch { $modelList = @() }
            $perCount = 0
            $isDuplicate = $false
            foreach ($pa in $modelList) {
                try {
                    if (($null -eq $pa) -or -not ($pa -is [System.Collections.IDictionary])) { continue }
                    if (($null -ne $pa['worker_revision']) -and ([int]$pa['worker_revision'] -eq [int]$wrkRevSnap)) {
                        $perCount++
                        $ps = ''
                        $pm = ''
                        if ($null -ne $pa['session_id']) { $ps = ([string]$pa['session_id']).Trim() }
                        if ($null -ne $pa['message_id']) { $pm = ([string]$pa['message_id']).Trim() }
                        if (($ps -ceq $child) -and ($pm -ceq $obsMsgId)) { $isDuplicate = $true }
                    }
                }
                catch { }
            }
            if ((@($modelList).Count -ne @($modelList0).Count) -or ($perCount -ne $perCount0)) {
                return (New-TaskKernelError -Code 'CAS_CONFLICT')
            }
            if ([bool]$isDuplicate) {
                return (New-TaskKernelError -Code 'MODEL_ATTEMPT_DUPLICATE')
            }
            $retryCap2 = 2
            try {
                $eb2 = $null
                if (($rec -is [System.Collections.IDictionary]) -and ($null -ne $rec['execution_budget'])) { $eb2 = $rec['execution_budget'] }
                if (($null -ne $eb2) -and ($eb2 -is [System.Collections.IDictionary]) -and ($null -ne $eb2['provider_retry_limit'])) {
                    $rc2 = [int]$eb2['provider_retry_limit']
                    if ($rc2 -ge 1) { $retryCap2 = $rc2 }
                }
            }
            catch { $retryCap2 = 2 }
            $taskBudget2 = 3
            try { $taskBudget2 = [int]$rec['attempt_budget'] } catch { $taskBudget2 = 3 }
            if ($taskBudget2 -lt 1) { $taskBudget2 = 3 }
            if ($perCount -ge $retryCap2) {
                return (New-TaskKernelError -Code 'MODEL_ATTEMPT_BUDGET_EXHAUSTED' -Extra @{ scope = 'per-candidate' })
            }
            if ((@($modelList).Count) -ge ([int]$taskBudget2 * [int]$retryCap2)) {
                return (New-TaskKernelError -Code 'MODEL_ATTEMPT_BUDGET_EXHAUSTED' -Extra @{ scope = 'task-total' })
            }
            $failedCount = 0
            $stratFp = ''
            $workerRev = 0
            try {
                if ($null -ne $rec['attempts']) { $failedCount = (@($rec['attempts'])).Count }
                if ($failedCount -gt 0) {
                    $last = (@($rec['attempts']))[$failedCount - 1]
                    $stratFp = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $last -Name 'strategy_fingerprint'))
                }
            }
            catch { }
            try {
                $wrk = $rec['worker_result']
                if (($null -ne $wrk) -and ($wrk -is [System.Collections.IDictionary]) -and ($null -ne $wrk['revision'])) {
                    $workerRev = [int]$wrk['revision']
                }
            }
            catch { $workerRev = 0 }
            $newRev = ([int]$rec['revision'] + 1)
            $node = [ordered]@{
                n                  = ((@($modelList).Count) + 1)
                attempt_n          = $failedCount
                worker_revision    = $workerRev
                session_id         = $child
                run_id             = ([string]$bound.run_id)
                parent_session_id  = ([string]$bound.root_session)
                message_id         = ([string]$obs['message_id']).Trim()
                model              = $fullId
                provider           = $prov
                tier               = ([string]$tierSlot.tier)
                strategy_fingerprint = $stratFp
                usage_input        = $obs['usage_input']
                usage_output       = $obs['usage_output']
                usage_reasoning    = $obs['usage_reasoning']
                usage_cache_read   = $obs['usage_cache_read']
                usage_cache_write  = $obs['usage_cache_write']
                cost               = $obs['cost']
                session_outcome    = ([string]$obs['session_outcome']).Trim()
                observed_at        = (Get-TaskKernelTimestamp)
                recorded_at        = (Get-TaskKernelTimestamp)
                policy_hash        = ([string]$pol.policy_hash)
                policy_version     = ([string]$pol.policy_version)
                task_revision      = $newRev
            }
            $modelList += $node
            $rec['model_attempts'] = $modelList
            # Model-routing tasks become proof-scoped on the first persisted
            # observation even when they were created without a verifier plan.
            $rec['completion_verification_contract'] = 'router-v1.4-kernel'
            $rec['revision'] = $newRev
            $rec['updated_at'] = (Get-TaskKernelTimestamp)
            $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
            if (-not [bool]$wr.ok) {
                return (New-TaskKernelError -Code ([string]$wr.error))
            }
            return [PSCustomObject]@{
                ok                = $true
                task_id           = $tid
                revision          = $newRev
                attempt_n         = ((@($modelList).Count))
                worker_revision   = $wrkRevSnap
                model             = $fullId
                provider          = $prov
                tier              = ([string]$tierSlot.tier)
                session_id        = $child
                run_id            = ([string]$bound.run_id)
                parent_session_id = ([string]$bound.root_session)
                message_id        = ([string]$obs['message_id']).Trim()
                policy_hash       = ([string]$pol.policy_hash)
            }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Test-TaskKernelModelFailureProofCore {
    <#
    .SYNOPSIS
        Recomputes one model-failure proof from the persisted record.
        Read-only. Returns @{ok, proof/error}. Never throws.
    #>
    [CmdletBinding()]
    param($Record, [string]$RequiredTier, $Policy, [string]$PolicyHash, [string]$RequiredModel, [string]$RequiredProvider, [bool]$Head = $true, [int]$MaxAttemptIndex = 2147483647, [int]$HeadWorkerRevision = 0)
    $refuse = {
        param([string]$Why)
        return @{ ok = $false; error = $Why }
    }
    try {
        $tid = ''
        try { $tid = ([string]$Record['task_id']).Trim() } catch { $tid = '' }
        $criteria = @()
        try { if ($null -ne $Record['acceptance_criteria']) { $criteria = @($Record['acceptance_criteria']) } } catch { $criteria = @() }
        $ver = $null
        try {
            if (($Record -is [System.Collections.IDictionary]) -and $Record.Contains('verification')) { $ver = $Record['verification'] }
        }
        catch { $ver = $null }
        if (($null -eq $ver) -or -not ($ver -is [System.Collections.IDictionary])) {
            return (& $refuse 'PROOF_VERIFICATION_MISSING')
        }
        if (-not $ver.Contains('status')) {
            return (& $refuse 'LEGACY_VERIFICATION_UNKNOWN')
        }
        $vstatus = ([string]$ver['status']).Trim()
        if ([string]::IsNullOrWhiteSpace($vstatus)) {
            return (& $refuse 'LEGACY_VERIFICATION_UNKNOWN')
        }
        if ($vstatus -cne 'verification_failed') {
            return (& $refuse 'PROOF_STATUS_NOT_FAILED')
        }
        $vpassed = $true
        try { if ($null -ne $ver['passed']) { $vpassed = [bool]$ver['passed'] } } catch { $vpassed = $true }
        if ([bool]$vpassed) {
            return (& $refuse 'PROOF_PASSED_NOT_FAILED')
        }
        $vsrc = ''
        try { if ($null -ne $ver['verification_source']) { $vsrc = ([string]$ver['verification_source']).Trim() } } catch { $vsrc = '' }
        if ($vsrc -cne 'kernel-executed') {
            return (& $refuse 'PROOF_VERIFIER_UNTRUSTED')
        }
        $vexReal = $false
        try { if ($null -ne $ver['verifier_executed']) { $vexReal = [bool]$ver['verifier_executed'] } } catch { $vexReal = $false }
        if (-not [bool]$vexReal) {
            return (& $refuse 'PROOF_VERIFIER_UNTRUSTED')
        }
        $vdigest = ''
        try { if ($null -ne $ver['result_digest']) { $vdigest = ([string]$ver['result_digest']).Trim() } } catch { $vdigest = '' }
        if ([string]::IsNullOrWhiteSpace($vdigest)) {
            return (& $refuse 'PROOF_VERIFIER_PROVENANCE_MISSING')
        }
        $vprofiles = @()
        try { if ($null -ne $ver['profiles']) { $vprofiles = @($ver['profiles']) } } catch { $vprofiles = @() }
        if (@($vprofiles).Count -eq 0) {
            return (& $refuse 'PROOF_VERIFIER_NO_PROFILES')
        }
        $profFailed = $false
        foreach ($vp2 in $vprofiles) {
            try {
                if ($null -eq $vp2) { return (& $refuse 'PROOF_VERIFIER_PROFILES_MALFORMED') }
                $vpn2 = ''
                $vps2 = ''
                if ($vp2 -is [System.Collections.IDictionary]) {
                    if ($null -ne $vp2['profile']) { $vpn2 = ([string]$vp2['profile']).Trim() }
                    if ($null -ne $vp2['status']) { $vps2 = ([string]$vp2['status']).Trim() }
                }
                else {
                    $qp1 = $vp2.PSObject.Properties | Where-Object { $_.Name -ceq 'profile' } | Select-Object -First 1
                    if ($null -ne $qp1) { $vpn2 = ([string]$qp1.Value).Trim() }
                    $qp2 = $vp2.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                    if ($null -ne $qp2) { $vps2 = ([string]$qp2.Value).Trim() }
                }
                if ([string]::IsNullOrWhiteSpace($vpn2) -or [string]::IsNullOrWhiteSpace($vps2)) {
                    return (& $refuse 'PROOF_VERIFIER_PROFILES_MALFORMED')
                }
                if ($vps2 -cne 'verified') { $profFailed = $true }
            }
            catch { return (& $refuse 'PROOF_VERIFIER_PROFILES_MALFORMED') }
        }
        if (-not [bool]$profFailed) {
            return (& $refuse 'PROOF_VERIFIER_NO_FAILED_PROFILE')
        }
        $wrk = $null
        try {
            if (($Record -is [System.Collections.IDictionary]) -and $Record.Contains('worker_result')) { $wrk = $Record['worker_result'] }
        }
        catch { $wrk = $null }
        if (($null -eq $wrk) -or -not ($wrk -is [System.Collections.IDictionary])) {
            return (& $refuse 'PROOF_CANDIDATE_NOT_FAILED')
        }
        $wstatus = ''
        $wrev = 0
        try {
            if ($null -ne $wrk['status']) { $wstatus = ([string]$wrk['status']).Trim().ToLowerInvariant() }
            if ($null -ne $wrk['revision']) { $wrev = [int]$wrk['revision'] }
        }
        catch { }
        if ((($wstatus -cne 'failed') -and ($wstatus -cne 'candidate_pass')) -or ($wrev -le 0)) {
            return (& $refuse 'PROOF_CANDIDATE_NOT_FAILED')
        }
        $candRev = 0
        try { if ($null -ne $ver['candidate_revision']) { $candRev = [int]$ver['candidate_revision'] } } catch { $candRev = 0 }
        if ([bool]$Head -and ($candRev -ne $wrev)) {
            return (& $refuse 'PROOF_CANDIDATE_STALE')
        }
        $verRev = 0
        try { if ($null -ne $ver['revision']) { $verRev = [int]$ver['revision'] } } catch { $verRev = 0 }
        $verEvidence = @()
        try { if ($null -ne $ver['evidence']) { $verEvidence = @($ver['evidence']) } } catch { $verEvidence = @() }
        $critSlot = Test-TaskKernelCriterionCoverage -Evidence $verEvidence -CriterionCount (@($criteria).Count)
        if (-not [bool]$critSlot.ok) {
            return (& $refuse ([string]$critSlot.error))
        }
        $unverifiedCount = 0
        foreach ($ck in @($critSlot.statuses.Keys)) {
            if ([string]$critSlot.statuses[$ck] -cne 'verified') { $unverifiedCount++ }
        }
        if ($unverifiedCount -eq 0) {
            return (& $refuse 'PROOF_CRITERION_ALL_VERIFIED')
        }
        $vmapCheck = $null
        try { if ($ver.Contains('criterion_map')) { $vmapCheck = $ver['criterion_map'] } } catch { $vmapCheck = $null }
        if (($null -eq $vmapCheck) -or -not ($vmapCheck -is [System.Collections.IDictionary])) {
            return (& $refuse 'PROOF_CRITERION_MAP_MISSING')
        }
        $mapKeys = @($vmapCheck.Keys)
        if ((@($mapKeys).Count) -ne (@($critSlot.statuses.Keys).Count)) {
            return (& $refuse 'PROOF_CRITERION_MAP_MISMATCH')
        }
        foreach ($ck in @($critSlot.statuses.Keys)) {
            $foundMap = $false
            $mapWord = ''
            foreach ($mk in $mapKeys) {
                if ([string]$mk -ceq [string]$ck) {
                    $foundMap = $true
                    try { $mapWord = ([string]$vmapCheck[$mk]).Trim().ToLowerInvariant() } catch { $mapWord = '' }
                    break
                }
            }
            if ((-not [bool]$foundMap) -or ($mapWord -cne [string]$critSlot.statuses[$ck])) {
                return (& $refuse 'PROOF_CRITERION_MAP_MISMATCH')
            }
        }
        $attempts = @()
        try { if ($null -ne $Record['attempts']) { $attempts = @($Record['attempts']) } } catch { $attempts = @() }
        $failedCount = (@($attempts).Count)
        $modelAttempts = @()
        try { if ($null -ne $Record['model_attempts']) { $modelAttempts = @($Record['model_attempts']) } } catch { $modelAttempts = @() }
        $pool = @()
        $poolIdx = @()
        for ($i = 0; $i -lt @($modelAttempts).Count; $i++) {
            if ($i -ge [int]$MaxAttemptIndex) { break }
            try {
                $a = (@($modelAttempts))[$i]
                if ($null -eq $a) { continue }
                $am = ''
                $ap = ''
                $at = ''
                if ($a -is [System.Collections.IDictionary]) {
                    if ($null -ne $a['model']) { $am = ([string]$a['model']).Trim() }
                    if ($null -ne $a['provider']) { $ap = ([string]$a['provider']).Trim() }
                    if ($null -ne $a['tier']) { $at = ([string]$a['tier']).Trim() }
                }
                else { continue }
                if (($am -cne $RequiredModel) -or ($ap -cne $RequiredProvider) -or ($at -cne $RequiredTier)) { continue }
                $pool += $a
                $poolIdx += $i
            }
            catch { }
        }
        if (@($pool).Count -eq 0) {
            return (& $refuse 'PROOF_NO_MODEL_ATTEMPT')
        }
        $cand = $pool[(@($pool).Count - 1)]
        $candPos = [int]$poolIdx[(@($poolIdx).Count - 1)]
        $candN = 0
        $candW = 0
        $candFp = ''
        $candSess = ''
        $candRun = ''
        $candMsg = ''
        $candPol = ''
        try {
            if ($cand -is [System.Collections.IDictionary]) {
                if ($null -ne $cand['attempt_n']) { $candN = [int]$cand['attempt_n'] }
                if ($null -ne $cand['worker_revision']) { $candW = [int]$cand['worker_revision'] }
                if ($null -ne $cand['strategy_fingerprint']) { $candFp = ConvertTo-TaskKernelFingerprint -Value ([string]$cand['strategy_fingerprint']) }
                if ($null -ne $cand['session_id']) { $candSess = ([string]$cand['session_id']).Trim() }
                if ($null -ne $cand['run_id']) { $candRun = ([string]$cand['run_id']).Trim() }
                if ($null -ne $cand['message_id']) { $candMsg = ([string]$cand['message_id']).Trim() }
                if ($null -ne $cand['policy_hash']) { $candPol = ([string]$cand['policy_hash']).Trim().ToLowerInvariant() }
            }
        }
        catch { return (& $refuse 'PROOF_MALFORMED_ATTEMPT') }
        if ([bool]$Head) {
            if (($candW -le 0) -or ($candW -ne $wrev)) {
                return (& $refuse 'PROOF_ATTEMPT_STALE')
            }
        }
        else {
            if (($candW -le 0) -or ($candW -ge [int]$HeadWorkerRevision)) {
                return (& $refuse 'PROOF_ATTEMPT_STALE')
            }
        }
        if ($wstatus -ceq 'failed') {
            if ($failedCount -eq 0) {
                return (& $refuse 'PROOF_NO_FAILED_ATTEMPT')
            }
            $target = $null
            foreach ($a in $attempts) {
                try {
                    $an = [int](Get-TaskKernelAttemptField -Attempt $a -Name 'n')
                    if ($an -eq $candN) { $target = $a; break }
                }
                catch { }
            }
            if (($null -eq $target) -or ($candN -le 0)) {
                return (& $refuse 'PROOF_ATTEMPT_MISMATCH')
            }
            $targetFp = ConvertTo-TaskKernelFingerprint -Value ([string](Get-TaskKernelAttemptField -Attempt $target -Name 'strategy_fingerprint'))
            if ($candFp -cne $targetFp) {
                return (& $refuse 'PROOF_STRATEGY_MISMATCH')
            }
        }
        else {
            if ($candN -ne $failedCount) {
                return (& $refuse 'PROOF_ATTEMPT_MISMATCH')
            }
        }
        if (-not [bool]$Head) {
            $vhistCheck = @()
            try { if ($null -ne $Record['verification_history']) { $vhistCheck = @($Record['verification_history']) } } catch { $vhistCheck = @() }
            $priorFailedHit = $false
            foreach ($vh in $vhistCheck) {
                try {
                    if ($null -eq $vh) { continue }
                    $vhs = ''
                    $vhp = $true
                    $vhc = 0
                    $vhSrc = ''
                    $vhEx = $false
                    if ($vh -is [System.Collections.IDictionary]) {
                        if ($null -ne $vh['status']) { $vhs = ([string]$vh['status']).Trim() }
                        if ($null -ne $vh['passed']) { $vhp = [bool]$vh['passed'] }
                        if ($null -ne $vh['candidate_revision']) { $vhc = [int]$vh['candidate_revision'] }
                        if ($null -ne $vh['verification_source']) { $vhSrc = ([string]$vh['verification_source']).Trim() }
                        if ($null -ne $vh['verifier_executed']) { $vhEx = [bool]$vh['verifier_executed'] }
                    }
                    else { continue }
                    if (($vhs -ceq 'verification_failed') -and (-not [bool]$vhp) -and ($vhc -eq $candW) -and ($candW -gt 0) -and ($vhSrc -ceq 'kernel-executed') -and ([bool]$vhEx)) {
                        $priorFailedHit = $true
                        break
                    }
                }
                catch { }
            }
            if (-not [bool]$priorFailedHit) {
                return (& $refuse 'PROOF_PRIOR_VERIFICATION_NOT_FOUND')
            }
        }
        $runHit = $false
        try {
            $b = $null
            if (($Record -is [System.Collections.IDictionary]) -and $Record.Contains('bindings')) { $b = $Record['bindings'] }
            if (($null -ne $b) -and ($b -is [System.Collections.IDictionary]) -and ($null -ne $b['runs'])) {
                foreach ($r in @($b['runs'])) {
                    if ($null -eq $r) { continue }
                    if ($r -is [System.Collections.IDictionary]) {
                        $rid = ''
                        if ($null -ne $r['run_id']) { $rid = ([string]$r['run_id']).Trim() }
                        if ($rid -cne $candRun) { continue }
                        foreach ($w in @($r['worker_sessions'])) {
                            if ([string]$w -ceq $candSess) { $runHit = $true; break }
                        }
                    }
                    if ([bool]$runHit) { break }
                }
            }
        }
        catch { $runHit = $false }
        if (-not [bool]$runHit) {
            return (& $refuse 'PROOF_SESSION_UNBOUND')
        }
        if ([string]::IsNullOrWhiteSpace($candPol) -or ($candPol -cne ([string]$PolicyHash).Trim().ToLowerInvariant())) {
            return (& $refuse 'PROOF_POLICY_CHANGED')
        }
        if ([bool]$Head) {
            $wClaimedHead = @()
            try { if ($null -ne $wrk['claimed_evidence']) { $wClaimedHead = @($wrk['claimed_evidence']) } } catch { $wClaimedHead = @() }
            $wsRefsHead = @(Get-TaskKernelClaimedRefs -Claimed $wClaimedHead -Prefix 'session:')
            $wmRefsHead = @(Get-TaskKernelClaimedRefs -Claimed $wClaimedHead -Prefix 'message:')
            if ((@($wsRefsHead).Count -ne 1) -or ([string]$wsRefsHead[0] -cne $candSess) -or (@($wmRefsHead) -cnotcontains $candMsg)) {
                return (& $refuse 'PROOF_CANDIDATE_UNCORRELATED')
            }
        }
        $anchorRev = $wrev
        if (-not [bool]$Head) { $anchorRev = $candW }
        $reference = ('modelproof:' + $tid + ':' + $RequiredTier + ':' + ([string]$candN) + ':' + ([string]$anchorRev))
        $canon = ('v1|task=' + (Get-TaskKernelFrame -Text $tid) + '|tier=' + (Get-TaskKernelFrame -Text $RequiredTier) + '|model=' + (Get-TaskKernelFrame -Text $RequiredModel) + '|provider=' + (Get-TaskKernelFrame -Text $RequiredProvider) + '|session=' + (Get-TaskKernelFrame -Text $candSess) + '|message=' + (Get-TaskKernelFrame -Text $candMsg) + '|attempt_n=' + (Get-TaskKernelFrame -Text ([string]$candN)) + '|worker_rev=' + (Get-TaskKernelFrame -Text ([string]$anchorRev)) + '|verification_rev=' + (Get-TaskKernelFrame -Text ([string]$verRev)) + '|policy_hash=' + (Get-TaskKernelFrame -Text ([string]$PolicyHash).Trim().ToLowerInvariant()))
        $digest = ('sha256:' + (Get-TaskKernelStringHash -Text $canon))
        return @{
            ok                   = $true
            error                = ''
            task_id              = $tid
            tier                 = $RequiredTier
            model                = $RequiredModel
            provider             = $RequiredProvider
            attempt_n            = $candN
            attempt_index        = $candPos
            session_id           = $candSess
            run_id               = $candRun
            message_id           = $candMsg
            worker_revision      = $anchorRev
            candidate_revision   = $candRev
            verification_revision = $verRev
            reference            = $reference
            digest               = $digest
            policy_hash          = ([string]$PolicyHash).Trim().ToLowerInvariant()
        }
    }
    catch { return @{ ok = $false; error = 'INTERNAL_ERROR' } }
}

function Get-OrchestrationTaskModelFailureProof {
    <#
    .SYNOPSIS
        Kernel-owned model-failure proof (read-only).
    .DESCRIPTION
        Recomputes from the persisted task record + recorded model_attempts:
        requires verification.status='verification_failed' with
        passed=false, a fresh worker-result candidate revision, the same
        failed attempt/strategy, the actual executed model/provider equal
        to the canonical required T3/T4 primary model from the current policy,
        nonempty criterion
        evidence with at least one unverified criterion, and the bound
        session still present in the recorded run. For T4 Opus, a prior
        valid T3 failure proof on the same task (earlier attempt) is
        required before Astra may be permitted. No dispatch, no
        bool/string proof parameters: only TaskId + RequiredTier. Root
        binding: the persisted verification_repo_root is required; a
        missing stored root fails closed with MODEL_PROOF_ROOT_UNBOUND.
        A nonempty caller -RepoRoot is only an assertion and must match
        the stored root (MODEL_PROOF_ROOT_MISMATCH); an omitted/empty
        caller root uses the stored root for model-policy resolution. No
        migration or rebind for legacy tasks. Returns
        the persisted reference/digest, or fail-closed otherwise. Never
        throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$RequiredTier,
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$PolicyPath = ''
    )
    try {
        $effRoot = ''
        $effRootSlot = Resolve-TaskKernelExplicitRepoRoot -RepoRoot $RepoRoot
        if (-not [bool]$effRootSlot.ok) {
            return (New-TaskKernelError -Code ([string]$effRootSlot.error))
        }
        $effRoot = ([string]$effRootSlot.root)
        $tier = ([string]$RequiredTier).Trim()
        if (($tier -cne 'T3') -and ($tier -cne 'T4')) {
            return (New-TaskKernelError -Code 'INVALID_TIER')
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-TaskKernelId -TaskId $tid)) {
            return (New-TaskKernelError -Code 'INVALID_TASK_ID')
        }
        $taskFile = Get-TaskKernelFilePath -TaskId $tid -TasksDir $TasksDir -RepoRoot $effRoot
        if ([string]::IsNullOrWhiteSpace($taskFile)) {
            return (New-TaskKernelError -Code 'NOT_FOUND')
        }
        $slot = Read-TaskKernelRecord -TaskFile $taskFile
        if (-not [bool]$slot.found) { return (New-TaskKernelError -Code 'NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-TaskKernelError -Code 'MALFORMED') }
        $rec = $slot.record
        $boundRootProof = Get-TaskKernelBoundVerificationRoot -Record $rec -CallerRepoRoot $RepoRoot -UnboundCode 'MODEL_PROOF_ROOT_UNBOUND' -MismatchCode 'MODEL_PROOF_ROOT_MISMATCH'
        if (-not [bool]$boundRootProof.ok) {
            return (New-TaskKernelError -Code ([string]$boundRootProof.error))
        }
        $proofRoot = ([string]$boundRootProof.root)
        $pol = Read-TaskKernelModelPolicy -PolicyPath $PolicyPath -RepoRoot $proofRoot
        if (-not [bool]$pol.ok) {
            return (New-TaskKernelError -Code ([string]$pol.error))
        }
        $canon = Get-TaskKernelCanonicalModelForTier -Policy $pol.policy -Tier $tier
        if (-not [bool]$canon.ok) {
            return (New-TaskKernelError -Code ([string]$canon.error))
        }
        $head = Test-TaskKernelModelFailureProofCore -Record $rec -RequiredTier $tier -Policy $pol.policy -PolicyHash ([string]$pol.policy_hash) -RequiredModel ([string]$canon.model_id) -RequiredProvider ([string]$canon.provider) -Head $true
        if (-not [bool]$head.ok) {
            return (New-TaskKernelError -Code ([string]$head.error))
        }
        if ($tier -ceq 'T4') {
            $canonT3 = Get-TaskKernelCanonicalModelForTier -Policy $pol.policy -Tier 'T3'
            if (-not [bool]$canonT3.ok) {
                return (New-TaskKernelError -Code 'T3_PROOF_REQUIRED' -Extra @{ detail = ([string]$canonT3.error) })
            }
            $prior = Test-TaskKernelModelFailureProofCore -Record $rec -RequiredTier 'T3' -Policy $pol.policy -PolicyHash ([string]$pol.policy_hash) -RequiredModel ([string]$canonT3.model_id) -RequiredProvider ([string]$canonT3.provider) -Head $false -MaxAttemptIndex ([int]$head.attempt_index) -HeadWorkerRevision ([int]$head.worker_revision)
            if (-not [bool]$prior.ok) {
                return (New-TaskKernelError -Code 'T3_PROOF_REQUIRED' -Extra @{ detail = ([string]$prior.error) })
            }
        }
        return [PSCustomObject]@{
            ok                    = $true
            task_id               = ([string]$head.task_id)
            tier                  = ([string]$head.tier)
            model                 = ([string]$head.model)
            provider              = ([string]$head.provider)
            attempt_n             = ([int]$head.attempt_n)
            session_id            = ([string]$head.session_id)
            run_id                = ([string]$head.run_id)
            message_id            = ([string]$head.message_id)
            worker_revision       = ([int]$head.worker_revision)
            candidate_revision    = ([int]$head.candidate_revision)
            verification_revision = ([int]$head.verification_revision)
            reference             = ([string]$head.reference)
            digest                = ([string]$head.digest)
            policy_hash           = ([string]$head.policy_hash)
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}
