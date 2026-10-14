$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationSessionReconciler.ps1')
$script:passed=0
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
$fixed='2026-10-02T12:00:00Z'
$e=New-OrchestrationContinuationEnvelope -TaskId 'task-1' -Objective 'build' -UserIntent 'user goal' -Decisions @('d1') -ValidEvidenceRefs @('ref1') -FailedStrategies @(@{strategy_id='s1';fingerprint='fp1';reason='failed'}) -ActiveRisks @('risk') -PendingWaits @(@{type='approval';owner='planner';action='review';dependency_id='d2'}) -NextMove 'continue' -TimestampUtc $fixed
Assert ($e.task_id -eq 'task-1' -and $e.pending_waits[0].type -eq 'approval' -and $e.failed_strategies[0].fingerprint -eq 'fp1') 'full envelope'
Assert ($e.generated_at -match '^2026-10-02T12:00:00') 'injected timestamp value'
$bad=@('host example.com','host example.dev','host example.local','token=creds','token=0123456789abcdef0123456789abcdef','sk-12345678901234567890','sk-proj-12345678901234567890',"User: private transcript line`nAssistant: response",'### Human: private transcript line')
$sensitive='example\.(com|dev|local)|token=creds|0123456789abcdef0123456789abcdef|sk-(proj-)?12345678901234567890|private transcript line|### Human:'
$stringFields=@('TaskId','Objective','UserIntent','Decisions','ValidEvidenceRefs','ActiveRisks','NextMove','StrategyId','Fingerprint','Reason','WaitType','WaitOwner','WaitAction','DependencyId','GeneratedAt')
foreach($field in $stringFields){foreach($payload in $bad){
    $args=@{TaskId='task-safe';Objective='o';UserIntent='u';Decisions=@('d');ValidEvidenceRefs=@('ref');FailedStrategies=@(@{strategy_id='strategy';fingerprint='fp';reason='reason'});ActiveRisks=@('risk');PendingWaits=@(@{type='type';owner='owner';action='action';dependency_id='dep'});NextMove='next';TimestampUtc=$fixed}
    if($field -eq 'GeneratedAt'){$json=ConvertTo-Json @{generated_at=(Protect-ContinuationText $payload)} -Compress;Assert ($json -notmatch $sensitive) 'redaction field GeneratedAt';continue}
    switch($field){
        'TaskId' {$args.TaskId=$payload}
        'Objective' {$args.Objective=$payload}
        'UserIntent' {$args.UserIntent=$payload}
        'Decisions' {$args.Decisions=@($payload)}
        'ValidEvidenceRefs' {$args.ValidEvidenceRefs=@($payload)}
        'ActiveRisks' {$args.ActiveRisks=@($payload)}
        'NextMove' {$args.NextMove=$payload}
        'StrategyId' {$args.FailedStrategies=@(@{strategy_id=$payload;fingerprint='fp';reason='reason'})}
        'Fingerprint' {$args.FailedStrategies=@(@{strategy_id='strategy';fingerprint=$payload;reason='reason'})}
        'Reason' {$args.FailedStrategies=@(@{strategy_id='strategy';fingerprint='fp';reason=$payload})}
        'WaitType' {$args.PendingWaits=@(@{type=$payload;owner='owner';action='action';dependency_id='dep'})}
        'WaitOwner' {$args.PendingWaits=@(@{type='type';owner=$payload;action='action';dependency_id='dep'})}
        'WaitAction' {$args.PendingWaits=@(@{type='type';owner='owner';action=$payload;dependency_id='dep'})}
        'DependencyId' {$args.PendingWaits=@(@{type='type';owner='owner';action='action';dependency_id=$payload})}
    }
    $json=ConvertTo-Json (New-OrchestrationContinuationEnvelope @args) -Depth 12 -Compress
    Assert ($json -notmatch $sensitive) ("redaction field $field")
}}
$large=New-OrchestrationContinuationEnvelope -TaskId t -Objective ('x'*1000) -Decisions @('d'*1000) -ValidEvidenceRefs @('e'*1000) -FailedStrategies @(@{strategy_id='s';fingerprint='f';reason=('r'*1000)}) -ActiveRisks @('a'*1000) -PendingWaits @(@{type='t';owner='o';action=('z'*1000);dependency_id='d'}) -ByteBudget 500 -TimestampUtc $fixed
Assert ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $large -Depth 12 -Compress)) -le 500) 'bounded envelope'
Assert ($large.truncated -and $large.failed_strategies.Count -eq 0 -and $large.decisions.Count -eq 0) 'documented discard priority'
$binding=@{task_id='t';run_id='r';session_id='child';worker_sessions=@('child');root_session=''}
$lost=New-OrchestrationSessionLostAttemptResult -Binding $binding -Observation @{observed='missing'} -AbsenceProven $true -TimestampUtc $fixed
Assert ($lost.result_type -eq 'SESSION_LOST' -and -not $lost.task_state_mutated -and $lost.registration -eq 'caller_must_register_with_kernel') 'typed lost result'
Assert (-not (New-OrchestrationSessionLostAttemptResult -Binding $binding -Observation @{observed='running'} -AbsenceProven $true).ok) 'lost proof required'
$runs=@(@{run_id='r1';root_session='';worker_sessions=@('done','live','gone','stale','sibling')})
$obs=@(@{session_id='done';observed='completed';output_ref='out-1'},@{session_id='live';observed='running'},@{session_id='stale';observed='running';binding_session_id='other'},@{session_id='sibling';observed='completed';output_ref='out-2'})
$rec=Get-OrchestrationSessionReconciliation -Bindings $runs -Observations $obs -StaleAfterSeconds 60 -TimestampUtc $fixed
Assert (($rec.runs | Where-Object session_id -eq done).status -eq 'completed') 'completed child'
Assert (($rec.recommended_actions | Where-Object session_id -eq live).action -eq 'reattach') 'running recommends reattach'
Assert (($rec.recommended_actions | Where-Object session_id -eq gone).action -eq 'mark_SESSION_LOST') 'missing recommends lost'
Assert (($rec.runs | Where-Object session_id -eq stale).status -eq 'stale') 'ownership mismatch stale'
Assert (($rec.runs | Where-Object session_id -eq sibling).output_ref -eq 'out-2') 'sibling completion retained'
Assert (($rec.recommended_actions | Where-Object session_id -eq done).action -eq 'recover-output') 'completed output recovery action'
Assert (($rec.recommended_actions | Where-Object session_id -eq sibling).output_ref_missing -eq $false) 'output ref present'
Assert ((Get-OrchestrationSessionReconciliation -Bindings @(@{run_id='z';root_session='blank';worker_sessions=@()}) -Observations @(@{session_id='blank';observed='completed'}) -StaleAfterSeconds 60 -TimestampUtc $fixed).recommended_actions[0].output_ref_missing) 'completed without output flagged'
Assert ((Get-OrchestrationSessionReconciliation -Bindings @(@{run_id='z';root_session='int';worker_sessions=@()}) -Observations @(@{session_id='int';observed='interrupted';attempt_ref='att-1'}) -StaleAfterSeconds 60 -TimestampUtc $fixed).recommended_actions[0].attempt_ref -eq 'att-1') 'interrupted attempt inspect action'
Assert ((ConvertTo-Json $rec -Depth 10 -Compress) -eq (ConvertTo-Json (Get-OrchestrationSessionReconciliation -Bindings $runs -Observations $obs -StaleAfterSeconds 60 -TimestampUtc $fixed) -Depth 10 -Compress)) 'reconciliation deterministic timestamp'
Assert ((Get-OrchestrationSessionReconciliation -Bindings @((1..250 | ForEach-Object {@{run_id="r$_";root_session="s$_";worker_sessions=@()}})) -StaleAfterSeconds 60 -TimestampUtc $fixed).status -eq 'input-limit-exceeded') 'binding input cap fail closed'
Assert ((Get-OrchestrationSessionReconciliation -Bindings @() -Observations @((1..501 | ForEach-Object {@{session_id="s$_";observed='missing'}})) -StaleAfterSeconds 60 -TimestampUtc $fixed).status -eq 'input-limit-exceeded') 'observation input cap fail closed'
Assert (-not $rec.probed) 'no probe'
$plan=New-OrchestrationContinuationPlan -Envelope $e -Runtime 1 -EnvelopeRef 'env-ref'
Assert ($plan.mode -eq 'fresh-session' -and -not $plan.native_resume -and $plan.task_id -eq 'task-1') 'V1 fresh session only'
$again=New-OrchestrationContinuationEnvelope -TaskId 'task-1' -Objective 'build' -TimestampUtc $fixed
Assert ((ConvertTo-Json $again -Compress) -eq (ConvertTo-Json (New-OrchestrationContinuationEnvelope -TaskId 'task-1' -Objective 'build' -TimestampUtc $fixed) -Compress)) 'deterministic'
# F2 regression: duplicate/out-of-order observations must fail closed as ambiguous (no last-wins, no timestamp heuristic)
function Assert-AmbiguousRow([object]$Rec,[string]$Sid,[string]$Name){
    $row=$Rec.runs | Where-Object session_id -eq $Sid
    Assert (($row.status -eq 'stale') -and ($row.detail -eq 'ambiguous_observations') -and ([string]::IsNullOrWhiteSpace([string]$row.output_ref))) ("F2 ambiguous $Name")
    Assert ((@($Rec.recommended_actions | Where-Object session_id -eq $Sid)).Count -eq 0) ("F2 no action $Name")
}
$dupRuns=@(@{run_id='orfs-diag';root_session='ses_diag';worker_sessions=@()})
$dupA=@(@{session_id='ses_diag';observed='completed';output_ref='artifact-ref'},@{session_id='ses_diag';observed='missing'})
$dupB=@(@{session_id='ses_diag';observed='missing'},@{session_id='ses_diag';observed='completed';output_ref='artifact-ref'})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $dupRuns -Observations $dupA -StaleAfterSeconds 60 -TimestampUtc $fixed) 'ses_diag' 'completed/missing order A'
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $dupRuns -Observations $dupB -StaleAfterSeconds 60 -TimestampUtc $fixed) 'ses_diag' 'completed/missing order B'
$runB=@(@{session_id='s_rc';observed='running'},@{session_id='s_rc';observed='completed';output_ref='o1'})
$runC=@(@{session_id='s_rc';observed='completed';output_ref='o1'},@{session_id='s_rc';observed='running'})
$bindRc=@(@{run_id='rrc';root_session='s_rc';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindRc -Observations $runB -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_rc' 'running/completed order A'
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindRc -Observations $runC -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_rc' 'running/completed order B'
$bindOut=@(@{run_id='rout';root_session='s_out';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindOut -Observations @(@{session_id='s_out';observed='completed';output_ref='out-A'},@{session_id='s_out';observed='completed';output_ref='out-B'}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_out' 'conflicting output_ref'
$bindOwn=@(@{run_id='rown';root_session='s_own';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindOwn -Observations @(@{session_id='s_own';observed='completed';output_ref='o'},@{session_id='s_own';observed='completed';output_ref='o';binding_session_id='other'}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_own' 'conflicting ownership'
$bindLs=@(@{run_id='rls';root_session='s_ls';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindLs -Observations @(@{session_id='s_ls';observed='completed';output_ref='o'},@{session_id='s_ls';observed='completed';output_ref='o';last_seen='not-a-date'}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_ls' 'invalid last_seen among duplicates'
$bindType=@(@{run_id='rty';root_session='s_ty';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindType -Observations @(@{session_id='s_ty';observed='completed';output_ref='o1'},@{session_id='s_ty';observed='completed';output_ref=@('o1')}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_ty' 'malformed output_ref type'
$bindEq=@(@{run_id='req';root_session='s_eq';worker_sessions=@()})
$eqA=@{session_id='s_eq';observed='completed';output_ref='o-eq';foo='irrelevant-1'}
$eqB=[pscustomobject]@{session_id='s_eq';observed='completed';output_ref='o-eq';bar='irrelevant-2'}
$eqRec=Get-OrchestrationSessionReconciliation -Bindings $bindEq -Observations @($eqA,$eqB) -StaleAfterSeconds 60 -TimestampUtc $fixed
Assert ((($eqRec.runs | Where-Object session_id -eq s_eq).status -eq 'completed') -and (($eqRec.runs | Where-Object session_id -eq s_eq).output_ref -eq 'o-eq')) 'F2 equivalent duplicates collapse'
Assert ((($eqRec.recommended_actions | Where-Object session_id -eq s_eq).action -eq 'recover-output')) 'F2 equivalent duplicates action'
# F2-R1: session_id matching is ordinal case-exact (ses_x vs SES_X are distinct; no cross-case hiding)
$bindCase=@(@{run_id='rcase';root_session='ses_x';worker_sessions=@('SES_X')})
$obsCaseA=@(@{session_id='ses_x';observed='completed';output_ref='o-low'},@{session_id='SES_X';observed='completed';output_ref='o-up'})
$obsCaseB=@(@{session_id='SES_X';observed='completed';output_ref='o-up'},@{session_id='ses_x';observed='completed';output_ref='o-low'})
foreach($pair in @($obsCaseA,$obsCaseB)){
    $cr=Get-OrchestrationSessionReconciliation -Bindings $bindCase -Observations $pair -StaleAfterSeconds 60 -TimestampUtc $fixed
    Assert (($cr.runs.Count -eq 2) -and ($cr.runs[0].session_id -ceq 'ses_x') -and ($cr.runs[0].status -eq 'completed') -and ($cr.runs[0].output_ref -eq 'o-low')) 'F2 ordinal exact ses_x row'
    Assert (($cr.runs[1].session_id -ceq 'SES_X') -and ($cr.runs[1].status -eq 'completed') -and ($cr.runs[1].output_ref -eq 'o-up')) 'F2 ordinal exact SES_X row'
}
$bindCross=@(@{run_id='rcross';root_session='ses_x';worker_sessions=@()})
$crossRec=Get-OrchestrationSessionReconciliation -Bindings $bindCross -Observations @(@{session_id='SES_X';observed='completed';output_ref='o-up'}) -StaleAfterSeconds 60 -TimestampUtc $fixed
Assert (($crossRec.runs[0].status -eq 'missing') -and ($crossRec.recommended_actions[0].action -eq 'mark_SESSION_LOST') -and ($crossRec.recommended_actions[0].session_id -ceq 'ses_x')) 'F2 cross-case no hidden observation'
# F2-R2: duplicates scope rejects non-string scalars (no array/type coercion, no false-as-absent); unique path untouched
$bindArr2=@(@{run_id='rarr2';root_session='s_arr2';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindArr2 -Observations @(@{session_id='s_arr2';observed='completed';output_ref=@('o1')},@{session_id='s_arr2';observed='completed';output_ref=@('o1')}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_arr2' 'identical array output_ref stays ambiguous'
$bindObs2=@(@{run_id='robs2';root_session='s_obs2';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindObs2 -Observations @(@{session_id='s_obs2';observed=@('completed');output_ref='o'},@{session_id='s_obs2';observed=@('completed');output_ref='o'}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_obs2' 'identical array observed stays ambiguous'
$bindBnd2=@(@{run_id='rbnd2';root_session='s_bnd2';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindBnd2 -Observations @(@{session_id='s_bnd2';observed='completed';output_ref='o';binding_session_id=@('s_bnd2')},@{session_id='s_bnd2';observed='completed';output_ref='o';binding_session_id=@('s_bnd2')}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_bnd2' 'identical array binding stays ambiguous'
$bindFls=@(@{run_id='rfls';root_session='s_fls';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindFls -Observations @(@{session_id='s_fls';observed='completed';output_ref='o';last_seen=$false},@{session_id='s_fls';observed='completed';output_ref='o';last_seen=$false}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_fls' 'identical bool last_seen stays ambiguous'
$bindZls=@(@{run_id='rzls';root_session='s_zls';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindZls -Observations @(@{session_id='s_zls';observed='completed';output_ref='o';last_seen=0},@{session_id='s_zls';observed='completed';output_ref='o';last_seen=0}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_zls' 'identical zero last_seen stays ambiguous'
$bindRev=@(@{run_id='rrev';root_session='s_rev';worker_sessions=@()})
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindRev -Observations @(@{session_id='s_rev';observed='completed';output_ref=@('o1')},@{session_id='s_rev';observed='completed';output_ref='o1'}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_rev' 'reversed array/string output A'
Assert-AmbiguousRow (Get-OrchestrationSessionReconciliation -Bindings $bindRev -Observations @(@{session_id='s_rev';observed='completed';output_ref='o1'},@{session_id='s_rev';observed='completed';output_ref=@('o1')}) -StaleAfterSeconds 60 -TimestampUtc $fixed) 's_rev' 'reversed array/string output B'
Write-Output "PASS: $script:passed assertions"
