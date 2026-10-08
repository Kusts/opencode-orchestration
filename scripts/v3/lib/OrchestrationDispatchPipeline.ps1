<#
.SYNOPSIS
    Deterministic record-only dispatch pipeline (V3.1 Phase 38, slice 2).
.DESCRIPTION
    Consumes the Planner plan record produced by Invoke-OrchestrationPlannerLoop
    plus the caller-declared descriptor and emits a bounded dispatch bundle:
    one bounded worker contract per planned role, canonical sequencing, a
    reusable-evidence prefill (P35 plan section only) and a completion gate (P36).

    Record-only by construction: no spawn, no network, no kernel/flag mutation
    and never a widening of the plan (no extra worker and no parallelism the
    plan did not declare). The only library calls are the P36 completion gate
    and the P35 evidence writer; both are lazy dot-sourced behind Test-Path and
    both fail closed with a typed reason when unavailable. An optional
    additive Phase 5 hook (-ObjectiveStatus on
    Test-OrchestrationDispatchCompletion) appends a record-only next_move
    from the pure continuation controller without touching completion
    authority; absent or invalid input leaves the verdict byte-identical.

    Worker contract fields are derived from the plan record and the declared
    descriptor only, with this precedence: per-role descriptor override
    (descriptor.worker_contracts.<role>) -> descriptor field -> plan record
    field. First declaring source wins per field; a field that is declared but
    malformed is reported in contract.invalid_fields and never silently falls
    back to a wider source, while an explicitly empty list is a declared value
    (read-only worker contract). A field that cannot be derived is omitted and
    listed in contract.missing_fields with contract.incomplete = $true.

    Fail-closed gates: parallel_ok/validation_reserved must be a real boolean
    $true, a validation budget that is not provably reserved keeps the route to
    exactly one contract, a plan demanding an unknown required role can never
    complete, and completion evidence must declare its invalidation conditions.

    RESIDUAL LIMITATION (documented, no behavior change): the completion gate
    validates the SHAPE and internal consistency of plan.validation, not the
    authenticity of its provenance. This bundle is record-only evidence, never an
    independent authority: a caller that does not trust the plan producer must
    treat plan.record_only as unverified and re-derive the gate from its own
    trusted inputs. DONE/verified_pass authority stays with the kernel.
#>
[CmdletBinding()]
param()

# Closed role allowlist. A role outside it in a plan record is rejected
# fail-closed and never echoed beyond a len:prefix sanitized reference.
$script:DPRoleAllowlist=@('coder','tester','reviewer','security-reviewer','explorer','researcher','debugger','architect')
# Canonical dispatch order used for the sequential routing (parallel keeps it).
$script:DPRoleRank=@{explorer=0;researcher=1;coder=2;tester=3;reviewer=4;'security-reviewer'=5;debugger=6;architect=7}
$script:DPContractFields=@('TASK_ID','OBJECTIVE','READ_SCOPE','WRITE_SCOPE','ACCEPTANCE_CRITERIA','VALIDATION','PROHIBITED_OPERATIONS','RETURN_FORMAT','ESCALATION_CONDITIONS')
$script:DPDiscardOrder=@('escalations and free-text rationale','incomplete contract detail','evidence prefill detail','complete contract detail','replace with minimum valid envelope')
$script:DPJsonCap=8192
$script:DPMinByteCap=512
$script:DPConditionsMax=20
# P35 invalidation condition contract (mirrors New-OrchestrationEvidenceRecord):
# declared conditions are validated here and either transported whole or the
# persistence is refused; a partial condition set is never written.
$script:DPConditionFields=@{'source-changed'=@('type','paths');'criteria-changed'=@('type','hash');'base-revision'=@('type','require_same');'env-changed'=@('type','runtime','version');'ttl'=@('type','expires_at')}

