<#
.SYNOPSIS
    Builds bounded continuation envelopes and deterministically reconciles declared session observations.
.DESCRIPTION
    Read-only: never probes or controls runtime sessions. SESSION_LOST is an attempt-shaped record;
    the caller must register it through the kernel's supported attempt path. V2 native probing is HOLD.
    Reconciliation input caps are 200 bindings and 500 observations; excess fails closed without partial output.
    Interrupted sessions recommend inspecting the referenced attempt; completed sessions recommend output recovery,
    including when output_ref is absent. Free-text secret scrubbing is heuristic and cannot detect arbitrary secrets.
    Oversize discard order: failed strategies, decisions, evidence refs, risks, waits, then objective text.
    PowerShell 5.1 compatible; no network or process execution.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$continuationSanitizePath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (-not (Get-Command Remove-SecretValues -ErrorAction SilentlyContinue)) { . $continuationSanitizePath }

function Resolve-ContinuationTimestamp([object]$TimestampUtc) {
    if ($null -eq $TimestampUtc) { return [DateTime]::UtcNow }
    try { return ([DateTime]::Parse([string]$TimestampUtc)).ToUniversalTime() } catch { throw 'TimestampUtc must be a DateTime or ISO timestamp.' }
}

function Protect-ContinuationText([string]$Value, [int]$MaxLength = 300) {
    if ($null -eq $Value) { return '' }
    $v = [string](Remove-SecretValues -InputObject $Value)
    if ($v.Length -gt $MaxLength) { $v = $v.Substring(0,$MaxLength) }
    return $v
}

function New-OrchestrationContinuationEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$TaskId,[string]$Objective='',[string]$UserIntent='',
        [object[]]$Decisions=@(),[object[]]$ValidEvidenceRefs=@(),[object[]]$FailedStrategies=@(),
        [object[]]$ActiveRisks=@(),[object[]]$PendingWaits=@(),[string]$NextMove='',
        [object]$TimestampUtc=$null,[int]$ByteBudget=8192,[int]$MaxItems=30)
    $env=[ordered]@{task_id=(Protect-ContinuationText $TaskId 128);objective=(Protect-ContinuationText $Objective);user_intent=(Protect-ContinuationText $UserIntent);decisions=@();valid_evidence_refs=@();failed_strategies=@();active_risks=@();pending_waits=@();next_move=(Protect-ContinuationText $NextMove);generated_at='';truncated=$false}
    try {$env.generated_at=Protect-ContinuationText ((Resolve-ContinuationTimestamp $TimestampUtc).ToString('o'))} catch {$env.generated_at=''}
    if($MaxItems -lt 0){$MaxItems=0}; if($MaxItems -gt 30){$MaxItems=30}; if($ByteBudget -lt 1){$ByteBudget=8192}
    foreach($item in @($Decisions | Select-Object -First $MaxItems)){ $env.decisions+=,(Protect-ContinuationText ([string]$item)) }
    foreach($item in @($ValidEvidenceRefs | Select-Object -First $MaxItems)){ $env.valid_evidence_refs+=,(Protect-ContinuationText ([string]$item) 160) }
    foreach($item in @($FailedStrategies | Select-Object -First $MaxItems)) {
        $env.failed_strategies+=,@{strategy_id=(Protect-ContinuationText ([string]$item.strategy_id) 128);fingerprint=(Protect-ContinuationText ([string]$item.fingerprint) 128);reason=(Protect-ContinuationText ([string]$item.reason))}
    }
    foreach($item in @($ActiveRisks | Select-Object -First $MaxItems)){ $env.active_risks+=,(Protect-ContinuationText ([string]$item)) }
    foreach($item in @($PendingWaits | Select-Object -First $MaxItems)){
        $env.pending_waits+=,@{type=(Protect-ContinuationText ([string]$item.type) 64);owner=(Protect-ContinuationText ([string]$item.owner) 128);action=(Protect-ContinuationText ([string]$item.action) 160);dependency_id=(Protect-ContinuationText ([string]$item.dependency_id) 128)}
    }
    $discard=@('failed_strategies','decisions','valid_evidence_refs','active_risks','pending_waits')
    foreach($key in $discard){
        $json=ConvertTo-Json -InputObject $env -Depth 12 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($json) -le $ByteBudget){break}
        if(@($env[$key]).Count -gt 0){$env[$key]=@();$env.truncated=$true}
    }
    $json=ConvertTo-Json -InputObject $env -Depth 12 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt $ByteBudget){
        foreach($key in @('objective','user_intent','next_move')){$env[$key]='';$env.truncated=$true;$json=ConvertTo-Json -InputObject $env -Depth 12 -Compress;if([Text.Encoding]::UTF8.GetByteCount($json) -le $ByteBudget){break}}
    }
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt $ByteBudget){return [pscustomobject]@{status='oversized';truncated=$true;oversized=$true}}
    return [pscustomobject]$env
}

