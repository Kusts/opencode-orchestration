<#!
.SYNOPSIS
    Healthcheck das skills do catalogo curado (Fase 2B, observacional).
.DESCRIPTION
    Le source/registry/skills-catalog.json, sonda os roots de discovery
    (~/.agents/skills, ~/.config/opencode/skills, .opencode/skills do repo) e
    emite: total_discovered / managed / personal / project / duplicate_ids /
    shadowed / invalid / deprecated + gate Core (present, discoverable,
    not_shadowed, version/status). Somente leitura: nunca move, remove ou
    escreve skills. PS 5.1 compativel.

    Exit: 0 = sondagem concluida (veredito PASS/FAIL no envelope);
    2 = fail-closed (catalogo ausente/ilegivel).
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$CatalogPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
  $CatalogPath = Join-Path $RepoRoot 'source\registry\skills-catalog.json'
}

function Get-SkillDirs([string]$Root) {
  $out = @()
  if ([string]::IsNullOrWhiteSpace($Root)) { return $out }
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $out }
  foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
    $skillFile = Join-Path $d.FullName 'SKILL.md'
    $present = $false
    try { $present = (Test-Path -LiteralPath $skillFile -PathType Leaf) } catch { $present = $false }
    $hash = ''
    if ($present) {
      try { $hash = ((Get-FileHash -LiteralPath $skillFile -Algorithm SHA256).Hash).ToLowerInvariant() } catch { $hash = '' }
    }
    $out += [ordered]@{ id = $d.Name; present = [bool]$present; sha256 = $hash }
  }
  return $out
}

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
  [Console]::Error.WriteLine('skills-catalog.json ausente: ' + $CatalogPath)
  exit 2
}
$cat = $null
try {
  $cat = ([IO.File]::ReadAllText($CatalogPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
}
catch {
  [Console]::Error.WriteLine('skills-catalog.json ilegivel: ' + $_.Exception.Message)
  exit 2
}
if (($null -eq $cat) -or ($null -eq $cat.skills)) {
  [Console]::Error.WriteLine('skills-catalog.json sem bloco skills')
  exit 2
}

$agentsRoot = Join-Path $HOME '.agents\skills'
$opencodeRoot = Join-Path $HOME '.config\opencode\skills'
$projectRoot = Join-Path $RepoRoot '.opencode\skills'
$repoCoreRoot = Join-Path $RepoRoot 'skills-core'

$agentsSkills = @(Get-SkillDirs $agentsRoot)
$opencodeSkills = @(Get-SkillDirs $opencodeRoot)
$projectSkills = @(Get-SkillDirs $projectRoot)

$agentsIds = @($agentsSkills | ForEach-Object { [string]$_.id })
$opencodeIds = @($opencodeSkills | ForEach-Object { [string]$_.id })
# Presenca = SKILL.md legivel (diretorio sozinho nao e skill valida: junction quebrada conta como invalid, nao como presente).
$agentsPresentIds = @($agentsSkills | Where-Object { [bool]$_.present } | ForEach-Object { [string]$_.id })
$opencodePresentIds = @($opencodeSkills | Where-Object { [bool]$_.present } | ForEach-Object { [string]$_.id })
$agentsHash = @{}
foreach ($s in $agentsSkills) { $agentsHash[[string]$s.id] = [string]$s.sha256 }
$opencodeHash = @{}
foreach ($s in $opencodeSkills) { $opencodeHash[[string]$s.id] = [string]$s.sha256 }

# duplicate_ids: case-insensitive dentro de cada root
$duplicateIds = @()
foreach ($set in @(@{ name = 'agents'; ids = $agentsIds }, @{ name = 'opencode'; ids = $opencodeIds })) {
  $lower = @{}
  foreach ($id in @($set.ids)) {
    $k = ([string]$id).ToLowerInvariant()
    if ($lower.ContainsKey($k)) {
      if ($lower[$k] -ne $id) { $duplicateIds += ($set.name + ':' + $id) }
    }
    else { $lower[$k] = $id }
  }
}

# shadowed: ids nos dois roots + estado do hash
$shadowed = @()
$opencodeById = @{}
foreach ($s in $opencodeSkills) { $opencodeById[[string]$s.id] = $s }
foreach ($s in $agentsSkills) {
  $id = [string]$s.id
  if ($opencodeById.ContainsKey($id)) {
    $o = $opencodeById[$id]
    $state = 'identical'
    if (([string]$s.sha256) -ne ([string]$o.sha256)) { $state = 'diverged' }
    if ((-not [bool]$s.present) -or (-not [bool]$o.present)) { $state = 'incomplete-' + $state }
    $shadowed += [ordered]@{ id = $id; state = $state; winner = '~/.config/opencode/skills' }
  }
}

# invalid: entrada sem SKILL.md legivel (inclui junction quebrada)
$invalid = @()
foreach ($s in ($agentsSkills + $opencodeSkills)) {
  if (-not [bool]$s.present) { $invalid += [string]$s.id }
}

# contagens por classificacao do catalogo (somente presentes em algum root)
$byClass = @{}
$managed = 0; $personal = 0; $project = 0; $deprecatedPresent = @()
$catById = @{}
foreach ($e in @($cat.skills)) { $catById[[string]$e.id] = $e }
foreach ($e in @($cat.skills)) {
  $id = [string]$e.id
  $cls = [string]$e.classification
  $presentAnywhere = ($agentsPresentIds -contains $id) -or ($opencodePresentIds -contains $id)
  if (-not $presentAnywhere) { continue }
  if (-not $byClass.ContainsKey($cls)) { $byClass[$cls] = 0 }
  $byClass[$cls] += 1
  if ([string]$e.managed_by -eq 'orchestration' -and (($cls -eq 'CORE') -or ($cls -eq 'RECOMMENDED') -or ($cls -eq 'DOMAIN'))) { $managed += 1 }
  if ($cls -eq 'PERSONAL') { $personal += 1 }
  if ($cls -eq 'PROJECT_SPECIFIC') { $project += 1 }
  if (($cls -eq 'DEPRECATED') -or ($cls -eq 'REMOVE_CANDIDATE')) { $deprecatedPresent += $id }
}

# gate Core: present + discoverable + not_shadowed (excecao vinculada ao par de hashes registrado) + version/status
$coreGate = @()
$coreFail = @()
$shadowApproved = @{}
try {
  foreach ($st in @($cat.shadow_table)) {
    $shadowApproved[[string]$st.id] = [ordered]@{
      state = [string]$st.state
      agents = ([string]$st.agents_sha256).ToLowerInvariant()
      opencode = ([string]$st.opencode_sha256).ToLowerInvariant()
    }
  }
} catch { $shadowApproved = @{} }
foreach ($e in @($cat.skills | Where-Object { [string]$_.classification -ceq 'CORE' })) {
  $id = [string]$e.id
  $inOpencode = ($opencodePresentIds -contains $id)
  $inAgents = ($agentsPresentIds -contains $id)
  $inRepoCore = (Test-Path -LiteralPath (Join-Path $repoCoreRoot (Join-Path $id 'SKILL.md')) -PathType Leaf)
  # present/discoverable = caminho efetivo de discovery com SKILL.md legivel (qualquer root); managed = root gerenciado (opencode ou repo-core)
  $present = ($inOpencode -or $inAgents -or $inRepoCore)
  $isManaged = ($inOpencode -or $inRepoCore)
  $sh = @($shadowed | Where-Object { [string]$_.id -ceq $id })
  $notShadowed = $true
  $shadowNote = 'no-shadow'
  if ($sh.Count -gt 0) {
    $shadowNote = [string]$sh[0].state
    if ($shadowApproved.ContainsKey($id)) {
      $ap = $shadowApproved[$id]
      $curA = ''; if ($agentsHash.ContainsKey($id)) { $curA = ([string]$agentsHash[$id]).ToLowerInvariant() }
      $curO = ''; if ($opencodeHash.ContainsKey($id)) { $curO = ([string]$opencodeHash[$id]).ToLowerInvariant() }
      if (($curA -ceq $ap.agents) -and ($curO -ceq $ap.opencode) -and (($ap.state -ceq 'identical') -or ($ap.state -ceq 'diverged-benign'))) {
        $notShadowed = $true
        $shadowNote = 'approved-pair'
      }
      else {
        $notShadowed = $false
        $shadowNote = 'diverged-undocumented'
      }
    }
    else { $notShadowed = $false; $shadowNote = 'shadow-undocumented' }
  }
  $ok = ([bool]$present -and [bool]$notShadowed)
  $coreGate += [ordered]@{ id = $id; present = [bool]$present; discoverable = [bool]$present; managed = [bool]$isManaged; not_shadowed = [bool]$notShadowed; shadow = $shadowNote; status = [string]$e.status; ok = [bool]$ok }
  if (-not $ok) { $coreFail += $id }
}

# REMOVE_CANDIDATE nao pode estar nos roots gerenciados (opencode skills / skills-core do repo)
$removedInManaged = @()
foreach ($e in @($cat.skills | Where-Object { [string]$_.classification -ceq 'REMOVE_CANDIDATE' })) {
  $id = [string]$e.id
  if ($opencodePresentIds -contains $id) { $removedInManaged += ('opencode:' + $id) }
  if (Test-Path -LiteralPath (Join-Path $repoCoreRoot (Join-Path $id 'SKILL.md')) -PathType Leaf) { $removedInManaged += ('repo-core:' + $id) }
}

$verdict = 'PASS'
$reasons = @()
if ($coreFail.Count -gt 0) { $verdict = 'FAIL'; $reasons += ('core-gate: ' + ($coreFail -join ',')) }
if ($removedInManaged.Count -gt 0) { $verdict = 'FAIL'; $reasons += ('remove-candidate-in-managed: ' + ($removedInManaged -join ',')) }

$envelope = [ordered]@{
  schema_version = 1
  generated_at   = ((Get-Date).ToUniversalTime().ToString('o'))
  catalog        = 'source/registry/skills-catalog.json'
  skills         = [ordered]@{
    total_discovered = (($agentsSkills.Count) + ($opencodeSkills.Count) + ($projectSkills.Count))
    agents_root      = $agentsSkills.Count
    opencode_root    = $opencodeSkills.Count
    project_root     = $projectSkills.Count
    managed          = $managed
    personal         = $personal
    project          = $project
    by_classification = $byClass
    duplicate_ids    = @($duplicateIds)
    shadowed         = @($shadowed)
    invalid          = @($invalid)
    deprecated       = @($deprecatedPresent)
  }
  core_gate      = @($coreGate)
  remove_in_managed = @($removedInManaged)
  verdict        = $verdict
  reasons        = @($reasons)
}

if ($Json) {
  $envelope | ConvertTo-Json -Depth 6 -Compress | Write-Output
  exit 0
}

Write-Host ('skills total_discovered=' + $envelope.skills.total_discovered + ' (agents=' + $envelope.skills.agents_root + ' opencode=' + $envelope.skills.opencode_root + ' project=' + $envelope.skills.project_root + ') managed=' + $managed + ' personal=' + $personal + ' project=' + $project)
Write-Host ('duplicate_ids=' + $duplicateIds.Count + ' shadowed=' + $shadowed.Count + ' invalid=[' + ($invalid -join ',') + '] deprecated=[' + ($deprecatedPresent -join ',') + ']')
Write-Host ('core_gate fails=[' + ($coreFail -join ',') + '] remove_in_managed=[' + ($removedInManaged -join ',') + '] verdict=' + $verdict)
exit 0
