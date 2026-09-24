<#!
.SYNOPSIS
    Valida a consistencia interna do pacote opencode-orchestration (P6.3).
.DESCRIPTION
    10 checks, exit 0/1, uma linha [OK]/[FAIL] por check. PS 5.1 compativel.
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
  [void]$renderFiles.Add((Join-Path $RepoRoot 'templates\opencode.json.tmpl'))
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

# ---- 3. template agents x source/agents .md + frontmatter --------------------
try {
  $tmplRaw = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.json.tmpl')
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
  if ($errs3.Count -eq 0) { Report-Ok '3 template x agents' '17 blocos (build,title,15 workers com .md); 19 .md com frontmatter valido; build/title sem .md by design' }
  else { Report-Fail '3 template x agents' ($errs3 -join ' | ') }
}
catch { Report-Fail '3 template x agents' $_.Exception.Message }

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
  if ($errs4.Count -eq 0) { Report-Ok '4 allowlist build == agents' ('19 nomes, "*":deny + allows; bidirecional exato') }
  else { Report-Fail '4 allowlist build == agents' ($errs4 -join ' | ') }
}
catch { Report-Fail '4 allowlist build == agents' $_.Exception.Message }

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
      [void]$errs7.Add(('template com token nao-MODEL: ' + $t))
    }
  }
  if ($errs7.Count -eq 0) { Report-Ok '7 model pools' 'models.example chaves planner/cheap/strong; template usa so {{MODEL_*}}' }
  else { Report-Fail '7 model pools' ($errs7 -join ' | ') }
}
catch { Report-Fail '7 model pools' $_.Exception.Message }

# ---- 8. workers: task deny no template E deny explicito no frontmatter -------
try {
  $tRaw8 = Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.json.tmpl')
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
  if ($bad8.Count -eq 0) { Report-Ok '8 workers task deny (template + frontmatter)' ([string]$checked8 + ' checagem(ns): 15 workers deny no template; 19 .md com deny explicito; build/title fora da regra') }
  else { Report-Fail '8 workers task deny (template + frontmatter)' ($bad8 -join ' | ') }
}
catch { Report-Fail '8 workers task deny (template + frontmatter)' $_.Exception.Message }

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

Write-Host ''
Write-Host ('CHECKS: ' + $script:nOk + ' OK / ' + $script:nBad + ' FAIL (total 10)')
if ($script:nBad -gt 0) { exit 1 }
exit 0
