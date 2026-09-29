<#!
.SYNOPSIS
    Cria/atualiza um perfil OpenCode isolado (CLI fino sobre New-OrchestrationProfile).
.DESCRIPTION
    PS 5.1 compativel. ASCII only. Exit codes: 0 ok; 5 falha (inclui
    provisionamento nao-rede e erros internos); 6 perfil/conflito (via
    P7-INSTALL-EXIT-6 do install filho); 7 provisionamento falhou por rede
    (opt-in, perfil de arquivos criado, sem binario). Nunca escreve fora do
    perfil; nunca persiste env; nunca toca o opencode global. -BinaryPath
    informa um binario ja provado para reusar (validado por geracao, sem
    npm; gravado no manifest com provenance 'override').
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot = '',
  [string]$ProfileRoot = '',
  [ValidateSet('opencode-v1', 'opencode-v2')]
  [string]$RuntimeId = 'opencode-v2',
  [switch]$ProvisionRuntime,
  [string]$BinaryPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
}
$lib = Join-Path $RepoRoot 'scripts\runtime\New-OrchestrationProfile.ps1'
. $lib

try {
  $info = New-OrchestrationProfile -RepoRoot $RepoRoot -ProfileRoot $ProfileRoot -RuntimeId $RuntimeId -ProvisionRuntime:$ProvisionRuntime -BinaryOverride $BinaryPath
  if (-not [string]::IsNullOrWhiteSpace([string]$info.WrapperPath)) {
    Write-Host ('wrapper: ' + [string]$info.WrapperPath) -ForegroundColor Green
  }
  exit 0
}
catch {
  $msg = $_.Exception.Message
  Write-Host $msg -ForegroundColor Red
  if ($msg -match '^P7-PROVISION-NETWORK') { exit 7 }
  $m = [regex]::Match($msg, 'P7-INSTALL-EXIT-(\d+)')
  if ($m.Success) { exit ([int]$m.Groups[1].Value) }
  exit 5
}
