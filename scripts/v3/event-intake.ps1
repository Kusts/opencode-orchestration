<#
.SYNOPSIS
    GitHub event intake: validate, route and deduplicate (M6, #183/#185).
.DESCRIPTION
    Thin CLI over OrchestrationEventCorrelation. It never creates a Task,
    dispatches a worker or mutates goal state. An optional -Record appends the
    dedup key to a bounded ledger so the same delivery is ignored once.
    Secret values must not contain leading or trailing whitespace.
    Oversized envelope files return EVENT_INPUT_TOO_LARGE with exit 1;
    this differs from verifier BODY_TOO_LARGE / exit 2 convention.
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
    [string]$SignatureHeader = '',
    [string]$SecretFile = '',
    [string]$SecretEnvVar = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationEventCorrelation.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationEventSignature.ps1')

function Read-EventText([string]$Path, [int]$MaxBytes) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $info = Get-Item -LiteralPath $Path
    if ([int64]$info.Length -gt [int64]$MaxBytes) { throw 'EVENT_INPUT_TOO_LARGE' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}
function Write-EventResult($Result, [int]$Code) {
    Write-Output ($Result | ConvertTo-Json -Depth 8)
    exit $Code
}

try {
    $configured = (-not [string]::IsNullOrWhiteSpace($SecretFile)) -or (-not [string]::IsNullOrWhiteSpace($SecretEnvVar))
    if ($configured -and -not [string]::IsNullOrWhiteSpace($EnvelopeJson)) {
        Write-EventResult @{ok=$false;error='SIGNATURE_REQUIRES_FILE';route='INVALID';reason='';signature_status='required-unverified'} 2
    }
    if (-not [string]::IsNullOrWhiteSpace($SecretFile) -and -not [string]::IsNullOrWhiteSpace($SecretEnvVar)) {
        Write-EventResult @{ok=$false;error='SECRET_SOURCE_AMBIGUOUS';route='INVALID';reason=''} 2
    }
    if ((-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) -and (-not [string]::IsNullOrWhiteSpace($EnvelopeJson))) {
        Write-EventResult @{ ok = $false; error = 'ENVELOPE_INPUT_AMBIGUOUS'; route = 'INVALID'; reason = '' } 2
    }
    $rawEnvelope = $EnvelopeJson
    $signatureStatus = 'not-configured'
    $signatureIgnored = $false
    if (-not $configured -and -not [string]::IsNullOrWhiteSpace($SignatureHeader)) {
        $signatureIgnored = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) {
        if ($configured) {
            if (-not (Test-Path -LiteralPath $EnvelopeFile -PathType Leaf)) {
                Write-EventResult @{ok=$false;error='ENVELOPE_REQUIRED';route='INVALID';reason=''} 2
            }
            $envelopeInfo=Get-Item -LiteralPath $EnvelopeFile
            if ([int64]$envelopeInfo.Length -gt 65536) {
                Write-EventResult @{ok=$false;error='EVENT_INPUT_TOO_LARGE';route='INVALID';reason=''} 1
            }
            if (-not [string]::IsNullOrWhiteSpace($SecretFile)) {
                $sr=Read-OrchestrationWebhookSecret -Path $SecretFile
                if(-not $sr.ok){Write-EventResult @{ok=$false;error=$sr.error;route='INVALID';reason=''} 1}
                $secret=$sr.secret
            } else {
                $secret=[Environment]::GetEnvironmentVariable($SecretEnvVar)
                if ($null -eq $secret) { $secret='' }
                $secret=$secret.Trim(" `t`r`n")
                if([string]::IsNullOrWhiteSpace($secret)){
                    Write-EventResult @{ok=$false;error='SECRET_INVALID';route='INVALID';reason=''} 1
                }
            }
            $bytes=[IO.File]::ReadAllBytes($EnvelopeFile)
            $sig=Test-OrchestrationGitHubSignature -BodyBytes $bytes -SignatureHeader $SignatureHeader -Secret $secret
            if(-not $sig.ok){$err=$sig.error;if($err -eq 'SIGNATURE_MISMATCH'){$err='SIGNATURE_MISMATCH'};Write-EventResult @{ok=$false;error=$err;route='INVALID';reason=''} 1}
            $signatureStatus='verified';$rawEnvelope=[Text.Encoding]::UTF8.GetString($bytes)
            if ($rawEnvelope.Length -gt 0 -and $rawEnvelope[0] -eq [char]0xFEFF) {
                $rawEnvelope=$rawEnvelope.Substring(1)
            }
        } else {$rawEnvelope = Read-EventText $EnvelopeFile 65536}
    }
    if ([string]::IsNullOrWhiteSpace($rawEnvelope)) {
        Write-EventResult @{ ok = $false; error = 'ENVELOPE_REQUIRED'; route = 'INVALID'; reason = '' } 2
    }
    $doc = $null
    try { $doc = ($rawEnvelope | ConvertFrom-Json) } catch {
        Write-EventResult @{ ok = $false; error = 'ENVELOPE_INVALID_JSON'; route = 'INVALID'; reason = '' } 1
    }
    $env = New-OrchestrationEventEnvelope -Source ([string]$doc.source) -Trigger ([string]$doc.trigger) `
        -Thread ([string]$doc.thread) -DeliveryId ([string]$doc.delivery_id) -Repo ([string]$doc.repo) `
        -InformationalOnly ([bool]$doc.informational_only) -Summary ([string]$doc.summary)
    if (-not [bool]$env.ok) {
        Write-EventResult @{ ok = $false; error = [string]$env.error; route = 'INVALID'; reason = 'envelope-invalid' } 1
    }

    $rawRoutes = $RoutesJson
    if (-not [string]::IsNullOrWhiteSpace($RoutesFile)) { $rawRoutes = Read-EventText $RoutesFile 262144 }
    $routes = @()
    if (-not [string]::IsNullOrWhiteSpace($rawRoutes)) {
        try {
            $parsedRoutes = $rawRoutes | ConvertFrom-Json
            $routes = @()
            foreach ($item in $parsedRoutes) { $routes += $item }
        } catch {
            Write-EventResult @{ ok = $false; error = 'ROUTES_INVALID_JSON'; route = 'INVALID'; reason = '' } 1
        }
    }

    $seen = @()
    if (-not [string]::IsNullOrWhiteSpace($SeenFile) -and (Test-Path -LiteralPath $SeenFile -PathType Leaf)) {
        $info = Get-Item -LiteralPath $SeenFile
        if ([int64]$info.Length -gt 262144) { Write-EventResult @{ ok = $false; error = 'SEEN_LEDGER_TOO_LARGE'; route = 'INVALID'; reason = '' } 1 }
        $seen = @([IO.File]::ReadAllLines($SeenFile, [Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $route = Resolve-OrchestrationEventRoute -Envelope $env -TaskRoutes $routes -SeenDeliveryKeys $seen -AdmissionEnabled:$AdmissionEnabled
    $recorded = $false
    if ([bool]$Record -and [bool]$route.ok -and ([string]$route.route -notin @('IGNORE', 'INVALID'))) {
        if (-not [string]::IsNullOrWhiteSpace($SeenFile)) {
            $dir = Split-Path -Parent $SeenFile
            if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $seen += [string]$route.dedup_key
            $seen = @($seen | Select-Object -Last 5000)
            $tmp = $SeenFile + '.tmp-' + [guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllLines($tmp, [string[]]$seen, (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $SeenFile) { [IO.File]::Delete($SeenFile) }
            [IO.File]::Move($tmp, $SeenFile)
            $recorded = $true
        }
    }
    Write-EventResult @{
        ok = [bool]$route.ok
        route = [string]$route.route
        reason = [string]$route.reason
        task_id = [string]$route.task_id
        dedup_key = [string]$route.dedup_key
        recorded = [bool]$recorded
        thread = [string]$env.thread
        trigger = [string]$env.trigger
        signature_status = $signatureStatus
        signature_header_ignored = $signatureIgnored
    } 0
}
catch {
    Write-EventResult @{ ok = $false; error = 'EVENT_INTAKE_FAILED'; route = 'INVALID'; reason = $_.Exception.Message } 1
}