function New-OrchestrationSessionLostAttemptResult {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Binding,[Parameter(Mandatory=$true)]$Observation,[Parameter(Mandatory=$true)][bool]$AbsenceProven,[object]$TimestampUtc=$null)
    if ([string]$Observation.observed -cne 'missing' -or -not $AbsenceProven) { return [pscustomobject]@{ok=$false;error='SESSION_LOST_NOT_PROVEN'} }
    $stamp=''; try{$stamp=(Resolve-ContinuationTimestamp $TimestampUtc).ToString('o')}catch{}
    return [pscustomobject][ordered]@{n=0;status='SESSION_LOST';result_type='SESSION_LOST';task_id=[string]$Binding.task_id;run_id=[string]$Binding.run_id;session_id=[string]$Binding.session_id;at=$stamp;registration='caller_must_register_with_kernel';task_state_mutated=$false}
}

function Get-ReconcilerFieldInfo([object]$Obs,[string]$Name) {
    if ($Obs -is [System.Collections.IDictionary]) {
        if ($Obs.Contains($Name)) {
            $v=$Obs[$Name];$t='null';if($null -ne $v){$t=$v.GetType().FullName};$s='';if($null -ne $v){$s=[string]$v}
            return @{exists=$true;text=$s;typename=$t;value=$v}
        }
        return @{exists=$false;text='';typename='';value=$null}
    }
    $p=$Obs.PSObject.Properties[$Name]
    if ($null -eq $p) { return @{exists=$false;text='';typename='';value=$null} }
    $v=$p.Value;$t='null';if($null -ne $v){$t=$v.GetType().FullName};$s='';if($null -ne $v){$s=[string]$v}
    return @{exists=$true;text=$s;typename=$t;value=$v}
}

function Test-ReconcilerGroupEquivalent([object[]]$Group) {
    $fields=@('observed','binding_session_id','output_ref','attempt_ref','last_seen')
    for($i=1;$i -lt $Group.Count;$i++){
        foreach($f in $fields){
            $a=Get-ReconcilerFieldInfo $Group[0] $f
            $b=Get-ReconcilerFieldInfo $Group[$i] $f
            if($a.exists -ne $b.exists){return $false}
            if($a.exists){
                if($a.text -cne $b.text){return $false}
                if($a.typename -cne $b.typename){return $false}
            }
        }
    }
    return $true
}

function Test-ReconcilerObservationValid([object]$Obs,[string]$Sid) {
    # Strict scalar-string gate, duplicates scope only (unique/singleton path keeps legacy coercion).
    # Any non-string scalar (arrays, bool/int, $null) in an identity/evidence field is invalid here,
    # so equally-invalid duplicates can never collapse into recover-output; a present-but-falsy
    # last_seen ($false/0) is invalid, while present-empty-string stays absent-like per unique contract.
    $oi=Get-ReconcilerFieldInfo $Obs 'observed'
    if(-not $oi.exists -or -not ($oi.value -is [string])){return $false}
    if($oi.value -notin @('running','completed','interrupted','missing','stale')){return $false}
    $si=Get-ReconcilerFieldInfo $Obs 'session_id'
    if(-not $si.exists -or -not ($si.value -is [string])){return $false}
    if($si.value -cne $Sid){return $false}
    $bi=Get-ReconcilerFieldInfo $Obs 'binding_session_id'
    if($bi.exists){
        if(-not ($bi.value -is [string])){return $false}
        if($bi.value -cne $Sid){return $false}
    }
    $ri=Get-ReconcilerFieldInfo $Obs 'output_ref'
    if($ri.exists -and -not ($ri.value -is [string])){return $false}
    $ai=Get-ReconcilerFieldInfo $Obs 'attempt_ref'
    if($ai.exists -and -not ($ai.value -is [string])){return $false}
    $lsi=Get-ReconcilerFieldInfo $Obs 'last_seen'
    if($lsi.exists){
        $lv=$lsi.value
        if($null -eq $lv){return $false}
        if(-not ($lv -is [string])){return $false}
        if($lv -ne ''){try{[void][DateTime]::Parse($lv).ToUniversalTime()}catch{return $false}}
    }
    return $true
}

