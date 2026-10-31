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

    Canonical policy only: delivery-policy.json shape governs eligibility
    and readiness via the shared lib (OrchestrationDelivery.ps1). No mirror
    evaluation exists here; policy-invalid stays REMEDIATE/RECONCILE.

    Merge identity: pr_head_sha is the authorized HEAD (ExpectedHeadSha).
    merge_commit_sha is the integration SHA created by the merge commit
    (method 'merge' only; squash/rebase are POLICY_BLOCKED). Verification
    consults the remote PR (merged=true, repo/pr match required, valid
    merge_commit_sha distinct from the original HEAD) and requires method
    proof via api signal or commit structure (2 parents + linkage to HEAD).
    Both identifiers persist in the receipt. Expiration uses a trusted
    clock (ClockFn when provided, else UtcNow), never the Planner $NowUtc.
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

function Test-MMExactMergeScope {
    param([string]$RepoCanon = '', $ScopeItems = @())
    try {
        $want = ('github:merge:' + $RepoCanon).ToLowerInvariant()
        foreach ($s in @($ScopeItems)) {
            if (($null -eq $s) -or (-not ($s -is [string]))) { continue }
            $v = ([string]$s).Trim()
            if ($v -ceq $want) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-MMAuthorityExpired {
    param($Authority = $null, $NowUtc = $null)
    try {
        if ($null -eq $Authority) { return $false }
        $raw = $null
        $hasExpiry = $false
        try {
            if ($Authority -is [System.Collections.IDictionary]) {
                foreach ($k in @('expires_at', 'valid_until', 'expires', 'authority_expires_at')) {
                    if ($Authority.Contains($k)) { $raw = $Authority[$k]; $hasExpiry = $true; break }
                }
            }
            else {
                foreach ($k in @('expires_at', 'valid_until', 'expires', 'authority_expires_at')) {
                    $p = $Authority.PSObject.Properties[$k]
                    if ($null -ne $p) { $raw = $p.Value; $hasExpiry = $true; break }
                }
            }
        }
        catch { return $false }
        if (-not $hasExpiry) { return $false }
        if ($null -eq $raw) { return $true }
        if (($raw -is [bool]) -or ($raw -is [int]) -or ($raw -is [long])) { return $true }
        if (-not ($raw -is [string] -or $raw -is [datetime])) { return $true }
        if (($raw -is [string]) -and [string]::IsNullOrWhiteSpace([string]$raw)) { return $false }
        $exp = Convert-MMToUtc -Value $raw
        if ($null -eq $exp) { return $true }
        $now = Convert-MMToUtc -Value $NowUtc
        if ($null -eq $NowUtc) { $now = [datetime]::UtcNow }
        if ($null -eq $now) { return $true }
        return ($exp -le $now)
    }
    catch { return $true }
}

function Get-MMTrustedNow {
    param($ClockFn = $null)
    try {
        if (($null -ne $ClockFn) -and ($ClockFn -is [scriptblock])) {
            try {
                $v = & $ClockFn
                if (($v -is [System.Collections.IList]) -and ($v -isnot [string]) -and (@($v).Count -ge 1)) { $v = @($v)[0] }
                $c = Convert-MMToUtc -Value $v
                if ($null -ne $c) { return $c }
            }
            catch { }
        }
        return [datetime]::UtcNow
    }
    catch { return [datetime]::UtcNow }
}

function Test-MMCommitParentsProof {
    param($VerifyResult = $null, [string]$ExpectedHeadSha = '')
    try {
        $parents = $null
        $found = $false
        foreach ($k in @('commit_parents', 'parents', 'merge_commit_parents')) {
            $v = Get-MMValue $VerifyResult $k $null
            if ($null -ne $v) { $parents = $v; $found = $true; break }
        }
        if (-not $found) { return $false }
        if ($null -eq $parents) { return $false }
        if ($parents -is [string]) { return $false }
        if (-not ($parents -is [System.Collections.IList])) { return $false }
        $arr = @($parents)
        if ($arr.Count -ne 2) { return $false }
        foreach ($p in $arr) {
            if (-not (Test-MMSha40 -Value $p)) { return $false }
        }
        if (Test-MMSha40 -Value $ExpectedHeadSha) {
            $exp = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
            $hit = $false
            foreach ($p in $arr) {
                if (([string]$p).Trim().ToLowerInvariant() -ceq $exp) { $hit = $true; break }
            }
            if (-not $hit) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-MMApiMethodProof {
    param($VerifyResult = $null)
    try {
        foreach ($k in @('api_method', 'api_merge_method', 'github_merge_method', 'verified_method', 'merged_via')) {
            $v = Get-MMValue $VerifyResult $k $null
            if (($null -ne $v) -and ($v -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$v))) {
                return (([string]$v).Trim().ToLowerInvariant() -ceq 'merge')
            }
        }
        return $false
    }
    catch { return $false }
}

function Get-MMVerifiedMerge {
    param($VerifyResult = $null, [string]$RepoCanon = '', [long]$PrNum = 0, [string]$ExpectedHeadSha = '')
    try {
        if ($null -eq $VerifyResult) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-unconfirmed'); merge_commit_sha = ''; merged = $false }
        }
        $m = Get-MMValue $VerifyResult 'merged' $null
        if (($m -isnot [bool]) -or ($m -ne $true)) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-unconfirmed'); merge_commit_sha = ''; merged = $false }
        }
        $sha = Get-MMValue $VerifyResult 'merge_commit_sha' $null
        if ($null -eq $sha) { $sha = Get-MMValue $VerifyResult 'merge_sha' $null }
        if ($null -eq $sha) { $sha = Get-MMValue $VerifyResult 'sha' $null }
        if ($null -eq $sha) { $sha = Get-MMValue $VerifyResult 'commit_sha' $null }
        if (-not (Test-MMSha40 -Value $sha)) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-unconfirmed'); merge_commit_sha = ''; merged = $true }
        }
        $mergeSha = ([string]$sha).Trim().ToLowerInvariant()
        $vr = Get-MMValue $VerifyResult 'repository' $null
        if ($null -eq $vr) { $vr = Get-MMValue $VerifyResult 'repo' $null }
        if ($null -eq $vr) { $vr = Get-MMValue $VerifyResult 'owner_repo' $null }
        $vrOk = $false
        try {
            if (($null -ne $vr) -and ($vr -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$vr))) {
                $vrT = ([string]$vr).Trim()
                $rcT = ([string]$RepoCanon).Trim().ToLowerInvariant()
                if ((Test-MMRepo -Value $vrT) -and ($vrT.ToLowerInvariant() -ceq $rcT)) { $vrOk = $true }
            }
        }
        catch { $vrOk = $false }
        if (-not $vrOk) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-pr-mismatch'); merge_commit_sha = ''; merged = $true }
        }
        $vp = Get-MMValue $VerifyResult 'pr_number' $null
        if ($null -eq $vp) { $vp = Get-MMValue $VerifyResult 'pr' $null }
        if ($null -eq $vp) { $vp = Get-MMValue $VerifyResult 'number' $null }
        if ($null -eq $vp) { $vp = Get-MMValue $VerifyResult 'pull_number' $null }
        if (($null -eq $vp) -or (-not (Test-MMStrictPositiveInt -Value $vp)) -or ([long]$vp -ne $PrNum)) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-pr-mismatch'); merge_commit_sha = ''; merged = $true }
        }
        if (Test-MMSha40 -Value $ExpectedHeadSha) {
            $exp = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
            if ($mergeSha -ceq $exp) {
                return [pscustomobject]@{ ok = $false; reasons = @('verify-sha-mismatch'); merge_commit_sha = ''; merged = $true }
            }
        }
        # Any divergent or non-string method signal is prohibited (all method fields must be merge when present).
        foreach ($mk in @('merge_method','method','api_method','api_merge_method','github_merge_method','verified_method','merged_via')) {
            $mv = Get-MMValue $VerifyResult $mk $null
            if ($null -eq $mv) { continue }
            if (($mv -is [string]) -and [string]::IsNullOrWhiteSpace([string]$mv)) { continue }
            if ((-not ($mv -is [string])) -or (([string]$mv).Trim().ToLowerInvariant() -cne 'merge')) {
                return [pscustomobject]@{ ok = $false; reasons = @('MERGE_METHOD_PROHIBITED'); merge_commit_sha = ''; merged = $true; prohibited = $true }
            }
        }
        $hasParents = Test-MMCommitParentsProof -VerifyResult $VerifyResult -ExpectedHeadSha $ExpectedHeadSha
        $hasApi = Get-MMApiMethodProof -VerifyResult $VerifyResult
        if (-not ($hasParents -or $hasApi)) {
            return [pscustomobject]@{ ok = $false; reasons = @('verify-method-unproven'); merge_commit_sha = ''; merged = $true }
        }
        return [pscustomobject]@{ ok = $true; reasons = @(); merge_commit_sha = $mergeSha; merged = $true }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reasons = @('verify-unconfirmed'); merge_commit_sha = ''; merged = $false }
    }
}

