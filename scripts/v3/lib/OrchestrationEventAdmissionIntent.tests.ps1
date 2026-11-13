$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEventAdmissionIntent.ps1')
$event=New-OrchestrationEventEnvelope -Source github -Trigger issue_comment -Thread pr:12 -DeliveryId test-1234 -Repo a/b
$ctx=@{actor='alice';actor_type='human';is_direct_mention=$false;scope='repo';source_allowlisted=$true;blocklisted=$false;duplicate=$false}
$rules=@{policy_version='1';rules=@(@{rule_id='r1';enabled=$true;trigger='issue_comment';thread_allowlist=@('pr:12');scope_allowlist=@('repo')})}
function Assert($condition,$message) { if (-not $condition) { throw $message } }
foreach ($mode in @('off','observe','auto')) {
 $x=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules $mode
    Assert ($x.intent -eq $(if($mode -eq 'off'){'context_only'}else{'candidate'})) "mode $mode intent"
    Assert (-not $x.executable -and $x.shadow) 'shadow contract'
}
$ctx.is_direct_mention=$true
$x=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules auto
Assert ($x.intent -eq 'explicit' -and $x.action -eq 'would_attach') 'explicit mention'
$ctx.actor_type='bot'; $x=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules auto
Assert ($x.intent -eq 'ignore' -and $x.reason -eq 'self-or-bot') 'bot precedence'
$bad=Resolve-OrchestrationEventAdmissionIntent @{} $ctx $rules observe
Assert (-not $bad.ok -and $bad.reason -eq 'invalid-envelope') 'invalid envelope'
$ctx.actor_type='human'; $ctx.is_direct_mention=$false; $ctx.blocklisted=$false; $ctx.duplicate=$false
$none=Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@()} observe
Assert ($none.intent -eq 'context_only') 'no signal'
$ctx=@{actor='alice';actor_type='human';is_direct_mention=$false;scope='repo';source_allowlisted=$true;blocklisted=$false;duplicate=$false}
$ctx.blocklisted=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'blocklisted') 'blocklist'
$ctx.blocklisted=$false;$ctx.duplicate=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'duplicate-delivery') 'duplicate'
$ctx.duplicate=$false;$event.informational_only=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'informational-only') 'informational'
$event.informational_only=$false;$ctx.is_direct_mention=$true;$ctx.source_allowlisted=$false
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).intent -eq 'context_only') 'explicit requires allowlist'
$ctx.is_direct_mention=$false;$ctx.source_allowlisted=$true
$ctx.duplicate=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'duplicate-delivery') 'duplicate before explicit'
$ctx.duplicate=$false;$ctx.is_direct_mention=$true
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules off).action -eq 'observe') 'off explicit'
$ctx.is_direct_mention=$false;$ctx.actor_type='unknown'
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules auto).intent -eq 'context_only') 'candidate needs human'
$ctx.actor_type='human';$ctx.source_allowlisted='false'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).ok) 'strict bool'
$ctx.source_allowlisted=$true;$ctx.blocklisted='false'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).ok) 'strict context bool'
$ctx.blocklisted=$false
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$true;trigger='';scope_allowlist=@('repo')})} observe).ok) 'invalid rule'
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$false})} observe).intent -eq 'context_only') 'disabled rule'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx @{} observe).ok) 'rules required'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $null $ctx $rules observe).ok) 'null envelope is data error'
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$true;trigger='push';thread_allowlist=@('pr:12');scope_allowlist=@('repo')})} observe).intent -eq 'context_only') 'trigger mismatch'
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$true;trigger='issue_comment';thread_allowlist=@('pr:13');scope_allowlist=@('repo')})} observe).intent -eq 'context_only') 'thread mismatch'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$true;trigger='issue_comment';scope_allowlist=@()})} observe).ok) 'empty scope allowlist'
$ctx.is_direct_mention=$true;$ctx.duplicate=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'duplicate-delivery') 'duplicate before explicit'
$ctx.duplicate=$false;$ctx.actor_type='bot';$ctx.blocklisted=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'self-or-bot') 'bot before blocklist'
$ctx.actor_type='human';$ctx.blocklisted=$false;$ctx.is_direct_mention=$false
$ctx.is_direct_mention=$true;$event.informational_only=$true;Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'informational-only') 'informational before explicit'
$ctx.actor_type='bot';Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe).reason -eq 'self-or-bot') 'bot before informational'
$ctx.actor_type='human';$ctx.is_direct_mention=$false;$event.informational_only=$false
$noThread=@{rules=@(@{enabled=$true;trigger='issue_comment';scope_allowlist=@('repo')})}
Assert ((Resolve-OrchestrationEventAdmissionIntent $event $ctx $noThread observe).intent -eq 'candidate') 'thread allowlist absent is unrestricted'
$emptyThreadRule=@{rules=@(@{enabled=$true;trigger='issue_comment';scope_allowlist=@('repo');thread_allowlist=@()})};Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $emptyThreadRule observe).ok) 'empty thread allowlist invalid'
$nullThreadRule=@{rules=@(@{enabled=$true;trigger='issue_comment';scope_allowlist=@('repo');thread_allowlist=$null})};Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $nullThreadRule observe).ok) 'null thread allowlist invalid'
$jsonEmpty=ConvertFrom-Json '{"rules":[{"enabled":true,"trigger":"issue_comment","thread_allowlist":[],"scope_allowlist":["repo"]}]}'
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $jsonEmpty observe).ok) 'JSON empty thread allowlist invalid'
$objMissingRules=ConvertFrom-Json '{"policy_version":"1"}';Assert (-not (Resolve-OrchestrationEventAdmissionIntent $event $ctx $objMissingRules observe).ok) 'PSCustomObject missing rules'
$offInvalid=Resolve-OrchestrationEventAdmissionIntent $event $ctx @{rules=@(@{enabled=$true;trigger='issue_comment';scope_allowlist=@('repo')},@{enabled=$true;trigger='';scope_allowlist=@('repo')})} off
Assert (-not $offInvalid.ok -and $offInvalid.reason -eq 'invalid-rule') 'validate all rules before candidate/off'
$tooLong=@{source='github';trigger='issue_comment';thread='pr:12';delivery_id='test-1234';repo='a/b';informational_only=$false;summary=('x'*2001)}
Assert (-not (Resolve-OrchestrationEventAdmissionIntent $tooLong $ctx $rules observe).ok) 'summary limit'
$a=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe | ConvertTo-Json -Compress
$b=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules observe | ConvertTo-Json -Compress
Assert ($a -ceq $b) 'determinism'

