<#
.SYNOPSIS
    Data-driven gating for candidate OpenCode V2 native capabilities (P40, plan section 17).
.DESCRIPTION
    Honest slice: the gating MECHANISM is real and data-driven, and NOT ONE feature is
    active. Every candidate in source/registry/v2-native-capabilities.json ships as
    status hold-unproven and can only leave that state through a valid exact-binary-live
    evidence record written by the validation slice (operator / P42). A declaration in
    the registry is NEVER an enabler (plan 17.10: do not enable a feature if exact-binary
    behavior is not proven).

    Get-OrchestrationV2NativeFeature is fail-closed end to end: a missing, unreadable,
    oversized, malformed or ambiguous evidence registry leaves every candidate
    NOT_PROVEN. There is no partial credit and no implicit default.

    An evidence record is accepted only when all of these hold, each divergence
    returning a distinct structured reason:
      - every declared field is present and exactly [string] (no numeric or bool
        coercion, so a pin can never be reformatted by a locale);
      - feature_id matches the queried candidate;
      - type is exactly 'exact-binary-live', runtime exactly 'v2', pin exactly the
        registry pin (2.0.18) and scenario exactly the declared required_evidence
        scenario;
      - verified_at is an instant with an explicit offset (RFC3339 text with 'Z' or
        +/-HH:MM, or a parsed DateTimeOffset/non-Unspecified DateTime) that normalizes to
        UTC with an explicit 'Z', and verified_by is a closed test-id charset; a wall-clock
        time without offset, a bare date and a Kind Unspecified value are rejected;
      - record_hash is 64 hex characters matching the sha256 of the canonical record
        content, with verified_at normalized to UTC round-trip form (hex case is not
        security-relevant, so the comparison is case-insensitive).

    Authority is narrowing-only: authority_impact must be 'none' or 'narrowing';
    'widening' is not representable in the closed enum and is rejected as
    authority-impact-invalid, and a rejected value is never echoed (the result carries
    'unknown'). v1_fallback is declarative (none, fresh-session, kernel-side-equivalent)
    and is surfaced for the caller to consume; the gate itself never selects a fallback.

    The library is strictly read-only: it opens files for reading only, never writes
    evidence, never touches capability flags, plugins or templates, and opens no
    process, socket or network connection. Output is sanitized, bounded and
    deterministic (no generated timestamp; verified_at comes from the record and is
    normalized to UTC).

    Structured reasons: registry-path-invalid, registry-unavailable,
    registry-unreadable, registry-too-large, registry-schema-invalid,
    feature-not-declared, feature-id-missing, feature-id-mismatch,
    description-invalid, required-evidence-missing, required-evidence-invalid,
    evidence-type-unsupported, evidence-runtime-unsupported,
    evidence-pin-unsupported, scenario-invalid, v1-fallback-missing,
    v1-fallback-invalid, authority-impact-missing, authority-impact-invalid,
    status-missing, status-invalid, evidence-path-invalid,
    evidence-registry-missing, evidence-registry-unreadable,
    evidence-registry-too-large, evidence-registry-schema-invalid,
    evidence-field-missing, evidence-field-invalid, evidence-feature-mismatch,
    evidence-type-mismatch, evidence-runtime-mismatch, evidence-pin-mismatch,
    evidence-scenario-mismatch, evidence-verified-at-invalid,
    evidence-verifier-invalid, evidence-hash-format-invalid,
    evidence-hash-mismatch, evidence-ambiguous, evidence-not-found.
#>
[CmdletBinding()]
param()

function Get-OrchestrationV2NativeValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $Default
}

function Test-OrchestrationV2NativeField {
    param($Object,[string]$Name)
    if($null -eq $Object){return $false}
    if($Object -is [System.Collections.IDictionary]){return [bool]$Object.Contains($Name)}
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-OrchestrationV2NativeFieldPair {
    <# Field presence and [string] type: the two checks every evidence field needs. #>
    param($Object,[string]$Name)
    if(-not (Test-OrchestrationV2NativeField $Object $Name)){return 'missing'}
    $value=Get-OrchestrationV2NativeValue $Object $Name $null
    if($value -isnot [string]){return 'invalid'}
    if([string]::IsNullOrWhiteSpace($value)){return 'invalid'}
    return ''
}

function Get-OrchestrationV2NativeSequence {
    <#
    .SYNOPSIS
        Read a field as an array without the PowerShell unrolling of one-element arrays.
    .DESCRIPTION
        Returns $null when the field is absent, an (possibly empty) array when it is
        present. The comma-wrap matters: a JSON array holding a single record must stay
        an array, otherwise a one-record evidence registry would be read as a bare
        object and rejected as a shape failure on every host.
    #>
    [CmdletBinding()]
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    $raw=$null;$present=$false
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){$present=$true;$raw=$Object[$Name]}
    }else{
        $property=$Object.PSObject.Properties[$Name]
        if($null -ne $property){$present=$true;$raw=$property.Value}
    }
    if(-not $present){return $null}
    if($null -eq $raw){return ,@()}
    return ,@($raw)
}

