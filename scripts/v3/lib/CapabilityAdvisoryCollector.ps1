<#!
.SYNOPSIS
    Fase 2G - coletor de observabilidade capability ADVISORY (somente leitura).
.DESCRIPTION
    Biblioteca dot-sourceable. Nenhuma escrita em disco, nenhuma rede, nenhuma
    invocacao de worker/MCP/Resolver/Kernel. Le dois streams explicitamente
    informados (JSONL), cada um confinado a <repo>/cache/v3/telemetry ou TEMP:

      A) resolver-YYYYMMDD.jsonl (producao manual via capability-resolve.ps1):
         a RECOMENDACAO sanitizada do adapter (task_id opaco de 16 hex +
         enums). Tratada sempre como RECOMENDACAO, nunca como decisao de
         runtime e nunca como prova de que o resolver foi consultado.
      B) registros de observacao explicitamente fornecidos (opt-in, autorados
         por operador/Planner). Aceitos SOMENTE com proveniencia explicita
         'supplied'. Como esta ferramenta nao autentica o produtor, toda
         observacao aceita fica rotulada SUPPLIED_UNVERIFIED: nunca promovida
         a RUNTIME_OBSERVED/VERIFIED e nunca usada para metrica de acordo,
        adesao, sucesso ou desfecho produtivo.

    Regras duras (revisao de review, 2026-10-09):
      - Confinamento: cada entrada sob raiz permitida; reparse point/junction
        em QUALQUER componente do caminho => fail-closed (leitura recusada).
      - Projecao por allowlist: saida apenas com identificador opaco, enums
        fechados e identificadores conhecidos. Campos desconhecidos, texto
        livre, nomes de arquivo/caminho, nomes de chave de entrada e valores
        sensiveis nunca fluem para o relatorio: TODA chave desconhecida de
        primeiro nivel (inclusive nome Unicode ou com mais de 64 caracteres)
        vira CONTAGEM (dropped_input_keys_count / sensitive_keys_dropped),
        nunca nome.
      - Identificador de capability so passa se existir na allowlist fechada
        de capabilities conhecidas (agents/skills/profiles/mcps). Um canario
        disfarcado de identificador (ex.: 'sk-...') e rejeitado com
        INVALID_IDENTIFIER, nunca ecoado. Allowlist ilegivel => fail-closed:
        nenhum identificador e aceito e falha explicita e registrada.
      - Raiz JSON: somente OBJETO. Array de objeto (inclusive o singleton, que
        o pipeline do PowerShell desenrola em PS 5.1 e PS 7), numero, string e
        bool sao rejeitados com NOT_AN_OBJECT olhando TAMBEM a raiz crua: o
        primeiro caractere nao-espaco da linha tem de ser '{'. Sem essa
        checagem um array de 1 elemento passaria por objeto depois do unwrap.
      - Sem coercao: campo textual exige JSON string. Numero/bool/objeto nao
        vira texto (id numerico nao e "consertado" para chave valida). Linha
        que repetir nome de campo LIDO e rejeitada (DUPLICATE_KEY): nada de
        first-wins/last-wins implicito. A comparacao usa a chave DECODIFICADA,
        entao 'task_id' e 'task\u005fid' (escape JSON) contam como repeticao.
        A deteccao de repeticao usa scanner lexical de passada unica (sem
        regex): custo O(n) no tamanho da linha, sem backtracking dependente
        de engine. Politica de duplicata aninhada: fail-closed conservador;
        nome lido repetido em qualquer profundidade rejeita a linha.
      - Limites duros (apertaveis, nunca afrouxaveis): arquivos, bytes totais,
        linhas por arquivo, registros, itens por array e claims no relatorio.
        Leitura e streaming linear POR BYTES, com leitor proprio. O orcamento
        de bytes (total_bytes) e UM SO compartilhado por todos os arquivos E
        pelos dois streams: o que resta e passado a cada leitor e o que foi
        consumido de fato e debitado (nunca o tamanho do arquivo medido antes
        da leitura); sem bytes restantes o arquivo seguinte nao e lido e a
        omissao fica explicita (status truncado + LIMIT_EXCEEDED +
        bytes_cap_reached). O cap de arquivos tambem e UM SO, compartilhado
        pelos dois streams (enumeracao GLOBAL de candidatos): a entrada nao
        passa de files caminhos distintos nem o array de detalhes do
        relatorio de files entradas. Omissao de candidato (por cap de
        arquivos ou por cap de registros) vira CONTAGEM
        (files_skipped_by_limit / files_omitted_by_records_cap +
        candidate_paths_seen), nunca entrada sem limite no relatorio.
        Fronteira exata de bytes: EOF no ultimo byte do orcamento NAO e
        truncamento (a linha final esta completa e e aceita); so ha
        truncamento quando existem bytes ALEM do orcamento.
        lines_read conta toda linha REALMENTE lida (validas, vazias,
        malformadas, a linha-sonda que revela um cap e a linha parcial
        cortada pelo orcamento): o relatorio nunca finge menos trabalho do
        que foi feito nem esconde omissao. Omissao por cap e sempre disclosed
        (records_cap_reached, lines_cap_reached, bytes_cap_reached,
        files_skipped_by_limit, files_omitted_by_records_cap, status do
        arquivo, lines_omitted, bytes examinados).
      - NENHUMA correlacao entre recomendacao do resolver e observacao
        fornecida: nao existe escopo comum (projeto/sessao/run) nem proveniencia
        autenticada. Os dois blocos sao reportados EM SEPARADO; toda observacao
        fornecida fica SUPPLIED_UNVERIFIED e todos os campos de observacao
        (agente/skills/mcps/desfecho) ficam NOT_OBSERVABLE. Nenhum par e criado,
        nenhum campo de observacao e preenchido e nenhuma metrica e derivada.
      - Telemetria de kernel (events-*.jsonl) NUNCA e ingerida como
        observacao: recusa explicita por nome de arquivo.
      - Relatorio determinista (sem timestamp, sem caminho absoluto) com
        evaluation_status PARTIAL e metricas que dependem de ground truth
        independente marcadas NOT_OBSERVABLE com razao em enum fechado.

    API publica: Get-AdvisoryCollectorLimits, Get-AdvisoryCollectorReport,
    ConvertTo-AdvisoryCollectorJson.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AdvisoryRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-AdvisoryTaskClasses {
    <#
    .SYNOPSIS
        Enum fechado de task_class do stream do resolver.
    .DESCRIPTION
        12 valores de source/registry/capability-routing.json -> task_classes
        MAIS 'unknown', que o proprio resolver emite quando a classe vem fora
        da allowlist do routing (capability-resolve.ps1, fail-closed). A suite
        2G afirma paridade com o registro: os 12 do registro e apenas
        'unknown' como extra. Valor fora da lista nao e "corrigido": a linha e
        rejeitada com INVALID_TASK_CLASS.
    #>
    [CmdletBinding()]
    param()
    return @(
        'implementation', 'migration', 'analysis', 'research', 'debugging',
        'validation', 'review', 'documentation', 'planning', 'design',
        'testing', 'trivial', 'unknown'
    )
}

function Get-AdvisoryRiskLevels {
    [CmdletBinding()]
    param()
    return @('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
}

function Get-AdvisoryConfidenceLevels {
    <#
    .SYNOPSIS
        Enum fechado de confidence emitido pelo resolver (HIGH | AMBIGUOUS).
    #>
    [CmdletBinding()]
    param()
    return @('HIGH', 'AMBIGUOUS')
}

function Get-AdvisoryModes {
    [CmdletBinding()]
    param()
    return @('shadow')
}

function Get-AdvisoryRejectionReasons {
    <#
    .SYNOPSIS
        Enum fechado de motivos de rejeicao/recusa. Nenhum texto livre.
    #>
    [CmdletBinding()]
    param()
    return @(
        'MALFORMED_JSON', 'NOT_AN_OBJECT', 'EMPTY_ROW', 'MISSING_TASK_KEY',
        'INVALID_TASK_KEY_FORMAT', 'INVALID_TASK_CLASS', 'INVALID_RISK',
        'INVALID_CONFIDENCE', 'INVALID_MODE', 'INVALID_TIMESTAMP',
        'INVALID_IDENTIFIER', 'OVERSIZED_ROW', 'OVERSIZED_ARRAY',
        'UNSUPPORTED_PROVENANCE', 'KERNEL_TELEMETRY_REFUSED',
        'OUTSIDE_ALLOWED_ROOT', 'REPARSE_POINT_REFUSED', 'READ_FAILED',
        'NOT_A_FILE', 'LIMIT_EXCEEDED', 'DUPLICATE_KEY',
        'CAPABILITY_ALLOWLIST_UNAVAILABLE', 'UNCLASSIFIED_REJECTION'
    )
}

function Get-AdvisorySafeReason {
    <#
    .SYNOPSIS
        Projeta qualquer motivo para o enum fechado (fallback enum-only).
    #>
    [CmdletBinding()]
    param([string]$Reason = '')
    $allow = @(Get-AdvisoryRejectionReasons)
    $s = ([string]$Reason).Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { return 'UNCLASSIFIED_REJECTION' }
    if ($allow -ccontains $s) { return $s }
    return 'UNCLASSIFIED_REJECTION'
}

function Get-AdvisoryCollectorLimits {
    <#
    .SYNOPSIS
        Limites padrao (policy) do coletor. Valores inteiros >= 1.
    .DESCRIPTION
        file_lines limita LINHAS EXAMINADAS por arquivo (validas, vazias ou
        malformadas): sem ele, um arquivo de linhas invalidas dentro do cap de
        bytes seria examinado por inteiro. Omissao por esse cap e disclosed
        (inputs.lines_cap_reached + status do arquivo), nunca silenciosa; a
        linha-sonda que revela o cap foi lida e conta em lines_read.
        line_bytes limita BYTES guardados por linha (a linha maior e descartada
        como OVERSIZED_ROW, sem materializar o resto).
        total_bytes e UM ORCAMENTO COMPARTILHADO: a soma de todos os arquivos
        E dos dois streams nunca passa dele. O restante e passado a cada
        leitor e o consumo real e debitado; omissao por esgotamento fica
        explicita (status truncado + LIMIT_EXCEEDED + bytes_cap_reached).
        files limita a ENUMERACAO de candidatos e o array de detalhes do
        relatorio, e o orcamento e UM SO para os DOIS streams: os paths dos
        dois streams concorrem aos mesmos files slots (no maximo files
        candidatos distintos ficam retidos, os menores na ordem ordinal, com
        desempate deterministico) e inputs.files nunca passa de files
        entradas. Candidato omitido vira contagem
        (files_skipped_by_limit / files_omitted_by_records_cap), nunca
        entrada sem limite no relatorio.
        output_items limita claims fornecidos emitidos no relatorio: nao
        existe correlacao, portanto tambem nao existe par.
    #>
    [CmdletBinding()]
    param()
    return @{
        files        = 8
        total_bytes  = 8388608
        line_bytes   = 32768
        file_lines   = 50000
        records      = 20000
        array_items  = 16
        output_items = 200
    }
}

function Resolve-AdvisoryLimits {
    <#
    .SYNOPSIS
        Mescla overrides sobre os limites padrao. Override SO aperta: qualquer
        valor acima do padrao (ou invalido) cai no padrao. Nunca afrouxa.
    #>
    [CmdletBinding()]
    param([hashtable]$Limits = $null)
    $merged = Get-AdvisoryCollectorLimits
    if ($null -eq $Limits) { return $merged }
    foreach ($k in @($Limits.Keys)) {
        if (-not $merged.ContainsKey($k)) { continue }
        $v = 0
        try { $v = [int]$Limits[$k] } catch { continue }
        if ($v -lt 1) { $v = 1 }
        $cap = [int]$merged[$k]
        if ($v -gt $cap) { $v = $cap }
        $merged[$k] = $v
    }
    return $merged
}

function Get-AdvisoryFullPath {
    [CmdletBinding()]
    param([string]$Path = '', [string]$RepoRoot = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    catch { return '' }
}

function Get-AdvisoryAllowedRoots {
    <#
    .SYNOPSIS
        Raizes de leitura permitidas: <repo>/cache/v3/telemetry e TEMP.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    $roots = New-Object System.Collections.ArrayList
    try {
        $tel = Join-Path (Join-Path (Join-Path $RepoRoot 'cache') 'v3') 'telemetry'
        [void]$roots.Add([IO.Path]::GetFullPath($tel))
    }
    catch { }
    $tmp = ''
    try { $tmp = [IO.Path]::GetTempPath() } catch { $tmp = '' }
    if ([string]::IsNullOrWhiteSpace($tmp)) { $tmp = [string]$env:TEMP }
    if (-not [string]::IsNullOrWhiteSpace($tmp)) {
        try { [void]$roots.Add([IO.Path]::GetFullPath($tmp)) } catch { }
    }
    return @($roots)
}

function Test-AdvisoryIsWindowsPlatform {
    <#
    .SYNOPSIS
        True no Windows (comparacao de caminho INSENSIVEL a caixa).
    .DESCRIPTION
        Nao usa $IsWindows (variavel automatica somente do PS 7): em PS 5.1
        ela nao existe e -not $IsWindows seria verdadeiro no Windows.
        Environment.OSVersion.Platform existe no .NET Framework (PS 5.1) e no
        .NET Core (PS 7): Windows devolve Win32NT; Linux/macOS devolvem Unix.
        Excecao (praticamente inalcancavel) preserva a semantica Windows.
    #>
    [CmdletBinding()]
    param()
    try { return ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
    catch { return $true }
}

function Test-AdvisoryPathUnderRoot {
    <#
    .SYNOPSIS
        True se FullPath esta sob Root, com comparacao propria da plataforma.
    .DESCRIPTION
        Windows (NTFS, case-insensitive): comparacao ordinal INSENSIVEL a
        caixa - raiz e caminho podem divergir apenas na caixa e ainda apontar
        para o mesmo arquivo; exigir caixa identica recusaria entrada legitima.
        Unix (ext4 e afins, case-SENSITIVE): comparacao ordinal SENSIVEL a
        caixa - la /TMP e /tmp sao diretorios distintos e tratar /TMP/x como
        sob /tmp seria confinamento falso. Os dois lados chegam normalizados
        por Get-AdvisoryFullPath.
    #>
    [CmdletBinding()]
    param([string]$FullPath = '', [string]$Root = '')
    if ([string]::IsNullOrWhiteSpace($FullPath) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $sep = [IO.Path]::DirectorySeparatorChar
        $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + $sep
        $cmp = [System.StringComparison]::Ordinal
        if (Test-AdvisoryIsWindowsPlatform) { $cmp = [System.StringComparison]::OrdinalIgnoreCase }
        return $FullPath.StartsWith($prefix, $cmp)
    }
    catch { return $false }
}

function Test-AdvisoryConfinedInput {
    <#
    .SYNOPSIS
        True somente se o caminho estiver sob uma raiz permitida.
    #>
    [CmdletBinding()]
    param([string]$Path = '', [string]$RepoRoot = '')
    $full = Get-AdvisoryFullPath -Path $Path -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($full)) { return $false }
    foreach ($root in @(Get-AdvisoryAllowedRoots -RepoRoot $RepoRoot)) {
        if (Test-AdvisoryPathUnderRoot -FullPath $full -Root ([string]$root)) { return $true }
    }
    return $false
}

function Test-AdvisoryPathHasReparsePoint {
    <#
    .SYNOPSIS
        Recusa junction/symlink em QUALQUER componente do caminho (arquivo e
        todos os ancestentes). Replica o padrao de capability-resolve.ps1 e
        CapabilityAuthority.ps1: atributo ReparsePoint OU LinkType nao-HardLink.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while (-not [string]::IsNullOrWhiteSpace($current) -and $guard -lt 160) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    $linkType = [string]$item.LinkType
                    if ($item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -ine 'HardLink') { return $true }
                }
                catch { }
            }
            catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Test-AdvisoryKernelTelemetryName {
    <#
    .SYNOPSIS
        True para nome de arquivo de telemetria de kernel (events-*.jsonl):
        nunca ingerido como observacao nem como recomendacao.
    #>
    [CmdletBinding()]
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $leaf = ''
    try { $leaf = Split-Path -Leaf $Path } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }
    return ($leaf -cmatch '^events[-_].*\.jsonl$')
}

