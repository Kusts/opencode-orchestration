<#!
.SYNOPSIS
    V3 Capability Activation lib: gated controlled activation (Phase 13).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Avalia o gate de
    ativacao por area (router_active, skill_routing, mcp_routing) SEM ativar
    por padrao. Fail-safe: nunca lanca; qualquer falha operacional vira
    hold com razoes concretas.

    Gate por area (TODAS as condicoes precisam passar para activate):
      G1 eval gate PASS (evidence/v3/evals/gate.json + report.json):
         correctness >= threshold, permission=0, forbidden=0, trust=0,
         authority=0, fallback=1.0, missing=0, unnecessary=0.
      G2 readiness do registry REAL (cache/v3/capability-registry.json):
         ROUTER_ACTIVE (capability_router.active) exige:
           R1 registry legivel (array capabilities presente);
           R2 registry fresco: computed_at parseavel, 0 <= idade <=
              stale_max_age_seconds (policy routing.stale_max_age_seconds,
              default 86400) e runtime_version nao vazio;
           R3 agentes available >= 5;
           R4 agentes com capabilities nao-vazias >= 5;
           R5 agentes com categories nao-vazias >= 5;
           R6 coerencia allowlist: agentes com caps precisam ja estar na
              allowlist viva (agent.build.permission.task); se faltar,
              HOLD com razao "authority change required" (NUNCA muta
              authority aqui);
           R7 zero regressao: shadow report com v3_worse=0,
              permission_violations=0 e authority_changes=0.
         SKILL_ROUTING (skill_routing.enabled) exige:
           S1 registry legivel + fresco (mesmo R1/R2);
           S2 skills available >= 10;
           S3 skills com capabilities nao-vazias >= 5;
           S4 zero regressao (mesmo R7).
          MCP_ROUTING (mcp_routing.enabled) exige HOLD INCONDICIONAL
            nesta versao: mcp_routing.enabled=false sempre, sem nenhum
            caminho de ativacao (mesmo com spike true). A decisao de
            mcp_routing e sempre 'hold' com razao de trava de versao;
            M1-M5 abaixo sao documentacao historica do gate (nao avaliados
            para activate):
            M1 registry legivel + fresco;
            M2 mcps available >= 1;
            M3 mcps com capabilities nao-vazias >= 1;
            M4 enforcement_supported == true (bool) no spike
               evidence/v3/mcp/enforcement-spike.json (hoje false);
            M5 zero regressao.
      G3 zero regressao sem evidencia de equivalencia/ganho no registry
         REAL: sem shadow Ok, NAO ativa (mantem shadow).

    MCP (mcp_routing.enabled=false) e HOLD INCONDICIONAL nesta versao:
    nenhum caminho ativa, mesmo com spike true. Authority (agent.build.permission.task)
    nunca e alterada por esta lib (somente leitura do hash para evidencia).
    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-ActivationRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-ActivationUtf8Single {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Read-ActivationJsonDoc {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 65536)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @{ Ok = $false; Doc = $null; Error = 'not-found' }
        }
        $text = Read-ActivationUtf8Single -Path $Path
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

function Get-ActivationNodeProp {
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

function Get-ActivationFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'MISSING' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    catch { return 'UNREADABLE' }
}

