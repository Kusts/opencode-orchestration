<#
.SYNOPSIS
    Intelligent Advisor Escalation Library (Issue #60, Addendum 2026-10-21).
.DESCRIPTION
    Dot-sourceable library (no execution on load).
    Implements demand-driven escalation from the stable economical Planner (T2/T3)
    to the specialized Engineering Advisor (T2/T3/T4) based on 7 concrete signals.
    Enforces structured consultation contracts, short-lived bounded caching to eliminate
    redundant LLM calls, and strict read-only advisory boundaries.
    The Advisor never issues DONE, never spawns subagents, and never mutates Kernel state.
    PowerShell 5.1 and 7+ compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# The 7 concrete escalation signals
$script:AdvisorValidEscalationSignals = @(
    'consequential_alternatives',
    'repeated_failure_no_new_info',
    'conflicting_evidence',
    'reasoning_gap',
    'complex_cross_component_decision',
    'verified_deadlock',
    'risk_asymmetry'
)

# In-memory bounded caches for advisor consultations: Key -> Response object
# Strictly isolated: test cache never leaks to production; production never polluted by test probes.
if ($null -eq $script:AdvisorProductionCache) {
    $script:AdvisorProductionCache = @{}
}
if ($null -eq $script:AdvisorTestCache) {
    $script:AdvisorTestCache = @{}
}
# Backward compatibility reference
$script:AdvisorConsultationCache = $script:AdvisorProductionCache

function Test-AdvisorEscalationSignal {
    <#
    .SYNOPSIS
        Validates whether a trigger signal meets the concrete criteria for Advisor escalation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Signal,

        [Parameter(Mandatory = $false)]
        [string]$Justification = '',

        [Parameter(Mandatory = $false)]
        [bool]$InformationMissing = $false
    )

    $cleanSignal = $Signal.Trim().ToLowerInvariant()

    # Rule: Missing information must be retrieved via T0/T2 exploration, not by escalating to Advisor
    if ($InformationMissing) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Information or context is missing. Must retrieve evidence via T0/T2 tools before escalating to Advisor."
            Signal   = $cleanSignal
        }
    }

    # Rule: Escalating purely because complexity is 'complex' is strictly prohibited
    if ($cleanSignal -in @('complex', 'high_complexity', 'task_is_complex')) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Anti-pattern prohibited: Cannot escalate to Advisor solely because task is complex. Requires one of the 7 concrete signals."
            Signal   = $cleanSignal
        }
    }

    if ($script:AdvisorValidEscalationSignals -notcontains $cleanSignal) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Signal '$cleanSignal' is not an allowlisted escalation trigger. Must be one of: $($script:AdvisorValidEscalationSignals -join ', ')."
            Signal   = $cleanSignal
        }
    }

    if ([string]::IsNullOrWhiteSpace($Justification) -or $Justification.Trim().Length -lt 10) {
        return [pscustomobject]@{
            Admitted = $false
            Reason   = "Escalation requires a non-empty factual justification (minimum 10 characters)."
            Signal   = $cleanSignal
        }
    }

    return [pscustomobject]@{
        Admitted = $true
        Reason   = "Escalation signal '$cleanSignal' validated."
        Signal   = $cleanSignal
    }
}

function ConvertTo-StructuredAdvisoryOpinion {
    <#
    .SYNOPSIS
        Parses advisory text into a structured opinion object.
    .DESCRIPTION
        Distinguishes:
        - EXECUTABLE_RECOMMENDATION: Concrete, validated actionable recommendation ready for implementation.
        - INVESTIGATION_NEEDED: Premature to choose; reproduction or further investigation required.
        - REJECTED: Proposed direction or anti-pattern rejected.
        - BLOCKED_MISSING_EVIDENCE: Blocked due to lack of evidence, reproduction, or necessary data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Text = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{
            Stance                 = 'BLOCKED_MISSING_EVIDENCE'
            IsBlocked              = $true
            RequiresInvestigation  = $true
            Diagnosis              = 'No advice text received or empty consultation.'
            MissingEvidence        = 'Consultation response text is missing.'
            NextAction             = 'Provide context and query to engineering-advisor.'
            RecommendedOption      = $null
            RollbackPlan           = 'Maintain current state; do not make changes.'
            RawText                = ''
        }
    }

    $raw = $Text.Trim()
    $stance = 'EXECUTABLE_RECOMMENDATION'

    # Stance evaluation
    if ($raw -match '(?i)\b(?:STATUS:\s*BLOCKED|\*\*STATUS:\s*BLOCKED|STATUS\s*:\s*BLOCKED)\b' -or `
        $raw -match '(?i)informação insuficiente' -or `
        $raw -match '(?i)incerteza alta' -or `
        $raw -match '(?i)não escolher ainda' -or `
        $raw -match '(?i)bloqueio por falta de evidência') {
        $stance = 'BLOCKED_MISSING_EVIDENCE'
    } elseif ($raw -match '(?i)\b(?:STATUS:\s*INVESTIGATION_NEEDED|\*\*STATUS:\s*INVESTIGATION_NEEDED|investigação necessária)\b' -or `
              $raw -match '(?i)fornecer uma reprodução mínima' -or `
              $raw -match '(?i)reproduzir antes de decidir') {
        $stance = 'INVESTIGATION_NEEDED'
    } elseif ($raw -match '(?i)\b(?:STATUS:\s*REJECTED|\*\*STATUS:\s*REJECTED|parecer rejeitado|anti-padrão proibido)\b') {
        $stance = 'REJECTED'
    } else {
        $stance = 'EXECUTABLE_RECOMMENDATION'
    }

    $isBlocked = ($stance -in @('BLOCKED_MISSING_EVIDENCE', 'REJECTED'))
    $requiresInv = ($stance -in @('BLOCKED_MISSING_EVIDENCE', 'INVESTIGATION_NEEDED'))

    # Extract Diagnosis
    $diag = ''
    if ($raw -match '(?i)(?:\*\*DIAGN[\p{L}\w]?STICO:\*\*|DIAGN[\p{L}\w]?STICO:|\*\*DIAGNOSIS:\*\*|DIAGNOSIS:)\s*([^\n]+(?:\n(?!\*\*)[^\n]+)*)') {
        $diag = $matches[1].Trim()
    }

    # Extract Missing Evidence
    $missingEv = ''
    if ($raw -match '(?i)(?:\*\*FALTAM:\*\*|FALTAM:|Evid[\p{L}\w]{1,2}ncia necess[\p{L}\w]{1,2}ria:|\*\*Evid[\p{L}\w]{1,2}ncia necess[\p{L}\w]{1,2}ria:\*\*|\*\*MISSING:\*\*|MISSING:)\s*([\s\S]*?)(?=\n\s*\*\*[A-Za-z0-9_ ]+:|\Z)') {
        $missingEv = $matches[1].Trim()
    }

    # Extract Next Action
    $nextAct = ''
    if ($raw -match '(?i)(?:\*\*PR[\p{L}\w]?XIMA\s+A[\p{L}\w]{1,2}O:\*\*|PR[\p{L}\w]?XIMA\s+A[\p{L}\w]{1,2}O:|\*\*UMA\s+pr[\p{L}\w]?xima\s+a[\p{L}\w]{1,2}o:\*\*|UMA\s+pr[\p{L}\w]?xima\s+a[\p{L}\w]{1,2}o:|\*\*NEXT ACTION:\*\*|NEXT ACTION:)\s*([^\n]+(?:\n(?!\*\*)[^\n]+)*)') {
        $nextAct = $matches[1].Trim()
    }

    # Extract Recommendation
    $rec = ''
    if ($raw -match '(?i)(?:\*\*RECOMMENDATION:\*\*|\*\*RECOMENDA[\p{L}\w]{1,2}O:\*\*|RECOMMENDATION:|RECOMENDA[\p{L}\w]{1,2}O:)\s*([^\n]+(?:\n(?!\*\*)[^\n]+)*)') {
        $rec = $matches[1].Trim()
    }

    # Extract Rollback
    $rollback = ''
    if ($raw -match '(?i)(?:\*\*Rollback:\*\*|Rollback:|\*\*ROLLBACK:\*\*)\s*([^\n]+(?:\n(?!\*\*)[^\n]+)*)') {
        $rollback = $matches[1].Trim()
    }

    # Fallbacks
    if ([string]::IsNullOrWhiteSpace($nextAct)) {
        if ($isBlocked -or $requiresInv) {
            $nextAct = if (-not [string]::IsNullOrWhiteSpace($missingEv)) {
                $firstLine = ($missingEv -split "`r?`n")[0].Trim().TrimStart('-').Trim()
                "Investigate and collect missing evidence: $firstLine"
            } else {
                "Provide minimal reproduction and required evidence before choosing mechanism."
            }
        } else {
            $nextAct = if (-not [string]::IsNullOrWhiteSpace($rec)) { $rec } else { "Follow executable recommendation." }
        }
    }
    if ([string]::IsNullOrWhiteSpace($rec)) {
        $rec = if ($isBlocked) {
            if (-not [string]::IsNullOrWhiteSpace($diag)) { "Adviser blocked pending evidence: $diag" } else { "Adviser blocked pending evidence; maintain current strategy." }
        } else {
            $raw.Substring(0, [Math]::Min(160, $raw.Length))
        }
    }

    return [pscustomobject]@{
        Stance                = $stance
        IsBlocked             = $isBlocked
        RequiresInvestigation = $requiresInv
        Diagnosis             = $diag
        MissingEvidence       = $missingEv
        NextAction            = $nextAct
        RecommendedOption     = $rec
        RollbackPlan          = $rollback
        RawText               = $raw
    }
}

function Get-AdvisorField($obj, [string]$name, $default = $null) {
    if ($null -eq $obj) { return $default }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $default
    }
    $prop = $obj.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $default
}

function Test-OrchestrationOpenCodeAuthenticated {
    <#
    .SYNOPSIS
        Verifica se ha provedores autenticados no OpenCode (env vars, auth.json ou auth list).
    .DESCRIPTION
        Nao depende exclusivamente de variaveis de ambiente e nao expoe segredos.
    #>
    [CmdletBinding()]
    param()

    # 1. Variaveis de ambiente explicitas
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENCODE_GO_API_KEY) -or `
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -or `
        -not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)) {
        return $true
    }

    # 2. Arquivo auth.json local do OpenCode
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        $authPath = Join-Path (Join-Path (Join-Path $homeDir '.local') 'share\opencode') 'auth.json'
        if (Test-Path -LiteralPath $authPath -PathType Leaf) {
            try {
                if ((Get-Item -LiteralPath $authPath).Length -gt 5) {
                    return $true
                }
            } catch { }
        }
    }

    # 3. CLI auth list se disponivel
    try {
        $authLines = @(opencode auth list 2>&1)
        if ($authLines.Count -gt 0 -and ($authLines -match 'stored' -or $authLines -match 'environment')) {
            return $true
        }
    } catch { }

    return $false
}

