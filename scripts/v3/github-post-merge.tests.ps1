$ErrorActionPreference='Stop'
$passed=0; $skipped=0
$root=Join-Path ([IO.Path]::GetTempPath()) ('pm-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Invoke-FixtureGit($dir,[string[]]$GitArgs) { $old=$ErrorActionPreference; $ErrorActionPreference='Continue'; & git -C $dir @GitArgs 2>&1 | Out-Null; $code=$LASTEXITCODE; $ErrorActionPreference=$old; if($code){throw "git fixture failed: $($GitArgs -join ' ')"} }
function Assert($v,$m) { if(-not $v){throw "FAIL: $m"}; $script:passed++ }
try {
  $bare=Join-Path $root 'origin.git'; $repo=Join-Path $root 'repo'; $owned=Join-Path $repo 'cache/runtime/worktrees/task-owned'
  & git init --bare $bare | Out-Null; & git init -b main $repo | Out-Null
  Invoke-FixtureGit $repo @('config','user.email','fixture@example.invalid'); Invoke-FixtureGit $repo @('config','user.name','Fixture')
  Set-Content (Join-Path $repo 'base.txt') 'base'; Set-Content (Join-Path $repo '.gitignore') ".orchestration-worktree.json`ncache/"
  Invoke-FixtureGit $repo @('add','base.txt','.gitignore'); Invoke-FixtureGit $repo @('commit','-m','base'); Invoke-FixtureGit $repo @('remote','add','origin',$bare); Invoke-FixtureGit $repo @('push','-u','origin','main')
  Invoke-FixtureGit $repo @('symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main')
  Invoke-FixtureGit $repo @('checkout','-b','orchestration/task-f4'); Set-Content (Join-Path $repo 'feature.txt') 'feature'
  Invoke-FixtureGit $repo @('add','feature.txt'); Invoke-FixtureGit $repo @('commit','-m','feature')
  Invoke-FixtureGit $repo @('checkout','main'); Invoke-FixtureGit $repo @('merge','--no-ff','orchestration/task-f4','-m','merge'); $merge=(git -C $repo rev-parse HEAD).Trim(); Invoke-FixtureGit $repo @('push','origin','main')
  function New-Owned {
    if (Test-Path $owned) { Invoke-FixtureGit $repo @('worktree','remove',$owned) }
    if (git -C $repo branch --list orchestration/task-owned) { Invoke-FixtureGit $repo @('branch','-d','orchestration/task-owned') }
    New-Item -ItemType Directory (Split-Path $owned -Parent) -Force | Out-Null
    Invoke-FixtureGit $repo @('worktree','add','-b','orchestration/task-owned',$owned,'origin/main')
    # Marker shape required by Remove-OrchestrationWorktree, including exact task_id.
    Set-Content (Join-Path $owned '.orchestration-worktree.json') (@{task_id='task-owned';pr_number=42;branch='orchestration/task-owned'}|ConvertTo-Json)
  }
  New-Owned
  $gh=Join-Path $root 'fake-gh.cmd'; $probe=Join-Path $root 'fake-probe.cmd'; $snap=Join-Path $root 'pr.json'; $sessionSnap=Join-Path $root 'sessions.json'
  Set-Content $gh '@echo off
type "%PM_FIXTURE_JSON%"'
  Set-Content $probe '@echo off
type "%PM_SESSION_JSON%"'
  $env:PM_FIXTURE_JSON=$snap; $env:PM_SESSION_JSON=$sessionSnap; $env:Path="$root;$env:Path"
  $cli=Join-Path $PSScriptRoot 'github-post-merge.ps1'
  function Snapshot($state='MERGED',$checks=@(@{state='SUCCESS';conclusion='SUCCESS'}),$method='MERGE') {
    @{state=$state;mergedAt='2026-11-18T00:00:00Z';mergeCommit=@{oid=$merge};baseRefName='main';headRefName='orchestration/task-f4';mergeMethod=$method;statusCheckRollup=$checks} | ConvertTo-Json -Depth 5 | Set-Content $snap
  }
  function RunApply {
    & powershell -NoProfile -File $cli -RepoRoot $repo -PrNumber 42 -Mode Apply -GhCommand $gh -SessionProbeCommand $probe 2>$null | ConvertFrom-Json
  }
  # (a) Empty active list permits actual primitive removal of owned clean WT/branch.
  '[]' | Set-Content $sessionSnap; Snapshot
  $out=RunApply
  if($out.removed.Count -ne 1) { $out | ConvertTo-Json -Depth 6 | Write-Output }
  Assert ($out.verdict -eq 'APPLIED' -and $out.local_sha -eq $out.remote_sha) 'normal merge FF and SHA'
  Assert ($out.removed.Count -eq 1 -and -not (Test-Path $owned)) 'owned worktree actually removed'
  Assert (-not (git -C $repo branch --list orchestration/task-owned)) 'owned branch actually removed'
  $cliText=Get-Content (Join-Path $PSScriptRoot 'github-post-merge.ps1') -Raw
  $wtLib=Get-Content (Join-Path $PSScriptRoot 'lib/OrchestrationWorktree.ps1') -Raw
  Assert ($cliText -match '-DeleteBranch -SafeBranchDelete' -and $wtLib -match "\{ '-d' \} else \{ '-D' \}") 'post-merge selects safe non-force branch deletion'
  # (b) Squash is accepted in Plan; feature branch is never merged by this CLI.
  Snapshot 'MERGED' @(@{state='SUCCESS';conclusion='SUCCESS'}) 'SQUASH'
  $plan=& powershell -NoProfile -File $cli -RepoRoot $repo -PrNumber 42 -Mode Plan -GhCommand $gh 2>$null | ConvertFrom-Json
  Assert ($plan.verdict -eq 'PLAN_READY' -and $plan.pr_snapshot.method -eq 'SQUASH') 'squash accepted'
  # (c) Active path and (d) failed probe both preserve.
  New-Owned; (@{worktrees=@(@{path=$owned})}|ConvertTo-Json -Depth 4) | Set-Content $sessionSnap; Snapshot
  $out=RunApply
  Assert ($out.preserved.code -contains 'SESSION_ACTIVE' -and $out.removed.Count -eq 0) 'active session preserved'
  New-Owned; '[]' | Set-Content $sessionSnap
  $out=& powershell -NoProfile -File $cli -RepoRoot $repo -PrNumber 42 -Mode Apply -GhCommand $gh -SessionProbeCommand 'missing-probe-command-xyz' 2>$null | ConvertFrom-Json
  Assert ($out.preserved.code -contains 'SESSION_PROBE_UNAVAILABLE' -and $out.removed.Count -eq 0) 'failed probe preserved'
  # Stderr is suspicious even when the probe exits successfully and prints [].
  $stderrProbe=Join-Path $root 'stderr-probe.cmd'; Set-Content $stderrProbe '@echo off
echo [] 
echo warning 1>&2'
  $out=& powershell -NoProfile -File $cli -RepoRoot $repo -PrNumber 42 -Mode Apply -GhCommand $gh -SessionProbeCommand $stderrProbe 2>$null | ConvertFrom-Json
  Assert ($out.preserved.code -contains 'SESSION_PROBE_UNAVAILABLE') 'probe stderr rejected'
  # (e) dirty worktree and repeat.
  New-Owned; '[]' | Set-Content $sessionSnap; Set-Content (Join-Path $owned 'dirty.txt') 'pending'
  $out=RunApply
  Assert ($out.preserved.code -contains 'WORKTREE_DIRTY_PRESERVED' -and (Test-Path $owned)) 'dirty worktree preserved'
  Remove-Item (Join-Path $owned 'dirty.txt'); $before=(git -C $repo rev-parse HEAD).Trim()
  $out=RunApply
  Assert ($out.local_sha -eq $before -and $out.local_sha -eq $out.remote_sha) 'reexecution idempotent'
  # PR not merged / checks pending must block without sync.
  Snapshot 'OPEN'; $before=(git -C $repo rev-parse HEAD).Trim(); $out=RunApply
  Assert ($out.verdict -eq 'BLOCKED' -and (git -C $repo rev-parse HEAD).Trim() -eq $before) 'unmerged PR blocked'
  Snapshot 'MERGED' @(@{status='IN_PROGRESS';conclusion=$null}); $before=(git -C $repo rev-parse HEAD).Trim(); $out=RunApply
  Assert ($out.verdict -eq 'BLOCKED' -and (git -C $repo rev-parse HEAD).Trim() -eq $before) 'in-progress null conclusion blocks before mutation'
  Snapshot 'MERGED' @(@{status='COMPLETED';conclusion='SUCCESS'}); $out=RunApply
  Assert ($out.verdict -eq 'APPLIED') 'completed successful check accepted'
  $badMergeDoc=@{state='MERGED';mergedAt='2026-11-18T00:00:00Z';mergeCommit=@{oid='0000000000000000000000000000000000000001'};baseRefName='main';headRefName='orchestration/task-f4';mergeMethod='MERGE';statusCheckRollup=@(@{status='COMPLETED';conclusion='SUCCESS'})}
  $badMergeDoc | ConvertTo-Json -Depth 5 | Set-Content $snap
  $before=(git -C $repo rev-parse HEAD).Trim(); $out=RunApply
  Assert ($out.reasons -contains 'MERGE_SHA_NOT_ANCESTOR' -and (git -C $repo rev-parse HEAD).Trim() -eq $before) 'unrelated merge SHA blocked before base merge'
  # Probe JSON schemas accepted; malformed/empty/unknown forms fail closed.
  New-Owned; Snapshot 'MERGED' @(@{status='COMPLETED';conclusion='SUCCESS'}); (@{result=@{worktrees=@()}}|ConvertTo-Json -Depth 5)|Set-Content $sessionSnap; $out=RunApply
  Assert ($out.removed.Count -eq 1) 'orca result.worktrees empty accepted'
  New-Owned; (@{agents=@(@{paneKey=$owned})}|ConvertTo-Json -Depth 5)|Set-Content $sessionSnap; $out=RunApply
  Assert ($out.preserved.code -contains 'SESSION_PROBE_UNAVAILABLE') 'paneKey-only schema rejected'
  Write-Output "PASS: $passed assertions; (a) 4, (b) 1, active 1, probe-failure 1, probe-stderr 1, dirty 1, repeat 1, blocked 3, merge-SHA 1, probe-schema 2; skipped=$skipped"
} finally { Remove-Item Env:PM_FIXTURE_JSON -ErrorAction SilentlyContinue; Remove-Item Env:PM_SESSION_JSON -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
