[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1')
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$registryPath=Join-Path $repoRoot 'source\registry\v2-native-capabilities.json'
$registry=ConvertFrom-Json ([IO.File]::ReadAllText($registryPath))
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}

$tempDir=Join-Path $env:TEMP ('v2-native-gating-'+[Guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($tempDir)
try {

# ---------- helpers (test side only; the library never writes) ----------
function New-EvidenceFile {
    param([string]$Name,[object[]]$Records)
    $path=Join-Path $script:tempDir $Name
    $doc=[ordered]@{schema_version=1;runtime='v2';pin='2.0.18';records=@($Records)}
    [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $doc -Depth 20),[Text.Encoding]::UTF8)
    return $path
}
function New-ProvenRecord {
    param([string]$FeatureId,[string]$Scenario,[hashtable]$Override=@{},[string]$DigestOverride='')
    $record=[ordered]@{feature_id=$FeatureId;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$Scenario;verified_at='2026-10-02T12:00:00Z';verified_by='livehook-v2.tests.ps1'}
    foreach($key in $Override.Keys){if($key -cne 'record_hash'){$record[$key]=$Override[$key]}}
    $hash=Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$record)
    if($DigestOverride){$hash=$DigestOverride}
    if(-not $hash){$hash=('0'*64)}
    $record['record_hash']=$hash
    return [pscustomobject]$record
}
function Copy-Registry {param($Source);return (ConvertFrom-Json (ConvertTo-Json $Source -Depth 20 -Compress))}

# ---------- R1: every candidate is declared, hold-unproven, narrowing-only, with fallback ----------
$expectedFeatures=@('session-hierarchy-provenance','session-permission-narrowing','experimental-policies-hard-deny','native-step-limits','background-subagents-bounded','plugin-storage-index','snapshots-auxiliary','durable-event-log-replay')
$declared=@($registry.features.PSObject.Properties|ForEach-Object{[string]$_.Name}|Sort-Object)
Assert-That (($declared -join ',') -ceq (($expectedFeatures|Sort-Object) -join ',')) 'registry declares exactly the plan 17 candidates'
$holdCount=0;$fallbackCount=0;$impactOk=$true
foreach($name in $expectedFeatures){
    $entry=$registry.features.PSObject.Properties[$name].Value
    if($entry.status -eq 'hold-unproven'){$holdCount++}
    if([string]$entry.feature_id -ceq $name -and [string]$entry.required_evidence.type -ceq 'exact-binary-live' -and [string]$entry.required_evidence.runtime -ceq 'v2' -and [string]$entry.required_evidence.pin -ceq '2.0.18'){$holdCount++}
    if([string]$entry.required_evidence.scenario -match '^[a-z0-9][a-z0-9-]{2,63}$'){$fallbackCount++}
    if([string]$entry.v1_fallback.mode -in @('none','fresh-session','kernel-side-equivalent')){$fallbackCount++}
    if([string]$entry.authority_impact -notin @('none','narrowing')){$impactOk=$false}
    if($entry.PSObject.Properties.Name -contains 'enabled'){$impactOk=$false}
}
Assert-That ($holdCount -eq ($expectedFeatures.Count*2)) 'every candidate is hold-unproven with exact-binary-live/v2/2.0.18 requirements'
Assert-That ($fallbackCount -eq ($expectedFeatures.Count*2)) 'every candidate declares a scenario and a v1_fallback.mode from the closed enum'
Assert-That $impactOk 'authority_impact is none/narrowing only and no candidate carries an enabled key'
Assert-That ($registry.runtime -ceq 'v2' -and $registry.pin -ceq '2.0.18' -and $registry.PSObject.Properties.Name -notcontains 'enabled') 'registry declares no global activation switch'
Assert-That ([bool]$registry.evidence_contract.append_only -and [string]$registry.evidence_contract.hash_algorithm -ceq 'sha256-canonical-json') 'evidence contract declares append-only sha256-canonical-json'
Assert-That ($registry.evidence_contract.registry_path -ceq 'evidence/v3.1/runtime-reliability/v2-native-evidence.json') 'evidence contract declares the append-only registry path'

# ---------- R2: absent evidence registry leaves every candidate NOT_PROVEN ----------
$absentEvidence=Join-Path $tempDir 'does-not-exist.json'
foreach($name in $expectedFeatures){
    $result=Get-OrchestrationV2NativeFeature -feature_id $name -evidence_registry_path $absentEvidence
    Assert-That ((-not $result.enabled) -and $result.status -eq 'not-proven' -and $result.reason -eq 'evidence-registry-missing') ("absent evidence registry: " + $name + " is NOT_PROVEN")
    Assert-That ($result.evidence -eq $null -and $result.v1_fallback_mode -in @('none','fresh-session','kernel-side-equivalent') -and $result.authority_impact -in @('none','narrowing')) ("absent evidence registry: " + $name + " surfaces fallback and narrowing-only impact")
}
$defaultRun=Get-OrchestrationV2NativeFeature -feature_id 'session-hierarchy-provenance'
Assert-That ((-not $defaultRun.enabled) -and $defaultRun.reason -eq 'evidence-registry-missing') 'shipped evidence registry absent by default: nothing is enabled'
$allAbsent=@(Get-OrchestrationV2NativeFeatures)
Assert-That ($allAbsent.Count -eq $expectedFeatures.Count -and @($allAbsent|Where-Object{$_.enabled -or $_.status -ne 'not-proven'}).Count -eq 0) 'bulk resolution with no evidence enables nothing'

# ---------- R2: a valid record enables exactly that feature (data-driven) ----------
$target='session-hierarchy-provenance'
$scenario=[string]$registry.features.PSObject.Properties[$target].Value.required_evidence.scenario
$validPath=New-EvidenceFile -Name 'valid.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario))
$enabled=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $validPath
Assert-That ($enabled.enabled -and $enabled.status -eq 'enabled' -and $enabled.reason -eq 'exact-binary-evidence-verified') 'valid exact-binary record enables the named feature'
Assert-That ($enabled.evidence.verified_at -eq '2026-10-02T12:00:00.0000000Z' -and $enabled.evidence.verified_by -eq 'livehook-v2.tests.ps1' -and $enabled.evidence.record_hash -match '^[a-f0-9]{64}$') 'enabled result carries normalized bounded evidence'
Assert-That ($enabled.declared_status -eq 'hold-unproven' -and $enabled.v1_fallback_mode -eq 'kernel-side-equivalent' -and $enabled.authority_impact -eq 'none') 'declaration stays hold-unproven and v1_fallback is surfaced for the caller'
$otherStillNot=Get-OrchestrationV2NativeFeature -feature_id 'native-step-limits' -evidence_registry_path $validPath
Assert-That ((-not $otherStillNot.enabled) -and $otherStillNot.reason -eq 'evidence-not-found') 'a record for one feature never enables another'
$bulk=@(Get-OrchestrationV2NativeFeatures -evidence_registry_path $validPath)
Assert-That ($bulk.Count -eq $expectedFeatures.Count -and @($bulk|Where-Object{$_.enabled}).Count -eq 1 -and $bulk[0].feature_id -eq 'background-subagents-bounded') 'bulk resolution enables exactly the proven candidate in a stable order'

# ---------- R2: every divergence fails closed with its own structured reason ----------
function Assert-NotProven {
    param([string]$Name,[string]$Reason,[object[]]$Records,[string]$Label)
    $path=New-EvidenceFile -Name $Name -Records $Records
    $result=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $path
    Assert-That ((-not $result.enabled) -and $result.status -eq 'not-proven' -and $result.reason -eq $Reason) ("$Label => expected " + $Reason + ', got ' + $result.reason)
    return $result
}
[void](Assert-NotProven -Name 'pin.json' -Reason 'evidence-pin-mismatch' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{pin='2.0.19'})) -Label 'record proven against another pin')
[void](Assert-NotProven -Name 'scenario.json' -Reason 'evidence-scenario-mismatch' -Records @((New-ProvenRecord -FeatureId $target -Scenario 'some-other-scenario')) -Label 'record proven under another scenario')
[void](Assert-NotProven -Name 'runtime.json' -Reason 'evidence-runtime-mismatch' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{runtime='v1'})) -Label 'record proven on another runtime')
[void](Assert-NotProven -Name 'type.json' -Reason 'evidence-type-mismatch' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{type='synthetic-mock'})) -Label 'record not proven on the exact binary')
[void](Assert-NotProven -Name 'stamp.json' -Reason 'evidence-verified-at-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='yesterday'})) -Label 'unparsable verified_at')
[void](Assert-NotProven -Name 'verifier.json' -Reason 'evidence-verifier-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_by='sk-SYNTHETICSECRET token=abc'})) -Label 'verifier outside the closed charset')
[void](Assert-NotProven -Name 'hashlen.json' -Reason 'evidence-hash-format-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -DigestOverride 'abc')) -Label 'digest truncated')
$upperDigestPath=New-EvidenceFile -Name 'hashcase.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -DigestOverride ((Get-OrchestrationV2NativeEvidenceHash ([pscustomobject](New-ProvenRecord -FeatureId $target -Scenario $scenario))).ToUpperInvariant())))
$upperDigestResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $upperDigestPath
Assert-That ($upperDigestResult.enabled -and $upperDigestResult.evidence.record_hash -match '^[0-9a-f]{64}$') 'uppercase hex digest of the same content verifies and is emitted normalized'

# R2/R3: a tampered record body no longer matches its own declared digest
$tampered=New-ProvenRecord -FeatureId $target -Scenario $scenario
$tampered.verified_by='someone-else.tests.ps1'
$tamperedPath=New-EvidenceFile -Name 'tampered.json' -Records @($tampered)
$tamperedResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $tamperedPath
Assert-That ((-not $tamperedResult.enabled) -and $tamperedResult.reason -eq 'evidence-hash-mismatch') 'edited record body fails the declared digest'

# a record for an undeclared feature never satisfies the query
$foreign=New-EvidenceFile -Name 'foreign.json' -Records @((New-ProvenRecord -FeatureId 'not-a-candidate' -Scenario $scenario))
$foreignResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $foreign
Assert-That ((-not $foreignResult.enabled) -and $foreignResult.reason -eq 'evidence-not-found') 'record for an undeclared feature proves nothing'

# two competing records for one feature are ambiguous, never "newest wins"
$duplicate=New-EvidenceFile -Name 'duplicate.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario),(New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-03T09:00:00Z'}))
$duplicateResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $duplicate
Assert-That ((-not $duplicateResult.enabled) -and $duplicateResult.reason -eq 'evidence-ambiguous') 'two records for one feature stay fail-closed'

