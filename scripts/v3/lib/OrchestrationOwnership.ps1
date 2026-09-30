<#!
.SYNOPSIS
    V3 Write Leases: cross-runtime writer ownership (Phase 14).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements write leases
    from ORCHESTRATION-V3.1-KERNEL-HARDENING (plan Phase 14, SPEC section 27):

      - Leases under cache/runtime/locks (override via -LocksDir for tests).
      - One active lease per task: lease-<TaskId>.json (schema v1).
      - Overlap detection is runtime-independent: a V1 task and a V2 task
        conflict when write scopes overlap.
      - Acquire scans FIRST; overlap with a different active task returns
        LEASE_CONFLICT without writing. Same-task re-acquire refreshes.
        Scan+acquire (and release/recovery) serialize under an exclusive
        dir-level lock file (.leases.lock, bounded retry; timeout =>
        LOCK_TIMEOUT) with a re-scan inside the critical section.
      - Malformed lease files are FAIL-CLOSED: mtime within the TTL window
        (default 3600s) counts as an ACTIVE unknown lease => LEASE_CONFLICT
        with reason 'malformed_active_lease'; older malformed files are
        stale and recoverable.
      - Release is ownership-protected; recovery removes only expired or
        stale-malformed lease files, never non-lease files.
      - Flag seam (Phase 19): task_kernel{enabled} read from -FlagsPath
        (default source/registry/capability-flags.json). When disabled,
        acquire returns KERNEL_DISABLED without writing. This file never
        writes capability flags.
      - Telemetry is best-effort via CapabilityObservability (events
        LEASE_ACQUIRED, LEASE_CONFLICT); failure never blocks.
      - Path confinement + reparse-point rejection + atomic write
        (temp + move + post-write hash), UTF-8 no BOM + LF, same pattern
        as OrchestrationTaskKernel / CapabilityAuthority.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects ({ok:$false, error:'CODE'}), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ownershipSchemaPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if (Test-Path -LiteralPath $ownershipSchemaPath -PathType Leaf) {
    . $ownershipSchemaPath
}
$ownershipObservabilityPath = Join-Path $PSScriptRoot 'CapabilityObservability.ps1'
if (Test-Path -LiteralPath $ownershipObservabilityPath -PathType Leaf) {
    . $ownershipObservabilityPath
}

# ---------- repo / path helpers ----------

function Get-OwnershipRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-OwnershipDefaultLocksDir {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-OwnershipRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'cache\runtime\locks')
}

function Get-OwnershipDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-OwnershipRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function Test-OwnershipTaskId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    return ([string]$TaskId -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
}

function Test-OwnershipPathHasReparsePoint {
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

function Get-OwnershipLeaseFilePath {
    <#
    .SYNOPSIS
        Resolves the confined lease file path, or '' when invalid.
    #>
    [CmdletBinding()]
    param([string]$TaskId, [string]$LocksDir, [string]$RepoRoot)
    if (-not (Test-OwnershipTaskId -TaskId $TaskId)) { return '' }
    $dir = $LocksDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-OwnershipDefaultLocksDir -RepoRoot $RepoRoot }
    $fullDir = ''
    $fullFile = ''
    try {
        $fullDir = [IO.Path]::GetFullPath($dir)
        $fullFile = [IO.Path]::GetFullPath((Join-Path $fullDir ('lease-' + [string]$TaskId + '.json')))
    }
    catch { return '' }
    $sep = $fullDir.TrimEnd('\', '/') + '\'
    if (-not $fullFile.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $fullFile
}

function Test-OwnershipWriteBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LeaseFile)
    try {
        $parent = Split-Path -Parent $LeaseFile
        foreach ($p in @($LeaseFile, $parent)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-OwnershipPathHasReparsePoint -Path $p) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-OwnershipStringHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
}

function Get-OwnershipTimestamp {
    [CmdletBinding()]
    param()
    return ((Get-Date).ToUniversalTime().ToString('o'))
}

function New-OwnershipError {
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

function Get-OwnershipFlagState {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $out = @{ enabled = $false; shadow = $false }
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-OwnershipDefaultFlagsPath -RepoRoot $RepoRoot }
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

function ConvertTo-OwnershipOrdered {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return [string]$Node }
    if ($Node -is [bool]) { return [bool]$Node }
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Node.Keys)) {
            $o[[string]$k] = (ConvertTo-OwnershipOrdered -Node $Node[$k])
        }
        return $o
    }
    if ($Node -is [System.ValueType]) { return $Node }
    if ($Node -is [System.Collections.IEnumerable]) {
        $a = @()
        foreach ($e in $Node) { $a += (ConvertTo-OwnershipOrdered -Node $e) }
        return $a
    }
    $o = [ordered]@{}
    foreach ($p in @($Node.PSObject.Properties)) {
        $o[$p.Name] = (ConvertTo-OwnershipOrdered -Node $p.Value)
    }
    return $o
}

