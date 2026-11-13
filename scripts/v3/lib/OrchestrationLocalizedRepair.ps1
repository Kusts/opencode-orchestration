<#!
.SYNOPSIS
    Localized repair decision before retry/replan (issue #103).
.DESCRIPTION
    Deterministic policy helper. It never executes or dispatches; it returns
    the safest next decision and its reason. Fail-closed: ambiguous external
    effects, stale evidence, critical findings and exhausted attempts always
    leave the local-repair path. PS 5.1, ASCII-only.
#>
function Resolve-OrchestrationLocalizedRepair {
    <#
    .SYNOPSIS
        Chooses LOCAL_REPAIR, REPLAN or ESCALATE for a review/failure finding.
    .OUTPUTS
        @{ ok; decision; reason; constraints }
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('low', 'medium', 'high', 'critical')][string]$Severity = 'medium',
        [int]$ChangedFiles = 1,
        [bool]$ScopeOverlap = $true,
        [bool]$ExternalEffectsAmbiguous = $false,
        [bool]$EvidenceCurrent = $true,
        [int]$Attempts = 0,
        [ValidateSet('localized', 'unknown', 'structural')][string]$FailureClass = 'localized'
    )
    try {
        if ($ChangedFiles -lt 0 -or $ChangedFiles -gt 100000) { return @{ ok = $false; decision = 'INVALID'; reason = 'changed-files-invalid'; constraints = @() } }
        if ($Attempts -lt 0 -or $Attempts -gt 100) { return @{ ok = $false; decision = 'INVALID'; reason = 'attempts-invalid'; constraints = @() } }

        if ($ExternalEffectsAmbiguous) {
            return @{ ok = $true; decision = 'REPLAN'; reason = 'ambiguous-external-effect'; constraints = @('no-blind-retry', 'settle-external-effect-first') }
        }
        if (-not $EvidenceCurrent) {
            return @{ ok = $true; decision = 'REPLAN'; reason = 'evidence-drift'; constraints = @('re-anchor-finding', 'do-not-apply-stale-fix') }
        }
        if ($Attempts -ge 2) {
            return @{ ok = $true; decision = 'ESCALATE'; reason = 'retry-budget-exhausted'; constraints = @('debugger-with-new-evidence', 'no-third-blind-attempt') }
        }
        if ($FailureClass -ceq 'structural') {
            return @{ ok = $true; decision = 'REPLAN'; reason = 'structural-failure'; constraints = @('new-strategy-required') }
        }
        if ($Severity -ceq 'critical') {
            return @{ ok = $true; decision = 'REPLAN'; reason = 'critical-scope'; constraints = @('review-invariants', 'no-local-only-fix') }
        }
        if ($FailureClass -ceq 'unknown') {
            return @{ ok = $true; decision = 'REPLAN'; reason = 'failure-class-unknown'; constraints = @('classify-before-repair') }
        }
        if ($ChangedFiles -le 2 -and $ScopeOverlap -and $Attempts -lt 2) {
            return @{ ok = $true; decision = 'LOCAL_REPAIR'; reason = 'localized-finding'; constraints = @('same-task', 'no-external-replay', 'focused-validation') }
        }
        return @{ ok = $true; decision = 'REPLAN'; reason = 'scope-too-broad'; constraints = @('reassess-scope') }
    }
    catch { return @{ ok = $false; decision = 'INVALID'; reason = 'repair-decision-failed'; constraints = @() } }
}
