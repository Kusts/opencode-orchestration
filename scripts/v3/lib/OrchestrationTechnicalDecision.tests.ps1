[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTechnicalDecision.ps1')
$passed = 0
function Assert-TDThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-TDArgs {
    param([hashtable]$Override = @{})
    $a = @{
        GoalId         = 'G-001'
        TaskId         = 'T-001'
        Question       = 'Which retry policy?'
        Alternatives   = @('fixed-backoff', 'exponential-backoff')
        Selected       = 'exponential-backoff'
        Rationale      = 'Backs off under sustained failure without hammering.'
        EvidenceRefs   = @('ev:run-42')
        Risk           = 'low'
        Reversibility  = 'high'
        DecidedBy      = 'planner'
    }
    foreach ($k in @($Override.Keys)) { $a[$k] = $Override[$k] }
    return $a
}
function New-TDDecision {
    param([hashtable]$Override = @{})
    $a = New-TDArgs $Override
    return (New-OrchestrationTechnicalDecision -GoalId $a.GoalId -TaskId $a.TaskId -Question $a.Question -Alternatives $a.Alternatives -Selected $a.Selected -Rationale $a.Rationale -EvidenceRefs $a.EvidenceRefs -Risk $a.Risk -Reversibility $a.Reversibility -DecidedBy $a.DecidedBy)
}
# --- Happy path builds a complete record.
$n = New-TDDecision
Assert-TDThat (($null -ne $n) -and [bool]$n.ok -and ([string]$n.reason -ceq '') -and ($null -ne $n.decision)) 'valid decision builds ok'
Assert-TDThat (([string]$n.decision.decision_id).Length -eq 16 -and ([string]$n.decision.decision_id -cmatch '^[0-9a-f]{16}$')) 'decision_id is 16 lowercase hex chars'
Assert-TDThat ((-not [string]::IsNullOrWhiteSpace([string]$n.decision.timestamp)) -and ([string]$n.decision.selected -ceq 'exponential-backoff') -and ([string]$n.decision.reversibility -ceq 'high')) 'record carries selected reversibility and timestamp'
# --- Deterministic id: same input yields same id.
$a = New-TDDecision
$b = New-TDDecision
Assert-TDThat (([string]$a.decision.decision_id -ceq [string]$b.decision.decision_id)) 'same input yields same decision_id'
# --- Different content yields a different id.
$c = New-TDDecision @{ Selected = 'fixed-backoff'; Alternatives = @('fixed-backoff', 'exponential-backoff') }
Assert-TDThat (([string]$c.decision.decision_id -cne [string]$a.decision.decision_id)) 'different selection yields different decision_id'
# --- Selected outside alternatives is rejected.
$n = New-TDDecision @{ Selected = 'no-backoff' }
Assert-TDThat (($null -ne $n) -and (-not [bool]$n.ok) -and ([string]$n.reason -ceq 'selected-not-in-alternatives') -and ($null -eq $n.decision)) 'selected outside alternatives is rejected'
# --- Invalid reversibility is rejected; casing normalizes.
$n = New-TDDecision @{ Reversibility = 'extreme' }
Assert-TDThat ((-not [bool]$n.ok) -and ([string]$n.reason -ceq 'invalid-reversibility')) 'invalid reversibility is rejected'
$n = New-TDDecision @{ Reversibility = 'Medium' }
Assert-TDThat ([bool]$n.ok -and ([string]$n.decision.reversibility -ceq 'medium')) 'reversibility casing normalizes'
$n = New-TDDecision @{ Reversibility = 'low' }
Assert-TDThat ([bool]$n.ok) 'low reversibility is accepted'
# --- Empty question / selected / rationale are rejected.
$n = New-TDDecision @{ Question = '   ' }
Assert-TDThat ((-not [bool]$n.ok) -and ([string]$n.reason -ceq 'invalid-question')) 'empty question is rejected'
$n = New-TDDecision @{ Selected = '' }
Assert-TDThat ((-not [bool]$n.ok) -and ([string]$n.reason -ceq 'invalid-selected')) 'empty selected is rejected'
$n = New-TDDecision @{ Rationale = '' }
Assert-TDThat ((-not [bool]$n.ok) -and ([string]$n.reason -ceq 'invalid-rationale')) 'empty rationale is rejected'
# --- Empty alternatives cannot contain the selection.
$n = New-TDDecision @{ Alternatives = @() }
Assert-TDThat ((-not [bool]$n.ok) -and ([string]$n.reason -ceq 'selected-not-in-alternatives')) 'empty alternatives reject any selection'
# --- Revalidation passes for a built record (hydration path).
$built = (New-TDDecision).decision
$v = Test-OrchestrationTechnicalDecisionValid -Decision $built
Assert-TDThat (($null -ne $v) -and [bool]$v.ok) 'built record revalidates'
# --- Revalidation catches semantic drift without generating an id.
$drifted = @{
    question = 'Which retry policy?'; alternatives = @('fixed-backoff'); selected = 'exponential-backoff'
    rationale = 'r'; evidence_refs = @(); reversibility = 'high'
}
$v = Test-OrchestrationTechnicalDecisionValid -Decision $drifted
Assert-TDThat ((-not [bool]$v.ok) -and ([string]$v.reason -ceq 'selected-not-in-alternatives')) 'drifted selected fails revalidation'
$v = Test-OrchestrationTechnicalDecisionValid -Decision $null
Assert-TDThat ((-not [bool]$v.ok) -and ([string]$v.reason -ceq 'invalid-decision')) 'null decision fails revalidation'
$v = Test-OrchestrationTechnicalDecisionValid -Decision 'junk'
Assert-TDThat ((-not [bool]$v.ok)) 'non-object decision fails revalidation'
# --- Pipe inside an alternative does not collide with split alternatives.
$p = New-TDDecision @{ Alternatives = @('a', 'b|c'); Selected = 'a' }
$q = New-TDDecision @{ Alternatives = @('a', 'b', 'c'); Selected = 'a' }
Assert-TDThat ([bool]$p.ok -and [bool]$q.ok) 'pipe variants build ok'
Assert-TDThat (([string]$p.decision.decision_id -cne [string]$q.decision.decision_id)) 'pipe inside alternative does not collide with split alternatives'
# --- Newline split across fields does not collide.
$r1 = New-TDDecision @{ GoalId = "X`nY"; TaskId = 'Z' }
$r2 = New-TDDecision @{ GoalId = 'X'; TaskId = "Y`nZ" }
Assert-TDThat ([bool]$r1.ok -and [bool]$r2.ok) 'newline variants build ok'
Assert-TDThat (([string]$r1.decision.decision_id -cne [string]$r2.decision.decision_id)) 'newline across fields does not collide'
Write-Output "PASS OrchestrationTechnicalDecision: $passed assertions"
