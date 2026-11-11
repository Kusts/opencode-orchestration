<#
.SYNOPSIS
    GH-WAKE -> event-intake -> Task Kernel bridge (M6, #183/#185).
.DESCRIPTION
    Reuses the existing correlation and Kernel functions. It routes one
    validated GitHub event, delivers it to the owning Task inbox and returns
    the outcome. No new controller, scheduler, polling or Task creation.
    PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$EnvelopeFile = '',
    [string]$EnvelopeJson = '',
    [string]$RoutesFile = '',
    [string]$RoutesJson = '',
    [string]$SeenFile = '',
    [switch]$AdmissionEnabled,
    [switch]$Record,
    [string]$TasksDir = '',
    [string]$FlagsPath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationEventCorrelation.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')

function Read-BridgeText([string]$Path, [int]$MaxBytes) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $info = Get-Item -LiteralPath $Path
    if ([int64]$info.Length -gt [int64]$MaxBytes) { throw 'BRIDGE_INPUT_TOO_LARGE' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}
function Write-BridgeResult($Result, [int]$Code) {
    Write-Output ($Result | ConvertTo-Json -Depth 8)
    exit $Code
}

try {
    if ((-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) -and (-not [string]::IsNullOrWhiteSpace($EnvelopeJson))) {
        Write-BridgeResult @{ ok = $false; error = 'ENVELOPE_INPUT_AMBIGUOUS'; route = 'INVALID' } 2
    }
    $rawEnvelope = $EnvelopeJson
    if (-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) { $rawEnvelope = Read-BridgeText $EnvelopeFile 65536 }
    if ([string]::IsNullOrWhiteSpace($rawEnvelope)) { Write-BridgeResult @{ ok = $false; error = 'ENVELOPE_REQUIRED'; route = 'INVALID' } 2 }
    $doc = $null
    try { $doc = ($rawEnvelope | ConvertFrom-Json) } catch { Write-BridgeResult @{ ok = $false; error = 'ENVELOPE_INVALID_JSON'; route = 'INVALID' } 1 }
    $ev = New-OrchestrationEventEnvelope -Source ([string]$doc.source) -Trigger ([string]$doc.trigger) `
        -Thread ([string]$doc.thread) -DeliveryId ([string]$doc.delivery_id) -Repo ([string]$doc.repo) `
        -InformationalOnly ([bool]$doc.informational_only) -Summary ([string]$doc.summary)
    if (-not [bool]$ev.ok) { Write-BridgeResult @{ ok = $false; error = [string]$ev.error; route = 'INVALID' } 1 }

    $rawRoutes = $RoutesJson
    if (-not [string]::IsNullOrWhiteSpace($RoutesFile)) { $rawRoutes = Read-BridgeText $RoutesFile 262144 }
    $routes = @()
    if (-not [string]::IsNullOrWhiteSpace($rawRoutes)) {
        try { $parsed = $rawRoutes | ConvertFrom-Json; foreach ($item in $parsed) { $routes += $item } }
        catch { Write-BridgeResult @{ ok = $false; error = 'ROUTES_INVALID_JSON'; route = 'INVALID' } 1 }
    }
    $seen = @()
    if (-not [string]::IsNullOrWhiteSpace($SeenFile) -and (Test-Path -LiteralPath $SeenFile -PathType Leaf)) {
        $seen = @([IO.File]::ReadAllLines($SeenFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $route = Resolve-OrchestrationEventRoute -Envelope $ev -TaskRoutes $routes -SeenDeliveryKeys $seen -AdmissionEnabled:$AdmissionEnabled
    if (-not [bool]$route.ok -or [string]$route.route -cne 'ATTACH') {
        Write-BridgeResult @{ ok = [bool]$route.ok; route = [string]$route.route; reason = [string]$route.reason; task_id = ''; delivered = $false; duplicate = $false; dedup_key = [string]$route.dedup_key } 0
    }

    $task = Get-OrchestrationTask -TaskId ([string]$route.task_id) -TasksDir $TasksDir
    if ($null -eq $task -or $null -ne $task.PSObject.Properties['error']) {
        Write-BridgeResult @{ ok = $false; error = 'TASK_NOT_FOUND'; route = 'ATTACH'; task_id = [string]$route.task_id } 1
    }
    $rev = [int]$task['revision']
    $delivery = Add-OrchestrationTaskEvent -TaskId ([string]$route.task_id) -EnvelopeJson $rawEnvelope -ExpectedRevision $rev -TasksDir $TasksDir -FlagsPath $FlagsPath
    if (-not [bool]$delivery.ok) {
        Write-BridgeResult @{ ok = $false; error = [string]$delivery.error; route = 'ATTACH'; task_id = [string]$route.task_id } 1
    }
    $recorded = $false
    if ([bool]$Record -and [bool]$delivery.ok -and (-not [string]::IsNullOrWhiteSpace($SeenFile))) {
        $dir = Split-Path -Parent $SeenFile
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $seen += [string]$ev.dedup_key
        $seen = @($seen | Select-Object -Last 5000)
        $tmp = $SeenFile + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllLines($tmp, [string[]]$seen, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $SeenFile) { [IO.File]::Delete($SeenFile) }
        [IO.File]::Move($tmp, $SeenFile)
        $recorded = $true
    }
    Write-BridgeResult @{
        ok = $true
        route = 'ATTACH'
        reason = [string]$route.reason
        task_id = [string]$route.task_id
        delivered = $true
        duplicate = [bool]$delivery.duplicate
        revision = [int]$delivery.revision
        dedup_key = [string]$ev.dedup_key
        recorded = [bool]$recorded
        thread = [string]$ev.thread
    } 0
}
catch { Write-BridgeResult @{ ok = $false; error = 'EVENT_BRIDGE_FAILED'; route = 'INVALID'; reason = $_.Exception.Message } 1 }
