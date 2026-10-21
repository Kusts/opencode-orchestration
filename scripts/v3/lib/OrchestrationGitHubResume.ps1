<#!
.SYNOPSIS
    P0-05 GitHub resume caller lib: durable wait registration + single-shot
    resume decision (no daemon, no watcher, no loop).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Single-shot helpers
    invoked by the Planner in an active session; there is no background
    lifecycle here: no sleep, no timer, no retry loop, no watcher, no
    scheduler, no service, no second control plane. Fail-closed, PS 5.1
    compatible, ASCII-only. Never throws on operational paths: every
    failure returns an object with ok=$false and a machine-readable reason.
    No network, no process spawn, no gh calls, no merge/deploy, no tokens,
    no transcripts: persisted contracts carry only bounded identifiers and
    stable codes. Readiness is NEVER reimplemented here: Test-... reuses
    Get-OrchestrationGitHubReadiness from OrchestrationDelivery.ps1 via
    lazy dot-source (same idiom as github-await.ps1). Compare-and-swap
    writes are serialized by a single-try advisory sidecar lock
    (<waitfile>.waitlock, no wait/sleep; contention fails closed with
    wait-lock-busy). The lock serializes cooperating writers that go
    through Write-GHRSWaitDocument; it is not an OS-mandatory lock
    against foreign writers. Authority pins: every
    envelope reports grants_authority=false, done_approved=false,
    merge_authority=false, kernel_mutated=false. resume_authorized=true only
    on a RESUME decision, consumed by the invoking Planner session as a
    recommendation; the Planner still owns the next step invocation. An
    absent executor yields READY (observation, never auto-advance).
    Contract-vs-policy gate: Test refuses persisted required_checks /
    review_expectation that diverge from the effective policy
    (INVALID policy-diverged, fail-closed); snapshot evaluation stays
    delegated to readiness. Filenames derive from the SHA256 of the full
    dedup key; Register refuses overwrite on identity divergence
    (wait-filename-collision, no silent -Force). Confirm/Register persist
    via optimistic compare-and-swap on file bytes (wait-modified on
    conflict, no silent loss).
#>
[CmdletBinding()]
param()

function Get-OrchestrationGitHubResumeVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        phase          = 'P0-05'
        contract       = 'github-resume-caller-v1'
    }
}

function Test-GHRSRepo {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
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

function Test-GHRSSha40 {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ($v.Length -ne 40) { return $false }
        return ($v -cmatch '^[0-9a-fA-F]{40}$')
    }
    catch { return $false }
}

function Test-GHRSStrictPositiveInt {
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

function Test-GHRSNonNegativeInt {
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

function Test-GHRSOwner {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Test-GHRSObjectiveId {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 64) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,64}$')
    }
    catch { return $false }
}

function Test-GHRSTaskId {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        if ($v -cnotmatch '\A[A-Za-z0-9._-]+\z') { return $false }
        return ($v -cmatch '\A[a-z0-9][a-z0-9._-]{2,63}\z')
    }
    catch { return $false }
}

function Test-GHRSRunId {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._-]+$')
    }
    catch { return $false }
}

function Test-GHRSBranch {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 200) { return $false }
        if ($v -cmatch '[^A-Za-z0-9._/-]') { return $false }
        if ($v -cmatch '\.\.') { return $false }
        return $true
    }
    catch { return $false }
}

function Test-GHRSCursor {
    param([string]$Value = '')
    try {
        $v = ([string]$Value)
        if ($null -eq $v) { return $true }
        if (-not ($v -is [string])) { return $false }
        if ($v -eq '') { return $true }
        if ($v.Length -gt 256) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]+$')
    }
    catch { return $false }
}

function Test-GHRSEventId {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 256) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]+$')
    }
    catch { return $false }
}

function Test-GHRSSecretFree {
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

function Test-GHRSCheckName {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 200) { return $false }
        if ($v -cmatch '[\x00-\x1F\x7F]') { return $false }
        if (-not (Test-GHRSSecretFree -Value $v)) { return $false }
        return $true
    }
    catch { return $false }
}