function Test-DPObject { param($Value)
    return (($null -ne $Value) -and (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])))
}
function Test-DPHasKey { param($Object,[string]$Name)
    if(-not (Test-DPObject $Object)){return $false}
    if($Object -is [System.Collections.IDictionary]){return $Object.Contains($Name)}
    return ($null -ne $Object.PSObject.Properties[$Name])
}
function Read-DP { param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $p=$Object.PSObject.Properties[$Name]
    if($null -ne $p){return $p.Value}
    return $Default
}
# Raw declared value without pipeline enumeration. A direct return would turn a
# one-item array into its single element and an empty array into nothing, which
# would silently promote a non-boolean gate value into a boolean one.
function Get-DPKeyRaw { param($Object,[string]$Name)
    $raw=$null
    $present=$false
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){$raw=$Object[$Name];$present=$true}
    }elseif($null -ne $Object){
        $property=$Object.PSObject.Properties[$Name]
        if($property){$raw=$property.Value;$present=$true}
    }
    return [pscustomobject]@{present=$present;value=$raw}
}
# Same redaction profile as the planner loop (S1): secret keys, token= values,
# hosts and control characters. Representation only: never applied to a path
# or to an identifier before it is validated.
function Safe-DP { param($Value,[int]$Max=240)
    if($null -eq $Value){return $null}
    $s=[string]$Value
    $s=$s -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]' -replace '(?i)(token|secret|password|key)\s*[=:]\s*[^\s,;]+','$1=[redacted]' -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]' -replace '[\x00-\x1f]',' '
    $s=$s.Trim()
    if($s.Length -gt $Max){$s=$s.Substring(0,$Max)}
    return $s
}
function Unavailable-DP { param([string]$Reason)
    return [pscustomobject]@{status='unavailable';reason=(Safe-DP $Reason 80)}
}
# Strict integer: only real integer types count (a JSON number may arrive as
# Int64). Booleans, decimals, strings and objects are not integers here.
function Get-DPInt { param($Value)
    if($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]){return [int]$Value}
    return $null
}
# Strict boolean gate: only a real $true enables a gate; any other type or value
# is the conservative false. (A textual 'false' must never read as true.)
function Get-DPGateBool { param($Value)
    if($Value -is [bool]){return [bool]$Value}
    return $false
}
# Timestamps accept ISO text and DateTime/DateTimeOffset (PS 7 ConvertFrom-Json
# coerces ISO strings to DateTime, which must not lose the evidence created_at)
# and always normalize to ISO-8601 UTC.
function ConvertTo-DPStamp { param($Value,[int]$MaxLen=80)
    if($null -eq $Value){return $null}
    $stamp=$null
    if($Value -is [DateTimeOffset]){$stamp=([DateTimeOffset]$Value).UtcDateTime}
    elseif($Value -is [DateTime]){$stamp=([DateTime]$Value).ToUniversalTime()}
    elseif($Value -is [string]){
        $parsed=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return $null}
        $stamp=$parsed.UtcDateTime
    }else{return $null}
    $text=$stamp.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
    if($text.Length -gt $MaxLen){$text=$text.Substring(0,$MaxLen)}
    return $text
}
# Role identity against the closed allowlist. Ordinal comparison (PowerShell's
# -eq is culture aware and silently ignores NUL/control characters, which would
# accept "coder" + NUL as coder) and an explicit control-character refusal.
function Test-DPRoleIdentity { param($Text)
    if($null -eq $Text){return $false}
    $candidate=[string]$Text
    if($candidate.Length -eq 0){return $false}
    if($candidate -match '[\x00-\x1f]'){return $false}
    foreach($role in $script:DPRoleAllowlist){
        if([string]::Equals($candidate,[string]$role,[StringComparison]::Ordinal)){return $true}
    }
    return $false
}
function Get-DPFirstValue { param($Sources,[string]$Name)
    if($null -ne $Sources){foreach($s in $Sources){if(Test-DPObject $s){$v=Read-DP $s $Name $null;if($null -ne $v){return $v}}}}
    return $null
}
# Strict string field: any other type counts as not declared (fail closed).
function Get-DPText { param($Value,[int]$MaxLen=240)
    if($null -eq $Value){return $null}
    if($Value -isnot [string]){return $null}
    $t=Safe-DP $Value $MaxLen
    if([string]::IsNullOrWhiteSpace($t)){return $null}
    return $t
}
function Get-DPFirstText { param($Sources,[string[]]$Names,[int]$MaxLen=240)
    if($null -ne $Names){foreach($n in $Names){$t=Get-DPText (Get-DPFirstValue $Sources $n) $MaxLen;if($t){return $t}}}
    return $null
}
# Presence of a contract field: an explicitly empty list is a declared value,
# an empty string or $null is not.
function Test-DPValuePresent { param($Value)
    if($null -eq $Value){return $false}
    if($Value -is [string]){return -not [string]::IsNullOrWhiteSpace($Value)}
    return $true
}
# Resolves a declared list into a wrapper: $null when the declared value cannot
# be represented faithfully (dictionary, non-string item, blank item, over the
# item cap), otherwise an object whose value may be an explicitly empty array.
# The array lives inside the wrapper because a returned array would be
# enumerated by the pipeline (a one-item list would collapse to a scalar and an
# empty list would vanish entirely).
function Resolve-DPListValue { param($Value,[int]$MaxItems,[int]$MaxLen)
    if($null -eq $Value){return $null}
    if($Value -is [string]){$one=Safe-DP $Value $MaxLen;if($one){return [pscustomobject]@{value=@($one)}};return $null}
    if($Value -is [System.Collections.IDictionary]){return $null}
    if($Value -isnot [System.Collections.IEnumerable]){return $null}
    $out=@()
    foreach($item in $Value){
        if($item -isnot [string]){return $null}
        $t=Safe-DP $item $MaxLen
        if(-not $t){return $null}
        $out+=@($t)
        if($out.Count -gt $MaxItems){return $null}
    }
    return [pscustomobject]@{value=$out}
}
# Resolves a list field across sources: $null when absent everywhere, otherwise
# a result with status ok (value may be an explicitly empty array) or invalid
# (declared but unusable - never falls back to a wider source).
function Get-DPListField { param($Sources,[string[]]$Names,[int]$MaxItems,[int]$MaxLen)
    if($null -ne $Sources){foreach($s in $Sources){
        if(-not (Test-DPObject $s)){continue}
        if($null -ne $Names){foreach($n in $Names){
            if(-not (Test-DPHasKey $s $n)){continue}
            # Direct value access: a helper function would emit an explicitly
            # empty declared list as nothing at all.
            $raw=$null
            if($s -is [System.Collections.IDictionary]){$raw=$s[$n]}else{$property=$s.PSObject.Properties[$n];if($property){$raw=$property.Value}}
            $resolved=Resolve-DPListValue $raw $MaxItems $MaxLen
            if($null -eq $resolved){return [pscustomobject]@{status='invalid';value=$null}}
            return [pscustomobject]@{status='ok';value=$resolved.value}
        }}
    }}
    return $null
}
# Deterministic ordered map (sorted keys) for declared fingerprints. Fail
# closed: a source that cannot be represented faithfully inside the caps
# (too many entries, or a key/value that would be truncated) is not mapped at
# all, because a partial fingerprint set is worse than no evidence.
function ConvertTo-DPMap { param($Value,[int]$MaxItems=16,[int]$KeyLen=120,[int]$ValLen=64)
    if(-not (Test-DPObject $Value)){return $null}
    $rawNames=@()
    if($Value -is [System.Collections.IDictionary]){$rawNames=@($Value.Keys | ForEach-Object {[string]$_})}else{$rawNames=@($Value.PSObject.Properties | ForEach-Object {[string]$_.Name})}
    if($rawNames.Count -eq 0 -or $rawNames.Count -gt $MaxItems){return $null}
    $out=[ordered]@{}
    foreach($rawName in @($rawNames | Sort-Object)){
        $rawValue=Read-DP $Value $rawName $null
        if($null -ne $rawValue -and ($rawValue -isnot [string] -and $rawValue -isnot [ValueType])){return $null}
        $safeKey=Safe-DP $rawName $KeyLen
        # $safeKey/$safeValue, never $key/$value: PowerShell variable names are
        # case-insensitive, so $value would overwrite the $Value parameter.
        $safeValue=Safe-DP $rawValue $ValLen
        if(-not $safeKey -or $safeKey.Length -ne $rawName.Length){return $null}
        if($null -ne $rawValue){if($safeValue.Length -ne ([string]$rawValue).Length){return $null}}
        $out[$safeKey]=$safeValue
    }
    if($out.Count -eq 0){return $null}
    return $out
}
# Declared invalidation conditions (P35 contract). Returns a result with status
# absent/ok/invalid; invalid carries a typed reason and no value, so the caller
# refuses persistence instead of writing a record without conditions.
function ConvertTo-DPInvalidationConditions { param($Value)
    $none=[pscustomobject]@{status='absent';value=@();reason=''}
    if($null -eq $Value){return $none}
    $bad=[pscustomobject]@{status='invalid';value=$null;reason=''}
    if($Value -is [string] -or $Value -is [System.Collections.IDictionary] -or $Value -isnot [System.Collections.IEnumerable]){
        $bad.reason='conditions-not-a-list';return $bad
    }
    $out=@()
    $count=0
    foreach($condition in $Value){
        $count++
        if($count -gt $script:DPConditionsMax){$bad.reason='conditions-too-many';return $bad}
        if(-not (Test-DPObject $condition)){$bad.reason='condition-not-an-object';return $bad}
        $type=Get-DPText (Read-DP $condition 'type' $null) 40
        if(-not $type){$bad.reason='condition-type-missing';return $bad}
        if(-not $script:DPConditionFields.ContainsKey($type)){$bad.reason='unknown-invalidation-type';return $bad}
        $names=@()
        if($condition -is [System.Collections.IDictionary]){$names=@($condition.Keys | ForEach-Object {[string]$_})}else{$names=@($condition.PSObject.Properties | ForEach-Object {[string]$_.Name})}
        foreach($n in $names){if($n -notin $script:DPConditionFields[$type]){$bad.reason='unexpected-invalidation-field';return $bad}}
        $built=[ordered]@{type=$type}
        switch($type){
            'source-changed' {
                $pathsRaw=Read-DP $condition 'paths' $null
                if($null -eq $pathsRaw){$bad.reason='condition-paths-missing';return $bad}
                $paths=Resolve-DPListValue $pathsRaw 100 240
                if($null -eq $paths -or @($paths.value).Count -eq 0){$bad.reason='condition-paths-invalid';return $bad}
                $built['paths']=$paths.value
            }
            'criteria-changed' {
                $hash=Get-DPText (Read-DP $condition 'hash' $null) 128
                if(-not $hash){$bad.reason='condition-hash-missing';return $bad}
                $built['hash']=$hash
            }
            'base-revision' {
                $same=Read-DP $condition 'require_same' $null
                if($same -isnot [bool]){$bad.reason='condition-require_same-not-boolean';return $bad}
                $built['require_same']=[bool]$same
            }
            'env-changed' {
                $runtime=Get-DPText (Read-DP $condition 'runtime' $null) 80
                $version=Get-DPText (Read-DP $condition 'version' $null) 80
                if(-not $runtime -or -not $version){$bad.reason='condition-env-incomplete';return $bad}
                $built['runtime']=$runtime
                $built['version']=$version
            }
            'ttl' {
                $expires=ConvertTo-DPStamp (Read-DP $condition 'expires_at' $null) 80
                if(-not $expires){$bad.reason='condition-expires-at-invalid';return $bad}
                $built['expires_at']=$expires
            }
        }
        $out+=,[pscustomobject]$built
    }
    return [pscustomobject]@{status='ok';value=@($out);reason=''}
}
function Get-DPJsonBytes { param([string]$Json)
    if($null -eq $Json){return 0}
    return [Text.Encoding]::UTF8.GetByteCount($Json)
}
# Byte-bounded text: cuts on character boundaries, never mid multibyte sequence.
# Byte-bounded text: cuts on character boundaries and never splits a UTF-16
# surrogate pair (a pair is one 4-byte unit), and an orphan high surrogate is
# never emitted because that would produce an invalid string.
function Get-DPTextByBytes { param($Value,[int]$MaxBytes)
    if($null -eq $Value){return ''}
    $text=[string]$Value
    if($MaxBytes -lt 1){return ''}
    if((Get-DPJsonBytes $text) -le $MaxBytes){return $text}
    $builder=New-Object System.Text.StringBuilder
    $used=0
    $index=0
    while($index -lt $text.Length){
        $unit=[string]$text[$index]
        $step=1
        if([char]::IsHighSurrogate($text[$index])){
            if(-not (($index+1 -lt $text.Length) -and [char]::IsLowSurrogate($text[$index+1]))){break}
            $unit+=([string]$text[$index+1])
            $step=2
        }
        $size=(Get-DPJsonBytes $unit)
        if(($used+$size) -gt $MaxBytes){break}
        [void]$builder.Append($unit)
        $used+=$size
        $index+=$step
    }
    return $builder.ToString()
}
# Bounded consumption of a declared list. Each element is accumulated as one
# indivisible unit (an element that is itself a collection is never flattened),
# the consumption counter is independent of what is accumulated, and nothing is
# consumed beyond MaxItems (+1 element for uncountable enumerables, which only
# raises the overflow flag).
function Get-DPBoundedList { param($Object,[string]$Name,[int]$MaxItems=64)
    $result=[pscustomobject]@{status='absent';items=@();count=0;overflow=0;consumed=0}
    $key=Get-DPKeyRaw $Object $Name
    if((-not $key.present) -or ($null -eq $key.value)){return $result}
    $raw=$key.value
    if($raw -is [string]){
        $result.status='ok'
        $result.items=@($raw)
        $result.count=1
        $result.consumed=1
        return $result
    }
    if(($raw -is [System.Collections.IDictionary]) -or ($raw -isnot [System.Collections.IEnumerable])){
        $result.status='malformed'
        return $result
    }
    if($raw -is [System.Collections.ICollection]){
        $declaredCount=0
        try{$declaredCount=[int]$raw.Count}catch{$result.status='malformed';return $result}
        if($declaredCount -le 0){$result.status='empty';return $result}
        $take=[Math]::Min($declaredCount,$MaxItems)
        $items=New-Object System.Collections.ArrayList
        $consumed=0
        if($raw -is [System.Collections.IList]){
            for($i=0;$i -lt $take;$i++){
                $element=$null
                try{$element=$raw[$i]}catch{break}
                [void]$items.Add($element)
                $consumed++
            }
        }else{
            foreach($element in $raw){
                if($consumed -ge $take){break}
                [void]$items.Add($element)
                $consumed++
            }
        }
        $result.items=$items.ToArray()
        $result.consumed=$consumed
        $result.count=$declaredCount
        $result.overflow=[Math]::Max(0,$declaredCount-$consumed)
        $result.status=$(if($consumed -eq 0){'empty'}else{'ok'})
        return $result
    }
    # Uncountable enumerable: consume at most MaxItems+1 elements.
    $items=New-Object System.Collections.ArrayList
    $consumed=0
    $overflow=0
    foreach($element in $raw){
        if($consumed -ge $MaxItems){$overflow=1;break}
        [void]$items.Add($element)
        $consumed++
    }
    $result.items=$items.ToArray()
    $result.consumed=$consumed
    $result.count=$consumed+$overflow
    $result.overflow=$overflow
    $result.status=$(if($consumed -eq 0){'empty'}else{'ok'})
    return $result
}
function Test-DPIDText { param($Value)
    if($null -eq $Value){return $false}
    return ([string]$Value -match '^[A-Za-z0-9._:-]{1,128}$')
}

