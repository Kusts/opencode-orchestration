<#!
.SYNOPSIS
    V3 Worktree isolation: task-owned parallel writer directories (Phase 15).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements task-scoped
    worktrees from ORCHESTRATION-V3.1-KERNEL-HARDENING (plan Phase 15, SPEC
    section 28):

      - Default root <repo>/cache/runtime/worktrees/<TASK_ID> (override via
        -WorktreesRoot for tests).
      - Deterministic branch name 'orchestration/<task-id>'.
      - TaskId validated with the SAME regex as the task kernel
        (^[a-z0-9][a-z0-9._-]{2,63}$).
      - Idempotent create: existing path with a matching marker returns the
        existing worktree without error.
      - Ownership-aware removal: marker missing or task_id mismatch returns
        WORKTREE_NOT_OWNED and does NOTHING (no git worktree remove --force
        on unowned paths, no Remove-Item of unowned directories). Branch is
        deleted only with -DeleteBranch and only when the branch name
        matches 'orchestration/<task-id>'.
      - Flag seam (Phase 19): worktree_isolation{enabled} read from
        -FlagsPath (default source/registry/capability-flags.json). When
        disabled, create returns WORKTREE_ISOLATION_DISABLED without
        invoking git. This file never writes capability flags.
      - Git missing/unavailable returns GIT_UNAVAILABLE, never throws.
      - Marker file .orchestration-worktree.json is written atomically
        (UTF-8 no BOM) inside the worktree.
      - Telemetry is best-effort via CapabilityObservability (event
        WORKTREE_CREATED); failure never blocks.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects ({ok:$false, error:'CODE'}), never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$worktreeSchemaPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if (Test-Path -LiteralPath $worktreeSchemaPath -PathType Leaf) {
    . $worktreeSchemaPath
}
$worktreeObservabilityPath = Join-Path $PSScriptRoot 'CapabilityObservability.ps1'
if (Test-Path -LiteralPath $worktreeObservabilityPath -PathType Leaf) {
    . $worktreeObservabilityPath
}

# ---------- repo / path helpers ----------

function Get-WorktreeRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-WorktreeDefaultRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-WorktreeRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'cache\runtime\worktrees')
}

function Get-WorktreeDefaultFlagsPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-WorktreeRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-flags.json')
}

function Test-OrchestrationWorktreeTaskId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    return ([string]$TaskId -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
}

function Get-OrchestrationWorktreeBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskId)
    return ('orchestration/' + [string]$TaskId)
}

function Test-WorktreePathHasReparsePoint {
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

function Get-OrchestrationWorktreePath {
    <#
    .SYNOPSIS
        Resolves the deterministic confined worktree path, or '' when invalid.
    #>
    [CmdletBinding()]
    param([string]$TaskId, [string]$WorktreesRoot, [string]$RepoRoot)
    if (-not (Test-OrchestrationWorktreeTaskId -TaskId $TaskId)) { return '' }
    $root = $WorktreesRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-WorktreeDefaultRoot -RepoRoot $RepoRoot }
    $fullRoot = ''
    $fullPath = ''
    try {
        $fullRoot = [IO.Path]::GetFullPath($root)
        $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot ([string]$TaskId).Trim()))
    }
    catch { return '' }
    $sep = $fullRoot.TrimEnd('\', '/') + '\'
    if (-not $fullPath.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $fullPath
}

function Get-OrchestrationWorktreeMarkerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorktreePath)
    return (Join-Path $WorktreePath '.orchestration-worktree.json')
}

function New-WorktreeError {
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

function Get-WorktreeTimestamp {
    [CmdletBinding()]
    param()
    return ((Get-Date).ToUniversalTime().ToString('o'))
}

# ---------- flags (Phase 19 seam, read-only) ----------

function Get-WorktreeFlagState {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $out = @{ enabled = $false }
    try {
        $p = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-WorktreeDefaultFlagsPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $out }
        $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        if ($null -eq $doc) { return $out }
        $wi = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('worktree_isolation')) { $wi = $doc['worktree_isolation'] }
        }
        else {
            $prop = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'worktree_isolation' } | Select-Object -First 1
            if ($null -ne $prop) { $wi = $prop.Value }
        }
        if ($null -eq $wi) { return $out }
        $slot = $null
        if ($wi -is [System.Collections.IDictionary]) {
            if ($wi.Contains('enabled')) { $slot = $wi['enabled'] }
        }
        else {
            $fp = $wi.PSObject.Properties | Where-Object { $_.Name -ceq 'enabled' } | Select-Object -First 1
            if ($null -ne $fp) { $slot = $fp.Value }
        }
        if (($null -ne $slot) -and ($slot -is [bool])) { $out.enabled = [bool]$slot }
    }
    catch { return $out }
    return $out
}

