<#
.SYNOPSIS
    Proportional Reuse-First Library (P2, Issues #4, #106, #146).
.DESCRIPTION
    Dot-sourceable library (no execution on load).
    Implements hierarchical, proportional reuse:
      Level 1: Exact match on commit HEAD and file fingerprints (T0 - zero tokens).
      Level 2: AI Memory project context lookup (consultative only, bounded).
      Level 3: Full re-execution fallback when evidence is stale, drifted, or absent.
    Preserves invariants: Memory is never runtime truth; no parallel database created.
    PowerShell 5.1 and 7+ compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $freshnessLib = Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1'
    if (Test-Path -LiteralPath $freshnessLib) { . $freshnessLib }
    $reuseWiringLib = Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1'
    if (Test-Path -LiteralPath $reuseWiringLib) { . $reuseWiringLib }
}
catch { }

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
    .PARAMETER EvidenceStoreDir
        Optional directory path for local evidence store.
    .PARAMETER MaxAgeSeconds
        Maximum age in seconds for evidence freshness (default: 86400 / 24h).
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
        [string]$EvidenceStoreDir = '',

        [Parameter(Mandatory = $false)]
        [int]$MaxAgeSeconds = 86400,

        [Parameter(Mandatory = $false)]
        [scriptblock]$AiMemoryProbe = $null
    )

    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    if ([string]::IsNullOrWhiteSpace($EvidenceStoreDir)) {
        $EvidenceStoreDir = Join-Path $root 'evidence'
    }

    # LEVEL 1: Exact Match Search in Evidence Store
    $exactCandidate = $null
    $exactVerdict = 'none'

    if (Test-Path -LiteralPath $EvidenceStoreDir) {
        $jsonFiles = @(Get-ChildItem -LiteralPath $EvidenceStoreDir -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($file in $jsonFiles) {
            try {
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                $ev = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                if ($null -eq $ev) { continue }

                # Check if this evidence relates to the current task or objective
                $evTaskId = [string]$ev.task_id
                $evHead = [string]$ev.head_sha
                $evType = [string]$ev.type

                # Fail-closed check using Test-OrchestrationEvidenceFreshness
                if (Get-Command Test-OrchestrationEvidenceFreshness -ErrorAction SilentlyContinue) {
                    $freshness = Test-OrchestrationEvidenceFreshness -Evidence $ev -CurrentHeadSha $CurrentHeadSha -MaxAgeSeconds $MaxAgeSeconds
                    if ($freshness.ok -and -not $freshness.refresh_required) {
                        # Match by task_id or exact matching objective
                        $evObj = [string]$ev.objective
                        if ($evTaskId -eq $TaskId -or ($evHead -eq $CurrentHeadSha -and -not [string]::IsNullOrWhiteSpace($evObj) -and $evObj -eq $Objective)) {
                            $exactCandidate = $ev
                            $exactVerdict = 'fresh'
                            break
                        }
                    }
                }
            }
            catch { }
        }
    }

    if ($null -ne $exactCandidate -and $exactVerdict -eq 'fresh') {
        return [pscustomobject]@{
            Status               = 'REUSED_EXACT'
            Strategy             = 'REUSE_VERIFIED'
            Tier                 = 'T0'
            TokensUsed           = 0
            ReusedEvidence       = $exactCandidate
            Reason               = "Exact match found on commit HEAD '$CurrentHeadSha' with valid freshness."
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
