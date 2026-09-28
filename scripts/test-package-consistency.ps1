<#!
.SYNOPSIS
    Valida a consistencia interna do pacote opencode-orchestration (P6.3 + V3.1 Phase 2).
.DESCRIPTION
    15 checks, exit 0/1, uma linha [OK]/[FAIL] por check. PS 5.1 compativel.
    Se um check apontar defeito REAL no pacote, conserte o pacote, nao o teste.
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$script:nOk = 0
$script:nBad = 0
function Report-Ok([string]$Name, [string]$Detail) {
  $script:nOk += 1
  $line = '[OK] ' + $Name
  if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + ' -- ' + $Detail }
  Write-Host $line
}
function Report-Fail([string]$Name, [string]$Detail) {
  $script:nBad += 1
  Write-Host ('[FAIL] ' + $Name + ' -- ' + $Detail)
}

function Read-Utf8([string]$Path) {
  return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Strip-JsoncComments([string]$Text) {
  $lines = $Text -split "`n" | Where-Object { $_ -notmatch '^\s*//' }
  return ($lines -join "`n")
}

function Get-TokenNames([string]$Text) {
  $set = @{}
  foreach ($m in [regex]::Matches($Text, '\{\{([A-Za-z0-9_]+)\}\}')) {
    $set[$m.Groups[1].Value] = $true
  }
  return @($set.Keys | Sort-Object)
}

# ---- 1. arquivos referenciados por install/uninstall existem ----------------
try {
  $missing1 = New-Object System.Collections.ArrayList
  $checked1 = 0
  foreach ($f in @((Join-Path $RepoRoot 'install.ps1'), (Join-Path $RepoRoot 'uninstall.ps1'))) {
    $txt = Read-Utf8 $f
    $seen = @{}
    $cands = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($txt, "(?:Join-Path|Resolve-Path)\s+(?:-LiteralPath\s+)?\`$[A-Za-z_]+\s+'([^']+)'")) {
      [void]$cands.Add($m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($txt, "'((?:source|templates|skills-core|plugins|scripts)[\\/][A-Za-z0-9_.\/\\*-]+)'")) {
      [void]$cands.Add($m.Groups[1].Value)
    }
    foreach ($lit in $cands) {
      if ([string]::IsNullOrWhiteSpace($lit)) { continue }
      $isRepoRef = ($lit -match '^(source|templates|skills-core|plugins|scripts)[\\/]') -or ($lit -ceq 'models.example.jsonc')
      if (-not $isRepoRef) { continue }
      $rel = ($lit -replace '/', '\')
      if ($seen.ContainsKey($rel)) { continue }
      $seen[$rel] = $true
      $checked1 += 1
      $full = Join-Path $RepoRoot $rel
      if (-not (Test-Path -LiteralPath $full)) {
        if ($rel.Contains('*')) {
          $hit = @(Get-ChildItem -Path $full -ErrorAction SilentlyContinue)
          if ($hit.Count -eq 0) { [void]$missing1.Add((Split-Path -Leaf $f) + ': ' + $rel) }
        }
        else {
          [void]$missing1.Add((Split-Path -Leaf $f) + ': ' + $rel)
        }
      }
    }
  }
  if ($missing1.Count -eq 0) { Report-Ok '1 refs install/uninstall existem' ([string]$checked1 + ' path(s) resolvidos') }
  else { Report-Fail '1 refs install/uninstall existem' ($missing1 -join ' | ') }
}
catch { Report-Fail '1 refs install/uninstall existem' $_.Exception.Message }

# ---- 2. tokens usados == conjunto conhecido ---------------------------------
try {
  $knownTokens = @('HOME', 'MODEL_CHEAP', 'MODEL_PLANNER', 'MODEL_STRONG', 'REPO_DIR')
  $renderFiles = New-Object System.Collections.ArrayList
  [void]$renderFiles.Add((Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl'))
  [void]$renderFiles.Add((Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'))
  [void]$renderFiles.Add((Join-Path $RepoRoot 'source\global\AGENTS.md'))
  [void]$renderFiles.Add((Join-Path $RepoRoot 'source\adapters\opencode.md'))
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)) {
    [void]$renderFiles.Add($f.FullName)
  }
  $used = @{}
  foreach ($f in $renderFiles) {
    foreach ($t in (Get-TokenNames (Read-Utf8 $f))) { $used[$t] = $true }
  }
  $unknown = @($used.Keys | Where-Object { $knownTokens -notcontains $_ } | Sort-Object)
  if ($unknown.Count -eq 0) { Report-Ok '2 tokens conhecidos' ('usados: ' + (($used.Keys | Sort-Object) -join ',')) }
  else { Report-Fail '2 tokens conhecidos' ('desconhecidos: ' + ($unknown -join ',')) }
}
catch { Report-Fail '2 tokens conhecidos' $_.Exception.Message }

# ---- 3. template V1 agents x source/agents .md + frontmatter --------------------
try {
  $tmplRaw = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl')
  $resolved = $tmplRaw.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $tmpl = $resolved | ConvertFrom-Json
  $blocks = @($tmpl.agent.PSObject.Properties.Name)
  $errs3 = New-Object System.Collections.ArrayList
  if ($blocks.Count -ne 17) { [void]$errs3.Add(('blocos agent=' + $blocks.Count + ', esperado 17')) }
  foreach ($req in @('build', 'title')) {
    if ($blocks -notcontains $req) { [void]$errs3.Add(('bloco ausente: ' + $req)) }
  }
  $workers = @($blocks | Where-Object { ($_ -ne 'build') -and ($_ -ne 'title') })
  foreach ($w in $workers) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ('source\agents\' + $w + '.md')) -PathType Leaf)) {
      [void]$errs3.Add(('template sem .md: ' + $w))
    }
  }
  $mdFiles = @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)
  if ($mdFiles.Count -ne 19) { [void]$errs3.Add(('.md=' + $mdFiles.Count + ', esperado 19')) }
  $planningOnly = @('requirements-analyst', 'engineering-advisor', 'product-designer', 'skeptic')
  foreach ($f in $mdFiles) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (($workers -notcontains $stem) -and ($planningOnly -notcontains $stem)) {
      [void]$errs3.Add(('.md sem bloco nem planning: ' + $f.Name))
    }
    $raw = Read-Utf8 $f.FullName
    $m = [regex]::Match($raw, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*')
    $fm = ''
    if ($m.Success) { $fm = $m.Groups[1].Value }
    $hasModel = ($fm -match '(?m)^model:\s*\{\{MODEL_(PLANNER|CHEAP|STRONG)\}\}\s*$')
    $hasMode = ($fm -match '(?m)^mode:\s*subagent\s*$')
    if ((-not $hasModel) -and (-not $hasMode)) {
      [void]$errs3.Add(('frontmatter sem model-token nem mode subagent: ' + $f.Name))
    }
  }
  if ($errs3.Count -eq 0) { Report-Ok '3 template V1 x agents' '17 blocos (build,title,15 workers com .md); 19 .md com frontmatter valido; build/title sem .md by design' }
  else { Report-Fail '3 template V1 x agents' ($errs3 -join ' | ') }
}
catch { Report-Fail '3 template V1 x agents' $_.Exception.Message }

# ---- 4. allowlist do build == arquivos source/agents (bidirecional + valores) --
try {
  $taskNode = $tmpl.agent.build.permission.task
  $errs4 = New-Object System.Collections.ArrayList
  if ($null -eq $taskNode) {
    [void]$errs4.Add('agent.build.permission.task ausente no template')
  }
  else {
    $wildProp = $taskNode.PSObject.Properties['*']
    $wild = $null
    if ($null -ne $wildProp) { $wild = $wildProp.Value }
    if ($wild -cne 'deny') { [void]$errs4.Add(('"*"=' + [string]$wild + ', esperado "deny"')) }
    $allow = @($taskNode.PSObject.Properties.Name | Where-Object { $_ -ne '*' } | Sort-Object)
    foreach ($a in $allow) {
      if ($taskNode.$a -cne 'allow') { [void]$errs4.Add(('valor != allow: ' + $a + '=' + [string]$taskNode.$a)) }
    }
    $mdNames = @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object)
    $onlyAllow = @($allow | Where-Object { $mdNames -notcontains $_ })
    $onlyMd = @($mdNames | Where-Object { $allow -notcontains $_ })
    if ($onlyAllow.Count -gt 0) { [void]$errs4.Add(('so-allowlist: ' + ($onlyAllow -join ','))) }
    if ($onlyMd.Count -gt 0) { [void]$errs4.Add(('so-.md: ' + ($onlyMd -join ','))) }
  }
  if ($errs4.Count -eq 0) { Report-Ok '4 allowlist build V1 == agents' ('19 nomes, "*":deny + allows; bidirecional exato') }
  else { Report-Fail '4 allowlist build V1 == agents' ($errs4 -join ' | ') }
}
catch { Report-Fail '4 allowlist build V1 == agents' $_.Exception.Message }

# ---- 5. referencias a scripts existentes --------------------------------------
try {
  $corpus = New-Object System.Collections.ArrayList
  [void]$corpus.Add((Join-Path $RepoRoot 'README.md'))
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'docs\*.md') -ErrorAction SilentlyContinue)) { [void]$corpus.Add($f.FullName) }
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\*.md') -Recurse -ErrorAction SilentlyContinue)) { [void]$corpus.Add($f.FullName) }
  [void]$corpus.Add((Join-Path $RepoRoot 'install.ps1'))
  [void]$corpus.Add((Join-Path $RepoRoot 'uninstall.ps1'))
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'templates\*') -ErrorAction SilentlyContinue)) { [void]$corpus.Add($f.FullName) }
  $bad5 = New-Object System.Collections.ArrayList
  $nRefs = 0
  foreach ($f in $corpus) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
    $norm = (Read-Utf8 $f) -replace '\\', '/'
    foreach ($m in [regex]::Matches($norm, 'scripts/[A-Za-z0-9_./-]*\.ps1')) {
      $ref = $m.Value
      $idx = $m.Index
      $before = ''
      if ($idx -ge 8) { $before = $norm.Substring($idx - 8, 8) }
      if ($before -match 'https?://') { continue }
      $nRefs += 1
      $full = Join-Path $RepoRoot ($ref -replace '/', '\')
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        [void]$bad5.Add(((Split-Path -Leaf $f) + ': ' + $ref))
      }
    }
  }
  if ($bad5.Count -eq 0) { Report-Ok '5 refs de scripts existem' ([string]$nRefs + ' ref(s) em ' + [string]$corpus.Count + ' arquivo(s); sem excecoes') }
  else { Report-Fail '5 refs de scripts existem' ($bad5 -join ' | ') }
}
catch { Report-Fail '5 refs de scripts existem' $_.Exception.Message }