# ---------- marker IO ----------

function ConvertTo-WorktreeOrdered {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return [string]$Node }
    if ($Node -is [bool]) { return [bool]$Node }
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Node.Keys)) {
            $o[[string]$k] = (ConvertTo-WorktreeOrdered -Node $Node[$k])
        }
        return $o
    }
    if ($Node -is [System.ValueType]) { return $Node }
    if ($Node -is [System.Collections.IEnumerable]) {
        $a = @()
        foreach ($e in $Node) { $a += (ConvertTo-WorktreeOrdered -Node $e) }
        return $a
    }
    $o = [ordered]@{}
    foreach ($p in @($Node.PSObject.Properties)) {
        $o[$p.Name] = (ConvertTo-WorktreeOrdered -Node $p.Value)
    }
    return $o
}

function ConvertTo-WorktreeJson {
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

function Read-WorktreeMarker {
    <#
    .SYNOPSIS
        Reads the marker file. Returns @{found, malformed, marker}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorktreePath)
    $out = @{ found = $false; malformed = $false; marker = $null }
    try {
        $mp = Get-OrchestrationWorktreeMarkerPath -WorktreePath $WorktreePath
        if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) { return $out }
        $out.found = $true
        $text = ''
        try { $text = [IO.File]::ReadAllText($mp, [Text.UTF8Encoding]::new($false)) }
        catch { $out.malformed = $true; return $out }
        $doc = $null
        try { $doc = ($text | ConvertFrom-Json) }
        catch { $out.malformed = $true; return $out }
        if ($null -eq $doc) { $out.malformed = $true; return $out }
        $rec = ConvertTo-WorktreeOrdered -Node $doc
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary])) { $out.malformed = $true; return $out }
        $out.marker = $rec
        return $out
    }
    catch { $out.malformed = $true; return $out }
}

function Write-WorktreeMarker {
    <#
    .SYNOPSIS
        Atomic marker write inside the worktree: temp + move. UTF-8 no BOM.
        Returns @{ok, error}.
    #>
    [CmdletBinding()]
    param($Marker, [Parameter(Mandatory = $true)][string]$WorktreePath)
    try {
        $mp = Get-OrchestrationWorktreeMarkerPath -WorktreePath $WorktreePath
        $json = ConvertTo-WorktreeJson -InputObject $Marker
        if ([string]::IsNullOrWhiteSpace($json)) { return @{ ok = $false; error = 'WRITE_FAILED' } }
        $text = (($json -replace "`r`n", "`n" -replace "`r", "`n") + "`n")
        $tmp = $mp + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        try {
            Move-Item -LiteralPath $tmp -Destination $mp -Force
        }
        catch {
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
            return @{ ok = $false; error = 'WRITE_FAILED' }
        }
        return @{ ok = $true; error = '' }
    }
    catch { return @{ ok = $false; error = 'WRITE_FAILED' } }
}

# ---------- git ----------

function Test-WorktreeGitAvailable {
    [CmdletBinding()]
    param()
    try {
        $cmd = Get-Command git -ErrorAction SilentlyContinue
        return ($null -ne $cmd)
    }
    catch { return $false }
}

function Invoke-WorktreeGit {
    <#
    .SYNOPSIS
        Runs git -C <dir> <args>. Returns @{ok, code, output}. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepoDir, [string[]]$GitArgs)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $all = New-Object System.Collections.Generic.List[string]
        $all.Add('-C') | Out-Null
        $all.Add($RepoDir) | Out-Null
        foreach ($a in @($GitArgs)) { $all.Add([string]$a) | Out-Null }
        $psi.Arguments = (($all.ToArray() | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $RepoDir
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $done = $p.WaitForExit(120000)
        if (-not $done) {
            try { $p.Kill() } catch { }
            return @{ ok = $false; code = -1; output = 'git-timeout' }
        }
        $code = $p.ExitCode
        try { $p.Close() } catch { }
        return @{ ok = ($code -eq 0); code = $code; output = ([string]$stdout + "`n" + [string]$stderr) }
    }
    catch { return @{ ok = $false; code = -1; output = 'git-unavailable' } }
}

