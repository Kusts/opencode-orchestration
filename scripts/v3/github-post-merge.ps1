[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][int]$PrNumber,
    [ValidateSet('Plan','Apply')][string]$Mode = 'Plan',
    [string]$GhCommand = 'gh',
    [string]$SessionProbeCommand = '',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/OrchestrationWorktree.ps1')

function Invoke-PMCommand([string]$Exe, [string[]]$CommandArgs, [string]$Cwd) {
    Push-Location $Cwd
    try {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $text = (& $Exe @CommandArgs 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference
        if ($code -ne 0) { throw "$Exe failed: $text" }
        return $text
    } finally { $ErrorActionPreference=$oldPreference; Pop-Location }
}
function Invoke-GhJson([string[]]$Args) {
    $raw = Invoke-PMCommand $GhCommand $Args $RepoRoot
    return ConvertFrom-Json $raw
}
function Get-ActiveWorktreePaths([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { throw 'SESSION_PROBE_UNAVAILABLE' }
    $paths = New-Object System.Collections.ArrayList
    try {
        $data = ConvertFrom-Json $Raw
        if ($data -is [System.Array]) {
            foreach($item in $data) {
                if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) { throw 'invalid session path array' }
                [void]$paths.Add([string]$item)
            }
            return @($paths.ToArray())
        }
        $items = $null
        if ($null -ne $data.result -and $null -ne $data.result.PSObject.Properties['worktrees']) { $items=@($data.result.worktrees) }
        elseif ($null -ne $data.PSObject.Properties['worktrees']) { $items=@($data.worktrees) }
        else { throw 'unknown session probe schema' }
        foreach($wt in $items) {
            if ($null -eq $wt.path -or -not ($wt.path -is [string]) -or [string]::IsNullOrWhiteSpace($wt.path)) { throw 'invalid worktree path' }
            [void]$paths.Add([string]$wt.path)
        }
    } catch {
        throw 'SESSION_PROBE_UNAVAILABLE'
    }
    return @($paths.ToArray())
}
function Invoke-PMProbe([string]$Exe,[string[]]$CommandArgs,[string]$Cwd) {
    $errFile=[IO.Path]::GetTempFileName()
    try {
        Push-Location $Cwd
        try {
            $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
            $stdout = (& $Exe @CommandArgs 2> $errFile | Out-String).Trim()
            $code=$LASTEXITCODE
            $ErrorActionPreference=$old
        } finally { $ErrorActionPreference=$old; Pop-Location }
        $stderr=[IO.File]::ReadAllText($errFile).Trim()
        if ($code -ne 0 -or $stderr) { throw 'SESSION_PROBE_UNAVAILABLE' }
        return $stdout
    } finally { Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
}
function Invoke-SessionProbe {
    $command = $SessionProbeCommand
    $args = @()
    if (-not $command) {
        $orca = Get-Command orca -ErrorAction SilentlyContinue
        if (-not $orca) { throw 'SESSION_PRESENCE_UNPROVEN' }
        $command = [string]$orca.Source
        $args = @('worktree','ps','--json')
    }
    elseif ($command -match '^"([^"]+)"(?:\s+(.*))?$') {
        $command = $Matches[1]
        if ($Matches[2]) { $args = @($Matches[2] -split '\s+') }
    }
    elseif ($command -match '^(\S+)\s+(.+)$') {
        $command = $Matches[1]
        $args = @($Matches[2] -split '\s+')
    }
    return (Invoke-PMProbe $command $args $RepoRoot)
}
$result = [ordered]@{
    pr = $PrNumber; mode = $Mode; verdict = 'BLOCKED'; stages = [ordered]@{};
    skipped = @(); reasons = @(); removed = @(); preserved = @()
}
try {
    $pr = Invoke-GhJson @('pr','view',[string]$PrNumber,'--json','state,mergedAt,mergeCommit,baseRefName,headRefName,mergeMethod,statusCheckRollup')
    if ([string]$pr.state -ne 'MERGED' -or -not $pr.mergedAt -or -not $pr.mergeCommit.oid) { throw 'PR_NOT_MERGED_OR_MISSING_MERGE_SHA' }
    $bad = @($pr.statusCheckRollup | Where-Object {
        $conclusion = [string]$_.conclusion
        $hasStatus = $null -ne $_.PSObject.Properties['status']
        ($conclusion -notin @('SUCCESS','SKIPPED','NEUTRAL')) -or
        ($hasStatus -and ([string]$_.status -cne 'COMPLETED'))
    })
    if ($bad.Count) { throw 'CHECKS_PENDING_OR_FAILED' }
    $result.pr_snapshot = @{ state=$pr.state; mergedAt=$pr.mergedAt; merge_sha=$pr.mergeCommit.oid; base=$pr.baseRefName; head=$pr.headRefName; method=$pr.mergeMethod }
    $base = [string]$pr.baseRefName
    if ([string]::IsNullOrWhiteSpace($base)) {
        $default = $null
        try { $default = Invoke-GhJson @('repo','view','--json','defaultBranchRef') } catch {}
        if ($default.defaultBranchRef.name) { $base=[string]$default.defaultBranchRef.name }
        else {
            $head = Invoke-PMCommand 'git' @('symbolic-ref','refs/remotes/origin/HEAD') $RepoRoot
            if ($head -match '^refs/remotes/origin/(.+)$') { $base=$Matches[1] }
        }
    }
    if (-not $base) { throw 'BASE_BRANCH_UNPROVEN' }
    $status = Invoke-PMCommand 'git' @('status','--porcelain') $RepoRoot
    if ($status) { throw 'BASE_WORKTREE_DIRTY' }
    $branch = (Invoke-PMCommand 'git' @('branch','--show-current') $RepoRoot)
    if ($branch -cne $base) { throw 'CHECKOUT_NOT_BASE_BRANCH' }
    $before = Invoke-PMCommand 'git' @('rev-parse','HEAD') $RepoRoot
    $result.stages.sync = 'planned'
    if ($Mode -eq 'Apply') {
        Invoke-PMCommand 'git' @('fetch','origin',$base) $RepoRoot | Out-Null
        try { Invoke-PMCommand 'git' @('merge-base','--is-ancestor',[string]$pr.mergeCommit.oid,"origin/$base") $RepoRoot | Out-Null }
        catch { throw 'MERGE_SHA_NOT_ANCESTOR' }
        Invoke-PMCommand 'git' @('merge','--ff-only',"origin/$base") $RepoRoot | Out-Null
        $result.stages.sync='fast-forwarded'
    }
    $local = Invoke-PMCommand 'git' @('rev-parse','HEAD') $RepoRoot
    $remote = if ($Mode -eq 'Apply') { Invoke-PMCommand 'git' @('rev-parse',"origin/$base") $RepoRoot } else { '' }
    if ($Mode -eq 'Apply' -and $local -ne $remote) { throw 'LOCAL_REMOTE_SHA_DIVERGED' }
    if ($Mode -eq 'Apply') {
        $activePaths = @()
        $probeStatus = 'ok'
        try { $activePaths = @(Get-ActiveWorktreePaths (Invoke-SessionProbe)) }
        catch {
            $probeStatus = 'failed'
            $result.stages.session_probe = $_.Exception.Message
        }
        $listing = Invoke-PMCommand 'git' @('worktree','list','--porcelain') $RepoRoot
        $blocks = @($listing -split '(?:\r?\n){2}' | Where-Object { $_ -match '(?m)^worktree ' })
        foreach ($block in $blocks) {
            $path = ([regex]::Match($block,'(?m)^worktree (.+)$')).Groups[1].Value.Trim()
            $wtBranch = ([regex]::Match($block,'(?m)^branch refs/heads/(.+)$')).Groups[1].Value.Trim()
            if (-not $path -or ([IO.Path]::GetFullPath($path).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/'))) { continue }
            $markerPath = Join-Path $path '.orchestration-worktree.json'
            $marker = $null
            if (Test-Path -LiteralPath $markerPath) { try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch {} }
            $taskId = ''
            if ($wtBranch -match '^orchestration/(.+)$') { $taskId=$Matches[1] }
            $mapped = (($wtBranch -ceq [string]$pr.headRefName) -and $taskId -match '^[a-z0-9][a-z0-9._-]{2,63}$') -or
                (($null -ne $marker) -and ([string]$marker.pr_number -ceq [string]$PrNumber))
            if (-not $mapped) { $result.preserved += @{path=$path;code='PR_MAPPING_UNPROVEN'}; continue }
            if (-not $taskId -and $marker) { $taskId=[string]$marker.task_id }
            if (-not $taskId -or -not $marker -or [string]$marker.task_id -cne $taskId) { $result.preserved += @{path=$path;code='WORKTREE_NOT_OWNED'}; continue }
            $dirty = Invoke-PMCommand 'git' @('-C',$path,'status','--porcelain') $RepoRoot
            if ($dirty) { $result.preserved += @{path=$path;code='WORKTREE_DIRTY_PRESERVED'}; continue }
            $ancestor = $true
            try { Invoke-PMCommand 'git' @('merge-base','--is-ancestor',$wtBranch,"origin/$base") $RepoRoot | Out-Null } catch { $ancestor=$false }
            if (-not $ancestor) { $result.preserved += @{path=$path;code='BRANCH_NOT_INTEGRATED'}; continue }
            if ($probeStatus -ne 'ok') {
                $code = if ($result.stages.session_probe -eq 'SESSION_PRESENCE_UNPROVEN') {'SESSION_PRESENCE_UNPROVEN'} else {'SESSION_PROBE_UNAVAILABLE'}
                $result.preserved += @{path=$path;code=$code}; continue
            }
            $isActive = $false
            foreach($active in $activePaths) {
                try { if ([IO.Path]::GetFullPath($active).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($path).TrimEnd('\','/')) { $isActive=$true } } catch {}
            }
            if ($isActive) { $result.preserved += @{path=$path;code='SESSION_ACTIVE'}; continue }
            $expectedPath = Get-OrchestrationWorktreePath -TaskId $taskId -RepoRoot $RepoRoot
            if ([IO.Path]::GetFullPath($path) -ine [IO.Path]::GetFullPath($expectedPath)) { $result.preserved += @{path=$path;code='WORKTREE_PATH_MISMATCH'}; continue }
            if ($wtBranch -cne ('orchestration/' + $taskId)) { $result.preserved += @{path=$path;code='PR_MAPPING_BRANCH_MISMATCH'}; continue }
            $markerNow = $null
            try { $markerNow = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch {}
            if ($null -eq $markerNow -or [string]$markerNow.task_id -cne [string]$marker.task_id -or [string]$markerNow.pr_number -cne [string]$marker.pr_number) {
                $result.preserved += @{path=$path;code='WORKTREE_MARKER_CHANGED'}; continue
            }
            $removed = Remove-OrchestrationWorktree -TaskId $taskId -RepoRoot $RepoRoot -DeleteBranch -SafeBranchDelete
            if ($removed.ok) { $result.removed += @{path=$path;task_id=$taskId;branch=$removed.branch} }
            else { $result.preserved += @{path=$path;code=[string]$removed.error} }
        }
    }
    $local = Invoke-PMCommand 'git' @('rev-parse','HEAD') $RepoRoot
    if ($Mode -eq 'Apply') {
        $remote = Invoke-PMCommand 'git' @('rev-parse',"origin/$base") $RepoRoot
        if ($local -ne $remote) { throw 'LOCAL_REMOTE_SHA_DIVERGED' }
    }
    $result.local_sha=$local; $result.remote_sha=$remote
    $result.stages.sha_confirmation= if ($Mode -eq 'Plan') {'not-applied'} else {'confirmed'}
    $result.verdict= if ($Mode -eq 'Plan') {'PLAN_READY'} else {'APPLIED'}
} catch {
    $result.reasons += $_.Exception.Message
}
$json = $result | ConvertTo-Json -Depth 8
if ($Output) { [IO.File]::WriteAllText($Output,$json,[Text.Encoding]::UTF8) }
$json
if ($result.verdict -eq 'BLOCKED') { exit 1 }
