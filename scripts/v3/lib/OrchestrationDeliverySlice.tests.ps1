<#!
.SYNOPSIS
    Test suite for OrchestrationDeliverySlice (Incremental Delivery & Evidence-Driven Development).
.DESCRIPTION
    Validates the vertical slice contract, observable acceptance criteria,
    admissibility checks, assisted subdivision, maturity projection,
    convergence rules, and DONE gates.
    PS 5.1 and PS 7 compatible.
#>
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LibPath = Join-Path $ScriptDir 'OrchestrationDeliverySlice.ps1'

if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Error "Library not found at $LibPath"
    exit 1
}

. $LibPath

$TotalAssertions = 0
$FailedAssertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:TotalAssertions++
    if (-not $Condition) {
        $script:FailedAssertions++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    $script:TotalAssertions++
    if ($Actual -ne $Expected) {
        $script:FailedAssertions++
        Write-Host "FAIL: $Message (Expected: '$Expected', Actual: '$Actual')" -ForegroundColor Red
    }
}

Write-Host "Starting OrchestrationDeliverySlice test suite..."

# 1. Fatia valida basica
$c1 = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-EXPENSE-01' `
    -Given 'Valid test database and logged-in test user' `
    -When 'User sends text "gastei 50 de carne"' `
    -Then 'Agent records expense with amount 50 and category food' `
    -Oracle 'db.expenses.where(amount=50).count == 1' `
    -VerificationType 'integration' `
    -Required $true

$slice1 = New-OrchestrationDeliverySlice `
    -SliceId 'slice-expense-entry' `
    -ObjectiveId 'obj-personal-finance-v1' `
    -Outcome 'User can record an expense by messaging the agent' `
    -Scope @('Interpret expense intent', 'Select account', 'Persist authorized record', 'Show confirmation') `
    -NonGoals @('Recurring expenses', 'Bank sync', 'Multi-currency support') `
    -AcceptanceCriteria @($c1) `
    -RiskLevel 'medium' `
    -ValidationProfile 'STANDARD'

$val1 = Test-OrchestrationDeliverySlice -Slice $slice1
Assert-True $val1.valid "Valid slice should pass schema validation"
Assert-Equal $val1.errors.Count 0 "Valid slice should have 0 errors"

# 2. Fatia sem resultado observavel (outcome ausente ou muito curto)
$sliceNoOutcome = New-OrchestrationDeliverySlice `
    -SliceId 'slice-bad-outcome' `
    -Outcome '' `
    -Scope @('Alter files in repo') `
    -AcceptanceCriteria @($c1)

$valNoOutcome = Test-OrchestrationDeliverySlice -Slice $sliceNoOutcome
Assert-True (-not $valNoOutcome.valid) "Slice without outcome must fail validation"

# 3. Fatia sem criterios de aceite
$sliceNoCriteria = New-OrchestrationDeliverySlice `
    -SliceId 'slice-no-crit' `
    -Outcome 'User can see a working screen' `
    -Scope @('Build UI') `
    -AcceptanceCriteria @()

$valNoCriteria = Test-OrchestrationDeliverySlice -Slice $sliceNoCriteria
Assert-True (-not $valNoCriteria.valid) "Slice without criteria must fail validation"

# 4. Criterio sem oraculo independente
$cNoOracle = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-NO-ORACLE' `
    -Given 'Context exists' `
    -When 'User clicks button' `
    -Then 'UI says ok' `
    -Oracle ''

$sliceNoOracle = New-OrchestrationDeliverySlice `
    -SliceId 'slice-no-oracle' `
    -Outcome 'User clicks button and sees ok' `
    -Scope @('Button click') `
    -AcceptanceCriteria @($cNoOracle)

$valNoOracle = Test-OrchestrationDeliverySlice -Slice $sliceNoOracle
Assert-True (-not $valNoOracle.valid) "Criterion without authoritative oracle must fail validation"

# 5. Dependencia circular
$sliceCircular = New-OrchestrationDeliverySlice `
    -SliceId 'slice-circular' `
    -Outcome 'User can execute action' `
    -Scope @('Feature execution') `
    -Dependencies @('slice-circular') `
    -AcceptanceCriteria @($c1)

