<#!
.SYNOPSIS
    V3 Model Routing record-only contracts (PLAN-F1, issue #99).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements SPEC
    MODEL-ROUTER-vNext-SPEC.md section 4 as shadow types only:

      New-ModelRoutingRequest -> normalized request (SPEC 4.1)
      New-ModelRoutingResult -> normalized result proposal (SPEC 4.2)
      Test-ModelRoutingEnvelope -> closed validation envelope (SPEC 4.3)

    RECORD-ONLY: constructed, validated and log-ready, NEVER read by the
    dispatch (no field added to OrchestrationNativeDispatch.ps1:791-905
    nor OrchestrationDispatchPipeline.ps1:506), no network/model call,
    no config/registry/template write, no flag activation.

    Precedence enforced inside Test-ModelRoutingEnvelope (SPEC section 3
    and 4.3, PLAN section 3): invariants (deny, allowlist/matrix section 5,
    paid/authorization, quotas, grants/scope via PlannerApproved) are
    validated BEFORE any user_model_override short-circuit. Override
    eliminates the CONSULTATION (consulted_router=false) but NEVER the
    validation: a prohibited, out-of-envelope, quota-exhausted or
    paid-without-authorization override is refused with DENY_POLICY (or
    candidate_out_of_envelope for non-override out-of-matrix picks) and
    falls back to the static baseline.

    PowerShell 5.1 compatible. ASCII-only. Never throws across the
    boundary: every failure is a closed fallback envelope.
#>
[CmdletBinding()]
param()

# No script-scope $ErrorActionPreference here: this file is dot-sourced, so a
# script-scope assignment would leak into the caller. Each function sets its
# own function-local preference instead (REV-F1-LIB).

$script:ModelRoutingRoles = @(
    'coder', 'explorer', 'researcher', 'tester', 'reviewer', 'debugger',
    'security-reviewer', 'architect', 'docs-manager', 'frontend-engineer',
    'backend-engineer', 'database-engineer', 'ai-agent-engineer',
    'automation-engineer', 'infra-engineer', 'requirements-analyst',
    'engineering-advisor', 'product-designer', 'skeptic'
)
$script:ModelRoutingTaskClasses = @(
    'implementation', 'migration', 'analysis', 'research', 'debugging',
    'validation', 'review', 'documentation', 'planning', 'design',
    'testing', 'trivial'
)
$script:ModelRoutingRisks = @('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
$script:ModelRoutingUncertainties = @('low', 'medium', 'high')
$script:ModelRoutingReasons = @(
    'BASELINE_SUFFICIENT', 'ESCALATE_COMPLEXITY', 'CHEAPEN_COST',
    'OVERRIDE_USER', 'FALLBACK_DETERMINISTIC', 'DENY_POLICY', 'PROOF_ABSENT',
    'candidate_out_of_envelope'
)
$script:ModelRoutingMinConfidence = 0.5

function Get-ModelRoutingField {
    <#
    .SYNOPSIS
        Reads one named field from a hashtable or PSObject, returning
        $null when absent. Never throws.
    #>
    [CmdletBinding()]
    param($Object, [string]$Name)
    $ErrorActionPreference = 'Stop'
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Test-ModelRoutingPaidHit {
    <#
    .SYNOPSIS
        Conservative paid-model signal (SPEC 4.1/8 item 5): any paid or
        Astra reference requires explicit per-environment authorization.
        Never throws (fail-closed true on error).
    #>
    [CmdletBinding()]
    param([string]$Text)
    $ErrorActionPreference = 'Stop'
    try {
        $t = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($t)) { return $false }
        $low = $t.ToLowerInvariant()
        if ($low.Contains('paid') -or $low.Contains('astra')) { return $true }
        return $false
    }
    catch { return $true }
}

function Test-ModelRoutingDeniedHit {
    <#
    .SYNOPSIS
        Closed deny-list match (case-insensitive, exact element). Never throws.
    #>
    [CmdletBinding()]
    param([string]$Candidate, [object[]]$DeniedModels)
    $ErrorActionPreference = 'Stop'
    try {
        $c = ([string]$Candidate).Trim()
        if ([string]::IsNullOrWhiteSpace($c)) { return $false }
        foreach ($d in @($DeniedModels)) {
            $n = ([string]$d).Trim()
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($c -ieq $n) { return $true }
        }
        return $false
    }
    catch { return $true }
}

function Test-ModelRoutingStrictBool {
    <#
    .SYNOPSIS
        Strict boolean gate for the envelope boundary. Only a real [bool]
        passes through; the strings 'true'/'false'/'1'/'0' (any case,
        trimmed) and the integers 0/1 are parsed explicitly. Anything else
        (including $null or arrays) is invalid: ok=$false and
        value=$Default, letting the caller choose the fail-closed default.
        In particular the string 'false' NEVER becomes $true. Never throws.
    #>
    [CmdletBinding()]
    param($Value, [bool]$Default = $false)
    $ErrorActionPreference = 'Stop'
    try {
        if ($Value -is [bool]) {
            return [PSCustomObject]@{ ok = $true; value = [bool]$Value }
        }
        if (($Value -is [int]) -or ($Value -is [long])) {
            $n = [long]$Value
            if ($n -eq 1) { return [PSCustomObject]@{ ok = $true; value = $true } }
            if ($n -eq 0) { return [PSCustomObject]@{ ok = $true; value = $false } }
            return [PSCustomObject]@{ ok = $false; value = [bool]$Default }
        }
        if ($Value -is [string]) {
            $t = ([string]$Value).Trim()
            if (($t -ieq 'true') -or ($t -ieq '1')) { return [PSCustomObject]@{ ok = $true; value = $true } }
            if (($t -ieq 'false') -or ($t -ieq '0')) { return [PSCustomObject]@{ ok = $true; value = $false } }
            return [PSCustomObject]@{ ok = $false; value = [bool]$Default }
        }
        return [PSCustomObject]@{ ok = $false; value = [bool]$Default }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; value = $false }
    }
}

function Test-ModelRoutingStrictConfidence {
    <#
    .SYNOPSIS
        Strict confidence gate for the envelope boundary: only a real
        numeric type (int/long/double/decimal/single) that is finite and in
        the closed interval [0,1] is accepted. Strings (even '0.9'), $null,
        NaN and Infinity are invalid: ok=$false, value=0.0. Never throws.
    #>
    [CmdletBinding()]
    param($Value)
    $ErrorActionPreference = 'Stop'
    try {
        if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single])) {
            return [PSCustomObject]@{ ok = $false; value = 0.0 }
        }
        $d = 0.0
        try { $d = [double]$Value } catch { return [PSCustomObject]@{ ok = $false; value = 0.0 } }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) {
            return [PSCustomObject]@{ ok = $false; value = 0.0 }
        }
        if (($d -lt 0.0) -or ($d -gt 1.0)) {
            return [PSCustomObject]@{ ok = $false; value = 0.0 }
        }
        return [PSCustomObject]@{ ok = $true; value = $d }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; value = 0.0 }
    }
}

