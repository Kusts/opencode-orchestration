<#!
.SYNOPSIS
    V3 Authority gate: mutacao byte-preserving de agent.build.permission.task (Phase 6).

.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa a ultima
    precondition da Phase 6: localizar e substituir SOMENTE o objeto valor de
    `agent.build.permission.task` no texto JSON do opencode.json, preservando
    todos os outros bytes (BOM, terminadores, indentacao, ordem de chaves,
    campos desconhecidos).

    Funcoes publicas:
      - Get-BuildTaskTargetRange -Text
        Localiza o intervalo [Start,End) EXATO (offsets de char no texto
        decodificado) do objeto valor de agent.build.permission.task, via
        scanner token-aware proprio (respeita strings e escapes, `{}`/`[]`,
        `:` e `,`), SEM usar ConvertFrom-Json para achar o range. O path e a
        sequencia de chaves agent -> build -> permission -> task no objeto raiz.
        Path ausente, chave repetida (qualquer objeto com chave duplicada em
        comparacao ordinal, case-sensitive), JSON malformado ou task
        nao-objeto => fail closed (throw, sem escrita).
      - New-BuildTaskAllowlistJson -ProposedAllowlist
        Serializa deterministicamente o objeto task desejado:
        `{"*": "deny", "<agent>": "allow", ...}` com as entradas de agente
        deduplicadas e ordenadas ordinalmente (case-sensitive); `"*"` sempre
        primeiro com `"deny"`; uma entrada por agente com `"allow"`;
        `{"*": "deny"}` quando vazio. Sem quebras de linha ou espacos
        superfluos (separadores exatos `": "` e `", "`).
      - Set-BuildTaskAllowlist -ConfigPath -ProposedAllowlist
        [-ExpectedHash] [-TestRoot] [-WhatIf] [-AllowRealWrite]
        1. le os bytes; decodifica UTF-8 estrito preservando BOM;
        2. CAS: -ExpectedHash dado e diferente do hash atual => throw com
           `CAS_CONFLICT` (sem escrever);
        3. localiza o range (fail closed, sem escrita);
        4. task atual semanticamente igual ao desejado => `NO_CHANGE` (sem
           escrita);
        5. substitui SOMENTE o intervalo do task; demais chars intactos;
        6. valida: ConvertFrom-Json OK + hash logico (Get-LogicalHash) dos
           campos nao-governados igual ao original (path
           agent.build.permission.task removido de ambos);
        7. escrita atomica (temp no mesmo dir + Replace/Move + verificacao
           pos-hash) SOMENTE com -TestRoot (fixture, com boundary fail-closed:
           TestRoot sob o TEMP do SO, ConfigPath canonico dentro de TestRoot,
           sem reparse points, nunca o opencode.json real nem dentro de
           %USERPROFILE%\.config\opencode) OU com -AllowRealWrite explicito.
           Sem nenhum dos dois (ou com -WhatIf) => nenhuma escrita; retorna o
           texto mutado (`WOULD_MUTATE`).
    Retorno: PSCustomObject @{ Status; HashBefore; HashAfter; TaskJson;
    MutatedText; Wrote }. Status: 'NO_CHANGE' | 'MUTATED' | 'WOULD_MUTATE'.
    `CAS_CONFLICT` e sinalizado via throw (mensagem contem `CAS_CONFLICT`),
    seguindo a convencao fail-closed do gate (CapabilityAuthority registra o
    estado CAS_CONFLICT a partir dessa excecao); nada e escrito nesse caso.

    NOTA: offsets sao indices de char no texto decodificado em UTF-8. Como o
    splice opera sobre esse mesmo texto e a recodificacao preserva o BOM e
    usa UTF-8, os bytes fora do intervalo permanecem bit-identicos.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$mutatorSchemaPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -eq $null) {
    if (Test-Path -LiteralPath $mutatorSchemaPath -PathType Leaf) {
        . $mutatorSchemaPath
    }
}

