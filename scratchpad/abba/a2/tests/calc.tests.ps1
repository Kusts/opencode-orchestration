. (Join-Path $PSScriptRoot '..\lib\calc.ps1')
$checks = @(
    ((Get-Total @(1,2)) -eq 3),
    ((Get-Total @(1,2,3)) -eq 6),
    ((Get-Total @()) -eq 0),
    ((Get-Total @(4,5,6,7,8)) -eq 30)
)
if ($checks.Count -ne 4) { exit 2 }
if ($checks -contains $false) { exit 1 }
exit 0
