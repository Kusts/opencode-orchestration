<#
.SYNOPSIS
    Planner model configuration tests (hermetic, no inference).
.DESCRIPTION
    Haiku is the Planner model of the `build` agent only. The global model
    (top level of opencode.json) stays Luna. These tests pin that scope across
    the canonical policy, the models example, the V1/V2 templates (rendered the
    same way install.ps1 resolves MODEL_* tokens), and the Router contract.
    Checks:
      1. Policy planner primary is claude-agent/haiku; its fallback is
         openai/gpt-6-luna and requires capability proof (no automatic fallback).
      2. models.example.jsonc planner is Haiku; a local models.jsonc, when
         present, is Haiku too (it is git-ignored, so the check is conditional).
      3. V2 and V1 templates: top-level model is the literal Luna id, not a
         Planner token; build.model resolves to Haiku.
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
Assert-PMC ([string]$planner.model_id -ceq 'claude-agent/haiku') 'pmc-policy-planner-primary-haiku'
Assert-PMC ([string]$planner.fallback_model_id -ceq 'openai/gpt-6-luna') 'pmc-policy-planner-fallback-luna'
Assert-PMC ([bool]$planner.fallback_requires_capability_proof) 'pmc-policy-fallback-requires-capability-proof'

$example = Read-JsoncFile (Join-Path $repo 'models.example.jsonc')
Assert-PMC ([string]$example.planner -ceq 'claude-agent/haiku') 'pmc-example-planner-haiku'

$localModels = Join-Path $repo 'models.jsonc'
if (Test-Path -LiteralPath $localModels -PathType Leaf) {
    $local = Read-JsoncFile $localModels
    Assert-PMC ([string]$local.planner -ceq 'claude-agent/haiku') 'pmc-local-models-planner-haiku'
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
    Assert-PMC ([string]$blocks.build.model -ceq 'claude-agent/haiku') ("pmc-$tag-build-agent-haiku")
    Assert-PMC ([string]$doc.default_agent -ceq 'build') ("pmc-$tag-default-agent-build")
    Assert-PMC ([string]$blocks.title.model -ceq 'openai/gpt-6-luna') ("pmc-$tag-title-agent-luna-not-haiku")
    $leak = @()
    foreach ($p in $blocks.PSObject.Properties) {
        if ($p.Name -ceq 'build') { continue }
        $mv = $p.Value.model
        if ($null -ne $mv -and ([string]$mv) -match 'haiku') { $leak += $p.Name }
    }
    Assert-PMC ($leak.Count -eq 0) ("pmc-$tag-no-other-agent-inherits-haiku")
}

Write-Host "RESULTS $script:pass PASS, $script:fail FAIL"
if ($script:fail -gt 0) { exit 1 }
exit 0
