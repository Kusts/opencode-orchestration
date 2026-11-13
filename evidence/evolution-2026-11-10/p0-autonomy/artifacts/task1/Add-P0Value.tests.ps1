[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Add-P0Value.ps1')

$passed = 0
$failed = 0
$cases = @(
    @{ A = 2; B = 3; Expected = 5; Name = '2 + 3 = 5' }
    @{ A = -1; B = 1; Expected = 0; Name = '-1 + 1 = 0' }
    @{ A = 0; B = 0; Expected = 0; Name = '0 + 0 = 0' }
)

foreach ($case in $cases) {
    $actual = Add-P0Value -a $case.A -b $case.B
    if ($actual -eq $case.Expected) {
        Write-Host ('[PASS] ' + $case.Name)
        $passed++
    }
    else {
        Write-Host ('[FAIL] ' + $case.Name + ' (expected ' + $case.Expected + ', got ' + $actual + ')')
        $failed++
    }
}

Write-Host ('PASS: ' + $passed + ' / FAIL: ' + $failed)
if ($failed -gt 0) { exit 1 }
exit 0
