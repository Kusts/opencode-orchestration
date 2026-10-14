# github-await.tests.ps1 -- ORFS-CONT-F3-CLI thin observe-only CLI.
# Custom PS 5.1 / PS7 suite, no Pester. Fixtures in owned TEMP. Offline by
# default; live network only when ORFS_LIVE_GITHUB=1 (opt-in probe, PR 88).
# Covers: strict arg validation (exit 2), fixed GraphQL query (no mutation),
# no retry/pagination/cache/timer/watcher/daemon lifecycle, StatusContext
# mapping, CheckRun exact enums, null rollup/review normalization, schema
# fail-closed codes (exit 1), head-mismatch STALE (exit 0), all-green READY
# with zero authority, wait_request only with explicit owner, no raw GH
# leakage (canary), envelope key stability. ASCII only.
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')
$ErrorActionPreference = 'Stop'
$script:cli = Join-Path $PSScriptRoot 'github-await.ps1'
. $script:cli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
# --- dot-source safety: helpers exist, nothing executed on load.
Assert-That ($null -ne (Get-Command Convert-GHARawToSnapshot -ErrorAction SilentlyContinue)) 'dot-source exposes normalizer'
Assert-That ($null -ne (Get-Command Get-GHAFixedQuery -ErrorAction SilentlyContinue)) 'dot-source exposes fixed query'
Assert-That ($null -ne (Get-Command Get-GHAGhArgs -ErrorAction SilentlyContinue)) 'dot-source exposes args builder'
Assert-That ($null -ne (Get-Command Convert-GHACheckName -ErrorAction SilentlyContinue)) 'dot-source exposes check-name sanitizer'
Assert-That ($null -ne (Get-Command Invoke-GHAChildTransport -ErrorAction SilentlyContinue)) 'dot-source exposes concurrent child transport'
Assert-That ($null -ne (Get-Command Convert-GHAArgsToLine -ErrorAction SilentlyContinue)) 'dot-source exposes argv quoting helper'
# --- fixed query: single read-only query, official fields, no mutation.
$q = Get-GHAFixedQuery
Assert-That (($q -is [string]) -and ($q.Length -gt 50)) 'fixed query is a non-trivial string'
Assert-That ($q -cmatch '\Aquery \(\$owner: String!, \$name: String!, \$number: Int!\)') 'fixed query signature is exact'
Assert-That (($q -cnotmatch 'mutation') -and ($q -cnotmatch 'delete') -and ($q -cnotmatch 'merge\(Strict')) 'fixed query has no mutation'
foreach ($field in @('nameWithOwner', 'pullRequest', 'headRefOid', 'mergeable', 'reviewDecision', 'statusCheckRollup', 'contexts(first: 100)', '__typename', 'checkSuite', 'pageInfo', 'hasNextPage', 'endCursor', 'totalCount')) {
    Assert-That ($q.Contains($field)) ('fixed query contains ' + $field)
}
$a = Get-GHAGhArgs -OwnerPart 'acme' -NamePart 'widgets' -Number 42
Assert-That (@($a).Count -eq 12) 'gh args have exactly 12 elements'
Assert-That (([string]$a[0] -ceq 'api') -and ([string]$a[1] -ceq 'graphql')) 'gh args use api graphql (read-only)'
Assert-That (([string]$a[2] -ceq '--hostname') -and ([string]$a[3] -ceq 'github.com')) 'gh args pin hostname github.com'
Assert-That (([string]$a[4] -ceq '-f') -and ([string]$a[5]).StartsWith('query=')) 'gh args pass query via -f'
Assert-That (([string]$a[6] -ceq '-F') -and ([string]$a[8] -ceq '-F') -and ([string]$a[10] -ceq '-F')) 'gh args pass values via -F only'
Assert-That (([string]$a[7] -ceq 'owner=acme') -and ([string]$a[9] -ceq 'name=widgets') -and ([string]$a[11] -ceq 'number=42')) 'gh -F values bind owner/name/number exactly'
Assert-That (([string]$a[5] -ceq ('query=' + $q))) 'gh query arg equals fixed query (no interpolation)'
Assert-That ((([string]$a -join ' ') -cnotmatch 'mutation')) 'gh args carry no mutation'
# --- no lifecycle: no timer, sleep, loop-poll, retry, watcher, daemon, waits, grants.
$cliText = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
foreach ($bad in @('Start-Sleep', 'System.Timers', 'Register-', 'while\s*\(', 'for\s*\(', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Start-Process', 'Complete-Orchestration', 'Unblock-', 'New-Service', 'Start-Service', 'FileSystemWatcher', ' mutation', 'gh pr create', 'gh pr merge', 'gh pr comment', 'gh pr edit', 'gh pr close', 'gh pr reopen', 'gh pr ready', 'gh pr review', '--method POST', '--method PUT', '--method PATCH', '--method DELETE', 'grants_authority = \$true', 'resume_authorized = \$true', 'kernel_mutated = \$true', 'GH_TOKEN', 'GITHUB_TOKEN')) {
    Assert-That ($cliText -cnotmatch $bad) ('CLI has no lifecycle/mutation/secret pattern: ' + $bad)
}
# --- F1: CLI performs no deletion; suite cleanup is confined to its owned root.
Assert-That ($cliText -cnotmatch 'Remove-Item') 'CLI performs no deletion (observe-only, no cleanup)'
Assert-That ($cliText -cnotmatch 'ghcheck') 'CLI has no absolute-path cleanup reference'
Assert-That ($cliText -cnotmatch 'C:\\Users') 'CLI has no machine-specific path'
Assert-That ($cliText -cnotmatch 'SpikeProcess') 'CLI uses its own concurrent transport (no shared-lib pipe)'
Assert-That ($cliText -cnotmatch 'Invoke-SpikeChild') 'CLI never calls the sequential shared-lib child'
# --- strict validators (pure, no coercion at this layer).
Assert-That (Test-GHARepoSyntax -Value 'acme/widgets') 'repo syntax accepts owner/repo'
Assert-That (-not (Test-GHARepoSyntax -Value 'bad repo!')) 'repo syntax rejects spaces/bang'
Assert-That (-not (Test-GHARepoSyntax -Value 'a/b/c')) 'repo syntax rejects two slashes'
Assert-That (-not (Test-GHARepoSyntax -Value (('a' * 100) + '/' + ('b' * 100)))) 'repo syntax rejects length over 200'
Assert-That (Test-GHASha40 -Value ('a' * 40)) 'sha40 accepts 40 hex'
Assert-That (-not (Test-GHASha40 -Value '')) 'sha40 rejects empty (explicit required, never auto)'
Assert-That (-not (Test-GHASha40 -Value ('z' * 40))) 'sha40 rejects non-hex'
Assert-That (Test-GHAIntRange -Value 42 -Min 1 -Max 2147483647) 'int range accepts 42'
Assert-That (-not (Test-GHAIntRange -Value '42' -Min 1 -Max 2147483647)) 'int range rejects string (strict)'
Assert-That (-not (Test-GHAIntRange -Value 0 -Min 1 -Max 2147483647)) 'int range rejects 0'
Assert-That (-not (Test-GHAIntRange -Value 2147483648 -Min 1 -Max 2147483647)) 'int range rejects 2^31'
Assert-That (-not (Test-GHAIntRange -Value 4.5 -Min 1 -Max 10000)) 'int range rejects double'
Assert-That (-not (Test-GHAIntRange -Value $true -Min 1 -Max 10000)) 'int range rejects bool'
$c42 = Convert-GHAIntRange -Value '42' -Min 1 -Max 2147483647
Assert-That (([bool]$c42.ok) -and ([long]$c42.value -eq 42)) 'CLI boundary coerces digit string 42'
Assert-That (-not [bool](Convert-GHAIntRange -Value '4x2' -Min 1 -Max 2147483647).ok) 'CLI boundary rejects 4x2'
Assert-That (-not [bool](Convert-GHAIntRange -Value '0' -Min 1 -Max 10000).ok) 'CLI boundary rejects timeout 0'
Assert-That (-not [bool](Convert-GHAIntRange -Value '10001' -Min 1 -Max 10000).ok) 'CLI boundary rejects timeout 10001'
Assert-That (Test-GHAOwner -Value 'kernel-owner_1:2') 'owner charset accepts word chars dot colon'
Assert-That (-not (Test-GHAOwner -Value 'a b')) 'owner rejects space'
# --- fixture builders (raw GraphQL shape, as gh api graphql returns).
$script:GH_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:GH_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:GH_REPO = 'acme/widgets'
$script:GH_PR = 42
$script:GH_NOW = '2026-10-10T12:02:00Z'
function New-GHARunNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{
        __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion
        checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } }
    }
}
function New-GHAStatusNode {
    param([string]$Context, [string]$State, [string]$Sha)
    return [pscustomobject]@{
        __typename = 'StatusContext'; context = $Context; state = $State
        commit = [pscustomobject]@{ oid = $Sha }
    }
}
function New-GHARaw {
    param($Nodes, [string]$Head = $script:GH_A, [string]$Commit = $script:GH_A, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'APPROVED', $Total = $null, $Next = $false, $Pi = $true)
    $totalCount = @($Nodes).Count
    if ($null -ne $Total) { $totalCount = $Total }
    $pageInfo = $null
    if ($Pi) { $pageInfo = [pscustomobject]@{ hasNextPage = $Next; endCursor = 'CURSOR1' } }
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = $pageInfo; totalCount = $totalCount } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{
        nameWithOwner = $script:GH_REPO
        pullRequest = [pscustomobject]@{
            number = $script:GH_PR; state = $State; headRefOid = $Head
            mergeable = $Merge; reviewDecision = $Review
            commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) }
        }
    } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
