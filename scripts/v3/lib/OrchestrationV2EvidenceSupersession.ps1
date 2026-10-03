<#
.SYNOPSIS
    Deterministic supersession reviewer for V2 native evidence records (P40 slice 2).
.DESCRIPTION
    Honest slice, same posture as the P40 S1 gating library: a review is a DECISION
    RECORD and nothing else. The append-only evidence registry is never mutated by this
    library, no capability flag is ever touched and no feature can leave its declared
    hold-unproven state because of anything computed here. Test-OrchestrationV2EvidenceSupersession
    answers exactly one question - how does a newly produced record relate to a record
    already in the registry - and Get-OrchestrationV2SupersessionReview answers the same
    question for every record of the registry. The append-or-supersede decision remains
    the operator's; this library only makes the relation observable and reproducible.

    Test-OrchestrationV2EvidenceSupersession returns one verdict from a closed set:
      - duplicate: the same canonical digest, so re-appending would be a no-op;
      - supersede-recommended: same evidence identity and the candidate instant is
        STRICTLY newer than the existing one, both records individually proven;
      - stale-candidate: same identity, candidate instant strictly older;
      - ambiguous-same-instant: same identity, same instant, divergent content. This is
        fail-closed on purpose: equal instants are never resolved by a tie-break;
      - identity-mismatch: the two records are different evidence slots (feature_id,
        type, runtime, pin or scenario diverge under ORDINAL comparison), so this is not a
        supersession case at all;
      - invalid-existing / invalid-candidate: the record does not prove anything, with
        the S1 reader's own kebab reason echoed verbatim;
      - unavailable: no decision could be formed (the gating library is not loadable, the
        caller contract is unusable, or an explicitly supplied -Now is not a proven
        instant). Never an exception.

    Ordering is decided ONLY by the two records' own instants, normalized by the S1 helper
    ConvertTo-OrchestrationV2NativeUtcStamp. -Now is recorded and never decides; an absent
    -Now has no effect, and an explicitly supplied unusable -Now fails closed. Identity is
    compared with [string]::Equals(...,Ordinal), so neither a locale nor an ignorable code
    point can reorder, fold or merge two evidence slots.

    Every record is validated individually by the S1 reader
    (Get-OrchestrationV2NativeRecordReason), which this library dot-sources lazily and
    read-only. With the reader absent nothing about the submitted records is trusted or
    echoed: the result carries the closed verdict and reason only.

    Get-OrchestrationV2SupersessionReview loads the registry through the S1 reader and is
    fail-closed on the registry as a whole: absent or unreadable registry is never
    reviewed over. Records of other identities are ignored and counted, never reviewed.
    The candidate is validated ONCE up front, so an unprovable candidate is reported as
    such instead of hiding behind 'no-prior-evidence'. The aggregated recommendation is
    descriptive and closed, and its precedence is fixed so that impeditivo evidence always
    wins: review-required (any ambiguous-same-instant / invalid-existing / invalid-candidate
    / unjudged pair), else duplicate-no-op, else append-supersedes-recommended (at least
    one supersede and no stale), else review-required (stale), else no-prior-evidence.

    Identity is compared ORDINALLY. A culture-sensitive comparison ignores code points the
    collation drops - a soft hyphen (U+00AD) is ignored on both supported engines - which
    would merge two different evidence slots. record_hash is echoed only when it really is
    64 hex characters (anchored \A...\z, normalized lowercase) and never as truncated
    arbitrary text. An explicitly supplied but unusable -Now fails closed before any
    record is compared, and -Now $null counts as supplied, not as absent.

    Structured reasons: gating-library-unavailable, feature-id-invalid,
    required-evidence-invalid, now-invalid-unusable, candidate-evidence-invalid,
    candidate-feature-id-invalid, candidate-identity-undecidable,
    evidence-identity-divergent, identical-evidence-record,
    candidate-instant-strictly-newer, candidate-instant-older,
    identical-instant-divergent-content, internal-error, plus every evidence-* reason
    produced by the S1 record reader.
#>
[CmdletBinding()]
param()

