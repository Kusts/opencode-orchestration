<#!
.SYNOPSIS
    Observation virtualization: full evidence out of context, exact recall.
.DESCRIPTION
    Writes large observations to a content-addressed artifact store and
    returns a bounded preview plus an ArtifactRef. Recall verifies the
    SHA-256 before returning content, so a tampered or truncated file is
    refused. Pure local IO; no network or model call. Callers storing sensitive
    text must redact it before persistence.
    PS 5.1 compatible, ASCII-only.
#>
$script:ObservationArtifactKinds = @('tool-output', 'session-log', 'test-output', 'diff', 'other')

function Get-OrchestrationObservationSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-OrchestrationArtifactStorePath {
    param(
        [Parameter(Mandatory = $true)][string]$StoreDir,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    $root = [IO.Path]::GetFullPath($StoreDir)
    $kindDir = Join-Path $root $Kind
    $path = Join-Path $kindDir ($Sha256 + '.txt')
    $full = [IO.Path]::GetFullPath($path)
    $rootWithSep = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $full
}

function New-OrchestrationArtifactRef {
    <#
    .SYNOPSIS
        Persists observation content and returns its content-addressed ref.
    .OUTPUTS
        @{ ok; artifact_id; sha256; bytes; kind; path; created; error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StoreDir,
        [string]$Kind = 'other',
        [string]$TaskId = '',
        [int]$MaxBytes = 1048576
    )
    try {
        if ([string]::IsNullOrWhiteSpace($StoreDir)) { return @{ ok = $false; error = 'ARTIFACT_STORE_REQUIRED' } }
        $k = ([string]$Kind).Trim().ToLowerInvariant()
        if ($script:ObservationArtifactKinds -notcontains $k) { return @{ ok = $false; error = 'ARTIFACT_KIND_INVALID' } }
        if (-not [string]::IsNullOrWhiteSpace($TaskId) -and ($TaskId -cnotmatch '^[a-z0-9][a-z0-9._-]{2,63}$')) {
            return @{ ok = $false; error = 'ARTIFACT_TASK_ID_INVALID' }
        }
        if ($MaxBytes -lt 1 -or $MaxBytes -gt 16777216) { return @{ ok = $false; error = 'ARTIFACT_MAX_BYTES_INVALID' } }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Content)
        if ($bytes.Length -gt $MaxBytes) { return @{ ok = $false; error = 'ARTIFACT_TOO_LARGE' } }
        $sha = Get-OrchestrationObservationSha256 -Bytes $bytes
        $full = Get-OrchestrationArtifactStorePath -StoreDir $StoreDir -Kind $k -Sha256 $sha
        if ([string]::IsNullOrWhiteSpace($full)) { return @{ ok = $false; error = 'ARTIFACT_PATH_ESCAPE' } }
        $kindDir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $kindDir -PathType Container)) {
            New-Item -ItemType Directory -Path $kindDir -Force | Out-Null
        }
        $created = $false
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $existing = [IO.File]::ReadAllBytes($full)
            if ((Get-OrchestrationObservationSha256 -Bytes $existing) -cne $sha) {
                return @{ ok = $false; error = 'ARTIFACT_HASH_COLLISION' }
            }
        }
        else {
            $tmp = $full + '.tmp-' + [guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllBytes($tmp, $bytes)
            try {
                [IO.File]::Move($tmp, $full)
                $created = $true
            }
            finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        return @{
            ok = $true
            error = ''
            artifact_id = $sha
            sha256 = $sha
            bytes = [int]$bytes.Length
            kind = $k
            task_id = ([string]$TaskId).Trim()
            path = $full
            created = $created
        }
    }
    catch { return @{ ok = $false; error = 'ARTIFACT_WRITE_FAILED' } }
}

function Read-OrchestrationArtifactRef {
    <#
    .SYNOPSIS
        Reads an artifact by ref and verifies its SHA-256 before returning.
    .OUTPUTS
        @{ ok; content; sha256; bytes; error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$StoreDir = '',
        [int]$MaxBytes = 1048576
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            return @{ ok = $false; error = 'ARTIFACT_REF_INVALID' }
        }
        if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { return @{ ok = $false; error = 'ARTIFACT_REF_INVALID' } }
        $full = [IO.Path]::GetFullPath($Path)
        if (-not [string]::IsNullOrWhiteSpace($StoreDir)) {
            $root = [IO.Path]::GetFullPath($StoreDir)
            $rootWithSep = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase)) {
                return @{ ok = $false; error = 'ARTIFACT_PATH_ESCAPE' }
            }
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return @{ ok = $false; error = 'ARTIFACT_NOT_FOUND' } }
        $info = Get-Item -LiteralPath $full
        if ([int64]$info.Length -gt [int64]$MaxBytes) { return @{ ok = $false; error = 'ARTIFACT_TOO_LARGE' } }
        $bytes = [IO.File]::ReadAllBytes($full)
        $sha = Get-OrchestrationObservationSha256 -Bytes $bytes
        if ($sha -cne $ExpectedSha256.ToLowerInvariant()) {
            return @{ ok = $false; error = 'ARTIFACT_HASH_MISMATCH'; sha256 = $sha }
        }
        return @{
            ok = $true
            error = ''
            content = [Text.Encoding]::UTF8.GetString($bytes)
            sha256 = $sha
            bytes = [int]$bytes.Length
        }
    }
    catch { return @{ ok = $false; error = 'ARTIFACT_READ_FAILED' } }
}

function New-OrchestrationVirtualizedObservation {
    <#
    .SYNOPSIS
        Stores the full observation and returns a bounded preview + ref.
    .DESCRIPTION
        The preview is what goes into the model context; the artifact keeps
        the exact bytes for later recall. Preview truncation is explicit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StoreDir,
        [string]$Kind = 'other',
        [string]$TaskId = '',
        [int]$PreviewChars = 2000,
        [int]$MaxBytes = 1048576
    )
    try {
        if ($PreviewChars -lt 1 -or $PreviewChars -gt 65536) { return @{ ok = $false; error = 'PREVIEW_CHARS_INVALID' } }
        $ref = New-OrchestrationArtifactRef -Content $Content -StoreDir $StoreDir -Kind $Kind -TaskId $TaskId -MaxBytes $MaxBytes
        if (-not [bool]$ref.ok) { return @{ ok = $false; error = [string]$ref.error } }
        $text = [string]$Content
        $truncated = ($text.Length -gt $PreviewChars)
        $preview = $text
        if ($truncated) { $preview = $text.Substring(0, $PreviewChars) }
        return @{
            ok = $true
            error = ''
            preview = $preview
            truncated = $truncated
            total_chars = [int]$text.Length
            artifact_ref = $ref
        }
    }
    catch { return @{ ok = $false; error = 'OBSERVATION_VIRTUALIZATION_FAILED' } }
}