function Test-AdvisoryIdentifier {
    <#
    .SYNOPSIS
        Identificador seguro: charset fechado, sem espaco, sem texto livre.
    #>
    [CmdletBinding()]
    param([string]$Value = '')
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-AdvisoryTaskKey {
    <#
    .SYNOPSIS
        Chave opaco do resolver: 16 hex minusculo, sem prefixo.
    #>
    [CmdletBinding()]
    param([string]$Value = '')
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    return ($s -cmatch '^[0-9a-f]{16}$')
}

function Get-AdvisoryNormalizedTaskKey {
    <#
    .SYNOPSIS
        Normaliza SOMENTE o prefixo 'sha256:' e devolve a chave de 16 hex.
    .DESCRIPTION
        Nao conserta literal antigo, nao trunca hash completo (64 hex) e nao
        aceita variante maiuscula: qualquer outro formato devolve '' (vazio),
        que o chamador trata como rejeicao/UNMATCHED. Zero inferencia.
    #>
    [CmdletBinding()]
    param([string]$Value = '')
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    if ($s.StartsWith('sha256:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(7).Trim()
    }
    if ($s.Length -eq 64 -and $s -cmatch '^[0-9a-f]{64}$') { return '' }
    if ($s -cmatch '^[0-9a-f]{16}$') { return $s }
    return ''
}

function Test-AdvisoryTimestamp {
    <#
    .SYNOPSIS
        Valida o campo 'at': string ISO-8601 round-trip ('o') OU valor de data
        ja tipado.
    .DESCRIPTION
        PS 7 coage string ISO-8601 com 'T' para [DateTime]; PS 5.1 mantem
        String. Nos dois casos o valor e aceito: tipo tipado comprova string
        de data parseavel e string passa pelo formato round-trip 'o'.
        Qualquer outro tipo, string vazia, ausente ou fora de 'o' => invalido.
    #>
    [CmdletBinding()]
    param($Value = $null)
    if ($null -eq $Value) { return $false }
    if ($Value -is [DateTime]) { return ($Value -ne [DateTime]::MinValue) }
    if ($Value -is [DateTimeOffset]) { return ($Value -ne [DateTimeOffset]::MinValue) }
    if ($Value -is [string]) {
        $s = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s.Length -gt 40) { return $false }
        $dto = [DateTimeOffset]::MinValue
        try {
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
            return [DateTimeOffset]::TryParseExact($s, 'o', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dto)
        }
        catch { return $false }
    }
    return $false
}

function Get-AdvisoryJsonField {
    <#
    .SYNOPSIS
        Le um campo do objeto JSON e devolve wrapper { found; value }.
    .DESCRIPTION
        O wrapper existe porque o pipeline do PowerShell desenrola array de 1
        elemento (`["reviewer"]` viraria escalar) e quebraria a validacao de
        array de identificadores. Acesso por propriedade nao desenrola.
    #>
    [CmdletBinding()]
    param($Node = $null, [string]$Field = '')
    $out = [PSCustomObject]@{ found = $false; value = $null }
    if ($null -eq $Node) { return $out }
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Field)) { $out.found = $true; $out.value = $Node[$Field] }
        }
        else {
            foreach ($p in @($Node.PSObject.Properties)) {
                if ($p.Name -ceq $Field) { $out.found = $true; $out.value = $p.Value; break }
            }
        }
    }
    catch { }
    return $out
}

function Get-AdvisoryStringField {
    <#
    .SYNOPSIS
        Campo textual ESTRITO: somente JSON string conta; nada e coercido.
    .DESCRIPTION
        Devolve @{ found; value; isString }. Regra (sem coercao):
          - ausente ou JSON null => found=$false (tratado como ausente);
          - presente e [string]   => found=$true, isString=$true;
          - presente e outro tipo (numero/bool/objeto/array) => found=$true,
            isString=$false, value='' (o chamador rejeita; id numerico NUNCA
            vira texto de chave valida).
    #>
    [CmdletBinding()]
    param($Node = $null, [string]$Field = '')
    $out = @{ found = $false; value = ''; isString = $false }
    $f = Get-AdvisoryJsonField -Node $Node -Field $Field
    if (-not $f.found) { return $out }
    if ($null -eq $f.value) { return $out }
    if ($f.value -isnot [string]) { return @{ found = $true; value = ''; isString = $false } }
    return @{ found = $true; value = ([string]$f.value); isString = $true }
}

function Get-AdvisoryJsonKeys {
    <#
    .SYNOPSIS
        TODOS os nomes de primeiro nivel do objeto (sem filtro de charset).
    .DESCRIPTION
        A contagem de projecao precisa cobrir TODA propriedade desconhecida,
        inclusive nome com Unicode ou com mais de 64 caracteres: filtrar por
        charset aqui faria a chave desaparecer ANTES da conta e o relatorio
        sub-notificaria entrada desconhecida. Nenhum nome sai daqui: o unico
        consumidor (Get-AdvisoryRowProjectionCounts) devolve apenas inteiros.
    #>
    [CmdletBinding()]
    param($Node = $null)
    $keys = New-Object System.Collections.ArrayList
    if ($null -eq $Node) { return @() }
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in @($Node.Keys)) {
                [void]$keys.Add([string]$k)
            }
        }
        else {
            foreach ($p in @($Node.PSObject.Properties)) {
                [void]$keys.Add([string]$p.Name)
            }
        }
    }
    catch { }
    return @($keys)
}

function Get-AdvisoryIsJsonObject {
    [CmdletBinding()]
    param($Node = $null)
    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return $true }
    return ($Node -is [System.Management.Automation.PSCustomObject])
}

