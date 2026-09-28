<#!
.SYNOPSIS
    Traducao DETERMINISTICA do frontmatter canonico V1 (source/agents/*.md)
    para frontmatter nativo V2. Lib PURA: sem rede, sem binario, sem escrita.
    PS 5.1 compativel. ASCII puro.
.DESCRIPTION
    Fonte canonica: 19 arquivos source/agents/*.md com frontmatter YAML V1
    (description, mode, model, temperature, permission{edit,bash,task},
    orchestration{...}). Esta lib converte para um objeto canonico em memoria
    e dai emite YAML V1 (roundtrip) ou YAML V2 (permissions array nativo).

    REGRA DE PRECEDENCIA V1 ASSUMIDA (documentada, nao confirmada em doc
    oficial do runtime 1.x): para action shell e comando S, o efeito V1 e:
      1. dentre os padroes ESPECIFICOS (resource != "*") que casam S pelo glob
         (* = qualquer sequencia, ? = um char, case-insensitive), vence o de
         MAIOR comprimento (mais especifico);
      2. empate de comprimento => vence o mais restritivo (deny > ask > allow);
      3. nenhum especifico casa => vale o catch-all "*" se presente;
      4. sem catch-all => deny (fail closed).
    REGRA DE ORDENACAO V2 (last-match-wins no runtime V2): o emissor ordena
    catch-all "*" PRIMEIRO e especificos DEPOIS (alfabetico estavel, Ordinal).
    Sobreposicao ambigua entre especificos com efeitos distintos (testemunha
    encontrada) => Assert-NoAmbiguousOverlap lanca 'ambiguous-permission-overlap'
    e Convert-CanonicalToV2Frontmatter FALHA O BUILD (fail closed).
    Sobreposicao entre especificos de MESMO efeito e ordem-indiferente.
    Mapeamento de actions: edit->edit, bash->shell, task->subagent.
    temperature NAO e campo nativo V2: omitida no render V2 (OmittedFields).
    orchestration e metadata do PACOTE (ja indexada pelo capability-registry):
    nao vai para o frontmatter V2 (DroppedFields). Permissoes extras escalares
    (ex. webfetch/websearch do researcher) nao tem action V2 valida: vao para
    DroppedFields como permission.<nome>.
#>

$ErrorActionPreference = 'Stop'

# ---- helpers de efeito/glob (puros) -----------------------------------------

function Get-EffectRank {
  param([string]$Effect = '')
  if ($Effect -ceq 'deny') { return 3 }
  if ($Effect -ceq 'ask') { return 2 }
  if ($Effect -ceq 'allow') { return 1 }
  return 0
}

function Test-ValidEffect {
  param([string]$Effect = '')
  return (($Effect -ceq 'allow') -or ($Effect -ceq 'deny') -or ($Effect -ceq 'ask'))
}

function Convert-GlobToRegex {
  param([string]$Pattern = '')
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('^')
  foreach ($ch in ([string]$Pattern).ToCharArray()) {
    if ($ch -eq '*') { [void]$sb.Append('.*') }
    elseif ($ch -eq '?') { [void]$sb.Append('.') }
    else { [void]$sb.Append([regex]::Escape([string]$ch)) }
  }
  [void]$sb.Append('$')
  return $sb.ToString()
}

function Test-GlobMatch {
  param([string]$Pattern = '', [string]$Text = '')
  $p = [string]$Pattern
  if ($p -ceq '*') { return $true }
  $rx = Convert-GlobToRegex -Pattern $p
  return [regex]::IsMatch([string]$Text, $rx, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Format-YamlDoubleQuoted {
  param([string]$Value = '')
  # Replace ordinal (nao regex): '\' -> '\\' e '"' -> '\"'. Emissao valida
  # em YAML double-quoted (ex.: '\scripts' vira '\\scripts'; finding V31-R1 F3).
  $e = ([string]$Value).Replace('\', '\\')
  $e = $e.Replace('"', '\"')
  return ('"' + $e + '"')
}

function Remove-YamlQuotes {
  param([string]$Value = '')
  $v = ([string]$Value).Trim()
  if (($v.Length -ge 2) -and ($v.StartsWith('"')) -and ($v.EndsWith('"'))) {
    $inner = $v.Substring(1, $v.Length - 2)
    $inner = $inner.Replace('\"', '"')
    $inner = $inner.Replace('\\', '\')
    return $inner
  }
  if (($v.Length -ge 2) -and ($v.StartsWith("'")) -and ($v.EndsWith("'"))) {
    return $v.Substring(1, $v.Length - 2)
  }
  return $v
}

function New-WitnessSamples {
  param([string]$Pattern = '')
  $p = [string]$Pattern
  $out = New-Object System.Collections.ArrayList
  if (($p -ceq '*') -or (-not ($p.Contains('*') -or $p.Contains('?')))) {
    [void]$out.Add($p)
    return @($out)
  }
  [void]$out.Add(($p.Replace('*', '').Replace('?', 'Q')))
  [void]$out.Add(($p.Replace('*', 'X').Replace('?', 'Q')))
  [void]$out.Add(($p.Replace('*', '--probe-value-zzz').Replace('?', 'Q')))
  return @($out)
}

function Get-GlobLiteralPrefix {
  param([string]$Pattern = '')
  # Literal inicial antes do primeiro wildcard ('*' ou '?'). Vazio quando o
  # pattern comeca com wildcard. Usado pelo short-circuit de disjuncao.
  $p = [string]$Pattern
  $cut = $p.Length
  $iS = $p.IndexOf('*')
  if (($iS -ge 0) -and ($iS -lt $cut)) { $cut = $iS }
  $iQ = $p.IndexOf('?')
  if (($iQ -ge 0) -and ($iQ -lt $cut)) { $cut = $iQ }
  return $p.Substring(0, $cut)
}

function Get-GlobSegments {
  param([string]$Pattern = '')
  # Fatias literais do glob (split em '*' e '?'). Usadas como segmentos
  # candidatos na geracao cruzada de testemunhas.
  return @([regex]::Split([string]$Pattern, '[*?]'))
}

function Get-GlobWitnesses {
  param([string]$Pattern = '', [string[]]$Candidates = @())
  # Produto estruturado: cada '*' vira um segmento candidato, cada '?' vira
  # um char ('Q'). Retorna $null quando as combinacoes excedem 64: o
  # chamador falha conservadoramente (disjuncao nao demonstrada).
  $p = [string]$Pattern
  $flat = $p.Replace('?', 'Q')
  $parts = @([regex]::Split($flat, '\*'))
  $stars = $parts.Count - 1
  if ($stars -le 0) { return @($flat) }
  $cands = @($Candidates)
  if ($cands.Count -eq 0) { $cands = @('', 'X', '--probe-value-zzz') }
  $total = 1
  for ($k = 0; $k -lt $stars; $k++) { $total = $total * $cands.Count }
  if ($total -gt 64) { return $null }
  $out = New-Object System.Collections.ArrayList
  for ($n = 0; $n -lt $total; $n++) {
    $t = $n
    $built = [string]$parts[0]
    for ($k = 0; $k -lt $stars; $k++) {
      $ci = $t % $cands.Count
      $t = [math]::Floor($t / $cands.Count)
      $built = $built + [string]$cands[$ci] + [string]$parts[$k + 1]
    }
    [void]$out.Add($built)
  }
  return @($out)
}

# ---- split frontmatter/corpo (puro sobre texto) -------------------------------

function Split-AgentFileText {
  param([string]$RawText = '', [string]$SourceName = 'agent')
  $norm = (([string]$RawText -replace "`r`n", "`n") -replace "`r", "`n")
  $lines = @($norm -split "`n")
  if (($lines.Count -eq 0) -or ($lines[0] -notmatch '^---\s*$')) {
    throw ('AgentTranslator: ' + $SourceName + ': frontmatter ausente (primeira linha deve ser ---).')
  }
  $close = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(---|\.\.\.)\s*$') { $close = $i; break }
  }
  if ($close -lt 0) {
    throw ('AgentTranslator: ' + $SourceName + ': frontmatter sem fechamento (--- final ausente).')
  }
  $fmLines = @()
  if ($close -gt 1) { $fmLines = @($lines[1..($close - 1)]) }
  $body = ''
  if (($close + 1) -lt $lines.Count) {
    $body = (($lines[($close + 1)..($lines.Count - 1)] -join "`n") + "`n")
  }
  else {
    $body = ''
  }
  return @{ FrontmatterText = ($fmLines -join "`n"); Body = $body }
}

# ---- parse V1 -> canonico ------------------------------------------------------

function Convert-AgentFrontmatterYamlToCanonical {
  param([string]$FrontmatterText = '', [string]$SourceName = 'agent')
  $id = [string]$SourceName
  $fail = {
    param([string]$Msg)
    throw ('AgentTranslator: ' + $id + ': ' + $Msg)
  }
  $lines = @(([string]$FrontmatterText -replace "`r`n", "`n" -replace "`r", "`n") -split "`n")
  $c = @{
    Id = $id; Description = ''; Mode = ''; Model = ''
    HasDescription = $false; HasMode = $false; HasModel = $false
    HasTemperature = $false; Temperature = ''
    HasHidden = $false; Hidden = $false
    EditPresent = $false; Edit = ''
    BashKind = 'absent'; BashScalar = ''
    ShellRules = @(); HasCatchAll = $false; CatchAllEffect = ''
    TaskKind = 'absent'; TaskScalar = ''
    TaskRules = @(); TaskHasCatchAll = $false; TaskCatchAllEffect = ''
    ExtraPermissions = @()
    OrchPresent = $false; BuildDelegable = $false
    Lifecycle = ''; Visibility = ''
    Preferred = @(); Forbidden = @()
  }
  $topSeen = @{}
  $permSeen = @{}
  $bashSeen = @{}
  $taskSeen = @{}
  $orchSeen = @{}
  $capSeen = @{}
  $state = 'top'
  $curList = ''
  $lineno = 0
  foreach ($raw in $lines) {
    $lineno += 1
    $line = [string]$raw
    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s*#') { continue }
    $ind = 0
    $mInd = [regex]::Match($line, '^( *)')
    if ($mInd.Success) { $ind = $mInd.Groups[1].Value.Length }
    if ($line -match '^\s*-\s+') {
      if (($state -ceq 'caplist') -and ($ind -ge 4)) {
        $item = ($line -replace '^\s*-\s+', '').Trim()
        $item = Remove-YamlQuotes -Value $item
        if ($curList -ceq 'preferred') { $c.Preferred = @($c.Preferred) + @($item) }
        elseif ($curList -ceq 'forbidden') { $c.Forbidden = @($c.Forbidden) + @($item) }
        else { throw (& $fail ('linha ' + $lineno + ': item de lista fora de preferred/forbidden.')) }
        continue
      }
      throw (& $fail ('linha ' + $lineno + ': item de lista inesperado fora de capabilities.'))
    }
    if ($ind -eq 0) { $state = 'top' }
    elseif ($ind -eq 2) {
      if ($state -ceq 'bashmap') { $state = 'perm' }
      elseif ($state -ceq 'taskmap') { $state = 'perm' }
      elseif (($state -ceq 'caplist') -or ($state -ceq 'cap')) { $state = 'orch' }
    }
    elseif ($ind -eq 4) {
      if ($state -ceq 'caplist') { $state = 'cap' }
    }
    $kvKey = $null
    $kvVal = $null
    $mQ = [regex]::Match($line, '^\s*"(?<k>(?:[^"\\]|\\.)*)"\s*:\s*(?<v>.*)$')
    if ($mQ.Success) {
      $rawKey = [string]$mQ.Groups['k'].Value
      $kvKey = $rawKey.Replace('\"', '"').Replace('\\', '\')
      $kvVal = $mQ.Groups['v'].Value.Trim()
    }
    else {
      $mK = [regex]::Match($line, '^\s*(?<k>[A-Za-z0-9_][A-Za-z0-9_.?/*-]*)\s*:\s*(?<v>.*)$')
      if (-not $mK.Success) {
        throw (& $fail ('linha ' + $lineno + ': sintaxe invalida (esperado chave: valor).'))
      }
      $kvKey = $mK.Groups['k'].Value
      $kvVal = $mK.Groups['v'].Value.Trim()
    }
    if ($state -ceq 'top') {
      if ($ind -ne 0) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada no topo.')) }
      if ($topSeen.ContainsKey($kvKey)) { throw (& $fail ("chave de topo duplicada: '$kvKey'.")) }
      $topSeen[$kvKey] = $true
      if ($kvKey -ceq 'description') {
        $c.Description = Remove-YamlQuotes -Value $kvVal
        $c.HasDescription = $true
      }
      elseif ($kvKey -ceq 'mode') {
        $c.Mode = Remove-YamlQuotes -Value $kvVal
        $c.HasMode = $true
      }
      elseif ($kvKey -ceq 'model') {
        $c.Model = Remove-YamlQuotes -Value $kvVal
        $c.HasModel = $true
      }
      elseif ($kvKey -ceq 'hidden') {
        $lv = (Remove-YamlQuotes -Value $kvVal).ToLowerInvariant()
        if (($lv -ceq 'true') -or ($lv -ceq 'false')) {
          $c.HasHidden = $true
          $c.Hidden = ($lv -ceq 'true')
        }
        else { throw (& $fail ('hidden nao-booleano: ' + $kvVal)) }
      }
      elseif ($kvKey -ceq 'temperature') {
        $tv = Remove-YamlQuotes -Value $kvVal
        if ($tv -notmatch '^\d+(\.\d+)?$') { throw (& $fail ('temperature invalida: ' + $kvVal)) }
        $c.HasTemperature = $true
        $c.Temperature = $tv
      }
      elseif ($kvKey -ceq 'permission') {
        if ($kvVal -ne '') { throw (& $fail 'bloco permission inline rejeitado (use mapping).') }
        $state = 'perm'
      }
      elseif ($kvKey -ceq 'orchestration') {
        if ($kvVal -ne '') { throw (& $fail 'bloco orchestration inline rejeitado (use mapping).') }
        $c.OrchPresent = $true
        $state = 'orch'
      }
      else { throw (& $fail ("chave de topo desconhecida: '$kvKey'.")) }
      continue
    }
    if ($state -ceq 'perm') {
      if ($ind -ne 2) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada em permission.')) }
      if ($permSeen.ContainsKey($kvKey)) { throw (& $fail ("chave duplicada em permission: '$kvKey'.")) }
      $permSeen[$kvKey] = $true
      if ($kvKey -ceq 'edit') {
        if ($kvVal -eq '') { throw (& $fail 'permission.edit vazio (esperado allow|deny|ask).') }
        $ev = Remove-YamlQuotes -Value $kvVal
        if (-not (Test-ValidEffect -Effect $ev)) { throw (& $fail ('permission.edit invalido: ' + $kvVal)) }
        $c.EditPresent = $true
        $c.Edit = $ev
      }
      elseif ($kvKey -ceq 'bash') {
        if ($kvVal -eq '') {
          $c.BashKind = 'map'
          $c.ShellRules = @()
          $state = 'bashmap'
        }
        else {
          $bv = Remove-YamlQuotes -Value $kvVal
          if (-not (Test-ValidEffect -Effect $bv)) { throw (& $fail ('permission.bash invalido: ' + $kvVal)) }
          $c.BashKind = 'scalar'
          $c.BashScalar = $bv
        }
      }
      elseif ($kvKey -ceq 'task') {
        if ($kvVal -eq '') {
          $c.TaskKind = 'map'
          $c.TaskRules = @()
          $state = 'taskmap'
        }
        else {
          $tv2 = Remove-YamlQuotes -Value $kvVal
          if (-not (Test-ValidEffect -Effect $tv2)) { throw (& $fail ('permission.task invalido: ' + $kvVal)) }
          $c.TaskKind = 'scalar'
          $c.TaskScalar = $tv2
        }
      }
      else {
        if ($kvVal -eq '') { throw (& $fail ("permission extra com mapa nao suportada: '$kvKey'.")) }
        $xv = Remove-YamlQuotes -Value $kvVal
        if (-not (Test-ValidEffect -Effect $xv)) { throw (& $fail ("permission extra invalida: '$kvKey': " + $kvVal)) }
        $c.ExtraPermissions = @($c.ExtraPermissions) + @(@{ Name = $kvKey; Effect = $xv })
      }
      continue
    }
    if ($state -ceq 'bashmap') {
      if ($ind -lt 4) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada no mapa bash.')) }
      if ($bashSeen.ContainsKey($kvKey)) { throw (& $fail ("padrao bash duplicado: '$kvKey'.")) }
      $bashSeen[$kvKey] = $true
      $bv2 = Remove-YamlQuotes -Value $kvVal
      if (-not (Test-ValidEffect -Effect $bv2)) { throw (& $fail ("efeito bash invalido para '$kvKey': " + $kvVal)) }
      if ($kvKey -ceq '*') {
        $c.HasCatchAll = $true
        $c.CatchAllEffect = $bv2
      }
      $c.ShellRules = @($c.ShellRules) + @(@{ Pattern = $kvKey; Effect = $bv2 })
      continue
    }
    if ($state -ceq 'taskmap') {
      if ($ind -lt 4) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada no mapa task.')) }
      if ($taskSeen.ContainsKey($kvKey)) { throw (& $fail ("padrao task duplicado: '$kvKey'.")) }
      $taskSeen[$kvKey] = $true
      $tv3 = Remove-YamlQuotes -Value $kvVal
      if (-not (Test-ValidEffect -Effect $tv3)) { throw (& $fail ("efeito task invalido para '$kvKey': " + $kvVal)) }
      if ($kvKey -ceq '*') {
        $c.TaskHasCatchAll = $true
        $c.TaskCatchAllEffect = $tv3
      }
      $c.TaskRules = @($c.TaskRules) + @(@{ Pattern = $kvKey; Effect = $tv3 })
      continue
    }
    if ($state -ceq 'orch') {
      if ($ind -ne 2) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada em orchestration.')) }
      if ($orchSeen.ContainsKey($kvKey)) { throw (& $fail ("chave duplicada em orchestration: '$kvKey'.")) }
      $orchSeen[$kvKey] = $true
      if ($kvKey -ceq 'build_delegable') {
        $bv3 = (Remove-YamlQuotes -Value $kvVal).ToLowerInvariant()
        if ($bv3 -ceq 'true') { $c.BuildDelegable = $true }
        elseif ($bv3 -ceq 'false') { $c.BuildDelegable = $false }
        else { throw (& $fail 'build_delegable nao-booleano.') }
      }
      elseif ($kvKey -ceq 'lifecycle') { $c.Lifecycle = Remove-YamlQuotes -Value $kvVal }
      elseif ($kvKey -ceq 'visibility') { $c.Visibility = Remove-YamlQuotes -Value $kvVal }
      elseif ($kvKey -ceq 'allow_visibility') {
        $av = (Remove-YamlQuotes -Value $kvVal).ToLowerInvariant()
        if (($av -ne 'true') -and ($av -ne 'false')) { throw (& $fail 'allow_visibility nao-booleano.') }
      }
      elseif ($kvKey -ceq 'capabilities') {
        if ($kvVal -ne '') { throw (& $fail 'capabilities inline rejeitado (use mapping).') }
        $state = 'cap'
      }
      else { throw (& $fail ("chave desconhecida em orchestration: '$kvKey'.")) }
      continue
    }
    if ($state -ceq 'cap') {
      if ($ind -ne 4) { throw (& $fail ('linha ' + $lineno + ': indentacao inesperada em capabilities.')) }
      if ($capSeen.ContainsKey($kvKey)) { throw (& $fail ("chave duplicada em capabilities: '$kvKey'.")) }
      $capSeen[$kvKey] = $true
      if (($kvKey -ceq 'preferred') -or ($kvKey -ceq 'forbidden')) {
        if ($kvVal -ceq '[]') {
          if ($kvKey -ceq 'preferred') { $c.Preferred = @() } else { $c.Forbidden = @() }
        }
        elseif ($kvVal -eq '') {
          $curList = $kvKey
          if ($kvKey -ceq 'preferred') { $c.Preferred = @() } else { $c.Forbidden = @() }
          $state = 'caplist'
        }
        else { throw (& $fail ("lista $kvKey com valor inline inesperado: " + $kvVal)) }
      }
      else { throw (& $fail ("chave desconhecida em capabilities: '$kvKey'.")) }
      continue
    }
    if ($state -ceq 'caplist') {
      throw (& $fail ('linha ' + $lineno + ': esperado item de lista (- ...) ou chave.'))
    }
    throw (& $fail ('linha ' + $lineno + ': estado interno inesperado.'))
  }
  if (-not $c.HasDescription) { throw (& $fail 'frontmatter sem description.') }
  if (-not $c.HasMode) { throw (& $fail 'frontmatter sem mode.') }
  if (-not $c.HasModel) { throw (& $fail 'frontmatter sem model.') }
  if (-not $topSeen.ContainsKey('permission')) { throw (& $fail 'frontmatter sem bloco permission.') }
  return $c
}

function Read-AgentFileCanonical {
  param([string]$Path = '')
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ('AgentTranslator: arquivo ausente: ' + $Path)
  }
  $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  $split = Split-AgentFileText -RawText $raw -SourceName $stem
  $c = Convert-AgentFrontmatterYamlToCanonical -FrontmatterText $split.FrontmatterText -SourceName $stem
  $c.Id = $stem
  return @{ Id = $stem; Canonical = $c; Body = $split.Body }
}

# ---- emissores -----------------------------------------------------------------

function Convert-CanonicalToV1Frontmatter {
  param($Canonical)
  $c = $Canonical
  $L = New-Object System.Collections.ArrayList
  [void]$L.Add(('description: ' + (Format-YamlDoubleQuoted -Value ([string]$c.Description))))
  [void]$L.Add(('mode: ' + [string]$c.Mode))
  [void]$L.Add(('model: ' + [string]$c.Model))
  if ([bool]$c.HasHidden) {
    $hv = 'false'
    if ([bool]$c.Hidden) { $hv = 'true' }
    [void]$L.Add(('hidden: ' + $hv))
  }
  if ([bool]$c.HasTemperature) { [void]$L.Add(('temperature: ' + [string]$c.Temperature)) }
  [void]$L.Add('permission:')
  if ([bool]$c.EditPresent) { [void]$L.Add(('  edit: ' + [string]$c.Edit)) }
  if ([string]$c.BashKind -ceq 'scalar') {
    [void]$L.Add(('  bash: ' + [string]$c.BashScalar))
  }
  elseif ([string]$c.BashKind -ceq 'map') {
    [void]$L.Add('  bash:')
    $ordered = @($c.ShellRules | Sort-Object { [string]$_.Pattern })
    foreach ($r in $ordered) {
      [void]$L.Add(('    ' + (Format-YamlDoubleQuoted -Value ([string]$r.Pattern)) + ': ' + [string]$r.Effect))
    }
  }
  foreach ($x in @($c.ExtraPermissions)) {
    [void]$L.Add(('  ' + [string]$x.Name + ': ' + [string]$x.Effect))
  }
  if ([string]$c.TaskKind -ceq 'scalar') {
    [void]$L.Add(('  task: ' + [string]$c.TaskScalar))
  }
  elseif ([string]$c.TaskKind -ceq 'map') {
    [void]$L.Add('  task:')
    $tord = @($c.TaskRules | Sort-Object { [string]$_.Pattern })
    foreach ($r in $tord) {
      [void]$L.Add(('    ' + (Format-YamlDoubleQuoted -Value ([string]$r.Pattern)) + ': ' + [string]$r.Effect))
    }
  }
  if ([bool]$c.OrchPresent) {
    [void]$L.Add('orchestration:')
    $bv = 'false'
    if ([bool]$c.BuildDelegable) { $bv = 'true' }
    [void]$L.Add(('  build_delegable: ' + $bv))
    [void]$L.Add(('  lifecycle: ' + [string]$c.Lifecycle))
    [void]$L.Add(('  visibility: ' + [string]$c.Visibility))
    [void]$L.Add('  capabilities:')
    [void]$L.Add('    preferred:')
    foreach ($p in @($c.Preferred)) { [void]$L.Add(('      - ' + $p)) }
    if ((@($c.Forbidden)).Count -eq 0) {
      [void]$L.Add('    forbidden: []')
    }
    else {
      [void]$L.Add('    forbidden:')
      foreach ($f in @($c.Forbidden)) { [void]$L.Add(('      - ' + $f)) }
    }
  }
  return @{ Text = ($L -join "`n"); OmittedFields = @(); DroppedFields = @() }
}

function Get-OrderedV2ShellRules {
  param($Canonical)
  $c = $Canonical
  $rules = New-Object System.Collections.ArrayList
  if ([string]$c.BashKind -ceq 'scalar') {
    [void]$rules.Add(@{ Action = 'shell'; Resource = '*'; Effect = [string]$c.BashScalar })
    return @($rules)
  }
  if ([string]$c.BashKind -ceq 'map') {
    $catch = @(@($c.ShellRules) | Where-Object { [string]$_.Pattern -ceq '*' })
    $spec = @(@($c.ShellRules) | Where-Object { -not ([string]$_.Pattern -ceq '*') } | Sort-Object { [string]$_.Pattern })
    foreach ($r in $catch) {
      [void]$rules.Add(@{ Action = 'shell'; Resource = '*'; Effect = [string]$r.Effect })
    }
    foreach ($r in $spec) {
      [void]$rules.Add(@{ Action = 'shell'; Resource = [string]$r.Pattern; Effect = [string]$r.Effect })
    }
  }
  return @($rules)
}

function Get-OrderedV2TaskRules {
  param($Canonical)
  $c = $Canonical
  $rules = New-Object System.Collections.ArrayList
  if ([string]$c.TaskKind -ceq 'scalar') {
    [void]$rules.Add(@{ Action = 'subagent'; Resource = '*'; Effect = [string]$c.TaskScalar })
    return @($rules)
  }
  if ([string]$c.TaskKind -ceq 'map') {
    $catch = @(@($c.TaskRules) | Where-Object { [string]$_.Pattern -ceq '*' })
    $spec = @(@($c.TaskRules) | Where-Object { -not ([string]$_.Pattern -ceq '*') } | Sort-Object { [string]$_.Pattern })
    foreach ($r in $catch) {
      [void]$rules.Add(@{ Action = 'subagent'; Resource = '*'; Effect = [string]$r.Effect })
    }
    foreach ($r in $spec) {
      [void]$rules.Add(@{ Action = 'subagent'; Resource = [string]$r.Pattern; Effect = [string]$r.Effect })
    }
  }
  return @($rules)
}

function Convert-CanonicalToV2Frontmatter {
  param($Canonical)
  $c = $Canonical
  Assert-NoAmbiguousOverlap -ShellRules @($c.ShellRules)
  Assert-NoAmbiguousOverlap -ShellRules @($c.TaskRules)
  $omitted = New-Object System.Collections.ArrayList
  $dropped = New-Object System.Collections.ArrayList
  $L = New-Object System.Collections.ArrayList
  [void]$L.Add(('description: ' + (Format-YamlDoubleQuoted -Value ([string]$c.Description))))
  [void]$L.Add(('mode: ' + [string]$c.Mode))
  [void]$L.Add(('model: ' + [string]$c.Model))
  [void]$L.Add('permissions:')
  if ([bool]$c.EditPresent) {
    [void]$L.Add('  - action: edit')
    [void]$L.Add('    resource: "*"')
    [void]$L.Add(('    effect: ' + [string]$c.Edit))
  }
  foreach ($r in @(Get-OrderedV2ShellRules -Canonical $c)) {
    [void]$L.Add(('  - action: ' + [string]$r.Action))
    [void]$L.Add(('    resource: ' + (Format-YamlDoubleQuoted -Value ([string]$r.Resource))))
    [void]$L.Add(('    effect: ' + [string]$r.Effect))
  }
  foreach ($r in @(Get-OrderedV2TaskRules -Canonical $c)) {
    [void]$L.Add(('  - action: ' + [string]$r.Action))
    [void]$L.Add(('    resource: ' + (Format-YamlDoubleQuoted -Value ([string]$r.Resource))))
    [void]$L.Add(('    effect: ' + [string]$r.Effect))
  }
  if ([bool]$c.HasHidden) {
    $hv = 'false'
    if ([bool]$c.Hidden) { $hv = 'true' }
    [void]$L.Add(('hidden: ' + $hv))
  }
  if ([bool]$c.HasTemperature) { [void]$omitted.Add('temperature') }
  if ([bool]$c.OrchPresent) { [void]$dropped.Add('orchestration') }
  foreach ($x in @($c.ExtraPermissions)) { [void]$dropped.Add(('permission.' + [string]$x.Name)) }
  return @{ Text = ($L -join "`n"); OmittedFields = @($omitted); DroppedFields = @($dropped) }
}

# ---- guard de sobreposicao ambigua (fail closed) ---------------------------------

function Assert-NoAmbiguousOverlap {
  param($ShellRules = @())
  # Guard conservadoramente completo (finding V31-R1 F2): para cada par com
  # efeitos distintos (ignorando o catch-all "*"), tenta PROVAR disjuncao;
  # se nao provar, lanca ambiguous-permission-overlap (fail closed).
  # Provas, em ordem: (1) short-circuit de prefixo literal (prefixos
  # iniciais distintos onde nenhum e prefixo do outro => disjuntos);
  # (2) literal direto (lado literal testado no outro glob; se nao casa,
  # disjuntos); (3) produto estruturado de segmentos nao encontra testemunha
  # comum. O passo (3) negativo NAO prova disjuncao: fallthrough lanca.
  $rules = @($ShellRules)
  for ($i = 0; $i -lt $rules.Count; $i++) {
    for ($j = ($i + 1); $j -lt $rules.Count; $j++) {
      $a = $rules[$i]
      $b = $rules[$j]
      $pa = [string]$a.Pattern
      $pb = [string]$b.Pattern
      if (($pa -ceq '*') -or ($pb -ceq '*')) { continue }
      if ([string]$a.Effect -ceq [string]$b.Effect) { continue }
      $preA = Get-GlobLiteralPrefix -Pattern $pa
      $preB = Get-GlobLiteralPrefix -Pattern $pb
      if ((($preA.Length -gt 0)) -and (($preB.Length -gt 0)) -and ($preA -cne $preB)) {
        $aStartsB = $preA.StartsWith($preB, [StringComparison]::OrdinalIgnoreCase)
        $bStartsA = $preB.StartsWith($preA, [StringComparison]::OrdinalIgnoreCase)
        if ((-not $aStartsB) -and (-not $bStartsA)) { continue }
      }
      $litA = ((-not $pa.Contains('*')) -and (-not $pa.Contains('?')))
      $litB = ((-not $pb.Contains('*')) -and (-not $pb.Contains('?')))
      if ($litA -and (Test-GlobMatch -Pattern $pb -Text $pa)) {
        throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') testemunha "' + $pa + '"')
      }
      if ($litB -and (Test-GlobMatch -Pattern $pa -Text $pb)) {
        throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') testemunha "' + $pb + '"')
      }
      if ($litA -or $litB) { continue }
      $segA = @(Get-GlobSegments -Pattern $pa)
      $segB = @(Get-GlobSegments -Pattern $pb)
      $seenA = @{}
      $candsForA = New-Object System.Collections.ArrayList
      foreach ($x in @(@('', 'X', '--probe-value-zzz') + @($segB))) {
        $k = [string]$x
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $seenA.ContainsKey($k)) { $seenA[$k] = $true; [void]$candsForA.Add($k) }
      }
      [void]$candsForA.Add('')
      $seenB = @{}
      $candsForB = New-Object System.Collections.ArrayList
      foreach ($x in @(@('', 'X', '--probe-value-zzz') + @($segA))) {
        $k = [string]$x
        if ([string]::IsNullOrWhiteSpace($k)) { continue }
        if (-not $seenB.ContainsKey($k)) { $seenB[$k] = $true; [void]$candsForB.Add($k) }
      }
      [void]$candsForB.Add('')
      $witA = Get-GlobWitnesses -Pattern $pa -Candidates @($candsForA)
      if ($null -eq $witA) {
        throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') (expansao excede 64 testemunhas; disjuncao nao demonstrada)')
      }
      $witB = Get-GlobWitnesses -Pattern $pb -Candidates @($candsForB)
      if ($null -eq $witB) {
        throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') (expansao excede 64 testemunhas; disjuncao nao demonstrada)')
      }
      $witA = @(@($witA) + @(New-WitnessSamples -Pattern $pa))
      $witB = @(@($witB) + @(New-WitnessSamples -Pattern $pb))
      $witness = ''
      foreach ($s in $witA) {
        if ((Test-GlobMatch -Pattern $pa -Text $s) -and (Test-GlobMatch -Pattern $pb -Text $s)) { $witness = $s; break }
      }
      if ($witness -eq '') {
        foreach ($s in $witB) {
          if ((Test-GlobMatch -Pattern $pa -Text $s) -and (Test-GlobMatch -Pattern $pb -Text $s)) { $witness = $s; break }
        }
      }
      if ($witness -ne '') {
        throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') testemunha "' + $witness + '"')
      }
      throw ('ambiguous-permission-overlap: "' + $pa + '" (' + [string]$a.Effect + ') x "' + $pb + '" (' + [string]$b.Effect + ') (disjuncao nao demonstrada)')
    }
  }
  return $true
}

# ---- avaliadores de efeito -------------------------------------------------------

function Get-V1RuleEffect {
  param($Rules = @(), [bool]$HasCatchAll = $false, [string]$CatchAllEffect = '', [string]$Command = '')
  $best = $null
  $bestLen = -1
  $bestRank = -1
  foreach ($r in @($Rules)) {
    if ([string]$r.Pattern -ceq '*') { continue }
    if (Test-GlobMatch -Pattern ([string]$r.Pattern) -Text ([string]$Command)) {
      $len = ([string]$r.Pattern).Length
      $rank = Get-EffectRank -Effect ([string]$r.Effect)
      if (($len -gt $bestLen) -or ((($len -eq $bestLen)) -and ($rank -gt $bestRank))) {
        $best = $r
        $bestLen = $len
        $bestRank = $rank
      }
    }
  }
  if ($null -ne $best) { return [string]$best.Effect }
  if ($HasCatchAll) { return [string]$CatchAllEffect }
  return 'deny'
}

function Get-V2RuleEffect {
  param($V2Rules = @(), [string]$Action = '', [string]$Command = '')
  $eff = 'deny'
  $hit = $false
  foreach ($r in @($V2Rules)) {
    if ([string]$r.Action -cne $Action) { continue }
    if (Test-GlobMatch -Pattern ([string]$r.Resource) -Text ([string]$Command)) {
      $eff = [string]$r.Effect
      $hit = $true
    }
  }
  return $eff
}

function Test-PermissionSemanticEquivalence {
  param($Canonical, $V2Rules = @(), [string[]]$ShellSamples = @(), [string[]]$TaskSamples = @())
  $c = $Canonical
  $rules = @($V2Rules)
  $dev = New-Object System.Collections.ArrayList
  $shell = @($ShellSamples)
  if ($shell.Count -eq 0) {
    $shell = @('totally-unrelated-command-zz-7788', 'git status', 'npm run test')
    foreach ($r in @($c.ShellRules)) {
      if ([string]$r.Pattern -ceq '*') { continue }
      $shell = @($shell) + @(([string]$r.Pattern).Replace('*', 'probe').Replace('?', 'q'))
    }
  }
  $tasks = @($TaskSamples)
  if ($tasks.Count -eq 0) { $tasks = @('coder', 'tester', 'explorer', '*', 'self') }
  $v1Edit = 'deny'
  if ([bool]$c.EditPresent) { $v1Edit = [string]$c.Edit }
  $v2Edit = Get-V2RuleEffect -V2Rules $rules -Action 'edit' -Command 'edit-action'
  if ($v1Edit -cne $v2Edit) {
    [void]$dev.Add(('edit: V1=' + $v1Edit + ' V2=' + $v2Edit))
  }
  $v1BashDflt = 'deny'
  $v1BashRules = @()
  $v1BashCatch = $false
  $v1BashCatchEff = ''
  if ([string]$c.BashKind -ceq 'scalar') { $v1BashDflt = [string]$c.BashScalar }
  elseif ([string]$c.BashKind -ceq 'map') {
    $v1BashRules = @($c.ShellRules)
    $v1BashCatch = [bool]$c.HasCatchAll
    $v1BashCatchEff = [string]$c.CatchAllEffect
  }
  foreach ($s in $shell) {
    $e1 = $v1BashDflt
    if ([string]$c.BashKind -ceq 'map') {
      $e1 = Get-V1RuleEffect -Rules $v1BashRules -HasCatchAll $v1BashCatch -CatchAllEffect $v1BashCatchEff -Command $s
    }
    $e2 = Get-V2RuleEffect -V2Rules $rules -Action 'shell' -Command $s
    if ($e1 -cne $e2) {
      [void]$dev.Add(('shell "' + $s + '": V1=' + $e1 + ' V2=' + $e2))
    }
  }
  $v1TaskDflt = 'deny'
  $v1TaskRules = @()
  $v1TaskCatch = $false
  $v1TaskCatchEff = ''
  if ([string]$c.TaskKind -ceq 'scalar') { $v1TaskDflt = [string]$c.TaskScalar }
  elseif ([string]$c.TaskKind -ceq 'map') {
    $v1TaskRules = @($c.TaskRules)
    $v1TaskCatch = [bool]$c.TaskHasCatchAll
    $v1TaskCatchEff = [string]$c.TaskCatchAllEffect
  }
  foreach ($s in $tasks) {
    $e1 = $v1TaskDflt
    if ([string]$c.TaskKind -ceq 'map') {
      $e1 = Get-V1RuleEffect -Rules $v1TaskRules -HasCatchAll $v1TaskCatch -CatchAllEffect $v1TaskCatchEff -Command $s
    }
    $e2 = Get-V2RuleEffect -V2Rules $rules -Action 'subagent' -Command $s
    if ($e1 -cne $e2) {
      [void]$dev.Add(('subagent "' + $s + '": V1=' + $e1 + ' V2=' + $e2))
    }
  }
  $eq = ((@($dev)).Count -eq 0)
  return @{ Equivalent = $eq; Deviations = @($dev) }
}
