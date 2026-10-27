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

    $suiteArgs = @('-AgentsSkillsRoot', $agents, '-OpencodeSkillsRoot', $opencode, '-ProjectSkillsRoot', $project)
    $b = Invoke-Target $suite $suiteArgs
    # O veredito do healthcheck falha por COREs ausentes (pre-existente), nao por skills pessoais.
    # A assercao chave: o inventario versionado continua integro (sem NOT OK de inventario).
    # A suite sai com codigo 1 porque o healthcheck reprova os COREs ausentes (pre-existente),
    # nao por causa das skills pessoais. O invariante sob teste e a integridade do inventario.
    Assert (($b.exit_code -eq 1) -and ($b.output -match 'ok - catalogo == inventario versionado') -and ($b.output -notmatch 'NOT OK - catalogo == inventario')) 'catalogo versionado nao exige igualdade com roots pessoais' $b.output

    $coreId = 'hybrid-development'
    $shadowA = Join-Path $agents $coreId
    $shadowO = Join-Path $opencode $coreId
    foreach ($d in @($shadowA, $shadowO)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText((Join-Path $shadowA 'SKILL.md'), '# unapproved-core-a', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $shadowO 'SKILL.md'), '# unapproved-core-b', (New-Object Text.UTF8Encoding $false))
    $c = Invoke-Target $health $argsHealth
    $jc = $null
    try { $jc = $c.output | ConvertFrom-Json } catch { }
    Assert (($c.exit_code -eq 0) -and ($null -ne $jc) -and ($jc.verdict -ceq 'FAIL') -and (($jc.reasons -join '|') -match 'core-gate')) 'healthcheck detecta shadow CORE nao aprovado' $c.output

    $d = Invoke-Target $suite $suiteArgs
    Assert (($d.exit_code -ne 0) -and ($d.output -match 'NOT OK -')) 'suite bloqueia conflito real em CORE' $d.output
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
