<#!
.SYNOPSIS
    V3 Technical Decision Records: pure record construction (SPEC v0.1.0 Phase 9).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure functions,
    fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns ok=$false with a
    machine-readable reason. No network, no process, no store, no
    kernel, no dispatch. This lib only builds and revalidates records;
    persistence/hydration wiring belongs to a later phase (never here).

    TDR-F9 (TDR records): New-OrchestrationTechnicalDecision builds one
    decision record from GoalId, TaskId, Question, Alternatives,
    Selected, Rationale, EvidenceRefs, Risk, Reversibility (plus
    optional DecidedBy). The record carries decision_id (first 16 hex
    chars of the SHA256 over the canonical content, timestamp
    excluded so the id is deterministic: same input yields same id),
    a UTC timestamp, and the SPEC section 19 minimum fields.
    Validation: question/selected/rationale must be non-empty,
    selected MUST appear in alternatives (else
    'selected-not-in-alternatives'), reversibility must be one of
    high|medium|low (else 'invalid-reversibility'). Identity is
    required at creation: goal_id, task_id, risk and decided_by must
    be non-empty (else 'invalid-goal-id' / 'invalid-task-id' /
    'invalid-risk' / 'invalid-decided-by').
    Test-OrchestrationTechnicalDecisionValid revalidates a record for
    hydration with the same rules without generating an id, including
    the strict identity check (empty goal_id, task_id, risk or
    decided_by fails with the same creation reason even when the
    stored hash matches), then recomputes the decision_id from the
    stored fields and compares it to the stored id (else
    'decision-id-mismatch'), so a tampered or cross-goal record never
    revalidates.
#>
[CmdletBinding()]
param()

function Get-TDField {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

# Length-prefixed chunk "len:value". The length prefix makes the encoding
# injective: separators ('|', newline) inside values can no longer merge
# distinct inputs into one canonical string (e.g. @('a','b|c') vs
# @('a','b','c'), or a newline split across two fields). NOTE: decision_id
# values for those previously-colliding inputs change under this scheme;
# ids are still deterministic (same input yields same id).
function Get-TDChunk {
    param([string]$Value = '')
    try {
        $s = [string]$Value
        return ([string]$s.Length + ':' + $s)
    }
    catch { return '0:' }
}

function Get-TDListChunk {
    param($Items)
    try {
        $list = @($Items)
        $parts = @()
        foreach ($it in $list) { $parts += (Get-TDChunk ([string]$it)) }
        return ([string]$list.Count + '#(' + ($parts -join ',') + ')')
    }
    catch { return '0#()' }
}

function Get-TDDecisionId {
    param(
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$Question = '',
        [string[]]$Alternatives = @(),
        [string]$Selected = '',
        [string]$Rationale = '',
        [string[]]$EvidenceRefs = @(),
        [string]$Risk = '',
        [string]$Reversibility = '',
        [string]$DecidedBy = ''
    )
    try {
        $canon = ((Get-TDChunk ([string]$GoalId)) + "`n" + (Get-TDChunk ([string]$TaskId)) + "`n" + (Get-TDChunk ([string]$Question)) + "`n" + (Get-TDListChunk (@($Alternatives) | ForEach-Object { [string]$_ })) + "`n" + (Get-TDChunk ([string]$Selected)) + "`n" + (Get-TDChunk ([string]$Rationale)) + "`n" + (Get-TDListChunk (@($EvidenceRefs) | ForEach-Object { [string]$_ })) + "`n" + (Get-TDChunk ([string]$Risk)) + "`n" + (Get-TDChunk ([string]$Reversibility)) + "`n" + (Get-TDChunk ([string]$DecidedBy)))
        $bytes = [Text.Encoding]::UTF8.GetBytes($canon)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($bytes)
        }
        finally {
            try { $sha.Dispose() } catch { }
        }
        $hex = ''
        foreach ($b in $hash) { $hex += $b.ToString('x2') }
        return $hex.Substring(0, 16).ToLowerInvariant()
    }
    catch { return '' }
}

