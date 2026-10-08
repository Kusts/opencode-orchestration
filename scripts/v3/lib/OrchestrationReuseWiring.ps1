<#!
.SYNOPSIS
    PR-4 Reuse Wiring: hardening over the evidence store (HOLD, Planner decides).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Fail-closed, PS 5.1
    compatible, ASCII-only. Never throws on operational paths: every
    failure is a reexecute envelope. No network, no process spawn, no
    secret values, no mutation of existing stores (read-only over
    OrchestrationEvidenceStore.ps1; candidate files are only read).

    Hardening rules (CORRECTIVE-PLAN Fase 3, PR-4):

      - store_dir default automatico: resolved under the repo-local
        cache (cache/reuse-store) when the caller passes none; the
        store is local-only, never remote.
      - TTL default por classe, nunca um TTL global arbitrario:
        content-fingerprint (content immutable, addressed by
        fingerprint) requires no TTL condition; service-response
        defaults to 3600s; external-behavior defaults to 900s. An
        unknown class fails closed (no reuse). Records of a TTL
        class without a ttl condition are stale (reexecute).
      - invalidez por provenance (missing created_by or
        kernel_task_ref means no reuse), criteria-drift, base-drift,
        env-drift, revoked and ttl-expiry, delegated to
        Test-OrchestrationEvidenceValidity for drift plus explicit
        local checks for provenance and class TTL.
      - reuse nunca equivale a verification: every envelope carries
        verified_pass=false and planner_decides=true; a hit is a
        reuse CANDIDATE that reduces work, the Planner alone
        decides and the verifier alone passes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $RWLibPath = Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1'
    if (Test-Path -LiteralPath $RWLibPath -PathType Leaf) { . $RWLibPath }
}
catch { }

$script:ReuseWiringTtlSeconds = @{
    'content-fingerprint' = 0
    'service-response'    = 3600
    'external-behavior'   = 900
}
$script:ReuseWiringDefaultClass = 'external-behavior'

function Get-OrchestrationReuseWiringVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-REUSE-WIRING'
        phase          = 'PR-4'
    }
}

function Get-RWFieldValue {
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

function Get-OrchestrationReuseRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    }
    catch { return '' }
}

function Get-OrchestrationReuseDefaultStoreDir {
    [CmdletBinding()]
    param([string]$StoreDir = '', [string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($StoreDir)) { return ([string]$StoreDir).Trim() }
        $root = Get-OrchestrationReuseRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        $dir = Join-Path (Join-Path $root 'cache') 'reuse-store'
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return '' }
        return $dir
    }
    catch { return '' }
}

function Get-OrchestrationReuseDefaultTtlSeconds {
    [CmdletBinding()]
    param([string]$ReuseClass = '')
    try {
        $c = ([string]$ReuseClass).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($c)) { $c = [string]$script:ReuseWiringDefaultClass }
        if ($script:ReuseWiringTtlSeconds.Contains($c)) { return [int]$script:ReuseWiringTtlSeconds[$c] }
        return -1
    }
    catch { return -1 }
}

function Get-OrchestrationReuseTtlExpiry {
    [CmdletBinding()]
    param($CreatedAt = $null, [string]$ReuseClass = '', [int]$TtlSecondsOverride = 0)
    try {
        $ttl = [int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass $ReuseClass)
        if ([int]$TtlSecondsOverride -gt 0) { $ttl = [int]$TtlSecondsOverride }
        if ($ttl -lt 0) { return '' }
        if ($ttl -eq 0) { return '' }
        $base = $null
        try {
            if ($CreatedAt -is [DateTimeOffset]) { $base = $CreatedAt.UtcDateTime }
            elseif ($CreatedAt -is [DateTime]) {
                $dt = [DateTime]$CreatedAt
                if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return '' }
                $base = $dt.ToUniversalTime()
            }
            else {
                $text = ([string]$CreatedAt).Trim()
                if ([string]::IsNullOrWhiteSpace($text)) { return '' }
                $parsed = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return '' }
                $base = $parsed.UtcDateTime
            }
        }
        catch { return '' }
        if ($null -eq $base) { return '' }
        return ([DateTime]$base).AddSeconds([double]$ttl).ToString('o')
    }
    catch { return '' }
}

function New-OrchestrationReuseEnvelope {
    [CmdletBinding()]
    param(
        [bool]$Reused = $false,
        [string]$Decision = 'reexecute',
        $Candidates = $null,
        [string[]]$Reasons = @(),
        [string]$StoreDir = '',
        [string]$ReuseClass = ''
    )
    try {
        $list = @()
        if ($null -ne $Candidates) { $list = @($Candidates) }
        $why = @()
        if ($null -ne $Reasons) { $why = @($Reasons) }
        return [pscustomobject]@{
            ok             = $true
            reused         = [bool]$Reused
            decision       = ([string]$Decision)
            candidates     = $list
            reasons        = $why
            work_saved     = ([bool]$Reused -and (@($list).Count -gt 0))
            verified_pass  = $false
            planner_decides = $true
            blocked        = $false
            store_dir      = ([string]$StoreDir)
            reuse_class    = ([string]$ReuseClass)
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $true; reused = $false; decision = 'reexecute'
            candidates = @(); reasons = @('internal-error')
            work_saved = $false; verified_pass = $false
            planner_decides = $true; blocked = $false
            store_dir = ''; reuse_class = ''
        }
    }
}

