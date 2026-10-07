<#
.SYNOPSIS
    Deterministic bounded Planner plan record; planning only, never dispatches.
.DESCRIPTION
    parallel_ok and route are loop composition: decision policies come from
    P34/P36 libraries; composition and stage ordering belong to this loop.
    When the Jev trigger fires and the jev_advisory flag node exists, the
    loop is the P38-S2 caller of Invoke-JevAdvisoryCall: it projects a
    sanitized bounded state, calls once through the lib (which owns every
    gate, the circuit and the sanitized evidence) and records the typed
    envelope in jev_advisory_result. -JevAdvisoryProbe (test seam,
    absent = real transport) and -JevAdvisoryBudgetSecondsOverride are
    direct pass-throughs. The result is advisory evidence only: it never
    routes, never escalates, never grants and never writes DONE, and any
    non-OK outcome leaves the deterministic plan untouched.
#>
[CmdletBinding()]
param()

function Invoke-OrchestrationPlannerLoop {
    [CmdletBinding()]
    param($Descriptor,$Options=$null,[scriptblock]$JevAdvisoryProbe=$null,[int]$JevAdvisoryBudgetSecondsOverride=0)
    $root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    function Read-PL($o,[string]$n,$d=$null) { if($null -eq $o){return $d};if($o -is [System.Collections.IDictionary]){if($o.Contains($n)){return $o[$n]};return $d};$p=$o.PSObject.Properties[$n];if($p){return $p.Value};return $d }
    # Secret redaction. The Authorization: Bearer form is redacted FIRST and
    # the -replace is whole-string and runs before the length cap, so a cut can
    # never leave a bearer value half revealed. Only the Authorization-qualified
    # form is matched (a standalone "bearer <token>" is NOT: false-positive rate
    # is too high and it would eat legitimate prose).
    function Safe-PL($v,[int]$max=300) { $s=[string]$v;$s=$s -replace '(?i)authorization[''"]?\s*[:=]\s*[''"]?bearer\s+[A-Za-z0-9._~+/=-]+','[redacted-authorization]' -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]' -replace '(?i)(token|secret|password|key)\s*[=:]\s*[^\s,;]+','$1=[redacted]' -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]' -replace '[\x00-\x1f]',' ';$s=$s.Trim();if($s.Length -gt $max){$s=$s.Substring(0,$max)};return $s }
    function Clean-PL($v,[int]$depth=0) { if($depth -gt 8){return '[depth-cap]'};if($null -eq $v){return $null};if($v -is [string]){return (Safe-PL $v 240)};if($v -is [bool] -or $v -is [ValueType]){return $v};if($v -is [System.Collections.IDictionary]){$h=[ordered]@{};$count=0;foreach($k in @($v.Keys | Sort-Object)){if($count -ge 40){break};$key=Safe-PL ([string]$k) 80;$h[$key]=Clean-PL $v[$k] ($depth+1);$count++};return $h};if($v -is [System.Collections.IEnumerable]){$a=@();foreach($x in $v){if($a.Count -ge 20){break};$a+=@(Clean-PL $x ($depth+1))};return ,$a};$h=[ordered]@{};$count=0;foreach($p in @($v.PSObject.Properties)){if($count -ge 40){break};$h[(Safe-PL $p.Name 80)]=Clean-PL $p.Value ($depth+1);$count++};return $h }
    function Unavailable-PL($why){return [pscustomobject]@{status='unavailable';reason=$why}}
    # Closed "not consulted" envelope for the Jev result record: same keys the
    # lib returns, no advice invented and never authoritative.
    function JevNotConsulted-PL($why){return [ordered]@{status='unavailable';reason=(Safe-PL $why 48);consulted=$false;would_consult=$false;fallback_continue=$true;blocked=$false;authoritative=$false;recommendation_only=$true}}
    # Resolve the process REAL home once: USERPROFILE, the HOME environment
    # variable, and the PowerShell $HOME automatic variable (read-only, so it
    # is only ever READ here). Distinct values are deduplicated case
    # insensitively. Trailing separators are trimmed so the value is safe to
    # use as an exact needle both bare and as a path prefix.
    function Get-PLRealHomes(){
        $seen=@{};$out=@()
        foreach($raw in @([string]$env:USERPROFILE,[string]$env:HOME,[string]$HOME)){
            if([string]::IsNullOrWhiteSpace($raw)){continue}
            $t=$raw.Trim().TrimEnd([char[]]@([char]'\',[char]'/'))
            if([string]::IsNullOrWhiteSpace($t)){continue}
            # A drive root ("C:") would make the literal replace below rewrite
            # EVERY path on that drive, so it is never used as a needle.
            if($t -match '^[A-Za-z]:$'){continue}
            $k=$t.ToLowerInvariant();if($seen.ContainsKey($k)){continue}
            $seen[$k]=$true;$out+=$t
        }
        return $out
    }
    # Strip user home directories. The real home goes first, matched by EXACT
    # case-insensitive literal replace (so a profile with spaces or regex
    # metacharacters is consumed whole and never half stripped), then the
    # generic fallback for OTHER profiles, whose Windows form consumes the full
    # name-with-spaces up to the next separator and leaves a trailing slash.
    # NOTE: the loop variable must not be named $home: that collides with the
    # read-only PowerShell automatic variable $HOME and fails the assignment.
    function Strip-UserHome-PL([string]$s){
        $out=[string]$s
        foreach($h in (Get-PLRealHomes)){
            try{$out=([regex]::new([regex]::Escape($h),[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Replace($out,'[redacted-user-path]')}
            catch{$out=$out.Replace($h,'[redacted-user-path]')}
        }
        $out=$out -replace '(?i)[A-Za-z]:\\Users\\[^\\\/]+\\','[redacted-user-path]/'
        $out=$out -replace '(?i)/(home|users)/[^/\|\s]+','/[redacted-user-path]'
        return $out
    }
    # Sanitized bounded state text for the advisory request.
    # ORDER (must stay exactly this): (1) secret redaction over the FULL text,
    # (2) home strip (real home literal + generic fallback), (3) length cap.
    # Redaction before the cap is what guarantees a length cut can never leave
    # half a credential or half a user path in the egress; the home strip also
    # runs before the cap so no absolute user path survives truncation.
    # TWO CAPS, TWO DIFFERENT JOBS. The leading `Safe-PL $s 100000` is a
    # fail-safe guard for absurd inputs (giant objective / DoS / memory), NOT
    # the egress limit: for any legitimate text it never bites, and because
    # Safe-PL redacts before it truncates, the redaction has already run inside
    # it before any cut can take effect. The trailing `Safe-PL $s 600` is the
    # egress limit: at most 600 chars cross the seam.
    # FINAL SECURITY CONTRACT (approved by the security-reviewer; encoded in
    # OrchestrationPlannerLoop.tests.ps1 as NT1/NT2/NT3):
    #   C1 no secret in -State: redaction precedes the cut, so no canary
    #      survives whole OR as a fragment.
    #   C2 no REAL process home in -State: the strip precedes the cut, so the
    #      real home never survives whole OR as a fragment, including when it
    #      straddles the 600 boundary.
    #   C3 -State is at most 600 chars.
    #   C4 a CUSTOM (non-real) home path is operator-authored objective text,
    #      not a secret: it may cross egress whole OR be fragmented by the cut
    #      and NO shape is guaranteed either way. A fragment reveals no more
    #      than the whole path already would, so this is an accepted, explicit
    #      security-reviewer decision - do not "fix" it into a shape guarantee.
    function JevStateText-PL($parts){$s=([string](@($parts) -join ' | '));$s=Safe-PL $s 100000;$s=Strip-UserHome-PL $s;return (Safe-PL $s 600)}
    # Closed typed projection of the advisory answers: only the recognized
    # typed keys cross into the record, at most 4 questions.
    function JevAnswerProjection-PL($out){$typed=[ordered]@{};$ans=$null;try{$ans=Get-JevAdvisoryPolicyNode -Doc $out -Name 'answers'}catch{$ans=$null};if($null -eq $ans){return $typed};$n=0;foreach($p in @($ans.PSObject.Properties)){if($n -ge 4){break};$e=[ordered]@{};foreach($k in @('type','choice','noul','score','confidence')){$v=$null;try{$v=Get-JevAdvisoryPolicyNode -Doc $p.Value -Name $k}catch{$v=$null};if($null -eq $v){continue};if($k -ceq 'type'){$e['type']=(Safe-PL $v 16)}else{$e[$k]=$v}};if($e.Count -gt 0){$typed[(Safe-PL $p.Name 40)]=[pscustomobject]$e;$n++}};return $typed}
    try {
        $o=$Options; if($null -eq $o){$o=@{}}
        $d=$Descriptor;$invalidDescriptor=($null -eq $d -or ($d -isnot [System.Collections.IDictionary] -and $d -isnot [pscustomobject]))
        if(-not $invalidDescriptor){foreach($field in @('objective','summary','risk','task_shape','scope','uncertainty')){$v=$null;if($d -is [System.Collections.IDictionary]){if($d.Contains($field)){$v=$d[$field]}}else{$prop=$d.PSObject.Properties[$field];if($prop){$v=$prop.Value}};if($null -ne $v -and ($v -is [array] -or $v -is [System.Collections.IDictionary] -or $v -is [pscustomobject] -or $v -is [ValueType])){$invalidDescriptor=$true;break}}}
        if($invalidDescriptor){$d=@{risk='medium';task_shape='invalid';objective='Invalid descriptor; conservative plan.'}}
        $objective=Safe-PL (Read-PL $d 'objective' (Read-PL $d 'summary' 'Insufficient task detail; clarify scope.')) 500
        if(-not $objective){$objective='Insufficient task detail; clarify scope.'}
        # P38-S2-R3: the egress State is built from the UNTRUNCATED objective
        # source, never from the 500-char plan-record cap. A mid-path cut from
        # that cap could leave an unrecognizable path fragment
        # ("D:\Profiles\Jane Do") that neither the literal home strip nor the
        # generic [A-Za-z]:\Users\ fallback can match, so the fragment would
        # cross egress as unrecognized noise. JevStateText-PL owns the egress
        # order (redaction -> home strip -> 600 cap), so handing it the full
        # text is what guarantees any path is either stripped whole or capped
        # after the strip, never cut apart first.
        $objectiveForState=[string](Read-PL $d 'objective' (Read-PL $d 'summary' 'Insufficient task detail; clarify scope.'))
        if([string]::IsNullOrWhiteSpace($objectiveForState)){$objectiveForState=$objective}
        $stamp=[string](Read-PL $o 'timestamp' '');$dt=[DateTimeOffset]::MinValue;$timestampNote='';if(-not [DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$dt)){$stamp=[DateTime]::UtcNow.ToString('o');$timestampNote='Invalid timestamp replaced with internal UTC.'}else{$stamp=$dt.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)}
        $frame=[ordered]@{objective=$objective;information_missing=([string](Read-PL $d 'summary' '') -eq '' -and [string](Read-PL $d 'objective' '') -eq '')}
        $reuse=Unavailable-PL 'evidence-store-not-requested'
        $reuseLib=Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1'
        if(Test-Path -LiteralPath $reuseLib){try{. $reuseLib;$explicitStore=[string](Read-PL $o 'store_dir' '');$reuseStore='explicit';$reuseDir=$explicitStore;if([string]::IsNullOrWhiteSpace($reuseDir)){$reuseDir=Get-OrchestrationEvidenceDefaultStoreDir;$reuseStore='default'};if(-not [string]::IsNullOrWhiteSpace($reuseDir)){$reuseQueryError=$null;$rr=Find-ReusableOrchestrationEvidence -StoreDir $reuseDir -Scope @((Read-PL $d 'scope' @())) -CurrentSourceFingerprints (Read-PL $d 'source_fingerprints' @{}) -CurrentBaseRevision ([string](Read-PL $d 'base_revision' '')) -CurrentCriteriaHash ([string](Read-PL $d 'criteria_hash' '')) -CurrentEnv (Read-PL $d 'environment' @{}) -Now $stamp -MaxResults 5 -QueryError ([ref]$reuseQueryError);if($rr -isnot [array]){throw 'bad reuse shape'};if(-not [string]::IsNullOrWhiteSpace([string]$reuseQueryError)){$reuse=[pscustomobject]@{status='unavailable';reason='reuse-store-query-failed';store=(Safe-PL $reuseStore 120);remaining='unknown-pending-dispatch'}}else{$reuse=[pscustomobject]@{status='ok';store=(Safe-PL $reuseStore 120);remaining='unknown-pending-dispatch';results=@($rr | Select-Object -First 5)}}}else{$reuse=[pscustomobject]@{status='unavailable';reason='reuse-store-unavailable';store='unavailable';remaining='unknown-pending-dispatch'}}}catch{if(-not [string]::IsNullOrWhiteSpace([string]$reuseQueryError) -and $reuseStore -in @('explicit','default')){$reuse=[pscustomobject]@{status='unavailable';reason='reuse-store-query-failed';store=(Safe-PL $reuseStore 120);remaining='unknown-pending-dispatch'}}else{$reuse=[pscustomobject]@{status='unavailable';reason='reuse-store-unavailable';store='unavailable';remaining='unknown-pending-dispatch'}}}}
        $stageOverrides=Read-PL $o 'stage_results' @{}
        if((Read-PL $stageOverrides 'reuse' $null)){ $reuse=Read-PL $stageOverrides 'reuse' $reuse }
        $simple=Unavailable-PL 'simplicity-library-unavailable';$simpLib=Join-Path $PSScriptRoot 'OrchestrationSimplicityPolicy.ps1';if(Test-Path -LiteralPath $simpLib){try{. $simpLib;$simple=Build-OrchestrationWorkerContractFields -Descriptor $d -Policy (Read-PL $o 'simplicity_policy' $null);if($null -eq $simple -or $simple -isnot [pscustomobject]){throw 'bad simplicity shape'}}catch{$simple=Unavailable-PL 'simplicity-stage-failed'}};if((Read-PL $stageOverrides 'simplicity' $null)){$simple=Read-PL $stageOverrides 'simplicity' $simple}
        $risk=[string](Read-PL $d 'risk' 'medium');if($risk -notin @('low','medium','high','critical')){$risk='unknown'}
        $uncertainty=[string](Read-PL $d 'uncertainty' 'medium');if($uncertainty -notin @('low','medium','high')){$uncertainty='medium'}
        $validation=Unavailable-PL 'validation-library-unavailable';$level='L2';$roles=@('coder','tester','reviewer');$completion=Unavailable-PL 'validation-library-unavailable'
        $valLib=Join-Path $PSScriptRoot 'OrchestrationValidationPolicy.ps1';if(Test-Path -LiteralPath $valLib){try{. $valLib;$vp=Read-PL $o 'validation_policy' $null;$vd=Get-OrchestrationValidationLevel -Descriptor $d -Policy $vp;if($null -eq $vd -or [string]$vd.level -notin @('L0','L1','L2','L3') -or $null -eq $vd.required_roles){throw 'bad validation shape'};$level=[string]$vd.level;$roles=@($vd.required_roles | ForEach-Object {Safe-PL $_ 64});$validation=[pscustomobject]@{status=(Safe-PL $vd.status 40);level=$level;required_roles=$roles;rationale=(Safe-PL $vd.rationale 160)};$completion=Test-OrchestrationCompletionPolicy -Level $level -CompletedRoles @() -Descriptor $d -Policy $vp;if($null -eq $completion -or $null -eq $completion.allowed){throw 'bad completion shape'}}catch{$validation=Unavailable-PL 'validation-stage-failed';$completion=Unavailable-PL 'completion-stage-failed';$level='L3';$roles=@('coder','tester','reviewer','security-reviewer')}};if((Read-PL $stageOverrides 'validation' $null)){$validation=Read-PL $stageOverrides 'validation' $validation;$level='L3';$roles=@('coder','tester','reviewer','security-reviewer');$completion=Unavailable-PL 'completion-stage-failed'}
        $mode=Unavailable-PL 'execution-mode-library-unavailable';$modeLib=Join-Path $PSScriptRoot 'OrchestrationExecutionModes.ps1';if(Test-Path -LiteralPath $modeLib){try{. $modeLib;$mode=Get-OrchestrationExecutionMode -Descriptor $d -Policy (Read-PL $o 'execution_mode_policy' $null);if($null -eq $mode -or [string]$mode.mode -notin @('A','B','C') -or [string]::IsNullOrWhiteSpace([string]$mode.rationale)){throw 'bad mode shape'}}catch{$mode=Unavailable-PL 'execution-mode-stage-failed'}};if((Read-PL $stageOverrides 'execution_mode' $null)){$mode=Read-PL $stageOverrides 'execution_mode' $mode}
        foreach($stageName in @('reuse','simplicity','validation','execution_mode','complete_requirements')){$stageValue=Read-PL $stageOverrides $stageName $null;if($null -ne $stageValue -and $stageValue -isnot [pscustomobject] -and $stageValue -isnot [System.Collections.IDictionary]){switch($stageName){'reuse'{$reuse=Unavailable-PL 'malformed-stage-result'};'simplicity'{$simple=Unavailable-PL 'malformed-stage-result'};'validation'{$validation=Unavailable-PL 'malformed-stage-result';$level='L3';$roles=@('coder','tester','reviewer','security-reviewer');$completion=Unavailable-PL 'malformed-stage-result'};'execution_mode'{$mode=Unavailable-PL 'malformed-stage-result'};'complete_requirements'{$completion=Unavailable-PL 'malformed-stage-result'}}}}
        $completionOverride=Read-PL $stageOverrides 'complete_requirements' $null;if($null -ne $completionOverride -and ($completionOverride -is [pscustomobject] -or $completionOverride -is [System.Collections.IDictionary])){$completion=$completionOverride}
        $vOverride=Read-PL $stageOverrides 'validation' $null;if($null -ne $vOverride -and ($vOverride -is [pscustomobject] -or $vOverride -is [System.Collections.IDictionary])){if([string](Read-PL $vOverride 'level' '') -in @('L0','L1','L2','L3') -and $null -ne (Read-PL $vOverride 'required_roles' $null)){$level=[string](Read-PL $vOverride 'level' 'L3');$roles=@((Read-PL $vOverride 'required_roles' @()) | ForEach-Object {Safe-PL $_ 64});$validation=$vOverride}else{$validation=Unavailable-PL 'malformed-stage-result';$level='L3';$roles=@('coder','tester','reviewer','security-reviewer');$completion=Unavailable-PL 'malformed-stage-result'}}
        $budgetAvailable=[bool](Read-PL $d 'validation_budget_available' $true);$budget=[ordered]@{status='record-only';validation_reserved=$budgetAvailable;review_reserved=$budgetAvailable;reserved_before_dispatch=$true;note='Reservation declared only; no execution/budget mutation.'}
        $nontrivial=($level -notin @('L0','L1') -or $risk -in @('medium','high','critical','unknown'))
        $independent=[bool](Read-PL $d 'work_independent' $false);$ownershipClear=[bool](Read-PL $d 'ownership_clear' $false);$shared=[bool](Read-PL $d 'shared_state' $true);$latency=[bool](Read-PL $d 'latency_benefit' $false);$synthesis=[bool](Read-PL $d 'synthesis_affordable' $false)
        $parallel=($independent -and $ownershipClear -and -not $shared -and $latency -and $synthesis -and $budgetAvailable -and $nontrivial)
        $workers=@('coder');if($nontrivial){$workers=@('coder','tester');if($level -in @('L2','L3')){$workers+=@('reviewer')};if($level -eq 'L3'){$workers+=@('security-reviewer')}}
        if(-not $budgetAvailable){$workers=@('coder');$parallel=$false}
        $dispatch=[ordered]@{workers=@($workers | Select-Object -Unique);parallel_ok=[bool]$parallel;parallel_rationale=$(if($parallel){'Independent ownership, bounded validation budget, latency benefit, no shared state, synthesis affordable.'}else{'Sequential/minimum route: parallel prerequisites not all proven.'});separation_rationale=(Safe-PL (Read-PL $d 'separation_rationale' '') 160);escalations=@()}
        if([bool](Read-PL $d 'information_missing' $frame.information_missing)){$dispatch.recommendation='Explorer/Researcher';$dispatch.escalations=@([pscustomobject]@{type='information-gathering';rationale='Resolve missing information before role/tool/model escalation.'})}
        $jev=Unavailable-PL 'jev-trigger-library-unavailable';$jevLib=Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1';if(Test-Path -LiteralPath $jevLib){try{. $jevLib;$jt=Test-JevAdvisoryTrigger -Descriptor $d;if($null -eq $jt -or $null -eq $jt.should_consult -or [string]::IsNullOrWhiteSpace([string]$jt.trigger_reason)){throw 'bad jev shape'};$jev=[pscustomobject]@{should_consult=[bool]$jt.should_consult;reason=(Safe-PL $jt.trigger_reason 80);jev_advisory=$true;authority='non-authoritative-recommendation'}}catch{$jev=Unavailable-PL 'jev-trigger-stage-failed'}};if((Read-PL $stageOverrides 'jev' $null)){$jev=Read-PL $stageOverrides 'jev' $jev};$jevOverride=Read-PL $stageOverrides 'jev' $null;if($null -ne $jevOverride -and $jevOverride -isnot [pscustomobject] -and $jevOverride -isnot [System.Collections.IDictionary]){$jev=Unavailable-PL 'malformed-stage-result'}
        # P38-S2 caller wiring: the Jev lib owns EVERY gate (trigger, flag
        # mode, credential, envelope, circuit, sanitized evidence). This loop
        # only projects a sanitized bounded state, calls ONCE and records the
        # typed envelope. No gate is duplicated here, no retry, no loop.
        $jevToolName='jev_decide'
        $jevAdvisory=JevNotConsulted-PL 'jev-advisory-not-triggered'
        if([bool](Read-PL $jev 'should_consult' $false) -and ($null -eq (Read-PL $stageOverrides 'jev' $null))){try{
            if((Get-Command Invoke-McpSafetyCall -ErrorAction SilentlyContinue) -eq $null){$envLib=Join-Path $PSScriptRoot 'OrchestrationMcpSafety.ps1';if(Test-Path -LiteralPath $envLib){. $envLib}}
            $flagNode=Get-JevAdvisoryFlag -FlagsPath (Get-JevAdvisoryDefaultFlagsPath -RepoRoot $root) -RepoRoot $root
            if([bool]$flagNode.found){
                $state=JevStateText-PL @('planner turn advisory request',('objective: '+$objectiveForState),('task_shape: '+([string](Read-PL $d 'task_shape' 'unspecified'))),('risk: '+$risk),('uncertainty: '+$uncertainty),('trigger: '+([string](Read-PL $jev 'reason' ''))),('mode: '+([string]$mode.mode)),('workers: '+(@($workers) -join '/')),('parallel_ok: '+([string]$parallel)))
                $questions=[ordered]@{route=[ordered]@{type='choice';instructions='Which planner route should the harness use for this turn?';criteria=[ordered]@{minimal='sequential minimum route';parallel='parallel fan-out with every gate proven';research='gather the missing information first'}};escalation=[ordered]@{type='score';instructions='How much validation rigor does this turn need?';criteria=@('L1','L2','L3')}}
                $turnId='planner-jev-advisory'
                try{$jh=Get-JevAdvisoryInputHash -Tool $jevToolName -TriggerReason ([string](Read-PL $jev 'reason' '')) -Descriptor $d;if(-not [string]::IsNullOrWhiteSpace([string]$jh)){$turnId='planner-'+([string]$jh).Substring(0,24)}}catch{}
                $raw=Invoke-JevAdvisoryCall -Tool $jevToolName -TurnId $turnId -Descriptor $d -State $state -ToolArgs @{questions=$questions} -Probe $JevAdvisoryProbe -ProbeArgs @($jevToolName,$state,$questions,[int]$JevAdvisoryBudgetSecondsOverride) -PolicyPath (Get-JevAdvisoryDefaultPolicyPath -RepoRoot $root) -FlagsPath (Get-JevAdvisoryDefaultFlagsPath -RepoRoot $root) -RepoRoot $root -TelemetryRoot ([string](Read-PL $o 'jev_advisory_telemetry_root' '')) -BudgetSecondsOverride ([int]$JevAdvisoryBudgetSecondsOverride)
                if($null -eq $raw){throw 'empty-jev-envelope'}
                $consulted=[bool](Read-PL $raw 'consulted' $false);$rawOut=Read-PL $raw 'output' $null;$budgetS=0
                try{$budgetS=[int](Read-PL $raw 'budget_s' 0)}catch{$budgetS=0}
                $sum='no-advisory-recommendation'
                if($consulted -and ($null -ne $rawOut)){try{$sum=Safe-PL (Get-JevAdvisoryOutputSummary -Tool ([string](Read-PL $raw 'tool' $jevToolName)) -Output $rawOut) 120}catch{$sum='advisory-summary-unavailable'};if([string]::IsNullOrWhiteSpace($sum)){$sum='advisory-summary-unavailable'}}
                $jevAdvisory=[ordered]@{status=(Safe-PL (Read-PL $raw 'status' 'JEV_UNAVAILABLE') 48);failure=(Safe-PL (Read-PL $raw 'failure' '') 48);consulted=$consulted;would_consult=[bool](Read-PL $raw 'would_consult' $false);fallback_continue=[bool](Read-PL $raw 'fallback_continue' $true);blocked=[bool](Read-PL $raw 'blocked' $false);tool=(Safe-PL (Read-PL $raw 'tool' $jevToolName) 24);mode=(Safe-PL (Read-PL $raw 'mode' '') 16);circuit=(Safe-PL (Read-PL $raw 'circuit' '') 16);budget_s=$budgetS;recommendation=$sum;answers=[pscustomobject](JevAnswerProjection-PL $rawOut);authoritative=$false;recommendation_only=$true}
            }else{$jevAdvisory=JevNotConsulted-PL 'jev-advisory-flag-absent'}
        }catch{$jevAdvisory=JevNotConsulted-PL 'jev-advisory-call-failed'}}
        $missing=@($roles)
        if($invalidDescriptor){$level='L2';$roles=@('coder','tester','reviewer');$completion=Unavailable-PL 'invalid-descriptor-conservative';$mode=[pscustomobject]@{mode='C';rationale='Invalid descriptor; conservative fallback.'};$workers=@('coder');$parallel=$false;$validation=[pscustomobject]@{status='unavailable';level='L2';required_roles=$roles};$dispatch.workers=$workers;$dispatch.parallel_ok=$false;$dispatch.escalations=@()}
        $plan=[ordered]@{frame=$frame;reuse=$reuse;simplicity=[pscustomobject]@{status='ok';contract=$simple};risk_uncertainty=[ordered]@{risk=$risk;uncertainty=$uncertainty};execution_mode=$mode;budget_reservation=$budget;dispatch_plan=$dispatch;validation=[pscustomobject]@{status=$validation.status;level=$level;required_roles=$roles};validation_gaps=[ordered]@{missing_roles=$roles;missing_evidence=@()};complete_requirements=$completion;jev_triggers=$jev;jev_advisory=[ordered]@{authoritative=$false;kernel_authority='planner/kernel';recommendation_only=$true};jev_advisory_result=$jevAdvisory;stop_condition=(Safe-PL (Read-PL $d 'stop_condition' 'Stop when sufficient evidence supports the current decision; do not expand scope.') 300);generated_at=(Safe-PL $stamp 80);timestamp_note=$timestampNote}
        $plan=Clean-PL $plan
        $json=ConvertTo-Json -InputObject $plan -Depth 16 -Compress
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192){$plan.reuse=Unavailable-PL 'discarded-plan-size';$plan.simplicity=[pscustomobject]@{status='unavailable';reason='discarded-plan-size'};$plan.jev_triggers=Unavailable-PL 'discarded-plan-size';$plan.jev_advisory_result=JevNotConsulted-PL 'discarded-plan-size';$plan.validation_gaps.missing_evidence=@();$json=ConvertTo-Json -InputObject $plan -Depth 12 -Compress}
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192){$plan.frame.objective='[truncated]';$plan.dispatch_plan.separation_rationale='';$json=ConvertTo-Json -InputObject $plan -Depth 8 -Compress}
        $oversized=$false
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192){
            $oversized=$true
            # Last resort is a distinct minimal valid record, never a partial JSON string.
            $ref=Safe-PL (Read-PL $d 'task_ref' (Read-PL $d 'task_id' 'unknown')) 120
            $plan=[ordered]@{status='oversized';truncated=$true;oversized=$true;task_ref=([string]$ref.Length+':'+$ref);generated_at=(Safe-PL $stamp 80)}
            $json=ConvertTo-Json -InputObject $plan -Depth 4 -Compress
        }
        return [pscustomobject]@{status=$(if($oversized){'oversized'}else{'ok'});plan=[pscustomobject]$plan;plan_json=$json;byte_length=[Text.Encoding]::UTF8.GetByteCount($json);bounded=([Text.Encoding]::UTF8.GetByteCount($json) -le 8192);truncated=[bool]$oversized;oversized=[bool]$oversized;discard_order=@('reuse results','simplicity details','Jev trigger detail','optional rationale','free text progressive len:value truncation','replace with minimum valid envelope')}
    } catch {return [pscustomobject]@{status='error';plan=$null;reason='planner-loop-failed'}}
}
