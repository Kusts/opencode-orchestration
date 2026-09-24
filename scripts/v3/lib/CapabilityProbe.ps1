<#!
.SYNOPSIS
    V3 Capability probe: read-only wrappers over the OpenCode CLI.
.DESCRIPTION
    Dot-sourceable library (no disk writes). Every Invoke-* wrapper spawns a
    short-lived child process for introspection commands only (debug config,
    debug skill, debug agent <name>, mcp list, agent list). Tool execution
    flags are rejected before any process starts, so discovery can never
    execute a tool. All Get-* functions degrade gracefully: they return $null
    (plus a Write-Verbose diagnostic) when the CLI is missing or fails, and
    they never throw at the top level.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Format-CliArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    return ('"' + ($Value -replace '"', '\"') + '"')
}

function Invoke-OpenCodeCli {
    <#
    .SYNOPSIS
        Runs the OpenCode CLI with the given arguments (read-only commands).
    .OUTPUTS
        PSCustomObject @{ Found = [bool]; ExitCode = [int]; StdOut = [string] }.
        Found is $false only when no `opencode` command resolves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 30,
        [hashtable]$ExtraEnvironment
    )
    foreach ($arg in $Arguments) {
        if ($arg -ceq '--tool' -or $arg -ceq '--params') {  # reject: never forward execution flags
            throw "Invoke-OpenCodeCli rejects execution flags ('--tool'/'--params'); discovery is read-only."
        }
    }
    $cmd = Get-Command 'opencode' -ErrorAction SilentlyContinue
    if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return [PSCustomObject]@{ Found = $false; ExitCode = -1; StdOut = '' }
    }
    $source = $cmd.Source
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($null -ne $ExtraEnvironment) {
        foreach ($key in $ExtraEnvironment.Keys) {
            $psi.EnvironmentVariables["$key"] = "$($ExtraEnvironment[$key])"
        }
    }
    $quotedArgs = @(foreach ($a in $Arguments) { Format-CliArgument -Value $a })
    $ext = [IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /c "' + (Format-CliArgument -Value $source) + ' ' + ($quotedArgs -join ' ') + '"'
    }
    elseif ($ext -eq '.ps1') {
        $hostCmd = Get-Command 'powershell' -ErrorAction SilentlyContinue
        if ($null -ne $hostCmd -and -not [string]::IsNullOrWhiteSpace($hostCmd.Source)) {
            $psi.FileName = $hostCmd.Source
        }
        else {
            $psi.FileName = 'powershell.exe'
        }
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Format-CliArgument -Value $source) + ' ' + ($quotedArgs -join ' ')
    }
    else {
        $psi.FileName = $source
        $psi.Arguments = ($quotedArgs -join ' ')
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        $proc.Start() | Out-Null
    }
    catch {
        return [PSCustomObject]@{ Found = $true; ExitCode = -1; StdOut = '' }
    }
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
    }
    catch {
        try { $proc.Kill() } catch { }
        return [PSCustomObject]@{ Found = $true; ExitCode = -1; StdOut = '' }
    }
    $timeoutMs = $TimeoutSeconds * 1000
    if ($timeoutMs -le 0) { $timeoutMs = 30000 }
    $exited = $proc.WaitForExit($timeoutMs)
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
        return [PSCustomObject]@{ Found = $true; ExitCode = -1; StdOut = '' }
    }
    $out = ''
    try { $out = $outTask.Result } catch { $out = '' }
    try { $errTask.Wait(5000) | Out-Null } catch { }
    if ($null -eq $out) { $out = '' }
    return [PSCustomObject]@{ Found = $true; ExitCode = $proc.ExitCode; StdOut = $out }
}

