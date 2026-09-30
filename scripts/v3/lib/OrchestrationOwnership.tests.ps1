<#!
.SYNOPSIS
    Tests for OrchestrationOwnership.ps1 (leases) and OrchestrationWorktree.ps1.
.DESCRIPTION
    Standalone suite; all state in TEMP fixtures. Never touches the real
    repo git state, real locks dir, or real flags. Run directly or via
    scripts/v3/run-v3-tests.ps1 -Name OrchestrationOwnership.
    Bracketed verdicts ([PASS]/[FAIL]/[SKIP]); exit 0/1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationOwnership.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationWorktree.ps1')

$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Assert-OwnTrue {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    } else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-OwnFixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = (($Text -replace "`r`n", "`n") -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-ownership-' + [guid]::NewGuid().ToString('N'))
$locks = Join-Path $base 'locks'
$wtRoot = Join-Path $base 'worktrees'
$telemetry = Join-Path $base 'telemetry-root'
$flagsOn = Join-Path $base 'flags-on.json'
$flagsOff = Join-Path $base 'flags-off.json'
$gitRepo = Join-Path $base 'fixture-repo'

function Get-GitAvailable {
    try { return ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) }
    catch { return $false }
}

try {
    New-Item -ItemType Directory -Path $locks -Force | Out-Null
    New-Item -ItemType Directory -Path $wtRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $telemetry -Force | Out-Null
    Write-OwnFixture -Path $flagsOn -Text '{"version":1,"task_kernel":{"enabled":true,"shadow":false},"worktree_isolation":{"enabled":true}}'
    Write-OwnFixture -Path $flagsOff -Text '{"version":1,"task_kernel":{"enabled":false,"shadow":true},"worktree_isolation":{"enabled":false}}'

    # ---------- leases ----------

    $l1 = New-OrchestrationWriteLease -TaskId 'v1-writer-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\api') -BaseSha 'abc123' -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ([bool]$l1.ok) 'lease: v1 task acquires scope'
    Assert-OwnTrue (([string]$l1.lease_id -ceq 'lease-v1-writer-task')) 'lease: lease id is lease-<taskid>'

    $l2 = New-OrchestrationWriteLease -TaskId 'v2-writer-task' -RuntimeId 'opencode-v2' -RuntimeProfile 'v2' -WriteScopes @('src/api') -BaseSha 'abc123' -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ((-not [bool]$l2.ok) -and ([string]$l2.error -ceq 'LEASE_CONFLICT')) 'lease: v2 same scope conflicts across generations'
    Assert-OwnTrue ((@($l2.conflicting_with) -contains 'lease-v1-writer-task')) 'lease: conflict names the v1 lease'
    Assert-OwnTrue ((-not (Test-Path -LiteralPath (Join-Path $locks 'lease-v2-writer-task.json')))) 'lease: conflict writes nothing'

    $d1 = New-OrchestrationWriteLease -TaskId 'disjoint-task-a' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\aaa-unique') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    $d2 = New-OrchestrationWriteLease -TaskId 'disjoint-task-b' -RuntimeId 'opencode-v2' -RuntimeProfile 'v2' -WriteScopes @('src\bbb-unique') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue (([bool]$d1.ok) -and ([bool]$d2.ok)) 'lease: disjoint scopes both active'

    $e1 = New-OrchestrationWriteLease -TaskId 'empty-scope-one' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @() -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    $e2 = New-OrchestrationWriteLease -TaskId 'empty-scope-two' -RuntimeId 'opencode-v2' -RuntimeProfile 'v2' -WriteScopes @() -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue (([bool]$e1.ok) -and ([bool]$e2.ok)) 'lease: empty scopes never conflict'

    $partialFile = Join-Path $locks 'lease-partial-task.json'
    $futureExp = ((Get-Date).ToUniversalTime().AddHours(1)).ToString('o')
    Write-OwnFixture -Path $partialFile -Text ('{"schema_version":1,"lease_id":"lease-partial-task","task_id":"partial-task","expires_at":"' + $futureExp + '"}')
    $pConflict = New-OrchestrationWriteLease -TaskId 'partial-probe-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\partial-scope') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ((-not [bool]$pConflict.ok) -and ([string]$pConflict.error -ceq 'LEASE_CONFLICT') -and ([string]$pConflict.reason -ceq 'malformed_active_lease')) 'lease: partial lease (task_id+expiry, no scopes) fail-closed conflicts'
    Remove-Item -LiteralPath $partialFile -Force -ErrorAction SilentlyContinue
    $validEmptyFile = Join-Path $locks 'lease-empty-scope-one.json'
    Assert-OwnTrue ((Test-Path -LiteralPath $validEmptyFile -PathType Leaf)) 'lease: valid empty-scopes file persists'
    $e3 = New-OrchestrationWriteLease -TaskId 'empty-scope-three' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\brand-new-scope') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ([bool]$e3.ok) 'lease: valid lease with empty scopes does not block disjoint acquire'

    $r1 = New-OrchestrationWriteLease -TaskId 'reacquire-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\re') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    $r2 = New-OrchestrationWriteLease -TaskId 'reacquire-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\re') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue (([bool]$r1.ok) -and ([bool]$r2.ok) -and ([int]$r2.revision -gt [int]$r1.revision)) 'lease: same task re-acquire refreshes revision'
    Assert-OwnTrue ((@(Get-ChildItem -LiteralPath $locks -File -Filter 'lease-reacquire-task.json').Count -eq 1) ) 'lease: re-acquire leaves a single file'

    $rel = Release-OrchestrationWriteLease -TaskId 'reacquire-task' -LocksDir $locks
    Assert-OwnTrue (([bool]$rel.ok) -and (-not (Test-Path -LiteralPath (Join-Path $locks 'lease-reacquire-task.json')))) 'lease: owner release deletes the file'

    $relMissing = Release-OrchestrationWriteLease -TaskId 'reacquire-task' -LocksDir $locks
    Assert-OwnTrue (([string]$relMissing.error -ceq 'LEASE_NOT_FOUND')) 'lease: release of missing lease reports NOT_FOUND'

    $o1 = New-OrchestrationWriteLease -TaskId 'owned-task-probe' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\owned') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ([bool]$o1.ok) 'lease: ownership probe acquires'
    $probeFile = Join-Path $locks 'lease-owned-task-probe.json'
    $probeDoc = ([IO.File]::ReadAllText($probeFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $probeDoc.task_id = 'someone-else'
    Write-OwnFixture -Path $probeFile -Text ($probeDoc | ConvertTo-Json -Depth 16 -Compress)
    $denied = Release-OrchestrationWriteLease -TaskId 'owned-task-probe' -LocksDir $locks
    Assert-OwnTrue (([string]$denied.error -ceq 'LEASE_OWNERSHIP_DENIED')) 'lease: mismatched task id release denied'
    Assert-OwnTrue ((Test-Path -LiteralPath $probeFile -PathType Leaf)) 'lease: denied release deletes nothing'
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue

    $x1 = New-OrchestrationWriteLease -TaskId 'expiring-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\ttl') -BaseSha 'x' -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry -TtlSeconds 3600
    Assert-OwnTrue ([bool]$x1.ok) 'lease: ttl task acquires'
    $xFile = Join-Path $locks 'lease-expiring-task.json'
    $xDoc = ([IO.File]::ReadAllText($xFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $xDoc.expires_at = '2000-01-01T00:00:00.0000000Z'
    Write-OwnFixture -Path $xFile -Text ($xDoc | ConvertTo-Json -Depth 16 -Compress)
    $rec = Invoke-OrchestrationLeaseRecovery -LocksDir $locks
    Assert-OwnTrue ((@($rec.removed) -contains 'lease-expiring-task.json')) 'lease: recovery removes the expired lease'
    $x2 = New-OrchestrationWriteLease -TaskId 'ttl-successor-task' -RuntimeId 'opencode-v2' -RuntimeProfile 'v2' -WriteScopes @('src\ttl') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ([bool]$x2.ok) 'lease: scope freed after expiry recovery'

    Write-OwnFixture -Path (Join-Path $locks 'lease-zzzmalformed.json') -Text 'not-json{{{'
    Write-OwnFixture -Path (Join-Path $locks 'notes.txt') -Text 'not a lease'
    $act = Get-OrchestrationActiveLeases -LocksDir $locks
    Assert-OwnTrue (([bool]$act.ok) -and (@($act.warnings).Count -gt 0)) 'lease: malformed file surfaces a warning'
    $mFresh = New-OrchestrationWriteLease -TaskId 'malformed-probe-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\zzz-unique-scope') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ((-not [bool]$mFresh.ok) -and ([string]$mFresh.error -ceq 'LEASE_CONFLICT') -and ([string]$mFresh.reason -ceq 'malformed_active_lease')) 'lease: fresh malformed file fails closed with malformed_active_lease'
    $rec2fresh = Invoke-OrchestrationLeaseRecovery -LocksDir $locks
    Assert-OwnTrue ((@($rec2fresh.kept) -contains 'lease-zzzmalformed.json') -and (Test-Path -LiteralPath (Join-Path $locks 'lease-zzzmalformed.json'))) 'lease: recovery keeps fresh malformed lease'
    try { (Get-Item -LiteralPath (Join-Path $locks 'lease-zzzmalformed.json') -Force).LastWriteTimeUtc = ((Get-Date).ToUniversalTime().AddHours(-2)) } catch { }
    $rec2 = Invoke-OrchestrationLeaseRecovery -LocksDir $locks
    Assert-OwnTrue ((@($rec2.removed) -contains 'lease-zzzmalformed.json')) 'lease: recovery removes stale malformed lease'
    Assert-OwnTrue ((Test-Path -LiteralPath (Join-Path $locks 'notes.txt') -PathType Leaf)) 'lease: recovery never touches non-lease files'
    $mAfter = New-OrchestrationWriteLease -TaskId 'malformed-probe-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\zzz-unique-scope') -LocksDir $locks -FlagsPath $flagsOn -TelemetryRoot $telemetry
    Assert-OwnTrue ([bool]$mAfter.ok) 'lease: scope acquirable after stale malformed recovery'

    $off = New-OrchestrationWriteLease -TaskId 'flags-off-task' -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\off') -LocksDir $locks -FlagsPath $flagsOff -TelemetryRoot $telemetry
    Assert-OwnTrue (([string]$off.error -ceq 'KERNEL_DISABLED')) 'lease: flags disabled blocks acquire'
    Assert-OwnTrue ((-not (Test-Path -LiteralPath (Join-Path $locks 'lease-flags-off-task.json')))) 'lease: flags disabled writes nothing'

    $raceChild = Join-Path $base 'race-acquire.ps1'
    $raceLib = Join-Path $PSScriptRoot 'OrchestrationOwnership.ps1'
    Write-OwnFixture -Path $raceChild -Text ("param([string]`$TaskId)`n. '" + ($raceLib -replace "'", "''") + "'`n`$r = New-OrchestrationWriteLease -TaskId `$TaskId -RuntimeId 'opencode-v1' -RuntimeProfile 'v1' -WriteScopes @('src\race-concurrent') -LocksDir '" + ($locks -replace "'", "''") + "' -FlagsPath '" + ($flagsOn -replace "'", "''") + "'`nif ([bool]`$r.ok) { exit 0 } else { exit 1 }`n")
    $rp1 = New-Object System.Diagnostics.ProcessStartInfo
    $rp1.FileName = 'cmd.exe'
    $rp1.Arguments = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + $raceChild + '" -TaskId race-writer-one'
    $rp1.UseShellExecute = $false
    $rp1.CreateNoWindow = $true
    $rp2 = New-Object System.Diagnostics.ProcessStartInfo
    $rp2.FileName = 'cmd.exe'
    $rp2.Arguments = '/c powershell -NoProfile -ExecutionPolicy Bypass -File "' + $raceChild + '" -TaskId race-writer-two'
    $rp2.UseShellExecute = $false
    $rp2.CreateNoWindow = $true
    $cp1 = [System.Diagnostics.Process]::Start($rp1)
    $cp2 = [System.Diagnostics.Process]::Start($rp2)
    $cp1.WaitForExit(60000)
    $cp2.WaitForExit(60000)
    $cc1 = $cp1.ExitCode
    $cc2 = $cp2.ExitCode
    try { $cp1.Close() } catch { }
    try { $cp2.Close() } catch { }
    $ccodes = @($cc1, $cc2) | Sort-Object
    Assert-OwnTrue ((($ccodes -join ',') -ceq '0,1')) 'lease: concurrent overlapping acquires => exactly one wins'
    $raceFiles = @(Get-ChildItem -LiteralPath $locks -File -Filter 'lease-race-writer-*.json' -ErrorAction SilentlyContinue)
    Assert-OwnTrue (($raceFiles.Count -eq 1)) 'lease: raced acquire leaves a single lease file'

    Assert-OwnTrue ((Get-OrchestrationScopeOverlap -ScopesA @('src\api') -ScopesB @('src\api\sub')) -eq $true) 'lease: parent/child scopes overlap'
    Assert-OwnTrue ((Get-OrchestrationScopeOverlap -ScopesA @('src\apix') -ScopesB @('src\api')) -eq $false) 'lease: sibling prefix without boundary does not overlap'

    # ---------- worktrees (temp git fixture only) ----------

    if (-not (Get-GitAvailable)) {
        Write-Host '[SKIP] worktree: git unavailable, fixture tests skipped'
        $script:skipped++
    }
    else {
        New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
        & git -C $gitRepo init --quiet 2>$null | Out-Null
        & git -C $gitRepo config user.email 'fixture@example.test' 2>$null | Out-Null
        & git -C $gitRepo config user.name 'Fixture' 2>$null | Out-Null
        Write-OwnFixture -Path (Join-Path $gitRepo 'seed.txt') -Text 'seed'
        & git -C $gitRepo add seed.txt 2>$null | Out-Null
        & git -C $gitRepo commit --quiet -m 'seed' 2>$null | Out-Null

        $w1 = New-OrchestrationWorktree -TaskId 'wt-alpha' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        $w1Path = ''
        try { $w1Path = [string]$w1.path } catch { $w1Path = '' }
        if ([string]::IsNullOrWhiteSpace($w1Path)) { $w1Path = Join-Path $wtRoot 'wt-alpha' }
        Assert-OwnTrue ([bool]$w1.ok) 'worktree: create succeeds'
        Assert-OwnTrue (($w1Path -ceq (Join-Path $wtRoot 'wt-alpha'))) 'worktree: deterministic path <root>/<task-id>'
        Assert-OwnTrue (([string]$w1.branch -ceq 'orchestration/wt-alpha')) 'worktree: deterministic branch orchestration/<task-id>'
        $markerFile = Join-Path $w1Path '.orchestration-worktree.json'
        Assert-OwnTrue ((Test-Path -LiteralPath $markerFile -PathType Leaf)) 'worktree: marker file exists'
        $marker = ([IO.File]::ReadAllText($markerFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        Assert-OwnTrue ((([string]$marker.task_id -ceq 'wt-alpha') -and ([string]$marker.branch -ceq 'orchestration/wt-alpha') -and ([string]$marker.created_by -ceq 'task-kernel') -and ([int]$marker.schema_version -eq 1))) 'worktree: marker fields correct'

        $w1b = New-OrchestrationWorktree -TaskId 'wt-alpha' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        Assert-OwnTrue (([bool]$w1b.ok) -and ([string]$w1b.path -ceq $w1Path)) 'worktree: second create is idempotent'

        $g1 = Get-OrchestrationWorktree -TaskId 'wt-alpha' -WorktreesRoot $wtRoot -RepoRoot $gitRepo
        Assert-OwnTrue (([bool]$g1.ok) -and ([string]$g1.path -ceq $w1Path)) 'worktree: get returns the created path'

        $wb = New-OrchestrationWorktree -TaskId 'wt-beta' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        $wbPath = [string]$wb.path
        Remove-Item -LiteralPath (Join-Path $wbPath '.orchestration-worktree.json') -Force
        $wbRm = Remove-OrchestrationWorktree -TaskId 'wt-beta' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo
        Assert-OwnTrue (([string]$wbRm.error -ceq 'WORKTREE_NOT_OWNED')) 'worktree: unowned removal refused when marker missing'
        Assert-OwnTrue ((Test-Path -LiteralPath $wbPath -PathType Container)) 'worktree: refused removal leaves the path'

        $wd = New-OrchestrationWorktree -TaskId 'wt-delta' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        $wdPath = [string]$wd.path
        $wdMarker = ([IO.File]::ReadAllText((Join-Path $wdPath '.orchestration-worktree.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
        $wdMarker.task_id = 'wt-other'
        Write-OwnFixture -Path (Join-Path $wdPath '.orchestration-worktree.json') -Text ($wdMarker | ConvertTo-Json -Depth 16 -Compress)
        $wdRm = Remove-OrchestrationWorktree -TaskId 'wt-delta' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo
        Assert-OwnTrue (([string]$wdRm.error -ceq 'WORKTREE_NOT_OWNED')) 'worktree: mismatched marker task refused'
        Assert-OwnTrue ((Test-Path -LiteralPath $wdPath -PathType Container)) 'worktree: mismatched removal deletes nothing'

        $wg = New-OrchestrationWorktree -TaskId 'wt-gamma' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        $wgPath = [string]$wg.path
        $wgPlain = Remove-OrchestrationWorktree -TaskId 'wt-gamma' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo
        Assert-OwnTrue (([string]$wgPlain.error -ceq 'WORKTREE_REMOVE_FAILED')) 'worktree: owned removal without -Force refused (marker is untracked; never implicitly forced)'
        Assert-OwnTrue ((Test-Path -LiteralPath $wgPath -PathType Container)) 'worktree: refused removal leaves the path'
        $wgRm = Remove-OrchestrationWorktree -TaskId 'wt-gamma' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo -Force -DeleteBranch
        Assert-OwnTrue ([bool]$wgRm.ok) 'worktree: owned removal with explicit -Force succeeds'
        Assert-OwnTrue ((-not (Test-Path -LiteralPath $wgPath))) 'worktree: owned removal removes the path'

        $wDirty = New-OrchestrationWorktree -TaskId 'wt-dirty' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOn -TelemetryRoot $telemetry
        $wDirtyPath = [string]$wDirty.path
        Write-OwnFixture -Path (Join-Path $wDirtyPath 'uncommitted.txt') -Text 'dirty'
        & git -C $wDirtyPath add uncommitted.txt 2>$null | Out-Null
        $wDirtyRm = Remove-OrchestrationWorktree -TaskId 'wt-dirty' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo
        Assert-OwnTrue (([string]$wDirtyRm.error -ceq 'WORKTREE_REMOVE_FAILED')) 'worktree: dirty owned worktree without -Force refused, never implicitly forced'
        Assert-OwnTrue ((Test-Path -LiteralPath (Join-Path $wDirtyPath 'uncommitted.txt') -PathType Leaf)) 'worktree: refused removal leaves files intact'
        $wDirtyRmF = Remove-OrchestrationWorktree -TaskId 'wt-dirty' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo -Force -DeleteBranch
        Assert-OwnTrue (([bool]$wDirtyRmF.ok) -and (-not (Test-Path -LiteralPath $wDirtyPath))) 'worktree: explicit -Force removes the dirty worktree'

        $ghostPath = Join-Path $wtRoot 'wt-ghost'
        New-Item -ItemType Directory -Path $ghostPath -Force | Out-Null
        Write-OwnFixture -Path (Join-Path $ghostPath '.orchestration-worktree.json') -Text '{"schema_version":1,"task_id":"wt-ghost","branch":"orchestration/wt-ghost","base_revision":"HEAD","created_at":"2026-01-01T00:00:00Z","created_by":"task-kernel","repo_root_hash":""}'
        $ghostRm = Remove-OrchestrationWorktree -TaskId 'wt-ghost' -WorktreesRoot $wtRoot -RepoRoot $gitRepo -GitRepoDir $gitRepo -Force
        Assert-OwnTrue (([string]$ghostRm.error -ceq 'WORKTREE_NOT_REGISTERED')) 'worktree: unregistered path refused with WORKTREE_NOT_REGISTERED'
        Assert-OwnTrue ((Test-Path -LiteralPath $ghostPath -PathType Container)) 'worktree: unregistered removal deletes nothing'
        Remove-Item -LiteralPath $ghostPath -Recurse -Force -ErrorAction SilentlyContinue

        $listBefore = (& git -C $gitRepo worktree list --porcelain 2>$null) -join "`n"
        $wOff = New-OrchestrationWorktree -TaskId 'wt-off' -RepoRoot $gitRepo -BaseRevision 'HEAD' -WorktreesRoot $wtRoot -FlagsPath $flagsOff -TelemetryRoot $telemetry
        $listAfter = (& git -C $gitRepo worktree list --porcelain 2>$null) -join "`n"
        Assert-OwnTrue (([string]$wOff.error -ceq 'WORKTREE_ISOLATION_DISABLED')) 'worktree: flags disabled blocks create'
        Assert-OwnTrue ((-not (Test-Path -LiteralPath (Join-Path $wtRoot 'wt-off')))) 'worktree: flags disabled creates no path'
        Assert-OwnTrue (($listBefore -ceq $listAfter)) 'worktree: flags disabled invokes no git'

        $gMiss = Get-OrchestrationWorktree -TaskId 'wt-nope' -WorktreesRoot $wtRoot -RepoRoot $gitRepo
        Assert-OwnTrue (([string]$gMiss.error -ceq 'NOT_FOUND')) 'worktree: get of missing task reports NOT_FOUND'

        # Fixture-only cleanup of intentionally orphaned worktrees.
        foreach ($tid in @('wt-alpha', 'wt-beta', 'wt-delta', 'wt-dirty')) {
            try {
                $p = Join-Path $wtRoot $tid
                if (Test-Path -LiteralPath $p) { & git -C $gitRepo worktree remove --force $p 2>$null | Out-Null }
            } catch { }
        }
        try { & git -C $gitRepo worktree prune 2>$null | Out-Null } catch { }
    }
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
}
finally {
    try {
        if ((Get-GitAvailable) -and (Test-Path -LiteralPath $gitRepo -PathType Container)) {
            & git -C $gitRepo worktree prune 2>$null | Out-Null
        }
    } catch { }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("OrchestrationOwnership: {0} passed, {1} failed, {2} skipped" -f $script:passed, $script:failed, $script:skipped)
if ($script:failed -gt 0) { exit 1 }
exit 0
