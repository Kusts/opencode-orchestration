[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationV2EvidenceSupersession.ps1')
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$registryPath=Join-Path $repoRoot 'source\registry\v2-native-capabilities.json'
$registry=ConvertFrom-Json ([IO.File]::ReadAllText($registryPath))
$defaultEvidencePath=Join-Path $repoRoot 'evidence\v3.1\runtime-reliability\v2-native-evidence.json'
$flagsPath=Join-Path $repoRoot 'source\registry\capability-flags.json'
$libraryPath=Join-Path $PSScriptRoot 'OrchestrationV2EvidenceSupersession.ps1'
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}

$tempDir=Join-Path $env:TEMP ('v2-evidence-supersession-'+[Guid]::NewGuid().ToString('n'))
[void][IO.Directory]::CreateDirectory($tempDir)
try {

# ---------- helpers (test side only; the library never writes) ----------
$featureId='session-hierarchy-provenance'
$scenario=[string]$registry.features.PSObject.Properties[$featureId].Value.required_evidence.scenario
$required=@{runtime='v2';pin='2.0.18';scenario=$scenario}
$closedVerdicts=@('duplicate','supersede-recommended','stale-candidate','ambiguous-same-instant','identity-mismatch','invalid-existing','invalid-candidate','unavailable')
$closedRecommendations=@('no-prior-evidence','duplicate-no-op','append-supersedes-recommended','registry-has-invalid-records','review-required')

function New-SupersessionRecord {
    <# Valid records are built through the S1 canonical digest helper: no copied hashing. #>
    param([string]$At,[string]$By='livehook-v2.tests.ps1',[hashtable]$Override=@{},[string]$DigestOverride='')
    $record=[ordered]@{feature_id=$featureId;type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$scenario;verified_at=$At;verified_by=$By}
    foreach($key in $Override.Keys){if($key -cne 'record_hash'){$record[$key]=$Override[$key]}}
    $hash=Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$record)
    if($DigestOverride){$hash=$DigestOverride}
    if(-not $hash){$hash=('0'*64)}
    $record['record_hash']=$hash
    return [pscustomobject]$record
}
function New-SupersessionFile {
    param([string]$Name,[object[]]$Records)
    $path=Join-Path $script:tempDir $Name
    $doc=[ordered]@{schema_version=1;runtime='v2';pin='2.0.18';records=@($Records)}
    [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $doc -Depth 20),[Text.Encoding]::UTF8)
    return $path
}
function Invoke-Review {
    param([string]$Path,$Record,[hashtable]$Bound=$null)
    if($Bound){return (Get-OrchestrationV2SupersessionReview -RegistryPath $Path -Candidate $Record -Contract $Bound)}
    return (Get-OrchestrationV2SupersessionReview -RegistryPath $Path -Candidate $Record)
}

# ---------- M1: the verdict matrix is closed and each fixture is discriminante ----------
$proven=New-SupersessionRecord -At '2026-10-02T12:00:00Z'
$newer=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'release-operator.tests.ps1'
$matrix=@(
    @{label='duplicate (identical canonical digest)';existing=$proven;candidate=$proven;verdict='duplicate';reason='identical-evidence-record'},
    @{label='duplicate under a different offset spelling';existing=$proven;candidate=(New-SupersessionRecord -At '2026-10-02T09:00:00-03:00');verdict='duplicate';reason='identical-evidence-record'},
    @{label='supersede-recommended (candidate strictly newer)';existing=$proven;candidate=$newer;verdict='supersede-recommended';reason='candidate-instant-strictly-newer'},
    @{label='stale-candidate (candidate strictly older)';existing=$newer;candidate=$proven;verdict='stale-candidate';reason='candidate-instant-older'},
    @{label='ambiguous-same-instant (equal instant, divergent content)';existing=$proven;candidate=(New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'second-operator.tests.ps1');verdict='ambiguous-same-instant';reason='identical-instant-divergent-content'},
    @{label='identity-mismatch (other scenario)';existing=(New-SupersessionRecord -At '2026-10-02T12:00:00Z' -Override @{scenario='some-other-scenario'});candidate=$newer;verdict='identity-mismatch';reason='evidence-identity-divergent'},
    @{label='identity-mismatch (other feature)';existing=(New-SupersessionRecord -At '2026-10-02T12:00:00Z' -Override @{feature_id='native-step-limits'});candidate=$newer;verdict='identity-mismatch';reason='evidence-identity-divergent'},
    @{label='identity-mismatch (other pin)';existing=(New-SupersessionRecord -At '2026-10-02T12:00:00Z' -Override @{pin='2.0.17'});candidate=$newer;verdict='identity-mismatch';reason='evidence-identity-divergent'},
    @{label='invalid-existing (unparsable verified_at)';existing=(New-SupersessionRecord -At 'yesterday');candidate=$newer;verdict='invalid-existing';reason='evidence-verified-at-invalid'},
    @{label='invalid-existing (digest diverges from content)';existing=(New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'first-operator.tests.ps1');candidate=$newer;verdict='invalid-existing';reason='evidence-hash-mismatch';tamper='existing'},
    @{label='invalid-candidate (unparsable verified_at)';existing=$proven;candidate=(New-SupersessionRecord -At '2026-10-04');verdict='invalid-candidate';reason='evidence-verified-at-invalid'},
    @{label='invalid-candidate (digest diverges from content)';existing=$proven;candidate=(New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'second-operator.tests.ps1');verdict='invalid-candidate';reason='evidence-hash-mismatch';tamper='candidate'}
)
foreach($case in $matrix){
    if($case.tamper -ceq 'existing'){$case.existing.verified_by='tampered-editor.tests.ps1'}
    if($case.tamper -ceq 'candidate'){$case.candidate.verified_by='tampered-editor.tests.ps1'}
    $verdict=Test-OrchestrationV2EvidenceSupersession -Existing $case.existing -Candidate $case.candidate -FeatureId $featureId -Required $required
    Assert-That ([string]$verdict.verdict -ceq $case.verdict) ("verdict: " + $case.label + " => " + $case.verdict)
    Assert-That ([string]$verdict.reason -ceq $case.reason) ("reason: " + $case.label + " => " + $case.reason)
    Assert-That ($closedVerdicts -contains [string]$verdict.verdict) ("closed verdict set: " + $case.label)
    Assert-That ([bool]$verdict.decision_record_only -and [bool]$verdict.enables_nothing) ("decision-record claims: " + $case.label)
}

# each verdict in the matrix is discriminante: no fixture collapses onto another verdict
$seen=@($matrix|ForEach-Object{[string]$_.verdict}|Sort-Object -Unique)
Assert-That (($seen -join ',') -ceq (($closedVerdicts|Where-Object{$_ -cne 'unavailable'}|Sort-Object) -join ',')) 'the matrix exercises every decider verdict (unavailable is covered separately)'

