[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalPromotion.ps1')
$passed = 0
function Assert-GPThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-GPSignals {
    param([hashtable]$Override = @{})
    $s = @{
        has_spec_plan          = $false
        phase_count            = 0
        expected_waves          = 0
        criteria_count          = 0
        likely_cross_session    = $false
        iterative_verification  = $false
        explicit_continuation   = $false
    }
    foreach ($k in @($Override.Keys)) { $s[$k] = $Override[$k] }
    return $s
}
# --- SPEC+PLAN alone promotes (strong PLAN preference).
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ has_spec_plan = $true })
Assert-GPThat (($null -ne $r) -and [bool]$r.promote -and ([long]$r.score -eq 3) -and ($r.shape -ceq 'persistent-goal')) 'SPEC+PLAN pure promotes with score 3'
Assert-GPThat ((@($r.reasons) -contains 'spec-plan') -and (@($r.reasons) -contains 'threshold-met')) 'SPEC+PLAN reasons explain the score'
# --- Empty signals stay a task with score 0.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{})
Assert-GPThat (($null -ne $r) -and (-not [bool]$r.promote) -and ([long]$r.score -eq 0) -and ($r.shape -ceq 'task')) 'empty signals stay task with score 0'
Assert-GPThat ((@($r.reasons) -contains 'below-threshold')) 'empty signals close below threshold'
# --- 2 phases alone do not promote (Jev threshold three).
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = 2 })
Assert-GPThat ((-not [bool]$r.promote) -and ([long]$r.score -eq 1) -and ($r.shape -ceq 'task')) '2 phases alone stay task with score 1'
# --- 3 phases + 3 waves promote exactly at threshold.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = 3; expected_waves = 3 })
Assert-GPThat ([bool]$r.promote -and ([long]$r.score -eq 3) -and ($r.shape -ceq 'persistent-goal')) '3 phases plus 3 waves promote with score 3'
# --- cross-session + explicit continuation promote.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ likely_cross_session = $true; explicit_continuation = $true })
Assert-GPThat ([bool]$r.promote -and ([long]$r.score -eq 4) -and ($r.shape -ceq 'persistent-goal')) 'cross-session plus explicit continuation promote with score 4'
# --- Negative counts clamp to 0.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = -5; expected_waves = -2; criteria_count = -9 })
Assert-GPThat ((-not [bool]$r.promote) -and ([long]$r.score -eq 0) -and ($r.shape -ceq 'task')) 'negative counts clamp to 0'
# --- Just below threshold stays task; one more wave promotes.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = 2; iterative_verification = $true })
Assert-GPThat ((-not [bool]$r.promote) -and ([long]$r.score -eq 2)) 'score 2 stays task'
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = 2; iterative_verification = $true; expected_waves = 3 })
Assert-GPThat ([bool]$r.promote -and ([long]$r.score -eq 3)) 'score 3 reaches threshold'
# --- Criteria alone: below threshold.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ criteria_count = 5 })
Assert-GPThat ((-not [bool]$r.promote) -and ([long]$r.score -eq 1)) 'criteria alone stay task with score 1'
# --- Full signal set accumulates every weight.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ has_spec_plan = $true; phase_count = 4; expected_waves = 3; criteria_count = 3; likely_cross_session = $true; iterative_verification = $true; explicit_continuation = $true })
Assert-GPThat ([bool]$r.promote -and ([long]$r.score -eq 12) -and ($r.shape -ceq 'persistent-goal')) 'full signals score 12'
# --- Non-numeric counts read as 0, non-bool flags as false.
$r = Test-OrchestrationGoalPromotion -Signals (New-GPSignals @{ phase_count = 'many'; has_spec_plan = 'yes' })
Assert-GPThat ((-not [bool]$r.promote) -and ([long]$r.score -eq 0)) 'non-numeric signals fail closed to 0'
# --- Invalid input fails closed, never throws, never returns null.
$r = Test-OrchestrationGoalPromotion -Signals $null
Assert-GPThat (($null -ne $r) -and (-not [bool]$r.promote) -and ([long]$r.score -eq 0) -and ($r.shape -ceq 'task') -and (@($r.reasons) -contains 'invalid-signals')) 'null signals fail closed'
$r = Test-OrchestrationGoalPromotion -Signals 'junk'
Assert-GPThat (($null -ne $r) -and (-not [bool]$r.promote) -and ([long]$r.score -eq 0)) 'non-object signals fail closed'
# --- PSObject input works like a hashtable.
$r = Test-OrchestrationGoalPromotion -Signals ([pscustomobject]@{ has_spec_plan = $true; phase_count = 0; expected_waves = 0; criteria_count = 0; likely_cross_session = $false; iterative_verification = $false; explicit_continuation = $false })
Assert-GPThat ([bool]$r.promote -and ([long]$r.score -eq 3)) 'psobject signals score like hashtable'
Write-Output "PASS OrchestrationGoalPromotion: $passed assertions"
