<#
.SYNOPSIS
    Process-level tests for evidence virtualization CLI.
    PowerShell 5.1/7 compatible, ASCII-only, temporary store only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:CliPath = Join-Path $PSScriptRoot 'evidence-virtualize.ps1'
$script:HostExe = ''
try { $script:HostExe = [string](Get-Process -Id $PID).Path } catch { }
if ([string]::IsNullOrWhiteSpace($script:HostExe)) {
    if ($PSVersionTable.PSEdition -eq 'Core') { $script:HostExe = Join-Path $PSHOME 'pwsh.exe' }
    else { $script:HostExe = Join-Path $PSHOME 'powershell.exe' }
}

function Assert-EvidenceVirtualize {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else {
        Write-Host ('[FAIL] ' + $Name + $(if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' -- ' + $Detail }))
        $script:Failed++
    }
}

function Invoke-EvidenceVirtualizeCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $quoted = @()
    foreach ($arg in @($CliArgs)) { $quoted += ('"' + ([string]$arg).Replace('"', '\"') + '"') }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CliPath + '" ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($stdout)) { $json = ConvertFrom-Json -InputObject $stdout } } catch { }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout.Trim(); Stderr = $stderr.Trim(); Json = $json }
}

if (-not (Test-Path -LiteralPath $script:HostExe -PathType Leaf)) {
    Assert-EvidenceVirtualize $false 'CLI host executable available' $script:HostExe
}
else {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('evidence-virtualize-' + [Guid]::NewGuid().ToString('N'))
    $store = Join-Path $root 'store'
    $contentPath = Join-Path $root 'large-log.txt'
    $outsidePath = Join-Path $root 'outside.txt'
    try {
        [void][IO.Directory]::CreateDirectory($root)
        $largeContent = 'log-line-' + (('x' * 90) + "`n") * 1200
        [IO.File]::WriteAllText($contentPath, $largeContent, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($outsidePath, 'outside-store', [Text.Encoding]::UTF8)

        $timer = [Diagnostics.Stopwatch]::StartNew()
        $stored = Invoke-EvidenceVirtualizeCli @('-Action', 'store', '-ContentFile', $contentPath, '-Kind', 'session-log', '-StoreDir', $store, '-PreviewChars', '2000')
        $preview = $null
        if ($stored.ExitCode -eq 0 -and $stored.Json) {
            $preview = Invoke-EvidenceVirtualizeCli @('-Action', 'preview', '-ArtifactId', ([string]$stored.Json.artifact_id), '-StoreDir', $store, '-PreviewChars', '2000')
        }
        $timer.Stop()
        Assert-EvidenceVirtualize (($stored.ExitCode -eq 0) -and [bool]$stored.Json.ok -and ([int]$stored.Json.preview.Length -le 2000) -and ([int]$stored.Json.full_bytes -gt [int]$stored.Json.preview_bytes)) 'store creates bounded preview for >100KB content' ($stored.Stdout + ' ' + $stored.Stderr)
        Assert-EvidenceVirtualize (($null -ne $preview) -and ($preview.ExitCode -eq 0) -and [bool]$preview.Json.ok -and ([string]$preview.Json.sha256 -ceq [string]$stored.Json.sha256) -and ([string]$preview.Json.content -ceq [string]$stored.Json.preview)) 'preview returns bounded content with verified SHA-256' $(if ($preview) { $preview.Stdout + ' ' + $preview.Stderr } else { 'preview not run' })

        $recalled = Invoke-EvidenceVirtualizeCli @('-Action', 'recall', '-ArtifactId', ([string]$stored.Json.artifact_id), '-StoreDir', $store)
        Assert-EvidenceVirtualize (($recalled.ExitCode -eq 0) -and [bool]$recalled.Json.ok -and ([string]$recalled.Json.content -ceq $largeContent) -and ([string]$recalled.Json.sha256 -ceq [string]$stored.Json.sha256)) 'recall returns full content after hash verification' ($recalled.Stdout.Substring(0, [Math]::Min(300, $recalled.Stdout.Length)))
        Write-Host ('[MEASURE] store+preview elapsed_ms=' + $timer.ElapsedMilliseconds + ' bytes_full=' + $stored.Json.full_bytes + ' bytes_preview=' + $stored.Json.preview_bytes)

        $again = Invoke-EvidenceVirtualizeCli @('-Action', 'store', '-ContentFile', $contentPath, '-Kind', 'session-log', '-StoreDir', $store, '-PreviewChars', '2000')
        Assert-EvidenceVirtualize (($again.ExitCode -eq 0) -and ([string]$again.Json.artifact_id -ceq [string]$stored.Json.artifact_id)) 'same content stores idempotently to same artifact_id' ($again.Stdout + ' ' + $again.Stderr)

        [IO.File]::AppendAllText([string]$stored.Json.path, 'tamper', [Text.Encoding]::UTF8)
        $tampered = Invoke-EvidenceVirtualizeCli @('-Action', 'recall', '-ArtifactId', ([string]$stored.Json.artifact_id), '-StoreDir', $store)
        Assert-EvidenceVirtualize (($tampered.ExitCode -eq 1) -and (-not [bool]$tampered.Json.ok) -and ([string]$tampered.Json.error -ceq 'ARTIFACT_HASH_MISMATCH')) 'tampered content is refused by recall' ($tampered.Stdout + ' ' + $tampered.Stderr)

        $badPath = Invoke-EvidenceVirtualizeCli @('-Action', 'recall', '-Path', '..\outside.txt', '-StoreDir', $store)
        Assert-EvidenceVirtualize (($badPath.ExitCode -eq 1) -and ([string]$badPath.Json.error -ceq 'ARTIFACT_PATH_ESCAPE')) 'path traversal/outside-store recall is refused' ($badPath.Stdout + ' ' + $badPath.Stderr)
        $badKind = Invoke-EvidenceVirtualizeCli @('-Action', 'store', '-ContentFile', $contentPath, '-Kind', 'invalid-kind', '-StoreDir', $store)
        Assert-EvidenceVirtualize (($badKind.ExitCode -eq 2) -and ([string]$badKind.Json.error -ceq 'ARTIFACT_KIND_INVALID')) 'invalid kind is rejected as usage error' ($badKind.Stdout + ' ' + $badKind.Stderr)
    }
    finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host ''
Write-Host ('EVIDENCE-VIRTUALIZE: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }
exit 0
