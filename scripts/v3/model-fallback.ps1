<#
.SYNOPSIS
Gets the next policy fallback or records an observed attempt.
.DESCRIPTION
For -Action next, pass -SessionId only when the runtime returned a child
session id. A tool.execution error without a session id is the observed
evidence of non-start. Any returned child session id forces an ambiguous
execution hold and prevents a duplicate run.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('next','record')][string]$Action,[string]$AttemptRole,[string]$FailedModel,[string[]]$AttemptedModels=@(),[string]$FailureJson,[string]$AttemptEvidenceJson,[string]$AttemptId,[string]$Model,[string]$SessionId,[string]$ObservedModel,[string]$TaskId='fallback',[string]$Risk='low',[string]$Complexity='simple',[string]$EvidenceDir='',[string]$PolicyPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationModelFallback.ps1')
try {
 if($Action -eq 'next'){
  if(-not $AttemptRole -or -not $FailedModel -or -not $FailureJson){throw 'Required: AttemptRole, FailedModel, FailureJson'}
  $f=$FailureJson;if($f.StartsWith('@')){$f=Get-Content -LiteralPath $f.Substring(1) -Raw}
  $ae=$null;if($AttemptEvidenceJson){$aj=$AttemptEvidenceJson;if($aj.StartsWith('@')){$aj=Get-Content -LiteralPath $aj.Substring(1) -Raw};$ae=ConvertFrom-Json -InputObject $aj -ErrorAction Stop}
  $d=Get-OrchestrationModelFallbackDecision -TaskId $TaskId -AttemptRole $AttemptRole -Risk $Risk -Complexity $Complexity -FailedModel $FailedModel -AttemptedModels $AttemptedModels -Failure $f -SessionId $SessionId -ObservedModel $ObservedModel -PolicyPath $PolicyPath -EvidenceDir $EvidenceDir -AttemptEvidence $ae
  $o=@{status=$d.Status;classification=$d.Classification;no_start_proof=$d.NoStartProof;next_model=$d.NextModel;next_tier=$d.NextTier;attempt_id=$d.AttemptId;reason=$d.Reason};$o|ConvertTo-Json -Compress
  if($d.Status -like 'HOLD_*'){exit 3};if($d.Status -in @('FALLBACK_AUTHORIZED','EXHAUSTED')){exit 0};exit 3
 }
 if(-not $AttemptId -or -not $AttemptRole -or -not $Model -or -not $SessionId){throw 'Required: AttemptId, AttemptRole, Model, SessionId'}
 $record=[ordered]@{attempt_id=$AttemptId;task_id=$TaskId;agent=$AttemptRole;requested_model=$Model;requested_provider=$(if($Model -match '^([^/]+)/'){$Matches[1]}else{'UNKNOWN'});stage='post_dispatch';session_id=$SessionId;observed_model=$(if($ObservedModel){$ObservedModel}else{'UNKNOWN'});started_at=[DateTime]::UtcNow.ToString('o');finished_at=[DateTime]::UtcNow.ToString('o');success=$true}
 if($EvidenceDir){try{[void][IO.Directory]::CreateDirectory($EvidenceDir);[IO.File]::AppendAllText((Join-Path $EvidenceDir 'model-attempts.jsonl'),(($record|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))}catch{}}
 $record|ConvertTo-Json -Compress;exit 0
} catch { [Console]::Error.WriteLine($_.Exception.Message);exit 2 }