# --- normalizer: all-green mix of CheckRun + StatusContext.
$greenNodes = @(
    (New-GHARunNode 'CI (ps51)' 'COMPLETED' 'SUCCESS' $script:GH_A),
    (New-GHAStatusNode 'ci/legacy' 'SUCCESS' $script:GH_A)
)
$n = Convert-GHARawToSnapshot -Raw (New-GHARaw $greenNodes) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That ([bool]$n.ok) 'normalizer accepts all-green mix'
Assert-That (([string]$n.snapshot.head_sha -ceq $script:GH_A) -and ([string]$n.snapshot.commit_sha -ceq $script:GH_A)) 'snapshot binds head and commit sha'
Assert-That (([string]$n.snapshot.observed_at -ceq $script:GH_NOW)) 'snapshot echoes forced observed_at'
Assert-That (([string]$n.snapshot.pr_state -ceq 'OPEN') -and ([string]$n.snapshot.mergeable -ceq 'MERGEABLE') -and ([string]$n.snapshot.review_decision -ceq 'APPROVED')) 'snapshot enums normalize upper'
Assert-That ([bool]$n.snapshot.checks_complete) 'all completed => checks_complete true'
Assert-That (@($n.snapshot.checks).Count -eq 2) 'snapshot keeps both checks'
Assert-That (([string]$n.snapshot.checks[0].conclusion -ceq 'success') -and ([string]$n.snapshot.checks[1].conclusion -ceq 'success')) 'conclusions normalize lower success'
Assert-That (([string]$n.snapshot.checks[0].status -ceq 'COMPLETED') -and ([string]$n.snapshot.checks[1].status -ceq 'COMPLETED')) 'statuses normalize upper'
# --- canonical API shape: statusCheckRollup as a single object (gh api
# graphql returns an object, not an array; observed live on PR 88).
$rawObjRoll = New-GHARaw $greenNodes
$rawObjRoll.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup = $rawObjRoll.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup[0]
$on = Convert-GHARawToSnapshot -Raw $rawObjRoll -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$on.ok) -and (@($on.snapshot.checks).Count -eq 2)) 'object-form rollup accepted (canonical gh shape)'
$rawScalarRoll = New-GHARaw $greenNodes
$rawScalarRoll.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup = 'nope'
$sn = Convert-GHARawToSnapshot -Raw $rawScalarRoll -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$sn.ok) -and (@($sn.errors) -contains 'rollup-not-array'))) 'scalar rollup => rollup-not-array'
$mapCases = @(
    @('PENDING', 'IN_PROGRESS', $null), @('EXPECTED', 'IN_PROGRESS', $null),
    @('FAILURE', 'COMPLETED', 'failure'), @('ERROR', 'COMPLETED', 'failure')
)
foreach ($mc in $mapCases) {
    $mn = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHAStatusNode 'x' $mc[0] $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
    Assert-That (([bool]$mn.ok) -and ([string]$mn.snapshot.checks[0].status -ceq $mc[1]) -and ($mn.snapshot.checks[0].conclusion -ceq $mc[2])) ('statuscontext maps ' + $mc[0])
}
$pm = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHAStatusNode 'x' 'PENDING' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$pm.ok) -and ([bool]$pm.snapshot.checks_complete)) 'pending context => response complete (state judged by pure Delivery, not by snapshot)'
Assert-That (([string]$pm.snapshot.checks[0].status -ceq 'IN_PROGRESS') -and ($null -eq $pm.snapshot.checks[0].conclusion)) 'pending state preserved in checks[] for Delivery'
# --- null rollup => complete false, checks empty, still ok.
$rawNull = New-GHARaw @()
$rawNull.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup = $null
$zn = Convert-GHARawToSnapshot -Raw $rawNull -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$zn.ok) -and (-not [bool]$zn.snapshot.checks_complete) -and (@($zn.snapshot.checks).Count -eq 0)) 'null rollup => complete false checks empty'
# --- null reviewDecision => UNKNOWN.
$rawRv = New-GHARaw $greenNodes
$rawRv.data.repository.pullRequest.reviewDecision = $null
$rn = Convert-GHARawToSnapshot -Raw $rawRv -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$rn.ok) -and ([string]$rn.snapshot.review_decision -ceq 'UNKNOWN')) 'null reviewDecision => UNKNOWN'
# --- null mergeable => UNKNOWN.
$rawMg = New-GHARaw $greenNodes
$rawMg.data.repository.pullRequest.mergeable = $null
$gn = Convert-GHARawToSnapshot -Raw $rawMg -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$gn.ok) -and ([string]$gn.snapshot.mergeable -ceq 'UNKNOWN')) 'null mergeable => UNKNOWN'
# --- schema fail-closed codes.
$rawNoPr = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:GH_REPO; pullRequest = $null } } }
$fn = Convert-GHARawToSnapshot -Raw $rawNoPr -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$fn.ok) -and (@($fn.errors) -contains 'pr-not-found'))) 'missing PR => pr-not-found'
$rawNoCommit = New-GHARaw $greenNodes
$rawNoCommit.data.repository.pullRequest.commits.nodes[0].commit = $null
$cn = Convert-GHARawToSnapshot -Raw $rawNoCommit -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$cn.ok) -and (@($cn.errors) -contains 'commit-null'))) 'nullable commit => commit-null'
$rawNotArr = New-GHARaw $greenNodes
$rawNotArr.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup[0].contexts.nodes = 'nope'
$na = Convert-GHARawToSnapshot -Raw $rawNotArr -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$na.ok) -and (@($na.errors) -contains 'contexts-not-array'))) 'collection not array => contexts-not-array'
$rawNoPi = New-GHARaw $greenNodes -Pi $false
$pi = Convert-GHARawToSnapshot -Raw $rawNoPi -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$pi.ok) -and (@($pi.errors) -contains 'pageinfo-missing'))) 'missing pageInfo => pageinfo-missing'
$rawNext = New-GHARaw $greenNodes -Next $true
$nx = Convert-GHARawToSnapshot -Raw $rawNext -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$nx.ok) -and (@($nx.errors) -contains 'pagination-incomplete'))) 'hasNextPage true => pagination-incomplete'
$rawTc = New-GHARaw $greenNodes -Total 99
$tc = Convert-GHARawToSnapshot -Raw $rawTc -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$tc.ok) -and (@($tc.errors) -contains 'totalcount-mismatch'))) 'totalCount mismatch => totalcount-mismatch'
$rawTyp = New-GHARaw @([pscustomobject]@{ __typename = 'WeirdFutureType'; name = 'x' })
$ty = Convert-GHARawToSnapshot -Raw $rawTyp -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$ty.ok) -and (@($ty.errors) -contains 'unknown-typename'))) 'unknown __typename => unknown-typename'
$rawBadSt = New-GHARaw @((New-GHARunNode 'CI (ps51)' 'WAITING' 'SUCCESS' $script:GH_A))
$bs = Convert-GHARawToSnapshot -Raw $rawBadSt -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$bs.ok) -and (@($bs.errors) -contains 'invalid-check-status'))) 'CheckRun status outside GitHub COMPLETED set => invalid-check-status'
$rawNoHead = New-GHARaw @((New-GHAStatusNode 'x' 'SUCCESS' 'zzz'))
$nh = Convert-GHARawToSnapshot -Raw $rawNoHead -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$nh.ok) -and (@($nh.errors) -contains 'check-commit-missing'))) 'per-check commit missing => check-commit-missing (head binding required)'
# --- child engine (same family as parent): CLI exit codes + envelopes.
$script:childExe = ''
$script:childIsCore = $false
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
    $found = $null
    try { $found = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $found = $null }
    if (($null -ne $found) -and (-not [string]::IsNullOrWhiteSpace([string]$found.Source))) {
        $script:childExe = [string]$found.Source
        $script:childIsCore = $true
    }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) {
    $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $script:childExe = $psExe
    $script:childIsCore = $false
}
if ([string]::IsNullOrWhiteSpace($script:childExe)) { throw 'FAIL: engine unavailable (neither pwsh nor powershell resolved)' }
$script:passed++
Write-Output ('engine: ' + $script:childExe)
function Invoke-GHAChild {
    param([string[]]$CliArgs = @())
    $out = & $script:childExe -NoProfile -File $script:cli @CliArgs 2>$null
    $code = $LASTEXITCODE
    $text = ''
    if ($null -ne $out) { $text = ($out -join "`n").Trim() }
    $env = $null
    try { if (-not [string]::IsNullOrWhiteSpace($text)) { $env = ConvertFrom-Json $text } } catch { $env = $null }
    return @{ code = $code; text = $text; env = $env }
}
# exit 2 cases.
$r = Invoke-GHAChild @('-Action', 'watch', '-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-action')) 'CLI rejects non-observe action with exit 2'
$r = Invoke-GHAChild @('-Repository', 'bad repo!', '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-repository')) 'CLI rejects bad repository with exit 2'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '0', '-ExpectedHeadSha', $script:GH_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-pr-number')) 'CLI rejects PR 0 with exit 2'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', 'zzz')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-expected-sha')) 'CLI rejects bad sha with exit 2'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-ExpectedHeadSha', $script:GH_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-pr-number')) 'CLI requires explicit PR (never auto)'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-expected-sha')) 'CLI requires explicit ExpectedHeadSha (never auto-accepts observed HEAD)'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-TimeoutMs', '0')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-timeout')) 'CLI rejects TimeoutMs 0 with exit 2'
$r = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-TimeoutMs', '10001')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-timeout')) 'CLI rejects TimeoutMs 10001 with exit 2'
# --- offline e2e via fixture files in owned TEMP.
$script:base = Join-Path ([IO.Path]::GetTempPath()) ('gha-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:base -Force | Out-Null
function Write-GHAFixture {
    param($Raw, [string]$Name)
    $p = Join-Path $script:base $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
$script:policyChecks = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
function New-GHAPolicyGreen {
    $out = @()
    foreach ($cn2 in $script:policyChecks) { $out += @(New-GHARunNode $cn2 'COMPLETED' 'SUCCESS' $script:GH_A) }
    return $out
}
# --- F3: required green + one pending EXTRA => response still complete.
$mixNodes = @((New-GHAPolicyGreen) + @((New-GHARunNode 'extra-flaky' 'IN_PROGRESS' $null $script:GH_A)))
$mx = Convert-GHARawToSnapshot -Raw (New-GHARaw $mixNodes) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$mx.ok) -and ([bool]$mx.snapshot.checks_complete)) 'pending extra => checks_complete true (response completeness, not all-COMPLETED)'
Assert-That (@($mx.snapshot.checks).Count -eq 6) 'snapshot keeps required checks plus the pending extra'
# --- F2: GraphQL errors fail closed with a stable code, never remote content.
$rawErr = New-GHARaw (New-GHAPolicyGreen)
$rawErr | Add-Member -NotePropertyName 'errors' -NotePropertyValue @([pscustomobject]@{ message = 'SENSITIVE-REMOTE-9f8e'; type = 'X' }) -Force
$eg = Convert-GHARawToSnapshot -Raw $rawErr -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$eg.ok) -and (@($eg.errors) -contains 'graphql-errors'))) 'non-empty errors => graphql-errors fail-closed'
Assert-That (((ConvertTo-Json -InputObject $eg -Depth 10 -Compress) -cnotmatch 'SENSITIVE-REMOTE-9f8e')) 'error envelope never echoes remote content'
$rawErrBad = New-GHARaw (New-GHAPolicyGreen)
$rawErrBad | Add-Member -NotePropertyName 'errors' -NotePropertyValue 'nope' -Force
$eb = Convert-GHARawToSnapshot -Raw $rawErrBad -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$eb.ok) -and (@($eb.errors) -contains 'graphql-errors'))) 'malformed errors => graphql-errors fail-closed'
$rawErrEmpty = New-GHARaw (New-GHAPolicyGreen)
$rawErrEmpty | Add-Member -NotePropertyName 'errors' -NotePropertyValue @() -Force
$ee = Convert-GHARawToSnapshot -Raw $rawErrEmpty -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That ([bool]$ee.ok) 'empty errors array => no failure'
# --- F4: check names are bounded (200) and sanitized (no controls, no secret echo).
$longName = ('n' * 300)
$ln = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $longName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$ln.ok) -and (@($ln.errors) -contains 'check-name-invalid'))) '300-char check name rejected (never truncated into required)'
$skName = 'extra sk-SYNTHETICSECRET-7f3a91c2-tail'
$sn4 = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $skName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$sn4.ok) -and (((ConvertTo-Json -InputObject $sn4.snapshot -Depth 10 -Compress) -cnotmatch 'sk-SYNTHETICSECRET-7f3a91c2'))) 'secret-like check name redacted from snapshot'
$canary = 'CANARY-9f8e7d6c5b4a3948'
$rawGreen = New-GHARaw (New-GHAPolicyGreen)
$rawGreen.data | Add-Member -NotePropertyName 'note' -NotePropertyValue $canary -Force
$fxGreen = Write-GHAFixture $rawGreen 'green.json'
$g = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxGreen, '-NowUtc', $script:GH_NOW)
Assert-That ([int]$g.code -eq 0) 'fixture all-green exits 0'
Assert-That (([bool]$g.env.ok) -and ([string]$g.env.exit_reason -ceq 'observed')) 'fixture all-green envelope observed'
Assert-That (([string]$g.env.transport -ceq 'fixture-declared') -and (-not [bool]$g.env.invocation_proven)) 'fixture provenance declared, invocation not proven'
Assert-That (([string]$g.env.readiness.value -ceq 'READY_FOR_RESUME') -and (@($g.env.errors).Count -eq 0)) 'fixture all-green readiness READY_FOR_RESUME, no errors'
Assert-That ((-not [bool]$g.env.grants_authority) -and (-not [bool]$g.env.merge_authority) -and (-not [bool]$g.env.done_approved) -and (-not [bool]$g.env.resume_authorized) -and (-not [bool]$g.env.kernel_mutated) -and ([bool]$g.env.snapshot_only)) 'all-green grants zero authority (observe is not merge authority)'
Assert-That ($null -eq $g.env.wait_request) 'no owner => no wait_request'
Assert-That (($g.text -cnotmatch $canary) -and ($g.text -cnotmatch 'stdout') -and ($g.text -cnotmatch 'stderr')) 'no raw GH leakage: canary and stream names absent'
$wantKeys = @('ok', 'exit_reason', 'action', 'transport', 'invocation_proven', 'transport_detail', 'repository', 'pr_number', 'expected_head_sha', 'observed_head_sha', 'observed_at', 'snapshot', 'readiness', 'wait_request', 'errors', 'snapshot_only', 'grants_authority', 'merge_authority', 'done_approved', 'resume_authorized', 'kernel_mutated')
$gotKeys = @()
foreach ($pp in @($g.env.PSObject.Properties)) { $gotKeys += @([string]$pp.Name) }
foreach ($wk in $wantKeys) { Assert-That ($gotKeys -contains $wk) ('envelope carries key ' + $wk) }
foreach ($gk in $gotKeys) { Assert-That ($wantKeys -contains $gk) ('envelope carries no extra key: ' + $gk) }
$gw = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxGreen, '-NowUtc', $script:GH_NOW, '-Owner', 'kernel-owner')
Assert-That (([int]$gw.code -eq 0) -and ($null -ne $gw.env.wait_request)) 'explicit owner => wait_request included'
Assert-That (([string]$gw.env.wait_request.WaitType -ceq 'external_dependency') -and ([string]$gw.env.wait_request.WaitDependencyId -ceq ('github-ci:v1:' + $script:GH_REPO + ':42:' + $script:GH_A))) 'wait_request is request-only with 4 kernel parameters'
Assert-That ((-not [bool]$gw.env.wait_request.kernel_mutated) -and (-not [bool]$gw.env.wait_request.grants_authority)) 'wait_request mutates nothing and grants nothing'
$fxStale = Write-GHAFixture (New-GHARaw (New-GHAPolicyGreen)) 'stale.json'
$st = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_B, '-GraphQLSnapshotFile', $fxStale, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$st.code -eq 0) -and ([string]$st.env.readiness.value -ceq 'STALE') -and (@($st.env.errors) -contains 'head-mismatch')) 'replay old head => exit 0 STALE head-mismatch (valid observation, not authorization)'
$fxNext = Write-GHAFixture (New-GHARaw (New-GHAPolicyGreen) -Next $true) 'next.json'
$nx2 = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxNext, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$nx2.code -eq 1) -and ([string]$nx2.env.exit_reason -ceq 'pagination-incomplete')) 'pagination without support => exit 1, no optimistic readiness'
$fxNoPr = Write-GHAFixture ([pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:GH_REPO; pullRequest = $null } } }) 'nopr.json'
$np = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxNoPr, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$np.code -eq 1) -and ([string]$np.env.exit_reason -ceq 'pr-not-found')) 'missing PR => exit 1 pr-not-found'
$np2 = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', (Join-Path $script:base 'absent.json'), '-NowUtc', $script:GH_NOW)
Assert-That (([int]$np2.code -eq 2) -and ([string]$np2.env.exit_reason -ceq 'invalid-snapshot-file')) 'absent fixture file => exit 2'
# --- F2 e2e: green data plus GraphQL errors => exit 1, stable code, no echo.
$rawErrFx = New-GHARaw (New-GHAPolicyGreen)
$rawErrFx | Add-Member -NotePropertyName 'errors' -NotePropertyValue @([pscustomobject]@{ message = 'SENSITIVE-REMOTE-GRAPHQL-4d2c'; type = 'X' }) -Force
$fxErr = Write-GHAFixture $rawErrFx 'errors.json'
$er = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxErr, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$er.code -eq 1) -and ([string]$er.env.exit_reason -ceq 'graphql-errors')) 'fixture data-green plus errors => exit 1 graphql-errors (fail-closed, no optimistic readiness)'
Assert-That ($er.text -cnotmatch 'SENSITIVE-REMOTE-GRAPHQL-4d2c') 'remote error detail never echoed to stdout'
# --- F3 e2e: required green plus a pending EXTRA => READY (extras ignored).
$fxMix = Write-GHAFixture (New-GHARaw @((New-GHAPolicyGreen) + @((New-GHARunNode 'extra-flaky' 'IN_PROGRESS' $null $script:GH_A)))) 'mixed.json'
$mm = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxMix, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$mm.code -eq 0) -and ([string]$mm.env.readiness.value -ceq 'READY_FOR_RESUME') -and ([bool]$mm.env.snapshot.checks_complete)) 'required green plus pending extra => exit 0 READY_FOR_RESUME with checks_complete true'
# --- F4 e2e: rejected action uses fixed value; remote names carry no secrets.
$evilAction = 'sk-SYNTHETICSECRET-ACT-8e1f'
$ra = Invoke-GHAChild @('-Action', $evilAction, '-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A)
Assert-That (([int]$ra.code -eq 2) -and ([string]$ra.env.exit_reason -ceq 'invalid-action') -and ([string]$ra.env.action -ceq 'observe')) 'invalid action rejected with fixed action observe'
Assert-That ($ra.text -cnotmatch 'sk-SYNTHETICSECRET-ACT-8e1f') 'rejected action value never echoed to stdout'
$fxEvil = Write-GHAFixture (New-GHARaw @((New-GHAPolicyGreen) + @((New-GHARunNode 'extra sk-SYNTHETICSECRET-NAME-5b6a' 'COMPLETED' 'SUCCESS' $script:GH_A)))) 'evilname.json'
$en = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxEvil, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$en.code -eq 0) -and ([string]$en.env.readiness.value -ceq 'READY_FOR_RESUME')) 'redacted extra name keeps READY_FOR_RESUME'
Assert-That ($en.text -cnotmatch 'sk-SYNTHETICSECRET-NAME-5b6a') 'secret-like check name never echoed to stdout'
# --- F5: own transport drains a large-output child concurrently (no pipe deadlock).
$emit = '$s = (''x'' * 150000); Write-Output $s'
$big = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emit) -TimeoutMs 10000 -OutputCapChars 262144
Assert-That ([bool]$big.Started) 'synthetic large-output child starts'
Assert-That (-not [bool]$big.TimedOut) 'synthetic 150k output completes without timeout (concurrent drain)'
Assert-That ([int]$big.ExitCode -eq 0) 'synthetic child exits 0'
Assert-That ((([string]$big.Stdout).Length -ge 100000) -and (([string]$big.Stdout).Length -le 262144)) 'synthetic stdout bounded within cap'
Assert-That ((-not [bool]$big.StdoutTruncated) -and (-not [bool]$big.DrainIncomplete)) 'synthetic stdout neither truncated nor incomplete'
# --- ORFS-F3-CLI-HARDEN RED: teto durante leitura (HIGH).
# Dreno concorrente em blocos retendo no maximo cap+1 por stream.
Assert-That ($cliText -cnotmatch 'ReadToEndAsync') 'harden: no unbounded ReadToEndAsync in transport'
$emit400 = '$s = (''x'' * 400000); Write-Output $s'
$big400 = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emit400) -TimeoutMs 10000 -OutputCapChars 262144
Assert-That ([bool]$big400.Started) 'harden: 400k child starts'
Assert-That (-not [bool]$big400.TimedOut) 'harden: 400k drains without timeout'
Assert-That ([int]$big400.ExitCode -eq 0) 'harden: 400k child exit code passes through'
Assert-That ([bool]$big400.StdoutTruncated) 'harden: 400k stdout over cap marks StdoutTruncated'
Assert-That (([string]$big400.Stdout).Length -eq 262145) 'harden: 400k stdout retained exactly cap+1 (overflow witness, bounded)'
Assert-That (-not [bool]$big400.DrainIncomplete) 'harden: 400k finite output drains completely'
Assert-That ($cliText -cmatch 'stdout-truncated') 'harden: StdoutTruncated maps to stable exit-1 code stdout-truncated'
$emitBoth = '$s = (''x'' * 400000); Write-Output $s; [Console]::Error.Write($s)'
$bigBoth = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitBoth) -TimeoutMs 10000 -OutputCapChars 262144
Assert-That (([bool]$bigBoth.StdoutTruncated) -and ([bool]$bigBoth.StderrTruncated)) 'harden: dual 400k streams both truncate without deadlock'
Assert-That ((([string]$bigBoth.Stdout).Length -le 262145) -and (([string]$bigBoth.Stderr).Length -le 262145)) 'harden: dual streams both bounded'
$capSmall = 64
$emitOutUnder = "[Console]::Out.Write(('x' * ($capSmall - 1)))"
$tOutUnder = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitOutUnder) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (((-not [bool]$tOutUnder.StdoutTruncated) -and (-not [bool]$tOutUnder.DrainIncomplete) -and (([string]$tOutUnder.Stdout).Length -eq ($capSmall - 1)))) 'harden: stdout cap-1 passes without truncation'
$emitOutExact = "[Console]::Out.Write(('x' * $capSmall))"
$tOutExact = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitOutExact) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (((-not [bool]$tOutExact.StdoutTruncated) -and (-not [bool]$tOutExact.DrainIncomplete) -and (([string]$tOutExact.Stdout).Length -eq $capSmall))) 'harden: stdout cap passes without truncation'
$emitOutOver = "[Console]::Out.Write(('x' * ($capSmall + 1)))"
$tOutOver = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitOutOver) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (([bool]$tOutOver.StdoutTruncated) -and (-not [bool]$tOutOver.DrainIncomplete) -and (([string]$tOutOver.Stdout).Length -eq ($capSmall + 1))) 'harden: stdout cap+1 marks truncated (witness counts)'
$emitErrUnder = "[Console]::Error.Write(('e' * ($capSmall - 1)))"
$tErrUnder = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitErrUnder) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (((-not [bool]$tErrUnder.StderrTruncated) -and (-not [bool]$tErrUnder.DrainIncomplete) -and (([string]$tErrUnder.Stderr).Length -eq ($capSmall - 1)))) 'harden: stderr cap-1 passes without truncation'
$emitErrExact = "[Console]::Error.Write(('e' * $capSmall))"
$tErrExact = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitErrExact) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (((-not [bool]$tErrExact.StderrTruncated) -and (-not [bool]$tErrExact.DrainIncomplete) -and (([string]$tErrExact.Stderr).Length -eq $capSmall))) 'harden: stderr cap passes without truncation'
$emitErrOver = "[Console]::Error.Write(('e' * ($capSmall + 1)))"
$tErrOver = Invoke-GHAChildTransport -FilePath $script:childExe -ArgumentList @('-NoProfile', '-Command', $emitErrOver) -TimeoutMs 10000 -OutputCapChars $capSmall
Assert-That (([bool]$tErrOver.StderrTruncated) -and (-not [bool]$tErrOver.DrainIncomplete) -and (([string]$tErrOver.Stderr).Length -eq ($capSmall + 1))) 'harden: stderr cap+1 marks truncated (witness counts)'
# --- ORFS-F3-CLI-HARDEN RED: identidade vs sanitizacao (MEDIUM).
# Nome bruto eh identidade: controles/vazio/>200 => invalido (fail-closed).
$evilCtl = 'CI (ps51)' + [string][char]0x01
$ctlRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $evilCtl 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$ctlRun.ok) -and (@($ctlRun.errors) -contains 'check-name-invalid'))) 'harden: control char in CheckRun name => check-name-invalid (never collapses to required)'
$ctlCtx = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHAStatusNode $evilCtl 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$ctlCtx.ok) -and (@($ctlCtx.errors) -contains 'check-name-invalid'))) 'harden: control char in StatusContext name => check-name-invalid'
$over201 = ('q' * 201)
$overRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $over201 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$overRun.ok) -and (@($overRun.errors) -contains 'check-name-invalid'))) 'harden: 201-char name => check-name-invalid (never truncated into required)'
$edge200 = ('q' * 200)
$edgeRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $edge200 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$edgeRun.ok) -and ([string]$edgeRun.snapshot.checks[0].name -ceq $edge200)) 'harden: 200-char boundary valid and published unmutated'
$rawExact = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode 'CI (ps51)' 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$rawExact.ok) -and ([string]$rawExact.snapshot.checks[0].name -ceq 'CI (ps51)')) 'harden: valid name published exactly (no pre-match transform)'
$fxCtl = Write-GHAFixture (New-GHARaw @((New-GHARunNode $evilCtl 'COMPLETED' 'SUCCESS' $script:GH_A))) 'harden-ctl.json'
$hc = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxCtl, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$hc.code -eq 1) -and ([string]$hc.env.exit_reason -ceq 'check-name-invalid')) 'harden e2e: control-char name => exit 1 check-name-invalid (never READY)'
Assert-That ($hc.text -cnotmatch 'READY_FOR_RESUME') 'harden e2e: invalid name never yields READY'
$tabName = 'CI (ps51)' + [string][char]0x09
$tabRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $tabName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$tabRun.ok) -and (@($tabRun.errors) -contains 'check-name-invalid'))) 'harden: trailing tab in CheckRun name => check-name-invalid (raw-first, never trimmed)'
Assert-That (((ConvertTo-Json -InputObject $tabRun -Depth 10 -Compress) -cnotmatch 'CI \(ps51\)')) 'harden: invalid raw name never echoed'
$lfName = [string][char]0x0A + 'CI (ps51)'
$lfRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $lfName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$lfRun.ok) -and (@($lfRun.errors) -contains 'check-name-invalid'))) 'harden: leading LF in CheckRun name => check-name-invalid (raw-first, never trimmed)'
$crlfName = 'CI (ps51)' + [string][char]0x0D + [string][char]0x0A
$crlfRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $crlfName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$crlfRun.ok) -and (@($crlfRun.errors) -contains 'check-name-invalid'))) 'harden: trailing CRLF in CheckRun name => check-name-invalid (raw-first, never trimmed)'
$tabCtx = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHAStatusNode $tabName 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$tabCtx.ok) -and (@($tabCtx.errors) -contains 'check-name-invalid'))) 'harden: trailing tab in StatusContext name => check-name-invalid (raw-first, never trimmed)'
$raw201spaced = ('q' * 195) + (' ' * 6)
Assert-That (([string]$raw201spaced).Length -eq 201) 'harden: raw-201-spaced fixture is exactly 201 chars'
$spacedRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $raw201spaced 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$spacedRun.ok) -and (@($spacedRun.errors) -contains 'check-name-invalid'))) 'harden: 201-char raw with edge spaces => check-name-invalid (length on raw, never collapsed)'
# --- ORFS-F3-CLI-HARDEN RED: allowlist + redacao (MEDIUM).
$evilCon = 'PWNED-SYNTHETIC-4d2c'
$badCon = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode 'extra-odd' 'COMPLETED' $evilCon $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$badCon.ok) -and (@($badCon.errors) -contains 'check-conclusion-invalid'))) 'harden: unknown CheckRun conclusion => check-conclusion-invalid'
Assert-That (((ConvertTo-Json -InputObject $badCon -Depth 10 -Compress) -cnotmatch 'PWNED-SYNTHETIC-4d2c')) 'harden: malicious conclusion never echoed'
$badState = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHAStatusNode 'extra-odd' $evilCon $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (((-not [bool]$badState.ok) -and (@($badState.errors) -contains 'invalid-context-state'))) 'harden: unknown StatusContext state => invalid-context-state'
$ghpName = 'extra ghp_SYNTHETICSECRET-9f8e-tail'
$ghpRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $ghpName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$ghpRun.ok) -and (((ConvertTo-Json -InputObject $ghpRun.snapshot -Depth 10 -Compress) -cnotmatch 'ghp_SYNTHETICSECRET-9f8e'))) 'harden: ghp_ secret-like name redacted from snapshot'
$patName = 'extra github_pat_SYNTHETIC-1a2b-tail'
$patRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $patName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$patRun.ok) -and (((ConvertTo-Json -InputObject $patRun.snapshot -Depth 10 -Compress) -cnotmatch 'github_pat_SYNTHETIC-1a2b'))) 'harden: github_pat_ secret-like name redacted from snapshot'
$xoxName = 'extra xox-SYNTHETIC-zz99-tail'
$xoxRun = Convert-GHARawToSnapshot -Raw (New-GHARaw @((New-GHARunNode $xoxName 'COMPLETED' 'SUCCESS' $script:GH_A))) -Repository $script:GH_REPO -PrNumber $script:GH_PR -ObservedAt $script:GH_NOW
Assert-That (([bool]$xoxRun.ok) -and (((ConvertTo-Json -InputObject $xoxRun.snapshot -Depth 10 -Compress) -cnotmatch 'xox-SYNTHETIC-zz99'))) 'harden: xox- secret-like name redacted from snapshot'
$fxBadCon = Write-GHAFixture (New-GHARaw @((New-GHAPolicyGreen) + @((New-GHARunNode 'extra-odd' 'COMPLETED' 'PWNED-SYNTHETIC-FX7q' $script:GH_A)))) 'harden-badcon.json'
$hbc = Invoke-GHAChild @('-Repository', $script:GH_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GH_A, '-GraphQLSnapshotFile', $fxBadCon, '-NowUtc', $script:GH_NOW)
Assert-That (([int]$hbc.code -eq 1) -and ([string]$hbc.env.exit_reason -ceq 'check-conclusion-invalid')) 'harden e2e: malicious conclusion in fixture => exit 1 rejected'
Assert-That ($hbc.text -cnotmatch 'PWNED-SYNTHETIC-FX7q') 'harden e2e: malicious conclusion never echoed to stdout'
# --- optional live probe (opt-in only; never fails offline default).
if (($env:ORFS_LIVE_GITHUB -eq '1')) {
    $ghLive = $null
    try { $ghLive = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghLive = $null }
    if (($null -ne $ghLive) -and (-not [string]::IsNullOrWhiteSpace([string]$ghLive.Source))) {
        $meta = $null
        try {
            $mtext = & ([string]$ghLive.Source) pr view 88 --repo Kusts/opencode-orchestration --json headRefOid,state 2>$null
            if (-not [string]::IsNullOrWhiteSpace(($mtext -join "`n"))) { $meta = ConvertFrom-Json ($mtext -join "`n") }
        }
        catch { $meta = $null }
        if (($null -ne $meta) -and (Test-GHASha40 -Value ([string]$meta.headRefOid))) {
            $lv = Invoke-GHAChild @('-Repository', 'Kusts/opencode-orchestration', '-PrNumber', '88', '-ExpectedHeadSha', ([string]$meta.headRefOid), '-TimeoutMs', '10000')
            Assert-That ([int]$lv.code -eq 0) 'live PR88 observe exits 0'
            Assert-That (([string]$lv.env.transport -ceq 'gh-query') -and ([string]$lv.env.observed_head_sha -ceq (([string]$meta.headRefOid).ToLowerInvariant()))) 'live PR88 binds observed head to metadata (never auto-accepts unknown SHA)'
            Write-Output ('NOTE live PR88 state=' + [string]$lv.env.snapshot.pr_state + ' readiness=' + [string]$lv.env.readiness.value)
        }
        else { Write-Output 'NOTE live probe skipped: PR88 metadata unavailable (auth/network)' }
    }
    else { Write-Output 'NOTE live probe skipped: gh not found' }
}
else { Write-Output 'NOTE live probe deferred (ORFS_LIVE_GITHUB!=1; offline default)' }
try { if (Test-Path -LiteralPath $script:base) { Remove-Item -LiteralPath $script:base -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
Write-Output "PASS: $passed assertions"