function Get-DPEvidenceSeed {
    <#
    .SYNOPSIS
        Declared evidence input for the optional post-completion persistence.
    .DESCRIPTION
        Only caller-declared values land here, plus two library-derived facts
        that are not claims: created_at (the bundle timestamp) and
        provenance.created_by (this pipeline). No raw evidence content is
        inlined; the store record references it by raw_ref. Declared
        invalidation conditions travel with the seed so the persisted record
        cannot outlive the sources it claims to describe.
    #>
    [CmdletBinding()] param($Descriptor,$Declared,[string]$Stamp)
    $d=$Descriptor;if(-not (Test-DPObject $d)){$d=@{}}
    $decl=$Declared;if(-not (Test-DPObject $decl)){$decl=@{}}
    $src=@($decl,$d)
    $envInput=Get-DPFirstValue $src 'environment'
    $resultInput=Get-DPFirstValue $src 'result'
    $conditionsKey=Get-DPKeyRaw $null 'invalidation_conditions'
    foreach($s in $src){if(Test-DPHasKey $s 'invalidation_conditions'){$conditionsKey=Get-DPKeyRaw $s 'invalidation_conditions';break}}
    $conditions=[pscustomobject]@{status='absent';value=@();reason=''}
    if($conditionsKey.present){$conditions=ConvertTo-DPInvalidationConditions $conditionsKey.value}
    $seed=[ordered]@{}
    $seed['task_id']=Get-DPFirstText $src @('task_id','task_ref') 128
    $seed['run_id']=Get-DPFirstText $src @('run_id') 128
    $seed['worker_id']=Get-DPFirstText $src @('worker_id') 128
    $seed['base_revision']=Get-DPFirstText $src @('base_revision') 128
    $seed['criteria_hash']=Get-DPFirstText $src @('criteria_hash') 128
    $seed['source_fingerprints']=ConvertTo-DPMap (Get-DPFirstValue $src 'source_fingerprints') 16 120 64
    $scopeField=Get-DPListField $src @('scope') 20 240
    $seed['scope']=$(if(($null -ne $scopeField) -and ($scopeField.status -eq 'ok') -and (@($scopeField.value).Count -gt 0)){$scopeField.value}else{$null})
    $seed['command']=Get-DPFirstText $src @('command') 240
    $seed['environment']=[ordered]@{runtime=(Get-DPFirstText @($envInput) @('runtime') 80);version=(Get-DPFirstText @($envInput) @('version') 80)}
    $seed['result']=[ordered]@{summary=(Get-DPFirstText @($resultInput) @('summary') 240);raw_ref=(Get-DPFirstText @($resultInput) @('raw_ref') 240)}
    $seed['provenance']=[ordered]@{created_by='orchestration-dispatch-pipeline';kernel_task_ref=(Get-DPFirstText $src @('kernel_task_ref') 128)}
    $seed['created_at']=ConvertTo-DPStamp $Stamp 80
    $seed['invalidation_conditions']=@($conditions.value)
    $seed['invalidation_conditions_status']=[string]$conditions.status
    $seed['invalidation_conditions_reason']=(Safe-DP $conditions.reason 80)
    return $seed
}

