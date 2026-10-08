<#!
.SYNOPSIS
    Phase 2D Capability Resolver (SHADOW ONLY). Deterministic, offline, read-only.
.DESCRIPTION
    Library dot-sourceable (no execution on load). Exports:
      Get-ProjectContext -ProjectRoot
      Invoke-CapabilityResolve -TaskInput
    Reads source/registry/capability-routing.json (version 1). Never executes
    tools, never changes config or flags. Same input -> same output.
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-ResolverRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-ResolverUtf8Text {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Get-ResolverRoutingDoc {
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$RoutingPath)
    $resolved = $RoutingPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $root = Get-ResolverRepoRoot -RepoRoot $RepoRoot
        $resolved = Join-Path $root 'source\registry\capability-routing.json'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw ("capability-routing.json not found: {0}" -f $resolved)
    }
    $text = Read-ResolverUtf8Text -Path $resolved
    $doc = $null
    try { $doc = $text | ConvertFrom-Json }
    catch { throw ("capability-routing.json invalid: {0} ({1})" -f $resolved, $_.Exception.Message) }
    # R2 FIX 2 (schema invalido): version -eq 1 e arrays obrigatorios.
    # Qualquer checagem falha -> throw capturavel (Invoke-CapabilityResolve
    # cai no fail-safe explicito; nunca throw operacional).
    $ver = -1
    try { $ver = [int]$doc.version } catch { $ver = -1 }
    if ($ver -ne 1) {
        throw ("capability-routing.json schema invalid (version must be 1): {0}" -f $resolved)
    }
    foreach ($f in @('task_classes', 'reason_codes', 'stack_detectors', 'profile_rules', 'agent_rules', 'skill_rules', 'mcp_rules', 'fallbacks')) {
        $v = $null
        try { $v = $doc.$f } catch { $v = $null }
        if (($null -eq $v) -or (-not ($v -is [System.Array]))) {
            throw ("capability-routing.json schema invalid (field '{0}' must be an array): {1}" -f $f, $resolved)
        }
    }
    return $doc
}

function Get-ResolverActiveSkillIds {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-ResolverRepoRoot -RepoRoot $RepoRoot
    $catalog = Join-Path $root 'source\registry\skills-catalog.json'
    if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) { return @() }
    $text = Read-ResolverUtf8Text -Path $catalog
    $doc = $text | ConvertFrom-Json
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($doc.skills)) {
        $id = ''
        $st = ''
        try { $id = Convert-ResolverNorm -Text ([string]$s.id) } catch { $id = '' }
        try { $st = ([string]$s.status).Trim().ToUpperInvariant() } catch { $st = '' }
        if (([string]::IsNullOrWhiteSpace($id)) -or ($st -cne 'ACTIVE')) { continue }
        if ($ids -cnotcontains $id) { $ids.Add($id) | Out-Null }
    }
    return [string[]]$ids
}

function Get-ResolverFailSafe {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        agents         = @('coder')
        skills         = @()
        profiles       = @()
        pilot_profiles = @()
        mcps           = @()
        capabilities   = @('code.bounded-edit')
        permissions    = [PSCustomObject]@{ recommendation = 'allow'; enforcement_authority = 'advisory-shadow (no enforcement)' }
        risk           = [PSCustomObject]@{ level = 'MEDIUM' }
        fallbacks      = @()
        reason_codes   = @('AMBIGUOUS')
        confidence     = 'AMBIGUOUS'
        mode           = 'shadow'
    }
}

function Convert-ResolverNorm {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ([string]$Text).Trim().ToLowerInvariant()
}