# Lazy, guarded load of the S1 gating library: only read, and only when its functions are
# not already present. The guard runs at script scope on purpose - a dot-source executed
# inside a function would drop the loaded functions when that function returned.
$gatingLibraryPath=Join-Path $PSScriptRoot 'OrchestrationV2NativeGating.ps1'
if(-not (Get-Command -Name 'Get-OrchestrationV2NativeRecordReason' -CommandType Function -ErrorAction SilentlyContinue)){
    if(Test-Path -LiteralPath $gatingLibraryPath -PathType Leaf){. $gatingLibraryPath}
}

$script:OrchestrationV2SupersessionIdentityFields=@('feature_id','type','runtime','pin','scenario')
$script:OrchestrationV2SupersessionVerdicts=@('duplicate','supersede-recommended','stale-candidate','ambiguous-same-instant','identity-mismatch','invalid-existing','invalid-candidate','unavailable')
$script:OrchestrationV2SupersessionRecommendations=@('no-prior-evidence','duplicate-no-op','append-supersedes-recommended','registry-has-invalid-records','review-required')
$script:OrchestrationV2SupersessionRequiredHelpers=@('Get-OrchestrationV2NativeRecordReason','Get-OrchestrationV2NativeEvidenceRegistry','Get-OrchestrationV2NativeEvidenceHash','ConvertTo-OrchestrationV2NativeUtcStamp','ConvertTo-OrchestrationV2NativeSafeText','Get-OrchestrationV2NativeValue','Get-OrchestrationV2NativeBound')

function Test-OrchestrationV2SupersessionGatingAvailable {
    <#
    .SYNOPSIS
        True only when every S1 helper this reviewer depends on is actually resolvable.
    .DESCRIPTION
        Fail-closed capability probe, checked per call instead of trusted from load time:
        a partially loaded reader must never be used, and its absence must degrade to the
        'unavailable' verdict rather than to a raw error.
    #>
    [CmdletBinding()]
    param()
    foreach($name in $script:OrchestrationV2SupersessionRequiredHelpers){
        if($null -eq (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)){return $false}
    }
    return $true
}

function ConvertTo-OrchestrationV2SupersessionSafeText {
    <#
    .SYNOPSIS
        Redact and bound one free-text value; '' whenever the S1 sanitizer is unreachable.
    .DESCRIPTION
        The S1 sanitizer is the single redaction policy in this family, so it is reused
        instead of copied. When it is not loadable the safe answer is to echo nothing:
        an unavailable reviewer must not become a channel for untrusted record text.
    #>
    [CmdletBinding()]
    param($Value,[int]$MaxLength=120)
    if($null -eq $Value){return ''}
    if($Value -isnot [string]){return ''}
    if(-not (Test-OrchestrationV2SupersessionGatingAvailable)){return ''}
    try{return [string](ConvertTo-OrchestrationV2NativeSafeText ([string]$Value) $MaxLength)}catch{return ''}
}

function Get-OrchestrationV2SupersessionStamp {
    <#
    .SYNOPSIS
        Normalized UTC round-trip instant of a record field, or '' when it is not one.
    .DESCRIPTION
        Delegates entirely to the S1 instant helper, so a wall-clock time, a bare date, a
        numeric stamp and a Kind Unspecified value are all rejected here exactly as they
        are inside the gate. The normalized form has a fixed shape (UTC round-trip with
        seven fractional digits), so ordinal string comparison over it is an exact
        chronological comparison - no locale, no host time zone, no parser divergence.
    #>
    [CmdletBinding()]
    param($Record)
    if($null -eq $Record){return ''}
    try{
        $raw=Get-OrchestrationV2NativeValue $Record 'verified_at' $null
        if($null -eq $raw){return ''}
        return [string](ConvertTo-OrchestrationV2NativeUtcStamp $raw)
    }catch{return ''}
}

