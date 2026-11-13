$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionRules.ps1')
function Assert($c,$m){if(-not $c){throw $m}}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$real=Import-OrchestrationEventAdmissionRules -RepoRoot $root
Assert ($real.ok -and !$real.rules[0].enabled) 'real disabled registry'
$tmp=Join-Path $env:TEMP ('admission-rules-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $tmp)
function Write-Doc($doc){$p=Join-Path $tmp 'rules.json';[IO.File]::WriteAllText($p,(ConvertTo-Json $doc -Depth 10 -Compress),[Text.UTF8Encoding]::new($false));$p}
function Write-Raw($raw){$p=Join-Path $tmp 'raw.json';[IO.File]::WriteAllText($p,$raw,[Text.UTF8Encoding]::new($false));$p}
$base=@{rule_id='rule-a';enabled=$true;risk='low';trigger='issue_comment';scope_allowlist=@('repo')}
$junction=$null
try {
 $missing=Import-OrchestrationEventAdmissionRules -Path (Join-Path $tmp 'missing');Assert ($missing.error -eq 'RULES_PATH_NOT_FOUND') 'missing'
 $p=Join-Path $tmp 'bad.json';[IO.File]::WriteAllText($p,'{');Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_INVALID_JSON') 'json'
 $big=Join-Path $tmp 'big';[IO.File]::WriteAllText($big,(' '*20));Assert ((Import-OrchestrationEventAdmissionRules $big -MaxBytes 10).error -eq 'RULES_TOO_LARGE') 'bytes'
 $d=@{schema_version=1;policy_version='1';rules=@($base)}
 $p=Write-Doc (@{schema_version=2;policy_version='1';rules=@($base)});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_SCHEMA_INVALID') 'schema'
 foreach($value in @('"1"','true','1.0')){Assert ((Import-OrchestrationEventAdmissionRules (Write-Raw ('{"schema_version":'+$value+',"policy_version":"1","rules":[]}'))).error -eq 'RULES_SCHEMA_INVALID') ('schema type '+$value)}
 foreach($pv in @('', $null)){ $x=@{schema_version=1;rules=@($base)};if($null -ne $pv){$x.policy_version=$pv};$p=Write-Doc $x;Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_POLICY_VERSION_INVALID') 'policy version' }
 $x=@{schema_version=1;policy_version='1';rules=@($base,$base)};$p=Write-Doc $x;Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_RULE_ID_DUPLICATE') 'duplicate'
 foreach($change in @(@{rule_id='BAD'},@{enabled='true'},@{risk='high'},@{trigger='unknown'},@{scope_allowlist=@()},@{scope_allowlist=@('')},@{thread_allowlist=@()},@{thread_allowlist=@('bad')},@{extra='x'})){$r=$base.Clone();foreach($k in $change.Keys){$r[$k]=$change[$k]};$p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($r)});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_RULE_INVALID') ('invalid '+(($change.Keys)[0]))}
 $p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($base,$base)});Assert ((Import-OrchestrationEventAdmissionRules $p -MaxRules 1).error -eq 'RULES_LIMIT_EXCEEDED') 'rule count'
 $exact=@{schema_version=1;policy_version='1';rules=@($base,(@{rule_id='rule-b';enabled=$false;risk='low';trigger='push';scope_allowlist=@('repo')}))};$p=Write-Doc $exact;Assert ((Import-OrchestrationEventAdmissionRules $p -MaxRules 2).ok) 'exact rule limit'
 $empty=@{schema_version=1;policy_version='1';rules=@()};$p=Write-Doc $empty;$loaded=Import-OrchestrationEventAdmissionRules $p;Assert ($loaded.ok -and $loaded.rule_count -eq 0) 'empty registry'
 . (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionIntent.ps1');$ev=New-OrchestrationEventEnvelope -Source github -Trigger issue_comment -Thread pr:12 -DeliveryId delivery-1 -Repo a/b;$ctx=@{actor='a';actor_type='human';is_direct_mention=$false;scope='repo';source_allowlisted=$true;blocklisted=$false;duplicate=$false};$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'context_only') 'empty rules classification'
 $threaded=$base.Clone();$threaded.thread_allowlist=@('pr:12');$p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($threaded)});$loaded=Import-OrchestrationEventAdmissionRules $p;Assert ($loaded.ok) 'valid thread allowlist';$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'candidate') 'thread rule candidate'
 foreach($change in @(@{rule_id="rule-a`n"},@{thread_allowlist=@("pr:12`n")},@{scope_allowlist=@('  ')})){$r=$base.Clone();foreach($k in $change.Keys){$r[$k]=$change[$k]};$p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($r)});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_RULE_INVALID') ('strict string '+(($change.Keys)[0]))}
 $p=Write-Doc (@{schema_version=1;policy_version='1';rules=@();extra=$true});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_SCHEMA_INVALID') 'unknown root field'
 $badPaths=@('\\host\share','//host/share','/\host\share','\/host/share','\\?\C:\rules.json',"FileSystem::$env:TEMP");foreach($unc in $badPaths){$pathResult=Import-OrchestrationEventAdmissionRules -Path $unc;Assert ($pathResult.error -eq 'RULES_PATH_INVALID') ('path rejected '+$unc+' got '+$pathResult.error)}
 $target=Join-Path $tmp 'target';[void](New-Item -ItemType Directory $target);$targetFile=Join-Path $target 'rules.json';[IO.File]::WriteAllText($targetFile,(ConvertTo-Json $d -Compress),[Text.UTF8Encoding]::new($false));$junction=Join-Path $tmp 'link';New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop|Out-Null;Assert ((Import-OrchestrationEventAdmissionRules -Path (Join-Path $junction 'rules.json')).error -eq 'RULES_PATH_INVALID') 'junction rejected'
 $a=Import-OrchestrationEventAdmissionRules (Write-Doc $d)|ConvertTo-Json -Depth 10 -Compress;$b=Import-OrchestrationEventAdmissionRules (Write-Doc $d)|ConvertTo-Json -Depth 10 -Compress;Assert ($a -ceq $b) 'deterministic'
  $base.enabled=$true;$loaded=Import-OrchestrationEventAdmissionRules (Write-Doc $d);$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'candidate' -and $o.action -eq 'would_new_task' -and !$o.executable) 'enabled classifier';$base.enabled=$false;$loaded=Import-OrchestrationEventAdmissionRules (Write-Doc $d);$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'context_only') 'disabled classifier'
} finally {if($junction -and (Test-Path -LiteralPath $junction)){[IO.Directory]::Delete($junction)};if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force}}
Write-Output 'PASS AdmissionRules'
