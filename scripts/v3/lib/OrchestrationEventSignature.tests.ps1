$ErrorActionPreference='Stop';. (Join-Path $PSScriptRoot 'OrchestrationEventSignature.ps1');$count=0
function A($b,$m){if(!$b){throw $m};$script:count++}
$secret='sk-SYNTHETICSECRET'
$body=[Text.Encoding]::UTF8.GetBytes(('caf'+[char]0xE9))
$key=[Text.Encoding]::UTF8.GetBytes($secret)
$h=New-Object -TypeName Security.Cryptography.HMACSHA256 -ArgumentList (,$key)
$mac=([BitConverter]::ToString($h.ComputeHash($body))).Replace('-','').ToUpperInvariant()
$sig='SHA256='+$mac
A ((Test-OrchestrationGitHubSignature $body $sig $secret).ok) 'valid unicode'
A (!(Test-OrchestrationGitHubSignature $body ('sha256='+('0'*64)) $secret).ok) 'invalid'
$tam=$body.Clone();$tam[0]=$tam[0]-bxor 1
A (!(Test-OrchestrationGitHubSignature $tam $sig $secret).ok) 'tampered'
$empty=[byte[]]@()
$emptyHash=([BitConverter]::ToString($h.ComputeHash($empty))).Replace('-','').ToLowerInvariant()
A ((Test-OrchestrationGitHubSignature $empty ('sha256='+$emptyHash) $secret).ok) 'empty body'
A ((Test-OrchestrationGitHubSignature $body '' $secret).error -eq 'SIGNATURE_MISSING') 'missing'
A ((Test-OrchestrationGitHubSignature $body 'bad' $secret).error -eq 'SIGNATURE_FORMAT_INVALID') 'format'
A ((Test-OrchestrationGitHubSignature $body ('sha1='+('0'*40)) $secret).error -eq 'SIGNATURE_ALGORITHM_UNSUPPORTED') 'sha1'
A ((Test-OrchestrationGitHubSignature $body ('sha512='+('0'*128)) $secret).error -eq 'SIGNATURE_ALGORITHM_UNSUPPORTED') 'sha512'
A ((Test-OrchestrationGitHubSignature $body $sig ' ').error -eq 'SECRET_INVALID') 'empty secret'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($tmp)|Out-Null
try {
    $p=Join-Path $tmp 'secret'
    [IO.File]::WriteAllText($p,$secret+"`r`n")
    A ((Read-OrchestrationWebhookSecret $p).secret -eq $secret) 'file trim'
    [IO.File]::WriteAllText($p,'')
    A (!(Read-OrchestrationWebhookSecret $p).ok) 'empty file'
    [IO.File]::WriteAllText($p,('x'*4097))
    A ((Read-OrchestrationWebhookSecret $p).error -eq 'SECRET_FILE_TOO_LARGE') 'large'
    A ((Read-OrchestrationWebhookSecret (Join-Path $tmp 'missing')).error -eq 'SECRET_FILE_NOT_FOUND') 'missing file'
    A ((Read-OrchestrationWebhookSecret '\\host\share').error -eq 'SECRET_FILE_INVALID') 'unc'
} finally {Remove-Item $tmp -Recurse -Force}
for($i=0;$i -lt 8;$i++){
    $wrong=('0'*62)+('{0:x2}' -f $i)
    $r=Test-OrchestrationGitHubSignature $body ('sha256='+$wrong) $secret
    A (!$r.ok -and $r.error -eq 'SIGNATURE_MISMATCH') ('fixed-size mismatch '+$i)
}
$badHeader=Test-OrchestrationGitHubSignature $body ('sha256='+('a'*63)) $secret
A ($badHeader.error -eq 'SIGNATURE_FORMAT_INVALID') 'short hex'
$env:ORCH_SIGNATURE_TEST_SECRET=$secret
$cliBody=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllBytes($cliBody,$body)
try {
    $cliArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot '..\github-webhook-verify.ps1'),
        '-BodyFile',$cliBody,'-SignatureHeader',$sig,'-SecretEnvVar','ORCH_SIGNATURE_TEST_SECRET')
    $cli=& powershell @cliArgs 2>&1
    $cliDoc=($cli -join "`n")|ConvertFrom-Json
    A ($LASTEXITCODE -eq 0 -and $cliDoc.body_bytes -eq $body.Length) 'cli valid'
    A (($cli -join '') -notmatch [regex]::Escape($secret)) 'cli does not disclose secret'
    $bad=& powershell -NoProfile -File (Join-Path $PSScriptRoot '..\github-webhook-verify.ps1') `
        -BodyFile $cliBody -SignatureHeader 'bad' -SecretEnvVar ORCH_SIGNATURE_TEST_SECRET 2>&1
    A ($LASTEXITCODE -eq 1) 'cli invalid exit'
    $usage=& powershell -NoProfile -File (Join-Path $PSScriptRoot '..\github-webhook-verify.ps1') `
        -BodyFile $cliBody 2>&1
    A ($LASTEXITCODE -eq 2) 'cli usage exit'
} finally {
    Remove-Item $cliBody -Force
    Remove-Item Env:ORCH_SIGNATURE_TEST_SECRET -ErrorAction SilentlyContinue
}
Write-Host "PASS OrchestrationEventSignature $count assertions"