function Get-OrchestrationV2NativeCanonicalFields {
    <# Fixed hash order shared by the reader and by Get-OrchestrationV2NativeEvidenceHash. #>
    return @('feature_id','type','runtime','pin','scenario','verified_at','verified_by')
}

function Get-OrchestrationV2NativeRequiredRecordFields {
    return @('feature_id','type','runtime','pin','scenario','verified_at','verified_by','record_hash')
}

function ConvertTo-OrchestrationV2NativeSafeText {
    <# Redact secret-shaped substrings, flatten control characters, then bound. #>
    param([string]$Value,[int]$MaxLength=120)
    if($null -eq $Value){return ''}
    $text=$Value -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]' `
        -replace '(?i)(token|secret|password|key)\s*[=:]\s*[^\s,;]+','$1=[redacted]' `
        -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]' `
        -replace '(?i)https?://[^\s]+','[redacted-url]'
    $text=$text -replace '[\r\n\t]',' '
    if($MaxLength -lt 1 -or $MaxLength -gt 240){$MaxLength=120}
    if($text.Length -gt $MaxLength){$text=$text.Substring(0,$MaxLength)}
    return $text
}

function Get-OrchestrationV2NativeSha256 {
    <# Lowercase hex sha256 of UTF-8 text; no file, process or network access. #>
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$hex=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return $hex
}

function ConvertTo-OrchestrationV2NativeUtcStamp {
    <#
    .SYNOPSIS
        Normalized UTC round-trip instant, or '' when the input is not a proven instant.
    .DESCRIPTION
        An evidence instant must carry its own offset: the text form must match the
        RFC3339 shape with a mandatory 'Z' or +/-HH:MM (no offset, a bare date and a
        wall-clock time are all rejected), and the parsed form must be [DateTimeOffset]
        or a [DateTime] that is not Kind Unspecified. The result is always UTC with an
        explicit 'Z' (Kind Utc), so no value can depend on the host time zone.

        The already-parsed [DateTime]/[DateTimeOffset] forms are accepted because
        PowerShell 7 auto-converts ISO-8601 JSON strings to [DateTime] while PowerShell
        5.1 keeps them as text; without both branches the same evidence document would
        be accepted on one host and rejected on the other.
    #>
    [CmdletBinding()]
    param($Value)
    $normalized=''
    if($Value -is [DateTimeOffset]){
        $normalized=$Value.UtcDateTime.ToString('o')
    }elseif($Value -is [DateTime]){
        # Kind Unspecified carries no offset: its instant would depend on the host zone.
        if($Value.Kind -eq [DateTimeKind]::Unspecified){return ''}
        $normalized=$Value.ToUniversalTime().ToString('o')
    }elseif($Value -is [string]){
        if($Value -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,7})?([Zz]|[+-][0-9]{2}:[0-9]{2})$'){return ''}
        $parsed=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return ''}
        $normalized=$parsed.UtcDateTime.ToString('o')
    }else{
        # Numbers, booleans and arbitrary objects are never coerced into an instant.
        return ''
    }
    if(-not $normalized.EndsWith('Z')){return ''}
    return $normalized
}

