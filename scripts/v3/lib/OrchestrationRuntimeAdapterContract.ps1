<#!
.SYNOPSIS
    PR-1 Runtime Adapter Contract: especificacao executavel das 10 ops do adapter (CORRECTIVE-PLAN Fase 1).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure constructors only,
    fail-closed, PS 5.1 compatible, ASCII-only. Never spawns processes, never
    touches the network, never kills processes, never reads secret values
    (credential identifiers are names only, never resolved). No DONE, no
    verified_pass, no grant is ever issued by any function here: every result
    carries grants_authority=$false and done_approved=$false
    (mcp-output-never-grants pattern).

    The 10 operations (names are proposal, not existing API -- CORRECTIVE-PLAN
    Fase 1): detectCapabilities, identifySession, getSessionState,
    dispatchWorker, observeWorkerResult, waitForSettlement,
    requestPlannerContinuation, restoreContext, cancelAuthorizedExecution,
    recordRuntimeEvidence.

    Matrix per op x runtime (V1, V2; pins live ONLY in
    source/registry/runtime-versions.json via the
    fail-closed loader, never as literals here -- not even in comments):
      SPECIFIABLE (SUPPORTED, spec-only, never VERIFIED -- no exact-binary-live
      claim exists): detectCapabilities (caller-provided probe --version text +
      major parse + pin resolution fail-closed; this lib never runs the probe),
      recordRuntimeEvidence (JSONL sink check + writeUnavailable typed result;
      the write itself stays with OrchestrationEvidenceStore),
      restoreContext (context built kernel-side from the caller envelope;
      snapshots/event-log marked auxiliary, never overriding Git/worktree),
      identifySession (best-effort chain session-map -> input-probe -> neutral,
      always reporting identity_source), observeWorkerResult (telemetry row +
      kernel-allowlisted verification note; verified stays $false here).
      HOLD (typed unavailable/blocked, allowlisted cause, fallback_continue,
      no authority change): getSessionState, dispatchWorker, waitForSettlement,
      requestPlannerContinuation, cancelAuthorizedExecution.
    runtime_grant_enforcement stays OFF: no deny is implemented here; affected
    actions return blocked/unavailable so the caller (executor) restricts them.
    The watchdog is only referenced (signal names), never driven.

    Operational failures return objects with ok=$false and a machine-readable
    reason (never throw), EXCEPT fail-closed registry/input errors which throw
    with a clear cause: missing/unreadable registry, unknown operation or
    runtime, out-of-allowlist cause.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$AdapterContractRepoRoot = ''
try {
  $AdapterContractRepoRoot = (Resolve-Path -LiteralPath (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') '..')).Path
}
catch {
  throw ('adapter contract: repo root irresoluvel para o loader de versoes: ' + $_.Exception.Message)
}
$AdapterContractVersionsLoader = Join-Path $AdapterContractRepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1'
if (-not (Test-Path -LiteralPath $AdapterContractVersionsLoader -PathType Leaf)) {
  throw ('adapter contract: loader de versoes ausente (fail-closed): ' + $AdapterContractVersionsLoader)
}
. $AdapterContractVersionsLoader

if ($null -eq $script:OrchestrationAdapterContractLoaderState) {
    $script:OrchestrationAdapterContractLoaderState = @{ loaded = $true }
}

function Get-OrchestrationAdapterContractVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-OBJECTIVE-RUNTIME-CONTRACT'
        phase          = 'PR-1'
    }
}

function Get-OrchestrationRuntimeAdapterOperations {
    [CmdletBinding()]
    param()
    return @(
        'detectCapabilities',
        'identifySession',
        'getSessionState',
        'dispatchWorker',
        'observeWorkerResult',
        'waitForSettlement',
        'requestPlannerContinuation',
        'restoreContext',
        'cancelAuthorizedExecution',
        'recordRuntimeEvidence'
    )
}

function Get-OrchestrationAdapterHoldOperations {
    [CmdletBinding()]
    param()
    return @(
        'getSessionState',
        'dispatchWorker',
        'waitForSettlement',
        'requestPlannerContinuation',
        'cancelAuthorizedExecution'
    )
}

