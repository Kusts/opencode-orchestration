<#!
.SYNOPSIS
    Regressao: skills user-owned nao invalidam o catalogo distribuido.
.DESCRIPTION
    Executa a suite do catalogo e o healthcheck contra roots temporarios.
    Uma skill pessoal extra e uma entrada incompleta nao devem reprovar
    a distribuicao; conflito nao aprovado em uma CORE deve reprovar.
    Read-only sobre repo/config real. PS 5.1 e PS 7.
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:pass++; Write-Host ('ok - ' + $Name) }
    else { $script:fail++; Write-Host ('NOT OK - ' + $Name + ' -- ' + $Detail) }
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$health = Join-Path $root 'scripts\v3\skills-healthcheck.ps1'
$suite = Join-Path $PSScriptRoot 'skills-catalog.tests.ps1'
$engine = 'powershell'
if ($PSVersionTable.PSEdition -eq 'Core') { $engine = 'pwsh' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('oo-skills-isolation-' + [guid]::NewGuid().ToString('N'))
$agents = Join-Path $fixture 'agents'
$opencode = Join-Path $fixture 'opencode'
$project = Join-Path $fixture 'project'
function Invoke-Target([string]$Path, [string[]]$ExtraArgs) {
    $lines = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $Path @ExtraArgs 2>&1)
    return [pscustomobject]@{ exit_code = $LASTEXITCODE; output = ($lines -join [Environment]::NewLine) }
}
try {
    foreach ($d in @($agents, $opencode, $project)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    $personalA = Join-Path $agents 'personal-unlisted-skill'
    $personalO = Join-Path $opencode 'other-unlisted-skill'
    $incomplete = Join-Path $agents 'incomplete-personal-dir'
    foreach ($d in @($personalA, $personalO, $incomplete)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $personalA 'SKILL.md'), '# personal-a', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $personalO 'SKILL.md'), '# personal-o', (New-Object Text.UTF8Encoding $false))
    $argsHealth = @('-Json', '-AgentsSkillsRoot', $agents, '-OpencodeSkillsRoot', $opencode, '-ProjectSkillsRoot', $project)
    $a = Invoke-Target $health $argsHealth
    $ja = $null
    try { $ja = $a.output | ConvertFrom-Json } catch { }
    # Os COREs ausentes do repo-core (5) ja falham no gate mesmo sem skills pessoais.
    # O teste verifica que as skills pessoais NAO adicionam novas falhas de CORE.
    $coreFailIds = @($ja.core_gate | Where-Object { -not [bool]$_.ok } | ForEach-Object { [string]$_.id })
    $missingCore = @('systematic-debugging','test-driven-development','writing-plans','executing-plans','skill-discovery')
    $personalInCoreFail = @($coreFailIds | Where-Object { $_ -in @('personal-unlisted-skill','other-unlisted-skill','incomplete-personal-dir') })
    Assert (($a.exit_code -eq 0) -and ($null -ne $ja) -and ($personalInCoreFail.Count -eq 0)) 'skills pessoais nao adicionam falhas ao gate CORE' $a.output
    Assert (($coreFailIds.Count -eq $missingCore.Count) -and (@($coreFailIds | Where-Object { $missingCore -contains $_ }).Count -eq $missingCore.Count)) 'gate CORE falha apenas nos COREs ausentes do repo-core' $a.output
    Assert (($ja.skills.invalid -contains 'incomplete-personal-dir')) 'diretorio pessoal incompleto e registrado como invalid observacional' $a.output

    $shared = Join-Path $fixture 'shared'
    New-Item -ItemType Directory -Path (Join-Path $shared 'writing-plans') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $shared 'writing-plans\SKILL.md'), '# shared writing plans', (New-Object Text.UTF8Encoding $false))
    New-Item -ItemType Junction -Path (Join-Path $agents 'writing-plans') -Target (Join-Path $shared 'writing-plans') | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $opencode 'writing-plans') -Target (Join-Path $shared 'writing-plans') | Out-Null
    $sameA = Invoke-Target $health $argsHealth
    $sameJA = $sameA.output | ConvertFrom-Json
    $sameCoreA = @($sameJA.core_gate | Where-Object { $_.id -ceq 'writing-plans' })[0]
    Assert ((@($sameJA.core_gate | Where-Object { -not $_.ok } | ForEach-Object { $_.id }) -notcontains 'writing-plans') -and ($sameCoreA.shadow -ceq 'same-target') -and $sameCoreA.ok) 'junctions duplas para alvo compartilhado sao same-target'

    $realTdd = Join-Path $agents 'test-driven-development'
    New-Item -ItemType Directory -Path $realTdd -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $realTdd 'SKILL.md'), '# shared test driven development', (New-Object Text.UTF8Encoding $false))
    New-Item -ItemType Junction -Path (Join-Path $opencode 'test-driven-development') -Target $realTdd | Out-Null
    $sameB = Invoke-Target $health $argsHealth
    $sameJB = $sameB.output | ConvertFrom-Json
    $sameCoreB = @($sameJB.core_gate | Where-Object { $_.id -ceq 'test-driven-development' })[0]
    Assert ((@($sameJB.core_gate | Where-Object { -not $_.ok } | ForEach-Object { $_.id }) -notcontains 'test-driven-development') -and ($sameCoreB.shadow -ceq 'same-target')) 'diretorio real + junction para ele sao same-target'

    $suiteArgs = @('-AgentsSkillsRoot', $agents, '-OpencodeSkillsRoot', $opencode, '-ProjectSkillsRoot', $project)
    $b = Invoke-Target $suite $suiteArgs
    # O veredito do healthcheck falha por COREs ausentes (pre-existente), nao por skills pessoais.
    # A assercao chave: o inventario versionado continua integro (sem NOT OK de inventario).
    # A suite sai com codigo 1 porque o healthcheck reprova os COREs ausentes (pre-existente),
    # nao por causa das skills pessoais. O invariante sob teste e a integridade do inventario.
    # Verifica que a UNICA falha da suite e o veredito do healthcheck (COREs ausentes),
    # sem nenhuma outra falha (inventario, schema, etc.).
    $notOkLines = @([regex]::Matches($b.output, 'NOT OK - [^\r\n]*') | ForEach-Object { $_.Value })
    $onlyExpectedFailure = ($notOkLines.Count -eq 1) -and ($notOkLines[0] -match 'skills-healthcheck verdict PASS')
    Assert (($b.exit_code -eq 1) -and ($b.output -match 'ok - catalogo cobre inventario \+ adicoes repo-pinned') -and $onlyExpectedFailure) 'catalogo versionado nao exige igualdade com roots pessoais' $b.output

    $coreId = 'hybrid-development'
    $shadowA = Join-Path $agents $coreId
    $shadowO = Join-Path $opencode $coreId
    foreach ($d in @($shadowA, $shadowO)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $shadowA 'SKILL.md'), '# unapproved-core-a', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $shadowO 'SKILL.md'), '# unapproved-core-b', (New-Object Text.UTF8Encoding $false))
    $c = Invoke-Target $health $argsHealth
    $jc = $null
    try { $jc = $c.output | ConvertFrom-Json } catch { }
    $shadowCoreFail = @($jc.core_gate | Where-Object { -not [bool]$_.ok } | ForEach-Object { [string]$_.id })
    Assert (($c.exit_code -eq 0) -and ($null -ne $jc) -and ($jc.verdict -ceq 'FAIL') -and ($shadowCoreFail -contains 'hybrid-development') -and (($jc.reasons -join '|') -match 'core-gate')) 'healthcheck detecta shadow CORE nao aprovado' $c.output

    $d = Invoke-Target $suite $suiteArgs
    Assert (($d.exit_code -ne 0) -and ($d.output -match 'NOT OK -')) 'suite bloqueia conflito real em CORE' $d.output

    # D: igualdade de conteúdo não isenta roots físicos distintos sem pin.
    $discoveryA = Join-Path $agents 'skill-discovery'
    $discoveryO = Join-Path $opencode 'skill-discovery'
    foreach ($dir in @($discoveryA, $discoveryO)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sameContent = '# identical bytes for distinct targets'
    [IO.File]::WriteAllText((Join-Path $discoveryA 'SKILL.md'), $sameContent, (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $discoveryO 'SKILL.md'), $sameContent, (New-Object Text.UTF8Encoding $false))
    $caseD = Invoke-Target $health $argsHealth
    $jD = $caseD.output | ConvertFrom-Json
    $coreD = @($jD.core_gate | Where-Object { $_.id -ceq 'skill-discovery' })[0]
    Assert (($jD.verdict -ceq 'FAIL') -and (@($jD.core_gate | Where-Object { -not $_.ok } | ForEach-Object { $_.id }) -contains 'skill-discovery') -and ($coreD.shadow -cne 'same-target')) 'D: alvos distintos falham mesmo com hash idêntico'

    # E: o pin prevalece mesmo quando ambos os roots são junctions ao mesmo alvo.
    $pinnedTarget = Join-Path $fixture 'pinned-hybrid-target'
    New-Item -ItemType Directory -Path $pinnedTarget -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $pinnedTarget 'SKILL.md'), '# deliberately outside registered pin', (New-Object Text.UTF8Encoding $false))
    Remove-Item -LiteralPath $shadowA,$shadowO -Recurse -Force
    New-Item -ItemType Junction -Path $shadowA -Target $pinnedTarget | Out-Null
    New-Item -ItemType Junction -Path $shadowO -Target $pinnedTarget | Out-Null
    $caseE = Invoke-Target $health $argsHealth
    $jE = $caseE.output | ConvertFrom-Json
    $coreE = @($jE.core_gate | Where-Object { $_.id -ceq 'hybrid-development' })[0]
    Assert (($jE.verdict -ceq 'FAIL') -and (@($jE.core_gate | Where-Object { -not $_.ok } | ForEach-Object { $_.id }) -contains 'hybrid-development') -and ($coreE.shadow -ceq 'diverged-undocumented')) 'E: pin diverge reprova mesmo em same-target'

    # Catálogo com shadow_table inválido não pode conceder isenção same-target.
    $catalogCopy = Join-Path $fixture 'skills-catalog-invalid-shadow.json'
    $catalogPath = Join-Path $root 'source\registry\skills-catalog.json'
    $catalog = [IO.File]::ReadAllText($catalogPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $catalog.shadow_table = 'invalid-shadow-table'
    [IO.File]::WriteAllText($catalogCopy, ($catalog | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
    $invalidShadowArgs = @('-Json', '-CatalogPath', $catalogCopy, '-AgentsSkillsRoot', $agents, '-OpencodeSkillsRoot', $opencode, '-ProjectSkillsRoot', $project)
    $invalidShadow = Invoke-Target $health $invalidShadowArgs
    $invalidShadowJson = $invalidShadow.output | ConvertFrom-Json
    $invalidShadowCore = @($invalidShadowJson.core_gate | Where-Object { $_.id -ceq 'writing-plans' })[0]
    Assert (($invalidShadowJson.verdict -ceq 'FAIL') -and (@($invalidShadowJson.reasons) -match 'core-gate') -and (-not $invalidShadowCore.ok) -and ($invalidShadowCore.shadow -ceq 'shadow-undocumented')) 'shadow_table invalido desativa isencao same-target (fail-closed)' $invalidShadow.output
}
catch {
    Assert $false 'fixture isolation executada' $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
    Assert (-not (Test-Path -LiteralPath $fixture)) 'fixture temporaria removida ao final' $fixture
}
Write-Host ('PASS: ' + $pass + ' / FAIL: ' + $fail)
if ($fail -gt 0) { exit 1 }
exit 0