function Get-OrchestrationSessionHostEvidence {
    <#
    .SYNOPSIS
        Extrai evidencias de execucao real de uma sessao nativa via opencode session export.
    .DESCRIPTION
        Coleta SessionId, Agent, ModelEffective, Tokens, Cost e Outcome reais do host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionId,

        [Parameter(Mandatory = $false)]
        [string]$OpencodeBin = ''
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }

    $bin = if (-not [string]::IsNullOrWhiteSpace($OpencodeBin)) { $OpencodeBin } else { 'opencode' }
    try {
        $raw = ''
        $spikeLib = Join-Path $PSScriptRoot '..\..\runtime\lib\SpikeProcess.ps1'
        if (Test-Path -LiteralPath $spikeLib -PathType Leaf) {
            . $spikeLib
            $spRes = Invoke-SpikeChild -FilePath $bin -ArgumentList @('session', 'export', $SessionId) -TimeoutMs 15000 -StdinNul
            if ($null -ne $spRes -and -not [string]::IsNullOrWhiteSpace($spRes.Stdout)) {
                $raw = [string]$spRes.Stdout
            }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $raw = & $bin session export $SessionId 2>&1 | Out-String
        }

        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $rawStr = if ($raw -is [array]) { $raw -join "`n" } else { [string]$raw }
        $rawStr = $rawStr.Trim()
        if (-not $rawStr.StartsWith('{')) { return $null }
        $parsed = ConvertFrom-Json -InputObject $rawStr -ErrorAction Stop
        if ($null -eq $parsed -or $null -eq $parsed.info) { return $null }

        $effModel = $null
        if ($parsed.info.model) {
            $providerId = [string]$parsed.info.model.providerID
            $mId = [string]$parsed.info.model.id
            $effModel = if (-not [string]::IsNullOrWhiteSpace($providerId) -and -not [string]::IsNullOrWhiteSpace($mId)) { "$providerId/$mId" } else { $mId }
        }

        $assistantText = ''
        if ($parsed.messages) {
            foreach ($msg in @($parsed.messages)) {
                if ($msg.type -eq 'assistant') {
                    if ($null -eq $effModel -and $msg.model) {
                        $pIdMsg = [string]$msg.model.providerID
                        $mIdMsg = [string]$msg.model.id
                        $effModel = if (-not [string]::IsNullOrWhiteSpace($pIdMsg) -and -not [string]::IsNullOrWhiteSpace($mIdMsg)) { "$pIdMsg/$mIdMsg" } else { $mIdMsg }
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$msg.text)) {
                        $assistantText = [string]$msg.text
                    } elseif ($msg.content) {
                        foreach ($c in @($msg.content)) {
                            if ($c.type -eq 'text' -and -not [string]::IsNullOrWhiteSpace([string]$c.text)) {
                                $assistantText = [string]$c.text
                                break
                            }
                        }
                    }
                }
            }
        }

        $tokensIn = 0; $tokensOut = 0; $tokensReas = 0
        if ($parsed.info.tokens) {
            try { $tokensIn = [int]$parsed.info.tokens.input } catch { }
            try { $tokensOut = [int]$parsed.info.tokens.output } catch { }
            try { $tokensReas = [int]$parsed.info.tokens.reasoning } catch { }
        }
        $costUsd = 'UNKNOWN'
        if ($null -ne $parsed.info.cost) {
            try { $costUsd = [double]$parsed.info.cost } catch { $costUsd = 'UNKNOWN' }
        }

        $agentEff = if (-not [string]::IsNullOrWhiteSpace([string]$parsed.info.agent)) { [string]$parsed.info.agent } else { $null }
        $sessionTitle = if ($parsed.info.title) { [string]$parsed.info.title } else { $null }

        return [pscustomobject]@{
            SessionId        = [string]$parsed.info.id
            Title            = $sessionTitle
            Agent            = $agentEff
            Outcome          = [string]$parsed.info.outcome
            EffectiveModel   = $effModel
            TokensInput      = $tokensIn
            TokensOutput     = $tokensOut
            TokensReasoning  = $tokensReas
            CostUsd          = $costUsd
            AssistantMessage = $assistantText
            RawOutput        = $rawStr
            RawError         = if ($parsed.info.outcome -eq 'failed') { "Session outcome reported failed" } else { $null }
        }
    } catch {
        return $null
    }
}

function Get-AdvisorConsultationCacheKey {
    <#
    .SYNOPSIS
        Computes a deterministic SHA256 cache key from bounded consultation inputs.
    .DESCRIPTION
        Considera TaskId, Signal, Question, HeadSha, Model, Constraints e ContextFingerprint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $true)]
        [string]$Signal,

        [Parameter(Mandatory = $true)]
        [string]$Question,

        [Parameter(Mandatory = $false)]
        [string]$HeadSha = '',

        [Parameter(Mandatory = $false)]
        [string]$Model = '',

        [Parameter(Mandatory = $false)]
        [string[]]$Constraints = @(),

        [Parameter(Mandatory = $false)]
        [string]$ContextFingerprint = ''
    )

    $cleanTask = if ($TaskId) { $TaskId.Trim().ToLowerInvariant() } else { '' }
    $cleanSig  = if ($Signal) { $Signal.Trim().ToLowerInvariant() } else { '' }
    $cleanQ    = if ($Question) { $Question.Trim().ToLowerInvariant() } else { '' }
    $cleanHead = if ($HeadSha) { $HeadSha.Trim().ToLowerInvariant() } else { '' }
    $cleanMod  = if ($Model) { $Model.Trim().ToLowerInvariant() } else { '' }
    $cleanCtx  = if ($ContextFingerprint) { $ContextFingerprint.Trim().ToLowerInvariant() } else { '' }
    $sortedConstraints = if ($Constraints) { @($Constraints | ForEach-Object { [string]$_.Trim().ToLowerInvariant() } | Sort-Object) -join ';' } else { '' }

    $canonicalString = "task:$cleanTask|signal:$cleanSig|q:$cleanQ|head:$cleanHead|model:$cleanMod|constraints:$sortedConstraints|context:$cleanCtx"
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalString)
    $hashBytes = $hasher.ComputeHash($bytes)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $hashBytes) {
        [void]$sb.Append($b.ToString("x2"))
    }
    return $sb.ToString()
}

