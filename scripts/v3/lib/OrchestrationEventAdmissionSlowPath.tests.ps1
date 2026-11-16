$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionSlowPath.ps1')
$script:count=0
function A($v,$m){$script:count++;
  if(!$v){throw "FAIL: $m"}}
function Copy-Request($request){$copy=[ordered]@{};
  foreach($property in $request.PSObject.Properties){$copy[$property.Name]=$property.Value};
  return $copy}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$real=Import-OrchestrationEventAdmissionSlowPathPolicy -RepoRoot $root;
  A ($real.ok -and !$real.policy.enabled) 'default disabled'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'));
  $target=Join-Path $tmp 'target';
  [void](New-Item -ItemType Directory $target);
  $link=Join-Path $tmp 'link';
  $linked=$false
try{
 $base=@{schema_version=1;
  policy_version='1';
  enabled=$true;
  min_confidence=0.7;
  max_summary_chars=20;
  max_rationale_chars=12;
  max_requests_per_day=2;
  max_requests_per_thread=2;
  classes=@('candidate','context_only','ignore')}
 function Write-Policy($doc){$p=Join-Path $tmp (([guid]::NewGuid().ToString('N'))+'.json');
  [IO.File]::WriteAllText($p,(ConvertTo-Json -InputObject $doc -Depth 8 -Compress),[Text.UTF8Encoding]::new($false));
  return $p}
 $path=Write-Policy $base;
  $loaded=Import-OrchestrationEventAdmissionSlowPathPolicy $path;
  A $loaded.ok 'valid policy'
 A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Join-Path $tmp 'missing.json')).error -eq 'SLOWPATH_POLICY_PATH_NOT_FOUND') 'missing policy'
 $mal=Join-Path $tmp 'malformed.json';
  [IO.File]::WriteAllText($mal,'{');
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy $mal).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') 'invalid json schema'
 $big=Join-Path $tmp 'big.json';
  [IO.File]::WriteAllText($big,(' '*20));
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy $big -MaxBytes 10).error -eq 'SLOWPATH_POLICY_TOO_LARGE') 'max bytes'
 foreach($sv in @('"1"','1.0')){$bad=Join-Path $tmp 'schema.json';
  $doc=ConvertTo-Json -InputObject $base -Compress;
  $doc=$doc -replace '"schema_version":1',('"schema_version":'+$sv);
  [IO.File]::WriteAllText($bad,$doc);
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy $bad).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') ('schema type '+$sv)}
 $d=[ordered]@{};
  foreach($k in $base.Keys){if($k -cne 'min_confidence'){$d[$k]=$base[$k]}};
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Write-Policy $d)).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') 'missing required key'
 $d=$base.Clone();
  $d.extra=1;
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Write-Policy $d)).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') 'unknown policy key'
 foreach($classes in @(@('candidate','candidate'),@('candidate','bogus'))){$d=$base.Clone();
  $d.classes=$classes;
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Write-Policy $d)).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') 'invalid classes'}
 foreach($conf in @(1.1,$true)){$d=$base.Clone();
  $d.min_confidence=$conf;
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Write-Policy $d)).error -eq 'SLOWPATH_POLICY_SCHEMA_INVALID') 'invalid policy confidence'}
 [IO.File]::WriteAllText((Join-Path $target 'policy.json'),(ConvertTo-Json -InputObject $base -Compress),[Text.UTF8Encoding]::new($false));
  New-Item -ItemType Junction -Path $link -Target $target|Out-Null;
  $linked=$true;
  A ((Import-OrchestrationEventAdmissionSlowPathPolicy (Join-Path $link 'policy.json')).error -eq 'SLOWPATH_POLICY_PATH_INVALID') 'junction rejected'
 $e=New-OrchestrationEventEnvelope github issue_comment pr:12 delivery-1 a/b -Summary 'secret=foo and more than twenty chars';
  $c=@{actor_type='human';
  source_allowlisted=$true;
  blocklisted=$false;
  duplicate=$false};
  $f=@{ok=$true;
  intent='context_only';
  signals=@('ambiguous')};
  $usage=@{requests_today=1;
  requests_for_thread=1};
  $pol=$loaded.policy
  $req=Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage;
  A ($req.decision -eq 'request' -and $req.request.request_digest -match '^[0-9a-f]{64}$') 'request digest';
  A ($req.request.summary.Length -le 20 -and $req.request.summary.Contains('[REDACTED]')) 'redacted and truncated';
  $serial=ConvertTo-Json $req -Compress;
  for($i=0;$i -lt 2;$i++){A ((ConvertTo-Json (Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage) -Compress) -ceq $serial) 'request deterministic'}
  $names=@($req.request.PSObject.Properties|ForEach-Object{$_.Name});
  A (($names -join ',') -ceq 'version,policy_version,dedup_key,thread,trigger,summary,signals,classes,max_rationale_chars,min_confidence,request_digest') 'request exact ordered keys'
  $reversed=$names.Clone();
  [array]::Reverse($reversed);
  $reordered=[ordered]@{};
  foreach($name in $reversed){$reordered[$name]=$req.request.$name};
  A ((Get-SlowPathDigest $reordered) -ceq (Get-SlowPathDigest $req.request)) 'digest order independent'
  $changed=[ordered]@{};
  foreach($name in $names){$changed[$name]=$req.request.$name};
  $changed.summary+='x';
  A ((Get-SlowPathDigest $changed) -cne (Get-SlowPathDigest $req.request)) 'digest detects one-char change'
  $unicode=New-OrchestrationEventEnvelope github issue_comment pr:12 delivery-2 a/b -Summary ([string]::Concat('<>&',[char]39,' caf',[char]0xE9));
  $unicodeReq=Request-OrchestrationEventAdmissionSlowPath $unicode $c $f $pol $usage;
  A ($unicodeReq.decision -eq 'request' -and (Get-SlowPathDigest $unicodeReq.request) -ceq $unicodeReq.request.request_digest) 'unicode canonical digest'
  $golden=[ordered]@{
   version=1;policy_version='1';dedup_key=('a'*64);thread='pr:12'
   trigger='issue_comment';summary=[string]::Concat('<>&',[char]39,' caf',[char]0xE9)
   signals=@('ambiguous');classes=@('candidate','context_only','ignore')
   max_rationale_chars=12;min_confidence=0.7;request_digest=''
  }
  A ((Get-SlowPathDigest $golden) -ceq '63b9c846450ae88c87f3ec80896539608dc0bd04465c355b6e17baaf6c356b96') 'golden canonical digest'
  $secretSamples = @(
   'Authorization: Bearer token-secret extra fields',
   'proxy-authorization: Basic user:pass', 'api_key=abc123',
   'DB_PASSWORD=x', 'AWS_SECRET_ACCESS_KEY=x', 'X_API_KEY=x',
   'refresh_token=x', 'id_token=x', 'token=abc', '"password":"a b"',
   'secret_key=x', 'github_pat_abcdefghijklmnopqrstuv',
   'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234', 'glpat-abcdefghijklmnopqrst',
   'sk_live_abcdefghijklmnop', 'sk-abcdefghijklmnop',
   'AKIA1234567890ABCDEF', 'AIzaabcdefghijklmnopqrstuvwxyz123456',
   'xoxb-abcdefghijk', 'xapp-abcdefghijk', 'npm_abcdefghijklmnopqrstuvwxyz123456',
   'eyJabcdefghij.abcdefghij.abcdefghij',
   '-----BEGIN RSA PRIVATE KEY-----secret-----END RSA PRIVATE KEY-----',
   '-----BEGIN RSA PRIVATE KEY-----secret without end marker',
   'https://user:pass@example.test/path', '{"Authorization": "Bearer secret"}'
  )
  foreach ($raw in $secretSamples) {
   $safeText = Get-SlowPathRedactedText $raw
   A ($safeText -notmatch '(token-secret|user:pass|Bearer secret|PRIVATE KEY-----secret|=x\z|=abc\z| a b\z|ghp_[A-Za-z0-9]+|sk-[A-Za-z0-9]+|glpat-[A-Za-z0-9]+)') 'secret redaction'
   A ($safeText.Contains('[REDACTED]')) 'redaction marker'
  }
  $emoji='A' + [char]::ConvertFromUtf32(0x1F600) + 'B';
  A ((Limit-SlowPathText $emoji 2) -ceq 'A') 'surrogate-safe truncation'
  $badFast=$f.Clone();
  $badFast.signals='ambiguous';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $badFast $pol $usage).reason -eq 'invalid-fast-result') 'signals must be array';
  $badFast=$f.Clone();
  $badFast.signals=@(('a'*65));
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $badFast $pol $usage).reason -eq 'invalid-fast-result') 'signal length';
  $badFast=$f.Clone();
  $badFast.signals=@('bad signal');
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $badFast $pol $usage).reason -eq 'invalid-fast-result') 'signal charset'
  foreach($flag in @('source_allowlisted','blocklisted','duplicate')){$badContext=$c.Clone();
  $badContext[$flag]='true';
  $x=Request-OrchestrationEventAdmissionSlowPath $e $badContext $f $pol $usage;
  A (!$x.ok -and $x.reason -eq 'invalid-context') ('strict '+$flag)}
  $badContext=$c.Clone();
  $badContext.Remove('duplicate');
  $x=Request-OrchestrationEventAdmissionSlowPath $e $badContext $f $pol $usage;
  A (!$x.ok -and $x.reason -eq 'invalid-context') 'missing context flag';
  $badEnvelope=$e.Clone();
  $badEnvelope.informational_only='false';
  $x=Request-OrchestrationEventAdmissionSlowPath $badEnvelope $c $f $pol $usage;
  A (!$x.ok -and $x.reason -eq 'invalid-envelope') 'strict informational bool'
  foreach($usageValue in @($true,1.5,-1,'1')){$badUsage=@{requests_today=$usageValue;
  requests_for_thread=0};
  $x=Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $badUsage;
  A (!$x.ok -and $x.reason -eq 'invalid-usage') 'strict usage integer'}
  foreach($number in @([double]::NaN,[double]::PositiveInfinity)){$badPolicy=[pscustomobject]@{policy_version='1';
  enabled=$true;
  min_confidence=$number;
  max_summary_chars=20;
  max_rationale_chars=12;
  max_requests_per_day=2;
  max_requests_per_thread=2;
  classes=@('candidate','context_only','ignore')};
  $x=Request-OrchestrationEventAdmissionSlowPath $e $c $f $badPolicy $usage;
  A (!$x.ok -and $x.reason -eq 'invalid-policy') 'policy rejects nonfinite'}
  $badPolicy=[pscustomobject]@{policy_version='1';
  enabled='true';
  min_confidence=0.7;
  max_summary_chars=20;
  max_rationale_chars=12;
  max_requests_per_day=2;
  max_requests_per_thread=2;
  classes=@('candidate')};
  $x=Request-OrchestrationEventAdmissionSlowPath $e $c $f $badPolicy $usage;
  A (!$x.ok -and $x.reason -eq 'invalid-policy') 'policy rejects wrong enabled type'
  $extraPolicy=[ordered]@{
   policy_version='1';enabled=$true;min_confidence=0.7;max_summary_chars=20
   max_rationale_chars=12;max_requests_per_day=2;max_requests_per_thread=2
   classes=@('candidate','context_only','ignore');extra=$true
  }
  $x=Request-OrchestrationEventAdmissionSlowPath $e $c $f $extraPolicy $usage
  A (!$x.ok -and $x.reason -eq 'invalid-policy') 'policy rejects unknown key'
 foreach($intent in @('explicit','candidate','ignore')){$x=$f.Clone();
  $x.intent=$intent;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $x $pol $usage).reason -eq ('not-ambiguous:'+$intent)) ('intent '+$intent)}
 $c.actor_type='bot';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'bot') 'bot';
  $c.actor_type='human';
  $c.blocklisted=$true;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'blocklisted') 'blocklist';
  $c.blocklisted=$false;
  $c.duplicate=$true;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'duplicate') 'duplicate';
  $c.duplicate=$false
 $ei=$e.Clone();
  $ei.informational_only=$true;
  A ((Request-OrchestrationEventAdmissionSlowPath $ei $c $f $pol $usage).reason -eq 'informational-only') 'informational';
  $c.source_allowlisted=$false;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'source-not-allowlisted') 'source allowlist';
  $c.source_allowlisted=$true;
  $c.actor_type='unknown';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'unknown-actor') 'unknown actor';
  $c.actor_type='service';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'non-human-actor') 'non-human actor';
  $c.actor_type='human'
 A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $null).reason -eq 'usage-cap') 'usage absent';
  $usage.requests_today=0;
  $usage.requests_for_thread=0;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).decision -eq 'request') 'cap minus one';
  $usage.requests_today=2;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'usage-cap') 'daily cap';
  $usage.requests_today=0;
  $usage.requests_for_thread=2;
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage).reason -eq 'usage-cap') 'thread cap'
 $usage.requests_for_thread=0;
  $usage.requests_today=0;
  $noKey=@{source='github';
  trigger='issue_comment';
  thread='pr:12';
  repo='a/b';
  summary='s';
  informational_only=$false};
  A ((Request-OrchestrationEventAdmissionSlowPath $noKey $c $f $pol $usage).reason -eq 'invalid-envelope') 'missing dedup';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $null $usage).reason -eq 'invalid-policy') 'null policy';
  A ((Request-OrchestrationEventAdmissionSlowPath $e $c $f $real.policy $usage).reason -eq 'policy-disabled') 'policy disabled'
  $redactor = (Get-Command Get-SlowPathRedactedText).ScriptBlock
  Set-Item Function:\Get-SlowPathRedactedText -Value { throw 'synthetic redaction error' }
  $internal=Request-OrchestrationEventAdmissionSlowPath $e $c $f $pol $usage
  Set-Item Function:\Get-SlowPathRedactedText -Value $redactor
  A (!$internal.ok -and $internal.reason -eq 'internal-error') 'request catches internal exception'
  $baseResponse=@{request_digest=$req.request.request_digest;
  classification='candidate';
  confidence=0.9;
  rationale='ok'};
  $valid=Test-OrchestrationEventAdmissionSlowPathResponse $req.request ([pscustomobject]$baseResponse) $pol;
  A ($valid.ok -and $valid.action -eq 'would_new_task' -and !$valid.executable) 'candidate shadow'
  $policyValidator = (Get-Command Test-SlowPathPolicyObject).ScriptBlock
  Set-Item Function:\Test-SlowPathPolicyObject -Value { throw 'synthetic policy error' }
  $caught=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $baseResponse $pol
  Set-Item Function:\Test-SlowPathPolicyObject -Value $policyValidator
  A (!$caught.ok -and $caught.error -eq 'SLOWPATH_RESPONSE_INVALID') 'response catches internal exception'
  $missing=Copy-Request $req.request;
  $missing.Remove('summary');
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $missing $baseResponse $pol).error -eq 'SLOWPATH_REQUEST_INVALID') 'request missing field';
  $extraRequest=Copy-Request $req.request;
  $extraRequest['forged']=1;
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $extraRequest $baseResponse $pol).error -eq 'SLOWPATH_REQUEST_INVALID') 'request extra field';
  A ((Test-OrchestrationEventAdmissionSlowPathResponse @{request_digest=$req.request.request_digest} $baseResponse $pol).error -eq 'SLOWPATH_REQUEST_INVALID') 'digest-only request rejected'
  foreach($field in @('policy_version','classes','max_rationale_chars','min_confidence')){$drift=Copy-Request $req.request;
  switch($field){'policy_version'{$drift[$field]='2'}'classes'{$drift[$field]=@('ignore')}'max_rationale_chars'{$drift[$field]=11}'min_confidence'{$drift[$field]=0.8}};
  $drift.request_digest=Get-SlowPathDigest $drift;
  $r=$baseResponse.Clone();
  $r.request_digest=$drift.request_digest;
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $drift $r $pol).error -eq 'SLOWPATH_POLICY_DRIFT') ('policy drift '+$field)}
  $disabledPolicy=[pscustomobject]@{policy_version=$pol.policy_version;
  enabled=$false;
  min_confidence=$pol.min_confidence;
  max_summary_chars=$pol.max_summary_chars;
  max_rationale_chars=$pol.max_rationale_chars;
  max_requests_per_day=$pol.max_requests_per_day;
  max_requests_per_thread=$pol.max_requests_per_thread;
  classes=@($pol.classes)};
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $baseResponse $disabledPolicy).reason -eq 'policy-disabled') 'evaluate disabled policy'
 foreach($bad in @(@{confidence=1.1},@{confidence=-0.1},@{confidence='0.9'},@{confidence=$true})){$r=$baseResponse.Clone();
  foreach($k in $bad.Keys){$r[$k]=$bad[$k]};
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_CONFIDENCE_INVALID') 'response confidence'}
 $r=$baseResponse.Clone();
  $r.rationale='rationale is oversized';
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_RATIONALE_INVALID') 'rationale limit';
  $r=$baseResponse.Clone();
  $r.provider=('x'*101);
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_METADATA_INVALID') 'metadata limit';
  $r=$baseResponse.Clone();
  $r.classification=4;
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_CLASS_INVALID') 'classification type';
  $r=$baseResponse.Clone();
  $r.extra=1;
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_RESPONSE_INVALID') 'extra response field'
  $r=$baseResponse.Clone();
  $r.request_digest=('0'*64);
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_DIGEST_MISMATCH') 'response digest';
  $r=$baseResponse.Clone();
  $r.confidence=0.2;
  $low=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol;
  A ($low.ok -and $low.intent -eq 'context_only' -and $low.reason -eq 'low-confidence') 'low confidence'
  foreach($number in @([double]::NaN,[double]::PositiveInfinity)){$r=$baseResponse.Clone();
  $r.confidence=$number;
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol).error -eq 'SLOWPATH_CONFIDENCE_INVALID') 'response rejects nonfinite'}
  $r=$baseResponse.Clone();
  $r.rationale='api_key=x';
  $safe=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol;
  A ($safe.rationale -notmatch 'api_key=x' -and $safe.rationale_trust -eq 'untrusted-external') 'rationale redaction and trust'
 $dict=[ordered]@{};
  foreach($p in $req.request.PSObject.Properties){$dict[$p.Name]=$p.Value};
  $r=$baseResponse.Clone();
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $dict $r $pol).ok) 'ordered hashtable request digest';
  $extra=[ordered]@{};
  foreach($k in $dict.Keys){$extra[$k]=$dict[$k]};
  $extra.extra='spoof';
  A ((Test-OrchestrationEventAdmissionSlowPathResponse $extra $r $pol).error -eq 'SLOWPATH_REQUEST_INVALID') 'extra request field invalidates shape'
 foreach($class in @('ignore','context_only')){$r=$baseResponse.Clone();
  $r.classification=$class;
  $x=Test-OrchestrationEventAdmissionSlowPathResponse $req.request $r $pol;
  $expected=if($class -eq 'ignore'){'ignore'}else{'observe'};
  A ($x.ok -and $x.action -eq $expected -and !$x.executable) ('response '+$class)}
 # CLI round-trip: preserve each process's exact stdout for byte determinism.
 $cli = Join-Path $root 'scripts/v3/event-admission-slow-path.ps1'
 $policyFile = Write-Policy $base
 $envFile = Join-Path $tmp 'envelope.json'
 $ctxFile = Join-Path $tmp 'context.json'
 $fastFile = Join-Path $tmp 'fast.json'
 $usageFile = Join-Path $tmp 'usage.json'
 $reqFile = Join-Path $tmp 'request.json'
 $respFile = Join-Path $tmp 'response.json'
 $cliSummary = [string]::Concat('<>&', [char]39, ' caf', [char]0xE9)
 $cliEnvelope = New-OrchestrationEventEnvelope github issue_comment pr:12 delivery-html a/b -Summary $cliSummary
 [IO.File]::WriteAllText($envFile, (ConvertTo-Json $cliEnvelope -Compress))
 [IO.File]::WriteAllText($ctxFile, (ConvertTo-Json $c -Compress))
 [IO.File]::WriteAllText($fastFile, (ConvertTo-Json $f -Compress))
 [IO.File]::WriteAllText($usageFile, (ConvertTo-Json $usage -Compress))
 $exe = (Get-Process -Id $PID).Path
 $cliArgs = @('-NoProfile', '-File', $cli, '-Action', 'request', '-EnvelopeFile', $envFile,
  '-ContextFile', $ctxFile, '-FastFile', $fastFile, '-PolicyFile', $policyFile,
  '-UsageFile', $usageFile)
 $out1 = (& $exe @cliArgs | Out-String).Trim()
 A ($LASTEXITCODE -eq 0 -and (ConvertFrom-Json $out1).executable -eq $false) 'CLI request'
 $out2 = (& $exe @cliArgs | Out-String).Trim()
 A ($LASTEXITCODE -eq 0 -and $out1 -ceq $out2) 'CLI deterministic'
 $cliRequest = (ConvertFrom-Json $out1).request
 A ($cliRequest.summary -ceq $cliSummary) 'CLI UTF-8 stdout roundtrip'
 [IO.File]::WriteAllText($reqFile, (ConvertTo-Json $cliRequest -Compress))
 $response = [ordered]@{
  request_digest = $cliRequest.request_digest; classification = 'candidate'
  confidence = 0.9; rationale = 'ok'
 }
 [IO.File]::WriteAllText($respFile, (ConvertTo-Json $response -Compress))
 $evalOut = (& $exe -NoProfile -File $cli -Action evaluate -RequestFile $reqFile `
  -ResponseFile $respFile -PolicyFile $policyFile | Out-String).Trim()
 A ($LASTEXITCODE -eq 0 -and (ConvertFrom-Json $evalOut).ok) 'CLI evaluate roundtrip'
 $badPolicy = Join-Path $tmp 'bad-policy.json'
 [IO.File]::WriteAllText($badPolicy, '{}')
 $badOut = (& $exe -NoProfile -File $cli -Action request -EnvelopeJson '{}' `
  -ContextJson '{}' -FastJson '{}' -PolicyFile $badPolicy | Out-String).Trim()
 A ($LASTEXITCODE -eq 1 -and -not (ConvertFrom-Json $badOut).ok) 'CLI policy invalid'
 $savedPreference = $ErrorActionPreference
 $ErrorActionPreference = 'Continue'
 $invalidCalls = @(
  @('-Action', 'request'),
  @('-Action', 'request', '-EnvelopeFile', $envFile, '-EnvelopeJson', '{}',
   '-ContextJson', '{}', '-FastJson', '{}'),
  @('-Action', 'request', '-EnvelopeJson', '{}', '-ContextJson', '{}',
   '-FastJson', '{}', '-UsageFile', $usageFile, '-UsageJson', '{}'),
  @('-Action', 'bogus')
 )
 foreach ($invalidCall in $invalidCalls) {
  & $exe -NoProfile -File $cli @invalidCall *> $null
  A ($LASTEXITCODE -eq 2) 'CLI usage exit'
 }
 $ErrorActionPreference = $savedPreference
}finally{if($linked){[IO.Directory]::Delete($link)};Remove-Item -LiteralPath $tmp -Recurse -Force}
Write-Host "PASS OrchestrationEventAdmissionSlowPath $script:count assertions"
