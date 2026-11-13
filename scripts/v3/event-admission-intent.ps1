# Always emits JSON; -Json remains accepted for compatibility with callers.
param([string]$EnvelopeFile,[string]$EnvelopeJson,[string]$ContextFile,[string]$ContextJson,[string]$RulesFile,[string]$RulesJson,[string]$Mode='observe',[switch]$Json)
$ErrorActionPreference='Stop'
function Read-InputObject([string]$File,[string]$Text,[int]$Limit) {
    if ([bool]$File -eq [bool]$Text) { throw 'USAGE' }
    if ($File) { $path=(Resolve-Path -LiteralPath $File).Path; if ((Get-Item -LiteralPath $path).Length -gt $Limit) {throw 'LIMIT'}; $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) }
    else { $raw=$Text; if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt $Limit) {throw 'LIMIT'} }
    try { return ConvertFrom-Json -InputObject $raw } catch { throw 'INVALID_JSON' }
}
if($Mode -cnotin @('off','observe','auto')){[Console]::Error.WriteLine('invalid mode');exit 2}
try {
 $e=Read-InputObject $EnvelopeFile $EnvelopeJson 65536;$c=Read-InputObject $ContextFile $ContextJson 65536;$r=Read-InputObject $RulesFile $RulesJson 262144
} catch { [Console]::Error.WriteLine($_.Exception.Message);if($_.Exception.Message -in @('USAGE','LIMIT')){exit 2}else{exit 1} }
. (Join-Path $PSScriptRoot 'lib/OrchestrationEventAdmissionIntent.ps1')
$out=Resolve-OrchestrationEventAdmissionIntent -Envelope $e -Context $c -Rules $r -Mode $Mode
$line=ConvertTo-Json -InputObject $out -Depth 12 -Compress;[Console]::Out.WriteLine($line)
if(-not $out.ok){exit 1};exit 0
