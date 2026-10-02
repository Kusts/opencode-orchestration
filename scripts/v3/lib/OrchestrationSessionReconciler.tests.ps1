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
Write-Output "PASS: $script:passed assertions"
