<#!
.SYNOPSIS
    ORFS-CONT-F3-CLI: thin GitHub observe-only CLI (no watcher, no daemon).
.DESCRIPTION
    Observes one pull request via read-only GitHub GraphQL (gh api graphql)
    or via an explicit offline fixture file, normalizes the response into
    the bounded snapshot contract owned by OrchestrationDelivery
    (Get-OrchestrationGitHubReadiness) and reports readiness. Observe-only:
    it never registers/unblocks waits, never completes work, never mutates
    kernel/grants/leases/flags, never writes PRs/comments, never logs in,
    never touches global config. Exit 0 carries a valid observation (whose
    readiness may be READY_FOR_RESUME, PENDING, TERMINAL, STALE,
    REPAIR_REQUIRED or INCONCLUSIVE -- observation is not authorization).
    Exit 1 = transport/schema failure. Exit 2 = invalid args.

    Usage (live):
      powershell -NoProfile -File github-await.ps1 -Action observe `
        -Repository owner/repo -PrNumber 88 -ExpectedHeadSha <40hex> `
        [-Owner <wait-owner>] [-TimeoutMs 10000] [-MaxAgeSeconds 300] `
        [-NowUtc 2026-10-10T12:02:00Z] [-PolicyFile <path>]

    Usage (offline fixture, same normalizer, no network):
      powershell -NoProfile -File github-await.ps1 -Action observe `
        -Repository owner/repo -PrNumber 88 -ExpectedHeadSha <40hex> `
        -GraphQLSnapshotFile <path>

    Output: exactly one JSON envelope on stdout (never raw gh
    stdout/stderr, URLs, bodies, logs or comments; errors[] carries only
    stable codes, never remote content). Dot-source safe: without
    -Repository and without -GraphQLSnapshotFile this file defines
    functions and does nothing else.
    PS 5.1 and PS7 compatible. ASCII-only.
#>
param(
    [string]$Action = 'observe',
    [string]$Repository = '',
    $PrNumber = $null,
    [string]$ExpectedHeadSha = '',
    [string]$Owner = '',
    $TimeoutMs = 10000,
    $MaxAgeSeconds = 300,
    [string]$NowUtc = '',
    [string]$GraphQLSnapshotFile = '',
    [string]$PolicyFile = ''
)

$ErrorActionPreference = 'Stop'

function Get-GHAValue {
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

function Get-GHAArray {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return @{ found = $false; items = @() } }
        if ($Object -is [System.Collections.IDictionary]) {
            if (-not $Object.Contains($Name)) { return @{ found = $false; items = @() } }
            $c = $Object[$Name]
        }
        else {
            $p = $null
            try { $p = $Object.PSObject.Properties[$Name] } catch { $p = $null }
            if ($null -eq $p) { return @{ found = $false; items = @() } }
            $c = $Object.$Name
        }
        if ($null -eq $c) { return @{ found = $true; nullvalue = $true; items = @() } }
        if (($c -is [array]) -or ($c -is [System.Collections.IList])) {
            return @{ found = $true; items = @($c) }
        }
        return @{ found = $true; notarray = $true; items = @() }
    }
    catch { return @{ found = $false; items = @() } }
}

function Test-GHARepoSyntax {
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

function Test-GHASha40 {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ($v.Length -ne 40) { return $false }
        return ($v -cmatch '^[0-9a-fA-F]{40}$')
    }
    catch { return $false }
}

function Test-GHAIntRange {
    param($Value, [long]$Min = 1, [long]$Max = 2147483647)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        $n = [long]$Value
        return (($n -ge $Min) -and ($n -le $Max))
    }
    catch { return $false }
}

function Convert-GHAIntRange {
    param($Value, [long]$Min = 1, [long]$Max = 2147483647)
    try {
        if (Test-GHAIntRange -Value $Value -Min $Min -Max $Max) {
            return @{ ok = $true; value = [long]$Value }
        }
        if ($Value -is [string]) {
            $s = ([string]$Value).Trim()
            if ($s -cmatch '\A[0-9]{1,10}\Z') {
                $n = [long]0
                if ([long]::TryParse($s, [ref]$n)) {
                    if (($n -ge $Min) -and ($n -le $Max)) {
                        return @{ ok = $true; value = $n }
                    }
                }
            }
        }
        return @{ ok = $false; value = [long]0 }
    }
    catch { return @{ ok = $false; value = [long]0 } }
}

function Test-GHAOwner {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 128) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Test-GHANamePart {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt 100) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._-]{1,100}$')
    }
    catch { return $false }
}

function Convert-GHACheckName {
    param($Value = $null)
    try {
        if (-not ($Value -is [string])) { return $null }
        # Raw-first identity: length/controls/empty on the original
        # string, before any Trim; invalid => null (fail-closed, no echo).
        $raw = [string]$Value
        if ($raw.Length -eq 0) { return $null }
        if ($raw.Length -gt 200) { return $null }
        if ($raw -cmatch '[\x00-\x1F\x7F]') { return $null }
        $v = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        if ($v.Length -gt 200) { return $null }
        if ($v -cmatch '[\x00-\x1F\x7F]') { return $null }
        $v = ($v -replace 'sk-[A-Za-z0-9._-]{4,}', '[redacted]')
        $v = ($v -replace 'ghp_[A-Za-z0-9]{4,}', '[redacted]')
        $v = ($v -replace 'github_pat_[A-Za-z0-9._-]{4,}', '[redacted]')
        $v = ($v -replace 'xox-[A-Za-z0-9._-]+', '[redacted]')
        $v = ([string]$v).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        if ($v.Length -gt 200) { return $null }
        return $v
    }
    catch { return $null }
}

function Convert-GHAUtc {
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

function Get-GHAFixedQuery {
    return 'query ($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { nameWithOwner pullRequest(number: $number) { number state headRefOid mergeable reviewDecision commits(last: 1) { nodes { commit { oid statusCheckRollup { contexts(first: 100) { nodes { __typename ... on CheckRun { name status conclusion checkSuite { commit { oid } } } ... on StatusContext { context state commit { oid } } } pageInfo { hasNextPage endCursor } totalCount } } } } } } } }'
}

function Get-GHAGhArgs {
    param([string]$OwnerPart = '', [string]$NamePart = '', [long]$Number = 0)
    $q = Get-GHAFixedQuery
    return @('api', 'graphql', '--hostname', 'github.com', '-f', ('query=' + $q), '-F', ('owner=' + $OwnerPart), '-F', ('name=' + $NamePart), '-F', ('number=' + [string]$Number))
}

function Convert-GHARawToSnapshot {
    param($Raw = $null, [string]$Repository = '', [long]$PrNumber = 0, [string]$ObservedAt = '')
    $errs = New-Object System.Collections.ArrayList
    try {
        $obs = Convert-GHAUtc -Value $ObservedAt
        if ($null -eq $obs) {
            [void]$errs.Add('invalid-observed-at')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $obsStr = ([datetime]$obs).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $errQ = Get-GHAArray $Raw 'errors'
        if (([bool]$errQ.found) -and (-not [bool]$errQ.nullvalue)) {
            if (([bool]$errQ.notarray) -or (@($errQ.items).Count -gt 0)) {
                [void]$errs.Add('graphql-errors')
                return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
            }
        }
        $data = Get-GHAValue $Raw 'data' $null
        if ($null -eq $data) {
            [void]$errs.Add('response-no-data')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $repoObj = Get-GHAValue $data 'repository' $null
        if ($null -eq $repoObj) {
            [void]$errs.Add('pr-not-found')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $nwo = Get-GHAValue $repoObj 'nameWithOwner' $null
        if ((-not ($nwo -is [string])) -or (-not (Test-GHARepoSyntax -Value ([string]$nwo)))) {
            [void]$errs.Add('repository-mismatch')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        if (([string]$nwo).Trim().ToLowerInvariant() -cne ([string]$Repository).Trim().ToLowerInvariant()) {
            [void]$errs.Add('repository-mismatch')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $pr = Get-GHAValue $repoObj 'pullRequest' $null
        if ($null -eq $pr) {
            [void]$errs.Add('pr-not-found')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $num = Get-GHAValue $pr 'number' $null
        if ((-not (Test-GHAIntRange -Value $num -Min 1 -Max 2147483647)) -or ([long]$num -ne [long]$PrNumber)) {
            [void]$errs.Add('pr-number-mismatch')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $stRaw = Get-GHAValue $pr 'state' $null
        if (-not ($stRaw -is [string])) {
            [void]$errs.Add('invalid-pr-state')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $st = ([string]$stRaw).Trim().ToUpperInvariant()
        if (($st -cne 'OPEN') -and ($st -cne 'CLOSED') -and ($st -cne 'MERGED')) {
            [void]$errs.Add('invalid-pr-state')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $headRaw = Get-GHAValue $pr 'headRefOid' $null
        if (-not (Test-GHASha40 -Value $headRaw)) {
            [void]$errs.Add('invalid-head-oid')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $headLow = ([string]$headRaw).Trim().ToLowerInvariant()
        $mgRaw = Get-GHAValue $pr 'mergeable' $null
        $mg = 'UNKNOWN'
        if ($null -eq $mgRaw) { $mg = 'UNKNOWN' }
        elseif ($mgRaw -is [string]) {
            $mgu = ([string]$mgRaw).Trim().ToUpperInvariant()
            if (($mgu -ceq 'MERGEABLE') -or ($mgu -ceq 'CONFLICTING') -or ($mgu -ceq 'UNKNOWN')) { $mg = $mgu }
            else {
                [void]$errs.Add('invalid-mergeable')
                return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
            }
        }
        else {
            [void]$errs.Add('invalid-mergeable')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $rvRaw = Get-GHAValue $pr 'reviewDecision' $null
        $rv = 'UNKNOWN'
        if ($null -eq $rvRaw) { $rv = 'UNKNOWN' }
        elseif ($rvRaw -is [string]) {
            $rvu = ([string]$rvRaw).Trim().ToUpperInvariant()
            if (($rvu -ceq 'APPROVED') -or ($rvu -ceq 'CHANGES_REQUESTED') -or ($rvu -ceq 'REVIEW_REQUIRED') -or ($rvu -ceq 'UNKNOWN')) { $rv = $rvu }
            else {
                [void]$errs.Add('invalid-review-decision')
                return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
            }
        }
        else {
            [void]$errs.Add('invalid-review-decision')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $commits = Get-GHAValue $pr 'commits' $null
        if ($null -eq $commits) {
            [void]$errs.Add('commits-missing')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $cnodesQ = Get-GHAArray $commits 'nodes'
        if ((-not [bool]$cnodesQ.found) -or [bool]$cnodesQ.notarray) {
            [void]$errs.Add('commits-not-array')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $cnodes = @($cnodesQ.items)
        if (@($cnodes).Count -eq 0) {
            [void]$errs.Add('commits-missing')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        if (@($cnodes).Count -gt 1) {
            [void]$errs.Add('commits-ambiguous')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $cmt = Get-GHAValue @($cnodes)[0] 'commit' $null
        if ($null -eq $cmt) {
            [void]$errs.Add('commit-null')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $coid = Get-GHAValue $cmt 'oid' $null
        if (-not (Test-GHASha40 -Value $coid)) {
            [void]$errs.Add('invalid-commit-oid')
            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
        }
        $commitLow = ([string]$coid).Trim().ToLowerInvariant()
        $checks = New-Object System.Collections.ArrayList
        $complete = $false
        $rollup = Get-GHAValue $cmt 'statusCheckRollup' $null
        if ($null -ne $rollup) {
            $rollObj = $null
            if (($rollup -is [array]) -or ($rollup -is [System.Collections.IList])) {
                $rollQ = Get-GHAArray $cmt 'statusCheckRollup'
                if ((-not [bool]$rollQ.found) -or [bool]$rollQ.notarray) {
                    [void]$errs.Add('rollup-not-array')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $rollArr = @($rollQ.items)
                if (@($rollArr).Count -gt 1) {
                    [void]$errs.Add('rollup-ambiguous')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                if (@($rollArr).Count -eq 1) { $rollObj = @($rollArr)[0] }
            }
            elseif (($rollup -is [System.Collections.IDictionary]) -or ($rollup -is [pscustomobject])) {
                $rollObj = $rollup
            }
            else {
                [void]$errs.Add('rollup-not-array')
                return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
            }
            if ($null -ne $rollObj) {
                $ctx = Get-GHAValue $rollObj 'contexts' $null
                if ($null -eq $ctx) {
                    [void]$errs.Add('contexts-missing')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $xnodesQ = Get-GHAArray $ctx 'nodes'
                if ((-not [bool]$xnodesQ.found) -or [bool]$xnodesQ.notarray) {
                    [void]$errs.Add('contexts-not-array')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $xnodes = @($xnodesQ.items)
                if (@($xnodes).Count -gt 100) {
                    [void]$errs.Add('checks-overflow')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $pi = Get-GHAValue $ctx 'pageInfo' $null
                if ($null -eq $pi) {
                    [void]$errs.Add('pageinfo-missing')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $hnp = Get-GHAValue $pi 'hasNextPage' $null
                if (-not ($hnp -is [bool])) {
                    [void]$errs.Add('pagenext-invalid')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                if ([bool]$hnp) {
                    [void]$errs.Add('pagination-incomplete')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                $tc = Get-GHAValue $ctx 'totalCount' $null
                if (-not (Test-GHAIntRange -Value $tc -Min 0 -Max 1000000)) {
                    [void]$errs.Add('totalcount-invalid')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                if ([long]$tc -ne [long]@($xnodes).Count) {
                    [void]$errs.Add('totalcount-mismatch')
                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                }
                foreach ($xn in @($xnodes)) {
                    $tn = Get-GHAValue $xn '__typename' $null
                    if (-not ($tn -is [string])) {
                        [void]$errs.Add('unknown-typename')
                        return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                    }
                    $tnu = ([string]$tn).Trim()
                    if ($tnu -ceq 'CheckRun') {
                        $nm = Get-GHAValue $xn 'name' $null
                        if ((-not ($nm -is [string])) -or [string]::IsNullOrWhiteSpace([string]$nm)) {
                            [void]$errs.Add('check-name-invalid')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $csu = Get-GHAValue $xn 'checkSuite' $null
                        $cco = Get-GHAValue $csu 'commit' $null
                        $coid2 = Get-GHAValue $cco 'oid' $null
                        if (-not (Test-GHASha40 -Value $coid2)) {
                            [void]$errs.Add('check-commit-missing')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $sRaw = Get-GHAValue $xn 'status' $null
                        if (-not ($sRaw -is [string])) {
                            [void]$errs.Add('invalid-check-status')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $su = ([string]$sRaw).Trim().ToUpperInvariant()
                        if (($su -cne 'QUEUED') -and ($su -cne 'IN_PROGRESS') -and ($su -cne 'COMPLETED')) {
                            [void]$errs.Add('invalid-check-status')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $conOut = $null
                        if ($su -ceq 'COMPLETED') {
                            $cRaw = Get-GHAValue $xn 'conclusion' $null
                            if ($null -ne $cRaw) {
                                if (-not ($cRaw -is [string])) {
                                    [void]$errs.Add('check-conclusion-invalid')
                                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                                }
                                $cu = ([string]$cRaw).Trim().ToUpperInvariant()
                                if (($cu -cne 'SUCCESS') -and ($cu -cne 'FAILURE') -and ($cu -cne 'NEUTRAL') -and ($cu -cne 'CANCELLED') -and ($cu -cne 'SKIPPED') -and ($cu -cne 'TIMED_OUT') -and ($cu -cne 'ACTION_REQUIRED')) {
                                    [void]$errs.Add('check-conclusion-invalid')
                                    return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                                }
                                $conOut = ([string]$cRaw).Trim().ToLowerInvariant()
                            }
                        }
                        $cleanRun = Convert-GHACheckName -Value ([string]$nm)
                        if ($null -eq $cleanRun) {
                            [void]$errs.Add('check-name-invalid')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        [void]$checks.Add([pscustomobject]@{
                            name = $cleanRun; head_sha = (([string]$coid2).Trim().ToLowerInvariant())
                            status = $su; conclusion = $conOut
                        })
                    }
                    elseif ($tnu -ceq 'StatusContext') {
                        $nm = Get-GHAValue $xn 'context' $null
                        if ((-not ($nm -is [string])) -or [string]::IsNullOrWhiteSpace([string]$nm)) {
                            [void]$errs.Add('check-name-invalid')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $sco = Get-GHAValue $xn 'commit' $null
                        $scoid = Get-GHAValue $sco 'oid' $null
                        if (-not (Test-GHASha40 -Value $scoid)) {
                            [void]$errs.Add('check-commit-missing')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $sRaw = Get-GHAValue $xn 'state' $null
                        if (-not ($sRaw -is [string])) {
                            [void]$errs.Add('invalid-context-state')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $sv = ([string]$sRaw).Trim().ToUpperInvariant()
                        $ms = ''; $mc = $null
                        if ($sv -ceq 'SUCCESS') { $ms = 'COMPLETED'; $mc = 'success' }
                        elseif (($sv -ceq 'PENDING') -or ($sv -ceq 'EXPECTED')) { $ms = 'IN_PROGRESS'; $mc = $null }
                        elseif (($sv -ceq 'FAILURE') -or ($sv -ceq 'ERROR')) { $ms = 'COMPLETED'; $mc = 'failure' }
                        else {
                            [void]$errs.Add('invalid-context-state')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        $cleanCtx = Convert-GHACheckName -Value ([string]$nm)
                        if ($null -eq $cleanCtx) {
                            [void]$errs.Add('check-name-invalid')
                            return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                        }
                        [void]$checks.Add([pscustomobject]@{
                            name = $cleanCtx; head_sha = (([string]$scoid).Trim().ToLowerInvariant())
                            status = $ms; conclusion = $mc
                        })
                    }
                    else {
                        [void]$errs.Add('unknown-typename')
                        return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
                    }
                }
                # checks_complete reports RESPONSE completeness (rollup present,
                # full single page observed: pageInfo present, hasNextPage
                # false, totalCount consistent). Per-check states stay in
                # checks[] for the pure Delivery readiness function, which
                # judges required checks and ignores extras.
                $complete = $true
            }
        }
        $snap = [pscustomobject]@{
            repository = (([string]$Repository).Trim().ToLowerInvariant())
            pr_number = [long]$PrNumber
            head_sha = $headLow
            commit_sha = $commitLow
            observed_at = $obsStr
            pr_state = $st
            mergeable = $mg
            review_decision = $rv
            checks_complete = [bool]$complete
            checks = @($checks)
        }
        return @{ ok = $true; snapshot = $snap; errors = [string[]]@() }
    }
    catch {
        try { [void]$errs.Add('normalizer-failed') } catch { }
        return @{ ok = $false; snapshot = $null; errors = [string[]]@($errs) }
    }
}

function Convert-GHAArgsToLine {
    param([string[]]$ArgumentList = @())
    try {
        $parts = New-Object System.Collections.ArrayList
        foreach ($a in @($ArgumentList)) {
            $s = [string]$a
            if ($s -eq '') { [void]$parts.Add('""'); continue }
            $needs = ($s.Contains(' ') -or $s.Contains("`t") -or $s.Contains('"'))
            if (-not $needs) { [void]$parts.Add($s); continue }
            $sb = New-Object Text.StringBuilder
            [void]$sb.Append('"')
            $slashes = 0
            foreach ($c in $s.ToCharArray()) {
                if ($c -eq '\') { $slashes = $slashes + 1 }
                elseif ($c -eq '"') {
                    $pad = New-Object String '\', ((2 * $slashes) + 1)
                    [void]$sb.Append($pad)
                    [void]$sb.Append('"')
                    $slashes = 0
                }
                else {
                    if ($slashes -gt 0) {
                        $pad = New-Object String '\', $slashes
                        [void]$sb.Append($pad)
                        $slashes = 0
                    }
                    [void]$sb.Append($c)
                }
            }
            if ($slashes -gt 0) {
                $pad = New-Object String '\', (2 * $slashes)
                [void]$sb.Append($pad)
            }
            [void]$sb.Append('"')
            [void]$parts.Add($sb.ToString())
        }
        return ($parts -join ' ')
    }
    catch { return '' }
}

