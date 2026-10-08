<#!
.SYNOPSIS
    Native Worker Dispatch bridge (honesto): DispatchIntent + recibos idempotentes.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1 compatible,
    ASCII-only, no network, no process spawn, no secrets. Never throws on
    operational paths: every failure is an envelope with ok=$false and a
    machine-readable reason.

    Arquitetura honesta (decisao do Planner, nao reabrir): NENHUM script
    PowerShell pode iniciar um worker nativo. O unico executor real e o
    Planner LLM via ferramenta `subagent` (V2) / `task` (V1). Este modulo
    NAO inventa API de spawn. O wiring honesto e:

      PS produz DispatchIntent validado + recibos idempotentes;
      o Planner (LLM) executa workers via subagent (o Executor);
      PS reconcilia resultados no kernel + evidence store.

    Por isso `Invoke-OrchestrationNativeDispatch` recebe um `-Executor`
    scriptblock injetado pelo chamador (harness/teste) ou e chamado pelo
    Planner apos execucao via subagent. Sem Executor, o Planner usa
    `New-OrchestrationDispatchIntent` e executa ele mesmo.

    Guarda-corpo central (Gate E): acao autorizada executa; acao nao
    autorizada e impedida ANTES de qualquer efeito externo. O Executor e
    invocado UMA vez e somente apos autorizacao admitida + admissao viva
    do kernel (F1) + recibo persistido + re-checagem de fencing pos-lock
    (F2). `-TestCallback` nunca e prova de producao.

    Idempotencia: recibo `<ReceiptDir>/<idempotency_key>.json` escrito
    como `pending` ANTES do Executor e atualizado para `settled` depois.
    O recibo vincula o fingerprint canonico do Intent completo (F7):
    re-dispatch da mesma key com Intent divergente e recusado como
    colisao, sem reutilizar resultado e sem executar. Recibo `pending`
    de execucao anterior incerta NUNCA da replay automatico (F3):
    retorna `pending-ambiguous` e exige reconciliacao externa explicita
    via `Confirm-OrchestrationDispatchReconciliation`; replay so quando
    a declaracao ORIGINAL persistida no recibo e o novo Intent declaram
    `external_idempotent=$true` com prova documentada (efeito externo
    idempotente pela mesma key; upgrade de idempotencia via novo Intent
    muda o fingerprint e e colisao recusada). Falha ao persistir
    `settled` e erro explicito, nunca silencioso.

    Holds preservados: `dispatchWorker/waitForSettlement/
    requestPlannerContinuation/cancelAuthorizedExecution` continuam em HOLD
    em OrchestrationRuntimeAdapterContract.ps1. Este modulo nao remove
    holds, nao ativa flags (`runtime_grant_enforcement` continua OFF).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $NDLibDir = $PSScriptRoot
    foreach ($NDLib in @('OrchestrationGoalKernel.ps1', 'OrchestrationEvidenceStore.ps1', 'OrchestrationTaskKernel.ps1')) {
        $NDPath = Join-Path $NDLibDir $NDLib
        if (Test-Path -LiteralPath $NDPath -PathType Leaf) { . $NDPath }
    }
}
catch { }

function Get-NDValue {
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
    }
    catch { return $Default }
}

function Get-NativeDispatchHash32 {
    param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            $h = $sha.ComputeHash($bytes)
            return (([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant().Substring(0, 32))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-OrchestrationDispatchRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return ([string]$RepoRoot).Trim() }
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    }
    catch { return '' }
}

function Get-OrchestrationDispatchReceiptDir {
    [CmdletBinding()]
    param([string]$ReceiptDir = '', [string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($ReceiptDir)) { return ([string]$ReceiptDir).Trim() }
        $root = Get-OrchestrationDispatchRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        $dir = Join-Path (Join-Path $root 'cache') 'native-dispatch-receipts'
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return '' }
        return $dir
    }
    catch { return '' }
}

function Test-NDTaskId {
    param([string]$Value)
    try {
        $cmd = Get-Command Test-TaskKernelId -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return [bool](Test-TaskKernelId -TaskId $Value) }
        return (([string]$Value) -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-NDCriterionRef {
    param($Value)
    try {
        if ($Value -isnot [string]) { return $false }
        return (([string]$Value) -cmatch '^criterion:[0-9]+$')
    }
    catch { return $false }
}

function New-OrchestrationDispatchIntent {
    <#
    .SYNOPSIS
        Constroi um envelope DispatchIntent puro e validado. Sem efeito externo.
    .DESCRIPTION
        Nunca carrega prompt com segredo: apenas `prompt_hash` (32 hex).
        `acceptance_criteria` sao refs `criterion:<idx>`. `idempotency_key`
        e fornecida (32 hex) ou derivada de forma deterministica do conteudo.
        Retorna envelope @{ok, reason, intent}; intent=$null quando invalido.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [long]$TaskExpectedRevision = 0,
        [string]$Agent = '',
        [string]$PromptHash = '',
        [string[]]$Scope = @(),
        [string[]]$AcceptanceCriteria = @(),
        [string]$IdempotencyKey = '',
        [string]$Owner = '',
        [long]$OwnershipGeneration = 0,
        [string]$BaseRevision = '',
        [bool]$ExternalIdempotent = $false,
        [string]$ExternalIdempotencyProof = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-NDTaskId $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-taskid'; intent = $null }
        }
        if ([long]$TaskExpectedRevision -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-expected-revision'; intent = $null }
        }
        $agent = ([string]$Agent).Trim()
        if ($agent -cnotmatch '^[A-Za-z0-9_-]{1,64}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-agent'; intent = $null }
        }
        $ph = ([string]$PromptHash).Trim().ToLowerInvariant()
        if ($ph -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-prompt-hash'; intent = $null }
        }
        $sc = @()
        foreach ($s in @($Scope)) {
            $t = ([string]$s).Trim()
            if ([string]::IsNullOrWhiteSpace($t) -or $t.Length -gt 240) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-scope'; intent = $null }
            }
            $sc += @($t)
        }
        if (@($sc).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-scope'; intent = $null }
        }
        $ac = @()
        foreach ($c in @($AcceptanceCriteria)) {
            if (-not (Test-NDCriterionRef $c)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-acceptance-criteria'; intent = $null }
            }
            $ac += @(([string]$c).Trim())
        }
        if (@($ac).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-acceptance-criteria'; intent = $null }
        }
        $own = ([string]$Owner).Trim()
        if ([string]::IsNullOrWhiteSpace($own) -or $own.Length -gt 128) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; intent = $null }
        }
        if ([long]$OwnershipGeneration -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-generation'; intent = $null }
        }
        $base = ([string]$BaseRevision).Trim()
        if ([string]::IsNullOrWhiteSpace($base) -or $base.Length -gt 80) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-base-revision'; intent = $null }
        }
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($key)) {
            $material = ($tid + '|' + $agent + '|' + $ph + '|' + $base + '|' + $own + '|' + [string]$OwnershipGeneration + '|' + ($ac -join ',') + '|' + ($sc -join ','))
            $key = Get-NativeDispatchHash32 $material
            if ([string]::IsNullOrWhiteSpace($key)) {
                return [pscustomobject]@{ ok = $false; reason = 'idempotency-key-failed'; intent = $null }
            }
        }
        elseif ($key -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-idempotency-key'; intent = $null }
        }
        $extProof = ([string]$ExternalIdempotencyProof).Trim()
        if ([bool]$ExternalIdempotent) {
            if ([string]::IsNullOrWhiteSpace($extProof) -or ($extProof.Length -gt 240)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-idempotency-proof'; intent = $null }
            }
        }
        else { $extProof = '' }
        $intent = [pscustomobject][ordered]@{
            schema_version       = 1
            task_id              = $tid
            task_expected_revision = [long]$TaskExpectedRevision
            agent                = $agent
            prompt_hash          = $ph
            scope                = [string[]]$sc
            acceptance_criteria  = [string[]]$ac
            idempotency_key      = $key
            owner                = $own
            ownership_generation = [long]$OwnershipGeneration
            base_revision        = $base
            external_idempotent  = [bool]$ExternalIdempotent
            external_idempotency_proof = $extProof
            created_at           = ([DateTime]::UtcNow.ToString('o'))
        }
        return [pscustomobject]@{ ok = $true; reason = ''; intent = $intent }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; intent = $null }
    }
}

