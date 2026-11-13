param(
 [string]$Action,
 [string]$EnvelopeFile, [string]$EnvelopeJson,
 [string]$ContextFile, [string]$ContextJson,
 [string]$FastFile, [string]$FastJson,
 [string]$RequestFile, [string]$RequestJson,
 [string]$ResponseFile, [string]$ResponseJson,
 [string]$PolicyFile,
 [string]$UsageFile, [string]$UsageJson
)
$ErrorActionPreference='Stop'
function Read-JsonPair {
 param(
  [AllowEmptyString()][string]$File,
  [AllowEmptyString()][string]$Text,
  [bool]$FileSpecified,
  [bool]$TextSpecified,
  [bool]$Required = $true
 )
 if ($FileSpecified -and $TextSpecified) { throw 'USAGE' }
 if (-not $FileSpecified -and -not $TextSpecified) {
  if ($Required) { throw 'USAGE' }
  return $null
 }
 if ($FileSpecified) {
  $item = Get-Item -LiteralPath $File -ErrorAction SilentlyContinue
  if ($null -eq $item -or $item.PSIsContainer -or $item.Length -gt 65536) { throw 'USAGE' }
  $raw = [IO.File]::ReadAllText($item.FullName, [Text.Encoding]::UTF8)
 } else {
  $raw = $Text
  if ([Text.Encoding]::UTF8.GetByteCount($raw) -gt 65536) { throw 'USAGE' }
 }
 try {
  $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
  $confidence = $parsed.PSObject.Properties['confidence']
   if ($null -ne $confidence -and $confidence.Value -is [decimal]) {
    $confidence.Value = [double]$confidence.Value
   }
  return $parsed
 }
 catch { throw 'INVALID_JSON' }
}
try {
 . (Join-Path $PSScriptRoot 'lib/OrchestrationEventAdmissionSlowPath.ps1')
 if ($Action -ceq 'request') {
  $e = Read-JsonPair $EnvelopeFile $EnvelopeJson `
   $PSBoundParameters.ContainsKey('EnvelopeFile') $PSBoundParameters.ContainsKey('EnvelopeJson')
  $c = Read-JsonPair $ContextFile $ContextJson `
   $PSBoundParameters.ContainsKey('ContextFile') $PSBoundParameters.ContainsKey('ContextJson')
  $f = Read-JsonPair $FastFile $FastJson `
   $PSBoundParameters.ContainsKey('FastFile') $PSBoundParameters.ContainsKey('FastJson')
  $u = Read-JsonPair $UsageFile $UsageJson `
   $PSBoundParameters.ContainsKey('UsageFile') $PSBoundParameters.ContainsKey('UsageJson') $false
 } elseif ($Action -ceq 'evaluate') {
  $q = Read-JsonPair $RequestFile $RequestJson `
   $PSBoundParameters.ContainsKey('RequestFile') $PSBoundParameters.ContainsKey('RequestJson')
  $r = Read-JsonPair $ResponseFile $ResponseJson `
   $PSBoundParameters.ContainsKey('ResponseFile') $PSBoundParameters.ContainsKey('ResponseJson')
 } else { throw 'USAGE' }
} catch {
 [Console]::Error.WriteLine($_.Exception.Message)
 if ($_.Exception.Message -eq 'USAGE') { exit 2 }
 exit 1
}
if ($PolicyFile) {
 $loaded = Import-OrchestrationEventAdmissionSlowPathPolicy -Path $PolicyFile
} else { $loaded = Import-OrchestrationEventAdmissionSlowPathPolicy }
if (-not $loaded.ok) {
 $failure = [ordered]@{
  ok = $false; error = $loaded.error; shadow = $true; executable = $false
 }
 [Console]::Out.WriteLine((ConvertTo-Json $failure -Compress))
 exit 1
}
if ($Action -ceq 'request') {
 $out = Request-OrchestrationEventAdmissionSlowPath `
  -Envelope $e -Context $c -FastResult $f -Policy $loaded.policy -UsageState $u
} else {
 $out = Test-OrchestrationEventAdmissionSlowPathResponse `
  -Request $q -Response $r -Policy $loaded.policy
}
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $out -Depth 12 -Compress))
if ($out.ok) { exit 0 }
exit 1
