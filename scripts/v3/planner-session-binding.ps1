<#
.SYNOPSIS
    Planner session binding on the real Task Kernel path (thin CLI wrapper).
.DESCRIPTION
    The Planner is the OpenCode `build` session, which is the ROOT of its run.
    Delegated workers are child sessions. This helper drives the existing
    kernel binding API through task-kernel.ps1 (no second mechanism):

      bind-root    bind the Planner session as run root (empty parent).
      detach-root  release the root so a worker can become the active owner.
      bind-worker  bind a delegated child session under the same root and run.
      status       read the run bindings and the task state (read-only).

    Every mutating action reads the current revision first (CAS). Kernel
    refusals (BIND_CONFLICT, CAS_CONFLICT, ...) are returned unchanged. Repeating
    an identical bind is idempotent in the kernel; a second, different owner is
    refused, so duplicate bindings cannot be created.
    Canonical store only: the CLI refuses non-canonical paths by design.
    Run: powershell -NoProfile -File scripts/v3/planner-session-binding.ps1 -Action status -TaskId <id>
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('bind-root', 'detach-root', 'bind-worker', 'status')][string]$Action,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$RunId = '',
    [string]$SessionId = '',
    [string]$RootSessionId = '',
    [string]$Runtime = 'opencode-v2',
    [string]$Version = 'native-run'
)
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot 'task-kernel.ps1'

function Invoke-TaskKernelCli([string[]]$CliArgs) {
    # The CLI reports refusals on stdout as JSON; stderr text must not become an
    # exception here, so the Kernel error code is returned to the caller intact.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>&1) | Out-String }
    finally { $ErrorActionPreference = $prevPref }
    $doc = $null
    try { $doc = $out | ConvertFrom-Json } catch { $doc = $null }
    if ($null -eq $doc) { return [pscustomobject]@{ ok = $false; error = 'CLI_OUTPUT_UNPARSEABLE'; raw = $out.Trim() } }
    return $doc
}

function Get-TaskRevision([string]$Id) {
    $rec = Invoke-TaskKernelCli @('-Action', 'get', '-TaskId', $Id)
    if ($null -ne $rec.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$rec.error)) {
        throw ('task unavailable: ' + [string]$rec.error)
    }
    return [int]$rec.revision
}

if ($Action -eq 'status') {
    $b = Invoke-TaskKernelCli @('-Action', 'get-bindings', '-TaskId', $TaskId)
    $t = Invoke-TaskKernelCli @('-Action', 'get', '-TaskId', $TaskId)
    [pscustomobject]@{ ok = [bool]$b.ok; task_id = $TaskId; state = [string]$t.state; revision = [int]$t.revision; bindings = $b.bindings } | ConvertTo-Json -Depth 12 -Compress
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($SessionId)) {
    Write-Output ('{"ok":false,"error":"RUN_AND_SESSION_REQUIRED"}')
    exit 1
}

$rev = Get-TaskRevision $TaskId
$common = @('-TaskId', $TaskId, '-RunId', $RunId, '-SessionId', $SessionId, '-ExpectedRevision', [string]$rev)
switch ($Action) {
    'bind-root' {
        $args2 = @('-Action', 'bind-session') + $common + @('-BindingRuntime', $Runtime, '-BindingVersion', $Version)
    }
    'detach-root' {
        $args2 = @('-Action', 'detach-session') + $common
    }
    'bind-worker' {
        if ([string]::IsNullOrWhiteSpace($RootSessionId)) { Write-Output ('{"ok":false,"error":"ROOT_SESSION_REQUIRED"}'); exit 1 }
        $args2 = @('-Action', 'bind-session') + $common + @('-WorkerSession', '-ParentSessionId', $RootSessionId, '-RootSessionId', $RootSessionId, '-BindingRuntime', $Runtime, '-BindingVersion', $Version)
    }
}
$res = Invoke-TaskKernelCli $args2
$res | ConvertTo-Json -Depth 8 -Compress
if ([bool]$res.ok) { exit 0 } else { exit 1 }
