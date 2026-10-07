[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
$PolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
$policy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($PolicyPath)))
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-DCheck {
    param([string]$Name, [string]$Conclusion)
    return [pscustomobject]@{ name = $Name; conclusion = $Conclusion }
}
function Get-DAllOk {
    param($Policy)
    $out = @()
    foreach ($n in @(Get-OrchestrationDeliveryRequiredChecks $Policy)) { $out += @(New-DCheck $n 'success') }
    return $out
}
# --- POLICY: TDR-F12-01 declarative contract.
Assert-That (Test-OrchestrationDeliveryPolicyShape $policy) 'policy shape ok'
Assert-That ([long]$policy.schema_version -eq 1) 'policy schema_version 1'
Assert-That ([bool]$policy.require_pr) 'policy require_pr true'
Assert-That (([string]$policy.direct_push -cne 'deny') -eq $false -and ([string]$policy.force_push -cne 'deny') -eq $false) 'policy direct_push and force_push deny'
Assert-That ([bool]$policy.deletion_protected) 'policy deletion protected'
Assert-That (@($policy.required_checks).Count -eq 5) 'policy has 5 required checks'
Assert-That (([string]$policy.required_checks[0] -ceq 'CI (ps51)') -and ([string]$policy.required_checks[1] -ceq 'CI (ps7)') -and ([string]$policy.required_checks[2] -ceq 'CI (smoke opencode real)') -and ([string]$policy.required_checks[3] -ceq 'CI (v2 lane, perfil V2 provisionado)') -and ([string]$policy.required_checks[4] -ceq 'CI (smoke opencode v2 real)')) 'policy check names are the 5 real CI names'
Assert-That (([string]$policy.review.internal_reviewer -ceq 'required') -and (@($policy.review.security_reviewer_on) -contains 'auth') -and (@($policy.review.security_reviewer_on) -contains 'security-sensitive')) 'policy review gates'
Assert-That (([bool]$policy.auto_merge.allowed) -and (@($policy.auto_merge.requires) -contains 'reviewer_approved') -and (@($policy.auto_merge.requires) -contains 'no_unresolved_p1')) 'policy auto_merge gates'
Assert-That (@($policy.terminal_states).Count -eq 3 -and (@($policy.terminal_states) -contains 'MERGED') -and (@($policy.terminal_states) -contains 'DELIVERY_BLOCKED') -and (@($policy.terminal_states) -contains 'CANCELLED')) 'policy terminal states'
Assert-That ((ConvertTo-Json (Get-OrchestrationDeliveryRequiredChecks $policy) -Compress) -ceq (ConvertTo-Json @($policy.required_checks) -Compress)) 'lib required checks match JSON exactly'
Assert-That (-not (Test-OrchestrationDeliveryPolicyShape @{})) 'empty policy fails shape'
Assert-That ((@(Get-OrchestrationDeliveryTerminalStates).Count -eq 3) -and (Test-OrchestrationDeliveryTerminal 'MERGED') -and (Test-OrchestrationDeliveryTerminal 'DELIVERY_BLOCKED') -and (Test-OrchestrationDeliveryTerminal 'CANCELLED') -and (-not (Test-OrchestrationDeliveryTerminal 'REPAIR'))) 'terminal helper matches policy'
# --- ELIGIBILITY: TDR-F12-02.
$allOk = Get-DAllOk $policy
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'green approved P1-0 low => eligible'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'medium'
Assert-That ([bool]$e.eligible) 'risk medium => eligible'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $true -SecurityApproved $true -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible) 'security required and approved => eligible'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'LOW'
Assert-That ([bool]$e.eligible) 'risk match is case-insensitive'
$failed = Get-DAllOk $policy
$failed[1] = New-DCheck 'CI (ps7)' 'failure'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $failed -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (([string]$e.reasons[0] -ceq 'check-failed:CI (ps7)'))) 'single check failure => exact check-failed reason'
$missing = @((Get-DAllOk $policy) | Where-Object { [string]$_.name -cne 'CI (ps51)' })
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $missing -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (([string]$e.reasons[0] -ceq 'check-missing:CI (ps51)'))) 'missing check => exact check-missing reason'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $false -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'reviewer-pending')) 'reviewer not approved => reviewer-pending'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $true -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'security-pending')) 'security required but not approved => security-pending'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 2 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'unresolved-p1')) 'unresolved P1 => unresolved-p1'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'high'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'risk-too-high')) 'risk high => risk-too-high'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'critical'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'risk-too-high')) 'risk critical => risk-too-high'
$withExtra = @(Get-DAllOk $policy) + @(New-DCheck 'CI (experimental extra)' 'failure')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $withExtra -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'extra failing check is ignored'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $failed -ReviewerApproved $false -SecurityRequired $true -SecurityApproved $false -UnresolvedP1 3 -Risk 'high'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 5) -and (@($e.reasons) -contains 'check-failed:CI (ps7)') -and (@($e.reasons) -contains 'reviewer-pending') -and (@($e.reasons) -contains 'security-pending') -and (@($e.reasons) -contains 'unresolved-p1') -and (@($e.reasons) -contains 'risk-too-high')) 'combined failures accumulate every reason'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved 'yes' -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'invalid-argument')) 'non-bool reviewer fails closed'
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 (-1) -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'invalid-argument')) 'negative P1 fails closed'
$e = Test-OrchestrationMergeEligibility -Policy @{} -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'policy-invalid')) 'malformed policy fails closed as policy-invalid'
$badPolicy = ConvertFrom-Json (ConvertTo-Json $policy -Depth 10)
$badPolicy.PSObject.Properties.Remove('required_checks')
$e = Test-OrchestrationMergeEligibility -Policy $badPolicy -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'policy-invalid')) 'policy without required_checks => policy-invalid'
$noAuto = ConvertFrom-Json (ConvertTo-Json $policy -Depth 10)
$noAuto.auto_merge.allowed = $false
$e = Test-OrchestrationMergeEligibility -Policy $noAuto -Checks $allOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'auto-merge-disabled')) 'auto_merge.allowed=false blocks even when green'
$dupA = @(Get-DAllOk $policy) + @(New-DCheck 'CI (ps7)' 'failure')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupA -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'check-duplicate:CI (ps7)')) 'duplicate required check (success then failure) => check-duplicate'
$dupB = @(@(New-DCheck 'CI (ps7)' 'failure') + @(Get-DAllOk $policy))
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupB -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'check-duplicate:CI (ps7)')) 'duplicate required check (failure then success) => check-duplicate'
# --- FIX2: null/non-string conclusion never silences a duplicate; identity is case-insensitive; unique null is inconclusive (fail-closed).
function New-DCheckNull {
    param([string]$Name)
    return [pscustomobject]@{ name = $Name; conclusion = $null }
}
$dupNullFirst = @(@(New-DCheckNull 'CI (ps7)') + @(Get-DAllOk $policy))
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupNullFirst -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (@($e.reasons) -contains 'check-duplicate:CI (ps7)')) 'duplicate required check (null then success) => exactly check-duplicate'
$dupNullLast = @(Get-DAllOk $policy) + @(New-DCheckNull 'CI (ps7)')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupNullLast -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (@($e.reasons) -contains 'check-duplicate:CI (ps7)')) 'duplicate required check (success then null) => exactly check-duplicate'
$dupCase = @(Get-DAllOk $policy) + @(New-DCheck 'ci (ps51)' 'success')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupCase -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (@($e.reasons) -contains 'check-duplicate:CI (ps51)')) 'duplicate required check with different case => check-duplicate with policy canonical name'
$onlyNull = @((Get-DAllOk $policy) | Where-Object { [string]$_.name -cne 'CI (ps7)' }) + @(New-DCheckNull 'CI (ps7)')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $onlyNull -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons).Count -eq 1) -and (@($e.reasons) -contains 'check-inconclusive:CI (ps7)')) 'unique required check with null conclusion => exactly check-inconclusive (never silent, never missing)'
$onlyNonString = @((Get-DAllOk $policy) | Where-Object { [string]$_.name -cne 'CI (ps7)' }) + @([pscustomobject]@{ name = 'CI (ps7)'; conclusion = 42 })
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $onlyNonString -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ((-not [bool]$e.eligible) -and (@($e.reasons) -contains 'check-inconclusive:CI (ps7)')) 'unique required check with non-string conclusion => check-inconclusive'
$caseOk = @((Get-DAllOk $policy) | Where-Object { [string]$_.name -cne 'CI (ps51)' }) + @(New-DCheck 'ci (ps51)' 'success')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $caseOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'unique required check with different case and success => eligible (case-insensitive identity)'
$dupExtra = @(Get-DAllOk $policy) + @(New-DCheck 'CI (experimental extra)' 'failure') + @(New-DCheck 'CI (experimental extra)' 'failure')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $dupExtra -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'duplicate extra check stays ignored (only required names duplicate)'
$extraNullThenOk = @(Get-DAllOk $policy) + @(New-DCheckNull 'CI (experimental extra)') + @(New-DCheck 'CI (experimental extra)' 'success')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $extraNullThenOk -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'extra null then success is ignored => eligible'
$extraOkThenNull = @(Get-DAllOk $policy) + @(New-DCheck 'CI (experimental extra)' 'success') + @(New-DCheckNull 'CI (EXPERIMENTAL EXTRA)')
$e = Test-OrchestrationMergeEligibility -Policy $policy -Checks $extraOkThenNull -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-That ([bool]$e.eligible -and @($e.reasons).Count -eq 0) 'extra success then null (any case) is ignored => eligible'
# --- STATES: TDR-F12-03.
$s = Get-OrchestrationDeliveryState -Events @()
Assert-That (([string]$s.state -ceq 'IMPLEMENTATION') -and (-not [bool]$s.terminal)) 'empty events => IMPLEMENTATION non-terminal'
$s = Get-OrchestrationDeliveryState -Events $null
Assert-That ([string]$s.state -ceq 'IMPLEMENTATION') 'null events => IMPLEMENTATION'
$s = Get-OrchestrationDeliveryState -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged')
Assert-That (([string]$s.state -ceq 'MERGED') -and [bool]$s.terminal) 'happy path => MERGED terminal'
$s = Get-OrchestrationDeliveryState -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_failed')
Assert-That (([string]$s.state -ceq 'REPAIR') -and (-not [bool]$s.terminal)) 'ci_failed mid-flow => REPAIR non-terminal'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_failed')
Assert-That ([string]$s.state -ceq 'REPAIR') 'tests_failed => REPAIR'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_passed', 'review_changes_requested')
Assert-That ([string]$s.state -ceq 'REPAIR') 'review_changes_requested => REPAIR'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_failed', 'finding_repair')
Assert-That (([string]$s.state -ceq 'TESTING') -and (-not [bool]$s.terminal)) 'finding_repair returns REPAIR to TESTING'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_failed', 'finding_repair', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged')
Assert-That (([string]$s.state -ceq 'MERGED') -and [bool]$s.terminal) 'repair loop can still reach MERGED'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'blocked')
Assert-That (([string]$s.state -ceq 'DELIVERY_BLOCKED') -and [bool]$s.terminal) 'blocked => DELIVERY_BLOCKED terminal'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'cancelled')
Assert-That (([string]$s.state -ceq 'CANCELLED') -and [bool]$s.terminal) 'cancelled => CANCELLED terminal'
$s = Get-OrchestrationDeliveryState -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged', 'ci_failed')
Assert-That (([string]$s.state -ceq 'MERGED') -and [bool]$s.terminal) 'terminal MERGED is sticky'
$s = Get-OrchestrationDeliveryState -Events @('merged')
Assert-That (([string]$s.state -ceq 'IMPLEMENTATION') -and (-not [bool]$s.terminal)) 'merged outside MERGE_GATE does not advance'
$s = Get-OrchestrationDeliveryState -Events @('deployed')
Assert-That (([string]$s.state -ceq 'INVALID') -and ([string]$s.reason -ceq 'invalid-event')) 'unknown event => INVALID invalid-event'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'deployed', 'merged')
Assert-That ([string]$s.state -ceq 'INVALID') 'event set validated before folding'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 42)
Assert-That (([string]$s.state -ceq 'INVALID') -and ([string]$s.reason -ceq 'invalid-event')) 'non-string event => INVALID'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_failed', 'finding_repair', 'tests_passed', 'pr_opened', 'ci_passed', 'merged')
Assert-That (([string]$s.state -cne 'MERGED') -and (-not [bool]$s.terminal)) 'pr_opened without review_approved never reaches MERGED'
$s = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_failed', 'finding_repair', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged')
Assert-That (([string]$s.state -ceq 'MERGED') -and [bool]$s.terminal) 'pr_opened after review_approved still reaches MERGED'
$s = Get-OrchestrationDeliveryState -Events @('branch_created', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'pr_opened', 'ci_passed', 'merged')
Assert-That (([string]$s.state -ceq 'MERGED') -and [bool]$s.terminal) 'pr_opened re-open from PR_OPEN still reaches MERGED'
Write-Output "PASS: $passed assertions"
