param([string]$OutFile = 'evidence/issue-50/pinned-versions-audit.json', [string]$GeneratedAt = '')
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$base = (git rev-parse HEAD).Trim()
$pins = @(); $caps = @()
$files = Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules|evidence)[\\/]' -and $_.Extension -in '.ps1','.psm1','.json','.jsonc','.md','.tmpl','.yml','.yaml' }
foreach ($file in $files) {
  $rel = $file.FullName.Substring($root.Length + 1).Replace('\','/')
  $n=0; foreach ($line in [IO.File]::ReadLines($file.FullName)) { $n++
    if ($line -match '(?i)(\d+\.\d+(?:\.\d+){0,2}|v\d+\.\d+\.\d+)' -and $line -match '(?i)pin|version|runtime|plugin|bun|opencode|compare|requires|must be') {
      $kind='version_literal'; $truth=''
      if ($rel -match 'runtime-versions\.json') { $kind='source_registry_pin'; $truth='source/registry/runtime-versions.json' }
      elseif ($rel -match 'RuntimeVersions\.ps1') { $kind='fail_closed_loader'; $truth='source/registry/runtime-versions.json; scripts/runtime/lib/RuntimeVersions.ps1' }
      elseif ($line -match '(?i)plugin') { $kind='plugin_pin'; $truth='source/registry/runtime-versions.json' }
      elseif ($line -match '(?i)bun') { $kind='tool_pin'; $truth='source/registry/runtime-versions.json' }
      $pins += [pscustomobject]@{path=$rel;line=$n;literal=$Matches[1];kind=$kind;source_of_truth=$truth}
    }
    if ($line -match '(?i)capabilit|healthcheck|probe|doctor') { $caps += [pscustomobject]@{path=$rel;line=$n;observes=$line.Trim()} }
  }
}
$candidates=@();$proposal=@()
foreach($p in $pins){$class='KEEP_PIN';$why='Version is an explicit reproducibility/compatibility contract; no equivalent observable check proven.';$risk='Changing the version contract may run incompatible behavior.'
 if($p.kind -eq 'version_literal' -and $p.path -notmatch 'docs/|CHANGELOG'){ $class='UNKNOWN';$why='Literal found, but its runtime role cannot be decided from local evidence.' }
 $candidates += [pscustomobject]@{path=$p.path;line=$p.line;literal=$p.literal;classification=$class;rationale=$why;risk=$risk}
}
$now=if($GeneratedAt){$GeneratedAt}else{(Get-Date).ToUniversalTime().ToString('o')}
$obj=[pscustomobject]@{pins=$pins;capability_checks=$caps;candidates=$candidates;proposal=$proposal;method=[pscustomobject]@{mode='deterministic_local_io';no_model_call=$true;base_revision=$base;generated_by_commit=$base;limitations='Regex inventory can miss computed/versioned dependencies; no external runtime compatibility proved.'};generated_at=$now}
$dest=Join-Path $root $OutFile; New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null; $obj | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $dest