function Test-OrchestrationReuseCandidate {
    [CmdletBinding()]
    param($Record = $null, $Current = $null, [string]$ReuseClass = '')
    try {
        $cls = ([string]$ReuseClass).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($cls)) { $cls = [string]$script:ReuseWiringDefaultClass }
        if (-not $script:ReuseWiringTtlSeconds.Contains($cls)) {
            return [pscustomobject]@{
                reusable = $false; reasons = @('unknown-class-no-reuse')
                verified_pass = $false; planner_decides = $true
            }
        }
        if ($null -eq $Record) {
            return [pscustomobject]@{
                reusable = $false; reasons = @('record-missing-no-reuse')
                verified_pass = $false; planner_decides = $true
            }
        }
        $prov = Get-RWFieldValue $Record 'provenance' $null
        $by = ([string](Get-RWFieldValue $prov 'created_by' '')).Trim()
        $ref = ([string](Get-RWFieldValue $prov 'kernel_task_ref' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($by) -or [string]::IsNullOrWhiteSpace($ref)) {
            return [pscustomobject]@{
                reusable = $false; reasons = @('provenance-missing-no-reuse')
                verified_pass = $false; planner_decides = $true
            }
        }
        $ttlNeed = [int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass $cls)
        $validCmd = Get-Command Test-OrchestrationEvidenceValidity -ErrorAction SilentlyContinue
        if ($null -eq $validCmd) {
            return [pscustomobject]@{
                reusable = $false; reasons = @('validity-check-unavailable-no-reuse')
                verified_pass = $false; planner_decides = $true
            }
        }
        $cur = $Current
        if ($null -eq $cur) { $cur = @{} }
        $v = $null
        try { $v = Test-OrchestrationEvidenceValidity $Record $cur }
        catch { $v = $null }
        if ($null -eq $v) {
            return [pscustomobject]@{
                reusable = $false; reasons = @('validity-check-failed-no-reuse')
                verified_pass = $false; planner_decides = $true
            }
        }
        $ok = $false
        try { $ok = [bool](Get-RWFieldValue $v 'reusable' $false) } catch { $ok = $false }
        $why = @()
        try { $why = @(Get-RWFieldValue $v 'reasons' @()) } catch { $why = @('invalid') }
        if ($ok) {
            if ($ttlNeed -gt 0) {
                $conds = @(Get-RWFieldValue $Record 'invalidation_conditions' @())
                $hasTtl = $false
                foreach ($c in @($conds)) {
                    try {
                        if ([string](Get-RWFieldValue $c 'type' '') -ceq 'ttl') { $hasTtl = $true; break }
                    }
                    catch { }
                }
                if (-not $hasTtl) {
                    return [pscustomobject]@{
                        reusable = $false; reasons = @('ttl-missing-stale-reexecute')
                        verified_pass = $false; planner_decides = $true
                    }
                }
            }
            return [pscustomobject]@{
                reusable = $true; reasons = @()
                verified_pass = $false; planner_decides = $true
            }
        }
        $flat = New-Object System.Collections.Generic.List[string]
        foreach ($r in @($why)) {
            $s = ([string]$r).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $flat.Add($s) | Out-Null
        }
        if (@($flat.ToArray()).Count -eq 0) { $flat.Add('invalid-reexecute') | Out-Null }
        return [pscustomobject]@{
            reusable = $false; reasons = ([string[]]$flat.ToArray())
            verified_pass = $false; planner_decides = $true
        }
    }
    catch {
        return [pscustomobject]@{
            reusable = $false; reasons = @('internal-error-no-reuse')
            verified_pass = $false; planner_decides = $true
        }
    }
}