function Get-OrchestrationAdapterHoldCauses {
    [CmdletBinding()]
    param()
    return @(
        'no-proven-api-effect-observable',
        'runtime-grant-enforcement-hold',
        'v2-probing-hold',
        'spawn-not-specified',
        'settlement-wait-not-specified',
        'continuation-not-wired',
        'cancel-deny-not-proven'
    )
}

function Get-OrchestrationAdapterRuntimes {
    [CmdletBinding()]
    param()
    return @('V1', 'V2')
}

function Test-OrchestrationAdapterOperation {
    [CmdletBinding()]
    param([string]$Operation = '')
    $known = Get-OrchestrationRuntimeAdapterOperations
    foreach ($op in $known) {
        if ($Operation -ceq $op) { return $true }
    }
    return $false
}

function Test-OrchestrationAdapterRuntime {
    [CmdletBinding()]
    param([string]$Runtime = '')
    return (($Runtime -ceq 'V1') -or ($Runtime -ceq 'V2'))
}

function Get-OrchestrationRuntimeAdapterMatrix {
    [CmdletBinding()]
    param([string]$Runtime = '')
    if (-not [string]::IsNullOrWhiteSpace($Runtime)) {
        if (-not (Test-OrchestrationAdapterRuntime -Runtime $Runtime)) {
            throw ('adapter contract: runtime desconhecido (esperado V1|V2): ' + [string]$Runtime)
        }
    }
    $targets = @()
    if ([string]::IsNullOrWhiteSpace($Runtime)) { $targets = Get-OrchestrationAdapterRuntimes }
    else { $targets = @($Runtime) }
    $holds = Get-OrchestrationAdapterHoldOperations
    $rows = New-Object System.Collections.ArrayList
    foreach ($rt in $targets) {
        foreach ($op in (Get-OrchestrationRuntimeAdapterOperations)) {
            $status = 'SUPPORTED'
            $basis = ''
            if ($holds -contains $op) {
                $status = 'HOLD'
                $basis = 'no-proven-api-effect-observable'
            }
            else {
                if ($op -ceq 'detectCapabilities') { $basis = 'probe-parse-plus-pin-resolution' }
                elseif ($op -ceq 'recordRuntimeEvidence') { $basis = 'jsonl-sink-plus-write-unavailable' }
                elseif ($op -ceq 'restoreContext') { $basis = 'kernel-side-context-auxiliary-snapshots' }
                elseif ($op -ceq 'identifySession') { $basis = 'best-effort-identity-chain' }
                else { $basis = 'telemetry-plus-kernel-verification' }
            }
            [void]$rows.Add([pscustomobject]@{
                operation = [string]$op
                runtime   = [string]$rt
                status    = [string]$status
                basis     = [string]$basis
                verified  = $false
            })
        }
    }
    return $rows.ToArray()
}

function Get-OrchestrationAdapterOperationSpec {
    [CmdletBinding()]
    param([string]$Operation = '')
    if (-not (Test-OrchestrationAdapterOperation -Operation $Operation)) {
        throw ('adapter contract: operacao desconhecida: ' + [string]$Operation)
    }
    $holds = Get-OrchestrationAdapterHoldOperations
    $isHold = ($holds -contains $Operation)
    $statusV1 = 'SUPPORTED'
    $statusV2 = 'SUPPORTED'
    if ($isHold) { $statusV1 = 'HOLD'; $statusV2 = 'HOLD' }
    $timeoutMs = 15000
    if ($Operation -ceq 'waitForSettlement') { $timeoutMs = 300000 }
    elseif ($Operation -ceq 'dispatchWorker') { $timeoutMs = 60000 }
    $proof = 'exact-binary-live-api-effect-observable'
    if ($isHold) { $proof = 'exact-binary-live-required-before-SUPPORTED' }
    return [pscustomobject]@{
        operation      = [string]$Operation
        input          = 'typed-caller-provided'
        identity       = 'pid-plus-creation-ticks-per-generation'
        authorization  = 'user-project-runtime-grants-intersection'
        result         = 'typed-closed'
        timeout_ms     = [int]$timeoutMs
        error          = 'closed-token'
        fallback       = 'fallback-continue-when-optional-else-blocked'
        proof_required = [string]$proof
        v1             = [string]$statusV1
        v2             = [string]$statusV2
        grants_authority = $false
        done_approved    = $false
    }
}

