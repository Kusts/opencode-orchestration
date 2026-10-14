<#!
.SYNOPSIS
    ORFS-F3-WATCHCLI: one-shot GitHub observe-and-decide CLI (no daemon, no loop).
.DESCRIPTION
    Observes one pull request exactly once and decides, without any
    daemon, loop, scheduler, retry or watcher lifecycle. Transport is fully
    reused from github-await.ps1 (dot-sourced; never reimplemented here):
    read-only GitHub GraphQL via gh, or an explicit offline fixture file.
    Readiness is the pure Delivery function
    (Get-OrchestrationGitHubReadiness). When -Owner is explicitly supplied
    and valid, a wait_request is emitted via AutonomyWiring
    (New-OrchestrationGitHubWaitRequest: external_dependency /
    revalidate-github-ci / canonical depid) plus a register_instruction
    text guiding registration through the existing task-kernel CLI. This
    CLI never writes to the kernel, never unblocks, never calls the
    Planner and never merges.

    Usage (offline fixture, no network):
      powershell -NoProfile -File github-watch.ps1 `
        -Repository owner/repo -PrNumber 42 -ExpectedHeadSha <40hex> `
        -GraphQLSnapshotFile <path> [-Owner <wait-owner>] `
        [-TimeoutMs 10000] [-MaxAgeSeconds 300] [-NowUtc <utc>]

    Usage (live, read-only gh):
      powershell -NoProfile -File github-watch.ps1 `
        -Repository owner/repo -PrNumber 42 -ExpectedHeadSha <40hex> `
        [-Owner <wait-owner>] [-TimeoutMs 10000] [-MaxAgeSeconds 300]

    Exit 0 carries a valid observation (readiness may be READY_FOR_RESUME,
    CHECKS_PENDING, REVIEW_PENDING, REPAIR_REQUIRED, INCONCLUSIVE, STALE or
    TERMINAL -- observation is not authorization). Exit 1 = transport,
    snapshot or readiness failure. Exit 2 = invalid args.

    Output: exactly one JSON envelope on stdout (bounded; never raw gh
    output, URLs, bodies or secrets; errors[] carries only stable codes).
    Dot-source safe: without -Repository and without -GraphQLSnapshotFile
    this file defines functions and does nothing else.
    PS 5.1 and PS7 compatible. ASCII-only.
#>
param(
    [string]$Repository = '',
    $PrNumber = $null,
    [string]$ExpectedHeadSha = '',
    [string]$Owner = '',
    $TimeoutMs = 10000,
    $MaxAgeSeconds = 300,
    [string]$NowUtc = '',
    [string]$GraphQLSnapshotFile = ''
)

$ErrorActionPreference = 'Stop'

# Dot-sourcing github-await.ps1 runs its param block in this scope, which
# would overwrite the parameters bound above with await defaults. Save and
# restore around the dot-source; await is dot-source safe so its own
# entrypoint guard stays silent with default (empty) values.
$GW_SavedRepository = $Repository
$GW_SavedPrNumber = $PrNumber
$GW_SavedExpectedHeadSha = $ExpectedHeadSha
$GW_SavedOwner = $Owner
$GW_SavedTimeoutMs = $TimeoutMs
$GW_SavedMaxAgeSeconds = $MaxAgeSeconds
$GW_SavedNowUtc = $NowUtc
$GW_SavedGraphQLSnapshotFile = $GraphQLSnapshotFile
. (Join-Path $PSScriptRoot 'github-await.ps1')
$Repository = $GW_SavedRepository
$PrNumber = $GW_SavedPrNumber
$ExpectedHeadSha = $GW_SavedExpectedHeadSha
$Owner = $GW_SavedOwner
$TimeoutMs = $GW_SavedTimeoutMs
$MaxAgeSeconds = $GW_SavedMaxAgeSeconds
$NowUtc = $GW_SavedNowUtc
$GraphQLSnapshotFile = $GW_SavedGraphQLSnapshotFile
Remove-Variable -Name GW_SavedRepository, GW_SavedPrNumber, GW_SavedExpectedHeadSha, GW_SavedOwner, GW_SavedTimeoutMs, GW_SavedMaxAgeSeconds, GW_SavedNowUtc, GW_SavedGraphQLSnapshotFile -ErrorAction SilentlyContinue

function Test-GWOwner {
    param([string]$Value = '')
    try { return ([bool](Test-GHAOwner -Value ([string]$Value))) }
    catch { return $false }
}

function New-GWRegisterInstruction {
    param(
        [string]$WaitType = '',
        [string]$WaitOwner = '',
        [string]$WaitAction = '',
        [string]$WaitDependencyId = ''
    )
    try {
        if ($WaitType -cne 'external_dependency') { return '' }
        if ($WaitAction -cne 'revalidate-github-ci') { return '' }
        if (-not (Test-GHAOwner -Value ([string]$WaitOwner))) { return '' }
        $dep = ([string]$WaitDependencyId).Trim()
        if ([string]::IsNullOrWhiteSpace($dep)) { return '' }
        if ($dep.Length -gt 300) { return '' }
        if ($dep -cnotmatch '\Agithub-ci:v1:[a-z0-9._-]+/[a-z0-9._-]+:[0-9]{1,10}:[0-9a-f]{40}\Z') { return '' }
        $own = ([string]$WaitOwner).Trim()
        $instruction = ('powershell -NoProfile -File scripts/v3/task-kernel.ps1 -Action block -TaskId <TASK_ID> -Actor ' + $own + ' -Reason github-ci-wait -ExpectedRevision <REVISION> -WaitType external_dependency -WaitOwner ' + $own + ' -WaitAction revalidate-github-ci -WaitDependencyId ' + $dep)
        if ($instruction.Length -gt 2048) { return '' }
        return $instruction
    }
    catch { return '' }
}

# CLI entrypoint. Runs only when -Repository or -GraphQLSnapshotFile is
# supplied, so dot-sourcing this file as a library defines the functions
# above and does nothing else. Single pass: no loop, no sleep, no timer.
if ((-not [string]::IsNullOrWhiteSpace($Repository)) -or (-not [string]::IsNullOrWhiteSpace($GraphQLSnapshotFile))) {
    function Write-GWEnvelope {
        param($Envelope)
        try {
            Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
        }
        catch {
            Write-Output '{"ok":false,"exit_reason":"encode-failed","action":"watch","errors":["encode-failed"],"snapshot_only":true,"grants_authority":false,"merge_authority":false,"done_approved":false,"resume_authorized":false,"kernel_mutated":false}'
        }
    }
    function New-GWErrorEnvelope {
        param([string]$Reason, [string]$TransportName, [string]$Repo, [long]$Pr, [string]$Exp, [string[]]$Codes)
        $c = @($Reason)
        try { if ($null -ne $Codes -and @($Codes).Count -gt 0) { $c = [string[]]@($Codes) } } catch { $c = @($Reason) }
        return [pscustomobject]@{
            ok = $false; exit_reason = $Reason; action = 'watch'
            transport = $TransportName
            repository = $Repo; pr_number = $Pr; expected_head_sha = $Exp
            observed_head_sha = ''; observed_at = ''
            observation = $null
            readiness = $null; wait_request = $null; register_instruction = $null
            errors = $c
            snapshot_only = $true; grants_authority = $false; merge_authority = $false
            done_approved = $false; resume_authorized = $false; kernel_mutated = $false
        }
    }
    try {
        if (-not (Test-GHARepoSyntax -Value ([string]$Repository))) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-repository' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('invalid-repository'))
            exit 2
        }
        $repoCanon = ([string]$Repository).Trim().ToLowerInvariant()
        $parts = ([string]$Repository).Trim().Split('/')
        $ownerPart = ([string]$parts[0]).Trim()
        $namePart = ([string]$parts[1]).Trim()
        if ((-not (Test-GHANamePart -Value $ownerPart)) -or (-not (Test-GHANamePart -Value $namePart))) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-repository' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('invalid-repository'))
            exit 2
        }
        $prConv = Convert-GHAIntRange -Value $PrNumber -Min 1 -Max 2147483647
        if (-not [bool]$prConv.ok) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-pr-number' -TransportName 'none' -Repo $repoCanon -Pr ([long]0) -Exp '' -Codes @('invalid-pr-number'))
            exit 2
        }
        $prNum = [long]$prConv.value
        if (-not (Test-GHASha40 -Value $ExpectedHeadSha)) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-expected-sha' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp '' -Codes @('invalid-expected-sha'))
            exit 2
        }
        $expLow = ([string]$ExpectedHeadSha).Trim().ToLowerInvariant()
        $toConv = Convert-GHAIntRange -Value $TimeoutMs -Min 1 -Max 10000
        if (-not [bool]$toConv.ok) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-timeout' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-timeout'))
            exit 2
        }
        $timeoutInt = [int]$toConv.value
        $maConv = Convert-GHAIntRange -Value $MaxAgeSeconds -Min 1 -Max 3600
        if (-not [bool]$maConv.ok) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-max-age' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-max-age'))
            exit 2
        }
        $maxAge = [long]$maConv.value
        $ownerTrim = ([string]$Owner).Trim()
        if (($ownerTrim -ne '') -and (-not (Test-GHAOwner -Value $ownerTrim))) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-owner' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-owner'))
            exit 2
        }
        $stampForced = ([string]$NowUtc).Trim()
        if (($stampForced -ne '') -and ($null -eq (Convert-GHAUtc -Value $stampForced))) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-now' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-now'))
            exit 2
        }
        $libDir = Join-Path $PSScriptRoot 'lib'
        $deliveryLib = Join-Path $libDir 'OrchestrationDelivery.ps1'
        $wiringLib = Join-Path $libDir 'OrchestrationAutonomyWiring.ps1'
        if ((-not (Test-Path -LiteralPath $deliveryLib -PathType Leaf)) -or (-not (Test-Path -LiteralPath $wiringLib -PathType Leaf))) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'lib-unavailable' -TransportName 'none' -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('lib-unavailable'))
            exit 1
        }
        $fixtureMode = (-not [string]::IsNullOrWhiteSpace($GraphQLSnapshotFile))
        $transportName = 'gh-query'
        if ($fixtureMode) { $transportName = 'fixture-declared' }
        $rawObj = $null
        if ($fixtureMode) {
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
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'invalid-snapshot-file' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('invalid-snapshot-file'))
                exit 2
            }
            try {
                $rawText = [IO.File]::ReadAllText($fx, [Text.Encoding]::UTF8)
                if ([string]::IsNullOrWhiteSpace($rawText)) { throw 'empty fixture' }
                $rawObj = ConvertFrom-Json $rawText
            }
            catch {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'snapshot-unparseable' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('snapshot-unparseable'))
                exit 1
            }
        }
        else {
            $ghCmd = $null
            try { $ghCmd = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghCmd = $null }
            if (($null -eq $ghCmd) -or [string]::IsNullOrWhiteSpace([string]$ghCmd.Source)) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'gh-not-found' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('gh-not-found'))
                exit 1
            }
            $ghArgs = Get-GHAGhArgs -OwnerPart $ownerPart -NamePart $namePart -Number $prNum
            $child = $null
            try {
                $child = Invoke-GHAChildTransport -FilePath ([string]$ghCmd.Source) -ArgumentList $ghArgs -TimeoutMs $timeoutInt -OutputCapChars 262144
            }
            catch { $child = $null }
            if ($null -eq $child) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'child-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-failed'))
                exit 1
            }
            $exitChild = -1
            $toChild = $false
            try { $exitChild = [int]$child.ExitCode } catch { $exitChild = -1 }
            try { $toChild = [bool]$child.TimedOut } catch { $toChild = $false }
            if (-not [bool]$child.Started) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'child-not-started' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-not-started'))
                exit 1
            }
            if ($toChild) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'child-timeout' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('child-timeout'))
                exit 1
            }
            if ([bool]$child.DrainIncomplete) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'drain-incomplete' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('drain-incomplete'))
                exit 1
            }
            if ([bool]$child.StdoutTruncated) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'stdout-truncated' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('stdout-truncated'))
                exit 1
            }
            if ($exitChild -ne 0) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'gh-nonzero-exit' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('gh-nonzero-exit'))
                exit 1
            }
            try {
                if ([string]::IsNullOrWhiteSpace([string]$child.Stdout)) { throw 'empty stdout' }
                $rawObj = ConvertFrom-Json ([string]$child.Stdout)
            }
            catch {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'snapshot-unparseable' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('snapshot-unparseable'))
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
            Write-GWEnvelope (New-GWErrorEnvelope -Reason ([string]$ncodes[0]) -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes $ncodes)
            exit 1
        }
        $snap = $norm.snapshot
        . $deliveryLib
        . $wiringLib
        $rdy = $null
        try {
            $rdy = Get-OrchestrationGitHubReadiness -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expLow -Snapshot $snap -Policy $null -NowUtc $stamp -MaxAgeSeconds $maxAge
        }
        catch { $rdy = $null }
        if ($null -eq $rdy) {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'readiness-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('readiness-failed'))
            exit 1
        }
        $rdyVal = ([string]$rdy.readiness)
        $rdyOk = [bool]$rdy.ok
        $rdyReasons = @()
        try { if ($null -ne $rdy.reasons) { $rdyReasons = [string[]]@($rdy.reasons) } } catch { $rdyReasons = @() }
        $errOut = @()
        if (($rdyVal -cne 'READY_FOR_RESUME') -or (-not $rdyOk)) { $errOut = @($rdyReasons) }
        $obsChecks = 0
        try { $obsChecks = @($snap.checks).Count } catch { $obsChecks = 0 }
        $obsComplete = $false
        try { $obsComplete = [bool]$snap.checks_complete } catch { $obsComplete = $false }
        $obsState = ''
        try { $obsState = ([string]$snap.pr_state) } catch { $obsState = '' }
        $observation = [pscustomobject]@{
            pr_state = $obsState; checks_complete = $obsComplete; checks_count = [long]$obsChecks
        }
        $wr = $null
        $regInstruction = $null
        if ($ownerTrim -ne '') {
            try {
                $wr = New-OrchestrationGitHubWaitRequest -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $expLow -Owner $ownerTrim
            }
            catch { $wr = $null }
            if (($null -eq $wr) -or (-not [bool]$wr.ok)) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'wait-request-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('wait-request-failed'))
                exit 1
            }
            $regInstruction = New-GWRegisterInstruction -WaitType ([string]$wr.WaitType) -WaitOwner ([string]$wr.WaitOwner) -WaitAction ([string]$wr.WaitAction) -WaitDependencyId ([string]$wr.WaitDependencyId)
            if ([string]::IsNullOrWhiteSpace([string]$regInstruction)) {
                Write-GWEnvelope (New-GWErrorEnvelope -Reason 'wait-request-failed' -TransportName $transportName -Repo $repoCanon -Pr $prNum -Exp $expLow -Codes @('wait-request-failed'))
                exit 1
            }
        }
        Write-GWEnvelope ([pscustomobject]@{
            ok = $true; exit_reason = 'observed'; action = 'watch'
            transport = $transportName
            repository = $repoCanon; pr_number = $prNum; expected_head_sha = $expLow
            observed_head_sha = ([string]$snap.head_sha); observed_at = ([string]$snap.observed_at)
            observation = $observation
            readiness = ([pscustomobject]@{ ok = $rdyOk; value = $rdyVal; reasons = [string[]]$rdyReasons })
            wait_request = $wr; register_instruction = $regInstruction
            errors = [string[]]$errOut
            snapshot_only = $true; grants_authority = $false; merge_authority = $false
            done_approved = $false; resume_authorized = $false; kernel_mutated = $false
        })
        exit 0
    }
    catch {
        try {
            Write-GWEnvelope (New-GWErrorEnvelope -Reason 'internal-error' -TransportName 'none' -Repo '' -Pr ([long]0) -Exp '' -Codes @('internal-error'))
        }
        catch { }
        exit 1
    }
}