# ---- 6. skills citadas ---------------------------------------------------------
try {
  $errs6 = New-Object System.Collections.ArrayList
  $core = @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')
  foreach ($s in $core) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ('skills-core\' + $s + '\SKILL.md')) -PathType Leaf)) {
      [void]$errs6.Add(('skills-core sem SKILL.md: ' + $s))
    }
  }
  $installTxt = Read-Utf8 (Join-Path $RepoRoot 'install.ps1')
  foreach ($s in $core) {
    if ($installTxt -notmatch [regex]::Escape($s)) { [void]$errs6.Add(('install.ps1 nao instala: ' + $s)) }
  }
  if ($errs6.Count -eq 0) { Report-Ok '6 skills-core + install' '5 skills com SKILL.md e presentes no instalador (entrypoint hybrid-development)' }
  else { Report-Fail '6 skills-core + install' ($errs6 -join ' | ') }
}
catch { Report-Fail '6 skills-core + install' $_.Exception.Message }

# ---- 7. model pools consistentes ------------------------------------------------
try {
  $errs7 = New-Object System.Collections.ArrayList
  $models = (Strip-JsoncComments (Read-Utf8 (Join-Path $RepoRoot 'models.example.jsonc'))) | ConvertFrom-Json
  foreach ($k in @('planner', 'cheap', 'strong')) {
    if ([string]::IsNullOrWhiteSpace([string]$models.$k)) { [void]$errs7.Add(('models.example sem chave: ' + $k)) }
  }
  $tmplTokens = Get-TokenNames $tmplRaw
  foreach ($t in $tmplTokens) {
    if (@('MODEL_PLANNER', 'MODEL_CHEAP', 'MODEL_STRONG') -notcontains $t) {
      [void]$errs7.Add(('template V1 com token nao-MODEL: ' + $t))
    }
  }
  $tmplRawV2t = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl')
  $tmplTokensV2 = Get-TokenNames $tmplRawV2t
  foreach ($t in $tmplTokensV2) {
    if (@('MODEL_PLANNER', 'MODEL_CHEAP', 'MODEL_STRONG') -notcontains $t) {
      [void]$errs7.Add(('template V2 com token nao-MODEL: ' + $t))
    }
  }
  if ($errs7.Count -eq 0) { Report-Ok '7 model pools' 'models.example chaves planner/cheap/strong; templates V1+V2 usam so {{MODEL_*}}' }
  else { Report-Fail '7 model pools' ($errs7 -join ' | ') }
}
catch { Report-Fail '7 model pools' $_.Exception.Message }