function Set-ModelRoutingFallbackSelection {
    <#
    .SYNOPSIS
        Applies the validated baseline to a fallback/deny envelope. When the
        fallback itself violates the invariants (deny-list hit,
        out-of-envelope, paid without authorization, blank), no baseline is
        permitted: selection is emptied and the envelope is explicitly
        blocked (denied=$true) with the fallback errors appended.
        Internal helper (not a boundary). Never throws.
    #>
    [CmdletBinding()]
    param($Out, [string]$Fallback = '', [bool]$FallbackOk = $true, [object[]]$FallbackErrs = @())
    $ErrorActionPreference = 'Stop'
    try {
        if ($null -eq $Out) { return }
        if ([bool]$FallbackOk) {
            $Out['selected'] = [string]$Fallback
        }
        else {
            $Out['selected'] = ''
            $Out['denied'] = $true
            $cur = @()
            try { $cur = @($Out['validation_errors']) } catch { $cur = @() }
            $Out['validation_errors'] = @($cur) + @($FallbackErrs)
        }
    }
    catch { }
}

function Test-ModelRoutingFallback {
    <#
    .SYNOPSIS
        Central fallback validator (REV-F1-LIB-R2): deny-list + paid +
        non-blank + membership in candidates, before any early return.
        Without a reliable matrix (no usable candidates) or with an
        invalid fallback, no baseline is permitted: ok=$false with an
        explicit error. Never throws (fail-closed invalid on error).
    #>
    [CmdletBinding()]
    param([string]$Fallback = '', [object[]]$Candidates = @(), [object[]]$DeniedModels = @(), [bool]$PaidAuthorized = $false)
    $ErrorActionPreference = 'Stop'
    try {
        $errs = New-Object System.Collections.Generic.List[string]
        $fb = ([string]$Fallback).Trim()
        if ([string]::IsNullOrWhiteSpace($fb)) {
            $errs.Add('fallback-blank') | Out-Null
            return [PSCustomObject]@{ ok = $false; errors = $errs.ToArray() }
        }
        if (Test-ModelRoutingDeniedHit -Candidate $fb -DeniedModels $DeniedModels) {
            $errs.Add('fallback-deny-list-hit') | Out-Null
        }
        if ((Test-ModelRoutingPaidHit -Text $fb) -and (-not [bool]$PaidAuthorized)) {
            $errs.Add('fallback-paid-without-authorization') | Out-Null
        }
        $clean = New-Object System.Collections.Generic.List[string]
        if ($null -ne $Candidates) {
            foreach ($c in @($Candidates)) {
                $s = ([string]$c).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $clean.Add($s) | Out-Null
            }
        }
        if ([int]$clean.Count -lt 1) {
            $errs.Add('fallback-matrix-unreliable') | Out-Null
        }
        else {
            $inMatrix = $false
            foreach ($c in @($clean.ToArray())) {
                if ([string]$fb -ceq [string]$c) { $inMatrix = $true; break }
            }
            if (-not $inMatrix) {
                $errs.Add('fallback-out-of-envelope') | Out-Null
            }
        }
        $ok = ([int]$errs.Count -eq 0)
        return [PSCustomObject]@{ ok = [bool]$ok; errors = $errs.ToArray() }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; errors = @('fallback-internal') }
    }
}

