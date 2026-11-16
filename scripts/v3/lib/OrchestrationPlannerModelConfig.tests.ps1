<#
.SYNOPSIS
    Planner model configuration tests (hermetic, no inference).
.DESCRIPTION
    Planner build uses DeepSeek Go while T2 cheap uses Luna. The global model
    (top level of opencode.json) stays unchanged. These tests pin that scope across
    the canonical policy, the models example, the V1/V2 templates (rendered the
    same way install.ps1 resolves MODEL_* tokens), and the Router contract.
    Checks:
      1. Policy planner primary is opencode-go/deepseek-v4.1-flash, T2, and no model fallback
         is authorized for build.
      2. T1/T2/T3/T4 policy order is Luna->Mimo, Luna->DeepSeek Go->Muse->Haiku,
         Sonnet->Terra, Opus->Sol. Claude aliases stay runtime-unverified.
      3. models.example.jsonc and local models.jsonc map Planner to DeepSeek Go and cheap to Luna.
      4. V2 and V1 templates preserve the top-level model; build.model resolves to the Planner mapping.
      4. No template routes the global model through MODEL_PLANNER.
    Run: powershell -NoProfile -File scripts/v3/lib/OrchestrationPlannerModelConfig.tests.ps1
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

$script:pass = 0
$script:fail = 0
function Assert-PMC([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "[PASS] $Name"; $script:pass++ }
    else { Write-Host "[FAIL] $Name"; $script:fail++ }
}

function Read-JsoncFile([string]$Path) {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $lines = $raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }
    return (($lines -join "`n") | ConvertFrom-Json)
}