# ---- 8. workers V1: task deny no template E deny explicito no frontmatter -------
try {
  $tRaw8 = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl')
  $tRes8 = $tRaw8.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $t8 = $tRes8 | ConvertFrom-Json
  $bad8 = New-Object System.Collections.ArrayList
  $checked8 = 0
  $workers8 = @($t8.agent.PSObject.Properties.Name | Where-Object { ($_ -ne 'build') -and ($_ -ne 'title') } | Sort-Object)
  foreach ($w in $workers8) {
    $checked8 += 1
    $node8 = $t8.agent.$w
    $tt8 = $null
    if (($null -ne $node8) -and ($null -ne $node8.permission)) { $tt8 = $node8.permission.task }
    if (-not ($tt8 -is [string]) -or ($tt8 -cne 'deny')) {
      [void]$bad8.Add(('template agent.' + $w + '.permission.task != deny'))
    }
  }
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)) {
    $checked8 += 1
    $raw = Read-Utf8 $f.FullName
    if ($raw -match '(?m)^\s*task:\s*allow\b') {
      [void]$bad8.Add(('task: allow em worker: ' + $f.Name))
      continue
    }
    $m8 = [regex]::Match($raw, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*')
    $fm8 = ''
    if ($m8.Success) { $fm8 = $m8.Groups[1].Value }
    $denyOk8 = $false
    $tm8 = [regex]::Match($fm8, '(?m)^(?<ind>\s*)task:\s*(?<val>.*?)(\r?)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($tm8.Success) {
      $v8 = $tm8.Groups['val'].Value.Trim()
      if ($v8 -ceq 'deny') { $denyOk8 = $true }
      elseif ($v8 -eq '') {
        $base8 = $tm8.Groups['ind'].Value.Length
        $vals8 = New-Object System.Collections.ArrayList
        $lines8 = $fm8 -split "`n"
        $started8 = $false
        foreach ($ln8 in $lines8) {
          if (-not $started8) {
            if ($ln8 -match '(?m)^\s*task:\s*$') { $started8 = $true }
            continue
          }
          $mm8 = [regex]::Match($ln8, '^(?<ind>\s*)(?<k>[A-Za-z0-9_*"''.?/-]+)\s*:\s*(?<v>.*?)\s*$')
          if (-not $mm8.Success) { continue }
          $ind8 = $mm8.Groups['ind'].Value.Length
          if ($ind8 -le $base8) { break }
          if ([string]::IsNullOrWhiteSpace($mm8.Groups['v'].Value)) { continue }
          [void]$vals8.Add($mm8.Groups['v'].Value.Trim())
        }
        if (($vals8.Count -gt 0) -and (@($vals8 | Where-Object { $_ -cne 'deny' }).Count -eq 0)) { $denyOk8 = $true }
      }
    }
    if (-not $denyOk8) {
      [void]$bad8.Add(('sem task deny explicito no frontmatter: ' + $f.Name))
    }
  }
  if ($bad8.Count -eq 0) { Report-Ok '8 workers V1 task deny (template + frontmatter)' ([string]$checked8 + ' checagem(ns): 15 workers deny no template; 19 .md com deny explicito; build/title fora da regra') }
  else { Report-Fail '8 workers V1 task deny (template + frontmatter)' ($bad8 -join ' | ') }
}
catch { Report-Fail '8 workers V1 task deny (template + frontmatter)' $_.Exception.Message }