function Get-OrchestrationV2SupersessionIdentity {
    <#
    .SYNOPSIS
        The record's evidence identity, or $null when it cannot be read structurally.
    .DESCRIPTION
        Identity is the five fields that name the evidence slot: feature_id, type,
        runtime, pin and scenario. A field that is absent, not exactly [string] or blank
        makes the identity undecidable; undecidable is not "different", so the caller must
        fall through to the per-record reader, whose kebab reason then reports the real
        shape failure instead of a fabricated identity divergence.
    #>
    [CmdletBinding()]
    param($Record)
    if($null -eq $Record){return $null}
    $identity=[ordered]@{}
    foreach($field in $script:OrchestrationV2SupersessionIdentityFields){
        $value=Get-OrchestrationV2NativeValue $Record $field $null
        if($value -isnot [string]){return $null}
        if([string]::IsNullOrWhiteSpace($value)){return $null}
        $identity[$field]=[string]$value
    }
    return [pscustomobject]$identity
}

function Test-OrchestrationV2SupersessionIdentityDiverges {
    <#
    .SYNOPSIS
        True only when both identities are decodable and differ under ORDINAL comparison.
    .DESCRIPTION
        Ordinal, not '-cne': '-cne' is a CULTURE-sensitive comparison, so it treats two
        different slots as one whenever the culture collation ignores a code point between
        them - a soft hyphen (U+00AD) is ignored by the default collation on both supported
        engines, which would silently merge "scenario" with "scenario + U+00AD" and let a
        record address the wrong evidence slot. Identity is an opaque slot name, so no
        culture rule, weight or ignorable code point may decide it.

        $null (undecidable) is reported as "does not diverge", so the caller validates the
        records instead of inventing a verdict.
    #>
    [CmdletBinding()]
    param($ExistingIdentity,$CandidateIdentity)
    if($null -eq $ExistingIdentity -or $null -eq $CandidateIdentity){return $false}
    foreach($field in $script:OrchestrationV2SupersessionIdentityFields){
        $same=[string]::Equals([string]$ExistingIdentity.$field,[string]$CandidateIdentity.$field,[StringComparison]::Ordinal)
        if(-not $same){return $true}
    }
    return $false
}

function Test-OrchestrationV2SupersessionRequired {
    <#
    .SYNOPSIS
        True when the requirement carries the three string fields the S1 reader needs.
    .DESCRIPTION
        Read through the S1 accessor on purpose, so this check agrees with the gate it
        feeds: whatever the S1 reader would treat as a string here is a string there, and
        the reviewer can never disagree with Get-OrchestrationV2NativeRecordReason about
        the same record.
    #>
    [CmdletBinding()]
    param($Required)
    if($null -eq $Required){return $false}
    if(-not ($Required -is [System.Collections.IDictionary])){return $false}
    foreach($field in @('runtime','pin','scenario')){
        $value=Get-OrchestrationV2NativeValue $Required $field $null
        if($value -isnot [string]){return $false}
        if([string]::IsNullOrWhiteSpace($value)){return $false}
    }
    return $true
}

function ConvertTo-OrchestrationV2SupersessionDigest {
    <#
    .SYNOPSIS
        The record's digest when it really is one (64 hex, lowercased), else ''.
    .DESCRIPTION
        Text sanitization proves nothing about a digest: bounding an arbitrary hostile
        string to 64 characters would let arbitrary text be echoed from a field the
        consumer reads as a sha256. The declared value must therefore match the closed
        digest shape and nothing else is emitted - never a truncated value, never a
        partially redacted one. The shape is anchored with \A...\z and NOT with ^...$: in
        .NET '$' also matches immediately BEFORE a trailing newline, so a 64-hex string
        followed by LF would pass a '^...$' anchor and be echoed carrying a line break.
        Hex case is normalized because it is not security-relevant, which is the same rule
        the S1 reader applies when it verifies the digest.
    #>
    [CmdletBinding()]
    param($Record)
    if($null -eq $Record){return ''}
    if(-not (Test-OrchestrationV2SupersessionGatingAvailable)){return ''}
    try{
        $raw=Get-OrchestrationV2NativeValue $Record 'record_hash' $null
        if($raw -isnot [string]){return ''}
        if(([string]$raw) -cnotmatch '\A[0-9a-fA-F]{64}\z'){return ''}
        return ([string]$raw).ToLowerInvariant()
    }catch{return ''}
}