function Test-NativeDispatchAuthorization {
    <#
    .SYNOPSIS
        Gate de autorizacao do dispatch nativo. Fail-closed, documentado.
    .DESCRIPTION
        Admite somente quando TODAS as condicoes valem:
          (1) Authorization.explicit_allow -ceq $true (bool real);
          (2) Authorization.source nao e test-callback: TestCallback nunca
              e prova de producao (recusa explicita);
          (3) Goal vivo lido do store nao esta em estado terminal;
          (4) ownership viva (fencing token owner+generation, lease valido)
              via Test-OrchestrationGoalOwnership (CAS-style, mesma familia
              de Acquire-OrchestrationGoalOwnership).
        Registra evidencia de ativacao (JSONL limitado, best-effort; falha
        de log nunca altera o veredito). Nunca lanca: retorna envelope
        @{ok, admitted, reason}. Qualquer duvida = negado.
    #>
    [CmdletBinding()]
    param(
        $Authorization = $null,
        [string]$GoalStoreDir = '',
        [string]$ActivationLogDir = ''
    )
    try {
        if ($null -eq $Authorization) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'authorization-missing' }
        }
        $src = ([string](Get-NDValue $Authorization 'source' '')).Trim().ToLowerInvariant()
        if (($src -ceq 'test-callback') -or ([bool](Get-NDValue $Authorization 'test_callback_only' $false))) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'test-callback-never-authorizes-production' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'test-callback-never-authorizes-production' }
        }
        $explicit = Get-NDValue $Authorization 'explicit_allow' $false
        if (($explicit -isnot [bool]) -or (-not $explicit)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'explicit-allow-required' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'explicit-allow-required' }
        }
        $gid = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $own = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $gen = [long](Get-NDValue $Authorization 'generation' 0)
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($own) -or ($gen -lt 1)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'invalid-fencing-token' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'invalid-fencing-token' }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'ownership-check-unavailable' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'ownership-check-unavailable' }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            $why = 'goal-read-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $slot 'reason' ''))) { $why = ('goal-read-failed:' + [string](Get-NDValue $slot 'reason' '')) } } catch { }
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason $why -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why }
        }
        $goal = Get-NDValue $slot 'goal' $null
        $state = ''
        try { $state = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $state = '' }
        if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'goal-terminal' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'goal-terminal' }
        }
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $own -Generation $gen }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            $why = 'ownership-not-held'
            try { if (($null -ne $chk) -and (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $chk 'reason' '')))) { $why = ('ownership-not-held:' + [string](Get-NDValue $chk 'reason' '')) } } catch { }
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason $why -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why }
        }
        try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $true -Reason '' -ActivationLogDir $ActivationLogDir) } catch { }
        return [pscustomobject]@{ ok = $true; admitted = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'authorization-internal-error' }
    }
}

function Write-NDActivationEvidence {
    param($Authorization = $null, [bool]$Admitted = $false, [string]$Reason = '', [string]$ActivationLogDir = '')
    try {
        $dir = ([string]$ActivationLogDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $root = Get-OrchestrationDispatchRepoRoot
            if ([string]::IsNullOrWhiteSpace($root)) { return $false }
            $dir = Join-Path (Join-Path $root 'cache') 'native-dispatch-receipts'
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return $false }
        $path = Join-Path $dir 'activations.jsonl'
        try {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Item -LiteralPath $path).Length -gt 262144)) { return $false }
        }
        catch { }
        $row = [ordered]@{
            timestamp     = ([DateTime]::UtcNow.ToString('o'))
            goal_id       = ([string](Get-NDValue $Authorization 'goal_id' ''))
            owner         = ([string](Get-NDValue $Authorization 'owner' ''))
            admitted      = [bool]$Admitted
            reason        = ([string]$Reason)
            source        = ([string](Get-NDValue $Authorization 'source' 'planner'))
        }
        $line = ((ConvertTo-Json -InputObject $row -Compress) + "`n")
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 2048) { return $false }
        try { [IO.File]::AppendAllText($path, $line, [Text.Encoding]::UTF8) } catch { return $false }
        return $true
    }
    catch { return $false }
}

function Test-OrchestrationDispatchResultShape {
    <#
    .SYNOPSIS
        Valida a forma do resultado do worker. Rejeita verified_pass/done.
    #>
    [CmdletBinding()]
    param($Result = $null)
    try {
        if ($null -eq $Result) {
            return [pscustomobject]@{ ok = $false; reason = 'result-missing' }
        }
        $status = ([string](Get-NDValue $Result 'status' '')).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $status) {
            return [pscustomobject]@{ ok = $false; reason = 'status-not-allowed-from-worker' }
        }
        $refs = @(Get-NDValue $Result 'claimed_evidence' @())
        if (@($refs).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'evidence-refs-missing' }
        }
        foreach ($r in @($refs)) {
            if (-not (Test-NDCriterionRef $r)) {
                return [pscustomobject]@{ ok = $false; reason = 'evidence-ref-invalid' }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; status = $status; claimed_evidence = [string[]]@($refs) }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'result-invalid' }
    }
}

function Open-NDReceiptLock {
    param([string]$Dir, [int]$LockTimeoutMs = 60000)
    try {
        $lockPath = Join-Path $Dir '.dispatch.lock'
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $LockTimeoutMs))
        do {
            try {
                return ([IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            }
            catch { Start-Sleep -Milliseconds 10 }
        } while ([DateTime]::UtcNow -lt $deadline)
        return $null
    }
    catch { return $null }
}