# ---- 9. registry minima ----------------------------------------------------------
try {
  $errs9 = New-Object System.Collections.ArrayList
  $flags = $null
  foreach ($rel in @('source\registry\capability-flags.json', 'source\registry\capability-policy.json', 'source\registry\runtimes.json')) {
    $p = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { [void]$errs9.Add(('ausente: ' + $rel)); continue }
    try { $null = (Read-Utf8 $p) | ConvertFrom-Json }
    catch { [void]$errs9.Add(('nao parseia: ' + $rel)) }
  }
  $fp = Join-Path $RepoRoot 'source\registry\capability-flags.json'
  if (Test-Path -LiteralPath $fp -PathType Leaf) {
    try {
      $flags = (Read-Utf8 $fp) | ConvertFrom-Json
      $req9 = @(
        @('capability_router', 'active'),
        @('capability_router', 'shadow'),
        @('skill_routing', 'enabled'),
        @('mcp_routing', 'enabled'),
        @('adaptive_ranking', 'enabled')
      )
      foreach ($r in $req9) {
        $sec9 = $r[0]
        $key9 = $r[1]
        $secNode9 = $flags.$sec9
        if ($null -eq $secNode9) { [void]$errs9.Add(('ausente secao: ' + $sec9)); continue }
        $prop9 = $secNode9.PSObject.Properties[$key9]
        if ($null -eq $prop9) { [void]$errs9.Add(('ausente: ' + $sec9 + '.' + $key9)); continue }
        $v9 = $prop9.Value
        if ($null -eq $v9) { [void]$errs9.Add(('nao-bool (null): ' + $sec9 + '.' + $key9)); continue }
        if (-not ($v9 -is [bool])) { [void]$errs9.Add(('nao-bool: ' + $sec9 + '.' + $key9 + ' (' + $v9.GetType().Name + '=' + [string]$v9 + ')')); continue }
        if ($v9 -ne $false) { [void]$errs9.Add(($sec9 + '.' + $key9 + ' != false')) }
      }
    }
    catch { [void]$errs9.Add('flags ilegivel: ' + $_.Exception.Message) }
  }
  if ($errs9.Count -eq 0) { Report-Ok '9 registry minima' '3 JSONs parseiam; active/shadow/skill/mcp/adaptive = false' }
  else { Report-Fail '9 registry minima' ($errs9 -join ' | ') }
}
catch { Report-Fail '9 registry minima' $_.Exception.Message }