function Get-OrchestrationV2SupersessionNow {
    <#
    .SYNOPSIS
        {stamp, note, unusable} for an injected -Now; every value comes from a closed set.
    .DESCRIPTION
        -Now exists so a caller can stamp a decision record reproducibly, and it never
        decides: the verdict comes from the two records' own instants. An ABSENT -Now is
        simply absent and has no effect at all. An EXPLICITLY supplied -Now that is not a
        proven instant is a broken caller contract, so 'unusable' is reported and both
        entry points fail closed on it before touching the records: a decision record
        stamped with a value nobody can interpret must not carry a positive
        recommendation. Supplying -Now with $null is an explicit supply of no instant, not
        an absence: the caller named the parameter, so the contract is broken and the same
        fail-closed rule applies. The note vocabulary is closed: now-not-supplied,
        now-not-evaluated, now-does-not-decide, now-invalid-unusable.
    #>
    [CmdletBinding()]
    param($Now,[bool]$Supplied)
    if(-not $Supplied){return [pscustomobject]@{stamp='';note='now-not-supplied';unusable=$false}}
    if(-not (Test-OrchestrationV2SupersessionGatingAvailable)){return [pscustomobject]@{stamp='';note='now-not-evaluated';unusable=$false}}
    try{
        $stamp=[string](ConvertTo-OrchestrationV2NativeUtcStamp $Now)
    }catch{$stamp=''}
    if($stamp){return [pscustomobject]@{stamp=$stamp;note='now-does-not-decide';unusable=$false}}
    return [pscustomobject]@{stamp='';note='now-invalid-unusable';unusable=$true}
}

function ConvertTo-OrchestrationV2SupersessionFeatureId {
    <#
    .SYNOPSIS
        The echoed feature name: redacted, then reduced to the closed name charset.
    .DESCRIPTION
        Redaction runs FIRST so no substring of a hostile value survives into a
        transformation that merely renames its characters; the neutralization then mirrors
        the S1 gate's own rendering of a rejected name (anything outside [a-z0-9-] becomes
        '-'), which is also why a hostile value can never carry a path separator into the
        decision record. A closed name passes through unchanged.
    #>
    [CmdletBinding()]
    param($FeatureId)
    if($null -eq $FeatureId){return ''}
    if($FeatureId -isnot [string]){return ''}
    if([string]::IsNullOrWhiteSpace($FeatureId)){return ''}
    $redacted=ConvertTo-OrchestrationV2SupersessionSafeText $FeatureId 240
    if([string]::IsNullOrWhiteSpace($redacted)){return ''}
    $neutral=($redacted.ToLowerInvariant() -replace '[^a-z0-9-]','-')
    if($neutral.Length -gt 64){$neutral=$neutral.Substring(0,64)}
    return $neutral
}

function New-OrchestrationV2SupersessionVerdict {
    <#
    .SYNOPSIS
        The fixed-shape, sanitized, ordered pair verdict returned by the reviewer.
    .DESCRIPTION
        Shape and order are fixed so identical inputs serialize byte-identically. Every
        free-text field passes the S1 sanitizer and is bounded. Both digests are emitted
        only when they match the closed 64-hex shape, normalized lowercase, and are ''
        otherwise: a record digest is public record content, so it is never redacted, but
        an arbitrary string in a record_hash field is never echoed as if it were a digest.
        decision_record_only and enables_nothing are literal claims about this library,
        asserted by its own suite.
    #>
    [CmdletBinding()]
    param([string]$Verdict,[string]$Reason,$FeatureId,$Existing,$Candidate,$Stamp,$Now,[bool]$NowSupplied)
    $existingHash=(ConvertTo-OrchestrationV2SupersessionDigest $Existing)
    $candidateHash=(ConvertTo-OrchestrationV2SupersessionDigest $Candidate)
    $now=(Get-OrchestrationV2SupersessionNow -Now $Now -Supplied $NowSupplied)
    return [pscustomobject][ordered]@{
        verdict=$Verdict
        reason=$Reason
        feature_id=(ConvertTo-OrchestrationV2SupersessionFeatureId $FeatureId)
        existing_verified_at=$Stamp.existing
        candidate_verified_at=$Stamp.candidate
        existing_record_hash=$existingHash
        candidate_record_hash=$candidateHash
        decision_record_only=$true
        enables_nothing=$true
        generated_at=$now.stamp
        timestamp_note=$now.note
    }
}

