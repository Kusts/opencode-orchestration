<#!
.SYNOPSIS
    Tests for receipt reading + live ownership on duplicate read (R2/R3 REV4).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.

    R3 (unreadable receipt must never become a new dispatch):
    proven absence (no file) is the ONLY state that allows a new
    dispatch. A truncated JSON, a key divergent from the filename, an
    unknown schema or an unknown phase must REFUSE with an explicit
    reason, keep the file byte-for-byte and call the Executor zero times.
    R2 (stale ownership on duplicate): the goal ownership is re-read
    under the receipt lock for EVERY path that returns a duplicate
    (owner/generation live == receipt and goal ACTIVE). A takeover or
    lease expiry simulated between authorization and the lock (the
    window that motivated the fix) must refuse without content.
    RP (REV6/SEC6 reparse points): `Test-Path -PathType Leaf` accepts a
    symlink/junction whose target is a regular file/directory, so the
    guard needs the ReparsePoint attribute. Covered with a REAL
    directory junction `<hash-B>` -> `<hash-A>` (no admin privilege
    needed) proving goal B cannot read or write receipts of A, and with
    a real file symlink on `<key>.json` proving the linked target is
    neither read nor overwritten. Link fixtures are created by
    `cmd /c mklink` and are explicitly SKIPPED (never faked) where the
    environment forbids them; cleanup removes ONLY the link, never the
    target.
    RP3 (REV7/R1 namespace TOCTOU): the resolver validates the goal
    namespace ONCE; `Assert-NDDirIdentity` revalidates it immediately
    before every IO. Covered by an identity change driven from inside
    the Executor (mid-dispatch, after resolution and after the pending
    write) with zero write IO afterwards and the receipt left pending,
    by direct helper calls on a REAL junctioned directory (read, write
    and lock, with and without the captured identity) with zero IO in
    the junction target, by a recreated directory failing the identity
    reassert, and by a happy-path dispatch proving the checks do not
    disturb the normal flow. The in-flight rename/junction swap itself
    is refused by the operating system while the receipt lock
    (FileShare.None) is held, which is stated in the test comment.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')

