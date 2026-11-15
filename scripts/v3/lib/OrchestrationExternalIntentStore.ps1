[CmdletBinding()]
param()

function Write-OcAtomicJson {
    param([string]$Path, $Value)
    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $parent)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $json = ConvertTo-Json -InputObject $Value -Depth 24 -Compress
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
        [IO.File]::Replace($tmp, $Path, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    else { [IO.File]::Move($tmp, $Path) }
}
function New-OcExternalIntentPersistFn {
    param([string]$Root)
    $closureRoot = [string]$Root
    return {
        param($Intent)
        try {
            $path = Join-Path $closureRoot ('cache/runtime/external-intents/' + $Intent.idempotency_key + '.json')
            $parent = Split-Path -Parent $path
            [void](New-Item -ItemType Directory -Force -Path $parent)
            $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            $json = ConvertTo-Json -InputObject $Intent -Depth 24 -Compress
            [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $path) {
                $backup=$path+'.'+[guid]::NewGuid().ToString('N')+'.bak'
                [IO.File]::Replace($tmp,$path,$backup)
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
            else { [IO.File]::Move($tmp,$path) }
            return [bool]$true
        } catch { $script:OcExternalPersistError = $_.Exception.Message; return [bool]$false }
    }.GetNewClosure()
}
function Get-OcExternalReceipt {
    param([string]$Root, [string]$Key)
    $p = Join-Path $Root ('cache/runtime/external-intents/' + $Key + '.receipt.json')
    if (Test-Path -LiteralPath $p -PathType Leaf) { return (Get-Content -Raw -LiteralPath $p | ConvertFrom-Json) }
    return $null
}
function Save-OcExternalReceipt {
    param([string]$Root, $Receipt)
    Write-OcAtomicJson -Path (Join-Path $Root ('cache/runtime/external-intents/' + $Receipt.idempotency_key + '.receipt.json')) -Value $Receipt
}