# identity divergence is decided ordinally: case folding never merges two slots
$upperSlot=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -Override @{scenario=($scenario.ToUpperInvariant())}
$caseVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $upperSlot -FeatureId $featureId -Required $required
Assert-That ([string]$caseVerdict.verdict -ceq 'identity-mismatch') 'ordinal identity comparison does not fold case'
$spaceVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate (New-SupersessionRecord -At '2026-10-03T09:00:00Z' -Override @{scenario=(' '+$scenario)}) -FeatureId $featureId -Required $required
Assert-That ([string]$spaceVerdict.verdict -eq 'identity-mismatch' -or [string]$spaceVerdict.verdict -eq 'invalid-candidate') 'a padded scenario is never silently trimmed into the same slot'

# instants are compared after UTC normalization, not as raw text
$offsetExisting=New-SupersessionRecord -At '2026-10-03T09:00:00Z'
$offsetCandidate=New-SupersessionRecord -At '2026-10-03T06:00:00-03:00' -By 'release-operator.tests.ps1'
$offsetVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $offsetExisting -Candidate $offsetCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$offsetVerdict.verdict -ceq 'ambiguous-same-instant') 'the same instant under two offsets is equal, not newer'
Assert-That ([string]$offsetVerdict.existing_verified_at -ceq '2026-10-03T09:00:00.0000000Z' -and [string]$offsetVerdict.candidate_verified_at -ceq '2026-10-03T09:00:00.0000000Z') 'both instants are normalized to UTC round-trip form before the output'

# ---------- F2: identity is compared ORDINALLY, never by the culture collation ----------
$softHyphen=[char]0x00AD
# Newer on purpose: under a culture comparison this pair would reach the DANGEROUS
# direction and recommend a supersede of a different slot.
$softSlot=New-SupersessionRecord -At '2026-10-05T09:00:00Z' -Override @{scenario=($scenario+$softHyphen)}
$softVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $newer -Candidate $softSlot -FeatureId $featureId -Required $required
Assert-That ([string]$softVerdict.verdict -ceq 'identity-mismatch' -and [string]$softVerdict.reason -ceq 'evidence-identity-divergent') 'F2: a slot whose scenario carries an ignorable soft hyphen is a DIFFERENT evidence slot'
$upperFeatureSlot=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -Override @{feature_id=($featureId.ToUpperInvariant())}
$upperFeatureVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $newer -Candidate $upperFeatureSlot -FeatureId $featureId -Required $required
Assert-That ([string]$upperFeatureVerdict.verdict -ceq 'identity-mismatch') 'F2: a feature id differing only by case is a different evidence slot'
$softPinSlot=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -Override @{pin=('2.0.18'+$softHyphen)}
$softPinVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $newer -Candidate $softPinSlot -FeatureId $featureId -Required $required
Assert-That ([string]$softPinVerdict.verdict -ceq 'identity-mismatch') 'F2: the same rule holds for every identity field, not only scenario'

# ---------- M2: unusable caller contract never produces a verdict about the records ----------
$nullPair=Test-OrchestrationV2EvidenceSupersession -Existing $null -Candidate $null -FeatureId '' -Required $null
Assert-That ([string]$nullPair.verdict -ceq 'unavailable' -and [string]$nullPair.reason -ceq 'feature-id-invalid') 'empty feature id is unavailable, not a verdict'
$badFeature=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId '../../etc/passwd' -Required $required
Assert-That ([string]$badFeature.verdict -ceq 'unavailable' -and [string]$badFeature.reason -ceq 'feature-id-invalid' -and [string]$badFeature.feature_id -notmatch '[\\/]') 'hostile feature id is refused and sanitized'
$badRequired=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required $null
Assert-That ([string]$badRequired.verdict -ceq 'unavailable' -and [string]$badRequired.reason -ceq 'required-evidence-invalid') 'missing required contract is unavailable'
$partialRequired=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required @{runtime='v2';pin='2.0.18'}
Assert-That ([string]$partialRequired.verdict -ceq 'unavailable' -and [string]$partialRequired.reason -ceq 'required-evidence-invalid') 'a partial required contract is unavailable'
$typedRequired=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required @{runtime='v2';pin='2.0.18';scenario=[string[]]@($scenario,$scenario)}
Assert-That ([string]$typedRequired.verdict -ceq 'unavailable' -and [string]$typedRequired.reason -ceq 'required-evidence-invalid') 'a non-string requirement field is never coerced into a verdict'
$nullRequired=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required ([pscustomobject]@{runtime='v2';pin='2.0.18';scenario=$scenario})
Assert-That ([string]$nullRequired.verdict -ceq 'unavailable' -and [string]$nullRequired.reason -ceq 'required-evidence-invalid') 'a requirement that is not a dictionary is unavailable'

# ---------- F3: with the S1 reader absent the reviewer is unavailable and never throws ----------
$isolatedBody=@'
$library=$args[0]
$output=$args[1]
$workDir=$args[2]
$ErrorActionPreference='Stop'
. $library
$readerPresent=[bool](Get-Command -Name 'Get-OrchestrationV2NativeRecordReason' -CommandType Function -ErrorAction SilentlyContinue)
function New-IsolatedRecord {
    param([string]$At,[string]$By='livehook-v2.tests.ps1',[string]$Scenario='session-hierarchy-provenance-exact-binary')
    $record=[ordered]@{feature_id='session-hierarchy-provenance';type='exact-binary-live';runtime='v2';pin='2.0.18';scenario=$Scenario;verified_at=$At;verified_by=$By}
    $hash=''
    if($readerPresent){$hash=Get-OrchestrationV2NativeEvidenceHash ([pscustomobject]$record)}
    if(-not $hash){$hash=('0'*64)}
    $record['record_hash']=$hash
    return [pscustomobject]$record
}
$existing=New-IsolatedRecord -At '2026-10-02T12:00:00Z'
$candidate=New-IsolatedRecord -At '2026-10-03T09:00:00Z' -By 'release-operator.tests.ps1'
$ambiguous=New-IsolatedRecord -At '2026-10-03T09:00:00Z' -By 'first-operator.tests.ps1'
$softScenario=New-IsolatedRecord -At '2026-10-05T09:00:00Z' -Scenario ('session-hierarchy-provenance-exact-binary'+[char]0x00AD)
$required=@{runtime='v2';pin='2.0.18';scenario='session-hierarchy-provenance-exact-binary'}
$verdict=Test-OrchestrationV2EvidenceSupersession -Existing $existing -Candidate $candidate -FeatureId 'session-hierarchy-provenance' -Required $required
$unicodeVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $candidate -Candidate $softScenario -FeatureId 'session-hierarchy-provenance' -Required $required
$review=Get-OrchestrationV2SupersessionReview -Candidate $candidate
$registryPath=Join-Path $workDir 'isolated-registry.json'
$registry=[ordered]@{schema_version=1;runtime='v2';pin='2.0.18';records=@($existing,$ambiguous)}
[IO.File]::WriteAllText($registryPath,(ConvertTo-Json -InputObject $registry -Depth 20),[Text.Encoding]::UTF8)
$registryReview=Get-OrchestrationV2SupersessionReview -RegistryPath $registryPath -Candidate $candidate
$payload=[ordered]@{reader_present=$readerPresent;verdict=[string]$verdict.verdict;reason=[string]$verdict.reason;feature_id=[string]$verdict.feature_id;existing_record_hash=[string]$verdict.existing_record_hash;unicode_verdict=[string]$unicodeVerdict.verdict;review_state=[string]$review.state;review_reason=[string]$review.reason;review_recommendation=[string]$review.recommendation;registry_review_recommendation=[string]$registryReview.recommendation;registry_review_supersede=[int]$registryReview.summary['supersede-recommended'];registry_review_ambiguous=[int]$registryReview.summary['ambiguous-same-instant']}
[IO.File]::WriteAllText($output,(ConvertTo-Json -InputObject $payload -Compress),[Text.Encoding]::UTF8)
'@
function Invoke-IsolatedLibrary {
    param([string]$Library,[string]$OutFile)
    $runspace=[powershell]::Create()
    $errors=0
    try{
        $null=$runspace.AddScript($isolatedBody).AddArgument($Library).AddArgument($OutFile).AddArgument($script:tempDir)
        $handle=$runspace.BeginInvoke()
        $null=$runspace.EndInvoke($handle)
        $errors=$runspace.Streams.Error.Count
    } finally {
        if($null -ne $runspace){$runspace.Dispose()}
    }
    return $errors
}
$isolationDir=Join-Path $tempDir 'isolation'
[void][IO.Directory]::CreateDirectory($isolationDir)
$lonelyLibrary=Join-Path $isolationDir 'OrchestrationV2EvidenceSupersession.ps1'
$libraryText=[IO.File]::ReadAllText($libraryPath)
[IO.File]::WriteAllText($lonelyLibrary,$libraryText,[Text.Encoding]::UTF8)
$lonelyOutput=Join-Path $isolationDir 'lonely.json'
$lonelyErrors=Invoke-IsolatedLibrary -Library $lonelyLibrary -OutFile $lonelyOutput
Assert-That ($lonelyErrors -eq 0) 'a reviewer copy without the S1 library raises no error'
Assert-That (Test-Path -LiteralPath $lonelyOutput -PathType Leaf) 'a reviewer copy without the S1 library still returns a structured verdict (no raw throw)'
$lonely=ConvertFrom-Json ([IO.File]::ReadAllText($lonelyOutput))
Assert-That ((-not $lonely.reader_present) -and $lonely.verdict -ceq 'unavailable' -and $lonely.reason -ceq 'gating-library-unavailable') 'S1 absent => unavailable/gating-library-unavailable'
Assert-That ($lonely.feature_id -eq '' -and $lonely.existing_record_hash -eq '') 'an unavailable reviewer echoes nothing about the submitted records'
$lonelyReviewErrors=$lonelyErrors
Assert-That ($lonelyReviewErrors -eq 0) 'the registry review also survives the absence of the S1 library without throwing'
Assert-That ($lonely.review_state -ceq 'unavailable' -and $lonely.review_reason -ceq 'gating-library-unavailable' -and $lonely.review_recommendation -ceq 'review-required') 'S1 absent => the registry review is unavailable too'

# ---------- M3: inverting the verified_at comparison must change the verdicts ----------
$mutationDir=Join-Path $isolationDir 'mutated'
[void][IO.Directory]::CreateDirectory($mutationDir)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1') -Destination $mutationDir
$invertedText=$libraryText.Replace('if($order -gt 0){','if($order -SWAP){').Replace('if($order -lt 0){','if($order -gt 0){').Replace('if($order -SWAP){','if($order -lt 0){')
Assert-That ($invertedText -cne $libraryText) 'the verified_at comparison is a single, mutation-visible branch'
Assert-That ($invertedText.Contains('if($order -gt 0){') -and $invertedText.Contains('if($order -lt 0){')) 'the mutation swaps both instant branches'
$invertedLibrary=Join-Path $mutationDir 'OrchestrationV2EvidenceSupersession.ps1'
[IO.File]::WriteAllText($invertedLibrary,$invertedText,[Text.Encoding]::UTF8)
$invertedOutput=Join-Path $mutationDir 'inverted.json'
Assert-That ((Invoke-IsolatedLibrary -Library $invertedLibrary -OutFile $invertedOutput) -eq 0) 'the comparison-inverted reviewer runs without error'
$inverted=ConvertFrom-Json ([IO.File]::ReadAllText($invertedOutput))
Assert-That ($inverted.reader_present) 'the comparison-inverted reviewer still loads the S1 library'
Assert-That ($inverted.verdict -ceq 'stale-candidate' -and $inverted.reason -ceq 'candidate-instant-older') 'mutation: inverting the verified_at comparison swaps supersede-recommended for stale-candidate'
$ordinalExpression='$same=[string]::Equals([string]$ExistingIdentity.$field,[string]$CandidateIdentity.$field,[StringComparison]::Ordinal)'
$foldedText=$libraryText.Replace($ordinalExpression,'$same=(-not ([string]$ExistingIdentity.$field -ceq [string]$CandidateIdentity.$field))')
Assert-That ($foldedText -cne $libraryText) 'the ordinal identity comparison is a single, mutation-visible expression'
$foldedLibrary=Join-Path $mutationDir 'folded.ps1'
[IO.File]::WriteAllText($foldedLibrary,$foldedText,[Text.Encoding]::UTF8)
$foldedOutput=Join-Path $mutationDir 'folded.json'
Assert-That ((Invoke-IsolatedLibrary -Library $foldedLibrary -OutFile $foldedOutput) -eq 0) 'the identity-inverted reviewer runs without error'
$folded=ConvertFrom-Json ([IO.File]::ReadAllText($foldedOutput))
Assert-That ($folded.verdict -ceq 'identity-mismatch' -and $folded.reason -ceq 'evidence-identity-divergent') 'mutation: inverting the identity comparison turns a proven supersession into identity-mismatch'

# ---------- M4: reverting the ORDINAL identity comparison merges two different slots ----------
# U+00AD is dropped by the default culture collation, so a cultural comparison reports
# "scenario" and "scenario + U+00AD" as the SAME slot and lets the record reach a decider
# verdict. Under Ordinal they are different slots.
Assert-That ($libraryText.Contains('[StringComparison]::Ordinal')) 'the identity comparison is ordinal by construction'
Assert-That (($scenario -cne ($scenario+[char]0x00AD)) -eq $false) 'the engine collation really does ignore the soft hyphen used by this fixture'
$culturalText=$libraryText.Replace($ordinalExpression,'$same=CULTURAL-SWAP')
$culturalText=$culturalText.Replace('$same=CULTURAL-SWAP','$same=(-not ([string]$ExistingIdentity.$field -cne [string]$CandidateIdentity.$field))')
Assert-That ($culturalText -cne $libraryText) 'the cultural identity comparison mutation is applied'
$culturalLibrary=Join-Path $mutationDir 'cultural.ps1'
[IO.File]::WriteAllText($culturalLibrary,$culturalText,[Text.Encoding]::UTF8)
$culturalOutput=Join-Path $mutationDir 'cultural.json'
Assert-That ((Invoke-IsolatedLibrary -Library $culturalLibrary -OutFile $culturalOutput) -eq 0) 'the culture-compared reviewer runs without error'
$cultural=ConvertFrom-Json ([IO.File]::ReadAllText($culturalOutput))
Assert-That ($cultural.unicode_verdict -ceq 'supersede-recommended' -and $cultural.reason -ceq 'candidate-instant-strictly-newer') 'mutation: a culture-sensitive identity comparison merges a soft-hyphen slot into a proven supersession'