function Test-ActivationGate {
    [CmdletBinding()]
    param($Metrics, $Gate)
    $checks = @()
    $reasons = @()
    try {
        $t = Get-ActivationNodeProp -Node $Gate -Name 'thresholds'
        if ($null -eq $t) { $t = $Gate }
        $getNum = {
            param($Node, [string]$Field, [double]$Default)
            try {
                $v = Get-ActivationNodeProp -Node $Node -Name $Field
                if ($null -ne $v) { return [double]$v }
            }
            catch { }
            return [double]$Default
        }
        $minCorrect = & $getNum $t 'agent_selection_correctness' 0.8
        $agentRate = 0.0
        try {
            $mv = Get-ActivationNodeProp -Node $Metrics -Name 'agent_selection_correctness'
            if ($null -ne $mv) { $agentRate = [double]$mv }
        }
        catch { $agentRate = 0.0 }
        $cPass = ($agentRate -ge $minCorrect)
        $checks += [PSCustomObject]@{ name = 'agent_selection_correctness'; expected = (">={0}" -f $minCorrect); actual = $agentRate; pass = [bool]$cPass }
        if (-not $cPass) { $reasons += ('gate: agent_selection_correctness {0} abaixo do threshold {1}' -f $agentRate, $minCorrect) }
        $perm = 0; $forbid = 0; $trust = 0; $auth = 0; $fbRate = 0.0; $unnec = 0; $missing = 0
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'permission_violations'; if ($null -ne $v) { $perm = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'forbidden_capability_selection'; if ($null -ne $v) { $forbid = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'auto_trust_elevation'; if ($null -ne $v) { $trust = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'authority_escalation'; if ($null -ne $v) { $auth = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'fallback_correctness'; if ($null -ne $v) { $fbRate = [double]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'unnecessary_delegation'; if ($null -ne $v) { $unnec = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $Metrics -Name 'missing_specialist'; if ($null -ne $v) { $missing = [int]$v } } catch { }
        $row = @(
            @{ n = 'permission_violations'; e = 0; a = $perm; p = ($perm -eq 0) },
            @{ n = 'forbidden_capability_selection'; e = 0; a = $forbid; p = ($forbid -eq 0) },
            @{ n = 'auto_trust_elevation'; e = 0; a = $trust; p = ($trust -eq 0) },
            @{ n = 'authority_escalation'; e = 0; a = $auth; p = ($auth -eq 0) },
            @{ n = 'fallback_correctness'; e = 1.0; a = $fbRate; p = ($fbRate -eq 1.0) },
            @{ n = 'missing_specialist'; e = 0; a = $missing; p = ($missing -eq 0) },
            @{ n = 'unnecessary_delegation'; e = 0; a = $unnec; p = ($unnec -eq 0) }
        )
        foreach ($r in $row) {
            $checks += [PSCustomObject]@{ name = [string]$r.n; expected = $r.e; actual = $r.a; pass = [bool]$r.p }
            if (-not [bool]$r.p) { $reasons += ('gate: {0} esperado {1}, obtido {2}' -f $r.n, $r.e, $r.a) }
        }
        $allPass = $true
        foreach ($c in $checks) { if (-not [bool]$c.pass) { $allPass = $false } }
        return @{ Pass = [bool]$allPass; Checks = @($checks); Reasons = @($reasons) }
    }
    catch {
        return @{ Pass = $false; Checks = @($checks); Reasons = @('gate: erro interno contido (fail-safe)') }
    }
}

function Get-ActivationRegistryStats {
    [CmdletBinding()]
    param([string]$RegistryPath, [string]$RepoRoot, $Policy)
    try {
        $repo = Get-ActivationRepoRoot -RepoRoot $RepoRoot
        $resolved = $RegistryPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'cache\v3\capability-registry.json'
        }
        $staleMax = 86400
        try {
            $rt = Get-ActivationNodeProp -Node $Policy -Name 'routing'
            if ($null -ne $rt) {
                $sv = Get-ActivationNodeProp -Node $rt -Name 'stale_max_age_seconds'
                if ($null -ne $sv) {
                    $n = [int]$sv
                    if ($n -gt 0 -and $n -le 2592000) { $staleMax = $n }
                }
            }
        }
        catch { }
        $r = Read-ActivationJsonDoc -Path $resolved -MaxBytes 0
        if (-not $r.Ok) {
            return @{ Available = $false; Error = ('registry ' + $r.Error); StaleMax = $staleMax; Fresh = $false; FreshReason = ('registry ' + $r.Error) }
        }
        $caps = @()
        try {
            $raw = Get-ActivationNodeProp -Node $r.Doc -Name 'capabilities'
            if ($null -ne $raw) { $caps = @($raw) }
        }
        catch { $caps = @() }
        $agentsAvail = 0; $agentsCaps = 0; $agentsCats = 0
        $skillsAvail = 0; $skillsCaps = 0
        $mcpsAvail = 0; $mcpsCaps = 0
        $agentNamesWithCaps = @()
        foreach ($c in $caps) {
            try {
                $type = ([string](Get-ActivationNodeProp -Node $c -Name 'type')).Trim().ToLowerInvariant()
                $status = ([string](Get-ActivationNodeProp -Node $c -Name 'status')).Trim().ToLowerInvariant()
                $name = ([string](Get-ActivationNodeProp -Node $c -Name 'name')).Trim()
                $capList = @(Get-ActivationNodeProp -Node $c -Name 'capabilities')
                if ($capList.Count -eq 1 -and ($capList[0] -is [System.Collections.IEnumerable]) -and (-not ($capList[0] -is [string]))) {
                    try { $capList = @($capList[0]) } catch { }
                }
                $nonEmptyCaps = @($capList | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
                $catRaw = Get-ActivationNodeProp -Node $c -Name 'categories'
                $catList = @()
                if ($null -ne $catRaw) {
                    $catList = @($catRaw)
                    if ($catList.Count -eq 1 -and ($catList[0] -is [System.Collections.IEnumerable]) -and (-not ($catList[0] -is [string]))) {
                        try { $catList = @($catList[0]) } catch { }
                    }
                }
                $nonEmptyCats = @($catList | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
                if ($type -ceq 'agent' -and $status -ceq 'available') {
                    $agentsAvail++
                    if ($nonEmptyCaps -gt 0) { $agentsCaps++; if (-not [string]::IsNullOrWhiteSpace($name)) { $agentNamesWithCaps += $name } }
                    if ($nonEmptyCats -gt 0) { $agentsCats++ }
                }
                elseif ($type -ceq 'skill' -and $status -ceq 'available') {
                    $skillsAvail++
                    if ($nonEmptyCaps -gt 0) { $skillsCaps++ }
                }
                elseif ($type -ceq 'mcp' -and $status -ceq 'available') {
                    $mcpsAvail++
                    if ($nonEmptyCaps -gt 0) { $mcpsCaps++ }
                }
            }
            catch { }
        }
        $fresh = $false
        $freshReason = 'registry freshness desconhecida'
        try {
            $reg = Get-ActivationNodeProp -Node $r.Doc -Name 'registry'
            $fr = $null
            if ($null -ne $reg) { $fr = Get-ActivationNodeProp -Node $reg -Name 'freshness' }
            $computedAt = ''
            $runtimeVer = ''
            if ($null -ne $fr) {
                $ca = Get-ActivationNodeProp -Node $fr -Name 'computed_at'
                if ($null -ne $ca) { $computedAt = ([string]$ca).Trim() }
                $rv = Get-ActivationNodeProp -Node $fr -Name 'runtime_version'
                if ($null -ne $rv) { $runtimeVer = ([string]$rv).Trim() }
            }
            if ([string]::IsNullOrWhiteSpace($computedAt)) {
                $fresh = $false; $freshReason = 'registry sem computed_at (stale por definicao)'
            }
            elseif ([string]::IsNullOrWhiteSpace($runtimeVer)) {
                $fresh = $false; $freshReason = 'registry sem runtime_version (stale por definicao)'
            }
            else {
                $dt = [DateTimeOffset]::MinValue
                $ok = [DateTimeOffset]::TryParse($computedAt, [ref]$dt)
                if (-not $ok) { $fresh = $false; $freshReason = 'registry computed_at invalido (stale por definicao)' }
                else {
                    $age = ([DateTimeOffset]::UtcNow - $dt).TotalSeconds
                    if ($age -lt 0) { $fresh = $false; $freshReason = ('registry computed_at no futuro (age {0}s)' -f [int]$age) }
                    elseif ($age -gt $staleMax) { $fresh = $false; $freshReason = ('registry stale (age {0}s > max {1}s)' -f [int]$age, $staleMax) }
                    else { $fresh = $true; $freshReason = ('registry fresco (age {0}s <= max {1}s)' -f [int]$age, $staleMax) }
                }
            }
        }
        catch { $fresh = $false; $freshReason = 'registry freshness ilegivel (stale por definicao)' }
        return @{
            Available = $true; Error = ''; StaleMax = $staleMax
            Fresh = [bool]$fresh; FreshReason = [string]$freshReason
            AgentsAvailable = $agentsAvail; AgentsWithCaps = $agentsCaps; AgentsWithCategories = $agentsCats
            AgentsWithCapsNames = @($agentNamesWithCaps)
            SkillsAvailable = $skillsAvail; SkillsWithCaps = $skillsCaps
            McpsAvailable = $mcpsAvail; McpsWithCaps = $mcpsCaps
            Total = @($caps).Count
        }
    }
    catch {
        return @{ Available = $false; Error = 'registry unreadable'; StaleMax = 86400; Fresh = $false; FreshReason = 'registry unreadable' }
    }
}

function Test-ActivationSpike {
    [CmdletBinding()]
    param([string]$SpikePath, [string]$RepoRoot)
    try {
        $repo = Get-ActivationRepoRoot -RepoRoot $RepoRoot
        $resolved = $SpikePath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'evidence\v3\mcp\enforcement-spike.json'
        }
        $r = Read-ActivationJsonDoc -Path $resolved -MaxBytes 65536
        if (-not $r.Ok) { return @{ Available = $false; Supported = $false; Error = ('spike ' + $r.Error) } }
        $v = Get-ActivationNodeProp -Node $r.Doc -Name 'enforcement_supported'
        if ($v -is [bool] -and $v -eq $true) { return @{ Available = $true; Supported = $true; Error = '' } }
        return @{ Available = $true; Supported = $false; Error = '' }
    }
    catch { return @{ Available = $false; Supported = $false; Error = 'spike unreadable' } }
}

function Get-ActivationShadowView {
    [CmdletBinding()]
    param([string]$ShadowReportPath, [string]$RepoRoot)
    try {
        $repo = Get-ActivationRepoRoot -RepoRoot $RepoRoot
        $resolved = $ShadowReportPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $repo 'evidence\v3\shadow\report.json'
        }
        $r = Read-ActivationJsonDoc -Path $resolved -MaxBytes 0
        if (-not $r.Ok) { return @{ Available = $false; Ok = $false; Worse = -1; PermissionViolations = -1; AuthorityChanges = -1; Error = ('shadow ' + $r.Error) } }
        $m = Get-ActivationNodeProp -Node $r.Doc -Name 'metrics'
        if ($null -eq $m) { return @{ Available = $false; Ok = $false; Worse = -1; PermissionViolations = -1; AuthorityChanges = -1; Error = 'shadow sem metrics' } }
        $worse = -1; $perm = -1; $auth = -1
        try { $v = Get-ActivationNodeProp -Node $m -Name 'v3_worse'; if ($null -ne $v) { $worse = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $m -Name 'permission_violations'; if ($null -ne $v) { $perm = [int]$v } } catch { }
        try { $v = Get-ActivationNodeProp -Node $m -Name 'authority_changes'; if ($null -ne $v) { $auth = [int]$v } } catch { }
        if ($worse -lt 0 -or $perm -lt 0 -or $auth -lt 0) {
            return @{ Available = $true; Ok = $false; Worse = $worse; PermissionViolations = $perm; AuthorityChanges = $auth; Error = 'shadow metrics incompletas' }
        }
        $ok = (($worse -eq 0) -and ($perm -eq 0) -and ($auth -eq 0))
        return @{ Available = $true; Ok = [bool]$ok; Worse = $worse; PermissionViolations = $perm; AuthorityChanges = $auth; Error = '' }
    }
    catch { return @{ Available = $false; Ok = $false; Worse = -1; PermissionViolations = -1; AuthorityChanges = -1; Error = 'shadow unreadable' } }
}

function Get-ActivationAllowlist {
    [CmdletBinding()]
    param([string]$ConfigPath)
    try {
        $resolved = $ConfigPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        }
        $r = Read-ActivationJsonDoc -Path $resolved -MaxBytes 0
        if (-not $r.Ok) { return @{ Available = $false; AllowNames = @(); Error = ('config ' + $r.Error) } }
        $names = @()
        try {
            $agent = Get-ActivationNodeProp -Node $r.Doc -Name 'agent'
            $build = $null; $perm = $null; $task = $null
            if ($null -ne $agent) { $build = Get-ActivationNodeProp -Node $agent -Name 'build' }
            if ($null -ne $build) { $perm = Get-ActivationNodeProp -Node $build -Name 'permission' }
            if ($null -ne $perm) { $task = Get-ActivationNodeProp -Node $perm -Name 'task' }
            if ($null -ne $task) {
                if ($task -is [System.Collections.IDictionary]) {
                    foreach ($k in @($task.Keys)) {
                        try { if ([string]$task[$k] -ceq 'allow') { $names += [string]$k } } catch { }
                    }
                }
                else {
                    foreach ($pp in @($task.PSObject.Properties)) {
                        try { if ([string]$pp.Value -ceq 'allow') { $names += [string]$pp.Name } } catch { }
                    }
                }
            }
        }
        catch { }
        return @{ Available = $true; AllowNames = @($names); Error = '' }
    }
    catch { return @{ Available = $false; AllowNames = @(); Error = 'config unreadable' } }
}

function Get-ActivationDecision {
    [CmdletBinding()]
    param($GateResult, $Stats, $Spike, $Shadow, $Allowlist)
    try {
        $areas = @()
        $gatePass = $false
        try { $gatePass = [bool]$GateResult.Pass } catch { $gatePass = $false }
        $gateReasons = @()
        try { $gateReasons = @($GateResult.Reasons) } catch { $gateReasons = @() }

        $shadowOk = $false
        try { $shadowOk = [bool]$Shadow.Ok } catch { $shadowOk = $false }

        $spikeSupported = $false
        try { $spikeSupported = [bool]$Spike.Supported } catch { $spikeSupported = $false }

        # ROUTER_ACTIVE
        $rr = @()
        if (-not $gatePass) { $rr += @($gateReasons | ForEach-Object { "router_active: $_" }); if ($rr.Count -eq 0) { $rr += 'router_active: eval gate FAIL' } }
        if (-not [bool]$Stats.Available) { $rr += ('router_active: registry indisponivel (' + [string]$Stats.Error + ')') }
        else {
            if (-not [bool]$Stats.Fresh) { $rr += ('router_active: ' + [string]$Stats.FreshReason) }
            if ([int]$Stats.AgentsAvailable -lt 5) { $rr += ('router_active: agentes available insuficientes ({0} < 5)' -f [int]$Stats.AgentsAvailable) }
            if ([int]$Stats.AgentsWithCaps -lt 5) { $rr += ('router_active: agentes com capabilities vazias ({0} com caps em {1} available; registry thin)' -f [int]$Stats.AgentsWithCaps, [int]$Stats.AgentsAvailable) }
            if ([int]$Stats.AgentsWithCategories -lt 5) { $rr += ('router_active: agentes com categories vazias ({0} com categories em {1} available)' -f [int]$Stats.AgentsWithCategories, [int]$Stats.AgentsAvailable) }
            try {
                $missing = @()
                foreach ($n in @($Stats.AgentsWithCapsNames)) {
                    if (@($Allowlist.AllowNames) -cnotcontains $n) { $missing += $n }
                }
                if ($missing.Count -gt 0) { $rr += ('router_active: authority change required para allowlist ({0}); parando sem mutar authority' -f ($missing -join ',')) }
            }
            catch { }
        }
        if (-not $shadowOk) {
            $w = -1; $p = -1; $a = -1
            try { $w = [int]$Shadow.Worse } catch { }; try { $p = [int]$Shadow.PermissionViolations } catch { }; try { $a = [int]$Shadow.AuthorityChanges } catch { }
            $rr += ('router_active: sem evidencia de equivalencia/ganho no registry REAL (shadow v3_worse={0} permission={1} authority={2})' -f $w, $p, $a)
        }
        $rDec = 'hold'
        if ($rr.Count -eq 0) { $rDec = 'activate' } else { $rDec = 'hold' }
        $areas += [PSCustomObject]@{ area = 'router_active'; decision = $rDec; reasons = @($rr) }

        # SKILL_ROUTING
        $sr = @()
        if (-not $gatePass) { $sr += @($gateReasons | ForEach-Object { "skill_routing: $_" }); if ($sr.Count -eq 0) { $sr += 'skill_routing: eval gate FAIL' } }
        if (-not [bool]$Stats.Available) { $sr += ('skill_routing: registry indisponivel (' + [string]$Stats.Error + ')') }
        else {
            if (-not [bool]$Stats.Fresh) { $sr += ('skill_routing: ' + [string]$Stats.FreshReason) }
            if ([int]$Stats.SkillsAvailable -lt 10) { $sr += ('skill_routing: skills available insuficientes ({0} < 10)' -f [int]$Stats.SkillsAvailable) }
            if ([int]$Stats.SkillsWithCaps -lt 5) { $sr += ('skill_routing: skills com classes vazias ({0} com caps em {1} available; registry thin)' -f [int]$Stats.SkillsWithCaps, [int]$Stats.SkillsAvailable) }
        }
        if (-not $shadowOk) {
            $w = -1; $p = -1; $a = -1
            try { $w = [int]$Shadow.Worse } catch { }; try { $p = [int]$Shadow.PermissionViolations } catch { }; try { $a = [int]$Shadow.AuthorityChanges } catch { }
            $sr += ('skill_routing: sem evidencia de equivalencia/ganho no registry REAL (shadow v3_worse={0} permission={1} authority={2})' -f $w, $p, $a)
        }
        $sDec = 'hold'
        if ($sr.Count -eq 0) { $sDec = 'activate' } else { $sDec = 'hold' }
        $areas += [PSCustomObject]@{ area = 'skill_routing'; decision = $sDec; reasons = @($sr) }

        # MCP_ROUTING: HOLD INCONDICIONAL nesta versao. Nenhum caminho
        # ativa mcp_routing.enabled (mesmo com spike true + registry rica).
        # O gate historico M1-M5 e avaliado abaixo apenas para razoes
        # honestas; a decisao final e sempre hold por trava de versao.
        $mr = @('mcp_routing: hold incondicional nesta versao (mcp_routing.enabled=false sempre; MCP nunca ativa)')
        if (-not $gatePass) { $mr += @($gateReasons | ForEach-Object { "mcp_routing: $_" }) }
        if (-not [bool]$Stats.Available) { $mr += ('mcp_routing: registry indisponivel (' + [string]$Stats.Error + ')') }
        else {
            if (-not [bool]$Stats.Fresh) { $mr += ('mcp_routing: ' + [string]$Stats.FreshReason) }
            if ([int]$Stats.McpsAvailable -lt 1) { $mr += ('mcp_routing: nenhum MCP available ({0} < 1)' -f [int]$Stats.McpsAvailable) }
            if ([int]$Stats.McpsWithCaps -lt 1) { $mr += ('mcp_routing: MCPs com classes vazias ({0} com caps em {1} available; registry thin)' -f [int]$Stats.McpsWithCaps, [int]$Stats.McpsAvailable) }
        }
        if (-not $spikeSupported) { $mr += 'mcp_routing: enforcement_supported=false no spike (evidence/v3/mcp/enforcement-spike.json); nunca ativa sem enforcement' }
        if (-not $shadowOk) {
            $w = -1; $p = -1; $a = -1
            try { $w = [int]$Shadow.Worse } catch { }; try { $p = [int]$Shadow.PermissionViolations } catch { }; try { $a = [int]$Shadow.AuthorityChanges } catch { }
            $mr += ('mcp_routing: sem evidencia de equivalencia/ganho no registry REAL (shadow v3_worse={0} permission={1} authority={2})' -f $w, $p, $a)
        }
        $mDec = 'hold'
        # Trava dura de versao: mcp nunca ativa; razoes historicas acima sao
        # informativas (spike/registry/shadow) e a trava abaixo e redundante
        # por construcao ($mr nunca vazio).
        if ($mDec -cne 'hold') {
            $mDec = 'hold'
            $mr += 'mcp_routing: trava dura de versao (hold incondicional sobrepoe qualquer activate)'
        }
        $areas += [PSCustomObject]@{ area = 'mcp_routing'; decision = $mDec; reasons = @($mr) }

        return @($areas)
    }
    catch {
        return @(
            [PSCustomObject]@{ area = 'router_active'; decision = 'hold'; reasons = @('router_active: erro interno contido (fail-safe)') },
            [PSCustomObject]@{ area = 'skill_routing'; decision = 'hold'; reasons = @('skill_routing: erro interno contido (fail-safe)') },
            [PSCustomObject]@{ area = 'mcp_routing'; decision = 'hold'; reasons = @('mcp_routing: erro interno contido (fail-safe)') }
        )
    }
}

function Get-ActivationSafeFlagsDoc {
    [CmdletBinding()]
    param()
    return [ordered]@{
        version = 1
        capability_registry = [ordered]@{ enabled = $true }
        capability_reconciler = [ordered]@{ enabled = $false }
        capability_router = [ordered]@{ shadow = $true; active = $false }
        skill_routing = [ordered]@{ enabled = $false }
        mcp_routing = [ordered]@{ enabled = $false }
        routing_telemetry = [ordered]@{ enabled = $false; retention_days = 30 }
        adaptive_ranking = [ordered]@{ enabled = $false }
    }
}

function Update-ActivationFlagsDoc {
    [CmdletBinding()]
    param($Flags, $Areas)
    try {
        if ($null -eq $Flags) { return (Get-ActivationSafeFlagsDoc) }
        $decMap = @{}
        foreach ($a in @($Areas)) {
            try { $decMap[[string]$a.area] = [string]$a.decision } catch { }
        }
        $setBool = {
            param($Node, [string]$Field, [bool]$Value)
            try {
                if ($Node -is [System.Collections.IDictionary]) {
                    if ($Node.Contains($Field)) { $Node[$Field] = $Value }
                    else { $Node.Add($Field, $Value) }
                }
                else {
                    $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Field } | Select-Object -First 1
                    if ($null -ne $p) { $p.Value = $Value }
                    else { $Node | Add-Member -NotePropertyName $Field -NotePropertyValue $Value -Force }
                }
            }
            catch { }
        }
        $router = Get-ActivationNodeProp -Node $Flags -Name 'capability_router'
        $skill = Get-ActivationNodeProp -Node $Flags -Name 'skill_routing'
        $mcp = Get-ActivationNodeProp -Node $Flags -Name 'mcp_routing'
        if ($decMap.ContainsKey('router_active') -and ($decMap['router_active'] -ceq 'activate')) {
            if ($null -ne $router) { & $setBool $router 'active' $true }
        }
        if ($decMap.ContainsKey('skill_routing') -and ($decMap['skill_routing'] -ceq 'activate')) {
            if ($null -ne $skill) { & $setBool $skill 'enabled' $true }
        }
        # mcp_routing.enabled NUNCA e ativado por esta lib (hold
        # incondicional nesta versao): nenhum caminho escreve true aqui,
        # mesmo com decision=activate em $Areas (defesa em profundidade;
        # Get-ActivationDecision ja so emite hold para mcp_routing).
        return $Flags
    }
    catch { return $Flags }
}

function Invoke-CapabilityActivation {
    [CmdletBinding()]
    param(
        [string]$RegistryPath,
        [string]$PolicyPath,
        [string]$FlagsPath,
        [string]$GatePath,
        [string]$ReportPath,
        [string]$SpikePath,
        [string]$ShadowReportPath,
        [string]$ConfigPath,
        [string]$RepoRoot
    )
    try {
        $repo = Get-ActivationRepoRoot -RepoRoot $RepoRoot
        $res = {
            param([string]$Given, [string]$Relative)
            if (-not [string]::IsNullOrWhiteSpace($Given)) { return $Given }
            return (Join-Path $repo $Relative)
        }
        $gateFile = & $res $GatePath 'evidence\v3\evals\gate.json'
        $reportFile = & $res $ReportPath 'evidence\v3\evals\report.json'
        $regFile = & $res $RegistryPath 'cache\v3\capability-registry.json'
        $polFile = & $res $PolicyPath 'source\registry\capability-policy.json'
        $flagFile = & $res $FlagsPath 'source\registry\capability-flags.json'
        $spikeFile = & $res $SpikePath 'evidence\v3\mcp\enforcement-spike.json'
        $shadowFile = & $res $ShadowReportPath 'evidence\v3\shadow\report.json'
        $cfgFile = $ConfigPath
        if ([string]::IsNullOrWhiteSpace($cfgFile)) {
            $cfgFile = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        }

        $gateDoc = $null; $gateErr = ''
        $gr = Read-ActivationJsonDoc -Path $gateFile -MaxBytes 65536
        if ($gr.Ok) { $gateDoc = $gr.Doc } else { $gateErr = $gr.Error }

        $metrics = $null; $reportErr = ''; $reportGatePass = $null
        $rr = Read-ActivationJsonDoc -Path $reportFile -MaxBytes 0
        if ($rr.Ok) {
            $metrics = Get-ActivationNodeProp -Node $rr.Doc -Name 'metrics'
            $reportGatePass = Get-ActivationNodeProp -Node $rr.Doc -Name 'gate_pass'
        }
        else { $reportErr = $rr.Error }

        $policy = $null
        $pr = Read-ActivationJsonDoc -Path $polFile -MaxBytes 65536
        if ($pr.Ok) { $policy = $pr.Doc }

        $flags = $null; $flagsErr = ''
        $fr = Read-ActivationJsonDoc -Path $flagFile -MaxBytes 65536
        if ($fr.Ok) { $flags = $fr.Doc } else { $flagsErr = $fr.Error }

        $gateResult = $null
        if ($null -ne $gateDoc -and $null -ne $metrics) {
            $gateResult = Test-ActivationGate -Metrics $metrics -Gate $gateDoc
        }
        else {
            $rs = @()
            if ([string]::IsNullOrWhiteSpace($gateErr) -eq $false -or ($null -eq $gateDoc)) { $rs += ('gate: gate.json ' + $gateErr) }
            if ([string]::IsNullOrWhiteSpace($reportErr) -eq $false -or ($null -eq $metrics)) { $rs += ('gate: report.json ' + $reportErr) }
            if ($rs.Count -eq 0) { $rs += 'gate: gate/report indisponiveis (fail-safe)' }
            $gateResult = @{ Pass = $false; Checks = @(); Reasons = @($rs) }
        }
        # report gate_pass=false tambem e FAIL (nao confia so no recompute)
        try {
            if ($null -ne $reportGatePass -and -not ([bool]$reportGatePass)) {
                $gateResult.Pass = $false
                $extra = 'gate: report.json gate_pass=false'
                if (@($gateResult.Reasons) -cnotcontains $extra) { $gateResult.Reasons = @(@($gateResult.Reasons) + @($extra)) }
            }
        }
        catch { }

        $stats = Get-ActivationRegistryStats -RegistryPath $regFile -RepoRoot $repo -Policy $policy
        $spike = Test-ActivationSpike -SpikePath $spikeFile -RepoRoot $repo
        $shadow = Get-ActivationShadowView -ShadowReportPath $shadowFile -RepoRoot $repo
        $allow = Get-ActivationAllowlist -ConfigPath $cfgFile
        $areas = Get-ActivationDecision -GateResult $gateResult -Stats $stats -Spike $spike -Shadow $shadow -Allowlist $allow

        $opHash = Get-ActivationFileHash -Path $cfgFile
        $refs = [ordered]@{
            gate = 'evidence/v3/evals/gate.json'
            report = 'evidence/v3/evals/report.json'
            registry = 'cache/v3/capability-registry.json'
            spike = 'evidence/v3/mcp/enforcement-spike.json'
            shadow = 'evidence/v3/shadow/report.json'
            flags = 'source/registry/capability-flags.json'
        }
        return [PSCustomObject]@{
            gate_pass = [bool]$gateResult.Pass
            gate_checks = @($gateResult.Checks)
            gate_reasons = @($gateResult.Reasons)
            registry = $stats
            spike_supported = [bool]$spike.Supported
            shadow_ok = [bool]$shadow.Ok
            areas = @($areas)
            gate_refs = $refs
            flags = $flags
            flags_error = [string]$flagsErr
            authority_changes = 0
            opencode_hash = [string]$opHash
        }
    }
    catch {
        return [PSCustomObject]@{
            gate_pass = $false
            gate_checks = @()
            gate_reasons = @('activation: erro interno contido (fail-safe)')
            registry = @{ Available = $false; Error = 'internal' }
            spike_supported = $false
            shadow_ok = $false
            areas = @(
                [PSCustomObject]@{ area = 'router_active'; decision = 'hold'; reasons = @('router_active: erro interno contido (fail-safe)') },
                [PSCustomObject]@{ area = 'skill_routing'; decision = 'hold'; reasons = @('skill_routing: erro interno contido (fail-safe)') },
                [PSCustomObject]@{ area = 'mcp_routing'; decision = 'hold'; reasons = @('mcp_routing: erro interno contido (fail-safe)') }
            )
            gate_refs = [ordered]@{
                gate = 'evidence/v3/evals/gate.json'
                report = 'evidence/v3/evals/report.json'
                registry = 'cache/v3/capability-registry.json'
                spike = 'evidence/v3/mcp/enforcement-spike.json'
                shadow = 'evidence/v3/shadow/report.json'
                flags = 'source/registry/capability-flags.json'
            }
            flags = $null
            flags_error = 'internal'
            authority_changes = 0
            opencode_hash = 'UNREADABLE'
        }
    }
}
