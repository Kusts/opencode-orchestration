# session-real-lane-credstore.tests.ps1 -- ORFS-LANE-CREDSTORE.
# Testes offline do import do credential store do usuario para o perfil
# isolado da lane scripts/ci/session-real-lane-v2.ps1
# (Import-LaneSessionCredentialStore, espelho de Import-LaneProfileCredentials
# da MCP lane com gate de opt-in): SOMENTE com Test-LaneModelKeyAvailable,
# copia APENAS os 5 nomes fixos (XDG_DATA opencode/auth.json,account.json +
# XDG_STATE opencode/kv.json,model.json,service.json, com fallback
# USERPROFILE/.local quando XDG_* vazio) para o xdg isolado; retorna bool;
# valores nunca em log (so bool/contagem); sem opt-in ou sem arquivos =>
# $false sem copiar nada (perna model segue blocked, fail-closed).
# Sem Pester. Sem rede/spawn/servico real; fixtures 100% sinteticas em TEMP
# (nunca o store real do operador); sem segredo real; so canarios syn-*.
# O helper e o gate sao extraidos da lane via AST (a lane nunca e executada)
# e exercitados em memoria; o resto sao asserts estaticos sobre o texto.
# PS 5.1 e PS7 compativel. ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
function Get-LaneFuncMap($text) {
    $tokens = $null
    $parseErrors = $null
    $map = @{}
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
        if (($null -ne $ast) -and (@($parseErrors).Count -eq 0)) {
            $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($f in @($found)) { $map[[string]$f.Name] = [string]$f.Extent.Text }
        }
    } catch { }
    return $map
}
function Get-CredFileHash([string]$Path) {
    try { return ([string](Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash) } catch { return '' }
}
try {
    Assert-That (Test-Path -LiteralPath $script:LanePath -PathType Leaf) 'lane file exists' $script:LanePath
    $text = ''
    try { $text = [IO.File]::ReadAllText($script:LanePath) } catch { $text = '' }
    Assert-That (-not [string]::IsNullOrEmpty($text)) 'lane text readable' 'empty'
    $funcs = Get-LaneFuncMap $text
    Assert-That (@($funcs.Keys).Count -gt 0) 'lane parses without syntax errors' 'parse falhou'
    Assert-That ($funcs.ContainsKey('Import-LaneSessionCredentialStore')) 'helper Import-LaneSessionCredentialStore exists' 'helper ausente na lane'
    Assert-That ($funcs.ContainsKey('Test-LaneModelKeyAvailable')) 'gate Test-LaneModelKeyAvailable exists' 'gate ausente na lane'
    $script:CredRoot = Join-Path ([IO.Path]::GetTempPath()) ('oo-credstore-test-' + [guid]::NewGuid().ToString('N'))
    $script:OutsideDirs = New-Object System.Collections.ArrayList
    $script:OptKey = 'SYNTEST_CREDSTORE_KEY'
    if (($funcs.ContainsKey('Import-LaneSessionCredentialStore')) -and ($funcs.ContainsKey('Test-LaneModelKeyAvailable'))) {
        Invoke-Expression $funcs['Test-LaneModelKeyAvailable']
        Invoke-Expression $funcs['Import-LaneSessionCredentialStore']
        $userShare = Join-Path (Join-Path $script:CredRoot 'user\share') 'opencode'
        $userState = Join-Path (Join-Path $script:CredRoot 'user\state') 'opencode'
        $targetRoot = Join-Path $script:CredRoot 'target'
        foreach ($d in @($userShare, $userState, $targetRoot)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $allowData = @('auth.json', 'account.json')
        $allowState = @('kv.json', 'model.json', 'service.json')
        # B. sem opt-in => $false e nada copiado (mesmo com store cheio)
        [IO.File]::WriteAllText((Join-Path $userShare 'auth.json'), '{"provider":"syn-credstore-auth-b1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userState 'kv.json'), '{"kv":"syn-credstore-kv-b1"}', (New-Object Text.UTF8Encoding $false))
        $script:ModelKeyEnvNameClean = ''
        try { Remove-Item ('Env:\' + $script:OptKey) -Force -ErrorAction SilentlyContinue } catch { }
        $rb = $false
        try { $rb = Import-LaneSessionCredentialStore -TargetRoot $targetRoot -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) } catch { $rb = 'THREW' }
        Assert-That ([bool]$rb -eq $false) 'sem opt-in: retorna false' ('ret=' + [string]$rb)
        Assert-That (($rb -is [bool])) 'sem opt-in: retorno e bool' 'tipo divergente'
        $leftData = @(Get-ChildItem -LiteralPath (Join-Path $targetRoot 'xdg-data') -Recurse -File -ErrorAction SilentlyContinue)
        $leftState = @(Get-ChildItem -LiteralPath (Join-Path $targetRoot 'xdg-state') -Recurse -File -ErrorAction SilentlyContinue)
        Assert-That ((@($leftData).Count -eq 0) -and (@($leftState).Count -eq 0)) 'sem opt-in: nada copiado' ('data=' + @($leftData).Count + ' state=' + @($leftState).Count)
        # C. opt-in + store vazio => $false
        $script:ModelKeyEnvNameClean = [string]$script:OptKey
        $env:SYNTEST_CREDSTORE_KEY = 'syn-value-c1'
        Remove-Item -LiteralPath (Join-Path $userShare 'auth.json') -Force
        Remove-Item -LiteralPath (Join-Path $userState 'kv.json') -Force
        $rc = Import-LaneSessionCredentialStore -TargetRoot $targetRoot -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState)
        Assert-That ([bool]$rc -eq $false) 'opt-in + store vazio: retorna false' ('ret=' + [string]$rc)
        # D. opt-in + store cheio (5) => $true; 5 presentes; hashes iguais; origem intacta
        [IO.File]::WriteAllText((Join-Path $userShare 'auth.json'), '{"provider":"syn-credstore-auth-d1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userShare 'account.json'), '{"account":"syn-credstore-account-d1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userState 'kv.json'), '{"kv":"syn-credstore-kv-d1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userState 'model.json'), '{"model":"syn-credstore-model-d1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userState 'service.json'), '{"service":"syn-credstore-service-d1"}', (New-Object Text.UTF8Encoding $false))
        $rd = Import-LaneSessionCredentialStore -TargetRoot $targetRoot -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState)
        Assert-That ([bool]$rd -eq $true) 'store cheio: retorna true' ('ret=' + [string]$rd)
        $dstData = Join-Path (Join-Path $targetRoot 'xdg-data') 'opencode'
        $dstState = Join-Path (Join-Path $targetRoot 'xdg-state') 'opencode'
        $gotData = @(Get-ChildItem -LiteralPath $dstData -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        $gotState = @(Get-ChildItem -LiteralPath $dstState -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        Assert-That ((($gotData -join ',') -ceq 'account.json,auth.json')) 'store cheio: data exatos' ($gotData -join ',')
        Assert-That ((($gotState -join ',') -ceq 'kv.json,model.json,service.json')) 'store cheio: state exatos' ($gotState -join ',')
        $hashOk = $true
        foreach ($pair in @(('auth.json', $userShare, $dstData), ('account.json', $userShare, $dstData), ('kv.json', $userState, $dstState), ('model.json', $userState, $dstState), ('service.json', $userState, $dstState))) {
            if ((Get-CredFileHash (Join-Path $pair[1] $pair[0])) -cne (Get-CredFileHash (Join-Path $pair[2] $pair[0]))) { $hashOk = $false }
        }
        Assert-That ($hashOk) 'store cheio: conteudo identico (hash)' 'hash divergente'
        Assert-That (@(Get-ChildItem -LiteralPath $userShare -File).Count -eq 2) 'origem data intacta (copia, nao move)' 'origem alterada'
        # E. parcial (1+1) => $true com conjunto exato
        $target2 = Join-Path $script:CredRoot 'target2'
        New-Item -ItemType Directory -Path $target2 -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $userShare 'account.json') -Force
        Remove-Item -LiteralPath (Join-Path $userState 'model.json') -Force
        Remove-Item -LiteralPath (Join-Path $userState 'service.json') -Force
        $re = Import-LaneSessionCredentialStore -TargetRoot $target2 -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState)
        Assert-That ([bool]$re -eq $true) 'parcial: retorna true' ('ret=' + [string]$re)
        $got2 = @(Get-ChildItem -LiteralPath $target2 -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        Assert-That ((($got2 -join ',') -ceq 'auth.json,kv.json')) 'parcial: so o presente' ($got2 -join ',')
        # F. extras ignorados (allowlist exata, sem recurse)
        [IO.File]::WriteAllText((Join-Path $userShare 'evil.json'), '{"evil":"syn-credstore-evil-f1"}', (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $userShare 'auth.json.bak'), '{"bak":"syn-credstore-bak-f1"}', (New-Object Text.UTF8Encoding $false))
        $subDir = Join-Path $userShare 'sub'
        New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $subDir 'auth.json'), '{"nested":"syn-credstore-nested-f1"}', (New-Object Text.UTF8Encoding $false))
        $target3 = Join-Path $script:CredRoot 'target3'
        New-Item -ItemType Directory -Path $target3 -Force | Out-Null
        $rf = Import-LaneSessionCredentialStore -TargetRoot $target3 -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState)
        Assert-That ([bool]$rf -eq $true) 'extras: allowlist ainda true' ('ret=' + [string]$rf)
        $got3 = @(Get-ChildItem -LiteralPath $target3 -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        Assert-That ((($got3 -join ',') -ceq 'auth.json,kv.json')) 'extras: ignorados (sem evil/bak/sub)' ($got3 -join ',')
        # G. idempotencia: segunda passada nao falha nem muda nada
        $rg = Import-LaneSessionCredentialStore -TargetRoot $target3 -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState)
        Assert-That ([bool]$rg -eq $true) 'idempotente: segunda passada true' ('ret=' + [string]$rg)
        Assert-That ((Get-CredFileHash (Join-Path (Join-Path $target3 'xdg-data\opencode') 'auth.json')) -ceq (Get-CredFileHash (Join-Path $userShare 'auth.json'))) 'idempotente: hash estavel' 'hash mudou'
        # H. TargetRoot vazio => $false sem throw; retorno sempre bool
        $threwH = $false
        $rh = $true
        try { $rh = Import-LaneSessionCredentialStore -TargetRoot '' -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) } catch { $threwH = $true }
        Assert-That ((-not $threwH) -and ([bool]$rh -eq $false)) 'target vazio: false sem throw' ('threw=' + $threwH)
        Assert-That (($rh -is [bool])) 'retorno sempre bool' 'tipo divergente'
        # I. confinamento: tudo sob TargetRoot; origem preservada
        $allDst = @(Get-ChildItem -LiteralPath $target3 -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.FullName })
        $confined = $true
        foreach ($f in @($allDst)) { if (-not ([string]$f).StartsWith($target3, [StringComparison]::OrdinalIgnoreCase)) { $confined = $false } }
        Assert-That ($confined -and (@($allDst).Count -gt 0)) 'confinado ao TargetRoot' ('fora=' + (-not $confined))
        $srcCount = @(Get-ChildItem -LiteralPath $userShare -File).Count + @(Get-ChildItem -LiteralPath $userState -File).Count
        Assert-That ($srcCount -eq 4) 'origem preservada (4 arquivos)' ('count=' + $srcCount)
        # J. fallback de env (XDG_* apontando para fixtures; restore em finally)
        # $null nao atravessa SetEnvironmentVariable igual nas engines
        # (vira '' no PS7); ausencia restaura via Remove-Item Env:.
        $hadData = Test-Path 'Env:\XDG_DATA_HOME'
        $hadState = Test-Path 'Env:\XDG_STATE_HOME'
        $savedData = [string]([Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process'))
        $savedState = [string]([Environment]::GetEnvironmentVariable('XDG_STATE_HOME', 'Process'))
        try {
            [Environment]::SetEnvironmentVariable('XDG_DATA_HOME', (Split-Path -Parent $userShare), 'Process')
            [Environment]::SetEnvironmentVariable('XDG_STATE_HOME', (Split-Path -Parent $userState), 'Process')
            $target4 = Join-Path $script:CredRoot 'target4'
            New-Item -ItemType Directory -Path $target4 -Force | Out-Null
            $rj = Import-LaneSessionCredentialStore -TargetRoot $target4 -UserDataRoot '' -UserStateRoot ''
            Assert-That ([bool]$rj -eq $true) 'fallback env: resolve XDG_* sintetico' ('ret=' + [string]$rj)
            $got4 = @(Get-ChildItem -LiteralPath $target4 -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
            Assert-That ((($got4 -join ',') -ceq 'auth.json,kv.json')) 'fallback env: arquivos no destino' ($got4 -join ',')
        } finally {
            try {
                if ($hadData) { [Environment]::SetEnvironmentVariable('XDG_DATA_HOME', $savedData, 'Process') } else { Remove-Item 'Env:\XDG_DATA_HOME' -Force -ErrorAction SilentlyContinue }
                if ($hadState) { [Environment]::SetEnvironmentVariable('XDG_STATE_HOME', $savedState, 'Process') } else { Remove-Item 'Env:\XDG_STATE_HOME' -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
        $restDataOk = ((Test-Path 'Env:\XDG_DATA_HOME') -eq [bool]$hadData)
        if ([bool]$hadData) { $restDataOk = ($restDataOk -and ([string]([Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')) -ceq $savedData)) }
        $restStateOk = ((Test-Path 'Env:\XDG_STATE_HOME') -eq [bool]$hadState)
        if ([bool]$hadState) { $restStateOk = ($restStateOk -and ([string]([Environment]::GetEnvironmentVariable('XDG_STATE_HOME', 'Process')) -ceq $savedState)) }
        Assert-That (($restDataOk) -and ($restStateOk)) 'env restaurado apos fallback' 'vazamento de env'
        # M. confinamento TEMP (sec): fora => $false SEM copiar + reason;
        # dentro (inclui case-variation) => ok. Alvos fora usam nomes unicos
        # sob o pai do TEMP / irmao com prefixo parecido; limpos no fim.
        $tempBaseNorm = ([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $evilSib = $tempBaseNorm + '-evil-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $dotBase = Join-Path $script:CredRoot 'dothere'
        $sep = [string][IO.Path]::DirectorySeparatorChar
        $dotEsc = $dotBase + $sep + '..' + $sep + '..' + $sep + '..' + $sep + 'oo-escape-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [void]$script:OutsideDirs.Add($evilSib)
        [void]$script:OutsideDirs.Add($dotEsc)
        $whySib = 'UNSET'
        $rSib = 'THREW'
        try { $rSib = Import-LaneSessionCredentialStore -TargetRoot $evilSib -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) -ReasonOut ([ref]$whySib) } catch { $rSib = 'THREW' }
        Assert-That ([bool]$rSib -eq $false) 'irmao-prefixo: retorna false' ('ret=' + [string]$rSib)
        Assert-That ([string]$whySib -ceq 'credstore-target-fora-do-temp') 'irmao-prefixo: reason explicito' ('why=' + [string]$whySib)
        Assert-That (-not (Test-Path -LiteralPath $evilSib)) 'irmao-prefixo: nada criado' 'dir criado fora do TEMP'
        $whyDot = 'UNSET'
        $rDot = 'THREW'
        try { $rDot = Import-LaneSessionCredentialStore -TargetRoot $dotEsc -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) -ReasonOut ([ref]$whyDot) } catch { $rDot = 'THREW' }
        Assert-That ([bool]$rDot -eq $false) 'dotdot-escape: retorna false' ('ret=' + [string]$rDot)
        Assert-That ([string]$whyDot -ceq 'credstore-target-fora-do-temp') 'dotdot-escape: reason explicito' ('why=' + [string]$whyDot)
        Assert-That (-not (Test-Path -LiteralPath $dotEsc)) 'dotdot-escape: nada criado' 'dir criado fora do TEMP'
        $caseDir = Join-Path $script:CredRoot 'casedir'
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        $whyCase = 'UNSET'
        $rCase = 'THREW'
        try { $rCase = Import-LaneSessionCredentialStore -TargetRoot ($caseDir.ToUpperInvariant()) -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) -ReasonOut ([ref]$whyCase) } catch { $rCase = 'THREW' }
        Assert-That ((($rCase -is [bool])) -and ([bool]$rCase -eq $true)) 'case-variation: dentro aceita' ('ret=' + [string]$rCase)
        $gotCase = @(Get-ChildItem -LiteralPath $caseDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        Assert-That ((($gotCase -join ',') -ceq 'auth.json,kv.json')) 'case-variation: arquivos no destino' ($gotCase -join ',')
        $whyIn = ''
        $rIn = 'THREW'
        try { $rIn = Import-LaneSessionCredentialStore -TargetRoot $targetRoot -UserDataRoot (Split-Path -Parent $userShare) -UserStateRoot (Split-Path -Parent $userState) -ReasonOut ([ref]$whyIn) } catch { $rIn = 'THREW' }
        Assert-That ((($rIn -is [bool])) -and ([bool]$rIn -eq $true) -and ([string]$whyIn -ceq '')) 'dentro: reason intocado no sucesso' ('why=' + [string]$whyIn)
        try { Remove-Item ('Env:\' + $script:OptKey) -Force -ErrorAction SilentlyContinue } catch { }
        $script:ModelKeyEnvNameClean = ''
        # K. estaticos: allowlist exata, gate, sem log, sem wildcard
        $credFn = [string]$funcs['Import-LaneSessionCredentialStore']
        Assert-That (($credFn.Contains('auth.json')) -and ($credFn.Contains('account.json')) -and ($credFn.Contains('kv.json')) -and ($credFn.Contains('model.json')) -and ($credFn.Contains('service.json'))) 'allowlist: 5 nomes fixos' 'nome ausente'
        Assert-That ($credFn.Contains('Test-LaneModelKeyAvailable')) 'gate de opt-in no helper' 'gate ausente'
        Assert-That (($credFn.Contains('GetFullPath')) -and ($credFn.Contains('RUNNER_TEMP'))) 'confinamento TEMP no helper' 'checagem ausente'
        Assert-That (($credFn -notmatch 'Write-Host') -and ($credFn -notmatch 'Write-Output') -and ($credFn -notmatch 'Out-File') -and ($credFn -notmatch 'Set-Content') -and ($credFn -notmatch 'Add-Content') -and ($credFn -notmatch 'Write-Verbose') -and ($credFn -notmatch 'Write-Debug')) 'sem log de valores' 'saida detectada'
        Assert-That ($credFn -notmatch '\*') 'sem wildcard (nomes exatos)' 'wildcard detectado'
    }
    $selfText = [IO.File]::ReadAllText($PSCommandPath)
    $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
    try { if (Test-Path -LiteralPath $script:CredRoot) { Remove-Item -LiteralPath $script:CredRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    try { foreach ($od in @($script:OutsideDirs)) { if (Test-Path -LiteralPath ([string]$od)) { Remove-Item -LiteralPath ([string]$od) -Recurse -Force -ErrorAction SilentlyContinue } } } catch { }
    Write-Host ('[credstore-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[credstore-tests] THROW: ' + $_.Exception.Message)
    try { if (($null -ne $script:CredRoot) -and (Test-Path -LiteralPath $script:CredRoot)) { Remove-Item -LiteralPath $script:CredRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    try { foreach ($od in @($script:OutsideDirs)) { if (($null -ne $od) -and (Test-Path -LiteralPath ([string]$od))) { Remove-Item -LiteralPath ([string]$od) -Recurse -Force -ErrorAction SilentlyContinue } } } catch { }
    exit 1
}