function Skip-BuildTaskJsonWhitespace {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)
    $text = [string]$State['Text']
    $len = [int]$State['Len']
    $pos = [int]$State['Pos']
    while ($pos -lt $len) {
        $c = $text[$pos]
        if (($c -eq ' ') -or ($c -eq "`t") -or ($c -eq "`r") -or ($c -eq "`n")) { $pos++ }
        else { break }
    }
    $State['Pos'] = $pos
}

function Read-BuildTaskJsonStringValue {
    <#
    .SYNOPSIS
        Le uma string JSON a partir da aspa de abertura (State.Pos) e retorna
        o valor DECODIFICADO (escapes resolvidos), avancando State.Pos para
        apos a aspa de fechamento. Fail-closed em string nao terminada,
        escape invalido ou controle cru (<0x20).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)
    $text = [string]$State['Text']
    $len = [int]$State['Len']
    $pos = [int]$State['Pos'] + 1
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        if ($pos -ge $len) { throw 'JSON malformado: string sem terminador.' }
        $c = $text[$pos]
        if ($c -eq '"') { $pos++; break }
        if ($c -eq '\') {
            $pos++
            if ($pos -ge $len) { throw 'JSON malformado: escape incompleto no fim do texto.' }
            $e = $text[$pos]
            if ($e -eq '"') { $sb.Append('"') | Out-Null }
            elseif ($e -eq '\') { $sb.Append('\') | Out-Null }
            elseif ($e -eq '/') { $sb.Append('/') | Out-Null }
            elseif ($e -eq 'b') { $sb.Append([char]8) | Out-Null }
            elseif ($e -eq 'f') { $sb.Append([char]12) | Out-Null }
            elseif ($e -eq 'n') { $sb.Append("`n") | Out-Null }
            elseif ($e -eq 'r') { $sb.Append("`r") | Out-Null }
            elseif ($e -eq 't') { $sb.Append("`t") | Out-Null }
            elseif ($e -eq 'u') {
                if (($pos + 4) -ge $len) { throw 'JSON malformado: escape \u incompleto.' }
                $hex = $text.Substring($pos + 1, 4)
                if ($hex -notmatch '^[0-9a-fA-F]{4}$') { throw ("JSON malformado: escape \u invalido: '{0}'." -f $hex) }
                $sb.Append([char][Convert]::ToInt32($hex, 16)) | Out-Null
                $pos += 4
            }
            else { throw ("JSON malformado: escape invalido '\{0}'." -f $e) }
            $pos++
        }
        else {
            if ([int][char]$c -lt 32) { throw 'JSON malformado: caractere de controle sem escape em string.' }
            $sb.Append($c) | Out-Null
            $pos++
        }
    }
    $State['Pos'] = $pos
    return $sb.ToString()
}

function Read-BuildTaskJsonLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][int]$Start)
    $text = [string]$State['Text']
    $pos = [int]$State['Pos']
    $rest = $text.Substring($pos)
    $m = [regex]::Match($rest, '^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)')
    if (-not $m.Success) { throw ("JSON malformado: valor inesperado em offset {0}." -f $pos) }
    $token = $m.Groups[1].Value
    if (($token -ceq 'true') -or ($token -ceq 'false') -or ($token -ceq 'null')) {
        $after = $pos + $token.Length
        if ($after -lt $text.Length) {
            $next = $text[$after]
            if (($next -match '[A-Za-z0-9_]')) { throw ("JSON malformado: literal invalido em offset {0}." -f $pos) }
        }
    }
    $State['Pos'] = $pos + $token.Length
    return [PSCustomObject]@{ Kind = 'literal'; Start = $Start; End = ([int]$State['Pos']); Members = $null; Elements = $null; Value = $token }
}

