<#!
.SYNOPSIS
    Detecta a geracao do runtime OpenCode (CLI fino sobre RuntimeAdapters).
.DESCRIPTION
    PS 5.1 compativel. Nunca escreve arquivos. Exit codes: 0 resolvido/target;
    6 unresolved/ambiguous/conflict/deferred (fail closed explicito);
    7 probe falhou/sem runtime.
#>
[CmdletBinding()]
param(
  [string]$RegistryPath = '',
  [ValidateSet('Auto', 'V1', 'V2', 'Both')]
  [string]$Mode = 'Auto',
  [string[]]$ProbeCommand = @('opencode', '--version'),
  [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot 'lib\RuntimeAdapters.ps1'
. $lib

$probeBound = $PSBoundParameters.ContainsKey('ProbeCommand')
try {
  $reg = Read-RuntimeRegistry -RegistryPath $RegistryPath
}
catch {
  $msg = $_.Exception.Message
  if ($AsJson) { Write-Output ('{"decision":"unresolved","reason":"' + ($msg -replace '"', "'") + '"}') }
  else { Write-Host ('unresolved: ' + $msg) }
  exit 6
}

if ($probeBound) {
  $r = Resolve-OpencodeRuntime -Registry $reg -Mode $Mode -ProbeCommand $ProbeCommand
}
else {
  $r = Resolve-OpencodeRuntime -Registry $reg -Mode $Mode
}

if ($AsJson) {
  $rid = ''
  if ($null -ne $r.RuntimeId) { $rid = [string]$r.RuntimeId }
  $reason = ([string]$r.Reason -replace '"', "'")
  Write-Output ('{"decision":"' + [string]$r.Decision + '","runtime_id":"' + $rid + '","generation":' + [int]$r.Generation + ',"reason":"' + $reason + '"}')
}
else {
  $rid = '(nenhum)'
  if ($null -ne $r.RuntimeId) { $rid = [string]$r.RuntimeId }
  Write-Host ('decision=' + [string]$r.Decision + ' runtime=' + $rid + ' generation=' + [int]$r.Generation + ' reason=' + [string]$r.Reason)
}

if ([string]$r.Decision -eq 'target') { exit 0 }
if ([bool]$r.ProbeError) { exit 7 }
exit 6