function Read-NDReceipt {
    param([string]$Dir, [string]$Key)
    try {
        $path = Join-Path $Dir ($Key + '.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $raw = ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))
        if ([string](Get-NDValue $raw 'idempotency_key' '') -cne $Key) { return $null }
        return $raw
    }
    catch { return $null }
}

function Write-NDReceipt {
    param([string]$Dir, $Receipt)
    try {
        $key = ([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') { return $false }
        $path = Join-Path $Dir ($key + '.json')
        $json = ConvertTo-Json -InputObject $Receipt -Depth 20 -Compress
        $tmp = Join-Path $Dir (('receipt-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
        catch { return $false }
        try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
        catch { try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }; return $false }
        return $true
    }
    catch { return $false }
}

function Get-NDCanonicalField {
    <#
    .SYNOPSIS
        Serializa um campo como nome:comprimento:valor; (R2, nao-ambiguo).
    .DESCRIPTION
        Prefixo de comprimento em caracteres elimina ambiguidade mesmo
        quando o valor contem os delimitadores. ASCII-only no codigo;
        o valor e opaco (qualquer texto). Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Name = '', [string]$Value = '')
    try {
        $v = ([string]$Value)
        return ([string]$Name + ':' + [string]$v.Length + ':' + $v + ';')
    }
    catch { return ([string]$Name + ':0:;') }
}

function Get-NDSortedOrdinal {
    [CmdletBinding()]
    param($Items = $null)
    try {
        $arr = @()
        foreach ($x in @($Items)) { $arr += @(([string]$x).Trim()) }
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        return $arr
    }
    catch { return @() }
}

function Get-NDIntentFingerprint {
    <#
    .SYNOPSIS
        Fingerprint canonico do Intent completo (F7+R2). Qualquer
        divergencia semantica muda o fingerprint; a mesma idempotency_key
        com fingerprint distinto e colisao, nunca reutilizacao.
    .DESCRIPTION
        Serializacao canonica estruturada v2 (R2): ordem fixa de campos,
        cada valor com prefixo de comprimento (nao-ambiguo mesmo com
        delimitadores no valor), listas (scope, acceptance_criteria)
        ordenadas em ordinal com contagem explicita. Cobre TODOS os campos
        semanticos: task, owner, generation, agent, scopes, prompt-hash,
        base-revision, expected-revision, external_idempotent e
        external_idempotency_proof. Em particular, upgrade de idempotencia
        (adicionar external_idempotent/proof num reenvio) muda o
        fingerprint e e recusado como colisao.
    #>
    [CmdletBinding()]
    param($Intent = $null)
    try {
        $scopes = Get-NDSortedOrdinal -Items @((Get-NDValue $Intent 'scope' @()))
        $acc = Get-NDSortedOrdinal -Items @((Get-NDValue $Intent 'acceptance_criteria' @()))
        $extFlag = '0'
        if ([bool](Get-NDValue $Intent 'external_idempotent' $false)) { $extFlag = '1' }
        $material = 'ndfp2;'
        $material += Get-NDCanonicalField -Name 'task' -Value ([string](Get-NDValue $Intent 'task_id' ''))
        $material += Get-NDCanonicalField -Name 'owner' -Value ([string](Get-NDValue $Intent 'owner' ''))
        $material += Get-NDCanonicalField -Name 'gen' -Value ([string]([long](Get-NDValue $Intent 'ownership_generation' 0)))
        $material += Get-NDCanonicalField -Name 'agent' -Value ([string](Get-NDValue $Intent 'agent' ''))
        $material += Get-NDCanonicalField -Name 'prompt' -Value ([string](Get-NDValue $Intent 'prompt_hash' ''))
        $material += Get-NDCanonicalField -Name 'base' -Value ([string](Get-NDValue $Intent 'base_revision' ''))
        $material += Get-NDCanonicalField -Name 'rev' -Value ([string]([long](Get-NDValue $Intent 'task_expected_revision' 0)))
        $material += Get-NDCanonicalField -Name 'ext' -Value $extFlag
        $material += Get-NDCanonicalField -Name 'proof' -Value ([string](Get-NDValue $Intent 'external_idempotency_proof' ''))
        $material += 'acc:' + [string](@($acc).Count) + ';'
        foreach ($a in @($acc)) { $material += Get-NDCanonicalField -Name 'a' -Value ([string]$a) }
        $material += 'scope:' + [string](@($scopes).Count) + ';'
        foreach ($s in @($scopes)) { $material += Get-NDCanonicalField -Name 's' -Value ([string]$s) }
        return (Get-NativeDispatchHash32 $material)
    }
    catch { return '' }
}

function Test-NDLiveTaskAdmission {
    <#
    .SYNOPSIS
        Admissao pre-efeito contra o kernel vivo (F1). Fail-closed.
    .DESCRIPTION
        Valida ANTES de qualquer efeito: a flag efetiva do TaskKernel
        (R1: kernel OFF recusa com 0 calls mesmo com task existente, pois
        o kernel nao aceitaria o worker-result); a task existe no
        TaskKernel e nao esta em estado terminal; a revisao esperada e o
        base_revision do Intent conferem com o registro vivo; owner/generation do Intent
        conferem com a Authorization; o dono atual da task confere com a
        Authorization; a task pertence ao goal da Authorization (active_tasks
        do goal vivo); cada scope do Intent esta nos read/write scopes da
        task; quando a Authorization declara allowed_agents/allowed_scopes,
        o agent e os scopes do Intent estao contidos neles. Qualquer
        divergencia recusa com 0 calls do Executor. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Intent = $null, $Authorization = $null, $Goal = $null, [string]$TasksDir = '', [string]$FlagsPath = '', [string]$RepoRoot = '')
    try {
        # R1: flag efetiva do TaskKernel ANTES de qualquer efeito. Kernel
        # OFF + task existente recusa com 0 calls: sem kernel vivo nao ha
        # como liquidar o worker-result, entao admitir seria efeito sem
        # liquidacao. Fail-closed quando o estado da flag e indeterminavel.
        $flagCmd = Get-Command Get-TaskKernelFlagState -ErrorAction SilentlyContinue
        if ($null -eq $flagCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-unavailable' }
        }
        $flags = $null
        try { $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot }
        catch { $flags = $null }
        if (($null -eq $flags) -or (-not [bool](Get-NDValue $flags 'enabled' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-disabled' }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-unavailable' }
        }
        $tid = ([string](Get-NDValue $Intent 'task_id' '')).Trim()
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'task-read-failed' }
        }
        $errCode = ''
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('error')) { $errCode = ([string]$task['error']) }
            }
            else {
                $ep = $task.PSObject.Properties['error']
                if ($null -ne $ep) { $errCode = ([string]$ep.Value) }
            }
        }
        catch { $errCode = '' }
        if (-not [string]::IsNullOrWhiteSpace($errCode)) {
            if ($errCode -ceq 'NOT_FOUND') {
                return [pscustomobject]@{ ok = $false; reason = 'task-not-found' }
            }
            if ($errCode -ceq 'KERNEL_DISABLED') {
                return [pscustomobject]@{ ok = $false; reason = 'taskkernel-disabled' }
            }
            return [pscustomobject]@{ ok = $false; reason = ('task-read-failed:' + $errCode) }
        }
        $termCmd = Get-Command Test-TaskKernelTerminalState -ErrorAction SilentlyContinue
        $tState = ([string](Get-NDValue $task 'state' '')).Trim().ToUpperInvariant()
        $isTerminal = $false
        try {
            if ($null -ne $termCmd) { $isTerminal = [bool](Test-TaskKernelTerminalState -State $tState) }
            else { $isTerminal = (@('DONE', 'EXHAUSTED', 'CANCELLED') -ccontains $tState) }
        }
        catch { $isTerminal = $true }
        if ($isTerminal) {
            return [pscustomobject]@{ ok = $false; reason = 'task-terminal' }
        }
        if ([long](Get-NDValue $task 'revision' -1) -ne [long](Get-NDValue $Intent 'task_expected_revision' 0)) {
            return [pscustomobject]@{ ok = $false; reason = 'task-revision-mismatch' }
        }
        if (([string](Get-NDValue $task 'base_revision' '')) -cne ([string](Get-NDValue $Intent 'base_revision' ''))) {
            return [pscustomobject]@{ ok = $false; reason = 'base-revision-mismatch' }
        }
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        if (([string](Get-NDValue $Intent 'owner' '')) -cne $authOwner) {
            return [pscustomobject]@{ ok = $false; reason = 'owner-mismatch' }
        }
        if ([long](Get-NDValue $Intent 'ownership_generation' 0) -ne $authGen) {
            return [pscustomobject]@{ ok = $false; reason = 'generation-mismatch' }
        }
        if (([string](Get-NDValue $task 'current_owner' '')) -cne $authOwner) {
            return [pscustomobject]@{ ok = $false; reason = 'task-owner-mismatch' }
        }
        if ($null -eq $Goal) {
            return [pscustomobject]@{ ok = $false; reason = 'goal-unavailable' }
        }
        $inActive = $false
        $inCompleted = $false
        try {
            foreach ($t in @((Get-NDValue $Goal 'active_tasks' @()))) {
                if ($tid -ceq ([string]$t)) { $inActive = $true; break }
            }
            foreach ($t in @((Get-NDValue $Goal 'completed_tasks' @()))) {
                if ($tid -ceq ([string]$t)) { $inCompleted = $true; break }
            }
        }
        catch { return [pscustomobject]@{ ok = $false; reason = 'goal-unavailable' } }
        if ($inCompleted) {
            return [pscustomobject]@{ ok = $false; reason = 'task-already-completed' }
        }
        if (-not $inActive) {
            return [pscustomobject]@{ ok = $false; reason = 'task-not-in-goal' }
        }
        $granted = @()
        try {
            $granted = @(@((Get-NDValue $task 'read_scopes' @())) + @((Get-NDValue $task 'write_scopes' @())))
        }
        catch { $granted = @() }
        foreach ($s in @((Get-NDValue $Intent 'scope' @()))) {
            $needle = ([string]$s)
            $found = $false
            foreach ($g in @($granted)) {
                if ($needle -ceq ([string]$g)) { $found = $true; break }
            }
            if (-not $found) {
                return [pscustomobject]@{ ok = $false; reason = 'scope-not-granted' }
            }
        }
        $allowedAgents = @((Get-NDValue $Authorization 'allowed_agents' @()))
        if (@($allowedAgents).Count -gt 0) {
            $agent = ([string](Get-NDValue $Intent 'agent' ''))
            $aFound = $false
            foreach ($a in @($allowedAgents)) {
                if ($agent -ceq ([string]$a)) { $aFound = $true; break }
            }
            if (-not $aFound) {
                return [pscustomobject]@{ ok = $false; reason = 'agent-not-granted' }
            }
        }
        $allowedScopes = @((Get-NDValue $Authorization 'allowed_scopes' @()))
        if (@($allowedScopes).Count -gt 0) {
            foreach ($s in @((Get-NDValue $Intent 'scope' @()))) {
                $needle = ([string]$s)
                $sFound = $false
                foreach ($g in @($allowedScopes)) {
                    if ($needle -ceq ([string]$g)) { $sFound = $true; break }
                }
                if (-not $sFound) {
                    return [pscustomobject]@{ ok = $false; reason = 'scope-not-granted' }
                }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'admission-internal-error' }
    }
}

