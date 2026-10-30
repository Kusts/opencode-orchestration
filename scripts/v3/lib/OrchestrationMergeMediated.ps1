<#!
.SYNOPSIS
    ETAPA 6 (6B) mediated merge decision: snapshot-bound, intent-gated, idempotent.
.DESCRIPTION
    Dot-sourceable library (no execution on load). Single entry point
    Invoke-OrchestrationMergeMediated decides a GitHub PR merge WITHOUT
    performing any network/gh/merge effect: execution stays external via an
    injected $Executor seam. Fail-closed, PS 5.1 compatible, ASCII-only.
    Never throws on operational paths: every failure returns an object with
    outcome + reasons (+ null receipt unless stated). Never emits DONE or
    verified_pass. Receipts carry identifiers only (no secrets) and always
    report enforcement SOFT_ADVISORY.

    Reuse: OrchestrationDelivery.ps1 (Test-OrchestrationMergeEligibility,
    Get-OrchestrationGitHubReadiness), OrchestrationDeliveryGateAdapter.ps1
    (Invoke-OcDeliveryGate / Invoke-OcPinnedDeliveryGate),
    OrchestrationExternalActionBoundary.ps1 (New-OcExternalIntent),
    AgentProfileBundleConsumer.ps1 (Test-ObjectiveBundlePin).

    Policy-shape fallback (documented, fail-closed): the shared eligibility
    and readiness functions require the full registry shape
    (deletion_protected, terminal_states, non-empty security_reviewer_on).
    A caller-supplied minimal policy that carries the canonical
    required_checks but omits registry-only shape metadata would otherwise
    be unevaluable (policy-invalid) even when every substantive gate is
    satisfiable. When a shared function refuses SOLELY for policy shape
    (reasons subset of {policy-invalid, policy-unavailable}) AND the policy
    still declares schema_version 1, auto_merge.allowed true and a
    resolvable required_checks set, this lib re-evaluates the SAME
    substantive gates locally (required-check success binding with FIX2/FIX3
    duplicate/inconclusive semantics, reviewer, conditional security,
    unresolved P1, risk band; snapshot binding, head/commit match,
    freshness, pr_state, mergeable, review_decision, checks evaluation)
    using the shared reason vocabulary. No evaluated gate is relaxed;
    anything else stays REMEDIATE/RECONCILE. With a canonical policy the
    shared path governs and the mirror never runs.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDeliveryGateAdapter.ps1')

