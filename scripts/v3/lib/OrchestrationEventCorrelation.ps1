<#!
.SYNOPSIS
    Event correlation and dedup for the Kernel (M6, issues #183/#185).
.DESCRIPTION
    Pure decision layer: an event envelope is validated, deduplicated by
    delivery id, and routed to the owning Task or held for admission. It does
    not poll GitHub, create Tasks or dispatch workers; GH-WAKE/Kernel remain
    the execution owners. PS 5.1, ASCII-only.
#>
$script:EventSources = @('github')
$script:EventTriggers = @('issue_comment', 'pull_request_review', 'ci_status', 'push')

function Get-OrchestrationEventHash {
    param([string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-OrchestrationEventEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Trigger,
        [Parameter(Mandatory = $true)][string]$Thread,
        [Parameter(Mandatory = $true)][string]$DeliveryId,
        [Parameter(Mandatory = $true)][string]$Repo,
        [bool]$InformationalOnly = $false,
        [AllowEmptyString()][string]$Summary = ''
    )
    try {
        $src = ([string]$Source).Trim().ToLowerInvariant()
        if ($script:EventSources -notcontains $src) { return @{ ok = $false; error = 'EVENT_SOURCE_UNSUPPORTED' } }
        $trg = ([string]$Trigger).Trim().ToLowerInvariant()
        if ($script:EventTriggers -notcontains $trg) { return @{ ok = $false; error = 'EVENT_TRIGGER_UNSUPPORTED' } }
        $th = ([string]$Thread).Trim().ToLowerInvariant()
        if ($th -cnotmatch '^(pr|issue|branch):[A-Za-z0-9._/-]{1,120}$') { return @{ ok = $false; error = 'EVENT_THREAD_INVALID' } }
        $did = ([string]$DeliveryId).Trim()
        if ($did -cnotmatch '^[A-Za-z0-9._:-]{4,160}$') { return @{ ok = $false; error = 'EVENT_DELIVERY_INVALID' } }
        $rp = ([string]$Repo).Trim()
        if ($rp -cnotmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { return @{ ok = $false; error = 'EVENT_REPO_INVALID' } }
        if ($Summary.Length -gt 2000) { return @{ ok = $false; error = 'EVENT_SUMMARY_TOO_LARGE' } }
        $dedup = Get-OrchestrationEventHash -Value ($src + '|' + $rp.ToLowerInvariant() + '|' + $did)
        return @{
            ok = $true
            error = ''
            source = $src
            trigger = $trg
            thread = $th
            delivery_id = $did
            repo = $rp
            informational_only = [bool]$InformationalOnly
            summary = $Summary
            dedup_key = $dedup
        }
    }
    catch { return @{ ok = $false; error = 'EVENT_INVALID' } }
}

function Resolve-OrchestrationEventRoute {
    <#
    .SYNOPSIS
        Routes an event once: ATTACH, OBSERVE, NEW_TASK, IGNORE or ESCALATE.
    .DESCRIPTION
        - duplicate delivery -> IGNORE
        - informational only -> IGNORE
        - exactly one non-terminal Task owns the thread -> ATTACH
        - more than one owner -> ESCALATE (never pick silently)
        - no owner: OBSERVE unless proactive admission is explicitly enabled
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Envelope,
        [array]$TaskRoutes = @(),
        [string[]]$SeenDeliveryKeys = @(),
        [bool]$AdmissionEnabled = $false
    )
    try {
        if ($null -eq $Envelope -or -not [bool]$Envelope['ok']) { return @{ ok = $false; route = 'INVALID'; reason = 'envelope-invalid'; task_id = '' } }
        $key = [string]$Envelope['dedup_key']
        if ([string]::IsNullOrWhiteSpace($key)) { return @{ ok = $false; route = 'INVALID'; reason = 'dedup-key-missing'; task_id = '' } }
        if (@($SeenDeliveryKeys) -contains $key) {
            return @{ ok = $true; route = 'IGNORE'; reason = 'duplicate-delivery'; task_id = ''; dedup_key = $key }
        }
        if ([bool]$Envelope['informational_only']) {
            return @{ ok = $true; route = 'IGNORE'; reason = 'informational-only'; task_id = ''; dedup_key = $key }
        }
        $thread = [string]$Envelope['thread']
        $matches = @()
        foreach ($r in @($TaskRoutes)) {
            if ($null -eq $r) { continue }
            if ([string]$r['thread'] -cne $thread) { continue }
            $state = ([string]$r['state']).Trim().ToUpperInvariant()
            if ($state -in @('DONE', 'CANCELLED', 'FAILED')) { continue }
            $tid = ([string]$r['task_id']).Trim()
            if ([string]::IsNullOrWhiteSpace($tid)) { continue }
            $matches += $tid
        }
        $matches = @($matches | Select-Object -Unique)
        if ($matches.Count -eq 1) {
            return @{ ok = $true; route = 'ATTACH'; reason = 'thread-owner'; task_id = [string]$matches[0]; dedup_key = $key }
        }
        if ($matches.Count -gt 1) {
            return @{ ok = $true; route = 'ESCALATE'; reason = 'ambiguous-thread-owner'; task_id = ''; dedup_key = $key }
        }
        if ($AdmissionEnabled) {
            return @{ ok = $true; route = 'NEW_TASK'; reason = 'admission-enabled'; task_id = ''; dedup_key = $key }
        }
        return @{ ok = $true; route = 'OBSERVE'; reason = 'admission-disabled'; task_id = ''; dedup_key = $key }
    }
    catch { return @{ ok = $false; route = 'INVALID'; reason = 'route-failed'; task_id = '' } }
}