function Test-NDPostLockFencing {
    <#
    .SYNOPSIS
        Re-checagem de fencing IMEDIATAMENTE antes do efeito (F2).
    .DESCRIPTION
        Rele o goal vivo do store sob o lock do recibo e exige: goal
        legivel, estado exatamente ACTIVE e fencing owner+generation com
        lease valido. Takeover, lease expirado ou saida de ACTIVE recusa
        sem executar. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$Owner = '', [long]$Generation = 0, [string]$GoalStoreDir = '')
    try {
        $gid = ([string]$GoalId).Trim()
        $own = ([string]$Owner).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($own) -or ([long]$Generation -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'post-lock-invalid-token' }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            return [pscustomobject]@{ ok = $false; reason = 'post-lock-check-unavailable' }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            $why = 'post-lock-goal-unreadable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $slot 'reason' ''))) { $why = ('post-lock-goal-unreadable:' + [string](Get-NDValue $slot 'reason' '')) } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why }
        }
        $goal = Get-NDValue $slot 'goal' $null
        $state = ''
        try { $state = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $state = '' }
        if ($state -cne 'ACTIVE') {
            return [pscustomobject]@{ ok = $false; reason = ('post-lock-goal-not-active:' + $state) }
        }
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $own -Generation ([long]$Generation) }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            $why = 'post-lock-fencing-changed'
            try { if (($null -ne $chk) -and (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $chk 'reason' '')))) { $why = ('post-lock-fencing-changed:' + [string](Get-NDValue $chk 'reason' '')) } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'post-lock-internal-error' }
    }
}