# ---------- M5: dropping the 'ambiguous-same-instant' TERM from the impeditivo guard ----------
# What this proves, precisely: with only that one term neutralized (the invalid-*
# terms stay), a registry holding an ambiguous pair alongside a superseding one reaches
# append-supersedes-recommended. It does NOT claim that the invalid-* terms are
# unguarded, nor that duplicate was evaluated before the guard.
$impeditiveText=$libraryText.Replace("([int]`$summary['ambiguous-same-instant'] -gt 0)","(0 -gt 0)")
Assert-That ($impeditiveText -cne $libraryText) 'the ambiguous term of the impeditivo guard is a single, mutation-visible expression'
$impeditiveLibrary=Join-Path $mutationDir 'impeditive-removed.ps1'
[IO.File]::WriteAllText($impeditiveLibrary,$impeditiveText,[Text.Encoding]::UTF8)
$impeditiveOutput=Join-Path $mutationDir 'impeditive.json'
Assert-That ((Invoke-IsolatedLibrary -Library $impeditiveLibrary -OutFile $impeditiveOutput) -eq 0) 'the reviewer with the ambiguous term neutralized runs without error'
$impeditive=ConvertFrom-Json ([IO.File]::ReadAllText($impeditiveOutput))
Assert-That ($impeditive.registry_review_ambiguous -eq 1 -and $impeditive.registry_review_supersede -eq 1) 'neutralizing the ambiguous term leaves the per-verdict counters untouched'
Assert-That ($impeditive.registry_review_recommendation -ceq 'append-supersedes-recommended') 'mutation: without the ambiguous term, an ambiguous pair no longer blocks an append recommendation'

# ---------- R1: registry review fails closed on the registry ----------
$reviewedCandidate=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'release-operator.tests.ps1'
$absentReview=Invoke-Review -Path (Join-Path $tempDir 'never-created.json') -Record $reviewedCandidate
Assert-That ($absentReview.state -eq 'unavailable' -and $absentReview.reason -eq 'evidence-registry-missing' -and $absentReview.recommendation -eq 'review-required') 'an absent registry is never reviewed over'
Assert-That ($absentReview.reviewed_count -eq 0 -and $absentReview.ignored_count -eq 0 -and $absentReview.verdicts.Count -eq 0) 'an absent registry produces no per-record verdict'
$garbagePath=Join-Path $tempDir 'garbage.json'
[IO.File]::WriteAllText($garbagePath,'{not json',[Text.Encoding]::UTF8)
$garbageReview=Invoke-Review -Path $garbagePath -Record $reviewedCandidate
Assert-That ($garbageReview.state -eq 'unavailable' -and $garbageReview.reason -eq 'evidence-registry-unreadable') 'an unreadable registry is never reviewed over'
$wrongVersionPath=Join-Path $tempDir 'wrong-version.json'
[IO.File]::WriteAllText($wrongVersionPath,'{"schema_version":7,"records":[]}',[Text.Encoding]::UTF8)
$wrongVersionReview=Invoke-Review -Path $wrongVersionPath -Record $reviewedCandidate
Assert-That ($wrongVersionReview.state -eq 'unavailable' -and $wrongVersionReview.reason -eq 'evidence-registry-schema-invalid') 'an unknown registry schema version is never reviewed over'
$scalarPath=Join-Path $tempDir 'scalar-records.json'
[IO.File]::WriteAllText($scalarPath,'{"schema_version":1,"records":"none"}',[Text.Encoding]::UTF8)
$scalarReview=Invoke-Review -Path $scalarPath -Record $reviewedCandidate
Assert-That ($scalarReview.state -eq 'unavailable' -and $scalarReview.reason -eq 'evidence-registry-schema-invalid') 'a scalar records field is never reviewed over'
$escapingReview=Invoke-Review -Path ('..\'+$tempDir.Substring(3)+'\scalar-records.json') -Record $reviewedCandidate
Assert-That ($escapingReview.state -eq 'unavailable' -and $escapingReview.reason -eq 'evidence-path-invalid') 'a registry path climbing out of the repository is refused'
$noIdentityReview=Invoke-Review -Path (New-SupersessionFile -Name 'ok.json' -Records @($proven)) -Record $null
Assert-That ($noIdentityReview.state -eq 'unavailable' -and $noIdentityReview.reason -eq 'candidate-identity-undecidable' -and $noIdentityReview.recommendation -eq 'review-required') 'an absent candidate is fail-closed before the registry is read'
$hostileCandidate=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -Override @{feature_id=('sk-SYNTHETICSECRET token=abc https://evil.example.com/x')}
$hostileCandidateReview=Invoke-Review -Path (New-SupersessionFile -Name 'ok.json' -Records @($proven)) -Record $hostileCandidate
Assert-That ($hostileCandidateReview.state -eq 'unavailable' -and $hostileCandidateReview.reason -eq 'candidate-feature-id-invalid') 'a candidate whose feature id is not a closed name is fail-closed'
$boundedReview=Invoke-Review -Path (New-SupersessionFile -Name 'bounded.json' -Records @($proven,$newer)) -Record $reviewedCandidate -Bound @{max_records=1}
Assert-That ($boundedReview.state -eq 'unavailable' -and $boundedReview.reason -eq 'evidence-registry-schema-invalid') 'a registry beyond the contract record bound is refused'

# ---------- F3: an unprovable candidate is reported as such, never as no-prior-evidence ----------
$emptyRegistry=New-SupersessionFile -Name 'empty-records.json' -Records @()
$otherIdentityOnly=New-SupersessionFile -Name 'other-identity.json' -Records @($otherRecord)
$brokenStamp=New-SupersessionRecord -At 'yesterday'
$brokenStamp.PSObject.Properties['record_hash'].Value=('0'*64)
$tamperedCandidate=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'release-operator.tests.ps1'
$tamperedCandidate.verified_by='tampered-editor.tests.ps1'
foreach($fixture in @(
    @{label='empty registry';path=$emptyRegistry;record=$brokenStamp;reason='evidence-verified-at-invalid'},
    @{label='registry of other identities only';path=$otherIdentityOnly;record=$brokenStamp;reason='evidence-verified-at-invalid'},
    @{label='tampered digest';path=$emptyRegistry;record=$tamperedCandidate;reason='evidence-hash-mismatch'},
    @{label='both records broken';path=(New-SupersessionFile -Name 'broken-existing.json' -Records @($brokenStamp));record=$brokenStamp;reason='evidence-verified-at-invalid'}
)){
    $review=Invoke-Review -Path $fixture.path -Record $fixture.record
    Assert-That ($review.state -eq 'unavailable' -and $review.recommendation -eq 'review-required') ("F3: " + $fixture.label + " => review-required")
    Assert-That ($review.reason -eq 'candidate-evidence-invalid' -and $review.candidate_reason -eq $fixture.reason) ("F3: " + $fixture.label + " carries the S1 candidate reason")
    Assert-That ($review.recommendation -ne 'no-prior-evidence' -and $review.reviewed_count -eq 0) ("F3: " + $fixture.label + " is never no-prior-evidence")
}
$brokenReview=Invoke-Review -Path $emptyRegistry -Record $brokenStamp
Assert-That ([string]$brokenReview.candidate_verified_at -eq '' -and [string]$brokenReview.candidate_reason -eq 'evidence-verified-at-invalid') 'an unparsable instant is never echoed, only the closed S1 reason'
$brokenHashCandidate=New-SupersessionRecord -At '2026-10-03T09:00:00Z'
$brokenHashCandidate.record_hash=('not-a-digest-'+('q'*40))
$brokenHashReview=Invoke-Review -Path $emptyRegistry -Record $brokenHashCandidate
Assert-That ([string]$brokenHashReview.candidate_record_hash -eq '' -and [string]$brokenHashReview.candidate_reason -eq 'evidence-hash-format-invalid') 'F4: a record_hash that is not a digest is not echoed even for an invalid candidate'

# ---------- F4: record_hash is echoed only when it really is a 64-hex digest ----------
$hostileHash=New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'first-operator.tests.ps1'
$hostileHash.record_hash=('sk-SYNTHETICSECRET '+('a'*80))
$hostileHashVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $hostileHash -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$hostileHashVerdict.existing_record_hash -eq '') 'F4: a hostile record_hash on the existing side is never echoed, not even truncated'
Assert-That ([string]$hostileHashVerdict.candidate_record_hash -match '^[0-9a-f]{64}$') 'F4: a genuine digest is still emitted'
$hostileHashCandidate=New-SupersessionRecord -At '2026-10-02T12:00:00Z'
$hostileHashCandidate.record_hash=('x'*64)
$hostileHashCandidateVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $newer -Candidate $hostileHashCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$hostileHashCandidateVerdict.candidate_record_hash -eq '' -and [string]$hostileHashCandidateVerdict.existing_record_hash -match '^[0-9a-f]{64}$') 'F4: a non-hex 64-character record_hash is not echoed as a digest'
$shortHash=New-SupersessionRecord -At '2026-10-02T12:00:00Z'
$shortHash.record_hash=('a'*63)
$shortHashVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $shortHash -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$shortHashVerdict.existing_record_hash -eq '') 'F4: a 63-character record_hash is not echoed'
$upperHash=New-SupersessionRecord -At '2026-10-02T12:00:00Z'
$upperHash.record_hash=([string]$upperHash.record_hash).ToUpperInvariant()
$upperHashVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $upperHash -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$upperHashVerdict.existing_record_hash -match '^[0-9a-f]{64}$') 'F4: an uppercase digest is emitted normalized to lowercase'

# ---------- G1: the digest shape is anchored, so a trailing newline cannot ride along ----------
# In .NET '$' also matches immediately BEFORE a trailing newline, so a '^...$' anchor would
# accept 64 hex characters + LF. \A...\z must refuse every trailing code unit.
Assert-That ($libraryText.Contains("'\A[0-9a-fA-F]{64}\z'")) 'G1: the digest shape is anchored with \A...\z'
foreach($suffix in @([string][char]10,([string][char]13+[string][char]10),([string][char]13),([string][char]0),' ')){
    $trailing=New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'first-operator.tests.ps1'
    $trailing.record_hash=([string]$trailing.record_hash)+$suffix
    $trailingVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $trailing -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
    Assert-That ([string]$trailingVerdict.existing_record_hash -eq '') ('G1: a digest with a trailing code unit is never echoed: U+' + ('{0:X4}' -f [int][char]($suffix[[char]$suffix.Length-1])))
}
$unicodeDigest=New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'first-operator.tests.ps1'
$unicodeDigest.record_hash=(('a'*63)+[string][char]0x00AD)
$unicodeDigestVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $unicodeDigest -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$unicodeDigestVerdict.existing_record_hash -eq '') 'G1: a non-hex code unit inside the digest shape is refused'
$leadingDigest=New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By 'first-operator.tests.ps1'
$leadingDigest.record_hash=([string][char]10)+([string]$leadingDigest.record_hash)
$leadingDigestVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $leadingDigest -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$leadingDigestVerdict.existing_record_hash -eq '') 'G1: a leading code unit is refused as well'
$newlineHashReview=Invoke-Review -Path (New-SupersessionFile -Name 'newline-hash.json' -Records @($trailing)) -Record $reviewedCandidate
Assert-That ([string]$newlineHashReview.verdicts[0].existing_record_hash -eq '') 'G1: the aggregated review echoes no digest for a record_hash carrying a trailing code unit'
Assert-That ([string]$newlineHashReview.recommendation -eq 'review-required') 'G1: the registry carrying that record is reported as impeditivo, not as a positive recommendation'
$hostileHashReview=Invoke-Review -Path (New-SupersessionFile -Name 'hostile-hash.json' -Records @($hostileHash)) -Record $reviewedCandidate
Assert-That ([string]$hostileHashReview.candidate_record_hash -match '^[0-9a-f]{64}$') 'F4: the aggregated review still emits a genuine candidate digest'
Assert-That ((ConvertTo-Json $hostileHashReview -Depth 8 -Compress) -notmatch 'SYNTHETICSECRET') 'F4: no hostile record_hash byte reaches the aggregated review JSON'

# ---------- F5: an explicitly supplied unusable -Now fails closed ----------
$f5Registry=New-SupersessionFile -Name 'f5-supersede.json' -Records @($proven)
$badNowPair=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required $required -Now 'not-an-instant'
Assert-That ([string]$badNowPair.verdict -eq 'unavailable' -and [string]$badNowPair.reason -eq 'now-invalid-unusable') 'F5: an unusable -Now makes the pair verdict unavailable'
Assert-That ([string]$badNowPair.generated_at -eq '' -and [string]$badNowPair.timestamp_note -eq 'now-invalid-unusable') 'F5: the unusable -Now is reported, never silently stamped'
$badNowDuplicate=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $proven -FeatureId $featureId -Required $required -Now 12345
Assert-That ([string]$badNowDuplicate.verdict -eq 'unavailable') 'F5: an unusable -Now outranks even an unambiguous duplicate'
$badNowReview=Get-OrchestrationV2SupersessionReview -RegistryPath $f5Registry -Candidate $reviewedCandidate -Now 'not-an-instant'
Assert-That ($badNowReview.state -eq 'unavailable' -and $badNowReview.recommendation -eq 'review-required' -and $badNowReview.reason -eq 'now-invalid-unusable') 'F5: an unusable -Now never leaves a positive recommendation'
$goodNowReview=Get-OrchestrationV2SupersessionReview -RegistryPath $f5Registry -Candidate $reviewedCandidate -Now ([DateTime]'2026-10-06T00:00:00Z')
Assert-That ($goodNowReview.state -eq 'ok' -and $goodNowReview.recommendation -eq 'append-supersedes-recommended' -and $goodNowReview.generated_at -eq '2026-10-06T00:00:00.0000000Z') 'F5: a usable -Now is recorded and never decides'
$badNowBeforeRegistry=Get-OrchestrationV2SupersessionReview -RegistryPath (Join-Path $tempDir 'never-created.json') -Candidate $reviewedCandidate -Now 'not-an-instant'
Assert-That ($badNowBeforeRegistry.reason -eq 'now-invalid-unusable') 'F5: the unusable -Now is refused before the registry is touched'