function Get-MMValue {
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

function Test-MMRepo {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 200) { return $false }
        if ($v -cmatch '[^A-Za-z0-9._/-]') { return $false }
        $parts = $v.Split('/')
        if (@($parts).Count -ne 2) { return $false }
        foreach ($p in @($parts)) {
            if ([string]::IsNullOrWhiteSpace([string]$p)) { return $false }
            if (([string]$p) -cmatch '[^A-Za-z0-9._-]') { return $false }
            if (([string]$p) -cmatch '^\.') { return $false }
            if (([string]$p) -cmatch '\.$') { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-MMSha40 {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ($v.Length -ne 40) { return $false }
        return ($v -cmatch '^[0-9a-fA-F]{40}$')
    }
    catch { return $false }
}

function Test-MMStrictPositiveInt {
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

function Test-MMStrictNonNegativeInt {
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        return ([long]$Value -ge 0)
    }
    catch { return $false }
}

function Test-MMSecretFree {
    param($Value)
    try {
        if ($null -eq $Value) { return $true }
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        $low = $v.ToLowerInvariant()
        foreach ($sig in @('gho_', 'ghp_', 'ghu_', 'github_pat_', 'xox-', 'gh_token', 'github_token', 'private key', 'token', 'secret', 'passwd', 'password', 'api_key', 'apikey', 'bearer', 'sk-')) {
            if ($low.Contains($sig)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Convert-MMToUtc {
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

function Get-MMPolicyDigest {
    param($Policy)
    try {
        if ($null -eq $Policy) { return '' }
        $pj = ($Policy | ConvertTo-Json -Depth 10 -Compress)
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$pj)
        $h = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $h.ComputeHash($bytes)
            return ((($hash | ForEach-Object { $_.ToString('x2') }) -join ''))
        }
        finally { try { $h.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-MMDerivedChecks {
    param($Snapshot)
    try {
        $out = New-Object System.Collections.ArrayList
        $raw = Get-MMValue $Snapshot 'checks' $null
        if (($null -eq $raw) -or (-not ($raw -is [System.Collections.IList]))) { return @() }
        foreach ($c in @($raw)) {
            $n = [string](Get-MMValue $c 'name' '')
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $con = Get-MMValue $c 'conclusion' $null
            [void]$out.Add(@{ name = $n; conclusion = $con })
        }
        return @($out.ToArray())
    }
    catch { return @() }
}

function New-MMResult {
    param([string]$Outcome = 'RECONCILE', $Reasons = @(), $Receipt = $null)
    try {
        $r = New-Object System.Collections.ArrayList
        if ($null -ne $Reasons) {
            foreach ($x in @($Reasons)) {
                if ($x -is [string]) {
                    $t = ([string]$x).Trim()
                    if (($t.Length -gt 0) -and ($t.Length -le 200) -and (-not ($t -match '[\x00-\x1F\x7F]'))) {
                        [void]$r.Add($t)
                    }
                }
            }
        }
        if (@($r).Count -eq 0) { [void]$r.Add('unspecified') }
        return [pscustomobject]@{ outcome = $Outcome; reasons = [string[]]$r.ToArray(); receipt = $Receipt }
    }
    catch {
        return [pscustomobject]@{ outcome = 'RECONCILE'; reasons = @('internal-error'); receipt = $null }
    }
}

function Set-MMStore {
    param($Store, [string]$Key = '', $Result = $null)
    try {
        if (($null -eq $Store) -or ($null -eq $Result)) { return }
        if (-not ($Store -is [System.Collections.IDictionary])) { return }
        if ([string]::IsNullOrWhiteSpace($Key)) { return }
        $Store[$Key] = $Result
    }
    catch { }
}

function Test-MMShapeFallbackAllowed {
    param($Policy, $Reasons)
    try {
        if ($null -eq $Reasons) { return $false }
        $list = @($Reasons)
        if (@($list).Count -eq 0) { return $false }
        foreach ($x in @($list)) {
            if (([string]$x -cne 'policy-invalid') -and ([string]$x -cne 'policy-unavailable')) { return $false }
        }
        if ($null -eq $Policy) { return $false }
        $sv = Get-MMValue $Policy 'schema_version' $null
        if (-not ($sv -is [int] -or $sv -is [long] -or $sv -is [short] -or $sv -is [byte])) { return $false }
        if ([long]$sv -ne 1) { return $false }
        $auto = Get-MMValue $Policy 'auto_merge' $null
        if ($null -eq $auto) { return $false }
        $allowed = Get-MMValue $auto 'allowed' $null
        if (($allowed -isnot [bool]) -or ($allowed -ne $true)) { return $false }
        $req = $null
        try { $req = Get-OrchestrationDeliveryRequiredChecks $Policy } catch { $req = $null }
        if ($null -eq $req) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-MMMirrorEligibility {
    param($RequiredChecks, $DerivedChecks, $ReviewerApproved, $SecurityRequired, $SecurityApproved, $UnresolvedP1, $Risk)
    try {
        $reasons = New-Object System.Collections.ArrayList
        $reqKeys = @{}
        $reqCanon = @{}
        foreach ($rn in @($RequiredChecks)) {
            $rns = [string]$rn
            if ([string]::IsNullOrWhiteSpace($rns)) { continue }
            $rk = $rns.ToLowerInvariant()
            if (-not $reqKeys.ContainsKey($rk)) {
                $reqKeys[$rk] = $true
                $reqCanon[$rk] = $rns
            }
        }
        $byName = @{}
        $inconclusive = @{}
        $dupKeys = @{}
        $dupNames = New-Object System.Collections.ArrayList
        foreach ($c in @($DerivedChecks)) {
            $n = [string](Get-MMValue $c 'name' '')
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $key = $n.ToLowerInvariant()
            if (-not $reqKeys.ContainsKey($key)) { continue }
            $canon = [string]$reqCanon[$key]
            if ($byName.ContainsKey($key) -or $inconclusive.ContainsKey($key)) {
                if (-not $dupKeys.ContainsKey($key)) {
                    $dupKeys[$key] = $true
                    [void]$dupNames.Add($canon)
                }
                continue
            }
            $con = Get-MMValue $c 'conclusion' $null
            if ($con -is [string]) { $byName[$key] = [string]$con }
            else { $inconclusive[$key] = $canon }
        }
        foreach ($d in @($dupNames)) { [void]$reasons.Add(('check-duplicate:' + [string]$d)) }
        foreach ($name in @($RequiredChecks)) {
            $rk = ([string]$name).ToLowerInvariant()
            if ($dupKeys.ContainsKey($rk)) { continue }
            if (-not $byName.ContainsKey($rk)) {
                if ($inconclusive.ContainsKey($rk)) { [void]$reasons.Add(('check-inconclusive:' + [string]$reqCanon[$rk])) }
                else { [void]$reasons.Add(('check-missing:' + [string]$name)) }
            }
            elseif ([string]$byName[$rk] -cne 'success') { [void]$reasons.Add(('check-failed:' + [string]$name)) }
        }
        if (-not [bool]$ReviewerApproved) { [void]$reasons.Add('reviewer-pending') }
        if ([bool]$SecurityRequired -and (-not [bool]$SecurityApproved)) { [void]$reasons.Add('security-pending') }
        if ([long]$UnresolvedP1 -ne 0) { [void]$reasons.Add('unresolved-p1') }
        $riskNorm = ''
        if ($Risk -is [string]) { $riskNorm = ([string]$Risk).Trim().ToLowerInvariant() }
        if (($riskNorm -cne 'low') -and ($riskNorm -cne 'medium')) { [void]$reasons.Add('risk-too-high') }
        return [string[]]$reasons.ToArray()
    }
    catch { return @('evaluation-failed') }
}

function Get-MMMirrorReadiness {
    param($RepoCanon = '', [long]$PrNum = 0, $ExpCanon = '', $Snapshot = $null, $RequiredChecks = @(), $NowUtc = $null, [long]$MaxAge = 300)
    try {
        $obsOut = ''
        $fail = {
            param($rdy, $why)
            return [pscustomobject]@{ ok = $false; readiness = $rdy; reasons = [string[]]@($why); observed_head_sha = $obsOut }
        }
        if ($null -eq $Snapshot) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $now = Convert-MMToUtc -Value $NowUtc
        if ($null -eq $NowUtc) { $now = [datetime]::UtcNow }
        if ($null -eq $now) { return (& $fail 'INCONCLUSIVE' @('invalid-now')) }
        $snapRepoRaw = Get-MMValue $Snapshot 'repository' $null
        if ((-not ($snapRepoRaw -is [string])) -or (-not (Test-MMRepo -Value ([string]$snapRepoRaw)))) {
            return (& $fail 'INCONCLUSIVE' @('invalid-snapshot'))
        }
        if (([string]$snapRepoRaw).Trim().ToLowerInvariant() -cne $RepoCanon) {
            return (& $fail 'INCONCLUSIVE' @('repository-mismatch'))
        }
        $snapPr = Get-MMValue $Snapshot 'pr_number' $null
        if ((-not (Test-MMStrictPositiveInt -Value $snapPr)) -or ([long]$snapPr -ne $PrNum)) {
            return (& $fail 'INCONCLUSIVE' @('pr-number-mismatch'))
        }
        $snapHeadRaw = Get-MMValue $Snapshot 'head_sha' $null
        if (-not (Test-MMSha40 -Value $snapHeadRaw)) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $snapHead = ([string]$snapHeadRaw).Trim().ToLowerInvariant()
        $snapCommitRaw = Get-MMValue $Snapshot 'commit_sha' $null
        if (-not (Test-MMSha40 -Value $snapCommitRaw)) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $snapCommit = ([string]$snapCommitRaw).Trim().ToLowerInvariant()
        $obsOut = $snapHead
        if ($snapHead -cne $ExpCanon) { return (& $fail 'STALE' @('head-mismatch')) }
        if ($snapCommit -cne $ExpCanon) { return (& $fail 'STALE' @('commit-mismatch')) }
        $obsRaw = Get-MMValue $Snapshot 'observed_at' $null
        if (-not ($obsRaw -is [string]) -or [string]::IsNullOrWhiteSpace([string]$obsRaw)) {
            return (& $fail 'INCONCLUSIVE' @('snapshot-time-invalid'))
        }
        $obs = Convert-MMToUtc -Value ([string]$obsRaw)
        if ($null -eq $obs) { return (& $fail 'INCONCLUSIVE' @('snapshot-time-invalid')) }
        if ($obs -gt $now) { return (& $fail 'STALE' @('snapshot-future')) }
        try {
            $age = ($now - $obs).TotalSeconds
            if ($age -gt [double]$MaxAge) { return (& $fail 'STALE' @('snapshot-stale')) }
        }
        catch { return (& $fail 'INCONCLUSIVE' @('snapshot-time-invalid')) }
        $prStateRaw = Get-MMValue $Snapshot 'pr_state' $null
        if (-not ($prStateRaw -is [string])) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $prState = ([string]$prStateRaw).Trim().ToUpperInvariant()
        if (($prState -cne 'OPEN') -and ($prState -cne 'CLOSED') -and ($prState -cne 'MERGED')) {
            return (& $fail 'INCONCLUSIVE' @('invalid-snapshot'))
        }
        if (($prState -ceq 'CLOSED') -or ($prState -ceq 'MERGED')) {
            return (& $fail 'TERMINAL' @('pr-terminal'))
        }
        $mergeRaw = Get-MMValue $Snapshot 'mergeable' $null
        if (-not ($mergeRaw -is [string])) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $merge = ([string]$mergeRaw).Trim().ToUpperInvariant()
        $repFail = New-Object System.Collections.ArrayList
        $incFail = New-Object System.Collections.ArrayList
        $pendChecks = New-Object System.Collections.ArrayList
        $pendReview = New-Object System.Collections.ArrayList
        if ($merge -ceq 'CONFLICTING') { [void]$repFail.Add('merge-conflicting') }
        elseif ($merge -ceq 'UNKNOWN') { [void]$incFail.Add('mergeable-unknown') }
        elseif (($merge -cne 'MERGEABLE')) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $revRaw = Get-MMValue $Snapshot 'review_decision' $null
        if (-not ($revRaw -is [string])) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $rev = ([string]$revRaw).Trim().ToUpperInvariant()
        if ($rev -ceq 'CHANGES_REQUESTED') { [void]$repFail.Add('changes-requested') }
        elseif ($rev -ceq 'APPROVED') { }
        elseif (($rev -ceq 'REVIEW_REQUIRED') -or ($rev -ceq 'UNKNOWN')) { [void]$pendReview.Add('review-required') }
        else { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $ccRaw = Get-MMValue $Snapshot 'checks_complete' $null
        if (-not ($ccRaw -is [bool])) { return (& $fail 'INCONCLUSIVE' @('invalid-snapshot')) }
        $checksRaw = Get-MMValue $Snapshot 'checks' $null
        if (($null -eq $checksRaw) -or (-not ($checksRaw -is [System.Collections.IList]))) {
            return (& $fail 'INCONCLUSIVE' @('checks-invalid'))
        }
        $checkList = @($checksRaw)
        if (@($checkList).Count -gt 100) { return (& $fail 'INCONCLUSIVE' @('checks-invalid')) }
        $reqKeys = @{}
        $reqCanon = @{}
        foreach ($rn in @($RequiredChecks)) {
            $rns = [string]$rn
            $rk = $rns.ToLowerInvariant()
            if (-not $reqKeys.ContainsKey($rk)) {
                $reqKeys[$rk] = $true
                $reqCanon[$rk] = $rns
            }
        }
        $seen = @{}
        foreach ($c in @($checkList)) {
            $nRaw = Get-MMValue $c 'name' $null
            if ((-not ($nRaw -is [string])) -or [string]::IsNullOrWhiteSpace([string]$nRaw)) {
                return (& $fail 'INCONCLUSIVE' @('checks-invalid'))
            }
            $key = ([string]$nRaw).Trim().ToLowerInvariant()
            if (-not $reqKeys.ContainsKey($key)) { continue }
            $canon = [string]$reqCanon[$key]
            if ($seen.ContainsKey($key)) {
                [void]$incFail.Add(('check-duplicate:' + $canon))
                continue
            }
            $seen[$key] = $true
            $chRaw = Get-MMValue $c 'head_sha' $null
            if (-not (Test-MMSha40 -Value $chRaw)) {
                [void]$incFail.Add(('check-inconclusive:' + $canon))
                continue
            }
            if (([string]$chRaw).Trim().ToLowerInvariant() -cne $ExpCanon) {
                [void]$incFail.Add(('check-sha-mismatch:' + $canon))
                continue
            }
            $stRaw = Get-MMValue $c 'status' $null
            if (-not ($stRaw -is [string])) { return (& $fail 'INCONCLUSIVE' @('checks-invalid')) }
            $st = ([string]$stRaw).Trim().ToUpperInvariant()
            if (($st -cne 'QUEUED') -and ($st -cne 'IN_PROGRESS') -and ($st -cne 'COMPLETED')) {
                return (& $fail 'INCONCLUSIVE' @('checks-invalid'))
            }
            $con = Get-MMValue $c 'conclusion' $null
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
        foreach ($name in @($RequiredChecks)) {
            $rk = ([string]$name).Trim().ToLowerInvariant()
            if (-not $seen.ContainsKey($rk)) {
                [void]$pendChecks.Add(('check-missing:' + [string]$reqCanon[$rk]))
            }
        }
        if (-not [bool]$ccRaw) { [void]$pendChecks.Add('checks-incomplete') }
        if (@($incFail).Count -gt 0) { return (& $fail 'INCONCLUSIVE' ([string[]]@($incFail))) }
        if (@($repFail).Count -gt 0) { return (& $fail 'REPAIR_REQUIRED' ([string[]]@($repFail))) }
        if (@($pendChecks).Count -gt 0) { return (& $fail 'CHECKS_PENDING' ([string[]]@($pendChecks))) }
        if (@($pendReview).Count -gt 0) { return (& $fail 'REVIEW_PENDING' ([string[]]@($pendReview))) }
        return [pscustomobject]@{ ok = $true; readiness = 'READY_FOR_RESUME'; reasons = @(); observed_head_sha = $obsOut }
    }
    catch {
        return [pscustomobject]@{ ok = $false; readiness = 'INCONCLUSIVE'; reasons = @('evaluation-failed'); observed_head_sha = '' }
    }
}

function Invoke-OrchestrationMergeMediated {
    [CmdletBinding()]
    param(
        $Repository = '',
        $PrNumber = $null,
        $ExpectedHeadSha = '',
        $Snapshot = $null,
        $Policy = $null,
        $Authority = $null,
        $Risk = 'low',
        $ReviewerApproved = $null,
        $SecurityRequired = $null,
        $SecurityApproved = $null,
        $UnresolvedP1 = $null,
        $ReviewerIdentity = '',
        $HumanConfirmed = $null,
        $EvidenceChannel = '',
        $BundleLoad = $null,
        $Pin = $null,
        $PersistFn = $null,
        $Executor = $null,
        $VerifyFn = $null,
        $ReceiptStore = $null,
        $GoalId = '',
        $TaskId = '',
        [switch]$DryRun,
        $NowUtc = $null,
        $MaxAgeSeconds = 300
    )
    try {
        if (-not (Test-MMRepo -Value $Repository)) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('invalid-repository'))
        }
        $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        if (-not (Test-MMStrictPositiveInt -Value $PrNumber)) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('invalid-pr-number'))
        }
        $prNum = [long]$PrNumber
        if (-not (Test-MMSha40 -Value $ExpectedHeadSha)) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('invalid-expected-sha'))
        }
        $expCanon = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        if ((-not (Test-MMStrictNonNegativeInt -Value $MaxAgeSeconds)) -or ([long]$MaxAgeSeconds -lt 1) -or ([long]$MaxAgeSeconds -gt 3600)) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('invalid-max-age'))
        }
        $maxAge = [long]$MaxAgeSeconds

        $authRaw = Get-MMValue $Authority 'authorized' $null
        if ($authRaw -isnot [bool]) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('AUTHORITY_NOT_BOOLEAN'))
        }
        if ($authRaw -ne $true) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('AUTHORITY_NOT_AUTHORIZED'))
        }
        $prodAuth = Get-MMValue $Authority 'production_authorized' $null
        if ($prodAuth -isnot [bool]) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('PRODUCTION_AUTHORITY_NOT_BOOLEAN'))
        }
        if ($prodAuth -ne $true) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('PRODUCTION_NOT_AUTHORIZED'))
        }
        $author = [string](Get-MMValue $Authority 'author' '')
        $envName = [string](Get-MMValue $Authority 'environment' '')
        $grantsRaw = Get-MMValue $Authority 'grants' $null
        $grantsList = @()
        if ($null -ne $grantsRaw) {
            if ($grantsRaw -is [System.Collections.IList]) { $grantsList = @($grantsRaw) }
            else { $grantsList = @($grantsRaw) }
        }
        $grantsClean = New-Object System.Collections.ArrayList
        foreach ($g in @($grantsList)) {
            if (($null -eq $g) -or (-not ($g -is [string])) -or [string]::IsNullOrWhiteSpace([string]$g)) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
            }
            if (-not (Test-MMSecretFree -Value ([string]$g))) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_SECRET'))
            }
            [void]$grantsClean.Add(([string]$g).Trim())
        }
        if (@($grantsClean).Count -eq 0) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
        }
        if ([string]::IsNullOrWhiteSpace($envName)) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
        }
        if (-not (Test-MMSecretFree -Value $envName)) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_SECRET'))
        }
        if (-not (Test-MMSecretFree -Value $author)) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_SECRET'))
        }
        $scopesRaw = Get-MMValue $Authority 'credential_scope' $null
        if ($null -eq $scopesRaw) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_MISSING'))
        }
        $scopeItems = @()
        if ($scopesRaw -is [System.Collections.IList]) { $scopeItems = @($scopesRaw) }
        else { $scopeItems = @($scopesRaw) }
        if (@($scopeItems).Count -eq 0) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_MISSING'))
        }
        $scopesClean = New-Object System.Collections.ArrayList
        foreach ($s in @($scopeItems)) {
            if (($null -eq $s) -or (-not ($s -is [string])) -or [string]::IsNullOrWhiteSpace([string]$s)) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_INVALID'))
            }
            if (-not (Test-MMSecretFree -Value ([string]$s))) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_SECRET'))
            }
            [void]$scopesClean.Add(([string]$s).Trim())
        }
        $scopeOk = $false
        foreach ($s in @($scopesClean)) {
            $low = ([string]$s).ToLowerInvariant()
            if ($low.Contains('repo') -or $low.Contains('merge') -or $low.Contains('gh')) { $scopeOk = $true; break }
        }
        if (-not $scopeOk) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_INSUFFICIENT'))
        }
        $scopesArr = [string[]]$scopesClean.ToArray()
        $grantsArr = [string[]]$grantsClean.ToArray()

        if ($ReviewerApproved -isnot [bool]) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons @('invalid-argument', 'reviewer-not-boolean'))
        }
        if ($SecurityRequired -isnot [bool]) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons @('invalid-argument', 'security-required-not-boolean'))
        }
        if ($SecurityApproved -isnot [bool]) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons @('invalid-argument', 'security-approved-not-boolean'))
        }
        if ((-not (Test-MMStrictNonNegativeInt -Value $UnresolvedP1))) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons @('invalid-argument', 'unresolved-p1-invalid'))
        }
        $riskNorm = ''
        if ($Risk -is [string]) { $riskNorm = ([string]$Risk).Trim().ToLowerInvariant() }
        if ((($riskNorm -ceq 'medium') -or ($riskNorm -ceq 'high') -or ($riskNorm -ceq 'critical')) -and ($HumanConfirmed -isnot [bool])) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('HUMAN_CONFIRMATION_NOT_BOOLEAN'))
        }

        $pinProvided = (($null -ne $BundleLoad) -or ($null -ne $Pin))
        if ($pinProvided) {
            $pinStatus = 'BUNDLE_UNAVAILABLE'
            try {
                if ($null -ne (Get-Command Test-ObjectiveBundlePin -ErrorAction SilentlyContinue)) {
                    $pinStatus = [string](Test-ObjectiveBundlePin -Pin $Pin -BundleLoad $BundleLoad)
                }
            }
            catch { $pinStatus = 'BUNDLE_UNAVAILABLE' }
            if ([string]::IsNullOrWhiteSpace($pinStatus)) { $pinStatus = 'UNKNOWN' }
            if ($pinStatus -cne 'PIN_CURRENT') {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('STALE_BUNDLE_PIN:' + $pinStatus))
            }
        }

        $derived = Get-MMDerivedChecks -Snapshot $Snapshot
        $elig = $null
        try {
            if ($null -ne (Get-Command Test-OrchestrationMergeEligibility -ErrorAction SilentlyContinue)) {
                $elig = Test-OrchestrationMergeEligibility -Policy $Policy -Checks $derived -ReviewerApproved $ReviewerApproved -SecurityRequired $SecurityRequired -SecurityApproved $SecurityApproved -UnresolvedP1 $UnresolvedP1 -Risk $Risk
            }
        }
        catch { $elig = $null }
        if ($null -eq $elig) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons @('eligibility-unavailable'))
        }
        if (-not [bool](Get-MMValue $elig 'eligible' $false)) {
            $eraw = Get-MMValue $elig 'reasons' $null
            $elist = @()
            if ($null -ne $eraw) { $elist = @($eraw) }
            if ((Test-MMShapeFallbackAllowed -Policy $Policy -Reasons $elist)) {
                $reqFb = $null
                try { $reqFb = Get-OrchestrationDeliveryRequiredChecks $Policy } catch { $reqFb = $null }
                $mirrorReasons = Test-MMMirrorEligibility -RequiredChecks $reqFb -DerivedChecks $derived -ReviewerApproved $ReviewerApproved -SecurityRequired $SecurityRequired -SecurityApproved $SecurityApproved -UnresolvedP1 $UnresolvedP1 -Risk $Risk
                if (@($mirrorReasons).Count -gt 0) {
                    return (New-MMResult -Outcome 'REMEDIATE' -Reasons $mirrorReasons)
                }
            }
            else {
                return (New-MMResult -Outcome 'REMEDIATE' -Reasons $elist)
            }
        }

        $rdy = $null
        try {
            if ($null -ne (Get-Command Get-OrchestrationGitHubReadiness -ErrorAction SilentlyContinue)) {
                $rdy = Get-OrchestrationGitHubReadiness -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -Snapshot $Snapshot -Policy $Policy -NowUtc $NowUtc -MaxAgeSeconds $maxAge
            }
        }
        catch { $rdy = $null }
        if ($null -eq $rdy) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('readiness-unavailable'))
        }
        $rdyVal = ([string](Get-MMValue $rdy 'readiness' '')).Trim().ToUpperInvariant()
        $rdyOk = [bool](Get-MMValue $rdy 'ok' $false)
        $rdyRaw = Get-MMValue $rdy 'reasons' $null
        $rdyReasons = @()
        if ($null -ne $rdyRaw) { $rdyReasons = @($rdyRaw) }
        if (($rdyVal -ceq 'INCONCLUSIVE') -and (Test-MMShapeFallbackAllowed -Policy $Policy -Reasons $rdyReasons)) {
            $reqFb2 = $null
            try { $reqFb2 = Get-OrchestrationDeliveryRequiredChecks $Policy } catch { $reqFb2 = $null }
            $m = Get-MMMirrorReadiness -RepoCanon $repoCanon -PrNum $prNum -ExpCanon $expCanon -Snapshot $Snapshot -RequiredChecks $reqFb2 -NowUtc $NowUtc -MaxAge $maxAge
            $rdyVal = ([string](Get-MMValue $m 'readiness' 'INCONCLUSIVE')).Trim().ToUpperInvariant()
            $rdyOk = [bool](Get-MMValue $m 'ok' $false)
            $mrRaw = Get-MMValue $m 'reasons' $null
            $rdyReasons = @()
            if ($null -ne $mrRaw) { $rdyReasons = @($mrRaw) }
        }
        if (($rdyVal -ceq 'READY_FOR_RESUME') -and $rdyOk) { }
        elseif ($rdyVal -ceq 'CHECKS_PENDING') {
            return (New-MMResult -Outcome 'WAIT' -Reasons $rdyReasons)
        }
        elseif (($rdyVal -ceq 'REVIEW_PENDING') -or ($rdyVal -ceq 'REPAIR_REQUIRED')) {
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons $rdyReasons)
        }
        elseif ($rdyVal -ceq 'TERMINAL') {
            $snapState = ([string](Get-MMValue $Snapshot 'pr_state' '')).Trim().ToUpperInvariant()
            if ($DryRun -or ($snapState -cne 'MERGED')) {
                return (New-MMResult -Outcome 'REMEDIATE' -Reasons $rdyReasons)
            }
            if ($null -eq $VerifyFn) {
                return (New-MMResult -Outcome 'RECONCILE' -Reasons @('verify-unavailable'))
            }
            $vv = $null
            try { $vv = & $VerifyFn $repoCanon $prNum $expCanon }
            catch { return (New-MMResult -Outcome 'RECONCILE' -Reasons @('verify-exception')) }
            $vm = Get-MMValue $vv 'merged' $null
            $vs = [string](Get-MMValue $vv 'sha' '')
            if ((($vm -is [bool]) -and ($vm -eq $true)) -and (Test-MMSha40 -Value $vs) -and (([string]$vs).Trim().ToLowerInvariant() -ceq $expCanon)) {
                $goalId = [string]$GoalId
                $taskId = [string]$TaskId
                $recKey = ('merge|' + $repoCanon + '|' + [string]$prNum + '|' + $expCanon)
                $receipt = [pscustomobject]@{
                    action = 'merge'; target = ($repoCanon + '#' + [string]$prNum); sha = $expCanon
                    idempotency_key = $recKey; enforcement = 'SOFT_ADVISORY'; outcome = 'CONFIRMED'
                    dry_run = $false; reconciled = $true; goal = $goalId; task = $taskId
                    repository = $repoCanon; pr_number = $prNum; policy_digest = (Get-MMPolicyDigest -Policy $Policy)
                    author = $author; credential_scope = $scopesArr; grants = $grantsArr; environment = $envName
                }
                $res = New-MMResult -Outcome 'EXECUTED' -Reasons @('RECONCILED_REMOTE_MERGED') -Receipt $receipt
                Set-MMStore -Store $ReceiptStore -Key $recKey -Result $res
                return $res
            }
            return (New-MMResult -Outcome 'RECONCILE' -Reasons (@('verify-unconfirmed') + @($rdyReasons)))
        }
        else {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons $rdyReasons)
        }

        $idemKey = ('merge|' + $repoCanon + '|' + [string]$prNum + '|' + $expCanon)
        try {
            if (($null -ne $ReceiptStore) -and ($ReceiptStore -is [System.Collections.IDictionary]) -and ($ReceiptStore.Contains($idemKey))) {
                $prev = $ReceiptStore[$idemKey]
                $prevReceipt = Get-MMValue $prev 'receipt' $null
                if ($null -ne $prevReceipt) {
                    $prevOutcome = [string](Get-MMValue $prevReceipt 'outcome' '')
                    $prevDry = Get-MMValue $prevReceipt 'dry_run' $null
                    $prevIsDry = (($prevDry -is [bool]) -and ($prevDry -eq $true))
                    if (($prevOutcome -ceq 'CONFIRMED') -or $prevIsDry) {
                        # Dry-run nunca bloqueia execução real posterior: só faz replay
                        # quando a natureza (dry vs real) coincide, ou quando já há
                        # CONFIRMED real (dry-run após merge real relata o merge).
                        if ($DryRun -and $prevIsDry) {
                            return (New-MMResult -Outcome 'DRYRUN_OK' -Reasons @('IDEMPOTENT_REPLAY') -Receipt $prevReceipt)
                        }
                        if ((-not $DryRun) -and ($prevOutcome -ceq 'CONFIRMED') -and (-not $prevIsDry)) {
                            return (New-MMResult -Outcome 'EXECUTED' -Reasons @('IDEMPOTENT_REPLAY') -Receipt $prevReceipt)
                        }
                        if ($DryRun -and ($prevOutcome -ceq 'CONFIRMED') -and (-not $prevIsDry)) {
                            return (New-MMResult -Outcome 'EXECUTED' -Reasons @('IDEMPOTENT_REPLAY') -Receipt $prevReceipt)
                        }
                        # Real após dry-run: cai through para execução real.
                    }
                }
            }
        }
        catch { }

        $goalStr = [string]$GoalId
        $taskStr = [string]$TaskId
        $digest = Get-MMPolicyDigest -Policy $Policy
        $chan = [string]$EvidenceChannel
        $rid = [string]$ReviewerIdentity
        if (-not (Test-MMSecretFree -Value $rid)) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('CREDENTIAL_SCOPE_SECRET'))
        }
        $target = ($repoCanon + '#' + [string]$prNum)
        $payload = ('merge|' + $repoCanon + '|' + [string]$prNum + '|' + $expCanon)

        if ($DryRun) {
            $intent = $null
            try {
                $intent = New-OcExternalIntent -Goal $goalStr -Action 'merge' -Target $target -Sha $expCanon -Payload $payload -IdempotencyKey $idemKey -Grants $grantsArr -Environment $envName -PolicyDigest $digest
            }
            catch {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
            }
            if ($null -eq $PersistFn) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('PERSIST_FN_MISSING'))
            }
            $pok = $false
            try {
                $pout = @(& $PersistFn $intent)
                if (($pout.Count -eq 1) -and ($pout[0] -is [bool]) -and ($pout[0] -eq $true)) { $pok = $true }
            }
            catch { $pok = $false }
            if (-not $pok) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('PERSIST_FAILED'))
            }
            $dreceipt = [pscustomobject]@{
                dry_run = $true; enforcement = 'SOFT_ADVISORY'; idempotency_key = $idemKey
                goal = $goalStr; task = $taskStr; repository = $repoCanon; pr_number = $prNum
                sha = $expCanon; policy_digest = $digest; author = $author; outcome = 'DRYRUN'
            }
            $dres = New-MMResult -Outcome 'DRYRUN_OK' -Reasons @('DRYRUN_PERSISTED') -Receipt $dreceipt
            Set-MMStore -Store $ReceiptStore -Key $idemKey -Result $dres
            return $dres
        }

        $gateResult = $null
        try {
            if ($pinProvided) {
                if ($null -eq (Get-Command Invoke-OcPinnedDeliveryGate -ErrorAction SilentlyContinue)) {
                    return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('GATE_UNAVAILABLE'))
                }
                $gateResult = Invoke-OcPinnedDeliveryGate -BundleLoad $BundleLoad -Pin $Pin -Authority $Authority -Action 'merge' -Target $target -Sha $expCanon -PolicyDigest $digest -Risk $Risk -DeliveryChecks $derived -ReviewerIdentity $rid -HumanConfirmed $HumanConfirmed -EvidenceChannel $chan -PersistFn $PersistFn -Executor $Executor -Policy $Policy
            }
            else {
                if ($null -eq (Get-Command Invoke-OcDeliveryGate -ErrorAction SilentlyContinue)) {
                    return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('GATE_UNAVAILABLE'))
                }
                $gateResult = Invoke-OcDeliveryGate -Authority $Authority -Action 'merge' -Target $target -Sha $expCanon -PolicyDigest $digest -Risk $Risk -DeliveryChecks $derived -ReviewerIdentity $rid -HumanConfirmed $HumanConfirmed -EvidenceChannel $chan -PersistFn $PersistFn -Executor $Executor -Policy $Policy
            }
        }
        catch {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('GATE_EXCEPTION'))
        }
        if ($null -eq $gateResult) {
            return (New-MMResult -Outcome 'RECONCILE' -Reasons @('GATE_UNAVAILABLE'))
        }
        $gout = ([string](Get-MMValue $gateResult 'outcome' '')).Trim().ToUpperInvariant()
        $graw = Get-MMValue $gateResult 'reasons' $null
        $greasons = @()
        if ($null -ne $graw) { $greasons = @($graw) }
        $gdec = ([string](Get-MMValue $gateResult 'decision' '')).Trim().ToUpperInvariant()
        if ($gout -ceq 'EXECUTED') {
            if ($null -eq $VerifyFn) {
                return (New-MMResult -Outcome 'RECONCILE' -Reasons @('verify-unavailable'))
            }
            $ev = $null
            try { $ev = & $VerifyFn $repoCanon $prNum $expCanon }
            catch { return (New-MMResult -Outcome 'RECONCILE' -Reasons @('verify-exception')) }
            $em = Get-MMValue $ev 'merged' $null
            $es = [string](Get-MMValue $ev 'sha' '')
            if ((($em -is [bool]) -and ($em -eq $true)) -and (Test-MMSha40 -Value $es) -and (([string]$es).Trim().ToLowerInvariant() -ceq $expCanon)) {
                $creceipt = [pscustomobject]@{
                    action = 'merge'; target = $target; sha = $expCanon
                    idempotency_key = $idemKey; enforcement = 'SOFT_ADVISORY'; outcome = 'CONFIRMED'
                    dry_run = $false; reconciled = $false; goal = $goalStr; task = $taskStr
                    repository = $repoCanon; pr_number = $prNum; policy_digest = $digest
                    author = $author; credential_scope = $scopesArr; grants = $grantsArr; environment = $envName
                }
                $cres = New-MMResult -Outcome 'EXECUTED' -Reasons (@($greasons) + @('VERIFY_CONFIRMED')) -Receipt $creceipt
                Set-MMStore -Store $ReceiptStore -Key $idemKey -Result $cres
                return $cres
            }
            return (New-MMResult -Outcome 'RECONCILE' -Reasons (@('verify-unconfirmed') + @($greasons)))
        }
        if ($gout -ceq 'RECONCILE') { return (New-MMResult -Outcome 'RECONCILE' -Reasons $greasons) }
        if ($gout -ceq 'WAIT') { return (New-MMResult -Outcome 'WAIT' -Reasons $greasons) }
        if ($gout -ceq 'NEEDS_USER_AUTHORITY') { return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons $greasons) }
        if ($gout -ceq 'POLICY_BLOCKED') { return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons $greasons) }
        if ($gout -ceq 'REMEDIATE') {
            if ($gdec -ceq 'POLICY_BLOCKED') {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons $greasons)
            }
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons $greasons)
        }
        return (New-MMResult -Outcome 'RECONCILE' -Reasons @('gate-unknown-outcome'))
    }
    catch {
        return (New-MMResult -Outcome 'RECONCILE' -Reasons @('internal-error'))
    }
}