function New-ModelRoutingRequest {
    <#
    .SYNOPSIS
        Builds the normalized ModelRoutingRequest (SPEC 4.1). Never throws:
        structural problems yield is_valid=false plus validation_errors.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$Role = '',
        [string]$TaskClass = '',
        [string]$Risk = '',
        [object[]]$Candidates = @(),
        [string]$Fallback = '',
        $ContextSignals = $null,
        $CostLimits = $null,
        [object[]]$CapabilitiesRequired = @(),
        [string]$Uncertainty = '',
        [string]$UserModelOverride = ''
    )
    $ErrorActionPreference = 'Stop'
    try {
        $errors = New-Object System.Collections.Generic.List[string]
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { $errors.Add('task_id-blank') | Out-Null }
        $role = ([string]$Role).Trim().ToLowerInvariant()
        if ($script:ModelRoutingRoles -cnotcontains $role) { $errors.Add('role-unknown') | Out-Null }
        $tc = ([string]$TaskClass).Trim().ToLowerInvariant()
        if ($script:ModelRoutingTaskClasses -cnotcontains $tc) { $errors.Add('task_class-unknown') | Out-Null }
        $rk = ([string]$Risk).Trim().ToUpperInvariant()
        if ($script:ModelRoutingRisks -cnotcontains $rk) { $errors.Add('risk-unknown') | Out-Null }
        $cands = New-Object System.Collections.Generic.List[string]
        if ($null -ne $Candidates) {
            foreach ($c in @($Candidates)) {
                $s = ([string]$c).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $cands.Add($s) | Out-Null
            }
        }
        if ([int]$cands.Count -lt 1) { $errors.Add('candidates-empty') | Out-Null }
        $fb = ([string]$Fallback).Trim()
        if ([string]::IsNullOrWhiteSpace($fb)) { $errors.Add('fallback-blank') | Out-Null }
        $unc = ([string]$Uncertainty).Trim().ToLowerInvariant()
        if ((-not [string]::IsNullOrWhiteSpace($unc)) -and ($script:ModelRoutingUncertainties -cnotcontains $unc)) {
            $errors.Add('uncertainty-unknown') | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($unc)) { $unc = '' }
        $ovr = ([string]$UserModelOverride).Trim()
        if ([string]::IsNullOrWhiteSpace($ovr)) { $ovr = '' }
        $caps = New-Object System.Collections.Generic.List[string]
        if ($null -ne $CapabilitiesRequired) {
            foreach ($c in @($CapabilitiesRequired)) {
                $s = ([string]$c).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $caps.Add($s) | Out-Null
            }
        }
        $limits = @{ max_escalations_subtask = 1; max_above_baseline_per_objective = 2; max_paid_calls = 0 }
        if ($null -ne $CostLimits) {
            $e1 = Get-ModelRoutingField -Object $CostLimits -Name 'max_escalations_subtask'
            $e2 = Get-ModelRoutingField -Object $CostLimits -Name 'max_above_baseline_per_objective'
            $e3 = Get-ModelRoutingField -Object $CostLimits -Name 'max_paid_calls'
            $ok = $true
            try {
                if ($null -ne $e1) { $limits['max_escalations_subtask'] = [int]$e1 }
                if ($null -ne $e2) { $limits['max_above_baseline_per_objective'] = [int]$e2 }
                if ($null -ne $e3) { $limits['max_paid_calls'] = [int]$e3 }
            }
            catch { $ok = $false }
            if (-not $ok) { $errors.Add('cost_limits-malformed') | Out-Null }
            if ([int]$limits['max_escalations_subtask'] -gt 1) { $errors.Add('cost_limits-escalations-over-cap') | Out-Null }
            if ([int]$limits['max_escalations_subtask'] -lt 0) { $errors.Add('cost_limits-malformed') | Out-Null }
            if ([int]$limits['max_above_baseline_per_objective'] -gt 2) { $errors.Add('cost_limits-above-baseline-over-cap') | Out-Null }
            if ([int]$limits['max_above_baseline_per_objective'] -lt 0) { $errors.Add('cost_limits-malformed') | Out-Null }
            if ([int]$limits['max_paid_calls'] -lt 0) { $errors.Add('cost_limits-malformed') | Out-Null }
        }
        $valid = ([int]$errors.Count -eq 0)
        return [PSCustomObject][ordered]@{
            task_id               = $tid
            role                  = $role
            task_class            = $tc
            risk                  = $rk
            context_signals       = $ContextSignals
            cost_limits           = $limits
            candidates            = $cands.ToArray()
            capabilities_required = $caps.ToArray()
            uncertainty           = $unc
            user_model_override   = $ovr
            fallback              = $fb
            is_valid              = [bool]$valid
            validation_errors     = $errors.ToArray()
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            task_id               = ''
            role                  = ''
            task_class            = ''
            risk                  = ''
            context_signals       = $null
            cost_limits           = @{ max_escalations_subtask = 1; max_above_baseline_per_objective = 2; max_paid_calls = 0 }
            candidates            = @()
            capabilities_required = @()
            uncertainty           = ''
            user_model_override   = ''
            fallback              = ''
            is_valid              = $false
            validation_errors     = @('request-internal')
        }
    }
}