function New-MMConfirmedReceipt {
    param([string]$RepoCanon = '', [long]$PrNum = 0, [string]$PrHeadSha = '', [string]$MergeCommitSha = '', [string]$PolicyDigest = '', [string]$Author = '', $ScopesArr = @(), $GrantsArr = @(), [string]$EnvName = '', [string]$GoalId = '', [string]$TaskId = '', [bool]$Reconciled = $false)
    try {
        $key = ('merge|' + $RepoCanon + '|' + [string]$PrNum + '|' + $PrHeadSha)
        return [pscustomobject]@{
            action = 'merge'; target = ($RepoCanon + '#' + [string]$PrNum); sha = $PrHeadSha
            pr_head_sha = $PrHeadSha; merge_commit_sha = $MergeCommitSha; merge_method = 'merge'
            idempotency_key = $key; enforcement = 'SOFT_ADVISORY'; outcome = 'CONFIRMED'
            dry_run = $false; reconciled = [bool]$Reconciled; goal = [string]$GoalId; task = [string]$TaskId
            repository = $RepoCanon; pr_number = $PrNum; policy_digest = [string]$PolicyDigest
            author = [string]$Author; credential_scope = $ScopesArr; grants = $GrantsArr; environment = [string]$EnvName
        }
    }
    catch { return $null }
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
        [string]$MergeMethod = 'merge',
        [switch]$DryRun,
        $NowUtc = $null,
        $MaxAgeSeconds = 300,
        [scriptblock]$ClockFn = $null
    )
    try {
        $methodNorm = ([string]$MergeMethod).Trim().ToLowerInvariant()
        if ($methodNorm -cne 'merge') {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('MERGE_METHOD_PROHIBITED'))
        }
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
        $trustedNow = Get-MMTrustedNow -ClockFn $ClockFn

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
        if (Test-MMAuthorityExpired -Authority $Authority -NowUtc $trustedNow) {
            return (New-MMResult -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('AUTHORITY_EXPIRED'))
        }
        $author = [string](Get-MMValue $Authority 'author' '')
        $envName = [string](Get-MMValue $Authority 'environment' '')
        if ([string]::IsNullOrWhiteSpace($author)) {
            return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
        }
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
        foreach ($idVal in @($GoalId, $TaskId)) {
            if (($null -eq $idVal) -or (($idVal -is [string]) -and [string]::IsNullOrWhiteSpace([string]$idVal))) { continue }
            if (-not (Test-MMSecretFree -Value $idVal)) {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons @('INTENT_CONTEXT_INVALID'))
            }
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
        if (-not (Test-MMExactMergeScope -RepoCanon $repoCanon -ScopeItems @($scopesClean.ToArray()))) {
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
            return (New-MMResult -Outcome 'REMEDIATE' -Reasons $elist)
        }

        $rdy = $null
        $readinessNow = $NowUtc
        if ($null -ne $ClockFn) { $readinessNow = $trustedNow }
        try {
            if ($null -ne (Get-Command Get-OrchestrationGitHubReadiness -ErrorAction SilentlyContinue)) {
                $rdy = Get-OrchestrationGitHubReadiness -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expCanon -Snapshot $Snapshot -Policy $Policy -NowUtc $readinessNow -MaxAgeSeconds $maxAge
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
            $ver = Get-MMVerifiedMerge -VerifyResult $vv -RepoCanon $repoCanon -PrNum $prNum -ExpectedHeadSha $expCanon
            if ([bool](Get-MMValue $ver 'ok' $false)) {
                $mergeSha = [string](Get-MMValue $ver 'merge_commit_sha' '')
                $receipt = New-MMConfirmedReceipt -RepoCanon $repoCanon -PrNum $prNum -PrHeadSha $expCanon -MergeCommitSha $mergeSha -PolicyDigest (Get-MMPolicyDigest -Policy $Policy) -Author $author -ScopesArr $scopesArr -GrantsArr $grantsArr -EnvName $envName -GoalId ([string]$GoalId) -TaskId ([string]$TaskId) -Reconciled $true
                $recKey = ('merge|' + $repoCanon + '|' + [string]$prNum + '|' + $expCanon)
                $res = New-MMResult -Outcome 'EXECUTED' -Reasons @('RECONCILED_REMOTE_MERGED') -Receipt $receipt
                Set-MMStore -Store $ReceiptStore -Key $recKey -Result $res
                return $res
            }
            $verReasons = @()
            $vrRaw = Get-MMValue $ver 'reasons' $null
            if ($null -ne $vrRaw) { $verReasons = @($vrRaw) }
            if ($verReasons -contains 'MERGE_METHOD_PROHIBITED') {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons $verReasons)
            }
            return (New-MMResult -Outcome 'RECONCILE' -Reasons ($verReasons + @($rdyReasons)))
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
                sha = $expCanon; pr_head_sha = $expCanon; merge_commit_sha = ''; merge_method = 'merge'
                policy_digest = $digest; author = $author; outcome = 'DRYRUN'
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
            if ($null -ne $VerifyFn) {
                try {
                    $tev = & $VerifyFn $repoCanon $prNum $expCanon
                    $tver = Get-MMVerifiedMerge -VerifyResult $tev -RepoCanon $repoCanon -PrNum $prNum -ExpectedHeadSha $expCanon
                    if ([bool](Get-MMValue $tver 'ok' $false)) {
                        $tmerge = [string](Get-MMValue $tver 'merge_commit_sha' '')
                        $treceipt = New-MMConfirmedReceipt -RepoCanon $repoCanon -PrNum $prNum -PrHeadSha $expCanon -MergeCommitSha $tmerge -PolicyDigest $digest -Author $author -ScopesArr $scopesArr -GrantsArr $grantsArr -EnvName $envName -GoalId $goalStr -TaskId $taskStr -Reconciled $true
                        $tres = New-MMResult -Outcome 'EXECUTED' -Reasons @('RECONCILED_AFTER_TIMEOUT') -Receipt $treceipt
                        Set-MMStore -Store $ReceiptStore -Key $idemKey -Result $tres
                        return $tres
                    }
                }
                catch { }
            }
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
            $ver2 = Get-MMVerifiedMerge -VerifyResult $ev -RepoCanon $repoCanon -PrNum $prNum -ExpectedHeadSha $expCanon
            if ([bool](Get-MMValue $ver2 'ok' $false)) {
                $mergeSha2 = [string](Get-MMValue $ver2 'merge_commit_sha' '')
                $creceipt = New-MMConfirmedReceipt -RepoCanon $repoCanon -PrNum $prNum -PrHeadSha $expCanon -MergeCommitSha $mergeSha2 -PolicyDigest $digest -Author $author -ScopesArr $scopesArr -GrantsArr $grantsArr -EnvName $envName -GoalId $goalStr -TaskId $taskStr -Reconciled $false
                $cres = New-MMResult -Outcome 'EXECUTED' -Reasons (@($greasons) + @('VERIFY_CONFIRMED')) -Receipt $creceipt
                Set-MMStore -Store $ReceiptStore -Key $idemKey -Result $cres
                return $cres
            }
            $ver2Reasons = @()
            $v2Raw = Get-MMValue $ver2 'reasons' $null
            if ($null -ne $v2Raw) { $ver2Reasons = @($v2Raw) }
            if ($ver2Reasons -contains 'MERGE_METHOD_PROHIBITED') {
                return (New-MMResult -Outcome 'POLICY_BLOCKED' -Reasons $ver2Reasons)
            }
            return (New-MMResult -Outcome 'RECONCILE' -Reasons ($ver2Reasons + @($greasons)))
        }
        if ($gout -ceq 'RECONCILE') {
            $isTimeout = $false
            foreach ($gr in @($greasons)) {
                if (([string]$gr -ceq 'EXECUTOR_EXCEPTION') -or (([string]$gr).Contains('TIMEOUT'))) { $isTimeout = $true; break }
            }
            if ($isTimeout -and ($null -ne $VerifyFn)) {
                try {
                    $tev2 = & $VerifyFn $repoCanon $prNum $expCanon
                    $tver2 = Get-MMVerifiedMerge -VerifyResult $tev2 -RepoCanon $repoCanon -PrNum $prNum -ExpectedHeadSha $expCanon
                    if ([bool](Get-MMValue $tver2 'ok' $false)) {
                        $tmerge2 = [string](Get-MMValue $tver2 'merge_commit_sha' '')
                        $treceipt2 = New-MMConfirmedReceipt -RepoCanon $repoCanon -PrNum $prNum -PrHeadSha $expCanon -MergeCommitSha $tmerge2 -PolicyDigest $digest -Author $author -ScopesArr $scopesArr -GrantsArr $grantsArr -EnvName $envName -GoalId $goalStr -TaskId $taskStr -Reconciled $true
                        $tres2 = New-MMResult -Outcome 'EXECUTED' -Reasons @('RECONCILED_AFTER_TIMEOUT') -Receipt $treceipt2
                        Set-MMStore -Store $ReceiptStore -Key $idemKey -Result $tres2
                        return $tres2
                    }
                }
                catch { }
            }
            return (New-MMResult -Outcome 'RECONCILE' -Reasons $greasons)
        }
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