function Read-BuildTaskJsonValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [int]$Depth = 0)
    if ($Depth -gt 64) { throw 'JSON malformado: profundidade excede o limite (64).' }
    Skip-BuildTaskJsonWhitespace -State $State | Out-Null
    $text = [string]$State['Text']
    $len = [int]$State['Len']
    $pos = [int]$State['Pos']
    if ($pos -ge $len) { throw 'JSON malformado: fim inesperado do texto.' }
    $c = $text[$pos]
    if ($c -eq '{') { return (Read-BuildTaskJsonObject -State $State -Depth $Depth) }
    if ($c -eq '[') { return (Read-BuildTaskJsonArray -State $State -Depth $Depth) }
    if ($c -eq '"') {
        $value = Read-BuildTaskJsonStringValue -State $State
        return [PSCustomObject]@{ Kind = 'string'; Start = $pos; End = ([int]$State['Pos']); Members = $null; Elements = $null; Value = $value }
    }
    return (Read-BuildTaskJsonLiteral -State $State -Start $pos)
}

function Read-BuildTaskJsonObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [int]$Depth = 0)
    $text = [string]$State['Text']
    $len = [int]$State['Len']
    $start = [int]$State['Pos']
    $State['Pos'] = $start + 1
    $members = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    Skip-BuildTaskJsonWhitespace -State $State | Out-Null
    if (([int]$State['Pos'] -lt $len) -and ($text[[int]$State['Pos']] -eq '}')) {
        $State['Pos'] = [int]$State['Pos'] + 1
        return [PSCustomObject]@{ Kind = 'object'; Start = $start; End = ([int]$State['Pos']); Members = $members; Elements = $null; Value = $null }
    }
    while ($true) {
        Skip-BuildTaskJsonWhitespace -State $State | Out-Null
        $pos = [int]$State['Pos']
        if ($pos -ge $len) { throw 'JSON malformado: objeto sem fechamento.' }
        if ($text[$pos] -cne '"') { throw ("JSON malformado: chave de objeto deve ser string (offset {0})." -f $pos) }
        $key = Read-BuildTaskJsonStringValue -State $State
        if ($members.Contains($key)) { throw ("JSON rejeitado (fail-closed): chave duplicada '{0}'." -f $key) }
        Skip-BuildTaskJsonWhitespace -State $State | Out-Null
        $pos = [int]$State['Pos']
        if (($pos -ge $len) -or ($text[$pos] -cne ':')) { throw ("JSON malformado: esperado ':' apos chave (offset {0})." -f $pos) }
        $State['Pos'] = $pos + 1
        $value = Read-BuildTaskJsonValue -State $State -Depth ($Depth + 1)
        $members[$key] = $value
        Skip-BuildTaskJsonWhitespace -State $State | Out-Null
        $pos = [int]$State['Pos']
        if ($pos -ge $len) { throw 'JSON malformado: objeto sem fechamento.' }
        $d = $text[$pos]
        if ($d -eq ',') { $State['Pos'] = $pos + 1; continue }
        if ($d -eq '}') { $State['Pos'] = $pos + 1; break }
        throw ("JSON malformado: esperado ',' ou '}}' em objeto (offset {0})." -f $pos)
    }
    return [PSCustomObject]@{ Kind = 'object'; Start = $start; End = ([int]$State['Pos']); Members = $members; Elements = $null; Value = $null }
}