function ConvertTo-OwnershipJson {
    [CmdletBinding()]
    param($InputObject)
    try {
        if ((Get-Command ConvertTo-DeterministicJson -ErrorAction SilentlyContinue) -ne $null) {
            return (ConvertTo-DeterministicJson -InputObject $InputObject)
        }
    } catch { }
    try { return ($InputObject | ConvertTo-Json -Depth 16 -Compress) }
    catch { return '' }
}

function Read-OwnershipLeaseRecord {
    <#
    .SYNOPSIS
        Reads a lease file. Returns @{found, malformed, record}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LeaseFile)
    $out = @{ found = $false; malformed = $false; record = $null }
    try {
        if (-not (Test-Path -LiteralPath $LeaseFile -PathType Leaf)) { return $out }
        $out.found = $true
        $text = ''
        try { $text = [IO.File]::ReadAllText($LeaseFile, [Text.UTF8Encoding]::new($false)) }
        catch { $out.malformed = $true; return $out }
        $doc = $null
        try { $doc = ($text | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $doc) { $out.malformed = $true; return $out }
        $rec = ConvertTo-OwnershipOrdered -Node $doc
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary])) { $out.malformed = $true; return $out }
        $out.record = $rec
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Write-OwnershipLeaseRecord {
    <#
    .SYNOPSIS
        Atomic write: temp file in same dir + move + post-write hash check.
        UTF-8 no BOM, LF only. Returns @{ok, error}.
    #>
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory = $true)][string]$LeaseFile)
    try {
        $parent = Split-Path -Parent $LeaseFile
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = ConvertTo-OwnershipJson -InputObject $Record
        if ([string]::IsNullOrWhiteSpace($json)) { return @{ ok = $false; error = 'WRITE_FAILED' } }
        $text = ($json + "`n")
        $tmp = Join-Path $parent (([IO.Path]::GetFileName($LeaseFile)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        try {
            Move-Item -LiteralPath $tmp -Destination $LeaseFile -Force
        }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
            return @{ ok = $false; error = 'WRITE_FAILED' }
        }
        try {
            $back = [IO.File]::ReadAllText($LeaseFile, [Text.UTF8Encoding]::new($false))
            if ((Get-OwnershipStringHash -Text $text) -cne (Get-OwnershipStringHash -Text $back)) {
                return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' }
            }
            $null = ($back | ConvertFrom-Json)
        }
        catch { return @{ ok = $false; error = 'WRITE_VERIFY_FAILED' } }
        return @{ ok = $true; error = '' }
    }
    catch { return @{ ok = $false; error = 'WRITE_FAILED' } }
}

# ---------- telemetry (best-effort, never blocks) ----------

