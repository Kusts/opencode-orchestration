<#!
.SYNOPSIS
    Governance tests for protect-master.ps1 (Phase 2E git governance).
.DESCRIPTION
    Pure classifier tests: no git write is ever executed (only
    Test-GitOperationAllowed / Get-GitGovernanceReviewClassification calls,
    plus two CLI subprocess invocations with an explicit -CurrentBranch so
    no branch auto-detection runs). Run with
    `powershell -NoProfile -File <this-file>`; exit 0/1. Discovered
    automatically by run-v3-tests.ps1 (scripts/v3/*.tests.ps1), no runner
    registration needed.
#>
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$guard = Join-Path $v3 'protect-master.ps1'
. $guard

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Invoke-GuardCli {
    param([string]$CommandLine, [string]$Branch)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = & powershell -NoProfile -File $guard -CommandLine $CommandLine -CurrentBranch $Branch
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = ((($text | ForEach-Object { "$_" }) -join "`n")) }
}

try {
    Assert-That (Test-Path -LiteralPath $guard -PathType Leaf) 'guard file exists' "Missing $guard"

    # (a) direct master push rejected
    $r = Test-GitOperationAllowed -CommandLine 'git push origin master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'direct master push rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin refs/heads/master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'refs/heads/master push rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'implicit push on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin "master"' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'quoted master push rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin --all' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push --all rejected fail-closed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin --mirror' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push --mirror rejected fail-closed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin --branches' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push --branches rejected fail-closed (--all alias)' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (a2) HEAD/bare push resolving to master rejected on master or unknown branch
    $r = Test-GitOperationAllowed -CommandLine 'git push origin HEAD' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push HEAD on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin HEAD:master' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push HEAD:master on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin +HEAD' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push +HEAD on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin HEAD' -CurrentBranch ''
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push HEAD on unknown branch rejected fail-closed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin HEAD' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'push HEAD on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin HEAD:master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_PUSH')) 'push HEAD:master from feature branch rejected' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (a3) history writes on master rejected, allowed on feature branches
    $r = Test-GitOperationAllowed -CommandLine 'git merge feat/x' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'merge on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git cherry-pick abc1234' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'cherry-pick on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git revert HEAD' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'revert on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git rebase master' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'rebase on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git reset --hard HEAD~1' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'reset on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git am 0001-fix.patch' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'am on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git merge feat/y' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'merge on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git cherry-pick abc1234' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'cherry-pick on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git reset --hard HEAD~1' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'reset on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git merge feat/y' -CurrentBranch ''
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'UNKNOWN_BRANCH')) 'merge on unknown branch denied fail-closed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git "merge" feat/x' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'quoted merge on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine "git 'merge' feat/x" -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'single-quoted merge on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git "cherry-pick" abc1234' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'quoted cherry-pick on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine "git 'cherry-pick' abc1234" -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'single-quoted cherry-pick on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git "merge" feat/y' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'quoted merge on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine "git 'merge' feat/y" -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'single-quoted merge on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (b) force push rejected
    $r = Test-GitOperationAllowed -CommandLine 'git push --force origin master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'FORCE_PUSH')) 'force push to master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push --force-with-lease origin master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'FORCE_PUSH')) 'force-with-lease to master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push -f origin master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'FORCE_PUSH')) 'short -f push to master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin +master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'FORCE_PUSH')) 'plus-refspec push to master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push --force' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'FORCE_PUSH')) 'implicit force push on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (d) delete of master rejected
    $r = Test-GitOperationAllowed -CommandLine 'git push origin --delete master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DELETE_PROTECTED')) 'delete-flag push of master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin :master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DELETE_PROTECTED')) 'delete-refspec push of master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin :refs/heads/master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DELETE_PROTECTED')) 'delete-refspec of refs/heads/master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (c) feature branch push allowed
    $r = Test-GitOperationAllowed -CommandLine 'git push origin feat/advisory-validation-git-governance-phase-2e' -CurrentBranch 'feat/advisory-validation-git-governance-phase-2e'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'feature branch push allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push --force origin feat/x' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'force push on explicit feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (d) PR workflow / read-only allowed
    $r = Test-GitOperationAllowed -CommandLine 'git checkout master' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_READONLY')) 'checkout master allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git pull' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_READONLY')) 'pull allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git log --oneline -5' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_READONLY')) 'log allowed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git status' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_READONLY')) 'status allowed' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (e) closure docs committed on master still rejected (no docs-only exemption)
    $r = Test-GitOperationAllowed -CommandLine 'git commit -m "docs: closure" -- docs/closure.md' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'docs-only commit on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git commit -m "fix: thing"' -CurrentBranch 'master'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'DIRECT_MASTER_COMMIT')) 'plain commit on master rejected' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git commit -m "docs: closure" -- docs/closure.md' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'docs commit on feature branch allowed' ("got $($r.Verdict)/$($r.ReasonCode)")

    # (f) fallback review classification is not an approval (explicit approval bound to SHA required)
    $fallback = Get-GitGovernanceReviewClassification -ReviewAvailable $false -CiPass $true -ThreadsResolved $true
    Assert-That ($fallback -ceq 'REVIEW_FALLBACK') 'fallback object classifies REVIEW_FALLBACK' ("got $fallback")
    Assert-That ($fallback -cne 'REVIEW_APPROVED') 'REVIEW_FALLBACK != REVIEW_APPROVED' ("got $fallback")
    $availOnly = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $true -ThreadsResolved $true
    Assert-That ($availOnly -ceq 'REVIEW_FALLBACK') 'availability alone classifies REVIEW_FALLBACK' ("got $availOnly")
    $approved = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $true -ThreadsResolved $true -ReviewApproved $true
    Assert-That ($approved -ceq 'REVIEW_APPROVED') 'explicit approval classifies REVIEW_APPROVED' ("got $approved")
    $noExplicit = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $true -ThreadsResolved $true -ReviewApproved $false
    Assert-That ($noExplicit -ceq 'REVIEW_FALLBACK') 'no explicit approval classifies REVIEW_FALLBACK' ("got $noExplicit")
    $changesReq = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $true -ThreadsResolved $true -ReviewApproved $false
    Assert-That ($changesReq -ceq 'REVIEW_FALLBACK') 'CHANGES_REQUIRED classifies REVIEW_FALLBACK' ("got $changesReq")
    $ciFail = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $false -ThreadsResolved $true -ReviewApproved $true
    Assert-That ($ciFail -ceq 'REVIEW_FALLBACK') 'failing CI classifies REVIEW_FALLBACK' ("got $ciFail")
    $threadsOpen = Get-GitGovernanceReviewClassification -ReviewAvailable $true -CiPass $true -ThreadsResolved $false -ReviewApproved $true
    Assert-That ($threadsOpen -ceq 'REVIEW_FALLBACK') 'unresolved threads classifies REVIEW_FALLBACK' ("got $threadsOpen")

    # fail-closed edges
    $r = Test-GitOperationAllowed -CommandLine 'frobnicate master' -CurrentBranch 'feat/x'
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'UNKNOWN_OPERATION')) 'non-git command denied fail-closed' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git commit -m "x"' -CurrentBranch ''
    Assert-That ((-not $r.Allowed) -and ($r.ReasonCode -ceq 'UNKNOWN_BRANCH')) 'commit with unknown branch denied' ("got $($r.Verdict)/$($r.ReasonCode)")
    $r = Test-GitOperationAllowed -CommandLine 'git push origin master-fix' -CurrentBranch 'feat/x'
    Assert-That ($r.Allowed -and ($r.ReasonCode -ceq 'OK_FEATURE_BRANCH')) 'master-prefix branch push allowed' ("got $($r.Verdict)/$($r.ReasonCode)")

    # CLI mode: exit codes without executing git (explicit branch, no auto-detect)
    $cli = Invoke-GuardCli -CommandLine 'git status' -Branch 'feat/x'
    Assert-That (($cli.Code -eq 0) -and ($cli.Text -match '\AALLOW OK_READONLY')) 'CLI allows read-only with exit 0' ("code $($cli.Code): $($cli.Text)")
    $cli = Invoke-GuardCli -CommandLine 'git push origin master' -Branch 'feat/x'
    Assert-That (($cli.Code -eq 1) -and ($cli.Text -match '\ADENY DIRECT_MASTER_PUSH')) 'CLI denies master push with exit 1' ("code $($cli.Code): $($cli.Text)")
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $total++
}

Write-Host ("ProtectMaster: {0} / {1} tests passed" -f $passed, $total)
if ($passed -ne $total) { exit 1 }
exit 0
