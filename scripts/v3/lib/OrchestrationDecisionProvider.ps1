<#!
.SYNOPSIS
    V3 Decision Provider: provider-neutral decision layer (SPEC v0.1.0 Phase 4).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Implements the new
    provider-neutral layer from SPEC v0.1.0 section 9 (PR-E, Phase 4):

      deterministic RulesProvider -> JevProvider -> Planner escalation.

    RulesProvider resolves everything fully encodable (empty set refusal,
    single-alternative shortcut, authority reservation, model-override
    reservation). JevProvider is consulted only when admitted, and Jev
    output is advisory evidence only: it is filtered by a local grant-gate
    equivalent and can never decide alone. Anything Jev cannot or must not
    resolve falls back to an honest Planner escalation envelope that never
    blocks the Objective.

    DEVIATION (TDR-F4-04, honest): this phase does NOT touch
    OrchestrationPlannerLoop.ps1 nor OrchestrationJevAdvisory.ps1. The
    provider COMPOSES the existing guards instead of reusing them: it
    reimplements only the cannot/model check locally and conservatively
    (substring authority match plus the TDR-F4-03 model regex) without
    importing state from the other lib and without calling any transport.
    Loop/dispatch wiring belongs to Phase 5. No real network exists here:
    the only Jev seam is the caller-supplied -JevProbe scriptblock used by
    the suite; a null probe means Jev is unavailable and yields the
    deterministic escalation fallback.

    PowerShell 5.1 compatible. ASCII-only. Expected domain results are
    returned as result objects, never thrown across the boundary.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:DecisionProviderQuestionTypes = @(
    'routing', 'specialist', 'continue', 'parallel',
    'evidence', 'risk', 'hypothesis', 'alternative'
)
$script:DecisionProviderAuthorityKeywords = @(
    'grant', 'permission', 'scope', 'model', 'provider', 'variant',
    'production', 'destructive', 'secret', 'credential', 'done',
    'approve', 'verifier', 'reviewer', 'security'
)
$script:DecisionProviderAuthorityCannot = @(
    'grant-permission', 'widen-scope', 'select-model', 'bypass-human-approval',
    'override-verifier', 'override-reviewer', 'override-security', 'write-done'
)
$script:DecisionProviderModelPattern = '(?i)(\bmodel\b|\bprovider\b|\bvariant\b|\bllm\b|\bgpt\b|\bclaude\b|\bmuse\b|\bsonnet\b|\bopus\b|\bhaiku\b|select-model)'
$script:DecisionProviderOverreachPattern = '(?i)(grant|permission|widen|scope|production|destructive|secret|credential|done|approve|verifier|reviewer|security|bypass|override)'
$script:DecisionProviderMaxAlternatives = 8
$script:DecisionProviderMinConfidence = 0.5

function Get-DecisionProviderField {
    <#
    .SYNOPSIS
        Reads one named field from a hashtable or PSObject, returning
        $null when absent. Never throws.
    #>
    [CmdletBinding()]
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Test-DecisionProviderAuthorityHit {
    <#
    .SYNOPSIS
        Conservative substring match (case-insensitive) against the
        authority-reserved keyword list. Any hit means the question or
        the alternatives touch authority and must be refused. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($t)) { return $false }
        foreach ($kw in @($script:DecisionProviderAuthorityKeywords)) {
            if ($t -like ('*' + $kw + '*')) { return $true }
        }
        return $false
    }
    catch { return $true }
}

function Test-DecisionProviderCannotHit {
    <#
    .SYNOPSIS
        Closed-list match against the 8 authority cannot entries (fail-closed
        backstop for exact reserved forms such as bypass-human-approval that
        the loose keyword scan does not catch). Case-insensitive substring
        with hyphens/underscores normalized. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($t)) { return $false }
        $norm = $t.ToLowerInvariant().Replace('_', '-')
        foreach ($c in @($script:DecisionProviderAuthorityCannot)) {
            $cn = ([string]$c).ToLowerInvariant().Replace('_', '-')
            if ([string]::IsNullOrWhiteSpace($cn)) { continue }
            if ($norm.Contains($cn)) { return $true }
        }
        return $false
    }
    catch { return $true }
}