# ---- 10. docs criticos ------------------------------------------------------------
try {
  $missing10 = New-Object System.Collections.ArrayList
  foreach ($rel in @('README.md', 'docs\PERMISSIONS.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $rel) -PathType Leaf)) {
      [void]$missing10.Add($rel)
    }
  }
  if ($missing10.Count -eq 0) { Report-Ok '10 docs criticos' 'README.md + docs/PERMISSIONS.md' }
  else { Report-Fail '10 docs criticos' ('ausentes: ' + ($missing10 -join ', ')) }
}
catch { Report-Fail '10 docs criticos' $_.Exception.Message }

# ---- 11. template V1 trimmed: sem autoupdate/skills/plugin; 17 agents --------
try {
  $tRaw11 = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl')
  $tRes11 = $tRaw11.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $errs11 = New-Object System.Collections.ArrayList
  try { $t11 = $tRes11 | ConvertFrom-Json }
  catch { $t11 = $null; [void]$errs11.Add(('template nao parseia: ' + $_.Exception.Message)) }
  if ($null -ne $t11) {
    foreach ($k in @('autoupdate', 'skills', 'plugin')) {
      if ($null -ne $t11.PSObject.Properties[$k]) { [void]$errs11.Add(('template contem chave removida: ' + $k)) }
    }
    $blocks11 = @($t11.agent.PSObject.Properties.Name)
    if ($blocks11.Count -ne 17) { [void]$errs11.Add(('blocos agent=' + $blocks11.Count + ', esperado 17')) }
    if (($null -ne $t11.agent) -and ($null -ne $t11.agent.build) -and ($null -ne ($t11.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))) {
      [void]$errs11.Add('template: bloco build nao deve conter "model"')
    }
  }
  if ($errs11.Count -eq 0) { Report-Ok '11 template V1 trimmed (sem autoupdate/skills/plugin)' '17 blocos agent; build sem model' }
  else { Report-Fail '11 template V1 trimmed (sem autoupdate/skills/plugin)' ($errs11 -join ' | ') }
}
catch { Report-Fail '11 template V1 trimmed (sem autoupdate/skills/plugin)' $_.Exception.Message }

