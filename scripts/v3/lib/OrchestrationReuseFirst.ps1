<#
.SYNOPSIS
    Proportional Reuse-First Library (P2, Issues #4, #106, #146).
.DESCRIPTION
    Dot-sourceable library (no execution on load).
    Implements hierarchical, proportional reuse:
      Level 1: Exact match on commit HEAD, file fingerprints, environment and criteria (T0 - zero tokens).
      Level 2: AI Memory project context lookup (consultative only, bounded).
      Level 3: Full re-execution fallback when evidence is stale, drifted, or absent.
    Preserves invariants: Memory is never runtime truth; no parallel database created;
    task_id alone is never accepted as proof of validity.
    PowerShell 5.1 and 7+ compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $storeLib = Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1'
    if (Test-Path -LiteralPath $storeLib) { . $storeLib }
    $freshnessLib = Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1'
    if (Test-Path -LiteralPath $freshnessLib) { . $freshnessLib }
    $reuseWiringLib = Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1'
    if (Test-Path -LiteralPath $reuseWiringLib) { . $reuseWiringLib }
}
catch { }

function Test-OrchestrationReusableApplicability {
    <#
    .SYNOPSIS
        Valida rigorosamente se uma evidencia candidata a reuso permanece aplicavel no disco.
    .DESCRIPTION
        Garante que requisitos de SHA, criterios, escopo e ambiente nao sejam ignorados por campos vazios.
        Verifica a integridade dos arquivos no disco atual contra os fingerprints gravados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Evidence,

        [Parameter(Mandatory = $false)]
        [string]$CurrentHeadSha = '',

        [Parameter(Mandatory = $false)]
        [string[]]$CurrentScope = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$CurrentSourceFingerprints = @{},

        [Parameter(Mandatory = $false)]
        [string]$CurrentCriteriaHash = '',

        [Parameter(Mandatory = $false)]
        $CurrentEnv = @{}
    )

    if ($null -eq $Evidence) {
        return @{ Applicable = $false; Reason = 'evidence-null' }
    }

    # 1. SHA mandatorio em ambas as pontas
    $evHead = [string]$Evidence.head_sha
    if ([string]::IsNullOrWhiteSpace($evHead)) { $evHead = [string]$Evidence.base_revision }
    if ([string]::IsNullOrWhiteSpace($CurrentHeadSha) -or [string]::IsNullOrWhiteSpace($evHead)) {
        return @{ Applicable = $false; Reason = 'head-sha-missing' }
    }
    if ($evHead -cne $CurrentHeadSha) {
        return @{ Applicable = $false; Reason = 'head-sha-mismatch' }
    }

    # 2. Criterios de aceite: se presentes na evidencia ou no pedido, devem coincidir
    $evCritHash = [string]$Evidence.criteria_hash
    if (-not [string]::IsNullOrWhiteSpace($evCritHash) -or -not [string]::IsNullOrWhiteSpace($CurrentCriteriaHash)) {
        if ([string]::IsNullOrWhiteSpace($evCritHash) -or [string]::IsNullOrWhiteSpace($CurrentCriteriaHash) -or ($evCritHash -cne $CurrentCriteriaHash)) {
            return @{ Applicable = $false; Reason = 'criteria-hash-mismatch' }
        }
    }

    # 3. Escopo e Fingerprints de arquivos no disco
    $evFps = $Evidence.source_fingerprints
    $targetFps = @{}
    if ($null -ne $evFps) {
        if ($evFps -is [System.Collections.IDictionary]) {
            foreach ($k in $evFps.Keys) { $targetFps[$k] = $evFps[$k] }
        } else {
            foreach ($p in $evFps.PSObject.Properties) { $targetFps[$p.Name] = $p.Value }
        }
    }
    if ($CurrentSourceFingerprints.Count -gt 0) {
        foreach ($k in $CurrentSourceFingerprints.Keys) {
            if (-not $targetFps.ContainsKey($k)) { $targetFps[$k] = $CurrentSourceFingerprints[$k] }
        }
    }

    # Se ha escopo definido no pedido ou na evidencia, verificar se arquivos existem no disco e se batem
    $combinedScope = @()
    if ($null -ne $CurrentScope) { $combinedScope += $CurrentScope }
    if ($null -ne $Evidence.scope) { $combinedScope += @($Evidence.scope) }
    $combinedScope = @($combinedScope | Select-Object -Unique)

    $currentWorkDir = (Get-Location).Path
    $workDirFull = [System.IO.Path]::GetFullPath($currentWorkDir)

    foreach ($fileRel in $combinedScope) {
        if ([string]::IsNullOrWhiteSpace($fileRel)) { continue }

        # Validacao rigorosa de escopo: prevencao contra path traversal relativo fora do workspace autorizado
        try {
            $isRooted = [System.IO.Path]::IsPathRooted($fileRel)
            $fullFilePath = if ($isRooted) { [System.IO.Path]::GetFullPath($fileRel) } else { [System.IO.Path]::GetFullPath((Join-Path $workDirFull $fileRel)) }
            if (-not $isRooted -and -not $fullFilePath.StartsWith($workDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Applicable = $false; Reason = "scope-path-traversal-detected" }
            }
        } catch {
            return @{ Applicable = $false; Reason = "scope-path-traversal-detected" }
        }

        # Exigencia rigorosa: se o fingerprint foi registrado, arquivo ausente ou inacessivel invalida o reuso
        if ($targetFps.ContainsKey($fileRel)) {
            if (-not (Test-Path -LiteralPath $fileRel -PathType Leaf)) {
                return @{ Applicable = $false; Reason = "scope-file-missing-in-$fileRel" }
            }
            try {
                $diskSha = (Get-FileHash -LiteralPath $fileRel -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                $recSha = ([string]$targetFps[$fileRel]).ToLowerInvariant()
                if ($diskSha -ne $recSha) {
                    return @{ Applicable = $false; Reason = "disk-content-drift-in-$fileRel" }
                }
            } catch {
                return @{ Applicable = $false; Reason = "disk-read-failed-in-$fileRel" }
            }
        }
    }

    # 4. Ambiente (runtime / versao): se presente na evidencia e no pedido, validar compatibilidade
    if ($null -ne $Evidence.environment -and $null -ne $CurrentEnv -and ($CurrentEnv -is [System.Collections.IDictionary] -or $CurrentEnv -is [pscustomobject])) {
        $evRt = if ($Evidence.environment.runtime) { [string]$Evidence.environment.runtime } else { '' }
        $curRt = if ($CurrentEnv -is [System.Collections.IDictionary]) { [string]$CurrentEnv['runtime'] } else { [string]$CurrentEnv.runtime }
        if (-not [string]::IsNullOrWhiteSpace($evRt) -and -not [string]::IsNullOrWhiteSpace($curRt) -and ($evRt -cne $curRt)) {
            return @{ Applicable = $false; Reason = 'environment-runtime-mismatch' }
        }

        $evVer = if ($Evidence.environment.version) { [string]$Evidence.environment.version } else { '' }
        $curVer = if ($CurrentEnv -is [System.Collections.IDictionary]) { [string]$CurrentEnv['version'] } else { [string]$CurrentEnv.version }
        if (-not [string]::IsNullOrWhiteSpace($evVer) -and -not [string]::IsNullOrWhiteSpace($curVer) -and ($evVer -cne $curVer)) {
            return @{ Applicable = $false; Reason = 'environment-version-mismatch' }
        }
    }

    return @{ Applicable = $true; Reason = 'all-requirements-validated' }
}