function Get-OrchestrationAdapterRuntimePins {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    $v1 = $null
    $v2 = $null
    try {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
            $v1 = Get-OrchestrationRuntimeVersion -Name 'v1'
            $v2 = Get-OrchestrationRuntimeVersion -Name 'v2'
        }
        else {
            $v1 = Get-OrchestrationRuntimeVersion -Name 'v1' -RepoRoot $RepoRoot
            $v2 = Get-OrchestrationRuntimeVersion -Name 'v2' -RepoRoot $RepoRoot
        }
    }
    catch {
        throw ('adapter contract: pins de runtime irresoluveis (fail-closed): ' + $_.Exception.Message)
    }
    return [pscustomobject]@{
        v1 = [string]$v1.Spec
        v2 = [string]$v2.Spec
    }
}

function Get-OrchestrationAdapterAuthOperations {
    [CmdletBinding()]
    param()
    # D5 closed decision set: each productive stage owns its decision
    # (dispatch / reconcile / settlement / checkpoint / advance /
    # terminalize). The envelope admits exactly one decision per call;
    # settlement never reuses the dispatch envelope, reconcile is
    # per-intent. Aliases below map historical adapter op names.
    return @('dispatch', 'reconcile', 'settlement', 'checkpoint', 'advance', 'terminalize')
}

