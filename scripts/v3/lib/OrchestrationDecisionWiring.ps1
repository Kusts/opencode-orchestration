<#!
.SYNOPSIS
    PR-4 Decision Wiring: single advisory path Rules -> JevAdvisory -> Planner.
.DESCRIPTION
    Dot-sourceable library (no execution on load). Fail-closed, PS 5.1
    compatible, ASCII-only. Never throws on operational paths: every
    failure returns a planner-escalation envelope with blocked=false.
    No network, no process spawn, no secret values in this file (env
    var NAMES only, values live in the operator-owned environment and
    are read by OrchestrationJevAdvisory.ps1 inside its own probe).

    The wiring CONNECTS the existing guards instead of duplicating
    them (CORRECTIVE-PLAN Fase 3, PR-4, HOLD mantido):

      Rules (OrchestrationDecisionProvider.ps1, shapes preserved)
        -> JevAdvisory transport (OrchestrationJevAdvisory.ps1,
           Invoke-JevAdvisoryCall: budget 30s, circuit 2/300s,
           closed 4-tool set, advisory-only authority)
        -> Planner (closed decision envelope; Planner decides,
           Jev never grants, never writes DONE, never verifies).

    Rules run first inside Invoke-OrchestrationDecision: unknown
    question types, empty sets, authority touches and model-override
    requests are refused there, and a single clean alternative is
    decided by rules alone (trivial_local never consults). Only an
    admitted multi-alternative question reaches the JevAdvisory
    transport, through one inner probe closure. A question mapped
    outside the closed tool set is never consulted.

    Jev output is advisory evidence only: the inner probe discards
    anything unmappable (throw -> deterministic escalation inside
    the provider) and the provider's own overreach/model filters
    still apply; every envelope carries grants_authority=false,
    done_approved=false and verified_pass=false. Jev unavailable
    (policy invalid, flag off, credential absent, transport not
    configured, envelope failure) is a safe deterministic fallback
    that never blocks the Objective (blocked=false always).

    Real-transport per-question wire mapping for jev_decide /
    jev_gate / jev_check / jev_score is built from the question so
    an operator-owned endpoint CAN serve it; exact-binary-live proof
    against a real endpoint is a declared pendency (harness uses the
    synthetic -JevProbe seam, zero real network).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    foreach ($DWLibName in @('OrchestrationDecisionProvider.ps1', 'OrchestrationJevAdvisory.ps1', 'OrchestrationMcpSafety.ps1')) {
        try {
            $DWLibPath = Join-Path $PSScriptRoot $DWLibName
            if (Test-Path -LiteralPath $DWLibPath -PathType Leaf) { . $DWLibPath }
        }
        catch { }
    }
}
catch { }

$script:DecisionWiringBudgetSeconds = 30
$script:DecisionWiringQuestionTool = @{
    'routing'     = 'jev_decide'
    'specialist'  = 'jev_decide'
    'parallel'    = 'jev_decide'
    'alternative' = 'jev_decide'
    'continue'    = 'jev_gate'
    'risk'        = 'jev_score'
    'evidence'    = 'jev_check'
    'hypothesis'  = 'jev_check'
}
$script:DecisionWiringAllowedTools = @('jev_check', 'jev_gate', 'jev_score', 'jev_decide')

function Get-OrchestrationDecisionWiringVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-DECISION-WIRING'
        phase          = 'PR-4'
        budget_seconds = [int]$script:DecisionWiringBudgetSeconds
    }
}

function Get-DWFieldValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-OrchestrationDecisionWiringTool {
    [CmdletBinding()]
    param([string]$QuestionType = '')
    try {
        $t = ([string]$QuestionType).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        if ($script:DecisionWiringQuestionTool.Contains($t)) {
            return [string]$script:DecisionWiringQuestionTool[$t]
        }
        return ''
    }
    catch { return '' }
}

