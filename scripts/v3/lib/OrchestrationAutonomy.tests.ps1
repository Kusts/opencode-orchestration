[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1')
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
# --- policy json loads with the 4 sections ---
$policy=Get-OrchestrationAutonomyPolicy
Assert-That ($null -ne $policy) 'P1 policy loads (not null)'
Assert-That ([int]$policy.schema_version -eq 1) 'P1 schema_version is 1'
Assert-That (@($policy.auto_authorized).Count -eq 19) 'P1 auto_authorized has 19 ids'
Assert-That (@($policy.auto_authorized) -contains 'pr_open') 'P1 auto_authorized contains pr_open'
Assert-That (@($policy.auto_authorized) -contains 'goal_resume') 'P1 auto_authorized contains goal_resume'
Assert-That (@($policy.terminal_stop_reasons).Count -eq 6) 'P1 terminal_stop_reasons has 6 codes'
Assert-That (@($policy.policy_denied_reasons).Count -eq 6) 'P1 policy_denied_reasons is closed (6)'
Assert-That (@($policy.authority_boundaries.PSObject.Properties).Count -eq 9) 'P1 authority_boundaries has 9 codes'
Assert-That ($null -ne $policy.authority_boundaries.POLICY_DENIED.description) 'P1 boundary entry carries description'
# --- 6 valid stop reasons ---
Assert-That (Test-OrchestrationStopReason -Reason 'OBJECTIVE_COMPLETED') 'S1 OBJECTIVE_COMPLETED valid'
Assert-That (Test-OrchestrationStopReason -Reason 'HUMAN_AUTHORITY_REQUIRED') 'S1 HUMAN_AUTHORITY_REQUIRED valid'
Assert-That (Test-OrchestrationStopReason -Reason 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE') 'S1 EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE valid'
Assert-That (Test-OrchestrationStopReason -Reason 'GOAL_HARD_BUDGET_EXHAUSTED') 'S1 GOAL_HARD_BUDGET_EXHAUSTED valid'
Assert-That (Test-OrchestrationStopReason -Reason 'POLICY_BLOCKED') 'S1 POLICY_BLOCKED valid'
Assert-That (Test-OrchestrationStopReason -Reason 'CANCELLED') 'S1 CANCELLED valid'
Assert-That (Test-OrchestrationStopReason -Reason 'objective_completed') 'S1 stop reason match is case-insensitive'
# --- 3 invalid stop reasons ---
Assert-That (-not (Test-OrchestrationStopReason -Reason '')) 'S2 empty stop reason is false'
Assert-That (-not (Test-OrchestrationStopReason -Reason 'TASK_DONE')) 'S2 TASK_DONE is not a stop reason'
Assert-That (-not (Test-OrchestrationStopReason -Reason 'CI_PASS')) 'S2 CI_PASS is not a stop reason'
# --- 9 valid boundaries ---
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'PRODUCT_INTENT_AMBIGUITY') 'B1 PRODUCT_INTENT_AMBIGUITY valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'IRREVERSIBLE_REAL_DATA_ACTION') 'B1 IRREVERSIBLE_REAL_DATA_ACTION valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'UNAUTHORIZED_PRODUCTION_ACTION') 'B1 UNAUTHORIZED_PRODUCTION_ACTION valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'EXTERNAL_COST_OR_PURCHASE') 'B1 EXTERNAL_COST_OR_PURCHASE valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'CREATE_ROTATE_REVOKE_CREDENTIAL') 'B1 CREATE_ROTATE_REVOKE_CREDENTIAL valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'EXTERNAL_COMMUNICATION_AS_USER') 'B1 EXTERNAL_COMMUNICATION_AS_USER valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'MATERIAL_SCOPE_EXPANSION') 'B1 MATERIAL_SCOPE_EXPANSION valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'POLICY_DENIED') 'B1 POLICY_DENIED valid'
Assert-That (Test-OrchestrationAuthorityBoundary -Boundary 'REQUIRED_EXTERNAL_INPUT_UNAVAILABLE') 'B1 REQUIRED_EXTERNAL_INPUT_UNAVAILABLE valid'
# --- 2 invalid boundaries ---
Assert-That (-not (Test-OrchestrationAuthorityBoundary -Boundary '')) 'B2 empty boundary is false'
Assert-That (-not (Test-OrchestrationAuthorityBoundary -Boundary 'UNCERTAIN')) 'B2 UNCERTAIN is not a boundary'
# --- policy json cross-check: every listed stop reason and boundary validates ---
foreach ($r in @($policy.terminal_stop_reasons)) { Assert-That (Test-OrchestrationStopReason -Reason ([string]$r)) ("X1 policy stop reason validates: $r") }
foreach ($p in @($policy.authority_boundaries.PSObject.Properties)) { Assert-That (Test-OrchestrationAuthorityBoundary -Boundary ([string]$p.Name)) ("X1 policy boundary validates: " + $p.Name) }
# --- envelope ---
$e1=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('research','commit','pr_open') -Denied @('commit') -Boundaries @()
Assert-That (@($e1.Allowed) -contains 'research' -and @($e1.Allowed) -contains 'pr_open' -and @($e1.Allowed) -notcontains 'commit') 'E1 denied beats auto'
Assert-That (@($e1.Denied) -contains 'commit') 'E1 removed item surfaces in Denied'
$e2=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('research','ci_rerun') -Denied @() -Boundaries @('POLICY_DENIED')
Assert-That (@($e2.Allowed) -contains 'research' -and @($e2.Allowed) -contains 'ci_rerun') 'E2 known boundary keeps current behavior (Allowed intact)'
Assert-That (@($e2.Boundaries) -contains 'POLICY_DENIED') 'E2 known boundary is echoed'
$e3=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @() -Denied @() -Boundaries @()
Assert-That (@($e3.Allowed).Count -eq 0) 'E3 empty inputs yield empty Allowed'
$e4=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('research','mystery_action') -Denied @() -Boundaries @()
Assert-That (@($e4.Allowed) -notcontains 'mystery_action' -and @($e4.Denied) -contains 'mystery_action') 'E4 unknown input fails closed to Denied'
$e5=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @($policy.auto_authorized) -Denied @() -Boundaries @()
Assert-That (@($e5.Allowed).Count -eq 19) 'E5 full auto with no deny allows all 19'
# --- unknown boundary fails closed total ---
$e6=Get-OrchestrationAuthorizationEnvelope -AutoAuthorized @('research','ci_rerun') -Denied @() -Boundaries @('mystery_boundary')
Assert-That (@($e6.Allowed).Count -eq 0) 'E6 unknown boundary fails closed (Allowed empty)'
Assert-That (@($e6.Denied) -contains 'mystery_boundary') 'E6 unknown boundary code surfaces in Denied'
# --- D1 bidirectional anti-drift: code getters vs policy json (both directions) ---
function Assert-SetEqual {param([string[]]$Code,[string[]]$Json,[string]$Name);$onlyCode=@($Code | Where-Object { $Json -cnotcontains $_ });$onlyJson=@($Json | Where-Object { $Code -cnotcontains $_ });Assert-That (@($Code).Count -eq @($Json).Count) ("D1 $Name cardinality matches ($(@($Code).Count) vs $(@($Json).Count))");Assert-That (@($Code | Sort-Object -Unique).Count -eq @($Code).Count) ("D1 $Name code list has no duplicates");Assert-That (@($Json | Sort-Object -Unique).Count -eq @($Json).Count) ("D1 $Name json list has no duplicates");Assert-That (@($onlyCode).Count -eq 0) ("D1 $Name code-only extras: $($onlyCode -join ',')");Assert-That (@($onlyJson).Count -eq 0) ("D1 $Name json-only extras: $($onlyJson -join ',')")}
$jsonBnds=@($policy.authority_boundaries.PSObject.Properties | ForEach-Object { [string]$_.Name })
Assert-SetEqual -Code @(Get-OrchestrationStopReasons) -Json @($policy.terminal_stop_reasons) -Name 'stop reasons'
Assert-SetEqual -Code @(Get-OrchestrationAuthorityBoundaries) -Json $jsonBnds -Name 'boundaries'
Assert-SetEqual -Code @(Get-OrchestrationAutoAuthorized) -Json @($policy.auto_authorized) -Name 'auto ids'
Write-Output "PASS: $passed assertions"