function Read-BuildTaskJsonArray {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [int]$Depth = 0)
    $text = [string]$State['Text']
    $len = [int]$State['Len']
    $start = [int]$State['Pos']
    $State['Pos'] = $start + 1
    $elements = New-Object System.Collections.ArrayList
    Skip-BuildTaskJsonWhitespace -State $State | Out-Null
    if (([int]$State['Pos'] -lt $len) -and ($text[[int]$State['Pos']] -eq ']')) {
        $State['Pos'] = [int]$State['Pos'] + 1
        return [PSCustomObject]@{ Kind = 'array'; Start = $start; End = ([int]$State['Pos']); Members = $null; Elements = @($elements); Value = $null }
    }
    while ($true) {
        $value = Read-BuildTaskJsonValue -State $State -Depth ($Depth + 1)
        $elements.Add($value) | Out-Null
        Skip-BuildTaskJsonWhitespace -State $State | Out-Null
        $pos = [int]$State['Pos']
        if ($pos -ge $len) { throw 'JSON malformado: array sem fechamento.' }
        $d = $text[$pos]
        if ($d -eq ',') { $State['Pos'] = $pos + 1; continue }
        if ($d -eq ']') { $State['Pos'] = $pos + 1; break }
        throw ("JSON malformado: esperado ',' ou ']' em array (offset {0})." -f $pos)
    }
    return [PSCustomObject]@{ Kind = 'array'; Start = $start; End = ([int]$State['Pos']); Members = $null; Elements = @($elements); Value = $null }
}

function Get-BuildTaskTargetRange {
    <#
    .SYNOPSIS
        Localiza o intervalo [Start,End) do objeto valor de
        agent.build.permission.task no texto JSON, sem ConvertFrom-Json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { throw 'JSON malformado: texto vazio.' }
    $state = @{ Text = $Text; Len = $Text.Length; Pos = 0 }
    $root = Read-BuildTaskJsonValue -State $state -Depth 0
    Skip-BuildTaskJsonWhitespace -State $state | Out-Null
    if ([int]$state['Pos'] -ne $Text.Length) { throw 'JSON malformado: conteudo apos o valor raiz.' }
    if ($root.Kind -cne 'object') { throw 'path agent.build.permission.task ausente: raiz JSON nao e objeto.' }
    $node = $root
    foreach ($key in @('agent', 'build', 'permission')) {
        if (-not $node.Members.Contains($key)) { throw ("path agent.build.permission.task ausente: chave '{0}' nao encontrada." -f $key) }
        $node = $node.Members[$key]
        if ($node.Kind -cne 'object') { throw ("path agent.build.permission.task malformado: '{0}' nao e objeto." -f $key) }
    }
    if (-not $node.Members.Contains('task')) { throw "path agent.build.permission.task ausente: chave 'task' nao encontrada." }
    $task = $node.Members['task']
    if ($task.Kind -cne 'object') { throw 'alvo task nao-objeto (fail-closed): agent.build.permission.task deve ser objeto.' }
    return [PSCustomObject]@{ Start = [int]$task.Start; End = [int]$task.End }
}

