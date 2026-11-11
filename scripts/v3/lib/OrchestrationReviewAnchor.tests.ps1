<#!
.SYNOPSIS
    Testes de ancoragem de findings de review (M5, issue #200).
.DESCRIPTION
    Funcoes puras; sem rede. PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationReviewAnchor.ps1')

$script:passed = 0
$script:failed = 0
function Assert-RA {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ('[FAIL] ' + $Name) }
        else { Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail) }
        $script:failed++
    }
}

$commit = 'abcdef1234567890abcdef1234567890abcdef12'
try {
    $f = New-OrchestrationReviewFinding -FindingId 'F-1' -File 'src/components/Card.tsx' -Line 42 -CommitSha $commit -Message 'estado vazio nao tratado' -Severity 'high' -TaskId 'task-1' -FileContent 'conteudo revisado'
    Assert-RA ([bool]$f.ok) '[RA1] finding valido construido' ([string]$f.error)
    Assert-RA (([string]$f.anchor -cmatch '^[0-9a-f]{64}$')) '[RA1] anchor sha256 presente' ([string]$f.anchor)
    Assert-RA (([string]$f.worker -ceq 'frontend-engineer')) '[RA1] owner frontend por path' ([string]$f.worker)
    Assert-RA (([string]$f.file -ceq 'src/components/Card.tsx')) '[RA1] path normalizado' ([string]$f.file)

    $f2 = New-OrchestrationReviewFinding -FindingId 'F-1' -File 'src/components/Card.tsx' -Line 42 -CommitSha $commit -Message 'estado vazio nao tratado' -Severity 'high' -FileContent 'conteudo revisado'
    Assert-RA (([string]$f2.anchor -ceq [string]$f.anchor)) '[RA2] anchor estavel para o mesmo estado' ''

    $f3 = New-OrchestrationReviewFinding -FindingId 'F-2' -File 'src/components/Card.tsx' -Line 43 -CommitSha $commit -Message 'outro' -Severity 'low'
    Assert-RA (([string]$f3.anchor -cne [string]$f.anchor)) '[RA2] linha diferente muda anchor' ''

    $badPath = New-OrchestrationReviewFinding -FindingId 'F-3' -File '../fora.ts' -CommitSha $commit -Message 'x'
    Assert-RA ((-not [bool]$badPath.ok) -and ([string]$badPath.error -ceq 'FINDING_PATH_INVALID')) '[RA3] path com .. recusado' ([string]$badPath.error)
    $absPath = New-OrchestrationReviewFinding -FindingId 'F-3' -File 'C:\fora.ts' -CommitSha $commit -Message 'x'
    Assert-RA ((-not [bool]$absPath.ok) -and ([string]$absPath.error -ceq 'FINDING_PATH_INVALID')) '[RA3] path absoluto recusado' ([string]$absPath.error)
    $badCommit = New-OrchestrationReviewFinding -FindingId 'F-3' -File 'a.ts' -CommitSha 'xyz' -Message 'x'
    Assert-RA ((-not [bool]$badCommit.ok) -and ([string]$badCommit.error -ceq 'FINDING_COMMIT_INVALID')) '[RA3] commit invalido recusado' ([string]$badCommit.error)

    $cur = Test-OrchestrationReviewAnchorCurrent -Finding $f -CurrentCommitSha $commit -FileExists $true -CurrentFileContent 'conteudo revisado'
    Assert-RA (([string]$cur.status -ceq 'CURRENT')) '[RA4] anchor atual reconhecido' ([string]$cur.status)

    $driftCommit = Test-OrchestrationReviewAnchorCurrent -Finding $f -CurrentCommitSha '1111111111111111111111111111111111111111' -FileExists $true -CurrentFileContent 'conteudo revisado'
    Assert-RA (([string]$driftCommit.status -ceq 'DRIFT_COMMIT')) '[RA5] commit divergente detectado' ([string]$driftCommit.status)

    $missing = Test-OrchestrationReviewAnchorCurrent -Finding $f -CurrentCommitSha $commit -FileExists $false
    Assert-RA (([string]$missing.status -ceq 'DRIFT_FILE_MISSING')) '[RA6] arquivo ausente detectado' ([string]$missing.status)

    $driftContent = Test-OrchestrationReviewAnchorCurrent -Finding $f -CurrentCommitSha $commit -FileExists $true -CurrentFileContent 'conteudo mudou'
    Assert-RA (([string]$driftContent.status -ceq 'DRIFT_CONTENT')) '[RA7] conteudo divergente detectado' ([string]$driftContent.status)

    Assert-RA (((Resolve-OrchestrationReviewOwner -File 'api/routes.py').owner) -ceq 'backend-engineer') '[RA8] owner backend' ''
    Assert-RA (((Resolve-OrchestrationReviewOwner -File 'migrations/001.sql').owner) -ceq 'database-engineer') '[RA8] owner database' ''
    Assert-RA (((Resolve-OrchestrationReviewOwner -File '.github/workflows/ci.yml').owner) -ceq 'infra-engineer') '[RA8] owner infra' ''
    Assert-RA (((Resolve-OrchestrationReviewOwner -File 'docs/README.md').owner) -ceq 'docs-manager') '[RA8] owner docs' ''
    Assert-RA (((Resolve-OrchestrationReviewOwner -File 'scripts/tool.ps1').owner) -ceq 'coder') '[RA8] owner default coder' ''

    $schema = Get-OrchestrationReviewFindingsSchema
    $schemaAgain = Get-OrchestrationReviewFindingsSchema
    Assert-RA ([int]$schema.schema_version -eq 1) '[RA9] schema version is 1' ([string]$schema.schema_version)
    Assert-RA (([int]$schema.max_findings -eq 50) -and ([int]$schema.max_bytes -eq 262144) -and ([int]$schema.max_message_chars -eq 2000)) '[RA9] schema limits match review bounds' ''
    Assert-RA ((@($schema.required_fields) -join ',') -ceq 'finding_id,file,commit_sha,message') '[RA9] required fields are stable' ''
    Assert-RA ((@($schema.optional_fields) -join ',') -ceq 'severity,line,task_id,worker,file_sha256') '[RA9] optional fields are stable' ''
    $exampleJson = ConvertTo-Json -InputObject @($schema.example) -Depth 8 -Compress
    $exampleParsed = ConvertFrom-Json -InputObject $exampleJson
    $exampleFields = @($exampleParsed[0].PSObject.Properties.Name)
    $exampleHasRequired = $true
    foreach ($field in @($schema.required_fields)) {
        if ($exampleFields -cnotcontains [string]$field) { $exampleHasRequired = $false }
    }
    Assert-RA ((@($exampleParsed).Count -eq 1) -and $exampleHasRequired) '[RA9] example is parseable JSON with required fields' $exampleJson
    Assert-RA ((ConvertTo-Json -InputObject $schema -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $schemaAgain -Depth 8 -Compress)) '[RA9] schema is deterministic' ''
}
finally { }

Write-Host ''
Write-Host ('REVIEW-ANCHOR: ' + $script:passed + ' passed / ' + $script:failed + ' failed')
if ($script:failed -gt 0) { exit 1 }
exit 0
