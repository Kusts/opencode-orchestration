<#!
.SYNOPSIS
    V3 Delivery lib: GitHub delivery continuation policy + merge eligibility (SPEC v0.1.0 Phase 12, PR-J).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure policy mirror and
    state helpers, fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns an object with eligible=$false
    (or state='INVALID') and a machine-readable reason. No network, no
    process, no git/gh calls, no merge authority: merge execution stays
    external (human/bot). This lib decides eligibility only.

    TDR-F12-01: the declarative contract lives in
    source/registry/delivery-policy.json (require_pr, direct_push/force_push
    deny, deletion protection, the 5 real CI check names from
    docs/github-lifecycle-policy.md section 4, internal reviewer required +
    security reviewer triggers, findings loop without user prompts,
    auto_merge gates, terminal states MERGED DELIVERY_BLOCKED CANCELLED).
    The tables below must match it exactly (asserted by the suite); the JSON
    is the readable policy, this lib is the enforcement.

    TDR-F12-02: Test-OrchestrationMergeEligibility folds required checks
    (conclusion 'success' exact), reviewer approval, conditional security
    approval, unresolved P1 count and risk band into eligible + reasons.
    Extra checks beyond the required set are ignored.
    FIX2: required-name repetition is detected before conclusion filtering
    (any repeated required name => check-duplicate, whatever the
    conclusion); identity is case-insensitive with the policy canonical
    name in reasons; a unique entry whose conclusion is null or non-string
    is never silent => check-inconclusive (fail-closed).
    FIX3: extras (any name outside the required set, any case) are
    discarded before any evaluation -- string, null, non-string
    conclusions and repeats among themselves are all ignored.

    TDR-F12-03: Get-OrchestrationDeliveryState folds a closed event set into
    a delivery state with a terminal flag. Unknown events fail closed to
    state 'INVALID' with reason 'invalid-event'; the whole event list is
    validated before folding.

    Branch/PR/CI/review substance is NOT duplicated here: see
    docs/github-lifecycle-policy.md sections 2-5 and SPEC section 22.
#>
[CmdletBinding()]
param()

function Get-DeliveryValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-OrchestrationDeliveryPolicy {
    [CmdletBinding()]
    param($Policy = $null)
    try {
        if ($null -ne $Policy) { return $Policy }
        $path = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
        try {
            $full = [IO.Path]::GetFullPath($path)
            return (ConvertFrom-Json ([IO.File]::ReadAllText($full)))
        }
        catch { return $null }
    }
    catch { return $null }
}

function Get-OrchestrationDeliveryRequiredChecks {
    [CmdletBinding()]
    param($Policy = $null)
    try {
        $Policy = Get-OrchestrationDeliveryPolicy $Policy
        $raw = Get-DeliveryValue $Policy 'required_checks' $null
        if ($null -eq $raw) { return $null }
        $out = New-Object System.Collections.ArrayList
        foreach ($item in @($raw)) {
            if (($item -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$item))) {
                [void]$out.Add([string]$item)
            }
            else { return $null }
        }
        if ($out.Count -eq 0) { return $null }
        return [string[]]$out.ToArray()
    }
    catch { return $null }
}

