# session-real-lane-nativeturn.tests.ps1 -- ORFS-LANE-NATIVETURN.
# Testes offline da perna nativa REST do turno de modelo da lane
# scripts/ci/session-real-lane-v2.ps1: POST prompt -> POST wait -> GET messages
# como ULTIMO fallback apos CLI pinned (--model) e CLI default (retry sem
# --model), sem mudar comportamento quando as CLI passam (no maximo 3
# tentativas por turno: 2 CLI + 1 nativa).
# Contrato (validado defensivamente em runtime, fail-closed sem excecao):
# prompt body minimo {"text":"..."} (delivery default steer; sem queue);
# resposta 200 = inbox item COM schema minimo (objeto com id string
# nao-vazia, sem erro significativo no envelope nem no item; NAO e a
# resposta); wait sem body, 204=idle
# (timeout client-side proprio; excedeu => inconclusivo fail-closed, sem
# interrupt); messages GET ?type=assistant&order=asc (+cursor.next com mesmo
# type; ausente ou terminal valido segue; presente-malformado recusa;
# cursor repetido => erro; cap 5 paginas com pendencia => erro;
# dedup por chave id/texto, sem dupla contagem), texto em content[] onde
# type=="text"; ok = wait 204 + ao menos 1 texto assistant NOVO (contagem
# antes/depois dedupada; sem timestamps frageis);
# shape inesperado/401/403/503/timeout => fail-closed.
# Sem Pester. Sem rede externa (so loopback HttpListener com fixtures
# sinteticas); sem spawn/modelo/servico real; sem segredo (canarios syn-*).
# Nos cenarios, a perna usa RequestFn autenticado via Invoke-Api
# (New-LaneNativeApiRequestFn; sem senha no helper); BaseUrl direto segue
# existindo para testes/offline e falha fechado sem auth.
# O helper puro Parse-NativeTurnMessages e a perna Invoke-LaneNativeTurn sao
# extraidos da lane via AST (a lane nunca e executada) e exercitados em
# memoria; o resto sao asserts estaticos sobre o texto da lane.
# PS 5.1 e PS7 compativel. ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:total = 0
$script:passed = 0
$script:suiteSw = [Diagnostics.Stopwatch]::StartNew()
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
function Get-LaneFuncMap($text) {
    $tokens = $null
    $parseErrors = $null
    $map = @{}
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
        if (($null -ne $ast) -and (@($parseErrors).Count -eq 0)) {
            $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($f in @($found)) { $map[[string]$f.Name] = [string]$f.Extent.Text }
        }
    } catch { }
    return $map
}
try {
    Assert-That (Test-Path -LiteralPath $script:LanePath -PathType Leaf) 'lane file exists' $script:LanePath
    $text = ''
    try { $text = [IO.File]::ReadAllText($script:LanePath) } catch { $text = '' }
    Assert-That (-not [string]::IsNullOrEmpty($text)) 'lane text readable' 'empty'
    $funcs = Get-LaneFuncMap $text
    Assert-That (@($funcs.Keys).Count -gt 0) 'lane parses without syntax errors' 'parse falhou'
    # A. existencia dos blocos novos
    Assert-That ($funcs.ContainsKey('Parse-NativeTurnMessages')) 'helper Parse-NativeTurnMessages exists' 'helper ausente na lane'
    Assert-That ($funcs.ContainsKey('Invoke-LaneNativeTurn')) 'leg Invoke-LaneNativeTurn exists' 'perna ausente na lane'
    Assert-That ($funcs.ContainsKey('New-LaneModelTurnOutcome')) 'helper New-LaneModelTurnOutcome exists' 'helper de decisao ausente'
    Assert-That ($funcs.ContainsKey('Invoke-LaneModelTurn')) 'turn Invoke-LaneModelTurn exists' 'turn ausente'
    Assert-That ($funcs.ContainsKey('Get-JsonProp')) 'dependency Get-JsonProp extracted' 'missing'
    if ($funcs.ContainsKey('Get-JsonProp')) { Invoke-Expression $funcs['Get-JsonProp'] }
    if ($funcs.ContainsKey('Parse-NativeTurnMessages')) {
        Invoke-Expression $funcs['Parse-NativeTurnMessages']
        # B1. data-wrapped com 2 textos assistant
        $b1 = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-b1-a"},{"type":"text","text":"syn-b1-b"}]},{"role":"user","content":[{"type":"text","text":"syn-b1-q"}]}]}'
        $p1 = Parse-NativeTurnMessages -Body $b1
        Assert-That (([bool]$p1.ok) -and ([int]$p1.count -eq 2)) 'parser: data-wrapped conta 2 assistant' ('ok=' + [bool]$p1.ok + ' count=' + [int]$p1.count)
        # B2. array nu
        $p2 = Parse-NativeTurnMessages -Body '[{"role":"assistant","content":[{"type":"text","text":"syn-b2"}]}]'
        Assert-That (([bool]$p2.ok) -and ([int]$p2.count -eq 1)) 'parser: array nu conta 1' ('count=' + [int]$p2.count)
        # B3. messages-wrapped
        $p3 = Parse-NativeTurnMessages -Body '{"messages":[{"role":"assistant","content":[{"type":"text","text":"syn-b3"}]}]}'
        Assert-That (([bool]$p3.ok) -and ([int]$p3.count -eq 1)) 'parser: messages-wrapped conta 1' ('count=' + [int]$p3.count)
        # B4. data.messages aninhado + cursor.next propagado
        $p4 = Parse-NativeTurnMessages -Body '{"data":{"messages":[{"role":"assistant","content":[{"type":"text","text":"syn-b4"}]}],"cursor":{"next":"syn-cursor-04"}}}'
        Assert-That (([bool]$p4.ok) -and ([int]$p4.count -eq 1) -and ([string]$p4.next -ceq 'syn-cursor-04')) 'parser: aninhado + cursor.next' ('next=' + [string]$p4.next)
        # B5. vazio => fail-closed
        $p5 = Parse-NativeTurnMessages -Body ''
        Assert-That ((-not [bool]$p5.ok) -and ([int]$p5.count -eq 0)) 'parser: vazio fail-closed' 'ok indevido'
        # B6. json invalido => fail-closed
        $p6 = Parse-NativeTurnMessages -Body 'THIS-IS-NOT-JSON{{{'
        Assert-That ((-not [bool]$p6.ok) -and ([int]$p6.count -eq 0)) 'parser: shape invalido fail-closed' 'ok indevido'
        # B7. objeto sem lista => fail-closed (nao inventa lista)
        $p7 = Parse-NativeTurnMessages -Body '{"data":{"id":"syn-b7"}}'
        Assert-That ((-not [bool]$p7.ok)) 'parser: objeto sem lista fail-closed' 'ok indevido'
        # B8. so nao-assistant => ok parseavel com count 0
        $p8 = Parse-NativeTurnMessages -Body '{"data":[{"role":"user","content":[{"type":"text","text":"syn-b8"}]}]}'
        Assert-That (([bool]$p8.ok) -and ([int]$p8.count -eq 0)) 'parser: so user conta 0' ('count=' + [int]$p8.count)
        # B9. partes nao-texto ignoradas
        $p9 = Parse-NativeTurnMessages -Body '{"data":[{"role":"assistant","content":[{"type":"image","text":"syn-b9-img"},{"type":"text","text":"syn-b9-t"}]}]}'
        Assert-That (([bool]$p9.ok) -and ([int]$p9.count -eq 1) -and (@($p9.texts) -contains 'syn-b9-t')) 'parser: ignora parte nao-texto' ('count=' + [int]$p9.count)
        # B10. content string direto
        $p10 = Parse-NativeTurnMessages -Body '{"data":[{"role":"assistant","content":"syn-b10-plain"}]}'
        Assert-That (([bool]$p10.ok) -and ([int]$p10.count -eq 1)) 'parser: content string conta 1' ('count=' + [int]$p10.count)
    }
    if (($funcs.ContainsKey('Parse-NativeTurnMessages')) -and ($funcs.ContainsKey('Invoke-LaneNativeTurn'))) {
        Invoke-Expression $funcs['Parse-NativeTurnMessages']
        Invoke-Expression $funcs['Invoke-LaneNativeTurn']
        # Canned RequestFn: contrato (Method, Path, Body, TimeoutMs) -> StatusCode/Body/TimedOut
        # C1. happy: prompt 200 + wait 204 + 1 texto novo => ok + proof
        $script:cannedCalls = 0
        $cannedHappy = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:cannedCalls++
                if ($script:cannedCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-c1-new"}]}],"cursor":{"next":""}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-01"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:cannedCalls = 0
        $r1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c1' -SafePrompt 'syn-prompt-c1' -TimeoutMs 10000 -RequestFn $cannedHappy
        Assert-That (([bool]$r1.attempted) -and ([bool]$r1.ok) -and ([bool]$r1.wait204) -and ([int]$r1.textsNew -eq 1)) 'leg happy: ok com wait204 + 1 texto novo' ('ok=' + [bool]$r1.ok + ' novos=' + [int]$r1.textsNew)
        Assert-That (($null -ne $r1.proof) -and ([string]$r1.proof['proof'] -ceq 'model-native-prompt') -and ([bool]$r1.proof['ok'])) 'leg happy: proof model-native-prompt ok=true' 'proof ausente/divergente'
        # C2. wait sem 204 => fail, sem proof
        $cannedWait500 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-02"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 500; Body = '{"error":"syn-wait-500"}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $r2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c2' -SafePrompt 'syn-prompt-c2' -TimeoutMs 10000 -RequestFn $cannedWait500
        Assert-That ((-not [bool]$r2.ok) -and ($null -ne $r2.proof) -and ([string]$r2.proof['proof'] -ceq 'model-native-failed') -and ([bool]$r2.proof['ok']) -and ([string]$r2.proof['detail'] -like 'wait-status-500*')) 'leg wait-sem-204: failed-proof com reason' ('reason=' + [string]$r2.reason)
        # C3. messages sem texto novo => fail
        $cannedNoNew = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-03"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $r3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c3' -SafePrompt 'syn-prompt-c3' -TimeoutMs 10000 -RequestFn $cannedNoNew
        Assert-That ((-not [bool]$r3.ok) -and ([string]$r3.reason -like 'no-new-text*') -and ($null -ne $r3.proof) -and ([string]$r3.proof['detail'] -like 'no-new-text*')) 'leg sem-texto-novo: failed-proof com reason' ('reason=' + [string]$r3.reason)
        # C4. shape invalido no messages => fail-closed
        $cannedBadShape = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = 'GARBAGE{{{'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-04"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $r4 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c4' -SafePrompt 'syn-prompt-c4' -TimeoutMs 10000 -RequestFn $cannedBadShape
        Assert-That ((-not [bool]$r4.ok) -and ($null -ne $r4.proof) -and ([string]$r4.proof['detail'] -like 'messages-before-invalid*')) 'leg shape-invalido: failed-proof com reason' ('ok=' + [bool]$r4.ok)
        # C5. prompt 503 APOS before ok => fail NO prompt com 503
        $cannedPrompt503 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 503; Body = '{"error":"syn-prompt-503"}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $r5 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c5' -SafePrompt 'syn-prompt-c5' -TimeoutMs 10000 -RequestFn $cannedPrompt503
        Assert-That ((-not [bool]$r5.ok) -and ($null -ne $r5.proof) -and ([string]$r5.proof['proof'] -ceq 'model-native-failed') -and ([string]$r5.proof['detail'] -like 'prompt-status-503*')) 'leg prompt-503: failed-proof com reason' ('reason=' + [string]$r5.reason)
        # C6. timeout do wait => fail-closed sem excecao
        $cannedWaitTimeout = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-06"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = -1; Body = ''; TimedOut = $true } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $threw6 = $false
        $r6 = $null
        try { $r6 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c6' -SafePrompt 'syn-prompt-c6' -TimeoutMs 10000 -RequestFn $cannedWaitTimeout } catch { $threw6 = $true }
        Assert-That ((-not $threw6) -and ($null -ne $r6) -and (-not [bool]$r6.ok) -and ([string]$r6.reason -like 'wait-timeout*') -and ($null -ne $r6.proof) -and ([string]$r6.proof['detail'] -like 'wait-timeout*')) 'leg wait-timeout: failed-proof sem throw' ('threw=' + $threw6)
        # C40. timeout no before => failed-proof com reason
        $cannedBeforeTimeout = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = -1; Body = ''; TimedOut = $true } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-40"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $r40 = Invoke-LaneNativeTurn -SessionId 'syn-sess-t0' -SafePrompt 'syn-prompt-t0' -TimeoutMs 10000 -RequestFn $cannedBeforeTimeout
        Assert-That ((-not [bool]$r40.ok) -and ([string]$r40.reason -like 'messages-before-timeout*') -and ($null -ne $r40.proof) -and ([string]$r40.proof['detail'] -like 'messages-before-timeout*')) 'leg before-timeout: failed-proof com reason' ('reason=' + [string]$r40.reason)
        # C7. sessao vazia => fail-closed sem transporte
        $r7 = Invoke-LaneNativeTurn -SessionId '' -SafePrompt 'syn-prompt-c7' -TimeoutMs 10000 -RequestFn $cannedHappy
        Assert-That ((-not [bool]$r7.attempted) -and (-not [bool]$r7.ok)) 'leg sessao-vazia: nao tenta' 'tentou indevidamente'
        # C8. sem transporte (sem BaseUrl e sem RequestFn) => fail-closed
        $r8 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c8' -SafePrompt 'syn-prompt-c8' -TimeoutMs 10000
        Assert-That ((-not [bool]$r8.attempted) -and (-not [bool]$r8.ok) -and ([string]$r8.reason -like 'native-transport-unavailable*')) 'leg sem-transporte: fail-closed' ('reason=' + [string]$r8.reason)
        # C9. body do prompt e {"text":...} sem queue; wait sem resposta => fail
        $script:seenBody = ''
        $cannedCapture = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { $script:seenBody = [string]$Body; return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-09"}}'; TimedOut = $false } }
            return $null
        }
        $script:seenBody = ''
        $r9 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c9' -SafePrompt 'syn-prompt-c9' -TimeoutMs 10000 -RequestFn $cannedCapture
        Assert-That ((-not [bool]$r9.ok) -and ($script:seenBody -match '"text"\s*:\s*"syn-prompt-c9"') -and ($script:seenBody -notmatch 'queue') -and ($null -ne $r9.proof) -and ([string]$r9.proof['detail'] -like 'wait-status--1*')) 'leg prompt-body minimo sem queue; failed-proof no wait-null' ('body=' + $script:seenBody)
        # C10. paginacao via cursor.next com mesmo type
        $script:pageCalls = 0
        $cannedPaged = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:pageCalls++
                if ($Path -notmatch 'type=assistant') { return @{ StatusCode = 400; Body = '{}'; TimedOut = $false } }
                if ($script:pageCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                if ($Path -match 'cursor=') { return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-c10-p2"}]}],"cursor":{"next":""}}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[],"cursor":{"next":"syn-c10-c1"}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-10"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:pageCalls = 0
        $r10 = Invoke-LaneNativeTurn -SessionId 'syn-sess-c10' -SafePrompt 'syn-prompt-c10' -TimeoutMs 10000 -RequestFn $cannedPaged
        Assert-That (([bool]$r10.ok) -and ([int]$r10.textsNew -eq 1)) 'leg paginacao: segue cursor.next com type e conta' ('novos=' + [int]$r10.textsNew)
        # C11. prompt shape: corpo parametrizado (GET inicial ok; resto happy)
        $script:shapePromptStatus = 200
        $script:shapePromptBody = '{"data":{"id":"syn-shape-ok"}}'
        $script:shapeAfterNew = $false
        $script:shapeMsgCalls = 0
        $shapeFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:shapeMsgCalls++
                if (($script:shapeAfterNew) -and ($script:shapeMsgCalls -gt 1)) { return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-shape-new"}]}]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = $script:shapePromptStatus; Body = [string]$script:shapePromptBody; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:shapePromptStatus = 200; $script:shapePromptBody = '{}'; $script:shapeAfterNew = $false; $script:shapeMsgCalls = 0
        $rs1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s1' -SafePrompt 'syn-prompt-s1' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs1.ok) -and ([string]$rs1.reason -like 'prompt-invalid-shape*') -and ($null -ne $rs1.proof) -and ([string]$rs1.proof['detail'] -like 'prompt-invalid-shape*')) 'leg prompt-{}: failed-proof com reason' ('reason=' + [string]$rs1.reason)
        $script:shapePromptBody = '{"error":"syn-shape-err"}'; $script:shapeMsgCalls = 0
        $rs2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s2' -SafePrompt 'syn-prompt-s2' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs2.ok) -and ([string]$rs2.reason -like 'prompt-invalid-shape*')) 'leg prompt-error: envelope de erro recusado' ('reason=' + [string]$rs2.reason)
        $script:shapePromptBody = '{"data":{}}'; $script:shapeMsgCalls = 0
        $rs3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s3' -SafePrompt 'syn-prompt-s3' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs3.ok) -and ([string]$rs3.reason -like 'prompt-invalid-shape*')) 'leg prompt-data-{}: sem id recusado' ('reason=' + [string]$rs3.reason)
        $script:shapePromptBody = '{"data":{"id":""}}'; $script:shapeMsgCalls = 0
        $rs4 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s4' -SafePrompt 'syn-prompt-s4' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs4.ok) -and ([string]$rs4.reason -like 'prompt-invalid-shape*')) 'leg prompt-id-vazio: recusado' ('reason=' + [string]$rs4.reason)
        # S5: '[]' nao comeca com '{' => prompt-invalid-shape nas duas
        # engines (check de texto anterior ao parse; uniforme por construcao).
        $script:shapePromptBody = '[]'; $script:shapeMsgCalls = 0
        $rs5 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s5' -SafePrompt 'syn-prompt-s5' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs5.ok) -and ([string]$rs5.reason -like 'prompt-invalid-shape*')) 'leg prompt-array: nao-objeto recusado' ('reason=' + [string]$rs5.reason)
        $script:shapePromptBody = '"syn-just-string"'; $script:shapeMsgCalls = 0
        $rs6 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s6' -SafePrompt 'syn-prompt-s6' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs6.ok) -and ([string]$rs6.reason -like 'prompt-invalid-shape*')) 'leg prompt-string: nao-objeto recusado' ('reason=' + [string]$rs6.reason)
        $script:shapePromptBody = '{"data":{"id":"syn-shape-07","error":"syn-shape-boom"}}'; $script:shapeMsgCalls = 0
        $rs7 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s7' -SafePrompt 'syn-prompt-s7' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$rs7.ok) -and ([string]$rs7.reason -like 'prompt-invalid-shape*')) 'leg prompt-id+error: erro concomitante recusado' ('reason=' + [string]$rs7.reason)
        $script:shapePromptBody = '{"id":"syn-shape-08"}'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $rs8 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s8' -SafePrompt 'syn-prompt-s8' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That (([bool]$rs8.ok) -and ([int]$rs8.textsNew -eq 1)) 'leg prompt-id-nuo: aceito e decide' ('ok=' + [bool]$rs8.ok)
        $script:shapePromptBody = '{"data":{"id":"syn-shape-09"}}'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $rs9 = Invoke-LaneNativeTurn -SessionId 'syn-sess-s9' -SafePrompt 'syn-prompt-s9' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That (([bool]$rs9.ok) -and ([int]$rs9.promptStatus -eq 200)) 'leg prompt-data-id: controle positivo' ('ok=' + [bool]$rs9.ok)
        # C17. envelope com erro string + id valido => recusado (erro externo nao descartado)
        $script:shapePromptBody = '{"error":"rejected","data":{"id":"syn"}}'; $script:shapeAfterNew = $false; $script:shapeMsgCalls = 0
        $re1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-e1' -SafePrompt 'syn-prompt-e1' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$re1.ok) -and ([string]$re1.reason -like 'prompt-invalid-shape*') -and ($null -ne $re1.proof) -and ([string]$re1.proof['detail'] -like 'prompt-invalid-shape*')) 'leg envelope-erro-str: failed-proof com reason' ('reason=' + [string]$re1.reason)
        # C18. envelope com erro array => recusado
        $script:shapePromptBody = '{"error":["boom"],"data":{"id":"syn"}}'; $script:shapeMsgCalls = 0
        $re2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-e2' -SafePrompt 'syn-prompt-e2' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$re2.ok) -and ([string]$re2.reason -like 'prompt-invalid-shape*') -and ($null -ne $re2.proof) -and ([string]$re2.proof['detail'] -like 'prompt-invalid-shape*')) 'leg envelope-erro-array: failed-proof com reason' ('reason=' + [string]$re2.reason)
        # C19. item com erro array => recusado
        $script:shapePromptBody = '{"data":{"id":"syn-x","error":["boom"]}}'; $script:shapeMsgCalls = 0
        $re3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-e3' -SafePrompt 'syn-prompt-e3' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$re3.ok) -and ([string]$re3.reason -like 'prompt-invalid-shape*') -and ($null -ne $re3.proof) -and ([string]$re3.proof['detail'] -like 'prompt-invalid-shape*')) 'leg item-erro-array: failed-proof com reason' ('reason=' + [string]$re3.reason)
        # C20. item com erro objeto => recusado
        $script:shapePromptBody = '{"data":{"id":"syn-x","error":{"code":1}}}'; $script:shapeMsgCalls = 0
        $re4 = Invoke-LaneNativeTurn -SessionId 'syn-sess-e4' -SafePrompt 'syn-prompt-e4' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$re4.ok) -and ([string]$re4.reason -like 'prompt-invalid-shape*') -and ($null -ne $re4.proof) -and ([string]$re4.proof['detail'] -like 'prompt-invalid-shape*')) 'leg item-erro-objeto: failed-proof com reason' ('reason=' + [string]$re4.reason)
        # C21/22/23. id numerico/bool/array => recusado (id exige string)
        $script:shapePromptBody = '{"data":{"id":123}}'; $script:shapeMsgCalls = 0
        $ri1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-i1' -SafePrompt 'syn-prompt-i1' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ri1.ok) -and ([string]$ri1.reason -like 'prompt-invalid-shape*') -and ($null -ne $ri1.proof) -and ([string]$ri1.proof['detail'] -like 'prompt-invalid-shape*')) 'leg id-numerico: failed-proof com reason' ('reason=' + [string]$ri1.reason)
        $script:shapePromptBody = '{"data":{"id":true}}'; $script:shapeMsgCalls = 0
        $ri2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-i2' -SafePrompt 'syn-prompt-i2' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ri2.ok) -and ([string]$ri2.reason -like 'prompt-invalid-shape*') -and ($null -ne $ri2.proof) -and ([string]$ri2.proof['detail'] -like 'prompt-invalid-shape*')) 'leg id-bool: failed-proof com reason' ('reason=' + [string]$ri2.reason)
        $script:shapePromptBody = '{"data":{"id":["syn"]}}'; $script:shapeMsgCalls = 0
        $ri3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-i3' -SafePrompt 'syn-prompt-i3' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ri3.ok) -and ([string]$ri3.reason -like 'prompt-invalid-shape*') -and ($null -ne $ri3.proof) -and ([string]$ri3.proof['detail'] -like 'prompt-invalid-shape*')) 'leg id-array: failed-proof com reason' ('reason=' + [string]$ri3.reason)
        # C24/25. erro benigno (array vazio / string vazia no envelope) => aceito
        $script:shapePromptBody = '{"error":[],"data":{"id":"syn-ok2"}}'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ro1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-o1' -SafePrompt 'syn-prompt-o1' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ([bool]$ro1.ok) 'leg envelope-erro-vazio: benigno aceito' ('ok=' + [bool]$ro1.ok)
        $script:shapePromptBody = '{"error":"","data":{"id":"syn-ok3"}}'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ro2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-o2' -SafePrompt 'syn-prompt-o2' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ([bool]$ro2.ok) 'leg envelope-erro-blank: benigno aceito' ('ok=' + [bool]$ro2.ok)
        # C36. array raiz singleton => recusado pelo texto (PS7 desembrulha
        # o array antes do check -is Array; o texto nao mente)
        $script:shapePromptBody = '[{"id":"syn"}]'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ra1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-a1' -SafePrompt 'syn-prompt-a1' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ra1.ok) -and ([string]$ra1.reason -like 'prompt-invalid-shape*') -and ($null -eq $ra1.proof)) 'leg array-raiz-singleton: recusado pelo texto' ('reason=' + [string]$ra1.reason)
        # C37. singleton sob data => recusado (data deve ser objeto)
        $script:shapePromptBody = '{"data":[{"id":"syn"}]}'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ra2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-a2' -SafePrompt 'syn-prompt-a2' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ra2.ok) -and ([string]$ra2.reason -like 'prompt-invalid-shape*') -and ($null -ne $ra2.proof) -and ([string]$ra2.proof['detail'] -like 'prompt-invalid-shape*')) 'leg array-sob-data: failed-proof com reason' ('reason=' + [string]$ra2.reason)
        # C38. array raiz com whitespace => recusado (trim antes do check)
        $script:shapePromptBody = '  [{"id":"syn"}]  '; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ra3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-a3' -SafePrompt 'syn-prompt-a3' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ra3.ok) -and ([string]$ra3.reason -like 'prompt-invalid-shape*') -and ($null -eq $ra3.proof)) 'leg array-raiz-trim: recusado' ('reason=' + [string]$ra3.reason)
        # C39. comentario + array singleton => recusado pelo texto (o parse
        # aceita comentarios; sem o check de '{', o array passa no PS7)
        $script:shapePromptBody = '/*syn-c*/[{"id":"syn"}]'; $script:shapeAfterNew = $true; $script:shapeMsgCalls = 0
        $ra4 = Invoke-LaneNativeTurn -SessionId 'syn-sess-a4' -SafePrompt 'syn-prompt-a4' -TimeoutMs 10000 -RequestFn $shapeFn
        Assert-That ((-not [bool]$ra4.ok) -and ([string]$ra4.reason -like 'prompt-invalid-shape*') -and ($null -eq $ra4.proof)) 'leg comentario+array: recusado pelo texto' ('reason=' + [string]$ra4.reason)
        # C12. cursor repetido no after => erro, sem loop
        $script:repCalls = 0
        $repFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:repCalls++
                if ($script:repCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[],"cursor":{"next":"syn-rep-1"}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-rep"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:repCalls = 0
        $rr1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-r1' -SafePrompt 'syn-prompt-r1' -TimeoutMs 10000 -RequestFn $repFn
        Assert-That ((-not [bool]$rr1.ok) -and ([string]$rr1.reason -like 'messages-after-cursor-repeat*') -and ($null -ne $rr1.proof) -and ([string]$rr1.proof['detail'] -like 'messages-after-cursor-repeat*')) 'leg cursor-repetido: failed-proof sem loop' ('reason=' + [string]$rr1.reason)
        # C13. 5 paginas + next pendente => leitura truncada, erro
        $script:trCalls = 0
        $truncFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:trCalls++
                if ($script:trCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = ('{"data":[],"cursor":{"next":"syn-tr-' + $script:trCalls + '"}}'); TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-tr"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:trCalls = 0
        $rt1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-t1' -SafePrompt 'syn-prompt-t1' -TimeoutMs 10000 -RequestFn $truncFn
        Assert-That ((-not [bool]$rt1.ok) -and ([string]$rt1.reason -like 'messages-after-truncated*') -and ($null -ne $rt1.proof) -and ([string]$rt1.proof['detail'] -like 'messages-after-truncated*')) 'leg after-truncado: failed-proof no cap' ('reason=' + [string]$rt1.reason)
        # C14. before truncado => falha antes do prompt (prompt nunca chamado)
        $script:btrCalls = 0
        $script:promptSeen = $false
        $btruncFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { $script:btrCalls++; return @{ StatusCode = 200; Body = ('{"data":[],"cursor":{"next":"syn-btr-' + $script:btrCalls + '"}}'); TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { $script:promptSeen = $true; return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-bt"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:btrCalls = 0
        $script:promptSeen = $false
        $rb1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-b1' -SafePrompt 'syn-prompt-b1' -TimeoutMs 10000 -RequestFn $btruncFn
        Assert-That ((-not [bool]$rb1.ok) -and ([string]$rb1.reason -like 'messages-before-truncated*') -and (-not [bool]$script:promptSeen) -and ($null -ne $rb1.proof) -and ([string]$rb1.proof['detail'] -like 'messages-before-truncated*')) 'leg before-truncado: failed-proof fail-fast' ('reason=' + [string]$rb1.reason)
        # C15. textos repetidos entre paginas contam 1x (dedup por chave)
        $dupFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                if ($Path -match 'cursor=') { return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-dup-t"}]}],"cursor":{"next":""}}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-dup-t"}]}],"cursor":{"next":"syn-dup-1"}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-dup"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $rd1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d1' -SafePrompt 'syn-prompt-d1' -TimeoutMs 10000 -RequestFn $dupFn
        Assert-That ((-not [bool]$rd1.ok) -and ([string]$rd1.reason -like 'no-new-text*') -and ([int]$rd1.afterCount -eq 1) -and ($null -ne $rd1.proof) -and ([string]$rd1.proof['detail'] -like 'no-new-text*')) 'leg dedup: failed-proof sem novidade' ('reason=' + [string]$rd1.reason + ' depois=' + [int]$rd1.afterCount)
        # C16. parser expoe chaves de dedup (id, ou texto quando sem id)
        $pk1 = Parse-NativeTurnMessages -Body '{"data":[{"id":"syn-k-01","role":"assistant","content":[{"type":"text","text":"syn-k-t1"}]}]}'
        Assert-That (([bool]$pk1.ok) -and (@($pk1['dedupKeys']) -contains 'id:syn-k-01')) 'parser: chave por id' ('keys=' + (@($pk1['dedupKeys']) -join ','))
        $pk2 = Parse-NativeTurnMessages -Body '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-k-t2"}]}]}'
        Assert-That (([bool]$pk2.ok) -and (@($pk2['dedupKeys']) -contains 'tx:syn-k-t2')) 'parser: chave por texto sem id' ('keys=' + (@($pk2['dedupKeys']) -join ','))
        # C26. cursor {} VAZIO => terminal valido do contrato (fim de paginas)
        $pc1 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":{}}'
        Assert-That (([bool]$pc1.ok) -and ([string]$pc1.next -ceq '')) 'parser: cursor-{} vazio terminal' ('err=' + [string]$pc1.error)
        # C26b. cursor NAO-vazio sem next => malformado (fail-closed preservado)
        $pc1b = Parse-NativeTurnMessages -Body '{"data":[],"cursor":{"foo":"syn-x"}}'
        Assert-That ((-not [bool]$pc1b.ok) -and ([string]$pc1b.error -ceq 'cursor-malformado')) 'parser: cursor nao-vazio sem next recusado' ('err=' + [string]$pc1b.error)
        # C27. cursor string => malformado (espera objeto)
        $pc2 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":"syn-cur-str"}'
        Assert-That ((-not [bool]$pc2.ok) -and ([string]$pc2.error -ceq 'cursor-malformado')) 'parser: cursor-string recusado' ('err=' + [string]$pc2.error)
        # C28. cursor numero => malformado
        $pc3 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":5}'
        Assert-That ((-not [bool]$pc3.ok) -and ([string]$pc3.error -ceq 'cursor-malformado')) 'parser: cursor-numero recusado' ('err=' + [string]$pc3.error)
        # C29. next numero (topo) => malformado
        $pc4 = Parse-NativeTurnMessages -Body '{"data":[],"next":5}'
        Assert-That ((-not [bool]$pc4.ok) -and ([string]$pc4.error -ceq 'cursor-malformado')) 'parser: next-numero recusado' ('err=' + [string]$pc4.error)
        # C30. next objeto => malformado (espera string)
        $pc5 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":{"next":{"a":1}}}'
        Assert-That ((-not [bool]$pc5.ok) -and ([string]$pc5.error -ceq 'cursor-malformado')) 'parser: next-objeto recusado' ('err=' + [string]$pc5.error)
        # C31. next null explicito => terminal valido
        $pc6 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":{"next":null}}'
        Assert-That (([bool]$pc6.ok) -and ([string]$pc6.next -ceq '')) 'parser: next-null terminal' ('next=' + [string]$pc6.next)
        # C32. next "" explicito => terminal valido
        $pc7 = Parse-NativeTurnMessages -Body '{"data":[],"cursor":{"next":""}}'
        Assert-That (([bool]$pc7.ok) -and ([string]$pc7.next -ceq '')) 'parser: next-vazio terminal' ('next=' + [string]$pc7.next)
        # C33. next string no topo => tolerado (mesmo type implicito)
        $pc8 = Parse-NativeTurnMessages -Body '{"data":[],"next":"syn-top-33"}'
        Assert-That (([bool]$pc8.ok) -and ([string]$pc8.next -ceq 'syn-top-33')) 'parser: top-next-string tolerado' ('next=' + [string]$pc8.next)
        # C34. before com cursor malformado => erro proprio, prompt nunca chamado
        $script:promptSeen2 = $false
        $curBadFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[],"cursor":"syn-bad-str"}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { $script:promptSeen2 = $true; return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-cb"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:promptSeen2 = $false
        $rc1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-u1' -SafePrompt 'syn-prompt-u1' -TimeoutMs 10000 -RequestFn $curBadFn
        Assert-That ((-not [bool]$rc1.ok) -and ([string]$rc1.reason -like 'messages-before-cursor-invalid*') -and (-not [bool]$script:promptSeen2) -and ($null -ne $rc1.proof) -and ([string]$rc1.proof['detail'] -like 'messages-before-cursor-invalid*')) 'leg before-cursor-malformado: failed-proof sem prompt' ('reason=' + [string]$rc1.reason)
        # C35. after com cursor malformado => erro proprio
        $script:curAfterCalls = 0
        $curAfterFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:curAfterCalls++
                if ($script:curAfterCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[],"cursor":{"next":5}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-ca"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:curAfterCalls = 0
        $rc2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-u2' -SafePrompt 'syn-prompt-u2' -TimeoutMs 10000 -RequestFn $curAfterFn
        Assert-That ((-not [bool]$rc2.ok) -and ([string]$rc2.reason -like 'messages-after-cursor-invalid*') -and ($null -ne $rc2.proof) -and ([string]$rc2.proof['detail'] -like 'messages-after-cursor-invalid*')) 'leg after-cursor-malformado: failed-proof propria' ('reason=' + [string]$rc2.reason)
    }
    # D. HttpListener loopback: prompt -> wait -> messages por modo
    if (($funcs.ContainsKey('Parse-NativeTurnMessages')) -and ($funcs.ContainsKey('Invoke-LaneNativeTurn'))) {
        Invoke-Expression $funcs['Parse-NativeTurnMessages']
        Invoke-Expression $funcs['Invoke-LaneNativeTurn']
        function Get-NativeTurnTestPort {
            $tcp = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
            try { $tcp.Start(); return ([int]$tcp.LocalEndpoint.Port) } finally { try { $tcp.Stop() } catch { } }
        }
        function Wait-NativeTurnTestHttp([int]$Port, [int]$DeadlineMs = 15000) {
            # Prontidao deterministica: GET / real; qualquer resposta HTTP
            # (mesmo 404) prova o listener. Conta como 1 request servido.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt $DeadlineMs) {
                try {
                    $req = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create(('http://127.0.0.1:' + $Port + '/')))
                    $req.Method = 'GET'
                    $req.Timeout = 2000
                    try { $req.Proxy = $null } catch { }
                    $gotHttp = $false
                    try {
                        $resp = $req.GetResponse()
                        try { $resp.Close() } catch { }
                        $gotHttp = $true
                    } catch {
                        # PS5.1 embrulha a WebException (ex. o 404 do /);
                        # qualquer resposta HTTP prova o listener.
                        $we = $null
                        $scan = $_.Exception
                        $sdepth = 0
                        while (($null -ne $scan) -and ($sdepth -lt 4)) {
                            if ($scan -is [System.Net.WebException]) { $we = $scan; break }
                            try { $scan = $scan.InnerException } catch { $scan = $null }
                            $sdepth++
                        }
                        if (($null -ne $we) -and ($null -ne $we.Response)) {
                            try { $we.Response.Close() } catch { }
                            $gotHttp = $true
                        }
                    }
                    if ($gotHttp) { return $true }
                } catch { }
                Start-Sleep -Milliseconds 200
            }
            return $false
        }
        function Start-NativeTurnFakeService([int]$Port, [string]$Mode, [string]$Canary, [int]$ExpectedHits) {
            # Saida por demanda: encerra sozinho ao servir ExpectedHits
            # (probe HTTP + requests do teste) ou no teto de 20s; accept
            # nao-bloqueante em fatias de 500ms (sem GetContext aberto),
            # entao Remove-Job nunca precisa interromper job preso.
            $job = Start-Job -ScriptBlock {
                param($Port, $Mode, $Canary, $ExpectedHits)
                $ErrorActionPreference = 'Stop'
                $lis = New-Object Net.HttpListener
                $lis.Prefixes.Add(('http://127.0.0.1:' + $Port + '/'))
                $lis.Start()
                $msgHits = 0
                $served = 0
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try {
                    # Um unico accept pendente por vez: rearma ANTES de
                    # consumir o completo; EndGetContext sempre no handle
                    # ja sinalizado (nunca bloqueia). Fatias de 500ms +
                    # teto de 20s; saida normal por contagem.
                    $iar = $null
                    try { $iar = $lis.BeginGetContext($null, $null) } catch { $iar = $null }
                    $acceptOk = ($null -ne $iar)
                    while ($acceptOk -and ($served -lt $ExpectedHits) -and ($sw.Elapsed.TotalSeconds -lt 20)) {
                        if (-not $iar.AsyncWaitHandle.WaitOne(500)) { continue }
                        $cur = $iar
                        $iar = $null
                        try { $iar = $lis.BeginGetContext($null, $null) } catch { $iar = $null }
                        if ($null -eq $iar) { $acceptOk = $false }
                        $ctx = $null
                        try { $ctx = $lis.EndGetContext($cur) } catch { $ctx = $null; continue }
                        if ($null -eq $ctx) { continue }
                        $served++
                        try {
                            $req = $ctx.Request
                            $resp = $ctx.Response
                            $raw = [string]$req.RawUrl
                            $pathOnly = ($raw -split '\?')[0]
                            $isPrompt = (($req.HttpMethod -ceq 'POST') -and ($pathOnly -like '*/prompt'))
                            $isWait = (($req.HttpMethod -ceq 'POST') -and ($pathOnly -like '*/wait'))
                            $isMsg = (($req.HttpMethod -ceq 'GET') -and ($pathOnly -like '*/message*'))
                            $code = 404
                            $body = ''
                            if ($isPrompt) {
                                if ($Mode -ceq 'authrequired') {
                                    # Servico que exige auth: sem Authorization
                                    # => 401; a perna direta nunca envia auth,
                                    # entao sempre falha fail-closed aqui.
                                    $authHdr = ''
                                    try { $authHdr = [string]$req.Headers['Authorization'] } catch { $authHdr = '' }
                                    if (-not [string]::IsNullOrWhiteSpace($authHdr)) { $code = 200; $body = '{"data":{"id":"syn-inbox-auth"}}' }
                                    else { $code = 401; $body = '{"error":"syn-auth-required"}' }
                                } else { $code = 200; $body = '{"data":{"id":"syn-inbox-loop"}}' }
                            }
                            elseif ($isWait) {
                                if ($Mode -ceq 'waitfail') { $code = 500; $body = '{"error":"syn-wait-500"}' }
                                elseif ($Mode -ceq 'slowwait') { Start-Sleep -Seconds 6; $code = 204; $body = '' }
                                else { $code = 204; $body = '' }
                            }
                            elseif ($isMsg) {
                                if ($Mode -ceq 'badshape') { $code = 200; $body = 'GARBAGE{{{loop' }
                                elseif ($Mode -ceq 'nonewtext') { $code = 200; $body = '{"data":[]}' }
                                else {
                                    $msgHits++
                                    if ($msgHits -le 1) { $code = 200; $body = '{"data":[]}' }
                                    else { $code = 200; $body = ('{"data":[{"role":"assistant","content":[{"type":"text","text":"' + $Canary + ' reply syn"}]}]}') }
                                }
                            }
                            $resp.StatusCode = [int]$code
                            if ($code -eq 204) { $resp.ContentLength64 = 0 }
                            else {
                                $buf = [Text.Encoding]::UTF8.GetBytes($body)
                                $resp.ContentType = 'application/json'
                                $resp.ContentLength64 = $buf.Length
                                $resp.OutputStream.Write($buf, 0, $buf.Length)
                            }
                            $resp.OutputStream.Close()
                        } catch { try { $ctx.Response.OutputStream.Close() } catch { } }
                    }
                } finally { try { $lis.Stop() } catch { } }
            } -ArgumentList @($Port, $Mode, $Canary, $ExpectedHits)
            return $job
        }
        # D1. happy via loopback real (probe + before + prompt + wait + after = 5)
        $portD1 = Get-NativeTurnTestPort
        $jobD1 = Start-NativeTurnFakeService -Port $portD1 -Mode 'happy' -Canary 'syn-d1' -ExpectedHits 5
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD1) 'loopback happy: listener no ar' 'sem listener'
            $rd1 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d1' -SafePrompt 'syn-prompt-d1' -TimeoutMs 15000 -BaseUrl ('http://127.0.0.1:' + $portD1)
            Assert-That (([bool]$rd1.attempted) -and ([bool]$rd1.ok) -and ([bool]$rd1.wait204) -and ([int]$rd1.textsNew -ge 1)) 'loopback happy: prompt200 wait204 texto-novo' ('ok=' + [bool]$rd1.ok + ' novos=' + [int]$rd1.textsNew)
            Assert-That (($null -ne $rd1.proof) -and ([string]$rd1.proof['proof'] -ceq 'model-native-prompt')) 'loopback happy: proof emitida' 'sem proof'
        } finally { try { Wait-Job -Job $jobD1 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD1 -Force -ErrorAction SilentlyContinue } catch { } }
        # D2. wait sem 204 via loopback (probe + before + prompt + wait = 4)
        $portD2 = Get-NativeTurnTestPort
        $jobD2 = Start-NativeTurnFakeService -Port $portD2 -Mode 'waitfail' -Canary 'syn-d2' -ExpectedHits 4
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD2) 'loopback waitfail: listener no ar' 'sem listener'
            $rd2 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d2' -SafePrompt 'syn-prompt-d2' -TimeoutMs 15000 -BaseUrl ('http://127.0.0.1:' + $portD2)
            Assert-That ((-not [bool]$rd2.ok) -and ($null -ne $rd2.proof) -and ([string]$rd2.proof['detail'] -like 'wait-status-500*') -and (-not [bool]$rd2.wait204) -and ([int]$rd2.waitStatus -eq 500)) 'loopback wait-500: failed-proof com reason' ('ok=' + [bool]$rd2.ok + ' wait=' + [int]$rd2.waitStatus)
        } finally { try { Wait-Job -Job $jobD2 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD2 -Force -ErrorAction SilentlyContinue } catch { } }
        # D3. messages sem texto novo via loopback (probe + before + prompt + wait + after = 5)
        $portD3 = Get-NativeTurnTestPort
        $jobD3 = Start-NativeTurnFakeService -Port $portD3 -Mode 'nonewtext' -Canary 'syn-d3' -ExpectedHits 5
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD3) 'loopback nonewtext: listener no ar' 'sem listener'
            $rd3 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d3' -SafePrompt 'syn-prompt-d3' -TimeoutMs 15000 -BaseUrl ('http://127.0.0.1:' + $portD3)
            Assert-That ((-not [bool]$rd3.ok) -and ([bool]$rd3.wait204) -and ($null -ne $rd3.proof) -and ([string]$rd3.proof['detail'] -like 'no-new-text*')) 'loopback sem-texto-novo: failed-proof com wait204' ('ok=' + [bool]$rd3.ok)
        } finally { try { Wait-Job -Job $jobD3 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD3 -Force -ErrorAction SilentlyContinue } catch { } }
        # D4. shape invalido via loopback (probe + before = 2)
        $portD4 = Get-NativeTurnTestPort
        $jobD4 = Start-NativeTurnFakeService -Port $portD4 -Mode 'badshape' -Canary 'syn-d4' -ExpectedHits 2
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD4) 'loopback badshape: listener no ar' 'sem listener'
            $rd4 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d4' -SafePrompt 'syn-prompt-d4' -TimeoutMs 15000 -BaseUrl ('http://127.0.0.1:' + $portD4)
            Assert-That ((-not [bool]$rd4.ok) -and ($null -ne $rd4.proof) -and ([string]$rd4.proof['detail'] -like 'messages-before-invalid*')) 'loopback shape-invalido: failed-proof' ('ok=' + [bool]$rd4.ok)
        } finally { try { Wait-Job -Job $jobD4 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD4 -Force -ErrorAction SilentlyContinue } catch { } }
        # D5. timeout do wait via loopback (probe + before + prompt + wait = 4;
        # servidor dorme 6s > cliente 3s; job sai sozinho ao servir)
        $portD5 = Get-NativeTurnTestPort
        $jobD5 = Start-NativeTurnFakeService -Port $portD5 -Mode 'slowwait' -Canary 'syn-d5' -ExpectedHits 4
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD5) 'loopback slowwait: listener no ar' 'sem listener'
            $threwD5 = $false
            $rd5 = $null
            try { $rd5 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d5' -SafePrompt 'syn-prompt-d5' -TimeoutMs 3000 -BaseUrl ('http://127.0.0.1:' + $portD5) } catch { $threwD5 = $true }
            Assert-That ((-not $threwD5) -and ($null -ne $rd5) -and (-not [bool]$rd5.ok) -and ([string]$rd5.reason -like 'wait-timeout*') -and ($null -ne $rd5.proof) -and ([string]$rd5.proof['detail'] -like 'wait-timeout*')) 'loopback wait-timeout: failed-proof sem throw' ('threw=' + $threwD5 + ' reason=' + [string]$rd5.reason)
        } finally { try { Wait-Job -Job $jobD5 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD5 -Force -ErrorAction SilentlyContinue } catch { } }
        # D6. servico que exige auth, perna direta sem auth => fail-closed
        # (probe + before publico + prompt 401 = 3; o 401 isola a causa auth)
        $portD6 = Get-NativeTurnTestPort
        $jobD6 = Start-NativeTurnFakeService -Port $portD6 -Mode 'authrequired' -Canary 'syn-d6' -ExpectedHits 3
        try {
            Assert-That (Wait-NativeTurnTestHttp -Port $portD6) 'loopback authrequired: listener no ar' 'sem listener'
            $rd6 = Invoke-LaneNativeTurn -SessionId 'syn-sess-d6' -SafePrompt 'syn-prompt-d6' -TimeoutMs 15000 -BaseUrl ('http://127.0.0.1:' + $portD6)
            Assert-That ((-not [bool]$rd6.ok) -and ($null -ne $rd6.proof) -and ([string]$rd6.proof['proof'] -ceq 'model-native-failed') -and ([string]$rd6.reason -like 'prompt-status-401*')) 'loopback sem-auth: failed-proof no prompt' ('reason=' + [string]$rd6.reason)
        } finally { try { Wait-Job -Job $jobD6 -Timeout 15 | Out-Null } catch { }; try { Remove-Job -Job $jobD6 -Force -ErrorAction SilentlyContinue } catch { } }
    }
    # E. ordem, teto de tentativas, evidencia e regressoes estaticas
    if (($funcs.ContainsKey('New-LaneModelTurnOutcome')) -and ($funcs.ContainsKey('Invoke-LaneModelTurn')) -and ($funcs.ContainsKey('Invoke-LaneNativeTurn')) -and ($funcs.ContainsKey('Test-LaneModelUnavailableOutput'))) {
        Invoke-Expression $funcs['Test-LaneModelUnavailableOutput']
        $outFn = [string]$funcs['New-LaneModelTurnOutcome']
        $turnFn = [string]$funcs['Invoke-LaneModelTurn']
        $natFn = [string]$funcs['Invoke-LaneNativeTurn']
        # E1. decisao antiga intacta: chamada so com FirstResult nao expoe nativa
        Invoke-Expression $funcs['New-LaneModelTurnOutcome']
        $fixE = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'ERROR Model unavailable: syn-model-e1'; JobAssigned = $true; JobNote = 'syn' }
        $oE = New-LaneModelTurnOutcome -FirstResult $fixE -SessionId 'syn-sess-e1' -SafePrompt 'syn-prompt-e1' -Model 'syn-model-e1'
        Assert-That (([bool]$oE.retryDue) -and (-not [bool]$oE.nativeAttempted) -and (-not [bool]$oE.nativeOk) -and ($null -eq $oE.nativeProof)) 'outcome estendido: callers antigos sem nativa' 'campos divergentes'
        Assert-That (([int]$oE.calls -eq 1) -and ($null -ne $oE.refusedProof)) 'outcome estendido: calls e recusa intactos sem nativa' 'regressao'
        # E2. turn delega a perna nativa como ultimo fallback
        Assert-That ($turnFn.Contains('Invoke-LaneNativeTurn')) 'turn chama a perna nativa' 'chamada ausente'
        $okPos = $turnFn.IndexOf('$res.ok = (')
        $natPos = $turnFn.IndexOf('Invoke-LaneNativeTurn')
        Assert-That ((($okPos -ge 0) -and ($natPos -ge 0) -and ($okPos -lt $natPos))) 'ordem: CLI decide antes da nativa' ('ok=' + $okPos + ' nat=' + $natPos)
        # E3. sem spawn novo no turn (teto: 2 CLI + 1 nativa = 3 tentativas)
        $spawns = @([regex]::Matches($turnFn, 'Invoke-SpikeChild'))
        Assert-That (@($spawns).Count -eq 2) 'turn mantem 2 spawns CLI (nativa sem spawn)' ('spawns=' + @($spawns).Count)
        Assert-That ($turnFn.Contains('3')) 'turn documenta teto de 3 tentativas' 'teto ausente'
        # E4. proof model-native-prompt definida 1x na perna, sempre ok=true
        $natDefs = @([regex]::Matches($text, "proof = 'model-native-prompt'"))
        Assert-That (@($natDefs).Count -eq 1) 'model-native-prompt definida 1x (perna)' ('count=' + @($natDefs).Count)
        $natBad = @([regex]::Matches($text, 'proof = ''model-native-prompt''; ok = \$false'))
        Assert-That (@($natBad).Count -eq 0) 'model-native-prompt nunca com ok=false' ('count=' + @($natBad).Count)
        # E5. usos gated nos 3 cenarios com turn (18/20/21)
        Assert-That ($text.Contains('if ($null -ne $turn18.nativeProof)')) '18: nativa gated em nativeProof' 'guard ausente'
        Assert-That ($text.Contains('if ($null -ne $turn20.nativeProof)')) '20: nativa gated em nativeProof' 'guard ausente'
        Assert-That ($text.Contains('if ($null -ne $turn21.nativeProof)')) '21: nativa gated em nativeProof' 'guard ausente'
        # E6. contrato da perna: sem queue, sem host hardcoded, sem segredo
        Assert-That (($natFn -match '"text"') -and ($natFn -notmatch 'queue')) 'perna: body minimo sem queue' 'contrato divergente'
        Assert-That (($natFn -notmatch '127\.0\.0\.1') -and ($natFn -notmatch 'localhost')) 'perna: sem host hardcoded (BaseUrl injetado)' 'host fixo presente'
        Assert-That (($natFn -notmatch 'PASSWORD') -and ($natFn -notmatch 'SECRET') -and ($natFn -notmatch 'TOKEN')) 'perna: sem segredo no codigo' 'literal sensivel'
        Assert-That (($natFn.Contains('StatusCode')) -and ($natFn.Contains('204')) -and ($natFn.Contains('TimedOut'))) 'perna: checa 200/204/timeout defensivamente' 'checks ausentes'
        # E7. vereditos/gates intactos
        Assert-That ($text.Contains('$hardFail20 = $false') -and $text.Contains('$hardFail21 = $false')) 'vereditos 20/21 intactos' 'gates alterados'
        Assert-That ($text.Contains("elseif (`$allOk) { 'blocked' }")) 'veredito 18 intacto' 'gate alterado'
        Assert-That ($text.Contains('$res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))')) 'expressao de turn-ok CLI intacta' 'semantica alterada'
        # E8. ASCII-only na mudanca + no teste; sem rede externa no teste
        $newSpans = @($funcs['Parse-NativeTurnMessages'], $funcs['Invoke-LaneNativeTurn'])
        if ($funcs.ContainsKey('New-LaneNativeApiRequestFn')) { $newSpans += $funcs['New-LaneNativeApiRequestFn'] }
        $spanLines = @()
        foreach ($ln in ($text -split "`r?`n")) {
            if (($ln -match 'NativeTurn') -or ($ln -match 'model-native-prompt') -or ($ln -match 'nativeProof') -or ($ln -match 'native-transport') -or ($ln -match 'prompt-invalid-shape') -or ($ln -match 'cursor-repeat') -or ($ln -match 'truncated') -or ($ln -match 'dedupKeys') -or ($ln -match 'NativeBaseUrl') -or ($ln -match 'NativeRequestFn') -or ($ln -match 'cursor-malformado') -or ($ln -match 'cursor-invalid') -or ($ln -match 'model-native-failed') -or ($ln -match '/api/experimental/session')) { $spanLines += $ln }
        }
        $newText = (($newSpans -join "`n") + "`n" + ($spanLines -join "`n"))
        $nonAsciiNew = @([regex]::Matches($newText, '[^\x00-\x7F]'))
        Assert-That (@($nonAsciiNew).Count -eq 0) 'mudanca ASCII-only' ('count=' + @($nonAsciiNew).Count)
        $selfText = [IO.File]::ReadAllText($PSCommandPath)
        $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
        Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
        Assert-That (($selfText -notmatch 'https?://(?!127\.0\.0\.1)[A-Za-z0-9]') -and ($selfText -match 'HttpListener')) 'teste so loopback via HttpListener' 'rede externa ou sem HttpListener'
    }
    # F. integracao do turn com dependencias simuladas + contadores
    if (($funcs.ContainsKey('Invoke-LaneModelTurn')) -and ($funcs.ContainsKey('Invoke-LaneNativeTurn')) -and ($funcs.ContainsKey('Parse-NativeTurnMessages')) -and ($funcs.ContainsKey('New-LaneModelTurnOutcome')) -and ($funcs.ContainsKey('Test-LaneModelUnavailableOutput'))) {
        Invoke-Expression $funcs['Test-LaneModelUnavailableOutput']
        Invoke-Expression $funcs['New-LaneModelTurnOutcome']
        Invoke-Expression $funcs['Parse-NativeTurnMessages']
        Invoke-Expression $funcs['Invoke-LaneNativeTurn']
        Invoke-Expression $funcs['Invoke-LaneModelTurn']
        if ($funcs.ContainsKey('Get-LaneTurnUnitText')) { Invoke-Expression $funcs['Get-LaneTurnUnitText'] }
        if ($funcs.ContainsKey('Test-LaneSignificantError')) { Invoke-Expression $funcs['Test-LaneSignificantError'] }
        if ($funcs.ContainsKey('Test-LaneTurnEvidence')) { Invoke-Expression $funcs['Test-LaneTurnEvidence'] }
        if ($funcs.ContainsKey('Get-LaneSafeText')) { Invoke-Expression $funcs['Get-LaneSafeText'] }
        if ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) { Invoke-Expression $funcs['Get-LaneModelTurnOutputExcerpt'] }
        function Test-LaneModelKeyAvailable { return $true }
        function Get-LaneModelChildEnv { param($BaseEnv = $null) return @{} }
        function New-RuntimeJobObject { return @{ Ok = $true } }
        function Get-RuntimeJobLimitFlags { param($Job = $null) return @{ Ok = $true; KillOnClose = $true } }
        function Close-RuntimeJobObject { param($Job = $null) return @{ Ok = $true } }
        $script:cliCalls = 0
        $script:cliSawModel = New-Object System.Collections.ArrayList
        $script:cliMode = 'ok'
        function Invoke-SpikeChild {
            param($FilePath = '', $ArgumentList = @(), $EnvSet = $null, $EnvRemove = $null, $WorkingDirectory = '', $TimeoutMs = 0, [switch]$CleanEnvironment, [switch]$StdinNul, $JobObject = $null)
            $script:cliCalls++
            [void]$script:cliSawModel.Add((@($ArgumentList) -contains '--model'))
            if ([string]$script:cliMode -ceq 'ok') { return @{ ExitCode = 0; TimedOut = $false; Stdout = '{"role":"assistant","content":[{"type":"text","text":"syn-cli-ok"}]}'; Stderr = ''; JobAssigned = $true; JobNote = 'syn-stub' } }
            if (([string]$script:cliMode -ceq 'once-then-ok') -and ($script:cliCalls -ge 2)) { return @{ ExitCode = 0; TimedOut = $false; Stdout = '{"role":"assistant","content":[{"type":"text","text":"syn-cli-retry-ok"}]}'; Stderr = ''; JobAssigned = $true; JobNote = 'syn-stub' } }
            return @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'Model unavailable: syn-stub-model'; JobAssigned = $true; JobNote = 'syn-stub' }
        }
        $script:legCalls = 0
        $script:realNativeLeg = ${function:Invoke-LaneNativeTurn}
        function Invoke-LaneNativeTurn {
            param([string]$SessionId = '', [string]$SafePrompt = '', [int]$TimeoutMs = 0, [string]$BaseUrl = '', $RequestFn = $null)
            $script:legCalls++
            return (& $script:realNativeLeg -SessionId $SessionId -SafePrompt $SafePrompt -TimeoutMs $TimeoutMs -BaseUrl $BaseUrl -RequestFn $RequestFn)
        }
        $script:natCalls = 0
        $fHappy = {
            param($Method, $Path, $Body, $TimeoutMs)
            $script:natCalls++
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                if ($script:natCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-f-new"}]}]}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-f"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        # F1. CLI ok => nativa nunca chamada
        $script:cliMode = 'ok'; $script:cliCalls = 0; $script:legCalls = 0; $script:natCalls = 0
        [void]$script:cliSawModel.Clear()
        $fNever = { param($Method, $Path, $Body, $TimeoutMs) $script:natCalls++; return @{ StatusCode = 500; Body = '{}'; TimedOut = $false } }
        $t1 = Invoke-LaneModelTurn -SessionId 'syn-sess-f1' -Prompt 'syn-prompt-f1' -TimeoutMs 10000 -NativeRequestFn $fNever
        Assert-That (([bool]$t1.ok) -and ([int]$script:cliCalls -eq 1) -and ([int]$script:legCalls -eq 0) -and (-not [bool]$t1.native) -and ($null -eq $t1.nativeProof)) 'turn CLI-ok: nativa nunca chamada' ('cli=' + $script:cliCalls + ' leg=' + $script:legCalls)
        # F2. CLI falha 2x + nativa happy => nativa decide, exatamente 1x
        $script:cliMode = 'unavailable'; $script:cliCalls = 0; $script:legCalls = 0; $script:natCalls = 0
        [void]$script:cliSawModel.Clear()
        $t2 = Invoke-LaneModelTurn -SessionId 'syn-sess-f2' -Prompt 'syn-prompt-f2' -TimeoutMs 10000 -NativeRequestFn $fHappy
        Assert-That (([bool]$t2.ok) -and ([bool]$t2.native) -and ([int]$script:cliCalls -eq 2) -and ([int]$script:legCalls -eq 1) -and ([int]$script:natCalls -eq 4)) 'turn CLI-fail+nativa-ok: perna decide 1x' ('cli=' + $script:cliCalls + ' leg=' + $script:legCalls + ' req=' + $script:natCalls)
        Assert-That (([int]$t2.calls -le 3) -and ($null -ne $t2.nativeProof) -and ([string]$t2.nativeProof['proof'] -ceq 'model-native-prompt')) 'turn nativa-ok: teto 3 + proof' ('calls=' + [int]$t2.calls)
        Assert-That (([bool]$script:cliSawModel[0]) -and (-not [bool]$script:cliSawModel[1])) 'turn ordem: 1a com pin, retry default' 'ordem divergente'
        # F3. retry ok => nativa nao corre (CLI default passou)
        $script:cliMode = 'once-then-ok'; $script:cliCalls = 0; $script:legCalls = 0; $script:natCalls = 0
        [void]$script:cliSawModel.Clear()
        $t3 = Invoke-LaneModelTurn -SessionId 'syn-sess-f3' -Prompt 'syn-prompt-f3' -TimeoutMs 10000 -NativeRequestFn $fHappy
        Assert-That (([bool]$t3.ok) -and (-not [bool]$t3.native) -and ([int]$script:legCalls -eq 0) -and ([int]$script:cliCalls -eq 2)) 'turn retry-ok: nativa nao corre' ('leg=' + $script:legCalls)
        # F4. prompt 401 via turn => fail, perna correu 1x, sem proof
        $script:cliMode = 'unavailable'; $script:cliCalls = 0; $script:legCalls = 0
        $f401 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 401; Body = '{"error":"syn-401"}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $t4 = Invoke-LaneModelTurn -SessionId 'syn-sess-f4' -Prompt 'syn-prompt-f4' -TimeoutMs 10000 -NativeRequestFn $f401
        Assert-That ((-not [bool]$t4.ok) -and ($null -ne $t4.nativeProof) -and ([string]$t4.nativeProof['proof'] -ceq 'model-native-failed') -and ([string]$t4.nativeProof['detail'] -like 'prompt-status-401*') -and ([int]$script:legCalls -eq 1)) 'turn prompt-401: failed-proof sem veredito' ('ok=' + [bool]$t4.ok)
        # F5. wait 403 via turn => fail, sem proof
        $script:cliCalls = 0; $script:legCalls = 0
        $f403 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-f5"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 403; Body = '{"error":"syn-403"}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $t5 = Invoke-LaneModelTurn -SessionId 'syn-sess-f5' -Prompt 'syn-prompt-f5' -TimeoutMs 10000 -NativeRequestFn $f403
        Assert-That ((-not [bool]$t5.ok) -and ($null -ne $t5.nativeProof) -and ([string]$t5.nativeProof['detail'] -like 'wait-status-403*') -and ([int]$script:legCalls -eq 1)) 'turn wait-403: failed-proof sem veredito' ('ok=' + [bool]$t5.ok)
        # F6. cursor repetido via turn => fail
        $script:cliCalls = 0; $script:legCalls = 0; $script:repCalls = 0
        $t6 = Invoke-LaneModelTurn -SessionId 'syn-sess-f6' -Prompt 'syn-prompt-f6' -TimeoutMs 10000 -NativeRequestFn $repFn
        Assert-That ((-not [bool]$t6.ok) -and ($null -ne $t6.nativeProof) -and ([string]$t6.nativeProof['detail'] -like 'messages-after-cursor-repeat*') -and ([int]$script:legCalls -eq 1)) 'turn cursor-repetido: failed-proof sem veredito' ('ok=' + [bool]$t6.ok)
        # F7. sem transporte (sem BaseUrl/RequestFn) => nativa nao tenta, CLI prevalece
        $script:cliMode = 'unavailable'; $script:cliCalls = 0; $script:legCalls = 0
        $t7 = Invoke-LaneModelTurn -SessionId 'syn-sess-f7' -Prompt 'syn-prompt-f7' -TimeoutMs 10000
        Assert-That ((-not [bool]$t7.ok) -and (-not [bool]$t7.native) -and ([int]$t7.nativeCalls -eq 0) -and ([int]$script:legCalls -eq 0)) 'turn sem-transporte: nativa ausente, CLI prevalece' ('native=' + [bool]$t7.native)
        # F8. leg direto: prompt 403 e wait 401 cobertos
        $fP403 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 403; Body = '{}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $l81 = Invoke-LaneNativeTurn -SessionId 'syn-sess-f8a' -SafePrompt 'syn-prompt-f8a' -TimeoutMs 10000 -RequestFn $fP403
        Assert-That ((-not [bool]$l81.ok) -and ([string]$l81.reason -like 'prompt-status-403*')) 'leg prompt-403 direto' ('reason=' + [string]$l81.reason)
        $fW401 = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-f8b"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 401; Body = '{}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $l82 = Invoke-LaneNativeTurn -SessionId 'syn-sess-f8b' -SafePrompt 'syn-prompt-f8b' -TimeoutMs 10000 -RequestFn $fW401
        Assert-That ((-not [bool]$l82.ok) -and ([string]$l82.reason -like 'wait-status-401*')) 'leg wait-401 direto' ('reason=' + [string]$l82.reason)
        # F9. estaticos: turn sem host implicito; cenarios injetam RequestFn autenticado
        Assert-That ($turnFn -notmatch '127\.0\.0\.1') 'turn: sem host implicito (transporte injetado)' 'host fixo no turn'
        $reqUseCount = 0
        $baseUseCount = 0
        foreach ($ln in ($text -split "`r?`n")) {
            if ($ln -match '\$turn(18|20|21) = Invoke-LaneModelTurn') {
                if ($ln -match '-NativeRequestFn \(New-LaneNativeApiRequestFn\)') { $reqUseCount++ }
                if ($ln -match '-NativeBaseUrl') { $baseUseCount++ }
            }
        }
        Assert-That ($reqUseCount -eq 3) 'cenarios 18/20/21 injetam NativeRequestFn autenticado' ('count=' + $reqUseCount)
        Assert-That ($baseUseCount -eq 0) 'cenarios sem NativeBaseUrl (direto sem auth nunca autenticaria)' ('count=' + $baseUseCount)
        # F10. drenagem deterministica: sem parada forcada de job; job com
        # accept nao-bloqueante e saida por contagem de requests
        Assert-That ($selfText -notmatch ('Stop-' + 'Job')) 'harness: saida por demanda sem parada forcada' 'parada forcada presente'
        Assert-That ($selfText -match 'BeginGetContext') 'harness: accept nao-bloqueante' 'accept bloqueante'
    }
    # G. RequestFn autenticado via Invoke-Api (sem servico real; stub local
    # do contrato ok/exit/truncated/finished/body; a lane nunca executa aqui)
    if (@($funcs.Keys).Count -gt 0) {
        Assert-That ($funcs.ContainsKey('New-LaneNativeApiRequestFn')) 'helper New-LaneNativeApiRequestFn exists' 'helper ausente na lane'
        if ($funcs.ContainsKey('New-LaneNativeApiRequestFn')) {
            Invoke-Expression $funcs['New-LaneNativeApiRequestFn']
            $apiFn = New-LaneNativeApiRequestFn
            Assert-That (($null -ne $apiFn) -and ($apiFn -is [scriptblock])) 'helper retorna scriptblock' 'tipo divergente'
            function Invoke-Api {
                param([string]$Method = '', [string]$Path = '', [string]$Data = '', [int]$TimeoutMs = 0, [int]$MaxChars = 524288)
                $script:apiSeenMethod = [string]$Method
                $script:apiSeenPath = [string]$Path
                $script:apiSeenBody = [string]$Data
                $script:apiSeenTimeout = [int]$TimeoutMs
                return $script:apiResult
            }
            # G3. roteia Method/Path/Body/TimeoutMs ao Invoke-Api
            $script:apiResult = @{ ok = $true; exit = 0; truncated = $false; finished = $true; body = '{"data":{"id":"syn-stub-01"}}' }
            $script:apiSeenMethod = ''; $script:apiSeenPath = ''; $script:apiSeenBody = ''; $script:apiSeenTimeout = 0
            $gRoute = & $apiFn -Method 'POST' -Path '/api/session/syn-g/prompt' -Body '{"text":"hi"}' -TimeoutMs 1234
            Assert-That (([string]$script:apiSeenMethod -ceq 'POST') -and ([string]$script:apiSeenPath -ceq '/api/session/syn-g/prompt')) 'api-fn roteia method+path' ($script:apiSeenMethod + ' ' + $script:apiSeenPath)
            Assert-That (([string]$script:apiSeenBody -ceq '{"text":"hi"}') -and ([int]$script:apiSeenTimeout -eq 1234)) 'api-fn roteia body+timeout' ('timeout=' + $script:apiSeenTimeout)
            # G4. ok com corpo => 200, corpo preservado, sem timeout
            Assert-That (([int]$gRoute.StatusCode -eq 200) -and ([string]$gRoute.Body -ceq '{"data":{"id":"syn-stub-01"}}') -and (-not [bool]$gRoute.TimedOut)) 'api-fn ok+corpo mapeia 200' ('code=' + [int]$gRoute.StatusCode)
            # G5. ok com corpo vazio => 204 (idle)
            $script:apiResult = @{ ok = $true; exit = 0; truncated = $false; finished = $true; body = '' }
            $gEmpty = & $apiFn -Method 'POST' -Path '/api/session/syn-g/wait' -Body '' -TimeoutMs 10000
            Assert-That ([int]$gEmpty.StatusCode -eq 204) 'api-fn ok+vazio mapeia 204' ('code=' + [int]$gEmpty.StatusCode)
            # G6. !ok => -1 fail-closed, sem corpo aproveitado
            $script:apiResult = @{ ok = $false; exit = 1; truncated = $false; finished = $true; body = '{"error":"syn-stub-06"}' }
            $gFail = & $apiFn -Method 'POST' -Path '/api/session/syn-g/prompt' -Body '{}' -TimeoutMs 10000
            Assert-That (([int]$gFail.StatusCode -eq -1) -and ([string]$gFail.Body -ceq '') -and (-not [bool]$gFail.TimedOut)) 'api-fn !ok vira -1 fail-closed' ('code=' + [int]$gFail.StatusCode)
            # G7. !finished => timeout (nao concluido)
            $script:apiResult = @{ ok = $false; exit = -1; truncated = $false; finished = $false; body = '' }
            $gUnf = & $apiFn -Method 'GET' -Path '/api/session/syn-g/message' -Body '' -TimeoutMs 10000
            Assert-That (([bool]$gUnf.TimedOut) -and ([int]$gUnf.StatusCode -eq -1)) 'api-fn !finished vira timeout' ('timedout=' + [bool]$gUnf.TimedOut)
            # G8. truncated (mesmo com ok) => fail-closed
            $script:apiResult = @{ ok = $true; exit = 0; truncated = $true; finished = $true; body = '{"data":[]}' }
            $gTrunc = & $apiFn -Method 'GET' -Path '/api/session/syn-g/message' -Body '' -TimeoutMs 10000
            Assert-That ([int]$gTrunc.StatusCode -eq -1) 'api-fn truncado vira -1' ('code=' + [int]$gTrunc.StatusCode)
            # G9. Invoke-Api sem resultado => fail-closed sem throw
            $script:apiResult = $null
            $threwG9 = $false
            $gNull = $null
            try { $gNull = & $apiFn -Method 'GET' -Path '/x' -Body '' -TimeoutMs 10000 } catch { $threwG9 = $true }
            Assert-That ((-not $threwG9) -and ($null -ne $gNull) -and ([int]$gNull.StatusCode -eq -1)) 'api-fn null fail-closed sem throw' ('threw=' + $threwG9)
            # G10. sem segredo dentro: delega ao Invoke-Api, sem valor sensivel
            $hlpFn = [string]$funcs['New-LaneNativeApiRequestFn']
            Assert-That (($hlpFn -match 'Invoke-Api') -and ($hlpFn -notmatch '(?i)(password|secret|token|api[_-]?key)\s*=\s*[''"][^''"]+[''"]')) 'helper sem segredo, delega auth' 'literal sensivel ou sem delegacao'
        }
    }
    # H. contrato de paths + proof de falha (sem servico real alem do loopback)
    if (($funcs.ContainsKey('Parse-NativeTurnMessages')) -and ($funcs.ContainsKey('Invoke-LaneNativeTurn'))) {
        Invoke-Expression $funcs['Parse-NativeTurnMessages']
        Invoke-Expression $funcs['Invoke-LaneNativeTurn']
        $script:hCalls = 0
        $script:seenPaths = New-Object System.Collections.ArrayList
        $hHappy = {
            param($Method, $Path, $Body, $TimeoutMs)
            [void]$script:seenPaths.Add(([string]$Method + ' ' + [string]$Path))
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:hCalls++
                if ($script:hCalls -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-h-new"}]}]}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-h"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:hCalls = 0
        $rh = Invoke-LaneNativeTurn -SessionId 'syn-sess-h1' -SafePrompt 'syn-prompt-h1' -TimeoutMs 10000 -RequestFn $hHappy
        Assert-That ([bool]$rh.ok) 'leg paths: fluxo happy ok' ('ok=' + [bool]$rh.ok)
        $waitHits = @(@($script:seenPaths) | Where-Object { $_ -like 'POST */wait' })
        Assert-That ((@($waitHits).Count -eq 1) -and ([string]$waitHits[0] -ceq 'POST /api/experimental/session/syn-sess-h1/wait')) 'leg paths: wait usa /api/experimental' ('hits=' + (@($waitHits) -join ';'))
        $promptHits = @(@($script:seenPaths) | Where-Object { $_ -like 'POST */prompt' })
        Assert-That ((@($promptHits).Count -eq 1) -and ([string]$promptHits[0] -ceq 'POST /api/session/syn-sess-h1/prompt')) 'leg paths: prompt inalterado' ('hits=' + (@($promptHits) -join ';'))
        $msgHits = @(@($script:seenPaths) | Where-Object { $_ -like 'GET */message*' })
        Assert-That ((@($msgHits).Count -eq 2) -and ((@($msgHits) | Where-Object { $_ -notmatch 'experimental' }).Count -eq 2)) 'leg paths: messages inalterados' ('hits=' + (@($msgHits) -join ';'))
        $expUses = @([regex]::Matches($text, '/api/experimental/session/'))
        Assert-That (@($expUses).Count -eq 1) 'lane: prefixo experimental 1x (so wait)' ('count=' + @($expUses).Count)
        $natFnH = [string]$funcs['Invoke-LaneNativeTurn']
        Assert-That ($natFnH.Contains("proof = 'model-native-failed'")) 'perna define model-native-failed' 'definicao ausente'
        $nfBad = @([regex]::Matches($text, 'proof = ''model-native-failed''; ok = \$false'))
        Assert-That (@($nfBad).Count -eq 0) 'model-native-failed nunca com ok=false' ('count=' + @($nfBad).Count)
        # H-paged: inicial com order=asc; seguintes com cursor SEM order
        # (pin 2.0.23: Cursor cannot be combined with order); type mantido.
        $script:pgPaths = New-Object System.Collections.ArrayList
        $script:pgGets = 0
        $pgFn = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                $script:pgGets++
                [void]$script:pgPaths.Add([string]$Path)
                if ([string]$Path -match 'cursor=') {
                    if ([int]$script:pgGets -le 2) { return @{ StatusCode = 200; Body = '{"data":[],"cursor":{}}'; TimedOut = $false } }
                    return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-pg-new"}]}],"cursor":{}}'; TimedOut = $false }
                }
                return @{ StatusCode = 200; Body = '{"data":[],"cursor":{"next":"syn-pg-1"}}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-pg"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $rpg = Invoke-LaneNativeTurn -SessionId 'syn-sess-pg' -SafePrompt 'syn-prompt-pg' -TimeoutMs 10000 -RequestFn $pgFn
        Assert-That ([bool]$rpg.ok) 'leg paged: ok com cursor-{} terminal na 2a pagina' ('ok=' + [bool]$rpg.ok + ' reason=' + [string]$rpg.reason)
        $pgFirst = @(@($script:pgPaths) | Where-Object { $_ -notmatch 'cursor=' })
        $pgFollow = @(@($script:pgPaths) | Where-Object { $_ -match 'cursor=' })
        Assert-That ((@($pgFirst).Count -ge 1) -and ((@($pgFirst) | Where-Object { ($_ -match 'order=asc') -and ($_ -match 'type=assistant') }).Count -eq @($pgFirst).Count)) 'leg paged: iniciais com order=asc+type' ('paths=' + (@($pgFirst) -join ';'))
        Assert-That ((@($pgFollow).Count -ge 1) -and ((@($pgFollow) | Where-Object { ($_ -match 'type=assistant') -and ($_ -notmatch 'order=') }).Count -eq @($pgFollow).Count)) 'leg paged: seguintes com cursor SEM order' ('paths=' + (@($pgFollow) -join ';'))
    }
    # I. evidencia stdout-OU-GET (18/21): stdout sanitizado do turno com os
    # mesmos criterios do GET; sem servico real (stubs + fixtures sinteticas).
    Assert-That ($funcs.ContainsKey('Test-LaneTurnEvidence')) 'helper Test-LaneTurnEvidence exists' 'helper ausente na lane'
    Assert-That ($funcs.ContainsKey('Test-LaneTurnEvidence')) 'helper Test-LaneTurnEvidence exists' 'helper ausente na lane'
    Assert-That ($funcs.ContainsKey('Get-LaneTurnUnitText')) 'helper Get-LaneTurnUnitText exists' 'helper ausente na lane'
    if (($funcs.ContainsKey('Test-LaneTurnEvidence')) -and ($funcs.ContainsKey('Get-LaneTurnUnitText'))) {
        Invoke-Expression $funcs['Get-LaneTurnUnitText']
        Invoke-Expression $funcs['Test-LaneTurnEvidence']
        $tokC = 'CHAL21-SYN01AA02BB'
        $tokS = 'PLANNING'
        # I-unit: extracao de texto por unidade elegivel
        $u1 = $null
        try { $u1 = ConvertFrom-Json '{"role":"assistant","content":[{"type":"text","text":"syn-u1-a"},{"type":"text","text":"syn-u1-b"}]}' } catch { $u1 = $null }
        Assert-That ((Get-LaneTurnUnitText -Unit $u1) -ceq "syn-u1-a`nsyn-u1-b") 'unit: partes text concatenadas' 'divergente'
        $u2 = $null
        try { $u2 = ConvertFrom-Json '{"role":"assistant","content":"syn-u2-plain"}' } catch { $u2 = $null }
        Assert-That ((Get-LaneTurnUnitText -Unit $u2) -ceq 'syn-u2-plain') 'unit: content string direto' 'divergente'
        $u3 = $null
        try { $u3 = ConvertFrom-Json '{"role":"tool","text":"syn-u3-tool"}' } catch { $u3 = $null }
        Assert-That ((Get-LaneTurnUnitText -Unit $u3) -ceq 'syn-u3-tool') 'unit: campo text direto' 'divergente'
        Assert-That ((Get-LaneTurnUnitText -Unit $null) -ceq '') 'unit: null vira vazio' 'divergente'
        # I-pos: assistant real com tokens na MESMA mensagem
        $okBody = '{"data":[{"role":"assistant","content":[{"type":"text","text":"li ' + $tokC + ' no arquivo; estado ' + $tokS + ' preservado"}]}]}'
        $evOk = Test-LaneTurnEvidence -Text $okBody -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evOk.role) -and ([bool]$evOk.canary) -and ([bool]$evOk.state)) 'matcher: assistant real com tokens na mesma mensagem' 'divergente'
        # I-neg-user: user array text com tokens => sem role
        $userBody = '{"data":[{"role":"user","content":[{"type":"text","text":"eco ' + $tokC + ' ' + $tokS + '"}]}]}'
        $evUser = Test-LaneTurnEvidence -Text $userBody -CanaryToken $tokC -StateToken $tokS
        Assert-That ((-not [bool]$evUser.role) -and (-not [bool]$evUser.canary) -and (-not [bool]$evUser.state)) 'matcher: user array text negado' 'falso positivo'
        # I-neg-split: user tokens + assistant negativa (unidades distintas)
        $splitBody = '{"data":[{"role":"user","content":"' + $tokC + ' ' + $tokS + '"},{"role":"assistant","content":[{"type":"text","text":"narrativa generica syn-split"}]}]}'
        $evSplit = Test-LaneTurnEvidence -Text $splitBody -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evSplit.role) -and (-not [bool]$evSplit.canary) -and (-not [bool]$evSplit.state)) 'matcher: user tokens + assistant negativa nao combinam' 'falso positivo'
        # I-neg-err: erro com marcadores => negado
        $errBody = '{"role":"assistant","error":"boom syn-err","content":[{"type":"text","text":"' + $tokC + ' ' + $tokS + '"}]}'
        $evErr = Test-LaneTurnEvidence -Text $errBody -CanaryToken $tokC -StateToken $tokS
        Assert-That ((-not [bool]$evErr.role) -and (-not [bool]$evErr.canary) -and (-not [bool]$evErr.state)) 'matcher: erro com marcadores negado' 'falso positivo'
        # I-neg-echo: eco do prompt (sem desafio) por assistant => sem canario
        $echoBody = '{"data":[{"role":"assistant","content":[{"type":"text","text":"RECOVERY-read-file-../kernel-tasks/lane21.json-report-objective-state-history"}]}]}'
        $evEchoP = Test-LaneTurnEvidence -Text $echoBody -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evEchoP.role) -and (-not [bool]$evEchoP.canary) -and (-not [bool]$evEchoP.state)) 'matcher: eco do prompt sem leitura negado' 'falso positivo'
        # I-env: envelopes com role passam com mesma-unidade
        $envNaked = '[{"role":"assistant","content":"' + $tokC + ' ' + $tokS + '"}]'
        $evNaked = Test-LaneTurnEvidence -Text $envNaked -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evNaked.role) -and ([bool]$evNaked.canary)) 'matcher: lista nua elegivel' 'divergente'
        $envMsgs = '{"messages":[{"role":"assistant","content":[{"type":"text","text":"' + $tokC + ' ' + $tokS + '"}]}]}'
        $evMsgs = Test-LaneTurnEvidence -Text $envMsgs -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evMsgs.role) -and ([bool]$evMsgs.canary)) 'matcher: messages elegivel' 'divergente'
        $envNested = '{"data":{"messages":[{"sender":"assistant","content":"' + $tokC + ' ' + $tokS + '"}],"cursor":{}}}'
        $evNested = Test-LaneTurnEvidence -Text $envNested -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evNested.role) -and ([bool]$evNested.canary)) 'matcher: data.messages+sender elegivel' 'divergente'
        $envTool = '{"role":"tool","content":"' + $tokC + ' ' + $tokS + '"}'
        $evTool = Test-LaneTurnEvidence -Text $envTool -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evTool.role) -and ([bool]$evTool.canary)) 'matcher: role tool elegivel' 'divergente'
        # I-cli-deny: stream sem role nunca vale (sem aceitacao ampla)
        $evStep = Test-LaneTurnEvidence -Text '{"type":"step_start","session":"syn-cli-02"}'
        Assert-That ((-not [bool]$evStep.role) -and (-not [bool]$evStep.canary) -and (-not [bool]$evStep.state)) 'matcher: step_start sozinho nao conta' 'falso positivo'
        $evBareTx = Test-LaneTurnEvidence -Text ('{"type":"text","text":"' + $tokC + ' ' + $tokS + '"}')
        Assert-That ((-not [bool]$evBareTx.role) -and (-not [bool]$evBareTx.canary) -and (-not [bool]$evBareTx.state)) 'matcher: type:text nu sem proveniencia negado' 'aceitacao ampla'
        # I-tui: transcript real do pin (TUI, sem JSON elegivel) => negado
        $tuiReal = '> build - muse-spark-1.3-contributor' + "`n" + '-> Skill "syn-skill"' + "`n" + '[0m ok syn-tui-01'
        $evTui = Test-LaneTurnEvidence -Text $tuiReal -CanaryToken $tokC -StateToken $tokS
        Assert-That ((-not [bool]$evTui.role) -and (-not [bool]$evTui.canary) -and (-not [bool]$evTui.state)) 'matcher: transcript TUI sem JSON negado' 'falso positivo'
        # I-mixed: TUI + uma linha JSON elegivel => vale pela linha
        $mixedBody = $tuiReal + "`n" + '{"role":"assistant","content":"' + $tokC + ' ' + $tokS + '"}'
        $evMixed = Test-LaneTurnEvidence -Text $mixedBody -CanaryToken $tokC -StateToken $tokS
        Assert-That (([bool]$evMixed.role) -and ([bool]$evMixed.canary)) 'matcher: linha elegivel em stream misto vale' 'falso negativo'
        # I-esc: escapes decodificados pelo parse estrutural
        $evEscBlank = Test-LaneTurnEvidence -Text '{"role":"assistant","content":[{"type":"text","text":"\n\t \u0020"}]}' -CanaryToken $tokC -StateToken $tokS
        Assert-That (-not [bool]$evEscBlank.role) 'matcher: so-escapes em branco recusado' 'falso positivo'
        $evBs = Test-LaneTurnEvidence -Text '{"role":"assistant","content":[{"type":"text","text":"\\"}]}'
        Assert-That ([bool]$evBs.role) 'matcher: contrabarra literal em unidade elegivel conta' 'falso negativo'
        # I-lit: tokens sao literais, nao regex
        $rxTok = 'CHAL21.(SYN)+'
        $evRx = Test-LaneTurnEvidence -Text '{"role":"assistant","content":"CHAL21XSYN estado PLANNING"}' -CanaryToken $rxTok -StateToken $tokS
        Assert-That (([bool]$evRx.role) -and (-not [bool]$evRx.canary) -and (-not [bool]$evRx.state)) 'matcher: token literal, nao regex' 'regex ativo'
        # I-closed: fail-closed sem throw
        $evEmpty = Test-LaneTurnEvidence -Text ''
        Assert-That ((-not [bool]$evEmpty.role) -and (-not [bool]$evEmpty.canary) -and (-not [bool]$evEmpty.state)) 'matcher: texto vazio tudo falso' 'divergente'
        $evGarbage = Test-LaneTurnEvidence -Text 'THIS-IS-NOT-JSON{{{'
        Assert-That ((-not [bool]$evGarbage.role) -and (-not [bool]$evGarbage.canary)) 'matcher: lixo nao-JSON negado' 'divergente'
        $evNoTok = Test-LaneTurnEvidence -Text '{"role":"assistant","content":"resposta real syn-notok"}'
        Assert-That (([bool]$evNoTok.role) -and (-not [bool]$evNoTok.canary) -and (-not [bool]$evNoTok.state)) 'matcher: sem tokens, so role' 'divergente'
    }
    # I-ancerr: erro ancestral descarta documento/descendentes (Debugger);
    # JSONL avaliado por documento, sem contaminacao cruzada.
    Assert-That ($funcs.ContainsKey('Test-LaneSignificantError')) 'helper Test-LaneSignificantError exists' 'helper ausente na lane'
    if (($funcs.ContainsKey('Test-LaneTurnEvidence')) -and ($funcs.ContainsKey('Get-LaneTurnUnitText')) -and ($funcs.ContainsKey('Test-LaneSignificantError'))) {
        Invoke-Expression $funcs['Get-LaneTurnUnitText']
        Invoke-Expression $funcs['Test-LaneSignificantError']
        Invoke-Expression $funcs['Test-LaneTurnEvidence']
        $tokC2 = 'CHAL21-ANC01RR02'
        $tokS2 = 'PLANNING'
        Assert-That (-not [bool](Test-LaneSignificantError -Value $null)) 'sigerr: null benigno' 'divergente'
        Assert-That (-not [bool](Test-LaneSignificantError -Value '')) 'sigerr: string vazia benigna' 'divergente'
        Assert-That (-not [bool](Test-LaneSignificantError -Value @())) 'sigerr: array vazio benigno' 'divergente'
        Assert-That (-not [bool](Test-LaneSignificantError -Value $false)) 'sigerr: false benigno' 'divergente'
        Assert-That (-not [bool](Test-LaneSignificantError -Value 0)) 'sigerr: zero benigno' 'divergente'
        Assert-That ([bool](Test-LaneSignificantError -Value 'boom')) 'sigerr: string significativa' 'divergente'
        Assert-That ([bool](Test-LaneSignificantError -Value @('x'))) 'sigerr: array nao-vazio significativo' 'divergente'
        Assert-That ([bool](Test-LaneSignificantError -Value $true)) 'sigerr: true significativo' 'divergente'
        Assert-That ([bool](Test-LaneSignificantError -Value 5)) 'sigerr: numero nao-zero significativo' 'divergente'
        $eobj = $null
        try { $eobj = ConvertFrom-Json '{}' } catch { $eobj = $null }
        if ($null -eq $eobj) { $eobj = New-Object PSObject }
        Assert-That ([bool](Test-LaneSignificantError -Value $eobj)) 'sigerr: {} significativo' 'divergente'
        $rData = '{"error":"boom syn-rd","data":[{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}'
        $evRData = Test-LaneTurnEvidence -Text $rData -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That ((-not [bool]$evRData.role) -and (-not [bool]$evRData.canary)) 'ancerr: raiz+data[] descartado' 'falso positivo'
        $rMsgs = '{"error":["boom syn-rm"],"messages":[{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}'
        $evRMsgs = Test-LaneTurnEvidence -Text $rMsgs -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That ((-not [bool]$evRMsgs.role) -and (-not [bool]$evRMsgs.canary)) 'ancerr: raiz+messages[] descartado' 'falso positivo'
        $rNest = '{"data":{"messages":[{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}}'
        $evRNest = Test-LaneTurnEvidence -Text $rNest -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That (([bool]$evRNest.role) -and ([bool]$evRNest.canary)) 'ancerr: data.messages sem erro passa (positivo)' 'falso negativo'
        $dErr = '{"data":{"error":"boom syn-de","messages":[{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}}'
        $evDErr = Test-LaneTurnEvidence -Text $dErr -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That ((-not [bool]$evDErr.role) -and (-not [bool]$evDErr.canary)) 'ancerr: data.error intermedio descarta' 'falso positivo'
        $ownErr = '{"data":[{"role":"assistant","error":"boom syn-own","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}'
        $evOwn = Test-LaneTurnEvidence -Text $ownErr -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That ((-not [bool]$evOwn.role) -and (-not [bool]$evOwn.canary)) 'ancerr: message.error proprio negado' 'falso positivo'
        $jlFalse = '{"error":"boom syn-j1","data":[{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}' + "`n" + '{"data":[{"role":"user","content":"' + $tokC2 + ' ' + $tokS2 + '"}]}'
        $evJlF = Test-LaneTurnEvidence -Text $jlFalse -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That ((-not [bool]$evJlF.role) -and (-not [bool]$evJlF.canary)) 'ancerr: JSONL erro+user falso' 'falso positivo'
        $jlTrue = '{"error":"boom syn-j2"}' + "`n" + '{"role":"assistant","content":"' + $tokC2 + ' ' + $tokS2 + '"}'
        $evJlT = Test-LaneTurnEvidence -Text $jlTrue -CanaryToken $tokC2 -StateToken $tokS2
        Assert-That (([bool]$evJlT.role) -and ([bool]$evJlT.canary)) 'ancerr: JSONL erro nao contamina assistant valido posterior' 'falso negativo'
    }
    if ($funcs.ContainsKey('Invoke-LaneModelTurn')) {
        Invoke-Expression $funcs['Invoke-LaneModelTurn']
        # I-turn: campo sanitizado (recarrega sanitizadores reais por cima dos stubs de F)
        if ($funcs.ContainsKey('Get-LaneTurnUnitText')) { Invoke-Expression $funcs['Get-LaneTurnUnitText'] }
        if ($funcs.ContainsKey('Test-LaneSignificantError')) { Invoke-Expression $funcs['Test-LaneSignificantError'] }
        if ($funcs.ContainsKey('Test-LaneTurnEvidence')) { Invoke-Expression $funcs['Test-LaneTurnEvidence'] }
        Invoke-Expression $funcs['Get-LaneSafeText']
        Invoke-Expression $funcs['Get-LaneModelTurnOutputExcerpt']
        function Invoke-SpikeChild {
            param($FilePath = '', $ArgumentList = @(), $EnvSet = $null, $EnvRemove = $null, $WorkingDirectory = '', $TimeoutMs = 0, [switch]$CleanEnvironment, [switch]$StdinNul, $JobObject = $null)
            $script:cliCalls++
            $ex = 0
            $to = $false
            $ja = $true
            if ([string]$script:cliFault -ceq 'rc') { $ex = 1 }
            elseif ([string]$script:cliFault -ceq 'timeout') { $to = $true }
            elseif ([string]$script:cliFault -ceq 'nojob') { $ja = $false }
            if ([string]$script:cliFault -ceq 'throw') { throw 'syn-spike-throw-i9' }
            if ([string]$script:cliFault -ceq 'null') { return $null }
            return @{ ExitCode = $ex; TimedOut = $to; Stdout = [string]$script:cliStdout; Stderr = ''; JobAssigned = $ja; JobNote = 'syn-stub' }
        }
        $script:cliCalls = 0
        $script:legCalls = 0
        $script:cliFault = ''
        $script:cliStdout = '{"role":"assistant","session":"lane21-syn-sess-i1","state":"PLANNING"} "api_key": "SYNTHETIC-K99-VALUE"'
        $tI = Invoke-LaneModelTurn -SessionId 'syn-sess-i1' -Prompt 'syn-prompt-i1' -TimeoutMs 10000
        Assert-That (([bool]$tI.ok) -and ([string]$tI.turn_stdout_safe -match 'assistant') -and ([string]$tI.turn_stdout_safe -match 'lane21-syn-sess-i1') -and ([string]$tI.turn_stdout_safe -match 'PLANNING')) 'turn expoe stdout sanitizado com marcadores' 'campo ausente/vazio'
        Assert-That ([string]$tI.turn_stdout_safe -notmatch 'SYNTHETIC-K99-VALUE') 'turn sanitiza segredo do stdout' 'vazamento'
        Assert-That ([int]$script:legCalls -eq 0) 'turn CLI-ok nao consulta nativa' ('leg=' + $script:legCalls)
        # I-full: output sanitizado ate 4000 (maior que o excerpt de falha)
        $script:cliFault = ''
        $script:cliStdout = '{"role":"assistant","session":"lane21-syn-sess-i9"} token=SYNTHETIC-K99-VALUE "token": "SYNTHETIC-T99-VALUE" ' + ('B' * 5000)
        $script:legCalls = 0
        $tO = Invoke-LaneModelTurn -SessionId 'syn-sess-i9' -Prompt 'syn-prompt-i9' -TimeoutMs 10000
        Assert-That (([bool]$tO.ok) -and ($tO.Contains('turn_output_safe')) -and ([string]$tO.turn_output_safe -match 'assistant')) 'turn expoe output sanitizado integral' 'campo ausente/vazio'
        Assert-That ((([string]$tO.turn_output_safe).Length -le 4000) -and (([string]$tO.turn_output_safe).Length -gt 1200)) 'turn cap 4000 respeitado, maior que excerpt' ('len=' + ([string]$tO.turn_output_safe).Length)
        Assert-That (([string]$tO.turn_output_safe -notmatch 'SYNTHETIC-K99-VALUE') -and ([int]$script:legCalls -eq 0)) 'turn output sanitizado sem consulta nativa' 'vazamento ou chamada indevida'
        # I-null-spawn: sem resultado, campo com placeholder nao-vazio
        $script:cliFault = 'null'
        $script:cliStdout = ''
        $tS = Invoke-LaneModelTurn -SessionId 'syn-sess-i10' -Prompt 'syn-prompt-i10' -TimeoutMs 10000
        Assert-That (([bool]$tS.attempted) -and (-not [bool]$tS.ok) -and ($tS.Contains('turn_output_safe')) -and ([string]$tS.turn_output_safe -ceq '(turno sem saida: spawn sem resultado)')) 'turn spawn-nulo: placeholder nao-vazio' 'campo ausente/vazio'
        # I-throw: excecao apos attempted, campo com placeholder nao-vazio
        $script:cliFault = 'throw'
        $tT = Invoke-LaneModelTurn -SessionId 'syn-sess-i11' -Prompt 'syn-prompt-i11' -TimeoutMs 10000
        Assert-That (([bool]$tT.attempted) -and (-not [bool]$tT.ok) -and ($tT.Contains('turn_output_safe')) -and ([string]$tT.turn_output_safe -ceq '(turno sem saida: spawn sem resultado)')) 'turn throw apos attempted: placeholder nao-vazio' 'campo ausente/vazio'
        $script:cliFault = ''
        Assert-That ([string]$tO.turn_output_safe -notmatch 'SYNTHETIC-T99-VALUE') 'turn redige token JSON com espaco no diag' 'vazamento'
        # I-gate: tentativa recusada nunca popula o campo, mesmo com marcadores
        $script:cliFault = 'rc'
        $tR = Invoke-LaneModelTurn -SessionId 'syn-sess-i2' -Prompt 'syn-prompt-i2' -TimeoutMs 10000
        Assert-That (((-not [bool]$tR.ok)) -and ($tR.Contains('turn_stdout_safe')) -and ([string]$tR.turn_stdout_safe -ceq '')) 'turn CLI rc!=0: stdout descartado' 'campo populado com stdout recusado'
        $script:cliFault = 'timeout'
        $tT = Invoke-LaneModelTurn -SessionId 'syn-sess-i3' -Prompt 'syn-prompt-i3' -TimeoutMs 10000
        Assert-That (($tT.Contains('turn_stdout_safe')) -and ([string]$tT.turn_stdout_safe -ceq '')) 'turn CLI timeout: stdout descartado' 'campo populado com stdout recusado'
        $script:cliFault = 'nojob'
        $tJ = Invoke-LaneModelTurn -SessionId 'syn-sess-i4' -Prompt 'syn-prompt-i4' -TimeoutMs 10000
        Assert-That (($tJ.Contains('turn_stdout_safe')) -and ([string]$tJ.turn_stdout_safe -ceq '')) 'turn sem job: stdout descartado' 'campo populado sem atribuicao'
        $script:cliFault = 'rc'
        $script:natCalls = 0
        $tN = Invoke-LaneModelTurn -SessionId 'syn-sess-i5' -Prompt 'syn-prompt-i5' -TimeoutMs 10000 -NativeRequestFn $fHappy
        Assert-That (([bool]$tN.ok) -and ([bool]$tN.native) -and ($tN.Contains('turn_stdout_safe')) -and ([string]$tN.turn_stdout_safe -ceq '')) 'turn nativa-ok: stdout recusado vazio, GET decide depois' 'campo populado com stdout recusado'
        $script:cliFault = ''
    }
    # I-statics: 18/21 leem o campo + OU com GET; GET mantido como fallback
    Assert-That ($text.Contains('turn18.turn_stdout_safe')) '18: le stdout do turno' 'leitura ausente'
    Assert-That ($text.Contains('turn21.turn_stdout_safe')) '21: le stdout do turno' 'leitura ausente'
    Assert-That ($text.Contains('if (-not [bool]$turn18.native)')) '18: stdout so sem nativa decidindo' 'gate ausente'
    Assert-That ($text.Contains('if (-not [bool]$turn21.native)')) '21: stdout so sem nativa decidindo' 'gate ausente'
    Assert-That ($text.Contains('Test-LaneTurnEvidence -Text $stdSrc18')) '18: mesmos criterios via matcher' 'matcher ausente'
    Assert-That ($text.Contains('Test-LaneTurnEvidence -Text $stdSrc21')) '21: mesmos criterios via matcher' 'matcher ausente'
    Assert-That ($text.Contains("Invoke-Api -Method 'GET' -Path ('/api/session/' + `$childId + '/message')")) '18: GET mantido como fallback' 'fallback removido'
    Assert-That ($text.Contains("Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]`$s2.id + '/message?type=assistant')")) '21: GET fallback filtrado por type=assistant (eco do prompt fora do corpo)' 'fallback divergente'
    # I-stdout-proof: diag model-turn-stdout ok=true nos 3 cenarios, gated em attempted
    $stdoutProofAdds = @([regex]::Matches($text, "proof = 'model-turn-stdout'"))
    Assert-That (@($stdoutProofAdds).Count -eq 3) 'model-turn-stdout em 18/20/21' ('count=' + @($stdoutProofAdds).Count)
    $stdoutProofBad = @([regex]::Matches($text, 'proof = ''model-turn-stdout''; ok = \$false'))
    Assert-That (@($stdoutProofBad).Count -eq 0) 'model-turn-stdout nunca com ok=false (veredito intacto)' ('count=' + @($stdoutProofBad).Count)
    Assert-That ((@([regex]::Matches($text, 'turn18\.turn_output_safe')).Count -ge 1) -and (@([regex]::Matches($text, 'turn20\.turn_output_safe')).Count -ge 1) -and (@([regex]::Matches($text, 'turn21\.turn_output_safe')).Count -ge 1)) 'stdout-proof le turn_output_safe nos 3' 'leitura ausente'
    # I21. desafio persistido no task file, NUNCA no prompt (anti-eco).
    $setup21Lines = @($text -split "`r?`n" | Where-Object { $_ -match "New-LaneTask -TaskId 'lane21'" })
    Assert-That (@($setup21Lines).Count -eq 1) '21: setup cria lane21 uma vez' ('count=' + @($setup21Lines).Count)
    $setup21 = ''
    if (@($setup21Lines).Count -ge 1) { $setup21 = [string]$setup21Lines[0] }
    Assert-That ($setup21 -match '\$challenge21') '21: setup persiste desafio fresco no objective' 'desafio ausente'
    Assert-That ($text.Contains('$challenge21 = (''CHAL21-'' + ([guid]::')) '21: desafio e token aleatorio de teste (guid, nao segredo)' 'definicao ausente'
    $prompt21Lines = @($text -split "`r?`n" | Where-Object { $_ -match '\$turn21 = Invoke-LaneModelTurn' })
    Assert-That (@($prompt21Lines).Count -eq 1) '21: um turn do substituto' ('count=' + @($prompt21Lines).Count)
    $p21line = ''
    if (@($prompt21Lines).Count -ge 1) { $p21line = [string]$prompt21Lines[0] }
    Assert-That ($p21line -match '\.\./kernel-tasks/lane21\.json') '21: prompt com caminho relativo do task file' 'caminho ausente'
    Assert-That ((($p21line -notmatch 'challenge21') -and ($p21line -notmatch 'preState') -and ($p21line -notmatch '(?i)canary'))) '21: prompt NAO revela desafio nem estado' 'revelacao no prompt'
    Assert-That ((@([regex]::Matches($text, '-CanaryToken \$challenge21 -StateToken \$preState')).Count) -eq 2) '21: matcher usa desafio+estado nas 2 vias (stdout+GET)' 'wiring divergente'
    # I21-sane: prompt curto sobrevive intacto ao saneamento do turno.
    $synPrompt21 = 'RECOVERY-read-file-../kernel-tasks/lane21.json-report-objective-state-history'
    $synSafe21 = (($synPrompt21 -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-').Trim())
    if ($synSafe21.Length -gt 200) { $synSafe21 = $synSafe21.Substring(0, 200) }
    Assert-That (($synSafe21 -ceq $synPrompt21) -and ($synSafe21.Length -le 200)) '21: prompt intacto pos-saneamento+cap200' ('safe=' + $synSafe21)
    # I21-gate: desafio+estado na mesma unidade assistant passam; eco do
    # prompt (sem desafio) e user-only com tokens nao passam.
    if ($funcs.ContainsKey('Get-LaneTurnUnitText')) { Invoke-Expression $funcs['Get-LaneTurnUnitText'] }
    if ($funcs.ContainsKey('Test-LaneSignificantError')) { Invoke-Expression $funcs['Test-LaneSignificantError'] }
    Invoke-Expression $funcs['Test-LaneTurnEvidence']
    $chal21 = 'CHAL21-SYNTEST01AB'
    $readBody21 = '{"data":[{"role":"assistant","content":[{"type":"text","text":"objective RR-E2E-21 ' + $chal21 + ' estado PLANNING via arquivo"}]}]}'
    $evRead21 = Test-LaneTurnEvidence -Text $readBody21 -CanaryToken $chal21 -StateToken 'PLANNING'
    Assert-That (([bool]$evRead21.role) -and ([bool]$evRead21.canary) -and ([bool]$evRead21.state)) '21 leitura real: desafio+estado na mesma unidade passam' 'divergente'
    $echoP21 = '{"data":[{"role":"assistant","content":[{"type":"text","text":"RECOVERY-read-file-../kernel-tasks/lane21.json-report-objective-state-history"}]}]}'
    $evEchoP21 = Test-LaneTurnEvidence -Text $echoP21 -CanaryToken $chal21 -StateToken 'PLANNING'
    Assert-That (([bool]$evEchoP21.role) -and (-not [bool]$evEchoP21.canary) -and (-not [bool]$evEchoP21.state)) '21 eco do prompt sem desafio negado' 'falso positivo'
    $userOnly21 = '{"data":[{"role":"user","content":"' + $chal21 + ' PLANNING"}]}'
    $evUser21 = Test-LaneTurnEvidence -Text $userOnly21 -CanaryToken $chal21 -StateToken 'PLANNING'
    Assert-That ((-not [bool]$evUser21.role) -and (-not [bool]$evUser21.canary)) '21 user-only com tokens negado' 'falso positivo'
    # J. hollow-ok (rc=0 SEM texto) nao conta como ok substantivo; a perna
    # nativa tem sua chance (ORFS-HOLLOW-NATIVE). Fixtures sinteticas, sem
    # rede/servico real. RED-first: falha na baseline (sem substantive, sem
    # trigger, nativa nunca corre com ok=true).
    if (($funcs.ContainsKey('Invoke-LaneModelTurn')) -and ($funcs.ContainsKey('Test-LaneTurnEvidence'))) {
        if ($funcs.ContainsKey('Get-LaneTurnUnitText')) { Invoke-Expression $funcs['Get-LaneTurnUnitText'] }
        if ($funcs.ContainsKey('Test-LaneSignificantError')) { Invoke-Expression $funcs['Test-LaneSignificantError'] }
        Invoke-Expression $funcs['Test-LaneTurnEvidence']
        Invoke-Expression $funcs['Invoke-LaneNativeTurn']
        Invoke-Expression $funcs['Invoke-LaneModelTurn']
        $script:legCallsJ = 0
        $script:realNativeLegJ = ${function:Invoke-LaneNativeTurn}
        function Invoke-LaneNativeTurn {
            param([string]$SessionId = '', [string]$SafePrompt = '', [int]$TimeoutMs = 0, [string]$BaseUrl = '', $RequestFn = $null)
            $script:legCallsJ++
            return (& $script:realNativeLegJ -SessionId $SessionId -SafePrompt $SafePrompt -TimeoutMs $TimeoutMs -BaseUrl $BaseUrl -RequestFn $RequestFn)
        }
        function Invoke-SpikeChild {
            param($FilePath = '', $ArgumentList = @(), $EnvSet = $null, $EnvRemove = $null, $WorkingDirectory = '', $TimeoutMs = 0, [switch]$CleanEnvironment, [switch]$StdinNul, $JobObject = $null)
            $exJ = 0
            $seJ = ''
            if ([string]$script:cliFaultJ -ceq 'rc') { $exJ = 1; $seJ = 'syn-fail-j3' }
            return @{ ExitCode = $exJ; TimedOut = $false; Stdout = [string]$script:cliStdoutJ; Stderr = $seJ; JobAssigned = $true; JobNote = 'syn-stub' }
        }
        $script:natCallsJ = 0
        $hHappyJ = {
            param($Method, $Path, $Body, $TimeoutMs)
            $script:natCallsJ++
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) {
                if ($script:natCallsJ -eq 1) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
                return @{ StatusCode = 200; Body = '{"data":[{"role":"assistant","content":[{"type":"text","text":"syn-j-new"}]}]}'; TimedOut = $false }
            }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-j"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 204; Body = ''; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        # J1. hollow: flag pura substantive existe; ok global intacto (true).
        $script:cliFaultJ = ''
        $script:cliStdoutJ = '{"session":"syn-hollow-j1"}'
        $script:natCallsJ = 0; $script:legCallsJ = 0
        $tJ1 = Invoke-LaneModelTurn -SessionId 'syn-sess-j1' -Prompt 'syn-prompt-j1' -TimeoutMs 10000 -NativeRequestFn $hHappyJ
        Assert-That ($tJ1.Contains('substantive')) 'hollow: flag substantive existe' 'chave ausente'
        Assert-That (([bool]$tJ1.ok) -and ($tJ1.Contains('substantive')) -and (-not [bool]$tJ1.substantive)) 'hollow: ok intacto mas substantive=false' ('ok=' + [bool]$tJ1.ok)
        # J2. hollow-ok da chance a nativa com trigger hollow (nao fail).
        Assert-That (([int]$script:legCallsJ -eq 1) -and ([bool]$tJ1.native) -and ([string]$tJ1.nativeTrigger -ceq 'native-after-hollow')) 'hollow: nativa corre 1x com trigger hollow' ('leg=' + $script:legCallsJ + ' trig=' + [string]$tJ1.nativeTrigger)
        Assert-That (($null -ne $tJ1.nativeTriggerProof) -and ([string]$tJ1.nativeTriggerProof['proof'] -ceq 'model-native-trigger') -and ([bool]$tJ1.nativeTriggerProof['ok']) -and ([string]$tJ1.nativeTriggerProof['detail'] -like '*native-after-hollow*')) 'hollow: proof model-native-trigger distingue hollow' 'proof ausente/divergente'
        # J3. fail da chance a nativa com trigger fail (nativa-ok decide o
        # turno: ok vira true VIA nativa, mas substantive segue false).
        $script:cliFaultJ = 'rc'
        $script:cliStdoutJ = ''
        $script:natCallsJ = 0; $script:legCallsJ = 0
        $tJ3 = Invoke-LaneModelTurn -SessionId 'syn-sess-j3' -Prompt 'syn-prompt-j3' -TimeoutMs 10000 -NativeRequestFn $hHappyJ
        Assert-That (([bool]$tJ3.ok) -and ([bool]$tJ3.native) -and (-not [bool]$tJ3.substantive) -and ([int]$script:legCallsJ -eq 1) -and ([string]$tJ3.nativeTrigger -ceq 'native-after-fail')) 'fail+nativa-ok: trigger fail, ok via nativa' ('leg=' + $script:legCallsJ + ' trig=' + [string]$tJ3.nativeTrigger)
        # J3b. fail + nativa-fail: ok segue false, trigger fail preservado.
        $fWait500J = {
            param($Method, $Path, $Body, $TimeoutMs)
            if (($Method -ceq 'GET') -and ($Path -like '*/message*')) { return @{ StatusCode = 200; Body = '{"data":[]}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/prompt')) { return @{ StatusCode = 200; Body = '{"data":{"id":"syn-inbox-j3b"}}'; TimedOut = $false } }
            if (($Method -ceq 'POST') -and ($Path -like '*/wait')) { return @{ StatusCode = 500; Body = '{}'; TimedOut = $false } }
            return @{ StatusCode = 404; Body = ''; TimedOut = $false }
        }
        $script:cliFaultJ = 'rc'
        $script:cliStdoutJ = ''
        $script:natCallsJ = 0; $script:legCallsJ = 0
        $tJ3b = Invoke-LaneModelTurn -SessionId 'syn-sess-j3b' -Prompt 'syn-prompt-j3b' -TimeoutMs 10000 -NativeRequestFn $fWait500J
        Assert-That (((-not [bool]$tJ3b.ok)) -and (-not [bool]$tJ3b.substantive) -and ([int]$script:legCallsJ -eq 1) -and ([string]$tJ3b.nativeTrigger -ceq 'native-after-fail')) 'fail+nativa-fail: ok false, trigger fail' ('leg=' + $script:legCallsJ + ' trig=' + [string]$tJ3b.nativeTrigger)
        # J4. substantivo-ok (rc=0 COM marcadores) nao chama a nativa.
        $script:cliFaultJ = ''
        $script:cliStdoutJ = '{"role":"assistant","content":[{"type":"text","text":"syn-j4-ok"}]}'
        $script:natCallsJ = 0; $script:legCallsJ = 0
        $tJ4 = Invoke-LaneModelTurn -SessionId 'syn-sess-j4' -Prompt 'syn-prompt-j4' -TimeoutMs 10000 -NativeRequestFn $hHappyJ
        Assert-That (([bool]$tJ4.ok) -and ([bool]$tJ4.substantive) -and (-not [bool]$tJ4.native) -and ([int]$script:legCallsJ -eq 0)) 'substantivo-ok: nativa nao corre' ('leg=' + $script:legCallsJ)
        $script:cliFaultJ = ''
    }
    # J-statics: flag, gate hollow, triggers e reason hollow em 18/21.
    $turnFnJ = [string]$funcs['Invoke-LaneModelTurn']
    Assert-That ($text.Contains('substantive')) 'static: lane expoe flag substantive' 'flag ausente'
    Assert-That (($turnFnJ.Contains('native-after-hollow')) -and ($turnFnJ.Contains('native-after-fail'))) 'static: turn distingue triggers hollow/fail' 'triggers ausentes'
    Assert-That ($turnFnJ.Contains('model-native-trigger')) 'static: turn emite proof model-native-trigger' 'proof ausente'
    Assert-That ($turnFnJ.Contains('substantive') -and ($turnFnJ.Contains('-not [bool]$res.ok'))) 'static: gate nativo cobre not-ok e hollow' 'gate ausente'
    Assert-That ($text.Contains('hollow-ok')) 'static: 18/21 nomeiam hollow-ok no blocked' 'reason hollow ausente'
    Assert-That ($text.Contains('$res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))')) 'static: expressao de turn-ok CLI intacta (hollow)' 'semantica alterada'
    $suiteSecs = [int]$script:suiteSw.Elapsed.TotalSeconds
    Assert-That ($suiteSecs -lt 300) 'suite completa <300s' ('duracao=' + $suiteSecs + 's')
    Write-Host ('[nativeturn-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[nativeturn-tests] THROW: ' + $_.Exception.Message)
    exit 1
}
