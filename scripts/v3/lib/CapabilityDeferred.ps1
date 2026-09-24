<#!
.SYNOPSIS
    V3 Deferred lib: validacao NAO destrutiva dos itens adiados (Phase 14).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Verifica que os
    itens ADIADOS do plano permanecem NAO implementados/ativos, SEMPRE em
    modo leitura: nunca ativa routing, nunca altera flags/policy/authority,
    nunca deleta arquivos. Fail-safe: nunca lanca; qualquer falha
    operacional vira decision=drift com razoes concretas.

    Grupos verificados:
      F flags ativas desligadas por padrao (skill_routing.enabled=false,
        mcp_routing.enabled=false, adaptive_ranking.enabled=false;
        shadow=true permitido/informativo) com excecao governada:
        capability_router.active=true PASSA quando existe registro valido
        de ativacao controlada Stage 1 em
        evidence/v3/activation/agent-routing-controlled.json
        (stage=stage1, gate_pass=true, activation_status=controlled_active
        e flags capability_router.active=true + skill/mcp/adaptive=false);
        sem registro valido, active=true e drift. O registro so e lido
        de dentro de evidence/v3/activation (caminho externo e rejeitado
        como nao-valido; anti self-assert) e com o nome canonico
        agent-routing-controlled.json (outro nome e rejeitado);
      S spike MCP: enforcement_supported=false (spike real) e mcp_routing
        nunca ativo com spike false;
      A authority inalterada: agent.build.permission.task exatamente os 19
        IDs esperados, '*' = deny; hash do opencode.json reportado e, quando
        avaliado no caminho padrao (live), comparado ao baseline conhecido;
      R artefatos ausentes: sem vector DB/embeddings/graph/daemon/MCP
        gateway/SQLite registry/OTEL (arquivos/dirs suspeitos + tokens de
        dependencia nos JSONs governados);
      O sem orchestration escondida de fase 10+: sem skill execution ativa,
        sem tool exposure ativo, sem enforcement presumido, policy com notas
        OFFLINE/advisory/read-only e exceptions.hard_filter vazio.

    Itens explicitamente adiados (status sempre 'deferred'): semantic
    retrieval, embeddings, adaptive ranking, graph, MCP gateway, daemon,
    hot reload, self-modifying policy, auto trust elevation,
    cross-project learning, OTEL, SQLite registry, tool-level MCP risk,
    migracao em massa de skills, multi-level hierarchy, peer-to-peer,
    arbiter, tool exposure/enforcement nao comprovado e excecoes a
    hard filter.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-DeferredRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-DeferredUtf8Single {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Read-DeferredJsonDoc {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 65536)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @{ Ok = $false; Doc = $null; Error = 'not-found' }
        }
        $text = Read-DeferredUtf8Single -Path $Path
        if ($MaxBytes -gt 0 -and $text.Length -gt $MaxBytes) {
            return @{ Ok = $false; Doc = $null; Error = 'too-large' }
        }
        $doc = $null
        try { $doc = $text | ConvertFrom-Json }
        catch { return @{ Ok = $false; Doc = $null; Error = 'invalid-json' } }
        return @{ Ok = $true; Doc = $doc; Error = '' }
    }
    catch { return @{ Ok = $false; Doc = $null; Error = 'unreadable' } }
}

function Get-DeferredNodeProp {
    [CmdletBinding()]
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Name)) { return $Node[$Name] }
            return $null
        }
        $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function Get-DeferredFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'MISSING' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    catch { return 'UNREADABLE' }
}

function Get-DeferredExpectedAllowlist {
    [CmdletBinding()]
    param()
    return @('ai-agent-engineer', 'architect', 'automation-engineer', 'backend-engineer', 'coder', 'database-engineer', 'debugger', 'docs-manager', 'engineering-advisor', 'explorer', 'frontend-engineer', 'infra-engineer', 'product-designer', 'requirements-analyst', 'researcher', 'reviewer', 'security-reviewer', 'skeptic', 'tester')
}

function Get-DeferredKnownOpencodeHash {
    [CmdletBinding()]
    param()
    return 'DE22307F88C43B93EC51A083992B39948C99CF5551682B98F6ACA2D087A98A46'
}

function Get-DeferredItems {
    [CmdletBinding()]
    param()
    $ids = @(
        'semantic-retrieval', 'embeddings', 'adaptive-ranking', 'graph',
        'mcp-gateway', 'daemon', 'hot-reload', 'self-modifying-policy',
        'auto-trust-elevation', 'cross-project-learning', 'otel',
        'sqlite-registry', 'tool-level-mcp-risk', 'skill-mass-migration',
        'multi-level-hierarchy', 'peer-to-peer', 'arbiter',
        'tool-exposure-unproven', 'hard-filter-exceptions'
    )
    $out = @()
    foreach ($id in $ids) {
        $out += [PSCustomObject]@{ id = [string]$id; status = 'deferred' }
    }
    return @($out)
}

