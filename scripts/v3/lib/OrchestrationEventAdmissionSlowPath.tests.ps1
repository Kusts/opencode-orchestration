$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionSlowPath.ps1')
$script:count=0
function A($v,$m){$script:count++;if(!$v){throw "FAIL: $m"}}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$real=Import-OrchestrationEventAdmissionSlowPathPolicy -RepoRoot $root;A ($real.ok -and !$real.policy.enabled) 'default disabled'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $tmp)
try{
 $path=Join-Path $tmp 'policy.json';$policyJson=ConvertTo-Json -InputObject ([ordered]@{schema_version=1;policy_version='1';enabled=$true;min_confidence=0.7;max_summary_chars=8;max_rationale_chars=12;max_requests_per_day=10;max_requests_per_thread=10;classes=@('candidate','context_only','ignore')}) -Compress;[IO.File]::WriteAllText($path,$policyJson,[Text.UTF8Encoding]::new($false));$loaded=Import-OrchestrationEventAdmissionSlowPathPolicy $path;A $loaded.ok 'valid policy'
 $e=New-OrchestrationEventEnvelope github issue_comment pr:12 delivery-1 a/b -Summary 'secret=foo longer';$c=@{actor_type='human';source_allowlisted=$true;blocklisted=$false;duplicate=$false};$f=@{ok=$true;intent='context_only';signals=@('ambiguous')};$usage=@{requests_today=0;requests_for_thread=0};$req=Request-OrchestrationEventAdmissionSlowPath $e $c $f $loaded.policy $usage;A ($req.decision -eq 'request' -and $req.request.request_digest -match '^[0-9a-f]{64}$') 'request+digest';A ($req.request.summary.Length -le 8 -and $req.request.summary -notmatch 'foo') 'redacted and truncated';A ((ConvertTo-Json $req -Compress) -ceq (ConvertTo-Json (Request-OrchestrationEventAdmissionSlowPath $e $c $f $loaded.policy $usage) -Compress)) 'deterministic'
 $base=@{request_digest=$req.request.request_digest;classification='candidate';confidence=0.9;rationale='ok'};$valid=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $base $loaded.policy;A ($valid.ok -and $valid.action -eq 'would_new_task' -and !$valid.executable) 'candidate shadow'
 $bad=$base.Clone();$bad.confidence=1.1;A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $bad $loaded.policy).error -eq 'SLOWPATH_CONFIDENCE_INVALID') 'confidence bound';$bad=$base.Clone();$bad.extra=1;A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $bad $loaded.policy).error -eq 'SLOWPATH_RESPONSE_INVALID') 'unknown response field'
 $bad=$base.Clone();$bad.classification='alien';A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $bad $loaded.policy).error -eq 'SLOWPATH_CLASS_INVALID') 'class validation';$bad=$base.Clone();$bad.request_digest=('0'*64);A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $bad $loaded.policy).error -eq 'SLOWPATH_DIGEST_MISMATCH') 'digest validation'
 $low=$base.Clone();$low.confidence=0.2;$result=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $low $loaded.policy;A ($result.ok -and $result.intent -eq 'context_only' -and $result.reason -eq 'low-confidence') 'low confidence'
 $c.actor_type='bot';A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $loaded.policy $usage).reason -eq 'bot') 'bot';$c.actor_type='human';$usage.requests_today=10;A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $loaded.policy $usage).reason -eq 'usage-cap') 'usage cap'
 $disabled=Import-OrchestrationEventAdmissionSlowPathPolicy -RepoRoot $root;A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $disabled.policy $usage).reason -eq 'policy-disabled') 'disabled gate'
 $badpath=Import-OrchestrationEventAdmissionSlowPathPolicy '\\host\share\policy.json';A ($badpath.error -eq 'SLOWPATH_POLICY_PATH_INVALID') 'UNC rejected'
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
Write-Host "PASS OrchestrationEventAdmissionSlowPath $script:count assertions"
