<#!
.SYNOPSIS
    Suite do catalogo curado de skills (Fase 2B): schema + cobertura + gates.
.DESCRIPTION
    Valida source/registry/skills-catalog.json (ids unicos, classificacao e
    prioridade validas, source/version_policy presentes, CORE com agents e
    status ACTIVE, shadow_table documentada) e, quando os roots de discovery
    da maquina existem, a cobertura total (catalogo cobre 103 + 2) e o
    veredito PASS de scripts/v3/skills-healthcheck.ps1 -Json.
    Estilo das suites distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
    Somente leitura; PS 5.1 compativel.
#>
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name, [string]$Detail = '') {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else {
    $script:fail += 1
    $line = ("NOT OK - " + $Name)
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + " -- " + $Detail }
    Write-Host $line
  }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$catPath = Join-Path $RepoRoot 'source\registry\skills-catalog.json'
$hcPath = Join-Path $RepoRoot 'scripts\v3\skills-healthcheck.ps1'

Assert (Test-Path -LiteralPath $catPath -PathType Leaf) 'catalogo skills-catalog.json existe'
Assert (Test-Path -LiteralPath $hcPath -PathType Leaf) 'healthcheck skills-healthcheck.ps1 existe'

$cat = $null
try {
  $cat = ([IO.File]::ReadAllText($catPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $cat) 'catalogo parseia como JSON'
}
catch {
  Assert $false 'catalogo parseia como JSON' $_.Exception.Message
}

if ($null -ne $cat) {
  Assert (([string]$cat.schema_version) -ceq '1') 'catalogo schema_version == 1'
  $skills = @($cat.skills)
  $ids = @($skills | ForEach-Object { [string]$_.id })
  $uniq = @($ids | Sort-Object -Unique)
  Assert (($ids.Count -gt 0) -and ($ids.Count -eq $uniq.Count)) 'ids unicos' ('total=' + $ids.Count)

  $allowedCls = @('CORE', 'RECOMMENDED', 'DOMAIN', 'PROJECT_SPECIFIC', 'PERSONAL', 'EXPERIMENTAL', 'REDUNDANT', 'DEPRECATED', 'REMOVE_CANDIDATE')
  $allowedPri = @('P0', 'P1', 'P2', 'P3', 'P4')
  $allowedMgr = @('orchestration', 'user', 'none')
  $allowedAct = @('on-demand', 'explicit-only', 'excluded')
  $allowedSt = @('ACTIVE', 'ACKNOWLEDGED', 'EXPERIMENTAL', 'INVALID', 'DEPRECATED_ACTIVE')
  $refErrs = New-Object System.Collections.ArrayList
  $coreIds = New-Object System.Collections.ArrayList
  foreach ($s in $skills) {
    $sid = [string]$s.id
    if ($allowedCls -notcontains [string]$s.classification) { [void]$refErrs.Add(($sid + ': classification invalida')) }
    if ($allowedPri -notcontains [string]$s.priority) { [void]$refErrs.Add(($sid + ': priority invalida')) }
    if ($allowedMgr -notcontains [string]$s.managed_by) { [void]$refErrs.Add(($sid + ': managed_by invalido')) }
    if ($allowedAct -notcontains [string]$s.activation) { [void]$refErrs.Add(($sid + ': activation invalida')) }
    if ($allowedSt -notcontains [string]$s.status) { [void]$refErrs.Add(($sid + ': status invalido')) }
    if ([string]::IsNullOrWhiteSpace([string]$s.source)) { [void]$refErrs.Add(($sid + ': source vazia')) }
    if ([string]::IsNullOrWhiteSpace([string]$s.version_policy)) { [void]$refErrs.Add(($sid + ': version_policy vazia')) }
    if ([string]::IsNullOrWhiteSpace([string]$s.category)) { [void]$refErrs.Add(($sid + ': category vazia')) }
    if ([string]$s.classification -ceq 'CORE') {
      [void]$coreIds.Add($sid)
      if (@($s.agents).Count -eq 0) { [void]$refErrs.Add(($sid + ': CORE sem agents')) }
      if ([string]$s.status -cne 'ACTIVE') { [void]$refErrs.Add(($sid + ': CORE sem status ACTIVE')) }
      if ([string]$s.managed_by -cne 'orchestration') { [void]$refErrs.Add(($sid + ': CORE sem managed_by orchestration')) }
    }
    if (([string]$s.classification -ceq 'REDUNDANT') -and [string]::IsNullOrWhiteSpace([string]$s.replaced_by)) {
      [void]$refErrs.Add(($sid + ': REDUNDANT sem replaced_by'))
    }
    if (([string]$s.classification -ceq 'DEPRECATED') -and [string]::IsNullOrWhiteSpace([string]$s.replaced_by)) {
      [void]$refErrs.Add(($sid + ': DEPRECATED sem replaced_by'))
    }
  }
  Assert ($refErrs.Count -eq 0) 'schema + enums + regras CORE/REDUNDANT/DEPRECATED' ($refErrs -join ' | ')
  Assert ($coreIds.Count -le 12) 'CORE pequeno (<=12)' ('obtido: ' + $coreIds.Count)

  # Precedencia documentada: winner esperado.
  $winner = ''
  try { $winner = [string]$cat.precedence.winner } catch { $winner = '' }
  Assert ($winner -ceq '~/.config/opencode/skills') 'precedencia later-wins documentada (opencode vence)'

  # Shadow_table: todo id sombreado tem estado conhecido e winner.
  $shErrs = New-Object System.Collections.ArrayList
  try {
    foreach ($st in @($cat.shadow_table)) {
      if ([string]::IsNullOrWhiteSpace([string]$st.id)) { [void]$shErrs.Add('shadow sem id') }
      if (@('identical', 'diverged-benign', 'diverged') -notcontains [string]$st.state) { [void]$shErrs.Add(([string]$st.id + ': state desconhecido')) }
      if ([string]$st.winner -cne '~/.config/opencode/skills') { [void]$shErrs.Add(([string]$st.id + ': winner inesperado')) }
      if ($ids -notcontains [string]$st.id) { [void]$shErrs.Add(([string]$st.id + ': shadow fora do catalogo')) }
    }
  } catch { [void]$shErrs.Add('shadow_table ilegivel') }
  Assert ($shErrs.Count -eq 0) 'shadow_table documentada (estado + winner)' ($shErrs -join ' | ')

  # Vinculo de hashes: excecao so vale para o par exato registrado (64 hex cada).
  $hashErrs = New-Object System.Collections.ArrayList
  try {
    foreach ($st in @($cat.shadow_table)) {
      foreach ($f in @('agents_sha256', 'opencode_sha256')) {
        $v = ''
        try { $v = [string]$st.$f } catch { $v = '' }
        if ($v -cnotmatch '^[0-9a-f]{64}$') { [void]$hashErrs.Add(([string]$st.id + ': ' + $f + ' fora do formato sha256 hex')) }
      }
    }
  } catch { [void]$hashErrs.Add('shadow_table ilegivel para hashes') }
  Assert ($hashErrs.Count -eq 0) 'shadow_table com par de hashes exato (gate vinculado)' ($hashErrs -join ' | ')

  # Repo-only: skills repo-pinned do CORE existem em skills-core/.
  $repoCoreErrs = New-Object System.Collections.ArrayList
  foreach ($s in @($skills | Where-Object { ([string]$_.classification -ceq 'CORE') -and ([string]$_.version_policy -ceq 'repo-pinned') })) {
    $p = Join-Path $RepoRoot (Join-Path 'skills-core' (Join-Path ([string]$s.id) 'SKILL.md'))
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { [void]$repoCoreErrs.Add(([string]$s.id + ': SKILL.md ausente em skills-core')) }
  }
  Assert ($repoCoreErrs.Count -eq 0) 'CORE repo-pinned presente em skills-core/' ($repoCoreErrs -join ' | ')

  # Cobertura exata contra o inventario versionado (repo-only: roda tambem no CI limpo).
  $invPath = Join-Path $RepoRoot 'evidence\capabilities-phase-2b\skills-inventory-2026-10-07.json'
  Assert (Test-Path -LiteralPath $invPath -PathType Leaf) 'inventario versionado existe'
  if (Test-Path -LiteralPath $invPath -PathType Leaf) {
    $invErrs = New-Object System.Collections.ArrayList
    try {
      $inv = ([IO.File]::ReadAllText($invPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
      $invAgents = @(@($inv.rows | Where-Object { [string]$_.root -ceq 'agents' }) | ForEach-Object { [string]$_.id })
      $invOpOnly = @(@($inv.rows | Where-Object { ([string]$_.root -ceq 'opencode') -and (-not [bool]$_.also_in_agents) }) | ForEach-Object { [string]$_.id })
      $expected = @($invAgents + $invOpOnly)
      if ($invAgents.Count -ne 103) { [void]$invErrs.Add(('inventario agents != 103: ' + $invAgents.Count)) }
      if ($invOpOnly.Count -ne 2) { [void]$invErrs.Add(('inventario opencode-only != 2: ' + $invOpOnly.Count)) }
      $d1 = @(Compare-Object $expected $ids | ForEach-Object { $_.InputObject })
      if ($d1.Count -gt 0) { [void]$invErrs.Add(('catalogo != inventario: ' + ($d1 -join ','))) }
    } catch { [void]$invErrs.Add(('inventario ilegivel: ' + $_.Exception.Message)) }
    Assert ($invErrs.Count -eq 0) 'catalogo == inventario versionado (103 + 2, sem sobra/falta)' ($invErrs -join ' | ')
  }

  # Cobertura total quando os roots da maquina existem (SKIP em CI/runner limpo).
  $agentsRoot = Join-Path $HOME '.agents\skills'
  $opencodeRoot = Join-Path $HOME '.config\opencode\skills'
  if ((Test-Path -LiteralPath $agentsRoot -PathType Container) -and (Test-Path -LiteralPath $opencodeRoot -PathType Container)) {
    $diskAgents = @(Get-ChildItem -LiteralPath $agentsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $missing = @($diskAgents | Where-Object { $ids -notcontains $_ })
    Assert ($missing.Count -eq 0) 'catalogo cobre 100% de ~/.agents/skills' ($missing -join ',')
    $diskOpOnly = @(Get-ChildItem -LiteralPath $opencodeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $diskAgents -notcontains $_ })
    $missingOp = @($diskOpOnly | Where-Object { $ids -notcontains $_ })
    Assert ($missingOp.Count -eq 0) 'catalogo cobre skills so-opencode' ($missingOp -join ',')
    Assert (($ids.Count -eq ($diskAgents.Count + $diskOpOnly.Count))) 'catalogo sem sobra (105 = 103 + 2)' ('catalogo=' + $ids.Count + ' disco=' + ($diskAgents.Count + $diskOpOnly.Count))

    $hcJson = ''
    try { $hcJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $hcPath -Json 2>&1 | Out-String } catch { $hcJson = '' }
    $env = $null
    try { $env = $hcJson | ConvertFrom-Json } catch { $env = $null }
    Assert ($null -ne $env) 'skills-healthcheck emite JSON parseavel'
    if ($null -ne $env) {
      Assert (([string]$env.verdict) -ceq 'PASS') 'skills-healthcheck verdict PASS' ('obtido: ' + [string]$env.verdict + ' reasons: ' + ((@($env.reasons)) -join ';'))
    }
  }
  else {
    Write-Host '[SKIP] cobertura de disco + healthcheck PASS (roots de skills ausentes neste runner)'
  }
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
