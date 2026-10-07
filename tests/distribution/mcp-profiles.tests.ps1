<#!
.SYNOPSIS
    Suite dos MCP profiles (Fase 2B): schema + refs + risk.
.DESCRIPTION
    Valida source/registry/mcp-profiles.json (status validos, refs de MCP
    existentes no capabilities-v2.json, refs de agents validas em
    source/agents/*.md + build, risk valido) e a regra: profiles APPROVED
    referenciam apenas capabilities nao-CANDIDATE; PILOT/HOLD referenciam
    pilotos. Estilo distribution: 'ok - ...' / 'NOT OK - ...', exit 0/1.
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
$profPath = Join-Path $RepoRoot 'source\registry\mcp-profiles.json'
$regPath = Join-Path $RepoRoot 'source\registry\capabilities-v2.json'

Assert (Test-Path -LiteralPath $profPath -PathType Leaf) 'mcp-profiles.json existe'

$prof = $null
try {
  $prof = ([IO.File]::ReadAllText($profPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert ($null -ne $prof) 'profiles parseiam como JSON'
}
catch {
  Assert $false 'profiles parseiam como JSON' $_.Exception.Message
}

$reg = $null
try { $reg = ([IO.File]::ReadAllText($regPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json } catch { $reg = $null }
Assert ($null -ne $reg) 'capabilities-v2.json parseia (refs de MCP)'

if (($null -ne $prof) -and ($null -ne $reg)) {
  Assert (([string]$prof.schema_version) -ceq '1') 'profiles schema_version == 1'
  $profiles = @($prof.profiles)
  $pids = @($profiles | ForEach-Object { [string]$_.id })
  Assert (($pids.Count -gt 0) -and ($pids.Count -eq @($pids | Sort-Object -Unique).Count)) 'profile ids unicos' ('total=' + $pids.Count)

  $regIds = @($reg.capabilities | ForEach-Object { [string]$_.id })
  $regDesired = @{}
  foreach ($c in @($reg.capabilities)) { $regDesired[[string]$c.id] = [string]$c.status.desired }

  $agentNames = @('build')
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'source\agents') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $agentNames += [IO.Path]::GetFileNameWithoutExtension($f.Name)
  }

  $allowedSt = @('APPROVED', 'PILOT', 'HOLD')
  $allowedRisk = @('low', 'medium', 'high', 'critical', 'unknown')
  $errs = New-Object System.Collections.ArrayList
  foreach ($p in $profiles) {
    $profId = [string]$p.id
    if ($allowedSt -notcontains [string]$p.status) { [void]$errs.Add(($profId + ': status invalido')) }
    if ($allowedRisk -notcontains [string]$p.risk.level) { [void]$errs.Add(($profId + ': risk.level invalido')) }
    if ([string]::IsNullOrWhiteSpace([string]$p.description)) { [void]$errs.Add(($profId + ': description vazia')) }
    if (@($p.mcps).Count -eq 0) { [void]$errs.Add(($profId + ': sem mcps')) }
    if (@($p.agents).Count -eq 0) { [void]$errs.Add(($profId + ': sem agents')) }
    foreach ($m in @($p.mcps)) {
      if ($regIds -notcontains [string]$m) { [void]$errs.Add(($profId + ': mcp inexistente no registry: ' + [string]$m)) }
      else {
        $des = $regDesired[[string]$m]
        if (([string]$p.status -ceq 'APPROVED') -and ($des -ceq 'CANDIDATE')) {
          [void]$errs.Add(($profId + ': APPROVED com capability CANDIDATE: ' + [string]$m))
        }
      }
    }
    foreach ($a in @($p.agents)) {
      if ($agentNames -notcontains [string]$a) { [void]$errs.Add(($profId + ': agent invalido: ' + [string]$a)) }
    }
    if ((([string]$p.status -ceq 'PILOT') -or ([string]$p.status -ceq 'HOLD')) -and (@($p.mcps).Count -gt 2)) {
      [void]$errs.Add(($profId + ': PILOT/HOLD com mais de 2 mcps (superficie minima)'))
    }
  }
  Assert ($errs.Count -eq 0) 'schema + refs MCP/agents + regra APPROVED/PILOT' ($errs -join ' | ')

  # Nenhum MCP global desnecessario: APPROVED restrito ao nucleo + browser stack 2C; pilotos sao opt-in.
  # Fase 2C (decisao do operador 2026-10-07): testing APPROVED com playwright-mcp + chrome-devtools-mcp full.
  $approvedMcps = New-Object System.Collections.ArrayList
  foreach ($p in @($profiles | Where-Object { [string]$_.status -ceq 'APPROVED' })) {
    foreach ($m in @($p.mcps)) { if (-not $approvedMcps.Contains([string]$m)) { [void]$approvedMcps.Add([string]$m) } }
  }
  $expectedApproved = @('context7', 'jev', 'ai-memory', 'playwright-mcp', 'chrome-devtools-mcp')
  $d = Compare-Object $approvedMcps $expectedApproved
  Assert (($null -eq $d)) 'APPROVED restrito ao nucleo + browser stack 2C' ((($d | ForEach-Object { $_.InputObject }) -join ','))
}

Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }

