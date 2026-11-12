$ErrorActionPreference='Stop';$out='evidence/issue-141/authority-surface-audit.test.json';$before=git status --porcelain
try { & "$PSScriptRoot/audit-authority-surfaces.ps1" -OutFile $out -GeneratedAt 'fixed';$j=Get-Content $out -Raw|ConvertFrom-Json
 if(@($j.surfaces).Count -ne 3 -or (@($j.surfaces.name|Sort-Object) -join ',') -ne 'agent-config,opencode,task-kernel'){throw 'surface set incorrect'}
 foreach($p in $j.permissions){if(!$p.enforced_by -or $p.enforcement_kind -notin @('hard','advisory','documented-only')){throw 'permission enforcement absent'}}
 foreach($d in $j.duplications){if($d.parity -notin @('PROVEN','UNPROVEN','CONFLICTING')){throw 'invalid parity'}}
 $a=Get-Content $out -Raw;& "$PSScriptRoot/audit-authority-surfaces.ps1" -OutFile $out -GeneratedAt 'fixed';if($a -ne (Get-Content $out -Raw)){throw 'not deterministic'}
 $changed=@(git status --porcelain|Where-Object {$_ -notmatch [regex]::Escape($out)});if(($changed -join "`n") -ne ($before -join "`n")){throw 'wrote outside output'}
 'PASS audit-authority-surfaces'
} finally {Remove-Item $out -ErrorAction SilentlyContinue}