function Convert-GHRSUtc {
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

function Get-GHRSValue {
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

function Get-OrchestrationGitHubResumeDedupKey {
    [CmdletBinding()]
    param($Repository = '', $PrNumber = $null, $HeadSha = '', $Generation = $null)
    try {
        if (-not (Test-GHRSRepo -Value ([string]$Repository))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-repository'; dedup_key = '' }
        }
        if (-not (Test-GHRSStrictPositiveInt -Value $PrNumber)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-pr-number'; dedup_key = '' }
        }
        if (-not (Test-GHRSSha40 -Value $HeadSha)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-head-sha'; dedup_key = '' }
        }
        if (-not (Test-GHRSNonNegativeInt -Value $Generation)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-generation'; dedup_key = '' }
        }
        $repo = ([string]$Repository).Trim().ToLowerInvariant()
        $head = ([string]$HeadSha).Trim().ToLowerInvariant()
        $key = ('github-resume:v1:' + $repo + ':' + [string]([long]$PrNumber) + ':' + $head + ':' + [string]([long]$Generation))
        return [pscustomobject]@{ ok = $true; reason = ''; dedup_key = $key }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; dedup_key = '' }
    }
}

function Get-GHRSWaitFileName {
    param([string]$Repository = '', [long]$PrNumber = 0, [string]$HeadSha = '', [long]$Generation = 0)
    try {
        $dk = Get-OrchestrationGitHubResumeDedupKey -Repository ([string]$Repository) -PrNumber $PrNumber -HeadSha ([string]$HeadSha) -Generation $Generation
        if (-not [bool]$dk.ok) { return '' }
        $keyBytes = [Text.Encoding]::UTF8.GetBytes([string]$dk.dedup_key)
        $sha = $null
        try { $sha = [Security.Cryptography.SHA256]::Create() }
        catch { return '' }
        try {
            $hash = $sha.ComputeHash($keyBytes)
            $hex = ''
            foreach ($b in @($hash)) { $hex += $b.ToString('x2') }
            if ($hex.Length -lt 16) { return '' }
            return ('ghwait-' + $hex.Substring(0, 16) + '.json')
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Write-GHRSWaitDocument {
    param([string]$Path = '', $OriginalBytes = $null, $Document = $null, [bool]$ExpectAbsent = $false)
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { return @{ ok = $false; reason = 'invalid-wait-file' } }
        if ($null -eq $Document) { return @{ ok = $false; reason = 'invalid-wait' } }
        $json = ''
        try { $json = (ConvertTo-Json -InputObject $Document -Depth 10 -Compress) }
        catch { return @{ ok = $false; reason = 'encode-failed' } }
        $dir = [IO.Path]::GetDirectoryName($p)
        if ([string]::IsNullOrWhiteSpace($dir)) { return @{ ok = $false; reason = 'invalid-wait-file' } }
        $lockPath = ($p + '.waitlock')
        $lockFs = $null
        try {
            $lockFs = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch { return @{ ok = $false; reason = 'wait-lock-busy' } }
        try {
        $tmp = Join-Path $dir (('.tmp-' + [IO.Path]::GetRandomFileName()) + '.json')
        try { [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false)) }
        catch {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            return @{ ok = $false; reason = 'wait-persist-failed' }
        }
        if ($null -ne $OriginalBytes) {
            $cur = $null
            try { $cur = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
            catch { $cur = $null }
            if (($null -eq $cur) -or ($cur -cne [string]$OriginalBytes)) {
                try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
                return @{ ok = $false; reason = 'wait-modified' }
            }
        }
        try {
            if ([bool]$ExpectAbsent) {
                Move-Item -LiteralPath $tmp -Destination $p -ErrorAction Stop
            }
            else {
                Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop
            }
        }
        catch {
            try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
            return @{ ok = $false; reason = 'wait-persist-failed' }
        }
        return @{ ok = $true; reason = '' }
        }
        finally {
            try {
                if ($null -ne $lockFs) {
                    try { $lockFs.Close() } catch { }
                    try { $lockFs.Dispose() } catch { }
                }
            }
            catch { }
            try {
                if (-not [string]::IsNullOrWhiteSpace($lockPath)) {
                    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
    }
    catch { return @{ ok = $false; reason = 'internal-error' } }
}

function Test-GHRSWaitShape {
    param($Wait = $null)
    try {
        if ($null -eq $Wait) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([long](Get-GHRSValue $Wait 'schema_version' 0) -ne 1) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([string](Get-GHRSValue $Wait 'wait_kind' '') -cne 'github-ci-resume') { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([string](Get-GHRSValue $Wait 'wait_state' '') -cne 'waiting') { return @{ ok = $false; reason = 'invalid-wait-state' } }
        if (-not (Test-GHRSRepo -Value ([string](Get-GHRSValue $Wait 'repository' '')))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if (-not (Test-GHRSStrictPositiveInt -Value (Get-GHRSValue $Wait 'pr_number' $null))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if (-not (Test-GHRSSha40 -Value ([string](Get-GHRSValue $Wait 'expected_head_sha' '')))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if (-not (Test-GHRSNonNegativeInt -Value (Get-GHRSValue $Wait 'generation' $null))) { return @{ ok = $false; reason = 'invalid-wait' } }
        $dk = Get-OrchestrationGitHubResumeDedupKey -Repository ([string](Get-GHRSValue $Wait 'repository' '')) -PrNumber (Get-GHRSValue $Wait 'pr_number' $null) -HeadSha ([string](Get-GHRSValue $Wait 'expected_head_sha' '')) -Generation (Get-GHRSValue $Wait 'generation' $null)
        if (-not [bool]$dk.ok) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([string](Get-GHRSValue $Wait 'dedup_key' '') -cne [string]$dk.dedup_key) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ($null -eq (Convert-GHRSUtc -Value (Get-GHRSValue $Wait 'deadline_utc' $null))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ($null -eq (Convert-GHRSUtc -Value (Get-GHRSValue $Wait 'lease_expires_utc' $null))) { return @{ ok = $false; reason = 'invalid-wait' } }
        $rbMax = Get-GHRSValue $Wait 'retry_budget_max' $null
        $rbUsed = Get-GHRSValue $Wait 'retry_used' $null
        if ((-not (Test-GHRSNonNegativeInt -Value $rbMax)) -or (-not (Test-GHRSNonNegativeInt -Value $rbUsed))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([long]$rbMax -gt 100) { return @{ ok = $false; reason = 'invalid-wait' } }
        if ([long]$rbUsed -gt [long]$rbMax) { return @{ ok = $false; reason = 'invalid-wait' } }
        if (-not (Test-GHRSOwner -Value ([string](Get-GHRSValue $Wait 'owner' '')))) { return @{ ok = $false; reason = 'invalid-wait' } }
        if (-not (Test-GHRSOwner -Value ([string](Get-GHRSValue $Wait 'lease_owner' '')))) { return @{ ok = $false; reason = 'invalid-wait' } }
        $rcRaw = Get-GHRSValue $Wait 'required_checks' $null
        if (($null -eq $rcRaw) -or (-not ($rcRaw -is [System.Collections.IList]))) { return @{ ok = $false; reason = 'invalid-wait' } }
        $rcList = @($rcRaw)
        if (@($rcList).Count -gt 32) { return @{ ok = $false; reason = 'invalid-wait' } }
        foreach ($cn in @($rcList)) {
            if (-not (Test-GHRSCheckName -Value $cn)) { return @{ ok = $false; reason = 'invalid-wait' } }
        }
        $reRaw = ([string](Get-GHRSValue $Wait 'review_expectation' '')).Trim().ToUpperInvariant()
        if (($reRaw -cne 'APPROVED') -and ($reRaw -cne 'ANY')) { return @{ ok = $false; reason = 'invalid-wait' } }
        return @{ ok = $true; reason = '' }
    }
    catch { return @{ ok = $false; reason = 'invalid-wait' } }
}

function Register-OrchestrationGitHubWait {
    [CmdletBinding()]
    param(
        [string]$WaitsDir = '',
        [string]$ObjectiveId = '',
        [string]$TaskId = '',
        [string]$RunId = '',
        $Generation = $null,
        [string]$Repository = '',
        $PrNumber = $null,
        [string]$Branch = '',
        [string]$ExpectedHeadSha = '',
        $RequiredChecks = @(),
        [string]$ReviewExpectation = 'APPROVED',
        [string]$Cursor = '',
        $DeadlineUtc = $null,
        $RetryBudgetMax = $null,
        [string]$LeaseOwner = '',
        $LeaseExpiresUtc = $null,
        [string]$Owner = ''
    )
    try {
        $dir = ([string]$WaitsDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-waits-dir'; reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSObjectiveId -Value $ObjectiveId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSTaskId -Value $TaskId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task'; reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSRunId -Value $RunId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-run'; reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $dk = Get-OrchestrationGitHubResumeDedupKey -Repository $Repository -PrNumber $PrNumber -HeadSha $ExpectedHeadSha -Generation $Generation
        if (-not [bool]$dk.ok) {
            return [pscustomobject]@{ ok = $false; reason = ([string]$dk.reason); reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSBranch -Value $Branch)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-branch'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $checks = @()
        if ($null -ne $RequiredChecks) { $checks = @($RequiredChecks) }
        if (@($checks).Count -gt 32) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-checks'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $cleanChecks = New-Object System.Collections.ArrayList
        foreach ($cn in @($checks)) {
            if (-not (Test-GHRSCheckName -Value $cn)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-checks'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
            }
            [void]$cleanChecks.Add(([string]$cn).Trim())
        }
        $revExp = ([string]$ReviewExpectation).Trim().ToUpperInvariant()
        if (($revExp -cne 'APPROVED') -and ($revExp -cne 'ANY')) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-review'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSCursor -Value $Cursor)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-cursor'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $deadline = Convert-GHRSUtc -Value $DeadlineUtc
        if ($null -eq $deadline) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-deadline'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSNonNegativeInt -Value $RetryBudgetMax)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-retry-budget'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if ([long]$RetryBudgetMax -gt 100) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-retry-budget'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSOwner -Value $LeaseOwner)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-lease-owner'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $leaseExp = Convert-GHRSUtc -Value $LeaseExpiresUtc
        if ($null -eq $leaseExp) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-lease-expiry'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        if (-not (Test-GHRSOwner -Value $Owner)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        foreach ($free in @($ObjectiveId, $TaskId, $RunId, $Branch, $Cursor, $LeaseOwner, $Owner)) {
            if (-not (Test-GHRSSecretFree -Value ([string]$free))) {
                return [pscustomobject]@{ ok = $false; reason = 'secret-refused'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
            }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'waits-dir-unavailable'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $prNum = [long]$PrNumber
        $gen = [long]$Generation
        $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        $headCanon = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter 'ghwait-*.json' -ErrorAction Stop)) {
                $doc = $null
                try {
                    if ([long]$f.Length -le 0 -or [long]$f.Length -gt 262144) { continue }
                    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
                }
                catch { continue }
                if ([string](Get-GHRSValue $doc 'dedup_key' '') -ceq [string]$dk.dedup_key) {
                    return [pscustomobject]@{ ok = $true; reason = 'already-registered'; reused = $true; wait = $doc; wait_file = $f.FullName; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'waits-dir-unreadable'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $stamp = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
        $wait = [pscustomobject][ordered]@{
            schema_version    = 1
            wait_kind         = 'github-ci-resume'
            wait_state        = 'waiting'
            dedup_key         = [string]$dk.dedup_key
            objective_id      = ([string]$ObjectiveId).Trim()
            task_id           = ([string]$TaskId).Trim()
            run_id            = ([string]$RunId).Trim()
            generation        = $gen
            repository        = $repoCanon
            pr_number         = $prNum
            branch            = ([string]$Branch).Trim()
            expected_head_sha = $headCanon
            required_checks   = [string[]]@($cleanChecks.ToArray())
            review_expectation = $revExp
            cursor            = ([string]$Cursor)
            deadline_utc      = $deadline.ToUniversalTime().ToString('o')
            retry_budget_max  = [long]$RetryBudgetMax
            retry_used        = [long]0
            lease_owner       = ([string]$LeaseOwner).Trim()
            lease_expires_utc = $leaseExp.ToUniversalTime().ToString('o')
            owner             = ([string]$Owner).Trim()
            applied_events    = [string[]]@()
            created_at        = $stamp
            updated_at        = $stamp
        }
        $fname = Get-GHRSWaitFileName -Repository $repoCanon -PrNumber $prNum -HeadSha $headCanon -Generation $gen
        if ([string]::IsNullOrWhiteSpace($fname)) {
            return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $dest = Join-Path $dir $fname
        $preBytes = $null
        try {
            if (Test-Path -LiteralPath $dest -PathType Leaf) {
                $preBytes = [IO.File]::ReadAllText($dest, [Text.Encoding]::UTF8)
            }
        }
        catch { $preBytes = $null }
        if ($null -ne $preBytes) {
            $preDoc = $null
            try { $preDoc = ConvertFrom-Json $preBytes } catch { $preDoc = $null }
            if (($null -ne $preDoc) -and ([string](Get-GHRSValue $preDoc 'dedup_key' '') -ceq [string]$dk.dedup_key)) {
                return [pscustomobject]@{ ok = $true; reason = 'already-registered'; reused = $true; wait = $preDoc; wait_file = $dest; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
            }
            return [pscustomobject]@{ ok = $false; reason = 'wait-filename-collision'; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        $wr = Write-GHRSWaitDocument -Path $dest -Document $wait -ExpectAbsent $true
        if (-not [bool]$wr.ok) {
            $wrsn = [string]$wr.reason
            if ([string]::IsNullOrWhiteSpace($wrsn)) { $wrsn = 'wait-persist-failed' }
            return [pscustomobject]@{ ok = $false; reason = $wrsn; reused = $false; wait = $null; wait_file = ''; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
        }
        return [pscustomobject]@{ ok = $true; reason = 'registered'; reused = $false; wait = $wait; wait_file = $dest; dedup_key = [string]$dk.dedup_key; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reused = $false; wait = $null; wait_file = ''; dedup_key = ''; kernel_mutated = $false; grants_authority = $false; done_approved = $false }
    }
}

function Get-OrchestrationGitHubWaits {
    [CmdletBinding()]
    param([string]$WaitsDir = '')
    try {
        $dir = ([string]$WaitsDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir) -or (-not (Test-Path -LiteralPath $dir -PathType Container))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-waits-dir'; waits = @(); skipped = [long]0 }
        }
        $out = New-Object System.Collections.ArrayList
        $skipped = [long]0
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter 'ghwait-*.json' -ErrorAction Stop)) {
            $doc = $null
            try {
                if ([long]$f.Length -le 0 -or [long]$f.Length -gt 262144) { $skipped++; continue }
                $doc = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
            }
            catch { $skipped++; continue }
            $shape = Test-GHRSWaitShape -Wait $doc
            if (-not [bool]$shape.ok) { $skipped++; continue }
            [void]$out.Add($doc)
        }
        return [pscustomobject]@{ ok = $true; reason = ''; waits = @($out.ToArray()); skipped = $skipped }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'waits-dir-unreadable'; waits = @(); skipped = [long]0 }
    }
}

function Confirm-OrchestrationGitHubResumeApplied {
    [CmdletBinding()]
    param([string]$WaitsDir = '', [string]$DedupKey = '', [string]$EventId = '')
    try {
        $dir = ([string]$WaitsDir).Trim()
        $ddk = ([string]$DedupKey).Trim()
        if ([string]::IsNullOrWhiteSpace($dir) -or (-not (Test-Path -LiteralPath $dir -PathType Container))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-waits-dir'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        if ([string]::IsNullOrWhiteSpace($ddk)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-dedup-key'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        if (-not (Test-GHRSEventId -Value $EventId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event-id'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        if (-not (Test-GHRSSecretFree -Value ([string]$EventId))) {
            return [pscustomobject]@{ ok = $false; reason = 'secret-refused'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        $target = $null
        $targetPath = ''
        $targetBytes = $null
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter 'ghwait-*.json' -ErrorAction Stop)) {
                $raw = $null
                $doc = $null
                try {
                    if ([long]$f.Length -le 0 -or [long]$f.Length -gt 262144) { continue }
                    $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
                    $doc = ConvertFrom-Json $raw
                }
                catch { continue }
                if ([string](Get-GHRSValue $doc 'dedup_key' '') -ceq $ddk) {
                    $shape = Test-GHRSWaitShape -Wait $doc
                    if (-not [bool]$shape.ok) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-wait'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
                    }
                    $target = $doc
                    $targetPath = $f.FullName
                    $targetBytes = $raw
                    break
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'waits-dir-unreadable'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        if ($null -eq $target) {
            return [pscustomobject]@{ ok = $false; reason = 'wait-not-found'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
        }
        $applied = @()
        try {
            $rawApplied = Get-GHRSValue $target 'applied_events' $null
            if ($null -ne $rawApplied) { $applied = @($rawApplied) }
        }
        catch { $applied = @() }
        $evt = ([string]$EventId).Trim()
        foreach ($seen in @($applied)) {
            if ([string]$seen -ceq $evt) {
                return [pscustomobject]@{ ok = $true; reason = 'duplicate-suppressed'; reused = $true; wait = $target; wait_file = $targetPath; kernel_mutated = $false }
            }
        }
        if (@($applied).Count -ge 128) {
            return [pscustomobject]@{ ok = $false; reason = 'event-log-full'; reused = $false; wait = $target; wait_file = $targetPath; kernel_mutated = $false }
        }
        $newApplied = @($applied) + @($evt)
        # Baseline binding: reuse the exact bytes captured on the first read
        # (:603 scan) and deserialize that same text. No second read here: a
        # re-read would hand CAS fresh bytes for a stale document, letting a
        # concurrent Confirm slip through and be silently overwritten.
        $origBytes = $targetBytes
        if (($null -eq $origBytes) -or ([string]::IsNullOrWhiteSpace([string]$origBytes))) {
            return [pscustomobject]@{ ok = $false; reason = 'waits-dir-unreadable'; reused = $false; wait = $target; wait_file = $targetPath; kernel_mutated = $false }
        }
        $target.applied_events = [string[]]$newApplied
        $target.updated_at = ([datetime]::UtcNow).ToUniversalTime().ToString('o')
        $wr = Write-GHRSWaitDocument -Path $targetPath -OriginalBytes $origBytes -Document $target
        if (-not [bool]$wr.ok) {
            $wrsn = [string]$wr.reason
            if ([string]::IsNullOrWhiteSpace($wrsn)) { $wrsn = 'wait-persist-failed' }
            return [pscustomobject]@{ ok = $false; reason = $wrsn; reused = $false; wait = $target; wait_file = $targetPath; kernel_mutated = $false }
        }
        return [pscustomobject]@{ ok = $true; reason = 'applied'; reused = $false; wait = $target; wait_file = $targetPath; kernel_mutated = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; reused = $false; wait = $null; wait_file = ''; kernel_mutated = $false }
    }
}

function New-GHRSDecisionEnvelope {
    param(
        [bool]$Ok = $false,
        [string]$Decision = 'INVALID',
        [string]$Reason = 'internal-error',
        $Reasons = @(),
        $Wait = $null,
        [string]$Readiness = '',
        [string]$ObservedHeadSha = ''
    )
    try {
        $valid = @('RESUME', 'READY', 'KEEP_WAITING', 'TERMINAL', 'DUPLICATE_NOOP', 'OUT_OF_ORDER', 'INVALID')
        $dec = ([string]$Decision).Trim().ToUpperInvariant()
        if ($valid -cnotcontains $dec) { $dec = 'INVALID' }
        $why = New-Object System.Collections.ArrayList
        if ($null -ne $Reasons) {
            foreach ($rs in @($Reasons)) {
                if (@($why).Count -ge 8) { break }
                if (-not ($rs -is [string])) { continue }
                $t = ([string]$rs).Trim()
                if ($t.Length -eq 0 -or $t.Length -gt 200) { continue }
                if ($t -match '[\x00-\x1F\x7F]') { continue }
                [void]$why.Add($t)
            }
        }
        $repoOut = ''
        $prOut = [long]0
        $expOut = ''
        $ddkOut = ''
        try {
            $repoOut = ([string](Get-GHRSValue $Wait 'repository' ''))
            $prOut = [long](Get-GHRSValue $Wait 'pr_number' 0)
            $expOut = ([string](Get-GHRSValue $Wait 'expected_head_sha' ''))
            $ddkOut = ([string](Get-GHRSValue $Wait 'dedup_key' ''))
        }
        catch { }
        $rdyOut = ([string]$Readiness).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($rdyOut)) { $rdyOut = 'UNKNOWN' }
        $obsOut = ''
        try {
            if (Test-GHRSSha40 -Value $ObservedHeadSha) {
                $obsOut = ([string]$ObservedHeadSha).Trim().ToLowerInvariant()
            }
        }
        catch { $obsOut = '' }
        $expShort = ''
        try {
            if (Test-GHRSSha40 -Value $expOut) { $expShort = ([string]$expOut).Trim().ToLowerInvariant().Substring(0, 8) }
        }
        catch { $expShort = '' }
        $notify = ($dec + ' ' + $repoOut + '#' + [string]$prOut + '@' + $expShort + ' readiness=' + $rdyOut + ' reason=' + ([string]$Reason))
        if (([string[]]$why.ToArray()).Count -gt 0) {
            $notify = ($notify + ' detail=' + (([string[]]$why.ToArray()) -join ','))
        }
        if ($notify.Length -gt 1024) { $notify = $notify.Substring(0, 1024) }
        return [pscustomobject]@{
            ok                = ([bool]$Ok -and ($dec -cne 'INVALID'))
            decision          = $dec
            reason            = ([string]$Reason)
            reasons           = [string[]]$why.ToArray()
            dedup_key         = $ddkOut
            repository        = $repoOut
            pr_number         = $prOut
            expected_head_sha = $expOut
            observed_head_sha = $obsOut
            readiness         = $rdyOut
            notify            = $notify
            snapshot_only     = $true
            grants_authority  = $false
            done_approved     = $false
            merge_authority   = $false
            resume_authorized = ($dec -ceq 'RESUME')
            kernel_mutated    = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; decision = 'INVALID'; reason = 'internal-error'; reasons = @('internal-error')
            dedup_key = ''; repository = ''; pr_number = 0; expected_head_sha = ''; observed_head_sha = ''
            readiness = 'UNKNOWN'; notify = 'INVALID reason=internal-error'
            snapshot_only = $true; grants_authority = $false; done_approved = $false
            merge_authority = $false; resume_authorized = $false; kernel_mutated = $false
        }
    }
}

function Test-OrchestrationGitHubResume {
    [CmdletBinding()]
    param(
        $Wait = $null,
        $Snapshot = $null,
        $Policy = $null,
        $NowUtc = $null,
        $MaxAgeSeconds = 300,
        $LeaseAlive = $null,
        $OwnerAlive = $null,
        $AuthorizationAlive = $null,
        $ExecutorPresent = $null,
        $CancelRequested = $null,
        $AlreadyApplied = $null,
        [string]$EventDedupKey = ''
    )
    try {
        $shape = Test-GHRSWaitShape -Wait $Wait
        if (-not [bool]$shape.ok) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason ([string]$shape.reason) -Reasons @([string]$shape.reason) -Wait $Wait)
        }
        foreach ($flagName in @('LeaseAlive', 'OwnerAlive', 'AuthorizationAlive', 'ExecutorPresent', 'CancelRequested', 'AlreadyApplied')) {
            $flagVal = $null
            if ($flagName -ceq 'LeaseAlive') { $flagVal = $LeaseAlive }
            elseif ($flagName -ceq 'OwnerAlive') { $flagVal = $OwnerAlive }
            elseif ($flagName -ceq 'AuthorizationAlive') { $flagVal = $AuthorizationAlive }
            elseif ($flagName -ceq 'ExecutorPresent') { $flagVal = $ExecutorPresent }
            elseif ($flagName -ceq 'CancelRequested') { $flagVal = $CancelRequested }
            elseif ($flagName -ceq 'AlreadyApplied') { $flagVal = $AlreadyApplied }
            if (-not ($flagVal -is [bool])) {
                return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'invalid-argument' -Reasons @('invalid-argument') -Wait $Wait)
            }
        }
        if (-not (Test-GHRSNonNegativeInt -Value $MaxAgeSeconds)) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'invalid-max-age' -Reasons @('invalid-max-age') -Wait $Wait)
        }
        if ([long]$MaxAgeSeconds -lt 1 -or [long]$MaxAgeSeconds -gt 3600) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'invalid-max-age' -Reasons @('invalid-max-age') -Wait $Wait)
        }
        if ([bool]$CancelRequested) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'cancelled' -Reasons @('cancelled') -Wait $Wait)
        }
        if ([bool]$AlreadyApplied) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'DUPLICATE_NOOP' -Reason 'duplicate-suppressed' -Reasons @('duplicate-suppressed') -Wait $Wait)
        }
        $evtTrim = ([string]$EventDedupKey).Trim()
        if ($evtTrim -ne '') {
            if ($evtTrim -cne ([string](Get-GHRSValue $Wait 'dedup_key' ''))) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'OUT_OF_ORDER' -Reason 'event-out-of-order' -Reasons @('event-out-of-order') -Wait $Wait)
            }
        }
        $now = Convert-GHRSUtc -Value $NowUtc
        if ($null -eq $NowUtc) { $now = [datetime]::UtcNow }
        if ($null -eq $now) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'invalid-now' -Reasons @('invalid-now') -Wait $Wait)
        }
        $deadline = Convert-GHRSUtc -Value (Get-GHRSValue $Wait 'deadline_utc' $null)
        if (($null -ne $deadline) -and ($now -gt $deadline)) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'wait-expired' -Reasons @('wait-expired') -Wait $Wait -Readiness 'UNKNOWN')
        }
        if (-not [bool]$LeaseAlive) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'lease-expired' -Reasons @('lease-expired') -Wait $Wait -Readiness 'UNKNOWN')
        }
        if (-not [bool]$OwnerAlive) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'owner-mismatch' -Reasons @('owner-mismatch') -Wait $Wait -Readiness 'UNKNOWN')
        }
        if (-not [bool]$AuthorizationAlive) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'authorization-revoked' -Reasons @('authorization-revoked') -Wait $Wait -Readiness 'UNKNOWN')
        }
        $libDir = $PSScriptRoot
        $deliveryLib = Join-Path $libDir 'OrchestrationDelivery.ps1'
        $hasReadiness = $false
        try {
            if ($null -ne (Get-Command Get-OrchestrationGitHubReadiness -ErrorAction SilentlyContinue)) { $hasReadiness = $true }
        }
        catch { $hasReadiness = $false }
        if (-not $hasReadiness) {
            try {
                if (Test-Path -LiteralPath $deliveryLib -PathType Leaf) {
                    . $deliveryLib
                    if ($null -ne (Get-Command Get-OrchestrationGitHubReadiness -ErrorAction SilentlyContinue)) { $hasReadiness = $true }
                }
            }
            catch { $hasReadiness = $false }
        }
        if (-not $hasReadiness) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'readiness-unavailable' -Reasons @('readiness-unavailable') -Wait $Wait -Readiness 'UNKNOWN')
        }
        $effChecks = $null
        try { $effChecks = Get-OrchestrationDeliveryRequiredChecks $Policy } catch { $effChecks = $null }
        if ($null -eq $effChecks) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'policy-invalid' -Reasons @('policy-invalid') -Wait $Wait)
        }
        $persistedChecks = @()
        try {
            $pcRaw = Get-GHRSValue $Wait 'required_checks' $null
            if ($null -ne $pcRaw) { $persistedChecks = @($pcRaw) }
        }
        catch { $persistedChecks = @() }
        $effSet = @{}
        foreach ($n in @($effChecks)) { $effSet[([string]$n).Trim().ToLowerInvariant()] = $true }
        $perSet = @{}
        foreach ($n in @($persistedChecks)) { $perSet[([string]$n).Trim().ToLowerInvariant()] = $true }
        $diverged = $false
        if (@($effSet.Keys).Count -ne @($perSet.Keys).Count) { $diverged = $true }
        else {
            foreach ($k in @($effSet.Keys)) {
                if (-not $perSet.ContainsKey($k)) { $diverged = $true; break }
            }
        }
        if ($diverged) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'policy-diverged' -Reasons @('policy-diverged') -Wait $Wait)
        }
        $persistedRev = ([string](Get-GHRSValue $Wait 'review_expectation' '')).Trim().ToUpperInvariant()
        $polIntRev = ''
        try {
            $polReview = Get-GHRSValue $Policy 'review' $null
            $polIntRev = ([string](Get-GHRSValue $polReview 'internal_reviewer' '')).Trim().ToLowerInvariant()
        }
        catch { $polIntRev = '' }
        if ([string]::IsNullOrWhiteSpace($polIntRev)) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'policy-invalid' -Reasons @('policy-invalid') -Wait $Wait)
        }
        if (($polIntRev -ceq 'required') -and ($persistedRev -cne 'APPROVED')) {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'policy-diverged' -Reasons @('policy-diverged') -Wait $Wait)
        }
        $rdy = $null
        try {
            $rdy = Get-OrchestrationGitHubReadiness -Repository ([string](Get-GHRSValue $Wait 'repository' '')) -PrNumber (Get-GHRSValue $Wait 'pr_number' $null) -ExpectedHeadSha ([string](Get-GHRSValue $Wait 'expected_head_sha' '')) -Snapshot $Snapshot -Policy $Policy -NowUtc $NowUtc -MaxAgeSeconds ([long]$MaxAgeSeconds)
        }
        catch { $rdy = $null }
        if ($null -eq $rdy) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'readiness-unavailable' -Reasons @('readiness-unavailable') -Wait $Wait -Readiness 'UNKNOWN')
        }
        $rdyVal = ''
        $rdyOk = $false
        $rdyReasons = @()
        $rdyObs = ''
        try { $rdyVal = ([string](Get-GHRSValue $rdy 'readiness' '')).Trim().ToUpperInvariant() } catch { $rdyVal = '' }
        try { $rdyOk = [bool](Get-GHRSValue $rdy 'ok' $false) } catch { $rdyOk = $false }
        try {
            $rr = Get-GHRSValue $rdy 'reasons' $null
            if ($null -ne $rr) { $rdyReasons = [string[]]@($rr) }
        }
        catch { $rdyReasons = @() }
        try { $rdyObs = ([string](Get-GHRSValue $rdy 'observed_head_sha' '')) } catch { $rdyObs = '' }
        if ($rdyVal -ceq 'READY_FOR_RESUME') {
            if ((-not $rdyOk) -or (@($rdyReasons).Count -gt 0)) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'inconclusive' -Reasons @('inconclusive') -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
            }
            if (-not [bool]$ExecutorPresent) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'READY' -Reason 'ready-no-executor' -Reasons @('ready-no-executor') -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
            }
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'RESUME' -Reason 'ready-for-resume' -Reasons @() -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        if (($rdyVal -ceq 'CHECKS_PENDING') -or ($rdyVal -ceq 'REVIEW_PENDING')) {
            $rbMax = [long](Get-GHRSValue $Wait 'retry_budget_max' 0)
            $rbUsed = [long](Get-GHRSValue $Wait 'retry_used' 0)
            if ($rbUsed -ge $rbMax) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'retry-budget-exhausted' -Reasons (@('retry-budget-exhausted') + @($rdyReasons)) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
            }
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'pending' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        if ($rdyVal -ceq 'REPAIR_REQUIRED') {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'diagnostic' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        if ($rdyVal -ceq 'TERMINAL') {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'pr-terminal' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        if ($rdyVal -ceq 'STALE') {
            $superseded = $false
            foreach ($rc in @($rdyReasons)) {
                if (([string]$rc -ceq 'head-mismatch') -or ([string]$rc -ceq 'commit-mismatch')) { $superseded = $true; break }
            }
            if ($superseded) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'head-superseded' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
            }
            $rbMax2 = [long](Get-GHRSValue $Wait 'retry_budget_max' 0)
            $rbUsed2 = [long](Get-GHRSValue $Wait 'retry_used' 0)
            if ($rbUsed2 -ge $rbMax2) {
                return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'retry-budget-exhausted' -Reasons (@('retry-budget-exhausted') + @($rdyReasons)) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
            }
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'snapshot-stale' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        $rbMax3 = [long](Get-GHRSValue $Wait 'retry_budget_max' 0)
        $rbUsed3 = [long](Get-GHRSValue $Wait 'retry_used' 0)
        if ($rbUsed3 -ge $rbMax3) {
            return (New-GHRSDecisionEnvelope -Ok $true -Decision 'TERMINAL' -Reason 'retry-budget-exhausted' -Reasons (@('retry-budget-exhausted') + @($rdyReasons)) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
        }
        return (New-GHRSDecisionEnvelope -Ok $true -Decision 'KEEP_WAITING' -Reason 'inconclusive' -Reasons @($rdyReasons) -Wait $Wait -Readiness $rdyVal -ObservedHeadSha $rdyObs)
    }
    catch {
        try {
            return (New-GHRSDecisionEnvelope -Ok $false -Decision 'INVALID' -Reason 'internal-error' -Reasons @('internal-error') -Wait $Wait)
        }
        catch { return $null }
    }
}
