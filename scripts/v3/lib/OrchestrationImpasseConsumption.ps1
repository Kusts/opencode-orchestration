<#!
.SYNOPSIS
    Etapa 3 FULL_DELIVERY — consumo automatico do sinal de impasse.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1, ASCII-only,
    no network, no spawn. Reutiliza OrchestrationImpasseEscalation.ps1
    (Test-IEImpasseSignal) sem nova maquina de estados.

    Invoke-OrchestrationImpasseConsumption recebe progresso + historico +
    orcamento e devolve UMA intervencao (nunca fan-out). Classifica causa:
      missing-context -> gather-context (Explorer)
      technical-reproducible -> debug-reproduce (Debugger)
      model-limitation -> advisory-consult (Advisor/Jev, escalate-tier se high/critical)
      legit-block -> wait-legit (nenhum consultor, sem custo)
    Dedup: mesma (failure_kind + consultant) ja presente em History => skipped.
    Orcamento: MaxInterventions esgotado => blocked sem consultor.
    Consultores fornecem evidencia/recomendacao; grants_authority=false sempre.

    Etapa 3 REAL: o consultor e REALMENTE executado (nunca simulado):
      - Com -ConsultantExecutor injetado: invocado como
        & $ConsultantExecutor -Consultant <nome> -Intervention <id>
        -FailureKind <kind> -TaskRisk <risk>; retorno incorporado em
        `consultation` (evidence/recommendation).
      - Sem executor ($null): executor real default interno:
        explorer = coleta real de evidencia filesystem (Test-Path /
        Get-ChildItem do diretorio informado via -ContextDir ou cwd,
        NUNCA rede/spawn); debugger = reproducao real deterministica
        (executa -ReproScript se fornecido, senao coleta stack/arquivos);
        jev/advisor = chama libs existentes se presentes
        (Invoke-JevAdvisoryCall / Invoke-AdvisorConsultation) senao
        retorna advisory-only com recommendation_only=true.
    Toda intervencao real, se $EvidenceDir existir, anexa JSONL com
    {ts, failure_kind, consultant, intervention, recommendation,
    grants_authority:false}. NUNCA grants_authority=true,
    NUNCA done_approved=true.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Get-ICCValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    } catch { return $Default }
}

function Get-ICCContextDir {
    param([string]$ContextDir)
    try {
        $d = ([string]$ContextDir).Trim()
        if ((-not [string]::IsNullOrWhiteSpace($d)) -and (Test-Path -LiteralPath $d)) { return $d }
        return (Get-Location).Path
    } catch { return (Get-Location).Path }
}

function Get-ICCBoundedText {
    param([string]$Text, [int]$Max = 512)
    try {
        $t = ([string]$Text)
        if ($t.Length -gt $Max) { return $t.Substring(0, $Max) }
        return $t
    } catch { return '' }
}

function Get-ICCLocalFileEvidence {
    param([string]$Dir, [int]$MaxNames = 32)
    try {
        $names = @()
        try { $names = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop | Select-Object -ExpandProperty Name) } catch { $names = @() }
        $names = @($names | Sort-Object | Select-Object -First $MaxNames)
        $joined = ($names -join ',')
        $ev = ('dir=' + $Dir + '; files=' + $joined)
        if (@($names).Count -eq 0) { $ev = ($ev + '; empty=true') }
        return $ev
    } catch { return ('dir=' + $Dir + '; files=; list-error=true') }
}