$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Assert-RX {
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

function Skip-RX {
    param([string]$Name)
    Write-Host ('[SKIP] ' + $Name)
    $script:skipped++
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndreceipts-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    $tasksDir = Join-Path $tempRoot 'tasks'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

    try {
        # ---------- fixture: ACTIVE goal + ownership + kernel task ----------
        $g = New-OrchestrationGoal -GoalId 'rx-goal-1' -Objective 'recibos honestos' -Criteria @('criterio-a', 'criterio-b') -StoreDir $goalDir
        Assert-RX ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-RX ([bool]$sv.ok) '[F] goal active+saved' ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'rx-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-RX ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
        $gen = [long]$own.ownership['generation']
        $authOk = @{ explicit_allow = $true; goal_id = 'rx-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $ph = Get-NativeDispatchHash32 'receipt-prompt-material'

        $script:tasksDirText = $tasksDir
        $script:flagsPathText = $flagsPath
        $script:tempRootText = $tempRoot
        $script:goalDirText = $goalDir
        $script:genText = $gen

        function New-RXKernelTask {
            param([string]$Id)
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $script:tempRootText
            Assert-RX ([bool]$c.ok) ('[F] kernel task created ' + $Id) ([string]$c.error)
            $slot = Get-OrchestrationGoal -GoalId 'rx-goal-1' -StoreDir $script:goalDirText
            $add = Add-OrchestrationGoalTaskPersisted -GoalId 'rx-goal-1' -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:goalDirText -OwnerId 'planner-1' -OwnershipGeneration $script:genText
            Assert-RX ([bool]$add.ok) ('[F] task attached ' + $Id) ([string]$add.reason)
        }

        function New-RXIntent {
            param([string]$Task, [string]$Key, [string]$Owner = 'planner-1', [long]$Gen = 0)
            $gg = $Gen
            if ($gg -lt 1) { $gg = $script:genText }
            return (New-OrchestrationNativeDispatchIntent -TaskId $Task -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $script:phText `
                -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $Key `
                -Owner $Owner -OwnershipGeneration $gg -BaseRevision 'rev-a')
        }
        $script:phText = $ph

        function New-RXReceiptPath {
            param([string]$GoalId, [string]$Key)
            try {
                # F3/REV5: recibos isolados por goal autorizado.
                $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $GoalId
                return (Join-Path $sub ($Key + '.json'))
            }
            catch { return (Join-Path $receiptDir ($Key + '.json')) }
        }

        function New-RXSpy {
            param([string]$Token = 'candidate_pass')
            $st = @{ calls = 0 }
            $spy = { param($i) $st.calls++; return @{ status = $Token; claimed_evidence = @('criterion:0') } }.GetNewClosure()
            return @{ state = $st; spy = $spy }
        }

        # Asserts the three invariants shared by every R3 refusal.
        function Assert-RXRefusal {
            param($Result, $SpyState, [string]$Reason, [string]$Name, [string]$ReceiptPath)
            Assert-RX (((-not [bool]$Result.ok) -and ([string]$Result.reason -ceq $Reason) -and ([int]$Result.executor_calls -eq 0) -and ([int]$SpyState.calls -eq 0))) ($Name + ' refuses with ' + $Reason) (([string]$Result.reason) + ' calls=' + [string]$SpyState.calls)
            Assert-RX ($null -eq $Result.worker_result) ($Name + ' leaks no worker result') ''
            Assert-RX (([string]$Result.evidence_id -ceq '')) ($Name + ' leaks no evidence id') ([string]$Result.evidence_id)
            if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
                Assert-RX (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) ($Name + ' keeps the receipt file') ''
            }
        }

        function Test-RXPreserved {
            param([string]$Path, [byte[]]$Before, [string]$Name)
            $after = [IO.File]::ReadAllBytes($Path)
            $same = (@($after).Count -eq @($Before).Count)
            if ($same) {
                for ($i = 0; $i -lt @($after).Count; $i++) { if ([int]$after[$i] -ne [int]$Before[$i]) { $same = $false; break } }
            }
            Assert-RX $same ($Name + ' preserves the receipt byte for byte') ('before=' + @($Before).Count + ' after=' + @($after).Count)
        }

        # ---------- R3a: proven absence is the only path to a new dispatch ----------
        New-RXKernelTask -Id 'rx-task-absent'
        $absentKey = Get-NativeDispatchHash32 'rx-absent-1'
        $absentIntent = New-RXIntent -Task 'rx-task-absent' -Key $absentKey
        $absentSpy = New-RXSpy -Token 'candidate_pass'
        $rAbsent = Invoke-OrchestrationNativeDispatch -Intent $absentIntent.intent -Executor $absentSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX (([bool]$rAbsent.ok) -and ([int]$rAbsent.executor_calls -eq 1) -and ([int]$absentSpy.state.calls -eq 1)) '[R3a] proven absence (no file) allows a fresh dispatch' ([string]$rAbsent.reason)
        $absentPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $absentKey)
        $absentRec = ConvertFrom-Json ([IO.File]::ReadAllText($absentPath, [Text.Encoding]::UTF8))
        Assert-RX (([string]$absentRec.phase -ceq 'settled') -and ([bool]$absentRec.ok)) '[R3a] fresh dispatch settles its own receipt' ([string]$absentRec.phase)

        # ---------- R3b..R3f: unreadable/invalid receipts never dispatch ----------
        $badKey = Get-NativeDispatchHash32 'rx-truncated-1'
        New-RXKernelTask -Id 'rx-task-trunc'
        $truncIntent = New-RXIntent -Task 'rx-task-trunc' -Key $badKey
        $truncPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $badKey)
        $truncText = '{"schema_version":1,"idempotency_key":"' + $badKey + '","phase":"pend'
        [IO.File]::WriteAllText($truncPath, $truncText, [Text.UTF8Encoding]::new($false))
        $truncBefore = [IO.File]::ReadAllBytes($truncPath)
        $truncSpy = New-RXSpy
        $rTrunc = Invoke-OrchestrationNativeDispatch -Intent $truncIntent.intent -Executor $truncSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RXRefusal -Result $rTrunc -SpyState $truncSpy.state -Reason 'receipt-json-invalid' -Name '[R3b] truncated JSON' -ReceiptPath $truncPath
        Test-RXPreserved -Path $truncPath -Before $truncBefore -Name '[R3b] truncated JSON'

        # key divergent from the filename
        $divKey = Get-NativeDispatchHash32 'rx-keydiv-1'
        $otherKey = Get-NativeDispatchHash32 'rx-keydiv-other'
        New-RXKernelTask -Id 'rx-task-keydiv'
        $divIntent = New-RXIntent -Task 'rx-task-keydiv' -Key $divKey
        $divPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $divKey)
        $divRec = [ordered]@{
            schema_version = 1; idempotency_key = $otherKey; phase = 'pending'
            task_id = 'rx-task-keydiv'; agent = 'coder'; owner = 'planner-1'
            goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1
            intent_fingerprint = (Get-NDIntentFingerprint -Intent $divIntent.intent)
            external_idempotent = $false; reconciled = $false
            created_at = ([DateTime]::UtcNow.ToString('o'))
        }
        [IO.File]::WriteAllText($divPath, (ConvertTo-Json -InputObject $divRec -Compress), [Text.UTF8Encoding]::new($false))
        $divBefore = [IO.File]::ReadAllBytes($divPath)
        $divSpy = New-RXSpy
        $rDiv = Invoke-OrchestrationNativeDispatch -Intent $divIntent.intent -Executor $divSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RXRefusal -Result $rDiv -SpyState $divSpy.state -Reason 'receipt-key-mismatch' -Name '[R3c] key divergent from filename' -ReceiptPath $divPath
        Test-RXPreserved -Path $divPath -Before $divBefore -Name '[R3c] key divergent from filename'

        # schema unknown
        $schKey = Get-NativeDispatchHash32 'rx-schema-1'
        New-RXKernelTask -Id 'rx-task-schema'
        $schIntent = New-RXIntent -Task 'rx-task-schema' -Key $schKey
        $schPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $schKey)
        $schRec = [ordered]@{
            schema_version = 2; idempotency_key = $schKey; phase = 'pending'
            task_id = 'rx-task-schema'; agent = 'coder'; owner = 'planner-1'
            goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1
            intent_fingerprint = (Get-NDIntentFingerprint -Intent $schIntent.intent)
            external_idempotent = $false; reconciled = $false
            created_at = ([DateTime]::UtcNow.ToString('o'))
        }
        [IO.File]::WriteAllText($schPath, (ConvertTo-Json -InputObject $schRec -Compress), [Text.UTF8Encoding]::new($false))
        $schBefore = [IO.File]::ReadAllBytes($schPath)
        $schSpy = New-RXSpy
        $rSch = Invoke-OrchestrationNativeDispatch -Intent $schIntent.intent -Executor $schSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RXRefusal -Result $rSch -SpyState $schSpy.state -Reason 'receipt-schema-unknown' -Name '[R3f] unknown schema' -ReceiptPath $schPath
        Test-RXPreserved -Path $schPath -Before $schBefore -Name '[R3f] unknown schema'

        # phase absent / unknown (same reason class, distinct receipts)
        $phaseCases = @(
            @{ tag = '[R3d] absent phase'; seed = 'rx-nophase-1'; task = 'rx-task-nophase'; phase = $null }
            @{ tag = '[R3e] unknown phase'; seed = 'rx-badphase-1'; task = 'rx-task-badphase'; phase = 'settling' }
        )
        foreach ($pc in @($phaseCases)) {
            $pcKey = Get-NativeDispatchHash32 ([string]$pc.seed)
            New-RXKernelTask -Id ([string]$pc.task)
            $pcIntent = New-RXIntent -Task ([string]$pc.task) -Key $pcKey
            $pcRec = [ordered]@{
                schema_version = 1; idempotency_key = $pcKey
                task_id = ([string]$pc.task); agent = 'coder'; owner = 'planner-1'
                goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1
                intent_fingerprint = (Get-NDIntentFingerprint -Intent $pcIntent.intent)
                external_idempotent = $false; reconciled = $false
                created_at = ([DateTime]::UtcNow.ToString('o'))
            }
            if ($null -ne $pc.phase) { $pcRec['phase'] = ([string]$pc.phase) }
            $pcPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $pcKey)
            [IO.File]::WriteAllText($pcPath, (ConvertTo-Json -InputObject $pcRec -Compress), [Text.UTF8Encoding]::new($false))
            $pcBefore = [IO.File]::ReadAllBytes($pcPath)
            $pcSpy = New-RXSpy
            $rPc = Invoke-OrchestrationNativeDispatch -Intent $pcIntent.intent -Executor $pcSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
            Assert-RXRefusal -Result $rPc -SpyState $pcSpy.state -Reason 'receipt-phase-unknown' -Name ([string]$pc.tag) -ReceiptPath $pcPath
            Test-RXPreserved -Path $pcPath -Before $pcBefore -Name ([string]$pc.tag)
        }

        # reconcile path also refuses an unreadable receipt instead of settling it
        $recKey = Get-NativeDispatchHash32 'rx-reconcile-bad-1'
        New-RXKernelTask -Id 'rx-task-recbad'
        $recIntent = New-RXIntent -Task 'rx-task-recbad' -Key $recKey
        $recPath = (New-RXReceiptPath -GoalId 'rx-goal-1' -Key $recKey)
        [IO.File]::WriteAllText($recPath, '{"schema_version":1,"idempotency_key":"' + $recKey + '","phase":"pend', [Text.UTF8Encoding]::new($false))
        $recBefore = [IO.File]::ReadAllBytes($recPath)
        $badOutcome = @{ ok = $true; reason = 'invented'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        $rRecBad = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $recKey -Outcome $badOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-RX (((-not [bool]$rRecBad.ok) -and ([string]$rRecBad.reason -ceq 'receipt-json-invalid') -and ([int]$rRecBad.executor_calls -eq 0))) '[R3g] reconciliation refuses an unreadable receipt' ([string]$rRecBad.reason)
        Test-RXPreserved -Path $recPath -Before $recBefore -Name '[R3g] reconciliation of unreadable receipt'

        # ---------- F1 (REV5): fase variante e canonicalizada na leitura ----------
        # Antes do fix, a leitura normalizava a fase para decidir se o
        # recibo era valido, mas DEVOLVIA o objeto original. O consumidor
        # comparava a forma bruta com -ceq 'pending'/'settled' e um recibo
        # 'PENDING' ou ' pending ' escorregava para o caminho de dispatch
        # novo: recibo existente + Executor chamado (efeito duplicado).
        $f1Cases = @(
            @{ tag = '[F1a] SETTLED (maiusculas)'; seed = 'rx-f1-settled'; task = 'rx-task-f1a'; phase = 'SETTLED'; expect = 'idempotent-duplicate' }
            @{ tag = '[F1b] pending (minusculas)'; seed = 'rx-f1-pending'; task = 'rx-task-f1b'; phase = 'pending'; expect = 'pending-ambiguous' }
            @{ tag = '[F1c] pending com padding'; seed = 'rx-f1-pad'; task = 'rx-task-f1c'; phase = ' pending '; expect = 'pending-ambiguous' }
        )
        foreach ($f1 in @($f1Cases)) {
            $f1Key = Get-NativeDispatchHash32 ([string]$f1.seed)
            New-RXKernelTask -Id ([string]$f1.task)
            $f1Intent = New-RXIntent -Task ([string]$f1.task) -Key $f1Key
            $f1Dir = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-1'
            $f1Path = Join-Path $f1Dir ($f1Key + '.json')
            $f1Rec = [ordered]@{
                schema_version = 1; idempotency_key = $f1Key
                phase = ([string]$f1.phase)
                task_id = ([string]$f1.task); agent = 'coder'; owner = 'planner-1'
                goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1
                intent_fingerprint = (Get-NDIntentFingerprint -Intent $f1Intent.intent)
                external_idempotent = $false; reconciled = $false
                created_at = ([DateTime]::UtcNow.ToString('o'))
            }
            [IO.File]::WriteAllText($f1Path, (ConvertTo-Json -InputObject $f1Rec -Compress), [Text.UTF8Encoding]::new($false))
            $f1Before = [IO.File]::ReadAllBytes($f1Path)
            $readF1 = Read-NDReceipt -Dir $f1Dir -Key $f1Key
            $f1RecObj = Get-NDValue $readF1 'receipt' $null
            $f1Canon = ([string]$f1.phase).Trim().ToLowerInvariant()
            $f1Phase = [string](Get-NDValue $f1RecObj 'phase' '')
            $f1Task = [string](Get-NDValue $f1RecObj 'task_id' '')
            $f1Fp = [string](Get-NDValue $f1RecObj 'intent_fingerprint' '')
            Assert-RX ((([bool]$readF1.ok) -and ($f1Phase -ceq $f1Canon) -and ($f1Task -ceq ([string]$f1.task)) -and ($f1Fp -cmatch '^[a-f0-9]{32}$'))) ([string]$f1.tag + ' is read as the canonical phase, other fields preserved') ([string]$readF1.reason + ' phase=' + $f1Phase)
            $f1Spy = New-RXSpy
            $rF1 = Invoke-OrchestrationNativeDispatch -Intent $f1Intent.intent -Executor $f1Spy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
            Assert-RXRefusal -Result $rF1 -SpyState $f1Spy.state -Reason ([string]$f1.expect) -Name ([string]$f1.tag) -ReceiptPath $f1Path
            Test-RXPreserved -Path $f1Path -Before $f1Before -Name ([string]$f1.tag)
        }

        # ---------- F2 (REV5): entrada nao-arquivo no caminho do recibo ----------
        # <key>.json como diretorio nao pode ser confundido com ausencia:
        # Move-Item -Force moveria o temporario para DENTRO do diretorio e
        # devolveria sucesso, admitindo o Executor sem recibo persistido.
        New-RXKernelTask -Id 'rx-task-dirreceipt'
        $dirKey = Get-NativeDispatchHash32 'rx-receipt-dir-1'
        $dirIntent = New-RXIntent -Task 'rx-task-dirreceipt' -Key $dirKey
        $dirGoal = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-1'
        $dirPath = Join-Path $dirGoal ($dirKey + '.json')
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        $decoyPath = Join-Path $dirPath 'decoy.json'
        [IO.File]::WriteAllText($decoyPath, '{"decoy":true}', [Text.UTF8Encoding]::new($false))
        $dirSpy = New-RXSpy
        $rDirPath = Invoke-OrchestrationNativeDispatch -Intent $dirIntent.intent -Executor $dirSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX (((-not [bool]$rDirPath.ok) -and ([string]$rDirPath.reason -ceq 'receipt-not-regular') -and ([int]$rDirPath.executor_calls -eq 0) -and ([int]$dirSpy.state.calls -eq 0))) '[F2] directory on the receipt path refuses with 0 calls' ([string]$rDirPath.reason + ' calls=' + [string]$dirSpy.state.calls)
        Assert-RX (($null -eq $rDirPath.worker_result) -and ([string]$rDirPath.evidence_id -ceq '')) '[F2] directory refusal leaks no content' ''
        Assert-RX ((Test-Path -LiteralPath $dirPath -PathType Container)) '[F2] the receipt path stays a directory' ''
        Assert-RX ((Test-Path -LiteralPath $decoyPath -PathType Leaf) -and (@(Get-ChildItem -LiteralPath $dirPath -Force).Count -eq 1)) '[F2] no temp was moved inside the directory' ''
        $readDir = Read-NDReceipt -Dir $dirGoal -Key $dirKey
        Assert-RX (((-not [bool]$readDir.ok) -and ([string]$readDir.reason -ceq 'receipt-not-regular') -and ([bool]$readDir.present))) '[F2] reading a non-regular entry is not absence' ([string]$readDir.reason)
        # escrita exige destino EXATAMENTE arquivo
        $dirWriteRec = [ordered]@{ schema_version = 1; idempotency_key = $dirKey; phase = 'pending'; task_id = 'rx-task-dirreceipt'; agent = 'coder'; owner = 'planner-1'; goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent $dirIntent.intent); external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        Assert-RX ((-not (Write-NDReceipt -Dir $dirGoal -Receipt $dirWriteRec))) '[F2] write refuses to target a directory' ''
        Assert-RX ((Test-Path -LiteralPath $dirPath -PathType Container) -and (@(Get-ChildItem -LiteralPath $dirPath -Force).Count -eq 1)) '[F2] refused write moved nothing and left no temp' ''
        $okWriteKey = Get-NativeDispatchHash32 'rx-receipt-okwrite-1'
        $okWriteRec = [ordered]@{ schema_version = 1; idempotency_key = $okWriteKey; phase = 'pending'; task_id = 'rx-task-dirreceipt'; agent = 'coder'; owner = 'planner-1'; goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent $dirIntent.intent); external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        Assert-RX (Write-NDReceipt -Dir $dirGoal -Receipt $okWriteRec) '[F2] write to a fresh destination succeeds' ''
        $okWritePath = Join-Path $dirGoal ($okWriteKey + '.json')
        Assert-RX ((Test-Path -LiteralPath $okWritePath -PathType Leaf)) '[F2] fresh write lands exactly on the expected regular file' ''
        $okWriteBack = [IO.File]::ReadAllText($okWritePath, [Text.Encoding]::UTF8)
        Assert-RX (($okWriteBack.IndexOf($okWriteKey, [StringComparison]::Ordinal) -ge 0)) '[F2] the persisted file holds the receipt key' ''

        # ---------- RP (REV6 / SEC6 MEDIA): reparse points ----------
        # `Test-Path -PathType Leaf` aceita symlink/junction para arquivo
        # ou diretorio. Sem a checagem de ReparsePoint o link passaria e
        # o codigo leria/gravaria no ALVO. Dois fixtures reais (nunca
        # fingidos): juncao de diretorio no subdiretorio de um goal e
        # symlink de arquivo no caminho do recibo. Limpeza remove APENAS
        # o link, nunca o alvo.
        function New-RXJunction {
            param([string]$LinkPath, [string]$TargetPath)
            try { cmd /c mklink /J "$LinkPath" "$TargetPath" 2>&1 | Out-Null } catch { }
            if (Test-Path -LiteralPath $LinkPath) { return $true }
            try { New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null } catch { return $false }
            return (Test-Path -LiteralPath $LinkPath)
        }

        function New-RXFileLink {
            param([string]$LinkPath, [string]$TargetPath)
            try { cmd /c mklink "$LinkPath" "$TargetPath" 2>&1 | Out-Null } catch { }
            if (Test-Path -LiteralPath $LinkPath) { return $true }
            try { New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null } catch { return $false }
            return (Test-Path -LiteralPath $LinkPath)
        }

        function Remove-RXLink {
            param([string]$LinkPath)
            # Directory.Delete(path, $false) sobre reparse point remove o
            # LINK; rmdir e o fallback. Remove-Item -Recurse NUNCA e
            # usado: em PS 5.1 ele pode apagar o CONTEUDO do alvo.
            try { if (Test-Path -LiteralPath $LinkPath) { [IO.Directory]::Delete($LinkPath, $false) } } catch { }
            try { if (Test-Path -LiteralPath $LinkPath) { cmd /c rmdir "$LinkPath" 2>&1 | Out-Null } } catch { }
        }

        function Remove-RXFileLink {
            param([string]$LinkPath)
            try { if (Test-Path -LiteralPath $LinkPath) { [IO.File]::Delete($LinkPath) } } catch { }
            try { if (Test-Path -LiteralPath $LinkPath) { Remove-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue } } catch { }
        }

        # ---------- RP1: juncao <hash-B> -> <hash-A> (quebra F3) ----------
        function New-RXLinkFixture {
            param([string]$GoalId, [string]$TaskId, [string]$KeySeed)
            $gg = New-OrchestrationGoal -GoalId $GoalId -Objective ('reparse ' + $GoalId) -Criteria @('criterio-a') -StoreDir $goalDir
            Assert-RX ([bool]$gg.ok) ('[RP1] goal created ' + $GoalId) ([string]$gg.reason)
            $ga = Set-OrchestrationGoalState -Goal $gg.goal -ToState 'ACTIVE'
            $gs = Save-OrchestrationGoal -Goal $ga.goal -StoreDir $goalDir
            Assert-RX ([bool]$gs.ok) ('[RP1] goal active ' + $GoalId) ([string]$gs.reason)
            $go = Acquire-OrchestrationGoalOwnership -GoalId $GoalId -OwnerId 'planner-1' -ExpectedRevision ([long]$gs.revision) -StoreDir $goalDir -LeaseTtlMs 60000
            Assert-RX ([bool]$go.ok) ('[RP1] ownership acquired ' + $GoalId) ([string]$go.reason)
            $ggen = [long]$go.ownership['generation']
            $ct = New-OrchestrationTask -TaskId $TaskId -Objective ('obj ' + $TaskId) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
            Assert-RX ([bool]$ct.ok) ('[RP1] kernel task created ' + $TaskId) ([string]$ct.error)
            $slot = Get-OrchestrationGoal -GoalId $GoalId -StoreDir $goalDir
            $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $TaskId -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $ggen
            Assert-RX ([bool]$add.ok) ('[RP1] task attached ' + $TaskId) ([string]$add.reason)
            $kk = Get-NativeDispatchHash32 $KeySeed
            $intent = New-RXIntent -Task $TaskId -Key $kk -Gen $ggen
            Assert-RX ([bool]$intent.ok) ('[RP1] intent built ' + $TaskId) ([string]$intent.reason)
            return @{ goal = $GoalId; gen = $ggen; task = $TaskId; key = $kk; intent = $intent }
        }

        $rxLinkB = New-RXLinkFixture -GoalId 'rx-goal-link-b' -TaskId 'rx-task-link' -KeySeed 'rx-link-key-1'
        $physA = Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-link-a')
        $linkB = Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-link-b')
        $junctionOk = $false
        try {
            New-Item -ItemType Directory -Path $physA -Force | Out-Null
            # recibo settled de A, na MESMA key que B vai consultar: se B
            # lesse atraves da juncao, a resposta seria 'already-settled'.
            $settledA = [ordered]@{
                schema_version = 1; idempotency_key = [string]$rxLinkB.key; phase = 'settled'
                task_id = 'rx-task-link'; agent = 'coder'; owner = 'planner-1'
                goal_id = 'rx-goal-link-a'; ownership_generation = 1; task_expected_revision = 1
                intent_fingerprint = (Get-NDIntentFingerprint -Intent $rxLinkB.intent.intent)
                reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o'))
            }
            [IO.File]::WriteAllText((Join-Path $physA ([string]$rxLinkB.key + '.json')), (ConvertTo-Json -InputObject $settledA -Compress), [Text.UTF8Encoding]::new($false))
            $junctionOk = New-RXJunction -LinkPath $linkB -TargetPath $physA
        }
        catch { $junctionOk = $false }
        if ($junctionOk) {
            try {
                $resState = Resolve-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-link-b'
                Assert-RX (((-not [bool]$resState.ok) -and ([string]$resState.reason -ceq 'receipt-dir-reparse-point') -and ([string]$resState.dir -ceq ''))) '[RP1] junction in the goal receipt subdir is refused' ([string]$resState.reason)
                Assert-RX (([string](Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-link-b') -ceq '')) '[RP1] string resolver returns empty for a linked subdir' ''
                Assert-RX ((-not (Test-NDPathWithoutReparsePoint -Path $linkB))) '[RP1] junction is not a path without reparse point' ''
                Assert-RX ((Test-NDPathWithoutReparsePoint -Path $physA) -and (Test-NDPathWithoutReparsePoint -Path $dirGoal)) '[RP1] regular directories and files pass the reparse guard' ''
                $linkSpy = New-RXSpy
                $rLink = Invoke-OrchestrationNativeDispatch -Intent $rxLinkB.intent.intent -Executor $linkSpy.spy -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-link-b'; owner = 'planner-1'; generation = [long]$rxLinkB.gen; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
                Assert-RX (((-not [bool]$rLink.ok) -and ([string]$rLink.reason -ceq 'receipt-dir-reparse-point') -and ([bool]$rLink.admitted) -and ([int]$rLink.executor_calls -eq 0) -and ([int]$linkSpy.state.calls -eq 0))) '[RP1] dispatch through the junction refuses without reading goal A receipt' ([string]$rLink.reason + ' calls=' + [string]$linkSpy.state.calls)
                Assert-RX ([string]$rLink.reason -cne 'already-settled') '[RP1] refusal never comes from reading the other goal receipt' ([string]$rLink.reason)
                Assert-RX (($null -eq $rLink.worker_result) -and ([string]$rLink.evidence_id -ceq '')) '[RP1] junction refusal leaks no receipt content' ''
                $rLinkC = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey ([string]$rxLinkB.key) -Outcome @{ ok = $true; reason = 'r6-probe'; evidence_id = ''; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } } -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-link-b'; owner = 'planner-1'; generation = [long]$rxLinkB.gen; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
                Assert-RX (((-not [bool]$rLinkC.ok) -and ([string]$rLinkC.reason -ceq 'receipt-dir-reparse-point') -and ([int]$rLinkC.executor_calls -eq 0) -and (-not [bool]$rLinkC.reconciled))) '[RP1] Confirm through the junction refuses too' ([string]$rLinkC.reason)
                # nada vazou para o diretorio FISICO de A
                $physAFiles = @(Get-ChildItem -LiteralPath $physA -Force -File -ErrorAction SilentlyContinue)
                Assert-RX ((@($physAFiles).Count -eq 1) -and (@($physAFiles)[0].Name -ceq ([string]$rxLinkB.key + '.json'))) '[RP1] physical directory of A keeps exactly the seeded receipt' ([string]@($physAFiles).Count)
                Assert-RX ((-not (Test-Path -LiteralPath (Join-Path $physA '.dispatch.lock')))) '[RP1] no lock was created inside the physical directory of A' ''
                $aBack = [IO.File]::ReadAllText((Join-Path $physA ([string]$rxLinkB.key + '.json')), [Text.Encoding]::UTF8)
                Assert-RX (($aBack.IndexOf('rx-goal-link-a', [StringComparison]::Ordinal) -ge 0) -and ($aBack.IndexOf('reconciled_by', [StringComparison]::Ordinal) -lt 0)) '[RP1] the receipt of A was not rewritten by goal B' ''
            }
            finally { Remove-RXLink -LinkPath $linkB }
        }
        else { Skip-RX 'RP1 junction fixture unavailable in this environment' }

        # ---------- RP2: symlink de arquivo no caminho do recibo -------
        # Aqui o Pre-fix passava: Test-Path -PathType Leaf aceita o link,
        # a leitura seguiria o alvo e a escrita sobrescreveria o arquivo
        # FORA do diretorio do goal.
        New-RXKernelTask -Id 'rx-task-symlink'
        $symKey = Get-NativeDispatchHash32 'rx-symlink-key-1'
        $symIntent = New-RXIntent -Task 'rx-task-symlink' -Key $symKey
        $symTarget = Join-Path $tempRoot 'rx-target-fora-do-namespace.json'
        $symPath = Join-Path $dirGoal ($symKey + '.json')
        $symOk = $false
        try {
            $symContent = '{"schema_version":1,"idempotency_key":"' + $symKey + '","phase":"settled","task_id":"rx-task-symlink","agent":"coder","owner":"planner-1","goal_id":"rx-goal-1","ownership_generation":' + [string]$gen + ',"task_expected_revision":1,"intent_fingerprint":"' + (Get-NDIntentFingerprint -Intent $symIntent.intent) + '","reconciled":false,"created_at":"o"}'
            [IO.File]::WriteAllText($symTarget, $symContent, [Text.UTF8Encoding]::new($false))
            $symOk = New-RXFileLink -LinkPath $symPath -TargetPath $symTarget
        }
        catch { $symOk = $false }
        if ($symOk) {
            try {
                $symBefore = [IO.File]::ReadAllBytes($symTarget)
                Assert-RX ((Test-Path -LiteralPath $symPath -PathType Leaf)) '[RP2] fixture: the symlink still looks like a regular file to PathType Leaf' ''
                Assert-RX ((-not (Test-NDPathWithoutReparsePoint -Path $symPath))) '[RP2] file symlink is not a path without reparse point' ''
                $readSym = Read-NDReceipt -Dir $dirGoal -Key $symKey
                Assert-RX (((-not [bool]$readSym.ok) -and ([string]$readSym.reason -ceq 'receipt-not-regular') -and ([bool]$readSym.present) -and ($null -eq $readSym.receipt))) '[RP2] reading a linked receipt is refused, the target is not the receipt' ([string]$readSym.reason)
                $symWriteRec = [ordered]@{ schema_version = 1; idempotency_key = $symKey; phase = 'pending'; task_id = 'rx-task-symlink'; agent = 'coder'; owner = 'planner-1'; goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent $symIntent.intent); external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
                Assert-RX ((-not (Write-NDReceipt -Dir $dirGoal -Receipt $symWriteRec))) '[RP2] write refuses a linked destination' ''
                $symAfter = [IO.File]::ReadAllBytes($symTarget)
                $symSame = ((@($symAfter).Count -eq @($symBefore).Count))
                if ($symSame) { for ($i = 0; $i -lt @($symAfter).Count; $i++) { if ([int]$symAfter[$i] -ne [int]$symBefore[$i]) { $symSame = $false; break } } }
                Assert-RX $symSame '[RP2] the linked target was NOT overwritten (no effect leaked outside)' 'target changed'
                Assert-RX ((@(Get-ChildItem -LiteralPath $dirGoal -Force -File -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -eq 0)) '[RP2] refused write left no temp behind' ''
                $symSpy = New-RXSpy
                $rSym = Invoke-OrchestrationNativeDispatch -Intent $symIntent.intent -Executor $symSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
                Assert-RX (((-not [bool]$rSym.ok) -and ([string]$rSym.reason -ceq 'receipt-not-regular') -and ([int]$rSym.executor_calls -eq 0) -and ([int]$symSpy.state.calls -eq 0))) '[RP2] dispatch on a linked receipt refuses with 0 calls' ([string]$rSym.reason + ' calls=' + [string]$symSpy.state.calls)
                Assert-RX (($null -eq $rSym.worker_result) -and ([string]$rSym.evidence_id -ceq '')) '[RP2] linked receipt refusal leaks no content' ''
            }
            finally { Remove-RXFileLink -LinkPath $symPath }
        }
        else { Skip-RX 'RP2 file symlink fixture unavailable in this environment' }

        # ---------- R2a: goal left ACTIVE refuses the settled duplicate ----------
        New-RXKernelTask -Id 'rx-task-pause'
        $pauseKey = Get-NativeDispatchHash32 'rx-pause-1'
        $pauseIntent = New-RXIntent -Task 'rx-task-pause' -Key $pauseKey
        $pauseSpy = New-RXSpy
        $rPause1 = Invoke-OrchestrationNativeDispatch -Intent $pauseIntent.intent -Executor $pauseSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX ([bool]$rPause1.ok) '[R2a] first dispatch settles while ACTIVE' ([string]$rPause1.reason)
        $pauseLive = Get-OrchestrationGoal -GoalId 'rx-goal-1' -StoreDir $goalDir
        $pause = Set-OrchestrationGoalStatePersisted -GoalId 'rx-goal-1' -ToState 'PAUSED' -ExpectedRevision ([long]$pauseLive.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        Assert-RX ([bool]$pause.ok) '[R2a] goal paused after the settled receipt' ([string]$pause.reason)
        $pausedSpy = New-RXSpy
        $rPausedDup = Invoke-OrchestrationNativeDispatch -Intent $pauseIntent.intent -Executor $pausedSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RXRefusal -Result $rPausedDup -SpyState $pausedSpy.state -Reason 'duplicate-identity-mismatch' -Name '[R2a] non-ACTIVE goal' -ReceiptPath ((New-RXReceiptPath -GoalId 'rx-goal-1' -Key $pauseKey))
        Assert-RX ((-not [bool]$rPausedDup.duplicate)) '[R2a] non-ACTIVE goal is not a duplicate read' ''
        $resumeLive = Get-OrchestrationGoal -GoalId 'rx-goal-1' -StoreDir $goalDir
        $resume = Set-OrchestrationGoalStatePersisted -GoalId 'rx-goal-1' -ToState 'ACTIVE' -ExpectedRevision ([long]$resumeLive.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen
        Assert-RX ([bool]$resume.ok) '[R2a] goal back to ACTIVE' ([string]$resume.reason)
        $backSpy = New-RXSpy
        $rBack = Invoke-OrchestrationNativeDispatch -Intent $pauseIntent.intent -Executor $backSpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX ((([bool]$rBack.duplicate) -and ([int]$backSpy.state.calls -eq 0) -and ([string]$rBack.reason -ceq 'idempotent-duplicate'))) '[R2a] ACTIVE same owner still reads the duplicate' ([string]$rBack.reason)

        # ---------- R2b: takeover/expiry between authorization and the lock ----------
        # Fixture order matters: the kernel task is created BEFORE the
        # short lease is acquired, so the lease only has to cover the
        # attach + one dispatch (renewed right before the dispatch).
        $tk = New-OrchestrationGoal -GoalId 'rx-goal-take' -Objective 'ownership stale' -Criteria @('criterio-a') -StoreDir $goalDir
        $atk = Set-OrchestrationGoalState -Goal $tk.goal -ToState 'ACTIVE'
        $stk = Save-OrchestrationGoal -Goal $atk.goal -StoreDir $goalDir
        $ctk = New-OrchestrationTask -TaskId 'rx-task-take1' -Objective 'obj take1' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-RX ([bool]$ctk.ok) '[R2b] takeover kernel task created' ([string]$ctk.error)
        $otk = Acquire-OrchestrationGoalOwnership -GoalId 'rx-goal-take' -OwnerId 'planner-1' -ExpectedRevision ([long]$stk.revision) -StoreDir $goalDir -LeaseTtlMs 3000
        Assert-RX ([bool]$otk.ok) '[R2b] takeover goal owned with short lease' ([string]$otk.reason)
        $genTk = [long]$otk.ownership['generation']
        $slotTk = Get-OrchestrationGoal -GoalId 'rx-goal-take' -StoreDir $goalDir
        $addTk = Add-OrchestrationGoalTaskPersisted -GoalId 'rx-goal-take' -TaskId 'rx-task-take1' -ExpectedRevision ([long]$slotTk.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $genTk
        Assert-RX ([bool]$addTk.ok) '[R2b] takeover task attached' ([string]$addTk.reason)
        $tkKey = Get-NativeDispatchHash32 'rx-take-1'
        # The settled receipt deliberately carries NO worker_result (worker
        # status refused), so no takeover read can be justified by proof.
        $tkIntent = New-RXIntent -Task 'rx-task-take1' -Key $tkKey -Gen $genTk
        $renTk = Renew-OrchestrationGoalOwnership -GoalId 'rx-goal-take' -OwnerId 'planner-1' -Generation $genTk -StoreDir $goalDir -LeaseTtlMs 3000
        Assert-RX ([bool]$renTk.ok) '[R2b] lease refreshed right before the dispatch' ([string]$renTk.reason)
        $tkEvil = New-RXSpy -Token 'verified_pass'
        $rTk1 = Invoke-OrchestrationNativeDispatch -Intent $tkIntent.intent -Executor $tkEvil.spy -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-take'; owner = 'planner-1'; generation = $genTk; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX (((-not [bool]$rTk1.ok) -and ([string]$rTk1.reason -ceq 'status-not-allowed-from-worker'))) '[R2b] takeover receipt settles as failure (no worker result)' ([string]$rTk1.reason)
        $tkPath = (New-RXReceiptPath -GoalId 'rx-goal-take' -Key $tkKey)
        if (-not (Test-Path -LiteralPath $tkPath -PathType Leaf)) {
            # Fixture failure (e.g. lease lost during setup): report one
            # clear assertion instead of aborting the whole suite.
            Assert-RX $false '[R2b] takeover receipt persisted' ([string]$rTk1.reason)
        }
        else {
        $tkBefore = [IO.File]::ReadAllBytes($tkPath)
        $tkStored = ConvertFrom-Json ([IO.File]::ReadAllText($tkPath, [Text.Encoding]::UTF8))
        Assert-RX (([string]$tkStored.phase -ceq 'settled') -and ($null -eq $tkStored.worker_result)) '[R2b] settled receipt has no worker result to leak' ''
        # provable expiry, then a NEW holder: the token that authorized the
        # first dispatch is exactly what a pre-lock authorization would
        # still carry when the duplicate read runs.
        Start-Sleep -Milliseconds 3500
        $tow = Takeover-OrchestrationGoalOwnership -GoalId 'rx-goal-take' -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 60000
        Assert-RX ([bool]$tow.ok) '[R2b] ownership taken over after provable expiry' ([string]$tow.reason)
        $genTk2 = [long]$tow.ownership['generation']
        # (i) pre-lock gate refuses the stale token outright (defense in depth)
        $staleSpy = New-RXSpy
        $rStale = Invoke-OrchestrationNativeDispatch -Intent $tkIntent.intent -Executor $staleSpy.spy -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-take'; owner = 'planner-1'; generation = $genTk; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX (((-not [bool]$rStale.ok) -and (-not [bool]$rStale.admitted) -and ([string]$rStale.reason -like 'ownership-not-held*') -and ([int]$staleSpy.state.calls -eq 0))) '[R2b] stale token is refused at the pre-lock gate' ([string]$rStale.reason)
        Assert-RX (($null -eq $rStale.worker_result) -and ([string]$rStale.evidence_id -ceq '')) '[R2b] stale token refusal leaks no content' ''
        # (ii) the SAME stale token reaching the duplicate gate (i.e. the
        # takeover happened INSIDE the authorization->lock window) must be
        # refused there too: the receipt owner is not the live owner anymore.
        $dupStale = Test-NDDuplicateReadIdentity -Receipt $tkStored -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-take'; owner = 'planner-1'; generation = $genTk; source = 'planner' } -GoalStoreDir $goalDir -TasksDir $tasksDir -RepoRoot $tempRoot
        Assert-RX (((-not [bool]$dupStale.ok) -and ([string]$dupStale.reason -ceq 'duplicate-identity-mismatch') -and (-not [bool]$dupStale.takeover))) '[R2b] stale receipt owner is refused at the duplicate gate' ([string]$dupStale.reason)
        # (iii) the live owner without kernel-side proof is still refused
        $liveSpy = New-RXSpy
        $rLive = Invoke-OrchestrationNativeDispatch -Intent $tkIntent.intent -Executor $liveSpy.spy -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-take'; owner = 'planner-2'; generation = $genTk2; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RXRefusal -Result $rLive -SpyState $liveSpy.state -Reason 'duplicate-identity-mismatch' -Name '[R2b] live owner without proof' -ReceiptPath $tkPath
        Test-RXPreserved -Path $tkPath -Before $tkBefore -Name '[R2b] refused duplicate read'
        }

        # ---------- RP3 (REV7/R1): namespace TOCTOU -------------------
        # `Resolve-NDGoalReceiptDir` valida o namespace UMA vez.
        # `Assert-NDDirIdentity` revalida antes de cada IO. Janela
        # residual documentada: PS 5.1 nao tem abertura kernel
        # sem-seguir-link, entao checagem -> IO nao e atomico.
        function New-RXSwapFixture {
            param([string]$GoalId, [string]$TaskId, [string]$KeySeed)
            return (New-RXLinkFixture -GoalId $GoalId -TaskId $TaskId -KeySeed $KeySeed)
        }

        # (a) dispatch: dentro do despacho, DEPOIS da resolucao e da
        #     escrita do pending, a identidade do diretorio de recibos
        #     deixa de conferir. O Executor e o unico ponto de
        #     interposicao do fluxo; a troca por rename/junction DURANTE
        #     o despacho e negada pelo proprio sistema operacional
        #     enquanto o lock do recibo (FileShare.None) esta aberto
        #     (verificado: Directory.Move/Delete e Move-Item falham com
        #     "being used by another process" - o lock e a primeira
        #     barreira). O estado que a revalidacao pega e o de
        #     identidade DIVERGENTE: a mutacao do CreationTimeUtc
        #     reproduz esse estado sem derrubar o lock. A escrita settled
        #     tem de recusar antes de criar temp/Move e o recibo em
        #     disco tem de continuar byte-a-byte o pending anterior.
        $swapA = New-RXSwapFixture -GoalId 'rx-goal-swap-a' -TaskId 'rx-task-swap-a' -KeySeed 'rx-swap-key-a'
        $swapADir = Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-swap-a')
        $swapAPath = Join-Path $swapADir ([string]$swapA.key + '.json')
        $swapAState = @{ done = $false; dir = $swapADir; path = $swapAPath; before = $null }
        $swapAExec = { param($i)
            if (-not $swapAState.done) {
                $swapAState.done = $true
                # snapshot do pending ANTES de alterar a identidade
                $swapAState.before = [IO.File]::ReadAllBytes($swapAState.path)
                [IO.Directory]::SetCreationTimeUtc($swapAState.dir, [DateTime]::UtcNow.AddDays(-1))
            }
            return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        $rSwapA = Invoke-OrchestrationNativeDispatch -Intent $swapA.intent.intent -Executor $swapAExec -Authorization @{ explicit_allow = $true; goal_id = 'rx-goal-swap-a'; owner = 'planner-1'; generation = [long]$swapA.gen; source = 'planner' } -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX (((-not [bool]$rSwapA.ok) -and ([string]$rSwapA.reason -ceq 'receipt-dir-identity-changed') -and ([int]$rSwapA.executor_calls -eq 1))) '[RP3a] identity changed mid-dispatch refuses the settled write' ([string]$rSwapA.reason + ' calls=' + [string]$rSwapA.executor_calls)
        $swapAAfter = [IO.File]::ReadAllBytes($swapAPath)
        $swapASame = ((@($swapAAfter).Count -eq @($swapAState.before).Count))
        if ($swapASame) { for ($i = 0; $i -lt @($swapAAfter).Count; $i++) { if ([int]$swapAAfter[$i] -ne [int]$swapAState.before[$i]) { $swapASame = $false; break } } }
        Assert-RX ($swapASame) '[RP3a] refusal did zero write IO after the identity change (pending bytes intact)' ('before=' + @($swapAState.before).Count + ' after=' + @($swapAAfter).Count)
        $swapAStored = ConvertFrom-Json ([IO.File]::ReadAllText($swapAPath, [Text.Encoding]::UTF8))
        Assert-RX (([string]$swapAStored.phase -ceq 'pending')) '[RP3a] the receipt stays pending (nothing settled under the new identity)' ([string]$swapAStored.phase)
        $swapATemps = @(Get-ChildItem -LiteralPath $swapADir -Force -File -Filter '*.tmp' -ErrorAction SilentlyContinue)
        Assert-RX ((@($swapATemps).Count -eq 0)) '[RP3a] no temp left behind by the refused write' ([string]@($swapATemps).Count)

        # (b) helpers chamados DIRETAMENTE com diretorio junctionado: e a
        #     mesma superficie (`Assert-NDDirIdentity` + Read/Write/Lock)
        #     que o despacho usa, entao a recusa aqui vale para o caminho
        #     do dispatch. A juncao representa `<hash-B>` -> `<hash-A>`
        #     criada depois de uma resolucao contra B.
        $directTarget = Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-direct-target')
        $directGoal = New-RXSwapFixture -GoalId 'rx-goal-direct-link' -TaskId 'rx-task-direct-link' -KeySeed 'rx-direct-key-1'
        $directDir = Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-direct-link')
        $directOk = $false
        try {
            New-Item -ItemType Directory -Path $directTarget -Force | Out-Null
            $directOk = New-RXJunction -LinkPath $directDir -TargetPath $directTarget
        }
        catch { $directOk = $false }
        if ($directOk) {
            try {
                $directKey = [string]$directGoal.key
                $directRead = Read-NDReceipt -Dir $directDir -Key $directKey
                Assert-RX (((-not [bool]$directRead.ok) -and ([string]$directRead.reason -ceq 'receipt-dir-reparse-point') -and (-not [bool]$directRead.present))) '[RP3b] direct read on a junctioned dir refuses' ([string]$directRead.reason)
                $directRead2 = Read-NDReceipt -Dir $directDir -Key $directKey -Expected '1'
                Assert-RX (((-not [bool]$directRead2.ok) -and ([string]$directRead2.reason -ceq 'receipt-dir-reparse-point'))) '[RP3b] direct read with Expected refuses the junction too' ([string]$directRead2.reason)
                $directWriteRec = [ordered]@{ schema_version = 1; idempotency_key = $directKey; phase = 'pending'; task_id = 'rx-task-direct-link'; agent = 'coder'; owner = 'planner-1'; goal_id = 'rx-goal-direct-link'; ownership_generation = 1; task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent $directGoal.intent.intent); external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
                Assert-RX ((-not (Write-NDReceipt -Dir $directDir -Receipt $directWriteRec))) '[RP3b] direct write on a junctioned dir refuses' ''
                Assert-RX ((-not (Write-NDReceipt -Dir $directDir -Receipt $directWriteRec -Expected '1'))) '[RP3b] direct write with Expected refuses the junction too' ''
                $directLock = Open-NDReceiptLock -Dir $directDir -LockTimeoutMs 200
                Assert-RX (($null -eq $directLock)) '[RP3b] direct lock on a junctioned dir refuses' ''
                $directLock2 = Open-NDReceiptLock -Dir $directDir -LockTimeoutMs 200 -Expected '1'
                Assert-RX (($null -eq $directLock2)) '[RP3b] direct lock with Expected refuses the junction too' ''
                $directTargetFiles = @(Get-ChildItem -LiteralPath $directTarget -Force -ErrorAction SilentlyContinue)
                Assert-RX ((@($directTargetFiles).Count -eq 0)) '[RP3b] the junction target received no IO at all (no lock, no receipt, no temp)' ([string]@($directTargetFiles).Count)
            }
            finally { try { Remove-RXLink -LinkPath $directDir } catch { } }
        }
        else { Skip-RX 'RP3b direct-helper junction fixture unavailable in this environment' }

        # (c) identidade alterada: diretorio do goal RECRIADO entre a
        #     resolucao e o IO. Com a identidade capturada, os helpers
        #     recusam antes de qualquer IO no diretorio novo.
        $identKey = Get-NativeDispatchHash32 'rx-identity-1'
        $identDir = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-1'
        $identState = Resolve-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-1'
        Assert-RX (([bool]$identState.ok) -and ([string]$identState.created_utc -cmatch '^[0-9]+$')) '[RP3c] resolver captures the creation identity' ([string]$identState.created_utc)
        $identExpect = [string]$identState.created_utc
        # caminho feliz primeiro: a identidade confere
        $identOkRead = Read-NDReceipt -Dir $identDir -Key $identKey -Expected $identExpect
        Assert-RX (((-not [bool]$identOkRead.ok) -and ([string]$identOkRead.reason -ceq 'receipt-absent'))) '[RP3c] matching identity still reads the receipt path' ([string]$identOkRead.reason)
        # recria o diretorio (identidade nova) e consulta de novo
        try { [IO.Directory]::Delete($identDir, $true) } catch { }
        [IO.Directory]::CreateDirectory($identDir) | Out-Null
        $identChk = Assert-NDDirIdentity -Path $identDir -Expected $identExpect
        Assert-RX (((-not [bool]$identChk.ok) -and ([string]$identChk.reason -ceq 'receipt-dir-identity-changed'))) '[RP3c] recreated directory fails the identity reassert' ([string]$identChk.reason)
        $identBadRead = Read-NDReceipt -Dir $identDir -Key $identKey -Expected $identExpect
        Assert-RX (((-not [bool]$identBadRead.ok) -and ([string]$identBadRead.reason -ceq 'receipt-dir-identity-changed'))) '[RP3c] read refuses the recreated directory' ([string]$identBadRead.reason)
        $identBadWrite = Write-NDReceipt -Dir $identDir -Expected $identExpect -Receipt ([ordered]@{ schema_version = 1; idempotency_key = $identKey; phase = 'pending'; task_id = 'rx-absent-1'; agent = 'coder'; owner = 'planner-1'; goal_id = 'rx-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent (New-RXIntent -Task 'rx-absent-1' -Key $identKey)); external_idempotent = $false; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) })
        Assert-RX ((-not $identBadWrite)) '[RP3c] write refuses the recreated directory' ''
        $identFiles = @(Get-ChildItem -LiteralPath $identDir -Force -ErrorAction SilentlyContinue)
        Assert-RX ((@($identFiles).Count -eq 0)) '[RP3c] refused write left the recreated directory empty (no temp either)' ([string]@($identFiles).Count)
        # diretorio inexistente tambem recusa (nao confunde com ausencia)
        $identGone = Assert-NDDirIdentity -Path (Join-Path $receiptDir (Get-NativeDispatchHash32 'rx-goal-inexistente-xyz')) -Expected $identExpect
        Assert-RX (((-not [bool]$identGone.ok) -and ([string]$identGone.reason -ceq 'receipt-dir-identity-changed'))) '[RP3c] missing directory is never treated as resolved' ([string]$identGone.reason)

        # (d) caminho feliz inalterado: um dispatch comum segue assentando
        #     com as revalidacoes de identidade ligadas.
        $happyKey = Get-NativeDispatchHash32 'rx-happy-identity-1'
        New-RXKernelTask -Id 'rx-task-happy-identity'
        $happyIntent = New-RXIntent -Task 'rx-task-happy-identity' -Key $happyKey
        $happySpy = New-RXSpy -Token 'candidate_pass'
        $rHappy = Invoke-OrchestrationNativeDispatch -Intent $happyIntent.intent -Executor $happySpy.spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-RX ((([bool]$rHappy.ok) -and ([int]$rHappy.executor_calls -eq 1) -and ([int]$happySpy.state.calls -eq 1))) '[RP3d] happy path still dispatches and settles with identity checks on' ([string]$rHappy.reason + ' calls=' + [string]$happySpy.state.calls)
        $happyPath = Join-Path (Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId 'rx-goal-1') ($happyKey + '.json')
        Assert-RX ((Test-Path -LiteralPath $happyPath -PathType Leaf)) '[RP3d] happy path receipt landed on the expected regular file' ''

        # ---------- hygiene ----------
        $rxPath = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        $rxText = [IO.File]::ReadAllText($rxPath, [Text.UTF8Encoding]::new($false))
        Assert-RX ((($rxText -notmatch 'Start-Process') -and ($rxText -notmatch 'Invoke-WebRequest') -and ($rxText -notmatch 'Invoke-RestMethod'))) '[NET] no spawn/network' ''
        Assert-RX (($rxText -notmatch '(?i)\bsk-[A-Za-z0-9]{20,}')) '[SEC] no secret value' ''
        foreach ($p in @($rxPath, (Join-Path $PSScriptRoot 'OrchestrationNativeDispatchReceipts.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-RX ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (' + $script:skipped + ' skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (' + $script:skipped + ' skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