$policy = Get-Content -LiteralPath (Join-Path $repo 'source\registry\model-routing-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$planner = $policy.planner
Assert-PMC ([string]$planner.primary -ceq 'deepseek_go' -and [string]$planner.model_id -ceq 'opencode-go/deepseek-v4.1-flash' -and [string]$planner.provider -ceq 'opencode-go' -and [string]$planner.tier -ceq 'T2') 'pmc-policy-planner-primary-deepseek-t2'
Assert-PMC (($null -eq $planner.fallback_model_id) -and (-not [bool]$planner.fallback_requires_capability_proof)) 'pmc-policy-build-no-automatic-fallback'
Assert-PMC ([string]$policy.role_profiles.build.default_model -ceq 'deepseek_go' -and (@($policy.role_profiles.build.admissible_tiers) -contains 'T2')) 'pmc-build-role-deepseek-t2'
Assert-PMC (@($policy.models.claude_haiku.eligible_roles) -notcontains 'build') 'pmc-haiku-not-admissible-for-planner-build'
Assert-PMC ([string]$policy.role_profiles.'engineering-advisor'.default_model -ceq 'claude_sonnet' -and [string]$policy.role_profiles.'engineering-advisor'.default_tier -ceq 'T3') 'pmc-advisor-sonnet-t3'
Assert-PMC ([string]$policy.role_profiles.tester.default_model -ceq 'luna' -and [string]$policy.role_profiles.tester.default_tier -ceq 'T1' -and [string]$policy.role_profiles.tester.deterministic_tier -ceq 'T0') 'pmc-tester-T0-deterministic-T1-LLM'

Assert-PMC (([string]$policy.tiers.T1.primary -ceq 'luna') -and ([string]$policy.tiers.T1.alternatives[0] -ceq 'mimo')) 'pmc-T1-luna-mimo-order'
Assert-PMC (([string]$policy.tiers.T2.primary -ceq 'luna') -and ([string]$policy.tiers.T2.alternatives[0] -ceq 'deepseek_go') -and ([string]$policy.tiers.T2.alternatives[1] -ceq 'muse') -and ([string]$policy.tiers.T2.alternatives[2] -ceq 'claude_haiku')) 'pmc-T2-luna-deepseek_go-muse-haiku-order'
Assert-PMC (([string]$policy.tiers.T3.primary -ceq 'claude_sonnet') -and ([string]$policy.tiers.T3.fallback -ceq 'terra')) 'pmc-T3-sonnet-terra-order'
Assert-PMC (([string]$policy.tiers.T4.primary -ceq 'claude_opus') -and ([string]$policy.tiers.T4.fallback -ceq 'sol') -and (@($policy.tiers.T4.alternatives) -notcontains 'muse') -and (@($policy.tiers.T4.alternatives) -notcontains 'deepseek_go')) 'pmc-T4-opus-sol-same-tier-only-T2-recovery-described-separately'
Assert-PMC (([string]$policy.tiers.T4.description -match 'DeepSeek') -and ([string]$policy.tiers.T4.description -match 'Muse') -and ([string]$policy.tiers.T4.description -match 'audit-only')) 'pmc-T4-description-documents-audit-only-T2-recovery'
foreach ($alias in @('claude_haiku','claude_sonnet','claude_opus','claude_fable')) {
    Assert-PMC ([string]$policy.models.$alias.resolution_status -ceq 'runtime-unverified') ("pmc-$alias-concrete-version-unverified")
}
Assert-PMC (([bool]$policy.models.deepseek_go.enabled) -and ([string]$policy.models.deepseek_go.availability_status -ceq 'active') -and ([string]$policy.models.deepseek_go.data_policy.zdr_status -ceq 'expired-unconfirmed') -and ([string]$policy.models.deepseek_go.provider -ceq 'opencode-go')) 'pmc-deepseek_go-operator-enabled-active-zdr-unconfirmed'
Assert-PMC (([bool]$policy.models.deepseek_go.data_policy.sensitive_data_allowed -eq $false) -and ([string]$policy.models.deepseek_go.data_policy.zdr_note -match 'non-sensitive') -and ([string]$policy.models.deepseek_go.data_policy.zdr_note -match 'requires ZDR')) 'pmc-deepseek_go-sensitive-data-not-allowed'
Assert-PMC (([string]$policy.models.deepseek_go.model_id -like 'opencode-go/*') -and ([string]$policy.tiers.T2.primary -ceq 'luna')) 'pmc-deepseek_go-provider-namespace-opencode-go-with-luna-T2-primary'
Assert-PMC ((-not [bool]$policy.models.deepseek.enabled) -and ([string]$policy.models.deepseek.availability_status -ceq 'disabled')) 'pmc-deepseek-console-remains-disabled'

$example = Read-JsoncFile (Join-Path $repo 'models.example.jsonc')
Assert-PMC ([string]$example.planner -ceq 'opencode-go/deepseek-v4.1-flash') 'pmc-example-planner-deepseek-go'
Assert-PMC ([string]$example.cheap -ceq 'openai/gpt-6-luna') 'pmc-example-cheap-luna'
Assert-PMC ([string]$example.strong -ceq 'claude-agent/sonnet' -and [string]$example.frontier -ceq 'claude-agent/opus') 'pmc-example-strong-sonnet-frontier-opus'
$advisorFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\engineering-advisor.md'), [Text.Encoding]::UTF8)
$researcherFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\researcher.md'), [Text.Encoding]::UTF8)
$testerFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\tester.md'), [Text.Encoding]::UTF8)
Assert-PMC ($advisorFrontmatter -match '(?m)^model:\s*\{\{MODEL_STRONG\}\}\s*$') 'pmc-advisor-frontmatter-uses-T3-token'
Assert-PMC ($researcherFrontmatter -match '(?m)^model:\s*\{\{MODEL_FREE\}\}\s*$') 'pmc-researcher-frontmatter-uses-T1-token'
Assert-PMC ($testerFrontmatter -match '(?m)^model:\s*\{\{MODEL_FREE\}\}\s*$') 'pmc-tester-frontmatter-uses-T1-token'

# Adaptive adapter documentation: the free pool is T1 and the cheap block never
# lists T1 roles (explorer/researcher/tester/docs-manager). Each block must own
# only its token (free -> MODEL_FREE, cheap -> MODEL_CHEAP).
foreach ($adapter in @(
    @{ Tag = 'v1'; Path = 'source\adapters\opencode.md' },
    @{ Tag = 'v2'; Path = 'source\adapters\opencode-v2.md' }
)) {
    $adapterText = [IO.File]::ReadAllText((Join-Path $repo $adapter.Path), [Text.Encoding]::UTF8)
    Assert-PMC ($adapterText -match 'Free worker pool') ("pmc-$($adapter.Tag)-adapter-documents-free-worker-pool")

    $cheapMatch = [regex]::Match($adapterText, '(?s)- Cheap worker pool.*?(?=\r?\n- |\z)')
    $cheapBlock = if ($cheapMatch.Success) { $cheapMatch.Value } else { '' }
    Assert-PMC ($cheapBlock.Length -gt 0 -and $cheapBlock.Contains('{{MODEL_CHEAP}}') -and -not $cheapBlock.Contains('{{MODEL_FREE}}')) ("pmc-$($adapter.Tag)-adapter-cheap-block-only-cheap-token")
    Assert-PMC ($cheapBlock.Length -gt 0 -and -not ($cheapBlock -match '\b(explorer|researcher|tester|docs-manager)\b')) ("pmc-$($adapter.Tag)-adapter-cheap-block-excludes-T1-roles")

    $freeMatch = [regex]::Match($adapterText, '(?s)- Free worker pool.*?(?=\r?\n- |\z)')
    $freeBlock = if ($freeMatch.Success) { $freeMatch.Value } else { '' }
    Assert-PMC ($freeBlock.Length -gt 0 -and $freeBlock.Contains('{{MODEL_FREE}}') -and -not $freeBlock.Contains('{{MODEL_CHEAP}}')) ("pmc-$($adapter.Tag)-adapter-free-block-only-free-token")
    $missingFreeRoles = @(@('explorer','researcher','tester','docs-manager') | Where-Object { $freeBlock -notmatch ('\b' + [regex]::Escape($_) + '\b') })
    Assert-PMC ($freeBlock.Length -gt 0 -and $missingFreeRoles.Count -eq 0) ("pmc-$($adapter.Tag)-adapter-free-block-lists-T1-roles")
    Assert-PMC ($freeBlock.Length -gt 0 -and -not ($freeBlock -match '\b(coder|frontend-engineer|backend-engineer|database-engineer|ai-agent-engineer|automation-engineer|infra-engineer)\b')) ("pmc-$($adapter.Tag)-adapter-free-block-excludes-cheap-roles")
}

$localModels = Join-Path $repo 'models.jsonc'
if (Test-Path -LiteralPath $localModels -PathType Leaf) {
    $local = Read-JsoncFile $localModels
    Assert-PMC ([string]$local.planner -ceq 'opencode-go/deepseek-v4.1-flash') 'pmc-local-models-planner-deepseek-go'
    Assert-PMC ([string]$local.cheap -ceq 'openai/gpt-6-luna') 'pmc-local-models-cheap-luna'
    Assert-PMC ([string]$local.strong -ceq 'claude-agent/sonnet' -and [string]$local.frontier -ceq 'claude-agent/opus') 'pmc-local-models-strong-sonnet-frontier-opus'
} else {
    Write-Host '[SKIP] pmc-local-models-planner-haiku (models.jsonc absent; git-ignored)'
}

# Render the templates the way install.ps1 resolves MODEL_* tokens (planner from example).
function Render-Template([string]$Name) {
    $raw = [IO.File]::ReadAllText((Join-Path $repo ('templates\' + $Name)), [Text.Encoding]::UTF8)
    $r = $raw.Replace('{{MODEL_PLANNER}}', [string]$example.planner)
    $r = $r.Replace('{{MODEL_CHEAP}}', [string]$example.cheap)
    $r = $r.Replace('{{MODEL_STRONG}}', [string]$example.strong)
    $r = $r.Replace('{{MODEL_FREE}}', 'openai/gpt-6-luna')
    $r = $r.Replace('{{HOME}}', 'C:/Users/example')
    return $r
}

foreach ($tmpl in @('opencode.v2.json.tmpl', 'opencode.v1.json.tmpl')) {
    $tag = if ($tmpl -like '*v2*') { 'v2' } else { 'v1' }
    $raw = [IO.File]::ReadAllText((Join-Path $repo ('templates\' + $tmpl)), [Text.Encoding]::UTF8)
    Assert-PMC (-not ($raw -match '(?m)^  "model": "\{\{MODEL_PLANNER\}\}"')) ("pmc-$tag-global-model-not-planner-token")
    $doc = (Render-Template $tmpl) | ConvertFrom-Json
    $blocks = if ($null -ne $doc.agents) { $doc.agents } else { $doc.agent }
    Assert-PMC ([string]$doc.model -ceq 'opencode-go/deepseek-v4.1-flash') ("pmc-$tag-global-model-deepseek-go")
    Assert-PMC ([string]$blocks.build.model -ceq 'opencode-go/deepseek-v4.1-flash') ("pmc-$tag-build-agent-deepseek-go")
    Assert-PMC ([string]$doc.default_agent -ceq 'build') ("pmc-$tag-default-agent-build")
    Assert-PMC ([string]$blocks.title.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-title-agent-luna-not-haiku")
    Assert-PMC ([string]$blocks.coder.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-T2-coder-luna")
    Assert-PMC ([string]$blocks.'frontend-engineer'.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-T2-engineering-agent-luna")
    Assert-PMC ([string]$blocks.researcher.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-researcher-starts-T1")
    Assert-PMC ([string]$blocks.'docs-manager'.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-docs-manager-starts-T1")
    Assert-PMC ([string]$blocks.explorer.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-explorer-starts-T1")
    Assert-PMC ([string]$blocks.tester.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-tester-LLM-default-T1")
    if ($null -ne $blocks.PSObject.Properties['engineering-advisor']) {
        Assert-PMC ([string]$blocks.'engineering-advisor'.model -ceq 'claude-agent/sonnet') ("pmc-$tag-advisor-sonnet-T3")
    }
    $leak = @()
    foreach ($p in $blocks.PSObject.Properties) {
        if ($p.Name -ceq 'build') { continue }
        $mv = $p.Value.model
        if ($null -ne $mv -and ([string]$mv -match 'haiku')) { $leak += $p.Name }
    }
    Assert-PMC ($leak.Count -eq 0) ("pmc-$tag-no-other-agent-inherits-haiku")
}

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
