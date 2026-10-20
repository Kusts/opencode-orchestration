<#!
.SYNOPSIS
    F1-S5 grant source snapshot + deny-only projection (fixture only).
.DESCRIPTION
    Slice S5 (fixture-only; flags OFF; sem claim runtime-real). Esta lib NAO
    executa workers, NAO verifica nada, NAO aprova DONE e NAO produz
    autoridade de grant: ela LE a task canonica + o registry canonico de
    grants e devolve uma PROJECAO PURA deny-only (observacao).

    D1. Get-NDGrantSourceSnapshot: le a task canonica (objeto ja lido via
    Get-OrchestrationTask) com o papel do recibo (receipt.agent) e chama
    Get-OrchestrationEffectiveGrants (a INTERSECAO do kernel: baseline do
    papel /\ task /\ runtime-capability /\ environment; sensivel so com as
    tres listas + HumanApproved). Esta lib NAO reimplementa e NAO amplia a
    interseccao. Saida: ok, reason, source_revision, grants (ordenado
    ordinal), denied_by_default=true, authority=false. Erros fail-closed:
    grant-source-task-missing, grant-source-role-missing,
    grant-source-registry-missing, grant-source-invalid,
    grant-source-unavailable.

    D2. Test-NDGrantProjection: projecao pura deny-only. Compara ordinal
    (case-sensitive), universo fechado: pedido fora do efetivo,
    desconhecido ou invalido => denied; lista pedida vazia => clear
    (abstencao, jamais allow). Nunca emite allow nem autoridade. Saida:
    ok, denied ([{grant, reason}]), reason (grant-projection-clear |
    grant-projection-denied | grant-projection-invalid), authority=false.

    source_revision: hash deterministico (Get-NativeDispatchHash32, SHA-256
    UTF-8 truncado em 32 hex, o mesmo algoritmo documentado na bridge) sobre
    o material canonico:
      'ndgrant1;taskrev=<revision>;flags=<hash32 do texto cru do flags file>;grants=<g1,g2,...>'
    onde <g1,g2,...> e a lista efetiva ordenada ordinal unida por ',' (vazia
    quando o efetivo e vazio). Sensivel a mudanca de task, de flags e do
    conjunto efetivo.

    LIMITACOES EXPLICITAS (fixture-only):
      * Formas vindas de JSON: arrays ANINHADOS sao preservados pelo
        ConvertFrom-Json em PS 5.1 e PS7 (verificado); o perigo e o
        achatamento no pipeline (array de um elemento devolvido por
        pipeline vira escalar) e escalares escritos a mao no arquivo da
        task. O snapshot normaliza SOMENTE o campo 'grants' da task lida
        do kernel ($null => @(); escalar string => 1 elemento; demais
        formas => invalido), igual ao nucleo (Get-TaskKernelCleanList).
        A projecao (Test-NDGrantProjection) e ESTRITA: exige arrays (sem
        coercao); escalar => grant-projection-invalid.
      * A revisao dos flags e o hash do texto cru do arquivo de flags: troca
        de arquivo com mesmo conteudo nao muda a revisao (conteudo e o que
        importa para a projecao).
      * A projecao e observacao da bridge: quem forja bridge/contexto mente
        sobre o snapshot; o hook valida forma/autoridade, nao autentica o
        produtor (residual declarado, igual a S1).

    Dot-source safe: sem -Action este arquivo define funcoes e nao faz mais
    nada. PS 5.1 e PS7 compativeis. ASCII-only. Sem rede, sem spawn, sem
    segredos, sem escrita.
#>

$ErrorActionPreference = 'Stop'

function Get-NDGPRawField {
    # Leitura CRUA sem enumeracao pelo pipeline (R3b): o valor vai para um
    # holder por ATRIBUICAO, nunca desenrola array de um elemento.
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) {
            return @{ found = $false; value = $null }
        }
        if ($Object -is [System.Collections.IDictionary]) {
            if (-not $Object.Contains($Name)) { return @{ found = $false; value = $null } }
            $h = @{ found = $true; value = $null }
            $h.value = $Object[$Name]
            return $h
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return @{ found = $false; value = $null } }
        $h = @{ found = $true; value = $null }
        $h.value = $prop.Value
        return $h
    }
    catch { return @{ found = $false; value = $null } }
}

