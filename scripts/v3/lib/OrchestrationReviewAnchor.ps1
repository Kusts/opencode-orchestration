<#!
.SYNOPSIS
    Anchored review findings: file + line + commit, drift detection, owner.
.DESCRIPTION
    Pure functions. A finding is only actionable when its anchor still
    matches the reviewed state; drift is reported explicitly instead of
    being silently applied to a different revision. PS 5.1, ASCII-only.
#>
$script:ReviewSeverities = @('low', 'medium', 'high', 'critical')

function Get-OrchestrationReviewFindingsSchema {
    [CmdletBinding()]
    param()
    return [ordered]@{
        schema_version = 1
        max_findings = 50
        max_bytes = 262144
        max_message_chars = 2000
        limits = [ordered]@{
            finding_id_max_chars = 128
            file_max_chars = 512
            line_min = 0
            line_max = 10000000
            commit_sha = '7-40 hexadecimal characters'
            path_rules = @('repository-relative', 'no .. path segment', 'no drive or absolute path', 'no control characters')
            severity_default = 'medium'
            message_max_chars = 2000
        }
        required_fields = @('finding_id', 'file', 'commit_sha', 'message')
        optional_fields = @('severity', 'line')
        derived_fields = @('anchor', 'worker', 'owner_reason', 'file_sha256')
        severities = @('low', 'medium', 'high', 'critical')
        fields = [ordered]@{
            finding_id = 'Non-empty stable finding identifier.'
            file = 'Repository-relative path; must not contain a .. path segment.'
            commit_sha = 'Reviewed commit identifier: 7-40 hexadecimal characters.'
            message = 'Non-empty finding text, at most 2000 characters.'
            severity = 'low, medium, high, or critical; defaults to medium.'
            line = 'Integer line number greater than or equal to 0.'
        }
        example = @(
            [ordered]@{
                finding_id = 'F-1'
                file = 'src/example.ps1'
                commit_sha = 'abcdef1234567'
                message = 'Handle the empty input case.'
                severity = 'medium'
                line = 12
            }
        )
        notes = @(
            'anchor, worker, owner_reason, and file_sha256 are derived; do not send them in the input.'
            'file_sha256 is calculated only when file content is supplied; the Kernel does not send it today.'
            'An approved review containing findings is rejected.'
        )
    }
}

function Get-OrchestrationReviewFileHash {
    param([AllowEmptyString()][string]$Content)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Content)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-OrchestrationReviewPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Trim()
    if ($p.Length -gt 512) { return $false }
    if ($p.StartsWith('/') -or $p.StartsWith('\') -or ($p -match '^[A-Za-z]:')) { return $false }
    if ($p -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($p -match '[\x00-\x1f]') { return $false }
    return $true
}

function New-OrchestrationReviewFinding {
    <#
    .SYNOPSIS
        Builds a validated finding anchored to the reviewed revision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FindingId,
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$CommitSha,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('low', 'medium', 'high', 'critical')][string]$Severity = 'medium',
        [int]$Line = 0,
        [string]$TaskId = '',
        [string]$Worker = '',
        [AllowEmptyString()][string]$FileContent = ''
    )
    try {
        if ([string]::IsNullOrWhiteSpace($FindingId) -or $FindingId.Length -gt 128) { return @{ ok = $false; error = 'FINDING_ID_INVALID' } }
        if (-not (Test-OrchestrationReviewPath -Path $File)) { return @{ ok = $false; error = 'FINDING_PATH_INVALID' } }
        if ($CommitSha -cnotmatch '^[0-9a-fA-F]{7,40}$') { return @{ ok = $false; error = 'FINDING_COMMIT_INVALID' } }
        if ([string]::IsNullOrWhiteSpace($Message)) { return @{ ok = $false; error = 'FINDING_MESSAGE_REQUIRED' } }
        if ($Line -lt 0 -or $Line -gt 10000000) { return @{ ok = $false; error = 'FINDING_LINE_INVALID' } }
        $file = $File.Trim() -replace '\\', '/'
        $commit = $CommitSha.ToLowerInvariant()
        $anchorInput = $file.ToLowerInvariant() + '|' + [string]$Line + '|' + $commit
        $anchor = Get-OrchestrationReviewFileHash -Content $anchorInput
        $fileHash = ''
        if ($PSBoundParameters.ContainsKey('FileContent')) { $fileHash = Get-OrchestrationReviewFileHash -Content $FileContent }
        $owner = Resolve-OrchestrationReviewOwner -File $file
        return @{
            ok = $true
            error = ''
            finding_id = $FindingId.Trim()
            file = $file
            line = [int]$Line
            commit_sha = $commit
            severity = $Severity
            message = $Message
            task_id = ([string]$TaskId).Trim()
            worker = if ([string]::IsNullOrWhiteSpace($Worker)) { [string]$owner.owner } else { $Worker.Trim() }
            owner_reason = [string]$owner.reason
            file_sha256 = $fileHash
            anchor = $anchor
        }
    }
    catch { return @{ ok = $false; error = 'FINDING_INVALID' } }
}

