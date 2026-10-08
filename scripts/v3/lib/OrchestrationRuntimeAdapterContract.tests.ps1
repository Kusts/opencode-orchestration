$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1')
$script:passed=0
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
function AssertThrows([scriptblock]$Block,[string]$Name){$threw=$false;try{[void](& $Block)}catch{$threw=$true};if(-not $threw){throw "FAIL (no throw): $Name"};$script:passed++}

$ops=Get-OrchestrationRuntimeAdapterOperations
Assert ($ops.Count -eq 10) 'ten operations declared'
foreach($expected in @('detectCapabilities','identifySession','getSessionState','dispatchWorker','observeWorkerResult','waitForSettlement','requestPlannerContinuation','restoreContext','cancelAuthorizedExecution','recordRuntimeEvidence')){Assert ($ops -contains $expected) ("op present $expected")}

$specifiable=@('detectCapabilities','identifySession','observeWorkerResult','restoreContext','recordRuntimeEvidence')
$holdOps=@('getSessionState','dispatchWorker','waitForSettlement','requestPlannerContinuation','cancelAuthorizedExecution')
foreach($rt in @('V1','V2')){
  $matrix=@(Get-OrchestrationRuntimeAdapterMatrix -Runtime $rt)
  Assert ($matrix.Count -eq 10) ("matrix 10 rows $rt")
  foreach($row in $matrix){
    Assert ($row.verified -eq $false) ("never VERIFIED $($row.operation) $rt")
    Assert ($row.status -cne 'VERIFIED') ("no VERIFIED status $($row.operation) $rt")
    if($specifiable -contains $row.operation){Assert ($row.status -ceq 'SUPPORTED') ("SPECIFIABLE SUPPORTED $($row.operation) $rt")}
    else{Assert ($row.status -ceq 'HOLD') ("HOLD op $($row.operation) $rt")}
  }
}
$all=@(Get-OrchestrationRuntimeAdapterMatrix)
Assert ($all.Count -eq 20) 'matrix both runtimes 20 rows'
AssertThrows {Get-OrchestrationRuntimeAdapterMatrix -Runtime 'V9'} 'unknown runtime throws'

foreach($h in $holdOps){
  $spec=Get-OrchestrationAdapterOperationSpec -Operation $h
  Assert (($spec.v1 -ceq 'HOLD') -and ($spec.v2 -ceq 'HOLD')) ("spec HOLD $h")
  $r=New-OrchestrationAdapterHoldResult -Operation $h -Runtime 'V1'
  Assert (($r.status -ceq 'unavailable' -or $r.status -ceq 'blocked') -and $r.fallback_continue -and -not $r.grants_authority -and -not $r.done_approved -and -not $r.verified_pass) ("hold typed fallback $h")
}
$blocked=New-OrchestrationAdapterHoldResult -Operation 'cancelAuthorizedExecution' -Runtime 'V2' -Cause 'cancel-deny-not-proven'
Assert ($blocked.status -ceq 'blocked') 'cancel hold blocked'
$enf=New-OrchestrationAdapterHoldResult -Operation 'dispatchWorker' -Runtime 'V2' -Cause 'runtime-grant-enforcement-hold'
Assert ($enf.status -ceq 'blocked') 'enforcement hold blocked'
AssertThrows {New-OrchestrationAdapterHoldResult -Operation 'detectCapabilities' -Runtime 'V1'} 'hold rejected for SPECIFIABLE op'
AssertThrows {New-OrchestrationAdapterHoldResult -Operation 'dispatchWorker' -Runtime 'V1' -Cause 'invented-cause'} 'out-of-allowlist cause throws'
AssertThrows {Get-OrchestrationAdapterOperationSpec -Operation 'nope'} 'unknown op spec throws'

