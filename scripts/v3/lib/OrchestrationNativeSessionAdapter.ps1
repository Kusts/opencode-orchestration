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
            if (-not ($s.created -is [int] -or $s.created -is [long] -or $s.created -is [System.Int32] -or $s.created -is [System.Int64])) {
                throw 'created must be integer'
            }
            $created = [long]$s.created
            if ($null -eq $s.updated) { throw 'missing updated' }
            if (-not ($s.updated -is [int] -or $s.updated -is [long] -or $s.updated -is [System.Int32] -or $s.updated -is [System.Int64])) {
                throw 'updated must be integer'
            }
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

function Test-NativeSessionIdFormat {
    [CmdletBinding()]
    param([string]$SessionId = '')
    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
        return (([string]$SessionId) -cmatch '^ses_[A-Za-z0-9]+$')
    } catch { return $false }
}

function Resolve-NativeSessionDirectory {
    [CmdletBinding()]
    param([string]$Path = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        $t = ([string]$Path).Trim()
        $t = $t.TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        if ($t -match '^[A-Za-z]:$') { $t = $t + '\' }
        $full = $t
        try { $full = [IO.Path]::GetFullPath($t) } catch { $full = $t }
        $full = ([string]$full).TrimEnd('\', '/')
        if ($full -match '^[A-Za-z]:$') { $full = $full + '\' }
        if ([string]::IsNullOrWhiteSpace($full)) { return '' }
        try {
            if (Test-Path -LiteralPath $full) {
                $it = Get-Item -LiteralPath $full -ErrorAction Stop
                if ($null -ne $it -and -not [string]::IsNullOrWhiteSpace([string]$it.FullName)) {
                    $full = ([string]$it.FullName).TrimEnd('\', '/')
                    if ($full -match '^[A-Za-z]:$') { $full = $full + '\' }
                }
            }
        } catch { }
        return [string]$full
    } catch { return '' }
}

function Find-NativeSessionById {
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        $SessionsResult = $null,
        [int]$MaxCount = 100,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }
        $list = $SessionsResult
        $hasSessions = $false
        try {
            if ($null -ne $list) {
                $p = $list.PSObject.Properties['sessions']
                if ($null -ne $p) { $hasSessions = $true }
            }
        } catch { $hasSessions = $false }
        if (-not $hasSessions) {
            $list = Get-NativeSessionList -MaxCount $MaxCount -BinaryCommand $BinaryCommand -TimeoutMs $TimeoutMs
        }
        if ($null -eq $list) { return $null }
        $listOk = $false
        try { $listOk = [bool]$list.ok } catch { $listOk = $false }
        if (-not $listOk) { return $null }
        $arr = @()
        try { $arr = @($list.sessions) } catch { return $null }
        foreach ($s in $arr) {
            try {
                if ($null -ne $s -and ([string]$s.id) -ceq $SessionId) { return $s }
            } catch { }
        }
        return $null
    } catch { return $null }
}

function Test-NativeSessionBinding {
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$ExpectedDirectory = '',
        [string]$ExpectedProjectId = '',
        $SessionsResult = $null
    )
    try {
        if (-not (Test-NativeSessionIdFormat -SessionId $SessionId)) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; session = $null }
        }
        if ($null -eq $SessionsResult) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; session = $null }
        }
        $okFlag = $false
        try { $okFlag = [bool]$SessionsResult.ok } catch { $okFlag = $false }
        if (-not $okFlag) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; session = $null }
        }
        $found = $null
        try {
            $arr = @($SessionsResult.sessions)
            foreach ($s in $arr) {
                try {
                    if ($null -ne $s -and ([string]$s.id) -ceq $SessionId) { $found = $s; break }
                } catch { }
            }
        } catch { $found = $null }
        if ($null -eq $found) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; session = $null }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedProjectId)) {
            $actualPid = ''
            try { $actualPid = [string]$found.projectId } catch { $actualPid = '' }
            if ($actualPid -cne [string]$ExpectedProjectId) {
                return [pscustomobject]@{ ok = $false; reason = 'project-mismatch'; session = $null }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedDirectory)) {
            $actualDir = ''
            try { $actualDir = [string]$found.directory } catch { $actualDir = '' }
            $canonExp = Resolve-NativeSessionDirectory -Path $ExpectedDirectory
            $canonAct = Resolve-NativeSessionDirectory -Path $actualDir
            if ([string]::IsNullOrWhiteSpace($canonExp) -or [string]::IsNullOrWhiteSpace($canonAct)) {
                if ($actualDir -ine [string]$ExpectedDirectory) {
                    return [pscustomobject]@{ ok = $false; reason = 'directory-mismatch'; session = $null }
                }
            } elseif ($canonExp -ine $canonAct) {
                return [pscustomobject]@{ ok = $false; reason = 'directory-mismatch'; session = $null }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; session = $found }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; session = $null }
    }
}

function Get-NativeSessionIdentity {
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$ExpectedDirectory = '',
        [string]$ExpectedProjectId = '',
        [int]$MaxCount = 100,
        [string]$BinaryCommand = 'opencode',
        [int]$TimeoutMs = 30000
    )
    try {
        if (-not (Test-NativeSessionIdFormat -SessionId $SessionId)) {
            return [pscustomobject]@{ ok = $false; reason = 'session-id-invalid'; detail = (Protect-Diag ([string]$SessionId)); session = $null }
        }
        $list = $null
        try {
            $list = Get-NativeSessionList -MaxCount $MaxCount -BinaryCommand $BinaryCommand -TimeoutMs $TimeoutMs
        } catch {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = (Protect-Diag $_.Exception.Message); session = $null }
        }
        if ($null -eq $list) {
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = 'empty list result'; session = $null }
        }
        $listOk = $false
        try { $listOk = [bool]$list.ok } catch { $listOk = $false }
        if (-not $listOk) {
            $d = ''
            try {
                $e = [string]$list.error
                $det = ''
                try { $det = [string]$list.detail } catch { $det = '' }
                if ([string]::IsNullOrWhiteSpace($det)) { $d = $e } else { $d = ($e + ':' + $det) }
            } catch { $d = 'list failed' }
            return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = (Protect-Diag $d); session = $null }
        }
        $b = Test-NativeSessionBinding -SessionId $SessionId -ExpectedDirectory $ExpectedDirectory -ExpectedProjectId $ExpectedProjectId -SessionsResult $list
        if ($null -eq $b -or -not [bool]$b.ok) {
            $reason = 'session-not-found'
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$b.reason)) { $reason = [string]$b.reason }
            } catch { }
            return [pscustomobject]@{ ok = $false; reason = $reason; detail = (Protect-Diag ($reason + ':' + [string]$SessionId)); session = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; detail = ''; session = $b.session }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'session-not-found'; detail = (Protect-Diag $_.Exception.Message); session = $null }
    }
}