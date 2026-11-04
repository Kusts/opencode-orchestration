<#
.SYNOPSIS
    Planner model configuration tests (hermetic, no inference).
.DESCRIPTION
    Haiku is the Planner model of the `build` agent only. The global model
    (top level of opencode.json) stays Luna. These tests pin that scope across
    the canonical policy, the models example, the V1/V2 templates (rendered the
    same way install.ps1 resolves MODEL_* tokens), and the Router contract.
    Checks:
      1. Policy planner primary is openai/gpt-6-luna, T2, and no model fallback
         is authorized for build.
      2. T1/T2/T3/T4 policy order is Iceman->Mimo, Muse->Haiku->Luna,
         Sonnet->Terra, Opus->Sol. Claude aliases stay runtime-unverified.
      3. models.example.jsonc and local models.jsonc keep the Planner on Luna.
      4. V2 and V1 templates: top-level model is literal Luna, build.model
         resolves to Luna, and the configured strong/frontier agents follow T3/T4.
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
Assert-PMC ([string]$planner.primary -ceq 'luna' -and [string]$planner.model_id -ceq 'openai/gpt-6-luna' -and [string]$planner.provider -ceq 'openai' -and [string]$planner.tier -ceq 'T2') 'pmc-policy-planner-primary-luna-t2'
Assert-PMC (($null -eq $planner.fallback_model_id) -and (-not [bool]$planner.fallback_requires_capability_proof)) 'pmc-policy-build-no-automatic-fallback'
Assert-PMC ([string]$policy.role_profiles.build.default_model -ceq 'luna' -and (@($policy.role_profiles.build.admissible_tiers) -contains 'T2')) 'pmc-build-role-luna-t2'
Assert-PMC (@($policy.models.claude_haiku.eligible_roles) -notcontains 'build') 'pmc-haiku-not-admissible-for-planner-build'
Assert-PMC ([string]$policy.role_profiles.'engineering-advisor'.default_model -ceq 'claude_sonnet' -and [string]$policy.role_profiles.'engineering-advisor'.default_tier -ceq 'T3') 'pmc-advisor-sonnet-t3'
Assert-PMC ([string]$policy.role_profiles.tester.default_model -ceq 'iceman' -and [string]$policy.role_profiles.tester.default_tier -ceq 'T1' -and [string]$policy.role_profiles.tester.deterministic_tier -ceq 'T0') 'pmc-tester-T0-deterministic-T1-LLM'

Assert-PMC (([string]$policy.tiers.T1.primary -ceq 'iceman') -and ([string]$policy.tiers.T1.alternatives[0] -ceq 'mimo')) 'pmc-T1-iceman-mimo-order'
Assert-PMC (([string]$policy.tiers.T2.primary -ceq 'muse') -and ([string]$policy.tiers.T2.alternatives[0] -ceq 'claude_haiku') -and ([string]$policy.tiers.T2.alternatives[1] -ceq 'luna')) 'pmc-T2-muse-haiku-luna-order'
Assert-PMC (([string]$policy.tiers.T3.primary -ceq 'claude_sonnet') -and ([string]$policy.tiers.T3.fallback -ceq 'terra')) 'pmc-T3-sonnet-terra-order'
Assert-PMC (([string]$policy.tiers.T4.primary -ceq 'claude_opus') -and ([string]$policy.tiers.T4.fallback -ceq 'sol') -and (@($policy.tiers.T4.alternatives) -notcontains 'muse') -and (@($policy.tiers.T4.alternatives) -notcontains 'deepseek_go')) 'pmc-T4-opus-sol-no-T2-transport'
foreach ($alias in @('claude_haiku','claude_sonnet','claude_opus','claude_fable')) {
    Assert-PMC ([string]$policy.models.$alias.resolution_status -ceq 'runtime-unverified') ("pmc-$alias-concrete-version-unverified")
}
Assert-PMC ((-not [bool]$policy.models.deepseek_go.enabled) -and ([string]$policy.models.deepseek_go.availability_reason -ceq 'ZDR_EXPIRED_UNCONFIRMED')) 'pmc-deepseek-ZDR-remains-blocked'

$example = Read-JsoncFile (Join-Path $repo 'models.example.jsonc')
Assert-PMC ([string]$example.planner -ceq 'openai/gpt-6-luna') 'pmc-example-planner-luna'
Assert-PMC ([string]$example.strong -ceq 'claude-agent/sonnet' -and [string]$example.frontier -ceq 'claude-agent/opus') 'pmc-example-strong-sonnet-frontier-opus'
$advisorFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\engineering-advisor.md'), [Text.Encoding]::UTF8)
$researcherFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\researcher.md'), [Text.Encoding]::UTF8)
$testerFrontmatter = [IO.File]::ReadAllText((Join-Path $repo 'source\agents\tester.md'), [Text.Encoding]::UTF8)
Assert-PMC ($advisorFrontmatter -match '(?m)^model:\s*\{\{MODEL_STRONG\}\}\s*$') 'pmc-advisor-frontmatter-uses-T3-token'
Assert-PMC ($researcherFrontmatter -match '(?m)^model:\s*\{\{MODEL_FREE\}\}\s*$') 'pmc-researcher-frontmatter-uses-T1-token'
Assert-PMC ($testerFrontmatter -match '(?m)^model:\s*\{\{MODEL_FREE\}\}\s*$') 'pmc-tester-frontmatter-uses-T1-token'

$localModels = Join-Path $repo 'models.jsonc'
if (Test-Path -LiteralPath $localModels -PathType Leaf) {
    $local = Read-JsoncFile $localModels
    Assert-PMC ([string]$local.planner -ceq 'openai/gpt-6-luna') 'pmc-local-models-planner-luna'
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
    $r = $r.Replace('{{MODEL_FREE}}', 'opencode-go/iceman-contributor-free')
    $r = $r.Replace('{{HOME}}', 'C:/Users/example')
    return $r
}

foreach ($tmpl in @('opencode.v2.json.tmpl', 'opencode.v1.json.tmpl')) {
    $tag = if ($tmpl -like '*v2*') { 'v2' } else { 'v1' }
    $raw = [IO.File]::ReadAllText((Join-Path $repo ('templates\' + $tmpl)), [Text.Encoding]::UTF8)
    Assert-PMC (-not ($raw -match '(?m)^  "model": "\{\{MODEL_PLANNER\}\}"')) ("pmc-$tag-global-model-not-planner-token")
    $doc = (Render-Template $tmpl) | ConvertFrom-Json
    $blocks = if ($null -ne $doc.agents) { $doc.agents } else { $doc.agent }
    Assert-PMC ([string]$doc.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-global-model-luna")
    Assert-PMC ([string]$blocks.build.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-build-agent-luna")
    Assert-PMC ([string]$doc.default_agent -ceq 'build') ("pmc-$tag-default-agent-build")
    Assert-PMC ([string]$blocks.title.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-title-agent-luna-not-haiku")
    Assert-PMC ([string]$blocks.researcher.model -ceq 'opencode-go/iceman-contributor-free') ("pmc-$tag-researcher-starts-T1")
    Assert-PMC ([string]$blocks.'docs-manager'.model -ceq 'opencode-go/iceman-contributor-free') ("pmc-$tag-docs-manager-starts-T1")
    Assert-PMC ([string]$blocks.explorer.model -ceq 'opencode-go/iceman-contributor-free') ("pmc-$tag-explorer-starts-T1")
    Assert-PMC ([string]$blocks.tester.model -ceq 'opencode-go/iceman-contributor-free') ("pmc-$tag-tester-LLM-default-T1")
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
