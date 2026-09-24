# config-preservation.tests.ps1 — ownership: custom/mcp/plugin/chaves/propriedades/AGENTS.md.
$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
function Assert($Cond, [string]$Name) {
  if ($Cond) { $script:pass += 1; Write-Host ("ok - " + $Name) }
  else { $script:fail += 1; Write-Host ("NOT OK - " + $Name) }
}
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$TmpHome = Join-Path ([IO.Path]::GetTempPath()) ('oo-t-pres-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpHome -Force | Out-Null
try {
  $ocDir = Join-Path $TmpHome '.config\opencode'
  New-Item -ItemType Directory -Path $ocDir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $ocDir 'node_modules\@opencode-ai\plugin') -Force | Out-Null
  $pre = [ordered]@{
    '$schema' = 'https://opencode.ai/config.json'
    model = 'user/planner-model'
    agent = [ordered]@{
      build = [ordered]@{ mode = 'primary'; model = 'legacy/model'; permission = [ordered]@{ task = [ordered]@{ '*' = 'deny' } } }
      coder = [ordered]@{ mode = 'subagent'; model = 'old/model'; temperature = 0.9; permission = 'deny' }
      'junio-custom' = [ordered]@{ model = 'foo/bar'; permission = [ordered]@{ bash = 'deny' } }
    }
    mcp = [ordered]@{ 'my-server' = [ordered]@{ type = 'local'; command = @('node', 'srv.js') } }
    plugin = @('my-plugin')
    meu_topo_custom = 'keep-me'
  }
  [IO.File]::WriteAllText((Join-Path $ocDir 'opencode.json'), ((($pre | ConvertTo-Json -Depth 32).TrimEnd()) + "`n"), (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText((Join-Path $ocDir 'AGENTS.md'), "# Notas do usuario`n`nConteudo fora dos markers que deve sobreviver.`n", (New-Object Text.UTF8Encoding $false))
  $null = & (Join-Path $RepoRoot 'install.ps1') -TargetHome $TmpHome 2>&1
  Assert ($LASTEXITCODE -eq 0) 'install exit 0'
  $j = ([IO.File]::ReadAllText((Join-Path $ocDir 'opencode.json'), [Text.Encoding]::UTF8)) | ConvertFrom-Json
  Assert (($j.agent.'junio-custom'.model -eq 'foo/bar') -and ($j.agent.'junio-custom'.permission.bash -eq 'deny')) 'custom agent intacto (DH-02)'
  Assert ((($j.agent.'junio-custom' | ConvertTo-Json -Depth 32 -Compress)) -eq '{"model":"foo/bar","permission":{"bash":"deny"}}') 'custom agent sem campo alterado'
  Assert ($j.mcp.'my-server'.command[1] -eq 'srv.js') 'mcp.* preservado'
  Assert ((@($j.plugin)).Count -eq 1 -and (@($j.plugin))[0] -eq 'my-plugin') 'plugin nao-vazio preservado'
  Assert ($j.meu_topo_custom -eq 'keep-me') 'chave de topo desconhecida preservada'
  Assert ($j.agent.coder.temperature -eq 0.9) 'propriedade desconhecida em agente conhecido preservada'
  $models = (([IO.File]::ReadAllText((Join-Path $RepoRoot 'models.jsonc'), [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n") | ConvertFrom-Json
  Assert ($j.agent.coder.model -eq $models.cheap) 'coder.model atualizado para cheap'
  $hasBM = ($null -ne ($j.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue))
  Assert (-not $hasBM) 'build.model legado removido'
  $t = [IO.File]::ReadAllText((Join-Path $ocDir 'AGENTS.md'), [Text.Encoding]::UTF8)
  Assert ($t.Contains('Conteudo fora dos markers')) 'AGENTS.md conteudo externo preservado'
  Assert (([regex]::Matches($t, '<!-- opencode-orchestration:start -->')).Count -eq 1) 'AGENTS.md 1 par de markers'
}
finally {
  if (Test-Path -LiteralPath $TmpHome) { Remove-Item -LiteralPath $TmpHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("PASS: " + $pass + " / FAIL: " + $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
