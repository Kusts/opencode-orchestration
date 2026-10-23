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
    if (($val -is [System.Collections.IEnumerable]) -and -not ($val -is [string]) -and -not ($val -is [System.Collections.IDictionary]) -and ($val.Count -eq 0)) {
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
        [Parameter(Mandatory = $true)][AllowNull()]$Slice
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

function Test-OrchestrationDeliverySliceDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Slices
    )

    $sliceMap = @{}
    foreach ($s in @($Slices)) {
        if ($null -eq $s) { continue }
        $sid = Safe-DSString (Get-DSValue $s 'slice_id' '')
        if (-not [string]::IsNullOrWhiteSpace($sid)) {
            $sliceMap[$sid] = @(Get-DSValue $s 'dependencies' @())
        }
    }

    $visited = @{}
    $recStack = @{}
    $cycles = New-Object System.Collections.ArrayList
    $hasCycle = $false

    foreach ($node in $sliceMap.Keys) {
        if (-not $visited.ContainsKey($node)) {
            $stack = New-Object System.Collections.ArrayList
            $dfs = {
                param($curr)
                $visited[$curr] = $true
                $recStack[$curr] = $true
                [void]$stack.Add($curr)
                $deps = @($sliceMap[$curr])
                foreach ($neighbor in $deps) {
                    if ([string]::IsNullOrWhiteSpace([string]$neighbor)) { continue }
                    if (-not $visited.ContainsKey($neighbor) -and $sliceMap.ContainsKey($neighbor)) {
                        & $dfs $neighbor
                    } elseif ($recStack.ContainsKey($neighbor) -and $recStack[$neighbor]) {
                        $script:hasCycle = $true
                        $cyclePath = ($stack.ToArray() -join ' -> ') + " -> $neighbor"
                        [void]$cycles.Add($cyclePath)
                    }
                }
                $recStack[$curr] = $false
                if ($stack.Count -gt 0) { [void]$stack.RemoveAt($stack.Count - 1) }
            }
            & $dfs $node
        }
    }

    return [pscustomobject]@{
        valid = ($cycles.Count -eq 0)
        cycles = [string[]]$cycles.ToArray()
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
        [Parameter(Mandatory = $true)][AllowNull()]$Slice,
        [int]$MaxItemsPerSlice = 4
    )

    if ($null -eq $Slice) { return @() }

    $maxItems = if ($MaxItemsPerSlice -lt 1) { 1 } else { $MaxItemsPerSlice }

    $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' 'slice')
    $oid = Safe-DSString (Get-DSValue $Slice 'objective_id' '')
    $gid = Safe-DSString (Get-DSValue $Slice 'goal_id' '')
    $outcome = Safe-DSString (Get-DSValue $Slice 'outcome' '')
    $scope = @(Get-DSValue $Slice 'scope' @())
    $nonGoals = @(Get-DSValue $Slice 'non_goals' @())
    $risk = Safe-DSString (Get-DSValue $Slice 'risk_level' 'medium')
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())

    if ($criteria.Count -le $maxItems -and $scope.Count -le $maxItems) {
        return @($Slice)
    }

    $numPartsCriteria = if ($criteria.Count -gt 0) { [int][math]::Ceiling($criteria.Count / $maxItems) } else { 0 }
    $numPartsScope = if ($scope.Count -gt 0) { [int][math]::Ceiling($scope.Count / $maxItems) } else { 0 }
    $totalParts = [math]::Max($numPartsCriteria, $numPartsScope)
    if ($totalParts -lt 1) { $totalParts = 1 }

    $subSlices = New-Object System.Collections.ArrayList
    $prevSliceId = ''

    for ($chunkIndex = 1; $chunkIndex -le $totalParts; $chunkIndex++) {
        $critStart = ($chunkIndex - 1) * $maxItems
        $chunkCriteria = @()
        if ($critStart -lt $criteria.Count) {
            $chunkCriteria = @($criteria | Select-Object -Skip $critStart -First $maxItems)
        } else {
            # Se ha mais escopos que criterios, garante que a subfatia tenha criterio observavel com oraculo
            $chunkCriteria = @(New-OrchestrationAcceptanceCriterion `
                -CriterionId "$sid-part-$chunkIndex-crit" `
                -Given "Verifiable functional subset $chunkIndex for $outcome" `
                -When "Subset $chunkIndex is executed" `
                -Then "Observable result for subset $chunkIndex is verified" `
                -Oracle "$sid.part$chunkIndex.verified == true" `
                -VerificationType 'integration' `
                -Required $true)
        }

        $scopeStart = ($chunkIndex - 1) * $maxItems
        $chunkScope = @()
        if ($scopeStart -lt $scope.Count) {
            $chunkScope = @($scope | Select-Object -Skip $scopeStart -First $maxItems)
        } else {
            # Se ha mais criterios que escopos, associa o escopo de entrega focal correspondente
            $chunkScope = @("Deliver verifiable subset $chunkIndex for: $outcome")
        }

        $partId = "$sid-part-$chunkIndex"
        $partOutcome = "$outcome (Part $chunkIndex of $totalParts)"
        $partDeps = if ($chunkIndex -eq 1) {
            @(Get-DSValue $Slice 'dependencies' @())
        } else {
            if (-not [string]::IsNullOrWhiteSpace($prevSliceId)) { @($prevSliceId) } else { @() }
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
    }

    return @($subSlices.ToArray())
}

function Test-OrchestrationSliceMaturity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Slice,
        [hashtable]$RuntimeContext = @{}
    )

    if ($null -eq $Slice) {
        return [pscustomobject]@{
            maturity_state = 'FAILED'
            can_advance_to_done = $false
            reason = 'Slice is null'
            coverage = [pscustomobject]@{
                total = 0
                required = 0
                required_verified = 0
                verified = 0
                optional_total = 0
                optional_verified = 0
                blocked = 0
                failed = 0
            }
        }
    }

    $criteria = @(Get-DSValue $Slice 'acceptance_criteria' @())
    $vp = Safe-DSString (Get-DSValue $Slice 'validation_profile' 'STANDARD')
    $isDirect = ($vp -eq 'DIRECT')

    # Contabilizacao estrita e separada de criterios obrigatorios e opcionais (C2 / INV-01)
    $totalCriteria = $criteria.Count
    $requiredTotal = 0
    $requiredVerified = 0
    $requiredCandidate = 0
    $requiredBlocked = 0
    $requiredFailed = 0
    $requiredPending = 0

    $optionalTotal = 0
    $optionalVerified = 0
    $optionalCandidate = 0
    $optionalBlocked = 0
    $optionalFailed = 0
    $optionalPending = 0

    $hasBackendOnlyWithoutUserJourney = [bool](Get-DSValue $RuntimeContext 'backend_only_without_journey' $false)
    $hasUnconnectedTool = [bool](Get-DSValue $RuntimeContext 'tool_unconnected' $false)
    $isE2eMissingWhenRequired = [bool](Get-DSValue $RuntimeContext 'e2e_missing_when_required' $false)
    $isModelMissingInRequiredEval = [bool](Get-DSValue $RuntimeContext 'model_missing_in_eval' $false)
    $isEvidenceStale = [bool](Get-DSValue $RuntimeContext 'evidence_stale' $false)

    # Validacao de existencia real de evidencias quando EvidenceStore/Contexto for fornecido (C4)
    $evStoreDir = Safe-DSString (Get-DSValue $RuntimeContext 'evidence_store_dir' '')
    $mockEvidenceStore = Get-DSValue $RuntimeContext 'mock_evidence_store' $null
    $requireStoreValidation = [bool](Get-DSValue $RuntimeContext 'require_evidence_store_validation' $false)

    foreach ($c in $criteria) {
        $req = [bool](Get-DSValue $c 'required' $true)
        $st = Safe-DSString (Get-DSValue $c 'status' 'pending')
        $eref = Safe-DSString (Get-DSValue $c 'evidence_ref' '')
        $vt = Safe-DSString (Get-DSValue $c 'verification_type' 'deterministic_check')

        $isVerified = ($st -eq 'verified_pass' -and -not [string]::IsNullOrWhiteSpace($eref))

        # C4: Uma string arbitraria nao e prova se exigida validacao contra store
        if ($isVerified -and $requireStoreValidation) {
            $foundInStore = $false
            if ($null -ne $mockEvidenceStore -and ($mockEvidenceStore -is [System.Collections.IDictionary])) {
                $foundInStore = $mockEvidenceStore.Contains($eref)
            } elseif (-not [string]::IsNullOrWhiteSpace($evStoreDir) -and (Test-Path -LiteralPath $evStoreDir)) {
                $expectedFile = Join-Path $evStoreDir ($eref + '.json')
                $foundInStore = (Test-Path -LiteralPath $expectedFile -PathType Leaf)
            }
            if (-not $foundInStore) {
                $isVerified = $false
                $st = 'pending'
            }
        }

        if ($req) {
            $requiredTotal++
            if ($isVerified) { $requiredVerified++ }
            elseif ($st -eq 'candidate_pass') { $requiredCandidate++ }
            elseif ($st -eq 'blocked') { $requiredBlocked++ }
            elseif ($st -eq 'failed') { $requiredFailed++ }
            else { $requiredPending++ }
        } else {
            $optionalTotal++
            if ($isVerified) { $optionalVerified++ }
            elseif ($st -eq 'candidate_pass') { $optionalCandidate++ }
            elseif ($st -eq 'blocked') { $optionalBlocked++ }
            elseif ($st -eq 'failed') { $optionalFailed++ }
            else { $optionalPending++ }
        }
    }

    $covObj = [pscustomobject]@{
        total = $totalCriteria
        required = $requiredTotal
        required_verified = $requiredVerified
        verified = ($requiredVerified + $optionalVerified)
        optional_total = $optionalTotal
        optional_verified = $optionalVerified
        blocked = ($requiredBlocked + $optionalBlocked)
        failed = ($requiredFailed + $optionalFailed)
    }

    # Avaliacao normativa dos estados:
    # 1. BLOCKED se houver bloqueio em criterio obrigatorio ou falta de provider essencial
    if ($requiredBlocked -gt 0 -or $isModelMissingInRequiredEval) {
        return [pscustomobject]@{
            maturity_state = 'BLOCKED'
            can_advance_to_done = $false
            reason = if ($isModelMissingInRequiredEval) { 'Required model eval blocked due to missing provider/quota (AC-05 fail-closed).' } else { 'One or more required acceptance criteria are blocked by dependencies.' }
            coverage = $covObj
        }
    }

    # 2. FAILED se houver falha confirmada em criterio obrigatorio
    if ($requiredFailed -gt 0) {
        return [pscustomobject]@{
            maturity_state = 'FAILED'
            can_advance_to_done = $false
            reason = 'One or more mandatory acceptance criteria failed verification.'
            coverage = $covObj
        }
    }

    # 3. Regra AC-06: Evidencia desatualizada invalida verificacao
    if ($isEvidenceStale) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Evidence is stale in relation to base revision; re-verification required (AC-06).'
            coverage = $covObj
        }
    }

    # 4. Regras AC-02, AC-03, AC-04:
    if ($hasBackendOnlyWithoutUserJourney) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Backend changes alone without observable end-to-end user journey cannot be accepted as integrated (AC-02).'
            coverage = $covObj
        }
    }

    if ($hasUnconnectedTool) {
        return [pscustomobject]@{
            maturity_state = 'IMPLEMENTED'
            can_advance_to_done = $false
            reason = 'Tool registered in catalog without executable wiring does not satisfy integration criteria (AC-03).'
            coverage = $covObj
        }
    }

    if ($isE2eMissingWhenRequired -and -not $isDirect) {
        return [pscustomobject]@{
            maturity_state = 'INTEGRATED'
            can_advance_to_done = $false
            reason = 'Unit tests passing alone cannot substitute required end-to-end verification (AC-04).'
            coverage = $covObj
        }
    }

    # 5. VALIDATED se e somente se TODOS os criterios obrigatorios estao verified_pass
    # INV-01: Criterio opcional NUNCA compensa criterio obrigatorio pendente!
    $allRequiredVerified = ($requiredTotal -gt 0 -and $requiredVerified -eq $requiredTotal -and $requiredPending -eq 0 -and $requiredCandidate -eq 0 -and $requiredBlocked -eq 0 -and $requiredFailed -eq 0)

    # Distincao de autoridade de DONE (C4 / INV-06 / INV-07):
    $taskRecord = Get-DSValue $RuntimeContext 'task_record' (Get-DSValue $RuntimeContext 'bound_task_record' $null)
    $isKernelCompleted = $false
    if ($null -ne $taskRecord) {
        $tState = Safe-DSString (Get-DSValue $taskRecord 'state' '')
        if ($tState -in @('DONE', 'COMPLETED')) { $isKernelCompleted = $true }
    }
    $isKernelDoneAuthorized = [bool](Get-DSValue $RuntimeContext 'kernel_done_authorized' $false)

    if ($allRequiredVerified) {
        if ($isKernelCompleted) {
            return [pscustomobject]@{
                maturity_state = 'DONE'
                can_advance_to_done = $true
                reason = 'All required acceptance criteria proven and terminal state completed by TaskKernel.'
                coverage = $covObj
            }
        } elseif ($isKernelDoneAuthorized) {
            return [pscustomobject]@{
                maturity_state = 'DONE'
                can_advance_to_done = $true
                reason = 'All required acceptance criteria proven with independent oracle evidence and authorized by Kernel (AC-12).'
                coverage = $covObj
            }
        } else {
            return [pscustomobject]@{
                maturity_state = 'VALIDATED'
                can_advance_to_done = $true
                reason = 'All required acceptance criteria verified by independent oracles; ready for kernel completion.'
                coverage = $covObj
            }
        }
    }

    # 6. INTEGRATED se dependencias conectadas mas faltam verificacoes finais
    if (($requiredCandidate + $optionalCandidate) -gt 0 -or ($requiredVerified + $optionalVerified) -gt 0) {
        return [pscustomobject]@{
            maturity_state = 'INTEGRATED'
            can_advance_to_done = $false
            reason = 'Components and interfaces connected; independent verification pending on mandatory criteria.'
            coverage = $covObj
        }
    }

    return [pscustomobject]@{
        maturity_state = 'IMPLEMENTED'
        can_advance_to_done = $false
        reason = 'Local code written; integration and verification pending.'
        coverage = $covObj
    }
}

function Test-OrchestrationSliceDoneAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Slice,
        [hashtable]$RuntimeContext = @{}
    )

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

    $maturity = Test-OrchestrationSliceMaturity -Slice $Slice -RuntimeContext $RuntimeContext

    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            allowed = $false
            reason = "Mandatory criteria not verified: $($missing -join ', ')"
            missing_criteria = [string[]]$missing.ToArray()
            maturity = $maturity.maturity_state
        }
    }

    if ($maturity.maturity_state -in @('VALIDATED', 'DONE') -and $maturity.can_advance_to_done) {
        return [pscustomobject]@{
            allowed = $true
            reason = 'All mandatory criteria satisfied with verified evidence.'
            missing_criteria = @()
            maturity = $maturity.maturity_state
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
        [string]$DiscriminantTest = '',
        [int]$ConsecutiveStalls = -1,
        [bool]$HasProgress = $false
    )

    if ($HasProgress) {
        return [pscustomobject]@{
            can_retry = $true
            action = 'PROGRESS_ADVANCING'
            reason = 'Measurable progress demonstrated; corrective cycle continues without stall escalation.'
            escalate_advisor = $false
        }
    }

    $attempts = [int](Get-DSValue $Slice 'attempt_count' 0)
    $effectiveStalls = if ($ConsecutiveStalls -ge 0) { $ConsecutiveStalls } else { $attempts }
    $hypotheses = @(Get-DSValue $Slice 'hypotheses' @())

    if ($effectiveStalls -lt $MaxConsecutiveStalls) {
        return [pscustomobject]@{
            can_retry = $true
            action = 'NORMAL_RETRY'
            reason = "Consecutive stalls ($effectiveStalls) within normal corrective threshold ($MaxConsecutiveStalls)."
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

    # 1. Projecao direta em memoria
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

    # 2. Persistencia compativel com schema estrito do GoalKernel (campo next_move / decision_refs)
    $sliceMeta = [ordered]@{
        slice_id = $sid
        outcome = $outc
        maturity = $maturity.maturity_state
        coverage = $maturity.coverage
    }
    $rawNext = Get-DSValue $Goal 'next_move' $null
    if ($null -eq $rawNext) {
        $rawNext = [ordered]@{}
        if ($Goal -is [System.Collections.IDictionary]) { $Goal['next_move'] = $rawNext }
        else { $Goal | Add-Member -NotePropertyName 'next_move' -NotePropertyValue $rawNext -Force }
    }
    if ($rawNext -is [System.Collections.IDictionary]) {
        $rawNext['delivery_slice'] = $sliceMeta
    } elseif ($null -ne $rawNext) {
        $rawNext | Add-Member -NotePropertyName 'delivery_slice' -NotePropertyValue $sliceMeta -Force
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

function Save-OrchestrationDeliverySlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Slice,
        [string]$StoreDir = ''
    )
    try {
        if ($null -eq $Slice) { return [pscustomobject]@{ ok = $false; error = 'SLICE_NULL' } }
        $sid = Safe-DSString (Get-DSValue $Slice 'slice_id' '')
        if ([string]::IsNullOrWhiteSpace($sid)) { return [pscustomobject]@{ ok = $false; error = 'MISSING_SLICE_ID' } }

        $targetDir = if (-not [string]::IsNullOrWhiteSpace($StoreDir)) {
            Join-Path $StoreDir 'delivery-slices'
        } else {
            Join-Path (Get-Location) 'cache/delivery-slices'
        }
        if (-not (Test-Path -LiteralPath $targetDir)) {
            [void](New-Item -ItemType Directory -Path $targetDir -Force)
        }
        $filePath = Join-Path $targetDir "$sid.json"
        $json = ConvertTo-Json -InputObject $Slice -Depth 10
        [IO.File]::WriteAllText($filePath, $json, [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ok = $true; path = $filePath; slice_id = $sid }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Get-OrchestrationDeliverySlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SliceId,
        [string]$StoreDir = ''
    )
    try {
        $sid = Safe-DSString $SliceId 64
        $targetDir = if (-not [string]::IsNullOrWhiteSpace($StoreDir)) {
            Join-Path $StoreDir 'delivery-slices'
        } else {
            Join-Path (Get-Location) 'cache/delivery-slices'
        }
        $filePath = Join-Path $targetDir "$sid.json"
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; error = 'NOT_FOUND'; slice = $null }
        }
        $raw = [IO.File]::ReadAllText($filePath, [Text.UTF8Encoding]::new($false))
        $slice = ConvertFrom-Json -InputObject $raw
        return [pscustomobject]@{ ok = $true; slice = $slice; path = $filePath }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message; slice = $null }
    }
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
        $hasUnmetMandatory = $false
        foreach ($c in $criteria) {
            $req = [bool](Get-DSValue $c 'required' $true)
            $st = Safe-DSString (Get-DSValue $c 'status' 'pending')
            $eref = Safe-DSString (Get-DSValue $c 'evidence_ref' '')
            if ($req) {
                $totalCriteria++
                if ($st -eq 'verified_pass' -and -not [string]::IsNullOrWhiteSpace($eref)) {
                    $verifiedCriteria++
                } else {
                    $hasUnmetMandatory = $true
                }
            }
        }

        # Contabilizacao confiavel de falso DONE:
        # Se a fatia alega estado DONE mas tem criterios obrigatorios nao verificados
        if ($mst -eq 'DONE' -and ($hasUnmetMandatory -or $criteria.Count -eq 0)) {
            $falseDoneCount++
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