function Get-DeferredFlagsView {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    try {
        $repo = Get-DeferredRepoRoot -RepoRoot $RepoRoot
        $resolved = $FlagsPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'source\registry\capability-flags.json'
        }
        $r = Read-DeferredJsonDoc -Path $resolved -MaxBytes 65536
        if (-not $r.Ok) {
            return [PSCustomObject]@{
                Available = $false; Error = [string]$r.Error
                Shadow = $null; RouterActive = $null; SkillEnabled = $null
                McpEnabled = $null; AdaptiveEnabled = $null
            }
        }
        $shadow = $null; $active = $null; $skill = $null; $mcp = $null; $adaptive = $null
        try {
            $n = Get-DeferredNodeProp -Node $r.Doc -Name 'capability_router'
            if ($null -ne $n) {
                $shadow = Get-DeferredNodeProp -Node $n -Name 'shadow'
                $active = Get-DeferredNodeProp -Node $n -Name 'active'
            }
        } catch { }
        try {
            $n = Get-DeferredNodeProp -Node $r.Doc -Name 'skill_routing'
            if ($null -ne $n) { $skill = Get-DeferredNodeProp -Node $n -Name 'enabled' }
        } catch { }
        try {
            $n = Get-DeferredNodeProp -Node $r.Doc -Name 'mcp_routing'
            if ($null -ne $n) { $mcp = Get-DeferredNodeProp -Node $n -Name 'enabled' }
        } catch { }
        try {
            $n = Get-DeferredNodeProp -Node $r.Doc -Name 'adaptive_ranking'
            if ($null -ne $n) { $adaptive = Get-DeferredNodeProp -Node $n -Name 'enabled' }
        } catch { }
        return [PSCustomObject]@{
            Available = $true; Error = ''
            Shadow = $shadow; RouterActive = $active; SkillEnabled = $skill
            McpEnabled = $mcp; AdaptiveEnabled = $adaptive
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false; Error = 'internal'
            Shadow = $null; RouterActive = $null; SkillEnabled = $null
            McpEnabled = $null; AdaptiveEnabled = $null
        }
    }
}

function Get-DeferredSpikeView {
    [CmdletBinding()]
    param([string]$SpikePath, [string]$RepoRoot)
    try {
        $repo = Get-DeferredRepoRoot -RepoRoot $RepoRoot
        $resolved = $SpikePath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'evidence\v3\mcp\enforcement-spike.json'
        }
        $r = Read-DeferredJsonDoc -Path $resolved -MaxBytes 65536
        if (-not $r.Ok) { return @{ Available = $false; Supported = $false; Error = ('spike ' + [string]$r.Error) } }
        $v = Get-DeferredNodeProp -Node $r.Doc -Name 'enforcement_supported'
        if ($v -is [bool] -and $v -eq $true) { return @{ Available = $true; Supported = $true; Error = '' } }
        return @{ Available = $true; Supported = $false; Error = '' }
    }
    catch { return @{ Available = $false; Supported = $false; Error = 'spike unreadable' } }
}