function Escape-BuildTaskJsonString {
    [CmdletBinding()]
    param([string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in ([string]$Text).ToCharArray()) {
        $code = [int][char]$ch
        if ($code -eq 34) { $sb.Append('\"') | Out-Null }
        elseif ($code -eq 92) { $sb.Append('\\') | Out-Null }
        elseif ($code -eq 8) { $sb.Append('\b') | Out-Null }
        elseif ($code -eq 9) { $sb.Append('\t') | Out-Null }
        elseif ($code -eq 10) { $sb.Append('\n') | Out-Null }
        elseif ($code -eq 12) { $sb.Append('\f') | Out-Null }
        elseif ($code -eq 13) { $sb.Append('\r') | Out-Null }
        elseif ($code -lt 32) { $sb.Append(('\u{0:x4}' -f $code)) | Out-Null }
        else { $sb.Append($ch) | Out-Null }
    }
    return $sb.ToString()
}

function Get-BuildTaskSortedAgents {
    <#
    .SYNOPSIS
        Lista deduplicada (ordinal, case-sensitive) e ordenada de agentes,
        ignorando nulos/vazios. Base do task canonico.
    #>
    [CmdletBinding()]
    param($ProposedAllowlist)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($null -ne $ProposedAllowlist) {
        foreach ($a in @($ProposedAllowlist)) {
            $name = [string]$a
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $set.Add($name) | Out-Null
        }
    }
    $sorted = @($set)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

function New-BuildTaskAllowlistJson {
    <#
    .SYNOPSIS
        Serializa deterministicamente o objeto task desejado:
        {"*": "deny", "<agent>": "allow", ...} (agentes em ordem ordinal).
    #>
    [CmdletBinding()]
    param($ProposedAllowlist)
    $sorted = @(Get-BuildTaskSortedAgents -ProposedAllowlist $ProposedAllowlist)
    $parts = @('"*": "deny"')
    foreach ($n in $sorted) {
        $parts += ('"' + (Escape-BuildTaskJsonString -Text $n) + '": "allow"')
    }
    return ('{' + ($parts -join ', ') + '}')
}

function Get-BuildTaskMutatedText {
    <#
    .SYNOPSIS
        Nucleo textual do mutator: splice do task + validacao, sem I/O.
        Retorna @{ Status = 'NO_CHANGE'|'MUTATED'; MutatedText; TaskJson }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        $ProposedAllowlist
    )
    $range = Get-BuildTaskTargetRange -Text $Text
    $desiredJson = New-BuildTaskAllowlistJson -ProposedAllowlist $ProposedAllowlist
    $sorted = @(Get-BuildTaskSortedAgents -ProposedAllowlist $ProposedAllowlist)

    $cfg = $null
    try { $cfg = $Text | ConvertFrom-Json }
    catch { throw ("Config file is not valid JSON (fail-closed): {0}" -f $_.Exception.Message) }
    $task = $null
    try {
        if (($null -ne $cfg.agent) -and ($null -ne $cfg.agent.build) -and ($null -ne $cfg.agent.build.permission)) {
            $task = $cfg.agent.build.permission.task
        }
    }
    catch { $task = $null }
    if ($null -eq $task) { throw "path agent.build.permission.task ausente apos parse (fail-closed)." }

    $desiredMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $desiredMap['*'] = 'deny'
    foreach ($n in $sorted) { $desiredMap[$n] = 'allow' }
    $currentMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($p in @($task.PSObject.Properties)) {
        $currentMap[[string]$p.Name] = [string]$p.Value
    }
    $equal = ($currentMap.Count -eq $desiredMap.Count)
    if ($equal) {
        foreach ($k in @($desiredMap.Keys)) {
            if (-not $currentMap.Contains($k)) { $equal = $false; break }
            if ($currentMap[$k] -cne $desiredMap[$k]) { $equal = $false; break }
        }
    }
    if ($equal) {
        return @{ Status = 'NO_CHANGE'; MutatedText = $Text; TaskJson = $desiredJson }
    }

    $mutated = $Text.Substring(0, [int]$range.Start) + $desiredJson + $Text.Substring([int]$range.End)
    try { $mutated | ConvertFrom-Json | Out-Null }
    catch { throw ("Mutacao rejeitada (fail-closed): resultado nao e JSON valido: {0}" -f $_.Exception.Message) }

    if ((Get-Command Get-LogicalHash -ErrorAction SilentlyContinue) -eq $null) {
        throw 'Mutacao rejeitada (fail-closed): Get-LogicalHash indisponivel para validar campos nao-governados.'
    }
    $o1 = $Text | ConvertFrom-Json
    $o2 = $mutated | ConvertFrom-Json
    try {
        $o1.agent.build.permission.PSObject.Properties.Remove('task')
        $o2.agent.build.permission.PSObject.Properties.Remove('task')
    }
    catch { throw ("Mutacao rejeitada (fail-closed): nao foi possivel isolar campos nao-governados: {0}" -f $_.Exception.Message) }
    $h1 = Get-LogicalHash -InputObject $o1
    $h2 = Get-LogicalHash -InputObject $o2
    if ($h1 -cne $h2) {
        throw 'Mutacao rejeitada (fail-closed): campos nao-governados divergiram apos o splice.'
    }
    return @{ Status = 'MUTATED'; MutatedText = $mutated; TaskJson = $desiredJson }
}

function Get-BuildTaskBytesSha256Lower {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
}

function Get-BuildTaskFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return ([IO.Path]::GetFullPath($Path).TrimEnd('\', '/')) }
    catch { return $Path }
}

function Test-BuildTaskPathHasReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while ((-not [string]::IsNullOrWhiteSpace($current)) -and ($guard -lt 128)) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    if (($item.PSObject.Properties['LinkType'] -ne $null) -and (-not [string]::IsNullOrWhiteSpace([string]$item.LinkType))) { return $true }
                } catch { }
            } catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -ceq $current)) { break }
        $current = $parent
    }
    return $false
}

