$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
. (Join-Path $PSScriptRoot 'CapabilityObservability.ps1')

$telDir = Join-Path $repo 'cache\v3\telemetry'
$tmpFiles = @()

$total = 0
$passed = 0
$skipped = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
function Skip-That($name, $reason) {
    $script:total++
    $script:skipped++
    Write-Host "[SKIP] $name -- $reason"
}

function New-TmpTelemetry {
    $p = Join-Path $script:telDir ('tmp-obs-test-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $script:tmpFiles += $p
    return $p
}

try {
    Assert-That (Test-Path -LiteralPath (Join-Path $v3 'lib\CapabilityObservability.ps1') -PathType Leaf) 'Lib file exists' 'Missing lib'
    # Hermetico clean-room: garante o dir de telemetria do repo (ausente quando
    # a copia limpa exclui cache/); o teste so cria arquivos tmp-obs-* nele.
    New-Item -ItemType Directory -Path $telDir -Force | Out-Null

    $valid = @(Get-ObservabilityValidEventTypes)
    Assert-That ($valid.Count -eq 29) 'Enum event_type tem 29 valores' ("Got $($valid.Count)")
    foreach ($e in @('TASK_RECEIVED', 'ROUTE_EVALUATED', 'AGENT_SELECTED', 'SKILL_SELECTED', 'MCP_SELECTED', 'DISPATCHED', 'STARTED', 'TOOL_USED', 'COMPLETED', 'VALIDATED', 'REVIEWED', 'RETRY', 'ESCALATED', 'FAILED', 'DONE')) {
        Assert-That ($valid -ccontains $e) ("Enum contem $e") ($valid -join ',')
    }
    $newTypes = @('TASK_CREATED', 'TASK_STATE_CHANGED', 'TASK_CANCELLED', 'TASK_EXHAUSTED', 'TASK_DONE', 'LEASE_ACQUIRED', 'LEASE_CONFLICT', 'WORKTREE_CREATED', 'CANDIDATE_RESULT_RECORDED', 'VERIFICATION_STARTED', 'VERIFICATION_PASSED', 'VERIFICATION_FAILED', 'REVIEW_APPROVED', 'REVIEW_CHANGES_REQUIRED')
    Assert-That ($newTypes.Count -eq 14) 'Enum: 14 novos tipos Phase 18' ("Got $($newTypes.Count)")
    foreach ($e in $newTypes) {
        Assert-That ($valid -ccontains $e) ("Enum contem novo $e") ($valid -join ',')
    }
    foreach ($e in $newTypes) {
        $t = $null
        try { $t = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType $e } catch { $t = 'THREW' }
        Assert-That (($null -ne $t) -and ($t -ne 'THREW') -and ($t.event_type -ceq $e)) ("Novo tipo aceito $e") ([string]$t)
        $tl = $null
        try { $tl = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType ($e.ToLowerInvariant()) } catch { $tl = 'THREW' }
        Assert-That (($null -ne $tl) -and ($tl -ne 'THREW') -and ($tl.event_type -ceq $e)) ("Novo tipo case-insensitive $e") ([string]$tl)
    }

    $rt = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeVersion '1.2.3' -RuntimeProfile 'default'
    Assert-That (($null -ne $rt) -and ([string]$rt.runtime_id -ceq 'opencode-v1') -and ([int]$rt.runtime_generation -eq 1) -and ([string]$rt.runtime_version -ceq '1.2.3') -and ([string]$rt.runtime_profile -ceq 'default')) 'Runtime valido persistido' 'Campos ausentes/errados'
    $rt2 = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeId 'opencode-v1' -RuntimeGeneration 2 -RuntimeVersion '2.0.0-beta+1' -RuntimeProfile 'dual.profile-1'
    Assert-That (($null -ne $rt2) -and ([int]$rt2.runtime_generation -eq 2)) 'Runtime generation 2 aceita' 'Rejeitada'

    $rtOmit = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED'
    $omitOk = $true
    if ($null -eq $rtOmit) { $omitOk = $false }
    else {
        foreach ($rn in @('runtime_id', 'runtime_generation', 'runtime_version', 'runtime_profile')) {
            $p = $rtOmit.PSObject.Properties | Where-Object { $_.Name -ceq $rn } | Select-Object -First 1
            if ($null -ne $p) { $omitOk = $false }
        }
    }
    Assert-That $omitOk 'Runtime omitido => campos ausentes (sem null/vazio)' 'Campo presente'

    $telRt = New-TmpTelemetry
    $evRtRaw = [PSCustomObject]@{ task_id = 'RT-11AA'; event_type = 'TASK_CREATED'; agent = 'coder' }
    $okRt = $false
    try { $okRt = Write-ObservabilityEvent -Event $evRtRaw -TelemetryPath $telRt } catch { $okRt = 'THREW' }
    Assert-That ($okRt -eq $true) 'Escrita sem runtime nao bloqueia' ([string]$okRt)
    if (Test-Path -LiteralPath $telRt -PathType Leaf) {
        $txtRt = [IO.File]::ReadAllText($telRt, [Text.UTF8Encoding]::new($false))
        Assert-That ((-not $txtRt.Contains('runtime_id')) -and (-not $txtRt.Contains('runtime_generation')) -and (-not $txtRt.Contains('runtime_version')) -and (-not $txtRt.Contains('runtime_profile'))) 'JSONL sem runtime: sem chaves null/vazias' 'Chave vazia emitida'
    }
    else { Assert-That $false 'JSONL sem runtime escrito' 'Ausente' }

    $rtBadId = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeId 'BAD ID!!'
    $badIdOk = ($null -ne $rtBadId)
    if ($badIdOk) { $p = $rtBadId.PSObject.Properties | Where-Object { $_.Name -ceq 'runtime_id' } | Select-Object -First 1; if ($null -ne $p) { $badIdOk = $false } }
    Assert-That $badIdOk 'Runtime id invalido descartado, evento valido' 'Campo vazou ou evento null'
    $rtBadUp = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeId 'Opencode-V1'
    $badUpOk = ($null -ne $rtBadUp)
    if ($badUpOk) { $p = $rtBadUp.PSObject.Properties | Where-Object { $_.Name -ceq 'runtime_id' } | Select-Object -First 1; if ($null -ne $p) { $badUpOk = $false } }
    Assert-That $badUpOk 'Runtime id maiusculo descartado (fail-safe)' 'Campo vazou'
    $rtBadGen = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeGeneration 3
    $badGenOk = ($null -ne $rtBadGen)
    if ($badGenOk) { $p = $rtBadGen.PSObject.Properties | Where-Object { $_.Name -ceq 'runtime_generation' } | Select-Object -First 1; if ($null -ne $p) { $badGenOk = $false } }
    Assert-That $badGenOk 'Runtime generation 3 descartada, evento valido' 'Campo vazou ou evento null'
    $rtBadVer = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeVersion ('x' * 40)
    $badVerOk = ($null -ne $rtBadVer)
    if ($badVerOk) { $p = $rtBadVer.PSObject.Properties | Where-Object { $_.Name -ceq 'runtime_version' } | Select-Object -First 1; if ($null -ne $p) { $badVerOk = $false } }
    Assert-That $badVerOk 'Runtime version longa descartada, evento valido' 'Campo vazou ou evento null'
    $rtSan = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeVersion 'v1.0;rm -rf'
    Assert-That (($null -ne $rtSan) -and ([string]$rtSan.runtime_version -ceq 'v1.0rm-rf') -and (-not ([string]$rtSan.runtime_version).Contains(';')) -and (-not ([string]$rtSan.runtime_version).Contains(' '))) 'Runtime version sanitizada (strip fora de [a-zA-Z0-9._+-])' ([string]$rtSan.runtime_version)
    $rtBadProf = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_CREATED' -RuntimeProfile 'BAD PROFILE!!'
    $badProfOk = ($null -ne $rtBadProf)
    if ($badProfOk) { $p = $rtBadProf.PSObject.Properties | Where-Object { $_.Name -ceq 'runtime_profile' } | Select-Object -First 1; if ($null -ne $p) { $badProfOk = $false } }
    Assert-That $badProfOk 'Runtime profile invalido descartado, evento valido' 'Campo vazou ou evento null'

    $telRt2 = New-TmpTelemetry
    $evRtFull = [PSCustomObject]@{ task_id = 'RT-22BB'; event_type = 'TASK_CREATED'; agent = 'coder'; runtime_id = 'opencode-v1'; runtime_generation = 1; runtime_version = '1.0.0'; runtime_profile = 'default' }
    $okRt2 = $false
    try { $okRt2 = Write-ObservabilityEvent -Event $evRtFull -TelemetryPath $telRt2 } catch { $okRt2 = 'THREW' }
    Assert-That ($okRt2 -eq $true) 'Escrita com runtime valido persiste' ([string]$okRt2)
    if (Test-Path -LiteralPath $telRt2 -PathType Leaf) {
        $txtRt2 = [IO.File]::ReadAllText($telRt2, [Text.UTF8Encoding]::new($false))
        Assert-That (($txtRt2.Contains('opencode-v1') -and $txtRt2.Contains('runtime_id'))) 'JSONL com runtime_id persistido' 'Ausente'
        $oRt = $null
        try { $oRt = (($txtRt2 -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) | ConvertFrom-Json) } catch { $oRt = $null }
        $reOk = $false
        try {
            $reOk = Write-ObservabilityEvent -Event $oRt -TelemetryPath (New-TmpTelemetry)
        } catch { $reOk = 'THREW' }
        Assert-That ($reOk -eq $true) 'Re-normalizacao com runtime preserva (idempotente)' ([string]$reOk)
    }
    else { Assert-That $false 'JSONL com runtime escrito' 'Ausente' }

    $ev = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'TASK_RECEIVED' -Agent 'coder' -Risk 'medium' -Status 'received'
    Assert-That (($null -ne $ev) -and ($ev.event_type -ceq 'TASK_RECEIVED')) 'Evento valido construido' 'Null ou tipo errado'
    if ($null -ne $ev) {
        Assert-That (($ev.task_id -match '^sha256:[0-9a-f]{16}$') -and (-not $ev.task_id.Contains('DB-1A2B'))) 'task_id somente hash (sem valor cru)' ([string]$ev.task_id)
        Assert-That (([string]$ev.agent -ceq 'coder') -and ([string]$ev.risk -ceq 'medium')) 'agent/risk normalizados' 'Errado'
        Assert-That (($ev.selected_skills -is [array]) -and ($ev.selected_mcps -is [array])) 'Arrays como arrays (vazios)' 'Nao array'
    }

    $bad = $null
    try { $bad = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'INVENTADO' } catch { $bad = 'THREW' }
    Assert-That (($null -eq $bad)) 'event_type desconhecido => $null (fail-closed, sem lancar)' ([string]$bad)

    $lower = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'task_received'
    Assert-That (($null -ne $lower) -and ($lower.event_type -ceq 'TASK_RECEIVED')) 'event_type case-insensitive normaliza' 'Falhou'

    $free = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'STARTED' -Agent 'bad id!!' -Model ('x' * 200) -Risk 'injected' -Status 'injected!!' -Validation 'INVALID!!' -RoutingReason 'revisar codigo'
    Assert-That (($null -ne $free) -and ([string]$free.agent -ceq '') -and ([string]$free.model -ceq '') -and ([string]$free.risk -ceq '') -and ([string]$free.status -ceq '')) 'Campos livres invalidos descartados' 'Vazou valor cru'

    $arr = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'SKILL_SELECTED' -SelectedSkills @('db-guide', 'bad id!!', '', 'ux-ref') -SelectedMcps @('good-store', 'evil!!store')
    Assert-That (($null -ne $arr) -and ($arr.selected_skills -is [array]) -and ($arr.selected_mcps -is [array])) 'Arrays permanecem arrays' 'Tipo errado'
    if ($null -ne $arr) {
        Assert-That ((@($arr.selected_skills) -ccontains 'db-guide') -and (@($arr.selected_skills) -ccontains 'ux-ref') -and (@($arr.selected_skills).Count -eq 2)) 'Skills: so IDs canonicos' ((@($arr.selected_skills)) -join ',')
        Assert-That ((@($arr.selected_mcps) -ccontains 'good-store') -and (@($arr.selected_mcps).Count -eq 1)) 'MCPs: so IDs canonicos' ((@($arr.selected_mcps)) -join ',')
    }

    $single = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'AGENT_SELECTED' -SelectedSkills 'db-guide'
    Assert-That (($null -ne $single) -and ($single.selected_skills -is [array]) -and (@($single.selected_skills).Count -eq 1)) 'Scalar vira array de 1 (sem {value,Count})' 'Falhou'

    $secret = 'Bearer abcdef1234567890abcdef1234567890'
    $telRed = New-TmpTelemetry
    $evRed = [PSCustomObject]@{
        task_id = 'SEC-99AA'; event_type = 'TASK_RECEIVED'; agent = 'coder'
        routing_reason = ('revisar codigo com ' + $secret)
        metadata = @{ note = ('token ' + $secret); count = 3; ok = $true; api_key = 'SHOULD-DROP' }
    }
    $okRed = $false
    try { $okRed = Write-ObservabilityEvent -Event $evRed -TelemetryPath $telRed } catch { $okRed = 'THREW' }
    Assert-That ($okRed -eq $true) 'Escrita com segredo nao bloqueia (retorna true)' ([string]$okRed)
    if (Test-Path -LiteralPath $telRed -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($telRed, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $txt.Contains('abcdef1234567890abcdef')) 'Redacao: sem segredo no JSONL' 'Vazou'
        Assert-That (-not $txt.Contains('SEC-99AA')) 'task_id cru ausente (so hash)' 'Vazou'
        Assert-That (($txt -match 'sha256:[0-9a-f]{16}')) 'Hash sha256:<16hex> presente' 'Ausente'
        Assert-That (-not $txt.Contains('api_key')) 'Chave sensivel descartada do metadata' 'Vazou'
        Assert-That ((-not $txt.Contains('"value"')) -and (-not $txt.Contains('"Count"'))) 'Sem envelope {value,Count}' 'Achou envelope'
        $o0 = $null
        try { $o0 = (($txt -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) | ConvertFrom-Json) } catch { $o0 = $null }
        $arrOk = $false
        if ($null -ne $o0) { $arrOk = (($o0.selected_skills -is [array]) -and ($o0.selected_mcps -is [array])) }
        Assert-That $arrOk 'JSONL: selected_* como arrays' 'Tipo errado'
    }
    else { Assert-That $false 'JSONL de redacao escrito' 'Ausente' }

    $plainReason = 'revisar codigo de autenticacao do projeto alfa'
    $evPlain = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'STARTED' -RoutingReason $plainReason
    Assert-That (($null -ne $evPlain) -and ([string]$evPlain.routing_reason -cne $plainReason)) 'routing_reason livre vira token/hash (nunca a string crua)' ([string]$evPlain.routing_reason)
    if ($null -ne $evPlain) {
        Assert-That ((([string]$evPlain.routing_reason -match '^[a-z][a-z0-9_-]{0,31}$') -or ([string]$evPlain.routing_reason -match '^h:[0-9a-f]{16}$'))) 'routing_reason persistido como enum/token/hash' ([string]$evPlain.routing_reason)
    }
    $telPlain = New-TmpTelemetry
    $evPlainRaw = [PSCustomObject]@{ task_id = 'PLAIN-11AA'; event_type = 'STARTED'; agent = 'coder'; routing_reason = $plainReason }
    $okPlain = $false
    try { $okPlain = Write-ObservabilityEvent -Event $evPlainRaw -TelemetryPath $telPlain } catch { $okPlain = 'THREW' }
    Assert-That ($okPlain -eq $true) 'Escrita com objetivo nao-segredo nao bloqueia (retorna true)' ([string]$okPlain)
    if (Test-Path -LiteralPath $telPlain -PathType Leaf) {
        $txtPlain = [IO.File]::ReadAllText($telPlain, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $txtPlain.Contains($plainReason)) 'Texto livre ausente literal no JSONL (objetivo nao-segredo)' 'Vazou literal'
    }
    else { Assert-That $false 'JSONL de texto livre escrito' 'Ausente' }

    $telOut = Join-Path ([IO.Path]::GetTempPath()) ('v3-obs-outside-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $evOut = New-ObservabilityEvent -TaskId 'DB-1A2B' -EventType 'DONE'
    $rOut = $true
    try { $rOut = Write-ObservabilityEvent -Event $evOut -TelemetryPath $telOut } catch { $rOut = 'THREW' }
    Assert-That ($rOut -eq $false) 'Confinamento: fora de cache/v3/telemetry recusa ($false)' ([string]$rOut)
    Assert-That (-not (Test-Path -LiteralPath $telOut -PathType Leaf)) 'Confinamento: nada escrito fora' 'Arquivo criado'

    $telDirBlock = Join-Path $telDir ('tmp-obs-dirblock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $telDirBlock -Force | Out-Null
    $rDir = $true
    try { $rDir = Write-ObservabilityEvent -Event $evOut -TelemetryPath $telDirBlock } catch { $rDir = 'THREW' }
    Assert-That ($rDir -eq $false) 'TelemetryPath diretorio => $false sem lancar' ([string]$rDir)
    Remove-Item -LiteralPath $telDirBlock -Recurse -Force -ErrorAction SilentlyContinue

    $rNull = $true
    try { $rNull = Write-ObservabilityEvent -Event $null -TelemetryPath (New-TmpTelemetry) } catch { $rNull = 'THREW' }
    Assert-That ($rNull -eq $false) 'Evento $null => $false sem lancar' ([string]$rNull)
    $rGarbage = $true
    try { $rGarbage = Write-ObservabilityEvent -Event 'texto-livre' -TelemetryPath (New-TmpTelemetry) } catch { $rGarbage = 'THREW' }
    Assert-That ($rGarbage -eq $false) 'Evento texto-livre => $false sem lancar' ([string]$rGarbage)

    $oldName = 'tmp-obs-retain-20000101.jsonl'
    $oldFile = Join-Path $telDir $oldName
    $todayStamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
    $newName = ('tmp-obs-retain-' + $todayStamp + '.jsonl')
    $newFile = Join-Path $telDir $newName
    $script:tmpFiles += $oldFile
    $script:tmpFiles += $newFile
    [IO.File]::WriteAllText($oldFile, "{}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($newFile, "{}`n", [Text.UTF8Encoding]::new($false))
    $ret = $null
    try { $ret = Remove-ExpiredObservability -TelemetryDir $telDir -RetentionDays 30 } catch { $ret = 'THREW' }
    Assert-That (($null -ne $ret) -and ($ret -ne 'THREW')) 'Retencao nunca lanca' ([string]$ret)
    if (($null -ne $ret) -and ($ret -ne 'THREW')) {
        Assert-That (-not (Test-Path -LiteralPath $oldFile -PathType Leaf)) 'Retencao: dia fora dos 30 dias apagado' 'Mantido'
        Assert-That (Test-Path -LiteralPath $newFile -PathType Leaf) 'Retencao: dia dentro da retencao preservado' 'Apagado'
    }
    $script:tmpFiles = @($script:tmpFiles | Where-Object { $_ -cne $oldFile })

    $outsideDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-obs-outside-dir-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $outsideDir -Force | Out-Null
    $outsideOld = Join-Path $outsideDir 'events-20000101.jsonl'
    [IO.File]::WriteAllText($outsideOld, "{}`n", [Text.UTF8Encoding]::new($false))
    $retOut = $null
    try { $retOut = Remove-ExpiredObservability -TelemetryDir $outsideDir -RetentionDays 30 } catch { $retOut = 'THREW' }
    Assert-That (($null -ne $retOut) -and ($retOut -ne 'THREW') -and ([int]$retOut.Removed -eq 0)) 'Retencao confinada: dir externo recusa sem deletar (Removed=0)' ([string]$retOut)
    Assert-That (Test-Path -LiteralPath $outsideOld -PathType Leaf) 'Retencao confinada: arquivo externo preservado' 'Deletado fora do perimetro'
    if (Test-Path -LiteralPath $outsideDir) { Remove-Item -LiteralPath $outsideDir -Recurse -Force -ErrorAction SilentlyContinue }

    $junctionLink = Join-Path $telDir ('tmp-junction-' + [guid]::NewGuid().ToString('N'))
    $junctionTarget = Join-Path ([IO.Path]::GetTempPath()) ('v3-obs-junction-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionOk = $true
    try { New-Item -ItemType Junction -Path $junctionLink -Target $junctionTarget -ErrorAction Stop | Out-Null } catch { $junctionOk = $false }
    if ($junctionOk) {
        $viaTel = Join-Path $junctionLink 'via-tel.jsonl'
        $rJ = $true
        try { $rJ = Write-ObservabilityEvent -Event $evOut -TelemetryPath $viaTel } catch { $rJ = 'THREW' }
        Assert-That ($rJ -eq $false) 'Reparse: via junction recusa ($false)' ([string]$rJ)
        Assert-That (-not (Test-Path -LiteralPath $viaTel -PathType Leaf)) 'Reparse: nada escrito via junction' 'Arquivo criado'
        $leaked = @(Get-ChildItem -LiteralPath $junctionTarget -Force -ErrorAction SilentlyContinue)
        Assert-That ($leaked.Count -eq 0) 'Reparse: nada vaza para o alvo' ($leaked.Count)
        Remove-Item -LiteralPath $junctionLink -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '[WARN] Junction indisponivel; skip do caso reparse'
        Assert-That ($true) 'Reparse via junction (skip sem privilegio)' 'skip'
    }
    if (Test-Path -LiteralPath $junctionTarget) { Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue }

    $retJuncTarget = Join-Path ([IO.Path]::GetTempPath()) ('v3-obs-retjunction-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $retJuncTarget -Force | Out-Null
    $retJuncOld = Join-Path $retJuncTarget 'events-20000101.jsonl'
    [IO.File]::WriteAllText($retJuncOld, "{}`n", [Text.UTF8Encoding]::new($false))
    $retJuncLink = Join-Path $telDir ('tmp-retjunction-' + [guid]::NewGuid().ToString('N'))
    $retJuncOk = $true
    try { New-Item -ItemType Junction -Path $retJuncLink -Target $retJuncTarget -ErrorAction Stop | Out-Null } catch { $retJuncOk = $false }
    if ($retJuncOk) {
        $retJ = $null
        try { $retJ = Remove-ExpiredObservability -TelemetryDir $retJuncLink -RetentionDays 30 } catch { $retJ = 'THREW' }
        Assert-That (($null -ne $retJ) -and ($retJ -ne 'THREW') -and ([int]$retJ.Removed -eq 0)) 'Retencao: TelemetryDir via junction recusa (Removed=0)' ([string]$retJ)
        Assert-That (Test-Path -LiteralPath $retJuncOld -PathType Leaf) 'Retencao: alvo da junction preservado' 'Deletado via junction'
        try { & cmd /c rmdir $retJuncLink 2>&1 | Out-Null } catch { }
    } else {
        Write-Host '[WARN] Junction indisponivel; skip do caso retencao-reparse'
        Assert-That ($true) 'Retencao via junction (skip sem privilegio)' 'skip'
    }
    if (Test-Path -LiteralPath $retJuncTarget) { Remove-Item -LiteralPath $retJuncTarget -Recurse -Force -ErrorAction SilentlyContinue }

    $liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if (Test-Path -LiteralPath $liveConfig -PathType Leaf) {
        $liveHash = (Get-FileHash -LiteralPath $liveConfig -Algorithm SHA256).Hash
        Assert-That ($liveHash.StartsWith('DE22307F')) 'opencode.json vivo inalterado (prefixo DE22307F)' $liveHash
    }
    else {
        Skip-That 'opencode.json vivo inalterado (prefixo DE22307F)' 'sem opencode.json vivo nesta maquina (estado live, nao distribuido)'
    }
}
finally {
    foreach ($tmp in @($tmpFiles)) {
        if ((-not [string]::IsNullOrWhiteSpace($tmp)) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "TEST RESULTS: $passed / $total passed ($skipped skipped)"
if (($passed + $skipped) -ne $total) { exit 1 }
exit 0
