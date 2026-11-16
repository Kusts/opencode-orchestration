# Pure shadow-only classifier. Callers MUST check ok before using intent; no action is executable.
. (Join-Path $PSScriptRoot 'OrchestrationEventCorrelation.ps1')
function Get-AdmissionProperty {
    param($Node,[string]$Name)
    if($null -eq $Node){return @{present=$false;value=$null}}
    if($Node -is [System.Collections.IDictionary]){if($Node.Contains($Name)){return @{present=$true;value=$Node[$Name]}};return @{present=$false;value=$null}}
    $p=$Node.PSObject.Properties[$Name];if($null -ne $p){return @{present=$true;value=$p.Value}};return @{present=$false;value=$null}
}
function Resolve-OrchestrationEventAdmissionIntent {
    [CmdletBinding()]
    param($Envelope,$Context,$Rules,[string]$Mode='observe')
    $o=[ordered]@{ok=$true;intent='ignore';mode=$Mode;action='ignore';reason='invalid-envelope';error='';rule_id='';shadow=$true;executable=$false;dedup_key='';thread='';signals=@()}
    try {
        if ($Mode -cnotin @('off','observe','auto')) {$o.ok=$false;$o.reason='invalid-mode';return [pscustomobject]$o}
        $o.mode=$Mode
        if ($null -eq $Envelope) {$o.ok=$false;return [pscustomobject]$o}
        foreach($pair in @(@('source','SOURCE'),@('trigger','TRIGGER'),@('thread','THREAD'),@('delivery_id','DELIVERY'),@('repo','REPO'))){$v=Get-AdmissionProperty $Envelope $pair[0];if(-not $v.present -or $v.value -isnot [string] -or [string]::IsNullOrWhiteSpace($v.value)){$o.ok=$false;$o.error='EVENT_'+$pair[1]+'_INVALID';return [pscustomobject]$o}}
        $info=Get-OrchestrationEventField $Envelope 'informational_only'
        if ($info -isnot [bool]) {$o.ok=$false;return [pscustomobject]$o}
        $summary=Get-OrchestrationEventField $Envelope 'summary'; if ($null -eq $summary) {$summary=''}
        $e=New-OrchestrationEventEnvelope -Source ([string](Get-OrchestrationEventField $Envelope 'source')) -Trigger ([string](Get-OrchestrationEventField $Envelope 'trigger')) -Thread ([string](Get-OrchestrationEventField $Envelope 'thread')) -DeliveryId ([string](Get-OrchestrationEventField $Envelope 'delivery_id')) -Repo ([string](Get-OrchestrationEventField $Envelope 'repo')) -InformationalOnly $info -Summary ([string]$summary)
        if (-not $e.ok) {$o.ok=$false;$o.error=[string]$e.error;return [pscustomobject]$o}
        $o.dedup_key=$e.dedup_key;$o.thread=$e.thread
        if ($null -eq $Context) {$o.ok=$false;$o.reason='invalid-context';return [pscustomobject]$o}
        foreach($n in @('is_direct_mention','source_allowlisted','blocklisted','duplicate')) {if ((Get-OrchestrationEventField $Context $n) -isnot [bool]) {$o.ok=$false;$o.reason='invalid-context';return [pscustomobject]$o}}
        foreach($n in @('actor','actor_type','scope')) {if ($null -eq (Get-OrchestrationEventField $Context $n)) {$o.ok=$false;$o.reason='invalid-context';return [pscustomobject]$o}}
        $type=[string](Get-OrchestrationEventField $Context 'actor_type');$scope=[string](Get-OrchestrationEventField $Context 'scope')
        if ($type -notin @('bot','human','unknown') -or [string]::IsNullOrWhiteSpace($scope)) {$o.ok=$false;$o.reason='invalid-context';return [pscustomobject]$o}
        # Precedence: bot > blocklist > duplicate > informational > explicit > rule candidate > context.
        # Rules are validated only after these early exits; scope_allowlist is required because scope is a defined admission boundary.
        # thread_allowlist is optional: when absent the rule has no thread restriction.
        if ($type -eq 'bot') {$o.reason='self-or-bot';return [pscustomobject]$o}
        if ((Get-OrchestrationEventField $Context 'blocklisted')) {$o.reason='blocklisted';return [pscustomobject]$o}
        if ((Get-OrchestrationEventField $Context 'duplicate')) {$o.reason='duplicate-delivery';return [pscustomobject]$o}
        if ($info) {$o.reason='informational-only';return [pscustomobject]$o}
        if ((Get-OrchestrationEventField $Context 'is_direct_mention') -and $type -eq 'human' -and (Get-OrchestrationEventField $Context 'source_allowlisted')) {$o.intent='explicit';$o.reason='direct-mention';$o.action=if($Mode -eq 'auto'){'would_attach'}else{'observe'};$o.signals=@('direct-mention','human','source-allowlisted');return [pscustomobject]$o}
        if ($null -eq $Rules) {$o.ok=$false;$o.reason='invalid-rule';return [pscustomobject]$o}
        $rulesProp=Get-AdmissionProperty $Rules 'rules';if(-not $rulesProp.present){$o.ok=$false;$o.reason='invalid-rule';return [pscustomobject]$o};$rs=$rulesProp.value
        $matched=$null
        foreach($r in @($rs)) {
            if($null -eq $r){$o.ok=$false;$o.reason='invalid-rule';return [pscustomobject]$o}
            $en=Get-OrchestrationEventField $r 'enabled';if($en -isnot [bool]){$o.ok=$false;$o.reason='invalid-rule';return [pscustomobject]$o}
            if(-not $en){continue}
            $tr=Get-AdmissionProperty $r 'trigger';$sc=Get-AdmissionProperty $r 'scope_allowlist';$th=Get-AdmissionProperty $r 'thread_allowlist'
            if(-not $tr.present -or [string]::IsNullOrWhiteSpace([string]$tr.value) -or -not $sc.present -or $null -eq $sc.value -or @($sc.value).Count -eq 0 -or ($th.present -and ($null -eq $th.value -or @($th.value).Count -eq 0))){$o.ok=$false;$o.reason='invalid-rule';return [pscustomobject]$o}
            if($null -eq $matched -and [string]$tr.value -ceq [string]$e.trigger -and (($th.present -and @($th.value) -ccontains [string]$e.thread) -or -not $th.present) -and @($sc.value) -ccontains $scope){$matched=$r}
        }
        if($null -ne $matched) {
            $o.rule_id=[string](Get-OrchestrationEventField $matched 'rule_id');$o.signals=@('enabled-rule')
            if(-not (Get-OrchestrationEventField $Context 'source_allowlisted') -or $type -ne 'human'){$o.intent='context_only';$o.reason='candidate-not-allowlisted-human';return [pscustomobject]$o}
            if($Mode -eq 'off'){$o.intent='context_only';$o.reason='mode-off';return [pscustomobject]$o}
            $o.intent='candidate';$o.reason='rule-match';$o.action=if($Mode -eq 'auto'){'would_new_task'}else{'observe'};return [pscustomobject]$o
        }
        $o.intent='context_only';$o.reason='context-only';return [pscustomobject]$o
    } catch {$o.ok=$false;$o.intent='ignore';$o.action='ignore';return [pscustomobject]$o}
}