function Test-OrchestrationDeliveryPolicyShape {
    [CmdletBinding()]
    param($Policy = $null)
    try {
        $Policy = Get-OrchestrationDeliveryPolicy $Policy
        if ($null -eq $Policy) { return $false }
        $sv = Get-DeliveryValue $Policy 'schema_version' $null
        if (-not ($sv -is [int] -or $sv -is [long])) { return $false }
        if ([long]$sv -ne 1) { return $false }
        if (-not ((Get-DeliveryValue $Policy 'require_pr' $null) -is [bool])) { return $false }
        if ([string](Get-DeliveryValue $Policy 'direct_push' '') -cne 'deny') { return $false }
        if ([string](Get-DeliveryValue $Policy 'force_push' '') -cne 'deny') { return $false }
        if (-not ((Get-DeliveryValue $Policy 'deletion_protected' $null) -is [bool])) { return $false }
        if ($null -eq (Get-OrchestrationDeliveryRequiredChecks $Policy)) { return $false }
        $review = Get-DeliveryValue $Policy 'review' $null
        if ($null -eq $review) { return $false }
        if ([string](Get-DeliveryValue $review 'internal_reviewer' '') -cne 'required') { return $false }
        $secOn = Get-DeliveryValue $review 'security_reviewer_on' $null
        if ($null -eq $secOn -or @($secOn).Count -eq 0) { return $false }
        foreach ($t in @($secOn)) {
            if (-not ($t -is [string]) -or [string]::IsNullOrWhiteSpace([string]$t)) { return $false }
        }
        $auto = Get-DeliveryValue $Policy 'auto_merge' $null
        if ($null -eq $auto) { return $false }
        if (-not ((Get-DeliveryValue $auto 'allowed' $null) -is [bool])) { return $false }
        if ($null -eq (Get-DeliveryValue $auto 'requires' $null) -or @(Get-DeliveryValue $auto 'requires' @()).Count -eq 0) { return $false }
        $terms = Get-DeliveryValue $Policy 'terminal_states' $null
        if ($null -eq $terms -or @($terms).Count -eq 0) { return $false }
        foreach ($t in @($terms)) {
            if (-not ($t -is [string]) -or [string]::IsNullOrWhiteSpace([string]$t)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-OrchestrationDeliveryEvents {
    [CmdletBinding()]
    param()
    return @('branch_created', 'implemented', 'tests_passed', 'tests_failed', 'review_approved', 'review_changes_requested', 'pr_opened', 'ci_passed', 'ci_failed', 'finding_repair', 'merged', 'blocked', 'cancelled')
}

function Get-OrchestrationDeliveryStates {
    [CmdletBinding()]
    param()
    return @('IMPLEMENTATION', 'TESTING', 'REVIEW', 'PR_READY', 'PR_OPEN', 'MERGE_GATE', 'REPAIR', 'MERGED', 'DELIVERY_BLOCKED', 'CANCELLED', 'INVALID')
}

function Get-OrchestrationDeliveryTerminalStates {
    [CmdletBinding()]
    param()
    try {
        $Policy = Get-OrchestrationDeliveryPolicy
        $terms = Get-DeliveryValue $Policy 'terminal_states' $null
        if ($null -ne $terms -and @($terms).Count -gt 0) {
            $ok = $true
            foreach ($t in @($terms)) {
                if (-not ($t -is [string]) -or [string]::IsNullOrWhiteSpace([string]$t)) { $ok = $false; break }
            }
            if ($ok) { return [string[]]@($terms) }
        }
        return @('MERGED', 'DELIVERY_BLOCKED', 'CANCELLED')
    }
    catch { return @('MERGED', 'DELIVERY_BLOCKED', 'CANCELLED') }
}

function Test-OrchestrationDeliveryTerminal {
    [CmdletBinding()]
    param([string]$State = '')
    try {
        $s = ([string]$State).Trim().ToUpperInvariant()
        foreach ($t in @(Get-OrchestrationDeliveryTerminalStates)) {
            if ($s -ceq ([string]$t)) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-OrchestrationMergeEligibility {
    [CmdletBinding()]
    param(
        $Policy = $null,
        $Checks = @(),
        $ReviewerApproved = $null,
        $SecurityRequired = $null,
        $SecurityApproved = $null,
        $UnresolvedP1 = $null,
        $Risk = $null
    )
    try {
        $resolved = Get-OrchestrationDeliveryPolicy $Policy
        if ($null -eq $resolved) {
            return [pscustomobject]@{ eligible = $false; reasons = @('policy-unavailable') }
        }
        if (-not (Test-OrchestrationDeliveryPolicyShape $resolved)) {
            return [pscustomobject]@{ eligible = $false; reasons = @('policy-invalid') }
        }
        $auto = Get-DeliveryValue $resolved 'auto_merge' $null
        if (-not [bool](Get-DeliveryValue $auto 'allowed' $false)) {
            return [pscustomobject]@{ eligible = $false; reasons = @('auto-merge-disabled') }
        }
        $required = Get-OrchestrationDeliveryRequiredChecks $resolved
        if ($null -eq $required) {
            return [pscustomobject]@{ eligible = $false; reasons = @('policy-unavailable') }
        }
        if (-not ($ReviewerApproved -is [bool]) -or -not ($SecurityRequired -is [bool]) -or -not ($SecurityApproved -is [bool])) {
            return [pscustomobject]@{ eligible = $false; reasons = @('invalid-argument') }
        }
        $p1ok = ($UnresolvedP1 -is [int] -or $UnresolvedP1 -is [long] -or $UnresolvedP1 -is [short] -or $UnresolvedP1 -is [byte])
        if (-not $p1ok -or [long]$UnresolvedP1 -lt 0) {
            return [pscustomobject]@{ eligible = $false; reasons = @('invalid-argument') }
        }
        $requiredKeys = @{}
        $requiredCanon = @{}
        foreach ($rn in @($required)) {
            $rns = [string]$rn
            if ([string]::IsNullOrWhiteSpace($rns)) { continue }
            $rk = $rns.ToLowerInvariant()
            if (-not $requiredKeys.ContainsKey($rk)) {
                $requiredKeys[$rk] = $true
                $requiredCanon[$rk] = $rns
            }
        }
        $byName = @{}
        $inconclusive = @{}
        $dupKeys = @{}
        $dupNames = New-Object System.Collections.ArrayList
        if ($null -ne $Checks) {
            foreach ($c in @($Checks)) {
                $n = [string](Get-DeliveryValue $c 'name' '')
                if ([string]::IsNullOrWhiteSpace($n)) { continue }
                $key = $n.ToLowerInvariant()
                $isReq = $requiredKeys.ContainsKey($key)
                if (-not $isReq) { continue }
                $canon = [string]$requiredCanon[$key]
                if ($byName.ContainsKey($key) -or $inconclusive.ContainsKey($key)) {
                    if (-not $dupKeys.ContainsKey($key)) {
                        $dupKeys[$key] = $true
                        [void]$dupNames.Add($canon)
                    }
                    continue
                }
                $con = Get-DeliveryValue $c 'conclusion' $null
                if ($con -is [string]) { $byName[$key] = [string]$con }
                else { $inconclusive[$key] = $canon }
            }
        }
        $reasons = New-Object System.Collections.ArrayList
        foreach ($d in @($dupNames)) {
            [void]$reasons.Add(('check-duplicate:' + [string]$d))
        }
        foreach ($name in @($required)) {
            $rk = ([string]$name).ToLowerInvariant()
            if ($dupKeys.ContainsKey($rk)) { continue }
            if (-not $byName.ContainsKey($rk)) {
                if ($inconclusive.ContainsKey($rk)) {
                    [void]$reasons.Add(('check-inconclusive:' + [string]$requiredCanon[$rk]))
                }
                else {
                    [void]$reasons.Add(('check-missing:' + [string]$name))
                }
            }
            elseif ([string]$byName[$rk] -cne 'success') {
                [void]$reasons.Add(('check-failed:' + [string]$name))
            }
        }
        if (-not [bool]$ReviewerApproved) {
            [void]$reasons.Add('reviewer-pending')
        }
        if ([bool]$SecurityRequired -and (-not [bool]$SecurityApproved)) {
            [void]$reasons.Add('security-pending')
        }
        if ([long]$UnresolvedP1 -ne 0) {
            [void]$reasons.Add('unresolved-p1')
        }
        $riskNorm = ''
        if ($Risk -is [string]) { $riskNorm = ([string]$Risk).Trim().ToLowerInvariant() }
        if ($riskNorm -cne 'low' -and $riskNorm -cne 'medium') {
            [void]$reasons.Add('risk-too-high')
        }
        $arr = [string[]]$reasons.ToArray()
        return [pscustomobject]@{ eligible = ($arr.Count -eq 0); reasons = $arr }
    }
    catch {
        return [pscustomobject]@{ eligible = $false; reasons = @('evaluation-failed') }
    }
}

function Get-OrchestrationDeliveryState {
    [CmdletBinding()]
    param($Events = @())
    try {
        $closed = @(Get-OrchestrationDeliveryEvents)
        $list = @()
        if ($null -ne $Events) {
            if ($Events -is [string]) { $list = @([string]$Events) }
            else { $list = @($Events) }
        }
        foreach ($e in $list) {
            $ok = $false
            if ($e -is [string]) {
                foreach ($c in $closed) {
                    if ([string]$e -ceq [string]$c) { $ok = $true; break }
                }
            }
            if (-not $ok) {
                return [pscustomobject]@{ state = 'INVALID'; terminal = $false; reason = 'invalid-event' }
            }
        }
        $state = 'IMPLEMENTATION'
        foreach ($e in $list) {
            $ev = [string]$e
            if (Test-OrchestrationDeliveryTerminal $state) { break }
            switch ($ev) {
                'tests_failed' { $state = 'REPAIR' }
                'ci_failed' { $state = 'REPAIR' }
                'review_changes_requested' { $state = 'REPAIR' }
                'blocked' { $state = 'DELIVERY_BLOCKED' }
                'cancelled' { $state = 'CANCELLED' }
                'merged' { if ($state -ceq 'MERGE_GATE') { $state = 'MERGED' } }
                'branch_created' {
                    if ($state -ceq 'IMPLEMENTATION') { $state = 'IMPLEMENTATION' }
                    elseif ($state -ceq 'REPAIR') { $state = 'IMPLEMENTATION' }
                }
                'implemented' {
                    if ($state -ceq 'IMPLEMENTATION' -or $state -ceq 'REPAIR') { $state = 'TESTING' }
                }
                'tests_passed' {
                    if ($state -ceq 'TESTING') { $state = 'REVIEW' }
                }
                'review_approved' {
                    if ($state -ceq 'REVIEW') { $state = 'PR_READY' }
                }
                'pr_opened' {
                    if ($state -ceq 'PR_READY' -or $state -ceq 'PR_OPEN') { $state = 'PR_OPEN' }
                }
                'ci_passed' {
                    if ($state -ceq 'PR_OPEN') { $state = 'MERGE_GATE' }
                }
                'finding_repair' {
                    if ($state -ceq 'REPAIR') { $state = 'TESTING' }
                }
                default { }
            }
        }
        return [pscustomobject]@{ state = $state; terminal = [bool](Test-OrchestrationDeliveryTerminal $state); reason = '' }
    }
    catch {
        return [pscustomobject]@{ state = 'INVALID'; terminal = $false; reason = 'invalid-event' }
    }
}