function Get-DPContract {
    <#
    .SYNOPSIS
        One bounded worker contract derived from the plan record and descriptor.
    #>
    [CmdletBinding()] param([string]$Role,$Plan,$Descriptor,[string]$Level,[string[]]$RequiredRoles)
    $d=$Descriptor;if(-not (Test-DPObject $d)){$d=@{}}
    $perRole=Read-DP $d 'worker_contracts' $null
    $roleInput=$null
    if(Test-DPObject $perRole){$candidate=Read-DP $perRole $Role $null;if(Test-DPObject $candidate){$roleInput=$candidate}}
    $src=@($roleInput,$d)
    $frame=Read-DP $Plan 'frame' $null
    $contract=Read-DP (Read-DP $Plan 'simplicity' $null) 'contract' $null
    $objective=Get-DPText (Read-DP $frame 'objective' $null) 300
    if(-not $objective){$objective=Get-DPFirstText $src @('objective','summary') 300}
    $validationText=$null
    if($Level -in @('L0','L1','L2','L3')){
        $roleList=@();if($null -ne $RequiredRoles){$roleList=@($RequiredRoles | Where-Object {$_})}
        $validationText=Safe-DP ('level='+$Level+';required_roles='+($roleList -join ',')) 160
    }
    # List fields: first declaring source wins, explicit empty list is a value,
    # declared-but-malformed never falls back to a wider source.
    $listFields=[ordered]@{}
    $listFields['READ_SCOPE']=Get-DPListField $src @('READ_SCOPE','read_scope') 12 200
    $listFields['WRITE_SCOPE']=Get-DPListField $src @('WRITE_SCOPE','write_scope') 12 200
    $listFields['ACCEPTANCE_CRITERIA']=Get-DPListField $src @('ACCEPTANCE_CRITERIA','acceptance_criteria') 12 200
    $listFields['PROHIBITED_OPERATIONS']=Get-DPListField $src @('prohibited_operations') 12 200
    $listFields['ESCALATION_CONDITIONS']=Get-DPListField $src @('escalation_conditions') 12 200
    # Plan-derived fallbacks only when the descriptor says nothing at all.
    if($null -eq $listFields['PROHIBITED_OPERATIONS']){
        $fromPlan=Resolve-DPListValue (Read-DP $contract 'non_goals' $null) 12 200
        if($null -ne $fromPlan){$listFields['PROHIBITED_OPERATIONS']=[pscustomobject]@{status='ok';value=$fromPlan.value}}
    }
    if($null -eq $listFields['ESCALATION_CONDITIONS']){
        $fromPlan=Resolve-DPListValue (Read-DP $Plan 'stop_condition' $null) 1 200
        if($null -ne $fromPlan){$listFields['ESCALATION_CONDITIONS']=[pscustomobject]@{status='ok';value=$fromPlan.value}}
    }
    $values=[ordered]@{}
    $values['TASK_ID']=Get-DPFirstText $src @('TASK_ID','task_id','task_ref') 128
    $values['OBJECTIVE']=$objective
    # Property access (never a function return) keeps an explicitly empty list
    # as an array instead of collapsing it through the pipeline.
    foreach($field in @('READ_SCOPE','WRITE_SCOPE','ACCEPTANCE_CRITERIA','PROHIBITED_OPERATIONS','ESCALATION_CONDITIONS')){
        if($null -ne $listFields[$field]){$values[$field]=$listFields[$field].value}
    }
    $values['VALIDATION']=$validationText
    $values['RETURN_FORMAT']=Get-DPFirstText $src @('RETURN_FORMAT','return_format') 300
    $missing=@()
    $invalid=@()
    foreach($field in $script:DPContractFields){
        $declared=$listFields[$field]
        if($null -ne $declared -and $declared.status -eq 'invalid'){$invalid+=@($field);continue}
        if(-not (Test-DPValuePresent $values[$field])){$missing+=@($field)}
    }
    $c=[ordered]@{}
    $c['role']=$Role
    $c['status']=$(if(($missing.Count -eq 0) -and ($invalid.Count -eq 0)){'ready'}else{'incomplete'})
    $c['incomplete']=(($missing.Count -gt 0) -or ($invalid.Count -gt 0))
    $c['missing_fields']=@($missing)
    $c['invalid_fields']=@($invalid)
    foreach($field in $script:DPContractFields){if(Test-DPValuePresent $values[$field]){$c[$field]=$values[$field]}}
    return $c
}

function ConvertTo-DPContractStub { param($Contract)
    if(-not ($Contract -is [System.Collections.IDictionary])){return $Contract}
    $count=@($Contract['missing_fields']).Count+@($Contract['invalid_fields']).Count
    $keep=@('role','status','incomplete')
    foreach($key in @($Contract.Keys)){if($key -notin $keep){[void]$Contract.Remove($key)}}
    $Contract['missing_count']=$count
    return $Contract
}