function Get-OrchestrationNativeAdvisorExecutor {
    <#
    .SYNOPSIS
        Returns the native OpenCode V2 executor for engineering-advisor consultations.
    .DESCRIPTION
        Reutiliza a infraestrutura de execucao nativa do OpenCode V2 sem duplicar dispatchers.
        Se o ambiente nativo estiver indisponivel, falha fechado com PROOF_ABSENT.
        Registra SessionId, Agent, ModelRequested, ModelEffective e ResponseRef.
    #>
    [CmdletBinding()]
    param()

    return {
        param($Req, $ModelSel)

        $taskId = [string](Get-AdvisorField $Req 'task_id' 'advisor-task')
        $question = [string](Get-AdvisorField $Req 'question' '')
        $context = [string](Get-AdvisorField $Req 'context_summary' '')
        $justification = [string](Get-AdvisorField $Req 'justification' '')
        $reqTier = if ($ModelSel) { [string]$ModelSel.Tier } else { 'T3' }

        # Resolve modelo real de catalogo se disponivel (evita passar tokens literais de template como MODEL_STRONG)
        $reqModel = if ($ModelSel -and $ModelSel.CatalogModel) { [string]$ModelSel.CatalogModel } else { $null }
        if ([string]::IsNullOrWhiteSpace($reqModel) -or $reqModel -eq 'MODEL_STRONG' -or $reqModel -eq 'MODEL_CHEAP') {
            $catLib = Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1'
            if (Test-Path -LiteralPath $catLib) {
                . $catLib
                $userCat = Get-OrchestrationUserConfigCatalog
                if ($userCat -and $userCat.ContainsKey($reqTier) -and $userCat[$reqTier].CatalogModel) {
                    $reqModel = [string]$userCat[$reqTier].CatalogModel
                } elseif ($userCat -and $userCat.ContainsKey('T3') -and $userCat['T3'].CatalogModel) {
                    $reqModel = [string]$userCat['T3'].CatalogModel
                }
            }
        }

        # 1. Checagem de disponibilidade do runtime nativo OpenCode V2
        $opencodeBin = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$env:OPENCODE_BIN) -and (Test-Path -LiteralPath ([string]$env:OPENCODE_BIN) -PathType Leaf)) {
            $opencodeBin = [string]$env:OPENCODE_BIN
        } else {
            $profileV2Exe = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
            if (Test-Path -LiteralPath $profileV2Exe -PathType Leaf) {
                $opencodeBin = $profileV2Exe
            } else {
                $cmd = Get-Command opencode -ErrorAction SilentlyContinue
                if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
                    $opencodeBin = [string]$cmd.Source
                }
            }
        }

        $consultationId = "ADV-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"

        if ([string]::IsNullOrWhiteSpace($opencodeBin)) {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
                ConsultationId       = $consultationId
                SessionId            = $null
                Agent                = $null
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "Native OpenCode binary unavailable. Proof of execution absent."
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'NONE'
            }
        }

        # 2. Checagem de disponibilidade de provider/credencial para o modelo solicitado
        $isAuth = Test-OrchestrationOpenCodeAuthenticated
        if (-not $isAuth) {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'MODEL_PROVIDER_CREDENTIAL_ABSENT'
                ConsultationId       = $consultationId
                SessionId            = $null
                Agent                = $null
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "No active model provider credentials detected via environment or auth storage. Execution unperformed."
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'NONE'
            }
        }

        # 3. Timeout configuravel (default 30s, sem timeout rigido de 10s)
        $timeoutMs = 30000
        $reqTimeout = Get-AdvisorField $Req 'timeout_ms' $null
        if ($null -ne $reqTimeout -and [int]$reqTimeout -gt 0) {
            $timeoutMs = [int]$reqTimeout
        } else {
            $budgetSec = Get-AdvisorField $Req 'budget_seconds' $null
            if ($null -ne $budgetSec -and [int]$budgetSec -gt 0) {
                $timeoutMs = [int]($budgetSec * 1000)
            }
        }

        # 4. Resolucao de sessao nativa: referencia sessao pai se fornecida;
        #    a sessao executada do Advisor sera a filha forkeada (NUNCA inferida do pai).
        $parentSession = Get-AdvisorField $Req 'parent_session_id' $null
        if ([string]::IsNullOrWhiteSpace($parentSession) -and -not [string]::IsNullOrWhiteSpace($env:OPENCODE_SESSION_ID)) {
            $parentSession = [string]$env:OPENCODE_SESSION_ID
        }

        # 5. Execucao nativa quando binario e credenciais disponiveis
        try {
            $prompt = @"
[CONSULTATION: $consultationId]
TASK: $taskId
QUESTION: $question
JUSTIFICATION: $justification
CONTEXT: $context
"@
            # Resoluo de shim .ps1 para .cmd no Windows para suporte nativo a Invoke-SpikeChild
            $resolvedBin = $opencodeBin
            if ($resolvedBin.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
                $cmdCandidate = [System.IO.Path]::ChangeExtension($resolvedBin, '.cmd')
                if (Test-Path -LiteralPath $cmdCandidate -PathType Leaf) {
                    $resolvedBin = $cmdCandidate
                }
            }

            $argParts = @('run', '--format', 'json', '--agent', 'engineering-advisor', '--title', "Advisor: $consultationId")
            if (-not [string]::IsNullOrWhiteSpace($reqModel) -and $reqModel.Contains('/')) {
                $argParts += @('--model', [string]$reqModel)
            }
            if (-not [string]::IsNullOrWhiteSpace($parentSession)) {
                $argParts += @('--session', [string]$parentSession, '--fork')
            }
            $argParts += $prompt

            $exitCode = -1
            $isTimedOut = $false
            $stdout = ''
            $stderr = ''

            # Invocação direta segura com redirecionamento de streams e fechamento imediato de Stdin para evitar deadlocks
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $resolvedBin
            $psi.Arguments = ($argParts | ForEach-Object { if ($_ -match '[\s"]') { "`"$($_ -replace '"', '\"')`"" } else { $_ } }) -join ' '
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardInput.Close()

            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            $completed = $proc.WaitForExit($timeoutMs)
            if (-not $completed) {
                $isTimedOut = $true
                try { $proc.Kill() } catch { }
            } else {
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                $exitCode = $proc.ExitCode
            }

            if ($isTimedOut) {
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_DISPATCH_TIMEOUT'
                    ConsultationId       = $consultationId
                    SessionId            = $null
                    ParentSessionId      = $parentSession
                    Agent                = $null
                    ModelRequested       = $reqModel
                    ModelEffective       = $null
                    ResponseRef          = $null
                    RecommendedOption    = $null
                    Rationale            = "Native advisor execution exceeded bounded timeout of $($timeoutMs)ms."
                    Risks                = @()
                    RejectionReasons     = @()
                    ActionableNextStep   = $null
                    ModelTierUsed        = $reqTier
                    ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                    IsAdvisory           = $true
                    Authoritative        = $false
                    FromCache            = $false
                    ExecutionProofType   = 'NONE'
                }
            }

            $combinedOutput = "$stdout`n$stderr".Trim()

            if ($exitCode -eq 0) {
                # PROCESS_EXITED comprovado
                if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
                    return [pscustomobject]@{
                        Status               = 'PROOF_ABSENT'
                        Reason               = 'PROCESS_EXITED_EMPTY_OUTPUT'
                        ConsultationId       = $consultationId
                        SessionId            = $null
                        ParentSessionId      = $parentSession
                        Agent                = $null
                        ModelRequested       = $reqModel
                        ModelEffective       = $null
                        ResponseRef          = $null
                        RecommendedOption    = $null
                        Rationale            = "Native process exited with code 0 but produced no output."
                        Risks                = @()
                        RejectionReasons     = @()
                        ActionableNextStep   = $null
                        ModelTierUsed        = $reqTier
                        ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                        IsAdvisory           = $true
                        Authoritative        = $false
                        FromCache            = $false
                        ExecutionProofType   = 'PROCESS_EXITED'
                    }
                }

                # Extrai texto estruturado do parecer a partir dos eventos JSON
                $extractedText = ''
                foreach ($line in @($combinedOutput -split "`r?`n" | Where-Object { $_ -match '^\s*\{' })) {
                    try {
                        $jsonObj = ConvertFrom-Json -InputObject $line -ErrorAction SilentlyContinue
                        if ($null -ne $jsonObj -and $jsonObj.type -eq 'text' -and $jsonObj.part -and -not [string]::IsNullOrWhiteSpace($jsonObj.part.text)) {
                            $extractedText += [string]$jsonObj.part.text
                        }
                    } catch { }
                }
                if ([string]::IsNullOrWhiteSpace($extractedText)) {
                    $extractedText = $combinedOutput
                }

                # RESULT_RECEIVED: Captura do ID efetivo da sessao executada por eventos JSON nativos
                # NUNCA utilizar automaticamente a sessao pai como evidencia da execucao do Advisor
                $targetSessionId = $null
                if ($combinedOutput -match '"sessionID"\s*:\s*"(ses_[a-zA-Z0-9_-]+)"') {
                    $targetSessionId = $matches[1]
                } elseif ($combinedOutput -match '(?i)session[:\s]+(ses_[a-zA-Z0-9_-]+)') {
                    $targetSessionId = $matches[1]
                }

                # HOST_EVIDENCE_VERIFIED tentativa
                $hostEvidence = if (-not [string]::IsNullOrWhiteSpace($targetSessionId)) {
                    Get-OrchestrationSessionHostEvidence -SessionId $targetSessionId -OpencodeBin $resolvedBin
                } else { $null }

                $hasHostEvidence = ($null -ne $hostEvidence)
                $effModel = if ($hasHostEvidence -and -not [string]::IsNullOrWhiteSpace($hostEvidence.EffectiveModel)) {
                    $hostEvidence.EffectiveModel
                } else { $null }

                $hostAgent = if ($hasHostEvidence) { $hostEvidence.Agent } else { $null }
                $agentMatches = (-not [string]::IsNullOrWhiteSpace($hostAgent) -and $hostAgent -eq 'engineering-advisor')
                $outcomeSucceeded = ($hasHostEvidence -and $hostEvidence.Outcome -eq 'succeeded')

                # Correlacao estrita da sessao executada com a consulta iniciada
                $sessionCorrelated = $false
                if ($hasHostEvidence) {
                    if (-not [string]::IsNullOrWhiteSpace($hostEvidence.Title) -and $hostEvidence.Title.Contains($consultationId)) {
                        $sessionCorrelated = $true
                    } elseif (-not [string]::IsNullOrWhiteSpace($hostEvidence.AssistantMessage) -and $hostEvidence.AssistantMessage.Contains($consultationId)) {
                        $sessionCorrelated = $true
                    } elseif (-not [string]::IsNullOrWhiteSpace($hostEvidence.RawOutput) -and $hostEvidence.RawOutput.Contains($consultationId)) {
                        $sessionCorrelated = $true
                    } elseif ($combinedOutput.Contains($targetSessionId) -and $combinedOutput.Contains($consultationId)) {
                        $sessionCorrelated = $true
                    }
                }

                # Comparacao entre modelo solicitado e modelo efetivo
                $modelMatches = $false
                $isModelDivergent = $false
                if (-not [string]::IsNullOrWhiteSpace($reqModel) -and -not [string]::IsNullOrWhiteSpace($effModel)) {
                    $cReq = $reqModel.Trim().ToLowerInvariant()
                    $cEff = $effModel.Trim().ToLowerInvariant()
                    if ($cReq -eq $cEff -or $cEff.EndsWith("/$cReq") -or $cReq.EndsWith("/$cEff")) {
                        $modelMatches = $true
                    } else {
                        $isModelDivergent = $true
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($effModel)) {
                    $modelMatches = $true
                }

                if ($hasHostEvidence -and $outcomeSucceeded -and $agentMatches -and $sessionCorrelated -and $modelMatches) {
                    # COMPLETED_VERIFIED comprovado com todas as evidencias obrigatorias validas
                    $opinion = ConvertTo-StructuredAdvisoryOpinion -Text $extractedText
                    return [pscustomobject]@{
                        Status                = 'COMPLETED'
                        Reason                = 'COMPLETED_VERIFIED'
                        ConsultationId        = $consultationId
                        SessionId             = $hostEvidence.SessionId
                        ParentSessionId       = $parentSession
                        Agent                 = $hostAgent
                        ModelRequested        = $reqModel
                        ModelEffective        = $effModel
                        ResponseRef           = "resp-$consultationId"
                        RecommendedOption     = $opinion.RecommendedOption
                        AdvisoryStance        = $opinion.Stance
                        IsBlocked             = $opinion.IsBlocked
                        RequiresInvestigation = $opinion.RequiresInvestigation
                        Diagnosis             = $opinion.Diagnosis
                        MissingEvidence       = $opinion.MissingEvidence
                        ActionableNextStep    = $opinion.NextAction
                        RollbackPlan          = $opinion.RollbackPlan
                        RawResponseText       = $extractedText
                        Rationale             = "Native execution verified with host session evidence, exact agent, succeeded outcome, correlated session and matching model."
                        Risks                 = @()
                        RejectionReasons      = @()
                        ModelTierUsed         = $reqTier
                        ModelTokenUsed        = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                        IsAdvisory            = $true
                        Authoritative         = $false
                        FromCache             = $false
                        ExecutionProofType    = 'COMPLETED_VERIFIED'
                        TokensInput           = $hostEvidence.TokensInput
                        TokensOutput          = $hostEvidence.TokensOutput
                        CostUsd               = $hostEvidence.CostUsd
                    }
                } elseif ($hasHostEvidence -and $outcomeSucceeded -and $agentMatches -and $sessionCorrelated -and $isModelDivergent) {
                    # MODEL_DIVERGENT: executou e comprovou sessao/agente/outcome, mas modelo efetivo divergiu do solicitado
                    return [pscustomobject]@{
                        Status               = 'PARTIAL_PROOF'
                        Reason               = 'MODEL_DIVERGENT'
                        ConsultationId       = $consultationId
                        SessionId            = $hostEvidence.SessionId
                        ParentSessionId      = $parentSession
                        Agent                = $hostAgent
                        ModelRequested       = $reqModel
                        ModelEffective       = $effModel
                        ResponseRef          = "resp-$consultationId"
                        RecommendedOption    = $extractedText
                        Rationale            = "Process completed and session verified, but effective model ($effModel) diverged from requested model ($reqModel)."
                        Risks                = @('Model divergence detected; effective model did not match requested catalog model.')
                        RejectionReasons     = @()
                        ActionableNextStep   = "Verify provider model aliases or router catalog mapping."
                        ModelTierUsed        = $reqTier
                        ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                        IsAdvisory           = $true
                        Authoritative        = $false
                        FromCache            = $false
                        ExecutionProofType   = 'MODEL_DIVERGENT'
                        TokensInput          = $hostEvidence.TokensInput
                        TokensOutput         = $hostEvidence.TokensOutput
                        CostUsd              = $hostEvidence.CostUsd
                    }
                } else {
                    # Faltou verificacao completa do host (modelo efetivo, agente, correlacao de sessao ou outcome)
                    # NUNCA declarar execucao integralmente verificada nem inferir modelo ou agente
                    $unverifiedReason = if ($hasHostEvidence) {
                        if (-not $sessionCorrelated) { 'SESSION_CORRELATION_UNVERIFIED' }
                        elseif (-not $agentMatches) { 'AGENT_UNVERIFIED' }
                        elseif (-not $outcomeSucceeded) { 'SESSION_OUTCOME_NOT_SUCCEEDED' }
                        else { 'HOST_EVIDENCE_INCOMPLETE' }
                    } else {
                        'HOST_EVIDENCE_UNVERIFIED'
                    }
                    $proofType = if ($hasHostEvidence) { 'HOST_EVIDENCE_VERIFIED' } else { 'RESULT_RECEIVED' }
                    return [pscustomobject]@{
                        Status               = 'PARTIAL_PROOF'
                        Reason               = $unverifiedReason
                        ConsultationId       = $consultationId
                        SessionId            = if ($hostEvidence) { $hostEvidence.SessionId } else { $targetSessionId }
                        ParentSessionId      = $parentSession
                        Agent                = $hostAgent
                        ModelRequested       = $reqModel
                        ModelEffective       = $effModel
                        ResponseRef          = "resp-$consultationId"
                        RecommendedOption    = $extractedText
                        Rationale            = "Process exited and text received, but host session evidence could not fully verify: $unverifiedReason."
                        Risks                = @('Execution unproven on host session store; cannot be cached as verified.')
                        RejectionReasons     = @()
                        ActionableNextStep   = "Consider verifying provider route or configuring dedicated session export."
                        ModelTierUsed        = $reqTier
                        ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                        IsAdvisory           = $true
                        Authoritative        = $false
                        FromCache            = $false
                        ExecutionProofType   = $proofType
                        TokensInput          = if ($hostEvidence) { $hostEvidence.TokensInput } else { $null }
                        TokensOutput         = if ($hostEvidence) { $hostEvidence.TokensOutput } else { $null }
                        CostUsd              = if ($hostEvidence -and $hostEvidence.CostUsd) { $hostEvidence.CostUsd } else { 'UNKNOWN' }
                    }
                }
            } else {
                return [pscustomobject]@{
                    Status               = 'PROOF_ABSENT'
                    Reason               = 'NATIVE_EXECUTION_FAILED_OR_NO_OUTPUT'
                    ConsultationId       = $consultationId
                    SessionId            = $parentSession
                    Agent                = $null
                    ModelRequested       = $reqModel
                    ModelEffective       = $null
                    ResponseRef          = $null
                    RecommendedOption    = $null
                    Rationale            = "OpenCode process exited with code $exitCode or produced empty output."
                    Risks                = @()
                    RejectionReasons     = @()
                    ActionableNextStep   = $null
                    ModelTierUsed        = $reqTier
                    ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                    IsAdvisory           = $true
                    Authoritative        = $false
                    FromCache            = $false
                    ExecutionProofType   = 'NONE'
                }
            }
        } catch {
            return [pscustomobject]@{
                Status               = 'PROOF_ABSENT'
                Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
                ConsultationId       = $consultationId
                SessionId            = $null
                Agent                = $null
                ModelRequested       = $reqModel
                ModelEffective       = $null
                ResponseRef          = $null
                RecommendedOption    = $null
                Rationale            = "Exception during native dispatch: $($_.Exception.Message)"
                Risks                = @()
                RejectionReasons     = @()
                ActionableNextStep   = $null
                ModelTierUsed        = $reqTier
                ModelTokenUsed       = if ($ModelSel) { [string]$ModelSel.ModelToken } else { 'MODEL_STRONG' }
                IsAdvisory           = $true
                Authoritative        = $false
                FromCache            = $false
                ExecutionProofType   = 'DISPATCH_EXCEPTION'
            }
        }
    }
}

function Invoke-AdvisorConsultation {
    <#
    .SYNOPSIS
        Orchestrates bounded consultation to engineering-advisor with contract validation and caching.
    .PARAMETER Request
        Hashtable or PSObject containing:
          - task_id (string)
          - trigger_signal (string)
          - justification (string)
          - question (string)
          - context_summary (string)
          - alternatives_evaluated (array)
          - constraints (array)
          - known_evidence (array)
          - head_sha (string)
    .PARAMETER ModelRouterSelection
        Selection object from Resolve-OrchestrationModelSelection for engineering-advisor.
    .PARAMETER AdvisorProbe
        Optional scriptblock seam for testing / simulated probe (strictly separated from production).
    .PARAMETER NativeExecutor
        Optional scriptblock seam for native execution override.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Request,

        [Parameter(Mandatory = $false)]
        [object]$ModelRouterSelection = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$AdvisorProbe = $null,

        [Parameter(Mandatory = $false)]
        [scriptblock]$NativeExecutor = $null,

        [Parameter(Mandatory = $false)]
        [switch]$DisableNativeExecutor
    )

    function Get-Field($obj, [string]$name, $default = $null) {
        if ($null -eq $obj) { return $default }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($name)) { return $obj[$name] }
            return $default
        }
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
        return $default
    }

    $taskId = [string](Get-Field $Request 'task_id' 'unknown-task')
    $signal = [string](Get-Field $Request 'trigger_signal' '')
    $justification = [string](Get-Field $Request 'justification' '')
    $question = [string](Get-Field $Request 'question' '')
    $contextSummary = [string](Get-Field $Request 'context_summary' '')
    $alternatives = @(Get-Field $Request 'alternatives_evaluated' @())
    $constraints = @(Get-Field $Request 'constraints' @())
    $knownEvidence = @(Get-Field $Request 'known_evidence' @())
    $headSha = [string](Get-Field $Request 'head_sha' '')
    $infoMissing = [bool](Get-Field $Request 'information_missing' $false)

    # Contexto de teste vs producao para isolamento estrito de cache
    $isTestContext = ($null -ne $AdvisorProbe) -or `
                     ([bool](Get-Field $Request 'is_test' $false)) -or `
                     ($taskId -match '(?i)test|mock|probe|gw-advisor|int-02')

    $activeCache = if ($isTestContext) { $script:AdvisorTestCache } else { $script:AdvisorProductionCache }

    # 1. Validate Escalation Trigger
    $signalCheck = Test-AdvisorEscalationSignal -Signal $signal -Justification $justification -InformationMissing $infoMissing
    if (-not $signalCheck.Admitted) {
        return [pscustomobject]@{
            Status               = 'REJECTED'
            ConsultationId       = "ADV-ERR-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            SessionId            = $null
            Agent                = $null
            ModelRequested       = $null
            ModelEffective       = $null
            ResponseRef          = $null
            RejectionReason      = $signalCheck.Reason
            RecommendedOption    = $null
            ActionableNextStep   = 'Retrieve missing evidence or formulate concrete escalation signal.'
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
        }
    }

    # 2. Resolve Model Tier if not provided (needed for cache key)
    if ($null -eq $ModelRouterSelection) {
        $routerLib = Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1'
        if (Test-Path -LiteralPath $routerLib) {
            . $routerLib
            $ModelRouterSelection = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex'
        }
    }

    $tier = if ($ModelRouterSelection) { $ModelRouterSelection.Tier } else { 'T3' }
    $modelToken = if ($ModelRouterSelection) { $ModelRouterSelection.ModelToken } else { 'MODEL_STRONG' }
    $modelCatalog = if ($ModelRouterSelection) { [string]$ModelRouterSelection.CatalogModel } else { 'openai/gpt-6.1-sol' }

    # Context fingerprint for cache isolation
    $ctxText = "$contextSummary|$(@($knownEvidence) -join ';')"
    $ctxBytes = [System.Text.Encoding]::UTF8.GetBytes($ctxText)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $ctxHash = [System.BitConverter]::ToString($hasher.ComputeHash($ctxBytes)).Replace('-', '').ToLowerInvariant()
    $ctxFingerprint = "$($ctxText.Length):$($ctxHash.Substring(0, 16))"

    # 3. Check Cache com chave expandida no cache isolado correto
    $cacheKey = Get-AdvisorConsultationCacheKey -TaskId $taskId -Signal $signal -Question $question -HeadSha $headSha -Model $modelCatalog -Constraints $constraints -ContextFingerprint $ctxFingerprint
    if ($activeCache.ContainsKey($cacheKey)) {
        $cached = $activeCache[$cacheKey]
        $cached.FromCache = $true
        return $cached
    }

    # 4. Invoke Advisor:
    #    (a) AdvisorProbe seam if provided (strictly for harness tests)
    #    (b) NativeExecutor seam if provided (explicit override)
    #    (c) Default native executor via OpenCode V2 (normal production flow)
    #    (d) If unexecutable or disabled, fail-closed with PROOF_ABSENT envelope
    $consultationId = "ADV-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 6))"
    
    $response = $null
    if ($null -ne $AdvisorProbe) {
        # Strict separation: test probes are executed here only
        $response = & $AdvisorProbe $Request $ModelRouterSelection
        if ($null -ne $response -and (-not $response.PSObject.Properties['ExecutionProofType'] -or [string]::IsNullOrWhiteSpace($response.ExecutionProofType))) {
            $response | Add-Member -NotePropertyName ExecutionProofType -NotePropertyValue 'HARNESS_PROBED' -Force
        }
    } elseif ($null -ne $NativeExecutor) {
        $response = & $NativeExecutor $Request $ModelRouterSelection
    } elseif (-not $DisableNativeExecutor -and -not [bool](Get-Field $Request 'disable_native' $false)) {
        # Conexao padrao do executor nativo OpenCode V2 no fluxo produtivo normal
        $nativeDispatch = Get-OrchestrationNativeAdvisorExecutor
        if ($null -ne $nativeDispatch) {
            $response = & $nativeDispatch $Request $ModelRouterSelection
        }
    }

    if ($null -eq $response) {
        # Standalone runtime without native execution: fail-closed with PROOF_ABSENT.
        # Fabricated recommendations are never returned as real consultations.
        # Nao inferir agente quando nao houver execucao comprovada.
        $response = [pscustomobject]@{
            Status               = 'PROOF_ABSENT'
            Reason               = 'NATIVE_DISPATCH_UNAVAILABLE'
            ConsultationId       = $consultationId
            SessionId            = $null
            Agent                = $null
            ModelRequested       = $modelCatalog
            ModelEffective       = $null
            ResponseRef          = $null
            RecommendedOption    = $null
            Rationale            = "Native dispatch of engineering-advisor not executed or proof absent."
            Risks                = @()
            RejectionReasons     = @()
            ActionableNextStep   = $null
            FallbackIfFailed     = $null
            ModelTierUsed        = $tier
            ModelTokenUsed       = $modelToken
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
            ExecutionProofType   = 'PROOF_ABSENT'
        }
    }

    # Structured interpretation of advisory opinion (only when consultation actually returned an opinion)
    if ($response.Status -notin @('PROOF_ABSENT', 'REJECTED')) {
        $textForStructuring = if (-not [string]::IsNullOrWhiteSpace($response.RecommendedOption)) {
            [string]$response.RecommendedOption
        } elseif (-not [string]::IsNullOrWhiteSpace($response.Rationale)) {
            [string]$response.Rationale
        } else { '' }

        $structuredOpinion = ConvertTo-StructuredAdvisoryOpinion -Text $textForStructuring
        if (-not $response.PSObject.Properties['AdvisoryStance']) {
            $response | Add-Member -NotePropertyName AdvisoryStance -NotePropertyValue $structuredOpinion.Stance -Force
        }
        if (-not $response.PSObject.Properties['IsBlocked']) {
            $response | Add-Member -NotePropertyName IsBlocked -NotePropertyValue $structuredOpinion.IsBlocked -Force
        }
        if (-not $response.PSObject.Properties['RequiresInvestigation']) {
            $response | Add-Member -NotePropertyName RequiresInvestigation -NotePropertyValue $structuredOpinion.RequiresInvestigation -Force
        }
        if (-not $response.PSObject.Properties['Diagnosis']) {
            $response | Add-Member -NotePropertyName Diagnosis -NotePropertyValue $structuredOpinion.Diagnosis -Force
        }
        if (-not $response.PSObject.Properties['MissingEvidence']) {
            $response | Add-Member -NotePropertyName MissingEvidence -NotePropertyValue $structuredOpinion.MissingEvidence -Force
        }
        if (-not $response.PSObject.Properties['StructuredOpinion']) {
            $response | Add-Member -NotePropertyName StructuredOpinion -NotePropertyValue $structuredOpinion -Force
        }

        if (-not [string]::IsNullOrWhiteSpace($structuredOpinion.NextAction) -and (-not $response.PSObject.Properties['ActionableNextStep'] -or $response.ActionableNextStep -eq 'Follow recommendation from engineering-advisor.' -or [string]::IsNullOrWhiteSpace($response.ActionableNextStep))) {
            $response | Add-Member -NotePropertyName ActionableNextStep -NotePropertyValue $structuredOpinion.NextAction -Force
        }
    } else {
        if (-not $response.PSObject.Properties['AdvisoryStance']) {
            $response | Add-Member -NotePropertyName AdvisoryStance -NotePropertyValue 'NONE' -Force
        }
        if (-not $response.PSObject.Properties['IsBlocked']) {
            $response | Add-Member -NotePropertyName IsBlocked -NotePropertyValue $false -Force
        }
        if (-not $response.PSObject.Properties['RequiresInvestigation']) {
            $response | Add-Member -NotePropertyName RequiresInvestigation -NotePropertyValue $false -Force
        }
    }

    # Enforce strict advisory boundaries
    if (-not $response.PSObject.Properties['IsAdvisory']) {
        $response | Add-Member -NotePropertyName IsAdvisory -NotePropertyValue $true -Force
    } else {
        $response.IsAdvisory = $true
    }
    if (-not $response.PSObject.Properties['Authoritative']) {
        $response | Add-Member -NotePropertyName Authoritative -NotePropertyValue $false -Force
    } else {
        $response.Authoritative = $false
    }
    if (-not $response.PSObject.Properties['FromCache']) {
        $response | Add-Member -NotePropertyName FromCache -NotePropertyValue $false -Force
    } else {
        $response.FromCache = $false
    }

    # Store in bounded cache (APENAS consultas COMPLETED_VERIFIED ou HARNESS_PROBED sao armazenadas)
    # Modelos divergentes ou provas parciais NUNCA sao armazenados em cache
    if ($response.Status -eq 'COMPLETED' -and $response.ExecutionProofType -in @('COMPLETED_VERIFIED', 'HARNESS_PROBED')) {
        if ($activeCache.Count -ge 50) {
            $activeCache.Clear()
        }
        $activeCache[$cacheKey] = $response
    }

    return $response
}

function Clear-AdvisorConsultationCache {
    <#
    .SYNOPSIS
        Clears the in-memory advisor consultation cache.
    .PARAMETER Scope
        Scope to clear: 'all', 'test', or 'production'. Default 'all'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('all', 'test', 'production')]
        [string]$Scope = 'all'
    )
    switch ($Scope) {
        'test' {
            if ($null -ne $script:AdvisorTestCache) { $script:AdvisorTestCache.Clear() }
        }
        'production' {
            if ($null -ne $script:AdvisorProductionCache) { $script:AdvisorProductionCache.Clear() }
            $script:AdvisorConsultationCache = $script:AdvisorProductionCache
        }
        'all' {
            if ($null -ne $script:AdvisorTestCache) { $script:AdvisorTestCache.Clear() }
            if ($null -ne $script:AdvisorProductionCache) { $script:AdvisorProductionCache.Clear() }
            $script:AdvisorConsultationCache = $script:AdvisorProductionCache
        }
    }
}