function Find-OrchestrationReusableWork {
    [CmdletBinding()]
    param(
        [string[]]$Scope = @(),
        $CurrentSourceFingerprints = $null,
        [string]$CurrentBaseRevision = '',
        [string]$CurrentCriteriaHash = '',
        $CurrentEnv = $null,
        [string]$Now = '',
        [string]$ReuseClass = 'external-behavior',
        [string]$StoreDir = '',
        [string]$RepoRoot = '',
        [int]$MaxResults = 10
    )
    try {
        $cls = ([string]$ReuseClass).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($cls)) { $cls = [string]$script:ReuseWiringDefaultClass }
        $dir = Get-OrchestrationReuseDefaultStoreDir -StoreDir $StoreDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons @('store-dir-unresolvable-reexecute') -StoreDir '' -ReuseClass $cls)
        }
        if (-not $script:ReuseWiringTtlSeconds.Contains($cls)) {
            return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons @('unknown-class-no-reuse') -StoreDir $dir -ReuseClass $cls)
        }
        $findCmd = Get-Command Find-ReusableOrchestrationEvidence -ErrorAction SilentlyContinue
        if ($null -eq $findCmd) {
            return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons @('evidence-store-unavailable-reexecute') -StoreDir $dir -ReuseClass $cls)
        }
        $nowText = ([string]$Now).Trim()
        if ([string]::IsNullOrWhiteSpace($nowText)) { $nowText = ([DateTime]::UtcNow).ToString('o') }
        $fps = $CurrentSourceFingerprints
        if ($null -eq $fps) { $fps = @{} }
        $envNow = $CurrentEnv
        if ($null -eq $envNow) { $envNow = @{} }
        $max = [int]$MaxResults
        if ($max -lt 1) { $max = 1 }
        if ($max -gt 100) { $max = 100 }
        $hits = $null
        $missBefore = @{}
        try {
            $mbCmd = Get-Command Get-OrchestrationEvidenceMetrics -ErrorAction SilentlyContinue
            if ($null -ne $mbCmd) {
                $mb = Get-OrchestrationEvidenceMetrics $dir
                $mbMap = Get-RWFieldValue $mb 'misses_by_reason' $null
                if ($mbMap -is [System.Collections.IDictionary]) {
                    foreach ($k in @($mbMap.Keys)) { $missBefore[[string]$k] = [int]$mbMap[[string]$k] }
                }
            }
        }
        catch { }
        try {
            $fpsTable = @{}
            if ($fps -is [System.Collections.IDictionary]) {
                foreach ($k in @($fps.Keys)) { $fpsTable[[string]$k] = ([string]$fps[[string]$k]) }
            }
            $hits = Find-ReusableOrchestrationEvidence $dir $Scope $fpsTable ([string]$CurrentBaseRevision) ([string]$CurrentCriteriaHash) $envNow $nowText $max
        }
        catch { $hits = $null }
        if ($null -eq $hits) {
            return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons @('store-query-failed-reexecute') -StoreDir $dir -ReuseClass $cls)
        }
        $kept = New-Object System.Collections.ArrayList
        $dropReasons = New-Object System.Collections.Generic.List[string]
        $current = @{
            current_source_fingerprints = $fps
            current_base_revision       = ([string]$CurrentBaseRevision)
            current_criteria_hash       = ([string]$CurrentCriteriaHash)
            current_env                 = $envNow
            now                         = $nowText
        }
        foreach ($h in @($hits)) {
            try {
                $eid = ([string](Get-RWFieldValue $h 'evidence_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($eid)) { $dropReasons.Add('candidate-id-missing') | Out-Null; continue }
                if ($eid -notmatch '^[a-f0-9]{32}$') { $dropReasons.Add('candidate-id-invalid') | Out-Null; continue }
                $full = $null
                try {
                    $fp = Join-Path $dir ($eid + '.json')
                    if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { $dropReasons.Add('candidate-record-missing') | Out-Null; continue }
                    $full = ([IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8) | ConvertFrom-Json)
                }
                catch { $dropReasons.Add('candidate-record-unreadable') | Out-Null; continue }
                $t = Test-OrchestrationReuseCandidate -Record $full -Current $current -ReuseClass $cls
                if ([bool](Get-RWFieldValue $t 'reusable' $false)) {
                    [void]$kept.Add($h)
                }
                else {
                    foreach ($r in @(Get-RWFieldValue $t 'reasons' @())) {
                        $s = ([string]$r).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($s)) { $dropReasons.Add($s) | Out-Null }
                    }
                }
            }
            catch { $dropReasons.Add('candidate-check-failed') | Out-Null }
        }
        if (@($kept.ToArray()).Count -gt 0) {
            return (New-OrchestrationReuseEnvelope -Reused $true -Decision 'reuse-candidate' -Candidates @($kept.ToArray()) -Reasons @() -StoreDir $dir -ReuseClass $cls)
        }
        try {
            $mbCmd = Get-Command Get-OrchestrationEvidenceMetrics -ErrorAction SilentlyContinue
            if ($null -ne $mbCmd) {
                $ma = Get-OrchestrationEvidenceMetrics $dir
                $maMap = Get-RWFieldValue $ma 'misses_by_reason' $null
                if ($maMap -is [System.Collections.IDictionary]) {
                    foreach ($k in @($maMap.Keys)) {
                        $bef = 0
                        if ($missBefore.Contains([string]$k)) { $bef = [int]$missBefore[[string]$k] }
                        if ([int]$maMap[[string]$k] -gt $bef) { $dropReasons.Add([string]$k) | Out-Null }
                    }
                }
            }
        }
        catch { }
        $why = ([string[]]$dropReasons.ToArray())
        if (@($why).Count -eq 0) { $why = @('no-candidate-reexecute') }
        return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons $why -StoreDir $dir -ReuseClass $cls)
    }
    catch {
        return (New-OrchestrationReuseEnvelope -Reused $false -Decision 'reexecute' -Candidates @() -Reasons @('internal-error-reexecute') -StoreDir '' -ReuseClass ([string]$ReuseClass))
    }
}