function Send-WorktreeTelemetry {
    [CmdletBinding()]
    param([string]$EventType, [string]$TaskId, [string]$TelemetryRoot)
    try {
        if ((Get-Command New-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        if ((Get-Command Write-ObservabilityEvent -ErrorAction SilentlyContinue) -eq $null) { return $false }
        $ev = New-ObservabilityEvent -TaskId ([string]$TaskId) -EventType ([string]$EventType)
        if ($null -eq $ev) { return $false }
        if ([string]::IsNullOrWhiteSpace($TelemetryRoot)) {
            return ([bool](Write-ObservabilityEvent -Event $ev))
        }
        return ([bool](Write-ObservabilityEvent -Event $ev -RepoRoot ([string]$TelemetryRoot)))
    }
    catch { return $false }
}

# ---------- worktree operations ----------

function New-OrchestrationWorktree {
    <#
    .SYNOPSIS
        Creates the task-owned worktree (idempotent on matching marker).
        Never throws; git problems return GIT_UNAVAILABLE / GIT_FAILED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$BaseRevision = 'HEAD',
        [string]$WorktreesRoot = '',
        [string]$FlagsPath = '',
        [string]$TelemetryRoot = ''
    )
    try {
        $flags = Get-WorktreeFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot
        if (-not [bool]$flags.enabled) {
            return (New-WorktreeError -Code 'WORKTREE_ISOLATION_DISABLED')
        }
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-OrchestrationWorktreeTaskId -TaskId $tid)) {
            return (New-WorktreeError -Code 'INVALID_TASK_ID')
        }
        if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
            return (New-WorktreeError -Code 'INVALID_REPO_ROOT')
        }
        $repoFull = ''
        try { $repoFull = [IO.Path]::GetFullPath($RepoRoot) }
        catch { return (New-WorktreeError -Code 'INVALID_REPO_ROOT') }
        $wtPath = Get-OrchestrationWorktreePath -TaskId $tid -WorktreesRoot $WorktreesRoot -RepoRoot $repoFull
        if ([string]::IsNullOrWhiteSpace($wtPath)) {
            return (New-WorktreeError -Code 'INVALID_TASK_ID')
        }
        foreach ($p in @($wtPath, (Split-Path -Parent $wtPath))) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-WorktreePathHasReparsePoint -Path $p) {
                return (New-WorktreeError -Code 'PATH_NOT_CONFINED')
            }
        }
        $base = ([string]$BaseRevision).Trim()
        if ([string]::IsNullOrWhiteSpace($base)) { $base = 'HEAD' }
        $branch = Get-OrchestrationWorktreeBranch -TaskId $tid
        # Idempotent: existing path with a matching marker returns as-is.
        if (Test-Path -LiteralPath $wtPath) {
            $slot = Read-WorktreeMarker -WorktreePath $wtPath
            if ([bool]$slot.found -and -not [bool]$slot.malformed) {
                $mtid = ''
                try { $mtid = ([string]$slot.marker['task_id']).Trim() } catch { $mtid = '' }
                if ($mtid -ceq $tid) {
                    $mbranch = ''
                    try { $mbranch = [string]$slot.marker['branch'] } catch { $mbranch = '' }
                    if ([string]::IsNullOrWhiteSpace($mbranch)) { $mbranch = $branch }
                    return [PSCustomObject]@{ ok = $true; task_id = $tid; path = $wtPath; branch = $mbranch; existing = $true }
                }
                return (New-WorktreeError -Code 'WORKTREE_PATH_CONFLICT' -Extra @{ path = $wtPath })
            }
            return (New-WorktreeError -Code 'WORKTREE_PATH_CONFLICT' -Extra @{ path = $wtPath })
        }
        if (-not (Test-WorktreeGitAvailable)) {
            return (New-WorktreeError -Code 'GIT_UNAVAILABLE')
        }
        $parent = Split-Path -Parent $wtPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $add = Invoke-WorktreeGit -RepoDir $repoFull -GitArgs @('worktree', 'add', '--quiet', $wtPath, '-b', $branch, $base)
        if (-not [bool]$add.ok) {
            # Branch may already exist: retry attaching the existing branch.
            $retry = Invoke-WorktreeGit -RepoDir $repoFull -GitArgs @('worktree', 'add', '--quiet', $wtPath, $branch)
            if (-not [bool]$retry.ok) {
                return (New-WorktreeError -Code 'GIT_FAILED' -Extra @{ detail = ('git worktree add exit ' + [string]$retry.code) })
            }
        }
        if (-not (Test-Path -LiteralPath $wtPath -PathType Container)) {
            return (New-WorktreeError -Code 'GIT_FAILED' -Extra @{ detail = 'worktree path missing after git worktree add' })
        }
        $repoHash = ''
        try {
            if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -ne $null) {
                $repoHash = Get-LogicalHash -InputObject $repoFull
            }
        }
        catch { $repoHash = '' }
        $marker = [ordered]@{
            schema_version = 1
            task_id        = $tid
            branch         = $branch
            base_revision  = $base
            created_at     = (Get-WorktreeTimestamp)
            created_by     = 'task-kernel'
            repo_root_hash = $repoHash
        }
        $mw = Write-WorktreeMarker -Marker $marker -WorktreePath $wtPath
        if (-not [bool]$mw.ok) {
            return (New-WorktreeError -Code ([string]$mw.error))
        }
        $null = Send-WorktreeTelemetry -EventType 'WORKTREE_CREATED' -TaskId $tid -TelemetryRoot $TelemetryRoot
        return [PSCustomObject]@{ ok = $true; task_id = $tid; path = $wtPath; branch = $branch; existing = $false }
    }
    catch { return (New-WorktreeError -Code 'INTERNAL_ERROR') }
}

