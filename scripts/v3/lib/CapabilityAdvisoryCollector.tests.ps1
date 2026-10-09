<#!
.SYNOPSIS
    Suite Phase 2G do coletor capability ADVISORY (somente leitura/offline).
.DESCRIPTION
    Valida scripts/v3/lib/CapabilityAdvisoryCollector.ps1 de forma
    deterministica e offline (fixtures so em TEMP, nada escrito no repo):

      - leitura confinada e fail-closed: raiz permitida (cache/v3/telemetry do
        repo ou TEMP), recusa de reparse point/junction em qualquer componente,
        recusa de telemetria de kernel (events-*.jsonl), recusa de arquivo
        ausente, arquivo fora da raiz e limite de arquivos/bytes/linhas;
      - leitura streaming linear e limitada POR BYTES: leitor proprio que conta
        bytes/linhas realmente examinados, guarda no maximo line_bytes por
        linha, trata UTF-8/CRLF/BOM e falha fechado em decodificacao invalida,
        linha acima do cap, escritor concorrente e orcamento de bytes;
        total_bytes e UM orcamento COMPARTILHADO por todos os arquivos e pelos
        dois streams (restante passado a cada leitor, consumo debitado), com
        fronteira exata: EOF no ultimo byte do orcamento aceita a linha final;
      - projecao por allowlist: task_id opaco de 16 hex, enums fechados, arrays
        de identificadores CONHECIDOS (allowlist de capabilities); campo
        desconhecido, nome de chave de entrada, nome de arquivo e valor
        sensivel nunca fluem para o relatorio (viram contagem);
      - sem coercao: campo textual exige JSON string (id numerico rejeitado);
        linha que repetir nome de campo LIDO e rejeitada (DUPLICATE_KEY),
        inclusive com escape JSON ('task\u005fid' === 'task_id');
      - raiz JSON tem de ser OBJETO na linha crua: array de 1 objeto (que o
        pipeline desenrola), array de N, numero, string e bool => NOT_AN_OBJECT;
      - linha malformada/oversized/fora-de-enum => rejeitada com motivo apenas
        de enum; task_id literal antigo NAO e consertado;
      - dedup de recomendacao, contagem honesta, muitas chaves distintas sem
        custo quadratico e nao-correlacao explicita entre os dois streams;
        lines_read conta TODA linha realmente lida (validas, vazias,
        malformadas, linha-sonda de cap e linha parcial do orcamento);
        a enumeracao de candidatos e o array de detalhes de arquivo ficam
        limitados por UM orcamento de arquivos COMPARTILHADO pelos dois
        streams (nao existe cap por stream) - omissao vira contagem, nunca
        entrada sem limite no relatorio;
        fronteira EXATA do orcamento de bytes: EOF no ultimo byte do
        orcamento NAO e truncamento (a linha final completa e aceita, com ou
        sem terminador); so ha truncamento quando existem bytes ALEM do
        orcamento;
        performance medida por ESCALA contra baseline menor e com tempo
        absoluto generoso: host carregado nao falha teste de custo, e
        comportamento quadratico ainda estoura a razao;
      - NENHUMA correlacao entre recomendacao do resolver e observacao
        fornecida (nao existe escopo comum): blocos separados, claims
        SUPPLIED_UNVERIFIED, campos de observacao NOT_OBSERVABLE;
      - claim conflitante para a mesma chave => AMBIGUO (nenhum claim
        escolhido); repeticao identica deduplica;
      - observacao fornecida exige provenance 'supplied', fica
        SUPPLIED_UNVERIFIED e nunca vira prova de acordo/adesao/sucesso;
      - relatorio PARTIAL sem observacoes externas, metricas indisponiveis
        marcadas NOT_OBSERVABLE, saida determinista (sem timestamp/caminho);
      - claims fornecidos: total real vs emitidos; truncation so quando
        verdadeiro; omissoes de cap disclosed;
      - duplicata detectada por scanner lexical de passada unica (sem regex),
        com fixture adversaria de milhares de aspas escapadas e tempo limitado;
      - determinismo da serializacao entre PROCESSOS separados (o teste lanca
        um processo filho e compara o JSON de saida byte a byte);
      - read-only comprovado (hash + LastWriteTime + listagem do diretorio) e
        nao-regressao 2G: flags de routing OFF e paridade do enum task_class
        com source/registry/capability-routing.json.

    Estilo distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
    PS 5.1 compativel. ASCII-only.
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
$skipped = 0

function Assert($Cond, [string]$Name, [string]$Detail = '') {
    if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
    else {
        $script:fail += 1
        $line = ("NOT OK - " + $Name)
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + " -- " + $Detail }
        Write-Host $line
    }
}
function Skip-That([string]$Name, [string]$Reason) {
    $script:skipped += 1
    Write-Host ("[SKIP] " + $Name + " -- " + $Reason)
}

$v3 = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $v3)
$libPath = Join-Path $PSScriptRoot 'CapabilityAdvisoryCollector.ps1'
$cliPath = Join-Path $v3 'capability-resolve.ps1'
$flagsPath = Join-Path $RepoRoot 'source\registry\capability-flags.json'
$routingPath = Join-Path $RepoRoot 'source\registry\capability-routing.json'

Assert (Test-Path -LiteralPath $libPath -PathType Leaf) 'lib CapabilityAdvisoryCollector.ps1 existe'
Assert (Test-Path -LiteralPath $cliPath -PathType Leaf) 'cli capability-resolve.ps1 existe (baseline intocado)'
Assert (Test-Path -LiteralPath $flagsPath -PathType Leaf) 'registry capability-flags.json existe'
Assert (Test-Path -LiteralPath $routingPath -PathType Leaf) 'registry capability-routing.json existe'

try {
    . (Join-Path $PSScriptRoot 'CapabilityAdvisoryCollector.ps1')
}
catch {
    Assert $false 'dot-source da lib sem escrita/efeito colateral' ($_.Exception.Message)
}

# ASCII-only: o repo trata acento como defeito em scripts versionados.
$nonAscii = 0
try {
    $bytes = [IO.File]::ReadAllBytes($libPath)
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii += 1 } }
}
catch { $nonAscii = -1 }
Assert ($nonAscii -eq 0) 'lib e ASCII-only' ("bytes>127: " + $nonAscii)

# ASCII-only tambem para a propria suite (o repo trata acento como defeito).
$testNonAscii = 0
try {
    $testBytes = [IO.File]::ReadAllBytes($PSCommandPath)
    foreach ($t in $testBytes) { if ($t -gt 127) { $testNonAscii += 1 } }
}
catch { $testNonAscii = -1 }
Assert ($testNonAscii -eq 0) 'suite e ASCII-only' ("bytes>127: " + $testNonAscii)

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('cap-advisory-2g-' + [guid]::NewGuid().ToString('N'))
$junctionDir = Join-Path $workDir 'telemetry'
$junctionLink = Join-Path $workDir 'jlink'
$createdDirs = @()

function New-TestDir([string]$Name) {
    $d = Join-Path $workDir $Name
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}
function Write-TestFile([string]$Dir, [string]$Name, [string[]]$Lines) {
    $p = Join-Path $Dir $Name
    $text = (@($Lines) -join "`r`n")
    if (@($Lines).Count -gt 0) { $text = $text + "`r`n" }
    [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
    return $p
}
function New-ResolverLine {
    param(
        [string]$TaskKey = 'abcdef0123456789',
        [string]$TaskClass = 'review',
        [string]$Risk = 'HIGH',
        [string]$Confidence = 'HIGH',
        [string]$Mode = 'shadow',
        [string[]]$Agents = @('reviewer'),
        [string[]]$Skills = @(),
        [string[]]$Profiles = @(),
        [string]$At = '2026-10-09T10:00:00.0000000Z'
    )
    $o = [ordered]@{
        task_id    = $TaskKey
        task_class = $TaskClass
        profiles   = @($Profiles)
        agents     = @($Agents)
        skills     = @($Skills)
        risk       = $Risk
        confidence = $Confidence
        mode       = $Mode
        at         = $At
    }
    return (ConvertTo-Json -InputObject $o -Depth 5 -Compress)
}
function New-ObservationLine {
    param(
        [string]$TaskKey = 'abcdef0123456789',
        [string]$Provenance = 'supplied',
        [string]$TaskClass = 'review',
        [string]$ClaimedAgent = 'reviewer',
        [string[]]$ClaimedSkills = @('requesting-code-review'),
        [string[]]$ClaimedMcps = @(),
        [string]$Outcome = 'SUCCESS'
    )
    $o = [ordered]@{
        provenance     = $Provenance
        task_key       = $TaskKey
        task_class     = $TaskClass
        claimed_agent  = $ClaimedAgent
        claimed_skills = @($ClaimedSkills)
        claimed_mcps   = @($ClaimedMcps)
        outcome        = $Outcome
    }
    return (ConvertTo-Json -InputObject $o -Depth 5 -Compress)
}

# Nomes das 7 metricas do relatorio. Definidos AQUI, antes de qualquer uso:
# houve regressao de ordem de inicializacao em que o laco passava sem verificar
# nada (lista vazia no ponto de uso). O teste abaixo trava a lista EXATA.
$metricNames = @('runtime_adherence', 'runtime_selected_agent', 'runtime_selected_skills', 'runtime_selected_mcps', 'productive_outcome', 'agreement_with_runtime', 'stability')
Assert (@($metricNames).Count -gt 0) 'lista de metricas nao pode estar vazia (regressao de ordem de inicializacao)' ([string]@($metricNames).Count)
Assert (@($metricNames).Count -eq 7) 'o relatorio declara EXATAMENTE 7 metricas NOT_OBSERVABLE' ([string]@($metricNames).Count)

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $telDir = New-TestDir 'telemetry'
}
catch {
    Assert $false 'diretorio temporario de trabalho criado' ($_.Exception.Message)
}

# ---- B. confinamento, fail-closed e limites ---------------------------------
$repoTelPath = Join-Path (Join-Path (Join-Path (Join-Path $RepoRoot 'cache') 'v3') 'telemetry') 'resolver-20261009.jsonl'
Assert (Test-AdvisoryConfinedInput -Path $repoTelPath -RepoRoot $RepoRoot) 'cache/v3/telemetry do repo e raiz permitida (funcao pura)' $repoTelPath
Assert (-not (Test-AdvisoryConfinedInput -Path (Join-Path $RepoRoot 'docs\plano.jsonl') -RepoRoot $RepoRoot)) 'caminho fora da raiz permitida e recusado'
Assert (-not (Test-AdvisoryConfinedInput -Path (Join-Path $env:USERPROFILE 'Documents\2g-fora.jsonl') -RepoRoot $RepoRoot)) 'caminho sob USERPROFILE\Documents (fora de TEMP) e recusado'

$outside = Join-Path $env:USERPROFILE ('2g-outside-' + [guid]::NewGuid().ToString('N') + '.jsonl')
[IO.File]::WriteAllText($outside, (New-ResolverLine), [Text.UTF8Encoding]::new($false))
$rOutside = $null
try { $rOutside = Get-AdvisoryCollectorReport -ResolverPaths @($outside) } catch { $rOutside = 'THREW' }
Assert (($null -ne $rOutside) -and ($rOutside -ne 'THREW')) 'coletor nunca lanca: path fora da raiz devolve relatorio' ([string]$rOutside)
if ($rOutside -and ($rOutside -ne 'THREW')) {
    Assert ($rOutside.collection_status -ceq 'FAILED_CLOSED') 'path fora da raiz => collection_status FAILED_CLOSED' ($rOutside.collection_status)
    Assert (@($rOutside.collection_failure_reasons) -ccontains 'OUTSIDE_ALLOWED_ROOT') 'motivo OUTSIDE_ALLOWED_ROOT' ($rOutside.collection_failure_reasons -join ',')
    Assert ([int]$rOutside.counts.resolver_records_valid -eq 0) 'arquivo fora da raiz nao produz registro valido' ([string]$rOutside.counts.resolver_records_valid)
}
Remove-Item -LiteralPath $outside -Force -ErrorAction SilentlyContinue

$eventsPath = Write-TestFile $telDir 'events-20261009.jsonl' @('{"task_id":"abcdef0123456789","event_type":"TASK_CREATED"}')
$rEvents = Get-AdvisoryCollectorReport -ObservationPaths @($eventsPath)
Assert ($rEvents.collection_status -ceq 'FAILED_CLOSED') 'events-*.jsonl (telemetria de kernel) => FAILED_CLOSED' ($rEvents.collection_status)
Assert (@($rEvents.collection_failure_reasons) -ccontains 'KERNEL_TELEMETRY_REFUSED') 'motivo KERNEL_TELEMETRY_REFUSED' ($rEvents.collection_failure_reasons -join ',')
Assert ([int]$rEvents.counts.observations_accepted -eq 0) 'telemetria de kernel nunca vira observacao'
Assert (-not $rEvents.integrity.kernel_telemetry_read) 'integridade: kernel_telemetry_read=false'

$missingPath = Join-Path $telDir 'resolver-99999999.jsonl'
$rMissing = Get-AdvisoryCollectorReport -ResolverPaths @($missingPath)
Assert ($rMissing.collection_status -ceq 'FAILED_CLOSED') 'arquivo ausente => FAILED_CLOSED' ($rMissing.collection_status)
Assert (@($rMissing.collection_failure_reasons) -ccontains 'NOT_A_FILE') 'motivo NOT_A_FILE'

$junctionOk = $false
try {
    cmd /c mklink /J "$junctionLink" "$junctionDir" | Out-Null
    $junctionOk = (Test-Path -LiteralPath $junctionLink)
}
catch { $junctionOk = $false }
if ($junctionOk) {
    $viaLink = Join-Path $junctionLink 'resolver-20261009.jsonl'
    [IO.File]::WriteAllText((Join-Path $telDir 'resolver-20261009.jsonl'), (New-ResolverLine), [Text.UTF8Encoding]::new($false))
    $rLink = Get-AdvisoryCollectorReport -ResolverPaths @($viaLink)
    Assert ($rLink.collection_status -ceq 'FAILED_CLOSED') 'junction no caminho => FAILED_CLOSED' ($rLink.collection_status)
    Assert (@($rLink.collection_failure_reasons) -ccontains 'REPARSE_POINT_REFUSED') 'motivo REPARSE_POINT_REFUSED'
    Assert ([int]$rLink.counts.resolver_records_valid -eq 0) 'arquivo atras de junction nao e lido'
}
else { Skip-That 'junction no caminho => FAILED_CLOSED' 'mklink /J indisponivel neste host' }

