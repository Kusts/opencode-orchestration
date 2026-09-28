<#!
.SYNOPSIS
    Suite de paridade semantica V1<->V2 do AgentTranslator (Phase 3, V3.1).
.DESCRIPTION
    Harness [OK]/[FAIL] + exit 0/1, PS 5.1, ASCII puro. Descoberta automatica
    pelo run-v3-tests (scripts/runtime/*.tests.ps1). Nao modifica o repo
    (escreve so em TEMP nos testes de CLI).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AgentTranslator.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$agentsDir = Join-Path $repoRoot 'source\agents'
$renderCli = Join-Path $PSScriptRoot 'render-agent-frontmatter.ps1'
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }

$script:total = 0
$script:passed = 0
function Assert-Ok($condition, $name, $detail) {
  $script:total += 1
  if ($condition) {
    $script:passed += 1
    Write-Host ('[OK] ' + $name)
  }
  else {
    Write-Host ('[FAIL] ' + $name + ' -- ' + $detail)
  }
}

function Compare-CanonicalEqual($a, $b) {
  $diffs = New-Object System.Collections.ArrayList
  foreach ($k in @('Description', 'Mode', 'Model', 'Temperature', 'Edit', 'BashScalar', 'TaskScalar', 'Lifecycle', 'Visibility')) {
    if ([string]$a.$k -cne [string]$b.$k) { [void]$diffs.Add(($k + ': [' + [string]$a.$k + '] vs [' + [string]$b.$k + ']')) }
  }
  foreach ($k in @('HasDescription', 'HasMode', 'HasModel', 'HasTemperature', 'HasHidden', 'Hidden', 'EditPresent', 'HasCatchAll', 'TaskHasCatchAll', 'OrchPresent', 'BuildDelegable')) {
    if ([bool]$a.$k -cne [bool]$b.$k) { [void]$diffs.Add(($k + ': [' + [string]$a.$k + '] vs [' + [string]$b.$k + ']')) }
  }
  foreach ($k in @('CatchAllEffect', 'TaskCatchAllEffect', 'BashKind', 'TaskKind')) {
    if ([string]$a.$k -cne [string]$b.$k) { [void]$diffs.Add(($k + ': [' + [string]$a.$k + '] vs [' + [string]$b.$k + ']')) }
  }
  $norm = {
    param($items, $keyProp)
    $sorted = @($items | ForEach-Object { [string]$_.Pattern + '=' + [string]$_.Effect } | Sort-Object)
    return ($sorted -join '|')
  }
  if ((& $norm @($a.ShellRules)) -cne (& $norm @($b.ShellRules))) { [void]$diffs.Add('ShellRules diverge') }
  if ((& $norm @($a.TaskRules)) -cne (& $norm @($b.TaskRules))) { [void]$diffs.Add('TaskRules diverge') }
  $nx = {
    param($items)
    return ((@($items | ForEach-Object { [string]$_.Name + '=' + [string]$_.Effect } | Sort-Object)) -join '|')
  }
  if ((& $nx @($a.ExtraPermissions)) -cne (& $nx @($b.ExtraPermissions))) { [void]$diffs.Add('ExtraPermissions diverge') }
  $nl = {
    param($items)
    return ((@($items | ForEach-Object { [string]$_ } | Sort-Object)) -join '|')
  }
  if ((& $nl @($a.Preferred)) -cne (& $nl @($b.Preferred))) { [void]$diffs.Add('Preferred diverge') }
  if ((& $nl @($a.Forbidden)) -cne (& $nl @($b.Forbidden))) { [void]$diffs.Add('Forbidden diverge') }
  return @($diffs)
}

function Get-TestV2Rules {
  param($Canonical)
  $c = $Canonical
  $rules = New-Object System.Collections.ArrayList
  if ([bool]$c.EditPresent) {
    [void]$rules.Add(@{ Action = 'edit'; Resource = '*'; Effect = [string]$c.Edit })
  }
  foreach ($r in @(Get-OrderedV2ShellRules -Canonical $c)) { [void]$rules.Add($r) }
  foreach ($r in @(Get-OrderedV2TaskRules -Canonical $c)) { [void]$rules.Add($r) }
  return @($rules)
}

function Get-TestShellSamples {
  param($Canonical)
  $c = $Canonical
  $s = New-Object System.Collections.ArrayList
  [void]$s.Add('totally-unrelated-command-zz-7788')
  [void]$s.Add('git status')
  [void]$s.Add('npm run test')
  foreach ($r in @($c.ShellRules)) {
    if ([string]$r.Pattern -ceq '*') { continue }
    $inst = (([string]$r.Pattern).Replace('*', 'probe').Replace('?', 'q'))
    if (-not $s.Contains($inst)) { [void]$s.Add($inst) }
  }
  $unrelated = 'totally-unrelated-command-zz-7788'
  $hits = $false
  foreach ($r in @($c.ShellRules)) {
    if ([string]$r.Pattern -ceq '*') { continue }
    if (Test-GlobMatch -Pattern ([string]$r.Pattern) -Text $unrelated) { $hits = $true; break }
  }
  if ($hits) {
    [void]$s.Add('qq-no-match-here-zzz-9999')
  }
  return @($s)
}

function Get-ModelPool {
  param($Canonical)
  $c = $Canonical
  $m = [string]$c.Model
  if ($m.Contains('STRONG')) { return 'strong' }
  if ($m.Contains('CHEAP')) { return 'cheap' }
  return 'unknown'
}

function Invoke-ChildCli {
  param([string]$Arguments)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:psExe
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $script:repoRoot
  try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEnd()
  $e = $p.StandardError.ReadToEnd()
  $p.WaitForExit(120000)
  $code = $p.ExitCode
  try { $p.Close() } catch { }
  return @{ Code = $code; Out = ($o + "`n" + $e) }
}

$canonById = @{}
$files = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File | Sort-Object Name)

Assert-Ok ($files.Count -eq 19) '19 agentes canonicos' ('encontrados=' + $files.Count)

foreach ($f in $files) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $parsed = $null
  $err = ''
  try { $parsed = Read-AgentFileCanonical -Path $f.FullName }
  catch { $err = $_.Exception.Message }
  Assert-Ok (($null -ne $parsed) -and ([string]$parsed.Canonical.Id -ceq $stem)) ('parse ' + $stem) $err
  if ($null -ne $parsed) { $canonById[$stem] = $parsed.Canonical }
}

Assert-Ok (-not (Test-Path -LiteralPath (Join-Path $agentsDir 'build.md') -PathType Leaf)) 'build fora de source/agents' 'build.md existe'

foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $c = $canonById[$stem]
  $v1 = Convert-CanonicalToV1Frontmatter -Canonical $c
  $back = $null
  $err = ''
  try { $back = Convert-AgentFrontmatterYamlToCanonical -FrontmatterText $v1.Text -SourceName $stem }
  catch { $err = $_.Exception.Message }
  $diffs = @('parse falhou: ' + $err)
  if ($null -ne $back) { $diffs = @(Compare-CanonicalEqual $c $back) }
  Assert-Ok (($diffs.Count -eq 0)) ('roundtrip V1 ' + $stem) ($diffs -join ' | ')
}

foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $c = $canonById[$stem]
  $guardOk = $true
  $guardErr = ''
  try { Assert-NoAmbiguousOverlap -ShellRules @($c.ShellRules) | Out-Null }
  catch { $guardOk = $false; $guardErr = $_.Exception.Message }
  try { Assert-NoAmbiguousOverlap -ShellRules @($c.TaskRules) | Out-Null }
  catch { $guardOk = $false; $guardErr = $_.Exception.Message }
  Assert-Ok $guardOk ('overlap guard ' + $stem) $guardErr
  if (-not $guardOk) { continue }
  $rules = @(Get-TestV2Rules $c)
  $samples = @(Get-TestShellSamples $c)
  $eq = Test-PermissionSemanticEquivalence -Canonical $c -V2Rules $rules -ShellSamples $samples
  Assert-Ok ([bool]$eq.Equivalent) ('equivalencia V1/V2 ' + $stem) ((@($eq.Deviations) -join ' | '))
}

$allSubDeny = $true
$subDetail = ''
foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $rules = @(Get-TestV2Rules $canonById[$stem])
  $sub = @($rules | Where-Object { ([string]$_.Action -ceq 'subagent') -and ([string]$_.Resource -ceq '*') })
  if (($sub.Count -eq 0) -or ([string]$sub[0].Effect -cne 'deny')) {
    $allSubDeny = $false
    $subDetail += $stem + ' '
  }
}
Assert-Ok $allSubDeny '19/19 com subagent deny no V2' $subDetail

$t = $canonById['tester']
Assert-Ok (([string]$t.Edit -ceq 'deny') -and ([bool]$t.EditPresent)) 'tester edit deny' ([string]$t.Edit)
Assert-Ok ((@($t.ShellRules)).Count -gt 10) 'tester shell map amplo' ('rules=' + (@($t.ShellRules)).Count)
Assert-Ok ([string]$t.BashKind -ceq 'map') 'tester bash em mapa' ([string]$t.BashKind)
Assert-Ok ([bool]$t.HasCatchAll -and ([string]$t.CatchAllEffect -ceq 'deny')) 'tester catch-all deny' ([string]$t.CatchAllEffect)

foreach ($stem in @('reviewer', 'security-reviewer', 'architect')) {
  $c = $canonById[$stem]
  Assert-Ok ([string]$c.Model -ceq '{{MODEL_STRONG}}' ) ($stem + ' MODEL_STRONG canonico') ([string]$c.Model)
  $v2 = Convert-CanonicalToV2Frontmatter -Canonical $c
  Assert-Ok ([string]$v2.Text -like '*{{MODEL_STRONG}}*') ($stem + ' MODEL_STRONG no V2') 'token ausente'
}

$tempOmitOk = $true
$tempDetail = ''
foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $c = $canonById[$stem]
  if (-not [bool]$c.HasTemperature) { $tempOmitOk = $false; $tempDetail += ($stem + ':sem-temperature ') ; continue }
  $v2 = Convert-CanonicalToV2Frontmatter -Canonical $c
  if (@($v2.OmittedFields) -notcontains 'temperature') { $tempOmitOk = $false; $tempDetail += ($stem + ':sem-omitted ') }
  if ([string]$v2.Text -like '*temperature*') { $tempOmitOk = $false; $tempDetail += ($stem + ':vazou-temperature ') }
  $v1 = Convert-CanonicalToV1Frontmatter -Canonical $c
  if ([string]$v1.Text -notlike '*temperature*') { $tempOmitOk = $false; $tempDetail += ($stem + ':v1-sem-temperature ') }
}
Assert-Ok $tempOmitOk 'temperature omitida no V2, presente no V1 (19/19)' $tempDetail

$orchDropOk = $true
$orchDetail = ''
foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $v2 = Convert-CanonicalToV2Frontmatter -Canonical $canonById[$stem]
  if (@($v2.DroppedFields) -notcontains 'orchestration') { $orchDropOk = $false; $orchDetail += ($stem + ' ') }
  if ([string]$v2.Text -like '*orchestration*') { $orchDropOk = $false; $orchDetail += ($stem + ':vazou ') }
}
Assert-Ok $orchDropOk 'orchestration fora do frontmatter V2 (19/19)' $orchDetail

$rx = $canonById['researcher']
$rxV2 = Convert-CanonicalToV2Frontmatter -Canonical $rx
Assert-Ok ((@($rx.ExtraPermissions)).Count -eq 2) 'researcher tem 2 permissoes extras' ((@($rx.ExtraPermissions)).Count)
Assert-Ok ((@($rxV2.DroppedFields) -contains 'permission.webfetch') -and (@($rxV2.DroppedFields) -contains 'permission.websearch')) 'researcher extras em DroppedFields' ((@($rxV2.DroppedFields) -join ','))
Assert-Ok ([string]$rxV2.Text -notlike '*webfetch*') 'researcher V2 sem webfetch' 'vazou'

$synthAmbig = @(
  @{ Pattern = 'git st*'; Effect = 'ask' },
  @{ Pattern = 'git status'; Effect = 'deny' }
)
$threwAmbig = $false
$msgAmbig = ''
try { Assert-NoAmbiguousOverlap -ShellRules $synthAmbig | Out-Null }
catch { $threwAmbig = $true; $msgAmbig = $_.Exception.Message }
Assert-Ok $threwAmbig 'sintetico: overlap ambiguo falha' 'nao falhou'
Assert-Ok ($msgAmbig -like '*ambiguous-permission-overlap*') 'sintetico: erro e ambiguous-permission-overlap' $msgAmbig

$synthCanon = @{
  Description = 'synth'; Mode = 'subagent'; Model = '{{MODEL_CHEAP}}'
  HasTemperature = $false; Temperature = ''
  HasHidden = $false; Hidden = $false
  EditPresent = $true; Edit = 'deny'
  BashKind = 'map'; BashScalar = ''
  ShellRules = $synthAmbig; HasCatchAll = $true; CatchAllEffect = 'deny'
  TaskKind = 'scalar'; TaskScalar = 'deny'
  TaskRules = @(); TaskHasCatchAll = $false; TaskCatchAllEffect = ''
  ExtraPermissions = @()
  OrchPresent = $false; BuildDelegable = $false; Lifecycle = ''; Visibility = ''
  Preferred = @(); Forbidden = @()
}
$threwBuild = $false
$msgBuild = ''
try { Convert-CanonicalToV2Frontmatter -Canonical $synthCanon | Out-Null }
catch { $threwBuild = $true; $msgBuild = $_.Exception.Message }
Assert-Ok $threwBuild 'sintetico: build V2 falha em overlap' 'nao falhou'
Assert-Ok ($msgBuild -like '*ambiguous-permission-overlap*') 'sintetico: build falha com overlap code' $msgBuild

# --- V31-R1 F2: guard conservadoramente completo ---
$f2a = @(
  @{ Pattern = 'foo *bar'; Effect = 'deny' },
  @{ Pattern = 'foo baz*'; Effect = 'allow' }
)
$threwF2a = $false
$msgF2a = ''
try { Assert-NoAmbiguousOverlap -ShellRules $f2a | Out-Null }
catch { $threwF2a = $true; $msgF2a = $_.Exception.Message }
Assert-Ok $threwF2a 'F2: foo *bar x foo baz* => throw' 'nao falhou'
Assert-Ok (($msgF2a -like '*ambiguous-permission-overlap*') -and ($msgF2a -like '*foo bazbar*')) 'F2: testemunha foo bazbar' $msgF2a

$f2b = @(
  @{ Pattern = 'npm *'; Effect = 'allow' },
  @{ Pattern = 'git status *'; Effect = 'allow' }
)
$threwF2b = $false
$errF2b = ''
try { Assert-NoAmbiguousOverlap -ShellRules $f2b | Out-Null }
catch { $threwF2b = $true; $errF2b = $_.Exception.Message }
Assert-Ok (-not $threwF2b) 'F2: npm * x git status * (mesmo efeito) => ok' $errF2b

$f2b2 = @(
  @{ Pattern = 'npm *'; Effect = 'deny' },
  @{ Pattern = 'git status *'; Effect = 'allow' }
)
$threwF2b2 = $false
$errF2b2 = ''
try { Assert-NoAmbiguousOverlap -ShellRules $f2b2 | Out-Null }
catch { $threwF2b2 = $true; $errF2b2 = $_.Exception.Message }
Assert-Ok (-not $threwF2b2) 'F2: prefixos disjuntos com efeitos distintos => ok (short-circuit)' $errF2b2

$f2c = @(
  @{ Pattern = 'git *'; Effect = 'deny' },
  @{ Pattern = 'git status *'; Effect = 'allow' }
)
$threwF2c = $false
$msgF2c = ''
try { Assert-NoAmbiguousOverlap -ShellRules $f2c | Out-Null }
catch { $threwF2c = $true; $msgF2c = $_.Exception.Message }
Assert-Ok $threwF2c 'F2: git * x git status * => throw' 'nao falhou'
Assert-Ok ($msgF2c -like '*ambiguous-permission-overlap*') 'F2: git */status erro e overlap' $msgF2c

# --- V31-R1 F3: backslash escapado no YAML double-quoted ---
$tV2 = Convert-CanonicalToV2Frontmatter -Canonical $canonById['tester']
Assert-Ok ([string]$tV2.Text -like '*{{REPO_DIR}}\\scripts*') 'F3: tester V2 com \\ duplicado' 'pattern sem escape'
$yamlEscOk = $true
$yamlEscDetail = ''
$allowedEsc = @('0', 'a', 'b', 't', 'n', 'v', 'f', 'r', 'e', ' ', '"', '\', '/', 'N', '_', 'L', 'P', 'x', 'u', 'U')
foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $vv = Convert-CanonicalToV2Frontmatter -Canonical $canonById[$stem]
  foreach ($ln in @(([string]$vv.Text -split "`n"))) {
    $m = [regex]::Match($ln, '^\s*(resource|description): "(?<inner>.*)"\s*$')
    if (-not $m.Success) { continue }
    $inner = $m.Groups['inner'].Value
    for ($ci = 0; $ci -lt $inner.Length; $ci++) {
      if ($inner.Substring($ci, 1) -ceq '\') {
        if (($ci + 1) -ge $inner.Length) { $yamlEscOk = $false; $yamlEscDetail += ($stem + ':backslash-final '); break }
        $nx = $inner.Substring($ci + 1, 1)
        if ($allowedEsc -cnotcontains $nx) { $yamlEscOk = $false; $yamlEscDetail += ($stem + ':escape-invalido ') ; break }
        $ci += 1
      }
    }
  }
}
Assert-Ok $yamlEscOk 'F3: sem escape YAML invalido nos 19 renders V2' $yamlEscDetail

$allowFirst = @(
  @{ Pattern = '*'; Effect = 'allow' },
  @{ Pattern = 'rm -rf *'; Effect = 'deny' }
)
$ordRules = @(Get-OrderedV2ShellRules -Canonical @{
  BashKind = 'map'; ShellRules = $allowFirst
})
$orderOk = ((@($ordRules)).Count -eq 2) -and ([string]$ordRules[0].Resource -ceq '*') -and ([string]$ordRules[0].Effect -ceq 'allow') -and ([string]$ordRules[1].Effect -ceq 'deny')
Assert-Ok $orderOk 'allow-* primeiro, deny especifico depois' ((@($ordRules) | ForEach-Object { [string]$_.Resource + '=' + [string]$_.Effect }) -join ' | ')
$eV1 = Get-V1RuleEffect -Rules $allowFirst -HasCatchAll $true -CatchAllEffect 'allow' -Command 'rm -rf /tmp/x'
$eV2 = Get-V2RuleEffect -V2Rules $ordRules -Action 'shell' -Command 'rm -rf /tmp/x'
Assert-Ok (($eV1 -ceq 'deny') -and ($eV2 -ceq 'deny')) 'especifico deny vence nos dois' ("V1=$eV1 V2=$eV2")
$eV1b = Get-V1RuleEffect -Rules $allowFirst -HasCatchAll $true -CatchAllEffect 'allow' -Command 'echo hi'
$eV2b = Get-V2RuleEffect -V2Rules $ordRules -Action 'shell' -Command 'echo hi'
Assert-Ok (($eV1b -ceq 'allow') -and ($eV2b -ceq 'allow')) 'catch-all allow vale para resto' ("V1=$eV1b V2=$eV2b")

Write-Host ''
Write-Host 'SNAPSHOT SEMANTICO V1 vs V2 (id | delegable | pool | edit | subagent | shell a/k/d | v2 a/k/d):'
$snapOk = $true
$snapDetail = ''
foreach ($stem in @($canonById.Keys | Sort-Object)) {
  $c = $canonById[$stem]
  $pool = Get-ModelPool $c
  $v1a = @(@($c.ShellRules) | Where-Object { [string]$_.Effect -ceq 'allow' }).Count
  $v1k = @(@($c.ShellRules) | Where-Object { [string]$_.Effect -ceq 'ask' }).Count
  $v1d = @(@($c.ShellRules) | Where-Object { [string]$_.Effect -ceq 'deny' }).Count
  if ([string]$c.BashKind -ceq 'scalar') {
    $v1a = 0; $v1k = 0; $v1d = 0
    if ([string]$c.BashScalar -ceq 'allow') { $v1a = 1 }
    elseif ([string]$c.BashScalar -ceq 'ask') { $v1k = 1 }
    else { $v1d = 1 }
  }
  $rules = @(Get-TestV2Rules $c)
  $sh = @($rules | Where-Object { [string]$_.Action -ceq 'shell' })
  $v2a = @($sh | Where-Object { [string]$_.Effect -ceq 'allow' }).Count
  $v2k = @($sh | Where-Object { [string]$_.Effect -ceq 'ask' }).Count
  $v2d = @($sh | Where-Object { [string]$_.Effect -ceq 'deny' }).Count
  $sub = @($rules | Where-Object { [string]$_.Action -ceq 'subagent' -and [string]$_.Resource -ceq '*' })
  $subEff = ''
  if ($sub.Count -gt 0) { $subEff = [string]$sub[0].Effect }
  $rc = 'none'
  if ((@($c.Preferred)).Count -gt 0) { $rc = [string]$c.Preferred[0] }
  Write-Host ('  ' + $stem + ' | deleg=' + [string]$c.BuildDelegable + ' | ' + $pool + ' | edit=' + [string]$c.Edit + ' | sub=' + $subEff + ' | ' + $v1a + '/' + $v1k + '/' + $v1d + ' | ' + $v2a + '/' + $v2k + '/' + $v2d + ' | ' + $rc)
  if (($v1a -ne $v2a) -or ($v1k -ne $v2k) -or ($v1d -ne $v2d)) {
    $snapOk = $false
    $snapDetail += ($stem + ' ')
  }
  $v1sub = 'deny'
  if ([string]$c.TaskKind -ceq 'scalar') { $v1sub = [string]$c.TaskScalar }
  if ($v1sub -cne $subEff) {
    $snapOk = $false
    $snapDetail += ($stem + ':sub ')
  }
  if (([string]$c.Edit -cne '') -and ([bool]$c.EditPresent)) {
    $ed = @($rules | Where-Object { [string]$_.Action -ceq 'edit' })
    if (($ed.Count -eq 0) -or ([string]$ed[0].Effect -cne [string]$c.Edit)) {
      $snapOk = $false
      $snapDetail += ($stem + ':edit ')
    }
  }
}
Assert-Ok $snapOk 'snapshot: intent igual V1/V2 (19/19)' $snapDetail

$badFm = @('description: "x"', 'mode: subagent', 'model: {{MODEL_CHEAP}}', 'temperature: 0.2') -join "`n"
$threwBad = $false
$msgBad = ''
try { Convert-AgentFrontmatterYamlToCanonical -FrontmatterText $badFm -SourceName 'bad' | Out-Null }
catch { $threwBad = $true; $msgBad = $_.Exception.Message }
Assert-Ok $threwBad 'malformed: sem permission falha' 'nao falhou'
Assert-Ok ($msgBad -like '*sem bloco permission*') 'malformed: erro claro (permission)' $msgBad

$cliBase = Join-Path ([IO.Path]::GetTempPath()) ('agent-xlate-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cliBase -Force | Out-Null
$cliAgents = Join-Path $cliBase 'agents'
New-Item -ItemType Directory -Path $cliAgents -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $cliAgents 'bad.md'), ('---' + "`n" + $badFm + "`n" + '---' + "`n" + 'corpo' + "`n"), [Text.UTF8Encoding]::new($false))
$cliOut = Join-Path $cliBase 'out'
$r = Invoke-ChildCli -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $renderCli + '" -AgentsDir "' + $cliAgents + '" -Runtime V2 -OutDir "' + $cliOut + '"')
Assert-Ok ([int]$r.Code -eq 6) 'CLI: malformed => exit 6' ('exit=' + [string]$r.Code + ' out=' + [string]$r.Out)
Assert-Ok (([string]$r.Out -like '*TRANSLATION FAILED*') -and ([string]$r.Out -notlike '*Exception*')) 'CLI: erro claro sem stack' ([string]$r.Out)
try { if (Test-Path -LiteralPath $cliBase) { Remove-Item -LiteralPath $cliBase -Recurse -Force -ErrorAction SilentlyContinue } } catch { }

