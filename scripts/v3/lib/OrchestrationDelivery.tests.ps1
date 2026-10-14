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
# --- F3-PURE: Get-OrchestrationGitHubReadiness (pure, data-only).
$GH_SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$GH_SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$GH_REPO = 'acme/widgets'
$GH_PR = 42
$GH_NOW = '2026-10-10T12:02:00Z'
$GH_OBS = '2026-10-10T12:00:00Z'
function New-GHCheck {
    param([string]$Name, [string]$Sha, [string]$Status, $Conclusion)
    return [pscustomobject]@{ name = $Name; head_sha = $Sha; status = $Status; conclusion = $Conclusion }
}
function New-GHChecksAllGreen {
    param([string]$Sha)
    $out = @()
    foreach ($n in @(Get-OrchestrationDeliveryRequiredChecks $policy)) { $out += @(New-GHCheck $n $Sha 'COMPLETED' 'success') }
    return $out
}
function New-GHSnapshot {
    param($Checks, [string]$Obs = $GH_OBS, [string]$Head = $GH_SHA_A, [string]$Commit = $GH_SHA_A, [string]$State = 'OPEN', [string]$Merge = 'MERGEABLE', [string]$Rev = 'APPROVED', [bool]$Complete = $true)
    return [pscustomobject]@{
        repository = $GH_REPO; pr_number = $GH_PR; head_sha = $Head; commit_sha = $Commit
        observed_at = $Obs; pr_state = $State; mergeable = $Merge
        review_decision = $Rev; checks_complete = $Complete; checks = $Checks
    }
}
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 300
Assert-That (([bool]$r.ok) -and ([string]$r.readiness -ceq 'READY_FOR_RESUME') -and (@($r.reasons).Count -eq 0)) 'F3 green => READY_FOR_RESUME ok'
Assert-That (([bool]$r.snapshot_only) -and (-not [bool]$r.grants_authority) -and (-not [bool]$r.done_approved) -and (-not [bool]$r.merge_authority) -and (-not [bool]$r.resume_authorized) -and (-not [bool]$r.kernel_mutated)) 'F3 green claims no authority and mutates nothing'
Assert-That ((([string]$r.repository -ceq 'acme/widgets') -and ([long]$r.pr_number -eq 42) -and ([string]$r.expected_head_sha -ceq $GH_SHA_A) -and ([string]$r.observed_head_sha -ceq $GH_SHA_A))) 'F3 identifiers echo canonically'
$r = Get-OrchestrationGitHubReadiness -Repository 'bad repo!' -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'invalid-repository'))) 'F3 bad repo => INCONCLUSIVE invalid-repository'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber '42' -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-pr-number'))) 'F3 string PR => INCONCLUSIVE invalid-pr-number'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha 'zzz' -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-expected-sha'))) 'F3 bad sha => INCONCLUSIVE invalid-expected-sha'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 0
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-max-age'))) 'F3 maxage 0 => INCONCLUSIVE invalid-max-age'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 3601
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-max-age'))) 'F3 maxage 3601 => INCONCLUSIVE invalid-max-age'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds '300'
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-max-age'))) 'F3 string maxage => INCONCLUSIVE invalid-max-age'
$wrongRepo = New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)
$wrongRepo.repository = 'acme/other'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $wrongRepo -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'repository-mismatch'))) 'F3 wrong snapshot repo => INCONCLUSIVE repository-mismatch'
$wrongPr = New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)
$wrongPr.pr_number = 43
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $wrongPr -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'pr-number-mismatch'))) 'F3 wrong snapshot PR => INCONCLUSIVE pr-number-mismatch'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Head $GH_SHA_B) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'STALE') -and (@($r.reasons) -contains 'head-mismatch'))) 'F3 replay old head => STALE head-mismatch'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Commit $GH_SHA_B) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'STALE') -and (@($r.reasons) -contains 'commit-mismatch'))) 'F3 commit mismatch => STALE commit-mismatch'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Obs '2026-10-10T11:00:00Z') -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 300
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'STALE') -and (@($r.reasons) -contains 'snapshot-stale'))) 'F3 stale timestamp => STALE snapshot-stale'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Obs '2026-10-10T12:05:00Z') -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 300
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'STALE') -and (@($r.reasons) -contains 'snapshot-future'))) 'F3 future timestamp => STALE snapshot-future'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -State 'MERGED') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'TERMINAL') -and (@($r.reasons) -contains 'pr-terminal'))) 'F3 merged PR => TERMINAL pr-terminal'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -State 'CLOSED') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'TERMINAL'))) 'F3 closed PR => TERMINAL'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Merge 'CONFLICTING') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'REPAIR_REQUIRED') -and (@($r.reasons) -contains 'merge-conflicting'))) 'F3 conflicting => REPAIR_REQUIRED merge-conflicting'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Merge 'UNKNOWN') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'mergeable-unknown'))) 'F3 mergeable unknown => INCONCLUSIVE mergeable-unknown'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Complete $false) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'CHECKS_PENDING') -and (@($r.reasons) -contains 'checks-incomplete'))) 'F3 checks_complete false => CHECKS_PENDING'
$missing = @((New-GHChecksAllGreen $GH_SHA_A) | Where-Object { [string]$_.name -cne 'CI (ps7)' })
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $missing) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'CHECKS_PENDING') -and (@($r.reasons) -contains 'check-missing:CI (ps7)'))) 'F3 missing required => CHECKS_PENDING check-missing'
$dup = @(New-GHChecksAllGreen $GH_SHA_A) + @(New-GHCheck 'ci (ps7)' $GH_SHA_A 'COMPLETED' 'success')
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $dup) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-duplicate:CI (ps7)'))) 'F3 duplicate required case-insensitive => INCONCLUSIVE check-duplicate'
$failedChecks = New-GHChecksAllGreen $GH_SHA_A
$failedChecks[1] = New-GHCheck 'CI (ps7)' $GH_SHA_A 'COMPLETED' 'failure'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $failedChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'REPAIR_REQUIRED') -and (@($r.reasons) -contains 'check-failed:CI (ps7)'))) 'F3 failed check => REPAIR_REQUIRED check-failed'
$skipChecks = New-GHChecksAllGreen $GH_SHA_A
$skipChecks[1] = New-GHCheck 'CI (ps7)' $GH_SHA_A 'COMPLETED' 'skipped'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $skipChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'check-failed:CI (ps7)'))) 'F3 skipped conclusion never green'
$neutChecks = New-GHChecksAllGreen $GH_SHA_A
$neutChecks[1] = New-GHCheck 'CI (ps7)' $GH_SHA_A 'COMPLETED' 'neutral'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $neutChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'check-failed:CI (ps7)'))) 'F3 neutral conclusion never green'
$nullChecks = @((New-GHChecksAllGreen $GH_SHA_A) | Where-Object { [string]$_.name -cne 'CI (ps7)' }) + @([pscustomobject]@{ name = 'CI (ps7)'; head_sha = $GH_SHA_A; status = 'COMPLETED'; conclusion = $null })
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $nullChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-inconclusive:CI (ps7)'))) 'F3 null conclusion => INCONCLUSIVE check-inconclusive'
$pendChecks = New-GHChecksAllGreen $GH_SHA_A
$pendChecks[1] = [pscustomobject]@{ name = 'CI (ps7)'; head_sha = $GH_SHA_A; status = 'IN_PROGRESS'; conclusion = $null }
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $pendChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'CHECKS_PENDING') -and (@($r.reasons) -contains 'check-pending:CI (ps7)'))) 'F3 in-progress check => CHECKS_PENDING check-pending'
$shaChecks = New-GHChecksAllGreen $GH_SHA_A
$shaChecks[1] = New-GHCheck 'CI (ps7)' $GH_SHA_B 'COMPLETED' 'success'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $shaChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-sha-mismatch:CI (ps7)'))) 'F3 required check on old head => INCONCLUSIVE check-sha-mismatch'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Rev 'CHANGES_REQUESTED') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'REPAIR_REQUIRED') -and (@($r.reasons) -contains 'changes-requested'))) 'F3 changes requested => REPAIR_REQUIRED'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A) -Rev 'REVIEW_REQUIRED') -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'REVIEW_PENDING') -and (@($r.reasons) -contains 'review-required'))) 'F3 review required => REVIEW_PENDING'
$extraBad = @(New-GHChecksAllGreen $GH_SHA_A) + @([pscustomobject]@{ name = 'CI (experiment)'; head_sha = 'bogus'; status = 'BROKEN'; conclusion = 42 })
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $extraBad) -Policy $policy -NowUtc $GH_NOW
Assert-That (([bool]$r.ok) -and ([string]$r.readiness -ceq 'READY_FOR_RESUME')) 'F3 invalid extra non-required ignored'
$noName = @(New-GHChecksAllGreen $GH_SHA_A) + @([pscustomobject]@{ head_sha = $GH_SHA_A; status = 'COMPLETED'; conclusion = 'success' })
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $noName) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'checks-invalid'))) 'F3 nameless entry => INCONCLUSIVE checks-invalid (never silently ignored)'
$nullChecksSnap = New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)
$nullChecksSnap.checks = $null
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $nullChecksSnap -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'checks-invalid'))) 'F3 null checks collection => INCONCLUSIVE checks-invalid'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy @{} -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'policy-invalid'))) 'F3 malformed policy => INCONCLUSIVE policy-invalid'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy @{} -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'policy-invalid'))) 'F3 malformed policy => INCONCLUSIVE policy-invalid'
# --- F3-FIX1: invalid identifiers are never echoed (no secret/huge leak, bounded).
$GH_CANARY = 'sk-SYNTHETICSECRET'
$GH_HUGE = ($GH_CANARY + "`n" + ('X' * 50000))
$r = Get-OrchestrationGitHubReadiness -Repository $GH_HUGE -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 300
Assert-That (((-not [bool]$r.ok) -and ([string]$r.repository -ceq '') -and ([string]$r.expected_head_sha -ceq ''))) 'F3 huge bad repo echoes no identifier'
$j = ConvertTo-Json $r -Compress -Depth 4
Assert-That ((($j -notmatch 'SYNTHETICSECRET') -and ($j.Length -le 4096))) 'F3 huge bad repo output bounded with no leak'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_CANARY -PrNumber $GH_PR -ExpectedHeadSha $GH_CANARY -Snapshot $null -Policy $policy -NowUtc $GH_NOW -MaxAgeSeconds 0
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-max-age') -and ([string]$r.repository -ceq '') -and ([string]$r.expected_head_sha -ceq ''))) 'F3 invalid maxage echoes no identifier'
$j = ConvertTo-Json $r -Compress -Depth 4
Assert-That ((($j -notmatch 'SYNTHETICSECRET') -and ($j.Length -le 4096))) 'F3 invalid maxage output bounded with no leak'
$r = Get-OrchestrationGitHubReadiness -Repository @('acme/widgets', 'evil') -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-repository') -and ([string]$r.repository -ceq ''))) 'F3 array repo echoes no identifier'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_CANARY -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'invalid-expected-sha') -and ([string]$r.expected_head_sha -ceq ''))) 'F3 bad sha echoes no identifier'
$j = ConvertTo-Json $r -Compress -Depth 4
Assert-That (($j -notmatch 'SYNTHETICSECRET')) 'F3 bad sha output carries no leak'
$GH_NLREPO = ('acme/wid' + "`n" + 'gets')
$r = Get-OrchestrationGitHubReadiness -Repository $GH_NLREPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.repository -ceq ''))) 'F3 newline repo echoes no identifier'
# --- F3-FIX2: required-check SHA must match before any status/conclusion verdict.
$oldFail = New-GHChecksAllGreen $GH_SHA_A
$oldFail[1] = New-GHCheck 'CI (ps7)' $GH_SHA_B 'COMPLETED' 'failure'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $oldFail) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-sha-mismatch:CI (ps7)') -and (-not (@($r.reasons) -contains 'check-failed:CI (ps7)')))) 'F3 old-head failure never repairs current HEAD'
$oldPend = New-GHChecksAllGreen $GH_SHA_A
$oldPend[1] = [pscustomobject]@{ name = 'CI (ps7)'; head_sha = $GH_SHA_B; status = 'IN_PROGRESS'; conclusion = $null }
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $oldPend) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-sha-mismatch:CI (ps7)'))) 'F3 old-head pending is inconclusive, not pending'
$noShaChecks = @((New-GHChecksAllGreen $GH_SHA_A) | Where-Object { [string]$_.name -cne 'CI (ps7)' }) + @([pscustomobject]@{ name = 'CI (ps7)'; status = 'COMPLETED'; conclusion = 'success' })
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $noShaChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'check-inconclusive:CI (ps7)'))) 'F3 missing check sha => INCONCLUSIVE check-inconclusive'
$badShaChecks = New-GHChecksAllGreen $GH_SHA_A
$badShaChecks[1] = New-GHCheck 'CI (ps7)' 'not-a-sha' 'COMPLETED' 'success'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot $badShaChecks) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'check-inconclusive:CI (ps7)'))) 'F3 malformed check sha => INCONCLUSIVE check-inconclusive'
# --- F3-FIX3: checks must be an explicit list, never a singular object/string.
$singPolicy = ConvertFrom-Json (ConvertTo-Json $policy -Depth 10)
$singPolicy.required_checks = @('CI (solo)')
$singEntry = [pscustomobject]@{ name = 'CI (solo)'; head_sha = $GH_SHA_A; status = 'COMPLETED'; conclusion = 'success' }
$singSnap = [pscustomobject]@{
    repository = $GH_REPO; pr_number = $GH_PR; head_sha = $GH_SHA_A; commit_sha = $GH_SHA_A
    observed_at = $GH_OBS; pr_state = 'OPEN'; mergeable = 'MERGEABLE'
    review_decision = 'APPROVED'; checks_complete = $true; checks = $singEntry
}
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $singSnap -Policy $singPolicy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'INCONCLUSIVE') -and (@($r.reasons) -contains 'checks-invalid'))) 'F3 singular checks object never READY'
$singSnapList = [pscustomobject]@{
    repository = $GH_REPO; pr_number = $GH_PR; head_sha = $GH_SHA_A; commit_sha = $GH_SHA_A
    observed_at = $GH_OBS; pr_state = 'OPEN'; mergeable = 'MERGEABLE'
    review_decision = 'APPROVED'; checks_complete = $true; checks = @($singEntry)
}
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $singSnapList -Policy $singPolicy -NowUtc $GH_NOW
Assert-That (([bool]$r.ok) -and ([string]$r.readiness -ceq 'READY_FOR_RESUME')) 'F3 single-check policy with proper list stays READY'
$strSnap = New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)
$strSnap.checks = 'COMPLETED'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $strSnap -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'checks-invalid'))) 'F3 string checks => INCONCLUSIVE checks-invalid'
$hashSnap = New-GHSnapshot (New-GHChecksAllGreen $GH_SHA_A)
$hashSnap.checks = @{ name = 'CI (ps7)'; head_sha = $GH_SHA_A; status = 'COMPLETED'; conclusion = 'success' }
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot $hashSnap -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and (@($r.reasons) -contains 'checks-invalid'))) 'F3 dictionary checks => INCONCLUSIVE checks-invalid'
$r = Get-OrchestrationGitHubReadiness -Repository $GH_REPO -PrNumber $GH_PR -ExpectedHeadSha $GH_SHA_A -Snapshot (New-GHSnapshot @()) -Policy $policy -NowUtc $GH_NOW
Assert-That (((-not [bool]$r.ok) -and ([string]$r.readiness -ceq 'CHECKS_PENDING') -and (@($r.reasons) -contains 'check-missing:CI (ps51)'))) 'F3 empty checks list means missing pending, not malformed'
Write-Output "PASS: $passed assertions"