$limits = Get-AdvisoryCollectorLimits
Assert ([int]$limits.files -ge 1 -and [int]$limits.records -ge 1 -and [int]$limits.line_bytes -ge 1) 'limites padrao positivos'
$loosened = Get-AdvisoryCollectorReport -ResolverPaths @((Join-Path $telDir 'resolver-20261009.jsonl')) -Limits @{ files = 99999; records = 999999; line_bytes = 99999999; file_lines = 999999 }
Assert ([int]$loosened.inputs.limits.files -eq [int]$limits.files) 'override nunca afrouxa limite de arquivos'
Assert ([int]$loosened.inputs.limits.records -eq [int]$limits.records) 'override nunca afrouxa limite de registros'
Assert ([int]$loosened.inputs.limits.file_lines -eq [int]$limits.file_lines) 'override nunca afrouxa limite de linhas por arquivo'
Assert ([int]$loosened.inputs.files_skipped_by_limit -eq 0) 'sem arquivo omitido nao ha contagem de omissao'
$capLines = @(
    (New-ResolverLine -TaskKey 'aaaaaaaaaaaaaaaa'),
    (New-ResolverLine -TaskKey 'bbbbbbbbbbbbbbbb'),
    (New-ResolverLine -TaskKey 'cccccccccccccccc')
)
$capFile = Write-TestFile $telDir 'resolver-20261020.jsonl' $capLines
$tightened = Get-AdvisoryCollectorReport -ResolverPaths @($capFile) -Limits @{ records = 1 }
Assert ([int]$tightened.counts.resolver_records_valid -eq 1) 'override pode apertar limite de registros' ([string]$tightened.counts.resolver_records_valid)
Assert ($tightened.inputs.records_cap_reached) 'cap de registros sinalizado no relatorio'
Assert (@($tightened.inputs.files)[0].status -ceq 'truncated') 'arquivo interrompido pelo cap de registros fica truncated'
Assert (@($tightened.inputs.files)[0].reason -ceq 'LIMIT_EXCEEDED') 'motivo LIMIT_EXCEEDED no arquivo truncado por registros'
# a linha-sonda foi lida e o resto do arquivo e examinado sem projecao:
# lines_read conta o trabalho real e lines_omitted expoe a omissao
Assert ([int]$tightened.counts.resolver_lines_read -eq 3) 'cap de registros conta linha-sonda + varredura do resto' ([string]$tightened.counts.resolver_lines_read)
Assert ([int]$tightened.counts.resolver_lines_omitted -eq 2) 'linhas examinadas e NAO projetadas ficam explicitas' ([string]$tightened.counts.resolver_lines_omitted)
Assert ([int]@($tightened.inputs.files)[0].lines_omitted -eq 2) 'omissao de linhas atribuida ao arquivo truncado'
$notCapped = Get-AdvisoryCollectorReport -ResolverPaths @($capFile)
Assert ([int]$notCapped.counts.resolver_records_valid -eq 3) 'sem override os 3 registros do fixture sao lidos' ([string]$notCapped.counts.resolver_records_valid)
Assert (-not $notCapped.inputs.records_cap_reached) 'cap nao alcancado nao e sinalizado'
Assert ([int]$notCapped.counts.resolver_lines_omitted -eq 0) 'sem cap nao ha linha omitida'
# cap de registros alcancado no primeiro de dois arquivos: o segundo candidato
# NAO e aberto e a omissao dele e contada
$skipSecondFile01 = Write-TestFile $telDir 'resolver-20261023.jsonl' @((New-ResolverLine -TaskKey 'dddddddddddddddd'))
$twoFilesCap = Get-AdvisoryCollectorReport -ResolverPaths @($capFile, $skipSecondFile01) -Limits @{ records = 2 }
Assert ([int]$twoFilesCap.inputs.files_omitted_by_records_cap -eq 1) 'candidato nao aberto por cap de registros e contado' ([string]$twoFilesCap.inputs.files_omitted_by_records_cap)
$filesCap = Get-AdvisoryCollectorReport -ResolverPaths @($capFile, $capFile) -Limits @{ files = 1 }
Assert (@($filesCap.inputs.files).Count -eq 1) 'limite de arquivos respeitado (path repetido nao duplica detalhe)' ([string]@($filesCap.inputs.files).Count)
Assert ([int]$filesCap.inputs.files_skipped_by_limit -eq 1) 'ocorrencia repetida e contada como omitida, sem gastar slot adicional'
Assert ([int]$filesCap.inputs.candidate_paths_seen -eq 2) 'candidatos vistos incluem a repeticao (contagem, nao array)' ([string]$filesCap.inputs.candidate_paths_seen)
# com dois arquivos distintos e cap 1: um e lido, o outro e OMITIDO; o relatorio
# NAO ganha entrada sem limite pelo omitido - a omissao vira CONTAGEM
$skipSecond = Write-TestFile $telDir 'resolver-20261022.jsonl' @((New-ResolverLine -TaskKey 'dddddddddddddddd'))
$filesSkipped = Get-AdvisoryCollectorReport -ResolverPaths @($capFile, $skipSecond) -Limits @{ files = 1 }
Assert (@($filesSkipped.inputs.files).Count -eq 1) 'array de detalhes de arquivo fica limitado pelo cap de arquivos' ([string]@($filesSkipped.inputs.files).Count)
Assert ([int]$filesSkipped.inputs.files_skipped_by_limit -eq 1) 'omissao por cap de arquivos e contada' ([string]$filesSkipped.inputs.files_skipped_by_limit)
Assert ([int]$filesSkipped.inputs.candidate_paths_seen -eq 2) 'candidatos vistos discorda dos lidos (omissao explicita)' ([string]$filesSkipped.inputs.candidate_paths_seen)
$readEntries = @(@($filesSkipped.inputs.files) | Where-Object { $_.status -ceq 'read' })
$skipEntries = @(@($filesSkipped.inputs.files) | Where-Object { $_.status -ceq 'skipped' })
Assert (@($readEntries).Count -eq 1) 'apenas um arquivo efetivamente lido sob o cap'
Assert (@($skipEntries).Count -eq 0) 'arquivo omitido pelo cap nao gera entrada no relatorio'
Assert ([int]$filesSkipped.counts.resolver_records_valid -eq 3) 'somente o arquivo lido produz registros' ([string]$filesSkipped.counts.resolver_records_valid)
# muitos caminhos candidatos: enumeracao limitada, relatorio limitado, contagem exata
$manyPaths = @()
for ($mi = 0; $mi -lt 12; $mi++) {
    $manyPaths += (Join-Path $telDir ('resolver-many-' + ('{0:d2}' -f $mi) + '.jsonl'))
}
$manyPathsReport = Get-AdvisoryCollectorReport -ResolverPaths @($manyPaths) -Limits @{ files = 3 }
Assert (@($manyPathsReport.inputs.files).Count -eq 3) 'detalhes de arquivo ficam no cap de arquivos com muitos candidatos' ([string]@($manyPathsReport.inputs.files).Count)
Assert ([int]$manyPathsReport.inputs.files_skipped_by_limit -eq 9) 'candidatos omitidos contados (12 vistos, 3 lidos)' ([string]$manyPathsReport.inputs.files_skipped_by_limit)
Assert ([int]$manyPathsReport.inputs.candidate_paths_seen -eq 12) 'todos os candidatos vistos sao contados' ([string]$manyPathsReport.inputs.candidate_paths_seen)
$pathA = Join-Path $telDir 'a-resolver-order.jsonl'
$pathB = Join-Path $telDir 'b-resolver-order.jsonl'
$orderOne = Get-AdvisoryCollectorReport -ResolverPaths @($pathB, $pathB, $pathA) -Limits @{ files = 1 }
$orderTwo = Get-AdvisoryCollectorReport -ResolverPaths @($pathA, $pathB, $pathB) -Limits @{ files = 1 }
Assert ([int]$orderOne.inputs.files_skipped_by_limit -eq 2 -and [int]$orderTwo.inputs.files_skipped_by_limit -eq 2) 'contagem de omissoes e invariavel a duplicatas expulsas pela selecao' (([string]$orderOne.inputs.files_skipped_by_limit) + '/' + ([string]$orderTwo.inputs.files_skipped_by_limit))
Assert ((ConvertTo-AdvisoryCollectorJson -Report $orderOne) -ceq (ConvertTo-AdvisoryCollectorJson -Report $orderTwo)) 'selecao e contagem sao invariaveis a ordem de entrada'
$manyRefused = @(@($manyPathsReport.inputs.files) | Where-Object { $_.status -ceq 'refused' })
Assert (@($manyRefused).Count -eq 3 -and $manyRefused[0].reason -ceq 'NOT_A_FILE') 'recusa barata acontece antes do cap: NOT_A_FILE para candidatos inexistentes' ([string]@($manyRefused).Count)

# ---- B1. orcamento de arquivos COMPARTILHADO entre os dois streams ----------
# O cap 'files' e UM SO para a entrada inteira: os caminhos dos dois streams
# concorrem aos MESMOS slots, o array de detalhes nunca passa de files
# entradas e o omitido (incluindo o que seria rejeitado) vira CONTAGEM precisa.
# Antes desta correcao cada stream recebia o cap cheio: com files=1, um resolver
# e uma observacao podiam ser lidos ao mesmo tempo e o relatorio podia ganhar
# 2 entradas de detalhe - acima do limite declarado em inputs.limits.files.
$crossDir = New-TestDir 'crossstream'
$crossResLine = (New-ResolverLine -TaskKey 'abcdef0123456789')
$crossObsLine = (New-ObservationLine -TaskKey 'abcdef0123456789')
$crossResFile = Write-TestFile $crossDir 'resolver-20261101.jsonl' @($crossResLine)
$crossObsFile = Write-TestFile $crossDir 'observations-20261101.jsonl' @($crossObsLine)
$crossOne = Get-AdvisoryCollectorReport -ResolverPaths @($crossResFile) -ObservationPaths @($crossObsFile) -Limits @{ files = 1 }
Assert (@($crossOne.inputs.files).Count -eq 1) 'cap de arquivos e UM SO: 1 detalhe para 1 resolver + 1 observacao' ([string]@($crossOne.inputs.files).Count)
Assert (@($crossOne.inputs.files).Count -le [int]$crossOne.inputs.limits.files) 'detalhes de arquivo nunca passam do limite declarado' ([string]@($crossOne.inputs.files).Count)
Assert ([int]$crossOne.inputs.files_skipped_by_limit -eq 1) 'candidato cross-stream omitido e contado (nao havia cap por stream)' ([string]$crossOne.inputs.files_skipped_by_limit)
Assert ([int]$crossOne.inputs.candidate_paths_seen -eq 2) 'candidatos vistos somam os dois streams' ([string]$crossOne.inputs.candidate_paths_seen)
Assert ($crossOne.inputs.files[0].kind -ceq 'observation') 'vencedor ordinal e a observacao (nome menor), nao o stream do resolver' ($crossOne.inputs.files[0].kind)
Assert ([int]$crossOne.counts.observations_accepted -eq 1) 'stream vencedor produz seu registro'
Assert ([int]$crossOne.counts.resolver_records_valid -eq 0) 'stream omitido pelo cap compartilhado nao e lido'
# a selecao e ORDINAL, nao por stream: com nome menor, o resolver vence
$crossResLowFile = Write-TestFile $crossDir 'a-resolver-20261101.jsonl' @($crossResLine)
$crossResLow = Get-AdvisoryCollectorReport -ResolverPaths @($crossResLowFile) -ObservationPaths @($crossObsFile) -Limits @{ files = 1 }
Assert (@($crossResLow.inputs.files).Count -eq 1) 'cap compartilhado com outros nomes: 1 detalhe'
Assert ($crossResLow.inputs.files[0].kind -ceq 'resolver') 'vencedor ordinal e o resolver quando o nome e menor' ($crossResLow.inputs.files[0].kind)
Assert ([int]$crossResLow.counts.resolver_records_valid -eq 1) 'resolver vencedor produz seu registro'
Assert ([int]$crossResLow.counts.observations_accepted -eq 0) 'observacao omitida pelo cap compartilhado nao e lida'
Assert ([int]$crossResLow.inputs.files_skipped_by_limit -eq 1) 'omissao cross-stream contada tambem no sentido inverso'
# com cap folgado (padrao) os dois streams sao lidos: nenhuma regressao
$crossBoth = Get-AdvisoryCollectorReport -ResolverPaths @($crossResFile) -ObservationPaths @($crossObsFile)
Assert (@($crossBoth.inputs.files).Count -eq 2) 'sem cap apertado os dois streams aparecem'
Assert ([int]$crossBoth.inputs.files_skipped_by_limit -eq 0) 'sem omissao nao ha contagem de omissao'
# cap 2 com 4 candidatos (2 por stream): 2 detalhes, 2 omitidos, contagem exata
$crossTwoRes = Write-TestFile $crossDir 'q1-resolver-20261102.jsonl' @($crossResLine)
$crossTwoObs = Write-TestFile $crossDir 'q2-observations-20261102.jsonl' @($crossObsLine)
$crossCap2 = Get-AdvisoryCollectorReport -ResolverPaths @($crossResFile, $crossTwoRes) -ObservationPaths @($crossObsFile, $crossTwoObs) -Limits @{ files = 2 }
Assert (@($crossCap2.inputs.files).Count -eq 2) 'cap 2 compartilhado: 2 detalhes para 4 candidatos' ([string]@($crossCap2.inputs.files).Count)
Assert (@($crossCap2.inputs.files).Count -le [int]$crossCap2.inputs.limits.files) 'detalhes dentro do limite declarado (multiplos caminhos por stream)'
Assert ([int]$crossCap2.inputs.files_skipped_by_limit -eq 2) 'omitidos contados com precisao: 4 vistos, 2 retidos' ([string]$crossCap2.inputs.files_skipped_by_limit)
Assert ([int]$crossCap2.inputs.candidate_paths_seen -eq 4) 'candidatos vistos incluem os dois streams' ([string]$crossCap2.inputs.candidate_paths_seen)
$crossKinds = @()
foreach ($fe in @($crossCap2.inputs.files)) { $crossKinds += [string]$fe.kind }
Assert (@($crossKinds | Where-Object { $_ -ceq 'observation' }).Count -ge 1 -and @($crossKinds | Where-Object { $_ -ceq 'resolver' }).Count -ge 1) 'cap compartilhado nao privilegia stream: ordem ordinal pura mistura os dois' ($crossKinds -join ',')
# omitido que SERIA rejeitado tambem entra na contagem (omissao e previa ao IO)
$crossRefused = Get-AdvisoryCollectorReport -ResolverPaths @($crossResFile) -ObservationPaths @($crossObsFile) -Limits @{ files = 1 }
Assert ([int]$crossRefused.inputs.files_skipped_by_limit -eq 1) 'contagem de omitidos nao depende de o caminho ser legivel'
# cap 1 com candidato inexistente (menor ordinal): o RECUSADO e o selecionado e o
# omitido (arquivo real) tambem e contado - disclosure por contagem, nao por entrada
$crossGoneFile = Join-Path $crossDir 'aaa-resolver-20261103.jsonl'
$crossGoneReport = Get-AdvisoryCollectorReport -ResolverPaths @($crossGoneFile, $crossResFile) -Limits @{ files = 1 }
Assert (@($crossGoneReport.inputs.files).Count -eq 1) 'cap 1 com candidato inexistente: uma unica entrada de detalhe' ([string]@($crossGoneReport.inputs.files).Count)
Assert ($crossGoneReport.inputs.files[0].status -ceq 'refused' -and $crossGoneReport.inputs.files[0].reason -ceq 'NOT_A_FILE') 'candidato inexistente (menor ordinal) e o selecionado e nao passa da recusa'
Assert ([int]$crossGoneReport.inputs.files_skipped_by_limit -eq 1) 'arquivo real omitido pelo cap compartilhado e contado mesmo existindo' ([string]$crossGoneReport.inputs.files_skipped_by_limit)
Assert ([int]$crossGoneReport.counts.resolver_records_valid -eq 0) 'nenhum registro quando o selecionado e inexistente'
Assert (@($crossGoneReport.inputs.files).Count -le [int]$crossGoneReport.inputs.limits.files) 'detalhe continua dentro do limite declarado quando o selecionado e recusado'
# cap 1 e nenhum caminho legivel (todos ausentes, nos dois streams)
$crossAllGone = Get-AdvisoryCollectorReport -ResolverPaths @((Join-Path $crossDir 'zzz-resolver-20261103.jsonl')) -ObservationPaths @((Join-Path $crossDir 'zzz-observations-20261103.jsonl')) -Limits @{ files = 1 }
Assert (@($crossAllGone.inputs.files).Count -le 1) 'cap compartilhado vale tambem quando nada e legivel' ([string]@($crossAllGone.inputs.files).Count)
Assert ([int]$crossAllGone.inputs.files_skipped_by_limit -eq 1) 'omitido contado com caminhos ausentes nos dois streams' ([string]$crossAllGone.inputs.files_skipped_by_limit)
Assert ([int]$crossAllGone.inputs.candidate_paths_seen -eq 2) 'candidatos ausentes tambem foram vistos' ([string]$crossAllGone.inputs.candidate_paths_seen)
# mesmo caminho pedido nos DOIS streams: dois candidatos, um slot
$crossSame = Get-AdvisoryCollectorReport -ResolverPaths @($crossResFile) -ObservationPaths @($crossResFile) -Limits @{ files = 1 }
Assert (@($crossSame.inputs.files).Count -eq 1) 'mesmo caminho nos dois streams consome um slot do cap compartilhado'
Assert ([int]$crossSame.inputs.candidate_paths_seen -eq 2) 'candidatos vistos contam o par (path, kind) dos dois streams'
Assert ([int]$crossSame.inputs.files_skipped_by_limit -eq 1) 'a outra metade do par e omitida e contada'

