<#!
.SYNOPSIS
    V3 EvidenceRef + compact handoffs: light references without raw payloads (SPEC v0.1.0 Phase 11).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure constructors and
    validators, fail-closed, PS 5.1 compatible, ASCII-only. Never throws
    on operational paths: every failure returns an envelope with ok=$false
    and a machine-readable reason. No network, no process, no store, no
    kernel, no dispatch.

    TDR-F11: New-OrchestrationEvidenceRef builds a validated reference
    (ordered): schema_version=1, evidence_id, goal_id, task_id, run_id,
    producer, artifact_ref, hash, verification_state, provenance,
    created_at. Id fields must match ^[A-Za-z0-9._:-]{1,128}$; hash must
    match ^[a-f0-9]{16,64}$; verification_state is one of unverified,
    verified, stale, revoked. Empty fields are invalid (fail-closed).

    New-OrchestrationCompactHandoff builds the SPEC section 20 worker
    return contract (ordered): schema_version=1, task_id, status,
    key_findings, evidence_refs, changes, validation, blockers, risks,
    recommendation, truncated, created_at. Status is one of
    candidate_pass, failed, blocked. Caps are applied by truncation
    (never by silent drop of the whole record): key_findings holds at
    most 10 items of at most 200 chars each; changes, validation,
    blockers, risks and recommendation hold at most 500 chars each.
    Evidence travels as REFS only: a raw payload is NEVER included; any
    evidence item carrying 'raw_content' or 'raw_payload' rejects the
    whole handoff with reason 'raw-payload-forbidden'.
    Test-OrchestrationHandoffValid revalidates a handoff record against
    the same rules (fail-closed, machine-readable reason).
#>
[CmdletBinding()]
param()

function Get-EVVerificationStates {
    [CmdletBinding()]
    param()
    return @('unverified', 'verified', 'stale', 'revoked')
}

function Get-EVHandoffStatuses {
    [CmdletBinding()]
    param()
    return @('candidate_pass', 'failed', 'blocked')
}

function Test-EVRefId {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Test-EVHash {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[a-f0-9]{16,64}$')
    }
    catch { return $false }
}

function Get-EVValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) {
            if ($Default -is [array]) { return ,$Default }
            return $Default
        }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $v = $Object[$Name]
                if ($null -eq $v) { return $null }
                if ($v -is [array]) { return ,$v }
                return $v
            }
            if ($Default -is [array]) { return ,$Default }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) {
            $v = $p.Value
            if ($null -eq $v) { return $null }
            if ($v -is [array]) { return ,$v }
            return $v
        }
        if ($Default -is [array]) { return ,$Default }
        return $Default
    }
    catch {
        if ($Default -is [array]) { return ,$Default }
        return $Default
    }
}