function New-ModelRoutingResult {
    <#
    .SYNOPSIS
        Builds the normalized ModelRoutingResult proposal (SPEC 4.2).
        Never throws: structural problems yield is_valid=false.
        Confidence uses the strict numeric-type gate (no string/bool
        coercion); range is the closed interval [0,1].
    #>
    [CmdletBinding()]
    param(
        [string]$Selected = '',
        [string]$Reason = '',
        $Confidence = $null,
        [string]$Fallback = '',
        [object[]]$PolicyRefs = @(),
        [object[]]$EvidenceRefs = @(),
        [bool]$EscalationConsumed = $false
    )
    $ErrorActionPreference = 'Stop'
    try {
        $errors = New-Object System.Collections.Generic.List[string]
        $sel = ([string]$Selected).Trim()
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '' }
        $rs = ([string]$Reason).Trim()
        $match = $false
        foreach ($r in @($script:ModelRoutingReasons)) {
            if ($rs -ceq $r) { $match = $true; $rs = [string]$r; break }
        }
        if (-not $match) { $errors.Add('reason-unknown') | Out-Null }
        $confOk = $true
        $conf = [double]::NaN
        if (-not ($Confidence -is [int] -or $Confidence -is [long] -or $Confidence -is [double] -or $Confidence -is [decimal] -or $Confidence -is [single])) {
            $confOk = $false
        }
        else {
            try { $conf = [double]$Confidence } catch { $confOk = $false }
            if ([double]::IsNaN($conf) -or [double]::IsInfinity($conf)) { $confOk = $false }
            elseif (($conf -lt 0.0) -or ($conf -gt 1.0)) { $confOk = $false }
        }
        if (-not $confOk) { $errors.Add('confidence-invalid') | Out-Null; $conf = 0.0 }
        $fb = ([string]$Fallback).Trim()
        if ([string]::IsNullOrWhiteSpace($fb)) { $errors.Add('fallback-blank') | Out-Null }
        $pol = New-Object System.Collections.Generic.List[string]
        if ($null -ne $PolicyRefs) {
            foreach ($p in @($PolicyRefs)) {
                $s = ([string]$p).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $pol.Add($s) | Out-Null
            }
        }
        $ev = New-Object System.Collections.Generic.List[string]
        if ($null -ne $EvidenceRefs) {
            foreach ($e in @($EvidenceRefs)) {
                $s = ([string]$e).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $ev.Add($s) | Out-Null
            }
        }
        $valid = ([int]$errors.Count -eq 0)
        return [PSCustomObject][ordered]@{
            selected            = $sel
            reason              = $rs
            confidence          = $conf
            fallback            = $fb
            policy_refs         = $pol.ToArray()
            evidence_refs       = $ev.ToArray()
            escalation_consumed = [bool]$EscalationConsumed
            is_valid            = [bool]$valid
            validation_errors   = $errors.ToArray()
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            selected            = ''
            reason              = ''
            confidence          = 0.0
            fallback            = ''
            policy_refs         = @()
            evidence_refs       = @()
            escalation_consumed = $false
            is_valid            = $false
            validation_errors   = @('result-internal')
        }
    }
}