function Get-OrchestrationV2NativeEvidenceHash {
    <#
    .SYNOPSIS
        Canonical evidence-record digest, for writers and for the reader's signature check.
    .DESCRIPTION
        Builds the compact canonical JSON object from the declared hashed_fields in the
        declared order, with verified_at normalized to UTC round-trip form, and returns
        its lowercase sha256 hex. Returns '' when any hashed field is missing or mistyped
        or when verified_at is not an instant, so a digest can never be computed over
        coerced or absent content. Read-only and side-effect free.
    #>
    [CmdletBinding()]
    param($Record)
    $raw=[ordered]@{}
    foreach($field in (Get-OrchestrationV2NativeCanonicalFields)){
        if($field -eq 'verified_at'){
            if(-not (Test-OrchestrationV2NativeField $Record 'verified_at')){return ''}
            $raw[$field]=ConvertTo-OrchestrationV2NativeUtcStamp (Get-OrchestrationV2NativeValue $Record 'verified_at' $null)
            if(-not $raw[$field]){return ''}
            continue
        }
        if((Get-OrchestrationV2NativeFieldPair $Record $field) -ne ''){return ''}
        $raw[$field]=[string](Get-OrchestrationV2NativeValue $Record $field $null)
    }
    $stamp=$raw['verified_at']
    if(-not $stamp){return ''}
    $material=[ordered]@{}
    foreach($field in (Get-OrchestrationV2NativeCanonicalFields)){
        if($field -eq 'verified_at'){$material[$field]=$stamp}else{$material[$field]=$raw[$field]}
    }
    $json=ConvertTo-Json -InputObject $material -Compress
    if([string]::IsNullOrEmpty($json)){return ''}
    return (Get-OrchestrationV2NativeSha256 $json)
}

function Test-OrchestrationV2NativeFieldIsArray {
    <#
    .SYNOPSIS
        True when the field is present as an original JSON array (empty array included).
    .DESCRIPTION
        The declared type matters: a scalar object holding one perfectly valid record is
        NOT an array and must be rejected structurally, never normalized into a unit
        list. $null counts as the empty array, because PowerShell 5.1 materializes a JSON
        empty array as $null while PowerShell 7 materializes it as an empty array.
    #>
    [CmdletBinding()]
    param($Object,[string]$Name)
    if($null -eq $Object){return $false}
    $raw=$null
    if($Object -is [System.Collections.IDictionary]){
        if(-not $Object.Contains($Name)){return $false}
        $raw=$Object[$Name]
    }else{
        $property=$Object.PSObject.Properties[$Name]
        if($null -eq $property){return $false}
        $raw=$property.Value
    }
    if($null -eq $raw){return $true}
    if($raw -is [string] -or $raw -is [ValueType]){return $false}
    if($raw.GetType().IsArray){return $true}
    return ($raw -is [System.Collections.IList])
}

function Test-OrchestrationV2NativeSchemaVersion {
    <# A schema version is an integral 1, whether the document spells it as a number or a string. #>
    param($Object)
    $raw=Get-OrchestrationV2NativeValue $Object 'schema_version' (Get-OrchestrationV2NativeValue $Object 'version' $null)
    if($raw -is [bool] -or $raw -isnot [ValueType]){return $false}
    $number=[double]$raw
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $false}
    if($number -ne [Math]::Floor($number) -or $number -ne 1){return $false}
    return $true
}