function Test-NDReconcileKernelProof {
    <#
    .SYNOPSIS
        Prova kernel-side vinculada para reconciliacao de sucesso (R3 + FIX3-S1). Fail-closed.
    .DESCRIPTION
        Sucesso reconciliado exige prova VINCULADA, nunca booleans
        declarados no Outcome e nunca artefatos alheios:
          (a) o worker_result persistido no kernel para a task existe e
              tem status + claimed_evidence iguais (campo a campo) ao
              resultado declarado no Outcome; transicao de revisao sem
              worker-result nao satisfaz;
          (b) a evidencia existe no store E esta vinculada a task/key do
              recibo: evidence.task_id confere com a task do recibo
              (provenance.kernel_task_ref confere quando legivel - o
              store redige padroes de segredo), e run_id ou
              source_fingerprints['dispatch-intent'] confere com a
              idempotency_key ou o fingerprint do recibo; evidencia de
              outro despacho nao satisfaz.
        Outcome inventado com artefatos alheios e recusado com razao
        explicita. Quando aceita, devolve os valores kernel-side
        (worker_status / worker_claimed_evidence) para o chamador
        persistir a verdade do kernel, nunca copiar o declarado sem
        comparacao. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [long]$ExpectedRevision = 0,
        [string]$EvidenceId = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$EvidenceStoreDir = '',
        [string]$RepoRoot = '',
        [string]$DeclaredStatus = '',
        [string[]]$DeclaredClaimedEvidence = @(),
        [string]$IdempotencyKey = '',
        [string]$IntentFingerprint = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid) -or ([long]$ExpectedRevision -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        # FIX3-S1: sem o resultado declarado e o vinculo do recibo nao
        # ha como comparar campo a campo; recusa fail-closed.
        $decStatus = ([string]$DeclaredStatus).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $decStatus) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        $fp = ([string]$IntentFingerprint).Trim().ToLowerInvariant()
        if (($key -cnotmatch '^[a-f0-9]{32}$') -or ($fp -cnotmatch '^[a-f0-9]{32}$')) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $isErr = $false
        try {
            if ($task -is [System.Collections.IDictionary]) { $isErr = $task.Contains('error') }
            else { $isErr = ($null -ne $task.PSObject.Properties['error']) }
        }
        catch { $isErr = $true }
        if ($isErr) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        if ([long](Get-NDValue $task 'revision' -1) -le [long]$ExpectedRevision) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        # (a) worker_result kernel-side existe e confere campo a campo
        # com o declarado. Revisao avancada por outra via (p.ex.
        # verification) sem worker-result nao satisfaz.
        $kwr = Get-NDValue $task 'worker_result' $null
        if ($null -eq $kwr) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-missing' }
        }
        $kStatus = ([string](Get-NDValue $kwr 'status' '')).Trim().ToLowerInvariant()
        if ($kStatus -cne $decStatus) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
        }
        foreach ($r in @($DeclaredClaimedEvidence)) {
            if (-not (Test-NDCriterionRef $r)) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
            }
        }
        $kSorted = @(Get-NDSortedOrdinal -Items @((Get-NDValue $kwr 'claimed_evidence' @())))
        $dSorted = @(Get-NDSortedOrdinal -Items @($DeclaredClaimedEvidence))
        if (@($kSorted).Count -ne @($dSorted).Count) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
        }
        for ($i = 0; $i -lt @($kSorted).Count; $i++) {
            if (([string]$kSorted[$i]) -cne ([string]$dSorted[$i])) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
            }
        }
        # (b) evidencia vinculada a task/key do recibo, nunca alheia.
        $eid = ([string]$EvidenceId).Trim().ToLowerInvariant()
        if ($eid -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        $evDir = ([string]$EvidenceStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($evDir)) {
            $evDirCmd = Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue
            if ($null -eq $evDirCmd) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
            }
            try { $evDir = ([string](Get-OrchestrationEvidenceDefaultStoreDir)) }
            catch { $evDir = '' }
        }
        if ([string]::IsNullOrWhiteSpace($evDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
        }
        $evPath = Join-Path $evDir ($eid + '.json')
        if (-not (Test-Path -LiteralPath $evPath -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        $ev = $null
        try { $ev = ConvertFrom-Json ([IO.File]::ReadAllText($evPath, [Text.Encoding]::UTF8)) }
        catch { $ev = $null }
        if ($null -eq $ev) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        if (([string](Get-NDValue $ev 'task_id' '')).Trim() -cne $tid) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        # provenance.kernel_task_ref confere quando legivel: o store
        # redige valores com padrao de segredo (p.ex. 'task-' casa
        # 'sk-'), entao ref redigida nao pode exigir igualdade - a
        # task ja esta vinculada por evidence.task_id acima.
        $evProv = Get-NDValue $ev 'provenance' $null
        $evKref = ([string](Get-NDValue $evProv 'kernel_task_ref' '')).Trim()
        if (([string]$evKref -cnotmatch '\[REDACTED') -and ($evKref -cne $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        $evRun = (([string](Get-NDValue $ev 'run_id' '')).Trim().ToLowerInvariant())
        $evDisp = ''
        try {
            $evSf = Get-NDValue $ev 'source_fingerprints' $null
            if ($evSf -is [System.Collections.IDictionary]) {
                if ($evSf.Contains('dispatch-intent')) { $evDisp = (([string]$evSf['dispatch-intent']).Trim().ToLowerInvariant()) }
            }
            else {
                $pp = $evSf.PSObject.Properties['dispatch-intent']
                if ($null -ne $pp) { $evDisp = (([string]$pp.Value).Trim().ToLowerInvariant()) }
            }
        }
        catch { $evDisp = '' }
        if ((($evRun -cne $key) -and ($evDisp -cne $key)) -and ($evDisp -cne $fp)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; worker_status = $kStatus; worker_claimed_evidence = [string[]]$kSorted }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
    }
}

function Test-NDDuplicateReadIdentity {
    <#
    .SYNOPSIS
        Vincula a leitura idempotente de recibo settled a Authorization (FIX3-S2). Fail-closed, sem vazar.
    .DESCRIPTION
        Antes de devolver o resultado de um recibo settled, confere a
        identidade da Authorization contra a identidade persistida no
        recibo (goal/owner/generation + task pertence ao goal, mesmo
        padrao do Confirm):
          - goal_id divergente (cross-goal) sempre recusa;
          - mesma identidade (goal/owner/generation) permite a leitura;
          - takeover (mesmo goal, owner/generation novos com ownership
            viva + worker_result kernel-side presente e igual campo a
            campo ao do recibo) permite a leitura com prova.
        Sem prova, recusa. O veredito nunca inclui conteudo do recibo:
        recusas usam uma razao unica e nao revelam worker_result nem
        evidence_id. Nenhuma ampliacao de autoridade: leitura do
        resultado ja persistido para o dono vivo do mesmo goal. Nunca
        lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null, $Authorization = $null, [string]$GoalStoreDir = '', [string]$TasksDir = '', [string]$RepoRoot = '')
    try {
        if (($null -eq $Receipt) -or ($null -eq $Authorization)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recGoal = ([string](Get-NDValue $Receipt 'goal_id' '')).Trim()
        $authGoal = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($recGoal) -or ($recGoal -cne $authGoal)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recTask = ([string](Get-NDValue $Receipt 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($recTask)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $recGoal -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $goal = Get-NDValue $slot 'goal' $null
        if ($null -eq $goal) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $inGoal = $false
        try {
            foreach ($t in @((Get-NDValue $goal 'active_tasks' @()))) {
                if ($recTask -ceq ([string]$t)) { $inGoal = $true; break }
            }
            if (-not $inGoal) {
                foreach ($t in @((Get-NDValue $goal 'completed_tasks' @()))) {
                    if ($recTask -ceq ([string]$t)) { $inGoal = $true; break }
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        if (-not $inGoal) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recOwner = ([string](Get-NDValue $Receipt 'owner' '')).Trim()
        $recGen = [long](Get-NDValue $Receipt 'ownership_generation' 0)
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        if (([string]::IsNullOrWhiteSpace($recOwner)) -or ([string]::IsNullOrWhiteSpace($authOwner)) -or ($recGen -lt 1) -or ($authGen -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        if (($recOwner -ceq $authOwner) -and ($recGen -eq $authGen)) {
            return [pscustomobject]@{ ok = $true; reason = ''; takeover = $false }
        }
        # Takeover: novo owner vivo do mesmo goal + prova kernel-side de
        # que o worker_result do recibo corresponde a verdade do kernel.
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $authOwner -Generation $authGen }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $recTask -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $isErr = $false
        try {
            if ($task -is [System.Collections.IDictionary]) { $isErr = $task.Contains('error') }
            else { $isErr = ($null -ne $task.PSObject.Properties['error']) }
        }
        catch { $isErr = $true }
        if ($isErr) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $kwr = Get-NDValue $task 'worker_result' $null
        $swr = Get-NDValue $Receipt 'worker_result' $null
        if (($null -eq $kwr) -or ($null -eq $swr)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $ks = ([string](Get-NDValue $kwr 'status' '')).Trim().ToLowerInvariant()
        $ss = ([string](Get-NDValue $swr 'status' '')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($ks) -or ($ks -cne $ss)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $kc = @(Get-NDSortedOrdinal -Items @((Get-NDValue $kwr 'claimed_evidence' @())))
        $sc = @(Get-NDSortedOrdinal -Items @((Get-NDValue $swr 'claimed_evidence' @())))
        if (@($kc).Count -ne @($sc).Count) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        for ($i = 0; $i -lt @($kc).Count; $i++) {
            if (([string]$kc[$i]) -cne ([string]$sc[$i])) {
                return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; takeover = $true }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
    }
}

function Confirm-OrchestrationDispatchReconciliation {
    <#
    .SYNOPSIS
        Reconciliacao externa explicita de recibo pending (F3+R3). Sem efeito.
    .DESCRIPTION
        Converte um recibo `pending` em `settled` a partir de verificacao
        externa do chamador autorizado (que apurou por fora se o efeito
        ocorreu). Exige Authorization admitida viva; nunca invoca o
        Executor (0 calls por construcao). Falha ao persistir e erro
        explicito, nunca silencioso. Nunca lanca.

        R3: a Authorization e conferida contra a identidade persistida no
        recibo sob lock (goal_id/owner/generation iguais ao despacho
        original). goal_id divergente (cross-goal) sempre recusa. SUCESSO
        (Outcome.ok=$true) so e registrado com prova vinculada
        kernel-side (worker_result persistido no kernel com status/refs
        iguais ao declarado + evidencia vinculada a task/key do recibo);
        booleans declarados no Outcome nunca sao
        prova, e outcome inventado e recusado. FALHA externa apurada
        (Outcome.ok=$false) pode liquidar como falha, sem alegar sucesso.

        Reconciliacao apos takeover: um novo owner (generation maior, com
        autorizacao viva do goal atual) pode reconciliar SOMENTE com prova
        kernel-side + autorizacao viva; sem prova, a divergencia de
        identidade recusa. O reconciliador fica registrado no recibo
        (reconciled_by/reconciled_generation).
    #>
    [CmdletBinding()]
    param(
        [string]$IdempotencyKey = '',
        $Outcome = $null,
        $Authorization = $null,
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$EvidenceStoreDir = '',
        [int]$LockTimeoutMs = 60000
    )
    try {
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-idempotency-key' -ExecutorCalls 0)
        }
        if ($null -eq $Outcome) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'outcome-missing' -ExecutorCalls 0)
        }
        $outOk = Get-NDValue $Outcome 'ok' $null
        if (($null -eq $outOk) -or ($outOk -isnot [bool])) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'outcome-invalid' -ExecutorCalls 0)
        }
        $outWorker = Get-NDValue $Outcome 'worker_result' $null
        if ([bool]$outOk) {
            # R3: sucesso exige worker_result presente com forma valida;
            # a prova kernel-side vem depois, sob lock, contra o recibo.
            if ($null -eq $outWorker) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-outcome-shape' -ExecutorCalls 0)
            }
            $shape = Test-OrchestrationDispatchResultShape -Result $outWorker
            if (-not [bool](Get-NDValue $shape 'ok' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-outcome-shape' -ExecutorCalls 0)
            }
        }
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -ExecutorCalls 0)
        }
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -ExecutorCalls 0)
        }
        $lock = Open-NDReceiptLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'lock-busy' -Admitted $true -ExecutorCalls 0)
        }
        try {
            $existing = Read-NDReceipt -Dir $dir -Key $key
            if ($null -eq $existing) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-not-found' -Admitted $true -ExecutorCalls 0)
            }
            if ([string](Get-NDValue $existing 'phase' '') -ceq 'settled') {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'already-settled' -Admitted $true -ExecutorCalls 0)
            }
            if ([string](Get-NDValue $existing 'phase' '') -cne 'pending') {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-invalid' -Admitted $true -ExecutorCalls 0)
            }
            # R3: identidade do recibo contra a Authorization viva.
            $recGoal = ([string](Get-NDValue $existing 'goal_id' '')).Trim()
            $authGoal = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($recGoal) -or ($recGoal -cne $authGoal)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'reconcile-identity-mismatch' -Admitted $true -ExecutorCalls 0)
            }
            $recOwner = ([string](Get-NDValue $existing 'owner' '')).Trim()
            $recGen = [long](Get-NDValue $existing 'ownership_generation' 0)
            $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
            $authGen = [long](Get-NDValue $Authorization 'generation' 0)
            $takeover = (($recOwner -cne $authOwner) -or ($recGen -ne $authGen))
            $recTask = ([string](Get-NDValue $existing 'task_id' ''))
            $recRev = [long](Get-NDValue $existing 'task_expected_revision' 0)
            $fp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
            $wOut = $null
            if ($null -ne $outWorker) {
                $wOut = [pscustomobject][ordered]@{
                    status = ([string](Get-NDValue $outWorker 'status' ''))
                    claimed_evidence = [string[]]@((Get-NDValue $outWorker 'claimed_evidence' @()))
                }
            }
            if ([bool]$outOk) {
                # R3 + FIX3-S1: sucesso so com prova kernel-side VINCULADA;
                # vale para o owner original e para takeover com
                # autorizacao viva (admitida acima). Sem prova, recusa -
                # inclusive quando a identidade diverge (takeover sem
                # prova). O recibo settled persiste os valores lidos do
                # kernel pela prova, nunca copia o declarado sem
                # comparacao campo a campo.
                $evId = ([string](Get-NDValue $Outcome 'evidence_id' '')).Trim().ToLowerInvariant()
                $proof = Test-NDReconcileKernelProof -TaskId $recTask -ExpectedRevision $recRev -EvidenceId $evId -TasksDir $TasksDir -FlagsPath $FlagsPath -EvidenceStoreDir $EvidenceStoreDir -RepoRoot $RepoRoot -DeclaredStatus ([string](Get-NDValue $outWorker 'status' '')) -DeclaredClaimedEvidence @((Get-NDValue $outWorker 'claimed_evidence' @())) -IdempotencyKey $key -IntentFingerprint $fp
                if (-not [bool](Get-NDValue $proof 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $proof 'reason' 'reconcile-unverifiable')) -Admitted $true -ExecutorCalls 0)
                }
                $wOut = [pscustomobject][ordered]@{
                    status = ([string](Get-NDValue $proof 'worker_status' ''))
                    claimed_evidence = [string[]]@((Get-NDValue $proof 'worker_claimed_evidence' @()))
                }
                $settled = [ordered]@{
                    schema_version = 1; idempotency_key = $key; phase = 'settled'
                    ok = $true; reason = ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally'))
                    task_id = $recTask
                    agent = ([string](Get-NDValue $existing 'agent' ''))
                    owner = $recOwner
                    goal_id = $recGoal
                    ownership_generation = $recGen
                    task_expected_revision = $recRev
                    intent_fingerprint = $fp
                    reconciled = $true
                    reconciled_by = $authOwner
                    reconciled_generation = $authGen
                    worker_result = $wOut
                    kernel_ok = $true
                    kernel_reason = 'reconciled-kernel-verified'
                    evidence_created = $true
                    evidence_id = $evId
                    settled_at = ([DateTime]::UtcNow.ToString('o'))
                }
                if (-not (Write-NDReceipt -Dir $dir -Receipt $settled)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-write-failed' -Admitted $true -ExecutorCalls 0)
                }
                return (New-NDDispatchEnvelope -Ok $true -Reason ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally')) -Admitted $true -Reconciled $true -ExecutorCalls 0 -WorkerResult $wOut -KernelOk $true -KernelReason 'reconciled-kernel-verified' -EvidenceCreated $true -EvidenceId $evId)
            }
            $settled = [ordered]@{
                schema_version = 1; idempotency_key = $key; phase = 'settled'
                ok = $false; reason = ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally'))
                task_id = $recTask
                agent = ([string](Get-NDValue $existing 'agent' ''))
                owner = $recOwner
                goal_id = $recGoal
                ownership_generation = $recGen
                task_expected_revision = $recRev
                intent_fingerprint = $fp
                reconciled = $true
                reconciled_by = $authOwner
                reconciled_generation = $authGen
                worker_result = $wOut
                kernel_ok = $false
                kernel_reason = ([string](Get-NDValue $Outcome 'kernel_reason' 'reconciled-external-failure'))
                evidence_created = [bool](Get-NDValue $Outcome 'evidence_created' $false)
                evidence_id = ([string](Get-NDValue $Outcome 'evidence_id' ''))
                settled_at = ([DateTime]::UtcNow.ToString('o'))
            }
            if (-not (Write-NDReceipt -Dir $dir -Receipt $settled)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-write-failed' -Admitted $true -ExecutorCalls 0)
            }
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally')) -Admitted $true -Reconciled $true -ExecutorCalls 0 -WorkerResult $wOut -KernelOk $false -KernelReason ([string](Get-NDValue $Outcome 'kernel_reason' 'reconciled-external-failure')) -EvidenceCreated ([bool](Get-NDValue $Outcome 'evidence_created' $false)) -EvidenceId ([string](Get-NDValue $Outcome 'evidence_id' '')))
        }
        finally { try { $lock.Dispose() } catch { } }
    }
    catch {
        return (New-NDDispatchEnvelope -Ok $false -Reason 'reconcile-internal-error' -ExecutorCalls 0)
    }
}

