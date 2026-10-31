<#!
.SYNOPSIS
    ETAPA 6 prova 6B - wiring reutilizavel de OBSERVACAO + DRY-RUN (sem merge real).
.DESCRIPTION
    Coleta snapshot SOMENTE-LEITURA via `gh api` (PR + check-runs + reviews),
    aplica anti-fabricacao de review (claim ReviewerApproved sem APPROVED real
    ou com CHANGES_REQUESTED nao superado => EVIDENCE_MISMATCH, sem mediador),
    e invoca Invoke-OrchestrationMergeMediated -DryRun com Authority lida de
    arquivo JSON obrigatorio (fail-closed antes de qualquer chamada gh quando
    ausente/invalida/nao-autorizada). NENHUM efeito remoto: somente `gh api`
    GET + DryRun; nenhum Executor real existe nesta versao (NE). Persistencia
    do intent em arquivo TEMP fora do repo; recibos sem segredos (so ids).
    PS 5.1 e pwsh compativeis. ASCII-only.

    Uso:
      powershell -NoProfile -File scripts/v3/full-delivery-etapa6-6b-wiring.ps1 `
        -Repository owner/repo -PrNumber 1 -AuthorityFile C:\path\auth.json

    Exit 0 = outcome honesto (qualquer outcome do mediador ou EVIDENCE_MISMATCH
    pre-mediador). Exit 1 = falha de ferramenta (gh ausente/falha, lib ausente).
    Exit 2 = erro de uso (parametros invalidos, AuthorityFile ausente/ilegivel).
#>
[CmdletBinding()]
param(
    [string]$Repository = '',
    $PrNumber = $null,
    [string]$AuthorityFile = '',
    $ReviewerApproved = $false,
    [string]$ReviewerIdentity = '',
    [string]$Risk = 'low',
    [string]$EvidenceChannel = 'provider-api',
    [string]$PersistDir = ''
)
$ErrorActionPreference = 'Stop'

function Write-W6BAudit {
    param([string]$Message)
    try { Write-Host ('WIRING6B: ' + [string]$Message) } catch { }
}

function Write-W6BResult {
    param($Result)
    try {
        Write-Output ($Result | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        Write-Output '{"outcome":"RECONCILE","reasons":["encode-failed"],"receipt":null}'
    }
}

function New-W6BEnvelope {
    param([string]$Outcome, $Reasons, $Receipt, $Extra)
    $r = @()
    if ($null -ne $Reasons) {
        foreach ($x in @($Reasons)) {
            if (($x -is [string]) -and ([string]$x).Length -gt 0) { $r += [string]$x }
        }
    }
    if ($r.Count -eq 0) { $r = @('unspecified') }
    $env = [pscustomobject]@{
        outcome = [string]$Outcome
        reasons = [string[]]$r
        receipt = $Receipt
    }
    if ($null -ne $Extra) {
        foreach ($k in @($Extra.Keys)) {
            try { $env | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue $Extra[$k] -Force } catch { }
        }
    }
    return $env
}

function Test-W6BSha40 {
    param($Value)
    try {
        if (-not ($Value -is [string])) { return $false }
        $v = ([string]$Value).Trim()
        if ($v.Length -ne 40) { return $false }
        return ($v -cmatch '^[0-9a-fA-F]{40}$')
    }
    catch { return $false }
}

function Invoke-W6BGhApi {
    param([string]$GhPath, [string]$Relative)
    # Retorna envelope @{ ok=[bool]; value=<json> } para preservar arrays
    # vazios (PS 5.1 desenrolaria `@()` para $null no retorno).
    try {
        $out = & $GhPath api $Relative 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { return [pscustomobject]@{ ok = $false; value = $null } }
        $text = ''
        if ($null -ne $out) { $text = ([string]($out -join "`n")).Trim() }
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ ok = $true; value = @() } }
        $parsed = ConvertFrom-Json $text
        if ($null -eq $parsed) {
            if ($text -ceq '[]') { return [pscustomobject]@{ ok = $true; value = @() } }
            return [pscustomobject]@{ ok = $false; value = $null }
        }
        return [pscustomobject]@{ ok = $true; value = $parsed }
    }
    catch { return [pscustomobject]@{ ok = $false; value = $null } }
}

