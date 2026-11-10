<#!
.SYNOPSIS
    Integracao review ancorado + reparo localizado no Task Kernel (M5).
.DESCRIPTION
    Exercita o registro de review com findings (#200) e a composicao com a
    decisao de reparo (#103). Sem rede/modelo; TasksDir temporario.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationLocalizedRepair.ps1')

$script:passed = 0
$script:failed = 0
function Assert-RI {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$flags = Join-Path $repo 'source\registry\capability-flags.json'
$tmp = Join-Path $env:TEMP ('oo-review-int-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    $create = New-OrchestrationTask -TaskId 'task-review-1' -Objective 'validar review ancorado' -TaskType 'implementation' -Risk 'low' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' -RuntimeVersion '2.2.6' -Actor 'planner' -TasksDir $tmp -FlagsPath $flags
    Assert-RI ([bool]$create.ok) '[RI1] task criada' ([string]$create.error)
    $wr = Set-OrchestrationTaskWorkerResult -TaskId 'task-review-1' -Status 'candidate_pass' -ClaimedEvidence @('test:ok') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tmp -FlagsPath $flags
    Assert-RI ([bool]$wr.ok) '[RI1] worker result registrado' ([string]$wr.error)

    $f1 = @(@{ finding_id = 'F-1'; file = 'src/components/Card.tsx'; line = 10; commit_sha = 'abcdef1'; message = 'estado vazio nao tratado'; severity = 'high' }) | ConvertTo-Json -Depth 5
    $rev = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'changes_required' -By 'reviewer' -ExpectedRevision 2 -FindingsJson $f1 -TasksDir $tmp -FlagsPath $flags
    Assert-RI ([bool]$rev.ok) '[RI2] review changes_required com finding' ([string]$rev.error)

    $task = Get-OrchestrationTask -TaskId 'task-review-1' -TasksDir $tmp -RepoRoot $repo
    $review = $task['review']
    Assert-RI ($null -ne $review) '[RI2] review persistido' ''
    Assert-RI (([int]$review['findings_count'] -eq 1)) '[RI2] findings_count=1' ([string]$review['findings_count'])
    $persisted = @($review['findings'])[0]
    Assert-RI (([string]$persisted['anchor'] -cmatch '^[0-9a-f]{64}$')) '[RI2] anchor persistido' ([string]$persisted['anchor'])
    Assert-RI (([string]$persisted['owner'] -ceq 'frontend-engineer')) '[RI2] owner roteado' ([string]$persisted['owner'])

    $approvedWithFindings = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 3 -FindingsJson $f1 -TasksDir $tmp -FlagsPath $flags
    Assert-RI ((-not [bool]$approvedWithFindings.ok) -and ([string]$approvedWithFindings.error -ceq 'REVIEW_FINDINGS_ON_APPROVED')) '[RI3] approved com findings recusado' ([string]$approvedWithFindings.error)

    $approved = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'approved' -By 'reviewer' -ExpectedRevision 3 -TasksDir $tmp -FlagsPath $flags
    Assert-RI ([bool]$approved.ok) '[RI4] approved sem findings aceito' ([string]$approved.error)

    $task2 = Get-OrchestrationTask -TaskId 'task-review-1' -TasksDir $tmp -RepoRoot $repo
    $history = @($task2['review_history'])
    Assert-RI (($history.Count -ge 1)) '[RI4] historico de review preservado' ([string]$history.Count)
    if ($history.Count -ge 1) {
        $prev = $history[$history.Count - 1]
        Assert-RI (([int]$prev['findings_count'] -eq 1)) '[RI4] finding anterior preservado no historico' ([string]$prev['findings_count'])
        Assert-RI (([string](@($prev['findings'])[0])['anchor'] -cmatch '^[0-9a-f]{64}$')) '[RI4] anchor historico intacto' ''
    }

    $bad = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'changes_required' -By 'reviewer' -ExpectedRevision 4 -FindingsJson 'nao-e-json' -TasksDir $tmp -FlagsPath $flags
    Assert-RI ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'REVIEW_FINDINGS_INVALID')) '[RI5] JSON invalido recusado' ([string]$bad.error)

    $badPath = @(@{ finding_id = 'F-2'; file = '../fora.ts'; line = 1; commit_sha = 'abcdef1'; message = 'x'; severity = 'low' }) | ConvertTo-Json -Depth 5
    $badPathRes = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'changes_required' -By 'reviewer' -ExpectedRevision 4 -FindingsJson $badPath -TasksDir $tmp -FlagsPath $flags
    Assert-RI ((-not [bool]$badPathRes.ok) -and ([string]$badPathRes.error -match 'REVIEW_FINDINGS_INVALID')) '[RI6] path invalido recusado' ([string]$badPathRes.error)

    $many = @()
    for ($i = 0; $i -lt 51; $i++) { $many += @{ finding_id = ('F-' + $i); file = 'a.ts'; line = 1; commit_sha = 'abcdef1'; message = 'x'; severity = 'low' } }
    $manyRes = Set-OrchestrationTaskReview -TaskId 'task-review-1' -Kind 'reviewer' -Status 'changes_required' -By 'reviewer' -ExpectedRevision 4 -FindingsJson ($many | ConvertTo-Json -Depth 4) -TasksDir $tmp -FlagsPath $flags
    Assert-RI ((-not [bool]$manyRes.ok) -and ([string]$manyRes.error -ceq 'REVIEW_FINDINGS_TOO_MANY')) '[RI7] limite de findings recusado' ([string]$manyRes.error)

    $local = Resolve-OrchestrationLocalizedRepair -Severity ([string]$persisted['severity']) -ChangedFiles 1 -ScopeOverlap $true -EvidenceCurrent $true -Attempts 0
    Assert-RI (([string]$local.decision -ceq 'LOCAL_REPAIR')) '[RI8] finding persistido compoe com reparo local' ([string]$local.decision)
    $stale = Resolve-OrchestrationLocalizedRepair -Severity ([string]$persisted['severity']) -ChangedFiles 1 -ScopeOverlap $true -EvidenceCurrent $false -Attempts 0
    Assert-RI (([string]$stale.decision -ceq 'REPLAN')) '[RI8] drift de evidencia impede reparo local' ([string]$stale.decision)
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('REVIEW-INTEGRATION: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
