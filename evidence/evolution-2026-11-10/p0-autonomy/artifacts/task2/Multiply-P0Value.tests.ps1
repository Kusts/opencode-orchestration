[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Multiply-P0Value.ps1')

$passed = 0
$failed = 0
$cases = @(
    @{ A = 2; B = 3; Expected = 6; Name = '2 * 3 = 6' }
    @{ A = -2; B = 3; Expected = -6; Name = '-2 * 3 = -6' }
    @{ A = 0; B = 5; Expected = 0; Name = '0 * 5 = 0' }
    @{ A = 2; B = 3; Expected = 6; Name = 'acceptance literal: 2 * 3 = 6' }
)

foreach ($case in $cases) {
    $actual = Multiply-P0Value -a $case.A -b $case.B
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