function Get-ProjectContext {
    <#
    .SYNOPSIS
        Scans ProjectRoot with Test-Path only (no network, no secrets).
    #>
    [CmdletBinding()]
    param([string]$ProjectRoot)
    $stacks = New-Object System.Collections.Generic.List[string]
    $signals = New-Object System.Collections.Generic.List[string]
    $evidence = New-Object System.Collections.Generic.List[string]
    $root = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-ResolverRepoRoot -RepoRoot ''
    }
    try {
        $doc = Get-ResolverRoutingDoc -RepoRoot (Get-ResolverRepoRoot -RepoRoot '')
        $detectors = @()
        try { $detectors = @($doc.stack_detectors) } catch { $detectors = @() }
        foreach ($d in $detectors) {
            $marker = ''
            $stack = ''
            $signal = ''
            try { $marker = [string]$d.marker } catch { $marker = '' }
            try { $stack = [string]$d.stack } catch { $stack = '' }
            try { $signal = [string]$d.signal } catch { $signal = '' }
            if ([string]::IsNullOrWhiteSpace($marker)) { continue }
            $candidate = Join-Path $root $marker
            $found = $false
            try { $found = Test-Path -LiteralPath $candidate } catch { $found = $false }
            if ($found) {
                # P2-1 FIX: marker sozinho nunca prova stack de banco. Um diretorio
                # supabase/ vazio (ou so com README) nao conta: exige evidencia
                # concreta via Test-Path (config/migrations/sql/functions). Vide
                # source/registry/capability-routing.json (stack_detector_note).
                if ($marker -ceq 'supabase') {
                    $isDir = $false
                    try { $isDir = Test-Path -LiteralPath $candidate -PathType Container } catch { $isDir = $false }
                    if ($isDir) {
                        $hasEv = $false
                        foreach ($e in @('config.toml', 'config.json', 'migrations', 'seed.sql', 'schema.sql', 'functions')) {
                            try { if (Test-Path -LiteralPath (Join-Path $candidate $e)) { $hasEv = $true; break } } catch { }
                        }
                        if (-not $hasEv) { continue }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($stack)) {
                    if ($stacks -cnotcontains $stack) { $stacks.Add($stack) }
                }
                if (-not [string]::IsNullOrWhiteSpace($signal)) {
                    if ($signals -cnotcontains $signal) { $signals.Add($signal) }
                }
                $evidence.Add(("marker:{0}" -f $marker))
            }
        }
    }
    catch { }
    $a1 = [string[]]$stacks
    $a2 = [string[]]$signals
    $a3 = [string[]]$evidence
    [Array]::Sort($a1, [System.StringComparer]::Ordinal)
    [Array]::Sort($a2, [System.StringComparer]::Ordinal)
    [Array]::Sort($a3, [System.StringComparer]::Ordinal)
    return [PSCustomObject]@{
        project_root = [string]$root
        stacks       = $a1
        signals      = $a2
        evidence     = $a3
    }
}

function Test-ResolverBlobHas {
    [CmdletBinding()]
    param([string]$Blob, [string[]]$Words)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return $false }
    $tokens = @($Blob -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($w in @($Words)) {
        $kw = Convert-ResolverNorm -Text ([string]$w)
        if ([string]::IsNullOrWhiteSpace($kw)) { continue }
        if ($kw -match '^[a-z0-9]+$') {
            foreach ($t in $tokens) {
                if ($t.StartsWith($kw, [System.StringComparison]::Ordinal)) { return $true }
            }
        }
        else {
            if ($Blob.Contains($kw)) { return $true }
        }
    }
    return $false
}

function Test-ResolverBlobHasExact {
    [CmdletBinding()]
    param([string]$Blob, [string[]]$Words)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return $false }
    $tokens = @($Blob -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($w in @($Words)) {
        $kw = Convert-ResolverNorm -Text ([string]$w)
        if ([string]::IsNullOrWhiteSpace($kw)) { continue }
        if ($tokens -ccontains $kw) { return $true }
    }
    return $false
}

function Get-ResolverField {
    [CmdletBinding()]
    param($Node, [string]$Field)
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Field)) { return $Node[$Field] }
            return $null
        }
        foreach ($p in @($Node.PSObject.Properties)) {
            if ($p.Name -ceq $Field) { return $p.Value }
        }
    }
    catch { }
    return $null
}