function Invoke-GHAChildTransport {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutMs = 10000,
        [int]$OutputCapChars = 262144,
        [int]$DrainMs = 5000
    )
    $t0 = [datetime]::UtcNow
    $cap = 262144
    try { if ([int]$OutputCapChars -gt 0) { $cap = [int]$OutputCapChars } } catch { $cap = 262144 }
    $chunk = 4096
    $limit = $cap + 1
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (Convert-GHAArgsToLine -ArgumentList $ArgumentList)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() }
    catch {
        return @{ Started = $false; TimedOut = $false; DrainIncomplete = $false; StdoutTruncated = $false; StderrTruncated = $false; ExitCode = -3; Stdout = ''; Stderr = ''; ElapsedMs = [long]0 }
    }
    try { $p.StandardInput.Close() } catch { }
    # Bounded concurrent drain: both pipes are pumped in 4k blocks during
    # execution, retaining at most cap+1 chars per stream. The +1 char is
    # the overflow witness. Surplus bytes are discarded, never stored, so
    # a chatty child cannot grow memory. Deadline kills fail closed.
    $outBuf = New-Object char[] $chunk
    $errBuf = New-Object char[] $chunk
    $outSb = New-Object Text.StringBuilder
    $errSb = New-Object Text.StringBuilder
    $outLen = 0
    $errLen = 0
    $oTrunc = $false
    $eTrunc = $false
    $outEof = $false
    $errEof = $false
    $drainBad = $false
    $timedOut = $false
    $exited = $false
    $outTask = $null
    $errTask = $null
    try { $outTask = $p.StandardOutput.ReadAsync($outBuf, 0, $chunk) } catch { $outTask = $null; $drainBad = $true }
    try { $errTask = $p.StandardError.ReadAsync($errBuf, 0, $chunk) } catch { $errTask = $null; $drainBad = $true }
    $grace = [int]$DrainMs
    if ($grace -lt 0) { $grace = 0 }
    if ($grace -gt 10000) { $grace = 10000 }
    foreach ($iter in 0..16383) {
        try { $exited = $p.HasExited } catch { $exited = $false }
        if ($outEof -and $errEof) { break }
        if (($null -eq $outTask) -and ($null -eq $errTask)) { $drainBad = $true; break }
        $elapsedNow = [long]0
        try { $elapsedNow = [long]([datetime]::UtcNow - $t0).TotalMilliseconds } catch { $elapsedNow = [long]0 }
        $deadline = [long]$TimeoutMs
        if ($exited) { $deadline = [long]$TimeoutMs + [long]$grace }
        $remain = $deadline - $elapsedNow
        if ($remain -le 0) {
            if ($exited) { $drainBad = $true }
            else { $timedOut = $true }
            break
        }
        $slice = 200
        if ([long]$remain -lt [long]$slice) { $slice = [int]$remain }
        $warr = New-Object 'System.Threading.Tasks.Task[]' 2
        $wcount = 0
        if ((-not $outEof) -and ($null -ne $outTask)) { $warr[$wcount] = $outTask; $wcount = $wcount + 1 }
        if ((-not $errEof) -and ($null -ne $errTask)) { $warr[$wcount] = $errTask; $wcount = $wcount + 1 }
        if ($wcount -eq 0) { break }
        $idx = -1
        if ($wcount -eq 1) {
            $solo = $warr[0]
            $ok1 = $false
            try { $ok1 = $solo.Wait([int]$slice) } catch { $ok1 = $false; $drainBad = $true }
            if (-not $ok1) { continue }
            $idx = 0
        }
        else {
            try { $idx = [System.Threading.Tasks.Task]::WaitAny($warr, [int]$slice) } catch { $idx = -1; $drainBad = $true }
            if ($idx -lt 0) { continue }
            if ($idx -ge $wcount) { $drainBad = $true; continue }
        }
        $done = $warr[$idx]
        $isOut = $false
        try { $isOut = [object]::ReferenceEquals($done, $outTask) } catch { $isOut = $false }
        $got = 0
        $rdBad = $false
        try { $got = [int]$done.Result } catch { $rdBad = $true }
        if ($rdBad) {
            $drainBad = $true
            if ($isOut) { $outEof = $true } else { $errEof = $true }
            continue
        }
        if ($got -le 0) {
            if ($isOut) { $outEof = $true } else { $errEof = $true }
            continue
        }
        if ($isOut) {
            if ($outLen -lt $limit) {
                $take = $limit - $outLen
                if ($take -gt $got) { $take = $got }
                try { [void]$outSb.Append($outBuf, 0, [int]$take) } catch { $drainBad = $true }
                $outLen = $outLen + $take
                if ($got -gt $take) { $oTrunc = $true }
            }
            else { $oTrunc = $true }
            try { $outTask = $p.StandardOutput.ReadAsync($outBuf, 0, $chunk) } catch { $outTask = $null; $outEof = $true; $drainBad = $true }
        }
        else {
            if ($errLen -lt $limit) {
                $take = $limit - $errLen
                if ($take -gt $got) { $take = $got }
                try { [void]$errSb.Append($errBuf, 0, [int]$take) } catch { $drainBad = $true }
                $errLen = $errLen + $take
                if ($got -gt $take) { $eTrunc = $true }
            }
            else { $eTrunc = $true }
            try { $errTask = $p.StandardError.ReadAsync($errBuf, 0, $chunk) } catch { $errTask = $null; $errEof = $true; $drainBad = $true }
        }
    }
    if ((-not $outEof) -or (-not $errEof)) {
        try { $exited = $p.HasExited } catch { $exited = $false }
        if ($exited) { $drainBad = $true }
        else { $timedOut = $true }
    }
    if ($timedOut) { try { $p.Kill() } catch { } }
    try { [void]$p.WaitForExit(2000) } catch { }
    $elapsed = [long]0
    try { $elapsed = [long]([datetime]::UtcNow - $t0).TotalMilliseconds } catch { $elapsed = [long]0 }
    $o = ''
    $e = ''
    try { $o = $outSb.ToString() } catch { $o = ''; $drainBad = $true }
    try { $e = $errSb.ToString() } catch { $e = ''; $drainBad = $true }
    if ($null -eq $o) { $o = '' }
    if ($null -eq $e) { $e = '' }
    # Overflow witness counts: retained length above cap means truncated,
    # even when the stream ends exactly at cap+1 with no further bytes.
    if ($outLen -gt $cap) { $oTrunc = $true }
    if ($errLen -gt $cap) { $eTrunc = $true }
    $code = -1
    if (-not $timedOut) { try { $code = [int]$p.ExitCode } catch { $code = -1 } }
    try { $p.Close() } catch { }
    try { $p.Dispose() } catch { }
    return @{ Started = $true; TimedOut = [bool]$timedOut; DrainIncomplete = [bool]$drainBad; StdoutTruncated = [bool]$oTrunc; StderrTruncated = [bool]$eTrunc; ExitCode = [int]$code; Stdout = [string]$o; Stderr = [string]$e; ElapsedMs = [long]$elapsed }
}

