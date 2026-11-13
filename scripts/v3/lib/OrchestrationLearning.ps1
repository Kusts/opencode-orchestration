<#!
.SYNOPSIS
    Verified learning and deterministic recipes (M4, issues #177/#77).
.DESCRIPTION
    Pure functions over a Task Kernel record. Only DONE + kernel-executed
    verification + approved review (when present) can become a lesson or
    recipe. The lesson payload is Markdown for the existing AI Memory MCP;
    this library never writes memory, never calls a model and never executes
    a recipe. PS 5.1, ASCII-only.
#>
function Get-OrchestrationLearningField {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains($Name)) { return $Node[$Name] }
        return $null
    }
    $p = $Node.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-OrchestrationLearningHash {
    param([string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-OrchestrationTaskLessonEligible {
    <#
    .SYNOPSIS
        Strict gateway: only verified kernel outcomes can teach.
    .OUTPUTS
        @{ ok; reasons }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Task)
    $reasons = New-Object System.Collections.ArrayList
    try {
        $state = ([string](Get-OrchestrationLearningField -Node $Task -Name 'state')).Trim().ToUpperInvariant()
        if ($state -cne 'DONE') { [void]$reasons.Add('state-not-done') }
        $ver = Get-OrchestrationLearningField -Node $Task -Name 'verification'
        $vstatus = ([string](Get-OrchestrationLearningField -Node $ver -Name 'status')).Trim()
        $vsource = ([string](Get-OrchestrationLearningField -Node $ver -Name 'source')).Trim()
        $vsrc2 = ([string](Get-OrchestrationLearningField -Node $ver -Name 'verification_source')).Trim()
        $vexec = Get-OrchestrationLearningField -Node $ver -Name 'verifier_executed'
        $vok = Get-OrchestrationLearningField -Node $ver -Name 'verifier_ok'
        if ($vstatus -cne 'verified_pass') { [void]$reasons.Add('verification-not-passed') }
        if (($vsource -cne 'kernel-executed') -and ($vsrc2 -cne 'kernel-executed')) { [void]$reasons.Add('verification-not-kernel-executed') }
        if ($null -eq $vexec -or -not [bool]$vexec) { [void]$reasons.Add('verifier-not-executed') }
        if ($null -ne $vok -and -not [bool]$vok) { [void]$reasons.Add('verifier-not-ok') }
        $criteria = Get-OrchestrationLearningField -Node $Task -Name 'acceptance_criteria'
        if ($null -eq $criteria -or @($criteria).Count -eq 0) { [void]$reasons.Add('criteria-missing') }
        $review = Get-OrchestrationLearningField -Node $Task -Name 'review'
        if ($null -ne $review) {
            $rstatus = ([string](Get-OrchestrationLearningField -Node $review -Name 'status')).Trim()
            if ($rstatus -ne 'approved') { [void]$reasons.Add('review-not-approved') }
        }
        return @{ ok = ($reasons.Count -eq 0); reasons = @($reasons.ToArray()) }
    }
    catch { return @{ ok = $false; reasons = @('task-record-invalid') } }
}

function New-OrchestrationLessonFromTask {
    <#
    .SYNOPSIS
        Builds a verified lesson page for the existing AI Memory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Task,
        [string]$Workspace = '',
        [string]$Project = ''
    )
    try {
        $gate = Test-OrchestrationTaskLessonEligible -Task $Task
        if (-not [bool]$gate.ok) {
            return @{ ok = $false; error = 'LESSON_NOT_VERIFIED'; reasons = @($gate.reasons) }
        }
        $taskId = ([string](Get-OrchestrationLearningField -Node $Task -Name 'task_id')).Trim()
        $rev = [int](Get-OrchestrationLearningField -Node $Task -Name 'revision')
        $objective = ([string](Get-OrchestrationLearningField -Node $Task -Name 'objective')).Trim()
        $ver = Get-OrchestrationLearningField -Node $Task -Name 'verification'
        $digest = ([string](Get-OrchestrationLearningField -Node $ver -Name 'result_digest')).Trim()
        $lessonId = Get-OrchestrationLearningHash -Value ($taskId + '|' + $rev + '|' + $digest)
        $criteria = @(Get-OrchestrationLearningField -Node $Task -Name 'acceptance_criteria')
        $profiles = @(Get-OrchestrationLearningField -Node $Task -Name 'verification_profiles')
        $review = Get-OrchestrationLearningField -Node $Task -Name 'review'
        $reviewStatus = if ($null -eq $review) { 'not-required' } else { [string](Get-OrchestrationLearningField -Node $review -Name 'status') }
        $title = 'Licao verificada: ' + (($objective -replace '\s+', ' ').Trim())
        if ($title.Length -gt 120) { $title = $title.Substring(0, 117) + '...' }
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('# ' + $title)
        [void]$lines.Add('')
        [void]$lines.Add('- **Confianca:** verified (kernel-executed)')
        [void]$lines.Add('- **Task:** `' + $taskId + '` (revision ' + $rev + ')')
        if (-not [string]::IsNullOrWhiteSpace($Workspace) -or -not [string]::IsNullOrWhiteSpace($Project)) {
            [void]$lines.Add('- **Escopo:** `' + $Workspace + '/' + $Project + '`')
        }
        [void]$lines.Add('- **Verificacao:** `verified_pass` via `' + ($profiles -join ', ') + '`')
        [void]$lines.Add('- **Review:** `' + $reviewStatus + '`')
        [void]$lines.Add('')
        [void]$lines.Add('## Resultado')
        [void]$lines.Add($objective)
        [void]$lines.Add('')
        [void]$lines.Add('## Criterios verificados')
        foreach ($c in $criteria) { [void]$lines.Add('- `' + [string]$c + '`') }
        [void]$lines.Add('')
        [void]$lines.Add('## Evidencia')
        foreach ($e in @(Get-OrchestrationLearningField -Node $ver -Name 'evidence')) { [void]$lines.Add('- `' + [string]$e + '`') }
        [void]$lines.Add('')
        [void]$lines.Add('## Anti-gaming')
        [void]$lines.Add('Licao promovida somente a partir de `DONE` + verificacao kernel-executed + review aprovado. Claims de worker, `UNKNOWN`, `PARTIAL` e resultados nao verificados nao sao promovidos.')
        return @{
            ok = $true
            error = ''
            lesson_id = $lessonId
            title = $title
            markdown = ($lines -join "`n")
            confidence = 'verified'
            task_id = $taskId
            result_digest = $digest
            tags = @('lesson', 'verified', 'kernel-executed')
        }
    }
    catch { return @{ ok = $false; error = 'LESSON_BUILD_FAILED'; reasons = @() } }
}

function New-OrchestrationRecipeFromTask {
    <#
    .SYNOPSIS
        Extracts a deterministic recipe from a verified Task.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Task)
    try {
        $gate = Test-OrchestrationTaskLessonEligible -Task $Task
        if (-not [bool]$gate.ok) { return @{ ok = $false; error = 'RECIPE_NOT_VERIFIED'; reasons = @($gate.reasons) } }
        $taskId = ([string](Get-OrchestrationLearningField -Node $Task -Name 'task_id')).Trim()
        $ver = Get-OrchestrationLearningField -Node $Task -Name 'verification'
        $digest = ([string](Get-OrchestrationLearningField -Node $ver -Name 'result_digest')).Trim()
        $profiles = @(Get-OrchestrationLearningField -Node $Task -Name 'verification_profiles')
        $scopes = @(Get-OrchestrationLearningField -Node $Task -Name 'write_scopes')
        $criteria = @(Get-OrchestrationLearningField -Node $Task -Name 'acceptance_criteria')
        $env = @(Get-OrchestrationLearningField -Node $Task -Name 'environment_allowed')
        $ma = @(Get-OrchestrationLearningField -Node $Task -Name 'model_attempts')
        $deterministic = ($profiles.Count -gt 0 -and [bool](Get-OrchestrationLearningField -Node $ver -Name 'verifier_executed'))
        return @{
            ok = $true
            error = ''
            recipe_id = Get-OrchestrationLearningHash -Value ($taskId + '|' + $digest)
            task_id = $taskId
            base_revision = [string](Get-OrchestrationLearningField -Node $Task -Name 'base_revision')
            verification_profiles = $profiles
            write_scopes = $scopes
            acceptance_criteria = $criteria
            environment_allowed = $env
            deterministic = [bool]$deterministic
            original_model_attempts = $ma.Count
            result_digest = $digest
        }
    }
    catch { return @{ ok = $false; error = 'RECIPE_BUILD_FAILED' } }
}