function Get-EVRawInspection {
    param($Object, [int]$Depth = 0, $Seen = $null)
    try {
        if ($null -eq $Object) { return 'clean' }
        if ($Object -is [string]) { return 'clean' }
        try {
            $t = $Object.GetType()
            if ($t.IsPrimitive) { return 'clean' }
            if (($Object -is [decimal]) -or ($Object -is [DateTime]) -or ($Object -is [DateTimeOffset]) -or ($Object -is [Guid])) { return 'clean' }
        }
        catch { }
        $isDict = ($Object -is [System.Collections.IDictionary])
        $isPso = ($Object -is [pscustomobject])
        $isArr = ($Object -is [array]) -or ($Object -is [System.Collections.IList])
        $isContainer = ($isDict -or $isPso -or $isArr)
        if ($Depth -gt 4) {
            if ($isContainer) { return 'incomplete' }
            return 'clean'
        }
        if ($isContainer) {
            if ($null -eq $Seen) {
                try { $Seen = New-Object 'System.Collections.Generic.HashSet[object]' }
                catch { return 'incomplete' }
            }
            try {
                $added = $Seen.Add($Object)
                if (-not $added) { return 'incomplete' }
            }
            catch { return 'incomplete' }
        }
        if ($isDict) {
            foreach ($k in $Object.Keys) {
                $s = [string]$k
                if (($s -ieq 'raw_content') -or ($s -ieq 'raw_payload')) { return 'raw' }
            }
            foreach ($k in $Object.Keys) {
                $r = Get-EVRawInspection -Object $Object[$k] -Depth ($Depth + 1) -Seen $Seen
                if ($r -ceq 'raw') { return 'raw' }
                if ($r -ceq 'incomplete') { return 'incomplete' }
            }
            return 'clean'
        }
        if ($isPso) {
            foreach ($p in $Object.PSObject.Properties) {
                if (($p.Name -ieq 'raw_content') -or ($p.Name -ieq 'raw_payload')) { return 'raw' }
            }
            foreach ($p in $Object.PSObject.Properties) {
                $r = Get-EVRawInspection -Object $p.Value -Depth ($Depth + 1) -Seen $Seen
                if ($r -ceq 'raw') { return 'raw' }
                if ($r -ceq 'incomplete') { return 'incomplete' }
            }
            return 'clean'
        }
        if ($isArr) {
            foreach ($e in $Object) {
                $r = Get-EVRawInspection -Object $e -Depth ($Depth + 1) -Seen $Seen
                if ($r -ceq 'raw') { return 'raw' }
                if ($r -ceq 'incomplete') { return 'incomplete' }
            }
            return 'clean'
        }
        return 'clean'
    }
    catch { return 'incomplete' }
}

function Test-EVHasRawKey {
    param($Object)
    try {
        $r = Get-EVRawInspection -Object $Object -Depth 0 -Seen $null
        if (($r -ceq 'raw') -or ($r -ceq 'incomplete')) { return $true }
        return $false
    }
    catch { return $true }
}

function Get-EVStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

function Get-EVInstant {
    param($Value)
    try {
        if ($null -eq $Value) { return '' }
        if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime.ToString('o') }
        if ($Value -is [DateTime]) {
            $dt = [DateTime]$Value
            if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return '' }
            return $dt.ToUniversalTime().ToString('o')
        }
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        return $s
    }
    catch { return '' }
}

function ConvertTo-EVEvidenceRef {
    param($Ref)
    try {
        $sv = Get-EVValue $Ref 'schema_version' $null
        if ($sv -is [array]) { return $null }
        if (($sv -isnot [int]) -and ($sv -isnot [long]) -and ($sv -isnot [int16]) -and ($sv -isnot [byte]) -and ($sv -isnot [short])) { return $null }
        if ([long]$sv -ne 1) { return $null }
        foreach ($pair in @(@('evidence_id', 'invalid-evidence-id'), @('goal_id', 'invalid-goal-id'), @('task_id', 'invalid-task-id'), @('run_id', 'invalid-run-id'), @('producer', 'invalid-producer'), @('artifact_ref', 'invalid-artifact-ref'), @('provenance', 'invalid-provenance'))) {
            $rawId = Get-EVValue $Ref $pair[0] $null
            if (-not ($rawId -is [string])) { return $null }
            if (-not (Test-EVRefId ([string]$rawId))) { return $null }
        }
        $rawHash = Get-EVValue $Ref 'hash' $null
        if (-not ($rawHash -is [string])) { return $null }
        if (-not (Test-EVHash ([string]$rawHash))) { return $null }
        $rawSt = Get-EVValue $Ref 'verification_state' ''
        if (-not ($rawSt -is [string])) { return $null }
        $st = [string]$rawSt
        if (@(Get-EVVerificationStates) -cnotcontains $st) { return $null }
        $created = Get-EVInstant (Get-EVValue $Ref 'created_at' '')
        if ([string]::IsNullOrWhiteSpace($created)) { return $null }
        $rec = [ordered]@{
            schema_version       = 1
            evidence_id          = ([string](Get-EVValue $Ref 'evidence_id' '')).Trim()
            goal_id              = ([string](Get-EVValue $Ref 'goal_id' '')).Trim()
            task_id              = ([string](Get-EVValue $Ref 'task_id' '')).Trim()
            run_id               = ([string](Get-EVValue $Ref 'run_id' '')).Trim()
            producer             = ([string](Get-EVValue $Ref 'producer' '')).Trim()
            artifact_ref         = ([string](Get-EVValue $Ref 'artifact_ref' '')).Trim()
            hash                 = ([string](Get-EVValue $Ref 'hash' '')).Trim()
            verification_state   = $st
            provenance           = ([string](Get-EVValue $Ref 'provenance' '')).Trim()
            created_at           = $created
        }
        return $rec
    }
    catch { return $null }
}