# CLI entrypoint. Runs only when -Repository or -GraphQLSnapshotFile is
# supplied, so dot-sourcing this file as a library defines the functions
# above and does nothing else.
if ((-not [string]::IsNullOrWhiteSpace($Repository)) -or (-not [string]::IsNullOrWhiteSpace($GraphQLSnapshotFile))) {
    function Write-GHAEnvelope {
        param($Envelope)
        try {
            Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
        }
        catch {
            Write-Output '{"ok":false,"exit_reason":"encode-failed","errors":["encode-failed"]}'
        }
    }
    function New-GHAErrorEnvelope {
        param([string]$Reason, [string]$TransportName, [string]$Repo, [long]$Pr, [string]$Exp, [string[]]$Codes, $Detail = $null, [string]$Act = 'observe')
        $c = @($Reason)
        try { if ($null -ne $Codes -and @($Codes).Count -gt 0) { $c = [string[]]@($Codes) } } catch { $c = @($Reason) }
        return [pscustomobject]@{
            ok = $false; exit_reason = $Reason; action = $Act
            transport = $TransportName; invocation_proven = $false; transport_detail = $Detail
            repository = $Repo; pr_number = $Pr; expected_head_sha = $Exp
            observed_head_sha = ''; observed_at = ''
            snapshot = $null; readiness = $null; wait_request = $null
            errors = $c
            snapshot_only = $true; grants_authority = $false; merge_authority = $false
            done_approved = $false; resume_authorized = $false; kernel_mutated = $false
        }
    }
    try {
        if ($Action -cne 'observe') {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-action' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('invalid-action'))
            exit 2
        }
        $fixtureMode = (-not [string]::IsNullOrWhiteSpace($GraphQLSnapshotFile))
        if (-not (Test-GHARepoSyntax -Value ([string]$Repository))) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-repository' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('invalid-repository'))
            exit 2
        }
        $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        $parts = ([string]$Repository).Trim().Split('/')
        $ownerPart = ([string]$parts[0]).Trim()
        $namePart = ([string]$parts[1]).Trim()
        if ((-not (Test-GHANamePart -Value $ownerPart)) -or (-not (Test-GHANamePart -Value $namePart))) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-repository' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('invalid-repository'))
            exit 2
        }
        $prConv = Convert-GHAIntRange -Value $PrNumber -Min 1 -Max 2147483647
        if (-not [bool]$prConv.ok) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-pr-number' -TransportName 'none' -Repo $repoCanon -Pr ([long]0) -Exp '' -Codes @('invalid-pr-number'))
            exit 2
        }
        $prNum = [long]$prConv.value
        if (-not (Test-GHASha40 -Value $ExpectedHeadSha)) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-expected-sha' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp '' -Codes @('invalid-expected-sha'))
            exit 2
        }
        $expLow = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        $toConv = Convert-GHAIntRange -Value $TimeoutMs -Min 1 -Max 10000
        if (-not [bool]$toConv.ok) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-timeout' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-timeout'))
            exit 2
        }
        $timeoutInt = [int]$toConv.value
        $maConv = Convert-GHAIntRange -Value $MaxAgeSeconds -Min 1 -Max 3600
        if (-not [bool]$maConv.ok) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-max-age' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-max-age'))
            exit 2
        }
        $maxAge = [long]$maConv.value
        $ownerTrim = ([string]$Owner).Trim()
        if (($ownerTrim -ne '') -and (-not (Test-GHAOwner -Value $ownerTrim))) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-owner' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-owner'))
            exit 2
        }
        $policyObj = $null
        if (-not [string]::IsNullOrWhiteSpace($PolicyFile)) {
            $pf = ([string]$PolicyFile).Trim()
            $policyBad = $true
            try {
                if (Test-Path -LiteralPath $pf -PathType Leaf) {
                    $pfi = Get-Item -LiteralPath $pf
                    if ([long]$pfi.Length -gt 0 -and [long]$pfi.Length -le 262144) {
                        $policyObj = ConvertFrom-Json ([IO.File]::ReadAllText($pf, [Text.Encoding]::UTF8))
                        $policyBad = $false
                    }
                }
            }
            catch { $policyBad = $true }
            if ($policyBad) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-policy-file' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-policy-file'))
                exit 2
            }
        }
        $stampForced = ([string]$NowUtc).Trim()
        if (($stampForced -ne '') -and ($null -eq (Convert-GHAUtc -Value $stampForced))) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-now' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-now'))
            exit 2
        }
        $libDir = Join-Path $PSScriptRoot 'lib'
        $deliveryLib = Join-Path $libDir 'OrchestrationDelivery.ps1'
        $wiringLib = Join-Path $libDir 'OrchestrationAutonomyWiring.ps1'
        if ((-not (Test-Path -LiteralPath $deliveryLib -PathType Leaf)) -or (-not (Test-Path -LiteralPath $wiringLib -PathType Leaf))) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'lib-unavailable' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('lib-unavailable'))
            exit 1
        }
        $rawObj = $null
        $transportName = 'gh-query'
        $transportDetail = $null
        if ($fixtureMode) {
            $transportName = 'fixture-declared'
            $fx = ([string]$GraphQLSnapshotFile).Trim()
            $okFile = $false
            try {
                if (Test-Path -LiteralPath $fx -PathType Leaf) {
                    $fxi = Get-Item -LiteralPath $fx
                    if ([long]$fxi.Length -gt 0 -and [long]$fxi.Length -le 262144) { $okFile = $true }
                }
            }
            catch { $okFile = $false }
            if (-not $okFile) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'invalid-snapshot-file' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-snapshot-file'))
                exit 2
            }
            try {
                $rawText = [IO.File]::ReadAllText($fx, [Text.Encoding]::UTF8)
                if ([string]::IsNullOrWhiteSpace($rawText)) { throw 'empty fixture' }
                $rawObj = ConvertFrom-Json $rawText
            }
            catch {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'snapshot-unparseable' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('snapshot-unparseable'))
                exit 1
            }
        }
        else {
            $ghCmd = $null
            try { $ghCmd = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghCmd = $null }
            if (($null -eq $ghCmd) -or [string]::IsNullOrWhiteSpace([string]$ghCmd.Source)) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'gh-not-found' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('gh-not-found'))
                exit 1
            }
            $ghArgs = Get-GHAGhArgs -OwnerPart $ownerPart -NamePart $namePart -Number $prNum
            $child = $null
            try {
                $child = Invoke-GHAChildTransport -FilePath ([string]$ghCmd.Source) -ArgumentList $ghArgs -TimeoutMs $timeoutInt -OutputCapChars 262144
            }
            catch { $child = $null }
            if ($null -eq $child) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'child-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-failed'))
                exit 1
            }
            $elapsedChild = [long]0
            $exitChild = -1
            $toChild = $false
            try { $elapsedChild = [long]$child.ElapsedMs } catch { $elapsedChild = [long]0 }
            try { $exitChild = [int]$child.ExitCode } catch { $exitChild = -1 }
            try { $toChild = [bool]$child.TimedOut } catch { $toChild = $false }
            $transportDetail = [pscustomobject]@{ exit_code = $exitChild; timed_out = $toChild; elapsed_ms = $elapsedChild }
            if (-not [bool]$child.Started) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'child-not-started' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-not-started') -Detail $transportDetail)
                exit 1
            }
            if ($toChild) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'child-timeout' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-timeout') -Detail $transportDetail)
                exit 1
            }
            if ([bool]$child.DrainIncomplete) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'drain-incomplete' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('drain-incomplete') -Detail $transportDetail)
                exit 1
            }
            if ([bool]$child.StdoutTruncated) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'stdout-truncated' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('stdout-truncated') -Detail $transportDetail)
                exit 1
            }
            if ($exitChild -ne 0) {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'gh-nonzero-exit' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('gh-nonzero-exit') -Detail $transportDetail)
                exit 1
            }
            try {
                if ([string]::IsNullOrWhiteSpace([string]$child.Stdout)) { throw 'empty stdout' }
                $rawObj = ConvertFrom-Json ([string]$child.Stdout)
            }
            catch {
                Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'snapshot-unparseable' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('snapshot-unparseable') -Detail $transportDetail)
                exit 1
            }
        }
        $stamp = $stampForced
        if ($stamp -eq '') {
            $stamp = ([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $norm = Convert-GHARawToSnapshot -Raw $rawObj -Repository $repoCanon -PrNumber $prNum -ObservedAt $stamp
        if (-not [bool]$norm.ok) {
            $ncodes = @('schema-failed')
            try { if ($null -ne $norm.errors -and @($norm.errors).Count -gt 0) { $ncodes = [string[]]@($norm.errors) } } catch { $ncodes = @('schema-failed') }
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason ([string]$ncodes[0]) -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes $ncodes -Detail $transportDetail)
            exit 1
        }
        $snap = $norm.snapshot
        . $deliveryLib
        . $wiringLib
        $rdy = $null
        try {
            $rdy = Get-OrchestrationGitHubReadiness -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expLow -Snapshot $snap -Policy $policyObj -NowUtc $stamp -MaxAgeSeconds $maxAge
        }
        catch { $rdy = $null }
        if ($null -eq $rdy) {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'readiness-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('readiness-failed') -Detail $transportDetail)
            exit 1
        }
        $rdyVal = ([string]$rdy.readiness)
        $rdyOk = [bool]$rdy.ok
        $rdyReasons = @()
        try { if ($null -ne $rdy.reasons) { $rdyReasons = [string[]]@($rdy.reasons) } } catch { $rdyReasons = @() }
        $errOut = @()
        if (($rdyVal -cne 'READY_FOR_RESUME') -or (-not $rdyOk)) { $errOut = @($rdyReasons) }
        $wr = $null
        if ($ownerTrim -ne '') {
            try {
                $wr = New-OrchestrationGitHubWaitRequest -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expLow -Owner $ownerTrim
            }
            catch { $wr = $null }
        }
        Write-GHAEnvelope ([pscustomobject]@{
            ok = $true; exit_reason = 'observed'; action = 'observe'
            transport = $transportName; invocation_proven = $false; transport_detail = $transportDetail
            repository = $repoCanon; pr_number = $prNum; expected_head_sha = $expLow
            observed_head_sha = ([string]$snap.head_sha); observed_at = ([string]$snap.observed_at)
            snapshot = $snap
            readiness = ([pscustomobject]@{ ok = $rdyOk; value = $rdyVal; reasons = [string[]]$rdyReasons })
            wait_request = $wr
            errors = [string[]]$errOut
            snapshot_only = $true; grants_authority = $false; merge_authority = $false
            done_approved = $false; resume_authorized = $false; kernel_mutated = $false
        })
        exit 0
    }
    catch {
        try {
            Write-GHAEnvelope (New-GHAErrorEnvelope -Reason 'internal-error' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('internal-error'))
        }
        catch { }
        exit 1
    }
}