function New-OrchestrationAdapterAuthEnvelope {
    [CmdletBinding()]
    param(
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        [bool]$Optional = $false,
        [string]$Operation = '',
        [string]$Resource = '',
        [string]$Decision = ''
    )
    $missing = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($User)) { [void]$missing.Add('user') }
    if ([string]::IsNullOrWhiteSpace($Project)) { [void]$missing.Add('project') }
    if ([string]::IsNullOrWhiteSpace($Runtime)) { [void]$missing.Add('runtime') }
    if ([string]::IsNullOrWhiteSpace($Grants)) { [void]$missing.Add('grants') }
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            ok                 = $false
            admitted           = $false
            reason             = ('POLICY-BLOCKED:missing-' + ($missing -join ','))
            fallback_continue  = [bool]$Optional
            operation          = [string]$Operation
            resource           = [string]$Resource
            decision           = [string]$Decision
            explicit_allow     = $false
            grant_ref          = ''
            grants_authority   = $false
            done_approved      = $false
        }
    }
    # D5: closed operation set. The requested operation normalizes through
    # the alias map; empty/unknown/malformed => denied fail-closed (never
    # admitted by facet presence alone).
    $opCanon = ([string]$Operation).Trim().ToLowerInvariant()
    $opAlias = @{
        dispatchworker    = 'dispatch'
        dispatch          = 'dispatch'
        reconcileeffect   = 'reconcile'
        reconcile         = 'reconcile'
        waitforsettlement = 'settlement'
        settle            = 'settlement'
        settlement        = 'settlement'
        checkpoint        = 'checkpoint'
        advance           = 'advance'
        nextmove          = 'advance'
        terminalize       = 'terminalize'
        terminal          = 'terminalize'
    }
    if ([string]::IsNullOrWhiteSpace($opCanon) -or (-not $opAlias.ContainsKey($opCanon))) {
        return [pscustomobject]@{
            ok                 = $false
            admitted           = $false
            reason             = 'POLICY-BLOCKED:operation-not-allowed'
            fallback_continue  = $false
            operation          = [string]$Operation
            resource           = [string]$Resource
            decision           = [string]$Decision
            explicit_allow     = $false
            grant_ref          = ''
            grants_authority   = $false
            done_approved      = $false
        }
    }
    $op = [string]$opAlias[$opCanon]
    $resCanon = ([string]$Resource).Trim().ToLowerInvariant()
    # F7 strict grammar: structured deny-wins intersection. Any
    # deny/inconclusive grant token (bare or scoped deny:<op>[:<resource>])
    # denies the whole envelope fail-closed, even when the other facets
    # are present; any malformed colon token denies too. Bare capability
    # labels without ':' (e.g. 'ops', 'g', 'fs.read') stay ignored.
    # Presence alone never admits.
    $denied = $false
    $malformedGrant = $false
    try {
        $toks = @([string]$Grants -split '[,;|\s]+')
        foreach ($t in $toks) {
            $rawTok = ([string]$t).Trim()
            if ([string]::IsNullOrWhiteSpace($rawTok)) { continue }
            $tok = $rawTok.ToLowerInvariant()
            if (($tok -ceq 'deny') -or ($tok -ceq 'denied') -or ($tok -ceq 'deny-all') -or ($tok -ceq 'inconclusive') -or ($tok -ceq 'unknown') -or ($tok -ceq 'none')) {
                $denied = $true
                break
            }
            if ($tok.StartsWith('deny:') -or $tok.StartsWith('denied:') -or $tok.StartsWith('deny-all')) {
                $denied = $true
                break
            }
            if ($tok.StartsWith('allow:')) {
                $rest = $tok.Substring(6)
                $parts = @($rest -split ':')
                $bad = $false
                if ([string]::IsNullOrWhiteSpace($rest)) { $bad = $true }
                elseif (($parts.Count -lt 1) -or ($parts.Count -gt 2)) { $bad = $true }
                elseif (@('dispatch', 'reconcile', 'settlement', 'checkpoint', 'advance', 'terminalize') -cnotcontains $parts[0]) { $bad = $true }
                elseif (($parts.Count -eq 2) -and (([string]::IsNullOrWhiteSpace($parts[1])) -or ((($parts[1] -cne '*') -and ($parts[1] -cnotmatch '^[a-z0-9._:-]+$'))))) { $bad = $true }
                if ($bad) { $malformedGrant = $true; break }
                continue
            }
            if ($rawTok.Contains(':')) { $malformedGrant = $true; break }
        }
    }
    catch { $denied = $false }
    # F7: a negative caller Decision vetoes any allow, even with a valid
    # grant reference (deny prevails in any order).
    $decisionDeny = $false
    try {
        $dLow = ([string]$Decision).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($dLow)) {
            if (($dLow -ceq 'deny') -or ($dLow -ceq 'denied') -or ($dLow -ceq 'deny-all') -or ($dLow -ceq 'inconclusive') -or ($dLow -ceq 'unknown') -or ($dLow -ceq 'none')) { $decisionDeny = $true }
            elseif ($dLow.StartsWith('deny:') -or $dLow.StartsWith('denied:') -or $dLow.StartsWith('deny-all')) { $decisionDeny = $true }
        }
    }
    catch { $decisionDeny = $false }
    if ($denied -or $malformedGrant -or $decisionDeny) {
        return [pscustomobject]@{
            ok                 = $false
            admitted           = $false
            reason             = 'POLICY-BLOCKED:grants-deny'
            fallback_continue  = $false
            operation          = [string]$Operation
            resource           = [string]$Resource
            decision           = [string]$Decision
            explicit_allow     = $false
            grant_ref          = ''
            grants_authority   = $false
            done_approved      = $false
        }
    }
    # D5: explicit allow per operation/resource. The Grants string must
    # carry a verifiable grant reference of the form 'allow:<op>' or
    # 'allow:<op>:<resource>' (resource '*' matches any). A caller-claimed
    # Decision='allow' is NEVER a self-grant: without the grant reference
    # the envelope denies fail-closed. No external policy file is ever
    # consulted as an authorizer here.
    $grantRef = ''
    try {
        $toks = @([string]$Grants -split '[,;|\s]+')
        foreach ($t in $toks) {
            $tok = ([string]$t).Trim().ToLowerInvariant()
            if (($tok.Length -le 6) -or (-not $tok.StartsWith('allow:'))) { continue }
            $rest = $tok.Substring(6)
            $parts = @($rest -split ':')
            if (($parts.Count -eq 1) -and ($parts[0] -ceq $op)) { $grantRef = ([string]$t).Trim(); break }
            if (($parts.Count -eq 2) -and ($parts[0] -ceq $op) -and (-not [string]::IsNullOrWhiteSpace($parts[1]))) {
                if (-not [string]::IsNullOrWhiteSpace($resCanon)) {
                    if (($parts[1] -ceq '*') -or ($parts[1] -ceq $resCanon)) { $grantRef = ([string]$t).Trim(); break }
                }
            }
        }
    }
    catch { $grantRef = '' }
    if ([string]::IsNullOrWhiteSpace($grantRef)) {
        $whyNot = 'POLICY-BLOCKED:operation-not-authorized'
        try {
            if (([string]$Decision).Trim().ToLowerInvariant() -ceq 'allow') { $whyNot = 'POLICY-BLOCKED:self-grant-rejected' }
        }
        catch { }
        return [pscustomobject]@{
            ok                 = $false
            admitted           = $false
            reason             = [string]$whyNot
            fallback_continue  = $false
            operation          = [string]$Operation
            resource           = [string]$Resource
            decision           = [string]$Decision
            explicit_allow     = $false
            grant_ref          = ''
            grants_authority   = $false
            done_approved      = $false
        }
    }
    return [pscustomobject]@{
        ok                 = $true
        admitted           = $true
        reason             = 'intersection-user-project-runtime-grants'
        fallback_continue  = $false
        operation          = [string]$Operation
        resource           = [string]$Resource
        decision           = [string]$Decision
        explicit_allow     = $true
        grant_ref          = [string]$grantRef
        grants_authority   = $false
        done_approved      = $false
    }
}

