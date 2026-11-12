param([string]$OutFile='evidence/issue-141/authority-surface-audit.json',[string]$GeneratedAt='')
$ErrorActionPreference='Stop';$root=(Get-Location).Path;$base=(git rev-parse HEAD).Trim()
$specs=@(
 @{name='opencode';paths=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','opencode.json')},
 @{name='agent-config';paths=@('source/global/AGENTS.md','source/adapters')},
 @{name='task-kernel';paths=@('scripts/v3/lib/OrchestrationTaskKernel.ps1','scripts/v3/lib/OrchestrationNativeDispatch.ps1','source/registry/verification-policy.json')})
$surfaces=@();$permissions=@();$owners=@();$seen=@{};$protected=@()
foreach($s in $specs){
 $existing=@($s.paths|Where-Object {Test-Path $_})
 $surfaces += [pscustomobject]@{name=$s.name;paths=$existing}
 $owners += [pscustomobject]@{surface=$s.name;controlled_by=($s.paths -join '; ')}
 foreach($p in $existing){
  $it=Get-Item $p
  if($it.PSIsContainer){$fs=@(Get-ChildItem $p -File -Recurse)}else{$fs=@($it)}
  foreach($f in $fs){
   $rel=$f.FullName.Substring($root.Length+1).Replace('\','/')
   $protected += [pscustomobject]@{path=$rel;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}
   $n=0;foreach($line in [IO.File]::ReadLines($f.FullName)){
    $n++
    if($line -match '(?i)(edit|bash:\*|subagent|deny|permission|allow|verification|lease|worktree)'){
     $token=if($line -match '(?i)bash:\*'){'bash:*'}elseif($line -match '(?i)subagent'){'subagent'}elseif($line -match '(?i)deny'){'deny'}elseif($line -match '(?i)edit'){'edit'}else{'permission'}
     $kind=if($s.name -eq 'agent-config'){'documented-only'}else{'advisory'};$ev="$rel`:$n"
     $permissions += [pscustomobject]@{permission=$token;surface=$s.name;path=$rel;line=$n;declared_by=$ev;enforced_by=$ev;enforcement_kind=$kind;evidence=$line.Trim()}
     if(!$seen.ContainsKey($token)){$seen[$token]=@()};$seen[$token]+=[pscustomobject]@{surface=$s.name;path=$rel;line=$n}
    }
   }
  }
 }
}
$dups=@()
foreach($token in $seen.Keys){
 $groups=@($seen[$token]|Group-Object surface)
 if($groups.Count -gt 1){
  $sides=@();foreach($g in $groups){$x=@($g.Group)[0];$sides += [pscustomobject]@{surface=$x.surface;path=$x.path;line=$x.line;additional_declarations=@($g.Group).Count-1}}
  $dups += [pscustomobject]@{permission=$token;parity='UNPROVEN';sides=$sides;what_missing='Behavioral parity test showing identical allow/deny outcome and precedence across both surfaces.';parity_evidence='No cross-surface behavior test established by this static scan.'}
 }
}
$proposal=@(foreach($d in $dups){[pscustomobject]@{permission=$d.permission;action='No removal proposed';required_proof=$d.what_missing}})
$now=if($GeneratedAt){$GeneratedAt}else{(Get-Date).ToUniversalTime().ToString('o')}
$o=[pscustomobject]@{scan_scope=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','opencode.json','source/global/AGENTS.md','source/adapters/','scripts/v3/lib/OrchestrationTaskKernel.ps1','scripts/v3/lib/OrchestrationNativeDispatch.ps1','source/registry/verification-policy.json');excluded_paths=@('evidence/','docs/','cache/','.git/','node_modules/');surfaces=$surfaces;permissions=$permissions;duplications=$dups;owners=$owners;protected_files=$protected;proposal=$proposal;method=[pscustomobject]@{mode='deterministic_local_io';no_model_call=$true;base_revision=$base;generated_by_commit=$base;limitations='Static scan cannot establish live runtime enforcement; enforcement_kind stays advisory/documented-only absent an explicitly cited behavioral guard/test.'};generated_at=$now}
$dest=Join-Path $root $OutFile;New-Item -ItemType Directory -Force (Split-Path $dest)|Out-Null;$o|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 $dest