function Resolve-OrchestrationProportionalReuse {
    <#
    .SYNOPSIS
        Evaluates whether an exact or consultative reusable artifact exists before dispatching work.
    .PARAMETER TaskId
        Identifier of the current task.
    .PARAMETER Objective
        Textual objective of the task.
    .PARAMETER Scope
        List of file paths involved in the task.
    .PARAMETER CurrentHeadSha
        Current git commit SHA-256 / SHA-1.
    .PARAMETER SourceFingerprints
        Hashtable of path -> sha256 of file contents.
    .PARAMETER CriteriaHash
        Hash or signature of acceptance criteria.
    .PARAMETER CurrentEnv
        Hashtable containing environment details (runtime, version).
    .PARAMETER EvidenceStoreDir
        Optional directory path for local evidence store.
    .PARAMETER MaxAgeSeconds
        Maximum age in seconds for evidence freshness (default: 86400 / 24h).
    .PARAMETER ReuseClass
        Class of reuse (default: external-behavior).
    .PARAMETER AiMemoryProbe
        Optional scriptblock seam for AI Memory integration (workspace=ferramentas, project=opencode-orchestration).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [string]$Objective,

        [Parameter(Mandatory = $false)]
        [string[]]$Scope = @(),

        [Parameter(Mandatory = $false)]
        [string]$CurrentHeadSha = '',

        [Parameter(Mandatory = $false)]
        [hashtable]$SourceFingerprints = @{},

        [Parameter(Mandatory = $false)]
        [string]$CriteriaHash = '',

        [Parameter(Mandatory = $false)]
        $CurrentEnv = @{},

        [Parameter(Mandatory = $false)]
        [string]$EvidenceStoreDir = '',

        [Parameter(Mandatory = $false)]
        [int]$MaxAgeSeconds = 86400,

        [Parameter(Mandatory = $false)]
        [string]$ReuseClass = 'external-behavior',

        [Parameter(Mandatory = $false)]
        [scriptblock]$AiMemoryProbe = $null
    )

    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    if ([string]::IsNullOrWhiteSpace($EvidenceStoreDir)) {
        if (Get-Command Get-OrchestrationReuseCanonicalStoreDir -ErrorAction SilentlyContinue) {
            $EvidenceStoreDir = Get-OrchestrationReuseCanonicalStoreDir -RepoRoot $root
        } elseif (Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue) {
            $EvidenceStoreDir = Get-OrchestrationEvidenceDefaultStoreDir
        } else {
            $EvidenceStoreDir = Join-Path (Join-Path $root 'cache') 'evidence-store'
        }
    }

    # LEVEL 1: Canonical Reusable Evidence Lookup
    # Validates commit SHA, file fingerprints, environment and acceptance criteria.
    # Reutiliza o mecanismo canonico evitando percorrer recursivamente todos os JSONs.
    # task_id isolado nunca e aceito como prova de validade.
    $exactCandidate = $null
    $exactReason = ''

    if (Test-Path -LiteralPath $EvidenceStoreDir -PathType Container) {
        # 1.1 Tentativa primaria via Find-OrchestrationReusableWork (canonical reuse wiring)
        if (Get-Command Find-OrchestrationReusableWork -ErrorAction SilentlyContinue) {
            try {
                $rw = Find-OrchestrationReusableWork -Scope $Scope `
                    -CurrentSourceFingerprints $SourceFingerprints `
                    -CurrentBaseRevision $CurrentHeadSha `
                    -CurrentCriteriaHash $CriteriaHash `
                    -CurrentEnv $CurrentEnv `
                    -ReuseClass $ReuseClass `
                    -StoreDir $EvidenceStoreDir `
                    -MaxResults 5
                if ($null -ne $rw -and [bool]$rw.reused -and @($rw.candidates).Count -gt 0) {
                    $exactCandidate = $rw.candidates[0]
                    $exactReason = "Canonical evidence match validated via Find-OrchestrationReusableWork on HEAD '$CurrentHeadSha'."
                }
            } catch { }
        }

        # 1.2 Tentativa secundaria via Find-ReusableOrchestrationEvidence (canonical store)
        if ($null -eq $exactCandidate -and (Get-Command Find-ReusableOrchestrationEvidence -ErrorAction SilentlyContinue)) {
            try {
                $qErr = $null
                $hits = Find-ReusableOrchestrationEvidence -StoreDir $EvidenceStoreDir `
                    -Scope $Scope `
                    -CurrentSourceFingerprints $SourceFingerprints `
                    -CurrentBaseRevision $CurrentHeadSha `
                    -CurrentCriteriaHash $CriteriaHash `
                    -CurrentEnv $CurrentEnv `
                    -Now ([DateTime]::UtcNow.ToString('o')) `
                    -MaxResults 5 `
                    -QueryError ([ref]$qErr)
                if ($null -ne $hits -and @($hits).Count -gt 0) {
                    $hit = $hits[0]
                    if (-not [string]::IsNullOrWhiteSpace([string]$hit.evidence_id)) {
                        $fullPath = Join-Path $EvidenceStoreDir ("$($hit.evidence_id).json")
                        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                            $exactCandidate = ConvertFrom-Json (Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop)
                        } else {
                            $exactCandidate = $hit
                        }
                    } else {
                        $exactCandidate = $hit
                    }
                    $exactReason = "Canonical evidence match validated via Find-ReusableOrchestrationEvidence on HEAD '$CurrentHeadSha'."
                }
            } catch { }
        }

        # 1.3 Verificacao direta fail-closed de arquivos no diretorio imediato (SEM busca recursiva)
        # Exige rigorosamente: SHA coincidente, frescor, e rejeita task_id isolado se fingerprints/SHA divergirem
        if ($null -eq $exactCandidate) {
            $directFiles = @(Get-ChildItem -LiteralPath $EvidenceStoreDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 50)
            foreach ($file in $directFiles) {
                try {
                    $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                    $ev = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                    if ($null -eq $ev) { continue }

                    $evHead = [string]$ev.head_sha
                    if ([string]::IsNullOrWhiteSpace($evHead)) { $evHead = [string]$ev.base_revision }
                    $evTaskId = [string]$ev.task_id
                    $evObj = [string]$ev.objective

                    # Deve corresponder a tarefa ou objetivo
                    if ($evTaskId -ne $TaskId -and ([string]::IsNullOrWhiteSpace($evObj) -or $evObj -ne $Objective)) { continue }

                    # Invariante: task_id isolado NAO e prova de validade. HEAD SHA e mandatorio.
                    if ([string]::IsNullOrWhiteSpace($CurrentHeadSha) -or [string]::IsNullOrWhiteSpace($evHead)) { continue }
                    if ($evHead -ne $CurrentHeadSha) { continue }

                    # Validar fingerprints se especificados no pedido
                    if ($SourceFingerprints.Count -gt 0) {
                        $evFps = $ev.source_fingerprints
                        if ($null -eq $evFps) { continue }
                        $fpMismatch = $false
                        foreach ($p in $SourceFingerprints.Keys) {
                            $oldVal = if ($evFps -is [System.Collections.IDictionary]) { $evFps[$p] } else { $evFps.$p }
                            if ([string]$oldVal -cne [string]$SourceFingerprints[$p]) {
                                $fpMismatch = $true
                                break
                            }
                        }
                        if ($fpMismatch) { continue }
                    }

                    # Validar frescor
                    if (Get-Command Test-OrchestrationEvidenceFreshness -ErrorAction SilentlyContinue) {
                        $freshness = Test-OrchestrationEvidenceFreshness -Evidence $ev -CurrentHeadSha $CurrentHeadSha -MaxAgeSeconds $MaxAgeSeconds
                        if ($freshness.ok -and -not $freshness.refresh_required) {
                            $exactCandidate = $ev
                            $exactReason = "Exact match validated on commit HEAD '$CurrentHeadSha' with matching fingerprints and freshness."
                            break
                        }
                    }
                } catch { }
            }
        }
    }

    if ($null -ne $exactCandidate) {
        $appCheck = Test-OrchestrationReusableApplicability -Evidence $exactCandidate `
            -CurrentHeadSha $CurrentHeadSha `
            -CurrentScope $Scope `
            -CurrentSourceFingerprints $SourceFingerprints `
            -CurrentCriteriaHash $CriteriaHash `
            -CurrentEnv $CurrentEnv
        if (-not [bool]$appCheck.Applicable) {
            $exactCandidate = $null
            $exactReason = "Candidate discarded: $($appCheck.Reason)"
        }
    }

    if ($null -ne $exactCandidate) {
        return [pscustomobject]@{
            Status               = 'REUSED_EXACT'
            Strategy             = 'REUSE_VERIFIED'
            Tier                 = 'T0'
            TokensUsed           = 0
            ReusedEvidence       = $exactCandidate
            Reason               = $exactReason
            ActionableNextStep   = 'Proceed directly to verification or completion using existing evidence.'
            IsAuthoritative      = $false
            MemoryConsulted      = $false
        }
    }

    # LEVEL 2: Consultative AI Memory Lookup (Advisory Context Only)
    $memoryNotes = @()
    if ($null -ne $AiMemoryProbe) {
        try {
            $mem = & $AiMemoryProbe $TaskId $Objective
            if ($null -ne $mem -and @($mem).Count -gt 0) {
                $memoryNotes = @($mem)
            }
        }
        catch { }
    }

    # LEVEL 3: Fallback to Fresh Execution
    return [pscustomobject]@{
        Status               = 'REEXECUTION_REQUIRED'
        Strategy             = 'SINGLE_OR_MULTI_WORKER'
        Tier                 = 'T2'
        TokensUsed           = 0
        ReusedEvidence       = $null
        MemoryAdvisoryNotes  = $memoryNotes
        Reason               = 'No fresh exact match found in Evidence Store. Execution required.'
        ActionableNextStep   = 'Dispatch worker according to Model Router tier.'
        IsAuthoritative      = $false
        MemoryConsulted      = ($memoryNotes.Count -gt 0)
    }
}