# ---- 12. template V2 shape nativo -------------------------------------------
try {
  $v2Raw12 = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl')
  $v2Res12 = $v2Raw12.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $errs12 = New-Object System.Collections.ArrayList
  try { $v2 = $v2Res12 | ConvertFrom-Json }
  catch { $v2 = $null; [void]$errs12.Add(('V2 nao parseia: ' + $_.Exception.Message)) }
  if ($null -ne $v2) {
    $top12 = @($v2.PSObject.Properties.Name)
    foreach ($k in @('agent', 'permission', 'subagent_depth', 'temperature', 'plugin', 'skills', 'mcp', 'autoupdate')) {
      if ($top12 -contains $k) { [void]$errs12.Add(('V2 contem chave proibida no topo: ' + $k)) }
    }
    if ($null -eq $v2.PSObject.Properties['agents']) { [void]$errs12.Add('V2 sem bloco agents') }
    else {
      $blocks12 = @($v2.agents.PSObject.Properties.Name)
      if ($blocks12.Count -ne 17) { [void]$errs12.Add(('V2 blocos agents=' + $blocks12.Count + ', esperado 17')) }
      foreach ($req in @('build', 'title')) {
        if ($blocks12 -notcontains $req) { [void]$errs12.Add(('V2 bloco ausente: ' + $req)) }
      }
    }
    if ($null -eq $v2.PSObject.Properties['experimental']) { [void]$errs12.Add('V2 sem bloco experimental') }
    elseif ([int]$v2.experimental.subagent_depth -ne 1) { [void]$errs12.Add('V2 experimental.subagent_depth != 1') }
    if ([string]$v2.default_agent -cne 'build') { [void]$errs12.Add(('V2 default_agent=' + [string]$v2.default_agent + ', esperado build')) }
    if (($null -ne $v2.agents) -and ($null -ne $v2.agents.build)) {
      if ([string]$v2.agents.build.mode -cne 'primary') { [void]$errs12.Add('V2 agents.build.mode != primary') }
      if ($null -ne ($v2.agents.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue)) { [void]$errs12.Add('V2 bloco build nao deve conter model') }
    }
    if (($null -ne $v2.agents) -and ($null -ne $v2.agents.title)) {
      if ([string]$v2.agents.title.model -cne 'x/planner') { [void]$errs12.Add('V2 agents.title.model != x/planner') }
      if ($null -ne ($v2.agents.title | Get-Member -Name 'permissions' -ErrorAction SilentlyContinue)) { [void]$errs12.Add('V2 bloco title nao deve conter permissions') }
    }
    if ($v2Raw12 -match '"task"\s*:') { [void]$errs12.Add('V2 contem chave legada task') }
    if ($v2Raw12 -match '"bash"') { [void]$errs12.Add('V2 contem acao legada bash') }
    if ($v2Raw12 -match '"temperature"') { [void]$errs12.Add('V2 contem temperature (ignorado no runtime)') }
    $validActions = @('subagent', 'shell', 'edit', 'read')
    $validEffects = @('allow', 'deny', 'ask')
    if ($null -ne $v2.agents) {
      foreach ($b in @($v2.agents.PSObject.Properties.Name)) {
        $node = $v2.agents.$b
        if ($b -eq 'title') { continue }
        if ($null -ne ($node | Get-Member -Name 'permission' -ErrorAction SilentlyContinue)) { [void]$errs12.Add(('V2 ' + $b + ' usa permission singular')) }
        if ($null -ne ($node | Get-Member -Name 'temperature' -ErrorAction SilentlyContinue)) { [void]$errs12.Add(('V2 ' + $b + ' contem temperature')) }
        $perms = $node.permissions
        if ($null -eq $perms) { [void]$errs12.Add(('V2 ' + $b + ' sem permissions array')); continue }
        if (-not ($perms -is [array])) { [void]$errs12.Add(('V2 ' + $b + '.permissions nao e array')); continue }
        foreach ($p in $perms) {
          if ($validActions -notcontains [string]$p.action) { [void]$errs12.Add(('V2 ' + $b + ' action invalida: ' + [string]$p.action)) }
          if ($validEffects -notcontains [string]$p.effect) { [void]$errs12.Add(('V2 ' + $b + ' effect invalido: ' + [string]$p.effect)) }
          if ([string]::IsNullOrWhiteSpace([string]$p.resource)) { [void]$errs12.Add(('V2 ' + $b + ' resource vazio')) }
        }
        if (($b -ne 'build') -and ($perms.Count -ne 1)) { [void]$errs12.Add(('V2 worker ' + $b + ' permissions != 1 entrada')) }
      }
    }
  }
  if ($errs12.Count -eq 0) { Report-Ok '12 template V2 shape nativo' '17 blocos agents; experimental.subagent_depth=1; permissions arrays validos; sem chaves legadas' }
  else { Report-Fail '12 template V2 shape nativo' ($errs12 -join ' | ') }
}
catch { Report-Fail '12 template V2 shape nativo' $_.Exception.Message }

