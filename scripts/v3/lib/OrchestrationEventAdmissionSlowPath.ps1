# Deterministic, shadow-only slow-path request contract. No provider or kernel calls.
. (Join-Path $PSScriptRoot 'OrchestrationEventCorrelation.ps1')
function Import-OrchestrationEventAdmissionSlowPathPolicy {
 [CmdletBinding()] param([string]$Path,[string]$RepoRoot,[int]$MaxBytes=65536)
 $o=[ordered]@{ok=$false;policy=$null;error=''}
 try {
  if(-not $Path){if(-not $RepoRoot){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path};$Path=Join-Path $RepoRoot 'source\registry\event-admission-slow-path-policy.json'}
  if($Path -match '^[\\/]{2}' -or $Path -match '^FileSystem::'){$o.error='SLOWPATH_POLICY_PATH_INVALID';return [pscustomobject]$o}
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){$o.error='SLOWPATH_POLICY_PATH_NOT_FOUND';return [pscustomobject]$o}
  $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path);$root=[IO.Path]::GetPathRoot($full);$cursor=$root
  if($full -match '^[\\/]{2}' -or $full -match '^FileSystem::'){$o.error='SLOWPATH_POLICY_PATH_INVALID';return [pscustomobject]$o};foreach($part in ($full.Substring($root.Length) -split '[\\/]')){if(!$part){continue};$cursor=Join-Path $cursor $part;$i=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){$o.error='SLOWPATH_POLICY_PATH_INVALID';return [pscustomobject]$o}}
  $i=Get-Item -LiteralPath $full -ErrorAction Stop;if($i.Length -gt $MaxBytes){$o.error='SLOWPATH_POLICY_TOO_LARGE';return [pscustomobject]$o}
  try{$d=Get-Content -LiteralPath $full -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$o.error='SLOWPATH_POLICY_INVALID_JSON';return [pscustomobject]$o}
  $names=@('schema_version','policy_version','enabled','min_confidence','max_summary_chars','max_rationale_chars','max_requests_per_day','max_requests_per_thread','classes');foreach($p in $d.PSObject.Properties){if($p.Name -cnotin $names){$o.error='SLOWPATH_POLICY_SCHEMA_INVALID';return [pscustomobject]$o}}
  if($d -isnot [pscustomobject] -or @($d.PSObject.Properties).Count -ne $names.Count -or ($d.schema_version -isnot [int] -and $d.schema_version -isnot [long]) -or $d.schema_version -ne 1 -or $d.policy_version -isnot [string] -or $d.policy_version.Length -lt 1 -or $d.policy_version.Length -gt 64 -or $d.enabled -isnot [bool] -or $d.min_confidence -isnot [ValueType] -or $d.min_confidence -is [bool] -or [double]$d.min_confidence -lt 0 -or [double]$d.min_confidence -gt 1 -or $d.classes -isnot [array] -or !$d.classes.Count){$o.error='SLOWPATH_POLICY_SCHEMA_INVALID';return [pscustomobject]$o}
  foreach($n in @('max_summary_chars','max_rationale_chars','max_requests_per_day','max_requests_per_thread')){if(($d.$n -isnot [int] -and $d.$n -isnot [long]) -or $d.$n -lt 0 -or $d.$n -gt 100000){$o.error='SLOWPATH_POLICY_SCHEMA_INVALID';return [pscustomobject]$o}}
  $seen=@{};foreach($c in $d.classes){if($c -isnot [string] -or $c -cnotin @('candidate','context_only','ignore') -or $seen.ContainsKey($c)){$o.error='SLOWPATH_POLICY_SCHEMA_INVALID';return [pscustomobject]$o};$seen[$c]=$true}
  $o.ok=$true;$o.policy=[pscustomobject]([ordered]@{policy_version=$d.policy_version;enabled=$d.enabled;min_confidence=[double]$d.min_confidence;max_summary_chars=[int]$d.max_summary_chars;max_rationale_chars=[int]$d.max_rationale_chars;max_requests_per_day=[int]$d.max_requests_per_day;max_requests_per_thread=[int]$d.max_requests_per_thread;classes=@($d.classes)})
 }catch{$o.error='SLOWPATH_POLICY_PATH_INVALID'};[pscustomobject]$o
}
function Get-SlowPathDigest { param($Document)
 $json=ConvertTo-Json -InputObject $Document -Depth 12 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($json);$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Request-OrchestrationEventAdmissionSlowPath {
 [CmdletBinding()]param($Envelope,$Context,$FastResult,$Policy,$UsageState=$null)
 $o=[ordered]@{ok=$true;decision='skip';reason='invalid-fast-result';request=$null;shadow=$true;executable=$false}
 try{
  if($null -eq $Policy){$o.ok=$false;$o.reason='invalid-policy';return [pscustomobject]$o};if(-not $Policy.enabled){$o.reason='policy-disabled';return [pscustomobject]$o}
  if($null -eq $FastResult -or (Get-OrchestrationEventField $FastResult 'ok') -isnot [bool] -or -not (Get-OrchestrationEventField $FastResult 'ok')){return [pscustomobject]$o}
  $intent=Get-OrchestrationEventField $FastResult 'intent';if($intent -cne 'context_only'){$o.reason='not-ambiguous:'+$intent;return [pscustomobject]$o}
  if((Get-OrchestrationEventField $Context 'actor_type') -ceq 'bot'){$o.reason='bot';return [pscustomobject]$o};if((Get-OrchestrationEventField $Context 'blocklisted') -eq $true){$o.reason='blocklisted';return [pscustomobject]$o};if((Get-OrchestrationEventField $Context 'duplicate') -eq $true){$o.reason='duplicate';return [pscustomobject]$o}
  if((Get-OrchestrationEventField $Envelope 'informational_only') -eq $true){$o.reason='informational-only';return [pscustomobject]$o}
  if((Get-OrchestrationEventField $Context 'source_allowlisted') -ne $true){$o.reason='source-not-allowlisted';return [pscustomobject]$o};$actor=Get-OrchestrationEventField $Context 'actor_type';if($actor -ceq 'unknown'){$o.reason='unknown-actor';return [pscustomobject]$o};if($actor -cne 'human'){$o.reason='invalid-fast-result';return [pscustomobject]$o}
  if($null -eq $UsageState -or $null -eq (Get-OrchestrationEventField $UsageState 'requests_today') -or $null -eq (Get-OrchestrationEventField $UsageState 'requests_for_thread') -or $Policy.max_requests_per_day -le 0 -or $Policy.max_requests_per_thread -le 0 -or [int](Get-OrchestrationEventField $UsageState 'requests_today') -ge $Policy.max_requests_per_day -or [int](Get-OrchestrationEventField $UsageState 'requests_for_thread') -ge $Policy.max_requests_per_thread){$o.reason='usage-cap';return [pscustomobject]$o}
  foreach($n in @('source','trigger','thread','repo','summary','dedup_key')){if($null -eq (Get-OrchestrationEventField $Envelope $n)){$o.ok=$false;$o.reason='invalid-envelope';return [pscustomobject]$o}}
  $summary=[string](Get-OrchestrationEventField $Envelope 'summary');$summary=$summary -replace '(?i)(token|secret|password|authorization)\s*[:=]\s*\S+','$1=[REDACTED]';if($summary.Length -gt $Policy.max_summary_chars){$summary=$summary.Substring(0,$Policy.max_summary_chars)}
  $doc=[ordered]@{version=1;policy_version=[string]$Policy.policy_version;dedup_key=[string](Get-OrchestrationEventField $Envelope 'dedup_key');thread=[string](Get-OrchestrationEventField $Envelope 'thread');trigger=[string](Get-OrchestrationEventField $Envelope 'trigger');summary=$summary;signals=@(Get-OrchestrationEventField $FastResult 'signals');classes=@($Policy.classes);max_rationale_chars=[int]$Policy.max_rationale_chars};$digest=Get-SlowPathDigest $doc;$doc.request_digest=$digest;$o.decision='request';$o.reason='ambiguous';$o.request=[pscustomobject]$doc
 }catch{$o.ok=$false;$o.reason='invalid-fast-result'};[pscustomobject]$o
}
function Test-OrchestrationEventAdmissionSlowPathResponse {
 [CmdletBinding()]param($Request,$Response,$Policy)
 $o=[ordered]@{ok=$false;intent='ignore';action='ignore';reason='SLOWPATH_RESPONSE_INVALID';error='';source='slow-path';shadow=$true;executable=$false}
 try{
  if($null -eq $Request -or $null -eq $Response -or $null -eq $Policy){return [pscustomobject]$o}
  $allowed=@('request_digest','classification','confidence','rationale','provider','model');$responseNames=if($Response -is [System.Collections.IDictionary]){@($Response.Keys)}else{@($Response.PSObject.Properties|ForEach-Object{$_.Name})};foreach($n in $responseNames){if($n -cnotin $allowed){$o.error='SLOWPATH_RESPONSE_INVALID';return [pscustomobject]$o}}
  $copy=[ordered]@{};foreach($p in $Request.PSObject.Properties){if($p.Name -cne 'request_digest'){$copy[$p.Name]=$p.Value}};$digest=Get-SlowPathDigest $copy
  if((Get-OrchestrationEventField $Request 'request_digest') -cnotmatch '^[0-9a-f]{64}$' -or (Get-OrchestrationEventField $Response 'request_digest') -cne $digest -or (Get-OrchestrationEventField $Request 'request_digest') -cne $digest){$o.error='SLOWPATH_DIGEST_MISMATCH';return [pscustomobject]$o}
  $class=Get-OrchestrationEventField $Response 'classification';if($class -isnot [string] -or $class -cnotin @($Policy.classes)){$o.error='SLOWPATH_CLASS_INVALID';return [pscustomobject]$o}
  $conf=Get-OrchestrationEventField $Response 'confidence';if($conf -isnot [ValueType] -or $conf -is [bool] -or [double]$conf -lt 0 -or [double]$conf -gt 1){$o.error='SLOWPATH_CONFIDENCE_INVALID';return [pscustomobject]$o}
  $r=Get-OrchestrationEventField $Response 'rationale';if($r -isnot [string] -or $r.Length -gt $Policy.max_rationale_chars){$o.error='SLOWPATH_RATIONALE_INVALID';return [pscustomobject]$o}
  foreach($n in @('provider','model')){$v=Get-OrchestrationEventField $Response $n;if($null -ne $v -and ($v -isnot [string] -or $v.Length -gt 100)){$o.error='SLOWPATH_METADATA_INVALID';return [pscustomobject]$o}}
  $o.ok=$true;$o.error='';if([double]$conf -lt $Policy.min_confidence){$o.intent='context_only';$o.action='observe';$o.reason='low-confidence'}else{$o.intent=$class;$o.action=switch($class){'candidate'{'would_new_task'}'context_only'{'observe'}default{'ignore'}};$o.reason='classified'};$o.classification=$class;$o.confidence=[double]$conf;$o.rationale=$r
 }catch{$o.ok=$false;$o.error='SLOWPATH_RESPONSE_INVALID'};[pscustomobject]$o
}