function New-OrchestrationAdapterHoldResult {
    [CmdletBinding()]
    param(
        [string]$Operation = '',
        [string]$Runtime = '',
        [string]$Cause = 'no-proven-api-effect-observable',
        [bool]$Optional = $true
    )
    if (-not (Test-OrchestrationAdapterOperation -Operation $Operation)) {
        throw ('adapter contract: operacao desconhecida: ' + [string]$Operation)
    }
    if (-not (Test-OrchestrationAdapterRuntime -Runtime $Runtime)) {
        throw ('adapter contract: runtime desconhecido (esperado V1|V2): ' + [string]$Runtime)
    }
    $allowed = Get-OrchestrationAdapterHoldCauses
    if ($allowed -notcontains $Cause) {
        throw ('adapter contract: causa fora da allowlist: ' + [string]$Cause)
    }
    $holds = Get-OrchestrationAdapterHoldOperations
    if ($holds -notcontains $Operation) {
        throw ('adapter contract: hold nao aplicavel a operacao SPECIFIABLE (use o construtor da op): ' + [string]$Operation)
    }
    $status = 'unavailable'
    if (($Cause -ceq 'runtime-grant-enforcement-hold') -or ($Cause -ceq 'cancel-deny-not-proven')) {
        $status = 'blocked'
    }
    return [pscustomobject]@{
        ok                = $false
        operation         = [string]$Operation
        runtime           = [string]$Runtime
        status            = [string]$status
        cause             = [string]$Cause
        fallback_continue = [bool]$Optional
        grants_authority  = $false
        done_approved     = $false
        verified_pass     = $false
        proof             = 'none-no-exact-binary-live'
    }
}

