[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationProviderError.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationCacheMetrics.ps1')

function Get-MAValue { param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
    $p=$Object.PSObject.Properties[$Name]; if ($null -ne $p) { return $p.Value }; return $Default
}
function Read-OrchestrationNativeSessionEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SessionId,[scriptblock]$Reader)
    $bad = @{ ok=$false; session_id=$SessionId; outcome=''; session_model_id=''; session_provider=''; assistant_messages=0; tool_calls=0; text_parts=0; error_type=''; error_message=''; usage_input='UNKNOWN'; usage_output='UNKNOWN'; usage_reasoning='UNKNOWN'; cache_read='UNKNOWN'; cache_write='UNKNOWN'; cost='UNKNOWN'; observed_model=$null; execution_started=$false; error='SESSION_EVIDENCE_UNAVAILABLE' }
    try {
        if ($null -eq $Reader) { return $bad }
        $raw = & $Reader -SessionId $SessionId
        if ($null -eq $raw) { return $bad }
        if ($raw -is [string]) { $raw = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
        if ($null -ne (Get-MAValue $raw 'session' $null)) { $session=Get-MAValue $raw 'session' $null; $messages=Get-MAValue $raw 'messages' @() }
        else { $session=Get-MAValue (Get-MAValue $raw 'data' $raw) 'session' $null; if ($null -eq $session) { $session=Get-MAValue $raw 'data' $raw }; $messages=Get-MAValue $raw 'messages' $null; if ($null -eq $messages) { $messages=Get-MAValue $raw 'data' @() } }
        if ($session -is [string]) { $session=ConvertFrom-Json $session -ErrorAction Stop }
        if ($null -eq $session) { return $bad }
        $sid=[string](Get-MAValue $session 'id' $SessionId); $outcome=[string](Get-MAValue $session 'outcome' '')
        $assistant=0; $tools=0; $texts=0; $observed=$null
        foreach ($m in @($messages)) {
            if ([string](Get-MAValue $m 'type' '') -ceq 'assistant') {
                $assistant++; $mm=Get-MAValue $m 'model' $null
                if ($null -ne $mm) { $pr=[string](Get-MAValue $mm 'providerID' ''); $id=[string](Get-MAValue $mm 'id' ''); if ($pr -and $id) { $observed="$pr/$id" } }
                foreach ($part in @(Get-MAValue $m 'content' @())) { $pt=[string](Get-MAValue $part 'type' ''); if ($pt -ceq 'tool') { $tools++ }; if ($pt -ceq 'text') { $texts++ } }
            }
        }
        $errType=''; $errMsg=''
        foreach ($m in @($messages)) { $e=Get-MAValue $m 'error' $null; if ($null -ne $e) { $errType=[string](Get-MAValue $e 'type' ''); $errMsg=[string](Get-MAValue $e 'message' '') } }
        if ($errMsg.Length -gt 512) { $errMsg=$errMsg.Substring(0,512) }
        $metrics=Get-OrchestrationCacheMetrics -Session $session
        return @{ ok=$true; session_id=$sid; outcome=$outcome; session_model_id=[string](Get-MAValue (Get-MAValue $session 'model' $null) 'id' ''); session_provider=[string](Get-MAValue (Get-MAValue $session 'model' $null) 'providerID' ''); assistant_messages=$assistant; tool_calls=$tools; text_parts=$texts; error_type=$errType; error_message=$errMsg; usage_input=$(if($metrics.ok){$metrics.input_tokens}else{'UNKNOWN'}); usage_output=$(if($metrics.ok){$metrics.output_tokens}else{'UNKNOWN'}); usage_reasoning=$(if($metrics.ok){$metrics.reasoning_tokens}else{'UNKNOWN'}); cache_read=$(if($metrics.ok){$metrics.cache_read_tokens}else{'UNKNOWN'}); cache_write=$(if($metrics.ok){$metrics.cache_write_tokens}else{'UNKNOWN'}); cost=$(if($metrics.ok){$metrics.cost}else{'UNKNOWN'}); observed_model=$observed; execution_started=([bool]($assistant -gt 0 -or $tools -gt 0)); error='' }
    } catch { $bad.error='SESSION_EVIDENCE_INVALID'; return $bad }
}
function New-OrchestrationModelAttempt {
    [CmdletBinding()] param([Parameter(Mandatory=$true)][string]$TaskId,[Parameter(Mandatory=$true)][string]$Agent,[Parameter(Mandatory=$true)][string]$Model,[Parameter(Mandatory=$true)][string]$AttemptId,[ValidateSet('pre_dispatch','post_dispatch','unknown')][string]$Stage='pre_dispatch',[string]$EvidenceDir='')
    $p,$m=$Model -split '/',2
    return [pscustomobject]@{ attempt_id=$AttemptId; task_id=$TaskId; agent=$Agent; requested_model=$Model; requested_provider=$p; stage=$Stage; evidence_dir=$EvidenceDir; started_at=[DateTime]::UtcNow.ToString('o'); assistant_messages=0; tool_calls=0; outcome=''; session_id=''; observed_model=$null; execution_started=$false }
}
function Test-OrchestrationAttemptNoStartProof {
    [CmdletBinding()] param([Parameter(Mandatory=$true)]$Attempt)
    $f=Get-MAValue $Attempt 'failure' $null; $class=[string](Get-MAValue $f 'Classification' '')
    $valid=([string](Get-MAValue $f 'Source' '') -ceq 'tool_error') -and -not [bool](Get-MAValue $Attempt 'execution_started' $true) -and ([int](Get-MAValue $Attempt 'assistant_messages' 0) -eq 0) -and ([int](Get-MAValue $Attempt 'tool_calls' 0) -eq 0) -and [string]::IsNullOrWhiteSpace([string](Get-MAValue $Attempt 'session_id' '')) -and ($null -eq (Get-MAValue $Attempt 'observed_model' $null)) -and ($class -in @('RATE_LIMIT','QUOTA_EXCEEDED','MODEL_UNAVAILABLE','PROVIDER_UNAVAILABLE'))
    return [pscustomobject]@{ proven=[bool]$valid; reason=$(if($valid){'OBSERVED_NO_START'}else{'NO_START_REQUIREMENTS_NOT_MET'}) }
}
function ConvertFrom-OrchestrationToolError {
    [CmdletBinding()] param([Parameter(Mandatory=$true)]$ErrorObject)
    try { if($ErrorObject -is [string]){$ErrorObject=ConvertFrom-Json -InputObject $ErrorObject -ErrorAction Stop} } catch { return [pscustomobject]@{Classification='NONE';Availability=$false;FallbackEligible=$false;Source='tool_error';Error='INVALID_TOOL_ERROR';Signals=@{}} }
    $e=Get-MAValue $ErrorObject 'error' $ErrorObject
    $type=[string](Get-MAValue $e 'type' '');$message=[string](Get-MAValue $e 'message' '')
    if($message.Length -gt 512){$message=$message.Substring(0,512)}
    if($type -ceq 'tool.execution' -and $message -match '(?i)is not available|not available|unknown model|model .+ not found'){$result=ConvertFrom-OrchestrationProviderFailure -Failure @{code='model_unavailable';message=$message} -Stage pre_dispatch}
    else {$result=ConvertFrom-OrchestrationProviderFailure -Failure @{type=$type;message=$message} -Stage pre_dispatch}
    return [pscustomobject]@{Classification=$result.Classification;Availability=[bool]$result.Availability;FallbackEligible=[bool]$result.FallbackEligible;Source='tool_error';Signals=$result.Signals;Message=$message;ToolType=$type;SessionId=[string](Get-MAValue $ErrorObject 'sessionID' '')}
}
function Get-OrchestrationFailureFromOutput {
    [CmdletBinding()] param([AllowEmptyString()][string]$StdOut,[AllowEmptyString()][string]$StdErr)
    $found=$null
    foreach ($line in (($StdOut+"`n"+$StdErr) -split "`r?`n")) { try { $o=ConvertFrom-Json -InputObject $line -ErrorAction Stop; if ([string](Get-MAValue $o 'type' '') -ceq 'error') { $found=Get-MAValue $o 'error' $null; $sid=[string](Get-MAValue $o 'sessionID' '') } } catch {} }
    if ($null -eq $found) { return $null }
    $msg=[string](Get-MAValue $found 'message' ''); if ($msg.Length -gt 512) {$msg=$msg.Substring(0,512)}
    $type=[string](Get-MAValue $found 'type' '')
    $code=$type
    if ($type -ceq 'provider.no-route') {$code='model_unavailable'}
    return [pscustomobject]@{ http_status=$null; code=$code; error_type=$type; message=$msg; provider=''; model=''; attempt_id=''; session_id=$sid }
}
function Complete-OrchestrationModelAttempt {
    [CmdletBinding()] param([Parameter(Mandatory=$true)]$Attempt,[int]$ExitCode,[AllowEmptyString()][string]$StdOut='',[AllowEmptyString()][string]$StdErr='',$SessionEvidence=$null,$FailureOverride=$null)
    $native=$SessionEvidence; if ($null -eq $native) {$native=@{}}
    $failureInput=$FailureOverride; if ($null -eq $failureInput) {$failureInput=Get-OrchestrationFailureFromOutput $StdOut $StdErr}
    $failure=ConvertFrom-OrchestrationProviderFailure -Failure $failureInput -Stage ([string]$Attempt.stage)
    $started=[bool](Get-MAValue $native 'execution_started' $false); $am=[int](Get-MAValue $native 'assistant_messages' 0); $tc=[int](Get-MAValue $native 'tool_calls' 0)
    if (($ExitCode -ne 0) -and ($null -eq $failureInput)) {$failure=ConvertFrom-OrchestrationProviderFailure -Failure @{code='unknown result'} -Stage 'unknown'}
    $Attempt | Add-Member -NotePropertyName failure -NotePropertyValue $failure -Force
    foreach ($n in @('session_id','outcome','observed_model','usage_input','usage_output','usage_reasoning','cache_read','cache_write','cost')) { $Attempt | Add-Member -NotePropertyName $n -NotePropertyValue (Get-MAValue $native $n $(if($n -like 'usage*' -or $n -like 'cache*' -or $n -eq 'cost'){'UNKNOWN'}else{$null})) -Force }
    $Attempt | Add-Member -NotePropertyName assistant_messages -NotePropertyValue $am -Force; $Attempt | Add-Member -NotePropertyName tool_calls -NotePropertyValue $tc -Force; $Attempt | Add-Member -NotePropertyName execution_started -NotePropertyValue $started -Force
    $proof=Test-OrchestrationAttemptNoStartProof $Attempt
    $Attempt | Add-Member -NotePropertyName no_start_proof -NotePropertyValue $proof.proven -Force; $Attempt | Add-Member -NotePropertyName no_start_reason -NotePropertyValue $proof.reason -Force
    $Attempt | Add-Member -NotePropertyName success -NotePropertyValue ([bool]($ExitCode -eq 0 -and $am -gt 0)) -Force; $Attempt | Add-Member -NotePropertyName finished_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    if (-not [string]::IsNullOrWhiteSpace([string]$Attempt.evidence_dir)) { try { [void][IO.Directory]::CreateDirectory([string]$Attempt.evidence_dir); [IO.File]::AppendAllText((Join-Path $Attempt.evidence_dir 'model-attempts.jsonl'),(($Attempt|ConvertTo-Json -Compress -Depth 8)+"`n"),(New-Object Text.UTF8Encoding($false))) } catch {} }
    return $Attempt
}