function Get-AdvisorySortedStrings {
    <#
    .SYNOPSIS
        Ordenacao ordinal (determinista entre locales/plataformas).
    .DESCRIPTION
        Acumula em ArrayList e so converte para array no fim: crescer array
        PowerShell com '+=' copia todo o acumulador a cada item (O(n^2)) e isso
        aparece justamente com muitas chaves distintas (perto dos caps). Nenhum
        item e descartado e a ordem de estabilidade nao importa: o comparador
        ordinal e total.
    #>
    [CmdletBinding()]
    param([string[]]$Values = @())
    $arr = New-Object System.Collections.ArrayList
    foreach ($v in @($Values)) {
        if ($null -ne $v) { [void]$arr.Add([string]$v) }
    }
    if ($arr.Count -le 1) { return @($arr) }
    $sorted = [string[]]$arr.ToArray()
    [array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function Get-AdvisorySortedCounts {
    <#
    .SYNOPSIS
        Hashtable de contagens projetada para dicionario ordenado (ordinal).
    #>
    [CmdletBinding()]
    param([hashtable]$Counts = $null)
    $out = [ordered]@{}
    if ($null -eq $Counts) { return $out }
    foreach ($k in @(Get-AdvisorySortedStrings -Values @($Counts.Keys))) {
        $out[$k] = [int]$Counts[$k]
    }
    return $out
}

function Add-AdvisoryCount {
    <#
    .SYNOPSIS
        Incrementa a contagem da chave no mapa (Count permite lote).
    #>
    [CmdletBinding()]
    param([hashtable]$Map = $null, [string]$Key = '', [int]$Count = 1)
    if ($null -eq $Map) { return }
    $k = [string]$Key
    $n = [int]$Count
    if ($n -lt 1) { $n = 1 }
    if ($Map.ContainsKey($k)) { $Map[$k] = ([int]$Map[$k]) + $n }
    else { $Map[$k] = $n }
}

function Get-AdvisoryCapabilityAllowlist {
    <#
    .SYNOPSIS
        Allowlist FECHADA de identificadores de capability conhecidos.
    .DESCRIPTION
        Leitura read-only das fontes canonicas do repo (nunca dos streams):
          - source/registry/capability-routing.json: agent_rules, skill_rules,
            profile_rules, mcp_rules;
          - source/agents/*.md: stems = ids canonicos de agente (fonte unica
            de verdade de agentes declarada no proprio routing);
          - source/registry/skills-catalog.json: skills[].id (catalogado);
          - source/registry/mcp-profiles.json: profiles[].id e profiles[].mcps.
        Regra dura: identificador FORA do conjunto nao pode fluir para o
        relatorio (seria um canal de vazamento de valor arbitrario). Se uma
        fonte esperada nao puder ser lida, ou se um conjunto ficar vazio,
        ok=false: o coletor falha fechado (nenhum identificador aceito) e a
        falha e registrada em collection_failure_reasons.
        Nenhum segredo, caminho ou texto livre entra no retorno.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    # Conjuntos criados inline de proposito: devolver HashSet pela saida de
    # uma funcao faria o pipeline do PowerShell enumerar o conjunto vazio
    # (Set vazio chegaria como $null no chamador).
    $agents = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $skills = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $profiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $mcps = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $ok = $true
    $root = ''
    try { $root = [IO.Path]::GetFullPath(([string]$RepoRoot)) } catch { $root = '' }
    if ([string]::IsNullOrWhiteSpace($root)) { $ok = $false }

    $routing = $null
    if ($ok) {
        try {
            $p = Join-Path $root 'source\registry\capability-routing.json'
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $routing = ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json)
            }
        }
        catch { $routing = $null }
        if ($null -eq $routing) { $ok = $false }
    }
    if ($null -ne $routing) {
        foreach ($r in @($routing.agent_rules)) {
            $v = ([string]$r.agent).Trim()
            if (Test-AdvisoryIdentifier -Value $v) { [void]$agents.Add($v) }
        }
        foreach ($r in @($routing.skill_rules)) {
            $v = ([string]$r.skill).Trim()
            if (Test-AdvisoryIdentifier -Value $v) { [void]$skills.Add($v) }
        }
        foreach ($r in @($routing.profile_rules)) {
            $v = ([string]$r.profile).Trim()
            if (Test-AdvisoryIdentifier -Value $v) { [void]$profiles.Add($v) }
        }
        foreach ($r in @($routing.mcp_rules)) {
            $v = ([string]$r.mcp).Trim()
            if (Test-AdvisoryIdentifier -Value $v) { [void]$mcps.Add($v) }
        }
    }

    if ($ok) {
        try {
            $adir = Join-Path $root 'source\agents'
            if (-not (Test-Path -LiteralPath $adir -PathType Container)) { $ok = $false }
            else {
                foreach ($f in @(Get-ChildItem -LiteralPath $adir -Filter '*.md' -File)) {
                    $n = [string]$f.BaseName
                    if (Test-AdvisoryIdentifier -Value $n) { [void]$agents.Add($n) }
                }
            }
        }
        catch { $ok = $false }
    }

    if ($ok) {
        try {
            $p = Join-Path $root 'source\registry\skills-catalog.json'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $ok = $false }
            else {
                $cat = ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json)
                foreach ($s in @($cat.skills)) {
                    $v = ([string]$s.id).Trim()
                    if (Test-AdvisoryIdentifier -Value $v) { [void]$skills.Add($v) }
                }
            }
        }
        catch { $ok = $false }
    }

    if ($ok) {
        try {
            $p = Join-Path $root 'source\registry\mcp-profiles.json'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $ok = $false }
            else {
                $mp = ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json)
                foreach ($pr in @($mp.profiles)) {
                    $v = ([string]$pr.id).Trim()
                    if (Test-AdvisoryIdentifier -Value $v) { [void]$profiles.Add($v) }
                    foreach ($m in @($pr.mcps)) {
                        $mv = ([string]$m).Trim()
                        if (Test-AdvisoryIdentifier -Value $mv) { [void]$mcps.Add($mv) }
                    }
                }
            }
        }
        catch { $ok = $false }
    }

    if ($ok) {
        if ($agents.Count -lt 1 -or $skills.Count -lt 1 -or $profiles.Count -lt 1 -or $mcps.Count -lt 1) { $ok = $false }
    }
    return @{ ok = $ok; agents = $agents; skills = $skills; profiles = $profiles; mcps = $mcps }
}

function Test-AdvisoryKnownCapabilityId {
    <#
    .SYNOPSIS
        True somente para identificador presente na allowlist do conjunto.
    .DESCRIPTION
        Allowlist ausente/nao carregada (ok=false) ou conjunto vazio => false
        (fail-closed: nada e ecoado sem comprovacao de origem conhecida).
    #>
    [CmdletBinding()]
    param([string]$Value = '', [string]$SetName = '', [hashtable]$Allowlist = $null)
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    if ($null -eq $Allowlist) { return $false }
    if (-not $Allowlist.ContainsKey('ok')) { return $false }
    if (-not [bool]$Allowlist['ok']) { return $false }
    $name = ([string]$SetName).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    if (-not $Allowlist.ContainsKey($name)) { return $false }
    $known = $Allowlist[$name]
    if ($null -eq $known) { return $false }
    return $known.Contains($s)
}

function Get-AdvisorySensitiveKeyPattern {
    <#
    .SYNOPSIS
        Regex de nome de chave sensivel (espelha CapabilitySanitize.ps1).
    #>
    [CmdletBinding()]
    param()
    return '(?i)(token|secret|password|passwd|passphrase|apikey|api_key|api-key|authorization|auth|cookie|bearer|jwt|session|private_key|secret_key|access_key|refresh_token|connectionstring|connection_string|client_secret|credential)'
}

function Get-AdvisoryIdentifierArray {
    <#
    .SYNOPSIS
        Valida array de identificadores CONHECIDOS: dedup + ordenacao ordinal.
    .DESCRIPTION
        Escalar (string) nao e aceito: o schema do stream exige array. Item
        invalido, item de tipo nao-string (numero/bool/objeto), item nulo,
        item fora da allowlist de capabilities ou excesso de itens => falha
        (sem truncamento silencioso). Devolve
        @{ ok = bool; items = string[]; reason = string }.
    #>
    [CmdletBinding()]
    param($Value = $null, [int]$MaxItems = 16, [string]$SetName = '', [hashtable]$Allowlist = $null)
    $fail = @{ ok = $false; items = @(); reason = 'INVALID_IDENTIFIER' }
    if ($null -eq $Value) { return $fail }
    if ($Value -is [string]) { return $fail }
    $raw = @()
    try { $raw = @($Value) } catch { return $fail }
    if ($raw.Count -gt $MaxItems) { return @{ ok = $false; items = @(); reason = 'OVERSIZED_ARRAY' } }
    # Nome de variavel no PowerShell NAO distingue caixa: qualquer coalescao
    # local com nome semelhante ao do parametro ($SetName, $Set, ...) sobrescreveria
    # o parametro dentro do mesmo escopo e TODO identificador conhecido viraria
    # INVALID_IDENTIFIER. O conjunto local usa nome unico, sem relacao de caixa
    # com $SetName.
    $identifierSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $raw) {
        if ($item -isnot [string]) { return $fail }
        $s = [string]$item
        if (-not (Test-AdvisoryIdentifier -Value $s)) { return $fail }
        if ($s.Length -gt 64) { return $fail }
        if (-not (Test-AdvisoryKnownCapabilityId -Value $s -SetName $SetName -Allowlist $Allowlist)) { return $fail }
        [void]$identifierSet.Add($s.Trim())
    }
    return @{ ok = $true; items = @(Get-AdvisorySortedStrings -Values @($identifierSet)); reason = '' }
}

function Get-AdvisoryReadKeyNames {
    <#
    .SYNOPSIS
        Conjunto dos nomes de campo LIDOS pelo collector (comparacao ordinal).
    .DESCRIPTION
        Usado somente para detectar repeticao de nome lido na linha crua, na
        chave DECODIFICADA. Chave fora deste conjunto nunca e projetada, entao
        repeticao dela nao altera resultado (nao ha escolha first/last-wins).
    #>
    [CmdletBinding()]
    param()
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($n in @('task_id', 'task_key', 'task_class', 'profiles', 'agents', 'skills', 'risk', 'confidence', 'mode', 'at', 'provenance', 'claimed_agent', 'claimed_skills', 'claimed_mcps')) {
        [void]$set.Add([string]$n)
    }
    return $set
}

function Convert-AdvisoryJsonEscapedText {
    <#
    .SYNOPSIS
        Decodifica escapes JSON de texto (conteudo cru de um token de string
        capturado pelo scanner lexical).
    .DESCRIPTION
        Cobre barra-invertida, aspas, barra, \b \f \n \r \t e \uXXXX (com par
        surrogate). Texto sem barra volta intocado (caminho comum). Nada daqui
        ecoa valor: o retorno so e comparado contra o conjunto de nomes lidos.
    #>
    [CmdletBinding()]
    param([string]$Value = '')
    $s = [string]$Value
    if ($s.IndexOf('\') -lt 0) { return $s }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -ne '\' -or ($i + 1) -ge $s.Length) { [void]$sb.Append($c); $i += 1; continue }
        $n = $s[$i + 1]
        if ($n -ceq 'n') { [void]$sb.Append([char]10); $i += 2; continue }
        if ($n -ceq 'r') { [void]$sb.Append([char]13); $i += 2; continue }
        if ($n -ceq 't') { [void]$sb.Append([char]9); $i += 2; continue }
        if ($n -ceq 'b') { [void]$sb.Append([char]8); $i += 2; continue }
        if ($n -ceq 'f') { [void]$sb.Append([char]12); $i += 2; continue }
        if ($n -ceq '/') { [void]$sb.Append('/'); $i += 2; continue }
        if ($n -ceq '\') { [void]$sb.Append('\'); $i += 2; continue }
        if ($n -ceq '"') { [void]$sb.Append('"'); $i += 2; continue }
        if ($n -ceq 'u' -and ($i + 6) -le $s.Length) {
            $code = 0
            $hex = $s.Substring($i + 2, 4)
            if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                if ($code -ge 0xD800 -and $code -le 0xDBFF -and ($i + 12) -le $s.Length -and $s[$i + 6] -ceq '\' -and $s[$i + 7] -ceq 'u') {
                    $lo = 0
                    $hex2 = $s.Substring($i + 8, 4)
                    if ([int]::TryParse($hex2, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$lo)) {
                        $code = 0x10000 + (($code - 0xD800) * 0x400) + ($lo - 0xDC00)
                        $i += 12
                    }
                    else { $i += 6 }
                }
                else { $i += 6 }
                try { [void]$sb.Append([char]::ConvertFromUtf32($code)) } catch { [void]$sb.Append('?') }
                continue
            }
        }
        [void]$sb.Append($c)
        $i += 1
    }
    return $sb.ToString()
}

function Test-AdvisoryRowDuplicateReadKey {
    <#
    .SYNOPSIS
        True se algum nome de campo LIDO aparece mais de uma vez na linha crua.
    .DESCRIPTION
        Scanner LEXICAL de passada unica (sem regex): custo O(n) no tamanho da
        linha, sem backtracking. O padrao regex anterior
        ('"((?:[^"\\]|\\.)*)"\s*:') tem custo dependente da engine (cadeia
        longa sem terminador forca backtracking) e foi substituido por este
        scanner, que anda a linha UMA vez: acha cada token de string
        respeitando escapes JSON, exige ':' depois do fecha-aspas para tratar
        o token como CHAVE, decodifica e compara contra o conjunto de nomes
        lidos.

        Repeticao de nome lido torna a linha ambigua, e a linha e rejeitada
        com DUPLICATE_KEY em vez de escolher silenciosamente um dos valores. A
        igualdade e na chave DECODIFICADA: 'task_id' e 'task\u005fid' sao a
        mesma chave e a linha e rejeitada (nada de first-wins/last-wins).

        Politica de duplicata aninhada (explicita): fail-closed conservador.
        Nao ha distincao de profundidade; objeto aninhado desconhecido que
        repetir um nome lido tambem rejeita a linha. Consequencia voluntaria:
        texto de um campo descartado que contenha algo como '"risk":' tambem
        rejeita. A direcao e sempre rejeitar, nunca aceitar ambiguidade; linhas
        reais do resolver e da observacao fornecida sao planas.
    #>
    [CmdletBinding()]
    param([string]$Raw = '')
    $s = [string]$Raw
    if ([string]::IsNullOrEmpty($s)) { return $false }
    $readKeys = Get-AdvisoryReadKeyNames
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $quote = [char]34
    $backslash = [char]92
    $colon = [char]58
    $tab = [char]9
    $cr = [char]13
    $lf = [char]10
    $n = $s.Length
    $i = 0
    while ($i -lt $n) {
        if ($s[$i] -cne $quote) { $i += 1; continue }
        # Token de string: avanca ate o fecha-aspas respeitando escapes JSON.
        $j = $i + 1
        $closed = $false
        while ($j -lt $n) {
            if ($s[$j] -ceq $backslash) { $j += 2; continue }
            if ($s[$j] -ceq $quote) { $closed = $true; break }
            $j += 1
        }
        if (-not $closed) { break }
        # So vira CHAVE se houver ':' depois do fecha-aspas (com whitespace
        # JSON no meio). Valor de string nao e chave.
        $k = $j + 1
        while ($k -lt $n) {
            $c = $s[$k]
            if ($c -ceq ' ' -or $c -ceq $tab -or $c -ceq $cr -or $c -ceq $lf) { $k += 1; continue }
            break
        }
        if ($k -lt $n -and $s[$k] -ceq $colon) {
            $rawKey = $s.Substring($i + 1, $j - $i - 1)
            $decoded = (Convert-AdvisoryJsonEscapedText -Value $rawKey)
            if ($readKeys.Contains($decoded)) {
                if (-not $seen.Add($decoded)) { return $true }
            }
        }
        $i = $j + 1
    }
    return $false
}

function Test-AdvisoryRawRootIsObject {
    <#
    .SYNOPSIS
        True se o primeiro caractere nao-espaco da linha crua e '{'.
    .DESCRIPTION
        Defesa contra o unwrap do pipeline: em PS 5.1 e PS 7 um array JSON de
        UM objeto chega ao consumidor como o proprio objeto, e a checagem de
        tipo do no parseado nao distingue mais. So a raiz crua distingue. Array
        (de 1 ou de N elementos), numero, string e bool nao passam. Somente
        espaco, TAB, CR e LF sao pulados (whitespace valido de JSON).
    #>
    [CmdletBinding()]
    param([string]$Raw = '')
    $s = [string]$Raw
    if ([string]::IsNullOrEmpty($s)) { return $false }
    $s = $s.TrimStart(@([char]32, [char]9, [char]13, [char]10))
    if ($s.Length -le 0) { return $false }
    return ($s[0] -eq '{')
}

function Get-AdvisoryRowProjectionCounts {
    <#
    .SYNOPSIS
        Conta TODA chave de primeiro nivel fora da allowlist. Nenhum nome e devolvido.
    .DESCRIPTION
        Nome de chave de entrada e dado do produtor: ecoa-lo no relatorio
        seria um canal de vazamento (canario em nome de propriedade). Por isso
        a saida e apenas contagem: dropped (fora da allowlist, nao sensivel) e
        sensitive (nome com padrao sensivel, tambem contado e nao ecoado).
        A contagem cobre TODA propriedade desconhecida - inclusive nome com
        Unicode ou com mais de 64 caracteres: filtro de charset nesta altura
        faria a chave sumir ANTES da conta. Invariante: dropped + sensitive =
        numero de propriedades de primeiro nivel fora da allowlist.
    #>
    [CmdletBinding()]
    param($Node = $null, [string[]]$AllowKeys = @())
    $dropped = 0
    $sensitive = 0
    foreach ($k in @(Get-AdvisoryJsonKeys -Node $Node)) {
        if (@($AllowKeys) -ccontains $k) { continue }
        if ($k -match (Get-AdvisorySensitiveKeyPattern)) { $sensitive += 1; continue }
        $dropped += 1
    }
    return @{ dropped = [int]$dropped; sensitive = [int]$sensitive }
}

function New-AdvisoryRowReject {
    <#
    .SYNOPSIS
        Resultado de rejeicao de linha, preservando as contagens de projecao.
    #>
    [CmdletBinding()]
    param([string]$Reason = '', [hashtable]$Notes = $null)
    $d = 0
    $s = 0
    if ($null -ne $Notes) { $d = [int]$Notes.dropped; $s = [int]$Notes.sensitive }
    return @{ ok = $false; reason = [string]$Reason; record = $null; dropped = $d; sensitive = $s }
}

function Convert-AdvisoryResolverRow {
    <#
    .SYNOPSIS
        Projeta uma linha do resolver para a allowlist (RECOMENDACAO apenas).
    .DESCRIPTION
        Aceita: task_id (16 hex, prefixo 'sha256:' normalizado), task_class,
        risk, confidence, mode='shadow', at (ISO-UTC round-trip) e arrays
        profiles/agents/skills de identificadores CONHECIDOS (allowlist de
        capabilities). Campos textuais exigem JSON string: sem coercao de
        numero/bool/objeto para texto. Qualquer outro campo de entrada e
        descartado (nunca projetado), e apenas CONTADO. Falha devolve
        @{ ok=$false; reason=<enum>; dropped=int; sensitive=int } - a primeira
        falha em ordem fixa.
    #>
    [CmdletBinding()]
    param($Node = $null, [int]$MaxItems = 16, [hashtable]$Allowlist = $null)
    $allowKeys = @('task_id', 'task_class', 'profiles', 'agents', 'skills', 'risk', 'confidence', 'mode', 'at')
    if (-not (Get-AdvisoryIsJsonObject -Node $Node)) {
        return @{ ok = $false; reason = 'NOT_AN_OBJECT'; record = $null; dropped = 0; sensitive = 0 }
    }
    $notes = Get-AdvisoryRowProjectionCounts -Node $Node -AllowKeys $allowKeys
    $keyField = Get-AdvisoryStringField -Node $Node -Field 'task_id'
    if (-not $keyField.found) { return (New-AdvisoryRowReject -Reason 'MISSING_TASK_KEY' -Notes $notes) }
    if (-not $keyField.isString) { return (New-AdvisoryRowReject -Reason 'INVALID_TASK_KEY_FORMAT' -Notes $notes) }
    if ([string]::IsNullOrWhiteSpace($keyField.value)) { return (New-AdvisoryRowReject -Reason 'MISSING_TASK_KEY' -Notes $notes) }
    $taskKey = Get-AdvisoryNormalizedTaskKey -Value $keyField.value
    if ([string]::IsNullOrWhiteSpace($taskKey)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_KEY_FORMAT' -Notes $notes)
    }
    $classes = @(Get-AdvisoryTaskClasses)
    $taskClass = 'unknown'
    $classField = Get-AdvisoryStringField -Node $Node -Field 'task_class'
    if (-not $classField.isString -or [string]::IsNullOrWhiteSpace($classField.value)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_CLASS' -Notes $notes)
    }
    $c = $classField.value.Trim().ToLowerInvariant()
    if ($classes -cnotcontains $c) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_CLASS' -Notes $notes)
    }
    $taskClass = $c
    $risks = @(Get-AdvisoryRiskLevels)
    $risk = ''
    $riskField = Get-AdvisoryStringField -Node $Node -Field 'risk'
    if (-not $riskField.isString -or [string]::IsNullOrWhiteSpace($riskField.value)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_RISK' -Notes $notes)
    }
    $r = $riskField.value.Trim().ToUpperInvariant()
    if ($risks -cnotcontains $r) {
        return (New-AdvisoryRowReject -Reason 'INVALID_RISK' -Notes $notes)
    }
    $risk = $r
    $confs = @(Get-AdvisoryConfidenceLevels)
    $conf = ''
    $confField = Get-AdvisoryStringField -Node $Node -Field 'confidence'
    if (-not $confField.isString -or [string]::IsNullOrWhiteSpace($confField.value)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_CONFIDENCE' -Notes $notes)
    }
    $cf = $confField.value.Trim().ToUpperInvariant()
    if ($confs -cnotcontains $cf) {
        return (New-AdvisoryRowReject -Reason 'INVALID_CONFIDENCE' -Notes $notes)
    }
    $conf = $cf
    $modeField = Get-AdvisoryStringField -Node $Node -Field 'mode'
    if (-not $modeField.isString -or [string]::IsNullOrWhiteSpace($modeField.value)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_MODE' -Notes $notes)
    }
    $mode = $modeField.value.Trim().ToLowerInvariant()
    if (@(Get-AdvisoryModes) -cnotcontains $mode) {
        return (New-AdvisoryRowReject -Reason 'INVALID_MODE' -Notes $notes)
    }
    $rawAt = (Get-AdvisoryJsonField -Node $Node -Field 'at').value
    if (-not (Test-AdvisoryTimestamp -Value $rawAt)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TIMESTAMP' -Notes $notes)
    }
    $arrays = @{}
    foreach ($field in @('profiles', 'agents', 'skills')) {
        $val = (Get-AdvisoryJsonField -Node $Node -Field $field).value
        if ($null -eq $val) { $arrays[$field] = @(); continue }
        $parsed = Get-AdvisoryIdentifierArray -Value $val -MaxItems $MaxItems -SetName $field -Allowlist $Allowlist
        if (-not $parsed.ok) {
            return (New-AdvisoryRowReject -Reason ([string]$parsed.reason) -Notes $notes)
        }
        $arrays[$field] = @($parsed.items)
    }
    $record = @{
        task_key     = $taskKey
        task_class   = $taskClass
        risk         = $risk
        confidence   = $conf
        mode         = $mode
        profiles     = @($arrays['profiles'])
        agents       = @($arrays['agents'])
        skills       = @($arrays['skills'])
    }
    return @{ ok = $true; reason = ''; record = $record; dropped = [int]$notes.dropped; sensitive = [int]$notes.sensitive }
}

function Convert-AdvisoryObservationRow {
    <#
    .SYNOPSIS
        Projeta um registro de observacao FORNECIDO (opt-in).
    .DESCRIPTION
        Exige provenance explicita 'supplied'; sem isso o registro e
        rejeitado (UNSUPPORTED_PROVENANCE) e nunca vira observacao real. O
        rotulo de confianca e sempre SUPPLIED_UNVERIFIED: esta ferramenta nao
        autentica o produtor, portanto nada aqui e RUNTIME_OBSERVED/VERIFIED.
        'outcome' e qualquer campo fora da allowlist sao descartados (nunca
        usados para metrica de acordo/adesao/sucesso). Identificadores
        reivindicados passam pela mesma allowlist de capabilities conhecidas.
        Campos textuais exigem JSON string (sem coercao).
    #>
    [CmdletBinding()]
    param($Node = $null, [int]$MaxItems = 16, [hashtable]$Allowlist = $null)
    $allowKeys = @('provenance', 'task_key', 'task_id', 'task_class', 'claimed_agent', 'claimed_skills', 'claimed_mcps')
    if (-not (Get-AdvisoryIsJsonObject -Node $Node)) {
        return @{ ok = $false; reason = 'NOT_AN_OBJECT'; record = $null; dropped = 0; sensitive = 0 }
    }
    $notes = Get-AdvisoryRowProjectionCounts -Node $Node -AllowKeys $allowKeys
    $provField = Get-AdvisoryStringField -Node $Node -Field 'provenance'
    if (-not $provField.isString) {
        return (New-AdvisoryRowReject -Reason 'UNSUPPORTED_PROVENANCE' -Notes $notes)
    }
    if ($provField.value.Trim().ToLowerInvariant() -cne 'supplied') {
        return (New-AdvisoryRowReject -Reason 'UNSUPPORTED_PROVENANCE' -Notes $notes)
    }
    $keyField = Get-AdvisoryStringField -Node $Node -Field 'task_key'
    if (-not $keyField.found) { $keyField = Get-AdvisoryStringField -Node $Node -Field 'task_id' }
    if (-not $keyField.found) {
        return (New-AdvisoryRowReject -Reason 'MISSING_TASK_KEY' -Notes $notes)
    }
    if (-not $keyField.isString) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_KEY_FORMAT' -Notes $notes)
    }
    if ([string]::IsNullOrWhiteSpace($keyField.value)) {
        return (New-AdvisoryRowReject -Reason 'MISSING_TASK_KEY' -Notes $notes)
    }
    $taskKey = Get-AdvisoryNormalizedTaskKey -Value $keyField.value
    if ([string]::IsNullOrWhiteSpace($taskKey)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_KEY_FORMAT' -Notes $notes)
    }
    $classes = @(Get-AdvisoryTaskClasses)
    $taskClass = 'unknown'
    $classField = Get-AdvisoryStringField -Node $Node -Field 'task_class'
    if (-not $classField.found) {
        $taskClass = 'unknown'
    }
    elseif (-not $classField.isString -or [string]::IsNullOrWhiteSpace($classField.value)) {
        return (New-AdvisoryRowReject -Reason 'INVALID_TASK_CLASS' -Notes $notes)
    }
    else {
        $c = $classField.value.Trim().ToLowerInvariant()
        if ($classes -cnotcontains $c) {
            return (New-AdvisoryRowReject -Reason 'INVALID_TASK_CLASS' -Notes $notes)
        }
        $taskClass = $c
    }
    $claimedAgent = ''
    $agentField = Get-AdvisoryStringField -Node $Node -Field 'claimed_agent'
    if ($agentField.found) {
        if (-not $agentField.isString -or -not (Test-AdvisoryIdentifier -Value $agentField.value)) {
            return (New-AdvisoryRowReject -Reason 'INVALID_IDENTIFIER' -Notes $notes)
        }
        if (-not (Test-AdvisoryKnownCapabilityId -Value $agentField.value -SetName 'agents' -Allowlist $Allowlist)) {
            return (New-AdvisoryRowReject -Reason 'INVALID_IDENTIFIER' -Notes $notes)
        }
        $claimedAgent = $agentField.value.Trim()
    }
    $claimed = @{}
    foreach ($field in @('claimed_skills', 'claimed_mcps')) {
        $val = (Get-AdvisoryJsonField -Node $Node -Field $field).value
        if ($null -eq $val) { $claimed[$field] = @(); continue }
        $setName = 'skills'
        if ($field -ceq 'claimed_mcps') { $setName = 'mcps' }
        $parsed = Get-AdvisoryIdentifierArray -Value $val -MaxItems $MaxItems -SetName $setName -Allowlist $Allowlist
        if (-not $parsed.ok) {
            return (New-AdvisoryRowReject -Reason ([string]$parsed.reason) -Notes $notes)
        }
        $claimed[$field] = @($parsed.items)
    }
    $record = @{
        task_key       = $taskKey
        provenance     = 'supplied'
        trust          = 'SUPPLIED_UNVERIFIED'
        task_class     = $taskClass
        claimed_agent  = $claimedAgent
        claimed_skills = @($claimed['claimed_skills'])
        claimed_mcps   = @($claimed['claimed_mcps'])
    }
    return @{ ok = $true; reason = ''; record = $record; dropped = [int]$notes.dropped; sensitive = [int]$notes.sensitive }
}

function Test-AdvisoryStreamAtEnd {
    <#
    .SYNOPSIS
        True somente se o stream nao tem mais nenhum byte para ler.
    .DESCRIPTION
        Usa Position/Length (metadado do stream: nao consome, nao aloca e nao
        le byte algum) para distinguir duas situacoes que o orcamento de bytes
        sozinho confunde:

          (a) EOF EXATO no ultimo byte do orcamento - o stream acabou ali, a
              linha pendente e a ULTIMA linha do arquivo e esta COMPLETA: ela
              deve ser aceita (truncar seria falso truncation);
          (b) ainda existem bytes ALEM do orcamento - a linha em curso esta
              incompleta e descarta-la e truncamento real, disclosed pelo
              chamador (LIMIT_EXCEEDED + bytes_cap_reached).

        Stream sem seek/Length, excecao de IO ou stream nulo devolve false:
        a direcao conservadora e truncar e disclosed, NUNCA aceitar linha que
        talvez esteja incompleta.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)
    try {
        if ($null -eq $Stream) { return $false }
        if (-not $Stream.CanSeek) { return $false }
        $pos = $Stream.Position
        $len = $Stream.Length
        return ([int64]$pos -ge [int64]$len)
    }
    catch { return $false }
}

function New-AdvisoryBoundedLineReader {
    <#
    .SYNOPSIS
        Leitor de linhas JSONL limitado por BYTES (nunca por linha toda).
    .DESCRIPTION
        O StreamReader.ReadLine alocava a linha inteira antes de qualquer
        checagem de cap: uma linha de 1 GB entrava na memoria antes de ser
        rejeitada, e o cap de bytes total era conferido contra o tamanho do
        arquivo lido ANTES da leitura (stale sob crescimento concorrente).

        Este leitor:
          - le blocos de 4096 bytes e monta a linha em buffer proprio de
            tamanho fixo (line_bytes + 1), entao a memoria por linha e limitada
            por policy, nao pelo produtor;
          - conta bytes e linhas REALMENTE examinados ($reader.bytesExamined);
          - sinaliza overflow sem materializar o resto da linha;
          - trata CRLF, LF sozinho, UTF-8 (invalido falha fechado) e BOM;
          - devolve 'limit' quando o orcamento de bytes do arquivo estoura.
        Nenhum corte de string e feito com split/slice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [int]$MaxLineBytes = 32768,
        [int64]$MaxTotalBytes = 8388608
    )
    $cap = [int]$MaxLineBytes
    if ($cap -lt 1) { $cap = 1 }
    $total = [int64]$MaxTotalBytes
    if ($total -lt 1) { $total = 1 }
    return @{
        stream       = $Stream
        buffer       = (New-Object 'byte[]' 4096)
        bufferLen    = 0
        bufferPos    = 0
        eof          = $false
        lineBuf      = (New-Object 'byte[]' ($cap + 1))
        maxLineBytes = $cap
        maxTotalBytes = $total
        lineLen      = 0
        startOfFile  = $true
        skipLF       = $false
        budgetStop   = $false
        encoding     = (New-Object System.Text.UTF8Encoding($false, $true))
        bytesExamined = [long]0
    }
}

function Read-AdvisoryBoundedLine {
    <#
    .SYNOPSIS
        Le a proxima linha do leitor limitado por bytes.
    .DESCRIPTION
        Devolve hashtable @{ kind; text; bytes; overflow; decodeFailed } com:
          kind = 'line'  -> linha completa (text pode ser vazio); a ULTIMA
                            linha do arquivo tambem volta 'line' mesmo sem
                            terminador final;
          kind = 'eof'   -> fim de arquivo sem bytes pendentes;
          kind = 'limit' -> existem bytes ALEM do orcamento de bytes (a linha
                           em curso esta incompleta, e descartada, nunca
                           parseada). EOF EXATO no ultimo byte do orcamento
                           NAO gera 'limit': a linha final esta completa;
          kind = 'error' -> falha de IO no meio da leitura.
        'bytes' conta os bytes consumidos desta linha (terminador e overflow
        inclusos); o total examinado fica em $Reader.bytesExamined.

        Sem linha fantasma: quando o ultimo byte do arquivo e o LF que fecha o
        CRLF da ultima linha, a proxima chamada devolve 'eof' - um arquivo
        "linha\r\n" tem UMA linha, nao duas. Sem isso, a linha vazia fantasma
        so aparecia no relatorio (era engolida pela contagem de vazias) ou
        inflava lines_read.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Reader)
    $st = $Reader
    if ([int64]$st.bytesExamined -gt [int64]$st.maxTotalBytes) {
        return @{ kind = 'limit'; text = ''; bytes = 0; overflow = $false; decodeFailed = $false }
    }
    if ($st.startOfFile) {
        while (($st.bufferLen - $st.bufferPos) -lt 3 -and -not $st.eof) {
            $remaining = ([int64]$st.maxTotalBytes) - ([int64]$st.bytesExamined)
            if ($remaining -le 0) { $st.eof = $true; $st.budgetStop = $true; break }
            $want = [int]($st.buffer.Length - $st.bufferLen)
            if ([int64]$want -gt $remaining) { $want = [int]$remaining }
            $n = 0
            try { $n = $st.stream.Read($st.buffer, $st.bufferLen, $want) }
            catch { return @{ kind = 'error'; text = ''; bytes = 0; overflow = $false; decodeFailed = $false } }
            if ($n -le 0) { $st.eof = $true; break }
            $st.bufferLen = ([int]$st.bufferLen) + [int]$n
            $st.bytesExamined = ([int64]$st.bytesExamined) + [int64]$n
        }
        if (($st.bufferLen - $st.bufferPos) -ge 3 -and
            [int]$st.buffer[$st.bufferPos] -eq 239 -and
            [int]$st.buffer[$st.bufferPos + 1] -eq 187 -and
            [int]$st.buffer[$st.bufferPos + 2] -eq 191) {
            $st.bufferPos = ([int]$st.bufferPos) + 3
        }
        $st.startOfFile = $false
    }
    $bytesThisLine = 0
    $overflow = $false
    while ($true) {
        if ($st.bufferPos -ge $st.bufferLen) {
            if ($st.eof) {
                if ($st.budgetStop) {
                    # Orcamento esgotado exatamente aqui. DUAS situacoes
                    # distintas, separadas sem consumir byte alem do orcamento
                    # (Position/Length sao metadados):
                    #   (a) o stream tambem acabou (EOF EXATO no fim do
                    #       orcamento): a linha pendente e a ULTIMA linha do
                    #       arquivo, COMPLETA, e e aceita - truncar aqui seria
                    #       falso truncation;
                    #   (b) ainda ha bytes ALEM do orcamento: a linha em curso
                    #       esta incompleta, e DESCARTADA (nunca parseada); a
                    #       omissao e explicitada pelo chamador como
                    #       LIMIT_EXCEEDED + bytes_cap_reached.
                    if (Test-AdvisoryStreamAtEnd -Stream $st.stream) {
                        $st.budgetStop = $false
                        $st.eof = $true
                        if ([int]$st.lineLen -le 0 -and $bytesThisLine -le 0) {
                            $st.skipLF = $false
                            return @{ kind = 'eof'; text = ''; bytes = 0; overflow = $false; decodeFailed = $false }
                        }
                        break
                    }
                    $st.lineLen = 0
                    $st.skipLF = $false
                    return @{ kind = 'limit'; text = ''; bytes = $bytesThisLine; overflow = $false; decodeFailed = $false }
                }
                if ([int]$st.lineLen -le 0 -and $bytesThisLine -le 0) {
                    return @{ kind = 'eof'; text = ''; bytes = 0; overflow = $false; decodeFailed = $false }
                }
                break
            }
            $st.bufferPos = 0
            $st.bufferLen = 0
            # A leitura nunca passa do orcamento de bytes: bytesExamined so
            # cresce enquanto ha orcamento, entao o tamanho reportado e sempre o
            # que foi realmente examinado (nunca o tamanho do arquivo).
            $remaining = ([int64]$st.maxTotalBytes) - ([int64]$st.bytesExamined)
            if ($remaining -le 0) {
                $st.eof = $true
                $st.budgetStop = $true
                continue
            }
            $want = [int]$st.buffer.Length
            if ([int64]$want -gt $remaining) { $want = [int]$remaining }
            $n = 0
            try { $n = $st.stream.Read($st.buffer, 0, $want) }
            catch { return @{ kind = 'error'; text = ''; bytes = $bytesThisLine; overflow = $overflow; decodeFailed = $false } }
            if ($n -le 0) { $st.eof = $true; continue }
            $st.bufferLen = [int]$n
            $st.bytesExamined = ([int64]$st.bytesExamined) + [int64]$n
        }
        $b = [int]$st.buffer[$st.bufferPos]
        $st.bufferPos = ([int]$st.bufferPos) + 1
        $bytesThisLine += 1
        if ($st.skipLF) {
            # LF que fecha o CRLF aberto no bloco anterior: consumido aqui, NAO
            # inicia nova linha e nao conta nos bytes da proxima linha. Sem esse
            # ajuste um arquivo "linha\r\n" devolvia uma linha fantasma vazia no
            # fim (o LF ficava como unico byte de uma linha que nao existe).
            $st.skipLF = $false
            if ($b -eq 10) { $bytesThisLine -= 1; continue }
        }
        if ($b -eq 13) {
            # CR termina a linha (CRLF ou CR sozinho, como no StreamReader). O CR
            # nunca entra no conteudo, entao uma linha com exatamente line_bytes
            # bytes continua dentro do cap.
            $st.skipLF = $true
            break
        }
        if ($b -eq 10) { break }
        if ([int]$st.lineLen -lt [int]$st.maxLineBytes) {
            $st.lineBuf[[int]$st.lineLen] = [byte]$b
            $st.lineLen = ([int]$st.lineLen) + 1
        }
        else { $overflow = $true }
    }
    if ([int64]$st.bytesExamined -gt [int64]$st.maxTotalBytes) {
        # Rede de seguranca: com a leitura limitada pelo orcamento isto nao
        # deveria acontecer; se acontecer, a linha e descartada.
        $st.lineLen = 0
        return @{ kind = 'limit'; text = ''; bytes = $bytesThisLine; overflow = $overflow; decodeFailed = $false }
    }
    $text = ''
    $decodeFailed = $false
    if ([int]$st.lineLen -gt 0) {
        try { $text = $st.encoding.GetString($st.lineBuf, 0, [int]$st.lineLen) }
        catch { $decodeFailed = $true; $text = '' }
    }
    $st.lineLen = 0
    return @{ kind = 'line'; text = $text; bytes = $bytesThisLine; overflow = $overflow; decodeFailed = $decodeFailed }
}

function Get-AdvisoryCandidateRank {
    <#
    .SYNOPSIS
        Ordem total determinista entre dois candidatos (caminho + kind).
    .DESCRIPTION
        Compara o caminho completo na ordem ordinal ignorando caixa e usa o
        kind como desempate ('observation' antes de 'resolver'), para que a
        selecao do orcamento de arquivos seja estavel entre processos e entre
        runtimes - nada de ordenacao dependente de cultura ou de seed de hash
        por processo.
    #>
    [CmdletBinding()]
    param([string]$PathA = '', [string]$KindA = '', [string]$PathB = '', [string]$KindB = '')
    $c = [string]::Compare([string]$PathA, [string]$PathB, [System.StringComparison]::OrdinalIgnoreCase)
    if ($c -ne 0) { return $c }
    return [string]::Compare([string]$KindA, [string]$KindB, [System.StringComparison]::Ordinal)
}

function Select-AdvisoryCandidates {
    <#
    .SYNOPSIS
        Enumeracao GLOBAL de candidatos sob UM orcamento compartilhado de arquivos.
    .DESCRIPTION
        O cap 'files' e UM SO para a entrada inteira: os caminhos dos dois
        streams (resolver e observacao) concorrem aos MESMOS slots, e o array
        de detalhes do relatorio (inputs.files) nunca passa de FileCap
        entradas. Candidato = par (caminho completo, kind): o mesmo caminho
        pedido nos dois streams sao DOIS candidatos, porque cada um e uma
        leitura distinta e cada um gera a propria entrada de detalhe.

        No maximo FileCap candidatos distintos ficam retidos (os menores na
        ordem total de Get-AdvisoryCandidateRank). A entrada NAO e
        materializada: somente os arrays de entrada do chamador e os no maximo
        FileCap candidatos retidos ficam em memoria adicional.

        Omissao vira CONTAGEM bounded (omitted = ocorrencias vistas -
        candidatos distintos retidos), mesmo quando o candidato omitido seria
        rejeitado ou recusado mais tarde. Repeticoes contam como ocorrencias
        omitidas, inclusive se o par repetido foi retido; elas nao consomem
        slots nem mudam a selecao. Essa definicao torna a contagem independente
        da ordem sem guardar todos os candidatos.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ResolverPaths = @(),
        [string[]]$ObservationPaths = @(),
        [string]$Repo = '',
        [int]$FileCap = 8
    )
    $cap = [int]$FileCap
    if ($cap -lt 1) { $cap = 1 }
    $bestFull = New-Object 'string[]' $cap
    $bestKind = New-Object 'string[]' $cap
    $bestCount = 0
    $seen = 0
    foreach ($stream in @(@{ paths = $ResolverPaths; kind = 'resolver' }, @{ paths = $ObservationPaths; kind = 'observation' })) {
        foreach ($rawPathValue in $stream.paths) {
            if ($null -eq $rawPathValue) { continue }
            $rawPath = [string]$rawPathValue
            if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
            $full = Get-AdvisoryFullPath -Path $rawPath -RepoRoot $Repo
            if ([string]::IsNullOrWhiteSpace($full)) { continue }
            $kind = [string]$stream.kind
            $seen += 1
            $isDup = $false
            for ($bi = 0; $bi -lt $bestCount; $bi++) {
                if (([string]::Equals([string]$bestFull[$bi], $full, [System.StringComparison]::OrdinalIgnoreCase)) -and
                    ([string]$bestKind[$bi] -ceq $kind)) { $isDup = $true; break }
            }
            if ($isDup) { continue }
            if ($bestCount -lt $cap) {
                $pos = $bestCount
                for ($bi = 0; $bi -lt $bestCount; $bi++) {
                    if ((Get-AdvisoryCandidateRank -PathA ([string]$bestFull[$bi]) -KindA ([string]$bestKind[$bi]) -PathB $full -KindB $kind) -gt 0) { $pos = $bi; break }
                }
                for ($bi = $bestCount; $bi -gt $pos; $bi--) {
                    $bestFull[$bi] = $bestFull[$bi - 1]
                    $bestKind[$bi] = $bestKind[$bi - 1]
                }
                $bestFull[$pos] = $full
                $bestKind[$pos] = $kind
                $bestCount += 1
                continue
            }
            $last = $bestCount - 1
            if ((Get-AdvisoryCandidateRank -PathA ([string]$bestFull[$last]) -KindA ([string]$bestKind[$last]) -PathB $full -KindB $kind) -gt 0) {
                $bi = $last
                while ($bi -gt 0 -and (Get-AdvisoryCandidateRank -PathA ([string]$bestFull[$bi - 1]) -KindA ([string]$bestKind[$bi - 1]) -PathB $full -KindB $kind) -gt 0) {
                    $bestFull[$bi] = $bestFull[$bi - 1]
                    $bestKind[$bi] = $bestKind[$bi - 1]
                    $bi -= 1
                }
                $bestFull[$bi] = $full
                $bestKind[$bi] = $kind
            }
        }
    }
    $omitted = $seen - $bestCount
    if ($omitted -lt 0) { $omitted = 0 }
    $selected = New-Object System.Collections.ArrayList
    for ($bi = 0; $bi -lt $bestCount; $bi++) {
        [void]$selected.Add(@{ full = [string]$bestFull[$bi]; kind = [string]$bestKind[$bi] })
    }
    return @{ selected = $selected; seen = [int]$seen; omitted = [int]$omitted }
}

function Invoke-AdvisoryStreamRead {
    <#
    .SYNOPSIS
        Le um stream JSONL confinado e projeta as linhas validas.
    .DESCRIPTION
        Mutaciona o acumulador $Acc (files, failures, rejeicoes, chaves
        descartadas, registros, contadores). Nunca escreve em disco e nunca
        altera os arquivos de entrada.

        ENUMERACAO: a selecao de candidatos NAO acontece aqui. O orcamento de
        arquivos e UM SO para os DOIS streams e e aplicado antes, em
        Get-AdvisoryCollectorReport (Select-AdvisoryCandidates): $Paths chega
        ja limitado aos candidatos deste kind que sobreviveram ao cap global,
        e o array de detalhes do relatorio nunca passa de files entradas
        justamente porque a selecao e global. Omitidos (cap de arquivos ou de
        registros) viram CONTAGEM no acumulador (filesSkipped /
        filesOmittedByRecordsCap), nunca entrada sem limite no relatorio.
        Falha de confinamento/reparse/nome de kernel => fail-closed: arquivo
        RECUSADO, nunca lido.

        ORCAMENTO DE BYTES COMPARTILHADO: o leitor de cada arquivo recebe o
        que resta do orcamento (acc.bytesRemaining) e o consumo real e
        debitado. Sem bytes restantes, nenhum arquivo novo e lido e a omissao
        fica explicita (status truncado + LIMIT_EXCEEDED + bytes_cap_reached).

        CAP DE REGISTROS (global): quando atinge, a linha-sonda foi lida e
        conta; o resto do arquivo e examinado SEM projecao (so para que
        lines_read seja a verdade) e os candidatos seguintes NAO sao abertos -
        a omissao deles vira CONTAGEM (acc.filesOmittedByRecordsCap).

        Leitura streaming e limitada POR BYTES (leitor proprio, nunca
        StreamReader.ReadLine nem ReadAllText do arquivo inteiro): no maximo
        file_lines linhas examinadas por arquivo, line_bytes guardados por
        linha e o orcamento compartilhado de bytes realmente examinados.
        Nenhum array de linhas e materializado, portanto nao ha custo
        quadratico de split/fatiamento, e a memoria por linha nao depende do
        produtor.

        lines_read conta toda linha REALMENTE lida (validas, vazias,
        malformadas, linha-sonda de cap e linha parcial cortada pelo
        orcamento): lines_read = validas + rejeitadas + omitidas. Toda omissao
        fica explicita (status do arquivo, lines_omitted e os flags
        records_cap_reached / lines_cap_reached / bytes_cap_reached).

        Identificadores passam pela allowlist de capabilities ($Allowlist).
        Nenhum nome de arquivo/caminho e registrado no acumulador.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Paths = @(),
        [string]$Kind = 'resolver',
        [string]$Repo = '',
        [hashtable]$Limits = $null,
        [hashtable]$Acc = $null,
        [hashtable]$Allowlist = $null
    )
    if ($null -eq $Acc) { return }
    if ($null -eq $Limits) { $Limits = Get-AdvisoryCollectorLimits }
    if ($null -eq $Allowlist) {
        $Allowlist = @{ ok = $false; agents = $null; skills = $null; profiles = $null; mcps = $null }
    }
    $isObs = ($Kind -ceq 'observation')

    # --- caminhos ja selecionados pela enumeracao GLOBAL -----------------------
    # O orcamento de arquivos e UM SO, compartilhado pelos dois streams, e foi
    # aplicado em Get-AdvisoryCollectorReport. Aqui os caminhos so sao
    # normalizados para caminho completo; nada de materializar a entrada e nada
    # de nome/caminho no acumulador.
    $orderedList = New-Object System.Collections.ArrayList
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$p)) { continue }
        $full = Get-AdvisoryFullPath -Path ([string]$p) -RepoRoot $Repo
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        [void]$orderedList.Add($full)
    }
    $ordered = @($orderedList)

    $recordKey = 'resolverRecords'
    if ($isObs) { $recordKey = 'observationRecords' }
    $rejMap = $Acc.rejResolver
    if ($isObs) { $rejMap = $Acc.rejObservation }
    $linesAcc = 'linesResolver'
    if ($isObs) { $linesAcc = 'linesObservation' }
    $omittedAcc = 'resolverLinesOmitted'
    if ($isObs) { $omittedAcc = 'observationLinesOmitted' }
    $maxItems = [int]$Limits.array_items
    $linesCap = [int]$Limits.file_lines
    $toRead = New-Object System.Collections.ArrayList

    # --- fase 1: recusas baratas (nunca abrem o arquivo para leitura) -------
    foreach ($full in $ordered) {
        # Nenhum nome de arquivo/caminho entra no relatorio: so kind, status,
        # reason e contagens. Nome de arquivo e entrada do produtor.
        if (-not (Test-AdvisoryConfinedInput -Path $full -RepoRoot $Repo)) {
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'refused'; reason = 'OUTSIDE_ALLOWED_ROOT'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            [void]$Acc.failures.Add('OUTSIDE_ALLOWED_ROOT')
            continue
        }
        if (Test-AdvisoryKernelTelemetryName -Path $full) {
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'refused'; reason = 'KERNEL_TELEMETRY_REFUSED'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            [void]$Acc.failures.Add('KERNEL_TELEMETRY_REFUSED')
            continue
        }
        if (Test-AdvisoryPathHasReparsePoint -Path $full) {
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'refused'; reason = 'REPARSE_POINT_REFUSED'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            [void]$Acc.failures.Add('REPARSE_POINT_REFUSED')
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'refused'; reason = 'NOT_A_FILE'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            [void]$Acc.failures.Add('NOT_A_FILE')
            continue
        }
        [void]$toRead.Add($full)
    }

    # --- fase 2: leitura (caps globais de registros e orcamento de bytes) ----
    $omittedByRecords = 0
    for ($fi = 0; $fi -lt $toRead.Count; $fi++) {
        $full = [string]$toRead[$fi]
        if ([bool]$Acc.capHit) {
            # Cap global de registros ja atingido: candidato NAO e aberto e a
            # omissao e contada (files_omitted_by_records_cap).
            $omittedByRecords += ($toRead.Count - $fi)
            break
        }
        if ([int64]$Acc.bytesRemaining -le 0) {
            # Orcamento COMPARTILHADO esgotado: o arquivo nao e lido e a
            # omissao fica explicita (truncated + LIMIT_EXCEEDED).
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'truncated'; reason = 'LIMIT_EXCEEDED'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            $Acc.bytesCapHit = $true
            continue
        }
        $stream = $null
        $opened = $false
        try {
            # FileShare.Read: escritor concorrente (qualquer handle com acesso
            # de escrita) impede a abertura onde a plataforma suporta share
            # modes (Windows). Falhar a abertura aqui e fail-closed
            # (READ_FAILED): melhor recusar do que ler arquivo em escrita.
            $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $opened = $true
        }
        catch { $opened = $false }
        if (-not $opened) {
            if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
            [void]$Acc.files.Add([ordered]@{ kind = $Kind; status = 'refused'; reason = 'READ_FAILED'; lines_read = 0; lines_omitted = 0; records_valid = 0; records_rejected = 0; bytes = 0 })
            [void]$Acc.failures.Add('READ_FAILED')
            continue
        }
        $consumed = 0
        $truncated = $false
        $readError = $false
        $countOnly = $false
        $pendingBlank = 0
        $pendingOver = 0
        $validHere = 0
        $rejectedHere = 0
        $linesHere = 0
        $omittedHere = 0
        $lineReader = New-AdvisoryBoundedLineReader -Stream $stream -MaxLineBytes ([int]$Limits.line_bytes) -MaxTotalBytes ([int64]$Acc.bytesRemaining)
        try {
            # Leitura streaming linear POR BYTES: o leitor proprio devolve uma
            # linha por vez, sem ReadAllText/split e sem fatiamento de array, e
            # nunca guarda mais que line_bytes de uma linha. Linhas vazias
            # ficam pendentes e so sao contadas quando uma linha nao-vazia
            # aparecer (ou no fim do arquivo/ponto de parada): foram lidas,
            # portanto contam como examinadas e rejeitadas (EMPTY_ROW).
            while ($true) {
                $line = Read-AdvisoryBoundedLine -Reader $lineReader
                if ($line.kind -ceq 'eof') { break }
                if ($line.kind -ceq 'error') {
                    # IO no meio da leitura: o contrato do coletor e nunca
                    # lancar. A omissao fica explicita (READ_FAILED + status).
                    $readError = $true
                    break
                }
                if ($line.kind -ceq 'limit') {
                    # Orcamento COMPARTILHADO estourou no meio de uma linha: a
                    # linha parcial foi lida (bytes contados) e DESCARTADA.
                    $truncated = $true
                    $Acc.bytesCapHit = $true
                    if ([int64]$line.bytes -gt 0) {
                        $consumed += 1
                        $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                        $linesHere += 1
                        $omittedHere += 1
                    }
                    break
                }
                $consumed += 1
                if ($consumed -gt $linesCap) {
                    # Linha-sonda do cap de linhas: foi LIDA (bytes realmente
                    # examinados) e conta em lines_read; a omissao e sinalizada
                    # por lines_cap_reached + lines_omitted.
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $omittedHere += 1
                    $truncated = $true
                    $Acc.linesCapHit = $true
                    break
                }
                if ((-not $countOnly) -and ([int]$Acc.recordsValid -ge [int]$Limits.records)) {
                    # Cap GLOBAL de registros: a linha-sonda foi lida e conta;
                    # daqui em diante o arquivo e examinado SEM projecao, so
                    # para que lines_read reflita o trabalho realmente feito.
                    $Acc.capHit = $true
                    $truncated = $true
                    $countOnly = $true
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $omittedHere += 1
                    continue
                }
                # Linha acima de line_bytes: bytes examinados e contados,
                # linha descartada sem parse (nada foi materializado alem do
                # cap).
                if ([bool]$line.overflow) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key 'OVERSIZED_ROW'
                    continue
                }
                # UTF-8 invalido: falha fechada, linha rejeitada (nunca aceita
                # com caractere de substituicao).
                if ([bool]$line.decodeFailed) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key 'MALFORMED_JSON'
                    continue
                }
                $raw = [string]$line.text
                if ([string]::IsNullOrWhiteSpace($raw)) {
                    $pendingBlank += 1
                    if ([int]$line.bytes -gt [int]$Limits.line_bytes) { $pendingOver += 1 }
                    continue
                }
                if ($pendingBlank -gt 0) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + $pendingBlank
                    $linesHere += $pendingBlank
                    $rejectedHere += $pendingBlank
                    $emptyCount = $pendingBlank - $pendingOver
                    if ($emptyCount -gt 0) { Add-AdvisoryCount -Map $rejMap -Key 'EMPTY_ROW' -Count $emptyCount }
                    if ($pendingOver -gt 0) { Add-AdvisoryCount -Map $rejMap -Key 'OVERSIZED_ROW' -Count $pendingOver }
                    $pendingBlank = 0
                    $pendingOver = 0
                }
                if ($countOnly) {
                    # Exame sem projecao (cap de registros ja atingido): a
                    # linha foi lida e omitida, e a omissao e contada.
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $omittedHere += 1
                    continue
                }
                $obj = $null
                $parsed = $false
                try { $obj = ($raw | ConvertFrom-Json); $parsed = $true }
                catch { $parsed = $false }
                if (-not $parsed) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key 'MALFORMED_JSON'
                    continue
                }
                # Raiz tem de ser OBJETO, olhando a linha crua E o no parseado:
                # sem a raiz crua, um array de 1 objeto passaria pelo unwrap do
                # pipeline do PowerShell (PS 5.1 e PS 7) como se fosse objeto.
                # Ordem deliberada: DEPOIS do parse (para que texto que nao e
                # JSON seja MALFORMED_JSON, nao NOT_AN_OBJECT) e ANTES da
                # duplicata (para que raiz nao-objeto seja NOT_AN_OBJECT, nao
                # DUPLICATE_KEY).
                if ((-not (Test-AdvisoryRawRootIsObject -Raw $raw)) -or (-not (Get-AdvisoryIsJsonObject -Node $obj))) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key 'NOT_AN_OBJECT'
                    continue
                }
                if (Test-AdvisoryRowDuplicateReadKey -Raw $raw) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key 'DUPLICATE_KEY'
                    continue
                }
                if ($isObs) {
                    $res = Convert-AdvisoryObservationRow -Node $obj -MaxItems $maxItems -Allowlist $Allowlist
                }
                else {
                    $res = Convert-AdvisoryResolverRow -Node $obj -MaxItems $maxItems -Allowlist $Allowlist
                }
                $Acc.droppedKeys = ([int]$Acc.droppedKeys) + [int]$res.dropped
                $Acc.sensitiveDropped = ([int]$Acc.sensitiveDropped) + [int]$res.sensitive
                if (-not $res.ok) {
                    $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                    $linesHere += 1
                    $rejectedHere += 1
                    Add-AdvisoryCount -Map $rejMap -Key (Get-AdvisorySafeReason -Reason $res.reason)
                    continue
                }
                $Acc.$linesAcc = ([int]$Acc.$linesAcc) + 1
                $linesHere += 1
                $validHere += 1
                $Acc.recordsValid = ([int]$Acc.recordsValid) + 1
                [void]$Acc.$recordKey.Add($res.record)
            }
            # Linhas vazias pendentes (fim do arquivo ou ponto de parada por
            # cap/IO) foram REALMENTE lidas: contam como examinadas e como
            # rejeitadas - lines_read nunca finge menos trabalho do que foi
            # feito.
            if ($pendingBlank -gt 0) {
                $Acc.$linesAcc = ([int]$Acc.$linesAcc) + $pendingBlank
                $linesHere += $pendingBlank
                $rejectedHere += $pendingBlank
                $emptyCount = $pendingBlank - $pendingOver
                if ($emptyCount -gt 0) { Add-AdvisoryCount -Map $rejMap -Key 'EMPTY_ROW' -Count $emptyCount }
                if ($pendingOver -gt 0) { Add-AdvisoryCount -Map $rejMap -Key 'OVERSIZED_ROW' -Count $pendingOver }
            }
        }
        finally {
            try { if ($null -ne $stream) { $stream.Dispose() } } catch { }
        }
        if ($readError) {
            $truncated = $true
            [void]$Acc.failures.Add('READ_FAILED')
        }
        # Debito real do orcamento COMPARTILHADO: so o que foi examinado de
        # fato sai do orcamento (nunca o tamanho do arquivo medido antes).
        $bytesHere = [int64]$lineReader.bytesExamined
        $Acc.bytesRead = ([int64]$Acc.bytesRead) + $bytesHere
        $Acc.bytesRemaining = ([int64]$Acc.bytesRemaining) - $bytesHere
        if ([int64]$Acc.bytesRemaining -lt 0) { $Acc.bytesRemaining = [int64]0 }
        [void]$Acc.files.Add([ordered]@{
            kind = $Kind
            status = $(if ($truncated) { 'truncated' } else { 'read' })
            reason = $(if ($readError) { 'READ_FAILED' } elseif ($truncated) { 'LIMIT_EXCEEDED' } else { '' })
            lines_read = $linesHere
            lines_omitted = $omittedHere
            records_valid = $validHere
            records_rejected = $rejectedHere
            bytes = $bytesHere
        })
        $Acc.$omittedAcc = ([int]$Acc.$omittedAcc) + $omittedHere
        if ([bool]$Acc.capHit) {
            # Este arquivo tripou o cap global: os candidatos seguintes NAO
            # sao abertos e a omissao e contada.
            $omittedByRecords += ($toRead.Count - $fi - 1)
            break
        }
    }
    $Acc.filesOmittedByRecordsCap = ([int]$Acc.filesOmittedByRecordsCap) + $omittedByRecords
}

function Get-AdvisoryRecommendationKey {
    <#
    .SYNOPSIS
        Chave de dedup da RECOMENDACAO projetada (sem texto livre).
    #>
    [CmdletBinding()]
    param([hashtable]$Record = $null)
    if ($null -eq $Record) { return '' }
    $parts = @(
        [string]$Record['task_key'],
        [string]$Record['task_class'],
        [string]$Record['risk'],
        [string]$Record['confidence'],
        ([string]$Record['mode']),
        (@($Record['profiles']) -join ','),
        (@($Record['agents']) -join ','),
        (@($Record['skills']) -join ',')
    )
    return ($parts -join '|')
}

function Get-AdvisoryClaimFingerprint {
    <#
    .SYNOPSIS
        Impressao do claim projetado de uma observacao (sem a task_key).
    .DESCRIPTION
        Comparar claims pelo CONTEUDO projetado (agent/skills/mcps/class) e o
        unico criterio honesto para saber se dois registros da mesma chave sao
        o mesmo claim repetido ou claims conflitantes. Nada de texto livre
        entra na impressao.
    #>
    [CmdletBinding()]
    param($Record = $null)
    if ($null -eq $Record) { return '' }
    $parts = @(
        [string]$Record['provenance'],
        [string]$Record['trust'],
        [string]$Record['task_class'],
        [string]$Record['claimed_agent'],
        (@($Record['claimed_skills']) -join ','),
        (@($Record['claimed_mcps']) -join ',')
    )
    return ($parts -join '|')
}

function Get-AdvisoryCollectorReport {
    <#
    .SYNOPSIS
        Relatorio determinista e read-only do coletor 2G (ADVISORY).
    .DESCRIPTION
        Retorna SEMPRE um objeto. collection_status 'FAILED_CLOSED' indica que
        pelo menos uma entrada foi recusada (fora da raiz permitida, reparse
        point, telemetria de kernel, ilegivel, allowlist de capabilities
        indisponivel): o consumidor deve tratar esse estado como nao-confiavel
        e nao como conclusao. Nenhum arquivo e escrito, nenhuma rede e
        acessada, nenhum worker/MCP/Resolver/Kernel e invocado. O relatorio
        nao contem timestamp, caminho absoluto, nome de arquivo nem nome de
        chave de entrada.

        Regras de agregacao: NAO ha correlacao entre os dois blocos. O JSONL do
        resolver carrega apenas um task_id opaco (16 hex) sem projeto/sessao/run,
        e o registro de observacao e fornecido sem proveniencia autenticada:
        nao existe escopo comum que justifique emparelhar as duas linhas. Os
        blocos 'recommendations' e 'supplied_claims' sao reportados em separado;
        toda observacao fornecida fica SUPPLIED_UNVERIFIED, todos os campos de
        observacao ficam NOT_OBSERVABLE e as contagens de chaves nao
        correlacionadas ficam explicitas. Claim conflitante para a mesma chave
        (dois registros aceitos com conteudo diferente) => AMBIGUO: nenhum claim
        e escolhido (nada de first-wins) e a chave fica em
        'ambiguous.observation_keys'.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ResolverPaths = @(),
        [string[]]$ObservationPaths = @(),
        [string]$RepoRoot = '',
        [hashtable]$Limits = $null
    )
    $repo = Get-AdvisoryRepoRoot -RepoRoot $RepoRoot
    $lim = Resolve-AdvisoryLimits -Limits $Limits
    $allow = Get-AdvisoryCapabilityAllowlist -RepoRoot $repo
    $acc = @{
        files              = (New-Object System.Collections.ArrayList)
        failures           = (New-Object System.Collections.ArrayList)
        rejResolver        = @{}
        rejObservation     = @{}
        droppedKeys        = 0
        sensitiveDropped   = 0
        resolverRecords    = (New-Object System.Collections.ArrayList)
        observationRecords = (New-Object System.Collections.ArrayList)
        linesResolver      = 0
        linesObservation   = 0
        resolverLinesOmitted = 0
        observationLinesOmitted = 0
        bytesRead          = [long]0
        bytesRemaining     = [int64]$lim.total_bytes
        bytesCapHit        = $false
        recordsValid       = 0
        filesSkipped       = 0
        filesOmittedByRecordsCap = 0
        candidatePathsSeen = 0
        capHit             = $false
        linesCapHit        = $false
    }
    if (-not [bool]$allow.ok) { [void]$acc.failures.Add('CAPABILITY_ALLOWLIST_UNAVAILABLE') }

    # --- enumeracao GLOBAL de candidatos (orcamento de arquivos COMPARTILHADO) --
    # O cap 'files' e UM SO para a entrada inteira: os caminhos dos dois streams
    # concorrem aos MESMOS slots e inputs.files nunca passa de lim.files
    # entradas. A contagem de omitidos e bounded e precisa - inclusive para
    # caminho que seria rejeitado/recusado, porque a omissao e decidida ANTES
    # de qualquer IO (nao depende de o arquivo existir ou ser legivel).
    $selection = Select-AdvisoryCandidates -ResolverPaths $ResolverPaths -ObservationPaths $ObservationPaths -Repo $repo -FileCap ([int]$lim.files)
    $acc.candidatePathsSeen = [int]$selection.seen
    $acc.filesSkipped = [int]$selection.omitted
    $resolverSelected = New-Object System.Collections.ArrayList
    $observationSelected = New-Object System.Collections.ArrayList
    foreach ($c in @($selection.selected)) {
        if ([string]$c.kind -ceq 'observation') { [void]$observationSelected.Add([string]$c.full) }
        else { [void]$resolverSelected.Add([string]$c.full) }
    }
    Invoke-AdvisoryStreamRead -Paths @($resolverSelected) -Kind 'resolver' -Repo $repo -Limits $lim -Acc $acc -Allowlist $allow
    Invoke-AdvisoryStreamRead -Paths @($observationSelected) -Kind 'observation' -Repo $repo -Limits $lim -Acc $acc -Allowlist $allow

    $uniqueRec = New-Object 'System.Collections.Generic.HashSet[string]'
    $byClass = @{}
    $byRisk = @{}
    $byConf = @{}
    foreach ($rec in @($acc.resolverRecords)) {
        $k = Get-AdvisoryRecommendationKey -Record $rec
        if (-not $uniqueRec.Add($k)) { continue }
        Add-AdvisoryCount -Map $byClass -Key ([string]$rec['task_class'])
        Add-AdvisoryCount -Map $byRisk -Key ([string]$rec['risk'])
        Add-AdvisoryCount -Map $byConf -Key ([string]$rec['confidence'])
    }

    # Observacoes por chave: repeticao identica deduplica; repeticao com
    # conteudo diferente => AMBIGUO (nunca escolha de um dos claims). Nada aqui
    # correla com o resolver: o agrupamento e so para expor a inconsistencia do
    # proprio fornecedor (duas linhas supplied dizendo coisas diferentes para a
    # mesma chave).
    $obsByKey = @{}
    $dupObs = 0
    $ambiguousKeys = New-Object System.Collections.ArrayList
    $obsLists = @{}
    foreach ($rec in @($acc.observationRecords)) {
        $k = [string]$rec['task_key']
        if (-not $obsLists.ContainsKey($k)) { $obsLists[$k] = (New-Object System.Collections.ArrayList) }
        [void]$obsLists[$k].Add($rec)
    }
    foreach ($k in @($obsLists.Keys)) {
        $list = @($obsLists[$k])
        if ($list.Count -gt 1) { $dupObs += ($list.Count - 1) }
        $prints = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($r in $list) { [void]$prints.Add((Get-AdvisoryClaimFingerprint -Record $r)) }
        if ($prints.Count -gt 1) {
            [void]$ambiguousKeys.Add([string]$k)
            continue
        }
        $obsByKey[$k] = $list[0]
    }
    $ambiguousSorted = @(Get-AdvisorySortedStrings -Values @($ambiguousKeys))
    $ambiguousSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($k in $ambiguousSorted) { [void]$ambiguousSet.Add([string]$k) }

    # SEM CORRELACAO. Nao existe escopo comum (projeto/sessao/run) nem
    # proveniencia autenticada entre os dois streams, portanto nenhum par e
    # criado, nem por chave opaca igual, que seria semantica de join sem
    # garantia de que o mesmo literal produziu as duas linhas. As contagens de
    # chaves nao correlacionadas ficam explicitas e honestas.
    $uniqueResolverKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($rec in @($acc.resolverRecords)) { [void]$uniqueResolverKeys.Add([string]$rec['task_key']) }
    # Contagem de chaves de observacao NAO correlacionadas: TODA chave distinta
    # ACEITA entra, inclusive a ambigua. A ambiguidade impede a EMISSAO do claim
    # (nenhum dos claims conflitantes e escolhido), mas a chave foi lida e
    # aceita: omiti-la aqui seria sub-contar observacao real. A emissao de claim
    # continua omitindo a chave conflitante mais abaixo.
    $uniqueObsKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in @($obsLists.Keys)) { [void]$uniqueObsKeys.Add([string]$k) }

    # Claims fornecidos emitidos (chaves nao ambiguas), com cap proprio e total
    # real antes do cap: emitted nunca substitui o total e truncation so e true
    # quando de fato houve omissao. O total omitido fica explicito pela
    # diferenca unique_keys - emitted.
    $claimTotal = [int]$obsByKey.Count
    $claimList = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-AdvisorySortedStrings -Values @($obsByKey.Keys))) {
        if ($claimList.Count -ge [int]$lim.output_items) { continue }
        $obs = $obsByKey[$k]
        # [ordered] de proposito: hash table comum teria ordem de enumeracao
        # dependente de seed por processo e quebraria o determinismo.
        [void]$claimList.Add([ordered]@{
            task_key        = [string]$k
            trust           = 'SUPPLIED_UNVERIFIED'
            claimed_task_class = [string]$obs['task_class']
            claimed_agent   = [string]$obs['claimed_agent']
            claimed_skills  = @($obs['claimed_skills'])
            claimed_mcps    = @($obs['claimed_mcps'])
        })
    }
    $claimsEmitted = @($claimList).Count
    $claimsTruncated = ($claimTotal -gt $claimsEmitted)

    $resolverValid = @($acc.resolverRecords).Count
    $obsAccepted = @($acc.observationRecords).Count
    $evalStatus = 'PARTIAL'
    $evalReason = 'OBSERVATIONS_SUPPLIED_UNVERIFIED'
    if ($resolverValid -le 0) { $evalStatus = 'UNAVAILABLE'; $evalReason = 'NO_VALID_RESOLVER_ROWS' }
    elseif ($obsAccepted -le 0) { $evalStatus = 'PARTIAL'; $evalReason = 'NO_EXTERNAL_OBSERVATIONS' }

    $failures = @(Get-AdvisorySortedStrings -Values @($acc.failures))
    $collectionStatus = 'COMPLETED'
    if ($failures.Count -gt 0) { $collectionStatus = 'FAILED_CLOSED' }

    $rejResolverTotal = 0
    foreach ($v in @($acc.rejResolver.Values)) { $rejResolverTotal += [int]$v }
    $rejObsTotal = 0
    foreach ($v in @($acc.rejObservation.Values)) { $rejObsTotal += [int]$v }

    # Entradas [ordered] de proposito: hashtable comum enumeraria em ordem
    # dependente de seed por processo (PS 5.1 e PS 7 divergem sem isso).
    $metrics = [ordered]@{
        runtime_adherence        = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'NO_INDEPENDENT_RUNTIME_GROUND_TRUTH' }
        runtime_selected_agent   = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'RUNTIME_SELECTION_NOT_EXPOSED' }
        runtime_selected_skills  = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'RUNTIME_SELECTION_NOT_EXPOSED' }
        runtime_selected_mcps    = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'RUNTIME_SELECTION_NOT_EXPOSED' }
        productive_outcome       = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'PRODUCTIVE_OUTCOME_NOT_EXPOSED' }
        agreement_with_runtime   = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'SUPPLIED_UNVERIFIED_CLAIMS_ONLY' }
        stability                = [ordered]@{ status = 'NOT_OBSERVABLE'; reason = 'PROVEN_OBSERVED_OUTCOMES_ABSENT' }
    }

    $report = [ordered]@{
        schema                     = 'capability-advisory-collector-report'
        schema_version             = 3
        producer                   = 'CapabilityAdvisoryCollector.ps1'
        authority                  = 'advisory-shadow-readonly'
        collection_status          = $collectionStatus
        collection_failure_reasons = @($failures)
        evaluation_status          = $evalStatus
        evaluation_status_reason   = $evalReason
        inputs                     = [ordered]@{
            allowed_roots              = @('cache:v3:telemetry', 'temp')
            capability_allowlist_loaded = [bool]$allow.ok
            files                      = @($acc.files)
            dropped_input_keys_count   = [int]$acc.droppedKeys
            sensitive_keys_dropped     = [int]$acc.sensitiveDropped
            limits                     = [ordered]@{
                files        = [int]$lim.files
                total_bytes  = [int]$lim.total_bytes
                line_bytes   = [int]$lim.line_bytes
                file_lines   = [int]$lim.file_lines
                records      = [int]$lim.records
                array_items  = [int]$lim.array_items
                output_items = [int]$lim.output_items
            }
            records_cap_reached        = [bool]$acc.capHit
            lines_cap_reached          = [bool]$acc.linesCapHit
            bytes_cap_reached          = [bool]$acc.bytesCapHit
            files_skipped_by_limit     = [int]$acc.filesSkipped
            files_omitted_by_records_cap = [int]$acc.filesOmittedByRecordsCap
            candidate_paths_seen       = [int]$acc.candidatePathsSeen
            bytes_examined_total       = [int64]$acc.bytesRead
        }
        counts                     = [ordered]@{
            resolver_lines_read          = [int]$acc.linesResolver
            observation_lines_read       = [int]$acc.linesObservation
            resolver_lines_omitted       = [int]$acc.resolverLinesOmitted
            observation_lines_omitted    = [int]$acc.observationLinesOmitted
            resolver_records_valid       = $resolverValid
            resolver_records_rejected    = $rejResolverTotal
            unique_recommendations       = [int]$uniqueRec.Count
            observations_accepted        = $obsAccepted
            observations_rejected        = $rejObsTotal
            observation_duplicate_keys   = $dupObs
            ambiguous_observation_keys   = @($ambiguousSorted).Count
            correlated_pairs             = 0
            uncorrelated_resolver_keys   = [int]$uniqueResolverKeys.Count
            uncorrelated_observation_keys = [int]$uniqueObsKeys.Count
            supplied_claim_keys          = [int]$obsByKey.Count
            supplied_claims_emitted      = $claimsEmitted
        }
        recommendations             = [ordered]@{
            unique_total   = [int]$uniqueRec.Count
            by_task_class  = (Get-AdvisorySortedCounts -Counts $byClass)
            by_risk        = (Get-AdvisorySortedCounts -Counts $byRisk)
            by_confidence  = (Get-AdvisorySortedCounts -Counts $byConf)
        }
        supplied_claims             = [ordered]@{
            trust          = 'SUPPLIED_UNVERIFIED'
            correlation    = 'NOT_CORRELATED_NO_COMMON_SCOPED_ID'
            accepted_total = $obsAccepted
            unique_keys    = [int]$obsByKey.Count
            duplicate_keys = $dupObs
            ambiguous_keys = @($ambiguousSorted).Count
            emitted        = $claimsEmitted
            truncated      = $claimsTruncated
            fields         = [ordered]@{
                claimed_task_class = 'CLAIMED_NOT_OBSERVED'
                claimed_agent      = 'CLAIMED_NOT_OBSERVED'
                claimed_skills     = 'CLAIMED_NOT_OBSERVED'
                claimed_mcps       = 'CLAIMED_NOT_OBSERVED'
                observed_agent     = 'NOT_OBSERVABLE'
                observed_skills    = 'NOT_OBSERVABLE'
                observed_mcps      = 'NOT_OBSERVABLE'
                observed_outcome   = 'NOT_OBSERVABLE'
            }
            items          = @($claimList)
        }
        uncorrelated               = [ordered]@{
            resolver_keys        = [int]$uniqueResolverKeys.Count
            observation_keys     = [int]$uniqueObsKeys.Count
            reason               = 'NO_COMMON_SCOPED_ID_OR_AUTHENTICATED_PROVENANCE'
        }
        ambiguous                   = [ordered]@{
            observation_keys = @($ambiguousSorted)
        }
        source_classification       = [ordered]@{
            resolver_stream    = 'RESOLVER_RECOMMENDATION_MANUAL_CLI'
            observation_stream = 'SUPPLIED_OBSERVATION_UNAUTHENTICATED'
            kernel_telemetry   = 'NOT_INGESTED'
            correlation        = 'NOT_CORRELATED_NO_COMMON_SCOPED_ID'
        }
        missing                     = [ordered]@{
            external_observations = ($obsAccepted -le 0)
            runtime_ground_truth  = $true
            proven_observations   = $true
            correlation_contract  = $true
        }
        metrics                     = $metrics
        rejection_reasons           = [ordered]@{
            resolver    = (Get-AdvisorySortedCounts -Counts $acc.rejResolver)
            observation = (Get-AdvisorySortedCounts -Counts $acc.rejObservation)
        }
        integrity                   = [ordered]@{
            read_only               = $true
            network_access          = $false
            input_files_mutated     = $false
            telemetry_written       = $false
            kernel_telemetry_read   = $false
            workers_or_mcp_invoked  = $false
            resolver_invoked        = $false
            rows_correlated         = $false
        }
    }
    return $report
}

function ConvertTo-AdvisoryCollectorJson {
    <#
    .SYNOPSIS
        Serializa o relatorio em JSON compacto e determinista.
    .DESCRIPTION
        $Report e Mandatory: $null e recusado pelo proprio parameter binding
        (nunca chega ao corpo), por isso nao existe guarda interna de nulo.
        Report nulo e erro do chamador, nao saida valida.

        Determinismo: TODOS os mapas serializados sao [ordered] (dicionario
        ordenado por insercao) e todas as colecoes expostas passam por
        ordenacao ordinal antes de entrar no relatorio. Um hashtable comum
        enumeraria em ordem dependente de seed de hash POR PROCESSO, e o
        mesmo relatorio sairia com chaves em ordem diferente em outro
        processo/runtime. O teste da suite compara a serializacao deste
        processo com a de um processo filho separado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Report,
        [int]$Depth = 12
    )
    return (ConvertTo-Json -InputObject $Report -Depth $Depth -Compress)
}
