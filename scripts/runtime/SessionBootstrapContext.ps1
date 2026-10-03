<#!
.SYNOPSIS
    Session-start bootstrap wiring for Phase 31 slice 2 (RR-P31-S2).
.DESCRIPTION
    Prints ONE bounded bootstrap context object on stdout and never blocks the
    session start. Thin wiring over the slice 1 builder
    (scripts/v3/lib/OrchestrationBootstrapContext.ps1), which stays read-only
    and parse-only. Nothing here installs, registers or activates anything in
    operator active state: activation remains an operator decision.
    Parse-only by construction: no process spawn, no network, no execution of
    any script other than dot-sourcing the builder lib. The only writes are
    inside an explicitly supplied -TelemetryDir.
    Startup never blocks: any contained failure degrades to a valid JSON
    envelope with status=unavailable plus a reason, and exit 0.
    Output is bounded by -ByteBudget; the wrapper re-checks the serialized
    byte length and, in the extreme case, emits the builder minimum envelope
    (status=oversized). It never truncates bytes by substring.
    Exit codes: 0 = valid JSON emitted (even degraded); 1 = STRUCTURALLY invalid
    parameter usage only (TelemetryDir exists and is a file, ByteBudget not a
    number or below zero, RepoRoot not a directory). An OPERATIONAL telemetry
    failure (directory not creatable, denied access, IO error, cap) never blocks
    the startup: telemetry is disabled for that run, an honest note goes to
    stderr and the full JSON is still emitted with exit 0.
    -ByteBudget bounds the TOTAL stdout, so one byte is reserved for the
    trailing LF and the builder receives ByteBudget-1 of payload budget. When
    even the minimum envelope does not fit, the oversized envelope is emitted
    honestly (slice 1 behavior: the minimum envelope can exceed the budget).
    Compliance telemetry (plan addendum section 8 task 8): with -TelemetryDir,
    appends exactly one sanitized metadata JSONL line per run to
    bootstrap-compliance-YYYYMMDD.jsonl - never the context content. 1 MB cap
    with pre-size accounting under a cross-process exclusive handle
    (FileShare.None acquired before the size read and held through the append),
    fail-closed; contention skips silently. Without -TelemetryDir there is zero
    write.
    PowerShell 5.1 and PS7 compatible. ASCII only.
#>
param(
    [string]$RepoRoot = '',
    [int]$ByteBudget = 8192,
    [string]$TelemetryDir = '',
    [string]$Timestamp = ''
)

$ErrorActionPreference = 'Stop'
$script:bootstrapTelemetryCapBytes = 1048576
$script:bootstrapStdoutBytes = 0
$script:bootstrapEmitted = $false
$script:bootstrapStampText = ''

function Write-BootstrapNotice([string]$Text) {
    try { [Console]::Error.WriteLine('[bootstrap] ' + $Text) } catch { }
}

function Get-BootstrapByteLength([string]$Text) {
    if ($null -eq $Text) { return [long]0 }
    try { return [long][Text.Encoding]::UTF8.GetByteCount($Text) } catch { return [long]0 }
}

function Protect-BootstrapTelemetryText([string]$Value) {
    # Per-field sanitization: hosts, sk- keys, token/key=value pairs, length cap.
    if ($null -eq $Value) { return '' }
    $v = $Value
    $v = $v -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b', '[redacted-host]'
    $v = $v -replace '(?i)\b(token|key|secret|password|bearer)\s*=\s*[^\s,;]+', '$1=[redacted]'
    $v = $v -replace '(?i)sk-[A-Za-z0-9_-]+', '[redacted]'
    if ($v.Length -gt 160) { $v = $v.Substring(0, 160) }
    return $v
}

function Get-BootstrapField($Section, [string]$Name) {
    # Section can be a PSCustomObject (top level) or an ordered dictionary
    # (nested builder sections). Returns @{ Has; Value }.
    if ($null -eq $Section) { return [pscustomobject]@{ Has = $false; Value = $null } }
    try {
        if ($Section -is [System.Collections.IDictionary]) {
            if ($Section.Contains($Name)) { return [pscustomobject]@{ Has = $true; Value = $Section[$Name] } }
            return [pscustomobject]@{ Has = $false; Value = $null }
        }
    }
    catch { return [pscustomobject]@{ Has = $false; Value = $null } }
    try {
        $prop = $Section.PSObject.Properties[$Name]
        if ($null -ne $prop) { return [pscustomobject]@{ Has = $true; Value = $prop.Value } }
    }
    catch { }
    return [pscustomobject]@{ Has = $false; Value = $null }
}

function Get-BootstrapEnvelopeStatus($Ctx) {
    $f = Get-BootstrapField $Ctx 'status'
    if ($f.Has) { return ([string]$f.Value) }
    return 'ok'
}

