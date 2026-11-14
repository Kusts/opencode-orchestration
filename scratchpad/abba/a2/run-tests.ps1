$ErrorActionPreference = 'Stop'
$test = Join-Path $PSScriptRoot 'tests\calc.tests.ps1'
$job = Start-Job -ScriptBlock {
    param($path)
    & powershell -NoProfile -File $path
    if ($LASTEXITCODE -eq 0) { 'ABBA_TEST_PASS' } else { 'ABBA_TEST_FAIL' }
} -ArgumentList $test
try {
    if (-not (Wait-Job -Job $job -Timeout 5)) {
        Stop-Job $job
        Write-Output 'criterion:0:FAIL'
        exit 1
    }
    $output = Receive-Job -Job $job 2>$null
    if ($output -contains 'ABBA_TEST_PASS') {
        Write-Output 'criterion:0:PASS'
        exit 0
    }
    Write-Output 'criterion:0:FAIL'
    exit 1
} finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