function New-NDDispatchEnvelope {
    param([bool]$Ok = $false, [string]$Reason = '', [bool]$Admitted = $false, [bool]$Duplicate = $false, [bool]$Reconciled = $false, [int]$ExecutorCalls = 0, $Intent = $null, $WorkerResult = $null, [bool]$KernelOk = $false, [string]$KernelReason = '', [bool]$EvidenceCreated = $false, [string]$EvidenceId = '')
    return [pscustomobject][ordered]@{
        ok              = [bool]$Ok
        reason          = ([string]$Reason)
        admitted        = [bool]$Admitted
        duplicate       = [bool]$Duplicate
        reconciled      = [bool]$Reconciled
        executor_calls  = [int]$ExecutorCalls
        intent          = $Intent
        worker_result   = $WorkerResult
        kernel_ok       = [bool]$KernelOk
        kernel_reason   = ([string]$KernelReason)
        evidence_created = [bool]$EvidenceCreated
        evidence_id     = ([string]$EvidenceId)
    }
}

function Invoke-OrchestrationNativeDispatch {
    <#
    .SYNOPSIS
        Despacha UM worker via Executor injetado, com recibo idempotente.
    .DESCRIPTION
        Ordem fixa: (a) autorizacao -> (b) admissao viva do kernel (F1:
        task existe e nao-terminal, pertence ao goal, revisoes/fencing/
        grants conferem; divergencia recusa com 0 calls) -> (c) lock do
        recibo -> (d) vinculo de Intent (F7: mesma key com fingerprint
        distinto = colisao, sem reuso e sem efeito) -> (e) pending
        ambiguo (F3: sem replay automatico; exige reconciliacao externa
        ou flag external_idempotent com prova) -> (f) recibo pending ->
        (g) fencing pos-lock (F2: releitura IMEDIATA antes do efeito) ->
        (h) Executor UMA vez (unico ponto de efeito externo) ->
        (i) validacao de forma -> (j) evidence row -> (k) kernel ->
        (l) recibo settled (falha de persistencia = erro explicito).
        O lock de recibo e mantido durante todo o despacho. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $Intent = $null,
        $Executor = $null,
        $Authorization = $null,
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000
    )
    try {
        $realIntent = Get-NDValue $Intent 'intent' $null
        if ($null -eq $realIntent) { $realIntent = $Intent }
        $check = New-OrchestrationDispatchIntent `
            -TaskId ([string](Get-NDValue $realIntent 'task_id' '')) `
            -TaskExpectedRevision ([long](Get-NDValue $realIntent 'task_expected_revision' 0)) `
            -Agent ([string](Get-NDValue $realIntent 'agent' '')) `
            -PromptHash ([string](Get-NDValue $realIntent 'prompt_hash' '')) `
            -Scope @((Get-NDValue $realIntent 'scope' @())) `
            -AcceptanceCriteria @((Get-NDValue $realIntent 'acceptance_criteria' @())) `
            -IdempotencyKey ([string](Get-NDValue $realIntent 'idempotency_key' '')) `
            -Owner ([string](Get-NDValue $realIntent 'owner' '')) `
            -OwnershipGeneration ([long](Get-NDValue $realIntent 'ownership_generation' 0)) `
            -BaseRevision ([string](Get-NDValue $realIntent 'base_revision' '')) `
            -ExternalIdempotent ([bool](Get-NDValue $realIntent 'external_idempotent' $false)) `
            -ExternalIdempotencyProof ([string](Get-NDValue $realIntent 'external_idempotency_proof' ''))
        if (-not [bool](Get-NDValue $check 'ok' $false)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $check 'reason' 'invalid-intent')))
        }
        $intent = Get-NDValue $check 'intent' $null
        $key = ([string](Get-NDValue $intent 'idempotency_key' '')).Trim().ToLowerInvariant()
        # R3: identidade completa do despacho, persistida em todo recibo
        # (pending e settled) para vincular reconciliacao a goal/task/
        # owner/generation exatos e permitir prova kernel-side posterior.
        $ndGoalId = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $ndOwnerGen = [long](Get-NDValue $intent 'ownership_generation' 0)
        $ndTaskRev = [long](Get-NDValue $intent 'task_expected_revision' 0)
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
        }
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -Intent $intent -ExecutorCalls 0)
        }
        if (($null -eq $Executor) -or ($Executor -isnot [scriptblock])) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'executor-required' -Admitted $true -Intent $intent -ExecutorCalls 0)
        }
        $fingerprint = Get-NDIntentFingerprint -Intent $intent
        if ([string]::IsNullOrWhiteSpace($fingerprint)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'intent-fingerprint-failed' -Admitted $true -Intent $intent -ExecutorCalls 0)
        }
        $lock = Open-NDReceiptLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'lock-busy' -Admitted $true -Intent $intent -ExecutorCalls 0)
        }
        try {
            $existing = Read-NDReceipt -Dir $dir -Key $key
            if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'settled')) {
                $storedFp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
                if ([string]::IsNullOrWhiteSpace($storedFp) -or ($storedFp -cne $fingerprint)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'idempotency-key-collision' -Admitted $true -Intent $intent -ExecutorCalls 0)
                }
                # FIX3-S2: antes de devolver o resultado settled, vincula
                # a Authorization a identidade persistida no recibo. A
                # recusa nao devolve conteudo do recibo (sem oracle).
                $dupId = Test-NDDuplicateReadIdentity -Receipt $existing -Authorization $Authorization -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -RepoRoot $RepoRoot
                if (-not [bool](Get-NDValue $dupId 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'duplicate-identity-mismatch' -Admitted $true -ExecutorCalls 0 -Intent $intent)
                }
                $dupReason = 'idempotent-duplicate'
                if ([bool](Get-NDValue $dupId 'takeover' $false)) { $dupReason = 'idempotent-duplicate-takeover' }
                return (New-NDDispatchEnvelope -Ok ([bool](Get-NDValue $existing 'ok' $false)) -Reason $dupReason -Admitted $true -Duplicate $true -ExecutorCalls 0 -Intent $intent -WorkerResult (Get-NDValue $existing 'worker_result' $null) -KernelOk ([bool](Get-NDValue $existing 'kernel_ok' $false)) -KernelReason ([string](Get-NDValue $existing 'kernel_reason' '')) -EvidenceCreated ([bool](Get-NDValue $existing 'evidence_created' $false)) -EvidenceId ([string](Get-NDValue $existing 'evidence_id' '')))
            }
            $reconciled = $false
            if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'pending')) {
                $storedFp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
                if ([string]::IsNullOrWhiteSpace($storedFp) -or ($storedFp -cne $fingerprint)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'idempotency-key-collision' -Admitted $true -Intent $intent -ExecutorCalls 0)
                }
                # R2: replay de pending consulta a declaracao ORIGINAL
                # persistida no recibo, nao a do novo Intent. Upgrade de
                # idempotencia via novo Intent (adicionar
                # external_idempotent/proof) muda o fingerprint e cai em
                # colisao acima; aqui, recibo original sem a declaracao
                # nunca autoriza replay so porque o reenvio declara.
                $storedExt = [bool](Get-NDValue $existing 'external_idempotent' $false)
                $newExt = [bool](Get-NDValue $intent 'external_idempotent' $false)
                if ((-not $storedExt) -or (-not $newExt)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'pending-ambiguous' -Admitted $true -Intent $intent -ExecutorCalls 0)
                }
                $reconciled = $true
            }
            # F1: admissao viva ANTES de qualquer efeito novo. Recibos
            # settled com fingerprint igual retornam acima apos vinculo
            # de identidade com o recibo (FIX3-S2; nenhum efeito novo, a
            # revisao da task avancou de proposito no primeiro dispatch).
            # Replay de pending e efeito novo e passa pela admissao.
            $liveGoal = $null
            try {
                $gidLive = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
                $gslot = Get-OrchestrationGoal -GoalId $gidLive -StoreDir $GoalStoreDir
                if (($null -ne $gslot) -and [bool](Get-NDValue $gslot 'ok' $false)) {
                    $liveGoal = Get-NDValue $gslot 'goal' $null
                }
            }
            catch { $liveGoal = $null }
            $admit = Test-NDLiveTaskAdmission -Intent $intent -Authorization $Authorization -Goal $liveGoal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $admit 'ok' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $admit 'reason' 'admission-denied')) -Admitted $true -Reconciled $reconciled -Intent $intent -ExecutorCalls 0)
            }
            $pending = [ordered]@{
                schema_version  = 1
                idempotency_key = $key
                phase           = 'pending'
                task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                agent           = ([string](Get-NDValue $intent 'agent' ''))
                owner           = ([string](Get-NDValue $intent 'owner' ''))
                goal_id         = $ndGoalId
                ownership_generation = $ndOwnerGen
                task_expected_revision = $ndTaskRev
                intent_fingerprint = $fingerprint
                external_idempotent = [bool](Get-NDValue $intent 'external_idempotent' $false)
                reconciled      = [bool]$reconciled
                created_at      = ([DateTime]::UtcNow.ToString('o'))
            }
            if (-not (Write-NDReceipt -Dir $dir -Receipt $pending)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-write-failed' -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            $post = Test-NDPostLockFencing -GoalId ([string](Get-NDValue $Authorization 'goal_id' '')) -Owner ([string](Get-NDValue $Authorization 'owner' '')) -Generation ([long](Get-NDValue $Authorization 'generation' 0)) -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $post 'ok' $false)) {
                $postWhy = ([string](Get-NDValue $post 'reason' 'post-lock-fencing-changed'))
                $refused = [ordered]@{
                    schema_version  = 1; idempotency_key = $key; phase = 'settled'
                    ok              = $false; reason = $postWhy
                    task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                    agent           = ([string](Get-NDValue $intent 'agent' ''))
                    owner           = ([string](Get-NDValue $intent 'owner' ''))
                    goal_id         = $ndGoalId
                    ownership_generation = $ndOwnerGen
                    task_expected_revision = $ndTaskRev
                    intent_fingerprint = $fingerprint
                    reconciled      = [bool]$reconciled
                    worker_result   = $null; kernel_ok = $false; kernel_reason = $postWhy
                    evidence_created = $false; evidence_id = ''
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                if (-not (Write-NDReceipt -Dir $dir -Receipt $refused)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-write-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
                }
                return (New-NDDispatchEnvelope -Ok $false -Reason $postWhy -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
            }
            $calls = 0
            $rawResult = $null
            try {
                $calls = 1
                $rawResult = & $Executor $intent
            }
            catch {
                $failed = [ordered]@{
                    schema_version  = 1; idempotency_key = $key; phase = 'settled'
                    ok              = $false; reason = 'executor-failed'
                    task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                    agent           = ([string](Get-NDValue $intent 'agent' ''))
                    owner           = ([string](Get-NDValue $intent 'owner' ''))
                    goal_id         = $ndGoalId
                    ownership_generation = $ndOwnerGen
                    task_expected_revision = $ndTaskRev
                    intent_fingerprint = $fingerprint
                    reconciled      = [bool]$reconciled
                    worker_result   = $null; kernel_ok = $false; kernel_reason = 'executor-failed'
                    evidence_created = $false; evidence_id = ''
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                if (-not (Write-NDReceipt -Dir $dir -Receipt $failed)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-persist-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -KernelReason 'executor-failed')
                }
                return (New-NDDispatchEnvelope -Ok $false -Reason 'executor-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent)
            }
            $shape = Test-OrchestrationDispatchResultShape -Result $rawResult
            if (-not [bool](Get-NDValue $shape 'ok' $false)) {
                $bad = [ordered]@{
                    schema_version  = 1; idempotency_key = $key; phase = 'settled'
                    ok              = $false; reason = ([string](Get-NDValue $shape 'reason' 'invalid-result'))
                    task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                    agent           = ([string](Get-NDValue $intent 'agent' ''))
                    owner           = ([string](Get-NDValue $intent 'owner' ''))
                    goal_id         = $ndGoalId
                    ownership_generation = $ndOwnerGen
                    task_expected_revision = $ndTaskRev
                    intent_fingerprint = $fingerprint
                    reconciled      = [bool]$reconciled
                    worker_result   = $null; kernel_ok = $false; kernel_reason = 'result-shape-invalid'
                    evidence_created = $false; evidence_id = ''
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                if (-not (Write-NDReceipt -Dir $dir -Receipt $bad)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-persist-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -KernelReason 'result-shape-invalid')
                }
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $shape 'reason' 'invalid-result')) -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -KernelReason 'result-shape-invalid')
            }
            $status = ([string](Get-NDValue $shape 'status' ''))
            $claimed = [string[]]@((Get-NDValue $shape 'claimed_evidence' @()))
            $workerOut = [pscustomobject][ordered]@{ status = $status; claimed_evidence = $claimed }
            $evCreated = $false
            $evId = ''
            try {
                $evCmd = Get-Command New-OrchestrationEvidenceRecord -ErrorAction SilentlyContinue
                $evDirCmd = Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue
                if (($null -ne $evCmd) -and ($null -ne $evDirCmd)) {
                    $evDir = ([string]$EvidenceStoreDir).Trim()
                    if ([string]::IsNullOrWhiteSpace($evDir)) {
                        $evDir = Get-OrchestrationEvidenceDefaultStoreDir
                    }
                    if (-not [string]::IsNullOrWhiteSpace($evDir)) {
                        $agentName = ([string](Get-NDValue $intent 'agent' ''))
                        $evInput = [ordered]@{
                            task_id = ([string](Get-NDValue $intent 'task_id' ''))
                            run_id  = $key
                            worker_id = $agentName
                            provenance = @{ created_by = $agentName; kernel_task_ref = ([string](Get-NDValue $intent 'task_id' '')) }
                            base_revision = ([string](Get-NDValue $intent 'base_revision' ''))
                            criteria_hash = (Get-NativeDispatchHash32 (($claimed -join ',')))
                            source_fingerprints = @{ 'dispatch-intent' = $key }
                            diff_hash = ''
                            scope = @((Get-NDValue $intent 'scope' @()))
                            command = 'native-dispatch'
                            environment = @{ runtime = 'native-dispatch'; version = '1' }
                            result = @{ summary = ('worker:' + $status); raw_ref = '' }
                            assumptions = @()
                            invalidation_conditions = @(
                                @{ type = 'base-revision'; require_same = $true }
                            )
                            created_at = ([DateTime]::UtcNow.ToString('o'))
                        }
                        $evSlot = New-OrchestrationEvidenceRecord -Evidence $evInput -StoreDir $evDir
                        if (($null -ne $evSlot) -and [bool](Get-NDValue $evSlot 'created' $false) -and ($null -ne (Get-NDValue $evSlot 'record' $null))) {
                            $evCreated = $true
                            $evId = ([string](Get-NDValue (Get-NDValue $evSlot 'record' $null) 'evidence_id' ''))
                        }
                    }
                }
            }
            catch { $evCreated = $false; $evId = '' }
            $kOk = $false
            $kWhy = 'kernel-unavailable'
            try {
                $kCmd = Get-Command Set-OrchestrationTaskWorkerResult -ErrorAction SilentlyContinue
                if ($null -ne $kCmd) {
                    $producedBy = ([string](Get-NDValue $intent 'agent' ''))
                    $kSlot = Set-OrchestrationTaskWorkerResult `
                        -TaskId ([string](Get-NDValue $intent 'task_id' '')) `
                        -Status $status `
                        -ClaimedEvidence $claimed `
                        -ProducedBy $producedBy `
                        -ExpectedRevision ([long](Get-NDValue $intent 'task_expected_revision' 0)) `
                        -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
                    if (($null -ne $kSlot) -and [bool](Get-NDValue $kSlot 'ok' $false)) {
                        $kOk = $true; $kWhy = ''
                    }
                    else {
                        $kWhy = ([string](Get-NDValue $kSlot 'error' 'kernel-refused'))
                        if ([string]::IsNullOrWhiteSpace($kWhy)) { $kWhy = 'kernel-refused' }
                    }
                }
            }
            catch { $kOk = $false; $kWhy = 'kernel-failed' }
            $settledOk = ([bool]$kOk)
            $settledReason = ''
            if (-not $settledOk) { $settledReason = ('kernel:' + $kWhy) }
            $settled = [ordered]@{
                schema_version  = 1; idempotency_key = $key; phase = 'settled'
                ok              = [bool]$settledOk; reason = $settledReason
                task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                agent           = ([string](Get-NDValue $intent 'agent' ''))
                owner           = ([string](Get-NDValue $intent 'owner' ''))
                goal_id         = $ndGoalId
                ownership_generation = $ndOwnerGen
                task_expected_revision = $ndTaskRev
                intent_fingerprint = $fingerprint
                reconciled      = [bool]$reconciled
                worker_result   = @{ status = $status; claimed_evidence = @($claimed) }
                kernel_ok       = [bool]$kOk; kernel_reason = $kWhy
                evidence_created = [bool]$evCreated; evidence_id = $evId
                settled_at      = ([DateTime]::UtcNow.ToString('o'))
            }
            if (-not (Write-NDReceipt -Dir $dir -Receipt $settled)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-persist-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
            }
            return (New-NDDispatchEnvelope -Ok $settledOk -Reason $settledReason -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
        }
        finally { try { $lock.Dispose() } catch { } }
    }
    catch {
        return (New-NDDispatchEnvelope -Ok $false -Reason 'dispatch-internal-error')
    }
}
