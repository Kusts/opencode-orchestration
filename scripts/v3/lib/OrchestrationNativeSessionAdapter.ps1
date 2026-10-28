<#
.SYNOPSIS
    Native-first read-only adapter for OpenCode V2 session listing.
#>
[CmdletBinding()]
param()

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

    $stdoutSb = New-Object System.Text.StringBuilder
    $stderrSb = New-Object System.Text.StringBuilder
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ ok = $false; error = 'LAUNCH_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
    }

    # Drain streams asynchronously to avoid pipe deadlock
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
    try {
        $parsed = $stdout | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ ok = $false; error = 'PARSE_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
    }
    $sessions = @()
    foreach ($s in @($parsed)) {
        try {
            $sessions += [pscustomobject]@{
                id = [string]$s.id
                title = [string]$s.title
                created = [long]$s.created
                updated = [long]$s.updated
                directory = [string]$s.directory
                projectId = [string]$s.projectId
            }
        } catch {
            return [pscustomobject]@{ ok = $false; error = 'FIELD_ERROR'; detail = (Protect-Diag $_.Exception.Message); sessions = @() }
        }
    }
    return [pscustomobject]@{ ok = $true; error = $null; sessions = $sessions; count = $sessions.Count }
}

function Protect-Diag([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
    return $t
}