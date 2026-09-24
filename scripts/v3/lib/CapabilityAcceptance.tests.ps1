$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-acceptlib-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

. (Join-Path $v3 'lib\CapabilityRouter.ps1')
. (Join-Path $v3 'lib\CapabilityAcceptance.ps1')

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

try {
    # --- Category mapping ---
    $t1 = New-RouterTask -Objective 'implementar endpoint' -TaskType 'implementation' -Domain 'backend'
    Assert-That ((Get-AcceptanceTaskCategory -Task $t1 -ExpectedAgent 'backend-engineer') -ceq 'backend') 'category: backend' 'mismatch'
    $tReview = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend'
    Assert-That ((Get-AcceptanceTaskCategory -Task $tReview -ExpectedAgent 'backend-engineer') -ceq 'review') 'category: review precedes backend domain' 'mismatch'
    $t2 = New-RouterTask -Objective 'pesquisar docs' -TaskType 'research' -Domain 'research'
    Assert-That ((Get-AcceptanceTaskCategory -Task $t2 -ExpectedAgent 'researcher') -ceq 'research') 'category: research' 'mismatch'
    $t3 = New-RouterTask -Objective 'debug bug' -TaskType 'debugging' -Domain 'debugging'
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceTaskCategory -Task $t3 -ExpectedAgent 'debugger'))) 'category: debugging out of stage1' 'not empty'
    $t4 = New-RouterTask -Objective 'arquitetar protocolo' -TaskType 'architecture' -Domain 'architecture'
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceTaskCategory -Task $t4 -ExpectedAgent 'architect'))) 'category: architecture out of stage1' 'not empty'

    # --- Hard exclusions ---
    $tSec = New-RouterTask -Objective 'revisar autenticacao e autorizacao' -TaskType 'review' -Domain 'security' -Risk 'high'
    $exSec = Get-AcceptanceHardExclusions -Task $tSec -Policy $null -ExpectedAgent 'reviewer' -RequiredCaps @('security.review') -ReadWrite ''
    Assert-That ([bool]$exSec.Excluded) 'exclusion: security sensitive' 'not excluded'
    Assert-That (@($exSec.Tokens) -ccontains 'security_sensitive') 'exclusion: security token' (@($exSec.Tokens) -join ',')
    $tAuth = New-RouterTask -Objective 'alterar allowlist e permissao de agentes' -TaskType 'planning' -Domain 'planning' -Risk 'high'
    $exAuth = Get-AcceptanceHardExclusions -Task $tAuth -Policy $null -ExpectedAgent 'coder' -RequiredCaps @() -ReadWrite ''
    Assert-That (@($exAuth.Tokens) -ccontains 'authority_change') 'exclusion: authority token' (@($exAuth.Tokens) -join ',')
    Assert-That (@($exAuth.Tokens) -ccontains 'permission_change') 'exclusion: permission token' (@($exAuth.Tokens) -join ',')
    $tDest = New-RouterTask -Objective 'migracao destrutiva do banco' -TaskType 'migration' -Domain 'database' -ReadWrite 'write'
    $exDest = Get-AcceptanceHardExclusions -Task $tDest -Policy $null -ExpectedAgent 'database-engineer' -RequiredCaps @('database.write') -ReadWrite 'write'
    Assert-That ([bool]$exDest.Excluded) 'exclusion: destructive/migration' 'not excluded'
    $tClean = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend'
    $exClean = Get-AcceptanceHardExclusions -Task $tClean -Policy $null -ExpectedAgent 'backend-engineer' -RequiredCaps @() -ReadWrite 'read'
    Assert-That (-not [bool]$exClean.Excluded) 'exclusion: clean task not excluded' (@($exClean.Tokens) -join ',')
    $tFw = New-RouterTask -Objective 'change staging firewall rules' -TaskType 'implementation' -Domain 'infra' -Risk 'high' -ReadWrite 'write'
    $exFw = Get-AcceptanceHardExclusions -Task $tFw -Policy $null -ExpectedAgent 'infra-engineer' -RequiredCaps @() -ReadWrite 'write'
    Assert-That (@($exFw.Tokens) -ccontains 'infra_mutation') 'exclusion: high-risk infra write is infra_mutation' (@($exFw.Tokens) -join ',')
    $fakeFw = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'infra-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dFw = Get-AcceptanceDecision -Task $tFw -Policy $null -Capabilities @() -Allowlist @('infra-engineer') -Fresh $true -RouterResult $fakeFw -Active $true
    Assert-That ((-not [bool]$dFw.accepted) -and ([string]$dFw.fallback_reason -ceq 'hard_exclusion_infra_mutation')) 'decision: staging firewall falls back hard_exclusion_infra_mutation' ($dFw | ConvertTo-Json -Compress)
    $tFwLow = New-RouterTask -Objective 'change staging firewall rules' -TaskType 'implementation' -Domain 'infra' -Risk 'low' -ReadWrite 'read'
    $exFwLow = Get-AcceptanceHardExclusions -Task $tFwLow -Policy $null -ExpectedAgent 'infra-engineer' -RequiredCaps @() -ReadWrite 'read'
    Assert-That (@($exFwLow.Tokens) -cnotcontains 'infra_mutation') 'exclusion: low-risk infra read is not infra_mutation (gate is risk+write, not word)' (@($exFwLow.Tokens) -join ',')
    $tFwNoWord = New-RouterTask -Objective 'rotate internal cache config' -TaskType 'implementation' -Domain 'infra' -Risk 'high' -ReadWrite 'write'
    $exFwNoWord = Get-AcceptanceHardExclusions -Task $tFwNoWord -Policy $null -ExpectedAgent 'infra-engineer' -RequiredCaps @() -ReadWrite 'write'
    Assert-That (@($exFwNoWord.Tokens) -ccontains 'infra_mutation') 'exclusion: staging word not needed for high-risk infra write gate' (@($exFwNoWord.Tokens) -join ',')

    # --- Hardening H-C: app release nao e control-plane ---
    $tRel = New-RouterTask -Objective 'fazer release da aplicacao' -TaskType 'implementation' -Domain 'backend' -ReadWrite 'write'
    $exRel = Get-AcceptanceHardExclusions -Task $tRel -Policy $null -ExpectedAgent 'backend-engineer' -RequiredCaps @('production.control') -ReadWrite 'write'
    Assert-That (@($exRel.Tokens) -cnotcontains 'control_plane') 'H-C: release (production.control) nao e control_plane' (@($exRel.Tokens) -join ',')
    $tCtl = New-RouterTask -Objective 'alterar capability-flags do router' -TaskType 'implementation' -Domain 'governance' -ReadWrite 'write'
    $exCtl = Get-AcceptanceHardExclusions -Task $tCtl -Policy $null -ExpectedAgent 'coder' -RequiredCaps @() -ReadWrite 'write'
    Assert-That (@($exCtl.Tokens) -ccontains 'control_plane') 'H-C: capability-flags continua control_plane' (@($exCtl.Tokens) -join ',')
    $tTokenizer = New-RouterTask -Objective 'otimizar o tokenizer do pipeline' -TaskType 'implementation' -Domain 'backend' -ReadWrite 'write'
    $exTok = Get-AcceptanceHardExclusions -Task $tTokenizer -Policy $null -ExpectedAgent 'infra-engineer' -RequiredCaps @() -ReadWrite 'write'
    Assert-That (@($exTok.Tokens) -cnotcontains 'credentials') 'tokenizer nao gera credentials' (@($exTok.Tokens) -join ',')

    # --- Research+backend: envelope research rejeita dono de dominio ---
    $tResBe = New-RouterTask -Objective 'pesquisar documentacao da API externa' -TaskType 'research' -Domain 'backend' -Risk 'low'
    $fakeResBe = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'backend-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dResBe = Get-AcceptanceDecision -Task $tResBe -Policy $null -Capabilities @() -Allowlist @('researcher', 'backend-engineer') -Fresh $true -RouterResult $fakeResBe -Active $true
    Assert-That ((-not [bool]$dResBe.accepted) -and ([string]$dResBe.fallback_reason -ceq 'candidate_out_of_envelope')) 'research envelope rejects domain-owner candidate (fallback, nao scoring)' ($dResBe | ConvertTo-Json -Compress)

    # --- Confidence gate ---
    Assert-That ((Get-AcceptanceConfidenceGate -ConfidenceClass 'explicit') -ceq 'strong') 'gate: explicit strong' 'x'
    Assert-That ((Get-AcceptanceConfidenceGate -ConfidenceClass 'curated') -ceq 'strong') 'gate: curated strong' 'x'
    Assert-That ((Get-AcceptanceConfidenceGate -ConfidenceClass 'inferred_high') -ceq 'acceptable') 'gate: inferred_high acceptable' 'x'
    Assert-That ((Get-AcceptanceConfidenceGate -ConfidenceClass 'inferred_low') -ceq 'insufficient') 'gate: inferred_low insufficient' 'x'
    Assert-That ((Get-AcceptanceConfidenceGate -ConfidenceClass 'unknown') -ceq 'insufficient') 'gate: unknown insufficient (never positive)' 'x'

    # --- Sanitizers ---
    Assert-That ((Get-AcceptanceTaskIdHash -TaskId 'plain-task') -match '^sha256:[0-9a-f]{16}$') 'hash: task id sha256 form' (Get-AcceptanceTaskIdHash -TaskId 'plain-task')
    Assert-That ((Get-AcceptanceTaskIdHash -TaskId 'sha256:aaaaaaaaaaaaaaaa') -ceq 'sha256:aaaaaaaaaaaaaaaa') 'hash: canonical passed through' (Get-AcceptanceTaskIdHash -TaskId 'sha256:aaaaaaaaaaaaaaaa')
    $tok = Get-AcceptanceReasonToken -Text 'algo livre com Bearer abcdefghijklmnop'
    Assert-That ($tok -match '^h:[0-9a-f]{16}$') 'token: free text hashed' $tok
    Assert-That ($tok -notmatch 'Bearer') 'token: no raw secret' $tok

    # --- Offline/active decision: inactive => deterministic router_inactive ---
    $task = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend' -Risk 'medium'
    $dInactive = Get-AcceptanceDecision -Task $task -Policy $null -Capabilities @() -Allowlist @('backend-engineer', 'reviewer') -Fresh $false -RouterResult $null -Active $false
    Assert-That (([string]$dInactive.mode -ceq 'deterministic') -and ([bool]$dInactive.fallback_used) -and ([string]$dInactive.fallback_reason -ceq 'router_inactive')) 'decision: inactive kill switch deterministic' ($dInactive | ConvertTo-Json -Compress)
    Assert-That (-not [bool]$dInactive.accepted) 'decision: inactive not accepted' 'x'
    Assert-That ([string]$dInactive.selected_agent -ceq 'reviewer') 'decision: inactive selects expected agent (work-type precedence)' ([string]$dInactive.selected_agent)

    # --- Trivial => direct ---
    $tTriv = New-RouterTask -Objective 'corrigir typo' -TaskType 'trivial' -Domain 'code' -Risk 'low'
    $dTriv = Get-AcceptanceDecision -Task $tTriv -Policy $null -Capabilities @() -Allowlist @('coder') -Fresh $false -RouterResult $null -Active $true
    Assert-That (([bool]$dTriv.direct) -and ([string]$dTriv.selected_agent -ceq 'build') -and (-not [bool]$dTriv.fallback_used)) 'decision: trivial direct build' ($dTriv | ConvertTo-Json -Compress)

    # --- Security precedence => fallback (Router never controls, even if it proposes an agent) ---
    $tSecure = New-RouterTask -Objective 'auditar autenticacao do servico' -TaskType 'review' -Domain 'security' -Risk 'high'
    $fakeRouterSec = [PSCustomObject]@{
        route         = [PSCustomObject]@{ agent = 'coder'; skills = @(); mcps = @(); direct = $false }
        fallback_used = $false
    }
    $dSecure = Get-AcceptanceDecision -Task $tSecure -Policy $null -Capabilities @() -Allowlist @('coder', 'security-reviewer') -Fresh $true -RouterResult $fakeRouterSec -Active $true
    Assert-That ((-not [bool]$dSecure.accepted) -and [bool]$dSecure.fallback_used) 'decision: security hard gate fallback' ($dSecure | ConvertTo-Json -Compress)
    Assert-That (@($dSecure.hard_gate.security_required) -contains $true) 'decision: security_required flagged' ($dSecure | ConvertTo-Json -Compress)

    # --- Envelope: candidate must belong to the category allowed agents ---
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'backend') -ccontains 'backend-engineer') 'envelope: backend allows backend-engineer' ''
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'backend') -cnotcontains 'architect') 'envelope: backend rejects architect' ''
    $tBack = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend' -Risk 'medium'
    $fakeRouterOut = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'architect'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dOut = Get-AcceptanceDecision -Task $tBack -Policy $null -Capabilities @() -Allowlist @('architect', 'backend-engineer', 'reviewer') -Fresh $true -RouterResult $fakeRouterOut -Active $true
    Assert-That ((-not [bool]$dOut.accepted) -and ([string]$dOut.fallback_reason -ceq 'candidate_out_of_envelope')) 'decision: out-of-envelope candidate rejected' ($dOut | ConvertTo-Json -Compress)

    # --- Review category must not be controlled to a domain implementer ---
    $fakeRouterRev = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'backend-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $tRevD = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend'
    $dRev = Get-AcceptanceDecision -Task $tRevD -Policy $null -Capabilities @() -Allowlist @('reviewer', 'backend-engineer') -Fresh $true -RouterResult $fakeRouterRev -Active $true
    Assert-That ((-not [bool]$dRev.accepted) -and ([string]$dRev.fallback_reason -ceq 'candidate_out_of_envelope')) 'decision: review category rejects domain implementer candidate' ($dRev | ConvertTo-Json -Compress)

    # --- Simulation seam cannot override the active envelope ---
    $tImplBe = New-RouterTask -Objective 'implementar endpoint backend' -TaskType 'implementation' -Domain 'backend'
    $fakeImplBe = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'architect'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $recArchBe = [PSCustomObject]@{
        id = 'agent:architect'; type = 'agent'; name = 'architect'; status = 'available'
        trust = 'trusted'; risk = 'low'; capabilities = @('architecture.reference'); categories = @(); tags = @('architecture')
        classification = [PSCustomObject]@{ confidence = 'explicit' }
        capability_profile = [PSCustomObject]@{ preferred = @(); forbidden = @() }
    }
    $evilEnv = @{ ExtraCategories = @('backend'); ExtraAgents = @{ 'backend' = @('architect') }; ExtraTaskMap = @{ TaskTypes = @{}; Domains = @{}; ExpectedAgents = @{} } }
    $dEvil = Get-AcceptanceDecision -Task $tImplBe -Policy $null -Capabilities @($recArchBe) -Allowlist @('architect', 'backend-engineer') -Fresh $true -RouterResult $fakeImplBe -Active $true -SimulateEnvelope $evilEnv
    Assert-That ((-not [bool]$dEvil.accepted) -and ([string]$dEvil.fallback_reason -ceq 'candidate_out_of_envelope')) 'sim: colliding envelope ignored (active backend wins)' ($dEvil | ConvertTo-Json -Compress)
    $aliasEnv = @{ ExtraCategories = @('architecture'); ExtraAgents = @{ 'architecture' = @('architect') }; ExtraTaskMap = @{ TaskTypes = @{}; Domains = @{ 'ai' = 'backend' }; ExpectedAgents = @{} } }
    $tAlias = New-RouterTask -Objective 'configurar pipeline' -TaskType 'implementation' -Domain 'ai'
    $dAlias = Get-AcceptanceDecision -Task $tAlias -Policy $null -Capabilities @($recArchBe) -Allowlist @('architect', 'infra-engineer') -Fresh $true -RouterResult $fakeImplBe -Active $true -SimulateEnvelope $aliasEnv
    Assert-That ((-not [bool]$dAlias.accepted) -and ([string]$dAlias.fallback_reason -ceq 'category_not_in_stage1')) 'sim: taskmap alias into active envelope refused' ($dAlias | ConvertTo-Json -Compress)

    # --- Security false-negative vectors must fall back (Router never controls) ---
    foreach ($secCase in @(
        @{ n = 'command-injection'; o = 'fix command injection in backend API' },
        @{ n = 'remote-code-execution'; o = 'prevent remote code execution via upload' },
        @{ n = 'path-traversal'; o = 'fix path traversal in file endpoint' }
    )) {
        $tSec2 = New-RouterTask -Objective $secCase.o -TaskType 'implementation' -Domain 'backend' -Risk 'high'
        $fakeSec = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'backend-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
        $dSec2 = Get-AcceptanceDecision -Task $tSec2 -Policy $null -Capabilities @() -Allowlist @('backend-engineer') -Fresh $true -RouterResult $fakeSec -Active $true
        Assert-That (-not [bool]$dSec2.accepted) ('decision: security vector fallback -> ' + $secCase.n) ($dSec2 | ConvertTo-Json -Compress)
    }

    # --- Positive acceptance across Stage-1 categories (valid candidate is accepted) ---
    $posCases = @(
        @{ a = 'backend-engineer'; o = 'implementar endpoint backend'; t = 'implementation'; d = 'backend' },
        @{ a = 'frontend-engineer'; o = 'implementar componente frontend'; t = 'implementation'; d = 'frontend' },
        @{ a = 'database-engineer'; o = 'analisar schema do banco'; t = 'analysis'; d = 'database' },
        @{ a = 'docs-manager'; o = 'atualizar documentacao'; t = 'documentation'; d = 'documentation' },
        @{ a = 'tester'; o = 'validar comportamento com testes'; t = 'validation'; d = 'quality' },
        @{ a = 'reviewer'; o = 'revisar pull request'; t = 'review'; d = 'quality' },
        @{ a = 'requirements-analyst'; o = 'esclarecer requisitos'; t = 'planning'; d = 'planning' },
        @{ a = 'product-designer'; o = 'desenhar fluxo de design'; t = 'design'; d = 'design' },
        @{ a = 'engineering-advisor'; o = 'avaliar viabilidade de engenharia'; t = 'analysis'; d = 'engineering' },
        @{ a = 'researcher'; o = 'pesquisar documentacao externa'; t = 'research'; d = 'research' },
        @{ a = 'explorer'; o = 'explorar codebase e impacto'; t = 'discovery'; d = 'code' }
    )
    $realPolicy = Import-RouterPolicy -PolicyPath (Join-Path $repo 'source\registry\capability-policy.json')
    foreach ($pc in $posCases) {
        $rec = [PSCustomObject]@{
            id                 = ('agent:' + $pc.a)
            type               = 'agent'
            name               = $pc.a
            status             = 'available'
            trust              = 'trusted'
            risk               = 'low'
            capabilities       = @()
            categories         = @()
            tags               = @()
            classification     = [PSCustomObject]@{ confidence = 'explicit' }
            capability_profile = [PSCustomObject]@{ preferred = @(); forbidden = @() }
        }
        $tp = New-RouterTask -Objective $pc.o -TaskType $pc.t -Domain $pc.d -Risk 'medium'
        $fr = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = $pc.a; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
        $dp = Get-AcceptanceDecision -Task $tp -Policy $realPolicy -Capabilities @($rec) -Allowlist @($pc.a) -Fresh $true -RouterResult $fr -Active $true
        Assert-That (([bool]$dp.accepted) -and ([string]$dp.selected_agent -ceq $pc.a)) ('positive acceptance: ' + $pc.a) ($dp | ConvertTo-Json -Compress)
    }

    # --- Stage 2 infra: planning/implementation accepted to infra-engineer; other task_types fall back ---
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'infra-planning') -ccontains 'infra-engineer') 'envelope: infra-planning allows infra-engineer' ''
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'infra-implementation') -ccontains 'infra-engineer') 'envelope: infra-implementation allows infra-engineer' ''
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'infra-planning') -cnotcontains 'architect') 'envelope: infra-planning rejects architect' ''
    Assert-That ((Get-AcceptanceCategoryAgents -Category 'infra-implementation') -cnotcontains 'architect') 'envelope: infra-implementation rejects architect' ''
    $recInfra = [PSCustomObject]@{
        id                 = 'agent:infra-engineer'
        type               = 'agent'
        name               = 'infra-engineer'
        status             = 'available'
        trust              = 'trusted'
        risk               = 'low'
        capabilities       = @()
        categories         = @()
        tags               = @()
        classification     = [PSCustomObject]@{ confidence = 'explicit' }
        capability_profile = [PSCustomObject]@{ preferred = @(); forbidden = @() }
    }
    $tInfraImpl = New-RouterTask -Objective 'implementar modulo de provisionamento' -TaskType 'implementation' -Domain 'infra' -Risk 'low'
    Assert-That ((Get-AcceptanceTaskCategory -Task $tInfraImpl -ExpectedAgent 'infra-engineer') -ceq 'infra-implementation') 'category: infra implementation' 'mismatch'
    $frInfraImpl = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'infra-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dInfraImpl = Get-AcceptanceDecision -Task $tInfraImpl -Policy $realPolicy -Capabilities @($recInfra) -Allowlist @('infra-engineer') -Fresh $true -RouterResult $frInfraImpl -Active $true
    Assert-That (([bool]$dInfraImpl.accepted) -and ([string]$dInfraImpl.selected_agent -ceq 'infra-engineer') -and ([string]$dInfraImpl.envelope_category -ceq 'infra-implementation')) 'positive acceptance: infra-implementation' ($dInfraImpl | ConvertTo-Json -Compress)
    $tInfraPlan = New-RouterTask -Objective 'esclarecer plano de capacidade' -TaskType 'planning' -Domain 'infra' -Risk 'low'
    Assert-That ((Get-AcceptanceTaskCategory -Task $tInfraPlan -ExpectedAgent 'infra-engineer') -ceq 'infra-planning') 'category: infra planning' 'mismatch'
    $frInfraPlan = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'infra-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dInfraPlan = Get-AcceptanceDecision -Task $tInfraPlan -Policy $realPolicy -Capabilities @($recInfra) -Allowlist @('infra-engineer') -Fresh $true -RouterResult $frInfraPlan -Active $true
    Assert-That (([bool]$dInfraPlan.accepted) -and ([string]$dInfraPlan.selected_agent -ceq 'infra-engineer') -and ([string]$dInfraPlan.envelope_category -ceq 'infra-planning')) 'positive acceptance: infra-planning' ($dInfraPlan | ConvertTo-Json -Compress)
    $tInfraRev = New-RouterTask -Objective 'revisar modulo de provisionamento' -TaskType 'review' -Domain 'infra' -Risk 'low'
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceTaskCategory -Task $tInfraRev -ExpectedAgent 'infra-engineer'))) 'category: infra review falls back (empty)' 'not empty'
    $frInfraRev = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'infra-engineer'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $dInfraRev = Get-AcceptanceDecision -Task $tInfraRev -Policy $realPolicy -Capabilities @($recInfra) -Allowlist @('infra-engineer') -Fresh $true -RouterResult $frInfraRev -Active $true
    Assert-That ((-not [bool]$dInfraRev.accepted) -and ([string]$dInfraRev.fallback_reason -ceq 'category_not_in_stage1')) 'decision: infra review falls back' ($dInfraRev | ConvertTo-Json -Compress)

    # --- Simulation seam: new-category envelope engages (positive control) ---
    $goodEnv = @{ ExtraCategories = @('architecture'); ExtraAgents = @{ 'architecture' = @('architect') }; ExtraTaskMap = @{ TaskTypes = @{ 'architecture' = 'architecture' }; Domains = @{}; ExpectedAgents = @{ 'architect' = 'architecture' } } }
    $tArchSim = New-RouterTask -Objective 'definir fronteira entre modulos' -TaskType 'architecture' -Domain 'architecture'
    $fakeArchSim = [PSCustomObject]@{ route = [PSCustomObject]@{ agent = 'architect'; skills = @(); mcps = @(); direct = $false }; fallback_used = $false }
    $recArch = [PSCustomObject]@{
        id = 'agent:architect'; type = 'agent'; name = 'architect'; status = 'available'
        trust = 'trusted'; risk = 'low'; capabilities = @('architecture.reference'); categories = @(); tags = @('architecture')
        classification = [PSCustomObject]@{ confidence = 'explicit' }
        capability_profile = [PSCustomObject]@{ preferred = @(); forbidden = @() }
    }
    $dArchSim = Get-AcceptanceDecision -Task $tArchSim -Policy $realPolicy -Capabilities @($recArch) -Allowlist @('architect') -Fresh $true -RouterResult $fakeArchSim -Active $true -SimulateEnvelope $goodEnv
    Assert-That (([bool]$dArchSim.accepted) -and ([string]$dArchSim.selected_agent -ceq 'architect')) 'sim: new-category envelope engages' ($dArchSim | ConvertTo-Json -Compress)

    # --- Fallback respects allowlist (expected not allowlisted => blocked/null) ---
    $dBlocked = Get-AcceptanceDecision -Task $tBack -Policy $null -Capabilities @() -Allowlist @('coder') -Fresh $false -RouterResult $null -Active $false
    Assert-That (([bool]$dBlocked.blocked) -and ([string]::IsNullOrWhiteSpace([string]$dBlocked.selected_agent))) 'decision: fallback blocked when expected not allowlisted' ($dBlocked | ConvertTo-Json -Compress)

    # --- Safe token drops secret-like identity values ---
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceSafeToken -Text 'sk-abcdefghijklmnop'))) 'safe token: drops sk- prefix' (Get-AcceptanceSafeToken -Text 'sk-abcdefghijklmnop')
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceSafeToken -Text 'AKIAABCDEFGHIJKLMNOP'))) 'safe token: drops AKIA prefix' (Get-AcceptanceSafeToken -Text 'AKIAABCDEFGHIJKLMNOP')
    Assert-That ([string]::IsNullOrWhiteSpace((Get-AcceptanceSafeToken -Text 'my-token-value'))) 'safe token: drops token-like' (Get-AcceptanceSafeToken -Text 'my-token-value')
    Assert-That ((Get-AcceptanceSafeToken -Text 'backend') -ceq 'backend') 'safe token: keeps normal token' (Get-AcceptanceSafeToken -Text 'backend')

    # --- Telemetry line sanitization ---
    $fakeDecision = [PSCustomObject]@{
        mode               = 'fallback'
        accepted           = $false
        fallback_used      = $true
        fallback_reason    = 'texto livre com Bearer abcdefghijklmnop'
        router_candidate   = 'backend-engineer'
        expected_agent     = 'backend-engineer'
        selected_agent     = 'backend-engineer'
        envelope_allowed   = $true
        envelope_category  = 'backend'
        envelope_exclusion = ''
        confidence_class   = 'explicit'
        disagreement       = $false
        hard_gate          = [ordered]@{ security_required = $false; authority_required = $false; destructive = $false; mcp_execution = $false }
        signals            = [ordered]@{ hard_filter_pass = $true; allowlisted = $true; available = $true; role_compatible = $true; fresh = $true }
    }
    $telTask = New-RouterTask -Objective 'revisar API backend' -TaskType 'review' -Domain 'backend' -Risk 'medium'
    $line = ConvertTo-AcceptanceTelemetry -Decision $fakeDecision -Task $telTask -TaskId 'plain-task-id' -Latency @{ registry_load_ms = 1; router_ms = 2; total_ms = 3 } -RouterResult $null
    $lineJson = ($line | ConvertTo-Json -Depth 10 -Compress)
    Assert-That ($line['task_id_hash'] -match '^sha256:[0-9a-f]{16}$') 'telemetry: task_id hashed' ([string]$line['task_id_hash'])
    Assert-That ($line['fallback_reason'] -match '^h:[0-9a-f]{16}$') 'telemetry: free reason hashed' ([string]$line['fallback_reason'])
    Assert-That ($lineJson -notmatch 'Bearer') 'telemetry: no raw secret in line' $lineJson
    Assert-That ([int]$line['latency_ms']['total_ms'] -eq 3) 'telemetry: latency carried' ($lineJson)
    $telTaskSec = New-RouterTask -Objective 'x' -TaskType 'review' -Domain 'backend'
    $telTaskSec.TaskType = 'sk-abcdefghijklmnop'
    $lineSec = ConvertTo-AcceptanceTelemetry -Decision $fakeDecision -Task $telTaskSec -TaskId 't' -Latency @{ registry_load_ms = 0; router_ms = 0; total_ms = 0 } -RouterResult $null
    $lineSecJson = ($lineSec | ConvertTo-Json -Depth 10 -Compress)
    Assert-That ([string]::IsNullOrWhiteSpace([string]$lineSec['task_type'])) 'telemetry: secret-like task_type dropped' ([string]$lineSec['task_type'])
    Assert-That ($lineSecJson -notmatch 'sk-abcdefghijklmnop') 'telemetry: secret-like task_type not persisted' $lineSecJson

    # --- Telemetry confinement / append / no BOM ---
    $allowedDir = Join-Path $repo 'cache\v3\telemetry'
    New-Item -ItemType Directory -Path $allowedDir -Force | Out-Null
    $telPath = Join-Path $allowedDir ('tmp-acceptlib-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $okWrite = Write-AcceptanceTelemetry -Line $line -TelemetryPath $telPath -RepoRoot $repo
    Assert-That ([bool]$okWrite) 'telemetry: write inside cache/v3/telemetry ok' 'write refused'
    Assert-That (Test-Path -LiteralPath $telPath -PathType Leaf) 'telemetry: file created' 'missing'
    if (Test-Path -LiteralPath $telPath -PathType Leaf) {
        $bytes = [IO.File]::ReadAllBytes($telPath)
        $bom = (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
        Assert-That (-not $bom) 'telemetry: UTF8 sem BOM' 'has BOM'
        $txt = [IO.File]::ReadAllText($telPath, [Text.UTF8Encoding]::new($false))
        Assert-That ($txt.TrimEnd("`n").EndsWith('}')) 'telemetry: JSON line appended' $txt
    }
    $outside = Join-Path $base 'fora.jsonl'
    $okOutside = Write-AcceptanceTelemetry -Line $line -TelemetryPath $outside -RepoRoot $repo
    Assert-That (-not [bool]$okOutside) 'telemetry: write outside refused' 'allowed outside'
    Assert-That (-not (Test-Path -LiteralPath $outside -PathType Leaf)) 'telemetry: no file outside' 'created outside'
    if (Test-Path -LiteralPath $telPath -PathType Leaf) { Remove-Item -LiteralPath $telPath -Force }
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}

Write-Output ''
Write-Output ('TEST RESULTS: ' + $passed + ' / ' + $total + ' passed')
if ($passed -eq $total) { exit 0 }
exit 1
