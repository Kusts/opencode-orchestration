$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($v3) -or -not (Test-Path -LiteralPath $v3 -PathType Container)) {
    $v3 = Join-Path (Split-Path -Parent $PSScriptRoot) 'v3'
}
$schemaLib = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
if (-not (Test-Path -LiteralPath $schemaLib -PathType Leaf)) {
    $schemaLib = Join-Path $v3 'lib\CapabilitySchema.ps1'
}
. $schemaLib
$mutLib = Join-Path $PSScriptRoot 'CapabilityJsonMutator.ps1'
if (-not (Test-Path -LiteralPath $mutLib -PathType Leaf)) {
    $mutLib = Join-Path $v3 'lib\CapabilityJsonMutator.ps1'
}
. $mutLib

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-json-mutator-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Write-Config {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Allow)
    $task = New-Object PSCustomObject
    $task | Add-Member -NotePropertyName '*' -NotePropertyValue 'deny'
    $sorted = @()
    if ($null -ne $Allow) { $sorted = @($Allow) }
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    foreach ($id in $sorted) { $task | Add-Member -NotePropertyName $id -NotePropertyValue 'allow' }
    $cfg = [ordered]@{
        agent = [ordered]@{ build = [ordered]@{ mode = 'primary'; permission = [ordered]@{ task = $task } } }
    }
    $json = (($cfg | ConvertTo-Json -Depth 10) + "`n")
    Write-Fixture -Path $Path -Text $json
}

function Get-CurrentAllow {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $out = @()
    foreach ($p in @($cfg.agent.build.permission.task.PSObject.Properties)) {
        if ($p.Name -ceq '*') { continue }
        if ([string]$p.Value -ceq 'allow') { $out += [string]$p.Name }
    }
    [Array]::Sort($out, [System.StringComparer]::Ordinal)
    return $out
}

function Get-NonGovernedHash {
    param([Parameter(Mandatory)][string]$Text)
    $o = $Text | ConvertFrom-Json
    $o.agent.build.permission.PSObject.Properties.Remove('task')
    return (Get-LogicalHash -InputObject $o)
}

function Assert-OnlyTaskChanged {
    param([Parameter(Mandatory)][string]$OriginalText, [Parameter(Mandatory)][string]$MutatedText, [Parameter(Mandatory)][string]$DesiredJson, [Parameter(Mandatory)][string]$Name)
    $range = Get-BuildTaskTargetRange -Text $OriginalText
    $prefixOk = ($MutatedText.Substring(0, [int]$range.Start) -ceq $OriginalText.Substring(0, [int]$range.Start))
    Assert-That ($prefixOk) ("$Name prefixo byte-a-byte identico") 'prefixo divergiu'
    $newSuffix = $MutatedText.Substring([int]$range.Start + $DesiredJson.Length)
    $oldSuffix = $OriginalText.Substring([int]$range.End)
    Assert-That (($newSuffix -ceq $oldSuffix)) ("$Name sufixo byte-a-byte identico") 'sufixo divergiu'
    $fragOk = ($MutatedText.Substring([int]$range.Start, $DesiredJson.Length) -ceq $DesiredJson)
    Assert-That ($fragOk) ("$Name fragmento == TaskJson canonico") 'fragmento divergiu'
    $valid = $true
    try { $MutatedText | ConvertFrom-Json | Out-Null } catch { $valid = $false }
    Assert-That ($valid) ("$Name resultado e JSON valido") 'parse falhou'
    Assert-That ((Get-NonGovernedHash -Text $MutatedText) -ceq (Get-NonGovernedHash -Text $OriginalText)) ("$Name nao-governados identicos (hash logico)") 'hash logico divergiu'
}

