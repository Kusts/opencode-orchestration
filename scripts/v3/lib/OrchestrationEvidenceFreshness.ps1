<#!
.SYNOPSIS
    Validação de frescor de evidências antes de DONE e transições consequenciais (Issue #106).
.DESCRIPTION
    Implementa as regras de Evidence Refresh da Issue #106:
      - Detecção de evidência obsoleta (stale-age, head-mismatch, superseded).
      - Prevenção de falso DONE ou transição consequencial baseada em evidência desatualizada.
      - Resolução determinística e orientada a risco sem busy polling.
    Compatível com PowerShell 5.1 e PowerShell 7. ASCII-only. Read-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-EvidenceFieldValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
}

function ConvertTo-UtcDateTimeOffset {
    param([string]$Stamp)
    if ([string]::IsNullOrWhiteSpace($Stamp)) { return [DateTimeOffset]::MinValue }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Stamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return [DateTimeOffset]::MinValue
}

function Test-OrchestrationEvidenceFreshness {
    <#
    .SYNOPSIS
        Avalia o frescor de uma referência ou registro de evidência.
    .DESCRIPTION
        Retorna um envelope com verdict:
          'fresh'               = evidência válida, recente e com HEAD coincidente
          'stale-head-mismatch' = HEAD do repositório mudou desde a coleta da evidência
          'stale-age-exceeded'  = evidência expirou o limite de idade (MaxAgeSeconds)
          'stale-superseded'    = evidência foi explicitamente substituída
          'invalid-evidence'    = objeto de evidência malformado ou incompleto
    #>
    [CmdletBinding()]
    param(
        $Evidence,
        [string]$CurrentHeadSha = '',
        [int]$MaxAgeSeconds = 3600,
        [string]$NowUtc = '',
        [string]$TargetTransition = ''
    )

    if ($null -eq $Evidence) {
        return [pscustomobject]@{
            ok               = $false
            verdict          = 'invalid-evidence'
            reason           = 'evidence-null'
            refresh_required = $true
            target           = $TargetTransition
        }
    }

    $evHead = [string](Get-EvidenceFieldValue $Evidence 'head_sha' '')
    $evStamp = [string](Get-EvidenceFieldValue $Evidence 'timestamp' '')
    $evSuperseded = [bool](Get-EvidenceFieldValue $Evidence 'superseded' $false)

    if ($evSuperseded) {
        return [pscustomobject]@{
            ok               = $false
            verdict          = 'stale-superseded'
            reason           = 'evidence-explicitly-superseded'
            refresh_required = $true
            target           = $TargetTransition
        }
    }

    # 1. Checagem de divergência de HEAD (mudança de commit invalida teste/CI prévio)
    if (-not [string]::IsNullOrWhiteSpace($CurrentHeadSha) -and -not [string]::IsNullOrWhiteSpace($evHead)) {
        if (-not [string]::Equals($CurrentHeadSha.Trim(), $evHead.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                ok               = $false
                verdict          = 'stale-head-mismatch'
                reason           = "head-drift: evidence on $evHead vs current $CurrentHeadSha"
                refresh_required = $true
                target           = $TargetTransition
            }
        }
    }

    # 2. Checagem de limite temporal de frescor
    if ($MaxAgeSeconds -gt 0 -and -not [string]::IsNullOrWhiteSpace($evStamp)) {
        $evInstant = ConvertTo-UtcDateTimeOffset -Stamp $evStamp
        if ($evInstant -eq [DateTimeOffset]::MinValue) {
            return [pscustomobject]@{
                ok               = $false
                verdict          = 'invalid-evidence'
                reason           = 'timestamp-unparseable'
                refresh_required = $true
                target           = $TargetTransition
            }
        }

        $nowInstant = [DateTimeOffset]::UtcNow
        if (-not [string]::IsNullOrWhiteSpace($NowUtc)) {
            $parsedNow = ConvertTo-UtcDateTimeOffset -Stamp $NowUtc
            if ($parsedNow -ne [DateTimeOffset]::MinValue) {
                $nowInstant = $parsedNow
            }
        }

        $elapsedSeconds = ($nowInstant - $evInstant).TotalSeconds
        if ($elapsedSeconds -gt $MaxAgeSeconds) {
            return [pscustomobject]@{
                ok               = $false
                verdict          = 'stale-age-exceeded'
                reason           = "age-exceeded: elapsed $($elapsedSeconds)s exceeds limit $($MaxAgeSeconds)s"
                refresh_required = $true
                target           = $TargetTransition
            }
        }
    }

    return [pscustomobject]@{
        ok               = $true
        verdict          = 'fresh'
        reason           = 'evidence-current-and-matching'
        refresh_required = $false
        target           = $TargetTransition
    }
}

function Test-OrchestrationDoneAllowedByEvidence {
    <#
    .SYNOPSIS
        Valida que o conjunto de evidências para OBJECTIVE_DONE não contenha itens stale.
    #>
    [CmdletBinding()]
    param(
        [array]$EvidenceItems,
        [string]$CurrentHeadSha = '',
        [int]$MaxAgeSeconds = 3600,
        [string]$NowUtc = ''
    )

    if ($null -eq $EvidenceItems -or $EvidenceItems.Count -eq 0) {
        return [pscustomobject]@{
            allowed = $false
            reason  = 'no-evidence-provided'
            stale_items = @()
        }
    }

    $staleItems = New-Object System.Collections.ArrayList

    foreach ($item in $EvidenceItems) {
        $eval = Test-OrchestrationEvidenceFreshness -Evidence $item -CurrentHeadSha $CurrentHeadSha -MaxAgeSeconds $MaxAgeSeconds -NowUtc $NowUtc -TargetTransition 'OBJECTIVE_DONE'
        if (-not [bool]$eval.ok) {
            [void]$staleItems.Add([pscustomobject]@{
                item    = $item
                verdict = $eval.verdict
                reason  = $eval.reason
            })
        }
    }

    if ($staleItems.Count -gt 0) {
        return [pscustomobject]@{
            allowed     = $false
            reason      = 'EVIDENCE_STALE_BLOCKED'
            stale_items = @($staleItems)
        }
    }

    return [pscustomobject]@{
        allowed     = $true
        reason      = 'all-evidence-fresh'
        stale_items = @()
    }
}
