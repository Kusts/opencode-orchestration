[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationPlannerLoop.ps1')
$script:checks=0
function Assert-PL([bool]$ok,[string]$name){$script:checks++;if(-not $ok){throw "FAIL: $name"}}
$now='2026-10-02T12:00:00Z'
# 1. Small change takes minimum C/L1 route.
$small=Invoke-OrchestrationPlannerLoop @{objective='Localized typo fix';summary='Localized';risk='low';localized=$true;trivial_direct=$false;task_shape='small_localized';validation_budget_available=$true} @{timestamp=$now}
Assert-PL ($small.status -eq 'ok' -and $small.plan.validation.level -eq 'L1' -and $small.plan.execution_mode.mode -eq 'C' -and @($small.plan.dispatch_plan.workers).Count -eq 1) 'small-minimum-route'
# 2. Ambiguous/high risk raises rigor.
$risky=Invoke-OrchestrationPlannerLoop @{objective='Investigate credentials failure';summary='Ambiguous credentials';risk='high';risk_triggers=@('credentials');uncertainty='high';task_shape='multi_step'} @{timestamp=$now}
Assert-PL ($risky.plan.validation.level -eq 'L3' -and $risky.plan.execution_mode.mode -eq 'C' -and $risky.plan.dispatch_plan.workers -contains 'security-reviewer') 'risky-rigor'
# 3. No validation budget suppresses fan-out.
$nobudget=Invoke-OrchestrationPlannerLoop @{objective='Complex work';risk='high';validation_budget_available=$false} @{timestamp=$now}
Assert-PL (@($nobudget.plan.dispatch_plan.workers).Count -eq 1 -and -not $nobudget.plan.dispatch_plan.parallel_ok -and -not $nobudget.plan.budget_reservation.validation_reserved) 'budget-constrains-fanout'
# 4. Jev trigger remains recommendation only.
$jev=Invoke-OrchestrationPlannerLoop @{objective='Need route';risk='low';route_uncertain=$true} @{timestamp=$now}
Assert-PL ($jev.plan.jev_triggers.should_consult -and -not $jev.plan.jev_advisory.authoritative -and $jev.plan.jev_advisory.recommendation_only) 'jev-non-authoritative'
# 5. Missing info recommends research, not model escalation.
$unknown=Invoke-OrchestrationPlannerLoop @{} @{timestamp=$now}
Assert-PL ($unknown.plan.dispatch_plan.recommendation -eq 'Explorer/Researcher' -and $unknown.plan.dispatch_plan.escalations[0].type -eq 'information-gathering') 'research-before-escalation'
# 6. Parallelism requires every gate; independent path vs dependent path.
$independent=Invoke-OrchestrationPlannerLoop @{objective='Independent modules';risk='medium';work_independent=$true;ownership_clear=$true;shared_state=$false;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
$dependent=Invoke-OrchestrationPlannerLoop @{objective='Sequential migration';risk='medium';work_independent=$true;ownership_clear=$true;shared_state=$true;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
Assert-PL ($independent.plan.dispatch_plan.parallel_ok -and -not $dependent.plan.dispatch_plan.parallel_ok) 'parallel-gates'
# 7. Stop condition always present.
Assert-PL (-not [string]::IsNullOrWhiteSpace($unknown.plan.stop_condition)) 'stop-condition'
# hostile input, sanitization and conservative fallback.
$hostile=Invoke-OrchestrationPlannerLoop ([pscustomobject]@{objective='sk-SYNTHETICSECRET token=hello evil.com';risk='injected';task_shape=@('malformed')}) @{timestamp=$now}
Assert-PL ($hostile.plan.execution_mode.mode -eq 'C' -and $hostile.plan.validation.level -eq 'L2' -and $hostile.plan.frame.objective -notmatch 'SYNTHETICSECRET|hello|evil.com') 'hostile-conservative-sanitized'
# stable inputs and value timestamp produce byte-identical serialization.
$again=Invoke-OrchestrationPlannerLoop @{} @{timestamp=$now}
Assert-PL ($unknown.plan_json -ceq $again.plan_json) 'deterministic'
Assert-PL ($hostile.bounded -and $hostile.byte_length -le 8192) 'bounded-record'
# Isolated malformed stage returns fail closed at that section without losing plan.
foreach($stage in @('reuse','simplicity','validation','execution_mode','jev')){
    $bad=Invoke-OrchestrationPlannerLoop @{objective='Stage seam';risk='low'} @{timestamp=$now;stage_results=@{$stage='malformed'}}
    $section=if($stage -eq 'reuse'){$bad.plan.reuse}elseif($stage -eq 'simplicity'){$bad.plan.simplicity.contract}elseif($stage -eq 'validation'){$bad.plan.validation}elseif($stage -eq 'execution_mode'){$bad.plan.execution_mode}else{$bad.plan.jev_triggers}
    Assert-PL ($bad.status -eq 'ok' -and $section.status -eq 'unavailable') "malformed-$stage-unavailable"
}
# Kernel API is intentionally not loaded: reservation stays record-only.
$recordOnly=Invoke-OrchestrationPlannerLoop @{objective='No kernel';risk='low'} @{timestamp=$now}
Assert-PL ($recordOnly.plan.budget_reservation.status -eq 'record-only') 'kernel-absent-record-only'
# Injected strings in reusable evidence, roles, mode and timestamp are sanitized.
$injected=Invoke-OrchestrationPlannerLoop @{objective='Sanitization';risk='low'} @{timestamp='invalid sk-SYNTHETICSECRET token=bad';stage_results=@{reuse=[pscustomobject]@{status='ok';results=@([pscustomobject]@{summary='sk-SYNTHETICSECRET token=bad'})};validation=[pscustomobject]@{status='ok';required_roles=@('sk-SYNTHETICSECRET token=bad');level='L1'};execution_mode=[pscustomobject]@{mode='C';rationale='sk-SYNTHETICSECRET token=bad'}}}
Assert-PL ((($injected.plan_json -notmatch 'SYNTHETICSECRET|token=bad') -and $injected.plan.timestamp_note -match 'Invalid timestamp') -and $injected.plan.execution_mode.rationale -notmatch 'SYNTHETICSECRET') 'all-injected-sources-sanitized'
# Oversized free text exercises ordered discards and absolute byte cap.
$large=Invoke-OrchestrationPlannerLoop @{objective=('x' * 200000);risk='low';separation_rationale=('y' * 200000)} @{timestamp=$now;stage_results=@{reuse=[pscustomobject]@{status='ok';results=@(('z' * 200000))}}}
Assert-PL ($large.bounded -and $large.byte_length -le 8192 -and $large.discard_order.Count -ge 6) 'absolute-cap-discard-order'
# Extreme nested payload must fall back to a valid compact envelope, consistently represented.
$hugeResults=@();for($i=0;$i -lt 20;$i++){$row=[ordered]@{};for($j=0;$j -lt 40;$j++){$row["field$j"]=('z' * 240)};$hugeResults+=,[pscustomobject]$row}
$hugeCompletion=[ordered]@{};for($i=0;$i -lt 40;$i++){$hugeCompletion["field$i"]=('z' * 240)}
$extreme=Invoke-OrchestrationPlannerLoop @{objective='Extreme payload';risk='low';task_ref='task-123'} @{timestamp='invalid sk-SYNTHETICSECRET';stage_results=@{reuse=[pscustomobject]@{status='ok';results=$hugeResults};complete_requirements=[pscustomobject]$hugeCompletion}}
$parsedExtreme=$extreme.plan_json | ConvertFrom-Json -ErrorAction Stop
$sameRecord=(ConvertTo-Json -InputObject $extreme.plan -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $parsedExtreme -Depth 8 -Compress)
Assert-PL ($extreme.bounded -and $extreme.byte_length -le 8192 -and $parsedExtreme.status -eq 'oversized' -and $parsedExtreme.truncated -and $parsedExtreme.oversized -and $sameRecord) 'oversized-valid-envelope-and-consistency'
Assert-PL ($extreme.plan_json -notmatch 'SYNTHETICSECRET' -and $extreme.plan_json -match '"generated_at"') 'oversized-invalid-timestamp-canary-absent'
# Invalid descriptor forces the whole plan to conservative mode and minimum dispatch.
$invalid=Invoke-OrchestrationPlannerLoop ([pscustomobject]@{objective=@('hostile');risk='critical';task_shape=@('B')}) @{timestamp=$now}
Assert-PL ($invalid.plan.execution_mode.mode -eq 'C' -and $invalid.plan.validation.level -eq 'L2' -and @($invalid.plan.dispatch_plan.workers).Count -eq 1 -and -not $invalid.plan.dispatch_plan.parallel_ok) 'invalid-descriptor-whole-plan-fallback'
Write-Output "PASS OrchestrationPlannerLoop: $script:checks checks"