# a non-string pin is a shape failure, never a coerced string
$coerced=New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{pin=2.0}
$coerced.PSObject.Properties['pin'].Value=@(2,0)
$coercedPath=New-EvidenceFile -Name 'coerced.json' -Records @($coerced)
$coercedResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $coercedPath
Assert-That ((-not $coercedResult.enabled) -and $coercedResult.reason -eq 'evidence-field-invalid') 'array pin is a shape failure, not a locale-formatted string'

$missingField=New-ProvenRecord -FeatureId $target -Scenario $scenario
$missingField.PSObject.Properties.Remove('scenario')
$missingFieldPath=New-EvidenceFile -Name 'missing.json' -Records @($missingField)
$missingFieldResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $missingFieldPath
Assert-That ((-not $missingFieldResult.enabled) -and $missingFieldResult.reason -eq 'evidence-field-invalid') 'record missing a required field proves nothing'

# malformed or hostile evidence registries
$garbagePath=Join-Path $tempDir 'garbage.json'
[IO.File]::WriteAllText($garbagePath,'{not json',[Text.Encoding]::UTF8)
$garbageResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $garbagePath
Assert-That ((-not $garbageResult.enabled) -and $garbageResult.reason -eq 'evidence-registry-unreadable') 'unparsable evidence registry is NOT_PROVEN'
$wrongVersionPath=Join-Path $tempDir 'wrong-version.json'
[IO.File]::WriteAllText($wrongVersionPath,'{"schema_version":2,"records":[]}',[Text.Encoding]::UTF8)
$wrongVersionResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $wrongVersionPath
Assert-That ((-not $wrongVersionResult.enabled) -and $wrongVersionResult.reason -eq 'evidence-registry-schema-invalid') 'unknown evidence schema version is NOT_PROVEN'
$recordsScalarPath=Join-Path $tempDir 'scalar.json'
[IO.File]::WriteAllText($recordsScalarPath,'{"schema_version":1,"records":"none"}',[Text.Encoding]::UTF8)
$recordsScalarResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $recordsScalarPath
Assert-That ((-not $recordsScalarResult.enabled) -and $recordsScalarResult.reason -eq 'evidence-registry-schema-invalid') 'scalar records field is NOT_PROVEN'
$emptyRecordsPath=Join-Path $tempDir 'empty.json'
[IO.File]::WriteAllText($emptyRecordsPath,'{"schema_version":1,"records":[]}',[Text.Encoding]::UTF8)
$emptyRecordsResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $emptyRecordsPath
Assert-That ((-not $emptyRecordsResult.enabled) -and $emptyRecordsResult.reason -eq 'evidence-not-found') 'empty append-only registry enables nothing'
$escapePath=Join-Path $tempDir 'escape.json'
[IO.File]::WriteAllText($escapePath,'{"schema_version":1,"records":[]}',[Text.Encoding]::UTF8)
$escapeResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path ('..\'+$tempDir.Substring(2)+'\escape.json')
Assert-That ((-not $escapeResult.enabled) -and $escapeResult.reason -eq 'evidence-path-invalid') 'path climbing out of the repository is refused'
$explicitPathResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $validPath
Assert-That ($explicitPathResult.enabled) 'explicit caller evidence path is honoured (read-only)'
$outsideRepoPath=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path 'C:\nonexistent-v2-evidence\evidence.json'
Assert-That ((-not $outsideRepoPath.enabled) -and $outsideRepoPath.reason -eq 'evidence-registry-missing') 'explicit path outside the repository stays NOT_PROVEN when absent'

# undeclared candidate and unusable registries
$unknown=Get-OrchestrationV2NativeFeature -feature_id 'not-a-candidate' -evidence_registry_path $validPath
Assert-That ((-not $unknown.enabled) -and $unknown.reason -eq 'feature-not-declared') 'undeclared candidate is NOT_PROVEN even with a valid evidence registry'
$hostileId=Get-OrchestrationV2NativeFeature -feature_id '../../etc/passwd' -evidence_registry_path $validPath
Assert-That ((-not $hostileId.enabled) -and $hostileId.reason -eq 'feature-id-missing' -and $hostileId.feature_id -notmatch '[\\/]') 'hostile feature_id is rejected and sanitized'
$missingRegistry=Get-OrchestrationV2NativeFeature -feature_id $target -registry_path 'source\registry\no-such-registry.json' -evidence_registry_path $validPath
Assert-That ((-not $missingRegistry.enabled) -and $missingRegistry.reason -eq 'registry-unavailable') 'absent candidate registry is NOT_PROVEN'

# ---------- registry schema drift fails closed (fail-closed on the declaration side) ----------
$driftCases=@(
    @{name='feature-id';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.feature_id='other-id'};reason='feature-id-mismatch'},
    @{name='description';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.description=42};reason='description-invalid'},
    @{name='required-evidence';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.required_evidence.PSObject.Properties.Remove('scenario')};reason='required-evidence-invalid'},
    @{name='evidence-type';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.required_evidence.type='synthetic-mock'};reason='evidence-type-unsupported'},
    @{name='evidence-runtime';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.required_evidence.runtime='v1'};reason='evidence-runtime-unsupported'},
    @{name='evidence-pin';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.required_evidence.pin='2.0.17'};reason='evidence-pin-unsupported'},
    @{name='v1-fallback';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.v1_fallback.mode='trust-the-runtime'};reason='v1-fallback-invalid'},
    @{name='authority-widening';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.authority_impact='widening'};reason='authority-impact-invalid'},
    @{name='status';mutate={param($r) $r.features.PSObject.Properties['session-hierarchy-provenance'].Value.status='enabled'};reason='status-invalid'},
    @{name='contract-order';mutate={param($r) $r.evidence_contract.hashed_fields=@('feature_id','type','runtime','pin','scenario','verified_by','verified_at')};reason='registry-schema-invalid'},
    @{name='contract-escape';mutate={param($r) $r.evidence_contract.registry_path='../../etc/v2-native-evidence.json'};reason='registry-schema-invalid'},
    @{name='contract-append-only';mutate={param($r) $r.evidence_contract.append_only=$false};reason='registry-schema-invalid'}
)
foreach($case in $driftCases){
    $copy=Copy-Registry $registry
    & $case.mutate $copy
    $driftResult=Get-OrchestrationV2NativeFeature -feature_id $target -Registry $copy -evidence_registry_path $validPath
    Assert-That ((-not $driftResult.enabled) -and $driftResult.status -eq 'not-proven' -and $driftResult.reason -eq $case.reason) ("registry drift: " + $case.name + " => " + $case.reason)
}