# --- V31-R1 F4: two-phase (falha no meio nao publica parcial) ---
$cliBase2 = Join-Path ([IO.Path]::GetTempPath()) ('agent-xlate-2phase-' + [guid]::NewGuid().ToString('N'))
$cliAgents2 = Join-Path $cliBase2 'agents'
$cliOut2 = Join-Path $cliBase2 'out'
New-Item -ItemType Directory -Path $cliAgents2 -Force | Out-Null
New-Item -ItemType Directory -Path $cliOut2 -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $agentsDir 'coder.md') -Destination (Join-Path $cliAgents2 'a-coder.md') -Force
Copy-Item -LiteralPath (Join-Path $agentsDir 'explorer.md') -Destination (Join-Path $cliAgents2 'b-explorer.md') -Force
[IO.File]::WriteAllText((Join-Path $cliAgents2 'c-bad.md'), ('---' + "`n" + $badFm + "`n" + '---' + "`n" + 'corpo' + "`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $cliOut2 'sentinel.txt'), 'sentinel', [Text.UTF8Encoding]::new($false))
$r2 = Invoke-ChildCli -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $renderCli + '" -AgentsDir "' + $cliAgents2 + '" -Runtime V2 -OutDir "' + $cliOut2 + '"')
Assert-Ok ([int]$r2.Code -eq 6) 'F4: 2 validos + 1 malformado => exit 6' ('exit=' + [string]$r2.Code + ' out=' + [string]$r2.Out)
$left2 = @(Get-ChildItem -LiteralPath $cliOut2 -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
$onlySentinel = (($left2.Count -eq 1) -and ($left2[0] -ceq 'sentinel.txt'))
Assert-Ok $onlySentinel 'F4: saida sem arquivo novo (so sentinel)' ($left2 -join ',')
try { if (Test-Path -LiteralPath $cliBase2) { Remove-Item -LiteralPath $cliBase2 -Recurse -Force -ErrorAction SilentlyContinue } } catch { }

Write-Host ''
Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + $script:total + ' passed')
if ($script:passed -ne $script:total) { exit 1 }
exit 0
