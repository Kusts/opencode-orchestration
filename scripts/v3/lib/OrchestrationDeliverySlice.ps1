<#!
.SYNOPSIS
    Incremental Delivery & Evidence-Driven Development library.
.DESCRIPTION
    Implements the vertical slice contract, observable acceptance criteria,
    admissibility checks, assisted subdivision, and maturity projections
    without creating a competing state machine.
    Integrates directly with TaskKernel, GoalKernel, EvidenceStore, and Verifier.
    PS 5.1 and PS 7 compatible, ASCII-only, fail-closed.
#>
[CmdletBinding()]
param()

function Safe-DSString([object]$Value, [int]$MaxLength = 500) {
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s -replace '[\x00-\x1f]', ' '
    $s = $s.Trim()
    if ($s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength)
    }
    return $s
}

function Safe-DSStringArray($Value, [int]$MaxItems = 50, [int]$MaxItemLength = 200) {
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Value) { return @() }
    $items = @($Value)
    $count = 0
    foreach ($item in $items) {
        if ($count -ge $MaxItems) { break }
        $s = Safe-DSString $item $MaxItemLength
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            [void]$out.Add($s)
            $count++
        }
    }
    return [string[]]$out.ToArray()
}

function Get-DSValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $val = $Default
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $val = $Object[$Name]
        }
    } elseif ($null -ne $Object.PSObject.Properties[$Name]) {
        $val = $Object.PSObject.Properties[$Name].Value
    }
    if ($null -eq $val) { return $Default }
    if (($val -is [System.Collections.IEnumerable]) -and -not ($val -is [string]) -and ($val.Count -eq 0)) {
        return ,@()
    }
    return $val
}

function New-OrchestrationAcceptanceCriterion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CriterionId,
        [AllowEmptyString()][string]$Given = '',
        [AllowEmptyString()][string]$When = '',
        [AllowEmptyString()][string]$Then = '',
        [AllowEmptyString()][string]$Oracle = '',
        [string]$VerificationType = 'deterministic_check',
        [bool]$Required = $true,
        [string]$EvidenceRef = '',
        [string]$Status = 'pending',
        [string]$TargetArtifact = '',
        [string]$Notes = ''
    )

    $id = Safe-DSString $CriterionId 64
    $g = Safe-DSString $Given 300
    $w = Safe-DSString $When 300
    $t = Safe-DSString $Then 300
    $o = Safe-DSString $Oracle 300
    $vt = Safe-DSString $VerificationType 64
    if ($vt -notin @('unit', 'contract', 'integration', 'e2e', 'model_eval', 'deterministic_check', 'security_review', 'manual_approval')) {
        $vt = 'deterministic_check'
    }
    $st = Safe-DSString $Status 32
    if ($st -notin @('pending', 'candidate_pass', 'verified_pass', 'failed', 'blocked', 'stale')) {
        $st = 'pending'
    }

    return [ordered]@{
        criterion_id = $id
        given = $g
        when = $w
        then = $t
        oracle = $o
        verification_type = $vt
        required = [bool]$Required
        evidence_ref = (Safe-DSString $EvidenceRef 128)
        status = $st
        target_artifact = (Safe-DSString $TargetArtifact 200)
        notes = (Safe-DSString $Notes 200)
    }
}