function Get-OrchestrationSessionReconciliation {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Bindings,[object[]]$Observations=@(),[Parameter(Mandatory=$true)][int]$StaleAfterSeconds,[object]$TimestampUtc=$null)
    if($Bindings.Count -gt 200 -or $Observations.Count -gt 500){return [pscustomobject]@{status='input-limit-exceeded';runs=@();recommended_actions=@();probed=$false}}
    $now=Resolve-ContinuationTimestamp $TimestampUtc
    # F2 root cause: prior code did last-wins ($obsById[sid]=$o) before validation, so duplicate
    # observations for the same session_id resolved by input order and a duplicate could hide
    # invalid evidence. Fail closed: group by session_id; only semantically equal duplicates on
    # the relevant safety fields (observed/binding_session_id/output_ref/attempt_ref/last_seen,
    # presence+value+type) collapse; any conflict or any individually-invalid member yields
    # stale/ambiguous_observations with empty output_ref and no recommended action. No timestamp ordering.
    # Identity is ordinal case-exact (ses_x vs SES_X are distinct ids; producers must use exact IDs):
    # grouping and binding lookup use Ordinal dictionaries, and each duplicate member must carry an
    # exact string session_id. Strict scalar-string validation applies to duplicates only; the
    # unique/singleton path keeps the legacy coercion contract.
    $obsGroups=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($o in $Observations){
        if($null -eq $o){continue}
        $sk='';try{$sk=[string]$o.session_id}catch{$sk=''}
        if([string]::IsNullOrWhiteSpace($sk)){continue}
        if(-not $obsGroups.ContainsKey($sk)){$obsGroups[$sk]=@()}
        $obsGroups[$sk]=@($obsGroups[$sk]) + ,$o
    }
    $obsById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $ambiguousIds=[System.Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
    foreach($key in @($obsGroups.Keys)){
        $g=@($obsGroups[$key])
        if($g.Count -eq 1){$obsById[$key]=$g[0];continue}
        $equiv=Test-ReconcilerGroupEquivalent $g
        $allValid=$true;foreach($m in $g){if(-not (Test-ReconcilerObservationValid $m $key)){$allValid=$false;break}}
        if($equiv -and $allValid){$obsById[$key]=$g[0]}
        else{$ambiguousIds[$key]=$true}
    }
    $rows=@();$actions=@()
    foreach($run in $Bindings){
        $ids=@();if($run.root_session){$ids+=,[string]$run.root_session};foreach($sid in @($run.worker_sessions)){$ids+=,[string]$sid}
        foreach($sid in $ids){if(-not $sid){continue};$o=$null;if($obsById.ContainsKey($sid)){$o=$obsById[$sid]};$status='missing';$detail='';$output=''
            if($ambiguousIds.ContainsKey($sid)){$status='stale';$detail='ambiguous_observations';$output=''}
            elseif($null -eq $o){
                $status='missing'
                if($run.bound_at){try{if(($now-[DateTime]::Parse([string]$run.bound_at).ToUniversalTime()).TotalSeconds -le $StaleAfterSeconds){$status='stale';$detail='awaiting_stale_threshold'}}catch{$status='stale';$detail='invalid_bound_at'}}
            }
            else {
                $decl=[string]$o.observed
                if($decl -notin @('running','completed','interrupted','missing','stale')){$status='stale';$detail='invalid_observation'}
                elseif((($o -is [System.Collections.IDictionary] -and $o.Contains('binding_session_id')) -or $o.PSObject.Properties['binding_session_id']) -and [string]$o.binding_session_id -cne $sid){$status='stale';$detail='ownership_mismatch'}
                else {$status=$decl;if($decl -eq 'completed'){$output=[string]$o.output_ref}}
                if(((($o -is [System.Collections.IDictionary] -and $o.Contains('last_seen')) -or $o.PSObject.Properties['last_seen'])) -and $o.last_seen){try{if(($now-[DateTime]::Parse([string]$o.last_seen).ToUniversalTime()).TotalSeconds -gt $StaleAfterSeconds -and $status -eq 'running'){$status='stale';$detail='stale_observation'}}catch{$status='stale';$detail='invalid_last_seen'}}
            }
            $r=[pscustomobject]@{run_id=[string]$run.run_id;session_id=$sid;status=$status;output_ref=$output;detail=$detail};$rows+=,$r
            if($status -eq 'running'){$actions+=,@{action='reattach';run_id=$r.run_id;session_id=$sid;via='P32_bind'}}
            elseif($status -eq 'completed'){$actions+=,@{action='recover-output';run_id=$r.run_id;session_id=$sid;output_ref=$output;output_ref_missing=[string]::IsNullOrWhiteSpace($output)}}
            elseif($status -eq 'interrupted'){$attemptRef='';if($null -ne $o){$attemptRef=[string]$o.attempt_ref};$actions+=,@{action='inspect-interrupted-attempt';run_id=$r.run_id;session_id=$sid;attempt_ref=$attemptRef}}
            elseif($status -eq 'missing'){$actions+=,@{action='mark_SESSION_LOST';run_id=$r.run_id;session_id=$sid;requires_absence_proof=$true}}
        }
    }
    return [pscustomobject]@{runs=@($rows);recommended_actions=@($actions);probed=$false}
}

function New-OrchestrationContinuationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Envelope,[Parameter(Mandatory=$true)][ValidateSet('1','2')][string]$Runtime,[string]$EnvelopeRef='')
    if($Runtime -eq '1'){return [pscustomobject]@{mode='fresh-session';task_id=[string]$Envelope.task_id;envelope_ref=$EnvelopeRef;native_resume=$false}}
    return [pscustomobject]@{mode='reconciler-required';task_id=[string]$Envelope.task_id;envelope_ref=$EnvelopeRef;native_resume=$false}
}
