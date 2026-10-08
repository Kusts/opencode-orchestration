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
    invocado UMA vez e somente apos autorizacao admitida + recibo
    persistido. `-TestCallback` nunca e prova de producao.

    Idempotencia: recibo `<ReceiptDir>/<idempotency_key>.json` escrito
    como `pending` ANTES do Executor e atualizado para `settled` depois.
    Re-dispatch da mesma key retorna o recibo existente sem re-executar.
    Crash entre recibo e execucao = recibo pending -> reconciliacao segura
    (re-executa com a mesma key; o lock de recibo serializa tentativas
    concorrentes, nunca ha duplo efeito externo sem reconciliacao).

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
        [string]$BaseRevision = ''
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
        Ordem fixa: (a) autorizacao -> (b) recibo pending -> (c) Executor UMA
        vez (unico ponto de efeito externo) -> (d) validacao de forma ->
        (e) evidence row -> (f) kernel. O lock de recibo e mantido durante
        todo o despacho para serializar tentativas concorrentes. Crash entre
        (b) e (c) deixa recibo pending: o proximo dispatch da mesma key
        reconcilia (re-executa com a mesma key, nunca duplica sem
        reconciliacao). Nunca lanca.
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
            -BaseRevision ([string](Get-NDValue $realIntent 'base_revision' ''))
        if (-not [bool](Get-NDValue $check 'ok' $false)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $check 'reason' 'invalid-intent')))
        }
        $intent = Get-NDValue $check 'intent' $null
        $key = ([string](Get-NDValue $intent 'idempotency_key' '')).Trim().ToLowerInvariant()
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
        $lock = Open-NDReceiptLock -Dir $dir -LockTimeoutMs $LockTimeoutMs
        if ($null -eq $lock) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'lock-busy' -Admitted $true -Intent $intent -ExecutorCalls 0)
        }
        try {
            $existing = Read-NDReceipt -Dir $dir -Key $key
            if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'settled')) {
                return (New-NDDispatchEnvelope -Ok ([bool](Get-NDValue $existing 'ok' $false)) -Reason 'idempotent-duplicate' -Admitted $true -Duplicate $true -ExecutorCalls 0 -Intent $intent -WorkerResult (Get-NDValue $existing 'worker_result' $null) -KernelOk ([bool](Get-NDValue $existing 'kernel_ok' $false)) -KernelReason ([string](Get-NDValue $existing 'kernel_reason' '')) -EvidenceCreated ([bool](Get-NDValue $existing 'evidence_created' $false)) -EvidenceId ([string](Get-NDValue $existing 'evidence_id' '')))
            }
            $reconciled = $false
            if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'pending')) {
                $reconciled = $true
            }
            $pending = [ordered]@{
                schema_version  = 1
                idempotency_key = $key
                phase           = 'pending'
                task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                agent           = ([string](Get-NDValue $intent 'agent' ''))
                owner           = ([string](Get-NDValue $intent 'owner' ''))
                reconciled      = [bool]$reconciled
                created_at      = ([DateTime]::UtcNow.ToString('o'))
            }
            if (-not (Write-NDReceipt -Dir $dir -Receipt $pending)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-write-failed' -Admitted $true -Intent $intent -ExecutorCalls 0)
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
                    reconciled      = [bool]$reconciled
                    worker_result   = $null; kernel_ok = $false; kernel_reason = 'executor-failed'
                    evidence_created = $false; evidence_id = ''
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                try { [void](Write-NDReceipt -Dir $dir -Receipt $failed) } catch { }
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
                    reconciled      = [bool]$reconciled
                    worker_result   = $null; kernel_ok = $false; kernel_reason = 'result-shape-invalid'
                    evidence_created = $false; evidence_id = ''
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                try { [void](Write-NDReceipt -Dir $dir -Receipt $bad) } catch { }
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
                reconciled      = [bool]$reconciled
                worker_result   = @{ status = $status; claimed_evidence = @($claimed) }
                kernel_ok       = [bool]$kOk; kernel_reason = $kWhy
                evidence_created = [bool]$evCreated; evidence_id = $evId
                settled_at      = ([DateTime]::UtcNow.ToString('o'))
            }
            try { [void](Write-NDReceipt -Dir $dir -Receipt $settled) } catch { }
            return (New-NDDispatchEnvelope -Ok $settledOk -Reason $settledReason -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
        }
        finally { try { $lock.Dispose() } catch { } }
    }
    catch {
        return (New-NDDispatchEnvelope -Ok $false -Reason 'dispatch-internal-error')
    }
}