function New-OrchestrationDeliverySlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SliceId,
        [string]$ObjectiveId = '',
        [string]$GoalId = '',
        [string[]]$TaskIds = @(),
        [AllowEmptyString()][string]$Outcome = '',
        [AllowEmptyCollection()][string[]]$Scope = @(),
        [string[]]$NonGoals = @(),
        [string[]]$Dependencies = @(),
        [object[]]$AcceptanceCriteria = @(),
        [string]$RiskLevel = 'medium',
        [string]$ValidationProfile = 'STANDARD',
        [string[]]$ExpectedEvidence = @(),
        [string]$BaselineRevision = '',
        [string]$TargetEnvironment = 'local',
        [hashtable]$Budget = @{},
        [object[]]$EvidenceRefs = @(),
        [string]$MaturityState = 'PLANNED',
        [int]$AttemptCount = 0,
        [string[]]$Hypotheses = @()
    )

    $sid = Safe-DSString $SliceId 64
    $oid = Safe-DSString $ObjectiveId 64
    $gid = Safe-DSString $GoalId 64
    $tids = Safe-DSStringArray $TaskIds 50 64
    $outc = Safe-DSString $Outcome 500
    $sc = Safe-DSStringArray $Scope 50 200
    $ng = Safe-DSStringArray $NonGoals 50 200
    $deps = Safe-DSStringArray $Dependencies 50 64
    $risk = (Safe-DSString $RiskLevel 16).ToLowerInvariant()
    if ($risk -notin @('low', 'medium', 'high', 'critical')) {
        $risk = 'medium'
    }
    $vp = (Safe-DSString $ValidationProfile 16).ToUpperInvariant()
    if ($vp -notin @('DIRECT', 'STANDARD', 'HIGH_RISK')) {
        $vp = switch ($risk) {
            'low' { 'DIRECT' }
            'high' { 'HIGH_RISK' }
            'critical' { 'HIGH_RISK' }
            default { 'STANDARD' }
        }
    }

    $parsedCriteria = New-Object System.Collections.ArrayList
    if ($null -ne $AcceptanceCriteria) {
        foreach ($c in @($AcceptanceCriteria)) {
            if ($null -eq $c) { continue }
            $cid = Get-DSValue $c 'criterion_id' ''
            $g = Get-DSValue $c 'given' ''
            $w = Get-DSValue $c 'when' ''
            $t = Get-DSValue $c 'then' ''
            $o = Get-DSValue $c 'oracle' ''
            $vt = Get-DSValue $c 'verification_type' 'deterministic_check'
            $req = [bool](Get-DSValue $c 'required' $true)
            $eref = Get-DSValue $c 'evidence_ref' ''
            $st = Get-DSValue $c 'status' 'pending'
            $art = Get-DSValue $c 'target_artifact' ''
            $nt = Get-DSValue $c 'notes' ''
            if (-not [string]::IsNullOrWhiteSpace($cid)) {
                $critObj = New-OrchestrationAcceptanceCriterion -CriterionId $cid -Given $g -When $w -Then $t -Oracle $o -VerificationType $vt -Required $req -EvidenceRef $eref -Status $st -TargetArtifact $art -Notes $nt
                [void]$parsedCriteria.Add([pscustomobject]$critObj)
            }
        }
    }

    $mst = (Safe-DSString $MaturityState 24).ToUpperInvariant()
    if ($mst -notin @('PLANNED', 'IMPLEMENTED', 'INTEGRATED', 'VALIDATED', 'DONE', 'BLOCKED', 'FAILED')) {
        $mst = 'PLANNED'
    }

    $bSoft = 0
    $bHard = 0
    $bSpent = 0
    if ($null -ne $Budget) {
        try { $bSoft = [int](Get-DSValue $Budget 'soft_cap' 0) } catch { $bSoft = 0 }
        try { $bHard = [int](Get-DSValue $Budget 'hard_cap' 0) } catch { $bHard = 0 }
        try { $bSpent = [int](Get-DSValue $Budget 'spent' 0) } catch { $bSpent = 0 }
    }

    return [ordered]@{
        schema_version = 1
        slice_id = $sid
        objective_id = $oid
        goal_id = $gid
        task_ids = [string[]]$tids
        outcome = $outc
        scope = [string[]]$sc
        non_goals = [string[]]$ng
        dependencies = [string[]]$deps
        acceptance_criteria = @($parsedCriteria.ToArray())
        risk_level = $risk
        validation_profile = $vp
        expected_evidence = [string[]](Safe-DSStringArray $ExpectedEvidence 50 120)
        baseline_revision = (Safe-DSString $BaselineRevision 64)
        target_environment = (Safe-DSString $TargetEnvironment 64)
        budget = [ordered]@{
            soft_cap = $bSoft
            hard_cap = $bHard
            spent = $bSpent
        }
        evidence_refs = [string[]](Safe-DSStringArray $EvidenceRefs 50 128)
        maturity_state = $mst
        attempt_count = [int]$AttemptCount
        hypotheses = [string[]](Safe-DSStringArray $Hypotheses 20 200)
    }
}