function Test-DecisionProviderModelHit {
    <#
    .SYNOPSIS
        TDR-F4-03 anti-model-override scan (Issue #19): the model regex
        plus select-model against one text. Any hit means a model/provider
        selection is requested. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($t)) { return $false }
        return ([regex]::IsMatch($t, [string]$script:DecisionProviderModelPattern))
    }
    catch { return $true }
}

function Test-DecisionProviderOverreachHit {
    <#
    .SYNOPSIS
        Local grant-gate equivalent for Jev output: any signal of
        grant/widen/authority/done in the advised text discards the
        advice. Never throws.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text)
        if ([string]::IsNullOrWhiteSpace($t)) { return $false }
        return ([regex]::IsMatch($t, [string]$script:DecisionProviderOverreachPattern))
    }
    catch { return $true }
}

function Get-DecisionProviderUsefulStateCount {
    <#
    .SYNOPSIS
        Counts useful State keys: a key with a non-blank name and a
        non-null, non-blank value. Zero means there is nothing for Jev to
        decide on. Never throws.
    #>
    [CmdletBinding()]
    param($State)
    try {
        if ($null -eq $State) { return 0 }
        $n = 0
        if ($State -is [System.Collections.IDictionary]) {
            foreach ($k in @($State.Keys)) {
                $name = ([string]$k).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $v = $null
                try { $v = $State[$k] } catch { $v = $null }
                if ($null -eq $v) { continue }
                if (($v -is [string]) -and [string]::IsNullOrWhiteSpace($v)) { continue }
                $n++
            }
            return $n
        }
        foreach ($p in @($State.PSObject.Properties)) {
            $name = ([string]$p.Name).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $v = $null
            try { $v = $p.Value } catch { $v = $null }
            if ($null -eq $v) { continue }
            if (($v -is [string]) -and [string]::IsNullOrWhiteSpace($v)) { continue }
            $n++
        }
        return $n
    }
    catch { return 0 }
}

function Add-DecisionProviderProbeValue {
    <#
    .SYNOPSIS
        Recursive accumulator for Get-DecisionProviderProbeText. Collects
        strings up to depth 4 into $Acc.parts and flips $Acc.complete to
        false on anything uninspected: more than 16 strings, a string longer
        than 512 chars, an access/enumeration error, content nested deeper
        than depth 4, or an uninspectable object type. Never throws.
    #>
    [CmdletBinding()]
    param($Value, [int]$Depth, $Acc)
    try {
        if ($null -eq $Value) { return }
        if ([int]$Depth -gt 4) {
            $empty = $true
            try {
                if ($Value -is [string]) { $empty = [string]::IsNullOrWhiteSpace([string]$Value) }
                elseif ($Value -is [System.Collections.IDictionary]) { $empty = (@($Value.Keys).Count -eq 0) }
                elseif ($Value -is [System.Collections.IList]) { $empty = (@($Value).Count -eq 0) }
                elseif ($Value -is [System.Management.Automation.PSCustomObject]) { $empty = (@($Value.PSObject.Properties).Count -eq 0) }
                else { $empty = $false }
            }
            catch { $empty = $false }
            if (-not $empty) { $Acc['complete'] = $false }
            return
        }
        if ($Value -is [string]) {
            $s = ([string]$Value)
            if ([string]::IsNullOrWhiteSpace($s)) { return }
            $Acc['count'] = [int]$Acc['count'] + 1
            if ([int]$Acc['count'] -gt 16) { $Acc['complete'] = $false; return }
            if ($s.Length -gt 512) { $Acc['complete'] = $false; $s = $s.Substring(0, 512) }
            $Acc['parts'].Add($s) | Out-Null
            return
        }
        if ($Value -is [System.Collections.IDictionary]) {
            $keys = @()
            try { $keys = @($Value.Keys) } catch { $Acc['complete'] = $false; return }
            foreach ($k in @($keys)) {
                $item = $null
                try { $item = $Value[$k] } catch { $Acc['complete'] = $false; continue }
                Add-DecisionProviderProbeValue -Value $item -Depth ([int]$Depth + 1) -Acc $Acc
            }
            return
        }
        if ($Value -is [System.Collections.IList]) {
            $items = @()
            try { $items = @($Value) } catch { $Acc['complete'] = $false; return }
            foreach ($item in @($items)) {
                Add-DecisionProviderProbeValue -Value $item -Depth ([int]$Depth + 1) -Acc $Acc
            }
            return
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $props = @()
            try { $props = @($Value.PSObject.Properties) } catch { $Acc['complete'] = $false; return }
            foreach ($p in @($props)) {
                $item = $null
                try { $item = $p.Value } catch { $Acc['complete'] = $false; continue }
                Add-DecisionProviderProbeValue -Value $item -Depth ([int]$Depth + 1) -Acc $Acc
            }
            return
        }
        $vt = $null
        try { $vt = $Value.GetType() } catch { $Acc['complete'] = $false; return }
        if ($vt.IsPrimitive -or ($Value -is [decimal]) -or ($Value -is [datetime]) -or ($Value -is [guid])) { return }
        $Acc['complete'] = $false
        return
    }
    catch { $Acc['complete'] = $false }
}