function Invoke-OrchestrationDispatchPipeline {
    <#
    .SYNOPSIS
        Builds the deterministic record-only dispatch bundle for a plan record.
    .DESCRIPTION
        Read-only over the plan record and the declared descriptor; the only
        write in this slice happens in Test-OrchestrationDispatchCompletion and
        only inside the caller-supplied store_dir path, used verbatim. Nothing
        is dispatched.
    #>
    [CmdletBinding()] param($PlanRecord,$Descriptor=$null,$Options=$null)
    try {
        $o=$Options;if($null -eq $o){$o=@{}}
        $d=$Descriptor;if(-not (Test-DPObject $d)){$d=@{}}
        $stampInput=Read-DP $o 'timestamp' $null
        $stamp=ConvertTo-DPStamp $stampInput 80
        $timestampNote=''
        if(-not $stamp){
            $stamp=ConvertTo-DPStamp ([DateTime]::UtcNow) 80
            $timestampNote='Invalid timestamp replaced with internal UTC.'
        }
        # The byte cap is a declared bound: it can only tighten the absolute cap.
        $cap=$script:DPJsonCap
        $capInput=Get-DPInt (Read-DP $o 'max_bundle_bytes' $null)
        if(($null -ne $capInput) -and ($capInput -ge $script:DPMinByteCap) -and ($capInput -lt $cap)){$cap=$capInput}
        # Accepts either the plan record itself or the planner loop envelope.
        $plan=$PlanRecord
        $inner=Read-DP $PlanRecord 'plan' $null
        if(Test-DPObject $inner){$plan=$inner}
        $dispatchPlan=Read-DP $plan 'dispatch_plan' $null
        $validationSection=Read-DP $plan 'validation' $null
        $fallbackReason=''
        if((-not (Test-DPObject $dispatchPlan)) -and (-not (Test-DPObject $validationSection))){
            # Conservative fallback in the S1 style: one coder contract, no fan-out.
            $plan=[ordered]@{
                frame=[ordered]@{objective='Insufficient plan detail; conservative dispatch.'}
                reuse=Unavailable-DP 'fallback-no-plan-record'
                simplicity=[pscustomobject]@{status='unavailable';reason='fallback-no-plan-record'}
                risk_uncertainty=[ordered]@{risk='unknown';uncertainty='high'}
                validation=[pscustomobject]@{status='unavailable';level='L3';required_roles=@('coder')}
                dispatch_plan=[ordered]@{workers=@('coder');parallel_ok=$false;escalations=@()}
                budget_reservation=[ordered]@{status='record-only';validation_reserved=$false}
                stop_condition='Stop when acceptance criteria are met; do not expand scope.'
            }
            $fallbackReason='plan-record-malformed'
        }
        $dispatchPlan=Read-DP $plan 'dispatch_plan' $null
        $validationSection=Read-DP $plan 'validation' $null
        # --- validation level and required roles (P36 section of the plan)
        $level=[string](Read-DP $validationSection 'level' '')
        $gateStatus='ok'
        $gateReason=''
        if($level -notin @('L0','L1','L2','L3')){$level='L3';$gateStatus='unavailable';$gateReason='validation-level-unavailable'}
        # The declared validation stage status is part of the gate evidence: a
        # stage that did not establish its level does not produce a usable gate,
        # even when the level and role names themselves look well formed.
        if(-not (Test-DPHasKey $validationSection 'status')){$gateStatus='unavailable';$gateReason='validation-stage-missing'}
        elseif([string](Read-DP $validationSection 'status' '') -ne 'ok'){$gateStatus='unavailable';$gateReason='validation-stage-unavailable'}
        $requiredRoles=@()
        $unknownRequired=0
        $roleCapDropped=0
        $roleList=Get-DPBoundedList $validationSection 'required_roles' 64
        if($roleList.overflow -gt 0){$unknownRequired+=[int]$roleList.overflow}
        foreach($r in $roleList.items){
            $t=Get-DPText $r 64
            if(-not $t){$unknownRequired++;continue}
            # Role identity is validated against the allowlist before sanitizing.
            if(-not (Test-DPRoleIdentity $r)){$unknownRequired++;continue}
            if($t -notin $requiredRoles){if($requiredRoles.Count -lt 16){$requiredRoles+=@($t)}else{$roleCapDropped++}}
        }
        $unknownRequired+=$roleCapDropped
        if($requiredRoles.Count -eq 0){
            $requiredRoles=@('coder','tester','reviewer','security-reviewer')
            if($gateStatus -eq 'ok'){$gateStatus='unavailable';$gateReason='validation-roles-unavailable'}
        }
        # --- declared workers, cardinality checked before any materialization
        $noWidenReasons=@()
        $workerList=Get-DPBoundedList $dispatchPlan 'workers' 64
        $declaredWorkers=@($workerList.items)
        $workersOverflow=[int]$workerList.overflow
        $workersTotal=[int]$workerList.count
        $workersMissing=$false
        $workersDeclaredEmpty=$false
        if($workerList.status -in @('absent','malformed')){$workersMissing=$true}
        elseif($workerList.status -eq 'empty'){$workersDeclaredEmpty=$true}
        if($workersMissing){
            $declaredWorkers=@('coder')
            $workersTotal=1
            if(-not $fallbackReason){$fallbackReason='plan-dispatch-workers-missing'}
        }elseif($workersDeclaredEmpty){
            # An explicitly empty worker list dispatches nothing: no-widen forbids
            # substituting a worker the plan did not declare.
            $noWidenReasons=@('workers-declared-empty')
        }
        if($workersOverflow -gt 0){$noWidenReasons+=@('declared-workers-cap-exceeded')}
        # --- budget gate: a real boolean $true only
        $budgetKey=Get-DPKeyRaw (Read-DP $plan 'budget_reservation' $null) 'validation_reserved'
        $budgetRaw=$null
        if($budgetKey.present){$budgetRaw=$budgetKey.value}
        $budgetReserved=Get-DPGateBool $budgetRaw
        if((-not $budgetReserved) -and ($null -ne $budgetRaw)){$noWidenReasons+=@('validation-reserved-not-boolean')}
        if(-not $budgetReserved){$noWidenReasons+=@('validation-budget-not-reserved')}
        # --- bounded worker contracts, closed role allowlist
        $contracts=@()
        $rejected=@()
        $rejectedTotal=0
        $seen=@{}
        $index=0
        foreach($raw in $declaredWorkers){
            $rawIndex=$index
            $index++
            if($raw -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$raw)){
                $rejectedTotal++
                if($rejected.Count -lt 16){$rejected+=@([ordered]@{index=$rawIndex;role='[rejected]';role_ref='len:0';reason='role-not-declared-as-text'})}
                $noWidenReasons+=@('role-not-declared-as-text')
                continue
            }
            # Validate the ORIGINAL identity first: sanitizing before the
            # allowlist check would accept "coder" + NUL as coder.
            $rawText=[string]$raw
            if(-not (Test-DPRoleIdentity $rawText)){
                $rejectedTotal++
                if($rejected.Count -lt 16){
                    $ref=Safe-DP $raw 16
                    $rejected+=@([ordered]@{index=$rawIndex;role='[rejected]';role_ref=([string]$rawText.Length+':'+$ref);reason='role-not-in-allowlist'})
                }
                $noWidenReasons+=@('role-not-in-allowlist')
                continue
            }
            if($seen.ContainsKey($rawText)){$noWidenReasons+=@('duplicate-role-collapsed');continue}
            $seen[$rawText]=$true
            $contracts+=@(Get-DPContract -Role $rawText -Plan $plan -Descriptor $d -Level $level -RequiredRoles $requiredRoles)
        }
        # No-widen: an unproven budget keeps exactly one contract (the first one
        # the plan declared); the withheld roles are reported, never dispatched.
        # withheld counts only real retention, never the normal route.
        $withheld=0
        if((-not $budgetReserved) -and ($contracts.Count -gt 1)){
            $withheld=$contracts.Count-1
            $contracts=@($contracts[0])
            $noWidenReasons+=@('minimum-route-budget-not-reserved')
        }
        # --- canonical, stable dispatch order (rank, then plan declaration index)
        $ranked=@()
        $orderIndex=0
        foreach($c in $contracts){
            $ranked+=,[pscustomobject]@{rank=[int]$script:DPRoleRank[[string]$c['role']];index=$orderIndex;contract=$c}
            $orderIndex++
        }
        $orderedContracts=@($ranked | Sort-Object -Property @{Expression={$_.rank}},@{Expression={$_.index}} | ForEach-Object {$_.contract})
        # --- sequencing: parallel only when the plan declared it (real boolean)
        $parallelKey=Get-DPKeyRaw $dispatchPlan 'parallel_ok'
        $parallelRaw=$null
        if($parallelKey.present){$parallelRaw=$parallelKey.value}
        $planParallel=Get-DPGateBool $parallelRaw
        $parallelReasons=@()
        if(-not $planParallel){$parallelReasons+=@('plan-declares-no-parallel')}
        if($parallelKey.present -and ($parallelRaw -isnot [bool])){$parallelReasons+=@('parallel-ok-not-boolean');$noWidenReasons+=@('parallel-ok-not-boolean')}
        if(-not $budgetReserved){$parallelReasons+=@('validation-budget-not-reserved')}
        if($orderedContracts.Count -le 1){$parallelReasons+=@('single-contract-no-fanout')}
        $parallel=($planParallel -and $budgetReserved -and ($orderedContracts.Count -gt 1))
        $sequencing=$(if($parallel){'parallel'}else{'sequential'})
        $sequencingNote=$(if($parallel){'Plan declared parallel_ok and every parallel gate held.'}else{'Sequential minimum route: '+($parallelReasons -join ', ')+'.'})
        # Reusable evidence prefill: plan.reuse only, never a new store query. A
        # prefill that was not requested is a declared expected state, carried by
        # the section status/reason instead of degrading the whole bundle.
        $reuse=Read-DP $plan 'reuse' $null
        $prefill=[ordered]@{status='unavailable';reason='';count=0;results=@()}
        if([string](Read-DP $reuse 'status' '') -eq 'ok'){
            $items=@()
            foreach($r in @(Read-DP $reuse 'results' @())){
                if($items.Count -ge 3){break}
                $id=Get-DPText (Read-DP $r 'evidence_id' $null) 64
                $ref=Get-DPText (Read-DP $r 'raw_ref' $null) 240
                $summary=Get-DPText (Read-DP $r 'summary' $null) 240
                if(-not $id -and -not $ref){continue}
                $byteLen=0
                $rawLen=Read-DP $r 'byte_len' $null
                $parsedLen=Get-DPInt $rawLen
                if($null -ne $parsedLen){$byteLen=$parsedLen}
                $items+=@([ordered]@{evidence_id=$id;raw_ref=$ref;byte_len=$byteLen;summary=$summary})
            }
            $prefill=[ordered]@{status='ok';reason='';count=@($items).Count;results=@($items)}
        }else{
            $prefill['reason']=$(if(Test-DPObject $reuse){'plan-reuse-not-ok'}else{'plan-reuse-section-missing'})
        }
        # --- escalations carried from the plan (bounded, sanitized)
        $escalations=@()
        foreach($e in @(Read-DP $dispatchPlan 'escalations' @())){
            if($escalations.Count -ge 5){break}
            $type=Get-DPText (Read-DP $e 'type' $null) 80
            if(-not $type){continue}
            $escalations+=@([ordered]@{type=$type;rationale=(Get-DPText (Read-DP $e 'rationale' $null) 240)})
        }
        # --- plan reference (risk drives the P36 effective level at completion)
        $risk=[string](Read-DP (Read-DP $plan 'risk_uncertainty' $null) 'risk' '')
        if($risk -notin @('low','medium','high','critical')){$risk='unknown'}
        $objectiveRaw=Read-DP (Read-DP $plan 'frame' $null) 'objective' $null
        $objectiveSafe=Get-DPText $objectiveRaw 500
        $objectiveRef=''
        if($objectiveSafe){$objectiveRef=([string]([string]$objectiveRaw).Length+':'+(Safe-DP $objectiveRaw 60))}
        $seed=Get-DPEvidenceSeed -Descriptor $d -Declared (Read-DP $o 'evidence' $null) -Stamp $stamp
        $noWidenReasons=@($noWidenReasons | Select-Object -Unique)
        $degraded=@()
        if($rejected.Count -gt 0){$degraded+=@('roles-rejected')}
        if($fallbackReason){$degraded+=@($fallbackReason)}
        if($workersDeclaredEmpty){$degraded+=@('workers-declared-empty')}
        if($gateStatus -ne 'ok'){$degraded+=@('completion-gate-degraded')}
        if($seed.invalidation_conditions_status -ne 'absent'){$degraded+=@('invalidation-conditions-declared')}
        $bundle=[ordered]@{
            schema_version=1
            status=$(if($degraded.Count -eq 0){'ok'}else{'degraded'})
            record_only=$true
            spawned=$false
            network_access=$false
            generated_at=$stamp
            timestamp_note=$timestampNote
            byte_cap=$cap
            plan_ref=[ordered]@{risk=$risk;objective_ref=$objectiveRef;validation_level=$level;declared_workers=$workersTotal;parallel_declared=$planParallel}
            sequencing=$sequencing
            sequencing_note=$sequencingNote
            no_widen=[ordered]@{enforced=$true;reasons=@($noWidenReasons);validation_reserved=$budgetReserved;declared_workers=$workersTotal;contract_count=@($orderedContracts).Count;withheld_roles=$withheld;workers_overflow=$workersOverflow}
            role_allowlist=@($script:DPRoleAllowlist)
            contracts=@($orderedContracts)
            rejected_roles=@($rejected)
            rejected_count=$rejectedTotal
            escalations=@($escalations)
            recommendation=(Get-DPText (Read-DP $dispatchPlan 'recommendation' $null) 160)
            evidence_prefill=[pscustomobject]$prefill
            completion_gate=[ordered]@{status=$gateStatus;reason=(Safe-DP $gateReason 80);level=$level;required_roles=@($requiredRoles);unknown_required_roles=$unknownRequired;source='plan.validation'}
            evidence_seed=[pscustomobject]$seed
            fallback_reason=(Safe-DP $fallbackReason 80)
            degraded_reasons=@($degraded)
            discard_applied=@()
        }
        # --- bounded serialization with a declared, ordered discard ladder
        $json=ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        $discarded=@()
        if((Get-DPJsonBytes $json) -gt $cap){
            $bundle['escalations']=@()
            $bundle['recommendation']=''
            $bundle['sequencing_note']=''
            $bundle['degraded_reasons']=@()
            $discarded+=@('escalations and free-text rationale')
            $bundle['discard_applied']=@($discarded)
            $json=ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        }
        if((Get-DPJsonBytes $json) -gt $cap){
            foreach($c in @($bundle['contracts'])){if($c['incomplete'] -eq $true){[void](ConvertTo-DPContractStub $c)}}
            $discarded+=@('incomplete contract detail')
            $bundle['discard_applied']=@($discarded)
            $json=ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        }
        if((Get-DPJsonBytes $json) -gt $cap){
            $bundle['evidence_prefill']=[pscustomobject]@{status='unavailable';reason='discarded-bundle-size';count=0;results=@()}
            $discarded+=@('evidence prefill detail')
            $bundle['discard_applied']=@($discarded)
            $json=ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        }
        if((Get-DPJsonBytes $json) -gt $cap){
            foreach($c in @($bundle['contracts'])){[void](ConvertTo-DPContractStub $c)}
            $bundle['evidence_seed']=[pscustomobject]@{status='unavailable';reason='discarded-bundle-size'}
            $bundle['rejected_roles']=@()
            $discarded+=@('complete contract detail')
            $bundle['discard_applied']=@($discarded)
            $json=ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        }
        $truncated=$false
        if((Get-DPJsonBytes $json) -gt $cap){
            # Last resort is a distinct minimum valid envelope, never a partial
            # string. task_ref is sized in BYTES (multibyte safe) and the result
            # is re-checked against the declared cap before returning.
            $truncated=$true
            $taskRef=''
            $declaredTaskId=Get-DPText (Read-DP $seed 'task_id' $null) 400
            if($declaredTaskId){$taskRef=([string]([string]$declaredTaskId).Length+':'+$declaredTaskId)}
            elseif($objectiveRef){$taskRef=$objectiveRef}
            $taskRef=Get-DPTextByBytes $taskRef 64
            $envelope=[ordered]@{schema_version=1;status='oversized';record_only=$true;truncated=$true;oversized=$true;task_ref=$taskRef;generated_at=$stamp;discard_applied=@($discarded+$script:DPDiscardOrder[4])}
            $bundle=$envelope
            $json=ConvertTo-Json -InputObject $bundle -Depth 4 -Compress
            # Deterministic reduction ladder: the minimum JSON must always fit.
            $reduction=0
            while(((Get-DPJsonBytes $json) -gt $cap) -and ($reduction -lt 4)){
                switch($reduction){
                    0 {$envelope['task_ref']=Get-DPTextByBytes $taskRef 24}
                    1 {$envelope['discard_applied']=@($script:DPDiscardOrder[4])}
                    2 {$envelope['task_ref']=''}
                    3 {$envelope['discard_applied']=@()}
                }
                $reduction++
                $json=ConvertTo-Json -InputObject $bundle -Depth 4 -Compress
            }
        }
        return [pscustomobject]@{
            status=$(if($truncated){'oversized'}else{[string]$bundle['status']})
            record_only=$true
            spawned=$false
            network_access=$false
            bundle=[pscustomobject]$bundle
            bundle_json=$json
            byte_length=(Get-DPJsonBytes $json)
            byte_cap=$cap
            bounded=((Get-DPJsonBytes $json) -le $cap)
            truncated=$truncated
            oversized=$truncated
            discard_order=@($script:DPDiscardOrder)
        }
    } catch {
        return [pscustomobject]@{status='error';record_only=$true;reason='dispatch-pipeline-failed';bundle=$null;bundle_json=$null;byte_length=0;byte_cap=$script:DPJsonCap;bounded=$true;truncated=$false;oversized=$false;discard_order=@($script:DPDiscardOrder)}
    }
}