function New-NDGPSnapshotFail {
    param([string]$Reason = 'grant-source-unavailable')
    $r = ([string]$Reason).Trim()
    if ([string]::IsNullOrWhiteSpace($r)) { $r = 'grant-source-unavailable' }
    return [pscustomobject][ordered]@{
        ok                = $false
        reason            = $r
        source_revision   = ''
        grants            = @()
        denied_by_default = $true
        authority         = $false
    }
}

function Test-NDGPStringArray {
    # Valida array ESTRITO de strings nao-vazias, sem coercao, sem pipeline
    # (um escalar - inclusive string - e rejeitado, nunca promovido).
    # $NullAsEmpty: $null vira @() (campo ausente = conjunto vazio).
    # Retorna @{ valid; items }.
    param($Value = $null, [bool]$NullAsEmpty = $false)
    try {
        if ($null -eq $Value) {
            if ($NullAsEmpty) { return @{ valid = $true; items = @() } }
            return @{ valid = $false; items = @() }
        }
        if ($Value -is [string]) { return @{ valid = $false; items = @() } }
        if (-not ($Value -is [System.Array])) { return @{ valid = $false; items = @() } }
        $out = @()
        foreach ($e in $Value) {
            if (-not ($e -is [string])) { return @{ valid = $false; items = @() } }
            $t = ([string]$e).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { return @{ valid = $false; items = @() } }
            $out += @([string]$e)
        }
        return @{ valid = $true; items = @($out) }
    }
    catch { return @{ valid = $false; items = @() } }
}

