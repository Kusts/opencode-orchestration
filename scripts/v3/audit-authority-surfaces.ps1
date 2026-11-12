param([string]$OutFile = 'evidence/issue-141/authority-surface-audit.json', [string]$GeneratedAt = '')
$ErrorActionPreference='Stop';$root=(Get-Location).Path;$base=(git rev-parse HEAD).Trim()
$specs=@(
 @{name='opencode';paths=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','opencode.json');owner='Runtime template/config';enforcer='OpenCode runtime';kind='hard'},
 @{name='agent-config';paths=@('source/global/AGENTS.md','source/adapters');owner='source/ agent instructions and adapter';enforcer='Agent/runtime instruction consumer';kind='advisory'},
 @{name='task-kernel';paths=@('scripts/v3/lib/OrchestrationTaskKernel.ps1','scripts/v3/lib/OrchestrationNativeDispatch.ps1','source/registry/verification-policy.json');owner='Task Kernel + verification registry';enforcer='Task Kernel guards and allowlisted verifier';kind='hard'}
)
$surfaces=@();$permissions=@();$owners=@();$seen=@{}
foreach($s in $specs){$surfaces += [pscustomobject]@{name=$s.name;paths=@($s.paths | Where-Object {Test-Path $_})};$owners += [pscustomobject]@{surface=$s.name;controlled_by=$s.owner}
 foreach($path in $s.paths){if(!(Test-Path $path)){continue};$items=if((Get-Item $path).PSIsContainer){Get-ChildItem $path -File -Recurse}else{@(Get-Item $path)}
 foreach($f in $items){$rel=$f.FullName.Substring($root.Length+1).Replace('\','/');$n=0;foreach($line in [IO.File]::ReadLines($f.FullName)){$n++
  if($line -match '(?i)(edit|bash:\*|subagent|deny|permission|allow|verification|lease|worktree)'){$token=if($line -match '(?i)bash:\*'){'bash:*'}elseif($line -match '(?i)subagent'){'subagent'}elseif($line -match '(?i)deny'){'deny'}elseif($line -match '(?i)edit'){'edit'}else{'permission'}
   $permissions += [pscustomobject]@{permission=$token;surface=$s.name;path=$rel;line=$n;declared_by=$rel;enforced_by=$s.enforcer;enforcement_kind=$s.kind;evidence=$line.Trim()};if(!$seen.ContainsKey($token)){$seen[$token]=@()} ;$seen[$token]+=$s.name
  }
 }} }
}
$dups=@();foreach($token in $seen.Keys){$unique=@($seen[$token]|Select-Object -Unique);if($unique.Count -gt 1){$dups += [pscustomobject]@{permission=$token;surfaces=$unique;parity='UNPROVEN';parity_evidence='No behavioral equivalence test was established by this static inventory.'}}}
$proposal=@();foreach($d in $dups){$proposal += [pscustomobject]@{permission=$d.permission;action='No removal proposed';required_proof='Behavioral parity test across each declaring/enforcing surface; authorization to remove.'}}
$now=if($GeneratedAt){$GeneratedAt}else{(Get-Date).ToUniversalTime().ToString('o')}
$obj=[pscustomobject]@{surfaces=$surfaces;permissions=$permissions;duplications=$dups;owners=$owners;proposal=$proposal;method=[pscustomobject]@{mode='deterministic_local_io';no_model_call=$true;base_revision=$base;generated_by_commit=$base;limitations='Static declaration scan; enforcement attribution is based on the named runtime/kernel boundary, not runtime experiment.'};generated_at=$now}
$dest=Join-Path $root $OutFile;New-Item -ItemType Directory -Force (Split-Path $dest)|Out-Null;$obj|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 $dest
