# github-watch.tests.ps1 -- ORFS-F3-WATCHCLI one-shot observe-and-decide CLI.
# Custom PS 5.1 / PS7 suite, no Pester. Fixtures in owned TEMP. Offline only
# (no live network, no gh required): every e2e case uses
# -GraphQLSnapshotFile. Covers: strict arg validation (exit 2), one-shot
# shape (no loop/sleep/timer/retry/daemon/scheduler), readiness classes
# READY/CHECKS_PENDING/STALE/TERMINAL via fixtures (exit 0), fail-closed
# schema codes (exit 1), wait_request + register_instruction only with
# explicit valid Owner, kernel never mutated, no raw GH leakage (canary),
# envelope key stability, JSON bounded. ASCII only.
param([ValidateSet('auto', 'powershell', 'pwsh')][string]$Engine = 'auto')
$ErrorActionPreference = 'Stop'
$script:cli = Join-Path $PSScriptRoot 'github-watch.ps1'
$script:cliAwait = Join-Path $PSScriptRoot 'github-await.ps1'
if (-not (Test-Path -LiteralPath $script:cli -PathType Leaf)) { throw 'RED: github-watch.ps1 not found (expected before GREEN)' }
. $script:cli
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
# --- dot-source safety: helper exists, nothing executed on load.
Assert-That ($null -ne (Get-Command New-GWRegisterInstruction -ErrorAction SilentlyContinue)) 'dot-source exposes register-instruction builder'
Assert-That ($null -ne (Get-Command Test-GWOwner -ErrorAction SilentlyContinue)) 'dot-source exposes owner validator'
Assert-That (Test-Path -LiteralPath $script:cliAwait -PathType Leaf) 'transport owner github-await.ps1 exists (watch reuses, never reimplements)'
# --- one-shot shape: no loop, no sleep, no timer, no retry, no daemon, no scheduler, no network, no kernel writes.
$cliText = [IO.File]::ReadAllText($script:cli, [Text.Encoding]::UTF8)
foreach ($bad in @('Start-Sleep', 'while\s*\(', 'for\s*\(', 'foreach\s*\(\s*\$iter', 'System\.Timers', 'Register-ObjectEvent', 'Start-Job', 'Register-Scheduled', 'New-Service', 'Start-Service', 'FileSystemWatcher', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', 'Start-Process', ' mutation', 'gh pr merge', 'gh pr create', 'gh pr comment', 'gh pr edit', 'gh pr close', 'gh pr reopen', 'gh pr ready', 'gh pr review', '--method POST', '--method PUT', '--method PATCH', '--method DELETE', 'Block-OrchestrationTask', 'Complete-OrchestrationTask', 'Unblock-', 'Set-OrchestrationTask', 'New-OrchestrationTask', 'Get-OrchestrationTask', 'OrchestrationTaskKernel', 'planner-turn', 'grants_authority = \$true', 'resume_authorized = \$true', 'kernel_mutated = \$true', 'merge_authority = \$true', 'done_approved = \$true', 'GH_TOKEN', 'GITHUB_TOKEN', 'Remove-Item', 'ReadToEnd', 'Convert-GHARawToSnapshot =', 'function Convert-GHARawToSnapshot', 'function Invoke-GHAChildTransport', 'function Get-GHAGhArgs')) {
    Assert-That ($cliText -cnotmatch $bad) ('CLI has no loop/mutation/transport-dup pattern: ' + $bad)
}
Assert-That ($cliText -cmatch 'github-await\.ps1') 'CLI dot-sources github-await.ps1 (transport reuse)'
Assert-That ($cliText -cmatch 'Get-OrchestrationGitHubReadiness') 'CLI calls pure Delivery readiness'
Assert-That ($cliText -cmatch 'New-OrchestrationGitHubWaitRequest') 'CLI builds wait_request via AutonomyWiring'
Assert-That ($cliText -cmatch 'task-kernel\.ps1') 'CLI emits task-kernel registration guidance as text'
Assert-That ($cliText -cnotmatch 'C:\\Users') 'CLI has no machine-specific path'
# --- owner validator (own thin check; transport validators come from await).
Assert-That (Test-GWOwner -Value 'kernel-owner_1:2') 'owner accepts word chars dot colon'
Assert-That (-not (Test-GWOwner -Value '')) 'owner rejects empty (absent means no wait_request, never auto)'
Assert-That (-not (Test-GWOwner -Value 'a b')) 'owner rejects space'
Assert-That (-not (Test-GWOwner -Value ('o' * 129))) 'owner rejects length over 128'
# --- register-instruction builder: bounded text, placeholders, no secrets.
$ri = New-GWRegisterInstruction -WaitType 'external_dependency' -WaitOwner 'kernel-owner' -WaitAction 'revalidate-github-ci' -WaitDependencyId 'github-ci:v1:acme/widgets:42:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Assert-That (([string]$ri -cmatch 'task-kernel\.ps1') -and ([string]$ri -cmatch '-Action block') -and ([string]$ri -cmatch 'external_dependency') -and ([string]$ri -cmatch 'revalidate-github-ci') -and ([string]$ri -cmatch '<TASK_ID>') -and ([string]$ri -cmatch '<REVISION>')) 'register instruction carries kernel block guidance with placeholders'
Assert-That (([string]$ri).Length -lt 2048) 'register instruction is bounded'
$riBad = New-GWRegisterInstruction -WaitType 'nope' -WaitOwner 'kernel-owner' -WaitAction 'revalidate-github-ci' -WaitDependencyId 'x'
Assert-That ([string]::IsNullOrWhiteSpace([string]$riBad)) 'register instruction refuses non-canonical wait triple (fail-closed, empty)'
# --- child engine (same family as parent): CLI exit codes + envelopes.
$script:childExe = ''
if (($Engine -eq 'pwsh') -or (($Engine -eq 'auto') -and ([int]$PSVersionTable.PSVersion.Major -ge 6))) {
    $found = $null
    try { $found = Get-Command pwsh -ErrorAction SilentlyContinue } catch { $found = $null }
    if (($null -ne $found) -and (-not [string]::IsNullOrWhiteSpace([string]$found.Source))) { $script:childExe = [string]$found.Source }
}
if ([string]::IsNullOrWhiteSpace($script:childExe) -and ($Engine -ne 'pwsh')) {
    $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
    $script:childExe = $psExe
}
if ([string]::IsNullOrWhiteSpace($script:childExe)) { throw 'FAIL: engine unavailable (neither pwsh nor powershell resolved)' }
$script:passed++
Write-Output ('engine: ' + $script:childExe)
function Invoke-GWChild {
    param([string[]]$CliArgs = @())
    $out = & $script:childExe -NoProfile -File $script:cli @CliArgs 2>$null
    $code = $LASTEXITCODE
    $text = ''
    if ($null -ne $out) { $text = ($out -join "`n").Trim() }
    $env = $null
    try { if (-not [string]::IsNullOrWhiteSpace($text)) { $env = ConvertFrom-Json $text } } catch { $env = $null }
    return @{ code = $code; text = $text; env = $env }
}
# --- fixture builders (raw GraphQL shape, as gh api graphql returns).
$script:GW_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:GW_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:GW_REPO = 'acme/widgets'
$script:GW_PR = 42
$script:GW_NOW = '2026-10-10T12:02:00Z'
$script:base = Join-Path ([IO.Path]::GetTempPath()) ('gwatch-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:base -Force | Out-Null
function New-GWRunNode {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{
        __typename = 'CheckRun'; name = $Name; status = $Status; conclusion = $Conclusion
        checkSuite = [pscustomobject]@{ commit = [pscustomobject]@{ oid = $Sha } }
    }
}
function New-GWStatusNode {
    param([string]$Context, [string]$State, [string]$Sha)
    return [pscustomobject]@{
        __typename = 'StatusContext'; context = $Context; state = $State
        commit = [pscustomobject]@{ oid = $Sha }
    }
}
function New-GWRaw {
    param($Nodes, [string]$Head = $script:GW_A, [string]$Commit = $script:GW_A, [string]$State = 'OPEN', $Merge = 'MERGEABLE', $Review = 'APPROVED')
    $roll = @([pscustomobject]@{ contexts = [pscustomobject]@{ nodes = @($Nodes); pageInfo = [pscustomobject]@{ hasNextPage = $false; endCursor = 'CURSOR1' }; totalCount = @($Nodes).Count } })
    $built = [pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{
        nameWithOwner = $script:GW_REPO
        pullRequest = [pscustomobject]@{
            number = $script:GW_PR; state = $State; headRefOid = $Head
            mergeable = $Merge; reviewDecision = $Review
            commits = [pscustomobject]@{ nodes = @([pscustomobject]@{ commit = [pscustomobject]@{ oid = $Commit; statusCheckRollup = $roll } }) }
        }
    } } }
    return (ConvertFrom-Json (ConvertTo-Json -InputObject $built -Depth 20))
}
function Write-GWFixture {
    param($Raw, [string]$Name)
    $p = Join-Path $script:base $Name
    [IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $Raw -Depth 20), (New-Object Text.UTF8Encoding $false))
    return $p
}
$script:policyChecks = @('CI (ps51)', 'CI (ps7)', 'CI (smoke opencode real)', 'CI (v2 lane, perfil V2 provisionado)', 'CI (smoke opencode v2 real)')
function New-GWPolicyGreen {
    $out = @()
    foreach ($cn2 in $script:policyChecks) { $out += @(New-GWRunNode $cn2 'COMPLETED' 'SUCCESS' $script:GW_A) }
    return $out
}
# --- exit 2: strict arg validation.
$r = Invoke-GWChild @('-Repository', 'bad repo!', '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-repository')) 'watch rejects bad repository with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '0', '-ExpectedHeadSha', $script:GW_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-pr-number')) 'watch rejects PR 0 with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-ExpectedHeadSha', $script:GW_A)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-pr-number')) 'watch requires explicit PR (never auto)'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-expected-sha')) 'watch requires explicit ExpectedHeadSha (never auto-accepts observed HEAD)'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', 'zzz')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-expected-sha')) 'watch rejects bad sha with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-TimeoutMs', '0')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-timeout')) 'watch rejects TimeoutMs 0 with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-TimeoutMs', '10001')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-timeout')) 'watch rejects TimeoutMs 10001 with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-MaxAgeSeconds', '0')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-max-age')) 'watch rejects MaxAgeSeconds 0 with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-MaxAgeSeconds', '3601')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-max-age')) 'watch rejects MaxAgeSeconds 3601 with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-Owner', 'bad owner!')
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-owner')) 'watch rejects bad owner with exit 2'
$r = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', (Join-Path $script:base 'absent.json'), '-NowUtc', $script:GW_NOW)
Assert-That (([int]$r.code -eq 2) -and ([string]$r.env.exit_reason -ceq 'invalid-snapshot-file')) 'watch rejects absent fixture file with exit 2'
# --- READY via fixture (exit 0, no owner => no wait_request, zero authority).
$canary = 'CANARY-9f8e7d6c5b4a3948'
$rawGreen = New-GWRaw (New-GWPolicyGreen)
$rawGreen.data | Add-Member -NotePropertyName 'note' -NotePropertyValue $canary -Force
$fxGreen = Write-GWFixture $rawGreen 'green.json'
$g = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxGreen, '-NowUtc', $script:GW_NOW)
Assert-That ([int]$g.code -eq 0) 'fixture all-green exits 0'
Assert-That (([bool]$g.env.ok) -and ([string]$g.env.exit_reason -ceq 'observed') -and ([string]$g.env.action -ceq 'watch')) 'fixture all-green envelope observed by watch'
Assert-That (([string]$g.env.transport -ceq 'fixture-declared')) 'fixture provenance declared'
Assert-That (([string]$g.env.readiness.value -ceq 'READY_FOR_RESUME') -and ([bool]$g.env.readiness.ok) -and (@($g.env.errors).Count -eq 0)) 'fixture all-green readiness READY_FOR_RESUME, no errors'
Assert-That ([string]$g.env.observed_head_sha -ceq $script:GW_A) 'observation binds head sha'
Assert-That ($g.text -cmatch '"observed_at":"2026-10-10T12:02:00Z"') 'observation binds forced timestamp on the wire (raw JSON; PS7 coerces parsed dates)'
Assert-That (([string]$g.env.observation.pr_state -ceq 'OPEN') -and ([bool]$g.env.observation.checks_complete) -and ([long]$g.env.observation.checks_count -eq 5)) 'observation carries bounded state (no raw bodies)'
Assert-That ((-not [bool]$g.env.snapshot_only -eq $false) -and (-not [bool]$g.env.grants_authority) -and (-not [bool]$g.env.merge_authority) -and (-not [bool]$g.env.done_approved) -and (-not [bool]$g.env.resume_authorized) -and (-not [bool]$g.env.kernel_mutated)) 'all-green grants zero authority (observe is not authorization)'
Assert-That (($null -eq $g.env.wait_request) -and ($null -eq $g.env.register_instruction)) 'no owner => no wait_request and no register instruction'
Assert-That (($g.text -cnotmatch $canary) -and ($g.text -cnotmatch 'stdout') -and ($g.text -cnotmatch 'stderr')) 'no raw GH leakage: canary and stream names absent'
Assert-That (([string]$g.text).Length -lt 65536) 'JSON output bounded'
$wantKeys = @('ok', 'exit_reason', 'action', 'transport', 'repository', 'pr_number', 'expected_head_sha', 'observed_head_sha', 'observed_at', 'observation', 'readiness', 'wait_request', 'register_instruction', 'errors', 'snapshot_only', 'grants_authority', 'merge_authority', 'done_approved', 'resume_authorized', 'kernel_mutated')
$gotKeys = @()
foreach ($pp in @($g.env.PSObject.Properties)) { $gotKeys += @([string]$pp.Name) }
foreach ($wk in $wantKeys) { Assert-That ($gotKeys -contains $wk) ('envelope carries key ' + $wk) }
foreach ($gk in $gotKeys) { Assert-That ($wantKeys -contains $gk) ('envelope carries no extra key: ' + $gk) }
# --- explicit valid Owner => wait_request + register_instruction, still zero authority.
$gw = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxGreen, '-NowUtc', $script:GW_NOW, '-Owner', 'kernel-owner')
Assert-That (([int]$gw.code -eq 0) -and ($null -ne $gw.env.wait_request) -and ($null -ne $gw.env.register_instruction)) 'explicit owner => wait_request plus register instruction'
Assert-That (([string]$gw.env.wait_request.WaitType -ceq 'external_dependency') -and ([string]$gw.env.wait_request.WaitAction -ceq 'revalidate-github-ci') -and ([string]$gw.env.wait_request.WaitOwner -ceq 'kernel-owner') -and ([string]$gw.env.wait_request.WaitDependencyId -ceq ('github-ci:v1:' + $script:GW_REPO + ':42:' + $script:GW_A))) 'wait_request carries canonical depid (request-only)'
Assert-That ((-not [bool]$gw.env.wait_request.kernel_mutated) -and (-not [bool]$gw.env.wait_request.grants_authority) -and (-not [bool]$gw.env.kernel_mutated)) 'wait_request mutates nothing (sem kernel_mutated)'
Assert-That (([string]$gw.env.register_instruction -cmatch 'task-kernel\.ps1') -and ([string]$gw.env.register_instruction -cmatch '-Action block') -and ([string]$gw.env.register_instruction -cmatch 'github-ci:v1:acme/widgets:42:') -and ([string]$gw.env.register_instruction -cmatch '<TASK_ID>')) 'register instruction guides kernel block with depid and placeholders'
# --- CHECKS_PENDING via fixture: one required check IN_PROGRESS (exit 0).
$pendNodes = @((New-GWPolicyGreen)[0..3] + @((New-GWRunNode 'CI (smoke opencode v2 real)' 'IN_PROGRESS' $null $script:GW_A)))
$fxPend = Write-GWFixture (New-GWRaw $pendNodes) 'pending.json'
$cp = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxPend, '-NowUtc', $script:GW_NOW)
Assert-That (([int]$cp.code -eq 0) -and ([string]$cp.env.readiness.value -ceq 'CHECKS_PENDING') -and (-not [bool]$cp.env.readiness.ok)) 'required check in progress => exit 0 CHECKS_PENDING'
Assert-That ((-not [bool]$cp.env.kernel_mutated) -and (-not [bool]$cp.env.resume_authorized)) 'pending observation authorizes nothing'
# --- STALE via fixture: expected head moved (exit 0, valid observation).
$fxStale = Write-GWFixture (New-GWRaw (New-GWPolicyGreen)) 'stale.json'
$st = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_B, '-GraphQLSnapshotFile', $fxStale, '-NowUtc', $script:GW_NOW)
Assert-That (([int]$st.code -eq 0) -and ([string]$st.env.readiness.value -ceq 'STALE') -and (@($st.env.errors) -contains 'head-mismatch')) 'replay old head => exit 0 STALE head-mismatch'
# --- TERMINAL via fixture: PR closed (exit 0, valid observation).
$fxTerm = Write-GWFixture (New-GWRaw (New-GWPolicyGreen) -State 'CLOSED') 'terminal.json'
$tm = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxTerm, '-NowUtc', $script:GW_NOW)
Assert-That (([int]$tm.code -eq 0) -and ([string]$tm.env.readiness.value -ceq 'TERMINAL') -and (@($tm.env.errors) -contains 'pr-terminal')) 'closed PR => exit 0 TERMINAL pr-terminal'
Assert-That ((-not [bool]$tm.env.kernel_mutated) -and (-not [bool]$tm.env.done_approved)) 'terminal observation mutates nothing'
# --- exit 1: schema fail-closed (missing PR, pagination, remote errors).
$fxNoPr = Write-GWFixture ([pscustomobject]@{ data = [pscustomobject]@{ repository = [pscustomobject]@{ nameWithOwner = $script:GW_REPO; pullRequest = $null } } }) 'nopr.json'
$np = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxNoPr, '-NowUtc', $script:GW_NOW)
Assert-That (([int]$np.code -eq 1) -and ([string]$np.env.exit_reason -ceq 'pr-not-found') -and ($null -eq $np.env.wait_request) -and (-not [bool]$np.env.kernel_mutated)) 'missing PR => exit 1 pr-not-found, no wait_request'
$rawErrFx = New-GWRaw (New-GWPolicyGreen)
$rawErrFx | Add-Member -NotePropertyName 'errors' -NotePropertyValue @([pscustomobject]@{ message = 'SENSITIVE-REMOTE-GRAPHQL-4d2c'; type = 'X' }) -Force
$fxErr = Write-GWFixture $rawErrFx 'errors.json'
$er = Invoke-GWChild @('-Repository', $script:GW_REPO, '-PrNumber', '42', '-ExpectedHeadSha', $script:GW_A, '-GraphQLSnapshotFile', $fxErr, '-NowUtc', $script:GW_NOW)
Assert-That (([int]$er.code -eq 1) -and ([string]$er.env.exit_reason -ceq 'graphql-errors')) 'fixture data-green plus errors => exit 1 graphql-errors'
Assert-That ($er.text -cnotmatch 'SENSITIVE-REMOTE-GRAPHQL-4d2c') 'remote error detail never echoed to stdout'
try { if (Test-Path -LiteralPath $script:base) { Remove-Item -LiteralPath $script:base -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
Write-Output "PASS: $passed assertions"
