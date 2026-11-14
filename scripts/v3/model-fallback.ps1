<#
.SYNOPSIS
Gets the next policy fallback or records an observed attempt.
.DESCRIPTION
For -Action next, provide structured failure and, for provider/dispatcher
errors, complete structured pre_dispatch evidence. Only a recognized
tool.execution error without child session id or valid explicit evidence
proves non-start. Missing, malformed, inconsistent, or ambiguous evidence
fails closed. The caller/Planner performs the single authorized redispatch;
this helper never dispatches. Output JSON has stable fields status,
classification, no_start_proof, next_model, next_tier, attempt_id, reason.
Conscious trade-off: an ineligible failure class takes precedence over
session/execution evidence and remains HOLD_TERMINAL with reason
FAILURE_NOT_ELIGIBLE; both conditions still hold, never permission to retry.
Exit codes: 0 for FALLBACK_AUTHORIZED or EXHAUSTED; 3 for HOLD_*; 2 for
usage/input errors. -Action record writes model-attempt evidence separately
from the Task Kernel model_attempts record.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('next','record')][string]$Action,[string]$AttemptRole,[string]$FailedModel,[string[]]$AttemptedModels=@(),[string]$FailureJson,[string]$AttemptEvidenceJson,[string]$AttemptId,[string]$Model,[string]$SessionId,[string]$ObservedModel,[string]$TaskId='fallback',[string]$Risk='low',[string]$Complexity='simple',[string]$EvidenceDir='',[string]$PolicyPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationModelFallback.ps1')
$AttemptedModels=ConvertFrom-OrchestrationAttemptedModels $AttemptedModels
try {
 if($Action -eq 'next'){
  if(-not $AttemptRole -or -not $FailedModel -or -not $FailureJson){throw 'Required: AttemptRole, FailedModel, FailureJson'}
  $f=$FailureJson;if($f.StartsWith('@')){$f=Get-Content -LiteralPath $f.Substring(1) -Raw}
  $ae=$null;if($AttemptEvidenceJson){try{$aj=$AttemptEvidenceJson;if($aj.StartsWith('@')){$aj=Get-Content -LiteralPath $aj.Substring(1) -Raw};$ae=ConvertFrom-Json -InputObject $aj -ErrorAction Stop}catch{$ae=@{source='invalid';stage='pre_dispatch';session_id='';execution_started=$false;assistant_messages=0;tool_calls=0}}}
  $d=Get-OrchestrationModelFallbackDecision -TaskId $TaskId -AttemptRole $AttemptRole -Risk $Risk -Complexity $Complexity -FailedModel $FailedModel -AttemptedModels $AttemptedModels -Failure $f -SessionId $SessionId -ObservedModel $ObservedModel -PolicyPath $PolicyPath -EvidenceDir $EvidenceDir -AttemptEvidence $ae
  $o=@{status=$d.Status;classification=$d.Classification;no_start_proof=$d.NoStartProof;next_model=$d.NextModel;next_tier=$d.NextTier;attempt_id=$d.AttemptId;reason=$d.Reason};$o|ConvertTo-Json -Compress
  if($d.Status -like 'HOLD_*'){exit 3};if($d.Status -in @('FALLBACK_AUTHORIZED','EXHAUSTED')){exit 0};exit 3
 }
 if(-not $AttemptId -or -not $AttemptRole -or -not $Model -or -not $SessionId){throw 'Required: AttemptId, AttemptRole, Model, SessionId'}
 $record=[ordered]@{attempt_id=$AttemptId;task_id=$TaskId;agent=$AttemptRole;requested_model=$Model;requested_provider=$(if($Model -match '^([^/]+)/'){$Matches[1]}else{'UNKNOWN'});stage='post_dispatch';session_id=$SessionId;observed_model=$(if($ObservedModel){$ObservedModel}else{'UNKNOWN'});started_at=[DateTime]::UtcNow.ToString('o');finished_at=[DateTime]::UtcNow.ToString('o');success=$true}
 if($EvidenceDir){try{[void][IO.Directory]::CreateDirectory($EvidenceDir);[IO.File]::AppendAllText((Join-Path $EvidenceDir 'model-attempts.jsonl'),(($record|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}}
 $record|ConvertTo-Json -Compress;exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message);exit 2 }