function Remove-AnsiCode {
    <#
    .SYNOPSIS
        Strips ANSI/CSI escape sequences from CLI output.
    #>
    [CmdletBinding()]
    param(
        [string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    # NOTE: Windows PowerShell 5.1 has no `e escape; build ESC explicitly.
    $esc = [string][char]27
    $pattern = $esc + '\[[0-9;?]*[A-Za-z]|' + $esc + '[()#%@][0-9A-Za-z]'
    return ([regex]::Replace($Text, $pattern, ''))
}

function Get-OpenCodeVersion {
    <#
    .SYNOPSIS
        Returns the OpenCode version string, or $null when unavailable.
    #>
    [CmdletBinding()]
    param()
    try {
        $result = Invoke-OpenCodeCli -Arguments @('--version')
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose 'Diagnostic: opencode --version unavailable.'
            return $null
        }
        $clean = (Remove-AnsiCode -Text $result.StdOut).Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) {
            Write-Verbose 'Diagnostic: opencode --version returned empty output.'
            return $null
        }
        $first = ($clean -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
        return $first
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeVersion failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-OpenCodeDebugConfig {
    <#
    .SYNOPSIS
        Returns the parsed `debug config` object, or $null when unavailable.
    #>
    [CmdletBinding()]
    param()
    try {
        $result = Invoke-OpenCodeCli -Arguments @('debug', 'config')
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose 'Diagnostic: opencode debug config unavailable.'
            return $null
        }
        $clean = Remove-AnsiCode -Text $result.StdOut
        return ($clean | ConvertFrom-Json)
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeDebugConfig failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-OpenCodeSkills {
    <#
    .SYNOPSIS
        Returns the parsed `debug skill` array with Claude skills isolated,
        or $null when the CLI is missing or fails.
    #>
    [CmdletBinding()]
    param()
    try {
        $isolated = @{ 'OPENCODE_DISABLE_CLAUDE_CODE_SKILLS' = '1' }
        $result = Invoke-OpenCodeCli -Arguments @('debug', 'skill') -ExtraEnvironment $isolated
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose 'Diagnostic: opencode debug skill unavailable.'
            return $null
        }
        $clean = Remove-AnsiCode -Text $result.StdOut
        $parsed = ($clean | ConvertFrom-Json)
        return @($parsed)
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeSkills failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-OpenCodeAgentConfig {
    <#
    .SYNOPSIS
        Returns the parsed `debug agent <name>` object, or $null when unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '^-') {
        throw ("Get-OpenCodeAgentConfig rejects invalid agent name: '{0}'." -f $Name)
    }
    try {
        $result = Invoke-OpenCodeCli -Arguments @('debug', 'agent', $Name)
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose ("Diagnostic: opencode debug agent '{0}' unavailable." -f $Name)
            return $null
        }
        $clean = Remove-AnsiCode -Text $result.StdOut
        return ($clean | ConvertFrom-Json)
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeAgentConfig failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-OpenCodeMcpList {
    <#
    .SYNOPSIS
        Parses `mcp list` text into @{ id; status } rows, or $null when unavailable.
    #>
    [CmdletBinding()]
    param()
    try {
        $result = Invoke-OpenCodeCli -Arguments @('mcp', 'list')
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose 'Diagnostic: opencode mcp list unavailable.'
            return $null
        }
        $clean = Remove-AnsiCode -Text $result.StdOut
        $rows = @()
        foreach ($line in ($clean -split "`r?`n")) {
            $text = ($line -replace '[^\u0020-\u007E]', ' ').Trim()
            if ($text -match '(?i)^\s*([A-Za-z0-9_][\w.\-]*)\s+(connected|disconnected|disabled|failed|needs_auth|needs-auth|unauthorized|error|unknown)\b') {
                $status = $Matches[2].ToLowerInvariant() -replace '-', '_'
                $rows += [PSCustomObject]@{ id = $Matches[1]; status = $status }
            }
        }
        return $rows
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeMcpList failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-OpenCodeAgentList {
    <#
    .SYNOPSIS
        Parses `agent list` text into @{ name; mode } rows, or $null when unavailable.
    #>
    [CmdletBinding()]
    param()
    try {
        $result = Invoke-OpenCodeCli -Arguments @('agent', 'list')
        if (-not $result.Found -or $result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Verbose 'Diagnostic: opencode agent list unavailable.'
            return $null
        }
        $clean = Remove-AnsiCode -Text $result.StdOut
        $rows = @()
        foreach ($line in ($clean -split "`r?`n")) {
            $text = ($line -replace '[^\u0020-\u007E]', ' ').Trim()
            if ($text -match '^\s*([A-Za-z0-9_][\w.\-]*)\s+\((primary|subagent|all)\)') {
                $rows += [PSCustomObject]@{ name = $Matches[1]; mode = $Matches[2] }
            }
        }
        return $rows
    }
    catch {
        Write-Verbose ("Diagnostic: Get-OpenCodeAgentList failed: {0}" -f $_.Exception.Message)
        return $null
    }
}