function New-OrchestrationDecisionWiringEnvelope {
    [CmdletBinding()]
    param($Decision = $null, [string]$Tool = '', [bool]$Consulted = $false,
        [string]$Transport = 'none', [int]$BudgetS = 30,
        [string]$Circuit = 'NOT_CONSULTED', [int]$Consecutive = 0)
    try {
        $qid = ''
        $qtype = ''
        $dec = ''
        $src = 'planner-escalation'
        $conf = 0.0
        $alts = 0
        $fb = $true
        $reason = 'internal-error'
        try { $qid = [string](Get-DWFieldValue $Decision 'question_id' '') } catch { $qid = '' }
        try { $qtype = [string](Get-DWFieldValue $Decision 'question_type' '') } catch { $qtype = '' }
        try { $dec = [string](Get-DWFieldValue $Decision 'decision' '') } catch { $dec = '' }
        try { $src = [string](Get-DWFieldValue $Decision 'source' 'planner-escalation') } catch { $src = 'planner-escalation' }
        try { $conf = [double](Get-DWFieldValue $Decision 'confidence' 0.0) } catch { $conf = 0.0 }
        try { $alts = [int](Get-DWFieldValue $Decision 'alternatives_considered' 0) } catch { $alts = 0 }
        try { $fb = [bool](Get-DWFieldValue $Decision 'fallback_used' $true) } catch { $fb = $true }
        try {
            $rr = [string](Get-DWFieldValue $Decision 'reason' 'internal-error')
            if (-not [string]::IsNullOrWhiteSpace($rr)) { $reason = $rr }
        }
        catch { $reason = 'internal-error' }
        if ([double]::IsNaN($conf) -or [double]::IsInfinity($conf)) { $conf = 0.0 }
        if ($conf -lt 0.0) { $conf = 0.0 }
        if ($conf -gt 1.0) { $conf = 1.0 }
        return [pscustomobject]@{
            question_id            = $qid
            question_type          = $qtype
            decision               = $dec
            source                 = $src
            confidence             = $conf
            alternatives_considered = $alts
            fallback_used          = $fb
            blocked                = $false
            reason                 = $reason
            tool                   = ([string]$Tool)
            consulted              = [bool]$Consulted
            transport              = ([string]$Transport)
            budget_s               = [int]$BudgetS
            circuit                = ([string]$Circuit)
            consecutive            = [int]$Consecutive
            grants_authority       = $false
            done_approved          = $false
            verified_pass          = $false
            planner_decides        = $true
        }
    }
    catch {
        return [pscustomobject]@{
            question_id = ''; question_type = ''; decision = ''
            source = 'planner-escalation'; confidence = 0.0
            alternatives_considered = 0; fallback_used = $true
            blocked = $false; reason = 'internal-error'
            tool = ''; consulted = $false; transport = 'none'
            budget_s = 30; circuit = 'NOT_CONSULTED'; consecutive = 0
            grants_authority = $false; done_approved = $false
            verified_pass = $false; planner_decides = $true
        }
    }
}

function New-DWToolArgs {
    param([string]$Tool = '', [string]$QuestionId = '', [object[]]$Alternatives = @())
    try {
        $t = ([string]$Tool).Trim().ToLowerInvariant()
        $qid = ([string]$QuestionId).Trim()
        if ([string]::IsNullOrWhiteSpace($qid)) { $qid = 'decision-question' }
        $clean = New-Object System.Collections.Generic.List[string]
        foreach ($a in @($Alternatives)) {
            $s = ([string]$a).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $clean.Add($s) | Out-Null
        }
        if ($t -ceq 'jev_gate') {
            return @{ action = $qid; context = ([string]::Join(' | ', $clean.ToArray())) }
        }
        if ($t -ceq 'jev_check') {
            return @{ instructions = $qid }
        }
        if ($t -ceq 'jev_score') {
            return @{ instructions = $qid; levels = @($clean.ToArray()) }
        }
        $crit = [ordered]@{}
        foreach ($s in @($clean.ToArray())) { $crit[$s] = $s }
        return @{ questions = @{ decision = @{ type = 'choice'; instructions = $qid; criteria = $crit } } }
    }
    catch { return $null }
}

