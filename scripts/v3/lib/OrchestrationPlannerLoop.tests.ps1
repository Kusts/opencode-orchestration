[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationPlannerLoop.ps1')
$script:checks=0
function Assert-PL([bool]$ok,[string]$name){$script:checks++;if(-not $ok){throw "FAIL: $name"}}
# P38-S2 hermetic seam: the loop is now a real Jev caller, so the
# operator-owned JEV_* environment is captured and cleared BEFORE any loop
# call; otherwise a configured operator environment would let a triggered
# descriptor reach a real endpoint from the suite. The outer try below opens
# BEFORE that first mutation, so its finally always covers the restore.
$script:PLSavedEnv=@{}
$now='2026-10-02T12:00:00Z'
try {
foreach($n in @('JEV_API_KEY','JEV_BASE_URL','JEV_MODEL')){$script:PLSavedEnv[$n]=[System.Environment]::GetEnvironmentVariable($n);[System.Environment]::SetEnvironmentVariable($n,$null)}
# 1. Small change takes minimum C/L1 route.
$small=Invoke-OrchestrationPlannerLoop @{objective='Localized typo fix';summary='Localized';risk='low';localized=$true;single_worker=$false;task_shape='small_localized';validation_budget_available=$true} @{timestamp=$now}
Assert-PL ($small.status -eq 'ok' -and $small.plan.validation.level -eq 'L1' -and $small.plan.execution_mode.mode -eq 'C' -and @($small.plan.dispatch_plan.workers).Count -eq 1) 'small-minimum-route'
# 2. Ambiguous/high risk raises rigor.
$risky=Invoke-OrchestrationPlannerLoop @{objective='Investigate credentials failure';summary='Ambiguous credentials';risk='high';risk_triggers=@('credentials');uncertainty='high';task_shape='multi_step'} @{timestamp=$now}
Assert-PL ($risky.plan.validation.level -eq 'L3' -and $risky.plan.execution_mode.mode -eq 'C' -and $risky.plan.dispatch_plan.workers -contains 'security-reviewer') 'risky-rigor'
# 3. No validation budget suppresses fan-out.
$nobudget=Invoke-OrchestrationPlannerLoop @{objective='Complex work';risk='high';validation_budget_available=$false} @{timestamp=$now}
Assert-PL (@($nobudget.plan.dispatch_plan.workers).Count -eq 1 -and -not $nobudget.plan.dispatch_plan.parallel_ok -and -not $nobudget.plan.budget_reservation.validation_reserved) 'budget-constrains-fanout'
# 4. Jev trigger remains recommendation only.
$jev=Invoke-OrchestrationPlannerLoop @{objective='Need route';risk='low';route_uncertain=$true} @{timestamp=$now}
Assert-PL ($jev.plan.jev_triggers.should_consult -and -not $jev.plan.jev_advisory.authoritative -and $jev.plan.jev_advisory.recommendation_only) 'jev-non-authoritative'
# 5. Missing info recommends research, not model escalation.
$unknown=Invoke-OrchestrationPlannerLoop @{} @{timestamp=$now}
Assert-PL ($unknown.plan.dispatch_plan.recommendation -eq 'Explorer/Researcher' -and $unknown.plan.dispatch_plan.escalations[0].type -eq 'information-gathering') 'research-before-escalation'
# 6. Parallelism requires every gate; independent path vs dependent path.
$independent=Invoke-OrchestrationPlannerLoop @{objective='Independent modules';risk='medium';work_independent=$true;ownership_clear=$true;shared_state=$false;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
$dependent=Invoke-OrchestrationPlannerLoop @{objective='Sequential migration';risk='medium';work_independent=$true;ownership_clear=$true;shared_state=$true;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
Assert-PL ($independent.plan.dispatch_plan.parallel_ok -and -not $dependent.plan.dispatch_plan.parallel_ok) 'parallel-gates'
# 7. Stop condition always present.
Assert-PL (-not [string]::IsNullOrWhiteSpace($unknown.plan.stop_condition)) 'stop-condition'
# hostile input, sanitization and conservative fallback.
$hostile=Invoke-OrchestrationPlannerLoop ([pscustomobject]@{objective='sk-SYNTHETICSECRET token=hello evil.com';risk='injected';task_shape=@('malformed')}) @{timestamp=$now}
Assert-PL ($hostile.plan.execution_mode.mode -eq 'C' -and $hostile.plan.validation.level -eq 'L2' -and $hostile.plan.frame.objective -notmatch 'SYNTHETICSECRET|hello|evil.com') 'hostile-conservative-sanitized'
# stable inputs and value timestamp produce byte-identical serialization.
$again=Invoke-OrchestrationPlannerLoop @{} @{timestamp=$now}
Assert-PL ($unknown.plan_json -ceq $again.plan_json) 'deterministic'
Assert-PL ($hostile.bounded -and $hostile.byte_length -le 8192) 'bounded-record'
# Isolated malformed stage returns fail closed at that section without losing plan.
foreach($stage in @('reuse','simplicity','validation','execution_mode','jev')){
    $bad=Invoke-OrchestrationPlannerLoop @{objective='Stage seam';risk='low'} @{timestamp=$now;stage_results=@{$stage='malformed'}}
    $section=if($stage -eq 'reuse'){$bad.plan.reuse}elseif($stage -eq 'simplicity'){$bad.plan.simplicity.contract}elseif($stage -eq 'validation'){$bad.plan.validation}elseif($stage -eq 'execution_mode'){$bad.plan.execution_mode}else{$bad.plan.jev_triggers}
    Assert-PL ($bad.status -eq 'ok' -and $section.status -eq 'unavailable') "malformed-$stage-unavailable"
}
# Kernel API is intentionally not loaded: reservation stays record-only.
$recordOnly=Invoke-OrchestrationPlannerLoop @{objective='No kernel';risk='low'} @{timestamp=$now}
Assert-PL ($recordOnly.plan.budget_reservation.status -eq 'record-only') 'kernel-absent-record-only'
# Injected strings in reusable evidence, roles, mode and timestamp are sanitized.
$injected=Invoke-OrchestrationPlannerLoop @{objective='Sanitization';risk='low'} @{timestamp='invalid sk-SYNTHETICSECRET token=bad';stage_results=@{reuse=[pscustomobject]@{status='ok';results=@([pscustomobject]@{summary='sk-SYNTHETICSECRET token=bad'})};validation=[pscustomobject]@{status='ok';required_roles=@('sk-SYNTHETICSECRET token=bad');level='L1'};execution_mode=[pscustomobject]@{mode='C';rationale='sk-SYNTHETICSECRET token=bad'}}}
Assert-PL ((($injected.plan_json -notmatch 'SYNTHETICSECRET|token=bad') -and $injected.plan.timestamp_note -match 'Invalid timestamp') -and $injected.plan.execution_mode.rationale -notmatch 'SYNTHETICSECRET') 'all-injected-sources-sanitized'
# Oversized free text exercises ordered discards and absolute byte cap.
$large=Invoke-OrchestrationPlannerLoop @{objective=('x' * 200000);risk='low';separation_rationale=('y' * 200000)} @{timestamp=$now;stage_results=@{reuse=[pscustomobject]@{status='ok';results=@(('z' * 200000))}}}
Assert-PL ($large.bounded -and $large.byte_length -le 8192 -and $large.discard_order.Count -ge 6) 'absolute-cap-discard-order'
# Extreme nested payload must fall back to a valid compact envelope, consistently represented.
$hugeResults=@();for($i=0;$i -lt 20;$i++){$row=[ordered]@{};for($j=0;$j -lt 40;$j++){$row["field$j"]=('z' * 240)};$hugeResults+=,[pscustomobject]$row}
$hugeCompletion=[ordered]@{};for($i=0;$i -lt 40;$i++){$hugeCompletion["field$i"]=('z' * 240)}
$extreme=Invoke-OrchestrationPlannerLoop @{objective='Extreme payload';risk='low';task_ref='task-123'} @{timestamp='invalid sk-SYNTHETICSECRET';stage_results=@{reuse=[pscustomobject]@{status='ok';results=$hugeResults};complete_requirements=[pscustomobject]$hugeCompletion}}
$parsedExtreme=$extreme.plan_json | ConvertFrom-Json -ErrorAction Stop
$sameRecord=(ConvertTo-Json -InputObject $extreme.plan -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $parsedExtreme -Depth 8 -Compress)
Assert-PL ($extreme.bounded -and $extreme.byte_length -le 8192 -and $parsedExtreme.status -eq 'oversized' -and $parsedExtreme.truncated -and $parsedExtreme.oversized -and $sameRecord) 'oversized-valid-envelope-and-consistency'
Assert-PL ($extreme.plan_json -notmatch 'SYNTHETICSECRET' -and $extreme.plan_json -match '"generated_at"') 'oversized-invalid-timestamp-canary-absent'
# Invalid descriptor forces the whole plan to conservative mode and minimum dispatch.
$invalid=Invoke-OrchestrationPlannerLoop ([pscustomobject]@{objective=@('hostile');risk='critical';task_shape=@('B')}) @{timestamp=$now}
Assert-PL ($invalid.plan.execution_mode.mode -eq 'C' -and $invalid.plan.validation.level -eq 'L2' -and @($invalid.plan.dispatch_plan.workers).Count -eq 1 -and -not $invalid.plan.dispatch_plan.parallel_ok) 'invalid-descriptor-whole-plan-fallback'
# ---------- P38-S2: Jev advisory caller wiring ----------
# Hermetic: synthetic canary credential only for the probe seam, never a
# base URL, temp telemetry root, and probes are synthetic scriptblocks that
# cannot touch the network. The lib owns every gate, the circuit and the
# sanitized evidence; the loop only records the typed envelope.
function Get-PLHitCount([string]$Path){if(-not (Test-Path -LiteralPath $Path)){return 0};return ([regex]::Matches([IO.File]::ReadAllText($Path),'hit;')).Count}
$plTemp=Join-Path ([IO.Path]::GetTempPath()) ('v3-pl-jev-'+[guid]::NewGuid().ToString('N'))
$plTele=Join-Path $plTemp 'evidence'
New-Item -ItemType Directory -Path $plTele -Force | Out-Null
$plOpt=@{timestamp=$now;jev_advisory_telemetry_root=$plTele}
$okOut="[pscustomobject]@{model='jev-latest';answers=[pscustomobject]@{route=[pscustomobject]@{type='choice';choice='minimal';confidence=0.8}};usage=[pscustomobject]@{input_tokens=1;output_tokens=1}}"
try{
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY','sk-SYNTHETICSECRET-PLANNER-CANARY')
    # T1: trigger fires, canonical flag node exists, probe OK => consulted once.
    $t1Marker=Join-Path $plTemp 'probe-t1.txt'
    $t1Probe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');{1}" -f $t1Marker,$okOut))
    $t1=Invoke-OrchestrationPlannerLoop @{objective='Wire the Jev advisory caller';risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $t1Probe
    Assert-PL ($t1.status -eq 'ok' -and (Get-PLHitCount $t1Marker) -eq 1 -and [bool]$t1.plan.jev_advisory_result.consulted -and [string]$t1.plan.jev_advisory_result.status -ceq 'JEV_ADVISORY_OK' -and -not [bool]$t1.plan.jev_advisory_result.blocked -and -not [bool]$t1.plan.jev_advisory_result.authoritative -and [bool]$t1.plan.jev_advisory_result.recommendation_only -and ([string]$t1.plan.jev_advisory_result.recommendation -like 'decide answers=*') -and @($t1.plan.dispatch_plan.workers).Count -ge 1) 'jev-wiring-t1-consulted-exactly-once'
    # T2: trivial_local never consults: zero probe, record identical to a run
    # without the probe seam, trigger reason unchanged.
    $t2Marker=Join-Path $plTemp 'probe-t2.txt'
    $t2Probe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');{1}" -f $t2Marker,$okOut))
    $t2Desc=@{objective='Trivial local typo';risk='low';trivial_local=$true;route_uncertain=$true}
    $t2=Invoke-OrchestrationPlannerLoop $t2Desc $plOpt -JevAdvisoryProbe $t2Probe
    $t2NoProbe=Invoke-OrchestrationPlannerLoop $t2Desc $plOpt
    Assert-PL (((Get-PLHitCount $t2Marker) -eq 0) -and ([string]$t2.plan.jev_triggers.reason -ceq 'trivial-local-never-consults') -and (-not [bool]$t2.plan.jev_triggers.should_consult) -and ([string]$t2.plan.jev_advisory_result.status -ceq 'unavailable') -and ([string]$t2.plan.jev_advisory_result.reason -ceq 'jev-advisory-not-triggered') -and (-not [bool]$t2.plan.jev_advisory_result.consulted) -and ([string]$t2.plan_json -ceq [string]$t2NoProbe.plan_json)) 'jev-wiring-t2-trivial-zero-call'
    # T3: transport failure is a structured unavailability and planning continues.
    $t3=Invoke-OrchestrationPlannerLoop @{objective='Advisory unavailable path';risk='low';consequential_tool_call=$true} $plOpt -JevAdvisoryProbe ([scriptblock]::Create("param(`$tool,`$state,`$toolArgs,`$budget);throw 'MCP_SIM_TIMEOUT boom'"))
    Assert-PL ($t3.status -eq 'ok' -and ([string]$t3.plan.jev_advisory_result.status -ceq 'JEV_UNAVAILABLE') -and [bool]$t3.plan.jev_advisory_result.fallback_continue -and -not [bool]$t3.plan.jev_advisory_result.blocked -and -not [bool]$t3.plan.jev_advisory_result.authoritative -and ([string]$t3.plan.jev_advisory_result.recommendation -eq 'no-advisory-recommendation') -and @($t3.plan.dispatch_plan.workers).Count -ge 1) 'jev-wiring-t3-unavailable-planning-continues'
    # T4: a contrary advisory recommendation never changes the plan decision.
    $t4Marker=Join-Path $plTemp 'probe-t4.txt'
    $contraOut="[pscustomobject]@{model='jev-latest';answers=[pscustomobject]@{route=[pscustomobject]@{type='choice';choice='parallel';confidence=0.95}};usage=[pscustomobject]@{input_tokens=2;output_tokens=2}}"
    $t4Probe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');{1}" -f $t4Marker,$contraOut))
    $t4Desc=@{objective='Compare routes under model uncertainty';risk='low';model_route_uncertain=$true;work_independent=$true;ownership_clear=$true;shared_state=$true;latency_benefit=$true;synthesis_affordable=$true}
    $t4With=Invoke-OrchestrationPlannerLoop $t4Desc $plOpt -JevAdvisoryProbe $t4Probe
    $t4Without=Invoke-OrchestrationPlannerLoop $t4Desc $plOpt
    $t4A=$t4With.plan.PSObject.Copy();$t4A.PSObject.Properties.Remove('jev_advisory_result')
    $t4B=$t4Without.plan.PSObject.Copy();$t4B.PSObject.Properties.Remove('jev_advisory_result')
    $t4Same=(ConvertTo-Json -InputObject $t4A -Depth 16 -Compress) -ceq (ConvertTo-Json -InputObject $t4B -Depth 16 -Compress)
    Assert-PL ($t4Same -and (Get-PLHitCount $t4Marker) -eq 1 -and -not [bool]$t4With.plan.dispatch_plan.parallel_ok -and ([string]$t4With.plan.jev_advisory_result.answers.route.choice -ceq 'parallel') -and -not [bool]$t4With.plan.jev_advisory_result.authoritative -and [bool]$t4With.plan.jev_advisory_result.recommendation_only) 'jev-wiring-t4-contrary-advice-never-changes-plan'
    # T4 (mirror): every fan-out gate proven (deterministic parallel_ok=true)
    # with an advisory recommending the minimum route: the loop still fans out.
    $t4cMarker=Join-Path $plTemp 'probe-t4c.txt'
    $t4cProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');{1}" -f $t4cMarker,$okOut))
    $t4cDesc=@{objective='Compare routes under route uncertainty';risk='low';route_uncertain=$true;work_independent=$true;ownership_clear=$true;shared_state=$false;latency_benefit=$true;synthesis_affordable=$true}
    $t4cWith=Invoke-OrchestrationPlannerLoop $t4cDesc $plOpt -JevAdvisoryProbe $t4cProbe
    $t4cWithout=Invoke-OrchestrationPlannerLoop $t4cDesc $plOpt
    $t4cA=$t4cWith.plan.PSObject.Copy();$t4cA.PSObject.Properties.Remove('jev_advisory_result')
    $t4cB=$t4cWithout.plan.PSObject.Copy();$t4cB.PSObject.Properties.Remove('jev_advisory_result')
    $t4cSame=(ConvertTo-Json -InputObject $t4cA -Depth 16 -Compress) -ceq (ConvertTo-Json -InputObject $t4cB -Depth 16 -Compress)
    Assert-PL ($t4cSame -and (Get-PLHitCount $t4cMarker) -eq 1 -and [bool]$t4cWith.plan.dispatch_plan.parallel_ok -and [bool]$t4cWithout.plan.dispatch_plan.parallel_ok -and ([string]$t4cWith.plan.jev_advisory_result.answers.route.choice -ceq 'minimal') -and -not [bool]$t4cWith.plan.jev_advisory_result.authoritative) 'jev-wiring-t4c-minimum-advice-never-collapses-fanout'
    # T5: the budget override reaches the probe seam and the envelope budget.
    $t5Hit=Join-Path $plTemp 'probe-t5.txt'
    $t5Budget=Join-Path $plTemp 'budget-t5.txt'
    $t5Probe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::AppendAllText('{0}','hit;');[IO.File]::AppendAllText('{1}',([string]`$budget));{2}" -f $t5Hit,$t5Budget,$okOut))
    $t5=Invoke-OrchestrationPlannerLoop @{objective='Budget override passthrough';risk='low';conflicting_evidence=$true} $plOpt -JevAdvisoryProbe $t5Probe -JevAdvisoryBudgetSecondsOverride 5
    $t5Seen='(none)'
    if(Test-Path -LiteralPath $t5Budget){$t5Seen=([IO.File]::ReadAllText($t5Budget)).Trim()}
    Assert-PL (([string]$t5Seen -ceq '5') -and ([int]$t5.plan.jev_advisory_result.budget_s -eq 5) -and ([string]$t5.plan.jev_advisory_result.status -ceq 'JEV_ADVISORY_OK') -and (Get-PLHitCount $t5Hit) -eq 1) 'jev-wiring-t5-budget-override-passthrough'
    # T6: no credential, endpoint or header ever crosses into the record.
    $t6Json=([string]$t1.plan_json)+([string]$t3.plan_json)+([string]$t4With.plan_json)
    Assert-PL (($t6Json -notmatch 'JEV_API_KEY') -and ($t6Json -notmatch 'SYNTHETICSECRET') -and ($t6Json -notmatch '(?i)authorization') -and ($t6Json -notmatch '(?i)bearer ') -and ($t6Json -notmatch '(?i)https?://')) 'jev-wiring-t6-record-has-no-credential-or-endpoint'
    # T7: production path, no probe and no credential: fail-closed before any
    # transport resolution, planning completes.
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY',$null)
    $t7=Invoke-OrchestrationPlannerLoop @{objective='Production path without credential';risk='low';recovery_comparison_bounded=$true} $plOpt
    $t7Text=''
    foreach($f in @(Get-ChildItem -LiteralPath $plTele -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)){try{$t7Text+=[IO.File]::ReadAllText($f.FullName)}catch{}}
    Assert-PL ($t7.status -eq 'ok' -and ([string]$t7.plan.jev_advisory_result.status -ceq 'JEV_UNAVAILABLE') -and (-not [bool]$t7.plan.jev_advisory_result.consulted) -and [bool]$t7.plan.jev_advisory_result.fallback_continue -and -not [bool]$t7.plan.jev_advisory_result.authoritative -and ($t7Text -match 'credential-absent-deterministic-fallback') -and @($t7.plan.dispatch_plan.workers).Count -ge 1) 'jev-wiring-t7-no-credential-fail-closed-no-network'
    # NT1: adversarial egress. The probe is the transport seam and receives the
    # exact -State the loop projects, so it can capture what would leave the
    # loop. Canary set: sk- key, an Authorization: Bearer credential, a path
    # under the REAL process home, and another profile with a space in the
    # name. None of them may appear in the State; the redaction markers must.
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY','sk-SYNTHETICSECRET-PLANNER-CANARY')
    $nt1StatePath=Join-Path $plTemp 'probe-nt1-state.txt'
    $nt1Probe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt1StatePath,$okOut))
    $nt1Home=''
    try{$nt1Home=([string]$env:USERPROFILE).Trim().TrimEnd([char[]]@([char]'\',[char]'/'))}catch{}
    if([string]::IsNullOrWhiteSpace($nt1Home)){$nt1Home='C:\synthetic-user-home-canary'}
    $nt1Desc=@{objective=('secret sk-SYNTHETICSECRET and Authorization: Bearer SYNTHETIC_BEARER_CANARY at '+$nt1Home+'\private.txt and C:\Users\Jane Doe\private.txt');risk='low';route_uncertain=$true}
    $nt1=Invoke-OrchestrationPlannerLoop $nt1Desc $plOpt -JevAdvisoryProbe $nt1Probe
    $nt1State='';if(Test-Path -LiteralPath $nt1StatePath){$nt1State=[IO.File]::ReadAllText($nt1StatePath)}
    Assert-PL (($nt1.status -eq 'ok') -and ([bool]$nt1.plan.jev_advisory_result.consulted) -and (-not [string]::IsNullOrWhiteSpace($nt1State)) -and ($nt1State -notmatch 'sk-SYNTHETICSECRET') -and ($nt1State -notmatch 'SYNTHETICSECRET') -and ($nt1State -notmatch 'SYNTHETIC_BEARER_CANARY') -and ($nt1State -notmatch 'SYNTHETIC_BEARER') -and ($nt1State -notmatch '(?i)bearer\s+\S') -and ($nt1State -notmatch [regex]::Escape($nt1Home)) -and ($nt1State -notmatch 'Jane Doe') -and ($nt1State -match '\[redacted\]') -and ($nt1State -match 'redacted-authorization') -and ($nt1State -match 'redacted-user-path') -and ($nt1State.Length -le 600)) 'jev-wiring-nt1-egress-state-has-no-canary-and-has-markers'
    # =====================================================================
    # NT2/NT3 FINAL egress contract, approved by the security-reviewer and
    # mirrored in the JevStateText-PL header of OrchestrationPlannerLoop.ps1:
    #   C1 no secret in -State. The redaction runs BEFORE any effective cut, so
    #      no canary survives whole OR as a fragment.
    #   C2 no REAL process home in -State. The strip (literal + fallbacks) runs
    #      before the 600 cap, so the real home never survives whole OR as a
    #      fragment, even when it straddles the cut.
    #   C3 -State is at most 600 chars.
    #   C4 a CUSTOM (non-real) home path is operator-authored objective text,
    #      not a secret: whole OR fragmented by the cut are both acceptable and
    #      NO shape is guaranteed. A fragment reveals no more than the whole
    #      path would, so the earlier whole-or-nothing assertion was withdrawn
    #      by explicit decision; only C1 and C3 are asserted for those cases.
    # Every cut geometry below is COMPUTED from the fixed State head and then
    # SELF-CHECKED against the raw 600 cut. If the head or the cap ever moves,
    # the case fails loudly instead of silently ceasing to straddle.
    # =====================================================================
    $ntStateHead='planner turn advisory request | objective: '
    $ntCap=600
    # NT2: redaction-before-cap (C1+C3), with a canary CROSSING the 600 cut.
    # The two cut geometries are mutually exclusive on a single objective: the
    # trigger precedes the token, so a raw cut cannot land inside the token and
    # inside "Authorization:" at once. Each gets its own case.
    $nt2Canary='Authorization: Bearer SYNTHETIC_BEARER_CANARY_CROSS'
    $nt2CanaryEarly='Authorization: Bearer SYNTHETIC_BEARER_CANARY_EARLY'
    # NT2 lead: the early canary sits at raw offset 120, far inside the cut, so
    # it proves redaction ran over the FULL pre-cap text (its marker must be
    # present) independently of where the crossing canary lands.
    $nt2EarlyAt=120
    $nt2Lead=(('A'*($nt2EarlyAt-$ntStateHead.Length-1))+' '+$nt2CanaryEarly+' ')
    # NT2a: the TOKEN straddles the cut - raw 600 lands inside SYNTHETIC_... so the
    # trigger plus part of the token stay visible. Scope note: with the current
    # patterns this geometry asserts the C1 FRAGMENT clause, not the order by
    # itself - a cap-first run still re-matches the visible token prefix and
    # replaces it, because no pattern is anchored at its end. The cut geometry
    # that actually discriminates the order is NT2b below (verified: with the
    # order inverted, NT2b fails and NT2a still passes).
    $nt2aStart=570
    $nt2aObj=$nt2Lead+(('B'*($nt2aStart-$ntStateHead.Length-$nt2Lead.Length-1))+' '+$nt2Canary+' '+('C'*120))
    $nt2aRaw=$ntStateHead+$nt2aObj
    $nt2aCut=$nt2aRaw.Substring(0,$ntCap)
    # Only the crossing region is inspected, so the early canary earlier in the
    # same objective cannot satisfy or defeat the straddle precondition. The
    # visible slice is computed FROM the canary and the cut, so the
    # precondition states the intent instead of a magic literal: the cut keeps
    # the trigger plus only part of the token, and the token tail sits past 600.
    $nt2aTail=$nt2aCut.Substring($nt2aStart-1)
    $nt2aVisible=$nt2Canary.Substring(0,($ntCap-($nt2aStart-1)-1))
    $nt2aStraddle=$nt2aTail.StartsWith(' '+$nt2aVisible) -and (-not $nt2aCut.Contains($nt2Canary)) -and (-not $nt2aVisible.EndsWith('BEARER_CANARY_CROSS'))
    $nt2aStatePath=Join-Path $plTemp 'probe-nt2a-state.txt'
    $nt2aProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt2aStatePath,$okOut))
    $nt2a=Invoke-OrchestrationPlannerLoop @{objective=$nt2aObj;risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $nt2aProbe
    $nt2aState='';if(Test-Path -LiteralPath $nt2aStatePath){$nt2aState=[IO.File]::ReadAllText($nt2aStatePath)}
    Assert-PL ($nt2aStraddle -and ($nt2aRaw.Length -gt $ntCap) -and ($nt2a.status -eq 'ok') -and ([bool]$nt2a.plan.jev_advisory_result.consulted) -and ($nt2aState.Length -le $ntCap) -and ($nt2aState -notmatch 'SYNTHETIC') -and ($nt2aState -notmatch 'BEARER_CANARY') -and ($nt2aState -notmatch '(?i)bearer\s+\S') -and ($nt2aState -match 'redacted-authorization') -and ($nt2aState -match 'objective:')) 'jev-wiring-nt2a-token-straddling-canary-redacted-before-cap'
    # NT2b: the cut lands INSIDE the trigger, so the visible remainder
    # ("Authorization:", the "Bearer <token>" half already dropped) cannot be
    # re-matched by any pattern. This is the geometry that actually proves the
    # ORDER: cap-before-redaction would cross egress with that fragment.
    # Ordinal case-sensitive Contains is deliberate: the marker
    # '[redacted-authorization]' is lowercase and must not read as a leak.
    $nt2bStart=586
    $nt2bObj=$nt2Lead+(('B'*($nt2bStart-$ntStateHead.Length-$nt2Lead.Length-1))+' '+$nt2Canary+' '+('C'*120))
    $nt2bRaw=$ntStateHead+$nt2bObj
    $nt2bCut=$nt2bRaw.Substring(0,$ntCap)
    $nt2bTail=$nt2bCut.Substring($nt2bStart-1)
    $nt2bVisible=$nt2Canary.Substring(0,($ntCap-($nt2bStart-1)-1))
    $nt2bStraddle=$nt2bTail.StartsWith(' '+$nt2bVisible) -and (-not $nt2bCut.Contains($nt2Canary)) -and (-not $nt2bVisible.Contains('Bearer'))
    $nt2bStatePath=Join-Path $plTemp 'probe-nt2b-state.txt'
    $nt2bProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt2bStatePath,$okOut))
    $nt2b=Invoke-OrchestrationPlannerLoop @{objective=$nt2bObj;risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $nt2bProbe
    $nt2bState='';if(Test-Path -LiteralPath $nt2bStatePath){$nt2bState=[IO.File]::ReadAllText($nt2bStatePath)}
    Assert-PL ($nt2bStraddle -and ($nt2bRaw.Length -gt $ntCap) -and ($nt2b.status -eq 'ok') -and ([bool]$nt2b.plan.jev_advisory_result.consulted) -and ($nt2bState.Length -le $ntCap) -and (-not $nt2bState.Contains('Authorization')) -and ($nt2bState -notmatch 'SYNTHETIC') -and ($nt2bState -notmatch 'BEARER_CANARY') -and ($nt2bState -match 'redacted-authorization') -and ($nt2bState -match 'objective:')) 'jev-wiring-nt2b-trigger-straddling-canary-redacted-before-cap'
    # NT3: the home strip side of the same order, under the C1-C4 contract.
    # (a) REAL process home CROSSING the 600 cut with the raw cut landing INSIDE
    #     the user-name segment. C2 forbids the fragment and C4 explicitly does
    #     NOT apply here: the real home is not operator text, it is the very path
    #     the strip exists for. The literal strip needs the WHOLE home and the
    #     generic fallback needs a trailing separator, so a cap-before-strip
    #     order would leak "C:\Users\<segment-prefix>". An sk- canary sits
    #     inside the retained window so C1 is checked here too.
    $nt3aRealHome=''
    try{$nt3aRealHome=([string]$env:USERPROFILE).Trim().TrimEnd([char[]]@([char]'\',[char]'/'))}catch{}
    if([string]::IsNullOrWhiteSpace($nt3aRealHome)){$nt3aRealHome='C:\synthetic-user-home-canary'}
    $nt3aSegIndex=$nt3aRealHome.LastIndexOf('\')+1
    $nt3aSeg=$nt3aRealHome.Substring($nt3aSegIndex)
    $nt3aSegHead=''
    if($nt3aSeg.Length -ge 4){$nt3aSegHead=$nt3aSeg.Substring(0,4)}
    $nt3aLead=(('A'*200)+' sk-SYNTHETICSK_PLANNER ')
    $nt3aDepth=4
    if($nt3aSeg.Length -lt $nt3aDepth){$nt3aDepth=$nt3aSeg.Length}
    $nt3aPad=$ntCap-$ntStateHead.Length-$nt3aLead.Length-1-$nt3aSegIndex-$nt3aDepth
    $nt3aObj=$nt3aLead+(('B'*$nt3aPad)+' '+$nt3aRealHome+'\private.txt '+('C'*40))
    $nt3aRaw=$ntStateHead+$nt3aObj
    $nt3aCut=$nt3aRaw.Substring(0,$ntCap)
    $nt3aStraddle=(-not [string]::IsNullOrEmpty($nt3aSegHead)) -and $nt3aCut.Contains($nt3aSegHead) -and (-not $nt3aCut.Contains($nt3aRealHome)) -and ($nt3aRaw.Length -gt $ntCap)
    $nt3aStatePath=Join-Path $plTemp 'probe-nt3a-state.txt'
    $nt3aProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt3aStatePath,$okOut))
    $nt3a=Invoke-OrchestrationPlannerLoop @{objective=$nt3aObj;risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $nt3aProbe
    $nt3aState='';if(Test-Path -LiteralPath $nt3aStatePath){$nt3aState=[IO.File]::ReadAllText($nt3aStatePath)}
    $nt3aRecordShape=([string]$nt3a.plan.frame.objective).Length -le 500
    Assert-PL ($nt3aStraddle -and ($nt3a.status -eq 'ok') -and ([bool]$nt3a.plan.jev_advisory_result.consulted) -and ($nt3aState.Length -le $ntCap) -and ($nt3aState -notmatch [regex]::Escape($nt3aRealHome)) -and ($nt3aState -notmatch [regex]::Escape('Users\'+$nt3aSegHead)) -and ($nt3aState -notmatch '(?i)[A-Za-z]:\\Users\\') -and ($nt3aState -notmatch 'SYNTHETIC') -and ($nt3aState -match '\[redacted\]') -and ($nt3aState -match 'redacted-user-path') -and $nt3aRecordShape) 'jev-wiring-nt3a-real-home-crossing-cap-has-no-whole-or-fragment'
    # (b) CUSTOM home well inside the cap. Under C4 no shape is guaranteed: the
    #     path is operator text, so whole-or-fragmented are both acceptable and
    #     the withdrawn whole-or-nothing assertion is NOT reinstated. Only C1 and
    #     C3 (plus the unchanged record shape) are asserted.
    $nt3CustomPath='D:\Profiles\Jane Doe\private.txt'
    $nt3bObj=(('A'*480)+' '+$nt3CustomPath+' tail text')
    $nt3bStatePath=Join-Path $plTemp 'probe-nt3b-state.txt'
    $nt3bProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt3bStatePath,$okOut))
    $nt3b=Invoke-OrchestrationPlannerLoop @{objective=$nt3bObj;risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $nt3bProbe
    $nt3bState='';if(Test-Path -LiteralPath $nt3bStatePath){$nt3bState=[IO.File]::ReadAllText($nt3bStatePath)}
    $nt3bRecordShape=([string]$nt3b.plan.frame.objective).Length -le 500
    Assert-PL (($nt3b.status -eq 'ok') -and ([bool]$nt3b.plan.jev_advisory_result.consulted) -and ($nt3bState.Length -le $ntCap) -and ($nt3bState -notmatch 'SYNTHETIC') -and ($nt3bState -notmatch '(?i)bearer\s+\S') -and $nt3bRecordShape) 'jev-wiring-nt3b-custom-home-inside-cap-holds-c1-c3'
    # (c) CUSTOM home CROSSING the cap: under C4 nothing is asserted about the
    #     resulting shape - the cut may leave any prefix of it. The self-check
    #     only proves the case really straddles (raw cut holds a proper prefix,
    #     not the whole path); the guarantees asserted are C1 and C3.
    $nt3cStart=585
    $nt3cObj=(('A'*($nt3cStart-$ntStateHead.Length-1))+' '+$nt3CustomPath+' tail text')
    $nt3cRaw=$ntStateHead+$nt3cObj
    $nt3cCut=$nt3cRaw.Substring(0,$ntCap)
    $nt3cStraddle=(-not $nt3cCut.Contains($nt3CustomPath)) -and $nt3cCut.Contains('D:\Profiles\Jan')
    $nt3cStatePath=Join-Path $plTemp 'probe-nt3c-state.txt'
    $nt3cProbe=[scriptblock]::Create(("param(`$tool,`$state,`$toolArgs,`$budget);[IO.File]::WriteAllText('{0}',([string]`$state));{1}" -f $nt3cStatePath,$okOut))
    $nt3c=Invoke-OrchestrationPlannerLoop @{objective=$nt3cObj;risk='low';route_uncertain=$true} $plOpt -JevAdvisoryProbe $nt3cProbe
    $nt3cState='';if(Test-Path -LiteralPath $nt3cStatePath){$nt3cState=[IO.File]::ReadAllText($nt3cStatePath)}
    $nt3cRecordShape=([string]$nt3c.plan.frame.objective).Length -le 500
    Assert-PL ($nt3cStraddle -and ($nt3c.status -eq 'ok') -and ([bool]$nt3c.plan.jev_advisory_result.consulted) -and ($nt3cState.Length -le $ntCap) -and ($nt3cState -notmatch 'SYNTHETIC') -and ($nt3cState -notmatch '(?i)bearer\s+\S') -and $nt3cRecordShape) 'jev-wiring-nt3c-custom-home-crossing-cap-holds-c1-c3'
    [System.Environment]::SetEnvironmentVariable('JEV_API_KEY',$null)
    # The record is advisory evidence only: no DONE, no authority anywhere.
    $t7Names=@($t1.plan.PSObject.Properties | ForEach-Object { $_.Name })
    Assert-PL (($t7Names -contains 'jev_advisory_result') -and ($t7Names -notcontains 'done') -and (-not [bool]$t1.plan.jev_advisory.authoritative) -and ([string]$t1.plan.jev_advisory.kernel_authority -ceq 'planner/kernel')) 'jev-wiring-advisory-only-no-done'
    # ---------- Fase 3 (Reuse-First): default store + explicit store ----------
    $f3StoreRoot=Join-Path ([IO.Path]::GetTempPath()) ('v3-pl-reuse-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $f3StoreRoot -Force | Out-Null
    try{
        $f3NoStore=Invoke-OrchestrationPlannerLoop @{objective='Reuse default store';risk='low'} @{timestamp=$now}
        Assert-PL ($f3NoStore.status -eq 'ok' -and [string]$f3NoStore.plan.reuse.status -ceq 'ok' -and [string]$f3NoStore.plan.reuse.store -ceq 'default' -and [string]$f3NoStore.plan.reuse.remaining -ceq 'unknown-pending-dispatch') 'reuse-default-store-ok'
        $f3Explicit=Invoke-OrchestrationPlannerLoop @{objective='Reuse explicit store';risk='low'} @{timestamp=$now;store_dir=$f3StoreRoot}
        Assert-PL ($f3Explicit.status -eq 'ok' -and [string]$f3Explicit.plan.reuse.status -ceq 'ok' -and [string]$f3Explicit.plan.reuse.store -ceq 'explicit') 'reuse-explicit-store-ok'
        Assert-PL ([string]$f3NoStore.plan_json -notmatch 'evidence-store-not-requested') 'reuse-not-requested-gone-from-normal-path'
        $f3FileAsStore=Join-Path $f3StoreRoot 'file-as-store';[IO.File]::WriteAllText($f3FileAsStore,'x')
        $f3StoreDown=Invoke-OrchestrationPlannerLoop @{objective='Reuse store down';risk='low'} @{timestamp=$now;store_dir=$f3FileAsStore}
        Assert-PL ($f3StoreDown.status -eq 'ok' -and [string]$f3StoreDown.plan.reuse.status -ceq 'unavailable') 'reuse-store-down-unavailable'
        Assert-PL ([string]$f3StoreDown.plan.reuse.reason -ceq 'reuse-store-query-failed') 'reuse-store-down-query-failed-reason'
    }
    finally{
        try{Remove-Item -LiteralPath $f3StoreRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    }
}
finally{
    try{Remove-Item -LiteralPath $plTemp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
}
}
finally{
    # FINDING 3 fix: this finally is the one that owns the JEV_* restore, and
    # it is attached to a try that opens before the very first env mutation, so
    # no failure between the mutation and here can leak the cleared environment
    # into the caller process.
    foreach($n in @('JEV_API_KEY','JEV_BASE_URL','JEV_MODEL')){if($script:PLSavedEnv.ContainsKey($n)){[System.Environment]::SetEnvironmentVariable($n,$script:PLSavedEnv[$n])}}
}
Write-Output "PASS OrchestrationPlannerLoop: $script:checks checks"
