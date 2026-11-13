$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionRules.ps1')
function Assert($c,$m){if(-not $c){throw $m}}
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$real=Import-OrchestrationEventAdmissionRules -RepoRoot $root
Assert ($real.ok -and !$real.rules[0].enabled) 'real disabled registry'
$tmp=Join-Path $env:TEMP ('admission-rules-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $tmp)
function Write-Doc($doc){$p=Join-Path $tmp 'rules.json';[IO.File]::WriteAllText($p,(ConvertTo-Json $doc -Depth 10 -Compress),[Text.UTF8Encoding]::new($false));$p}
$base=@{rule_id='rule-a';enabled=$true;risk='low';trigger='issue_comment';scope_allowlist=@('repo')}
try {
 $missing=Import-OrchestrationEventAdmissionRules -Path (Join-Path $tmp 'missing');Assert ($missing.error -eq 'RULES_PATH_NOT_FOUND') 'missing'
 $p=Join-Path $tmp 'bad.json';[IO.File]::WriteAllText($p,'{');Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_INVALID_JSON') 'json'
 $big=Join-Path $tmp 'big';[IO.File]::WriteAllText($big,(' '*20));Assert ((Import-OrchestrationEventAdmissionRules $big -MaxBytes 10).error -eq 'RULES_TOO_LARGE') 'bytes'
 $d=@{schema_version=1;policy_version='1';rules=@($base)}
 $p=Write-Doc (@{schema_version=2;policy_version='1';rules=@($base)});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_SCHEMA_INVALID') 'schema'
 foreach($pv in @('', $null)){ $x=@{schema_version=1;rules=@($base)};if($null -ne $pv){$x.policy_version=$pv};$p=Write-Doc $x;Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_POLICY_VERSION_INVALID') 'policy version' }
 $x=@{schema_version=1;policy_version='1';rules=@($base,$base)};$p=Write-Doc $x;Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_RULE_ID_DUPLICATE') 'duplicate'
 foreach($change in @(@{rule_id='BAD'},@{enabled='true'},@{risk='high'},@{trigger='unknown'},@{scope_allowlist=@()},@{scope_allowlist=@('')},@{thread_allowlist=@()},@{thread_allowlist=@('bad')},@{extra='x'})){$r=$base.Clone();foreach($k in $change.Keys){$r[$k]=$change[$k]};$p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($r)});Assert ((Import-OrchestrationEventAdmissionRules $p).error -eq 'RULES_RULE_INVALID') ('invalid '+(($change.Keys)[0]))}
 $p=Write-Doc (@{schema_version=1;policy_version='1';rules=@($base,$base)});Assert ((Import-OrchestrationEventAdmissionRules $p -MaxRules 1).error -eq 'RULES_LIMIT_EXCEEDED') 'rule count'
 $a=Import-OrchestrationEventAdmissionRules (Write-Doc $d)|ConvertTo-Json -Depth 10 -Compress;$b=Import-OrchestrationEventAdmissionRules (Write-Doc $d)|ConvertTo-Json -Depth 10 -Compress;Assert ($a -ceq $b) 'deterministic'
 . (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionIntent.ps1');$ev=New-OrchestrationEventEnvelope -Source github -Trigger issue_comment -Thread pr:12 -DeliveryId delivery-1 -Repo a/b;$ctx=@{actor='a';actor_type='human';is_direct_mention=$false;scope='repo';source_allowlisted=$true;blocklisted=$false;duplicate=$false};$p=Write-Doc $d;$loaded=Import-OrchestrationEventAdmissionRules $p;$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'candidate' -and $o.action -eq 'would_new_task' -and !$o.executable) 'enabled classifier';$base.enabled=$false;$loaded=Import-OrchestrationEventAdmissionRules (Write-Doc $d);$o=Resolve-OrchestrationEventAdmissionIntent $ev $ctx @{rules=$loaded.rules} auto;Assert ($o.intent -eq 'context_only') 'disabled classifier'
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force}
Write-Output 'PASS AdmissionRules (20 assertions)'
