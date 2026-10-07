<#
.SYNOPSIS
    Suite for the record-only dispatch pipeline (V3.1 Phase 38, slice 2).
.DESCRIPTION
    Covers the minimum/no-widen route, the rigorous L3 route, canonical
    sequencing, the P36-backed completion gate, the P35 evidence prefill, the
    post-completion persistence matrix with declared invalidation conditions,
    hostile input, determinism, malformed input, the bounded discard ladder
    (including the minimum valid envelope), fail-closed boolean gates,
    read-only contract overrides and the record-only guarantees.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationDispatchPipeline.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationPlannerLoop.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:checks=0
function Assert-DP([bool]$ok,[string]$name){$script:checks++;if(-not $ok){throw "FAIL: $name"}}
$contractFields=@('TASK_ID','OBJECTIVE','READ_SCOPE','WRITE_SCOPE','ACCEPTANCE_CRITERIA','VALIDATION','PROHIBITED_OPERATIONS','RETURN_FORMAT','ESCALATION_CONDITIONS')
function Get-ContractFieldCount($Contract){
    $keys=@()
    if($Contract -is [System.Collections.IDictionary]){$keys=@($Contract.Keys)}else{$keys=@($Contract.PSObject.Properties | ForEach-Object {$_.Name})}
    $hit=@($keys | Where-Object {$_ -in $contractFields})
    return [int]$hit.Count
}
# Engine-neutral object/JSON comparison: PS 7 ConvertFrom-Json coerces ISO
# timestamps to DateTime and re-serializes them without the sub-second part, so
# timestamps are normalized before the strict text comparison.
function Get-NormalizedJson($Value){return ((ConvertTo-Json -InputObject $Value -Depth 12 -Compress) -replace '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z','<ts>')}
# Count of a library result: wrapping the call itself in @() would turn an empty
# returned array into one element, so the value is bound first and measured after.
function Get-ResultCount($Value){return @($Value).Count}
function Get-JsonBytes([string]$Json){if($null -eq $Json){return 0};return [Text.Encoding]::UTF8.GetByteCount($Json)}
# Uncountable enumerable that refuses to produce more than cap+1 elements: the
# pipeline must stop at the declared cap instead of walking the whole list.
if(-not ('DPGuardEnumerable' -as [type])){
    Add-Type -TypeDefinition @'
public class DPGuardEnumerable : System.Collections.IEnumerable {
    private readonly int total;
    private readonly string prefix;
    public int Produced;
    public int Limit=65;
    public DPGuardEnumerable(int total){this.total=total;this.prefix="worker";}
    public DPGuardEnumerable(int total,string prefix){this.total=total;this.prefix=prefix;}
    public System.Collections.IEnumerator GetEnumerator(){return new Guard(this);}
    private class Guard : System.Collections.IEnumerator {
        private readonly DPGuardEnumerable owner; private int index=-1;
        public Guard(DPGuardEnumerable owner){this.owner=owner;}
        public object Current{get{return this.owner.prefix + "-" + this.index;}}
        public bool MoveNext(){
            if((this.index+1)>=this.owner.total){return false;}
            this.index++;
            this.owner.Produced++;
            if(this.owner.Produced > this.owner.Limit){throw new System.InvalidOperationException("declared list enumerated beyond cap+1");}
            return true;
        }
        public void Reset(){this.index=-1;}
    }
}
public class DPEmptyArrayEnumerable : System.Collections.IEnumerable {
    private readonly int total;
    public int Produced;
    public DPEmptyArrayEnumerable(int total){this.total=total;}
    public System.Collections.IEnumerator GetEnumerator(){return new Guard(this);}
    private class Guard : System.Collections.IEnumerator {
        private readonly DPEmptyArrayEnumerable owner; private int index=-1;
        public Guard(DPEmptyArrayEnumerable owner){this.owner=owner;}
        public object Current{get{return new int[0];}}
        public bool MoveNext(){
            if((this.index+1)>=this.owner.total){return false;}
            this.index++;
            this.owner.Produced++;
            return true;
        }
        public void Reset(){this.index=-1;}
    }
}
public class DPLyingCountList : System.Collections.IList {
    private readonly System.Collections.ArrayList inner=new System.Collections.ArrayList();
    private readonly int declared;
    public DPLyingCountList(int real,int declared){
        for(int i=0;i<real;i++){this.inner.Add("liar-"+i);}
        this.declared=declared;
    }
    public int Count{get{return this.declared;}}
    public bool IsReadOnly{get{return false;}}
    public bool IsFixedSize{get{return false;}}
    public bool IsSynchronized{get{return false;}}
    public object SyncRoot{get{return this;}}
    public object this[int index]{get{return this.inner[index];}set{this.inner[index]=value;}}
    public int IndexOf(object value){return this.inner.IndexOf(value);}
    public void Insert(int index,object value){this.inner.Insert(index,value);}
    public void RemoveAt(int index){this.inner.RemoveAt(index);}
    public void Remove(object value){this.inner.Remove(value);}
    public int Add(object value){return this.inner.Add(value);}
    public void Clear(){this.inner.Clear();}
    public bool Contains(object value){return this.inner.Contains(value);}
    public void CopyTo(System.Array array,int index){this.inner.CopyTo(array,index);}
    public System.Collections.IEnumerator GetEnumerator(){return this.inner.GetEnumerator();}
}
'@
}
function Get-ContractByRole($Bundle,[string]$Role){
    foreach($c in @($Bundle.contracts)){if([string]$c.role -eq $Role){return $c}}
    return $null
}
$now='2026-10-02T12:00:00Z'
$store=''
$dotStore=''
try {
    # ---- record-only guards: no spawn/network API and no kernel/flag wiring in the lib.
    $libPath=Join-Path $PSScriptRoot 'OrchestrationDispatchPipeline.ps1'
    $libText=[IO.File]::ReadAllText($libPath)
    foreach($api in @('Start-Process','System.Net','Invoke-WebRequest','Invoke-RestMethod','Start-Job','Invoke-Command','New-PSSession','Send-MailMessage','Start-ThreadJob','&')){
        Assert-DP ($libText -notmatch [regex]::Escape($api)) ('record-only-no-' + $api)
    }
    Assert-DP ($libText -notmatch 'task-kernel|capability-flags|orchestration-preflight') 'lib-does-not-wire-kernel-or-flags'
    $guarded=@('scripts\v3\task-kernel.ps1','scripts\v3\orchestration-preflight.ps1','source\registry\capability-flags.json')
    $beforeHashes=@{}
    foreach($g in $guarded){$full=Join-Path $RepoRoot $g;$beforeHashes[$g]=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}
    # ---- Smoke guard first: a regression that turns a normal plan into an error
    # must fail here by name, instead of surfacing as a null dereference later.
    $smokePlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Smoke plan'};risk_uncertainty=[pscustomobject]@{risk='medium';uncertainty='medium'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester','reviewer')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester','reviewer');parallel_ok=$true;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $smoke=Invoke-OrchestrationDispatchPipeline $smokePlan @{task_id='T-smoke';read_scope=@('a');write_scope=@('a');acceptance_criteria=@('a');return_format='S'} @{timestamp=$now}
    Assert-DP ($smoke.status -in @('ok','degraded','oversized') -and $null -ne $smoke.bundle) 'smoke-normal-plan-valid-bundle'
    Assert-DP (@($smoke.bundle.contracts).Count -eq 3 -and [string]$smoke.bundle.contracts[0].role -eq 'coder') 'smoke-normal-plan-contracts-intact'
    $smokeCompletion=Test-OrchestrationDispatchCompletion $smoke.bundle @('coder','tester','reviewer')
    Assert-DP ($smokeCompletion.status -eq 'allowed' -and $smokeCompletion.gate_verifiable) 'smoke-normal-completion-allowed'

    # ---- AC2 minimum route: no reserved validation budget -> exactly one contract, sequential.
    $nobudget=Invoke-OrchestrationPlannerLoop @{objective='Complex work';risk='high';validation_budget_available=$false} @{timestamp=$now}
    $nb=Invoke-OrchestrationDispatchPipeline $nobudget.plan @{task_id='T-2'} @{timestamp=$now}
    Assert-DP (@($nobudget.plan.dispatch_plan.workers).Count -eq 1 -and -not $nobudget.plan.dispatch_plan.parallel_ok) 'ac2-plan-has-single-worker'
    Assert-DP (@($nb.bundle.contracts).Count -eq 1 -and [string]$nb.bundle.contracts[0].role -eq 'coder' -and $nb.bundle.sequencing -eq 'sequential') 'ac2-budget-route-single-sequential'
    Assert-DP ($nb.bundle.no_widen.enforced -and @($nb.bundle.no_widen.reasons) -contains 'validation-budget-not-reserved') 'ac2-no-widen-reason-declared'
    # ---- AC2 single-worker plan that declares parallel_ok still never fans out.
    $single=[pscustomobject]@{frame=[pscustomobject]@{objective='Single worker plan'};validation=[pscustomobject]@{status='ok';level='L1';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=@('coder');parallel_ok=$true;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $sg=Invoke-OrchestrationDispatchPipeline $single @{task_id='T-2'} @{timestamp=$now}
    Assert-DP (@($sg.bundle.contracts).Count -eq 1 -and $sg.bundle.sequencing -eq 'sequential') 'ac2-single-worker-never-fans-out'

    # ---- AC3 rigorous route: L3 plan -> 4 contracts with all 9 delegation fields.
    $rigor=Invoke-OrchestrationPlannerLoop @{objective='Harden auth boundary';summary='auth';risk='critical';work_independent=$true;ownership_clear=$true;shared_state=$false;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
    $descriptor=@{task_id='T-3';read_scope=@('scripts/v3/lib/Orchestration*.ps1');write_scope=@('scripts/v3/lib/OrchestrationDispatchPipeline.ps1');acceptance_criteria=@('bundle bounded','no fan-out without plan');return_format='STATUS, CHANGES, VALIDATION'}
    $rig=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now}
    Assert-DP ([string]$rigor.plan.validation.level -eq 'L3' -and @($rigor.plan.dispatch_plan.workers).Count -eq 4) 'ac3-plan-is-l3-with-four-workers'
    Assert-DP (@($rig.bundle.contracts).Count -eq 4) 'ac3-four-contracts'
    foreach($c in @($rig.bundle.contracts)){
        Assert-DP ((Get-ContractFieldCount $c) -eq 9 -and $c.incomplete -eq $false -and @($c.missing_fields).Count -eq 0 -and [string]$c.status -eq 'ready') ('ac3-nine-fields-' + [string]$c.role)
    }
    Assert-DP ($rig.bundle.sequencing -eq 'parallel' -and $rigor.plan.dispatch_plan.parallel_ok) 'ac3-parallel-only-when-plan-declares'
    Assert-DP ($rig.record_only -and -not $rig.spawned -and -not $rig.network_access -and $rig.bundle.record_only) 'ac3-record-only-declared'
    # ---- AC3 canonical sequential order (explorer/researcher first, then coder, tester, reviewer, security-reviewer).
    $shared=Invoke-OrchestrationPlannerLoop @{objective='Shared state migration';risk='critical';work_independent=$true;ownership_clear=$true;shared_state=$true;latency_benefit=$true;synthesis_affordable=$true} @{timestamp=$now}
    $sq=Invoke-OrchestrationDispatchPipeline $shared.plan $descriptor @{timestamp=$now}
    Assert-DP ($sq.bundle.sequencing -eq 'sequential') 'ac3-parallel-denied-when-plan-says-sequential'
    $unordered=[pscustomobject]@{frame=[pscustomobject]@{objective='Canonical order'};validation=[pscustomobject]@{status='ok';level='L3';required_roles=@('coder','tester','reviewer','security-reviewer')};dispatch_plan=[pscustomobject]@{workers=@('reviewer','explorer','coder','researcher','security-reviewer','tester');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $canon=Invoke-OrchestrationDispatchPipeline $unordered $descriptor @{timestamp=$now}
    $canonRoles=((@($canon.bundle.contracts) | ForEach-Object {[string]$_.role}) -join ',')
    Assert-DP ($canonRoles -eq 'explorer,researcher,coder,tester,reviewer,security-reviewer') 'ac3-canonical-order-stable'

    # ---- AC4 completion gate (P36 reuse, never more permissive).
    $allowedVerdict=Test-OrchestrationDispatchCompletion $rig.bundle @('coder','tester','reviewer','security-reviewer')
    Assert-DP ($allowedVerdict.status -eq 'allowed' -and $allowedVerdict.allowed -and @($allowedVerdict.missing_roles).Count -eq 0 -and $allowedVerdict.record_only) 'ac4-all-required-roles-allowed'
    $blockedVerdict=Test-OrchestrationDispatchCompletion $rig.bundle @('coder','tester')
    Assert-DP ($blockedVerdict.status -eq 'blocked' -and -not $blockedVerdict.allowed -and $blockedVerdict.reason -eq 'missing-roles' -and @($blockedVerdict.missing_roles) -contains 'reviewer') 'ac4-missing-reviewer-blocked'
    $unknownVerdict=Test-OrchestrationDispatchCompletion $rig.bundle @('coder','tester','reviewer','security-reviewer','wizard')
    Assert-DP (-not $unknownVerdict.allowed -and $unknownVerdict.status -eq 'blocked' -and $unknownVerdict.reason -eq 'unknown-completed-role' -and $unknownVerdict.unknown_completed_roles -ge 1) 'ac4-unknown-role-fail-closed'
    $envelopeVerdict=Test-OrchestrationDispatchCompletion $rig @('coder','tester','reviewer','security-reviewer')
    Assert-DP ($envelopeVerdict.status -eq 'allowed') 'ac4-accepts-pipeline-envelope'
    . (Join-Path $PSScriptRoot 'OrchestrationValidationPolicy.ps1')
    $policyReference=Test-OrchestrationCompletionPolicy -Level 'L3' -CompletedRoles @('coder','tester') -Descriptor @{risk='critical'}
    Assert-DP ($blockedVerdict.completion_policy.allowed -eq $policyReference.allowed -and @($blockedVerdict.completion_policy.missing_roles) -contains 'reviewer') 'ac4-consistent-with-p36'

    # ---- F1: a plan demanding an unknown required role can never complete.
    $unknownRequiredPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Plan with an unsatisfiable role'};validation=[pscustomobject]@{status='ok';level='L3';required_roles=@('coder','tester','reviewer','security-reviewer','wizard')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester','reviewer','security-reviewer');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $urBundle=Invoke-OrchestrationDispatchPipeline $unknownRequiredPlan $descriptor @{timestamp=$now}
    Assert-DP ($urBundle.bundle.completion_gate.unknown_required_roles -eq 1 -and @($urBundle.bundle.contracts).Count -eq 4) 'f1-unknown-required-role-counted'
    $urVerdict=Test-OrchestrationDispatchCompletion $urBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=(Join-Path ([IO.Path]::GetTempPath()) 'p38s2-should-not-exist')}
    Assert-DP (-not $urVerdict.allowed -and $urVerdict.status -eq 'blocked' -and $urVerdict.reason -eq 'unknown-required-role' -and $urVerdict.unknown_required_roles -eq 1) 'f1-unknown-required-role-blocks-completion'
    Assert-DP (-not $urVerdict.persistence.created -and -not $urVerdict.persistence.attempted) 'f1-unknown-required-role-no-persistence'
    $noGateVerdict=Test-OrchestrationDispatchCompletion ([pscustomobject]@{schema_version=1;status='ok'}) @('coder','tester','reviewer','security-reviewer')
    Assert-DP (-not $noGateVerdict.allowed -and $noGateVerdict.reason -eq 'gate-unverifiable' -and -not $noGateVerdict.gate_verifiable) 'f1-bundle-without-gate-is-unverifiable'

    # ---- F2: an explicitly empty list is a declared (read-only) contract value.
    $roDescriptor=@{task_id='T-9';read_scope=@('docs');write_scope=@('scripts/v3/lib/x.ps1');acceptance_criteria=@('global criteria');return_format='STATUS';worker_contracts=@{reviewer=@{write_scope=@();acceptance_criteria=@()}}}
    $ro=Invoke-OrchestrationDispatchPipeline $rigor.plan $roDescriptor @{timestamp=$now}
    $roReviewer=Get-ContractByRole $ro.bundle 'reviewer'
    $roCoder=Get-ContractByRole $ro.bundle 'coder'
    Assert-DP ($roReviewer.Contains('WRITE_SCOPE') -and @($roReviewer['WRITE_SCOPE']).Count -eq 0) 'f2-explicit-empty-write-scope-not-inherited'
    Assert-DP ($roReviewer.Contains('ACCEPTANCE_CRITERIA') -and @($roReviewer['ACCEPTANCE_CRITERIA']).Count -eq 0) 'f2-explicit-empty-acceptance-criteria-not-inherited'
    Assert-DP (@($roCoder['WRITE_SCOPE']).Count -eq 1 -and $roCoder.status -eq 'ready') 'f2-undeclared-field-still-inherits'
    $badDescriptor=@{task_id='T-9';write_scope=@('x.ps1');worker_contracts=@{reviewer=@{write_scope=@{a='b'}}}}
    $badRo=Invoke-OrchestrationDispatchPipeline $rigor.plan $badDescriptor @{timestamp=$now}
    $badReviewer=Get-ContractByRole $badRo.bundle 'reviewer'
    Assert-DP (@($badReviewer['invalid_fields']) -contains 'WRITE_SCOPE' -and -not $badReviewer.Contains('WRITE_SCOPE') -and $badReviewer.incomplete -eq $true) 'f2-malformed-override-never-inherits'
    $blankDescriptor=@{task_id='T-9';write_scope=@('x.ps1');worker_contracts=@{reviewer=@{write_scope=@('   ')}}}
    $blankRo=Invoke-OrchestrationDispatchPipeline $rigor.plan $blankDescriptor @{timestamp=$now}
    $blankReviewer=Get-ContractByRole $blankRo.bundle 'reviewer'
    Assert-DP (@($blankReviewer['invalid_fields']) -contains 'WRITE_SCOPE' -and -not $blankReviewer.Contains('WRITE_SCOPE')) 'f2-blank-list-entry-refused'

    # ---- F3: declared invalidation conditions travel with the persisted record.
    $store=Join-Path ([IO.Path]::GetTempPath()) ('p38s2-' + [guid]::NewGuid().ToString('N'))
    $fullInput=@{task_id='T-6';run_id='R-1';worker_id='W-1';base_revision='DE22307F';source_fingerprints=@{'a.ps1'='hash-a';'b.ps1'='hash-b'};scope=@('scripts/v3/lib');command='pwsh -File suite';environment=@{runtime='pwsh';version='7'};kernel_task_ref='kernel-ref-1';result=@{summary='dispatch completion allowed';raw_ref='evidence/raw-1.json'};invalidation_conditions=@([pscustomobject]@{type='source-changed';paths=@('a.ps1','b.ps1')},[pscustomobject]@{type='base-revision';require_same=$true},[pscustomobject]@{type='ttl';expires_at='2026-10-03T00:00:00Z'})}
    $persistBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $fullInput @{timestamp=$now}
    Assert-DP ([string]$persistBundle.bundle.evidence_seed.invalidation_conditions_status -eq 'ok' -and @($persistBundle.bundle.evidence_seed.invalidation_conditions).Count -eq 3) 'f3-conditions-carried-in-bundle'
    $noStore=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer')
    Assert-DP (-not $noStore.persistence.created -and $noStore.persistence.reason -eq 'store-dir-not-provided') 'ac5-persist-requires-store-dir'
    $written=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP ($written.persistence.created -and $written.persistence.attempted -and [string]$written.persistence.evidence_id -match '^[a-f0-9]{32}$' -and $written.evidence_input.complete) 'ac5-persist-created'
    Assert-DP ($written.evidence_input.invalidation_conditions_count -eq 3 -and $written.evidence_input.invalidation_conditions_status -eq 'ok') 'f3-conditions-reported-on-verdict'
    $recordPath=Join-Path $store ([string]$written.persistence.evidence_id + '.json')
    $storedRecord=(ConvertFrom-Json ([IO.File]::ReadAllText($recordPath)))
    Assert-DP (@($storedRecord.invalidation_conditions).Count -eq 3 -and [string]$storedRecord.invalidation_conditions[2].type -eq 'ttl') 'f3-conditions-written-whole'
    $rewritten=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP ($rewritten.persistence.created -and $rewritten.persistence.reason -eq 'idempotent' -and [string]$rewritten.persistence.evidence_id -eq [string]$written.persistence.evidence_id) 'ac5-persist-idempotent-same-record'
    $blockedWrite=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder') @{store_dir=$store}
    Assert-DP (-not $blockedWrite.persistence.created -and -not $blockedWrite.persistence.attempted -and $blockedWrite.persistence.reason -eq 'missing-roles') 'ac5-persist-blocked-on-missing-roles'
    foreach($field in @('run_id','worker_id','base_revision','command','scope','source_fingerprints','kernel_task_ref','environment','invalidation_conditions')){
        $partial=@{}+$fullInput
        [void]$partial.Remove($field)
        if($field -eq 'environment'){$partial['environment']=@{version='7'}}
        if($field -eq 'source_fingerprints'){$partial['source_fingerprints']=@{}}
        $partialBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $partial @{timestamp=$now}
        $matrix=Test-OrchestrationDispatchCompletion $partialBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
        $expected=$(if($field -eq 'environment'){'environment.runtime'}elseif($field -eq 'kernel_task_ref'){'provenance.kernel_task_ref'}else{$field})
        $reported=(@($matrix.evidence_input.missing_fields) -contains $expected) -or (@($matrix.evidence_input.invalid_fields) -contains $expected)
        Assert-DP (-not $matrix.persistence.created -and -not $matrix.persistence.attempted -and $reported -and -not $matrix.evidence_input.complete) ('ac5-missing-evidence-' + $field)
    }
    $invalidInput=@{}+$fullInput
    $invalidInput['task_id']='bad id!'
    $invalidBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $invalidInput @{timestamp=$now}
    $invalidVerdict=Test-OrchestrationDispatchCompletion $invalidBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP (-not $invalidVerdict.persistence.created -and $invalidVerdict.persistence.reason -eq 'invalid-evidence-input' -and @($invalidVerdict.evidence_input.invalid_fields) -contains 'task_id') 'ac5-invalid-evidence-input-typed'
    # A fingerprint set that cannot be carried whole is refused, never partially stored.
    $tooMany=@{}+$fullInput
    $manyPrints=@{}
    for($i=0;$i -lt 40;$i++){$manyPrints[("file-$i.ps1")]=[string]$i}
    $tooMany['source_fingerprints']=$manyPrints
    $manyBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $tooMany @{timestamp=$now}
    $manyVerdict=Test-OrchestrationDispatchCompletion $manyBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP (-not $manyVerdict.persistence.created -and -not $manyVerdict.persistence.attempted -and @($manyVerdict.evidence_input.missing_fields) -contains 'source_fingerprints') 'ac5-oversized-fingerprint-set-refused'
    $longPrint=@{}+$fullInput
    $longPrint['source_fingerprints']=@{'a.ps1'=('h' * 200)}
    $longBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $longPrint @{timestamp=$now}
    $longVerdict=Test-OrchestrationDispatchCompletion $longBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP (-not $longVerdict.persistence.created -and -not $longVerdict.persistence.attempted -and @($longVerdict.evidence_input.missing_fields) -contains 'source_fingerprints') 'ac5-truncatable-fingerprint-refused'
    # F3 negative matrix: an unusable condition set refuses persistence, never a partial write.
    $badConditionSets=New-Object System.Collections.ArrayList
    [void]$badConditionSets.Add(@([pscustomobject]@{type='made-up';foo='bar'}))
    [void]$badConditionSets.Add(@([pscustomobject]@{type='base-revision';require_same='yes'}))
    [void]$badConditionSets.Add(@([pscustomobject]@{type='source-changed';paths=@()}))
    [void]$badConditionSets.Add(@([pscustomobject]@{type='ttl';expires_at='not-a-date'}))
    [void]$badConditionSets.Add(@([pscustomobject]@{type='criteria-changed'}))
    [void]$badConditionSets.Add(@('not-an-object'))
    foreach($badSet in $badConditionSets){
        $badCond=@{}+$fullInput
        $badCond['invalidation_conditions']=$badSet
        $badBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $badCond @{timestamp=$now}
        $badVerdict=Test-OrchestrationDispatchCompletion $badBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
        Assert-DP (-not $badVerdict.persistence.created -and -not $badVerdict.persistence.attempted -and @($badVerdict.evidence_input.invalid_fields) -contains 'invalidation_conditions' -and -not [string]::IsNullOrWhiteSpace([string]$badVerdict.evidence_input.invalidation_conditions_reason)) ('f3-invalid-conditions-refused-' + [string]$badVerdict.evidence_input.invalidation_conditions_reason)
    }
    # F3 end-to-end: the transported conditions really invalidate the evidence.
    $condStore=Join-Path ([IO.Path]::GetTempPath()) ('p38s2-cond-' + [guid]::NewGuid().ToString('N'))
    $condInput=@{task_id='T-7';run_id='R-7';worker_id='W-7';base_revision='DE22307F';source_fingerprints=@{'a.ps1'='hash-a';'b.ps1'='hash-b'};scope=@('scripts/v3/lib');command='pwsh -File suite';environment=@{runtime='pwsh';version='7'};kernel_task_ref='kernel-ref-7';result=@{summary='conditions end to end';raw_ref='evidence/raw-7.json'};invalidation_conditions=@([pscustomobject]@{type='source-changed';paths=@('a.ps1','b.ps1')},[pscustomobject]@{type='base-revision';require_same=$true},[pscustomobject]@{type='ttl';expires_at='2026-10-03T00:00:00Z'})}
    $condBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $condInput @{timestamp=$now}
    $condWrite=Test-OrchestrationDispatchCompletion $condBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$condStore}
    Assert-DP ($condWrite.persistence.created) 'f3-conditions-record-created'
    $reusableNow=Find-ReusableOrchestrationEvidence -StoreDir $condStore -Scope @() -CurrentSourceFingerprints @{'a.ps1'='hash-a';'b.ps1'='hash-b'} -CurrentBaseRevision 'DE22307F' -CurrentCriteriaHash '' -CurrentEnv @{} -Now '2026-10-02T13:00:00Z'
    Assert-DP ((Get-ResultCount $reusableNow) -eq 1) 'f3-reusable-while-valid'
    $reusableChanged=Find-ReusableOrchestrationEvidence -StoreDir $condStore -Scope @() -CurrentSourceFingerprints @{'a.ps1'='hash-a';'b.ps1'='hash-changed'} -CurrentBaseRevision 'DE22307F' -CurrentCriteriaHash '' -CurrentEnv @{} -Now '2026-10-02T13:00:00Z'
    Assert-DP ((Get-ResultCount $reusableChanged) -eq 0) 'f3-not-reusable-after-source-change'
    $reusableExpired=Find-ReusableOrchestrationEvidence -StoreDir $condStore -Scope @() -CurrentSourceFingerprints @{'a.ps1'='hash-a';'b.ps1'='hash-b'} -CurrentBaseRevision 'DE22307F' -CurrentCriteriaHash '' -CurrentEnv @{} -Now '2026-10-04T00:00:00Z'
    Assert-DP ((Get-ResultCount $reusableExpired) -eq 0) 'f3-not-reusable-after-ttl'
    $reusableMoved=Find-ReusableOrchestrationEvidence -StoreDir $condStore -Scope @() -CurrentSourceFingerprints @{'a.ps1'='hash-a';'b.ps1'='hash-b'} -CurrentBaseRevision 'OTHER-REVISION' -CurrentCriteriaHash '' -CurrentEnv @{} -Now '2026-10-02T13:00:00Z'
    Assert-DP ((Get-ResultCount $reusableMoved) -eq 0) 'f3-not-reusable-after-base-revision-move'
    $reusableAgain=Find-ReusableOrchestrationEvidence -StoreDir $condStore -Scope @() -CurrentSourceFingerprints @{'a.ps1'='hash-a';'b.ps1'='hash-b'} -CurrentBaseRevision 'DE22307F' -CurrentCriteriaHash '' -CurrentEnv @{} -Now '2026-10-02T13:00:00Z' -MaxResults 5
    Assert-DP ((Get-ResultCount $reusableAgain) -eq 1) 'f3-unchanged-still-reusable-after-negative-probes'
    try{Remove-Item -LiteralPath $condStore -Recurse -Force -ErrorAction SilentlyContinue}catch{}

    # ---- F4a/F10: an unreserved budget keeps exactly one contract, even with parallel_ok=$true.
    $mutPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Budget mutation survivor'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester','reviewer')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester','reviewer');parallel_ok=$true;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$false}}
    $mut=Invoke-OrchestrationDispatchPipeline $mutPlan $descriptor @{timestamp=$now}
    Assert-DP (@($mut.bundle.contracts).Count -eq 1 -and [string]$mut.bundle.contracts[0].role -eq 'coder') 'f10-budget-mutation-single-contract'
    Assert-DP ($mut.bundle.sequencing -eq 'sequential' -and $mut.bundle.no_widen.withheld_roles -eq 2 -and @($mut.bundle.no_widen.reasons) -contains 'validation-budget-not-reserved') 'f10-budget-mutation-sequential-and-declared'
    Assert-DP ($mut.bundle.no_widen.validation_reserved -eq $false) 'f10-budget-mutation-not-reserved'
    # ---- F4b: only a real boolean $true opens a gate.
    $badBooleans=New-Object System.Collections.ArrayList
    [void]$badBooleans.Add('false')
    [void]$badBooleans.Add('true')
    [void]$badBooleans.Add(1)
    [void]$badBooleans.Add(0)
    [void]$badBooleans.Add(@($true))
    [void]$badBooleans.Add(@{value=$true})
    foreach($badBool in $badBooleans){
        $parallelPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Boolean gate'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester');parallel_ok=$badBool;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
        $parallelBundle=Invoke-OrchestrationDispatchPipeline $parallelPlan $descriptor @{timestamp=$now}
        Assert-DP ($parallelBundle.bundle.sequencing -eq 'sequential' -and @($parallelBundle.bundle.no_widen.reasons) -contains 'parallel-ok-not-boolean') ('f4b-parallel-ok-not-boolean-' + $badBool.GetType().Name)
        $budgetPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Boolean gate'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$badBool}}
        $budgetBundle=Invoke-OrchestrationDispatchPipeline $budgetPlan $descriptor @{timestamp=$now}
        Assert-DP (@($budgetBundle.bundle.contracts).Count -eq 1 -and $budgetBundle.bundle.no_widen.validation_reserved -eq $false -and @($budgetBundle.bundle.no_widen.reasons) -contains 'validation-reserved-not-boolean') ('f4b-budget-not-boolean-' + $badBool.GetType().Name)
    }

    # ---- F5: the caller path is used verbatim; only the reported value is sanitized.
    $dotStore=Join-Path ([IO.Path]::GetTempPath()) ('p38s2.acme.com-' + [guid]::NewGuid().ToString('N'))
    $dotVerdict=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$dotStore}
    Assert-DP ($dotVerdict.persistence.created -and $dotVerdict.persistence.store_dir_display -notmatch 'acme\.com' -and $dotVerdict.persistence.store_dir_display -match 'redacted-host') 'f5-store-dir-display-sanitized'
    Assert-DP (Test-Path -LiteralPath (Join-Path $dotStore ([string]$dotVerdict.persistence.evidence_id + '.json'))) 'f5-original-store-dir-used'
    Assert-DP (@(Get-ChildItem -LiteralPath $dotStore -Filter '*.json' -File).Count -eq 1) 'f5-no-write-outside-declared-dir'
    $fileStore=Join-Path ([IO.Path]::GetTempPath()) ('p38s2-file-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($fileStore,'not-a-directory')
    $fileVerdict=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$fileStore}
    Assert-DP (-not $fileVerdict.persistence.created -and -not $fileVerdict.persistence.attempted -and $fileVerdict.persistence.reason -eq 'store-dir-not-a-directory') 'f5-store-dir-must-be-a-directory'
    $controlStore='C:\bad'+[string][char]0+'path'
    $controlVerdict=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$controlStore}
    Assert-DP (-not $controlVerdict.persistence.created -and $controlVerdict.persistence.reason -eq 'store-dir-control-character') 'f5-store-dir-control-character-refused'
    $intStore=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=42}
    Assert-DP (-not $intStore.persistence.created -and $intStore.persistence.reason -eq 'store-dir-not-a-string') 'f5-store-dir-non-string-refused'

    # ---- F6: completion and persistence from a JSON round trip (PS 7 coerces created_at).
    $roundTrip=$persistBundle.bundle_json | ConvertFrom-Json
    $roundVerdict=Test-OrchestrationDispatchCompletion $roundTrip @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP ($roundVerdict.allowed -and $roundVerdict.persistence.created -and [string]$roundVerdict.evidence_input.invalidation_conditions_status -eq 'ok') 'f6-roundtrip-json-completes-and-persists'
    $roundNoOptions=Test-OrchestrationDispatchCompletion $roundTrip @('coder','tester','reviewer','security-reviewer')
    Assert-DP ($roundNoOptions.allowed -and $roundNoOptions.persistence.reason -eq 'store-dir-not-provided' -and @($roundNoOptions.missing_roles).Count -eq 0) 'f6-roundtrip-without-timestamp-option'

    # ---- F7: role identity is validated before any sanitizing.
    $controlRole=('coder'+[char]0)
    $controlPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Control character role'};validation=[pscustomobject]@{status='ok';level='L1';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=@($controlRole,'coder');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $controlBundle=Invoke-OrchestrationDispatchPipeline $controlPlan $descriptor @{timestamp=$now}
    Assert-DP (@($controlBundle.bundle.contracts).Count -eq 1 -and [string]$controlBundle.bundle.contracts[0].role -eq 'coder' -and $controlBundle.bundle.rejected_count -eq 1) 'f7-control-char-role-rejected'
    Assert-DP ([string]$controlBundle.bundle.rejected_roles[0].reason -eq 'role-not-in-allowlist' -and $controlBundle.bundle_json -notmatch [regex]::Escape([string][char]0)) 'f7-control-char-role-scrubbed'
    $controlVerdict=Test-OrchestrationDispatchCompletion $rig.bundle @($controlRole,'coder','tester','reviewer','security-reviewer')
    Assert-DP (-not $controlVerdict.allowed -and $controlVerdict.reason -eq 'unknown-completed-role') 'f7-control-char-completed-role-rejected'

    # ---- AC5 evidence prefill comes from plan.reuse only, sanitized.
    $reuseLoop=Invoke-OrchestrationPlannerLoop @{objective='Reusable evidence';risk='low'} @{timestamp=$now;stage_results=@{reuse=[pscustomobject]@{status='ok';results=@([pscustomobject]@{evidence_id='0123456789abcdef0123456789abcdef';raw_ref='evidence/ref.json';byte_len=120;summary='sk-SYNTHETICSECRET token=bad evil.com'})}}}
    $rp=Invoke-OrchestrationDispatchPipeline $reuseLoop.plan @{task_id='T-5'} @{timestamp=$now}
    Assert-DP ($rp.bundle.evidence_prefill.status -eq 'ok' -and $rp.bundle.evidence_prefill.count -eq 1 -and [string]$rp.bundle.evidence_prefill.results[0].summary -notmatch 'SYNTHETICSECRET|token=bad|evil\.com') 'ac5-prefill-sanitized-from-plan'
    $noReuse=Invoke-OrchestrationDispatchPipeline $nobudget.plan @{task_id='T-5'} @{timestamp=$now}
    Assert-DP ([string]$noReuse.bundle.evidence_prefill.status -eq 'ok' -and [int]$noReuse.bundle.evidence_prefill.count -eq 0) 'ac5-mandatory-reuse-miss-not-unavailable'
    Assert-DP ([string]$sg.bundle.evidence_prefill.status -eq 'unavailable' -and -not [string]::IsNullOrWhiteSpace([string]$sg.bundle.evidence_prefill.reason)) 'ac5-no-reuse-no-prefill'
    Assert-DP ($rig.status -eq 'ok' -and $nb.status -eq 'ok') 'ac2-ac3-normal-route-is-ok'

    # ---- AC6 hostile input: canaries redacted, status valid, unknown roles rejected.
    $hostilePlan=[pscustomobject]@{
        frame=[pscustomobject]@{objective='sk-SYNTHETICSECRET token=bad evil.com'}
        reuse=[pscustomobject]@{status='ok';results=@([pscustomobject]@{evidence_id='sk-SYNTHETICSECRET';raw_ref='evil.com';byte_len=7;summary='token=bad'})}
        simplicity=[pscustomobject]@{status='ok';contract=[pscustomobject]@{non_goals=@('sk-SYNTHETICSECRET token=bad')}}
        risk_uncertainty=[pscustomobject]@{risk='critical';uncertainty='high'}
        validation=[pscustomobject]@{status='ok';level='L3';required_roles=@('coder','sk-SYNTHETICSECRET token=bad')}
        dispatch_plan=[pscustomobject]@{workers=@('coder','sk-SYNTHETICSECRET token=bad','wizard');parallel_ok=$true;escalations=@([pscustomobject]@{type='token=bad';rationale='sk-SYNTHETICSECRET evil.com'})}
        budget_reservation=[pscustomobject]@{validation_reserved=$true}
        stop_condition='sk-SYNTHETICSECRET token=bad'
    }
    $hostile=Invoke-OrchestrationDispatchPipeline $hostilePlan @{task_id='sk-SYNTHETICSECRET';read_scope=@('token=bad evil.com')} @{timestamp='sk-SYNTHETICSECRET token=bad'}
    Assert-DP ($hostile.bundle_json -notmatch 'SYNTHETICSECRET|token=bad|evil\.com') 'ac6-canary-absent-everywhere'
    Assert-DP ($hostile.status -in @('ok','degraded','oversized') -and [string]$hostile.bundle.timestamp_note -match 'Invalid timestamp') 'ac6-status-valid-timestamp-note'
    Assert-DP (@($hostile.bundle.contracts).Count -eq 1 -and @($hostile.bundle.rejected_roles).Count -eq 2 -and [string]$hostile.bundle.rejected_roles[0].reason -eq 'role-not-in-allowlist' -and $hostile.bundle.completion_gate.unknown_required_roles -eq 1) 'ac6-allowlist-fail-closed'
    $hostileVerdict=Test-OrchestrationDispatchCompletion $hostile.bundle @('coder','sk-SYNTHETICSECRET token=bad') @{store_dir=$store}
    Assert-DP (-not $hostileVerdict.allowed -and $hostileVerdict.reason -eq 'unknown-required-role' -and (ConvertTo-Json -InputObject $hostileVerdict -Depth 6 -Compress) -notmatch 'SYNTHETICSECRET|token=bad') 'ac6-verdict-sanitized'

    # ---- AC7 determinism and absolute byte cap.
    $first=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now}
    $second=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now}
    Assert-DP ($first.bundle_json -ceq $second.bundle_json -and $first.byte_length -eq $second.byte_length) 'ac7-byte-identical-serialization'
    Assert-DP ($first.bounded -and $first.byte_length -le 8192) 'ac7-bounded-under-cap'

    # ---- AC8 malformed plan record -> conservative valid fallback, never a throw.
    $malformedInputs=New-Object System.Collections.ArrayList
    [void]$malformedInputs.Add($null)
    [void]$malformedInputs.Add('garbage')
    [void]$malformedInputs.Add(42)
    [void]$malformedInputs.Add(@('a','b'))
    [void]$malformedInputs.Add([pscustomobject]@{foo='bar'})
    [void]$malformedInputs.Add([pscustomobject]@{dispatch_plan=[pscustomobject]@{workers=@{a='b'}};validation=$null})
    [void]$malformedInputs.Add([pscustomobject]@{dispatch_plan=[pscustomobject]@{workers='coder'}})
    [void]$malformedInputs.Add([pscustomobject]@{validation=[pscustomobject]@{level='L3';required_roles=@('coder')}})
    foreach($malformed in $malformedInputs){
        $guard=Invoke-OrchestrationDispatchPipeline $malformed $null @{timestamp=$now}
        $parsed=$null
        try{$parsed=$guard.bundle_json | ConvertFrom-Json -ErrorAction Stop}catch{}
        $consistent=$true
        if($null -ne $parsed){$consistent=((Get-NormalizedJson $guard.bundle) -ceq (Get-NormalizedJson $parsed))}
        Assert-DP ($guard.status -in @('ok','degraded','oversized') -and $null -ne $parsed -and @($guard.bundle.contracts).Count -le 1 -and [string]$guard.bundle.sequencing -eq 'sequential') 'ac8-malformed-conservative-valid'
        Assert-DP ($consistent -and $guard.bounded) 'ac8-object-and-json-consistent'
    }

    # ---- Bounded discard ladder: ordered discards at the absolute cap.
    $bigEntries=@()
    for($i=0;$i -lt 12;$i++){$bigEntries+=@("scope-entry-$i-" + ('z' * 180))}
    $bigDescriptor=@{task_id='T-8';read_scope=$bigEntries;write_scope=$bigEntries;acceptance_criteria=$bigEntries;prohibited_operations=$bigEntries;return_format=('f' * 300)}
    $big=Invoke-OrchestrationDispatchPipeline $rigor.plan $bigDescriptor @{timestamp=$now}
    $bigParsed=$null
    try{$bigParsed=$big.bundle_json | ConvertFrom-Json -ErrorAction Stop}catch{}
    Assert-DP ($big.discard_order.Count -eq 5 -and $big.bounded -and $big.byte_length -le 8192 -and $null -ne $bigParsed) 'bounded-discard-ladder-valid-json'
    Assert-DP ((Get-NormalizedJson $big.bundle) -ceq (Get-NormalizedJson $bigParsed)) 'bounded-object-and-json-agree'
    Assert-DP (@($big.bundle.discard_applied).Count -ge 1 -and ($big.status -in @('ok','degraded','oversized'))) 'bounded-discard-order-declared'
    if($big.status -eq 'oversized'){
        Assert-DP ($big.truncated -and $big.oversized -and [string]$bigParsed.status -eq 'oversized' -and -not [string]::IsNullOrWhiteSpace([string]$bigParsed.generated_at)) 'bounded-minimum-envelope-valid'
    }else{
        Assert-DP (@($big.bundle.contracts).Count -eq 4) 'bounded-contract-roles-survive-discard'
    }
    # A declared list larger than the cap is refused whole, never silently narrowed.
    $overCap=@()
    for($i=0;$i -lt 40;$i++){$overCap+=@("entry-$i")}
    $overBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan @{task_id='T-8';write_scope=$overCap} @{timestamp=$now}
    $overCoder=Get-ContractByRole $overBundle.bundle 'coder'
    Assert-DP (@($overCoder['invalid_fields']) -contains 'WRITE_SCOPE' -and -not $overCoder.Contains('WRITE_SCOPE') -and $overCoder.incomplete -eq $true) 'bounded-over-cap-list-refused-not-narrowed'
    # ---- F9: the declared cap can only tighten, and a tight cap drives the minimum envelope.
    $tight=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now;max_bundle_bytes=512}
    $tightParsed=$tight.bundle_json | ConvertFrom-Json -ErrorAction Stop
    Assert-DP ($tight.byte_cap -eq 512 -and $first.byte_cap -eq 8192) 'f9-cap-only-tightens'
    Assert-DP ($tight.status -eq 'oversized' -and $tight.truncated -and $tight.bounded -and $tight.byte_length -le 512) 'f9-tight-cap-forces-envelope'
    Assert-DP ([string]$tightParsed.status -eq 'oversized' -and $tightParsed.truncated -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$tightParsed.generated_at) -and @($tightParsed.discard_applied).Count -eq 5) 'f9-minimum-envelope-valid'
    Assert-DP ((Get-NormalizedJson $tight.bundle) -ceq (Get-NormalizedJson $tightParsed)) 'f9-envelope-object-and-json-agree'
    $tightVerdict=Test-OrchestrationDispatchCompletion $tight.bundle @('coder','tester','reviewer','security-reviewer')
    Assert-DP (-not $tightVerdict.allowed -and $tightVerdict.reason -eq 'gate-unverifiable' -and -not $tightVerdict.persistence.created) 'f9-envelope-cannot-complete'
    $tooTight=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now;max_bundle_bytes=10}
    Assert-DP ($tooTight.byte_cap -eq 8192 -and $tooTight.status -ne 'error') 'f9-absurd-cap-ignored'
    $stringCap=Invoke-OrchestrationDispatchPipeline $rigor.plan $descriptor @{timestamp=$now;max_bundle_bytes='1024'}
    Assert-DP ($stringCap.byte_cap -eq 8192) 'f9-non-integer-cap-ignored'

    # ---- Pathological declared lists stay bounded and counted (never silently dropped).
    $manyWorkers=@()
    for($i=0;$i -lt 200;$i++){$manyWorkers+=@("role-$i")}
    $manyRoles=@()
    for($i=0;$i -lt 100;$i++){$manyRoles+=@("role-$i")}
    $pathological=[pscustomobject]@{frame=[pscustomobject]@{objective='Pathological plan'};validation=[pscustomobject]@{status='ok';level='L3';required_roles=$manyRoles};dispatch_plan=[pscustomobject]@{workers=$manyWorkers;parallel_ok=$true;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $path=Invoke-OrchestrationDispatchPipeline $pathological $descriptor @{timestamp=$now}
    Assert-DP ($path.bounded -and $path.byte_length -le 8192 -and @($path.bundle.contracts).Count -eq 0 -and @($path.bundle.rejected_roles).Count -le 16) 'bounded-pathological-worker-list'
    Assert-DP ($path.bundle.rejected_count -eq 64 -and @($path.bundle.no_widen.reasons) -contains 'declared-workers-cap-exceeded' -and $path.bundle.completion_gate.unknown_required_roles -eq 100) 'bounded-pathological-counts-declared'
    # ---- F8: cardinality is checked before materialization and the excess is counted.
    Assert-DP ($path.bundle.no_widen.workers_overflow -eq 136 -and $path.bundle.plan_ref.declared_workers -eq 200 -and $path.bundle.no_widen.contract_count -eq 0) 'f8-worker-cap-before-materialization'
    $pathVerdict=Test-OrchestrationDispatchCompletion $path.bundle @('coder')
    Assert-DP (-not $pathVerdict.allowed -and $pathVerdict.reason -in @('gate-unavailable','unknown-required-role') -and @($pathVerdict.missing_roles).Count -gt 0) 'pathological-required-roles-stay-blocked'
    # ---- G1: a gate that is unavailable or misshapen can never complete.
    $unavailablePlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Gate unavailable'};validation=[pscustomobject]@{status='unavailable';level='NOPE';required_roles=@('coder','tester','reviewer','security-reviewer')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester','reviewer','security-reviewer');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $unavailableBundle=Invoke-OrchestrationDispatchPipeline $unavailablePlan $descriptor @{timestamp=$now}
    Assert-DP ([string]$unavailableBundle.bundle.completion_gate.status -eq 'unavailable' -and [string]$unavailableBundle.bundle.completion_gate.level -eq 'L3' -and $unavailableBundle.bundle.completion_gate.unknown_required_roles -eq 0) 'g1-gate-marked-unavailable'
    $unavailableVerdict=Test-OrchestrationDispatchCompletion $unavailableBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP (-not $unavailableVerdict.allowed -and $unavailableVerdict.status -eq 'blocked' -and $unavailableVerdict.reason -eq 'gate-unavailable') 'g1-unavailable-gate-blocks-completion'
    Assert-DP (-not $unavailableVerdict.persistence.created -and -not $unavailableVerdict.persistence.attempted) 'g1-unavailable-gate-no-persistence'
    $shapeBundle=@{completion_gate=[pscustomobject]@{status='ok';level='L9';required_roles=@('coder');unknown_required_roles=0}}
    $shapeVerdict=Test-OrchestrationDispatchCompletion ([pscustomobject]$shapeBundle) @('coder')
    Assert-DP (-not $shapeVerdict.allowed -and $shapeVerdict.reason -eq 'gate-unverifiable' -and [string]$shapeVerdict.gate_shape_error -eq 'gate-level-invalid') 'g1-invalid-gate-level-unverifiable'
    $noRolesBundle=[pscustomobject]@{completion_gate=[pscustomobject]@{status='ok';level='L2';required_roles=@();unknown_required_roles=0}}
    $noRolesVerdict=Test-OrchestrationDispatchCompletion $noRolesBundle @('coder','tester','reviewer')
    Assert-DP (-not $noRolesVerdict.allowed -and $noRolesVerdict.reason -eq 'gate-unverifiable' -and [string]$noRolesVerdict.gate_shape_error -eq 'gate-required-roles-missing') 'g1-missing-required-roles-unverifiable'
    $noCounterBundle=[pscustomobject]@{completion_gate=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder')}}
    $noCounterVerdict=Test-OrchestrationDispatchCompletion $noCounterBundle @('coder')
    Assert-DP (-not $noCounterVerdict.allowed -and $noCounterVerdict.reason -eq 'gate-unverifiable' -and [string]$noCounterVerdict.gate_shape_error -eq 'gate-unknown-required-counter-missing') 'g1-missing-counter-unverifiable'
    Assert-DP ($allowedVerdict.gate_verifiable -and [string]$allowedVerdict.gate_status -eq 'ok') 'g1-normal-gate-still-verifiable'

    # ---- G2: workers declared empty dispatch nothing; absent keeps the conservative fallback.
    $emptyWorkers=[pscustomobject]@{frame=[pscustomobject]@{objective='Declared empty workers'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester','reviewer')};dispatch_plan=[pscustomobject]@{workers=@();parallel_ok=$true;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $emptyBundle=Invoke-OrchestrationDispatchPipeline $emptyWorkers $descriptor @{timestamp=$now}
    Assert-DP (@($emptyBundle.bundle.contracts).Count -eq 0 -and @($emptyBundle.bundle.no_widen.reasons) -contains 'workers-declared-empty') 'g2-declared-empty-no-contracts'
    Assert-DP ($emptyBundle.bundle.plan_ref.declared_workers -eq 0 -and [string]$emptyBundle.bundle.fallback_reason -eq '' -and $emptyBundle.bundle.sequencing -eq 'sequential') 'g2-declared-empty-is-not-a-fallback'
    Assert-DP ($emptyBundle.bundle.no_widen.validation_reserved -eq $true -and $emptyBundle.bundle.no_widen.withheld_roles -eq 0) 'g2-declared-empty-withheld-zero'
    $emptyVerdict=Test-OrchestrationDispatchCompletion $emptyBundle.bundle @('coder','tester','reviewer')
    Assert-DP (-not $emptyVerdict.allowed) 'g2-declared-empty-cannot-complete'
    $absentBundle=Invoke-OrchestrationDispatchPipeline ([pscustomobject]@{frame=[pscustomobject]@{objective='Absent workers'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder')}}) $descriptor @{timestamp=$now}
    Assert-DP (@($absentBundle.bundle.contracts).Count -eq 1 -and [string]$absentBundle.bundle.fallback_reason -eq 'plan-dispatch-workers-missing') 'g2-absent-workers-keep-conservative-fallback'

    # ---- G3: the minimum envelope is sized in bytes and always fits the declared cap.
    $wideRef='界'*120
    $wideDescriptor=@{task_id=$wideRef;read_scope=@('a');write_scope=@('a');acceptance_criteria=@('a');return_format='S'}
    $wideBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $wideDescriptor @{timestamp=$now;max_bundle_bytes=512}
    Assert-DP ($wideBundle.status -eq 'oversized' -and $wideBundle.bounded -and $wideBundle.byte_length -le 512) 'g3-multibyte-envelope-fits-cap'
    $wideParsed=$wideBundle.bundle_json | ConvertFrom-Json -ErrorAction Stop
    Assert-DP ([string]$wideParsed.status -eq 'oversized' -and $wideParsed.truncated -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$wideParsed.generated_at)) 'g3-multibyte-envelope-valid'
    Assert-DP ((Get-NormalizedJson $wideBundle.bundle) -ceq (Get-NormalizedJson $wideParsed)) 'g3-multibyte-envelope-object-json-agree'
    Assert-DP ((Get-JsonBytes ([string]$wideParsed.task_ref)) -le 64 -and (Get-JsonBytes ([string]$wideParsed.task_ref)) -gt 24) 'g3-task-ref-byte-bounded-upfront'
    # The scenario is genuinely oversized only if the reference were not sized in bytes.
    $naiveEnvelope=[ordered]@{schema_version=1;status='oversized';record_only=$true;truncated=$true;oversized=$true;task_ref=([string]$wideRef.Length+':'+$wideRef);generated_at=$now;discard_applied=@('replace with minimum valid envelope')}
    Assert-DP ((Get-JsonBytes (ConvertTo-Json -InputObject $naiveEnvelope -Depth 4 -Compress)) -gt 512) 'g3-naive-oversize-scenario-confirmed'
    $tinyBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan @{task_id=('界'*400);read_scope=@('a');write_scope=@('a');acceptance_criteria=@('a');return_format='S'} @{timestamp=$now;max_bundle_bytes=512}
    Assert-DP ($tinyBundle.status -eq 'oversized' -and $tinyBundle.byte_length -le 512 -and $tinyBundle.bounded -and @($tinyBundle.bundle.discard_applied).Count -ge 1) 'g3-huge-multibyte-still-fits'

    # ---- G4: a declared list is consumed up to cap+1 elements, never fully enumerated.
    $instrumented=New-Object System.Collections.ArrayList
    [void]$instrumented.Add('worker-0')
    for($i=1;$i -lt 200;$i++){[void]$instrumented.Add("worker-$i")}
    $planWithEnumerable=[pscustomobject]@{frame=[pscustomobject]@{objective='Uncountable enumerable'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=(New-Object DPGuardEnumerable (200,'worker'));parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $enumBundle=Invoke-OrchestrationDispatchPipeline $planWithEnumerable $descriptor @{timestamp=$now}
    Assert-DP (@($enumBundle.bundle.contracts).Count -eq 0 -and @($enumBundle.bundle.rejected_roles).Count -eq 16) 'g4-uncountable-enumerable-capped'
    Assert-DP ($enumBundle.bundle.plan_ref.declared_workers -eq 65 -and $enumBundle.bundle.no_widen.workers_overflow -eq 1 -and @($enumBundle.bundle.no_widen.reasons) -contains 'declared-workers-cap-exceeded') 'g4-enumeration-stops-at-cap'
    $guardWorkers=New-Object DPGuardEnumerable (500,'worker')
    $guardRoles=New-Object DPGuardEnumerable (500,'coder')
    $guardedPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Guarded enumerable'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=$guardRoles};dispatch_plan=[pscustomobject]@{workers=$guardWorkers;parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $guardBundle=Invoke-OrchestrationDispatchPipeline $guardedPlan $descriptor @{timestamp=$now}
    Assert-DP ($guardBundle.status -ne 'error' -and $guardBundle.bounded) 'g4-guarded-enumerable-does-not-throw'
    Assert-DP ($guardWorkers.Produced -le 65 -and $guardRoles.Produced -le 65) 'g4-guard-stops-at-cap-plus-one'
    Assert-DP ($guardBundle.bundle.completion_gate.unknown_required_roles -ge 64 -and $guardBundle.bundle.no_widen.workers_overflow -eq 1) 'g4-overflow-declared-for-both-lists'
    Assert-DP ($instrumented.Count -eq 200 -and @($enumBundle.bundle.rejected_roles).Count -le 16) 'g4-rejected-list-stays-bounded'

    # ---- G5: withheld_roles only counts real retention.
    Assert-DP ($rig.bundle.no_widen.withheld_roles -eq 0 -and @($rig.bundle.contracts).Count -eq 4) 'g5-normal-route-withholds-nothing'
    $mutBundle=Invoke-OrchestrationDispatchPipeline $mutPlan $descriptor @{timestamp=$now}
    Assert-DP ($mutBundle.bundle.no_widen.withheld_roles -eq 2 -and @($mutBundle.bundle.contracts).Count -eq 1) 'g5-minimum-route-withholds-the-rest'
    Assert-DP ($path.bundle.no_widen.withheld_roles -eq 0) 'g5-zero-contracts-never-negative'

    # ---- G6: store_dir must be a real string, whatever the array shape.
    foreach($shape in @(@($store),@(),@($store,'extra'))){
        $shapeVerdictStore=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$shape}
        Assert-DP (-not $shapeVerdictStore.persistence.created -and -not $shapeVerdictStore.persistence.attempted -and $shapeVerdictStore.persistence.reason -eq 'store-dir-not-a-string') ('g6-store-dir-array-refused-' + @($shape).Count)
    }
    $singleArray=Test-OrchestrationDispatchCompletion $persistBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=@($dotStore)}
    Assert-DP (-not $singleArray.persistence.created -and @(Get-ChildItem -LiteralPath $dotStore -Filter '*.json' -File).Count -le 1) 'g6-single-element-array-no-extra-write'

    # ---- H1: plan.validation.status is gate evidence, not decoration.
    $stageUnavailable=[pscustomobject]@{frame=[pscustomobject]@{objective='Validation stage unavailable'};validation=[pscustomobject]@{status='unavailable';level='L3';required_roles=@('coder','tester','reviewer','security-reviewer')};dispatch_plan=[pscustomobject]@{workers=@('coder','tester','reviewer','security-reviewer');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $stageBundle=Invoke-OrchestrationDispatchPipeline $stageUnavailable $descriptor @{timestamp=$now}
    Assert-DP (@($stageBundle.bundle.contracts).Count -eq 4 -and [string]$stageBundle.bundle.completion_gate.status -eq 'unavailable' -and [string]$stageBundle.bundle.completion_gate.reason -eq 'validation-stage-unavailable') 'h1-stage-unavailable-promoted-to-gate'
    $stageVerdict=Test-OrchestrationDispatchCompletion $stageBundle.bundle @('coder','tester','reviewer','security-reviewer') @{store_dir=$store}
    Assert-DP (-not $stageVerdict.allowed -and $stageVerdict.status -eq 'blocked' -and $stageVerdict.reason -eq 'gate-unavailable' -and [string]$stageVerdict.gate_status -eq 'unavailable') 'h1-stage-unavailable-blocks-completion'
    Assert-DP (-not $stageVerdict.persistence.created -and -not $stageVerdict.persistence.attempted) 'h1-stage-unavailable-no-persistence'
    $stageMissing=[pscustomobject]@{frame=[pscustomobject]@{objective='Validation stage missing'};validation=[pscustomobject]@{level='L3';required_roles=@('coder','tester','reviewer','security-reviewer')};dispatch_plan=[pscustomobject]@{workers=@('coder');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $stageMissingBundle=Invoke-OrchestrationDispatchPipeline $stageMissing $descriptor @{timestamp=$now}
    Assert-DP ([string]$stageMissingBundle.bundle.completion_gate.status -eq 'unavailable' -and [string]$stageMissingBundle.bundle.completion_gate.reason -eq 'validation-stage-missing') 'h1-stage-missing-is-not-ok'
    $canaryStage=[pscustomobject]@{frame=[pscustomobject]@{objective='sk-SYNTHETICSECRET token=bad evil.com'};validation=[pscustomobject]@{status='sk-SYNTHETICSECRET token=bad';level='L3';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=@('coder');parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $canaryStageBundle=Invoke-OrchestrationDispatchPipeline $canaryStage @{task_id='sk-SYNTHETICSECRET'} @{timestamp=$now}
    Assert-DP ($canaryStageBundle.bundle_json -notmatch 'SYNTHETICSECRET|token=bad|evil\.com' -and [string]$canaryStageBundle.bundle.completion_gate.reason -eq 'validation-stage-unavailable') 'h1-canary-stage-status-sanitized'

    # ---- H2: a declared element is one indivisible unit, never flattened.
    $nested=New-Object System.Collections.ArrayList
    [void]$nested.Add(@('coder','tester'))
    $nestedPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Nested array element'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder','tester')};dispatch_plan=[pscustomobject]@{workers=$nested;parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $nestedBundle=Invoke-OrchestrationDispatchPipeline $nestedPlan $descriptor @{timestamp=$now}
    Assert-DP ($nestedBundle.status -in @('ok','degraded','oversized')) 'h2-nested-array-still-valid-bundle'
    Assert-DP (@($nestedBundle.bundle.contracts).Count -eq 0 -and $nestedBundle.bundle.rejected_count -eq 1 -and [string]$nestedBundle.bundle.rejected_roles[0].reason -eq 'role-not-declared-as-text') 'h2-nested-array-element-rejected'
    Assert-DP ($nestedBundle.bundle.plan_ref.declared_workers -eq 1 -and $nestedBundle.bundle.no_widen.workers_overflow -eq 0) 'h2-nested-array-declared-count-respected'
    $bigInner=@();for($i=0;$i -lt 500;$i++){$bigInner+=@("inner-$i")}
    $bigNested=New-Object System.Collections.ArrayList
    [void]$bigNested.Add($bigInner)
    $bigNestedPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Huge nested element'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=$bigNested;parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $bigNestedBundle=Invoke-OrchestrationDispatchPipeline $bigNestedPlan $descriptor @{timestamp=$now}
    Assert-DP ($bigNestedBundle.bounded -and @($bigNestedBundle.bundle.contracts).Count -eq 0 -and $bigNestedBundle.bundle_json -notmatch 'inner-\d+') 'h2-huge-nested-element-not-expanded'
    $emptyArrayEnumerable=New-Object DPEmptyArrayEnumerable 500
    $emptyArrayPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Empty array elements'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=(New-Object DPEmptyArrayEnumerable 500)};dispatch_plan=[pscustomobject]@{workers=$emptyArrayEnumerable;parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $emptyArrayBundle=Invoke-OrchestrationDispatchPipeline $emptyArrayPlan $descriptor @{timestamp=$now}
    Assert-DP ($emptyArrayBundle.status -ne 'error' -and $emptyArrayBundle.bounded) 'h2-empty-array-element-enumerable-does-not-throw'
    Assert-DP ($emptyArrayEnumerable.Produced -le 65 -and $emptyArrayBundle.bundle.rejected_count -eq 64 -and $emptyArrayBundle.bundle.plan_ref.declared_workers -eq 65) 'h2-empty-array-element-consumption-capped'
    Assert-DP ($emptyArrayBundle.bundle.completion_gate.unknown_required_roles -ge 64) 'h2-empty-array-required-roles-counted-as-unknown'
    $lyingList=New-Object DPLyingCountList (3,1000)
    $lyingPlan=[pscustomobject]@{frame=[pscustomobject]@{objective='Lying Count'};validation=[pscustomobject]@{status='ok';level='L2';required_roles=@('coder')};dispatch_plan=[pscustomobject]@{workers=$lyingList;parallel_ok=$false;escalations=@()};budget_reservation=[pscustomobject]@{validation_reserved=$true}}
    $lyingBundle=Invoke-OrchestrationDispatchPipeline $lyingPlan $descriptor @{timestamp=$now}
    Assert-DP ($lyingBundle.status -ne 'error' -and @($lyingBundle.bundle.contracts).Count -eq 0 -and $lyingBundle.bundle.rejected_count -eq 64) 'h2-lying-count-no-crash-no-fabricated-role'
    $lyingReasons=@($lyingBundle.bundle.rejected_roles | ForEach-Object {[string]$_.reason})
    Assert-DP (@($lyingReasons | Select-Object -Unique).Count -eq 2 -and $lyingReasons -contains 'role-not-in-allowlist' -and $lyingReasons -contains 'role-not-declared-as-text') 'h2-lying-count-typed-rejections-only'
    Assert-DP ($lyingBundle.bundle.plan_ref.declared_workers -eq 1000 -and $lyingBundle.bundle.no_widen.workers_overflow -eq 936 -and @($lyingBundle.bundle.rejected_roles).Count -le 16) 'h2-lying-count-declared-value-reported'

    # ---- H3: byte truncation never splits a surrogate pair.
    $pairInput=('a' * 61)+[char]::ConvertFromUtf32(0x1F600)+'zz'
    $pairCut=Get-DPTextByBytes $pairInput 64
    Assert-DP ($pairCut.Length -eq 61 -and (Get-JsonBytes $pairCut) -le 64 -and -not [char]::IsHighSurrogate($pairCut[$pairCut.Length-1])) 'h3-surrogate-pair-not-split'
    $pairFit=Get-DPTextByBytes $pairInput 66
    Assert-DP ($pairFit.Length -eq 64 -and (Get-JsonBytes $pairFit) -eq 66 -and $pairFit.Contains([char]::ConvertFromUtf32(0x1F600))) 'h3-surrogate-pair-kept-when-it-fits'
    $orphanInput=('a' * 61)+[char]0xD83D+'zz'
    $orphanCut=Get-DPTextByBytes $orphanInput 64
    Assert-DP ($orphanCut.Length -eq 61 -and (Get-JsonBytes $orphanCut) -le 64 -and -not [char]::IsHighSurrogate($orphanCut[$orphanCut.Length-1])) 'h3-orphan-high-surrogate-dropped'
    $pairDescriptor=@{task_id=$pairInput;read_scope=$bigEntries;write_scope=$bigEntries;acceptance_criteria=$bigEntries;prohibited_operations=$bigEntries;return_format=('f' * 300)}
    $pairBundle=Invoke-OrchestrationDispatchPipeline $rigor.plan $pairDescriptor @{timestamp=$now;max_bundle_bytes=512}
    $pairParsed=$pairBundle.bundle_json | ConvertFrom-Json -ErrorAction Stop
    Assert-DP ($pairBundle.status -eq 'oversized' -and $pairBundle.byte_length -le 512 -and (Get-JsonBytes ([string]$pairParsed.task_ref)) -le 64) 'h3-envelope-with-emoji-fits-cap'
    Assert-DP (-not [char]::IsHighSurrogate(([string]$pairParsed.task_ref)[([string]$pairParsed.task_ref).Length-1]) -and (Get-NormalizedJson $pairBundle.bundle) -ceq (Get-NormalizedJson $pairParsed)) 'h3-envelope-string-valid'

    # ---- H4: reported gate fields use a closed vocabulary and stay sanitized.
    $canaryGate=[pscustomobject]@{completion_gate=[pscustomobject]@{status='sk-SYNTHETICSECRET token=bad evil.com';level='L2';required_roles=@('coder','tester');unknown_required_roles=0}}
    $canaryVerdict=Test-OrchestrationDispatchCompletion $canaryGate @('coder','tester') @{store_dir=$store}
    Assert-DP (-not $canaryVerdict.allowed -and $canaryVerdict.reason -eq 'gate-unavailable') 'h4-canary-status-blocked'
    Assert-DP ((ConvertTo-Json -InputObject $canaryVerdict -Depth 6 -Compress) -notmatch 'SYNTHETICSECRET|token=bad|evil\.com') 'h4-canary-not-echoed'
    Assert-DP ([string]$canaryVerdict.gate_status -eq 'unavailable' -and [string]$canaryVerdict.gate_reason -eq 'gate-status-unavailable') 'h4-closed-vocabulary-unavailable'
    $missingGateVerdict=Test-OrchestrationDispatchCompletion ([pscustomobject]@{schema_version=1}) @('coder')
    Assert-DP ([string]$missingGateVerdict.gate_status -eq 'missing' -and [string]$missingGateVerdict.gate_reason -eq 'gate-unverifiable') 'h4-closed-vocabulary-missing'
    $invalidGateVerdict=Test-OrchestrationDispatchCompletion $noCounterBundle @('coder')
    Assert-DP ([string]$invalidGateVerdict.gate_status -eq 'invalid' -and [string]$invalidGateVerdict.gate_shape_error -eq 'gate-unknown-required-counter-missing') 'h4-closed-vocabulary-invalid'
    $canaryShapeVerdict=Test-OrchestrationDispatchCompletion ([pscustomobject]@{completion_gate=[pscustomobject]@{status='ok';level='sk-SYNTHETICSECRET token=bad';required_roles=@('coder');unknown_required_roles=0}}) @('coder')
    Assert-DP (-not $canaryShapeVerdict.allowed -and (ConvertTo-Json -InputObject $canaryShapeVerdict -Depth 6 -Compress) -notmatch 'SYNTHETICSECRET|token=bad') 'h4-canary-level-not-echoed'
    Assert-DP ([string]$allowedVerdict.gate_status -eq 'ok' -and $allowedVerdict.gate_verifiable) 'h4-normal-gate-status-ok'

    # ---- Kernel, preflight and capability flags are untouched by the whole suite.
    foreach($g in $guarded){
        $after=(Get-FileHash -LiteralPath (Join-Path $RepoRoot $g) -Algorithm SHA256).Hash
        Assert-DP ($after -eq $beforeHashes[$g]) ('no-mutation-' + $g)
    }
} finally {
    if($store -and (Test-Path -LiteralPath $store)){try{Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction SilentlyContinue}catch{}}
    if($dotStore -and (Test-Path -LiteralPath $dotStore)){try{Remove-Item -LiteralPath $dotStore -Recurse -Force -ErrorAction SilentlyContinue}catch{}}
}
Write-Output "PASS OrchestrationDispatchPipeline: $script:checks checks"