# ---------- R3: the library never writes evidence and opens no process/network ----------
$beforeListing=@(Get-ChildItem -LiteralPath $tempDir -Force|ForEach-Object{$_.Name+':'+$_.Length}|Sort-Object)
$beforeEvidence=(Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash
$beforeRegistry=(Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
$beforeFlags=(Get-FileHash -LiteralPath (Join-Path $repoRoot 'source\registry\capability-flags.json') -Algorithm SHA256).Hash
[void](Get-OrchestrationV2NativeFeatures -evidence_registry_path $validPath)
[void](Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $absentEvidence)
$afterListing=@(Get-ChildItem -LiteralPath $tempDir -Force|ForEach-Object{$_.Name+':'+$_.Length}|Sort-Object)
Assert-That (($beforeListing -join '|') -ceq ($afterListing -join '|')) 'gating adds no file to the evidence directory'
Assert-That ((Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash -ceq $beforeEvidence) 'evidence registry bytes are untouched'
Assert-That ((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash -ceq $beforeRegistry) 'candidate registry bytes are untouched'
Assert-That ((Get-FileHash -LiteralPath (Join-Path $repoRoot 'source\registry\capability-flags.json') -Algorithm SHA256).Hash -ceq $beforeFlags) 'capability flags are untouched'
$libText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1'))
foreach($forbidden in @('WriteAllText','WriteAllBytes','FileMode]::Append','Out-File','Set-Content','Add-Content','New-Item','Remove-Item','Copy-Item','Move-Item','Delete','Rename-Item')){
    Assert-That ($libText -notmatch [regex]::Escape($forbidden)) ("library contains no writer token: " + $forbidden)
}
foreach($forbidden in @('Invoke-WebRequest','Invoke-RestMethod','Start-Process','System.Net','WebClient','HttpClient','New-PSSession','curl ','wget ')){
    Assert-That ($libText -notmatch [regex]::Escape($forbidden)) ("library contains no network/process token: " + $forbidden)
}
Assert-That ((Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]@{feature_id='x'})) -eq '') 'digest is not computable from an incomplete record'

# ---------- R5: sanitized, bounded, deterministic output ----------
$hostileRegistry=Copy-Registry $registry
$hostileRegistry.features.PSObject.Properties[$target].Value.description=('sk-SYNTHETICSECRET token=abc https://secret.example.com/path' * 20)
$hostilePath=Join-Path $tempDir 'hostile.json'
[IO.File]::WriteAllText($hostilePath,(ConvertTo-Json -InputObject $hostileRegistry -Depth 20),[Text.Encoding]::UTF8)
$hostileGate=Get-OrchestrationV2NativeFeature -feature_id $target -registry_path $hostilePath -evidence_registry_path $validPath
Assert-That ($hostileGate.enabled -and $hostileGate.evidence.verified_by -eq 'livehook-v2.tests.ps1') 'hostile declaration text never reaches the gate output'
$hostileEvidence=New-EvidenceFile -Name 'hostile-evidence.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_by=('a'*400)}))
$hostileEvidenceResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $hostileEvidence
Assert-That ((-not $hostileEvidenceResult.enabled) -and $hostileEvidenceResult.reason -eq 'evidence-verifier-invalid' -and $hostileEvidenceResult.detail.Length -le 120) 'hostile verifier id fails closed with a bounded detail'
$first=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $validPath
$second=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $validPath
Assert-That ((ConvertTo-Json $first -Depth 10 -Compress) -ceq (ConvertTo-Json $second -Depth 10 -Compress)) 'identical inputs produce byte-identical output'
$offsetStamp=New-EvidenceFile -Name 'offset.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-02T09:00:00-03:00'}))
$offsetResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $offsetStamp
Assert-That ($offsetResult.enabled -and $offsetResult.evidence.verified_at -eq '2026-10-02T12:00:00.0000000Z') 'instant is normalized to UTC round-trip form'
$allFields=@(($first.PSObject.Properties.Name)+@($first.evidence.PSObject.Properties.Name)) -join ','
Assert-That ($allFields -eq 'feature_id,enabled,status,reason,detail,authority_impact,declared_status,v1_fallback_mode,scenario,evidence,verified_at,verified_by,record_hash') 'output shape is fixed'
$typedInstant=[ordered]@{feature_id=$target;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$scenario;verified_at=([DateTime]'2026-10-02T12:00:00Z');verified_by='livehook-v2.tests.ps1'}
$textInstant=[ordered]@{feature_id=$target;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$scenario;verified_at='2026-10-02T12:00:00Z';verified_by='livehook-v2.tests.ps1'}
Assert-That ((Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$typedInstant)) -ceq (Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$textInstant))) 'typed and text instants hash identically (PS7 auto-converts ISO JSON to DateTime)'

