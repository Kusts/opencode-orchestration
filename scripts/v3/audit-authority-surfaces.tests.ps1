$ErrorActionPreference='Stop';$out='evidence/issue-141/authority-surface-audit.test.json';$script="$PSScriptRoot/audit-authority-surfaces.ps1";$baseline=@(git status --porcelain);$protectedBefore=@{}
$paths=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','source/agents','source/global/AGENTS.md','source/adapters','source/registry/execution-grants.json','scripts/v3/lib/OrchestrationTaskKernel.ps1','scripts/v3/lib/OrchestrationNativeDispatchGrantProjection.ps1','scripts/v3/lib/OrchestrationNativeDispatch.ps1','scripts/v3/lib/OrchestrationAutonomy.ps1')
foreach($p in $paths){if(Test-Path $p){$i=Get-Item $p;if($i.PSIsContainer){$fs=Get-ChildItem $p -File -Recurse}else{$fs=@($i)};foreach($f in $fs){$protectedBefore[$f.FullName]=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}}}
try{
 & $script -OutFile $out -GeneratedAt fixed;$j=Get-Content $out -Raw|ConvertFrom-Json
 if(@($j.surfaces).Count -ne 3 -or @($j.cross_surface_tokens).Count -ne 0){throw 'surface/cross-token count mismatch'};if(!$j.cross_surface_rule -or !$j.surfaces.Where({$_.name -eq 'agent-config'}).no_structured_declarations){throw 'Agent Config structured-declaration status missing'}
 foreach($p in $j.permissions){if(!$p.declared_by){throw 'declaration provenance missing'};if($p.enforced_by -and $p.enforced_by -eq $p.declared_by){throw 'enforcement is not distinct from declaration'};if($p.enforcement_kind -notin @('hard','advisory','documented-only')){throw 'invalid enforcement kind'}}
 foreach($u in $j.unparseable){if($u.classification -ne 'UNPARSEABLE'){throw 'UNPARSEABLE was silently resolved'}}
 foreach($f in $j.protected_files){if((Get-FileHash $f.path -Algorithm SHA256).Hash -ne $f.sha256){throw "protected hash mismatch $($f.path)"}};foreach($p in $protectedBefore.Keys){if((Get-FileHash $p -Algorithm SHA256).Hash -ne $protectedBefore[$p]){throw "protected file changed $p"}}
 $ids=@($j.permissions|ForEach-Object{"$($_.surface):$($_.declared_by):$($_.token)"});if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'duplicate structured permission record'}
 $first=Get-Content $out -Raw;& $script -OutFile $out -GeneratedAt fixed;if($first -ne (Get-Content $out -Raw)){throw 'not deterministic'}
 $changed=@(git status --porcelain|Where-Object{$_ -notmatch [regex]::Escape($out)});if(($changed -join "`n") -ne ($baseline -join "`n")){throw 'write outside OutFile'};'PASS audit-authority-surfaces'
}finally{Remove-Item $out -ErrorAction SilentlyContinue}
