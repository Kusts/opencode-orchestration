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
        -Passed value fails closed (VERIFIER_RESULT_MISMATCH).
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
        return $a
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
        [int]$Retries = 20,
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

# ---------- telemetry (best-effort, never blocks) ----------

function Send-TaskKernelTelemetry {
    [CmdletBinding()]
    param([string]$EventType, [string]$TaskId, $Runtime, [string]$TelemetryRoot)
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
        $meta = [ordered]@{
            task_id_hash       = $tidHash
            runtime_id         = $rid
            runtime_generation = $gen
            profile            = $prof
        }
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
        $artifacts = Get-TaskKernelCleanList -Value $ExpectedArtifacts
        if (-not [bool]$artifacts.valid) { return (New-TaskKernelError -Code 'INVALID_ARTIFACTS') }
        $envAllowed = Get-TaskKernelCleanList -Value $EnvironmentAllowed
        if (-not [bool]$envAllowed.valid) { return (New-TaskKernelError -Code 'INVALID_ENVIRONMENTS') }
        $projectCanon = Get-TaskKernelCanonicalText -Text ([string]$Project)
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
        $record = [ordered]@{
            schema_version            = 1
            task_id                   = $tid
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
            worker_result             = $null
            verification              = $null
            review                    = $null
            security_review           = $null
            blockers                  = @()
            residual_risks            = @()
            closure_reason            = ''
            project                   = $projectSafe
            work_fingerprint          = $workFp
            require_typed_waits       = [bool]$RequireTypedWaits
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
        $null = Send-TaskKernelTelemetry -EventType 'TASK_CREATED' -TaskId $tid -Runtime $record['runtime'] -TelemetryRoot $TelemetryRoot
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
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-TaskKernelError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
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

function Set-OrchestrationTaskVerification {
    <#
    .SYNOPSIS
        Records verifier output. NEVER self-attested: -VerifierEvidenceJson
        (parsed Invoke-OrchestrationVerifier result or its JSON string) is
        REQUIRED; Passed derives from its status field and only
        'verified_pass' counts as passed. A legacy -Passed value that
        disagrees with the derived value fails closed
        (VERIFIER_RESULT_MISMATCH).
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
        try {
            if ($vnode -is [System.Collections.IDictionary]) {
                if ($null -ne $vnode['status']) { $vstatus = ([string]$vnode['status']).Trim() }
                if ($null -ne $vnode['evidence']) { $vidence = @($vnode['evidence']) }
                if ($null -ne $vnode['command_classes']) { $vclasses = @($vnode['command_classes']) }
            }
            else {
                $ps = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'status' } | Select-Object -First 1
                if ($null -ne $ps) { $vstatus = ([string]$ps.Value).Trim() }
                $pe = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'evidence' } | Select-Object -First 1
                if ($null -ne $pe) { $vidence = @($pe.Value) }
                $pc = $vnode.PSObject.Properties | Where-Object { $_.Name -ceq 'command_classes' } | Select-Object -First 1
                if ($null -ne $pc) { $vclasses = @($pc.Value) }
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
        $newRev = ([int]$rec['revision'] + 1)
        $rec['verification'] = [ordered]@{
            passed             = $derived
            evidence           = ([string[]]$evClean)
            command_classes    = ([string[]]$cmd.items)
            source             = 'orchestration-verifier'
            result_digest      = $digest
            candidate_revision = $candRev
            at                 = (Get-TaskKernelTimestamp)
            revision           = $newRev
        }
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; passed = $derived }
        }
        finally {
            Exit-TaskKernelFileLock -Handle $lock.handle -LockFile $lock.lockFile
        }
    }
    catch { return (New-TaskKernelError -Code 'INTERNAL_ERROR') }
}

function Set-OrchestrationTaskReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$By,
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
        $newRev = ([int]$rec['revision'] + 1)
        $entry = [ordered]@{
            status             = $status
            by                 = $byClean
            candidate_revision = $candRev
            at                 = (Get-TaskKernelTimestamp)
            revision           = $newRev
        }
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
        complete may proceed. Idempotent: repeats and confirms on a
        never-engaged record succeed without mutation. Planner/build +
        trusted identity + CAS + lock. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Actor,
        [Parameter(Mandatory = $true)][int]$ExpectedRevision,
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
            return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = ([int]$rec['revision']); watchdog_settled = $true; noop = $true }
        }
        $node = $rec['watchdog_interrupt']
        if (($null -eq $node) -or (-not ($node -is [System.Collections.IDictionary]))) {
            return (New-TaskKernelError -Code 'MALFORMED')
        }
        $node['settled'] = $true
        $node['settled_at'] = (Get-TaskKernelTimestamp)
        $newRev = ([int]$rec['revision'] + 1)
        $rec['revision'] = $newRev
        $rec['updated_at'] = (Get-TaskKernelTimestamp)
        $wr = Write-TaskKernelRecord -Record $rec -TaskFile $taskFile
        if (-not [bool]$wr.ok) {
            return (New-TaskKernelError -Code ([string]$wr.error))
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; revision = $newRev; watchdog_settled = $true }
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
        relative to the current worker_result revision. Never throws.
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
        try {
            $ver = $rec['verification']
            if (($null -ne $ver) -and ($ver -is [System.Collections.IDictionary])) {
                if ($null -ne $ver['passed']) { $verPassed = [bool]$ver['passed'] }
                if ($null -ne $ver['evidence']) { $verEvidence = @($ver['evidence']) }
                if ($null -ne $ver['candidate_revision']) { $verCandRev = [int]$ver['candidate_revision'] }
            }
        }
        catch { }
        if (-not $verPassed) {
            $reasons.Add('verification-not-passed') | Out-Null
        }
        elseif (($workerStatus -ceq 'candidate_pass') -and ([int]$verCandRev -ne [int]$workerRev)) {
            $reasons.Add('verification_stale') | Out-Null
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
        $null = Send-TaskKernelTelemetry -EventType 'TASK_DONE' -TaskId $tid -Runtime $rec['runtime'] -TelemetryRoot $TelemetryRoot
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