function Test-OrchestrationDeliverySlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice
    )

    $errors = New-Object System.Collections.ArrayList

    if ($null -eq $Slice) {
        [void]$errors.Add('Slice object is null.')
        return [pscustomobject]@{
            valid = $false
            errors = [string[]]$errors.ToArray()
        }
    }

    $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' '')
    if ([string]::IsNullOrWhiteSpace($sid)) {
        [void]$errors.Add('Missing or empty slice_id.')
    }

    $outcome = Safe-DSString (Get-DSValue $Slice 'outcome' '')
    if ([string]::IsNullOrWhiteSpace($outcome)) {
        [void]$errors.Add('Missing or empty outcome. A vertical slice must specify an observable user outcome.')
    }
    elseif ($outcome.Length -lt 10) {
        [void]$errors.Add('Outcome is too brief to represent a verifiable user outcome.')
    }

    $scope = @(Get-DSValue $Slice 'scope' @())
    if ($scope.Count -eq 0) {
        [void]$errors.Add('Missing scope. A vertical slice must specify what will be delivered.')
    }

    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())
    if ($criteria.Count -eq 0) {
        [void]$errors.Add('Missing acceptance criteria. A vertical slice must define at least one observable criterion.')
    }
    else {
        $seenIds = @{}
        foreach ($c in $criteria) {
            $cid = Safe-DSString (Get-DSValue $c 'criterion_id' '')
            if ([string]::IsNullOrWhiteSpace($cid)) {
                [void]$errors.Add('Acceptance criterion missing criterion_id.')
                continue
            }
            if ($seenIds.ContainsKey($cid.ToLowerInvariant())) {
                [void]$errors.Add("Duplicate criterion_id: $cid")
            }
            $seenIds[$cid.ToLowerInvariant()] = $true

            $oracle = Safe-DSString (Get-DSValue $c 'oracle' '')
            if ([string]::IsNullOrWhiteSpace($oracle)) {
                [void]$errors.Add("Criterion $cid is missing an authoritative oracle/verification source.")
            }

            $thenPart = Safe-DSString (Get-DSValue $c 'then' '')
            if ([string]::IsNullOrWhiteSpace($thenPart)) {
                [void]$errors.Add("Criterion $cid is missing expected observable outcome (then).")
            }
        }
    }

    $deps = @(Get-DSValue $Slice 'dependencies' @())
    if ($deps.Contains($sid)) {
        [void]$errors.Add("Circular dependency: slice $sid depends on itself.")
    }

    $risk = Safe-DSString (Get-DSValue $Slice 'risk_level' 'medium')
    if ($risk -notin @('low', 'medium', 'high', 'critical')) {
        [void]$errors.Add("Invalid risk_level: $risk")
    }

    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    if ($vp -notin @('DIRECT', 'STANDARD', 'HIGH_RISK')) {
        [void]$errors.Add("Invalid validation_profile: $vp")
    }

    $isValid = ($errors.Count -eq 0)
    return [pscustomobject]@{
        valid = $isValid
        errors = [string[]]$errors.ToArray()
    }
}

function Test-OrchestrationDeliverySliceAdmissibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [int]$MaxScopeItems = 10,
        [int]$MaxCriteriaItems = 7
    )

    $validation = Test-OrchestrationDeliverySlice -Slice $Slice
    if (-not $validation.valid) {
        return [pscustomobject]@{
            admissible = $false
            requires_subdivision = $false
            reasons = $validation.errors
        }
    }

    $reasons = New-Object System.Collections.ArrayList
    $requiresSubdivision = $false

    # 1. Unico resultado principal
    $outcome = Safe-DSString (Get-DSValue $Slice 'outcome' '')
    if ($outcome -match '\b(e\s+tambem|alem\s+disso|outro\s+modulo|e\s+um\s+novo\s+painel)\b') {
        [void]$reasons.Add('Outcome appears to combine multiple unrelated objectives; consider separate slices.')
        $requiresSubdivision = $true
    }

    # 2. Escopo delimitado
    $scope = @(Get-DSValue $Slice 'scope' @())
    if ($scope.Count -gt $MaxScopeItems) {
        [void]$reasons.Add("Scope count ($($scope.Count)) exceeds single slice limit ($MaxScopeItems); subdivide slice.")
        $requiresSubdivision = $true
    }

    # 3. Criterios observaveis com oraculo
    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())
    if ($criteria.Count -gt $MaxCriteriaItems) {
        [void]$reasons.Add("Criteria count ($($criteria.Count)) exceeds single slice limit ($MaxCriteriaItems); subdivide slice.")
        $requiresSubdivision = $true
    }

    # 4. Nao-objetivos definidos para mudancas nao triviais
    $nonGoals = @(Get-DSValue $Slice 'non_goals' @())
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    if ($vp -in @('STANDARD', 'HIGH_RISK') -and $nonGoals.Count -eq 0) {
        [void]$reasons.Add('Non-trivial slices must explicitly state non_goals to prevent scope creep.')
    }

    # 5. Dependencias conhecidas
    $rawDeps = Get-DSValue $Slice 'dependencies' $null
    if ($null -ne $rawDeps) {
        $deps = @($rawDeps)
        foreach ($d in $deps) {
            if ($null -ne $d -and [string]::IsNullOrWhiteSpace([string]$d)) {
                [void]$reasons.Add('Slice contains blank or invalid dependency reference.')
            }
        }
    }

    $isAdmissible = ($reasons.Count -eq 0)
    return [pscustomobject]@{
        admissible = $isAdmissible
        requires_subdivision = $requiresSubdivision
        reasons = [string[]]$reasons.ToArray()
    }
}

function Split-OrchestrationDeliverySlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [int]$MaxItemsPerSlice = 4
    )

    $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' 'slice')
    $oid = Safe-DSString (Get-DSValue $Slice 'objective_id' '')
    $gid = Safe-DSString (Get-DSValue $Slice 'goal_id' '')
    $outcome = Safe-DSString (Get-DSValue $Slice 'outcome' '')
    $scope = @(Get-DSValue $Slice 'scope' @())
    $nonGoals = @(Get-DSValue $Slice 'non_goals' @())
    $risk = Safe-DSString (Get-DSValue $Slice 'risk_level' 'medium')
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())

    if ($criteria.Count -le $MaxItemsPerSlice -and $scope.Count -le $MaxItemsPerSlice) {
        return @($Slice)
    }

    $subSlices = New-Object System.Collections.ArrayList
    $chunkIndex = 1
    $critIndex = 0
    $prevSliceId = ''

    while ($critIndex -lt $criteria.Count) {
        $chunkCriteria = @($criteria | Select-Object -Skip $critIndex -First $MaxItemsPerSlice)
        $critIndex += $MaxItemsPerSlice

        $chunkScope = @($scope | Select-Object -Skip (($chunkIndex - 1) * $MaxItemsPerSlice) -First $MaxItemsPerSlice)
        if ($chunkScope.Count -eq 0) {
            $chunkScope = @("Deliver verifiable subset $chunkIndex for: $outcome")
        }

        $partId = "$sid-part-$chunkIndex"
        $partOutcome = "$outcome (Part $chunkIndex)"
        $partDeps = if ([string]::IsNullOrWhiteSpace($prevSliceId)) {
            @(Get-DSValue $Slice 'dependencies' @())
        } else {
            @($prevSliceId)
        }

        $sub = New-OrchestrationDeliverySlice `
            -SliceId $partId `
            -ObjectiveId $oid `
            -GoalId $gid `
            -Outcome $partOutcome `
            -Scope $chunkScope `
            -NonGoals $nonGoals `
            -Dependencies $partDeps `
            -AcceptanceCriteria $chunkCriteria `
            -RiskLevel $risk `
            -ValidationProfile $vp `
            -BaselineRevision (Safe-DSString (Get-DSValue $Slice 'baseline_revision' '')) `
            -TargetEnvironment (Safe-DSString (Get-DSValue $Slice 'target_environment' 'local'))

        [void]$subSlices.Add([pscustomobject]$sub)
        $prevSliceId = $partId
        $chunkIndex++
    }

    return @($subSlices.ToArray())
}

