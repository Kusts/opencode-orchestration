[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationSimplicityPolicy.ps1')
$policy=Get-SimplicityPolicy
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
Assert-That (@($policy.required_principles).Count -eq 5 -and @($policy.change_budget.max_loc_by_category.PSObject.Properties).Count -ge 5) 'R1 policy defaults and principles'
Assert-That ($policy.thresholds.soft_multiplier -eq 1 -and $policy.thresholds.hard_multiplier -eq 2) 'R1 exceedance thresholds'
$descriptor=@{summary='Fix localized parser bug';NON_GOALS=@('Do not refactor neighboring parser');PRESERVE=@('Public parser API');reuse_candidates=@('scripts/lib/ExistingHelper.ps1');bounded_question='Which parser branch fails?';stop_condition='Stop once regression is reproduced and corrected.';expected_blast_radius='Parser function and its test'}
$contract=Build-OrchestrationWorkerContractFields $descriptor
Assert-That (@($contract.principles).Count -eq 5 -and $contract.NON_GOALS[0] -eq 'Do not refactor neighboring parser' -and $contract.PRESERVE.Count -eq 1) 'R2 contract fields preserve scope and stop condition'
Assert-That ($contract.reuse_before_create.candidate_paths[0] -eq 'scripts/lib/ExistingHelper.ps1' -and $contract.abstraction_by_evidence.requires_real_consumer) 'R2 reuse and evidence criteria'
Assert-That ($contract.expected_blast_radius -eq 'Parser function and its test' -and $contract.stop_condition -like 'Stop once*') 'R2 blast radius and explicit stop'
 $budgetHostile=Build-OrchestrationWorkerContractFields @{summary='Budget normalization';change_budget=[pscustomobject]@{max_files=999999;max_total_loc='junk';max_loc_by_category=[pscustomobject]@{code=-8;tests=999999;docs='password=sk-SYNTHETICSECRET';evil='secret'}}}
Assert-That ($budgetHostile.CHANGE_BUDGET.max_files -eq $policy.change_budget.max_files -and $budgetHostile.CHANGE_BUDGET.max_total_loc -eq $policy.change_budget.max_total_loc) 'Fix2 invalid budget values fall back and excessive numeric values clamp'
Assert-That ($budgetHostile.CHANGE_BUDGET.max_loc_by_category.code -eq $policy.change_budget.max_loc_by_category.code -and $budgetHostile.CHANGE_BUDGET.max_loc_by_category.tests -eq $policy.change_budget.max_loc_by_category.tests -and $null -eq $budgetHostile.CHANGE_BUDGET.max_loc_by_category.PSObject.Properties['evil']) 'Fix2 category values clamp, reject junk, and discard unrecognized fields'
$canary=Build-OrchestrationWorkerContractFields @{summary='sk-SYNTHETICSECRET token=abc'}
Assert-That ((ConvertTo-Json $canary -Compress) -notmatch 'sk-SYNTHETICSECRET|token=abc') 'sanitizes contract canaries'
$hostile=Build-OrchestrationWorkerContractFields ([pscustomobject]@{summary=@('junk');NON_GOALS='sk-SYNTHETICSECRET';reuse_candidates=@('token=secret')})
Assert-That ($hostile.NON_GOALS.Count -gt 0 -and (ConvertTo-Json $hostile -Compress) -notmatch 'SYNTHETICSECRET|token=secret') 'hostile descriptor bounded conservatively without throw'
$a=Build-OrchestrationWorkerContractFields $descriptor;$b=Build-OrchestrationWorkerContractFields $descriptor
Assert-That ((ConvertTo-Json $a -Compress) -ceq (ConvertTo-Json $b -Compress)) 'contract deterministic'
$budget=$policy.change_budget
$none=Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=10;deletions=2}) $budget
Assert-That ($none.exceeded -eq 'none' -and $none.within_budget) 'R3 localized change within budget'
$soft=Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=130;deletions=0}) $budget
Assert-That ($soft.exceeded -eq 'soft' -and -not $soft.within_budget -and $soft.reason -eq 'rationale-required') 'R3 soft excess without rationale rejected'
$hardFiles=@();for($i=0;$i -lt 7;$i++){$hardFiles+=@(@{path="src/f$i.ps1";additions=130;deletions=0})}
$hard=Test-OrchestrationChangeBudget $hardFiles $budget
$hardWhy=Test-OrchestrationChangeBudget $hardFiles $budget 'Cross-cutting API migration required by acceptance criteria.'
Assert-That ($hard.exceeded -eq 'hard' -and -not $hard.within_budget -and $hard.reason -like '*CHANGE_BUDGET_EXCEEDED*') 'R3 hard excess without rationale fails'
Assert-That ($hardWhy.exceeded -eq 'hard-accepted' -and $hardWhy.within_budget -and $hardWhy.rationale) 'R3 cross-cutting hard excess accepted and rationale recorded'
$softWhy=Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=130;deletions=0}) $budget 'Localized deviation justified by regression coverage.'
Assert-That ($softWhy.exceeded -eq 'soft-accepted' -and $softWhy.within_budget -and $softWhy.rationale -like 'Localized deviation*') 'F1 soft accepted with rationale and recorded'
$exactOne=Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=120;deletions=0}) $budget
$exactTwo=Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=240;deletions=0}) $budget
Assert-That ($exactOne.exceeded -eq 'none' -and $exactOne.within_budget) 'F1 exact 1x boundary is within budget'
Assert-That ($exactTwo.exceeded -eq 'soft' -and -not $exactTwo.within_budget) 'F1 exact 2x boundary is soft'
Assert-That ((Test-OrchestrationChangeBudget @(@{path='src/parser.ps1';additions=240;deletions=0}) $budget 'Exactly twice budget justified.').exceeded -eq 'soft-accepted') 'F1 exact 2x accepted with rationale'
$badBudget=Test-OrchestrationChangeBudget @() @{max_files=-2;max_total_loc=20;max_loc_by_category=@{code=-1}}
Assert-That ($badBudget.exceeded -eq 'input-limit-exceeded' -and -not $badBudget.within_budget) 'F5 negative malformed budget fails closed without throw'
$tooMany=@();for($i=0;$i -lt 201;$i++){$tooMany+=@(@{path="src/$i.ps1";additions=0;deletions=0})}
Assert-That ((Test-OrchestrationChangeBudget $tooMany $budget).exceeded -eq 'input-limit-exceeded') 'F4 changed files capped at 200'
# §14 structured evals: localized bug scope, reuse, evidence, bounded explorer/researcher, reviewer.
Assert-That ($contract.NON_GOALS -contains 'Do not refactor neighboring parser') 'eval: localized bug excludes broad refactor'
Assert-That ($contract.reuse_before_create.candidate_paths.Count -gt 0) 'eval: existing helper reuse candidate surfaced'
$noConsumer=Build-OrchestrationWorkerContractFields @{summary='Add abstraction';abstraction_consumer=''}
Assert-That (-not $noConsumer.abstraction_by_evidence.consumer) 'eval: abstraction contract requires real consumer'
$noConsumerFinding=Review-OrchestrationSimplicityFindings @{abstraction_added=$true} $noConsumer
Assert-That ($noConsumerFinding.Count -eq 1 -and $noConsumerFinding[0].type -eq 'speculative-abstraction') 'F5 abstraction without consumer emits finding'
$cross=Test-OrchestrationChangeBudget $hardFiles $budget 'Cross-cutting change justified by shared contract.'
Assert-That $cross.within_budget 'eval: cross-cutting change can exceed budget with rationale'
$explorer=Build-OrchestrationWorkerContractFields @{bounded_question='Is evidence sufficient?';role='explorer'}
$researcher=Build-OrchestrationWorkerContractFields @{bounded_question='Which source resolves the claim?';role='researcher'}
Assert-That ($explorer.stop_condition -and $researcher.stop_condition -and $explorer.stop_condition -match 'sufficient evidence') 'eval: Explorer and Researcher stop on sufficient evidence'
$findings=Review-OrchestrationSimplicityFindings @{unrelated_changes=@('other module');speculative_abstractions=@('no consumer');duplicated_helpers=@('helper copy');unjustified_compatibility_layers=@('legacy shim')} $contract
Assert-That ($findings.Count -eq 4 -and @($findings.type | Select-Object -Unique).Count -eq 4) 'eval: reviewer flags all four simplicity categories'
Assert-That ((Get-Help Review-OrchestrationSimplicityFindings).Synopsis -match 'pre-categorized DiffSummary') 'Fix2 reviewer checklist is documented assistive, not autonomous'
Assert-That ((Review-OrchestrationSimplicityFindings @{unrelated_changes=@(1..201)} $contract)[0].type -eq 'input-limit-exceeded') 'F4 findings inputs capped at 200'
$hostileDiff=Review-OrchestrationSimplicityFindings ([pscustomobject]@{unrelated_changes='sk-SYNTHETICSECRET credential=secret'}) $contract
Assert-That ($hostileDiff.Count -eq 1) 'F5 hostile diff summary does not throw'
$pathSecret=Test-OrchestrationChangeBudget @(@{path='src/sk-SYNTHETICSECRET.ps1';additions=1;deletions=0}) $budget
Assert-That ((ConvertTo-Json $pathSecret -Compress) -notmatch 'SYNTHETICSECRET') 'F5 paths redact credential canaries'
Write-Output "PASS: $passed assertions"
