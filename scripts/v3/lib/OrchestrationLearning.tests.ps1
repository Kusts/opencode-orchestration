<#!
.SYNOPSIS
    Testes de aprendizado verificado e receitas determinísticas (M4 #177/#77).
.DESCRIPTION
    Funcoes puras; sem rede, sem modelo, sem escrita. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationLearning.ps1')

$script:passed = 0
$script:failed = 0
function Assert-LN {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}
function New-TaskFixture {
    return [ordered]@{
        task_id              = 'task-learn-1'
        revision             = 9
        state                = 'DONE'
        objective            = 'Implementar ratio com casos nulos e denominador zero'
        acceptance_criteria  = @('criterion:0')
        verification_profiles = @('criterion-smoke')
        write_scopes         = @('scratchpad/m5-e2e')
        environment_allowed  = @('local')
        base_revision        = 'acc13b2'
        model_attempts       = @(@{ model = 'gpt-6-luna' }, @{ model = 'claude-agent/sonnet' })
        verification         = [ordered]@{
            status              = 'verified_pass'
            source              = 'kernel-executed'
            verification_source = 'kernel-executed'
            verifier_executed   = $true
            verifier_ok         = $true
            result_digest       = 'sha256:abc123'
            evidence            = @('criterion:0:verified')
        }
        review               = [ordered]@{ status = 'approved' }
    }
}

try {
    $t = New-TaskFixture
    $gate = Test-OrchestrationTaskLessonEligible -Task $t
    Assert-LN ([bool]$gate.ok) '[LN1] Task DONE kernel-executed elegivel' ([string]($gate.reasons -join ','))

    $lesson = New-OrchestrationLessonFromTask -Task $t -Workspace 'ferramentas' -Project 'opencode-orchestration'
    Assert-LN ([bool]$lesson.ok) '[LN2] licao construida' ([string]$lesson.error)
    Assert-LN (([string]$lesson.lesson_id -cmatch '^[0-9a-f]{64}$')) '[LN2] lesson_id sha256' ([string]$lesson.lesson_id)
    Assert-LN (([string]$lesson.markdown -match '^# Licao verificada:')) '[LN2] markdown com H1' ''
    Assert-LN (([string]$lesson.markdown -match 'Anti-gaming')) '[LN2] anti-gaming documentado' ''
    Assert-LN (([string]$lesson.confidence -ceq 'verified')) '[LN2] confianca verified' ([string]$lesson.confidence)

    $recipe = New-OrchestrationRecipeFromTask -Task $t
    Assert-LN ([bool]$recipe.ok) '[LN3] receita construida' ([string]$recipe.error)
    Assert-LN ([bool]$recipe.deterministic) '[LN3] receita deterministica' ([string]$recipe.deterministic)
    Assert-LN (([int]$recipe.original_model_attempts -eq 2)) '[LN3] chamadas originais contadas' ([string]$recipe.original_model_attempts)

    $reuse = Test-OrchestrationRecipeReusable -Recipe $recipe -CurrentBaseRevision 'acc13b2' -CurrentEnvironmentAllowed @('local')
    Assert-LN (([string]$reuse.decision -ceq 'REUSABLE')) '[LN4] mesma base/ambiente reutiliza' ([string]$reuse.decision)
    $stale = Test-OrchestrationRecipeReusable -Recipe $recipe -CurrentBaseRevision 'deadbee' -CurrentEnvironmentAllowed @('local')
    Assert-LN (([string]$stale.decision -ceq 'RECIPE_STALE_BASE')) '[LN5] base divergente exige revalidacao' ([string]$stale.decision)
    $envBad = Test-OrchestrationRecipeReusable -Recipe $recipe -CurrentBaseRevision 'acc13b2' -CurrentEnvironmentAllowed @('prod')
    Assert-LN (([string]$envBad.decision -ceq 'RECIPE_ENV_MISMATCH')) '[LN6] ambiente divergente recusado' ([string]$envBad.decision)

    $notDone = New-TaskFixture
    $notDone['state'] = 'IMPLEMENTING'
    $g1 = Test-OrchestrationTaskLessonEligible -Task $notDone
    Assert-LN ((-not [bool]$g1.ok) -and (@($g1.reasons) -contains 'state-not-done')) '[LN7] task nao-DONE recusada' ([string]($g1.reasons -join ','))

    $caller = New-TaskFixture
    $caller['verification']['source'] = 'caller-supplied'
    $caller['verification']['verification_source'] = 'caller-supplied'
    $g2 = Test-OrchestrationTaskLessonEligible -Task $caller
    Assert-LN ((-not [bool]$g2.ok) -and (@($g2.reasons) -contains 'verification-not-kernel-executed')) '[LN8] verificacao nao-kernel recusada' ([string]($g2.reasons -join ','))

    $failedTask = New-TaskFixture
    $failedTask['verification']['status'] = 'verification_failed'
    $g3 = Test-OrchestrationTaskLessonEligible -Task $failedTask
    Assert-LN ((-not [bool]$g3.ok) -and (@($g3.reasons) -contains 'verification-not-passed')) '[LN9] verificacao falha recusada' ([string]($g3.reasons -join ','))

    $changes = New-TaskFixture
    $changes['review']['status'] = 'changes_required'
    $g4 = Test-OrchestrationTaskLessonEligible -Task $changes
    Assert-LN ((-not [bool]$g4.ok) -and (@($g4.reasons) -contains 'review-not-approved')) '[LN10] review changes_required recusado' ([string]($g4.reasons -join ','))

    $noCriteria = New-TaskFixture
    $noCriteria['acceptance_criteria'] = @()
    $g5 = Test-OrchestrationTaskLessonEligible -Task $noCriteria
    Assert-LN ((-not [bool]$g5.ok) -and (@($g5.reasons) -contains 'criteria-missing')) '[LN11] sem criterio recusado' ([string]($g5.reasons -join ','))

    $noProfiles = New-TaskFixture
    $noProfiles['verification_profiles'] = @()
    $r2 = New-OrchestrationRecipeFromTask -Task $noProfiles
    Assert-LN ([bool]$r2.ok -and (-not [bool]$r2.deterministic)) '[LN12] sem perfil nao e deterministica' ([string]$r2.deterministic)
    $r2reuse = Test-OrchestrationRecipeReusable -Recipe $r2 -CurrentBaseRevision 'acc13b2'
    Assert-LN (([string]$r2reuse.decision -ceq 'RECIPE_NOT_DETERMINISTIC')) '[LN12] reuso exige modelo' ([string]$r2reuse.decision)

    $q = Get-OrchestrationLessonQuery -Objective 'Implementar ratio com casos nulos' -Project 'opencode-orchestration'
    Assert-LN (([string]$q -match 'ratio') -and ([string]$q -match 'opencode-orchestration')) '[LN13] query de recuperacao construida' ([string]$q)
}
finally { }

Write-Host ''
Write-Host ('LEARNING: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0

