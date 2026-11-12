$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'compare-execution-strategies.ps1'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temp = Join-Path $env:TEMP ('strategy-' + [guid]::NewGuid().ToString('N') + '.json')
$failures = 0
$assertions = 0
function Assert-True([bool]$Condition, [string]$Message) { $script:assertions++; if (-not $Condition) { $script:failures++; Write-Output ("ASSERTION FAILED: {0}" -f $Message) } }
$statusBefore = @(git -C $repo status --porcelain)
$diffBefore = @(git -C $repo diff --name-only)
try {
    & $scriptPath -OutFile $temp -GeneratedAt '2026-11-12T00:00:00Z' -BaseRevision 'base-test' -GeneratedByCommit 'commit-test'
    $j = Get-Content -Raw $temp | ConvertFrom-Json
    Assert-True ($j.evidence_kind -eq 'decision_and_policy_probe' -and $j.runtime_real -eq $false -and $j.execution_performed -eq $false) 'Evidence labels invalid.'
    $expected = @{ A='DIRECT_VERIFIED'; B='SINGLE_WORKER'; C='MULTI_WORKER'; D='MULTI_WORKER' }
    foreach ($d in $j.decisions) { Assert-True ($d.decision -ceq $expected[$d.id]) "Scenario $($d.id) decision mismatch."; if ($d.id -ne 'A') { Assert-True ($d.selected_agents.Count -ge 1) "Scenario $($d.id) agent selection empty." } }
    . (Join-Path $PSScriptRoot 'lib\OrchestrationPreflight.ps1')
    foreach ($row in $j.policy_probe) { $argsLive = @{}; foreach ($prop in $row.inputs.PSObject.Properties) { $argsLive[$prop.Name] = $prop.Value }; $live = Test-OrchestrationDoneCompliance @argsLive; Assert-True ($row.declared_inputs -eq $true -and $row.token -ceq $live) "Policy token mismatch: $($row.id)." }
    foreach ($d in $j.decisions) { $cmp = @($j.comparison | Where-Object scenario_id -eq $d.id)[0]; Assert-True (@($cmp.compliance_tokens).Count -gt 0 -and @($cmp.compliance_policy_probe_ids | ForEach-Object { @($j.policy_probe | Where-Object id -eq $_)[0].inputs.Decision -eq $d.decision } | Where-Object { -not $_ }).Count -eq 0) "Comparison uses a mismatched decision token: $($d.id)." }
    Assert-True (@($j.policy_probe | Where-Object { $_.id -eq 'single_zero' -and $_.token -ceq 'ORCHESTRATION_POLICY_BYPASS' }).Count -eq 1) 'Missing zero participation bypass.'
    Assert-True (@($j.policy_probe | Where-Object { $_.id -eq 'single_one' -and $_.token -ceq 'COMPLIANT' }).Count -eq 1) 'Missing one participation compliant.'
    Assert-True (@($j.policy_probe | Where-Object { $_.id -eq 'direct_missing_reason' -and $_.token -ceq 'NON_COMPLIANT_MISSING_DIRECT_REASON' }).Count -eq 1) 'Missing missing-reason rejection.'
    foreach ($name in @('Cascade','Critique')) { $strategy = @($j.strategies | Where-Object name -eq $name)[0]; Assert-True ($strategy.status -eq 'NOT_IMPLEMENTED' -and -not ($strategy.PSObject.Properties.Name -contains 'metrics')) "$name status/metrics invalid." }
    foreach ($name in @('wall_clock','provider_tokens','provider_cost','execution_shape_observed','worker_participation_observed','cascade_outcome','critique_outcome')) { $u=@($j.unknown | Where-Object name -eq $name)[0]; Assert-True ($null -ne $u -and -not [string]::IsNullOrWhiteSpace($u.reason)) "Missing unknown/reason $name." }
    Assert-True (@($j.metrics.objective_chars_proxy | Where-Object { $_.is_estimate -ne $true -or $_.method -ne 'chars/4' -or $_.measures_performance -ne $false }).Count -eq 0) 'Unlabelled objective proxy.'
    $first = Get-Content -Raw $temp
    & $scriptPath -OutFile $temp -GeneratedAt '2026-11-12T00:00:00Z' -BaseRevision 'base-test' -GeneratedByCommit 'commit-test'
    Assert-True ((Get-Content -Raw $temp) -ceq $first) 'Output is not deterministic.'
    $text = Get-Content -Raw $scriptPath
    $dotSources = @([regex]::Matches($text, '(?im)^\s*\.\s+\(Join-Path[^\r\n]+'))
    Assert-True ($dotSources.Count -eq 1 -and $dotSources[0].Value.Contains('lib\OrchestrationPreflight.ps1') -and $text -notmatch '(?i)OrchestrationModelRouter|CapabilityRouter|\.\s*\([^\r\n]*Router') 'Unexpected router import/use.'
    $functionNames = @([regex]::Matches($text, '(?im)^\s*function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (@($functionNames | Where-Object { $_ -match '(?i)(select|score|rank|strategy)' }).Count -eq 0 -and $text -match 'no_second_router=\$true') 'Strategy selection/scoring function found.'
    Assert-True ($text -notmatch 'execution_shape_observed\s*=\s*') 'Observed execution shape is asserted.'
    Assert-True ((@(git -C $repo status --porcelain) -join "`n") -ceq ($statusBefore -join "`n")) 'Test changed git status in repo.'
    Assert-True ((@(git -C $repo diff --name-only) -join "`n") -ceq ($diffBefore -join "`n")) 'Test changed tracked diff.'
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
Write-Output ("Assertions: {0}; Failures: {1}" -f $assertions, $failures)
if ($failures -gt 0) { exit 1 }
