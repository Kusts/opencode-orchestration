[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceRef.ps1')
$passed = 0
function Assert-EVThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-EVRefArgs {
    return @{
        EvidenceId        = 'ev.1'
        GoalId            = 'UT.goal:1'
        TaskId            = 'TASK-1'
        RunId             = 'RUN-1'
        Producer          = 'coder'
        ArtifactRef       = 'store:ev.1'
        Hash              = 'abcdef0123456789'
        VerificationState = 'verified'
        Provenance        = 'kernel:TASK-1'
    }
}
function New-EVGoodHandoff {
    $a = New-EVRefArgs
    $r = New-OrchestrationEvidenceRef @a
    return New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'candidate_pass' -KeyFindings @('f1') -EvidenceRefs @($r.ref) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
}
# --- Valid ref builds with every field.
$refArgs = New-EVRefArgs
$r = New-OrchestrationEvidenceRef @refArgs
Assert-EVThat ([bool]$r.ok -and ([string]$r.reason -ceq '') -and ($null -ne $r.ref)) 'valid ref builds'
Assert-EVThat (([string]$r.ref['evidence_id'] -ceq 'ev.1') -and ([string]$r.ref['hash'] -ceq 'abcdef0123456789') -and ([string]$r.ref['verification_state'] -ceq 'verified')) 'ref keeps ids hash and state'
# --- Hash too short and state outside the set are invalid.
$a = New-EVRefArgs; $a['Hash'] = 'abc123'
$short = New-OrchestrationEvidenceRef @a
Assert-EVThat ((-not [bool]$short.ok) -and ([string]$short.reason -ceq 'invalid-hash') -and ($null -eq $short.ref)) 'short hash is invalid'
$a = New-EVRefArgs; $a['Hash'] = 'ABCDEF0123456789'
$upper = New-OrchestrationEvidenceRef @a
Assert-EVThat ((-not [bool]$upper.ok) -and ([string]$upper.reason -ceq 'invalid-hash')) 'uppercase hash is invalid'
$a = New-EVRefArgs; $a['VerificationState'] = 'pending'
$st = New-OrchestrationEvidenceRef @a
Assert-EVThat ((-not [bool]$st.ok) -and ([string]$st.reason -ceq 'invalid-verification-state')) 'state outside the set is invalid'
$a = New-EVRefArgs; $a['VerificationState'] = 'Verified'
$stCase = New-OrchestrationEvidenceRef @a
Assert-EVThat (-not [bool]$stCase.ok) 'state match is case-sensitive'
# --- Empty fields are invalid, never accepted silently.
foreach ($field in @('EvidenceId', 'GoalId', 'TaskId', 'RunId', 'Producer', 'ArtifactRef', 'Hash', 'VerificationState', 'Provenance')) {
    $a = New-EVRefArgs; $a[$field] = ''
    $bad = New-OrchestrationEvidenceRef @a
    Assert-EVThat (-not [bool]$bad.ok) "empty $field is invalid"
}
$a = New-EVRefArgs; $a['EvidenceId'] = 'has space!'
$badId = New-OrchestrationEvidenceRef @a
Assert-EVThat ((-not [bool]$badId.ok) -and ([string]$badId.reason -ceq 'invalid-evidence-id')) 'malformed id is invalid'
# --- Every verification state in the set builds.
foreach ($s in @('unverified', 'verified', 'stale', 'revoked')) {
    $a = New-EVRefArgs; $a['VerificationState'] = $s
    $one = New-OrchestrationEvidenceRef @a
    Assert-EVThat ([bool]$one.ok) "state $s builds"
}
# --- Valid handoff builds and revalidates clean.
$h = New-EVGoodHandoff
Assert-EVThat ([bool]$h.ok -and ($null -ne $h.handoff)) 'valid handoff builds'
Assert-EVThat (([string]$h.handoff['task_id'] -ceq 'TASK-1') -and ([string]$h.handoff['status'] -ceq 'candidate_pass') -and (-not [bool]$h.handoff['truncated'])) 'handoff keeps task status and clean flag'
$v = Test-OrchestrationHandoffValid -Handoff $h.handoff
Assert-EVThat ([bool]$v.ok) 'good handoff revalidates'
# --- Raw payload is forbidden: rejected, never stored.
$a = New-EVRefArgs
$rawItem = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z'; raw_content = 'SECRET-BYTES' }
$rawH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @('f1') -EvidenceRefs @($rawItem) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ((-not [bool]$rawH.ok) -and ([string]$rawH.reason -ceq 'raw-payload-forbidden') -and ($null -eq $rawH.handoff)) 'raw_content evidence is rejected'
$rawItem2 = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z'; raw_payload = 'SECRET-BYTES' }
$rawH2 = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @('f1') -EvidenceRefs @($rawItem2) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ((-not [bool]$rawH2.ok) -and ([string]$rawH2.reason -ceq 'raw-payload-forbidden')) 'raw_payload evidence is rejected'
Assert-EVThat ([bool](Test-OrchestrationHandoffValid -Handoff $h.handoff).ok) 'validator accepts the built handoff record'
# --- Caps: 11 findings become 10, long texts truncate.
$many = @('k1', 'k2', 'k3', 'k4', 'k5', 'k6', 'k7', 'k8', 'k9', 'k10', 'k11')
$capped = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'blocked' -KeyFindings $many -EvidenceRefs @() -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ([bool]$capped.ok -and (@($capped.handoff['key_findings']).Count -eq 10)) 'eleven findings cap to ten'
Assert-EVThat ([bool]$capped.handoff['truncated']) 'capped handoff marks truncated'
Assert-EVThat ((@($capped.handoff['key_findings'])[-1] -ceq 'k10')) 'cap keeps the first ten in order'
$long = ('x' * 300)
$longH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @($long) -EvidenceRefs @() -Changes ('y' * 600) -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ([bool]$longH.ok -and ((@($longH.handoff['key_findings'])[0]).Length -eq 200)) 'finding truncates to 200 chars'
Assert-EVThat (([string]$longH.handoff['changes']).Length -eq 500) 'changes truncate to 500 chars'
Assert-EVThat ([bool](Test-OrchestrationHandoffValid -Handoff $longH.handoff).ok) 'truncated handoff still revalidates'
# --- Status outside the set and bad task id are invalid.
$badSt = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'done' -KeyFindings @() -EvidenceRefs @() -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ((-not [bool]$badSt.ok) -and ([string]$badSt.reason -ceq 'invalid-status')) 'status outside the set is invalid'
$badTask = New-OrchestrationCompactHandoff -TaskId 'no good!' -Status 'failed' -KeyFindings @() -EvidenceRefs @() -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ((-not [bool]$badTask.ok) -and ([string]$badTask.reason -ceq 'invalid-task-id')) 'malformed task id is invalid'
foreach ($s in @('candidate_pass', 'failed', 'blocked')) {
    $one = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status $s -KeyFindings @() -EvidenceRefs @() -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
    Assert-EVThat ([bool]$one.ok) "status $s builds"
}
# --- Strict types: non-string findings and text fail closed.
$badFind = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @(42) -EvidenceRefs @() -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ((-not [bool]$badFind.ok) -and ([string]$badFind.reason -ceq 'invalid-key-findings')) 'non-string finding fails closed'
$badText = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @() -EvidenceRefs @() -Changes @(1, 2) -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ((-not [bool]$badText.ok) -and ([string]$badText.reason -ceq 'invalid-changes')) 'non-string changes fail closed'
# --- Validator catches oversized and unknown records.
$forged = [ordered]@{ schema_version = 1; task_id = 'TASK-1'; status = 'failed'; key_findings = @('a','b','c','d','e','f','g','h','i','j','k'); evidence_refs = @(); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $true; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ((-not [bool](Test-OrchestrationHandoffValid -Handoff $forged).ok) -and ([string](Test-OrchestrationHandoffValid -Handoff $forged).reason -ceq 'too-many-findings')) 'validator rejects eleven findings'
Assert-EVThat (-not [bool](Test-OrchestrationHandoffValid -Handoff $null).ok) 'validator rejects null'
Assert-EVThat (-not [bool](Test-OrchestrationHandoffValid -Handoff 'junk').ok) 'validator rejects non-record'
# --- String evidence ids are accepted as refs.
$strH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'candidate_pass' -KeyFindings @() -EvidenceRefs @('ev.1', 'ev.2') -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ([bool]$strH.ok -and (@($strH.handoff['evidence_refs']).Count -eq 2)) 'string evidence ids accepted'
$badRef = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @() -EvidenceRefs @('has space!') -Changes '' -Validation '' -Blockers '' -Risks '' -Recommendation ''
Assert-EVThat ((-not [bool]$badRef.ok) -and ([string]$badRef.reason -ceq 'invalid-evidence-ref')) 'malformed evidence id rejected'
# --- Nested raw payload is forbidden in constructor and validator.
$nestedRaw = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z'; metadata = @{ raw_payload = 'X' } }
$nestedH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @('f1') -EvidenceRefs @($nestedRaw) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ((-not [bool]$nestedH.ok) -and ([string]$nestedH.reason -ceq 'raw-payload-forbidden')) 'nested raw_payload rejected in constructor'
$nestedRec = [ordered]@{ schema_version = 1; task_id = 'TASK-1'; status = 'failed'; key_findings = @(); evidence_refs = @($nestedRaw); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
$nestedV = Test-OrchestrationHandoffValid -Handoff $nestedRec
Assert-EVThat ((-not [bool]$nestedV.ok) -and ([string]$nestedV.reason -ceq 'raw-payload-forbidden')) 'nested raw_payload rejected in validator'
# --- Cycle is rejected fail-closed without hang.
$cycle = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z' }
$cycle['self'] = $cycle
$cycleH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @('f1') -EvidenceRefs @($cycle) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ((-not [bool]$cycleH.ok) -and ([string]$cycleH.reason -ceq 'inspection-incomplete')) 'cycle rejected in constructor'
$cycleRec = [ordered]@{ schema_version = 1; task_id = 'TASK-1'; status = 'failed'; key_findings = @(); evidence_refs = @($cycle); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
$cycleV = Test-OrchestrationHandoffValid -Handoff $cycleRec
Assert-EVThat ((-not [bool]$cycleV.ok) -and ([string]$cycleV.reason -ceq 'inspection-incomplete')) 'cycle rejected in validator'
# --- Four clean levels are accepted.
$l4 = @{ level = '4'; note = 'leaf' }
$l3 = @{ level = '3'; child = $l4 }
$l2 = @{ level = '2'; child = $l3 }
$l1 = @{ level = '1'; child = $l2 }
$deepOk = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z'; metadata = $l1 }
$deepH = New-OrchestrationCompactHandoff -TaskId 'TASK-1' -Status 'failed' -KeyFindings @('f1') -EvidenceRefs @($deepOk) -Changes 'c' -Validation 'v' -Blockers 'b' -Risks 'r' -Recommendation 'rec'
Assert-EVThat ([bool]$deepH.ok) 'four clean levels accepted in constructor'
Assert-EVThat ([bool](Test-OrchestrationHandoffValid -Handoff $deepH.handoff).ok) 'four clean levels accepted in validator'
# --- Strict types: array schema_version and numeric id fail closed, scalars stay valid.
$svArr = [ordered]@{ schema_version = @(1); evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ($null -eq (ConvertTo-EVEvidenceRef $svArr)) 'array schema_version fails closed'
$svArrH = [ordered]@{ schema_version = @(1); task_id = 'TASK-1'; status = 'failed'; key_findings = @(); evidence_refs = @(); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat (-not [bool](Test-OrchestrationHandoffValid -Handoff $svArrH).ok) 'array schema_version handoff fails closed'
$idNum = [ordered]@{ schema_version = 1; evidence_id = 42; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ($null -eq (ConvertTo-EVEvidenceRef $idNum)) 'numeric evidence id fails closed'
$taskNum = [ordered]@{ schema_version = 1; task_id = 42; status = 'failed'; key_findings = @(); evidence_refs = @(); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ((-not [bool](Test-OrchestrationHandoffValid -Handoff $taskNum).ok) -and ([string](Test-OrchestrationHandoffValid -Handoff $taskNum).reason -ceq 'invalid-task-id')) 'numeric task id fails closed'
$legitArgs = New-EVRefArgs
$legit = New-OrchestrationEvidenceRef @legitArgs
Assert-EVThat ([bool]$legit.ok) 'legit scalars stay valid'
# --- Strict types: array verification_state and status fail closed, strings stay valid.
$vsArr = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = @('verified'); provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ($null -eq (ConvertTo-EVEvidenceRef $vsArr)) 'array verification_state fails closed'
$stArrH = [ordered]@{ schema_version = 1; task_id = 'TASK-1'; status = @('failed'); key_findings = @(); evidence_refs = @(); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ((-not [bool](Test-OrchestrationHandoffValid -Handoff $stArrH).ok) -and ([string](Test-OrchestrationHandoffValid -Handoff $stArrH).reason -ceq 'invalid-status')) 'array status fails closed'
$vsStr = [ordered]@{ schema_version = 1; evidence_id = 'ev.1'; goal_id = 'g1'; task_id = 't1'; run_id = 'r1'; producer = 'coder'; artifact_ref = 'a1'; hash = 'abcdef0123456789'; verification_state = 'verified'; provenance = 'p1'; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ($null -ne (ConvertTo-EVEvidenceRef $vsStr)) 'string verification_state stays valid'
$stStrH = [ordered]@{ schema_version = 1; task_id = 'TASK-1'; status = 'failed'; key_findings = @(); evidence_refs = @(); changes = ''; validation = ''; blockers = ''; risks = ''; recommendation = ''; truncated = $false; created_at = '2026-10-07T00:00:00.0000000Z' }
Assert-EVThat ([bool](Test-OrchestrationHandoffValid -Handoff $stStrH).ok) 'string status stays valid'
Write-Output "PASS OrchestrationEvidenceRef: $passed assertions"
