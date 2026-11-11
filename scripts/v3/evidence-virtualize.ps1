<#
.SYNOPSIS
    CLI for content-addressed observation storage and verified recall.
.DESCRIPTION
    Thin wrapper over OrchestrationObservationVirtualization.ps1. Local IO only.
    PowerShell 5.1/7 compatible, ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$Action = '',
    [string]$ContentFile = '',
    [AllowEmptyString()][string]$Content = '',
    [string]$Kind = 'other',
    [string]$StoreDir = 'cache/v3/evidence-artifacts',
    [string]$TaskId = '',
    [int]$PreviewChars = 2000,
    [string]$ArtifactId = '',
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationObservationVirtualization.ps1')

function Write-EvidenceVirtualizeJson {
    param($Value)
    Write-Output (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}

function Stop-EvidenceVirtualize {
    param([string]$ErrorCode, [int]$ExitCode)
    Write-EvidenceVirtualizeJson ([ordered]@{ ok = $false; error = $ErrorCode })
    exit $ExitCode
}

$actionValue = $Action.Trim().ToLowerInvariant()
if (@('store', 'recall', 'preview') -cnotcontains $actionValue) { Stop-EvidenceVirtualize 'USAGE_ACTION_INVALID' 2 }
if ($PreviewChars -lt 200 -or $PreviewChars -gt 20000) { Stop-EvidenceVirtualize 'USAGE_PREVIEW_CHARS_INVALID' 2 }
if ([string]::IsNullOrWhiteSpace($StoreDir)) { Stop-EvidenceVirtualize 'USAGE_STORE_DIR_REQUIRED' 2 }

switch ($actionValue) {
    'store' {
        $hasFile = $PSBoundParameters.ContainsKey('ContentFile') -and -not [string]::IsNullOrWhiteSpace($ContentFile)
        $hasContent = $PSBoundParameters.ContainsKey('Content')
        if ($hasFile -eq $hasContent) { Stop-EvidenceVirtualize 'USAGE_STORE_REQUIRES_CONTENTFILE_OR_CONTENT' 2 }
        if (@('tool-output', 'session-log', 'test-output', 'diff', 'other') -cnotcontains $Kind.Trim().ToLowerInvariant()) { Stop-EvidenceVirtualize 'ARTIFACT_KIND_INVALID' 2 }
        if ($hasFile) {
            if (-not (Test-Path -LiteralPath $ContentFile -PathType Leaf)) { Stop-EvidenceVirtualize 'CONTENT_FILE_NOT_FOUND' 2 }
            try { $contentValue = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ContentFile).Path, [Text.Encoding]::UTF8) }
            catch { Stop-EvidenceVirtualize 'CONTENT_FILE_READ_FAILED' 1 }
        }
        else { $contentValue = $Content }
        $stored = New-OrchestrationVirtualizedObservation -Content $contentValue -StoreDir $StoreDir -Kind $Kind -TaskId $TaskId -PreviewChars $PreviewChars
        if (-not [bool]$stored.ok) { Stop-EvidenceVirtualize ([string]$stored.error) 1 }
        $ref = $stored.artifact_ref
        $preview = [string]$stored.preview
        $previewBytes = [Text.Encoding]::UTF8.GetByteCount($preview)
        Write-EvidenceVirtualizeJson ([ordered]@{
            ok = $true; artifact_id = [string]$ref.artifact_id; sha256 = [string]$ref.sha256
            bytes = [int]$ref.bytes; kind = [string]$ref.kind; path = [string]$ref.path
            preview = $preview; preview_bytes = [int]$previewBytes; full_bytes = [int]$ref.bytes; error = ''
        })
        exit 0
    }
    default {
        $hasId = -not [string]::IsNullOrWhiteSpace($ArtifactId)
        $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
        if ($hasId -eq $hasPath) { Stop-EvidenceVirtualize 'USAGE_RECALL_REQUIRES_ARTIFACTID_OR_PATH' 2 }
        $storeRoot = [IO.Path]::GetFullPath($StoreDir)
        if ($hasId) {
            $expected = $ArtifactId.Trim().ToLowerInvariant()
            if ($expected -cnotmatch '^[0-9a-f]{64}$') { Stop-EvidenceVirtualize 'ARTIFACT_REF_INVALID' 2 }
            $artifactPath = ''
            foreach ($kindName in @('tool-output', 'session-log', 'test-output', 'diff', 'other')) {
                $candidate = Join-Path (Join-Path $storeRoot $kindName) ($expected + '.txt')
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $artifactPath = $candidate; break }
            }
            if ([string]::IsNullOrWhiteSpace($artifactPath)) { Stop-EvidenceVirtualize 'ARTIFACT_NOT_FOUND' 1 }
        }
        else {
            if ([IO.Path]::IsPathRooted($Path)) { $artifactPath = [IO.Path]::GetFullPath($Path) }
            else { $artifactPath = [IO.Path]::GetFullPath((Join-Path $storeRoot $Path)) }
            $rootWithSep = $storeRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $artifactPath.StartsWith($rootWithSep, [StringComparison]::OrdinalIgnoreCase)) { Stop-EvidenceVirtualize 'ARTIFACT_PATH_ESCAPE' 1 }
            $leaf = [IO.Path]::GetFileName($artifactPath)
            if ($leaf -cnotmatch '^([0-9a-fA-F]{64})\.txt$') { Stop-EvidenceVirtualize 'ARTIFACT_REF_INVALID' 2 }
            $expected = $Matches[1].ToLowerInvariant()
        }
        $read = Read-OrchestrationArtifactRef -Path $artifactPath -ExpectedSha256 $expected -StoreDir $storeRoot
        if (-not [bool]$read.ok) { Stop-EvidenceVirtualize ([string]$read.error) 1 }
        $contentResult = [string]$read.content
        if ($actionValue -ceq 'preview' -and $contentResult.Length -gt $PreviewChars) { $contentResult = $contentResult.Substring(0, $PreviewChars) }
        Write-EvidenceVirtualizeJson ([ordered]@{ ok = $true; sha256 = [string]$read.sha256; bytes = [int]$read.bytes; content = $contentResult })
        exit 0
    }
}