try {
    # --- SERIALIZACAO deterministica ---
    $j1 = New-BuildTaskAllowlistJson -ProposedAllowlist @('tester', 'coder', 'coder')
    Assert-That (($j1 -ceq '{"*": "deny", "coder": "allow", "tester": "allow"}')) 'Serialize ordena ordinal + dedupes' $j1
    $j2 = New-BuildTaskAllowlistJson -ProposedAllowlist @()
    Assert-That (($j2 -ceq '{"*": "deny"}')) 'Serialize vazio => so deny' $j2
    $j3 = New-BuildTaskAllowlistJson -ProposedAllowlist $null
    Assert-That (($j3 -ceq '{"*": "deny"}')) 'Serialize null => so deny' $j3

    # --- RANGE exato + strings com chaves/escapes respeitadas ---
    $tricky = '{"agent": {"build": {"permission": {"task": {"*": "deny", "coder": "allow"}}, "mode": "primary", "note": "a } { \"q\" [ ] : , brace"}}, "other": {"s": "task"}}'
    $rg = Get-BuildTaskTargetRange -Text $tricky
    $frag = $tricky.Substring([int]$rg.Start, [int]$rg.End - [int]$rg.Start)
    Assert-That (($frag -ceq '{"*": "deny", "coder": "allow"}')) 'Range extrai exatamente o objeto task' $frag
    $fragCfg = $frag | ConvertFrom-Json
    Assert-That (([string]$fragCfg.coder -ceq 'allow')) 'Fragmento do range parseia para o task' 'parse divergiu'
    Assert-That (($tricky.IndexOf('{"*": "deny", "coder": "allow"}') -eq [int]$rg.Start)) 'Range Start == IndexOf do fragmento' ("start=$([int]$rg.Start)")

    # --- RANGE com chave escapada (ta\u0073k == task) ---
    $escaped = '{"agent": {"build": {"permission": {"ta\u0073k": {"*": "deny"}}}}}'
    $rgEsc = Get-BuildTaskTargetRange -Text $escaped
    $fragEsc = $escaped.Substring([int]$rgEsc.Start, [int]$rgEsc.End - [int]$rgEsc.Start)
    Assert-That (($fragEsc -ceq '{"*": "deny"}')) 'Range resolve chave escapada \u0073' $fragEsc

    # --- NO-OP: current == proposed => NO_CHANGE, zero escrita ---
    $cfgNoop = Join-Path $base 'noop\opencode.json'
    Write-Config -Path $cfgNoop -Allow @('coder', 'tester')
    $hashNoopBefore = (Get-FileHash -LiteralPath $cfgNoop -Algorithm SHA256).Hash
    $rNoop = Set-BuildTaskAllowlist -ConfigPath $cfgNoop -ProposedAllowlist @('tester', 'coder') -TestRoot (Join-Path $base 'noop')
    Assert-That ([string]$rNoop.Status -ceq 'NO_CHANGE') 'NO-OP retorna NO_CHANGE' ([string]$rNoop.Status)
    Assert-That ((-not [bool]$rNoop.Wrote)) 'NO-OP nao escreve (Wrote=false)' 'Wrote=true'
    $hashNoopAfter = (Get-FileHash -LiteralPath $cfgNoop -Algorithm SHA256).Hash
    Assert-That ($hashNoopBefore -ceq $hashNoopAfter) 'NO-OP preserva bytes (hash igual)' "$hashNoopBefore vs $hashNoopAfter"
    Assert-That ([string]$rNoop.HashAfter -ceq [string]$rNoop.HashBefore) 'NO-OP HashAfter == HashBefore' (([string]$rNoop.HashBefore) + ' vs ' + ([string]$rNoop.HashAfter))

    # --- ADD: +1 entry; so o subtree task mudou ---
    $cfgAdd = Join-Path $base 'add\opencode.json'
    Write-Config -Path $cfgAdd -Allow @('coder')
    $origAdd = [IO.File]::ReadAllText($cfgAdd, [Text.UTF8Encoding]::new($false))
    $rAdd = Set-BuildTaskAllowlist -ConfigPath $cfgAdd -ProposedAllowlist @('coder', 'tester') -TestRoot (Join-Path $base 'add')
    Assert-That ([string]$rAdd.Status -ceq 'MUTATED') 'ADD retorna MUTATED' ([string]$rAdd.Status)
    Assert-That ([bool]$rAdd.Wrote) 'ADD escreve (Wrote=true)' 'Wrote=false'
    Assert-That (((Get-CurrentAllow -Path $cfgAdd) -join ',') -ceq 'coder,tester') 'ADD atualiza allowlist' ((Get-CurrentAllow -Path $cfgAdd) -join ',')
    $mutAdd = [IO.File]::ReadAllText($cfgAdd, [Text.UTF8Encoding]::new($false))
    Assert-OnlyTaskChanged -OriginalText $origAdd -MutatedText $mutAdd -DesiredJson ([string]$rAdd.TaskJson) -Name 'ADD'
    $leftAdd = @(Get-ChildItem -LiteralPath (Join-Path $base 'add') -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
    Assert-That ($leftAdd.Count -eq 0) 'ADD nao deixa temp files' ("$($leftAdd.Count) leftover(s)")

    # --- REMOVE ---
    $cfgRm = Join-Path $base 'rm\opencode.json'
    Write-Config -Path $cfgRm -Allow @('coder', 'tester')
    $origRm = [IO.File]::ReadAllText($cfgRm, [Text.UTF8Encoding]::new($false))
    $rRm = Set-BuildTaskAllowlist -ConfigPath $cfgRm -ProposedAllowlist @('coder') -TestRoot (Join-Path $base 'rm')
    Assert-That ([string]$rRm.Status -ceq 'MUTATED') 'REMOVE retorna MUTATED' ([string]$rRm.Status)
    Assert-That (((Get-CurrentAllow -Path $cfgRm) -join ',') -ceq 'coder') 'REMOVE atualiza allowlist' ((Get-CurrentAllow -Path $cfgRm) -join ',')
    $mutRm = [IO.File]::ReadAllText($cfgRm, [Text.UTF8Encoding]::new($false))
    Assert-OnlyTaskChanged -OriginalText $origRm -MutatedText $mutRm -DesiredJson ([string]$rRm.TaskJson) -Name 'REMOVE'

    # --- ADD+REMOVE ---
    $cfgBoth = Join-Path $base 'both\opencode.json'
    Write-Config -Path $cfgBoth -Allow @('coder', 'explorer')
    $origBoth = [IO.File]::ReadAllText($cfgBoth, [Text.UTF8Encoding]::new($false))
    $rBoth = Set-BuildTaskAllowlist -ConfigPath $cfgBoth -ProposedAllowlist @('coder', 'tester') -TestRoot (Join-Path $base 'both')
    Assert-That (((Get-CurrentAllow -Path $cfgBoth) -join ',') -ceq 'coder,tester') 'ADD+REMOVE atualiza allowlist' ((Get-CurrentAllow -Path $cfgBoth) -join ',')
    $mutBoth = [IO.File]::ReadAllText($cfgBoth, [Text.UTF8Encoding]::new($false))
    Assert-OnlyTaskChanged -OriginalText $origBoth -MutatedText $mutBoth -DesiredJson ([string]$rBoth.TaskJson) -Name 'ADD+REMOVE'

    # --- FORMATTING PRESERVATION: espacamento nao-padrao, desconhecidos, ordem, outras secoes ---
    $weird = @'
{
  "skills":  { "b" : "a", "z": [1, 2, {"k": "v } {"}] },
 "agent" : {"title": {"model": "m"}, "build": { "permission" : { "task" : { "*" : "deny" , "coder" : "allow", "tester" : "allow" } , "extra": "keep } me" } , "mode": "primary" }, "note": "brace } in string" },
 "mcp": {"x": 1},
 "plugin": []
}
'@
    $cfgWeird = Join-Path $base 'weird\opencode.json'
    Write-Fixture -Path $cfgWeird -Text $weird
    $origWeird = [IO.File]::ReadAllText($cfgWeird, [Text.UTF8Encoding]::new($false))
    $rWeird = Set-BuildTaskAllowlist -ConfigPath $cfgWeird -ProposedAllowlist @('coder') -TestRoot (Join-Path $base 'weird')
    Assert-That ([string]$rWeird.Status -ceq 'MUTATED') 'WEIRD retorna MUTATED' ([string]$rWeird.Status)
    Assert-That (((Get-CurrentAllow -Path $cfgWeird) -join ',') -ceq 'coder') 'WEIRD atualiza allowlist' ((Get-CurrentAllow -Path $cfgWeird) -join ',')
    $mutWeird = [IO.File]::ReadAllText($cfgWeird, [Text.UTF8Encoding]::new($false))
    Assert-OnlyTaskChanged -OriginalText $origWeird -MutatedText $mutWeird -DesiredJson ([string]$rWeird.TaskJson) -Name 'WEIRD'
    Assert-That (($mutWeird -match '"extra": "keep \} me"') -and ($mutWeird -match '"brace \} in string"') -and ($mutWeird -match '"mcp"')) 'WEIRD preserva campos desconhecidos/strings' 'campos perdidos'

    # --- BOM + CRLF preservados fora do range ---
    $cfgBom = Join-Path $base 'bom\opencode.json'
    $bomText = '{"agent": {"build": {"mode": "primary", "permission": {"task": {"*": "deny", "coder": "allow"}}}}}' + "`r`n"
    $bomBytes = New-Object System.Collections.Generic.List[byte]
    $bomBytes.AddRange([byte[]](0xEF, 0xBB, 0xBF))
    $bomBytes.AddRange([Text.Encoding]::UTF8.GetBytes($bomText))
    $parentBom = Split-Path -Parent $cfgBom
    New-Item -ItemType Directory -Path $parentBom -Force | Out-Null
    [IO.File]::WriteAllBytes($cfgBom, $bomBytes.ToArray())
    $rBom = Set-BuildTaskAllowlist -ConfigPath $cfgBom -ProposedAllowlist @('coder', 'tester') -TestRoot (Join-Path $base 'bom')
    Assert-That ([string]$rBom.Status -ceq 'MUTATED') 'BOM retorna MUTATED' ([string]$rBom.Status)
    $afterBom = [IO.File]::ReadAllBytes($cfgBom)
    Assert-That (($afterBom[0] -eq 0xEF) -and ($afterBom[1] -eq 0xBB) -and ($afterBom[2] -eq 0xBF)) 'BOM preservado apos escrita' 'BOM perdido'
    $afterBomText = [Text.Encoding]::UTF8.GetString($afterBom[3..($afterBom.Length - 1)])
    Assert-That (($afterBomText -match "`r`n")) 'CRLF fora do range preservado' 'terminador mudou'
    Assert-That (((Get-CurrentAllow -Path $cfgBom) -join ',') -ceq 'coder,tester') 'BOM allowlist atualizada' ((Get-CurrentAllow -Path $cfgBom) -join ',')

    # --- CAS_CONFLICT: ExpectedHash antigo => erro, sem escrita ---
    $cfgCas = Join-Path $base 'cas\opencode.json'
    Write-Config -Path $cfgCas -Allow @('coder')
    $hashCasBefore = (Get-FileHash -LiteralPath $cfgCas -Algorithm SHA256).Hash
    $casThrew = $false; $casMsg = ''
    try { Set-BuildTaskAllowlist -ConfigPath $cfgCas -ProposedAllowlist @('coder', 'tester') -ExpectedHash 'sha256:0000000000000000000000000000000000000000000000000000000000000000' -TestRoot (Join-Path $base 'cas') | Out-Null }
    catch { $casThrew = $true; $casMsg = $_.Exception.Message }
    Assert-That (($casThrew) -and ($casMsg -match 'CAS_CONFLICT')) 'CAS_CONFLICT lanca erro' $casMsg
    $hashCasAfter = (Get-FileHash -LiteralPath $cfgCas -Algorithm SHA256).Hash
    Assert-That ($hashCasBefore -ceq $hashCasAfter) 'CAS_CONFLICT nao escreve' "$hashCasBefore vs $hashCasAfter"

    # --- CAS ok: ExpectedHash atual => escreve ---
    $curHash = 'sha256:' + ((Get-FileHash -LiteralPath $cfgCas -Algorithm SHA256).Hash).ToLowerInvariant()
    $rCasOk = Set-BuildTaskAllowlist -ConfigPath $cfgCas -ProposedAllowlist @('coder', 'tester') -ExpectedHash $curHash -TestRoot (Join-Path $base 'cas')
    Assert-That ([string]$rCasOk.Status -ceq 'MUTATED') 'CAS com hash atual escreve' ([string]$rCasOk.Status)

    # --- SEM TestRoot => WOULD_MUTATE, sem escrita (nunca toca o real) ---
    $cfgWhat = Join-Path $base 'what\opencode.json'
    Write-Config -Path $cfgWhat -Allow @('coder')
    $hashWhatBefore = (Get-FileHash -LiteralPath $cfgWhat -Algorithm SHA256).Hash
    $rWhat = Set-BuildTaskAllowlist -ConfigPath $cfgWhat -ProposedAllowlist @('coder', 'tester')
    Assert-That ([string]$rWhat.Status -ceq 'WOULD_MUTATE') 'Sem TestRoot retorna WOULD_MUTATE' ([string]$rWhat.Status)
    Assert-That ((-not [bool]$rWhat.Wrote)) 'WOULD_MUTATE nao escreve' 'Wrote=true'
    Assert-That ((-not [string]::IsNullOrWhiteSpace([string]$rWhat.MutatedText))) 'WOULD_MUTATE retorna o texto mutado' 'MutatedText vazio'
    $hashWhatAfter = (Get-FileHash -LiteralPath $cfgWhat -Algorithm SHA256).Hash
    Assert-That ($hashWhatBefore -ceq $hashWhatAfter) 'WOULD_MUTATE preserva o arquivo' 'arquivo mudou'
    $rWhatIf = Set-BuildTaskAllowlist -ConfigPath $cfgWhat -ProposedAllowlist @('coder', 'tester') -TestRoot (Join-Path $base 'what') -WhatIf
    Assert-That (([string]$rWhatIf.Status -ceq 'WOULD_MUTATE') -and (-not [bool]$rWhatIf.Wrote)) '-WhatIf com TestRoot nao escreve' ([string]$rWhatIf.Status)
    $hashWhatIfAfter = (Get-FileHash -LiteralPath $cfgWhat -Algorithm SHA256).Hash
    Assert-That ($hashWhatBefore -ceq $hashWhatIfAfter) '-WhatIf preserva o arquivo' 'arquivo mudou'

    # --- INVALID TARGET: fail closed, sem escrita ---
    $invDir = Join-Path $base 'inv'
    $cases = @(
        @{ Name = 'task ausente'; Text = '{"agent": {"build": {"mode": "primary", "permission": {}}}}'; Match = 'ausente' },
        @{ Name = 'agent duplicado'; Text = '{"agent": {"build": {"permission": {"task": {"*": "deny"}}}}, "agent": {}}'; Match = 'duplicada' },
        @{ Name = 'task duplicado'; Text = '{"agent": {"build": {"permission": {"task": {"*": "deny", "coder": "allow", "coder": "deny"}}}}}'; Match = 'duplicada' },
        @{ Name = 'task nao-objeto'; Text = '{"agent": {"build": {"permission": {"task": "deny"}}}}'; Match = 'nao-objeto' },
        @{ Name = 'JSON malformado'; Text = '{"agent": {"build": {"permission": {"task": {"*": "deny"}}'; Match = 'malformado' },
        @{ Name = 'raiz nao-objeto'; Text = '[{"agent": 1}]'; Match = 'ausente|raiz' }
    )
    foreach ($c in $cases) {
        $p = Join-Path $invDir (($c.Name -replace '[^a-z]', '') + '\opencode.json')
        Write-Fixture -Path $p -Text $c.Text
        $hBefore = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        $threw = $false; $msg = ''
        try { Set-BuildTaskAllowlist -ConfigPath $p -ProposedAllowlist @('coder') -TestRoot (Split-Path -Parent $p) | Out-Null }
        catch { $threw = $true; $msg = $_.Exception.Message }
        Assert-That (($threw) -and ($msg -match $c.Match)) ("INVALID $($c.Name) fail closed") $msg
        $hAfter = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        Assert-That ($hBefore -ceq $hAfter) ("INVALID $($c.Name) nao escreve") "$hBefore vs $hAfter"
    }

    # --- BOUNDARY: TestRoot fora do TEMP => recusa antes de escrever ---
    $cfgBound = Join-Path $base 'bound\opencode.json'
    Write-Config -Path $cfgBound -Allow @('coder')
    $boundThrew = $false
    try { Set-BuildTaskAllowlist -ConfigPath $cfgBound -ProposedAllowlist @('coder', 'tester') -TestRoot 'C:\Windows\Temp\evil-root' | Out-Null } catch { $boundThrew = $true }
    Assert-That ($boundThrew) 'Boundary TestRoot fora do TEMP recusa' 'escreveu fora do TEMP'

    # --- BOUNDARY: config real nunca e escrito pelo mutator ---
    $realCfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if (Test-Path -LiteralPath $realCfg -PathType Leaf) {
        $realThrew = $false
        try { Set-BuildTaskAllowlist -ConfigPath $realCfg -ProposedAllowlist @('coder') -TestRoot ([IO.Path]::GetTempPath()) | Out-Null } catch { $realThrew = $true }
        Assert-That ($realThrew) 'Boundary config real sempre recusado' 'mutator aceitou o config real'
    }

    # --- INTEGRACAO: New-AuthorityChangeRequest usa bytes mutados ---
    $authLib = Join-Path $PSScriptRoot 'CapabilityAuthority.ps1'
    if (-not (Test-Path -LiteralPath $authLib -PathType Leaf)) {
        $authLib = Join-Path $v3 'lib\CapabilityAuthority.ps1'
    }
    . $authLib
    $rInt = Join-Path $base 'int'
    $agentsDir = Join-Path $rInt 'source\agents'
    $regDir = Join-Path $rInt 'source\registry'
    New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $regDir -Force | Out-Null
    Write-Fixture -Path (Join-Path $regDir 'capability-policy.json') -Text '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{}}'
    Write-Fixture -Path (Join-Path $regDir 'runtimes.json') -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"agent.build.permission.task":"control-plane"}}]}}}'
    foreach ($n in @('coder', 'tester')) {
        Write-Fixture -Path (Join-Path $agentsDir ($n + '.md')) -Text "---`ndescription: $n`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n"
    }
    $cfgInt = Join-Path $rInt 'fix\opencode.json'
    Write-Config -Path $cfgInt -Allow @('coder', 'tester')
    $reqInt = New-AuthorityChangeRequest -RepoRoot $rInt -ConfigPath $cfgInt -PolicyPath (Join-Path $regDir 'capability-policy.json')
    Assert-That ([string]$reqInt.target_config_hash -ceq [string]$reqInt.base_config_hash) 'Integracao no-op: target == base (15<>15 analogo)' (([string]$reqInt.target_config_hash) + ' vs ' + ([string]$reqInt.base_config_hash))
    Write-Fixture -Path (Join-Path $agentsDir 'researcher.md') -Text "---`ndescription: researcher`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n"
    $reqInt2 = New-AuthorityChangeRequest -RepoRoot $rInt -ConfigPath $cfgInt -PolicyPath (Join-Path $regDir 'capability-policy.json')
    Assert-That ([string]$reqInt2.target_config_hash -cne [string]$reqInt2.base_config_hash) 'Integracao +1 agente: target != base' (([string]$reqInt2.target_config_hash) + ' vs ' + ([string]$reqInt2.base_config_hash))
    $wInt = Set-BuildTaskAllowlist -ConfigPath $cfgInt -ProposedAllowlist @($reqInt2.proposed_allowlist)
    Assert-That ([string]$wInt.HashAfter -ceq [string]$reqInt2.target_config_hash) 'Integracao target == hash dos bytes mutados' (([string]$wInt.HashAfter) + ' vs ' + ([string]$reqInt2.target_config_hash))
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