function Test-DeferredPathHasReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while (-not [string]::IsNullOrWhiteSpace($current) -and $guard -lt 128) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    $linkType = [string]$item.LinkType
                    if ($item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -ine 'HardLink') { return $true }
                } catch { }
            } catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-DeferredGovernedRecordView {
    [CmdletBinding()]
    param([string]$ActivationRecordPath, [string]$RepoRoot)
    try {
        $repo = Get-DeferredRepoRoot -RepoRoot $RepoRoot
        $resolved = $ActivationRecordPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'evidence\v3\activation\agent-routing-controlled.json'
        }
        $full = $resolved
        try {
            if ([IO.Path]::IsPathRooted($resolved)) { $full = [IO.Path]::GetFullPath($resolved) }
            else { $full = [IO.Path]::GetFullPath((Join-Path $repo $resolved)) }
        }
        catch { return @{ Available = $false; Valid = $false; Error = 'unreadable' } }
        if (Test-DeferredPathHasReparsePoint -Path $full) {
            return @{ Available = $false; Valid = $false; Error = 'reparse-point' }
        }
        # Confinamento anti self-assert: o registro governado so vale
        # dentro de evidence/v3/activation (repo) E com o nome canonico
        # agent-routing-controlled.json. Caminho externo ou nome
        # nao-canonico e rejeitado como nao-valido, de modo que nunca
        # satisfaz a invariante router-active-governed. Acesso de escrita
        # ao repo ja e o limite de confianca: quem pode escrever no repo
        # pode escrever o canonico.
        $allowedGovDir = ''
        try { $allowedGovDir = [IO.Path]::GetFullPath((Join-Path $repo 'evidence\v3\activation')) } catch { $allowedGovDir = '' }
        $govSep = $allowedGovDir.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ([string]::IsNullOrWhiteSpace($allowedGovDir) -or (-not $full.StartsWith($govSep, [System.StringComparison]::OrdinalIgnoreCase))) {
            return @{ Available = $false; Valid = $false; Error = 'activation-record fora de evidence/v3/activation (rejeitado; nao satisfaz governanca)' }
        }
        $govLeaf = ''
        try { $govLeaf = [IO.Path]::GetFileName($full) } catch { $govLeaf = '' }
        if ($govLeaf -cne 'agent-routing-controlled.json') {
            return @{ Available = $false; Valid = $false; Error = 'activation-record nao e o arquivo canonico agent-routing-controlled.json (rejeitado; nao satisfaz governanca)' }
        }
        $r = Read-DeferredJsonDoc -Path $full -MaxBytes 65536
        if (-not $r.Ok) { return @{ Available = $false; Valid = $false; Error = ('activation-record ' + [string]$r.Error) } }
        $doc = $r.Doc
        $stage = [string](Get-DeferredNodeProp -Node $doc -Name 'stage')
        $status = [string](Get-DeferredNodeProp -Node $doc -Name 'activation_status')
        $gatePass = Get-DeferredNodeProp -Node $doc -Name 'gate_pass'
        if (($stage -cne 'stage1') -or ($status -cne 'controlled_active') -or (-not ($gatePass -is [bool] -and $gatePass -eq $true))) {
            return @{ Available = $true; Valid = $false; Error = 'record not controlled_active stage1 with gate_pass=true' }
        }
        $fl = Get-DeferredNodeProp -Node $doc -Name 'flags'
        if ($null -eq $fl) { return @{ Available = $true; Valid = $false; Error = 'record sem flags' } }
        $cr = Get-DeferredNodeProp -Node $fl -Name 'capability_router'
        $sk = Get-DeferredNodeProp -Node $fl -Name 'skill_routing'
        $mc = Get-DeferredNodeProp -Node $fl -Name 'mcp_routing'
        $ad = Get-DeferredNodeProp -Node $fl -Name 'adaptive_ranking'
        $crActive = $null; $skOn = $null; $mcOn = $null; $adOn = $null
        try { if ($null -ne $cr) { $crActive = Get-DeferredNodeProp -Node $cr -Name 'active' } } catch { }
        try { if ($null -ne $sk) { $skOn = Get-DeferredNodeProp -Node $sk -Name 'enabled' } } catch { }
        try { if ($null -ne $mc) { $mcOn = Get-DeferredNodeProp -Node $mc -Name 'enabled' } } catch { }
        try { if ($null -ne $ad) { $adOn = Get-DeferredNodeProp -Node $ad -Name 'enabled' } } catch { }
        $isTrue = { param($v) return (($v -is [bool]) -and ($v -eq $true)) }
        $isFalse = { param($v) return (($v -is [bool]) -and ($v -eq $false)) }
        if ((& $isTrue $crActive) -and (& $isFalse $skOn) -and (& $isFalse $mcOn) -and (& $isFalse $adOn)) {
            return @{ Available = $true; Valid = $true; Error = '' }
        }
        return @{ Available = $true; Valid = $false; Error = 'record flags divergem (exige router active=true + skill/mcp/adaptive=false)' }
    }
    catch { return @{ Available = $false; Valid = $false; Error = 'internal' } }
}

function Get-DeferredAuthorityView {
    [CmdletBinding()]
    param([string]$ConfigPath, [bool]$IsDefaultPath = $true)
    try {
        $resolved = $ConfigPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        }
        $hash = Get-DeferredFileHash -Path $resolved
        $r = Read-DeferredJsonDoc -Path $resolved -MaxBytes 0
        if (-not $r.Ok) {
            return [PSCustomObject]@{
                Available = $false; Error = ('config ' + [string]$r.Error)
                AllowNames = @(); Wild = ''; Hash = [string]$hash
                ExpectedOk = $false; HashMatchesKnown = $null
            }
        }
        $names = @()
        $wild = ''
        try {
            $agent = Get-DeferredNodeProp -Node $r.Doc -Name 'agent'
            $build = $null; $perm = $null; $task = $null
            if ($null -ne $agent) { $build = Get-DeferredNodeProp -Node $agent -Name 'build' }
            if ($null -ne $build) { $perm = Get-DeferredNodeProp -Node $build -Name 'permission' }
            if ($null -ne $perm) { $task = Get-DeferredNodeProp -Node $perm -Name 'task' }
            if ($null -ne $task) {
                if ($task -is [System.Collections.IDictionary]) {
                    foreach ($k in @($task.Keys)) {
                        if ("$k" -ceq '*') { $wild = [string]$task[$k] }
                        elseif ([string]$task[$k] -ceq 'allow') { $names += [string]$k }
                    }
                }
                else {
                    foreach ($pp in @($task.PSObject.Properties)) {
                        if ($pp.Name -ceq '*') { $wild = [string]$pp.Value }
                        elseif ([string]$pp.Value -ceq 'allow') { $names += [string]$pp.Name }
                    }
                }
            }
        }
        catch { }
        $sorted = @($names)
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $expected = @(Get-DeferredExpectedAllowlist)
        $exactOk = ($sorted.Count -eq $expected.Count)
        if ($exactOk) {
            for ($i = 0; $i -lt $sorted.Count; $i++) {
                if ($sorted[$i] -cne $expected[$i]) { $exactOk = $false; break }
            }
        }
        $wildOk = ($wild -ceq 'deny')
        $hashMatch = $null
        if ($IsDefaultPath) {
            $known = Get-DeferredKnownOpencodeHash
            $hashMatch = ($hash -ceq $known)
        }
        return [PSCustomObject]@{
            Available = $true; Error = ''
            AllowNames = @($sorted); Wild = [string]$wild; Hash = [string]$hash
            ExpectedOk = [bool]($exactOk -and $wildOk); HashMatchesKnown = $hashMatch
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false; Error = 'internal'
            AllowNames = @(); Wild = ''; Hash = 'UNREADABLE'
            ExpectedOk = $false; HashMatchesKnown = $null
        }
    }
}