$valCircular = Test-OrchestrationDeliverySlice -Slice $sliceCircular
Assert-True (-not $valCircular.valid) "Circular dependency must fail validation"

# 6. Admissibilidade e necessidade de subdivisao por escopo excessivo
$largeScope = 1..15 | ForEach-Object { "Sub-feature $_" }
$largeCriteria = 1..10 | ForEach-Object {
    New-OrchestrationAcceptanceCriterion `
        -CriterionId "AC-LARGE-$_" `
        -Given 'Condition' `
        -When 'Action' `
        -Then 'Result' `
        -Oracle "oracle_$_ == true"
}

$sliceLarge = New-OrchestrationDeliverySlice `
    -SliceId 'slice-large' `
    -Outcome 'Deliver massive monolith combining all modules' `
    -Scope $largeScope `
    -NonGoals @('External deployment') `
    -AcceptanceCriteria $largeCriteria `
    -RiskLevel 'high' `
    -ValidationProfile 'HIGH_RISK'

$admissibility = Test-OrchestrationDeliverySliceAdmissibility -Slice $sliceLarge
Assert-True (-not $admissibility.admissible) "Massive slice should fail immediate admission"
Assert-True $admissibility.requires_subdivision "Massive slice should require subdivision"

# 7. Subdivisao assistida preservando rastreabilidade
$splitSlices = Split-OrchestrationDeliverySlice -Slice $sliceLarge -MaxItemsPerSlice 4
Assert-True ($splitSlices.Count -ge 3) "Split should produce at least 3 smaller slices"
Assert-Equal $splitSlices[0].slice_id 'slice-large-part-1' "First part should have traceable id"
Assert-Equal $splitSlices[1].slice_id 'slice-large-part-2' "Second part should have traceable id"
Assert-Equal $splitSlices[1].dependencies[0] 'slice-large-part-1' "Second part should depend on first part sequentially"

# 8. Regra AC-02: Backend-only sem jornada observada nao e INTEGRATED
$sliceBackendOnly = New-OrchestrationDeliverySlice `
    -SliceId 'slice-backend' `
    -Outcome 'Add backend handler' `
    -Scope @('Add route in express') `
    -AcceptanceCriteria @($c1)

$matBackend = Test-OrchestrationSliceMaturity `
    -Slice $sliceBackendOnly `
    -RuntimeContext @{ backend_only_without_journey = $true }

Assert-Equal $matBackend.maturity_state 'IMPLEMENTED' "Backend-only change cannot be accepted as INTEGRATED (AC-02)"
Assert-True (-not $matBackend.can_advance_to_done) "Backend-only change cannot advance to DONE"

# 9. Regra AC-03: Tool no catalogo sem conexao executavel nao satisfaz integracao
$matUnconnectedTool = Test-OrchestrationSliceMaturity `
    -Slice $slice1 `
    -RuntimeContext @{ tool_unconnected = $true }

Assert-Equal $matUnconnectedTool.maturity_state 'IMPLEMENTED' "Unconnected tool cannot be accepted as INTEGRATED (AC-03)"

# 10. Regra AC-04: Teste unitario isolado nao substitui E2E obrigatorio
$cVerifiedUnit = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-UNIT-ONLY' `
    -Given 'Unit test harness' `
    -When 'Run Pester' `
    -Then 'Unit tests pass' `
    -Oracle 'pester.passed == true' `
    -VerificationType 'unit' `
    -EvidenceRef 'ev-unit-123' `
    -Status 'verified_pass'

$sliceUnitOnly = New-OrchestrationDeliverySlice `
    -SliceId 'slice-unit' `
    -Outcome 'User workflow completes' `
    -Scope @('Complete user workflow') `
    -NonGoals @('External deploy') `
    -AcceptanceCriteria @($cVerifiedUnit) `
    -ValidationProfile 'STANDARD'

$matUnitWithoutE2e = Test-OrchestrationSliceMaturity `
    -Slice $sliceUnitOnly `
    -RuntimeContext @{ e2e_missing_when_required = $true }

Assert-Equal $matUnitWithoutE2e.maturity_state 'INTEGRATED' "Unit test green cannot substitute required E2E (AC-04)"
Assert-True (-not $matUnitWithoutE2e.can_advance_to_done) "Cannot advance to DONE without required E2E"

# 11. Regra AC-05: Falta de provider em eval obrigatoria gera BLOCKED_EXTERNAL, nao PASS
$cModelEval = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-MODEL-EVAL' `
    -Given 'LLM intent classifier' `
    -When 'Prompt with natural language variations' `
    -Then 'Correct tool selected with 95% confidence' `
    -Oracle 'llm_eval.accuracy >= 0.95' `
    -VerificationType 'model_eval' `
    -Status 'pending'

$sliceModelEval = New-OrchestrationDeliverySlice `
    -SliceId 'slice-model' `
    -Outcome 'Agent correctly understands conversational inputs' `
    -Scope @('Model prompt tuning') `
    -NonGoals @('Fine-tuning') `
    -AcceptanceCriteria @($cModelEval)

$matModelBlocked = Test-OrchestrationSliceMaturity `
    -Slice $sliceModelEval `
    -RuntimeContext @{ model_missing_in_eval = $true }

Assert-Equal $matModelBlocked.maturity_state 'BLOCKED' "Missing provider/quota in required eval must be BLOCKED (AC-05)"
Assert-True (-not $matModelBlocked.can_advance_to_done) "Blocked eval cannot advance to DONE"

# 12. Regra AC-06: Evidencia desatualizada (stale) impede conclusao
$matStale = Test-OrchestrationSliceMaturity `
    -Slice $slice1 `
    -RuntimeContext @{ evidence_stale = $true }

Assert-Equal $matStale.maturity_state 'IMPLEMENTED' "Stale evidence invalidates verification (AC-06)"

# 13. Regra AC-07: Controle de convergencia (2 tentativas sem progresso exigem diagnostico/advisor)
$sliceStalled0 = New-OrchestrationDeliverySlice `
    -SliceId 'slice-stalled' `
    -Outcome 'Correct bug in data parser' `
    -Scope @('Fix parser') `
    -AcceptanceCriteria @($c1) `
    -AttemptCount 0

$prog0 = Test-OrchestrationConvergenceProgress -Slice $sliceStalled0
Assert-True $prog0.can_retry "Attempt 0 can retry normally"
Assert-Equal $prog0.action 'NORMAL_RETRY' "Attempt 0 action should be NORMAL_RETRY"

$sliceStalled2 = New-OrchestrationDeliverySlice `
    -SliceId 'slice-stalled' `
    -Outcome 'Correct bug in data parser' `
    -Scope @('Fix parser') `
    -AcceptanceCriteria @($c1) `
    -AttemptCount 2 `
    -Hypotheses @('Regex character class issue', 'Encoding mismatch')

# 3a tentativa SEM nova hipotese deve ser rejeitada e escalonada
$progStalled = Test-OrchestrationConvergenceProgress `
    -Slice $sliceStalled2 `
    -NewHypothesis 'Regex character class issue' `
    -DiscriminantTest ''

Assert-True (-not $progStalled.can_retry) "Repeating same hypothesis after 2 stalls must be rejected (AC-07)"
Assert-Equal $progStalled.action 'ESCALATE_DIAGNOSTIC' "Must escalate to diagnostic/advisor after 2 stalls"
Assert-True $progStalled.escalate_advisor "Should flag advisor escalation"

# 3a tentativa COM nova hipotese e teste discriminante deve ser permitida
$progDiscriminant = Test-OrchestrationConvergenceProgress `
    -Slice $sliceStalled2 `
    -NewHypothesis 'Parser buffer split boundary truncation' `
    -DiscriminantTest 'Test buffer chunks of 512 bytes'

Assert-True $progDiscriminant.can_retry "3rd attempt with new hypothesis and discriminant test is allowed"
Assert-Equal $progDiscriminant.action 'DISCRIMINANT_RETRY' "Action should be DISCRIMINANT_RETRY"

# 14. Gate de DONE: Coder attestation alone (candidate_pass) is NOT enough
$cCandidateOnly = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-CANDIDATE-ONLY' `
    -Given 'Feature implemented' `
    -When 'Coder claims completed' `
    -Then 'Code compiles' `
    -Oracle 'coder_report.passed == true' `
    -VerificationType 'unit' `
    -Status 'candidate_pass'

$sliceCandidate = New-OrchestrationDeliverySlice `
    -SliceId 'slice-cand' `
    -Outcome 'Feature done' `
    -Scope @('Feature') `
    -AcceptanceCriteria @($cCandidateOnly)

$doneCheckCand = Test-OrchestrationSliceDoneAllowed -Slice $sliceCandidate
Assert-True (-not $doneCheckCand.allowed) "Candidate pass from coder alone cannot authorize DONE"

# 15. Gate de DONE: Todos os criterios obrigatorios verificados com oraculo independente
$cFullyVerified = New-OrchestrationAcceptanceCriterion `
    -CriterionId 'AC-VERIFIED-REAL' `
    -Given 'Database fixture ready' `
    -When 'Endpoint receives payload' `
    -Then 'Row inserted and verified in DB' `
    -Oracle 'db.orders.count == 1' `
    -VerificationType 'integration' `
    -EvidenceRef 'ev-sha256-verified-789' `
    -Status 'verified_pass'

$sliceFullyVerified = New-OrchestrationDeliverySlice `
    -SliceId 'slice-verified-ok' `
    -Outcome 'Order persistence works' `
    -Scope @('Order persistence') `
    -NonGoals @('Invoice printing') `
    -AcceptanceCriteria @($cFullyVerified) `
    -ValidationProfile 'STANDARD'

$doneCheckOk = Test-OrchestrationSliceDoneAllowed `
    -Slice $sliceFullyVerified `
    -RuntimeContext @{ kernel_done_authorized = $true }

Assert-True $doneCheckOk.allowed "Fully verified slice with kernel authorization must allow DONE (AC-12)"
Assert-Equal $doneCheckOk.maturity 'DONE' "Maturity should be DONE"

# 16. Projecao de maturidade intermediaria: VALIDATED quando pronto para conclusao do kernel
$doneCheckValidated = Test-OrchestrationSliceDoneAllowed `
    -Slice $sliceFullyVerified `
    -RuntimeContext @{ kernel_done_authorized = $false }

Assert-True $doneCheckValidated.allowed "Fully verified slice without kernel done yet is VALIDATED"
Assert-Equal $doneCheckValidated.maturity 'VALIDATED' "Maturity should be VALIDATED"

# 17. Sincronizacao de metadados com GoalKernel
$goalRecord = [ordered]@{
    goal_id = 'goal-test-101'
    state = 'ACTIVE'
    objective = 'Deliver core features'
    active_tasks = @('task-01')
    completed_tasks = @()
}
$syncedGoal = Sync-OrchestrationDeliverySliceToGoal -Goal $goalRecord -Slice $sliceFullyVerified
Assert-Equal $syncedGoal['active_slice_id'] 'slice-verified-ok' "Goal should have active_slice_id attached"
Assert-Equal $syncedGoal['slice_maturity'] 'VALIDATED' "Goal should project slice_maturity as VALIDATED"

# 18. Sincronizacao de metadados com TaskKernel
$taskRecord = [ordered]@{
    task_id = 'task-01'
    status = 'PENDING'
    role = 'coder'
}
$syncedTask = Sync-OrchestrationDeliverySliceToTask -Task $taskRecord -Slice $sliceFullyVerified
Assert-Equal $syncedTask['delivery_slice_id'] 'slice-verified-ok' "Task should have delivery_slice_id attached"
Assert-Equal $syncedTask['validation_profile'] 'STANDARD' "Task should have validation_profile attached"

# 19. Integracao com PlannerLoop: perfil DIRECT
$plannerLib = Join-Path $ScriptDir 'OrchestrationPlannerLoop.ps1'
if (Test-Path -LiteralPath $plannerLib) {
    . $plannerLib

    $sliceDirect = New-OrchestrationDeliverySlice `
        -SliceId 'slice-direct-01' `
        -Outcome 'Fix typo in documentation comment' `
        -Scope @('Correct typo in comment') `
        -NonGoals @('Refactoring') `
        -AcceptanceCriteria @($c1) `
        -RiskLevel 'low' `
        -ValidationProfile 'DIRECT'

    $descDirect = @{
        objective = 'Fix typo in documentation comment'
        risk = 'low'
        task_shape = 'single_file'
        delivery_slice = $sliceDirect
    }

    $plannerResDirect = Invoke-OrchestrationPlannerLoop -Descriptor $descDirect
    Assert-Equal $plannerResDirect.status 'ok' "PlannerLoop should return ok for DIRECT slice"
    Assert-Equal $plannerResDirect.plan.delivery_slice.validation_profile 'DIRECT' "PlannerLoop should record DIRECT profile"
    Assert-Equal $plannerResDirect.plan.validation.level 'L1' "DIRECT slice should map to L1 validation level"
    Assert-Equal $plannerResDirect.plan.dispatch_plan.workers.Count 1 "DIRECT slice should route to single worker"
    Assert-Equal $plannerResDirect.plan.dispatch_plan.workers[0] 'coder' "DIRECT slice worker should be coder"

    # 20. Integracao com PlannerLoop: perfil HIGH_RISK
    $sliceHighRisk = New-OrchestrationDeliverySlice `
        -SliceId 'slice-hr-01' `
        -Outcome 'Implement payment credential rotation' `
        -Scope @('Rotate payment API secret', 'Verify HMAC signature') `
        -NonGoals @('Database migration') `
        -AcceptanceCriteria @($c1) `
        -RiskLevel 'high' `
        -ValidationProfile 'HIGH_RISK'

    $descHighRisk = @{
        objective = 'Implement payment credential rotation'
        risk = 'high'
        task_shape = 'cross_cutting'
        delivery_slice = $sliceHighRisk
    }

    $plannerResHR = Invoke-OrchestrationPlannerLoop -Descriptor $descHighRisk
    Assert-Equal $plannerResHR.status 'ok' "PlannerLoop should return ok for HIGH_RISK slice"
    Assert-Equal $plannerResHR.plan.delivery_slice.validation_profile 'HIGH_RISK' "PlannerLoop should record HIGH_RISK profile"
    Assert-Equal $plannerResHR.plan.validation.level 'L3' "HIGH_RISK slice should map to L3 validation level"
    Assert-True ($plannerResHR.plan.dispatch_plan.workers -contains 'security-reviewer') "HIGH_RISK slice must require security-reviewer"

    # 21. Integracao com PlannerLoop: Fatia excessiva sinaliza requires_subdivision
    $descLarge = @{
        objective = 'Deliver massive monolith combining all modules'
        risk = 'high'
        task_shape = 'monolith'
        delivery_slice = $sliceLarge
    }

    $plannerResLarge = Invoke-OrchestrationPlannerLoop -Descriptor $descLarge
    Assert-Equal $plannerResLarge.status 'ok' "PlannerLoop should return ok for large slice"
    Assert-True $plannerResLarge.plan.delivery_slice.requires_subdivision "PlannerLoop should detect requires_subdivision = true for oversized slice"
}

# 22. Telemetria de fatias
$sliceTelemetryInput = @(
    $sliceFullyVerified,
    $sliceStalled2,
    $slice1
)
$sliceFullyVerified['maturity_state'] = 'DONE'
$sliceStalled2['maturity_state'] = 'FAILED'
$slice1['maturity_state'] = 'IMPLEMENTED'

$telemetrySummary = Get-OrchestrationSliceTelemetrySummary -Slices $sliceTelemetryInput
Assert-Equal $telemetrySummary.slices_total 3 "Telemetry should count total slices"
Assert-Equal $telemetrySummary.slices_by_maturity.DONE 1 "Telemetry should breakdown DONE slices"
Assert-Equal $telemetrySummary.slices_by_maturity.FAILED 1 "Telemetry should breakdown FAILED slices"
Assert-Equal $telemetrySummary.total_rework_attempts 2 "Telemetry should aggregate total rework attempts"
Assert-Equal $telemetrySummary.false_done_count 0 "False DONE count should be zero"
Assert-True ($telemetrySummary.first_pass_acceptance_rate -gt 0) "First pass acceptance rate should be positive"



Write-Host "Total assertions: $script:TotalAssertions"
Write-Host "Failed assertions: $script:FailedAssertions"

if ($script:FailedAssertions -gt 0) {
    Write-Host "SUITE FAILED: $script:FailedAssertions assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "SUITE PASSED: All $script:TotalAssertions assertions passed." -ForegroundColor Green
exit 0