# CLI process contract (same executable family/version as this test host).
$cli=Join-Path (Split-Path -Parent $PSScriptRoot) 'event-admission-intent.ps1'
$hostExe=(Get-Process -Id $PID).Path
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('admission-intent-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $tmp)
function Invoke-Cli([string[]]$CliArgs) {
    $old=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $out=(& $hostExe -NoProfile -File $cli @CliArgs 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$old }
    return @{code=$code;text=$out}
}
$ej=$event|ConvertTo-Json -Depth 10 -Compress;$cj=$ctx|ConvertTo-Json -Depth 10 -Compress;$rj=$rules|ConvertTo-Json -Depth 10 -Compress
$ef=Join-Path $tmp 'e.json';$cf=Join-Path $tmp 'c.json';$rf=Join-Path $tmp 'r.json'
[IO.File]::WriteAllText($ef,$ej,[Text.Encoding]::UTF8);[IO.File]::WriteAllText($cf,$cj,[Text.Encoding]::UTF8);[IO.File]::WriteAllText($rf,$rj,[Text.Encoding]::UTF8)
# JSON inline is covered by direct PowerShell parameter binding; subprocess
# argument quoting differs between Windows PowerShell 5.1 and PowerShell 7.
$one=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$rf);$two=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$rf)
Assert ($one.code -eq 0) ('CLI file success: '+$one.text);Assert (($one.text|ConvertFrom-Json).ok) 'CLI file JSON';Assert ($one.text -ceq $two.text) 'CLI byte determinism with same files'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-EnvelopeJson',$ej,'-ContextFile',$cf,'-RulesFile',$rf);Assert ($z.code -eq 2) 'CLI envelope usage xor'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-ContextJson',$cj,'-RulesFile',$rf);Assert ($z.code -eq 2) 'CLI context usage xor'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$rf,'-RulesJson',$rj);Assert ($z.code -eq 2) 'CLI rules usage xor'
$badJson=Join-Path $tmp 'bad.json';[IO.File]::WriteAllText($badJson,'{',[Text.UTF8Encoding]::new($false))
$z=Invoke-Cli @('-EnvelopeFile',$badJson,'-ContextFile',$cf,'-RulesFile',$rf);Assert ($z.code -eq 1 -and $z.text -match 'INVALID_JSON') 'CLI malformed envelope JSON'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$badJson,'-RulesFile',$rf);Assert ($z.code -eq 1 -and $z.text -match 'INVALID_JSON') 'CLI malformed context JSON'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$badJson);Assert ($z.code -eq 1 -and $z.text -match 'INVALID_JSON') 'CLI malformed rules JSON'
foreach($m in @(@('-EnvelopeFile',$ef,65537),@('-ContextFile',$cf,65537),@('-RulesFile',$rf,262145))) {
 $p=Join-Path $tmp ([guid]::NewGuid().ToString('N')+'.big');$fs=[IO.File]::Create($p);$fs.SetLength([long]$m[2]);$fs.Dispose()
 if($m[0] -eq '-EnvelopeFile'){$args=@('-EnvelopeFile',$p,'-ContextFile',$cf,'-RulesFile',$rf)}elseif($m[0] -eq '-ContextFile'){$args=@('-EnvelopeFile',$ef,'-ContextFile',$p,'-RulesFile',$rf)}else{$args=@('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$p)};$z=Invoke-Cli $args;Assert ($z.code -eq 2) ('CLI file size limit: '+$z.text)
}
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$rf,'-Mode','bogus');Assert ($z.code -eq 2) 'CLI invalid mode'
$badEvent=@{source='github';trigger='issue_comment';thread='BAD';delivery_id='test-1234';repo='a/b';informational_only=$false;summary=''}|ConvertTo-Json -Compress
$badEventFile=Join-Path $tmp 'bad-envelope.json';[IO.File]::WriteAllText($badEventFile,$badEvent,[Text.UTF8Encoding]::new($false))
$z=Invoke-Cli @('-EnvelopeFile',$badEventFile,'-ContextFile',$cf,'-RulesFile',$rf);Assert ($z.code -eq 1) 'CLI invalid envelope exit';$err=$z.text|ConvertFrom-Json;Assert (-not $err.ok -and $err.reason -eq 'invalid-envelope' -and $err.error -eq 'EVENT_THREAD_INVALID') 'CLI typed envelope error'
foreach($field in @('source','trigger','thread','delivery_id','repo')){$missing=@{source='github';trigger='issue_comment';thread='pr:12';delivery_id='test-1234';repo='a/b';informational_only=$false;summary=''};$missing.Remove($field);$missingPath=Join-Path $tmp ('missing-'+$field+'.json');[IO.File]::WriteAllText($missingPath,($missing|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));$z=Invoke-Cli @('-EnvelopeFile',$missingPath,'-ContextFile',$cf,'-RulesFile',$rf);Assert ($z.code -eq 1) ('CLI missing '+$field);$mout=$z.text|ConvertFrom-Json;$errorField=if($field -eq 'delivery_id'){'EVENT_DELIVERY_INVALID'}else{'EVENT_'+$field.ToUpperInvariant()+'_INVALID'};Assert (-not $mout.ok -and $mout.error -eq $errorField) ('typed missing '+$field)}
$upperLib=Resolve-OrchestrationEventAdmissionIntent $event $ctx $rules 'OBSERVE';Assert (-not $upperLib.ok -and $upperLib.reason -ceq 'invalid-mode') 'lib mode is case-sensitive'
$upper=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$rf,'-Mode','OBSERVE');Assert ($upper.code -eq 2) 'CLI rejects uppercase mode'
$registry=Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'source/registry/event-admission-rules.json'
$registryDoc=Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json;$equivalent=Join-Path $tmp 'equivalent-rules.json';[IO.File]::WriteAllText($equivalent,($registryDoc|ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
$regSuccess=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$registry);$fileSuccess=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$equivalent)
Assert ($regSuccess.code -eq 0 -and $regSuccess.text -ceq $fileSuccess.text) 'CLI registry equals equivalent file'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$registry,'-RulesFile',$rf);Assert ($z.code -eq 2) 'CLI registry/file conflict'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$registry,'-RulesJson',$rj);Assert ($z.code -eq 2) 'CLI registry/json conflict'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$registry,'-RulesFile',$rf,'-RulesJson',$rj);Assert ($z.code -eq 2) 'CLI all rules sources conflict'
$z=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$badJson);Assert ($z.code -eq 1 -and $z.text -match 'RULES_INVALID_JSON') 'CLI invalid registry'
$absent=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',(Join-Path $tmp 'no-registry.json'));Assert ($absent.code -eq 1) 'CLI missing registry exit';$shape=$absent.text|ConvertFrom-Json;Assert (($shape.PSObject.Properties.Name -join ',') -ceq 'ok,intent,mode,action,reason,error,rule_id,shadow,executable,dedup_key,thread,signals' -and $shape.error -eq 'RULES_PATH_NOT_FOUND' -and $shape.mode -eq 'observe' -and !$shape.ok -and $shape.intent -eq 'ignore' -and $shape.shadow -and !$shape.executable) 'CLI full registry error shape'
$activeDoc=@{schema_version=1;policy_version='1';rules=@($rules.rules)};$activeDoc.rules[0].risk='low';$activeDoc.rules[0].enabled=$true;$activeRegistry=Join-Path $tmp 'active-registry.json';[IO.File]::WriteAllText($activeRegistry,($activeDoc|ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false));$activeRules=Join-Path $tmp 'active-rules.json';[IO.File]::WriteAllText($activeRules,(@{policy_version='1';rules=$activeDoc.rules}|ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
$active=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesRegistry',$activeRegistry,'-Mode','auto');$activeFile=Invoke-Cli @('-EnvelopeFile',$ef,'-ContextFile',$cf,'-RulesFile',$activeRules,'-Mode','auto');$activeOut=$active.text|ConvertFrom-Json;Assert ($active.code -eq 0 -and $active.text -ceq $activeFile.text -and $activeOut.intent -eq 'candidate' -and $activeOut.action -eq 'would_new_task' -and $activeOut.shadow -and !$activeOut.executable) ('CLI enabled normalized registry: '+$active.code+' '+$active.text+' vs '+$activeFile.text)
Remove-Item -LiteralPath $tmp -Recurse -Force
Write-Output 'PASS AdmissionIntent'