# ---- 13. template V2 ordem de seguranca (broad-first) -------------------------
try {
  $v2Raw13 = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl')
  $v2Res13 = $v2Raw13.Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $v213 = $v2Res13 | ConvertFrom-Json
  $errs13 = New-Object System.Collections.ArrayList
  $perms13 = @($v213.agents.build.permissions)
  if ($perms13.Count -ne 20) { [void]$errs13.Add(('build.permissions=' + $perms13.Count + ', esperado 20 (1 deny + 19 allows)')) }
  $denyIdx = -1
  for ($i = 0; $i -lt $perms13.Count; $i++) {
    if (([string]$perms13[$i].action -ceq 'subagent') -and ([string]$perms13[$i].resource -ceq '*') -and ([string]$perms13[$i].effect -ceq 'deny')) { $denyIdx = $i; break }
  }
  if ($denyIdx -lt 0) { [void]$errs13.Add('par {subagent,*:deny} ausente no build') }
  elseif ($denyIdx -ne 0) { [void]$errs13.Add(('deny-* no indice ' + $denyIdx + ', esperado 0 (broad-first)')) }
  for ($i = 0; $i -lt $perms13.Count; $i++) {
    if ([string]$perms13[$i].effect -ceq 'allow') {
      if ($denyIdx -ge 0 -and $i -lt $denyIdx) { [void]$errs13.Add(('allow antes do deny-*: ' + [string]$perms13[$i].resource)) }
    }
  }
  if ($errs13.Count -eq 0) { Report-Ok '13 template V2 ordem broad-first' 'deny-* primeiro, 19 allows estreitos depois (last-match-wins)' }
  else { Report-Fail '13 template V2 ordem broad-first' ($errs13 -join ' | ') }
}
catch { Report-Fail '13 template V2 ordem broad-first' $_.Exception.Message }

