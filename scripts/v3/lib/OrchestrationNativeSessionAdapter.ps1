<#
.SYNOPSIS
    Native-first read-only adapter for OpenCode V2 session listing.
.DESCRIPTION
    Thin wrapper over `opencode session list --format json`. Read-only: never
    mutates task/goal state. Returns structured objects with id, title,
    created, updated, directory, projectId. On failure, returns a structured
    error object (no throw) so callers can fall back to the local catalog.
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
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $resolved = $BinaryCommand
    if ($BinaryCommand -eq 'opencode') {
        # Prefer the .cmd shim over the .ps1 wrapper
        $cmd = Get-Command opencode.cmd -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command opencode -ErrorAction SilentlyContinue }
        if ($cmd) { $resolved = $cmd.Source }
    }
    $psi.FileName = $resolved
    $psi.Arguments = ($args -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutMs)) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{ ok = $false; error = 'TIMEOUT'; sessions = @() }
    }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if ($proc.ExitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; error = ('EXIT_' + $proc.ExitCode); detail = $stderr; sessions = @() }
    }
    try {
        $parsed = $stdout | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ ok = $false; error = 'PARSE_ERROR'; detail = $_.Exception.Message; sessions = @() }
    }
    $sessions = @()
    foreach ($s in @($parsed)) {
        $sessions += [pscustomobject]@{
            id = [string]$s.id
            title = [string]$s.title
            created = [long]$s.created
            updated = [long]$s.updated
            directory = [string]$s.directory
            projectId = [string]$s.projectId
        }
    }
    return [pscustomobject]@{ ok = $true; error = $null; sessions = $sessions; count = $sessions.Count }
}