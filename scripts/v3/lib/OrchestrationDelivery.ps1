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

    SOLO-MAINTAINER: source/registry/delivery-policy.json declares a named
    'solo-maintainer' profile with independent review fields
    (internal_reviewer=required, github_approval=not_required); the default
    profile keeps github_approval=required explicitly. Effective review is
    resolved by Get-OrchestrationDeliveryEffectiveReview for an explicit
    -DeliveryProfile only -- approval is never inferred from the reviewer
    field. Under the solo regime the GitHub approval leg is waived (an
    explicit CHANGES_REQUESTED still repairs). No signed RSA attestation
    is required: a valid internal-agent review record on the expected
    head SHA satisfies TECHNICAL readiness without any cryptographic
    attestation; the offline attestation verifier stays experimental,
    disconnected from readiness, and BLOCKED (no keys/certs). The valid
    agent record is quality-control evidence only -- its origin and
    limits are recorded in the readiness evidence (review_basis /
    review_detail) and it never claims authenticated identity, an
    independent signature, human approval, or GitHub approval. The
    default regime is byte-identical in behavior to the pre-profile
    code.
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
        $ghAppr = Get-DeliveryValue $review 'github_approval' $null
        if ($null -ne $ghAppr) {
            if (-not ($ghAppr -is [string])) { return $false }
            $ghNorm = ([string]$ghAppr).Trim().ToLowerInvariant()
            if (($ghNorm -cne 'required') -and ($ghNorm -cne 'not_required')) { return $false }
        }
        $profName = Get-DeliveryValue $Policy 'profile' $null
        if ($null -ne $profName) {
            if (-not ($profName -is [string])) { return $false }
            $profTrim = ([string]$profName).Trim()
            if ([string]::IsNullOrWhiteSpace($profTrim) -or $profTrim.Length -gt 64) { return $false }
            if ($profTrim -cnotmatch '\A[A-Za-z0-9._-]+\z') { return $false }
        }
        $profiles = Get-DeliveryValue $Policy 'profiles' $null
        if ($null -ne $profiles) {
            $entries = @()
            try {
                if ($profiles -is [System.Collections.IDictionary]) {
                    foreach ($k in @($profiles.Keys)) {
                        $entries += @([pscustomobject]@{ name = [string]$k; value = $profiles[$k] })
                    }
                }
                else {
                    foreach ($p in @($profiles.PSObject.Properties)) {
                        $entries += @([pscustomobject]@{ name = [string]$p.Name; value = $p.Value })
                    }
                }
            }
            catch { return $false }
            if (@($entries).Count -eq 0) { return $false }
            foreach ($en in @($entries)) {
                if ([string]::IsNullOrWhiteSpace([string]$en.name)) { return $false }
                if (([string]$en.name).Length -gt 64) { return $false }
                if (([string]$en.name) -cnotmatch '\A[A-Za-z0-9._-]+\z') { return $false }
                $prv = Get-DeliveryValue $en.value 'review' $null
                if ($null -eq $prv) { return $false }
                $pInt = Get-DeliveryValue $prv 'internal_reviewer' $null
                if (-not ($pInt -is [string])) { return $false }
                if (([string]$pInt).Trim().ToLowerInvariant() -cne 'required') { return $false }
                $pGh = Get-DeliveryValue $prv 'github_approval' $null
                if (-not ($pGh -is [string])) { return $false }
                $pGhNorm = ([string]$pGh).Trim().ToLowerInvariant()
                if (($pGhNorm -cne 'required') -and ($pGhNorm -cne 'not_required')) { return $false }
            }
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

function Get-OrchestrationDeliveryEffectiveReview {
    [CmdletBinding()]
    param($Policy = $null, $DeliveryProfile = '')
    try {
        $fail = [pscustomobject]@{ ok = $false; reason = 'policy-invalid'; profile = ''; internal_reviewer = ''; github_approval = '' }
        $resolved = Get-OrchestrationDeliveryPolicy $Policy
        if (($null -eq $resolved) -or (-not (Test-OrchestrationDeliveryPolicyShape $resolved))) {
            return $fail
        }
        $profName = ''
        if ($null -eq $DeliveryProfile) { $profName = '' }
        elseif ($DeliveryProfile -is [string]) { $profName = ([string]$DeliveryProfile).Trim() }
        else { return $fail }
        if ($profName -eq '') {
            $review = Get-DeliveryValue $resolved 'review' $null
            $intRev = ([string](Get-DeliveryValue $review 'internal_reviewer' '')).Trim().ToLowerInvariant()
            $ghRaw = Get-DeliveryValue $review 'github_approval' $null
            $ghAppr = 'required'
            if ($null -ne $ghRaw) {
                if (-not ($ghRaw -is [string])) { return $fail }
                $ghAppr = ([string]$ghRaw).Trim().ToLowerInvariant()
            }
            if ($intRev -cne 'required') { return $fail }
            if (($ghAppr -cne 'required') -and ($ghAppr -cne 'not_required')) { return $fail }
            return [pscustomobject]@{ ok = $true; reason = ''; profile = 'default'; internal_reviewer = $intRev; github_approval = $ghAppr }
        }
        if (($profName.Length -gt 64) -or ($profName -cnotmatch '\A[A-Za-z0-9._-]+\z')) {
            return $fail
        }
        $profiles = Get-DeliveryValue $resolved 'profiles' $null
        if ($null -eq $profiles) { return $fail }
        $entry = $null
        $found = $false
        try {
            if ($profiles -is [System.Collections.IDictionary]) {
                foreach ($k in @($profiles.Keys)) {
                    if (([string]$k) -ceq $profName) { $entry = $profiles[$k]; $found = $true; break }
                }
            }
            else {
                foreach ($p in @($profiles.PSObject.Properties)) {
                    if ([string]$p.Name -ceq $profName) { $entry = $p.Value; $found = $true; break }
                }
            }
        }
        catch { return $fail }
        if (-not $found) { return $fail }
        $prev = Get-DeliveryValue $entry 'review' $null
        if ($null -eq $prev) { return $fail }
        $pIntRaw = Get-DeliveryValue $prev 'internal_reviewer' $null
        $pGhRaw = Get-DeliveryValue $prev 'github_approval' $null
        if ((-not ($pIntRaw -is [string])) -or (-not ($pGhRaw -is [string]))) { return $fail }
        $pInt = ([string]$pIntRaw).Trim().ToLowerInvariant()
        $pGh = ([string]$pGhRaw).Trim().ToLowerInvariant()
        if ($pInt -cne 'required') { return $fail }
        if (($pGh -cne 'required') -and ($pGh -cne 'not_required')) { return $fail }
        return [pscustomobject]@{ ok = $true; reason = ''; profile = $profName; internal_reviewer = $pInt; github_approval = $pGh }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'policy-invalid'; profile = ''; internal_reviewer = ''; github_approval = '' }
    }
}