function Get-BootstrapSectionStats($Ctx) {
    $names = @('runtime', 'capability_health', 'tasks', 'pending_waits', 'jev_status', 'aimemory_status')
    $ok = 0
    $unavailable = 0
    foreach ($name in $names) {
        $section = (Get-BootstrapField $Ctx $name).Value
        $missing = $true
        if ($null -ne $section) {
            if ($name -eq 'runtime') {
                $missing = (-not (Get-BootstrapField $section 'generation').Has)
            }
            else {
                $st = Get-BootstrapField $section 'status'
                $missing = ($st.Has -and ([string]$st.Value) -eq 'unavailable')
            }
        }
        if ($missing) { $unavailable++ } else { $ok++ }
    }
    return [pscustomobject]@{ Ok = $ok; Unavailable = $unavailable }
}

function Get-BootstrapClock([string]$Raw, [ref]$Note) {
    $Note.Value = 'utc-internal'
    if (-not [string]::IsNullOrWhiteSpace($Raw)) {
        $parsed = [datetimeoffset]::MinValue
        $okParse = $false
        try {
            $okParse = [datetimeoffset]::TryParse($Raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
        }
        catch { $okParse = $false }
        if ($okParse) {
            try {
                $Note.Value = 'injected'
                return $parsed.ToUniversalTime()
            }
            catch { }
        }
        $Note.Value = 'utc-internal:invalid-timestamp'
        Write-BootstrapNotice 'invalid -Timestamp; falling back to internal UTC clock (honest note).'
    }
    return [datetimeoffset]::UtcNow
}

function New-BootstrapEnvelope([string]$Status, [string]$Reason, [string]$StampText, [bool]$Oversized) {
    # Minimum valid envelope, same section shape as the builder.
    $doc = [ordered]@{
        status           = $Status
        reason           = $Reason
        truncated        = [bool]$Oversized
        oversized        = [bool]$Oversized
        generated_at     = $StampText
        project_id       = 'unknown'
        runtime          = [ordered]@{ generation = 'unknown'; source = 'not-probed' }
        capability_health = [ordered]@{ status = 'unavailable' }
        tasks            = [ordered]@{ status = 'unavailable' }
        pending_waits    = [ordered]@{ status = 'unavailable' }
        jev_status       = [ordered]@{ status = 'unavailable' }
        aimemory_status  = [ordered]@{ status = 'unavailable' }
    }
    return [pscustomobject]$doc
}

function New-BootstrapMinimumEnvelope() {
    return [pscustomobject][ordered]@{ status = 'oversized'; truncated = $true; oversized = $true }
}

function Write-BootstrapStdout([string]$Text) {
    $payload = ($Text + "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $script:bootstrapStdoutBytes = [long]$bytes.Length
    $script:bootstrapEmitted = $true
    try {
        $stream = [Console]::OpenStandardOutput()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    catch {
        try { Write-Output $payload } catch { }
    }
}

function Write-BootstrapComplianceTelemetry {
    <#
    .SYNOPSIS
        Appends ONE sanitized compliance metadata line to the daily JSONL.
    .DESCRIPTION
        Metadata only: timestamp, project_id, byte_length, byte_budget, closed
        status token, section ok/unavailable counts, truncated/oversized flags,
        runtime generation and clock source. Never the context content.
        Cross-process exclusion (FIX2): the daily JSONL is opened with
        FileShare.None BEFORE the size read and held through the append, so
        measure+append is atomic across processes and the 1 MB cap cannot be
        raced (an in-process lock would not protect against another process).
        The wait for the exclusive handle is bounded; contention skips
        SILENTLY and never blocks. Fail-closed: accounting failure, denied
        access or 1 MB overflow refuses the write with a skipped reason and
        never truncates a line. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TelemetryDir,
        [Parameter(Mandatory = $true)][string]$StampDay,
        [Parameter(Mandatory = $true)][string]$StampText,
        [Parameter(Mandatory = $true)][string]$ClockNote,
        [Parameter(Mandatory = $true)]$Ctx,
        [long]$ByteLength = 0,
        [int]$ByteBudget = 8192
    )
    try {
        $target = ''
        try { $target = Join-Path $TelemetryDir ('bootstrap-compliance-' + $StampDay + '.jsonl') } catch { $target = '' }
        if ([string]::IsNullOrWhiteSpace($target)) { return [pscustomobject]@{ ok = $false; skipped = 'no-target' } }

        $statusToken = Get-BootstrapEnvelopeStatus $Ctx
        if ($statusToken -notin @('ok', 'oversized', 'unavailable')) { $statusToken = 'degraded' }
        $stats = Get-BootstrapSectionStats $Ctx
        $truncField = Get-BootstrapField $Ctx 'truncated'
        $overField = Get-BootstrapField $Ctx 'oversized'
        $genField = (Get-BootstrapField (Get-BootstrapField $Ctx 'runtime').Value 'generation')
        $projectField = Get-BootstrapField $Ctx 'project_id'
        $doc = [ordered]@{
            ts                  = (Protect-BootstrapTelemetryText $StampText)
            source              = 'session-bootstrap'
            status              = $statusToken
            clock               = (Protect-BootstrapTelemetryText $ClockNote)
            project_id          = (Protect-BootstrapTelemetryText ([string]$projectField.Value))
            byte_length         = [long]$ByteLength
            byte_budget         = [long]$ByteBudget
            sections_ok         = [int]$stats.Ok
            sections_unavailable = [int]$stats.Unavailable
            truncated           = [bool]$truncField.Value
            oversized           = [bool]$overField.Value
            runtime_generation  = (Protect-BootstrapTelemetryText ([string]$genField.Value))
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 4 -Compress) } catch { $text = '' }
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ ok = $false; skipped = 'serialize' } }
        $line = ($text + "`n")

        # Exclusive cross-process handle: acquired before the size read, held
        # through the append. Bounded wait; contention skips silently.
        $stream = $null
        $deadline = [DateTime]::UtcNow.AddMilliseconds(400)
        while ($null -eq $stream) {
            try {
                $stream = [System.IO.File]::Open($target, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            }
            catch [System.UnauthorizedAccessException] { return [pscustomobject]@{ ok = $false; skipped = 'write' } }
            catch [System.IO.IOException] { $stream = $null }
            catch { return [pscustomobject]@{ ok = $false; skipped = 'write' } }
            if ($null -ne $stream) { break }
            if ([DateTime]::UtcNow -ge $deadline) { return [pscustomobject]@{ ok = $false; skipped = 'contended' } }
            try { Start-Sleep -Milliseconds 25 } catch { }
        }
        try {
            $eventBytes = Get-BootstrapByteLength $line
            try { $currentLen = [long]$stream.Length } catch { return [pscustomobject]@{ ok = $false; skipped = 'accounting-unavailable' } }
            if (($currentLen + [long]$eventBytes) -gt [long]$script:bootstrapTelemetryCapBytes) {
                return [pscustomobject]@{ ok = $false; skipped = 'cap' }
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($line)
            $null = $stream.Seek(0, [System.IO.SeekOrigin]::End)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            return [pscustomobject]@{ ok = $true; skipped = '' }
        }
        catch { return [pscustomobject]@{ ok = $false; skipped = 'write' } }
        finally { try { if ($null -ne $stream) { $stream.Dispose() } } catch { } }
    }
    catch { return [pscustomobject]@{ ok = $false; skipped = 'internal' } }
}

# ---------------------------------------------------------------------------
# Main flow. Any contained failure still emits valid JSON and exits 0.
# ---------------------------------------------------------------------------
try {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }

    # --- parameter usage: STRUCTURALLY invalid usage is the ONLY exit 1 surface ---
    if ($ByteBudget -lt 0) {
        Write-BootstrapNotice 'invalid usage: -ByteBudget must be greater than or equal to 0.'
        exit 1
    }
    $repo = $RepoRoot
    if ([string]::IsNullOrWhiteSpace($repo)) {
        try { $repo = (Split-Path -Parent (Split-Path -Parent $here)) } catch { $repo = '' }
    }
    if ([string]::IsNullOrWhiteSpace($repo)) {
        Write-BootstrapNotice 'invalid usage: -RepoRoot could not be resolved.'
        exit 1
    }
    try { $repoOk = (Test-Path -LiteralPath $repo -PathType Container) } catch { $repoOk = $false }
    if (-not $repoOk) {
        Write-BootstrapNotice 'invalid usage: -RepoRoot is not a directory.'
        exit 1
    }
    # Telemetry directory: STRUCTURAL misuse (the path exists and is a file)
    # is exit 1; an OPERATIONAL failure only disables telemetry for this run,
    # with an honest stderr note, and never blocks the startup.
    $telemetryEnabled = $false
    if (-not [string]::IsNullOrWhiteSpace($TelemetryDir)) {
        $telemetryIsFile = $false
        try { $telemetryIsFile = (Test-Path -LiteralPath $TelemetryDir -PathType Leaf) } catch { $telemetryIsFile = $false }
        if ($telemetryIsFile) {
            Write-BootstrapNotice 'invalid usage: -TelemetryDir exists and is a file, not a directory.'
            exit 1
        }
        $telemetryDirOk = $false
        try {
            $telemetryDirOk = (Test-Path -LiteralPath $TelemetryDir -PathType Container)
            if (-not $telemetryDirOk) {
                New-Item -ItemType Directory -Path $TelemetryDir -Force | Out-Null
                $telemetryDirOk = (Test-Path -LiteralPath $TelemetryDir -PathType Container)
            }
        }
        catch { $telemetryDirOk = $false }
        if ($telemetryDirOk) { $telemetryEnabled = $true }
        else {
            Write-BootstrapNotice 'telemetry disabled for this run (directory could not be created or is not a directory); startup is never blocked.'
        }
    }

    # --- injectable clock ---
    $clockNote = 'utc-internal'
    $stamp = Get-BootstrapClock $Timestamp ([ref]$clockNote)
    $stampText = $stamp.ToString('o')
    $script:bootstrapStampText = $stampText

    # --- lazy dot-source of the slice 1 builder (the only execution here) ---
    $builderPath = Join-Path $here '..\v3\lib\OrchestrationBootstrapContext.ps1'
    $ctx = $null
    $degradedReason = ''
    $builderAvailable = $false
    try {
        if (Test-Path -LiteralPath $builderPath -PathType Leaf) {
            $parseTokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$parseTokens, [ref]$parseErrors)
            if (($null -ne $parseErrors) -and ([int]@($parseErrors).Count -gt 0)) {
                $degradedReason = 'builder-unparseable'
            }
            else {
                . $builderPath
                $builderAvailable = ($null -ne (Get-Command -Name 'New-OrchestrationBootstrapContext' -CommandType Function -ErrorAction SilentlyContinue))
                if (-not $builderAvailable) { $degradedReason = 'builder-missing-entrypoint' }
            }
        }
        else {
            $degradedReason = 'builder-missing'
        }
    }
    catch { $degradedReason = 'builder-load-failed' }

    # --- payload budget reserves the trailing LF, so the TOTAL stdout
    # (payload + LF) never exceeds -ByteBudget ---
    $payloadBudget = [int]$ByteBudget - 1
    if ($payloadBudget -lt 0) { $payloadBudget = 0 }

    if ($builderAvailable) {
        try {
            $clock = { return $script:bootstrapStampText }
            $ctx = New-OrchestrationBootstrapContext -RepoRoot $repo -ByteBudget $payloadBudget -Clock $clock
            if ($null -eq $ctx) { $degradedReason = 'builder-empty-result' }
        }
        catch { $ctx = $null; $degradedReason = 'builder-invocation-failed' }
    }
    if ($null -eq $ctx) {
        if ([string]::IsNullOrWhiteSpace($degradedReason)) { $degradedReason = 'builder-unavailable' }
        $ctx = New-BootstrapEnvelope 'unavailable' $degradedReason $stampText $false
    }

    # --- serialize + re-check the payload budget (never substring-cut) ---
    $json = ''
    try { $json = ConvertTo-Json -InputObject $ctx -Depth 20 -Compress } catch { $json = '' }
    if ([string]::IsNullOrWhiteSpace($json)) {
        $json = ConvertTo-Json -InputObject (New-BootstrapEnvelope 'unavailable' 'serialize-failed' $stampText $false) -Depth 20 -Compress
    }
    if ((Get-BootstrapByteLength $json) -gt [long]$payloadBudget) {
        # Minimum envelope of the builder. Slice 1 behavior is preserved: when
        # even this cannot fit the requested budget, it is emitted honestly.
        $json = ConvertTo-Json -InputObject (New-BootstrapMinimumEnvelope) -Depth 4 -Compress
    }

    Write-BootstrapStdout $json

    # --- compliance telemetry (metadata only, explicit dir only) ---
    if ($telemetryEnabled) {
        $stampDay = $stamp.ToString('yyyyMMdd')
        $telemetryResult = Write-BootstrapComplianceTelemetry -TelemetryDir $TelemetryDir -StampDay $stampDay -StampText $stampText -ClockNote $clockNote -Ctx $ctx -ByteLength ([long]$script:bootstrapStdoutBytes) -ByteBudget $ByteBudget
        # Contention skips SILENTLY; every other skip (denied access, IO, cap,
        # accounting) is reported honestly on stderr and never blocks startup.
        if ((-not [bool]$telemetryResult.ok) -and ([string]$telemetryResult.skipped -cne 'contended')) {
            Write-BootstrapNotice ('telemetry disabled for this run (skipped=' + [string]$telemetryResult.skipped + '); startup is never blocked.')
        }
    }
    exit 0
}
catch {
    if (-not $script:bootstrapEmitted) {
        try {
            $fallback = ConvertTo-Json -InputObject (New-BootstrapEnvelope 'unavailable' 'wrapper-internal-error' $script:bootstrapStampText $false) -Depth 20 -Compress
            Write-BootstrapStdout $fallback
        }
        catch { }
    }
    Write-BootstrapNotice 'contained failure; startup is never blocked.'
    exit 0
}