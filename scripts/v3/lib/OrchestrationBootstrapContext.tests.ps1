[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationBootstrapContext.ps1')
$script:passed=0; $script:failed=0
function Assert-Bootstrap([bool]$ok,[string]$name) { if($ok){$script:passed++;Write-Host "[PASS] $name"}else{$script:failed++;Write-Host "[FAIL] $name"} }
function Put([string]$p,[string]$v) { $d=Split-Path -Parent $p; New-Item -ItemType Directory -Path $d -Force|Out-Null; [IO.File]::WriteAllText($p,$v,[Text.UTF8Encoding]::new($false)) }
$root=Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $root|Out-Null
try {
  Put (Join-Path $root 'source/registry/capability-flags.json') '{"jev_advisory":{"enabled":false},"task_kernel":{"enabled":false}}'
  Put (Join-Path $root 'source/registry/jev-advisory-policy.json') '{}'; Put (Join-Path $root 'source/registry/ai-memory-remote-policy.json') '{}'
  Put (Join-Path $root 'cache/runtime/tasks/abc-1.json') '{"task_id":"abc-1","state":"IMPLEMENTING","active_wait":{"type":"human"}}'
  $fixed={ '2026-01-01T00:00:00Z' }
  $a=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed
  $b=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed
  Assert-Bootstrap ($a.tasks.active_count -eq 1 -and $a.pending_waits.count -eq 1 -and $a.jev_status.transport -eq 'synthetic-hold') 'complete fixture context'
  Assert-Bootstrap ((ConvertTo-Json $a -Depth 20 -Compress) -ceq (ConvertTo-Json $b -Depth 20 -Compress)) 'fixed clock deterministic'
  $empty=Join-Path $root 'empty'; New-Item -ItemType Directory $empty|Out-Null
  $missing=New-OrchestrationBootstrapContext -RepoRoot $empty -FlagsPath (Join-Path $empty 'none') -TasksDir (Join-Path $empty 'tasks') -Clock $fixed
  Assert-Bootstrap ($missing -and $missing.capability_health.status -eq 'unavailable' -and $missing.tasks.status -eq 'unavailable') 'missing sources non-blocking'
  $small=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed -ByteBudget 500
  Assert-Bootstrap ($small.truncated -and [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $small -Depth 20 -Compress)) -le 500) 'byte cap truncation'
  Assert-Bootstrap (-not $small.tasks.Contains('refs') -and -not $small.pending_waits.Contains('refs') -and $small.tasks.active_count -eq 1 -and $small.pending_waits.count -eq 1) 'refs dropped before counts'
  Assert-Bootstrap ($null -ne $small.capability_health.flags) 'capability health retained last'
  $expectedDiscard=@('tasks.refs','pending_waits.refs','jev_status','aimemory_status','tasks.counts','pending_waits.counts')
  $observedDiscard=@(); $singleStageSnapshots=0; $stageError=$false
  $previous=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed -ByteBudget 2000
  for($budget=1999;$budget -ge 250;$budget--) {
    $snapshot=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed -ByteBudget $budget
    if($snapshot.oversized){continue}
    $before=@([bool]$previous.tasks.Contains('refs'),[bool]$previous.pending_waits.Contains('refs'),[bool]($previous.jev_status.status -ne 'unavailable'),[bool]($previous.aimemory_status.status -ne 'unavailable'),[bool]$previous.tasks.Contains('active_count'),[bool]$previous.pending_waits.Contains('count'))
    $after=@([bool]$snapshot.tasks.Contains('refs'),[bool]$snapshot.pending_waits.Contains('refs'),[bool]($snapshot.jev_status.status -ne 'unavailable'),[bool]($snapshot.aimemory_status.status -ne 'unavailable'),[bool]$snapshot.tasks.Contains('active_count'),[bool]$snapshot.pending_waits.Contains('count'))
    $removed=@(); for($i=0;$i -lt $before.Count;$i++){if($before[$i] -and -not $after[$i]){$removed+= $expectedDiscard[$i]}}
    if($removed.Count -gt 0) { if($removed.Count -ne 1){$stageError=$true}; $observedDiscard+= $removed; $singleStageSnapshots++ }
    if(($null -eq $snapshot.capability_health.flags) -and ($observedDiscard.Count -lt $expectedDiscard.Count)){$stageError=$true}
    $previous=$snapshot
  }
  Assert-Bootstrap (-not $stageError -and $singleStageSnapshots -eq 6 -and (($observedDiscard -join '|') -ceq ($expectedDiscard -join '|'))) 'descending-budget snapshots prove exact one-stage discard order; capability health retained'
  $budgetChecks=$true
  foreach($budget in @(500,600,8192)) { $c=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed -ByteBudget $budget; $n=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $c -Depth 20 -Compress)); if(($c.oversized -ne $true) -and ($n -gt $budget)){$budgetChecks=$false} }
  Assert-Bootstrap $budgetChecks 'serialized output respects every satisfiable tested budget'
  Put (Join-Path $root 'cache/runtime/tasks/def-2.json') '{"task_id":"sk-SYNTHETICSECRET","state":"IMPLEMENTING"}'
  $safe=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed
  Assert-Bootstrap ((ConvertTo-Json $safe -Depth 20 -Compress) -notmatch 'sk-SYNTHETICSECRET') 'canary redaction'
  Put (Join-Path $root 'cache/runtime/tasks/ghi-3.json') '{"task_id":"agent.example.com","state":"IMPLEMENTING","active_wait":{"type":"token=creds123"}}'
  $redacted=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed
  $serialized=ConvertTo-Json $redacted -Depth 20 -Compress
  Assert-Bootstrap ($serialized -notmatch 'agent\.example\.com|token=creds123|creds123') 'hostname and token key-value redacted'
  Assert-Bootstrap ($redacted.runtime.generation -eq 'unknown' -and $redacted.runtime.source -eq 'not-probed') 'runtime parse-only default; no process execution'
  $injected=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed -RuntimeInfo @{generation=2;version='2.1.0'}
  Assert-Bootstrap ($injected.runtime.generation -eq '2' -and $injected.runtime.source -eq 'injected') 'trusted runtime info injected'
  Put (Join-Path $empty 'source/registry/capability-flags.json') '{bad'
  Put (Join-Path $empty 'source/registry/jev-advisory-policy.json') '{bad'
  Put (Join-Path $empty 'source/registry/ai-memory-remote-policy.json') '{bad'
  $corrupt=New-OrchestrationBootstrapContext -RepoRoot $empty -Clock $fixed
  Assert-Bootstrap ($corrupt.capability_health.status -eq 'unavailable' -and $corrupt.jev_status.status -eq 'unavailable' -and $corrupt.aimemory_status.status -eq 'unavailable') 'corrupt flags and policies unavailable'
  $negative=New-OrchestrationBootstrapContext -RepoRoot $empty -Clock $fixed -MaxRefs -5 -ByteBudget -1
  Assert-Bootstrap ($negative -and $negative.runtime.generation -eq 'unknown') 'negative parameters clamped'
  $minimum=New-OrchestrationBootstrapContext -RepoRoot $empty -Clock $fixed -ByteBudget 1
  Assert-Bootstrap ($minimum.oversized -and $minimum.truncated) 'sub-minimum budget reported honestly'
  $before=@(Get-ChildItem $root -Recurse -File|% FullName)
  $null=New-OrchestrationBootstrapContext -RepoRoot $root -Clock $fixed
  $after=@(Get-ChildItem $root -Recurse -File|% FullName)
  Assert-Bootstrap ($after.Count -eq $before.Count) 'read-only directory unchanged by builder'
} finally { Remove-Item $root -Recurse -Force }
Write-Host ("[SUMMARY] passed={0} failed={1}" -f $script:passed,$script:failed)
if($script:failed -gt 0){exit 1}
