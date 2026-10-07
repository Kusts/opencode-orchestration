[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalProgress.ps1')
$passed = 0
function Assert-GDThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-GDMetrics {
    param([hashtable]$Override = @{})
    $m = @{
        satisfied    = 0
        total        = 0
        failed_tests = 0
        open_p1      = 0
        blockers     = 0
    }
    foreach ($k in @($Override.Keys)) { $m[$k] = $Override[$k] }
    return $m
}
# --- Improvement in satisfied is meaningful and resets stagnation.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3; total = 8; failed_tests = 20; open_p1 = 3; blockers = 2 }) -Current (New-GDMetrics @{ satisfied = 5; total = 8; failed_tests = 20; open_p1 = 3; blockers = 2 }) -StagnationCount 2
Assert-GDThat (($null -ne $d) -and [bool]$d.ok -and [bool]$d.meaningful -and ([string]$d.reason -ceq 'improved')) 'satisfied gain is meaningful'
Assert-GDThat (([long]$d.stagnation_count -eq 0) -and (-not [bool]$d.strategy_change_required)) 'improvement resets stagnation'
Assert-GDThat (([long]$d.delta.satisfied_diff -eq 2) -and ([long]$d.delta.total_diff -eq 0)) 'delta carries per-metric diffs'
# --- Improvement in failed tests alone is meaningful.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ failed_tests = 20 }) -Current (New-GDMetrics @{ failed_tests = 4 })
Assert-GDThat ([bool]$d.meaningful -and ([long]$d.delta.failed_tests_diff -eq -16) -and ([long]$d.stagnation_count -eq 0)) 'failed-tests drop is meaningful'
# --- Improvement in open_p1 / blockers is meaningful.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ open_p1 = 3; blockers = 2 }) -Current (New-GDMetrics @{ open_p1 = 1; blockers = 0 })
Assert-GDThat ([bool]$d.meaningful -and ([long]$d.delta.open_p1_diff -eq -2) -and ([long]$d.delta.blockers_diff -eq -2)) 'p1 and blocker drops are meaningful'
# --- Identical snapshots stall: stagnation input + 1.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3; total = 8 }) -Current (New-GDMetrics @{ satisfied = 3; total = 8 }) -StagnationCount 1
Assert-GDThat (($null -ne $d) -and [bool]$d.ok -and (-not [bool]$d.meaningful) -and ([string]$d.reason -ceq 'no-change')) 'identical snapshots are not meaningful'
Assert-GDThat (([long]$d.stagnation_count -eq 2) -and (-not [bool]$d.strategy_change_required)) 'stall bumps stagnation without strategy change yet'
# --- Third consecutive stall requires a strategy change.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3 }) -Current (New-GDMetrics @{ satisfied = 3 }) -StagnationCount 2
Assert-GDThat (([long]$d.stagnation_count -eq 3) -and [bool]$d.strategy_change_required) '3 stalls require strategy change'
# --- Pure regression is change but not meaningful.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 5; failed_tests = 4 }) -Current (New-GDMetrics @{ satisfied = 4; failed_tests = 9 }) -StagnationCount 0
Assert-GDThat ((-not [bool]$d.meaningful) -and ([string]$d.reason -ceq 'regressed') -and ([long]$d.stagnation_count -eq 1)) 'pure regression is not meaningful'
# --- Scope-only change without improvement reads as regressed.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3; total = 8 }) -Current (New-GDMetrics @{ satisfied = 3; total = 10 })
Assert-GDThat ((-not [bool]$d.meaningful) -and ([string]$d.reason -ceq 'regressed')) 'scope-only change without improvement is not meaningful'
# --- Mixed improvement plus regression still counts as progress.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3; failed_tests = 4 }) -Current (New-GDMetrics @{ satisfied = 5; failed_tests = 6 })
Assert-GDThat ([bool]$d.meaningful -and ([string]$d.reason -ceq 'improved') -and ([long]$d.stagnation_count -eq 0)) 'any improvement wins over co-occurring regression'
# --- Strict types: scalar-invalid input fails closed.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = @('3') }) -Current (New-GDMetrics @{ satisfied = 3 })
Assert-GDThat (($null -ne $d) -and (-not [bool]$d.ok) -and (-not [bool]$d.meaningful) -and ([string]$d.reason -ceq 'invalid-input')) 'collection metric fails closed'
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = '3' }) -Current (New-GDMetrics @{ satisfied = 3 })
Assert-GDThat ((-not [bool]$d.ok) -and (-not [bool]$d.meaningful)) 'string metric fails closed'
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = 3.5 }) -Current (New-GDMetrics @{ satisfied = 4 })
Assert-GDThat ((-not [bool]$d.ok) -and (-not [bool]$d.meaningful)) 'non-integral metric fails closed'
$d = Get-OrchestrationGoalProgressDelta -Previous $null -Current (New-GDMetrics @{})
Assert-GDThat (($null -ne $d) -and (-not [bool]$d.ok) -and (-not [bool]$d.meaningful)) 'null snapshot fails closed'
$d = Get-OrchestrationGoalProgressDelta -Previous 'junk' -Current (New-GDMetrics @{})
Assert-GDThat ((-not [bool]$d.ok) -and (-not [bool]$d.meaningful)) 'non-object snapshot fails closed'
$d = Get-OrchestrationGoalProgressDelta -Previous @{ satisfied = 1 } -Current (New-GDMetrics @{ satisfied = 1 })
Assert-GDThat ((-not [bool]$d.ok) -and ([string]$d.reason -ceq 'invalid-input')) 'missing metrics fail closed'
# --- Invalid input still bumps stagnation (no valid progress observed).
$d = Get-OrchestrationGoalProgressDelta -Previous $null -Current $null -StagnationCount 2
Assert-GDThat (([long]$d.stagnation_count -eq 3) -and [bool]$d.strategy_change_required) 'invalid input bumps stagnation toward strategy change'
# --- Negative stagnation input clamps to 0.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{}) -Current (New-GDMetrics @{}) -StagnationCount -4
Assert-GDThat (([long]$d.stagnation_count -eq 1) -and (-not [bool]$d.strategy_change_required)) 'negative stagnation input clamps to 0 then bumps'
# --- Singleton array metric stays an array: invalid, never meaningful.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{ satisfied = @([int]3) }) -Current (New-GDMetrics @{ satisfied = @([int]3) })
Assert-GDThat (($null -ne $d) -and (-not [bool]$d.ok) -and (-not [bool]$d.meaningful) -and ([string]$d.reason -ceq 'invalid-input')) 'singleton int array metric fails closed'
# --- Stagnation saturates at MaxValue: gate stays on, never throws.
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{}) -Current (New-GDMetrics @{}) -StagnationCount ([long]::MaxValue)
Assert-GDThat (($null -ne $d) -and (-not [bool]$d.meaningful) -and ([long]$d.stagnation_count -eq [long]::MaxValue) -and [bool]$d.strategy_change_required) 'stagnation saturates at MaxValue with gate on'
$d = Get-OrchestrationGoalProgressDelta -Previous (New-GDMetrics @{}) -Current (New-GDMetrics @{}) -StagnationCount ([long]([long]::MaxValue - 1))
Assert-GDThat (([long]$d.stagnation_count -eq [long]::MaxValue) -and [bool]$d.strategy_change_required) 'MaxValue minus one saturates at MaxValue'
Write-Output "PASS OrchestrationGoalProgress: $passed assertions"