function Get-NDGrantSourceSnapshot {
    <#
    .SYNOPSIS
        Snapshot canonico dos grants de origem (D1). Fail-closed, sem autoridade.
    #>
    [CmdletBinding()]
    param(
        [string]$Role = '',
        $Task = $null,
        $RuntimeCapabilityGrants = $null,
        $EnvironmentGrants = $null,
        $HumanApproved = $false,
        [string]$GrantsPath = '',
        [string]$FlagsPath = '',
        [string]$RepoRoot = ''
    )
    try {
        $role = ([string]$Role).Trim()
        if ([string]::IsNullOrWhiteSpace($role)) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-role-missing')
        }
        if (-not ($HumanApproved -is [bool])) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $rtSlot = Test-NDGPStringArray -Value $RuntimeCapabilityGrants -NullAsEmpty $true
        if (-not [bool]$rtSlot.valid) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $envSlot = Test-NDGPStringArray -Value $EnvironmentGrants -NullAsEmpty $true
        if (-not [bool]$envSlot.valid) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $runtimeArr = @($rtSlot.items)
        $envArr = @($envSlot.items)
        if ($null -eq $Task) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-task-missing')
        }
        $errField = Get-NDGPRawField -Object $Task -Name 'error'
        if ([bool]$errField.found) {
            $code = ([string]$errField.value).Trim().ToUpperInvariant()
            if ($code -ceq 'NOT_FOUND') {
                return (New-NDGPSnapshotFail -Reason 'grant-source-task-missing')
            }
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $needCmds = @('Get-OrchestrationEffectiveGrants', 'Get-NativeDispatchHash32')
        foreach ($nc in $needCmds) {
            try {
                if ($null -eq (Get-Command $nc -ErrorAction SilentlyContinue)) {
                    return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable')
                }
            }
            catch { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
        }
        $gp = ([string]$GrantsPath).Trim()
        if ([string]::IsNullOrWhiteSpace($gp)) {
            try {
                if ($null -ne (Get-Command Get-TaskKernelDefaultGrantsPath -ErrorAction SilentlyContinue)) {
                    $gp = ([string](Get-TaskKernelDefaultGrantsPath -RepoRoot $RepoRoot)).Trim()
                }
            }
            catch { $gp = '' }
        }
        if ([string]::IsNullOrWhiteSpace($gp)) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-registry-missing')
        }
        if (-not (Test-Path -LiteralPath $gp -PathType Leaf)) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-registry-missing')
        }
        try {
            $regText = [IO.File]::ReadAllText($gp, [Text.UTF8Encoding]::new($false))
            $regDoc = ($regText | ConvertFrom-Json)
            if ($null -eq $regDoc) { return (New-NDGPSnapshotFail -Reason 'grant-source-invalid') }
            $gField = Get-NDGPRawField -Object $regDoc -Name 'grants'
            $bField = Get-NDGPRawField -Object $regDoc -Name 'role_baselines'
            if ((-not [bool]$gField.found) -or (-not [bool]$bField.found)) {
                return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
            }
        }
        catch { return (New-NDGPSnapshotFail -Reason 'grant-source-invalid') }
        $tgField = Get-NDGPRawField -Object $Task -Name 'grants'
        $taskGrants = @()
        if (-not [bool]$tgField.found) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $tgRaw = $tgField.value
        if ($null -eq $tgRaw) { $taskGrants = @() }
        elseif ($tgRaw -is [string]) {
            $tt = ([string]$tgRaw).Trim()
            if ([string]::IsNullOrWhiteSpace($tt)) {
                return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
            }
            $taskGrants = @([string]$tgRaw)
        }
        elseif ($tgRaw -is [System.Array]) {
            $tgSlot = Test-NDGPStringArray -Value $tgRaw
            if (-not [bool]$tgSlot.valid) {
                return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
            }
            $taskGrants = @($tgSlot.items)
        }
        else { return (New-NDGPSnapshotFail -Reason 'grant-source-invalid') }
        $revField = Get-NDGPRawField -Object $Task -Name 'revision'
        $revText = '0'
        if ([bool]$revField.found) {
            try { $revText = ([string]([long]$revField.value)) } catch { $revText = '0' }
        }
        $fp = ([string]$FlagsPath).Trim()
        if ([string]::IsNullOrWhiteSpace($fp) -or (-not [IO.Path]::IsPathRooted($fp))) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-invalid')
        }
        $flagsHash = ''
        try {
            $fs = $null
            try { $fs = [IO.File]::Open($fp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
            catch { $fs = $null }
            if ($null -eq $fs) { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
            try {
                $buf = New-Object byte[] 8192
                $mem = New-Object IO.MemoryStream
                $seen = [long]0
                $tooBig = $false
                while ($true) {
                    $n = $fs.Read($buf, 0, 8192)
                    if ($n -le 0) { break }
                    $seen += [long]$n
                    if ($seen -gt [long]65536) { $tooBig = $true; break }
                    $mem.Write($buf, 0, $n)
                }
                if ($tooBig) { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
                $fbytes = $mem.ToArray()
                if (($null -eq $fbytes) -or (@($fbytes).Count -eq 0)) {
                    return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable')
                }
                $strict = New-Object System.Text.UTF8Encoding($false, $true)
                $flagsText = $strict.GetString($fbytes)
                $flagsHash = Get-NativeDispatchHash32 $flagsText
            }
            finally { try { $fs.Dispose() } catch { } }
        }
        catch { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
        if ([string]::IsNullOrWhiteSpace($flagsHash)) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable')
        }
        $eff = @()
        try {
            $effRaw = Get-OrchestrationEffectiveGrants -Role $role -TaskGrants $taskGrants -RuntimeCapabilityGrants $runtimeArr -EnvironmentAuthorizationGrants $envArr -HumanApproved:$HumanApproved -GrantsPath $gp -RepoRoot $RepoRoot
            $effList = New-Object System.Collections.ArrayList
            foreach ($g in @($effRaw)) {
                if ($g -is [string]) {
                    $gt = ([string]$g).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($gt)) { [void]$effList.Add([string]$g) }
                }
            }
            $eff = @($effList.ToArray())
            [Array]::Sort($eff, [System.StringComparer]::Ordinal)
        }
        catch { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
        $material = 'ndgrant1;taskrev=' + $revText + ';flags=' + $flagsHash + ';grants=' + ($eff -join ',')
        $srcRev = ''
        try { $srcRev = Get-NativeDispatchHash32 $material } catch { $srcRev = '' }
        if ([string]::IsNullOrWhiteSpace($srcRev)) {
            return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable')
        }
        return [pscustomobject][ordered]@{
            ok                = $true
            reason            = ''
            source_revision   = $srcRev
            grants            = @($eff)
            denied_by_default = $true
            authority         = $false
        }
    }
    catch { return (New-NDGPSnapshotFail -Reason 'grant-source-unavailable') }
}

function New-NDGPProjectionFail {
    param([string]$Reason = 'grant-projection-invalid')
    $r = ([string]$Reason).Trim()
    if ([string]::IsNullOrWhiteSpace($r)) { $r = 'grant-projection-invalid' }
    return [pscustomobject][ordered]@{
        ok       = $false
        denied   = @()
        reason   = $r
        authority = $false
    }
}

function Test-NDGrantProjection {
    <#
    .SYNOPSIS
        Projecao pura deny-only (D2). Nunca allow, nunca autoridade.
    #>
    [CmdletBinding()]
    param(
        $Snapshot = $null,
        $RequestedGrants = $null,
        $InvocationGrants = $null
    )
    try {
        if ($null -eq $Snapshot) { return (New-NDGPProjectionFail) }
        if (($Snapshot -is [System.Array]) -or ($Snapshot -is [string])) {
            return (New-NDGPProjectionFail)
        }
        $okField = Get-NDGPRawField -Object $Snapshot -Name 'ok'
        if ((-not [bool]$okField.found) -or (-not ($okField.value -is [bool])) -or (-not [bool]$okField.value)) {
            return (New-NDGPProjectionFail)
        }
        $authField = Get-NDGPRawField -Object $Snapshot -Name 'authority'
        if ((-not [bool]$authField.found) -or (-not ($authField.value -is [bool])) -or ([bool]$authField.value -ne $false)) {
            return (New-NDGPProjectionFail)
        }
        $dbdField = Get-NDGPRawField -Object $Snapshot -Name 'denied_by_default'
        if ((-not [bool]$dbdField.found) -or (-not ($dbdField.value -is [bool])) -or (-not [bool]$dbdField.value)) {
            return (New-NDGPProjectionFail)
        }
        $revField = Get-NDGPRawField -Object $Snapshot -Name 'source_revision'
        if ((-not [bool]$revField.found) -or (-not ($revField.value -is [string]))) {
            return (New-NDGPProjectionFail)
        }
        $srcRev = ([string]$revField.value).Trim().ToLowerInvariant()
        if ($srcRev -cnotmatch '\A[a-f0-9]{32}\z') {
            return (New-NDGPProjectionFail)
        }
        $grField = Get-NDGPRawField -Object $Snapshot -Name 'grants'
        if (-not [bool]$grField.found) { return (New-NDGPProjectionFail) }
        $effSlot = Test-NDGPStringArray -Value $grField.value -NullAsEmpty $true
        if (-not [bool]$effSlot.valid) { return (New-NDGPProjectionFail) }
        $reqSlot = Test-NDGPStringArray -Value $RequestedGrants -NullAsEmpty $true
        if (-not [bool]$reqSlot.valid) { return (New-NDGPProjectionFail) }
        $invSlot = Test-NDGPStringArray -Value $InvocationGrants -NullAsEmpty $true
        if (-not [bool]$invSlot.valid) { return (New-NDGPProjectionFail) }
        $effSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($g in @($effSlot.items)) { [void]$effSet.Add([string]$g) }
        $wantSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($g in (@($reqSlot.items) + @($invSlot.items))) {
            [void]$wantSet.Add([string]$g)
        }
        if ($wantSet.Count -eq 0) {
            return [pscustomobject][ordered]@{
                ok        = $true
                denied    = @()
                reason    = 'grant-projection-clear'
                authority = $false
            }
        }
        $denied = New-Object System.Collections.ArrayList
        foreach ($g in @($wantSet)) {
            if (-not $effSet.Contains([string]$g)) {
                [void]$denied.Add(([string]$g))
            }
        }
        $deniedNames = @($denied.ToArray())
        [Array]::Sort($deniedNames, [System.StringComparer]::Ordinal)
        if (@($deniedNames).Count -eq 0) {
            return [pscustomobject][ordered]@{
                ok        = $true
                denied    = @()
                reason    = 'grant-projection-clear'
                authority = $false
            }
        }
        $deniedArr = New-Object System.Collections.ArrayList
        foreach ($g in @($deniedNames)) {
            [void]$deniedArr.Add([pscustomobject][ordered]@{
                grant  = ([string]$g)
                reason = 'grant-not-effective'
            })
        }
        return [pscustomobject][ordered]@{
            ok        = $true
            denied    = @($deniedArr.ToArray())
            reason    = 'grant-projection-denied'
            authority = $false
        }
    }
    catch { return (New-NDGPProjectionFail) }
}
