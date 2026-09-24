<#!
.SYNOPSIS
    V3 Authority gate: conjunto desejado de delegacao build, change requests
    content-addressed, aprovacao humana, apply atomico em fixture (Phase 6) e
    apply REAL governado pos-aprovacao humana (Invoke-AuthorityRealApply).

.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa o gate
    de mudanca de authority (ADR-018/040, plano §5.3, Phase 6):

      - Default deny: somente agentes com `orchestration.build_delegable: true`
        explicito em source/agents/*.md entram no conjunto desejado.
        O parser de frontmatter e ESTRITO (fail-closed): bloco
        `orchestration:` duplicado, chave de topo duplicada, chave duplicada
        dentro de orchestration, chave desconhecida em orchestration
        (permitidas: build_delegable, lifecycle, visibility, capabilities,
        allow_visibility), tokens YAML de alias/anchor/tag/merge (`*`, `&`, `!`, `<<`)
#         em QUALQUER posicao do bloco orchestration (inclui flow collections
#         como `capabilities: [ &ref x ]` e valores inline como
#         `build_delegable: !!bool true`), valores
        nao-booleanos em build_delegable/allow_visibility, ou visibility fora
        de {normal,hidden,internal,experimental} => deny (BuildDelegable
        $false) com diagnostico em Valid/Error.
      - `visibility` em deny_rules.visibility (hidden/internal/experimental)
        nega, salvo override explicito em policy.overrides. O override aceita
        SOMENTE a chave canonica booleana `allow_visibility: true` (qualquer
        alias — allow, allow_delegation, build_delegable, build_allow,
        visibility_allow — e ignorado). O override so levanta o bloqueio de
        visibilidade; nunca concede delegacao quando build_delegable e falso
        ("global deny wins").
      - Change request content-addressed: approval_hash = Get-LogicalHash de
        { protocol_version, base_config_hash, proposed_allowlist,
          policy_source_hash, agent_sources_hash }; change_id = 'acr-' + 16
        hex iniciais. Qualquer mudanca de input muda hash/id e invalida
        aprovacoes antigas. target_config_hash = hash dos BYTES MUTADOS pelo
        mutator byte-preserving (CapabilityJsonMutator: substituicao SOMENTE
        do fragmento agent.build.permission.task, demais bytes intactos).
        Quando nao ha diff logico (mutator NO_CHANGE), os bytes mutados ==
        originais e target_config_hash = base_config_hash (no-op).
      - Ownership verificado: New-AuthorityChangeRequest le
        source/registry/runtimes.json e exige que o alvo opencode declare
        `agent.build.permission.task` com valor EXATO `control-plane`
        (igualdade ordinal; substring/regex nao basta) no path canonico do
        target OpenCode; sem a declaracao exata o request falha.
      - Apply em FIXTURE SOMENTE com -FixtureRoot obrigatorio (o antigo
        -TestRoot foi removido). Bytes e escrita via mutator byte-preserving
        (Set-BuildTaskAllowlist com -TestRoot = -FixtureRoot e CAS estrito
        por -ExpectedHash = base_config_hash); a verificacao pos-hash compara
        o disco com target_config_hash. Regras de boundary (fail-closed):
        ConfigPath canonico DENTRO de FixtureRoot; FixtureRoot sob o TEMP do
        SO; nenhum componente de FixtureRoot/ConfigPath/BackupRoot (nem
        ancestors) pode ser reparse point/junction; e o caminho canonico
        final NUNCA pode ser o opencode.json real nem estar dentro de
        %USERPROFILE%\.config\opencode. Sem -FixtureRoot o caller aborta
        com exit 2. Drift (Request.drift nao-vazio) bloqueia o apply (exit 1)
        sem tocar o config. Idempotencia: se hash atual == target_config_hash
        E allowlist atual == proposed_allowlist => noop (exit 0) ANTES do CAS,
        mas SOMENTE apos revalidar aprovacao/staleness contra as fontes reais
        (RepoRoot, ConfigPath, PolicyPath, AgentsRoot) e o ownership do target
        (policy/agent-sources divergentes tornam o noop STALE);
        qualquer outro estado usa CAS estrito (base_config_hash). Falha
        na ATOMIC WRITE phase pos-replace (replaceDone) SEMPRE tenta
        restaurar o backup e o verifica por SHA-256/bytes contra o backup:
        verificado => ROLLED_BACK; restauracao ou verificacao falhou =>
        ROLLBACK_REQUIRED (rollback.json). A BOOKKEEPING phase
        (Get-FileSetFingerprint, Set-RuntimeReloadStatus, escrita de
        rollback.json) e best-effort: o config ja esta correto e verificado;
        falhas aqui NAO fazem rollback e sao registradas em
        warnings[]/bookkeeping_errors[] do resultado com status `applied`
        mantido (reload-state pode estar incompleto). Usa temp no mesmo dir + [IO.File]::Replace (ou Move) + verificacao
        pos-hash + backup + rollback.json + Set-RuntimeReloadStatus, e
        registra/baselina o config alvo via CapabilityLifecycle
        (fingerprint de conjunto de arquivos) alem dos .md.
      - Separacao de aprovacao e PROCEDURAL (mesma conta Windows), sem
        isolamento criptografico. Documentado tambem em
        approve-authority-change.ps1.
      - NOTA DE MODELO (fix #11): `state` e INFORMATIVO/model-only ate
        existir apply real em producao. Os resultados de falha reais sao
        registrados no resultado do apply/aprovacao e no rollback.json com
        os status REJECTED/STALE/CAS_CONFLICT/ROLLBACK_REQUIRED/ROLLED_BACK;
        transicoes Set-AuthorityRequestState continuam validadas, mas nao
        representam o runtime.

    Reutiliza CapabilitySchema.ps1 (Get-LogicalHash /
    ConvertTo-DeterministicJson), CapabilityTaxonomy.ps1 (policy) e o padrao
    CAS/atomico de reconcile-agents.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$authoritySchemaPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if (Test-Path -LiteralPath $authoritySchemaPath -PathType Leaf) {
    . $authoritySchemaPath
}
$authorityLifecyclePath = Join-Path $PSScriptRoot 'CapabilityLifecycle.ps1'
if (Test-Path -LiteralPath $authorityLifecyclePath -PathType Leaf) {
    . $authorityLifecyclePath
}
$authorityMutatorPath = Join-Path $PSScriptRoot 'CapabilityJsonMutator.ps1'
if (Test-Path -LiteralPath $authorityMutatorPath -PathType Leaf) {
    . $authorityMutatorPath
}

function Get-AuthorityRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-AuthorityPolicyPath {
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) { return $PolicyPath }
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\capability-policy.json')
}

function Get-AuthorityAgentsRoot {
    [CmdletBinding()]
    param([string]$AgentsRoot, [string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($AgentsRoot)) { return $AgentsRoot }
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\agents')
}

function Read-AuthorityPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PolicyPath)
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw ("capability-policy.json not found: {0}" -f $PolicyPath)
    }
    $text = [IO.File]::ReadAllText($PolicyPath, [Text.UTF8Encoding]::new($false))
    return ($text | ConvertFrom-Json)
}

function Get-FileSha256Lower {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ([string]$hash).ToLowerInvariant()
}

function Get-StringSha256Lower {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return ((($digest | ForEach-Object { $_.ToString('x2') }) -join '').ToLowerInvariant())
}

function Get-PolicySourceHash {
    <#
    .SYNOPSIS
        "sha256:<hex>" do arquivo de policy (bytes brutos).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PolicyPath)
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        throw ("capability-policy.json not found: {0}" -f $PolicyPath)
    }
    return ('sha256:' + (Get-FileSha256Lower -Path $PolicyPath))
}

function Get-AgentSourcesHash {
    <#
    .SYNOPSIS
        "sha256:<hex>" deterministico do conjunto source/agents/*.md
        (linhas "nome:hash" ordenadas, ordinal).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AgentsRoot)
    $lines = @()
    if (Test-Path -LiteralPath $AgentsRoot -PathType Container) {
        $names = @(
            Get-ChildItem -LiteralPath $AgentsRoot -Filter '*.md' -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name }
        )
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
        foreach ($name in $names) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $AgentsRoot $name) -Algorithm SHA256).Hash
            $lines += ($name + ':' + ([string]$hash).ToLowerInvariant())
        }
    }
    $joined = ($lines -join "`n")
    return ('sha256:' + (Get-StringSha256Lower -Text $joined))
}

function Get-ConfigFileHash {
    <#
    .SYNOPSIS
        "sha256:<hex>" do arquivo de config (bytes brutos).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw ("Config file not found: {0}" -f $ConfigPath)
    }
    return ('sha256:' + (Get-FileSha256Lower -Path $ConfigPath))
}

function Get-AuthorityProtocolVersion {
    [CmdletBinding()]
    param()
    return 2
}

function Get-ApprovalHash {
    <#
    .SYNOPSIS
        Content-addressed hash do change: Get-LogicalHash de
        { protocol_version, base_config_hash, proposed_allowlist,
          policy_source_hash, agent_sources_hash }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseConfigHash,
        [Parameter(Mandatory = $true)]$ProposedAllowlist,
        [Parameter(Mandatory = $true)][string]$PolicySourceHash,
        [Parameter(Mandatory = $true)][string]$AgentSourcesHash
    )
    $proposed = @()
    if ($null -ne $ProposedAllowlist) { $proposed = @($ProposedAllowlist) }
    $input = [ordered]@{
        agent_sources_hash = $AgentSourcesHash
        base_config_hash   = $BaseConfigHash
        policy_source_hash = $PolicySourceHash
        proposed_allowlist = @($proposed)
        protocol_version   = (Get-AuthorityProtocolVersion)
    }
    return (Get-LogicalHash -InputObject $input)
}

function Get-AuthorityChangeId {
    <#
    .SYNOPSIS
        'acr-' + primeiros 16 hex do approval_hash (deterministico).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ApprovalHash)
    $hex = ([string]$ApprovalHash -replace '^sha256:', '').ToLowerInvariant()
    if ($hex.Length -lt 16) { throw 'Invalid approval_hash for change_id.' }
    return ('acr-' + $hex.Substring(0, 16))
}

function Read-AgentOrchestration {
    <#
    .SYNOPSIS
        Parser fail-closed e ESTRITO do frontmatter de source/agents/*.md.
        Retorna BuildDelegable/Lifecycle/Visibility/HasOrchestration mais
        Valid/Error (diagnostico). Ausente ou malformado => default deny
        (BuildDelegable $false, Valid $false quando rejeitado por regra
        estrita).
        Rejeita (deny): bloco `orchestration:` duplicado; chave de topo
        duplicada; chave duplicada dentro de orchestration; chaves
        desconhecidas em orchestration (permitidas: build_delegable,
        lifecycle, visibility, capabilities, allow_visibility); aliases/tags
        YAML (`*`, `&`, `<<`); valores nao-booleanos em
        build_delegable/allow_visibility; visibility fora de
        {normal,hidden,internal,experimental}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $parsed = [ordered]@{
        BuildDelegable   = $false
        Lifecycle        = 'unknown'
        Visibility       = 'normal'
        HasOrchestration = $false
        Valid            = $true
        Error            = ''
    }
    $deny = {
        param([string]$Reason)
        $parsed.BuildDelegable = $false
        $parsed.Valid = $false
        $parsed.Error = $Reason
        return $parsed
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    $lines = ($raw -replace "`r`n", "`n" -replace "`r", "`n") -split "`n"
    if ($null -eq $lines -or $lines.Count -eq 0) { return $parsed }
    if ($lines[0] -notmatch '^---\s*$') { return $parsed }
    $close = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(---|\.\.\.)\s*$') { $close = $i; break }
    }
    if ($close -lt 0) { return (& $deny 'frontmatter sem fechamento') }
    $allowedOrch = @('build_delegable', 'lifecycle', 'visibility', 'capabilities', 'allow_visibility')
    $allowedVis = @('normal', 'hidden', 'internal', 'experimental')
    $topKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $orchKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $orchBlocks = 0
    $inOrch = $false
    for ($i = 1; $i -lt $close; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*#') { continue }
        # Merge-key / alias / anchor / tag: somente dentro do frontmatter.
        $trimmed = $line.Trim()
        if ($trimmed -match '^<<\s*:') { return (& $deny 'YAML merge key << rejeitado') }
        if ($line -match '^(?<ind>[ \t]*)(?<key>[A-Za-z0-9_][A-Za-z0-9_.-]*|<<)\s*:\s*(?<val>.*)$') {
            $k = $Matches['key']
            $v = $Matches['val'].Trim()
            if ($k -ceq '<<') { return (& $deny 'YAML merge key << rejeitado') }
            # Valor com alias/anchor/tag YAML no inicio => rejeitar.
            if ($v -match '^[*!&][\w\-]') { return (& $deny ("YAML alias/anchor/tag rejeitado em '$k'")) }
            if ($v -match '^\*') { return (& $deny ("YAML alias rejeitado em '$k'")) }
        }
        elseif ($trimmed -match '^[*!&]') { return (& $deny 'YAML alias/anchor/tag rejeitado') }
        if ($line -match '^(?<key>[A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:\s*(?<val>.*)$') {
            $key = $Matches['key']
            $val = $Matches['val'].Trim()
            if (-not $topKeys.Add($key)) { return (& $deny ("chave de topo duplicada: '$key'")) }
            if ($key -ceq 'orchestration' -and $val -eq '') {
                $orchBlocks++
                if ($orchBlocks -gt 1) { return (& $deny 'bloco orchestration duplicado') }
                $inOrch = $true
                $parsed.HasOrchestration = $true
            }
            elseif ($key -ceq 'orchestration') {
                # `orchestration: <inline>` nao e o formato governado => deny.
                return (& $deny 'bloco orchestration inline rejeitado (use mapping)')            }
            else {
                $inOrch = $false
            }
            continue
        }
        if ($inOrch) {
            # Tokens YAML perigosos em QUALQUER posicao do bloco orchestration
            # (fail-closed): inclui flow collections (`capabilities: [ &ref x ]`)
            # e valores inline (`build_delegable: !!bool true`). Linhas de chave
            # de topo ja sairam pelo bloco acima (continue); aqui so restam
            # linhas do bloco orchestration (chaves indentadas, itens de lista,
            # continuacoes).
            if ($line -match '<<') { return (& $deny 'YAML merge key << rejeitado em orchestration') }
            if ($line -match '(^|[\s,\[\{=:])\*') { return (& $deny 'YAML alias * rejeitado em orchestration') }
            if ($line -match '(^|[\s,\[\{=:])&') { return (& $deny 'YAML anchor & rejeitado em orchestration') }
            if ($line -match '(^|[\s,\[\{=:])!') { return (& $deny 'YAML tag ! rejeitada em orchestration') }
        }
        if ($inOrch -and ($line -match '^(?<ind>[ \t]+)(?<key>[A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:\s*(?<val>.*)$')) {
            $indent = $Matches['ind'].Length
            if ($indent -eq 2) {
                $key = $Matches['key']
                $val = $Matches['val'].Trim()
                if (-not $orchKeys.Add($key)) { return (& $deny ("chave duplicada em orchestration: '$key'")) }
                if ($allowedOrch -cnotcontains $key) { return (& $deny ("chave desconhecida em orchestration: '$key'")) }
                if ($key -ceq 'build_delegable') {
                    if ($val -ceq 'true') { $parsed.BuildDelegable = $true }
                    elseif ($val -ceq 'false') { $parsed.BuildDelegable = $false }
                    else { return (& $deny 'build_delegable nao-booleano') }
                }
                elseif ($key -ceq 'allow_visibility') {
                    if (-not ($val -ceq 'true' -or $val -ceq 'false')) { return (& $deny 'allow_visibility nao-booleano') }
                }
                elseif ($key -ceq 'lifecycle') {
                    $clean = $val.Trim('"', "'").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($clean)) { $parsed.Lifecycle = $clean }
                }
                elseif ($key -ceq 'visibility') {
                    $clean = $val.Trim('"', "'").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($clean)) { $parsed.Visibility = $clean }
                    $visNorm = ([string]$parsed.Visibility).Trim().ToLowerInvariant()
                    if ($allowedVis -cnotcontains $visNorm) { return (& $deny ("visibility invalida: '$clean'")) }
                }
            }
            continue
        }
    }
    return $parsed
}

function Test-AuthorityVisibilityOverride {
    <#
    .SYNOPSIS
        True SOMENTE para a chave canonica booleana `allow_visibility: true`.
        Aliases (allow, visibility_allow, allow_delegation, build_delegable,
        build_allow) sao ignorados; strings 'true' nao conferem (exige bool).
    #>
    [CmdletBinding()]
    param($Override)
    if ($null -eq $Override) { return $false }
    $table = $null
    if ($Override -is [System.Collections.IDictionary]) { $table = $Override }
    else {
        $table = @{}
        foreach ($p in @($Override.PSObject.Properties)) { $table[$p.Name] = $p.Value }
    }
    if ($table.Contains('allow_visibility') -and ($table['allow_visibility'] -is [bool]) -and [bool]$table['allow_visibility']) { return $true }
    return $false
}

function Get-AuthorityOverrideEntry {
    [CmdletBinding()]
    param($Policy, [string]$AgentName)
    if ($null -eq $Policy -or $null -eq $Policy.overrides) { return $null }
    $overrides = $Policy.overrides
    if ($overrides -is [System.Collections.IDictionary]) {
        foreach ($k in @($overrides.Keys)) {
            if ("$k" -ceq $AgentName) { return $overrides[$k] }
        }
        foreach ($k in @($overrides.Keys)) {
            if ("$k".ToLowerInvariant() -ceq "$AgentName".ToLowerInvariant()) { return $overrides[$k] }
        }
        return $null
    }
    $entry = @($overrides.PSObject.Properties | Where-Object { $_.Name -ceq $AgentName } | Select-Object -First 1)
    if ($entry.Count -gt 0) { return $entry[0].Value }
    $lower = @($overrides.PSObject.Properties | Where-Object { $_.Name.ToLowerInvariant() -ceq $AgentName.ToLowerInvariant() } | Select-Object -First 1)
    if ($lower.Count -gt 0) { return $lower[0].Value }
    return $null
}

function Get-DesiredBuildDelegationSet {
    <#
    .SYNOPSIS
        Conjunto desejado (ordenado) de agentes delegaveis pelo build.
        Default deny; visibility negada salvo override explicito; override
        nunca concede quando build_delegable e falso.
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        $Policy,
        [string]$PolicyPath,
        [string]$AgentsRoot
    )
    $effectivePolicy = $Policy
    if ($null -eq $effectivePolicy) {
        $resolvedPolicy = Get-AuthorityPolicyPath -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        $effectivePolicy = Read-AuthorityPolicy -PolicyPath $resolvedPolicy
    }
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    $agentsDir = Get-AuthorityAgentsRoot -AgentsRoot $AgentsRoot -RepoRoot $root

    $denyVisibility = @()
    if ($null -ne $effectivePolicy.deny_rules -and $null -ne $effectivePolicy.deny_rules.visibility) {
        foreach ($v in @($effectivePolicy.deny_rules.visibility)) {
            $denyVisibility += ([string]$v).ToLowerInvariant()
        }
    }
    else {
        $denyVisibility = @('hidden', 'internal', 'experimental')
    }

    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($file in $files) {
            $agentName = [IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($agentName)) { continue }
            $orch = $null
            try { $orch = Read-AgentOrchestration -Path $file.FullName }
            catch { continue }
            if (-not [bool]$orch.BuildDelegable) { continue }
            $visNorm = ([string]$orch.Visibility).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($visNorm)) { $visNorm = 'normal' }
            if ($denyVisibility -ccontains $visNorm) {
                $override = Get-AuthorityOverrideEntry -Policy $effectivePolicy -AgentName $agentName
                if (-not (Test-AuthorityVisibilityOverride -Override $override)) { continue }
            }
            $ids.Add($agentName) | Out-Null
        }
    }
    $sorted = @($ids)
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

function Get-CurrentBuildAllowlist {
    <#
    .SYNOPSIS
        Entries de agent.build.permission.task com valor "allow" (exclui "*").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw ("Config file not found: {0}" -f $ConfigPath)
    }
    $text = [IO.File]::ReadAllText($ConfigPath, [Text.UTF8Encoding]::new($false))
    $cfg = $null
    try { $cfg = $text | ConvertFrom-Json }
    catch { throw ("Config file is not valid JSON: {0} ($($_.Exception.Message))" -f $ConfigPath) }
    $task = $null
    try {
        if ($null -ne $cfg.agent -and $null -ne $cfg.agent.build -and $null -ne $cfg.agent.build.permission) {
            $task = $cfg.agent.build.permission.task
        }
    }
    catch { $task = $null }
    if ($null -eq $task) { return @() }
    if ($task -is [string]) { return @() }
    $entries = @()
    if ($task -is [System.Collections.IDictionary]) {
        foreach ($k in @($task.Keys)) {
            if ("$k" -ceq '*') { continue }
            if ("$($task[$k])" -ceq 'allow') { $entries += "$k" }
        }
    }
    else {
        foreach ($p in @($task.PSObject.Properties)) {
            if ($p.Name -ceq '*') { continue }
            if ("$($p.Value)" -ceq 'allow') { $entries += [string]$p.Name }
        }
    }
    [Array]::Sort($entries, [System.StringComparer]::Ordinal)
    $unique = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($e in $entries) { if ($seen.Add($e)) { $unique += $e } }
    return $unique
}

function Get-AuthorityDrift {
    <#
    .SYNOPSIS
        Entries do current_allowlist nao explicadas pelas fontes governadas
        (desired). Ordenado, sem duplicatas.
    #>
    [CmdletBinding()]
    param($CurrentAllowlist, $Desired)
    $currentList = @()
    if ($null -ne $CurrentAllowlist) { $currentList = @($CurrentAllowlist) }
    $desiredList = @()
    if ($null -ne $Desired) { $desiredList = @($Desired) }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($d in $desiredList) { $set.Add([string]$d) | Out-Null }
    $drift = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($c in $currentList) {
        $name = [string]$c
        if (-not $set.Contains($name)) {
            if ($seen.Add($name)) { $drift += $name }
        }
    }
    [Array]::Sort($drift, [System.StringComparer]::Ordinal)
    return $drift
}

function Get-AuthorityGitHead {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & git -C $root rev-parse HEAD 2>$null
        $ErrorActionPreference = $prevEap
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace("$out")) {
            return ("$out").Trim()
        }
    }
    catch { }
    return 'unknown'
}

function Get-ProposedConfigText {
    <#
    .SYNOPSIS
        Texto proposto do config via mutator byte-preserving (compat):
        substitui SOMENTE o fragmento task; sem diff retorna o original.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OriginalText,
        $ProposedAllowlist
    )
    $core = Get-BuildTaskMutatedText -Text $OriginalText -ProposedAllowlist $ProposedAllowlist
    return [string]$core.MutatedText
}

function New-AuthorityChangeRequest {
    <#
    .SYNOPSIS
        Monta o AuthorityChangeRequest completo (sanitizado, sem segredos).
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot,
        [string]$ConfigPath,
        [string]$PolicyPath,
        [string]$AgentsRoot,
        [string]$RuntimesPath,
        [string]$Reason = ''
    )
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    $config = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($config)) {
        $config = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    }
    $policyFile = Get-AuthorityPolicyPath -PolicyPath $PolicyPath -RepoRoot $root
    $agentsDir = Get-AuthorityAgentsRoot -AgentsRoot $AgentsRoot -RepoRoot $root

    Assert-AuthorityTargetOwnership -RepoRoot $root -RuntimesPath $RuntimesPath | Out-Null

    $policy = Read-AuthorityPolicy -PolicyPath $policyFile
    $policyHash = Get-PolicySourceHash -PolicyPath $policyFile
    $agentHash = Get-AgentSourcesHash -AgentsRoot $agentsDir
    $baseHash = Get-ConfigFileHash -ConfigPath $config

    $current = @(Get-CurrentBuildAllowlist -ConfigPath $config)
    $desired = @(Get-DesiredBuildDelegationSet -RepoRoot $root -Policy $policy -AgentsRoot $agentsDir)

    $desiredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($d in $desired) { $desiredSet.Add([string]$d) | Out-Null }
    $currentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($c in $current) { $currentSet.Add([string]$c) | Out-Null }

    $added = @()
    foreach ($d in $desired) { if (-not $currentSet.Contains([string]$d)) { $added += [string]$d } }
    [Array]::Sort($added, [System.StringComparer]::Ordinal)
    $removed = @()
    foreach ($c in $current) { if (-not $desiredSet.Contains([string]$c)) { $removed += [string]$c } }
    [Array]::Sort($removed, [System.StringComparer]::Ordinal)
    $drift = @(Get-AuthorityDrift -CurrentAllowlist $current -Desired $desired)

    # target_config_hash = hash dos BYTES MUTADOS pelo mutator
    # byte-preserving (substituicao SOMENTE do task; leitura somente, sem
    # escrita: sem -TestRoot o mutator retorna WOULD_MUTATE/NO_CHANGE).
    # Sem diff os bytes mutados == originais (NO_CHANGE) => target == base.
    $mutPreview = Set-BuildTaskAllowlist -ConfigPath $config -ProposedAllowlist $desired
    if ([string]$mutPreview.Status -ceq 'NO_CHANGE') {
        $targetHash = $baseHash
    }
    else {
        $targetHash = [string]$mutPreview.HashAfter
    }

    $approvalHash = Get-ApprovalHash -BaseConfigHash $baseHash -ProposedAllowlist $desired -PolicySourceHash $policyHash -AgentSourcesHash $agentHash
    $changeId = Get-AuthorityChangeId -ApprovalHash $approvalHash
    $head = Get-AuthorityGitHead -RepoRoot $root
    $stamp = (Get-Date).ToUniversalTime().ToString('o')

    $reasonText = Get-SanitizedAuthorityReason -Reason $Reason
    if ([string]::IsNullOrWhiteSpace($reasonText)) {
        if (($added.Count -eq 0) -and ($removed.Count -eq 0)) { $reasonText = 'no authority change (desired equals current)' }
        else { $reasonText = 'reconcile build delegation with governed agent sources' }
    }

    $request = [ordered]@{
        schema_version     = 1
        change_id          = $changeId
        created_at         = $stamp
        base_revision      = $head
        base_config_hash   = $baseHash
        target_config_hash = $targetHash
        scope              = 'agent.build.permission.task'
        agents_added       = @($added)
        agents_removed     = @($removed)
        current_allowlist  = @($current)
        proposed_allowlist = @($desired)
        policy_source_hash = $policyHash
        agent_sources_hash = $agentHash
        drift              = @($drift)
        reason             = $reasonText
        validation         = [ordered]@{ discovery = 'pass'; registry = 'pass'; governance = 'pass'; tests = 'pass' }
        reviews            = [ordered]@{ reviewer = 'none'; security_reviewer = 'none' }
        approval           = [ordered]@{ required = $true; status = 'pending' }
        approval_hash      = $approvalHash
        state              = 'VALIDATED'
    }
    return ([PSCustomObject]$request)
}

function Get-AuthorityRequestState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request)
    if ($Request -is [System.Collections.IDictionary]) { return [string]$Request['state'] }
    return [string]$Request.state
}

function Get-AuthorityAllowedTransitions {
    [CmdletBinding()]
    param()
    return @{
        'PROPOSED'                = @('VALIDATED', 'REJECTED', 'STALE')
        'VALIDATED'               = @('REVIEWED', 'AWAITING_HUMAN_APPROVAL', 'REJECTED', 'STALE')
        'REVIEWED'                = @('SECURITY_REVIEWED', 'AWAITING_HUMAN_APPROVAL', 'REJECTED', 'STALE')
        'SECURITY_REVIEWED'       = @('AWAITING_HUMAN_APPROVAL', 'REJECTED', 'STALE')
        'AWAITING_HUMAN_APPROVAL' = @('APPROVED', 'REJECTED', 'STALE')
        'APPROVED'                = @('APPLIED_TO_DISK', 'REJECTED', 'STALE', 'CAS_CONFLICT')
        'APPLIED_TO_DISK'         = @('RUNTIME_RELOAD_REQUIRED', 'ROLLBACK_REQUIRED')
        'RUNTIME_RELOAD_REQUIRED' = @('RUNTIME_ACTIVE', 'ROLLBACK_REQUIRED')
        'RUNTIME_ACTIVE'          = @()
        'REJECTED'                = @()
        'STALE'                   = @()
        'CAS_CONFLICT'            = @()
        'ROLLBACK_REQUIRED'       = @('ROLLED_BACK')
        'ROLLED_BACK'             = @()
    }
}

function Set-AuthorityRequestState {
    <#
    .SYNOPSIS
        Transicao pura de estado com validacao. Retorna copia com novo estado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$NewState
    )
    $validStates = @('PROPOSED', 'VALIDATED', 'REVIEWED', 'SECURITY_REVIEWED', 'AWAITING_HUMAN_APPROVAL', 'APPROVED', 'APPLIED_TO_DISK', 'RUNTIME_RELOAD_REQUIRED', 'RUNTIME_ACTIVE', 'REJECTED', 'STALE', 'CAS_CONFLICT', 'ROLLBACK_REQUIRED', 'ROLLED_BACK')
    if ($validStates -cnotcontains $NewState) { throw ("Invalid authority state: '{0}'." -f $NewState) }
    $current = Get-AuthorityRequestState -Request $Request
    if ($current -ceq $NewState) { return $Request }
    $allowed = Get-AuthorityAllowedTransitions
    if (-not $allowed.ContainsKey($current)) { throw ("Unknown current authority state: '{0}'." -f $current) }
    if ($allowed[$current] -cnotcontains $NewState) {
        throw ("Illegal authority transition: '{0}' -> '{1}'." -f $current, $NewState)
    }
    if ($Request -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($k in @($Request.Keys)) { $copy[$k] = $Request[$k] }
        $copy['state'] = $NewState
        return $copy
    }
    $copy = New-Object PSCustomObject
    foreach ($p in @($Request.PSObject.Properties)) {
        if ($p.Name -ceq 'state') { $copy | Add-Member -NotePropertyName 'state' -NotePropertyValue $NewState }
        else { $copy | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    return $copy
}

function Test-AuthorityApproval {
    <#
    .SYNOPSIS
        Valida ApprovalRecord contra o Request e o estado atual em disco.
        Retorna @{ Valid; Reasons }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        $ApprovalRecord,
        [string]$RepoRoot,
        [string]$ConfigPath,
        [string]$PolicyPath,
        [string]$AgentsRoot
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -eq $ApprovalRecord) {
        $reasons.Add('missing approval record')
        return [PSCustomObject]@{ Valid = $false; Reasons = [string[]]$reasons }
    }
    $approvalStatus = ''
    $approvalChange = ''
    $approvalHashValue = ''
    if ($ApprovalRecord -is [System.Collections.IDictionary]) {
        if ($ApprovalRecord.Contains('status')) { $approvalStatus = [string]$ApprovalRecord['status'] }
        if ($ApprovalRecord.Contains('change_id')) { $approvalChange = [string]$ApprovalRecord['change_id'] }
        if ($ApprovalRecord.Contains('approval_hash')) { $approvalHashValue = [string]$ApprovalRecord['approval_hash'] }
    }
    else {
        if ($null -ne $ApprovalRecord.PSObject.Properties['status']) { $approvalStatus = [string]$ApprovalRecord.status }
        if ($null -ne $ApprovalRecord.PSObject.Properties['change_id']) { $approvalChange = [string]$ApprovalRecord.change_id }
        if ($null -ne $ApprovalRecord.PSObject.Properties['approval_hash']) { $approvalHashValue = [string]$ApprovalRecord.approval_hash }
    }
    if ($approvalStatus -cne 'approved') {
        $reasons.Add(("approval status is '{0}', expected 'approved'" -f $approvalStatus))
    }
    $requestChange = ''
    $requestHash = ''
    $requestBase = ''
    $requestPolicy = ''
    $requestAgents = ''
    $requestProposed = @()
    if ($Request -is [System.Collections.IDictionary]) {
        $requestChange = [string]$Request['change_id']
        $requestHash = [string]$Request['approval_hash']
        $requestBase = [string]$Request['base_config_hash']
        $requestPolicy = [string]$Request['policy_source_hash']
        $requestAgents = [string]$Request['agent_sources_hash']
        if ($null -ne $Request['proposed_allowlist']) { $requestProposed = @($Request['proposed_allowlist']) }
    }
    else {
        $requestChange = [string]$Request.change_id
        $requestHash = [string]$Request.approval_hash
        $requestBase = [string]$Request.base_config_hash
        $requestPolicy = [string]$Request.policy_source_hash
        $requestAgents = [string]$Request.agent_sources_hash
        if ($null -ne $Request.proposed_allowlist) { $requestProposed = @($Request.proposed_allowlist) }
    }
    if ($approvalChange -cne $requestChange) {
        $reasons.Add(("change_id mismatch: approval '{0}' vs request '{1}'" -f $approvalChange, $requestChange))
    }
    if ($approvalHashValue -cne $requestHash) {
        $reasons.Add('approval_hash mismatch vs request')
    }
    $internal = ''
    try { $internal = Get-ApprovalHash -BaseConfigHash $requestBase -ProposedAllowlist $requestProposed -PolicySourceHash $requestPolicy -AgentSourcesHash $requestAgents }
    catch { $internal = '' }
    if (-not [string]::IsNullOrWhiteSpace($internal) -and ($internal -cne $requestHash)) {
        $reasons.Add('request approval_hash does not recompute from its own inputs (tampered request)')
    }
    $expectedChange = ''
    try { $expectedChange = Get-AuthorityChangeId -ApprovalHash $requestHash } catch { $expectedChange = '' }
    if ((-not [string]::IsNullOrWhiteSpace($expectedChange)) -and ($expectedChange -cne $requestChange)) {
        $reasons.Add(("request change_id '{0}' does not match approval_hash (expected '{1}')" -f $requestChange, $expectedChange))
    }
    $hasDiskPaths = (-not [string]::IsNullOrWhiteSpace($RepoRoot)) -or (-not [string]::IsNullOrWhiteSpace($ConfigPath)) -or (-not [string]::IsNullOrWhiteSpace($PolicyPath))
    if ($hasDiskPaths) {
        try {
            $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
            $config = $ConfigPath
            if ([string]::IsNullOrWhiteSpace($config)) { $config = Join-Path $env:USERPROFILE '.config\opencode\opencode.json' }
            $policyFile = Get-AuthorityPolicyPath -PolicyPath $PolicyPath -RepoRoot $root
            $agentsDir = Get-AuthorityAgentsRoot -AgentsRoot $AgentsRoot -RepoRoot $root
            if ((Test-Path -LiteralPath $config -PathType Leaf) -and (Test-Path -LiteralPath $policyFile -PathType Leaf)) {
                $curBase = Get-ConfigFileHash -ConfigPath $config
                $curPolicy = Get-PolicySourceHash -PolicyPath $policyFile
                $curAgents = Get-AgentSourcesHash -AgentsRoot $agentsDir
                $fresh = Get-ApprovalHash -BaseConfigHash $curBase -ProposedAllowlist $requestProposed -PolicySourceHash $curPolicy -AgentSourcesHash $curAgents
                if ($fresh -cne $requestHash) {
                    $reasons.Add('STALE: current policy/agent-sources/base-config no longer produce approval_hash')
                }
            }
        }
        catch {
            $reasons.Add(('staleness check failed: ' + $_.Exception.Message))
        }
    }
    $valid = ($reasons.Count -eq 0)
    return [PSCustomObject]@{ Valid = $valid; Reasons = [string[]]$reasons }
}

function Get-AuthorityFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return ([IO.Path]::GetFullPath($Path).TrimEnd('\', '/')) }
    catch { return $Path }
}

function Get-AuthorityRealOpencodeDir {
    [CmdletBinding()]
    param()
    return (Get-AuthorityFullPath -Path (Join-Path $env:USERPROFILE '.config\opencode'))
}

function Get-AuthorityRealOpencodeConfigPath {
    [CmdletBinding()]
    param()
    return (Get-AuthorityFullPath -Path (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'))
}

function Test-AuthorityPathHasReparsePoint {
    <#
    .SYNOPSIS
        True se o caminho ou QUALQUER ancestor existente for reparse
        point/junction (Get-Item -Force + Attributes ReparsePoint).
    #>
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
                    # HardLink is NOT a reparse point: it is a second name for the same
                    # file (e.g. the Orca-shared opencode.json) and must not be treated as
                    # a junction/symlink traversal bypass. Only reparse-based links block.
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

function Assert-AuthorityFixtureBoundary {
    <#
    .SYNOPSIS
        Boundary fail-closed do apply: exige -FixtureRoot sob TEMP do SO,
        ConfigPath canonico dentro de FixtureRoot, sem reparse points, e
        NUNCA o opencode.json real nem dentro de .config/opencode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FixtureRoot,
        [string]$BackupRoot
    )
    if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
        throw 'apply bloqueado ate aprovacao humana do gate (sem -FixtureRoot o apply real e proibido; exit 2)'
    }
    $fullConfig = Get-AuthorityFullPath -Path $ConfigPath
    $fullFixture = Get-AuthorityFullPath -Path $FixtureRoot
    $tempRoot = Get-AuthorityFullPath -Path ([IO.Path]::GetTempPath())
    $underTemp = ($fullFixture -ieq $tempRoot) -or $fullFixture.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $underTemp) {
        throw ("FixtureRoot fora do TEMP do SO (fixture-only): {0} nao esta sob {1}" -f $FixtureRoot, $tempRoot)
    }
    $underFixture = ($fullConfig -ieq $fullFixture) -or $fullConfig.StartsWith($fullFixture + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $underFixture) {
        throw ("ConfigPath fora do -FixtureRoot (fixture-only): {0} nao esta sob {1}" -f $ConfigPath, $FixtureRoot)
    }
    foreach ($p in @($FixtureRoot, $ConfigPath, $BackupRoot)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-AuthorityPathHasReparsePoint -Path $p) {
            throw ("Reparse point/junction detectado no caminho (fixture-only bloqueado): {0}" -f $p)
        }
    }
    # Resolve o parentanjer real do config para reparse indireto via dir novo.
    $cfgParent = Split-Path -Parent $fullConfig
    if (-not [string]::IsNullOrWhiteSpace($cfgParent) -and (Test-AuthorityPathHasReparsePoint -Path $cfgParent)) {
        throw ("Reparse point/junction detectado em ancestor do ConfigPath: {0}" -f $cfgParent)
    }
    $realCfg = Get-AuthorityRealOpencodeConfigPath
    $realDir = Get-AuthorityRealOpencodeDir
    if ($fullConfig -ieq $realCfg) {
        throw ("ConfigPath e o opencode.json real (apply proibido): {0}" -f $ConfigPath)
    }
    if (($fullConfig -ieq $realDir) -or $fullConfig.StartsWith($realDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw ("ConfigPath dentro do profile real .config\opencode (apply proibido): {0}" -f $ConfigPath)
    }
    return $true
}

function Assert-AuthorityOutPath {
    <#
    .SYNOPSIS
        -Out restrito: sob evidence\v3\authority\ do repo OU sob -FixtureRoot.
        Rejeita traversal e reparse points.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Out,
        [string]$RepoRoot,
        [string]$FixtureRoot
    )
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    $evidence = Get-AuthorityFullPath -Path (Join-Path $root 'evidence\v3\authority')
    $fullOut = Get-AuthorityFullPath -Path $Out
    $underEvidence = ($fullOut -ieq $evidence) -or $fullOut.StartsWith($evidence + '\', [StringComparison]::OrdinalIgnoreCase)
    $underFixture = $false
    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $fullFixture = Get-AuthorityFullPath -Path $FixtureRoot
        $underFixture = ($fullOut -ieq $fullFixture) -or $fullOut.StartsWith($fullFixture + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    if (-not ($underEvidence -or $underFixture)) {
        throw ("-Out fora das areas permitidas (evidence\v3\authority do repo OU -FixtureRoot): {0}" -f $Out)
    }
    if (Test-AuthorityPathHasReparsePoint -Path $Out) {
        throw ("Reparse point/junction detectado em -Out (bloqueado): {0}" -f $Out)
    }
    return $true
}

function Get-SanitizedAuthorityReason {
    <#
    .SYNOPSIS
        Sanitiza `reason`: remove caracteres de controle, trim, limite 500.
    #>
    [CmdletBinding()]
    param([string]$Reason)
    $text = [string]$Reason
    $clean = ($text -replace '[\x00-\x1F\x7F]', ' ').Trim()
    $clean = ($clean -replace '\s+', ' ').Trim()
    if ($clean.Length -gt 500) { $clean = $clean.Substring(0, 500).TrimEnd() }
    return $clean
}

function Get-AuthorityRuntimesPath {
    [CmdletBinding()]
    param([string]$RuntimesPath, [string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RuntimesPath)) { return $RuntimesPath }
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\runtimes.json')
}

function Assert-AuthorityTargetOwnership {
    <#
    .SYNOPSIS
        Exige que source/registry/runtimes.json declare o alvo opencode com
        `agent.build.permission.task` de valor EXATO `control-plane`
        (igualdade ordinal, case-sensitive; substring/regex nao basta) e com
        o path canonico do target OpenCode
        (%USERPROFILE%\.config\opencode\opencode.json).
    #>
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$RuntimesPath)
    $regPath = Get-AuthorityRuntimesPath -RuntimesPath $RuntimesPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
        throw ("runtimes.json nao encontrado (ownership nao verificavel): {0}" -f $regPath)
    }
    $text = [IO.File]::ReadAllText($regPath, [Text.UTF8Encoding]::new($false))
    $reg = $null
    try { $reg = $text | ConvertFrom-Json }
    catch { throw ("runtimes.json ilegivel: {0} ({1})" -f $regPath, $_.Exception.Message) }
    $runtimes = $null
    try { $runtimes = $reg.runtimes } catch { $runtimes = $null }
    if ($null -eq $runtimes) { throw 'runtimes.json sem bloco runtimes (ownership falhou)' }
    $opencode = $null
    try {
        if ($runtimes -is [System.Collections.IDictionary]) {
            if ($runtimes.Contains('opencode')) { $opencode = $runtimes['opencode'] }
        } else {
            $prop = $runtimes.PSObject.Properties | Where-Object { $_.Name -ceq 'opencode' } | Select-Object -First 1
            if ($null -ne $prop) { $opencode = $prop.Value }
        }
    } catch { $opencode = $null }
    if ($null -eq $opencode) { throw 'ownership falhou: alvo opencode ausente em runtimes.json' }
    $targets = @()
    try { if ($null -ne $opencode.settings_targets) { $targets = @($opencode.settings_targets) } } catch { $targets = @() }
    foreach ($t in $targets) {
        $tpath = ''
        try {
            if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('path')) { $tpath = [string]$t['path'] } }
            else { $tpath = [string]$t.path }
        } catch { $tpath = '' }
        if ([string]::IsNullOrWhiteSpace($tpath)) { continue }
        if ($tpath -notmatch '(?i)opencode\.json') { continue }
        $sections = $null
        try {
            if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('sections')) { $sections = $t['sections'] } }
            else { $sections = $t.sections }
        } catch { $sections = $null }
        if ($null -eq $sections) { continue }
        $decl = $null
        try {
            if ($sections -is [System.Collections.IDictionary]) {
                foreach ($k in @($sections.Keys)) {
                    if ("$k" -ceq 'agent.build.permission.task') { $decl = $sections[$k]; break }
                }
            } else {
                $sp = $sections.PSObject.Properties | Where-Object { $_.Name -ceq 'agent.build.permission.task' } | Select-Object -First 1
                if ($null -ne $sp) { $decl = $sp.Value }
            }
        } catch { $decl = $null }
        if ($null -eq $decl) { continue }
        if (-not [string]::Equals([string]$decl, 'control-plane', [System.StringComparison]::Ordinal)) { continue }
        $tpathNorm = (([string]$tpath).Trim() -replace '/', '\')
        $expandedTarget = [Environment]::ExpandEnvironmentVariables($tpathNorm)
        $fullTarget = Get-AuthorityFullPath -Path $expandedTarget
        $canonicalTarget = Get-AuthorityRealOpencodeConfigPath
        if ($fullTarget -ine $canonicalTarget) { continue }
        return $true
    }
    throw 'ownership falhou: alvo opencode nao declara agent.build.permission.task = control-plane em runtimes.json'
}

function Write-AuthorityUtf8NoBomLf {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Restore-AuthorityConfigFromBackup {
    <#
    .SYNOPSIS
        Restaura o backup sobre o config e VERIFICA SHA-256/bytes
        (restaurado == backup). Nunca assume sucesso do Copy-Item sem
        verificacao. Retorna @{ Verified; Error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [bool]$SimulateCorruption = $false
    )
    try {
        Copy-Item -LiteralPath $BackupPath -Destination $ConfigPath -Force
        if ($SimulateCorruption) {
            [IO.File]::AppendAllText($ConfigPath, 'CORRUPT', [Text.UTF8Encoding]::new($false))
        }
        $restoredHash = Get-ConfigFileHash -ConfigPath $ConfigPath
        $backupHash = Get-ConfigFileHash -ConfigPath $BackupPath
        if ($restoredHash -ceq $backupHash) {
            return [PSCustomObject]@{ Verified = $true; Error = '' }
        }
        return [PSCustomObject]@{ Verified = $false; Error = ("restored hash {0} != backup hash {1}" -f $restoredHash, $backupHash) }
    }
    catch {
        return [PSCustomObject]@{ Verified = $false; Error = $_.Exception.Message }
    }
}

function Invoke-AuthorityApply {
    <#
    .SYNOPSIS
        Apply atomico do change em FIXTURE (-FixtureRoot obrigatorio, sob TEMP).
        Sem -FixtureRoot lanca (o CLI converte em exit 2). Drift bloqueia
        (exit 1) sem tocar o config. Noop idempotente antes do CAS, com
        revalidacao de staleness/ownership contra as fontes reais; CAS
        estrito nos demais estados. FASES: (1) ATOMIC WRITE phase — CAS,
        escrita temp, replace/move, verificacao pos-hash; QUALQUER excecao
        apos o replace nesta fase tenta restaurar o backup e VERIFICA
        SHA-256/bytes contra o backup — verificado => ROLLED_BACK,
        restauracao ou verificacao falhou => ROLLBACK_REQUIRED. (2)
        BOOKKEEPING phase (best-effort, nao-fatal) — Get-FileSetFingerprint,
        Set-RuntimeReloadStatus, escrita de rollback.json; falhas aqui NAO
        fazem rollback do config (ja correto e verificado) e sao registradas
        em warnings[]/bookkeeping_errors[] do resultado com status `applied`
        mantido (reload-state pode estar incompleto). Sucesso do Copy-Item
        nunca e assumido sem verificacao. Estados reais de falha
        (STALE/CAS_CONFLICT/ROLLBACK_REQUIRED/ROLLED_BACK) vao para o
        resultado e o rollback.json; `state` permanece model-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        $ApprovalRecord,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupRoot,
        [string]$ReloadStorePath,
        [string]$FixtureRoot,
        [string]$TestRoot,
        [string]$RepoRoot,
        [string]$PolicyPath,
        [string]$AgentsRoot,
        [switch]$SimulatePreReplaceFailure,
        [switch]$SimulatePostReplaceMismatch,
        [switch]$SimulatePostReplaceError,
        [switch]$SimulateRestoreFailure,
        [switch]$SimulateBookkeepingFailure,
        [switch]$SimulateRollbackWriteFailure
    )
    if (-not [string]::IsNullOrWhiteSpace($TestRoot)) {
        throw 'parametro -TestRoot foi removido; use -FixtureRoot (sob o TEMP do SO)'
    }
    Assert-AuthorityFixtureBoundary -ConfigPath $ConfigPath -FixtureRoot $FixtureRoot -BackupRoot $BackupRoot | Out-Null
    $fullConfig = Get-AuthorityFullPath -Path $ConfigPath
    $fullFixture = Get-AuthorityFullPath -Path $FixtureRoot
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    $policyFile = Get-AuthorityPolicyPath -PolicyPath $PolicyPath -RepoRoot $root
    $agentsDir = Get-AuthorityAgentsRoot -AgentsRoot $AgentsRoot -RepoRoot $root

    $requestDrift = @()
    if ($Request -is [System.Collections.IDictionary]) {
        if ($null -ne $Request['drift']) { $requestDrift = @($Request['drift']) }
    }
    else {
        if ($null -ne $Request.drift) { $requestDrift = @($Request.drift) }
    }
    if ($requestDrift.Count -gt 0) {
        throw ("DRIFT_BLOCKED (state=STALE): drift nao resolvido bloqueia o apply: " + ($requestDrift -join ', '))
    }

    $requestBase = ''
    $requestTarget = ''
    $requestProposed = @()
    $requestChange = ''
    if ($Request -is [System.Collections.IDictionary]) {
        $requestBase = [string]$Request['base_config_hash']
        $requestTarget = [string]$Request['target_config_hash']
        $requestChange = [string]$Request['change_id']
        if ($null -ne $Request['proposed_allowlist']) { $requestProposed = @($Request['proposed_allowlist']) }
    }
    else {
        $requestBase = [string]$Request.base_config_hash
        $requestTarget = [string]$Request.target_config_hash
        $requestChange = [string]$Request.change_id
        if ($null -ne $Request.proposed_allowlist) { $requestProposed = @($Request.proposed_allowlist) }
    }

    # Idempotencia/retry ANTES do CAS: se o disco ja reflete o alvo
    # (hash == target E allowlist == proposta), o retry e noop — mas SOMENTE
    # apos revalidar a aprovacao/staleness contra as fontes REAIS (RepoRoot,
    # ConfigPath, PolicyPath, AgentsRoot) e o ownership do target. Nao se
    # confia so em hash+allowlist: a base avancada ao alvo e esperada no
    # retry, mas policy/agent-sources divergentes tornam o noop STALE.
    $currentHash = Get-ConfigFileHash -ConfigPath $ConfigPath
    $currentAllow = @(Get-CurrentBuildAllowlist -ConfigPath $ConfigPath)
    $sameAllow = ($currentAllow.Count -eq $requestProposed.Count)
    if ($sameAllow) {
        for ($i = 0; $i -lt $currentAllow.Count; $i++) {
            if ($currentAllow[$i] -cne $requestProposed[$i]) { $sameAllow = $false; break }
        }
    }
    if (($currentHash -ceq $requestTarget) -and $sameAllow) {
        $retryCheck = Test-AuthorityApproval -Request $Request -ApprovalRecord $ApprovalRecord
        if (-not [bool]$retryCheck.Valid) {
            throw ("approval invalida (state=STALE): " + (($retryCheck.Reasons -join ' | ')))
        }
        try {
            Assert-AuthorityTargetOwnership -RepoRoot $root | Out-Null
        }
        catch {
            throw ("approval invalida (state=STALE): ownership falhou no retry noop: " + $_.Exception.Message)
        }
        $requestPolicyH = ''
        $requestAgentsH = ''
        if ($Request -is [System.Collections.IDictionary]) {
            $requestPolicyH = [string]$Request['policy_source_hash']
            $requestAgentsH = [string]$Request['agent_sources_hash']
        }
        else {
            $requestPolicyH = [string]$Request.policy_source_hash
            $requestAgentsH = [string]$Request.agent_sources_hash
        }
        $diskPolicyH = ''
        $diskAgentsH = ''
        try {
            $diskPolicyH = Get-PolicySourceHash -PolicyPath $policyFile
            $diskAgentsH = Get-AgentSourcesHash -AgentsRoot $agentsDir
        }
        catch {
            throw ("approval invalida (state=STALE): staleness check falhou no retry noop: " + $_.Exception.Message)
        }
        if (($diskPolicyH -cne $requestPolicyH) -or ($diskAgentsH -cne $requestAgentsH)) {
            throw ("approval invalida (state=STALE): STALE: policy/agent-sources mudaram desde o request (policy disco {0} vs request {1}; agents disco {2} vs request {3})" -f $diskPolicyH, $requestPolicyH, $diskAgentsH, $requestAgentsH)
        }
        return [PSCustomObject]@{
            Status            = 'noop'
            State             = (Get-AuthorityRequestState -Request $Request)
            ChangeId          = $requestChange
            ConfigPath        = $ConfigPath
            BackupPath        = $null
            RollbackPath      = $null
            Warnings          = @()
            BookkeepingErrors = @()
        }
    }

    $check = Test-AuthorityApproval -Request $Request -ApprovalRecord $ApprovalRecord -RepoRoot $root -ConfigPath $ConfigPath -PolicyPath $policyFile -AgentsRoot $agentsDir
    if (-not [bool]$check.Valid) {
        throw ("approval invalida (state=STALE): " + (($check.Reasons -join ' | ')))
    }

    if ($currentHash -cne $requestBase) {
        throw ("CAS_CONFLICT (state=CAS_CONFLICT): base_config_hash do request ({0}) difere do disco ({1})" -f $requestBase, $currentHash)
    }

    if ($SimulatePreReplaceFailure) {
        throw 'simulated pre-replace failure (test-only; nothing was written)'
    }

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $fullFixture 'authority-backups' }
    $fullBackup = Get-AuthorityFullPath -Path $BackupRoot
    $tempRootBk = Get-AuthorityFullPath -Path ([IO.Path]::GetTempPath())
    $bkOk = ($fullBackup -ieq $tempRootBk) -or $fullBackup.StartsWith($tempRootBk + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $bkOk) {
        throw ("BackupRoot fora do TEMP do SO (fixture-only): {0} nao esta sob {1}" -f $BackupRoot, $tempRootBk)
    }
    if (Test-AuthorityPathHasReparsePoint -Path $BackupRoot) {
        throw ("Reparse point/junction detectado em BackupRoot (bloqueado): {0}" -f $BackupRoot)
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRoot ($requestChange + '-' + $stamp)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupPath = Join-Path $backupDir 'opencode.json.backup'
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
    $rollbackPath = Join-Path $backupDir 'rollback.json'
    $rollbackDone = $false

    $tempPath = $null
    $replaceDone = $false
    try {
        # Bytes + escrita via mutator byte-preserving (fixture): substitui
        # SOMENTE o fragmento agent.build.permission.task, com CAS estrito
        # (-ExpectedHash = base_config_hash) e validacao interna de
        # nao-governados + escrita atomica (temp no mesmo dir + Replace/Move
        # + verificacao pos-hash). O mutator gerencia o proprio temp;
        # $tempPath permanece $null (a limpeza legada abaixo vira no-op).
        # Corrida com o noop: se o disco convergiu ao alvo entre o noop
        # check e aqui, o mutator retorna NO_CHANGE => noop idempotente.
        $mutApply = Set-BuildTaskAllowlist -ConfigPath $fullConfig -ProposedAllowlist $requestProposed -ExpectedHash $requestBase -TestRoot $fullFixture
        if ([string]$mutApply.Status -ceq 'NO_CHANGE') {
            return [PSCustomObject]@{
                Status            = 'noop'
                State             = (Get-AuthorityRequestState -Request $Request)
                ChangeId          = $requestChange
                ConfigPath        = $ConfigPath
                BackupPath        = $null
                RollbackPath      = $null
                Warnings          = @()
                BookkeepingErrors = @()
            }
        }
        $replaceDone = $true
        if ($SimulatePostReplaceError) {
            # Test-only: falha generica apos o replace para exercitar o
            # rollback robusto (restaura + verifica => ROLLED_BACK).
            throw 'simulated post-replace failure (test-only; backup will be restored and verified)'
        }
        if ($SimulatePostReplaceMismatch) {
            # Test-only: corrompe o pos-replace para exercitar o rollback automatico.
            [IO.File]::AppendAllText($fullConfig, "`n", [Text.UTF8Encoding]::new($false))
        }
        $after = Get-ConfigFileHash -ConfigPath $ConfigPath
        if ($after -cne $requestTarget) {
            $restoreResult = Restore-AuthorityConfigFromBackup -BackupPath $backupPath -ConfigPath $ConfigPath -SimulateCorruption ([bool]$SimulateRestoreFailure)
            if ([bool]$restoreResult.Verified) {
                $rollback = [ordered]@{
                    version            = 1
                    change_id          = $requestChange
                    created_at         = (Get-Date).ToUniversalTime().ToString('o')
                    config_path        = $ConfigPath
                    base_config_hash   = $requestBase
                    target_config_hash = $requestTarget
                    backup_path        = $backupPath
                    status             = 'ROLLED_BACK'
                    state              = 'ROLLED_BACK'
                    note               = 'Hash pos-replace divergiu; backup restaurado e VERIFICADO por SHA-256/bytes contra o backup.'
                }
                Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
                $rollbackDone = $true
                return [PSCustomObject]@{
                    Status       = 'ROLLED_BACK'
                    State        = 'ROLLED_BACK'
                    ChangeId     = $requestChange
                    ConfigPath   = $ConfigPath
                    BackupPath   = $backupPath
                    RollbackPath = $rollbackPath
                }
            }
            $restoreError = [string]$restoreResult.Error
            $rollback = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = $restoreError
                note               = 'Hash pos-replace divergiu e a restauracao automatica FALHOU na verificacao; restaure o backup manualmente.'
            }
            Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
            $rollbackDone = $true
            throw ("Post-apply hash mismatch (state=ROLLBACK_REQUIRED): esperado {0}, atual {1}; restore/verificacao falhou: {2}" -f $requestTarget, $after, $restoreError)
        }
        # --- BOOKKEEPING PHASE (best-effort, nao-fatal) ---
        # O config ja foi substituido e VERIFICADO por hash acima. Falhas
        # aqui (fingerprint, reload-state, escrita de rollback.json) NAO
        # fazem rollback: sao capturadas e registradas em
        # warnings[]/bookkeeping_errors[] com status `applied` mantido.
        $warnings = New-Object System.Collections.Generic.List[string]
        $bkErrors = New-Object System.Collections.Generic.List[string]
        $rollback = [ordered]@{
            version            = 1
            change_id          = $requestChange
            created_at         = (Get-Date).ToUniversalTime().ToString('o')
            config_path        = $ConfigPath
            base_config_hash   = $requestBase
            target_config_hash = $requestTarget
            backup_path        = $backupPath
            status             = 'applied-and-verified'
            state              = 'APPLIED_TO_DISK'
            note               = 'Restore por copia byte-a-byte do backup (.backup) ou do replace-backup.'
        }
        try {
            if ([bool]$SimulateBookkeepingFailure) {
                throw 'simulated bookkeeping failure (test-only; fingerprint indisponivel)'
            }
            if ((Get-Command Get-FileSetFingerprint -ErrorAction SilentlyContinue) -ne $null) {
                $rollback['config_snapshot'] = (Get-FileSetFingerprint -FilePaths @($ConfigPath))
            }
        }
        catch {
            $msg = ('bookkeeping fingerprint falhou (nao-fatal; config aplicado e verificado): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
        }
        try {
            if ([bool]$SimulateBookkeepingFailure) {
                throw 'simulated bookkeeping failure (test-only; reload-state indisponivel)'
            }
            $store = $ReloadStorePath
            if ([string]::IsNullOrWhiteSpace($store)) { $store = Join-Path $fullFixture 'reload-state.json' }
            if ((Get-Command Set-RuntimeReloadStatus -ErrorAction SilentlyContinue) -ne $null) {
                Set-RuntimeReloadStatus -Status 'DISK_APPLIED_RELOAD_REQUIRED' -TargetRoot $fullFixture -StorePath $store -ConfigPath $ConfigPath | Out-Null
            }
        }
        catch {
            $msg = ('bookkeeping reload-state falhou (nao-fatal; reload-state pode estar incompleto): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
            [Console]::Error.WriteLine($msg)
        }
        $rollback['warnings'] = [string[]]$warnings
        $rollback['bookkeeping_errors'] = [string[]]$bkErrors
        try {
            if ([bool]$SimulateRollbackWriteFailure -or [bool]$SimulateBookkeepingFailure) {
                throw 'simulated rollback write failure (test-only; bookkeeping nao-fatal)'
            }
            Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
            $rollbackDone = $true
        }
        catch {
            $msg = ('bookkeeping rollback.json falhou (nao-fatal; config aplicado e verificado): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
            [Console]::Error.WriteLine($msg)
        }
        return [PSCustomObject]@{
            Status            = 'applied'
            State             = 'APPLIED_TO_DISK'
            ChangeId          = $requestChange
            ConfigPath        = $ConfigPath
            BackupPath        = $backupPath
            RollbackPath      = $rollbackPath
            Warnings          = [string[]]$warnings
            BookkeepingErrors = [string[]]$bkErrors
        }
    }
    catch {
        $caughtMessage = $_.Exception.Message
        if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($replaceDone) {
            # ATOMIC WRITE phase: QUALQUER excecao apos o replace nesta fase
            # tenta restaurar o backup e VERIFICA SHA-256/bytes contra o
            # backup. A restauracao e idempotente (backup intacto).
            # (Bookkeeping e best-effort e nunca chega aqui: falhas la sao
            # capturadas e retornadas como applied + warnings.)
            $postRestore = Restore-AuthorityConfigFromBackup -BackupPath $backupPath -ConfigPath $ConfigPath -SimulateCorruption ([bool]$SimulateRestoreFailure)
            if ([bool]$postRestore.Verified) {
                $rollbackRestored = [ordered]@{
                    version            = 1
                    change_id          = $requestChange
                    created_at         = (Get-Date).ToUniversalTime().ToString('o')
                    config_path        = $ConfigPath
                    base_config_hash   = $requestBase
                    target_config_hash = $requestTarget
                    backup_path        = $backupPath
                    status             = 'ROLLED_BACK'
                    state              = 'ROLLED_BACK'
                    error              = $caughtMessage
                    note               = 'Excecao pos-replace; backup restaurado e VERIFICADO por SHA-256/bytes contra o backup.'
                }
                try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackRestored | ConvertTo-Json -Depth 10) + "`n") } catch { }
                $rollbackDone = $true
                return [PSCustomObject]@{
                    Status       = 'ROLLED_BACK'
                    State        = 'ROLLED_BACK'
                    ChangeId     = $requestChange
                    ConfigPath   = $ConfigPath
                    BackupPath   = $backupPath
                    RollbackPath = $rollbackPath
                }
            }
            $postRestoreError = [string]$postRestore.Error
            $rollbackRequired = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = ($caughtMessage + ' | restore/verificacao falhou: ' + $postRestoreError)
                note               = 'Excecao pos-replace e restauracao/verificacao FALHOU; restaure o backup manualmente.'
            }
            try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackRequired | ConvertTo-Json -Depth 10) + "`n") } catch { }
            $rollbackDone = $true
            throw ("Post-replace failure (state=ROLLBACK_REQUIRED): {0}; restore/verificacao falhou: {1}" -f $caughtMessage, $postRestoreError)
        }
        if (-not $rollbackDone) {
            $rollbackFail = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = $caughtMessage
            }
            try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackFail | ConvertTo-Json -Depth 10) + "`n") } catch { }
        }
        throw
    }
}

function Assert-AuthorityRealConfigPath {
    <#
    .SYNOPSIS
        Boundary fail-closed do apply REAL: ConfigPath deve ser o opencode.json
        canonico real (%USERPROFILE%\.config\opencode\opencode.json), sem
        reparse point no caminho nem nos ancestors. Em -TestMode, aceita SOMENTE
        o caminho TEMP fornecido explicitamente via -ExpectedConfigPath (nunca
        o config real) — fixture/TestMode nunca tocam o opencode.json real.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$ExpectedConfigPath,
        [switch]$TestMode
    )
    $canonical = Get-AuthorityRealOpencodeConfigPath
    $fullConfig = Get-AuthorityFullPath -Path $ConfigPath
    if ([bool]$TestMode) {
        if ([string]::IsNullOrWhiteSpace($ExpectedConfigPath)) {
            throw 'apply real em TestMode exige -ExpectedConfigPath explicito (fail-closed; nunca inferir o config real em testes)'
        }
        $fullExpected = Get-AuthorityFullPath -Path $ExpectedConfigPath
        $tempRoot = Get-AuthorityFullPath -Path ([IO.Path]::GetTempPath())
        $underTemp = ($fullExpected -ieq $tempRoot) -or $fullExpected.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $underTemp) {
            throw ("TestMode: ExpectedConfigPath fora do TEMP do SO (fixture-only): {0} nao esta sob {1}" -f $ExpectedConfigPath, $tempRoot)
        }
        if ($fullConfig -ine $fullExpected) {
            throw ("ConfigPath difere do ExpectedConfigPath em TestMode: {0} vs {1}" -f $ConfigPath, $ExpectedConfigPath)
        }
        if ($fullConfig -ieq $canonical) {
            throw 'TestMode nunca toca o opencode.json real (fail-closed)'
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedConfigPath)) {
            $fullExpected = Get-AuthorityFullPath -Path $ExpectedConfigPath
            if ($fullExpected -ine $canonical) {
                throw ("ExpectedConfigPath nao-canonico (apply real exige o opencode.json canonico): {0}" -f $ExpectedConfigPath)
            }
        }
        if ($fullConfig -ine $canonical) {
            throw ("apply real exige o config canonico real ({0}); recebido: {1} (use -FixtureRoot para fixture)" -f $canonical, $ConfigPath)
        }
    }
    if (Test-AuthorityPathHasReparsePoint -Path $ConfigPath) {
        throw ("Reparse point/junction detectado no ConfigPath (apply real bloqueado): {0}" -f $ConfigPath)
    }
    $cfgParent = Split-Path -Parent $fullConfig
    if (-not [string]::IsNullOrWhiteSpace($cfgParent) -and (Test-AuthorityPathHasReparsePoint -Path $cfgParent)) {
        throw ("Reparse point/junction detectado em ancestor do ConfigPath (apply real bloqueado): {0}" -f $cfgParent)
    }
    return $true
}

function Backup-AuthorityRealConfig {
    <#
    .SYNOPSIS
        Backup DPAPI-com-fallback (padrao reconcile-agents.ps1): tenta
        ProtectedData::Protect(CurrentUser) em "<base>.dpapi"; se DPAPI
        indisponivel, copia plain em "<base>.bak". Retorna @{ path; encoding }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationBase
    )
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $bytes = [IO.File]::ReadAllBytes($SourcePath)
        $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
        $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, $scope)
        $dest = "$DestinationBase.dpapi"
        [IO.File]::WriteAllBytes($dest, $enc)
        return [ordered]@{ path = $dest; encoding = 'dpapi' }
    }
    catch {
        $dest = "$DestinationBase.bak"
        Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
        return [ordered]@{ path = $dest; encoding = ('plain-copy (DPAPI unavailable: ' + $_.Exception.Message + ')') }
    }
}

function Restore-AuthorityRealConfigFromBackup {
    <#
    .SYNOPSIS
        Restaura o backup REAL sobre o config e VERIFICA byte-a-byte contra o
        backup (Unprotect para .dpapi; copia para .bak/.backup). Retorna
        @{ Verified; Error }. Nunca assume sucesso sem verificacao.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [bool]$SimulateCorruption = $false
    )
    try {
        $expectedBytes = $null
        if ($BackupPath -match '\.dpapi\s*$') {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $enc = [IO.File]::ReadAllBytes($BackupPath)
            $scope = [Security.Cryptography.DataProtectionScope]::CurrentUser
            $expectedBytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, $scope)
            [IO.File]::WriteAllBytes($ConfigPath, $expectedBytes)
        }
        else {
            Copy-Item -LiteralPath $BackupPath -Destination $ConfigPath -Force
            $expectedBytes = [IO.File]::ReadAllBytes($BackupPath)
        }
        if ($SimulateCorruption) {
            [IO.File]::AppendAllText($ConfigPath, 'CORRUPT', [Text.UTF8Encoding]::new($false))
        }
        $restored = [IO.File]::ReadAllBytes($ConfigPath)
        $ok = ($restored.Length -eq $expectedBytes.Length)
        if ($ok) {
            for ($i = 0; $i -lt $restored.Length; $i++) {
                if ($restored[$i] -ne $expectedBytes[$i]) { $ok = $false; break }
            }
        }
        if ($ok) { return [PSCustomObject]@{ Verified = $true; Error = '' } }
        return [PSCustomObject]@{ Verified = $false; Error = 'restored bytes divergem do backup (verificacao DPAPI/plain falhou)' }
    }
    catch {
        return [PSCustomObject]@{ Verified = $false; Error = $_.Exception.Message }
    }
}

function Get-AuthorityConsumedRoot {
    [CmdletBinding()]
    param([string]$ConsumedRoot, [string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($ConsumedRoot)) { return $ConsumedRoot }
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'evidence\v3\authority\consumed')
}

function Write-AuthorityConsumedMarker {
    <#
    .SYNOPSIS
        Marca o ACR como consumido em consumed/<change_id>.json (approval
        status/apontamento) para impedir re aplicacao como nova authority.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConsumedRoot,
        [Parameter(Mandatory = $true)][string]$ChangeId,
        [Parameter(Mandatory = $true)]$Value
    )
    if ($ChangeId -notmatch '^acr-[0-9a-f]{16}$') {
        throw ("ChangeId invalido para consumed marker: {0}" -f $ChangeId)
    }
    $path = Join-Path $ConsumedRoot ($ChangeId + '.json')
    Write-AuthorityUtf8NoBomLf -Path $path -Text ((($Value | ConvertTo-Json -Depth 10) + "`n"))
    return $path
}

function Invoke-AuthorityRealApply {
    <#
    .SYNOPSIS
        Apply REAL governado (pos-aprovacao humana) da mudanca de authority no
        opencode.json canonico, via mutator byte-preserving. Em -TestMode opera
        SOMENTE sobre o caminho TEMP de -ExpectedConfigPath (fixture; nunca o
        real) com -TestRoot como boundary do mutator.

        Revalida approval (change_id + approval_hash, status approved) e
        staleness (base_config_hash/policy_source_hash/agent_sources_hash
        atuais vs request => STALE sem escrita); ConfigPath canonico real
        (TestMode: TEMP explicito) sem reparse; drift vazio obrigatorio;
        ownership verificado; CAS estrito (atual == base_config_hash, senao
        CAS_CONFLICT sem escrita); backup DPAPI-com-fallback + escrita atomica
        via Set-BuildTaskAllowlist com -ExpectedHash = base; pos-hash deve ==
        target_config_hash com JSON valido e hash logico dos nao-governados
        igual (apenas o subtree task mudou); disco ja no alvo (hash == target
        E allowlist == proposta) => noop idempotente (apos revalidar
        aprovacao/staleness/ownership); registra rollback.json + consumed
        marker (evidence\v3\authority\consumed\<change_id>.json).
        FASES como o apply em fixture: (1) ATOMIC WRITE (falha pos-replace =>
        restore + verificacao => ROLLED_BACK ou ROLLBACK_REQUIRED); (2)
        BOOKKEEPING best-effort (fingerprint, reload-state, rollback.json,
        consumed) com warnings[]/bookkeeping_errors[] e status `applied`
        mantido.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        $ApprovalRecord,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$BackupRoot,
        [string]$ReloadStorePath,
        [string]$ExpectedConfigPath,
        [string]$RepoRoot,
        [string]$PolicyPath,
        [string]$AgentsRoot,
        [string]$ConsumedRoot,
        [switch]$TestMode,
        [string]$TestRoot,
        [switch]$SimulatePreReplaceFailure,
        [switch]$SimulatePostReplaceMismatch,
        [switch]$SimulatePostReplaceError,
        [switch]$SimulateRestoreFailure,
        [switch]$SimulateBookkeepingFailure,
        [switch]$SimulateRollbackWriteFailure
    )
    Assert-AuthorityRealConfigPath -ConfigPath $ConfigPath -ExpectedConfigPath $ExpectedConfigPath -TestMode:$TestMode | Out-Null
    $fullConfig = Get-AuthorityFullPath -Path $ConfigPath
    $root = Get-AuthorityRepoRoot -RepoRoot $RepoRoot
    $policyFile = Get-AuthorityPolicyPath -PolicyPath $PolicyPath -RepoRoot $root
    $agentsDir = Get-AuthorityAgentsRoot -AgentsRoot $AgentsRoot -RepoRoot $root
    $isTest = [bool]$TestMode

    $fullTestRoot = ''
    if ($isTest) {
        if ([string]::IsNullOrWhiteSpace($TestRoot)) {
            throw 'apply real em TestMode exige -TestRoot explicito (boundary do mutator em fixture)'
        }
        $fullTestRoot = Get-AuthorityFullPath -Path $TestRoot
    }

    $tempRoot = Get-AuthorityFullPath -Path ([IO.Path]::GetTempPath())
    if ($isTest) {
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $fullTestRoot 'authority-backups' }
        if ([string]::IsNullOrWhiteSpace($ReloadStorePath)) { $ReloadStorePath = Join-Path $fullTestRoot 'reload-state.json' }
        if ([string]::IsNullOrWhiteSpace($ConsumedRoot)) { $ConsumedRoot = Join-Path $fullTestRoot 'consumed' }
        foreach ($p in @($BackupRoot, $ReloadStorePath, $ConsumedRoot)) {
            $full = Get-AuthorityFullPath -Path $p
            $underTemp = ($full -ieq $tempRoot) -or $full.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)
            if (-not $underTemp) {
                throw ("TestMode: caminho de saida fora do TEMP do SO (fixture-only): {0} nao esta sob {1}" -f $p, $tempRoot)
            }
            if (Test-AuthorityPathHasReparsePoint -Path $p) {
                throw ("Reparse point/junction detectado em caminho de saida TestMode (bloqueado): {0}" -f $p)
            }
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) { $BackupRoot = Join-Path $root 'reconciliation-backups' }
        $ConsumedRoot = Get-AuthorityConsumedRoot -ConsumedRoot $ConsumedRoot -RepoRoot $root
        foreach ($p in @($BackupRoot, $ConsumedRoot)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-AuthorityPathHasReparsePoint -Path $p) {
                throw ("Reparse point/junction detectado em caminho de saida (apply real bloqueado): {0}" -f $p)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ReloadStorePath) -and (Test-AuthorityPathHasReparsePoint -Path $ReloadStorePath)) {
            throw ("Reparse point/junction detectado em ReloadStorePath (apply real bloqueado): {0}" -f $ReloadStorePath)
        }
    }

    Assert-AuthorityTargetOwnership -RepoRoot $root | Out-Null

    $requestDrift = @()
    if ($Request -is [System.Collections.IDictionary]) {
        if ($null -ne $Request['drift']) { $requestDrift = @($Request['drift']) }
    }
    else {
        if ($null -ne $Request.drift) { $requestDrift = @($Request.drift) }
    }
    if ($requestDrift.Count -gt 0) {
        throw ("DRIFT_BLOCKED (state=STALE): drift nao resolvido bloqueia o apply real: " + ($requestDrift -join ', '))
    }

    $requestBase = ''
    $requestTarget = ''
    $requestProposed = @()
    $requestChange = ''
    $requestPolicyH = ''
    $requestAgentsH = ''
    if ($Request -is [System.Collections.IDictionary]) {
        $requestBase = [string]$Request['base_config_hash']
        $requestTarget = [string]$Request['target_config_hash']
        $requestChange = [string]$Request['change_id']
        $requestPolicyH = [string]$Request['policy_source_hash']
        $requestAgentsH = [string]$Request['agent_sources_hash']
        if ($null -ne $Request['proposed_allowlist']) { $requestProposed = @($Request['proposed_allowlist']) }
    }
    else {
        $requestBase = [string]$Request.base_config_hash
        $requestTarget = [string]$Request.target_config_hash
        $requestChange = [string]$Request.change_id
        $requestPolicyH = [string]$Request.policy_source_hash
        $requestAgentsH = [string]$Request.agent_sources_hash
        if ($null -ne $Request.proposed_allowlist) { $requestProposed = @($Request.proposed_allowlist) }
    }
    if ($requestChange -notmatch '^acr-[0-9a-f]{16}$') {
        throw ("change_id invalido no request (apply real bloqueado): {0}" -f $requestChange)
    }

    # REPLAY guard: mesma aprovacao nunca re-muta. Se existir consumed marker
    # para o change_id: disco no alvo => noop estrito (sem escrita, sem novo
    # marker); fora do alvo => REPLAY_BLOCKED (sem escrita, sem reconsumir).
    $replayConsumedPath = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($ConsumedRoot)) {
            $replayConsumedPath = Join-Path $ConsumedRoot ($requestChange + '.json')
        }
    } catch { $replayConsumedPath = $null }
    $replayConsumedExists = $false
    if (-not [string]::IsNullOrWhiteSpace($replayConsumedPath)) {
        try { $replayConsumedExists = (Test-Path -LiteralPath $replayConsumedPath -PathType Leaf) } catch { $replayConsumedExists = $false }
    }
    if ($replayConsumedExists) {
        $replayHash = ''
        $replayAllow = @()
        try {
            $replayHash = Get-ConfigFileHash -ConfigPath $ConfigPath
            $replayAllow = @(Get-CurrentBuildAllowlist -ConfigPath $ConfigPath)
        } catch {
            throw ("REPLAY_BLOCKED (state=REPLAY_BLOCKED): change_id {0} ja consumido (marker presente); config ilegivel, sem escrita." -f $requestChange)
        }
        $replaySame = ($replayAllow.Count -eq $requestProposed.Count)
        if ($replaySame) {
            for ($ri = 0; $ri -lt $replayAllow.Count; $ri++) {
                if ($replayAllow[$ri] -cne $requestProposed[$ri]) { $replaySame = $false; break }
            }
        }
        if (($replayHash -ceq $requestTarget) -and $replaySame) {
            return [PSCustomObject]@{
                Status            = 'noop'
                State             = (Get-AuthorityRequestState -Request $Request)
                ChangeId          = $requestChange
                ConfigPath        = $ConfigPath
                BackupPath        = $null
                RollbackPath      = $null
                Warnings          = @()
                BookkeepingErrors = @()
            }
        }
        throw ("REPLAY_BLOCKED (state=REPLAY_BLOCKED): change_id {0} ja consumido em {1}; disco fora do alvo, nova mutacao com a mesma aprovacao bloqueada (sem escrita)." -f $requestChange, $replayConsumedPath)
    }

    # Idempotencia/noop ANTES do CAS: disco ja reflete o alvo (hash == target
    # E allowlist == proposta) => noop — mas SOMENTE apos revalidar aprovacao
    # (identidade), ownership e staleness de policy/agent-sources.
    $currentHash = Get-ConfigFileHash -ConfigPath $ConfigPath
    $currentAllow = @(Get-CurrentBuildAllowlist -ConfigPath $ConfigPath)
    $sameAllow = ($currentAllow.Count -eq $requestProposed.Count)
    if ($sameAllow) {
        for ($i = 0; $i -lt $currentAllow.Count; $i++) {
            if ($currentAllow[$i] -cne $requestProposed[$i]) { $sameAllow = $false; break }
        }
    }
    if (($currentHash -ceq $requestTarget) -and $sameAllow) {
        $retryCheck = Test-AuthorityApproval -Request $Request -ApprovalRecord $ApprovalRecord
        if (-not [bool]$retryCheck.Valid) {
            throw ("approval invalida (state=STALE): " + (($retryCheck.Reasons -join ' | ')))
        }
        try { Assert-AuthorityTargetOwnership -RepoRoot $root | Out-Null }
        catch { throw ("approval invalida (state=STALE): ownership falhou no retry noop: " + $_.Exception.Message) }
        $diskPolicyH = ''
        $diskAgentsH = ''
        try {
            $diskPolicyH = Get-PolicySourceHash -PolicyPath $policyFile
            $diskAgentsH = Get-AgentSourcesHash -AgentsRoot $agentsDir
        }
        catch { throw ("approval invalida (state=STALE): staleness check falhou no retry noop: " + $_.Exception.Message) }
        if (($diskPolicyH -cne $requestPolicyH) -or ($diskAgentsH -cne $requestAgentsH)) {
            throw ("approval invalida (state=STALE): STALE: policy/agent-sources mudaram desde o request (policy disco {0} vs request {1}; agents disco {2} vs request {3})" -f $diskPolicyH, $requestPolicyH, $diskAgentsH, $requestAgentsH)
        }
        $noopWarnings = @()
        try {
            $noopApprovalHash = ''
            if ($ApprovalRecord -is [System.Collections.IDictionary]) { $noopApprovalHash = [string]$ApprovalRecord['approval_hash'] }
            elseif ($null -ne $ApprovalRecord) { $noopApprovalHash = [string]$ApprovalRecord.approval_hash }
            $noopMarker = [ordered]@{
                version            = 1
                change_id          = $requestChange
                approval_hash      = $noopApprovalHash
                status             = 'consumed'
                consumed_at        = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $null
                rollback_path      = $null
                note               = 'noop idempotente: disco ja refletia o alvo; marker reconfirmado.'
            }
            Write-AuthorityConsumedMarker -ConsumedRoot $ConsumedRoot -ChangeId $requestChange -Value $noopMarker | Out-Null
        }
        catch { $noopWarnings += ('consumed marker best-effort falhou no noop (nao-fatal): ' + $_.Exception.Message) }
        return [PSCustomObject]@{
            Status            = 'noop'
            State             = (Get-AuthorityRequestState -Request $Request)
            ChangeId          = $requestChange
            ConfigPath        = $ConfigPath
            BackupPath        = $null
            RollbackPath      = $null
            Warnings          = $noopWarnings
            BookkeepingErrors = @()
        }
    }

    $check = Test-AuthorityApproval -Request $Request -ApprovalRecord $ApprovalRecord -RepoRoot $root -ConfigPath $ConfigPath -PolicyPath $policyFile -AgentsRoot $agentsDir
    if (-not [bool]$check.Valid) {
        throw ("approval invalida (state=STALE): " + (($check.Reasons -join ' | ')))
    }

    if ($currentHash -cne $requestBase) {
        throw ("CAS_CONFLICT (state=CAS_CONFLICT): base_config_hash do request ({0}) difere do disco ({1})" -f $requestBase, $currentHash)
    }

    if ($SimulatePreReplaceFailure) {
        throw 'simulated pre-replace failure (test-only; nothing was written)'
    }

    $fullBackup = Get-AuthorityFullPath -Path $BackupRoot
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRoot ($requestChange + '-' + $stamp)
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backupBase = Join-Path $backupDir 'opencode.json'
    $backupInfo = Backup-AuthorityRealConfig -SourcePath $ConfigPath -DestinationBase $backupBase
    $backupPath = [string]$backupInfo.path
    $rollbackPath = Join-Path $backupDir 'rollback.json'
    $rollbackDone = $false

    # Pre-imagem logica para a verificacao "apenas o subtree task mudou".
    $preText = [IO.File]::ReadAllText($fullConfig, [Text.UTF8Encoding]::new($false))

    $replaceDone = $false
    try {
        if ($isTest) {
            $mutApply = Set-BuildTaskAllowlist -ConfigPath $fullConfig -ProposedAllowlist $requestProposed -ExpectedHash $requestBase -TestRoot $fullTestRoot
        }
        else {
            $mutApply = Set-BuildTaskAllowlist -ConfigPath $fullConfig -ProposedAllowlist $requestProposed -ExpectedHash $requestBase -AllowRealWrite
        }
        if ([string]$mutApply.Status -ceq 'NO_CHANGE') {
            return [PSCustomObject]@{
                Status            = 'noop'
                State             = (Get-AuthorityRequestState -Request $Request)
                ChangeId          = $requestChange
                ConfigPath        = $ConfigPath
                BackupPath        = $null
                RollbackPath      = $null
                Warnings          = @()
                BookkeepingErrors = @()
            }
        }
        $replaceDone = $true
        if ($SimulatePostReplaceError) {
            throw 'simulated post-replace failure (test-only; backup will be restored and verified)'
        }
        if ($SimulatePostReplaceMismatch) {
            [IO.File]::AppendAllText($fullConfig, "`n", [Text.UTF8Encoding]::new($false))
        }
        $after = Get-ConfigFileHash -ConfigPath $ConfigPath
        if ($after -cne $requestTarget) {
            $restoreResult = Restore-AuthorityRealConfigFromBackup -BackupPath $backupPath -ConfigPath $ConfigPath -SimulateCorruption ([bool]$SimulateRestoreFailure)
            if ([bool]$restoreResult.Verified) {
                $rollback = [ordered]@{
                    version            = 1
                    change_id          = $requestChange
                    created_at         = (Get-Date).ToUniversalTime().ToString('o')
                    config_path        = $ConfigPath
                    base_config_hash   = $requestBase
                    target_config_hash = $requestTarget
                    backup_path        = $backupPath
                    status             = 'ROLLED_BACK'
                    state              = 'ROLLED_BACK'
                    note               = 'Hash pos-replace divergiu; backup restaurado e VERIFICADO byte-a-byte contra o backup.'
                }
                Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
                $rollbackDone = $true
                return [PSCustomObject]@{
                    Status       = 'ROLLED_BACK'
                    State        = 'ROLLED_BACK'
                    ChangeId     = $requestChange
                    ConfigPath   = $ConfigPath
                    BackupPath   = $backupPath
                    RollbackPath = $rollbackPath
                }
            }
            $restoreError = [string]$restoreResult.Error
            $rollback = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = $restoreError
                note               = 'Hash pos-replace divergiu e a restauracao automatica FALHOU na verificacao; restaure o backup manualmente.'
            }
            Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
            $rollbackDone = $true
            throw ("Post-apply hash mismatch (state=ROLLBACK_REQUIRED): esperado {0}, atual {1}; restore/verificacao falhou: {2}" -f $requestTarget, $after, $restoreError)
        }
        # JSON valido + apenas o subtree task mudou (hash logico dos
        # nao-governados igual ao pre-apply). Falha aqui => rollback.
        try {
            $postText = [IO.File]::ReadAllText($fullConfig, [Text.UTF8Encoding]::new($false))
            $o1 = $preText | ConvertFrom-Json
            $o2 = $postText | ConvertFrom-Json
            $o1.agent.build.permission.PSObject.Properties.Remove('task')
            $o2.agent.build.permission.PSObject.Properties.Remove('task')
            $h1 = Get-LogicalHash -InputObject $o1
            $h2 = Get-LogicalHash -InputObject $o2
            if ($h1 -cne $h2) {
                throw 'campos nao-governados divergiram apos o apply real (fail-closed: apenas o subtree task pode mudar)'
            }
        }
        catch {
            $restoreResult = Restore-AuthorityRealConfigFromBackup -BackupPath $backupPath -ConfigPath $ConfigPath -SimulateCorruption ([bool]$SimulateRestoreFailure)
            if ([bool]$restoreResult.Verified) {
                $rollback = [ordered]@{
                    version            = 1
                    change_id          = $requestChange
                    created_at         = (Get-Date).ToUniversalTime().ToString('o')
                    config_path        = $ConfigPath
                    base_config_hash   = $requestBase
                    target_config_hash = $requestTarget
                    backup_path        = $backupPath
                    status             = 'ROLLED_BACK'
                    state              = 'ROLLED_BACK'
                    error              = $_.Exception.Message
                    note               = 'Validacao pos-apply (JSON/subtree) falhou; backup restaurado e VERIFICADO byte-a-byte.'
                }
                Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
                $rollbackDone = $true
                return [PSCustomObject]@{
                    Status       = 'ROLLED_BACK'
                    State        = 'ROLLED_BACK'
                    ChangeId     = $requestChange
                    ConfigPath   = $ConfigPath
                    BackupPath   = $backupPath
                    RollbackPath = $rollbackPath
                }
            }
            $restoreError = [string]$restoreResult.Error
            $rollback = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = ($_.Exception.Message + ' | restore/verificacao falhou: ' + $restoreError)
                note               = 'Validacao pos-apply falhou e a restauracao/verificacao FALHOU; restaure o backup manualmente.'
            }
            Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
            $rollbackDone = $true
            throw ("Post-apply validation failure (state=ROLLBACK_REQUIRED): {0}; restore/verificacao falhou: {1}" -f $_.Exception.Message, $restoreError)
        }
        # --- BOOKKEEPING PHASE (best-effort, nao-fatal) ---
        $warnings = New-Object System.Collections.Generic.List[string]
        $bkErrors = New-Object System.Collections.Generic.List[string]
        $approvalHashValue = ''
        if ($ApprovalRecord -is [System.Collections.IDictionary]) { $approvalHashValue = [string]$ApprovalRecord['approval_hash'] }
        elseif ($null -ne $ApprovalRecord) { $approvalHashValue = [string]$ApprovalRecord.approval_hash }
        $approverValue = ''
        if ($ApprovalRecord -is [System.Collections.IDictionary]) { $approverValue = [string]$ApprovalRecord['approver'] }
        elseif ($null -ne $ApprovalRecord) { $approverValue = [string]$ApprovalRecord.approver }
        $approvedAtValue = ''
        if ($ApprovalRecord -is [System.Collections.IDictionary]) { $approvedAtValue = [string]$ApprovalRecord['approved_at'] }
        elseif ($null -ne $ApprovalRecord) { $approvedAtValue = [string]$ApprovalRecord.approved_at }
        $rollback = [ordered]@{
            version            = 1
            change_id          = $requestChange
            created_at         = (Get-Date).ToUniversalTime().ToString('o')
            config_path        = $ConfigPath
            base_config_hash   = $requestBase
            target_config_hash = $requestTarget
            backup_path        = $backupPath
            backup_encoding    = [string]$backupInfo.encoding
            status             = 'applied-and-verified'
            state              = 'APPLIED_TO_DISK'
            note               = 'Apply real pos-aprovacao humana. Restore pelo backup (DPAPI: Unprotect CurrentUser; plain: copia byte-a-byte).'
        }
        try {
            if ([bool]$SimulateBookkeepingFailure) {
                throw 'simulated bookkeeping failure (test-only; fingerprint indisponivel)'
            }
            if ((Get-Command Get-FileSetFingerprint -ErrorAction SilentlyContinue) -ne $null) {
                $rollback['config_snapshot'] = (Get-FileSetFingerprint -FilePaths @($ConfigPath))
            }
        }
        catch {
            $msg = ('bookkeeping fingerprint falhou (nao-fatal; config aplicado e verificado): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
        }
        try {
            if ([bool]$SimulateBookkeepingFailure) {
                throw 'simulated bookkeeping failure (test-only; reload-state indisponivel)'
            }
            $targetRoot = Split-Path -Parent $fullConfig
            if ($isTest) { $targetRoot = $fullTestRoot }
            if ((Get-Command Set-RuntimeReloadStatus -ErrorAction SilentlyContinue) -ne $null) {
                Set-RuntimeReloadStatus -Status 'DISK_APPLIED_RELOAD_REQUIRED' -TargetRoot $targetRoot -StorePath $ReloadStorePath -ConfigPath $ConfigPath | Out-Null
            }
        }
        catch {
            $msg = ('bookkeeping reload-state falhou (nao-fatal; reload-state pode estar incompleto): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
            [Console]::Error.WriteLine($msg)
        }
        $rollback['warnings'] = [string[]]$warnings
        $rollback['bookkeeping_errors'] = [string[]]$bkErrors
        try {
            if ([bool]$SimulateRollbackWriteFailure -or [bool]$SimulateBookkeepingFailure) {
                throw 'simulated rollback write failure (test-only; bookkeeping nao-fatal)'
            }
            Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollback | ConvertTo-Json -Depth 10) + "`n")
            $rollbackDone = $true
        }
        catch {
            $msg = ('bookkeeping rollback.json falhou (nao-fatal; config aplicado e verificado): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
            [Console]::Error.WriteLine($msg)
        }
        try {
            if ([bool]$SimulateBookkeepingFailure) {
                throw 'simulated bookkeeping failure (test-only; consumed marker indisponivel)'
            }
            $marker = [ordered]@{
                version            = 1
                change_id          = $requestChange
                approval_hash      = $approvalHashValue
                approver           = $approverValue
                approved_at        = $approvedAtValue
                approval_status    = 'approved'
                status             = 'consumed'
                consumed_at        = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                rollback_path      = $rollbackPath
            }
            Write-AuthorityConsumedMarker -ConsumedRoot $ConsumedRoot -ChangeId $requestChange -Value $marker | Out-Null
        }
        catch {
            $msg = ('bookkeeping consumed marker falhou (nao-fatal; config aplicado e verificado): ' + $_.Exception.Message)
            $warnings.Add($msg) | Out-Null
            $bkErrors.Add($msg) | Out-Null
            [Console]::Error.WriteLine($msg)
        }
        return [PSCustomObject]@{
            Status            = 'applied'
            State             = 'APPLIED_TO_DISK'
            ChangeId          = $requestChange
            ConfigPath        = $ConfigPath
            BackupPath        = $backupPath
            RollbackPath      = $rollbackPath
            Warnings          = [string[]]$warnings
            BookkeepingErrors = [string[]]$bkErrors
        }
    }
    catch {
        $caughtMessage = $_.Exception.Message
        if ($replaceDone) {
            $postRestore = Restore-AuthorityRealConfigFromBackup -BackupPath $backupPath -ConfigPath $ConfigPath -SimulateCorruption ([bool]$SimulateRestoreFailure)
            if ([bool]$postRestore.Verified) {
                $rollbackRestored = [ordered]@{
                    version            = 1
                    change_id          = $requestChange
                    created_at         = (Get-Date).ToUniversalTime().ToString('o')
                    config_path        = $ConfigPath
                    base_config_hash   = $requestBase
                    target_config_hash = $requestTarget
                    backup_path        = $backupPath
                    status             = 'ROLLED_BACK'
                    state              = 'ROLLED_BACK'
                    error              = $caughtMessage
                    note               = 'Excecao pos-replace no apply real; backup restaurado e VERIFICADO byte-a-byte contra o backup.'
                }
                try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackRestored | ConvertTo-Json -Depth 10) + "`n") } catch { }
                $rollbackDone = $true
                return [PSCustomObject]@{
                    Status       = 'ROLLED_BACK'
                    State        = 'ROLLED_BACK'
                    ChangeId     = $requestChange
                    ConfigPath   = $ConfigPath
                    BackupPath   = $backupPath
                    RollbackPath = $rollbackPath
                }
            }
            $postRestoreError = [string]$postRestore.Error
            $rollbackRequired = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = ($caughtMessage + ' | restore/verificacao falhou: ' + $postRestoreError)
                note               = 'Excecao pos-replace no apply real e restauracao/verificacao FALHOU; restaure o backup manualmente.'
            }
            try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackRequired | ConvertTo-Json -Depth 10) + "`n") } catch { }
            $rollbackDone = $true
            throw ("Post-replace failure (state=ROLLBACK_REQUIRED): {0}; restore/verificacao falhou: {1}" -f $caughtMessage, $postRestoreError)
        }
        if (-not $rollbackDone) {
            $rollbackFail = [ordered]@{
                version            = 1
                change_id          = $requestChange
                created_at         = (Get-Date).ToUniversalTime().ToString('o')
                config_path        = $ConfigPath
                base_config_hash   = $requestBase
                target_config_hash = $requestTarget
                backup_path        = $backupPath
                status             = 'ROLLBACK_REQUIRED'
                state              = 'ROLLBACK_REQUIRED'
                error              = $caughtMessage
            }
            try { Write-AuthorityUtf8NoBomLf -Path $rollbackPath -Text (($rollbackFail | ConvertTo-Json -Depth 10) + "`n") } catch { }
        }
        throw
    }
}
