<#!
.SYNOPSIS
    Task Kernel CLI: thin wrapper over lib/OrchestrationTaskKernel.ps1.
.DESCRIPTION
    Actions:
      create        - New-OrchestrationTask (needs -TaskId -Objective; optional -Project for active-work dedupe: same objective+scope+DoD+project on an ACTIVE task returns DUPLICATE_ACTIVE_WORK, never merges; optional -RequireTypedWaits switch for a sticky per-task typed-wait requirement; optional -VerificationProfiles commits the immutable verification plan before model dispatch)
      check-duplicate - Get-OrchestrationDuplicateWork query (needs -Objective; optional scopes/criteria/project; read-only, no creation)
      get           - Get-OrchestrationTask (needs -TaskId)
      status        - Get-OrchestrationTaskStatus (needs -TaskId)
      transition    - Invoke-OrchestrationTaskTransition (needs -TaskId -ToState -Actor -ExpectedRevision; optional typed wait for -ToState BLOCKED; unblock from BLOCKED needs -WaitFingerprint or -UnblockAction when a typed wait is active)
      record-result - Set-OrchestrationTaskWorkerResult (needs -TaskId -WorkerStatus -ProducedBy -ExpectedRevision; optional strategy/recovery fields -StrategyId -StrategyApproach -StrategyTool -StrategyParams -StrategyFingerprint -FailureClass -FailureDetail -RecoverySource -NewEvidenceRefs)
      verify        - Set-OrchestrationTaskVerification (UNTRUSTED caller JSON/file; persists verification_source=caller-supplied, never proof-capable)
      verify-run    - Invoke-TaskKernelVerifyRun (TRUSTED: executes the task's committed verification_profiles plan in-process in the task repo; needs -TaskId -ExpectedRevision; no result JSON accepted)
      review        - Set-OrchestrationTaskReview (needs -TaskId -ReviewKind reviewer|security -ReviewStatus approved|changes_required -ReviewBy -ExpectedRevision; optional anchored findings via -FindingsFile or -FindingsJson, validated/bounded, persisted in the review entry)
      review-schema - Print the versioned anchored-review findings schema (read-only; no -TaskId)
      event-attach  - Add-OrchestrationTaskEvent (needs -TaskId -ExpectedRevision; optional -EnvelopeFile or -EnvelopeJson; delivers one validated GitHub event to event_inbox with idempotent dedup)
      event-ack     - Confirm-OrchestrationTaskEvent (needs -TaskId -DedupKey -SessionId -ExpectedRevision; optional -ResponseSummary; idempotent consumption/settlement ack)
      block         - Block-OrchestrationTask (needs -TaskId -Actor -Reason -ExpectedRevision; optional typed wait -WaitType -WaitOwner -WaitAction [-WaitDependencyId]; re-block with the same wait fingerprint is idempotent)
      cancel        - Cancel-OrchestrationTask (needs -TaskId -Actor -Reason -ExpectedRevision)
      complete      - Complete-OrchestrationTask (needs -TaskId -Actor -ExpectedRevision)
      watchdog-interrupt - Set-OrchestrationTaskWatchdogInterrupt (needs -TaskId -Actor -ExpectedRevision -WatchdogAttemptN -WatchdogClass; optional -WatchdogTelemetryFile)
      watchdog-settle    - Confirm-OrchestrationTaskWatchdogSettlement (needs -TaskId -Actor -ExpectedRevision; idempotent; optional -WatchdogDisposition RETRY|CLOSE, default RETRY)
      model-attempt - Set-OrchestrationTaskModelAttempt (needs -TaskId -SessionId <child> -ExpectedRevision; records only independently-observed session evidence, no dispatch)
      model-proof   - Get-OrchestrationTaskModelFailureProof (needs -TaskId -RequiredTier T3|T4; read-only recomputation, no proof params)
      model-select  - Planner read-only selection (needs -TaskId -AttemptRole <role>; optional -Risk -ModelComplexity -TaskType -RequiresLlm; returns tier + providerID/modelID + policy_hash + proof refs; no dispatch, no session spawn; load failure => MODEL_ROUTER_LOAD_FAILED, selection failure => MODEL_SELECTION_FAILED)
      path-overrides - -TasksDir -FlagsPath -CliRepoRoot -PolicyPath are compat-only: omit them to use the canonical paths derived from the script; any divergent value returns TRUSTED_PATH_MISMATCH before IO; never point them at another store/policy
      get-budget    - Get-OrchestrationTaskBudget (needs -TaskId; old records derive defaults read-only)
      start-attempt - Start-OrchestrationTaskAttempt (needs -TaskId -AttemptRole -SessionId -Actor -ExpectedRevision; optional -DebuggerEvidenceRefs/-NewEvidenceRefs string arrays for retry-gated starts; optional strategy fields -StrategyId -StrategyApproach -StrategyTool -StrategyParams -StrategyFingerprint -AttemptHypothesis for stall gates)
      set-budget    - Set-OrchestrationTaskBudget planner/kernel only (needs -TaskId -Actor -ExpectedRevision)
      planner-turn  - Start-OrchestrationPlannerTurn (needs -TaskId -PlannerTurnId -UserInputSignal -UserInputSequence -Actor -ExpectedRevision)
    List parameters (-ReadScopes, -WriteScopes, -Grants, -AcceptanceCriteria,
    -ExpectedArtifacts, -EnvironmentAllowed, -Evidence, -CommandClasses,
    -ClaimedEvidence, -ResidualRisks) accept native PowerShell arrays
    (-Evidence 'a' 'b'). A single value containing '|' is split on '|'.
    Prints the result as JSON (ConvertTo-Json -Depth 12).
    Exit codes:
      0 ok
      1 domain error not listed below (ALREADY_EXISTS, STATUS_NOT_ALLOWED_FROM_WORKER, UNKNOWN_STATE, INVALID_*, WRITE_*, INTERNAL_ERROR)
      2 usage (missing/invalid CLI parameters, unknown action)
      3 CAS_CONFLICT
      4 ILLEGAL_TRANSITION
      5 KERNEL_DISABLED
      6 COMPLETION_GATE_FAILED
      7 NOT_FOUND or MALFORMED
      8 UNTRUSTED_IDENTITY
    PowerShell 5.1. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$Action = '',
    [string]$TaskId = '',
    [string]$Objective = '',
    [string]$TaskType = '',
    [string]$Risk = '',
    [string]$Actor = '',
    [string]$ToState = '',
    [string]$WorkerStatus = '',
    [string]$ProducedBy = '',
    [string[]]$ClaimedEvidence = @(),
    [string]$Passed = '',
    [string[]]$Evidence = @(),
    [string[]]$CommandClasses = @(),
    [string]$VerifierResultFile = '',
    [string]$VerifierResultJson = '',
    [string]$ReviewKind = '',
    [string]$ReviewStatus = '',
    [string]$ReviewBy = '',
    [string]$FindingsFile = '',
    [string]$FindingsJson = '',
    [string]$EnvelopeFile = '',
    [string]$EnvelopeJson = '',
    [string]$DedupKey = '',
    [string]$ResponseSummary = '',
    [string]$Reason = '',
    [int]$ExpectedRevision = -1,
    [string[]]$ResidualRisks = @(),
    [switch]$AcceptEmptyResidualRisks,
    [switch]$NewEvidence,
    [switch]$DebuggerInvoked,
    [string]$Hypothesis = '',
    [string]$OrchestrationCompliance = '',
    [string]$ActorIdentitySource = '',
    [string]$ParentTaskId = '',
    [string]$TraceId = '',
    [string]$OrchestrationDecision = '',
    [string]$RuntimeId = '',
    [int]$RuntimeGeneration = 1,
    [string]$RuntimeProfile = '',
    [string]$RuntimeVersion = '',
    [string]$BaseRevision = '',
    [string[]]$ReadScopes = @(),
    [string[]]$WriteScopes = @(),
    [string[]]$Grants = @(),
    [string[]]$AcceptanceCriteria = @(),
    [string[]]$ExpectedArtifacts = @(),
    [string[]]$EnvironmentAllowed = @(),
    [switch]$ProductionAuthorized,
    $AttemptBudget = 3,
    [string]$BudgetProfile = '',
    [string]$BudgetPolicyPath = '',
    [string]$SessionId = '',
    [string]$AttemptRole = '',
    [string[]]$DebuggerEvidenceRefs = @(),
    [string[]]$NewEvidenceRefs = @(),
    [string]$PlannerTurnId = '',
    [string]$UserInputSignal = '',
    $UserInputSequence = $null,
    $BudgetWallSeconds = $null,
    $BudgetStepBudget = $null,
    $BudgetNoProgressSeconds = $null,
    [string]$TasksDir = '',
    [string]$FlagsPath = '',
    [string]$LeasesDir = '',
    [string]$CurrentBaseRevision = '',
    $WatchdogAttemptN = $null,
    [string]$WatchdogClass = '',
    [string]$WatchdogTelemetryFile = '',
    [string]$WatchdogDisposition = '',
    [string]$Project = '',
    [switch]$RequireTypedWaits,
    [string]$StrategyId = '',
    [string]$StrategyApproach = '',
    [string]$StrategyTool = '',
    [string[]]$StrategyParams = @(),
    [string]$StrategyFingerprint = '',
    [string]$FailureClass = '',
    [string]$FailureDetail = '',
    [string]$RecoverySource = '',
    [string]$AttemptHypothesis = '',
    [string]$WaitType = '',
    [string]$WaitOwner = '',
    [string]$WaitAction = '',
    [string]$WaitDependencyId = '',
    [string]$WaitFingerprint = '',
    [string]$UnblockAction = ''
    ,[string]$RunId = '', [string]$SeatId = '', [string]$BindingRuntime = '', [string]$BindingVersion = '',
    [string]$ParentSessionId = '', [string]$RootSessionId = '', [switch]$WorkerSession,
    [string]$RequiredTier = '', [string]$ChildSessionId = '', [string]$PolicyPath = '',
    [string]$CliRepoRoot = '', [string[]]$VerifierProfiles = @(),
    [string]$ModelComplexity = '', [switch]$RequiresLlm
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
. (Join-Path $v3root 'lib\OrchestrationTaskKernel.ps1')

function Write-TaskKernelCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Split-TaskKernelCliList {
    param([string[]]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Value) {
        foreach ($v in @($Value)) {
            if ($null -eq $v) { continue }
            $s = ([string]$v)
            if ($s.Contains('|')) {
                foreach ($part in ($s -split '\|')) {
                    $out.Add([string]$part) | Out-Null
                }
            }
            else {
                $out.Add($s) | Out-Null
            }
        }
    }
    return [string[]]$out.ToArray()
}

function Get-TaskKernelResultError {
    param($Result)
    if ($null -eq $Result) { return 'INTERNAL_ERROR' }
    if ($Result -is [System.Collections.IDictionary]) {
        if ($Result.Contains('error')) { return [string]$Result['error'] }
        return ''
    }
    $p = $Result.PSObject.Properties | Where-Object { $_.Name -ceq 'error' } | Select-Object -First 1
    if ($null -ne $p) { return [string]$p.Value }
    return ''
}

function Get-TaskKernelExitCode {
    param([string]$ErrorCode)
    if ([string]::IsNullOrWhiteSpace($ErrorCode)) { return 0 }
    if ($ErrorCode -ceq 'CAS_CONFLICT') { return 3 }
    if ($ErrorCode -ceq 'ILLEGAL_TRANSITION') { return 4 }
    if ($ErrorCode -ceq 'KERNEL_DISABLED') { return 5 }
    if ($ErrorCode -ceq 'COMPLETION_GATE_FAILED') { return 6 }
    if (($ErrorCode -ceq 'NOT_FOUND') -or ($ErrorCode -ceq 'MALFORMED')) { return 7 }
    if ($ErrorCode -ceq 'UNTRUSTED_IDENTITY') { return 8 }
    return 1
}

$action = ([string]$Action).Trim().ToLowerInvariant()
$validActions = @('create', 'get', 'status', 'transition', 'record-result', 'verify', 'verify-run', 'review', 'review-schema', 'event-attach', 'event-ack', 'block', 'cancel', 'complete', 'get-budget', 'start-attempt', 'set-budget', 'planner-turn', 'watchdog-interrupt', 'watchdog-settle', 'check-duplicate', 'bind-session', 'rebind-session', 'detach-session', 'get-bindings', 'model-attempt', 'model-proof', 'model-select')
if ($validActions -cnotcontains $action) {
    Write-TaskKernelCliError 'Uso: task-kernel.ps1 -Action create|get|status|transition|record-result|verify|review|review-schema|block|cancel|complete|get-budget|start-attempt|set-budget|planner-turn|watchdog-interrupt|watchdog-settle|check-duplicate ...'
    exit 2
}

function Assert-TaskKernelRevision {
    if ($script:ExpectedRevision -lt 0) {
        Write-TaskKernelCliError 'Esta acao exige -ExpectedRevision >= 0 (CAS).'
        exit 2
    }
}

function Test-TaskKernelCliTrustedPath {
    param([string]$Provided, [string]$Canonical)
    if ([string]::IsNullOrWhiteSpace($Provided)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Canonical)) { return $false }
    try {
        $a = [IO.Path]::GetFullPath((([string]$Provided).Trim())).TrimEnd('\', '/')
        $b = [IO.Path]::GetFullPath((([string]$Canonical).Trim())).TrimEnd('\', '/')
        if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
        return ([string]$a).Equals([string]$b, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-TaskKernelCliCanonicalRoot {
    try { return (Get-TaskKernelRepoRoot -RepoRoot '') }
    catch { return '' }
}

function Convert-TaskKernelPassed {
    param([string]$Text)
    $s = ([string]$Text).Trim().ToLowerInvariant()
    if (($s -ceq 'true') -or ($s -ceq '1') -or ($s -ceq 'yes')) { return @{ valid = $true; value = $true } }
    if (($s -ceq 'false') -or ($s -ceq '0') -or ($s -ceq 'no')) { return @{ valid = $true; value = $false } }
    return @{ valid = $false; value = $false }
}

function Convert-TaskKernelBudgetInt {
    <#
    .SYNOPSIS
        Strict canonical-decimal parser for CLI budget/sequence inputs.
        Accepts [int]/[long] in [Min, Max], or a STRING of 1-10 ASCII
        digits parsed via [long]::TryParse (invariant culture, no styles)
        so over-long inputs can never overflow: length is capped by the
        regex, conversion is TryParse-guarded, and the caller's Min/Max
        bounds the value ('2147483648' fails Max; '1000000'/'2147483647'
        pass when Max allows). Rejects bool/float/decimal/non-strings,
        blanks, signs, fractions and 11+ digit strings. Never throws.
    #>
    param($Raw, [int]$Min = 1, [int]$Max = 86400)
    try {
        if ($null -eq $Raw) { return @{ valid = $false; value = 0 } }
        if ($Raw -is [bool]) { return @{ valid = $false; value = 0 } }
        if ($Raw -is [double] -or $Raw -is [single] -or $Raw -is [decimal]) { return @{ valid = $false; value = 0 } }
        if ($Raw -is [int] -or $Raw -is [long]) {
            $n = [long]$Raw
            if (($n -ge [long]$Min) -and ($n -le [long]$Max)) { return @{ valid = $true; value = [int]$n } }
            return @{ valid = $false; value = 0 }
        }
        if (-not ($Raw -is [string])) { return @{ valid = $false; value = 0 } }
        $s = ([string]$Raw).Trim()
        if ($s -cnotmatch '^[0-9]{1,10}$') { return @{ valid = $false; value = 0 } }
        $n = [long]0
        $parsed = [long]::TryParse($s, [System.Globalization.NumberStyles]::None, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
        if (-not $parsed) { return @{ valid = $false; value = 0 } }
        if (($n -ge [long]$Min) -and ($n -le [long]$Max)) { return @{ valid = $true; value = [int]$n } }
        return @{ valid = $false; value = 0 }
    }
    catch { return @{ valid = $false; value = 0 } }
}

$result = $null
switch ($action) {
    'review-schema' {
        $hasReviewSchemaArgs = (-not [string]::IsNullOrWhiteSpace($TaskId)) -or
            (($PSBoundParameters.ContainsKey('ExpectedRevision')) -and ([int]$ExpectedRevision -ne 0)) -or
            (-not [string]::IsNullOrWhiteSpace($ReviewKind)) -or
            (-not [string]::IsNullOrWhiteSpace($ReviewStatus)) -or
            (-not [string]::IsNullOrWhiteSpace($ReviewBy)) -or
            (-not [string]::IsNullOrWhiteSpace($FindingsFile)) -or
            (-not [string]::IsNullOrWhiteSpace($FindingsJson))
        if ($hasReviewSchemaArgs) {
            Write-TaskKernelCliError 'review-schema nao aceita -TaskId, -ExpectedRevision diferente de 0, -ReviewKind, -ReviewStatus, -ReviewBy, -FindingsFile ou -FindingsJson.'
            exit 2
        }
        . (Join-Path $v3root 'lib\OrchestrationReviewAnchor.ps1')
        $reviewSchema = Get-OrchestrationReviewFindingsSchema
        Write-Output (ConvertTo-Json -InputObject $reviewSchema -Depth 8)
        exit 0
    }
    'create' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Objective)) {
            Write-TaskKernelCliError 'create exige -TaskId e -Objective.'
            exit 2
        }
        $tt = $TaskType
        if ([string]::IsNullOrWhiteSpace($tt)) { $tt = 'implementation' }
        $rk = $Risk
        if ([string]::IsNullOrWhiteSpace($rk)) { $rk = 'medium' }
        $rid = $RuntimeId
        if ([string]::IsNullOrWhiteSpace($rid)) { $rid = 'opencode-v1' }
        $rprof = $RuntimeProfile
        if ([string]::IsNullOrWhiteSpace($rprof)) {
            if ([int]$RuntimeGeneration -eq 2) { $rprof = 'v2' } else { $rprof = 'v1' }
        }
        $abConv = Convert-TaskKernelBudgetInt -Raw $AttemptBudget -Min 1 -Max 100
        if (-not [bool]$abConv.valid) {
            Write-TaskKernelCliError 'create: -AttemptBudget exige decimal canonico 1..100.'
            exit 2
        }
        $result = New-OrchestrationTask -TaskId $TaskId -Objective $Objective -TaskType $tt -Risk $rk `
            -ParentTaskId $ParentTaskId -TraceId $TraceId -OrchestrationDecision $OrchestrationDecision -Project $Project -RequireTypedWaits:$RequireTypedWaits -Actor $Actor `
            -RuntimeId $rid -RuntimeGeneration ([int]$RuntimeGeneration) -RuntimeProfile $rprof -RuntimeVersion $RuntimeVersion `
            -BaseRevision $BaseRevision -ReadScopes (Split-TaskKernelCliList -Value $ReadScopes) `
            -WriteScopes (Split-TaskKernelCliList -Value $WriteScopes) -Grants (Split-TaskKernelCliList -Value $Grants) `
            -AcceptanceCriteria (Split-TaskKernelCliList -Value $AcceptanceCriteria) `
            -ExpectedArtifacts (Split-TaskKernelCliList -Value $ExpectedArtifacts) `
            -VerificationProfiles (Split-TaskKernelCliList -Value $VerifierProfiles) `
            -EnvironmentAllowed (Split-TaskKernelCliList -Value $EnvironmentAllowed) `
            -ProductionAuthorized ([bool]$ProductionAuthorized) -AttemptBudget ([int]$abConv.value) `
            -BudgetProfile $BudgetProfile -BudgetPolicyPath $BudgetPolicyPath `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'check-duplicate' {
        if ([string]::IsNullOrWhiteSpace($Objective)) {
            Write-TaskKernelCliError 'check-duplicate exige -Objective (consulta somente-leitura, nada cria).'
            exit 2
        }
        $fpSlot = Get-OrchestrationWorkFingerprint -Objective $Objective `
            -Scope ((Split-TaskKernelCliList -Value $ReadScopes) + (Split-TaskKernelCliList -Value $WriteScopes)) `
            -DefinitionOfDone (Split-TaskKernelCliList -Value $AcceptanceCriteria) -Project $Project
        if (-not [bool]$fpSlot.ok) {
            Write-TaskKernelCliError ('check-duplicate: ' + [string]$fpSlot.error)
            exit 2
        }
        $dup = Get-OrchestrationDuplicateWork -WorkFingerprint ([string]$fpSlot.fingerprint) -TasksDir $TasksDir
        $result = [PSCustomObject]@{ ok = $true; duplicate = [bool]$dup.found; existing_task_id = ([string]$dup.existing_task_id); work_fingerprint = ([string]$fpSlot.fingerprint) }
    }
    { $_ -in @('bind-session','rebind-session','detach-session') } {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($SessionId) -or ([string]::IsNullOrWhiteSpace($RunId) -and $action -ne 'detach-session')) { Write-TaskKernelCliError 'binding exige -TaskId -SessionId e -RunId (exceto detach-session, que o resolve se unico).'; exit 1 }
        if ($ExpectedRevision -lt 0) { Write-TaskKernelCliError 'binding exige -ExpectedRevision.'; exit 1 }
        $op='bind'; if($action -eq 'rebind-session'){$op='rebind'} elseif($action -eq 'detach-session'){$op='detach'}
        if ($op -eq 'detach' -and [string]::IsNullOrWhiteSpace($RunId)) {
            $boundTask=Get-OrchestrationTask -TaskId $TaskId -TasksDir $TasksDir
            if ($null -eq $boundTask -or $boundTask.PSObject.Properties['error']) { $result=$boundTask }
            else {
                $runs=@($boundTask['bindings']['runs']); $matches=@()
                foreach($candidate in $runs) {
                    if ([string]$candidate['status'] -ne 'attached') { continue }
                    if (([string]$candidate['root_session'] -ceq $SessionId) -or (@($candidate['worker_sessions']) -ccontains $SessionId)) { $matches+=,[string]$candidate['run_id'] }
                }
                if($matches.Count -eq 0) {
                    foreach($candidate in $runs) {
                        if ([string]$candidate['status'] -ne 'detached') { continue }
                        if (([string]$candidate['root_session'] -ceq $SessionId) -or (@($candidate['worker_sessions']) -ccontains $SessionId)) { $matches+=,[string]$candidate['run_id'] }
                    }
                }
                if($matches.Count -ne 1){$result=New-TaskKernelError -Code 'BIND_RUN_AMBIGUOUS' -Extra @{matches=$matches.Count;detail='RunId required when session does not resolve to exactly one run (including detached runs)'}}
                else{$RunId=[string]$matches[0]}
            }
        }
        if ($null -ne $result -and (Get-TaskKernelResultError -Result $result)) { break }
        $bindingArgs=@{Operation=$op;TaskId=$TaskId;RunId=$RunId;SessionId=$SessionId;ExpectedRevision=$ExpectedRevision;TasksDir=$TasksDir;FlagsPath=$FlagsPath;SeatId=$SeatId;Runtime=$BindingRuntime;Version=$BindingVersion;ParentId=$ParentSessionId;RootId=$RootSessionId;WorkerSession=[bool]$WorkerSession}
        $result=Invoke-OrchestrationTaskSessionBinding @bindingArgs
    }
    'get-bindings' { if([string]::IsNullOrWhiteSpace($TaskId)){Write-TaskKernelCliError 'get-bindings exige -TaskId.';exit 1};$result=Get-OrchestrationTaskBindings -TaskId $TaskId -TasksDir $TasksDir }
    'get' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'get exige -TaskId.'
            exit 2
        }
        $result = Get-OrchestrationTask -TaskId $TaskId -TasksDir $TasksDir
    }
    'status' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'status exige -TaskId.'
            exit 2
        }
        $result = Get-OrchestrationTaskStatus -TaskId $TaskId -TasksDir $TasksDir
    }
    'transition' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($ToState) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'transition exige -TaskId -ToState -Actor -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $result = Invoke-OrchestrationTaskTransition -TaskId $TaskId -ToState $ToState -Actor $Actor `
            -ExpectedRevision ([int]$ExpectedRevision) -Reason $Reason -ActorIdentitySource $ids `
            -WaitType $WaitType -WaitOwner $WaitOwner -WaitAction $WaitAction -WaitDependencyId $WaitDependencyId `
            -WaitFingerprint $WaitFingerprint -UnblockAction $UnblockAction `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'record-result' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($WorkerStatus) -or [string]::IsNullOrWhiteSpace($ProducedBy)) {
            Write-TaskKernelCliError 'record-result exige -TaskId -WorkerStatus candidate_pass|failed|blocked -ProducedBy -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Set-OrchestrationTaskWorkerResult -TaskId $TaskId -Status $WorkerStatus `
            -ClaimedEvidence (Split-TaskKernelCliList -Value $ClaimedEvidence) -ProducedBy $ProducedBy `
            -ExpectedRevision ([int]$ExpectedRevision) -Hypothesis $Hypothesis -NewEvidence:$NewEvidence `
            -DebuggerInvoked:$DebuggerInvoked `
            -StrategyId $StrategyId -StrategyApproach $StrategyApproach -StrategyTool $StrategyTool `
            -StrategyParams (Split-TaskKernelCliList -Value $StrategyParams) -StrategyFingerprint $StrategyFingerprint `
            -FailureClass $FailureClass -FailureDetail $FailureDetail -RecoverySource $RecoverySource `
            -NewEvidenceRefs (Split-TaskKernelCliList -Value $NewEvidenceRefs) `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'verify' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'verify exige -TaskId -VerifierResultFile <caminho> (ou -VerifierResultJson) -ExpectedRevision.'
            exit 2
        }
        if ($PSBoundParameters.ContainsKey('Passed')) {
            Write-TaskKernelCliError 'verify nao aceita -Passed: use -VerifierResultFile (saida do verifier).'
            exit 2
        }
        Assert-TaskKernelRevision
        $vtext = $VerifierResultJson
        if (-not [string]::IsNullOrWhiteSpace($VerifierResultFile)) {
            if (-not (Test-Path -LiteralPath $VerifierResultFile -PathType Leaf)) {
                Write-TaskKernelCliError 'verify: arquivo de resultado do verifier nao encontrado.'
                exit 2
            }
            try { $vtext = [IO.File]::ReadAllText($VerifierResultFile, [Text.UTF8Encoding]::new($false)) }
            catch {
                Write-TaskKernelCliError 'verify: falha ao ler o arquivo de resultado do verifier.'
                exit 2
            }
        }
        if ([string]::IsNullOrWhiteSpace($vtext)) {
            Write-TaskKernelCliError 'verify exige -VerifierResultFile <caminho> (ou -VerifierResultJson).'
            exit 2
        }
        $result = Set-OrchestrationTaskVerification -TaskId $TaskId -VerifierEvidenceJson $vtext `
            -ExpectedRevision ([int]$ExpectedRevision) -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'verify-run' {
        $canonRootVr = Get-TaskKernelCliCanonicalRoot
        $canonTasksVr = ''; $canonFlagsVr = ''
        try { $canonTasksVr = Get-TaskKernelDefaultTasksDir -RepoRoot '' } catch { $canonTasksVr = '' }
        try { $canonFlagsVr = Get-TaskKernelDefaultFlagsPath -RepoRoot '' } catch { $canonFlagsVr = '' }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $CliRepoRoot -Canonical $canonRootVr)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'repo_root'; action = 'verify-run' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $TasksDir -Canonical $canonTasksVr)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'tasks_dir'; action = 'verify-run' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $FlagsPath -Canonical $canonFlagsVr)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'flags_path'; action = 'verify-run' }; break }
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'verify-run exige -TaskId -ExpectedRevision (usa o plano verification_profiles do task + repo/policy do -CliRepoRoot).'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Invoke-TaskKernelVerifyRun -TaskId $TaskId -ExpectedRevision ([int]$ExpectedRevision) `
            -TasksDir $canonTasksVr -FlagsPath $canonFlagsVr -RepoRoot $canonRootVr
    }
    'review' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($ReviewKind) -or [string]::IsNullOrWhiteSpace($ReviewStatus) -or [string]::IsNullOrWhiteSpace($ReviewBy)) {
            Write-TaskKernelCliError 'review exige -TaskId -ReviewKind reviewer|security -ReviewStatus approved|changes_required -ReviewBy -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        if ((-not [string]::IsNullOrWhiteSpace($FindingsFile)) -and (-not [string]::IsNullOrWhiteSpace($FindingsJson))) {
            Write-TaskKernelCliError 'review aceita -FindingsFile OU -FindingsJson, nunca ambos.'
            exit 2
        }
        $reviewFindings = $FindingsJson
        if (-not [string]::IsNullOrWhiteSpace($FindingsFile)) {
            if (-not (Test-Path -LiteralPath $FindingsFile -PathType Leaf)) {
                Write-TaskKernelCliError 'review: arquivo de findings nao encontrado.'
                exit 2
            }
            try { $reviewFindings = [IO.File]::ReadAllText($FindingsFile, [Text.UTF8Encoding]::new($false)) }
            catch {
                Write-TaskKernelCliError 'review: falha ao ler o arquivo de findings.'
                exit 2
            }
        }
        $result = Set-OrchestrationTaskReview -TaskId $TaskId -Kind $ReviewKind -Status $ReviewStatus -By $ReviewBy `
            -ExpectedRevision ([int]$ExpectedRevision) -FindingsJson $reviewFindings -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'event-attach' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'event-attach exige -TaskId -ExpectedRevision e -EnvelopeFile ou -EnvelopeJson.'
            exit 2
        }
        Assert-TaskKernelRevision
        if ((-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) -and (-not [string]::IsNullOrWhiteSpace($EnvelopeJson))) {
            Write-TaskKernelCliError 'event-attach aceita -EnvelopeFile OU -EnvelopeJson, nunca ambos.'
            exit 2
        }
        $envText = $EnvelopeJson
        if (-not [string]::IsNullOrWhiteSpace($EnvelopeFile)) {
            if (-not (Test-Path -LiteralPath $EnvelopeFile -PathType Leaf)) {
                Write-TaskKernelCliError 'event-attach: arquivo de envelope nao encontrado.'
                exit 2
            }
            $envInfo = Get-Item -LiteralPath $EnvelopeFile
            if ([int64]$envInfo.Length -gt 65536) {
                Write-TaskKernelCliError 'event-attach: envelope acima do limite.'
                exit 2
            }
            try { $envText = [IO.File]::ReadAllText($EnvelopeFile, [Text.UTF8Encoding]::new($false)) }
            catch {
                Write-TaskKernelCliError 'event-attach: falha ao ler o envelope.'
                exit 2
            }
        }
        if ([string]::IsNullOrWhiteSpace($envText)) {
            Write-TaskKernelCliError 'event-attach exige -EnvelopeFile ou -EnvelopeJson.'
            exit 2
        }
        $result = Add-OrchestrationTaskEvent -TaskId $TaskId -EnvelopeJson $envText -ExpectedRevision ([int]$ExpectedRevision) `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'event-ack' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($DedupKey) -or [string]::IsNullOrWhiteSpace($SessionId)) {
            Write-TaskKernelCliError 'event-ack exige -TaskId -DedupKey -SessionId -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Confirm-OrchestrationTaskEvent -TaskId $TaskId -DedupKey $DedupKey -SessionId $SessionId `
            -ResponseSummary $ResponseSummary -ExpectedRevision ([int]$ExpectedRevision) `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'block' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor) -or [string]::IsNullOrWhiteSpace($Reason)) {
            Write-TaskKernelCliError 'block exige -TaskId -Actor -Reason -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Block-OrchestrationTask -TaskId $TaskId -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) `
            -Reason $Reason -WaitType $WaitType -WaitOwner $WaitOwner -WaitAction $WaitAction -WaitDependencyId $WaitDependencyId `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'cancel' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor) -or [string]::IsNullOrWhiteSpace($Reason)) {
            Write-TaskKernelCliError 'cancel exige -TaskId -Actor -Reason -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $result = Cancel-OrchestrationTask -TaskId $TaskId -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) `
            -Reason $Reason -ActorIdentitySource $ids -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'complete' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'complete exige -TaskId -Actor -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $completeArgs = @{
            TaskId = $TaskId; Actor = $Actor; ExpectedRevision = ([int]$ExpectedRevision)
            ResidualRisks = (Split-TaskKernelCliList -Value $ResidualRisks)
            OrchestrationCompliance = $OrchestrationCompliance; ActorIdentitySource = $ids
            TasksDir = $TasksDir; FlagsPath = $FlagsPath
        }
        if ([bool]$AcceptEmptyResidualRisks) { $completeArgs['AcceptEmptyResidualRisks'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($LeasesDir)) { $completeArgs['LeasesDir'] = $LeasesDir }
        if (-not [string]::IsNullOrWhiteSpace($CurrentBaseRevision)) { $completeArgs['CurrentBaseRevision'] = $CurrentBaseRevision }
        $result = Complete-OrchestrationTask @completeArgs
    }
    'get-budget' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Write-TaskKernelCliError 'get-budget exige -TaskId.'
            exit 2
        }
        $result = Get-OrchestrationTaskBudget -TaskId $TaskId -TasksDir $TasksDir -BudgetPolicyPath $BudgetPolicyPath
    }
    'start-attempt' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($AttemptRole) -or [string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'start-attempt exige -TaskId -AttemptRole -SessionId -Actor -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $saArgs = @{
            TaskId = $TaskId; AttemptRole = $AttemptRole; SessionId = $SessionId
            Actor = $Actor; ExpectedRevision = ([int]$ExpectedRevision); ActorIdentitySource = $ids
            BudgetPolicyPath = $BudgetPolicyPath; TasksDir = $TasksDir; FlagsPath = $FlagsPath
            StrategyId = $StrategyId; StrategyApproach = $StrategyApproach; StrategyTool = $StrategyTool
            StrategyFingerprint = $StrategyFingerprint; AttemptHypothesis = $AttemptHypothesis
        }
        if (-not [string]::IsNullOrWhiteSpace(([string]($StrategyParams -join '')).Trim())) {
            $saArgs['StrategyParams'] = (Split-TaskKernelCliList -Value $StrategyParams)
        }
        foreach ($rk in @('DebuggerEvidenceRefs', 'NewEvidenceRefs')) {
            if ($PSBoundParameters.ContainsKey($rk)) {
                $boundVal = $PSBoundParameters[$rk]
                $refList = New-Object System.Collections.Generic.List[string]
                $items = @()
                if ($null -ne $boundVal) { $items = @($boundVal) }
                foreach ($e in @($items)) {
                    if (-not ($e -is [string]) -or [string]::IsNullOrWhiteSpace([string]$e)) {
                        Write-TaskKernelCliError ('start-attempt: -{0} exige array de strings nao-vazias.' -f $rk)
                        exit 2
                    }
                    $refList.Add([string]$e) | Out-Null
                }
                $saArgs[$rk] = [string[]]$refList.ToArray()
            }
        }
        $result = Start-OrchestrationTaskAttempt @saArgs
    }
    'set-budget' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'set-budget exige -TaskId -Actor -ExpectedRevision (override e planner/kernel only).'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $sbArgs = @{
            TaskId = $TaskId; Actor = $Actor; ExpectedRevision = ([int]$ExpectedRevision); ActorIdentitySource = $ids
            BudgetPolicyPath = $BudgetPolicyPath; TasksDir = $TasksDir; FlagsPath = $FlagsPath
        }
        if ($PSBoundParameters.ContainsKey('BudgetProfile') -and (-not [string]::IsNullOrWhiteSpace($BudgetProfile))) {
            $sbArgs['BudgetProfile'] = $BudgetProfile
        }
        foreach ($bk in @('BudgetStepBudget', 'BudgetWallSeconds', 'BudgetNoProgressSeconds')) {
            if ($PSBoundParameters.ContainsKey($bk)) {
                $raw = (Get-Variable -Name $bk -ValueOnly)
                $conv = Convert-TaskKernelBudgetInt -Raw $raw -Min 1 -Max 86400
                if (-not [bool]$conv.valid) {
                    Write-TaskKernelCliError ('set-budget: -{0} exige decimal canonico 1..86400 (sem sinal, sem fracao).' -f $bk)
                    exit 2
                }
                $sbArgs[$bk] = [int]$conv.value
            }
        }
        $result = Set-OrchestrationTaskBudget @sbArgs
    }
    'planner-turn' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($PlannerTurnId) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'planner-turn exige -TaskId -PlannerTurnId -UserInputSignal -UserInputSequence -Actor -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        if (-not $PSBoundParameters.ContainsKey('UserInputSequence')) {
            Write-TaskKernelCliError 'planner-turn exige -UserInputSequence decimal canonico >= 1 e crescente por task.'
            exit 2
        }
        $seqConv = Convert-TaskKernelBudgetInt -Raw $UserInputSequence -Min 1 -Max 2147483647
        if (-not [bool]$seqConv.valid) {
            Write-TaskKernelCliError 'planner-turn: -UserInputSequence exige decimal canonico 1..2147483647 (sem sinal, sem fracao).'
            exit 2
        }
        $result = Start-OrchestrationPlannerTurn -TaskId $TaskId -TurnId $PlannerTurnId -UserInputSignal $UserInputSignal -UserInputSequence ([int]$seqConv.value) `
            -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) -ActorIdentitySource $ids `
            -BudgetPolicyPath $BudgetPolicyPath -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'watchdog-interrupt' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor) -or [string]::IsNullOrWhiteSpace($WatchdogClass)) {
            Write-TaskKernelCliError 'watchdog-interrupt exige -TaskId -Actor -ExpectedRevision -WatchdogAttemptN -WatchdogClass HARD_TIMEOUT|NO_PROGRESS|REPEATED_ACTION|REPEATED_CYCLE.'
            exit 2
        }
        Assert-TaskKernelRevision
        if (-not $PSBoundParameters.ContainsKey('WatchdogAttemptN')) {
            Write-TaskKernelCliError 'watchdog-interrupt exige -WatchdogAttemptN decimal canonico 1..1000000.'
            exit 2
        }
        $wdConv = Convert-TaskKernelBudgetInt -Raw $WatchdogAttemptN -Min 1 -Max 1000000
        if (-not [bool]$wdConv.valid) {
            Write-TaskKernelCliError 'watchdog-interrupt: -WatchdogAttemptN exige decimal canonico 1..1000000 (sem sinal, sem fracao).'
            exit 2
        }
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $result = Set-OrchestrationTaskWatchdogInterrupt -TaskId $TaskId -AttemptN ([int]$wdConv.value) -Class $WatchdogClass `
            -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) -TelemetryFile $WatchdogTelemetryFile -ActorIdentitySource $ids `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'watchdog-settle' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor)) {
            Write-TaskKernelCliError 'watchdog-settle exige -TaskId -Actor -ExpectedRevision (idempotente).'
            exit 2
        }
        Assert-TaskKernelRevision
        $ids = $ActorIdentitySource
        if ([string]::IsNullOrWhiteSpace($ids)) { $ids = 'unknown' }
        $dispArgs = @{}
        if ($PSBoundParameters.ContainsKey('WatchdogDisposition') -and (-not [string]::IsNullOrWhiteSpace($WatchdogDisposition))) {
            $dispNorm = ([string]$WatchdogDisposition).Trim().ToUpperInvariant()
            if (($dispNorm -cne 'RETRY') -and ($dispNorm -cne 'CLOSE')) {
                Write-TaskKernelCliError 'watchdog-settle: -WatchdogDisposition exige RETRY|CLOSE.'
                exit 2
            }
            $dispArgs['Disposition'] = $dispNorm
        }
        $result = Confirm-OrchestrationTaskWatchdogSettlement -TaskId $TaskId `
            -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) -ActorIdentitySource $ids `
            -TasksDir $TasksDir -FlagsPath $FlagsPath @dispArgs
    }
    'model-attempt' {
        $canonRootMa = Get-TaskKernelCliCanonicalRoot
        $canonTasksMa = ''; $canonFlagsMa = ''; $canonPolMa = ''
        try { $canonTasksMa = Get-TaskKernelDefaultTasksDir -RepoRoot '' } catch { $canonTasksMa = '' }
        try { $canonFlagsMa = Get-TaskKernelDefaultFlagsPath -RepoRoot '' } catch { $canonFlagsMa = '' }
        try { $canonPolMa = Get-TaskKernelModelPolicyDefaultPath -RepoRoot '' } catch { $canonPolMa = '' }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $CliRepoRoot -Canonical $canonRootMa)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'repo_root'; action = 'model-attempt' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $TasksDir -Canonical $canonTasksMa)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'tasks_dir'; action = 'model-attempt' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $FlagsPath -Canonical $canonFlagsMa)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'flags_path'; action = 'model-attempt' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $PolicyPath -Canonical $canonPolMa)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'model_policy'; action = 'model-attempt' }; break }
        $child = $ChildSessionId
        if ([string]::IsNullOrWhiteSpace($child)) { $child = $SessionId }
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($child)) {
            Write-TaskKernelCliError 'model-attempt exige -TaskId -SessionId <child> (ou -ChildSessionId) -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Set-OrchestrationTaskModelAttempt -TaskId $TaskId -ChildSessionId $child `
            -ExpectedRevision ([int]$ExpectedRevision) -TasksDir $canonTasksMa -FlagsPath $canonFlagsMa `
            -RepoRoot $canonRootMa -PolicyPath $canonPolMa
    }
    'model-proof' {
        $canonRootMp = Get-TaskKernelCliCanonicalRoot
        $canonTasksMp = ''; $canonFlagsMp = ''; $canonPolMp = ''
        try { $canonTasksMp = Get-TaskKernelDefaultTasksDir -RepoRoot '' } catch { $canonTasksMp = '' }
        try { $canonFlagsMp = Get-TaskKernelDefaultFlagsPath -RepoRoot '' } catch { $canonFlagsMp = '' }
        try { $canonPolMp = Get-TaskKernelModelPolicyDefaultPath -RepoRoot '' } catch { $canonPolMp = '' }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $CliRepoRoot -Canonical $canonRootMp)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'repo_root'; action = 'model-proof' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $TasksDir -Canonical $canonTasksMp)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'tasks_dir'; action = 'model-proof' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $FlagsPath -Canonical $canonFlagsMp)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'flags_path'; action = 'model-proof' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $PolicyPath -Canonical $canonPolMp)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'model_policy'; action = 'model-proof' }; break }
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($RequiredTier)) {
            Write-TaskKernelCliError 'model-proof exige -TaskId -RequiredTier T3|T4.'
            exit 2
        }
        $rt = ([string]$RequiredTier).Trim().ToUpperInvariant()
        if (($rt -cne 'T3') -and ($rt -cne 'T4')) {
            Write-TaskKernelCliError 'model-proof: -RequiredTier exige T3|T4.'
            exit 2
        }
        $result = Get-OrchestrationTaskModelFailureProof -TaskId $TaskId -RequiredTier $rt `
            -TasksDir $canonTasksMp -RepoRoot $canonRootMp -PolicyPath $canonPolMp
    }
    'model-select' {
        $canonRootMs = Get-TaskKernelCliCanonicalRoot
        $canonTasksMs = ''; $canonFlagsMs = ''; $canonPolMs = ''
        try { $canonTasksMs = Get-TaskKernelDefaultTasksDir -RepoRoot '' } catch { $canonTasksMs = '' }
        try { $canonFlagsMs = Get-TaskKernelDefaultFlagsPath -RepoRoot '' } catch { $canonFlagsMs = '' }
        try { $canonPolMs = Get-TaskKernelModelPolicyDefaultPath -RepoRoot '' } catch { $canonPolMs = '' }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $CliRepoRoot -Canonical $canonRootMs)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'repo_root'; action = 'model-select' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $TasksDir -Canonical $canonTasksMs)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'tasks_dir'; action = 'model-select' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $FlagsPath -Canonical $canonFlagsMs)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'flags_path'; action = 'model-select' }; break }
        if (-not (Test-TaskKernelCliTrustedPath -Provided $PolicyPath -Canonical $canonPolMs)) { $result = New-TaskKernelError -Code 'TRUSTED_PATH_MISMATCH' -Extra @{ path_role = 'model_policy'; action = 'model-select' }; break }
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($AttemptRole)) {
            Write-TaskKernelCliError 'model-select exige -TaskId -AttemptRole <role> (somente leitura, sem dispatch).'
            exit 2
        }
        $roleSel = ([string]$AttemptRole).Trim().ToLowerInvariant()
        $riskSel = ([string]$Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($riskSel)) { $riskSel = 'medium' }
        $complexSel = ([string]$ModelComplexity).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($complexSel)) { $complexSel = 'medium' }
        $reqLlmSel = [bool]$RequiresLlm
        $typeSel = ([string]$TaskType).Trim()
        $taskRec = Get-OrchestrationTask -TaskId $TaskId -TasksDir $canonTasksMs -RepoRoot $canonRootMs
        if ($null -ne $taskRec -and ($taskRec -is [System.Collections.IDictionary] -or $null -ne $taskRec.PSObject)) {
            $errProbe = ''
            try {
                if ($taskRec -is [System.Collections.IDictionary]) { if ($taskRec.Contains('error')) { $errProbe = [string]$taskRec['error'] } }
                else { $pp = $taskRec.PSObject.Properties['error']; if ($null -ne $pp) { $errProbe = [string]$pp.Value } }
            } catch { $errProbe = '' }
            if (-not [string]::IsNullOrWhiteSpace($errProbe)) { $result = $taskRec; break }
        }
        $routerLibMs = (Join-Path $v3root 'lib\OrchestrationModelRouter.ps1')
        if (-not (Test-Path -LiteralPath $routerLibMs -PathType Leaf)) { $result = New-TaskKernelError -Code 'MODEL_ROUTER_LOAD_FAILED'; break }
        try { . $routerLibMs } catch { $result = New-TaskKernelError -Code 'MODEL_ROUTER_LOAD_FAILED'; break }
        # Live-server-only capability: task runtime profile/version is caller
        # metadata persisted for observability and NEVER authorizes the
        # subagent.model override. Proven only when the CURRENT live local
        # OpenCode server version (bounded /api/info read) is exactly in the
        # canonical supported allowlist. Same-server assumption documented in
        # the helper and operations guide.
        $nativeProof = @{ ok = $false; reason = 'INFO_UNAVAILABLE'; live_version = '' }
        try { $nativeProof = Test-OrchestrationNativeModelOverrideProof } catch { $nativeProof = @{ ok = $false; reason = 'INFO_UNAVAILABLE'; live_version = '' } }
        $nativeProven = [bool]$nativeProof.ok
        $nativeReason = [string]$nativeProof.reason
        $sel = $null
        try {
            $sel = Resolve-OrchestrationModelSelection -AgentName $roleSel -TaskId $TaskId -TasksDir $canonTasksMs -RepoRoot $canonRootMs -PolicyPath $canonPolMs -Risk $riskSel -Complexity $complexSel -TaskType $typeSel -RequiresLlm:$reqLlmSel -IgnoreUserConfig $true -NativeModelOverrideProven $nativeProven
        } catch { $result = New-TaskKernelError -Code 'MODEL_SELECTION_FAILED'; break }
        if ($null -eq $sel) { $result = New-TaskKernelError -Code 'MODEL_SELECTION_FAILED'; break }
        $refOut = ''; $dgOut = ''
        try { if ($null -ne $sel.PSObject.Properties['KernelProofReference']) { $refOut = [string]$sel.KernelProofReference } } catch { }
        try { if ($null -ne $sel.PSObject.Properties['KernelProofDigest']) { $dgOut = [string]$sel.KernelProofDigest } } catch { }
        $modelOut = ''
        $subModelOut = ''
        if ($nativeProven) { $modelOut = [string]$sel.CatalogModel; $subModelOut = [string]$sel.CatalogModel }
        $fbTokOut = ''; $fbTierOut = ''
        try { $fbTokOut = [string]$sel.FallbackToken } catch { }
        try { $fbTierOut = [string]$sel.FallbackTier } catch { }
        $plFallbackModel = ''; $plFallbackProvider = ''
        if ($roleSel -ceq 'build') {
            try {
                $polFb = Get-OrchestrationModelRoutingPolicy -PolicyPath $canonPolMs
                if ($polFb.Status -eq 'POLICY_LOADED' -and $null -ne $polFb.Policy.planner) {
                    if ($null -ne $polFb.Policy.planner.fallback_model_id) { $plFallbackModel = [string]$polFb.Policy.planner.fallback_model_id }
                    if ($null -ne $polFb.Policy.planner.fallback_provider) { $plFallbackProvider = [string]$polFb.Policy.planner.fallback_provider }
                }
            } catch { $plFallbackModel = ''; $plFallbackProvider = '' }
        }
        $result = [PSCustomObject]@{
            ok = ([string]$sel.Status -ceq 'SELECTED')
            task_id = ([string]$TaskId).Trim()
            role = $roleSel
            tier = [string]$sel.Tier
            model = $modelOut
            subagent_model = $subModelOut
            subagent_model_usage = 'OMIT subagent.model unless model_override_proven=true; use host template when false'
            provider = [string]$sel.selected_provider
            policy_hash = [string]$sel.policy_hash
            policy_version = [string]$sel.policy_version
            native_model_override_proven = $nativeProven
            model_override_proven = $nativeProven
            native_proof_reason = $nativeReason
            fallback_token = $fbTokOut
            fallback_tier = $fbTierOut
            planner_fallback_model = $plFallbackModel
            planner_fallback_provider = $plFallbackProvider
            kernel_proof_reference = $refOut
            kernel_proof_digest = $dgOut
            selection_reason = [string]$sel.SelectionReason
            no_dispatch = $true
        }
    }
}

$code = Get-TaskKernelExitCode -ErrorCode (Get-TaskKernelResultError -Result $result)
if ($action -in @('bind-session','rebind-session','detach-session') -and -not [string]::IsNullOrWhiteSpace((Get-TaskKernelResultError -Result $result))) {
    $code = 2
    if ((Get-TaskKernelResultError -Result $result) -eq 'BIND_INVALID_ID') { $code = 1 }
}
try {
    Write-Output ($result | ConvertTo-Json -Depth 12)
}
catch {
    Write-TaskKernelCliError 'task-kernel.ps1: falha ao serializar o resultado.'
    exit 1
}
exit $code
