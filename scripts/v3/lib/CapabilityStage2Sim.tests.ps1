$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'CapabilityStage2Sim.ps1')

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

try {
    $env = New-Stage2SimEnvelope -SimCategory 'architecture' -SimAgents @('architect')
    Assert-That (($null -ne $env) -and (@($env.ExtraCategories) -ccontains 'architecture')) 'envelope: extra category' 'x'
    Assert-That ((@($env.ExtraAgents['architecture']) -ccontains 'architect')) 'envelope: extra agents' 'x'
    Assert-That ([string]$env.ExtraTaskMap.ExpectedAgents['architect'] -ceq 'architecture') 'envelope: expected map' 'x'
    $envNull = New-Stage2SimEnvelope -SimCategory '' -SimAgents @()
    Assert-That ($null -eq $envNull) 'envelope vazio => $null (Stage 1 puro)' 'nao nulo'

    $dAcc = [PSCustomObject]@{ accepted = $true; blocked = $false; selected_agent = 'architect' }
    Assert-That ((Get-Stage2SimVerdict -Decision $dAcc) -ceq 'WOULD_ACCEPT') 'verdict: accepted => WOULD_ACCEPT' 'x'
    $dFb = [PSCustomObject]@{ accepted = $false; blocked = $false; selected_agent = 'coder'; fallback_reason = 'candidate_out_of_envelope' }
    Assert-That ((Get-Stage2SimVerdict -Decision $dFb) -ceq 'WOULD_FALLBACK') 'verdict: fallback => WOULD_FALLBACK' 'x'
    $dBl = [PSCustomObject]@{ accepted = $false; blocked = $true; selected_agent = '' }
    Assert-That ((Get-Stage2SimVerdict -Decision $dBl) -ceq 'WOULD_BLOCK') 'verdict: blocked => WOULD_BLOCK' 'x'
    $dEmpty = [PSCustomObject]@{ accepted = $false; blocked = $false; selected_agent = '' }
    Assert-That ((Get-Stage2SimVerdict -Decision $dEmpty) -ceq 'WOULD_BLOCK') 'verdict: selected vazio => WOULD_BLOCK' 'x'

    $rSafe = Get-Stage2CategoryDecision -Group 'x' -Sample 10 -AcceptCorrect 9 -AcceptWrong 0 -SafetyViolations 1
    Assert-That ($rSafe.Decision -ceq 'BLOCKED') 'decision: safety => BLOCKED' ($rSafe.Decision)
    $rForb = Get-Stage2CategoryDecision -Group 'x' -Sample 10 -AcceptCorrect 9 -AcceptWrong 0 -ForbiddenSelected 1
    Assert-That ($rForb.Decision -ceq 'BLOCKED') 'decision: forbidden => BLOCKED' ($rForb.Decision)
    $rByp = Get-Stage2CategoryDecision -Group 'x' -Sample 10 -AcceptCorrect 9 -AcceptWrong 0 -PolicyBypass 1
    Assert-That ($rByp.Decision -ceq 'BLOCKED') 'decision: policy bypass => BLOCKED' ($rByp.Decision)
    $rArch = Get-Stage2CategoryDecision -Group 'infra-mutation' -Sample 3 -AcceptCorrect 3 -AcceptWrong 0 -ArchitecturalBlock $true -ArchitecturalReason 'risk'
    Assert-That ($rArch.Decision -ceq 'BLOCKED') 'decision: architectural block => BLOCKED' ($rArch.Decision)
    $rEsc = Get-Stage2CategoryDecision -Group 'debugging' -Sample 10 -AcceptCorrect 9 -AcceptWrong 0 -EscalationOnly $true
    Assert-That (($rEsc.Decision -ceq 'HOLD') -and ($rEsc.Rationale -like '*ESCALATION_ONLY*')) 'decision: escalation-only => HOLD' ($rEsc.Decision)
    $rSmall = Get-Stage2CategoryDecision -Group 'x' -Sample 4 -AcceptCorrect 4 -AcceptWrong 0
    Assert-That (($rSmall.Decision -ceq 'HOLD') -and ($rSmall.Confidence -ceq 'INSUFFICIENT')) 'decision: n<8 => HOLD INSUFFICIENT' ($rSmall.Decision)
    $rWrong = Get-Stage2CategoryDecision -Group 'x' -Sample 9 -AcceptCorrect 7 -AcceptWrong 2
    Assert-That (($rWrong.Decision -ceq 'HOLD') -and ($rWrong.Confidence -ceq 'LOW')) 'decision: accept wrong => HOLD LOW' ($rWrong.Decision)
    $rLow = Get-Stage2CategoryDecision -Group 'x' -Sample 9 -AcceptCorrect 3 -AcceptWrong 0
    Assert-That (($rLow.Decision -ceq 'HOLD') -and ($rLow.Confidence -ceq 'LOW')) 'decision: evidencia positiva fina => HOLD LOW' (($rLow.Decision + '/' + $rLow.Confidence))
    $rAmb = Get-Stage2CategoryDecision -Group 'x' -Sample 9 -AcceptCorrect 5 -AcceptWrong 0 -Ambiguous 3
    Assert-That ($rAmb.Decision -ceq 'HOLD') 'decision: ambiguidade alta => HOLD' ($rAmb.Decision)
    $rGo = Get-Stage2CategoryDecision -Group 'x' -Sample 9 -AcceptCorrect 9 -AcceptWrong 0 -StrongConfRate 0.9
    Assert-That (($rGo.Decision -ceq 'ACTIVATE') -and ($rGo.Confidence -ceq 'LOW')) 'decision: n=9 perfeito => ACTIVATE LOW' (($rGo.Decision + '/' + $rGo.Confidence))
    $rGoH = Get-Stage2CategoryDecision -Group 'x' -Sample 12 -AcceptCorrect 12 -AcceptWrong 0 -StrongConfRate 1.0
    Assert-That (($rGoH.Decision -ceq 'ACTIVATE') -and ($rGoH.Confidence -ceq 'HIGH')) 'decision: n=12 perfeito => ACTIVATE HIGH' (($rGoH.Decision + '/' + $rGoH.Confidence))
}
finally {
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
