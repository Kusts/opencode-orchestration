function Invoke-ExclusiveWork {
    <#
    .SYNOPSIS
        Executes a scriptblock exclusively across processes using a named System.Threading.Mutex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [int]$TimeoutMs = 5000
    )

    $hasHandle = $false
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $LockName)
        try {
            $hasHandle = $mutex.WaitOne($TimeoutMs, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $hasHandle = $true
        }

        if (-not $hasHandle) {
            throw "Failed to acquire mutex '$LockName' within $TimeoutMs ms."
        }

        return (& $Action)
    } finally {
        if ($hasHandle -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}
