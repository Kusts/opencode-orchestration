function Test-OrchestrationGitHubSignature {
    param([byte[]]$BodyBytes,[string]$SignatureHeader,[string]$Secret)
    $r=[ordered]@{ok=$false;error='';algorithm='sha256'}
    try {
        if([string]::IsNullOrEmpty($SignatureHeader)){$r.error='SIGNATURE_MISSING';return [pscustomobject]$r}
        if($SignatureHeader -match '^(?i:sha1|sha512)='){$r.error='SIGNATURE_ALGORITHM_UNSUPPORTED';return [pscustomobject]$r}
        if($SignatureHeader -cnotmatch '^(?i:sha256)=([0-9a-fA-F]{64})\z'){$r.error='SIGNATURE_FORMAT_INVALID';return [pscustomobject]$r}
        if([string]::IsNullOrWhiteSpace($Secret)){$r.error='SECRET_INVALID';return [pscustomobject]$r}
        $key=[Text.Encoding]::UTF8.GetBytes($Secret);$mac=New-Object -TypeName System.Security.Cryptography.HMACSHA256 -ArgumentList (,$key)
        try {$expected=$mac.ComputeHash([byte[]]$BodyBytes)} finally {$mac.Dispose()}
        $given=New-Object byte[] 32
        for($i=0;$i -lt 32;$i++){$given[$i]=[Convert]::ToByte($Matches[1].Substring($i*2,2),16)}
        $diff=0;for($i=0;$i -lt 32;$i++){$diff=$diff -bor ($expected[$i] -bxor $given[$i])}
        $r.ok=($diff -eq 0);if(-not $r.ok){$r.error='SIGNATURE_MISMATCH'}
    } catch {$r.error='SIGNATURE_FORMAT_INVALID'}
    [pscustomobject]$r
}
function Read-OrchestrationWebhookSecret {
    param([string]$Path,[int]$MaxBytes=4096)
    $r=[ordered]@{ok=$false;secret='';error=''}
    try {
        if($Path -match '^[\\/]{2}' -or $Path -match '^FileSystem::'){$r.error='SECRET_FILE_INVALID';return [pscustomobject]$r}
        if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){$r.error='SECRET_FILE_NOT_FOUND';return [pscustomobject]$r}
        $full=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
        $cursor=[IO.Path]::GetPathRoot($full)
        foreach($part in ($full.Substring($cursor.Length) -split '[\\/]')){
            if(!$part){continue}
            $cursor=Join-Path $cursor $part
            $i=Get-Item -LiteralPath $cursor -Force
            if(($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
                $r.error='SECRET_FILE_INVALID';return [pscustomobject]$r
            }
        }
        $i=Get-Item -LiteralPath $full;if($i.Length -gt $MaxBytes){$r.error='SECRET_FILE_TOO_LARGE';return [pscustomobject]$r}
        $r.secret=[IO.File]::ReadAllText($full,[Text.Encoding]::UTF8).Trim(" `t`r`n")
        if([string]::IsNullOrWhiteSpace($r.secret)){
            $r.secret='';$r.error='SECRET_FILE_INVALID';return [pscustomobject]$r
        }
        $r.ok=$true
    } catch {$r.secret='';$r.error='SECRET_FILE_INVALID'}
    [pscustomobject]$r
}