# cap de linhas examinadas (vazias e malformadas incluidas) + omissao disclosed
$linesCapFile = Write-TestFile $telDir 'resolver-20261021.jsonl' @(
    (New-ResolverLine -TaskKey 'aaaaaaaaaaaaaaaa'),
    (New-ResolverLine -TaskKey 'bbbbbbbbbbbbbbbb')
)
$linesCapped = Get-AdvisoryCollectorReport -ResolverPaths @($linesCapFile) -Limits @{ file_lines = 1 }
Assert ([int]$linesCapped.counts.resolver_records_valid -eq 1) 'cap de linhas examinadas interrompe o arquivo' ([string]$linesCapped.counts.resolver_records_valid)
Assert ($linesCapped.inputs.lines_cap_reached) 'omissao por cap de linhas e disclosed'
Assert (@($linesCapped.inputs.files)[0].status -ceq 'truncated') 'arquivo truncado tem status truncated'
Assert (@($linesCapped.inputs.files)[0].reason -ceq 'LIMIT_EXCEEDED') 'arquivo truncado declara o motivo'
# a linha-sonda que revelou o cap foi LIDA e conta em lines_read (nunca fingir
# menos trabalho do que foi feito); ela nao e projetada (omitted)
Assert ([int]$linesCapped.counts.resolver_lines_read -eq 2) 'linha-sonda do cap de linhas conta como lida' ([string]$linesCapped.counts.resolver_lines_read)
Assert ([int]$linesCapped.counts.resolver_lines_omitted -eq 1) 'linha-sonda do cap nao e projetada' ([string]$linesCapped.counts.resolver_lines_omitted)
$linesNoCap = Get-AdvisoryCollectorReport -ResolverPaths @($linesCapFile)
Assert (-not $linesNoCap.inputs.lines_cap_reached) 'sem omissao por linhas o flag fica false'

# allowlist de capabilities indisponivel => fail-closed explicito
$noRegistry = New-TestDir 'sem-registry'
$noAllow = Get-AdvisoryCollectorReport -ResolverPaths @($capFile) -RepoRoot $noRegistry
Assert ($noAllow.collection_status -ceq 'FAILED_CLOSED') 'allowlist indisponivel nao passa em silencio' ($noAllow.collection_status)
Assert (@($noAllow.collection_failure_reasons) -ccontains 'CAPABILITY_ALLOWLIST_UNAVAILABLE') 'motivo CAPABILITY_ALLOWLIST_UNAVAILABLE'
Assert (-not $noAllow.inputs.capability_allowlist_loaded) 'inputs.capability_allowlist_loaded=false'
Assert ([int]$noAllow.counts.resolver_records_valid -eq 0) 'sem allowlist nenhum identificador e aceito'

$bigFile = Join-Path $telDir 'resolver-20261010.jsonl'
[IO.File]::WriteAllText($bigFile, ('{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"HIGH","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","pad":"' + ('x' * 60000) + '"}'), [Text.UTF8Encoding]::new($false))
$rBig = Get-AdvisoryCollectorReport -ResolverPaths @($bigFile)
Assert ([int]$rBig.counts.resolver_records_rejected -ge 1) 'linha oversized e rejeitada' ([string]$rBig.counts.resolver_records_rejected)
Assert (@($rBig.rejection_reasons.resolver.Keys) -ccontains 'OVERSIZED_ROW') 'motivo OVERSIZED_ROW'
Assert (-not ((ConvertTo-AdvisoryCollectorJson -Report $rBig -Depth 12).Contains('xxxxx'))) 'conteudo oversized nao vaza para o relatorio'

# ---- B. leitor limitado POR BYTES (cap efetivo, sem depender de tamanho) ------
$byteDir = New-TestDir 'bytestream'
function New-PaddedResolverLine {
    param([string]$TaskKey = 'abcdef0123456789', [int]$TotalBytes = 200)
    $base = '{"task_id":"' + $TaskKey + '","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"HIGH","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","pad":"'
    $tail = '"}'
    $need = [int]$TotalBytes - $base.Length - $tail.Length
    if ($need -lt 1) { $need = 1 }
    return ($base + ('x' * $need) + $tail)
}
# linha grande (> buffer de 4096) SEM terminador final: ultima linha do arquivo
$longNoEol = New-PaddedResolverLine -TaskKey 'aaaaaaaaaaaaaaaa' -TotalBytes 5000
$longFile = Join-Path $byteDir 'resolver-20261070.jsonl'
[IO.File]::WriteAllText($longFile, $longNoEol, [Text.UTF8Encoding]::new($false))
$rLong = Get-AdvisoryCollectorReport -ResolverPaths @($longFile)
Assert ([int]$rLong.counts.resolver_records_valid -eq 1) 'ultima linha sem terminador ainda e lida' ([string]$rLong.counts.resolver_records_valid)
Assert (@($rLong.inputs.files)[0].status -ceq 'read') 'arquivo com linha longa completa sem truncamento'
Assert ([int64]@($rLong.inputs.files)[0].bytes -ge 5000) 'bytes examinados refletem a linha grande realmente lida' ([string]@($rLong.inputs.files)[0].bytes)

# linha grande acima do cap, sem terminador: rejeitada sem materializar
$hugeNoEol = New-PaddedResolverLine -TaskKey 'bbbbbbbbbbbbbbbb' -TotalBytes 200000
$hugeFile = Join-Path $byteDir 'resolver-20261071.jsonl'
[IO.File]::WriteAllText($hugeFile, $hugeNoEol, [Text.UTF8Encoding]::new($false))
$swHuge = [System.Diagnostics.Stopwatch]::StartNew()
$rHuge = Get-AdvisoryCollectorReport -ResolverPaths @($hugeFile) -Limits @{ line_bytes = 1024 }
$swHuge.Stop()
Assert ([int]$rHuge.counts.resolver_records_valid -eq 0) 'linha acima de line_bytes nao produz registro' ([string]$rHuge.counts.resolver_records_valid)
Assert ([int]$rHuge.counts.resolver_records_rejected -eq 1) 'linha acima do cap e rejeitada uma vez'
Assert ([int]$rHuge.rejection_reasons.resolver.OVERSIZED_ROW -eq 1) 'motivo OVERSIZED_ROW para linha sem terminador acima do cap'
Assert ($swHuge.ElapsedMilliseconds -lt 60000) 'linha gigante sem terminador nao estoura o tempo (margem generosa)' ("$($swHuge.ElapsedMilliseconds)ms")
Assert (-not ((ConvertTo-AdvisoryCollectorJson -Report $rHuge -Depth 12).Contains('xxxxx'))) 'conteudo da linha acima do cap nao vaza'

# fronteira exata do cap: N bytes passa, N+1 rejeita
$boundaryPath = Join-Path $byteDir 'resolver-20261072.jsonl'
$fitLine = New-PaddedResolverLine -TaskKey 'cccccccccccccccc' -TotalBytes 240
$overLine = New-PaddedResolverLine -TaskKey 'dddddddddddddddd' -TotalBytes 241
Assert ($overLine.Length -eq ($fitLine.Length + 1)) 'fixtures de fronteira diferem em exatamente 1 byte' ([string]$fitLine.Length + '/' + [string]$overLine.Length)
[IO.File]::WriteAllText($boundaryPath, ($fitLine + "`r`n" + $overLine + "`r`n"), [Text.UTF8Encoding]::new($false))
$rBoundary = Get-AdvisoryCollectorReport -ResolverPaths @($boundaryPath) -Limits @{ line_bytes = $fitLine.Length }
Assert ([int]$rBoundary.counts.resolver_records_valid -eq 1) 'linha com exatamente line_bytes bytes e aceita' ([string]$rBoundary.counts.resolver_records_valid)
Assert ([int]$rBoundary.rejection_reasons.resolver.OVERSIZED_ROW -eq 1) 'linha com line_bytes+1 bytes e rejeitada' ([string]$rBoundary.rejection_reasons.resolver.OVERSIZED_ROW)

# terminador CRLF quebrado entre dois blocos de leitura (4095 + CRLF)
$crlfPath = Join-Path $byteDir 'resolver-20261077.jsonl'
$crlfA = New-PaddedResolverLine -TaskKey 'eeeeeeeeeeeeeeee' -TotalBytes 4095
$crlfB = New-PaddedResolverLine -TaskKey 'ffffffffffffffff' -TotalBytes 200
[IO.File]::WriteAllText($crlfPath, ($crlfA + "`r`n" + $crlfB + "`r`n"), [Text.UTF8Encoding]::new($false))
$rCrlf = Get-AdvisoryCollectorReport -ResolverPaths @($crlfPath)
Assert ([int]$rCrlf.counts.resolver_records_valid -eq 2) 'CRLF na fronteira do buffer nao corrompe as linhas' ([string]$rCrlf.counts.resolver_records_valid)
Assert ([int]$rCrlf.counts.resolver_lines_read -eq 2) 'duas linhas examinadas com terminador quebrado' ([string]$rCrlf.counts.resolver_lines_read)