function Test-DWStructuredAuthorityOverreach {
    param($Output)
    try {
        if ($null -eq $Output) { return $false }
        $names = @('grants_authority', 'granted', 'widened', 'model_selected', 'done_written', 'done_approved', 'verified_pass')
        foreach ($n in $names) {
            $v = $null
            $present = $false
            try {
                if ($Output -is [System.Collections.IDictionary]) {
                    if ($Output.Contains($n)) { $v = $Output[$n]; $present = $true }
                }
                else {
                    $p = $Output.PSObject.Properties[$n]
                    if ($null -ne $p) { $v = $p.Value; $present = $true }
                }
            }
            catch { continue }
            if (-not $present) { continue }
            if ($v -is [bool]) { if ([bool]$v) { return $true } }
            elseif (($v -is [int]) -or ($v -is [long]) -or ($v -is [double])) {
                try { if ([double]$v -ne 0) { return $true } } catch { return $true }
            }
            elseif ($v -is [string]) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return $true } }
            elseif ($null -ne $v) { return $true }
        }
        return $false
    }
    catch { return $true }
}

function Invoke-OrchestrationDecisionWiring {
    [CmdletBinding()]
    param(
        [string]$QuestionId = '',
        [string]$QuestionType = '',
        [object[]]$Alternatives = @(),
        $State = $null,
        [string]$Risk = 'low',
        [string]$TurnId = '',
        $Descriptor = $null,
        [string]$Tool = '',
        $ToolArgs = $null,
        [scriptblock]$JevProbe = $null,
        [string]$PolicyPath = '',
        [string]$FlagsPath = '',
        [string]$McpPolicyPath = '',
        [string]$TelemetryRoot = '',
        [string]$RepoRoot = '',
        [int]$BudgetSecondsOverride = 0,
        $ApiKey = $null,
        $NowUtc = $null,
        $ConcludedAtUtc = $null
    )
    try {
        $hasProvider = ((Get-Command Invoke-OrchestrationDecision -ErrorAction SilentlyContinue) -ne $null)
        $hasAdvisory = ((Get-Command Invoke-JevAdvisoryCall -ErrorAction SilentlyContinue) -ne $null)
        $qid = ([string]$QuestionId).Trim()
        $qtype = ([string]$QuestionType).Trim().ToLowerInvariant()
        $budget = [int]$script:DecisionWiringBudgetSeconds
        if (([int]$BudgetSecondsOverride -gt 0) -and ([int]$BudgetSecondsOverride -lt $budget)) {
            $budget = [int]$BudgetSecondsOverride
        }

        $noConsult = {
            param($Why)
            $blank = $null
            try { $blank = New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype -Decision '' -Source 'planner-escalation' -Confidence 0.0 -AlternativesConsidered 0 -FallbackUsed $true -Reason ([string]$Why) } catch { $blank = $null }
            return (New-OrchestrationDecisionWiringEnvelope -Decision $blank -Tool '' -Consulted $false -Transport 'none' -BudgetS $budget)
        }

        if (-not $hasProvider) {
            return (& $noConsult 'decision-provider-unavailable')
        }

        $mapped = Get-OrchestrationDecisionWiringTool -QuestionType $qtype
        $wanted = ([string]$Tool).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($wanted)) {
            if ($script:DecisionWiringAllowedTools -notcontains $wanted) {
                return (& $noConsult 'tool-outside-closed-set-no-consult')
            }
            $mapped = $wanted
        }
        if ([string]::IsNullOrWhiteSpace($mapped)) {
            return (& $noConsult 'question-outside-toolset-no-consult')
        }

        $desc = $Descriptor
        if ($null -eq $desc) { $desc = @{ route_uncertain = $true } }
        $shouldConsult = $true
        try {
            $trigCmd = Get-Command Test-JevAdvisoryTrigger -ErrorAction SilentlyContinue
            if ($null -ne $trigCmd) {
                $trig = Test-JevAdvisoryTrigger -Descriptor $desc
                $shouldConsult = [bool](Get-DWFieldValue $trig 'should_consult' $false)
            }
        }
        catch { $shouldConsult = $false }
        $turnOk = $false
        try {
            $turnCmd = Get-Command Test-JevAdvisoryTurnId -ErrorAction SilentlyContinue
            if ($null -ne $turnCmd) { $turnOk = [bool](Test-JevAdvisoryTurnId -Value ([string]$TurnId)) }
            else { $turnOk = (-not [string]::IsNullOrWhiteSpace(([string]$TurnId).Trim())) }
        }
        catch { $turnOk = $false }
        if (-not $hasAdvisory) { $shouldConsult = $false }

        if ((-not $shouldConsult) -or (-not $turnOk)) {
            $why = 'jev-trigger-no-consult'
            if (-not $hasAdvisory) { $why = 'jev-transport-unavailable-no-consult' }
            elseif (-not $turnOk) { $why = 'invalid-turn-id-no-consult' }
            $rulesOnly = $null
            try {
                $rulesOnly = Invoke-OrchestrationDecision -QuestionId $qid -QuestionType $qtype -Alternatives $Alternatives -State $State -Risk $Risk -AllowJev $false -JevProbe $null
            }
            catch { $rulesOnly = $null }
            if ($null -eq $rulesOnly) {
                return (& $noConsult $why)
            }
            $r = ([string](Get-DWFieldValue $rulesOnly 'reason' ''))
            if ($r -ceq 'jev-disabled-by-caller') {
                try { $rulesOnly.reason = $why } catch { }
            }
            return (New-OrchestrationDecisionWiringEnvelope -Decision $rulesOnly -Tool $mapped -Consulted $false -Transport 'none' -BudgetS $budget)
        }

        $stateText = ''
        try {
            if ($State -is [string]) { $stateText = ([string]$State).Trim() }
            elseif ($null -ne $State) { $stateText = ($State | ConvertTo-Json -Depth 4 -Compress) }
        }
        catch { $stateText = '' }
        if ([string]::IsNullOrWhiteSpace($stateText)) { $stateText = 'decision-state-present' }
        $wireArgs = $ToolArgs
        if ($null -eq $wireArgs) { $wireArgs = New-DWToolArgs -Tool $mapped -QuestionId $qid -Alternatives $Alternatives }

        $cap = @{ adv = $null; gate = $null; grant_block = $false; structured_block = $false }
        $wTurn = ([string]$TurnId).Trim()
        $wDesc = $desc
        $wStateText = $stateText
        $wWireArgs = $wireArgs
        $wMapped = $mapped
        $wProbe = $JevProbe
        $wPolicy = ([string]$PolicyPath)
        $wFlags = ([string]$FlagsPath)
        $wMcp = ([string]$McpPolicyPath)
        $wTele = ([string]$TelemetryRoot)
        $wRepo = ([string]$RepoRoot)
        $wBudget = [int]$budget
        $wApiBound = $PSBoundParameters.ContainsKey('ApiKey')
        $wApi = $ApiKey
        $wNow = $NowUtc
        $wConcl = $ConcludedAtUtc

        $inner = {
            param($ctx)
            $advParams = @{
                Tool = $wMapped; TurnId = $wTurn; Descriptor = $wDesc
                State = $wStateText; BudgetSecondsOverride = $wBudget
                PolicyPath = $wPolicy; FlagsPath = $wFlags; McpPolicyPath = $wMcp
                TelemetryRoot = $wTele; RepoRoot = $wRepo
                NowUtc = $wNow; ConcludedAtUtc = $wConcl
            }
            if ($null -ne $wWireArgs) { $advParams['ToolArgs'] = $wWireArgs }
            if ($null -ne $wProbe) { $advParams['Probe'] = $wProbe; $advParams['ProbeArgs'] = @() }
            if ($wApiBound) { $advParams['ApiKey'] = $wApi }
            $adv = $null
            try { $adv = Invoke-JevAdvisoryCall @advParams }
            catch { $adv = $null }
            $cap['adv'] = $adv
            if (($null -eq $adv) -or ([string](Get-DWFieldValue $adv 'status' '') -cne 'JEV_ADVISORY_OK')) {
                throw 'jev-transport-unavailable'
            }
            $gate = $null
            try { $gate = Invoke-JevAdvisoryGrantGate -JevResult (Get-DWFieldValue $adv 'output' $null) }
            catch { $gate = $null }
            $cap['gate'] = $gate
            if ($null -eq $gate) { $cap['grant_block'] = $true; throw 'jev-grant-gate-failed' }
            $gateBlocked = $false
            try {
                $gStatus = ([string](Get-DWFieldValue $gate 'status' '')).Trim()
                if ($gStatus -cne 'JEV_ADVISORY_CANNOT_GRANT') { $gateBlocked = $true }
                else {
                    foreach ($gf in @('granted', 'widened', 'model_selected', 'done_written')) {
                        $gv = $false
                        try { $gv = [bool](Get-DWFieldValue $gate $gf $false) } catch { $gv = $true }
                        if ($gv) { $gateBlocked = $true; break }
                    }
                }
            }
            catch { $gateBlocked = $true }
            if ($gateBlocked) { $cap['grant_block'] = $true; throw 'jev-grant-gate-blocked' }
            $out = Get-DWFieldValue $adv 'output' $null
            if (Test-DWStructuredAuthorityOverreach -Output $out) { $cap['structured_block'] = $true; throw 'jev-overreach-discarded' }
            $picked = ([string](Get-DWFieldValue $out 'decision' '')).Trim()
            $confRaw = Get-DWFieldValue $out 'confidence' $null
            if ([string]::IsNullOrWhiteSpace($picked)) { throw 'jev-output-unmappable' }
            if ($null -eq $confRaw) { throw 'jev-output-unmappable' }
            $advice = ([string](Get-DWFieldValue $out 'advice' ''))
            return @{ decision = $picked; confidence = $confRaw; advice = $advice }
        }.GetNewClosure()

        $dec = $null
        try {
            $dec = Invoke-OrchestrationDecision -QuestionId $qid -QuestionType $qtype -Alternatives $Alternatives -State $State -Risk $Risk -AllowJev $true -JevProbe $inner
        }
        catch { $dec = $null }
        if ($null -eq $dec) {
            return (& $noConsult 'decision-internal-escalation')
        }
        try {
            $decReason = ([string](Get-DWFieldValue $dec 'reason' ''))
            if (($decReason -ceq 'jev-failed-escalation') -and [bool]$cap['structured_block']) {
                try { $dec.reason = 'jev-overreach-discarded' } catch { }
            }
            elseif ((($decReason -ceq 'jev-failed-escalation') -or ($decReason -ceq 'jev-malformed-escalation')) -and [bool]$cap['grant_block']) {
                try { $dec.reason = 'jev-grant-gate-blocked' } catch { }
            }
        }
        catch { }
        $consulted = ($null -ne $cap['adv'])
        $cir = 'NOT_CONSULTED'
        $consec = 0
        $transport = 'none'
        if ($consulted) {
            $transport = 'jev-advisory'
            try {
                $c = ([string](Get-DWFieldValue $cap['adv'] 'circuit' '')).Trim().ToUpperInvariant()
                if (-not [string]::IsNullOrWhiteSpace($c)) { $cir = $c }
            }
            catch { $cir = 'CLOSED' }
            try { $consec = [int](Get-DWFieldValue $cap['adv'] 'consecutive' 0) } catch { $consec = 0 }
        }
        return (New-OrchestrationDecisionWiringEnvelope -Decision $dec -Tool $mapped -Consulted $consulted -Transport $transport -BudgetS $budget -Circuit $cir -Consecutive $consec)
    }
    catch {
        $blank = $null
        try { $blank = New-OrchestrationDecisionEnvelope -QuestionId ([string]$QuestionId) -QuestionType ([string]$QuestionType) -Decision '' -Source 'planner-escalation' -Confidence 0.0 -AlternativesConsidered 0 -FallbackUsed $true -Reason 'decision-wiring-internal-escalation' } catch { $blank = $null }
        return (New-OrchestrationDecisionWiringEnvelope -Decision $blank -Tool '' -Consulted $false -Transport 'none' -BudgetS 30)
    }
}