function Invoke-ICCDefaultConsultant {
    [CmdletBinding()]
    param(
        [string]$Consultant = '',
        [string]$Intervention = '',
        [string]$FailureKind = '',
        [string]$TaskRisk = 'low',
        [string]$ContextDir = '',
        $ReproScript = $null
    )
    $c = ([string]$Consultant).Trim().ToLowerInvariant()
    $dir = Get-ICCContextDir -ContextDir $ContextDir
    try {
        if ($c -ceq 'explorer') {
            $ev = Get-ICCLocalFileEvidence -Dir $dir
            $rec = ('criar artefato ausente em ' + $dir)
            return [pscustomobject]@{
                consultant = 'explorer'; intervention = ([string]$Intervention)
                evidence = $ev; recommendation = $rec
                recommendation_only = $false; error = ''
            }
        }
        if ($c -ceq 'debugger') {
            if ($ReproScript -is [scriptblock]) {
                $raw = ''
                try {
                    $o = & $ReproScript
                    if ($null -eq $o) { $raw = 'repro-exit-null' }
                    elseif ($o -is [System.Collections.IEnumerable] -and (-not ($o -is [string]))) { $raw = ((@($o) | ForEach-Object { [string]$_ }) -join ';') }
                    else { $raw = ([string]$o) }
                } catch { $raw = ('repro-error: ' + $_.Exception.Message) }
                $ev = ('repro=' + (Get-ICCBoundedText -Text $raw -Max 512) + '; ' + (Get-ICCLocalFileEvidence -Dir $dir))
                return [pscustomobject]@{
                    consultant = 'debugger'; intervention = ([string]$Intervention)
                    evidence = $ev; recommendation = 'corrigir causa reproduzida e repetir tentativa'
                    recommendation_only = $false; error = ''
                }
            }
            $ev = ('repro=none; stack=local; ' + (Get-ICCLocalFileEvidence -Dir $dir))
            return [pscustomobject]@{
                consultant = 'debugger'; intervention = ([string]$Intervention)
                evidence = $ev; recommendation = 'investigar causa com evidencias locais e repetir tentativa'
                recommendation_only = $false; error = ''
            }
        }
        if ($c -ceq 'jev') {
            $libNote = 'lib-unavailable'
            try {
                $cmd = Get-Command Test-JevAdvisoryTrigger -ErrorAction SilentlyContinue
                if ($null -ne $cmd) {
                    $tr = $null
                    try { $tr = Test-JevAdvisoryTrigger -Descriptor @{ route_uncertain = $true } } catch { $tr = $null }
                    if ($null -ne $tr) { $libNote = ('trigger=' + [string](Get-ICCValue $tr 'trigger_reason' 'unknown')) }
                    else { $libNote = 'lib-present-fallback' }
                }
            } catch { $libNote = 'lib-error-fallback' }
            return [pscustomobject]@{
                consultant = 'jev'; intervention = ([string]$Intervention)
                evidence = ('advisory-only; ' + $libNote + '; kind=' + ([string]$FailureKind))
                recommendation = 'revisar decisao com cautela antes de escalar (advisory-only)'
                recommendation_only = $true; error = ''
            }
        }
        if ($c -ceq 'advisor') {
            $libNote = 'lib-unavailable'
            try {
                $cmd = Get-Command Invoke-AdvisorConsultation -ErrorAction SilentlyContinue
                if ($null -ne $cmd) {
                    try {
                        $req = @{
                            task_id = 'etapa3-impasse'
                            trigger_signal = ([string]$FailureKind)
                            justification = 'impasse-consumption'
                            question = 'como retomar apos impasse?'
                            context_summary = ('kind=' + ([string]$FailureKind) + '; risk=' + ([string]$TaskRisk))
                            alternatives_evaluated = @()
                            constraints = @()
                            known_evidence = @()
                            head_sha = ''
                        }
                        $resp = Invoke-AdvisorConsultation -Request $req -DisableNativeExecutor
                        $st = [string](Get-ICCValue $resp 'status' '')
                        if ([string]::IsNullOrWhiteSpace($st)) { $st = [string](Get-ICCValue $resp 'reason' 'consulted') }
                        $libNote = ('consulted=' + $st)
                    } catch { $libNote = 'lib-present-fallback' }
                }
            } catch { $libNote = 'lib-error-fallback' }
            return [pscustomobject]@{
                consultant = 'advisor'; intervention = ([string]$Intervention)
                evidence = ('advisory-only; ' + $libNote + '; kind=' + ([string]$FailureKind))
                recommendation = 'seguir orientacao do advisor sem ampliar autoridade (advisory-only)'
                recommendation_only = $true; error = ''
            }
        }
        return [pscustomobject]@{
            consultant = ([string]$Consultant); intervention = ([string]$Intervention)
            evidence = ''; recommendation = ''
            recommendation_only = $true; error = 'unknown-consultant'
        }
    } catch {
        return [pscustomobject]@{
            consultant = ([string]$Consultant); intervention = ([string]$Intervention)
            evidence = ''; recommendation = ''
            recommendation_only = $true; error = ('default-executor-error: ' + $_.Exception.Message)
        }
    }
}