# ---- 14. paridade semantica V2 <-> V1 ------------------------------------------
try {
  $v1Raw14 = (Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v1.json.tmpl')).Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $v2Raw14 = (Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl')).Replace('{{MODEL_PLANNER}}', 'x/planner').Replace('{{MODEL_CHEAP}}', 'x/cheap').Replace('{{MODEL_STRONG}}', 'x/strong')
  $t114 = $v1Raw14 | ConvertFrom-Json
  $t214 = $v2Raw14 | ConvertFrom-Json
  $errs14 = New-Object System.Collections.ArrayList
  $v1Allow = @($t114.agent.build.permission.task.PSObject.Properties.Name | Where-Object { $_ -ne '*' } | Sort-Object)
  $v2Allow = @($t214.agents.build.permissions | Where-Object { [string]$_.effect -ceq 'allow' } | ForEach-Object { [string]$_.resource } | Sort-Object)
  $d14 = Compare-Object $v1Allow $v2Allow
  if ($null -ne $d14) { [void]$errs14.Add(('allowlist diverge: ' + (($d14 | ForEach-Object { $_.InputObject }) -join ','))) }
  $strong14 = @('reviewer', 'debugger', 'security-reviewer', 'architect')
  foreach ($w in @($t114.agent.PSObject.Properties.Name | Where-Object { ($_ -ne 'build') -and ($_ -ne 'title') } | Sort-Object)) {
    $v2node = $t214.agents.$w
    if ($null -eq $v2node) { [void]$errs14.Add(('V2 sem worker: ' + $w)); continue }
    if ([string]$t114.agent.$w.model -cne [string]$v2node.model) { [void]$errs14.Add(('model diverge em ' + $w + ': V1=' + [string]$t114.agent.$w.model + ' V2=' + [string]$v2node.model)) }
    $exp14 = 'x/cheap'
    if ($strong14 -contains $w) { $exp14 = 'x/strong' }
    if ([string]$v2node.model -cne $exp14) { [void]$errs14.Add(('V2 model inesperado em ' + $w + ': ' + [string]$v2node.model)) }
  }
  if ([string]$t114.default_agent -cne [string]$t214.default_agent) { [void]$errs14.Add('default_agent diverge') }
  if ([string]$t114.agent.build.mode -cne [string]$t214.agents.build.mode) { [void]$errs14.Add('build.mode diverge') }
  if ([string]$t114.agent.title.model -cne [string]$t214.agents.title.model) { [void]$errs14.Add('title.model diverge') }
  if ($errs14.Count -eq 0) { Report-Ok '14 paridade V2 <-> V1' '19 allows iguais; 15 workers com mesmos models CHEAP/STRONG; default_agent/build/title iguais' }
  else { Report-Fail '14 paridade V2 <-> V1' ($errs14 -join ' | ') }
}
catch { Report-Fail '14 paridade V2 <-> V1' $_.Exception.Message }

# ---- 15. registry <-> templates -------------------------------------------------
try {
  $errs15 = New-Object System.Collections.ArrayList
  $reg15 = (Read-Utf8 (Join-Path $RepoRoot 'source\registry\runtimes.json')) | ConvertFrom-Json
  $tplV1 = [string]$reg15.runtimes.'opencode-v1'.template
  $tplV2 = [string]$reg15.runtimes.'opencode-v2'.template
  if ([string]::IsNullOrWhiteSpace($tplV1)) { [void]$errs15.Add('registry sem opencode-v1.template') }
  elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($tplV1 -replace '/', '\')) -PathType Leaf)) { [void]$errs15.Add(('template V1 do registry nao existe: ' + $tplV1)) }
  if ([string]::IsNullOrWhiteSpace($tplV2)) { [void]$errs15.Add('registry sem opencode-v2.template') }
  elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($tplV2 -replace '/', '\')) -PathType Leaf)) { [void]$errs15.Add(('template V2 do registry nao existe: ' + $tplV2)) }
  $keysV1 = @($reg15.runtimes.'opencode-v1'.managed_config_keys)
  foreach ($k in @('agent', 'permission', 'task', 'subagent_depth')) {
    if ($keysV1 -notcontains $k) { [void]$errs15.Add(('managed_config_keys V1 sem: ' + $k)) }
  }
  $keysV2 = @($reg15.runtimes.'opencode-v2'.managed_config_keys)
  foreach ($k in @('agents', 'permissions', 'experimental.subagent_depth')) {
    if ($keysV2 -notcontains $k) { [void]$errs15.Add(('managed_config_keys V2 sem: ' + $k)) }
  }
  if ($errs15.Count -eq 0) { Report-Ok '15 registry <-> templates' 'v1/v2 templates existem; managed_config_keys conferem com o shape' }
  else { Report-Fail '15 registry <-> templates' ($errs15 -join ' | ') }
}
catch { Report-Fail '15 registry <-> templates' $_.Exception.Message }

Write-Host ''
Write-Host ('CHECKS: ' + $script:nOk + ' OK / ' + $script:nBad + ' FAIL (total 15)')
if ($script:nBad -gt 0) { exit 1 }
exit 0