# orcamento de bytes: arquivo grande e truncado, e o tamanho reportado e o que
# foi realmente examinado (nunca o tamanho do arquivo lido antes/guardado)
$threeRows = @(
    (New-PaddedResolverLine -TaskKey '1111111111111111' -TotalBytes 260),
    (New-PaddedResolverLine -TaskKey '2222222222222222' -TotalBytes 260),
    (New-PaddedResolverLine -TaskKey '3333333333333333' -TotalBytes 260)
)
$fullPath = Join-Path $byteDir 'resolver-20261073.jsonl'
[IO.File]::WriteAllText($fullPath, (@($threeRows) -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
$fullSize = [long]((Get-Item -LiteralPath $fullPath -Force).Length)
Assert ($fullSize -gt 700) 'fixture de orcamento tem arquivo maior que o orcamento' ([string]$fullSize)
$rBudget = Get-AdvisoryCollectorReport -ResolverPaths @($fullPath) -Limits @{ total_bytes = 200 }
Assert (@($rBudget.inputs.files)[0].status -ceq 'truncated') 'orcamento de bytes estoura => status truncated'
Assert (@($rBudget.inputs.files)[0].reason -ceq 'LIMIT_EXCEEDED') 'motivo LIMIT_EXCEEDED no arquivo truncado por bytes'
Assert ([int64]@($rBudget.inputs.files)[0].bytes -lt $fullSize) 'bytes reportados sao os examinados, nao o tamanho total do arquivo' ([string]@($rBudget.inputs.files)[0].bytes)
Assert ([int64]@($rBudget.inputs.files)[0].bytes -gt 0) 'houve exame real de bytes antes do cap' ([string]@($rBudget.inputs.files)[0].bytes)
Assert ([int64]$rBudget.inputs.bytes_examined_total -lt $fullSize) 'total examinado tambem nao usa tamanho pre-lido' ([string]$rBudget.inputs.bytes_examined_total)
Assert ($rBudget.inputs.bytes_cap_reached) 'esgotamento do orcamento e sinalizado (bytes_cap_reached)'
Assert ([int]$rBudget.inputs.bytes_examined_total -le 200) 'orcamento nunca e estourado no total' ([string]$rBudget.inputs.bytes_examined_total)

# orcamento de bytes COMPARTILHADO entre arquivos: o segundo arquivo so recebe
# o que resta - cada arquivo NAO ganha o cap cheio
$sharedA = Join-Path $byteDir 'resolver-20261078.jsonl'
$sharedB = Join-Path $byteDir 'resolver-20261079.jsonl'
$rowAB = New-PaddedResolverLine -TaskKey '1212121212121212' -TotalBytes 200
$rowSize = [int64]([Text.Encoding]::UTF8.GetByteCount($rowAB))
$fileSize = (($rowSize + 2) * 2)
[IO.File]::WriteAllText($sharedA, ($rowAB + "`r`n" + $rowAB + "`r`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($sharedB, ($rowAB + "`r`n" + $rowAB + "`r`n"), [Text.UTF8Encoding]::new($false))
$sharedBudget = $fileSize + 100
$rSharedBudget = Get-AdvisoryCollectorReport -ResolverPaths @($sharedA, $sharedB) -Limits @{ total_bytes = $sharedBudget }
$sharedFiles = @($rSharedBudget.inputs.files)
Assert (@($sharedFiles).Count -eq 2) 'dois arquivos candidatos no relatorio'
Assert ($sharedFiles[0].status -ceq 'read') 'primeiro arquivo le dentro do que resta do orcamento'
Assert ([int64]$sharedFiles[0].bytes -eq $fileSize) 'primeiro arquivo consome exatamente o que leu' ([string]$sharedFiles[0].bytes)
Assert ($sharedFiles[1].status -ceq 'truncated') 'segundo arquivo recebe apenas o resto do orcamento'
Assert ([int64]$sharedFiles[1].bytes -eq 100) 'segundo arquivo le so os bytes restantes do orcamento compartilhado' ([string]$sharedFiles[1].bytes)
Assert ([int64]$rSharedBudget.inputs.bytes_examined_total -eq $sharedBudget) 'soma examinada = orcamento compartilhado (nunca o dobro do cap)' ([string]$rSharedBudget.inputs.bytes_examined_total)
Assert ($rSharedBudget.inputs.bytes_cap_reached) 'orcamento compartilhado esgotado e sinalizado'
# esgotado ANTES do segundo arquivo: ele nao e lido e a omissao fica explicita
$rNoBudget = Get-AdvisoryCollectorReport -ResolverPaths @($sharedA, $sharedB) -Limits @{ total_bytes = $fileSize }
Assert ($rNoBudget.inputs.files[1].status -ceq 'truncated') 'arquivo sem orcamento restante nao e lido'
Assert ([int64]$rNoBudget.inputs.files[1].bytes -eq 0) 'nenhum byte examinado sem orcamento'
Assert ($rNoBudget.inputs.bytes_cap_reached) 'esgotamento total sinalizado mesmo sem leitura parcial'

# orcamento COMPARTILHADO tambem entre os dois streams: se o resolver come o
# orcamento, a observacao e truncada e disclosure aparece com kind proprio
$obsBudgetLine = '{"provenance":"supplied","task_key":"abcdef0123456789","task_class":"review","claimed_agent":"reviewer"}'
$obsBudgetFile = Join-Path $byteDir 'observations-20261078.jsonl'
[IO.File]::WriteAllText($obsBudgetFile, ($obsBudgetLine + "`r`n" + $obsBudgetLine + "`r`n"), [Text.UTF8Encoding]::new($false))
$streamBudget = $fileSize + 40
$rStreamBudget = Get-AdvisoryCollectorReport -ResolverPaths @($sharedA) -ObservationPaths @($obsBudgetFile) -Limits @{ total_bytes = $streamBudget }
$streamFiles = @($rStreamBudget.inputs.files)
$resBudgetEntry = @($streamFiles | Where-Object { $_.kind -ceq 'resolver' })
$obsBudgetEntry = @($streamFiles | Where-Object { $_.kind -ceq 'observation' })
Assert (@($resBudgetEntry).Count -eq 1 -and $resBudgetEntry[0].status -ceq 'read') 'resolver le dentro do orcamento compartilhado'
Assert ([int64]$resBudgetEntry[0].bytes -eq $fileSize) 'resolver consome o que leu, nao o cap cheio' ([string]$resBudgetEntry[0].bytes)
Assert (@($obsBudgetEntry).Count -eq 1 -and $obsBudgetEntry[0].status -ceq 'truncated') 'observacao truncada pelo mesmo orcamento compartilhado'
Assert ([int64]$obsBudgetEntry[0].bytes -eq 40) 'observacao so recebe o resto do orcamento' ([string]$obsBudgetEntry[0].bytes)
Assert ([int64]$rStreamBudget.inputs.bytes_examined_total -eq $streamBudget) 'orcamento e um so para os dois streams' ([string]$rStreamBudget.inputs.bytes_examined_total)
Assert ([int]$rStreamBudget.counts.observations_accepted -eq 0) 'sem orcamento nao ha observacao aceita'
Assert ([int]$rStreamBudget.counts.observations_accepted -eq 0) 'sem orcamento nao ha observacao aceita'

# ---- fronteira EXATA do orcamento de bytes ---------------------------------
# EOF no ultimo byte do orcamento NAO e truncamento: a linha final do arquivo
# esta completa e precisa ser aceita. So ha truncamento quando existem bytes
# ALEM do orcamento. Sem distinguir os dois casos, uma linha valida de exatamente
# total_bytes (com ou sem terminador) era descartada como LIMIT_EXCEEDED - falso
# truncation que escondia um registro real do relatorio.
$boundDir = New-TestDir 'byteboundary'
$boundaryRow = New-PaddedResolverLine -TaskKey 'aaaaaaaaaaaaaaaa' -TotalBytes 300
$boundaryBytes = [int64]([Text.Encoding]::UTF8.GetByteCount($boundaryRow))
Assert ($boundaryBytes -eq 300) 'fixture de fronteira tem exatamente 300 bytes' ("$boundaryBytes")
# (a) linha valida de EXATAMENTE total_bytes, SEM terminador final
$exactNoEol = Join-Path $boundDir 'resolver-20261110.jsonl'
[IO.File]::WriteAllText($exactNoEol, $boundaryRow, [Text.UTF8Encoding]::new($false))
$rExactNoEol = Get-AdvisoryCollectorReport -ResolverPaths @($exactNoEol) -Limits @{ total_bytes = $boundaryBytes }
Assert ([int]$rExactNoEol.counts.resolver_records_valid -eq 1) 'linha final com exatamente total_bytes e sem LF e aceita' ([string]$rExactNoEol.counts.resolver_records_valid)
Assert (@($rExactNoEol.inputs.files)[0].status -ceq 'read') 'sem bytes alem do orcamento nao ha truncated'
Assert (@($rExactNoEol.inputs.files)[0].reason -ceq '') 'motivo vazio quando nao ha omissao'
Assert (-not $rExactNoEol.inputs.bytes_cap_reached) 'EOF exato no orcamento nao sinaliza bytes_cap_reached'
Assert ([int64]$rExactNoEol.inputs.bytes_examined_total -eq $boundaryBytes) 'bytes examinados = orcamento exato' ([string]$rExactNoEol.inputs.bytes_examined_total)
Assert ([int]$rExactNoEol.counts.resolver_lines_read -eq 1) 'linha unica lida (sem linha fantasma no EOF)'
Assert ([int]$rExactNoEol.counts.resolver_lines_omitted -eq 0) 'nada omitido no EOF exato'
# (b) LF depois da linha: orcamento exato = conteudo + 1
$exactLf = Join-Path $boundDir 'resolver-20261111.jsonl'
[IO.File]::WriteAllText($exactLf, ($boundaryRow + "`n"), [Text.UTF8Encoding]::new($false))
$rExactLf = Get-AdvisoryCollectorReport -ResolverPaths @($exactLf) -Limits @{ total_bytes = ($boundaryBytes + 1) }
Assert ([int]$rExactLf.counts.resolver_records_valid -eq 1) 'linha + LF com orcamento exato e aceita' ([string]$rExactLf.counts.resolver_records_valid)
Assert (@($rExactLf.inputs.files)[0].status -ceq 'read') 'LF no fim do orcamento nao gera truncated'
Assert (-not $rExactLf.inputs.bytes_cap_reached) 'LF dentro do orcamento: sem bytes_cap_reached'
Assert ([int64]$rExactLf.inputs.bytes_examined_total -eq ($boundaryBytes + 1)) 'bytes examinados incluem o LF final'
Assert ([int]$rExactLf.counts.resolver_lines_read -eq 1) 'linha unica (o LF nao cria segunda linha)'
# (c) CRLF depois da linha: orcamento exato = conteudo + 2
$exactCrlf = Join-Path $boundDir 'resolver-20261112.jsonl'
[IO.File]::WriteAllText($exactCrlf, ($boundaryRow + "`r`n"), [Text.UTF8Encoding]::new($false))
$rExactCrlf = Get-AdvisoryCollectorReport -ResolverPaths @($exactCrlf) -Limits @{ total_bytes = ($boundaryBytes + 2) }
Assert ([int]$rExactCrlf.counts.resolver_records_valid -eq 1) 'linha + CRLF com orcamento exato e aceita' ([string]$rExactCrlf.counts.resolver_records_valid)
Assert (@($rExactCrlf.inputs.files)[0].status -ceq 'read') 'CRLF no fim do orcamento nao gera truncated'
Assert (-not $rExactCrlf.inputs.bytes_cap_reached) 'CRLF dentro do orcamento: sem bytes_cap_reached'
Assert ([int64]$rExactCrlf.inputs.bytes_examined_total -eq ($boundaryBytes + 2)) 'bytes examinados incluem o CRLF final'
# (d) cap + 1 byte de conteudo (sem terminador): truncamento REAL e disclosed
$overRow = New-PaddedResolverLine -TaskKey 'bbbbbbbbbbbbbbbb' -TotalBytes 301
$overBytes = [int64]([Text.Encoding]::UTF8.GetByteCount($overRow))
$overNoEol = Join-Path $boundDir 'resolver-20261113.jsonl'
[IO.File]::WriteAllText($overNoEol, $overRow, [Text.UTF8Encoding]::new($false))
$rOver = Get-AdvisoryCollectorReport -ResolverPaths @($overNoEol) -Limits @{ total_bytes = $boundaryBytes }
Assert ($overBytes -eq ($boundaryBytes + 1)) 'fixture cap+1 tem exatamente um byte acima do orcamento' ("$overBytes")
Assert ([int]$rOver.counts.resolver_records_valid -eq 0) 'cap+1 descarta a linha incompleta (nunca projetada)'
Assert (@($rOver.inputs.files)[0].status -ceq 'truncated' -and @($rOver.inputs.files)[0].reason -ceq 'LIMIT_EXCEEDED') 'cap+1 disclosed como truncated/LIMIT_EXCEEDED'
Assert ($rOver.inputs.bytes_cap_reached) 'cap+1 sinaliza bytes_cap_reached'
Assert ([int64]$rOver.inputs.bytes_examined_total -le $boundaryBytes) 'orcamento nunca estourado com cap+1' ([string]$rOver.inputs.bytes_examined_total)
Assert ([int]$rOver.counts.resolver_lines_read -eq 1) 'linha parcial cortada pelo orcamento conta como lida' ([string]$rOver.counts.resolver_lines_read)
Assert ([int]$rOver.counts.resolver_lines_omitted -eq 1) 'linha parcial cortada conta como omitida' ([string]$rOver.counts.resolver_lines_omitted)
# (e) linha completa dentro do orcamento + 1 byte ALEM dele: a linha e aceita e o
#     byte extra fica disclosed, sem linha fantasma
$extraTail = Join-Path $boundDir 'resolver-20261114.jsonl'
[IO.File]::WriteAllText($extraTail, ($boundaryRow + "`n" + "x"), [Text.UTF8Encoding]::new($false))
$rExtraTail = Get-AdvisoryCollectorReport -ResolverPaths @($extraTail) -Limits @{ total_bytes = ($boundaryBytes + 1) }
Assert ([int]$rExtraTail.counts.resolver_records_valid -eq 1) 'linha completa antes do fim do orcamento e aceita' ([string]$rExtraTail.counts.resolver_records_valid)
Assert (@($rExtraTail.inputs.files)[0].status -ceq 'truncated') 'byte alem do orcamento disclosed como truncated'
Assert ($rExtraTail.inputs.bytes_cap_reached) 'byte alem do orcamento sinaliza bytes_cap_reached'
Assert ([int64]$rExtraTail.inputs.bytes_examined_total -eq ($boundaryBytes + 1)) 'bytes examinados param exatamente no orcamento' ([string]$rExtraTail.inputs.bytes_examined_total)
Assert ([int]$rExtraTail.counts.resolver_lines_read -eq 1) 'sem linha fantasma: so a linha completa foi lida' ([string]$rExtraTail.counts.resolver_lines_read)
Assert ([int]$rExtraTail.counts.resolver_lines_omitted -eq 0) 'byte nao lido nao infla lines_omitted' ([string]$rExtraTail.counts.resolver_lines_omitted)
# (f) tres linhas, orcamento que cobre a primeira linha inteira e so o conteudo
#     da segunda (sem o LF): a primeira e aceita, a segunda fica truncated
$midRows = @(
    (New-PaddedResolverLine -TaskKey '1111111111111111' -TotalBytes 200),
    (New-PaddedResolverLine -TaskKey '2222222222222222' -TotalBytes 200),
    (New-PaddedResolverLine -TaskKey '3333333333333333' -TotalBytes 200)
)
$midFile = Join-Path $boundDir 'resolver-20261115.jsonl'
[IO.File]::WriteAllText($midFile, ($midRows[0] + "`n" + $midRows[1] + "`n" + $midRows[2] + "`n"), [Text.UTF8Encoding]::new($false))
$midBudget = 201 + 200
$rMid = Get-AdvisoryCollectorReport -ResolverPaths @($midFile) -Limits @{ total_bytes = $midBudget }
Assert ([int]$rMid.counts.resolver_records_valid -eq 1) 'primeira linha inteira (com LF) aceita no orcamento' ([string]$rMid.counts.resolver_records_valid)
Assert (@($rMid.inputs.files)[0].status -ceq 'truncated') 'segunda linha incompleta => truncated' (@($rMid.inputs.files)[0].status)
Assert ([int64]$rMid.inputs.bytes_examined_total -eq $midBudget) 'orcamento consumido exatamente (sem estouro)' ([string]$rMid.inputs.bytes_examined_total)
Assert ([int]$rMid.counts.resolver_lines_read -eq 2) 'linha completa + linha parcial cortada pelo orcamento' ([string]$rMid.counts.resolver_lines_read)
Assert ([int]$rMid.counts.resolver_lines_omitted -eq 1) 'linha parcial omitida e contada' ([string]$rMid.counts.resolver_lines_omitted)

# UTF-8 invalido: falha fechada (linha rejeitada, nunca aceita com replacement)
$badUtf8Path = Join-Path $byteDir 'resolver-20261074.jsonl'
$goodBytes = [Text.Encoding]::UTF8.GetBytes((New-ResolverLine -TaskKey 'abcdef0123456789') + "`r`n")
$badRow = '{"task_id":"fedcba9876543210","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","pad":"'
$badBytes = [Text.Encoding]::UTF8.GetBytes($badRow)
$ffBytes = [byte[]]@(0xFF, 0xFF, 0x22, 0x7D, 0x0D, 0x0A)
$mem = New-Object System.IO.MemoryStream
$mem.Write($goodBytes, 0, $goodBytes.Length)
$mem.Write($badBytes, 0, $badBytes.Length)
$mem.Write($ffBytes, 0, $ffBytes.Length)
[IO.File]::WriteAllBytes($badUtf8Path, $mem.ToArray())
$mem.Dispose()
$rBadUtf8 = Get-AdvisoryCollectorReport -ResolverPaths @($badUtf8Path)
Assert ([int]$rBadUtf8.counts.resolver_records_valid -eq 1) 'linha UTF-8 valida e aceita ao lado da invalida' ([string]$rBadUtf8.counts.resolver_records_valid)
Assert ([int]$rBadUtf8.counts.resolver_records_rejected -eq 1) 'linha com UTF-8 invalido e rejeitada (falha fechada)' ([string]$rBadUtf8.counts.resolver_records_rejected)
Assert ([int]$rBadUtf8.rejection_reasons.resolver.MALFORMED_JSON -eq 1) 'motivo MALFORMED_JSON para decodificacao invalida'

# BOM UTF-8 no inicio do arquivo nao corrompe a primeira linha
$bomPath = Join-Path $byteDir 'resolver-20261075.jsonl'
$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
$rowBytes = [Text.Encoding]::UTF8.GetBytes((New-ResolverLine -TaskKey 'abcdef0123456789') + "`r`n")
$mem2 = New-Object System.IO.MemoryStream
$mem2.Write($bom, 0, $bom.Length)
$mem2.Write($rowBytes, 0, $rowBytes.Length)
[IO.File]::WriteAllBytes($bomPath, $mem2.ToArray())
$mem2.Dispose()
$rBom = Get-AdvisoryCollectorReport -ResolverPaths @($bomPath)
Assert ([int]$rBom.counts.resolver_records_valid -eq 1) 'BOM UTF-8 e tratado (primeira linha valida)' ([string]$rBom.counts.resolver_records_valid)

# escrita concorrente impede a leitura (fail-closed) onde a plataforma suporta
$sharedPath = Join-Path $byteDir 'resolver-20261076.jsonl'
[IO.File]::WriteAllText($sharedPath, (New-ResolverLine -TaskKey 'abcdef0123456789'), [Text.UTF8Encoding]::new($false))
$onWindows = ($env:OS -ceq 'Windows_NT')
$writer = $null
$openedWriter = $false
if ($onWindows) {
    try {
        $writer = [IO.File]::Open($sharedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        $openedWriter = $true
    }
    catch { $openedWriter = $false }
}
if ($onWindows -and $openedWriter) {
    $rShared = Get-AdvisoryCollectorReport -ResolverPaths @($sharedPath)
    Assert ($rShared.collection_status -ceq 'FAILED_CLOSED') 'escritor concorrente impede a abertura => FAILED_CLOSED' ($rShared.collection_status)
    Assert (@($rShared.collection_failure_reasons) -ccontains 'READ_FAILED') 'motivo READ_FAILED para escrita concorrente'
    Assert ([int]$rShared.counts.resolver_records_valid -eq 0) 'arquivo em escrita concorrente nao produz registro'
    try { $writer.Dispose() } catch { }
    $rAfterClose = Get-AdvisoryCollectorReport -ResolverPaths @($sharedPath)
    Assert ([int]$rAfterClose.counts.resolver_records_valid -eq 1) 'fechado o escritor, a leitura volta a funcionar' ([string]$rAfterClose.counts.resolver_records_valid)
}
elseif ($onWindows) {
    Skip-That 'escritor concorrente impede a abertura' 'abertura de escrita concorrente indisponivel neste host'
}
else {
    Skip-That 'escritor concorrente impede a abertura' 'plataforma sem share mode enforced (somente Windows)'
}

# ---- C. validacao estrita das linhas do resolver ----------------------------
$caseDir = New-TestDir 'cases'
$goodKey = 'abcdef0123456789'
$mixLines = @(
    (New-ResolverLine -TaskKey $goodKey),
    (New-ResolverLine -TaskKey $goodKey),
    (New-ResolverLine -TaskKey '2G-IMPLEMENT-01'),
    (New-ResolverLine -TaskKey '0123456789abcdef' -TaskClass 'not-a-class'),
    (New-ResolverLine -TaskKey 'fedcba9876543210' -TaskClass 'implementation' -Risk 'SEVERE'),
    (New-ResolverLine -TaskKey 'fedcba9876543211' -TaskClass 'implementation' -Confidence 'MAYBE'),
    (New-ResolverLine -TaskKey 'fedcba9876543212' -TaskClass 'implementation' -Mode 'active'),
    (New-ResolverLine -TaskKey 'fedcba9876543213' -TaskClass 'implementation' -At 'not-a-timestamp'),
    (New-ResolverLine -TaskKey 'fedcba9876543214' -TaskClass 'implementation' -Agents @('reviewer', 'coder', 'debugger', 'architect', 'tester', 'docs-manager', 'frontend-engineer', 'backend-engineer', 'database-engineer', 'ai-agent-engineer', 'automation-engineer', 'infra-engineer', 'planner', 'planner-2', 'planner-3', 'planner-4', 'planner-5')),
    (New-ResolverLine -TaskKey 'fedcba9876543215' -TaskClass 'implementation' -Agents @('has space', 'ok-agent')),
    (New-ResolverLine -TaskKey 'fedcba9876543217' -TaskClass 'implementation' -Agents @('sk-SYNTHETICSECRET')),
    '{"task_id":"fedcba9876543216","task_class":"implementation" "profiles":[]}',
    'not-json-at-all',
    '',
    '["array","not","object"]',
    '42',
    '"scalar"',
    '[{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}]',
    '[{"task_id":"1234567890abcdef","task_class":"review"},{"task_id":"fedcba0987654321","task_class":"review"}]',
    '  [{"task_id":"abcdef0123456789","task_class":"review"}]  ',
    '{"task_id":1234567890123456,"task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}',
    '{"task_id":"abcdef0123456789","task_id":"2222222222222222","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}'
)
$mixFile = Write-TestFile $caseDir 'resolver-20261009.jsonl' $mixLines
$rMix = Get-AdvisoryCollectorReport -ResolverPaths @($mixFile)
$rejKeys = @($rMix.rejection_reasons.resolver.Keys)
Assert ([int]$rMix.counts.resolver_records_valid -eq 2) 'apenas 2 linhas validas no cenario misto' ([string]$rMix.counts.resolver_records_valid)
Assert ($rejKeys -ccontains 'INVALID_TASK_KEY_FORMAT') 'task_id literal antigo rejeitado (nao consertado)' ($rejKeys -join ',')
Assert ($rejKeys -ccontains 'INVALID_TASK_CLASS') 'task_class fora do enum rejeitado'
Assert ($rejKeys -ccontains 'INVALID_RISK') 'risk fora do enum rejeitado'
Assert ($rejKeys -ccontains 'INVALID_CONFIDENCE') 'confidence fora do enum rejeitado'
Assert ($rejKeys -ccontains 'INVALID_MODE') 'mode diferente de shadow rejeitado'
Assert ($rejKeys -ccontains 'INVALID_TIMESTAMP') 'timestamp invalido rejeitado'
Assert ($rejKeys -ccontains 'OVERSIZED_ARRAY') 'array acima do limite rejeitado'
Assert ($rejKeys -ccontains 'INVALID_IDENTIFIER') 'identificador com espaco rejeitado'
Assert ($rejKeys -ccontains 'MALFORMED_JSON') 'JSON malformado rejeitado'
Assert ($rejKeys -ccontains 'NOT_AN_OBJECT') 'linha que nao e objeto rejeitada'
Assert ([int]$rMix.rejection_reasons.resolver.NOT_AN_OBJECT -ge 5) 'raiz nao-objeto: array de N, array de 1 objeto, numero e string' ([string]$rMix.rejection_reasons.resolver.NOT_AN_OBJECT)
Assert ($rejKeys -ccontains 'EMPTY_ROW') 'linha vazia rejeitada'
Assert ($rejKeys -ccontains 'DUPLICATE_KEY') 'nome de campo lido repetido na linha e rejeitado'
Assert ([int]$rMix.counts.resolver_records_rejected -eq ([int]($mixLines.Count) - 2)) 'contagem de rejeitados fecha com o total de linhas' ([string]$rMix.counts.resolver_records_rejected)
Assert ([int]$rMix.counts.resolver_lines_read -eq [int]($mixLines.Count)) 'linhas lidas contam examinadas (validas + rejeitadas)' ([string]$rMix.counts.resolver_lines_read)

# ---- C1. raiz JSON: array singleton NAO e objeto (PS 5.1 e PS 7) -------------
$validObjLine = (New-ResolverLine -TaskKey 'abcdef0123456789')
$singletonArray = '[' + $validObjLine + ']'
$rootLines = @(
    $singletonArray,
    ('  ' + $singletonArray + '  '),
    ('[' + $validObjLine + ',' + (New-ResolverLine -TaskKey '1234567890abcdef') + ']'),
    '42',
    'true',
    '"scalar"',
    'null',
    $validObjLine
)
$rootFile = Write-TestFile $caseDir 'resolver-20261060.jsonl' $rootLines
$rRoot = Get-AdvisoryCollectorReport -ResolverPaths @($rootFile)
Assert ([int]$rRoot.counts.resolver_records_valid -eq 1) 'somente a linha-objeto e aceita; array singleton nao passa' ([string]$rRoot.counts.resolver_records_valid)
Assert ([int]$rRoot.counts.resolver_records_rejected -eq 7) 'as 7 linhas de raiz nao-objeto sao rejeitadas' ([string]$rRoot.counts.resolver_records_rejected)
Assert (@($rRoot.rejection_reasons.resolver.Keys) -ccontains 'NOT_AN_OBJECT') 'motivo NOT_AN_OBJECT para raiz nao-objeto'
Assert ([int]$rRoot.rejection_reasons.resolver.NOT_AN_OBJECT -eq 7) 'todas as raizes nao-objeto caem em NOT_AN_OBJECT (nada de MALFORMED_JSON)' ([string]$rRoot.rejection_reasons.resolver.NOT_AN_OBJECT)
$rootJson = ConvertTo-AdvisoryCollectorJson -Report $rRoot -Depth 12
Assert (-not $rootJson.Contains('1234567890abcdef')) 'conteudo do array singleton nao vaza para o relatorio'
$soloArrayFile = Write-TestFile $caseDir 'resolver-20261061.jsonl' @($singletonArray)
$rSoloArray = Get-AdvisoryCollectorReport -ResolverPaths @($soloArrayFile)
Assert ([int]$rSoloArray.counts.resolver_records_valid -eq 0) 'arquivo so com array singleton nao produz registro valido' ([string]$rSoloArray.counts.resolver_records_valid)
Assert ($rSoloArray.evaluation_status -ceq 'UNAVAILABLE') 'array singleton sozinho => UNAVAILABLE' ($rSoloArray.evaluation_status)

# ---- C2. duplicata com escape JSON (task_id vs task\u005fid) ------------------
$escDupLine = '{"task_id":"abcdef0123456789","task\u005fid":"2222222222222222","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}'
$escDupFile = Write-TestFile $caseDir 'resolver-20261062.jsonl' @($escDupLine)
$rEscDup = Get-AdvisoryCollectorReport -ResolverPaths @($escDupFile)
Assert ([int]$rEscDup.counts.resolver_records_valid -eq 0) 'task_id repetido via escape JSON e rejeitado' ([string]$rEscDup.counts.resolver_records_valid)
Assert (@($rEscDup.rejection_reasons.resolver.Keys) -ccontains 'DUPLICATE_KEY') 'motivo DUPLICATE_KEY para repeticao escapada'
Assert ([int]$rEscDup.counts.observations_accepted -eq 0) 'nada de observacao no cenario de resolver'
$escEscapedFile = Write-TestFile $caseDir 'resolver-20261063.jsonl' @(
    '{"task_id":"abcdef0123456789","task_id":"2222222222222222","task_class":"review"}',
    '{"\u0074ask_id":"abcdef0123456789","task\u005fid":"2222222222222222","task_class":"review"}',
    '{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","zz\u007a":1}'
)
$rEscEscaped = Get-AdvisoryCollectorReport -ResolverPaths @($escEscapedFile)
Assert ([int]$rEscEscaped.counts.resolver_records_valid -eq 1) 'chave desconhecida escapada nao invalida a linha' ([string]$rEscEscaped.counts.resolver_records_valid)
Assert ([int]$rEscEscaped.rejection_reasons.resolver.DUPLICATE_KEY -eq 2) 'literal, \u0074 e \u005f sao a mesma chave task_id (duas linhas rejeitadas)' ([string]$rEscEscaped.rejection_reasons.resolver.DUPLICATE_KEY)
Assert ([int]$rEscEscaped.inputs.dropped_input_keys_count -eq 1) 'chave desconhecida escapada continua sendo so contada'
$obsEscDupFile = Write-TestFile $caseDir 'observations-20261064.jsonl' @('{"provenance":"supplied","task_key":"abcdef0123456789","task\u005fkey":"2222222222222222","claimed_agent":"reviewer"}')
$rObsEscDup = Get-AdvisoryCollectorReport -ObservationPaths @($obsEscDupFile)
Assert ([int]$rObsEscDup.counts.observations_accepted -eq 0) 'escape duplicado tambem rejeita no stream de observacao'
Assert (@($rObsEscDup.rejection_reasons.observation.Keys) -ccontains 'DUPLICATE_KEY') 'motivo DUPLICATE_KEY tambem na observacao'
# politica explicita de duplicata aninhada: fail-closed em qualquer profundidade
$nestedEscDupFile = Write-TestFile $caseDir 'resolver-20261065.jsonl' @('{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","meta":{"task\u005fid":"2222222222222222"}}')
$rNestedEscDup = Get-AdvisoryCollectorReport -ResolverPaths @($nestedEscDupFile)
Assert ([int]$rNestedEscDup.counts.resolver_records_valid -eq 0) 'duplicata escapada em objeto aninhado rejeita a linha (fail-closed)' ([string]$rNestedEscDup.counts.resolver_records_valid)
Assert (@($rNestedEscDup.rejection_reasons.resolver.Keys) -ccontains 'DUPLICATE_KEY') 'motivo DUPLICATE_KEY para repeticao aninhada escapada'

# fixture ADVERSARIA: milhares de aspas escapadas dentro de um valor de string.
# O detector e um scanner lexical de passada unica (sem regex): custo O(n) no
# tamanho da linha, sem backtracking. Uma regex de captura de chave poderia
# backtreackar em cadeias longas - este teste trava o tempo e o resultado.
$advQuotes = 4000
$advValidBody = '{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","pad":"'
$advValidLine = $advValidBody + ('\"' * $advQuotes) + '"}'
$advDupLine = '{"task_id":"abcdef0123456789","pad":"' + ('\"' * $advQuotes) + '","task_id":"2222222222222222"}'
$advLines = @($advValidLine, $advDupLine)
$advFile = Write-TestFile $caseDir 'resolver-20261066.jsonl' $advLines
$swAdv = [System.Diagnostics.Stopwatch]::StartNew()
$rAdv = Get-AdvisoryCollectorReport -ResolverPaths @($advFile)
$swAdv.Stop()
Assert ([int]$rAdv.counts.resolver_records_valid -eq 1) 'linha com milhares de aspas escapadas no valor continua valida' ([string]$rAdv.counts.resolver_records_valid)
Assert ([int]$rAdv.counts.resolver_records_rejected -eq 1) 'a outra linha adversaria (duplicata) e rejeitada' ([string]$rAdv.counts.resolver_records_rejected)
Assert ([int]$rAdv.rejection_reasons.resolver.DUPLICATE_KEY -eq 1) 'motivo DUPLICATE_KEY na fixture adversaria' ([string]$rAdv.rejection_reasons.resolver.DUPLICATE_KEY)
Assert ($swAdv.ElapsedMilliseconds -lt 60000) 'scanner de passada unica: tempo limitado com milhares de aspas escapadas (margem generosa)' ("$($swAdv.ElapsedMilliseconds)ms")
$advJson = ConvertTo-AdvisoryCollectorJson -Report $rAdv -Depth 12
Assert (-not $advJson.Contains('"pad"')) 'nome do campo desconhecido com escapes nao e ecoado'
Assert ($advJson.Length -lt 4000) 'nada do conteudo adversario (8k+ chars de escapes) entra no relatorio' ($advJson.Length)

$typeLines = @(
    '{"task_id":"fedcba9876543217","task_class":"implementation","profiles":[],"agents":[42],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}',
    '{"task_id":"fedcba9876543218","task_class":"implementation","profiles":[],"agents":"reviewer","skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}',
    '{"task_id":"fedcba9876543219","task_class":"implementation","profiles":[],"agents":[true],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z"}'
)
$typeFile = Write-TestFile $caseDir 'resolver-20261013.jsonl' $typeLines
$rTypes = Get-AdvisoryCollectorReport -ResolverPaths @($typeFile)
Assert ([int]$rTypes.counts.resolver_records_valid -eq 0) 'item de array que nao e string JSON e rejeitado' ([string]$rTypes.counts.resolver_records_valid)
Assert ([int]$rTypes.counts.resolver_records_rejected -eq 3) 'as 3 linhas com tipo invalido sao rejeitadas' ([string]$rTypes.counts.resolver_records_rejected)
Assert (-not (ConvertTo-AdvisoryCollectorJson -Report $rTypes -Depth 12).Contains('"42"')) 'valor numerico de array nao e coerzido para identificador'
$obsTypeFile = Write-TestFile $caseDir 'observations-20261013.jsonl' @('{"provenance":"supplied","task_key":"abcdef0123456789","claimed_agent":7,"claimed_skills":[true]}')
$rObsTypes = Get-AdvisoryCollectorReport -ObservationPaths @($obsTypeFile)
Assert ([int]$rObsTypes.counts.observations_accepted -eq 0) 'claimed_agent/claimed_skills de tipo nao-string sao rejeitados' ([string]$rObsTypes.counts.observations_accepted)
Assert (@($rObsTypes.rejection_reasons.observation.Keys) -ccontains 'INVALID_IDENTIFIER') 'motivo INVALID_IDENTIFIER para tipo invalido em claimed_*'
Assert ([int]$rMix.counts.unique_recommendations -eq 1) 'linhas identedicas deduplicam em 1 recomendacao' ([string]$rMix.counts.unique_recommendations)
$mixJson = ConvertTo-AdvisoryCollectorJson -Report $rMix -Depth 12
Assert (-not $mixJson.Contains('2G-IMPLEMENT-01')) 'task_id literal antigo nao aparece no relatorio'
Assert (-not $mixJson.Contains('not-a-class')) 'valor fora de enum nao aparece no relatorio'
Assert (-not $mixJson.Contains('has space')) 'identificador invalido nao aparece no relatorio'
Assert (-not $mixJson.Contains('sk-SYNTHETICSECRET')) 'canario em identificador nao aparece no relatorio'
Assert (-not $mixJson.Contains('"1234567890123456"')) 'id numerico nao e coerzido para chave no relatorio'

# chave duplicada fora do conjunto lido nao altera projecao (so e descartada)
$dupUnknownLine = '{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","zzz":1,"zzz":2}'
$dupUnknownFile = Write-TestFile $caseDir 'resolver-20261051.jsonl' @($dupUnknownLine)
$rDupUnknown = Get-AdvisoryCollectorReport -ResolverPaths @($dupUnknownFile)
Assert ([int]$rDupUnknown.counts.resolver_records_valid -eq 1) 'duplicata de chave desconhecida nao invalida a linha' ([string]$rDupUnknown.counts.resolver_records_valid)
Assert ([int]$rDupUnknown.inputs.dropped_input_keys_count -eq 1) 'chave desconhecida duplicada conta uma vez (parser colapsa)'
# objeto aninhado desconhecido repetindo nome lido => fail-closed
$nestedDupLine = '{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":[],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","meta":{"agents":1}}'
$nestedDupFile = Write-TestFile $caseDir 'resolver-20261052.jsonl' @($nestedDupLine)
$rNestedDup = Get-AdvisoryCollectorReport -ResolverPaths @($nestedDupFile)
Assert ([int]$rNestedDup.counts.resolver_records_valid -eq 0) 'nome lido repetido em objeto aninhado rejeita a linha (fail-closed)'
Assert (@($rNestedDup.rejection_reasons.resolver.Keys) -ccontains 'DUPLICATE_KEY') 'motivo DUPLICATE_KEY para repeticao aninhada'

# ---- D. projecao por allowlist (sem texto livre/segredo) --------------------
$leakLine = '{"task_id":"abcdef0123456789","task_class":"review","profiles":[],"agents":["reviewer"],"skills":["requesting-code-review"],"risk":"HIGH","confidence":"HIGH","mode":"shadow","at":"2026-10-09T10:00:00.0000000Z","prompt":"texto livre com segredo","api_key":"sk-SYNTHETICSECRET","nested":{"a":1},"reason_codes":["AMBIGUOUS"]}'
$leakFile = Write-TestFile $caseDir 'resolver-20261011.jsonl' @($leakLine)
$rLeak = Get-AdvisoryCollectorReport -ResolverPaths @($leakFile)
$leakJson = ConvertTo-AdvisoryCollectorJson -Report $rLeak -Depth 12
Assert ([int]$rLeak.counts.resolver_records_valid -eq 1) 'linha valida com campos extras e aceita' ([string]$rLeak.counts.resolver_records_valid)
Assert ([int]$rLeak.inputs.dropped_input_keys_count -eq 3) 'chaves desconhecidas viram contagem (prompt, nested, reason_codes)' ([string]$rLeak.inputs.dropped_input_keys_count)
Assert ([int]$rLeak.inputs.sensitive_keys_dropped -ge 1) 'chave sensivel contada sem ter o nome ecoado'
Assert (-not $leakJson.Contains('sk-SYNTHETICSECRET')) 'valor sensivel nao vaza'
Assert (-not $leakJson.Contains('texto livre')) 'texto livre nao vaza'
Assert (-not $leakJson.Contains('"a":1')) 'valor de objeto aninhado desconhecido nao vaza'
Assert (-not $leakJson.Contains('nested":{"a"')) 'objeto aninhado nao e serializado no relatorio'
Assert (-not $leakJson.Contains('AMBIGUOUS')) 'valor de campo descartado nao vaza'
Assert (-not $leakJson.Contains('"prompt"')) 'nome de chave desconhecida nao e ecoado'
Assert (-not $leakJson.Contains('"reason_codes"')) 'nome de chave conhecida do CLI nao e ecoado'
# canario tambem no NOME do arquivo: nada de nome/caminho no relatorio
$canaryFile = Write-TestFile $caseDir ('resolver-canary-sk-SYNTHETICSECRET-' + [guid]::NewGuid().ToString('N') + '.jsonl') @((New-ResolverLine -TaskKey 'abcdef0123456789'))
$rCanaryName = Get-AdvisoryCollectorReport -ResolverPaths @($canaryFile)
$canaryJson = ConvertTo-AdvisoryCollectorJson -Report $rCanaryName -Depth 12
Assert ([int]$rCanaryName.counts.resolver_records_valid -eq 1) 'arquivo com canario no nome ainda e lido' ([string]$rCanaryName.counts.resolver_records_valid)
Assert (-not $canaryJson.Contains('SYNTHETICSECRET')) 'nome de arquivo (canario) nao e ecoado no relatorio'
$fileEntryHasName = $false
foreach ($fe in @($rCanaryName.inputs.files)) {
    if (@($fe.PSObject.Properties.Name) -ccontains 'file') { $fileEntryHasName = $true }
}
Assert (-not $fileEntryHasName) 'entrada de arquivo no relatorio nao tem campo de nome/caminho'
$allowedTop = @('schema', 'schema_version', 'producer', 'authority', 'collection_status', 'collection_failure_reasons', 'evaluation_status', 'evaluation_status_reason', 'inputs', 'counts', 'recommendations', 'supplied_claims', 'uncorrelated', 'ambiguous', 'source_classification', 'missing', 'metrics', 'rejection_reasons', 'integrity')
$topKeys = @()
try { $topKeys = @(($leakJson | ConvertFrom-Json).PSObject.Properties.Name) } catch { $topKeys = @() }
$topUnexpected = @($topKeys | Where-Object { $allowedTop -cnotcontains $_ })
Assert (@($topUnexpected).Count -eq 0) 'relatorio so tem chaves de topo conhecidas' (@($topUnexpected) -join ',')

# ---- E. contrato do produtor (CLI manual) ----------------------------------
$cliLines = @(
    '{"task_id":"aaaaaaaaaaaaaaaa","task_class":"unknown","profiles":[],"agents":["coder"],"skills":["verification-before-completion"],"risk":"MEDIUM","confidence":"AMBIGUOUS","mode":"shadow","at":"2026-10-09T11:00:00.0000000Z"}',
    '{"task_id":"bbbbbbbbbbbbbbbb","task_class":"documentation","profiles":["core"],"agents":["docs-manager"],"skills":["repo-doc"],"risk":"LOW","confidence":"HIGH","mode":"shadow","at":"2026-10-09T11:05:00.0000000Z"}'
)
$cliFile = Write-TestFile $caseDir 'resolver-20261012.jsonl' $cliLines
$rCli = Get-AdvisoryCollectorReport -ResolverPaths @($cliFile)
Assert ([int]$rCli.counts.resolver_records_valid -eq 2) 'formato do CLI (capability-resolve.ps1) e aceito' ([string]$rCli.counts.resolver_records_valid)
Assert (@($rCli.recommendations.by_task_class.Keys) -ccontains 'unknown') "task_class 'unknown' do resolver e aceito"
Assert (@($rCli.recommendations.by_confidence.Keys) -ccontains 'AMBIGUOUS') 'confidence AMBIGUOUS do resolver e aceita'

# ---- F. NENHUMA correlacao entre resolver e observacao ----------------------
# Nao existe escopo comum (projeto/sessao/run) nem proveniencia autenticada.
# Mesmo com a mesma chave opaca nos dois streams, nenhum par e criado.
$corrDir = New-TestDir 'correlation'
$resKey = 'abcdef0123456789'
$corrResLines = @(
    (New-ResolverLine -TaskKey $resKey),
    (New-ResolverLine -TaskKey '0011223344556677'),
    (New-ResolverLine -TaskKey '8899aabbccddeeff')
)
$corrResFile = Write-TestFile $corrDir 'resolver-20261013.jsonl' $corrResLines
$corrObsLines = @(
    (New-ObservationLine -TaskKey ('sha256:' + $resKey)),
    (New-ObservationLine -TaskKey '0011223344556677' -Provenance 'runtime'),
    (New-ObservationLine -TaskKey 'ffeeddccbbaa9988'),
    (New-ObservationLine -TaskKey '9999888877776666' -Provenance 'supplied'),
    (New-ObservationLine -TaskKey 'DB-1A2B')
)
$corrObsFile = Write-TestFile $corrDir 'observations-20261013.jsonl' $corrObsLines
$rCorr = Get-AdvisoryCollectorReport -ResolverPaths @($corrResFile) -ObservationPaths @($corrObsFile)
Assert ([int]$rCorr.counts.observations_accepted -eq 3) 'somente observacoes com provenance supplied e chave valida sao aceitas' ([string]$rCorr.counts.observations_accepted)
Assert (@($rCorr.rejection_reasons.observation.Keys) -ccontains 'UNSUPPORTED_PROVENANCE') 'provenance != supplied rejeitada'
Assert (@($rCorr.rejection_reasons.observation.Keys) -ccontains 'INVALID_TASK_KEY_FORMAT') 'task_key literal antigo rejeitado'
Assert ([int]$rCorr.counts.correlated_pairs -eq 0) 'nenhum par e criado, nem com chave opaca igual nos dois streams' ([string]$rCorr.counts.correlated_pairs)
Assert ($rCorr.supplied_claims.correlation -ceq 'NOT_CORRELATED_NO_COMMON_SCOPED_ID') 'bloco de claims declara ausencia de correlacao' ($rCorr.supplied_claims.correlation)
Assert ($rCorr.supplied_claims.trust -ceq 'SUPPLIED_UNVERIFIED') 'claims fornecidos ficam SUPPLIED_UNVERIFIED'
Assert ($rCorr.uncorrelated.reason -ceq 'NO_COMMON_SCOPED_ID_OR_AUTHENTICATED_PROVENANCE') 'motivo da nao-correlacao e explicito'
Assert ([int]$rCorr.uncorrelated.resolver_keys -eq 3) 'todas as chaves do resolver ficam nao-correlacionadas' ([string]$rCorr.uncorrelated.resolver_keys)
Assert ([int]$rCorr.uncorrelated.observation_keys -eq 3) 'todas as chaves de observacao ficam nao-correlacionadas' ([string]$rCorr.uncorrelated.observation_keys)
Assert ([int]$rCorr.counts.uncorrelated_resolver_keys -eq 3) 'contagem de chaves do resolver nao correlacionadas'
Assert ([int]$rCorr.counts.uncorrelated_observation_keys -eq 3) 'contagem de chaves de observacao nao correlacionadas'
Assert ($rCorr.missing.correlation_contract) 'ausencia de contrato de correlacao declarada em missing' ([string]$rCorr.missing.correlation_contract)
Assert (-not $rCorr.integrity.rows_correlated) 'integridade: nenhuma linha correlacionada'
$corrClaim = $null
foreach ($c in @($rCorr.supplied_claims.items)) {
    if ([string]$c.task_key -ceq $resKey) { $corrClaim = $c }
}
if ($null -ne $corrClaim) {
    Assert ($corrClaim.trust -ceq 'SUPPLIED_UNVERIFIED') 'claim emitido carrega o rotulo SUPPLIED_UNVERIFIED'
    Assert (@($corrClaim.claimed_skills) -ccontains 'requesting-code-review') 'claim fornecido e exibido como claim (nunca como observacao)'
}
foreach ($obsField in @('observed_agent', 'observed_skills', 'observed_mcps', 'observed_outcome')) {
    Assert ($rCorr.supplied_claims.fields.$obsField -ceq 'NOT_OBSERVABLE') ('campo de observacao ' + $obsField + ' fica NOT_OBSERVABLE') ([string]$rCorr.supplied_claims.fields.$obsField)
}
foreach ($clmField in @('claimed_task_class', 'claimed_agent', 'claimed_skills', 'claimed_mcps')) {
    Assert ($rCorr.supplied_claims.fields.$clmField -ceq 'CLAIMED_NOT_OBSERVED') ('campo de claim ' + $clmField + ' fica CLAIMED_NOT_OBSERVED') ([string]$rCorr.supplied_claims.fields.$clmField)
}
$corrJson = ConvertTo-AdvisoryCollectorJson -Report $rCorr -Depth 12
Assert (-not $corrJson.Contains('RUNTIME_OBSERVED')) 'nenhum campo RUNTIME_OBSERVED no relatorio'
Assert (-not $corrJson.Contains('"VERIFIED"')) 'nenhum campo VERIFIED no relatorio'
Assert (-not $corrJson.Contains('sha256:')) 'prefixo sha256: nao e ecoado no relatorio'
Assert (-not $corrJson.Contains('DB-1A2B')) 'task_key literal antigo nao e ecoado'
Assert (-not $corrJson.Contains('"pairs"')) 'relatorio nao tem bloco de pares'
Assert (-not $corrJson.Contains('EXACT_KEY_MATCH')) 'nenhum marcador de correlacao exata no relatorio'

# hash completo (64 hex) do kernel continua invalido: sem truncamento e sem par
$hashLines = @(
    (New-ResolverLine -TaskKey 'abcdef0123456789'),
    ('{"provenance":"supplied","task_key":"sha256:' + ('a' * 64) + '","task_class":"review","claimed_agent":"reviewer"}')
)
$hashFile = Write-TestFile $corrDir 'resolver-20261014.jsonl' @($hashLines[0])
$hashObsFile = Write-TestFile $corrDir 'observations-20261014.jsonl' @($hashLines[1])
$rHash = Get-AdvisoryCollectorReport -ResolverPaths @($hashFile) -ObservationPaths @($hashObsFile)
Assert ([int]$rHash.counts.correlated_pairs -eq 0) 'hash completo de 64 hex nao e truncado para casar (zero inferencia)'
Assert ([int]$rHash.counts.uncorrelated_resolver_keys -eq 1) 'chave do resolver fica nao-correlacionada'
Assert ([int]$rHash.counts.uncorrelated_observation_keys -eq 0) 'observacao com hash completo e rejeitada, nao correlacionada'
Assert (@($rHash.rejection_reasons.observation.Keys) -ccontains 'INVALID_TASK_KEY_FORMAT') 'motivo INVALID_TASK_KEY_FORMAT para hash completo'

# observacao sem provenance/outcome nao conta como observacao real
$noProvFile = Write-TestFile $corrDir 'observations-20261015.jsonl' @(
    '{"task_key":"abcdef0123456789","task_class":"review","claimed_agent":"reviewer"}',
    '{"provenance":"kernel-telemetry","task_key":"abcdef0123456789"}',
    '{"provenance":"supplied","task_key":"abcdef0123456789","claimed_agent":"reviewer","claimed_skills":["requesting-code-review"],"claimed_mcps":["context7"]}'
)
$rNoProv = Get-AdvisoryCollectorReport -ResolverPaths @($hashFile) -ObservationPaths @($noProvFile)
Assert ([int]$rNoProv.counts.observations_accepted -eq 1) 'registro sem provenance explicita nao e aceito' ([string]$rNoProv.counts.observations_accepted)
Assert ([int]$rNoProv.counts.observations_rejected -eq 2) 'registros invalidos contados como rejeitados'
Assert ([int]$rNoProv.counts.observation_duplicate_keys -eq 0) 'chave duplicada nao inflaciona observacoes'
$dupFile = Write-TestFile $corrDir 'observations-20261016.jsonl' @(
    (New-ObservationLine -TaskKey 'abcdef0123456789'),
    (New-ObservationLine -TaskKey 'abcdef0123456789' -ClaimedAgent 'coder')
)
$rDup = Get-AdvisoryCollectorReport -ResolverPaths @($hashFile) -ObservationPaths @($dupFile)
Assert ([int]$rDup.counts.observations_accepted -eq 2) 'observacoes duplicadas aceitas mas contadas'
Assert ([int]$rDup.counts.observation_duplicate_keys -eq 1) 'chave duplicada contabilizada uma vez'
Assert ([int]$rDup.counts.ambiguous_observation_keys -eq 1) 'claims conflitantes para a mesma chave ficam AMBIGUOS'
Assert ([int]$rDup.counts.correlated_pairs -eq 0) 'nenhum par existe, com ou sem ambiguidade'
Assert (@($rDup.ambiguous.observation_keys) -ccontains 'abcdef0123456789') 'chave ambigua listada em ambiguous.observation_keys'
Assert ([int]$rDup.supplied_claims.emitted -eq 0) 'chave ambigua nao emite claim (nenhum claim escolhido)'
$dupJson = ConvertTo-AdvisoryCollectorJson -Report $rDup -Depth 12
Assert (-not $dupJson.Contains('"claimed_agent":"coder"')) 'claim conflitante nao e ecoado em lugar nenhum'
Assert (-not $dupJson.Contains('"claimed_agent":"reviewer"')) 'nenhum dos claims conflitantes e escolhido'
# repeticao IDENTICA do mesmo claim deduplica (nao e conflito)
$sameDupFile = Write-TestFile $corrDir 'observations-20261017.jsonl' @(
    (New-ObservationLine -TaskKey 'abcdef0123456789'),
    (New-ObservationLine -TaskKey 'abcdef0123456789')
)
$rSameDup = Get-AdvisoryCollectorReport -ResolverPaths @($hashFile) -ObservationPaths @($sameDupFile)
Assert ([int]$rSameDup.counts.observations_accepted -eq 2) 'repeticao identica aceita e contada'
Assert ([int]$rSameDup.counts.ambiguous_observation_keys -eq 0) 'repeticao identica nao e ambiguidade'
Assert ([int]$rSameDup.counts.correlated_pairs -eq 0) 'claim unico nao correla com recomendacao (sem escopo comum)'
Assert ([int]$rSameDup.supplied_claims.unique_keys -eq 1) 'repeticao identica deduplica em 1 chave de claim'
$sameClaim = $null
foreach ($c in @($rSameDup.supplied_claims.items)) { if ([string]$c.task_key -ceq 'abcdef0123456789') { $sameClaim = $c } }
if ($null -ne $sameClaim) {
    Assert ($sameClaim.trust -ceq 'SUPPLIED_UNVERIFIED') 'claim fornecido segue SUPPLIED_UNVERIFIED'
    Assert (@($sameClaim.claimed_skills) -ccontains 'requesting-code-review') 'claim e exibido como claim, sem campo de observacao'
}
# nenhuma metrica e derivada de claim fornecido, mesmo com claim emitido
$claimMetricBad = @()
foreach ($m in $metricNames) {
    $cm = $null
    try { $cm = $rSameDup.metrics.$m } catch { $cm = $null }
    if ($null -eq $cm) { $claimMetricBad += ($m + ':ausente'); continue }
    if ([string]$cm.status -cne 'NOT_OBSERVABLE') { $claimMetricBad += ($m + ':' + $cm.status) }
}
Assert (@($claimMetricBad).Count -eq 0) 'metrica nenhuma e derivada de claim fornecido (mesmo com par emitido)' (@($claimMetricBad) -join ',')

# ---- G. saida honesta: PARTIAL, classificacao de fonte, NOT_OBSERVABLE ------
# ($metricNames ja foi definido e travado antes de qualquer uso, no topo.)
$soloRes = Get-AdvisoryCollectorReport -ResolverPaths @($corrResFile)
Assert ($soloRes.source_classification.resolver_stream -ceq 'RESOLVER_RECOMMENDATION_MANUAL_CLI') 'fonte do resolver classificada como recomendacao de CLI manual'
Assert ($soloRes.source_classification.observation_stream -ceq 'SUPPLIED_OBSERVATION_UNAUTHENTICATED') 'fonte de observacao classificada como fornecida e nao autenticada'
Assert ($soloRes.source_classification.kernel_telemetry -ceq 'NOT_INGESTED') 'telemetria de kernel declarada como nao ingerida'
Assert ($soloRes.source_classification.correlation -ceq 'NOT_CORRELATED_NO_COMMON_SCOPED_ID') 'correlacao declarada como inexistente (sem escopo comum)'
Assert ($soloRes.missing.external_observations) 'ausencia de observacoes externas declarada em missing'
Assert ($soloRes.missing.runtime_ground_truth) 'ausencia de ground truth de runtime declarada em missing'
Assert ($soloRes.missing.proven_observations) 'ausencia de observacao provada/autenticada declarada em missing'
Assert ($soloRes.evaluation_status -ceq 'PARTIAL') 'sem observacoes externas o status e PARTIAL' ($soloRes.evaluation_status)
Assert ($soloRes.evaluation_status_reason -ceq 'NO_EXTERNAL_OBSERVATIONS') 'razao NO_EXTERNAL_OBSERVATIONS'
$emptyRep = Get-AdvisoryCollectorReport
Assert ($emptyRep.evaluation_status -ceq 'UNAVAILABLE') 'sem nenhum registro valido o status e UNAVAILABLE' ($emptyRep.evaluation_status)
Assert ($emptyRep.evaluation_status_reason -ceq 'NO_VALID_RESOLVER_ROWS') 'razao NO_VALID_RESOLVER_ROWS'
$metricBad = @()
foreach ($m in $metricNames) {
    $entry = $null
    try { $entry = $soloRes.metrics.$m } catch { $entry = $null }
    if ($null -eq $entry) { $metricBad += ($m + ':ausente'); continue }
    if ([string]$entry.status -cne 'NOT_OBSERVABLE') { $metricBad += ($m + ':' + $entry.status) }
    if ([string]::IsNullOrWhiteSpace([string]$entry.reason)) { $metricBad += ($m + ':sem-razao') }
}
Assert (@($metricBad).Count -eq 0) 'metricas sem ground truth independente ficam NOT_OBSERVABLE com razao' (@($metricBad) -join ',')
Assert (@($soloRes.metrics.Keys).Count -eq @($metricNames).Count) 'nenhuma metrica observavel exposta alem das NOT_OBSERVABLE'
$metricKeys = @()
try { $metricKeys = @($soloRes.metrics.Keys) } catch { $metricKeys = @() }
$metricUnexpected = @($metricKeys | Where-Object { $metricNames -cnotcontains $_ })
$metricMissing = @($metricNames | Where-Object { $metricKeys -cnotcontains $_ })
Assert (@($metricUnexpected).Count -eq 0) 'nenhuma metrica fora da lista exata de 7' (@($metricUnexpected) -join ',')
Assert (@($metricMissing).Count -eq 0) 'as 7 metricas esperadas existem no relatorio' (@($metricMissing) -join ',')
$soloJson = ConvertTo-AdvisoryCollectorJson -Report $soloRes -Depth 12
Assert (-not $soloJson.Contains('adherence_rate')) 'nenhuma metrica de adesao inventada'
Assert (-not $soloJson.Contains('agreement_rate')) 'nenhuma metrica de acordo inventada'
Assert (-not $soloJson.Contains('success_rate')) 'nenhuma metrica de sucesso inventada'

# ---- H. claims fornecidos: total real vs emitido, truncation so quando vero --
$pairDir = New-TestDir 'pairexact'
$pKeys = @('1111111111111111', '2222222222222222', '3333333333333333')
$pResLines = @()
$pObsLines = @()
foreach ($k in $pKeys) {
    $pResLines += (New-ResolverLine -TaskKey $k)
    $pObsLines += (New-ObservationLine -TaskKey $k)
}
$pResFile = Write-TestFile $pairDir 'resolver-20261080.jsonl' $pResLines
$pObsFile = Write-TestFile $pairDir 'observations-20261080.jsonl' $pObsLines
$pExact = Get-AdvisoryCollectorReport -ResolverPaths @($pResFile) -ObservationPaths @($pObsFile) -Limits @{ output_items = 3 }
Assert ([int]$pExact.supplied_claims.unique_keys -eq 3) 'total real de claims nao depende de cap' ([string]$pExact.supplied_claims.unique_keys)
Assert ([int]$pExact.supplied_claims.emitted -eq 3) 'todos os claims emitidos sem cap apertado'
Assert (-not $pExact.supplied_claims.truncated) 'cap exato sem omissao NAO marca truncation'
Assert ([int]$pExact.counts.correlated_pairs -eq 0) 'chaves iguais nos dois streams nao geram correlacao'
$pTrunc = Get-AdvisoryCollectorReport -ResolverPaths @($pResFile) -ObservationPaths @($pObsFile) -Limits @{ output_items = 1 }
Assert ([int]$pTrunc.supplied_claims.unique_keys -eq 3) 'total real permanece 3 com cap de emissao' ([string]$pTrunc.supplied_claims.unique_keys)
Assert ([int]$pTrunc.supplied_claims.emitted -eq 1) 'emissao respeita o cap' ([string]$pTrunc.supplied_claims.emitted)
Assert (@($pTrunc.supplied_claims.items).Count -eq 1) 'array de claims tem exatamente o que foi emitido'
Assert ($pTrunc.supplied_claims.truncated) 'truncation true apenas quando houve omissao real'
$pTruncJson = ConvertTo-AdvisoryCollectorJson -Report $pTrunc -Depth 12
Assert ($pTruncJson.Contains('"unique_keys":3')) 'total real declarado no JSON mesmo truncado'
Assert ($pTruncJson.Contains('"emitted":1')) 'emitido declarado no JSON'
$claimsByKey = @{}
foreach ($c in @($pExact.supplied_claims.items)) { $claimsByKey[[string]$c.task_key] = $c }
Assert (@($claimsByKey.Keys).Count -eq 3) 'cada chave de claim aparece uma vez'
$firstClaim = $null
foreach ($c in @($pExact.supplied_claims.items)) { $firstClaim = $c; break }
if ($null -ne $firstClaim) {
    $claimFields = @($firstClaim.Keys)
    $claimUnexpected = @($claimFields | Where-Object { @('task_key', 'trust', 'claimed_task_class', 'claimed_agent', 'claimed_skills', 'claimed_mcps') -cnotcontains $_ })
    Assert (@($claimUnexpected).Count -eq 0) 'item de claim so tem campos conhecidos' (@($claimUnexpected) -join ',')
    Assert (@($firstClaim.claimed_skills).Count -ge 1) 'claim emitido carrega os skills reivindicados'
}

# ---- I. borda: arquivo vazio/so-blanks, diretorio, paths duplicados --------
$edgeDir = New-TestDir 'edges'
$emptyFile = Write-TestFile $edgeDir 'resolver-20261030.jsonl' @()
[IO.File]::WriteAllText($emptyFile, '', [Text.UTF8Encoding]::new($false))
$swEmpty = [System.Diagnostics.Stopwatch]::StartNew()
$rEmpty = Get-AdvisoryCollectorReport -ResolverPaths @($emptyFile)
$swEmpty.Stop()
Assert ($rEmpty.collection_status -ceq 'COMPLETED') 'arquivo vazio nao trava e nao falha fechado' ($rEmpty.collection_status)
Assert ([int]$rEmpty.counts.resolver_records_valid -eq 0) 'arquivo vazio nao produz registro'
Assert ($rEmpty.evaluation_status -ceq 'UNAVAILABLE') 'arquivo vazio => UNAVAILABLE'
Assert ($swEmpty.ElapsedMilliseconds -lt 60000) 'arquivo vazio responde em tempo limitado (margem generosa, sem laco infinito)' ("$($swEmpty.ElapsedMilliseconds)ms")
$blankFile = Write-TestFile $edgeDir 'resolver-20261031.jsonl' @('', '   ', '')
[IO.File]::WriteAllText($blankFile, "`r`n   `r`n`r`n", [Text.UTF8Encoding]::new($false))
$rBlank = Get-AdvisoryCollectorReport -ResolverPaths @($blankFile)
Assert ($rBlank.collection_status -ceq 'COMPLETED') 'arquivo so com linhas vazias nao trava'
# as 3 linhas vazias (inclusive as do fim) foram REALMENTE lidas: contam como
# examinadas e como rejeitadas - lines_read nunca finge menos trabalho
Assert ([int]$rBlank.counts.resolver_lines_read -eq 3) 'linhas vazias posicionadas no fim contam como lidas' ([string]$rBlank.counts.resolver_lines_read)
Assert ([int]$rBlank.counts.resolver_records_rejected -eq 3) 'linhas vazias viram EMPTY_ROW rejeitadas' ([string]$rBlank.counts.resolver_records_rejected)
Assert ([int]$rBlank.rejection_reasons.resolver.EMPTY_ROW -eq 3) 'motivo EMPTY_ROW para as vazias do fim'
Assert ([int]$rBlank.counts.resolver_lines_omitted -eq 0) 'sem cap nao ha linha omitida'
$lfFile = Join-Path $edgeDir 'resolver-20261032.jsonl'
[IO.File]::WriteAllText($lfFile, "`n`n`n", [Text.UTF8Encoding]::new($false))
$rLf = Get-AdvisoryCollectorReport -ResolverPaths @($lfFile)
Assert ($rLf.collection_status -ceq 'COMPLETED') 'arquivo so com LF nao trava'
Assert ([int]$rLf.counts.resolver_lines_read -eq 3) 'linhas com LF sozinho tambem contam como lidas' ([string]$rLf.counts.resolver_lines_read)
Assert ($rLf.evaluation_status -ceq 'UNAVAILABLE') 'arquivo so com LF => UNAVAILABLE'
# regressao de custo quadratico: muitas linhas vazias no fim (era
# ReadAllText + split + fatiamento sucessivo de array). Robustez: baseline menor
# (4x menos linhas) + margem absoluta generosa - carga de host nao pode falhar
# um teste que mede escala, e comportamento quadratico ainda estouraria a razao.
$blankHeavy = Join-Path $edgeDir 'resolver-20261040.jsonl'
$blankBase = Join-Path $edgeDir 'resolver-20261041.jsonl'
$blankHeavyLines = 20000
$blankBaseLines = 5000
$blankBuilder = New-Object System.Text.StringBuilder
for ($bi = 0; $bi -lt $blankHeavyLines; $bi++) { [void]$blankBuilder.Append("`r`n") }
[IO.File]::WriteAllText($blankHeavy, $blankBuilder.ToString(), [Text.UTF8Encoding]::new($false))
$blankBaseBuilder = New-Object System.Text.StringBuilder
for ($bi = 0; $bi -lt $blankBaseLines; $bi++) { [void]$blankBaseBuilder.Append("`r`n") }
[IO.File]::WriteAllText($blankBase, $blankBaseBuilder.ToString(), [Text.UTF8Encoding]::new($false))
$swBlankBase = [System.Diagnostics.Stopwatch]::StartNew()
$rBlankBase = Get-AdvisoryCollectorReport -ResolverPaths @($blankBase)
$swBlankBase.Stop()
$rateBlankBase = ([double]$swBlankBase.ElapsedMilliseconds) / ([double]$blankBaseLines)
$swBlank = [System.Diagnostics.Stopwatch]::StartNew()
$rBlankHeavy = Get-AdvisoryCollectorReport -ResolverPaths @($blankHeavy)
$swBlank.Stop()
$rateBlank = ([double]$swBlank.ElapsedMilliseconds) / ([double]$blankHeavyLines)
Assert ([int]$rBlankBase.counts.resolver_lines_read -eq $blankBaseLines) 'baseline de 5k vazias lida por inteiro' ([string]$rBlankBase.counts.resolver_lines_read)
Assert ($rBlankHeavy.collection_status -ceq 'COMPLETED') 'arquivo com 20k linhas vazias completa sem falhar fechado'
Assert ([int]$rBlankHeavy.counts.resolver_lines_read -eq $blankHeavyLines) '20k vazias do fim contam como lidas (trabalho real)' ([string]$rBlankHeavy.counts.resolver_lines_read)
Assert ([int]$rBlankHeavy.rejection_reasons.resolver.EMPTY_ROW -eq $blankHeavyLines) '20k vazias viram EMPTY_ROW agregado' ([string]$rBlankHeavy.rejection_reasons.resolver.EMPTY_ROW)
Assert ($swBlank.ElapsedMilliseconds -lt 90000) 'leitura linear: 20k vazias com margem generosa (host carregado)' ("$($swBlank.ElapsedMilliseconds)ms")
Assert ($rateBlankBase -gt 0) 'custo por linha da baseline e mensuravel' ("$($rateBlankBase)ms/linha")
Assert ($rateBlank -le (3.0 * $rateBlankBase)) 'custo por linha nao escala pior que linear (baseline 4x menor como referencia)' ("base=$($rateBlankBase)ms/linha heavy=$($rateBlank)ms/linha")
# linhas malformadas em massa sao examinadas, contadas e delimitadas
$junkHeavy = Join-Path $edgeDir 'resolver-20261041.jsonl'
$junkBuilder = New-Object System.Text.StringBuilder
for ($ji = 0; $ji -lt 2000; $ji++) { [void]$junkBuilder.Append('not-json-' + $ji + "`r`n") }
[IO.File]::WriteAllText($junkHeavy, $junkBuilder.ToString(), [Text.UTF8Encoding]::new($false))
$rJunk = Get-AdvisoryCollectorReport -ResolverPaths @($junkHeavy)
Assert ([int]$rJunk.counts.resolver_lines_read -eq 2000) 'malformadas contam como linhas examinadas' ([string]$rJunk.counts.resolver_lines_read)
Assert ([int]$rJunk.counts.resolver_records_rejected -eq 2000) 'malformadas contam como rejeitadas'
Assert ([int]$rJunk.rejection_reasons.resolver.MALFORMED_JSON -eq 2000) 'motivo MALFORMED_JSON agregado corretamente'
Assert (-not $rJunk.inputs.records_cap_reached) 'dentro do cap nao ha sinalizacao de truncamento'
# muitas chaves DISTINTAS perto dos caps: agregacao/ordenacao nao pode ser O(n^2).
# Regressao medida por ESCALA contra uma baseline menor (1/6 do volume), nao por
# tempo absoluto: sob host carregado (CI ou maquina local) o absoluto varia uma
# ordem de grandeza em PS 5.1 e um limite fixo baixo falhava por ruido de
# ambiente, nao por regressao de custo. Com 6x os dados, custo linear daria ~6x
# o tempo (taxa por chave equivalente) e custo quadratico daria ~36x (taxa ~6x
# maior): a taxa por chave da amostra grande nao pode passar de 3x a da
# baseline. O tempo absoluto continua verificado, so que com margem generosa,
# como rede de seguranca contra laco infinito.
$manyKeys = 1500
$manyBaseKeys = 250
$manyDir = New-TestDir 'manykeys'
$manyFile = Join-Path $manyDir 'resolver-20261090.jsonl'
$manyBaseFile = Join-Path $manyDir 'resolver-20261091.jsonl'
$manyBuilder = New-Object System.Text.StringBuilder
for ($ki = 0; $ki -lt $manyKeys; $ki++) {
    $hex = ('{0:x16}' -f $ki)
    [void]$manyBuilder.Append((New-ResolverLine -TaskKey $hex -TaskClass 'review' -Risk 'LOW' -Confidence 'HIGH'))
    [void]$manyBuilder.Append("`r`n")
}
[IO.File]::WriteAllText($manyFile, $manyBuilder.ToString(), [Text.UTF8Encoding]::new($false))
$manyBaseBuilder = New-Object System.Text.StringBuilder
for ($ki = 0; $ki -lt $manyBaseKeys; $ki++) {
    $hex = ('{0:x16}' -f $ki)
    [void]$manyBaseBuilder.Append((New-ResolverLine -TaskKey $hex -TaskClass 'review' -Risk 'LOW' -Confidence 'HIGH'))
    [void]$manyBaseBuilder.Append("`r`n")
}
[IO.File]::WriteAllText($manyBaseFile, $manyBaseBuilder.ToString(), [Text.UTF8Encoding]::new($false))
$swManyBase = [System.Diagnostics.Stopwatch]::StartNew()
$rManyBase = Get-AdvisoryCollectorReport -ResolverPaths @($manyBaseFile)
$swManyBase.Stop()
$rateBase = ([double]$swManyBase.ElapsedMilliseconds) / ([double]$manyBaseKeys)
$swMany = [System.Diagnostics.Stopwatch]::StartNew()
$rMany = Get-AdvisoryCollectorReport -ResolverPaths @($manyFile)
$swMany.Stop()
$rateMany = ([double]$swMany.ElapsedMilliseconds) / ([double]$manyKeys)
Assert ([int]$rManyBase.counts.resolver_records_valid -eq $manyBaseKeys) 'baseline menor de chaves distintas e aceita por inteiro' ([string]$rManyBase.counts.resolver_records_valid)
Assert ([int]$rMany.counts.resolver_records_valid -eq $manyKeys) 'todas as linhas com chave distinta sao aceitas' ([string]$rMany.counts.resolver_records_valid)
Assert ([int]$rMany.counts.unique_recommendations -eq $manyKeys) 'cada chave distinta gera recomendacao unica' ([string]$rMany.counts.unique_recommendations)
Assert ([int]$rMany.counts.uncorrelated_resolver_keys -eq $manyKeys) 'nenhuma chave e correlacionada (sem escopo comum)' ([string]$rMany.counts.uncorrelated_resolver_keys)
Assert ([int]$rMany.recommendations.by_task_class.review -eq $manyKeys) 'contagem por task_class fecha com as chaves distintas' ([string]$rMany.recommendations.by_task_class.review)
Assert ($swMany.ElapsedMilliseconds -lt 90000) 'tempo absoluto permanece finito com margem generosa (rede de seguranca)' ("$($swMany.ElapsedMilliseconds)ms")
Assert ($rateBase -gt 0) 'custo por chave da baseline e mensuravel' ("$($rateBase)ms/chave")
Assert ($rateMany -le (3.0 * $rateBase)) 'custo por chave nao escala pior que linear (baseline 6x menor como referencia)' ("base=$($rateBase)ms/chave many=$($rateMany)ms/chave")
# helper de ordenacao: muitos itens, ordem ordinal, sem perda
$sortedProbe = New-Object System.Collections.ArrayList
for ($si = 0; $si -lt 4000; $si++) { [void]$sortedProbe.Add(('k{0:d6}' -f $si)) }
$swSort = [System.Diagnostics.Stopwatch]::StartNew()
$sortedOut = @(Get-AdvisorySortedStrings -Values $sortedProbe.ToArray())
$swSort.Stop()
Assert (@($sortedOut).Count -eq 4000) 'ordenacao nao perde item' ([string]@($sortedOut).Count)
Assert ($sortedOut[0] -ceq 'k000000' -and $sortedOut[3999] -ceq 'k003999') 'ordenacao ordinal de ponta a ponta'
Assert ($swSort.ElapsedMilliseconds -lt 30000) 'ordenacao de 4000 itens e linear (margem generosa)' ("$($swSort.ElapsedMilliseconds)ms")
$rDir = Get-AdvisoryCollectorReport -ResolverPaths @($edgeDir)
Assert ($rDir.collection_status -ceq 'FAILED_CLOSED') 'diretorio como entrada => FAILED_CLOSED'
Assert (@($rDir.collection_failure_reasons) -ccontains 'NOT_A_FILE') 'motivo NOT_A_FILE para diretorio'
$rDup = Get-AdvisoryCollectorReport -ResolverPaths @($emptyFile, $emptyFile)
Assert (@($rDup.inputs.files).Count -eq 1) 'path repetido e deduplicado (uma entrada)' ([string]@($rDup.inputs.files).Count)
$rNoInput = Get-AdvisoryCollectorReport
Assert ($rNoInput.collection_status -ceq 'COMPLETED') 'sem nenhum caminho o coletor completa sem lancar'
Assert (@($rNoInput.inputs.files).Count -eq 0) 'sem caminho nao ha arquivo no relatorio'

# ---- J. determinismo, read-only e nao-regressao ----------------------------
$detA = ConvertTo-AdvisoryCollectorJson -Report (Get-AdvisoryCollectorReport -ResolverPaths @($corrResFile) -ObservationPaths @($corrObsFile)) -Depth 12
$detB = ConvertTo-AdvisoryCollectorJson -Report (Get-AdvisoryCollectorReport -ResolverPaths @($corrResFile) -ObservationPaths @($corrObsFile)) -Depth 12
Assert ($detA -ceq $detB) 'relatorio deterministico (duas execucoes identicas)'
Assert (-not $detA.Contains('"generated"')) 'relatorio sem campo de timestamp'
Assert (-not $detA.Contains($workDir)) 'relatorio sem caminho absoluto da fixture'
Assert (-not $detA.Contains('\:"')) 'relatorio sem path Windows'

# determinismo ENTRE PROCESSOS: um processo filho (runtime separado, seed de
# hash diferente) serializa o MESMO relatorio a partir das MESMAS fixtures e o
# JSON tem de ser identido byte a byte. Sem [ordered] em todos os mapas
# serializados, a ordem de chaves mudaria entre processos.
$procDir = New-TestDir 'determinism'
$procResLines = @(
    (New-ResolverLine -TaskKey 'abcdef0123456789' -Agents @('reviewer') -Skills @('requesting-code-review')),
    (New-ResolverLine -TaskKey '0123456789abcdef' -TaskClass 'implementation' -Risk 'LOW' -Confidence 'AMBIGUOUS' -Agents @('coder')),
    (New-ResolverLine -TaskKey 'fedcba9876543210' -TaskClass 'review' -Risk 'HIGH' -Confidence 'HIGH' -Profiles @('core'))
)
$procObsLines = @(
    (New-ObservationLine -TaskKey 'abcdef0123456789'),
    (New-ObservationLine -TaskKey '0123456789abcdef' -ClaimedAgent 'coder' -ClaimedSkills @('requesting-code-review')),
    (New-ObservationLine -TaskKey 'fedcba9876543210' -Provenance 'runtime')
)
$procResFile = Write-TestFile $procDir 'resolver-20261096.jsonl' $procResLines
$procObsFile = Write-TestFile $procDir 'observations-20261096.jsonl' $procObsLines
$detParent = ConvertTo-AdvisoryCollectorJson -Report (Get-AdvisoryCollectorReport -ResolverPaths @($procResFile) -ObservationPaths @($procObsFile)) -Depth 12
$detChildOut = Join-Path $procDir 'child-report.json'
$env:2G_DET_LIB = $libPath
$env:2G_DET_RES = $procResFile
$env:2G_DET_OBS = $procObsFile
$env:2G_DET_REPO = $RepoRoot
$env:2G_DET_OUT = $detChildOut
# Filho: dot-source da lib, monta o relatorio e grava o JSON (nada no stdout).
$detChildScript = @'
$ErrorActionPreference = "Stop"
. ([string]$env:2G_DET_LIB)
$rep = Get-AdvisoryCollectorReport -ResolverPaths @([string]$env:2G_DET_RES) -ObservationPaths @([string]$env:2G_DET_OBS) -RepoRoot ([string]$env:2G_DET_REPO)
$json = ConvertTo-AdvisoryCollectorJson -Report $rep -Depth 12
[IO.File]::WriteAllText([string]$env:2G_DET_OUT, $json, (New-Object System.Text.UTF8Encoding($false)))
'@
$detChildExe = 'powershell'
if ($PSVersionTable.PSVersion.Major -ge 7) { $detChildExe = 'pwsh' }
$detEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($detChildScript))
$detChildOutput = $null
$detChildErr = $null
$detChildCanRun = $false
try { $detChildCmd = Get-Command $detChildExe -ErrorAction Stop; if ($null -ne $detChildCmd) { $detChildCanRun = $true } } catch { $detChildCanRun = $false }
if (-not $detChildCanRun) {
    Skip-That 'processo filho separado produziu o mesmo relatorio' ('executavel ' + $detChildExe + ' indisponivel neste host')
    Skip-That 'serializacao identica entre PROCESSOS separados (ordem de chaves estavel)' ('executavel ' + $detChildExe + ' indisponivel neste host')
}
else {
    try { $detChildOutput = & $detChildExe -NoProfile -NonInteractive -EncodedCommand $detEncoded 2>&1 } catch { $detChildErr = $_.Exception.Message }
    $detChildJson = ''
    if ((Test-Path -LiteralPath $detChildOut -PathType Leaf)) {
        try { $detChildJson = [IO.File]::ReadAllText($detChildOut) } catch { $detChildJson = '' }
    }
    if (@($detChildJson).Length -le 0) {
        Skip-That 'processo filho separado produziu o mesmo relatorio' ('falha ao lancar processo filho: ' + [string]$detChildErr)
    }
    else {
        Assert ($detChildJson -ceq $detParent) 'processo filho separado produziu o mesmo relatorio' ('parent=' + @($detParent).Length + ' child=' + @($detChildJson).Length)
        Assert ($detChildJson -ceq $detParent) 'serializacao identica entre PROCESSOS separados (ordem de chaves estavel)' ('parent=' + @($detParent).Length + ' child=' + @($detChildJson).Length)
    }
}
# runtime oposto tambem estavel quando disponivel (fecha PS 5.1 <-> PS 7)
$detOtherExe = ''
if ($detChildExe -ceq 'powershell') { $detOtherExe = 'pwsh' }
elseif ($detChildExe -ceq 'pwsh') { $detOtherExe = 'powershell' }
if ($detOtherExe -cne '') {
    $detOtherOut = Join-Path $procDir 'other-report.json'
    $env:2G_DET_OUT = $detOtherOut
    $detOtherJson = ''
    $detOtherCanRun = $false
    try { $detOtherCmd = Get-Command $detOtherExe -ErrorAction Stop; if ($null -ne $detOtherCmd) { $detOtherCanRun = $true } } catch { $detOtherCanRun = $false }
    if ($detOtherCanRun) {
        try { $null = & $detOtherExe -NoProfile -NonInteractive -EncodedCommand $detEncoded } catch { }
        if (Test-Path -LiteralPath $detOtherOut -PathType Leaf) {
            try { $detOtherJson = [IO.File]::ReadAllText($detOtherOut) } catch { $detOtherJson = '' }
        }
    }
    if ((-not $detOtherCanRun) -or @($detOtherJson).Length -le 0) {
        Skip-That 'serializacao identica no runtime oposto (PS 5.1 <-> PS 7)' ('runtime oposto (' + $detOtherExe + ') indisponivel neste host')
    }
    else {
        Assert ($detOtherJson -ceq $detParent) 'serializacao identica no runtime oposto (PS 5.1 <-> PS 7)' ('parent=' + @($detParent).Length + ' other=' + @($detOtherJson).Length)
    }
    try { Remove-Item -LiteralPath $detOtherOut -Force -ErrorAction SilentlyContinue } catch { }
}
$env:2G_DET_LIB = $null
$env:2G_DET_RES = $null
$env:2G_DET_OBS = $null
$env:2G_DET_REPO = $null
$env:2G_DET_OUT = $null

$snapBefore = @()
$hashBefore = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $corrDir -File)) {
    $snapBefore += $f.Name
    $hashBefore[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
}
$null = Get-AdvisoryCollectorReport -ResolverPaths @($corrResFile) -ObservationPaths @($corrObsFile)
$snapAfter = @()
foreach ($f in @(Get-ChildItem -LiteralPath $corrDir -File)) { $snapAfter += $f.Name }
$sameListing = ((@($snapBefore).Count -eq @($snapAfter).Count))
foreach ($n in @($snapBefore)) { if (@($snapAfter) -cnotcontains $n) { $sameListing = $false } }
Assert $sameListing 'nenhum arquivo criado/removido no diretorio de entrada'
$hashSame = $true
foreach ($n in @($snapBefore)) {
    $h = (Get-FileHash -LiteralPath (Join-Path $corrDir $n) -Algorithm SHA256).Hash
    if ($h -cne $hashBefore[$n]) { $hashSame = $false }
}
Assert $hashSame 'conteudo dos arquivos de entrada inalterado (hash)'

$libText = ''
try { $libText = [IO.File]::ReadAllText($libPath, [Text.Encoding]::UTF8) } catch { $libText = '' }
Assert (-not $libText.Contains('Invoke-WebRequest')) 'lib nao faz requisicao web'
Assert (-not $libText.Contains('Invoke-RestMethod')) 'lib nao chama REST'
Assert (-not $libText.Contains('New-Object System.Net.WebClient')) 'lib nao usa WebClient'
Assert (-not $libText.Contains('Invoke-CapabilityResolve')) 'lib nao invoca Invoke-CapabilityResolve'
Assert (-not $libText.Contains('in @($stream.paths)')) 'selecao nao materializa o stream completo antes do cap'
Assert (-not $libText.Contains('Start-Process')) 'lib nao inicia processo externo'
Assert (-not $libText.Contains('[IO.File]::WriteAllText')) 'lib nao escreve arquivo'
Assert (-not $libText.Contains('[IO.File]::AppendAllText')) 'lib nao acrescenta a arquivo'
Assert (-not ($libText.Contains('events-*.jsonl') -and -not $libText.Contains('KERNEL_TELEMETRY_REFUSED'))) 'lib nao le events-*.jsonl (apenas recusa)'
Assert (-not $libText.Contains('if ($null -eq $Report)')) 'serializer nao carrega guarda morta de nulo'

# Report nulo: recusado pelo parameter binding (Mandatory), sem saida '{}'
$nullThrew = $false
$nullOut = ''
try { $nullOut = ConvertTo-AdvisoryCollectorJson -Report $null -Depth 12 } catch { $nullThrew = $true }
Assert $nullThrew 'serializer recusa Report nulo no binding (nada de guarda interna)' ([string]$nullOut)

$flags = $null
try { $flags = ([IO.File]::ReadAllText($flagsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $flags = $null }
if ($null -ne $flags) {
    Assert ($flags.capability_router.shadow -eq $false) 'flag capability_router.shadow continua OFF'
    Assert ($flags.capability_router.active -eq $false) 'flag capability_router.active continua OFF'
    Assert ($flags.routing_telemetry.enabled -eq $false) 'flag routing_telemetry.enabled continua OFF'
    Assert ($flags.skill_routing.enabled -eq $false -and $flags.mcp_routing.enabled -eq $false) 'flags skill_routing/mcp_routing continuam OFF'
    Assert ($flags.adaptive_ranking.enabled -eq $false) 'flag adaptive_ranking continua OFF'
    Assert ($flags.capability_reconciler.enabled -eq $false) 'flag capability_reconciler continua OFF'
}
else { Skip-That 'flags de routing OFF' 'capability-flags.json ilegivel' }

$routing = $null
try { $routing = ([IO.File]::ReadAllText($routingPath, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $routing = $null }
if ($null -ne $routing) {
    $registryClasses = @(@($routing.task_classes) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $collectorClasses = @(Get-AdvisoryTaskClasses)
    $drift = @($registryClasses | Where-Object { $collectorClasses -cnotcontains $_ })
    $extra = @($collectorClasses | Where-Object { $registryClasses -cnotcontains $_ -and $_ -cne 'unknown' })
    Assert (@($drift).Count -eq 0) 'enum task_class do coletor cobre o registro de routing' (@($drift) -join ',')
    Assert (@($extra).Count -eq 0) 'unico extra do enum do coletor e unknown do proprio resolver' (@($extra) -join ',')
}
else { Skip-That 'paridade do enum task_class' 'capability-routing.json ilegivel' }

# ---- limpeza da area temporaria (nunca do repo) ---------------------------
try {
    if (Test-Path -LiteralPath $junctionLink) {
        cmd /c rmdir "$junctionLink" | Out-Null
        if (Test-Path -LiteralPath $junctionLink) {
            try { [IO.Directory]::Delete($junctionLink) } catch { }
        }
    }
}
catch { }
try {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch { }
try {
    if (Test-Path -LiteralPath $workDir) { [IO.Directory]::Delete($workDir, $true) }
}
catch { }

Write-Host ("2G advisory collector: " + $pass + " passed, " + $fail + " failed, " + $skipped + " skipped, " + ($pass + $fail + $skipped) + " total")
if ($fail -gt 0) { exit 1 }
exit 0