# ---------- F1: a rejected authority_impact is never echoed ----------
$hostileImpact=Copy-Registry $registry
$hostileImpact.features.PSObject.Properties[$target].Value.authority_impact=('sk-SYNTHETICSECRET token=abc https://evil.example.com/path'+[char]7+[char]27+[char]11+('y'*5000))
$hostileImpactResult=Get-OrchestrationV2NativeFeature -feature_id $target -Registry $hostileImpact -evidence_registry_path $validPath
$hostileImpactJson=ConvertTo-Json $hostileImpactResult -Depth 10 -Compress
Assert-That ((-not $hostileImpactResult.enabled) -and $hostileImpactResult.reason -eq 'authority-impact-invalid' -and $hostileImpactResult.authority_impact -eq 'unknown') 'rejected authority_impact degrades to unknown instead of echoing the value'
Assert-That ($hostileImpactJson -notmatch 'SYNTHETICSECRET|evil\.example|\babc\b|y{50}' -and $hostileImpactJson -notmatch '[^\x20-\x7E]') 'no byte of the hostile authority_impact (secret, controls, 5k padding) reaches the result JSON'
$widening=Copy-Registry $registry
$widening.features.PSObject.Properties[$target].Value.authority_impact='widening'
$wideningResult=Get-OrchestrationV2NativeFeature -feature_id $target -Registry $widening -evidence_registry_path $validPath
Assert-That ((-not $wideningResult.enabled) -and $wideningResult.reason -eq 'authority-impact-invalid' -and $wideningResult.authority_impact -eq 'unknown') 'widening is still refused and reported as unknown'

