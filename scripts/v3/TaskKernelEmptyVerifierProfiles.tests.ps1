$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot 'task-kernel.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('task-kernel-empty-verifiers-' + [guid]::NewGuid().ToString('N'))
$tasks = Join-Path $root 'tasks'
$flags = Join-Path $root 'flags.json'
$suffix = [guid]::NewGuid().ToString('N').ToLowerInvariant()
$ids = @(('empty-' + $suffix.Substring(0, 12)), ('explicit-' + $suffix.Substring(12, 12)))
New-Item -ItemType Directory -Path $tasks -Force | Out-Null
[IO.File]::WriteAllText($flags, '{"task_kernel":{"enabled":true,"shadow":false}}', (New-Object Text.UTF8Encoding $false))
try {
    Write-Host ('DIAG TaskIds=' + ($ids -join ',') + ' TasksDir=' + $tasks + ' FlagsPath=' + $flags)
    $rawNone = & $cli -Action create -TaskId $ids[0] -Objective 'empty verifier profile CLI regression' -Actor planner -TasksDir $tasks -FlagsPath $flags
    Write-Host ('DIAG CLI output=' + (($rawNone | ForEach-Object { [string]$_ }) -join "`n"))
    $none = $rawNone | ConvertFrom-Json
    if (-not $none.ok) { throw "CLI create without VerifierProfiles failed: $($none | ConvertTo-Json -Compress)" }
    $noneRecord = Get-Content -LiteralPath (Join-Path $tasks ($ids[0] + '.json')) -Raw | ConvertFrom-Json
    if (($null -ne $noneRecord.verification_profiles) -and (@($noneRecord.verification_profiles).Count -ne 0)) { throw 'create without VerifierProfiles stored profiles' }

    $explicit = & $cli -Action create -TaskId $ids[1] -Objective 'explicit verifier profile CLI regression' -VerifierProfiles @('v3-kernel') -Actor planner -TasksDir $tasks -FlagsPath $flags | ConvertFrom-Json
    if (-not $explicit.ok) { throw "CLI create with explicit VerifierProfiles failed: $($explicit | ConvertTo-Json -Compress)" }
    $explicitRecord = Get-Content -LiteralPath (Join-Path $tasks ($ids[1] + '.json')) -Raw | ConvertFrom-Json
    if (@($explicitRecord.verification_profiles) -notcontains 'v3-kernel') { throw 'explicit verifier profile was not preserved' }
    Write-Host '[PASS] TaskKernel empty and explicit verifier profile CLI behavior'
}
finally {
    foreach ($id in $ids) {
        $artifact = Join-Path $tasks ($id + '.json')
        if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Force }
    }
    if (Test-Path -LiteralPath $flags) { Remove-Item -LiteralPath $flags -Force }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Force -Recurse }
}