function Test-OrchestrationDispatchCompletion {
    <#
    .SYNOPSIS
        Completion verdict for a dispatch bundle, reusing the P36 policy gate.
    .DESCRIPTION
        Completion is fail-closed: it is blocked when the bundle carries no
        verifiable gate, when the plan demanded an unknown required role, when
        an unknown role appears in CompletedRoles, when the P36 library is
        unavailable or when a required role is missing. Persists evidence via
        New-OrchestrationEvidenceRecord only when completion is allowed AND a
        store_dir was supplied AND the declared evidence input (including its
        invalidation conditions) is complete; the store_dir path is used
        verbatim, sanitization applies to the reported value only. The
        optional -ObjectiveStatus carries a post-settlement objective
        snapshot: when present and valid, the pure continuation controller
        verdict is attached as next_move (record-only, completion authority
        untouched); otherwise the verdict is byte-identical.
    #>
    [CmdletBinding()] param($Bundle,[string[]]$CompletedRoles,$Options=$null,$ObjectiveStatus=$null)
    $o=$Options;if($null -eq $o){$o=@{}}
    $b=$Bundle
    $inner=Read-DP $Bundle 'bundle' $null
    if(Test-DPObject $inner){$b=$inner}
    try {
        $gate=Read-DP $b 'completion_gate' $null
        $gateVerifiable=(Test-DPObject $gate)
        $gateDeclaredStatus=''
        $gateShapeError=''
        if($gateVerifiable){
            $gateDeclaredStatus=[string](Read-DP $gate 'status' '')
            $declaredLevel=[string](Read-DP $gate 'level' '')
            $declaredRoles=@(Read-DP $gate 'required_roles' @())
            if($declaredLevel -notin @('L0','L1','L2','L3')){$gateShapeError='gate-level-invalid'}
            elseif($declaredRoles.Count -eq 0){$gateShapeError='gate-required-roles-missing'}
            elseif($null -eq (Get-DPInt (Read-DP $gate 'unknown_required_roles' $null))){$gateShapeError='gate-unknown-required-counter-missing'}
        }
        $level=[string](Read-DP $gate 'level' '')
        if($level -notin @('L0','L1','L2','L3')){$level='L3'}
        $required=@()
        $requiredExtra=0
        foreach($r in @(Read-DP $gate 'required_roles' @())){
            $t=Get-DPText $r 64
            if(-not $t){continue}
            if($t -notin $required){if($required.Count -lt 16){$required+=@($t)}else{$requiredExtra++}}
        }
        if($required.Count -eq 0){$required=@('coder','tester','reviewer','security-reviewer')}
        # A plan that demanded a role outside the allowlist can never complete:
        # the count is part of the gate evidence, not an informational count.
        # An absent or non-integer counter is a SHAPE problem (gateShapeError),
        # not a missing gate: the two are reported with distinct vocabularies.
        $unknownRequired=0
        $unknownRequiredInt=Get-DPInt (Read-DP $gate 'unknown_required_roles' $null)
        if($null -ne $unknownRequiredInt){$unknownRequired=$unknownRequiredInt}
        # Completed roles: role identity is validated BEFORE sanitizing, and an
        # unknown role is never interpreted as complete.
        $known=@()
        $unknownCount=$requiredExtra
        foreach($r in @($CompletedRoles)){
            if($null -eq $r){$unknownCount++;continue}
            if(Test-DPRoleIdentity $r){$rawText=[string]$r;if($rawText -notin $known){$known+=@($rawText)}}else{$unknownCount++}
        }
        $missing=@()
        foreach($r in $required){if(($r -notin $known) -and ($r -notin $missing)){$missing+=@($r)}}
        # --- P36 completion gate (lazy, Test-Path guarded)
        $policyVerdict=$null
        $gateStatus='ok'
        $gateReason=''
        $valLib=Join-Path $PSScriptRoot 'OrchestrationValidationPolicy.ps1'
        if(-not (Test-Path -LiteralPath $valLib)){
            $gateStatus='unavailable'
            $gateReason='validation-library-unavailable'
        } else {
            try {
                . $valLib
                $risk=[string](Read-DP (Read-DP $b 'plan_ref' $null) 'risk' '')
                if($risk -notin @('low','medium','high','critical')){$risk=''}
                $policyVerdict=Test-OrchestrationCompletionPolicy -Level $level -CompletedRoles $known -Descriptor @{risk=$risk} -Policy (Read-DP $o 'validation_policy' $null)
                if($null -eq $policyVerdict -or $null -eq $policyVerdict.allowed){throw 'bad completion shape'}
            } catch {
                $gateStatus='unavailable'
                $gateReason='completion-policy-stage-failed'
                $policyVerdict=$null
            }
        }
        $effective=$level
        if($null -ne $policyVerdict -and [string](Read-DP $policyVerdict 'effective_level' '') -in @('L0','L1','L2','L3')){$effective=[string](Read-DP $policyVerdict 'effective_level' '')}
        if($null -ne $policyVerdict){
            foreach($r in @(Read-DP $policyVerdict 'missing_roles' @())){
                $t=Get-DPText $r 64
                if($t -and ($t -notin $missing)){$missing+=@($t)}
            }
        }
        $allowed=$false
        $reason=''
        if(-not $gateVerifiable){$reason='gate-unverifiable'}
        elseif($gateShapeError){$reason='gate-unverifiable'}
        elseif($gateDeclaredStatus -ne 'ok'){$reason='gate-unavailable'}
        elseif($unknownRequired -gt 0){$reason='unknown-required-role'}
        elseif($unknownCount -gt 0){$reason='unknown-completed-role'}
        elseif($gateStatus -ne 'ok'){$reason=$gateReason}
        elseif($missing.Count -gt 0){$reason='missing-roles'}
        else{$allowed=[bool]$policyVerdict.allowed;if(-not $allowed){$reason='policy-denied'}}
        # --- declared evidence input (bundle seed overridden by -Options.evidence)
        $seed=Read-DP $b 'evidence_seed' $null
        $src=@()
        $declared=Read-DP $o 'evidence' $null
        if(Test-DPObject $declared){$src+=@($declared)}
        if(Test-DPObject $seed){$src+=@($seed)}
        $envInput=Get-DPFirstValue $src 'environment'
        $resultInput=Get-DPFirstValue $src 'result'
        $provInput=Get-DPFirstValue $src 'provenance'
        $conditions=[pscustomobject]@{status='absent';value=@();reason=''}
        $conditionsHolder=$null
        foreach($s in $src){if(Test-DPHasKey $s 'invalidation_conditions'){$conditionsHolder=$s;break}}
        if($null -ne $conditionsHolder){
            $conditions=ConvertTo-DPInvalidationConditions (Get-DPKeyRaw $conditionsHolder 'invalidation_conditions').value
            # A seed that already recorded an unusable condition set must not be
            # downgraded here by re-parsing its (empty) value.
            if(($conditions.status -eq 'ok') -and (@($conditions.value).Count -eq 0) -and (Test-DPHasKey $conditionsHolder 'invalidation_conditions_status')){
                if([string](Read-DP $conditionsHolder 'invalidation_conditions_status' '') -eq 'invalid'){
                    $conditions=[pscustomobject]@{status='invalid';value=$null;reason=(Get-DPText (Read-DP $conditionsHolder 'invalidation_conditions_reason' $null) 80)}
                }
            }
        }
        $evidenceInput=[ordered]@{}
        $evidenceInput['task_id']=Get-DPFirstText $src @('task_id','task_ref') 128
        $evidenceInput['run_id']=Get-DPFirstText $src @('run_id') 128
        $evidenceInput['worker_id']=Get-DPFirstText $src @('worker_id') 128
        $evidenceInput['base_revision']=Get-DPFirstText $src @('base_revision') 128
        $evidenceInput['criteria_hash']=Get-DPFirstText $src @('criteria_hash') 128
        $evidenceInput['source_fingerprints']=ConvertTo-DPMap (Get-DPFirstValue $src 'source_fingerprints') 16 120 64
        $evidenceScope=Get-DPListField $src @('scope') 20 240
        $evidenceInput['scope']=$(if(($null -ne $evidenceScope) -and ($evidenceScope.status -eq 'ok') -and (@($evidenceScope.value).Count -gt 0)){$evidenceScope.value}else{$null})
        $evidenceInput['command']=Get-DPFirstText $src @('command') 240
        $evidenceInput['environment']=[ordered]@{runtime=(Get-DPFirstText @($envInput) @('runtime') 80);version=(Get-DPFirstText @($envInput) @('version') 80)}
        $evidenceInput['result']=[ordered]@{summary=(Get-DPFirstText @($resultInput) @('summary') 240);raw_ref=(Get-DPFirstText @($resultInput) @('raw_ref') 240)}
        $evidenceInput['provenance']=[ordered]@{created_by=(Get-DPFirstText @($provInput) @('created_by') 64);kernel_task_ref=(Get-DPFirstText @($provInput) @('kernel_task_ref') 128)}
        $createdAt=ConvertTo-DPStamp (Get-DPFirstValue $src 'created_at') 80
        if(-not $createdAt){$createdAt=ConvertTo-DPStamp (Read-DP $o 'timestamp' $null) 80}
        $evidenceInput['created_at']=$createdAt
        $evidenceInput['invalidation_conditions']=@($conditions.value)
        # Raw evidence content only when the caller declares it here (never inlined by the bundle).
        $rawContent=Get-DPFirstText @($resultInput) @('raw_content') 4096
        if($rawContent){$evidenceInput['result']['raw_content']=$rawContent}
        $missingFields=@()
        $invalidFields=@()
        foreach($field in @('task_id','run_id','worker_id')){
            $value=Read-DP $evidenceInput $field $null
            if($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)){$missingFields+=@($field)}
            elseif(-not (Test-DPIDText $value)){$invalidFields+=@($field)}
        }
        foreach($field in @('base_revision','command','created_at')){
            $value=Read-DP $evidenceInput $field $null
            if($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)){$missingFields+=@($field)}
        }
        foreach($field in @('source_fingerprints','scope','environment','result')){
            if($null -eq (Read-DP $evidenceInput $field $null)){$missingFields+=@($field)}
        }
        if(-not (Get-DPFirstText @($evidenceInput['environment']) @('runtime') 80)){$invalidFields+=@('environment.runtime')}
        if(-not (Get-DPFirstText @($evidenceInput['provenance']) @('created_by') 64)){$missingFields+=@('provenance.created_by')}
        if(-not (Get-DPFirstText @($evidenceInput['provenance']) @('kernel_task_ref') 128)){$missingFields+=@('provenance.kernel_task_ref')}
        if($conditions.status -eq 'invalid'){$invalidFields+=@('invalidation_conditions')}
        elseif(@($conditions.value).Count -eq 0){$missingFields+=@('invalidation_conditions')}
        $missingFields=@($missingFields | Sort-Object -Unique)
        $invalidFields=@($invalidFields | Sort-Object -Unique)
        # --- optional persistence: the caller path is used verbatim; only the
        # reported representation is sanitized. The declared value is read
        # without pipeline enumeration so an array can never arrive as a string.
        $storeKey=Get-DPKeyRaw $o 'store_dir'
        $storeRaw=$null
        if($storeKey.present){$storeRaw=$storeKey.value}
        $storePath=$null
        $storeDisplay=''
        $storeProblem=''
        if($null -ne $storeRaw){
            if($storeRaw -isnot [string]){$storeProblem='store-dir-not-a-string'}
            elseif([string]::IsNullOrWhiteSpace($storeRaw)){$storeProblem='store-dir-empty'}
            elseif(([string]$storeRaw).Length -gt 400){$storeProblem='store-dir-too-long'}
            elseif(([string]$storeRaw) -match '[\x00-\x1f]'){$storeProblem='store-dir-control-character'}
            else{
                $storePath=[string]$storeRaw
                $storeDisplay=Safe-DP $storeRaw 400
                if(Test-Path -LiteralPath $storePath -PathType Leaf){$storeProblem='store-dir-not-a-directory'}
            }
        }
        $persistence=[ordered]@{attempted=$false;created=$false;reason='';evidence_id='';store_declared=($null -ne $storeRaw);store_dir_display=$storeDisplay}
        if(-not $allowed){$persistence['reason']=$(if($reason){$reason}else{'completion-not-allowed'})}
        elseif($storeProblem){$persistence['reason']=$storeProblem}
        elseif(-not $persistence['store_declared']){$persistence['reason']='store-dir-not-provided'}
        elseif($missingFields.Count -gt 0){$persistence['reason']='incomplete-evidence-input'}
        elseif($invalidFields.Count -gt 0){$persistence['reason']='invalid-evidence-input'}
        else{
            $storeLib=Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1'
            if(-not (Test-Path -LiteralPath $storeLib)){
                $persistence['reason']='evidence-store-library-unavailable'
            } else {
                try {
                    . $storeLib
                    $persistence['attempted']=$true
                    $written=New-OrchestrationEvidenceRecord -Evidence ([pscustomobject]$evidenceInput) -StoreDir $storePath
                    $persistence['created']=[bool]$written.created
                    $persistence['reason']=(Get-DPText $written.reason 80)
                    $persistence['evidence_id']=(Get-DPFirstText @($written.record) @('evidence_id') 64)
                } catch {
                    $persistence['attempted']=$true
                    $persistence['reason']='evidence-store-stage-failed'
                }
            }
        }
        $verdict=[ordered]@{
            schema_version=1
            status=$(if($allowed){'allowed'}else{'blocked'})
            allowed=$allowed
            reason=(Safe-DP $reason 80)
            record_only=$true
            gate_status=$(if(-not $gateVerifiable){'missing'}elseif($gateShapeError){'invalid'}elseif($gateDeclaredStatus -eq 'ok'){'ok'}else{'unavailable'})
            gate_reason=$(if(-not $gateVerifiable){'gate-unverifiable'}elseif($gateShapeError){$gateShapeError}elseif($gateDeclaredStatus -ne 'ok'){'gate-status-unavailable'}else{(Safe-DP $gateReason 80)})
            gate_verifiable=($gateVerifiable -and (-not $gateShapeError))
            gate_shape_error=(Safe-DP $gateShapeError 48)
            effective_level=$effective
            required_roles=@($required)
            unknown_required_roles=$unknownRequired
            completed_roles=@($known)
            unknown_completed_roles=$unknownCount
            missing_roles=@($missing)
            completion_policy=$(if($null -ne $policyVerdict){[pscustomobject]@{allowed=[bool]$policyVerdict.allowed;missing_roles=@(Read-DP $policyVerdict 'missing_roles' @());effective_level=(Safe-DP (Read-DP $policyVerdict 'effective_level' '') 8)}}else{Unavailable-DP 'completion-policy-unavailable'})
            evidence_input=[pscustomobject]@{complete=($missingFields.Count -eq 0 -and $invalidFields.Count -eq 0);missing_fields=@($missingFields);invalid_fields=@($invalidFields);invalidation_conditions_status=[string]$conditions.status;invalidation_conditions_reason=(Safe-DP $conditions.reason 80);invalidation_conditions_count=@($conditions.value).Count}
            persistence=[pscustomobject]$persistence
            generated_at=(Get-DPFirstText @($b) @('generated_at') 80)
        }
        # --- Phase 5 additive hook (TDR-F5-03): optional post-settlement
        # next-move annotation. Present and valid -ObjectiveStatus attaches
        # the pure controller verdict as next_move. Absent, non-object,
        # invalid, unavailable or failing input leaves the verdict
        # byte-identical: allowed/reason authority is never touched here.
        $nextMove=$null
        try {
            if (Test-DPObject $ObjectiveStatus) {
                $ocLib=Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1'
                if (Test-Path -LiteralPath $ocLib) {
                    . $ocLib
                    $ocStatusOk=$false
                    try { $ocStatusOk=[bool](Test-OrchestrationObjectiveStatus -Status $ObjectiveStatus) } catch { $ocStatusOk=$false }
                    if ($ocStatusOk) {
                        try {
                            $ocMove=Get-OrchestrationNextMove -Status $ObjectiveStatus
                            if (($null -ne $ocMove) -and (-not [string]::IsNullOrWhiteSpace([string]$ocMove.move))) { $nextMove=$ocMove }
                        } catch { $nextMove=$null }
                    }
                }
            }
        } catch { $nextMove=$null }
        if ($null -ne $nextMove) { $verdict['next_move']=$nextMove }
        return [pscustomobject]$verdict
    } catch {
        return [pscustomobject]@{schema_version=1;status='blocked';allowed=$false;reason='dispatch-completion-failed';record_only=$true;gate_status='unavailable';gate_reason='dispatch-completion-failed';gate_verifiable=$false;effective_level='L3';required_roles=@();unknown_required_roles=0;completed_roles=@();unknown_completed_roles=0;missing_roles=@();completion_policy=(Unavailable-DP 'dispatch-completion-failed');evidence_input=[pscustomobject]@{complete=$false;missing_fields=@();invalid_fields=@('dispatch-completion-failed');invalidation_conditions_status='unknown';invalidation_conditions_reason='';invalidation_conditions_count=0};persistence=[pscustomobject]@{attempted=$false;created=$false;reason='dispatch-completion-failed';evidence_id='';store_declared=$false;store_dir_display=''};generated_at='';gate_shape_error='dispatch-completion-failed'}
    }
}