# ---------- F2: the evidence instant must carry its own offset ----------
[void](Assert-NotProven -Name 'nooffset.json' -Reason 'evidence-verified-at-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-02T12:00:00'})) -Label 'wall-clock time without offset')
[void](Assert-NotProven -Name 'dateonly.json' -Reason 'evidence-verified-at-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-02'})) -Label 'date without time')
[void](Assert-NotProven -Name 'nominutes.json' -Reason 'evidence-verified-at-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-02T12:00Z'})) -Label 'time without seconds')
[void](Assert-NotProven -Name 'numberstamp.json' -Reason 'evidence-verified-at-invalid' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at=20261002})) -Label 'numeric stamp is never coerced')
$zonePath=New-EvidenceFile -Name 'zone.json' -Records @((New-ProvenRecord -FeatureId $target -Scenario $scenario -Override @{verified_at='2026-10-02T21:00:00+09:00'}))
$zoneResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $zonePath
Assert-That ($zoneResult.enabled -and $zoneResult.evidence.verified_at -eq '2026-10-02T12:00:00.0000000Z' -and $zoneResult.evidence.record_hash -ceq $enabled.evidence.record_hash) 'the same instant under a different offset verifies to the same digest'
$unspecified=[ordered]@{feature_id=$target;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$scenario;verified_at=([DateTime]::SpecifyKind([DateTime]'2026-10-02 12:00:00',[DateTimeKind]::Unspecified));verified_by='livehook-v2.tests.ps1'}
Assert-That ((Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$unspecified)) -eq '') 'Kind Unspecified instant yields no digest'
$wallClock=[ordered]@{feature_id=$target;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$scenario;verified_at=[DateTime]'2026-10-02 12:00:00';verified_by='livehook-v2.tests.ps1'}
Assert-That ((Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$wallClock)) -eq '') 'wall-clock DateTime without offset yields no digest'

