$ErrorActionPreference='Stop';$out='evidence/issue-50/pinned-versions-audit.test.json';$before=git status --porcelain
try { & "$PSScriptRoot/audit-pinned-versions.ps1" -OutFile $out -GeneratedAt 'fixed';$j=Get-Content $out -Raw|ConvertFrom-Json
 if($null -eq $j.pins -or $null -eq $j.capability_checks -or $null -eq $j.candidates -or $null -eq $j.proposal){throw 'required blocks missing'}
 foreach($c in $j.candidates){if($c.classification -eq 'CAPABILITY_CANDIDATE' -and !($j.proposal|Where-Object { $_.path -eq $c.path -and $_.line -eq $c.line })){throw 'candidate proposal missing'}}
 $a=Get-Content $out -Raw; & "$PSScriptRoot/audit-pinned-versions.ps1" -OutFile $out -GeneratedAt 'fixed';if($a -ne (Get-Content $out -Raw)){throw 'not deterministic'}
 $changed=@(git status --porcelain | Where-Object {$_ -notmatch [regex]::Escape($out)});if(($changed -join "`n") -ne ($before -join "`n")){throw 'wrote outside output'}
 'PASS audit-pinned-versions'
} finally {Remove-Item $out -ErrorAction SilentlyContinue}