function Get-DeferredArtifactView {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $checks = New-Object System.Collections.ArrayList
    try {
        $repo = Get-DeferredRepoRoot -RepoRoot $RepoRoot
        $addCheck = {
            param([string]$Name, [bool]$Pass, [string]$Detail)
            [void]$checks.Add([PSCustomObject]@{ name = $Name; pass = [bool]$Pass; detail = $Detail })
        }
        $findMatches = {
            param([string[]]$Patterns)
            $hits = @()
            $v3d = Join-Path $repo 'scripts\v3'
            foreach ($pat in $Patterns) {
                try {
                    if (Test-Path -LiteralPath $v3d -PathType Container) {
                        $found = @(Get-ChildItem -LiteralPath $v3d -Filter $pat -File -ErrorAction SilentlyContinue | Select-Object -First 5)
                        foreach ($f in $found) { $hits += ('scripts/v3/' + $f.Name) }
                    }
                } catch { }
            }
            return @($hits)
        }
        $testRelatives = {
            param([string[]]$Rels)
            $hits = @()
            foreach ($rel in $Rels) {
                try {
                    if (Test-Path -LiteralPath (Join-Path $repo $rel)) { $hits += $rel }
                } catch { }
            }
            return @($hits)
        }
        $testGlobs = {
            param([string]$Dir, [string]$Filter)
            $hits = @()
            try {
                $d = Join-Path $repo $Dir
                if (Test-Path -LiteralPath $d -PathType Container) {
                    $found = @(Get-ChildItem -LiteralPath $d -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 5)
                    foreach ($f in $found) { $hits += ($Dir + '\' + $f.Name) }
                }
            } catch { }
            return @($hits)
        }

        $vHits = @()
        $vHits += @(& $testRelatives @('cache\v3\vector-store.json', 'cache\v3\embeddings.json', 'source\registry\capability-embeddings.json', 'source\registry\vector-store.json'))
        $vHits += @(& $testGlobs 'cache\v3' '*vector*')
        $vHits += @(& $testGlobs 'cache\v3' '*embedding*')
        $vHits += @(& $testGlobs 'evidence\v3' '*vector*')
        $vHits += @(& $testGlobs 'evidence\v3' '*embedding*')
        $vHits += @(& $testGlobs 'source\registry' '*vector*')
        $vHits += @(& $testGlobs 'source\registry' '*embedding*')
        $vHits += @(& $findMatches @('*vector*.ps1', '*embedding*.ps1'))
        if ($vHits.Count -eq 0) { & $addCheck 'no-vector-db-embeddings' $true 'nenhum arquivo/dir de vector DB ou embeddings' }
        else { & $addCheck 'no-vector-db-embeddings' $false ('artefatos de vector/embeddings presentes: ' + (($vHits | Select-Object -First 5) -join ', ')) }

        $depFiles = @('source\registry\capability-flags.json', 'source\registry\capability-policy.json', 'source\registry\runtimes.json', 'opencode\package.json')
        $depTokens = @('faiss', 'chromadb', 'pgvector', 'sqlite-vec', 'sqlite_vec', 'sentence-transformers', 'qdrant', 'weaviate', 'pinecone', 'neo4j', 'onnxruntime', 'opentelemetry')
        $depHits = @()
        foreach ($rel in $depFiles) {
            $p = Join-Path $repo $rel
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $text = ''
            try {
                $text = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))
                if ($text.Length -gt 262144) { $text = $text.Substring(0, 262144) }
            } catch { continue }
            foreach ($tok in $depTokens) {
                if ($text.ToLowerInvariant().Contains($tok)) { $depHits += ($rel + ':' + $tok) }
            }
            if ([regex]::IsMatch($text, '\botel\b', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $depHits += ($rel + ':otel') }
        }
        if ($depHits.Count -eq 0) { & $addCheck 'no-dependency-tokens' $true 'nenhum token de vector/graph/OTEL nos JSONs governados' }
        else { & $addCheck 'no-dependency-tokens' $false ('tokens de dependencia encontrados: ' + (($depHits | Select-Object -First 5) -join ', ')) }

        $gHits = @()
        $gHits += @(& $testRelatives @('source\registry\capability-graph.json', 'cache\v3\capability-graph.json', 'evidence\v3\graph'))
        $gHits += @(& $testGlobs 'source\registry' '*graph*')
        $gHits += @(& $testGlobs 'cache\v3' '*graph*')
        $gHits += @(& $findMatches @('*graph*.ps1'))
        if ($gHits.Count -eq 0) { & $addCheck 'no-graph-artifacts' $true 'nenhum artefato de graph store' }
        else { & $addCheck 'no-graph-artifacts' $false ('artefatos de graph presentes: ' + (($gHits | Select-Object -First 5) -join ', ')) }

        $dHits = @()
        $dHits += @(& $testRelatives @('evidence\v3\daemon', 'cache\v3\daemon'))
        $dHits += @(& $findMatches @('*daemon*.ps1'))
        $dHits += @(& $testGlobs 'cache\v3' '*daemon*')
        if ($dHits.Count -eq 0) { & $addCheck 'no-daemon-artifacts' $true 'nenhum daemon/servico persistente' }
        else { & $addCheck 'no-daemon-artifacts' $false ('artefatos de daemon presentes: ' + (($dHits | Select-Object -First 5) -join ', ')) }

        $gwHits = @()
        $gwHits += @(& $testRelatives @('source\registry\mcp-gateway.json', 'evidence\v3\mcp\gateway.json'))
        $gwHits += @(& $findMatches @('*gateway*.ps1'))
        $gwHits += @(& $testGlobs 'source\registry' '*gateway*')
        $gwHits += @(& $testGlobs 'evidence\v3\mcp' '*gateway*')
        if ($gwHits.Count -eq 0) { & $addCheck 'no-mcp-gateway' $true 'nenhum MCP gateway' }
        else { & $addCheck 'no-mcp-gateway' $false ('artefatos de MCP gateway presentes: ' + (($gwHits | Select-Object -First 5) -join ', ')) }

        $liteHits = @()
        $liteHits += @(& $testGlobs 'cache\v3' '*.db')
        $liteHits += @(& $testGlobs 'cache\v3' '*.sqlite*')
        $liteHits += @(& $testGlobs 'source\registry' '*.db')
        $liteHits += @(& $testGlobs 'source\registry' '*.sqlite*')
        if ($liteHits.Count -eq 0) { & $addCheck 'no-sqlite-registry' $true 'nenhum SQLite registry (*.db/*.sqlite*)' }
        else { & $addCheck 'no-sqlite-registry' $false ('arquivos SQLite presentes: ' + (($liteHits | Select-Object -First 5) -join ', ')) }

        $otelHits = @()
        $otelHits += @(& $testRelatives @('evidence\v3\otel', 'cache\v3\otel'))
        if ($otelHits.Count -eq 0) { & $addCheck 'no-otel-artifacts' $true 'nenhum artefato OTEL dedicado' }
        else { & $addCheck 'no-otel-artifacts' $false ('artefatos OTEL presentes: ' + (($otelHits | Select-Object -First 5) -join ', ')) }

        return @{ Checks = @($checks) }
    }
    catch {
        return @{ Checks = @([PSCustomObject]@{ name = 'artifact-scan'; pass = $false; detail = 'scan interno falhou (fail-safe)' }) }
    }
}

function Get-DeferredOrchestrationView {
    [CmdletBinding()]
    param($Policy, [string]$PolicyError, $FlagsView, $SpikeView, $AuthorityView, $GovernedView)
    $checks = New-Object System.Collections.ArrayList
    try {
        $addCheck = {
            param([string]$Name, [bool]$Pass, [string]$Detail)
            [void]$checks.Add([PSCustomObject]@{ name = $Name; pass = [bool]$Pass; detail = $Detail })
        }
        $flagsOk = $false
        try { $flagsOk = [bool]$FlagsView.Available } catch { $flagsOk = $false }
        $routerActive = $null; $skillOn = $null; $mcpOn = $null; $adaptiveOn = $null
        try { $routerActive = $FlagsView.RouterActive } catch { }
        try { $skillOn = $FlagsView.SkillEnabled } catch { }
        try { $mcpOn = $FlagsView.McpEnabled } catch { }
        try { $adaptiveOn = $FlagsView.AdaptiveEnabled } catch { }
        $isFalse = { param($v) return (($v -is [bool]) -and ($v -eq $false)) }
        $isTrue = { param($v) return (($v -is [bool]) -and ($v -eq $true)) }
        $governedOk = $false
        try { $governedOk = ([bool]$GovernedView.Valid) } catch { $governedOk = $false }

        if (-not $flagsOk) { & $addCheck 'router-active-governed' $false 'flags ilegiveis; estado ativo nao comprovadamente desligado nem governado' }
        elseif (& $isFalse $routerActive) { & $addCheck 'router-active-governed' $true 'capability_router.active=false' }
        elseif ((& $isTrue $routerActive) -and $governedOk) { & $addCheck 'router-active-governed' $true 'capability_router.active=true sob ativacao controlada Stage 1 valida (agent-routing-controlled.json)' }
        else { & $addCheck 'router-active-governed' $false ('capability_router.active=true sem registro governado valido (obtido: ' + [string]$routerActive + ')') }

        if (-not $flagsOk) { & $addCheck 'skill-execution-off' $false 'flags ilegíveis; skill execution nao comprovadamente desligada' }
        elseif (& $isFalse $skillOn) { & $addCheck 'skill-execution-off' $true 'skill_routing.enabled=false (ponte somente identidade/intencao)' }
        else { & $addCheck 'skill-execution-off' $false ('skill_routing.enabled nao e false (obtido: ' + [string]$skillOn + ')') }

        if (-not $flagsOk) { & $addCheck 'tool-exposure-off' $false 'flags ilegíveis; tool exposure nao comprovadamente desligado' }
        elseif (& $isFalse $mcpOn) { & $addCheck 'tool-exposure-off' $true 'mcp_routing.enabled=false (tool_exposure adiado)' }
        else { & $addCheck 'tool-exposure-off' $false ('mcp_routing.enabled nao e false (obtido: ' + [string]$mcpOn + ')') }

        if (-not $flagsOk) { & $addCheck 'adaptive-ranking-off' $false 'flags ilegíveis; adaptive ranking nao comprovadamente desligado' }
        elseif (& $isFalse $adaptiveOn) { & $addCheck 'adaptive-ranking-off' $true 'adaptive_ranking.enabled=false' }
        else { & $addCheck 'adaptive-ranking-off' $false ('adaptive_ranking.enabled nao e false (obtido: ' + [string]$adaptiveOn + ')') }

        $spikeSupported = $false
        try { $spikeSupported = [bool]$SpikeView.Supported } catch { $spikeSupported = $false }
        $spikeAvail = $false
        try { $spikeAvail = [bool]$SpikeView.Available } catch { $spikeAvail = $false }
        if (-not $spikeAvail) { & $addCheck 'no-presumed-enforcement' $false 'spike MCP ilegível; enforcement nao comprovadamente ausente' }
        elseif ($spikeSupported) { & $addCheck 'no-presumed-enforcement' $false 'enforcement_supported=true no spike; reavaliar lista de adiados (esperado false nesta fase)' }
        else { & $addCheck 'no-presumed-enforcement' $true 'enforcement_supported=false; nenhum enforcement presumido' }

        if ((& $isFalse $mcpOn) -eq $false -and ($mcpOn -is [bool]) -and ($mcpOn -eq $true) -and (-not $spikeSupported)) {
            & $addCheck 'mcp-never-active-without-spike' $false 'mcp_routing.enabled=true com enforcement_supported=false; nunca ativa sem enforcement'
        }
        else {
            & $addCheck 'mcp-never-active-without-spike' $true 'mcp_routing nunca ativo sem enforcement (spike false + flag false)'
        }

        if ([string]::IsNullOrWhiteSpace($PolicyError) -and ($null -ne $Policy)) {
            $skillNotes = ''
            $mcpNotes = ''
            try {
                $sb = Get-DeferredNodeProp -Node $Policy -Name 'skill_bridge'
                if ($null -ne $sb) { $skillNotes = [string](Get-DeferredNodeProp -Node $sb -Name 'notes') }
            } catch { $skillNotes = '' }
            try {
                $mr = Get-DeferredNodeProp -Node $Policy -Name 'mcp_routing'
                if ($null -ne $mr) { $mcpNotes = [string](Get-DeferredNodeProp -Node $mr -Name 'notes') }
            } catch { $mcpNotes = '' }
            $skillOffline = (($skillNotes -imatch 'OFFLINE') -and (($skillNotes -imatch 'read-only') -or ($skillNotes -imatch 'read only')))
            if ($skillOffline) { & $addCheck 'policy-skill-offline' $true 'skill_bridge documentado como OFFLINE/read-only' }
            else { & $addCheck 'policy-skill-offline' $false 'skill_bridge sem marcacao OFFLINE/read-only na policy' }
            $mcpAdvisory = (($mcpNotes -imatch 'OFFLINE') -and (($mcpNotes -imatch 'advisory') -or ($mcpNotes -imatch 'NAO habilitados')))
            if ($mcpAdvisory) { & $addCheck 'policy-mcp-advisory' $true 'mcp_routing documentado como OFFLINE/advisory (execucao NAO habilitada)' }
            else { & $addCheck 'policy-mcp-advisory' $false 'mcp_routing sem marcacao OFFLINE/advisory na policy' }
            $hardEmpty = $true
            $hardDetail = 'exceptions.hard_filter vazio (sem excecoes)'
            try {
                $exc = Get-DeferredNodeProp -Node $Policy -Name 'exceptions'
                if ($null -ne $exc) {
                    $hf = Get-DeferredNodeProp -Node $exc -Name 'hard_filter'
                    if ($null -ne $hf -and (@($hf).Count -gt 0)) {
                        $hardEmpty = $false
                        $hardDetail = ('exceptions.hard_filter com excecoes ativas: ' + ((@($hf) | ForEach-Object { "$_" }) -join ', '))
                    }
                }
            } catch { $hardEmpty = $false; $hardDetail = 'exceptions.hard_filter ilegível (fail-safe)' }
            & $addCheck 'hard-filter-no-exceptions' $hardEmpty $hardDetail
        }
        else {
            & $addCheck 'policy-skill-offline' $false ('policy ilegível: ' + [string]$PolicyError)
            & $addCheck 'policy-mcp-advisory' $false ('policy ilegível: ' + [string]$PolicyError)
            & $addCheck 'hard-filter-no-exceptions' $false ('policy ilegível: ' + [string]$PolicyError)
        }

        $authOk = $false
        try { $authOk = ([bool]$AuthorityView.Available -and [bool]$AuthorityView.ExpectedOk) } catch { $authOk = $false }
        if ($authOk) { & $addCheck 'authority-unchanged' $true 'agent.build.permission.task com os 19 IDs esperados e * = deny' }
        else { & $addCheck 'authority-unchanged' $false 'authority divergiu do esperado (allowlist ou wildcard)' }

        return @{ Checks = @($checks) }
    }
    catch {
        return @{ Checks = @([PSCustomObject]@{ name = 'orchestration-scan'; pass = $false; detail = 'scan interno falhou (fail-safe)' }) }
    }
}

function Invoke-CapabilityDeferred {
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$FlagsPath,
        [string]$PolicyPath,
        [string]$ConfigPath,
        [string]$SpikePath,
        [string]$ActivationRecordPath
    )
    try {
        $repo = Get-DeferredRepoRoot -RepoRoot $RepoRoot
        $flagsView = Get-DeferredFlagsView -FlagsPath $FlagsPath -RepoRoot $repo
        $spikeView = Get-DeferredSpikeView -SpikePath $SpikePath -RepoRoot $repo
        $governedView = Get-DeferredGovernedRecordView -ActivationRecordPath $ActivationRecordPath -RepoRoot $repo
        $isDefaultCfg = [string]::IsNullOrWhiteSpace($ConfigPath)
        $authView = Get-DeferredAuthorityView -ConfigPath $ConfigPath -IsDefaultPath $isDefaultCfg
        $polFile = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($polFile)) {
            $polFile = Join-Path $repo 'source\registry\capability-policy.json'
        }
        $policyDoc = $null
        $policyErr = ''
        $pr = Read-DeferredJsonDoc -Path $polFile -MaxBytes 65536
        if ($pr.Ok) { $policyDoc = $pr.Doc } else { $policyErr = [string]$pr.Error }
        $artView = Get-DeferredArtifactView -RepoRoot $repo
        $orchView = Get-DeferredOrchestrationView -Policy $policyDoc -PolicyError $policyErr -FlagsView $flagsView -SpikeView $spikeView -AuthorityView $authView -GovernedView $governedView

        $reasons = @()
        $governedOk = $false
        try { $governedOk = ([bool]$governedView.Valid) } catch { $governedOk = $false }
        if (-not [bool]$flagsView.Available) {
            $reasons += ('flags: capability-flags.json ilegivel (' + [string]$flagsView.Error + '); estado ativo nao comprovadamente desligado')
        }
        else {
            $routerOn = (($flagsView.RouterActive -is [bool]) -and ($flagsView.RouterActive -eq $true))
            $routerOff = (($flagsView.RouterActive -is [bool]) -and ($flagsView.RouterActive -eq $false))
            if (-not $routerOff -and -not ($routerOn -and $governedOk)) {
                if ($routerOn) {
                    $reasons += ('flags: capability_router.active=true sem registro governado valido (agent-routing-controlled.json stage1/controlled_active); routing ativo nao governado nao permitido')
                }
                else {
                    $reasons += ('flags: capability_router.active nao e false (obtido: ' + [string]$flagsView.RouterActive + '); routing ativo nao permitido na fase de adiados')
                }
            }
            if (-not (($flagsView.SkillEnabled -is [bool]) -and ($flagsView.SkillEnabled -eq $false))) {
                $reasons += ('flags: skill_routing.enabled nao e false (obtido: ' + [string]$flagsView.SkillEnabled + ')')
            }
            if (-not (($flagsView.McpEnabled -is [bool]) -and ($flagsView.McpEnabled -eq $false))) {
                $reasons += ('flags: mcp_routing.enabled nao e false (obtido: ' + [string]$flagsView.McpEnabled + ')')
            }
            if (-not (($flagsView.AdaptiveEnabled -is [bool]) -and ($flagsView.AdaptiveEnabled -eq $false))) {
                $reasons += ('flags: adaptive_ranking.enabled nao e false (obtido: ' + [string]$flagsView.AdaptiveEnabled + ')')
            }
        }
        $spikeSupported = $false
        try { $spikeSupported = [bool]$spikeView.Supported } catch { $spikeSupported = $false }
        $spikeAvail = $false
        try { $spikeAvail = [bool]$spikeView.Available } catch { $spikeAvail = $false }
        if (-not $spikeAvail) {
            $reasons += 'spike: evidence/v3/mcp/enforcement-spike.json ilegivel; enforcement nao comprovadamente ausente'
        }
        elseif ($spikeSupported) {
            $reasons += 'spike: enforcement_supported=true; reavaliar lista de adiados (esperado false nesta fase)'
        }
        $mcpOn = $false
        try { $mcpOn = (($flagsView.McpEnabled -is [bool]) -and ($flagsView.McpEnabled -eq $true)) } catch { $mcpOn = $false }
        if ($mcpOn -and (-not $spikeSupported)) {
            $reasons += 'mcp: mcp_routing.enabled=true com enforcement_supported=false no spike; nunca ativa sem enforcement'
        }
        if (-not [bool]$authView.Available) {
            $reasons += ('authority: opencode.json ilegivel (' + [string]$authView.Error + ')')
        }
        else {
            if (-not [bool]$authView.ExpectedOk) {
                $reasons += ('authority: agent.build.permission.task diverge do esperado (19 IDs + *=deny); obtidos: ' + ((@($authView.AllowNames) | ForEach-Object { "$_" }) -join ', ') + ' (*=' + [string]$authView.Wild + ')')
            }
            if ($isDefaultCfg -and ($authView.HashMatchesKnown -is [bool]) -and (-not [bool]$authView.HashMatchesKnown)) {
                $reasons += ('authority: hash do opencode.json divergiu do baseline conhecido DE22307F... (obtido: ' + [string]$authView.Hash + '); mudanca estrutural inesperada')
            }
        }
        foreach ($c in @($artView.Checks)) {
            if (-not [bool]$c.pass) { $reasons += ('artifacts: ' + [string]$c.name + ' :: ' + [string]$c.detail) }
        }
        foreach ($c in @($orchView.Checks)) {
            if (-not [bool]$c.pass) {
                $dup = $false
                foreach ($r in @($reasons)) {
                    if ($r.Contains([string]$c.name)) { $dup = $true; break }
                }
                if (-not $dup) { $reasons += ('orchestration: ' + [string]$c.name + ' :: ' + [string]$c.detail) }
            }
        }

        $decision = 'ok'
        if (@($reasons).Count -gt 0) { $decision = 'drift' }
        return [PSCustomObject]@{
            decision = [string]$decision
            reasons = @($reasons)
            flags = $flagsView
            flags_error = ([string]$flagsView.Error)
            spike_supported = [bool]$spikeSupported
            spike_error = ([string]$spikeView.Error)
            governed_record_valid = [bool]$governedOk
            governed_record_error = ([string]$governedView.Error)
            authority = $authView
            artifacts = @($artView.Checks)
            orchestration = @($orchView.Checks)
            deferred_items = @(Get-DeferredItems)
            opencode_hash = [string]$authView.Hash
        }
    }
    catch {
        return [PSCustomObject]@{
            decision = 'drift'
            reasons = @('deferred: erro interno contido (fail-safe)')
            flags = [PSCustomObject]@{ Available = $false; Error = 'internal'; Shadow = $null; RouterActive = $null; SkillEnabled = $null; McpEnabled = $null; AdaptiveEnabled = $null }
            flags_error = 'internal'
            spike_supported = $false
            spike_error = 'internal'
            governed_record_valid = $false
            governed_record_error = 'internal'
            authority = [PSCustomObject]@{ Available = $false; Error = 'internal'; AllowNames = @(); Wild = ''; Hash = 'UNREADABLE'; ExpectedOk = $false; HashMatchesKnown = $null }
            artifacts = @([PSCustomObject]@{ name = 'artifact-scan'; pass = $false; detail = 'erro interno contido (fail-safe)' })
            orchestration = @([PSCustomObject]@{ name = 'orchestration-scan'; pass = $false; detail = 'erro interno contido (fail-safe)' })
            deferred_items = @(Get-DeferredItems)
            opencode_hash = 'UNREADABLE'
        }
    }
}
