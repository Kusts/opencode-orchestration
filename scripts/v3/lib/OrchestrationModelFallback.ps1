[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelAttempt.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
function Get-OrchestrationModelFallbackDecision {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][string]$AttemptRole,[string]$Risk='low',[string]$Complexity='simple',[Parameter(Mandatory=$true)][string]$FailedModel,[string[]]$AttemptedModels=@(),[Parameter(Mandatory=$true)]$Failure,[string]$SessionId='',[string]$ObservedModel='',[string]$PolicyPath='',[string]$EvidenceDir='',$AttemptEvidence=$null)
    $tool=$false
    if($Failure -is [string]){try{$parsed=ConvertFrom-Json $Failure -ErrorAction Stop;if($null -ne (Get-MAValue $parsed 'error' $null)){$Failure=ConvertFrom-OrchestrationToolError $parsed;$tool=$true}else{$Failure=ConvertFrom-OrchestrationProviderFailure $parsed -Stage pre_dispatch}}catch{$Failure=ConvertFrom-OrchestrationProviderFailure @{code='unknown result'} -Stage unknown}}
    elseif($null -ne (Get-MAValue $Failure 'Source' $null) -and (Get-MAValue $Failure 'Source' '') -ceq 'tool_error'){$tool=$true}
    elseif($null -ne (Get-MAValue $Failure 'error' $null)){$Failure=ConvertFrom-OrchestrationToolError $Failure;$tool=$true}
    else {$Failure=ConvertFrom-OrchestrationProviderFailure $Failure -Stage pre_dispatch}
    $class=[string](Get-MAValue $Failure 'Classification' 'NONE')
    $sessionFromError=[string](Get-MAValue $Failure 'SessionId' '')
    if(-not $SessionId){$SessionId=$sessionFromError}
    $ev=$AttemptEvidence
    if($tool -and $null -eq $ev){$ev=@{source='tool_error';stage='pre_dispatch';session_id=$SessionId;execution_started=$false;assistant_messages=0;tool_calls=0}}
    $validEvidence=$null -ne $ev -and [string](Get-MAValue $ev 'stage' '') -ceq 'pre_dispatch' -and [string]::IsNullOrWhiteSpace([string](Get-MAValue $ev 'session_id' '')) -and -not [bool](Get-MAValue $ev 'execution_started' $true) -and [int](Get-MAValue $ev 'assistant_messages' -1) -eq 0 -and [int](Get-MAValue $ev 'tool_calls' -1) -eq 0 -and (([string](Get-MAValue $ev 'source' '') -ceq 'tool_error' -and $tool) -or ([string](Get-MAValue $ev 'source' '') -in @('provider','dispatcher') -and $null -ne $AttemptEvidence))
    $noStart=[bool]((Get-MAValue $Failure 'Availability' $false) -and $validEvidence)
    $status='HOLD_TERMINAL';$next=$null;$tier=$null;$reason='FAILURE_NOT_ELIGIBLE'
    if(-not [string]::IsNullOrWhiteSpace($SessionId) -or ($null -ne $ev -and (-not [string]::IsNullOrWhiteSpace([string](Get-MAValue $ev 'session_id' '')) -or [bool](Get-MAValue $ev 'execution_started' $false)))){$status='HOLD_AMBIGUOUS_EXECUTION';$reason='EXECUTION_MAY_HAVE_STARTED'}
    elseif([string]::IsNullOrWhiteSpace($SessionId) -and [bool](Get-MAValue $Failure 'Availability' $false) -and $null -eq $AttemptEvidence -and -not $tool){$status='HOLD_NO_START_PROOF_UNVERIFIED';$reason='NO_START_PROOF_UNVERIFIED'}
    elseif($noStart){
        $selection=Resolve-OrchestrationModelSelection -AgentName $AttemptRole -TaskId $TaskId -Risk $Risk -Complexity $Complexity -PolicyPath $PolicyPath -IgnoreUserConfig $true
        $trigger=$class;if($trigger -eq 'PROVIDER_UNAVAILABLE'){$trigger='SERVICE_UNAVAILABLE'}
        $fb=Resolve-OrchestrationModelFallback -RequestedSelection $selection -FailedModel $FailedModel -TriggerReason $trigger -AttemptedModels $AttemptedModels -PolicyPath $PolicyPath -IgnoreUserConfig $true -NoExecutionStarted $true -TaskId $TaskId
        $candidate=[string](Get-MAValue $fb 'CandidateModel' (Get-MAValue $fb 'FallbackModel' ''))
        if($candidate -and $candidate -notin $AttemptedModels -and $candidate -cne $FailedModel){$status='FALLBACK_AUTHORIZED';$next=$candidate;$tier=[string]$fb.FallbackTier;$reason=[string]$fb.Reason}
        else {$status='EXHAUSTED';$reason=[string](Get-MAValue $fb 'Reason' 'NO_ELIGIBLE_CANDIDATE')}
    }
    $id=[guid]::NewGuid().ToString('N')
    $decision=[pscustomobject]@{Status=$status;Classification=$class;NoStartProof=$noStart;FallbackEligible=[bool]($status -eq 'FALLBACK_AUTHORIZED');NextModel=$next;NextTier=$tier;AttemptId=$id;SessionId=$(if($SessionId){$SessionId}else{$null});ObservedModel=$(if($ObservedModel){$ObservedModel}else{'UNKNOWN'});EvidenceRef=$(if($EvidenceDir){Join-Path $EvidenceDir 'fallback-decisions.jsonl'}else{$null});Reason=$reason}
    if($EvidenceDir){try{[void][IO.Directory]::CreateDirectory($EvidenceDir);$line=[ordered]@{task_id=$TaskId;attempt_role=$AttemptRole;failed_model=$FailedModel;classification=$class;no_start_proof=$noStart;no_start_reason=$(if($noStart){'OBSERVED_NO_START'}else{'NO_START_REQUIREMENTS_NOT_MET'});status=$status;decision=$status;next_model=$next;attempt_id=$id;session_id=$(if($SessionId){$SessionId}else{$null});observed_model=$(if($ObservedModel){$ObservedModel}else{'UNKNOWN'});error=$( [string](Get-MAValue $Failure 'Message' (Get-MAValue $Failure 'message' '')) );recorded_at=[DateTime]::UtcNow.ToString('o')};if($line.error.Length -gt 512){$line.error=$line.error.Substring(0,512)};[IO.File]::AppendAllText($decision.EvidenceRef,(($line|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}}
    return $decision
}
function Get-OrchestrationModelFallbackChain {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$AttemptRole,[string]$Risk='low',[string]$Complexity='simple',[string]$TaskId='audit',[string]$PolicyPath='')
    $sel=Resolve-OrchestrationModelSelection -AgentName $AttemptRole -TaskId $TaskId -Risk $Risk -Complexity $Complexity -PolicyPath $PolicyPath -IgnoreUserConfig $true
    $chain=@();$seen=@();$current=[string]$sel.CatalogModel
    for($i=0;$i -lt 8 -and $current;$i++){$chain+=,$current;$seen+=,$current;$r=Resolve-OrchestrationModelFallback -RequestedSelection $sel -FailedModel $current -TriggerReason RATE_LIMIT -AttemptedModels $seen -PolicyPath $PolicyPath -IgnoreUserConfig $true -NoExecutionStarted $true -TaskId $TaskId;$current=[string](Get-MAValue $r 'CandidateModel' (Get-MAValue $r 'FallbackModel' ''))}
    return ,$chain
}