function Test-OrchestrationReviewAnchorCurrent {
    <#
    .SYNOPSIS
        Compares a finding against the current revision and file state.
    .OUTPUTS
        @{ ok; status; reason; finding_id }
        status: CURRENT | DRIFT_COMMIT | DRIFT_FILE_MISSING | DRIFT_CONTENT
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Finding,
        [Parameter(Mandatory = $true)][string]$CurrentCommitSha,
        [bool]$FileExists = $true,
        [AllowEmptyString()][string]$CurrentFileContent = ''
    )
    try {
        if ($null -eq $Finding) { return @{ ok = $false; status = 'INVALID'; reason = 'FINDING_MISSING'; finding_id = '' } }
        $fid = [string]$Finding['finding_id']
        if ([string]::IsNullOrWhiteSpace([string]$Finding['anchor'])) {
            return @{ ok = $false; status = 'INVALID'; reason = 'FINDING_ANCHOR_MISSING'; finding_id = $fid }
        }
        if ($CurrentCommitSha -cnotmatch '^[0-9a-fA-F]{7,40}$') {
            return @{ ok = $false; status = 'INVALID'; reason = 'CURRENT_COMMIT_INVALID'; finding_id = $fid }
        }
        if (-not $FileExists) {
            return @{ ok = $true; status = 'DRIFT_FILE_MISSING'; reason = 'file-missing'; finding_id = $fid }
        }
        $cur = $CurrentCommitSha.ToLowerInvariant()
        if ($cur -cne [string]$Finding['commit_sha']) {
            return @{ ok = $true; status = 'DRIFT_COMMIT'; reason = 'commit-diverged'; finding_id = $fid }
        }
        $expectedFileHash = [string]$Finding['file_sha256']
        if (-not [string]::IsNullOrWhiteSpace($expectedFileHash)) {
            $curFileHash = Get-OrchestrationReviewFileHash -Content $CurrentFileContent
            if ($curFileHash -cne $expectedFileHash) {
                return @{ ok = $true; status = 'DRIFT_CONTENT'; reason = 'file-content-diverged'; finding_id = $fid }
            }
        }
        return @{ ok = $true; status = 'CURRENT'; reason = 'anchor-current'; finding_id = $fid }
    }
    catch { return @{ ok = $false; status = 'INVALID'; reason = 'ANCHOR_CHECK_FAILED'; finding_id = '' } }
}

function Resolve-OrchestrationReviewOwner {
    <#
    .SYNOPSIS
        Routes a finding to the most likely owning worker by changed path.
    .DESCRIPTION
        A routing hint, never a permission or authority grant. Defaults to
        the T2 coder when the path does not identify a specialist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$File)
    $p = ([string]$File).Trim().ToLowerInvariant() -replace '\\', '/'
    if ($p -match '(^|/)(migrations?|schema|db|database)/' -or $p -match '\.sql$') {
        return @{ owner = 'database-engineer'; reason = 'database-path' }
    }
    if ($p -match '(^|/)(\.github/workflows|docker|infra|terraform|k8s|helm|deploy)/' -or $p -match '(^|/)(dockerfile|docker-compose\.ya?ml)$') {
        return @{ owner = 'infra-engineer'; reason = 'infra-path' }
    }
    if ($p -match '\.(tsx|jsx|css|scss|sass|less|html|vue|svelte)$' -or $p -match '(^|/)(web|frontend|components|pages)/') {
        return @{ owner = 'frontend-engineer'; reason = 'frontend-path' }
    }
    if ($p -match '\.(py|go|java|rb|php|cs)$' -or $p -match '(^|/)(api|server|backend|services)/') {
        return @{ owner = 'backend-engineer'; reason = 'backend-path' }
    }
    if ($p -match '\.md$') { return @{ owner = 'docs-manager'; reason = 'docs-path' } }
    return @{ owner = 'coder'; reason = 'default-owner' }
}