try {
    # ---- (0) validacao de uso (antes de tudo) ----
    $repoTrim = ([string]$Repository).Trim()
    $repoOk = $false
    try {
        if (($repoTrim -ne '') -and ($repoTrim.Length -le 200) -and ($repoTrim -cmatch '\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\Z')) {
            $ps = $repoTrim.Split('/')
            if ((@($ps).Count -eq 2) -and ([string]$ps[0] -notmatch '\A\.') -and ([string]$ps[1] -notmatch '\A\.')) { $repoOk = $true }
        }
    }
    catch { $repoOk = $false }
    if (-not $repoOk) {
        Write-W6BAudit 'uso-invalido: invalid-repository'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('invalid-repository') -Receipt $null -Extra $null)
        exit 2
    }
    $repoCanon = $repoTrim.ToLowerInvariant()
    $prNum = 0
    $prOk = $false
    try {
        if (($null -ne $PrNumber) -and ($PrNumber -isnot [bool])) {
            if (($PrNumber -is [int]) -or ($PrNumber -is [long])) {
                if ([long]$PrNumber -ge 1) { $prNum = [long]$PrNumber; $prOk = $true }
            }
            elseif ($PrNumber -is [string]) {
                $t = ([string]$PrNumber).Trim()
                if ($t -cmatch '\A[0-9]{1,10}\Z') {
                    $n = [long]$t
                    if ($n -ge 1) { $prNum = $n; $prOk = $true }
                }
            }
        }
    }
    catch { $prOk = $false }
    if (-not $prOk) {
        Write-W6BAudit 'uso-invalido: invalid-pr-number'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('invalid-pr-number') -Receipt $null -Extra $null)
        exit 2
    }
    $authPath = ([string]$AuthorityFile).Trim()
    if ([string]::IsNullOrWhiteSpace($authPath)) {
        Write-W6BAudit 'uso-invalido: authority-file-missing'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('authority-file-missing') -Receipt $null -Extra $null)
        exit 2
    }
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        Write-W6BAudit 'uso-invalido: authority-file-not-found'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('authority-file-not-found') -Receipt $null -Extra $null)
        exit 2
    }
    $chanTrim = ([string]$EvidenceChannel).Trim()
    if (($chanTrim -cne 'provider-api') -and ($chanTrim -cne 'ci-system') -and ($chanTrim -cne 'reviewer-human')) {
        Write-W6BAudit 'uso-invalido: invalid-evidence-channel'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('invalid-evidence-channel') -Receipt $null -Extra $null)
        exit 2
    }
    $riskTrim = ([string]$Risk).Trim().ToLowerInvariant()
    if (($riskTrim -cne 'low') -and ($riskTrim -cne 'medium') -and ($riskTrim -cne 'high') -and ($riskTrim -cne 'critical')) {
        Write-W6BAudit 'uso-invalido: invalid-risk'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('invalid-risk') -Receipt $null -Extra $null)
        exit 2
    }
    # ReviewerApproved estrito para bool (CLI pode entregar string; mediador exige [bool]).
    $reviewerBool = $false
    $reviewerOk = $false
    try {
        if ($ReviewerApproved -is [bool]) { $reviewerBool = [bool]$ReviewerApproved; $reviewerOk = $true }
        elseif (($ReviewerApproved -is [int]) -or ($ReviewerApproved -is [long])) {
            if ([long]$ReviewerApproved -eq 1) { $reviewerBool = $true; $reviewerOk = $true }
            elseif ([long]$ReviewerApproved -eq 0) { $reviewerBool = $false; $reviewerOk = $true }
        }
        elseif ($ReviewerApproved -is [string]) {
            $t = ([string]$ReviewerApproved).Trim().ToLowerInvariant()
            if (($t -ceq 'true') -or ($t -ceq '1')) { $reviewerBool = $true; $reviewerOk = $true }
            elseif (($t -ceq 'false') -or ($t -ceq '0') -or ($t -ceq '')) { $reviewerBool = $false; $reviewerOk = $true }
        }
    }
    catch { $reviewerOk = $false }
    if (-not $reviewerOk) {
        Write-W6BAudit 'uso-invalido: reviewer-not-boolean'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('reviewer-not-boolean') -Receipt $null -Extra $null)
        exit 2
    }

    # ---- (A) Authority fail-closed ANTES de qualquer chamada gh ----
    $authority = $null
    try {
        $authText = [IO.File]::ReadAllText($authPath, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($authText)) { throw 'empty authority file' }
        $authority = ConvertFrom-Json $authText
    }
    catch {
        Write-W6BAudit 'authority-invalida: authority-file-unparseable (fail-closed, sem chamada gh)'
        Write-W6BResult (New-W6BEnvelope -Outcome 'USAGE_ERROR' -Reasons @('authority-file-unparseable') -Receipt $null -Extra $null)
        exit 2
    }
    if ($null -eq $authority) {
        Write-W6BAudit 'authority-invalida: authority-null (fail-closed, sem chamada gh)'
        Write-W6BResult (New-W6BEnvelope -Outcome 'NEEDS_USER_AUTHORITY' -Reasons @('AUTHORITY_NOT_BOOLEAN') -Receipt $null -Extra $null)
        exit 0
    }
    $authFailReason = ''
    $authFailOutcome = 'NEEDS_USER_AUTHORITY'
    try {
        $aRaw = $null; $pRaw = $null; $authorRaw = ''; $grantsRaw = $null; $scopesRaw = $null; $envRaw = ''
        try {
            if ($authority -is [System.Collections.IDictionary]) {
                if ($authority.Contains('authorized')) { $aRaw = $authority['authorized'] }
                if ($authority.Contains('production_authorized')) { $pRaw = $authority['production_authorized'] }
                if ($authority.Contains('author')) { $authorRaw = $authority['author'] }
                if ($authority.Contains('grants')) { $grantsRaw = $authority['grants'] }
                if ($authority.Contains('credential_scope')) { $scopesRaw = $authority['credential_scope'] }
                if ($authority.Contains('environment')) { $envRaw = $authority['environment'] }
            }
            else {
                foreach ($k in @('authorized','production_authorized','author','grants','credential_scope','environment')) {
                    $pp = $authority.PSObject.Properties[$k]
                    if ($null -ne $pp) {
                        switch ($k) {
                            'authorized' { $aRaw = $pp.Value }
                            'production_authorized' { $pRaw = $pp.Value }
                            'author' { $authorRaw = $pp.Value }
                            'grants' { $grantsRaw = $pp.Value }
                            'credential_scope' { $scopesRaw = $pp.Value }
                            'environment' { $envRaw = $pp.Value }
                        }
                    }
                }
            }
        }
        catch { $authFailReason = 'AUTHORITY_NOT_BOOLEAN' }
        if ($authFailReason -eq '') {
            if (($aRaw -isnot [bool]) -or ($aRaw -ne $true)) { $authFailReason = 'AUTHORITY_NOT_AUTHORIZED' }
            elseif (($pRaw -isnot [bool]) -or ($pRaw -ne $true)) { $authFailReason = 'PRODUCTION_NOT_AUTHORIZED' }
            elseif (($null -eq $authorRaw) -or (-not ($authorRaw -is [string])) -or [string]::IsNullOrWhiteSpace([string]$authorRaw)) { $authFailReason = 'INTENT_CONTEXT_INVALID'; $authFailOutcome = 'POLICY_BLOCKED' }
            elseif (($null -eq $grantsRaw) -or (@($grantsRaw).Count -eq 0)) { $authFailReason = 'INTENT_CONTEXT_INVALID'; $authFailOutcome = 'POLICY_BLOCKED' }
            elseif (($null -eq $scopesRaw) -or (@($scopesRaw).Count -eq 0)) { $authFailReason = 'CREDENTIAL_SCOPE_MISSING'; $authFailOutcome = 'POLICY_BLOCKED' }
            elseif (($null -eq $envRaw) -or (-not ($envRaw -is [string])) -or [string]::IsNullOrWhiteSpace([string]$envRaw)) { $authFailReason = 'INTENT_CONTEXT_INVALID'; $authFailOutcome = 'POLICY_BLOCKED' }
        }
    }
    catch { if ($authFailReason -eq '') { $authFailReason = 'AUTHORITY_NOT_BOOLEAN' } }
    if ($authFailReason -ne '') {
        Write-W6BAudit ('authority fail-closed: ' + $authFailReason + ' (sem chamada gh, sem mediador)')
        Write-W6BResult (New-W6BEnvelope -Outcome $authFailOutcome -Reasons @($authFailReason) -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 0
    }
    Write-W6BAudit 'authority pre-validada (forma ok; decisao final e do mediador)'

    # ---- libs ----
    $libDir = Join-Path $PSScriptRoot 'lib'
    $mmLib = Join-Path $libDir 'OrchestrationMergeMediated.ps1'
    if (-not (Test-Path -LiteralPath $mmLib -PathType Leaf)) {
        Write-W6BAudit 'ferramenta: lib-unavailable OrchestrationMergeMediated.ps1'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('lib-unavailable') -Receipt $null -Extra $null)
        exit 1
    }
    . $mmLib
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $policyPath = Join-Path $repoRoot 'source\registry\delivery-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        Write-W6BAudit 'ferramenta: policy-missing'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('policy-missing') -Receipt $null -Extra $null)
        exit 1
    }
    $policy = ConvertFrom-Json ([IO.File]::ReadAllText($policyPath, [Text.Encoding]::UTF8))

    # ---- gh disponivel (somente GET via `gh api`) ----
    $ghCmd = $null
    try { $ghCmd = Get-Command gh -ErrorAction SilentlyContinue } catch { $ghCmd = $null }
    if (($null -eq $ghCmd) -or [string]::IsNullOrWhiteSpace([string]$ghCmd.Source)) {
        Write-W6BAudit 'ferramenta: gh-not-found'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('gh-not-found') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $ghPath = [string]$ghCmd.Source

    # ---- (1) snapshot SOMENTE-LEITURA ----
    Write-W6BAudit ('observando repos/' + $repoCanon + '/pulls/' + [string]$prNum + ' (somente leitura)')
    $prCall = Invoke-W6BGhApi -GhPath $ghPath -Relative ('repos/' + $repoCanon + '/pulls/' + [string]$prNum)
    $pr = $null
    if (($null -ne $prCall) -and [bool]$prCall.ok) { $pr = $prCall.value }
    if (($null -eq $pr) -or (($pr -is [System.Collections.IList]) -and ($pr -isnot [string]) -and (@($pr).Count -eq 0))) {
        Write-W6BAudit 'ferramenta: gh-pr-unreadable'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('gh-pr-unreadable') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $headSha = ''
    try { $headSha = [string]$pr.head.sha } catch { $headSha = '' }
    if (-not (Test-W6BSha40 -Value $headSha)) {
        Write-W6BAudit 'ferramenta: snapshot-head-invalid'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('snapshot-head-invalid') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $headLow = $headSha.Trim().ToLowerInvariant()
    $prStateRaw = ''
    try { $prStateRaw = [string]$pr.state } catch { $prStateRaw = '' }
    $mergedFlag = $false
    try { if ($pr.merged -is [bool]) { $mergedFlag = [bool]$pr.merged } } catch { $mergedFlag = $false }
    $prState = 'OPEN'
    if ($mergedFlag) { $prState = 'MERGED' }
    elseif ($prStateRaw.Trim().ToLowerInvariant() -ceq 'closed') { $prState = 'CLOSED' }
    elseif ($prStateRaw.Trim().ToLowerInvariant() -ceq 'open') { $prState = 'OPEN' }
    else {
        Write-W6BAudit 'ferramenta: snapshot-pr-state-invalid'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('snapshot-pr-state-invalid') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $mergeableVal = 'UNKNOWN'
    try {
        if ($null -eq $pr.mergeable) { $mergeableVal = 'UNKNOWN' }
        elseif (($pr.mergeable -is [bool]) -and ([bool]$pr.mergeable)) { $mergeableVal = 'MERGEABLE' }
        elseif (($pr.mergeable -is [bool]) -and (-not [bool]$pr.mergeable)) { $mergeableVal = 'CONFLICTING' }
        else { $mergeableVal = 'UNKNOWN' }
    }
    catch { $mergeableVal = 'UNKNOWN' }

    $checksCall = Invoke-W6BGhApi -GhPath $ghPath -Relative ('repos/' + $repoCanon + '/commits/' + $headLow + '/check-runs')
    $checksObj = $null
    if (($null -ne $checksCall) -and [bool]$checksCall.ok) { $checksObj = $checksCall.value }
    if ($null -eq $checksObj) {
        Write-W6BAudit 'ferramenta: gh-check-runs-unreadable'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('gh-check-runs-unreadable') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $rawRuns = @()
    try { if ($null -ne $checksObj.check_runs) { $rawRuns = @($checksObj.check_runs) } } catch { $rawRuns = @() }
    $snapChecks = @()
    $allComplete = $true
    foreach ($cr in @($rawRuns)) {
        $nm = ''; $st = ''; $con = $null
        try { $nm = [string]$cr.name } catch { $nm = '' }
        try { $st = [string]$cr.status } catch { $st = '' }
        try { $con = $cr.conclusion } catch { $con = $null }
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }
        $stUp = $st.Trim().ToUpperInvariant()
        if (($stUp -cne 'QUEUED') -and ($stUp -cne 'IN_PROGRESS') -and ($stUp -cne 'COMPLETED')) { $stUp = 'QUEUED' }
        if ($stUp -cne 'COMPLETED') { $allComplete = $false }
        $entry = [pscustomobject]@{ name = $nm; head_sha = $headLow; status = $stUp; conclusion = $con }
        $snapChecks += $entry
    }
    if (@($snapChecks).Count -eq 0) { $allComplete = $false }

    # ---- (2) ANTI-FABRICACAO: reviews reais via gh ----
    Write-W6BAudit ('consultando reviews reais (anti-fabricacao) repos/' + $repoCanon + '/pulls/' + [string]$prNum + '/reviews')
    $reviewsCall = Invoke-W6BGhApi -GhPath $ghPath -Relative ('repos/' + $repoCanon + '/pulls/' + [string]$prNum + '/reviews')
    $reviewsVal = $null
    $reviewsOk = $false
    if ($null -ne $reviewsCall) {
        $reviewsOk = [bool]$reviewsCall.ok
        $reviewsVal = $reviewsCall.value
    }
    if (-not $reviewsOk) {
        Write-W6BAudit 'ferramenta: gh-reviews-unreadable'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('gh-reviews-unreadable') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    $revList = @()
    if ($null -ne $reviewsVal) { $revList = @($reviewsVal) }
    $approvedReal = $false
    $openChangesUsers = @()
    $reviewLines = @()
    try {
        $byUser = @{}
        foreach ($rv in @($revList)) {
            $u = ''; $s = ''; $at = ''
            try { $u = [string]$rv.user.login } catch { $u = '' }
            try { $s = [string]$rv.state } catch { $s = '' }
            try { $at = [string]$rv.submitted_at } catch { $at = '' }
            if ([string]::IsNullOrWhiteSpace($u)) { continue }
            $sUp = $s.Trim().ToUpperInvariant()
            if (($sUp -cne 'APPROVED') -and ($sUp -cne 'CHANGES_REQUESTED')) { continue }
            $key = $u.Trim().ToLowerInvariant()
            if (-not $byUser.ContainsKey($key)) { $byUser[$key] = @() }
            $byUser[$key] += [pscustomobject]@{ user = $u.Trim(); state = $sUp; submitted_at = $at }
            $reviewLines += ($u.Trim() + ':' + $sUp + ':' + $at)
        }
        foreach ($k in @($byUser.Keys)) {
            $items = @($byUser[$k] | Sort-Object -Property submitted_at)
            $last = $items[@($items).Count - 1]
            if ([string]$last.state -ceq 'APPROVED') { $approvedReal = $true }
            elseif ([string]$last.state -ceq 'CHANGES_REQUESTED') { $openChangesUsers += [string]$last.user }
        }
    }
    catch { $approvedReal = $false }
    Write-W6BAudit ('reviews observados: ' + [string]@($revList).Count + ' | APPROVED real=' + [string]$approvedReal + ' | CHANGES_REQUESTED aberto=' + ($openChangesUsers -join ','))
    $reviewDecision = 'REVIEW_REQUIRED'
    if (@($openChangesUsers).Count -gt 0) { $reviewDecision = 'CHANGES_REQUESTED' }
    elseif ($approvedReal) { $reviewDecision = 'APPROVED' }
    if ($reviewerBool -and (-not $approvedReal)) {
        Write-W6BAudit 'EVIDENCE_MISMATCH: claim ReviewerApproved sem APPROVED real no gh (sem mediador, sem efeito)'
        Write-W6BResult (New-W6BEnvelope -Outcome 'EVIDENCE_MISMATCH' -Reasons @('reviewer-claim-without-gh-approval') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum; head_sha = $headLow; reviews_observed = $reviewLines }))
        exit 0
    }
    if ($reviewerBool -and (@($openChangesUsers).Count -gt 0)) {
        Write-W6BAudit 'EVIDENCE_MISMATCH: CHANGES_REQUESTED nao superado no gh (sem mediador, sem efeito)'
        Write-W6BResult (New-W6BEnvelope -Outcome 'EVIDENCE_MISMATCH' -Reasons @('reviewer-claim-with-open-changes-requested') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum; head_sha = $headLow; reviews_observed = $reviewLines }))
        exit 0
    }

    $observedAt = ([datetime]::UtcNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $snapshot = [pscustomobject]@{
        repository = $repoCanon
        pr_number = $prNum
        head_sha = $headLow
        commit_sha = $headLow
        observed_at = $observedAt
        pr_state = $prState
        mergeable = $mergeableVal
        review_decision = $reviewDecision
        checks_complete = [bool]$allComplete
        checks = @($snapChecks)
    }
    Write-W6BAudit ('snapshot: head=' + $headLow.Substring(0, 8) + ' state=' + $prState + ' mergeable=' + $mergeableVal + ' review=' + $reviewDecision + ' checks=' + [string]@($snapChecks).Count + ' complete=' + [string]$allComplete)

    # ---- (3) VerifyFn: reconsulta gh (PR + parents do commit) ----
    $verifyState = @{ Repo = $repoCanon; Pr = $prNum; Gh = $ghPath }
    $verifyFn = {
        param($RepoArg, $PrArg, $ExpArg)
        try {
            $st = $verifyState
            $repo = [string]$st.Repo
            $prn = [long]$st.Pr
            $gh = [string]$st.Gh
            $out = & $gh api ('repos/' + $repo + '/pulls/' + [string]$prn) 2>&1
            if ($LASTEXITCODE -ne 0) { return $null }
            $p = ConvertFrom-Json (([string]($out -join "`n")).Trim())
            $m = $false
            try { if ($p.merged -is [bool]) { $m = [bool]$p.merged } } catch { $m = $false }
            $msha = ''
            try { $msha = [string]$p.merge_commit_sha } catch { $msha = '' }
            $parents = @()
            $methodProof = ''
            if ($m -and ($msha -is [string]) -and ($msha.Trim().Length -eq 40) -and ($msha -cmatch '^[0-9a-fA-F]{40}$')) {
                try {
                    $cout = & $gh api ('repos/' + $repo + '/commits/' + $msha.Trim()) 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $c = ConvertFrom-Json (([string]($cout -join "`n")).Trim())
                        foreach ($par in @($c.parents)) {
                            try { $parents += [string]$par.sha } catch { }
                        }
                    }
                }
                catch { $parents = @() }
                $methodProof = 'merge'
            }
            return [pscustomobject]@{
                merged = [bool]$m
                merge_commit_sha = [string]$msha
                repository = $repo
                pr_number = $prn
                merge_method = [string]$methodProof
                api_method = [string]$methodProof
                commit_parents = @($parents)
            }
        }
        catch { return $null }
    }.GetNewClosure()

    # ---- (4) PersistFn em TEMP (fora do repo) + ReceiptStore em memoria ----
    $persistBase = ([string]$PersistDir).Trim()
    if ([string]::IsNullOrWhiteSpace($persistBase)) { $persistBase = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($persistBase)) { $persistBase = ([IO.Path]::GetTempPath()) }
    try {
        if (-not (Test-Path -LiteralPath $persistBase -PathType Container)) { [void][IO.Directory]::CreateDirectory($persistBase) }
    }
    catch {
        Write-W6BAudit 'ferramenta: persist-dir-unavailable'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('persist-dir-unavailable') -Receipt $null -Extra $null)
        exit 1
    }
    $persistFile = Join-Path $persistBase ('etapa6-6b-intent-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $persistFn = {
        param($Intent)
        try {
            $line = ($Intent | ConvertTo-Json -Depth 8 -Compress)
            [IO.File]::AppendAllText($persistFile, ($line + [System.Environment]::NewLine), [Text.Encoding]::UTF8)
            return $true
        }
        catch { return $false }
    }.GetNewClosure()
    $receiptStore = @{}

    # ---- (5) mediador em DryRun (Authority vem do arquivo; nada inventado) ----
    Write-W6BAudit 'invocando Invoke-OrchestrationMergeMediated -DryRun (sem Executor, sem efeito)'
    $mmResult = $null
    try {
        $mmResult = Invoke-OrchestrationMergeMediated -Repository $repoCanon -PrNumber $prNum -ExpectedHeadSha $headLow -Snapshot $snapshot -Policy $policy -Authority $authority -Risk $riskTrim -ReviewerApproved $reviewerBool -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -ReviewerIdentity ([string]$ReviewerIdentity) -EvidenceChannel $chanTrim -PersistFn $persistFn -VerifyFn $verifyFn -ReceiptStore $receiptStore -GoalId 'etapa6-6b-proof' -TaskId 'CODER-ETAPA6-WIRING' -MergeMethod 'merge' -DryRun -MaxAgeSeconds 300
    }
    catch {
        Write-W6BAudit 'ferramenta: mediator-exception'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('mediator-exception') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }
    if ($null -eq $mmResult) {
        Write-W6BAudit 'ferramenta: mediator-null'
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('mediator-null') -Receipt $null -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum }))
        exit 1
    }

    # ---- (6) audit log + JSON; exit 0 em outcome honesto ----
    $mmOutcome = ''
    $mmReasons = @()
    $mmReceipt = $null
    try { $mmOutcome = [string]$mmResult.outcome } catch { $mmOutcome = '' }
    try { if ($null -ne $mmResult.reasons) { $mmReasons = @($mmResult.reasons) } } catch { $mmReasons = @() }
    try { $mmReceipt = $mmResult.receipt } catch { $mmReceipt = $null }
    Write-W6BAudit ('mediador outcome=' + $mmOutcome + ' reasons=' + ($mmReasons -join ','))
    Write-W6BAudit ('persist_file=' + $persistFile)
    Write-W6BAudit 'NE: sem caminho de merge real nesta versao; Executor real vira com autorizacao explicita futura'
    Write-W6BResult (New-W6BEnvelope -Outcome $mmOutcome -Reasons $mmReasons -Receipt $mmReceipt -Extra ([ordered]@{ repository = $repoCanon; pr_number = $prNum; head_sha = $headLow; observed_at = $observedAt; persist_file = $persistFile; snapshot_only = $true; grants_authority = $false; merge_authority = $false }))
    exit 0
}
catch {
    try {
        $msg = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'harness-exception' }
        Write-W6BAudit ('ferramenta: ' + $msg)
        Write-W6BResult (New-W6BEnvelope -Outcome 'TOOL_ERROR' -Reasons @('internal-error') -Receipt $null -Extra $null)
    }
    catch { }
    exit 1
}
