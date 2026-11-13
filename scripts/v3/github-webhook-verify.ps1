<#
.DESCRIPTION
    Secret values must not contain leading or trailing whitespace. Bodies over
    1 MiB return BODY_TOO_LARGE with exit 2 (usage/limit convention).
#>
[CmdletBinding()]
param([string]$BodyFile,[string]$SignatureHeader,[string]$SecretFile,[string]$SecretEnvVar)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationEventSignature.ps1')
function Finish($o,[int]$n){Write-Output ($o|ConvertTo-Json -Compress);exit $n}
if([string]::IsNullOrWhiteSpace($BodyFile) -or
    (([string]::IsNullOrWhiteSpace($SecretFile)) -eq ([string]::IsNullOrWhiteSpace($SecretEnvVar)))){
    Finish ([ordered]@{ok=$false;error='USAGE_INVALID';algorithm='sha256';body_bytes=0;body_sha256=''}) 2
}
try {
 if(-not (Test-Path -LiteralPath $BodyFile -PathType Leaf)){Finish ([ordered]@{ok=$false;error='BODY_FILE_INVALID';algorithm='sha256';body_bytes=0;body_sha256=''}) 2}
 $bodyInfo=Get-Item -LiteralPath $BodyFile
 if([int64]$bodyInfo.Length -gt 1048576){
  Finish ([ordered]@{ok=$false;error='BODY_TOO_LARGE';algorithm='sha256';
   body_bytes=$bodyInfo.Length;body_sha256=''}) 2
 }
 $bytes=[IO.File]::ReadAllBytes($BodyFile)
 if($SecretFile){
  $s=Read-OrchestrationWebhookSecret $SecretFile
  if(!$s.ok){
   $hash=([BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
   Finish ([ordered]@{ok=$false;error=$s.error;algorithm='sha256';
    body_bytes=$bytes.Length;body_sha256=$hash}) 1
  }
  $secret=$s.secret
 }else{
  $secret=[Environment]::GetEnvironmentVariable($SecretEnvVar)
  if($null -eq $secret){$secret=''}
  $secret=$secret.Trim(" `t`r`n")
 }
 $v=Test-OrchestrationGitHubSignature $bytes $SignatureHeader $secret;$hash=([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
 Finish ([ordered]@{ok=[bool]$v.ok;error=[string]$v.error;algorithm='sha256';body_bytes=$bytes.Length;body_sha256=$hash}) $(if($v.ok){0}else{1})
} catch {Finish ([ordered]@{ok=$false;error='VERIFY_FAILED';algorithm='sha256';body_bytes=0;body_sha256=''}) 1}