function Invoke-CapabilityResolve {
    <#
    .SYNOPSIS
        Deterministic shadow resolve. Never throws for operational input.
    #>
    [CmdletBinding()]
    param($TaskInput, [string]$RoutingPath)
    $agents = New-Object System.Collections.Generic.List[string]
    $skills = New-Object System.Collections.Generic.List[string]
    $profiles = New-Object System.Collections.Generic.List[string]
    $pilotProfiles = New-Object System.Collections.Generic.List[string]
    $mcps = New-Object System.Collections.Generic.List[string]
    $caps = New-Object System.Collections.Generic.List[string]
    $codes = New-Object System.Collections.Generic.List[string]
    $fallbacks = New-Object System.Collections.Generic.List[string]
    $risk = 'MEDIUM'
    $confidence = 'HIGH'
    $permRec = 'allow'
    $permAuth = 'advisory-shadow (no enforcement)'
    $doc = $null
    try { $doc = Get-ResolverRoutingDoc -RepoRoot '' -RoutingPath $RoutingPath }
    catch { $doc = $null }
    if ($null -eq $doc) { return Get-ResolverFailSafe }
    try {
        $task = ''
        $taskClass = ''
        $reqAgent = ''
        $reqCaps = @()
        $riskCtx = ''
        $projStack = ''
        $projRoot = ''
        try {
            $v = Get-ResolverField -Node $TaskInput -Field 'task'
            if ($null -ne $v) { $task = [string]$v }
            $v = Get-ResolverField -Node $TaskInput -Field 'task_class'
            if ($null -ne $v) { $taskClass = Convert-ResolverNorm -Text ([string]$v) }
            $v = Get-ResolverField -Node $TaskInput -Field 'requested_agent'
            if ($null -ne $v) { $reqAgent = Convert-ResolverNorm -Text ([string]$v) }
            $v = Get-ResolverField -Node $TaskInput -Field 'requested_capabilities'
            if ($null -ne $v) { $reqCaps = @($v) | ForEach-Object { Convert-ResolverNorm -Text ([string]$_) } }
            $v = Get-ResolverField -Node $TaskInput -Field 'risk_context'
            if ($null -ne $v) { $riskCtx = Convert-ResolverNorm -Text ([string]$v) }
            $pnode = Get-ResolverField -Node $TaskInput -Field 'project'
            if ($null -ne $pnode) {
                $sv = Get-ResolverField -Node $pnode -Field 'stack'
                if ($null -ne $sv) { $projStack = Convert-ResolverNorm -Text ([string]$sv) }
            }
            $v = Get-ResolverField -Node $TaskInput -Field 'projectRoot'
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $projRoot = [string]$v }
            if ([string]::IsNullOrWhiteSpace($projRoot)) {
                $v = Get-ResolverField -Node $TaskInput -Field 'project_root'
                if ($null -ne $v) { $projRoot = [string]$v }
            }
        }
        catch { }
        $ctx = $null
        try { $ctx = Get-ProjectContext -ProjectRoot $projRoot } catch { $ctx = $null }
        $ctxStacks = @()
        if ($null -ne $ctx) { try { $ctxStacks = @($ctx.stacks) } catch { $ctxStacks = @() } }
        $blob = Convert-ResolverNorm -Text (([string]$task) + ' ' + $taskClass + ' ' + $riskCtx + ' ' + $projStack + ' ' + (($ctxStacks | ForEach-Object { "$_" }) -join ' '))
        # 2F-FIX-DEBUGGER-R5R6 (plano sec. 10.3): sinais de risco
        # (isFinancial/isProd e as excecoes doc/logs-read) sao calculados sobre
        # o TEXTO DA TAREFA. task_class/stack (metadata) NAO alimentam mencao
        # nem excecao: nao podem fornecer sinais que rebaixem risco.
        # risk_context explicito so pode ELEVAR (OR), nunca rebaixar.
        # $blob acima segue inalterado para os demais sinais (agentes, skills,
        # perfis, capabilities): la meta-dado continua valendo como hint.
        $riskText = Convert-ResolverNorm -Text ([string]$task)
        $riskCtxText = Convert-ResolverNorm -Text ([string]$riskCtx)
        $riskTokens = @($riskText -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $mentionSupabase = (Test-ResolverBlobHas -Blob $blob -Words @('supabase'))
        $mentionNeon = (Test-ResolverBlobHas -Blob $blob -Words @('neon'))
        $proofSupabase = (($ctxStacks -ccontains 'supabase') -or ($projStack -ceq 'supabase'))
        $proofNeon = (($ctxStacks -ccontains 'neon') -or ($projStack -ceq 'neon'))
        $provenDb = ($proofSupabase -or $proofNeon)
        $needsDb = (Test-ResolverBlobHas -Blob $blob -Words @('database', 'sql', 'migration', 'migrate', 'schema', 'postgres', 'banco'))
        $needsE2E = (Test-ResolverBlobHas -Blob $blob -Words @('e2e', 'playwright', 'fluxo web', 'formulario', 'navegacao', 'checkout flow'))
        $needsRuntimeDbg = (Test-ResolverBlobHas -Blob $blob -Words @('console', 'runtime', 'flaky', 'stacktrace', 'perf', 'network', 'dom'))
        $needsDocs = (Test-ResolverBlobHas -Blob $blob -Words @('docs', 'library', 'framework', 'version', 'api reference'))
        $needsMemory = (Test-ResolverBlobHas -Blob $blob -Words @('memory', 'historico', 'handoff', 'decisao'))
        $isAmbiguous = [string]::IsNullOrWhiteSpace($task)
        # 2F-FIX-DEBUGGER-R5R6: mencao financeira sozinha nao basta para
        # CRITICAL quando a intencao e exclusivamente documental (ex.:
        # document Stripe refund procedure -> LOW + allow). Sem sinal
        # documental, mencao continua CRITICAL (conservador: N1 segue
        # CRITICAL). Regra REAL (plano 10.3; sem alegar compreensao
        # semantica, apenas forma textual fechada):
        # (1) verbo de execucao inequivoco em QUALQUER posicao veta a excecao
        #     documental (tokens exatos; 'refund' fica FORA do veto: ambiguo,
        #     fica sob clausula + alvo);
        # (2) o texto e dividido em clausulas por 'and'/'then'/';' e a excecao
        #     vale SOMENTE se TODA clausula com mencao financeira contiver
        #     verbo documental proprio (document/explain/describe/draft/write
        #     + flexoes; 'procedure' sozinho NAO conta: e substantivo);
        # (3) alvo operacional (customer/payment/invoice/subscription/card/
        #     order + plural) tambem veta.
        $isFinancialMention = (Test-ResolverBlobHas -Blob $riskText -Words @('refund', 'payout', 'pagamento', 'cobranca', 'stripe', 'financial'))
        $isFinancialMentionCtx = (Test-ResolverBlobHas -Blob $riskCtxText -Words @('refund', 'payout', 'pagamento', 'cobranca', 'stripe', 'financial'))
        $finExecVeto = (Test-ResolverBlobHasExact -Blob $riskText -Words @('execute', 'executes', 'executed', 'executing', 'process', 'processes', 'processed', 'processing', 'perform', 'performs', 'performed', 'performing', 'run', 'runs', 'running', 'initiate', 'initiates', 'initiated', 'initiating', 'approve', 'approves', 'approved', 'approving', 'confirm', 'confirms', 'confirmed', 'confirming', 'submit', 'submits', 'submitted', 'submitting', 'transfer', 'transfers', 'transferred', 'transferring', 'charge', 'charges', 'charged', 'charging', 'pay', 'pays', 'paid', 'paying', 'payout', 'payouts'))
        $finDocVerbWords = @('document', 'documents', 'documented', 'documenting', 'explain', 'explains', 'explained', 'explaining', 'describe', 'describes', 'described', 'describing', 'draft', 'drafts', 'drafted', 'drafting', 'write', 'writes', 'writing', 'written')
        $finMentionWords = @('refund', 'payout', 'pagamento', 'cobranca', 'stripe', 'financial')
        $isFinancialOpTarget = (Test-ResolverBlobHasExact -Blob $riskText -Words @('customer', 'customers', 'payment', 'payments', 'invoice', 'invoices', 'subscription', 'subscriptions', 'card', 'cards', 'order', 'orders'))
        # 2F-FIX-CLAUSE-SEPARATORS (plano 10.4): separadores de clausula
        # ampliados de 'and'/'then'/';' para incluir '.', ',', ':', '!?',
        # 'but' e quebra de linha. Clausulas VAZIAS apos o split sao
        # ignoradas: ponto final isolado ('document Stripe refund
        # procedure.') nao cria clausula e a excecao segue valendo (LOW).
        # FRONTEIRA (faz valer no codigo): a excecao documental so vale em
        # clausula UNICA com mencao financeira, verbo documental proprio,
        # sem exec-veto (R5) e sem alvo operacional. Mencao financeira
        # distribuida em 2+ clausulas nao-vazias => algum contexto sem
        # verbo documental proprio => CRITICAL + deny (conservador; nao ha
        # alegacao semantica, apenas forma textual fechada). 'or'/'with'
        # ficam FORA dos separadores (residual documentado no plano).
        $finClauseSplitRx = '\b(?:and|then|but)\b|[.,:;!?\r\n]+'
        $finClauses = @($riskText -split $finClauseSplitRx | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $finDocClausesOk = ($finClauses.Count -eq 1)
        if ($finDocClausesOk) {
            $cl = [string]$finClauses[0]
            if (-not (Test-ResolverBlobHas -Blob $cl -Words $finMentionWords)) { $finDocClausesOk = $false }
            elseif (-not (Test-ResolverBlobHasExact -Blob $cl -Words $finDocVerbWords)) { $finDocClausesOk = $false }
        }
        $finDocException = ($isFinancialMention -and $finDocClausesOk -and (-not $finExecVeto) -and (-not $isFinancialOpTarget))
        $isFinancial = (($isFinancialMention -and (-not $finDocException)) -or $isFinancialMentionCtx)
        # P2-4 FIX: token 'release' isolado nao e escrita em producao (ex.:
        # "review release notes"). RISK_PRODUCTION_WRITE exige contexto de
        # producao/deploy/escrita. Vide risk_model (production deploy).
        # 2F: leitura de logs de producao/deploy (read + deployment logs) nao e
        # escrita em producao: LOW + allow, sem RISK_PRODUCTION_WRITE. Qualquer
        # outra mencao a production/deploy continua HIGH + deny (conservador).
        # 2F-FIX-DEBUGGER-R5R6 (plano 10.3): a excecao de logs-read vale por
        # FORMA TEXTUAL FECHADA sobre o texto da tarefa: TODO token do texto
        # precisa ser verbo de leitura, descritor (production/producao/
        # deployment/prod), 'logs' ou filler (artigos/preposicoes/listados).
        # Qualquer token de conteudo fora da forma => sem excecao => HIGH +
        # deny + RISK_PRODUCTION_WRITE. 'deployment' e descritor (nao flexao
        # de deploy); 'release' NAO e descritor da forma (sem ele a forma nao
        # casa; 'review release notes' continua LOW por nao ter mencao de
        # producao).
        $isProdMention = (Test-ResolverBlobHas -Blob $riskText -Words @('production', 'producao', 'deploy'))
        $isProdMentionCtx = (Test-ResolverBlobHas -Blob $riskCtxText -Words @('production', 'producao', 'deploy'))
        $logsReadVerbs = @('read', 'reads', 'reading', 'review', 'reviews', 'reviewing', 'lookup', 'lookups', 'analyze', 'analyzes', 'analyzed', 'analyzing', 'summarize', 'summarizes', 'summarized', 'summarizing', 'show', 'shows', 'showed', 'showing', 'list', 'lists', 'listed', 'listing', 'view', 'views', 'viewed', 'viewing', 'monitor', 'monitors', 'monitored', 'monitoring', 'check', 'checks', 'checked', 'checking', 'tail', 'tails', 'tailed', 'tailing', 'fetch', 'fetches', 'fetched', 'fetching', 'get', 'gets', 'gotten', 'getting', 'display', 'displays', 'displayed', 'displaying')
        $logsDescriptors = @('production', 'producao', 'deployment', 'prod')
        $logsFillers = @('the', 'a', 'an', 'of', 'for', 'to', 'in', 'on', 'from', 'with', 'and', 'last', 'latest', 'recent', 'first', 'app', 'application', 'service', 'server', 'lines')
        $logsFormAllowed = @($logsReadVerbs + $logsDescriptors + $logsFillers + @('logs'))
        $logsFormShaped = ($riskTokens.Count -gt 0)
        foreach ($t in $riskTokens) { if ($logsFormAllowed -cnotcontains $t) { $logsFormShaped = $false; break } }
        $isProdLogsRead = ($logsFormShaped -and (Test-ResolverBlobHasExact -Blob $riskText -Words $logsReadVerbs) -and (Test-ResolverBlobHasExact -Blob $riskText -Words $logsDescriptors) -and (Test-ResolverBlobHasExact -Blob $riskText -Words @('logs')))
        # defesa em profundidade: verbo de mutacao em producao (flexoes por
        # token exato; nunca prefixo que case com 'deployment'; 'release' fora
        # da lista para preservar 'review release notes'). Com a forma fechada
        # acima, qualquer mutacao ja quebra a forma; a lista segue como veto
        # redundante e explicito.
        $isProdMutation = (Test-ResolverBlobHasExact -Blob $riskText -Words @('deploy', 'deploys', 'deployed', 'deploying', 'delete', 'deletes', 'deleted', 'deleting', 'truncate', 'truncates', 'truncated', 'truncating', 'destroy', 'destroys', 'destroyed', 'destroying', 'drop', 'drops', 'dropped', 'dropping', 'update', 'updates', 'updated', 'updating', 'upgrade', 'upgrades', 'upgraded', 'upgrading', 'publish', 'publishes', 'published', 'publishing', 'rollout', 'rollouts', 'restart', 'restarts', 'restarted', 'restarting', 'scale', 'scales', 'scaled', 'scaling', 'stop', 'stops', 'stopped', 'stopping', 'start', 'starts', 'started', 'starting', 'reboot', 'reboots', 'rebooted', 'rebooting', 'push', 'pushes', 'pushed', 'pushing', 'apply', 'applies', 'applied', 'applying', 'trigger', 'triggers', 'triggered', 'triggering', 'migrate', 'migrates', 'migrated', 'migrating'))
        $isProd = (($isProdMention -and (-not ($isProdLogsRead -and (-not $isProdMutation)))) -or $isProdMentionCtx)
        $isMigration = (Test-ResolverBlobHas -Blob $blob -Words @('migration', 'migrate', 'ddl'))
        # reason codes (PROJECT_USES_* exige prova de projeto; mencao textual sozinha nao prova)
        if ($proofSupabase -and $needsDb) { if ($codes -cnotcontains 'PROJECT_USES_SUPABASE') { $codes.Add('PROJECT_USES_SUPABASE') } }
        if ($proofNeon -and $needsDb) { if ($codes -cnotcontains 'PROJECT_USES_NEON') { $codes.Add('PROJECT_USES_NEON') } }
        if ($needsDb) { if ($codes -cnotcontains 'TASK_REQUIRES_DATABASE') { $codes.Add('TASK_REQUIRES_DATABASE') } }
        if ($needsE2E) { if ($codes -cnotcontains 'BROWSER_E2E_REQUIRED') { $codes.Add('BROWSER_E2E_REQUIRED') } }
        if ($needsRuntimeDbg) {
            if ($codes -cnotcontains 'BROWSER_RUNTIME_DEBUG') { $codes.Add('BROWSER_RUNTIME_DEBUG') }
            if ($codes -cnotcontains 'CONSOLE_DIAGNOSTICS') { $codes.Add('CONSOLE_DIAGNOSTICS') }
            if ($codes -cnotcontains 'DOM_INSPECTION') { $codes.Add('DOM_INSPECTION') }
            if ($codes -cnotcontains 'NETWORK_DEBUG') { $codes.Add('NETWORK_DEBUG') }
            if ((Test-ResolverBlobHas -Blob $blob -Words @('perf', 'trace', 'lighthouse'))) { if ($codes -cnotcontains 'PERFORMANCE_TRACE') { $codes.Add('PERFORMANCE_TRACE') } }
        }
        if ($needsDocs) {
            if ($codes -cnotcontains 'LIBRARY_DOCS_REQUIRED') { $codes.Add('LIBRARY_DOCS_REQUIRED') }
            if ((Test-ResolverBlobHas -Blob $blob -Words @('version'))) { if ($codes -cnotcontains 'VERSION_SPECIFIC_API') { $codes.Add('VERSION_SPECIFIC_API') } }
            if ((Test-ResolverBlobHas -Blob $blob -Words @('unknown', 'behavior', 'comportamento'))) { if ($codes -cnotcontains 'UNKNOWN_FRAMEWORK_BEHAVIOR') { $codes.Add('UNKNOWN_FRAMEWORK_BEHAVIOR') } }
        }
        if ($isProd) { if ($codes -cnotcontains 'RISK_PRODUCTION_WRITE') { $codes.Add('RISK_PRODUCTION_WRITE') } }
        if ($isAmbiguous) { if ($codes -cnotcontains 'AMBIGUOUS') { $codes.Add('AMBIGUOUS') } }
        # risk
        if ($isFinancial) { $risk = 'CRITICAL' }
        elseif ($isMigration -or $isProd) { $risk = 'HIGH' }
        elseif ($needsE2E -or $needsRuntimeDbg) { $risk = 'MEDIUM' }
        else { $risk = 'LOW' }
        if ($isFinancial -or $isProd) { $permRec = 'deny' } else { $permRec = 'allow' }
        # agent selection via agent_rules (first keyword match wins)
        $selected = ''
        try {
            foreach ($r in @($doc.agent_rules)) {
                $kws = @()
                try { $kws = @($r.keywords) } catch { $kws = @() }
                if (Test-ResolverBlobHas -Blob $blob -Words $kws) {
                    $selected = Convert-ResolverNorm -Text ([string]$r.agent)
                    break
                }
            }
        }
        catch { }
        if ([string]::IsNullOrWhiteSpace($selected)) { $selected = 'coder' }
        # user override wins when safe
        $allowedAgents = @('coder', 'tester', 'reviewer', 'debugger', 'docs-manager', 'frontend-engineer', 'backend-engineer', 'database-engineer', 'architect', 'researcher', 'requirements-analyst', 'security-reviewer')
        if (-not [string]::IsNullOrWhiteSpace($reqAgent)) {
            if ($allowedAgents -ccontains $reqAgent) {
                $safeOverride = $true
                if ($isFinancial -and ($reqAgent -cne 'backend-engineer') -and ($reqAgent -cne 'reviewer') -and ($reqAgent -cne 'security-reviewer')) {
                    $safeOverride = $true
                }
                if ($safeOverride) { $selected = $reqAgent }
            }
        }
        if ($isFinancial -or $isAmbiguous) {
            # financial/ambiguous never bypass deny, but agent stays deterministic
        }
        $agents.Add($selected) | Out-Null
        # skills: deterministic by task_class/task
        $wantSkills = New-Object System.Collections.Generic.List[string]
        # 2F: 'failing/fail' conta como debug (sinal de investigacao).
        if ((Test-ResolverBlobHas -Blob $blob -Words @('bug', 'debug', 'flaky', 'dificil', 'stacktrace', 'fail'))) { $wantSkills.Add('systematic-debugging') | Out-Null }
        if ((Test-ResolverBlobHas -Blob $blob -Words @('feature', 'test', 'spec', 'tdd'))) { $wantSkills.Add('test-driven-development') | Out-Null }
        if ((Test-ResolverBlobHas -Blob $blob -Words @('valid', 'done', 'final', 'review'))) { $wantSkills.Add('verification-before-completion') | Out-Null }
        if ($wantSkills.Count -eq 0) { $wantSkills.Add('verification-before-completion') | Out-Null }
        foreach ($s in $wantSkills) {
            if ($skills.Count -ge 3) { break }
            if ($skills -ccontains $s) { continue }
            $skills.Add($s) | Out-Null
        }
        # skills: somente ids ACTIVE no skills-catalog.json (fail-closed: catalogo ilegivel -> vazio)
        $activeSet = @()
        try { $activeSet = @(Get-ResolverActiveSkillIds -RepoRoot '') } catch { $activeSet = @() }
        $maxSkills = 3
        try { if ([int]$doc.skill_policy.max_skills -gt 0) { $maxSkills = [int]$doc.skill_policy.max_skills } } catch { $maxSkills = 3 }
        $filtered = New-Object System.Collections.Generic.List[string]
        foreach ($s in $skills) {
            if ($filtered.Count -ge $maxSkills) { break }
            if ($activeSet -cnotcontains $s) { continue }
            $filtered.Add($s) | Out-Null
        }
        $skills = $filtered
        # profiles + capabilities + mcps (PILOT exige prova de projeto: marker filesystem ou project.stack)
        $mcps = New-Object System.Collections.Generic.List[string]
        $needsResearch = (Test-ResolverBlobHas -Blob $blob -Words @('research', 'compare', 'benchmark'))
        if ($needsDocs -and (-not $needsResearch)) {
            if ($profiles -cnotcontains 'core') { $profiles.Add('core') | Out-Null }
            if ($mcps -cnotcontains 'context7') { $mcps.Add('context7') | Out-Null }
            if ($caps -cnotcontains 'docs.current') { $caps.Add('docs.current') | Out-Null }
        }
        if ($needsResearch) {
            if ($profiles -cnotcontains 'research') { $profiles.Add('research') | Out-Null }
            if ($mcps -cnotcontains 'jev') { $mcps.Add('jev') | Out-Null }
            if ($caps -cnotcontains 'research.external') { $caps.Add('research.external') | Out-Null }
        }
        if ($needsMemory) {
            if ($profiles -cnotcontains 'memory') { $profiles.Add('memory') | Out-Null }
            if ($mcps -cnotcontains 'ai-memory') { $mcps.Add('ai-memory') | Out-Null }
            if ($caps -cnotcontains 'memory.project-history') { $caps.Add('memory.project-history') | Out-Null }
        }
        if ($needsE2E -or $needsRuntimeDbg) {
            if ($profiles -cnotcontains 'testing') { $profiles.Add('testing') | Out-Null }
            if ($needsE2E) { if ($mcps -cnotcontains 'playwright-mcp') { $mcps.Add('playwright-mcp') | Out-Null } }
            if ($needsRuntimeDbg) { if ($mcps -cnotcontains 'chrome-devtools-mcp') { $mcps.Add('chrome-devtools-mcp') | Out-Null } }
            if ($caps -cnotcontains 'browser.automation') { $caps.Add('browser.automation') | Out-Null }
        }
        if ($needsDb) {
            if ($proofSupabase -and (-not $proofNeon)) {
                if ($profiles -cnotcontains 'database-supabase') { $profiles.Add('database-supabase') | Out-Null }
                if ($mcps -cnotcontains 'supabase-mcp') { $mcps.Add('supabase-mcp') | Out-Null }
                if ($caps -cnotcontains 'database.read') { $caps.Add('database.read') | Out-Null }
            }
            elseif ($proofNeon -and (-not $proofSupabase)) {
                if ($profiles -cnotcontains 'database-neon') { $profiles.Add('database-neon') | Out-Null }
                if ($mcps -cnotcontains 'neon-mcp') { $mcps.Add('neon-mcp') | Out-Null }
                if ($caps -cnotcontains 'database.read') { $caps.Add('database.read') | Out-Null }
            }
            else {
                if ($caps -cnotcontains 'database.read') { $caps.Add('database.read') | Out-Null }
            }
        }
        if ($caps.Count -eq 0) { $caps.Add('code.bounded-edit') | Out-Null }
        # requested capabilities: add when safe/canonical
        $canonical = @('code.bounded-edit', 'database.read', 'database.schema', 'browser.automation', 'docs.current', 'knowledge.current-documentation', 'research.external', 'memory.project-history', 'test.run', 'quality.regression')
        foreach ($c in $reqCaps) {
            if ([string]::IsNullOrWhiteSpace($c)) { continue }
            if (($canonical -ccontains $c) -and ($caps -cnotcontains $c)) { $caps.Add($c) | Out-Null }
        }
        # fallbacks from routing doc
        try {
            foreach ($f in @($doc.fallbacks)) {
                $m = Convert-ResolverNorm -Text ([string]$f.mcp)
                if ($mcps -ccontains $m) {
                    $fb = [string]$f.fallback
                    if (-not [string]::IsNullOrWhiteSpace($fb)) {
                        if ($fallbacks -cnotcontains $fb) { $fallbacks.Add($fb) | Out-Null }
                    }
                }
            }
        }
        catch { }
        # confidence (DB sem provedor provado -> AMBIGUOUS; mencao sozinha nao sugere PILOT)
        if ($isAmbiguous -or ($needsDb -and (-not $provenDb)) -or (($proofSupabase -and $proofNeon) -and $needsDb)) {
            $confidence = 'AMBIGUOUS'
        }
        else { $confidence = 'HIGH' }
        if ($confidence -ceq 'AMBIGUOUS') {
            # safe fallback: generic backend, no supabase/neon MCP
            $profiles2 = New-Object System.Collections.Generic.List[string]
            foreach ($p in $profiles) {
                if (($p -cne 'database-supabase') -and ($p -cne 'database-neon')) { $profiles2.Add($p) | Out-Null }
            }
            $profiles = $profiles2
            $mcps2 = New-Object System.Collections.Generic.List[string]
            foreach ($m in $mcps) {
                if (($m -cne 'supabase-mcp') -and ($m -cne 'neon-mcp')) { $mcps2.Add($m) | Out-Null }
            }
            $mcps = $mcps2
            if ($isAmbiguous -and ($agents.Count -gt 0) -and ($agents[0] -cne 'coder')) {
                # keep deterministic agent; ambiguous task without signal -> coder handled below
            }
            if ($isAmbiguous -and [string]::IsNullOrWhiteSpace($task)) {
                $agents.Clear()
                $agents.Add('coder') | Out-Null
            }
        }
        # pilot_profiles: subconjunto de profiles com status PILOT (forma: array paralelo; profiles segue string[])
        $pilotSet = @('database-supabase', 'database-neon', 'backend', 'frontend')
        foreach ($p in $profiles) {
            if (($pilotSet -ccontains $p) -and ($pilotProfiles -cnotcontains $p)) { $pilotProfiles.Add($p) | Out-Null }
        }
    }
    catch { }
    $aAgents = [string[]]$agents
    $aSkills = [string[]]$skills
    $aProfiles = [string[]]$profiles
    $aPilot = [string[]]$pilotProfiles
    $aCaps = [string[]]$caps
    $aCodes = [string[]]$codes
    $aFb = [string[]]$fallbacks
    $aMcps = [string[]]$mcps
    [Array]::Sort($aAgents, [System.StringComparer]::Ordinal)
    [Array]::Sort($aSkills, [System.StringComparer]::Ordinal)
    [Array]::Sort($aProfiles, [System.StringComparer]::Ordinal)
    [Array]::Sort($aPilot, [System.StringComparer]::Ordinal)
    [Array]::Sort($aCaps, [System.StringComparer]::Ordinal)
    [Array]::Sort($aCodes, [System.StringComparer]::Ordinal)
    [Array]::Sort($aFb, [System.StringComparer]::Ordinal)
    [Array]::Sort($aMcps, [System.StringComparer]::Ordinal)
    # mcps sorted too (returned inside capabilities detail via profiles? keep separate)
    return [PSCustomObject]@{
        agents         = $aAgents
        skills         = $aSkills
        profiles       = $aProfiles
        pilot_profiles = $aPilot
        mcps           = $aMcps
        capabilities = $aCaps
        permissions  = [PSCustomObject]@{ recommendation = $permRec; enforcement_authority = $permAuth }
        risk         = [PSCustomObject]@{ level = $risk }
        fallbacks    = $aFb
        reason_codes = $aCodes
        confidence   = $confidence
        mode         = 'shadow'
    }
}