function Test-OrchestrationRecipeReusable {
    <#
    .SYNOPSIS
        Decides whether a recipe can be replayed without model decisions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Recipe,
        [Parameter(Mandatory = $true)][string]$CurrentBaseRevision,
        [string[]]$CurrentEnvironmentAllowed = @()
    )
    try {
        if ($null -eq $Recipe -or -not [bool](Get-OrchestrationLearningField -Node $Recipe -Name 'ok')) {
            return @{ ok = $false; decision = 'INVALID'; reason = 'recipe-invalid' }
        }
        if (-not [bool](Get-OrchestrationLearningField -Node $Recipe -Name 'deterministic')) {
            return @{ ok = $true; decision = 'RECIPE_NOT_DETERMINISTIC'; reason = 'requires-model' }
        }
        $base = [string](Get-OrchestrationLearningField -Node $Recipe -Name 'base_revision')
        if ([string]::IsNullOrWhiteSpace($base) -or $base -cne $CurrentBaseRevision) {
            return @{ ok = $true; decision = 'RECIPE_STALE_BASE'; reason = 'base-revision-diverged' }
        }
        $env = @(Get-OrchestrationLearningField -Node $Recipe -Name 'environment_allowed')
        if ($env.Count -gt 0) {
            foreach ($e in $CurrentEnvironmentAllowed) {
                if ($env -notcontains $e) { return @{ ok = $true; decision = 'RECIPE_ENV_MISMATCH'; reason = 'environment-not-allowed' } }
            }
        }
        return @{ ok = $true; decision = 'REUSABLE'; reason = 'verified-and-compatible' }
    }
    catch { return @{ ok = $false; decision = 'INVALID'; reason = 'reuse-check-failed' } }
}

function Get-OrchestrationLessonQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Objective, [string]$Project = '')
    $q = ($Objective -replace '\s+', ' ').Trim()
    if ($q.Length -gt 200) { $q = $q.Substring(0, 200) }
    if (-not [string]::IsNullOrWhiteSpace($Project)) { $q = $q + ' ' + $Project.Trim() }
    return $q.Trim()
}
