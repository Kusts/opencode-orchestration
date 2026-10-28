<#
.SYNOPSIS
    Native-first read-only adapter for OpenCode V2 session listing.
.DESCRIPTION
    Thin wrapper over `opencode session list --format json`. Read-only.
    Returns structured objects with id, title, created, updated, directory,
    projectId. On failure returns a structured error (no throw).
    Validates required fields and types; distinguishes empty list from invalid.
#>
[CmdletBinding()]
param()

function Protect-Diag([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
    return $t
}

function Get-NativeSessionList {
    [CmdletBinding()]
    param(
        [int]$MaxCount = 100,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    if ($MaxCount -lt 1) { $MaxCount = 1 }
    if ($MaxCount -gt 1000) { $MaxCount = 1000 }
    $args = @('session', 'list', '-n', $MaxCount, '--format', 'json')

    # Resolve executable (prefer .cmd on Windows)
    $resolved = $BinaryCommand
    $useCmdShim = $false
    if ($BinaryCommand -eq 'opencode') {
        $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
        if ($cmd) {
            $resolved = $cmd.Source
            if ($resolved -like '*.cmd' -or $resolved -like '*.bat') { $useCmdShim = $true }
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($useCmdShim) {
        $psi.FileName = 'cmd.exe'
        $escaped = $resolved -replace '"', '""'
        $psi.Arguments = '/c ""' + $escaped + '" ' + ($args -join ' ') + '"'
    } else {
        $psi.FileName = $resolved
        $psi.Arguments = ($args -join ' ')
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ ok = $false; error = 'LAUNCH_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{ ok = $false; error = 'TIMEOUT'; sessions = @() }
    }
    $stdout = $outTask.Result
    $stderr = $errTask.Result

    if ($proc.ExitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; error = ('EXIT_' + $proc.ExitCode); detail = (Protect-Diag $stderr); sessions = @() }
    }

    # Validate response
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return [pscustomobject]@{ ok = $false; error = 'PARSE_ERROR'; detail = 'empty response'; sessions = @() }
    }
    $parsed = $null
    try {
        $parsed = $stdout | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ ok = $false; error = 'PARSE_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
    }
    # Must be an array (list), not a single object
    $isArrayResponse = $stdout.Trim().StartsWith('[')
    if (-not $isArrayResponse) {
        return [pscustomobject]@{ ok = $false; error = 'PARSE_ERROR'; detail = 'expected array'; sessions = @() }
    }
    if ($null -eq $parsed) {
        # ConvertFrom-Json of '[]' yields $null in PowerShell; treat as empty list.
        $parsed = @()
    }
    if ($parsed -isnot [System.Array]) {
        # Single-element arrays are unwrapped by ConvertFrom-Json; re-wrap.
        $parsed = @($parsed)
    }

    $sessions = @()
    foreach ($s in $parsed) {
        # Validate required fields
        if ($null -eq $s) {
            return [pscustomobject]@{ ok = $false; error = 'FIELD_ERROR'; detail = 'null entry'; sessions = @() }
        }
        $id = ''
        try { $id = [string]$s.id } catch { $id = '' }
        if ([string]::IsNullOrWhiteSpace($id)) {
            return [pscustomobject]@{ ok = $false; error = 'FIELD_ERROR'; detail = 'missing id'; sessions = @() }
        }
        $created = 0; $updated = 0
        try {
            if ($null -eq $s.created) { throw 'missing created' }
            $created = [long]$s.created
            if ($null -eq $s.updated) { throw 'missing updated' }
            $updated = [long]$s.updated
        } catch {
            return [pscustomobject]@{ ok = $false; error = 'FIELD_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
        }
        $title = ''
        try { $title = [string]$s.title } catch { $title = '' }
        $directory = ''
        try { $directory = [string]$s.directory } catch { $directory = '' }
        $projectId = ''
        try { $projectId = [string]$s.projectId } catch { $projectId = '' }

        $sessions += [pscustomobject]@{
            id = $id
            title = $title
            created = $created
            updated = $updated
            directory = $directory
            projectId = $projectId
        }
    }
    return [pscustomobject]@{ ok = $true; error = $null; sessions = $sessions; count = $sessions.Count }
}