$denied=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $denied.admitted) -and ($denied.reason -match 'POLICY-BLOCKED') -and -not $denied.grants_authority -and -not $denied.done_approved) 'auth envelope denies on missing grants'
$opt=New-OrchestrationAdapterAuthEnvelope -User 'u' -Runtime 'V1' -Optional $true
Assert ((-not $opt.admitted) -and $opt.fallback_continue) 'optional missing admits fallback'
$full=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'g allow:dispatch' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ($full.admitted -and $full.explicit_allow -and -not [string]::IsNullOrWhiteSpace([string]$full.grant_ref) -and -not $full.grants_authority -and -not $full.done_approved) 'full envelope admits with verifiable grant ref and no authority'
$noAllow=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'g' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $noAllow.admitted) -and ($noAllow.reason -ceq 'POLICY-BLOCKED:operation-not-authorized')) 'capability tokens without explicit allow deny'
$selfGrant=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'g' -Operation 'dispatch' -Resource 'w-1' -Decision 'allow'
Assert ((-not $selfGrant.admitted) -and ($selfGrant.reason -ceq 'POLICY-BLOCKED:self-grant-rejected')) 'caller Decision=allow is never a self-grant'
$badOp=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch' -Operation 'invented' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $badOp.admitted) -and ($badOp.reason -ceq 'POLICY-BLOCKED:operation-not-allowed')) 'unknown operation denies fail-closed'
$noOp=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch'
Assert ((-not $noOp.admitted) -and ($noOp.reason -ceq 'POLICY-BLOCKED:operation-not-allowed')) 'absent operation denies fail-closed'
$scoped=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:reconcile:ra-wa' -Operation 'reconcile' -Resource 'ra-wa' -Decision 'reconcile'
Assert ($scoped.admitted) 'resource-scoped allow admits its own resource'
$scopedOther=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:reconcile:ra-wa' -Operation 'reconcile' -Resource 'ra-wb' -Decision 'reconcile'
Assert (-not $scopedOther.admitted) 'resource-scoped allow denies other resources'
$denyWithAllow=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch, deny' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $denyWithAllow.admitted) -and ($denyWithAllow.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'deny wins over explicit allow'
$scopedDeny=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch:w1;deny:dispatch:w1' -Operation 'dispatch' -Resource 'w1' -Decision 'dispatch'
Assert ((-not $scopedDeny.admitted) -and ($scopedDeny.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'F7 scoped deny prevails over allow in any order'
$scopedDenyRev=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'deny:dispatch:w1;allow:dispatch:w1' -Operation 'dispatch' -Resource 'w1' -Decision 'dispatch'
Assert ((-not $scopedDenyRev.admitted) -and ($scopedDenyRev.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'F7 scoped deny first also denies'
$decisionDeny=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch' -Operation 'dispatch' -Resource 'w-1' -Decision 'deny'
Assert ((-not $decisionDeny.admitted) -and ($decisionDeny.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'F7 negative Decision vetoes an allow'
$malformedAllow=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch allow:dispatch:' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $malformedAllow.admitted) -and ($malformedAllow.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'F7 malformed grant token denies'
$unknownColon=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'allow:dispatch foo:bar' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ((-not $unknownColon.admitted) -and ($unknownColon.reason -ceq 'POLICY-BLOCKED:grants-deny')) 'F7 unknown colon token denies'
$bareLabels=New-OrchestrationAdapterAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops g fs.read allow:dispatch' -Operation 'dispatch' -Resource 'w-1' -Decision 'dispatch'
Assert ($bareLabels.admitted) 'F7 bare capability labels stay ignored'
$authOps=Get-OrchestrationAdapterAuthOperations
Assert (($authOps.Count -eq 6) -and ($authOps -contains 'dispatch') -and ($authOps -contains 'reconcile') -and ($authOps -contains 'settlement') -and ($authOps -contains 'checkpoint') -and ($authOps -contains 'advance') -and ($authOps -contains 'terminalize')) 'closed six-decision auth set'

$probeV1="opencode version 1.18.34 windows"
$probeV2="@opencode/cli 2.0.23 (windows)"
$d1=Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput $probeV1 -Runtime 'V1'
Assert ($d1.ok -and $d1.probe_matched -and ($d1.major -eq 1) -and -not $d1.grants_authority -and -not $d1.done_approved) 'detect V1 matched'
Assert ($d1.pin_spec -notmatch 'literal') 'pin spec present'
$d2=Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput $probeV2 -Runtime 'V2'
Assert ($d2.ok -and ($d2.major -eq 2)) 'detect V2 matched'
$mm=Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput $probeV2 -Runtime 'V1'
Assert ((-not $mm.ok) -and $mm.fallback_continue) 'major mismatch falls back'
$empty=Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput '' -Runtime 'V1'
Assert ((-not $empty.ok) -and ($empty.cause -ceq 'probe-output-missing')) 'empty probe unavailable'
$garbage=Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput 'no version here' -Runtime 'V1'
Assert ((-not $garbage.ok) -and ($garbage.cause -ceq 'probe-output-unrecognized')) 'garbage probe unavailable'

$tmpRoot=Join-Path ([IO.Path]::GetTempPath()) ('adapter-contract-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tmpRoot)
try{
  AssertThrows {Get-OrchestrationAdapterRuntimePins -RepoRoot $tmpRoot} 'fail-closed without registry'
  AssertThrows {Invoke-OrchestrationAdapterDetectCapabilities -ProbeOutput $probeV1 -Runtime 'V1' -RepoRoot $tmpRoot} 'detect fail-closed without registry'
  $sinkMissing=Test-OrchestrationAdapterEvidenceSink -StoreDir (Join-Path $tmpRoot 'no-such-dir')
  Assert ((-not $sinkMissing.writable) -and ($sinkMissing.reason -ceq 'write-unavailable')) 'sink write-unavailable'
  $sinkOk=Test-OrchestrationAdapterEvidenceSink -StoreDir $tmpRoot
  Assert ($sinkOk.writable -and -not $sinkOk.grants_authority) 'sink writable no authority'
}finally{try{Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{}}

$idMap=New-OrchestrationAdapterSessionIdentity -SessionMapId 'sess-1'
Assert (($idMap.identity_source -ceq 'session-map') -and $idMap.resolved) 'identity session-map first'
$idProbe=New-OrchestrationAdapterSessionIdentity -ProbeObservation 'obs-1'
Assert (($idProbe.identity_source -ceq 'input-probe') -and $idProbe.resolved) 'identity input-probe second'
$idNeutral=New-OrchestrationAdapterSessionIdentity
Assert (($idNeutral.identity_source -ceq 'neutral') -and -not $idNeutral.resolved) 'identity neutral fallback'
Assert ((-not $idNeutral.grants_authority) -and (-not $idNeutral.done_approved)) 'identity no authority'

$planBad=New-OrchestrationAdapterRestorePlan -ContinuationEnvelope ([pscustomobject]@{}) -Runtime 'V1'
Assert ((-not $planBad.ok) -and ($planBad.cause -ceq 'envelope-without-task-id')) 'restore needs task id'
$plan=New-OrchestrationAdapterRestorePlan -ContinuationEnvelope ([pscustomobject]@{task_id='t-1'}) -Runtime 'V2'
Assert ($plan.ok -and ($plan.mode -ceq 'kernel-side-context') -and ($plan.snapshots -ceq 'auxiliary-only') -and -not $plan.overrides_git -and -not $plan.overrides_worktree) 'restore kernel-side auxiliary'
AssertThrows {New-OrchestrationAdapterRestorePlan -ContinuationEnvelope ([pscustomobject]@{task_id='t'}) -Runtime 'V9'} 'restore unknown runtime throws'

$obs=New-OrchestrationAdapterWorkerObservation -TaskId 't' -RunId 'r' -SessionId 's' -Observed 'completed' -OutputRef 'out-1'
Assert ($obs.ok -and -not $obs.verified -and ($obs.verification -ceq 'kernel-allowlisted-only') -and -not $obs.verified_pass -and -not $obs.done_approved) 'observation never verified here'
$obsBad=New-OrchestrationAdapterWorkerObservation -TaskId '' -RunId 'r' -SessionId 's'
Assert ((-not $obsBad.ok) -and ($obsBad.cause -ceq 'missing-task_id')) 'observation missing id unavailable'

$row=New-OrchestrationAdapterEvidenceRow -TaskId 't' -RunId 'r' -WorkerId 'w' -Summary 'did work'
Assert ($row.ok -and ($row.sink -ceq 'jsonl') -and -not $row.grants_authority) 'evidence row no authority'
$rowBad=New-OrchestrationAdapterEvidenceRow -TaskId 'bad id!' -RunId 'r' -WorkerId 'w'
Assert ((-not $rowBad.ok) -and ($rowBad.cause -ceq 'invalid-task_id')) 'evidence row validates ids'

$cred=Get-OrchestrationAdapterCredentialName -Name 'OPENCODE_API_KEY'
Assert ($cred.is_name_only -and -not $cred.value_read) 'credential name only'
AssertThrows {Get-OrchestrationAdapterCredentialName -Name 'not a name!'} 'credential bad name throws'

$wd=Get-OrchestrationAdapterWatchdogReference
Assert ((-not $wd.drives_watchdog) -and ($wd.mode -ceq 'referenced-not-driven')) 'watchdog referenced not driven'

$libPath=Join-Path $PSScriptRoot 'OrchestrationRuntimeAdapterContract.ps1'
$libText=[IO.File]::ReadAllText($libPath,[Text.Encoding]::UTF8)
Assert ($libText -notmatch 'Start-Process|System\.Diagnostics\.Process|taskkill|Stop-Process|\.Kill\(\)') 'no spawn or kill in lib'
Assert ($libText -notmatch 'Invoke-RestMethod|Invoke-WebRequest|System\.Net\.Http|TcpClient|HttpClient') 'no network in lib'
Assert ($libText -notmatch '\$env:') 'no env value reads in lib'
Assert ($libText -notmatch '1\.18\.34|2\.0\.23') 'no version literals in lib'
Assert ($libText -notmatch "=\s*'VERIFIED'") 'no VERIFIED status assigned in lib'
Assert ($libText -notmatch 'verification-policy') 'verification policy never used as authorizer'
Assert ($libText -notmatch 'Set-Content|Out-File|Add-Content|WriteAllText|New-Item') 'lib never writes files'
foreach($h in $holdOps){$spec=Get-OrchestrationAdapterOperationSpec -Operation $h;Assert ((-not $spec.grants_authority) -and (-not $spec.done_approved)) ("spec no authority $h")}
foreach($s in $specifiable){$spec=Get-OrchestrationAdapterOperationSpec -Operation $s;Assert (($spec.v1 -ceq 'SUPPORTED') -and ($spec.v2 -ceq 'SUPPORTED')) ("spec SUPPORTED $s")}
Write-Output "PASS: $script:passed assertions"