function Get-DecisionProviderProbeText {
    <#
    .SYNOPSIS
        Joins every string field (recursive to depth 4, bounded) of a probe
        result so the overreach/model scans see hostile payloads wherever
        they hide. Returns @{ text = <joined>; complete = <bool> };
        complete=false means the text was NOT fully inspected (too many
        strings, overlong string, access error, deeper nesting or unknown
        type) and the caller must escalate fail-closed. Never throws.
    #>
    [CmdletBinding()]
    param($ProbeResult)
    try {
        if ($null -eq $ProbeResult) { return @{ text = ''; complete = $true } }
        $acc = @{
            parts    = (New-Object System.Collections.Generic.List[string])
            complete = $true
            count    = 0
        }
        Add-DecisionProviderProbeValue -Value $ProbeResult -Depth 0 -Acc $acc
        return @{ text = ([string]::Join('|', $acc['parts'].ToArray())); complete = [bool]$acc['complete'] }
    }
    catch { return @{ text = ''; complete = $false } }
}

function New-OrchestrationDecisionEnvelope {
    <#
    .SYNOPSIS
        Builds the closed decision envelope. blocked is always false:
        no path here may ever block the Objective. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$QuestionId = '',
        [string]$QuestionType = '',
        [string]$Decision = '',
        [string]$Source = 'planner-escalation',
        [double]$Confidence = 0.0,
        [int]$AlternativesConsidered = 0,
        [bool]$FallbackUsed = $true,
        [string]$Reason = ''
    )
    try {
        $conf = 0.0
        try { $conf = [double]$Confidence } catch { $conf = 0.0 }
        if ([double]::IsNaN($conf) -or [double]::IsInfinity($conf)) { $conf = 0.0 }
        if ($conf -lt 0.0) { $conf = 0.0 }
        if ($conf -gt 1.0) { $conf = 1.0 }
        $src = ([string]$Source).Trim().ToLowerInvariant()
        if (@('rules', 'jev', 'planner-escalation', 'refused') -cnotcontains $src) {
            $src = 'planner-escalation'
        }
        return [PSCustomObject][ordered]@{
            question_id            = ([string]$QuestionId)
            question_type          = ([string]$QuestionType)
            decision               = ([string]$Decision)
            source                 = $src
            confidence             = $conf
            alternatives_considered = [int]$AlternativesConsidered
            fallback_used          = [bool]$FallbackUsed
            blocked                = $false
            reason                 = ([string]$Reason)
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            question_id            = ''
            question_type          = ''
            decision               = ''
            source                 = 'planner-escalation'
            confidence             = 0.0
            alternatives_considered = 0
            fallback_used          = $true
            blocked                = $false
            reason                 = 'envelope-internal'
        }
    }
}

