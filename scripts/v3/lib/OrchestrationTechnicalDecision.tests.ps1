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
# --- Identity fields are required at creation.
$ni = New-TDDecision @{ GoalId = '   ' }
Assert-TDThat ((-not [bool]$ni.ok) -and ([string]$ni.reason -ceq 'invalid-goal-id')) 'empty goal id is rejected'
$ni = New-TDDecision @{ TaskId = '' }
Assert-TDThat ((-not [bool]$ni.ok) -and ([string]$ni.reason -ceq 'invalid-task-id')) 'empty task id is rejected'
$ni = New-TDDecision @{ Risk = '   ' }
Assert-TDThat ((-not [bool]$ni.ok) -and ([string]$ni.reason -ceq 'invalid-risk')) 'empty risk is rejected'
$ni = New-TDDecision @{ DecidedBy = '' }
Assert-TDThat ((-not [bool]$ni.ok) -and ([string]$ni.reason -ceq 'invalid-decided-by')) 'empty decided-by is rejected'
# --- Revalidation recomputes the decision id (tamper/cross-goal fail).
$goodRec = (New-TDDecision).decision
$vg = Test-OrchestrationTechnicalDecisionValid -Decision $goodRec
Assert-TDThat ([bool]$vg.ok) 'untampered record revalidates'
$zeroed = @{}
foreach ($p in @($goodRec.PSObject.Properties)) { $zeroed[$p.Name] = $p.Value }
$zeroed['decision_id'] = '0000000000000000'
$vz = Test-OrchestrationTechnicalDecisionValid -Decision $zeroed
Assert-TDThat ((-not [bool]$vz.ok) -and ([string]$vz.reason -ceq 'decision-id-mismatch')) 'zeroed id with valid fields fails revalidation'
$moved = @{}
foreach ($p in @($goodRec.PSObject.Properties)) { $moved[$p.Name] = $p.Value }
$moved['goal_id'] = 'G-999'
$vm = Test-OrchestrationTechnicalDecisionValid -Decision $moved
Assert-TDThat ((-not [bool]$vm.ok) -and ([string]$vm.reason -ceq 'decision-id-mismatch')) 'record moved to another goal fails revalidation'
$noId = @{}
foreach ($p in @($goodRec.PSObject.Properties)) { $noId[$p.Name] = $p.Value }
$noId.Remove('decision_id')
$vn = Test-OrchestrationTechnicalDecisionValid -Decision $noId
Assert-TDThat ((-not [bool]$vn.ok) -and ([string]$vn.reason -ceq 'decision-id-mismatch')) 'record without id fails revalidation'
# --- Strict hydration: legacy record with empty identity fails even with a matching hash.
$legacy = @{}
foreach ($p in @($goodRec.PSObject.Properties)) { $legacy[$p.Name] = $p.Value }
$legacy['goal_id'] = ''
$legacy['decision_id'] = (Get-TDDecisionId -GoalId '' -TaskId ([string]$legacy['task_id']) -Question ([string]$legacy['question']) -Alternatives ([string[]]$legacy['alternatives']) -Selected ([string]$legacy['selected']) -Rationale ([string]$legacy['rationale']) -EvidenceRefs ([string[]]$legacy['evidence_refs']) -Risk ([string]$legacy['risk']) -Reversibility ([string]$legacy['reversibility']) -DecidedBy ([string]$legacy['decided_by']))
$vl = Test-OrchestrationTechnicalDecisionValid -Decision $legacy
Assert-TDThat ((-not [bool]$vl.ok) -and ([string]$vl.reason -ceq 'invalid-goal-id')) 'legacy record with empty identity fails revalidation even with matching hash'
$legacyTask = @{}
foreach ($p in @($goodRec.PSObject.Properties)) { $legacyTask[$p.Name] = $p.Value }
$legacyTask['decided_by'] = '   '
$legacyTask['decision_id'] = (Get-TDDecisionId -GoalId ([string]$legacyTask['goal_id']) -TaskId ([string]$legacyTask['task_id']) -Question ([string]$legacyTask['question']) -Alternatives ([string[]]$legacyTask['alternatives']) -Selected ([string]$legacyTask['selected']) -Rationale ([string]$legacyTask['rationale']) -EvidenceRefs ([string[]]$legacyTask['evidence_refs']) -Risk ([string]$legacyTask['risk']) -Reversibility ([string]$legacyTask['reversibility']) -DecidedBy '   ')
$vt = Test-OrchestrationTechnicalDecisionValid -Decision $legacyTask
Assert-TDThat ((-not [bool]$vt.ok) -and ([string]$vt.reason -ceq 'invalid-decided-by')) 'legacy record with blank decided-by fails revalidation even with matching hash'
# --- Intact record with identity revalidates under strict hydration (regression).
$vi = Test-OrchestrationTechnicalDecisionValid -Decision $goodRec
Assert-TDThat ([bool]$vi.ok) 'intact record with identity revalidates under strict hydration'
Write-Output "PASS OrchestrationTechnicalDecision: $passed assertions"
