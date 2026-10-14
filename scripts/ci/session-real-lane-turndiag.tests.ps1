# session-real-lane-turndiag.tests.ps1 -- ORFS-LANE-TURNDIAG.
# Testes offline da instrumentacao de diagnostico de turn de modelo da lane
# scripts/ci/session-real-lane-v2.ps1: em falha de turn (rc!=0/timeout) a
# evidencia do cenario ganha proof 'model-turn-output' com excerpt sanitizado
# via Get-LaneSafeText (cap 1200), sem alterar veredito (blocked segue
# blocked, fail segue fail); turn OK nao muda nada.
# Sem Pester. Sem rede/spawn/modelo: o helper e extraido do arquivo da lane
# via AST (a lane nunca e executada) e exercitado em memoria; o resto sao
# asserts estaticos sobre o texto da lane. So canarios sinteticos
# (sk-SYNTHETICSECRET-*, EXAMPLEVALUE*); nenhum segredo real.
# Cobertura ORFS-LANE-TURNDIAG rodada 2 (reviewer+sec): excerpt SOMENTE em
# falha (sucesso mantem '') + pre-redacao local de valores com aspas
# (NOME="v", NOME='v', "NOME": "v", 'NOME': 'v') antes do cap.
# PS 5.1 e PS7 compativel. ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:ModelKeyEnvNameClean = ''
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
    Assert-That ($funcs.ContainsKey('Get-LaneSafeText')) 'dependency Get-LaneSafeText extracted' 'missing'
    Assert-That ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) 'helper Get-LaneModelTurnOutputExcerpt exists' 'RED: helper ausente na lane'
    if ($funcs.ContainsKey('Get-LaneSafeText') -and $funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) {
        Invoke-Expression $funcs['Get-LaneSafeText']
        Invoke-Expression $funcs['Get-LaneModelTurnOutputExcerpt']
        # 1. segredo sintetico sk-* redigido
        $canaryOut = Get-LaneModelTurnOutputExcerpt -Stdout 'turn falhou rc=1 detalhe sk-SYNTHETICSECRET-abc123 fim' -Stderr ''
        Assert-That (([string]$canaryOut -notmatch 'SYNTHETICSECRET') -and ([string]$canaryOut -match '\[REDACTED\]')) 'sk-SYNTHETICSECRET redigido' ([string]$canaryOut)
        # 2. padrao NOME=valor da key configurada redigido (NOME apenas; valor sintetico)
        $script:ModelKeyEnvNameClean = 'OPENCODE_GO_API_KEY'
        $keyOut = Get-LaneModelTurnOutputExcerpt -Stdout 'falha em OPENCODE_GO_API_KEY=EXAMPLEVALUE99 rc=1' -Stderr ''
        Assert-That (([string]$keyOut -notmatch 'EXAMPLEVALUE99') -and ([string]$keyOut -match 'OPENCODE_GO_API_KEY=\[REDACTED\]')) 'NOME=valor da key redigido' ([string]$keyOut)
        $script:ModelKeyEnvNameClean = ''
        # 3. truncagem em 1200
        $long = ('A' * 2000)
        $truncOut = Get-LaneModelTurnOutputExcerpt -Stdout $long -Stderr ''
        Assert-That (([string]$truncOut).Length -eq 1200) 'truncagem em 1200 chars' ('len=' + ([string]$truncOut).Length)
        # 4. saida vazia tratada (placeholder ASCII, nunca vazio)
        $emptyOut = Get-LaneModelTurnOutputExcerpt -Stdout '' -Stderr ''
        Assert-That (([string]$emptyOut -ceq '(sem saida capturada)')) 'saida vazia vira placeholder' ([string]$emptyOut)
        # 5. stdout+stderr combinados no excerpt
        $bothOut = Get-LaneModelTurnOutputExcerpt -Stdout 'OUTMARK-syn-01' -Stderr 'ERRMARK-syn-02'
        Assert-That (([string]$bothOut -match 'OUTMARK-syn-01') -and ([string]$bothOut -match 'ERRMARK-syn-02')) 'stdout+stderr combinados' ([string]$bothOut)
        # 10. NOME="valor" com aspas duplas (bypass do padrao sem aspas)
        $qdOut = Get-LaneModelTurnOutputExcerpt -Stdout 'falha em OPENCODE_API_KEY="EXAMPLEVALUE-DQ99" rc=1' -Stderr ''
        Assert-That (([string]$qdOut -notmatch 'EXAMPLEVALUE-DQ99') -and ([string]$qdOut -match 'OPENCODE_API_KEY=\[REDACTED\]')) 'NOME="valor" redigido' ([string]$qdOut)
        # 11. NOME='valor' com aspas simples
        $qsOut = Get-LaneModelTurnOutputExcerpt -Stdout "falha em GITHUB_TOKEN='EXAMPLEVALUE-SQ99' rc=1" -Stderr ''
        Assert-That (([string]$qsOut -notmatch 'EXAMPLEVALUE-SQ99') -and ([string]$qsOut -match 'GITHUB_TOKEN=\[REDACTED\]')) "NOME='valor' redigido" ([string]$qsOut)
        # 12. "NOME": "valor" JSON com aspas duplas
        $jdOut = Get-LaneModelTurnOutputExcerpt -Stdout '"GIT_TOKEN": "EXAMPLEVALUE-JSON99", outro=1' -Stderr ''
        Assert-That (([string]$jdOut -notmatch 'EXAMPLEVALUE-JSON99') -and ([string]$jdOut -match 'GIT_TOKEN')) '"NOME": "valor" redigido' ([string]$jdOut)
        # 13. 'NOME': 'valor' JSON com aspas simples
        $jsOut = Get-LaneModelTurnOutputExcerpt -Stdout "'NPM_TOKEN': 'EXAMPLEVALUE-JSQ99', outro=1" -Stderr ''
        Assert-That (([string]$jsOut -notmatch 'EXAMPLEVALUE-JSQ99') -and ([string]$jsOut -match 'NPM_TOKEN')) "'NOME': 'valor' redigido" ([string]$jsOut)
        # 14. stem generico com aspas (chave desconhecida com cara de segredo)
        $genOut = Get-LaneModelTurnOutputExcerpt -Stdout '"db_password": "EXAMPLEVALUE-GEN99", outro=1' -Stderr ''
        Assert-That (([string]$genOut -notmatch 'EXAMPLEVALUE-GEN99')) 'stem generico com aspas redigido' ([string]$genOut)
        # 15. model-key opt-in tambem com aspas (nome dinamico na lista local)
        $script:ModelKeyEnvNameClean = 'OPENCODE_GO_API_KEY'
        $mkqOut = Get-LaneModelTurnOutputExcerpt -Stdout 'falha em OPENCODE_GO_API_KEY="EXAMPLEVALUE-MK99" rc=1' -Stderr ''
        Assert-That (([string]$mkqOut -notmatch 'EXAMPLEVALUE-MK99') -and ([string]$mkqOut -match 'OPENCODE_GO_API_KEY=\[REDACTED\]')) 'model-key com aspas redigido' ([string]$mkqOut)
        $script:ModelKeyEnvNameClean = ''
        # 16. truncagem DEPOIS da redacao: segredo com aspas + padding longo
        $longQ = ('"GITHUB_TOKEN": "EXAMPLEVALUE-LONG99", pad=' + ('P' * 2000))
        $longQOut = Get-LaneModelTurnOutputExcerpt -Stdout $longQ -Stderr ''
        Assert-That ((([string]$longQOut).Length -le 1200) -and ([string]$longQOut -notmatch 'EXAMPLEVALUE-LONG99')) 'truncagem depois da redacao' ('len=' + ([string]$longQOut).Length)
        # 40. JSON com aspa escapada: par inteiro redigido, sem residual TAIL
        $escDQ = Get-LaneModelTurnOutputExcerpt -Stdout '{"GITHUB_TOKEN": "prefix\"TAIL99X"}' -Stderr ''
        Assert-That (([string]$escDQ -notmatch 'TAIL99X') -and ([string]$escDQ -notmatch 'prefix')) 'aspa escapada dq sem residual' ([string]$escDQ)
        $escSQ = Get-LaneModelTurnOutputExcerpt -Stdout "{'GIT_TOKEN': 'pre\'TAIL98X'}" -Stderr ''
        Assert-That (([string]$escSQ -notmatch 'TAIL98X') -and ([string]$escSQ -notmatch 'pre\\')) 'aspa escapada sq sem residual' ([string]$escSQ)
        # 41. nomes genericos exatos (sem prefixo): "password" e 'token'
        $genDQ = Get-LaneModelTurnOutputExcerpt -Stdout '{"password": "EXAMPLEVALUE-T43"}' -Stderr ''
        Assert-That (([string]$genDQ -notmatch 'EXAMPLEVALUE-T43')) '"password" exato redigido' ([string]$genDQ)
        $genSQ = Get-LaneModelTurnOutputExcerpt -Stdout "{'token': 'EXAMPLEVALUE-T42'}" -Stderr ''
        Assert-That (([string]$genSQ -notmatch 'EXAMPLEVALUE-T42')) "'token' exato redigido" ([string]$genSQ)
        # 42. truncagem segue apos redacao com escape + padding longo
        $longE = ('{"GITHUB_TOKEN": "pre\"TAIL77X", pad=' + ('P' * 2000))
        $longEOut = Get-LaneModelTurnOutputExcerpt -Stdout $longE -Stderr ''
        Assert-That ((([string]$longEOut).Length -le 1200) -and ([string]$longEOut -notmatch 'TAIL77X')) 'truncagem apos redacao com escape' ('len=' + ([string]$longEOut).Length)
        # 17. espelho do guard da lane: excerpt SOMENTE em falha (fidelidade
        # travada pelo assert do texto do guard em Invoke-LaneModelTurn abaixo)
        function Get-TurnDiagGuardedExcerpt($Attempted, $Ok, $Stdout, $Stderr) {
            if (([bool]$Attempted) -and (-not [bool]$Ok)) { return (Get-LaneModelTurnOutputExcerpt -Stdout ([string]$Stdout) -Stderr ([string]$Stderr)) }
            return ''
        }
        $gOk = Get-TurnDiagGuardedExcerpt -Attempted $true -Ok $true -Stdout 'ok OUTMARK-syn-10' -Stderr ''
        Assert-That ([string]$gOk -ceq '') 'sucesso => excerpt vazio' ([string]$gOk)
        $gErr = Get-TurnDiagGuardedExcerpt -Attempted $true -Ok $false -Stdout 'rc=1 ERRMARK-syn-11' -Stderr ''
        Assert-That (([string]$gErr -match 'ERRMARK-syn-11')) 'erro => excerpt com conteudo' ([string]$gErr)
        $gTo = Get-TurnDiagGuardedExcerpt -Attempted $true -Ok $false -Stdout '' -Stderr 'timeout TOMARK-syn-12'
        Assert-That (([string]$gTo -match 'TOMARK-syn-12')) 'timeout => excerpt com conteudo' ([string]$gTo)
        $gNa = Get-TurnDiagGuardedExcerpt -Attempted $false -Ok $false -Stdout 'x' -Stderr ''
        Assert-That ([string]$gNa -ceq '') 'nao-tentado => excerpt vazio' ([string]$gNa)
    }
    Assert-That ($funcs.ContainsKey('Invoke-LaneModelTurn')) 'turn Invoke-LaneModelTurn extraido' 'missing'
    if ($funcs.ContainsKey('Invoke-LaneModelTurn') -and $funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) {
        $turnFn = [string]$funcs['Invoke-LaneModelTurn']
        $helperFn = [string]$funcs['Get-LaneModelTurnOutputExcerpt']
        # 18. guard da lane: calculo do excerpt DEPOIS do ok e SOMENTE em falha
        $guardExpr = 'if (([bool]$res.attempted) -and (-not [bool]$res.ok))'
        Assert-That ($turnFn.Contains($guardExpr)) 'guard do excerpt e attempted-and-not-ok' 'guard ausente/divergente'
        $okPos = $turnFn.IndexOf('$res.ok = (')
        $capPos = $turnFn.IndexOf('output_excerpt = Get-LaneModelTurnOutputExcerpt -Stdout ([string]$r.Stdout)')
        Assert-That ((($okPos -ge 0) -and ($capPos -ge 0) -and ($okPos -lt $capPos))) 'excerpt calculado depois do ok' ('ok=' + $okPos + ' cap=' + $capPos)
        # 19. pre-redacao local ANTES do cap (truncagem depois da redacao)
        Assert-That ($helperFn.Contains('Get-LaneSafeText $v $Max')) 'helper aplica cap sobre texto pre-redigido' 'ordem ausente'
        Assert-That (($helperFn.IndexOf('-replace (') -ge 0) -and ($helperFn.IndexOf('-replace (') -lt $helperFn.IndexOf('Get-LaneSafeText $v $Max'))) 'pre-redacao antes do cap' 'ordem invertida'
        # 43. valores com escape: sequencia (\\. | [^"\\])* em vez de parar na aspa
        Assert-That ($helperFn.Contains('\x5c.')) 'valores reconhecem escapes' 'escape ausente'
        # 44. nomes genericos aceitam prefixo vazio/delimitador (lookbehind)
        Assert-That ($helperFn.Contains('(?<=^|')) 'generico aceita prefixo vazio' 'lookbehind ausente'
        # 20. Get-LaneSafeText compartilhada intocada (sem logica turndiag nela)
        $safeFn = [string]$funcs['Get-LaneSafeText']
        Assert-That (($safeFn.Contains('param($Value, [int]$Max = 200)')) -and ($safeFn -notmatch 'credNames|nameRx|model-turn-output|output_excerpt')) 'Get-LaneSafeText compartilhada intocada' 'alterada'
    }
    # 6. prova model-turn-output nos 3 cenarios com turn (18/20/21), ok=true (diag; veredito intacto)
    $proofAdds = @([regex]::Matches($text, 'proof = ''model-turn-output''; ok = \$true'))
    Assert-That (@($proofAdds).Count -eq 3) 'model-turn-output ok=true em 3 pontos de falha' ('count=' + @($proofAdds).Count)
    $badAdds = @([regex]::Matches($text, 'proof = ''model-turn-output''; ok = \$false'))
    Assert-That (@($badAdds).Count -eq 0) 'model-turn-output nunca com ok=false (veredito intacto)' ('count=' + @($badAdds).Count)
    # 7. gating em falha: turn OK nao ganha prova
    Assert-That ($text.Contains("if ([bool]`$turn18.attempted) { [void]`$proofs.Add([ordered]@{ proof = 'model-turn-output'")) '18: prova so em turn tentado/falho' 'guard ausente'
    Assert-That ($text.Contains("if (([bool]`$turn20.attempted) -and (-not [bool]`$turn20.ok)) { [void]`$proofs.Add([ordered]@{ proof = 'model-turn-output'")) '20: prova so em turn falho' 'guard ausente'
    Assert-That ($text.Contains("if (([bool]`$turn21.attempted) -and (-not [bool]`$turn21.ok)) { [void]`$proofs.Add([ordered]@{ proof = 'model-turn-output'")) '21: prova so em turn falho' 'guard ausente'
    # 8. captura via helper dentro de Invoke-LaneModelTurn; semantica de ok intacta
    Assert-That ($text.Contains('output_excerpt = Get-LaneModelTurnOutputExcerpt')) 'turn popula output_excerpt via helper' 'sem captura'
    Assert-That ($text.Contains('$res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))')) 'expressao de turn-ok intacta' 'semantica alterada'
    Assert-That ($text.Contains('$hardFail20 = $false') -and $text.Contains('$hardFail21 = $false')) 'vereditos 20/21 intactos (hardFail loops)' 'gates alterados'
    Assert-That ($text.Contains("elseif (`$allOk) { 'blocked' }")) 'veredito 18 intacto (blocked segue blocked)' 'gate alterado'
    # 9. ASCII-only na MUDANCA (helper + proofs + captura); o restante da lane
    # mantem o conteudo pre-existente da base (fora do escopo desta tarefa)
    $newSpans = @()
    if ($funcs.ContainsKey('Get-LaneModelTurnOutputExcerpt')) { $newSpans += $funcs['Get-LaneModelTurnOutputExcerpt'] }
    $spanLines = @()
    foreach ($ln in ($text -split "`r?`n")) {
        if (($ln -match 'model-turn-output') -or ($ln -match 'output_excerpt')) { $spanLines += $ln }
    }
    Assert-That (@($spanLines).Count -ge 7) 'mudanca cobre helper+3 proofs+captura' ('linhas=' + @($spanLines).Count)
    $newText = (($newSpans -join "`n") + "`n" + ($spanLines -join "`n"))
    $nonAsciiNew = @([regex]::Matches($newText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiNew).Count -eq 0) 'mudanca ASCII-only' ('count=' + @($nonAsciiNew).Count)
    $selfText = [IO.File]::ReadAllText($PSCommandPath)
    $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
    Write-Host ('[turndiag-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[turndiag-tests] THROW: ' + $_.Exception.Message)
    exit 1
}
