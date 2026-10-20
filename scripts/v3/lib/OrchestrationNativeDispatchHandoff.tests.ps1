<#!
.SYNOPSIS
    Tests for the PR-A native handoff slice of lib/OrchestrationNativeDispatch.ps1
    (durable PREPARE + one-use pre-effect CLAIM).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.

    Scope of this slice (PLANNER-NATIVE-HANDOFF-v0.1.2, PR-A):
      * PREPARE persists a durable prepared state under the EXISTING receipt
        lock and namespace, returning a compact opaque reference. It NEVER
        invokes an Executor and NEVER runs a second effect.
      * CLAIM consumes a prepared receipt exactly once, revalidating live
        authorization/ownership/task state, and atomically transitions to the
        pre-effect uncertain/claimed phase BEFORE returning admitted.
      * The legacy synchronous Invoke-OrchestrationNativeDispatch contract is
        unchanged: prepared/claimed receipts never reach the legacy Executor
        path (refused as 'receipt-phase-unknown' with 0 executor calls).

    Every expectation asserts executor_calls = 0 AND a spy counter at 0:
    no worker is spawned anywhere in this suite.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')

$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Assert-HF {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Skip-HF {
    param([string]$Name)
    Write-Host ('[SKIP] ' + $Name)
    $script:skipped++
}


try {
    $script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndhandoff-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempRoot -Force | Out-Null
    # Contador compartilhado por referencia: `GetNewClosure()` copia o escopo,
    # entao um `\$script:contador++` dentro do closure escreveria numa copia
    # e o teste nunca veria a chamada. Hashtable e mutado in place.
    $script:spyState = @{ calls = 0 }
    $goalDir = Join-Path $script:tempRoot 'goals'
    $receiptDir = Join-Path $script:tempRoot 'receipts'
    $evDir = Join-Path $script:tempRoot 'evidence'
    $tasksDir = Join-Path $script:tempRoot 'tasks'
    $flagsPath = Join-Path $script:tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    # ---------- fixture: ACTIVE goal + ownership + kernel task ----------
    $g = New-OrchestrationGoal -GoalId 'hf-goal-1' -Objective 'handoff honesto' -Criteria @('criterio-a', 'criterio-b') -StoreDir $goalDir
    Assert-HF ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
    $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
    Assert-HF ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
    $own = Acquire-OrchestrationGoalOwnership -GoalId 'hf-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
    $gen = [long]$own.ownership['generation']
    $script:hfGen = [long]$own.ownership['generation']

    $authOk = @{ explicit_allow = $true; goal_id = 'hf-goal-1'; owner = 'planner-1'; generation = $script:hfGen; source = 'planner' }
    $authNoAllow = @{ explicit_allow = $false; goal_id = 'hf-goal-1'; owner = 'planner-1'; generation = $script:hfGen; source = 'planner' }
    $authCb = @{ explicit_allow = $true; goal_id = 'hf-goal-1'; owner = 'planner-1'; generation = $script:hfGen; source = 'test-callback' }
    $authRival = @{ explicit_allow = $true; goal_id = 'hf-goal-1'; owner = 'planner-2'; generation = $script:hfGen; source = 'planner' }
    $authRivalGen = @{ explicit_allow = $true; goal_id = 'hf-goal-1'; owner = 'planner-1'; generation = ($script:hfGen + 7); source = 'planner' }
    $authMissing = @{ goal_id = 'hf-goal-1'; owner = 'planner-1'; generation = $script:hfGen; source = 'planner' }

    $ph = Get-NativeDispatchHash32 'handoff-prompt-material'
    $script:phText = $ph

    function New-HFKernelTask {
        param([string]$Id, [string]$GoalId = 'hf-goal-1', [long]$Gen = 0)
        $g = $Gen
        if ($g -lt 1) { $g = $script:hfGen }
        $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
        Assert-HF ([bool]$c.ok) ('[F] kernel task created ' + $Id) ([string]$c.error)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $goalDir
        $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $g
        Assert-HF ([bool]$add.ok) ('[F] task attached ' + $Id) ([string]$add.reason)
    }

    function New-HFIntent {
        param([string]$Task, [string]$Key, [string]$Agent = 'coder', [string]$Owner = 'planner-1', [long]$Gen = 0, [long]$Rev = 1, [bool]$Ext = $false, [string]$Proof = '')
        $gg = $Gen
        if ($gg -lt 1) { $gg = $script:hfGen }
        return (New-OrchestrationNativeDispatchIntent -TaskId $Task -TaskExpectedRevision $Rev -Agent $Agent -PromptHash $script:phText `
            -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $Key `
            -Owner $Owner -OwnershipGeneration $gg -BaseRevision 'rev-a' -ExternalIdempotent $Ext -ExternalIdempotencyProof $Proof)
    }

    function Get-HFReceiptPath {
        param([string]$GoalId, [string]$Key)
        $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return '' }
        return (Join-Path $sub ($Key + '.json'))
    }


    New-HFKernelTask -Id 'hf-task-1'
    New-HFKernelTask -Id 'hf-task-2'
    New-HFKernelTask -Id 'hf-task-term'
    New-HFKernelTask -Id 'hf-task-legacy'
    New-HFKernelTask -Id 'hf-task-claim'
    New-HFKernelTask -Id 'hf-task-conc'
    New-HFKernelTask -Id 'hf-task-l1'

    # Fixture isolado (goal proprio) para os cenarios de fronteira
    # pre-efeito: mutar o goal compartilhado quebraria o resto da suite.
    function New-HFIsolatedFixture {
        param([string]$Suffix)
        $gid = ('hf-goal-' + $Suffix)
        $tid = ('hf-task-' + $Suffix)
        $gg = New-OrchestrationGoal -GoalId $gid -Objective ('goal isolado ' + $Suffix) -Criteria @('criterio-a') -StoreDir $goalDir
        Assert-HF ([bool]$gg.ok) ('[F] fixture goal created ' + $gid) ([string]$gg.reason)
        $act = Set-OrchestrationGoalState -Goal $gg.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-HF ([bool]$sv.ok) ('[F] fixture goal active ' + $gid) ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId $gid -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-HF ([bool]$own.ok) ('[F] fixture goal owned ' + $gid) ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        New-HFKernelTask -Id $tid -GoalId $gid -Gen $gen
        $auth = @{ explicit_allow = $true; goal_id = $gid; owner = 'planner-1'; generation = $gen; source = 'planner' }
        return [pscustomobject]@{ goal = $gid; task = $tid; gen = $gen; auth = $auth }
    }

    function Set-HFGoalStateLive {
        param([string]$GoalId, [string]$ToState, [long]$Gen)
        $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $goalDir
        if (($null -eq $slot) -or (-not [bool]$slot.ok)) { return $slot }
        return (Set-OrchestrationGoalStatePersisted -GoalId $GoalId -ToState $ToState -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $Gen)
    }

    function Open-HFReceiptLockHeld {
        param([string]$GoalId)
        $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        return ([IO.File]::Open((Join-Path $sub '.dispatch.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
    }

    # Baseline de bytes do log de ativacao: a espera so observa as
    # linhas ANEXADAS depois deste ponto, nunca a linha do baseline
    # anterior (que ja existia antes de o job comecar).
    function Get-HFActivationBaselineBytes {
        param([string]$Dir = '')
        $d = $Dir
        if ([string]::IsNullOrWhiteSpace($d)) { $d = $receiptDir }
        $logPath = Join-Path $d 'activations.jsonl'
        try {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                return [long](([IO.FileInfo]::new($logPath)).Length)
            }
        }
        catch { }
        return [long]0
    }

    # Espera uma NOVA linha de ativacao admitida, ANEXADA depois do
    # baseline em bytes e com IDENTIDADE explicita (goal + owner +
    # admitted=true). A linha so e escrita DEPOIS da checagem de
    # ownership do gate pre-lock, entao ve-la prova que a autorizacao
    # daquele processo passou antes da mutacao seguinte - e exige que a
    # linha seja realmente DAQUELE evento, nao uma sobra anterior.
    function Wait-HFNewAdmittedRow {
        param([string]$Dir, [long]$BaselineBytes = 0, [string]$GoalId = '', [string]$Owner = '', [int]$TimeoutMs = 25000)
        $logPath = Join-Path $Dir 'activations.jsonl'
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ($true) {
            $saw = $false
            try {
                if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                    $len = [long](([IO.FileInfo]::new($logPath)).Length)
                    if ($len -gt $BaselineBytes) {
                        $fs = [IO.FileStream]::new($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                        try {
                            $null = $fs.Seek($BaselineBytes, [IO.SeekOrigin]::Begin)
                            $buf = New-Object byte[] ($len - $BaselineBytes)
                            $got = 0
                            while ($got -lt $buf.Length) {
                                $n = $fs.Read($buf, $got, $buf.Length - $got)
                                if ($n -le 0) { break }
                                $got += $n
                            }
                            $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
                        }
                        finally { try { $fs.Dispose() } catch { } }
                        foreach ($line in @($txt -split "`n")) {
                            $t = ([string]$line).Trim()
                            if ($t -eq '') { continue }
                            $row = $null
                            try { $row = ConvertFrom-Json $t } catch { continue }
                            if ($null -eq $row) { continue }
                            if ((([string](Get-NDValue $row 'goal_id' '')) -ceq $GoalId) -and
                                (([string](Get-NDValue $row 'owner' '')) -ceq $Owner) -and
                                ([bool](Get-NDValue $row 'admitted' $false))) { $saw = $true; break }
                        }
                    }
                }
            }
            catch { }
            if ($saw) { return $true }
            if ([DateTime]::UtcNow -ge $deadline) { return $false }
            Start-Sleep -Milliseconds 100
        }
    }

    # CLAIM em processo separado (job): o lock do recibo e contido pelo
    # teste enquanto o goal e mutado, exatamente o cenario "takeover /
    # expiracao / terminalizacao enquanto o pretendente espera o lock".
    function Invoke-HFClaimInJob {
        param([string]$Key, $Authorization, [string]$PreparedFingerprint, [int]$LockTimeoutMs = 30000)
        $lib = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        return (Start-Job -ScriptBlock {
            param($Lib, $Key, $ReceiptDir, $GoalStoreDir, $TasksDir, $FlagsPath, $Session, $Message, $Call, $Fp, $Timeout, $Auth)
            $libDir = Split-Path -Parent $Lib
            . (Join-Path $libDir 'OrchestrationGoalKernel.ps1')
            . (Join-Path $libDir 'OrchestrationEvidenceStore.ps1')
            . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
            . $Lib
            return (Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $Key -Authorization $Auth -SessionId $Session -MessageId $Message -CallId $Call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $Fp -ReceiptDir $ReceiptDir -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath -LockTimeoutMs $Timeout)
        } -ArgumentList @($lib, $Key, $receiptDir, $goalDir, $tasksDir, $flagsPath, $session, $message, $call, $PreparedFingerprint, $LockTimeoutMs, $Authorization))
    }

    # CLAIM em processo separado, com namespace de recibos proprio: usado
    # pelos cenarios de exclusao por task em OUTRO goal (jobs disputam a
    # MESMA reserva via lock de task na raiz).
    function Invoke-HFClaimJobOnRoot {
        param([string]$RootDir, [string]$Key, $Authorization, [string]$PreparedFingerprint, [int]$LockTimeoutMs = 30000)
        $lib = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        return (Start-Job -ScriptBlock {
            param($Lib, $Key, $ReceiptDir, $GoalStoreDir, $TasksDir, $FlagsPath, $Session, $Message, $Call, $Fp, $Timeout, $Auth)
            $libDir = Split-Path -Parent $Lib
            . (Join-Path $libDir 'OrchestrationGoalKernel.ps1')
            . (Join-Path $libDir 'OrchestrationEvidenceStore.ps1')
            . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
            . $Lib
            return (Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $Key -Authorization $Auth -SessionId $Session -MessageId $Message -CallId $Call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $Fp -ReceiptDir $ReceiptDir -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath -LockTimeoutMs $Timeout)
        } -ArgumentList @($lib, $Key, $RootDir, $goalDir, $tasksDir, $flagsPath, $session, $message, $call, $PreparedFingerprint, $LockTimeoutMs, $Authorization))
    }

    # Espera limitada por job: o literal anterior (`-Timeout 90000`)
    # significava 90.000 SEGUNDOS (25h), nao 90s - e, no estouro, o
    # Wait-Job segue sem sinalizar nada e o teste prosseguiria em
    # silencio. O padrao agora e 60s (o dobro do LockTimeoutMs interno de
    # 30s do CLAIM) e o estouro FALHA explicito, sempre com stop/remove
    # no fluxo de limpeza.
    function Receive-HFJob {
        param($Job, [int]$TimeoutSec = 60, [string]$Name = 'job')
        $r = $null
        if ($null -ne $Job) {
            try { $null = Wait-Job -Job $Job -Timeout $TimeoutSec } catch { }
            $state = ''
            try { $state = [string]$Job.State } catch { $state = 'unknown' }
            if ($state -notin @('Completed', 'Failed', 'Stopped')) {
                try { Stop-Job -Job $Job -ErrorAction SilentlyContinue } catch { }
                Assert-HF $false ('[HF-JOB-TIMEOUT] ' + $Name + ' did not finish within ' + [string]$TimeoutSec + 's (stopped forcefully)') ('state=' + $state)
            }
            try { $r = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)[-1] } catch { $r = $null }
            try { Stop-Job -Job $Job -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
        }
        return $r
    }

    $session = 'ses_hf_abc123'
    $message = 'msg_hf_001'
    $call = 'call_hf_001'

    # ---------- P1: PREPARE allow ----------
    $k1 = Get-NativeDispatchHash32 'hf-prepare-allow-1'
    $i1 = New-HFIntent -Task 'hf-task-1' -Key $k1
    $p1 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i1 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$p1.ok) -and ([int]$p1.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 0)) '[P1] prepare admits with 0 executor calls' ([string]$p1.reason)
    Assert-HF (([string]$p1.phase -ceq 'prepared') -and ([string]$p1.reference -cmatch '^[a-f0-9]{32}$')) '[P1] prepared phase + compact opaque reference' ('phase=' + [string]$p1.phase + ' ref=' + [string]$p1.reference)
    $p1Path = Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k1
    Assert-HF (($p1Path -ne '') -and (Test-Path -LiteralPath $p1Path -PathType Leaf)) '[P1] durable prepared receipt persisted on disk' $p1Path
    $p1Raw = $null
    try { $p1Raw = ConvertFrom-Json ([IO.File]::ReadAllText($p1Path, [Text.Encoding]::UTF8)) } catch { $p1Raw = $null }
    Assert-HF ((([string]$p1Raw.phase -ceq 'prepared') -and ([string]$p1Raw.handoff_state -ceq 'PREPARED'))) '[P1] receipt holds phase=prepared and handoff_state=PREPARED' ('phase=' + [string]$p1Raw.phase + ' state=' + [string]$p1Raw.handoff_state)
    Assert-HF (([string]$p1Raw.intent_fingerprint -cne '') -and ([string]$p1Raw.prepared_fingerprint -cne '') -and ([string]$p1Raw.session_id -ceq $session)) '[P1] receipt binds fingerprint + session' ''
    Assert-HF (([string]$p1Raw.prompt_hash -ceq $ph) -and ($null -eq $p1Raw.PSObject.Properties['prompt'])) '[P1] receipt carries prompt_hash only, never prompt text' ''

    # ---------- P2: PREPARE deny - authorization ----------
    $k2 = Get-NativeDispatchHash32 'hf-prepare-deny-auth'
    $i2 = New-HFIntent -Task 'hf-task-1' -Key $k2
    $p2a = Invoke-OrchestrationNativeDispatchPrepare -Intent $i2 -Authorization $authNoAllow -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p2a.ok) -and ([string]$p2a.reason -ceq 'explicit-allow-required') -and ([int]$p2a.executor_calls -eq 0)) '[P2a] missing explicit_allow denies' ([string]$p2a.reason)
    $p2b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i2 -Authorization $authCb -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p2b.ok) -and ([string]$p2b.reason -ceq 'test-callback-never-authorizes-production') -and ([int]$script:spyState.calls -eq 0)) '[P2b] test-callback never authorizes production' ([string]$p2b.reason)
    $p2c = Invoke-OrchestrationNativeDispatchPrepare -Intent $i2 -Authorization $authMissing -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p2c.ok) -and ([string]$p2c.reason -ceq 'explicit-allow-required')) '[P2c] absent explicit_allow denies' ([string]$p2c.reason)
    $p2d = Invoke-OrchestrationNativeDispatchPrepare -Intent $i2 -Authorization $null -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p2d.ok) -and ([string]$p2d.reason -ceq 'authorization-missing')) '[P2d] null authorization denies' ([string]$p2d.reason)
    $p2e = Invoke-OrchestrationNativeDispatchPrepare -Intent $i2 -Authorization $authOk -SessionId '' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p2e.ok) -and ([string]$p2e.reason -ceq 'host-session-invalid') -and ([int]$p2e.executor_calls -eq 0)) '[P2e] empty host session denies before any receipt IO' ([string]$p2e.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k2) -PathType Leaf)) '[P2] no receipt persisted for denied prepares' ''

    # ---------- P3: PREPARE deny - intent shape ----------
    $k3 = Get-NativeDispatchHash32 'hf-prepare-deny-intent'
    $badIntent = New-OrchestrationNativeDispatchIntent -TaskId 'hf-task-1' -TaskExpectedRevision 1 -Agent 'bad agent!!' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $script:hfGen -BaseRevision 'rev-a'
    $p3 = Invoke-OrchestrationNativeDispatchPrepare -Intent $badIntent -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    # Fail-closed: um envelope quebrado nao carrega Intent valido; a
    # revalidacao do PREPARE recusa ja na task, sem efeito.
    Assert-HF ((-not [bool]$p3.ok) -and ([string]$p3.reason -ceq 'invalid-taskid') -and ([int]$p3.executor_calls -eq 0)) '[P3] invalid agent in Intent denies' ([string]$p3.reason)

    # ---------- P4: PREPARE deny - terminal goal ----------
    $gterm = New-OrchestrationGoal -GoalId 'hf-goal-term' -Objective 'goal terminal' -Criteria @('criterio-a') -StoreDir $goalDir
    $gtermAct = Set-OrchestrationGoalState -Goal $gterm.goal -ToState 'ACTIVE'
    $gtermSv = Save-OrchestrationGoal -Goal $gtermAct.goal -StoreDir $goalDir
    $gtermOwn = Acquire-OrchestrationGoalOwnership -GoalId 'hf-goal-term' -OwnerId 'planner-1' -ExpectedRevision ([long]$gtermSv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$gtermOwn.ok) '[F4] terminal-goal fixture owned' ([string]$gtermOwn.reason)
    $gtermGen = [long]$gtermOwn.ownership['generation']
    $authTerm = @{ explicit_allow = $true; goal_id = 'hf-goal-term'; owner = 'planner-1'; generation = $gtermGen; source = 'planner' }
    New-OrchestrationTask -TaskId 'hf-task-gterm' -Objective 'obj gterm' -TaskType 'implementation' -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot | Out-Null
    $gtermSlot = Get-OrchestrationGoal -GoalId 'hf-goal-term' -StoreDir $goalDir
    Add-OrchestrationGoalTaskPersisted -GoalId 'hf-goal-term' -TaskId 'hf-task-gterm' -ExpectedRevision ([long]$gtermSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gtermGen | Out-Null
    $gtermAfter = Get-OrchestrationGoal -GoalId 'hf-goal-term' -StoreDir $goalDir
    $gtermFin = Set-OrchestrationGoalStatePersisted -GoalId 'hf-goal-term' -ToState 'COMPLETED' -ExpectedRevision ([long]$gtermAfter.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gtermGen
    Assert-HF ([bool]$gtermFin.ok) '[F4] terminal-goal fixture moved to COMPLETED' ([string]$gtermFin.reason)
    $k4 = Get-NativeDispatchHash32 'hf-prepare-deny-goalterm'
    $i4 = New-HFIntent -Task 'hf-task-gterm' -Key $k4 -Gen $gtermGen
    $p4 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i4 -Authorization $authTerm -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p4.ok) -and ([string]$p4.reason -ceq 'goal-terminal') -and ([int]$p4.executor_calls -eq 0)) '[P4] terminal goal denies before any effect' ([string]$p4.reason)

    # ---------- P5: PREPARE deny - terminal task ----------
    $ttermSlot = Get-OrchestrationTask -TaskId 'hf-task-term' -TasksDir $tasksDir
    $ttermRev = [int]$ttermSlot.revision
    $tterm = Invoke-OrchestrationTaskTransition -TaskId 'hf-task-term' -ToState 'CANCELLED' -Actor 'planner-1' -ExpectedRevision $ttermRev -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$tterm.ok) '[F5] terminal task fixture cancelled' ([string]$tterm.error)
    $k5 = Get-NativeDispatchHash32 'hf-prepare-deny-taskterm'
    $i5 = New-HFIntent -Task 'hf-task-term' -Key $k5 -Rev $ttermRev
    $p5 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i5 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p5.ok) -and ([string]$p5.reason -ceq 'task-terminal') -and ([int]$p5.executor_calls -eq 0)) '[P5] terminal task denies before any effect' ([string]$p5.reason)

    # ---------- P6: PREPARE deny - stale ownership / revision ----------
    $k6 = Get-NativeDispatchHash32 'hf-prepare-deny-owner'
    $i6 = New-HFIntent -Task 'hf-task-2' -Key $k6
    $p6a = Invoke-OrchestrationNativeDispatchPrepare -Intent $i6 -Authorization $authRival -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p6a.ok) -and ([string]$p6a.reason -like 'ownership-not-held*') -and ([int]$p6a.executor_calls -eq 0)) '[P6a] rival owner denies (ownership not held)' ([string]$p6a.reason)
    $p6b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i6 -Authorization $authRivalGen -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p6b.ok) -and ([string]$p6b.reason -like 'ownership-not-held*') -and ([int]$p6b.executor_calls -eq 0)) '[P6b] stale generation denies (fencing)' ([string]$p6b.reason)
    $k6c = Get-NativeDispatchHash32 'hf-prepare-deny-rev'
    $i6c = New-HFIntent -Task 'hf-task-2' -Key $k6c -Rev 99
    $p6c = Invoke-OrchestrationNativeDispatchPrepare -Intent $i6c -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p6c.ok) -and ([string]$p6c.reason -ceq 'task-revision-mismatch') -and ([int]$p6c.executor_calls -eq 0)) '[P6c] stale expected revision denies' ([string]$p6c.reason)
    $k6d = Get-NativeDispatchHash32 'hf-prepare-deny-scope'
    $i6d = New-OrchestrationNativeDispatchIntent -TaskId 'hf-task-2' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/evil.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $k6d -Owner 'planner-1' -OwnershipGeneration $script:hfGen -BaseRevision 'rev-a'
    $p6d = Invoke-OrchestrationNativeDispatchPrepare -Intent $i6d.intent -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p6d.ok) -and ([string]$p6d.reason -ceq 'scope-not-granted') -and ([int]$p6d.executor_calls -eq 0)) '[P6d] ungranted scope denies' ([string]$p6d.reason)

    # ---------- P7: PREPARE deny - kernel disabled ----------
    $flagsOff = Join-Path $script:tempRoot 'flags-off.json'
    [IO.File]::WriteAllText($flagsOff, '{"task_kernel":{"enabled":false,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    $k7 = Get-NativeDispatchHash32 'hf-prepare-deny-kernel'
    $i7 = New-HFIntent -Task 'hf-task-2' -Key $k7
    $p7 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i7 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsOff
    Assert-HF ((-not [bool]$p7.ok) -and ([string]$p7.reason -ceq 'taskkernel-disabled') -and ([int]$p7.executor_calls -eq 0)) '[P7] kernel OFF denies with 0 executor calls' ([string]$p7.reason)

    # ---------- P8: duplicate PREPARE is idempotent ----------
    $k8 = Get-NativeDispatchHash32 'hf-prepare-idem-1'
    $i8 = New-HFIntent -Task 'hf-task-2' -Key $k8
    $p8a = Invoke-OrchestrationNativeDispatchPrepare -Intent $i8 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$p8a.ok) -and (-not [bool]$p8a.reused)) '[P8a] first prepare is fresh' ([string]$p8a.reason)
    $p8aRawText = [IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k8), [Text.Encoding]::UTF8)
    $p8b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i8 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$p8b.ok) -and ([bool]$p8b.reused) -and ([string]$p8b.reference -ceq [string]$p8a.reference)) '[P8b] identical re-entry is idempotent (same reference)' ('reused=' + [string]$p8b.reused + ' reason=' + [string]$p8b.reason)
    Assert-HF (([string]$p8b.reason -ceq 'prepare-reused')) '[P8b] idempotent re-entry reports prepare-reused' ([string]$p8b.reason)
    $p8bRawText = [IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k8), [Text.Encoding]::UTF8)
    Assert-HF ($p8aRawText -ceq $p8bRawText) '[P8b] idempotent re-entry does not rewrite the receipt' ''
    Assert-HF ([int]$script:spyState.calls -eq 0) '[P8] no executor call across duplicate prepares' ''

    # ---------- P9: key collision / fingerprint mismatch on PREPARE ----------
    $k9 = Get-NativeDispatchHash32 'hf-prepare-collision-1'
    $i9a = New-HFIntent -Task 'hf-task-2' -Key $k9
    $p9a = Invoke-OrchestrationNativeDispatchPrepare -Intent $i9a -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p9a.ok) '[P9] first prepare stored for collision fixture' ([string]$p9a.reason)
    $i9b = New-HFIntent -Task 'hf-task-2' -Key $k9 -Agent 'tester'
    $p9b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i9b -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p9b.ok) -and ([string]$p9b.reason -ceq 'prepare-key-collision') -and ([int]$p9b.executor_calls -eq 0)) '[P9] same key with divergent Intent is a refused collision' ([string]$p9b.reason)
    $p9c = Invoke-OrchestrationNativeDispatchPrepare -Intent $i9a -Authorization $authOk -SessionId 'ses_hf_OTHER' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    # A sessao entra no prepared_fingerprint, entao a divergencia de sessao
    # muda o fingerprint primeiro: a recusa vem como colisao (antes da
    # checagem de sessao). Ambos os caminhos recusam sem efeito.
    Assert-HF ((-not [bool]$p9c.ok) -and (@('prepare-key-collision', 'prepare-session-mismatch') -ccontains [string]$p9c.reason)) '[P9] same key with divergent session is refused' ([string]$p9c.reason)

    # ---------- P10: PREPARE after CLAIM denies ----------
    $k10 = Get-NativeDispatchHash32 'hf-prepare-after-claim-1'
    $i10 = New-HFIntent -Task 'hf-task-2' -Key $k10
    $p10a = Invoke-OrchestrationNativeDispatchPrepare -Intent $i10 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p10a.ok) '[P10] prepared for post-claim fixture' ([string]$p10a.reason)
    $c10 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k10 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p10a.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c10.ok) '[P10] claim consumed the fixture' ([string]$c10.reason)
    $p10b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i10 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p10b.ok) -and ([string]$p10b.reason -ceq 'prepare-already-claimed') -and ([int]$p10b.executor_calls -eq 0)) '[P10] re-prepare of a claimed receipt denies' ([string]$p10b.reason)

    # ---------- P11: PREPARE over a legacy pending receipt conflicts ----------
    $k11 = Get-NativeDispatchHash32 'hf-prepare-legacy-pending'
    $i11 = New-HFIntent -Task 'hf-task-2' -Key $k11
    $i11Fp = Get-NDIntentFingerprint -Intent $i11.intent
    $legacyPending = [ordered]@{ schema_version = 1; idempotency_key = $k11; phase = 'pending'; task_id = 'hf-task-2'; agent = 'coder'; owner = 'planner-1'; goal_id = 'hf-goal-1'; ownership_generation = $script:hfGen; task_expected_revision = 1; intent_fingerprint = $i11Fp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k11), (ConvertTo-Json -InputObject $legacyPending -Compress), [Text.UTF8Encoding]::new($false))
    $p11 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i11 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p11.ok) -and ([string]$p11.reason -ceq 'prepare-phase-conflict') -and ([int]$p11.executor_calls -eq 0)) '[P11] prepare over a legacy pending receipt refuses' ([string]$p11.reason)

    # ---------- C1: CLAIM valid ----------
    $k12 = Get-NativeDispatchHash32 'hf-claim-valid-1'
    $i12 = New-HFIntent -Task 'hf-task-claim' -Key $k12
    $p12 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i12 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p12.ok) '[C1] prepared for valid claim' ([string]$p12.reason)
    $c1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k12 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p12.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$c1.ok) -and ([bool]$c1.claimed) -and ([bool]$c1.admitted) -and ([int]$c1.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 0)) '[C1] valid claim admits with 0 executor calls' ([string]$c1.reason)
    Assert-HF (([string]$c1.phase -ceq 'claimed') -and ([string]$c1.handoff_state -ceq 'DISPATCH_UNCERTAIN')) '[C1] claim transitions to DISPATCH_UNCERTAIN before the effect boundary' ('phase=' + [string]$c1.phase + ' state=' + [string]$c1.handoff_state)
    Assert-HF (([string]$c1.session_id -ceq $session) -and ([string]$c1.message_id -ceq $message) -and ([string]$c1.call_id -ceq $call)) '[C1] claim records host lineage' ''
    Assert-HF (([string]$c1.caller_agent -ceq 'planner') -and ([string]$c1.target_agent -ceq 'coder')) '[C1] claim records caller/target agents' ''
    $c1Path = Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k12
    $c1Raw = $null
    try { $c1Raw = ConvertFrom-Json ([IO.File]::ReadAllText($c1Path, [Text.Encoding]::UTF8)) } catch { $c1Raw = $null }
    Assert-HF (([string]$c1Raw.phase -ceq 'claimed') -and ([string]$c1Raw.handoff_state -ceq 'DISPATCH_UNCERTAIN')) '[C1] durable receipt holds the claimed phase' ('phase=' + [string]$c1Raw.phase)
    Assert-HF (([string]$c1Raw.claim_session_id -ceq $session) -and ([string]$c1Raw.claim_message_id -ceq $message) -and ([string]$c1Raw.claim_call_id -ceq $call)) '[C1] durable receipt holds host lineage' ''
    Assert-HF (([string]$c1Raw.task_id -ceq 'hf-task-claim') -and ([string]$c1Raw.agent -ceq 'coder') -and ([string]$c1Raw.intent_fingerprint -cne '')) '[C1] claimed receipt preserves prepared intent fields' ''

    # ---------- C2: CLAIM duplicate / replay denies ----------
    $c2a = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k12 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p12.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2a.ok) -and ([string]$c2a.reason -ceq 'claim-already-consumed') -and (-not [bool]$c2a.claimed) -and ([int]$c2a.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 0)) '[C2a] identical replay of a consumed claim denies' ([string]$c2a.reason)
    $c2b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k12 -Authorization $authOk -SessionId $session -MessageId 'msg_hf_002' -CallId 'call_hf_002' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p12.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2b.ok) -and ([string]$c2b.reason -ceq 'claim-already-consumed') -and ([int]$c2b.executor_calls -eq 0)) '[C2b] replay with a NEW call identity still denies' ([string]$c2b.reason)
    $c2Raw = ConvertFrom-Json ([IO.File]::ReadAllText($c1Path, [Text.Encoding]::UTF8))
    Assert-HF (([string]$c2Raw.claim_call_id -ceq $call) -and ([string]$c2Raw.phase -ceq 'claimed')) '[C2] refused replays never mutate the consumed receipt' ''

    # ---------- C3g fixture: autorizacao VALIDA de OUTRO goal ----------
    # Um segundo goal, ativo e com ownership propria, da uma autorizacao
    # legitima que NAO e a identidade do preparo: o gate de autorizacao
    # passa e a recusa tem de vir da identidade vinculada ao recibo.
    $gtake = New-OrchestrationGoal -GoalId 'hf-goal-take' -Objective 'goal do pretendente' -Criteria @('criterio-a') -StoreDir $goalDir
    $gtakeAct = Set-OrchestrationGoalState -Goal $gtake.goal -ToState 'ACTIVE'
    $gtakeSv = Save-OrchestrationGoal -Goal $gtakeAct.goal -StoreDir $goalDir
    $gtakeOwn = Acquire-OrchestrationGoalOwnership -GoalId 'hf-goal-take' -OwnerId 'planner-9' -ExpectedRevision ([long]$gtakeSv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$gtakeOwn.ok) '[C3] rival authorization fixture owned' ([string]$gtakeOwn.reason)
    $authTakeover = @{ explicit_allow = $true; goal_id = 'hf-goal-take'; owner = 'planner-9'; generation = [long]$gtakeOwn.ownership['generation']; source = 'planner' }
    # ---------- C3: CLAIM argument / session / task / agent mismatch ----------
    $k13 = Get-NativeDispatchHash32 'hf-claim-mismatch-1'
    $i13 = New-HFIntent -Task 'hf-task-claim' -Key $k13
    $p13 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i13 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p13.ok) '[C3] prepared for mismatch fixture' ([string]$p13.reason)
    $wrongFp = Get-NativeDispatchHash32 'hf-claim-wrong-fingerprint'
    $c3a = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $wrongFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3a.ok) -and ([string]$c3a.reason -ceq 'claim-fingerprint-mismatch') -and ([int]$c3a.executor_calls -eq 0)) '[C3a] divergence between claim and stored argument fingerprint denies' ([string]$c3a.reason)
    $c3b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId 'ses_hf_WRONG' -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3b.ok) -and ([string]$c3b.reason -ceq 'claim-session-mismatch')) '[C3b] wrong session denies' ([string]$c3b.reason)
    $c3c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'tester' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3c.ok) -and ([string]$c3c.reason -ceq 'claim-agent-mismatch')) '[C3c] wrong target agent denies' ([string]$c3c.reason)
    $c3d = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'coder' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3d.ok) -and ([string]$c3d.reason -ceq 'claim-agent-mismatch')) '[C3d] caller equal to target agent denies' ([string]$c3d.reason)
    $c3e = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId $session -MessageId $message -CallId 'bad call id!!' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3e.ok) -and ([string]$c3e.reason -ceq 'host-call-invalid')) '[C3e] malformed call id denies' ([string]$c3e.reason)
    $c3f = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authOk -SessionId $session -MessageId 'bad message!!' -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c3f.ok) -and ([string]$c3f.reason -ceq 'host-message-invalid')) '[C3f] malformed message id denies' ([string]$c3f.reason)
    $c3g = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13 -Authorization $authTakeover -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    # F3/REV5: recibos sao isolados por goal. Uma autorizacao de outro goal
    # resolve o namespace do PROPRIO goal, que nao contem a key: a resposta
    # e claim-not-prepared, generica, igual a de key inexistente. Nao ha
    # oraculo de existencia entre goals e a identidade do preparo nao vaza.
    Assert-HF ((-not [bool]$c3g.ok) -and (@('claim-not-prepared') -ccontains [string]$c3g.reason)) '[C3g] authorization of another goal sees the receipt as absent (isolation)' ([string]$c3g.reason)
    $c3Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k13), [Text.Encoding]::UTF8))
    Assert-HF (([string]$c3Raw.phase -ceq 'prepared')) '[C3] all refused claims leave the receipt prepared' ('phase=' + [string]$c3Raw.phase)

    # ---------- C4: CLAIM over legacy phases and absent receipt ----------
    $k14 = Get-NativeDispatchHash32 'hf-claim-legacy-pending'
    $i14 = New-HFIntent -Task 'hf-task-2' -Key $k14
    $i14Fp = Get-NDIntentFingerprint -Intent $i14.intent
    $i14Path = Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k14
    [IO.File]::WriteAllText($i14Path, (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $k14; phase = 'pending'; task_id = 'hf-task-2'; agent = 'coder'; owner = 'planner-1'; goal_id = 'hf-goal-1'; ownership_generation = $script:hfGen; task_expected_revision = 1; intent_fingerprint = $i14Fp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $c4 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k14 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $wrongFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c4.ok) -and ([string]$c4.reason -ceq 'claim-phase-conflict') -and ([int]$c4.executor_calls -eq 0)) '[C4a] claim over a legacy pending receipt conflicts' ([string]$c4.reason)
    $k15 = Get-NativeDispatchHash32 'hf-claim-legacy-settled'
    $i15Path = Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k15
    [IO.File]::WriteAllText($i15Path, (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $k15; phase = 'settled'; task_id = 'hf-task-2'; agent = 'coder'; owner = 'planner-1'; goal_id = 'hf-goal-1'; ownership_generation = $script:hfGen; task_expected_revision = 1; intent_fingerprint = $i14Fp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $c4b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k15 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $wrongFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c4b.ok) -and ([string]$c4b.reason -ceq 'claim-phase-conflict')) '[C4b] claim over a legacy settled receipt conflicts' ([string]$c4b.reason)
    $k16 = Get-NativeDispatchHash32 'hf-claim-absent-1'
    $c4c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k16 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $wrongFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c4c.ok) -and ([string]$c4c.reason -ceq 'claim-not-prepared') -and ([int]$c4c.executor_calls -eq 0)) '[C4c] claim of an absent key denies as not prepared' ([string]$c4c.reason)
    $c4d = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey 'not-a-valid-key' -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $wrongFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c4d.ok) -and ([string]$c4d.reason -ceq 'invalid-idempotency-key')) '[C4d] malformed key denies' ([string]$c4d.reason)
    $c4e = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k16 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint 'not-a-fingerprint' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c4e.ok) -and ([string]$c4e.reason -ceq 'invalid-prepared-fingerprint')) '[C4e] malformed fingerprint denies' ([string]$c4e.reason)

    # ---------- C5: CLAIM over a corrupt receipt fails closed ----------
    $k17 = Get-NativeDispatchHash32 'hf-claim-corrupt-1'
    $i17 = New-HFIntent -Task 'hf-task-2' -Key $k17
    $p17 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i17 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p17.ok) '[C5] prepared for corruption fixture' ([string]$p17.reason)
    $corruptPath = Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k17
    $corruptBefore = [IO.File]::ReadAllText($corruptPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($corruptPath, '{"schema_version":1,"idempotency_key":"' + $k17 + '","phase":"prepa', [Text.UTF8Encoding]::new($false))
    $c5 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k17 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p17.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c5.ok) -and ([string]$c5.reason -ceq 'receipt-json-invalid') -and ([int]$c5.executor_calls -eq 0)) '[C5a] truncated JSON receipt denies the claim' ([string]$c5.reason)
    $p17b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i17 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p17b.ok) -and ([string]$p17b.reason -ceq 'receipt-json-invalid')) '[C5b] corrupt receipt also blocks re-prepare' ([string]$p17b.reason)
    Assert-HF (([IO.File]::ReadAllText($corruptPath, [Text.Encoding]::UTF8) -ne $corruptBefore)) '[C5] corrupt fixture left corrupt (never rewritten)' ''
    [IO.File]::WriteAllText($corruptPath, $corruptBefore, [Text.UTF8Encoding]::new($false))

    # ---------- C6: CLAIM concurrency (lock serializes, second consumer loses) ----------
    $k18 = Get-NativeDispatchHash32 'hf-claim-concurrency-1'
    # task dedicada: hf-task-2 ja tem um recibo 'claimed' nao-resolvido
    # (P10), e a reserva de task (F2) recusaria um segundo consumo.
    $i18 = New-HFIntent -Task 'hf-task-conc' -Key $k18
    $p18 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i18 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p18.ok) '[C6] prepared for concurrency fixture' ([string]$p18.reason)
    $goalSubDir = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'hf-goal-1'
    $heldLock = Open-NDReceiptLock -Dir $goalSubDir -LockTimeoutMs 5000
    Assert-HF ($null -ne $heldLock) '[C6] test holds the receipt lock' ''
    $c6 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k18 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p18.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -LockTimeoutMs 250
    Assert-HF ((-not [bool]$c6.ok) -and ([string]$c6.reason -ceq 'lock-busy') -and ([int]$c6.executor_calls -eq 0)) '[C6] a claimant that cannot take the receipt lock refuses as busy' ([string]$c6.reason)
    $c6Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k18), [Text.Encoding]::UTF8))
    Assert-HF (([string]$c6Raw.phase -ceq 'prepared')) '[C6] a lock-starved claimant never consumes the receipt' ('phase=' + [string]$c6Raw.phase)
    try { $heldLock.Dispose() } catch { }
    $c6b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k18 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p18.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c6b.ok) '[C6] after the lock is released the single legitimate claim succeeds' ([string]$c6b.reason)
    $c6c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k18 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p18.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c6c.ok) -and ([string]$c6c.reason -ceq 'claim-already-consumed')) '[C6] exactly one claim wins, the duplicate is refused' ([string]$c6c.reason)

    # ---------- L1: legacy Invoke refuses prepared/claimed receipts ----------
    $k19 = Get-NativeDispatchHash32 'hf-legacy-vs-prepared-1'
    # task dedicada: hf-task-claim ja tem um recibo 'claimed' (C1) e a
    # reserva de task (F2) impediria um segundo consumo na mesma task.
    $i19 = New-HFIntent -Task 'hf-task-l1' -Key $k19
    $p19 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i19 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p19.ok) '[L1] prepared for legacy-interaction fixture' ([string]$p19.reason)
    $l1Spy = { param($x) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l1 = Invoke-OrchestrationNativeDispatch -Intent $i19.intent -Executor $l1Spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$l1.ok) -and ([string]$l1.reason -ceq 'receipt-phase-unknown') -and ([int]$l1.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 0)) '[L1a] legacy Invoke refuses a prepared receipt with 0 executor calls' ([string]$l1.reason)
    $l1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k19), [Text.Encoding]::UTF8))
    Assert-HF (([string]$l1Raw.phase -ceq 'prepared')) '[L1a] the prepared receipt survives the legacy refusal' ('phase=' + [string]$l1Raw.phase)
    $c19 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k19 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p19.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c19.ok) '[L1] claimed for legacy-interaction fixture' ([string]$c19.reason)
    $l1bSpy = { param($x) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l1b = Invoke-OrchestrationNativeDispatch -Intent $i19.intent -Executor $l1bSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$l1b.ok) -and ([string]$l1b.reason -ceq 'receipt-phase-unknown') -and ([int]$l1b.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 0)) '[L1b] legacy Invoke refuses a claimed receipt with 0 executor calls' ([string]$l1b.reason)
    $l1bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k19), [Text.Encoding]::UTF8))
    Assert-HF (([string]$l1bRaw.phase -ceq 'claimed') -and ([string]$l1bRaw.claim_call_id -ceq $call)) '[L1b] the claimed receipt is never overwritten by the legacy path' ('phase=' + [string]$l1bRaw.phase)

    # ---------- L2: legacy Invoke still settles its own receipt (contract intact) ----------
    $k20 = Get-NativeDispatchHash32 'hf-legacy-compat-1'
    $i20 = New-HFIntent -Task 'hf-task-legacy' -Key $k20
    # Closure criado NO ESCOPO do script (nunca dentro de uma function):
    # um closure feito dentro de function recebe outro escopo de script e o
    # contador compartilhado deixaria de ser observavel.
    $l2Spy = { param($x) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l2 = Invoke-OrchestrationNativeDispatch -Intent $i20.intent -Executor $l2Spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$l2.ok) -and ([int]$l2.executor_calls -eq 1) -and ([int]$script:spyState.calls -eq 1)) '[L2a] legacy synchronous Invoke still executes exactly once' ([string]$l2.reason + ' calls=' + [string]$l2.executor_calls)
    Assert-HF (([string]$l2.reason -ceq '') -and ([bool]$l2.admitted)) '[L2a] legacy happy path returns its usual envelope' ([string]$l2.reason)
    $l2Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId 'hf-goal-1' -Key $k20), [Text.Encoding]::UTF8))
    Assert-HF (([string]$l2Raw.phase -ceq 'settled') -and ([bool]$l2Raw.ok)) '[L2a] legacy receipt settles as before' ('phase=' + [string]$l2Raw.phase)
    $l2bSpy = { param($x) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l2b = Invoke-OrchestrationNativeDispatch -Intent $i20.intent -Executor $l2bSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$l2b.ok) -and ([bool]$l2b.duplicate) -and ([int]$l2b.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 1)) '[L2b] legacy duplicate still short-circuits with 0 executor calls' ([string]$l2b.reason)
    $p20 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i20 -Authorization $authOk -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$p20.ok) -and ([string]$p20.reason -ceq 'prepare-phase-conflict') -and ([int]$p20.executor_calls -eq 0)) '[L2c] prepare over a settled legacy receipt conflicts' ([string]$p20.reason)
    $c20 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k20 -Authorization $authOk -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p20.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c20.ok) -and ([string]$c20.reason -ceq 'claim-phase-conflict') -and ([int]$c20.executor_calls -eq 0)) '[L2c] claim over a settled legacy receipt conflicts' ([string]$c20.reason)

    # ---------- L3: helpers never treat a supplied descriptor as authorization ----------
    $h1 = Test-NDHostCallDescriptor -SessionId 'ses_hf_x'
    Assert-HF (([bool]$h1.ok) -and ([string]$h1.session_id -ceq 'ses_hf_x')) '[L3a] descriptor validation checks shape only' ([string]$h1.reason)
    $h2 = Test-NDHostCallDescriptor -SessionId 'ses_hf_x' -MessageId 'm' -CallId 'c' -RequireCallIdentity
    Assert-HF (([bool]$h2.ok) -and ([string]$h2.message_id -ceq 'm') -and ([string]$h2.call_id -ceq 'c')) '[L3a] required call identity validates message and call ids' ([string]$h2.reason)
    $h3 = Test-NDHostCallDescriptor -SessionId 'bad session!!'
    Assert-HF ((-not [bool]$h3.ok) -and ([string]$h3.reason -ceq 'host-session-invalid')) '[L3b] malformed session id is refused' ([string]$h3.reason)
    $h4 = Test-NDHostCallDescriptor -SessionId 'ses_hf_x' -MessageId 'bad message!!' -CallId 'bad call!!' -RequireCallIdentity
    Assert-HF ((-not [bool]$h4.ok) -and (@('host-message-invalid', 'host-call-invalid') -ccontains [string]$h4.reason)) '[L3b] a claim descriptor requires message and call identity' ([string]$h4.reason)
    Assert-HF ((-not [bool]$h3.ok) -and ([string]$h3.reason -ceq 'host-session-invalid')) '[L3b] malformed session id is refused' ([string]$h3.reason)
    $src = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1') -Raw)
    Assert-HF ($src -match 'NAO consegue autenticar um descritor fornecido') '[L3c] library documents that it cannot authenticate a supplied descriptor' ''

    # ---------- hygiene ----------
    foreach ($p in @((Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'), (Join-Path $PSScriptRoot 'OrchestrationNativeDispatchHandoff.tests.ps1'))) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $bad = 0
        foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
        Assert-HF ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
    }
    $ndSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'), [Text.UTF8Encoding]::new($false))
    Assert-HF ((($ndSrc -notmatch 'Start-Process') -and ($ndSrc -notmatch 'Invoke-WebRequest') -and ($ndSrc -notmatch 'Invoke-RestMethod') -and ($ndSrc -notmatch 'Start-Job'))) '[HYG] library has no spawn/network' ''
    $ndLibDir = $PSScriptRoot
    $ndRootFiles = @()
    try { $ndRootFiles = @([IO.Directory]::GetFiles((Get-OrchestrationDispatchReceiptDir -ReceiptDir $receiptDir), '*.json')) } catch { $ndRootFiles = @() }
    Assert-HF (@($ndRootFiles).Count -eq 0) '[HYG] no receipt JSON at the receipt root (no second store)' ('files=' + [string]@($ndRootFiles).Count)
    $ndSubReceipts = 0
    foreach ($d in @([IO.Directory]::GetDirectories($receiptDir))) { $ndSubReceipts += @([IO.Directory]::GetFiles($d, '*.json')).Count }
    Assert-HF ($ndSubReceipts -gt 0) '[HYG] every receipt lives under a per-goal subdirectory of the existing store' ('receipts=' + [string]$ndSubReceipts)

    # ---------- F1: fencing pos-lock em PREPARE (reuso e persistencia) e CLAIM ----------
    # Cenario deterministico: o teste ocupa o lock do recibo e, ENQUANTO o
    # pretendente esperaria, tira o goal de ACTIVE. A autorizacao pre-lock
    # passa (PAUSED nao e terminal e a ownership segue valida), portanto a
    # recusa so pode vir da releitura viva feita SOB o lock.
    $fx = New-HFIsolatedFixture -Suffix 'fence'
    $kf1 = Get-NativeDispatchHash32 'hf-fence-prepare-1'
    $if1 = New-HFIntent -Task $fx.task -Key $kf1 -Gen $fx.gen
    $pf1 = Invoke-OrchestrationNativeDispatchPrepare -Intent $if1 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pf1.ok) '[F1] prepared on the isolated fence fixture' ([string]$pf1.reason)

    $held = Open-HFReceiptLockHeld -GoalId $fx.goal
    Assert-HF ($null -ne $held) '[F1a] test holds the receipt lock of the fence fixture' ''
    if ($null -ne $held) {
        try {
            $paused = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'PAUSED' -Gen $fx.gen
            Assert-HF ([bool]$paused.ok) '[F1a] goal left ACTIVE while a claimant would wait on the lock' ([string]$paused.reason)
        }
        finally { try { $held.Dispose() } catch { } }
    }
    $pf1b = Invoke-OrchestrationNativeDispatchPrepare -Intent $if1 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$pf1b.ok) -and ([string]$pf1b.reason -like 'post-lock-goal-not-active*') -and (-not [bool]$pf1b.reused) -and ([int]$pf1b.executor_calls -eq 0)) '[F1a] idempotent reuse revalidates admission, budget and live fencing under the lock' ([string]$pf1b.reason)
    $pf1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fx.goal -Key $kf1), [Text.Encoding]::UTF8))
    Assert-HF (([string]$pf1Raw.phase -ceq 'prepared') -and ([string]$pf1Raw.reference -ceq [string]$pf1.reference)) '[F1a] refused reuse never rewrites the prepared receipt' ''
    $back1 = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'ACTIVE' -Gen $fx.gen
    Assert-HF ([bool]$back1.ok) '[F1a] goal restored to ACTIVE' ([string]$back1.reason)
    $pf1c = Invoke-OrchestrationNativeDispatchPrepare -Intent $if1 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$pf1c.ok) -and ([bool]$pf1c.reused) -and ([string]$pf1c.reason -ceq 'prepare-reused') -and ([string]$pf1c.reference -ceq [string]$pf1.reference)) '[F1a] control: identical reuse works again once the goal is ACTIVE' ([string]$pf1c.reason)

    $kf2 = Get-NativeDispatchHash32 'hf-fence-prepare-2'
    $if2 = New-HFIntent -Task $fx.task -Key $kf2 -Gen $fx.gen
    $held = Open-HFReceiptLockHeld -GoalId $fx.goal
    if ($null -ne $held) {
        try {
            $paused2 = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'PAUSED' -Gen $fx.gen
            Assert-HF ([bool]$paused2.ok) '[F1b] goal left ACTIVE before a fresh persist' ([string]$paused2.reason)
        }
        finally { try { $held.Dispose() } catch { } }
    }
    $pf2 = Invoke-OrchestrationNativeDispatchPrepare -Intent $if2 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$pf2.ok) -and ([string]$pf2.reason -like 'post-lock-goal-not-active*') -and ([int]$pf2.executor_calls -eq 0)) '[F1b] a fresh PREPARED persist requires post-lock fencing' ([string]$pf2.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fx.goal -Key $kf2) -PathType Leaf)) '[F1b] nothing persisted when fencing refuses' ''
    $back2 = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'ACTIVE' -Gen $fx.gen
    Assert-HF ([bool]$back2.ok) '[F1b] goal restored to ACTIVE' ([string]$back2.reason)
    $pf2b = Invoke-OrchestrationNativeDispatchPrepare -Intent $if2 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pf2b.ok) '[F1b] control: fresh persist works once the goal is ACTIVE' ([string]$pf2b.reason)

    $kf3 = Get-NativeDispatchHash32 'hf-fence-claim-1'
    $if3 = New-HFIntent -Task $fx.task -Key $kf3 -Gen $fx.gen
    $pf3 = Invoke-OrchestrationNativeDispatchPrepare -Intent $if3 -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pf3.ok) '[F1c] prepared for the claim fencing fixture' ([string]$pf3.reason)
    $held = Open-HFReceiptLockHeld -GoalId $fx.goal
    if ($null -ne $held) {
        try {
            $paused3 = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'PAUSED' -Gen $fx.gen
            Assert-HF ([bool]$paused3.ok) '[F1c] goal left ACTIVE before the claim' ([string]$paused3.reason)
        }
        finally { try { $held.Dispose() } catch { } }
    }
    $cf3 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kf3 -Authorization $fx.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pf3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cf3.ok) -and (-not [bool]$cf3.claimed) -and ([string]$cf3.reason -like 'post-lock-goal-not-active*') -and ([int]$cf3.executor_calls -eq 0)) '[F1c] CLAIM revalidates the goal under the lock immediately before the write' ([string]$cf3.reason)
    $cf3Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fx.goal -Key $kf3), [Text.Encoding]::UTF8))
    Assert-HF (([string]$cf3Raw.phase -ceq 'prepared')) '[F1c] refused claim leaves the receipt prepared' ('phase=' + [string]$cf3Raw.phase)
    $back3 = Set-HFGoalStateLive -GoalId $fx.goal -ToState 'ACTIVE' -Gen $fx.gen
    Assert-HF ([bool]$back3.ok) '[F1c] goal restored to ACTIVE' ([string]$back3.reason)
    $cf3b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kf3 -Authorization $fx.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pf3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cf3b.ok) -and ([bool]$cf3b.claimed)) '[F1c] control: claim works once the goal is ACTIVE' ([string]$cf3b.reason)

    # ---------- F1 (job): takeover / lease / terminalizacao ENQUANTO o pretendente espera o lock ----------
    # O job roda em processo separado: o teste ocupa o lock, espera a linha
    # de ativacao admitida do job (prova de que o gate pre-lock dele ja
    # passou) e so entao muta o goal. Nao ha corrida de tempo: a recusa
    # observada so pode vir da releitura viva feita sob o lock.
    function Invoke-HFClaimAfterLiveMutation {
        param($Fixture, [string]$Key, [scriptblock]$Mutation, [int]$LeaseTtlMs = 0)
        if ($LeaseTtlMs -gt 0) {
            $ren = Renew-OrchestrationGoalOwnership -GoalId ([string]$Fixture.goal) -OwnerId 'planner-1' -Generation ([long]$Fixture.gen) -StoreDir $goalDir -LeaseTtlMs $LeaseTtlMs
            Assert-HF ([bool]$ren.ok) ('[F1] lease armed for the wait window ' + [string]$Fixture.goal) ([string]$ren.reason)
        }
        $fi = New-HFIntent -Task ([string]$Fixture.task) -Key $Key -Gen ([long]$Fixture.gen)
        $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $fi -Authorization $Fixture.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$prep.ok) ('[F1] prepared before the lock wait ' + [string]$Fixture.goal) ([string]$prep.reason)
        $baseline = Get-HFActivationBaselineBytes -Dir $receiptDir
        $held = Open-HFReceiptLockHeld -GoalId ([string]$Fixture.goal)
        if ($null -eq $held) { return $null }
        $jb = $null
        $saw = $false
        $mutResult = $null
        $res = $null
        try {
            $jb = Invoke-HFClaimInJob -Key $Key -Authorization $Fixture.auth -PreparedFingerprint ([string]$prep.prepared_fingerprint)
            $saw = Wait-HFNewAdmittedRow -Dir $receiptDir -BaselineBytes $baseline -GoalId ([string]$Fixture.goal) -Owner 'planner-1'
            if ($null -ne $Mutation) { $mutResult = & $Mutation }
        }
        finally {
            try { Start-Sleep -Milliseconds 250 } catch { }
            try { $held.Dispose() } catch { }
            # o job NUNCA sobrevive ao cenario: mesmo em falha no meio do
            # fluxo ele recebe aqui espera limitada + stop/remove.
            try { $res = Receive-HFJob -Job $jb -Name ('F1-claim-job ' + $Key) } catch { $res = $null }
        }
        return [pscustomobject]@{ result = $res; admitted_seen = $saw; mutation = $mutResult }
    }

    $fj1 = New-HFIsolatedFixture -Suffix 'job1'
    $kd1 = Get-NativeDispatchHash32 'hf-job1-claim-1'
    # PRA-SETTLE-FIX5 (F1d): a lease de SETUP e LONGA (120s) - o boot do
    # job e o gate pre-lock precisam de ownership viva para escrever a
    # linha de ativacao admitida. A EXPIRACAO e deterministica: com o job
    # ja admitido (portanto parado no lock do recibo), a lease vigente e
    # encurtada para um TTL que expira com certeza antes de a trava ser
    # solta - a recusa observada so pode vir do fencing pos-lock, nunca de
    # um boot lento. A assercao de fencing real segue intacta.
    $out1 = Invoke-HFClaimAfterLiveMutation -Fixture $fj1 -Key $kd1 -LeaseTtlMs 120000 -Mutation {
        $dl = [DateTime]::UtcNow.AddSeconds(20)
        $expiredSeen = $false
        while ([DateTime]::UtcNow -lt $dl) {
            $slot = Get-OrchestrationGoal -GoalId $fj1.goal -StoreDir $goalDir
            $chk = $null
            try { $chk = Test-OrchestrationGoalOwnership -Goal $slot.goal -OwnerId 'planner-1' -Generation $fj1.gen } catch { $chk = $null }
            if (($null -ne $chk) -and (-not [bool]$chk.held)) { $expiredSeen = $true; break }
            # encurta a lease para 1ms: a proxima poll (>=100ms depois)
            # ve a expiracao com certeza, e o finally ainda espera 250ms
            # antes de soltar a trava do recibo.
            $shr = Renew-OrchestrationGoalOwnership -GoalId $fj1.goal -OwnerId 'planner-1' -Generation $fj1.gen -StoreDir $goalDir -LeaseTtlMs 1
            if (-not [bool]$shr.ok) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $expiredSeen) { return [pscustomobject]@{ ok = $false; reason = 'lease-never-expired'; generation = $fj1.gen; owner = 'planner-1'; renewed = $false; held_by_new_owner = $false } }
        return [pscustomobject]@{ ok = $true; reason = 'lease-shortened-deterministically'; generation = $fj1.gen; owner = 'planner-1'; renewed = $true; held_by_new_owner = $false }
    }
    Assert-HF (($null -ne $out1) -and ($null -ne $out1.mutation) -and ([bool]$out1.mutation.ok)) '[F1d] the setup lease stayed live through admission and was then expired deterministically' ('mutation=' + (ConvertTo-Json -InputObject $out1.mutation -Compress))
    Assert-HF (($null -ne $out1) -and ([bool]$out1.admitted_seen) -and ($null -ne $out1.result) -and (-not [bool]$out1.result.ok) -and ([string]$out1.result.reason -like 'post-lock-fencing-changed*') -and (-not [bool]$out1.result.claimed) -and ([int]$out1.result.executor_calls -eq 0)) '[F1d] lease expiry while the claimant waits on the lock refuses' ('admitted_seen=' + [string]$out1.admitted_seen + ' reason=' + [string]$out1.result.reason)
    $kd1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fj1.goal -Key $kd1), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kd1Raw.phase -ceq 'prepared')) '[F1d] expired lease never consumes the prepared receipt' ('phase=' + [string]$kd1Raw.phase)

    $fj2 = New-HFIsolatedFixture -Suffix 'job2'
    $kd2 = Get-NativeDispatchHash32 'hf-job2-claim-1'
    $out2 = Invoke-HFClaimAfterLiveMutation -Fixture $fj2 -Key $kd2 -Mutation {
        return (Set-HFGoalStateLive -GoalId $fj2.goal -ToState 'COMPLETED' -Gen $fj2.gen)
    }
    Assert-HF (($null -ne $out2) -and ([bool]$out2.admitted_seen) -and ($null -ne $out2.result) -and (-not [bool]$out2.result.ok) -and ([string]$out2.result.reason -like 'post-lock-goal-not-active*') -and (-not [bool]$out2.result.claimed) -and ([int]$out2.result.executor_calls -eq 0)) '[F1e] terminalization while the claimant waits on the lock refuses' ('admitted_seen=' + [string]$out2.admitted_seen + ' reason=' + [string]$out2.result.reason)
    $kd2Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fj2.goal -Key $kd2), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kd2Raw.phase -ceq 'prepared')) '[F1e] terminal goal never consumes the prepared receipt' ('phase=' + [string]$kd2Raw.phase)

    $fj3 = New-HFIsolatedFixture -Suffix 'job3'
    $kd3 = Get-NativeDispatchHash32 'hf-job3-claim-1'
    # PRA-SETTLE-FIX5 (F1f): mesmo tratamento do F1d - lease LONGA de
    # setup (120s) para o boot + admissao do job, e expiracao
    # DETERMINISTICA (renovacao para 1ms) somente depois de a linha
    # admitida ser vista, com o job ja parado no lock. O takeover abaixo
    # continua sendo a UNICA explicacao da recusa: o novo dono recebe
    # lease viva (120s), entao a recusa NAO pode ser atribuida a
    # expiracao de lease.
    $out3 = Invoke-HFClaimAfterLiveMutation -Fixture $fj3 -Key $kd3 -LeaseTtlMs 120000 -Mutation {
        $dl = [DateTime]::UtcNow.AddSeconds(20)
        $expired = $false
        while ([DateTime]::UtcNow -lt $dl) {
            $slot = Get-OrchestrationGoal -GoalId $fj3.goal -StoreDir $goalDir
            $chk = $null
            try { $chk = Test-OrchestrationGoalOwnership -Goal $slot.goal -OwnerId 'planner-1' -Generation $fj3.gen } catch { $chk = $null }
            if (($null -ne $chk) -and (-not [bool]$chk.held)) { $expired = $true; break }
            $shr = Renew-OrchestrationGoalOwnership -GoalId $fj3.goal -OwnerId 'planner-1' -Generation $fj3.gen -StoreDir $goalDir -LeaseTtlMs 1
            if (-not [bool]$shr.ok) { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $expired) { return [pscustomobject]@{ ok = $false; reason = 'lease-never-expired'; generation = 0; owner = ''; renewed = $false; held_by_new_owner = $false } }
        $tow = Takeover-OrchestrationGoalOwnership -GoalId $fj3.goal -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 120000
        if (-not [bool]$tow.ok) {
            return [pscustomobject]@{ ok = $false; reason = ([string]$tow.reason); generation = 0; owner = ''; renewed = $false; held_by_new_owner = $false }
        }
        # O NOVO dono recebe lease viva e ownership valida: assim a recusa
        # do claimant NAO pode ser explicada por expiracao de lease - so o
        # takeover (owner/generation divergentes) explica.
        $newGen = [long]$tow.ownership['generation']
        $renew = Renew-OrchestrationGoalOwnership -GoalId $fj3.goal -OwnerId 'planner-2' -Generation $newGen -StoreDir $goalDir -LeaseTtlMs 120000
        $probe = $null
        try {
            $slot = Get-OrchestrationGoal -GoalId $fj3.goal -StoreDir $goalDir
            $probe = Test-OrchestrationGoalOwnership -Goal $slot.goal -OwnerId 'planner-2' -Generation $newGen
        }
        catch { $probe = $null }
        return [pscustomobject]@{
            ok = [bool]$tow.ok; reason = ([string]$tow.reason); generation = $newGen; owner = 'planner-2'
            renewed = ([bool](Get-NDValue $renew 'ok' $false)); held_by_new_owner = ([bool](Get-NDValue $probe 'held' $false))
        }
    }
    Assert-HF (($null -ne $out3) -and ($null -ne $out3.mutation) -and ([bool]$out3.mutation.ok) -and ([long]$out3.mutation.generation -gt [long]$fj3.gen) -and ([string]$out3.mutation.owner -ceq 'planner-2') -and ([bool]$out3.mutation.held_by_new_owner) -and ([bool]$out3.admitted_seen)) '[F1f] takeover succeeded (new owner + live lease) while the claimant waited on the lock' ('admitted_seen=' + [string]$out3.admitted_seen + ' mutation=' + (ConvertTo-Json -InputObject $out3.mutation -Compress))
    Assert-HF (($null -ne $out3) -and ($null -ne $out3.result) -and (-not [bool]$out3.result.ok) -and ([string]$out3.result.reason -like 'post-lock-fencing-changed:owner-conflict*') -and (-not [bool]$out3.result.claimed) -and ([int]$out3.result.executor_calls -eq 0)) '[F1f] takeover, not lease expiry, refuses the claim' ('reason=' + [string]$out3.result.reason)
    $kd3Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fj3.goal -Key $kd3), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kd3Raw.phase -ceq 'prepared')) '[F1f] takeover never consumes the prepared receipt' ('phase=' + [string]$kd3Raw.phase)

    # ---------- F2: reserva de task (segundo claim na mesma task/revisao) ----------
    $ff2a = New-HFIsolatedFixture -Suffix 'f2a'
    $k2a1 = Get-NativeDispatchHash32 'hf-f2a-key-1'
    $k2a2 = Get-NativeDispatchHash32 'hf-f2a-key-2'
    $p2a1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2a.task -Key $k2a1 -Gen $ff2a.gen) -Authorization $ff2a.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2a1.ok) '[F2a] first key prepared for the reservation fixture' ([string]$p2a1.reason)
    $p2a2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2a.task -Key $k2a2 -Gen $ff2a.gen) -Authorization $ff2a.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2a2.ok) '[F2a] second key prepared for the SAME task and revision' ([string]$p2a2.reason)
    $c2a1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2a1 -Authorization $ff2a.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2a1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$c2a1.ok) -and ([bool]$c2a1.claimed)) '[F2a] first key claims' ([string]$c2a1.reason)
    $c2a2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2a2 -Authorization $ff2a.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2a2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2a2.ok) -and (-not [bool]$c2a2.claimed) -and ([string]$c2a2.reason -ceq 'claim-task-already-claimed') -and ([int]$c2a2.executor_calls -eq 0)) '[F2a] second key on the same task/revision is refused by the reservation' ([string]$c2a2.reason)
    $k2a2Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $ff2a.goal -Key $k2a2), [Text.Encoding]::UTF8))
    Assert-HF (([string]$k2a2Raw.phase -ceq 'prepared')) '[F2a] the refused second receipt stays prepared' ('phase=' + [string]$k2a2Raw.phase)
    $ff2b = New-HFIsolatedFixture -Suffix 'f2b'
    $k2b1 = Get-NativeDispatchHash32 'hf-f2b-key-1'
    $p2b1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2b.task -Key $k2b1 -Gen $ff2b.gen) -Authorization $ff2b.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2b1.ok) '[F2b] unrelated task prepared' ([string]$p2b1.reason)
    $c2b1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2b1 -Authorization $ff2b.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2b1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$c2b1.ok) -and ([bool]$c2b1.claimed)) '[F2b] the reservation does not block an unrelated task' ([string]$c2b1.reason)
    $ff2c = New-HFIsolatedFixture -Suffix 'f2c'
    $k2c1 = Get-NativeDispatchHash32 'hf-f2c-legacy-settled'
    $k2c2 = Get-NativeDispatchHash32 'hf-f2c-key-2'
    $i2c2Fp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $ff2c.task -Key $k2c2 -Gen $ff2c.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $ff2c.goal -Key $k2c1), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $k2c1; phase = 'settled'; task_id = $ff2c.task; agent = 'coder'; owner = 'planner-1'; goal_id = $ff2c.goal; ownership_generation = $ff2c.gen; task_expected_revision = 1; intent_fingerprint = $i2c2Fp; reconciled = $true; kernel_ok = $true; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $p2c2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2c.task -Key $k2c2 -Gen $ff2c.gen) -Authorization $ff2c.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2c2.ok) '[F2c] prepared over a settled legacy receipt of the same task' ([string]$p2c2.reason)
    $c2c2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2c2 -Authorization $ff2c.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2c2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$c2c2.ok) -and ([bool]$c2c2.claimed)) '[F2c] a settled receipt does not block the task' ([string]$c2c2.reason)
    $k2c3 = Get-NativeDispatchHash32 'hf-f2c-key-3'
    $p2c3 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2c.task -Key $k2c3 -Gen $ff2c.gen) -Authorization $ff2c.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2c3.ok) '[F2d] second key prepared over an open claim of the same task' ([string]$p2c3.reason)
    $c2c3 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2c3 -Authorization $ff2c.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2c3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2c3.ok) -and (-not [bool]$c2c3.claimed) -and ([string]$c2c3.reason -ceq 'claim-task-already-claimed') -and ([int]$c2c3.executor_calls -eq 0)) '[F2d] an open claim of the same task refuses a second effect' ([string]$c2c3.reason)
    $k2c3Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $ff2c.goal -Key $k2c3), [Text.Encoding]::UTF8))
    Assert-HF (([string]$k2c3Raw.phase -ceq 'prepared')) '[F2d] refused effect keeps the prepared receipt' ('phase=' + [string]$k2c3Raw.phase)
    $ff2e = New-HFIsolatedFixture -Suffix 'f2e'
    $k2e1 = Get-NativeDispatchHash32 'hf-f2e-key-1'
    $p2e1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2e.task -Key $k2e1 -Gen $ff2e.gen) -Authorization $ff2e.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2e1.ok) '[F2e] prepared for the unknown-phase scan fixture' ([string]$p2e1.reason)
    $ns2e = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $ff2e.goal
    $unknownPhasePath = Join-Path $ns2e ((Get-NativeDispatchHash32 'hf-f2e-unknown-phase') + '.json')
    [IO.File]::WriteAllText($unknownPhasePath, ('{"schema_version":1,"idempotency_key":"' + (Get-NativeDispatchHash32 'hf-f2e-unknown-phase') + '","phase":"settling","task_id":"' + [string]$ff2e.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$ff2e.goal + '","ownership_generation":' + [string]$ff2e.gen + ',"task_expected_revision":1}'), [Text.UTF8Encoding]::new($false))
    $c2e1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2e1 -Authorization $ff2e.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2e1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2e1.ok) -and (-not [bool]$c2e1.claimed) -and ([string]$c2e1.reason -ceq 'claim-task-scan-unreadable') -and ([int]$c2e1.executor_calls -eq 0)) '[F2e] an unknown-phase receipt of the SAME task fails the scan closed' ([string]$c2e1.reason)
    $k2e1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $ff2e.goal -Key $k2e1), [Text.Encoding]::UTF8))
    Assert-HF (([string]$k2e1Raw.phase -ceq 'prepared')) '[F2e] failed scan never consumes the prepared receipt' ('phase=' + [string]$k2e1Raw.phase)
    # Controle: removido o registro de fase desconhecida, o claim volta a funcionar.
    try { Remove-Item -LiteralPath $unknownPhasePath -Force -ErrorAction SilentlyContinue } catch { }
    $c2e1b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2e1 -Authorization $ff2e.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2e1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c2e1b.ok) '[F2e] control: the claim works once the malformed receipt is gone' ([string]$c2e1b.reason)
    # Registro de OUTRA task com estrutura INVALIDA (aqui: fase
    # desconhecida, sem fingerprint) NAO pode ser ignorado: a varredura
    # valida a estrutura do registro ANTES de atribui-lo a outra task.
    # Sem estrutura valida nao ha como afirmar que nao ha efeito DESTA
    # task ali, entao a incerteza recusa (fail-closed) e nao libera um
    # segundo efeito. Fixture proprio para nao herdar o efeito aberto do
    # controle acima.
    $ff2f = New-HFIsolatedFixture -Suffix 'f2f'
    $ns2f = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $ff2f.goal
    $otherTaskUnknownPath = Join-Path $ns2f ((Get-NativeDispatchHash32 'hf-f2f-other-task-unknown') + '.json')
    [IO.File]::WriteAllText($otherTaskUnknownPath, ('{"schema_version":1,"idempotency_key":"' + (Get-NativeDispatchHash32 'hf-f2f-other-task-unknown') + '","phase":"settling","task_id":"hf-task-2","agent":"coder","owner":"planner-1","goal_id":"' + [string]$ff2f.goal + '","ownership_generation":' + [string]$ff2f.gen + ',"task_expected_revision":1}'), [Text.UTF8Encoding]::new($false))
    $k2f1 = Get-NativeDispatchHash32 'hf-f2f-key-1'
    $p2f1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2f.task -Key $k2f1 -Gen $ff2f.gen) -Authorization $ff2f.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2f1.ok) '[F2f] prepared with a foreign-task invalid receipt present' ([string]$p2f1.reason)
    $c2f1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2f1 -Authorization $ff2f.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2f1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c2f1.ok) -and (-not [bool]$c2f1.claimed) -and ([string]$c2f1.reason -ceq 'claim-task-scan-unreadable') -and ([int]$c2f1.executor_calls -eq 0)) '[F2f] an invalid receipt of ANOTHER task fails the scan closed (never ignored as unrelated)' ([string]$c2f1.reason)
    $k2f1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $ff2f.goal -Key $k2f1), [Text.Encoding]::UTF8))
    Assert-HF (([string]$k2f1Raw.phase -ceq 'prepared')) '[F2f] failed scan never consumes the prepared receipt' ('phase=' + [string]$k2f1Raw.phase)
    try { Remove-Item -LiteralPath $otherTaskUnknownPath -Force -ErrorAction SilentlyContinue } catch { }
    $c2f1b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k2f1 -Authorization $ff2f.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p2f1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c2f1b.ok) '[F2f] control: the claim works once the malformed foreign receipt is gone' ([string]$c2f1b.reason)

    # ---------- F2 (job): mesmo task/revisao, chaves diferentes, simultaneo ----------
    $ff2d = New-HFIsolatedFixture -Suffix 'f2d'
    $k2d1 = Get-NativeDispatchHash32 'hf-f2d-key-1'
    $k2d2 = Get-NativeDispatchHash32 'hf-f2d-key-2'
    $p2d1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2d.task -Key $k2d1 -Gen $ff2d.gen) -Authorization $ff2d.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2d1.ok) '[F2e] first concurrent key prepared' ([string]$p2d1.reason)
    $p2d2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff2d.task -Key $k2d2 -Gen $ff2d.gen) -Authorization $ff2d.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p2d2.ok) '[F2e] second concurrent key prepared' ([string]$p2d2.reason)
    $jb1 = $null
    $jb2 = $null
    try {
        $jb1 = Invoke-HFClaimInJob -Key $k2d1 -Authorization $ff2d.auth -PreparedFingerprint ([string]$p2d1.prepared_fingerprint)
        $jb2 = Invoke-HFClaimInJob -Key $k2d2 -Authorization $ff2d.auth -PreparedFingerprint ([string]$p2d2.prepared_fingerprint)
    }
    catch { }
    $r1 = Receive-HFJob -Job $jb1 -Name 'F2e-concurrent-key1'
    $r2 = Receive-HFJob -Job $jb2 -Name 'F2e-concurrent-key2'
    $winners = @()
    foreach ($r in @($r1, $r2)) {
        if (($null -ne $r) -and [bool]$r.claimed) { $winners += $r }
    }
    $losersOk = $true
    foreach ($r in @($r1, $r2)) {
        if (($null -ne $r) -and (-not [bool]$r.claimed)) {
            if ([bool]$r.ok) { $losersOk = $false }
            if (@('claim-task-already-claimed', 'lock-busy') -cnotcontains [string]$r.reason) { $losersOk = $false }
            if ([int]$r.executor_calls -ne 0) { $losersOk = $false }
        }
    }
    Assert-HF ((($null -ne $r1) -and ($null -ne $r2) -and (@($winners).Count -eq 1) -and $losersOk)) '[F2e] concurrent same-task claims yield at most one winner' ('r1=' + [string]$r1.reason + ' r2=' + [string]$r2.reason)
    $claimedOnDisk = 0
    foreach ($f in @([IO.Directory]::GetFiles((Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $ff2d.goal), '*.json'))) {
        $raw = ConvertFrom-Json ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
        if ([string]$raw.phase -ceq 'claimed') { $claimedOnDisk++ }
    }
    Assert-HF ($claimedOnDisk -eq 1) '[F2e] exactly one receipt of that task is claimed on disk' ('claimed=' + [string]$claimedOnDisk)

    # ---------- X1: exclusao de efeito por TASK (GoalId/revisao/chave independentes) ----------
    # A reserva vale para (raiz de recibos, task_id): nenhum SEGUNDO efeito
    # enquanto existir recibo nao-resolvido da MESMA task em QUALQUER
    # namespace de goal sob a mesma raiz.

    # X1a: mesma task, NOVA revisao, chave diferente -> segundo efeito recusado
    $fx1 = New-HFIsolatedFixture -Suffix 'x1rev'
    $kx1a = Get-NativeDispatchHash32 'hf-x1rev-key-1'
    $px1a = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fx1.task -Key $kx1a -Rev 1 -Gen $fx1.gen) -Authorization $fx1.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1a.ok) '[X1a] first key prepared at revision 1' ([string]$px1a.reason)
    $cx1a = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1a -Authorization $fx1.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1a.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1a.ok) '[X1a] first key claims at revision 1' ([string]$cx1a.reason)
    $adv = Set-OrchestrationTaskWorkerResult -TaskId $fx1.task -Status 'failed' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
    Assert-HF ([bool]$adv.ok) '[X1a] kernel advanced the live task revision' ([string]$adv.error)
    $taskNow = Get-OrchestrationTask -TaskId $fx1.task -TasksDir $tasksDir
    $revNow = 0
    try { $revNow = [int]$taskNow.revision } catch { $revNow = 0 }
    Assert-HF ($revNow -ge 2) '[X1a] live task revision moved forward' ('rev=' + [string]$revNow)
    $kx1b = Get-NativeDispatchHash32 'hf-x1rev-key-2'
    $px1b = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fx1.task -Key $kx1b -Rev 2 -Gen $fx1.gen) -Authorization $fx1.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1b.ok) '[X1a] a NEW revision still prepares (prepared is not an effect)' ([string]$px1b.reason)
    $cx1b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1b -Authorization $fx1.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1b.ok) -and (-not [bool]$cx1b.claimed) -and ([string]$cx1b.reason -ceq 'claim-task-already-claimed') -and ([int]$cx1b.executor_calls -eq 0)) '[X1a] same task at a NEW revision is still blocked by the open effect' ([string]$cx1b.reason)
    $kx1bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fx1.goal -Key $kx1b), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kx1bRaw.phase -ceq 'prepared')) '[X1a] refused revision keeps its prepared receipt' ('phase=' + [string]$kx1bRaw.phase)
    # X1b: a MESMA task em DOIS goals diferentes -> so um efeito
    $fxa = New-HFIsolatedFixture -Suffix 'x1ga'
    $gBId = 'hf-goal-x1gb'
    $gB = New-OrchestrationGoal -GoalId $gBId -Objective 'goal B mesma task' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$gB.ok) '[X1b] second goal created for the same task' ([string]$gB.reason)
    $gBAct = Set-OrchestrationGoalState -Goal $gB.goal -ToState 'ACTIVE'
    $gBSv = Save-OrchestrationGoal -Goal $gBAct.goal -StoreDir $goalDir
    Assert-HF ([bool]$gBSv.ok) '[X1b] second goal active' ([string]$gBSv.reason)
    $gBOwn = Acquire-OrchestrationGoalOwnership -GoalId $gBId -OwnerId 'planner-1' -ExpectedRevision ([long]$gBSv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$gBOwn.ok) '[X1b] second goal owned' ([string]$gBOwn.reason)
    $gBGen = [long]$gBOwn.ownership['generation']
    $gBSlot = Get-OrchestrationGoal -GoalId $gBId -StoreDir $goalDir
    $gBAdd = Add-OrchestrationGoalTaskPersisted -GoalId $gBId -TaskId $fxa.task -ExpectedRevision ([long]$gBSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gBGen
    Assert-HF ([bool]$gBAdd.ok) '[X1b] the SAME task attached to the second goal' ([string]$gBAdd.reason)
    $authB = @{ explicit_allow = $true; goal_id = $gBId; owner = 'planner-1'; generation = $gBGen; source = 'planner' }
    $kx1bA = Get-NativeDispatchHash32 'hf-x1gb-key-A'
    $px1bA = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxa.task -Key $kx1bA -Gen $gBGen) -Authorization $authB -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1bA.ok) '[X1b] prepared under goal B' ([string]$px1bA.reason)
    $cx1bA = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1bA -Authorization $authB -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1bA.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1bA.ok) '[X1b] claim under goal B succeeds (no effect open yet)' ([string]$cx1bA.reason)
    $kx1bB = Get-NativeDispatchHash32 'hf-x1gb-key-B'
    $px1bB = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxa.task -Key $kx1bB -Gen $fxa.gen) -Authorization $fxa.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1bB.ok) '[X1b] prepared under goal A for the same task' ([string]$px1bB.reason)
    $cx1bB = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1bB -Authorization $fxa.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1bB.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1bB.ok) -and (-not [bool]$cx1bB.claimed) -and ([string]$cx1bB.reason -ceq 'claim-task-already-claimed') -and ([int]$cx1bB.executor_calls -eq 0)) '[X1b] the open effect of ANOTHER goal blocks a second effect of the same task' ([string]$cx1bB.reason)
    $kx1bBRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxa.goal -Key $kx1bB), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kx1bBRaw.phase -ceq 'prepared')) '[X1b] the blocked receipt of goal A stays prepared' ('phase=' + [string]$kx1bBRaw.phase)
    # X1c: recibo SETTLED de outro goal NAO bloqueia (liquidacao conhecida)
    $fxc = New-HFIsolatedFixture -Suffix 'x1settled'
    $gCId = 'hf-goal-x1sc'
    $gC = New-OrchestrationGoal -GoalId $gCId -Objective 'goal C settled' -Criteria @('criterio-a') -StoreDir $goalDir
    $gCAct = Set-OrchestrationGoalState -Goal $gC.goal -ToState 'ACTIVE'
    $gCSv = Save-OrchestrationGoal -Goal $gCAct.goal -StoreDir $goalDir
    $gCOwn = Acquire-OrchestrationGoalOwnership -GoalId $gCId -OwnerId 'planner-1' -ExpectedRevision ([long]$gCSv.revision) -StoreDir $goalDir
    $gCGen = [long]$gCOwn.ownership['generation']
    $gCSlot = Get-OrchestrationGoal -GoalId $gCId -StoreDir $goalDir
    $null = Add-OrchestrationGoalTaskPersisted -GoalId $gCId -TaskId $fxc.task -ExpectedRevision ([long]$gCSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gCGen
    $authC = @{ explicit_allow = $true; goal_id = $gCId; owner = 'planner-1'; generation = $gCGen; source = 'planner' }
    $kx1c = Get-NativeDispatchHash32 'hf-x1sc-settled'
    $settledFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxc.task -Key $kx1c -Gen $gCGen).intent
    $cSub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $gCId
    [IO.File]::WriteAllText((Join-Path $cSub ($kx1c + '.json')), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kx1c; phase = 'settled'; task_id = $fxc.task; agent = 'coder'; owner = 'planner-1'; goal_id = $gCId; ownership_generation = $gCGen; task_expected_revision = 1; intent_fingerprint = $settledFp; reconciled = $true; kernel_ok = $true; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $kx1c2 = Get-NativeDispatchHash32 'hf-x1sc-fresh'
    $px1c = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxc.task -Key $kx1c2 -Gen $fxc.gen) -Authorization $fxc.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1c.ok) '[X1c] prepared while a settled receipt of the same task exists in another goal' ([string]$px1c.reason)
    $cx1c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1c2 -Authorization $fxc.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1c.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cx1c.ok) -and ([bool]$cx1c.claimed)) '[X1c] a settled receipt of the same task does not block' ([string]$cx1c.reason)
    # X1d: CLAIM seguido de Invoke legado (mesma task, chave diferente)
    $fxd = New-HFIsolatedFixture -Suffix 'x1legacy'
    $kx1d1 = Get-NativeDispatchHash32 'hf-x1legacy-claim'
    $px1d = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxd.task -Key $kx1d1 -Gen $fxd.gen) -Authorization $fxd.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1d.ok) '[X1d] prepared for the claim-then-legacy fixture' ([string]$px1d.reason)
    $cx1d = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1d1 -Authorization $fxd.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1d.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1d.ok) '[X1d] claim consumed the fixture' ([string]$cx1d.reason)
    $kx1d2 = Get-NativeDispatchHash32 'hf-x1legacy-other'
    $i1d2 = New-HFIntent -Task $fxd.task -Key $kx1d2 -Gen $fxd.gen
    $x1dSpy = { param($i) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l1d = Invoke-OrchestrationNativeDispatch -Intent $i1d2.intent -Executor $x1dSpy -Authorization $fxd.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$l1d.ok) -and ([string]$l1d.reason -ceq 'claim-task-already-claimed') -and ([int]$l1d.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq 1)) '[X1d] the legacy Executor is refused while the claim is unresolved' ([string]$l1d.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxd.goal -Key $kx1d2) -PathType Leaf)) '[X1d] refused legacy dispatch persisted nothing' ''
    # mesma chave do claim: o diagnostico do proprio recibo vem primeiro
    $x1dSpy2 = { param($i) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l1d2 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxd.task -Key $kx1d1 -Gen $fxd.gen).intent -Executor $x1dSpy2 -Authorization $fxd.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$l1d2.ok) -and ([string]$l1d2.reason -ceq 'receipt-phase-unknown') -and ([int]$l1d2.executor_calls -eq 0)) '[X1d] the own claimed receipt still refuses as phase-unknown' ([string]$l1d2.reason)
    # X1e: recibo PENDING do legado (outra chave) bloqueia um CLAIM
    $fxe = New-HFIsolatedFixture -Suffix 'x1pend'
    $kx1e1 = Get-NativeDispatchHash32 'hf-x1pend-legacy'
    $pendFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxe.task -Key $kx1e1 -Gen $fxe.gen).intent
    $eSub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxe.goal
    [IO.File]::WriteAllText((Join-Path $eSub ($kx1e1 + '.json')), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kx1e1; phase = 'pending'; task_id = $fxe.task; agent = 'coder'; owner = 'planner-1'; goal_id = $fxe.goal; ownership_generation = $fxe.gen; task_expected_revision = 1; intent_fingerprint = $pendFp; external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $kx1e2 = Get-NativeDispatchHash32 'hf-x1pend-claim'
    $px1e = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxe.task -Key $kx1e2 -Gen $fxe.gen) -Authorization $fxe.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1e.ok) '[X1e] prepared while a legacy pending of the same task is unresolved' ([string]$px1e.reason)
    $cx1e = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1e2 -Authorization $fxe.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1e.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1e.ok) -and (-not [bool]$cx1e.claimed) -and ([string]$cx1e.reason -ceq 'claim-task-already-claimed') -and ([int]$cx1e.executor_calls -eq 0)) '[X1e] an unresolved legacy pending blocks a native claim of the same task' ([string]$cx1e.reason)
    $kx1eRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxe.goal -Key $kx1e2), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kx1eRaw.phase -ceq 'prepared')) '[X1e] blocked claim stays prepared' ('phase=' + [string]$kx1eRaw.phase)
    # X1f: replay legado idempotente da PROPRIA chave permanece contratado
    $fxf = New-HFIsolatedFixture -Suffix 'x1replay'
    $kx1f = Get-NativeDispatchHash32 'hf-x1replay-key'
    $i1f = New-HFIntent -Task $fxf.task -Key $kx1f -Gen $fxf.gen -Ext $true -Proof 'sink dedupes by idempotency key (test)'
    Assert-HF ([bool]$i1f.ok) '[X1f] external-idempotent intent built' ([string]$i1f.reason)
    $replayFp = Get-NDIntentFingerprint -Intent $i1f.intent
    $fSub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxf.goal
    [IO.File]::WriteAllText((Join-Path $fSub ($kx1f + '.json')), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kx1f; phase = 'pending'; task_id = $fxf.task; agent = 'coder'; owner = 'planner-1'; goal_id = $fxf.goal; ownership_generation = $fxf.gen; task_expected_revision = 1; intent_fingerprint = $replayFp; external_idempotent = $true; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    # enquanto o pending proprio segue sem liquidacao, outro claim da MESMA task recusa
    $kx1f2 = Get-NativeDispatchHash32 'hf-x1replay-other'
    $px1f2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxf.task -Key $kx1f2 -Gen $fxf.gen) -Authorization $fxf.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1f2.ok) '[X1f] second key prepared while the legacy pending is unresolved' ([string]$px1f2.reason)
    $cx1f = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1f2 -Authorization $fxf.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1f2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1f.ok) -and (-not [bool]$cx1f.claimed) -and ([string]$cx1f.reason -ceq 'claim-task-already-claimed')) '[X1f] an unresolved legacy pending also blocks another key' ([string]$cx1f.reason)
    $x1fSpy = { param($i) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $beforeSpy = [int]$script:spyState.calls
    $l1f = Invoke-OrchestrationNativeDispatch -Intent $i1f.intent -Executor $x1fSpy -Authorization $fxf.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$l1f.reconciled) -and ([int]$l1f.executor_calls -eq 1) -and ([int]$script:spyState.calls -eq ($beforeSpy + 1))) '[X1f] the exact same-key external-idempotent replay still runs once' ([string]$l1f.reason)
    $l1fRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxf.goal -Key $kx1f), [Text.Encoding]::UTF8))
    Assert-HF (([string]$l1fRaw.phase -ceq 'settled')) '[X1f] the replayed receipt settles as before' ('phase=' + [string]$l1fRaw.phase)
    # X1g: identidade do recibo na varredura e (namespace, chave), NUNCA a chave sozinha
    $fxg = New-HFIsolatedFixture -Suffix 'x1ident'
    $gGId = 'hf-goal-x1idb'
    $gG = New-OrchestrationGoal -GoalId $gGId -Objective 'goal B mesma chave' -Criteria @('criterio-a') -StoreDir $goalDir
    $gGAct = Set-OrchestrationGoalState -Goal $gG.goal -ToState 'ACTIVE'
    $gGSv = Save-OrchestrationGoal -Goal $gGAct.goal -StoreDir $goalDir
    $gGOwn = Acquire-OrchestrationGoalOwnership -GoalId $gGId -OwnerId 'planner-1' -ExpectedRevision ([long]$gGSv.revision) -StoreDir $goalDir
    $gGGen = [long]$gGOwn.ownership['generation']
    $gGSlot = Get-OrchestrationGoal -GoalId $gGId -StoreDir $goalDir
    $null = Add-OrchestrationGoalTaskPersisted -GoalId $gGId -TaskId $fxg.task -ExpectedRevision ([long]$gGSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gGGen
    $authG = @{ explicit_allow = $true; goal_id = $gGId; owner = 'planner-1'; generation = $gGGen; source = 'planner' }
    $kx1g = Get-NativeDispatchHash32 'hf-x1ident-key'
    $px1g = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxg.task -Key $kx1g -Gen $fxg.gen) -Authorization $fxg.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1g.ok) '[X1g] prepared under goal A' ([string]$px1g.reason)
    $cx1g = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1g -Authorization $fxg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1g.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1g.ok) '[X1g] claimed under goal A' ([string]$cx1g.reason)
    # a MESMA chave agora existe no namespace de B: preparo valido la
    $px1gB = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxg.task -Key $kx1g -Gen $gGGen) -Authorization $authG -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1gB.ok) '[X1g] the same key prepares cleanly in the second namespace' ([string]$px1gB.reason)
    $cx1gB = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1g -Authorization $authG -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1gB.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1gB.ok) -and (-not [bool]$cx1gB.claimed) -and ([string]$cx1gB.reason -ceq 'claim-task-already-claimed') -and ([int]$cx1gB.executor_calls -eq 0)) '[X1g] the same key in another namespace is a DIFFERENT receipt and is still blocked' ([string]$cx1gB.reason)
    $kx1gBRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $gGId -Key $kx1g), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kx1gBRaw.phase -ceq 'prepared')) '[X1g] the blocked receipt of goal B stays prepared' ('phase=' + [string]$kx1gBRaw.phase)
    # X1h: dois processos, MESMA task, goals diferentes -> um unico vencedor
    $fxh = New-HFIsolatedFixture -Suffix 'x1conc'
    $gHId = 'hf-goal-x1cb'
    $gH = New-OrchestrationGoal -GoalId $gHId -Objective 'goal B concorrencia' -Criteria @('criterio-a') -StoreDir $goalDir
    $gHAct = Set-OrchestrationGoalState -Goal $gH.goal -ToState 'ACTIVE'
    $gHSv = Save-OrchestrationGoal -Goal $gHAct.goal -StoreDir $goalDir
    $gHOwn = Acquire-OrchestrationGoalOwnership -GoalId $gHId -OwnerId 'planner-1' -ExpectedRevision ([long]$gHSv.revision) -StoreDir $goalDir
    $gHGen = [long]$gHOwn.ownership['generation']
    $gHSlot = Get-OrchestrationGoal -GoalId $gHId -StoreDir $goalDir
    $null = Add-OrchestrationGoalTaskPersisted -GoalId $gHId -TaskId $fxh.task -ExpectedRevision ([long]$gHSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gHGen
    $authH = @{ explicit_allow = $true; goal_id = $gHId; owner = 'planner-1'; generation = $gHGen; source = 'planner' }
    $kx1hA = Get-NativeDispatchHash32 'hf-x1cb-key-A'
    $kx1hB = Get-NativeDispatchHash32 'hf-x1cb-key-B'
    $px1hA = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh.task -Key $kx1hA -Gen $fxh.gen) -Authorization $fxh.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    $px1hB = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh.task -Key $kx1hB -Gen $gHGen) -Authorization $authH -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$px1hA.ok) -and ([bool]$px1hB.ok)) '[X1h] both goals prepared the same task' ([string]$px1hB.reason)
    $jbA = $null
    $jbB = $null
    try {
        $jbA = Invoke-HFClaimJobOnRoot -RootDir $receiptDir -Key $kx1hA -Authorization $fxh.auth -PreparedFingerprint ([string]$px1hA.prepared_fingerprint)
        $jbB = Invoke-HFClaimJobOnRoot -RootDir $receiptDir -Key $kx1hB -Authorization $authH -PreparedFingerprint ([string]$px1hB.prepared_fingerprint)
    }
    catch { }
    $rA = Receive-HFJob -Job $jbA -Name 'X1h-cross-goal-A'
    $rB = Receive-HFJob -Job $jbB -Name 'X1h-cross-goal-B'
    $x1hWinners = @()
    foreach ($r in @($rA, $rB)) { if (($null -ne $r) -and [bool]$r.claimed) { $x1hWinners += $r } }
    $x1hLosersOk = $true
    foreach ($r in @($rA, $rB)) {
        if (($null -ne $r) -and (-not [bool]$r.claimed)) {
            if ([bool]$r.ok) { $x1hLosersOk = $false }
            if (@('claim-task-already-claimed', 'lock-busy', 'task-lock-busy') -cnotcontains [string]$r.reason) { $x1hLosersOk = $false }
            if ([int]$r.executor_calls -ne 0) { $x1hLosersOk = $false }
        }
    }
    Assert-HF ((($null -ne $rA) -and ($null -ne $rB) -and (@($x1hWinners).Count -eq 1) -and $x1hLosersOk)) '[X1h] concurrent same-task claims across goals yield exactly one winner' ('rA=' + [string]$rA.reason + ' rB=' + [string]$rB.reason)
    $x1hClaimed = 0
    foreach ($gid in @($fxh.goal, $gHId)) {
        foreach ($f in @([IO.Directory]::GetFiles((Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $gid), '*.json'))) {
            $raw = ConvertFrom-Json ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
            if (([string]$raw.phase -ceq 'claimed') -and ([string]$raw.task_id -ceq $fxh.task)) { $x1hClaimed++ }
        }
    }
    Assert-HF ($x1hClaimed -eq 1) '[X1h] exactly one claimed receipt of that task across both goals' ('claimed=' + [string]$x1hClaimed)
    # X1i: integridade SEMANTICA de um recibo de handoff da MESMA task e recalculada
    $fxi = New-HFIsolatedFixture -Suffix 'x1sem'
    $kx1i1 = Get-NativeDispatchHash32 'hf-x1sem-key-1'
    $px1i1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxi.task -Key $kx1i1 -Gen $fxi.gen) -Authorization $fxi.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1i1.ok) '[X1i] prepared for the semantic-scan fixture' ([string]$px1i1.reason)
    $x1iPath = Get-HFReceiptPath -GoalId $fxi.goal -Key $kx1i1
    $x1iGood = [IO.File]::ReadAllText($x1iPath, [Text.Encoding]::UTF8)
    $x1iRaw = ConvertFrom-Json $x1iGood
    Add-Member -InputObject $x1iRaw -Name 'intent_fingerprint' -Value (Get-NativeDispatchHash32 'hf-x1sem-tampered') -MemberType NoteProperty -Force
    [IO.File]::WriteAllText($x1iPath, (ConvertTo-Json -InputObject $x1iRaw -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $kx1i2 = Get-NativeDispatchHash32 'hf-x1sem-key-2'
    $px1i2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxi.task -Key $kx1i2 -Gen $fxi.gen) -Authorization $fxi.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1i2.ok) '[X1i] second key prepared over a tampered same-task receipt' ([string]$px1i2.reason)
    $cx1i = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1i2 -Authorization $fxi.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1i2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1i.ok) -and (-not [bool]$cx1i.claimed) -and ([string]$cx1i.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cx1i.executor_calls -eq 0)) '[X1i] a semantically tampered handoff receipt of the same task fails the scan closed' ([string]$cx1i.reason)
    [IO.File]::WriteAllText($x1iPath, $x1iGood, [Text.UTF8Encoding]::new($false))
    $cx1ib = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1i2 -Authorization $fxi.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1i2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1ib.ok) '[X1i] control: the claim works once the tampering is reverted' ([string]$cx1ib.reason)
    # X1j: nome inesperado de arquivo num namespace qualquer recusa a varredura
    $fxj = New-HFIsolatedFixture -Suffix 'x1name'
    $jSub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxj.goal
    [IO.File]::WriteAllText((Join-Path $jSub 'not-a-receipt.json'), '{"schema_version":1}', [Text.UTF8Encoding]::new($false))
    $kx1j = Get-NativeDispatchHash32 'hf-x1name-key'
    $px1j = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxj.task -Key $kx1j -Gen $fxj.gen) -Authorization $fxj.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$px1j.ok) '[X1j] prepared for the unexpected-name fixture' ([string]$px1j.reason)
    $cx1j = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1j -Authorization $fxj.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1j.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cx1j.ok) -and (-not [bool]$cx1j.claimed) -and ([string]$cx1j.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cx1j.executor_calls -eq 0)) '[X1j] an unexpected receipt file name fails the scan closed' ([string]$cx1j.reason)
    $kx1jRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxj.goal -Key $kx1j), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kx1jRaw.phase -ceq 'prepared')) '[X1j] failed scan never consumes the receipt' ('phase=' + [string]$kx1jRaw.phase)
    try { Remove-Item -LiteralPath (Join-Path $jSub 'not-a-receipt.json') -Force -ErrorAction SilentlyContinue } catch { }
    $cx1jb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1j -Authorization $fxj.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1j.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$cx1jb.ok) '[X1j] control: the claim works once the odd file is gone' ([string]$cx1jb.reason)
    # X1k: cap rigido de namespaces raiz -> varredura fail-closed
    $capRoot = Join-Path $script:tempRoot 'receipts-cap'
    New-Item -ItemType Directory -Path $capRoot -Force | Out-Null
    $capOk = $true
    try {
        for ($ci = 0; $ci -lt 513; $ci++) {
            New-Item -ItemType Directory -Path (Join-Path $capRoot ((Get-NativeDispatchHash32 ('hf-cap-ns-' + $ci)).PadRight(32, '0').Substring(0, 32))) -Force | Out-Null
        }
    }
    catch { $capOk = $false }
    if ($capOk) {
        $fxk = New-HFIsolatedFixture -Suffix 'x1cap'
        $kx1k = Get-NativeDispatchHash32 'hf-x1cap-key'
        $px1k = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxk.task -Key $kx1k -Gen $fxk.gen) -Authorization $fxk.auth -SessionId $session -ReceiptDir $capRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$px1k.ok) '[X1k] prepared inside the capped receipt root' ([string]$px1k.reason)
        $cx1k = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1k -Authorization $fxk.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1k.prepared_fingerprint) -ReceiptDir $capRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$cx1k.ok) -and (-not [bool]$cx1k.claimed) -and ([string]$cx1k.reason -ceq 'claim-task-scan-unbounded') -and ([int]$cx1k.executor_calls -eq 0)) '[X1k] a root above the namespace cap fails the scan closed' ([string]$cx1k.reason)
        $kx1kRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path (Get-NDGoalReceiptDir -RootDir $capRoot -GoalId $fxk.goal) ($kx1k + '.json')), [Text.Encoding]::UTF8))
        Assert-HF (([string]$kx1kRaw.phase -ceq 'prepared')) '[X1k] capped scan never consumes the receipt' ('phase=' + [string]$kx1kRaw.phase)
    }
    else { Skip-HF 'X1k namespace-cap fixture unavailable in this environment' }
    try { Remove-Item -LiteralPath $capRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    # X1l: recibo acima do cap de bytes por arquivo -> varredura fail-closed
    $capPerFile = Join-Path $script:tempRoot 'receipts-bigfile'
    New-Item -ItemType Directory -Path $capPerFile -Force | Out-Null
    $bigOk = $false
    try {
        $fxl = New-HFIsolatedFixture -Suffix 'x1big'
        $kx1l = Get-NativeDispatchHash32 'hf-x1big-key'
        $px1l = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxl.task -Key $kx1l -Gen $fxl.gen) -Authorization $fxl.auth -SessionId $session -ReceiptDir $capPerFile -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        if ([bool]$px1l.ok) {
            $bigKey = Get-NativeDispatchHash32 'hf-x1big-fat'
            $bigSub = Get-NDGoalReceiptDir -RootDir $capPerFile -GoalId $fxl.goal
            $fat = 'x' * 300000
            [IO.File]::WriteAllText((Join-Path $bigSub ($bigKey + '.json')), ('{"schema_version":1,"idempotency_key":"' + $bigKey + '","phase":"settled","task_id":"' + [string]$fxl.task + '","pad":"' + $fat + '"}'), [Text.UTF8Encoding]::new($false))
            $cx1l = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1l -Authorization $fxl.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1l.prepared_fingerprint) -ReceiptDir $capPerFile -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
            Assert-HF ((-not [bool]$cx1l.ok) -and (-not [bool]$cx1l.claimed) -and ([string]$cx1l.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cx1l.executor_calls -eq 0)) '[X1l] a receipt above the per-file byte cap fails the scan closed' ([string]$cx1l.reason)
            $kx1lRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path (Get-NDGoalReceiptDir -RootDir $capPerFile -GoalId $fxl.goal) ($kx1l + '.json')), [Text.Encoding]::UTF8))
            Assert-HF (([string]$kx1lRaw.phase -ceq 'prepared')) '[X1l] oversized-receipt refusal never consumes the prepared receipt' ('phase=' + [string]$kx1lRaw.phase)
            $bigOk = $true
        }
    }
    catch { $bigOk = $false }
    if (-not $bigOk) { Skip-HF 'X1l per-file byte cap fixture unavailable in this environment' }
    try { Remove-Item -LiteralPath $capPerFile -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    # X1m: namespace substituido por junction durante a varredura -> recusa
    $fxm = New-HFIsolatedFixture -Suffix 'x1reparse'
    $linkRoot = Join-Path $script:tempRoot 'receipts-reparse'
    New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
    $physTarget = Join-Path $linkRoot (Get-NativeDispatchHash32 'hf-goal-x1reparse-target')
    $linkPath = Join-Path $linkRoot (Get-NativeDispatchHash32 'hf-goal-x1reparse-link')
    $linkOk = $false
    try {
        New-Item -ItemType Directory -Path $physTarget -Force | Out-Null
        try { cmd /c mklink /J "$linkPath" "$physTarget" 2>&1 | Out-Null } catch { }
        if (-not (Test-Path -LiteralPath $linkPath)) {
            try { New-Item -ItemType Junction -Path $linkPath -Target $physTarget -ErrorAction Stop | Out-Null } catch { }
        }
        if (Test-Path -LiteralPath $linkPath) { $linkOk = $true }
    }
    catch { $linkOk = $false }
    if ($linkOk) {
        $kx1m = Get-NativeDispatchHash32 'hf-x1reparse-key'
        $px1m = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxm.task -Key $kx1m -Gen $fxm.gen) -Authorization $fxm.auth -SessionId $session -ReceiptDir $linkRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$px1m.ok) '[X1m] prepared inside the reparse-scanned root' ([string]$px1m.reason)
        $cx1m = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kx1m -Authorization $fxm.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$px1m.prepared_fingerprint) -ReceiptDir $linkRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$cx1m.ok) -and (-not [bool]$cx1m.claimed) -and (([string]$cx1m.reason -ceq 'receipt-dir-reparse-point') -or ([string]$cx1m.reason -ceq 'receipt-dir-identity-changed')) -and ([int]$cx1m.executor_calls -eq 0)) '[X1m] a junction namespace is refused by the scan' ([string]$cx1m.reason)
        $kx1mRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path (Get-NDGoalReceiptDir -RootDir $linkRoot -GoalId $fxm.goal) ($kx1m + '.json')), [Text.Encoding]::UTF8))
        Assert-HF (([string]$kx1mRaw.phase -ceq 'prepared')) '[X1m] reparse refusal never consumes the receipt' ('phase=' + [string]$kx1mRaw.phase)
        try { [IO.Directory]::Delete($linkPath, $false) } catch { }
    }
    else { Skip-HF 'X1m reparse fixture unavailable in this environment' }
    try { Remove-Item -LiteralPath $linkRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    # ---------- F2 (hardening A): recibo ILEGIVEL/truncado como UNICO bloqueio (outra chave) ----------
    # Bloqueador A1: um claimed desta task que ficou ilegivel NAO pode liberar
    # um segundo efeito. O diagnostico especifico (Read-NDReceipt) e so do
    # recibo PROPRIO da operacao; aqui o corrompido e OUTRA chave, entao a
    # varredura devolve o recuso generico claim-task-scan-unreadable.
    $fxh1 = New-HFIsolatedFixture -Suffix 'h1corr'
    $kh1a = Get-NativeDispatchHash32 'hf-h1corr-a'
    $ph1a = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh1.task -Key $kh1a -Gen $fxh1.gen) -Authorization $fxh1.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph1a.ok) '[B1a] first key prepared for the corrupt-only-blocker fixture' ([string]$ph1a.reason)
    $ch1a = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh1a -Authorization $fxh1.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph1a.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ch1a.ok) '[B1a] first key claims, effect open' ([string]$ch1a.reason)
    $h1aPath = Get-HFReceiptPath -GoalId $fxh1.goal -Key $kh1a
    $h1aGood = [IO.File]::ReadAllText($h1aPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($h1aPath, ('{"schema_version":1,"idempotency_key":"' + $kh1a + '","phase":"clai'), [Text.UTF8Encoding]::new($false))
    $kh1b = Get-NativeDispatchHash32 'hf-h1corr-b'
    $ph1b = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh1.task -Key $kh1b -Gen $fxh1.gen) -Authorization $fxh1.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph1b.ok) '[B1a] second key prepared (prepare is not an effect)' ([string]$ph1b.reason)
    $ch1b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh1b -Authorization $fxh1.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph1b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$ch1b.ok) -and (-not [bool]$ch1b.claimed) -and ([string]$ch1b.reason -ceq 'claim-task-scan-unreadable') -and ([int]$ch1b.executor_calls -eq 0)) '[B1a] a corrupt unresolved effect of the same task fails the scan closed (no second effect)' ([string]$ch1b.reason)
    $kh1bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxh1.goal -Key $kh1b), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kh1bRaw.phase -ceq 'prepared')) '[B1a] failed scan never consumes the second prepared receipt' ('phase=' + [string]$kh1bRaw.phase)
    [IO.File]::WriteAllText($h1aPath, $h1aGood, [Text.UTF8Encoding]::new($false))
    $ch1b2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh1b -Authorization $fxh1.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph1b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$ch1b2.ok) -and ([string]$ch1b2.reason -ceq 'claim-task-already-claimed')) '[B1a] control: restored valid claimed still refuses the second effect' ([string]$ch1b2.reason)

    # ---------- F2 (hardening B): recibo ILEGIVEL como UNICO bloqueio ENTRE goals ----------
    $fxh2 = New-HFIsolatedFixture -Suffix 'h2cross'
    $gH2Id = 'hf-goal-h2crossb'
    $gH2 = New-OrchestrationGoal -GoalId $gH2Id -Objective 'goal B cross corrupt' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$gH2.ok) '[B1b] second goal created' ([string]$gH2.reason)
    $gH2Act = Set-OrchestrationGoalState -Goal $gH2.goal -ToState 'ACTIVE'
    $gH2Sv = Save-OrchestrationGoal -Goal $gH2Act.goal -StoreDir $goalDir
    $gH2Own = Acquire-OrchestrationGoalOwnership -GoalId $gH2Id -OwnerId 'planner-1' -ExpectedRevision ([long]$gH2Sv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$gH2Own.ok) '[B1b] second goal owned' ([string]$gH2Own.reason)
    $gH2Gen = [long]$gH2Own.ownership['generation']
    $gH2Slot = Get-OrchestrationGoal -GoalId $gH2Id -StoreDir $goalDir
    $gH2Add = Add-OrchestrationGoalTaskPersisted -GoalId $gH2Id -TaskId $fxh2.task -ExpectedRevision ([long]$gH2Slot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gH2Gen
    Assert-HF ([bool]$gH2Add.ok) '[B1b] same task attached to the second goal' ([string]$gH2Add.reason)
    $authH2 = @{ explicit_allow = $true; goal_id = $gH2Id; owner = 'planner-1'; generation = $gH2Gen; source = 'planner' }
    $kh2a = Get-NativeDispatchHash32 'hf-h2cross-a'
    $ph2a = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh2.task -Key $kh2a -Gen $fxh2.gen) -Authorization $fxh2.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    $ch2a = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh2a -Authorization $fxh2.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph2a.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ch2a.ok) '[B1b] effect opened under goal A' ([string]$ch2a.reason)
    $h2aPath = Get-HFReceiptPath -GoalId $fxh2.goal -Key $kh2a
    $h2aGood = [IO.File]::ReadAllText($h2aPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($h2aPath, ('{"schema_version":1,"idempotency_key":"' + $kh2a + '","phase":"claim'), [Text.UTF8Encoding]::new($false))
    $kh2b = Get-NativeDispatchHash32 'hf-h2cross-b'
    $ph2b = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh2.task -Key $kh2b -Gen $gH2Gen) -Authorization $authH2 -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph2b.ok) '[B1b] prepared under goal B for the same task' ([string]$ph2b.reason)
    $ch2b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh2b -Authorization $authH2 -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph2b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$ch2b.ok) -and (-not [bool]$ch2b.claimed) -and ([string]$ch2b.reason -ceq 'claim-task-scan-unreadable') -and ([int]$ch2b.executor_calls -eq 0)) '[B1b] a corrupt cross-goal effect of the same task fails the scan closed' ([string]$ch2b.reason)
    $kh2bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $gH2Id -Key $kh2b), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kh2bRaw.phase -ceq 'prepared')) '[B1b] failed scan never consumes the goal-B prepared receipt' ('phase=' + [string]$kh2bRaw.phase)
    [IO.File]::WriteAllText($h2aPath, $h2aGood, [Text.UTF8Encoding]::new($false))

    # ---------- F2 (hardening C): task_id AUSENTE/INVALIDO nao e assumido "outra task" ----------
    $fxh3 = New-HFIsolatedFixture -Suffix 'h3tid'
    $kh3 = Get-NativeDispatchHash32 'hf-h3tid-key'
    $ph3 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh3.task -Key $kh3 -Gen $fxh3.gen) -Authorization $fxh3.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph3.ok) '[B1c] prepared for the missing-task-id fixture' ([string]$ph3.reason)
    $nsH3 = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxh3.goal
    $badTidKey = Get-NativeDispatchHash32 'hf-h3tid-badtask'
    $badTidPath = Join-Path $nsH3 ($badTidKey + '.json')
    [IO.File]::WriteAllText($badTidPath, ('{"schema_version":1,"idempotency_key":"' + $badTidKey + '","phase":"claimed","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxh3.goal + '"}'), [Text.UTF8Encoding]::new($false))
    $ch3 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh3 -Authorization $fxh3.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$ch3.ok) -and (-not [bool]$ch3.claimed) -and ([string]$ch3.reason -ceq 'claim-task-scan-unreadable') -and ([int]$ch3.executor_calls -eq 0)) '[B1c] a receipt-shaped record with missing task_id fails the scan closed (not assumed unrelated)' ([string]$ch3.reason)
    $kh3Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxh3.goal -Key $kh3), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kh3Raw.phase -ceq 'prepared')) '[B1c] failed scan never consumes the prepared receipt' ('phase=' + [string]$kh3Raw.phase)
    try { Remove-Item -LiteralPath $badTidPath -Force -ErrorAction SilentlyContinue } catch { }
    $ch3b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh3 -Authorization $fxh3.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ch3b.ok) '[B1c] control: the claim works once the unattributable record is gone' ([string]$ch3b.reason)

    # ---------- F2 (hardening D): entrada com nome de recibo que NAO e arquivo regular ----------
    $fxh4 = New-HFIsolatedFixture -Suffix 'h4dirent'
    $kh4 = Get-NativeDispatchHash32 'hf-h4dirent-key'
    $ph4 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh4.task -Key $kh4 -Gen $fxh4.gen) -Authorization $fxh4.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph4.ok) '[B2] prepared for the receipt-shaped directory fixture' ([string]$ph4.reason)
    $nsH4 = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxh4.goal
    $dirAsKey = Get-NativeDispatchHash32 'hf-h4dirent-dir'
    $dirAsPath = Join-Path $nsH4 ($dirAsKey + '.json')
    New-Item -ItemType Directory -Path $dirAsPath -Force | Out-Null
    $ch4 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh4 -Authorization $fxh4.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph4.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$ch4.ok) -and (-not [bool]$ch4.claimed) -and ([string]$ch4.reason -ceq 'claim-task-scan-unreadable') -and ([int]$ch4.executor_calls -eq 0)) '[B2] a receipt-named DIRECTORY fails the scan closed (EnumerateFileSystemEntries sees it)' ([string]$ch4.reason)
    $kh4Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxh4.goal -Key $kh4), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kh4Raw.phase -ceq 'prepared')) '[B2] failed scan never consumes the prepared receipt' ('phase=' + [string]$kh4Raw.phase)
    try { Remove-Item -LiteralPath $dirAsPath -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $ch4b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh4 -Authorization $fxh4.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph4.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ch4b.ok) '[B2] control: the claim works once the receipt-named directory is gone' ([string]$ch4b.reason)

    # ---------- F2 (hardening D-link): junction com nome de recibo (reparse) ----------
    $fxh5 = New-HFIsolatedFixture -Suffix 'h5link'
    $kh5 = Get-NativeDispatchHash32 'hf-h5link-key'
    $ph5 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxh5.task -Key $kh5 -Gen $fxh5.gen) -Authorization $fxh5.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$ph5.ok) '[B2] prepared for the receipt-named junction fixture' ([string]$ph5.reason)
    $nsH5 = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxh5.goal
    $lnkTgt = Join-Path $script:tempRoot ('h5target-' + [guid]::NewGuid().ToString('N'))
    $linkOkB = $false
    try {
        New-Item -ItemType Directory -Path $lnkTgt -Force | Out-Null
        $lnkKey = Get-NativeDispatchHash32 'hf-h5link-junction'
        $lnkPath = Join-Path $nsH5 ($lnkKey + '.json')
        try { cmd /c mklink /J "$lnkPath" "$lnkTgt" 2>&1 | Out-Null } catch { }
        if (-not (Test-Path -LiteralPath $lnkPath)) { try { New-Item -ItemType Junction -Path $lnkPath -Target $lnkTgt -ErrorAction Stop | Out-Null } catch { } }
        if (Test-Path -LiteralPath $lnkPath) { $linkOkB = $true }
    }
    catch { $linkOkB = $false }
    if ($linkOkB) {
        $ch5 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh5 -Authorization $fxh5.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph5.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$ch5.ok) -and (-not [bool]$ch5.claimed) -and ([string]$ch5.reason -ceq 'claim-task-scan-unreadable') -and ([int]$ch5.executor_calls -eq 0)) '[B2] a receipt-named JUNCTION fails the scan closed (reparse rejected)' ([string]$ch5.reason)
        $kh5Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxh5.goal -Key $kh5), [Text.Encoding]::UTF8))
        Assert-HF (([string]$kh5Raw.phase -ceq 'prepared')) '[B2] junction refusal never consumes the prepared receipt' ('phase=' + [string]$kh5Raw.phase)
        try { [IO.Directory]::Delete($lnkPath, $false) } catch { }
        $ch5b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kh5 -Authorization $fxh5.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$ph5.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$ch5b.ok) '[B2] control: the claim works once the junction is gone' ([string]$ch5b.reason)
    }
    else { Skip-HF 'B2 junction fixture unavailable in this environment' }

    # ---------- F2 (hardening F): estrutura validada ANTES de ignorar registro de OUTRA task ----------
    # Um registro so pode ser atribuido a outra task (e portanto ignorado
    # pela reserva) quando passa pela validacao estrutural FECHADA. Aqui um
    # registro MORADOR de outro namespace tem estrutura invalida de QUATRO
    # formas diferentes - schema desconhecido, chave divergente do nome do
    # arquivo, hash de namespace divergente do goal e (handoff) integridade
    # semantica adulterada - e NENHUMA delas pode liberar um efeito.
    $fxi = New-HFIsolatedFixture -Suffix 'zstruct'
    $kzi = Get-NativeDispatchHash32 'hf-zstruct-key'
    $pzi = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxi.task -Key $kzi -Gen $fxi.gen) -Authorization $fxi.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzi.ok) '[B4] prepared for the foreign-invalid-structure fixture' ([string]$pzi.reason)
    # controle: com os registros VALIDOS de outras tasks que a suite ja
    # deixou no namespace hospedeiro e nos demais, o claim passa - prova que
    # registro integro de outra task segue sendo ignorado.
    $czValid = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzi -Authorization $fxi.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzi.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$czValid.ok) -and ([bool]$czValid.claimed) -and ([string]$czValid.reason -ceq '')) '[B4a] control: valid foreign-task receipts do not block' ([string]$czValid.reason)
    # namespace hospede dos registros invalidos (diferente do da operacao).
    $nsHostId = 'hf-goal-zhost'
    $nsHostGoal = New-OrchestrationGoal -GoalId $nsHostId -Objective 'goal hospedeiro dos registros invalidos' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$nsHostGoal.ok) '[B4] host goal created' ([string]$nsHostGoal.reason)
    $nsHostAct = Set-OrchestrationGoalState -Goal $nsHostGoal.goal -ToState 'ACTIVE'
    $nsHostSv = Save-OrchestrationGoal -Goal $nsHostAct.goal -StoreDir $goalDir
    $nsHostOwn = Acquire-OrchestrationGoalOwnership -GoalId $nsHostId -OwnerId 'planner-1' -ExpectedRevision ([long]$nsHostSv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$nsHostOwn.ok) '[B4] host goal owned' ([string]$nsHostOwn.reason)
    $nsHost = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $nsHostId
    Assert-HF (($nsHost -ne '') -and (Test-Path -LiteralPath $nsHost -PathType Container)) '[B4] host namespace resolved' $nsHost
    # fixture proprio para os casos: task distinta, porque o controle acima
    # deixou um claimed aberto da task do fixture inicial.
    $fzi = New-HFIsolatedFixture -Suffix 'zstruct2'
    $kzi2 = Get-NativeDispatchHash32 'hf-zstruct-key-2'
    $pzi2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzi.task -Key $kzi2 -Gen $fzi.gen) -Authorization $fzi.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzi2.ok) '[B4] second fixture prepared for the invalid-structure cases' ([string]$pzi2.reason)
    $zBadCases = @(
        @{ tag = 'unknown-schema'; seed = 'hf-zstruct-schema'; body = '{"schema_version":9,"idempotency_key":"{KEY}","phase":"prepared","task_id":"hf-task-zhost","agent":"coder","owner":"planner-1","goal_id":"hf-goal-zhost","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'key-vs-filename'; seed = 'hf-zstruct-keydiv'; body = '{"schema_version":1,"idempotency_key":"{OTHER}","phase":"prepared","task_id":"hf-task-zhost","agent":"coder","owner":"planner-1","goal_id":"hf-goal-zhost","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'namespace-hash'; seed = 'hf-zstruct-nsdiv'; body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"prepared","task_id":"hf-task-zhost","agent":"coder","owner":"planner-1","goal_id":"hf-goal-1","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'semantic-integrity'; seed = 'hf-zstruct-tamper'; body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"prepared","handoff_state":"PREPARED","reference":"{REF}","task_id":"hf-task-zhost","agent":"coder","owner":"planner-1","goal_id":"hf-goal-zhost","ownership_generation":1,"task_expected_revision":1,"base_revision":"rev-a","prompt_hash":"{PH}","scope":["src/a.ps1"],"acceptance_criteria":["criterion:0"],"intent_fingerprint":"{FP}","prepared_fingerprint":"{PFP}","session_id":"ses_hf_TAMPERED","external_idempotent":false,"external_idempotency_proof":""}' }
    )
    $zFpSeed = (Get-NativeDispatchHash32 'hf-zstruct-fp-material')
    foreach ($zb in @($zBadCases)) {
        $zbKey = Get-NativeDispatchHash32 ([string]$zb.seed)
        $zbPath = Join-Path $nsHost ($zbKey + '.json')
        $zbBody = ([string]$zb.body).Replace('{KEY}', $zbKey).Replace('{OTHER}', (Get-NativeDispatchHash32 ('hf-zstruct-other-' + [string]$zb.tag))).Replace('{FP}', $zFpSeed).Replace('{PFP}', $zFpSeed).Replace('{REF}', $zFpSeed).Replace('{PH}', $zFpSeed)
        [IO.File]::WriteAllText($zbPath, $zbBody, [Text.UTF8Encoding]::new($false))
        $czBad = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzi2 -Authorization $fzi.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzi2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$czBad.ok) -and (-not [bool]$czBad.claimed) -and ([string]$czBad.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czBad.executor_calls -eq 0)) ('[B4] a foreign receipt with ' + [string]$zb.tag + ' fails the scan closed') ([string]$czBad.reason)
        $kzi2Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fzi.goal -Key $kzi2), [Text.Encoding]::UTF8))
        Assert-HF (([string]$kzi2Raw.phase -ceq 'prepared')) ('[B4] the ' + [string]$zb.tag + ' refusal never consumes the prepared receipt') ('phase=' + [string]$kzi2Raw.phase)
        try { Remove-Item -LiteralPath $zbPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    # controle final: sem os registros invalidos, o claim volta a funcionar.
    $czControl = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzi2 -Authorization $fzi.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzi2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$czControl.ok) -and ([bool]$czControl.claimed) -and ([string]$czControl.reason -ceq '')) '[B4] control: the claim works once every invalid foreign receipt is gone' ([string]$czControl.reason)

    # ---------- F2 (hardening G): UNICO bloqueio corrompido - CLAIM, legado e outro goal ----------
    # Bloqueador: quando o UNICO recibo nao-resolvido da task esta
    # corrompido (ilegivel/sem task_id), um SEGUNDO efeito - por outra
    # chave, por outro goal, pelo CLAIM nativo ou pelo Executor legado -
    # nao pode acontecer. Um recibo VALIDO de outra task fica presente de
    # proposito para provar que a varredura nao para no primeiro registro
    # integro e nao deixa o corrompido ser mascarado.
    $fzg = New-HFIsolatedFixture -Suffix 'zonly'
    $fzm = New-HFIsolatedFixture -Suffix 'zmask'
    $kzm = Get-NativeDispatchHash32 'hf-zmask-key'
    $pzm = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzm.task -Key $kzm -Gen $fzm.gen) -Authorization $fzm.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzm.ok) '[B1d] a VALID claimed receipt of ANOTHER task is seeded (must not mask the corrupt one)' ([string]$pzm.reason)
    $czm = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzm -Authorization $fzm.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzm.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$czm.ok) '[B1d] the masking receipt is an open effect of another task' ([string]$czm.reason)
    $kzg1 = Get-NativeDispatchHash32 'hf-zonly-open'
    $pzg1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzg.task -Key $kzg1 -Gen $fzg.gen) -Authorization $fzg.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzg1.ok) '[B1d] the only unresolved receipt of the task is prepared' ([string]$pzg1.reason)
    $czg1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzg1 -Authorization $fzg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzg1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$czg1.ok) '[B1d] the effect is open (claimed)' ([string]$czg1.reason)
    $zg1Path = Get-HFReceiptPath -GoalId $fzg.goal -Key $kzg1
    $zg1Good = [IO.File]::ReadAllText($zg1Path, [Text.Encoding]::UTF8)
    # o UNICO bloqueio fica corrompido: JSON truncado, sem task_id.
    [IO.File]::WriteAllText($zg1Path, ('{"schema_version":1,"idempotency_key":"' + $kzg1 + '","phase":"clai'), [Text.UTF8Encoding]::new($false))
    # (a) segunda chave da MESMA task, MESMO goal -> CLAIM recusa.
    $kzg2 = Get-NativeDispatchHash32 'hf-zonly-second'
    $pzg2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzg.task -Key $kzg2 -Gen $fzg.gen) -Authorization $fzg.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzg2.ok) '[B1d] second key of the same task prepared (prepare is not an effect)' ([string]$pzg2.reason)
    $czg2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzg2 -Authorization $fzg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzg2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$czg2.ok) -and (-not [bool]$czg2.claimed) -and ([string]$czg2.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czg2.executor_calls -eq 0)) '[B1d] a corrupt-only blocker refuses the second key of the same task' ([string]$czg2.reason)
    $kzg2Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fzg.goal -Key $kzg2), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kzg2Raw.phase -ceq 'prepared')) '[B1d] the refused second receipt stays prepared' ('phase=' + [string]$kzg2Raw.phase)
    # (b) Invoke LEGADO da MESMA task, chave nova -> Executor nao roda.
    $kzg3 = Get-NativeDispatchHash32 'hf-zonly-legacy'
    $zg3SpyState = @{ calls = 0 }
    $zg3Spy = { param($i) $zg3SpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lzg3 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fzg.task -Key $kzg3 -Gen $fzg.gen).intent -Executor $zg3Spy -Authorization $fzg.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lzg3.ok) -and ([string]$lzg3.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lzg3.executor_calls -eq 0) -and ([int]$zg3SpyState.calls -eq 0)) '[B1d] the corrupt-only blocker also refuses the legacy Invoke (executor spy 0)' ([string]$lzg3.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fzg.goal -Key $kzg3) -PathType Leaf)) '[B1d] the refused legacy dispatch persisted nothing' ''
    # (c) OUTRO goal, MESMA task: CLAIM e Invoke legado recusam.
    $gZId = 'hf-goal-zonly-b'
    $gZ = New-OrchestrationGoal -GoalId $gZId -Objective 'goal B do bloqueio corrompido' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$gZ.ok) '[B1e] second goal created' ([string]$gZ.reason)
    $gZAct = Set-OrchestrationGoalState -Goal $gZ.goal -ToState 'ACTIVE'
    $gZSv = Save-OrchestrationGoal -Goal $gZAct.goal -StoreDir $goalDir
    $gZOwn = Acquire-OrchestrationGoalOwnership -GoalId $gZId -OwnerId 'planner-1' -ExpectedRevision ([long]$gZSv.revision) -StoreDir $goalDir
    Assert-HF ([bool]$gZOwn.ok) '[B1e] second goal owned' ([string]$gZOwn.reason)
    $gZGen = [long]$gZOwn.ownership['generation']
    $gZSlot = Get-OrchestrationGoal -GoalId $gZId -StoreDir $goalDir
    $gZAdd = Add-OrchestrationGoalTaskPersisted -GoalId $gZId -TaskId $fzg.task -ExpectedRevision ([long]$gZSlot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gZGen
    Assert-HF ([bool]$gZAdd.ok) '[B1e] the same task attached to the second goal' ([string]$gZAdd.reason)
    $authZ = @{ explicit_allow = $true; goal_id = $gZId; owner = 'planner-1'; generation = $gZGen; source = 'planner' }
    $kzh1 = Get-NativeDispatchHash32 'hf-zonly-othergoal-claim'
    $pzh1 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzg.task -Key $kzh1 -Gen $gZGen) -Authorization $authZ -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzh1.ok) '[B1e] prepared under the second goal for the same task' ([string]$pzh1.reason)
    $czh1 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzh1 -Authorization $authZ -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzh1.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$czh1.ok) -and (-not [bool]$czh1.claimed) -and ([string]$czh1.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czh1.executor_calls -eq 0)) '[B1e] the corrupt-only blocker refuses the CLAIM of ANOTHER goal' ([string]$czh1.reason)
    $kzh2 = Get-NativeDispatchHash32 'hf-zonly-othergoal-legacy'
    $zh2SpyState = @{ calls = 0 }
    $zh2Spy = { param($i) $zh2SpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lzh2 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fzg.task -Key $kzh2 -Gen $gZGen).intent -Executor $zh2Spy -Authorization $authZ -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lzh2.ok) -and ([string]$lzh2.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lzh2.executor_calls -eq 0) -and ([int]$zh2SpyState.calls -eq 0)) '[B1e] the corrupt-only blocker also refuses the legacy Invoke of ANOTHER goal (executor spy 0)' ([string]$lzh2.reason)
    # (d) controle: restaurado o recibo valido, a recusa volta a ser a
    #     reserva normal - prova que o corrompido era o UNICO bloqueio e
    #     que nenhum registro valido o mascarou.
    [IO.File]::WriteAllText($zg1Path, $zg1Good, [Text.UTF8Encoding]::new($false))
    $czg2b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzg2 -Authorization $fzg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzg2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$czg2b.ok) -and ([string]$czg2b.reason -ceq 'claim-task-already-claimed')) '[B1d] control: the restored valid receipt refuses with the reservation reason' ([string]$czg2b.reason)
    # (e) o MESMO cenario com task_id AUSENTE e com task_id INVALIDO: sem
    #     identidade recuperavel o registro nao pode ser atribuido a outra
    #     task, e a incerteza nao pode liberar um segundo efeito.
    $zgBadTaskBodies = @(
        @{ tag = 'missing task_id'; body = ('{"schema_version":1,"idempotency_key":"' + $kzg1 + '","phase":"claimed","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fzg.goal + '"}') }
        @{ tag = 'invalid task_id'; body = ('{"schema_version":1,"idempotency_key":"' + $kzg1 + '","phase":"claimed","task_id":"TASK INVALIDA!!","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fzg.goal + '"}') }
    )
    foreach ($zbt in @($zgBadTaskBodies)) {
        [IO.File]::WriteAllText($zg1Path, ([string]$zbt.body), [Text.UTF8Encoding]::new($false))
        $kzg4 = Get-NativeDispatchHash32 ('hf-zonly-notid-' + [string]$zbt.tag)
        $zg4SpyState = @{ calls = 0 }
        $zg4Spy = { param($i) $zg4SpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $lzg4 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fzg.task -Key $kzg4 -Gen $gZGen).intent -Executor $zg4Spy -Authorization $authZ -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$lzg4.ok) -and ([string]$lzg4.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lzg4.executor_calls -eq 0) -and ([int]$zg4SpyState.calls -eq 0)) ('[B1d] an only-unresolved receipt with ' + [string]$zbt.tag + ' refuses the legacy Invoke of ANOTHER goal (executor spy 0)') ([string]$lzg4.reason)
        $czg5 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzg2 -Authorization $fzg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzg2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$czg5.ok) -and (-not [bool]$czg5.claimed) -and ([string]$czg5.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czg5.executor_calls -eq 0)) ('[B1d] an only-unresolved receipt with ' + [string]$zbt.tag + ' refuses the CLAIM of the second key') ([string]$czg5.reason)
    }
    # controle final: recibo valido de volta, a reserva volta a ser a razao.
    [IO.File]::WriteAllText($zg1Path, $zg1Good, [Text.UTF8Encoding]::new($false))
    $czg2c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzg2 -Authorization $fzg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzg2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$czg2c.ok) -and ([string]$czg2c.reason -ceq 'claim-task-already-claimed')) '[B1d] control: with a readable receipt the reservation reason is back' ([string]$czg2c.reason)

    # ---------- F2 (hardening H): entrada com nome de recibo em OUTRO namespace ----------
    # O diretorio/junction `<chave>.json` nao precisa estar no namespace da
    # operacao para esconder um recibo: a varredura caminha TODAS as
    # namespaces sob a raiz. Aqui o hostil mora no namespace do segundo
    # goal (criado no bloco acima), nunca no namespace da operacao.
    $nsZHost = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $gZId
    Assert-HF (($nsZHost -ne '') -and (Test-Path -LiteralPath $nsZHost -PathType Container)) '[B2b] the foreign namespace exists' $nsZHost
    $fzd = New-HFIsolatedFixture -Suffix 'zdirent'
    $kzd = Get-NativeDispatchHash32 'hf-zdirent-key'
    $pzd = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzd.task -Key $kzd -Gen $fzd.gen) -Authorization $fzd.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzd.ok) '[B2b] prepared for the foreign-namespace directory fixture' ([string]$pzd.reason)
    $zDirKey = Get-NativeDispatchHash32 'hf-zdirent-foreign-dir'
    $zDirPath = Join-Path $nsZHost ($zDirKey + '.json')
    New-Item -ItemType Directory -Path $zDirPath -Force | Out-Null
    $czd = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzd -Authorization $fzd.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzd.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$czd.ok) -and (-not [bool]$czd.claimed) -and ([string]$czd.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czd.executor_calls -eq 0)) '[B2b] a receipt-named DIRECTORY in ANOTHER namespace fails the scan closed' ([string]$czd.reason)
    $kzdRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fzd.goal -Key $kzd), [Text.Encoding]::UTF8))
    Assert-HF (([string]$kzdRaw.phase -ceq 'prepared')) '[B2b] the foreign-directory refusal never consumes the prepared receipt' ('phase=' + [string]$kzdRaw.phase)
    try { Remove-Item -LiteralPath $zDirPath -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    $czdb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzd -Authorization $fzd.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzd.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$czdb.ok) '[B2b] control: the claim works once the foreign-namespace directory is gone' ([string]$czdb.reason)
    # junction com nome de recibo em OUTRO namespace.
    $fzj = New-HFIsolatedFixture -Suffix 'zjunc'
    $kzj = Get-NativeDispatchHash32 'hf-zjunc-key'
    $pzj = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fzj.task -Key $kzj -Gen $fzj.gen) -Authorization $fzj.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pzj.ok) '[B2b] prepared for the foreign-namespace junction fixture' ([string]$pzj.reason)
    $zJuncTgt = Join-Path $script:tempRoot ('zjunc-target-' + [guid]::NewGuid().ToString('N'))
    $zLinkOk = $false
    try {
        New-Item -ItemType Directory -Path $zJuncTgt -Force | Out-Null
        $zJuncKey = Get-NativeDispatchHash32 'hf-zjunc-foreign-junction'
        $zJuncPath = Join-Path $nsZHost ($zJuncKey + '.json')
        try { cmd /c mklink /J "$zJuncPath" "$zJuncTgt" 2>&1 | Out-Null } catch { }
        if (-not (Test-Path -LiteralPath $zJuncPath)) { try { New-Item -ItemType Junction -Path $zJuncPath -Target $zJuncTgt -ErrorAction Stop | Out-Null } catch { } }
        if (Test-Path -LiteralPath $zJuncPath) { $zLinkOk = $true }
    }
    catch { $zLinkOk = $false }
    if ($zLinkOk) {
        $czj = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzj -Authorization $fzj.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzj.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$czj.ok) -and (-not [bool]$czj.claimed) -and ([string]$czj.reason -ceq 'claim-task-scan-unreadable') -and ([int]$czj.executor_calls -eq 0)) '[B2b] a receipt-named JUNCTION in ANOTHER namespace fails the scan closed' ([string]$czj.reason)
        $kzjRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fzj.goal -Key $kzj), [Text.Encoding]::UTF8))
        Assert-HF (([string]$kzjRaw.phase -ceq 'prepared')) '[B2b] the foreign-junction refusal never consumes the prepared receipt' ('phase=' + [string]$kzjRaw.phase)
        try { [IO.Directory]::Delete($zJuncPath, $false) } catch { }
        $czjb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kzj -Authorization $fzj.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pzj.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$czjb.ok) '[B2b] control: the claim works once the foreign-namespace junction is gone' ([string]$czjb.reason)
    }
    else { Skip-HF 'B2b foreign-namespace junction fixture unavailable in this environment' }

    # ---------- F2 (hardening E): cap GLOBAL de entradas entre TODAS as namespaces ----------
    $gcapRoot = Join-Path $script:tempRoot 'receipts-gcap'
    New-Item -ItemType Directory -Path $gcapRoot -Force | Out-Null
    $gcapOk = $false
    try {
        $fxg = New-HFIsolatedFixture -Suffix 'gcap'
        $kgc = Get-NativeDispatchHash32 'hf-gcap-key'
        $pgc = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxg.task -Key $kgc -Gen $fxg.gen) -Authorization $fxg.auth -SessionId $session -ReceiptDir $gcapRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        if ([bool]$pgc.ok) {
            # speedup SAFE de setup: uma unica instancia de encoder para
            # os 4300 arquivos (o literal `[Text.UTF8Encoding]::new($false)`
            # por arquivo alocava um encoder a cada WriteAllText) e join de
            # caminho por concatenacao direta, sem o cmdlet Join-Path por
            # arquivo. O estado em disco exercitado e IDENTICO: mesmos
            # nomes, mesmo conteudo 'x', mesmo UTF-8 sem BOM.
            $gcapUtf8 = [Text.UTF8Encoding]::new($false)
            $gcapSep = [string][IO.Path]::DirectorySeparatorChar
            for ($gi = 0; $gi -lt 10; $gi++) {
                $nsNameG = (Get-NativeDispatchHash32 ('hf-gcap-ns-' + $gi)).PadRight(32, '0').Substring(0, 32)
                $nsDirG = Join-Path $gcapRoot $nsNameG
                New-Item -ItemType Directory -Path $nsDirG -Force | Out-Null
                $nsPrefixG = ($nsDirG + $gcapSep)
                for ($fj = 0; $fj -lt 430; $fj++) {
                    [IO.File]::WriteAllText(($nsPrefixG + 'bulk-' + $fj + '.tmp'), 'x', $gcapUtf8)
                }
            }
            $cgc = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kgc -Authorization $fxg.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pgc.prepared_fingerprint) -ReceiptDir $gcapRoot -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
            Assert-HF ((-not [bool]$cgc.ok) -and (-not [bool]$cgc.claimed) -and ([string]$cgc.reason -ceq 'claim-task-scan-unbounded') -and ([int]$cgc.executor_calls -eq 0)) '[B3] total entries above the GLOBAL cap fails the scan closed' ([string]$cgc.reason)
            $kgcRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path (Get-NDGoalReceiptDir -RootDir $gcapRoot -GoalId $fxg.goal) ($kgc + '.json')), [Text.Encoding]::UTF8))
            Assert-HF (([string]$kgcRaw.phase -ceq 'prepared')) '[B3] capped scan never consumes the prepared receipt' ('phase=' + [string]$kgcRaw.phase)
            $gcapOk = $true
        }
    }
    catch { $gcapOk = $false }
    if (-not $gcapOk) { Skip-HF 'B3 global-cap fixture unavailable in this environment' }
    try { Remove-Item -LiteralPath $gcapRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    # ---------- F3: integridade semantica do registro (um campo por vez) ----------
    $ff3 = New-HFIsolatedFixture -Suffix 'f3'
    $kf3x = Get-NativeDispatchHash32 'hf-f3-prepare-1'
    $pf3x = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff3.task -Key $kf3x -Gen $ff3.gen) -Authorization $ff3.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pf3x.ok) '[F3] prepared for the integrity fixture' ([string]$pf3x.reason)
    $f3Path = Get-HFReceiptPath -GoalId $ff3.goal -Key $kf3x
    $f3Good = [IO.File]::ReadAllText($f3Path, [Text.Encoding]::UTF8)
    $f3Fp = [string]$pf3x.prepared_fingerprint
    $f3Tampers = @(
        @{ name = 'prompt_hash'; field = 'prompt_hash'; value = (Get-NativeDispatchHash32 'hf-tamper-prompt-material') },
        @{ name = 'scope'; field = 'scope'; value = @('src/tampered.ps1') },
        @{ name = 'acceptance_criteria'; field = 'acceptance_criteria'; value = @('criterion:9') },
        @{ name = 'session_id'; field = 'session_id'; value = 'ses_hf_TAMPERED' },
        @{ name = 'task_id'; field = 'task_id'; value = 'hf-task-f3-alt' },
        @{ name = 'agent'; field = 'agent'; value = 'tester' }
    )
    foreach ($t in @($f3Tampers)) {
        $raw = ConvertFrom-Json $f3Good
        Add-Member -InputObject $raw -Name ([string]$t.field) -Value $t.value -MemberType NoteProperty -Force
        [IO.File]::WriteAllText($f3Path, (ConvertTo-Json -InputObject $raw -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $pt = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff3.task -Key $kf3x -Gen $ff3.gen) -Authorization $ff3.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$pt.ok) -and (-not [bool]$pt.reused) -and ([string]$pt.reason -ceq 'receipt-integrity-invalid')) ('[F3] tampered ' + [string]$t.name + ' refuses prepare reuse') ([string]$pt.reason)
        $ct = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kf3x -Authorization $ff3.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $f3Fp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$ct.ok) -and (-not [bool]$ct.claimed) -and ([string]$ct.reason -ceq 'receipt-integrity-invalid') -and ([int]$ct.executor_calls -eq 0)) ('[F3] tampered ' + [string]$t.name + ' refuses claim') ([string]$ct.reason)
        $tamperedPhase = ConvertFrom-Json ([IO.File]::ReadAllText($f3Path, [Text.Encoding]::UTF8))
        Assert-HF (([string]$tamperedPhase.phase -ceq 'prepared')) ('[F3] tampered ' + [string]$t.name + ' receipt is never rewritten by the refusal') ('phase=' + [string]$tamperedPhase.phase)
        [IO.File]::WriteAllText($f3Path, $f3Good, [Text.UTF8Encoding]::new($false))
    }
    $pf3ok = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $ff3.task -Key $kf3x -Gen $ff3.gen) -Authorization $ff3.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$pf3ok.ok) -and ([bool]$pf3ok.reused)) '[F3] control: untampered record is reusable again' ([string]$pf3ok.reason)
    $cf3 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kf3x -Authorization $ff3.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $f3Fp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cf3.ok) -and ([bool]$cf3.claimed)) '[F3] control: untampered record is claimable' ([string]$cf3.reason)

    # ---------- PRA-1: efeito externo real + excecao do Executor deixa o
    # recibo NAO-RESOLVIDO e a task reservada (regressao do achado F3) ----------
    # O spy REGISTRA um efeito externo simulado e SO ENTAO lanca: isso prova
    # que o Executor rodou e que um efeito pode ter ocorrido. O recibo NAO
    # pode liquidar em 'settled' (liberaria a reserva) e uma SEGUNDA chave
    # da MESMA task tem de ser negada enquanto o efeito segue incerto.
    $fxEx = New-HFIsolatedFixture -Suffix 'exthrow'
    $kEx1 = Get-NativeDispatchHash32 'hf-exthrow-1'
    $exState = @{ calls = 0; effect = '' }
    $exSpy = { param($i) $exState.calls++; $exState.effect = 'external-effect-occurred'; throw 'simulated-post-effect-boom' }.GetNewClosure()
    $lEx1 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxEx.task -Key $kEx1 -Gen $fxEx.gen).intent -Executor $exSpy -Authorization $fxEx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lEx1.ok) -and ([string]$lEx1.reason -ceq 'executor-failed') -and ([int]$lEx1.executor_calls -eq 1) -and ([int]$exState.calls -eq 1) -and ([string]$exState.effect -ceq 'external-effect-occurred')) '[PRA-1] post-effect Executor exception still accounts the effect (executor-failed, calls=1)' (([string]$lEx1.reason) + ' calls=' + [string]$lEx1.executor_calls)
    $ex1Raw = $null
    try { $ex1Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxEx.goal -Key $kEx1), [Text.Encoding]::UTF8)) } catch { $ex1Raw = $null }
    Assert-HF (($null -ne $ex1Raw) -and ([string]$ex1Raw.phase -ceq 'pending') -and ($null -eq $ex1Raw.PSObject.Properties['settled_at'])) '[PRA-1] the receipt stays UNRESOLVED (pending), never settled after a possible effect' ('phase=' + [string]$ex1Raw.phase)
    $kEx2 = Get-NativeDispatchHash32 'hf-exthrow-2'
    $ex2State = @{ calls = 0 }
    $ex2Spy = { param($i) $ex2State.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lEx2 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxEx.task -Key $kEx2 -Gen $fxEx.gen).intent -Executor $ex2Spy -Authorization $fxEx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lEx2.ok) -and ([string]$lEx2.reason -ceq 'claim-task-already-claimed') -and ([int]$lEx2.executor_calls -eq 0) -and ([int]$ex2State.calls -eq 0)) '[PRA-1] a SECOND key on the same task is DENIED while the effect is unresolved' ([string]$lEx2.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxEx.goal -Key $kEx2) -PathType Leaf)) '[PRA-1] the denied second key persisted nothing' ''

    # ---------- PRA-2: replay recusado por fencing pos-lock deixa o pending
    # ORIGINAL intacto (nunca liquida em settled-failure) ----------
    $fxFc = New-HFIsolatedFixture -Suffix 'repfence'
    $kFc = Get-NativeDispatchHash32 'hf-repfence-1'
    $iFc = New-HFIntent -Task $fxFc.task -Key $kFc -Gen $fxFc.gen -Ext $true -Proof 'sink dedupes by idempotency key (repfence)'
    Assert-HF ([bool]$iFc.ok) '[PRA-2] external-idempotent replay intent built' ([string]$iFc.reason)
    $fcFp = Get-NDIntentFingerprint -Intent $iFc.intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $fxFc.goal -Key $kFc), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kFc; phase = 'pending'; task_id = $fxFc.task; agent = 'coder'; owner = 'planner-1'; goal_id = $fxFc.goal; ownership_generation = $fxFc.gen; task_expected_revision = 1; intent_fingerprint = $fcFp; external_idempotent = $true; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    # lock contido + goal fora de ACTIVE: o gate pre-lock passa (PAUSED nao e
    # terminal) e a recusa so pode vir da releitura viva sob o lock.
    $heldFc = Open-HFReceiptLockHeld -GoalId $fxFc.goal
    if ($null -ne $heldFc) {
        try { $pausedFc = Set-HFGoalStateLive -GoalId $fxFc.goal -ToState 'PAUSED' -Gen $fxFc.gen; Assert-HF ([bool]$pausedFc.ok) '[PRA-2] goal left ACTIVE while the replay would settle' ([string]$pausedFc.reason) }
        finally { try { $heldFc.Dispose() } catch { } }
    }
    $fcState = @{ calls = 0 }
    $fcSpy = { param($i) $fcState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lFc = Invoke-OrchestrationNativeDispatch -Intent $iFc.intent -Executor $fcSpy -Authorization $fxFc.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lFc.ok) -and ([string]$lFc.reason -like 'post-lock-*') -and ([int]$lFc.executor_calls -eq 0) -and ([int]$fcState.calls -eq 0)) '[PRA-2] the replay is refused by post-lock fencing with 0 executor calls' ([string]$lFc.reason)
    $fcStored = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxFc.goal -Key $kFc), [Text.Encoding]::UTF8))
    Assert-HF (([string]$fcStored.phase -ceq 'pending') -and ($null -eq $fcStored.PSObject.Properties['settled_at']) -and ($null -eq $fcStored.PSObject.Properties['kernel_ok']) -and (([string]$fcStored.intent_fingerprint) -ceq $fcFp) -and ([bool]$fcStored.external_idempotent)) '[PRA-2] the ORIGINAL pending is NOT overwritten with settled-failure (phase=pending, identity preserved)' ('phase=' + [string]$fcStored.phase)
    $backFc = Set-HFGoalStateLive -GoalId $fxFc.goal -ToState 'ACTIVE' -Gen $fxFc.gen
    Assert-HF ([bool]$backFc.ok) '[PRA-2] goal restored to ACTIVE' ([string]$backFc.reason)
    # prova real: a task segue RESERVADA (pending intacto) -> 2a chave negada.
    $kFc2 = Get-NativeDispatchHash32 'hf-repfence-2'
    $fc2State = @{ calls = 0 }
    $fc2Spy = { param($i) $fc2State.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lFc2 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxFc.task -Key $kFc2 -Gen $fxFc.gen).intent -Executor $fc2Spy -Authorization $fxFc.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lFc2.ok) -and ([string]$lFc2.reason -ceq 'claim-task-already-claimed') -and ([int]$fc2State.calls -eq 0)) '[PRA-2] the refused replay kept the task reserved: a second key is refused' ([string]$lFc2.reason)

    # ---------- PRA-3: campos numericos JSON booleanos/fracionarios e de
    # identidade nao-string falham a varredura fechada (sem coercao) ----------
    $fxPn = New-HFIsolatedFixture -Suffix 'pnum'
    $nsHostIdP = 'hf-goal-pnumhost'
    $nsHostGoalP = New-OrchestrationGoal -GoalId $nsHostIdP -Objective 'host dos registros invalidos PRA' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$nsHostGoalP.ok) '[PRA-3] host goal created' ([string]$nsHostGoalP.reason)
    $nsHostActP = Set-OrchestrationGoalState -Goal $nsHostGoalP.goal -ToState 'ACTIVE'
    $nsHostSvP = Save-OrchestrationGoal -Goal $nsHostActP.goal -StoreDir $goalDir
    $null = Acquire-OrchestrationGoalOwnership -GoalId $nsHostIdP -OwnerId 'planner-1' -ExpectedRevision ([long]$nsHostSvP.revision) -StoreDir $goalDir | Out-Null
    $nsHostDirP = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $nsHostIdP
    Assert-HF (($nsHostDirP -ne '') -and (Test-Path -LiteralPath $nsHostDirP -PathType Container)) '[PRA-3] host namespace resolved' $nsHostDirP
    $kPn = Get-NativeDispatchHash32 'hf-pnum-key'
    $pPn = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxPn.task -Key $kPn -Gen $fxPn.gen) -Authorization $fxPn.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pPn.ok) '[PRA-3] prepared for the numeric-coercion fixture' ([string]$pPn.reason)
    $pFpSeed = (Get-NativeDispatchHash32 'hf-pnum-fp-material')
    # Cada registro e de OUTRA task e estruturalmente valido EXCETO UM campo,
    # cujo valor e booleano/fracionario (numerico) ou nao-string (identidade).
    # Sem a checagem do tipo do token, [long]$true=1, [long]1.0=1 e
    # [string]$true='True' fariam o campo passar e o registro seria IGNORADO
    # como de outra task, liberando a reserva. Agora todos recusam.
    $pBadCases = @(
        @{ tag = 'schema-bool';           body = '{"schema_version":true,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'schema-fractional';     body = '{"schema_version":1.0,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'generation-bool';       body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":true,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'generation-fractional'; body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1.5,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'revision-bool';         body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":true,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'revision-fractional';   body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1.9,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'agent-bool';            body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":true,"owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'owner-bool';            body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-pnhost","agent":"coder","owner":true,"goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
    )
    foreach ($pb in @($pBadCases)) {
        $pbKey = Get-NativeDispatchHash32 ('hf-pnum-' + [string]$pb.tag)
        $pbPath = Join-Path $nsHostDirP ($pbKey + '.json')
        $pbBody = ([string]$pb.body).Replace('{KEY}', $pbKey).Replace('{G}', $nsHostIdP).Replace('{FP}', $pFpSeed)
        [IO.File]::WriteAllText($pbPath, $pbBody, [Text.UTF8Encoding]::new($false))
        $cpBad = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kPn -Authorization $fxPn.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pPn.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$cpBad.ok) -and (-not [bool]$cpBad.claimed) -and ([string]$cpBad.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cpBad.executor_calls -eq 0)) ('[PRA-3] a foreign receipt with ' + [string]$pb.tag + ' fails the scan closed (no numeric/type coercion)') ([string]$cpBad.reason)
        $kPnRawP = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxPn.goal -Key $kPn), [Text.Encoding]::UTF8))
        Assert-HF ([string]$kPnRawP.phase -ceq 'prepared') ('[PRA-3] ' + [string]$pb.tag + ' refusal never consumes the prepared receipt') ('phase=' + [string]$kPnRawP.phase)
        try { Remove-Item -LiteralPath $pbPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    $cpControl = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kPn -Authorization $fxPn.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pPn.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cpControl.ok) -and ([bool]$cpControl.claimed)) '[PRA-3] control: the claim works once every malformed foreign receipt is gone' ([string]$cpControl.reason)

    # ---------- PRA-4: enumeracao incremental para em cap+1 sem materializar
    # a lista inteira (enumerador .NET explicito de Invoke-NDIncrementalWalk) ----------
    $praEnumOk = $false
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
public class NDCountEnum : IEnumerable<string> {
    public int Total = 2000;
    public int Pulled = 0;
    public bool FullyWalked = false;
    public IEnumerator<string> GetEnumerator() { return new NDCountInner(this); }
    IEnumerator IEnumerable.GetEnumerator() { return GetEnumerator(); }
    private class NDCountInner : IEnumerator<string> {
        private NDCountEnum owner; private int idx = -1; private string cur;
        public NDCountInner(NDCountEnum o) { owner = o; }
        public string Current { get { return cur; } }
        object IEnumerator.Current { get { return cur; } }
        public bool MoveNext() {
            idx++;
            if (idx >= owner.Total) { owner.FullyWalked = true; return false; }
            owner.Pulled = idx + 1; cur = "i" + idx; return true;
        }
        public void Reset() { idx = -1; cur = null; }
        public void Dispose() { }
    }
}
'@ -ErrorAction Stop
        $praEnumOk = $true
    }
    catch { $praEnumOk = $false }
    if ($praEnumOk) {
        $cntSrc = New-Object NDCountEnum
        $walk = Invoke-NDIncrementalWalk -Source $cntSrc -Cap 512 -OnItem { param($x) return '' }
        Assert-HF ((-not [bool]$walk.ok) -and ([string]$walk.reason -ceq 'walk-cap-exceeded') -and ([int]$walk.seen -eq 513)) '[PRA-4] capped walk stops with walk-cap-exceeded at seen=513' ('reason=' + [string]$walk.reason + ' seen=' + [string]$walk.seen)
        Assert-HF (([int]$cntSrc.Pulled -eq 513) -and (-not [bool]$cntSrc.FullyWalked)) '[PRA-4] the enumerator stopped at cap+1 (513) WITHOUT fully materializing all 2000 items' ('pulled=' + [string]$cntSrc.Pulled + ' fullyWalked=' + [string]$cntSrc.FullyWalked)
        $smallSrc = New-Object NDCountEnum
        $smallSrc.Total = 10
        $walkSmall = Invoke-NDIncrementalWalk -Source $smallSrc -Cap 512 -OnItem { param($x) return '' }
        Assert-HF (([bool]$walkSmall.ok) -and ([int]$smallSrc.Pulled -eq 10) -and ([bool]$smallSrc.FullyWalked)) '[PRA-4] control: a source under the cap is fully walked and reports ok' ('pulled=' + [string]$smallSrc.Pulled)
        $stopSrc = New-Object NDCountEnum
        $stopWalk = Invoke-NDIncrementalWalk -Source $stopSrc -Cap 512 -OnItem { param($x) return 'stop-now' }
        Assert-HF ((-not [bool]$stopWalk.ok) -and ([string]$stopWalk.reason -ceq 'stop-now') -and ([int]$stopSrc.Pulled -eq 1) -and (-not [bool]$stopSrc.FullyWalked)) '[PRA-4] a callback stop-signal halts the walk at that item (pulled=1)' ('reason=' + [string]$stopWalk.reason + ' pulled=' + [string]$stopSrc.Pulled)
    }
    else { Skip-HF 'PRA-4 incremental-enumeration fixture unavailable in this environment' }

    # ---------- PRA-5: token JSON de ARRAY de um elemento nao chega como
    # escalar (leitura crua da propriedade, sem pipeline/coercao) ----------
    # `Get-NDValue` devolve o valor pelo pipeline de saida e o PowerShell
    # DESENROLA colecao nesse caminho: `[1]`, `["x"]` e `["pending"]`
    # chegariam ao validador como 1 / 'x' / 'pending' e passariam pela
    # coercao [long]/[string]. A varredura fechada e a leitura do recibo
    # agora leem o TOKEN cru (Get-NDJson*Value) e recusam fail-closed.
    $fxTok = New-HFIsolatedFixture -Suffix 'tok'
    $nsHostIdTok = 'hf-goal-tokhost'
    $nsHostGoalTok = New-OrchestrationGoal -GoalId $nsHostIdTok -Objective 'host dos registros com token array' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$nsHostGoalTok.ok) '[PRA-5] host goal created' ([string]$nsHostGoalTok.reason)
    $nsHostActTok = Set-OrchestrationGoalState -Goal $nsHostGoalTok.goal -ToState 'ACTIVE'
    $nsHostSvTok = Save-OrchestrationGoal -Goal $nsHostActTok.goal -StoreDir $goalDir
    $null = Acquire-OrchestrationGoalOwnership -GoalId $nsHostIdTok -OwnerId 'planner-1' -ExpectedRevision ([long]$nsHostSvTok.revision) -StoreDir $goalDir | Out-Null
    $nsHostDirTok = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $nsHostIdTok
    Assert-HF (($nsHostDirTok -ne '') -and (Test-Path -LiteralPath $nsHostDirTok -PathType Container)) '[PRA-5] host namespace resolved' $nsHostDirTok
    $kTok = Get-NativeDispatchHash32 'hf-tok-key'
    $iTok = New-HFIntent -Task $fxTok.task -Key $kTok -Gen $fxTok.gen
    Assert-HF ([bool]$iTok.ok) '[PRA-5] intent built for the token-shape fixture' ([string]$iTok.reason)
    $pTok = Invoke-OrchestrationNativeDispatchPrepare -Intent $iTok.intent -Authorization $fxTok.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pTok.ok) '[PRA-5] prepared for the token-shape fixture' ([string]$pTok.reason)
    $fpSeedTok = (Get-NativeDispatchHash32 'hf-tok-fp-material')
    # Cada registro e de OUTRA task ('hf-task-tokhost') e estruturalmente
    # valido EXCETO UM campo, cujo token e um array de um elemento. Se o
    # array chegasse como escalar, o registro seria aceito, atribuido a
    # outra task e IGNORADO - e o claim da task reservada passaria.
    $tokScanCases = @(
        @{ tag = 'schema-array';   body = '{"schema_version":[1],"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'task-array';     body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":["hf-task-tokhost"],"agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'phase-array';    body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":["pending"],"task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'generation-array'; body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":[1],"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'revision-array'; body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":[1],"intent_fingerprint":"{FP}"}' }
        @{ tag = 'key-array';      body = '{"schema_version":1,"idempotency_key":["{KEY}"],"phase":"pending","task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'goal-array';     body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-tokhost","agent":"coder","owner":"planner-1","goal_id":["{G}"],"ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
        @{ tag = 'agent-array';    body = '{"schema_version":1,"idempotency_key":"{KEY}","phase":"pending","task_id":"hf-task-tokhost","agent":["coder"],"owner":"planner-1","goal_id":"{G}","ownership_generation":1,"task_expected_revision":1,"intent_fingerprint":"{FP}"}' }
    )
    foreach ($tc in @($tokScanCases)) {
        $tcKey = Get-NativeDispatchHash32 ('hf-tok-' + [string]$tc.tag)
        $tcPath = Join-Path $nsHostDirTok ($tcKey + '.json')
        $tcBody = ([string]$tc.body).Replace('{KEY}', $tcKey).Replace('{G}', $nsHostIdTok).Replace('{FP}', $fpSeedTok)
        [IO.File]::WriteAllText($tcPath, $tcBody, [Text.UTF8Encoding]::new($false))
        # a UNICA varredura de recibos (claim da task reservada) tem de
        # recusar fail-closed: um token array nao pode ser ignorado como
        # registro valido de outra task.
        $cTok = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kTok -Authorization $fxTok.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pTok.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$cTok.ok) -and (-not [bool]$cTok.claimed) -and ([string]$cTok.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cTok.executor_calls -eq 0)) ('[PRA-5] a foreign receipt with ' + [string]$tc.tag + ' fails the scan closed (no pipeline unrolling)') ([string]$cTok.reason)
        $kTokRawP = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxTok.goal -Key $kTok), [Text.Encoding]::UTF8))
        Assert-HF ([string]$kTokRawP.phase -ceq 'prepared') ('[PRA-5] ' + [string]$tc.tag + ' refusal never consumes the prepared receipt') ('phase=' + [string]$kTokRawP.phase)
        try { Remove-Item -LiteralPath $tcPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    # A leitura do recibo (unica varredura do caminho legado/settled)
    # tambem recusa os tokens array, com a razao explicita de cada campo.
    $tokReadCases = @(
        @{ tag = 'schema-array'; reason = 'receipt-schema-unknown'; body = '{"idempotency_key":"{KEY}","schema_version":[1],"phase":"pending"}' }
        @{ tag = 'phase-array';  reason = 'receipt-phase-unknown';  body = '{"idempotency_key":"{KEY}","schema_version":1,"phase":["pending"]}' }
        @{ tag = 'key-array';    reason = 'receipt-key-mismatch';    body = '{"idempotency_key":["{KEY}"],"schema_version":1,"phase":"pending"}' }
    )
    foreach ($rc in @($tokReadCases)) {
        $rcKey = Get-NativeDispatchHash32 ('hf-tokread-' + [string]$rc.tag)
        $rcPath = Join-Path $nsHostDirTok ($rcKey + '.json')
        $rcBody = ([string]$rc.body).Replace('{KEY}', $rcKey)
        [IO.File]::WriteAllText($rcPath, $rcBody, [Text.UTF8Encoding]::new($false))
        $rTokRead = Read-NDReceipt -Dir $nsHostDirTok -Key $rcKey
        Assert-HF (((-not [bool]$rTokRead.ok) -and ([string]$rTokRead.reason -ceq ([string]$rc.reason)) -and ([bool]$rTokRead.present) -and ($null -eq $rTokRead.receipt))) ('[PRA-5] reading a receipt with ' + [string]$rc.tag + ' refuses: ' + [string]$rc.reason) ([string]$rTokRead.reason)
        try { Remove-Item -LiteralPath $rcPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Controle: representacoes LEGITIMAS do ConvertFrom-Json (inteiro
    # Int32 no PS 5.1 / Int64 no PS 7, string) seguem aceitas.
    $rcOkKey = Get-NativeDispatchHash32 'hf-tokread-legit'
    $rcOkPath = Join-Path $nsHostDirTok ($rcOkKey + '.json')
    [IO.File]::WriteAllText($rcOkPath, ('{"idempotency_key":"' + $rcOkKey + '","schema_version":1,"phase":" PENDING ","task_id":"hf-task-tokhost"}'), [Text.UTF8Encoding]::new($false))
    $rTokOk = Read-NDReceipt -Dir $nsHostDirTok -Key $rcOkKey
    Assert-HF ((([bool]$rTokOk.ok) -and ([string]$rTokOk.receipt.phase -ceq 'pending') -and ([string]$rTokOk.receipt.task_id -ceq 'hf-task-tokhost'))) '[PRA-5] control: legitimate integer/string tokens are still read and canonicalized' ([string]$rTokOk.reason)
    try { Remove-Item -LiteralPath $rcOkPath -Force -ErrorAction SilentlyContinue } catch { }
    $cTokControl = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kTok -Authorization $fxTok.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pTok.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cTokControl.ok) -and ([bool]$cTokControl.claimed)) '[PRA-5] control: the claim works once every array-token receipt is gone' ([string]$cTokControl.reason)

    # ---------- PRA-6: recibo settled duplicado + takeover SEM prova
    # kernel-side recusa (duplicate-identity-mismatch, 0 chamadas, sem
    # vazamento). Separado do caso de resultado invalido POS-efeito, que
    # agora deixa o recibo pending (pending-ambiguous). ----------
    $dupGoalId = 'hf-goal-dupsettled'
    $dupTaskId = 'hf-task-dupsettled'
    $dg = New-OrchestrationGoal -GoalId $dupGoalId -Objective 'settled duplicado sob takeover' -Criteria @('criterio-a') -StoreDir $goalDir
    Assert-HF ([bool]$dg.ok) '[PRA-6] settled-duplicate goal created' ([string]$dg.reason)
    $dgAct = Set-OrchestrationGoalState -Goal $dg.goal -ToState 'ACTIVE'
    $dgSv = Save-OrchestrationGoal -Goal $dgAct.goal -StoreDir $goalDir
    Assert-HF ([bool]$dgSv.ok) '[PRA-6] settled-duplicate goal active' ([string]$dgSv.reason)
    # lease curta: cobre a escrita do recibo e a leitura idempotente do
    # dono original, e expira de forma PROVAVEL antes do takeover.
    $dgOwn = Acquire-OrchestrationGoalOwnership -GoalId $dupGoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$dgSv.revision) -StoreDir $goalDir -LeaseTtlMs 3000
    Assert-HF ([bool]$dgOwn.ok) '[PRA-6] settled-duplicate goal owned with a short lease' ([string]$dgOwn.reason)
    $dgGen = [long]$dgOwn.ownership['generation']
    New-HFKernelTask -Id $dupTaskId -GoalId $dupGoalId -Gen $dgGen
    $kDup = Get-NativeDispatchHash32 'hf-dupsettled-key'
    $iDup = New-HFIntent -Task $dupTaskId -Key $kDup -Gen $dgGen
    Assert-HF ([bool]$iDup.ok) '[PRA-6] settled-duplicate intent built' ([string]$iDup.reason)
    $fpDup = Get-NDIntentFingerprint -Intent $iDup.intent
    $dupPath = Get-HFReceiptPath -GoalId $dupGoalId -Key $kDup
    Assert-HF (($dupPath -ne '') -and (-not (Test-Path -LiteralPath $dupPath -PathType Leaf))) '[PRA-6] settled-duplicate receipt path resolved and absent' $dupPath
    # recibo settled LEGADO, SEM worker_result: nenhuma prova kernel-side
    # do resultado que ele declara.
    [IO.File]::WriteAllText($dupPath, (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kDup; phase = 'settled'; ok = $true; reason = 'settled-fixture'; task_id = $dupTaskId; agent = 'coder'; owner = 'planner-1'; goal_id = $dupGoalId; ownership_generation = $dgGen; task_expected_revision = 1; intent_fingerprint = $fpDup; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $dupBefore = [IO.File]::ReadAllBytes($dupPath)
    # controle: o DONO ORIGINAL, ownership ainda viva, le o duplicado -
    # prova que o recibo e bem formado e que a recusa abaixo NAO pode ser
    # explicada por estrutura invalida.
    $dupSameState = @{ calls = 0 }
    $dupSameSpy = { param($i) $dupSameState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $rDupSame = Invoke-OrchestrationNativeDispatch -Intent $iDup.intent -Executor $dupSameSpy -Authorization @{ explicit_allow = $true; goal_id = $dupGoalId; owner = 'planner-1'; generation = $dgGen; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$rDupSame.ok) -and ([bool]$rDupSame.duplicate) -and ([string]$rDupSame.reason -ceq 'idempotent-duplicate') -and ([int]$rDupSame.executor_calls -eq 0) -and ([int]$dupSameState.calls -eq 0)) '[PRA-6] control: the original live owner still reads the settled duplicate' ([string]$rDupSame.reason)
    # expiracao provavel + takeover por OUTRO dono, com lease viva: a
    # recusa abaixo nao pode ser explicada por expiracao de lease.
    Start-Sleep -Milliseconds 3500
    $dgTow = Takeover-OrchestrationGoalOwnership -GoalId $dupGoalId -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 120000
    Assert-HF ([bool]$dgTow.ok) '[PRA-6] ownership taken over after provable expiry' ([string]$dgTow.reason)
    $dgGen2 = [long]$dgTow.ownership['generation']
    $dgRenew = Renew-OrchestrationGoalOwnership -GoalId $dupGoalId -OwnerId 'planner-2' -Generation $dgGen2 -StoreDir $goalDir -LeaseTtlMs 120000
    Assert-HF ([bool]$dgRenew.ok) '[PRA-6] the new owner lease is live' ([string]$dgRenew.reason)
    $authDupNew = @{ explicit_allow = $true; goal_id = $dupGoalId; owner = 'planner-2'; generation = $dgGen2; source = 'planner' }
    # (i) a identidade do duplicado, isolada: takeover sem prova recusa.
    $dupStored = ConvertFrom-Json ([IO.File]::ReadAllText($dupPath, [Text.Encoding]::UTF8))
    $dupId = Test-NDDuplicateReadIdentity -Receipt $dupStored -Authorization $authDupNew -GoalStoreDir $goalDir -TasksDir $tasksDir -RepoRoot $script:tempRoot
    Assert-HF (((-not [bool]$dupId.ok) -and ([string]$dupId.reason -ceq 'duplicate-identity-mismatch') -and (-not [bool]$dupId.takeover))) '[PRA-6] a settled receipt without kernel-side proof refuses the takeover read' ([string]$dupId.reason)
    # (ii) o dispatch completo: recusa, zero chamadas, sem vazar conteudo.
    $dupState = @{ calls = 0 }
    $dupSpy = { param($i) $dupState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $rDup = Invoke-OrchestrationNativeDispatch -Intent $iDup.intent -Executor $dupSpy -Authorization $authDupNew -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$rDup.ok) -and (-not [bool]$rDup.duplicate) -and ([string]$rDup.reason -ceq 'duplicate-identity-mismatch') -and ([int]$rDup.executor_calls -eq 0) -and ([int]$dupState.calls -eq 0))) '[PRA-6] the settled duplicate without proof yields duplicate-identity-mismatch with 0 executor calls' (([string]$rDup.reason) + ' calls=' + [string]$dupState.calls)
    Assert-HF (($null -eq $rDup.worker_result) -and ([string]$rDup.evidence_id -ceq '')) '[PRA-6] the refusal leaks no worker result and no evidence id' ''
    $dupAfter = [IO.File]::ReadAllBytes($dupPath)
    Assert-HF (($dupAfter.Length -eq $dupBefore.Length)) '[PRA-6] the settled receipt was not rewritten by the refusal' 'size changed'
    if ($dupAfter.Length -eq $dupBefore.Length) {
        $dupSameBytes = $true
        for ($bi = 0; $bi -lt $dupAfter.Length; $bi++) { if ([int]$dupAfter[$bi] -ne [int]$dupBefore[$bi]) { $dupSameBytes = $false; break } }
        Assert-HF $dupSameBytes '[PRA-6] the refused takeover read left the settled receipt byte-identical' 'content changed'
    }
    # (iii) controle positivo: COM a prova kernel-side presente e igual
    # campo a campo, o MESMO takeover le o duplicado. Prova que a recusa
    # acima e exatamente a falta de prova, nao o takeover em si.
    $wrDup = Set-OrchestrationTaskWorkerResult -TaskId $dupTaskId -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
    Assert-HF ([bool]$wrDup.ok) '[PRA-6] kernel-side proof recorded for the task' ([string]$wrDup.error)
    [IO.File]::WriteAllText($dupPath, (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kDup; phase = 'settled'; ok = $true; reason = 'settled-fixture'; task_id = $dupTaskId; agent = 'coder'; owner = 'planner-1'; goal_id = $dupGoalId; ownership_generation = $dgGen; task_expected_revision = 1; intent_fingerprint = $fpDup; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $dupProved = ConvertFrom-Json ([IO.File]::ReadAllText($dupPath, [Text.Encoding]::UTF8))
    $dupIdProved = Test-NDDuplicateReadIdentity -Receipt $dupProved -Authorization $authDupNew -GoalStoreDir $goalDir -TasksDir $tasksDir -RepoRoot $script:tempRoot
    Assert-HF ((([bool]$dupIdProved.ok) -and ([bool]$dupIdProved.takeover) -and ([string]$dupIdProved.reason -ceq ''))) '[PRA-6] control: the SAME takeover WITH kernel-side proof reads the settled duplicate' ([string]$dupIdProved.reason)
    $dupProvState = @{ calls = 0 }
    $dupProvSpy = { param($i) $dupProvState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $rDupProv = Invoke-OrchestrationNativeDispatch -Intent $iDup.intent -Executor $dupProvSpy -Authorization $authDupNew -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$rDupProv.ok) -and ([bool]$rDupProv.duplicate) -and ([string]$rDupProv.reason -ceq 'idempotent-duplicate-takeover') -and ([int]$rDupProv.executor_calls -eq 0) -and ([int]$dupProvState.calls -eq 0)) '[PRA-6] control: the proved takeover read still runs no Executor' ([string]$rDupProv.reason)

    # ---------- PRA-7: forma crua do recibo PROPRIO (FIX3B / achado A) ----------
    # O recibo PROPRIO e EXCLUIDO da varredura global, e a integridade
    # semantica reconstroi o Intent por Get-NDValue, que DESENROLA array de
    # um elemento. Um campo alterado para [x] (valor coercitivo identico ao
    # original) recalcularia os MESMOS fingerprints e passaria com os hashes
    # antigos. Test-NDHandoffReceiptShape (porta de forma crua dentro de
    # Test-NDReceiptSemanticIntegrity) rejeita ANTES de reconstruir/reutilizar/
    # consumir. PREPARE reuse e CLAIM recusam; o recibo fica byte-identico;
    # controle intacto funciona.
    $fxSh = New-HFIsolatedFixture -Suffix 'shape'
    $kSh = Get-NativeDispatchHash32 'hf-shape-key'
    $iSh = New-HFIntent -Task $fxSh.task -Key $kSh -Gen $fxSh.gen
    Assert-HF ([bool]$iSh.ok) '[PRA-7] intent built for the own-shape fixture' ([string]$iSh.reason)
    $pSh = Invoke-OrchestrationNativeDispatchPrepare -Intent $iSh -Authorization $fxSh.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pSh.ok) '[PRA-7] prepared for the own-shape fixture' ([string]$pSh.reason)
    $shFp = [string]$pSh.prepared_fingerprint
    $shPath = Get-HFReceiptPath -GoalId $fxSh.goal -Key $kSh
    $shGood = [IO.File]::ReadAllText($shPath, [Text.Encoding]::UTF8)
    $shObj = ConvertFrom-Json $shGood
    $shMutants = @(
        @{ name = 'task_id-singleton-array';        field = 'task_id';                  value = @([string]$shObj.task_id) }
        @{ name = 'agent-singleton-array';          field = 'agent';                    value = @([string]$shObj.agent) }
        @{ name = 'owner-singleton-array';          field = 'owner';                    value = @([string]$shObj.owner) }
        @{ name = 'goal_id-singleton-array';        field = 'goal_id';                  value = @([string]$shObj.goal_id) }
        @{ name = 'prompt_hash-singleton-array';    field = 'prompt_hash';              value = @([string]$shObj.prompt_hash) }
        @{ name = 'base_revision-singleton-array';  field = 'base_revision';            value = @([string]$shObj.base_revision) }
        @{ name = 'session_id-singleton-array';      field = 'session_id';              value = @([string]$shObj.session_id) }
        @{ name = 'intent_fingerprint-singleton-array'; field = 'intent_fingerprint';   value = @([string]$shObj.intent_fingerprint) }
        @{ name = 'prepared_fingerprint-singleton-array'; field = 'prepared_fingerprint'; value = @([string]$shObj.prepared_fingerprint) }
        @{ name = 'ownership_generation-singleton-array'; field = 'ownership_generation'; value = @([long]$shObj.ownership_generation) }
        @{ name = 'task_expected_revision-singleton-array'; field = 'task_expected_revision'; value = @([long]$shObj.task_expected_revision) }
        @{ name = 'external_idempotent-singleton-array';  field = 'external_idempotent'; value = @([bool]$shObj.external_idempotent) }
        @{ name = 'scope-to-scalar';                field = 'scope';                    value = ([string]$shObj.scope[0]) }
        @{ name = 'acceptance_criteria-first-elem-array'; field = 'acceptance_criteria'; value = @(@([string]$shObj.acceptance_criteria[0]), [string]$shObj.acceptance_criteria[1]) }
    )
    foreach ($m in @($shMutants)) {
        $raw = ConvertFrom-Json $shGood
        Add-Member -InputObject $raw -Name ([string]$m.field) -Value $m.value -MemberType NoteProperty -Force
        [IO.File]::WriteAllText($shPath, (ConvertTo-Json -InputObject $raw -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $shTamper = [IO.File]::ReadAllBytes($shPath)
        $pShBad = Invoke-OrchestrationNativeDispatchPrepare -Intent $iSh -Authorization $fxSh.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$pShBad.ok) -and (-not [bool]$pShBad.reused) -and ([string]$pShBad.reason -ceq 'receipt-integrity-invalid') -and ([int]$pShBad.executor_calls -eq 0))) ('[PRA-7] own-receipt ' + [string]$m.name + ' refuses prepare reuse') ([string]$pShBad.reason)
        $cShBad = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kSh -Authorization $fxSh.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $shFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cShBad.ok) -and (-not [bool]$cShBad.claimed) -and ([string]$cShBad.reason -ceq 'receipt-integrity-invalid') -and ([int]$cShBad.executor_calls -eq 0))) ('[PRA-7] own-receipt ' + [string]$m.name + ' refuses claim') ([string]$cShBad.reason)
        $shAfter = [IO.File]::ReadAllBytes($shPath)
        $shSame = ($shAfter.Length -eq $shTamper.Length)
        if ($shSame) { for ($bi = 0; $bi -lt $shAfter.Length; $bi++) { if ([int]$shAfter[$bi] -ne [int]$shTamper[$bi]) { $shSame = $false; break } } }
        Assert-HF $shSame ('[PRA-7] ' + [string]$m.name + ' refused receipt stays byte-identical (never rewritten)') 'content changed'
        $shPhase = (ConvertFrom-Json ([IO.File]::ReadAllText($shPath, [Text.Encoding]::UTF8))).phase
        Assert-HF ([string]$shPhase -ceq 'prepared') ('[PRA-7] ' + [string]$m.name + ' receipt still prepared after refusal') ('phase=' + [string]$shPhase)
    }
    [IO.File]::WriteAllText($shPath, $shGood, [Text.UTF8Encoding]::new($false))
    $pShOk = Invoke-OrchestrationNativeDispatchPrepare -Intent $iSh -Authorization $fxSh.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$pShOk.ok) -and ([bool]$pShOk.reused) -and ([string]$pShOk.reason -ceq 'prepare-reused')) '[PRA-7] control: untampered own receipt is reusable again' ([string]$pShOk.reason)
    $cShOk = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kSh -Authorization $fxSh.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint $shFp -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cShOk.ok) -and ([bool]$cShOk.claimed)) '[PRA-7] control: untampered own receipt is claimable' ([string]$cShOk.reason)

    # ---------- PRA-8: raiz JSON OBJETO obrigatoria (FIX3B / achado B) ----------
    # ConvertFrom-Json pela pipeline desenrolaria `[{...}]` num objeto escalar e
    # aceitaria `42`/`"x"`/`true`/`null`. Read-NDReceipt e a varredura de
    # reserva exigem agora que o primeiro token nao-espaco seja '{'.
    $fxOr = New-HFIsolatedFixture -Suffix 'objroot'
    $kOr = Get-NativeDispatchHash32 'hf-objroot-key'
    $iOr = New-HFIntent -Task $fxOr.task -Key $kOr -Gen $fxOr.gen
    Assert-HF ([bool]$iOr.ok) '[PRA-8] intent built for the object-root fixture' ([string]$iOr.reason)
    $pOr = Invoke-OrchestrationNativeDispatchPrepare -Intent $iOr -Authorization $fxOr.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pOr.ok) '[PRA-8] prepared for the object-root fixture' ([string]$pOr.reason)
    $nsOr = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxOr.goal
    # (a) leitura do recibo PROPRIO: raiz array ou escalar => receipt-json-invalid.
    $kOrRead = Get-NativeDispatchHash32 'hf-objroot-read'
    $orReadBad = @(
        @{ tag = 'singleton-array-root'; body = ('[{"idempotency_key":"' + $kOrRead + '","schema_version":1,"phase":"prepared","task_id":"' + [string]$fxOr.task + '"}]') }
        @{ tag = 'empty-array-root';     body = '[]' }
        @{ tag = 'scalar-number-root';   body = '42' }
        @{ tag = 'scalar-string-root';   body = ('"' + $kOrRead + '"') }
        @{ tag = 'scalar-bool-root';     body = 'true' }
        @{ tag = 'scalar-null-root';     body = 'null' }
    )
    foreach ($rb in @($orReadBad)) {
        $orReadPath = Join-Path $nsOr ($kOrRead + '.json')
        [IO.File]::WriteAllText($orReadPath, ([string]$rb.body), [Text.UTF8Encoding]::new($false))
        $rOr = Read-NDReceipt -Dir $nsOr -Key $kOrRead -AllowHandoffPhases
        Assert-HF (((-not [bool]$rOr.ok) -and ([string]$rOr.reason -ceq 'receipt-json-invalid') -and ([bool]$rOr.present) -and ($null -eq $rOr.receipt))) ('[PRA-8] own-receipt read refuses a ' + [string]$rb.tag + ' as receipt-json-invalid') ([string]$rOr.reason)
        try { Remove-Item -LiteralPath $orReadPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    [IO.File]::WriteAllText((Join-Path $nsOr ($kOrRead + '.json')), ('{"idempotency_key":"' + $kOrRead + '","schema_version":1,"phase":"prepared","task_id":"' + [string]$fxOr.task + '"}'), [Text.UTF8Encoding]::new($false))
    $rOrOk = Read-NDReceipt -Dir $nsOr -Key $kOrRead -AllowHandoffPhases
    Assert-HF ((([bool]$rOrOk.ok) -and ([string]$rOrOk.receipt.phase -ceq 'prepared'))) '[PRA-8] control: a JSON object root is still read and canonicalized' ([string]$rOrOk.reason)
    try { Remove-Item -LiteralPath (Join-Path $nsOr ($kOrRead + '.json')) -Force -ErrorAction SilentlyContinue } catch { }
    # (b) varredura de reserva: arquivo ESTRANGEIRO com raiz array/escalar
    # (que, se desenrolado, seria um recibo VALIDO de OUTRA task e portanto
    # ignorado) faz a varredura falhar fechada.
    $orScanBad = @(
        @{ tag = 'singleton-array-root'; body = ('[{"schema_version":1,"idempotency_key":"{KEY}","phase":"settled","task_id":"hf-task-objroot-other","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxOr.goal + '","ownership_generation":' + [string]$fxOr.gen + ',"task_expected_revision":1,"intent_fingerprint":"{FP}"}]') }
        @{ tag = 'scalar-root';          body = '42' }
    )
    foreach ($sb in @($orScanBad)) {
        $orScanKey = Get-NativeDispatchHash32 ('hf-objroot-scan-' + [string]$sb.tag)
        $orScanPath = Join-Path $nsOr ($orScanKey + '.json')
        $orScanBody = ([string]$sb.body).Replace('{KEY}', $orScanKey).Replace('{FP}', ('a' * 32))
        [IO.File]::WriteAllText($orScanPath, $orScanBody, [Text.UTF8Encoding]::new($false))
        $cOrBad = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kOr -Authorization $fxOr.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pOr.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cOrBad.ok) -and (-not [bool]$cOrBad.claimed) -and ([string]$cOrBad.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cOrBad.executor_calls -eq 0))) ('[PRA-8] reservation scan refuses a foreign ' + [string]$sb.tag + ' (fails closed)') ([string]$cOrBad.reason)
        $kOrBadRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxOr.goal -Key $kOr), [Text.Encoding]::UTF8))
        Assert-HF ([string]$kOrBadRaw.phase -ceq 'prepared') ('[PRA-8] ' + [string]$sb.tag + ' failed scan never consumes the prepared receipt') ('phase=' + [string]$kOrBadRaw.phase)
        try { Remove-Item -LiteralPath $orScanPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    $cOrOk = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kOr -Authorization $fxOr.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pOr.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cOrOk.ok) -and ([bool]$cOrOk.claimed)) '[PRA-8] control: the claim works once every non-object-root foreign receipt is gone' ([string]$cOrOk.reason)

    # ---------- H5 (PRA-SETTLE-FIX4): comparacao estrutural PROFUNDA por
    # leitura direta, sem pipeline de saida ----------
    # `Get-NDValue` desenrola array de um elemento no pipeline: `kernel_ok:
    # [true]` chegaria como `true` e `settle_child_session_id:["filho"]` como
    # 'filho'. A prova do recibo 'settled' passa a comparar NOS lidos direto
    # da propriedade (`Get-NDValueNode`), que preservam o TIPO do token.
    # Estas regressoes atacam os helpers diretamente.
    # (a) escalar vs array de um elemento (topo do objeto).
    $hBoolScalar = New-NDValueNode -Value ([bool]$true) -Present $true
    $hBoolArray = New-NDValueNode -Value @([bool]$true) -Present $true
    Assert-HF (([string]$hBoolScalar.kind -ceq 'bool') -and ([string]$hBoolArray.kind -ceq 'list') -and (-not (Test-NDReceiptValueMatch -Expected $hBoolScalar -Actual $hBoolArray))) '[H5a] a boolean never matches its own singleton array' ('kinds=' + [string]$hBoolScalar.kind + '/' + [string]$hBoolArray.kind)
    Assert-HF ((Test-NDReceiptValueMatch -Expected $hBoolScalar -Actual (New-NDValueNode -Value ([bool]$true) -Present $true))) '[H5a] identical booleans still match' ''
    $hStrArray = New-NDValueNode -Value @('ses_hf_child_1') -Present $true
    Assert-HF (([string]$hStrArray.kind -ceq 'list') -and (-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value 'ses_hf_child_1' -Present $true) -Actual $hStrArray))) '[H5a] a string never matches its own singleton array' ''
    # (b) aninhado: campo de objeto tambem nao casa com singleton array.
    $hNestedOk = [pscustomobject]@{ status = 'candidate_pass'; refs = @('criterion:0', 'criterion:1') }
    $hNestedArr = [pscustomobject]@{ status = @('candidate_pass'); refs = @('criterion:0', 'criterion:1') }
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hNestedOk) -Actual (New-NDValueNode -Value $hNestedArr)))) '[H5b] a nested string field never matches its singleton array' ''
    Assert-HF ((Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hNestedOk) -Actual (New-NDValueNode -Value ([pscustomobject]@{ status = 'candidate_pass'; refs = @('criterion:0', 'criterion:1') })))) '[H5b] identical nested objects still match' ''
    $hNestedJson = ConvertFrom-Json '{"status":["candidate_pass"],"refs":["criterion:0","criterion:1"]}'
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hNestedOk) -Actual (New-NDValueNode -Value $hNestedJson)))) '[H5b] JSON with a nested singleton-array field is refused' ''
    $hNestedList = Get-NDValueNode -Object (ConvertFrom-Json '{"refs":[["criterion:0"]]}') -Name 'refs'
    Assert-HF (([string]$hNestedList.kind -ceq 'list') -and (-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value @('criterion:0')) -Actual $hNestedList))) '[H5b] a nested LIST never matches a flat list' ''
    # (c) inteiro vs fracionario e normalizacao Int32/Int64.
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value ([int]1)) -Actual (New-NDValueNode -Value ([double]1.0))))) '[H5c] an integer never matches a float of the same magnitude' ''
    Assert-HF (((Get-NDScalarToken -Value ([int]1)) -cne (Get-NDScalarToken -Value ([double]1.0))) -and ((Get-NDScalarToken -Value ([int]2)) -ceq (Get-NDScalarToken -Value ([long]2)))) '[H5c] int/float tokens differ while Int32 and Int64 tokens are equal' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value ([bool]$true)) -Actual (New-NDValueNode -Value ([int]1))))) '[H5c] a boolean never matches an integer' ''
    # (d) ausente vs null.
    $hWithNull = [pscustomobject]@{ present_field = $null }
    $hWithout = [pscustomobject]@{ }
    $hAbsent = Get-NDValueNode -Object $hWithNull -Name 'absent_field'
    $hNull = Get-NDValueNode -Object $hWithNull -Name 'present_field'
    Assert-HF ((([string]$hAbsent.kind -ceq 'absent') -and ([string]$hNull.kind -ceq 'null') -and (-not (Test-NDReceiptValueMatch -Expected $hAbsent -Actual $hNull)))) '[H5d] an ABSENT property never matches an explicit null' ''
    Assert-HF ((Test-NDReceiptValueMatch -Expected $hAbsent -Actual (Get-NDValueNode -Object $hWithout -Name 'absent_field'))) '[H5d] absent matches absent' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hWithNull) -Actual (New-NDValueNode -Value $hWithout)))) '[H5d] a null field never matches a missing field (key sets differ)' ''
    # (e) ordem da lista.
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value @('a', 'b')) -Actual (New-NDValueNode -Value @('b', 'a'))))) '[H5e] list order is part of the comparison' ''
    Assert-HF ((Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value @('a', 'b')) -Actual (New-NDValueNode -Value @('a', 'b')))) '[H5e] identical ordered lists still match' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value @('a')) -Actual (New-NDValueNode -Value @('a', 'b'))))) '[H5e] list size is part of the comparison' ''
    # (f) chave extra / chave faltando.
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value ([pscustomobject]@{ a = 1; b = 2 })) -Actual (New-NDValueNode -Value ([pscustomobject]@{ a = 1; c = 2 }))))) '[H5f] an extra/missing object key is refused' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value ([ordered]@{ a = 1 })) -Actual (New-NDValueNode -Value ([ordered]@{ a = 1; b = 2 }))))) '[H5f] an extra key on the persisted side is refused' ''
    Assert-HF ((Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value ([ordered]@{ a = 1; b = 2 })) -Actual (New-NDValueNode -Value ([ordered]@{ a = 1; b = 2 })))) '[H5f] identical key sets still match' ''
    # (g) timestamp: string ISO e DateTime do MESMO instante canonizam juntos
    #     (PS 5.1 devolve string, PS 7 devolve DateTime).
    $hTsText = '2026-10-10T12:00:00.0000000Z'
    $hTsDate = [DateTime]::Parse($hTsText, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
    Assert-HF ((Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hTsText) -Actual (New-NDValueNode -Value $hTsDate))) '[H5g] the same ISO-8601 instant matches across string/DateTime' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hTsText) -Actual (New-NDValueNode -Value '2026-10-10T12:00:01.0000000Z')))) '[H5g] a different instant never matches' ''
    # (h0) NOMES REAIS do recibo 'settled': `kernel_ok:true` vs
    #      `kernel_ok:[true]`, status do candidato vs singleton array e
    #      child id vs array - exatamente os tokens que a leitura com
    #      coercao trataria como iguais.
    $hKTrue = Get-NDValueNode -Object ([pscustomobject]@{ kernel_ok = [bool]$true }) -Name 'kernel_ok'
    $hKArr = Get-NDValueNode -Object (ConvertFrom-Json '{"kernel_ok":[true]}') -Name 'kernel_ok'
    Assert-HF ((([string]$hKTrue.kind -ceq 'bool') -and ([string]$hKArr.kind -ceq 'list') -and (-not (Test-NDReceiptValueMatch -Expected $hKTrue -Actual $hKArr)))) '[H5h0] kernel_ok:true never matches kernel_ok:[true]' ('kinds=' + [string]$hKTrue.kind + '/' + [string]$hKArr.kind)
    Assert-HF ((Test-NDReceiptValueMatch -Expected $hKTrue -Actual (Get-NDValueNode -Object ([pscustomobject]@{ kernel_ok = [bool]$true }) -Name 'kernel_ok'))) '[H5h0] control: kernel_ok:true matches kernel_ok:true' ''
    $hStatusOk = [pscustomobject]@{ worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }
    $hStatusArr = ConvertFrom-Json '{"worker_result":{"status":["candidate_pass"],"claimed_evidence":["criterion:0"]}}'
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hStatusOk) -Actual (New-NDValueNode -Value $hStatusArr)))) '[H5h0] a nested worker status string never matches its singleton array' ''
    $hChildOk = [pscustomobject]@{ settle_child_session_id = 'ses_hf_child_1' }
    $hChildArr = ConvertFrom-Json '{"settle_child_session_id":["ses_hf_child_1"]}'
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hChildOk) -Actual (New-NDValueNode -Value $hChildArr)))) '[H5h0] the child session id string never matches its singleton array' ''
    # (h1) lista VAZIA nunca casa com lista de um elemento (refs do candidato).
    $hEmptyRefs = [pscustomobject]@{ settle_claimed_evidence = [string[]]@() }
    $hOneRef = ConvertFrom-Json '{"settle_claimed_evidence":["criterion:0"]}'
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hEmptyRefs) -Actual (New-NDValueNode -Value $hOneRef)))) '[H5h1] an EMPTY list never matches a one-element list' ''
    Assert-HF ((Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hEmptyRefs) -Actual (New-NDValueNode -Value ([pscustomobject]@{ settle_claimed_evidence = [string[]]@() })))) '[H5h1] control: empty matches empty' ''
    Assert-HF ((-not (Test-NDReceiptValueMatch -Expected (New-NDValueNode -Value $hOneRef) -Actual (New-NDValueNode -Value $hEmptyRefs)))) '[H5h1] the comparison is symmetric for empty vs non-empty' ''
    # (h) porta de forma CRUA dos campos proprios do 'settled' (positivo).
    $hSettledOk = [pscustomobject][ordered]@{
        phase = 'settled'; handoff_state = 'SETTLED'; idempotency_key = 'a' * 32; goal_id = 'hf-goal-1'
        task_id = 'hf-task-shape'; agent = 'coder'; owner = 'planner-1'; evidence_id = 'e' * 32
        settle_status = 'candidate_pass'; settle_child_session_id = 'ses_hf_child_1'; settle_session_id = 'ses_hf_shape'
        settle_message_id = 'msg_hf_shape'; settle_call_id = 'call_hf_shape'; settle_caller_agent = 'planner'
        settle_target_agent = 'coder'; settled_by = 'planner-1'
        kernel_ok = [bool]$true; evidence_created = [bool]$true; reconciled = [bool]$false
        worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'criterion:1') }
        settle_claimed_evidence = [string[]]@('criterion:0', 'criterion:1')
    }
    Assert-HF ((Test-NDSettledReceiptFieldShape -Receipt $hSettledOk)) '[H5h] an exact settled receipt shape is accepted' ''
    $hSettledMutants = @(
        @{ tag = 'kernel_ok-array';               apply = { param($o) $o.kernel_ok = @([bool]$true) } }
        @{ tag = 'evidence_created-array';        apply = { param($o) $o.evidence_created = @([bool]$true) } }
        @{ tag = 'reconciled-array';              apply = { param($o) $o.reconciled = @([bool]$false) } }
        @{ tag = 'reconciled-string';             apply = { param($o) $o.reconciled = 'false' } }
        @{ tag = 'executor_calls-array';          apply = { param($o) Add-Member -InputObject $o -Name 'executor_calls' -Value @([int]0) -MemberType NoteProperty -Force } }
        @{ tag = 'executor_calls-float';          apply = { param($o) Add-Member -InputObject $o -Name 'executor_calls' -Value ([double]0.0) -MemberType NoteProperty -Force } }
        @{ tag = 'settle_child_session_id-array'; apply = { param($o) $o.settle_child_session_id = @('ses_hf_child_1') } }
        @{ tag = 'settle_call_id-array';          apply = { param($o) $o.settle_call_id = @('call_hf_shape') } }
        @{ tag = 'evidence_id-array';             apply = { param($o) $o.evidence_id = @('e' * 32) } }
        @{ tag = 'phase-array';                   apply = { param($o) $o.phase = @('settled') } }
        @{ tag = 'worker_result-scalar';          apply = { param($o) $o.worker_result = 'candidate_pass' } }
        @{ tag = 'worker_result-array';           apply = { param($o) $o.worker_result = @(@{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }) } }
        @{ tag = 'worker_result-status-array';    apply = { param($o) $o.worker_result = @{ status = @('candidate_pass'); claimed_evidence = @('criterion:0') } } }
        @{ tag = 'worker_result-refs-scalar';     apply = { param($o) $o.worker_result = @{ status = 'candidate_pass'; claimed_evidence = 'criterion:0' } } }
        @{ tag = 'settle_claimed_evidence-scalar';apply = { param($o) $o.settle_claimed_evidence = 'criterion:0' } }
        @{ tag = 'settled_by-missing';            apply = { param($o) $o.PSObject.Properties.Remove('settled_by') } }
    )
    foreach ($hm in @($hSettledMutants)) {
        $hObj = ConvertFrom-Json (ConvertTo-Json -InputObject $hSettledOk -Depth 20 -Compress)
        & $hm.apply $hObj
        Assert-HF ((-not (Test-NDSettledReceiptFieldShape -Receipt $hObj))) ('[H5h] settled shape refuses ' + [string]$hm.tag) ''
    }
    # (h2) refs VAZIAS seguem validas (array vazio nao e token divergente).
    $hSettledEmpty = [pscustomobject]([ordered]@{
        phase = 'settled'; handoff_state = 'SETTLED'; idempotency_key = 'a' * 32; goal_id = 'hf-goal-1'
        task_id = 'hf-task-shape'; agent = 'coder'; owner = 'planner-1'; evidence_id = 'e' * 32
        settle_status = 'failed'; settle_child_session_id = 'ses_hf_child_1'; settle_session_id = 'ses_hf_shape'
        settle_message_id = 'msg_hf_shape'; settle_call_id = 'call_hf_shape'; settle_caller_agent = 'planner'
        settle_target_agent = 'coder'; settled_by = 'planner-1'
        kernel_ok = [bool]$false; evidence_created = [bool]$false; reconciled = [bool]$false
        worker_result = @{ status = 'failed'; claimed_evidence = @() }
        settle_claimed_evidence = [string[]]@()
    })
    Assert-HF ((Test-NDSettledReceiptFieldShape -Receipt $hSettledEmpty)) '[H5h] a settled receipt with EMPTY evidence refs keeps a valid shape' ''

    # ---------- S0: helpers de liquidacao (SETTLE, fatia 2) ----------
    # Baseline do contador de Executor legado: as duas chamadas
    # intencionais da suite (L2a e X1f) ja aconteceram antes deste ponto.
    # Nenhuma operacao de handoff - PREPARE, CLAIM ou SETTLE - pode
    # incrementar esse contador.
    $script:spyBaseline = [int]$script:spyState.calls
    # PRA-SETTLE-FIX5 (runtime): a raiz de recibos e REATRIBUIDA por grupo
    # a partir daqui. Os grupos de liquidacao e de porta do 'settled'
    # afirmam SOMENTE sobre o PROPRIO fixture - a validacao semantica do
    # scan precede a atribuicao, entao a semantica observada e identica
    # (registro valido de outra task e ignorado; registro adulterado ou
    # de liquidacao nao provada recusa fechado). O que muda e o TAMANHO
    # da caminhada: cada grupo ve apenas os namespaces que ele mesmo
    # criou, em vez de acumular ~85 namespaces no fim da suite. Os grupos
    # que deixam um 'settled' de handoff ADULTERADO em disco (F4-6, F4-7,
    # F5 e o caso de task_id trocado) ficam em raiz PROPRIA: com a
    # porta FIX5, um 'settled' marcado que nao prova a liquidacao NAO
    # pode mais ser ignorado como "outra task" - a adulteracao fica
    # contida no grupo que a criou. PRA-SETTLE-FIX6: nos lacos F4-7 e F5
    # a raiz propria e POR ITERACAO - a adulteracao de um caso recusa a
    # varredura INTEIRA da raiz em que esta, entao o caso seguinte precisa
    # de uma raiz nova para conseguir criar o fixture.
    function New-HFReceiptRoot {
        param([string]$Name)
        $d = Join-Path $script:tempRoot ('receipts-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }
    $receiptDir = New-HFReceiptRoot -Name 'settle'
    function New-HFSettleFixture {
        param([string]$Suffix, [string]$KeyMaterial)
        $fx = New-HFIsolatedFixture -Suffix $Suffix
        $k = Get-NativeDispatchHash32 $KeyMaterial
        $i = New-HFIntent -Task $fx.task -Key $k -Gen $fx.gen
        Assert-HF ([bool]$i.ok) ('[S] intent built ' + $Suffix) ([string]$i.reason)
        $p = Invoke-OrchestrationNativeDispatchPrepare -Intent $i -Authorization $fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$p.ok) ('[S] prepared ' + $Suffix) ([string]$p.reason)
        $c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k -Authorization $fx.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$c.ok) ('[S] claimed ' + $Suffix) ([string]$c.reason)
        return [pscustomobject]@{ fx = $fx; key = $k; intent = $i; prepare = $p; claim = $c }
    }

    function Invoke-HFSettle {
        param(
            [string]$Key,
            $Authorization,
            $Result,
            [string]$ChildSession = 'ses_hf_child_1',
            [string]$Session = $session,
            [string]$Message = $message,
            [string]$Call = $call,
            [string]$Caller = 'planner',
            [string]$Target = 'coder',
            [string]$Fp = '',
            [string]$Reference = '',
            [string]$TaskId = '',
            [int]$LockTimeoutMs = 60000
        )
        return (Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $Key -Authorization $Authorization -ChildSessionId $ChildSession -SessionId $Session -MessageId $Message -CallId $Call -CallerAgent $Caller -TargetAgent $Target -TaskId $TaskId -PreparedFingerprint $Fp -Reference $Reference -Result $Result -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath -LockTimeoutMs $LockTimeoutMs)
    }

    function Get-HFReceiptRaw {
        param([string]$GoalId, [string]$Key)
        $path = Get-HFReceiptPath -GoalId $GoalId -Key $Key
        if (($path -eq '') -or (-not (Test-Path -LiteralPath $path -PathType Leaf))) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    # PRA-SETTLE-FIX4: reescreve UM campo do registro persistido (preserva os
    # demais) eRemove UM campo. Usado pelos cenarios de porta do 'settled' na
    # duplicata e na varredura - sempre com o escritor mockado em 'pass' e
    # sempre restaurando os bytes originais no finally do cenario.
    function Set-HFReceiptField {
        param([string]$Path, [string]$Field, $Value)
        try {
            $obj = ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
            Add-Member -InputObject $obj -Name $Field -Value $Value -MemberType NoteProperty -Force
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $obj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
            return $true
        }
        catch { return $false }
    }

    function Remove-HFReceiptField {
        param([string]$Path, [string]$Field)
        try {
            $obj = ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
            if ($null -ne $obj.PSObject.Properties[$Field]) { $obj.PSObject.Properties.Remove($Field) }
            [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $obj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
            return $true
        }
        catch { return $false }
    }

    # ---------- mock deterministico de Write-NDReceipt (somente teste) ----------
    # PRA-SETTLE-FIX3: para simular uma falha REAL da escrita do recibo
    # 'settled' - inclusive a variante em que o arquivo JA foi movido para o
    # destino e a prova pos-escrita falhou - sem mutar fase de recibo a mao.
    # O mock DELEGA ao escritor original em TODOS os outros casos (inclusive
    # nos modos 'claims' de marcador) e a funcao original e restaurada no
    # finally de cada cenario e no finally da suite. Nenhuma outra suite e
    # alterada: no modo 'pass' o mock e delegacao transparente.
    $script:hfReceiptWriteMode = 'pass'
    $script:hfWriterMockInstalled = $false
    $script:hfMutateSettledField = ''
    # PRA-SETTLE-FIX5: campo do registro 'settled' que o escritor mockado
    # substitui por OUTRO valor do MESMO tipo (string valida) DEPOIS da
    # escrita real - a mutacao que a porta antiga deixava passar.
    $script:hfMutateSettledValue = @{ field = ''; value = $null }
    $script:hfOrigWriteReceipt = (Get-Item -Path ('function:' + 'Write-NDReceipt')).ScriptBlock
    function Write-NDReceipt {
        param([string]$Dir, $Receipt, [string]$Expected = '', [ref]$RefusalReason)
        try {
            if ($null -eq $script:hfOrigWriteReceipt) { return $false }
            $phase = ([string](Get-NDValue $Receipt 'phase' '')).Trim().ToLowerInvariant()
            if ($phase -ceq 'settled') {
                # escrita final: falha SEM IO no destino (nada persistido).
                if ($script:hfReceiptWriteMode -ceq 'fail-settled') { return $false }
                # escrita final: PERSISTE e devolve $false (prova pos-escrita
                # falhando depois do Move).
                if ($script:hfReceiptWriteMode -ceq 'persist-then-false-settled') {
                    $null = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    return $false
                }
                # PRA-SETTLE-FIX4: escrita REAL do 'settled' (escritor
                # genuino, sem mutacao de fase a mao) e, EM SEGUIDA, UM campo
                # do registro persistido e colocado em forma de array de um
                # elemento - o token cru adulterado DEPOIS do Move, exatamente
                # a situacao em que o disco nao contem o que foi pedido.
                # Devolve $false para obrigar a prova de releitura.
                if ($script:hfReceiptWriteMode -ceq 'persist-mutate-settled') {
                    $orig = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    if ($orig) {
                        $mKey = ([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
                        $mField = [string]$script:hfMutateSettledField
                        $mPath = Join-Path $Dir ($mKey + '.json')
                        try {
                            $mObj = ConvertFrom-Json ([IO.File]::ReadAllText($mPath, [Text.Encoding]::UTF8))
                            $mCur = Get-NDValue -Object $mObj -Name $mField -Default $null
                            if ($null -ne $mCur) { $mCur = @($mCur) } else { $mCur = @() }
                            Add-Member -InputObject $mObj -Name $mField -Value $mCur -MemberType NoteProperty -Force
                            [IO.File]::WriteAllText($mPath, (ConvertTo-Json -InputObject $mObj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
                        }
                        catch { }
                    }
                    return $false
                }
                # PRA-SETTLE-FIX4 (bloqueador 2): MESMA adulteracao, mas o
                # escritor devolve $true - o suposto "caminho feliz". Um
                # retorno $true do escritor NAO pode provar que o disco
                # contem o registro 'settled' EXATO: a prova tem de vir da
                # releitura sob lock, que aqui encontra o token em forma de
                # array e recusa.
                if ($script:hfReceiptWriteMode -ceq 'persist-mutate-settled-true') {
                    $orig2 = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    if ($orig2) {
                        $m2Key = ([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
                        $m2Field = [string]$script:hfMutateSettledField
                        $m2Path = Join-Path $Dir ($m2Key + '.json')
                        try {
                            $m2Obj = ConvertFrom-Json ([IO.File]::ReadAllText($m2Path, [Text.Encoding]::UTF8))
                            $m2Cur = Get-NDValue -Object $m2Obj -Name $m2Field -Default $null
                            if ($null -ne $m2Cur) { $m2Cur = @($m2Cur) } else { $m2Cur = @() }
                            Add-Member -InputObject $m2Obj -Name $m2Field -Value $m2Cur -MemberType NoteProperty -Force
                            [IO.File]::WriteAllText($m2Path, (ConvertTo-Json -InputObject $m2Obj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
                        }
                        catch { }
                    }
                    return $orig2
                }
                # PRA-SETTLE-FIX5: escrita REAL do 'settled' e, EM SEGUIDA, UM
                # campo de MESMO TIPO recebe OUTRO valor VALIDO (child session
                # id outra string valida, evidence_id outro hash valido). O
                # token cru continua sendo do tipo esperado - so o valor
                # divergiu do que a liquidacao pediu. Devolve $false para
                # obrigar a prova de releitura, que tem de recusar.
                if ($script:hfReceiptWriteMode -ceq 'persist-mutate-value-settled') {
                    $origV = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    if ($origV) {
                        $mKey = ([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
                        $mField = [string]$script:hfMutateSettledValue.field
                        $mVal = $script:hfMutateSettledValue.value
                        if ((-not [string]::IsNullOrWhiteSpace($mField)) -and ($null -ne $mVal)) {
                            $mPath = Join-Path $Dir ($mKey + '.json')
                            try {
                                $mObj = ConvertFrom-Json ([IO.File]::ReadAllText($mPath, [Text.Encoding]::UTF8))
                                Add-Member -InputObject $mObj -Name $mField -Value $mVal -MemberType NoteProperty -Force
                                [IO.File]::WriteAllText($mPath, (ConvertTo-Json -InputObject $mObj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
                            }
                            catch { }
                        }
                    }
                    return $false
                }
            }
            if ($phase -ceq 'pending') {
                # PRA-SETTLE-FIX4: para provocar uma recusa PRE-efeito REAL no
                # Invoke legado (despacho NOVO). O mock GRAVA o 'pending' e
                # tira o goal de ACTIVE; a rechecagem de fencing pos-lock roda
                # em seguida e recusa (sem efeito), e o legado liquida a recusa
                # como settled PRE-efeito (kernel_ok=false, executor_calls=0).
                if ($script:hfReceiptWriteMode -ceq 'pause-goal-on-pending') {
                    $null = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    $pauseGoal = ([string](Get-NDValue $Receipt 'goal_id' '')).Trim()
                    $pauseGen = [long](Get-NDValue $Receipt 'ownership_generation' 0)
                    if ((-not [string]::IsNullOrWhiteSpace($pauseGoal)) -and ($pauseGen -ge 1)) {
                        $null = Set-HFGoalStateLive -GoalId $pauseGoal -ToState 'PAUSED' -Gen $pauseGen
                    }
                    return $true
                }
            }
            if (($phase -ceq 'claimed') -and ($null -ne (Get-NDValue $Receipt 'settle_evidence_id' $null))) {
                # marcador duravel de evidencia (segunda escrita 'claimed').
                if ($script:hfReceiptWriteMode -ceq 'fail-evidence-marker') { return $false }
                # escreve o marcador e TIRA o goal de ACTIVE antes da escrita
                # no kernel: prova o fencing imediatamente anterior ao kernel.
                if ($script:hfReceiptWriteMode -ceq 'pause-goal-on-evidence') {
                    $null = (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
                    $pauseGoal = ([string](Get-NDValue $Receipt 'goal_id' '')).Trim()
                    $pauseGen = [long](Get-NDValue $Receipt 'ownership_generation' 0)
                    if ((-not [string]::IsNullOrWhiteSpace($pauseGoal)) -and ($pauseGen -ge 1)) {
                        $null = Set-HFGoalStateLive -GoalId $pauseGoal -ToState 'PAUSED' -Gen $pauseGen
                    }
                    return $true
                }
            }
        }
        catch { }
        return (& $script:hfOrigWriteReceipt -Dir $Dir -Receipt $Receipt -Expected $Expected -RefusalReason $RefusalReason)
    }
    $script:hfWriterMockInstalled = $true

    function Set-HFReceiptWriteMode {
        param([string]$Mode = 'pass')
        $script:hfReceiptWriteMode = ([string]$Mode)
    }

    # PRA-SETTLE-FIX4: campo do registro 'settled' que o escritor mockado
    # coloca em forma de array de um elemento DEPOIS da escrita real.
    function Set-HFReceiptMutateField {
        param([string]$Field = '')
        $script:hfMutateSettledField = ([string]$Field)
    }

    # PRA-SETTLE-FIX5: campo do registro 'settled' que o escritor mockado
    # substitui por OUTRO valor do MESMO tipo DEPOIS da escrita real.
    function Set-HFReceiptMutateValue {
        param([string]$Field = '', $Value = $null)
        $script:hfMutateSettledValue = @{ field = ([string]$Field); value = $Value }
    }

    function Restore-HFReceiptWriter {
        if ($script:hfWriterMockInstalled -and ($null -ne $script:hfOrigWriteReceipt)) {
            try { Set-Item -Path ('function:' + 'Write-NDReceipt') -Value $script:hfOrigWriteReceipt } catch { }
        }
        $script:hfWriterMockInstalled = $false
        $script:hfReceiptWriteMode = 'pass'
        $script:hfMutateSettledField = ''
        $script:hfMutateSettledValue = @{ field = ''; value = $null }
    }

    # ---------- S1: liquidacao VALIDA de um handoff CLAIMED ----------
    $sx1 = New-HFSettleFixture -Suffix 'settle1' -KeyMaterial 'hf-settle-valid-1'
    $fp1 = ([string]$sx1.prepare.prepared_fingerprint)
    $s1cand = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'criterion:1') }
    $s1 = Invoke-HFSettle -Key $sx1.key -Authorization $sx1.fx.auth -Result $s1cand -Fp $fp1
    Assert-HF (([bool]$s1.ok) -and ([bool]$s1.settled) -and (-not [bool]$s1.duplicate) -and ([int]$s1.executor_calls -eq 0) -and ([int]$script:spyState.calls -eq [int]$script:spyBaseline)) '[S1] valid settle admits with 0 executor calls' ('reason=' + [string]$s1.reason + ' spy=' + [string]$script:spyState.calls + '/' + [string]$script:spyBaseline)
    Assert-HF (([string]$s1.phase -ceq 'settled') -and ([string]$s1.handoff_state -ceq 'SETTLED')) '[S1] settle transitions to SETTLED' ('phase=' + [string]$s1.phase + ' state=' + [string]$s1.handoff_state)
    Assert-HF (([string]$s1.worker_status -ceq 'candidate_pass') -and ([bool]$s1.kernel_ok) -and ([string]$s1.evidence_id -cmatch '^[a-f0-9]{32}$') -and ([bool]$s1.evidence_created)) '[S1] settle reports kernel ok, canonical evidence id and candidate status' ('status=' + [string]$s1.worker_status + ' ev=' + [string]$s1.evidence_id)
    Assert-HF (([string]$s1.child_session_id -ceq 'ses_hf_child_1') -and ([string]$s1.target_agent -ceq 'coder')) '[S1] settle records the child session lineage' ('child=' + [string]$s1.child_session_id)
    $s1raw = Get-HFReceiptRaw -GoalId $sx1.fx.goal -Key $sx1.key
    Assert-HF (($null -ne $s1raw) -and ([string]$s1raw.phase -ceq 'settled') -and ([string]$s1raw.handoff_state -ceq 'SETTLED')) '[S1] durable receipt holds the settled phase' ('phase=' + [string]$s1raw.phase)
    Assert-HF (($null -ne $s1raw) -and ([bool]$s1raw.kernel_ok) -and ([string]$s1raw.worker_result.status -ceq 'candidate_pass') -and ([string]$s1raw.settle_child_session_id -ceq 'ses_hf_child_1')) '[S1] durable receipt holds kernel result and child session' ''
    Assert-HF (($null -ne $s1raw) -and ([string]$s1raw.settle_call_id -ceq $call) -and ([string]$s1raw.settle_caller_agent -ceq 'planner')) '[S1] durable receipt holds the host call provenance' ''
    $s1task = Get-OrchestrationTask -TaskId $sx1.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s1task) -and (-not [string]::IsNullOrWhiteSpace([string]$s1task.worker_result.status)) -and ([string]$s1task.worker_result.status -ceq 'candidate_pass')) '[S1] kernel task really holds the worker result' 'kernel empty'
    $s1evPath = Join-Path $evDir ([string]$s1.evidence_id + '.json')
    Assert-HF (Test-Path -LiteralPath $s1evPath -PathType Leaf) '[S1] canonical evidence record exists in the evidence store' $s1evPath
    $s1ev = $null
    try { $s1ev = ConvertFrom-Json ([IO.File]::ReadAllText($s1evPath, [Text.Encoding]::UTF8)) } catch { $s1ev = $null }
    Assert-HF (($null -ne $s1ev) -and ([string]$s1ev.task_id -ceq $sx1.fx.task) -and ([string]$s1ev.run_id -ceq $sx1.key)) '[S1] evidence record is bound to this task and idempotency key' ''
    Assert-HF (($null -ne $s1ev) -and ([string]$s1ev.source_fingerprints.'native-handoff-child-session' -ceq 'ses_hf_child_1') -and ([string]$s1ev.source_fingerprints.'dispatch-intent' -ceq $sx1.key)) '[S1] evidence provenance carries host call + child session reference' ''
    Assert-HF (($null -ne $s1ev) -and ($null -eq $s1ev.PSObject.Properties['prompt']) -and ($null -eq $s1ev.PSObject.Properties['raw_content'])) '[S1] evidence record carries no prompt text' ''


    # ---------- S2: duplicata identica e idempotente ----------
    $s2same = Invoke-HFSettle -Key $sx1.key -Authorization $sx1.fx.auth -Result $s1cand -Fp $fp1
    Assert-HF (([bool]$s2same.ok) -and ([bool]$s2same.duplicate) -and ([bool]$s2same.settled) -and ([int]$s2same.executor_calls -eq 0)) '[S2] identical duplicate settle is idempotent' ([string]$s2same.reason)
    Assert-HF (([string]$s2same.reason -ceq 'settle-duplicate')) '[S2] idempotent duplicate reports settle-duplicate' ([string]$s2same.reason)
    $s2rev = [long](Get-OrchestrationTask -TaskId $sx1.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($s2rev -eq 2) '[S2] duplicate never rewrites the kernel (revision unchanged)' ('rev=' + [string]$s2rev)
    $s2raw = Get-HFReceiptRaw -GoalId $sx1.fx.goal -Key $sx1.key
    Assert-HF (($null -ne $s2raw) -and ([string]$s2raw.worker_result.status -ceq 'candidate_pass')) '[S2] duplicate keeps the original settled result' ''
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S2] no Executor call on the duplicate settle' ''

    # ---------- S3: duplicata DIVERGENTE e conflito ----------
    $s3a = Invoke-HFSettle -Key $sx1.key -Authorization $sx1.fx.auth -Result (@{ status = 'failed'; claimed_evidence = @('criterion:0') }) -Fp $fp1
    Assert-HF ((-not [bool]$s3a.ok) -and ([string]$s3a.reason -ceq 'settle-result-conflict') -and (-not [bool]$s3a.settled) -and (-not [bool]$s3a.duplicate)) '[S3a] divergent status on a settled receipt conflicts' ([string]$s3a.reason)
    $s3b = Invoke-HFSettle -Key $sx1.key -Authorization $sx1.fx.auth -Result (@{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }) -Fp $fp1
    Assert-HF ((-not [bool]$s3b.ok) -and ([string]$s3b.reason -ceq 'settle-result-conflict')) '[S3b] divergent evidence refs on a settled receipt conflict' ([string]$s3b.reason)
    $s3rev = [long](Get-OrchestrationTask -TaskId $sx1.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($s3rev -eq 2) '[S3] conflicting duplicate never rewrites the kernel' ('rev=' + [string]$s3rev)
    $s3raw = Get-HFReceiptRaw -GoalId $sx1.fx.goal -Key $sx1.key
    Assert-HF (($null -ne $s3raw) -and ([string]$s3raw.phase -ceq 'settled') -and ([string]$s3raw.worker_result.status -ceq 'candidate_pass')) '[S3] the settled receipt is not overwritten by the conflict' ('status=' + [string]$s3raw.worker_result.status)

    # ---------- S4: descritor do host divergente do CLAIM ----------
    $sx4 = New-HFSettleFixture -Suffix 'settle4' -KeyMaterial 'hf-settle-hostdesc-1'
    $fp4 = ([string]$sx4.prepare.prepared_fingerprint)
    $s4a = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Session 'ses_hf_OTHER'
    Assert-HF ((-not [bool]$s4a.ok) -and ([string]$s4a.reason -ceq 'settle-host-call-mismatch')) '[S4a] foreign session (cross-session) refuses before any write' ([string]$s4a.reason)
    $s4b = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Message 'msg_hf_OTHER'
    Assert-HF ((-not [bool]$s4b.ok) -and ([string]$s4b.reason -ceq 'settle-host-call-mismatch')) '[S4b] foreign message id refuses' ([string]$s4b.reason)
    $s4c = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Call 'call_hf_OTHER'
    Assert-HF ((-not [bool]$s4c.ok) -and ([string]$s4c.reason -ceq 'settle-host-call-mismatch')) '[S4c] foreign call id refuses' ([string]$s4c.reason)
    $s4d = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Caller 'reviewer'
    Assert-HF ((-not [bool]$s4d.ok) -and ([string]$s4d.reason -ceq 'settle-host-call-mismatch')) '[S4d] foreign caller agent refuses' ([string]$s4d.reason)
    $s4e = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Target 'tester'
    Assert-HF ((-not [bool]$s4e.ok) -and ([string]$s4e.reason -ceq 'settle-agent-mismatch')) '[S4e] foreign target agent refuses' ([string]$s4e.reason)
    $s4f = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Caller 'coder' -Target 'coder'
    Assert-HF ((-not [bool]$s4f.ok) -and (@('host-agent-invalid', 'settle-agent-mismatch') -ccontains [string]$s4f.reason)) '[S4f] caller equal to target refuses' ([string]$s4f.reason)
    $s4g = Invoke-HFSettle -Key $sx4.key -Authorization $sx4.fx.auth -Result $s1cand -Fp $fp4 -Call 'bad call!!'
    Assert-HF ((-not [bool]$s4g.ok) -and ([string]$s4g.reason -ceq 'host-call-invalid')) '[S4g] malformed call id refuses before any receipt IO' ([string]$s4g.reason)
    $s4raw = Get-HFReceiptRaw -GoalId $sx4.fx.goal -Key $sx4.key
    Assert-HF (($null -ne $s4raw) -and ([string]$s4raw.phase -ceq 'claimed') -and ([string]$s4raw.handoff_state -ceq 'DISPATCH_UNCERTAIN')) '[S4] every refused settle leaves the receipt claimed and unresolved' ('phase=' + [string]$s4raw.phase)
    Assert-HF (($null -ne $s4raw) -and ($null -eq $s4raw.PSObject.Properties['settle_attempt_status'])) '[S4] no attempt marker is written when the descriptor is refused' ''

    # ---------- S5: child session ausente, malformada ou igual ao pai ----------
    $sx5 = New-HFSettleFixture -Suffix 'settle5' -KeyMaterial 'hf-settle-child-1'
    $fp5 = ([string]$sx5.prepare.prepared_fingerprint)
    $s5a = Invoke-HFSettle -Key $sx5.key -Authorization $sx5.fx.auth -Result $s1cand -Fp $fp5 -ChildSession ''
    Assert-HF ((-not [bool]$s5a.ok) -and ([string]$s5a.reason -ceq 'child-session-invalid')) '[S5a] absent child session (no execute.after) refuses' ([string]$s5a.reason)
    $s5b = Invoke-HFSettle -Key $sx5.key -Authorization $sx5.fx.auth -Result $s1cand -Fp $fp5 -ChildSession 'bad child id!!'
    Assert-HF ((-not [bool]$s5b.ok) -and ([string]$s5b.reason -ceq 'child-session-invalid')) '[S5b] malformed child session refuses' ([string]$s5b.reason)
    $s5c = Invoke-HFSettle -Key $sx5.key -Authorization $sx5.fx.auth -Result $s1cand -Fp $fp5 -ChildSession $session
    Assert-HF ((-not [bool]$s5c.ok) -and ([string]$s5c.reason -ceq 'settle-child-session-mismatch')) '[S5c] child session equal to the parent session refuses' ([string]$s5c.reason)
    $s5raw = Get-HFReceiptRaw -GoalId $sx5.fx.goal -Key $sx5.key
    Assert-HF (($null -ne $s5raw) -and ([string]$s5raw.phase -ceq 'claimed')) '[S5] a missing/erroring execute.after keeps the receipt claimed (never "no effect")' ('phase=' + [string]$s5raw.phase)
    $s5task = Get-OrchestrationTask -TaskId $sx5.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s5task) -and ($null -eq $s5task.worker_result)) '[S5] no worker result is written when the child session is unusable' ''
    # um SEGUNDO efeito na mesma task continua bloqueado: a reserva nao foi liberada
    $k5second = Get-NativeDispatchHash32 'hf-settle-child-second'
    $i5second = New-HFIntent -Task $sx5.fx.task -Key $k5second -Gen $sx5.fx.gen
    $p5second = Invoke-OrchestrationNativeDispatchPrepare -Intent $i5second -Authorization $sx5.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p5second.ok) '[S5] second effect on the same task prepared' ([string]$p5second.reason)
    $c5second = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k5second -Authorization $sx5.fx.auth -SessionId $session -MessageId 'msg_hf_s5b' -CallId 'call_hf_s5b' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p5second.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c5second.ok) -and ([string]$c5second.reason -ceq 'claim-task-already-claimed')) '[S5] the unresolved claim still blocks a second effect (no release, no retry)' ([string]$c5second.reason)
    # liquidacao legitima posterior funciona
    $s5ok = Invoke-HFSettle -Key $sx5.key -Authorization $sx5.fx.auth -Result $s1cand -Fp $fp5
    Assert-HF (([bool]$s5ok.ok) -and ([bool]$s5ok.settled)) '[S5] control: the same claim settles once the child session is usable' ([string]$s5ok.reason)


    # ---------- S6: identidade, task, generation e revisao divergentes ----------
    $sx6 = New-HFSettleFixture -Suffix 'settle6' -KeyMaterial 'hf-settle-ident-1'
    $fp6 = ([string]$sx6.prepare.prepared_fingerprint)
    $wrongFp6 = Get-NativeDispatchHash32 'hf-settle-wrong-fingerprint'
    $s6a = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp $wrongFp6
    Assert-HF ((-not [bool]$s6a.ok) -and ([string]$s6a.reason -ceq 'settle-fingerprint-mismatch')) '[S6a] wrong prepared fingerprint refuses' ([string]$s6a.reason)
    $s6b = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp 'not-a-fingerprint'
    Assert-HF ((-not [bool]$s6b.ok) -and ([string]$s6b.reason -ceq 'invalid-prepared-fingerprint')) '[S6b] malformed prepared fingerprint refuses before any receipt IO' ([string]$s6b.reason)
    $s6c = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp $fp6 -Reference 'not-a-reference'
    Assert-HF ((-not [bool]$s6c.ok) -and ([string]$s6c.reason -ceq 'invalid-reference')) '[S6c] malformed handoff reference refuses' ([string]$s6c.reason)
    $s6d = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp $fp6 -Reference (Get-NativeDispatchHash32 'hf-settle-wrong-reference')
    Assert-HF ((-not [bool]$s6d.ok) -and ([string]$s6d.reason -ceq 'settle-reference-mismatch')) '[S6d] foreign handoff reference refuses' ([string]$s6d.reason)
    $s6e = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp $fp6 -TaskId 'hf-task-other-entirely'
    Assert-HF ((-not [bool]$s6e.ok) -and ([string]$s6e.reason -ceq 'settle-task-mismatch')) '[S6e] foreign task id (cross-task) refuses' ([string]$s6e.reason)
    # autorizacao de OUTRO goal: o namespace do proprio goal nao contem a chave
    $s6f = Invoke-HFSettle -Key $sx6.key -Authorization $authTakeover -Result $s1cand -Fp $fp6
    Assert-HF ((-not [bool]$s6f.ok) -and ([string]$s6f.reason -like 'ownership-not-held*') -or ([string]$s6f.reason -ceq 'settle-not-claimed')) '[S6f] authorization of another goal never settles this claim (isolation)' ([string]$s6f.reason)
    # autorizacao valida do MESMO goal, mas com generation staleness
    $s6g = Invoke-HFSettle -Key $sx6.key -Authorization @{ explicit_allow = $true; goal_id = $sx6.fx.goal; owner = 'planner-1'; generation = ($sx6.fx.gen + 7); source = 'planner' } -Result $s1cand -Fp $fp6
    Assert-HF ((-not [bool]$s6g.ok) -and (([string]$s6g.reason -like 'ownership-not-held*') -or ([string]$s6g.reason -ceq 'settle-identity-mismatch'))) '[S6g] stale generation refuses' ([string]$s6g.reason)
    # revisao viva deslocada (outro writer avancou a task): admissao recusa
    $t6 = Get-OrchestrationTask -TaskId $sx6.fx.task -TasksDir $tasksDir
    $adv6 = Invoke-OrchestrationTaskTransition -TaskId $sx6.fx.task -ToState 'PLANNING' -Actor 'planner-1' -ExpectedRevision ([int]$t6.revision) -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$adv6.ok) '[S6] task revision advanced by another writer' ([string]$adv6.error)
    $s6h = Invoke-HFSettle -Key $sx6.key -Authorization $sx6.fx.auth -Result $s1cand -Fp $fp6
    Assert-HF ((-not [bool]$s6h.ok) -and ([string]$s6h.reason -ceq 'task-revision-mismatch')) '[S6h] live revision mismatch refuses (late result)' ([string]$s6h.reason)
    $s6raw = Get-HFReceiptRaw -GoalId $sx6.fx.goal -Key $sx6.key
    Assert-HF (($null -ne $s6raw) -and ([string]$s6raw.phase -ceq 'claimed')) '[S6] every identity/revision refusal leaves the receipt claimed' ('phase=' + [string]$s6raw.phase)

    # ---------- S7: status e evidencia forjados / vazios / invalidos ----------
    $sx7 = New-HFSettleFixture -Suffix 'settle7' -KeyMaterial 'hf-settle-forge-1'
    $fp7 = ([string]$sx7.prepare.prepared_fingerprint)
    $s7bad = @(
        @{ tag = 'verified_pass'; res = @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') }; want = 'status-not-allowed-from-worker' }
        @{ tag = 'done'; res = @{ status = 'done'; claimed_evidence = @('criterion:0') }; want = 'status-not-allowed-from-worker' }
        @{ tag = 'approved'; res = @{ status = 'approved'; claimed_evidence = @('criterion:0') }; want = 'status-not-allowed-from-worker' }
        @{ tag = 'empty-status'; res = @{ status = ''; claimed_evidence = @('criterion:0') }; want = 'status-not-allowed-from-worker' }
        @{ tag = 'missing-status'; res = @{ claimed_evidence = @('criterion:0') }; want = 'status-not-allowed-from-worker' }
        @{ tag = 'no-evidence'; res = @{ status = 'candidate_pass'; claimed_evidence = @() }; want = 'evidence-refs-missing' }
        @{ tag = 'evidence-not-criterion'; res = @{ status = 'candidate_pass'; claimed_evidence = @('evidence:123') }; want = 'evidence-ref-invalid' }
        @{ tag = 'evidence-nonnumeric'; res = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:abc') }; want = 'evidence-ref-invalid' }
        @{ tag = 'evidence-mixed'; res = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'proof:0') }; want = 'evidence-ref-invalid' }
        @{ tag = 'result-null'; res = $null; want = 'result-missing' }
        @{ tag = 'result-string'; res = 'candidate_pass'; want = 'status-not-allowed-from-worker' }
    )
    foreach ($bad in @($s7bad)) {
        $s7 = Invoke-HFSettle -Key $sx7.key -Authorization $sx7.fx.auth -Result $bad.res -Fp $fp7
        $s7ok = ((-not [bool]$s7.ok) -and (-not [bool]$s7.settled) -and ([string]$s7.reason -ceq ([string]$bad.want)) -and ([string]::IsNullOrWhiteSpace([string]$s7.worker_status)))
        Assert-HF $s7ok ('[S7] ' + [string]$bad.tag + ' is refused as a worker claim') ([string]$s7.reason)
    }
    $s7task = Get-OrchestrationTask -TaskId $sx7.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s7task) -and ($null -eq $s7task.worker_result)) '[S7] no forged result ever reaches the kernel' ''
    $s7raw = Get-HFReceiptRaw -GoalId $sx7.fx.goal -Key $sx7.key
    Assert-HF (($null -ne $s7raw) -and ([string]$s7raw.phase -ceq 'claimed') -and ($null -eq $s7raw.PSObject.Properties['settle_attempt_status'])) '[S7] the receipt stays claimed with no attempt marker' ('phase=' + [string]$s7raw.phase)
    Assert-HF (($null -ne $s7raw) -and ($null -eq $s7raw.PSObject.Properties['worker_result']) -and ($null -eq $s7raw.PSObject.Properties['kernel_ok'])) '[S7] the receipt never carries a worker_result or kernel verdict before settlement' ''
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S7] no Executor call for any forged status or evidence' ('')


    # ---------- S8: escrita parcial - evidencia feita, kernel recusado ----------
    $sx8 = New-HFSettleFixture -Suffix 'settle8' -KeyMaterial 'hf-settle-partial-1'
    $fp8 = ([string]$sx8.prepare.prepared_fingerprint)
    $evCountBefore = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $taskFile8 = Get-TaskKernelFilePath -TaskId $sx8.fx.task -TasksDir $tasksDir
    $held8 = $null
    try { $held8 = [IO.File]::Open(($taskFile8 + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $held8 = $null }
    Assert-HF ($null -ne $held8) '[S8] the task file lock is held by the test (kernel write must fail)'
    $s8 = Invoke-HFSettle -Key $sx8.key -Authorization $sx8.fx.auth -Result $s1cand -Fp $fp8
    Assert-HF ((-not [bool]$s8.ok) -and ([string]$s8.reason -like 'settle-kernel-refused*') -and (-not [bool]$s8.settled)) '[S8a] kernel refusal keeps the receipt claimed and unresolved' ([string]$s8.reason)
    try { $held8.Close(); $held8.Dispose() } catch { }
    try { Remove-Item -LiteralPath ($taskFile8 + '.lock') -Force -ErrorAction SilentlyContinue } catch { }
    $s8task = Get-OrchestrationTask -TaskId $sx8.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s8task) -and ($null -eq $s8task.worker_result)) '[S8a] no worker result is written when the kernel refuses' ''
    $s8raw = Get-HFReceiptRaw -GoalId $sx8.fx.goal -Key $sx8.key
    Assert-HF (($null -ne $s8raw) -and ([string]$s8raw.phase -ceq 'claimed') -and ([string]$s8raw.handoff_state -ceq 'DISPATCH_UNCERTAIN')) '[S8a] the receipt stays claimed/DISPATCH_UNCERTAIN (never settled)' ('phase=' + [string]$s8raw.phase)
    Assert-HF (($null -ne $s8raw) -and ($null -ne $s8raw.PSObject.Properties['settle_attempt_status']) -and (-not [string]::IsNullOrWhiteSpace([string]$s8raw.settle_evidence_id))) '[S8a] the attempt marker and the written evidence id are auditable on disk' ('ev=' + [string]$s8raw.settle_evidence_id)
    $evCountAfterFail = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCountAfterFail -gt $evCountBefore) '[S8a] the canonical evidence record WAS written before the kernel refusal' ('before=' + [string]$evCountBefore + ' after=' + [string]$evCountAfterFail)
    # a reserva de task continua valendo: nenhum segundo efeito
    $k8second = Get-NativeDispatchHash32 'hf-settle-partial-second'
    $i8second = New-HFIntent -Task $sx8.fx.task -Key $k8second -Gen $sx8.fx.gen
    $p8second = Invoke-OrchestrationNativeDispatchPrepare -Intent $i8second -Authorization $sx8.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p8second.ok) '[S8a] a second effect on the same task can still be prepared' ([string]$p8second.reason)
    $c8second = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k8second -Authorization $sx8.fx.auth -SessionId $session -MessageId 'msg_hf_s8' -CallId 'call_hf_s8' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p8second.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c8second.ok) -and ([string]$c8second.reason -ceq 'claim-task-already-claimed')) '[S8a] the unresolved claim still blocks a second effect after a kernel failure' ([string]$c8second.reason)
    # retentativa legitima depois da falha do kernel: mesma evidencia, kernel gravado
    $s8b = Invoke-HFSettle -Key $sx8.key -Authorization $sx8.fx.auth -Result $s1cand -Fp $fp8
    Assert-HF (([bool]$s8b.ok) -and ([bool]$s8b.settled) -and (-not [bool]$s8b.reconciled)) '[S8b] the same claim settles once the kernel is writable again' ([string]$s8b.reason)
    $s8bRev = [long](Get-OrchestrationTask -TaskId $sx8.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($s8bRev -eq 2) '[S8b] the kernel is written exactly once' ('rev=' + [string]$s8bRev)
    $evCountAfterOk = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCountAfterOk -eq $evCountAfterFail) '[S8b] the deterministic evidence is reused, never orphaned' ('afterFail=' + [string]$evCountAfterFail + ' afterOk=' + [string]$evCountAfterOk)
    Assert-HF ((([string]$s8.evidence_id -ceq [string]$s8b.evidence_id) -and (-not [string]::IsNullOrWhiteSpace([string]$s8b.evidence_id))) -and (-not [bool]$s8b.reconciled)) '[S8b] the retry reuses the EXACT evidence bound in the first attempt and does the first/only CAS kernel write (no reconcile, no fabrication)' ('first=' + [string]$s8.evidence_id + ' retry=' + [string]$s8b.evidence_id)

    # ---------- S9 (PRA-SETTLE-FIX3): escrita parcial REAL - kernel feito,
    # escrita do recibo 'settled' FALHANDO sem IO no destino ----------
    # PRA-SETTLE-FIX2/3: NAO existe reconciliador dentro do SETTLE e a fase
    # do recibo NUNCA e mutada a mao para fingir crash. A falha e injetada
    # no ESCRITOR (mock deterministico de Write-NDReceipt): ele falha
    # EXATAMENTE quando lhe pedem o recibo final 'settled', isto e, DEPOIS
    # de evidencia e kernel ja persistidos. Provar que o kernel guarda "o
    # mesmo" resultado nao prova que ESTA claim o escreveu (sem marcador
    # atomico kernel-side nao ha prova causal), e esta fatia nao cria
    # evidencia para provar escrita anterior. A retentativa depois de
    # kernel-feito/recibo-nao devolve o bloqueio SEGURO
    # settle-kernel-commit-ambiguous: recibo claimed/reserved mantido, sem
    # nova escrita, sem release e sem retry. Reconciliacao, se houver, e
    # operacao manual do operador.
    $sx9 = New-HFSettleFixture -Suffix 'settle9' -KeyMaterial 'hf-settle-partial-2'
    $fp9 = ([string]$sx9.prepare.prepared_fingerprint)
    $rp9 = Get-HFReceiptPath -GoalId $sx9.fx.goal -Key $sx9.key
    $rp9Claimed = [IO.File]::ReadAllBytes($rp9)
    $evCount9Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $rev9Before = [long](Get-OrchestrationTask -TaskId $sx9.fx.task -TasksDir $tasksDir).revision
    Set-HFReceiptWriteMode -Mode 'fail-settled'
    try {
        $s9a = Invoke-HFSettle -Key $sx9.key -Authorization $sx9.fx.auth -Result $s1cand -Fp $fp9
    }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    # a escrita do recibo FALHOU sem IO no destino: a releitura sob lock
    # prova que o registro NAO e o 'settled' esperado, e a resposta e um
    # estado EXPLICITAMENTE ambiguo - nem 'claimed', nem 'settled'.
    Assert-HF ((-not [bool]$s9a.ok) -and (-not [bool]$s9a.settled) -and (-not [bool]$s9a.duplicate) -and (-not [bool]$s9a.reconciled) -and ([string]$s9a.reason -like 'settle-receipt-proof-*') -and ([string]::IsNullOrWhiteSpace([string]$s9a.phase)) -and ([string]::IsNullOrWhiteSpace([string]$s9a.handoff_state))) '[S9a] the failed final receipt write returns an EXPLICIT ambiguity (never claiming a phase)' ('reason=' + [string]$s9a.reason)
    $s9raw = Get-HFReceiptRaw -GoalId $sx9.fx.goal -Key $sx9.key
    Assert-HF (($null -ne $s9raw) -and ([string]$s9raw.phase -ceq 'claimed') -and ([string]$s9raw.handoff_state -ceq 'DISPATCH_UNCERTAIN') -and (-not [bool](Get-NDValue $s9raw 'reconciled' $false))) '[S9a] the persisted file remains claimed/DISPATCH_UNCERTAIN with no reconciliation' ('phase=' + [string]$s9raw.phase)
    Assert-HF (($null -ne $s9raw) -and ([string]$s9raw.settle_attempt_status -ceq 'candidate_pass') -and ((@($s9raw.settle_attempt_claimed_evidence) -join ',') -ceq 'criterion:0,criterion:1') -and (-not [string]::IsNullOrWhiteSpace([string]$s9raw.settle_evidence_id))) '[S9a] the durable settle-ATTEMPT and EVIDENCE markers are on disk (written before the failed final write)' ('ev=' + [string]$s9raw.settle_evidence_id)
    Assert-HF (($null -ne $s9raw) -and ($null -eq $s9raw.PSObject.Properties['worker_result']) -and ($null -eq $s9raw.PSObject.Properties['kernel_ok'])) '[S9a] the receipt carries no worker_result or kernel verdict: it is not settled' ''
    $rev9 = [long](Get-OrchestrationTask -TaskId $sx9.fx.task -TasksDir $tasksDir).revision
    Assert-HF (($rev9 -eq 2) -and ($rev9Before -eq 1)) '[S9a] the TaskKernel result HAS advanced (kernel write completed before the receipt write)' ('rev=' + [string]$rev9Before + '->' + [string]$rev9)
    Assert-HF (([string](Get-OrchestrationTask -TaskId $sx9.fx.task -TasksDir $tasksDir).worker_result.status -ceq 'candidate_pass')) '[S9a] the kernel holds the candidate of THIS claim' ''
    $evCount9 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount9 -eq ($evCount9Before + 1)) '[S9a] exactly ONE evidence row exists for this claim (no orphan)' ('before=' + [string]$evCount9Before + ' after=' + [string]$evCount9)
    $rp9After = [IO.File]::ReadAllBytes($rp9)
    Assert-HF ($rp9After.Length -gt $rp9Claimed.Length) '[S9a] the file changed only by the durable markers (no fabricated settle write)' 'content not grown'
    # retentativa legitima depois da falha: bloqueio SEGURO, sem nova escrita
    $s9b = Invoke-HFSettle -Key $sx9.key -Authorization $sx9.fx.auth -Result $s1cand -Fp $fp9
    Assert-HF ((-not [bool]$s9b.ok) -and (-not [bool]$s9b.settled) -and (-not [bool]$s9b.reconciled) -and ([string]$s9b.reason -ceq 'settle-kernel-commit-ambiguous') -and ([string]::IsNullOrWhiteSpace([string]$s9b.evidence_id))) '[S9a] the retry after the receipt-write failure stays settle-kernel-commit-ambiguous (no causal proof, no reconcile)' ([string]$s9b.reason)
    $s9bRev = [long](Get-OrchestrationTask -TaskId $sx9.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($s9bRev -eq $rev9) '[S9a] the ambiguous retry never rewrites the kernel (no second kernel write)' ('before=' + [string]$rev9 + ' after=' + [string]$s9bRev)
    $evCount9b = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount9b -eq $evCount9) '[S9a] the ambiguous retry creates no orphan evidence row' ('before=' + [string]$evCount9 + ' after=' + [string]$evCount9b)
    Assert-HF (($null -ne $s9raw) -and ([string]$s9raw.phase -ceq 'claimed') -and ([string]$s9raw.settle_evidence_id -ceq [string]$s9a.evidence_id)) '[S9a] the durable evidence marker from the failed attempt is STILL on the receipt - and still proves nothing (marker != causal proof)' ('marker=' + [string]$s9raw.settle_evidence_id)
    $rp9Final = [IO.File]::ReadAllBytes($rp9)
    $rp9Same = ($rp9Final.Length -eq $rp9After.Length)
    if ($rp9Same) { for ($bi = 0; $bi -lt $rp9Final.Length; $bi++) { if ([int]$rp9Final[$bi] -ne [int]$rp9After[$bi]) { $rp9Same = $false; break } } }
    Assert-HF $rp9Same '[S9a] the ambiguous retry left the claimed receipt byte-identical (no fabricated write)' 'content changed'
    # a reserva de task continua valendo: nenhum segundo efeito (sem release).
    $k9second = Get-NativeDispatchHash32 'hf-settle-partial-second'
    $i9second = New-HFIntent -Task $sx9.fx.task -Key $k9second -Gen $sx9.fx.gen -Rev $rev9
    $p9second = Invoke-OrchestrationNativeDispatchPrepare -Intent $i9second -Authorization $sx9.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p9second.ok) '[S9a] a second effect on the same task can still be prepared' ([string]$p9second.reason)
    $c9second = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k9second -Authorization $sx9.fx.auth -SessionId $session -MessageId 'msg_hf_s9' -CallId 'call_hf_s9' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p9second.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c9second.ok) -and ([string]$c9second.reason -ceq 'claim-task-already-claimed')) '[S9a] the ambiguous claim keeps the task reservation intact (no release, no retry)' ([string]$c9second.reason)
    # retentativa DIVERGENTE para a MESMA claim: o marcador de tentativa do
    # proprio recibo (lado recibo, nao kernel) continua sendo conflito.
    $s9c = Invoke-HFSettle -Key $sx9.key -Authorization $sx9.fx.auth -Result (@{ status = 'blocked'; claimed_evidence = @('criterion:0') }) -Fp $fp9
    Assert-HF ((-not [bool]$s9c.ok) -and ([string]$s9c.reason -ceq 'settle-result-conflict')) '[S9b] a divergent retry for the same claim still conflicts' ([string]$s9c.reason)
    $rp9bFinal = [IO.File]::ReadAllBytes($rp9)
    $rp9bSame = ($rp9bFinal.Length -eq $rp9After.Length)
    if ($rp9bSame) { for ($bi = 0; $bi -lt $rp9bFinal.Length; $bi++) { if ([int]$rp9bFinal[$bi] -ne [int]$rp9After[$bi]) { $rp9bSame = $false; break } } }
    Assert-HF $rp9bSame '[S9b] the conflicting retry left the claimed receipt byte-identical' 'content changed'
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S9] no Executor call during the partial-write scenario' ''


    # ---------- S10: recibos corrompidos / adulterados ----------
    $sx10 = New-HFSettleFixture -Suffix 'settle10' -KeyMaterial 'hf-settle-corrupt-1'
    $fp10 = ([string]$sx10.prepare.prepared_fingerprint)
    $rp10 = Get-HFReceiptPath -GoalId $sx10.fx.goal -Key $sx10.key
    $s10good = [IO.File]::ReadAllText($rp10, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($rp10, ('{"schema_version":1,"idempotency_key":"' + $sx10.key + '","phase":"cla'), [Text.UTF8Encoding]::new($false))
    $s10a = Invoke-HFSettle -Key $sx10.key -Authorization $sx10.fx.auth -Result $s1cand -Fp $fp10
    Assert-HF ((-not [bool]$s10a.ok) -and ([string]$s10a.reason -ceq 'receipt-json-invalid') -and (-not [bool]$s10a.settled)) '[S10a] truncated JSON receipt denies the settle' ([string]$s10a.reason)
    # campo semantico adulterado com hash intacto
    $s10obj = ConvertFrom-Json $s10good
    Add-Member -InputObject $s10obj -Name 'task_expected_revision' -Value 9 -MemberType NoteProperty -Force
    [IO.File]::WriteAllText($rp10, (ConvertTo-Json -InputObject $s10obj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $s10b = Invoke-HFSettle -Key $sx10.key -Authorization $sx10.fx.auth -Result $s1cand -Fp $fp10
    Assert-HF ((-not [bool]$s10b.ok) -and ([string]$s10b.reason -ceq 'receipt-integrity-invalid')) '[S10b] semantically tampered receipt denies the settle' ([string]$s10b.reason)
    # campo em forma de array (token cru divergente)
    $s10obj2 = ConvertFrom-Json $s10good
    Add-Member -InputObject $s10obj2 -Name 'task_id' -Value @([string]$s10obj2.task_id) -MemberType NoteProperty -Force
    [IO.File]::WriteAllText($rp10, (ConvertTo-Json -InputObject $s10obj2 -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $s10c = Invoke-HFSettle -Key $sx10.key -Authorization $sx10.fx.auth -Result $s1cand -Fp $fp10
    Assert-HF ((-not [bool]$s10c.ok) -and ([string]$s10c.reason -ceq 'receipt-integrity-invalid')) '[S10c] array-token field in the receipt denies the settle' ([string]$s10c.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S10] no Executor call for any corrupt receipt' ''
    # restaura o recibo bom ANTES de criar outro fixture: a varredura de
    # reserva caminha TODAS as namespaces e um recibo adulterado recusa
    # fail-closed qualquer novo claim.
    [IO.File]::WriteAllText($rp10, $s10good, [Text.UTF8Encoding]::new($false))
    # recibo NAO-arquivo no caminho: nem ausencia, nem sobrescrita
    $sx10b = New-HFSettleFixture -Suffix 'settle10b' -KeyMaterial 'hf-settle-corrupt-2'
    $fp10b = ([string]$sx10b.prepare.prepared_fingerprint)
    $rp10b = Get-HFReceiptPath -GoalId $sx10b.fx.goal -Key $sx10b.key
    Remove-Item -LiteralPath $rp10b -Force
    New-Item -ItemType Directory -Path $rp10b -Force | Out-Null
    $s10d = Invoke-HFSettle -Key $sx10b.key -Authorization $sx10b.fx.auth -Result $s1cand -Fp $fp10b
    Assert-HF ((-not [bool]$s10d.ok) -and ([string]$s10d.reason -ceq 'receipt-not-regular')) '[S10d] a receipt-shaped DIRECTORY is never overwritten' ([string]$s10d.reason)
    Assert-HF (Test-Path -LiteralPath $rp10b -PathType Container) '[S10d] the directory entry is preserved' ''
    Remove-Item -LiteralPath $rp10b -Force
    # uma entrada com nome de recibo que nao e arquivo regular TAMBEM
    # impede qualquer claim novo na raiz (varredura fail-closed).
    $k10e = Get-NativeDispatchHash32 'hf-settle-corrupt-3'
    $i10e = New-HFIntent -Task $sx10b.fx.task -Key $k10e -Gen $sx10b.fx.gen
    $p10e = Invoke-OrchestrationNativeDispatchPrepare -Intent $i10e -Authorization $sx10b.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p10e.ok) '[S10e] prepared while every receipt entry is a regular file again' ([string]$p10e.reason)
    $s10ok = Invoke-HFSettle -Key $sx10.key -Authorization $sx10.fx.auth -Result $s1cand -Fp $fp10
    Assert-HF (([bool]$s10ok.ok) -and ([bool]$s10ok.settled)) '[S10] control: an untampered receipt settles again' ([string]$s10ok.reason)

    # ---------- S11: liquidar um recibo NAO claimeado ----------
    $sx11 = New-HFIsolatedFixture -Suffix 'settle11'
    $k11s = Get-NativeDispatchHash32 'hf-settle-notclaimed-1'
    $i11s = New-HFIntent -Task $sx11.task -Key $k11s -Gen $sx11.gen
    $p11s = Invoke-OrchestrationNativeDispatchPrepare -Intent $i11s -Authorization $sx11.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p11s.ok) '[S11] prepared for the unclaimed fixture' ([string]$p11s.reason)
    $s11a = Invoke-HFSettle -Key $k11s -Authorization $sx11.auth -Result $s1cand -Fp ([string]$p11s.prepared_fingerprint)
    Assert-HF ((-not [bool]$s11a.ok) -and ([string]$s11a.reason -ceq 'settle-not-claimed')) '[S11a] a prepared (never claimed) receipt is not settleable' ([string]$s11a.reason)
    $s11raw = Get-HFReceiptRaw -GoalId $sx11.goal -Key $k11s
    Assert-HF (($null -ne $s11raw) -and ([string]$s11raw.phase -ceq 'prepared')) '[S11a] the prepared receipt is untouched' ('phase=' + [string]$s11raw.phase)
    # recibo legado pending
    $k11l = Get-NativeDispatchHash32 'hf-settle-legacy-pending'
    $i11lFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $sx11.task -Key $k11l -Gen $sx11.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $sx11.goal -Key $k11l), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $k11l; phase = 'pending'; task_id = $sx11.task; agent = 'coder'; owner = 'planner-1'; goal_id = $sx11.goal; ownership_generation = $sx11.gen; task_expected_revision = 1; intent_fingerprint = $i11lFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $s11b = Invoke-HFSettle -Key $k11l -Authorization $sx11.auth -Result $s1cand -Fp (Get-NativeDispatchHash32 'hf-settle-legacy-fp')
    Assert-HF ((-not [bool]$s11b.ok) -and ([string]$s11b.reason -ceq 'settle-phase-conflict')) '[S11b] a legacy pending receipt conflicts' ([string]$s11b.reason)
    # chave ausente
    $k11c = Get-NativeDispatchHash32 'hf-settle-absent-1'
    $s11c = Invoke-HFSettle -Key $k11c -Authorization $sx11.auth -Result $s1cand -Fp (Get-NativeDispatchHash32 'hf-settle-legacy-fp')
    Assert-HF ((-not [bool]$s11c.ok) -and ([string]$s11c.reason -ceq 'settle-not-claimed')) '[S11c] an absent key denies as not claimed' ([string]$s11c.reason)
    # chave malformada
    $s11d = Invoke-HFSettle -Key 'not-a-key' -Authorization $sx11.auth -Result $s1cand -Fp (Get-NativeDispatchHash32 'hf-settle-legacy-fp')
    Assert-HF ((-not [bool]$s11d.ok) -and ([string]$s11d.reason -ceq 'invalid-idempotency-key')) '[S11d] a malformed key denies before any receipt IO' ([string]$s11d.reason)
    # o caminho legado continua dono do recibo pending: sem prova externa
    # de idempotencia ele NAO faz replay (pending-ambiguous), e o recibo
    # liquidado pelo legado nao e alcancado pelo SETTLE.
    $l11spy = { param($i) $script:spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $l11 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $sx11.task -Key $k11l -Gen $sx11.gen).intent -Executor $l11spy -Authorization $sx11.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$l11.ok) -and ([string]$l11.reason -ceq 'pending-ambiguous') -and ([int]$l11.executor_calls -eq 0)) '[S11] control: the legacy path still refuses to replay its own pending (no implicit retry)' ([string]$l11.reason)

    # ---------- S12: o envelope NUNCA carrega verified/done ----------
    Assert-HF ((-not [bool]$s1.worker_status.Contains('verified')) -and (-not [bool]$s1.worker_status.Contains('done')) -and (-not [bool]$s1.worker_status.Contains('approved'))) '[S12] the settle envelope reports only a candidate worker status' ([string]$s1.worker_status)
    $s12raw = Get-HFReceiptRaw -GoalId $sx1.fx.goal -Key $sx1.key
    Assert-HF (($null -ne $s12raw) -and (@('candidate_pass', 'failed', 'blocked') -ccontains [string]$s12raw.worker_result.status)) '[S12] the durable receipt stores only a candidate worker status' ([string]$s12raw.worker_result.status)
    $s12task = Get-OrchestrationTask -TaskId $sx1.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s12task) -and ([string]$s12task.state -cne 'DONE') -and ([string]$s12task.state -cne 'EXHAUSTED')) '[S12] SETTLE never advances the task to a terminal state' ('state=' + [string]$s12task.state)
    Assert-HF ((-not [bool]$s1.ok -eq $false) -and ([bool]$s1.ok)) '[S12] settle ok is exactly the kernel verdict, not a verification' ''


    # ---------- S13: lock de task impede claim novo ATE liquidar ----------
    $sx13 = New-HFSettleFixture -Suffix 'settle13' -KeyMaterial 'hf-settle-tasklock-1'
    $fp13 = ([string]$sx13.prepare.prepared_fingerprint)
    $taskLockPath13 = Get-NDTaskLockPath -RootDir $receiptDir -TaskId $sx13.fx.task
    Assert-HF ((-not [string]::IsNullOrWhiteSpace($taskLockPath13)) -and (Test-Path -LiteralPath $taskLockPath13 -PathType Leaf)) '[S13] the task lock exists at the receipt root (shared reservation)' $taskLockPath13
    $held13 = $null
    try { $held13 = [IO.File]::Open($taskLockPath13, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $held13 = $null }
    Assert-HF ($null -ne $held13) '[S13] the task lock is held by the test'
    $s13a = Invoke-HFSettle -Key $sx13.key -Authorization $sx13.fx.auth -Result $s1cand -Fp $fp13 -LockTimeoutMs 250
    Assert-HF ((-not [bool]$s13a.ok) -and ([string]$s13a.reason -ceq 'task-lock-busy') -and (-not [bool]$s13a.settled)) '[S13a] a settle that cannot take the task lock refuses as busy' ([string]$s13a.reason)
    # claim novo na MESMA task tambem e barrado pelo lock de task
    $k13n = Get-NativeDispatchHash32 'hf-settle-tasklock-2'
    $i13n = New-HFIntent -Task $sx13.fx.task -Key $k13n -Gen $sx13.fx.gen
    $p13n = Invoke-OrchestrationNativeDispatchPrepare -Intent $i13n -Authorization $sx13.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p13n.ok) '[S13a] a second effect on the same task can still be prepared' ([string]$p13n.reason)
    $c13n = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13n -Authorization $sx13.fx.auth -SessionId $session -MessageId 'msg_hf_s13' -CallId 'call_hf_s13' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13n.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -LockTimeoutMs 250
    Assert-HF ((-not [bool]$c13n.ok) -and ([string]$c13n.reason -ceq 'task-lock-busy')) '[S13a] a new claim on the same task is barred by the held task lock' ([string]$c13n.reason)
    try { $held13.Close(); $held13.Dispose() } catch { }
    # reserva ainda nao resolvida: claim novo continua bloqueado
    $c13b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13n -Authorization $sx13.fx.auth -SessionId $session -MessageId 'msg_hf_s13' -CallId 'call_hf_s13' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13n.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c13b.ok) -and ([string]$c13b.reason -ceq 'claim-task-already-claimed')) '[S13b] the unresolved claim still blocks a new claim on the same task' ([string]$c13b.reason)
    # liquidacao legitima libera a reserva (a revisao da task avancou com
    # o settlement, entao a nova intent usa a revisao viva atual).
    $s13c = Invoke-HFSettle -Key $sx13.key -Authorization $sx13.fx.auth -Result $s1cand -Fp $fp13
    Assert-HF (([bool]$s13c.ok) -and ([bool]$s13c.settled)) '[S13c] the settle completes once the lock is free' ([string]$s13c.reason)
    $t13live = Get-OrchestrationTask -TaskId $sx13.fx.task -TasksDir $tasksDir
    $k13n2 = Get-NativeDispatchHash32 'hf-settle-tasklock-3'
    $i13n2 = New-HFIntent -Task $sx13.fx.task -Key $k13n2 -Gen $sx13.fx.gen -Rev ([long]$t13live.revision)
    $p13n2 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i13n2 -Authorization $sx13.fx.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p13n2.ok) '[S13c] a second effect prepares with the live revision' ([string]$p13n2.reason)
    $c13d = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k13n2 -Authorization $sx13.fx.auth -SessionId $session -MessageId 'msg_hf_s13' -CallId 'call_hf_s13' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p13n2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$c13d.ok) -and ([bool]$c13d.claimed)) '[S13c] after settlement the task reservation is RELEASED (new claim admitted)' ([string]$c13d.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S13] no Executor call anywhere in the task-lock scenario' ''

    # ---------- S14: isolamento com o caminho legado ----------
    # fixture proprio: a lease de ownership do fixture do S1 ja expirou
    # naturalmente no decorrer da suite, e uma autorizacao staleness nao
    # provaria o isolamento que este cenario quer provar.
    $sx14 = New-HFSettleFixture -Suffix 'settle14' -KeyMaterial 'hf-settle-legacy-1'
    $fp14 = ([string]$sx14.prepare.prepared_fingerprint)
    $s14a = Invoke-HFSettle -Key $sx14.key -Authorization $sx14.fx.auth -Result $s1cand -Fp $fp14
    Assert-HF (([bool]$s14a.ok) -and ([bool]$s14a.settled)) '[S14] settled fixture for the legacy isolation scenario' ([string]$s14a.reason)
    $s14path = Get-HFReceiptPath -GoalId $sx14.fx.goal -Key $sx14.key
    $s14rawBefore = [IO.File]::ReadAllBytes($s14path)
    $s14spyState = @{ calls = 0 }
    $s14spy = { param($i) $s14spyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $s14 = Invoke-OrchestrationNativeDispatch -Intent $sx14.intent.intent -Executor $s14spy -Authorization $sx14.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$s14.duplicate) -and ([int]$s14.executor_calls -eq 0) -and ([int]$s14spyState.calls -eq 0)) '[S14] the legacy Invoke reads the handoff SETTLED receipt as a duplicate with 0 executor calls' ([string]$s14.reason)
    Assert-HF (([string]$s14.reason -ceq 'idempotent-duplicate') -or ([string]$s14.reason -ceq 'duplicate-identity-mismatch')) '[S14] the legacy duplicate is explicit, never a second effect' ([string]$s14.reason)
    $s14rawAfter = [IO.File]::ReadAllBytes($s14path)
    Assert-HF (($s14rawAfter.Length -eq $s14rawBefore.Length)) '[S14] the settled handoff receipt keeps its size after the legacy call' 'size changed'
    if ($s14rawAfter.Length -eq $s14rawBefore.Length) {
        $s14same = $true
        for ($bi = 0; $bi -lt $s14rawAfter.Length; $bi++) { if ([int]$s14rawAfter[$bi] -ne [int]$s14rawBefore[$bi]) { $s14same = $false; break } }
        Assert-HF $s14same '[S14] the settled handoff receipt is byte-identical after the legacy call' 'content changed'
    }
    $s14task = Get-OrchestrationTask -TaskId $sx14.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s14task) -and ([int]$s14task.revision -eq 2)) '[S14] the legacy call never rewrote the kernel worker result' ('rev=' + [string]$s14task.revision)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S14] the isolated spy was used only for this control, never by the handoff path' ''


    # ---------- S15 (PRA-SETTLE F1): worker_result HISTORICO (revisao <=
    # esperada) NAO bloqueia uma tentativa nova com candidato divergente ----------
    # Um resultado gravado em revisao <= a revisao esperada do recito e de
    # OUTRO claim/tentativa: nao pertence a este CLAIM. A comparacao de
    # candidato so pode vincular escrita POS-claim (revisao avancada alem do
    # esperado). Aqui ela nunca gera settle-result-conflict nem trava a
    # liquidacao legitima; o CAS sobrescreve legitimamente.
    $sx15 = New-HFIsolatedFixture -Suffix 'settle15'
    $w15 = Set-OrchestrationTaskWorkerResult -TaskId $sx15.task -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
    Assert-HF ([bool]$w15.ok) '[S15] a historical (foreign) worker result advanced the task 1 -> 2' ([string]$w15.error)
    $k15 = Get-NativeDispatchHash32 'hf-settle-historical-1'
    $i15 = New-HFIntent -Task $sx15.task -Key $k15 -Gen $sx15.gen -Rev 2
    $p15 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i15 -Authorization $sx15.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p15.ok) '[S15] prepared a new claim at the live revision' ([string]$p15.reason)
    $c15 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k15 -Authorization $sx15.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p15.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c15.ok) '[S15] claimed the new attempt' ([string]$c15.reason)
    # candidato com o MESMO status mas refs DIVERGENTES do resultado historico:
    # antes do fix isso geraria um settle-result-conflict falso.
    $s15 = Invoke-HFSettle -Key $k15 -Authorization $sx15.auth -Result (@{ status = 'candidate_pass'; claimed_evidence = @('criterion:1') }) -Fp ([string]$p15.prepared_fingerprint)
    Assert-HF (([bool]$s15.ok) -and ([bool]$s15.settled) -and (-not [bool]$s15.duplicate)) '[S15] a new legitimate claim with a divergent candidate settles over a HISTORICAL result (no false conflict)' ([string]$s15.reason)
    $s15task = Get-OrchestrationTask -TaskId $sx15.task -TasksDir $tasksDir
    Assert-HF ((([int]$s15task.revision -eq 3) -and ([string]$s15task.worker_result.status -ceq 'candidate_pass') -and ((@($s15task.worker_result.claimed_evidence) -join ',') -ceq 'criterion:1'))) '[S15] the kernel holds the NEW candidate at revision 3 (exactly one CAS write)' ('rev=' + [string]$s15task.revision + ' refs=' + (@($s15task.worker_result.claimed_evidence) -join ','))

    # ---------- S16 (PRA-SETTLE F2): worker_result POS-claim (revisao alem do
    # esperado) SEM prova causal duravel => settle-kernel-commit-ambiguous ----------
    # Um escritor ALHEIO gravou no kernel o MESMO status/refs do candidato
    # (revisao 1 -> 2), mas este recito NUNCA persistiu settle_evidence_id:
    # nao ha prova de que ESTE claim escreveu o kernel. Sem criar evidencia
    # para provar escrita anterior, a liquidacao volta um estado tipado e
    # seguro: claimed/reserved mantido, sem nova escrita e sem release.
    $sx16 = New-HFIsolatedFixture -Suffix 'settle16'
    $k16 = Get-NativeDispatchHash32 'hf-settle-ambiguous-1'
    $i16 = New-HFIntent -Task $sx16.task -Key $k16 -Gen $sx16.gen -Rev 1
    $p16 = Invoke-OrchestrationNativeDispatchPrepare -Intent $i16 -Authorization $sx16.auth -SessionId $session -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p16.ok) '[S16] prepared the ambiguous fixture' ([string]$p16.reason)
    $c16 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k16 -Authorization $sx16.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p16.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$c16.ok) '[S16] claimed the ambiguous fixture' ([string]$c16.reason)
    $w16 = Set-OrchestrationTaskWorkerResult -TaskId $sx16.task -Status 'candidate_pass' -ClaimedEvidence @('criterion:0', 'criterion:1') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
    Assert-HF ([bool]$w16.ok) '[S16] an unrelated writer posted an identical kernel result beyond the expected revision' ([string]$w16.error)
    $evCount16Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $rev16Before = [long](Get-OrchestrationTask -TaskId $sx16.task -TasksDir $tasksDir).revision
    $s16 = Invoke-HFSettle -Key $k16 -Authorization $sx16.auth -Result (@{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'criterion:1') }) -Fp ([string]$p16.prepared_fingerprint)
    Assert-HF ((-not [bool]$s16.ok) -and (-not [bool]$s16.settled) -and ([string]$s16.reason -ceq 'settle-kernel-commit-ambiguous')) '[S16] revision advanced beyond expected with no durable evidence proof => settle-kernel-commit-ambiguous' ([string]$s16.reason)
    $s16raw = Get-HFReceiptRaw -GoalId $sx16.goal -Key $k16
    Assert-HF (($null -ne $s16raw) -and ([string]$s16raw.phase -ceq 'claimed') -and ($null -eq $s16raw.PSObject.Properties['worker_result'])) '[S16] the receipt stays claimed and unresolved (no settled write)' ('phase=' + [string]$s16raw.phase)
    Assert-HF (($null -ne $s16raw) -and ($null -eq $s16raw.PSObject.Properties['settle_attempt_status']) -and ($null -eq $s16raw.PSObject.Properties['settle_evidence_id'])) '[S16] the ambiguous settle wrote NOTHING on the receipt (no attempt marker, no evidence id)' ''
    $evCount16After = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount16After -eq $evCount16Before) '[S16] NO evidence is created to prove a previous write' ('before=' + [string]$evCount16Before + ' after=' + [string]$evCount16After)
    $rev16After = [long](Get-OrchestrationTask -TaskId $sx16.task -TasksDir $tasksDir).revision
    Assert-HF ($rev16After -eq $rev16Before) '[S16] no second kernel write happens' ('rev=' + [string]$rev16After)
    # a reserva de task continua valendo: nenhum segundo efeito (sem release).
    $k16b = Get-NativeDispatchHash32 'hf-settle-ambiguous-second'
    $i16b = New-HFIntent -Task $sx16.task -Key $k16b -Gen $sx16.gen -Rev 2
    $p16b = Invoke-OrchestrationNativeDispatchPrepare -Intent $i16b -Authorization $sx16.auth -SessionId 'ses_hf_s16b' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p16b.ok) '[S16] a second effect on the ambiguous task prepared' ([string]$p16b.reason)
    $c16b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k16b -Authorization $sx16.auth -SessionId 'ses_hf_s16b' -MessageId 'msg_hf_s16b' -CallId 'call_hf_s16b' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p16b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c16b.ok) -and ([string]$c16b.reason -ceq 'claim-task-already-claimed')) '[S16] the ambiguous claim keeps the task reservation intact (no release, no retry)' ([string]$c16b.reason)

    # ---------- S17 (PRA-SETTLE F5): refs do candidato em ordem INVERTIDA
    # produzem a MESMA evidencia canonica (uma linha/ID, sem orfao) ----------
    $sx17 = New-HFSettleFixture -Suffix 'settle17' -KeyMaterial 'hf-settle-reversed-1'
    $fp17 = ([string]$sx17.prepare.prepared_fingerprint)
    $taskFile17 = Get-TaskKernelFilePath -TaskId $sx17.fx.task -TasksDir $tasksDir
    $held17 = $null
    try { $held17 = [IO.File]::Open(($taskFile17 + '.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { $held17 = $null }
    Assert-HF ($null -ne $held17) '[S17] the task file lock is held so the first attempt stops at the kernel'
    $s17a = Invoke-HFSettle -Key $sx17.key -Authorization $sx17.fx.auth -Result (@{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'criterion:1') }) -Fp $fp17
    Assert-HF ((-not [bool]$s17a.ok) -and ([string]$s17a.reason -like 'settle-kernel-refused*') -and (-not [bool]$s17a.settled)) '[S17a] the first attempt wrote evidence but the kernel refused' ([string]$s17a.reason)
    $evId17 = ([string]$s17a.evidence_id)
    Assert-HF ($evId17 -cmatch '^[a-f0-9]{32}$') '[S17a] the first attempt persisted a canonical evidence id' $evId17
    $evCount17 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    try { $held17.Close(); $held17.Dispose() } catch { }
    try { Remove-Item -LiteralPath ($taskFile17 + '.lock') -Force -ErrorAction SilentlyContinue } catch { }
    # retentativa com as refs EM ORDEM INVERTIDA: a canonicalizacao unica faz
    # o criteria_hash (fingerprint do evidence store) coincidir.
    $s17b = Invoke-HFSettle -Key $sx17.key -Authorization $sx17.fx.auth -Result (@{ status = 'candidate_pass'; claimed_evidence = @('criterion:1', 'criterion:0') }) -Fp $fp17
    Assert-HF (([bool]$s17b.ok) -and ([bool]$s17b.settled) -and (-not [bool]$s17b.reconciled)) '[S17b] a reversed-order retry still settles (refs canonicalized once)' ([string]$s17b.reason)
    $rev17 = [long](Get-OrchestrationTask -TaskId $sx17.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev17 -eq 2) '[S17b] the kernel is written exactly once' ('rev=' + [string]$rev17)
    $s17task = Get-OrchestrationTask -TaskId $sx17.fx.task -TasksDir $tasksDir
    Assert-HF (((@($s17task.worker_result.claimed_evidence) -join ',') -ceq 'criterion:0,criterion:1')) '[S17b] the kernel stores the candidate refs in the ONE canonical order' ('refs=' + (@($s17task.worker_result.claimed_evidence) -join ','))
    $s17raw = Get-HFReceiptRaw -GoalId $sx17.fx.goal -Key $sx17.key
    Assert-HF (((@($s17raw.settle_claimed_evidence) -join ',') -ceq 'criterion:0,criterion:1')) '[S17b] the settled receipt stores the same canonical order' ('refs=' + (@($s17raw.settle_claimed_evidence) -join ','))
    $evCount17b = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount17b -eq $evCount17) '[S17b] the reversed-order retry reuses the SAME evidence row - no orphan' ('before=' + [string]$evCount17 + ' after=' + [string]$evCount17b)
    Assert-HF (([string]$s17b.evidence_id -ceq $evId17)) '[S17b] the reversed-order retry derives the SAME canonical evidence id' ('before=' + $evId17 + ' after=' + [string]$s17b.evidence_id)

    # ---------- S18 (PRA-SETTLE F3): fencing pos-lock em TODA liquidacao -
    # com os dois locks segurados e imediatamente antes de cada escrita ----------
    # Cenario deterministico: o teste ocupa o lock do recibo e, ENQUANTO a
    # liquidacao esperaria, tira o goal de ACTIVE. O gate pre-lock passa
    # (PAUSED nao e terminal e a ownership segue valida), portanto a recusa
    # so pode vir da revalidacao feita COM OS LOCKS SEGURADOS.
    $sx18 = New-HFSettleFixture -Suffix 'settle18' -KeyMaterial 'hf-settle-fence-1'
    $fp18 = ([string]$sx18.prepare.prepared_fingerprint)
    $rp18 = Get-HFReceiptPath -GoalId $sx18.fx.goal -Key $sx18.key
    $s18before = [IO.File]::ReadAllBytes($rp18)
    $held18 = Open-HFReceiptLockHeld -GoalId $sx18.fx.goal
    Assert-HF ($null -ne $held18) '[S18] the test holds the receipt lock of the fence fixture'
    if ($null -ne $held18) {
        try {
            $ch18 = Set-HFGoalStateLive -GoalId $sx18.fx.goal -ToState 'PAUSED' -Gen $sx18.fx.gen
            Assert-HF ([bool]$ch18.ok) '[S18] the goal left ACTIVE (PAUSED) while the settle would wait on the lock' ([string]$ch18.reason)
        }
        finally { try { $held18.Dispose() } catch { } }
    }
    $s18 = Invoke-HFSettle -Key $sx18.key -Authorization $sx18.fx.auth -Result $s1cand -Fp $fp18
    Assert-HF ((-not [bool]$s18.ok) -and (-not [bool]$s18.settled) -and (-not [bool]$s18.reconciled) -and ([string]$s18.reason -like 'post-lock-goal-not-active*')) '[S18] the settle fences on a non-ACTIVE goal with both locks held (no partial bypass)' ([string]$s18.reason)
    $s18raw = Get-HFReceiptRaw -GoalId $sx18.fx.goal -Key $sx18.key
    Assert-HF (($null -ne $s18raw) -and ([string]$s18raw.phase -ceq 'claimed') -and ($null -eq $s18raw.PSObject.Properties['settle_attempt_status'])) '[S18] the receipt stays claimed with no attempt marker (refused before any write)' ('phase=' + [string]$s18raw.phase)
    $s18after = [IO.File]::ReadAllBytes($rp18)
    $s18same = ($s18after.Length -eq $s18before.Length)
    if ($s18same) { for ($bi = 0; $bi -lt $s18after.Length; $bi++) { if ([int]$s18after[$bi] -ne [int]$s18before[$bi]) { $s18same = $false; break } } }
    Assert-HF $s18same '[S18] the fenced settle left the claimed receipt byte-identical' 'content changed'
    # controle: com o goal de volta a ACTIVE, a MESMA liquidacao conclui.
    $ch18b = Set-HFGoalStateLive -GoalId $sx18.fx.goal -ToState 'ACTIVE' -Gen $sx18.fx.gen
    Assert-HF ([bool]$ch18b.ok) '[S18] the goal is back to ACTIVE for the positive control' ([string]$ch18b.reason)
    $s18ok = Invoke-HFSettle -Key $sx18.key -Authorization $sx18.fx.auth -Result $s1cand -Fp $fp18
    Assert-HF (([bool]$s18ok.ok) -and ([bool]$s18ok.settled) -and (-not [bool]$s18ok.reconciled)) '[S18] control: the same settle completes once the goal is ACTIVE again' ([string]$s18ok.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S18] no Executor call in the fencing scenario' ''

    # ---------- S19 (PRA-SETTLE F4): duplicata settled exige a MESMA sessao
    # filha e devolve a linhagem ARMAZENADA ----------
    $sx19 = New-HFSettleFixture -Suffix 'settle19' -KeyMaterial 'hf-settle-dupchild-1'
    $fp19 = ([string]$sx19.prepare.prepared_fingerprint)
    $s19 = Invoke-HFSettle -Key $sx19.key -Authorization $sx19.fx.auth -Result $s1cand -Fp $fp19 -ChildSession 'ses_hf_child_1'
    Assert-HF (([bool]$s19.ok) -and ([bool]$s19.settled)) '[S19] reference settle stores the child session lineage' ([string]$s19.reason)
    # (a) mesma chamada do host, sessao filha DIVERGENTE => recusada.
    $s19a = Invoke-HFSettle -Key $sx19.key -Authorization $sx19.fx.auth -Result $s1cand -Fp $fp19 -ChildSession 'ses_hf_child_OTHER'
    Assert-HF ((-not [bool]$s19a.ok) -and (-not [bool]$s19a.settled) -and (-not [bool]$s19a.duplicate) -and ([string]$s19a.reason -ceq 'settle-duplicate-child-mismatch')) '[S19a] a settled duplicate with a mismatched child id is denied (same-call/different-child refusal)' ([string]$s19a.reason)
    Assert-HF ((([string]$s19a.child_session_id -cne 'ses_hf_child_1') -and (-not [bool]$s19a.settled))) '[S19a] the denial never returns the stored child lineage' ('echoed=' + [string]$s19a.child_session_id)
    $rp19 = Get-HFReceiptPath -GoalId $sx19.fx.goal -Key $sx19.key
    $s19BytesBefore = [IO.File]::ReadAllBytes($rp19)
    $s19RevBefore = [long](Get-OrchestrationTask -TaskId $sx19.fx.task -TasksDir $tasksDir).revision
    $s19a2 = Invoke-HFSettle -Key $sx19.key -Authorization $sx19.fx.auth -Result $s1cand -Fp $fp19 -ChildSession 'ses_hf_child_OTHER'
    Assert-HF ((-not [bool]$s19a2.ok) -and ([string]$s19a2.reason -ceq 'settle-duplicate-child-mismatch')) '[S19a] the child-B denial is stable across calls' ([string]$s19a2.reason)
    $s19BytesAfter = [IO.File]::ReadAllBytes($rp19)
    $s19same = ($s19BytesAfter.Length -eq $s19BytesBefore.Length)
    if ($s19same) { for ($bi = 0; $bi -lt $s19BytesAfter.Length; $bi++) { if ([int]$s19BytesAfter[$bi] -ne [int]$s19BytesBefore[$bi]) { $s19same = $false; break } } }
    Assert-HF $s19same '[S19a] the denied duplicate left the settled receipt byte-identical (stored child A kept)' 'content changed'
    $s19rawAfter = Get-HFReceiptRaw -GoalId $sx19.fx.goal -Key $sx19.key
    Assert-HF (([string]$s19rawAfter.settle_child_session_id -ceq 'ses_hf_child_1')) '[S19a] the durable receipt still stores child A' ('stored=' + [string]$s19rawAfter.settle_child_session_id)
    $s19RevAfter = [long](Get-OrchestrationTask -TaskId $sx19.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($s19RevAfter -eq $s19RevBefore) '[S19a] the denied duplicate never rewrites the kernel' ('rev=' + [string]$s19RevAfter)
    # (b) mesma sessao filha: idempotente e devolve a linhagem ARMAZENADA.
    $s19b = Invoke-HFSettle -Key $sx19.key -Authorization $sx19.fx.auth -Result $s1cand -Fp $fp19 -ChildSession 'ses_hf_child_1'
    Assert-HF (([bool]$s19b.ok) -and ([bool]$s19b.duplicate) -and ([bool]$s19b.settled) -and ([string]$s19b.reason -ceq 'settle-duplicate')) '[S19b] an identical child duplicate is idempotent' ([string]$s19b.reason)
    Assert-HF (([string]$s19b.child_session_id -ceq 'ses_hf_child_1')) '[S19b] the duplicate returns the STORED child identity, not the presented one' ([string]$s19b.child_session_id)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S19] no Executor call in the settled-duplicate child scenario' ''

    # ---------- S20 (PRA-SETTLE item 4): kernel gravado mas o marcador de
    # evidencia duravel perdido => a retentativa PERMANECE ambiguous/claimed,
    # sem fabricar evidencia e sem segunda escrita no kernel. A reconciliacao,
    # se houver, e limitacao manual do operador - nunca automatica. ----------
    $sx20 = New-HFSettleFixture -Suffix 'settle20' -KeyMaterial 'hf-settle-lostproof-1'
    $fp20 = ([string]$sx20.prepare.prepared_fingerprint)
    $s20full = Invoke-HFSettle -Key $sx20.key -Authorization $sx20.fx.auth -Result $s1cand -Fp $fp20
    Assert-HF (([bool]$s20full.ok) -and ([bool]$s20full.settled)) '[S20] reference settle completes (kernel written)' ([string]$s20full.reason)
    $rev20 = [long](Get-OrchestrationTask -TaskId $sx20.fx.task -TasksDir $tasksDir).revision
    $rp20 = Get-HFReceiptPath -GoalId $sx20.fx.goal -Key $sx20.key
    $s20obj = ConvertFrom-Json ([IO.File]::ReadAllText($rp20, [Text.Encoding]::UTF8))
    # estado de crash: recibo de volta a 'claimed' E o marcador duravel de
    # evidencia (settle_evidence_id) perdido - "kernel gravado, escrita final
    # falhou e a prova causal nao sobreviveu".
    Add-Member -InputObject $s20obj -Name 'phase' -Value 'claimed' -MemberType NoteProperty -Force
    Add-Member -InputObject $s20obj -Name 'handoff_state' -Value 'DISPATCH_UNCERTAIN' -MemberType NoteProperty -Force
    if ($null -ne $s20obj.PSObject.Properties['settle_evidence_id']) { $s20obj.PSObject.Properties.Remove('settle_evidence_id') }
    [IO.File]::WriteAllText($rp20, (ConvertTo-Json -InputObject $s20obj -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $rp20BytesBefore = [IO.File]::ReadAllBytes($rp20)
    $evCount20Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $s20 = Invoke-HFSettle -Key $sx20.key -Authorization $sx20.fx.auth -Result $s1cand -Fp $fp20
    Assert-HF ((-not [bool]$s20.ok) -and (-not [bool]$s20.settled) -and (-not [bool]$s20.reconciled) -and ([string]$s20.reason -ceq 'settle-kernel-commit-ambiguous') -and ([string]::IsNullOrWhiteSpace([string]$s20.evidence_id))) '[S20] with the durable evidence marker lost, the retry remains settle-kernel-commit-ambiguous' ([string]$s20.reason)
    $s20raw = Get-HFReceiptRaw -GoalId $sx20.fx.goal -Key $sx20.key
    Assert-HF (($null -ne $s20raw) -and ([string]$s20raw.phase -ceq 'claimed')) '[S20] the receipt stays claimed - no settle/release on the ambiguous retry' ('phase=' + [string]$s20raw.phase)
    # o recibo NAO e reescrito (nem trabalhista/fabricado) pela retentativa ambigua.
    $rp20BytesAfter = [IO.File]::ReadAllBytes($rp20)
    $rp20Same = ($rp20BytesAfter.Length -eq $rp20BytesBefore.Length)
    if ($rp20Same) { for ($bi20 = 0; $bi20 -lt $rp20BytesAfter.Length; $bi20++) { if ([int]$rp20BytesAfter[$bi20] -ne [int]$rp20BytesBefore[$bi20]) { $rp20Same = $false; break } } }
    Assert-HF $rp20Same '[S20] the ambiguous retry left the claimed receipt byte-identical (no fabricated worker result, no settle write)' 'content changed'
    $rev20After = [long](Get-OrchestrationTask -TaskId $sx20.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev20After -eq $rev20) '[S20] no second kernel write happens on the ambiguous retry' ('before=' + [string]$rev20 + ' after=' + [string]$rev20After)
    $evCount20After = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount20After -eq $evCount20Before) '[S20] the ambiguous retry creates no evidence' ('before=' + [string]$evCount20Before + ' after=' + [string]$evCount20After)

    # ---------- S21 (PRA-SETTLE-FIX3b): o escritor MOVE o recibo 'settled'
    # e devolve $false; a releitura sob lock prova o commit EXATO ----------
    # Variante honesta da escrita parcial: `Write-NDReceipt` pode ter
    # persistido o destino e falhar so na prova pos-escrita. Ainda sob os
    # dois locks, o registro e RELIDO e comparado campo a campo com o recibo
    # 'settled' EXATO: prova exata => liquidacao de fato persistida e a
    # resposta e settled, sem novo kernel e sem nova evidencia.
    $sx21 = New-HFSettleFixture -Suffix 'settle21' -KeyMaterial 'hf-settle-proof-1'
    $fp21 = ([string]$sx21.prepare.prepared_fingerprint)
    $rp21 = Get-HFReceiptPath -GoalId $sx21.fx.goal -Key $sx21.key
    $evCount21Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Set-HFReceiptWriteMode -Mode 'persist-then-false-settled'
    try {
        $s21 = Invoke-HFSettle -Key $sx21.key -Authorization $sx21.fx.auth -Result $s1cand -Fp $fp21
    }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    Assert-HF (([bool]$s21.ok) -and ([bool]$s21.settled) -and (-not [bool]$s21.duplicate) -and (-not [bool]$s21.reconciled) -and ([string]$s21.phase -ceq 'settled') -and ([string]$s21.handoff_state -ceq 'SETTLED')) '[S21a] writer persisted the settled receipt and returned false: the reread proves the commit and the response is settled success' ('reason=' + [string]$s21.reason)
    Assert-HF (([bool]$s21.kernel_ok) -and ([string]$s21.worker_status -ceq 'candidate_pass') -and ([string]$s21.evidence_id -cmatch '^[a-f0-9]{32}$') -and ([bool]$s21.evidence_created) -and ([string]$s21.child_session_id -ceq 'ses_hf_child_1')) '[S21a] the settled envelope carries kernel/evidence/child lineage like any successful settle' ('status=' + [string]$s21.worker_status + ' ev=' + [string]$s21.evidence_id)
    $s21raw = Get-HFReceiptRaw -GoalId $sx21.fx.goal -Key $sx21.key
    Assert-HF (($null -ne $s21raw) -and ([string]$s21raw.phase -ceq 'settled') -and ([string]$s21raw.handoff_state -ceq 'SETTLED') -and ([string]$s21raw.worker_result.status -ceq 'candidate_pass') -and ([string]$s21raw.settle_child_session_id -ceq 'ses_hf_child_1') -and ([string]$s21raw.evidence_id -ceq [string]$s21.evidence_id)) '[S21a] the durable receipt is the exact settled record (status, child session, evidence id)' ''
    $rev21 = [long](Get-OrchestrationTask -TaskId $sx21.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev21 -eq 2) '[S21a] the kernel was written exactly ONCE (no duplicated kernel write)' ('rev=' + [string]$rev21)
    $evCount21 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount21 -eq ($evCount21Before + 1)) '[S21a] exactly ONE evidence row (no duplicated evidence write)' ('before=' + [string]$evCount21Before + ' after=' + [string]$evCount21)
    # a liquidacao persistida mantem TODA a semantica de duplicata settled.
    $s21dup = Invoke-HFSettle -Key $sx21.key -Authorization $sx21.fx.auth -Result $s1cand -Fp $fp21
    Assert-HF (([bool]$s21dup.ok) -and ([bool]$s21dup.duplicate) -and ([bool]$s21dup.settled) -and ([string]$s21dup.reason -ceq 'settle-duplicate') -and ([string]$s21dup.child_session_id -ceq 'ses_hf_child_1')) '[S21b] the proven settle still answers an identical duplicate idempotently' ([string]$s21dup.reason)
    $s21dupc = Invoke-HFSettle -Key $sx21.key -Authorization $sx21.fx.auth -Result $s1cand -Fp $fp21 -ChildSession 'ses_hf_child_OTHER'
    Assert-HF ((-not [bool]$s21dupc.ok) -and (-not [bool]$s21dupc.duplicate) -and ([string]$s21dupc.reason -ceq 'settle-duplicate-child-mismatch')) '[S21c] child-session equality still holds for the settled duplicate' ([string]$s21dupc.reason)
    $s21raw2 = Get-HFReceiptRaw -GoalId $sx21.fx.goal -Key $sx21.key
    Assert-HF (($null -ne $s21raw2) -and ([string]$s21raw2.settle_child_session_id -ceq 'ses_hf_child_1') -and (@(@('candidate_pass', 'failed', 'blocked') -ccontains [string]$s21raw2.worker_result.status))) '[S21c] the stored child and the candidate status are preserved (never verified/done)' ('child=' + [string]$s21raw2.settle_child_session_id + ' status=' + [string]$s21raw2.worker_result.status)
    $s21task = Get-OrchestrationTask -TaskId $sx21.fx.task -TasksDir $tasksDir
    Assert-HF (($null -ne $s21task) -and ([int]$s21task.revision -eq 2) -and ([string]$s21task.state -cne 'DONE') -and ([string]$s21task.state -cne 'EXHAUSTED')) '[S21c] the duplicate refusals never rewrite the kernel nor advance the task to a terminal state' ('rev=' + [string]$s21task.revision + ' state=' + [string]$s21task.state)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S21] no Executor call in the write-proved settle scenario' ''

    # ---------- S22 (PRA-SETTLE-FIX3c): marcador duravel de tentativa no
    # recibo + escritor ALHEIO no kernel com o MESMO status/refs ----------
    # O marcador settle_attempt_* no recibo NAO prova que o kernel foi
    # escrito por esta claim. Um escritor alheio posta exatamente o mesmo
    # status/refs com a revisao avancada: coincidencia nao e autoria, e a
    # reconciliacao automatica NAO volta. O bloqueio seguro permanece.
    $sx22 = New-HFSettleFixture -Suffix 'settle22' -KeyMaterial 'hf-settle-foreign-1'
    $fp22 = ([string]$sx22.prepare.prepared_fingerprint)
    $rp22 = Get-HFReceiptPath -GoalId $sx22.fx.goal -Key $sx22.key
    $evCount22Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Set-HFReceiptWriteMode -Mode 'fail-evidence-marker'
    try {
        $s22a = Invoke-HFSettle -Key $sx22.key -Authorization $sx22.fx.auth -Result $s1cand -Fp $fp22
    }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    Assert-HF ((-not [bool]$s22a.ok) -and (-not [bool]$s22a.settled) -and ([string]$s22a.reason -ceq 'settle-receipt-write-failed') -and (-not [string]::IsNullOrWhiteSpace([string]$s22a.evidence_id))) '[S22a] the evidence-marker write fails with the attempt marker already durable' ('reason=' + [string]$s22a.reason)
    $s22rawA = Get-HFReceiptRaw -GoalId $sx22.fx.goal -Key $sx22.key
    Assert-HF (($null -ne $s22rawA) -and ([string]$s22rawA.phase -ceq 'claimed') -and (-not [string]::IsNullOrWhiteSpace([string]$s22rawA.settle_attempt_status)) -and ($null -eq $s22rawA.PSObject.Properties['settle_evidence_id'])) '[S22a] the durable ATTEMPT marker survives without the evidence marker' ''
    $rev22Before = [long](Get-OrchestrationTask -TaskId $sx22.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev22Before -eq 1) '[S22a] the failed attempt reached NO kernel write' ('rev=' + [string]$rev22Before)
    $evCount22Mid = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount22Mid -eq ($evCount22Before + 1)) '[S22a] the canonical evidence row of the failed attempt exists exactly once' ('before=' + [string]$evCount22Before + ' after=' + [string]$evCount22Mid)
    # escritor ALHEIO: mesmo candidato, revisao avancada alem da esperada.
    $w22 = Set-OrchestrationTaskWorkerResult -TaskId $sx22.fx.task -Status 'candidate_pass' -ClaimedEvidence @('criterion:0', 'criterion:1') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $script:tempRoot
    Assert-HF ([bool]$w22.ok) '[S22] an unrelated writer posted the IDENTICAL kernel result beyond the expected revision' ([string]$w22.error)
    $rp22Before = [IO.File]::ReadAllBytes($rp22)
    $s22b = Invoke-HFSettle -Key $sx22.key -Authorization $sx22.fx.auth -Result $s1cand -Fp $fp22
    Assert-HF ((-not [bool]$s22b.ok) -and (-not [bool]$s22b.settled) -and (-not [bool]$s22b.reconciled) -and ([string]$s22b.reason -ceq 'settle-kernel-commit-ambiguous')) '[S22b] identical status/refs from an UNRELATED writer remain ambiguous (coincidence is not authorship, no auto-reconciliation)' ([string]$s22b.reason)
    $rev22After = [long](Get-OrchestrationTask -TaskId $sx22.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev22After -eq 2) '[S22b] the ambiguous hold performs no second kernel write' ('rev=' + [string]$rev22After)
    $evCount22After = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evCount22After -eq $evCount22Mid) '[S22b] the ambiguous hold creates no evidence to prove a previous write' ('before=' + [string]$evCount22Mid + ' after=' + [string]$evCount22After)
    $s22rawB = Get-HFReceiptRaw -GoalId $sx22.fx.goal -Key $sx22.key
    Assert-HF (($null -ne $s22rawB) -and ([string]$s22rawB.phase -ceq 'claimed') -and ($null -eq $s22rawB.PSObject.Properties['worker_result']) -and (-not [string]::IsNullOrWhiteSpace([string]$s22rawB.settle_attempt_status))) '[S22b] the receipt stays claimed with the durable attempt marker (no fabricated settle)' ('phase=' + [string]$s22rawB.phase)
    $rp22After = [IO.File]::ReadAllBytes($rp22)
    $rp22Same = ($rp22After.Length -eq $rp22Before.Length)
    if ($rp22Same) { for ($bi = 0; $bi -lt $rp22After.Length; $bi++) { if ([int]$rp22After[$bi] -ne [int]$rp22Before[$bi]) { $rp22Same = $false; break } } }
    Assert-HF $rp22Same '[S22b] the ambiguous hold left the claimed receipt byte-identical' 'content changed'
    $k22second = Get-NativeDispatchHash32 'hf-settle-foreign-second'
    $i22second = New-HFIntent -Task $sx22.fx.task -Key $k22second -Gen $sx22.fx.gen -Rev $rev22After
    $p22second = Invoke-OrchestrationNativeDispatchPrepare -Intent $i22second -Authorization $sx22.fx.auth -SessionId 'ses_hf_s22b' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$p22second.ok) '[S22c] a second effect on the held task can still be prepared' ([string]$p22second.reason)
    $c22second = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $k22second -Authorization $sx22.fx.auth -SessionId 'ses_hf_s22b' -MessageId 'msg_hf_s22' -CallId 'call_hf_s22' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p22second.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$c22second.ok) -and ([string]$c22second.reason -ceq 'claim-task-already-claimed')) '[S22c] the reservation blocks a second effect while the state is uncertain' ([string]$c22second.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S22] no Executor call in the unrelated-writer scenario' ''

    # ---------- S23 (PRA-SETTLE-FIX3d): fencing pos-lock continua
    # IMEDIATAMENTE antes da escrita no kernel no caminho parcial ----------
    # O mock escreve o marcador de evidencia e tira o goal de ACTIVE no meio
    # da liquidacao: a unica barreira possivel e a revalidacao feita entre
    # essa escrita e o kernel. goal nao-ACTIVE recusa, mantem 'claimed' com
    # a reserva e nao escreve no kernel.
    $sx23 = New-HFSettleFixture -Suffix 'settle23' -KeyMaterial 'hf-settle-fencek-1'
    $fp23 = ([string]$sx23.prepare.prepared_fingerprint)
    Set-HFReceiptWriteMode -Mode 'pause-goal-on-evidence'
    try {
        $s23a = Invoke-HFSettle -Key $sx23.key -Authorization $sx23.fx.auth -Result $s1cand -Fp $fp23
    }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    Assert-HF ((-not [bool]$s23a.ok) -and (-not [bool]$s23a.settled) -and ([string]$s23a.reason -like 'post-lock-goal-not-active*')) '[S23a] the ownership ACTIVE/lease check still runs immediately before the kernel write (partial path)' ('reason=' + [string]$s23a.reason)
    Assert-HF (([string]$s23a.kernel_reason -like 'post-lock-goal-not-active*')) '[S23a] the fenced kernel write is reported on the envelope' ('kernel_reason=' + [string]$s23a.kernel_reason)
    $rev23 = [long](Get-OrchestrationTask -TaskId $sx23.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev23 -eq 1) '[S23a] no kernel write happened after the fenced window' ('rev=' + [string]$rev23)
    $s23raw = Get-HFReceiptRaw -GoalId $sx23.fx.goal -Key $sx23.key
    Assert-HF (($null -ne $s23raw) -and ([string]$s23raw.phase -ceq 'claimed') -and (-not [string]::IsNullOrWhiteSpace([string]$s23raw.settle_attempt_status)) -and (-not [string]::IsNullOrWhiteSpace([string]$s23raw.settle_evidence_id))) '[S23a] the receipt stays claimed with the durable attempt/evidence markers (no settle)' ('phase=' + [string]$s23raw.phase)
    # controle: goal de volta a ACTIVE, a MESMA liquidacao conclui.
    $ch23 = Set-HFGoalStateLive -GoalId $sx23.fx.goal -ToState 'ACTIVE' -Gen $sx23.fx.gen
    Assert-HF ([bool]$ch23.ok) '[S23] the goal is back to ACTIVE for the positive control' ([string]$ch23.reason)
    $s23b = Invoke-HFSettle -Key $sx23.key -Authorization $sx23.fx.auth -Result $s1cand -Fp $fp23
    Assert-HF (([bool]$s23b.ok) -and ([bool]$s23b.settled) -and (-not [bool]$s23b.reconciled)) '[S23b] control: the same settle completes once the goal is ACTIVE again' ([string]$s23b.reason)
    $rev23b = [long](Get-OrchestrationTask -TaskId $sx23.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($rev23b -eq 2) '[S23b] the kernel is written exactly once, after the fence is gone' ('rev=' + [string]$rev23b)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[S23] no Executor call in the partial-path fencing scenario' ''

    # ==================================================================
    # PRA-SETTLE-FIX4: um recibo 'settled' com kernel_ok=false DEPOIS de
    # um efeito real NAO pode liberar a reserva de task (era o bypass de
    # Test-NDTaskEffectExclusive - todo 'settled' era tratado como
    # resolvido). Registro agora discrimina a liquidacao conhecida
    # (kernel_ok exatamente true) da recusa PRE-efeito fresca; todo o
    # resto que liquida 'settled' com kernel_ok=false continua reservando.
    # ==================================================================
    # Mock deterministico do escritor de worker-result do kernel (somente
    # teste): em modo 'reject' devolve ok=$false SEM tocar na task (simula
    # o TaskKernel recusando apos o efeito); em 'pass' delega ao original
    # via @PSBoundParameters. A funcao original e capturada e restaurada no
    # fim deste bloco e no finally da suite. Nenhuma outra suite muda.
    $script:hfKernelReject = $false
    $script:hfKernelMockInstalled = $false
    $script:hfOrigSetWorkerResult = $null
    try { $script:hfOrigSetWorkerResult = (Get-Item -Path ('function:Set-OrchestrationTaskWorkerResult')).ScriptBlock } catch { $script:hfOrigSetWorkerResult = $null }
    function Set-OrchestrationTaskWorkerResult {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$TaskId,
            [Parameter(Mandatory = $true)][string]$Status,
            [string[]]$ClaimedEvidence = @(),
            [Parameter(Mandatory = $true)][string]$ProducedBy,
            [Parameter(Mandatory = $true)][int]$ExpectedRevision,
            [string]$Hypothesis = '',
            [switch]$NewEvidence,
            [switch]$DebuggerInvoked,
            [string]$StrategyId = '',
            [string]$StrategyApproach = '',
            [string]$StrategyTool = '',
            [string[]]$StrategyParams = @(),
            [string]$StrategyFingerprint = '',
            [string]$FailureClass = '',
            [string]$FailureDetail = '',
            [string]$RecoverySource = '',
            [string[]]$NewEvidenceRefs = @(),
            [string]$ProposedBudgetJson = '',
            [string]$TasksDir = '',
            [string]$FlagsPath = '',
            [string]$RepoRoot = '',
            [string]$TelemetryRoot = '',
            $SettlementContext = $null
        )
        try {
            if ($script:hfKernelReject) { return [pscustomobject]@{ ok = $false; error = 'KERNEL_REFUSED_AFTER_EFFECT' } }
            return (& $script:hfOrigSetWorkerResult @PSBoundParameters)
        }
        catch { return [pscustomobject]@{ ok = $false; error = 'KERNEL_MOCK_ERROR' } }
    }
    $script:hfKernelMockInstalled = $true
    function Set-HFKernelReject { param([bool]$Reject = $false) $script:hfKernelReject = [bool]$Reject }
    function Restore-HFKernelWriter {
        if ($script:hfKernelMockInstalled -and ($null -ne $script:hfOrigSetWorkerResult)) {
            try { Set-Item -Path ('function:Set-OrchestrationTaskWorkerResult') -Value $script:hfOrigSetWorkerResult } catch { }
        }
        $script:hfKernelMockInstalled = $false
        $script:hfKernelReject = $false
    }

    # ---------- F4-1 (TEST 1): efeito real + TaskKernel recusa => settled
    # kernel_ok=false/executor_calls=1 continua RESERVANDO a task; uma 2a
    # chave (CLAIM e Invoke legado) recusa com 0 novas chamadas ----------
    # raiz propria do bloco F4-1..F4-5: nenhum cenario depende dos
    # namespaces anteriores e os registros daqui (legado, sem marcadores
    # de handoff) seguem a porta legada na varredura.
    $receiptDir = New-HFReceiptRoot -Name 'fix4-legacy'
    $fxKf = New-HFIsolatedFixture -Suffix 'fix4a'
    $kF4a = Get-NativeDispatchHash32 'hf-fix4-effect-kconf'
    $kF4a2 = Get-NativeDispatchHash32 'hf-fix4-effect-second'
    $kF4a3 = Get-NativeDispatchHash32 'hf-fix4-effect-third'
    $f4aState = @{ calls = 0 }
    $f4aSpy = { param($i) $f4aState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    Set-HFKernelReject -Reject $true
    try { $lF4a = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxKf.task -Key $kF4a -Gen $fxKf.gen).intent -Executor $f4aSpy -Authorization $fxKf.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath }
    finally { Set-HFKernelReject -Reject $false }
    Assert-HF ((-not [bool]$lF4a.ok) -and ([string]$lF4a.reason -like 'kernel:*') -and ([int]$lF4a.executor_calls -eq 1) -and ([int]$f4aState.calls -eq 1)) '[F4-1] a real effect then TaskKernel refusal still accounts the effect (kernel:*, calls=1)' (([string]$lF4a.reason) + ' calls=' + [string]$lF4a.executor_calls)
    $f4aRaw = $null
    try { $f4aRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxKf.goal -Key $kF4a), [Text.Encoding]::UTF8)) } catch { $f4aRaw = $null }
    Assert-HF (($null -ne $f4aRaw) -and ([string]$f4aRaw.phase -ceq 'settled') -and ($null -ne $f4aRaw.PSObject.Properties['kernel_ok']) -and (-not [bool]$f4aRaw.kernel_ok) -and ($null -ne $f4aRaw.PSObject.Properties['executor_calls']) -and ([int]$f4aRaw.executor_calls -eq 1)) '[F4-1] the settled receipt records kernel_ok=false and executor_calls=1 (post-effect failure)' ('phase=' + [string]$f4aRaw.phase)
    $pF4a2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxKf.task -Key $kF4a2 -Gen $fxKf.gen) -Authorization $fxKf.auth -SessionId 'ses_hf_f4a2' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF4a2.ok) '[F4-1] a second key prepares over the post-effect settled receipt (prepare is not an effect)' ([string]$pF4a2.reason)
    $cF4a2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4a2 -Authorization $fxKf.auth -SessionId 'ses_hf_f4a2' -MessageId 'msg_hf_f4a2' -CallId 'call_hf_f4a2' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4a2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cF4a2.ok) -and (-not [bool]$cF4a2.claimed) -and ([string]$cF4a2.reason -ceq 'claim-task-already-claimed') -and ([int]$cF4a2.executor_calls -eq 0)) '[F4-1] a second key CLAIM is refused: the post-effect settled failure does NOT release the reservation' ([string]$cF4a2.reason)
    $f4a3State = @{ calls = 0 }
    $f4a3Spy = { param($i) $f4a3State.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lF4a3 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxKf.task -Key $kF4a3 -Gen $fxKf.gen).intent -Executor $f4a3Spy -Authorization $fxKf.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$lF4a3.ok) -and ([string]$lF4a3.reason -ceq 'claim-task-already-claimed') -and ([int]$lF4a3.executor_calls -eq 0) -and ([int]$f4a3State.calls -eq 0)) '[F4-1] a second key legacy Invoke is refused with 0 new executor calls' ([string]$lF4a3.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxKf.goal -Key $kF4a3) -PathType Leaf)) '[F4-1] the refused second legacy key persisted nothing' ''

    # ---------- F4-2 (TEST 2): recusa PRE-efeito pos-lock REAL (despacho
    # NOVO) liquida settled kernel_ok=false/executor_calls=0/reconciled=
    # false/reason allowlisted e NAO bloqueia uma nova chave ----------
    $fxPf = New-HFIsolatedFixture -Suffix 'fix4b'
    $kF4b = Get-NativeDispatchHash32 'hf-fix4-prefuse'
    $kF4b2 = Get-NativeDispatchHash32 'hf-fix4-prefuse-second'
    $f4bState = @{ calls = 0 }
    $f4bSpy = { param($i) $f4bState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    Set-HFReceiptWriteMode -Mode 'pause-goal-on-pending'
    try { $lF4b = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxPf.task -Key $kF4b -Gen $fxPf.gen).intent -Executor $f4bSpy -Authorization $fxPf.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    Assert-HF ((-not [bool]$lF4b.ok) -and ([string]$lF4b.reason -like 'post-lock-*') -and ([int]$lF4b.executor_calls -eq 0) -and ([int]$f4bState.calls -eq 0)) '[F4-2] a fresh pre-effect post-lock refusal runs the Executor 0 times' (([string]$lF4b.reason) + ' calls=' + [string]$lF4b.executor_calls)
    $f4bRaw = $null
    try { $f4bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxPf.goal -Key $kF4b), [Text.Encoding]::UTF8)) } catch { $f4bRaw = $null }
    Assert-HF (($null -ne $f4bRaw) -and ([string]$f4bRaw.phase -ceq 'settled') -and (-not [bool]$f4bRaw.kernel_ok) -and ([int]$f4bRaw.executor_calls -eq 0) -and (-not [bool]$f4bRaw.reconciled) -and ([string]$f4bRaw.reason -like 'post-lock-*')) '[F4-2] the real pre-effect refusal persisted settled/kernel_ok=false/executor_calls=0/reconciled=false' ('phase=' + [string]$f4bRaw.phase + ' reason=' + [string]$f4bRaw.reason)
    $backF4b = Set-HFGoalStateLive -GoalId $fxPf.goal -ToState 'ACTIVE' -Gen $fxPf.gen
    Assert-HF ([bool]$backF4b.ok) '[F4-2] the goal is back to ACTIVE for the non-blocking control' ([string]$backF4b.reason)
    $pF4b2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxPf.task -Key $kF4b2 -Gen $fxPf.gen) -Authorization $fxPf.auth -SessionId 'ses_hf_f4b2' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF4b2.ok) '[F4-2] a new key prepares over the pre-effect refusal' ([string]$pF4b2.reason)
    $cF4b2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4b2 -Authorization $fxPf.auth -SessionId 'ses_hf_f4b2' -MessageId 'msg_hf_f4b2' -CallId 'call_hf_f4b2' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4b2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF4b2.ok) -and ([bool]$cF4b2.claimed)) '[F4-2] a no-effect settled refusal does NOT block the task (settled-does-not-block assertion preserved)' ([string]$cF4b2.reason)

    # ---------- F4-3 (TEST 3): settled kernel_ok=false/executor_calls=0 com
    # reconciled=true (replay de um pending anterior) NAO libera a reserva ----------
    $fxRc = New-HFIsolatedFixture -Suffix 'fix4c'
    $kF4c = Get-NativeDispatchHash32 'hf-fix4-replay-settled'
    $kF4c2 = Get-NativeDispatchHash32 'hf-fix4-replay-second'
    $f4cFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxRc.task -Key $kF4c -Gen $fxRc.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $fxRc.goal -Key $kF4c), (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; idempotency_key = $kF4c; phase = 'settled'; ok = $false; reason = 'post-lock-fencing-changed'; task_id = $fxRc.task; agent = 'coder'; owner = 'planner-1'; goal_id = $fxRc.goal; ownership_generation = $fxRc.gen; task_expected_revision = 1; intent_fingerprint = $f4cFp; reconciled = $true; kernel_ok = $false; executor_calls = 0; created_at = ([DateTime]::UtcNow.ToString('o')) }) -Compress), [Text.UTF8Encoding]::new($false))
    $pF4c2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxRc.task -Key $kF4c2 -Gen $fxRc.gen) -Authorization $fxRc.auth -SessionId 'ses_hf_f4c2' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF4c2.ok) '[F4-3] a second key prepares over the reconciled replay settled failure' ([string]$pF4c2.reason)
    $cF4c2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4c2 -Authorization $fxRc.auth -SessionId 'ses_hf_f4c2' -MessageId 'msg_hf_f4c2' -CallId 'call_hf_f4c2' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4c2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ((-not [bool]$cF4c2.ok) -and (-not [bool]$cF4c2.claimed) -and ([string]$cF4c2.reason -ceq 'claim-task-already-claimed') -and ([int]$cF4c2.executor_calls -eq 0)) '[F4-3] a settled failure with reconciled=true (replay of an earlier pending) STILL blocks, even with executor_calls=0' ([string]$cF4c2.reason)

    # ---------- F4-4 (TEST 4): settled malformado (kernel_ok /
    # executor_calls / reconciled / reason) falha fechado ----------
    $fxMb = New-HFIsolatedFixture -Suffix 'fix4d'
    $nsF4mb = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $fxMb.goal
    $kF4mb = Get-NativeDispatchHash32 'hf-fix4-malformed-op'
    $f4mbFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxMb.task -Key $kF4mb -Gen $fxMb.gen).intent
    $pF4mb = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxMb.task -Key $kF4mb -Gen $fxMb.gen) -Authorization $fxMb.auth -SessionId 'ses_hf_f4mb' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF4mb.ok) '[F4-4] prepared for the malformed-settled fixture' ([string]$pF4mb.reason)
    # cada caso parte de uma recusa PRE-efeito fresca VALIDA e corrompe UM
    # campo (token ausente/tipo errado/razao desconhecida); todos bloqueiam.
    $f4BadCases = @(
        @{ tag = 'kernel_ok-missing';    from = '"kernel_ok":false,'; to = '';                                        expect = 'claim-task-scan-unreadable' }
        @{ tag = 'kernel_ok-array';      from = '"kernel_ok":false';      to = '"kernel_ok":[false]';                    expect = 'claim-task-scan-unreadable' }
        @{ tag = 'kernel_ok-string';     from = '"kernel_ok":false';      to = '"kernel_ok":"false"';                    expect = 'claim-task-scan-unreadable' }
        @{ tag = 'executor_calls-array'; from = '"executor_calls":0';     to = '"executor_calls":[0]';                   expect = 'claim-task-already-claimed' }
        @{ tag = 'reconciled-array';     from = '"reconciled":false';     to = '"reconciled":[false]';                   expect = 'claim-task-already-claimed' }
        @{ tag = 'reason-array';         from = '"reason":"post-lock-fencing-changed"'; to = '"reason":["post-lock-fencing-changed"]'; expect = 'claim-task-already-claimed' }
        @{ tag = 'reason-unknown';       from = '"reason":"post-lock-fencing-changed"'; to = '"reason":"kernel-refused"'; expect = 'claim-task-already-claimed' }
    )
    foreach ($bc in @($f4BadCases)) {
        $badKey = Get-NativeDispatchHash32 ('hf-fix4-malformed-' + [string]$bc.tag)
        $badPath = Join-Path $nsF4mb ($badKey + '.json')
        $goodBody = '{"schema_version":1,"idempotency_key":"' + $badKey + '","phase":"settled","ok":false,"task_id":"' + [string]$fxMb.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxMb.goal + '","ownership_generation":' + [string]$fxMb.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $f4mbFp + '","reconciled":false,"kernel_ok":false,"executor_calls":0,"reason":"post-lock-fencing-changed"}'
        $badBody = $goodBody.Replace([string]$bc.from, [string]$bc.to)
        [IO.File]::WriteAllText($badPath, $badBody, [Text.UTF8Encoding]::new($false))
        $cF4mb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4mb -Authorization $fxMb.auth -SessionId 'ses_hf_f4mb' -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4mb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ((-not [bool]$cF4mb.ok) -and (-not [bool]$cF4mb.claimed) -and ([string]$cF4mb.reason -ceq ([string]$bc.expect)) -and ([int]$cF4mb.executor_calls -eq 0)) ('[F4-4] a settled receipt with ' + [string]$bc.tag + ' fails closed (' + [string]$bc.expect + ')') ([string]$cF4mb.reason)
        $kF4mbRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxMb.goal -Key $kF4mb), [Text.Encoding]::UTF8))
        Assert-HF ([string]$kF4mbRaw.phase -ceq 'prepared') ('[F4-4] ' + [string]$bc.tag + ' refusal never consumes the prepared receipt') ('phase=' + [string]$kF4mbRaw.phase)
        try { Remove-Item -LiteralPath $badPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    # controle (recusa PRE-efeito fresca VALIDA): NAO bloqueia.
    $f4okKey = Get-NativeDispatchHash32 'hf-fix4-malformed-validfresh'
    [IO.File]::WriteAllText((Join-Path $nsF4mb ($f4okKey + '.json')), ('{"schema_version":1,"idempotency_key":"' + $f4okKey + '","phase":"settled","ok":false,"task_id":"' + [string]$fxMb.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxMb.goal + '","ownership_generation":' + [string]$fxMb.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $f4mbFp + '","reconciled":false,"kernel_ok":false,"executor_calls":0,"reason":"post-lock-fencing-changed"}'), [Text.UTF8Encoding]::new($false))
    $cF4mbOk = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4mb -Authorization $fxMb.auth -SessionId 'ses_hf_f4mb' -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4mb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF4mbOk.ok) -and ([bool]$cF4mbOk.claimed)) '[F4-4] control: a VALID fresh pre-effect refusal still does not block (the malformed gate above is precise, not blanket)' ([string]$cF4mbOk.reason)
    try { Remove-Item -LiteralPath (Join-Path $nsF4mb ($f4okKey + '.json')) -Force -ErrorAction SilentlyContinue } catch { }

    # ---------- F4-5 (TEST 5): liquidacao BEM-SUCEDIDA grava kernel_ok=true
    # (exatamente) e LIBERA a reserva (handoff SETTLE e Invoke legado) ----------
    # (a) invalida o helper de discriminacao com um settled kernel_ok=true.
    $fxOk = New-HFIsolatedFixture -Suffix 'fix4e'
    $kF4e = Get-NativeDispatchHash32 'hf-fix4-legacy-ok'
    $kF4e2 = Get-NativeDispatchHash32 'hf-fix4-legacy-ok-second'
    $f4eSpy = { param($i) return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $lF4e = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxOk.task -Key $kF4e -Gen $fxOk.gen).intent -Executor $f4eSpy -Authorization $fxOk.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$lF4e.ok) -and (-not [bool]$lF4e.duplicate) -and ([string]$lF4e.reason -ceq '')) '[F4-5] a successful legacy Invoke settles as before' ([string]$lF4e.reason)
    $f4eRaw = $null
    try { $f4eRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxOk.goal -Key $kF4e), [Text.Encoding]::UTF8)) } catch { $f4eRaw = $null }
    Assert-HF (($null -ne $f4eRaw) -and ([string]$f4eRaw.phase -ceq 'settled') -and ($null -ne $f4eRaw.PSObject.Properties['kernel_ok']) -and ([bool]$f4eRaw.kernel_ok) -and ([int]$f4eRaw.executor_calls -eq 1)) '[F4-5] the successful settled receipt records kernel_ok=true and executor_calls=1 (known settlement)' ''
    $f4eLive = Get-OrchestrationTask -TaskId $fxOk.task -TasksDir $tasksDir
    $pF4e2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxOk.task -Key $kF4e2 -Gen $fxOk.gen -Rev ([long]$f4eLive.revision)) -Authorization $fxOk.auth -SessionId 'ses_hf_f4e2' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF4e2.ok) '[F4-5] a new key prepares after the successful settlement (revision advanced)' ([string]$pF4e2.reason)
    $cF4e2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF4e2 -Authorization $fxOk.auth -SessionId 'ses_hf_f4e2' -MessageId 'msg_hf_f4e2' -CallId 'call_hf_f4e2' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF4e2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF4e2.ok) -and ([bool]$cF4e2.claimed)) '[F4-5] a kernel_ok=true settled receipt RELEASES the reservation (new claim admitted)' ([string]$cF4e2.reason)

    # ---------- F4-6 (PRA-SETTLE-FIX4): escritor genuino grava o
    # 'settled' e o registro em disco fica com UM campo em forma de array
    # de um elemento ----------
    # NAO ha mutacao de fase a mao: o escritor REAL persiste o recibo
    # 'settled' EXATO e, em seguida, UM campo do arquivo e colocado em forma
    # de array (`kernel_ok:[true]` / `settle_child_session_id:["filho"]`) -
    # o token cru adulterado DEPOIS do Move, com o escritor devolvendo $false.
    # A prova de releitura sob lock (`Test-NDSettledReceiptPersisted`) tem de
    # RECUSAR: `Get-NDValue` desenrolaria o array de um elemento e a
    # comparacao antiga aceitaria `kernel_ok:[true]` como `kernel_ok:true` e
    # `["filho"]` como 'filho'. A resposta e EXPLICITAMENTE ambigua (nunca
    # sucesso), sem segunda escrita de kernel/evidencia e com a retentativa
    # caindo no gate de commit ambiguo.
    # PRA-SETTLE-FIX5: este grupo DEIXA o registro 'settled' adulterado em
    # disco (o cenario exige o byte-identical, nunca a restauracao). Com a
    # nova porta, um 'settled' de handoff que nao prova a liquidacao nao
    # pode mais ser ignorado como "outra task" - por isso a raiz e PROPRIA:
    # a adulteracao fica contida aqui e nao vaza para os grupos seguintes.
    $receiptDir = New-HFReceiptRoot -Name 'fix6-mutate'
    foreach ($mu in @(
        @{ tag = 'kernel_ok'; field = 'kernel_ok'; blocked = $true }
        @{ tag = 'child-session'; field = 'settle_child_session_id'; blocked = $false }
    )) {
        # PRA-SETTLE-FIX5: raiz NOVA por iteracao. O registro 'settled'
        # adulterado deste caso fica em disco (o cenario exige
        # byte-identical) e, com a porta FIX5, nao pode ser ignorado como
        # "outra task" - a raiz propria isola a adulteracao do caso
        # seguinte e deixa a varredura de cada claim pequena.
        $receiptDir = New-HFReceiptRoot -Name ('fix6-' + [string]$mu.tag)
        $sxMu = New-HFSettleFixture -Suffix ('settle-mut-' + [string]$mu.tag) -KeyMaterial ('hf-settle-mutate-' + [string]$mu.tag)
        $fpMu = ([string]$sxMu.prepare.prepared_fingerprint)
        $rpMu = Get-HFReceiptPath -GoalId $sxMu.fx.goal -Key $sxMu.key
        $revMuBefore = [long](Get-OrchestrationTask -TaskId $sxMu.fx.task -TasksDir $tasksDir).revision
        $evMuBefore = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Set-HFReceiptMutateField -Field ([string]$mu.field)
        Set-HFReceiptWriteMode -Mode 'persist-mutate-settled'
        try { $sMu = Invoke-HFSettle -Key $sxMu.key -Authorization $sxMu.fx.auth -Result $s1cand -Fp $fpMu }
        finally { Set-HFReceiptWriteMode -Mode 'pass'; Set-HFReceiptMutateField -Field '' }
        # (a) recusa EXPLICITAMENTE ambigna: nem sucesso, nem 'claimed'.
        Assert-HF (((-not [bool]$sMu.ok) -and (-not [bool]$sMu.settled) -and (-not [bool]$sMu.duplicate) -and (-not [bool]$sMu.reconciled) -and ([string]$sMu.reason -like 'settle-receipt-proof-*') -and ([string]::IsNullOrWhiteSpace([string]$sMu.phase)) -and ([string]::IsNullOrWhiteSpace([string]$sMu.handoff_state)))) ('[F4-6/' + [string]$mu.tag + '] the tampered settled receipt is refused as an EXPLICIT ambiguity (never success)') ('reason=' + [string]$sMu.reason)
        # (b) o registro EM DISCO ficou 'settled' com o campo em ARRAY cru:
        #     e a prova mesmo assim recusou (a fase nao basta).
        $muRaw = Get-HFReceiptRaw -GoalId $sxMu.fx.goal -Key $sxMu.key
        Assert-HF (($null -ne $muRaw) -and ([string]$muRaw.phase -ceq 'settled') -and ([string]$muRaw.handoff_state -ceq 'SETTLED')) ('[F4-6/' + [string]$mu.tag + '] the writer really persisted the settled phase (no manual phase mutation)') ('phase=' + [string]$muRaw.phase)
        $muTok = Get-NDValueNode -Object $muRaw -Name ([string]$mu.field)
        Assert-HF (($null -ne $muTok) -and ([string]$muTok.kind -ceq 'list')) ('[F4-6/' + [string]$mu.tag + '] the persisted token really is a singleton ARRAY of one element') ('kind=' + [string]$muTok.kind)
        # (c) uma UNICA escrita de kernel e UMA evidencia: nada de segunda
        #     escrita pelo caminho ambiguo.
        $revMu = [long](Get-OrchestrationTask -TaskId $sxMu.fx.task -TasksDir $tasksDir).revision
        Assert-HF (($revMu -eq ($revMuBefore + 1)) -and ($revMuBefore -eq 1)) '[F4-6] the kernel was written exactly ONCE (before the receipt write)' ('rev=' + [string]$revMuBefore + '->' + [string]$revMu)
        $evMu = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Assert-HF ($evMu -eq ($evMuBefore + 1)) '[F4-6] exactly ONE evidence row exists for this claim' ('before=' + [string]$evMuBefore + ' after=' + [string]$evMu)
        # (d) retentativa: recusa fail-closed, sem nova escrita. O registro
        #     adulterado ficou 'settled' EM DISCO (o escritor REAL gravou),
        #     portanto a retentativa entra no gate de duplicata e recusa pela
        #     FORMA CRUA; se o registro tivesse ficado 'claimed', a recusa
        #     seria o gate de commit ambiguo. Os dois caminhos recusam, nenhum
        #     reescreve.
        $muBytes = [IO.File]::ReadAllBytes($rpMu)
        $sMu2 = Invoke-HFSettle -Key $sxMu.key -Authorization $sxMu.fx.auth -Result $s1cand -Fp $fpMu
        # PRA-SETTLE-FIX4: com a porta propria do 'settled' do HANDOFF na
        # duplicata (bloqueador 3), o registro adulterado e recusado como
        # `settle-duplicate-unproven` - a duplicata so e idempotente quando o
        # PROPRIO registro prova a liquidacao (forma crua + kernel_ok true +
        # evidencia). Se o registro tivesse ficado 'claimed', a recusa seria
        # o gate de commit ambiguo. Os dois caminhos recusam, nenhum reescreve.
        Assert-HF (((-not [bool]$sMu2.ok) -and (-not [bool]$sMu2.settled) -and (-not [bool]$sMu2.reconciled) -and ((@('settle-kernel-commit-ambiguous', 'settle-duplicate-unproven') -ccontains [string]$sMu2.reason)))) ('[F4-6/' + [string]$mu.tag + '] the retry is refused fail-closed on the tampered record (ambiguous commit or unproven duplicate)') (([string]$sMu2.reason) + ' (no rewrite either way)')
        $revMu2 = [long](Get-OrchestrationTask -TaskId $sxMu.fx.task -TasksDir $tasksDir).revision
        Assert-HF ($revMu2 -eq $revMu) '[F4-6] the ambiguous retry performs NO second kernel write' ('before=' + [string]$revMu + ' after=' + [string]$revMu2)
        $evMu2 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Assert-HF ($evMu2 -eq $evMu) '[F4-6] the ambiguous retry creates NO second evidence row' ('before=' + [string]$evMu + ' after=' + [string]$evMu2)
        $muBytes2 = [IO.File]::ReadAllBytes($rpMu)
        $muSame = ($muBytes2.Length -eq $muBytes.Length)
        if ($muSame) { for ($bi = 0; $bi -lt $muBytes2.Length; $bi++) { if ([int]$muBytes2[$bi] -ne [int]$muBytes[$bi]) { $muSame = $false; break } } }
        Assert-HF $muSame ('[F4-6/' + [string]$mu.tag + '] the ambiguous retry left the receipt byte-identical (no fabricated write)') 'content changed'
        Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) ('[F4-6/' + [string]$mu.tag + '] no Executor call in the tampered-token scenario') ''
        # (e) reserva de task: a liquidacao ambigua NAO usa a resposta para
        #     liberar nada. Um claim novo sobre a MESMA task e barrado
        #     fail-clado - pelo bloqueio de reserva quando a liquidacao nao
        #     e conhecida, ou pela varredura indecidivel quando o token
        #     `kernel_ok` do registro persistido esta em forma de array.
        $kMuSecond = Get-NativeDispatchHash32 ('hf-settle-mutate-second-' + [string]$mu.tag)
        $iMuSecond = New-HFIntent -Task $sxMu.fx.task -Key $kMuSecond -Gen $sxMu.fx.gen -Rev $revMu2
        $pMuSecond = Invoke-OrchestrationNativeDispatchPrepare -Intent $iMuSecond -Authorization $sxMu.fx.auth -SessionId 'ses_hf_musecond' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pMuSecond.ok) ('[F4-6/' + [string]$mu.tag + '] a second effect on the same task can still be PREPARED (prepare is not an effect)') ([string]$pMuSecond.reason)
        $cMuSecond = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kMuSecond -Authorization $sxMu.fx.auth -SessionId 'ses_hf_musecond' -MessageId 'msg_hf_musecond' -CallId 'call_hf_musecond' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pMuSecond.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        $revMu3 = [long](Get-OrchestrationTask -TaskId $sxMu.fx.task -TasksDir $tasksDir).revision
        # PRA-SETTLE-FIX4 (bloqueador 4): a varredura global de reserva agora
        # valida o 'settled' do HANDOFF antes de liberar a task. O registro
        # adulterado (token em forma de array) e INDECIDIVEL: a varredura
        # recusa (claim-task-scan-unreadable) e a reserva continua valendo - a
        # liquidacao ambigua NAO libera segundo efeito por nenhum caminho, e
        # isso nao quebra o schema legado, que tem porta propria.
        $muScanNode = Get-NDValueNode -Object $muRaw -Name ([string]$mu.field)
        Assert-HF (((-not [bool]$cMuSecond.ok) -and (-not [bool]$cMuSecond.claimed) -and ((@('claim-task-scan-unreadable', 'claim-task-already-claimed') -ccontains [string]$cMuSecond.reason)) -and ([int]$cMuSecond.executor_calls -eq 0))) ('[F4-6/' + [string]$mu.tag + '] the tampered settled record keeps the task reservation BLOCKED (the scan validates the handoff-settled shape)') ([string]$cMuSecond.reason)
        Assert-HF (($null -ne $muScanNode) -and ([string]$muScanNode.kind -ceq 'list')) ('[F4-6/' + [string]$mu.tag + '] the block is the fail-closed scan over the tampered token (no documented residual left)') ('field=' + [string]$mu.field + ' kind=' + [string]$muScanNode.kind + ' reason=' + [string]$cMuSecond.reason)
        Assert-HF ($revMu3 -eq $revMu2) ('[F4-6/' + [string]$mu.tag + '] the second claim attempt wrote nothing in the kernel') ('rev=' + [string]$revMu3)
    }
    # controle positivo COM TIPOS EXATOS: o escritor persiste o 'settled'
    # EXATO e devolve $false; a releitura sob lock prova o commit e a
    # liquidacao responde sucesso - nenhum campo em forma de array.
    # PRA-SETTLE-FIX5: raiz NOVA - o controle precisa de um claim novo
    # (fixture proprio) e a raiz anterior guarda os 'settled' adulterados
    # do laco, que agora nao podem ser ignorados como "outra task".
    $receiptDir = New-HFReceiptRoot -Name 'fix6-mutate-ok'
    $sxMuOk = New-HFSettleFixture -Suffix 'settle-mutate-ok' -KeyMaterial 'hf-settle-mutate-ok'
    $fpMuOk = ([string]$sxMuOk.prepare.prepared_fingerprint)
    $revMuOkBefore = [long](Get-OrchestrationTask -TaskId $sxMuOk.fx.task -TasksDir $tasksDir).revision
    $evMuOkBefore = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Set-HFReceiptWriteMode -Mode 'persist-then-false-settled'
    try { $sMuOk = Invoke-HFSettle -Key $sxMuOk.key -Authorization $sxMuOk.fx.auth -Result $s1cand -Fp $fpMuOk }
    finally { Set-HFReceiptWriteMode -Mode 'pass' }
    Assert-HF (([bool]$sMuOk.ok) -and ([bool]$sMuOk.settled) -and (-not [bool]$sMuOk.duplicate) -and (-not [bool]$sMuOk.reconciled) -and ([string]$sMuOk.phase -ceq 'settled') -and ([string]$sMuOk.reason -ceq '')) '[F4-6] control: an EXACT persisted settled receipt (no array token) still proves the commit' ('reason=' + [string]$sMuOk.reason)
    $muOkRaw = Get-HFReceiptRaw -GoalId $sxMuOk.fx.goal -Key $sxMuOk.key
    Assert-HF (($null -ne $muOkRaw) -and (Test-NDSettledReceiptFieldShape -Receipt $muOkRaw) -and ([string]$muOkRaw.worker_result.status -ceq 'candidate_pass') -and ([bool]$muOkRaw.kernel_ok) -and ([string]$muOkRaw.settle_child_session_id -ceq 'ses_hf_child_1')) '[F4-6] control: the persisted receipt holds the EXACT scalar types (kernel_ok bool, child string, candidate object)' ''
    $revMuOk = [long](Get-OrchestrationTask -TaskId $sxMuOk.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revMuOk -eq ($revMuOkBefore + 1)) '[F4-6] control: the kernel was written exactly once' ('rev=' + [string]$revMuOkBefore + '->' + [string]$revMuOk)
    $evMuOk = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evMuOk -eq ($evMuOkBefore + 1)) '[F4-6] control: exactly one evidence row' ('before=' + [string]$evMuOkBefore + ' after=' + [string]$evMuOk)

    # ==================================================================
    # PRA-SETTLE-FIX4 (bloqueadores 2 e 5): o escritor devolve $true e o
    # registro persistado fica adulterado. Um retorno $true do escritor NAO
    # pode provar que o disco contem o 'settled' EXATO - a prova vem da
    # RELEITURA sob os dois locks, que aqui encontra o token em forma de
    # array e devolve a ambiguidade EXPLICITA, sem alegar liquidacao e sem
    # liberar a reserva. Uma segunda chave da MESMA task continua barrada.
    # ==================================================================
    # PRA-SETTLE-FIX5: raiz PROPRIA - o registro 'settled' adulterado
    # (token em forma de array) fica em disco e, com a nova porta, nao
    # pode ser ignorado como "outra task"; a adulteracao nao vaza para os
    # grupos seguintes.
    # PRA-SETTLE-FIX6: raiz NOVA POR ITERACAO (a mesma regra do laco
    # F4-6). O registro 'settled' adulterado de uma iteracao fica em disco
    # e, com a porta FIX5, recusa a varredura INTEIRA daquela raiz
    # (indecidivel ou reservada) - sem raiz propria, a iteracao seguinte
    # nem consegue criar o fixture (o CLAIM do fixture ja seria barrado
    # pelo registro adulterado da iteracao anterior).
    foreach ($muT in @(
        @{ tag = 'kernel_ok'; field = 'kernel_ok' }
        @{ tag = 'child-session'; field = 'settle_child_session_id' }
    )) {
        $receiptDir = New-HFReceiptRoot -Name ('fix7-true-' + [string]$muT.tag)
        $sxT = New-HFSettleFixture -Suffix ('settle-true-mut-' + [string]$muT.tag) -KeyMaterial ('hf-settle-true-mutate-' + [string]$muT.tag)
        $fpT = ([string]$sxT.prepare.prepared_fingerprint)
        $rpT = Get-HFReceiptPath -GoalId $sxT.fx.goal -Key $sxT.key
        $revTBefore = [long](Get-OrchestrationTask -TaskId $sxT.fx.task -TasksDir $tasksDir).revision
        $evTBefore = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Set-HFReceiptMutateField -Field ([string]$muT.field)
        Set-HFReceiptWriteMode -Mode 'persist-mutate-settled-true'
        try { $sT = Invoke-HFSettle -Key $sxT.key -Authorization $sxT.fx.auth -Result $s1cand -Fp $fpT }
        finally { Set-HFReceiptWriteMode -Mode 'pass'; Set-HFReceiptMutateField -Field '' }
        # (a) a prova de releitura RODOU mesmo com o escritor devolvendo
        #     $true: a resposta e a ambiguidade, nunca sucesso.
        Assert-HF (((-not [bool]$sT.ok) -and (-not [bool]$sT.settled) -and (-not [bool]$sT.duplicate) -and (-not [bool]$sT.reconciled) -and ([string]$sT.reason -like 'settle-receipt-proof-*') -and ([string]::IsNullOrWhiteSpace([string]$sT.phase)) -and ([string]::IsNullOrWhiteSpace([string]$sT.handoff_state)))) ('[F4-7/' + [string]$muT.tag + '] a writer TRUE return does NOT bypass the reread: the tampered settled receipt is an EXPLICIT ambiguity') ('reason=' + [string]$sT.reason)
        # (b) o disco tem 'settled' com o token em forma de array - e a prova
        #     recusou mesmo assim (a fase nao basta).
        $tRaw = Get-HFReceiptRaw -GoalId $sxT.fx.goal -Key $sxT.key
        Assert-HF (($null -ne $tRaw) -and ([string]$tRaw.phase -ceq 'settled') -and ([string]$tRaw.handoff_state -ceq 'SETTLED')) ('[F4-7/' + [string]$muT.tag + '] the writer really persisted the settled phase') ('phase=' + [string]$tRaw.phase)
        $tTok = Get-NDValueNode -Object $tRaw -Name ([string]$muT.field)
        Assert-HF (($null -ne $tTok) -and ([string]$tTok.kind -ceq 'list')) ('[F4-7/' + [string]$muT.tag + '] the persisted token really is a singleton ARRAY') ('kind=' + [string]$tTok.kind)
        # (c) UMA escrita de kernel e UMA evidencia: nada de segunda escrita.
        $revT = [long](Get-OrchestrationTask -TaskId $sxT.fx.task -TasksDir $tasksDir).revision
        Assert-HF (($revT -eq ($revTBefore + 1)) -and ($revTBefore -eq 1)) '[F4-7] the kernel was written exactly ONCE (before the receipt write)' ('rev=' + [string]$revTBefore + '->' + [string]$revT)
        $evT = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Assert-HF ($evT -eq ($evTBefore + 1)) '[F4-7] exactly ONE evidence row exists for this claim' ('before=' + [string]$evTBefore + ' after=' + [string]$evT)
        # (d) retentativa: recusa fail-closed pela porta do 'settled' do
        #     handoff, sem nova escrita e sem reescrever o registro.
        $tBytes = [IO.File]::ReadAllBytes($rpT)
        $sT2 = Invoke-HFSettle -Key $sxT.key -Authorization $sxT.fx.auth -Result $s1cand -Fp $fpT
        Assert-HF (((-not [bool]$sT2.ok) -and (-not [bool]$sT2.settled) -and (-not [bool]$sT2.reconciled) -and ((@('settle-duplicate-unproven', 'settle-kernel-commit-ambiguous') -ccontains [string]$sT2.reason)))) ('[F4-7/' + [string]$muT.tag + '] the retry is refused fail-closed on the tampered record (unproven duplicate or ambiguous commit)') (([string]$sT2.reason) + ' (no rewrite either way)')
        $revT2 = [long](Get-OrchestrationTask -TaskId $sxT.fx.task -TasksDir $tasksDir).revision
        Assert-HF ($revT2 -eq $revT) '[F4-7] the ambiguous retry performs NO second kernel write' ('before=' + [string]$revT + ' after=' + [string]$revT2)
        $evT2 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Assert-HF ($evT2 -eq $evT) '[F4-7] the ambiguous retry creates NO second evidence row' ('before=' + [string]$evT + ' after=' + [string]$evT2)
        $tBytes2 = [IO.File]::ReadAllBytes($rpT)
        $tSame = ($tBytes2.Length -eq $tBytes.Length)
        if ($tSame) { for ($bi = 0; $bi -lt $tBytes2.Length; $bi++) { if ([int]$tBytes2[$bi] -ne [int]$tBytes[$bi]) { $tSame = $false; break } } }
        Assert-HF $tSame ('[F4-7/' + [string]$muT.tag + '] the ambiguous retry left the receipt byte-identical (no fabricated write)') 'content changed'
        # (e) reserva de task: a liquidacao ambigua NAO libera nada. Uma
        #     segunda chave da MESMA task continua barrada - pela varredura
        #     indecidivel (token em forma de array) ou pela reserva.
        $kTSecond = Get-NativeDispatchHash32 ('hf-settle-true-mutate-second-' + [string]$muT.tag)
        $iTSecond = New-HFIntent -Task $sxT.fx.task -Key $kTSecond -Gen $sxT.fx.gen -Rev $revT2
        $pTSecond = Invoke-OrchestrationNativeDispatchPrepare -Intent $iTSecond -Authorization $sxT.fx.auth -SessionId 'ses_hf_tsecond' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pTSecond.ok) ('[F4-7/' + [string]$muT.tag + '] a second effect on the same task can still be PREPARED (prepare is not an effect)') ([string]$pTSecond.reason)
        $cTSecond = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kTSecond -Authorization $sxT.fx.auth -SessionId 'ses_hf_tsecond' -MessageId 'msg_hf_tsecond' -CallId 'call_hf_tsecond' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pTSecond.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cTSecond.ok) -and (-not [bool]$cTSecond.claimed) -and ((@('claim-task-scan-unreadable', 'claim-task-already-claimed') -ccontains [string]$cTSecond.reason)) -and ([int]$cTSecond.executor_calls -eq 0))) ('[F4-7/' + [string]$muT.tag + '] the ambiguous outcome keeps the task reservation BLOCKED (no second effect admitted)') ([string]$cTSecond.reason)
        $revT3 = [long](Get-OrchestrationTask -TaskId $sxT.fx.task -TasksDir $tasksDir).revision
        Assert-HF ($revT3 -eq $revT2) ('[F4-7/' + [string]$muT.tag + '] the refused second claim wrote nothing in the kernel') ('rev=' + [string]$revT3)
        Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) ('[F4-7/' + [string]$muT.tag + '] no Executor call in the writer-true tampering scenario') ''
    }
    # controle positivo: escritor devolve $true e o registro persistido e
    # EXATO - a prova de releitura passa e a liquidacao responde sucesso.
    # PRA-SETTLE-FIX5: raiz NOVA - o controle cria fixture proprio (claim
    # novo) e a raiz anterior guarda os 'settled' adulterados do laco.
    $receiptDir = New-HFReceiptRoot -Name 'fix7-true-ok'
    $sxTOk = New-HFSettleFixture -Suffix 'settle-true-ok' -KeyMaterial 'hf-settle-true-ok'
    $fpTOk = ([string]$sxTOk.prepare.prepared_fingerprint)
    $revTOkBefore = [long](Get-OrchestrationTask -TaskId $sxTOk.fx.task -TasksDir $tasksDir).revision
    $evTOkBefore = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $sTOk = Invoke-HFSettle -Key $sxTOk.key -Authorization $sxTOk.fx.auth -Result $s1cand -Fp $fpTOk
    Assert-HF (([bool]$sTOk.ok) -and ([bool]$sTOk.settled) -and (-not [bool]$sTOk.duplicate) -and (-not [bool]$sTOk.reconciled) -and ([string]$sTOk.phase -ceq 'settled') -and ([string]$sTOk.reason -ceq '')) '[F4-7] control: with a TRUE writer return and an EXACT receipt, the reread proof still confirms the settle' ('reason=' + [string]$sTOk.reason)
    $revTOk = [long](Get-OrchestrationTask -TaskId $sxTOk.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revTOk -eq ($revTOkBefore + 1)) '[F4-7] control: the kernel was written exactly once' ('rev=' + [string]$revTOkBefore + '->' + [string]$revTOk)
    $evTOk = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    Assert-HF ($evTOk -eq ($evTOkBefore + 1)) '[F4-7] control: exactly one evidence row' ('before=' + [string]$evTOkBefore + ' after=' + [string]$evTOk)

    # ==================================================================
    # PRA-SETTLE-FIX4 (bloqueador 4): a varredura global de reserva valida
    # o 'settled' do HANDOFF (forma crua + evidencia + kernel conhecido)
    # ANTES de liberar a task. O schema LEGADO tem porta propria e segue
    # intacto (coberto por F4-1..F4-5).
    # ==================================================================
    # PRA-SETTLE-FIX5: raiz propria para F4-8, F4-9, F5-dup e F5-legacy -
    # todos RESTAURAM o registro exato ao fim de cada caso (nenhum
    # 'settled' adulterado sobrevive), entao a convivencia entre eles e
    # segura e a varretta caminha so os namespaces deste bloco.
    $receiptDir = New-HFReceiptRoot -Name 'fix8-scan'
    $fxHs = New-HFSettleFixture -Suffix 'fix4scan' -KeyMaterial 'hf-fix4-scan-1'
    $fpHs = ([string]$fxHs.prepare.prepared_fingerprint)
    $sHs = Invoke-HFSettle -Key $fxHs.key -Authorization $fxHs.fx.auth -Result $s1cand -Fp $fpHs
    Assert-HF (([bool]$sHs.ok) -and ([bool]$sHs.settled) -and (-not [bool]$sHs.duplicate)) '[F4-8] the handoff fixture settled (known settlement)' ([string]$sHs.reason)
    $hsPath = Get-HFReceiptPath -GoalId $fxHs.fx.goal -Key $fxHs.key
    $hsGood = [IO.File]::ReadAllText($hsPath, [Text.Encoding]::UTF8)
    # a liquidacao avancou a revisao viva da task: a segunda chave usa a
    # revisao ATUAL (prepare de chave nova e governado pela admissao viva).
    $hsLive = Get-OrchestrationTask -TaskId $fxHs.fx.task -TasksDir $tasksDir
    $hsRevNow = 1
    try { $hsRevNow = [long]$hsLive.revision } catch { $hsRevNow = 1 }
    # ATENCAO (ordem): o controle de LIBERACAO fica no FINAL. Um claim
    # bem-sucedido deixa um recibo 'claimed' da MESMA task, que por si so
    # reserva a task - portanto ele nao pode rodar antes dos casos de recusa.
    # casos: cada um corrompe UM campo do registro 'settled' persistido e
    # exige que a varredura recuse - indecidivel (forma crua) ou reservada
    # (liquidacao nao provada). NUNCA segundo efeito. Cada caso usa uma
    # chave NOVA, porque um claim bem-sucedido consumiria o preparo.
    $hsBadCases = @(
        @{ tag = 'kernel_ok-false';    kind = 'set';    field = 'kernel_ok';                  value = [bool]$false; expect = 'claim-task-already-claimed' }
        @{ tag = 'evidence_created';   kind = 'set';    field = 'evidence_created';           value = [bool]$false; expect = 'claim-task-already-claimed' }
        @{ tag = 'evidence_id-empty';  kind = 'set';    field = 'evidence_id';                value = '';           expect = 'claim-task-already-claimed' }
        @{ tag = 'settle_status-bad';  kind = 'set';    field = 'settle_status';              value = 'verified_pass'; expect = 'claim-task-already-claimed' }
        @{ tag = 'child-array';        kind = 'set';    field = 'settle_child_session_id';    value = @('ses_hf_child_1'); expect = 'claim-task-scan-unreadable' }
        @{ tag = 'kernel_ok-array';    kind = 'set';    field = 'kernel_ok';                  value = @([bool]$true); expect = 'claim-task-scan-unreadable' }
        @{ tag = 'settle_status-gone'; kind = 'remove'; field = 'settle_status';              value = $null;        expect = 'claim-task-scan-unreadable' }
    )
    $hsCaseIdx = 0
    foreach ($hb in @($hsBadCases)) {
        $hsCaseIdx++
        $hbTag = [string]$hb.tag
        $hbField = [string]$hb.field
        $mutated = $false
        if ([string]$hb.kind -ceq 'remove') { $mutated = Remove-HFReceiptField -Path $hsPath -Field $hbField }
        else { $mutated = Set-HFReceiptField -Path $hsPath -Field $hbField -Value $hb.value }
        if (-not $mutated) {
            Assert-HF $false ('[F4-8] fixture could not mutate ' + $hbTag) 'mutation failed'
            continue
        }
        $hbKey = Get-NativeDispatchHash32 ('hf-fix4-scan-bad-' + $hbTag)
        $iHb = New-HFIntent -Task $fxHs.fx.task -Key $hbKey -Gen $fxHs.fx.gen -Rev $hsRevNow
        $pHb = Invoke-OrchestrationNativeDispatchPrepare -Intent $iHb -Authorization $fxHs.fx.auth -SessionId ('ses_hf_hsbad' + [string]$hsCaseIdx) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pHb.ok) ('[F4-8] a fresh second key prepared for the ' + $hbTag + ' case') ([string]$pHb.reason)
        $cHsBad = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $hbKey -Authorization $fxHs.fx.auth -SessionId ('ses_hf_hsbad' + [string]$hsCaseIdx) -MessageId ('msg_hf_hsbad' + [string]$hsCaseIdx) -CallId ('call_hf_hsbad' + [string]$hsCaseIdx) -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pHb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cHsBad.ok) -and (-not [bool]$cHsBad.claimed) -and ([string]$cHsBad.reason -ceq ([string]$hb.expect)) -and ([int]$cHsBad.executor_calls -eq 0))) ('[F4-8] a handoff settled receipt with ' + $hbTag + ' fails closed (' + [string]$hb.expect + ')') ([string]$cHsBad.reason)
        $kHbRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxHs.fx.goal -Key $hbKey), [Text.Encoding]::UTF8))
        Assert-HF ([string]$kHbRaw.phase -ceq 'prepared') ('[F4-8] the ' + $hbTag + ' refusal never consumes the prepared receipt') ('phase=' + [string]$kHbRaw.phase)
        [IO.File]::WriteAllText($hsPath, $hsGood, [Text.UTF8Encoding]::new($false))
    }
    # controle final: restaurado o registro EXATO, a reserva volta a liberar.
    $kHsEnd = Get-NativeDispatchHash32 'hf-fix4-scan-end'
    $iHsEnd = New-HFIntent -Task $fxHs.fx.task -Key $kHsEnd -Gen $fxHs.fx.gen -Rev $hsRevNow
    $pHsEnd = Invoke-OrchestrationNativeDispatchPrepare -Intent $iHsEnd -Authorization $fxHs.fx.auth -SessionId 'ses_hf_hsend' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pHsEnd.ok) '[F4-8] a fresh key prepared for the final control' ([string]$pHsEnd.reason)
    $cHsEnd = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kHsEnd -Authorization $fxHs.fx.auth -SessionId 'ses_hf_hsend' -MessageId 'msg_hf_hsend' -CallId 'call_hf_hsend' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pHsEnd.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cHsEnd.ok) -and ([bool]$cHsEnd.claimed)) '[F4-8] control: the exact settled receipt releases the reservation again' ([string]$cHsEnd.reason)

    # ==================================================================
    # PRA-SETTLE-FIX4 (bloqueador 3): a duplicata settled so e idempotente
    # quando o PROPRIO registro prova a liquidacao - kernel_ok EXATAMENTE
    # true, evidence_created EXATAMENTE true e evidence_id nao vazio - e a
    # linhagem devolvida e sempre a ARMAZENADA, comparada com a apresentada.
    # ==================================================================
    $fxDp = New-HFSettleFixture -Suffix 'fix4dup' -KeyMaterial 'hf-fix4-dup-1'
    $fpDp = ([string]$fxDp.prepare.prepared_fingerprint)
    $sDp = Invoke-HFSettle -Key $fxDp.key -Authorization $fxDp.fx.auth -Result $s1cand -Fp $fpDp
    Assert-HF (([bool]$sDp.ok) -and ([bool]$sDp.settled) -and (-not [bool]$sDp.duplicate)) '[F4-9] the duplicate fixture settled' ([string]$sDp.reason)
    $dpPath = Get-HFReceiptPath -GoalId $fxDp.fx.goal -Key $fxDp.key
    $dpGood = [IO.File]::ReadAllText($dpPath, [Text.Encoding]::UTF8)
    # controle: duplicata identica sobre o registro PROVADO e idempotente e
    # devolve a linhagem ARMAZENADA (child session do recibo).
    $sDpOk = Invoke-HFSettle -Key $fxDp.key -Authorization $fxDp.fx.auth -Result $s1cand -Fp $fpDp
    Assert-HF (([bool]$sDpOk.ok) -and ([bool]$sDpOk.duplicate) -and ([bool]$sDpOk.settled) -and ([string]$sDpOk.reason -ceq 'settle-duplicate') -and ([string]$sDpOk.child_session_id -ceq 'ses_hf_child_1') -and ([bool]$sDpOk.kernel_ok) -and ([string]::IsNullOrWhiteSpace([string]$sDpOk.evidence_id) -eq $false)) '[F4-9] control: a PROVEN settled duplicate is idempotent and returns the STORED lineage' ([string]$sDpOk.reason)
    # casos: cada um Remove a prova da liquidacao do PROPRIO registro e a
    # duplicata deixa de ser idempotente (settle-duplicate-unproven).
    $dpBadCases = @(
        @{ tag = 'kernel_ok-false';   kind = 'set';    field = 'kernel_ok';        value = [bool]$false }
        @{ tag = 'evidence_created';  kind = 'set';    field = 'evidence_created'; value = [bool]$false }
        @{ tag = 'evidence_id-empty'; kind = 'set';    field = 'evidence_id';      value = '' }
        @{ tag = 'evidence_id-gone';  kind = 'remove'; field = 'evidence_id';      value = $null }
        @{ tag = 'kernel_ok-array';   kind = 'set';    field = 'kernel_ok';        value = @([bool]$true) }
    )
    foreach ($db in @($dpBadCases)) {
        $dbTag = [string]$db.tag
        $dbField = [string]$db.field
        $dbMutated = $false
        if ([string]$db.kind -ceq 'remove') { $dbMutated = Remove-HFReceiptField -Path $dpPath -Field $dbField }
        else { $dbMutated = Set-HFReceiptField -Path $dpPath -Field $dbField -Value $db.value }
        if (-not $dbMutated) {
            Assert-HF $false ('[F4-9] fixture could not mutate ' + $dbTag) 'mutation failed'
            continue
        }
        $sDpBad = Invoke-HFSettle -Key $fxDp.key -Authorization $fxDp.fx.auth -Result $s1cand -Fp $fpDp
        Assert-HF (((-not [bool]$sDpBad.ok) -and (-not [bool]$sDpBad.duplicate) -and (-not [bool]$sDpBad.settled) -and ([string]$sDpBad.reason -ceq 'settle-duplicate-unproven'))) ('[F4-9] a settled duplicate with ' + $dbTag + ' is NOT idempotent (duplicate-unproven)') ([string]$sDpBad.reason)
        [IO.File]::WriteAllText($dpPath, $dpGood, [Text.UTF8Encoding]::new($false))
    }
    # linhagem: sessao/mensagem/call/caller/target ARMAZENADOS tem de ser
    # EXATAMENTE os apresentados; divergencia recusa (nunca reaproveita).
    $dpLinGood = [IO.File]::ReadAllText($dpPath, [Text.Encoding]::UTF8)
    Assert-HF (Set-HFReceiptField -Path $dpPath -Field 'settle_session_id' -Value 'ses_hf_OTHER') '[F4-9] fixture mutated the stored settle session' ''
    $sDpLin = Invoke-HFSettle -Key $fxDp.key -Authorization $fxDp.fx.auth -Result $s1cand -Fp $fpDp
    # PRA-SETTLE-FIX5: a prova estrita do 'settled' roda PRIMEIRO e ja
    # vincula a linhagem settle_* aos claim_* do PROPRIO registro, entao uma
    # sessao ARMAZENADA adulterada e recusada por ela
    # ('settle-duplicate-unproven'); a checagem especifica de linhagem
    # APRESENTADA segue valendo para o registro INTACTO
    # ('settle-duplicate-host-call-mismatch'). Os dois caminhos recusam.
    Assert-HF (((-not [bool]$sDpLin.ok) -and (-not [bool]$sDpLin.duplicate) -and (@('settle-duplicate-host-call-mismatch', 'settle-duplicate-unproven') -ccontains [string]$sDpLin.reason))) '[F4-9] a settled duplicate whose STORED host lineage diverges is refused' ([string]$sDpLin.reason)
    [IO.File]::WriteAllText($dpPath, $dpLinGood, [Text.UTF8Encoding]::new($false))
    $sDpEnd = Invoke-HFSettle -Key $fxDp.key -Authorization $fxDp.fx.auth -Result $s1cand -Fp $fpDp
    Assert-HF (([bool]$sDpEnd.ok) -and ([bool]$sDpEnd.duplicate) -and ([string]$sDpEnd.reason -ceq 'settle-duplicate')) '[F4-9] control: with the exact receipt restored, the duplicate is idempotent again' ([string]$sDpEnd.reason)
    $dpRevEnd = [long](Get-OrchestrationTask -TaskId $fxDp.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($dpRevEnd -eq 2) '[F4-9] no duplicate refusal ever rewrote the kernel (revision kept at 2)' ('rev=' + [string]$dpRevEnd)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F4-9] no Executor call in the duplicate-proof scenarios' ''

    # ==================================================================
    # PRA-SETTLE-FIX5: a porta do 'settled' do HANDOFF RECONSTROI a
    # liquidacao dos campos persistidos no PROPRIO registro. Um escritor
    # que grava o 'settled' e troca UM campo de MESMO TIPO por outro valor
    # VALIDO (child session id -> outra string valida; evidence_id -> outro
    # hash valido) devolvendo $false NAO pode liberar a reserva de task: a
    # prova de releitura recusa (settle-receipt-proof-*), a segunda chave -
    # CLAIM nativo E Invoke legado - continua barrada pela varredura com 0
    # chamadas de Executor, e o registro EXATO volta a liberar.
    # ==================================================================
    # PRA-SETTLE-FIX5: raiz PROPRIA - o registro 'settled' adulterado
    # (valor de MESMO tipo) fica em disco e nao pode ser ignorado como
    # "outra task"; a adulteracao nao vaza para os grupos seguintes.
    # PRA-SETTLE-FIX6: raiz NOVA POR ITERACAO. O registro 'settled'
    # adulterado de um caso recusa a varredura INTEIRA da raiz onde esta
    # (a prova estrita do handoff nao deixa marca-nao-provada ser lida
    # como efeito de outra task), entao cada caso precisa da raiz propria
    # para o fixture do caso seguinte existir.
    foreach ($f5 in @(
        @{ tag = 'child-session'; field = 'settle_child_session_id'; value = 'ses_hf_child_ALT'; expect = 'settled-attempt-mismatch' }
        @{ tag = 'evidence-id';    field = 'evidence_id';              value = ('f' * 32);        expect = 'settled-evidence-unbound' }
        @{ tag = 'settle-evidence-id'; field = 'settle_evidence_id';   value = ('e' * 32);        expect = 'settled-evidence-unbound' }
    )) {
        $f5Tag = [string]$f5.tag
        # PRA-SETTLE-FIX6: raiz NOVA por iteracao - a raiz anterior guarda
        # o registro 'settled' adulterado do caso anterior.
        $receiptDir = New-HFReceiptRoot -Name ('fix5-mut-' + $f5Tag)
        $fxF5 = New-HFSettleFixture -Suffix ('fix5-' + $f5Tag) -KeyMaterial ('hf-fix5-mutate-' + $f5Tag)
        $fpF5 = ([string]$fxF5.prepare.prepared_fingerprint)
        $rpF5 = Get-HFReceiptPath -GoalId $fxF5.fx.goal -Key $fxF5.key
        $revF5Before = [long](Get-OrchestrationTask -TaskId $fxF5.fx.task -TasksDir $tasksDir).revision
        $evF5Before = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        $spyF5Before = [int]$script:spyState.calls
        Set-HFReceiptMutateValue -Field ([string]$f5.field) -Value ([string]$f5.value)
        Set-HFReceiptWriteMode -Mode 'persist-mutate-value-settled'
        try { $sF5 = Invoke-HFSettle -Key $fxF5.key -Authorization $fxF5.fx.auth -Result $s1cand -Fp $fpF5 }
        finally { Set-HFReceiptWriteMode -Mode 'pass'; Set-HFReceiptMutateValue -Field '' -Value '' }
        Assert-HF (((-not [bool]$sF5.ok) -and (-not [bool]$sF5.settled) -and (-not [bool]$sF5.duplicate) -and (-not [bool]$sF5.reconciled) -and ([string]$sF5.reason -like 'settle-receipt-proof-*') -and ([string]::IsNullOrWhiteSpace([string]$sF5.phase)) -and ([string]::IsNullOrWhiteSpace([string]$sF5.handoff_state)))) ('[F5/' + $f5Tag + '] a same-type tampered settled receipt is an EXPLICIT ambiguity (never success)') ('reason=' + [string]$sF5.reason)
        # disco: 'settled' com o campo de MESMO TIPO trocado por valor valido.
        $f5Raw = Get-HFReceiptRaw -GoalId $fxF5.fx.goal -Key $fxF5.key
        Assert-HF (($null -ne $f5Raw) -and ([string]$f5Raw.phase -ceq 'settled') -and ([string]$f5Raw.handoff_state -ceq 'SETTLED')) ('[F5/' + $f5Tag + '] the writer really persisted the settled phase (no manual phase mutation)') ('phase=' + [string]$f5Raw.phase)
        $f5Tok = Get-NDValueNode -Object $f5Raw -Name ([string]$f5.field)
        Assert-HF (($null -ne $f5Tok) -and ([string]$f5Tok.kind -ceq 'string') -and ([string]$f5Tok.value -ceq ([string]$f5.value))) ('[F5/' + $f5Tag + '] the persisted token is another valid SAME-TYPE value (string)') ('kind=' + [string]$f5Tok.kind + ' value=' + [string]$f5Tok.value)
        # a prova estrita recusa pela CORRELACAO semantica, nao pela forma
        # crua: e exatamente o caso que a porta antiga deixava passar.
        $f5Proof = Test-NDSettledHandoffProof -Receipt $f5Raw
        Assert-HF (((-not [bool]$f5Proof.ok) -and ([string]$f5Proof.reason -ceq ([string]$f5.expect)))) ('[F5/' + $f5Tag + '] the strict settlement proof refuses the tampered record by SEMANTIC correlation') ('reason=' + [string]$f5Proof.reason)
        # UMA escrita de kernel e UMA evidencia: nada de segunda escrita.
        $revF5 = [long](Get-OrchestrationTask -TaskId $fxF5.fx.task -TasksDir $tasksDir).revision
        Assert-HF (($revF5 -eq ($revF5Before + 1)) -and ($revF5Before -eq 1)) ('[F5/' + $f5Tag + '] the kernel was written exactly ONCE (before the receipt write)') ('rev=' + [string]$revF5Before + '->' + [string]$revF5)
        $evF5 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
        Assert-HF ($evF5 -eq ($evF5Before + 1)) ('[F5/' + $f5Tag + '] exactly ONE evidence row exists for this claim') ('before=' + [string]$evF5Before + ' after=' + [string]$evF5)
        # retentativa da liquidacao: recusa fail-closed pela porta do
        # 'settled' do handoff, sem reescrever nada.
        $f5Bytes = [IO.File]::ReadAllBytes($rpF5)
        $sF5Retry = Invoke-HFSettle -Key $fxF5.key -Authorization $fxF5.fx.auth -Result $s1cand -Fp $fpF5
        Assert-HF (((-not [bool]$sF5Retry.ok) -and (-not [bool]$sF5Retry.settled) -and (-not [bool]$sF5Retry.duplicate) -and (-not [bool]$sF5Retry.reconciled) -and ([string]$sF5Retry.reason -ceq 'settle-duplicate-unproven'))) ('[F5/' + $f5Tag + '] the retry is refused fail-closed on the tampered record (unproven duplicate)') ('reason=' + [string]$sF5Retry.reason)
        $revF5Retry = [long](Get-OrchestrationTask -TaskId $fxF5.fx.task -TasksDir $tasksDir).revision
        Assert-HF ($revF5Retry -eq $revF5) ('[F5/' + $f5Tag + '] the refused retry performs NO second kernel write') ('rev=' + [string]$revF5Retry)
        $f5Bytes2 = [IO.File]::ReadAllBytes($rpF5)
        $f5Same = ($f5Bytes2.Length -eq $f5Bytes.Length)
        if ($f5Same) { for ($bi = 0; $bi -lt $f5Bytes2.Length; $bi++) { if ([int]$f5Bytes2[$bi] -ne [int]$f5Bytes[$bi]) { $f5Same = $false; break } } }
        Assert-HF $f5Same ('[F5/' + $f5Tag + '] the refused retry left the tampered receipt byte-identical (no fabricated write)') 'content changed'
        # segunda chave: PREPARE nao e efeito; o CLAIM e barrado pela
        # varredura - o registro adulterado NAO libera a reserva.
        $kF5Second = Get-NativeDispatchHash32 ('hf-fix5-second-' + $f5Tag)
        $iF5Second = New-HFIntent -Task $fxF5.fx.task -Key $kF5Second -Gen $fxF5.fx.gen -Rev $revF5
        $pF5Second = Invoke-OrchestrationNativeDispatchPrepare -Intent $iF5Second -Authorization $fxF5.fx.auth -SessionId 'ses_hf_f5second' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pF5Second.ok) ('[F5/' + $f5Tag + '] a second effect on the same task can still be PREPARED (prepare is not an effect)') ([string]$pF5Second.reason)
        $cF5Second = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5Second -Authorization $fxF5.fx.auth -SessionId 'ses_hf_f5second' -MessageId 'msg_hf_f5second' -CallId 'call_hf_f5second' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5Second.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cF5Second.ok) -and (-not [bool]$cF5Second.claimed) -and ([string]$cF5Second.reason -ceq 'claim-task-already-claimed') -and ([int]$cF5Second.executor_calls -eq 0))) ('[F5/' + $f5Tag + '] the tampered settled record KEEPS the task reservation (second-key CLAIM denied)') ([string]$cF5Second.reason)
        $cF5Raw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxF5.fx.goal -Key $kF5Second), [Text.Encoding]::UTF8))
        Assert-HF ([string]$cF5Raw.phase -ceq 'prepared') ('[F5/' + $f5Tag + '] the denied claim never consumes the prepared receipt') ('phase=' + [string]$cF5Raw.phase)
        # Invoke legado com outra chave: barrado pela MESMA varredura, com 0
        # chamadas de Executor e sem persistir recibo algum.
        $f5LegacyState = @{ calls = 0 }
        $f5LegacySpy = { param($i) $f5LegacyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $kF5Legacy = Get-NativeDispatchHash32 ('hf-fix5-legacy-' + $f5Tag)
        $lF5Legacy = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxF5.fx.task -Key $kF5Legacy -Gen $fxF5.fx.gen -Rev $revF5).intent -Executor $f5LegacySpy -Authorization $fxF5.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$lF5Legacy.ok) -and ([string]$lF5Legacy.reason -ceq 'claim-task-already-claimed') -and ([int]$lF5Legacy.executor_calls -eq 0) -and ([int]$f5LegacyState.calls -eq 0))) ('[F5/' + $f5Tag + '] the legacy Invoke with a second key is denied by the SAME scan with 0 executor calls') ([string]$lF5Legacy.reason)
        Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxF5.fx.goal -Key $kF5Legacy) -PathType Leaf)) ('[F5/' + $f5Tag + '] the denied legacy key persisted nothing') ''
        Assert-HF ([int]$script:spyState.calls -eq $spyF5Before) ('[F5/' + $f5Tag + '] no Executor call from any handoff operation in the tampered scenario') ('spy=' + [string]$script:spyState.calls + '/' + [string]$spyF5Before)
    }
    # controle positivo: o registro 'settled' EXATO passa na prova estrita e
    # LIBERA a reserva - nenhum campo alterado.
    # PRA-SETTLE-FIX5: raiz NOVA - o controle cria fixture proprio (claim
    # novo) e a raiz anterior guarda os 'settled' adulterados do laco.
    $receiptDir = New-HFReceiptRoot -Name 'fix5-ok'
    $fxF5Ok = New-HFSettleFixture -Suffix 'fix5-ok' -KeyMaterial 'hf-fix5-ok'
    $fpF5Ok = ([string]$fxF5Ok.prepare.prepared_fingerprint)
    $sF5Ok = Invoke-HFSettle -Key $fxF5Ok.key -Authorization $fxF5Ok.fx.auth -Result $s1cand -Fp $fpF5Ok
    Assert-HF (([bool]$sF5Ok.ok) -and ([bool]$sF5Ok.settled) -and (-not [bool]$sF5Ok.duplicate) -and (-not [bool]$sF5Ok.reconciled) -and ([string]$sF5Ok.reason -ceq '')) '[F5] control: an EXACT settled receipt settles as known settlement' ('reason=' + [string]$sF5Ok.reason)
    $f5OkRaw = Get-HFReceiptRaw -GoalId $fxF5Ok.fx.goal -Key $fxF5Ok.key
    Assert-HF ([bool](Test-NDSettledHandoffProof -Receipt $f5OkRaw).ok) '[F5] control: the strict settlement proof ACCEPTS the exact settled receipt' ''
    $revF5Ok = [long](Get-OrchestrationTask -TaskId $fxF5Ok.fx.task -TasksDir $tasksDir).revision
    $kF5Ok2 = Get-NativeDispatchHash32 'hf-fix5-ok-second'
    $iF5Ok2 = New-HFIntent -Task $fxF5Ok.fx.task -Key $kF5Ok2 -Gen $fxF5Ok.fx.gen -Rev $revF5Ok
    $pF5Ok2 = Invoke-OrchestrationNativeDispatchPrepare -Intent $iF5Ok2 -Authorization $fxF5Ok.fx.auth -SessionId 'ses_hf_f5ok' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5Ok2.ok) '[F5] control: a second key prepares after the exact settlement' ([string]$pF5Ok2.reason)
    $cF5Ok2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5Ok2 -Authorization $fxF5Ok.fx.auth -SessionId 'ses_hf_f5ok' -MessageId 'msg_hf_f5ok' -CallId 'call_hf_f5ok' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5Ok2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5Ok2.ok) -and ([bool]$cF5Ok2.claimed)) '[F5] control: the EXACT settled receipt RELEASES the task reservation' ([string]$cF5Ok2.reason)

    # ---------- F5-dup: a duplicata usa a MESMA prova estrita e devolve os
    # valores PERSISTIDOS (child session, evidencia, kernel) ----------
    # PRA-SETTLE-FIX5: raiz NOVA (compartilhada com F5-legacy) - a raiz do
    # laco F5 guarda 'settled' adulterados; este grupo cria fixture novo.
    $receiptDir = New-HFReceiptRoot -Name 'fix5dup'
    $fxF5D = New-HFSettleFixture -Suffix 'fix5dup' -KeyMaterial 'hf-fix5-dup-1'
    $fpF5D = ([string]$fxF5D.prepare.prepared_fingerprint)
    $sF5D = Invoke-HFSettle -Key $fxF5D.key -Authorization $fxF5D.fx.auth -Result $s1cand -Fp $fpF5D
    Assert-HF (([bool]$sF5D.ok) -and ([bool]$sF5D.settled) -and (-not [bool]$sF5D.duplicate)) '[F5-dup] the duplicate fixture settled' ([string]$sF5D.reason)
    $rpF5D = Get-HFReceiptPath -GoalId $fxF5D.fx.goal -Key $fxF5D.key
    $f5DGood = [IO.File]::ReadAllText($rpF5D, [Text.Encoding]::UTF8)
    # (a) duplicata identica: idempotente e devolve a linhagem ARMAZENADA.
    $sF5Dup = Invoke-HFSettle -Key $fxF5D.key -Authorization $fxF5D.fx.auth -Result $s1cand -Fp $fpF5D
    Assert-HF (([bool]$sF5Dup.ok) -and ([bool]$sF5Dup.duplicate) -and ([bool]$sF5Dup.settled) -and ([string]$sF5Dup.reason -ceq 'settle-duplicate')) '[F5-dup] an identical duplicate on the PROVEN record is idempotent' ([string]$sF5Dup.reason)
    Assert-HF ((([string]$sF5Dup.evidence_id -ceq [string]$sF5D.evidence_id) -and ([string]$sF5Dup.child_session_id -ceq 'ses_hf_child_1') -and ([bool]$sF5Dup.kernel_ok) -and ([bool]$sF5Dup.evidence_created))) '[F5-dup] the duplicate returns the PERSISTED evidence id, child session and kernel verdict' ('ev=' + [string]$sF5Dup.evidence_id + ' child=' + [string]$sF5Dup.child_session_id)
    # (b) evidence_id trocado por OUTRO hash valido (mesmo tipo): a prova
    #     estrita recusa e a duplicata deixa de ser idempotente.
    Assert-HF (Set-HFReceiptField -Path $rpF5D -Field 'evidence_id' -Value ('e' * 32)) '[F5-dup] fixture replaced the stored evidence id with another valid hash' ''
    $f5DupRaw = Get-HFReceiptRaw -GoalId $fxF5D.fx.goal -Key $fxF5D.key
    Assert-HF ((-not [bool](Test-NDSettledHandoffProof -Receipt $f5DupRaw).ok)) '[F5-dup] the strict proof refuses a same-type evidence id swap' ''
    $sF5DupBad = Invoke-HFSettle -Key $fxF5D.key -Authorization $fxF5D.fx.auth -Result $s1cand -Fp $fpF5D
    Assert-HF (((-not [bool]$sF5DupBad.ok) -and (-not [bool]$sF5DupBad.duplicate) -and (-not [bool]$sF5DupBad.settled) -and ([string]$sF5DupBad.reason -ceq 'settle-duplicate-unproven'))) '[F5-dup] a duplicate over the swapped evidence id is NOT idempotent (unproven)' ([string]$sF5DupBad.reason)
    [IO.File]::WriteAllText($rpF5D, $f5DGood, [Text.UTF8Encoding]::new($false))
    $dF5Rev = [long](Get-OrchestrationTask -TaskId $fxF5D.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($dF5Rev -eq 2) '[F5-dup] no duplicate refusal ever rewrote the kernel' ('rev=' + [string]$dF5Rev)
    # (c) com o registro exato de volta, a duplicata e idempotente outra vez.
    $sF5DupOk = Invoke-HFSettle -Key $fxF5D.key -Authorization $fxF5D.fx.auth -Result $s1cand -Fp $fpF5D
    Assert-HF (([bool]$sF5DupOk.ok) -and ([bool]$sF5DupOk.duplicate) -and ([string]$sF5DupOk.reason -ceq 'settle-duplicate') -and ([string]$sF5DupOk.evidence_id -ceq [string]$sF5D.evidence_id)) '[F5-dup] control: the exact record restored, the duplicate is idempotent again with the PERSISTED evidence id' ([string]$sF5DupOk.reason)

    # ---------- F5-legacy: compatibilidade do 'settled' LEGADO ----------
    # Um recibo 'settled' do caminho legado - kernel_ok EXATAMENTE true,
    # executor_calls contabilizado, SEM marcadores de handoff - continua
    # tendo porta propria: a varredura nao exige o material do handoff e a
    # reserva e liberada. A prova estrita do handoff nao derruba esse
    # caminho (schema legado estruturalmente valido segue compativel).
    $fxF5L = New-HFIsolatedFixture -Suffix 'fix5legacy'
    $kF5L = Get-NativeDispatchHash32 'hf-fix5-legacy-ok'
    $kF5L2 = Get-NativeDispatchHash32 'hf-fix5-legacy-second'
    $f5LFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxF5L.task -Key $kF5L -Gen $fxF5L.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $fxF5L.goal -Key $kF5L), ('{"schema_version":1,"idempotency_key":"' + $kF5L + '","phase":"settled","ok":true,"reason":"","task_id":"' + [string]$fxF5L.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxF5L.goal + '","ownership_generation":' + [string]$fxF5L.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $f5LFp + '","reconciled":false,"kernel_ok":true,"executor_calls":1,"worker_result":{"status":"candidate_pass","claimed_evidence":["criterion:0"]},"evidence_created":true,"evidence_id":"' + ('a' * 32) + '","created_at":"' + ([DateTime]::UtcNow.ToString('o')) + '"}'), [Text.UTF8Encoding]::new($false))
    Assert-HF ((-not (Test-NDHandoffSettledMarker -Receipt (Get-HFReceiptRaw -GoalId $fxF5L.goal -Key $kF5L)))) '[F5-legacy] the structurally valid legacy settled receipt carries NO handoff marker' ''
    $pF5L2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF5L.task -Key $kF5L2 -Gen $fxF5L.gen) -Authorization $fxF5L.auth -SessionId 'ses_hf_f5l' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5L2.ok) '[F5-legacy] a second key prepares over the legacy settled receipt' ([string]$pF5L2.reason)
    $cF5L2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5L2 -Authorization $fxF5L.auth -SessionId 'ses_hf_f5l' -MessageId 'msg_hf_f5l' -CallId 'call_hf_f5l' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5L2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5L2.ok) -and ([bool]$cF5L2.claimed)) '[F5-legacy] a structurally valid LEGACY settled receipt (kernel_ok=true, no handoff markers) still RELEASES the reservation' ([string]$cF5L2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F5] no Executor call in any strict-proof scenario' ''

    # ==================================================================
    # PRA-SETTLE-FIX5/FIX6 (fechamento do achado do reviewer): a
    # varredura de reserva tem de validar a integridade SEMANTICA do
    # 'settled' do HANDOFF ANTES de atribuir/ignorar o task_id. Cenario:
    # o registro 'settled' EXATO de uma task tem o task_id TROCADO por
    # OUTRO id VALIDO, com os hashes intactos - a estrutura continua
    # perfeita e apenas o fingerprint RECALCULADO divergiria. Antes da
    # correcao a varredura atribuia o registro a outra task e o IGNORAVA,
    # liberando um SEGUNDO efeito da task original (CLAIM nativo ou
    # Invoke legado). Agora ela recusa fechado, com 0 chamadas de
    # Executor e sem persistir nada; o registro EXATO restaurado volta a
    # liberar.
    # Controles na MESMA raiz (antes de qualquer adulteracao):
    #   (1) um 'settled' de handoff VALIDO de OUTRA task - PROVADO pela
    #       porta estrita - e ignorado para a task alheia (nunca bloqueia
    #       quem nao e dela) e libera a dele;
    #   (2) um 'settled' LEGADO valido (sem marcador algum) continua na
    #       porta propria e libera a reserva - a correcao nao arrasta o
    #       schema legado para a porta do handoff;
    #   (3) um registro HIBRIDO (marcadores de handoff sem a linhagem
    #       completa da liquidacao, mantendo kernel_ok=true) NUNCA e
    #       rebaixado a legado: recusa a varredura, sem liberar nada.
    # ==================================================================
    $receiptDir = New-HFReceiptRoot -Name 'fix5-taskid'
    $fxF5T1 = New-HFSettleFixture -Suffix 'fix5tid-a' -KeyMaterial 'hf-fix5-taskid-a'
    $fpF5T1 = ([string]$fxF5T1.prepare.prepared_fingerprint)
    $sF5T1 = Invoke-HFSettle -Key $fxF5T1.key -Authorization $fxF5T1.fx.auth -Result $s1cand -Fp $fpF5T1
    Assert-HF (([bool]$sF5T1.ok) -and ([bool]$sF5T1.settled) -and (-not [bool]$sF5T1.duplicate)) '[F5-taskid] the reference fixture settled (known settlement)' ([string]$sF5T1.reason)
    $rpF5T1 = Get-HFReceiptPath -GoalId $fxF5T1.fx.goal -Key $fxF5T1.key
    $f5T1Good = [IO.File]::ReadAllText($rpF5T1, [Text.Encoding]::UTF8)
    # (a0) CONTROLE 1 - 'settled' de handoff VALIDO de OUTRA task, na
    #      MESMA raiz: PROVADO pela porta estrita e, so depois, ignorado
    #      para a task alheia (e liberador para a propria).
    $fxF5T2 = New-HFSettleFixture -Suffix 'fix5tid-b' -KeyMaterial 'hf-fix5-taskid-b'
    Assert-HF ([bool]$fxF5T2.claim.ok) '[F5-taskid] control: the fixture of ANOTHER task claimed while a proven settled receipt is in the root' ([string]$fxF5T2.claim.reason)
    $fpF5T2 = ([string]$fxF5T2.prepare.prepared_fingerprint)
    $sF5T2 = Invoke-HFSettle -Key $fxF5T2.key -Authorization $fxF5T2.fx.auth -Result $s1cand -Fp $fpF5T2
    Assert-HF (([bool]$sF5T2.ok) -and ([bool]$sF5T2.settled) -and (-not [bool]$sF5T2.duplicate)) '[F5-taskid] control: the unrelated fixture ALSO settled (valid handoff settlement)' ([string]$sF5T2.reason)
    $f5T2Raw = Get-HFReceiptRaw -GoalId $fxF5T2.fx.goal -Key $fxF5T2.key
    Assert-HF (($null -ne $f5T2Raw) -and ([bool](Test-NDSettledHandoffProof -Receipt $f5T2Raw).ok)) '[F5-taskid] control: the unrelated settlement passes the strict proof (proven)' ''
    $revF5T2 = [long](Get-OrchestrationTask -TaskId $fxF5T2.fx.task -TasksDir $tasksDir).revision
    $kF5T2s = Get-NativeDispatchHash32 'hf-fix5-taskid-b-second'
    $iF5T2s = New-HFIntent -Task $fxF5T2.fx.task -Key $kF5T2s -Gen $fxF5T2.fx.gen -Rev $revF5T2
    $pF5T2s = Invoke-OrchestrationNativeDispatchPrepare -Intent $iF5T2s -Authorization $fxF5T2.fx.auth -SessionId 'ses_hf_f5tidb' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5T2s.ok) '[F5-taskid] control: a second key of the OTHER task prepares' ([string]$pF5T2s.reason)
    $cF5T2s = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5T2s -Authorization $fxF5T2.fx.auth -SessionId 'ses_hf_f5tidb' -MessageId 'msg_hf_f5tidb' -CallId 'call_hf_f5tidb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5T2s.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5T2s.ok) -and ([bool]$cF5T2s.claimed) -and ([int]$cF5T2s.executor_calls -eq 0)) '[F5-taskid] control: a VALID unrelated handoff-settled receipt does NOT block (proven, then ignored) and its OWN task is released' ([string]$cF5T2s.reason)
    # (a1) CONTROLE 2 - 'settled' LEGADO valido na MESMA raiz: sem
    #      marcador algum, porta propria, reserva liberada. A correcao
    #      nao pode empurrar o schema legado para a porta do handoff.
    $fxF5T3 = New-HFIsolatedFixture -Suffix 'fix5tidlegacy'
    $kF5T3 = Get-NativeDispatchHash32 'hf-fix5-taskid-legacy-ok'
    $kF5T3s = Get-NativeDispatchHash32 'hf-fix5-taskid-legacy-second'
    $f5T3Fp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxF5T3.task -Key $kF5T3 -Gen $fxF5T3.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $fxF5T3.goal -Key $kF5T3), ('{"schema_version":1,"idempotency_key":"' + $kF5T3 + '","phase":"settled","ok":true,"reason":"","task_id":"' + [string]$fxF5T3.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxF5T3.goal + '","ownership_generation":' + [string]$fxF5T3.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $f5T3Fp + '","reconciled":false,"kernel_ok":true,"executor_calls":1,"worker_result":{"status":"candidate_pass","claimed_evidence":["criterion:0"]},"evidence_created":true,"evidence_id":"' + ('a' * 32) + '","created_at":"' + ([DateTime]::UtcNow.ToString('o')) + '"}'), [Text.UTF8Encoding]::new($false))
    $f5T3Raw = Get-HFReceiptRaw -GoalId $fxF5T3.goal -Key $kF5T3
    Assert-HF (($null -ne $f5T3Raw) -and (-not (Test-NDHandoffRecordMarkers -Receipt $f5T3Raw))) '[F5-taskid] control: the LEGACY settled receipt carries NO handoff marker (own compatibility path)' ''
    $pF5T3s = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF5T3.task -Key $kF5T3s -Gen $fxF5T3.gen) -Authorization $fxF5T3.auth -SessionId 'ses_hf_f5tidl' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5T3s.ok) '[F5-taskid] control: a second key of the LEGACY task prepares' ([string]$pF5T3s.reason)
    $cF5T3s = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5T3s -Authorization $fxF5T3.auth -SessionId 'ses_hf_f5tidl' -MessageId 'msg_hf_f5tidl' -CallId 'call_hf_f5tidl' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5T3s.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5T3s.ok) -and ([bool]$cF5T3s.claimed) -and ([int]$cF5T3s.executor_calls -eq 0)) '[F5-taskid] control: a valid LEGACY settled receipt still RELEASES the reservation in the same root (never dragged into the handoff gate)' ([string]$cF5T3s.reason)
    # (b) adultera UM campo: task_id -> outro id VALIDO, hashes intactos.
    Assert-HF (Set-HFReceiptField -Path $rpF5T1 -Field 'task_id' -Value ([string]$fxF5T2.fx.task)) '[F5-taskid] fixture mutated the settled task_id to another VALID id (hashes untouched)' ''
    $f5T1Raw = Get-HFReceiptRaw -GoalId $fxF5T1.fx.goal -Key $fxF5T1.key
    Assert-HF (($null -ne $f5T1Raw) -and ([string]$f5T1Raw.phase -ceq 'settled') -and ([string]$f5T1Raw.handoff_state -ceq 'SETTLED')) '[F5-taskid] the tampered record is still a settled handoff on disk (no phase tampering)' ('phase=' + [string]$f5T1Raw.phase)
    $f5T1Tok = Get-NDValueNode -Object $f5T1Raw -Name 'task_id'
    Assert-HF (($null -ne $f5T1Tok) -and ([string]$f5T1Tok.kind -ceq 'string') -and ([string]$f5T1Tok.value -ceq ([string]$fxF5T2.fx.task))) '[F5-taskid] the persisted task_id token is another valid SAME-TYPE string (kernel-accepted id)' ('kind=' + [string]$f5T1Tok.kind + ' value=' + [string]$f5T1Tok.value)
    # (c) as provas do PROPRIO registro recusam: a integridade semantica
    #     RECALCULADA diverge (o fingerprint do Intent cobre a task) e a
    #     prova estrita da liquidacao tambem.
    $f5T1Integ = Test-NDReceiptSemanticIntegrity -Receipt $f5T1Raw -GoalId $fxF5T1.fx.goal -IdempotencyKey $fxF5T1.key
    Assert-HF ((-not [bool](Get-NDValue $f5T1Integ 'ok' $false))) '[F5-taskid] the recalculated semantic integrity REFUSES the same-type task_id swap (hash intact)' ([string](Get-NDValue $f5T1Integ 'reason' ''))
    $f5T1Proof = Test-NDSettledHandoffProof -Receipt $f5T1Raw
    Assert-HF ((-not [bool](Get-NDValue $f5T1Proof 'ok' $false))) '[F5-taskid] the strict settlement proof REFUSES the same-type task_id swap' ([string](Get-NDValue $f5T1Proof 'reason' ''))
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $f5T1Raw) '[F5-taskid] the tampered record still carries handoff markers (never read as legacy)' ''
    # (d) nova chave da task ORIGINAL: PREPARE nao e efeito; o CLAIM e
    #     barrado pela varredura ANTES de qualquer atribuicao de task.
    $revF5T1 = [long](Get-OrchestrationTask -TaskId $fxF5T1.fx.task -TasksDir $tasksDir).revision
    $kF5T1b = Get-NativeDispatchHash32 'hf-fix5-taskid-second'
    $iF5T1b = New-HFIntent -Task $fxF5T1.fx.task -Key $kF5T1b -Gen $fxF5T1.fx.gen -Rev $revF5T1
    $pF5T1b = Invoke-OrchestrationNativeDispatchPrepare -Intent $iF5T1b -Authorization $fxF5T1.fx.auth -SessionId 'ses_hf_f5tid' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5T1b.ok) '[F5-taskid] a second effect on the original task can still be PREPARED (prepare is not an effect)' ([string]$pF5T1b.reason)
    $cF5T1b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5T1b -Authorization $fxF5T1.fx.auth -SessionId 'ses_hf_f5tid' -MessageId 'msg_hf_f5tid' -CallId 'call_hf_f5tid' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5T1b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cF5T1b.ok) -and (-not [bool]$cF5T1b.claimed) -and ((@('claim-task-scan-unreadable', 'claim-task-already-claimed') -ccontains [string]$cF5T1b.reason)) -and ([int]$cF5T1b.executor_calls -eq 0))) '[F5-taskid] the ORIGINAL task stays RESERVED: the scan fails closed on the swapped task_id (no second effect)' ([string]$cF5T1b.reason)
    $kF5T1bRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxF5T1.fx.goal -Key $kF5T1b), [Text.Encoding]::UTF8))
    Assert-HF ([string]$kF5T1bRaw.phase -ceq 'prepared') '[F5-taskid] the denied claim never consumes the prepared receipt' ('phase=' + [string]$kF5T1bRaw.phase)
    $revF5T1b = [long](Get-OrchestrationTask -TaskId $fxF5T1.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revF5T1b -eq $revF5T1) '[F5-taskid] the denied claim wrote nothing in the kernel' ('rev=' + [string]$revF5T1b)
    # (e) Invoke LEGADO com outra chave na MESMA task: mesma recusa, 0
    #     chamadas de Executor, nada persistido.
    $f5T1SpyState = @{ calls = 0 }
    $f5T1Spy = { param($i) $f5T1SpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $kF5T1l = Get-NativeDispatchHash32 'hf-fix5-taskid-legacy'
    $lF5T1 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxF5T1.fx.task -Key $kF5T1l -Gen $fxF5T1.fx.gen -Rev $revF5T1).intent -Executor $f5T1Spy -Authorization $fxF5T1.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$lF5T1.ok) -and ((@('claim-task-scan-unreadable', 'claim-task-already-claimed') -ccontains [string]$lF5T1.reason)) -and ([int]$lF5T1.executor_calls -eq 0) -and ([int]$f5T1SpyState.calls -eq 0))) '[F5-taskid] the legacy Invoke with another key is denied by the SAME scan with 0 executor calls' ([string]$lF5T1.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxF5T1.fx.goal -Key $kF5T1l) -PathType Leaf)) '[F5-taskid] the denied legacy key persisted nothing' ''
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F5-taskid] no Executor call from any operation in the swapped-task_id scenario' ''
    # (f) controle final: restaurado o registro EXATO, a MESMA segunda
    #     chave volta a ser admitida - a reserva libera de novo.
    [IO.File]::WriteAllText($rpF5T1, $f5T1Good, [Text.UTF8Encoding]::new($false))
    $cF5T1b2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5T1b -Authorization $fxF5T1.fx.auth -SessionId 'ses_hf_f5tid' -MessageId 'msg_hf_f5tid' -CallId 'call_hf_f5tid' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5T1b.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5T1b2.ok) -and ([bool]$cF5T1b2.claimed)) '[F5-taskid] control: the EXACT settled receipt restored RELEASES the reservation again' ([string]$cF5T1b2.reason)
    $f5T1Restored = Get-HFReceiptRaw -GoalId $fxF5T1.fx.goal -Key $fxF5T1.key
    Assert-HF ([bool](Test-NDSettledHandoffProof -Receipt $f5T1Restored).ok) '[F5-taskid] control: the restored receipt passes the strict settlement proof again' ''
    # (g) CONTROLE 3 - registro HIBRIDO em raiz e fixture PROPRIOS. A
    #     partir de um 'settled' EXATO, a linhagem INTEIRA da liquidacao
    #     (settle_*/settled_*/handoff_state) e removida. Sobram marcadores
    #     de handoff do preparo/claim (session_id, reference, prepared_*,
    #     claim_*) e o kernel_ok=true do legado. Um registro com ALGUNS
    #     marcadores de handoff NUNCA e rebaixado a legado: a varredura
    #     recusa fechado e nao libera a reserva (a prova estrita exige a
    #     liquidacao completa). A raiz propria garante que a recusa vem
    #     deste registro - e nao de um 'claimed' deixado por outro cenario
    #     da mesma raiz (o que produziria um claim-task-already-claimed
    #     sem qualquer relacao com o hibrido).
    $receiptDir = New-HFReceiptRoot -Name 'fix5-hybrid'
    $fxF5Hb = New-HFSettleFixture -Suffix 'fix5hyb' -KeyMaterial 'hf-fix5-hybrid-1'
    $fpF5Hb = ([string]$fxF5Hb.prepare.prepared_fingerprint)
    $sF5Hb = Invoke-HFSettle -Key $fxF5Hb.key -Authorization $fxF5Hb.fx.auth -Result $s1cand -Fp $fpF5Hb
    Assert-HF (([bool]$sF5Hb.ok) -and ([bool]$sF5Hb.settled) -and (-not [bool]$sF5Hb.duplicate)) '[F5-hybrid] the isolated fixture settled (known settlement)' ([string]$sF5Hb.reason)
    $rpF5Hb = Get-HFReceiptPath -GoalId $fxF5Hb.fx.goal -Key $fxF5Hb.key
    $f5HbGood = [IO.File]::ReadAllText($rpF5Hb, [Text.Encoding]::UTF8)
    $f5HbRaw0 = Get-HFReceiptRaw -GoalId $fxF5Hb.fx.goal -Key $fxF5Hb.key
    Assert-HF (($null -ne $f5HbRaw0) -and ([string]$f5HbRaw0.phase -ceq 'settled') -and (Test-NDHandoffRecordMarkers -Receipt $f5HbRaw0) -and (Test-NDCanonicalReceiptFieldNames -Receipt $f5HbRaw0)) '[F5-hybrid] the reference receipt is a CANONICAL settled handoff receipt' ('phase=' + [string]$f5HbRaw0.phase)
    $f5HybridLineage = @(
        'handoff_state', 'settle_status', 'settle_child_session_id', 'settle_session_id', 'settle_message_id',
        'settle_call_id', 'settle_caller_agent', 'settle_target_agent', 'settled_by', 'settled_generation',
        'settle_claimed_evidence', 'settle_evidence_created', 'settle_evidence_id',
        'settle_attempt_child_session_id', 'settle_attempt_session_id', 'settle_attempt_message_id',
        'settle_attempt_call_id', 'settle_attempt_caller_agent', 'settle_attempt_target_agent',
        'settle_attempt_status', 'settle_attempt_claimed_evidence'
    )
    $f5HybridOk = $true
    foreach ($hl in @($f5HybridLineage)) {
        if (-not (Remove-HFReceiptField -Path $rpF5Hb -Field ([string]$hl))) { $f5HybridOk = $false }
    }
    Assert-HF $f5HybridOk '[F5-hybrid] fixture stripped the whole settlement lineage from the exact receipt' ''
    $f5HybridRaw = Get-HFReceiptRaw -GoalId $fxF5Hb.fx.goal -Key $fxF5Hb.key
    Assert-HF (($null -ne $f5HybridRaw) -and (Test-NDHandoffRecordMarkers -Receipt $f5HybridRaw)) '[F5-hybrid] the hybrid record STILL carries handoff markers (some, not all)' ''
    $f5HybridKernel = Get-NDJsonBoolValue -Object $f5HybridRaw -Name 'kernel_ok'
    Assert-HF (($null -ne $f5HybridKernel) -and ([bool]$f5HybridKernel)) '[F5-hybrid] the hybrid record keeps the legacy-looking kernel_ok=true (the value the legacy gate would release on)' ''
    $f5HybridProof = Test-NDSettledHandoffProof -Receipt $f5HybridRaw
    Assert-HF (((-not [bool](Get-NDValue $f5HybridProof 'ok' $false)) -and ([string](Get-NDValue $f5HybridProof 'reason' '') -ceq 'settled-shape-invalid'))) '[F5-hybrid] the strict proof refuses the hybrid record as INDECIDABLE (settled-shape-invalid, not a legacy-shaped refusal)' ([string](Get-NDValue $f5HybridProof 'reason' ''))
    $f5HybridInteg = Test-NDReceiptSemanticIntegrity -Receipt $f5HybridRaw -GoalId $fxF5Hb.fx.goal -IdempotencyKey $fxF5Hb.key
    Assert-HF ([bool](Get-NDValue $f5HybridInteg 'ok' $false)) '[F5-hybrid] the semantic integrity still holds (only settlement fields were removed - this is not a semantic tamper)' ([string](Get-NDValue $f5HybridInteg 'reason' ''))
    $revF5Hb = [long](Get-OrchestrationTask -TaskId $fxF5Hb.fx.task -TasksDir $tasksDir).revision
    $kF5Hybrid = Get-NativeDispatchHash32 'hf-fix5-hybrid-second'
    $pF5Hybrid = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF5Hb.fx.task -Key $kF5Hybrid -Gen $fxF5Hb.fx.gen -Rev $revF5Hb) -Authorization $fxF5Hb.fx.auth -SessionId 'ses_hf_f5hyb' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF5Hybrid.ok) '[F5-hybrid] a second effect on the hybrid root can still be PREPARED (prepare is not an effect)' ([string]$pF5Hybrid.reason)
    $cF5Hybrid = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5Hybrid -Authorization $fxF5Hb.fx.auth -SessionId 'ses_hf_f5hyb' -MessageId 'msg_hf_f5hyb' -CallId 'call_hf_f5hyb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5Hybrid.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cF5Hybrid.ok) -and (-not [bool]$cF5Hybrid.claimed) -and ([string]$cF5Hybrid.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cF5Hybrid.executor_calls -eq 0))) '[F5-hybrid] the HYBRID record is refused fail-closed with the EXACT scan reason (indecidable, never released as legacy)' ([string]$cF5Hybrid.reason)
    $f5HybridPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxF5Hb.fx.goal -Key $kF5Hybrid), [Text.Encoding]::UTF8))
    Assert-HF ([string]$f5HybridPrepRaw.phase -ceq 'prepared') '[F5-hybrid] the refused hybrid claim never consumes the prepared receipt' ('phase=' + [string]$f5HybridPrepRaw.phase)
    $revF5HbAfter = [long](Get-OrchestrationTask -TaskId $fxF5Hb.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revF5HbAfter -eq $revF5Hb) '[F5-hybrid] the refused claim wrote nothing in the kernel' ('rev=' + [string]$revF5HbAfter)
    # controle: restaurado o registro EXATO, a MESMA raiz volta a admitir o
    # claim - a recusa hibrida era do PROPRIO registro, nao do fixture nem
    # de um recibo concorrente.
    [IO.File]::WriteAllText($rpF5Hb, $f5HbGood, [Text.UTF8Encoding]::new($false))
    $f5HbFinalRaw = Get-HFReceiptRaw -GoalId $fxF5Hb.fx.goal -Key $fxF5Hb.key
    Assert-HF ([bool](Test-NDSettledHandoffProof -Receipt $f5HbFinalRaw).ok) '[F5-hybrid] control: the exact receipt restored passes the strict settlement proof again' ''
    $cF5Hybrid2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF5Hybrid -Authorization $fxF5Hb.fx.auth -SessionId 'ses_hf_f5hyb' -MessageId 'msg_hf_f5hyb' -CallId 'call_hf_f5hyb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF5Hybrid.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF5Hybrid2.ok) -and ([bool]$cF5Hybrid2.claimed) -and ([int]$cF5Hybrid2.executor_calls -eq 0)) '[F5-hybrid] control: the exact receipt restored, the SAME root admits the claim again' ([string]$cF5Hybrid2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F5-hybrid] no Executor call in the hybrid scenario' ''
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F5-taskid] no Executor call anywhere in the task_id-swap group' ''

    # ==================================================================
    # PRA-SETTLE-FIX6A (fechamento dos blockers de review): a deteccao de
    # marcadores decide o SCHEMA do registro e nao pode depender de caixa
    # nem da FORMA do nome. Um registro que carrega marcador de handoff com
    # nome alterado (`SETTLE_CHILD_SESSION_ID`, `HANDOFF_STATE`,
    # `handoff_state ` com espaco em volta, `handoff state` com espaco
    # interno, `settle-status` com o separador trocado) tem de ser
    # classificado como HANDOFF e recusado fail-closed pelas portas de
    # forma/prova - NUNCA lido como legado, que e a porta mais permissiva.
    # Um registro do qual falte EXATAMENTE UM marcador - com todos os outros
    # presentes - tambem continua handoff. TODOS os grupos abaixo tem raiz e
    # fixture PROPRIOS: nenhum recibo 'claimed' ou 'settled' nao-resolvido
    # de outro grupo disputa a reserva, entao uma recusa
    # `claim-task-already-claimed` nao pode vir de caso alheio. Cada grupo
    # ainda prova que, restaurado o registro EXATO (nome canonico), a MESMA
    # raiz volta a admitir um claim.
    # ==================================================================
    # (a) deteccao DIRETA, sem IO: caixa, espaco, forma do nome e conjunto
    #     parcial. Nenhum desses casos pode escapar para o schema legado.
    $mkLegacyOnly = [pscustomobject]@{ schema_version = 1; phase = 'settled'; ok = $true; kernel_ok = $true; evidence_created = $true; evidence_id = ('a' * 32); worker_result = @{ status = 'candidate_pass' }; executor_calls = 1; reconciled = $false }
    Assert-HF (-not (Test-NDHandoffRecordMarkers -Receipt $mkLegacyOnly)) '[F6A-marker] a structurally valid LEGACY receipt (no handoff lineage at all) is still NOT marked' ''
    $mkUpper = [pscustomobject]@{ SETTLE_CHILD_SESSION_ID = 'ses_child' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkUpper) '[F6A-marker] a record whose ONLY handoff field has ALTERED CASE (SETTLE_CHILD_SESSION_ID) is still classified as HANDOFF (never legacy)' ''
    $mkUpperState = [pscustomobject]@{ HANDOFF_STATE = 'SETTLED' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkUpperState) '[F6A-marker] a record whose ONLY handoff field is HANDOFF_STATE (uppercase) is still classified as HANDOFF' ''
    $mkUpperClaim = [pscustomobject]@{ Claim_Session_Id = 'ses' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkUpperClaim) '[F6A-marker] a record whose ONLY handoff field is Claim_Session_Id (mixed case) is still classified as HANDOFF' ''
    $mkTrailing = [pscustomobject]@{ 'handoff_state ' = 'SETTLED' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkTrailing) '[F6A-marker] a marker name with TRAILING whitespace (handoff_state ) is still classified as HANDOFF' ''
    $mkLeading = [pscustomobject]@{ ' settle_status' = 'candidate_pass' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkLeading) '[F6A-marker] a marker name with LEADING whitespace ( settle_status) is still classified as HANDOFF' ''
    $mkInner = [pscustomobject]@{ 'handoff state' = 'SETTLED' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkInner) '[F6A-marker] a marker name with INNER whitespace (handoff state) is still classified as HANDOFF' ''
    $mkHyphen = [pscustomobject]@{ 'settle-status' = 'candidate_pass' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkHyphen) '[F6A-marker] a handoff-shaped name with the separator TAMPERED (settle-status) is still classified as HANDOFF' ''
    $mkClaimOnly = [pscustomobject]@{ claimed_by = 'planner-1' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkClaimOnly) '[F6A-marker] a record whose ONLY handoff field is claimed_by (exclusive claim metadata) is still classified as HANDOFF' ''
    $mkRefOnly = [pscustomobject]@{ reference = ('b' * 32) }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkRefOnly) '[F6A-marker] a record whose ONLY handoff field is reference is still classified as HANDOFF' ''
    $mkPreparedOnly = [pscustomobject]@{ prepared_at = 'now' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkPreparedOnly) '[F6A-marker] a record whose ONLY handoff field is prepared_at is still classified as HANDOFF' ''
    # (b) nome alterado no registro REAL: a varredura recusa fechado e a
    #     raiz propria volta a liberar com o nome canonico restaurado.
    $receiptDir = New-HFReceiptRoot -Name 'fix6a-case'
    $fxCa = New-HFSettleFixture -Suffix 'fix6a-case' -KeyMaterial 'hf-fix6a-case'
    $sCa = Invoke-HFSettle -Key $fxCa.key -Authorization $fxCa.fx.auth -Result $s1cand -Fp ([string]$fxCa.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sCa.ok) -and ([bool]$sCa.settled) -and (-not [bool]$sCa.duplicate)) '[F6A-case] the reference fixture settled (known settlement)' ([string]$sCa.reason)
    $rpCa = Get-HFReceiptPath -GoalId $fxCa.fx.goal -Key $fxCa.key
    $caGood = [IO.File]::ReadAllText($rpCa, [Text.Encoding]::UTF8)
    $caRaw0 = Get-HFReceiptRaw -GoalId $fxCa.fx.goal -Key $fxCa.key
    Assert-HF (($null -ne $caRaw0) -and ([string]$caRaw0.phase -ceq 'settled') -and (Test-NDHandoffRecordMarkers -Receipt $caRaw0) -and (Test-NDCanonicalReceiptFieldNames -Receipt $caRaw0)) '[F6A-case] the reference fixture is a CANONICAL settled handoff receipt' ('phase=' + [string]$caRaw0.phase)
    $caChild = [string]$caRaw0.settle_child_session_id
    Assert-HF ((-not [string]::IsNullOrWhiteSpace($caChild)) -and (Remove-HFReceiptField -Path $rpCa -Field 'settle_child_session_id') -and (Set-HFReceiptField -Path $rpCa -Field 'SETTLE_CHILD_SESSION_ID' -Value $caChild)) '[F6A-case] fixture moved the SAME child session VALUE to an ALTERED-CASE field name (value untouched)' ''
    $caRaw = Get-HFReceiptRaw -GoalId $fxCa.fx.goal -Key $fxCa.key
    Assert-HF (($null -ne $caRaw) -and ([string]$caRaw.phase -ceq 'settled')) '[F6A-case] only the field NAME changed - the phase and every other field are intact' ('phase=' + [string]$caRaw.phase)
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $caRaw) '[F6A-case] the altered-case record is STILL classified as HANDOFF (marker detection is case-insensitive)' ''
    Assert-HF (-not (Test-NDCanonicalReceiptFieldNames -Receipt $caRaw)) '[F6A-case] the altered-case name is NOT canonical (this is not the record the settlement wrote)' ''
    $caScan = Test-NDReceiptScanRecord -Receipt $caRaw -Namespace (Get-NativeDispatchHash32 ([string]$fxCa.fx.goal)) -FileKey $fxCa.key -Phase 'settled'
    Assert-HF (((-not [bool](Get-NDValue $caScan 'ok' $false)) -and ([string](Get-NDValue $caScan 'reason' '') -ceq 'claim-task-scan-unreadable'))) '[F6A-case] the closed structural gate refuses the altered-case marked record with the EXACT reason' ([string](Get-NDValue $caScan 'reason' ''))
    $kCa = Get-NativeDispatchHash32 'hf-fix6a-case-second'
    $revCa = [long](Get-OrchestrationTask -TaskId $fxCa.fx.task -TasksDir $tasksDir).revision
    $pCa = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxCa.fx.task -Key $kCa -Gen $fxCa.fx.gen -Rev $revCa) -Authorization $fxCa.fx.auth -SessionId 'ses_hf_f6acase' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pCa.ok) '[F6A-case] a second effect on the same task can still be PREPARED (prepare is not an effect)' ([string]$pCa.reason)
    $cCa = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCa -Authorization $fxCa.fx.auth -SessionId 'ses_hf_f6acase' -MessageId 'msg_hf_f6acase' -CallId 'call_hf_f6acase' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCa.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cCa.ok) -and (-not [bool]$cCa.claimed) -and ([string]$cCa.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cCa.executor_calls -eq 0))) '[F6A-case] the altered-case record fails the scan closed with the EXACT reason (never released through the legacy gate)' ([string]$cCa.reason)
    $caPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxCa.fx.goal -Key $kCa), [Text.Encoding]::UTF8))
    Assert-HF ([string]$caPrepRaw.phase -ceq 'prepared') '[F6A-case] the refused claim never consumes the prepared receipt' ('phase=' + [string]$caPrepRaw.phase)
    $revCaAfter = [long](Get-OrchestrationTask -TaskId $fxCa.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revCaAfter -eq $revCa) '[F6A-case] the refused claim wrote nothing in the kernel' ('rev=' + [string]$revCaAfter)
    [IO.File]::WriteAllText($rpCa, $caGood, [Text.UTF8Encoding]::new($false))
    $cCa2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCa -Authorization $fxCa.fx.auth -SessionId 'ses_hf_f6acase' -MessageId 'msg_hf_f6acase' -CallId 'call_hf_f6acase' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCa.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cCa2.ok) -and ([bool]$cCa2.claimed) -and ([int]$cCa2.executor_calls -eq 0)) '[F6A-case] control: the canonical name restored, the SAME root admits the claim again' ([string]$cCa2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6A-case] no Executor call in the altered-case scenario' ''
    # (c) EXATAMENTE UM marcador removido, com todos os outros presentes.
    $receiptDir = New-HFReceiptRoot -Name 'fix6a-missing'
    $fxMi = New-HFSettleFixture -Suffix 'fix6a-missing' -KeyMaterial 'hf-fix6a-missing'
    $sMi = Invoke-HFSettle -Key $fxMi.key -Authorization $fxMi.fx.auth -Result $s1cand -Fp ([string]$fxMi.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sMi.ok) -and ([bool]$sMi.settled) -and (-not [bool]$sMi.duplicate)) '[F6A-missing] the reference fixture settled (known settlement)' ([string]$sMi.reason)
    $rpMi = Get-HFReceiptPath -GoalId $fxMi.fx.goal -Key $fxMi.key
    $miGood = [IO.File]::ReadAllText($rpMi, [Text.Encoding]::UTF8)
    Assert-HF (Remove-HFReceiptField -Path $rpMi -Field 'settle_status') '[F6A-missing] fixture removed EXACTLY ONE marker (settle_status), leaving every other handoff marker' ''
    $miRaw = Get-HFReceiptRaw -GoalId $fxMi.fx.goal -Key $fxMi.key
    Assert-HF (($null -ne $miRaw) -and (Test-NDHandoffRecordMarkers -Receipt $miRaw) -and (Test-NDCanonicalReceiptFieldNames -Receipt $miRaw)) '[F6A-missing] with ONE marker gone the record is STILL handoff (the remaining markers keep it out of the legacy gate)' ''
    $miProof = Test-NDSettledHandoffProof -Receipt $miRaw
    Assert-HF (((-not [bool](Get-NDValue $miProof 'ok' $false)) -and ([string](Get-NDValue $miProof 'reason' '') -ceq 'settled-shape-invalid'))) '[F6A-missing] the strict settlement proof refuses the record as INDECIDABLE (settled-shape-invalid)' ([string](Get-NDValue $miProof 'reason' ''))
    $miScan = Test-NDReceiptScanRecord -Receipt $miRaw -Namespace (Get-NativeDispatchHash32 ([string]$fxMi.fx.goal)) -FileKey $fxMi.key -Phase 'settled'
    Assert-HF ([bool](Get-NDValue $miScan 'ok' $false)) '[F6A-missing] the structural gate STILL accepts the record (every remaining name is canonical and the fingerprints hold)' ([string](Get-NDValue $miScan 'reason' ''))
    $kMi = Get-NativeDispatchHash32 'hf-fix6a-missing-second'
    $revMi = [long](Get-OrchestrationTask -TaskId $fxMi.fx.task -TasksDir $tasksDir).revision
    $pMi = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxMi.fx.task -Key $kMi -Gen $fxMi.fx.gen -Rev $revMi) -Authorization $fxMi.fx.auth -SessionId 'ses_hf_f6amiss' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pMi.ok) '[F6A-missing] a second effect on the same task can still be PREPARED (prepare is not an effect)' ([string]$pMi.reason)
    $cMi = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kMi -Authorization $fxMi.fx.auth -SessionId 'ses_hf_f6amiss' -MessageId 'msg_hf_f6amiss' -CallId 'call_hf_f6amiss' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pMi.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cMi.ok) -and (-not [bool]$cMi.claimed) -and ([string]$cMi.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cMi.executor_calls -eq 0))) '[F6A-missing] a partial marker set fails the scan closed with the EXACT reason (indecidable settlement)' ([string]$cMi.reason)
    $miPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxMi.fx.goal -Key $kMi), [Text.Encoding]::UTF8))
    Assert-HF ([string]$miPrepRaw.phase -ceq 'prepared') '[F6A-missing] the refused claim never consumes the prepared receipt' ('phase=' + [string]$miPrepRaw.phase)
    [IO.File]::WriteAllText($rpMi, $miGood, [Text.UTF8Encoding]::new($false))
    $cMi2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kMi -Authorization $fxMi.fx.auth -SessionId 'ses_hf_f6amiss' -MessageId 'msg_hf_f6amiss' -CallId 'call_hf_f6amiss' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pMi.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cMi2.ok) -and ([bool]$cMi2.claimed) -and ([int]$cMi2.executor_calls -eq 0)) '[F6A-missing] control: the complete marker set restored, the SAME root admits the claim again' ([string]$cMi2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6A-missing] no Executor call in the missing-marker scenario' ''
    # (d) CROSS-GOAL: o task_id de um 'settled' PROVADO de um goal e
    #     falsificado para o id de OUTRO goal (hashes intactos). Nenhum dos
    #     dois lados ganha segundo efeito: o original continua reservado
    #     (a integridade semantica recalculada diverge) e o goal ALHEIO
    #     nao pode ler a falsificacao como liquidacao provada sua. Com o
    #     registro EXATO restaurado, os dois voltam a liquidar/claimer.
    $receiptDir = New-HFReceiptRoot -Name 'fix6a-crossgoal'
    $fxXa = New-HFSettleFixture -Suffix 'fix6a-xga' -KeyMaterial 'hf-fix6a-xg-a'
    $sXa = Invoke-HFSettle -Key $fxXa.key -Authorization $fxXa.fx.auth -Result $s1cand -Fp ([string]$fxXa.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sXa.ok) -and ([bool]$sXa.settled) -and (-not [bool]$sXa.duplicate)) '[F6A-cross] the goal-A fixture settled (known settlement)' ([string]$sXa.reason)
    $fxXb = New-HFSettleFixture -Suffix 'fix6a-xgb' -KeyMaterial 'hf-fix6a-xg-b'
    $sXb = Invoke-HFSettle -Key $fxXb.key -Authorization $fxXb.fx.auth -Result $s1cand -Fp ([string]$fxXb.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sXb.ok) -and ([bool]$sXb.settled) -and (-not [bool]$sXb.duplicate)) '[F6A-cross] the goal-B fixture settled (known settlement)' ([string]$sXb.reason)
    $rpXa = Get-HFReceiptPath -GoalId $fxXa.fx.goal -Key $fxXa.key
    $xaGood = [IO.File]::ReadAllText($rpXa, [Text.Encoding]::UTF8)
    $xaRaw0 = Get-HFReceiptRaw -GoalId $fxXa.fx.goal -Key $fxXa.key
    Assert-HF (($null -ne $xaRaw0) -and ([string]$xaRaw0.task_id -ceq ([string]$fxXa.fx.task))) '[F6A-cross] the reference receipt carries the task id of its OWN goal' ('task_id=' + [string]$xaRaw0.task_id)
    Assert-HF (Set-HFReceiptField -Path $rpXa -Field 'task_id' -Value ([string]$fxXb.fx.task)) '[F6A-cross] fixture forged the settled task_id into ANOTHER goal task id (hashes untouched)' ''
    $xaRaw = Get-HFReceiptRaw -GoalId $fxXa.fx.goal -Key $fxXa.key
    Assert-HF (($null -ne $xaRaw) -and (Test-NDHandoffRecordMarkers -Receipt $xaRaw)) '[F6A-cross] the forged receipt still carries handoff markers (never read as legacy)' ''
    $xaInteg = Test-NDReceiptSemanticIntegrity -Receipt $xaRaw -GoalId $fxXa.fx.goal -IdempotencyKey $fxXa.key
    Assert-HF ((-not [bool](Get-NDValue $xaInteg 'ok' $false))) '[F6A-cross] the recalculated semantic integrity REFUSES the forged task_id (the intent fingerprint covers the task)' ([string](Get-NDValue $xaInteg 'reason' ''))
    $revXa = [long](Get-OrchestrationTask -TaskId $fxXa.fx.task -TasksDir $tasksDir).revision
    $revXb = [long](Get-OrchestrationTask -TaskId $fxXb.fx.task -TasksDir $tasksDir).revision
    $kXa = Get-NativeDispatchHash32 'hf-fix6a-xg-a-second'
    $kXb = Get-NativeDispatchHash32 'hf-fix6a-xg-b-second'
    $pXa = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxXa.fx.task -Key $kXa -Gen $fxXa.fx.gen -Rev $revXa) -Authorization $fxXa.fx.auth -SessionId 'ses_hf_f6axga' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pXa.ok) '[F6A-cross] a second effect on the ORIGINAL task can still be PREPARED (prepare is not an effect)' ([string]$pXa.reason)
    $cXa = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kXa -Authorization $fxXa.fx.auth -SessionId 'ses_hf_f6axga' -MessageId 'msg_hf_f6axga' -CallId 'call_hf_f6axga' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pXa.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cXa.ok) -and (-not [bool]$cXa.claimed) -and ([string]$cXa.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cXa.executor_calls -eq 0))) '[F6A-cross] the ORIGINAL task stays RESERVED: the scan fails closed on the forged record' ([string]$cXa.reason)
    $pXb = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxXb.fx.task -Key $kXb -Gen $fxXb.fx.gen -Rev $revXb) -Authorization $fxXb.fx.auth -SessionId 'ses_hf_f6axgb' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pXb.ok) '[F6A-cross] a second effect on the FORGED-ID task can still be PREPARED (prepare is not an effect)' ([string]$pXb.reason)
    $cXb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kXb -Authorization $fxXb.fx.auth -SessionId 'ses_hf_f6axgb' -MessageId 'msg_hf_f6axgb' -CallId 'call_hf_f6axgb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pXb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cXb.ok) -and (-not [bool]$cXb.claimed) -and ([string]$cXb.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cXb.executor_calls -eq 0))) '[F6A-cross] the goal whose id was FORGED also stays RESERVED (the forgery is not a proven settlement of that goal)' ([string]$cXb.reason)
    $xaPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxXa.fx.goal -Key $kXa), [Text.Encoding]::UTF8))
    Assert-HF ([string]$xaPrepRaw.phase -ceq 'prepared') '[F6A-cross] the refused claim never consumes the prepared receipt of the original task' ('phase=' + [string]$xaPrepRaw.phase)
    [IO.File]::WriteAllText($rpXa, $xaGood, [Text.UTF8Encoding]::new($false))
    $cXa2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kXa -Authorization $fxXa.fx.auth -SessionId 'ses_hf_f6axga' -MessageId 'msg_hf_f6axga' -CallId 'call_hf_f6axga' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pXa.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cXa2.ok) -and ([bool]$cXa2.claimed) -and ([int]$cXa2.executor_calls -eq 0)) '[F6A-cross] control: the exact receipt restored, the ORIGINAL goal task is released again' ([string]$cXa2.reason)
    $cXb2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kXb -Authorization $fxXb.fx.auth -SessionId 'ses_hf_f6axgb' -MessageId 'msg_hf_f6axgb' -CallId 'call_hf_f6axgb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pXb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cXb2.ok) -and ([bool]$cXb2.claimed) -and ([int]$cXb2.executor_calls -eq 0)) '[F6A-cross] control: with the forgery gone, the OTHER goal task is released again too' ([string]$cXb2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6A-cross] no Executor call in the cross-goal forgery scenario' ''

    # ==================================================================
    # PRA-SETTLE-FIX6B (fechamento dos achados restantes de review): a
    # classificacao por marcadores e COMPLETA e case-insensitive, e a
    # recusa tem de ser ATRIBUIVEL ao registro sob teste. Aqui:
    #   (a) deteccao DIRETA, sem IO: CADA nome exclusivo do handoff em
    #       caixa alterada (maiuscula/mista) continua HANDOFF, inclusive
    #       um conjunto PARCIAL todo em caixa alterada; um conjunto todo
    #       LEGADO em maiuscula continua LEGADO (nenhum falso positivo);
    #   (b) caixa alterada em VARIOS marcadores do registro REAL, em raiz e
    #       fixture PROPRIOS (nenhum claimed/pending alheio): a porta
    #       estrutural recusa na classe EXATA 'claim-task-scan-unreadable'
    #       para o CLAIM de outra chave E para o Invoke legado, ambos sem
    #       efeito; o registro EXATO restaurado devolve a admissao aos dois;
    #   (c) HIBRIDO com caixa alterada (linhagem da liquidacao REMOVIDA +
    #       marcadores restantes renomeados): continua HANDOFF, prova
    #       estrita INDECIDIVEL, varredura fechada na classe exata; com o
    #       registro EXATO restaurado a MESMA raiz volta a admitir;
    #   (d) CHAVE SEMANTICA DUPLICADA por caixa no texto do registro: o
    #       parse recusa e a varredura falha fechada, sem atribuir task.
    # Nenhum grupo depende de reserva alheia: cada um tem raiz propria.
    # ==================================================================
    # (a) deteccao DIRETA - cada nome exclusivo, em caixa alterada.
    $mkF6BNames = @(
        @{ tag = 'SETTLE_STATUS';               obj = [pscustomobject]@{ SETTLE_STATUS = 'candidate_pass' } }
        @{ tag = 'Settle_Child_Session_Id';     obj = [pscustomobject]@{ Settle_Child_Session_Id = 'ses_child' } }
        @{ tag = 'SETTLE_ATTEMPT_STATUS';       obj = [pscustomobject]@{ SETTLE_ATTEMPT_STATUS = 'candidate_pass' } }
        @{ tag = 'settle_EVIDENCE_ID';          obj = [pscustomobject]@{ settle_EVIDENCE_ID = ('c' * 32) } }
        @{ tag = 'Claim_Call_Id';               obj = [pscustomobject]@{ Claim_Call_Id = 'call' } }
        @{ tag = 'CLAIM_PREPARED_FINGERPRINT';  obj = [pscustomobject]@{ CLAIM_PREPARED_FINGERPRINT = ('a' * 32) } }
        @{ tag = 'CLAIMED_BY';                  obj = [pscustomobject]@{ CLAIMED_BY = 'planner-1' } }
        @{ tag = 'Claimed_Generation';          obj = [pscustomobject]@{ Claimed_Generation = 1 } }
        @{ tag = 'CLAIMED_AT';                  obj = [pscustomobject]@{ CLAIMED_AT = 'now' } }
        @{ tag = 'Prepared_By';                 obj = [pscustomobject]@{ Prepared_By = 'planner-1' } }
        @{ tag = 'PREPARED_GENERATION';         obj = [pscustomobject]@{ PREPARED_GENERATION = 1 } }
        @{ tag = 'Prepared_Fingerprint';        obj = [pscustomobject]@{ Prepared_Fingerprint = ('b' * 32) } }
        @{ tag = 'SESSION_ID';                  obj = [pscustomobject]@{ SESSION_ID = 'ses' } }
        @{ tag = 'REFERENCE';                   obj = [pscustomobject]@{ REFERENCE = ('d' * 32) } }
        @{ tag = 'SETTLED_BY';                  obj = [pscustomobject]@{ SETTLED_BY = 'planner-1' } }
        @{ tag = 'Settled_Generation';          obj = [pscustomobject]@{ Settled_Generation = 1 } }
    )
    foreach ($mk in @($mkF6BNames)) {
        Assert-HF (Test-NDHandoffRecordMarkers -Receipt ([pscustomobject]$mk.obj)) ('[F6B-marker] the handoff-exclusive name ' + [string]$mk.tag + ' in ALTERED CASE is still classified as HANDOFF') ''
    }
    # (a2) conjunto PARCIAL, TODO em caixa alterada (hibrido): marcado.
    $mkF6BHybridUpper = [pscustomobject]@{ schema_version = 1; phase = 'settled'; kernel_ok = $true; HANDOFF_STATE = 'SETTLED'; SETTLE_STATUS = 'candidate_pass' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkF6BHybridUpper) '[F6B-marker] a PARTIAL marker set whose names are ALL in altered case is still classified as HANDOFF' ''
    # (a3) prefixo EXATO como nome (`settle_`, `prepared_`): nao e campo de
    #      escritor algum, e a direcao da duvida e MARCA (nunca legado).
    $mkF6BExactPrefix = [pscustomobject]@{ 'settle_' = 'x' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkF6BExactPrefix) '[F6B-marker] a name that is EXACTLY the handoff prefix (settle_) is marked, never downgraded' ''
    $mkF6BExactPrepared = [pscustomobject]@{ 'prepared_' = 'x' }
    Assert-HF (Test-NDHandoffRecordMarkers -Receipt $mkF6BExactPrepared) '[F6B-marker] a name that is EXACTLY the handoff prefix (prepared_) is marked, never downgraded' ''
    # (a4) controle negativo: conjunto LEGADO, so que em maiuscula, NAO e
    #      marcado - o conjunto continua exato, sem falso positivo.
    $mkF6BLegacyUpper = [pscustomobject]@{ schema_version = 1; PHASE = 'settled'; OK = $true; KERNEL_OK = $true; EVIDENCE_CREATED = $true; EVIDENCE_ID = ('a' * 32); EXECUTOR_CALLS = 1; RECONCILED = $false; WORKER_RESULT = @{ status = 'candidate_pass' }; SETTLED_AT = 'now'; CREATED_AT = 'now'; INTENT_FINGERPRINT = ('e' * 32) }
    Assert-HF (-not (Test-NDHandoffRecordMarkers -Receipt $mkF6BLegacyUpper)) '[F6B-marker] a record whose UPPERCASE names are ALL legacy fields carries NO handoff marker (the set stays exact)' ''

    # (b) caixa alterada em VARIOS marcadores do registro REAL.
    $receiptDir = New-HFReceiptRoot -Name 'fix6b-case'
    $fxCb = New-HFSettleFixture -Suffix 'fix6b-case' -KeyMaterial 'hf-fix6b-case'
    $sCb = Invoke-HFSettle -Key $fxCb.key -Authorization $fxCb.fx.auth -Result $s1cand -Fp ([string]$fxCb.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sCb.ok) -and ([bool]$sCb.settled) -and (-not [bool]$sCb.duplicate)) '[F6B-case] the isolated fixture settled (known settlement)' ([string]$sCb.reason)
    $rpCb = Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $fxCb.key
    $cbGood = [IO.File]::ReadAllText($rpCb, [Text.Encoding]::UTF8)
    $cbRaw0 = Get-HFReceiptRaw -GoalId $fxCb.fx.goal -Key $fxCb.key
    Assert-HF (($null -ne $cbRaw0) -and ([string]$cbRaw0.phase -ceq 'settled') -and (Test-NDHandoffRecordMarkers -Receipt $cbRaw0) -and (Test-NDCanonicalReceiptFieldNames -Receipt $cbRaw0)) '[F6B-case] the reference receipt is a CANONICAL settled handoff receipt' ('phase=' + [string]$cbRaw0.phase)
    # renomeia marcadores preservando os VALORES (so o nome muda).
    $cbRenames = @(
        @{ from = 'handoff_state';           to = 'HANDOFF_STATE' }
        @{ from = 'settle_status';           to = 'Settle_Status' }
        @{ from = 'settle_child_session_id'; to = 'SETTLE_CHILD_SESSION_ID' }
        @{ from = 'settle_attempt_status';   to = 'Settle_Attempt_Status' }
        @{ from = 'settled_by';              to = 'SETTLED_BY' }
        @{ from = 'settled_generation';      to = 'Settled_Generation' }
        @{ from = 'session_id';              to = 'Session_Id' }
        @{ from = 'reference';               to = 'REFERENCE' }
        @{ from = 'prepared_fingerprint';    to = 'Prepared_Fingerprint' }
        @{ from = 'claim_call_id';           to = 'Claim_Call_Id' }
        @{ from = 'claimed_by';              to = 'CLAIMED_BY' }
    )
    $cbRenameOk = $true
    foreach ($rn in @($cbRenames)) {
        $rnVal = Get-NDValue $cbRaw0 ([string]$rn.from) $null
        if (($null -eq $rnVal) -or (-not (Remove-HFReceiptField -Path $rpCb -Field ([string]$rn.from))) -or (-not (Set-HFReceiptField -Path $rpCb -Field ([string]$rn.to) -Value $rnVal))) { $cbRenameOk = $false }
    }
    Assert-HF $cbRenameOk '[F6B-case] fixture renamed handoff markers to ALTERED CASE with every VALUE untouched' ''
    $cbRaw = Get-HFReceiptRaw -GoalId $fxCb.fx.goal -Key $fxCb.key
    Assert-HF (($null -ne $cbRaw) -and ([string]$cbRaw.phase -ceq 'settled') -and (Test-NDHandoffRecordMarkers -Receipt $cbRaw)) '[F6B-case] the ALTERED-CASE record is STILL classified as HANDOFF (marker detection is case-insensitive)' ''
    Assert-HF (($null -ne $cbRaw) -and (-not (Test-NDCanonicalReceiptFieldNames -Receipt $cbRaw))) '[F6B-case] the altered-case names are NOT canonical (this is not the record the settlement wrote)' ''
    $cbScan = Test-NDReceiptScanRecord -Receipt $cbRaw -Namespace (Get-NativeDispatchHash32 ([string]$fxCb.fx.goal)) -FileKey $fxCb.key -Phase 'settled'
    Assert-HF (((-not [bool](Get-NDValue $cbScan 'ok' $false)) -and ([string](Get-NDValue $cbScan 'reason' '') -ceq 'claim-task-scan-unreadable'))) '[F6B-case] the closed structural gate refuses the altered-case marked record with the EXACT reason' ([string](Get-NDValue $cbScan 'reason' ''))
    $revCb = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    $kCb = Get-NativeDispatchHash32 'hf-fix6b-case-second'
    $pCb = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCb -Gen $fxCb.fx.gen -Rev $revCb) -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bcase' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pCb.ok) '[F6B-case] a second effect on the same task can still be PREPARED (prepare is not an effect)' ([string]$pCb.reason)
    $cCb = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bcase' -MessageId 'msg_hf_f6bcase' -CallId 'call_hf_f6bcase' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cCb.ok) -and (-not [bool]$cCb.claimed) -and ([string]$cCb.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cCb.executor_calls -eq 0))) '[F6B-case] the cross-key CLAIM is refused fail-closed with the EXACT scan class (never released as legacy)' ([string]$cCb.reason)
    $cbPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $kCb), [Text.Encoding]::UTF8))
    Assert-HF ([string]$cbPrepRaw.phase -ceq 'prepared') '[F6B-case] the refused claim never consumes the prepared receipt' ('phase=' + [string]$cbPrepRaw.phase)
    $revCbAfter = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revCbAfter -eq $revCb) '[F6B-case] the refused claim wrote nothing in the kernel' ('rev=' + [string]$revCbAfter)
    # Invoke LEGADO com outra chave: MESMA classe de recusa, 0 efeito.
    $cbSpyState = @{ calls = 0 }
    $cbSpy = { param($i) $cbSpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
    $kCbL = Get-NativeDispatchHash32 'hf-fix6b-case-legacy'
    $lCb = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCbL -Gen $fxCb.fx.gen -Rev $revCbAfter).intent -Executor $cbSpy -Authorization $fxCb.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$lCb.ok) -and ([string]$lCb.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lCb.executor_calls -eq 0) -and ([int]$cbSpyState.calls -eq 0))) '[F6B-case] the cross-key legacy Invoke is refused by the SAME scan with 0 executor calls' ([string]$lCb.reason)
    Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $kCbL) -PathType Leaf)) '[F6B-case] the refused legacy key persisted nothing' ''
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6B-case] no Executor call from any operation in the altered-case scenario' ''
    # controle positivo: registro EXATO restaurado devolve a admissao aos
    # DOIS caminhos. Primeiro o Invoke legado (que liquida a falha e AVANCA
    # a revisao da task); depois um NOVO preparo/claim nativo, ja com a
    # revisao viva - os dois provam que a recusa vinha do registro.
    [IO.File]::WriteAllText($rpCb, $cbGood, [Text.UTF8Encoding]::new($false))
    $lCb2 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCbL -Gen $fxCb.fx.gen -Rev $revCbAfter).intent -Executor $cbSpy -Authorization $fxCb.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$lCb2.ok) -and ([int]$lCb2.executor_calls -eq 1) -and ([int]$cbSpyState.calls -eq 1)) '[F6B-case] control: the EXACT record restored, the legacy Invoke is admitted again (the refusal was attributable to the record)' ([string]$lCb2.reason)
    $kCb2 = Get-NativeDispatchHash32 'hf-fix6b-case-control'
    $revCb2 = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    $pCb2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCb2 -Gen $fxCb.fx.gen -Rev $revCb2) -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bcase' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pCb2.ok) '[F6B-case] control: a fresh prepare on the SAME root is admitted with the EXACT record restored' ([string]$pCb2.reason)
    $cCb2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb2 -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bcase' -MessageId 'msg_hf_f6bcase' -CallId 'call_hf_f6bcase' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cCb2.ok) -and ([bool]$cCb2.claimed) -and ([int]$cCb2.executor_calls -eq 0)) '[F6B-case] control: the EXACT record restored, the SAME root admits the claim again' ([string]$cCb2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6B-case] the local legacy spy took the call, never the global one' ''
    # (c) HIBRIDO com caixa alterada, em raiz PROPRIA, reusando o MESMO
    #     fixture e o MESMO registro settled EXATO (ja conhecido): a
    #     linhagem INTEIRA da liquidacao e REMOVIDA e os marcadores
    #     restantes sao RENOMEADOS em caixa alterada. O registro continua
    #     HANDOFF (nunca legado), a prova estrita e INDECIDIVEL e a
    #     varredura recusa fechado na classe exata - com o registro EXATO
    #     restaurado a MESMA raiz volta a admitir.
    $receiptDir = New-HFReceiptRoot -Name 'fix6b-hybrid'
    $kCb3 = Get-NativeDispatchHash32 'hf-fix6b-hybrid-second'
    $revCb3 = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    $pCb3 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCb3 -Gen $fxCb.fx.gen -Rev $revCb3) -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bhyb' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pCb3.ok) '[F6B-hybrid] a second effect on the hybrid root can still be PREPARED (prepare is not an effect)' ([string]$pCb3.reason)
    $rpCb3 = Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $fxCb.key
    Assert-HF (-not (Test-Path -LiteralPath $rpCb3 -PathType Leaf)) '[F6B-hybrid] the isolated root holds ONLY the prepared receipt (no other pending/claimed receipt shares the root)' ''
    [IO.File]::WriteAllText($rpCb3, $cbGood, [Text.UTF8Encoding]::new($false))
    $cbHybLineage = @(
        'handoff_state', 'settle_status', 'settle_child_session_id', 'settle_session_id', 'settle_message_id',
        'settle_call_id', 'settle_caller_agent', 'settle_target_agent', 'settled_by', 'settled_generation',
        'settle_claimed_evidence', 'settle_evidence_created', 'settle_evidence_id',
        'settle_attempt_child_session_id', 'settle_attempt_session_id', 'settle_attempt_message_id',
        'settle_attempt_call_id', 'settle_attempt_caller_agent', 'settle_attempt_target_agent',
        'settle_attempt_status', 'settle_attempt_claimed_evidence'
    )
    $cbHybRenames = @(
        @{ from = 'session_id';           to = 'Session_Id' }
        @{ from = 'reference';            to = 'REFERENCE' }
        @{ from = 'prepared_fingerprint'; to = 'Prepared_Fingerprint' }
        @{ from = 'claim_message_id';     to = 'CLAIM_MESSAGE_ID' }
    )
    $cbHybRaw0 = Get-HFReceiptRaw -GoalId $fxCb.fx.goal -Key $fxCb.key
    $cbHybOk = $true
    foreach ($hl in @($cbHybLineage)) {
        if (-not (Remove-HFReceiptField -Path $rpCb3 -Field ([string]$hl))) { $cbHybOk = $false }
    }
    foreach ($rn in @($cbHybRenames)) {
        $rnVal = Get-NDValue $cbHybRaw0 ([string]$rn.from) $null
        if (($null -eq $rnVal) -or (-not (Remove-HFReceiptField -Path $rpCb3 -Field ([string]$rn.from))) -or (-not (Set-HFReceiptField -Path $rpCb3 -Field ([string]$rn.to) -Value $rnVal))) { $cbHybOk = $false }
    }
    Assert-HF $cbHybOk '[F6B-hybrid] fixture stripped the settlement lineage AND renamed the surviving markers to altered case' ''
    $cbHybRaw = Get-HFReceiptRaw -GoalId $fxCb.fx.goal -Key $fxCb.key
    Assert-HF (($null -ne $cbHybRaw) -and (Test-NDHandoffRecordMarkers -Receipt $cbHybRaw)) '[F6B-hybrid] the hybrid with ALTERED-CASE markers STILL carries handoff markers (never legacy)' ''
    Assert-HF (($null -ne $cbHybRaw) -and (-not (Test-NDCanonicalReceiptFieldNames -Receipt $cbHybRaw))) '[F6B-hybrid] the altered-case names are NOT canonical' ''
    $cbHybKernel = Get-NDJsonBoolValue -Object $cbHybRaw -Name 'kernel_ok'
    Assert-HF (($null -ne $cbHybKernel) -and ([bool]$cbHybKernel)) '[F6B-hybrid] the hybrid keeps the legacy-looking kernel_ok=true (the value the legacy gate would release on)' ''
    $cbHybProof = Test-NDSettledHandoffProof -Receipt $cbHybRaw
    Assert-HF (((-not [bool](Get-NDValue $cbHybProof 'ok' $false)) -and ([string](Get-NDValue $cbHybProof 'reason' '') -ceq 'settled-shape-invalid'))) '[F6B-hybrid] the strict proof refuses the hybrid as INDECIDABLE (settled-shape-invalid)' ([string](Get-NDValue $cbHybProof 'reason' ''))
    $cbHybInteg = Test-NDReceiptSemanticIntegrity -Receipt $cbHybRaw -GoalId $fxCb.fx.goal -IdempotencyKey $fxCb.key
    Assert-HF ([bool](Get-NDValue $cbHybInteg 'ok' $false)) '[F6B-hybrid] the semantic integrity still holds (only names/fields changed - not a semantic tamper)' ([string](Get-NDValue $cbHybInteg 'reason' ''))
    $cbHybScan = Test-NDReceiptScanRecord -Receipt $cbHybRaw -Namespace (Get-NativeDispatchHash32 ([string]$fxCb.fx.goal)) -FileKey $fxCb.key -Phase 'settled'
    Assert-HF (((-not [bool](Get-NDValue $cbHybScan 'ok' $false)) -and ([string](Get-NDValue $cbHybScan 'reason' '') -ceq 'claim-task-scan-unreadable'))) '[F6B-hybrid] the closed structural gate refuses the altered-case hybrid with the EXACT reason' ([string](Get-NDValue $cbHybScan 'reason' ''))
    $cCb3 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb3 -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bhyb' -MessageId 'msg_hf_f6bhyb' -CallId 'call_hf_f6bhyb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cCb3.ok) -and (-not [bool]$cCb3.claimed) -and ([string]$cCb3.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cCb3.executor_calls -eq 0))) '[F6B-hybrid] the HYBRID claim is refused fail-closed with the EXACT scan class (indecidable, never released as legacy)' ([string]$cCb3.reason)
    $cbHybPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $kCb3), [Text.Encoding]::UTF8))
    Assert-HF ([string]$cbHybPrepRaw.phase -ceq 'prepared') '[F6B-hybrid] the refused hybrid claim never consumes the prepared receipt' ('phase=' + [string]$cbHybPrepRaw.phase)
    $revCb3After = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    Assert-HF ($revCb3After -eq $revCb3) '[F6B-hybrid] the refused claim wrote nothing in the kernel' ('rev=' + [string]$revCb3After)
    $kCb3L = Get-NativeDispatchHash32 'hf-fix6b-hybrid-legacy'
    $lCb3 = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCb3L -Gen $fxCb.fx.gen -Rev $revCb3After).intent -Executor $cbSpy -Authorization $fxCb.fx.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$lCb3.ok) -and ([string]$lCb3.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lCb3.executor_calls -eq 0) -and ([int]$cbSpyState.calls -eq 1))) '[F6B-hybrid] the cross-key legacy Invoke is refused by the SAME scan with no new executor call' ([string]$lCb3.reason)
    # controle: registro EXATO restaurado, a MESMA raiz volta a admitir.
    [IO.File]::WriteAllText($rpCb3, $cbGood, [Text.UTF8Encoding]::new($false))
    $cbHybFinalRaw = Get-HFReceiptRaw -GoalId $fxCb.fx.goal -Key $fxCb.key
    Assert-HF (($null -ne $cbHybFinalRaw) -and (Test-NDHandoffRecordMarkers -Receipt $cbHybFinalRaw) -and (Test-NDCanonicalReceiptFieldNames -Receipt $cbHybFinalRaw) -and ([bool](Test-NDSettledHandoffProof -Receipt $cbHybFinalRaw).ok)) '[F6B-hybrid] control: the EXACT record restored is a canonical, proven settled handoff receipt again' ''
    $cCb3b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb3 -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bhyb' -MessageId 'msg_hf_f6bhyb' -CallId 'call_hf_f6bhyb' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb3.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cCb3b.ok) -and ([bool]$cCb3b.claimed) -and ([int]$cCb3b.executor_calls -eq 0)) '[F6B-hybrid] control: the EXACT record restored, the SAME root admits the claim again' ([string]$cCb3b.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6B-hybrid] no Executor call in the altered-case hybrid scenario' ''
    # (d) CHAVE SEMANTICA DUPLICADA POR CAIXA no texto do registro: o
    #     mesmo registro EXATO com uma segunda ocorrencia de `handoff_state`
    #     em outra caixa. O parse do recibo RECUSA (chaves duplicadas), a
    #     varredura falha fechada e nunca chega a atribuir task. Registro
    #     EXATO restaurado, a MESMA raiz volta a admitir.
    $receiptDir = New-HFReceiptRoot -Name 'fix6b-dup'
    $kCb4 = Get-NativeDispatchHash32 'hf-fix6b-dup-second'
    $revCb4 = [long](Get-OrchestrationTask -TaskId $fxCb.fx.task -TasksDir $tasksDir).revision
    $pCb4 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxCb.fx.task -Key $kCb4 -Gen $fxCb.fx.gen -Rev $revCb4) -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bdup' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pCb4.ok) '[F6B-dup] a second effect on the duplicate-key root can still be PREPARED (prepare is not an effect)' ([string]$pCb4.reason)
    $rpCb4 = Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $fxCb.key
    $cbDupOk = $false
    try {
        $cbDupText = $cbGood.Replace('"handoff_state":"SETTLED"', '"handoff_state":"SETTLED","HANDOFF_STATE":"PREPARED"')
        if (($cbDupText -ne $cbGood) -and ($cbDupText.Contains('"HANDOFF_STATE":"PREPARED"'))) {
            [IO.File]::WriteAllText($rpCb4, $cbDupText, [Text.UTF8Encoding]::new($false))
            $cbDupOk = $true
        }
    }
    catch { $cbDupOk = $false }
    Assert-HF $cbDupOk '[F6B-dup] fixture wrote the SAME settled record with a case-duplicated semantic key (handoff_state + HANDOFF_STATE)' ''
    $cbDupParsed = $null
    try { $cbDupParsed = ConvertFrom-Json ([IO.File]::ReadAllText($rpCb4, [Text.Encoding]::UTF8)) } catch { $cbDupParsed = $null }
    Assert-HF ($null -eq $cbDupParsed) '[F6B-dup] the case-duplicated key makes the receipt UNPARSEABLE (fail-closed at parse, never half-read)' ''
    $cCb4 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb4 -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bdup' -MessageId 'msg_hf_f6bdup' -CallId 'call_hf_f6bdup' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb4.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (((-not [bool]$cCb4.ok) -and (-not [bool]$cCb4.claimed) -and ([string]$cCb4.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cCb4.executor_calls -eq 0))) '[F6B-dup] the duplicate-key record fails the scan closed with the EXACT reason (unattributable, never half-read)' ([string]$cCb4.reason)
    $cbDupPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxCb.fx.goal -Key $kCb4), [Text.Encoding]::UTF8))
    Assert-HF ([string]$cbDupPrepRaw.phase -ceq 'prepared') '[F6B-dup] the refused claim never consumes the prepared receipt' ('phase=' + [string]$cbDupPrepRaw.phase)
    [IO.File]::WriteAllText($rpCb4, $cbGood, [Text.UTF8Encoding]::new($false))
    $cCb4b = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kCb4 -Authorization $fxCb.fx.auth -SessionId 'ses_hf_f6bdup' -MessageId 'msg_hf_f6bdup' -CallId 'call_hf_f6bdup' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pCb4.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cCb4b.ok) -and ([bool]$cCb4b.claimed) -and ([int]$cCb4b.executor_calls -eq 0)) '[F6B-dup] control: the EXACT record restored, the SAME root admits the claim again' ([string]$cCb4b.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6B-dup] no Executor call in the duplicate-key scenario' ''

    # ==================================================================
    # PRA-SETTLE-FIX6C (fechamento dos achados restantes de review): o
    # conjunto de marcadores omitia nomes EXATOS, exclusivos do handoff,
    # que nao casam com nenhum dos quatro prefixos - `base_revision`,
    # `prompt_hash`, `scope`, `acceptance_criteria`,
    # `external_idempotency_proof` e `prepared_fingerprint`. Confirmado
    # campo a campo contra os escritores REAIS de recibo: os TRES
    # escritores LEGADOS ('pending', 'settled' e a recusa PRE-efeito do
    # pos-lock fencing) nao gravam NENHUM desses nomes; o unico escritor
    # deles e o PREPARE do handoff (claim/settle preservam os campos do
    # preparo). Sem esses nomes no conjunto, um 'settled' em FORMA legada
    # carregando APENAS UM deles como marcador sobrevivente era lido como
    # legado e, com o task_id trocado por outro id VALIDO (hashes
    # intactos), atribuido a outra task e IGNORADO pela varredura de
    # exclusao - liberando o segundo efeito da task original.
    #   (a) deteccao DIRETA, sem IO: cada nome omitido, sozinho num
    #       registro em FORMA legada, MARCA o registro (e a versao em caixa
    #       alterada tambem marca, mas nao e canonica - quem recusa nesse
    #       caso e a porta de caixa, nunca a porta legada); um registro
    #       legado sem marcador NAO marca (sem falso positivo);
    #   (b) cenario REAL, raiz e fixture PROPRIOS, para CADA nome: o
    #       registro e um 'settled' em forma legada + o nome como UNICO
    #       marcador sobrevivente + task_id trocado por outro id VALIDO
    #       (hashes intactos). A porta estrutural da varredura recusa
    #       fechado ('claim-task-scan-unreadable') ANTES de qualquer
    #       atribuicao de task, e o CLAIM de outra chave da task ORIGINAL
    #       e o Invoke legado de outra chave sao ambos negados, sem efeito;
    #   (c) CONTROLES na MESMA raiz: um recibo legado de verdade (sem
    #       marcador algum) segue liberando a reserva e um handoff
    #       'settled' PROVADO e valido tambem - a correcao nao empurra o
    #       schema legado para a porta do handoff nem bloqueia liquidacao
    #       conhecida.
    # ==================================================================
    # (a) deteccao DIRETA: conjunto legado de referencia, sem marcador.
    $f6cLegacyHash = [ordered]@{
        schema_version = 1; phase = 'settled'; ok = $true; reason = ''
        task_id = 'hf-task-1'; agent = 'coder'; owner = 'planner-1'
        ownership_generation = 1; task_expected_revision = 1
        intent_fingerprint = ('e' * 32); reconciled = $false
        kernel_ok = $true; kernel_reason = ''; executor_calls = 1
        evidence_created = $true; evidence_id = ('a' * 32)
        worker_result = @{ status = 'candidate_pass' }
        settled_at = '2026-01-01T00:00:00.0000000Z'
    }
    Assert-HF (-not (Test-NDHandoffRecordMarkers -Receipt ([pscustomobject]$f6cLegacyHash))) '[F6C-marker] a structurally valid LEGACY settled receipt (no handoff marker at all) is still NOT marked' ''
    $f6cSoleNames = @(
        @{ tag = 'base_revision';              value = 'rev-a' }
        @{ tag = 'prompt_hash';                value = ('a' * 32) }
        @{ tag = 'scope';                      value = @('src/a.ps1') }
        @{ tag = 'acceptance_criteria';        value = @('criterion:0') }
        @{ tag = 'external_idempotency_proof'; value = 'proof-hf-fix6c' }
        @{ tag = 'prepared_fingerprint';       value = ('b' * 32) }
    )
    foreach ($sn in @($f6cSoleNames)) {
        $snTag = [string]$sn.tag
        $snClone = [ordered]@{}
        foreach ($sk in @($f6cLegacyHash.Keys)) { $snClone[$sk] = $f6cLegacyHash[$sk] }
        $snClone[$snTag] = $sn.value
        Assert-HF (Test-NDHandoffRecordMarkers -Receipt ([pscustomobject]$snClone)) ('[F6C-marker] the handoff-exclusive name ' + $snTag + ' as the SOLE surviving marker in a legacy-shaped record is classified as HANDOFF (never legacy)') ''
        $snUpper = ([string]$snTag).ToUpperInvariant()
        $snCloneU = [ordered]@{}
        foreach ($sk in @($f6cLegacyHash.Keys)) { $snCloneU[$sk] = $f6cLegacyHash[$sk] }
        $snCloneU[$snUpper] = $sn.value
        Assert-HF (Test-NDHandoffRecordMarkers -Receipt ([pscustomobject]$snCloneU)) ('[F6C-marker] the same name in ALTERED CASE (' + $snUpper + ') is still classified as HANDOFF (any surviving marker means handoff)') ''
        Assert-HF (-not (Test-NDCanonicalReceiptFieldNames -Receipt ([pscustomobject]$snCloneU))) ('[F6C-marker] the altered-case name is NOT canonical - the CASE gate rejects it, never the legacy gate') ''
    }
    # (b) cenario REAL: cada nome como UNICO marcador sobrevivente num
    #     'settled' em forma legada, com task_id trocado por outro id
    #     VALIDO e hashes intactos. Raiz e fixture proprios: so existe o
    #     registro fabricado de CADA iteracao (removido ao final dela) e os
    #     'prepared' das chaves de claim - nenhum 'claimed'/'pending'
    #     alheio disputa a reserva, entao a recusa exata vem do registro
    #     fabricado.
    $receiptDir = New-HFReceiptRoot -Name 'fix6c-sole'
    $fxF6c = New-HFIsolatedFixture -Suffix 'fix6c-sole'
    $f6cOtherTask = 'hf-task-1'
    Assert-HF (([string]$f6cOtherTask -cne [string]$fxF6c.task) -and (Test-NDTaskId $f6cOtherTask)) '[F6C-sole] the swap target is a DIFFERENT, kernel-VALID task id' ('target=' + [string]$f6cOtherTask)
    foreach ($sn in @($f6cSoleNames)) {
        $snTag = [string]$sn.tag
        $kSole = Get-NativeDispatchHash32 ('hf-fix6c-sole-' + $snTag)
        $soleFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxF6c.task -Key $kSole -Gen $fxF6c.gen).intent
        Assert-HF (($soleFp -cmatch '^[a-f0-9]{32}$')) ('[F6C-sole/' + $snTag + '] the kept hash is a 32-hex intent fingerprint of the ORIGINAL task (hashes intact)') ('fp=' + [string]$soleFp)
        # valor JSON do campo exclusivo: string ou array JSON de strings.
        if ($sn.value -is [array]) {
            $snParts = @()
            foreach ($si in @($sn.value)) { $snParts += ('"' + [string]$si + '"') }
            $snValJson = ('[' + ($snParts -join ',') + ']')
        }
        else { $snValJson = ('"' + [string]$sn.value + '"') }
        $soleJson = ('{"schema_version":1,"idempotency_key":"' + $kSole + '","phase":"settled","ok":true,"reason":"","task_id":"' + $f6cOtherTask + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxF6c.goal + '","ownership_generation":' + [string]$fxF6c.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $soleFp + '","reconciled":false,"kernel_ok":true,"kernel_reason":"","executor_calls":1,"worker_result":{"status":"candidate_pass","claimed_evidence":["criterion:0"]},"evidence_created":true,"evidence_id":"' + ('a' * 32) + '","settled_at":"' + ([DateTime]::UtcNow.ToString('o')) + '","' + $snTag + '":' + $snValJson + '}')
        $solePath = Get-HFReceiptPath -GoalId $fxF6c.goal -Key $kSole
        [IO.File]::WriteAllText($solePath, $soleJson, [Text.UTF8Encoding]::new($false))
        $soleRaw = Get-HFReceiptRaw -GoalId $fxF6c.goal -Key $kSole
        Assert-HF (($null -ne $soleRaw) -and ([string]$soleRaw.phase -ceq 'settled') -and ([string]$soleRaw.task_id -ceq $f6cOtherTask)) ('[F6C-sole/' + $snTag + '] the fixture is a settled receipt in LEGACY shape with the task_id swapped to another VALID id') ('phase=' + [string]$soleRaw.phase)
        Assert-HF (Test-NDHandoffRecordMarkers -Receipt $soleRaw) ('[F6C-sole/' + $snTag + '] the record with the SOLE surviving marker is classified as HANDOFF (never legacy)') ''
        Assert-HF (Test-NDCanonicalReceiptFieldNames -Receipt $soleRaw) ('[F6C-sole/' + $snTag + '] the sole marker name is canonical (the case gate is not the reason for any refusal here)') ''
        # a porta estrutural da varredura recusa fechado ANTES de atribuir task.
        $soleScan = Test-NDReceiptScanRecord -Receipt $soleRaw -Namespace (Get-NativeDispatchHash32 ([string]$fxF6c.goal)) -FileKey $kSole -Phase 'settled'
        Assert-HF (((-not [bool](Get-NDValue $soleScan 'ok' $false)) -and ([string](Get-NDValue $soleScan 'reason' '') -ceq 'claim-task-scan-unreadable'))) ('[F6C-sole/' + $snTag + '] the structural gate fails closed on the marked record BEFORE any task attribution (exact reason)') ([string](Get-NDValue $soleScan 'reason' ''))
        # CLAIM de outra chave da task ORIGINAL: negado, sem efeito.
        $revF6c = [long](Get-OrchestrationTask -TaskId $fxF6c.task -TasksDir $tasksDir).revision
        $kClaim = Get-NativeDispatchHash32 ('hf-fix6c-sole-' + $snTag + '-claim')
        $pClaim = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF6c.task -Key $kClaim -Gen $fxF6c.gen -Rev $revF6c) -Authorization $fxF6c.auth -SessionId ('ses_hf_f6c_' + $snTag) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pClaim.ok) ('[F6C-sole/' + $snTag + '] a second effect on the original task can still be PREPARED (prepare is not an effect)') ([string]$pClaim.reason)
        $cClaim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kClaim -Authorization $fxF6c.auth -SessionId ('ses_hf_f6c_' + $snTag) -MessageId ('msg_hf_f6c_' + $snTag) -CallId ('call_hf_f6c_' + $snTag) -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pClaim.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$cClaim.ok) -and (-not [bool]$cClaim.claimed) -and ([string]$cClaim.reason -ceq 'claim-task-scan-unreadable') -and ([int]$cClaim.executor_calls -eq 0))) ('[F6C-sole/' + $snTag + '] the ORIGINAL task stays RESERVED: the cross-key CLAIM is denied fail-closed with the EXACT scan class (no second effect)') ([string]$cClaim.reason)
        $claimPrepRaw = ConvertFrom-Json ([IO.File]::ReadAllText((Get-HFReceiptPath -GoalId $fxF6c.goal -Key $kClaim), [Text.Encoding]::UTF8))
        Assert-HF ([string]$claimPrepRaw.phase -ceq 'prepared') ('[F6C-sole/' + $snTag + '] the denied claim never consumes the prepared receipt') ('phase=' + [string]$claimPrepRaw.phase)
        $revF6cAfter = [long](Get-OrchestrationTask -TaskId $fxF6c.task -TasksDir $tasksDir).revision
        Assert-HF ($revF6cAfter -eq $revF6c) ('[F6C-sole/' + $snTag + '] the denied claim wrote nothing in the kernel') ('rev=' + [string]$revF6cAfter)
        # Invoke LEGADO com outra chave: MESMA recusa, 0 chamadas de Executor.
        $f6cSpyState = @{ calls = 0 }
        $f6cSpy = { param($i) $f6cSpyState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $kLegacy = Get-NativeDispatchHash32 ('hf-fix6c-sole-' + $snTag + '-legacy')
        $lClaim = Invoke-OrchestrationNativeDispatch -Intent (New-HFIntent -Task $fxF6c.task -Key $kLegacy -Gen $fxF6c.gen -Rev $revF6c).intent -Executor $f6cSpy -Authorization $fxF6c.auth -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (((-not [bool]$lClaim.ok) -and ([string]$lClaim.reason -ceq 'claim-task-scan-unreadable') -and ([int]$lClaim.executor_calls -eq 0) -and ([int]$f6cSpyState.calls -eq 0))) ('[F6C-sole/' + $snTag + '] the cross-key legacy Invoke is denied by the SAME scan with 0 executor calls') ([string]$lClaim.reason)
        Assert-HF (-not (Test-Path -LiteralPath (Get-HFReceiptPath -GoalId $fxF6c.goal -Key $kLegacy) -PathType Leaf)) ('[F6C-sole/' + $snTag + '] the denied legacy key persisted nothing') ''
        Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) ('[F6C-sole/' + $snTag + '] no Executor call from any operation in the sole-marker scenario') ''
        # remove o registro fabricado: a proxima iteracao comeca limpa.
        [IO.File]::Delete($solePath)
    }
    # (c1) CONTROLE 1 - recibo legado de VERDADE (sem marcador algum) na
    #      MESMA raiz: porta propria, reserva liberada. A correcao nao pode
    #      empurrar o schema legado para a porta do handoff.
    $kLg = Get-NativeDispatchHash32 'hf-fix6c-legacy-ok'
    $lgFp = Get-NDIntentFingerprint -Intent (New-HFIntent -Task $fxF6c.task -Key $kLg -Gen $fxF6c.gen).intent
    [IO.File]::WriteAllText((Get-HFReceiptPath -GoalId $fxF6c.goal -Key $kLg), ('{"schema_version":1,"idempotency_key":"' + $kLg + '","phase":"settled","ok":true,"reason":"","task_id":"' + [string]$fxF6c.task + '","agent":"coder","owner":"planner-1","goal_id":"' + [string]$fxF6c.goal + '","ownership_generation":' + [string]$fxF6c.gen + ',"task_expected_revision":1,"intent_fingerprint":"' + $lgFp + '","reconciled":false,"kernel_ok":true,"kernel_reason":"","executor_calls":1,"worker_result":{"status":"candidate_pass","claimed_evidence":["criterion:0"]},"evidence_created":true,"evidence_id":"' + ('a' * 32) + '","settled_at":"' + ([DateTime]::UtcNow.ToString('o')) + '"}'), [Text.UTF8Encoding]::new($false))
    $lgRaw = Get-HFReceiptRaw -GoalId $fxF6c.goal -Key $kLg
    Assert-HF (($null -ne $lgRaw) -and ([string]$lgRaw.phase -ceq 'settled') -and (-not (Test-NDHandoffRecordMarkers -Receipt $lgRaw))) '[F6C-control] a genuinely LEGACY settled receipt (no marker at all) is NOT marked (own compatibility path)' ''
    $kLg2 = Get-NativeDispatchHash32 'hf-fix6c-legacy-ok-second'
    $revLg = [long](Get-OrchestrationTask -TaskId $fxF6c.task -TasksDir $tasksDir).revision
    $pLg = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF6c.task -Key $kLg2 -Gen $fxF6c.gen -Rev $revLg) -Authorization $fxF6c.auth -SessionId 'ses_hf_f6clg' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pLg.ok) '[F6C-control] a second key of the LEGACY task prepares' ([string]$pLg.reason)
    $cLg = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kLg2 -Authorization $fxF6c.auth -SessionId 'ses_hf_f6clg' -MessageId 'msg_hf_f6clg' -CallId 'call_hf_f6clg' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pLg.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cLg.ok) -and ([bool]$cLg.claimed) -and ([int]$cLg.executor_calls -eq 0)) '[F6C-control] a genuinely legacy settled receipt still RELEASES the reservation in the same root (never dragged into the handoff gate)' ([string]$cLg.reason)
    # (c2) CONTROLE 2 - handoff 'settled' PROVADO e valido de OUTRO
    #      fixture: liquidacao conhecida libera a propria task e nao
    #      bloqueia as demais.
    $fxF6cOk = New-HFSettleFixture -Suffix 'fix6c-ok' -KeyMaterial 'hf-fix6c-ok-1'
    $sF6cOk = Invoke-HFSettle -Key $fxF6cOk.key -Authorization $fxF6cOk.fx.auth -Result $s1cand -Fp ([string]$fxF6cOk.prepare.prepared_fingerprint)
    Assert-HF (([bool]$sF6cOk.ok) -and ([bool]$sF6cOk.settled) -and (-not [bool]$sF6cOk.duplicate)) '[F6C-control] the unrelated fixture settled (known settlement)' ([string]$sF6cOk.reason)
    $f6cOkRaw = Get-HFReceiptRaw -GoalId $fxF6cOk.fx.goal -Key $fxF6cOk.key
    Assert-HF (($null -ne $f6cOkRaw) -and (Test-NDHandoffRecordMarkers -Receipt $f6cOkRaw) -and (Test-NDCanonicalReceiptFieldNames -Receipt $f6cOkRaw) -and ([bool](Test-NDSettledHandoffProof -Receipt $f6cOkRaw).ok)) '[F6C-control] the unrelated settlement is a CANONICAL, PROVEN settled handoff receipt' ''
    $kF6cOk2 = Get-NativeDispatchHash32 'hf-fix6c-ok-second'
    $revF6cOk = [long](Get-OrchestrationTask -TaskId $fxF6cOk.fx.task -TasksDir $tasksDir).revision
    $pF6cOk2 = Invoke-OrchestrationNativeDispatchPrepare -Intent (New-HFIntent -Task $fxF6cOk.fx.task -Key $kF6cOk2 -Gen $fxF6cOk.fx.gen -Rev $revF6cOk) -Authorization $fxF6cOk.fx.auth -SessionId 'ses_hf_f6cok' -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF ([bool]$pF6cOk2.ok) '[F6C-control] a second key of the unrelated task prepares' ([string]$pF6cOk2.reason)
    $cF6cOk2 = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $kF6cOk2 -Authorization $fxF6cOk.fx.auth -SessionId 'ses_hf_f6cok' -MessageId 'msg_hf_f6cok' -CallId 'call_hf_f6cok' -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pF6cOk2.prepared_fingerprint) -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
    Assert-HF (([bool]$cF6cOk2.ok) -and ([bool]$cF6cOk2.claimed) -and ([int]$cF6cOk2.executor_calls -eq 0)) '[F6C-control] a VALID unrelated handoff-settled receipt does NOT block (proven, then released)' ([string]$cF6cOk2.reason)
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[F6C] no Executor call anywhere in the omitted-exclusive-names group' ''

    # restaura o escritor de kernel mockado antes das checagens globais.
    Restore-HFKernelWriter

    # o escritor real e restaurado antes das checagens globais.
    Restore-HFReceiptWriter
    $hfRestoredWriter = Get-Item -Path ('function:' + 'Write-NDReceipt')
    Assert-HF ((($null -ne $hfRestoredWriter) -and ($null -ne $hfRestoredWriter.ScriptBlock) -and ($hfRestoredWriter.ScriptBlock -ceq $script:hfOrigWriteReceipt))) '[G] the ORIGINAL Write-NDReceipt is restored after the writer-fault scenarios' 'not restored'

    # =================================================================
    # G1 trusted-runtime closure (ADDITIVO): provenance strict (A),
    # admission lifecycle + decisao sem host (B) e avanco causal (D).
    #
    # Nada aqui altera o comportamento default: os cenarios sem
    # -StrictProvenance / -EmitAdmission provam isso explicitamente
    # (A6-control, B8-control), e os escritores mockados ja foram
    # restaurados acima, portanto estas escritas sao REAIS.
    # =================================================================
    $g1Root = New-HFReceiptRoot -Name 'g1'

    # ---------- fixtures: claim claimed em raiz propria ----------
    function New-G1PrepareFixture {
        param([string]$Suffix, [string]$KeyMaterial)
        $fx = New-HFIsolatedFixture -Suffix $Suffix
        $k = Get-NativeDispatchHash32 $KeyMaterial
        $i = New-HFIntent -Task $fx.task -Key $k -Gen $fx.gen
        Assert-HF ([bool]$i.ok) ('[G1] intent built ' + $Suffix) ([string]$i.reason)
        $p = Invoke-OrchestrationNativeDispatchPrepare -Intent $i -Authorization $fx.auth -SessionId $session -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$p.ok) ('[G1] prepared ' + $Suffix) ([string]$p.reason)
        return [pscustomobject]@{ fx = $fx; key = $k; intent = $i; prepare = $p }
    }

    function Invoke-G1Claim {
        param($Fx, [switch]$EmitAdmission, [int]$Ttl = 3600, [string]$Model = '', [string]$Provider = '', $Auth = $null)
        $useAuth = $Auth
        if ($null -eq $useAuth) { $useAuth = $Fx.fx.auth }
        return (Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $Fx.key -Authorization $useAuth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$Fx.prepare.prepared_fingerprint) -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EmitAdmission:$EmitAdmission -AdmissionTtlSeconds $Ttl -AdmissionModel $Model -AdmissionProvider $Provider)
    }

    function Invoke-G1Settle {
        param($Fx, $Result, $Proof = $null, [switch]$Strict, [string]$ChildSession = 'ses_g1_child_1', [switch]$EmitAdmission)
        return (Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $Fx.key -Authorization $Fx.fx.auth -ChildSessionId $ChildSession -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$Fx.prepare.prepared_fingerprint) -Reference ([string]$Fx.prepare.reference) -Result $Result -ReceiptDir $g1Root -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath -ProvenanceProof $Proof -StrictProvenance:$Strict -EmitAdmission:$EmitAdmission)
    }

    function New-G1Proof {
        param(
            [string]$Child = 'ses_g1_child_1',
            [string]$Parent = $session,
            [string]$CallId = $call,
            [string]$KeyMaterial = '',
            [string]$Source = 'plugin-session-get',
            [string[]]$Sources = @(),
            [string[]]$Refs = @()
        )
        return [pscustomobject]@{
            source = $Source
            sources = [string[]]$Sources
            child_session_id = $Child
            parent_session_id = $Parent
            call_id = $CallId
            idempotency_key = $KeyMaterial
            claimed_evidence = [string[]]$Refs
        }
    }

    function Get-G1Admission {
        param([string]$GoalId, [string]$Key)
        $st = Get-NDAdmissionDir -RootDir $g1Root -GoalId $GoalId
        if (-not [bool]$st.ok) { return $null }
        return (Read-NDAdmissionRecord -AdmissionDir ([string]$st.dir) -Key $Key)
    }

    # Leitura crua do recibo NA RAIZ PROPRIA dos cenarios G1 (o helper
    # global le a raiz 'settle', que nao e esta).
    function Get-G1ReceiptRaw {
        param([string]$GoalId, [string]$Key)
        $sub = Get-NDGoalReceiptDir -RootDir $g1Root -GoalId $GoalId
        if ([string]::IsNullOrWhiteSpace($sub)) { return $null }
        $p = Join-Path $sub ($Key + '.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    $g1Cand = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0', 'criterion:1') }
    $g1Child = 'ses_g1_child_1'

    # ---------- A1: strict sem proof recusa ANTES de qualquer escrita ----------
    $fxA1 = New-G1PrepareFixture -Suffix 'g1a1' -KeyMaterial 'g1-a1-1'
    $cA1 = Invoke-G1Claim -Fx $fxA1
    Assert-HF (([bool]$cA1.ok) -and ([bool]$cA1.claimed) -and ([int]$cA1.executor_calls -eq 0)) '[A1] the claim committed without any admission/provenance opt-in (default unchanged)' ([string]$cA1.reason)
    $evBeforeA1 = @(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count
    $sA1 = Invoke-G1Settle -Fx $fxA1 -Result $g1Cand -Strict
    Assert-HF ((-not [bool]$sA1.ok) -and (-not [bool]$sA1.settled) -and ([string]$sA1.reason -ceq 'settle-provenance-unproven') -and ([int]$sA1.executor_calls -eq 0)) '[A1] strict without proof refuses the settlement before evidence/kernel' ([string]$sA1.reason)
    $rawA1 = Get-G1ReceiptRaw -GoalId $fxA1.fx.goal -Key $fxA1.key
    Assert-HF (($null -ne $rawA1) -and ([string]$rawA1.phase -ceq 'claimed')) '[A1] the receipt stays claimed with the task reservation held' ''
    Assert-HF (@(Get-ChildItem -LiteralPath $evDir -Filter '*.json' -File).Count -eq $evBeforeA1) '[A1] no evidence line was created by the refused strict settle' ''

    # ---------- A2: child inexistente (proof declara outro filho) ----------
    $fxA2 = New-G1PrepareFixture -Suffix 'g1a2' -KeyMaterial 'g1-a2-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA2).ok) '[A2] claimed' ''
    $pA2 = New-G1Proof -Child 'ses_g1_never_existed' -KeyMaterial $fxA2.key -Refs @('criterion:0', 'criterion:1')
    $sA2 = Invoke-G1Settle -Fx $fxA2 -Result $g1Cand -Proof $pA2 -Strict
    Assert-HF ((-not [bool]$sA2.ok) -and ([string]$sA2.reason -ceq 'settle-provenance-unproven')) '[A2] a nonexistent child session is refused in strict mode' ([string]$sA2.reason)

    # ---------- A3: parent incorreto ----------
    $fxA3 = New-G1PrepareFixture -Suffix 'g1a3' -KeyMaterial 'g1-a3-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA3).ok) '[A3] claimed' ''
    $pA3 = New-G1Proof -Parent 'ses_hf_some_other_session' -KeyMaterial $fxA3.key -Refs @('criterion:0', 'criterion:1')
    $sA3 = Invoke-G1Settle -Fx $fxA3 -Result $g1Cand -Proof $pA3 -Strict
    Assert-HF ((-not [bool]$sA3.ok) -and ([string]$sA3.reason -ceq 'settle-provenance-unproven')) '[A3] a wrong parent session is refused' ([string]$sA3.reason)

    # ---------- A4: chamada inexistente ----------
    $fxA4 = New-G1PrepareFixture -Suffix 'g1a4' -KeyMaterial 'g1-a4-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA4).ok) '[A4] claimed' ''
    $pA4 = New-G1Proof -CallId 'call_never_made' -KeyMaterial $fxA4.key -Refs @('criterion:0', 'criterion:1')
    $sA4 = Invoke-G1Settle -Fx $fxA4 -Result $g1Cand -Proof $pA4 -Strict
    Assert-HF ((-not [bool]$sA4.ok) -and ([string]$sA4.reason -ceq 'settle-provenance-unproven')) '[A4] a nonexistent host call id is refused' ([string]$sA4.reason)

    # ---------- A5: resultado adulterado depois da claim ----------
    $fxA5 = New-G1PrepareFixture -Suffix 'g1a5' -KeyMaterial 'g1-a5-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA5).ok) '[A5] claimed' ''
    $pA5 = New-G1Proof -KeyMaterial $fxA5.key -Refs @('criterion:0', 'criterion:1')
    $tampered = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:1', 'criterion:99') }
    $sA5 = Invoke-G1Settle -Fx $fxA5 -Result $tampered -Proof $pA5 -Strict
    Assert-HF ((-not [bool]$sA5.ok) -and ([string]$sA5.reason -ceq 'settle-provenance-unproven')) '[A5] an evidence ref tampered after the claim is refused (never tier-capped into success)' ([string]$sA5.reason)

    # ---------- A6: proof legitima permite + tier/source no recibo ----------
    $fxA6 = New-G1PrepareFixture -Suffix 'g1a6' -KeyMaterial 'g1-a6-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA6).ok) '[A6] claimed' ''
    $pA6 = New-G1Proof -KeyMaterial $fxA6.key -Refs @('criterion:0', 'criterion:1')
    $bindA6 = Test-NDProvenanceBinding -ProvenanceProof $pA6 -ClaimSessionId $session -ClaimCallId $call -IdempotencyKey $fxA6.key -ChildSessionId $g1Child
    Assert-HF (([bool]$bindA6.ok) -and ([string]$bindA6.tier -ceq 'observed') -and ([string]$bindA6.source -ceq 'plugin-session-get')) '[A6] a single independent host source binds as tier observed' ('reason=' + [string]$bindA6.reason)
    $pA6b = New-G1Proof -KeyMaterial $fxA6.key -Source 'opencode-db' -Sources @('plugin-session-get', 'opencode-db') -Refs @('criterion:0', 'criterion:1')
    $bindA6b = Test-NDProvenanceBinding -ProvenanceProof $pA6b -ClaimSessionId $session -ClaimCallId $call -IdempotencyKey $fxA6.key -ChildSessionId $g1Child
    Assert-HF (([bool]$bindA6b.ok) -and ([string]$bindA6b.tier -ceq 'corroborated')) '[A6] two independent sources bind as tier corroborated' ('reason=' + [string]$bindA6b.reason)
    $pA6c = New-G1Proof -KeyMaterial $fxA6.key -Source 'declared' -Refs @('criterion:0', 'criterion:1')
    $bindA6c = Test-NDProvenanceBinding -ProvenanceProof $pA6c -ClaimSessionId $session -ClaimCallId $call -IdempotencyKey $fxA6.key -ChildSessionId $g1Child
    Assert-HF (([bool]$bindA6c.ok) -and ([string]$bindA6c.tier -ceq 'declared')) '[A6] a bare declaration binds as tier declared' ('reason=' + [string]$bindA6c.reason)
    $sA6 = Invoke-G1Settle -Fx $fxA6 -Result $g1Cand -Proof $pA6 -Strict
    Assert-HF (([bool]$sA6.ok) -and ([bool]$sA6.settled) -and (-not [bool]$sA6.duplicate) -and ([int]$sA6.executor_calls -eq 0)) '[A6] a valid bound proof allows the settlement in strict mode' ([string]$sA6.reason)
    $rawA6 = Get-G1ReceiptRaw -GoalId $fxA6.fx.goal -Key $fxA6.key
    Assert-HF (($null -ne $rawA6) -and ([string]$rawA6.settle_provenance_tier -ceq 'observed') -and ([string]$rawA6.settle_provenance_source -ceq 'plugin-session-get')) '[A6] the settled receipt records settle_provenance_tier + settle_provenance_source' ''
    Assert-HF ([bool](Test-NDSettledHandoffProof -Receipt $rawA6).ok) '[A6] the settled receipt still proves the handoff with the provenance fields added' ''

    # ---------- A6-control: default SEM proof segue identico ----------
    $fxA6c = New-G1PrepareFixture -Suffix 'g1a6c' -KeyMaterial 'g1-a6c-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA6c).ok) '[A6c] claimed' ''
    $sA6c = Invoke-G1Settle -Fx $fxA6c -Result $g1Cand
    Assert-HF (([bool]$sA6c.ok) -and ([bool]$sA6c.settled)) '[A6c] without strict/proof the settlement is unchanged (no new refusal)' ([string]$sA6c.reason)
    $rawA6c = Get-G1ReceiptRaw -GoalId $fxA6c.fx.goal -Key $fxA6c.key
    Assert-HF (($null -ne $rawA6c) -and ($null -eq $rawA6c.PSObject.Properties['settle_provenance_tier'])) '[A6c] the default receipt carries no provenance field (byte-level default preserved)' ''

    # ---------- A7: strict recusa source='declared' mesmo com tupla concordante ----------
    $fxA7 = New-G1PrepareFixture -Suffix 'g1a7' -KeyMaterial 'g1-a7-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA7).ok) '[A7] claimed' ''
    $pA7 = New-G1Proof -KeyMaterial $fxA7.key -Source 'declared' -Refs @('criterion:0', 'criterion:1')
    $sA7 = Invoke-G1Settle -Fx $fxA7 -Result $g1Cand -Proof $pA7 -Strict
    Assert-HF ((-not [bool]$sA7.ok) -and (-not [bool]$sA7.settled) -and ([string]$sA7.reason -ceq 'settle-provenance-unproven')) '[A7] a concordant tuple with source declared is refused in strict mode (declaration is never proof)' ([string]$sA7.reason)
    $bindA7 = Test-NDProvenanceBinding -ProvenanceProof $pA7 -ClaimSessionId $session -ClaimCallId $call -IdempotencyKey $fxA7.key -ChildSessionId $g1Child -ExpectedClaimedEvidence @('criterion:0', 'criterion:1') -Strict
    Assert-HF ((-not [bool]$bindA7.ok) -and ([string]$bindA7.reason -ceq 'provenance-declared-not-proof')) '[A7] strict binding refuses the declared tier directly' ([string]$bindA7.reason)

    # ---------- A8: strict exige claimed_evidence (sem skip por ausencia) ----------
    $fxA8 = New-G1PrepareFixture -Suffix 'g1a8' -KeyMaterial 'g1-a8-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA8).ok) '[A8] claimed' ''
    $pA8 = New-G1Proof -KeyMaterial $fxA8.key
    $sA8 = Invoke-G1Settle -Fx $fxA8 -Result $g1Cand -Proof $pA8 -Strict
    Assert-HF ((-not [bool]$sA8.ok) -and ([string]$sA8.reason -ceq 'settle-provenance-unproven')) '[A8] strict refuses a proof without claimed_evidence (no skip on absence)' ([string]$sA8.reason)
    $bindA8 = Test-NDProvenanceBinding -ProvenanceProof $pA8 -ClaimSessionId $session -ClaimCallId $call -IdempotencyKey $fxA8.key -ChildSessionId $g1Child -ExpectedClaimedEvidence @('criterion:0', 'criterion:1') -Strict
    Assert-HF ((-not [bool]$bindA8.ok) -and ([string]$bindA8.reason -ceq 'provenance-evidence-required')) '[A8] strict binding requires the result refs directly' ([string]$bindA8.reason)

    # ---------- A9: replay strict de liquidacao declarada nao herda sucesso ----------
    $fxA9 = New-G1PrepareFixture -Suffix 'g1a9' -KeyMaterial 'g1-a9-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxA9).ok) '[A9] claimed' ''
    $sA9 = Invoke-G1Settle -Fx $fxA9 -Result $g1Cand
    Assert-HF (([bool]$sA9.ok) -and ([bool]$sA9.settled)) '[A9] the declared settlement succeeded without strict' ([string]$sA9.reason)
    $sA9r = Invoke-G1Settle -Fx $fxA9 -Result $g1Cand -Strict
    Assert-HF ((-not [bool]$sA9r.ok) -and (-not [bool]$sA9r.settled) -and ([string]$sA9r.reason -ceq 'settle-provenance-unproven')) '[A9] a strict replay of a declared settlement is refused (replay never invents provenance)' ([string]$sA9r.reason)

    # ---------- B1: CLAIM valido => admission vivo => allow ----------
    $fxB1 = New-G1PrepareFixture -Suffix 'g1b1' -KeyMaterial 'g1-b1-1'
    $cB1 = Invoke-G1Claim -Fx $fxB1 -EmitAdmission
    Assert-HF (([bool]$cB1.ok) -and ([bool]$cB1.claimed)) '[B1] the claim accepted with the admission opt-in' ([string]$cB1.reason)
    $admB1 = Get-G1Admission -GoalId $fxB1.fx.goal -Key $fxB1.key
    Assert-HF ($null -ne $admB1) '[B1] the admission file exists under <goal-namespace>/admission/<key>.admission.json' ''
    $dB1 = Test-NDAdmissionDecision -Admission $admB1 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -ExpectedGeneration $fxB1.fx.gen
    Assert-HF (([bool]$dB1.allow) -and ([string]$dB1.reason -ceq '')) '[B1] a live admission with matching (session, call, agent) allows' ('reason=' + [string]$dB1.reason)
    $rawB1 = Get-G1ReceiptRaw -GoalId $fxB1.fx.goal -Key $fxB1.key
    Assert-HF (($null -ne $rawB1) -and ([string]$rawB1.phase -ceq 'claimed')) '[B1] the receipt is claimed (the admission did not change the receipt phase)' ''

    # ---------- B2: sem CLAIM => sem admission => deny ----------
    $fxB2 = New-G1PrepareFixture -Suffix 'g1b2' -KeyMaterial 'g1-b2-1'
    Assert-HF ([bool](Invoke-OrchestrationNativeDispatchPrepare -Intent $fxB2.intent -Authorization $fxB2.fx.auth -SessionId $session -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath).ok) '[B2] only PREPARE ran (no claim, no effect)' ''
    $admB2 = Get-G1Admission -GoalId $fxB2.fx.goal -Key $fxB2.key
    Assert-HF ($null -eq $admB2) '[B2] no admission file exists without a claim' ''
    $dB2 = Test-NDAdmissionDecision -Admission $null -GoalId $fxB2.fx.goal -SessionId $session -CallId $call -Agent 'coder'
    Assert-HF ((-not [bool]$dB2.allow) -and ([string]$dB2.reason -ceq 'admission-absent')) '[B2] absent admission denies (fail-closed)' ('reason=' + [string]$dB2.reason)

    # ---------- B3: expirado => deny ----------
    $admB3 = New-NDAdmissionRecord -IdempotencyKey $fxB1.key -GoalId $fxB1.fx.goal -TaskId $fxB1.fx.task -SessionId $session -CallId $call -Agent 'coder' -Owner 'planner-1' -Generation $fxB1.fx.gen -GoalState 'ACTIVE' -TtlSeconds 1 -NowUtc ([DateTime]::UtcNow.AddHours(-2))
    $dB3 = Test-NDAdmissionDecision -Admission $admB3 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder'
    Assert-HF ((-not [bool]$dB3.allow) -and ([string]$dB3.reason -ceq 'admission-expired')) '[B3] an expired admission denies' ('reason=' + [string]$dB3.reason)

    # ---------- B4: generation obsoleta => deny ----------
    $admB4 = New-NDAdmissionRecord -IdempotencyKey $fxB1.key -GoalId $fxB1.fx.goal -TaskId $fxB1.fx.task -SessionId $session -CallId $call -Agent 'coder' -Owner 'planner-1' -Generation $fxB1.fx.gen -GoalState 'ACTIVE' -TtlSeconds 3600
    $dB4 = Test-NDAdmissionDecision -Admission $admB4 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -ExpectedGeneration ($fxB1.fx.gen + 1)
    Assert-HF ((-not [bool]$dB4.allow) -and ([string]$dB4.reason -ceq 'admission-generation-stale')) '[B4] a stale ownership generation denies' ('reason=' + [string]$dB4.reason)

    # ---------- B5: outro goal => deny ----------
    $dB5 = Test-NDAdmissionDecision -Admission $admB1 -GoalId 'hf-goal-outro' -SessionId $session -CallId $call -Agent 'coder'
    Assert-HF ((-not [bool]$dB5.allow) -and ([string]$dB5.reason -ceq 'admission-goal-mismatch')) '[B5] another goal denies' ('reason=' + [string]$dB5.reason)

    # ---------- B6: model/provider fora do autorizado => deny ----------
    $admB6 = New-NDAdmissionRecord -IdempotencyKey $fxB1.key -GoalId $fxB1.fx.goal -TaskId $fxB1.fx.task -SessionId $session -CallId $call -Agent 'coder' -Owner 'planner-1' -Generation $fxB1.fx.gen -GoalState 'ACTIVE' -TtlSeconds 3600 -AllowedModel 'modelo-autorizado' -AllowedProvider 'provider-autorizado'
    $dB6m = Test-NDAdmissionDecision -Admission $admB6 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Model 'modelo-nao-autorizado' -Provider 'provider-autorizado'
    Assert-HF ((-not [bool]$dB6m.allow) -and ([string]$dB6m.reason -ceq 'admission-model-not-authorized')) '[B6] an unauthorized model override denies' ('reason=' + [string]$dB6m.reason)
    $dB6p = Test-NDAdmissionDecision -Admission $admB6 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Model 'modelo-autorizado' -Provider 'provider-nao-autorizado'
    Assert-HF ((-not [bool]$dB6p.allow) -and ([string]$dB6p.reason -ceq 'admission-provider-not-authorized')) '[B6] an unauthorized provider override denies' ('reason=' + [string]$dB6p.reason)

    # ---------- B7: operacao legitima => allow ----------
    $dB7 = Test-NDAdmissionDecision -Admission $admB6 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Model 'modelo-autorizado' -Provider 'provider-autorizado'
    Assert-HF (([bool]$dB7.allow) -and ([string]$dB7.reason -ceq '')) '[B7] a legitimate operation (tuple + authorized model/provider) allows' ('reason=' + [string]$dB7.reason)
    # B7 residual (documentado, nao coberto): o gate de permissao so
    # alcanca a superficie model-callable 'subagent'. Um shell/REST
    # direto NAO passa por permission.evaluate e portanto NAO coberto por
    # este decision function; a parcela PowerShell (admission lifecycle)
    # cobre a criacao/remocao, nao a invocacao fora da tool.
    $dB7b = Test-NDAdmissionDecision -Admission $admB6 -GoalId $fxB1.fx.goal -SessionId 'ses_hf_outra' -CallId $call -Agent 'coder' -Model 'modelo-autorizado' -Provider 'provider-autorizado'
    Assert-HF ((-not [bool]$dB7b.allow) -and ([string]$dB7b.reason -ceq 'admission-session-mismatch')) '[B7] another session denies (the tuple is what allows)' ('reason=' + [string]$dB7b.reason)

    # ---------- B8: SETTLE remove o admission ----------
    $fxB8 = New-G1PrepareFixture -Suffix 'g1b8' -KeyMaterial 'g1-b8-1'
    $cB8 = Invoke-G1Claim -Fx $fxB8 -EmitAdmission
    Assert-HF (([bool]$cB8.ok) -and ($null -ne (Get-G1Admission -GoalId $fxB8.fx.goal -Key $fxB8.key))) '[B8] the claim wrote a live admission' ''
    $sB8 = Invoke-G1Settle -Fx $fxB8 -Result $g1Cand -EmitAdmission
    Assert-HF (([bool]$sB8.ok) -and ([bool]$sB8.settled)) '[B8] the settlement succeeded and released the reservation' ([string]$sB8.reason)
    Assert-HF ($null -eq (Get-G1Admission -GoalId $fxB8.fx.goal -Key $fxB8.key)) '[B8] the settled dispatch no longer has a live admission (released)' ''
    $dB8 = Test-NDAdmissionDecision -Admission $null -GoalId $fxB8.fx.goal -SessionId $session -CallId $call -Agent 'coder'
    Assert-HF ((-not [bool]$dB8.allow) -and ([string]$dB8.reason -ceq 'admission-absent')) '[B8] a released admission denies the next dispatch of the same key' ('reason=' + [string]$dB8.reason)

    # ---------- B8-control: CLAIM/SETTLE sem opt-in nao tocam o admission ----------
    $fxB8c = New-G1PrepareFixture -Suffix 'g1b8c' -KeyMaterial 'g1-b8c-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxB8c).ok) '[B8c] claimed without the admission opt-in' ''
    Assert-HF ($null -eq (Get-G1Admission -GoalId $fxB8c.fx.goal -Key $fxB8c.key)) '[B8c] no admission file is written without -EmitAdmission (default unchanged)' ''
    $sB8c = Invoke-G1Settle -Fx $fxB8c -Result $g1Cand
    Assert-HF (([bool]$sB8c.ok) -and ([bool]$sB8c.settled)) '[B8c] the settle without -EmitAdmission still succeeds' ([string]$sB8c.reason)

    # ---------- B9: reparo idempotente pos-commit (admission perdido, retry identico) ----------
    $fxB9 = New-G1PrepareFixture -Suffix 'g1b9' -KeyMaterial 'g1-b9-1'
    $cB9 = Invoke-G1Claim -Fx $fxB9 -EmitAdmission
    Assert-HF (([bool]$cB9.ok) -and ($null -ne (Get-G1Admission -GoalId $fxB9.fx.goal -Key $fxB9.key))) '[B9] the claim wrote the admission after the durable commit' ([string]$cB9.reason)
    $stB9 = Get-NDAdmissionDir -RootDir $g1Root -GoalId $fxB9.fx.goal
    $admPathB9 = Join-Path ([string]$stB9.dir) ($fxB9.key + '.admission.json')
    Remove-Item -LiteralPath $admPathB9 -Force
    Assert-HF ($null -eq (Get-G1Admission -GoalId $fxB9.fx.goal -Key $fxB9.key)) '[B9] the admission file was removed to simulate a post-commit loss' ''
    $cB9r = Invoke-G1Claim -Fx $fxB9 -EmitAdmission
    Assert-HF (([bool]$cB9r.ok) -and ([bool]$cB9r.claimed) -and ($null -ne (Get-G1Admission -GoalId $fxB9.fx.goal -Key $fxB9.key))) '[B9] an identical retry regenerates the admission (idempotent repair, no new effect)' ([string]$cB9r.reason)
    # retry com binding divergente continua consumido-recusado.
    $cB9x = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $fxB9.key -Authorization $fxB9.fx.auth -SessionId 'ses_hf_outra' -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$fxB9.prepare.prepared_fingerprint) -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EmitAdmission
    Assert-HF ((-not [bool]$cB9x.ok) -and ([string]$cB9x.reason -ceq 'claim-already-consumed')) '[B9] a divergent retry of a consumed claim is still refused' ([string]$cB9x.reason)

    # ---------- B9-takeover: retry do novo dono nao reautoriza claim antigo ----------
    $fxB9t = New-G1PrepareFixture -Suffix 'g1b9t' -KeyMaterial 'g1-b9t-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxB9t -EmitAdmission).ok) '[B9t] claimed with admission under planner-1' ''
    $stB9t = Get-NDAdmissionDir -RootDir $g1Root -GoalId $fxB9t.fx.goal
    Remove-Item -LiteralPath (Join-Path ([string]$stB9t.dir) ($fxB9t.key + '.admission.json')) -Force
    $shrB9t = Renew-OrchestrationGoalOwnership -GoalId $fxB9t.fx.goal -OwnerId 'planner-1' -Generation $fxB9t.fx.gen -StoreDir $goalDir -LeaseTtlMs 1
    Assert-HF (($null -ne $shrB9t) -and ([bool]$shrB9t.ok)) '[B9t] the lease was shrunk to force expiry' ''
    Start-Sleep -Milliseconds 400
    $towB9t = Takeover-OrchestrationGoalOwnership -GoalId $fxB9t.fx.goal -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 120000
    Assert-HF (($null -ne $towB9t) -and ([bool]$towB9t.ok)) '[B9t] the takeover to planner-2 succeeded' ([string]$towB9t.reason)
    $authB9t = @{ explicit_allow = $true; goal_id = $fxB9t.fx.goal; owner = 'planner-2'; generation = [long]$towB9t.ownership.generation; source = 'planner' }
    $cB9t = Invoke-G1Claim -Fx $fxB9t -EmitAdmission -Auth $authB9t
    Assert-HF ((-not [bool]$cB9t.ok) -and ([string]$cB9t.reason -ceq 'claim-already-consumed')) '[B9t] the new owner retry with the old tuple does not reauthorize the old claim' ([string]$cB9t.reason)
    Assert-HF ($null -eq (Get-G1Admission -GoalId $fxB9t.fx.goal -Key $fxB9t.key)) '[B9t] no admission was regenerated across the ownership change' ''

    # ---------- B9-restricoes: reparo preserva o escopo gravado, nao o do retry ----------
    $fxB9r = New-G1PrepareFixture -Suffix 'g1b9r' -KeyMaterial 'g1-b9r-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxB9r -EmitAdmission -Model 'modelo-original').ok) '[B9r] claimed with a model restriction' ''
    $stB9r = Get-NDAdmissionDir -RootDir $g1Root -GoalId $fxB9r.fx.goal
    Remove-Item -LiteralPath (Join-Path ([string]$stB9r.dir) ($fxB9r.key + '.admission.json')) -Force
    $cB9r = Invoke-G1Claim -Fx $fxB9r -EmitAdmission -Model 'modelo-trocado'
    Assert-HF (([bool]$cB9r.ok) -and ([bool]$cB9r.claimed)) '[B9r] the identical retry regenerates the admission' ([string]$cB9r.reason)
    $admB9r = Get-G1Admission -GoalId $fxB9r.fx.goal -Key $fxB9r.key
    Assert-HF (($null -ne $admB9r) -and ([string]$admB9r.allowed_model -ceq 'modelo-original')) '[B9r] the regenerated admission keeps the RECORDED restriction (retry never loosens scope)' ('allowed_model=' + [string]$admB9r.allowed_model)
    $dB9r = Test-NDAdmissionDecision -Admission $admB9r -GoalId $fxB9r.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Model 'modelo-trocado'
    Assert-HF ((-not [bool]$dB9r.allow) -and ([string]$dB9r.reason -ceq 'admission-model-not-authorized')) '[B9r] the swapped model still denies against the recorded restriction' ('reason=' + [string]$dB9r.reason)

    # ---------- B9-corrompido: admission existente invalido nunca e "reparado" ----------
    $fxB9m = New-G1PrepareFixture -Suffix 'g1b9m' -KeyMaterial 'g1-b9m-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxB9m -EmitAdmission).ok) '[B9m] claimed with admission' ''
    $stB9m = Get-NDAdmissionDir -RootDir $g1Root -GoalId $fxB9m.fx.goal
    $admPathB9m = Join-Path ([string]$stB9m.dir) ($fxB9m.key + '.admission.json')
    [IO.File]::WriteAllText($admPathB9m, '{ truncado', [Text.UTF8Encoding]::new($false))
    $cB9m = Invoke-G1Claim -Fx $fxB9m -EmitAdmission
    Assert-HF ((-not [bool]$cB9m.ok) -and ([string]$cB9m.reason -ceq 'claim-already-consumed')) '[B9m] an identical retry never repairs an existing (even malformed) admission with a new expiry' ([string]$cB9m.reason)
    Assert-HF ([string]([IO.File]::ReadAllText($admPathB9m, [Text.Encoding]::UTF8)) -ceq '{ truncado') '[B9m] the malformed admission file was left untouched' ''

    # ---------- B10: remocao incondicional mesmo sem switch no SETTLE ----------
    $fxB10 = New-G1PrepareFixture -Suffix 'g1b10' -KeyMaterial 'g1-b10-1'
    Assert-HF ([bool](Invoke-G1Claim -Fx $fxB10 -EmitAdmission).ok) '[B10] claimed with admission' ''
    Assert-HF ($null -ne (Get-G1Admission -GoalId $fxB10.fx.goal -Key $fxB10.key)) '[B10] the admission exists before settlement' ''
    $sB10 = Invoke-G1Settle -Fx $fxB10 -Result $g1Cand
    Assert-HF (([bool]$sB10.ok) -and ([bool]$sB10.settled)) '[B10] the settle without -EmitAdmission still succeeds' ([string]$sB10.reason)
    Assert-HF ($null -eq (Get-G1Admission -GoalId $fxB10.fx.goal -Key $fxB10.key)) '[B10] the admission is released even when the settle carries no opt-in (unconditional removal)' ''

    # ---------- B11: paridade de model/provider vazio (restricao vazia = sem restricao) ----------
    $admB11 = New-NDAdmissionRecord -IdempotencyKey $fxB1.key -GoalId $fxB1.fx.goal -TaskId $fxB1.fx.task -SessionId $session -CallId $call -Agent 'coder' -Owner 'planner-1' -Generation $fxB1.fx.gen -GoalState 'ACTIVE' -TtlSeconds 3600
    $dB11 = Test-NDAdmissionDecision -Admission $admB11 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Model 'qualquer-modelo' -Provider 'qualquer-provider'
    Assert-HF ([bool]$dB11.allow) '[B11] an empty model/provider restriction constrains nothing (parity PS/JS)' ('reason=' + [string]$dB11.reason)
    $dB11b = Test-NDAdmissionDecision -Admission $admB6 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -Provider 'provider-autorizado'
    Assert-HF ((-not [bool]$dB11b.allow) -and ([string]$dB11b.reason -ceq 'admission-model-not-authorized')) '[B11] a filled model restriction with omitted invocation model denies (no bypass by omission)' ('reason=' + [string]$dB11b.reason)
    $dB11c = Test-NDAdmissionDecision -Admission $admB11 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -ExpectedOwner 'planner-1'
    Assert-HF ([bool]$dB11c.allow) '[B11] a matching expected owner allows' ('reason=' + [string]$dB11c.reason)
    $dB11d = Test-NDAdmissionDecision -Admission $admB11 -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder' -ExpectedOwner 'outro-owner'
    Assert-HF ((-not [bool]$dB11d.allow) -and ([string]$dB11d.reason -ceq 'admission-owner-mismatch')) '[B11] a divergent expected owner denies' ('reason=' + [string]$dB11d.reason)
    $admB11e = New-NDAdmissionRecord -IdempotencyKey $fxB1.key -GoalId $fxB1.fx.goal -TaskId $fxB1.fx.task -SessionId $session -CallId $call -Agent 'coder' -Owner 'planner-1' -Generation $fxB1.fx.gen -GoalState 'BLOCKED' -TtlSeconds 3600
    $dB11e = Test-NDAdmissionDecision -Admission $admB11e -GoalId $fxB1.fx.goal -SessionId $session -CallId $call -Agent 'coder'
    Assert-HF ((-not [bool]$dB11e.allow) -and ([string]$dB11e.reason -ceq 'admission-goal-not-active')) '[B11] a non-ACTIVE recorded goal state denies' ('reason=' + [string]$dB11e.reason)

    # ---------- D: avanco causal ----------
    . (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
    $script:g1OrigNextMove = (Get-Item -Path ('function:' + 'Get-OrchestrationNextMove')).ScriptBlock
    function Restore-G1NextMove {
        if ($null -ne $script:g1OrigNextMove) { Set-Item -Path ('function:' + 'Get-OrchestrationNextMove') -Value $script:g1OrigNextMove }
    }
    function New-G1AdvanceFixture {
        param([string]$Suffix)
        $fx = New-HFIsolatedFixture -Suffix $Suffix
        $nextTask = ('hf-task-' + $Suffix + '-next')
        New-HFKernelTask -Id $nextTask -GoalId $fx.goal -Gen $fx.gen
        $nextKey = Get-NativeDispatchHash32 ('g1-adv-' + $Suffix + '-next')
        $nextIntent = New-HFIntent -Task $nextTask -Key $nextKey -Gen $fx.gen
        Assert-HF ([bool]$nextIntent.ok) ('[G1-D] next intent built ' + $Suffix) ([string]$nextIntent.reason)
        return [pscustomobject]@{ fx = $fx; nextTask = $nextTask; nextKey = $nextKey; nextIntent = $nextIntent }
    }
    # G1-D-FIX: avanco exige liquidacao REAL previa. Prepara, reclama e
    # liquida a primeira task do goal (default, sem opt-ins) e devolve a
    # chave liquidada para o avanco causal.
    function New-G1SettledAdvanceFixture {
        param([string]$Suffix)
        $a = New-G1AdvanceFixture -Suffix $Suffix
        $firstTask = ('hf-task-' + $Suffix)
        $sk = Get-NativeDispatchHash32 ('g1-settled-' + $Suffix)
        $firstIntent = New-HFIntent -Task $firstTask -Key $sk -Gen $a.fx.gen
        Assert-HF ([bool]$firstIntent.ok) ('[G1-D] first intent built ' + $Suffix) ([string]$firstIntent.reason)
        $pp = Invoke-OrchestrationNativeDispatchPrepare -Intent $firstIntent -Authorization $a.fx.auth -SessionId $session -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF ([bool]$pp.ok) ('[G1-D] first task prepared ' + $Suffix) ([string]$pp.reason)
        $cc = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $sk -Authorization $a.fx.auth -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pp.prepared_fingerprint) -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (([bool]$cc.ok) -and ([bool]$cc.claimed)) ('[G1-D] first task claimed ' + $Suffix) ([string]$cc.reason)
        $ss = Invoke-OrchestrationNativeDispatchSettle -IdempotencyKey $sk -Authorization $a.fx.auth -ChildSessionId $g1Child -SessionId $session -MessageId $message -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pp.prepared_fingerprint) -Reference ([string]$pp.reference) -Result $g1Cand -ReceiptDir $g1Root -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-HF (([bool]$ss.ok) -and ([bool]$ss.settled)) ('[G1-D] first task settled ' + $Suffix) ([string]$ss.reason)
        return [pscustomobject]@{ fx = $a.fx; nextTask = $a.nextTask; nextKey = $a.nextKey; nextIntent = $a.nextIntent; settledKey = $sk }
    }
    function Invoke-G1Advance {
        param($Fx, $Status, $NextIntent, [switch]$Finalize, [string]$SettledKey, [int]$LockMs = 60000)
        return (Invoke-OrchestrationNativeDispatchAdvance -GoalId $Fx.fx.goal -SettledKey $SettledKey -Authorization $Fx.fx.auth -ObjectiveStatus $Status -NextIntent $NextIntent -SessionId $session -ReceiptDir $g1Root -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -FinalizeGoalOnComplete:$Finalize -LockTimeoutMs $LockMs)
    }
    function New-G1Status {
        param([bool]$Completed = $false, [bool]$StrategyChange = $false, [string]$Failure = '', [bool]$Progress = $true, [string[]]$Remaining = @('hf-next'))
        $fail = $Failure
        if ([string]::IsNullOrWhiteSpace($fail)) { $fail = $null }
        return @{
            objective_completed = [bool]$Completed
            remaining_work = [string[]]$Remaining
            authorized = $true
            blocker_kind = ''
            progress_possible = [bool]$Progress
            strategy_change = [bool]$StrategyChange
            context_degraded = $false
            last_failure = $fail
            terminal_blocker = $null
            consecutive_no_progress = [long]0
        }
    }
    function Get-G1AdvanceRecord {
        param([string]$GoalId, [string]$SettledKey)
        $st = Get-NDAdvanceDir -RootDir $g1Root -GoalId $GoalId
        if (-not [bool]$st.ok) { return $null }
        $p = Join-Path ([string]$st.dir) ($SettledKey + '.advance.json')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
        try { return (ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8))) } catch { return $null }
    }

    # D0: chave fabricada (sem liquidacao) nao avanca - sem prepare.
    $fxD0 = New-G1AdvanceFixture -Suffix 'g1d0'
    $aD0 = Invoke-G1Advance -Fx $fxD0 -Status (New-G1Status) -NextIntent $fxD0.nextIntent -SettledKey (Get-NativeDispatchHash32 'g1-settled-d0')
    Assert-HF ((-not [bool]$aD0.ok) -and (-not [bool]$aD0.prepared) -and ([string]$aD0.reason -ceq 'advance-settlement-unproven')) '[D0] a fabricated settled key never advances (no prior settlement, no prepare)' ([string]$aD0.reason)

    # D1: CONTINUE prepara a proxima task.
    $fxD1 = New-G1SettledAdvanceFixture -Suffix 'g1d1'
    $skD1 = $fxD1.settledKey
    $aD1 = Invoke-G1Advance -Fx $fxD1 -Status (New-G1Status) -NextIntent $fxD1.nextIntent -SettledKey $skD1
    Assert-HF (([bool]$aD1.ok) -and ([bool]$aD1.prepared) -and ([string]$aD1.move -ceq 'CONTINUE') -and ([int]$aD1.executor_calls -eq 0)) '[D1] CONTINUE prepares the next task and returns the new idempotency key' ([string]$aD1.reason)
    Assert-HF (($aD1.idempotency_key -ceq $fxD1.nextKey) -and (-not [string]::IsNullOrWhiteSpace([string]$aD1.reference))) '[D1] the returned key is the PREPAREd one' ('key=' + [string]$aD1.idempotency_key)
    $recD1 = Get-G1AdvanceRecord -GoalId $fxD1.fx.goal -SettledKey $skD1
    Assert-HF (($null -ne $recD1) -and ([string]$recD1.move -ceq 'CONTINUE') -and ([bool]$recD1.prepared) -and ([string]$recD1.next_idempotency_key -ceq $fxD1.nextKey)) '[D1] the advance decision is persisted with the prepared next key' ''
    # D1-idempotencia: repetir a mesma chave devolve a decisao SEM novo PREPARE.
    $aD1b = Invoke-G1Advance -Fx $fxD1 -Status (New-G1Status) -NextIntent $fxD1.nextIntent -SettledKey $skD1
    Assert-HF (([bool]$aD1b.ok) -and ([bool]$aD1b.prepared) -and ([string]$aD1b.idempotency_key -ceq $fxD1.nextKey)) '[D1] replaying the settled key returns the stored decision without preparing again' ([string]$aD1b.reason)

    # D1c: lock do advance ocupado => recusa sem preparar (exclusao real).
    $fxD1c = New-G1SettledAdvanceFixture -Suffix 'g1d1c'
    $advDirD1c = Get-NDAdvanceDir -RootDir $g1Root -GoalId $fxD1c.fx.goal
    Assert-HF ([bool](Get-NDValue $advDirD1c 'ok' $false)) '[D1c] the advance dir resolves' ''
    $heldWhy = ''
    $heldLock = Open-NDReceiptLock -Dir ([string](Get-NDValue $advDirD1c 'dir' '')) -LockTimeoutMs 60000 -Expected ([string](Get-NDValue $advDirD1c 'ident' '')) -RefusalReason ([ref]$heldWhy)
    Assert-HF ($null -ne $heldLock) '[D1c] the test holds the advance lock' ([string]$heldWhy)
    try {
        $aD1c = Invoke-G1Advance -Fx $fxD1c -Status (New-G1Status) -NextIntent $fxD1c.nextIntent -SettledKey $fxD1c.settledKey -LockMs 300
    }
    finally {
        try { $heldLock.Dispose() } catch { }
    }
    Assert-HF ((-not [bool]$aD1c.ok) -and (-not [bool]$aD1c.prepared) -and ([string]$aD1c.reason -ceq 'advance-lock-busy')) '[D1c] a contended advance refuses without preparing (one decision per settlement)' ([string]$aD1c.reason)
    $recD1c = Get-G1AdvanceRecord -GoalId $fxD1c.fx.goal -SettledKey $fxD1c.settledKey
    Assert-HF ($null -eq $recD1c) '[D1c] the refused contended advance persisted no decision' ''

    # D1d: record pendente (queda antes do PREPARE) permite nova tentativa fresca.
    $fxD1d = New-G1SettledAdvanceFixture -Suffix 'g1d1d'
    $advDirD1d = Get-NDAdvanceDir -RootDir $g1Root -GoalId $fxD1d.fx.goal
    $pendingD1d = [ordered]@{
        schema_version = 1
        ok = $true
        reason = ''
        goal_id = $fxD1d.fx.goal
        settled_key = $fxD1d.settledKey
        move = 'CONTINUE'
        move_reason = 'crashed-before-prepare'
        stop_reason = ''
        prepared = $false
        next_idempotency_key = $fxD1d.nextKey
        next_reference = ''
        next_task_id = ''
        next_agent = ''
        prepare_reason = ''
        goal_state = 'ACTIVE'
        goal_revision = 0
        finalize_reason = ''
        recorded_at = ([DateTime]::UtcNow.ToString('o'))
    }
    Assert-HF ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $advDirD1d 'dir' '')) -Ident ([string](Get-NDValue $advDirD1d 'ident' '')) -Key $fxD1d.settledKey -Record $pendingD1d)) '[D1d] a pending record simulates the pre-PREPARE crash' ''
    $aD1d = Invoke-G1Advance -Fx $fxD1d -Status (New-G1Status) -NextIntent $fxD1d.nextIntent -SettledKey $fxD1d.settledKey
    Assert-HF (([bool]$aD1d.ok) -and ([bool]$aD1d.prepared) -and ([string]$aD1d.idempotency_key -ceq $fxD1d.nextKey)) '[D1d] a pending record recovers with a fresh attempt of the SAME intent (never replays empty success)' ([string]$aD1d.reason)

    # D1e: pendente com intent divergente recusa; pendente sem chave recusa.
    $fxD1e = New-G1SettledAdvanceFixture -Suffix 'g1d1e'
    $advDirD1e = Get-NDAdvanceDir -RootDir $g1Root -GoalId $fxD1e.fx.goal
    $otherKeyD1e = Get-NativeDispatchHash32 'g1-d1e-other-intent'
    $otherIntentD1e = New-HFIntent -Task 'hf-task-g1d1e-other' -Key $otherKeyD1e -Gen $fxD1e.fx.gen
    $pendingD1e = [ordered]@{
        schema_version = 1
        ok = $true
        reason = ''
        goal_id = $fxD1e.fx.goal
        settled_key = $fxD1e.settledKey
        move = 'CONTINUE'
        move_reason = 'crashed-after-prepare'
        stop_reason = ''
        prepared = $false
        next_idempotency_key = $fxD1e.nextKey
        next_reference = ''
        next_task_id = ''
        next_agent = ''
        prepare_reason = ''
        goal_state = 'ACTIVE'
        goal_revision = 0
        finalize_reason = ''
        recorded_at = ([DateTime]::UtcNow.ToString('o'))
    }
    Assert-HF ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $advDirD1e 'dir' '')) -Ident ([string](Get-NDValue $advDirD1e 'ident' '')) -Key $fxD1e.settledKey -Record $pendingD1e)) '[D1e] a pending record with the reserved intent is stored' ''
    $aD1e = Invoke-G1Advance -Fx $fxD1e -Status (New-G1Status) -NextIntent $otherIntentD1e -SettledKey $fxD1e.settledKey
    Assert-HF ((-not [bool]$aD1e.ok) -and (-not [bool]$aD1e.prepared) -and ([string]$aD1e.reason -ceq 'advance-intent-mismatch')) '[D1e] a retry with a DIVERGENT intent never prepares a second successor for the same settlement' ([string]$aD1e.reason)
    $noKeyD1e = [ordered]@{}
    foreach ($kv in $pendingD1e.GetEnumerator()) { $noKeyD1e[$kv.Key] = $kv.Value }
    $noKeyD1e['next_idempotency_key'] = ''
    Assert-HF ([bool](Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $advDirD1e 'dir' '')) -Ident ([string](Get-NDValue $advDirD1e 'ident' '')) -Key $fxD1e.settledKey -Record $noKeyD1e)) '[D1e] a pending record without intent identity is stored' ''
    $aD1e2 = Invoke-G1Advance -Fx $fxD1e -Status (New-G1Status) -NextIntent $fxD1e.nextIntent -SettledKey $fxD1e.settledKey
    Assert-HF ((-not [bool]$aD1e2.ok) -and (-not [bool]$aD1e2.prepared) -and ([string]$aD1e2.reason -ceq 'advance-intent-unknown')) '[D1e] a pending record without intent identity refuses instead of preparing blindly' ([string]$aD1e2.reason)

    # D1f: advance record existente porem ilegivel nunca vira ausencia.
    $fxD1f = New-G1SettledAdvanceFixture -Suffix 'g1d1f'
    $advDirD1f = Get-NDAdvanceDir -RootDir $g1Root -GoalId $fxD1f.fx.goal
    $advPathD1f = Join-Path ([string](Get-NDValue $advDirD1f 'dir' '')) ($fxD1f.settledKey + '.advance.json')
    [IO.File]::WriteAllText($advPathD1f, '{ truncado', [Text.UTF8Encoding]::new($false))
    $aD1f = Invoke-G1Advance -Fx $fxD1f -Status (New-G1Status) -NextIntent $fxD1f.nextIntent -SettledKey $fxD1f.settledKey
    Assert-HF ((-not [bool]$aD1f.ok) -and (-not [bool]$aD1f.prepared) -and ([string]$aD1f.reason -ceq 'advance-intent-unknown')) '[D1f] an unreadable advance record refuses without preparing (corruption is never absence)' ([string]$aD1f.reason)
    Assert-HF ([string]([IO.File]::ReadAllText($advPathD1f, [Text.Encoding]::UTF8)) -ceq '{ truncado') '[D1f] the corrupted advance record was preserved, not overwritten' ''
    $pD1f = Join-Path (Get-NDGoalReceiptDir -RootDir $g1Root -GoalId $fxD1f.fx.goal) ($fxD1f.nextKey + '.json')
    Assert-HF (-not (Test-Path -LiteralPath $pD1f)) '[D1f] no successor was prepared for the settlement with the corrupted record' ''

    # D2: RETRY dentro da policy prepara.
    $fxD2 = New-G1SettledAdvanceFixture -Suffix 'g1d2'
    $stD2 = New-G1Status -Failure 'recoverable' -Progress $false
    $aD2 = Invoke-G1Advance -Fx $fxD2 -Status $stD2 -NextIntent $fxD2.nextIntent -SettledKey $fxD2.settledKey
    Assert-HF (([bool]$aD2.ok) -and ([bool]$aD2.prepared) -and ([string]$aD2.move -ceq 'RETRY')) '[D2] RETRY inside policy prepares the next task' ([string]$aD2.reason)

    # D3: REPLAN nao prepara as cegas.
    $fxD3 = New-G1SettledAdvanceFixture -Suffix 'g1d3'
    $skD3 = $fxD3.settledKey
    $aD3 = Invoke-G1Advance -Fx $fxD3 -Status (New-G1Status -StrategyChange $true) -NextIntent $fxD3.nextIntent -SettledKey $skD3
    Assert-HF (([bool]$aD3.ok) -and (-not [bool]$aD3.prepared) -and ([string]$aD3.move -ceq 'REPLAN')) '[D3] REPLAN does not prepare blindly' ([string]$aD3.reason)
    Assert-HF ([string]::IsNullOrWhiteSpace([string]$aD3.idempotency_key)) '[D3] no idempotency key is minted on REPLAN' ''
    $recD3 = Get-G1AdvanceRecord -GoalId $fxD3.fx.goal -SettledKey $skD3
    Assert-HF (($null -ne $recD3) -and ([string]$recD3.move -ceq 'REPLAN') -and (-not [bool]$recD3.prepared)) '[D3] the replan decision is marked in the advance record' ''
    $pD3 = Join-Path (Get-NDGoalReceiptDir -RootDir $g1Root -GoalId $fxD3.fx.goal) ($fxD3.nextKey + '.json')
    Assert-HF (-not (Test-Path -LiteralPath $pD3)) '[D3] no prepared receipt exists for the next task after REPLAN' ''

    # D4: admissao viva recusa => BLOCKED sem prepare.
    $fxD4 = New-G1SettledAdvanceFixture -Suffix 'g1d4'
    $ghostKey = Get-NativeDispatchHash32 'g1-adv-d4-ghost'
    $ghostIntent = New-HFIntent -Task 'hf-task-ghost-d4' -Key $ghostKey -Gen $fxD4.fx.gen
    $aD4 = Invoke-G1Advance -Fx $fxD4 -Status (New-G1Status) -NextIntent $ghostIntent -SettledKey $fxD4.settledKey
    Assert-HF ((-not [bool]$aD4.ok) -and (-not [bool]$aD4.prepared) -and ([string]$aD4.move -ceq 'BLOCKED') -and ([string]$aD4.reason -ceq 'advance-blocked:task-not-found')) '[D4] a refused live admission blocks the advance without preparing' ([string]$aD4.reason)

    # D5: COMPLETE nao prepara e finaliza SOMENTE por CAS.
    $fxD5 = New-G1SettledAdvanceFixture -Suffix 'g1d5'
    $stD5 = New-G1Status -Completed $true -Progress $false
    $aD5 = Invoke-G1Advance -Fx $fxD5 -Status $stD5 -NextIntent $fxD5.nextIntent -SettledKey $fxD5.settledKey
    Assert-HF (([bool]$aD5.ok) -and (-not [bool]$aD5.prepared) -and ([string]$aD5.move -ceq 'COMPLETE')) '[D5] COMPLETE does not prepare' ([string]$aD5.reason)
    $goalD5 = (Get-OrchestrationGoal -GoalId $fxD5.fx.goal -StoreDir $goalDir).goal
    Assert-HF ([string]$goalD5['state'] -ceq 'ACTIVE') '[D5] without the explicit finalize switch the goal state is untouched' ('state=' + [string]$goalD5['state'])
    $fxD5b = New-G1SettledAdvanceFixture -Suffix 'g1d5b'
    $revD5b = [long]((Get-OrchestrationGoal -GoalId $fxD5b.fx.goal -StoreDir $goalDir).goal['revision'])
    # S3a-FIX (finalize gated): o caminho legitimo exige criterios
    # verificados no goal vivo; o fixture marca progress 1/1 antes.
    $liveD5b = (Get-OrchestrationGoal -GoalId $fxD5b.fx.goal -StoreDir $goalDir).goal
    $upD5b = Update-OrchestrationGoal -GoalId $fxD5b.fx.goal -ExpectedRevision ([long]$liveD5b['revision']) -Fields @{ progress = @{ satisfied = 1; total = 1 } } -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $fxD5b.fx.gen
    Assert-HF ([bool]$upD5b.ok) '[D5b] the fixture goal carries verified criteria' ([string]$upD5b.reason)
    $aD5b = Invoke-G1Advance -Fx $fxD5b -Status (New-G1Status -Completed $true -Progress $false) -NextIntent $fxD5b.nextIntent -SettledKey $fxD5b.settledKey -Finalize
    Assert-HF (([bool]$aD5b.ok) -and (-not [bool]$aD5b.prepared) -and ([string]$aD5b.move -ceq 'COMPLETE')) '[D5b] COMPLETE with the finalize switch still does not prepare' ([string]$aD5b.reason)
    $goalD5b = (Get-OrchestrationGoal -GoalId $fxD5b.fx.goal -StoreDir $goalDir).goal
    Assert-HF ([string]$goalD5b['state'] -ceq 'COMPLETED') '[D5b] the goal was finalized through the CAS path' ('state=' + [string]$goalD5b['state'])
    # S3a-FIX (D5d): stop de politica com -Finalize NAO finaliza.
    $fxD5d = New-G1SettledAdvanceFixture -Suffix 'g1d5d'
    $stD5d = @{ objective_completed = $false; remaining_work = @(); authorized = $false; blocker_kind = 'policy'; progress_possible = $false; strategy_change = $false; context_degraded = $false; last_failure = $null; terminal_blocker = $null; consecutive_no_progress = [long]0 }
    $aD5d = Invoke-G1Advance -Fx $fxD5d -Status $stD5d -NextIntent $fxD5d.nextIntent -SettledKey $fxD5d.settledKey -Finalize
    Assert-HF (([bool]$aD5d.ok) -and (-not [bool]$aD5d.prepared) -and ([string]$aD5d.move -ceq 'COMPLETE')) '[D5d] a policy stop records COMPLETE without preparing' ([string]$aD5d.reason)
    $goalD5d = (Get-OrchestrationGoal -GoalId $fxD5d.fx.goal -StoreDir $goalDir).goal
    Assert-HF ([string]$goalD5d['state'] -ceq 'ACTIVE') '[D5d] a policy stop never finalizes the goal' ('state=' + [string]$goalD5d['state'])
    $recD5d = Get-G1AdvanceRecord -GoalId $fxD5d.fx.goal -SettledKey $fxD5d.settledKey
    Assert-HF (([string]$recD5d.finalize_reason -ceq 'goal-finalize-refused:policy-stop')) '[D5d] the finalize refusal is recorded' ([string]$recD5d.finalize_reason)
    $aD5c = Invoke-G1Advance -Fx $fxD5b -Status (New-G1Status -Completed $true -Progress $false) -NextIntent $fxD5b.nextIntent -SettledKey (Get-NativeDispatchHash32 'g1-settled-d5b2') -Finalize
    Assert-HF ((-not [bool]$aD5c.ok) -and ([string]$aD5c.reason -ceq 'advance-stale-goal')) '[D5c] a terminal goal refuses the next advance (stale)' ([string]$aD5c.reason)

    # D6: move fora do conjunto fechado => recusa sem prepare.
    $fxD6 = New-G1SettledAdvanceFixture -Suffix 'g1d6'
    function Get-OrchestrationNextMove {
        param($Status)
        return [pscustomobject]@{ move = 'ROTATE_CONTEXT'; reason = 'mocked-rotacao'; remaining_count = 1 }
    }
    try {
        $aD6 = Invoke-G1Advance -Fx $fxD6 -Status (New-G1Status) -NextIntent $fxD6.nextIntent -SettledKey $fxD6.settledKey
    }
    finally {
        Restore-G1NextMove
    }
    Assert-HF ((-not [bool]$aD6.ok) -and (-not [bool]$aD6.prepared) -and ([string]$aD6.reason -ceq 'advance-move-unknown')) '[D6] an unknown move refuses without preparing' ([string]$aD6.reason)

    # D7: goal stale (fora de ACTIVE) => revalida e recusa.
    $fxD7 = New-G1AdvanceFixture -Suffix 'g1d7'
    $setD7 = Set-HFGoalStateLive -GoalId $fxD7.fx.goal -ToState 'BLOCKED' -Gen $fxD7.fx.gen
    Assert-HF ([bool]$setD7.ok) '[D7] the fixture goal left ACTIVE' ([string]$setD7.reason)
    $aD7 = Invoke-G1Advance -Fx $fxD7 -Status (New-G1Status) -NextIntent $fxD7.nextIntent -SettledKey (Get-NativeDispatchHash32 'g1-settled-d7')
    Assert-HF ((-not [bool]$aD7.ok) -and (-not [bool]$aD7.prepared) -and ([string]$aD7.reason -ceq 'advance-stale-goal')) '[D7] a stale goal (not ACTIVE) is revalidated and refuses' ([string]$aD7.reason)

    # ---------- global: no worker was ever spawned in this suite ----------
    # L2a (compatibilidade legada) e X1f (replay idempotente da propria
    # chave) sao as UNICAS chamadas intencionais de Executor em toda a suite;
    # todo o resto tem de provar executor_calls = 0.
    Assert-HF ([int]$script:spyState.calls -eq [int]$script:spyBaseline) '[G] no Executor call from Prepare/Claim/Settle beyond the two intentional legacy calls' ('spyCalls=' + [string]$script:spyState.calls + ' baseline=' + [string]$script:spyBaseline)
    Assert-HF ([int]$script:spyState.calls -eq 2) '[G] exactly the TWO intentional legacy-spy calls happened, nothing else' ('spyCalls=' + [string]$script:spyState.calls)
}
finally {
    # PRA-SETTLE-FIX3: o escritor mockado NUNCA sobrevive a suite, nem em
    # falha no meio do cenario - a funcao original e restaurada aqui.
    try { Restore-HFReceiptWriter } catch { }
    try { Restore-HFKernelWriter } catch { }
    if ($script:tempRoot -ne '') {
        try { Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Host ('[SUMMARY] pass=' + $script:passed + ' fail=' + $script:failed + ' skip=' + $script:skipped)
if ($script:failed -gt 0) { exit 1 }
exit 0
