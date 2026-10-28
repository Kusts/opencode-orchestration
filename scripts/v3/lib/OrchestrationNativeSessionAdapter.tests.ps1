$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeSessionAdapter.ps1')

$passed = 0; $failed = 0
function Assert-S($cond, $name, $detail) {
    if ($cond) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
    else { $script:failed++; Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}

$hasOpencode = $null -ne (Get-Command opencode -ErrorAction SilentlyContinue)
if ($hasOpencode) {
    $r2 = Get-NativeSessionList -MaxCount 2
    Assert-S ($r2.ok -eq $true) 'list ok' ($r2.error)
    Assert-S ($r2.count -ge 1 -and $r2.count -le 2) 'count bounded' ("got $($r2.count)")
    Assert-S ($r2.sessions[0].id -match '^ses_') 'id shape' $r2.sessions[0].id
} else {
    Write-Host 'SKIP: opencode not available'
}

# 2. MaxCount clamping (0 -> 1) smoke
if ($hasOpencode) {
    $r4 = Get-NativeSessionList -MaxCount 1
    Assert-S ($r4.ok -eq $true) 'maxcount 1 ok' ($r4.error)
    Assert-S ($r4.count -le 1) 'maxcount 1 bounded' ("got $($r4.count)")
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0