function Get-OrchestrationWorktree {
    <#
    .SYNOPSIS
        Returns path + branch + marker info, or NOT_FOUND. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$WorktreesRoot = '',
        [string]$RepoRoot = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $wtPath = Get-OrchestrationWorktreePath -TaskId $tid -WorktreesRoot $WorktreesRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($wtPath)) {
            return (New-WorktreeError -Code 'NOT_FOUND')
        }
        if (-not (Test-Path -LiteralPath $wtPath -PathType Container)) {
            return (New-WorktreeError -Code 'NOT_FOUND')
        }
        $slot = Read-WorktreeMarker -WorktreePath $wtPath
        if (-not [bool]$slot.found) {
            return (New-WorktreeError -Code 'NOT_FOUND')
        }
        if ([bool]$slot.malformed) {
            return (New-WorktreeError -Code 'MALFORMED')
        }
        $branch = ''
        try { $branch = [string]$slot.marker['branch'] } catch { $branch = '' }
        if ([string]::IsNullOrWhiteSpace($branch)) { $branch = Get-OrchestrationWorktreeBranch -TaskId $tid }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; path = $wtPath; branch = $branch; marker = $slot.marker }
    }
    catch { return (New-WorktreeError -Code 'INTERNAL_ERROR') }
}

function Test-WorktreeRegisteredInGit {
    <#
    .SYNOPSIS
        True when `git worktree list --porcelain` contains the path.
        Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GitRepoDir,
        [Parameter(Mandatory = $true)][string]$WorktreePath
    )
    try {
        $list = Invoke-WorktreeGit -RepoDir $GitRepoDir -GitArgs @('worktree', 'list', '--porcelain')
        if (-not [bool]$list.ok) { return $false }
        $want = ([string]$WorktreePath -replace '/', '\').TrimEnd('\').ToLowerInvariant()
        foreach ($line in @(([string]$list.output -split "`r?`n"))) {
            $t = $line.Trim()
            if (-not $t.StartsWith('worktree ', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $p = $t.Substring(9).Trim()
            $norm = ($p -replace '/', '\').TrimEnd('\').ToLowerInvariant()
            if ($norm -ceq $want) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Remove-OrchestrationWorktree {
    <#
    .SYNOPSIS
        Ownership-aware removal. Marker missing or task_id mismatch returns
        WORKTREE_NOT_OWNED and does NOTHING. The path must be registered in
        `git worktree list --porcelain` or WORKTREE_NOT_REGISTERED is
        returned and nothing is touched. Plain `git worktree remove` runs
        first and is NEVER implicitly forced: on failure returns
        WORKTREE_REMOVE_FAILED with a hint to pass -Force explicitly.
        -Force still requires the marker task_id match plus a fresh
        reparse-point check before any git action. The branch is deleted
        only with -DeleteBranch and only when named
        'orchestration/<task-id>'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$WorktreesRoot = '',
        [string]$RepoRoot = '',
        [string]$GitRepoDir = '',
        [switch]$Force,
        [switch]$DeleteBranch
    )
    try {
        $tid = ([string]$TaskId).Trim()
        $wtPath = Get-OrchestrationWorktreePath -TaskId $tid -WorktreesRoot $WorktreesRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($wtPath)) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_OWNED')
        }
        if (-not (Test-Path -LiteralPath $wtPath)) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_OWNED')
        }
        $slot = Read-WorktreeMarker -WorktreePath $wtPath
        if (-not [bool]$slot.found) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_OWNED')
        }
        if ([bool]$slot.malformed) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_OWNED')
        }
        $mtid = ''
        try { $mtid = ([string]$slot.marker['task_id']).Trim() } catch { $mtid = '' }
        if ($mtid -cne $tid) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_OWNED')
        }
        if (-not (Test-WorktreeGitAvailable)) {
            return (New-WorktreeError -Code 'GIT_UNAVAILABLE')
        }
        $gitDir = $GitRepoDir
        if ([string]::IsNullOrWhiteSpace($gitDir)) { $gitDir = $RepoRoot }
        if ([string]::IsNullOrWhiteSpace($gitDir)) {
            return (New-WorktreeError -Code 'INVALID_REPO_ROOT')
        }
        if (Test-WorktreePathHasReparsePoint -Path $wtPath) {
            return (New-WorktreeError -Code 'PATH_NOT_CONFINED')
        }
        if (-not (Test-WorktreeRegisteredInGit -GitRepoDir $gitDir -WorktreePath $wtPath)) {
            return (New-WorktreeError -Code 'WORKTREE_NOT_REGISTERED' -Extra @{ path = $wtPath })
        }
        $mbranch = ''
        try { $mbranch = ([string]$slot.marker['branch']).Trim() } catch { $mbranch = '' }
        $expectedBranch = Get-OrchestrationWorktreeBranch -TaskId $tid
        if ([string]::IsNullOrWhiteSpace($mbranch)) { $mbranch = $expectedBranch }
        if ([bool]$Force) {
            $rm = Invoke-WorktreeGit -RepoDir $gitDir -GitArgs @('worktree', 'remove', '--force', $wtPath)
            if (-not [bool]$rm.ok) {
                return (New-WorktreeError -Code 'GIT_FAILED' -Extra @{ detail = ('git worktree remove --force exit ' + [string]$rm.code) })
            }
        }
        else {
            $rm = Invoke-WorktreeGit -RepoDir $gitDir -GitArgs @('worktree', 'remove', $wtPath)
            if (-not [bool]$rm.ok) {
                return (New-WorktreeError -Code 'WORKTREE_REMOVE_FAILED' -Extra @{ hint = 'dirty worktree; use -Force explicitly'; detail = ('git worktree remove exit ' + [string]$rm.code) })
            }
        }
        if ([bool]$DeleteBranch -and ($mbranch -ceq $expectedBranch)) {
            $null = Invoke-WorktreeGit -RepoDir $gitDir -GitArgs @('branch', '-D', $mbranch)
        }
        if (Test-Path -LiteralPath $wtPath) {
            return (New-WorktreeError -Code 'GIT_FAILED' -Extra @{ detail = 'worktree path still present after git worktree remove' })
        }
        return [PSCustomObject]@{ ok = $true; task_id = $tid; branch = $mbranch }
    }
    catch { return (New-WorktreeError -Code 'INTERNAL_ERROR') }
}