function Test-ModelRoutingEnvelope {
    <#
    .SYNOPSIS
        Closed record-only validation envelope (SPEC 4.3, PLAN 3).
    .DESCRIPTION
        Order (invariants BEFORE override): structural request/result
        validation -> HIGH/CRITICAL without PlannerApproved deny ->
        deny-list -> allowlist/matrix -> paid-without-authorization ->
        quota-exhausted -> confidence floor -> override short-circuit
        (consulted_router=false, still fully validated) -> accept.
        Never throws; never consults a router/model/network; never reads
        dispatch, config, registry or flags. PlannerApproved,
        PaidAuthorized, QuotaExhausted and DeniedModels are explicit
        caller-supplied facts for the shadow record.
    #>
    [CmdletBinding()]
    param(
        $Request = $null,
        $Proposed = $null,
        $PlannerApproved = $false,
        $PaidAuthorized = $false,
        $QuotaExhausted = $false,
        [object[]]$DeniedModels = @()
    )
    $ErrorActionPreference = 'Stop'
    try {
        $fbGuess = ''
        try {
            $g1 = Get-ModelRoutingField -Object $Request -Name 'fallback'
            $g2 = Get-ModelRoutingField -Object $Proposed -Name 'fallback'
            if (-not [string]::IsNullOrWhiteSpace([string]$g1)) { $fbGuess = ([string]$g1).Trim() }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$g2)) { $fbGuess = ([string]$g2).Trim() }
        }
        catch { }
        $base = [ordered]@{
            task_id          = ''
            role             = ''
            task_class       = ''
            risk             = ''
            selected         = $fbGuess
            fallback         = $fbGuess
            reason           = 'FALLBACK_DETERMINISTIC'
            confidence       = 0.0
            consulted_router = $false
            fallback_used    = $true
            denied           = $false
            validation_errors = @()
            policy_refs      = @()
            evidence_refs    = @('NO_EVIDENCE_YET')
            escalation_consumed = $false
        }
        $plannerOk = $false
        $paidOk = $false
        $quotaOut = $true
        try {
            $paGate = Test-ModelRoutingStrictBool -Value $PlannerApproved -Default $false
            $plannerOk = (([bool]$paGate.ok) -and ([bool]$paGate.value))
            $pzGate = Test-ModelRoutingStrictBool -Value $PaidAuthorized -Default $false
            $paidOk = (([bool]$pzGate.ok) -and ([bool]$pzGate.value))
            $qeGate = Test-ModelRoutingStrictBool -Value $QuotaExhausted -Default $true
            $quotaOut = [bool]$qeGate.value
        }
        catch { $plannerOk = $false; $paidOk = $false; $quotaOut = $true }
        $reqValid = $false
        $propValid = $false
        try {
            $reqFlag = Get-ModelRoutingField -Object $Request -Name 'is_valid'
            $reqValid = (($reqFlag -is [bool]) -and ([bool]$reqFlag))
        }
        catch { $reqValid = $false }
        try {
            $propFlag = Get-ModelRoutingField -Object $Proposed -Name 'is_valid'
            $propValid = (($propFlag -is [bool]) -and ([bool]$propFlag))
        }
        catch { $propValid = $false }
        if (-not $reqValid) {
            $errs = @('request-invalid')
            try {
                $re = Get-ModelRoutingField -Object $Request -Name 'validation_errors'
                if ($null -ne $re) { $errs = @($re) }
            }
            catch { }
            $base['validation_errors'] = $errs
            try {
                $base['task_id'] = ([string](Get-ModelRoutingField -Object $Request -Name 'task_id'))
            }
            catch { }
            try {
                $reqCands = @()
                try { $reqCands = @((Get-ModelRoutingField -Object $Request -Name 'candidates')) } catch { $reqCands = @() }
                $fbCheck = Test-ModelRoutingFallback -Fallback $fbGuess -Candidates $reqCands -DeniedModels $DeniedModels -PaidAuthorized $paidOk
                if (-not [bool]$fbCheck.ok) {
                    $base['selected'] = ''
                    $base['denied'] = $true
                    $base['validation_errors'] = @($base['validation_errors']) + @($fbCheck.errors)
                }
            }
            catch { }
            return [PSCustomObject]$base
        }
        if (-not $propValid) {
            $errs = @('proposal-invalid')
            try {
                $pe = Get-ModelRoutingField -Object $Proposed -Name 'validation_errors'
                if ($null -ne $pe) { $errs = @($pe) }
            }
            catch { }
            $base['validation_errors'] = $errs
            try {
                $base['task_id'] = ([string](Get-ModelRoutingField -Object $Request -Name 'task_id'))
                $base['role'] = ([string](Get-ModelRoutingField -Object $Request -Name 'role'))
                $base['task_class'] = ([string](Get-ModelRoutingField -Object $Request -Name 'task_class'))
                $base['risk'] = ([string](Get-ModelRoutingField -Object $Request -Name 'risk'))
                $base['fallback'] = ([string](Get-ModelRoutingField -Object $Request -Name 'fallback'))
                $base['selected'] = $base['fallback']
            }
            catch { }
            try {
                $reqCands = @()
                try { $reqCands = @((Get-ModelRoutingField -Object $Request -Name 'candidates')) } catch { $reqCands = @() }
                $fbCheck = Test-ModelRoutingFallback -Fallback ([string]$base['fallback']) -Candidates $reqCands -DeniedModels $DeniedModels -PaidAuthorized $paidOk
                if (-not [bool]$fbCheck.ok) {
                    $base['selected'] = ''
                    $base['denied'] = $true
                    $base['validation_errors'] = @($base['validation_errors']) + @($fbCheck.errors)
                }
            }
            catch { }
            return [PSCustomObject]$base
        }
        $taskId = ([string](Get-ModelRoutingField -Object $Request -Name 'task_id'))
        $role = ([string](Get-ModelRoutingField -Object $Request -Name 'role'))
        $tclass = ([string](Get-ModelRoutingField -Object $Request -Name 'task_class'))
        $risk = ([string](Get-ModelRoutingField -Object $Request -Name 'risk'))
        $fallback = ([string](Get-ModelRoutingField -Object $Request -Name 'fallback')).Trim()
        $override = ([string](Get-ModelRoutingField -Object $Request -Name 'user_model_override')).Trim()
        $hasOverride = (-not [string]::IsNullOrWhiteSpace($override))
        $sel = ([string](Get-ModelRoutingField -Object $Proposed -Name 'selected')).Trim()
        $conf = 0.0
        $confOk = $false
        try {
            $confGate = Test-ModelRoutingStrictConfidence -Value (Get-ModelRoutingField -Object $Proposed -Name 'confidence')
            $conf = [double]$confGate.value
            $confOk = [bool]$confGate.ok
        }
        catch { $conf = 0.0; $confOk = $false }
        $esc = $true
        try {
            $escGate = Test-ModelRoutingStrictBool -Value (Get-ModelRoutingField -Object $Proposed -Name 'escalation_consumed') -Default $true
            $esc = [bool]$escGate.value
        }
        catch { $esc = $true }
        $pol = @()
        $ev = @('NO_EVIDENCE_YET')
        try {
            $p0 = Get-ModelRoutingField -Object $Proposed -Name 'policy_refs'
            if ($null -ne $p0) { $pol = @($p0) }
            $e0 = Get-ModelRoutingField -Object $Proposed -Name 'evidence_refs'
            if (($null -ne $e0) -and (@($e0).Count -gt 0)) { $ev = @($e0) }
        }
        catch { }
        $cands = @()
        try { $cands = @((Get-ModelRoutingField -Object $Request -Name 'candidates')) } catch { $cands = @() }
        $effective = $sel
        if ($hasOverride) { $effective = $override }
        $roleNorm = ([string]$role).Trim().ToLowerInvariant()
        $tclassNorm = ([string]$tclass).Trim().ToLowerInvariant()
        $riskNorm = ([string]$risk).Trim().ToUpperInvariant()
        $reasonRaw = ([string](Get-ModelRoutingField -Object $Proposed -Name 'reason')).Trim()
        $reasonNorm = ''
        foreach ($r in @($script:ModelRoutingReasons)) {
            if ($reasonRaw -ceq $r) { $reasonNorm = [string]$r; break }
        }
        $fallbackOk = $true
        $fallbackErrs = New-Object System.Collections.Generic.List[string]
        try {
            $fbCheck = Test-ModelRoutingFallback -Fallback $fallback -Candidates $cands -DeniedModels $DeniedModels -PaidAuthorized $paidOk
            $fallbackOk = [bool]$fbCheck.ok
            foreach ($fe in @($fbCheck.errors)) { $fallbackErrs.Add([string]$fe) | Out-Null }
        }
        catch {
            $fallbackOk = $false
            $fallbackErrs.Add('fallback-internal') | Out-Null
        }
        $fieldErrs = New-Object System.Collections.Generic.List[string]
        if ($script:ModelRoutingRoles -cnotcontains $roleNorm) { $fieldErrs.Add('role-unknown') | Out-Null }
        if ($script:ModelRoutingTaskClasses -cnotcontains $tclassNorm) { $fieldErrs.Add('task_class-unknown') | Out-Null }
        if ($script:ModelRoutingRisks -cnotcontains $riskNorm) { $fieldErrs.Add('risk-unknown') | Out-Null }
        if ([string]::IsNullOrWhiteSpace($reasonNorm)) { $fieldErrs.Add('reason-unknown') | Out-Null }
        if (-not $confOk) { $fieldErrs.Add('confidence-invalid') | Out-Null }
        if ([int]$fieldErrs.Count -gt 0) {
            $ferr = [ordered]@{
                task_id          = $taskId
                role             = $roleNorm
                task_class       = $tclassNorm
                risk             = $riskNorm
                selected         = $fallback
                fallback         = $fallback
                reason           = 'FALLBACK_DETERMINISTIC'
                confidence       = 0.0
                consulted_router = $false
                fallback_used    = $true
                denied           = $false
                validation_errors = $fieldErrs.ToArray()
                policy_refs      = $pol
                evidence_refs    = $ev
                escalation_consumed = $esc
            }
            Set-ModelRoutingFallbackSelection -Out $ferr -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$ferr
        }
        $role = $roleNorm
        $tclass = $tclassNorm
        $risk = $riskNorm
        $out = [ordered]@{
            task_id          = $taskId
            role             = $role
            task_class       = $tclass
            risk             = $risk
            selected         = $fallback
            fallback         = $fallback
            reason           = 'FALLBACK_DETERMINISTIC'
            confidence       = $conf
            consulted_router = $false
            fallback_used    = $true
            denied           = $false
            validation_errors = @()
            policy_refs      = $pol
            evidence_refs    = $ev
            escalation_consumed = $esc
        }
        # Invariant 1: HIGH/CRITICAL requires explicit Planner approval (before override).
        if ((($risk -ceq 'HIGH') -or ($risk -ceq 'CRITICAL')) -and (-not $plannerOk)) {
            $out['reason'] = 'DENY_POLICY'
            $out['denied'] = $true
            $out['validation_errors'] = @('high-risk-without-planner')
            $out['confidence'] = 0.0
            Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$out
        }
        # Invariant 2: deny-list (before override).
        if ((-not [string]::IsNullOrWhiteSpace($effective)) -and (Test-ModelRoutingDeniedHit -Candidate $effective -DeniedModels $DeniedModels)) {
            $out['reason'] = 'DENY_POLICY'
            $out['denied'] = $true
            $out['validation_errors'] = @('deny-list-hit')
            $out['confidence'] = 0.0
            Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$out
        }
        # Invariant 3: allowlist/matrix (before override effect).
        if (-not [string]::IsNullOrWhiteSpace($effective)) {
            $inMatrix = $false
            foreach ($c in @($cands)) {
                if ([string]$effective -ceq [string]$c) { $inMatrix = $true; break }
            }
            if (-not $inMatrix) {
                if ($hasOverride) {
                    $out['reason'] = 'DENY_POLICY'
                    $out['denied'] = $true
                    $out['validation_errors'] = @('override-out-of-envelope')
                }
                else {
                    $out['reason'] = 'candidate_out_of_envelope'
                    $out['denied'] = $true
                    $out['validation_errors'] = @('candidate-out-of-envelope')
                }
                $out['confidence'] = 0.0
                $out['confidence'] = 0.0
                Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
                return [PSCustomObject]$out
            }
        }
        # Invariant 4: paid without explicit per-environment authorization.
        if ((-not [string]::IsNullOrWhiteSpace($effective)) -and (Test-ModelRoutingPaidHit -Text $effective) -and (-not $paidOk)) {
            $out['reason'] = 'DENY_POLICY'
            $out['denied'] = $true
            $out['validation_errors'] = @('paid-without-authorization')
            $out['confidence'] = 0.0
            Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$out
        }
        # Invariant 5: quota exhausted (before override effect).
        if ($quotaOut -and ($hasOverride -or $esc -or (Test-ModelRoutingPaidHit -Text $effective))) {
            $out['reason'] = 'DENY_POLICY'
            $out['denied'] = $true
            $out['validation_errors'] = @('quota-exhausted')
            $out['confidence'] = 0.0
            Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$out
        }
        # Confidence floor applies to override too (validation, not consultation).
        if ($conf -lt [double]$script:ModelRoutingMinConfidence) {
            $out['reason'] = 'FALLBACK_DETERMINISTIC'
            $out['validation_errors'] = @('low-confidence-fallback')
            $out['confidence'] = 0.0
            Set-ModelRoutingFallbackSelection -Out $out -Fallback $fallback -FallbackOk $fallbackOk -FallbackErrs $fallbackErrs.ToArray()
            return [PSCustomObject]$out
        }
        # Override short-circuit: no consultation, still fully validated above.
        # A broken fallback still blocks: no baseline is permitted, so the
        # selection is emptied with an explicit block (REV-F1-LIB-R3).
        if ($hasOverride) {
            if (-not [bool]$fallbackOk) {
                $out['selected'] = ''
                $out['reason'] = 'FALLBACK_DETERMINISTIC'
                $out['consulted_router'] = $false
                $out['fallback_used'] = $true
                $out['denied'] = $true
                $out['validation_errors'] = @($fallbackErrs.ToArray())
                $out['confidence'] = 0.0
                return [PSCustomObject]$out
            }
            $out['selected'] = $override
            $out['reason'] = 'OVERRIDE_USER'
            $out['consulted_router'] = $false
            $out['fallback_used'] = $false
            $out['denied'] = $false
            return [PSCustomObject]$out
        }
        # Valid proposal: record the advised pick (shadow; dispatch never reads it).
        if ([string]::IsNullOrWhiteSpace($sel)) {
            if ([bool]$fallbackOk) {
                $out['selected'] = $fallback
                $out['reason'] = $reasonNorm
                $out['consulted_router'] = $true
                $out['fallback_used'] = $true
                $out['denied'] = $false
            }
            else {
                $out['selected'] = ''
                $out['reason'] = 'FALLBACK_DETERMINISTIC'
                $out['consulted_router'] = $false
                $out['fallback_used'] = $true
                $out['denied'] = $true
                $out['validation_errors'] = @($fallbackErrs.ToArray())
                $out['confidence'] = 0.0
            }
            return [PSCustomObject]$out
        }
        # A broken fallback still blocks even with a valid pick: no baseline
        # is permitted, so the selection is emptied (REV-F1-LIB-R3).
        if (-not [bool]$fallbackOk) {
            $out['selected'] = ''
            $out['reason'] = 'FALLBACK_DETERMINISTIC'
            $out['consulted_router'] = $false
            $out['fallback_used'] = $true
            $out['denied'] = $true
            $out['validation_errors'] = @($fallbackErrs.ToArray())
            $out['confidence'] = 0.0
            return [PSCustomObject]$out
        }
        $out['selected'] = $sel
        $out['reason'] = $reasonNorm
        $out['consulted_router'] = $true
        $out['fallback_used'] = $false
        $out['denied'] = $false
        return [PSCustomObject]$out
    }
    catch {
        return [PSCustomObject][ordered]@{
            task_id          = ''
            role             = ''
            task_class       = ''
            risk             = ''
            selected         = ''
            fallback         = ''
            reason           = 'FALLBACK_DETERMINISTIC'
            confidence       = 0.0
            consulted_router = $false
            fallback_used    = $true
            denied           = $true
            validation_errors = @('envelope-internal')
            policy_refs      = @()
            evidence_refs    = @('NO_EVIDENCE_YET')
            escalation_consumed = $false
        }
    }
}