function Test-GHSecretFreeLocal {
    param([string]$Value = '')
    try {
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        $low = ([string]$v).ToLowerInvariant()
        foreach ($sig in @('ghp_', 'gho_', 'ghu_', 'github_pat_', 'xox-', 'gh_token', 'github_token', 'private key')) {
            if ($low.Contains($sig)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-GHInternalReview {
    # Solo-maintainer internal-agent review record shape check. A valid
    # record (approved, expected head SHA, distinct reviewer identity)
    # satisfies TECHNICAL readiness under the solo profile only, with no
    # cryptographic attestation required. It is quality-control evidence
    # only: never authenticated identity, an independent signature, human
    # approval, or GitHub approval. Origin/limits are recorded by the
    # caller in the readiness evidence (review_basis/review_detail).
    [CmdletBinding()]
    param($InternalReview = $null, [string]$ExpectedHeadSha = '')
    try {
        $pending = [pscustomobject]@{ ok = $false; reason = 'internal-review-pending' }
        $invalid = [pscustomobject]@{ ok = $false; reason = 'internal-review-invalid' }
        if ($null -eq $InternalReview) { return $pending }
        if (($InternalReview -is [string]) -or ($InternalReview -is [System.Collections.IList]) -or ($InternalReview -is [ValueType])) {
            return $invalid
        }
        $appr = Get-DeliveryValue $InternalReview 'approved' $null
        if ($null -eq $appr) { return $pending }
        if (-not ($appr -is [bool])) { return $invalid }
        if (-not [bool]$appr) { return $pending }
        $shaRaw = Get-DeliveryValue $InternalReview 'head_sha' $null
        if (-not ($shaRaw -is [string])) { return $invalid }
        $sha = ([string]$shaRaw).Trim().ToLowerInvariant()
        if (($sha.Length -ne 40) -or ($sha -cnotmatch '\A[0-9a-f]{40}\z')) { return $invalid }
        $exp = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        if ($sha -cne $exp) {
            return [pscustomobject]@{ ok = $false; reason = 'internal-review-sha-mismatch' }
        }
        $revRaw = Get-DeliveryValue $InternalReview 'reviewer_identity' $null
        if (-not ($revRaw -is [string])) { return $invalid }
        $revId = ([string]$revRaw).Trim()
        if ([string]::IsNullOrWhiteSpace($revId) -or ($revId.Length -gt 128)) { return $invalid }
        if ($revId -cnotmatch '\A[A-Za-z0-9._:-]+\z') { return $invalid }
        if (-not (Test-GHSecretFreeLocal -Value $revId)) { return $invalid }
        $authRaw = Get-DeliveryValue $InternalReview 'author_identity' $null
        if (-not ($authRaw -is [string])) { return $invalid }
        $authId = ([string]$authRaw).Trim()
        if ([string]::IsNullOrWhiteSpace($authId) -or ($authId.Length -gt 128)) { return $invalid }
        if ($authId -cnotmatch '\A[A-Za-z0-9._:-]+\z') { return $invalid }
        if (-not (Test-GHSecretFreeLocal -Value $authId)) { return $invalid }
        if ($authId.ToLowerInvariant() -ceq $revId.ToLowerInvariant()) {
            return [pscustomobject]@{ ok = $false; reason = 'internal-self-review' }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-review-invalid' }
    }
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

# ---------- ORFS-CONT-F3-PURE: GitHub readiness (pure, data-only) ----------

function Test-GHRepoSyntax {
    param([string]$Repository = '')
    try {
        $v = ([string]$Repository).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 200) { return $false }
        if ($v -cmatch '[^A-Za-z0-9._/-]') { return $false }
        $parts = $v.Split('/')
        if (@($parts).Count -ne 2) { return $false }
        foreach ($p in @($parts)) {
            if ([string]::IsNullOrWhiteSpace([string]$p)) { return $false }
            if (([string]$p) -cmatch '[^A-Za-z0-9._-]') { return $false }
            if ([string]$p -cmatch '^\.') { return $false }
            if ([string]$p -cmatch '\.$') { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-GHSha40 {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ($v.Length -ne 40) { return $false }
        return ($v -cmatch '^[0-9a-fA-F]{40}$')
    }
    catch { return $false }
}

function Test-GHStrictPositiveInt {
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        return ([long]$Value -ge 1)
    }
    catch { return $false }
}

function Test-GHStrictMaxAge {
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        $n = [long]$Value
        return (($n -ge 1) -and ($n -le 3600))
    }
    catch { return $false }
}

function Test-GHReadinessName {    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim().ToUpperInvariant()
        foreach ($k in @('READY_FOR_RESUME', 'CHECKS_PENDING', 'REVIEW_PENDING', 'REPAIR_REQUIRED', 'INCONCLUSIVE', 'STALE', 'TERMINAL')) {
            if ($v -ceq $k) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function New-GHReadinessEnvelope {
    param(
        [bool]$Ok = $false,
        $Readiness = 'INCONCLUSIVE',
        $Reasons = @(),
        $Repository = '',
        $PrNumber = 0,
        $ExpectedHeadSha = '',
        $ObservedHeadSha = '',
        $ReviewBasis = '',
        $ReviewDetail = ''
    )
    try {
        $basisOut = ''
        try {
            $b = ([string]$ReviewBasis).Trim().ToLowerInvariant()
            if (($b -ceq 'github-approval') -or ($b -ceq 'internal-agent')) { $basisOut = $b }
        }
        catch { $basisOut = '' }
        $detailOut = ''
        try {
            $d = ([string]$ReviewDetail).Trim()
            if ($d.Length -gt 0) {
                $d = $d -replace '[\x00-\x1F\x7F]', ''
                $d = $d.Trim()
                if ($d.Length -gt 200) { $d = $d.Substring(0, 200) }
                if ($d.Length -gt 0) { $detailOut = $d }
            }
        }
        catch { $detailOut = '' }
        if (($basisOut -ceq '') -and ($detailOut -cne '')) { $detailOut = '' }
        $why = New-Object System.Collections.ArrayList
        if ($null -ne $Reasons) {
            foreach ($rs in @($Reasons)) {
                if (@($why).Count -ge 120) { break }
                if (-not ($rs -is [string])) { continue }
                $t = [string]$rs
                if ($t.Length -eq 0 -or $t.Length -gt 200) { continue }
                if ($t -match '[\x00-\x1F\x7F]') { continue }
                [void]$why.Add($t)
            }
        }
        $pn = 0
        try { if (Test-GHStrictPositiveInt -Value $PrNumber) { $pn = [long]$PrNumber } } catch { $pn = 0 }
        $repoOut = ''
        try {
            if (($Repository -is [string]) -and (Test-GHRepoSyntax -Repository ([string]$Repository))) {
                $repoOut = ([string]$Repository).Trim().ToLowerInvariant()
            }
        }
        catch { $repoOut = '' }
        $expOut = ''
        try {
            if (Test-GHSha40 -Value $ExpectedHeadSha) {
                $expOut = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
            }
        }
        catch { $expOut = '' }
        $obsOut = ''
        try {
            if (($null -ne $ObservedHeadSha) -and (($ObservedHeadSha -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$ObservedHeadSha)))) {
                if (Test-GHSha40 -Value $ObservedHeadSha) {
                    $obsOut = ([string]$ObservedHeadSha).Trim().ToLowerInvariant()
                }
            }
        }
        catch { $obsOut = '' }
        $readyOut = 'INCONCLUSIVE'
        $okOut = $false
        try {
            if (($Readiness -is [string]) -and (Test-GHReadinessName -Value ([string]$Readiness))) {
                $readyOut = ([string]$Readiness).Trim().ToUpperInvariant()
                $okOut = ([bool]$Ok -and ($readyOut -ceq 'READY_FOR_RESUME'))
            }
        }
        catch { $readyOut = 'INCONCLUSIVE'; $okOut = $false }
        return [pscustomobject]@{
            ok                = $okOut
            readiness         = $readyOut
            reasons           = [string[]]$why.ToArray()
            repository        = $repoOut
            pr_number         = $pn
            expected_head_sha = $expOut
            observed_head_sha = $obsOut
            review_basis      = $basisOut
            review_detail     = $detailOut
            snapshot_only     = $true
            grants_authority  = $false
            done_approved     = $false
            merge_authority   = $false
            resume_authorized = $false
            kernel_mutated    = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; readiness = 'INCONCLUSIVE'; reasons = @('internal-error')
            repository = ''; pr_number = 0; expected_head_sha = ''; observed_head_sha = ''
            review_basis = ''; review_detail = ''
            snapshot_only = $true; grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $false; kernel_mutated = $false
        }
    }
}

function Convert-GHToUtc {
    param($Value)
    try {
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) {
            try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
        }
        if ($Value -is [string]) {
            $s = ([string]$Value).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            $dt = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            try {
                if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) { return $dt }
            }
            catch { return $null }
            return $null
        }
        return $null
    }
    catch { return $null }
}

function Get-OrchestrationGitHubReadiness {
    [CmdletBinding()]
    param(
        $Repository = '',
        $PrNumber = $null,
        $ExpectedHeadSha = '',
        $Snapshot = $null,
        $Policy = $null,
        $NowUtc = $null,
        $MaxAgeSeconds = 300,
        $DeliveryProfile = '',
        $InternalReview = $null
    )
    try {
        if (-not (Test-GHStrictMaxAge -Value $MaxAgeSeconds)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-max-age') -Repository '' -PrNumber 0 -ExpectedHeadSha '' -ObservedHeadSha '')
        }
        $maxAge = [long]$MaxAgeSeconds
        $repoCanon = ''
        if (($Repository -is [string]) -and (Test-GHRepoSyntax -Repository ([string]$Repository))) {
            $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        }
        else {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-repository') -Repository '' -PrNumber 0 -ExpectedHeadSha '' -ObservedHeadSha '')
        }
        if (-not (Test-GHStrictPositiveInt -Value $PrNumber)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-pr-number') -Repository $repoCanon -PrNumber 0 -ExpectedHeadSha '' -ObservedHeadSha '')
        }
        $prNum = [long]$PrNumber
        $expCanon = ''
        if (Test-GHSha40 -Value $ExpectedHeadSha) {
            $expCanon = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        }
        else {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-expected-sha') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha '' -ObservedHeadSha '')
        }
        $resolved = Get-OrchestrationDeliveryPolicy $Policy
        if (($null -eq $resolved) -or (-not (Test-OrchestrationDeliveryPolicyShape $resolved))) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('policy-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $effReview = Get-OrchestrationDeliveryEffectiveReview -Policy $resolved -DeliveryProfile $DeliveryProfile
        if (($null -eq $effReview) -or (-not [bool]$effReview.ok)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('policy-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $ghApprovalRequired = ([string]$effReview.github_approval -ceq 'required')
        $soloInternalGate = ((-not $ghApprovalRequired) -and ([string]$effReview.internal_reviewer -ceq 'required'))
        $required = Get-OrchestrationDeliveryRequiredChecks $resolved
        if ($null -eq $required) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('policy-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        if ($null -eq $Snapshot) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $now = $null
        if ($null -eq $NowUtc) {
            $now = [datetime]::UtcNow
        }
        elseif ($NowUtc -is [datetime]) {
            try { $now = ([datetime]$NowUtc).ToUniversalTime() } catch { $now = $null }
            if ($null -eq $now) {
                return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-now') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
            }
        }
        elseif ($NowUtc -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$NowUtc)) {
                $now = [datetime]::UtcNow
            }
            else {
                $now = Convert-GHToUtc -Value ([string]$NowUtc)
                if ($null -eq $now) {
                    return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-now') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
                }
            }
        }
        else {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-now') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapRepoRaw = Get-DeliveryValue $Snapshot 'repository' $null
        if (-not ($snapRepoRaw -is [string]) -or (-not (Test-GHRepoSyntax -Repository ([string]$snapRepoRaw)))) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapRepo = ([string]$snapRepoRaw).Trim().ToLowerInvariant()
        if ($snapRepo -cne $repoCanon) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('repository-mismatch') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapPr = Get-DeliveryValue $Snapshot 'pr_number' $null
        if ((-not (Test-GHStrictPositiveInt -Value $snapPr)) -or ([long]$snapPr -ne $prNum)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('pr-number-mismatch') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapHeadRaw = Get-DeliveryValue $Snapshot 'head_sha' $null
        if (-not (Test-GHSha40 -Value $snapHeadRaw)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapHead = ([string]$snapHeadRaw).Trim().ToLowerInvariant()
        $snapCommitRaw = Get-DeliveryValue $Snapshot 'commit_sha' $null
        if (-not (Test-GHSha40 -Value $snapCommitRaw)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha '')
        }
        $snapCommit = ([string]$snapCommitRaw).Trim().ToLowerInvariant()
        if ($snapHead -cne $expCanon) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'STALE' -Reasons @('head-mismatch') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if ($snapCommit -cne $expCanon) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'STALE' -Reasons @('commit-mismatch') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $obsRaw = Get-DeliveryValue $Snapshot 'observed_at' $null
        if (-not ($obsRaw -is [string]) -or [string]::IsNullOrWhiteSpace([string]$obsRaw)) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('snapshot-time-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $obs = Convert-GHToUtc -Value ([string]$obsRaw)
        if ($null -eq $obs) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('snapshot-time-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if ($obs -gt $now) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'STALE' -Reasons @('snapshot-future') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        try {
            $age = ($now - $obs).TotalSeconds
            if ($age -gt [double]$maxAge) {
                return (New-GHReadinessEnvelope -Ok $false -Readiness 'STALE' -Reasons @('snapshot-stale') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
            }
        }
        catch {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('snapshot-time-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $prStateRaw = Get-DeliveryValue $Snapshot 'pr_state' $null
        if (-not ($prStateRaw -is [string])) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $prState = ([string]$prStateRaw).Trim().ToUpperInvariant()
        if (($prState -cne 'OPEN') -and ($prState -cne 'CLOSED') -and ($prState -cne 'MERGED')) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if (($prState -ceq 'CLOSED') -or ($prState -ceq 'MERGED')) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'TERMINAL' -Reasons @('pr-terminal') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $mergeRaw = Get-DeliveryValue $Snapshot 'mergeable' $null
        if (-not ($mergeRaw -is [string])) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $merge = ([string]$mergeRaw).Trim().ToUpperInvariant()
        if (($merge -cne 'MERGEABLE') -and ($merge -cne 'CONFLICTING') -and ($merge -cne 'UNKNOWN')) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $revRaw = Get-DeliveryValue $Snapshot 'review_decision' $null
        if (-not ($revRaw -is [string])) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $rev = ([string]$revRaw).Trim().ToUpperInvariant()
        if (($rev -cne 'APPROVED') -and ($rev -cne 'CHANGES_REQUESTED') -and ($rev -cne 'REVIEW_REQUIRED') -and ($rev -cne 'UNKNOWN')) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $ccRaw = Get-DeliveryValue $Snapshot 'checks_complete' $null
        if (-not ($ccRaw -is [bool])) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('invalid-snapshot') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $checksRaw = $null
        try {
            if ($Snapshot -is [System.Collections.IDictionary]) {
                if ($Snapshot.Contains('checks')) { $checksRaw = $Snapshot['checks'] }
            }
            else {
                $checksRaw = $Snapshot.checks
            }
        }
        catch { $checksRaw = $null }
        if (($null -eq $checksRaw) -or (-not ($checksRaw -is [System.Collections.IList]))) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('checks-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $checkList = @($checksRaw)
        if (@($checkList).Count -gt 100) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('checks-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        $requiredKeys = @{}
        $requiredCanon = @{}
        foreach ($rn in @($required)) {
            $rns = [string]$rn
            $rk = $rns.ToLowerInvariant()
            if (-not $requiredKeys.ContainsKey($rk)) {
                $requiredKeys[$rk] = $true
                $requiredCanon[$rk] = $rns
            }
        }
        $seen = @{}
        $repFail = New-Object System.Collections.ArrayList
        $incFail = New-Object System.Collections.ArrayList
        $pendChecks = New-Object System.Collections.ArrayList
        $pendReview = New-Object System.Collections.ArrayList
        if ($merge -ceq 'CONFLICTING') { [void]$repFail.Add('merge-conflicting') }
        elseif ($merge -ceq 'UNKNOWN') { [void]$incFail.Add('mergeable-unknown') }
        foreach ($c in @($checkList)) {
            $nRaw = Get-DeliveryValue $c 'name' $null
            if ((-not ($nRaw -is [string])) -or [string]::IsNullOrWhiteSpace([string]$nRaw)) {
                return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('checks-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
            }
            $key = ([string]$nRaw).Trim().ToLowerInvariant()
            if (-not $requiredKeys.ContainsKey($key)) { continue }
            $canon = [string]$requiredCanon[$key]
            if ($seen.ContainsKey($key)) {
                [void]$incFail.Add(('check-duplicate:' + $canon))
                continue
            }
            $seen[$key] = $true
            $chRaw = Get-DeliveryValue $c 'head_sha' $null
            if (-not (Test-GHSha40 -Value $chRaw)) {
                [void]$incFail.Add(('check-inconclusive:' + $canon))
                continue
            }
            $chLow = ([string]$chRaw).Trim().ToLowerInvariant()
            if ($chLow -cne $expCanon) {
                [void]$incFail.Add(('check-sha-mismatch:' + $canon))
                continue
            }
            $stRaw = Get-DeliveryValue $c 'status' $null
            if (-not ($stRaw -is [string])) {
                return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('checks-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
            }
            $st = ([string]$stRaw).Trim().ToUpperInvariant()
            if (($st -cne 'QUEUED') -and ($st -cne 'IN_PROGRESS') -and ($st -cne 'COMPLETED')) {
                return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('checks-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
            }
            $con = Get-DeliveryValue $c 'conclusion' $null
            if ($st -cne 'COMPLETED') {
                [void]$pendChecks.Add(('check-pending:' + $canon))
                continue
            }
            if (($null -eq $con) -or (-not ($con -is [string]))) {
                [void]$incFail.Add(('check-inconclusive:' + $canon))
                continue
            }
            if ([string]$con -cne 'success') {
                [void]$repFail.Add(('check-failed:' + $canon))
                continue
            }
        }
        foreach ($name in @($required)) {
            $rk = ([string]$name).Trim().ToLowerInvariant()
            if (-not $seen.ContainsKey($rk)) {
                [void]$pendChecks.Add(('check-missing:' + [string]$requiredCanon[$rk]))
            }
        }
        if (-not [bool]$ccRaw) { [void]$pendChecks.Add('checks-incomplete') }
        if ($rev -ceq 'CHANGES_REQUESTED') { [void]$repFail.Add('changes-requested') }
        elseif ($ghApprovalRequired) {
            if ($rev -ceq 'APPROVED') { }
            else { [void]$pendReview.Add('review-required') }
        }
        else {
            # Solo-maintainer regime: GitHub approval waived (APPROVED,
            # REVIEW_REQUIRED and UNKNOWN all pass this leg); an explicit
            # CHANGES_REQUESTED still repairs above. No internal gate here
            # replaces the waived external gate until a trusted issuer
            # lands (see solo hold below).
        }
        if ($soloInternalGate) {
            # Solo-maintainer regime: no attestation required. A valid
            # internal-agent review record on the expected head SHA
            # satisfies the solo review leg as quality-control evidence
            # only (recorded in review_basis/review_detail on READY, never
            # an authenticated identity, independent signature, human
            # approval, or GitHub approval). Missing/invalid/mismatched
            # records still hold or fail closed below, exactly like the
            # pre-profile gates.
            $soloReviewOk = $false
            $soloReviewer = ''
            $ir = Test-GHInternalReview -InternalReview $InternalReview -ExpectedHeadSha $expCanon
            if (-not [bool]$ir.ok) {
                $irr = [string]$ir.reason
                if ($irr -ceq 'internal-review-invalid') {
                    return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('internal-review-invalid') -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
                }
                [void]$pendReview.Add($irr)
            }
            else {
                $soloReviewOk = $true
                try { $soloReviewer = ([string](Get-DeliveryValue $InternalReview 'reviewer_identity' '')).Trim() } catch { $soloReviewer = '' }
            }
        }
        if (@($incFail).Count -gt 0) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons ([string[]]@($incFail)) -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if (@($repFail).Count -gt 0) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'REPAIR_REQUIRED' -Reasons ([string[]]@($repFail)) -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if (@($pendChecks).Count -gt 0) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'CHECKS_PENDING' -Reasons ([string[]]@($pendChecks)) -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if (@($pendReview).Count -gt 0) {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'REVIEW_PENDING' -Reasons ([string[]]@($pendReview)) -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead)
        }
        if ($soloInternalGate) {
            $shortHead = $expCanon
            try { if ($expCanon.Length -ge 8) { $shortHead = $expCanon.Substring(0, 8) } } catch { $shortHead = $expCanon }
            $det = ('internal-agent reviewer=' + [string]$soloReviewer + '; qc-only; no auth-identity/signature/human/GitHub approval; no attestation; head=' + [string]$shortHead)
            if ($det.Length -gt 200) { $det = $det.Substring(0, 200) }
            return (New-GHReadinessEnvelope -Ok $true -Readiness 'READY_FOR_RESUME' -Reasons @() -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead -ReviewBasis 'internal-agent' -ReviewDetail $det)
        }
        return (New-GHReadinessEnvelope -Ok $true -Readiness 'READY_FOR_RESUME' -Reasons @() -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -ObservedHeadSha $snapHead -ReviewBasis 'github-approval' -ReviewDetail 'github approval observed on expected head; internal reviewer required by policy')
    }
    catch {
        try {
            return (New-GHReadinessEnvelope -Ok $false -Readiness 'INCONCLUSIVE' -Reasons @('evaluation-failed') -Repository '' -PrNumber 0 -ExpectedHeadSha '' -ObservedHeadSha '')
        }
        catch { return $null }
    }
}