function New-OrchestrationEvidenceRef {
    [CmdletBinding()]
    param(
        [string]$EvidenceId = '',
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$RunId = '',
        [string]$Producer = '',
        [string]$ArtifactRef = '',
        [string]$Hash = '',
        [string]$VerificationState = '',
        [string]$Provenance = ''
    )
    try {
        if (-not (Test-EVRefId $EvidenceId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-id'; ref = $null }
        }
        if (-not (Test-EVRefId $GoalId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; ref = $null }
        }
        if (-not (Test-EVRefId $TaskId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; ref = $null }
        }
        if (-not (Test-EVRefId $RunId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-run-id'; ref = $null }
        }
        if (-not (Test-EVRefId $Producer)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-producer'; ref = $null }
        }
        if (-not (Test-EVRefId $ArtifactRef)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-artifact-ref'; ref = $null }
        }
        if (-not (Test-EVHash $Hash)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-hash'; ref = $null }
        }
        $st = ([string]$VerificationState).Trim()
        if (@(Get-EVVerificationStates) -cnotcontains $st) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-verification-state'; ref = $null }
        }
        if (-not (Test-EVRefId $Provenance)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-provenance'; ref = $null }
        }
        $rec = [ordered]@{
            schema_version       = 1
            evidence_id          = ([string]$EvidenceId).Trim()
            goal_id              = ([string]$GoalId).Trim()
            task_id              = ([string]$TaskId).Trim()
            run_id               = ([string]$RunId).Trim()
            producer             = ([string]$Producer).Trim()
            artifact_ref         = ([string]$ArtifactRef).Trim()
            hash                 = ([string]$Hash).Trim()
            verification_state   = $st
            provenance           = ([string]$Provenance).Trim()
            created_at           = Get-EVStamp
        }
        if ($null -eq (ConvertTo-EVEvidenceRef $rec)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-ref'; ref = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; ref = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-ref'; ref = $null }
    }
}

function Get-EVCappedText {
    param($Value, [int]$MaxLength)
    try {
        if ($null -eq $Value) { return [pscustomobject]@{ ok = $true; truncated = $false; text = '' } }
        if (-not ($Value -is [string])) { return [pscustomobject]@{ ok = $false; truncated = $false; text = '' } }
        $s = [string]$Value
        if ($s.Length -gt $MaxLength) {
            return [pscustomobject]@{ ok = $true; truncated = $true; text = $s.Substring(0, $MaxLength) }
        }
        return [pscustomobject]@{ ok = $true; truncated = $false; text = $s }
    }
    catch { return [pscustomobject]@{ ok = $false; truncated = $false; text = '' } }
}

function Get-EVFindingsList {
    param($Value, [int]$MaxItems = 10, [int]$MaxChars = 200)
    try {
        $truncated = $false
        $raw = @()
        if ($null -eq $Value) { $raw = @() }
        elseif ($Value -is [string]) { $raw = @([string]$Value) }
        elseif ($Value -is [System.Collections.IDictionary]) { return $null }
        else {
            try { $raw = @($Value) } catch { return $null }
        }
        foreach ($item in $raw) {
            if (-not ($item -is [string])) { return $null }
        }
        if ($raw.Count -gt $MaxItems) {
            $raw = @($raw | Select-Object -First $MaxItems)
            $truncated = $true
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($item in $raw) {
            $s = [string]$item
            if ($s.Length -gt $MaxChars) {
                $s = $s.Substring(0, $MaxChars)
                $truncated = $true
            }
            [void]$out.Add($s)
        }
        return [pscustomobject]@{ ok = $true; truncated = [bool]$truncated; items = [string[]]$out.ToArray() }
    }
    catch { return $null }
}

function Get-EVNormalizedRefs {
    param($Value)
    try {
        $raw = @()
        if ($null -eq $Value) { $raw = @() }
        elseif ($Value -is [string]) { $raw = @([string]$Value) }
        elseif ($Value -is [System.Collections.IDictionary]) { return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs'; refs = $null } }
        else {
            try { $raw = @($Value) } catch { return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs'; refs = $null } }
        }
        $out = New-Object System.Collections.ArrayList
        foreach ($item in $raw) {
            if ($item -is [string]) {
                if (-not (Test-EVRefId ([string]$item))) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-ref'; refs = $null }
                }
                [void]$out.Add(([string]$item).Trim())
            }
            elseif (($item -is [System.Collections.IDictionary]) -or ($item -is [pscustomobject])) {
                $insp = Get-EVRawInspection -Object $item -Depth 0 -Seen $null
                if ($insp -ceq 'raw') {
                    return [pscustomobject]@{ ok = $false; reason = 'raw-payload-forbidden'; refs = $null }
                }
                if ($insp -ceq 'incomplete') {
                    return [pscustomobject]@{ ok = $false; reason = 'inspection-incomplete'; refs = $null }
                }
                $norm = ConvertTo-EVEvidenceRef $item
                if ($null -eq $norm) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-ref'; refs = $null }
                }
                [void]$out.Add($norm)
            }
            else {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs'; refs = $null }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; refs = @($out.ToArray()) }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs'; refs = $null } }
}

function New-OrchestrationCompactHandoff {
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$Status = '',
        $KeyFindings = $null,
        $EvidenceRefs = $null,
        $Changes = $null,
        $Validation = $null,
        $Blockers = $null,
        $Risks = $null,
        $Recommendation = $null
    )
    try {
        if (-not (Test-EVRefId $TaskId)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; handoff = $null }
        }
        $st = ([string]$Status).Trim()
        if (@(Get-EVHandoffStatuses) -cnotcontains $st) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-status'; handoff = $null }
        }
        $findings = Get-EVFindingsList $KeyFindings 10 200
        if ($null -eq $findings) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-key-findings'; handoff = $null }
        }
        $refs = Get-EVNormalizedRefs $EvidenceRefs
        if ($null -eq $refs -or -not [bool]$refs.ok) {
            $why = 'invalid-evidence-refs'
            if (($null -ne $refs) -and (-not [string]::IsNullOrWhiteSpace([string]$refs.reason))) { $why = [string]$refs.reason }
            return [pscustomobject]@{ ok = $false; reason = $why; handoff = $null }
        }
        $truncated = [bool]$findings.truncated
        $texts = [ordered]@{}
        foreach ($pair in @(@('changes', $Changes), @('validation', $Validation), @('blockers', $Blockers), @('risks', $Risks), @('recommendation', $Recommendation))) {
            $cap = Get-EVCappedText $pair[1] 500
            if ($null -eq $cap -or -not [bool]$cap.ok) {
                return [pscustomobject]@{ ok = $false; reason = ('invalid-' + [string]$pair[0]); handoff = $null }
            }
            $texts[[string]$pair[0]] = [string]$cap.text
            if ([bool]$cap.truncated) { $truncated = $true }
        }
        $rec = [ordered]@{
            schema_version = 1
            task_id        = ([string]$TaskId).Trim()
            status         = $st
            key_findings   = @($findings.items)
            evidence_refs  = @($refs.refs)
            changes        = [string]$texts['changes']
            validation     = [string]$texts['validation']
            blockers       = [string]$texts['blockers']
            risks          = [string]$texts['risks']
            recommendation = [string]$texts['recommendation']
            truncated      = [bool]$truncated
            created_at     = Get-EVStamp
        }
        $chk = Test-OrchestrationHandoffValid -Handoff $rec
        if ($null -eq $chk -or -not [bool]$chk.ok) {
            $why = 'invalid-handoff'
            if (($null -ne $chk) -and (-not [string]::IsNullOrWhiteSpace([string]$chk.reason))) { $why = [string]$chk.reason }
            return [pscustomobject]@{ ok = $false; reason = $why; handoff = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; handoff = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff'; handoff = $null }
    }
}

function Test-OrchestrationHandoffValid {
    [CmdletBinding()]
    param($Handoff = $null)
    try {
        if ($null -eq $Handoff) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        $sv = Get-EVValue $Handoff 'schema_version' $null
        if ($sv -is [array]) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        if (($sv -isnot [int]) -and ($sv -isnot [long]) -and ($sv -isnot [int16]) -and ($sv -isnot [byte]) -and ($sv -isnot [short])) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        if ([long]$sv -ne 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        $rawTask = Get-EVValue $Handoff 'task_id' $null
        if (-not ($rawTask -is [string])) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id' }
        }
        if (-not (Test-EVRefId ([string]$rawTask))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id' }
        }
        $rawStatus = Get-EVValue $Handoff 'status' ''
        if (-not ($rawStatus -is [string])) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-status' }
        }
        if (@(Get-EVHandoffStatuses) -cnotcontains ([string]$rawStatus)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-status' }
        }
        $kf = Get-EVValue $Handoff 'key_findings' $null
        # Flat empty lists read back as $null across the helper call;
        # that is empty (valid), not a missing field.
        if ($null -eq $kf) { $kf = @() }
        # A single stored finding reads back as a scalar string across
        # the helper call; that is one item (valid), not a bad shape.
        if (($kf -is [System.Collections.IDictionary])) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-key-findings' }
        }
        $kfArr = @($kf)
        if ($kfArr.Count -gt 10) {
            return [pscustomobject]@{ ok = $false; reason = 'too-many-findings' }
        }
        foreach ($item in $kfArr) {
            if (-not ($item -is [string])) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-key-findings' }
            }
            if (([string]$item).Length -gt 200) {
                return [pscustomobject]@{ ok = $false; reason = 'finding-too-long' }
            }
        }
        $er = Get-EVValue $Handoff 'evidence_refs' $null
        if ($null -eq $er) { $er = @() }
        # A single stored ref object reads back as a scalar dictionary
        # across the helper call; that is one item (valid), revalidated
        # field by field below (raw keys still forbidden).
        try { $erArr = @($er) } catch { return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs' } }
        foreach ($item in $erArr) {
            if ($item -is [string]) {
                if (-not (Test-EVRefId ([string]$item))) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-ref' }
                }
            }
            elseif (($item -is [System.Collections.IDictionary]) -or ($item -is [pscustomobject])) {
                $insp = Get-EVRawInspection -Object $item -Depth 0 -Seen $null
                if ($insp -ceq 'raw') {
                    return [pscustomobject]@{ ok = $false; reason = 'raw-payload-forbidden' }
                }
                if ($insp -ceq 'incomplete') {
                    return [pscustomobject]@{ ok = $false; reason = 'inspection-incomplete' }
                }
                if ($null -eq (ConvertTo-EVEvidenceRef $item)) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-ref' }
                }
            }
            else {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs' }
            }
        }
        foreach ($fname in @('changes', 'validation', 'blockers', 'risks', 'recommendation')) {
            $fv = Get-EVValue $Handoff $fname $null
            if ($null -eq $fv) {
                return [pscustomobject]@{ ok = $false; reason = ('invalid-' + $fname) }
            }
            if (-not ($fv -is [string])) {
                return [pscustomobject]@{ ok = $false; reason = ('invalid-' + $fname) }
            }
            if (([string]$fv).Length -gt 500) {
                return [pscustomobject]@{ ok = $false; reason = 'field-too-long' }
            }
        }
        $tr = Get-EVValue $Handoff 'truncated' $null
        if (-not ($tr -is [bool])) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        if ([string]::IsNullOrWhiteSpace((Get-EVInstant (Get-EVValue $Handoff 'created_at' '')))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-handoff' }
    }
}