function Test-OrchestrationV2EvidenceSupersession {
    <#
    .SYNOPSIS
        Classify how one candidate evidence record relates to one existing record.
    .DESCRIPTION
        Closed and fail-closed; no input can produce an open verdict and no input can make
        this function decide to append, supersede or enable anything.

        Order of evaluation, deliberate and documented:
          1. the S1 reader must be loadable, else 'unavailable';
          2. -FeatureId must be a closed feature name and -Required must carry runtime,
             pin and scenario, else 'unavailable' (a caller contract failure is not a
             verdict about the records);
          3. an EXPLICITLY supplied but unusable -Now is a broken caller contract too, so
             it fails closed with 'now-invalid-unusable' BEFORE any record is inspected.
             An absent -Now has no effect: it never decides either way, and -Now $null is
             an explicit supply of no instant, not an absence;
          4. structurally readable and DIFFERENT identities are 'identity-mismatch', under
             ORDINAL comparison: the two records are different evidence slots, so no
             supersession question exists. An undecidable identity is NOT treated as
             different - it falls through to step 5, where the S1 reader reports the real
             shape failure;
          5. each record is then validated individually by the S1 reader, existing first,
             and the reader's own kebab reason is echoed under 'invalid-existing' /
             'invalid-candidate';
          6. with both records proven, an identical canonical digest is 'duplicate'
             (re-appending is a no-op); otherwise the normalized instants decide, and an
             equal instant is 'ambiguous-same-instant' - never resolved by a tie-break.

        Reading 'existing' before 'candidate' is a stable choice for a pair where both are
        broken: the older slot's defect is reported first. The whole body is wrapped so an
        unexpected failure degrades to 'unavailable'/'internal-error' instead of throwing.
    #>
    [CmdletBinding()]
    param(
        $Existing,
        $Candidate,
        [string]$FeatureId,
        $Required,
        $Now
    )
    # Present means the caller named the parameter. A supplied $null is an explicit
    # supply of no instant, which is a broken contract - not an absence - so the
    # fail-closed rule below applies to it exactly as to any unparsable value.
    $nowSupplied=$PSBoundParameters.ContainsKey('Now')
    try{
        if(-not (Test-OrchestrationV2SupersessionGatingAvailable)){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'unavailable' -Reason 'gating-library-unavailable' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp ([pscustomobject]@{existing='';candidate=''}) -Now $Now -NowSupplied $nowSupplied)
        }
        if([string]::IsNullOrWhiteSpace($FeatureId) -or $FeatureId -cnotmatch '^[a-z0-9][a-z0-9-]{2,63}$'){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'unavailable' -Reason 'feature-id-invalid' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp ([pscustomobject]@{existing='';candidate=''}) -Now $Now -NowSupplied $nowSupplied)
        }
        if(-not (Test-OrchestrationV2SupersessionRequired $Required)){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'unavailable' -Reason 'required-evidence-invalid' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp ([pscustomobject]@{existing='';candidate=''}) -Now $Now -NowSupplied $nowSupplied)
        }
        if((Get-OrchestrationV2SupersessionNow -Now $Now -Supplied $nowSupplied).unusable){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'unavailable' -Reason 'now-invalid-unusable' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp ([pscustomobject]@{existing='';candidate=''}) -Now $Now -NowSupplied $nowSupplied)
        }
        $stamp=[pscustomobject]@{existing=(Get-OrchestrationV2SupersessionStamp $Existing);candidate=(Get-OrchestrationV2SupersessionStamp $Candidate)}
        # Ordinal identity first: two different slots never reach the record comparison.
        if(Test-OrchestrationV2SupersessionIdentityDiverges -ExistingIdentity (Get-OrchestrationV2SupersessionIdentity $Existing) -CandidateIdentity (Get-OrchestrationV2SupersessionIdentity $Candidate)){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'identity-mismatch' -Reason 'evidence-identity-divergent' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
        }
        $existingReason=[string](Get-OrchestrationV2NativeRecordReason -Record $Existing -FeatureId $FeatureId -Required $Required)
        if($existingReason){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'invalid-existing' -Reason $existingReason -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
        }
        $candidateReason=[string](Get-OrchestrationV2NativeRecordReason -Record $Candidate -FeatureId $FeatureId -Required $Required)
        if($candidateReason){
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'invalid-candidate' -Reason $candidateReason -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
        }
        # Both records are proven, so both identities are decodable and equal here.
        $existingHash=[string](Get-OrchestrationV2NativeValue $Existing 'record_hash' $null)
        $candidateHash=[string](Get-OrchestrationV2NativeValue $Candidate 'record_hash' $null)
        if($existingHash -ine $candidateHash){
            $order=[string]::CompareOrdinal($stamp.candidate,$stamp.existing)
            if($order -gt 0){
                return (New-OrchestrationV2SupersessionVerdict -Verdict 'supersede-recommended' -Reason 'candidate-instant-strictly-newer' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
            }
            if($order -lt 0){
                return (New-OrchestrationV2SupersessionVerdict -Verdict 'stale-candidate' -Reason 'candidate-instant-older' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
            }
            return (New-OrchestrationV2SupersessionVerdict -Verdict 'ambiguous-same-instant' -Reason 'identical-instant-divergent-content' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
        }
        # Identical canonical digest means identical content, so the instants agree by
        # construction; re-appending the candidate would be a no-op.
        return (New-OrchestrationV2SupersessionVerdict -Verdict 'duplicate' -Reason 'identical-evidence-record' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp $stamp -Now $Now -NowSupplied $nowSupplied)
    }catch{
        return (New-OrchestrationV2SupersessionVerdict -Verdict 'unavailable' -Reason 'internal-error' -FeatureId $FeatureId -Existing $Existing -Candidate $Candidate -Stamp ([pscustomobject]@{existing='';candidate=''}) -Now $Now -NowSupplied $nowSupplied)
    }
}

function New-OrchestrationV2SupersessionReview {
    <#
    .SYNOPSIS
        The fixed-shape, sanitized, ordered registry review returned to the caller.
    .DESCRIPTION
        'summary' always carries every closed verdict key (zero when unused) so a consumer
        never has to probe for a missing counter, and 'verdicts' is always an array - a
        single per-record verdict is never collapsed into a scalar. Only the leaf file name
        of the registry is echoed: a full path would embed the host layout into a decision
        record. decision_record_only and enables_nothing are literal claims, asserted by the
        suite that inventories the registry bytes before and after this library runs.
    #>
    [CmdletBinding()]
    param(
        [string]$State,
        [string]$Reason,
        [string]$Recommendation,
        [string]$FeatureId,
        [string]$RegistryFile,
        $Candidate,
        [int]$RecordsTotal=0,
        [int]$MaxRecords=200,
        [int]$ReviewedCount=0,
        [int]$IgnoredCount=0,
        $Summary,
        $Verdicts,
        [string]$CandidateReason='',
        $Now,
        [bool]$NowSupplied
    )
    $candidateHash=''
    $candidateStamp=''
    if((Test-OrchestrationV2SupersessionGatingAvailable) -and $null -ne $Candidate){
        $candidateHash=(ConvertTo-OrchestrationV2SupersessionDigest $Candidate)
        $candidateStamp=(Get-OrchestrationV2SupersessionStamp $Candidate)
    }
    $now=(Get-OrchestrationV2SupersessionNow -Now $Now -Supplied $NowSupplied)
    return [pscustomobject][ordered]@{
        state=$State
        reason=$Reason
        recommendation=$Recommendation
        feature_id=(ConvertTo-OrchestrationV2SupersessionFeatureId $FeatureId)
        registry_file=(ConvertTo-OrchestrationV2SupersessionSafeText $RegistryFile 120)
        candidate_verified_at=$candidateStamp
        candidate_record_hash=$candidateHash
        candidate_reason=(ConvertTo-OrchestrationV2SupersessionSafeText $CandidateReason 64)
        records_total=$RecordsTotal
        max_records=$MaxRecords
        reviewed_count=$ReviewedCount
        ignored_count=$IgnoredCount
        summary=$Summary
        verdicts=$Verdicts
        decision_record_only=$true
        enables_nothing=$true
        generated_at=$now.stamp
        timestamp_note=$now.note
    }
}

function Get-OrchestrationV2SupersessionReview {
    <#
    .SYNOPSIS
        Review a candidate evidence record against every record of the append-only registry.
    .DESCRIPTION
        Fail-closed on the registry as a whole: an absent, unreadable, oversize or
        schema-invalid registry is never reviewed over, and neither is an unusable
        candidate whose evidence identity cannot even be named. The registry is loaded
        through the S1 reader with the caller's contract (max_bytes / max_records), and the
        review itself is bounded by the same max_records (default 200), so a hostile
        registry cannot turn this into an unbounded loop.

        The requirement each record is judged against is taken from the CANDIDATE itself.
        That is the supersession question - "is this prior record the same proven evidence
        slot as this candidate" - and it is deliberately not the feature gate's job, which
        stays with Get-OrchestrationV2NativeFeature and its declared requirement.

        Records whose identity differs from the candidate's are not supersession cases:
        they are ignored and counted, never reviewed. Everything else is reviewed one by
        one through Test-OrchestrationV2EvidenceSupersession and counted by verdict.

        The candidate itself is validated ONCE, up front, with the S1 reader, and the
        review fails closed when it does not prove anything: an unprovable candidate is
        never reported as 'no-prior-evidence' merely because the registry holds no record
        of its identity - the invalidity is the answer.

        The aggregated recommendation is descriptive and closed. Precedence is fixed and
        IMPEDITIVE evidence always wins, so no positive recommendation can ever be reached
        while the review still holds something a human must look at:
          1. any ambiguous-same-instant / invalid-existing / invalid-candidate
                                                   -> review-required;
          2. else any duplicate    -> duplicate-no-op (the candidate is already in the
                                      append-only registry, so appending is a no-op);
          3. else >=1 supersede-recommended AND no stale-candidate
                                                   -> append-supersedes-recommended;
          4. else any stale-candidate (without supersede) -> review-required (an obsolete
                                      candidate earns no positive recommendation);
          5. else, nothing of the candidate's identity -> no-prior-evidence.

        'registry-has-invalid-records' stays in the closed vocabulary so existing consumers
        keep parsing, but the precedence above never emits it: impeditivos always resolve
        to 'review-required'. The suite asserts that invariant.

        None of these is an action: appending, superseding and enabling stay with the
        operator, and the review writes nothing anywhere.
    #>
    [CmdletBinding()]
    param(
        [string]$RegistryPath='',
        $Candidate,
        $Contract,
        $Now
    )
    # Same rule as the pair function: a supplied -Now $null is a broken contract, not an
    # absence. The loop below forwards -Now only when the caller actually supplied it.
    $nowSupplied=$PSBoundParameters.ContainsKey('Now')
    $noVerdicts=@()
    try{
        $summary=[ordered]@{}
        foreach($verdict in $script:OrchestrationV2SupersessionVerdicts){$summary[$verdict]=0}
        if(-not (Test-OrchestrationV2SupersessionGatingAvailable)){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'gating-library-unavailable' -Recommendation 'review-required' -FeatureId '' -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        if((Get-OrchestrationV2SupersessionNow -Now $Now -Supplied $nowSupplied).unusable){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'now-invalid-unusable' -Recommendation 'review-required' -FeatureId '' -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        if($null -eq $Candidate){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'candidate-identity-undecidable' -Recommendation 'review-required' -FeatureId '' -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        $featureId=[string](Get-OrchestrationV2NativeValue $Candidate 'feature_id' $null)
        if([string]::IsNullOrWhiteSpace($featureId) -or $featureId -cnotmatch '^[a-z0-9][a-z0-9-]{2,63}$'){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'candidate-feature-id-invalid' -Recommendation 'review-required' -FeatureId $featureId -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        $identity=Get-OrchestrationV2SupersessionIdentity $Candidate
        if($null -eq $identity){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'candidate-identity-undecidable' -Recommendation 'review-required' -FeatureId $featureId -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        $required=@{runtime=[string]$identity.runtime;pin=[string]$identity.pin;scenario=[string]$identity.scenario}
        # The candidate is judged once, before the registry is even opened: an unprovable
        # candidate IS the answer, whatever the registry happens to hold.
        $candidateReason=[string](Get-OrchestrationV2NativeRecordReason -Record $Candidate -FeatureId $featureId -Required $required)
        if($candidateReason){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'candidate-evidence-invalid' -Recommendation 'review-required' -FeatureId $featureId -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -CandidateReason $candidateReason -Now $Now -NowSupplied $nowSupplied)
        }
        $registry=Get-OrchestrationV2NativeEvidenceRegistry -Path $RegistryPath -Contract $Contract
        $registryFile=''
        try{
            $registryFullPath=[string]$registry.path
            if(-not [string]::IsNullOrWhiteSpace($registryFullPath)){$registryFile=[IO.Path]::GetFileName($registryFullPath)}
        }catch{$registryFile=''}
        if([string]$registry.state -cne 'ok'){
            return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason ([string]$registry.reason) -Recommendation 'review-required' -FeatureId $featureId -RegistryFile $registryFile -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
        }
        $maxRecords=Get-OrchestrationV2NativeBound (Get-OrchestrationV2NativeValue $Contract 'max_records' $null) 200 1 1000
        $records=@($registry.records)
        $recordsTotal=$records.Count
        $verdicts=@()
        $reviewed=0
        $ignored=0
        $cursor=0
        foreach($record in $records){
            if($cursor -ge $maxRecords){break}
            $cursor++
            $verdict=$null
            # Forward -Now only when the caller actually supplied it: passing an absent
            # -Now as $null would look like an explicit supply down here and fail closed
            # for the wrong reason.
            if($nowSupplied){
                $verdict=(Test-OrchestrationV2EvidenceSupersession -Existing $record -Candidate $Candidate -FeatureId $featureId -Required $required -Now $Now)
            }else{
                $verdict=(Test-OrchestrationV2EvidenceSupersession -Existing $record -Candidate $Candidate -FeatureId $featureId -Required $required)
            }
            if([string]$verdict.verdict -ceq 'identity-mismatch'){
                # Another evidence slot entirely: not a supersession case, so it is
                # counted as ignored and never enters the summary or the verdicts.
                $ignored++
                continue
            }
            $reviewed++
            if($summary.Contains($verdict.verdict)){$summary[$verdict.verdict]=[int]$summary[$verdict.verdict]+1}
            $verdicts+=@($verdict)
        }
        # Precedence (see the synopsis). Impeditive evidence wins unconditionally, so a
        # positive recommendation is unreachable while anything here needs a human. A pair
        # that could not be judged at all ('unavailable') is impeditivo too: an internal
        # failure must never resolve into a positive recommendation. 'reviewed -eq 0' is
        # checked first because every counter is then zero, so rules 1-4 cannot fire.
        $impeditive=([int]$summary['ambiguous-same-instant'] -gt 0) -or ([int]$summary['invalid-existing'] -gt 0) -or ([int]$summary['invalid-candidate'] -gt 0) -or ([int]$summary['unavailable'] -gt 0)
        $recommendation='review-required'
        if($reviewed -eq 0){
            $recommendation='no-prior-evidence'
        }elseif($impeditive){
            $recommendation='review-required'
        }elseif([int]$summary['duplicate'] -gt 0){
            $recommendation='duplicate-no-op'
        }elseif([int]$summary['supersede-recommended'] -gt 0 -and [int]$summary['stale-candidate'] -eq 0){
            $recommendation='append-supersedes-recommended'
        }else{
            # Stale evidence with no supersession to act on, or any mixture left over.
            $recommendation='review-required'
        }
        return (New-OrchestrationV2SupersessionReview -State 'ok' -Reason '' -Recommendation $recommendation -FeatureId $featureId -RegistryFile $registryFile -Candidate $Candidate -RecordsTotal $recordsTotal -MaxRecords $maxRecords -ReviewedCount $reviewed -IgnoredCount $ignored -Summary $summary -Verdicts $verdicts -Now $Now -NowSupplied $nowSupplied)
    }catch{
        return (New-OrchestrationV2SupersessionReview -State 'unavailable' -Reason 'internal-error' -Recommendation 'review-required' -FeatureId '' -RegistryFile '' -Candidate $Candidate -Summary $summary -Verdicts $noVerdicts -Now $Now -NowSupplied $nowSupplied)
    }
}