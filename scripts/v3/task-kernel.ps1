<#!
.SYNOPSIS
    Task Kernel CLI: thin wrapper over lib/OrchestrationTaskKernel.ps1.
.DESCRIPTION
    Actions:
      create        - New-OrchestrationTask (needs -TaskId -Objective)
      get           - Get-OrchestrationTask (needs -TaskId)
      status        - Get-OrchestrationTaskStatus (needs -TaskId)
      transition    - Invoke-OrchestrationTaskTransition (needs -TaskId -ToState -Actor -ExpectedRevision)
      record-result - Set-OrchestrationTaskWorkerResult (needs -TaskId -WorkerStatus -ProducedBy -ExpectedRevision)
      verify        - Set-OrchestrationTaskVerification (needs -TaskId -VerifierResultFile|-VerifierResultJson -ExpectedRevision; never -Passed)
      review        - Set-OrchestrationTaskReview (needs -TaskId -ReviewKind reviewer|security -ReviewStatus approved|changes_required -ReviewBy -ExpectedRevision)
      block         - Block-OrchestrationTask (needs -TaskId -Actor -Reason -ExpectedRevision)
      cancel        - Cancel-OrchestrationTask (needs -TaskId -Actor -Reason -ExpectedRevision)
      complete      - Complete-OrchestrationTask (needs -TaskId -Actor -ExpectedRevision)
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
    [int]$AttemptBudget = 3,
    [string]$TasksDir = '',
    [string]$FlagsPath = '',
    [string]$LeasesDir = '',
    [string]$CurrentBaseRevision = ''
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
$validActions = @('create', 'get', 'status', 'transition', 'record-result', 'verify', 'review', 'block', 'cancel', 'complete')
if ($validActions -cnotcontains $action) {
    Write-TaskKernelCliError 'Uso: task-kernel.ps1 -Action create|get|status|transition|record-result|verify|review|block|cancel|complete ...'
    exit 2
}

function Assert-TaskKernelRevision {
    if ($script:ExpectedRevision -lt 0) {
        Write-TaskKernelCliError 'Esta acao exige -ExpectedRevision >= 0 (CAS).'
        exit 2
    }
}

function Convert-TaskKernelPassed {
    param([string]$Text)
    $s = ([string]$Text).Trim().ToLowerInvariant()
    if (($s -ceq 'true') -or ($s -ceq '1') -or ($s -ceq 'yes')) { return @{ valid = $true; value = $true } }
    if (($s -ceq 'false') -or ($s -ceq '0') -or ($s -ceq 'no')) { return @{ valid = $true; value = $false } }
    return @{ valid = $false; value = $false }
}

$result = $null
switch ($action) {
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
        $result = New-OrchestrationTask -TaskId $TaskId -Objective $Objective -TaskType $tt -Risk $rk `
            -ParentTaskId $ParentTaskId -TraceId $TraceId -OrchestrationDecision $OrchestrationDecision -Actor $Actor `
            -RuntimeId $rid -RuntimeGeneration ([int]$RuntimeGeneration) -RuntimeProfile $rprof -RuntimeVersion $RuntimeVersion `
            -BaseRevision $BaseRevision -ReadScopes (Split-TaskKernelCliList -Value $ReadScopes) `
            -WriteScopes (Split-TaskKernelCliList -Value $WriteScopes) -Grants (Split-TaskKernelCliList -Value $Grants) `
            -AcceptanceCriteria (Split-TaskKernelCliList -Value $AcceptanceCriteria) `
            -ExpectedArtifacts (Split-TaskKernelCliList -Value $ExpectedArtifacts) `
            -EnvironmentAllowed (Split-TaskKernelCliList -Value $EnvironmentAllowed) `
            -ProductionAuthorized ([bool]$ProductionAuthorized) -AttemptBudget ([int]$AttemptBudget) `
            -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
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
    'review' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($ReviewKind) -or [string]::IsNullOrWhiteSpace($ReviewStatus) -or [string]::IsNullOrWhiteSpace($ReviewBy)) {
            Write-TaskKernelCliError 'review exige -TaskId -ReviewKind reviewer|security -ReviewStatus approved|changes_required -ReviewBy -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Set-OrchestrationTaskReview -TaskId $TaskId -Kind $ReviewKind -Status $ReviewStatus -By $ReviewBy `
            -ExpectedRevision ([int]$ExpectedRevision) -TasksDir $TasksDir -FlagsPath $FlagsPath
    }
    'block' {
        if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Actor) -or [string]::IsNullOrWhiteSpace($Reason)) {
            Write-TaskKernelCliError 'block exige -TaskId -Actor -Reason -ExpectedRevision.'
            exit 2
        }
        Assert-TaskKernelRevision
        $result = Block-OrchestrationTask -TaskId $TaskId -Actor $Actor -ExpectedRevision ([int]$ExpectedRevision) `
            -Reason $Reason -TasksDir $TasksDir -FlagsPath $FlagsPath
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
}

$code = Get-TaskKernelExitCode -ErrorCode (Get-TaskKernelResultError -Result $result)
try {
    Write-Output ($result | ConvertTo-Json -Depth 12)
}
catch {
    Write-TaskKernelCliError 'task-kernel.ps1: falha ao serializar o resultado.'
    exit 1
}
exit $code