function Test-OrchestrationSliceMaturity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [hashtable]$RuntimeContext = @{}
    )

    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    $isDirect = ($vp -eq 'DIRECT')

    # Status de criterios
    $totalCriteria = $criteria.Count
    $requiredCriteria = 0
    $verifiedCount = 0
    $candidateCount = 0
    $blockedCount = 0
    $failedCount = 0
    $hasBackendOnlyWithoutUserJourney = [bool](Get-DSValue $RuntimeContext 'backend_only_without_journey' $false)
    $hasUnconnectedTool = [bool](Get-DSValue $RuntimeContext 'tool_unconnected' $false)
    $isE2eMissingWhenRequired = [bool](Get-DSValue $RuntimeContext 'e2e_missing_when_required' $false)
    $isModelMissingInRequiredEval = [bool](Get-DSValue $RuntimeContext 'model_missing_in_eval' $false)
    $isEvidenceStale = [bool](Get-DSValue $RuntimeContext 'evidence_stale' $false)
    $isKernelDoneAuthorized = [bool](Get-DSValue $RuntimeContext 'kernel_done_authorized' $false)

    foreach ($c in $criteria) {
        $req = [bool](Get-DSValue $c 'required' $true)
        if ($req) { $requiredCriteria++ }
        $st = Safe-DSString (Get-DSValue $c 'status' 'pending')
        $eref = Safe-DSString (Get-DSValue $c 'evidence_ref' '')
        $vt = Safe-DSString (Get-DSValue $c 'verification_type' 'deterministic_check')

        if ($st -eq 'verified_pass' -and -not [string]::IsNullOrWhiteSpace($eref)) {
            $verifiedCount++
        }
        elseif ($st -eq 'candidate_pass') {
            $candidateCount++
        }
        elseif ($st -eq 'blocked') {
            $blockedCount++
        }
        elseif ($st -eq 'failed') {
            $failedCount++
        }
    }

    # Avaliacao normativa dos estados:
    # 1. BLOCKED se houver bloqueio real ou falta de provider essencial
    if ($blockedCount -gt 0 -or $isModelMissingInRequiredEval) {
        return [pscustomobject]@{
            maturity_state = 'BLOCKED'
            can_advance_to_done = $false
            reason = if ($isModelMissingInRequiredEval) { 'Required model eval blocked due to missing provider/quota (AC-05 fail-closed).' } else { 'One or more required acceptance criteria are blocked by dependencies.' }
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # 2. FAILED se houver falha confirmada
    if ($failedCount -gt 0) {
        return [pscustomobject]@{
            maturity_state = 'FAILED'
            can_advance_to_done = $false
            reason = 'One or more acceptance criteria failed verification.'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # 3. Regra AC-06: Evidencia desatualizada invalida verificacao
    if ($isEvidenceStale) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Evidence is stale in relation to base revision; re-verification required (AC-06).'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # 4. Regras AC-02, AC-03, AC-04:
    # Backend isolado sem jornada -> nao e INTEGRATED
    if ($hasBackendOnlyWithoutUserJourney) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Backend changes alone without observable end-to-end user journey cannot be accepted as integrated (AC-02).'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # Tool existente sem rota executavel -> nao e INTEGRATED
    if ($hasUnconnectedTool) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Tool registered in catalog without executable wiring does not satisfy integration criteria (AC-03).'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # Unit test green sem E2E quando este e requerido -> nao e VALIDATED
    if ($isE2eMissingWhenRequired -and -not $isDirect) {
        return [pscustomobject]@{
            maturity_state = 'INTEGRATED'
            can_advance_to_done = $false
            reason = 'Unit tests passing alone cannot substitute required end-to-end verification (AC-04).'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    # 5. VALIDATED se todos os criterios obrigatorios estao verified_pass por oraculo independente
    $allRequiredVerified = ($requiredCriteria -gt 0 -and $verifiedCount -ge $requiredCriteria)

    if ($allRequiredVerified) {
        if ($isKernelDoneAuthorized) {
            return [pscustomobject]@{
                maturity_state = 'DONE'
                can_advance_to_done = $true
                reason = 'All required acceptance criteria proven with independent oracle evidence and authorized by Kernel (AC-12).'
                coverage = [pscustomobject]@{
                    total = $totalCriteria
                    required = $requiredCriteria
                    verified = $verifiedCount
                    candidate = $candidateCount
                    blocked = $blockedCount
                    failed = $failedCount
                }
            }
        } else {
            return [pscustomobject]@{
                maturity_state = 'VALIDATED'
                can_advance_to_done = $true
                reason = 'All required acceptance criteria verified by independent oracles; ready for kernel completion.'
                coverage = [pscustomobject]@{
                    total = $totalCriteria
                    required = $requiredCriteria
                    verified = $verifiedCount
                    candidate = $candidateCount
                    blocked = $blockedCount
                    failed = $failedCount
                }
            }
        }
    }

    # 6. INTEGRATED se dependencias conectadas mas faltam verificacoes finais
    if ($candidateCount -gt 0 -or $verifiedCount -gt 0) {
        return [pscustomobject]@{
            maturity_state = 'INTEGRATED'
            can_advance_to_done = $false
            reason = 'Components and interfaces connected; independent verification pending.'
            coverage = [pscustomobject]@{
                total = $totalCriteria
                required = $requiredCriteria
                verified = $verifiedCount
                candidate = $candidateCount
                blocked = $blockedCount
                failed = $failedCount
            }
        }
    }

    return [pscustomobject]@{
        maturity_state = 'IMPLEMENTED'
        can_advance_to_done = $false
        reason = 'Local code written; integration and verification pending.'
        coverage = [pscustomobject]@{
            total = $totalCriteria
            required = $requiredCriteria
            verified = $verifiedCount
            candidate = $candidateCount
            blocked = $blockedCount
            failed = $failedCount
        }
    }
}

function Test-OrchestrationSliceDoneAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [hashtable]$RuntimeContext = @{}
    )

    $maturity = Test-OrchestrationSliceMaturity -Slice $Slice -RuntimeContext $RuntimeContext
    if ($maturity.maturity_state -in @('VALIDATED', 'DONE') -and $maturity.can_advance_to_done) {
        return [pscustomobject]@{
            allowed = $true
            reason = 'All mandatory criteria satisfied with verified evidence.'
            missing_criteria = @()
            maturity = $maturity.maturity_state
        }
    }

    $missing = New-Object System.Collections.ArrayList
    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())
    foreach ($c in $criteria) {
        $req = [bool](Get-DSValue $c 'required' $true)
        $st = Safe-DSString (Get-DSValue $c 'status' 'pending')
        $cid = Safe-DSString (Get-DSValue $c 'criterion_id' '')
        if ($req -and $st -ne 'verified_pass') {
            [void]$missing.Add("$cid ($st)")
        }
    }

    return [pscustomobject]@{
        allowed = $false
        reason = $maturity.reason
        missing_criteria = [string[]]$missing.ToArray()
        maturity = $maturity.maturity_state
    }
}

function Test-OrchestrationConvergenceProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [int]$MaxConsecutiveStalls = 2,
        [string]$NewHypothesis = '',
        [string]$DiscriminantTest = ''
    )

    $attempts = [int](Get-DSValue $Slice 'attempt_count' 0)
    $hypotheses = @(Get-DSValue $Slice 'hypotheses' @())

    if ($attempts -lt $MaxConsecutiveStalls) {
        return [pscustomobject]@{
            can_retry = $true
            action = 'NORMAL_RETRY'
            reason = "Attempt $attempts within normal corrective threshold ($MaxConsecutiveStalls)."
            escalate_advisor = $false
        }
    }

    # Apos 2 tentativas sem progresso:
    # A 3a tentativa EXIGE nova hipotese e teste discriminante
    $hasNewHypothesis = (-not [string]::IsNullOrWhiteSpace($NewHypothesis) -and -not $hypotheses.Contains($NewHypothesis))
    $hasDiscriminantTest = (-not [string]::IsNullOrWhiteSpace($DiscriminantTest))

    if ($hasNewHypothesis -and $hasDiscriminantTest) {
        return [pscustomobject]@{
            can_retry = $true
            action = 'DISCRIMINANT_RETRY'
            reason = 'New distinct hypothesis and discriminant test provided. Advancing with structured experiment.'
            escalate_advisor = $false
        }
    }

    return [pscustomobject]@{
        can_retry = $false
        action = 'ESCALATE_DIAGNOSTIC'
        reason = "Two consecutive attempts without demonstrated progress. Must perform root-cause diagnostic or consult Advisor/Debugger before repeating (AC-07)."
        escalate_advisor = $true
    }
}