function Invoke-OrchestrationAdapterDetectCapabilities {
    [CmdletBinding()]
    param(
        [string]$ProbeOutput = '',
        [string]$Runtime = '',
        [string]$RepoRoot = ''
    )
    if (-not (Test-OrchestrationAdapterRuntime -Runtime $Runtime)) {
        throw ('adapter contract: runtime desconhecido (esperado V1|V2): ' + [string]$Runtime)
    }
    if ([string]::IsNullOrWhiteSpace($ProbeOutput)) {
        return [pscustomobject]@{
            ok                = $false
            operation         = 'detectCapabilities'
            runtime           = [string]$Runtime
            status            = 'unavailable'
            cause             = 'probe-output-missing'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    $major = 0
    $found = $false
    foreach ($ln in @([string]$ProbeOutput -split "`r?`n")) {
        $m = [regex]::Match($ln, '(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) {
            $found = $true
            $major = [int]$m.Groups[1].Value
            break
        }
    }
    if (-not $found) {
        return [pscustomobject]@{
            ok                = $false
            operation         = 'detectCapabilities'
            runtime           = [string]$Runtime
            status            = 'unavailable'
            cause             = 'probe-output-unrecognized'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    $pins = $null
    try {
        $pins = Get-OrchestrationAdapterRuntimePins -RepoRoot $RepoRoot
    }
    catch {
        throw ('adapter contract: detectCapabilities fail-closed sem registry: ' + $_.Exception.Message)
    }
    $wantMajor = 1
    if ($Runtime -ceq 'V2') { $wantMajor = 2 }
    $pinSpec = [string]$pins.v1
    if ($Runtime -ceq 'V2') { $pinSpec = [string]$pins.v2 }
    $matched = ($major -eq $wantMajor)
    $reason = 'probe-major-matches-pin-generation'
    if (-not $matched) { $reason = ('probe-major-mismatch-expected-' + $wantMajor + '-got-' + $major) }
    return [pscustomobject]@{
        ok                = [bool]$matched
        operation         = 'detectCapabilities'
        runtime           = [string]$Runtime
        status            = 'probed'
        major             = [int]$major
        pin_spec          = [string]$pinSpec
        probe_matched     = [bool]$matched
        reason            = [string]$reason
        fallback_continue = (-not $matched)
        grants_authority  = $false
        done_approved     = $false
        verified_pass     = $false
    }
}

function New-OrchestrationAdapterSessionIdentity {
    [CmdletBinding()]
    param(
        [string]$SessionMapId = '',
        [string]$ProbeObservation = ''
    )
    $source = 'neutral'
    $sessionId = ''
    $resolved = $false
    if (-not [string]::IsNullOrWhiteSpace($SessionMapId)) {
        $source = 'session-map'
        $sessionId = [string]$SessionMapId
        $resolved = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProbeObservation)) {
        $source = 'input-probe'
        $sessionId = [string]$ProbeObservation
        $resolved = $true
    }
    return [pscustomobject]@{
        ok               = $true
        operation        = 'identifySession'
        identity_source  = [string]$source
        session_id       = [string]$sessionId
        resolved         = [bool]$resolved
        grants_authority = $false
        done_approved    = $false
        verified_pass    = $false
    }
}

function New-OrchestrationAdapterRestorePlan {
    [CmdletBinding()]
    param(
        $ContinuationEnvelope = $null,
        [string]$Runtime = ''
    )
    if (-not (Test-OrchestrationAdapterRuntime -Runtime $Runtime)) {
        throw ('adapter contract: runtime desconhecido (esperado V1|V2): ' + [string]$Runtime)
    }
    $taskId = ''
    try {
        if ($null -ne $ContinuationEnvelope) {
            if ($null -ne $ContinuationEnvelope.PSObject.Properties['task_id']) {
                $taskId = [string]$ContinuationEnvelope.task_id
            }
        }
    }
    catch { $taskId = '' }
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        return [pscustomobject]@{
            ok                = $false
            operation         = 'restoreContext'
            runtime           = [string]$Runtime
            status            = 'unavailable'
            cause             = 'envelope-without-task-id'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    return [pscustomobject]@{
        ok                = $true
        operation         = 'restoreContext'
        runtime           = [string]$Runtime
        task_id           = [string]$taskId
        mode              = 'kernel-side-context'
        snapshots         = 'auxiliary-only'
        event_log         = 'auxiliary-only'
        overrides_git     = $false
        overrides_worktree = $false
        grants_authority  = $false
        done_approved     = $false
        verified_pass     = $false
    }
}

function New-OrchestrationAdapterWorkerObservation {
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$RunId = '',
        [string]$SessionId = '',
        [string]$Observed = '',
        [string]$OutputRef = ''
    )
    foreach ($pair in @(@('task_id', $TaskId), @('run_id', $RunId), @('session_id', $SessionId))) {
        $v = [string]$pair[1]
        if ([string]::IsNullOrWhiteSpace($v)) {
            return [pscustomobject]@{
                ok                = $false
                operation         = 'observeWorkerResult'
                status            = 'unavailable'
                cause             = ('missing-' + [string]$pair[0])
                fallback_continue = $true
                grants_authority  = $false
                done_approved     = $false
                verified_pass     = $false
            }
        }
    }
    return [pscustomobject]@{
        ok                = $true
        operation         = 'observeWorkerResult'
        task_id           = [string]$TaskId
        run_id            = [string]$RunId
        session_id        = [string]$SessionId
        observed          = [string]$Observed
        output_ref        = [string]$OutputRef
        verified          = $false
        verification      = 'kernel-allowlisted-only'
        grants_authority  = $false
        done_approved     = $false
        verified_pass     = $false
    }
}

function Test-OrchestrationAdapterEvidenceSink {
    [CmdletBinding()]
    param([string]$StoreDir = '')
    if ([string]::IsNullOrWhiteSpace($StoreDir)) {
        return [pscustomobject]@{
            ok                = $false
            operation         = 'recordRuntimeEvidence'
            writable          = $false
            reason            = 'write-unavailable'
            cause             = 'store-dir-missing'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    if (-not (Test-Path -LiteralPath $StoreDir -PathType Container)) {
        return [pscustomobject]@{
            ok                = $false
            operation         = 'recordRuntimeEvidence'
            writable          = $false
            reason            = 'write-unavailable'
            cause             = 'store-dir-not-container'
            fallback_continue = $true
            grants_authority  = $false
            done_approved     = $false
            verified_pass     = $false
        }
    }
    return [pscustomobject]@{
        ok                = $true
        operation         = 'recordRuntimeEvidence'
        writable          = $true
        reason            = 'jsonl-sink-container'
        fallback_continue = $false
        grants_authority  = $false
        done_approved     = $false
        verified_pass     = $false
    }
}

function New-OrchestrationAdapterEvidenceRow {
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$RunId = '',
        [string]$WorkerId = '',
        [string]$Summary = ''
    )
    foreach ($pair in @(@('task_id', $TaskId), @('run_id', $RunId), @('worker_id', $WorkerId))) {
        $v = [string]$pair[1]
        if (([string]::IsNullOrWhiteSpace($v)) -or ($v.Length -gt 128) -or ($v -notmatch '^[A-Za-z0-9._:-]{1,128}$')) {
            return [pscustomobject]@{
                ok                = $false
                operation         = 'recordRuntimeEvidence'
                status            = 'unavailable'
                cause             = ('invalid-' + [string]$pair[0])
                fallback_continue = $true
                grants_authority  = $false
                done_approved     = $false
                verified_pass     = $false
            }
        }
    }
    $safe = [string]$Summary
    if ($safe.Length -gt 240) { $safe = $safe.Substring(0, 240) }
    return [pscustomobject]@{
        ok               = $true
        operation        = 'recordRuntimeEvidence'
        task_id          = [string]$TaskId
        run_id           = [string]$RunId
        worker_id        = [string]$WorkerId
        summary          = [string]$safe
        sink             = 'jsonl'
        grants_authority = $false
        done_approved    = $false
        verified_pass    = $false
    }
}

function Get-OrchestrationAdapterCredentialName {
    [CmdletBinding()]
    param([string]$Name = '')
    $v = [string]$Name
    if (([string]::IsNullOrWhiteSpace($v)) -or ($v -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$')) {
        throw ('adapter contract: nome de credencial invalido (nomes apenas, nunca valores): ' + [string]$Name)
    }
    return [pscustomobject]@{
        name         = [string]$v
        is_name_only = $true
        value_read   = $false
    }
}

function Get-OrchestrationAdapterWatchdogReference {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        signals         = @('NO_PROGRESS', 'HARD_TIMEOUT')
        mode            = 'referenced-not-driven'
        drives_watchdog = $false
        grants_authority = $false
        done_approved    = $false
    }
}