function Invoke-OrchestrationDecision {
    <#
    .SYNOPSIS
        Provider-neutral decision entry point (TDR-F4-01..F4-03).
    .DESCRIPTION
        Pipeline: (1) RulesProvider refuses unknown question types,
        empty alternative sets, authority touches and model-override
        requests, and shortcuts a single clean alternative; (2) JevProvider
        is consulted only when admitted (TDR-F4-02); (3) every outcome is
        the closed envelope, Jev output filtered by the local grant-gate
        equivalent (Jev never decides alone). Never throws: every failure
        is an honest planner-escalation envelope with blocked=false.
    #>
    [CmdletBinding()]
    param(
        [string]$QuestionId = '',
        [string]$QuestionType = '',
        [object[]]$Alternatives = @(),
        $State = $null,
        [string]$Risk = 'low',
        [bool]$AllowJev = $true,
        [scriptblock]$JevProbe = $null
    )
    try {
        $qid = ([string]$QuestionId).Trim()
        $qtype = ([string]$QuestionType).Trim().ToLowerInvariant()
        $risk = ([string]$Risk).Trim().ToLowerInvariant()

        $alts = New-Object System.Collections.Generic.List[string]
        if ($null -ne $Alternatives) {
            foreach ($a in @($Alternatives)) {
                $s = ([string]$a).Trim()
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $alts.Add($s) | Out-Null
            }
        }
        $n = [int]$alts.Count

        # (1a) closed question types (TDR-F4-01)
        if ($script:DecisionProviderQuestionTypes -cnotcontains $qtype) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'refused' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $false -Reason 'unknown-question-type')
        }

        # (1b) empty set refusal
        if ($n -lt 1) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'refused' -Confidence 0.0 `
                -AlternativesConsidered 0 -FallbackUsed $false -Reason 'no-alternatives')
        }

        # (1c) authority reservation BEFORE any shortcut: a single hostile
        # alternative must be refused, never granted (TDR-F4-01). Both the
        # loose keyword scan and the closed 8-cannot backstop (exact forms
        # such as bypass-human-approval) apply to the QuestionId and to
        # EVERY alternative.
        if (Test-DecisionProviderAuthorityHit -Text $qid) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'refused' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $false -Reason 'authority-reserved')
        }
        if (Test-DecisionProviderCannotHit -Text $qid) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'refused' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $false -Reason 'authority-reserved')
        }
        foreach ($s in @($alts.ToArray())) {
            if (Test-DecisionProviderAuthorityHit -Text $s) {
                return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                    -Decision '' -Source 'refused' -Confidence 0.0 `
                    -AlternativesConsidered $n -FallbackUsed $false -Reason 'authority-reserved')
            }
            if (Test-DecisionProviderCannotHit -Text $s) {
                return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                    -Decision '' -Source 'refused' -Confidence 0.0 `
                    -AlternativesConsidered $n -FallbackUsed $false -Reason 'authority-reserved')
            }
        }

        # (1d) model-override reservation on the QuestionId and on every
        # alternative (TDR-F4-03)
        if (Test-DecisionProviderModelHit -Text $qid) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'refused' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $false -Reason 'model-selection-reserved')
        }
        foreach ($s in @($alts.ToArray())) {
            if (Test-DecisionProviderModelHit -Text $s) {
                return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                    -Decision '' -Source 'refused' -Confidence 0.0 `
                    -AlternativesConsidered $n -FallbackUsed $false -Reason 'model-selection-reserved')
            }
        }

        # (1e) single clean alternative: RulesProvider decides alone
        if ($n -eq 1) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision ([string]$alts[0]) -Source 'rules' -Confidence 1.0 `
                -AlternativesConsidered 1 -FallbackUsed $false -Reason 'single-alternative')
        }

        # (2) Jev admission (TDR-F4-02, utilitarian, no task-class veto)
        if ($risk -ceq 'high') {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'high-risk-no-jev')
        }
        if (($risk -cne 'low') -and ($risk -cne 'medium')) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'invalid-risk-escalation')
        }
        if ([int]$n -gt [int]$script:DecisionProviderMaxAlternatives) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'too-many-alternatives-no-jev')
        }
        if ([int](Get-DecisionProviderUsefulStateCount -State $State) -lt 1) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'state-empty-no-jev')
        }
        if (-not [bool]$AllowJev) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-disabled-by-caller')
        }

        # (3) Jev unavailable: honest deterministic fallback, never blocks
        if ($null -eq $JevProbe) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-unavailable-escalation')
        }

        # (4) Jev call through the synthetic seam only (no real transport
        # in this phase); a throwing probe (timeout included) escalates
        $ctx = @{ question_id = $qid; question_type = $qtype; alternatives = $alts.ToArray(); risk = $risk }
        try {
            if ($null -ne $State) { $ctx['state'] = $State }
        }
        catch { }
        $raw = $null
        try { $raw = (& $JevProbe $ctx) }
        catch {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-failed-escalation')
        }

        # (5) malformed probe results escalate (TDR-F4-02)
        if ($null -eq $raw) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-malformed-escalation')
        }
        $picked = ([string](Get-DecisionProviderField -Object $raw -Name 'decision')).Trim()
        if ([string]::IsNullOrWhiteSpace($picked)) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-malformed-escalation')
        }
        $confRaw = Get-DecisionProviderField -Object $raw -Name 'confidence'
        if (($null -eq $confRaw) -or (($confRaw -is [string]) -and [string]::IsNullOrWhiteSpace([string]$confRaw))) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-malformed-escalation')
        }
        # Strict numeric-type gate: confidence must already be a real
        # numeric type before any conversion. Strings (even numeric
        # ones like '0.9'), bools and any other non-numeric type
        # escalate here so PowerShell coercion can never accept them.
        # Same low-confidence reason as the other invalid values so no
        # new verdict proliferates. ([float] is [single], one check
        # covers both.)
        if (-not ($confRaw -is [int] -or $confRaw -is [long] -or $confRaw -is [double] -or $confRaw -is [decimal] -or $confRaw -is [single])) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-low-confidence-escalation')
        }
        $conf = [double]::NaN
        try { $conf = [double]$confRaw } catch { $conf = [double]::NaN }
        if ([double]::IsNaN($conf) -or [double]::IsInfinity($conf)) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-malformed-escalation')
        }
        $known = $false
        foreach ($s in @($alts.ToArray())) {
            if ([string]$s -ceq [string]$picked) { $known = $true; break }
        }
        if (-not $known) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-decision-not-in-alternatives')
        }
        if ($conf -lt [double]$script:DecisionProviderMinConfidence) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-low-confidence-escalation')
        }
        if ($conf -gt 1.0) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-low-confidence-escalation')
        }

        # (6) Jev never decides alone: the advice text must be COMPLETE
        # before any scan trusts it; a truncated/inaccessible/deep payload
        # escalates fail-closed and is never accepted (no silent clamp).
        # Only then filter the advice through the local grant-gate
        # equivalent; model-override first (specific reason), then the
        # general overreach sweep (TDR-F4-01, TDR-F4-03)
        $probeInfo = Get-DecisionProviderProbeText -ProbeResult $raw
        $probeText = ''
        $probeComplete = $false
        try {
            if ($probeInfo -is [System.Collections.IDictionary]) {
                if ($probeInfo.Contains('text')) { $probeText = ([string]$probeInfo['text']) }
                if ($probeInfo.Contains('complete')) { $probeComplete = [bool]$probeInfo['complete'] }
            }
            elseif ($probeInfo -is [string]) { $probeText = $probeInfo; $probeComplete = $true }
            else { $probeComplete = $false }
        }
        catch { $probeComplete = $false }
        if (-not $probeComplete) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-inspection-incomplete')
        }
        if (Test-DecisionProviderModelHit -Text $probeText) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-model-override-discarded')
        }
        if (Test-DecisionProviderOverreachHit -Text $probeText) {
            return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
                -Decision '' -Source 'planner-escalation' -Confidence 0.0 `
                -AlternativesConsidered $n -FallbackUsed $true -Reason 'jev-overreach-discarded')
        }

        # (7) clean advice is accepted as Jev-sourced evidence
        return (New-OrchestrationDecisionEnvelope -QuestionId $qid -QuestionType $qtype `
            -Decision $picked -Source 'jev' -Confidence $conf `
            -AlternativesConsidered $n -FallbackUsed $false -Reason 'jev-advice-accepted')
    }
    catch {
        return (New-OrchestrationDecisionEnvelope -QuestionId ([string]$QuestionId) `
            -QuestionType ([string]$QuestionType) -Decision '' -Source 'planner-escalation' `
            -Confidence 0.0 -AlternativesConsidered 0 -FallbackUsed $true -Reason 'decision-internal-escalation')
    }
}