function Test-TDDecisionFields {
    param($Question, $Alternatives, $Selected, $Rationale, $EvidenceRefs, $Reversibility)
    try {
        $q = ([string]$Question).Trim()
        if ([string]::IsNullOrWhiteSpace($q)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-question' }
        }
        $s = ([string]$Selected).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-selected' }
        }
        $r = ([string]$Rationale).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-rationale' }
        }
        $alts = @()
        if ($null -ne $Alternatives) {
            if ($Alternatives -is [string]) {
                if ([string]::IsNullOrWhiteSpace([string]$Alternatives)) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-alternatives' }
                }
                $alts = @([string]$Alternatives)
            }
            else {
                foreach ($item in @($Alternatives)) {
                    if (($null -eq $item) -or (-not ($item -is [string])) -or [string]::IsNullOrWhiteSpace([string]$item)) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-alternatives' }
                    }
                    $alts += ([string]$item).Trim()
                }
            }
        }
        $found = $false
        foreach ($a in @($alts)) {
            if ($s -ceq $a) { $found = $true; break }
        }
        if (-not $found) {
            return [pscustomobject]@{ ok = $false; reason = 'selected-not-in-alternatives' }
        }
        $rev = ([string]$Reversibility).Trim().ToLowerInvariant()
        if (@('high', 'medium', 'low') -cnotcontains $rev) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-reversibility' }
        }
        $ev = @()
        if ($null -ne $EvidenceRefs) {
            if ($EvidenceRefs -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$EvidenceRefs)) {
                    $ev = @(([string]$EvidenceRefs).Trim())
                }
            }
            else {
                foreach ($item in @($EvidenceRefs)) {
                    if ($null -eq $item) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs' }
                    }
                    if (-not ($item -is [string])) {
                        return [pscustomobject]@{ ok = $false; reason = 'invalid-evidence-refs' }
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                        $ev += ([string]$item).Trim()
                    }
                }
            }
        }
        return [pscustomobject]@{
            ok            = $true
            reason        = ''
            question      = $q
            alternatives  = [string[]]$alts
            selected      = $s
            rationale     = $r
            evidence_refs = [string[]]$ev
            reversibility = $rev
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-decision' }
    }
}

function Test-TDIdentity {
    param($GoalId, $TaskId, $Risk, $DecidedBy)
    try {
        $gid = ([string]$GoalId).Trim()
        $tid = ([string]$TaskId).Trim()
        $risk = ([string]$Risk).Trim()
        $by = ([string]$DecidedBy).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; goal_id = $gid; task_id = $tid; risk = $risk; decided_by = $by }
        }
        if ([string]::IsNullOrWhiteSpace($tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-task-id'; goal_id = $gid; task_id = $tid; risk = $risk; decided_by = $by }
        }
        if ([string]::IsNullOrWhiteSpace($risk)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-risk'; goal_id = $gid; task_id = $tid; risk = $risk; decided_by = $by }
        }
        if ([string]::IsNullOrWhiteSpace($by)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-decided-by'; goal_id = $gid; task_id = $tid; risk = $risk; decided_by = $by }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; goal_id = $gid; task_id = $tid; risk = $risk; decided_by = $by }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-decision'; goal_id = ''; task_id = ''; risk = ''; decided_by = '' }
    }
}

function Get-TDStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