function Assert-BuildTaskFixtureBoundary {
    <#
    .SYNOPSIS
        Boundary fail-closed da escrita do mutator: exige -TestRoot sob o TEMP
        do SO, ConfigPath canonico dentro de TestRoot, sem reparse points, e
        NUNCA o opencode.json real nem dentro de .config\opencode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$TestRoot
    )
    $fullConfig = Get-BuildTaskFullPath -Path $ConfigPath
    $fullTest = Get-BuildTaskFullPath -Path $TestRoot
    $tempRoot = Get-BuildTaskFullPath -Path ([IO.Path]::GetTempPath())
    $underTemp = ($fullTest -ieq $tempRoot) -or $fullTest.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $underTemp) {
        throw ("TestRoot fora do TEMP do SO (fixture-only): {0} nao esta sob {1}" -f $TestRoot, $tempRoot)
    }
    $underFixture = ($fullConfig -ieq $fullTest) -or $fullConfig.StartsWith($fullTest + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $underFixture) {
        throw ("ConfigPath fora do -TestRoot (fixture-only): {0} nao esta sob {1}" -f $ConfigPath, $TestRoot)
    }
    foreach ($p in @($TestRoot, $ConfigPath)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-BuildTaskPathHasReparsePoint -Path $p) {
            throw ("Reparse point/junction detectado no caminho (fixture-only bloqueado): {0}" -f $p)
        }
    }
    $cfgParent = Split-Path -Parent $fullConfig
    if ((-not [string]::IsNullOrWhiteSpace($cfgParent)) -and (Test-BuildTaskPathHasReparsePoint -Path $cfgParent)) {
        throw ("Reparse point/junction detectado em ancestor do ConfigPath: {0}" -f $cfgParent)
    }
    $realCfg = Get-BuildTaskFullPath -Path (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
    $realDir = Get-BuildTaskFullPath -Path (Join-Path $env:USERPROFILE '.config\opencode')
    if ($fullConfig -ieq $realCfg) {
        throw ("ConfigPath e o opencode.json real (escrita proibida): {0}" -f $ConfigPath)
    }
    if (($fullConfig -ieq $realDir) -or $fullConfig.StartsWith($realDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw ("ConfigPath dentro do profile real .config\opencode (escrita proibida): {0}" -f $ConfigPath)
    }
    return $true
}

function Write-BuildTaskBytesAtomic {
    <#
    .SYNOPSIS
        Escrita atomica: temp no mesmo dir + Replace (ou Move) + limpeza do
        temp em qualquer falha anterior a conclusao.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $full = [IO.Path]::GetFullPath($ConfigPath)
    $parent = Split-Path -Parent $full
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $tempBackup = $temp + '.backup'
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            [IO.File]::Replace($temp, $full, $tempBackup)
            Remove-Item -LiteralPath $tempBackup -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temp, $full)
        }
        $temp = $null
        $tempBackup = $null
    }
    finally {
        if (($null -ne $temp) -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        if (($null -ne $tempBackup) -and (Test-Path -LiteralPath $tempBackup)) {
            Remove-Item -LiteralPath $tempBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-BuildTaskAllowlist {
    <#
    .SYNOPSIS
        Mutacao byte-preserving de agent.build.permission.task com CAS,
        validacao de nao-governados e escrita atomica restrita a fixture.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        $ProposedAllowlist,
        [string]$ExpectedHash,
        [string]$TestRoot,
        [switch]$WhatIf,
        [switch]$AllowRealWrite
    )
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw ("Config file not found: {0}" -f $ConfigPath)
    }
    $raw = [IO.File]::ReadAllBytes($ConfigPath)
    $hashBefore = ('sha256:' + (Get-BuildTaskBytesSha256Lower -Bytes $raw))
    if ((-not [string]::IsNullOrWhiteSpace($ExpectedHash)) -and ($ExpectedHash -cne $hashBefore)) {
        throw ("CAS_CONFLICT: hash atual {0} difere do esperado {1}; nada foi escrito." -f $hashBefore, $ExpectedHash)
    }
    $hasBom = ($raw.Length -ge 3 -and ($raw[0] -eq 0xEF) -and ($raw[1] -eq 0xBB) -and ($raw[2] -eq 0xBF))
    $contentBytes = @()
    if ($raw.Length -gt 3 -and $hasBom) { $contentBytes = $raw[3..($raw.Length - 1)] }
    elseif (-not $hasBom) { $contentBytes = $raw }
    $strict = New-Object Text.UTF8Encoding($false, $true)
    $text = ''
    try { $text = $strict.GetString($contentBytes) }
    catch { throw ("Config file is not valid UTF-8 (fail-closed): {0} ({1})" -f $ConfigPath, $_.Exception.Message) }

    $core = Get-BuildTaskMutatedText -Text $text -ProposedAllowlist $ProposedAllowlist
    if ([string]$core.Status -ceq 'NO_CHANGE') {
        return [PSCustomObject]@{
            Status      = 'NO_CHANGE'
            HashBefore  = $hashBefore
            HashAfter   = $hashBefore
            TaskJson    = [string]$core.TaskJson
            MutatedText = $text
            Wrote       = $false
        }
    }
    $mutated = [string]$core.MutatedText
    # GetBytes NAO emite o preamble BOM; prefixar manualmente para
    # preservar o BOM original byte-a-byte.
    $enc = New-Object Text.UTF8Encoding($hasBom, $false)
    $outBytes = $enc.GetBytes($mutated)
    if ($hasBom) { $outBytes = [byte[]]($enc.GetPreamble() + $outBytes) }
    $hashAfter = ('sha256:' + (Get-BuildTaskBytesSha256Lower -Bytes $outBytes))

    $doWrite = ((-not [bool]$WhatIf) -and ((-not [string]::IsNullOrWhiteSpace($TestRoot)) -or [bool]$AllowRealWrite))
    if (-not $doWrite) {
        return [PSCustomObject]@{
            Status      = 'WOULD_MUTATE'
            HashBefore  = $hashBefore
            HashAfter   = $hashAfter
            TaskJson    = [string]$core.TaskJson
            MutatedText = $mutated
            Wrote       = $false
        }
    }
    if ([string]::IsNullOrWhiteSpace($TestRoot)) {
        Write-BuildTaskBytesAtomic -ConfigPath $ConfigPath -Bytes $outBytes
    }
    else {
        Assert-BuildTaskFixtureBoundary -ConfigPath $ConfigPath -TestRoot $TestRoot | Out-Null
        Write-BuildTaskBytesAtomic -ConfigPath $ConfigPath -Bytes $outBytes
    }
    $afterBytes = [IO.File]::ReadAllBytes($ConfigPath)
    $afterHash = ('sha256:' + (Get-BuildTaskBytesSha256Lower -Bytes $afterBytes))
    if ($afterHash -cne $hashAfter) {
        throw ("Verificacao pos-write falhou (fail-closed): esperado {0}, atual {1}." -f $hashAfter, $afterHash)
    }
    return [PSCustomObject]@{
        Status      = 'MUTATED'
        HashBefore  = $hashBefore
        HashAfter   = $hashAfter
        TaskJson    = [string]$core.TaskJson
        MutatedText = $mutated
        Wrote       = $true
    }
}
