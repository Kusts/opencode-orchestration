$ErrorActionPreference='Stop'
$out='evidence/issue-141/authority-surface-audit.test.json';$script="$PSScriptRoot/audit-authority-surfaces.ps1";$baseline=@(git status --porcelain);$protectedBefore=@{}
$paths=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','source/global/AGENTS.md','source/adapters','scripts/v3/lib/OrchestrationTaskKernel.ps1','scripts/v3/lib/OrchestrationNativeDispatch.ps1','source/registry/verification-policy.json')
foreach($p in $paths){if(Test-Path $p){$i=Get-Item $p;if($i.PSIsContainer){$files=Get-ChildItem $p -File -Recurse}else{$files=@($i)};foreach($f in $files){$protectedBefore[$f.FullName]=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}}}
try{
 & $script -OutFile $out -GeneratedAt fixed;$j=Get-Content $out -Raw|ConvertFrom-Json
 if(@($j.surfaces).Count -ne 3 -or @($j.duplications).Count -ne 4){throw 'surface or duplicate count mismatch'}
 if(!$j.scan_scope -or !$j.excluded_paths){throw 'scope lists missing'}
 foreach($p in $j.permissions){if(!$p.enforced_by -or $p.enforced_by -notmatch '.+:\d+$' -or $p.enforcement_kind -notin @('hard','advisory','documented-only')){throw 'invalid enforcement location/kind'};foreach($x in $j.excluded_paths){if($p.path.StartsWith($x,[StringComparison]::OrdinalIgnoreCase)){throw 'excluded path scanned'}}}
 foreach($d in $j.duplications){if($d.parity -notin @('PROVEN','UNPROVEN','CONFLICTING')){throw 'invalid parity'};if($d.parity -eq 'UNPROVEN' -and @($d.sides|Select-Object -ExpandProperty surface -Unique).Count -lt 2){throw 'UNPROVEN missing both sides'}}
 foreach($f in $j.protected_files){if((Get-FileHash $f.path -Algorithm SHA256).Hash -ne $f.sha256){throw "protected hash mismatch: $($f.path)"}}
 foreach($p in $protectedBefore.Keys){if((Get-FileHash $p -Algorithm SHA256).Hash -ne $protectedBefore[$p]){throw "protected file changed: $p"}}
 $first=Get-Content $out -Raw;& $script -OutFile $out -GeneratedAt fixed;if($first -ne (Get-Content $out -Raw)){throw 'not deterministic'}
 $changed=@(git status --porcelain|Where-Object{$_ -notmatch [regex]::Escape($out)});if(($changed -join "`n") -ne ($baseline -join "`n")){throw 'write outside OutFile'};'PASS audit-authority-surfaces'
}finally{Remove-Item $out -ErrorAction SilentlyContinue}