function New-OrchestrationTechnicalDecision {
    <#
    .SYNOPSIS
        Pure TDR record construction (TDR-F9).
    .DESCRIPTION
        Builds one technical-decision record with a deterministic
        decision_id (content hash, 16 hex chars) and a UTC timestamp.
        Returns ok=$false with a machine-readable reason on any rule
        violation; never throws, never returns $null.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$Question = '',
        $Alternatives = @(),
        [string]$Selected = '',
        [string]$Rationale = '',
        $EvidenceRefs = @(),
        [string]$Risk = '',
        [string]$Reversibility = '',
        [string]$DecidedBy = ''
    )
    try {
        $v = Test-TDDecisionFields -Question $Question -Alternatives $Alternatives -Selected $Selected -Rationale $Rationale -EvidenceRefs $EvidenceRefs -Reversibility $Reversibility
        if (-not [bool]$v.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$v.reason; decision = $null }
        }
        $ident = Test-TDIdentity -GoalId $GoalId -TaskId $TaskId -Risk $Risk -DecidedBy $DecidedBy
        if (-not [bool]$ident.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$ident.reason; decision = $null }
        }
        $gid = [string]$ident.goal_id
        $tid = [string]$ident.task_id
        $risk = [string]$ident.risk
        $by = [string]$ident.decided_by
        $id = Get-TDDecisionId -GoalId $gid -TaskId $tid -Question ([string]$v.question) -Alternatives ([string[]]$v.alternatives) -Selected ([string]$v.selected) -Rationale ([string]$v.rationale) -EvidenceRefs ([string[]]$v.evidence_refs) -Risk $risk -Reversibility ([string]$v.reversibility) -DecidedBy $by
        if ([string]::IsNullOrWhiteSpace($id)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-decision'; decision = $null }
        }
        $rec = [PSCustomObject][ordered]@{
            decision_id   = $id
            goal_id       = $gid
            task_id       = $tid
            question      = ([string]$v.question)
            alternatives  = ([string[]]$v.alternatives)
            selected      = ([string]$v.selected)
            rationale     = ([string]$v.rationale)
            evidence_refs = ([string[]]$v.evidence_refs)
            risk          = $risk
            reversibility = ([string]$v.reversibility)
            timestamp     = (Get-TDStamp)
            decided_by    = $by
        }
        return [pscustomobject]@{ ok = $true; reason = ''; decision = $rec }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-decision'; decision = $null }
    }
}

function Test-OrchestrationTechnicalDecisionValid {
    <#
    .SYNOPSIS
        Pure TDR revalidation for hydration (TDR-F9).
    .DESCRIPTION
        Applies the same rules as New-OrchestrationTechnicalDecision
        to an existing record (hashtable or PSObject) without
        generating an id. Returns ok=$false with the same
        machine-readable reasons; never throws.
    #>
    [CmdletBinding()]
    param($Decision = $null)
    try {
        if (($null -eq $Decision) -or ((-not ($Decision -is [System.Collections.IDictionary])) -and (-not ($Decision -is [pscustomobject])))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-decision' }
        }
        $v = Test-TDDecisionFields -Question (Get-TDField $Decision 'question') -Alternatives (Get-TDField $Decision 'alternatives') -Selected (Get-TDField $Decision 'selected') -Rationale (Get-TDField $Decision 'rationale') -EvidenceRefs (Get-TDField $Decision 'evidence_refs') -Reversibility (Get-TDField $Decision 'reversibility')
        if (-not [bool]$v.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$v.reason }
        }
        $ident = Test-TDIdentity -GoalId (Get-TDField $Decision 'goal_id') -TaskId (Get-TDField $Decision 'task_id') -Risk (Get-TDField $Decision 'risk') -DecidedBy (Get-TDField $Decision 'decided_by')
        if (-not [bool]$ident.ok) {
            return [pscustomobject]@{ ok = $false; reason = [string]$ident.reason }
        }
        $storedId = [string](Get-TDField $Decision 'decision_id')
        if ([string]::IsNullOrWhiteSpace($storedId)) {
            return [pscustomobject]@{ ok = $false; reason = 'decision-id-mismatch' }
        }
        $reId = Get-TDDecisionId -GoalId ([string]$ident.goal_id) -TaskId ([string]$ident.task_id) -Question ([string]$v.question) -Alternatives ([string[]]$v.alternatives) -Selected ([string]$v.selected) -Rationale ([string]$v.rationale) -EvidenceRefs ([string[]]$v.evidence_refs) -Risk ([string]$ident.risk) -Reversibility ([string]$v.reversibility) -DecidedBy ([string]$ident.decided_by)
        if ([string]::IsNullOrWhiteSpace($reId) -or ($storedId -cne $reId)) {
            return [pscustomobject]@{ ok = $false; reason = 'decision-id-mismatch' }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-decision' }
    }
}