# ---------- G2: an explicit -Now $null is a supply, not an absence ----------
$nullNowPair=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $newer -FeatureId $featureId -Required $required -Now $null
Assert-That ([string]$nullNowPair.verdict -eq 'unavailable' -and [string]$nullNowPair.reason -eq 'now-invalid-unusable') 'G2: an explicit -Now $null fails closed in the pair verdict'
Assert-That ([string]$nullNowPair.timestamp_note -eq 'now-invalid-unusable' -and [string]$nullNowPair.generated_at -eq '') 'G2: -Now $null is reported as an unusable contract, never as absent'
$nullNowSuperseding=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required -Now $null
Assert-That ([string]$nullNowSuperseding.verdict -ne 'supersede-recommended') 'G2: records that would otherwise supersede cannot produce a recommendation through -Now $null'
$nullNowReview=Get-OrchestrationV2SupersessionReview -RegistryPath $f5Registry -Candidate $reviewedCandidate -Now $null
Assert-That ($nullNowReview.state -eq 'unavailable' -and $nullNowReview.recommendation -eq 'review-required' -and $nullNowReview.reason -eq 'now-invalid-unusable') 'G2: an explicit -Now $null fails closed in the registry review'
$absentNowReview=Get-OrchestrationV2SupersessionReview -RegistryPath $f5Registry -Candidate $reviewedCandidate
Assert-That ($absentNowReview.state -eq 'ok' -and $absentNowReview.recommendation -eq 'append-supersedes-recommended' -and $absentNowReview.timestamp_note -eq 'now-not-supplied') 'G2: an absent -Now still has no effect: the review decides normally'
$absentNowPair=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
Assert-That ([string]$absentNowPair.verdict -eq 'supersede-recommended' -and [string]$absentNowPair.timestamp_note -eq 'now-not-supplied') 'G2: an absent -Now still lets the records decide the pair verdict'

# ---------- R2: the aggregated recommendation is closed and deterministic ----------
$otherRecord=New-SupersessionRecord -At '2026-10-01T00:00:00Z' -Override @{feature_id='native-step-limits';scenario='native-step-limits-exact-binary'}
$noPriorReview=Invoke-Review -Path (New-SupersessionFile -Name 'other-only.json' -Records @($otherRecord,$otherRecord)) -Record $reviewedCandidate
Assert-That ($noPriorReview.state -eq 'ok' -and $noPriorReview.recommendation -eq 'no-prior-evidence') 'records of other identities only => no-prior-evidence'
Assert-That ($noPriorReview.reviewed_count -eq 0 -and $noPriorReview.ignored_count -eq 2 -and $noPriorReview.records_total -eq 2) 'records of other identities are ignored and counted'
Assert-That ($noPriorReview.summary['identity-mismatch'] -eq 0 -and $noPriorReview.verdicts.Count -eq 0) 'an ignored record never enters the summary or the verdicts'
$duplicateReview=Invoke-Review -Path (New-SupersessionFile -Name 'all-dup.json' -Records @($reviewedCandidate,$reviewedCandidate)) -Record $reviewedCandidate
Assert-That ($duplicateReview.recommendation -eq 'duplicate-no-op' -and $duplicateReview.summary['duplicate'] -eq 2 -and $duplicateReview.reviewed_count -eq 2) 'every reviewed record duplicate => duplicate-no-op'
Assert-That ($duplicateReview.verdicts -is [array] -and $duplicateReview.verdicts.Count -eq 2) 'a list of per-record verdicts stays an array'
$singleVerdictReview=Invoke-Review -Path (New-SupersessionFile -Name 'one-dup.json' -Records @($reviewedCandidate)) -Record $reviewedCandidate
Assert-That ($singleVerdictReview.verdicts -is [array] -and $singleVerdictReview.verdicts.Count -eq 1) 'a one-record review does not collapse the verdict list into a scalar'
$supersedeReview=Invoke-Review -Path (New-SupersessionFile -Name 'supersede.json' -Records @($proven,$otherRecord)) -Record $reviewedCandidate
Assert-That ($supersedeReview.recommendation -eq 'append-supersedes-recommended' -and $supersedeReview.summary['supersede-recommended'] -eq 1 -and $supersedeReview.ignored_count -eq 1) 'one supersede recommendation wins, other identities stay ignored'
$invalidExistingReview=Invoke-Review -Path (New-SupersessionFile -Name 'invalid-existing.json' -Records @((New-SupersessionRecord -At '2026-10-02T12:00:00Z' -By ('z'*400)))) -Record $reviewedCandidate
Assert-That ($invalidExistingReview.recommendation -eq 'review-required' -and $invalidExistingReview.summary['invalid-existing'] -eq 1) 'F1: an invalid existing record is impeditivo => review-required (never a positive recommendation)'
Assert-That ([string]$invalidExistingReview.verdicts[0].verdict -ceq 'invalid-existing' -and [string]$invalidExistingReview.verdicts[0].reason -ceq 'evidence-verifier-invalid') 'the invalid existing record carries the S1 kebab reason'
$mixedReview=Invoke-Review -Path (New-SupersessionFile -Name 'mixed.json' -Records @((New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'first-operator.tests.ps1'),(New-SupersessionRecord -At '2026-10-04T00:00:00Z' -By 'later-operator.tests.ps1'))) -Record $reviewedCandidate
Assert-That ($mixedReview.recommendation -eq 'review-required' -and $mixedReview.summary['ambiguous-same-instant'] -eq 1 -and $mixedReview.summary['stale-candidate'] -eq 1) 'a mixture without any supersede => review-required'

