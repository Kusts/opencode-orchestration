$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'compare-execution-strategies.ps1'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temp = Join-Path $env:TEMP ('strategy-' + [guid]::NewGuid().ToString('N') + '.json')
$failures = 0
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) { $script:assertions++; if (-not $Condition) { $script:failures++; Write-Error $Message } }
$statusBefore = @(git -C $repo status --porcelain)
$diffBefore = @(git -C $repo diff --name-only)
try {
    & $scriptPath -OutFile $temp -GeneratedAt '2026-11-12T00:00:00Z' -BaseRevision 'base-test' -GeneratedByCommit 'commit-test'
    $j = Get-Content -Raw $temp | ConvertFrom-Json
    Assert-True ($j.evidence_kind -eq 'decision_and_policy_probe' -and $j.runtime_real -eq $false -and $j.execution_performed -eq $false) 'Evidence labels invalid.'
    Assert-True ($j.decisions[0].decision -eq 'DIRECT_VERIFIED' -and $j.decisions[0].selected_agents.Count -eq 0) 'Scenario A mismatch.'
    foreach ($d in @($j.decisions | Select-Object -Skip 1)) { Assert-True ($d.decision -ne 'DIRECT_VERIFIED' -and $d.selected_agents.Count -ge 1) "Scenario $($d.id) mismatch." }
    Assert-True (@($j.compliance_matrix | Where-Object { $_.inputs.TaskClass -eq 'trivial' -and $_.inputs.Decision -eq 'SINGLE_WORKER' -and $_.inputs.ActualWorkerParticipation -eq 0 -and $_.token -eq 'ORCHESTRATION_POLICY_BYPASS' }).Count -gt 0) 'Missing zero participation bypass.'
    Assert-True (@($j.compliance_matrix | Where-Object { $_.inputs.Decision -eq 'SINGLE_WORKER' -and $_.inputs.ActualWorkerParticipation -eq 1 -and $_.token -eq 'COMPLIANT' }).Count -gt 0) 'Missing one participation compliant.'
    Assert-True (@($j.compliance_matrix | Where-Object { $_.inputs.Decision -eq 'DIRECT_VERIFIED' -and -not ($_.inputs.PSObject.Properties.Name -contains 'DirectReason') -and $_.token -eq 'NON_COMPLIANT_MISSING_DIRECT_REASON' }).Count -gt 0) 'Missing missing-reason rejection.'
    foreach ($name in @('Cascade','Critique')) { $strategy = @($j.strategies | Where-Object name -eq $name)[0]; Assert-True ($strategy.status -eq 'NOT_IMPLEMENTED' -and -not ($strategy.PSObject.Properties.Name -contains 'metrics')) "$name status/metrics invalid." }
    foreach ($name in @('wall_clock','provider_tokens','provider_cost','execution_shape_observed','worker_participation_observed','cascade_outcome','critique_outcome')) { Assert-True (@($j.unknown | Where-Object name -eq $name).Count -eq 1) "Missing unknown $name." }
    Assert-True (@($j.metrics.estimated_tokens | Where-Object { $_.is_estimate -ne $true -or $_.method -ne 'chars/4' }).Count -eq 0) 'Unlabelled estimate.'
    $first = Get-Content -Raw $temp
    & $scriptPath -OutFile $temp -GeneratedAt '2026-11-12T00:00:00Z' -BaseRevision 'base-test' -GeneratedByCommit 'commit-test'
    Assert-True ((Get-Content -Raw $temp) -ceq $first) 'Output is not deterministic.'
    $text = Get-Content -Raw $scriptPath
    Assert-True ($text.Contains('no_second_router=$true') -and $text -notmatch '(?i)Select-Strategy|score|function\s+Select') 'Second router/scoring marker found.'
    Assert-True ($text -notmatch 'execution_shape_observed\s*=\s*') 'Observed execution shape is asserted.'
    Assert-True ((@(git -C $repo status --porcelain) -join "`n") -ceq ($statusBefore -join "`n")) 'Test changed git status in repo.'
    Assert-True ((@(git -C $repo diff --name-only) -join "`n") -ceq ($diffBefore -join "`n")) 'Test changed tracked diff.'
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
Write-Output ("Assertions: {0}; Failures: {1}" -f $assertions, $failures)
if ($failures -gt 0) { exit 1 }
