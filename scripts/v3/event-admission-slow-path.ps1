param([string]$Action,[string]$EnvelopeFile,[string]$EnvelopeJson,[string]$ContextFile,[string]$ContextJson,[string]$FastFile,[string]$FastJson,[string]$RequestFile,[string]$RequestJson,[string]$ResponseFile,[string]$ResponseJson,[string]$PolicyFile,[string]$UsageFile,[string]$UsageJson)
$ErrorActionPreference='Stop'
function Read-JsonPair([string]$File,[string]$Text,[bool]$Required=$true){if([bool]$File -eq [bool]$Text){if($Required){throw 'USAGE'};return $null};if($File){$p=(Resolve-Path -LiteralPath $File).Path;if((Get-Item $p).Length -gt 65536){throw 'USAGE'};$raw=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)}else{$raw=$Text;if([Text.Encoding]::UTF8.GetByteCount($raw)-gt 65536){throw 'USAGE'}};try{return ConvertFrom-Json -InputObject $raw -ErrorAction Stop}catch{throw 'INVALID_JSON'}}
try{
 . (Join-Path $PSScriptRoot 'lib/OrchestrationEventAdmissionSlowPath.ps1')
 if($Action -ceq 'request'){$e=Read-JsonPair $EnvelopeFile $EnvelopeJson;$c=Read-JsonPair $ContextFile $ContextJson;$f=Read-JsonPair $FastFile $FastJson;$u=Read-JsonPair $UsageFile $UsageJson $false}
 elseif($Action -ceq 'evaluate'){$q=Read-JsonPair $RequestFile $RequestJson;$r=Read-JsonPair $ResponseFile $ResponseJson}
 else{throw 'USAGE'}
}catch{[Console]::Error.WriteLine($_.Exception.Message);if($_.Exception.Message -eq 'USAGE'){exit 2};exit 1}
if($PolicyFile){$loaded=Import-OrchestrationEventAdmissionSlowPathPolicy -Path $PolicyFile}else{$loaded=Import-OrchestrationEventAdmissionSlowPathPolicy}
if(!$loaded.ok){[Console]::Out.WriteLine((ConvertTo-Json ([ordered]@{ok=$false;error=$loaded.error;shadow=$true;executable=$false}) -Compress));exit 1}
if($Action -ceq 'request'){$out=Request-OrchestrationEventAdmissionSlowPath -Envelope $e -Context $c -FastResult $f -Policy $loaded.policy -UsageState $u}else{$out=Test-OrchestrationEventAdmissionSlowPathResponse -Request $q -Response $r -Policy $loaded.policy}
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $out -Depth 12 -Compress));if($out.ok){exit 0};exit 1
