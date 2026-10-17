# session-real-lane-f1fix01.tests.ps1 -- F1-FIX-01 (RR-E2E-18/21).
# Testes offline das correcoes minimas em scripts/ci/session-real-lane-v2.ps1:
# 1. Gate pre-19 executa SOMENTE com filtro vazio ou contendo 19 (predicado
#    puro Test-LaneNeedsPre19Gate; filtro so-18 pula sem falha por ele).
# 2. Framing JSONL preservado no caminho decisorio (excerpt mantem \n) +
#    split robusto de docs concatenados por espacos ('}  {', caso lane18 real).
# 3. Evento CLI tipo text com duplo vinculo de sessao => cli_bound=true;
#    outra sessao, sem messageID ou texto vazio seguem inelegiveis; sem
#    ExpectedSessionId o comportamento estrito e preservado.
# 4. Cap 1200 com flag truncated (predicado puro Test-LaneStdoutWindowTruncated).
# 5. Sem aumento de timeout (180000 intacto); sem aceitacao ampla.
# Sem Pester. Sem rede/spawn/modelo: helpers extraidos via AST (a lane nunca
# e executada) e exercitados em memoria com fixtures sinteticas; o resto sao
# asserts estaticos sobre o texto da lane. So IDs/canarios sinteticos
# (ses_SYNTH-*, SYN-*); nenhum segredo real. PS 5.1 e PS7 compativel. ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
try {
    Assert-That (Test-Path -LiteralPath $script:LanePath -PathType Leaf) 'lane file exists' $script:LanePath
    $text = ''
    try { $text = [IO.File]::ReadAllText($script:LanePath) } catch { $text = '' }
    Assert-That (-not [string]::IsNullOrEmpty($text)) 'lane text readable' 'empty'
    $tokens = $null
    $parseErrors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors) } catch { $ast = $null }
    Assert-That (($null -ne $ast) -and ($null -ne $parseErrors) -and (@($parseErrors).Count -eq 0)) 'lane parses without syntax errors' ('errors=' + @($parseErrors).Count)
    $funcs = @{}
    try {
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($f in @($found)) { $funcs[[string]$f.Name] = [string]$f.Extent.Text }
    } catch { }
    foreach ($fn in @('Get-LaneSafeText', 'Get-LaneModelTurnOutputExcerpt', 'Test-LaneSignificantError', 'Get-LaneTurnUnitText', 'Test-LaneTurnEvidence', 'Test-LaneStdoutWindowTruncated', 'Test-LaneNeedsPre19Gate', 'Test-LaneNeedsPost17Gate')) {
        Assert-That ($funcs.ContainsKey($fn)) ("helper $fn exists") 'RED: helper ausente na lane'
    }
    if (($funcs.ContainsKey('Get-LaneSafeText')) -and ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) -and ($funcs.ContainsKey('Test-LaneSignificantError')) -and ($funcs.ContainsKey('Get-LaneTurnUnitText')) -and ($funcs.ContainsKey('Test-LaneTurnEvidence')) -and ($funcs.ContainsKey('Test-LaneStdoutWindowTruncated')) -and ($funcs.ContainsKey('Test-LaneNeedsPre19Gate')) -and ($funcs.ContainsKey('Test-LaneNeedsPost17Gate'))) {
        Invoke-Expression $funcs['Get-LaneSafeText']
        Invoke-Expression $funcs['Get-LaneModelTurnOutputExcerpt']
        Invoke-Expression $funcs['Test-LaneSignificantError']
        Invoke-Expression $funcs['Get-LaneTurnUnitText']
        Invoke-Expression $funcs['Test-LaneTurnEvidence']
        Invoke-Expression $funcs['Test-LaneStdoutWindowTruncated']
        Invoke-Expression $funcs['Test-LaneNeedsPre19Gate']
        Invoke-Expression $funcs['Test-LaneNeedsPost17Gate']
        # ---- fixture exata de lane18:71 (2 docs CLI unidos por 2 espacos) ----
        # Em-dash via [char] para manter o fonte ASCII-only (valor identico).
        $emdash = [string][char]0x2014
        $sid18 = 'ses_ec043897bffeBFN0rj4YNfL698'
        $docA = '{"type":"step_start","timestamp":1792070690699,"sessionID":"' + $sid18 + '","part":{"id":"prt_13fbca78b001ATtoYIcYXjWiKH","sessionID":"' + $sid18 + '","messageID":"msg_13fbc9b7d001jQpczsUfwnLp8C","type":"step-start"}}'
        $docB = '{"type":"text","timestamp":1792070691256,"sessionID":"' + $sid18 + '","part":{"id":"prt_13fbca92a001LKzdU0IKOIaCqN","sessionID":"' + $sid18 + '","messageID":"msg_13fbc9b7d001jQpczsUfwnLp8C","type":"text","text":"probe ack ' + $emdash + ' alive and ready.","time":{"start":1792070691114,"end":1792070691256}}}'
        $fixture18 = ($docA + '  ' + $docB)
        # c3a. sessao esperada => cli_bound=true (role segue false: sem role)
        $ev18 = Test-LaneTurnEvidence -Text $fixture18 -ExpectedSessionId $sid18
        Assert-That (([bool]$ev18.cli_bound) -and (-not [bool]$ev18.role)) 'lane18:71 ligada a sessao => cli_bound=true role=false' ('cli=' + [bool]$ev18.cli_bound + ' role=' + [bool]$ev18.role)
        # c3b. sessao divergente => inelegivel
        $ev18div = Test-LaneTurnEvidence -Text $fixture18 -ExpectedSessionId 'ses_DIVERGENT999'
        Assert-That ((-not [bool]$ev18div.cli_bound) -and (-not [bool]$ev18div.role)) 'sessao divergente => cli_bound=false' ('cli=' + [bool]$ev18div.cli_bound)
        # c3c. sem ExpectedSessionId => estrito preservado (sem aceitacao ampla)
        $ev18strict = Test-LaneTurnEvidence -Text $fixture18
        Assert-That ((-not [bool]$ev18strict.cli_bound) -and (-not [bool]$ev18strict.role)) 'sem ExpectedSessionId => estrito (cli_bound=false)' ('cli=' + [bool]$ev18strict.cli_bound)
        # c3d. sem messageID => inelegivel
        $noMid = $fixture18.Replace('"messageID":"msg_13fbc9b7d001jQpczsUfwnLp8C"', '"messageID":""')
        $evNoMid = Test-LaneTurnEvidence -Text $noMid -ExpectedSessionId $sid18
        Assert-That (-not [bool]$evNoMid.cli_bound) 'sem messageID => cli_bound=false' ('cli=' + [bool]$evNoMid.cli_bound)
        # c3e. texto vazio => inelegivel
        $emptyTx = $docB -replace '"text":"[^"]*"', '"text":""'
        $evEmptyTx = Test-LaneTurnEvidence -Text ($docA + '  ' + $emptyTx) -ExpectedSessionId $sid18
        Assert-That (-not [bool]$evEmptyTx.cli_bound) 'texto vazio => cli_bound=false' ('cli=' + [bool]$evEmptyTx.cli_bound)
        # ---- c2a. framing: newline sobrevive a sanitizacao do caminho decisorio ----
        $l1 = '{"role":"assistant","content":"SYN-F1-A1"}'
        $l2 = '{"role":"assistant","content":"SYN-F1-B2"}'
        $jlNL = ($l1 + "`n" + $l2)
        $excNL = Get-LaneModelTurnOutputExcerpt -Stdout $jlNL -Stderr ''
        Assert-That (([string]$excNL -match "`n")) 'excerpt preserva newline (framing JSONL)' 'newline achatado'
        $evExcNL = Test-LaneTurnEvidence -Text $excNL
        Assert-That ([bool]$evExcNL.role) 'excerpt com newline: 2 docs parseiam (role=true)' 'parse falhou'
        # ---- c2b. split robusto: docs unidos por 2 espacos tambem segmentam ----
        $evSP = Test-LaneTurnEvidence -Text ($l1 + '  ' + $l2)
        Assert-That ([bool]$evSP.role) 'docs com 2 espacos segmentam (role=true)' 'split falhou'
        # linha unica valida nao regride (tentativa integral antes do split)
        $evSingle = Test-LaneTurnEvidence -Text $l1
        Assert-That ([bool]$evSingle.role) 'linha unica valida intacta' 'regressao'
        # ---- c1. predicado do gate pre-19 (puro, sem spawn) ----
        Assert-That (-not [bool](Test-LaneNeedsPre19Gate -Filter @('18'))) 'filtro so-18 pula gate pre-19' 'gate executaria'
        Assert-That ([bool](Test-LaneNeedsPre19Gate -Filter @())) 'filtro vazio executa gate pre-19' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPre19Gate -Filter @('19'))) 'filtro 19 executa gate pre-19' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPre19Gate -Filter @('18', '19'))) 'filtro 18+19 executa gate pre-19' 'gate pulado'
        Assert-That (-not [bool](Test-LaneNeedsPre19Gate -Filter @('20'))) 'filtro so-20 pula gate pre-19' 'gate executaria'
        # ---- c1b. predicado do gate pos-16/17 (puro, sem spawn) ----
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('16'))) 'filtro so-16 pula gate pos-16/17' 'gate executaria'
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('17'))) 'filtro so-17 pula gate pos-16/17' 'gate executaria'
        Assert-That (-not [bool](Test-LaneNeedsPost17Gate -Filter @('16', '17'))) 'filtro 16+17 pula gate pos-16/17' 'gate executaria'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @())) 'filtro vazio executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('18'))) 'filtro so-18 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('21'))) 'filtro so-21 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('19'))) 'filtro so-19 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('20'))) 'filtro so-20 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('22'))) 'filtro so-22 executa gate pos-16/17' 'gate pulado'
        Assert-That ([bool](Test-LaneNeedsPost17Gate -Filter @('16', '21'))) 'filtro 16+21 executa gate pos-16/17' 'gate pulado'
        # ---- c4. flag de truncamento da janela 1200 ----
        Assert-That ([bool](Test-LaneStdoutWindowTruncated -Stdout ('W' * 5000) -Window 1200)) 'stdout longo => truncated=true' 'flag ausente'
        Assert-That (-not [bool](Test-LaneStdoutWindowTruncated -Stdout 'curto SYN-F1-T1' -Window 1200)) 'stdout curto => truncated=false' 'flag espuria'
        Assert-That (-not [bool](Test-LaneStdoutWindowTruncated -Stdout '' -Stderr '' -Window 1200)) 'stdout vazio => truncated=false' 'flag espuria'
    }
    # ---- F1-FIX-02: framing 1-para-1 + split top-level fora de strings ----
    # Tudo comportamental via matcher/excerpt (o segmentador e inline e
    # autocontido em Test-LaneTurnEvidence, sem helper separado: extracao
    # offline por AST de outros harnesses continua funcionando).
    if (($funcs.ContainsKey('Test-LaneTurnEvidence')) -and ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt'))) {
    # (f2a) doc 1190 chars + newline preserva parse no cap 1200: o token de
    # 16 chars expandia 1192 -> 1226 e truncava; 1-para-1 nao expande.
    $padLen02 = 1190 - '{"role":"assistant","content":""}'.Length
    $doc1190 = '{"role":"assistant","content":"' + ('P' * $padLen02) + '"}'
    Assert-That ($doc1190.Length -eq 1190) 'f1fix02 sanidade: doc tem 1190 chars' ('len=' + $doc1190.Length)
    $exc1190 = Get-LaneModelTurnOutputExcerpt -Stdout ($doc1190 + "`n") -Stderr ''
    $ev1190 = Test-LaneTurnEvidence -Text $exc1190
    Assert-That ([bool]$ev1190.role) 'f1fix02: doc 1190 chars + newline preserva parse (role=true)' 'truncado pelo framing'
    # (f2b) dois docs concatenados cujo texto contem "} {": o doc com codigo
    # + canario/state na MESMA unidade prova segmentacao correta e texto
    # intacto (split dentro da string geraria fragmentos invalidos e
    # canary=false). Tokens sinteticos locais.
    $tokC02 = 'SYN-F1FIX02-CA'
    $tokS02 = 'SYN-F1FIX02-ST'
    $codeDoc = '{"role":"assistant","content":"codigo if (x) } { y } ' + $tokC02 + ' ' + $tokS02 + ' fim"}'
    $plainDoc = '{"role":"assistant","content":"outro doc sem marcadores"}'
    $evCode = Test-LaneTurnEvidence -Text ($codeDoc + '  ' + $plainDoc) -CanaryToken $tokC02 -StateToken $tokS02
    Assert-That (([bool]$evCode.role) -and ([bool]$evCode.canary) -and ([bool]$evCode.state)) 'f1fix02: codigo com "} {" concatenado, texto intacto na unidade (role+canary+state)' 'split quebrou o texto'
    # (f2c) "}  {" (2 espacos) DENTRO de string NAO divide: 1 doc valido.
    # A regex antiga dividia aqui e descartava ambos os fragmentos.
    $inStrDoc = '{"role":"assistant","content":"SYN-F1FIX02-C3 a}  {b fim"}'
    $evInStr = Test-LaneTurnEvidence -Text $inStrDoc
    Assert-That ([bool]$evInStr.role) 'f1fix02: split dentro de string NAO divide (role=true)' 'falso negativo'
    # (f2d) DEL preexistente nao vira newline espurio (colisao cosmetica
    # fail-closed: vira espaco, parse preservado, sem newline inventado).
    # O unico \n esperado e o trailing legitimo da juncao stdout+stderr.
    $delCh = [string][char]0x7F
    $delDoc = '{"role":"assistant","content":"SYN-F1FIX02-D4 AB' + $delCh + 'CD"}'
    $excDel = Get-LaneModelTurnOutputExcerpt -Stdout $delDoc -Stderr ''
    $nlCountDel = @([regex]::Matches([string]$excDel, "`n")).Count
    Assert-That ((($nlCountDel -eq 1)) -and ([string]$excDel).Contains('SYN-F1FIX02-D4 AB CD')) 'f1fix02: DEL preexistente nao vira newline espurio' ('newlines=' + $nlCountDel)
    $evDel = Test-LaneTurnEvidence -Text $excDel
    Assert-That ([bool]$evDel.role) 'f1fix02: doc com DEL preserva parse (role=true)' 'parse quebrou'
    Assert-That (($text -notmatch 'LANE-NL')) 'f1fix02: token expansivo removido da lane' 'token ainda presente'
    Assert-That (-not $text.Contains('(?<=\})\s+(?=\{)')) 'f1fix02: regex fragil de split removida da lane' 'regex ainda presente'
    }
    # ---- F1-FIX-03: fixtures residuais do reviewer (segmentador top-level) ----
    # As 3 fixtures passam no segmentador atual (depth+string+escape); este
    # bloco e regressao focada, sem tocar a lane. O doc simples usa outra
    # sessao (nao vincula), entao cli_bound=true prova que o doc dificil
    # parseou, segmentou e vinculou. Tokens sinteticos locais. ASCII only.
    if ($funcs.ContainsKey('Test-LaneTurnEvidence')) {
    $sid03 = 'ses_SYN03ABCDEF'
    $tokC03 = 'SYN-F1FIX03-CA'
    $tokS03 = 'SYN-F1FIX03-ST'
    $docPlain03 = '{"type":"text","timestamp":1792070691257,"sessionID":"ses_SYN03OTHER","part":{"id":"prt_SYN03P","sessionID":"ses_SYN03OTHER","messageID":"msg_SYN03P","type":"text","text":"outro doc sem marcadores"}}'
    # (f3a) aspas escapadas: \" e } { dentro de string nao dividem; vinculo -ceq preservado.
    $escText03 = 'diz \"oi\" } { ' + $tokC03 + ' ' + $tokS03 + ' fim'
    $docEsc03 = '{"type":"text","timestamp":1792070691256,"sessionID":"' + $sid03 + '","part":{"id":"prt_SYN03A","sessionID":"' + $sid03 + '","messageID":"msg_SYN03A","type":"text","text":"' + $escText03 + '"}}'
    $evEsc03 = Test-LaneTurnEvidence -Text ($docEsc03 + '  ' + $docPlain03) -CanaryToken $tokC03 -StateToken $tokS03 -ExpectedSessionId $sid03
    Assert-That ([bool]$evEsc03.cli_bound) 'f1fix03: aspas escapadas + "} {" preservam vinculo cli_bound' 'vinculo perdido (split dentro da string?)'
    Assert-That (([bool]$evEsc03.canary) -and ([bool]$evEsc03.state)) 'f1fix03: texto com escape intacto na unidade (canary+state)' 'split quebrou o texto'
    # (f3b) barras consecutivas: \\ e \\}/\\{ em JSON valido; sem divisao espuria, sem excecao.
    $bsText03 = 'a \\\\ b \\} \\{ ' + $tokC03 + ' ' + $tokS03 + ' fim'
    $docBs03 = '{"type":"text","timestamp":1792070691256,"sessionID":"' + $sid03 + '","part":{"id":"prt_SYN03C","sessionID":"' + $sid03 + '","messageID":"msg_SYN03C","type":"text","text":"' + $bsText03 + '"}}'
    $evBs03 = Test-LaneTurnEvidence -Text ($docBs03 + '  ' + $docPlain03) -CanaryToken $tokC03 -StateToken $tokS03 -ExpectedSessionId $sid03
    Assert-That ([bool]$evBs03.cli_bound) 'f1fix03: barras consecutivas preservam vinculo cli_bound (sem excecao)' 'vinculo perdido ou excecao'
    Assert-That (([bool]$evBs03.canary) -and ([bool]$evBs03.state)) 'f1fix03: texto com barras intacto na unidade (canary+state)' 'split quebrou o texto'
    # (f3c) arrays/objetos aninhados com "} {" em string: 2 docs concatenados parseiam.
    $nestText03 = 'relatorio ' + $tokC03 + ' ' + $tokS03 + ' fim'
    $docNest03 = '{"type":"text","timestamp":1792070691256,"sessionID":"' + $sid03 + '","part":{"id":"prt_SYN03D","sessionID":"' + $sid03 + '","messageID":"msg_SYN03D","type":"text","text":"' + $nestText03 + '","tags":["a} {b","c"],"meta":{"k":"v} {w}"}}}'
    $evNest03 = Test-LaneTurnEvidence -Text ($docNest03 + '  ' + $docPlain03) -CanaryToken $tokC03 -StateToken $tokS03 -ExpectedSessionId $sid03
    Assert-That ([bool]$evNest03.cli_bound) 'f1fix03: array/objeto aninhado com "} {" preserva vinculo cli_bound' 'vinculo perdido'
    Assert-That (([bool]$evNest03.canary) -and ([bool]$evNest03.state)) 'f1fix03: doc aninhado intacto na unidade (canary+state)' 'split quebrou o texto'
    Assert-That ((-not [bool]$evEsc03.role) -and (-not [bool]$evBs03.role) -and (-not [bool]$evNest03.role)) 'f1fix03: docs CLI sem role seguem role=false (sem aceitacao ampla)' 'role espurio'
    }
    # ---- c5. estaticos: sem aumento de timeout, sem aceitacao ampla ----
    $to180 = @([regex]::Matches($text, '-TimeoutMs 180000'))
    Assert-That (@($to180).Count -eq 3) 'TimeoutMs 180000 intacto nos 3 turns (18/20/21)' ('count=' + @($to180).Count)
    Assert-That ($text.Contains('if (Test-LaneNeedsPre19Gate -Filter $ScenarioFilter)')) 'gate pre-19 gated no predicado' 'wrap ausente'
    Assert-That ($text.Contains("Fail-Lane 'servico indisponivel antes do cenario 19.'")) 'falha do gate pre-19 preservada (dentro do if)' 'mensagem ausente'
    Assert-That ($text.Contains('if (Test-LaneNeedsPost17Gate -Filter $ScenarioFilter)')) 'gate pos-16/17 gated no predicado' 'wrap ausente'
    Assert-That ($text.Contains("Fail-Lane 'servico indisponivel apos cenarios 16/17; lane abortada.'")) 'falha do gate pos-16/17 preservada (dentro do if)' 'mensagem ausente'
    $ceqBind = @([regex]::Matches($text, '-ceq \$ExpectedSessionId'))
    Assert-That (@($ceqBind).Count -eq 2) 'vinculo exato doc+part (-ceq ExpectedSessionId 2x)' ('count=' + @($ceqBind).Count)
    Assert-That ($text.Contains('$subEv.cli_bound')) 'turn: substantive aceita cli_bound' 'wiring ausente'
    Assert-That ($text.Contains('$stdEv18.cli_bound')) '18: stdout aceita cli_bound' 'wiring ausente'
    Assert-That ($text.Contains('$msgEv18b.cli_bound')) '18: GET aceita cli_bound' 'wiring ausente'
    Assert-That ($text.Contains('$stdEv21.cli_bound') -and $text.Contains('$msgEv21.cli_bound')) '21: stdout+GET aceitam cli_bound' 'wiring ausente'
    Assert-That ($text.Contains('turn_stdout_truncated')) 'flag truncated no resultado do turno' 'campo ausente'
    Assert-That ((@([regex]::Matches($text, 'turn_stdout_window=1200 truncated=')).Count) -eq 3) 'truncated=true/false na proof diag dos 3 cenarios' 'proof sem flag'
    $safeFn = ''
    if ($funcs.ContainsKey('Get-LaneSafeText')) { $safeFn = [string]$funcs['Get-LaneSafeText'] }
    Assert-That (($safeFn.Contains('param($Value, [int]$Max = 200)')) -and ($safeFn -notmatch 'cli_bound|ExpectedSessionId|LANE-NL')) 'Get-LaneSafeText compartilhada intocada' 'assinatura alterada'
    $excFn = ''
    if ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) { $excFn = [string]$funcs['Get-LaneModelTurnOutputExcerpt'] }
    Assert-That ($excFn.Contains('Get-LaneSafeText $v $Max')) 'excerpt ainda capa via Get-LaneSafeText apos pre-redacao' 'ordem alterada'
    # ---- NOLINT de segredos + ASCII-only ----
    $selfText = [IO.File]::ReadAllText($PSCommandPath)
    Assert-That (($selfText -notmatch 'sk-[A-Za-z0-9]') -and ($selfText -notmatch '(?i)password\s*=\s*[^=\s]')) 'teste sem segredos reais' 'padrao sensivel no teste'
    $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
    $laneChanged = @()
    if ($funcs.ContainsKey('Test-LaneTurnEvidence')) { $laneChanged += $funcs['Test-LaneTurnEvidence'] }
    if ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) { $laneChanged += $funcs['Get-LaneModelTurnOutputExcerpt'] }
    if ($funcs.ContainsKey('Test-LaneStdoutWindowTruncated')) { $laneChanged += $funcs['Test-LaneStdoutWindowTruncated'] }
    if ($funcs.ContainsKey('Test-LaneNeedsPre19Gate')) { $laneChanged += $funcs['Test-LaneNeedsPre19Gate'] }
    if ($funcs.ContainsKey('Test-LaneNeedsPost17Gate')) { $laneChanged += $funcs['Test-LaneNeedsPost17Gate'] }
    if ($funcs.ContainsKey('Invoke-LaneModelTurn')) { $laneChanged += $funcs['Invoke-LaneModelTurn'] }
    $gateLines = @()
    foreach ($ln in ($text -split "`r?`n")) {
        if (($ln -match 'NeedsPre19Gate') -or ($ln -match 'NeedsPost17Gate') -or ($ln -match 'cli_bound') -or ($ln -match 'turn_stdout_truncated') -or ($ln -match 'turn_stdout_window=1200') -or ($ln -match 'LANE-NL')) { $gateLines += $ln }
    }
    $newText = (($laneChanged -join "`n") + "`n" + ($gateLines -join "`n"))
    $nonAsciiNew = @([regex]::Matches($newText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiNew).Count -eq 0) 'mudanca ASCII-only' ('count=' + @($nonAsciiNew).Count)
    Write-Host ('[f1fix01-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[f1fix01-tests] THROW: ' + $_.Exception.Message)
    exit 1
}