# ---------- F3: records must be an array in its original type ----------
$scalarObjectPath=Join-Path $tempDir 'scalar-object.json'
$scalarRecord=New-ProvenRecord -FeatureId $target -Scenario $scenario
[IO.File]::WriteAllText($scalarObjectPath,('{"schema_version":1,"records":'+(ConvertTo-Json -InputObject $scalarRecord -Depth 20 -Compress)+'}'),[Text.Encoding]::UTF8)
$scalarObjectResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $scalarObjectPath
Assert-That ((-not $scalarObjectResult.enabled) -and $scalarObjectResult.reason -eq 'evidence-registry-schema-invalid') 'scalar object holding a valid record is not normalized into a unit list'
$arrayOfOnePath=New-EvidenceFile -Name 'array-of-one.json' -Records @($scalarRecord)
$arrayOfOneResult=Get-OrchestrationV2NativeFeature -feature_id $target -evidence_registry_path $arrayOfOnePath
Assert-That ($arrayOfOneResult.enabled) 'the same record inside a real one-element array still verifies'

# ---------- contract: ASCII-only sources, honest HOLD documented ----------
foreach($file in @((Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1'),(Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.tests.ps1'),$registryPath)){
    $bytes=[IO.File]::ReadAllBytes($file)
    Assert-That (@($bytes|Where-Object{$_ -gt 127}).Count -eq 0) ("ASCII-only: " + [IO.Path]::GetFileName($file))
}
$help=Get-Help (Resolve-Path (Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1'))
$description=[string](($help.Description.Text) -join ' ')
Assert-That ($description -match 'NOT ONE' -and $description -match '17\.10' -and $description -match 'read-only' -and $description -match 'fail-closed') 'synopsis documents the honest HOLD, the exact-binary rule and the read-only contract'
$flags=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $repoRoot 'source\registry\capability-flags.json')))
Assert-That (($flags.runtime_support.v2 -eq $true) -and (-not $flags.capability_router.active) -and (-not $flags.capability_router.shadow)) 'runtime v2 is activated in the registry (2026-10-04) and the capability router stays off: the gate still owns no activation switch'

} finally {
    try {[IO.Directory]::Delete($tempDir,$true)} catch {}
}

Write-Output "PASS: $passed assertions"