function Sync-OrchestrationDeliverySliceToGoal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Goal,
        [Parameter(Mandatory = $true)]$Slice
    )

    if ($null -eq $Goal -or $null -eq $Slice) { return $Goal }
    $maturity = Test-OrchestrationSliceMaturity -Slice $Slice
    $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' '')
    $outc = Safe-DSString (Get-DSValue $Slice 'outcome' '')

    if ($Goal -is [System.Collections.IDictionary]) {
        $Goal['active_slice_id'] = $sid
        $Goal['slice_outcome'] = $outc
        $Goal['slice_maturity'] = $maturity.maturity_state
        $Goal['slice_coverage'] = $maturity.coverage
    } else {
        $Goal | Add-Member -NotePropertyName 'active_slice_id' -NotePropertyValue $sid -Force
        $Goal | Add-Member -NotePropertyName 'slice_outcome' -NotePropertyValue $outc -Force
        $Goal | Add-Member -NotePropertyName 'slice_maturity' -NotePropertyValue $maturity.maturity_state -Force
        $Goal | Add-Member -NotePropertyName 'slice_coverage' -NotePropertyValue $maturity.coverage -Force
    }

    return $Goal
}

function Sync-OrchestrationDeliverySliceToTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)]$Slice
    )

    if ($null -eq $Task -or $null -eq $Slice) { return $Task }
    $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' '')
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')

    if ($Task -is [System.Collections.IDictionary]) {
        $Task['delivery_slice_id'] = $sid
        $Task['validation_profile'] = $vp
    } else {
        $Task | Add-Member -NotePropertyName 'delivery_slice_id' -NotePropertyValue $sid -Force
        $Task | Add-Member -NotePropertyName 'validation_profile' -NotePropertyValue $vp -Force
    }

    return $Task
}

function Get-OrchestrationSliceTelemetrySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Slices
    )

    $totalSlices = 0
    $maturityBreakdown = [ordered]@{
        PLANNED = 0
        IMPLEMENTED = 0
        INTEGRATED = 0
        VALIDATED = 0
        DONE = 0
        BLOCKED = 0
        FAILED = 0
    }
    $totalAttempts = 0
    $firstPassSuccess = 0
    $doneCount = 0
    $totalCriteria = 0
    $verifiedCriteria = 0
    $falseDoneCount = 0

    foreach ($s in @($Slices)) {
        if ($null -eq $s) { continue }
        $totalSlices++
        $mst = Safe-DSString (Get-DSValue $s 'maturity_state' 'PLANNED')
        if ($maturityBreakdown.Contains($mst)) {
            $maturityBreakdown[$mst]++
        }

        $attempts = [int](Get-DSValue $s 'attempt_count' 0)
        $totalAttempts += $attempts

        if ($mst -eq 'DONE') {
            $doneCount++
            if ($attempts -eq 0) {
                $firstPassSuccess++
            }
        }

        $criteria = @(Get-DSValue $s 'acceptance_criteria' @())
        foreach ($c in $criteria) {
            $req = [bool](Get-DSValue $c 'required' $true)
            if ($req) {
                $totalCriteria++
                $st = Safe-DSString (Get-DSValue $c 'status' 'pending')
                if ($st -eq 'verified_pass') {
                    $verifiedCriteria++
                }
            }
        }
    }

    $firstPassRate = if ($doneCount -gt 0) { [math]::Round(($firstPassSuccess / $doneCount), 4) } else { 0.0 }
    $coverageRate = if ($totalCriteria -gt 0) { [math]::Round(($verifiedCriteria / $totalCriteria), 4) } else { 0.0 }

    return [pscustomobject][ordered]@{
        schema_version = 1
        slices_total = [int]$totalSlices
        slices_by_maturity = [pscustomobject]$maturityBreakdown
        first_pass_acceptance_rate = [double]$firstPassRate
        total_rework_attempts = [int]$totalAttempts
        evidence_coverage_rate = [double]$coverageRate
        false_done_count = [int]$falseDoneCount
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
}