function Send-OwnershipTelemetry {
    [CmdletBinding()]
    param([string]$EventType, [string]$TaskId, [string]$RuntimeId, [string]$RuntimeProfile, [string]$TelemetryRoot)
    try {
        if ((Get-Command New-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        if ((Get-Command Write-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        $tidHash = ''
        try {
            if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -ne $null) {
                $tidHash = Get-LogicalHash -InputObject ([string]$TaskId)
            }
        }
        catch { $tidHash = '' }
        $meta = [ordered]@{
            task_id_hash    = $tidHash
            runtime_id      = ([string]$RuntimeId)
            runtime_profile = ([string]$RuntimeProfile)
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

# ---------- scope helpers ----------

function Get-OwnershipNormalizedScope {
    [CmdletBinding()]
    param([string]$Scope)
    $s = ([string]$Scope).Trim()
    $s = ($s -replace '/', '\')
    while ($s -match '\\\\') { $s = ($s -replace '\\\\', '\') }
    $s = $s.TrimEnd('\')
    return $s
}

function Get-OwnershipCleanScopes {
    <#
    .SYNOPSIS
        Trims string scope lists; returns @{valid, items}. Empty input is valid (@()).
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

function Get-OrchestrationScopeOverlap {
    <#
    .SYNOPSIS
        True when ANY scope pair intersects: equal (case-insensitive, slash
        normalized) or one is a path-prefix of the other at a '\' boundary.
        Empty scope sets never overlap.
    #>
    [CmdletBinding()]
    param($ScopesA, $ScopesB)
    try {
        $a = Get-OwnershipCleanScopes -Value $ScopesA
        $b = Get-OwnershipCleanScopes -Value $ScopesB
        if (-not [bool]$a.valid) { return $false }
        if (-not [bool]$b.valid) { return $false }
        $itemsA = @($a.items)
        $itemsB = @($b.items)
        if ($itemsA.Count -eq 0) { return $false }
        if ($itemsB.Count -eq 0) { return $false }
        $normA = @()
        foreach ($s in $itemsA) { $normA += (Get-OwnershipNormalizedScope -Scope $s) }
        $normB = @()
        foreach ($s in $itemsB) { $normB += (Get-OwnershipNormalizedScope -Scope $s) }
        foreach ($x in $normA) {
            foreach ($y in $normB) {
                if ($x -ieq $y) { return $true }
                if ($x.Length -lt $y.Length) {
                    if ($y.StartsWith($x, [System.StringComparison]::OrdinalIgnoreCase) -and $y[$x.Length] -ceq '\') { return $true }
                }
                elseif ($y.Length -lt $x.Length) {
                    if ($x.StartsWith($y, [System.StringComparison]::OrdinalIgnoreCase) -and $x[$y.Length] -ceq '\') { return $true }
                }
            }
        }
        return $false
    }
    catch { return $false }
}

function Test-OwnershipLeaseActive {
    [CmdletBinding()]
    param($Record)
    try {
        if ($null -eq $Record) { return $false }
        if (-not ($Record -is [System.Collections.IDictionary])) { return $false }
        if (-not $Record.Contains('expires_at')) { return $false }
        $raw = [string]$Record['expires_at']
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $when = [DateTime]::MinValue
        try { $when = [DateTime]::Parse($raw, $null, [Globalization.DateTimeStyles]::RoundtripKind) }
        catch { return $false }
        return ($when.ToUniversalTime() -gt (Get-Date).ToUniversalTime())
    }
    catch { return $false }
}

function Get-OwnershipLeaseScopes {
    [CmdletBinding()]
    param($Record)
    try {
        if ($null -eq $Record) { return ([string[]]@()) }
        if (-not ($Record -is [System.Collections.IDictionary])) { return ([string[]]@()) }
        if (-not $Record.Contains('write_scopes')) { return ([string[]]@()) }
        $clean = Get-OwnershipCleanScopes -Value $Record['write_scopes']
        if (-not [bool]$clean.valid) { return ([string[]]@()) }
        return ([string[]]$clean.items)
    }
    catch { return ([string[]]@()) }
}

function Test-OwnershipLeaseScopesShape {
    <#
    .SYNOPSIS
        Strict shape check for write_scopes in a parsed lease record.
        Returns @{hasKey, valid, items}. Valid includes genuinely empty
        array (no conflict) and single scalar string (PS 5.1 unwrapping).
        Null value with key present is treated as valid-empty (empty array
        round-trips to null in PS 5.1). Missing key or non-string entries
        or blank entries => valid $false (caller fail-closes when active).
        Never throws.
    #>
    [CmdletBinding()]
    param($Record)
    $out = @{ hasKey = $false; valid = $false; items = ([string[]]@()) }
    try {
        if ($null -eq $Record) { return $out }
        if (-not ($Record -is [System.Collections.IDictionary])) { return $out }
        if (-not $Record.Contains('write_scopes')) { return $out }
        $out.hasKey = $true
        $raw = $Record['write_scopes']
        if ($null -eq $raw) {
            $out.valid = $true
            $out.items = ([string[]]@())
            return $out
        }
        if ($raw -is [string]) {
            $t = ([string]$raw).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { return $out }
            $out.valid = $true
            $out.items = ([string[]]@($t))
            return $out
        }
        if (($raw -is [System.Collections.IDictionary]) -or ($raw -is [System.Management.Automation.PSObject] -and -not ($raw -is [System.Collections.IEnumerable]))) {
            return $out
        }
        if ($raw -is [System.Collections.IEnumerable]) {
            $list = New-Object System.Collections.Generic.List[string]
            $count = 0
            foreach ($e in @($raw)) {
                $count++
                if (-not ($e -is [string])) { return $out }
                $t = ([string]$e).Trim()
                if ([string]::IsNullOrWhiteSpace($t)) { return $out }
                $list.Add($t) | Out-Null
            }
            $out.valid = $true
            $out.items = ([string[]]$list.ToArray())
            return $out
        }
        return $out
    }
    catch { return $out }
}

function Get-OwnershipLocksDirFull {
    [CmdletBinding()]
    param([string]$LocksDir, [string]$RepoRoot)
    $dir = $LocksDir
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-OwnershipDefaultLocksDir -RepoRoot $RepoRoot }
    try { return ([IO.Path]::GetFullPath($dir)) }
    catch { return '' }
}

function Get-OwnershipLeaseFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LocksDirFull)
    try {
        if (-not (Test-Path -LiteralPath $LocksDirFull -PathType Container)) { return @() }
        return @(Get-ChildItem -LiteralPath $LocksDirFull -File -Filter 'lease-*.json' -ErrorAction SilentlyContinue)
    }
    catch { return @() }
}

# ---------- lease operations ----------

function Enter-OwnershipDirLock {
    <#
    .SYNOPSIS
        Exclusive dir-level lock (<LocksDir>\.leases.lock) with bounded
        retry (20 x 100ms). Returns @{acquired, handle, lockFile}.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LocksDirFull,
        [int]$Retries = 20,
        [int]$DelayMs = 100
    )
    $out = @{ acquired = $false; handle = $null; lockFile = (Join-Path ([string]$LocksDirFull) '.leases.lock') }
    try {
        New-Item -ItemType Directory -Path ([string]$LocksDirFull) -Force | Out-Null
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

function Exit-OwnershipDirLock {
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

function Test-OwnershipLeaseFileFresh {
    <#
    .SYNOPSIS
        True when the lease file mtime is within the TTL window (fail-closed
        freshness for malformed files). Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeaseFile,
        [int]$TtlSeconds = 3600
    )
    try {
        $item = Get-Item -LiteralPath $LeaseFile -Force -ErrorAction Stop
        $mtime = $item.LastWriteTimeUtc
        $ttl = [int]$TtlSeconds
        if ($ttl -lt 1) { $ttl = 3600 }
        return (((Get-Date).ToUniversalTime() - $mtime).TotalSeconds -le [double]$ttl)
    }
    catch { return $true }
}

function New-OrchestrationWriteLease {
    <#
    .SYNOPSIS
        Acquires a write lease after a conflict scan. Overlap with a
        different ACTIVE task returns LEASE_CONFLICT without writing.
        Same-task re-acquire refreshes expiry (idempotent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$RuntimeId,
        [Parameter(Mandatory = $true)][string]$RuntimeProfile,
        [string[]]$WriteScopes = @(),
        [string]$BaseSha = '',
        [string]$LocksDir = '',
        [int]$TtlSeconds = 3600,
        [string]$FlagsPath = '',
        [string]$RepoRoot = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-OwnershipFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-OwnershipError -Code 'KERNEL_DISABLED' -Extra @{ shadow = [bool]$flags.shadow })
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-OwnershipTaskId -TaskId $tid)) {
            return (New-OwnershipError -Code 'INVALID_TASK_ID')
        }
        $rid = ([string]$RuntimeId).Trim()
        if ([string]::IsNullOrWhiteSpace($rid)) {
            return (New-OwnershipError -Code 'INVALID_RUNTIME')
        }
        $prof = ([string]$RuntimeProfile).Trim()
        if ([string]::IsNullOrWhiteSpace($prof)) {
            return (New-OwnershipError -Code 'INVALID_RUNTIME')
        }
        if ([int]$TtlSeconds -lt 1 -or [int]$TtlSeconds -gt 86400) {
            return (New-OwnershipError -Code 'INVALID_TTL')
        }
        $scopes = Get-OwnershipCleanScopes -Value $WriteScopes
        if (-not [bool]$scopes.valid) { return (New-OwnershipError -Code 'INVALID_SCOPES') }
        $leaseFile = Get-OwnershipLeaseFilePath -TaskId $tid -LocksDir $LocksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($leaseFile)) {
            return (New-OwnershipError -Code 'INVALID_TASK_ID')
        }
        if (-not (Test-OwnershipWriteBoundary -LeaseFile $leaseFile)) {
            return (New-OwnershipError -Code 'PATH_NOT_CONFINED')
        }
        $dirFull = Get-OwnershipLocksDirFull -LocksDir $LocksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dirFull)) {
            return (New-OwnershipError -Code 'INVALID_LOCKS_DIR')
        }
        if (Test-OwnershipPathHasReparsePoint -Path $dirFull) {
            return (New-OwnershipError -Code 'PATH_NOT_CONFINED')
        }
        $dirLock = Enter-OwnershipDirLock -LocksDirFull $dirFull
        if (-not [bool]$dirLock.acquired) {
            return (New-OwnershipError -Code 'LOCK_TIMEOUT')
        }
        try {
        # Conflict scan FIRST: every existing lease file is parsed.
        # Re-scanned INSIDE the dir lock. Malformed files are FAIL-CLOSED:
        # mtime within the TTL window => ACTIVE unknown lease (conflict);
        # older => stale (recoverable, skipped here).
        $conflicts = New-Object System.Collections.ArrayList
        $malformedActive = New-Object System.Collections.ArrayList
        $warnings = New-Object System.Collections.Generic.List[string]
        foreach ($f in @(Get-OwnershipLeaseFiles -LocksDirFull $dirFull)) {
            $slot = Read-OwnershipLeaseRecord -LeaseFile $f.FullName
            if (-not [bool]$slot.found) { continue }
            if ([bool]$slot.malformed) {
                if (Test-OwnershipLeaseFileFresh -LeaseFile $f.FullName -TtlSeconds ([int]$TtlSeconds)) {
                    [void]$malformedActive.Add($f.Name)
                }
                else {
                    $warnings.Add(('stale-recoverable:' + $f.Name)) | Out-Null
                }
                continue
            }
            $rec = $slot.record
            $otherId = ''
            try { $otherId = ([string]$rec['task_id']).Trim() } catch { $otherId = '' }
            if ([string]::IsNullOrWhiteSpace($otherId)) {
                if (Test-OwnershipLeaseFileFresh -LeaseFile $f.FullName -TtlSeconds ([int]$TtlSeconds)) {
                    [void]$malformedActive.Add($f.Name)
                }
                else {
                    $warnings.Add(('stale-recoverable:' + $f.Name)) | Out-Null
                }
                continue
            }
            if ($otherId -ceq $tid) { continue }
            if (-not (Test-OwnershipLeaseActive -Record $rec)) { continue }
            $shape = Test-OwnershipLeaseScopesShape -Record $rec
            if ((-not [bool]$shape.hasKey) -or (-not [bool]$shape.valid)) {
                [void]$malformedActive.Add($f.Name)
                continue
            }
            $otherScopes = ([string[]]$shape.items)
            if (Get-OrchestrationScopeOverlap -ScopesA ([string[]]$scopes.items) -ScopesB $otherScopes) {
                $lid = ''
                try { $lid = [string]$rec['lease_id'] } catch { $lid = '' }
                if ([string]::IsNullOrWhiteSpace($lid)) { $lid = ('lease-' + $otherId) }
                [void]$conflicts.Add($lid)
            }
        }
        if ($malformedActive.Count -gt 0) {
            $arr = ([string[]]$malformedActive.ToArray())
            [Array]::Sort($arr, [System.StringComparer]::Ordinal)
            $null = Send-OwnershipTelemetry -EventType 'LEASE_CONFLICT' -TaskId $tid -RuntimeId $rid -RuntimeProfile $prof -TelemetryRoot $TelemetryRoot
            return (New-OwnershipError -Code 'LEASE_CONFLICT' -Extra @{ reason = 'malformed_active_lease'; conflicting_with = $arr })
        }
        if ($conflicts.Count -gt 0) {
            $arr = ([string[]]$conflicts.ToArray())
            [Array]::Sort($arr, [System.StringComparer]::Ordinal)
            $null = Send-OwnershipTelemetry -EventType 'LEASE_CONFLICT' -TaskId $tid -RuntimeId $rid -RuntimeProfile $prof -TelemetryRoot $TelemetryRoot
            return (New-OwnershipError -Code 'LEASE_CONFLICT' -Extra @{ conflicting_with = $arr })
        }
        $now = (Get-Date).ToUniversalTime()
        $acquiredAt = $now.ToString('o')
        $expiresAt = ($now.AddSeconds([int]$TtlSeconds)).ToString('o')
        $ownerPid = 0
        try { $ownerPid = $PID } catch { $ownerPid = 0 }
        # Same-task re-acquire: idempotent refresh, bump revision.
        $revision = 1
        $ownSlot = Read-OwnershipLeaseRecord -LeaseFile $leaseFile
        if ([bool]$ownSlot.found -and -not [bool]$ownSlot.malformed) {
            try { $revision = ([int]$ownSlot.record['revision'] + 1) } catch { $revision = 1 }
            if ($revision -lt 1) { $revision = 1 }
        }
        $record = [ordered]@{
            schema_version  = 1
            lease_id        = ('lease-' + $tid)
            task_id         = $tid
            runtime_id      = $rid
            runtime_profile = $prof
            base_sha        = ([string]$BaseSha).Trim()
            write_scopes    = ([string[]]$scopes.items)
            acquired_at     = $acquiredAt
            expires_at      = $expiresAt
            owner_pid       = [int]$ownerPid
            revision        = [int]$revision
        }
        $wr = Write-OwnershipLeaseRecord -Record $record -LeaseFile $leaseFile
        if (-not [bool]$wr.ok) {
            return (New-OwnershipError -Code ([string]$wr.error))
        }
        $null = Send-OwnershipTelemetry -EventType 'LEASE_ACQUIRED' -TaskId $tid -RuntimeId $rid -RuntimeProfile $prof -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{
            ok              = $true
            lease_id        = ('lease-' + $tid)
            task_id         = $tid
            runtime_id      = $rid
            runtime_profile = $prof
            expires_at      = $expiresAt
            revision        = [int]$revision
        }
        }
        finally {
            Exit-OwnershipDirLock -Handle $dirLock.handle -LockFile $dirLock.lockFile
        }
    }
    catch { return (New-OwnershipError -Code 'INTERNAL_ERROR') }
}

function Release-OrchestrationWriteLease {
    <#
    .SYNOPSIS
        Ownership-protected release: deletes only the exact lease file for
        the given task. Wrong task id => LEASE_OWNERSHIP_DENIED, no deletion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$LocksDir = '',
        [string]$RepoRoot = '',
        [string]$ActorIdentitySource = 'unknown'
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $leaseFile = Get-OwnershipLeaseFilePath -TaskId $tid -LocksDir $LocksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($leaseFile)) {
            return (New-OwnershipError -Code 'INVALID_TASK_ID')
        }
        if (-not (Test-OwnershipWriteBoundary -LeaseFile $leaseFile)) {
            return (New-OwnershipError -Code 'PATH_NOT_CONFINED')
        }
        $dirFull = Get-OwnershipLocksDirFull -LocksDir $LocksDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dirFull)) {
            return (New-OwnershipError -Code 'INVALID_LOCKS_DIR')
        }
        $dirLock = Enter-OwnershipDirLock -LocksDirFull $dirFull
        if (-not [bool]$dirLock.acquired) {
            return (New-OwnershipError -Code 'LOCK_TIMEOUT')
        }
        try {
        $slot = Read-OwnershipLeaseRecord -LeaseFile $leaseFile
        if (-not [bool]$slot.found) { return (New-OwnershipError -Code 'LEASE_NOT_FOUND') }
        if ([bool]$slot.malformed) { return (New-OwnershipError -Code 'MALFORMED') }
        $fileTaskId = ''
        try { $fileTaskId = ([string]$slot.record['task_id']).Trim() } catch { $fileTaskId = '' }
        if ($fileTaskId -cne $tid) {
            return (New-OwnershipError -Code 'LEASE_OWNERSHIP_DENIED')
        }
        try {
            Remove-Item -LiteralPath $leaseFile -Force -ErrorAction Stop
        }
        catch { return (New-OwnershipError -Code 'RELEASE_FAILED') }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; lease_id = ('lease-' + $tid) }
        }
        finally {
            Exit-OwnershipDirLock -Handle $dirLock.handle -LockFile $dirLock.lockFile
        }
    }
    catch { return (New-OwnershipError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationActiveLeases {
    <#
    .SYNOPSIS
        Lists active (non-expired, well-formed) leases plus warnings for
        malformed files. Never throws.
    #>
    [CmdletBinding()]
    param([string]$LocksDir = '', [string]$RepoRoot = '')
    try {
        $dirFull = Get-OwnershipLocksDirFull -LocksDir $LocksDir -RepoRoot $RepoRoot
        $leases = New-Object System.Collections.ArrayList
        $warnings = New-Object System.Collections.Generic.List[string]
        if ([string]::IsNullOrWhiteSpace($dirFull)) {
            return [PSCustomObject]@{ ok = $true; leases = ([object[]]@()); warnings = ([string[]]@('invalid-locks-dir')) }
        }
        foreach ($f in @(Get-OwnershipLeaseFiles -LocksDirFull $dirFull)) {
            $slot = Read-OwnershipLeaseRecord -LeaseFile $f.FullName
            if (-not [bool]$slot.found) { continue }
            if ([bool]$slot.malformed) {
                $warnings.Add(('malformed:' + $f.Name)) | Out-Null
                continue
            }
            if (-not (Test-OwnershipLeaseActive -Record $slot.record)) { continue }
            [void]$leases.Add($slot.record)
        }
        return [PSCustomObject]@{
            ok       = $true
            leases   = ([object[]]$leases.ToArray())
            warnings = ([string[]]$warnings.ToArray())
        }
    }
    catch { return (New-OwnershipError -Code 'INTERNAL_ERROR') }
}

function Invoke-OrchestrationLeaseRecovery {
    <#
    .SYNOPSIS
        Removes ONLY expired or malformed lease-*.json files. Never touches
        non-lease files. Returns {removed, kept, warnings}.
    #>
    [CmdletBinding()]
    param([string]$LocksDir = '', [string]$RepoRoot = '', [int]$TtlSeconds = 3600)
    try {
        $dirFull = Get-OwnershipLocksDirFull -LocksDir $LocksDir -RepoRoot $RepoRoot
        $removed = New-Object System.Collections.Generic.List[string]
        $kept = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        if ([string]::IsNullOrWhiteSpace($dirFull)) {
            return [PSCustomObject]@{ ok = $true; removed = ([string[]]@()); kept = ([string[]]@()); warnings = ([string[]]@('invalid-locks-dir')) }
        }
        if (-not (Test-Path -LiteralPath $dirFull -PathType Container)) {
            return [PSCustomObject]@{ ok = $true; removed = ([string[]]@()); kept = ([string[]]@()); warnings = ([string[]]@()) }
        }
        if (Test-OwnershipPathHasReparsePoint -Path $dirFull) {
            return (New-OwnershipError -Code 'PATH_NOT_CONFINED')
        }
        $dirLock = Enter-OwnershipDirLock -LocksDirFull $dirFull
        if (-not [bool]$dirLock.acquired) {
            return (New-OwnershipError -Code 'LOCK_TIMEOUT')
        }
        try {
        foreach ($f in @(Get-OwnershipLeaseFiles -LocksDirFull $dirFull)) {
            $slot = Read-OwnershipLeaseRecord -LeaseFile $f.FullName
            if (-not [bool]$slot.found) { continue }
            if ([bool]$slot.malformed) {
                if (Test-OwnershipLeaseFileFresh -LeaseFile $f.FullName -TtlSeconds ([int]$TtlSeconds)) {
                    $kept.Add($f.Name) | Out-Null
                    $warnings.Add(('kept-malformed-active:' + $f.Name)) | Out-Null
                    continue
                }
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $removed.Add($f.Name) | Out-Null
                    $warnings.Add(('removed-malformed:' + $f.Name)) | Out-Null
                }
                catch { $warnings.Add(('remove-failed:' + $f.Name)) | Out-Null }
                continue
            }
            if (Test-OwnershipLeaseActive -Record $slot.record) {
                $lid = ''
                try { $lid = [string]$slot.record['lease_id'] } catch { $lid = '' }
                if ([string]::IsNullOrWhiteSpace($lid)) { $lid = $f.Name }
                $kept.Add($lid) | Out-Null
                continue
            }
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $removed.Add($f.Name) | Out-Null
            }
            catch { $warnings.Add(('remove-failed:' + $f.Name)) | Out-Null }
        }
        return [PSCustomObject]@{
            ok       = $true
            removed  = ([string[]]$removed.ToArray())
            kept     = ([string[]]$kept.ToArray())
            warnings = ([string[]]$warnings.ToArray())
        }
        }
        finally {
            Exit-OwnershipDirLock -Handle $dirLock.handle -LockFile $dirLock.lockFile
        }
    }
    catch { return (New-OwnershipError -Code 'INTERNAL_ERROR') }
}