function Resolve-OrchestrationV2NativePath {
    <#
    .SYNOPSIS
        Resolve a path for reading; '' when the input is unusable.
    .DESCRIPTION
        An explicit caller path (-evidence_registry_path, -registry_path) is honoured as
        rooted or repo-relative, because the caller is the kernel and the read is
        read-only. A path DECLARED inside the registry (-Declared) must be relative and
        must stay inside the repository, so a hostile registry cannot redirect the gate
        to arbitrary files. '..' segments are refused in both cases.
    #>
    [CmdletBinding()]
    param([string]$Path,[switch]$Declared)
    if([string]::IsNullOrWhiteSpace($Path)){return ''}
    $candidate=$Path.Trim().Replace('/','\')
    if($candidate -match '(^|\\)\.\.($|\\)'){return ''}
    $rooted=($candidate.Contains(':') -or $candidate.StartsWith('\'))
    if($Declared -and $rooted){return ''}
    try{
        $full=[IO.Path]::GetFullPath($(if($rooted){$candidate}else{Join-Path $PSScriptRoot ('..\..\..\'+$candidate)}))
        if($Declared){
            $prefix=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')+'\'
            if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return ''}
        }
        return $full
    }catch{return ''}
}

function Get-OrchestrationV2NativeBound {
    <# Clamp a declared limit into a hard ceiling; out-of-range falls back to the default. #>
    param($Raw,[int]$Fallback,[int]$Minimum,[int]$Maximum)
    if($Raw -is [bool] -or $Raw -isnot [ValueType]){return $Fallback}
    $number=[double]$Raw
    if([double]::IsNaN($number) -or [double]::IsInfinity($number)){return $Fallback}
    $value=[int][Math]::Floor($number)
    if($value -lt $Minimum -or $value -gt $Maximum){return $Fallback}
    return $value
}

function New-OrchestrationV2NativeRegistryState {
    param([bool]$Available,[string]$Reason,$Registry=$null,$Contract=$null,$Features=$null,[string]$Path='')
    return [pscustomobject]@{available=$Available;reason=$Reason;registry=$Registry;contract=$Contract;features=$Features;path=$Path}
}

function Test-OrchestrationV2NativeRegistrySchema {
    <#
    .SYNOPSIS
        Schema-check the candidate registry; '' when valid, else a kebab reason.
    .DESCRIPTION
        One closed check for both the on-disk and the injected registry: version, exact
        runtime, pinned release, and an evidence contract that declares append-only
        sha256-canonical-json over the exact hashed/required field order this library
        implements, with a registry path confined to the repository. A declared hash
        order that drifts from the reader's canonical order is registry-schema-invalid,
        so the digest can never be computed over a different material than declared.
    #>
    [CmdletBinding()]
    param($Registry)
    if($null -eq $Registry){return 'registry-unreadable'}
    if(-not (Test-OrchestrationV2NativeSchemaVersion $Registry)){return 'registry-schema-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $Registry 'runtime') -ne ''){return 'registry-schema-invalid'}
    if([string](Get-OrchestrationV2NativeValue $Registry 'runtime' $null) -cne 'v2'){return 'registry-schema-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $Registry 'pin') -ne ''){return 'registry-schema-invalid'}
    if([string](Get-OrchestrationV2NativeValue $Registry 'pin' $null) -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$'){return 'registry-schema-invalid'}
    $contract=Get-OrchestrationV2NativeValue $Registry 'evidence_contract' $null
    if($null -eq $contract){return 'registry-schema-invalid'}
    $appendOnly=Get-OrchestrationV2NativeValue $contract 'append_only' $null
    if($appendOnly -isnot [bool] -or -not $appendOnly){return 'registry-schema-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $contract 'hash_algorithm') -ne ''){return 'registry-schema-invalid'}
    if([string](Get-OrchestrationV2NativeValue $contract 'hash_algorithm' $null) -cne 'sha256-canonical-json'){return 'registry-schema-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $contract 'registry_path') -ne ''){return 'registry-schema-invalid'}
    if(-not (Resolve-OrchestrationV2NativePath ([string](Get-OrchestrationV2NativeValue $contract 'registry_path' $null)) -Declared)){return 'registry-schema-invalid'}
    $declaredHashed=Get-OrchestrationV2NativeSequence $contract 'hashed_fields'
    $declaredRequired=Get-OrchestrationV2NativeSequence $contract 'required_fields'
    if($null -eq $declaredHashed -or ($declaredHashed -join ',') -cne ((Get-OrchestrationV2NativeCanonicalFields) -join ',')){return 'registry-schema-invalid'}
    if($null -eq $declaredRequired -or ($declaredRequired -join ',') -cne ((Get-OrchestrationV2NativeRequiredRecordFields) -join ',')){return 'registry-schema-invalid'}
    $features=Get-OrchestrationV2NativeValue $Registry 'features' $null
    if($null -eq $features){return 'registry-schema-invalid'}
    if($features -is [string] -or $features -is [System.Collections.IDictionary] -or $features -is [ValueType]){return 'registry-schema-invalid'}
    $names=@($features.PSObject.Properties|ForEach-Object{$_.Name})
    if($names.Count -eq 0 -or $names.Count -gt 64){return 'registry-schema-invalid'}
    return ''
}

function Get-OrchestrationV2NativeRegistry {
    <#
    .SYNOPSIS
        Load and schema-check the candidate registry (read-only, bounded).
    .DESCRIPTION
        Returns {available,reason,registry,contract,features,path}. Any failure is a
        structured unavailable registry, never a partially trusted one. An injected
        -Registry object is schema-checked exactly like the on-disk file so tests can
        exercise hostile variants.
    #>
    [CmdletBinding()]
    param($Registry,[string]$RegistryPath='')
    if($PSBoundParameters.ContainsKey('Registry') -and $null -ne $Registry){
        $schemaReason=Test-OrchestrationV2NativeRegistrySchema $Registry
        if($schemaReason){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason $schemaReason)}
        return (New-OrchestrationV2NativeRegistryState -Available $true -Reason '' -Registry $Registry -Contract (Get-OrchestrationV2NativeValue $Registry 'evidence_contract' $null) -Features (Get-OrchestrationV2NativeValue $Registry 'features' $null) -Path '<injected>')
    }
    if([string]::IsNullOrWhiteSpace($RegistryPath)){$RegistryPath='source\registry\v2-native-capabilities.json'}
    $path=Resolve-OrchestrationV2NativePath $RegistryPath
    if(-not $path){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason 'registry-path-invalid')}
    try{
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason 'registry-unavailable')}
        $file=New-Object IO.FileInfo $path
        if($file.Length -gt 262144){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason 'registry-too-large')}
        $parsed=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    }catch{return (New-OrchestrationV2NativeRegistryState -Available $false -Reason 'registry-unreadable')}
    if($null -eq $parsed){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason 'registry-unreadable')}
    $schemaReason=Test-OrchestrationV2NativeRegistrySchema $parsed
    if($schemaReason){return (New-OrchestrationV2NativeRegistryState -Available $false -Reason $schemaReason)}
    return (New-OrchestrationV2NativeRegistryState -Available $true -Reason '' -Registry $parsed -Contract (Get-OrchestrationV2NativeValue $parsed 'evidence_contract' $null) -Features (Get-OrchestrationV2NativeValue $parsed 'features' $null) -Path $path)
}

function Test-OrchestrationV2NativeDescriptor {
    <#
    .SYNOPSIS
        Schema-check one candidate descriptor; '' when valid, else a kebab reason.
    .DESCRIPTION
        Closed and fail-closed: an unknown authority_impact, an unsupported evidence
        type/runtime/pin, a missing v1_fallback or a feature_id that drifts from its own
        map key are schema failures, never silently defaulted.
    #>
    [CmdletBinding()]
    param($Registry,[string]$Name)
    $features=Get-OrchestrationV2NativeValue $Registry 'features' $null
    $descriptor=Get-OrchestrationV2NativeValue $features $Name $null
    if($null -eq $descriptor){return 'feature-not-declared'}
    if((Get-OrchestrationV2NativeFieldPair $descriptor 'feature_id') -ne ''){return 'feature-id-missing'}
    if([string](Get-OrchestrationV2NativeValue $descriptor 'feature_id' $null) -cne $Name){return 'feature-id-mismatch'}
    if((Get-OrchestrationV2NativeFieldPair $descriptor 'description') -ne ''){return 'description-invalid'}
    $required=Get-OrchestrationV2NativeValue $descriptor 'required_evidence' $null
    if($null -eq $required){return 'required-evidence-missing'}
    foreach($field in @('type','runtime','pin','scenario')){
        if((Get-OrchestrationV2NativeFieldPair $required $field) -ne ''){return 'required-evidence-invalid'}
    }
    if([string](Get-OrchestrationV2NativeValue $required 'type' $null) -cne 'exact-binary-live'){return 'evidence-type-unsupported'}
    if([string](Get-OrchestrationV2NativeValue $required 'runtime' $null) -cne 'v2'){return 'evidence-runtime-unsupported'}
    if([string](Get-OrchestrationV2NativeValue $required 'pin' $null) -cne [string](Get-OrchestrationV2NativeValue $Registry 'pin' $null)){return 'evidence-pin-unsupported'}
    if([string](Get-OrchestrationV2NativeValue $required 'scenario' $null) -notmatch '^[a-z0-9][a-z0-9-]{2,63}$'){return 'scenario-invalid'}
    $fallback=Get-OrchestrationV2NativeValue $descriptor 'v1_fallback' $null
    if($null -eq $fallback){return 'v1-fallback-missing'}
    if([string](Get-OrchestrationV2NativeValue $fallback 'mode' $null) -notin @('none','fresh-session','kernel-side-equivalent')){return 'v1-fallback-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $descriptor 'authority_impact') -ne ''){return 'authority-impact-missing'}
    if([string](Get-OrchestrationV2NativeValue $descriptor 'authority_impact' $null) -notin @('none','narrowing')){return 'authority-impact-invalid'}
    if((Get-OrchestrationV2NativeFieldPair $descriptor 'status') -ne ''){return 'status-missing'}
    if([string](Get-OrchestrationV2NativeValue $descriptor 'status' $null) -notin @('hold-unproven','proven')){return 'status-invalid'}
    return ''
}

function Get-OrchestrationV2NativeEvidenceRegistry {
    <#
    .SYNOPSIS
        Load and schema-check the append-only evidence registry (read-only, bounded).
    .DESCRIPTION
        Returns {state,reason,records,path} where state is 'ok', 'missing' (an absent
        file, which leaves every candidate NOT_PROVEN) or 'invalid'. Oversize files are
        rejected before parsing. 'records' must be an array in its original type (a
        scalar object is rejected, never normalized into a unit list) and an absent field
        is schema-invalid; an empty array is valid and enables nothing, so an empty
        append-only registry can never differ from a malformed one in a way that enables
        anything. An unusable explicit path is invalid, never silently replaced by the
        default.
    #>
    [CmdletBinding()]
    param([string]$Path,$Contract)
    $target=''
    if(-not [string]::IsNullOrWhiteSpace($Path)){
        $target=Resolve-OrchestrationV2NativePath $Path
        if(-not $target){return [pscustomobject]@{state='invalid';reason='evidence-path-invalid';records=@();path=''}}
    }else{
        if($null -ne $Contract -and (Get-OrchestrationV2NativeFieldPair $Contract 'registry_path') -eq ''){
            $target=Resolve-OrchestrationV2NativePath ([string](Get-OrchestrationV2NativeValue $Contract 'registry_path' $null)) -Declared
        }
        if(-not $target){$target=Resolve-OrchestrationV2NativePath 'evidence\v3.1\runtime-reliability\v2-native-evidence.json'}
        if(-not $target){return [pscustomobject]@{state='invalid';reason='evidence-path-invalid';records=@();path=''}}
    }
    try{
        if(-not (Test-Path -LiteralPath $target -PathType Leaf)){return [pscustomobject]@{state='missing';reason='evidence-registry-missing';records=@();path=$target}}
        $maxBytes=Get-OrchestrationV2NativeBound (Get-OrchestrationV2NativeValue $Contract 'max_bytes' $null) 262144 4096 1048576
        $file=New-Object IO.FileInfo $target
        if($file.Length -gt $maxBytes){return [pscustomobject]@{state='invalid';reason='evidence-registry-too-large';records=@();path=$target}}
        $parsed=ConvertFrom-Json ([IO.File]::ReadAllText($target))
    }catch{return [pscustomobject]@{state='invalid';reason='evidence-registry-unreadable';records=@();path=$target}}
    if($null -eq $parsed){return [pscustomobject]@{state='invalid';reason='evidence-registry-unreadable';records=@();path=$target}}
    if(-not (Test-OrchestrationV2NativeSchemaVersion $parsed)){return [pscustomobject]@{state='invalid';reason='evidence-registry-schema-invalid';records=@();path=$target}}
    if(-not (Test-OrchestrationV2NativeFieldIsArray $parsed 'records')){return [pscustomobject]@{state='invalid';reason='evidence-registry-schema-invalid';records=@();path=$target}}
    $raw=Get-OrchestrationV2NativeSequence $parsed 'records'
    $entries=@()
    foreach($item in $raw){
        if($null -eq $item -or $item -is [string] -or $item -is [ValueType] -or $item -is [System.Collections.IDictionary]){return [pscustomobject]@{state='invalid';reason='evidence-registry-schema-invalid';records=@();path=$target}}
        $entries+=@($item)
        if($entries.Count -gt 1000){break}
    }
    $maxRecords=Get-OrchestrationV2NativeBound (Get-OrchestrationV2NativeValue $Contract 'max_records' $null) 200 1 1000
    if($entries.Count -gt $maxRecords){return [pscustomobject]@{state='invalid';reason='evidence-registry-schema-invalid';records=@();path=$target}}
    return [pscustomobject]@{state='ok';reason='';records=$entries;path=$target}
}

function Get-OrchestrationV2NativeRecordReason {
    <#
    .SYNOPSIS
        Return '' when one evidence record proves the candidate, else a kebab reason.
    .DESCRIPTION
        Shape first (every declared field exactly [string]), then agreement with the
        declared requirement (feature, type, runtime, exact pin, exact scenario), then
        provenance (parsable instant, closed test-id charset) and finally the canonical
        digest. A record failing any of these proves nothing.
    #>
    [CmdletBinding()]
    param($Record,[string]$FeatureId,$Required)
    foreach($field in (Get-OrchestrationV2NativeRequiredRecordFields)){
        if($field -eq 'verified_at'){
            if(-not (Test-OrchestrationV2NativeField $Record 'verified_at')){return 'evidence-field-invalid'}
            continue
        }
        if((Get-OrchestrationV2NativeFieldPair $Record $field) -ne ''){return 'evidence-field-invalid'}
    }
    if((Get-OrchestrationV2NativeFieldPair $Record 'feature_id') -ne ''){return 'evidence-field-missing'}
    if([string](Get-OrchestrationV2NativeValue $Record 'feature_id' $null) -cne $FeatureId){return 'evidence-feature-mismatch'}
    if([string](Get-OrchestrationV2NativeValue $Record 'type' $null) -cne 'exact-binary-live'){return 'evidence-type-mismatch'}
    if([string](Get-OrchestrationV2NativeValue $Record 'runtime' $null) -cne [string](Get-OrchestrationV2NativeValue $Required 'runtime' $null)){return 'evidence-runtime-mismatch'}
    if([string](Get-OrchestrationV2NativeValue $Record 'pin' $null) -cne [string](Get-OrchestrationV2NativeValue $Required 'pin' $null)){return 'evidence-pin-mismatch'}
    if([string](Get-OrchestrationV2NativeValue $Record 'scenario' $null) -cne [string](Get-OrchestrationV2NativeValue $Required 'scenario' $null)){return 'evidence-scenario-mismatch'}
    if(-not (ConvertTo-OrchestrationV2NativeUtcStamp (Get-OrchestrationV2NativeValue $Record 'verified_at' $null))){return 'evidence-verified-at-invalid'}
    if([string](Get-OrchestrationV2NativeValue $Record 'verified_by' $null) -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$'){return 'evidence-verifier-invalid'}
    $declaredHash=[string](Get-OrchestrationV2NativeValue $Record 'record_hash' $null)
    if($declaredHash -notmatch '^[0-9a-fA-F]{64}$'){return 'evidence-hash-format-invalid'}
    $expected=Get-OrchestrationV2NativeEvidenceHash $Record
    if(-not $expected){return 'evidence-hash-format-invalid'}
    if($declaredHash -ine $expected){return 'evidence-hash-mismatch'}
    return ''
}

function New-OrchestrationV2NativeNotProven {
    <# Structured NOT_PROVEN result; every free-text field passes through the sanitizer. #>
    param([string]$FeatureId,[string]$Reason,[string]$Impact='unknown',[string]$DeclaredStatus='unknown',[string]$FallbackMode='none',[string]$Scenario='')
    $safeFeature=ConvertTo-OrchestrationV2NativeSafeText $FeatureId 64
    return [pscustomobject]@{
        feature_id=$safeFeature
        enabled=$false
        status='not-proven'
        reason=$Reason
        detail=('Feature not enabled; '+$Reason+'.')
        authority_impact=$Impact
        declared_status=$DeclaredStatus
        v1_fallback_mode=$FallbackMode
        scenario=(ConvertTo-OrchestrationV2NativeSafeText $Scenario 64)
        evidence=$null
    }
}

function Get-OrchestrationV2NativeFeature {
    <#
    .SYNOPSIS
        Resolve one V2 native candidate to enabled/not-proven with a structured reason.
    .DESCRIPTION
        enabled=$true is possible only when the append-only evidence registry holds one
        record whose content matches this candidate's declared requirement exactly and
        whose canonical digest verifies. Everything else - absent registry, unreadable
        registry, undeclared candidate, schema-invalid descriptor, absent or divergent
        record, tampered digest, two competing records - returns not-proven with the
        first violated rule. Read-only: opens files for reading and never writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$feature_id,
        [string]$evidence_registry_path='',
        [string]$registry_path='',
        $Registry=$null
    )
    $name=$feature_id.Trim().ToLowerInvariant()
    if($name -notmatch '^[a-z0-9][a-z0-9-]{2,63}$'){
        # Echo a neutralized rendering, never the raw hostile input (no path separators).
        $safe=($name -replace '[^a-z0-9-]','-')
        if($safe.Length -gt 64){$safe=$safe.Substring(0,64)}
        return (New-OrchestrationV2NativeNotProven -FeatureId $safe -Reason 'feature-id-missing')
    }
    $loaded=Get-OrchestrationV2NativeRegistry -Registry $Registry -RegistryPath $registry_path
    if(-not $loaded.available){return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason $loaded.reason)}
    $schemaReason=Test-OrchestrationV2NativeDescriptor -Registry $loaded.registry -Name $name
    $descriptor=Get-OrchestrationV2NativeValue $loaded.features $name $null
    if($schemaReason){
        # Only an enum member is echoed; a rejected authority_impact stays 'unknown' so a
        # hostile payload can never ride into the output through the error path.
        $impact='unknown'
        if($null -ne $descriptor){
            $rawImpact=[string](Get-OrchestrationV2NativeValue $descriptor 'authority_impact' $null)
            if($rawImpact -in @('none','narrowing')){$impact=$rawImpact}
        }
        return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason $schemaReason -Impact $impact)
    }
    $required=Get-OrchestrationV2NativeValue $descriptor 'required_evidence' $null
    $fallback=Get-OrchestrationV2NativeValue $descriptor 'v1_fallback' $null
    $impact=[string](Get-OrchestrationV2NativeValue $descriptor 'authority_impact' $null)
    $declaredStatus=[string](Get-OrchestrationV2NativeValue $descriptor 'status' $null)
    $mode=[string](Get-OrchestrationV2NativeValue $fallback 'mode' $null)
    $scenario=[string](Get-OrchestrationV2NativeValue $required 'scenario' $null)
    $evidence=Get-OrchestrationV2NativeEvidenceRegistry -Path $evidence_registry_path -Contract $loaded.contract
    if($evidence.state -ne 'ok'){
        return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason $evidence.reason -Impact $impact -DeclaredStatus $declaredStatus -FallbackMode $mode -Scenario $scenario)
    }
    $matched=@()
    foreach($record in $evidence.records){
        if([string](Get-OrchestrationV2NativeValue $record 'feature_id' $null) -ceq $name){$matched+=@($record)}
    }
    if($matched.Count -eq 0){
        return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason 'evidence-not-found' -Impact $impact -DeclaredStatus $declaredStatus -FallbackMode $mode -Scenario $scenario)
    }
    if($matched.Count -gt 1){
        return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason 'evidence-ambiguous' -Impact $impact -DeclaredStatus $declaredStatus -FallbackMode $mode -Scenario $scenario)
    }
    $record=$matched[0]
    $recordReason=Get-OrchestrationV2NativeRecordReason -Record $record -FeatureId $name -Required $required
    if($recordReason){
        return (New-OrchestrationV2NativeNotProven -FeatureId $name -Reason $recordReason -Impact $impact -DeclaredStatus $declaredStatus -FallbackMode $mode -Scenario $scenario)
    }
    return [pscustomobject]@{
        feature_id=(ConvertTo-OrchestrationV2NativeSafeText $name 64)
        enabled=$true
        status='enabled'
        reason='exact-binary-evidence-verified'
        detail='Exact-binary-live evidence verified for the declared pin and scenario.'
        authority_impact=$impact
        declared_status=$declaredStatus
        v1_fallback_mode=$mode
        scenario=(ConvertTo-OrchestrationV2NativeSafeText $scenario 64)
        evidence=[pscustomobject]@{
            verified_at=(ConvertTo-OrchestrationV2NativeUtcStamp (Get-OrchestrationV2NativeValue $record 'verified_at' $null))
            verified_by=(ConvertTo-OrchestrationV2NativeSafeText ([string](Get-OrchestrationV2NativeValue $record 'verified_by' $null)) 128)
            record_hash=(ConvertTo-OrchestrationV2NativeSafeText ([string](Get-OrchestrationV2NativeValue $record 'record_hash' $null)) 64)
        }
    }
}

function Get-OrchestrationV2NativeFeatures {
    <#
    .SYNOPSIS
        Resolve every declared candidate, in a stable feature_id order, bounded at 64.
    .DESCRIPTION
        Same fail-closed contract as Get-OrchestrationV2NativeFeature, applied per
        candidate; used by the validation slice to see exactly which candidates remain
        unproven. Deterministic for a fixed registry and evidence registry. Returns an
        empty list when the registry itself is unavailable.
    #>
    [CmdletBinding()]
    param([string]$evidence_registry_path='',[string]$registry_path='',$Registry=$null)
    $loaded=Get-OrchestrationV2NativeRegistry -Registry $Registry -RegistryPath $registry_path
    if(-not $loaded.available){return @()}
    $names=@($loaded.features.PSObject.Properties|ForEach-Object{[string]$_.Name}|Sort-Object|Select-Object -First 64)
    $results=New-Object System.Collections.ArrayList
    foreach($name in $names){
        [void]$results.Add((Get-OrchestrationV2NativeFeature -feature_id $name -evidence_registry_path $evidence_registry_path -registry_path $registry_path -Registry $Registry))
    }
    return @($results.ToArray())
}