# ---------- F1: the aggregation precedence, every cited permutation with its own fixture ----------
$newerThanCandidate=New-SupersessionRecord -At '2026-10-05T00:00:00Z' -By 'later-operator.tests.ps1'
$ambiguousTwin=New-SupersessionRecord -At '2026-10-03T09:00:00Z' -By 'first-operator.tests.ps1'
$precedence=@(
    @{label='[older] alone';records=@($proven);recommendation='append-supersedes-recommended';supersede=1;duplicate=0;stale=0;ambiguous=0},
    @{label='[older, candidate-already-registered]';records=@($proven,$reviewedCandidate);recommendation='duplicate-no-op';supersede=1;duplicate=1;stale=0;ambiguous=0},
    @{label='[older, record-newer-than-candidate]';records=@($proven,$newerThanCandidate);recommendation='review-required';supersede=1;duplicate=0;stale=1;ambiguous=0},
    @{label='[older, supersede + stale mixed]';records=@($ambiguousTwin,$newerThanCandidate);recommendation='review-required';supersede=0;duplicate=0;stale=1;ambiguous=1},
    @{label='[older, supersede + duplicate]';records=@($proven,$reviewedCandidate,$otherRecord);recommendation='duplicate-no-op';supersede=1;duplicate=1;stale=0;ambiguous=0},
    @{label='[older, ambiguous in the middle]';records=@($proven,$ambiguousTwin,$reviewedCandidate);recommendation='review-required';supersede=1;duplicate=1;stale=0;ambiguous=1},
    @{label='[record-newer-than-candidate] alone';records=@($newerThanCandidate);recommendation='review-required';supersede=0;duplicate=0;stale=1;ambiguous=0},
    @{label='[candidate-already-registered] alone';records=@($reviewedCandidate);recommendation='duplicate-no-op';supersede=0;duplicate=1;stale=0;ambiguous=0}
)
$allPrecedenceCases=@()
for($index=0;$index -lt $precedence.Count;$index++){
    $case=$precedence[$index]
    $review=Invoke-Review -Path (New-SupersessionFile -Name ('prec-'+$index+'.json') -Records $case.records) -Record $reviewedCandidate
    $allPrecedenceCases+=$review
    Assert-That ([string]$review.recommendation -ceq $case.recommendation) ("F1 precedence: " + $case.label + " => " + $case.recommendation)
    Assert-That ([int]$review.summary['supersede-recommended'] -eq $case.supersede -and [int]$review.summary['duplicate'] -eq $case.duplicate -and [int]$review.summary['stale-candidate'] -eq $case.stale -and [int]$review.summary['ambiguous-same-instant'] -eq $case.ambiguous) ("F1 counters: " + $case.label)
    Assert-That ([int]$review.reviewed_count -eq ($case.supersede+$case.duplicate+$case.stale+$case.ambiguous)) ("F1 reviewed count: " + $case.label)
}
Assert-That (@($allPrecedenceCases|Where-Object{[string]$_.recommendation -ceq 'registry-has-invalid-records'}).Count -eq 0) 'F1: registry-has-invalid-records is retained in the vocabulary but never emitted'
Assert-That (@($allPrecedenceCases|Where-Object{-not ($closedRecommendations -contains [string]$_.recommendation)}).Count -eq 0) 'every emitted recommendation belongs to the closed set'
$summaryKeys=@($mixedReview.summary.Keys)
Assert-That (($summaryKeys -join ',') -ceq (($closedVerdicts) -join ',')) 'the summary carries every closed verdict key in a fixed order'
foreach($key in $closedVerdicts){Assert-That ($mixedReview.summary[$key] -is [int]) ("summary counter is an int: " + $key)}
$countedTotal=0
foreach($key in $closedVerdicts){$countedTotal+=[int]$mixedReview.summary[$key]}
Assert-That ($countedTotal -eq $mixedReview.reviewed_count -and ($mixedReview.reviewed_count + $mixedReview.ignored_count) -eq $mixedReview.records_total) 'summary counters, reviewed and ignored counts reconcile with the registry'
Assert-That ($mixedReview.max_records -eq 200 -and $closedRecommendations -contains [string]$mixedReview.recommendation) 'the review is bounded by the default contract bound and the recommendation is closed'

# a USABLE -Now is recorded and still never decides the aggregated recommendation
$nowReview=Invoke-Review -Path (New-SupersessionFile -Name 'supersede.json' -Records @($proven,$otherRecord)) -Record $reviewedCandidate
$stamped=Get-OrchestrationV2SupersessionReview -RegistryPath (Join-Path $tempDir 'supersede.json') -Candidate $reviewedCandidate -Now ([DateTime]'2026-10-05T00:00:00Z')
Assert-That ([string]$stamped.recommendation -ceq [string]$nowReview.recommendation -and [string]$stamped.generated_at -ceq '2026-10-05T00:00:00.0000000Z') 'a usable -Now is recorded in the decision record and never decides'

# ---------- D1: decision record only - the reviewer writes nothing anywhere ----------
$beforeListing=@(Get-ChildItem -LiteralPath $tempDir -Recurse -Force|ForEach-Object{$_.FullName.Substring($tempDir.Length)+':'+$_.Length}|Sort-Object)
$beforeSupersede=(Get-FileHash -LiteralPath (Join-Path $tempDir 'supersede.json') -Algorithm SHA256).Hash
$beforeRegistry=(Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash
$beforeFlags=(Get-FileHash -LiteralPath $flagsPath -Algorithm SHA256).Hash
$beforeDefaultExists=Test-Path -LiteralPath $defaultEvidencePath
foreach($path in @((Join-Path $tempDir 'mixed.json'),(Join-Path $tempDir 'all-dup.json'),(Join-Path $tempDir 'invalid-existing.json'),(Join-Path $tempDir 'garbage.json'))){
    [void](Invoke-Review -Path $path -Record $reviewedCandidate)
}
[void](Invoke-Review -Path (Join-Path $tempDir 'supersede.json') -Record $reviewedCandidate -Bound @{max_records=200;max_bytes=262144})
[void](Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required)
$afterListing=@(Get-ChildItem -LiteralPath $tempDir -Recurse -Force|ForEach-Object{$_.FullName.Substring($tempDir.Length)+':'+$_.Length}|Sort-Object)
Assert-That (($beforeListing -join '|') -ceq ($afterListing -join '|')) 'the reviewer adds, renames and removes nothing in the evidence directory'
Assert-That ((Get-FileHash -LiteralPath (Join-Path $tempDir 'supersede.json') -Algorithm SHA256).Hash -ceq $beforeSupersede) 'the reviewed registry bytes are untouched'
Assert-That ((Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash -ceq $beforeRegistry) 'the candidate registry bytes are untouched'
Assert-That ((Get-FileHash -LiteralPath $flagsPath -Algorithm SHA256).Hash -ceq $beforeFlags) 'capability flags are untouched'
Assert-That ((Test-Path -LiteralPath $defaultEvidencePath) -eq $beforeDefaultExists) 'the shipped evidence registry is not created by a review'
foreach($verdict in @($singleVerdictReview.verdicts[0],$mixedReview.verdicts[0],$supersedeReview.verdicts[0],$nullPair,$absentReview)){
    Assert-That ([bool]$verdict.decision_record_only -and [bool]$verdict.enables_nothing) 'every emitted record claims decision_record_only and enables_nothing'
}
$flags=ConvertFrom-Json ([IO.File]::ReadAllText($flagsPath))
Assert-That (($flags.runtime_support.v2 -eq $true) -and (-not $flags.capability_router.active) -and (-not $flags.capability_router.shadow)) 'the reviewer still enables nothing by itself: runtime v2 was activated in the registry (2026-10-04) and the capability router stays off'
Assert-That (([string]$registry.features.PSObject.Properties[$featureId].Value.status) -eq 'hold-unproven') 'a reviewed candidate keeps its declared hold-unproven status'
$libraryTextNow=[IO.File]::ReadAllText($libraryPath)
foreach($forbidden in @('WriteAllText','WriteAllBytes','FileMode]::Append','Out-File','Set-Content','Add-Content','New-Item','Remove-Item','Copy-Item','Move-Item','Delete','Rename-Item')){
    Assert-That ($libraryTextNow -notmatch [regex]::Escape($forbidden)) ("reviewer contains no writer token: " + $forbidden)
}
foreach($forbidden in @('Invoke-WebRequest','Invoke-RestMethod','Start-Process','System.Net','WebClient','HttpClient','New-PSSession','curl ','wget ')){
    Assert-That ($libraryTextNow -notmatch [regex]::Escape($forbidden)) ("reviewer contains no network/process token: " + $forbidden)
}
$gateSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1'))
Assert-That ($libraryTextNow -notmatch 'capability-flags\.json' -and $libraryTextNow -notmatch 'v2-native-capabilities\.json') 'the reviewer reads no registry or flag file by its own contract'

# ---------- S1: sanitized, bounded, deterministic output ----------
$canary='sk-SYNTHETICSECRET token=abc https://evil.example.com/path'
$hostileExisting=New-SupersessionRecord -At '2026-10-02T12:00:00Z' -Override @{verified_by=($canary+[char]7+[char]27+[char]11+('y'*5000))}
$hostileVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $hostileExisting -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
$hostileJson=ConvertTo-Json $hostileVerdict -Depth 6 -Compress
Assert-That ([string]$hostileVerdict.verdict -ceq 'invalid-existing' -and [string]$hostileVerdict.reason -ceq 'evidence-verifier-invalid') 'a hostile verifier id fails closed with the S1 reason'
Assert-That ($hostileJson -notmatch 'SYNTHETICSECRET|evil\.example|\babc\b|y{50}' -and $hostileJson -notmatch '[^\x20-\x7E]') 'no byte of the hostile verifier id reaches the verdict JSON'
$hostileFeatureVerdict=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId ($canary+('z'*300)) -Required $required
$hostileFeatureJson=ConvertTo-Json $hostileFeatureVerdict -Depth 6 -Compress
Assert-That ([string]$hostileFeatureVerdict.verdict -ceq 'unavailable' -and $hostileFeatureJson -notmatch 'SYNTHETICSECRET|evil\.example|z{50}') 'a hostile feature id never reaches the verdict'
$hostileReview=Invoke-Review -Path (New-SupersessionFile -Name 'hostile.json' -Records @((New-SupersessionRecord -At '2026-10-02T12:00:00Z' -Override @{verified_by=($canary+('y'*5000))}))) -Record $reviewedCandidate
$hostileReviewJson=ConvertTo-Json $hostileReview -Depth 8 -Compress
Assert-That ($hostileReviewJson -notmatch 'SYNTHETICSECRET|evil\.example|\babc\b|y{50}' -and $hostileReviewJson -notmatch '[^\x20-\x7E]') 'no byte of hostile registry content reaches the review JSON'
Assert-That ([string]$supersedeReview.registry_file -ceq 'supersede.json' -and [string]$supersedeReview.registry_file -notmatch '\\') 'only the leaf registry file name is echoed, never a host path'
Assert-That ([string]$mixedReview.verdicts[0].existing_record_hash -match '^[0-9a-f]{64}$' -and [string]$mixedReview.verdicts[0].candidate_record_hash -match '^[0-9a-f]{64}$') 'a genuine record digest is emitted in full as public record content (F4)'
$pairShape='verdict,reason,feature_id,existing_verified_at,candidate_verified_at,existing_record_hash,candidate_record_hash,decision_record_only,enables_nothing,generated_at,timestamp_note'
$reviewShape='state,reason,recommendation,feature_id,registry_file,candidate_verified_at,candidate_record_hash,candidate_reason,records_total,max_records,reviewed_count,ignored_count,summary,verdicts,decision_record_only,enables_nothing,generated_at,timestamp_note'
Assert-That ((@($supersedeReview.verdicts[0].PSObject.Properties.Name) -join ',') -ceq $pairShape) 'the pair verdict shape is fixed'
Assert-That ((@($supersedeReview.PSObject.Properties.Name) -join ',') -ceq $reviewShape) 'the review shape is fixed'
$first=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required -Now ([DateTime]'2026-10-05T00:00:00Z')
$second=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required -Now ([DateTime]'2026-10-05T00:00:00Z')
Assert-That ((ConvertTo-Json $first -Depth 6 -Compress) -ceq (ConvertTo-Json $second -Depth 6 -Compress)) 'identical inputs produce byte-identical verdict JSON'
$reviewFirst=Get-OrchestrationV2SupersessionReview -RegistryPath (Join-Path $tempDir 'mixed.json') -Candidate $reviewedCandidate -Now '2026-10-05T00:00:00Z'
$reviewSecond=Get-OrchestrationV2SupersessionReview -RegistryPath (Join-Path $tempDir 'mixed.json') -Candidate $reviewedCandidate -Now '2026-10-05T00:00:00Z'
Assert-That ((ConvertTo-Json $reviewFirst -Depth 8 -Compress) -ceq (ConvertTo-Json $reviewSecond -Depth 8 -Compress)) 'identical inputs produce byte-identical review JSON'
$noNow=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required
$badNow=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required -Now 'not-an-instant'
Assert-That ([string]$noNow.timestamp_note -ceq 'now-not-supplied' -and [string]$noNow.generated_at -eq '') 'an absent -Now is recorded as not supplied'
Assert-That ([string]$noNow.verdict -ceq [string]$first.verdict) 'an ABSENT -Now has no effect: the records still decide the verdict'
Assert-That ([string]$badNow.timestamp_note -ceq 'now-invalid-unusable' -and [string]$badNow.generated_at -eq '' -and [string]$badNow.verdict -ceq 'unavailable') 'an unusable -Now is refused and reported instead of being stamped'
$typedNow=Test-OrchestrationV2EvidenceSupersession -Existing $proven -Candidate $reviewedCandidate -FeatureId $featureId -Required $required -Now ([DateTimeOffset]'2026-10-05T00:00:00+02:00')
Assert-That ([string]$typedNow.timestamp_note -ceq 'now-does-not-decide' -and [string]$typedNow.generated_at -ceq '2026-10-04T22:00:00.0000000Z' -and [string]$typedNow.verdict -ceq [string]$first.verdict) 'a usable -Now is normalized, recorded and still never decides'

# ---------- contract: ASCII-only sources, honest HOLD documented ----------
foreach($file in @($libraryPath,(Join-Path $PSScriptRoot 'OrchestrationV2EvidenceSupersession.tests.ps1'),$registryPath)){
    $bytes=[IO.File]::ReadAllBytes($file)
    Assert-That (@($bytes|Where-Object{$_ -gt 127}).Count -eq 0) ("ASCII-only: " + [IO.Path]::GetFileName($file))
}
$help=Get-Help (Resolve-Path $libraryPath)
$description=[string](($help.Description.Text) -join ' ')
$normalized=($description -replace '\s+',' ')
Assert-That ($normalized -match 'DECISION RECORD' -and $normalized -match 'never mutated' -and $normalized -match 'fail-closed' -and $normalized -match 'operator') 'synopsis documents the decision-record posture, the read-only contract and the operator-owned decision'
Assert-That ($normalized -match 'supersede-recommended' -and $normalized -match 'ambiguous-same-instant' -and $normalized -match 'tie-break') 'synopsis documents the closed verdict set'

} finally {
    try {[IO.Directory]::Delete($tempDir,$true)} catch {}
}

Write-Output "PASS: $passed assertions"