function Write-ICCImpasseEvidence {
    [CmdletBinding()]
    param(
        [string]$EvidenceDir = '',
        [string]$FailureKind = '',
        [string]$Consultant = '',
        [string]$Intervention = '',
        [string]$Recommendation = ''
    )
    try {
        $d = ([string]$EvidenceDir).Trim()
        if ([string]::IsNullOrWhiteSpace($d)) { return $false }
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $false }
        $row = [ordered]@{
            ts = ([DateTime]::UtcNow.ToString('o'))
            failure_kind = ([string]$FailureKind)
            consultant = ([string]$Consultant)
            intervention = ([string]$Intervention)
            recommendation = (Get-ICCBoundedText -Text $Recommendation -Max 512)
            grants_authority = $false
        }
        $line = ''
        try { $line = ($row | ConvertTo-Json -Depth 4 -Compress) } catch { return $false }
        if ([string]::IsNullOrWhiteSpace($line)) { return $false }
        $file = Join-Path $d 'impasse-consumption.jsonl'
        try { Add-Content -LiteralPath $file -Value $line -Encoding UTF8 -ErrorAction Stop } catch { return $false }
        return $true
    } catch { return $false }
}

function Invoke-OrchestrationImpasseConsumption {
    [CmdletBinding()]
    param(
        $ProgressDelta = $null,
        [string]$LastFailure = '',
        [string]$TaskRisk = 'low',
        [string]$FailureKind = '',
        $History = @(),
        [int]$MaxInterventions = 3,
        [int]$StagnationThreshold = 3,
        [scriptblock]$ConsultantExecutor = $null,
        [string]$ContextDir = '',
        [scriptblock]$ReproScript = $null,
        [string]$EvidenceDir = ''
    )
    try {
        $lib = Join-Path $PSScriptRoot 'OrchestrationImpasseEscalation.ps1'
        if (Test-Path -LiteralPath $lib) { . $lib }
        $cmd = Get-Command Test-IEImpasseSignal -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return [pscustomobject]@{ ok = $false; reason = 'impasse-signal-unavailable'; impasse = $false; consultant = 'none'; grants_authority = $false }
        }
        $sig = $null
        try { $sig = Test-IEImpasseSignal -ProgressDelta $ProgressDelta -StagnationThreshold $StagnationThreshold -LastFailure $LastFailure -TaskRisk $TaskRisk } catch { $sig = $null }
        if ($null -eq $sig) {
            return [pscustomobject]@{ ok = $false; reason = 'impasse-signal-failed'; impasse = $false; consultant = 'none'; grants_authority = $false }
        }
        if (-not [bool](Get-ICCValue $sig 'impasse' $false)) {
            return [pscustomobject]@{ ok = $true; reason = 'no-impasse'; impasse = $false; consultant = 'none'; intervention = 'none'; signal = $sig; budget_remaining = $MaxInterventions; dedup_skipped = $false; grants_authority = $false; done_approved = $false }
        }
        $kind = ([string]$FailureKind).Trim().ToLowerInvariant()
        if ($kind -notin @('missing-context','technical-reproducible','model-limitation','legit-block')) {
            $kind = 'technical-reproducible'
        }
        $consultant = 'none'
        $intervention = 'none'
        switch ($kind) {
            'missing-context' { $consultant = 'explorer'; $intervention = 'gather-context' }
            'technical-reproducible' { $consultant = 'debugger'; $intervention = 'debug-reproduce' }
            'model-limitation' {
                if (([string]$TaskRisk).Trim().ToLowerInvariant() -in @('high','critical')) { $consultant = 'advisor'; $intervention = 'advisory-consult-escalate' }
                else { $consultant = 'jev'; $intervention = 'advisory-consult' }
            }
            'legit-block' { $consultant = 'none'; $intervention = 'wait-legit' }
        }
        if ($intervention -ceq 'wait-legit') {
            return [pscustomobject]@{ ok = $true; reason = 'legit-block-no-consult'; impasse = $true; consultant = 'none'; intervention = $intervention; failure_kind = $kind; signal = $sig; budget_remaining = $MaxInterventions; dedup_skipped = $false; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $used = 0
        try { $used = @($History).Count } catch { $used = 0 }
        if ($used -ge $MaxInterventions) {
            return [pscustomobject]@{ ok = $true; reason = 'budget-exhausted'; impasse = $true; consultant = 'none'; intervention = 'blocked-budget'; failure_kind = $kind; signal = $sig; budget_remaining = 0; dedup_skipped = $false; grants_authority = $false; done_approved = $false }
        }
        $dup = $false
        foreach ($h in @($History)) {
            $hk = ([string](Get-ICCValue $h 'failure_kind' '')).Trim().ToLowerInvariant()
            $hc = ([string](Get-ICCValue $h 'consultant' '')).Trim().ToLowerInvariant()
            if (($hk -ceq $kind) -and ($hc -ceq $consultant)) { $dup = $true; break }
        }
        if ($dup) {
            return [pscustomobject]@{ ok = $true; reason = 'duplicate-suppressed'; impasse = $true; consultant = $consultant; intervention = $intervention; failure_kind = $kind; signal = $sig; budget_remaining = ($MaxInterventions - $used); dedup_skipped = $true; grants_authority = $false; done_approved = $false }
        }
        $consultation = $null
        if ($null -ne $ConsultantExecutor) {
            try {
                $cr = & $ConsultantExecutor -Consultant $consultant -Intervention $intervention -FailureKind $kind -TaskRisk ([string]$TaskRisk)
                $consultation = [pscustomobject]@{
                    consultant = $consultant
                    intervention = $intervention
                    evidence = [string](Get-ICCValue $cr 'evidence' '')
                    recommendation = [string](Get-ICCValue $cr 'recommendation' '')
                    recommendation_only = [bool](Get-ICCValue $cr 'recommendation_only' $false)
                    error = [string](Get-ICCValue $cr 'error' '')
                }
            } catch {
                $consultation = [pscustomobject]@{
                    consultant = $consultant
                    intervention = $intervention
                    evidence = ''
                    recommendation = ''
                    recommendation_only = $true
                    error = ('consultant-error: ' + $_.Exception.Message)
                }
                return [pscustomobject]@{
                    ok = $false; reason = 'consultant-error'; impasse = $true; consultant = $consultant; intervention = $intervention
                    failure_kind = $kind; signal = $sig; consultation = $consultation
                    budget_remaining = ($MaxInterventions - $used); dedup_skipped = $false
                    grants_authority = $false; done_approved = $false; verified_pass = $false
                }
            }
        } else {
            $consultation = Invoke-ICCDefaultConsultant -Consultant $consultant -Intervention $intervention -FailureKind $kind -TaskRisk ([string]$TaskRisk) -ContextDir $ContextDir -ReproScript $ReproScript
        }
        $rec = ''
        try { $rec = [string](Get-ICCValue $consultation 'recommendation' '') } catch { $rec = '' }
        [void](Write-ICCImpasseEvidence -EvidenceDir $EvidenceDir -FailureKind $kind -Consultant $consultant -Intervention $intervention -Recommendation $rec)
        $entry = [ordered]@{ failure_kind = $kind; consultant = $consultant; intervention = $intervention; at = ([DateTime]::UtcNow.ToString('o')) }
        return [pscustomobject]@{
            ok = $true; reason = 'consult'; impasse = $true; consultant = $consultant; intervention = $intervention
            failure_kind = $kind; signal = $sig; history_entry = $entry; consultation = $consultation
            budget_remaining = ($MaxInterventions - $used - 1); dedup_skipped = $false
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'consumption-internal-error'; impasse = $false; consultant = 'none'; grants_authority = $false }
    }
}
