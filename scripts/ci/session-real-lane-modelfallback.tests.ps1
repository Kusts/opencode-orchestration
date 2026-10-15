# session-real-lane-modelfallback.tests.ps1 -- ORFS-LANE-MODELFALLBACK.
# Testes offline do fallback de modelo da lane scripts/ci/session-real-lane-v2.ps1:
# Invoke-LaneModelTurn tenta --model <pinned>; se falhar com
# 'Model unavailable' no output, retenta UMA vez sem --model (default do
# servico), registrando fallback na evidencia via proof 'model-fallback-default'
# (ok=true, diag informativa; vereditos intactos: fail segue fail se o retry
# falhar; ok so se retry exit 0 + job assigned).
# Decisao pura em New-LaneModelTurnOutcome (sem spawn/rede/estado): decide o
# retry, monta os args, conta chamadas e emite a proof; o turn delega a ele.
# Gate de mitigacao ORFS-SPAWN-CONTAINMENT-ADV: retry/fallback SO com a 1a
# com JobAssigned provado; 1a sem atribuicao => sem retry, terminal, reason
# estavel (job-unassigned-no-fallback) + proof diag model-fallback-refused.
# Honestidade contratual: contencao POS-SPAWN + rejeicao de resultado sem
# atribuicao; NAO contencao pre-execucao (sem "nunca sem contencao").
# A proof do 18 fica FORA do else (como 20/21), gated em fallbackProof, de modo
# que fallback+bem-sucedido tambem emite proof (regressao reviewer MEDIUM-1).
# Contencao segue o padrao P26 (nota no retry; sem mudanca no SpikeProcess).
# Sem Pester. Sem rede/spawn/modelo: os helpers puros sao extraidos do arquivo
# da lane via AST (a lane nunca e executada) e exercitados em memoria com
# fixtures sinteticas; o resto sao asserts estaticos sobre o texto da lane.
# So canarios sinteticos; nenhum segredo real. PS 5.1 e PS7 compativel. ASCII only.
# ANSI CSI e stripado antes do match no classificador (root-cause: [0m colado
# no M matava o \b); resto do contrato identico. ESC via [char]27, sem byte
# literal, no codigo e nos testes.
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
    # 1. classificador puro (comportamento)
    Assert-That ($funcs.ContainsKey('Test-LaneModelUnavailableOutput')) 'helper Test-LaneModelUnavailableOutput exists' 'helper ausente na lane'
    if ($funcs.ContainsKey('Test-LaneModelUnavailableOutput')) {
        Invoke-Expression $funcs['Test-LaneModelUnavailableOutput']
        $p1 = $false
        try { $p1 = Test-LaneModelUnavailableOutput -Text 'ERROR Model unavailable: opencode-go/muse-spark-1.3-contributor rc=1' } catch { $p1 = $false }
        Assert-That ([bool]$p1) 'unavailable com colon => true' 'false'
        $p2 = $false
        try { $p2 = Test-LaneModelUnavailableOutput -Text 'model unavailable opencode-go/muse-spark-1.3-contributor' } catch { $p2 = $false }
        Assert-That ([bool]$p2) 'unavailable com espaco => true' 'false'
        $p3 = $false
        try { $p3 = Test-LaneModelUnavailableOutput -Text 'MODEL UNAVAILABLE: X' } catch { $p3 = $false }
        Assert-That ([bool]$p3) 'unavailable upper => true' 'false'
        $n1 = $true
        try { $n1 = Test-LaneModelUnavailableOutput -Text '' } catch { $n1 = $false }
        Assert-That (-not [bool]$n1) 'vazio => false' 'true'
        $n2 = $true
        try { $n2 = Test-LaneModelUnavailableOutput -Text 'turn TIMEOUT 180000ms sem resposta' } catch { $n2 = $false }
        Assert-That (-not [bool]$n2) 'timeout sem frase => false' 'true'
        $n3 = $true
        try { $n3 = Test-LaneModelUnavailableOutput -Text 'exit=1 connection refused by service' } catch { $n3 = $false }
        Assert-That (-not [bool]$n3) 'outro erro => false' 'true'
        $n4 = $true
        try { $n4 = Test-LaneModelUnavailableOutput -Text 'assistant reply ok rc=0' } catch { $n4 = $false }
        Assert-That (-not [bool]$n4) 'rc0 sem frase => false' 'true'
        $n5 = $true
        try { $n5 = Test-LaneModelUnavailableOutput -Text 'model busy try again' } catch { $n5 = $false }
        Assert-That (-not [bool]$n5) 'frase parcial => false' 'true'
        # 1i. ANSI real: reset [0m colado no M (root-cause: \b morria no 'mM')
        $esc = [string][char]27
        $a1 = $false
        try { $a1 = Test-LaneModelUnavailableOutput -Text ($esc + '[0mModel unavailable: syn-model-ansi-01') } catch { $a1 = $false }
        Assert-That ([bool]$a1) 'ANSI [0m colado => true' 'false'
        # 1j. multi-sequencia SGR antes da frase
        $a2 = $false
        try { $a2 = Test-LaneModelUnavailableOutput -Text ($esc + '[91m' + $esc + '[1mError:  ' + $esc + '[0mModel unavailable: syn-model-ansi-02') } catch { $a2 = $false }
        Assert-That ([bool]$a2) 'ANSI multi SGR => true' 'false'
        # 1k. ANSI no meio da frase
        $a3 = $false
        try { $a3 = Test-LaneModelUnavailableOutput -Text ('Model' + $esc + '[0m unavailable syn-ansi-03') } catch { $a3 = $false }
        Assert-That ([bool]$a3) 'ANSI no meio da frase => true' 'false'
        # 1l. ANSI-only sem frase => false
        $a4 = $true
        try { $a4 = Test-LaneModelUnavailableOutput -Text ($esc + '[91m' + $esc + '[0m boom syn-ansi-04') } catch { $a4 = $false }
        Assert-That (-not [bool]$a4) 'ANSI-only sem frase => false' 'true'
        # 1m. escape solitario sem CSI nao quebra (false, sem throw)
        $a5 = $true
        try { $a5 = Test-LaneModelUnavailableOutput -Text ($esc + ' syn-lone-05 model busy') } catch { $a5 = $false }
        Assert-That (-not [bool]$a5) 'escape solitario => false sem throw' 'true/throw'
        # 1n. texto limpo intacto
        $a6 = $false
        try { $a6 = Test-LaneModelUnavailableOutput -Text '  Model unavailable. syn-clean-06  ' } catch { $a6 = $false }
        Assert-That ([bool]$a6) 'texto limpo intacto => true' 'false'
    }
    # 2. decisao pura sem spawn (fixtures sinteticas; sem mocks de processo)
    Assert-That ($funcs.ContainsKey('New-LaneModelTurnOutcome')) 'helper New-LaneModelTurnOutcome exists' 'helper de decisao ausente na lane'
    if ($funcs.ContainsKey('New-LaneModelTurnOutcome')) {
        $outFn = [string]$funcs['New-LaneModelTurnOutcome']
        Assert-That ($outFn -notmatch 'Invoke-SpikeChild') 'decisao pura (sem spawn)' 'spawn dentro do helper'
        Assert-That ($outFn -notmatch 'Invoke-PreflightBoundedExe') 'decisao pura (sem exe bounded)' 'exe dentro do helper'
        $hasLoopOut = (($outFn -match '\bwhile\b') -or ($outFn -match '\bfor\b') -or ($outFn -match '\bforeach\b'))
        Assert-That (-not $hasLoopOut) 'decisao sem loop' 'loop no helper'
        Assert-That ($outFn.Contains('Test-LaneModelUnavailableOutput')) 'decisao usa o classificador' 'classificador nao referenciado'
        $outFlags = @([regex]::Matches($outFn, "'--model'"))
        Assert-That (@($outFlags).Count -eq 1) 'flag --model 1x no helper (so 1a)' ('count=' + @($outFlags).Count)
        $fmtFlags = @([regex]::Matches($outFn, "'--format', 'json'"))
        Assert-That (@($fmtFlags).Count -eq 2) 'flag --format json 2x no helper (1a+retry; matcher exige stream estruturado)' ('count=' + @($fmtFlags).Count)
        Assert-That ($outFn -notmatch "'--model',\s*''") 'retry sem string vazia de modelo' 'placeholder vazio'
        Assert-That (($outFn.Contains('noFallbackReason')) -and ($outFn.Contains('refusedProof')) -and ($outFn.Contains('retryDue'))) 'helper expoe gate/proof de recusa' 'campos ausentes'
        Assert-That (($outFn.Contains('job-unassigned-no-fallback')) -and ($outFn.Contains('model-fallback-refused'))) 'helper define reason/proof de recusa' 'tokens ausentes'
        Invoke-Expression $funcs['New-LaneModelTurnOutcome']
        # 2a. sucesso na 1a: 1 chamada, sem retry
        $fixOk = @{ ExitCode = 0; TimedOut = $false; Stdout = 'assistant reply syn-ok-01'; Stderr = ''; JobAssigned = $true; JobNote = 'syn' }
        $oOk = New-LaneModelTurnOutcome -FirstResult $fixOk -SessionId 'syn-sess-01' -SafePrompt 'syn-prompt-01' -Model 'syn-model-01'
        Assert-That ((-not [bool]$oOk.shouldRetry) -and ([int]$oOk.calls -eq 1) -and (-not [bool]$oOk.fallback)) 'sucesso-1a: 1 chamada sem retry' ('retry=' + [bool]$oOk.shouldRetry + ' calls=' + [int]$oOk.calls)
        Assert-That (($null -eq $oOk.retryArgs) -and ($null -eq $oOk.fallbackProof) -and (@($oOk.proofs).Count -eq 0)) 'sucesso-1a: sem retryArgs/proof' 'residuo de retry'
        Assert-That ([bool]$oOk.ok -and ([string]$oOk.final.Stdout -ceq 'assistant reply syn-ok-01')) 'sucesso-1a: ok com final da 1a' 'ok/final divergente'
        Assert-That ((@($oOk.firstArgs) -contains '--model') -and (@($oOk.firstArgs) -contains 'syn-model-01')) 'sucesso-1a: 1a com --model' 'args da 1a divergentes'
        Assert-That (((@($oOk.firstArgs) -contains '--format') -and (@($oOk.firstArgs) -contains 'json') -and (@($oOk.firstArgs) -contains 'syn-sess-01'))) 'sucesso-1a: 1a com --format json + sessao (prova de origem)' ('args=' + (@($oOk.firstArgs) -join ','))
        # 2b. indisponivel + retry ok: 2 chamadas, 2a sem --model, proof emitida
        $fixUn = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'ERROR Model unavailable: syn-model-02'; JobAssigned = $true; JobNote = 'syn' }
        $fixRe = @{ ExitCode = 0; TimedOut = $false; Stdout = 'assistant reply syn-re-02'; Stderr = ''; JobAssigned = $true; JobNote = 'syn' }
        $oFb = New-LaneModelTurnOutcome -FirstResult $fixUn -RetryResult $fixRe -SessionId 'syn-sess-02' -SafePrompt 'syn-prompt-02' -Model 'syn-model-02'
        Assert-That (([bool]$oFb.shouldRetry) -and ([int]$oFb.calls -eq 2) -and ([bool]$oFb.fallback)) 'indisponivel: retry decidido, 2 chamadas' ('retry=' + [bool]$oFb.shouldRetry + ' calls=' + [int]$oFb.calls)
        Assert-That ((@($oFb.retryArgs) -notcontains '--model') -and (@($oFb.retryArgs) -contains 'syn-sess-02') -and (@($oFb.retryArgs) -contains 'syn-prompt-02')) 'retry sem --model (flag omitida)' ('args=' + (@($oFb.retryArgs) -join ','))
        Assert-That (((@($oFb.retryArgs) -contains '--format') -and (@($oFb.retryArgs) -contains 'json') -and (@($oFb.retryArgs) -contains 'syn-sess-02') -and (@($oFb.retryArgs) -contains 'syn-prompt-02'))) 'retry com --format json + sessao/prompt (prova de origem)' ('args=' + (@($oFb.retryArgs) -join ','))
        Assert-That ([bool]$oFb.ok -and ([string]$oFb.final.Stdout -ceq 'assistant reply syn-re-02')) 'retry ok: final do retry' 'final divergente'
        Assert-That (($null -ne $oFb.fallbackProof) -and ([string]$oFb.fallbackProof['proof'] -ceq 'model-fallback-default') -and ([bool]$oFb.fallbackProof['ok'])) 'fallback emite proof ok=true' 'proof ausente/divergente'
        Assert-That ((@($oFb.proofs).Count -eq 1) -and ([string]$oFb.proofs[0]['proof'] -ceq 'model-fallback-default')) 'proofs por cenario: 1 fallback' 'proofs divergentes'
        # 2c. indisponivel + retry falha: fallback true, ok false (fail segue fail)
        $fixReFail = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'boom syn-03'; JobAssigned = $true; JobNote = 'syn' }
        $oFbFail = New-LaneModelTurnOutcome -FirstResult $fixUn -RetryResult $fixReFail -SessionId 'syn-sess-03' -SafePrompt 'syn-prompt-03' -Model 'syn-model-03'
        Assert-That (([bool]$oFbFail.fallback) -and (-not [bool]$oFbFail.ok) -and ($null -ne $oFbFail.fallbackProof)) 'retry falhou: fail segue fail com proof' 'veredito/proof divergente'
        # 2d. timeout: 1 chamada, sem retry
        $fixTo = @{ ExitCode = -1; TimedOut = $true; Stdout = ''; Stderr = 'TIMEOUT syn-04'; JobAssigned = $false; JobNote = 'syn' }
        $oTo = New-LaneModelTurnOutcome -FirstResult $fixTo -SessionId 'syn-sess-04' -SafePrompt 'syn-prompt-04' -Model 'syn-model-04'
        Assert-That ((-not [bool]$oTo.shouldRetry) -and ([int]$oTo.calls -eq 1) -and (-not [bool]$oTo.fallback)) 'timeout: 1 chamada sem retry' 'retry indevido'
        # 2e. outro erro: 1 chamada, sem retry
        $fixEr = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'connection refused syn-05'; JobAssigned = $true; JobNote = 'syn' }
        $oEr = New-LaneModelTurnOutcome -FirstResult $fixEr -SessionId 'syn-sess-05' -SafePrompt 'syn-prompt-05' -Model 'syn-model-05'
        Assert-That ((-not [bool]$oEr.shouldRetry) -and ([int]$oEr.calls -eq 1) -and ($null -eq $oEr.retryArgs)) 'outro erro: 1 chamada sem retry' 'retry indevido'
        # 2f. contencao ausente: retry devido mas recusado (fail-closed)
        $oRef = New-LaneModelTurnOutcome -FirstResult $fixUn -RetryRefused $true -SessionId 'syn-sess-06' -SafePrompt 'syn-prompt-06' -Model 'syn-model-06'
        Assert-That (([bool]$oRef.shouldRetry) -and (-not [bool]$oRef.fallback) -and ([int]$oRef.calls -eq 1)) 'recusa: retry devido mas nao usado' 'recusa divergente'
        Assert-That (([string]$oRef.final.Stderr -ceq 'ERROR Model unavailable: syn-model-02') -and ($null -eq $oRef.fallbackProof)) 'recusa: 1a prevalece sem proof' 'final/proof divergente'
        Assert-That ([string]$oRef.noFallbackReason -like 'retry-job-unavailable*') 'recusa: reason estavel' 'reason divergente'
        Assert-That (($null -ne $oRef.refusedProof) -and ([string]$oRef.refusedProof['proof'] -ceq 'model-fallback-refused') -and ([bool]$oRef.refusedProof['ok'])) 'recusa: proof diag emitida' 'proof ausente'
        # 2g. 1a sem assign + indisponivel: sem retry + reason + proof diag
        $fixNoA = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'ERROR Model unavailable: syn-model-07'; JobAssigned = $false; JobNote = 'syn' }
        $oNoA = New-LaneModelTurnOutcome -FirstResult $fixNoA -SessionId 'syn-sess-07' -SafePrompt 'syn-prompt-07' -Model 'syn-model-07'
        Assert-That ((-not [bool]$oNoA.shouldRetry) -and ([bool]$oNoA.retryDue) -and ([int]$oNoA.calls -eq 1) -and (-not [bool]$oNoA.fallback)) 'sem-assign: sem retry, terminal' 'retry indevido'
        Assert-That ([string]$oNoA.noFallbackReason -like 'job-unassigned-no-fallback*') 'sem-assign: reason estavel' 'reason divergente'
        Assert-That (($null -ne $oNoA.refusedProof) -and ([string]$oNoA.refusedProof['proof'] -ceq 'model-fallback-refused') -and ([bool]$oNoA.refusedProof['ok']) -and (@($oNoA.proofs).Count -eq 1)) 'sem-assign: proof diag' 'proof ausente'
        # 2h. 1a sem assign + outro erro: fora de classe (sem reason/proof)
        $fixNoAe = @{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'connection refused syn-08'; JobAssigned = $false; JobNote = 'syn' }
        $oNoAe = New-LaneModelTurnOutcome -FirstResult $fixNoAe -SessionId 'syn-sess-08' -SafePrompt 'syn-prompt-08' -Model 'syn-model-08'
        Assert-That ((-not [bool]$oNoAe.shouldRetry) -and (-not [bool]$oNoAe.retryDue) -and ([string]$oNoAe.noFallbackReason -ceq '') -and ($null -eq $oNoAe.refusedProof)) 'sem-assign fora de classe: sem reason/proof' 'residuo'
    }
    # 3. delegacao no turn (Invoke-LaneModelTurn usa o helper; sem gate inline)
    Assert-That ($funcs.ContainsKey('Invoke-LaneModelTurn')) 'turn Invoke-LaneModelTurn extracted' 'missing'
    if ($funcs.ContainsKey('Invoke-LaneModelTurn')) {
        $turnFn = [string]$funcs['Invoke-LaneModelTurn']
        Assert-That ($turnFn.Contains('New-LaneModelTurnOutcome')) 'turn delega decisao ao helper' 'helper nao referenciado no turn'
        $delCalls = @([regex]::Matches($turnFn, 'New-LaneModelTurnOutcome'))
        Assert-That (@($delCalls).Count -ge 3) 'delegacao nas 3 fases (args/decisao/desfecho)' ('calls=' + @($delCalls).Count)
        Assert-That (($turnFn.Contains('$plan.firstArgs')) -and ($turnFn.Contains('$gate.retryArgs')) -and ($turnFn.Contains('$gate.shouldRetry')) -and ($turnFn.Contains('$outcome.final')) -and ($turnFn.Contains('$res.fallbackProof'))) 'turn usa args/decisao/desfecho do helper' 'uso parcial'
        Assert-That ($turnFn -notmatch 'Test-LaneModelUnavailableOutput') 'gate vive no helper (nao inline)' 'gate duplicado no turn'
        $turnModelFlags = @([regex]::Matches($turnFn, "'--model'"))
        Assert-That (@($turnModelFlags).Count -eq 0) 'turn sem flag inline (args do helper)' ('count=' + @($turnModelFlags).Count)
        $turnFmtFlags = @([regex]::Matches($turnFn, "'--format'"))
        Assert-That (@($turnFmtFlags).Count -eq 0) 'turn sem formato inline (formato vem do helper)' ('count=' + @($turnFmtFlags).Count)
        $spawns = @([regex]::Matches($turnFn, 'Invoke-SpikeChild'))
        Assert-That (@($spawns).Count -eq 2) 'exatamente 1 retry (2 spawns)' ('spawns=' + @($spawns).Count)
        $hasLoop = (($turnFn -match '\bwhile\b') -or ($turnFn -match '\bfor\b') -or ($turnFn -match '\bforeach\b'))
        Assert-That (-not $hasLoop) 'retry unico sem loop' 'loop no turn'
        Assert-That (($turnFn.Contains('$res.fallback')) -and ($turnFn.Contains('$res.fallbackProof'))) 'resultado expoe fallback+proof' 'campos ausentes'
        Assert-That (($turnFn.Contains('$res.refusedProof')) -and ($turnFn.Contains('$final.refusedProof')) -and ($turnFn.Contains('noFallbackReason'))) 'turn expoe recusa (reason+proof)' 'wiring ausente'
        Assert-That (($turnFn.Contains('NAO e contencao pre-execucao')) -and ($turnFn.Contains('POS-SPAWN'))) 'honestidade: pos-spawn, nao pre-execucao' 'fraseo divergente'
        Assert-That ($turnFn.Contains('$res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))')) 'expressao de turn-ok intacta' 'semantica alterada'
        Assert-That ($turnFn.Contains('P26') -and ($turnFn.Contains('create-suspended'))) 'nota P26 + create-suspended no retry' 'nota ausente'
    }
    # 4. evidencia: proof definida 1x no helper; 3 usos gated; 18 fora do else
    $fbDefs = @([regex]::Matches($text, 'proof = ''model-fallback-default'''))
    Assert-That (@($fbDefs).Count -eq 1) 'model-fallback-default definida 1x (helper)' ('count=' + @($fbDefs).Count)
    $fbBad = @([regex]::Matches($text, 'proof = ''model-fallback-default''; ok = \$false'))
    Assert-That (@($fbBad).Count -eq 0) 'model-fallback-default nunca com ok=false' ('count=' + @($fbBad).Count)
    Assert-That ($text.Contains('if ($null -ne $turn18.fallbackProof)')) '18: proof gated em fallbackProof' 'guard ausente'
    Assert-That ($text.Contains('if ($null -ne $turn20.fallbackProof)')) '20: proof gated em fallbackProof' 'guard ausente'
    Assert-That ($text.Contains('if ($null -ne $turn21.fallbackProof)')) '21: proof gated em fallbackProof' 'guard ausente'
    Assert-That ((@([regex]::Matches($text, '\$turn1[89]\.fallbackProof|\$turn2[01]\.fallbackProof')).Count) -eq 6) '3 usos gated (guard+add em 18/20/21)' 'usos divergentes'
    $rfDefs = @([regex]::Matches($text, 'proof = ''model-fallback-refused'''))
    Assert-That (@($rfDefs).Count -eq 1) 'model-fallback-refused definida 1x (helper)' ('count=' + @($rfDefs).Count)
    $rfBad = @([regex]::Matches($text, 'proof = ''model-fallback-refused''; ok = \$false'))
    Assert-That (@($rfBad).Count -eq 0) 'model-fallback-refused nunca com ok=false' ('count=' + @($rfBad).Count)
    Assert-That ($text.Contains('if ($null -ne $turn18.refusedProof)')) '18: recusa gated em refusedProof' 'guard ausente'
    Assert-That ($text.Contains('if ($null -ne $turn20.refusedProof)')) '20: recusa gated em refusedProof' 'guard ausente'
    Assert-That ($text.Contains('if ($null -ne $turn21.refusedProof)')) '21: recusa gated em refusedProof' 'guard ausente'
    Assert-That ((@([regex]::Matches($text, '\$turn1[89]\.refusedProof|\$turn2[01]\.refusedProof')).Count) -eq 6) '3 recusas gated (guard+add em 18/20/21)' 'usos divergentes'
    Assert-That ($text -notmatch 'nunca sem contencao') 'sem alegacao de contencao total' 'overclaim presente'
    $idxFb18 = $text.IndexOf('if ($null -ne $turn18.fallbackProof)')
    $idxOk18 = $text.IndexOf('if ([bool]$turn18.ok)')
    Assert-That ((($idxFb18 -ge 0) -and ($idxOk18 -ge 0) -and ($idxFb18 -lt $idxOk18))) '18: fallback fora do else (antes do if-ok)' 'proof ainda no else'
    $idxRf18 = $text.IndexOf('if ($null -ne $turn18.refusedProof)')
    Assert-That ((($idxRf18 -ge 0) -and ($idxOk18 -ge 0) -and ($idxRf18 -lt $idxOk18))) '18: recusa fora do else (antes do if-ok)' 'posicao divergente'
    $idxOut20 = $text.IndexOf('detail = ([string]$turn20.output_excerpt)')
    $idxFb20 = $text.IndexOf('if ($null -ne $turn20.fallbackProof)')
    $idxOk20 = $text.IndexOf('if ([bool]$turn20.ok)')
    Assert-That ((($idxOut20 -ge 0) -and ($idxFb20 -gt $idxOut20) -and ($idxOk20 -gt $idxFb20))) '20: ordem output/fallback/if-ok' 'ordem divergente'
    $idxOut21 = $text.IndexOf('detail = ([string]$turn21.output_excerpt)')
    $idxFb21 = $text.IndexOf('if ($null -ne $turn21.fallbackProof)')
    $idxOk21 = $text.IndexOf('if ([bool]$turn21.ok)')
    Assert-That ((($idxOut21 -ge 0) -and ($idxFb21 -gt $idxOut21) -and ($idxOk21 -gt $idxFb21))) '21: ordem output/fallback/if-ok' 'ordem divergente'
    Assert-That ($text.Contains('$hardFail20 = $false') -and $text.Contains('$hardFail21 = $false')) 'vereditos 20/21 intactos (hardFail loops)' 'gates alterados'
    Assert-That ($text.Contains("elseif (`$allOk) { 'blocked' }")) 'veredito 18 intacto (blocked segue blocked)' 'gate alterado'
    Assert-That ($text.Contains("proof = 'model-turn-output'; ok = `$true")) 'model-turn-output intacto (3 diag)' 'regressao turndiag'
    # 5. ASCII-only na mudanca + no teste
    $newSpans = @()
    if ($funcs.ContainsKey('Test-LaneModelUnavailableOutput')) { $newSpans += $funcs['Test-LaneModelUnavailableOutput'] }
    if ($funcs.ContainsKey('New-LaneModelTurnOutcome')) { $newSpans += $funcs['New-LaneModelTurnOutcome'] }
    if ($funcs.ContainsKey('Invoke-LaneModelTurn')) { $newSpans += $funcs['Invoke-LaneModelTurn'] }
    $spanLines = @()
    foreach ($ln in ($text -split "`r?`n")) {
        if (($ln -match 'model-fallback-default') -or ($ln -match 'ModelUnavailable') -or ($ln -match 'ModelTurnOutcome') -or ($ln -match 'fallbackProof') -or ($ln -match 'refusedProof') -or ($ln -match 'noFallback')) { $spanLines += $ln }
    }
    Assert-That (@($spanLines).Count -ge 10) 'mudanca cobre helpers+delegacao+3 proofs' ('linhas=' + @($spanLines).Count)
    $newText = (($newSpans -join "`n") + "`n" + ($spanLines -join "`n"))
    $nonAsciiNew = @([regex]::Matches($newText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiNew).Count -eq 0) 'mudanca ASCII-only' ('count=' + @($nonAsciiNew).Count)
    $selfText = [IO.File]::ReadAllText($PSCommandPath)
    $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
    Write-Host ('[modelfallback-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[modelfallback-tests] THROW: ' + $_.Exception.Message)
    exit 1
}
