<#!
.SYNOPSIS
    Native Worker Dispatch bridge (honesto): DispatchIntent + recibos idempotentes.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1 compatible,
    ASCII-only, no network, no process spawn, no secrets. Never throws on
    operational paths: every failure is an envelope with ok=$false and a
    machine-readable reason.

    Arquitetura honesta (decisao do Planner, nao reabrir): NENHUM script
    PowerShell pode iniciar um worker nativo. O unico executor real e o
    Planner LLM via ferramenta `subagent` (V2) / `task` (V1). Este modulo
    NAO inventa API de spawn. O wiring honesto e:

      PS produz DispatchIntent validado + recibos idempotentes;
      o Planner (LLM) executa workers via subagent (o Executor);
      PS reconcilia resultados no kernel + evidence store.

    Por isso `Invoke-OrchestrationNativeDispatch` recebe um `-Executor`
    scriptblock injetado pelo chamador (harness/teste) ou e chamado pelo
    Planner apos execucao via subagent. Sem Executor, o Planner usa
    `New-OrchestrationNativeDispatchIntent` e executa ele mesmo.

    Nota de simbolo (R1/REV4): `New-OrchestrationDispatchIntent` e o
    construtor do contrato ANTIGO de OrchestrationObjectiveRuntime.ps1
    (GoalId/WorkItemId/ActionRevision). O construtor NOVO deste modulo
    (TaskId/agent/scopes) chama-se `New-OrchestrationNativeDispatchIntent`
    para nao colidir com o nome antigo quando as duas bibliotecas sao
    carregadas na mesma sessao.

    Guarda-corpo central (Gate E): acao autorizada executa; acao nao
    autorizada e impedida ANTES de qualquer efeito externo. O Executor e
    invocado UMA vez e somente apos autorizacao admitida + admissao viva
    do kernel (F1) + recibo persistido + re-checagem de fencing pos-lock
    (F2). `-TestCallback` nunca e prova de producao.

    Idempotencia: recibo `<ReceiptDir>/<goal-hash>/<idempotency_key>.json`
    (F3/REV5: recibos ISOLADOS pela identidade autorizada - o subpath e
    derivado do goal_id da Authorization, sobre um fundo raiz comum)
    escrito como `pending` ANTES do Executor e atualizado para `settled`
    depois. A leitura devolve sempre a fase CANONICALIZADA (F1/REV5:
    'PENDING', ' pending ', 'SETTLED' chegam ao consumidor como
    'pending'/'settled'), entrada existente nao-arquivo no caminho e
    recusada como `receipt-not-regular` (F2/REV5: nao e ausencia e nao
    pode ser sobrescrita) e a persistencia exige destino exatamente o
    arquivo regular do recibo.
    O recibo vincula o fingerprint canonico do Intent completo (F7):
    re-dispatch da mesma key com Intent divergente e recusado como
    colisao, sem reutilizar resultado e sem executar. Recibo `pending`
    de execucao anterior incerta NUNCA da replay automatico (F3):
    retorna `pending-ambiguous` e exige reconciliacao externa explicita
    via `Confirm-OrchestrationDispatchReconciliation`; replay so quando
    a declaracao ORIGINAL persistida no recibo e o novo Intent declaram
    `external_idempotent=$true` com prova documentada (efeito externo
    idempotente pela mesma key; upgrade de idempotencia via novo Intent
    muda o fingerprint e e colisao recusada). Falha ao persistir
    `settled` e erro explicito, nunca silencioso.

    Reconciliacao (F4/REV5): a authorization e conferida ANTES do lock;
    a ownership viva e RELIDA sob o lock imediatamente antes de qualquer
    persistencia (sucesso e falha). Expiracao de lease ou tomada de
    posso durante a espera recusa com `reconcile-ownership-stale` e
    deixa o recibo `pending`.

    Limite honesto do claim F4 (SEC6): `Test-NDReconcileLiveOwnership`
    cobre takeover OCORRIDO ANTES da releitura (o gate pre-lock e a
    releitura sob lock provam esse caso). A sequencia releitura ->
    persistencia NAO e atomica: existe janela residual entre a
    revalidacao da ownership viva e a escrita do recibo, e o lock do
    recibo NAO serializa mutacao do goal. Dentro dessa janela, um
    takeover que aconteca depois da releitura liquida com a autorizacao
    ja validada; o recibo registra reconciled_by/reconciled_generation
    para auditoria. Nao ha alegacao de serializacao cross-recurso.

    Reparse points (REV6/SEC6) + namespace TOCTOU (REV7/R1): `Test-Path
    -PathType Leaf` aceita symlink/junction cujo alvo seja arquivo ou
    diretorio. Nos caminhos de recibo isso seria furo: `<hash-B>` como
    junction para `<hash-A>` faria B ler e gravar recibos no diretorio
    fisico de A (quebra F3), e um `<key>.json` linkado para arquivo
    regular passaria pela prova de "arquivo regular" e leria/escreveria
    no alvo.

    MODELO REAL (SEC7 - sem claim excessivo): isto e DEFESA EM
    PROFUNDIDADE contra namespace alterado, NAO prova de que o codigo
    "nunca segue link". PS 5.1 nao tem abertura kernel sem-seguir-link,
    entao a sequencia checagem -> IO nao e atomica: ha JANELA RESIDUAL
    TOCTOU entre a ultima revalidacao e a operacao de arquivo, e ela
    fica documentada. O que o modulo faz de fato:
      (a) `Test-NDPathWithoutReparsePoint` recusa subdiretorio de goal
          com ReparsePoint (`receipt-dir-reparse-point`) e entrada de
          recibo linkada (`receipt-not-regular`), sem ler nem seguir o
          link NAQUELE caminho;
      (b) `Assert-NDDirIdentity` revalida o diretorio JA RESOLVIDO
          (existe, Container, atributos SEM ReparsePoint, identidade
          estavel por CreationTimeUtc) IMEDIATAMENTE ANTES de cada IO:
          abrir lock, ler recibo, criar temp, mover e provar
          pos-escrita. Divergencia ou atributo ilegivel recusa
          (`receipt-dir-identity-changed` / `receipt-dir-reparse-point`)
          com zero IO no alvo;
      (c) a escrita usa temp+Move e NUNCA escreve direto no destino; a
          prova pos-escrita (PathType Leaf + atributos SEM ReparsePoint
          + key no conteudo) mostra o estado FINAL do destino, e NAO
          prova ausencia de vazamento durante a janela residual.
    Atributo ilegivel conta como rejeicao, nunca como ausencia.

    LOCK RETRY + CLEANUP (REV8/F1 + F2 - fechamento dos dois P1): a
    validacao de identidade do lock AGORA acontece DENTRO de cada
    tentativa do laco de contencao, imediatamente antes do File.Open.
    Antes ela era feita UMA vez antes do laco e ficava valendo para todas
    as tentativas: com o lock contido por outro writer e Start-Sleep
    entre elas, um namespace trocado nesse intervalo so era conferido na
    proxima CHAMADA, e a tentativa seguinte criava/abria o lock no alvo
    substituido. Divergencia recusa na hora com `lock-identity-changed`,
    sem retry e sem IO no alvo; `lock-busy` passa a ser EXCLUSIVAMENTE
    contencao real do lock. Na escrita, identidade divergente entre o
    temporario e o Move NAO faz cleanup pelo caminho invalidado: o
    Remove-Item seguiria o caminho substituido (diretorio recriado,
    junction para outro goal) e apagaria la. O temporario fica
    preservado e a falha e reportada como `receipt-cleanup-deferred`; o
    catch do Move revalida a identidade ANTES de qualquer cleanup e so
    remove com identidade valida.

    CONFIANCA NA RAIZ: `ReceiptDir` (default ou do chamador) e confiavel
    por ESCOLHA DO CHAMADOR; o contrato exige ownership exclusivo do
    diretorio raiz para o produtor de recibos (raiz compartilhada com
    outro escritor esta fora do modelo de ameaca). Hard link PERMITIDO:
    nao e reparse point (segundo nome do MESMO arquivo) e o writer usa
    temp+Move, que substitui a entrada de diretorio sem escrever no
    alvo do hard link. Nao ha claim de atomicidade
    releitura -> persistencia (delimitacao F4 acima).

    HANDOFF NATIVO (PR-A, fatia 1): `Invoke-OrchestrationNativeDispatchPrepare`
    e `Invoke-OrchestrationNativeDispatchClaim` separam a preparacao
    duravel do consumo pre-efeito SEM criar segundo store de recibos,
    sem binding paralelo e sem invocar worker: ambos usam os MESMOS
    recibos (`<ReceiptDir>/<goal-hash>/<key>.json`), o MESMO lock
    (`.dispatch.lock`), os MESMOS helpers (resolucao de namespace,
    identidade de diretorio, fingerprint, autorizacao, admissao viva,
    fencing pos-lock) e a MESMA maquina de fases. Nenhum Executor e
    recebido por essas operacoes: o efeito nativo acontece FORA do
    PowerShell, na tool model-callable da sessao real.

    FRONTEIRA PRE-EFEITO (F1/F2/F3 - fechamento dos blockers de review):
    nenhum caminho que devolva `claimed=$true`, e tambem nenhuma
    reutilizacao idempotente de um preparo, passa sem as tres barreiras
    abaixo, todas sob o lock do recibo do goal:
      (F1) `Test-NDPostLockFencing` IMEDIATAMENTE antes de reutilizar um
          preparo, antes de persistir PREPARED e antes de escrever
          CLAIMED: o goal e relido e tem de estar EXATAMENTE ACTIVE, com
          owner/generation/lease vivos. Takeover, lease expirada ou goal
          terminalizado/enquanto o pretendente espera o lock recusam
          (`post-lock-*`) e deixam o recibo na fase anterior;
      (F2) `Test-NDTaskEffectExclusive`: exclusao de efeito por TASK
          (`(raiz de recibos, task_id)`, independente de GoalId,
          revisao, generation e chave). Varredura INCREMENTAL,
          LIMITADA e fail-closed que caminha TODOS os namespaces de
          goal sob a MESMA raiz, sob o lock de task da raiz e o lock
          do recibo do goal (nunca um segundo store) e recusa
          (`claim-task-already-claimed`) qualquer efeito - CLAIM
          nativo ou Executor legado - enquanto existir recibo
          NAO-RESOLVIDO da mesma task em outro namespace/chave/
          revisao/goal. 'prepared' nao e efeito e nao bloqueia;
          'settled' NAO libera so por estar 'settled' (PRA-SETTLE-FIX4):
          o 'settled' do HANDOFF (marcadores settle_*/handoff_state
          SETTLED) tem porta propria e a liquidacao tem de ser
          RECONSTRUIDA dos campos persistidos no PROPRIO registro
          (Test-NDSettledHandoffProof): kernel_ok EXATAMENTE true,
          evidence_created EXATAMENTE true, evidence_id nao vazio e
          VINCULADO ao marcador duravel de evidencia, settled_by/generation
          contra owner/generation do recibo, linhagem settle_* EXATAMENTE
          igual aos claim_* da chamada que consumiu o preparo, child
          binding (filho distinto da sessao pai), marcadores
          settle_attempt_* e worker_result correlacionados campo a campo e
          integridade semantica RECALCULADA. Token cru indecidivel recusa a
          varredura (claim-task-scan-unreadable); qualquer outra falha de
          prova - inclusive um campo de MESMO TIPO trocado por outro valor
          valido (child session id, evidence_id) - mantem a reserva
          (claim-task-already-claimed) (PRA-SETTLE-FIX5); o
          'settled' LEGADO (sem marcadores de handoff) mantem a porta
          propria: kernel_ok EXATAMENTE true (liquidacao conhecida) nao
          bloqueia, e kernel_ok=false so nao bloqueia se for recusa
          PRE-efeito fresca;
      (F3) `Test-NDReceiptSemanticIntegrity`: o Intent e RECONSTRUIDO do
          PROPRIO recibo e intent_fingerprint, prepared_fingerprint (com
          a sessao ARMAZENADA) e a referencia opaca sao RECALCULADOS e
          comparados campo a campo com o persistido. JSON valido com
          campo semantico adulterado e hash intacto recusa em
          `receipt-integrity-invalid`.
    DELIMITACAO (honesta, mantida): a sequencia ultima revalidacao ->
    escrita do recibo NAO e atomica, e o lock do recibo nao serializa
    mutacao do goal. Um takeover que aconteca DEPOIS da releitura liquida
    dentro da janela residual com a autorizacao ja validada; a trilha
    claimed_by/claimed_generation (e prepared_by/prepared_generation)
    existe para auditoria dessa janela.

    EXCLUSAO DE EFEITO POR TASK (F2, fechamento do achado A): a reserva
    vale para `(raiz de recibos, task_id)` e NAO depende de GoalId,
    revisao, generation nem chave. Um segundo efeito - CLAIM nativo ou
    Executor do caminho legado - e recusado enquanto existir QUALQUER
    recibo NAO-RESOLVIDO da MESMA task em QUALQUER namespace de goal sob
    a MESMA raiz: 'claimed' (efeito nativo em DISPATCH_UNCERTAIN) e
    'pending' (efeito legado incerto) bloqueiam; 'prepared' NAO e efeito
    e nao bloqueia; 'settled' NAO e permissao automatica de segundo efeito
    (PRA-SETTLE-FIX4): o 'settled' do HANDOFF (qualquer marcador de
    handoff - `Test-NDHandoffRecordMarkers`) so libera a reserva quando a
    liquidacao esta
    RECONSTRUIDA dos campos persistidos no PROPRIO registro
    (Test-NDSettledHandoffProof): kernel conhecido (kernel_ok EXATAMENTE
    true), evidencia exigida e VINCULADA (evidence_created EXATAMENTE true +
    evidence_id nao vazio, iguais ao marcador settle_evidence_*), identidade
    do recibo (settled_by/generation contra owner/generation), linhagem
    settle_* EXATAMENTE igual aos claim_* da chamada que consumiu o preparo,
    child binding, marcadores settle_attempt_* e worker_result correlacionados
    campo a campo e integridade semantica RECALCULADA. Forma crua indecidivel
    ou semantica adulterada recusa a varredura; liquidacao nao provada
    continua reservando a task - inclusive quando um campo de MESMO TIPO foi
    trocado por outro valor valido (PRA-SETTLE-FIX5). A prova do 'settled'
    marcado roda ANTES da atribuicao de task: um task_id TROCADO por outro
    id valido, com hashes intactos, nao transforma o registro em "outra
    task" (o fingerprint RECALCULADO divergiria) e a liquidacao teria de
    ser provada de novo sobre o proprio registro; o
    'settled' LEGADO (sem marcador algum de handoff) tem porta propria, onde
    kernel_ok EXATAMENTE true (liquidacao conhecida) nao bloqueia e um
    kernel_ok=false so nao bloqueia quando e recusa PRE-efeito fresca.
    A identidade de um recibo na varredura e `(namespace do goal,
    chave)` - NUNCA a chave sozinha: a mesma chave em dois goals sao dois
    recibos distintos. A excecao de replay vale somente para o arquivo
    EXATO da operacao em curso (mesmo namespace + mesma chave), o que
    preserva o replay legado idempotente com a prova externa ORIGINAL
    do proprio recibo - sem excecao cross-key e sem excecao cross-goal.
    NAO existe segundo store: a varredura caminha os namespaces ja
    existentes sob a raiz, de forma INCREMENTAL, com cap rigido de
    namespaces/entradas e de bytes por arquivo; a identidade da raiz e de
    cada subdiretorio e reassertada imediatamente antes de enumerar/ler;
    reparse, identidade divergente, nome inesperado, fase desconhecida ou
    registro estruturalmente invalido recusam em modo fail-closed; o cap
    agora inclui um teto GLOBAL de entradas (4096) entre todas as
    namespaces, a enumeracao usa EnumerateFileSystemEntries (para ver
    diretorio/junction com nome <chave>.json) e a leitura de cada recibo e
    limitada por stream (cap+1 bytes, sem confiar no FileInfo.Length).
    Fail-closed tambem para recibo ILEGIVEL/truncado/JSON invalido,
    schema desconhecido, chave divergente do nome, task_id AUSENTE/INVALIDO
    (nao atribuivel => NAO assumido nao-relacionado), fase desconhecida,
    hash de namespace divergente do goal do registro ou integridade
    SEMANTICA adulterada - e tudo isso vale ANTES de decidir a task: a
    varredura so ignora um registro de OUTRA task quando ele passa pela
    validacao estrutural FECHADA (`Test-NDReceiptScanRecord`) e o task_id
    dele e diferente do da operacao. Para as fases de handoff da propria
    task - e de qualquer task, ja que a validacao precede a atribuicao - a
    integridade SEMANTICA e RECALCULADA (`Test-NDReceiptSemanticIntegrity`);
    as fases do legado ('pending'/'settled') passam pela validacao
    estrutural fechada, que nao exige o material semantico do handoff.
    PRA-SETTLE-FIX5: a fronteira semantica passou a ser os MARCADORES, nao
    a fase: QUALQUER registro que carregue marcadores de handoff
    (`handoff_state`, `settle_*`, `claim_*`, `claimed_*`, `prepared_*`,
    `settled_by`, `settled_generation`, `reference`, `session_id` e - desde
    PRA-SETTLE-FIX6C - `base_revision`, `prompt_hash`, `scope`,
    `acceptance_criteria`, `external_idempotency_proof` e
    `prepared_fingerprint` - `Test-NDHandoffRecordMarkers`) exige a
    integridade semantica RECALCULADA em qualquer fase, e um 'settled'
    marcado exige TAMBEM a prova ESTRITA da liquidacao
    (`Test-NDSettledHandoffProof`) ANTES de poder ser ignorado por task
    divergente. Um 'settled' do handoff com o task_id trocado por outro id
    VALIDO e hashes intactos portanto NAO passa por "outra task, ignoro":
    ele nao libera segundo efeito por caminho algum. Combinacoes de
    marcadores malformadas/contraditorias falham fechado (varredura
    indecidivel ou reserva mantida), e um handoff malformado NUNCA e lido
    como legado - o legado de verdade nao tem marcador nenhum.

    LOCK DE TASK (ordem unica): o lock de task vive na RAIZ dos recibos
    (`.ndtask-<hash32(task_id)>.lock`) e e compartilhado pelo CLAIM e
    pelo Invoke legado. A ordem de aquisicao e SEMPRE lock de task ->
    lock do recibo; nenhum caminho segura dois locks de task ao mesmo
    tempo e nenhum adquire o lock do recibo sem antes ter o de task, o
    que torna a ordem estavel e sem ciclo. O CLAIM deriva o task_id de
    uma leitura PREVIA do proprio recibo - usada SOMENTE para nomear o
    lock - e, ja sob o lock do recibo, reconfere que o task_id do
    registro e o mesmo (divergencia = recusa). DELIMITACAO: o lock de
    task serializa a reserva + a escrita do recibo entre processos;
    ele NAO serializa mutacao do GoalKernel e a sequencia ultima
    revalidacao -> escrita do recibo continua NAO atomica.

    FASES DO RECIBO (PR-A): 'prepared' -> 'claimed' -> 'settled'.
    'prepared' = tentativa autorizada persistida antes de qualquer
    efeito; 'claimed' = consumo UNICO registrado com
    handoff_state='DISPATCH_UNCERTAIN' antes da fronteira do efeito;
    'settled' e escrita pelo caminho de liquidacao - o legado hoje e,
    desde a fatia 2, tambem o SETTLE correlacionado do handoff nativo.
    PREPARE e CLAIM NAO liquidam, nao verificam e nao avancam Goal/Task:
    eles so governam a fronteira pre-efeito. SETTLE liquida, mas tambem
    NAO verifica: worker so declara candidate_pass|failed|blocked, e
    candidate/persisted/verified/advanced seguem estados separados.

    INVARIANTE DE COMPATIBILIDADE (legado intacto): o caminho legado
    (`Invoke-OrchestrationNativeDispatch`) le recibos com
    `Read-NDReceipt` SEM `-AllowHandoffPhases`. As fases 'prepared' e
    'claimed' portanto NUNCA entram na maquina legada: ela recusa com
    `receipt-phase-unknown`, com 0 chamadas de Executor e sem
    sobrescrever o arquivo. Por construcao, um recibo preparado ou
    consumed nao pode fazer o Executor legado rodar um segundo efeito.
    O mesmo vale para `Confirm-OrchestrationDispatchReconciliation`.

    CONFIANCA NO DESCRITOR (sem autenticacao, sem texto do modelo como
    autorizacao): `Test-NDHostCallDescriptor` valida apenas a FORMA do
    descritor de chamada (session/message/call/caller/target agent).
    A identidade do evento do host precisa ser obtida de forma
    INDEPENDENTE pelo hospedeiro (plugin/hook da sessao real, com
    sessionID/messageID/callID proprios do runtime). Este modulo nao
    consegue autenticar um descritor fornecido: a conferencia de
    identidade/argumento e vinculacao de estado, nunca prova de quem
    chamou. Sem provenance independente, o resultado segue sendo claim
    nao verificado.

    SETTLE CORRELACIONADO (PR-A, fatia 2):
    `Invoke-OrchestrationNativeDispatchSettle` fecha a liquidacao de UM
    handoff nativo sem criar segundo store, segundo binding, segundo
    lock nem chamada de worker:
      - USA os MESMOS recibos (`<ReceiptDir>/<goal-hash>/<key>.json`), o
        MESMO lock de recibo (`.dispatch.lock`), o MESMO lock de task
        (`.ndtask-<hash32(task_id)>.lock` na RAIZ) e a MESMA ordem de
        aquisicao (task -> recibo) do CLAIM e do Invoke legado;
      - EXIGE fase 'claimed' (nunca 'prepared' nem 'pending' do legado) e
        so transita para 'settled' DEPOIS de evidencia canonica +
        worker-result no kernel. Essa escrita E a liberacao da reserva de
        task (F2): nao existe registro de reserva separado, a varredura
        `Test-NDTaskEffectExclusive` simplesmente para de bloquear
        quando o unico recibo nao-resolvido da task vira 'settled';
      - VINCULA a liquidacao a chamada EXATA do host que consumiu o
        preparo (mesma sessao/mensagem/call/caller/target) mais a sessao
        FILHA informada pelo hospedeiro (execute.after +
        ctx.session.get(child).parentID). O descritor continua sendo
        dado, nunca autoridade: esta funcao confere forma e estado;
      - NUNCA aceita 'verified_pass'/'done'/'approved' como status de
        worker (`Test-OrchestrationDispatchResultShape`), nunca marca
        settled porque uma tool filha devolveu texto e nunca reexecuta
        efeito: `executor_calls` e sempre 0;
      - ESCRITA PARCIAL fica recuperavel sem retry implicito: evidencia
        feita e kernel recusado deixam 'claimed' e a retentativa repete a
        UNICA escrita CAS no kernel; kernel feito e recibo nao gravado
        deixam 'claimed' e a retentativa NAO conclui sozinha - com a
        revisao avancada alem da esperada e sem marcador atomico de
        liquidacao no kernel, nao ha prova causal de que a escrita foi
        desta claim, e o estado devolvido e o bloqueio seguro
        `settle-kernel-commit-ambiguous` (sem criar evidencia para provar
        escrita anterior, sem reescrever o kernel, sem release e sem
        retry; reconciliacao e manual do operador). A prova de que a
        liquidacao esta persistida NUNCA vem do retorno do escritor:
        Write-NDReceipt devolvendo False DEPOIS de mover o arquivo
        'settled' para o destino nao prova que nada foi gravado, e
        devolvendo True nao prova que o disco contem o registro EXATO. Em
        AMBOS os casos a prova vem da RELEITURA sob os dois locks
        (Test-NDSettledReceiptPersisted: comparacao profunda campo a
        campo + forma crua): registro 'settled' EXATO confirma a liquidacao;
        prova indisponivel devolve settle-receipt-proof-*, sem afirmar
        fase e sem liberar reserva;
        duplicata identica e
        idempotente e candidato DIVERGENTE para a mesma claim e conflito
        (settle-result-conflict). A duplicata so e idempotente quando o
        PROPRIO registro 'settled' prova a liquidacao - forma crua,
        kernel_ok exatamente true, vidence_created exatamente true e
        vidence_id nao vazio (settle-duplicate-unproven no caso
        contrario) - e a linhagem devolvida e sempre a ARMAZENADA, nunca a
        apresentada. A ausencia de execute.after (child
        faltando, com erro ou malformado) NAO significa ausencia de
        efeito: o recibo segue 'claimed'/DISPATCH_UNCERTAIN, sem
        liberacao e sem retry.

    Holds preservados: `dispatchWorker/waitForSettlement/
    requestPlannerContinuation/cancelAuthorizedExecution` continuam em HOLD
    em OrchestrationRuntimeAdapterContract.ps1. Este modulo nao remove
    holds, nao ativa flags (`runtime_grant_enforcement` continua OFF).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $NDLibDir = $PSScriptRoot
    foreach ($NDLib in @('OrchestrationGoalKernel.ps1', 'OrchestrationEvidenceStore.ps1', 'OrchestrationTaskKernel.ps1')) {
        $NDPath = Join-Path $NDLibDir $NDLib
        if (Test-Path -LiteralPath $NDPath -PathType Leaf) { . $NDPath }
    }
}
catch { }

function Get-NDValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Try-NDRawProperty {
    <#
    .SYNOPSIS
        Le UMA propriedade CRUA (objeto, array, escalar) SEM passar o valor
        pelo pipeline de saida. Somente leitura. Nunca lanca.
    .DESCRIPTION
        PRA-SETTLE-FIX4: `Get-NDValue` devolve o valor da propriedade pelo
        pipeline, e o PowerShell DESENROLA array de um elemento nesse
        caminho - um campo cujo token cru e uma lista de um elemento
        chegaria ao chamador como escalar. Para propriedades cujo valor e
        OBJETO (ou qualquer coisa que nao caiba num token escalar) esse
        desenrolamento seria exactly a confusao que a prova do recibo
        'settled' precisa detectar.

        Aqui a propriedade e lida na mao (indice de dicionario ou
        PSObject.Properties) e o valor CRU - lista inclusive - vai para o
        [ref] do chamador por ATRIBUICAO, que nunca desenrola. Devolve
        $true somente quando a propriedade existe; ausencia, objeto nulo ou
        nome vazio devolvem $false com o [ref] limpo. Nunca enumera.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '', [ref]$Value = $null)
    try {
        if ($null -ne $Value) { $Value.Value = $null }
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $false }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                if ($null -ne $Value) { $Value.Value = $Object[$Name] }
                return $true
            }
            return $false
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -ne $prop) {
            if ($null -ne $Value) { $Value.Value = $prop.Value }
            return $true
        }
        return $false
    }
    catch { return $false }
}

function Get-NativeDispatchHash32 {
    param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            $h = $sha.ComputeHash($bytes)
            return (([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant().Substring(0, 32))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-OrchestrationDispatchRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return ([string]$RepoRoot).Trim() }
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    }
    catch { return '' }
}

function Get-OrchestrationDispatchReceiptDir {
    <#
    .SYNOPSIS
        Raiz comum dos recibos (log de ativacao + subdiretorios por goal).
    .DESCRIPTION
        SEC7 (honestidade): esta raiz e CONFIAVEL POR ESCOLHA DO
        CHAMADOR. O modulo nao audita nem isola a raiz: o contrato exige
        ownership exclusivo do diretorio para o produtor de recibos. Raiz
        compartilhada com outro escritor (ou removida/substituida por
        terceiro) esta fora do modelo de ameaca. O isolamento que o
        modulo GARANTE por Codigo e apenas o subnamespace por goal
        (`<raiz>/<goal-hash>`, F3/REV5) mais as revalidacoes de
        `Assert-NDDirIdentity` antes de cada IO.
    #>
    [CmdletBinding()]
    param([string]$ReceiptDir = '', [string]$RepoRoot = '')
    try {
        if (-not [string]::IsNullOrWhiteSpace($ReceiptDir)) { return ([string]$ReceiptDir).Trim() }
        $root = Get-OrchestrationDispatchRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return '' }
        $dir = Join-Path (Join-Path $root 'cache') 'native-dispatch-receipts'
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return '' }
        return $dir
    }
    catch { return '' }
}

function Test-NDPathWithoutReparsePoint {
    <#
    .SYNOPSIS
        $true SOMENTE quando o caminho existe e NAO e reparse point.
    .DESCRIPTION
        `Test-Path -PathType Leaf` aceita symlink/junction cujo alvo seja
        arquivo ou diretorio: o link passa na checagem e o codigo passa a
        ler/gravar no ALVO, fora do destino esperado. Isso quebraria o
        isolamento por goal (namespace `<raiz>/<hash-B>` apontando para
        `<raiz>/<hash-A>`) e a prova de "arquivo regular do recibo".

        Usa `[IO.File]::GetAttributes`, que NAO segue o link: a flag
        ReparsePoint aparece para symlink E junction. Hard link NAO e
        reparse point (segundo nome do MESMO arquivo) e segue permitido,
        mesma decisao do resto do pacote.

        Fail-closed: atributos ilegiveis (permissao, path invalido) e
        caminho inexistente devolvem $false. Nunca devolve $true por
        excesso de confianca, e nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Path = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $attrs = [IO.File]::GetAttributes($Path)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-NDDirCreationTimeUtcTicks {
    <#
    .SYNOPSIS
        CreationTimeUtc (ticks, cultura invariante) de UM diretorio.
    .DESCRIPTION
        Identidade estavel usada por `Assert-NDDirIdentity`: capturada
        na resolucao do namespace e comparada antes de cada IO. Devolve
        '' quando ilegivel ou nao-confiavel (excecao, caminho vazio,
        ticks <= 0 - filesystem sem creation time); ilegivel NUNCA vale
        como identidade. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Path = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
        $dt = [IO.Directory]::GetCreationTimeUtc($Path)
        if ($null -eq $dt) { return '' }
        $ticks = [long]$dt.Ticks
        if ($ticks -le 0) { return '' }
        return ($ticks.ToString([Globalization.CultureInfo]::InvariantCulture))
    }
    catch { return '' }
}

function Assert-NDDirIdentity {
    <#
    .SYNOPSIS
        REV7/R1 (S1): revalida a identidade do diretorio de recibos de
        UM goal IMEDIATAMENTE ANTES de cada IO. Fail-closed.
    .DESCRIPTION
        `Resolve-NDGoalReceiptDir` valida o namespace UMA vez. Entre
        essa resolucao e o IO existe janela TOCTOU: `<raiz>/<hash-B>`
        pode ser removido e substituido por junction para `<hash-A>` (ou
        por outro diretorio) e o codigo passaria a ler/gravar no alvo.
        Esta funcao encurta essa janela por defesa em profundidade.

        Modelo honesto (SEC7): PS 5.1 nao tem abertura kernel
        sem-seguir-link, entao checagem -> IO continua NAO atomico. A
        janela residual permanece documentada; o que esta funcao garante
        e que um namespace JA alterado (ou ilegivel) recusa antes de
        qualquer IO novo no alvo.

        Verificacoes, na ordem, todas fail-closed:
          1. caminho legivel E diretorio (Container);
          2. atributos SEM ReparsePoint -> 'receipt-dir-reparse-point';
          3. identidade estavel: CreationTimeUtc (ticks) identico ao
             capturado na resolucao (`-Expected`) ->
             'receipt-dir-identity-changed' quando divergir ou for
             ilegivel.
        `-Expected` vazio (chamador que nao capturou identidade) exige
        apenas 1 e 2. Devolve @{ok, reason}. Nunca lanca e nunca
        devolve ok=$true por excesso de confianca.
    #>
    [CmdletBinding()]
    param([string]$Path = '', [string]$Expected = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-identity-changed' }
        }
        $attrs = $null
        try { $attrs = [IO.File]::GetAttributes($Path) } catch { $attrs = $null }
        if ($null -eq $attrs) {
            # inexistente ou ilegivel: nao e mais o diretorio resolvido
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-identity-changed' }
        }
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-reparse-point' }
        }
        if (($attrs -band [IO.FileAttributes]::Directory) -eq 0) {
            # existe mas nao e Container: o alvo do IO nao e um diretorio
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-identity-changed' }
        }
        if (-not [string]::IsNullOrWhiteSpace($Expected)) {
            $created = Get-NDDirCreationTimeUtcTicks -Path $Path
            if (([string]::IsNullOrWhiteSpace($created)) -or ($created -cne ([string]$Expected))) {
                return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-identity-changed' }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-identity-changed' }
    }
}

function Test-NDReceiptDirLive {
    <#
    .SYNOPSIS
        Conveniencia dos callers: '' quando o diretorio de recibos
        continua identico ao resolvido; senao a razao de recusa.
    .DESCRIPTION
        Envolve `Assert-NDDirIdentity` para os callers poderem recusar
        com a razao correta em uma linha, antes de cada operacao de
        arquivo (lock, leitura, escrita). Fail-closed: qualquer duvida
        devolve razao, nunca ''. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Dir = '', [string]$Expected = '')
    try {
        $chk = Assert-NDDirIdentity -Path $Dir -Expected $Expected
        if ([bool](Get-NDValue $chk 'ok' $false)) { return '' }
        return ([string](Get-NDValue $chk 'reason' 'receipt-dir-identity-changed'))
    }
    catch { return 'receipt-dir-identity-changed' }
}

function Test-NDLockPathOpenSafe {
    <#
    .SYNOPSIS
        $true somente quando o caminho do lock pode ser aberto sem
        risco de cair em um alvo linkado.
    .DESCRIPTION
        REV7/R1 (S1): pre-checagem de ReparsePoint do caminho do lock
        ANTES do `[IO.File]::Open`. `Test-Path` segue o link e um
        symlink pendente apareceria como ausencia (o OpenOrCreate
        criaria o arquivo NO ALVO, fora do namespace). Caminho
        inexistente (atributo ilegivel) e seguro: o OpenOrCreate cria
        arquivo regular novo. Link (inclusive pendente) recusa.
        Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Path = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $attrs = $null
        try { $attrs = [IO.File]::GetAttributes($Path) } catch { $attrs = $null }
        if ($null -eq $attrs) { return $true }
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return $true
    }
    catch { return $false }
}

function Resolve-NDGoalReceiptDir {
    <#
    .SYNOPSIS
        Resolve o subdiretorio de recibos de UM goal com motivo explicito.
    .DESCRIPTION
        Variante com estado de `Get-NDGoalReceiptDir`: devolve
        @{ok, reason, dir, created_utc} para o chamador poder recusar
        com a razao CORRETA em vez de colapsar tudo em
        `receipt-dir-unresolvable`. Reasons:
          ''                         resolvido
          receipt-dir-unresolvable   raiz/goal invalidos, IO falhou ou
                                     identidade (CreationTimeUtc)
                                     ilegivel no diretorio resolvido
          receipt-dir-reparse-point  subdiretorio e link (SEC6/REV6)

        Reforco de seguranca (REV6): se `<raiz>/<hash>` existe e tem o
        atributo ReparsePoint (symlink/junction, inclusive link pendente
        cujo alvo nao existe), a resolucao RECUSA antes de qualquer IO -
        sem ler, sem gravar, sem criar. Sem isso, B apontado para A
        leria e gravaria recibos no diretorio fisico de A, quebrando o
        isolamento por goal (F3/REV5). Atributos ilegiveis contam como
        rejeicao. Depois de criar (ou confirmar) o diretorio, a checagem
        e repetida para cobrir a corrida entre a checagem e a criacao.

        Identidade (REV7/R1): ao resolver, o CreationTimeUtc (ticks) do
        diretorio e capturado em `created_utc`. Os callers reassertam
        essa identidade com `Assert-NDDirIdentity` IMEDIATAMENTE antes
        de cada IO; diretorio recriado ou trocado nesse intervalo recusa
        com `receipt-dir-identity-changed`. Identidade ilegivel na
        resolucao recusa com `receipt-dir-unresolvable` (fail-closed).
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$GoalId = '')
    try {
        $gid = ([string]$GoalId).Trim()
        if (([string]::IsNullOrWhiteSpace($RootDir)) -or ([string]::IsNullOrWhiteSpace($gid))) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-unresolvable'; dir = ''; created_utc = '' }
        }
        $sub = Get-NativeDispatchHash32 $gid
        if ([string]::IsNullOrWhiteSpace($sub)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-unresolvable'; dir = ''; created_utc = '' }
        }
        $dir = Join-Path $RootDir $sub
        # (a) entrada ja existente (inclusive link pendente, cujo alvo
        # nao existe): GetAttributes reconhece o reparse point SEM seguir
        # o link. Caminho inexistente dispara excecao e cai na criacao
        # abaixo. Atributos ilegiveis tambem recusam (fail-closed).
        $attrsRead = $false
        try { [void][IO.File]::GetAttributes($dir); $attrsRead = $true } catch { $attrsRead = $false }
        if ($attrsRead -and (-not (Test-NDPathWithoutReparsePoint -Path $dir))) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-reparse-point'; dir = ''; created_utc = '' }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-unresolvable'; dir = ''; created_utc = '' } }
        # (b) re-checagem pos-criacao: cobre a corrida entre a checagem
        # acima e a criacao do diretorio.
        if (-not (Test-NDPathWithoutReparsePoint -Path $dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-reparse-point'; dir = ''; created_utc = '' }
        }
        # (c) identidade estavel do diretorio resolvido, carregada no
        # envelope para reassert antes de cada IO (REV7/R1).
        $created = Get-NDDirCreationTimeUtcTicks -Path $dir
        if ([string]::IsNullOrWhiteSpace($created)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-unresolvable'; dir = ''; created_utc = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; dir = $dir; created_utc = $created }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'receipt-dir-unresolvable'; dir = ''; created_utc = '' } }
}

function Get-NDGoalReceiptDir {
    <#
    .SYNOPSIS
        Subdiretorio de recibos de UM goal, derivado do goal_id (F3/REV5).
    .DESCRIPTION
        Isola os recibos pela identidade autorizada: <RootDir>/<goal-hash>.
        O fundo raiz comum (ReceiptDir default ou o do chamador) continua
        sendo o mesmo; a diferenciacao e apenas por goal_id.

        Consequencia honesta: a consulta de um recibo por uma
        Authorization de OUTRO goal enxerga AUSENCIA (o caminho do outro
        goal nao contem a key), indistinguivel de key nunca usada, e
        segue o mesmo caminho normal de admissao (que recusa em
        task-not-in-goal / owner-mismatch). Nao ha oraculo de existencia
        cross-goal, e Confirm-* de um goal nunca enxerga o recibo de
        outro. Tomada de posse (troca de owner DENTRO do mesmo goal)
        continua preservada: o namespace usa SOMENTE o goal_id, e a
        identidade (owner/generation) continua protegendo duplicata e
        liquidacao. Retorna '' quando nao da para resolver.

        REV6/SEC6: devolve '' tambem quando o subdiretorio existe como
        reparse point (symlink/junction) - um link direcionaria leitura e
        gravacao para o diretorio fisico de outro goal. O chamador que
        precisa da razao exata usa `Resolve-NDGoalReceiptDir`.
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$GoalId = '')
    try {
        $state = Resolve-NDGoalReceiptDir -RootDir $RootDir -GoalId $GoalId
        return ([string](Get-NDValue $state 'dir' ''))
    }
    catch { return '' }
}

function Test-NDTaskId {
    param([string]$Value)
    try {
        $cmd = Get-Command Test-TaskKernelId -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return [bool](Test-TaskKernelId -TaskId $Value) }
        return (([string]$Value) -cmatch '^[a-z0-9][a-z0-9._-]{2,63}$')
    }
    catch { return $false }
}

function Test-NDCriterionRef {
    param($Value)
    try {
        if ($Value -isnot [string]) { return $false }
        return (([string]$Value) -cmatch '^criterion:[0-9]+$')
    }
    catch { return $false }
}

function New-OrchestrationNativeDispatchIntent {
    <#
    .SYNOPSIS
        Constroi um envelope DispatchIntent puro e validado. Sem efeito externo.
    .DESCRIPTION
        Nunca carrega prompt com segredo: apenas `prompt_hash` (32 hex).
        `acceptance_criteria` sao refs `criterion:<idx>`. `idempotency_key`
        e fornecida (32 hex) ou derivada de forma deterministica do conteudo.
        Retorna envelope @{ok, reason, intent}; intent=$null quando invalido.
        Nome exclusivo (R1/REV4): nao colide com `New-OrchestrationDispatchIntent`
        do contrato antigo em OrchestrationObjectiveRuntime.ps1.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [long]$TaskExpectedRevision = 0,
        [string]$Agent = '',
        [string]$PromptHash = '',
        [string[]]$Scope = @(),
        [string[]]$AcceptanceCriteria = @(),
        [string]$IdempotencyKey = '',
        [string]$Owner = '',
        [long]$OwnershipGeneration = 0,
        [string]$BaseRevision = '',
        [bool]$ExternalIdempotent = $false,
        [string]$ExternalIdempotencyProof = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        if (-not (Test-NDTaskId $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-taskid'; intent = $null }
        }
        if ([long]$TaskExpectedRevision -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-expected-revision'; intent = $null }
        }
        $agent = ([string]$Agent).Trim()
        if ($agent -cnotmatch '^[A-Za-z0-9_-]{1,64}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-agent'; intent = $null }
        }
        $ph = ([string]$PromptHash).Trim().ToLowerInvariant()
        if ($ph -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-prompt-hash'; intent = $null }
        }
        $sc = @()
        foreach ($s in @($Scope)) {
            $t = ([string]$s).Trim()
            if ([string]::IsNullOrWhiteSpace($t) -or $t.Length -gt 240) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-scope'; intent = $null }
            }
            $sc += @($t)
        }
        if (@($sc).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-scope'; intent = $null }
        }
        $ac = @()
        foreach ($c in @($AcceptanceCriteria)) {
            if (-not (Test-NDCriterionRef $c)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-acceptance-criteria'; intent = $null }
            }
            $ac += @(([string]$c).Trim())
        }
        if (@($ac).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-acceptance-criteria'; intent = $null }
        }
        $own = ([string]$Owner).Trim()
        if ([string]::IsNullOrWhiteSpace($own) -or $own.Length -gt 128) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-owner'; intent = $null }
        }
        if ([long]$OwnershipGeneration -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-generation'; intent = $null }
        }
        $base = ([string]$BaseRevision).Trim()
        if ([string]::IsNullOrWhiteSpace($base) -or $base.Length -gt 80) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-base-revision'; intent = $null }
        }
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($key)) {
            $material = ($tid + '|' + $agent + '|' + $ph + '|' + $base + '|' + $own + '|' + [string]$OwnershipGeneration + '|' + ($ac -join ',') + '|' + ($sc -join ','))
            $key = Get-NativeDispatchHash32 $material
            if ([string]::IsNullOrWhiteSpace($key)) {
                return [pscustomobject]@{ ok = $false; reason = 'idempotency-key-failed'; intent = $null }
            }
        }
        elseif ($key -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-idempotency-key'; intent = $null }
        }
        $extProof = ([string]$ExternalIdempotencyProof).Trim()
        if ([bool]$ExternalIdempotent) {
            if ([string]::IsNullOrWhiteSpace($extProof) -or ($extProof.Length -gt 240)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-idempotency-proof'; intent = $null }
            }
        }
        else { $extProof = '' }
        $intent = [pscustomobject][ordered]@{
            schema_version       = 1
            task_id              = $tid
            task_expected_revision = [long]$TaskExpectedRevision
            agent                = $agent
            prompt_hash          = $ph
            scope                = [string[]]$sc
            acceptance_criteria  = [string[]]$ac
            idempotency_key      = $key
            owner                = $own
            ownership_generation = [long]$OwnershipGeneration
            base_revision        = $base
            external_idempotent  = [bool]$ExternalIdempotent
            external_idempotency_proof = $extProof
            created_at           = ([DateTime]::UtcNow.ToString('o'))
        }
        return [pscustomobject]@{ ok = $true; reason = ''; intent = $intent }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'invalid-intent'; intent = $null }
    }
}

function Test-NativeDispatchAuthorization {
    <#
    .SYNOPSIS
        Gate de autorizacao do dispatch nativo. Fail-closed, documentado.
    .DESCRIPTION
        Admite somente quando TODAS as condicoes valem:
          (1) Authorization.explicit_allow -ceq $true (bool real);
          (2) Authorization.source nao e test-callback: TestCallback nunca
              e prova de producao (recusa explicita);
          (3) Goal vivo lido do store nao esta em estado terminal;
          (4) ownership viva (fencing token owner+generation, lease valido)
              via Test-OrchestrationGoalOwnership (CAS-style, mesma familia
              de Acquire-OrchestrationGoalOwnership).
        Registra evidencia de ativacao (JSONL limitado, best-effort; falha
        de log nunca altera o veredito). Nunca lanca: retorna envelope
        @{ok, admitted, reason}. Qualquer duvida = negado.
    #>
    [CmdletBinding()]
    param(
        $Authorization = $null,
        [string]$GoalStoreDir = '',
        [string]$ActivationLogDir = ''
    )
    try {
        if ($null -eq $Authorization) {
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'authorization-missing' }
        }
        $src = ([string](Get-NDValue $Authorization 'source' '')).Trim().ToLowerInvariant()
        if (($src -ceq 'test-callback') -or ([bool](Get-NDValue $Authorization 'test_callback_only' $false))) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'test-callback-never-authorizes-production' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'test-callback-never-authorizes-production' }
        }
        $explicit = Get-NDValue $Authorization 'explicit_allow' $false
        if (($explicit -isnot [bool]) -or (-not $explicit)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'explicit-allow-required' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'explicit-allow-required' }
        }
        $gid = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $own = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $gen = [long](Get-NDValue $Authorization 'generation' 0)
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($own) -or ($gen -lt 1)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'invalid-fencing-token' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'invalid-fencing-token' }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'ownership-check-unavailable' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'ownership-check-unavailable' }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            $why = 'goal-read-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $slot 'reason' ''))) { $why = ('goal-read-failed:' + [string](Get-NDValue $slot 'reason' '')) } } catch { }
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason $why -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why }
        }
        $goal = Get-NDValue $slot 'goal' $null
        $state = ''
        try { $state = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $state = '' }
        if (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state) {
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason 'goal-terminal' -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'goal-terminal' }
        }
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $own -Generation $gen }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            $why = 'ownership-not-held'
            try { if (($null -ne $chk) -and (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $chk 'reason' '')))) { $why = ('ownership-not-held:' + [string](Get-NDValue $chk 'reason' '')) } } catch { }
            try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $false -Reason $why -ActivationLogDir $ActivationLogDir) } catch { }
            return [pscustomobject]@{ ok = $false; admitted = $false; reason = $why }
        }
        try { [void](Write-NDActivationEvidence -Authorization $Authorization -Admitted $true -Reason '' -ActivationLogDir $ActivationLogDir) } catch { }
        return [pscustomobject]@{ ok = $true; admitted = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; admitted = $false; reason = 'authorization-internal-error' }
    }
}

function Write-NDActivationEvidence {
    param($Authorization = $null, [bool]$Admitted = $false, [string]$Reason = '', [string]$ActivationLogDir = '')
    try {
        $dir = ([string]$ActivationLogDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $root = Get-OrchestrationDispatchRepoRoot
            if ([string]::IsNullOrWhiteSpace($root)) { return $false }
            $dir = Join-Path (Join-Path $root 'cache') 'native-dispatch-receipts'
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch { return $false }
        $path = Join-Path $dir 'activations.jsonl'
        try {
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Item -LiteralPath $path).Length -gt 262144)) { return $false }
        }
        catch { }
        $row = [ordered]@{
            timestamp     = ([DateTime]::UtcNow.ToString('o'))
            goal_id       = ([string](Get-NDValue $Authorization 'goal_id' ''))
            owner         = ([string](Get-NDValue $Authorization 'owner' ''))
            admitted      = [bool]$Admitted
            reason        = ([string]$Reason)
            source        = ([string](Get-NDValue $Authorization 'source' 'planner'))
        }
        $line = ((ConvertTo-Json -InputObject $row -Compress) + "`n")
        if ([Text.Encoding]::UTF8.GetByteCount($line) -gt 2048) { return $false }
        try { [IO.File]::AppendAllText($path, $line, [Text.Encoding]::UTF8) } catch { return $false }
        return $true
    }
    catch { return $false }
}

function Test-OrchestrationDispatchResultShape {
    <#
    .SYNOPSIS
        Valida a forma do resultado do worker. Rejeita verified_pass/done.
    #>
    [CmdletBinding()]
    param($Result = $null)
    try {
        if ($null -eq $Result) {
            return [pscustomobject]@{ ok = $false; reason = 'result-missing' }
        }
        $status = ([string](Get-NDValue $Result 'status' '')).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $status) {
            return [pscustomobject]@{ ok = $false; reason = 'status-not-allowed-from-worker' }
        }
        $refs = @(Get-NDValue $Result 'claimed_evidence' @())
        if (@($refs).Count -lt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'evidence-refs-missing' }
        }
        foreach ($r in @($refs)) {
            if (-not (Test-NDCriterionRef $r)) {
                return [pscustomobject]@{ ok = $false; reason = 'evidence-ref-invalid' }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; status = $status; claimed_evidence = [string[]]@($refs) }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'result-invalid' }
    }
}

function Resolve-NDRefusalReason {
    <#
    .SYNOPSIS
        Motivo honesto de uma recusa vinda de um helper por [ref].
    .DESCRIPTION
        REV8 (F1/F2): `Open-NDReceiptLock` e `Write-NDReceipt` guardam o
        contrato de retorno (handle/$null e $true/$false) e comunicam o
        motivo especifico por `-RefusalReason` (opcional). Sem motivo, o
        chamador usa o fallback do estado (contention ou escrita). Com
        motivo, ele e propagado sem traducao - assim `lock-busy`
        continua sendo EXCLUSIVAMENTE contencao real do lock e nunca
        esconde namespace trocado durante a espera. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Refusal = '', [string]$Fallback = 'lock-busy')
    try {
        if ([string]::IsNullOrWhiteSpace($Refusal)) { return ([string]$Fallback) }
        return ([string]$Refusal)
    }
    catch { return ([string]$Fallback) }
}

function Open-NDReceiptLock {
    param([string]$Dir, [int]$LockTimeoutMs = 60000, [string]$Expected = '', [ref]$RefusalReason)
    try {
        if ([string]::IsNullOrWhiteSpace($Dir)) { return $null }
        $lockPath = Join-Path $Dir '.dispatch.lock'
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $LockTimeoutMs))
        do {
            # REV8/F1 (S1): a identidade do diretorio E o ReparsePoint do
            # caminho do lock sao revalidados DENTRO de cada tentativa,
            # imediatamente antes do File.Open. A validacao FORA do laco
            # era reutilizada por todas as tentativas: com o lock contido
            # e um Start-Sleep entre elas, um namespace trocado nesse
            # intervalo (ate o deadline de 60s) so era conferido na
            # proxima CHAMADA da funcao, e a tentativa seguinte abria/criava
            # o lock no alvo substituido. Agora a divergencia recusa na
            # hora (lock-identity-changed): sem retry e sem IO no alvo.
            $idChk = Assert-NDDirIdentity -Path $Dir -Expected $Expected
            if (-not [bool](Get-NDValue $idChk 'ok' $false)) {
                if ($null -ne $RefusalReason) { $RefusalReason.Value = 'lock-identity-changed' }
                return $null
            }
            try {
                # REV7/R1 (S1): pre-checagem de ReparsePoint do caminho
                # do lock antes do Open (Test-Path seguiria o link). Link
                # no caminho do lock e namespace trocado no nivel do
                # ARQUIVO: a tentativa recusa, nunca cria no alvo.
                if (-not (Test-NDLockPathOpenSafe -Path $lockPath)) {
                    if ($null -ne $RefusalReason) { $RefusalReason.Value = 'lock-identity-changed' }
                    return $null
                }
                return ([IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            }
            catch { Start-Sleep -Milliseconds 10 }
        } while ([DateTime]::UtcNow -lt $deadline)
        return $null
    }
    catch { return $null }
}

function Get-NDTaskLockPath {
    <#
    .SYNOPSIS
        Caminho do lock de task, na RAIZ dos recibos (nunca num namespace).
    .DESCRIPTION
        A exclusao de efeito e por `(raiz de recibos, task_id)`. Para que
        dois processos - um CLAIM no goal A e um Invoke legado no goal B,
        com chaves diferentes - dispute a MESMA exclusao, o lock nao pode
        morar no namespace de um goal: ele fica na raiz, com nome derivado
        do task_id (`.ndtask-<hash32(task_id)>.lock`). Nao e recibo, nao e
        binding e nao cria store paralelo: e apenas o lock da reserva.
        Devolve '' quando nao da para derivar o caminho. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$TaskId = '')
    try {
        if ([string]::IsNullOrWhiteSpace($RootDir)) { return '' }
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { return '' }
        $h = Get-NativeDispatchHash32 $tid
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $RootDir ('.ndtask-' + $h + '.lock'))
    }
    catch { return '' }
}

function Open-NDTaskLock {
    <#
    .SYNOPSIS
        Lock INTERPROCESSO de task, compartilhado por CLAIM e Invoke
        legado, na raiz dos recibos (F2 - exclusao de efeito por task).
    .DESCRIPTION
        Contencao real devolve $null com motivo VAZIO (`task-lock-busy`),
        exatamente como `Open-NDReceiptLock` mantem `lock-busy` como
        contencao pura. Divergencia de identidade da raiz ou reparse no
        caminho do lock recusa na hora com motivo especifico
        (`task-lock-identity-changed` / `task-lock-reparse-point`), sem
        retry e sem IO no alvo; a identidade e revalidada DENTRO de cada
        tentativa do laco, pela mesma razao do lock do recibo (REV8/F1).

        Ordem de locks (unica em todos os caminhos): lock de task ->
        lock do recibo. O chamador DEVE adquirir este lock antes de
        `Open-NDReceiptLock` e mante-lo durante toda a operacao,
        inclusive o efeito. Devolve handle ou $null. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$TaskId = '', [int]$LockTimeoutMs = 60000, [string]$RootExpected = '', [ref]$RefusalReason)
    try {
        $lockPath = Get-NDTaskLockPath -RootDir $RootDir -TaskId $TaskId
        if ([string]::IsNullOrWhiteSpace($lockPath)) {
            if ($null -ne $RefusalReason) { $RefusalReason.Value = 'task-lock-unresolvable' }
            return $null
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $LockTimeoutMs))
        do {
            $idChk = Assert-NDDirIdentity -Path $RootDir -Expected $RootExpected
            if (-not [bool](Get-NDValue $idChk 'ok' $false)) {
                $why = ([string](Get-NDValue $idChk 'reason' 'receipt-dir-identity-changed'))
                if ($why -ceq 'receipt-dir-reparse-point') { $why = 'task-lock-reparse-point' }
                else { $why = 'task-lock-identity-changed' }
                if ($null -ne $RefusalReason) { $RefusalReason.Value = $why }
                return $null
            }
            try {
                if (-not (Test-NDLockPathOpenSafe -Path $lockPath)) {
                    if ($null -ne $RefusalReason) { $RefusalReason.Value = 'task-lock-identity-changed' }
                    return $null
                }
                return ([IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
            }
            catch { Start-Sleep -Milliseconds 10 }
        } while ([DateTime]::UtcNow -lt $deadline)
        return $null
    }
    catch { return $null }
}

function Read-NDReceipt {
    <#
    .SYNOPSIS
        Le o recibo de uma idempotency key SEM colapsar estados distintos.
    .DESCRIPTION
        Retorna @{ok, reason, present, receipt}. Ausencia COMPROVADA
        (caminho inexistente) devolve ok=$false com
        reason='receipt-absent': esse e o UNICO caso em que um dispatch
        novo e legitimo. Entrada existente que nao e arquivo regular
        (diretorio, link) devolve 'receipt-not-regular' (F2/REV5):
        nao e ausencia e nao pode ser sobrescrita com seguranca.
        REV6/SEC6: link (symlink/junction) recai na MESMA razao e nao e
        lido nem seguido - o alvo do link nao e confundido com o recibo.
        Qualquer outro ok=$false significa que existe um
        recibo que nao pode ser lido nem confiado, e o chamador DEVE
        recusar com a razao explicita, sem sobrescrever o arquivo e sem
        executar nada (R3/REV4):
          receipt-absent        caminho inexistente (unico dispatch novo)
          receipt-not-regular   entrada existente nao-arquivo (F2/REV5)
          receipt-key-invalid   key fora do formato 32 hex
          receipt-unreadable    falha de IO ao ler o arquivo
          receipt-json-invalid  JSON ausente/truncado/invalido, ou raiz
                                que NAO e objeto (array/escalar: FIX3B)
          receipt-key-mismatch  idempotency_key divergente do nome do arquivo
          receipt-schema-unknown schema_version nao suportado
          receipt-phase-unknown  phase fora de settled/pending
        TOKENS CRUS (FIX3/PRA): `idempotency_key`, `schema_version` e
        `phase` sao lidos DIRETO da propriedade JSON
        (`Get-NDJson*Value`, sem pipeline) e o TIPO do token e
        conferido antes de qualquer coercao. Um array de UM elemento
        (`["<chave>"]`, `[1]`, `["settled"]`) chegaria como escalar
        pela leitura por pipeline e passaria pela comparacao; aqui
        recusa em 'receipt-key-mismatch' / 'receipt-schema-unknown' /
        'receipt-phase-unknown'. Inteiro legitimo (Int32 no PS 5.1,
        Int64 no PS 7) e string seguem aceitos.
        Quando ok=$true, o recibo devolvido tem a fase CANONICALIZADA
        (F1/REV5): 'PENDING', ' pending ', 'SETTLED' etc. chegam ao
        consumidor como 'pending'/'settled'. Os demais campos sao
        preservados campo a campo. Nunca lanca e nunca devolve recibo
        parcial.

        REV7/R1 (S1): `-Expected` (CreationTimeUtc capturado na
        resolucao) faz a leitura reassertar a identidade do diretorio
        IMEDIATAMENTE antes do IO. Divisao/ilegiveis recusam com
        `receipt-dir-identity-changed`; junction/symlink no caminho do
        diretorio recusa com `receipt-dir-reparse-point` - zero IO no
        alvo.

        PR-A (`-AllowHandoffPhases`, opt-in): por padrao o leitor aceita
        SOMENTE as fases do caminho legado (`settled`, `pending`), e uma
        fase fora desse conjunto recusa com `receipt-phase-unknown`. Com
        o switch, as fases do handoff nativo (`prepared`, `claimed`)
        tambem sao aceitas e devolvidas canonicalizadas. O switch e
        EXCLUSIVO das operacoes novas (PREPARE/CLAIM): o caminho legado
        e a reconciliacao Nunca o usam, portanto um recibo de handoff
        nunca e lido, reutilizado nem sobrescrito por eles - a recusa
        `receipt-phase-unknown` com 0 chamadas de Executor e a garantia
        de que prepared/claimed nao provocam segundo efeito no legado.
    #>
    [CmdletBinding()]
    param([string]$Dir, [string]$Key, [string]$Expected = '', [switch]$AllowHandoffPhases)
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($Dir)) -or ($k -cnotmatch '^[a-f0-9]{32}$')) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-key-invalid'; present = $false; receipt = $null }
        }
        # REV7/R1 (S1): reassert imediato antes de qualquer IO de leitura.
        $idChk = Assert-NDDirIdentity -Path $Dir -Expected $Expected
        if (-not [bool](Get-NDValue $idChk 'ok' $false)) {
            return [pscustomobject]@{ ok = $false; reason = ([string](Get-NDValue $idChk 'reason' 'receipt-dir-identity-changed')); present = $false; receipt = $null }
        }
        $path = Join-Path $Dir ($k + '.json')
        if (-not (Test-Path -LiteralPath $path)) {
            # Ausencia COMPROVADA (nada no caminho, F2/REV5): unico
            # estado que autoriza um dispatch novo.
            return [pscustomobject]@{ ok = $false; reason = 'receipt-absent'; present = $false; receipt = $null }
        }
        # REV6/SEC6: link NAO e o recibo. `Test-Path -PathType Leaf`
        # aceita symlink/junction para arquivo regular, e a leitura
        # seguiria o ALVO (outra goal, outro caminho). Atributos
        # ilegiveis tambem recusam: fail-closed, nunca ausencia.
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-not-regular'; present = $true; receipt = $null }
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            # Entrada existente que NAO e arquivo regular (diretorio,
            # pipe). Nao pode ser lida nem sobrescrita com seguranca
            # e NUNCA deve ser confundida com ausencia: recusar com razao
            # explicita, sem tocar na entrada e sem efeito.
            return [pscustomobject]@{ ok = $false; reason = 'receipt-not-regular'; present = $true; receipt = $null }
        }
        $text = ''
        try { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
        catch { return [pscustomobject]@{ ok = $false; reason = 'receipt-unreadable'; present = $true; receipt = $null } }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-json-invalid'; present = $true; receipt = $null }
        }
        # FIX3B: raiz OBJETO obrigatoria antes de parsear. `ConvertFrom-Json`
        # pela pipeline desenrolaria `[{...}]` num objeto escalar e aceitaria
        # um recibo cuja raiz real e array (ou escalar). Primeiro token
        # nao-espaco do texto tem de ser '{'.
        if (-not (Test-NDJsonObjectRootText -Text $text)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-json-invalid'; present = $true; receipt = $null }
        }
        $raw = $null
        try { $raw = ConvertFrom-Json $text }
        catch { return [pscustomobject]@{ ok = $false; reason = 'receipt-json-invalid'; present = $true; receipt = $null } }
        if ($null -eq $raw) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-json-invalid'; present = $true; receipt = $null }
        }
        $rawKey = Get-NDJsonStringValue -Object $raw -Name 'idempotency_key'
        if (($null -eq $rawKey) -or (([string]$rawKey) -cne $k)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-key-mismatch'; present = $true; receipt = $null }
        }
        # TOKENS CRUS, sem coercao e sem pipeline: a leitura por
        # `Get-NDValue` desenrolaria `["<chave>"]`, `[1]` ou
        # `["settled"]` em escalar, e a comparacao seguinte aceitaria o
        # valor como se o token original fosse o campo esperado. Aqui o
        # TIPO do token e conferido ANTES (Get-NDJson*Value le a
        # propriedade direto, sem passar pelo pipeline de saida).
        $sv = Get-NDJsonIntegralLong -Object $raw -Name 'schema_version'
        if (($null -eq $sv) -or ($sv -ne 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-schema-unknown'; present = $true; receipt = $null }
        }
        $phaseTok = Get-NDJsonStringValue -Object $raw -Name 'phase'
        if ($null -eq $phaseTok) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-phase-unknown'; present = $true; receipt = $null }
        }
        $phase = (([string]$phaseTok).Trim().ToLowerInvariant())
        # PR-A: `prepared`/`claimed` so entram aqui quando o chamador e uma
        # operacao de handoff (`-AllowHandoffPhases`). Sem o switch, a fase
        # nova recusa como desconhecida - e esse e o comportamento que
        # mantem o caminho legado fora dos recibos de handoff.
        $allowedPhases = @('settled', 'pending')
        if ($AllowHandoffPhases) { $allowedPhases = @('settled', 'pending', 'prepared', 'claimed') }
        if (@($allowedPhases) -cnotcontains $phase) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-phase-unknown'; present = $true; receipt = $null }
        }
        # F1/REV5: o envelope de leitura devolve o recibo com a fase
        # CANONICALIZADA (minuscura, sem espacos). Consumidores so veem a
        # forma canonica, entao a comparacao -ceq 'pending'/'settled'
        # nunca perde um recibo escrito com variacao de caixa/padding e
        # escorrega para um dispatch novo (efeito duplicado). O resto do
        # recibo e preservado campo a campo.
        $canonical = [ordered]@{}
        foreach ($pp in @($raw.PSObject.Properties)) { $canonical[$pp.Name] = $pp.Value }
        $canonical['phase'] = $phase
        return [pscustomobject]@{ ok = $true; reason = ''; present = $true; receipt = ([pscustomobject]$canonical) }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'receipt-unreadable'; present = $false; receipt = $null }
    }
}

function Write-NDReceipt {
    param([string]$Dir, $Receipt, [string]$Expected = '', [ref]$RefusalReason)
    try {
        $key = ([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') { return $false }
        # REV7/R1 (S1): reassert ANTES de criar temporario. Namespace
        # alterado desde a resolucao recusa sem IO no alvo.
        $idPre = Assert-NDDirIdentity -Path $Dir -Expected $Expected
        if (-not [bool](Get-NDValue $idPre 'ok' $false)) {
            if ($null -ne $RefusalReason) { $RefusalReason.Value = ([string](Get-NDValue $idPre 'reason' 'receipt-dir-identity-changed')) }
            return $false
        }
        $path = Join-Path $Dir ($key + '.json')
        # F2/REV5: o destino EXATO tem de ser um arquivo regular. Se ja
        # existir algo que nao seja arquivo (diretorio, link), recusar
        # ANTES de criar temporario: Move-Item -Force sobre um diretorio
        # moveria o temporario para DENTRO dele e devolveria sucesso,
        # deixando o chamador acreditar que persistiu.
        # REV6/SEC6: idem para symlink/junction - sem a checagem de
        # reparse point o alvo do link (fora deste diretorio) seria
        # sobrescrito pelo Move, e o efeito vazaria do destino.
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        $json = ConvertTo-Json -InputObject $Receipt -Depth 20 -Compress
        $tmp = Join-Path $Dir (('receipt-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) }
        catch { return $false }
        # REV7/R1 (S1): reassert ANTES do Move - o Move e o IO que
        # escreveria no lugar errado se o diretorio foi trocado entre a
        # criacao do temporario e aqui.
        # REV8/F2 (S1): identidade divergente NAO faz cleanup pelo caminho.
        # O Remove-Item seguiria o caminho substituido (diretorio recriado
        # ou junction para outro goal) e apagaria la - IO destrutivo no
        # alvo errado. O temporario fica preservado e a falha e reportada
        # como receipt-cleanup-deferred; a remocao passa a ser operacao
        # do operador, com o caminho VALIDADO de novo.
        $idMove = Assert-NDDirIdentity -Path $Dir -Expected $Expected
        if (-not [bool](Get-NDValue $idMove 'ok' $false)) {
            if ($null -ne $RefusalReason) { $RefusalReason.Value = 'receipt-cleanup-deferred' }
            return $false
        }
        try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
        catch {
            # REV8/F2 (S1): o Move pode ter falhado justamente porque o
            # namespace foi trocado entre a revalidacao e aqui. Revalidar
            # a identidade ANTES de qualquer cleanup: divergente preserva
            # o temporario e reporta receipt-cleanup-deferred; somente com
            # identidade valida o temporario e removido (best-effort, e
            # sempre pelo caminho revalidado).
            $idCatch = Assert-NDDirIdentity -Path $Dir -Expected $Expected
            if (-not [bool](Get-NDValue $idCatch 'ok' $false)) {
                if ($null -ne $RefusalReason) { $RefusalReason.Value = 'receipt-cleanup-deferred' }
                return $false
            }
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } catch { }
            return $false
        }
        # F2/REV5: prova pos-escrita. O destino precisa ser exatamente o
        # arquivo esperado e conter a key deste recibo; qualquer outro
        # resultado (por exemplo o move tendo caido dentro de um
        # diretorio criado entre a checagem e o move) nao e persistencia.
        # REV6/SEC6: a prova inclui "atributos SEM ReparsePoint", para
        # mostrar que o destino continua sendo o arquivo regular deste
        # diretorio e nao um link cujo alvo foi escrito no lugar.
        # REV7/R1 (S1) + SEC7: a prova descreve o estado FINAL observado
        # e NAO prova ausencia de vazamento durante a janela residual
        # TOCTOU entre a ultima revalidacao e o IO (PS 5.1 nao tem
        # abertura kernel sem-seguir-link). O reassert pos-Move mantem o
        # claim limitado ao que foi efetivamente observado.
        $idPost = Assert-NDDirIdentity -Path $Dir -Expected $Expected
        if (-not [bool](Get-NDValue $idPost 'ok' $false)) {
            # O Move ja ocorreu (nao ha temporario a preservar): a falha
            # e a identidade divergente no estado final, reportada como tal.
            if ($null -ne $RefusalReason) { $RefusalReason.Value = ([string](Get-NDValue $idPost 'reason' 'receipt-dir-identity-changed')) }
            return $false
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
        try {
            $back = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($back) -or ($back.IndexOf($key, [StringComparison]::Ordinal) -lt 0)) { return $false }
        }
        catch { return $false }
        return $true
    }
    catch { return $false }
}

function Get-NDScalarToken {
    <#
    .SYNOPSIS
        Token canonico de UM valor escalar de recibo (sem coercao).
    .DESCRIPTION
        PRA-SETTLE-FIX3: comparar `[string]$a -ceq [string]$b` equipararia
        1 a '1' e 'True' a 'true'. Aqui o tipo decide o prefixo: booleano
        vira 'bool:true'/'bool:false', string vira 'str:<texto>' e os
        PRA-SETTLE-FIX4: o token de INTEIRO e separado do token de
        FRACIONARIO. `1` (Int32 no PS 5.1, Int64 no PS 7) vira 'int:1' e
        `1.0`/`1.5` (Double/Decimal/Single) vira 'num:1'/'num:1.5': um
        inteiro esperado NUNCA casa com um fracionario persistido, e
        Int32/Int64 do mesmo numero continuam iguais. Booleano, array,
        string e null NUNCA entram nessa normalizacao numerica.

        TIMESTAMP (PS 5.1 vs PS 7): o mesmo texto ISO-8601 de um recibo
        volta como STRING no 5.1 e como [DateTime] no 7 (`ConvertFrom-Json`
        do PS 7 parseia data). `str:<texto>` vs `num:<data>` acusaria
        divergencia inexistente no MESMO estado persistido. Entao o token
        de um instante e canonico nos dois mundos: 'ts:' + ticks UTC. Somente
        texto ISO-8601 completo (\d{4}-\d{2}-\d{2}T...) entra nessa
        normalizacao - qualquer outra string continua comparando como texto
        puro, sem interpretacao de formato. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Value = $null)
    try {
        if ($null -eq $Value) { return 't:null' }
        if ($Value -is [bool]) { if ($Value) { return 'bool:true' } else { return 'bool:false' } }
        if ($Value -is [string]) {
            $s = [string]$Value
            if ($s -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T') {
                $ticks = Get-NDTimestampTicks -Text $s
                if ($ticks -gt 0) { return ('ts:' + [string]$ticks) }
            }
            return ('str:' + $s)
        }
        if ($Value -is [DateTime]) {
            try {
                $ticks = $Value.ToUniversalTime().Ticks
                return ('ts:' + [string]$ticks)
            }
            catch { }
        }
        # INTEIRO (Int32/Int64/...): prefixo proprio. Normaliza a
        # diferenca de tipo entre PS 5.1 (Int32) e PS 7 (Int64) sem confundir
        # inteiro com fracionario.
        if (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [uint16]) -or ($Value -is [byte]) -or ($Value -is [sbyte]) -or ($Value -is [int32]) -or ($Value -is [uint32]) -or ($Value -is [int64]) -or ($Value -is [uint64])) {
            $itok = $null
            try { $itok = [System.Convert]::ToString([long]$Value, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $itok = $null }
            if ($null -ne $itok) { return ('int:' + $itok) }
        }
        $s = $null
        try { $s = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { $s = $null }
        if ($null -eq $s) { return 't:null' }
        return ('num:' + $s)
    }
    catch { return 't:err' }
}

function Get-NDTimestampTicks {
    <#
    .SYNOPSIS
        Ticks UTC de um texto ISO-8601; 0 quando nao for instante valido.
    .DESCRIPTION
        PRA-SETTLE-FIX3: `DateTimeOffset.Parse` com estilos
        AssumeUniversal|AdjustToUniversal converte formato local, com 'Z'
        ou com offset explicito para o MESMO instante UTC. Retorna 0 para
        texto que nao seja timestamp (o chamador trata como string pura).
        Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Text = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return [long]0 }
        # Variavel PRE-INICIALIZADA: passar [ref] de $null nao liga o overload
        # TryParse em nenhuma das duas edicoes.
        $d = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$Text, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$d)) { return [long]0 }
        return [long]$d.ToUniversalTime().Ticks
    }
    catch { return [long]0 }
}

function New-NDValueNode {
    <#
    .SYNOPSIS
        Classifica UM valor cru de recibo num NO tipado, sem emitir nada
        pelo pipeline. Somente leitura. Nunca lanca.
    .DESCRIPTION
        PRA-SETTLE-FIX4: comparar valores lidos por `Get-NDValue` e
        inseguro porque o PowerShell DESENROLA array de um elemento no
        pipeline de saida da funcao: `kernel_ok:[true]` chegaria ao
        chamador como `true`, e `settle_child_session_id:["filho"]` como
        'filho'. O NO carrega o valor CRU dentro de uma propriedade
        (acesso a propriedade nao desenrola) e o TIPO do token:

          absent   -> propriedade inexistente (distingue de null);
          null     -> token JSON null;
          bool     -> booleano exato;
          integer  -> inteiro JSON (Int32/Int64/...), normalizado [long];
          float    -> fracionario JSON (Double/Decimal/Single);
          string   -> token JSON string;
          datetime -> [DateTime] (PS 7 parseia data ISO-8601);
          object   -> dicionario (hashtable/ordered) ou PSCustomObject;
          list     -> array/colecao (nunca string);
          other    -> qualquer outro tipo (nunca equiparado a escalar).

        Kind DIFERENTE nunca casa: array vs escalar, inteiro vs
        fracionario, booleano vs inteiro, null vs ausente. O `count` de
        'list'/'object' e a contagem de elementos/chaves.
    #>
    [CmdletBinding()]
    param($Value = $null, [bool]$Present = $true)
    $absentNode = [pscustomobject]@{ kind = 'absent'; value = $null; count = 0 }
    try {
        if (-not $Present) { return $absentNode }
        if ($null -eq $Value) { return [pscustomobject]@{ kind = 'null'; value = $null; count = 0 } }
        if ($Value -is [bool]) { return [pscustomobject]@{ kind = 'bool'; value = [bool]$Value; count = 0 } }
        if ($Value -is [string]) { return [pscustomobject]@{ kind = 'string'; value = [string]$Value; count = 0 } }
        if (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [uint16]) -or ($Value -is [byte]) -or ($Value -is [sbyte]) -or ($Value -is [int32]) -or ($Value -is [uint32]) -or ($Value -is [int64]) -or ($Value -is [uint64])) {
            return [pscustomobject]@{ kind = 'integer'; value = [long]$Value; count = 0 }
        }
        if (($Value -is [double]) -or ($Value -is [decimal]) -or ($Value -is [single])) {
            return [pscustomobject]@{ kind = 'float'; value = $Value; count = 0 }
        }
        if ($Value -is [DateTime]) { return [pscustomobject]@{ kind = 'datetime'; value = [DateTime]$Value; count = 0 } }
        if ($Value -is [System.Collections.IDictionary]) {
            return [pscustomobject]@{ kind = 'object'; value = $Value; count = @($Value.Keys).Count }
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ kind = 'object'; value = $Value; count = @($Value.PSObject.Properties).Count }
        }
        if ($Value -is [System.Collections.IEnumerable]) {
            $c = 0
            foreach ($el in $Value) { $c++ }
            return [pscustomobject]@{ kind = 'list'; value = $Value; count = [int]$c }
        }
        return [pscustomobject]@{ kind = 'other'; value = $Value; count = 0 }
    }
    catch { return [pscustomobject]@{ kind = 'other'; value = $null; count = 0 } }
}

function Get-NDValueNode {
    <#
    .SYNOPSIS
        Le UMA propriedade de UM objeto DIRETO (indice de dicionario ou
        PSObject.Properties), SEM passar o valor pelo pipeline. Somente
        leitura. Nunca lanca.
    .DESCRIPTION
        `Get-NDValue` devolve `$p.Value` pelo pipeline de saida, e o
        PowerShell desenrola array de um elemento nesse caminho - por isso
        ele NAO serve para comparar forma de token. Aqui a propriedade e
        lida na mao e o valor cru vai para `New-NDValueNode`, que o guarda
        dentro de outro objeto. Ausencia devolve kind 'absent', distinto
        de 'null'. Nunca enumera colecoes.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) {
            return (New-NDValueNode -Value $null -Present $false)
        }
        $val = $null
        $found = $false
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $val = $Object[$Name]; $found = $true }
        }
        else {
            $prop = $Object.PSObject.Properties[$Name]
            if ($null -ne $prop) { $val = $prop.Value; $found = $true }
        }
        if (-not $found) { return (New-NDValueNode -Value $null -Present $false) }
        return (New-NDValueNode -Value $val -Present $true)
    }
    catch { return (New-NDValueNode -Value $null -Present $false) }
}

function Test-NDValueStringList {
    <#
    .SYNOPSIS
        $true SOMENTE quando a propriedade nomeada e um ARRAY (nunca
        escalar, nunca objeto) cujos elementos sao TODOS strings. Array
        VAZIO e valido. Somente leitura. Nunca lanca.
    .DESCRIPTION
        `Get-NDJsonStringArrayValue` devolve [string[]] pelo pipeline, e
        `return` de array vazio nao emite objeto algum: o chamador recebe
        $null e nao distingue "array vazio legitimo" de "token
        divergente". Para campos de liquidacao que PODEM nascer vazios
        (refs do candidato) essa ambiguidade serviria como recusa
        indevida. Aqui a classificacao vem do NO (`Get-NDValueNode`):
        kind 'list' garante array/colecao e cada elemento e conferido
        sem coercao. Nunca enumera pelo pipeline de saida.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        $node = Get-NDValueNode -Object $Object -Name $Name
        if ([string]$node.kind -cne 'list') { return $false }
        foreach ($el in @($node.value)) {
            if ($el -isnot [string]) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-NDReceiptValueMatch {
    <#
    .SYNOPSIS
        Comparacao ESTRUTURAL PROFUNDA de DOIS NOS de recibo. Fail-closed.
    .DESCRIPTION
        PRA-SETTLE-FIX3/FIX4: a prova de que o recibo 'settled' EXATO esta
        persistido nao pode depender de igualdade rasa nem de leitura por
        pipeline. `-Expected` e `-Actual` sao NOS produzidos por
        `Get-NDValueNode`/`New-NDValueNode`, que trazem o TIPO do token
        original:

          - objeto (dicionario ou PSCustomObject): CONJUNTO DE CHAVES
            igual (contagem e nomes, sem campo extra dos dois lados) e
            comparacao recursiva de cada valor;
          - lista: MESMA contagem e elemento a elemento EM ORDEM;
          - escalar: TOKEN canonico (`Get-NDScalarToken`), onde string
            ISO-8601 e [DateTime] do mesmo instante canonizam juntos
            (PS 5.1 devolve string, PS 7 devolve DateTime) e inteiro
            (Int32/Int64) nunca casa com fracionario;
          - kind DIFERENTE nunca casa: array vs escalar, null vs
            ausente, booleano vs inteiro, string vs numero.

        Qualquer duvida devolve $false - nunca $true por excesso de
        confianca. Somente leitura. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Expected = $null, $Actual = $null)
    try {
        if (($null -eq $Expected) -or ($null -eq $Actual)) { return $false }
        $ek = [string]$Expected.kind
        $ak = [string]$Actual.kind
        if ($ek -cne $ak) {
            # string ISO-8601 e DateTime do MESMO instante sao o mesmo
            # valor persistido nas duas edicoes do PowerShell.
            $eTime = (($ek -ceq 'string') -or ($ek -ceq 'datetime'))
            $aTime = (($ak -ceq 'string') -or ($ak -ceq 'datetime'))
            if ((-not $eTime) -or (-not $aTime)) { return $false }
            return ((Get-NDScalarToken -Value $Expected.value) -ceq (Get-NDScalarToken -Value $Actual.value))
        }
        if ($ek -ceq 'other') {
            return ((Get-NDScalarToken -Value $Expected.value) -ceq (Get-NDScalarToken -Value $Actual.value))
        }
        if (($ek -ceq 'absent') -or ($ek -ceq 'null')) { return $true }
        if (($ek -ceq 'bool') -or ($ek -ceq 'integer') -or ($ek -ceq 'float') -or ($ek -ceq 'string') -or ($ek -ceq 'datetime')) {
            return ((Get-NDScalarToken -Value $Expected.value) -ceq (Get-NDScalarToken -Value $Actual.value))
        }
        if ($ek -ceq 'list') {
            if ([int]$Expected.count -ne [int]$Actual.count) { return $false }
            $eArr = @($Expected.value)
            $aArr = @($Actual.value)
            if (@($eArr).Count -ne @($aArr).Count) { return $false }
            for ($i = 0; $i -lt @($eArr).Count; $i++) {
                $en = New-NDValueNode -Value $eArr[$i] -Present $true
                $an = New-NDValueNode -Value $aArr[$i] -Present $true
                if (-not (Test-NDReceiptValueMatch -Expected $en -Actual $an)) { return $false }
            }
            return $true
        }
        if ($ek -ceq 'object') {
            if ([int]$Expected.count -ne [int]$Actual.count) { return $false }
            $eNames = @()
            if ($Expected.value -is [System.Collections.IDictionary]) { $eNames = @($Expected.value.Keys) }
            else { foreach ($pp in @($Expected.value.PSObject.Properties)) { $eNames += [string]$pp.Name } }
            foreach ($kk in @($eNames)) {
                $kn = ([string]$kk)
                if ([string]::IsNullOrWhiteSpace($kn)) { return $false }
                $en = Get-NDValueNode -Object $Expected.value -Name $kn
                $an = Get-NDValueNode -Object $Actual.value -Name $kn
                if (-not (Test-NDReceiptValueMatch -Expected $en -Actual $an)) { return $false }
            }
            return $true
        }
        return $false
    }
    catch { return $false }
}

function Test-NDSettledReceiptFieldShape {
    <#
    .SYNOPSIS
        Forma CRUA (tipo de token) do recibo 'settled' PROPRIO do fluxo de
        handoff. Fail-closed. Somente leitura.
    .DESCRIPTION
        PRA-SETTLE-FIX4: `Test-NDReceiptSemanticIntegrity` cobre os campos
        do PREPARE (identidade, inteiros, booleanos e arrays do Intent).
        Os campos que o SETTLE acrescenta na liquidacao NAO tinham porta
        de forma propria - e um `kernel_ok:[true]`, um
        `settle_child_session_id:["filho"]` ou um
        `worker_result:"..."` adulterados chegariam como escalar pela
        leitura com coercao. Esta funcao exige, em TOKENS CRUS (lidos
        direto da propriedade JSON, sem pipeline e sem coercao):

          - `kernel_ok`, `evidence_created` e `reconciled` BOOLEANOS
            exatos;
          - `executor_calls`, QUANDO presente (o SETTLE do handoff nao o
            grava; ele so existe em recibos liquidados pelo caminho
            legado), INTEIRO escalar exato;
          - strings de identidade/fase/status/evidencia:
            `phase`, `handoff_state`, `idempotency_key`, `goal_id`,
            `task_id`, `agent`, `owner`, `evidence_id`,
            `settle_status`, `settle_child_session_id`,
            `settle_session_id`, `settle_message_id`, `settle_call_id`,
            `settle_caller_agent`, `settle_target_agent`, `settled_by`;
          - `worker_result` OBJETO com `status` string e
            `claimed_evidence` ARRAY JSON de strings;
          - `settle_claimed_evidence` ARRAY JSON de strings.

        Campo ausente ou tipo divergente devolve $false. NAO e aplicada a
        recibos legados: ela e exclusiva da liquidacao do handoff. Nunca
        lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        # booleanos exatos do veredicto da liquidacao.
        foreach ($bf in @('kernel_ok', 'evidence_created', 'reconciled')) {
            if ($null -eq (Get-NDJsonBoolValue -Object $Receipt -Name $bf)) { return $false }
        }
        # contagem de execucoes: inteira quando existir (legado).
        $callsTok = Get-NDJsonProperty -Object $Receipt -Name 'executor_calls'
        if (($null -ne $callsTok) -and ([bool]$callsTok.present)) {
            if ([string]$callsTok.kind -cne 'integer') { return $false }
        }
        # strings de identidade/fase/status/evidencia/linhagem.
        foreach ($sf in @('phase', 'handoff_state', 'idempotency_key', 'goal_id', 'task_id', 'agent', 'owner', 'evidence_id', 'settle_status', 'settle_child_session_id', 'settle_session_id', 'settle_message_id', 'settle_call_id', 'settle_caller_agent', 'settle_target_agent', 'settled_by')) {
            if ($null -eq (Get-NDJsonStringValue -Object $Receipt -Name $sf)) { return $false }
        }
        # candidato: OBJETO (nunca array nem escalar) com status string e
        # refs em array de strings. O NO classifica dicionario/PSCustomObject
        # como 'object' e array como 'list' - `Get-NDJsonProperty` nao
        # distingue objeto de Double/array (todos 'other').
        $wrNode = Get-NDValueNode -Object $Receipt -Name 'worker_result'
        if ([string]$wrNode.kind -cne 'object') { return $false }
        $wrVal = $wrNode.value
        if ($null -eq $wrVal) { return $false }
        if ($null -eq (Get-NDJsonStringValue -Object $wrVal -Name 'status')) { return $false }
        if (-not (Test-NDValueStringList -Object $wrVal -Name 'claimed_evidence')) { return $false }
        # refs do candidato tambem no nivel do recibo.
        if (-not (Test-NDValueStringList -Object $Receipt -Name 'settle_claimed_evidence')) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-NDSettledReceiptPersisted {
    <#
    .SYNOPSIS
        Prova pos-falha: o recibo 'settled' EXATO esta persistido? Somente
        leitura, sob os locks que o chamador JA segura (PRA-SETTLE-FIX3).
    .DESCRIPTION
        `Write-NDReceipt` devolve $false tambem quando o Move JA OCORREU e
        a prova pos-escrita falhou (identidade divergente no estado final,
        alvo que deixou de ser arquivo regular, leitura de retorno
        ilegivel). $false portanto NAO distingue "nada foi gravado" de
        "gravou e nao conseguiu provar": sem reler, o SETTLE teria de
        escolher entre mentir que o recibo continua 'claimed' e mentir que
        a liquidacao foi persistida. O unico jeito honesto e RELER o
        arquivo - ainda SOB OS DOIS LOCKS da operacao, sem adquirir lock
        proprio - e comparar com o recibo EXATO que se tentou escrever:

          (a) leitura autoritativa valida (`Read-NDReceipt`, com a
              identidade do namespace reassertada) e fase CANONICA
              'settled';
          (b) integridade SEMANTICA RECALCULADA do registro
              (`Test-NDReceiptSemanticIntegrity`) - hash intacto com campo
              adulterado nao passa;
          (b1) FORMA CRUA dos campos que so a liquidacao do handoff grava
              (`Test-NDSettledReceiptFieldShape`): booleanos exatos,
              inteiro exato, strings, objeto do candidato e arrays de
              refs, tambem em TOKENS CRUS (sem pipeline, sem coercao);
          (c) igualdade campo a campo, ESTRUTURAL e PROFUNDA
              (`Test-NDReceiptValueMatch`), com o recibo 'settled'
              esperado: referencia, goal/owner/generation, task, agente,
              fingerprints, linhagem do host (sessao/mensagem/call/caller/
              target), sessao filha, candidato (status + evidence refs),
              evidence_id/kernel_ok/kernel_reason e reconciled;
          (d) nenhum campo EXTRA no registro persistido: o que esta em
              disco tem de ser EXATAMENTE o que se tentou escrever.

        Qualquer divergencia devolve ok=$false com motivo explicito
        ('settle-receipt-proof-*'). O chamador NAO pode tratar isso como
        "recibo ainda claimed" nem como liquidacao persistida: o estado e
        incerto e a resposta tem de ser ambigua. Nunca lanca e nunca
        devolve ok=$true por excesso de confianca.

        PRA-SETTLE-FIX4: esta prova roda DEPOIS da escrita do 'settled'
        independentemente do retorno do escritor - `$true` de
        `Write-NDReceipt` NAO e prova de que o disco contem o registro
        EXATO (o destino pode ter sido substituido depois do Move), e
        `$false` NAO prova que nada foi gravado. Em ambos os casos a
        autoridade e a RELEITURA sob os dois locks. Todas as leituras de
        campo desta funcao usam acesso direto a propriedade
        (`Get-NDJson*Value` / `Get-NDValueNode` / `Try-NDRawProperty`):
        `Get-NDValue` desenrolaria lista de um elemento e a comparacao
        aceitaria `kernel_ok:[true]` como `kernel_ok:true`.
    #>
    [CmdletBinding()]
    param($Dir = '', [string]$Key = '', [string]$Expected = '', $SettledReceipt = $null, [string]$GoalId = '')
    try {
        $deny = {
            param([string]$Why)
            return [pscustomobject]@{ ok = $false; reason = ([string]$Why); phase = ''; receipt = $null }
        }
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($Dir)) -or ($k -cnotmatch '^[a-f0-9]{32}$')) {
            return (& $deny 'settle-receipt-proof-key-invalid')
        }
        if ($null -eq $SettledReceipt) { return (& $deny 'settle-receipt-proof-missing') }
        # (a) releitura SOB OS LOCKS DO CHAMADOR, com identidade reassertada.
        #     O envelope da leitura e objeto PROPRIO desta biblioteca, mas a
        #     prova nao depende de coercao: 'ok' e lido como BOOLEANO cru e
        #     'reason' como STRING cru (`Get-NDJson*Value` le a propriedade
        #     direto, sem pipeline).
        $reread = Read-NDReceipt -Dir $Dir -Key $k -Expected $Expected -AllowHandoffPhases
        $rereadOk = Get-NDJsonBoolValue -Object $reread -Name 'ok'
        if (($null -eq $rereadOk) -or (-not $rereadOk)) {
            $rereadWhy = Get-NDJsonStringValue -Object $reread -Name 'reason'
            if ($null -eq $rereadWhy) { $rereadWhy = 'receipt-unreadable' }
            return (& $deny ('settle-receipt-proof-unreadable:' + [string]$rereadWhy))
        }
        # O registro persistido e OBJETO: lido por atribuicao ([ref]), nunca
        # pelo pipeline - `Get-NDValue` desenrolaria lista de um elemento e
        # a prova passaria a comparar um escalar com um objeto.
        $persisted = $null
        if (-not (Try-NDRawProperty -Object $reread -Name 'receipt' -Value ([ref]$persisted))) {
            return (& $deny 'settle-receipt-proof-unreadable:receipt-absent')
        }
        if ($null -eq $persisted) { return (& $deny 'settle-receipt-proof-unreadable:receipt-absent') }
        # Fase: TOKEN CRU. `Get-NDValue` + [string] desenrolaria
        # `phase:["settled"]` em 'settled' e a prova seguiria comparando um
        # registro que nao tem a fase esperada.
        $phaseTok = Get-NDJsonStringValue -Object $persisted -Name 'phase'
        if ($null -eq $phaseTok) { return (& $deny 'settle-receipt-proof-phase:absent') }
        $phase = ([string]$phaseTok).Trim().ToLowerInvariant()
        if ($phase -cne 'settled') { return (& $deny ('settle-receipt-proof-phase:' + $phase)) }
        # (b1) FORMA CRUA dos campos que so a liquidacao do handoff grava
        #      (`kernel_ok`, `evidence_created`, `reconciled`,
        #      `executor_calls`, `worker_result`, ids de sessao/mensagem/
        #      call e arrays do candidato). Um token em forma de array
        #      (`kernel_ok:[true]`, `settle_child_session_id:["filho"]`)
        #      chegaria como escalar pela leitura por pipeline; aqui o tipo
        #      cru e conferido antes de qualquer comparacao.
        if (-not (Test-NDSettledReceiptFieldShape -Receipt $persisted)) {
            return (& $deny 'settle-receipt-proof-shape')
        }
        # (b) integridade semantica recalculada do registro persistido.
        $integ = Test-NDReceiptSemanticIntegrity -Receipt $persisted -GoalId ([string]$GoalId) -IdempotencyKey $k
        $integOk = Get-NDJsonBoolValue -Object $integ -Name 'ok'
        if (($null -eq $integOk) -or (-not $integOk)) { return (& $deny 'settle-receipt-proof-integrity') }
        # o registro que se tentou escrever TEM de ser um 'settled'.
        $wantPhaseTok = Get-NDJsonStringValue -Object $SettledReceipt -Name 'phase'
        if ($null -eq $wantPhaseTok) { return (& $deny 'settle-receipt-proof-expected-phase') }
        if (([string]$wantPhaseTok).Trim().ToLowerInvariant() -cne 'settled') { return (& $deny 'settle-receipt-proof-expected-phase') }
        # (c) campo a campo, estrutural e profundo. A lista de nomes vem das
        #      CHAVES quando o registro esperado e dicionario (ordered) -
        #      `PSObject.Properties` em OrderedDictionary devolve os
        #      adaptadores (Count/Keys/Values...), nunca as chaves. Os dois
        #      lados sao lidos por `Get-NDValueNode` (propriedade direta,
        #      SEM pipeline): o NO carrega o valor cru e o seu TIPO, entao
        #      escalar vs array de um elemento nao casa.
        $wantNames = @()
        if ($SettledReceipt -is [System.Collections.IDictionary]) { $wantNames = @($SettledReceipt.Keys) }
        else { $wantNames = @($SettledReceipt.PSObject.Properties | ForEach-Object { [string]$_.Name }) }
        foreach ($name in @($wantNames)) {
            $fn = ([string]$name)
            $wv = Get-NDValueNode -Object $SettledReceipt -Name $fn
            $av = Get-NDValueNode -Object $persisted -Name $fn
            if (-not (Test-NDReceiptValueMatch -Expected $wv -Actual $av)) {
                return (& $deny ('settle-receipt-proof-mismatch:' + $fn))
            }
        }
        # (d) nenhum campo extra: disk == tentativa de escrita, nem mais.
        $haveNames = @()
        if ($persisted -is [System.Collections.IDictionary]) { $haveNames = @($persisted.Keys) }
        else { $haveNames = @($persisted.PSObject.Properties | ForEach-Object { [string]$_.Name }) }
        foreach ($name in @($haveNames)) {
            $pn = [string]$name
            if (@($wantNames) -cnotcontains $pn) { return (& $deny ('settle-receipt-proof-extra:' + $pn)) }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; phase = 'settled'; receipt = $persisted }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'settle-receipt-proof-error'; phase = ''; receipt = $null } }
}

function Test-NDHandoffSettledMarker {
    <#
    .SYNOPSIS
        $true SOMENTE quando o registro 'settled' e do HANDOFF nativo (nunca
        do caminho legado). Fail-closed. Somente leitura. Nunca lanca.
    .DESCRIPTION
        PRA-SETTLE-FIX4: a varredura de exclusao de efeito por task e a
        duplicata do SETTLE precisam saber se um 'settled' foi gravado pelo
        handoff (`Invoke-OrchestrationNativeDispatchSettle`) ou pelo caminho
        legado (`Invoke-OrchestrationNativeDispatch`), porque os DOIS schemas
        coexistem no mesmo store e a regra de liberacao da reserva e
        DIFERENTE para cada um.

        A discriminacao usa SOMENTE campos que o handoff grava e o legado
        nunca grava - `settle_*` (status, refs, child session, sessao/
        mensagem/call/caller/target, marcadores de tentativa/evidencia),
        `settled_by`, `settled_generation` e `handoff_state='SETTLED'`.
        Campos como `worker_result`, `kernel_ok`, `evidence_created`,
        `evidence_id` e `settled_at` existem nos DOIS caminhos e portanto
        NAO discriminam nada.

        Leitura por nome de propriedade (direto, sem pipeline): um token em
        forma de array continua sendo detectado pela PRESENCA do campo, que
        e o que interessa aqui. Qualquer duvida devolve $false - nunca
        $true por excesso de confianca.

        PRA-SETTLE-FIX6A: a comparacao de NOMES e feita sobre a forma
        INVARIANTE (lowercase) de cada nome - `SETTLE_STATUS`,
        `Settle_Status` e `settle_status` tem de ser reconhecidos igualmente,
        senao trocar a caixa de um campo esconderia a linhagem. O escopo
        continua ESTRITO (so a linhagem da liquidacao): a deteccao ampla,
        que decide o schema do registro, e `Test-NDHandoffRecordMarkers`.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        if (($Receipt -is [string]) -or ($Receipt -is [Array]) -or ($Receipt -is [bool])) { return $false }
        $names = @()
        if ($Receipt -is [System.Collections.IDictionary]) { $names = @($Receipt.Keys) }
        else {
            try { foreach ($pp in @($Receipt.PSObject.Properties)) { $names += [string]$pp.Name } } catch { return $false }
        }
        foreach ($n in @($names)) {
            $nn = ([string]$n).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($nn)) { continue }
            if ($nn.Length -gt 7) {
                if ($nn.Substring(0, 7) -ceq 'settle_') { return $true }
            }
            if (($nn -ceq 'settled_by') -or ($nn -ceq 'settled_generation')) { return $true }
        }
        $state = Get-NDJsonStringValue -Object $Receipt -Name 'handoff_state'
        if (($null -ne $state) -and (([string]$state).Trim().ToUpperInvariant() -ceq 'SETTLED')) { return $true }
        return $false
    }
    catch { return $false }
}

function Test-NDHandoffRecordMarkers {
    <#
    .SYNOPSIS
        $true SOMENTE quando o registro carrega PELO MENOS UM marcador que
        existe no HANDOFF e NUNCA no caminho legado. Fail-closed. Somente
        leitura. Nunca lanca.
    .DESCRIPTION
        PRA-SETTLE-FIX5: a varredura de exclusao de efeito por task precisa
        decidir "este registro e de OUTRA task, ignoro" ANTES de qualquer
        prova semantica - e um 'settled' do HANDOFF com o `task_id` trocado
        por outro id VALIDO (hashes intactos) passaria por essa decisao sem
        nunca ser validado, liberando um segundo efeito da task original.
        A unima forma de fechar esse buraco e exigir a prova completa de
        QUALQUER registro que carregue marcadores de handoff, em QUALQUER
        fase, ANTES da atribuicao.

        `Test-NDHandoffSettledMarker` e estreita demais para isso: ela so
        enxerga a LINHAGEM DA LIQUIDACAO (`settle_*`, `settled_by`,
        `settled_generation`, `handoff_state='SETTLED'`). Um registro
        'settled' que carrega o material do handoff MAS tem a liquidacao
        ausente ou corrompida (por exemplo `session_id` + `prepared_*` sem
        `handoff_state`, ou `handoff_state` com outro valor) cairia na
        porta LEGADA - que tem regra propria e bem mais permissiva. Aqui o
        conjunto e POSITIVO, FECHADO e COMPLETO - cobre TODOS os campos que
        o handoff grava e o legado NUNCA grava, e mais nenhum:

          PREFIXOS (qualquer sufixo):
          - `settle_*`   - liquidacao: status, refs, child session,
                           sessao/mensagem/call/caller/target, marcadores de
                           tentativa (`settle_attempt_*`) e de evidencia
                           (`settle_evidence_*`);
          - `claim_*`    - linhagem da chamada do host que consumiu o
                           preparo (sessao/mensagem/call/caller/target e
                           claim_prepared_fingerprint);
          - `claimed_*`  - identidade da transicao preparado -> claimed
                           (`claimed_by`, `claimed_generation`, `claimed_at`);
          - `prepared_*` - preparo duravel (prepared_fingerprint,
                           prepared_by, prepared_generation, prepared_at).

          NOMES EXATOS:
          - `settled_by`, `settled_generation` (identidade da liquidacao);
          - `handoff_state` - pela PRESENCA do campo, com qualquer valor
            (ou token): a ausencia de divisao clara e justamente o caso
            "handoff malformado" que nao pode ser lido como legado;
          - `reference` (a referencia opaca do preparo) e `session_id`;
          - PRA-SETTLE-FIX6C: `base_revision`, `prompt_hash`, `scope`,
            `acceptance_criteria`, `external_idempotency_proof` e
            `prepared_fingerprint` - o material semantico do preparo
            duravel, que nao casa com nenhum dos quatro prefixos. Confirmado
            campo a campo contra os escritores: os TRES escritores LEGADOS
            ('pending', 'settled' e a recusa PRE-efeito do pos-lock fencing)
            nao gravam NENHUM desses nomes; o escritor do PREPARE do handoff
            grava TODOS. `prepared_fingerprint` ja era coberto pelo prefixo
            `prepared_*` e entra explicito porque a revisao o exige nomeado.

        NOMES CANONICOS X CAIXA X FORMA (PRA-SETTLE-FIX6A): a comparacao e
        feita sobre a forma INVARIANTE de cada nome - trim de espaco
        circundante + minuscula -, porque a versao anterior era sensivel a
        caixa (`SETTLE_STATUS` ou `HANDOFF_STATE` nao eram reconhecidos e o
        registro marcado era lido como LEGADO) e, sem o trim, tambem sensivel
        a espaco em volta do nome (`handoff_state `, ` settle_status`).
        Um nome que casa com o conjunto mas NAO esta na caixa canonica e
        recusado mais adiante pela porta de forma do registro
        (`Test-NDCanonicalReceiptFieldNames`, aplicada por
        `Test-NDReceiptScanRecord` a todo registro marcado): registro com
        marcador nao canonico nao e o registro que a liquidacao escreveu,
        portanto nao pode ser lido como legado NEM como handoff conhecido.

        CONJUNTO COMPLETO (PRA-SETTLE-FIX6B): o conjunto abaixo foi
        confrontado campo a campo com TODOS os escritores de recibo de
        handoff - `Invoke-OrchestrationNativeDispatchPrepare` (prepared_by/
        prepared_generation/prepared_at e demais `prepared_*`),
        `Invoke-OrchestrationNativeDispatchClaim` (`claim_*`,
        `claimed_by`/`claimed_generation`/`claimed_at`),
        `Invoke-OrchestrationNativeDispatchSettle` (`settle_*`, inclusive
        `settle_attempt_*` e `settle_evidence_*`, mais `settled_by`/
        `settled_generation`) e a caixa do envelope - e NAO existe nenhum
        nome exclusivo do handoff fora dele. Os quatro prefixos usam o
        MESMO limite (tamanho do nome maior ou igual ao tamanho do
        prefixo), entao nenhuma linhagem escapa por off-by-one - e o nome
        que e exatamente o prefixo (`settle_`, `claim_`, `claimed_`,
        `prepared_`) tambem MARCA, porque nao e campo de escritor algum.

        CORRECAO DA COMPLETUDE (PRA-SETTLE-FIX6C): a varredura da FIX6B
        confrontou o conjunto com os escritores de handoff, mas NAO com os
        escritores LEGADOS, e por isso deixou de fora nomes exclusivos do
        handoff que nao casam com prefixo algum: `base_revision`,
        `prompt_hash`, `scope`, `acceptance_criteria` e
        `external_idempotency_proof` (mais `prepared_fingerprint`, que o
        prefixo `prepared_*` ja cobria e que passa a ser nomeado explicito).
        Nenhum dos tres escritores legados ('pending', 'settled' e a recusa
        PRE-efeito) grava esses nomes - o unico escritor deles e o PREPARE
        do handoff. A consequencia da omissao era direta: um 'settled' em
        FORMA legada carregando APENAS UM desses campos como marcador
        sobrevivente era classificado como legado, e com o task_id trocado
        por outro id VALIDO (hashes intactos) era atribuido a outra task e
        IGNORADO pela varredura de exclusao - liberando o segundo efeito da
        task original. Com os nomes no conjunto, qualquer um deles como
        marcador sobrevivente classifica o registro como handoff; se a caixa
        do nome for nao canonica, quem recusa e
        `Test-NDCanonicalReceiptFieldNames` (nunca a porta legada).
        CHAVE SEMANTICA DUPLICADA: um registro com a MESMA chave semantica
        em duas variantes de caixa (`handoff_state` + `HANDOFF_STATE`) nao
        chega a ser classificado - o proprio parse do recibo recusa
        (chaves duplicadas no JSON) e a varredura falha fechada em
        'claim-task-scan-unreadable'. Nenhum caminho rebaixa registro
        marcado a legado.

        ALFABETO CANONICO (PRA-SETTLE-FIX6A): alem do conjunto de marcadores,
        TODO nome de campo fora do alfabeto `[a-z0-9_]` - espaco interno,
        pontuacao, separador trocado, caractere exotico - MARCA o registro.
        Nenhum escritor de recibo (legado ou handoff) grava nome nessa forma,
        entao nome assim nao pertence a nenhum schema conhecido e nao pode
        ser lido como legado; o registro marcado e recusado fail-closed pelas
        portas de forma/prova. A direcao da duvida e sempre a mesma: nao
        reconhecer um nome NUNCA pode significar "e legado".

        LIMITE HONESTO: `settled_at`, `worker_result`, `kernel_ok`,
        `kernel_reason`, `evidence_created`, `evidence_id`, `ok`,
        `reason`, `reconciled` e `executor_calls` existem nos DOIS
        caminhos e portanto NAO discriminam nada - nao entram no conjunto.
        Por isso um registro do qual TENHAM sido removidos todos os
        marcadores e inevitavelmente indistinguivel de legado; o que a
        completude do conjunto garante e que NAO existe nenhuma linhagem de
        handoff - inclusive `claimed_*`, que a versao anterior nao cobria
        - que possa ser o UNICO marcador sobrevivente.

        O caminho legado ('pending'/'settled' de
        `Invoke-OrchestrationNativeDispatch`) nao grava NENHUM desses
        campos, portanto um registro sem eles segue no schema legado -
        inambiguamente. Qualquer duvida (objeto nulo, forma nao-registro,
        IO) devolve $false; a porta de quem chama e que decide o
        fail-closed.

        NAO EXISTE RECLASSIFICACAO AUTOMATICA: registro MARCADO que
        falha a porta do handoff e RECUSADO (falha fechada), nunca
        rebaixado ao schema legado - inclusive quando carrega apenas
        ALGUNS dos marcadores (registro hibrido). Somente um registro
        sem marcador algum pode ser lido como legado. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        if (($Receipt -is [string]) -or ($Receipt -is [Array]) -or ($Receipt -is [bool])) { return $false }
        $names = @()
        if ($Receipt -is [System.Collections.IDictionary]) { $names = @($Receipt.Keys) }
        else {
            try { foreach ($pp in @($Receipt.PSObject.Properties)) { $names += [string]$pp.Name } } catch { return $false }
        }
        foreach ($n in @($names)) {
            # PRA-SETTLE-FIX6A: nome na forma INVARIANTE (trim + lowercase) -
            # caixa e espaco CIRCUNDANTE nunca decidem o schema (ver doc). Sem
            # o trim, `handoff_state ` (espaco a direita) ou ` settle_status`
            # escapavam da deteccao e caiam na porta legada; com ele, o nome
            # alterado e reconhecido e recusado fail-closed pelas portas
            # seguintes. A caixa nao canonica tambem nao decide aqui.
            $nRaw = ([string]$n).Trim()
            # Nome VAZIO ou so de espaco nao e campo de nenhum escritor:
            # registro com nome assim e MARCADO (nunca legado).
            if ([string]::IsNullOrWhiteSpace($nRaw)) { return $true }
            $nn = $nRaw.ToLowerInvariant()
            # ALFABETO CANONICO FECHADO: TODO nome gravado pelos escritores de
            # recibo - legado E handoff - e `[a-z0-9_]+`. Um nome fora desse
            # conjunto (espaco interno, pontuacao, caractere exotico) nao e
            # campo de nenhum schema conhecido, portanto nao pode ser lido
            # como legado: o registro e MARCADO e recusado fail-closed. Isso
            # fecha a variante "nao canonica por FORMA" - casos como
            # `handoff state` ou um separador trocado - que a comparacao por
            # nome exato/prefixo nao enxergaria.
            if ($nn -cnotmatch '^[a-z0-9_]+$') { return $true }
            # linhagens gravadas SOMENTE pelo handoff. Cada prefixo casa
            # tambem quando o nome E EXATAMENTE o prefixo (`settle_`,
            # `claim_`, `claimed_`, `prepared_`): nome assim nao e campo
            # de nenhum escritor de recibo e, pela direcao da duvida deste
            # conjunto, MARCA - nunca rebaixa a legado. Os quatro limites
            # ficam uniformes em (tamanho >= tamanho do prefixo), para que
            # nenhuma linhagem fique de fora por um off-by-one
            # (PRA-SETTLE-FIX6B).
            if (($nn.Length -ge 7) -and ($nn.Substring(0, 7) -ceq 'settle_')) { return $true }
            if (($nn.Length -ge 6) -and ($nn.Substring(0, 6) -ceq 'claim_')) { return $true }
            if (($nn.Length -ge 8) -and ($nn.Substring(0, 8) -ceq 'claimed_')) { return $true }
            if (($nn.Length -ge 9) -and ($nn.Substring(0, 9) -ceq 'prepared_')) { return $true }
            if (($nn -ceq 'settled_by') -or ($nn -ceq 'settled_generation')) { return $true }
            if ($nn -ceq 'handoff_state') { return $true }
            if (($nn -ceq 'reference') -or ($nn -ceq 'session_id')) { return $true }
            # PRA-SETTLE-FIX6C: nomes EXATOS, exclusivos do handoff, que os
            # quatro prefixos NAO cobrem - o material semantico do preparo
            # duravel. Confirmado campo a campo contra os escritores de
            # recibo: os TRES escritores LEGADOS ('pending', 'settled' e a
            # recusa PRE-efeito do pos-lock fencing) nao gravam NENHUM desses
            # nomes; o escritor do PREPARE do handoff grava TODOS. Sem eles no
            # conjunto, um 'settled' em FORMA legada carregando APENAS UM
            # desses campos como marcador sobrevivente era lido como legado -
            # e, com o task_id trocado por outro id VALIDO e hashes intactos,
            # atribuido a outra task e IGNORADO, liberando o segundo efeito da
            # task original. `prepared_fingerprint` ja era coberto pelo
            # prefixo `prepared_*` e entra explicito porque a revisao o exige
            # nomeado. A comparacao usa a forma INVARIANTE ($nn), como todo o
            # conjunto: caixa e espaco circundante nunca decidem o schema.
            if (($nn -ceq 'base_revision') -or ($nn -ceq 'prompt_hash') -or ($nn -ceq 'scope') -or ($nn -ceq 'acceptance_criteria') -or ($nn -ceq 'external_idempotency_proof') -or ($nn -ceq 'prepared_fingerprint')) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-NDCanonicalReceiptFieldNames {
    <#
    .SYNOPSIS
        $true SOMENTE quando TODOS os nomes de campo do registro estao na
        caixa CANONICA (minuscula invariante). Fail-closed. Somente
        leitura. Nunca lanca.
    .DESCRIPTION
        PRA-SETTLE-FIX6A: todo nome de campo que os escritores de recibo
        gravam e canonico em minusculas (`settle_status`,
        `claim_session_id`, `handoff_state`, `session_id`, `reference`,
        `claimed_by`, ...). Um nome fora dessa caixa nao e o campo que a
        liquidacao escreveu - e, como a leitura de propriedade do
        PowerShell (`PSObject.Properties[name]`) e case-INSENSITIVE nas
        duas edicoes (5.1 e 7), `HANDOFF_STATE` seria lido como
        `handoff_state` pelas portas de forma/prova sem que o registro
        persistido fosse, de fato, o registro canonico.

        Esta funcao e a porta de caixa exigida ANTES da selecao de schema:
        `Test-NDReceiptScanRecord` a aplica a TODO registro que carregue
        marcadores de handoff (`Test-NDHandoffRecordMarkers`, agora
        case-insensitive). Registro marcado com nome nao canonico recusa a
        varredura em 'claim-task-scan-unreadable' - nunca e rebaixado a
        legado e nunca e aceito como handoff conhecido. Registro sem
        marcador algum (legado de verdade) nao passa por aqui e segue no
        caminho legado inalterado.

        Qualquer duvida (objeto nulo, forma nao-registro, propriedade
        ilegivel, nome vazio) devolve $false - fail-closed. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        if (($Receipt -is [string]) -or ($Receipt -is [Array]) -or ($Receipt -is [bool])) { return $false }
        $names = @()
        if ($Receipt -is [System.Collections.IDictionary]) { $names = @($Receipt.Keys) }
        else {
            try { foreach ($pp in @($Receipt.PSObject.Properties)) { $names += [string]$pp.Name } } catch { return $false }
        }
        foreach ($n in @($names)) {
            $nn = [string]$n
            if ([string]::IsNullOrWhiteSpace($nn)) { return $false }
            if ($nn -cne $nn.ToLowerInvariant()) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-NDSettledHandoffProof {
    <#
    .SYNOPSIS
        Prova ESTRITA de que um 'settled' do HANDOFF e liquidacao CONHECIDA,
        RECONSTRUIDA dos campos persistidos no PROPRIO registro. Fail-closed,
        somente leitura.
    .DESCRIPTION
        PRA-SETTLE-FIX5: a porta anterior conferia forma crua + flags
        (kernel_ok/evidence_created/evidence_id/settle_status). Um registro
        'settled' com UM campo de MESMO TIPO alterado - child session id
        trocado por outra string valida, evidence_id trocado por outro hash
        valido - passava por essa porta: a varredura de exclusao liberava a
        reserva de task e a duplicata respondia idempotente sobre um registro
        que NAO e o que a liquidacao gravou. A liquidacao agora e
        RECONSTRUIDA dos campos duradouros do PROPRIO registro, e cada campo
        da liquidacao e correlacionado com os que a acompanham:

          (a) FORMA CRUA dos campos que so a liquidacao grava
              (`Test-NDSettledReceiptFieldShape`): booleanos exatos, inteiro
              exato, strings, objeto do candidato e arrays de refs. Token em
              forma de array (`kernel_ok:[true]`,
              `settle_child_session_id:["filho"]`) ou campo ausente recusa
              em 'settled-shape-invalid' - INDECIDIVEL;
          (b) fase 'settled' e handoff_state 'SETTLED' (strings cruas);
          (c) `kernel_ok` EXATAMENTE booleano true (liquidacao conhecida) e
              `reconciled` EXATAMENTE booleano false (liquidacao desta
              claim, nunca replay reconciliado de pendencia alheia);
          (d) `evidence_created` EXATAMENTE booleano true e `evidence_id`
              string NAO VAZIA (evidencia exigida);
          (e) `settle_status` em candidate_pass|failed|blocked (nunca
              verified_pass/done/aprovado);
          (f) IDENTIDADE DO RECIBO: `settled_by` EXATAMENTE `owner`,
              `settled_generation` EXATAMENTE `ownership_generation` e
              `settle_target_agent` EXATAMENTE `agent` - o efeito liquidado
              e o do Intent persistido, liquidoado pela ownership que o
              autorizou;
          (g) LINFAGEM DA CHAMADA DO HOST: `settle_session_id`,
              `settle_message_id`, `settle_call_id`, `settle_caller_agent` e
              `settle_target_agent` EXATAMENTE iguais aos campos `claim_*`
              da chamada que consumiu o preparo, e o filho
              (`settle_child_session_id`, string nao vazia) DISTINTO da
              sessao pai - child binding;
          (h) MARCADORES DUROUEIS da tentativa (`settle_attempt_*`),
              gravados no registro ANTES da escrita final: child, sessao,
              mensagem, call, caller, target, status e refs tem de ser
              EXATAMENTE os campos desta liquidacao. Campo ausente ou
              divergente recusa em 'settled-attempt-mismatch';
          (i) EVIDENCIA VINCULADA: `settle_evidence_created` booleano true e
              `settle_evidence_id` string nao vazia, e `evidence_created` /
              `evidence_id` do registro EXATAMENTE esses valores - a
              evidencia que prova esta liquidacao e a marcada no MESMO
              registro ('settled-evidence-unbound');
          (j) CANDIDATO CORRELACIONADO: `worker_result.status` EXATAMENTE
              `settle_status` e `worker_result.claimed_evidence`
              EXATAMENTE `settle_claimed_evidence` (comparacao estrutural
              profunda por NO, elemento a elemento e em ordem);
          (k) INTEGRIDADE SEMANTICA RECALCULADA do registro
              (`Test-NDReceiptSemanticIntegrity`, com goal_id e
              idempotency_key LIDOS DO PROPRIO registro): intent_fingerprint,
              prepared_fingerprint e a referencia opaca reconstruidos campo
              a campo.

        Devolve @{ok, reason}. 'settled-shape-invalid' sinaliza registro
        INDECIDIVEL (token cru de tipo errado ou campo ausente): o chamador
        da varredura recusa a varredura ('claim-task-scan-unreadable'). Os
        demais motivos - INCLUSIVE semantica adulterada
        ('settled-integrity-invalid') - sinalizam liquidacao NAO PROVADA: a
        reserva continua valendo ('claim-task-already-claimed') e a
        duplicata nao e idempotente ('settle-duplicate-unproven'). NAO ha
        liberacao de reserva por revisao de task avancada nem por kernel_ok
        true solto: a prova e do PROPRIO registro, nunca do kernel vivo.

        CRITERIO DE LIBERACAO (explicito): a reserva de task so e liberada
        por esta porta quando TODOS os itens (a)-(k) passam, com os campos
        de identidade/liquidacao RECONSTRUIDOS e correlacionados DENTRO do
        proprio registro persistido. Registro MARCADO - em qualquer fase,
        com alguns ou com todos os marcadores - que falha em qualquer item
        NUNCA e rebaixado ao schema legado e NUNCA libera a reserva: nao
        existe reclassificacao automatica. Um registro malformado ou
        hibrido (marcadores de handoff sem a liquidacao completa, ou
        liquidacao sem os marcadores que a acompanham) recusa fechado.

        LIMITACAO DE CONFIANCA NO DESCRITOR DO HOST: a correlacao
        settle_*/claim_*/settle_attempt_* confere FORMA e COERENCIA
        INTERNA do registro. Ela NAO autentica o evento do host - a
        identidade da chamada precisa de provenance independente do
        runtime (ver `Test-NDHostCallDescriptor`) - e NAO prova que o
        efeito externo aconteceu; prova apenas que o registro persistido
        e internamente consistente com a liquidacao que afirma.
        Nunca lanca e nunca devolve ok=$true por excesso de confianca.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    $bad = [pscustomobject]@{ ok = $false; reason = 'settled-shape-invalid' }
    $deny = {
        param([string]$Why)
        return [pscustomobject]@{ ok = $false; reason = ([string]$Why) }
    }
    try {
        if ($null -eq $Receipt) { return $bad }
        # (a) forma crua dos campos proprios da liquidacao do handoff.
        if (-not (Test-NDSettledReceiptFieldShape -Receipt $Receipt)) { return $bad }
        # (b) fase + estado da maquina do handoff.
        $ph = Get-NDJsonStringValue -Object $Receipt -Name 'phase'
        if (($null -eq $ph) -or (([string]$ph).Trim().ToLowerInvariant() -cne 'settled')) {
            return (& $deny 'settled-phase-invalid')
        }
        $st8 = Get-NDJsonStringValue -Object $Receipt -Name 'handoff_state'
        if (($null -eq $st8) -or (([string]$st8).Trim().ToUpperInvariant() -cne 'SETTLED')) {
            return (& $deny 'settled-state-invalid')
        }
        # (c) kernel conhecido: booleano EXATAMENTE true; reconciled EXATO
        #     false (a liquidacao do handoff nunca e replay reconciliado).
        $kOk = Get-NDJsonBoolValue -Object $Receipt -Name 'kernel_ok'
        if (($null -eq $kOk) -or (-not $kOk)) {
            return (& $deny 'settled-kernel-not-proven')
        }
        $recTok = Get-NDJsonBoolValue -Object $Receipt -Name 'reconciled'
        if (($null -eq $recTok) -or ($recTok)) {
            return (& $deny 'settled-reconciled-unexpected')
        }
        # (d) evidencia exigida: criada + id nao vazio.
        $evCreated = Get-NDJsonBoolValue -Object $Receipt -Name 'evidence_created'
        if (($null -eq $evCreated) -or (-not $evCreated)) {
            return (& $deny 'settled-evidence-missing')
        }
        $evId = Get-NDJsonStringValue -Object $Receipt -Name 'evidence_id'
        if (($null -eq $evId) -or ([string]::IsNullOrWhiteSpace([string]$evId))) {
            return (& $deny 'settled-evidence-missing')
        }
        # (e) status do candidato dentro do conjunto permitido.
        $status = Get-NDJsonStringValue -Object $Receipt -Name 'settle_status'
        if ($null -eq $status) { return (& $deny 'settled-status-invalid') }
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains (([string]$status).Trim().ToLowerInvariant())) {
            return (& $deny 'settled-status-invalid')
        }
        # (f) identidade do recibo: quem liquidou, com que ownership e sobre
        #      qual Intent. Tokens crus, sem pipeline e sem coercao.
        $ownTok = Get-NDJsonStringValue -Object $Receipt -Name 'owner'
        $sByTok = Get-NDJsonStringValue -Object $Receipt -Name 'settled_by'
        if (($null -eq $ownTok) -or ($null -eq $sByTok) -or ([string]::IsNullOrWhiteSpace([string]$sByTok)) -or ([string]$ownTok -cne [string]$sByTok)) {
            return (& $deny 'settled-identity-mismatch')
        }
        $genTok = Get-NDJsonIntegralLong -Object $Receipt -Name 'ownership_generation'
        $sGenTok = Get-NDJsonIntegralLong -Object $Receipt -Name 'settled_generation'
        if (($null -eq $genTok) -or ($null -eq $sGenTok) -or ([long]$genTok -ne [long]$sGenTok)) {
            return (& $deny 'settled-identity-mismatch')
        }
        $agentTok = Get-NDJsonStringValue -Object $Receipt -Name 'agent'
        $tgtTok = Get-NDJsonStringValue -Object $Receipt -Name 'settle_target_agent'
        if (($null -eq $agentTok) -or ($null -eq $tgtTok) -or ([string]$agentTok -cne [string]$tgtTok)) {
            return (& $deny 'settled-identity-mismatch')
        }
        # (g) linhagem da chamada do host: a liquidacao grava a MESMA chamada
        #      que o CLAIM consumiu (claim_*), e uma sessao filha DISTINTA.
        $sessTok = Get-NDJsonStringValue -Object $Receipt -Name 'settle_session_id'
        foreach ($lp in @(
            @{ n = 'settle_session_id';   c = 'claim_session_id' }
            @{ n = 'settle_message_id';   c = 'claim_message_id' }
            @{ n = 'settle_call_id';      c = 'claim_call_id' }
            @{ n = 'settle_caller_agent'; c = 'claim_caller_agent' }
            @{ n = 'settle_target_agent'; c = 'claim_target_agent' }
        )) {
            $aTok = Get-NDJsonStringValue -Object $Receipt -Name ([string]$lp.n)
            $cTok = Get-NDJsonStringValue -Object $Receipt -Name ([string]$lp.c)
            if (($null -eq $aTok) -or ($null -eq $cTok) -or ([string]::IsNullOrWhiteSpace([string]$aTok)) -or ([string]$aTok -cne [string]$cTok)) {
                return (& $deny 'settled-lineage-invalid')
            }
        }
        $childTok = Get-NDJsonStringValue -Object $Receipt -Name 'settle_child_session_id'
        if (($null -eq $childTok) -or ([string]::IsNullOrWhiteSpace([string]$childTok)) -or ($null -eq $sessTok) -or ([string]$childTok -ceq [string]$sessTok)) {
            return (& $deny 'settled-lineage-invalid')
        }
        # (h) marcadores duradouros da tentativa: tem de ser EXATAMENTE os
        #      campos desta liquidacao (ausente ou divergente recusa).
        foreach ($ap in @(
            @{ n = 'settle_child_session_id'; a = 'settle_attempt_child_session_id' }
            @{ n = 'settle_session_id';       a = 'settle_attempt_session_id' }
            @{ n = 'settle_message_id';       a = 'settle_attempt_message_id' }
            @{ n = 'settle_call_id';          a = 'settle_attempt_call_id' }
            @{ n = 'settle_caller_agent';     a = 'settle_attempt_caller_agent' }
            @{ n = 'settle_target_agent';     a = 'settle_attempt_target_agent' }
            @{ n = 'settle_status';           a = 'settle_attempt_status' }
        )) {
            $aTok = Get-NDJsonStringValue -Object $Receipt -Name ([string]$ap.n)
            $mTok = Get-NDJsonStringValue -Object $Receipt -Name ([string]$ap.a)
            if (($null -eq $aTok) -or ($null -eq $mTok) -or ([string]$aTok -cne [string]$mTok)) {
                return (& $deny 'settled-attempt-mismatch')
            }
        }
        $refsLive = Get-NDValueNode -Object $Receipt -Name 'settle_claimed_evidence'
        $refsAttempt = Get-NDValueNode -Object $Receipt -Name 'settle_attempt_claimed_evidence'
        if (-not (Test-NDReceiptValueMatch -Expected $refsLive -Actual $refsAttempt)) {
            return (& $deny 'settled-attempt-mismatch')
        }
        # (i) evidencia vinculada: o par persistido na liquidacao e EXATAMENTE
        #      o par do marcador duravel de evidencia.
        $evMarkCreated = Get-NDJsonBoolValue -Object $Receipt -Name 'settle_evidence_created'
        $evMarkId = Get-NDJsonStringValue -Object $Receipt -Name 'settle_evidence_id'
        if (($null -eq $evMarkCreated) -or (-not $evMarkCreated) -or ($null -eq $evMarkId) -or ([string]::IsNullOrWhiteSpace([string]$evMarkId))) {
            return (& $deny 'settled-evidence-unbound')
        }
        if ([string]$evMarkId -cne [string]$evId) {
            return (& $deny 'settled-evidence-unbound')
        }
        # (j) candidato correlacionado: o worker_result do registro e a foto
        #      do MESMO candidato que settle_status/settle_claimed_evidence.
        $wrNode = Get-NDValueNode -Object $Receipt -Name 'worker_result'
        if ([string]$wrNode.kind -cne 'object') { return (& $deny 'settled-candidate-mismatch') }
        $wrVal = $wrNode.value
        if ($null -eq $wrVal) { return (& $deny 'settled-candidate-mismatch') }
        $wrStatusTok = Get-NDJsonStringValue -Object $wrVal -Name 'status'
        if (($null -eq $wrStatusTok) -or ([string]$wrStatusTok -cne [string]$status)) {
            return (& $deny 'settled-candidate-mismatch')
        }
        $wrRefsNode = Get-NDValueNode -Object $wrVal -Name 'claimed_evidence'
        if (-not (Test-NDReceiptValueMatch -Expected $refsLive -Actual $wrRefsNode)) {
            return (& $deny 'settled-candidate-mismatch')
        }
        # (k) integridade semantica RECALCULADA do registro, com goal_id e
        #      idempotency_key lidos DO PROPRIO registro (token cru).
        $recGoal = Get-NDJsonStringValue -Object $Receipt -Name 'goal_id'
        $recKey = Get-NDJsonStringValue -Object $Receipt -Name 'idempotency_key'
        if (($null -eq $recGoal) -or ($null -eq $recKey)) { return (& $deny 'settled-integrity-invalid') }
        $integ = Test-NDReceiptSemanticIntegrity -Receipt $Receipt -GoalId ([string]$recGoal) -IdempotencyKey ([string]$recKey)
        $integOk = Get-NDJsonBoolValue -Object $integ -Name 'ok'
        if (($null -eq $integOk) -or (-not $integOk)) {
            return (& $deny 'settled-integrity-invalid')
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch { return $bad }
}

function Get-NDCanonicalField {
    <#
    .SYNOPSIS
        Serializa um campo como nome:comprimento:valor; (R2, nao-ambiguo).
    .DESCRIPTION
        Prefixo de comprimento em caracteres elimina ambiguidade mesmo
        quando o valor contem os delimitadores. ASCII-only no codigo;
        o valor e opaco (qualquer texto). Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Name = '', [string]$Value = '')
    try {
        $v = ([string]$Value)
        return ([string]$Name + ':' + [string]$v.Length + ':' + $v + ';')
    }
    catch { return ([string]$Name + ':0:;') }
}

function Get-NDSortedOrdinal {
    [CmdletBinding()]
    param($Items = $null)
    try {
        $arr = @()
        foreach ($x in @($Items)) { $arr += @(([string]$x).Trim()) }
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
        return $arr
    }
    catch { return @() }
}

function Get-NDIntentFingerprint {
    <#
    .SYNOPSIS
        Fingerprint canonico do Intent completo (F7+R2). Qualquer
        divergencia semantica muda o fingerprint; a mesma idempotency_key
        com fingerprint distinto e colisao, nunca reutilizacao.
    .DESCRIPTION
        Serializacao canonica estruturada v2 (R2): ordem fixa de campos,
        cada valor com prefixo de comprimento (nao-ambiguo mesmo com
        delimitadores no valor), listas (scope, acceptance_criteria)
        ordenadas em ordinal com contagem explicita. Cobre TODOS os campos
        semanticos: task, owner, generation, agent, scopes, prompt-hash,
        base-revision, expected-revision, external_idempotent e
        external_idempotency_proof. Em particular, upgrade de idempotencia
        (adicionar external_idempotent/proof num reenvio) muda o
        fingerprint e e recusado como colisao.
    #>
    [CmdletBinding()]
    param($Intent = $null)
    try {
        $scopes = Get-NDSortedOrdinal -Items @((Get-NDValue $Intent 'scope' @()))
        $acc = Get-NDSortedOrdinal -Items @((Get-NDValue $Intent 'acceptance_criteria' @()))
        $extFlag = '0'
        if ([bool](Get-NDValue $Intent 'external_idempotent' $false)) { $extFlag = '1' }
        $material = 'ndfp2;'
        $material += Get-NDCanonicalField -Name 'task' -Value ([string](Get-NDValue $Intent 'task_id' ''))
        $material += Get-NDCanonicalField -Name 'owner' -Value ([string](Get-NDValue $Intent 'owner' ''))
        $material += Get-NDCanonicalField -Name 'gen' -Value ([string]([long](Get-NDValue $Intent 'ownership_generation' 0)))
        $material += Get-NDCanonicalField -Name 'agent' -Value ([string](Get-NDValue $Intent 'agent' ''))
        $material += Get-NDCanonicalField -Name 'prompt' -Value ([string](Get-NDValue $Intent 'prompt_hash' ''))
        $material += Get-NDCanonicalField -Name 'base' -Value ([string](Get-NDValue $Intent 'base_revision' ''))
        $material += Get-NDCanonicalField -Name 'rev' -Value ([string]([long](Get-NDValue $Intent 'task_expected_revision' 0)))
        $material += Get-NDCanonicalField -Name 'ext' -Value $extFlag
        $material += Get-NDCanonicalField -Name 'proof' -Value ([string](Get-NDValue $Intent 'external_idempotency_proof' ''))
        $material += 'acc:' + [string](@($acc).Count) + ';'
        foreach ($a in @($acc)) { $material += Get-NDCanonicalField -Name 'a' -Value ([string]$a) }
        $material += 'scope:' + [string](@($scopes).Count) + ';'
        foreach ($s in @($scopes)) { $material += Get-NDCanonicalField -Name 's' -Value ([string]$s) }
        return (Get-NativeDispatchHash32 $material)
    }
    catch { return '' }
}

function Test-NDLiveTaskAdmission {
    <#
    .SYNOPSIS
        Admissao pre-efeito contra o kernel vivo (F1). Fail-closed.
    .DESCRIPTION
        Valida ANTES de qualquer efeito: a flag efetiva do TaskKernel
        (R1: kernel OFF recusa com 0 calls mesmo com task existente, pois
        o kernel nao aceitaria o worker-result); a task existe no
        TaskKernel e nao esta em estado terminal; a revisao esperada e o
        base_revision do Intent conferem com o registro vivo; owner/generation do Intent
        conferem com a Authorization; o dono atual da task confere com a
        Authorization; a task pertence ao goal da Authorization (active_tasks
        do goal vivo); cada scope do Intent esta nos read/write scopes da
        task; quando a Authorization declara allowed_agents/allowed_scopes,
        o agent e os scopes do Intent estao contidos neles. Qualquer
        divergencia recusa com 0 calls do Executor. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Intent = $null, $Authorization = $null, $Goal = $null, [string]$TasksDir = '', [string]$FlagsPath = '', [string]$RepoRoot = '')
    try {
        # R1: flag efetiva do TaskKernel ANTES de qualquer efeito. Kernel
        # OFF + task existente recusa com 0 calls: sem kernel vivo nao ha
        # como liquidar o worker-result, entao admitir seria efeito sem
        # liquidacao. Fail-closed quando o estado da flag e indeterminavel.
        $flagCmd = Get-Command Get-TaskKernelFlagState -ErrorAction SilentlyContinue
        if ($null -eq $flagCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-unavailable' }
        }
        $flags = $null
        try { $flags = Get-TaskKernelFlagState -FlagsPath $FlagsPath -RepoRoot $RepoRoot }
        catch { $flags = $null }
        if (($null -eq $flags) -or (-not [bool](Get-NDValue $flags 'enabled' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-disabled' }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'taskkernel-unavailable' }
        }
        $tid = ([string](Get-NDValue $Intent 'task_id' '')).Trim()
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'task-read-failed' }
        }
        $errCode = ''
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('error')) { $errCode = ([string]$task['error']) }
            }
            else {
                $ep = $task.PSObject.Properties['error']
                if ($null -ne $ep) { $errCode = ([string]$ep.Value) }
            }
        }
        catch { $errCode = '' }
        if (-not [string]::IsNullOrWhiteSpace($errCode)) {
            if ($errCode -ceq 'NOT_FOUND') {
                return [pscustomobject]@{ ok = $false; reason = 'task-not-found' }
            }
            if ($errCode -ceq 'KERNEL_DISABLED') {
                return [pscustomobject]@{ ok = $false; reason = 'taskkernel-disabled' }
            }
            return [pscustomobject]@{ ok = $false; reason = ('task-read-failed:' + $errCode) }
        }
        $termCmd = Get-Command Test-TaskKernelTerminalState -ErrorAction SilentlyContinue
        $tState = ([string](Get-NDValue $task 'state' '')).Trim().ToUpperInvariant()
        $isTerminal = $false
        try {
            if ($null -ne $termCmd) { $isTerminal = [bool](Test-TaskKernelTerminalState -State $tState) }
            else { $isTerminal = (@('DONE', 'EXHAUSTED', 'CANCELLED') -ccontains $tState) }
        }
        catch { $isTerminal = $true }
        if ($isTerminal) {
            return [pscustomobject]@{ ok = $false; reason = 'task-terminal' }
        }
        if ([long](Get-NDValue $task 'revision' -1) -ne [long](Get-NDValue $Intent 'task_expected_revision' 0)) {
            return [pscustomobject]@{ ok = $false; reason = 'task-revision-mismatch' }
        }
        if (([string](Get-NDValue $task 'base_revision' '')) -cne ([string](Get-NDValue $Intent 'base_revision' ''))) {
            return [pscustomobject]@{ ok = $false; reason = 'base-revision-mismatch' }
        }
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        if (([string](Get-NDValue $Intent 'owner' '')) -cne $authOwner) {
            return [pscustomobject]@{ ok = $false; reason = 'owner-mismatch' }
        }
        if ([long](Get-NDValue $Intent 'ownership_generation' 0) -ne $authGen) {
            return [pscustomobject]@{ ok = $false; reason = 'generation-mismatch' }
        }
        if (([string](Get-NDValue $task 'current_owner' '')) -cne $authOwner) {
            return [pscustomobject]@{ ok = $false; reason = 'task-owner-mismatch' }
        }
        if ($null -eq $Goal) {
            return [pscustomobject]@{ ok = $false; reason = 'goal-unavailable' }
        }
        $inActive = $false
        $inCompleted = $false
        try {
            foreach ($t in @((Get-NDValue $Goal 'active_tasks' @()))) {
                if ($tid -ceq ([string]$t)) { $inActive = $true; break }
            }
            foreach ($t in @((Get-NDValue $Goal 'completed_tasks' @()))) {
                if ($tid -ceq ([string]$t)) { $inCompleted = $true; break }
            }
        }
        catch { return [pscustomobject]@{ ok = $false; reason = 'goal-unavailable' } }
        if ($inCompleted) {
            return [pscustomobject]@{ ok = $false; reason = 'task-already-completed' }
        }
        if (-not $inActive) {
            return [pscustomobject]@{ ok = $false; reason = 'task-not-in-goal' }
        }
        $granted = @()
        try {
            $granted = @(@((Get-NDValue $task 'read_scopes' @())) + @((Get-NDValue $task 'write_scopes' @())))
        }
        catch { $granted = @() }
        foreach ($s in @((Get-NDValue $Intent 'scope' @()))) {
            $needle = ([string]$s)
            $found = $false
            foreach ($g in @($granted)) {
                if ($needle -ceq ([string]$g)) { $found = $true; break }
            }
            if (-not $found) {
                return [pscustomobject]@{ ok = $false; reason = 'scope-not-granted' }
            }
        }
        $allowedAgents = @((Get-NDValue $Authorization 'allowed_agents' @()))
        if (@($allowedAgents).Count -gt 0) {
            $agent = ([string](Get-NDValue $Intent 'agent' ''))
            $aFound = $false
            foreach ($a in @($allowedAgents)) {
                if ($agent -ceq ([string]$a)) { $aFound = $true; break }
            }
            if (-not $aFound) {
                return [pscustomobject]@{ ok = $false; reason = 'agent-not-granted' }
            }
        }
        $allowedScopes = @((Get-NDValue $Authorization 'allowed_scopes' @()))
        if (@($allowedScopes).Count -gt 0) {
            foreach ($s in @((Get-NDValue $Intent 'scope' @()))) {
                $needle = ([string]$s)
                $sFound = $false
                foreach ($g in @($allowedScopes)) {
                    if ($needle -ceq ([string]$g)) { $sFound = $true; break }
                }
                if (-not $sFound) {
                    return [pscustomobject]@{ ok = $false; reason = 'scope-not-granted' }
                }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'admission-internal-error' }
    }
}

function Test-NDPostLockFencing {
    <#
    .SYNOPSIS
        Re-checagem de fencing IMEDIATAMENTE antes do efeito (F2).
    .DESCRIPTION
        Rele o goal vivo do store sob o lock do recibo e exige: goal
        legivel, estado exatamente ACTIVE e fencing owner+generation com
        lease valido. Takeover, lease expirado ou saida de ACTIVE recusa
        sem executar. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$Owner = '', [long]$Generation = 0, [string]$GoalStoreDir = '')
    try {
        $gid = ([string]$GoalId).Trim()
        $own = ([string]$Owner).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($own) -or ([long]$Generation -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'post-lock-invalid-token' }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            return [pscustomobject]@{ ok = $false; reason = 'post-lock-check-unavailable' }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            $why = 'post-lock-goal-unreadable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $slot 'reason' ''))) { $why = ('post-lock-goal-unreadable:' + [string](Get-NDValue $slot 'reason' '')) } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why }
        }
        $goal = Get-NDValue $slot 'goal' $null
        $state = ''
        try { $state = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $state = '' }
        if ($state -cne 'ACTIVE') {
            return [pscustomobject]@{ ok = $false; reason = ('post-lock-goal-not-active:' + $state) }
        }
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $own -Generation ([long]$Generation) }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            $why = 'post-lock-fencing-changed'
            try { if (($null -ne $chk) -and (-not [string]::IsNullOrWhiteSpace([string](Get-NDValue $chk 'reason' '')))) { $why = ('post-lock-fencing-changed:' + [string](Get-NDValue $chk 'reason' '')) } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'post-lock-internal-error' }
    }
}

function Test-NDReconcileKernelProof {
    <#
    .SYNOPSIS
        Prova kernel-side vinculada para reconciliacao de sucesso (R3 + FIX3-S1). Fail-closed.
    .DESCRIPTION
        Sucesso reconciliado exige prova VINCULADA, nunca booleans
        declarados no Outcome e nunca artefatos alheios:
          (a) o worker_result persistido no kernel para a task existe e
              tem status + claimed_evidence iguais (campo a campo) ao
              resultado declarado no Outcome; transicao de revisao sem
              worker-result nao satisfaz;
          (b) a evidencia existe no store E esta vinculada a task/key do
              recibo: evidence.task_id confere com a task do recibo
              (provenance.kernel_task_ref confere quando legivel - o
              store redige padroes de segredo), e run_id ou
              source_fingerprints['dispatch-intent'] confere com a
              idempotency_key ou o fingerprint do recibo; evidencia de
              outro despacho nao satisfaz.
        Outcome inventado com artefatos alheios e recusado com razao
        explicita. Quando aceita, devolve os valores kernel-side
        (worker_status / worker_claimed_evidence) para o chamador
        persistir a verdade do kernel, nunca copiar o declarado sem
        comparacao. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [long]$ExpectedRevision = 0,
        [string]$EvidenceId = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$EvidenceStoreDir = '',
        [string]$RepoRoot = '',
        [string]$DeclaredStatus = '',
        [string[]]$DeclaredClaimedEvidence = @(),
        [string]$IdempotencyKey = '',
        [string]$IntentFingerprint = ''
    )
    try {
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid) -or ([long]$ExpectedRevision -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        # FIX3-S1: sem o resultado declarado e o vinculo do recibo nao
        # ha como comparar campo a campo; recusa fail-closed.
        $decStatus = ([string]$DeclaredStatus).Trim().ToLowerInvariant()
        if (@('candidate_pass', 'failed', 'blocked') -cnotcontains $decStatus) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        $fp = ([string]$IntentFingerprint).Trim().ToLowerInvariant()
        if (($key -cnotmatch '^[a-f0-9]{32}$') -or ($fp -cnotmatch '^[a-f0-9]{32}$')) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        $isErr = $false
        try {
            if ($task -is [System.Collections.IDictionary]) { $isErr = $task.Contains('error') }
            else { $isErr = ($null -ne $task.PSObject.Properties['error']) }
        }
        catch { $isErr = $true }
        if ($isErr) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        if ([long](Get-NDValue $task 'revision' -1) -le [long]$ExpectedRevision) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
        }
        # (a) worker_result kernel-side existe e confere campo a campo
        # com o declarado. Revisao avancada por outra via (p.ex.
        # verification) sem worker-result nao satisfaz.
        $kwr = Get-NDValue $task 'worker_result' $null
        if ($null -eq $kwr) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-missing' }
        }
        $kStatus = ([string](Get-NDValue $kwr 'status' '')).Trim().ToLowerInvariant()
        if ($kStatus -cne $decStatus) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
        }
        foreach ($r in @($DeclaredClaimedEvidence)) {
            if (-not (Test-NDCriterionRef $r)) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-unverifiable' }
            }
        }
        $kSorted = @(Get-NDSortedOrdinal -Items @((Get-NDValue $kwr 'claimed_evidence' @())))
        $dSorted = @(Get-NDSortedOrdinal -Items @($DeclaredClaimedEvidence))
        if (@($kSorted).Count -ne @($dSorted).Count) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
        }
        for ($i = 0; $i -lt @($kSorted).Count; $i++) {
            if (([string]$kSorted[$i]) -cne ([string]$dSorted[$i])) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-worker-result-mismatch' }
            }
        }
        # (b) evidencia vinculada a task/key do recibo, nunca alheia.
        $eid = ([string]$EvidenceId).Trim().ToLowerInvariant()
        if ($eid -cnotmatch '^[a-f0-9]{32}$') {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        $evDir = ([string]$EvidenceStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($evDir)) {
            $evDirCmd = Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue
            if ($null -eq $evDirCmd) {
                return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
            }
            try { $evDir = ([string](Get-OrchestrationEvidenceDefaultStoreDir)) }
            catch { $evDir = '' }
        }
        if ([string]::IsNullOrWhiteSpace($evDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
        }
        $evPath = Join-Path $evDir ($eid + '.json')
        if (-not (Test-Path -LiteralPath $evPath -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        $ev = $null
        try { $ev = ConvertFrom-Json ([IO.File]::ReadAllText($evPath, [Text.Encoding]::UTF8)) }
        catch { $ev = $null }
        if ($null -eq $ev) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-missing' }
        }
        if (([string](Get-NDValue $ev 'task_id' '')).Trim() -cne $tid) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        # provenance.kernel_task_ref confere quando legivel: o store
        # redige valores com padrao de segredo (p.ex. 'task-' casa
        # 'sk-'), entao ref redigida nao pode exigir igualdade - a
        # task ja esta vinculada por evidence.task_id acima.
        $evProv = Get-NDValue $ev 'provenance' $null
        $evKref = ([string](Get-NDValue $evProv 'kernel_task_ref' '')).Trim()
        if (([string]$evKref -cnotmatch '\[REDACTED') -and ($evKref -cne $tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        $evRun = (([string](Get-NDValue $ev 'run_id' '')).Trim().ToLowerInvariant())
        $evDisp = ''
        try {
            $evSf = Get-NDValue $ev 'source_fingerprints' $null
            if ($evSf -is [System.Collections.IDictionary]) {
                if ($evSf.Contains('dispatch-intent')) { $evDisp = (([string]$evSf['dispatch-intent']).Trim().ToLowerInvariant()) }
            }
            else {
                $pp = $evSf.PSObject.Properties['dispatch-intent']
                if ($null -ne $pp) { $evDisp = (([string]$pp.Value).Trim().ToLowerInvariant()) }
            }
        }
        catch { $evDisp = '' }
        if ((($evRun -cne $key) -and ($evDisp -cne $key)) -and ($evDisp -cne $fp)) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-evidence-unbound' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; worker_status = $kStatus; worker_claimed_evidence = [string[]]$kSorted }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'reconcile-verify-unavailable' }
    }
}

function Test-NDDuplicateReadIdentity {
    <#
    .SYNOPSIS
        Vincula a leitura idempotente de recibo settled a Authorization (FIX3-S2). Fail-closed, sem vazar.
    .DESCRIPTION
        Antes de devolver o resultado de um recibo settled, confere a
        identidade da Authorization contra a identidade persistida no
        recibo (goal/owner/generation + task pertence ao goal, mesmo
        padrao do Confirm):
          - goal_id divergente (cross-goal) sempre recusa;
          - goal nao-ACTIVE recusa em TODOS os caminhos (R2);
          - mesma identidade (goal/owner/generation) SO permite a leitura
            se essa ownership ainda e a viva ATUAL (owner+geracao+lease
            conferidos no goal relido sob o lock) (R2);
          - takeover (mesmo goal, owner/generation novos com ownership
            viva + worker_result kernel-side presente e igual campo a
            campo ao do recibo) permite a leitura com prova.
        Sem prova ou com ownership stale, recusa. O veredito nunca inclui
        conteudo do recibo: recusas usam uma razao unica e nao revelam
        worker_result nem evidence_id. Nenhuma ampliacao de autoridade:
        leitura do resultado ja persistido para o dono vivo do mesmo
        goal. Os campos de identidade (goal_id, task_id, owner,
        ownership_generation) sao lidos como TOKENS CRUS do registro
        (sem pipeline/coercao): array de um elemento, booleano ou
        fracionario recusa. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null, $Authorization = $null, [string]$GoalStoreDir = '', [string]$TasksDir = '', [string]$RepoRoot = '')
    try {
        if (($null -eq $Receipt) -or ($null -eq $Authorization)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        # Identidade do registro: TOKENS CRUS lidos direto da
        # propriedade. `task_id:["..."]`, `goal_id:[...]` ou
        # `ownership_generation:[1]` chegariam como escalar pela leitura
        # por pipeline + coercao [string]/[long] e satisfariam a
        # comparacao sem que o token original fosse o campo esperado.
        # Fail-closed: token de tipo errado recusa.
        $recGoalTok = Get-NDJsonStringValue -Object $Receipt -Name 'goal_id'
        if ($null -eq $recGoalTok) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recGoal = ([string]$recGoalTok).Trim()
        $authGoal = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($recGoal) -or ($recGoal -cne $authGoal)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recTaskTok = Get-NDJsonStringValue -Object $Receipt -Name 'task_id'
        if ($null -eq $recTaskTok) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recTask = ([string]$recTaskTok).Trim()
        if ([string]::IsNullOrWhiteSpace($recTask)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $goalCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        $ownCmd = Get-Command Test-OrchestrationGoalOwnership -ErrorAction SilentlyContinue
        if (($null -eq $goalCmd) -or ($null -eq $ownCmd)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $recGoal -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-NDValue $slot 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $goal = Get-NDValue $slot 'goal' $null
        if ($null -eq $goal) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $inGoal = $false
        try {
            foreach ($t in @((Get-NDValue $goal 'active_tasks' @()))) {
                if ($recTask -ceq ([string]$t)) { $inGoal = $true; break }
            }
            if (-not $inGoal) {
                foreach ($t in @((Get-NDValue $goal 'completed_tasks' @()))) {
                    if ($recTask -ceq ([string]$t)) { $inGoal = $true; break }
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        if (-not $inGoal) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recOwnerTok = Get-NDJsonStringValue -Object $Receipt -Name 'owner'
        if ($null -eq $recOwnerTok) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recOwner = ([string]$recOwnerTok).Trim()
        $recGenTok = Get-NDJsonIntegralLong -Object $Receipt -Name 'ownership_generation'
        if ($null -eq $recGenTok) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $recGen = [long]$recGenTok
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        if (([string]::IsNullOrWhiteSpace($recOwner)) -or ([string]::IsNullOrWhiteSpace($authOwner)) -or ($recGen -lt 1) -or ($authGen -lt 1)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        # R2 (REV4): a autorizacao acontece ANTES do lock do recibo. Sem
        # esta releitura da ownership VIVA, um token aceito no gate
        # poderia devolver o resultado de um recibo cujo goal mudou de
        # dono (takeover/expiracao) ou saiu de ACTIVE entre a autorizacao
        # e a aquisicao do lock. Goal nao-ACTIVE recusa em TODOS os
        # caminhos; o caminho direto ainda exige que o dono do recibo
        # seja o dono vivo ATUAL (owner+geracao+lease). Mismatch recusa
        # sem conteudo.
        $liveState = ''
        try { $liveState = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $liveState = '' }
        if ($liveState -cne 'ACTIVE') {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        if (($recOwner -ceq $authOwner) -and ($recGen -eq $authGen)) {
            $liveChk = $null
            try { $liveChk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $recOwner -Generation $recGen }
            catch { $liveChk = $null }
            if (($null -eq $liveChk) -or (-not [bool](Get-NDValue $liveChk 'ok' $false)) -or (-not [bool](Get-NDValue $liveChk 'held' $false))) {
                return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; takeover = $false }
        }
        # Takeover: novo owner vivo do mesmo goal + prova kernel-side de
        # que o worker_result do recibo corresponde a verdade do kernel.
        $chk = $null
        try { $chk = Test-OrchestrationGoalOwnership -Goal $goal -OwnerId $authOwner -Generation $authGen }
        catch { $chk = $null }
        if (($null -eq $chk) -or (-not [bool](Get-NDValue $chk 'ok' $false)) -or (-not [bool](Get-NDValue $chk 'held' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $recTask -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $isErr = $false
        try {
            if ($task -is [System.Collections.IDictionary]) { $isErr = $task.Contains('error') }
            else { $isErr = ($null -ne $task.PSObject.Properties['error']) }
        }
        catch { $isErr = $true }
        if ($isErr) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $kwr = Get-NDValue $task 'worker_result' $null
        $swr = Get-NDValue $Receipt 'worker_result' $null
        if (($null -eq $kwr) -or ($null -eq $swr)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $ks = ([string](Get-NDValue $kwr 'status' '')).Trim().ToLowerInvariant()
        $ss = ([string](Get-NDValue $swr 'status' '')).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($ks) -or ($ks -cne $ss)) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        $kc = @(Get-NDSortedOrdinal -Items @((Get-NDValue $kwr 'claimed_evidence' @())))
        $sc = @(Get-NDSortedOrdinal -Items @((Get-NDValue $swr 'claimed_evidence' @())))
        if (@($kc).Count -ne @($sc).Count) {
            return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
        }
        for ($i = 0; $i -lt @($kc).Count; $i++) {
            if (([string]$kc[$i]) -cne ([string]$sc[$i])) {
                return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; takeover = $true }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'duplicate-identity-mismatch'; takeover = $false }
    }
}

function Test-NDReconcileLiveOwnership {
    <#
    .SYNOPSIS
        Ownership viva sob o lock, imediatamente antes de liquidar (F4/REV5).
    .DESCRIPTION
        A autorizacao e conferida ANTES de adquirir o lock do recibo. Sem
        esta releitura, um token aceito no gate poderia liquidar um recibo
        pending cuja ownership deixou de valer durante a espera (lease
        expirada, goal fora de ACTIVE, tomada de posso por outro dono).
        Confere a identidade da Authorization apresentada contra o goal
        relido agora: se ela nao e mais a viva ATUAL, recusa e o recibo
        fica pending (sem liquidacao). Nunca amplia autoridade: so a
        authorization que continua viva liquida. Nunca lanca.

        DELIMITACAO DO CLAIM (SEC6/REV6 - honestidade de contrato, sem
        mudanca de comportamento): o que esta funcao PROVA e takeover
        OCORRIDO ANTES da releitura (expiracao de lease ou tomada de
        posse acontecida antes desta chamada, inclusive durante a espera
        pelo lock do recibo). O que ela NAO prova:
          - a sequencia releitura -> persistencia do recibo NAO e atomica.
            Ha janela residual entre esta revalidacao e o Write-NDReceipt
            seguinte; um takeover que aconteca DEPOIS da releitura liquida
            com a autorizacao ja validada;
          - o lock do recibo NAO serializa mutacao do goal. Ele serializa
            apenas acesso ao arquivo do recibo; a escrita do goal
            (ownership/lease) segue caminho proprio, sem lock compartilhado.
        Nao ha alegacao de serializacao cross-recurso nem de atomicidade.
        A trilha de auditoria existe (reconciled_by/reconciled_generation
        no recibo) para revisar liquidacoes feitas dentro da janela.
    #>
    [CmdletBinding()]
    param($Authorization = $null, [string]$GoalStoreDir = '')
    try {
        if ($null -eq $Authorization) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-ownership-stale' }
        }
        $gid = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $own = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $gen = [long](Get-NDValue $Authorization 'generation' 0)
        $live = $null
        try { $live = Test-NDPostLockFencing -GoalId $gid -Owner $own -Generation $gen -GoalStoreDir $GoalStoreDir }
        catch { $live = $null }
        if (($null -eq $live) -or (-not [bool](Get-NDValue $live 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-ownership-stale' }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'reconcile-ownership-stale' }
    }
}

function Confirm-OrchestrationDispatchReconciliation {
    <#
    .SYNOPSIS
        Reconciliacao externa explicita de recibo pending (F3+R3). Sem efeito.
    .DESCRIPTION
        Converte um recibo `pending` em `settled` a partir de verificacao
        externa do chamador autorizado (que apurou por fora se o efeito
        ocorreu). Exige Authorization admitida viva; nunca invoca o
        Executor (0 calls por construcao). Falha ao persistir e erro
        explicito, nunca silencioso. Nunca lanca.

        R3: a Authorization e conferida contra a identidade persistida no
        recibo sob lock (goal_id/owner/generation iguais ao despacho
        original). SUCESSO
        (Outcome.ok=$true) so e registrado com prova vinculada
        kernel-side (worker_result persistido no kernel com status/refs
        iguais ao declarado + evidencia vinculada a task/key do recibo);
        booleans declarados no Outcome nunca sao
        prova, e outcome inventado e recusado. FALHA externa apurada
        (Outcome.ok=$false) pode liquidar como falha, sem alegar sucesso.

        F3/REV5: os recibos sao isolados por goal. O Confirm de um goal
        resolve o caminho do PROPRIO goal, portanto nunca enxerga o recibo
        de outro: a resposta para recibo alheio e `receipt-not-found`,
        generica, igual a de key inexistente. Nao ha oraculo de existencia
        entre goals.

        F4/REV5: a ownership viva e RELIDA sob o lock imediatamente antes
        de qualquer persisticao (sucesso e falha). Expiracao de lease ou
        tomada de posso durante a espera pelo lock recusa com
        `reconcile-ownership-stale` e deixa o recibo `pending`.
        DELIMITACAO (SEC6/REV6): a releitura cobre takeover OCORRIDO
        ANTES dela. A sequencia releitura -> persistencia nao e atomica
        (janela residual) e o lock do recibo nao serializa mutacao do
        goal - detalhe em Test-NDReconcileLiveOwnership.
        Reconciliacao apos takeover: um novo owner (generation maior, com
        autorizacao viva do goal atual) pode reconciliar SOMENTE com prova
        kernel-side + autorizacao viva; sem prova, a divergencia de
        identidade recusa. O reconciliador fica registrado no recibo
        (reconciled_by/reconciled_generation).
    #>
    [CmdletBinding()]
    param(
        [string]$IdempotencyKey = '',
        $Outcome = $null,
        $Authorization = $null,
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$EvidenceStoreDir = '',
        [int]$LockTimeoutMs = 60000
    )
    try {
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-idempotency-key' -ExecutorCalls 0)
        }
        if ($null -eq $Outcome) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'outcome-missing' -ExecutorCalls 0)
        }
        $outOk = Get-NDValue $Outcome 'ok' $null
        if (($null -eq $outOk) -or ($outOk -isnot [bool])) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'outcome-invalid' -ExecutorCalls 0)
        }
        $outWorker = Get-NDValue $Outcome 'worker_result' $null
        if ([bool]$outOk) {
            # R3: sucesso exige worker_result presente com forma valida;
            # a prova kernel-side vem depois, sob lock, contra o recibo.
            if ($null -eq $outWorker) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-outcome-shape' -ExecutorCalls 0)
            }
            $shape = Test-OrchestrationDispatchResultShape -Result $outWorker
            if (-not [bool](Get-NDValue $shape 'ok' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'invalid-outcome-shape' -ExecutorCalls 0)
            }
        }
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -ExecutorCalls 0)
        }
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -ExecutorCalls 0)
        }
        # F3/REV5: recibos isolados pela identidade autorizada. Confirm de
        # um goal nunca enxerga o recibo de outro: o caminho do goal
        # autorizado nao contem a key e a resposta e receipt-not-found
        # (generico), igual a de uma key inexistente.
        # REV6/SEC6: `receipt-dir-reparse-point` recusa quando o
        # subdiretorio do goal e um link (ler/gravar sairia do destino).
        # REV7/R1 (S1): `created_utc` do envelope carrega a identidade
        # capturada na resolucao; cada IO abaixo reasserta antes de tocar
        # no alvo (defesa em profundidade contra namespace trocado).
        $rState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId (([string](Get-NDValue $Authorization 'goal_id' '')).Trim())
        $rDir = [string](Get-NDValue $rState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($rDir)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $rState 'reason' 'receipt-dir-unresolvable')) -Admitted $true -ExecutorCalls 0)
        }
        $rIdent = [string](Get-NDValue $rState 'created_utc' '')
        $idWhy = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
        if (-not [string]::IsNullOrWhiteSpace($idWhy)) {
            return (New-NDDispatchEnvelope -Ok $false -Reason $idWhy -Admitted $true -ExecutorCalls 0)
        }
        # REV8/F1 (S1): motivo explicito da recusa do lock. Sem motivo a
        # recusa e contencao real (lock-busy); com motivo, o lock foi
        # recusado por identidade/namespace trocado DURANTE a espera e o
        # envelope carrega a razao honesta em vez de simular ocupacao.
        $lockWhy = ''
        $lock = Open-NDReceiptLock -Dir $rDir -LockTimeoutMs $LockTimeoutMs -Expected $rIdent -RefusalReason ([ref]$lockWhy)
        if ($null -eq $lock) {
            return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $lockWhy -Fallback 'lock-busy') -Admitted $true -ExecutorCalls 0)
        }
        try {
            $read = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent
            if (-not [bool](Get-NDValue $read 'ok' $false)) {
                # R3: ausencia comprovada -> receipt-not-found; recibo
                # ilegivel/invalido recusa com a razao explicita e sem
                # sobrescrever o arquivo.
                $readWhy = ([string](Get-NDValue $read 'reason' 'receipt-unreadable'))
                if ($readWhy -ceq 'receipt-absent') { $readWhy = 'receipt-not-found' }
                return (New-NDDispatchEnvelope -Ok $false -Reason $readWhy -Admitted $true -ExecutorCalls 0)
            }
            $existing = Get-NDValue $read 'receipt' $null
            if ($null -eq $existing) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-not-found' -Admitted $true -ExecutorCalls 0)
            }
            if ([string](Get-NDValue $existing 'phase' '') -ceq 'settled') {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'already-settled' -Admitted $true -ExecutorCalls 0)
            }
            if ([string](Get-NDValue $existing 'phase' '') -cne 'pending') {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-invalid' -Admitted $true -ExecutorCalls 0)
            }
            # R3: identidade do recibo contra a Authorization viva.
            $recGoal = ([string](Get-NDValue $existing 'goal_id' '')).Trim()
            $authGoal = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($recGoal) -or ($recGoal -cne $authGoal)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'reconcile-identity-mismatch' -Admitted $true -ExecutorCalls 0)
            }
            $recOwner = ([string](Get-NDValue $existing 'owner' '')).Trim()
            $recGen = [long](Get-NDValue $existing 'ownership_generation' 0)
            $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
            $authGen = [long](Get-NDValue $Authorization 'generation' 0)
            $takeover = (($recOwner -cne $authOwner) -or ($recGen -ne $authGen))
            $recTask = ([string](Get-NDValue $existing 'task_id' ''))
            $recRev = [long](Get-NDValue $existing 'task_expected_revision' 0)
            $fp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
            $wOut = $null
            if ($null -ne $outWorker) {
                $wOut = [pscustomobject][ordered]@{
                    status = ([string](Get-NDValue $outWorker 'status' ''))
                    claimed_evidence = [string[]]@((Get-NDValue $outWorker 'claimed_evidence' @()))
                }
            }
            if ([bool]$outOk) {
                # R3 + FIX3-S1: sucesso so com prova kernel-side VINCULADA;
                # vale para o owner original e para takeover com
                # autorizacao viva (admitida acima). Sem prova, recusa -
                # inclusive quando a identidade diverge (takeover sem
                # prova). O recibo settled persiste os valores lidos do
                # kernel pela prova, nunca copia o declarado sem
                # comparacao campo a campo.
                $evId = ([string](Get-NDValue $Outcome 'evidence_id' '')).Trim().ToLowerInvariant()
                $proof = Test-NDReconcileKernelProof -TaskId $recTask -ExpectedRevision $recRev -EvidenceId $evId -TasksDir $TasksDir -FlagsPath $FlagsPath -EvidenceStoreDir $EvidenceStoreDir -RepoRoot $RepoRoot -DeclaredStatus ([string](Get-NDValue $outWorker 'status' '')) -DeclaredClaimedEvidence @((Get-NDValue $outWorker 'claimed_evidence' @())) -IdempotencyKey $key -IntentFingerprint $fp
                if (-not [bool](Get-NDValue $proof 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $proof 'reason' 'reconcile-unverifiable')) -Admitted $true -ExecutorCalls 0)
                }
                $wOut = [pscustomobject][ordered]@{
                    status = ([string](Get-NDValue $proof 'worker_status' ''))
                    claimed_evidence = [string[]]@((Get-NDValue $proof 'worker_claimed_evidence' @()))
                }
                $settled = [ordered]@{
                    schema_version = 1; idempotency_key = $key; phase = 'settled'
                    ok = $true; reason = ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally'))
                    task_id = $recTask
                    agent = ([string](Get-NDValue $existing 'agent' ''))
                    owner = $recOwner
                    goal_id = $recGoal
                    ownership_generation = $recGen
                    task_expected_revision = $recRev
                    intent_fingerprint = $fp
                    reconciled = $true
                    reconciled_by = $authOwner
                    reconciled_generation = $authGen
                    worker_result = $wOut
                    kernel_ok = $true
                    kernel_reason = 'reconciled-kernel-verified'
                    evidence_created = $true
                    evidence_id = $evId
                    settled_at = ([DateTime]::UtcNow.ToString('o'))
                }
                # F4/REV5: ownership VIVA revalidada sob o lock,
                # imediatamente antes de liquidar o SUCESSO. Expiracao de
                # lease ou tomada de posse durante a espera pelo lock
                # recusa sem liquidar; o recibo permanece pending.
                $liveOwn = Test-NDReconcileLiveOwnership -Authorization $Authorization -GoalStoreDir $GoalStoreDir
                if (-not [bool](Get-NDValue $liveOwn 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $liveOwn 'reason' 'reconcile-ownership-stale')) -Admitted $true -ExecutorCalls 0)
                }
                # REV7/R1 (S1): identidade do diretorio reassertada
                # imediatamente antes da escrita.
                $idWhyOk = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                if (-not [string]::IsNullOrWhiteSpace($idWhyOk)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyOk -Admitted $true -ExecutorCalls 0)
                }
                # REV8/F2 (S1): motivo explicito da recusa de escrita.
                $writeWhy = ''
                if (-not (Write-NDReceipt -Dir $rDir -Receipt $settled -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -Admitted $true -ExecutorCalls 0)
                }
                return (New-NDDispatchEnvelope -Ok $true -Reason ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally')) -Admitted $true -Reconciled $true -ExecutorCalls 0 -WorkerResult $wOut -KernelOk $true -KernelReason 'reconciled-kernel-verified' -EvidenceCreated $true -EvidenceId $evId)
            }
            $settled = [ordered]@{
                schema_version = 1; idempotency_key = $key; phase = 'settled'
                ok = $false; reason = ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally'))
                task_id = $recTask
                agent = ([string](Get-NDValue $existing 'agent' ''))
                owner = $recOwner
                goal_id = $recGoal
                ownership_generation = $recGen
                task_expected_revision = $recRev
                intent_fingerprint = $fp
                reconciled = $true
                reconciled_by = $authOwner
                reconciled_generation = $authGen
                worker_result = $wOut
                kernel_ok = $false
                kernel_reason = ([string](Get-NDValue $Outcome 'kernel_reason' 'reconciled-external-failure'))
                evidence_created = [bool](Get-NDValue $Outcome 'evidence_created' $false)
                evidence_id = ([string](Get-NDValue $Outcome 'evidence_id' ''))
                settled_at = ([DateTime]::UtcNow.ToString('o'))
            }
            # F4/REV5: a MESMA revalidacao de ownership viva sob o lock
            # no caminho de FALHA. Liquidar uma falha externa tambem e
            # mutacao do recibo e exige autorizacao ainda viva.
            $liveOwn2 = Test-NDReconcileLiveOwnership -Authorization $Authorization -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $liveOwn2 'ok' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $liveOwn2 'reason' 'reconcile-ownership-stale')) -Admitted $true -ExecutorCalls 0)
            }
            # REV7/R1 (S1): identidade do diretorio reassertada
            # imediatamente antes da escrita (caminho de falha tambem
            # muta o recibo).
            $idWhyFail = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyFail)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyFail -Admitted $true -ExecutorCalls 0)
            }
            # REV8/F2 (S1): motivo explicito da recusa de escrita.
            $writeWhy = ''
            if (-not (Write-NDReceipt -Dir $rDir -Receipt $settled -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -Admitted $true -ExecutorCalls 0)
            }
            return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $Outcome 'reason' 'reconciled-externally')) -Admitted $true -Reconciled $true -ExecutorCalls 0 -WorkerResult $wOut -KernelOk $false -KernelReason ([string](Get-NDValue $Outcome 'kernel_reason' 'reconciled-external-failure')) -EvidenceCreated ([bool](Get-NDValue $Outcome 'evidence_created' $false)) -EvidenceId ([string](Get-NDValue $Outcome 'evidence_id' '')))
        }
        finally { try { $lock.Dispose() } catch { } }
    }
    catch {
        return (New-NDDispatchEnvelope -Ok $false -Reason 'reconcile-internal-error' -ExecutorCalls 0)
    }
}

function New-NDDispatchEnvelope {
    param([bool]$Ok = $false, [string]$Reason = '', [bool]$Admitted = $false, [bool]$Duplicate = $false, [bool]$Reconciled = $false, [int]$ExecutorCalls = 0, $Intent = $null, $WorkerResult = $null, [bool]$KernelOk = $false, [string]$KernelReason = '', [bool]$EvidenceCreated = $false, [string]$EvidenceId = '')
    return [pscustomobject][ordered]@{
        ok              = [bool]$Ok
        reason          = ([string]$Reason)
        admitted        = [bool]$Admitted
        duplicate       = [bool]$Duplicate
        reconciled      = [bool]$Reconciled
        executor_calls  = [int]$ExecutorCalls
        intent          = $Intent
        worker_result   = $WorkerResult
        kernel_ok       = [bool]$KernelOk
        kernel_reason   = ([string]$KernelReason)
        evidence_created = [bool]$EvidenceCreated
        evidence_id     = ([string]$EvidenceId)
    }
}

function Invoke-OrchestrationNativeDispatch {
    <#
    .SYNOPSIS
        Despacha UM worker via Executor injetado, com recibo idempotente.
    .DESCRIPTION
        Ordem fixa: (a) autorizacao -> (b) admissao viva do kernel (F1:
        task existe e nao-terminal, pertence ao goal, revisoes/fencing/
        grants conferem; divergencia recusa com 0 calls) -> (c) lock de
        TASK na raiz dos recibos (F2: exclusao de efeito por task,
        compartilhada com o CLAIM; sempre ANTES do lock do recibo, ordem
        unica task -> recibo, mantido sobre todo o despacho inclusive o
        Executor) -> (c2) lock do recibo -> (d) leitura do recibo (R3:
        ausencia COMPROVADA segue
        para dispatch novo; recibo ilegivel/invalido recusa com razao
        explicita, sem sobrescrever e sem efeito; F2/REV5: entrada
        nao-arquivo no caminho recusa 'receipt-not-regular'; F1/REV5: a
        fase vem canonicalizada) -> (e) duplicata
        settled: IDENTIDADE antes do fingerprint (R4/SEC4: razao unica
        'duplicate-identity-mismatch' para "existe e nao e utilizavel",
        sem oraculo de existencia, sem worker_result/evidence_id) ->
        (f) pending ambiguo (F3: sem replay automatico; exige
        reconciliacao externa ou flag external_idempotent com prova) ->
        (g) recibo pending -> (f3) admissao viva do efeito novo/replay e
        exclusao de efeito por task (`Test-NDTaskEffectExclusive`: recusa
        `claim-task-already-claimed` enquanto existir recibo
        nao-resolvido da MESMA task em QUALQUER goal/chave/revisao sob a
        mesma raiz; excecao somente para o arquivo exato desta operacao) ->
        (h) recibo pending persistido -> (i) fencing pos-lock (F2:
        releitura IMEDIATA antes do efeito) -> (j) Executor UMA vez (unico
        ponto de efeito externo) -> (k) validacao de forma -> (l) evidence
        row -> (m) kernel -> (n) recibo settled (falha de persistencia
        = erro explicito).
        F3/REV5: o caminho do recibo e namespaceado pelo goal_id da
        Authorization, sobre o fundo raiz comum. Um Autorizacao de outro
        goal ve AUSENCIA (indistinguivel de key nunca usada) e segue o
        caminho normal de admissao; takeover dentro do MESMO goal
        preservado (namespace so por goal_id).
        O lock de task e o lock de recibo sao mantidos durante todo o
        despacho (o lock de task inclusive sobre o Executor) e soltos na
        ordem inversa. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $Intent = $null,
        $Executor = $null,
        $Authorization = $null,
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000
    )
        try {
            $realIntent = Get-NDValue $Intent 'intent' $null
            if ($null -eq $realIntent) { $realIntent = $Intent }
            $check = New-OrchestrationNativeDispatchIntent `
                -TaskId ([string](Get-NDValue $realIntent 'task_id' '')) `
                -TaskExpectedRevision ([long](Get-NDValue $realIntent 'task_expected_revision' 0)) `
                -Agent ([string](Get-NDValue $realIntent 'agent' '')) `
                -PromptHash ([string](Get-NDValue $realIntent 'prompt_hash' '')) `
                -Scope @((Get-NDValue $realIntent 'scope' @())) `
                -AcceptanceCriteria @((Get-NDValue $realIntent 'acceptance_criteria' @())) `
                -IdempotencyKey ([string](Get-NDValue $realIntent 'idempotency_key' '')) `
                -Owner ([string](Get-NDValue $realIntent 'owner' '')) `
                -OwnershipGeneration ([long](Get-NDValue $realIntent 'ownership_generation' 0)) `
                -BaseRevision ([string](Get-NDValue $realIntent 'base_revision' '')) `
                -ExternalIdempotent ([bool](Get-NDValue $realIntent 'external_idempotent' $false)) `
                -ExternalIdempotencyProof ([string](Get-NDValue $realIntent 'external_idempotency_proof' ''))
            if (-not [bool](Get-NDValue $check 'ok' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $check 'reason' 'invalid-intent')))
            }
            $intent = Get-NDValue $check 'intent' $null
            $key = ([string](Get-NDValue $intent 'idempotency_key' '')).Trim().ToLowerInvariant()
            # R3: identidade completa do despacho, persistida em todo recibo
            # (pending e settled) para vincular reconciliacao a goal/task/
            # owner/generation exatos e permitir prova kernel-side posterior.
            $ndGoalId = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
            $ndOwnerGen = [long](Get-NDValue $intent 'ownership_generation' 0)
            $ndTaskRev = [long](Get-NDValue $intent 'task_expected_revision' 0)
            $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
            if ([string]::IsNullOrWhiteSpace($dir)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
            }
            try {
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                    [void][IO.Directory]::CreateDirectory($dir)
                }
            }
            catch {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
            }
            # F2: identidade da RAIZ dos recibos, usada pelo lock de task e pela
            # varredura de exclusao. '' (creation time ilegivel) degrada para as
            # checagens de existencia/Container/reparse, nunca para confianca.
            $rootIdent = Get-NDDirCreationTimeUtcTicks -Path $dir
            $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
            if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -Intent $intent -ExecutorCalls 0)
            }
            # F3/REV5: recibos isolados pela identidade autorizada. O fundo
            # raiz continua sendo $dir (onde tambem fica o log de ativacao);
            # cada goal le e escreve apenas <dir>/<goal-hash>. Uma autorizacao
            # de outro goal nao ve a key (ausencia indistinguivel) e cai no
            # caminho normal de admissao. Takeover preservado: namespace so
            # por goal_id.
            # REV6/SEC6: `receipt-dir-reparse-point` recusa quando o
            # subdiretorio do goal e um link (ler/gravar sairia do destino).
            # REV7/R1 (S1): `created_utc` carrega a identidade capturada na
            # resolucao; todos os IO abaixo (lock, leitura, escritas)
            # reassertam essa identidade imediatamente antes de tocar no alvo.
            $rState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId $ndGoalId
            $rDir = [string](Get-NDValue $rState 'dir' '')
            if ([string]::IsNullOrWhiteSpace($rDir)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $rState 'reason' 'receipt-dir-unresolvable')) -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            $rIdent = [string](Get-NDValue $rState 'created_utc' '')
            # REV7/R1 (S1): primeira barreira - namespace trocado entre a
            # resolucao e o lock recusa ANTES de qualquer IO no alvo (nem o
            # arquivo de lock chega a ser criado la).
            $idWhyPre = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyPre)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyPre -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            if (($null -eq $Executor) -or ($Executor -isnot [scriptblock])) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'executor-required' -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            $fingerprint = Get-NDIntentFingerprint -Intent $intent
            if ([string]::IsNullOrWhiteSpace($fingerprint)) {
                return (New-NDDispatchEnvelope -Ok $false -Reason 'intent-fingerprint-failed' -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            # F2 (exclusao de efeito por task): lock de task na RAIZ, ANTES do
            # lock do recibo, sempre nesta ordem. Ordem unica e estavel em todos
            # os caminhos (task -> recibo): sem ciclo, e dois processos com
            # chaves/goals diferentes disputam a MESMA exclusao da task.
            $taskLockWhy = ''
            $taskLock = Open-NDTaskLock -RootDir $dir -TaskId ([string](Get-NDValue $intent 'task_id' '')) -LockTimeoutMs $LockTimeoutMs -RootExpected $rootIdent -RefusalReason ([ref]$taskLockWhy)
            if ($null -eq $taskLock) {
                return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $taskLockWhy -Fallback 'task-lock-busy') -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            $lockWhy = ''
            $lock = Open-NDReceiptLock -Dir $rDir -LockTimeoutMs $LockTimeoutMs -Expected $rIdent -RefusalReason ([ref]$lockWhy)
            if ($null -eq $lock) {
                try { $taskLock.Dispose() } catch { }
                return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $lockWhy -Fallback 'lock-busy') -Admitted $true -Intent $intent -ExecutorCalls 0)
            }
            try {
                # REV7/R1 (S1): identidade reassertada depois do lock (o lock
                # e o primeiro IO) e antes da leitura do recibo.
                $idWhyLock = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                if (-not [string]::IsNullOrWhiteSpace($idWhyLock)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyLock -Admitted $true -Intent $intent -ExecutorCalls 0)
                }
                # R3 (REV4): ausencia COMPROVADA (sem arquivo) e o UNICO caso
                # que segue para um dispatch novo. Recibo ilegivel/invalido
                # (JSON truncado, chave divergente, schema/fase desconhecidos)
                # recusa com razao explicita, sem sobrescrever o arquivo e sem
                # chamar o Executor.
                $read = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent
                $existing = $null
                if (-not [bool](Get-NDValue $read 'ok' $false)) {
                    $readWhy = ([string](Get-NDValue $read 'reason' 'receipt-unreadable'))
                    if ($readWhy -cne 'receipt-absent') {
                        return (New-NDDispatchEnvelope -Ok $false -Reason $readWhy -Admitted $true -Intent $intent -ExecutorCalls 0)
                    }
                }
                else {
                    $existing = Get-NDValue $read 'receipt' $null
                }
                if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'settled')) {
                    # R4/SEC4: IDENTIDADE antes do fingerprint, e uma UNICA
                    # razao de recusa para "existe um recibo que este chamador
                    # nao pode usar". Assim o envelope nao revela se a key
                    # existe nem se o recibo e do proprio chamador (sem oraculo
                    # de existencia cross-goal), e nunca carrega
                    # worker_result/evidence_id.
                    $storedFp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
                    $fpOk = ((-not [string]::IsNullOrWhiteSpace($storedFp)) -and ($storedFp -ceq $fingerprint))
                    $dupId = Test-NDDuplicateReadIdentity -Receipt $existing -Authorization $Authorization -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -RepoRoot $RepoRoot
                    $identityOk = [bool](Get-NDValue $dupId 'ok' $false)
                    if ((-not $identityOk) -or (-not $fpOk)) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason 'duplicate-identity-mismatch' -Admitted $true -Intent $intent -ExecutorCalls 0)
                    }
                    $dupReason = 'idempotent-duplicate'
                    if ([bool](Get-NDValue $dupId 'takeover' $false)) { $dupReason = 'idempotent-duplicate-takeover' }
                    return (New-NDDispatchEnvelope -Ok ([bool](Get-NDValue $existing 'ok' $false)) -Reason $dupReason -Admitted $true -Duplicate $true -ExecutorCalls 0 -Intent $intent -WorkerResult (Get-NDValue $existing 'worker_result' $null) -KernelOk ([bool](Get-NDValue $existing 'kernel_ok' $false)) -KernelReason ([string](Get-NDValue $existing 'kernel_reason' '')) -EvidenceCreated ([bool](Get-NDValue $existing 'evidence_created' $false)) -EvidenceId ([string](Get-NDValue $existing 'evidence_id' '')))
                }
                $reconciled = $false
                if (($null -ne $existing) -and ([string](Get-NDValue $existing 'phase' '') -ceq 'pending')) {
                    $storedFp = ([string](Get-NDValue $existing 'intent_fingerprint' ''))
                    # R4/SEC4: mesma razao unica do caminho settled para
                    # "recibo existente nao utilizavel por este chamador".
                    if ([string]::IsNullOrWhiteSpace($storedFp) -or ($storedFp -cne $fingerprint)) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason 'duplicate-identity-mismatch' -Admitted $true -Intent $intent -ExecutorCalls 0)
                    }
                    # R2: replay de pending consulta a declaracao ORIGINAL
                    # persistida no recibo, nao a do novo Intent. Upgrade de
                    # idempotencia via novo Intent (adicionar
                    # external_idempotent/proof) muda o fingerprint e cai em
                    # colisao acima; aqui, recibo original sem a declaracao
                    # nunca autoriza replay so porque o reenvio declara.
                    $storedExt = [bool](Get-NDValue $existing 'external_idempotent' $false)
                    $newExt = [bool](Get-NDValue $intent 'external_idempotent' $false)
                    if ((-not $storedExt) -or (-not $newExt)) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason 'pending-ambiguous' -Admitted $true -Intent $intent -ExecutorCalls 0)
                    }
                    $reconciled = $true
                }
                # F1: admissao viva ANTES de qualquer efeito novo. Recibos
                # settled com fingerprint igual retornam acima apos vinculo
                # de identidade com o recibo (FIX3-S2; nenhum efeito novo, a
                # revisao da task avancou de proposito no primeiro dispatch).
                # Replay de pending e efeito novo e passa pela admissao.
                $liveGoal = $null
                try {
                    $gidLive = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
                    $gslot = Get-OrchestrationGoal -GoalId $gidLive -StoreDir $GoalStoreDir
                    if (($null -ne $gslot) -and [bool](Get-NDValue $gslot 'ok' $false)) {
                        $liveGoal = Get-NDValue $gslot 'goal' $null
                    }
                }
                catch { $liveGoal = $null }
                $admit = Test-NDLiveTaskAdmission -Intent $intent -Authorization $Authorization -Goal $liveGoal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
                if (-not [bool](Get-NDValue $admit 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $admit 'reason' 'admission-denied')) -Admitted $true -Reconciled $reconciled -Intent $intent -ExecutorCalls 0)
                }
                # F2 (exclusao de efeito por task): nenhum segundo efeito do
                # legado enquanto existir recibo nao-resolvido ('claimed' do
                # handoff ou 'pending' do legado) da MESMA task em QUALQUER
                # namespace sob a MESMA raiz. A excecao vale somente para o
                # arquivo exato desta operacao (mesmo namespace + mesma chave),
                # o que preserva o replay idempotente do proprio recibo com a
                # prova externa ORIGINAL - sem excecao cross-key/cross-goal.
                # Roda DEPOIS do diagnostico do recibo PROPRIO (R3) e da
                # admissao: a razao de recusa do proprio recibo continua sendo
                # a que o chamador ve, e a reserva so decide quando um efeito
                # novo (ou replay idempotente) realmente vai acontecer.
                $slot = Test-NDTaskEffectExclusive -RootDir $dir -TaskId ([string](Get-NDValue $intent 'task_id' '')) -SkipGoalId $ndGoalId -SkipKey $key -RootExpected $rootIdent
                if (-not [bool](Get-NDValue $slot 'ok' $false)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $slot 'reason' 'claim-task-already-claimed')) -Admitted $true -Reconciled $reconciled -Intent $intent -ExecutorCalls 0)
                }
                $pending = [ordered]@{
                    schema_version  = 1
                    idempotency_key = $key
                    phase           = 'pending'
                    task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                    agent           = ([string](Get-NDValue $intent 'agent' ''))
                    owner           = ([string](Get-NDValue $intent 'owner' ''))
                    goal_id         = $ndGoalId
                    ownership_generation = $ndOwnerGen
                    task_expected_revision = $ndTaskRev
                    intent_fingerprint = $fingerprint
                    external_idempotent = [bool](Get-NDValue $intent 'external_idempotent' $false)
                    reconciled      = [bool]$reconciled
                    created_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                # REV7/R1 (S1): identidade reassertada imediatamente antes
                # da escrita do recibo pending.
                $idWhyPending = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                if (-not [string]::IsNullOrWhiteSpace($idWhyPending)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyPending -Admitted $true -Reconciled $reconciled -Intent $intent -ExecutorCalls 0)
                }
                $writeWhy = ''
                if (-not (Write-NDReceipt -Dir $rDir -Receipt $pending -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -Admitted $true -Intent $intent -ExecutorCalls 0)
                }
                $post = Test-NDPostLockFencing -GoalId ([string](Get-NDValue $Authorization 'goal_id' '')) -Owner ([string](Get-NDValue $Authorization 'owner' '')) -Generation ([long](Get-NDValue $Authorization 'generation' 0)) -GoalStoreDir $GoalStoreDir
                if (-not [bool](Get-NDValue $post 'ok' $false)) {
                    $postWhy = ([string](Get-NDValue $post 'reason' 'post-lock-fencing-changed'))
                    # F3/exclusao de efeito: recusa pos-lock NUNCA liquida um
                    # recibo pending pre-existente. Um replay recusado nao
                    # prova que o efeito externo do pending ORIGINAL nao tenha
                    # ocorrido; sobrescrever com settled-failure liberaria a
                    # reserva da task e deixaria um SEGUNDO efeito rodar. Para
                    # o replay (reconciled=$true) o pending ORIGINAL fica
                    # intacto; a reconciliacao externa com prova kernel-side
                    # segue sendo o unico caminho para resolve-lo.
                    if ($reconciled) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason $postWhy -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
                    }
                    # despacho NOVO (recibo ausente comprovado, executor ainda
                    # NAO rodou): zero efeito estabelecido, entao liquidar a
                    # falha e seguro e preserva o comportamento historico.
                    $refused = [ordered]@{
                        schema_version  = 1; idempotency_key = $key; phase = 'settled'
                        ok              = $false; reason = $postWhy
                        task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                        agent           = ([string](Get-NDValue $intent 'agent' ''))
                        owner           = ([string](Get-NDValue $intent 'owner' ''))
                        goal_id         = $ndGoalId
                        ownership_generation = $ndOwnerGen
                        task_expected_revision = $ndTaskRev
                        intent_fingerprint = $fingerprint
                        reconciled      = [bool]$reconciled
                        worker_result   = $null; kernel_ok = $false; kernel_reason = $postWhy
                        executor_calls  = 0
                        evidence_created = $false; evidence_id = ''
                        settled_at      = ([DateTime]::UtcNow.ToString('o'))
                    }
                    # REV7/R1 (S1): identidade reassertada antes da escrita
                    # da recusa (fencing pos-lock).
                    $idWhyRefused = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                    if (-not [string]::IsNullOrWhiteSpace($idWhyRefused)) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason $idWhyRefused -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
                    }
                    $writeWhy = ''
                    if (-not (Write-NDReceipt -Dir $rDir -Receipt $refused -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                        return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
                    }
                    return (New-NDDispatchEnvelope -Ok $false -Reason $postWhy -Admitted $true -Reconciled $reconciled -ExecutorCalls 0 -Intent $intent -KernelReason $postWhy)
                }
                $calls = 0
                $rawResult = $null
                try {
                    $calls = 1
                    $rawResult = & $Executor $intent
                }
                catch {
                    # F3/exclusao de efeito: o Executor foi chamado (calls=1)
                    # e lancou DEPOIS de um POSSIVEL efeito externo. Uma
                    # excecao generica NUNCA prova que o efeito nao ocorreu;
                    # liquidar 'settled' liberaria a reserva da task e
                    # deixaria um SEGUNDO efeito rodar enquanto o primeiro
                    # pode ter acontecido. O pending escrito em (h) fica
                    # INTACTO (nao-resolvido); a reconciliacao externa com
                    # prova kernel-side segue sendo o unico caminho para
                    # resolve-lo. O envelope ainda reporta o efeito ocorrido
                    # (executor-failed, executor_calls=1).
                    return (New-NDDispatchEnvelope -Ok $false -Reason 'executor-failed' -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -KernelReason 'executor-failed')
                }
                $shape = Test-OrchestrationDispatchResultShape -Result $rawResult
                if (-not [bool](Get-NDValue $shape 'ok' $false)) {
                    # F3/exclusao de efeito: o Executor RODOU (calls=1) e
                    # devolveu um resultado de forma inutilizavel. Isso nao
                    # prova ausencia de efeito externo (o worker completou e
                    # retornou); liquidar 'settled' liberaria a reserva da
                    # task. O pending fica INTACTO (nao-resolvido) e a
                    # reconciliacao externa com prova kernel-side resolve.
                    return (New-NDDispatchEnvelope -Ok $false -Reason ([string](Get-NDValue $shape 'reason' 'invalid-result')) -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -KernelReason 'result-shape-invalid')
                }
                $status = ([string](Get-NDValue $shape 'status' ''))
                $claimed = [string[]]@((Get-NDValue $shape 'claimed_evidence' @()))
                $workerOut = [pscustomobject][ordered]@{ status = $status; claimed_evidence = $claimed }
                $evCreated = $false
                $evId = ''
                try {
                    $evCmd = Get-Command New-OrchestrationEvidenceRecord -ErrorAction SilentlyContinue
                    $evDirCmd = Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue
                    if (($null -ne $evCmd) -and ($null -ne $evDirCmd)) {
                        $evDir = ([string]$EvidenceStoreDir).Trim()
                        if ([string]::IsNullOrWhiteSpace($evDir)) {
                            $evDir = Get-OrchestrationEvidenceDefaultStoreDir
                        }
                        if (-not [string]::IsNullOrWhiteSpace($evDir)) {
                            $agentName = ([string](Get-NDValue $intent 'agent' ''))
                            $evInput = [ordered]@{
                                task_id = ([string](Get-NDValue $intent 'task_id' ''))
                                run_id  = $key
                                worker_id = $agentName
                                provenance = @{ created_by = $agentName; kernel_task_ref = ([string](Get-NDValue $intent 'task_id' '')) }
                                base_revision = ([string](Get-NDValue $intent 'base_revision' ''))
                                criteria_hash = (Get-NativeDispatchHash32 (($claimed -join ',')))
                                source_fingerprints = @{ 'dispatch-intent' = $key }
                                diff_hash = ''
                                scope = @((Get-NDValue $intent 'scope' @()))
                                command = 'native-dispatch'
                                environment = @{ runtime = 'native-dispatch'; version = '1' }
                                result = @{ summary = ('worker:' + $status); raw_ref = '' }
                                assumptions = @()
                                invalidation_conditions = @(
                                    @{ type = 'base-revision'; require_same = $true }
                                )
                                created_at = ([DateTime]::UtcNow.ToString('o'))
                            }
                            $evSlot = New-OrchestrationEvidenceRecord -Evidence $evInput -StoreDir $evDir
                            if (($null -ne $evSlot) -and [bool](Get-NDValue $evSlot 'created' $false) -and ($null -ne (Get-NDValue $evSlot 'record' $null))) {
                                $evCreated = $true
                                $evId = ([string](Get-NDValue (Get-NDValue $evSlot 'record' $null) 'evidence_id' ''))
                            }
                        }
                    }
                }
                catch { $evCreated = $false; $evId = '' }
                $kOk = $false
                $kWhy = 'kernel-unavailable'
                try {
                    $kCmd = Get-Command Set-OrchestrationTaskWorkerResult -ErrorAction SilentlyContinue
                    if ($null -ne $kCmd) {
                        $producedBy = ([string](Get-NDValue $intent 'agent' ''))
                        $kSlot = Set-OrchestrationTaskWorkerResult `
                            -TaskId ([string](Get-NDValue $intent 'task_id' '')) `
                            -Status $status `
                            -ClaimedEvidence $claimed `
                            -ProducedBy $producedBy `
                            -ExpectedRevision ([long](Get-NDValue $intent 'task_expected_revision' 0)) `
                            -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
                        if (($null -ne $kSlot) -and [bool](Get-NDValue $kSlot 'ok' $false)) {
                            $kOk = $true; $kWhy = ''
                        }
                        else {
                            $kWhy = ([string](Get-NDValue $kSlot 'error' 'kernel-refused'))
                            if ([string]::IsNullOrWhiteSpace($kWhy)) { $kWhy = 'kernel-refused' }
                        }
                    }
                }
                catch { $kOk = $false; $kWhy = 'kernel-failed' }
                $settledOk = ([bool]$kOk)
                $settledReason = ''
                if (-not $settledOk) { $settledReason = ('kernel:' + $kWhy) }
                $settled = [ordered]@{
                    schema_version  = 1; idempotency_key = $key; phase = 'settled'
                    ok              = [bool]$settledOk; reason = $settledReason
                    task_id         = ([string](Get-NDValue $intent 'task_id' ''))
                    agent           = ([string](Get-NDValue $intent 'agent' ''))
                    owner           = ([string](Get-NDValue $intent 'owner' ''))
                    goal_id         = $ndGoalId
                    ownership_generation = $ndOwnerGen
                    task_expected_revision = $ndTaskRev
                    intent_fingerprint = $fingerprint
                    reconciled      = [bool]$reconciled
                    worker_result   = @{ status = $status; claimed_evidence = @($claimed) }
                    kernel_ok       = [bool]$kOk; kernel_reason = $kWhy
                    executor_calls  = [int]$calls
                    evidence_created = [bool]$evCreated; evidence_id = $evId
                    settled_at      = ([DateTime]::UtcNow.ToString('o'))
                }
                # REV7/R1 (S1): ultima barreira antes de persistir o recibo
                # settled. E o ponto em que uma troca de namespace acontecida
                # durante o Executor seria percebida: sem isso a escrita
                # assumiria o destino da resolucao original.
                $idWhySettled = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                if (-not [string]::IsNullOrWhiteSpace($idWhySettled)) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason $idWhySettled -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
                }
                # REV8/F2 (S1): motivo explicito da recusa de escrita.
                $writeWhy = ''
                if (-not (Write-NDReceipt -Dir $rDir -Receipt $settled -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                    return (New-NDDispatchEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-persist-failed') -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
                }
                return (New-NDDispatchEnvelope -Ok $settledOk -Reason $settledReason -Admitted $true -Reconciled $reconciled -ExecutorCalls $calls -Intent $intent -WorkerResult $workerOut -KernelOk $kOk -KernelReason $kWhy -EvidenceCreated $evCreated -EvidenceId $evId)
            }
            # F2: o lock de task e mantido durante TODA a operacao, inclusive o
            # efeito do Executor e a liquidacao do recibo - e soltado por
            # ultimo, na ordem inversa da aquisicao.
            finally {
                try { $lock.Dispose() } catch { }
                try { $taskLock.Dispose() } catch { }
            }
        }
        catch {
            return (New-NDDispatchEnvelope -Ok $false -Reason 'dispatch-internal-error')
        }
    }
# ---------- PR-A: handoff nativo (PREPARE / CLAIM / SETTLE) ----------
#
# Fatia 1 do PLANNER-NATIVE-HANDOFF-v0.1.2 (PREPARE + CLAIM) e fatia 2
# (SETTLE). Separam a preparacao duravel, o consumo pre-efeito e a
# liquidacao correlacionada SEM criar store paralelo, SEM binding extra e
# SEM invocar worker. As tres operacoes novas usam EXCLUSIVAMENTE a
# infraestrutura existente deste modulo:
#   - o mesmo diretorio de recibos (<ReceiptDir>/<goal-hash>/<key>.json)
#     e o mesmo lock de recibo (.dispatch.lock);
#   - o mesmo lock de task na RAIZ (.ndtask-<hash32(task_id)>.lock), na
#     mesma ordem task -> recibo do CLAIM e do Invoke legado;
#   - os mesmos gates de autorizacao/admissao/fencing
#     (Test-NativeDispatchAuthorization, Test-NDLiveTaskAdmission,
#     Test-NDPostLockFencing, Test-NDReconcileLiveOwnership);
#   - os mesmos helpers de namespace/identidade/fingerprint
#     (Resolve-NDGoalReceiptDir, Assert-NDDirIdentity, Test-NDReceiptDirLive,
#     Write-NDReceipt, Read-NDReceipt com -AllowHandoffPhases,
#     Get-NDIntentFingerprint).
#
# FASES: 'prepared' -> 'claimed' -> 'settled'. O campo `handoff_state`
# carrega o estado da maquina da SPEC: 'PREPARED' no preparo,
# 'DISPATCH_UNCERTAIN' no consumo e 'SETTLED' na liquidacao - os dois
# primeiros persistidos ANTES da fronteira do efeito, o terceiro SO depois
# de evidencia canonica + worker-result no kernel. Nao existe store de
# reserva separado: a liberacao da reserva de task (F2) e a propria
# transicao para 'settled', que a varredura `Test-NDTaskEffectExclusive`
# passa a tratar como liquidacao conhecida.
#
# NENHUMA das tres operacoes recebe ou invoca Executor: o efeito nativo
# acontece FORA do PowerShell, na tool model-callable da sessao real.
# `executor_calls` aparece nos envelopes apenas para o chamador provar 0
# sem precisar confiar na palavra da operacao.
#
# CONFIANCA NO DESCRITOR (sem autenticacao): `Test-NDHostCallDescriptor`
# valida apenas a FORMA de sessionID/messageID/callID. A identidade do
# evento do host precisa ser obtida de forma INDEPENDENTE pelo hospedeiro
# (plugin/hook da sessao real, com IDs proprios do runtime). Este modulo
# NAO consegue autenticar um descritor fornecido e nao trata texto do
# modelo como autorizacao. Sem provenance independente, o resultado
# continua sendo claim nao verificado.

function Test-NDHostCallDescriptor {
    <#
    .SYNOPSIS
        Valida a FORMA do descritor de chamada do host. Nunca autentica.
    .DESCRIPTION
        PR-A: sessionID/messageID/callID do evento do host so passam por
        uma checagem de charset/tamanho. Isso NAO e prova de quem chamou:
        a identidade do evento precisa ser obtida de forma independente
        pelo hospedeiro (plugin/hook da sessao real). Este helper nao
        consegue autenticar um descritor fornecido e nao trata texto do
        modelo como autorizacao.

        `-RequireCallIdentity` (usado pelo CLAIM) exige os tres campos;
        sem ele (PREPARE) apenas a sessao e obrigatoria, porque
        message/call ID ainda nao existem no preparo. Fail-closed:
        qualquer divergencia de forma devolve ok=$false com razao
        especifica. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [switch]$RequireCallIdentity
    )
    try {
        $sid = ([string]$SessionId).Trim()
        if ($sid -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            return [pscustomobject]@{ ok = $false; reason = 'host-session-invalid' }
        }
        if ($RequireCallIdentity) {
            $mid = ([string]$MessageId).Trim()
            if ($mid -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
                return [pscustomobject]@{ ok = $false; reason = 'host-message-invalid' }
            }
            $cid = ([string]$CallId).Trim()
            if ($cid -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
                return [pscustomobject]@{ ok = $false; reason = 'host-call-invalid' }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; session_id = $sid; message_id = $mid; call_id = $cid }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; session_id = $sid; message_id = ''; call_id = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'host-descriptor-invalid' }
    }
}

function Test-NDHostAgentName {
    <#
    .SYNOPSIS
        Valida a FORMA de um nome de agente do descritor do host.
    .DESCRIPTION
        Mesmo charset do `agent` do Intent (`^[A-Za-z0-9_-]{1,64}$`).
        Checagem de forma apenas: nao autoriza nem autentica ninguem.
        Fail-closed. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Agent = '')
    try {
        $a = ([string]$Agent).Trim()
        if ($a -cnotmatch '^[A-Za-z0-9_-]{1,64}$') {
            return [pscustomobject]@{ ok = $false; reason = 'host-agent-invalid'; agent = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; agent = $a }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'host-agent-invalid'; agent = '' }
    }
}

function Test-NDChildSessionId {
    <#
    .SYNOPSIS
        Valida a FORMA do identificador da sessao filha (PR-A, fatia 2).
    .DESCRIPTION
        A sessao filha vem do hospedeiro (evento execute.after da tool
        nativa + ctx.session.get(child).parentID). Esta funcao confere
        apenas charset/tamanho - o MESMO alfabeto dos IDs de sessao do
        host - e NAO autentica nada: ela nao consegue provar que a sessao
        existe, que o parent e o declarado nem que o worker rodou nela.
        Fail-closed: ausente, vazio ou fora do formato devolve ok=$false
        com 'child-session-invalid'. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$ChildSessionId = '')
    try {
        $c = ([string]$ChildSessionId).Trim()
        if ($c -cnotmatch '^[A-Za-z0-9._:-]{1,128}$') {
            return [pscustomobject]@{ ok = $false; reason = 'child-session-invalid'; child_session_id = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; child_session_id = $c }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'child-session-invalid'; child_session_id = '' }
    }
}

function Test-NDCandidateResultMatch {
    <#
    .SYNOPSIS
        Compara DOIS resultados candidatos do worker (status + refs).
    .DESCRIPTION
        Igualdade ordinal do status (canonicalizado em minusculas) e
        comparacao de claimed_evidence ordenada em ordinal, com contagem
        explicita - a mesma disciplina de
        `Test-NDReconcileKernelProof`. Nao ha tratamento especial para
        'verified_pass'/'done'/'approved': quem chama ja validou a FORMA
        dos dois lados com `Test-OrchestrationDispatchResultShape`, e aqui
        qualquer divergencia e divergencia. Devolve $false para status
        vazio. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Status = '', $Refs = $null, [string]$OtherStatus = '', $OtherRefs = $null)
    try {
        $a = ([string]$Status).Trim().ToLowerInvariant()
        $b = ([string]$OtherStatus).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($a)) -or ($a -cne $b)) { return $false }
        $x = @(Get-NDSortedOrdinal -Items @($Refs))
        $y = @(Get-NDSortedOrdinal -Items @($OtherRefs))
        if (@($x).Count -ne @($y).Count) { return $false }
        for ($i = 0; $i -lt @($x).Count; $i++) {
            if (([string]$x[$i]) -cne ([string]$y[$i])) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-NDPreparedArgumentFingerprint {
    <#
    .SYNOPSIS
        Fingerprint canonico do CONJUNTO de argumentos preparados (PR-A).
    .DESCRIPTION
        Cobre o fingerprint canonico do Intent (`Get-NDIntentFingerprint`,
        F7/R2) MAIS a identidade do preparo (sessao do Planner, task e
        agente). Qualquer divergencia semantica - argumento, sessao, task,
        agente ou ownership - muda o fingerprint; o mesmo
        idempotency_key com fingerprint distinto e colisao, nunca
        reutilizacao. Nunca carrega prompt: so hashes.
    #>
    [CmdletBinding()]
    param($Intent = $null, [string]$SessionId = '')
    try {
        $base = Get-NDIntentFingerprint -Intent $Intent
        if ([string]::IsNullOrWhiteSpace($base)) { return '' }
        $material = 'ndpf1;'
        $material += Get-NDCanonicalField -Name 'intent' -Value $base
        $material += Get-NDCanonicalField -Name 'session' -Value (([string]$SessionId).Trim())
        $material += Get-NDCanonicalField -Name 'task' -Value ([string](Get-NDValue $Intent 'task_id' ''))
        $material += Get-NDCanonicalField -Name 'agent' -Value ([string](Get-NDValue $Intent 'agent' ''))
        return (Get-NativeDispatchHash32 $material)
    }
    catch { return '' }
}

function Get-NDHandoffReference {
    <#
    .SYNOPSIS
        Referencia compacta e opaca de UM preparo (PR-A).
    .DESCRIPTION
        Hash determinista de goal + idempotency_key + prepared_fingerprint.
        E opaca (32 hex, sem goal/task/owner em texto) e estavel: a
        reentrada identica do PREPARE devolve a MESMA referencia, o que
        torna o preparo idempotente sem criar segundo store. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$IdempotencyKey = '', [string]$PreparedFingerprint = '')
    try {
        $material = 'ndhref1;'
        $material += Get-NDCanonicalField -Name 'goal' -Value (([string]$GoalId).Trim())
        $material += Get-NDCanonicalField -Name 'key' -Value (([string]$IdempotencyKey).Trim().ToLowerInvariant())
        $material += Get-NDCanonicalField -Name 'fp' -Value (([string]$PreparedFingerprint).Trim().ToLowerInvariant())
        return (Get-NativeDispatchHash32 $material)
    }
    catch { return '' }
}

function Get-NDReceiptIntentView {
    <#
    .SYNOPSIS
        Reconstroi a visao de Intent a partir de UM recibo duravel (PR-A).
    .DESCRIPTION
        O CLAIM precisa revalidar admissao viva contra o kernel, mas nao
        pode confiar em Intent fornecido pelo chamador: a fonte da verdade
        e o recibo persistido pelo PREPARE. Esta funcao devolve um Intent
        com a MESMA forma do canonico (campos semanticos + idempotency_key),
        lido apenas do recibo, ou $null quando o recibo nao tem os campos
        minimos (fail-closed: sem visao valida nao ha admissao).
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $null }
        $tid = ([string](Get-NDValue $Receipt 'task_id' '')).Trim()
        $agent = ([string](Get-NDValue $Receipt 'agent' '')).Trim()
        if (([string]::IsNullOrWhiteSpace($tid)) -or ([string]::IsNullOrWhiteSpace($agent))) { return $null }
        $scopes = [string[]]@()
        foreach ($s in @((Get-NDValue $Receipt 'scope' @()))) {
            $t = ([string]$s).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { $scopes += @($t) }
        }
        if (@($scopes).Count -lt 1) { return $null }
        $crits = [string[]]@()
        foreach ($c in @((Get-NDValue $Receipt 'acceptance_criteria' @()))) {
            $t = ([string]$c).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { $crits += @($t) }
        }
        $rev = [long]0
        try { $rev = [long](Get-NDValue $Receipt 'task_expected_revision' 0) } catch { $rev = 0 }
        if ($rev -lt 1) { return $null }
        $gen = [long]0
        try { $gen = [long](Get-NDValue $Receipt 'ownership_generation' 0) } catch { $gen = 0 }
        $owner = ([string](Get-NDValue $Receipt 'owner' '')).Trim()
        if (([string]::IsNullOrWhiteSpace($owner)) -or ($gen -lt 1)) { return $null }
        return [pscustomobject][ordered]@{
            schema_version = 1
            task_id = $tid
            task_expected_revision = $rev
            agent = $agent
            prompt_hash = ([string](Get-NDValue $Receipt 'prompt_hash' ''))
            scope = [string[]]$scopes
            acceptance_criteria = [string[]]$crits
            idempotency_key = ([string](Get-NDValue $Receipt 'idempotency_key' ''))
            owner = $owner
            ownership_generation = $gen
            base_revision = ([string](Get-NDValue $Receipt 'base_revision' ''))
            external_idempotent = [bool](Get-NDValue $Receipt 'external_idempotent' $false)
            external_idempotency_proof = ([string](Get-NDValue $Receipt 'external_idempotency_proof' ''))
        }
    }
    catch { return $null }
}

function Test-NDHandoffReceiptShape {
    <#
    .SYNOPSIS
        Forma CRUA (tipo de token) do recibo PROPRIO de handoff, antes de
        reconstruir/consumir/reutilizar (FIX3B / F3). Fail-closed.
    .DESCRIPTION
        A integridade semantica RECONSTROI o Intent do recibo
        (`Get-NDReceiptIntentView`) e recalcula fingerprints. A
        reconstrucao le campos por `Get-NDValue` + coercao, e esse caminho
        DESENROLA um array de um elemento: `task_id:["x"]` chega como 'x',
        `ownership_generation:[1]` como 1, `external_idempotent:[false]`
        como $false, `scope:"src/a"` como @('src/a'). Um recibo com token
        em forma de array mas VALOR coercitivo identico passaria entao pelo
        recalculo de fingerprint com os hashes antigos intactos - a mesma
        adulteracao que a varredura de recibos ESTRANGEIROS ja rejeita
        (`Test-NDReceiptScanRecord`), mas que o recibo PROPRIO, EXCLUIDO da
        varredura, ainda deixava passar.

        Esta funcao fecha a lacuna para o recibo PROPRIO exigindo, em
        TOKENS CRUS (lidos direto da propriedade JSON, sem pipeline/coercao):
          - raiz objeto JSON (nunca array nem escalar);
          - identidade/hash/fase como STRING (task_id, agent, owner,
            goal_id, idempotency_key, prompt_hash, base_revision, phase,
            intent_fingerprint, prepared_fingerprint, reference,
            session_id, external_idempotency_proof - a prova opcional
            preserva string vazia);
          - schema_version/ownership_generation/task_expected_revision como
            INTEIRO escalar exato (schema == 1, generation >= 1,
            revisao >= 1);
          - external_idempotent como BOOLEANO exato;
          - scope e acceptance_criteria como ARRAY JSON de strings nao
            vazio (cada elemento string).
        Campo ausente ou tipo de token divergente devolve $false. Roda
        SOMENTE para recibos de handoff ('prepared'/'claimed'); recibos
        legados ('pending'/'settled') nunca passam por aqui. Somente
        leitura. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        # raiz objeto: array ou escalar (string/numero/booleano) nao e registro.
        if (($Receipt -is [string]) -or ($Receipt -is [Array]) -or ($Receipt -is [bool])) { return $false }
        # identidade/hash/fase: token string cruo (array/numero/bool recusam).
        foreach ($f in @('task_id', 'agent', 'owner', 'goal_id', 'idempotency_key', 'prompt_hash', 'base_revision', 'phase', 'intent_fingerprint', 'prepared_fingerprint', 'reference', 'session_id', 'external_idempotency_proof')) {
            if ($null -eq (Get-NDJsonStringValue -Object $Receipt -Name $f)) { return $false }
        }
        # escalares inteiros exatos (inteiro, nunca booleano/fracionario/array).
        $sv = Get-NDJsonIntegralLong -Object $Receipt -Name 'schema_version'
        if (($null -eq $sv) -or ($sv -ne 1)) { return $false }
        $gen = Get-NDJsonIntegralLong -Object $Receipt -Name 'ownership_generation'
        if (($null -eq $gen) -or ($gen -lt 1)) { return $false }
        $rev = Get-NDJsonIntegralLong -Object $Receipt -Name 'task_expected_revision'
        if (($null -eq $rev) -or ($rev -lt 1)) { return $false }
        # booleano exato (nunca array de um elemento, nunca string 'false').
        if ($null -eq (Get-NDJsonBoolValue -Object $Receipt -Name 'external_idempotent')) { return $false }
        # arrays JSON de strings nao vazios.
        $scope = Get-NDJsonStringArrayValue -Object $Receipt -Name 'scope'
        if (($null -eq $scope) -or (@($scope).Count -lt 1)) { return $false }
        $crit = Get-NDJsonStringArrayValue -Object $Receipt -Name 'acceptance_criteria'
        if (($null -eq $crit) -or (@($crit).Count -lt 1)) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-NDReceiptSemanticIntegrity {
    <#
    .SYNOPSIS
        Integridade SEMANTICA do registro de handoff (F3). Fail-closed.
    .DESCRIPTION
        Comparar apenas os campos de hash deixa um furo: um recibo com
        JSON valido e hashes intactos, mas com campo semantico alterado,
        passaria pela conferencia de fingerprint. Esta funcao
        RECONSTROI o Intent a partir do PROPRIO recibo
        (`Get-NDReceiptIntentView` + `New-OrchestrationNativeDispatchIntent`,
        o MESMO construtor do caminho legado), RECALCULA
        `intent_fingerprint`, `prepared_fingerprint` (com a sessao
        ARMAZENADA, nunca com a do chamador) e a referencia opaca
        (goal/key/fingerprint), e exige que TODO campo de identidade
        semantica persistido bata com o recalculado.

        Cobre, um a um: task, agent, owner, generation, revisao esperada,
        base_revision, prompt_hash, scope, acceptance_criteria,
        external_idempotent/proof, idempotency_key, goal_id, sessao,
        intent_fingerprint, prepared_fingerprint e reference. Tampering
        com hash intacto muda o fingerprint RECALCULADO e recusa com
        `receipt-integrity-invalid`; registro sem os campos minimos ou
        com formato invalido recusa do mesmo jeito.

        PORTA DE FORMA CRUA (FIX3B, antes da reconstrucao): o recalculo de
        fingerprint por si so nao distinguiria `task_id:"x"` de
        `task_id:["x"]` (o valor coercitivo e identico), entao um recibo
        PROPRIO com campo em forma de array passaria com os hashes
        antigos. `Test-NDHandoffReceiptShape` exige primeiro o TIPO de
        TOKEN cru de cada campo (raiz objeto, strings de identidade/hash/
        fase, inteiros exatos, booleano exato, arrays de strings);
        divergencia recusa em `receipt-integrity-invalid` ANTES de
        reconstruir ou reutilizar. Nunca lanca e nunca devolve ok=$true
        por excesso de confianca.
    #>
    [CmdletBinding()]
    param($Receipt = $null, [string]$GoalId = '', [string]$IdempotencyKey = '')
    try {
        $refuse = [pscustomobject]@{ ok = $false; reason = 'receipt-integrity-invalid'; intent = $null }
        if ($null -eq $Receipt) { return $refuse }
        # FIX3B: forma crua do recibo PROPRIO antes de qualquer reconstrucao,
        # reuso ou claim - fecha a inconsistencia array-token/hash-intacto.
        if (-not (Test-NDHandoffReceiptShape -Receipt $Receipt)) { return $refuse }
        $gid = ([string]$GoalId).Trim()
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($gid)) -or ($key -cnotmatch '^[a-f0-9]{32}$')) { return $refuse }
        # identidade de arquivo: key do nome e goal do namespace autorizado
        if (([string](Get-NDValue $Receipt 'idempotency_key' '')).Trim().ToLowerInvariant() -cne $key) { return $refuse }
        if (([string](Get-NDValue $Receipt 'goal_id' '')).Trim() -cne $gid) { return $refuse }
        # a sessao usada na reconstrucao e a ARMAZENADA no registro: assim
        # uma sessao adulterada muda o prepared_fingerprint recalculado.
        $storedSession = ([string](Get-NDValue $Receipt 'session_id' ''))
        $view = Get-NDReceiptIntentView -Receipt $Receipt
        if ($null -eq $view) { return $refuse }
        $check = New-OrchestrationNativeDispatchIntent `
            -TaskId ([string](Get-NDValue $view 'task_id' '')) `
            -TaskExpectedRevision ([long](Get-NDValue $view 'task_expected_revision' 0)) `
            -Agent ([string](Get-NDValue $view 'agent' '')) `
            -PromptHash ([string](Get-NDValue $view 'prompt_hash' '')) `
            -Scope @((Get-NDValue $view 'scope' @())) `
            -AcceptanceCriteria @((Get-NDValue $view 'acceptance_criteria' @())) `
            -IdempotencyKey $key `
            -Owner ([string](Get-NDValue $view 'owner' '')) `
            -OwnershipGeneration ([long](Get-NDValue $view 'ownership_generation' 0)) `
            -BaseRevision ([string](Get-NDValue $view 'base_revision' '')) `
            -ExternalIdempotent ([bool](Get-NDValue $view 'external_idempotent' $false)) `
            -ExternalIdempotencyProof ([string](Get-NDValue $view 'external_idempotency_proof' ''))
        if (-not [bool](Get-NDValue $check 'ok' $false)) { return $refuse }
        $intent = Get-NDValue $check 'intent' $null
        if ($null -eq $intent) { return $refuse }
        # comparacao explicita campo a campo dos campos de identidade
        foreach ($f in @('task_id', 'agent', 'owner', 'base_revision', 'prompt_hash', 'external_idempotency_proof')) {
            if (([string](Get-NDValue $Receipt $f '')).Trim() -cne ([string](Get-NDValue $intent $f '')).Trim()) { return $refuse }
        }
        if ([long](Get-NDValue $Receipt 'ownership_generation' 0) -ne [long](Get-NDValue $intent 'ownership_generation' 0)) { return $refuse }
        if ([long](Get-NDValue $Receipt 'task_expected_revision' 0) -ne [long](Get-NDValue $intent 'task_expected_revision' 0)) { return $refuse }
        if ([bool](Get-NDValue $Receipt 'external_idempotent' $false) -ne [bool](Get-NDValue $intent 'external_idempotent' $false)) { return $refuse }
        foreach ($list in @('scope', 'acceptance_criteria')) {
            $storedList = @(Get-NDSortedOrdinal -Items @((Get-NDValue $Receipt $list @())))
            $builtList = @(Get-NDSortedOrdinal -Items @((Get-NDValue $intent $list @())))
            if (@($storedList).Count -ne @($builtList).Count) { return $refuse }
            for ($i = 0; $i -lt @($storedList).Count; $i++) {
                if (([string]$storedList[$i]) -cne ([string]$builtList[$i])) { return $refuse }
            }
        }
        $intentFp = Get-NDIntentFingerprint -Intent $intent
        if (([string]::IsNullOrWhiteSpace($intentFp)) -or ($intentFp -cne ([string](Get-NDValue $Receipt 'intent_fingerprint' '')).Trim().ToLowerInvariant())) { return $refuse }
        $preparedFp = Get-NDPreparedArgumentFingerprint -Intent $intent -SessionId $storedSession
        if (([string]::IsNullOrWhiteSpace($preparedFp)) -or ($preparedFp -cne ([string](Get-NDValue $Receipt 'prepared_fingerprint' '')).Trim().ToLowerInvariant())) { return $refuse }
        $reference = Get-NDHandoffReference -GoalId $gid -IdempotencyKey $key -PreparedFingerprint $preparedFp
        if (([string]::IsNullOrWhiteSpace($reference)) -or ($reference -cne ([string](Get-NDValue $Receipt 'reference' '')).Trim())) { return $refuse }
        return [pscustomobject]@{ ok = $true; reason = ''; intent = $intent }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'receipt-integrity-invalid'; intent = $null }
    }
}
function Read-NDBoundedFileText {
    <#
    .SYNOPSIS
        Le UM arquivo de texto com teto de bytes (cap+1 em stream). Fail-closed.
    .DESCRIPTION
        B3/REV8: confiar no FileInfo.Length e depois ler sem limite deixa
        janela TOCTOU (o arquivo pode crescer entre o stat e a leitura) e um
        recibo poderia ser lido inteiro mesmo acima do cap. Aqui a leitura e
        limitada pelo proprio stream: abre, le no maximo cap+1 bytes e, se
        ainda havia byte cap+1, o arquivo EXCEDE o teto => ok=$false
        (recusa). Nunca devolve conteudo parcial como se fosse completo:
        ok=$true somente com o arquivo inteiro dentro do cap. IO/atributo
        ilegivel tambem ok=$false. Nunca lanca. Somente leitura.
    #>
    [CmdletBinding()]
    param([string]$Path = '', [int]$MaxBytes = 262144)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return [pscustomobject]@{ ok = $false; text = '' } }
        $cap = [int]$MaxBytes
        if ($cap -lt 1) { $cap = 1 }
        $fs = $null
        try {
            $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $want = $cap + 1
            $buf = New-Object byte[] $want
            $got = 0
            while ($got -lt $want) {
                $n = $fs.Read($buf, $got, ($want - $got))
                if ($n -le 0) { break }
                $got += $n
            }
            # byte extra (cap+1) presente => excede o teto.
            if ($got -gt $cap) { return [pscustomobject]@{ ok = $false; text = '' } }
            return [pscustomobject]@{ ok = $true; text = ([Text.Encoding]::UTF8.GetString($buf, 0, $got)) }
        }
        finally { try { if ($null -ne $fs) { $fs.Dispose() } } catch { } }
    }
    catch { return [pscustomobject]@{ ok = $false; text = '' } }
}

function Get-NDJsonProperty {
    <#
    .SYNOPSIS
        Le UM token JSON do registro cru, sem passar pelo pipeline.
    .DESCRIPTION
        `Get-NDValue` devolve o valor da propriedade pelo PIPELINE de
        saida, e o PowerShell DESENROLA colecao nesse caminho: um token
        `[1]`, `["x"]` ou `["settled"]` (array de UM elemento) chega ao
        chamador como escalar 1 / 'x' / 'settled'. A coercao seguinte
        (`[long]`, `[string]`) aceita entao o valor como se o token
        original fosse o campo esperado - e `schema_version:[1]`,
        `task_id:["..."]`, `phase:["settled"]` passariam por escalares.

        Aqui a propriedade e lida DIRETO de `PSObject.Properties[name]`
        (ou do dicionario) e o TIPO do valor cru e classificado ANTES de
        qualquer coercao ou passagem por pipeline. `kind`:
          - 'string'  -> token JSON string; `value` carry a string;
          - 'integer' -> token JSON inteiro (Int32 no PS 5.1, Int64 no
            PS 7 - ambos aceitos); `value` carry o [long];
          - 'bool'    -> token JSON booleano; `value` carry o [bool];
          - 'null'    -> token JSON null;
          - 'other'   -> Double/Decimal, array ou objeto;
          - 'absent'  -> objeto nulo ou propriedade inexistente.
        Array/objeto devolvem kind 'other' com `value` $null: nunca o
        conteudo enumerado. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    $absent = [pscustomobject]@{ present = $false; kind = 'absent'; value = $null }
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $absent }
        $val = $null
        $found = $false
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $val = $Object[$Name]; $found = $true }
        }
        else {
            $prop = $Object.PSObject.Properties[$Name]
            if ($null -ne $prop) { $val = $prop.Value; $found = $true }
        }
        if (-not $found) { return $absent }
        if ($null -eq $val) { return [pscustomobject]@{ present = $true; kind = 'null'; value = $null } }
        if ($val -is [string]) { return [pscustomobject]@{ present = $true; kind = 'string'; value = ([string]$val) } }
        if (($val -is [int]) -or ($val -is [long])) { return [pscustomobject]@{ present = $true; kind = 'integer'; value = ([long]$val) } }
        if ($val -is [bool]) { return [pscustomobject]@{ present = $true; kind = 'bool'; value = ([bool]$val) } }
        # Double/Decimal, array, objeto: o token cru nao e o campo esperado.
        # Fail-closed, sem enumerar e sem coercir.
        return [pscustomobject]@{ present = $true; kind = 'other'; value = $null }
    }
    catch { return $absent }
}

function Get-NDJsonIntegralLong {
    <#
    .SYNOPSIS
        Devolve o valor [long] SOMENTE quando o token JSON original e um
        INTEIRO escalar. Fail-closed para qualquer outra coisa.
    .DESCRIPTION
        `ConvertFrom-Json` produz System.Int32 (PS 5.1) ou System.Int64
        (PS 7) para inteiros; System.Decimal/Double para fracionarios;
        System.Boolean para booleanos; array para `[1]`. Uma coercao
        cega ([long]$true eq 1, [long]1.5 eq 2, [long]1.0 eq 1)
        deixaria schema_version/generation/revision adulterados
        passarem, e a leitura por pipeline desenrolaria o array de um
        elemento em escalar.

        Aqui o token e lido DIRETO da propriedade
        (`Get-NDJsonProperty`) e o TIPO cru e conferido antes de qualquer
        coercao: inteiro (Int32/Int64) devolve [long]; booleano,
        fracionario, string, ARRAY, objeto, null ou ausencia devolvem
        $null (o chamador recusa). Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        $tok = Get-NDJsonProperty -Object $Object -Name $Name
        # PRA-SETTLE-FIX5 (perf): leitura direta do token proprio desta
        # biblioteca (ver Get-NDJsonBoolValue) - semantica identica, sem
        # chamadas de funcao por campo no caminho quente da varredura.
        if (-not $tok.present) { return $null }
        if ($tok.kind -cne 'integer') { return $null }
        $v = $tok.value
        if ($null -eq $v) { return $null }
        return [long]$v
    }
    catch { return $null }
}

function Get-NDJsonStringValue {
    <#
    .SYNOPSIS
        Devolve a string SOMENTE quando o token JSON original e uma
        STRING. Fail-closed para qualquer outra coisa.
    .DESCRIPTION
        Campos de identidade (idempotency_key, goal_id, task_id, agent,
        owner, intent_fingerprint) e fase tem de ser strings no JSON. Um
        booleano/numero/array/objeto seria coercitado por [string] (ex.:
        [string]$true eq 'True') e poderia satisfazer uma checagem de
        forma sem que o token original fosse, de fato, o campo esperado -
        e `["..."]` chegaria como string escalar pelo pipeline.

        Aqui o token e lido DIRETO da propriedade
        (`Get-NDJsonProperty`) e o TIPO cru e conferido: string devolve
        [string]; qualquer outro tipo (inclusive ARRAY), null ou
        ausencia devolve $null. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        $tok = Get-NDJsonProperty -Object $Object -Name $Name
        # PRA-SETTLE-FIX5 (perf): leitura direta do token proprio desta
        # biblioteca (ver Get-NDJsonBoolValue) - semantica identica, sem
        # chamadas de funcao por campo no caminho quente da varredura.
        if (-not $tok.present) { return $null }
        if ($tok.kind -cne 'string') { return $null }
        return [string]$tok.value
    }
    catch { return $null }
}

function Get-NDJsonInstantString {
    <#
    .SYNOPSIS
        Devolve o instante SOMENTE quando o token e string ISO ou DateTime
        materializado pelo runtime (G1-B, paridade PS5.1/PS7). Fail-closed.
    .DESCRIPTION
        O ConvertFrom-Json do PS7 materializa strings ISO-8601 como
        [DateTime]; o do PS5.1 as mantem [string]. O MESMO bytes JSON
        produz tipos diferentes por edicao - esta funcao normaliza:
        string devolve como esta; DateTime devolve em formato 'o'
        (round-trip, sem perda); qualquer outro tipo, null ou ausencia
        devolve $null. Uso RESTRITO a campos de instante (expires_at_utc):
        campos de identidade continuam em Get-NDJsonStringValue estrito,
        pois um DateTime ali seria violacao de forma, nao artefato do
        runtime. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $null }
        $val = $null
        $found = $false
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $val = $Object[$Name]; $found = $true }
        }
        else {
            $prop = $Object.PSObject.Properties[$Name]
            if ($null -ne $prop) { $val = $prop.Value; $found = $true }
        }
        if (-not $found) { return $null }
        if ($null -eq $val) { return $null }
        if ($val -is [string]) { return [string]$val }
        # PS7 materializa strings ISO-8601 como [DateTime] no
        # ConvertFrom-Json (PS5.1 mantem [string]): o MESMO bytes JSON
        # produz tipos distintos por edicao. Normaliza para 'o'.
        if ($val -is [DateTime]) { return (([DateTime]$val).ToString('o')) }
        return $null
    }
    catch { return $null }
}

function Get-NDJsonBoolValue {
    <#
    .SYNOPSIS
        Devolve o [bool] SOMENTE quando o token JSON original e um
        BOOLEANO. Fail-closed para qualquer outra coisa.
    .DESCRIPTION
        `external_idempotent` tem de ser booleano no JSON. Uma coercao
        cega ([bool]@($false) ainda da $false para um array de um
        elemento; [bool]'false' da $true para a string 'false') deixaria
        o campo adulterado passar, e `["<...>"]`/`[true]` chegariam como
        escalar pela leitura por pipeline.

        Aqui o token e lido DIRETO da propriedade (`Get-NDJsonProperty`,
        kind 'bool') e o TIPO cru e conferido antes de qualquer coercao:
        booleano devolve [bool]; inteiro, string, ARRAY, objeto, null ou
        ausencia devolvem $null (o chamador recusa). Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        $tok = Get-NDJsonProperty -Object $Object -Name $Name
        # PRA-SETTLE-FIX5 (perf): `$tok` e SEMPRE o objeto proprio desta
        # biblioteca ([pscustomobject] com present/kind/value); le-lo por
        # acesso direto a propriedade evita tres chamadas de funcao por
        # campo no caminho quente da varredura. Semantica identica.
        if (-not $tok.present) { return $null }
        if ($tok.kind -cne 'bool') { return $null }
        return [bool]$tok.value
    }
    catch { return $null }
}

function Get-NDJsonStringArrayValue {
    <#
    .SYNOPSIS
        Devolve [string[]] SOMENTE quando o token JSON original e um
        ARRAY (nao escalar) e TODOS os elementos sao STRINGS. Fail-closed.
    .DESCRIPTION
        `scope` e `acceptance_criteria` tem de ser arrays JSON de strings.
        A leitura por pipeline trataria uma string escalar
        (`scope:"src/a"`) como colecao de um elemento e `[["src/a"]]`
        (array cujo elemento e outro array) como string coercitada
        (`[string]@("src/a")` eq 'src/a'), fazendo o campo adulterado
        passar com o valor coercitivo igual ao original.

        Aqui a propriedade e lida DIRETO (sem pipeline) e o TIPO cru e
        conferido antes de qualquer coercao: um escalar string, um objeto
        JSON ou qualquer elemento NAO-string devolvem $null (o chamador
        recusa). Um array JSON de strings devolve [string[]]. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $null }
        $val = $null
        $found = $false
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $val = $Object[$Name]; $found = $true }
        }
        else {
            $prop = $Object.PSObject.Properties[$Name]
            if ($null -ne $prop) { $val = $prop.Value; $found = $true }
        }
        if (-not $found) { return $null }
        if ($null -eq $val) { return $null }
        # escalar string NAO e array de strings.
        if ($val -is [string]) { return $null }
        # objeto JSON (PSCustomObject) NAO e array de strings.
        if ($val -is [System.Management.Automation.PSCustomObject]) { return $null }
        if (-not ($val -is [System.Collections.IEnumerable])) { return $null }
        $arr = @()
        foreach ($el in $val) {
            if ($el -isnot [string]) { return $null }
            $arr += [string]$el
        }
        return [string[]]$arr
    }
    catch { return $null }
}

function Test-NDJsonObjectRootText {
    <#
    .SYNOPSIS
        $true SOMENTE quando o primeiro token JSON nao-espaco do texto e
        '{' (raiz OBJETO). Fail-closed para qualquer outra coisa.
    .DESCRIPTION
        `ConvertFrom-Json` pela pipeline DESENROLA um array de um
        elemento: o texto `[{...}]` chega ao chamador como UM objeto
        escalar ($raw -is [Array] eq $false), e `42`/`"x"`/`true`/`null`
        chegam como escalar. Um recibo cuja raiz real e array (ou escalar)
        passaria entao pela validacao seguinte como se fosse o objeto
        interno, burlando a exigencia de raiz objeto.

        PSP 5.1 nao tem parser que preserve o tipo da raiz via
        ConvertFrom-Json, entao a estrategia compativel e inspecionar o
        TEXTO antes de parsear: o primeiro caractere nao-espaco (espaco,
        TAB, LF, CR) tem de ser '{'. Qualquer outra coisa (inclusive '[')
        recusa. Nunca lanca e nunca devolve $true por excesso de confianca.
    #>
    [CmdletBinding()]
    param([string]$Text = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
        $t = $Text.TrimStart([char[]]@(' ', [char]9, [char]10, [char]13))
        if ($t.Length -lt 1) { return $false }
        return ($t[0] -ceq '{')
    }
    catch { return $false }
}

function Test-NDReceiptScanRecord {
    <#
    .SYNOPSIS
        Validacao ESTRUTURAL FECHADA de um registro encontrado na
        varredura de exclusao de efeito por task (F2). Fail-closed.
    .DESCRIPTION
        `Test-NDTaskEffectExclusive` caminha TODOS os namespaces de goal
        sob a MESMA raiz de recibos. Concluir "este registro e de OUTRA
        task, ignoro" so e seguro DEPOIS de provar que o registro e
        estruturalmente integro: sem isso, um recibo corrompido de outra
        task/goal/chave passaria por ruido e liberaria um segundo efeito
        da task que esta sob reserva.

        Esta funcao roda ANTES de qualquer atribuicao de task e exige,
        um a um:
          - `schema_version` exatamente 1;
          - `idempotency_key` no formato 32 hex E igual a chave contida
            no NOME do arquivo (key-vs-filename);
          - `phase` dentro do conjunto fechado (pending, prepared,
            claimed, settled), canonicalizado aqui (caixa/padding);
          - todos os campos acima tem de ser TOKENS CRUS do tipo
            esperado: `[1]`, `["settled"]`, `["<task>"]` (array de um
            elemento) chegariam como escalar pela leitura por pipeline
            e passariam pela coercao - aqui o tipo e conferido antes;
          - `goal_id` NAO vazio cujo hash32 bata com o NOME do namespace
            onde o registro foi encontrado (namespace por goal, F3/REV5);
          - `task_id` presente e no formato aceito pelo kernel
            (`Test-NDTaskId`): sem identidade recuperavel nao existe
            atribuicao possivel;
          - `agent` e `owner` NAO vazios (identidade do efeito);
          - `ownership_generation` >= 1 e `task_expected_revision` >= 1;
          - `intent_fingerprint` no formato 32 hex.

        Para as fases de handoff ('prepared'/'claimed') a validacao
        SEMANTICA completa (`Test-NDReceiptSemanticIntegrity`, F3)
        tambem e exigida: o Intent e RECONSTRUIDO do proprio registro e
        `intent_fingerprint`, `prepared_fingerprint` e a referencia opaca
        sao RECALCULADOS e comparados campo a campo. Para as fases do
        caminho legado ('pending'/'settled') vale a validacao estrutural
        fechada acima: esses registros nao carregam o material semantico
        do handoff (prompt_hash/scope/reference/sessao), e exigir o
        recalculo ali recusaria TODO recibo legado legitimo.

        PRA-SETTLE-FIX5: a fronteira NAO e mais a fase, e sim os
        MARCADORES. Qualquer registro que carregue marcadores de handoff
        (`Test-NDHandoffRecordMarkers` - conjunto FECHADO e COMPLETO:
        prefixos `settle_*`, `claim_*`, `claimed_*`, `prepared_*` e os nomes
        exatos `settled_by`, `settled_generation`, `handoff_state`,
        `reference`, `session_id`, `base_revision`, `prompt_hash`, `scope`,
        `acceptance_criteria`, `external_idempotency_proof` e
        `prepared_fingerprint`, comparados em caixa INVARIANTE) exige a
        integridade semantica RECALCULADA em QUALQUER fase - inclusive
        'settled' e inclusive uma fase legada carregando material de
        handoff, que e contradicao, nao compatibilidade. Sem ESSE recalculo,
        um 'settled' do handoff com o `task_id` trocado por outro id VALIDO
        (hashes intactos) seria atribuido a outra task e IGNORADO pela
        varredura, liberando o segundo efeito da task original. Um
        registro legado de verdade - sem nenhum desses campos - segue
        passando so pela validacao estrutural fechada, que e tudo que o
        schema legado tem.

        PRA-SETTLE-FIX6A: para TODO registro marcado tambem vale a porta de
        CAIXA (`Test-NDCanonicalReceiptFieldNames`). Como a deteccao de
        marcadores agora normaliza o nome para minuscula, `SETTLE_STATUS`
        nao pode mais esconder o marcador - mas `HANDOFF_STATE` seria lido
        como `handoff_state` pelas portas seguintes (a leitura de
        propriedade do PowerShell e case-insensitive), e o registro
        persistido nao seria o registro canonico. Nome fora da caixa
        canonica em registro marcado recusa em 'claim-task-scan-unreadable'.
        Registro sem marcador algum (legado) nao passa por essa porta.

        Qualquer duvida - campo ausente, formato invalido, namespace
        divergente, chave divergente do nome, fase desconhecida ou
        fingerprint irrecalculavel - devolve ok=$false com
        'claim-task-scan-unreadable'. Nunca lanca e nunca devolve
        ok=$true por excesso de confianca. Somente leitura.
    #>
    [CmdletBinding()]
    param($Receipt = $null, [string]$Namespace = '', [string]$FileKey = '', [string]$Phase = '')
    try {
        $refuse = [pscustomobject]@{ ok = $false; reason = 'claim-task-scan-unreadable'; task_id = ''; phase = '' }
        if ($null -eq $Receipt) { return $refuse }
        # chave do NOME do arquivo e a identidade de referencia.
        $fk = ([string]$FileKey).Trim().ToLowerInvariant()
        if ($fk -cnotmatch '^[a-f0-9]{32}$') { return $refuse }
        # schema_version: token JSON inteiro == 1. Get-NDJsonIntegralLong
        # recusa fail-closed booleano/fracionario/string e ARRAY (inclusive
        # a de um elemento, que chegaria como escalar pelo pipeline).
        $sv = Get-NDJsonIntegralLong -Object $Receipt -Name 'schema_version'
        if (($null -eq $sv) -or ($sv -ne 1)) { return $refuse }
        $rawKey = Get-NDJsonStringValue -Object $Receipt -Name 'idempotency_key'
        if ($null -eq $rawKey) { return $refuse }
        $rawKey = ([string]$rawKey).Trim().ToLowerInvariant()
        if (($rawKey -cnotmatch '^[a-f0-9]{32}$') -or ($rawKey -cne $fk)) { return $refuse }
        # Fase: TOKEN CRU do proprio registro, lido sem pipeline. A
        # coercao [string] de `phase:["settled"]` (ou de um
        # booleano/numero) deixaria a fase passar sem que o token
        # original fosse uma string.
        $phaseTok = Get-NDJsonStringValue -Object $Receipt -Name 'phase'
        if ($null -eq $phaseTok) { return $refuse }
        $phase = (([string]$phaseTok).Trim().ToLowerInvariant())
        if (@('pending', 'prepared', 'claimed', 'settled') -cnotcontains $phase) { return $refuse }
        # O parametro -Phase (informativo, do caller) NAO pode
        # contradizer o token cru do registro.
        if ((-not [string]::IsNullOrWhiteSpace($Phase)) -and (([string]$Phase).Trim().ToLowerInvariant() -cne $phase)) { return $refuse }
        # namespace por goal: o hash32(goal_id) do registro tem de ser o
        # nome do subdiretorio onde ele foi encontrado.
        $rawGoal = Get-NDJsonStringValue -Object $Receipt -Name 'goal_id'
        if ($null -eq $rawGoal) { return $refuse }
        $rawGoal = ([string]$rawGoal).Trim()
        if ([string]::IsNullOrWhiteSpace($rawGoal)) { return $refuse }
        $nsExpect = Get-NativeDispatchHash32 $rawGoal
        if (([string]::IsNullOrWhiteSpace($nsExpect)) -or ($nsExpect -cne ([string]$Namespace).Trim())) { return $refuse }
        # identidade minima do efeito: task_id tem de ser string com forma
        # aceita pelo kernel (nunca um numero/objeto/array coercitado).
        $rawTask = Get-NDJsonStringValue -Object $Receipt -Name 'task_id'
        if ($null -eq $rawTask) { return $refuse }
        $rawTask = ([string]$rawTask).Trim()
        if (-not (Test-NDTaskId $rawTask)) { return $refuse }
        $rawAgent = Get-NDJsonStringValue -Object $Receipt -Name 'agent'
        if ($null -eq $rawAgent) { return $refuse }
        $rawAgent = ([string]$rawAgent).Trim()
        if ($rawAgent -cnotmatch '^[A-Za-z0-9_-]{1,64}$') { return $refuse }
        $rawOwner = Get-NDJsonStringValue -Object $Receipt -Name 'owner'
        if ($null -eq $rawOwner) { return $refuse }
        $rawOwner = ([string]$rawOwner).Trim()
        if (([string]::IsNullOrWhiteSpace($rawOwner)) -or ($rawOwner.Length -gt 128)) { return $refuse }
        # ownership_generation e task_expected_revision: tokens JSON inteiros
        # >= 1. Get-NDJsonIntegralLong recusa booleano/fracionario/array.
        $gen = Get-NDJsonIntegralLong -Object $Receipt -Name 'ownership_generation'
        if (($null -eq $gen) -or ($gen -lt 1)) { return $refuse }
        $rev = Get-NDJsonIntegralLong -Object $Receipt -Name 'task_expected_revision'
        if (($null -eq $rev) -or ($rev -lt 1)) { return $refuse }
        $fp = Get-NDJsonStringValue -Object $Receipt -Name 'intent_fingerprint'
        if ($null -eq $fp) { return $refuse }
        $fp = ([string]$fp).Trim().ToLowerInvariant()
        if ($fp -cnotmatch '^[a-f0-9]{32}$') { return $refuse }
        # fases de handoff: integridade SEMANTICA recalculada (F3).
        # PRA-SETTLE-FIX6A: a exigencia agora vem dos MARCADORES, nao da
        # fase - qualquer registro que carregue material de handoff (em
        # qualquer fase, inclusive 'settled') tem de provar a integridade
        # SEMANTICA RECALCULADA antes de poder ser atribuido ou ignorado
        # pela varredura. Sem isso, um 'settled' do handoff com o task_id
        # trocado por outro id valido (hashes intactos) seria ignorado
        # como "outra task". Um legado de verdade nao tem marcadores.
        # A deteccao de marcador e case-insensitive, entao a CAIXA dos
        # nomes e conferida aqui: registro marcado com nome fora da caixa
        # canonica nao e o registro que a liquidacao escreveu - recusa a
        # varredura (nunca rebaixado a legado, nunca aceito como handoff).
        if ((($phase -ceq 'prepared') -or ($phase -ceq 'claimed')) -or (Test-NDHandoffRecordMarkers -Receipt $Receipt)) {
            if (-not (Test-NDCanonicalReceiptFieldNames -Receipt $Receipt)) { return $refuse }
            $integ = Test-NDReceiptSemanticIntegrity -Receipt $Receipt -GoalId $rawGoal -IdempotencyKey $fk
            if (-not [bool](Get-NDValue $integ 'ok' $false)) { return $refuse }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; task_id = $rawTask; goal_id = $rawGoal; phase = $phase }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'claim-task-scan-unreadable'; task_id = ''; phase = '' } }
}

function Resolve-NDWalkReason {
    <#
    .SYNOPSIS
        Normaliza a razao devolvida por `Invoke-NDIncrementalWalk` para a
        razao final do scan de exclusao de efeito. Fail-closed.
    .DESCRIPTION
        O caminhador devolve razoes internas ('walk-cap-exceeded',
        'walk-source-null', 'walk-callback-null', 'walk-enumerate-failed',
        'walk-callback-error'). Cap estourado veta a varredura sem
        materializar tudo -> 'claim-task-scan-unbounded'. Qualquer outro
        motivo interno (argumento ruim, enumeracao ou callback falharam) ou
        razao vazia -> 'claim-task-scan-unreadable'. Uma razao que o proprio
        callback JA produziu no vocabulario do scan passa intacta. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Reason = '')
    try {
        if ($Reason -ceq 'walk-cap-exceeded') { return 'claim-task-scan-unbounded' }
        if (($Reason -ceq 'walk-source-null') -or ($Reason -ceq 'walk-callback-null') -or ($Reason -ceq 'walk-enumerate-failed') -or ($Reason -ceq 'walk-callback-error') -or ([string]::IsNullOrWhiteSpace($Reason))) {
            return 'claim-task-scan-unreadable'
        }
        return $Reason
    }
    catch { return 'claim-task-scan-unreadable' }
}

function Invoke-NDIncrementalWalk {
    <#
    .SYNOPSIS
        Caminha um IEnumerable<string> de forma INCREMENTAL com enumerador
        .NET EXPLICITO (GetEnumerator/MoveNext/Current), aplicando um cap
        DURANTE a caminhada e invocando $OnItem uma entrada por vez.
    .DESCRIPTION
        Diferente de um `foreach` - cuja avaliacao lazy depende de detalhes
        do runtime de scripting - aqui a fonte e puxada UM item por vez via
        MoveNext/Current e o cap interrompe em Cap+1 (PULLED == Cap+1), sem
        NUNCA materializar a lista inteira antes do cap. O enumerador e
        sempre descartado no finally (handle de IO do FindFirstFile
        liberado), inclusive quando a caminhada para no meio.

        $OnItem recebe o item atual e devolve:
          - string vazia (''): continue para a proxima entrada;
          - string nao-vazia: PARE a caminhada com essa razao.
        Um cap estourado devolve razao interna 'walk-cap-exceeded'. Falha de
        enumeracao ('walk-enumerate-failed'), de callback ('walk-callback-error')
        ou argumento ruim ('walk-source-null'/'walk-callback-null') sao
        fail-closed. Devolve [pscustomobject]@{ ok; reason; seen }. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $Source = $null,
        [scriptblock]$OnItem = $null,
        [int]$Cap = 512
    )
    if ($null -eq $Source) { return [pscustomobject]@{ ok = $false; reason = 'walk-source-null'; seen = 0 } }
    if ($null -eq $OnItem) { return [pscustomobject]@{ ok = $false; reason = 'walk-callback-null'; seen = 0 } }
    if ($Cap -lt 1) { $Cap = 1 }
    $iter = $null
    $seen = 0
    try {
        try { $iter = $Source.GetEnumerator() }
        catch { return [pscustomobject]@{ ok = $false; reason = 'walk-enumerate-failed'; seen = $seen } }
        while ($true) {
            $advance = $false
            try { $advance = $iter.MoveNext() }
            catch { return [pscustomobject]@{ ok = $false; reason = 'walk-enumerate-failed'; seen = $seen } }
            if (-not $advance) { break }
            $seen++
            if ($seen -gt $Cap) { return [pscustomobject]@{ ok = $false; reason = 'walk-cap-exceeded'; seen = $seen } }
            $current = $null
            try { $current = $iter.Current } catch { return [pscustomobject]@{ ok = $false; reason = 'walk-enumerate-failed'; seen = $seen } }
            $sig = $null
            try { $sig = & $OnItem $current }
            catch { return [pscustomobject]@{ ok = $false; reason = 'walk-callback-error'; seen = $seen } }
            if (($null -ne $sig) -and ([string]$sig -ne '')) {
                return [pscustomobject]@{ ok = $false; reason = ([string]$sig); seen = $seen }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; seen = $seen }
    }
    finally {
        if ($iter -is [IDisposable]) { try { $iter.Dispose() } catch { } }
    }
}

function Test-NDPostLockRefusalReason {
    <#
    .SYNOPSIS
        $true SOMENTE quando a razao e uma recusa de Test-NDPostLockFencing.
    .DESCRIPTION
        PRA-SETTLE-FIX4: um recibo 'settled' legado com kernel_ok=false so
        libera a reserva de task quando e PROVAVELMENTE uma recusa PRE-efeito
        fresca. Uma das condicoes e o reason estar nesta allowlist FECHADA das
        razoes-BASE que Test-NDPostLockFencing devolve. As formas com sufixo
        documentadas la (post-lock-goal-not-active:<estado>,
        post-lock-fencing-changed:<razao>, post-lock-goal-unreadable:<razao>)
        casam pelo prefixo seguido de ':'. NUNCA aceita sufixo arbitrario
        colado (ex.: post-lock-fencing-changedXYZ), nem razao de outro dominio
        (kernel:*, executor-failed, invented). Qualquer duvida devolve $false -
        fail-closed. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Reason = '')
    try {
        $allow = @(
            'post-lock-invalid-token',
            'post-lock-check-unavailable',
            'post-lock-goal-unreadable',
            'post-lock-goal-not-active',
            'post-lock-fencing-changed',
            'post-lock-internal-error'
        )
        $r = ([string]$Reason)
        if ([string]::IsNullOrWhiteSpace($r)) { return $false }
        foreach ($a in @($allow)) {
            if ($r -ceq $a) { return $true }
            if ($r.StartsWith(($a + ':'), [System.StringComparison]::Ordinal)) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-NDSettledFreshPreEffectRefusal {
    <#
    .SYNOPSIS
        $true SOMENTE para um 'settled' legado que e PROVAVELMENTE uma recusa
        PRE-efeito fresca (nenhum efeito ocorreu naquela invocacao). Fail-closed.
    .DESCRIPTION
        PRA-SETTLE-FIX4: um recibo 'settled' com kernel_ok=false nunca deve
        liberar a reserva de task so por estar 'settled' - o Invoke legado
        ainda liquida 'settled' DEPOIS de um efeito real quando o kernel
        recusa (TaskKernel failure), e liquidar esse recibo liberaria um
        SEGUNDO efeito da mesma task. A UNICA excecao segura e a recusa
        pos-lock de um despacho NOVO, onde o Executor jamais rodou: exige,
        lendo TOKENS CRUS (sem coercao, sem pipeline), que
          (a) kernel_ok seja EXATAMENTE booleano false;
          (b) executor_calls seja EXATAMENTE inteiro 0 (ausente/array/
              booleano/fracionario nao comprova zero efeito);
          (c) reconciled seja EXATAMENTE booleano false - um replay de um
              pending anterior (reconciled=true) NUNCA libera, mesmo com zero
              chamadas, porque o efeito do pending ORIGINAL pode ter ocorrido;
          (d) reason seja uma recusa de Test-NDPostLockFencing
              (Test-NDPostLockRefusalReason, allowlist fechada).
        Qualquer condicao nao satisfeita (inclusive token malformado) devolve
        $false. Nunca lanca. Somente leitura.
    #>
    [CmdletBinding()]
    param($Receipt = $null)
    try {
        if ($null -eq $Receipt) { return $false }
        # (a) kernel_ok EXATAMENTE booleano false (o true ja foi tratado pelo
        #     chamador; ausente/malformado devolve $null e nao passa).
        $kOk = Get-NDJsonBoolValue -Object $Receipt -Name 'kernel_ok'
        if (($null -eq $kOk) -or ($kOk -ne $false)) { return $false }
        # (b) executor_calls EXATAMENTE inteiro 0.
        $calls = Get-NDJsonIntegralLong -Object $Receipt -Name 'executor_calls'
        if (($null -eq $calls) -or ($calls -ne 0)) { return $false }
        # (c) reconciled EXATAMENTE booleano false (nunca replay de pending).
        $rec = Get-NDJsonBoolValue -Object $Receipt -Name 'reconciled'
        if (($null -eq $rec) -or ($rec -ne $false)) { return $false }
        # (d) reason na allowlist fechada de recusas pos-lock.
        $reason = Get-NDJsonStringValue -Object $Receipt -Name 'reason'
        if ($null -eq $reason) { return $false }
        if (-not (Test-NDPostLockRefusalReason -Reason $reason)) { return $false }
        return $true
    }
    catch { return $false }
}

function Test-NDTaskEffectExclusive {
    <#
    .SYNOPSIS
        Exclusao de efeito por TASK: nenhum segundo efeito nativo/Executor
        enquanto existir recibo nao-resolvido da MESMA task (F2).
    .DESCRIPTION
        Chaves de idempotencia diferentes - e ate goals diferentes - podem
        preparar (e reivindicar) recibos diferentes para a MESMA task. Sem
        uma reserva por TASK, dois efeitos da mesma task chegariam a
        'claimed' (ou a 'pending' no legado) enquanto o primeiro segue
        DISPATCH_UNCERTAIN, e o efeito externo rodaria duas vezes.

        A reserva vale para `(raiz de recibos, task_id)` e NAO depende de
        GoalId, revisao, generation nem chave. Esta funcao caminha TODOS
        os namespaces de goal sob a MESMA raiz - o proprio modelo de
        recibos, nunca um segundo store - de forma INCREMENTAL
        (`EnumerateDirectories`/`EnumerateFiles`, caps aplicados durante a
        caminhada, sem materializar a lista inteira antes do cap) e recusa
        quando OUTRO recibo - identidade `(namespace, chave)`, NUNCA a
        chave sozinha - esta em fase NAO-RESOLVIDA para a mesma task:
          'claimed' -> efeito nativo em DISPATCH_UNCERTAIN: bloqueia;
          'pending' -> efeito legado incerto: bloqueia;
          'prepared' -> NAO e efeito: nao bloqueia;
          'settled' -> liquidacao CONHECIDA libera a reserva; NAO e, porem,
                       permissao automatica de segundo efeito (PRA-SETTLE-FIX4).
                       O 'settled' do HANDOFF (qualquer marcador de handoff -
                       Test-NDHandoffRecordMarkers) so libera quando a FORMA CRUA, a
                       EVIDENCIA (evidence_created booleano true + evidence_id
                       nao vazio) e o kernel conhecido (kernel_ok booleano
                       EXATAMENTE true) estao provados no PROPRIO registro
                       (Test-NDSettledHandoffProof): forma crua indecidivel
                       recusa a varredura, liquidacao nao provada mantem a
                       reserva. Essa prova - e a integridade semantica
                       RECALCULADA de qualquer registro marcado - rodam ANTES
                       da atribuicao de task (PRA-SETTLE-FIX5): um task_id
                       trocado por outro id valido, com hashes intactos, nao
                       chega a ser ignorado como "outra task". O 'settled'
                       LEGADO (sem marcador algum de handoff)
                       tem porta propria: kernel_ok booleano EXATAMENTE true
                       libera; um settled com kernel_ok=false so libera se for
                       PROVAVELMENTE uma recusa PRE-efeito fresca (executor_calls
                       0, reconciled false, reason na allowlist de
                       Test-NDPostLockFencing); qualquer outro settled com
                       kernel_ok false - inclusive efeito real seguido de
                       TaskKernel recusando - continua bloqueando. Token
                       kernel_ok ausente/malformado recusa a varredura
                       (claim-task-scan-unreadable).

                       ORDEM (PRA-SETTLE-FIX5/FIX6/FIX6A): a variante do
                       registro - HANDOFF ou LEGADO - e decidida pelos
                       MARCADORES crus ANTES de qualquer atribuicao de
                       task. Para QUALQUER registro marcado, em qualquer
                       fase, rodam antes de comparar o task_id dele com o
                       da operacao: (i) a porta de CAIXA
                       (`Test-NDCanonicalReceiptFieldNames`), (ii) a
                       integridade semantica RECALCULADA contra o goal/key
                       ARMAZENADOS no PROPRIO registro e (iii) para fase
                       'settled', a prova ESTRITA da liquidacao
                       (`Test-NDSettledHandoffProof`). Qualquer divergencia
                       recusa a varredura INTEIRA, nao apenas aquele
                       registro - e registro MARCADO que nao prova a
                       liquidacao NUNCA e rebaixado a legado nem libera a
                       reserva (sem reclassificacao automatica, sem
                       liberacao em registro malformado/hibrido).

                       A deteccao de marcadores de
                       `Test-NDHandoffRecordMarkers` normaliza o nome para
                       a forma INVARIANTE (minuscula) e cobre o conjunto
                       FECHADO e COMPLETO (`settle_*`, `claim_*,
                       `claimed_*`, `prepared_*`, `settled_by`,
                       `settled_generation`, `handoff_state`,
                       `reference`, `session_id` e, desde
                       PRA-SETTLE-FIX6C, `base_revision`, `prompt_hash`,
                       `scope`, `acceptance_criteria`,
                       `external_idempotency_proof` e
                       `prepared_fingerprint`): mudar a caixa de um
                       nome nao rebaixa mais o registro a legado (FIX6A), e
                       nenhuma linhagem de handoff - inclusive `claimed_*` -
                       fica fora do conjunto. Nome fora da caixa canonica em
                       registro marcado recusa a varredura em
                       'claim-task-scan-unreadable'.
                       Alem do conjunto de marcadores, TODO nome fora do
                       alfabeto canonico `[a-z0-9_]` (espaco interno,
                       pontuacao, separador trocado) MARCA o registro:
                       nenhum escritor grava nome nessa forma, entao nome
                       assim nao pode significar "e legado".
        A excecao de replay (`-SkipGoalId`/`-SkipKey`) vale somente para o
        arquivo EXATO da operacao em curso; nao ha excecao cross-key nem
        cross-goal.

        Atribuicao (regra explicita): um registro so decide - bloqueando
        ou sendo ignorado - quando a validacao ESTRUTURAL FECHADA dele
        passou INTEIRA (`Test-NDReceiptScanRecord`: schema 1, chave contra
        o nome do arquivo, conjunto de fases, hash do namespace do goal,
        identidade minima do efeito e, nas fases de handoff, integridade
        SEMANTICA recalculada - F3) E o task_id DO PROPRIO registro bate
        com o da operacao. A atribuicao portanto NUNCA acontece antes da
        validacao. Nomes inesperados de namespace/arquivo, reparse, entrada
        nao-arquivo, identidade divergente, cap estourado, arquivo grande
        demais, JSON invalido/truncado/vazio, task_id AUSENTE/INVALIDO,
        schema desconhecido, chave divergente do nome do arquivo, fase
        desconhecida, hash de namespace divergente ou integridade semantica
        adulterada recusam SEMPRE em modo fail-closed - INCLUSIVE quando o
        registro parece ser de OUTRA task: sem estrutura valida nao ha como
        afirmar que nao ha efeito DESTA task ali, e incerteza nunca pode
        liberar um segundo efeito. Somente DEPOIS de valido, um registro
        de OUTRA task e ignorado (nao ha efeito desta task nele).
        O recibo PROPRIO da operacao continua sendo lido e recusado ANTES
        desta varredura, pelo diagnostico especifico dele (R3): a razao que
        o chamador ve para o proprio recibo nao e mascarada pelo scan.

        Delimitacao honesta: a identidade de cada subdiretorio e capturada
        quando o namespace entra na caminhada e reassertada antes de cada
        leitura; PS 5.1 nao tem abertura kernel sem-seguir-link, entao
        checagem -> IO continua com janela residual TOCTOU documentada.
        O lock de task serializa a reserva + a escrita do recibo entre
        processos e NAO serializa mutacao do GoalKernel. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$RootDir = '',
        [string]$TaskId = '',
        [string]$SkipGoalId = '',
        [string]$SkipKey = '',
        [string]$RootExpected = ''
    )
    try {
        $refuseUnreadable = [pscustomobject]@{ ok = $false; reason = 'claim-task-scan-unreadable' }
        $refuseUnbounded = [pscustomobject]@{ ok = $false; reason = 'claim-task-scan-unbounded' }
        $tid = ([string]$TaskId).Trim()
        if (([string]::IsNullOrWhiteSpace($RootDir)) -or ([string]::IsNullOrWhiteSpace($tid))) { return $refuseUnreadable }
        $skipNs = ''
        if (-not [string]::IsNullOrWhiteSpace($SkipGoalId)) {
            $skipNs = Get-NativeDispatchHash32 (([string]$SkipGoalId).Trim())
            if ([string]::IsNullOrWhiteSpace($skipNs)) { return $refuseUnreadable }
        }
        $skipKey = ([string]$SkipKey).Trim().ToLowerInvariant()
        # identidade da RAIZ reassertada imediatamente antes de enumerar.
        $rootChk = Assert-NDDirIdentity -Path $RootDir -Expected $RootExpected
        if (-not [bool](Get-NDValue $rootChk 'ok' $false)) {
            return [pscustomobject]@{ ok = $false; reason = ([string](Get-NDValue $rootChk 'reason' 'receipt-dir-identity-changed')) }
        }
        # B3: cap GLOBAL de entradas entre TODAS as namespaces, compartilhado
        # por referencia nos callbacks (hashtable mutavel do escopo do scan).
        $scanState = @{ entries = 0 }
        $nsEnumerable = $null
        try { $nsEnumerable = [IO.Directory]::EnumerateDirectories($RootDir) }
        catch { return $refuseUnreadable }
        # Callback por NAMESPACE: devolve '' para continuar ou a razao (no
        # vocabulario do scan) que PARA a varredura. Identidade da raiz e do
        # namespace reassertada exatamente como antes; as entradas do
        # namespace passam pelo caminhador incremental (enumerador explicito,
        # cap local 512) e pelo cap global (4096) contado em $scanState.
        $nsCallback = {
            param($nsPath)
            $nsName = ''
            try { $nsName = [IO.Path]::GetFileName($nsPath) } catch { return 'claim-task-scan-unreadable' }
            # nome inesperado de namespace: recusa, nunca ignorar.
            if (([string]::IsNullOrWhiteSpace($nsName)) -or ($nsName -cnotmatch '^[a-f0-9]{32}$')) { return 'claim-task-scan-unreadable' }
            # raiz reassertada antes de enumerar CADA namespace.
            $rootNow = Assert-NDDirIdentity -Path $RootDir -Expected $RootExpected
            if (-not [bool](Get-NDValue $rootNow 'ok' $false)) {
                return ([string](Get-NDValue $rootNow 'reason' 'receipt-dir-identity-changed'))
            }
            # subdiretorio: existe, Container e SEM reparse point.
            $nsChk = Assert-NDDirIdentity -Path $nsPath -Expected ''
            if (-not [bool](Get-NDValue $nsChk 'ok' $false)) {
                return ([string](Get-NDValue $nsChk 'reason' 'receipt-dir-identity-changed'))
            }
            # identidade estavel do namespace, reassertada antes de cada IO.
            $nsIdent = Get-NDDirCreationTimeUtcTicks -Path $nsPath
            # B2: enumerar ENTRADAS (nao so arquivos *.json): um diretorio ou
            # junction chamado <chave>.json seria invisivel para EnumerateFiles
            # e esconderia um recibo. Enumeracao incremental pelo caminhador,
            # uma entrada por vez.
            $fEnumerable = $null
            try { $fEnumerable = [IO.Directory]::EnumerateFileSystemEntries($nsPath) }
            catch { return 'claim-task-scan-unreadable' }
            $fCallback = {
                param($f)
                # B3: cap GLOBAL de entradas em TODAS as namespaces (4096).
                $scanState.entries++
                if ($scanState.entries -gt 4096) { return 'claim-task-scan-unbounded' }
                # B3: raiz reassert imediatamente antes de CADA entrada.
                $rootNow = Assert-NDDirIdentity -Path $RootDir -Expected $RootExpected
                if (-not [bool](Get-NDValue $rootNow 'ok' $false)) {
                    return ([string](Get-NDValue $rootNow 'reason' 'receipt-dir-identity-changed'))
                }
                # identidade do subdiretorio reassertada antes de CADA leitura.
                $nsNow = Assert-NDDirIdentity -Path $nsPath -Expected $nsIdent
                if (-not [bool](Get-NDValue $nsNow 'ok' $false)) {
                    return ([string](Get-NDValue $nsNow 'reason' 'receipt-dir-identity-changed'))
                }
                $name = ''
                try { $name = [IO.Path]::GetFileName($f) } catch { return 'claim-task-scan-unreadable' }
                if ([string]::IsNullOrWhiteSpace($name)) { return 'claim-task-scan-unreadable' }
                # Internos legitimos do store NAO terminam em .json
                # (.dispatch.lock, receipt-*.tmp) e seguem ignorados. Tudo que
                # terminar em .json passa a ser recuso-able (B2) ou recibo (B1).
                if (-not $name.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) { return '' }
                # excecao de replay (B6): SOMENTE o arquivo exato desta
                # operacao (namespace do goal autorizado + chave exata). Nome
                # fora do formato de recibo nao entra na excecao.
                if ($name -cmatch '^[a-f0-9]{32}\.json$') {
                    $exKey = $name.Substring(0, $name.Length - 5)
                    if (($skipNs -ne '') -and ($nsName -ceq $skipNs) -and ($exKey -ceq $skipKey)) { return '' }
                }
                # B2: link (symlink/junction) ou diretorio com nome de recibo
                # recusa (fail-closed); atributo ilegivel tambem. NAO le nem
                # segue o alvo.
                $fAttrs = $null
                try { $fAttrs = [IO.File]::GetAttributes($f) } catch { $fAttrs = $null }
                if ($null -eq $fAttrs) { return 'claim-task-scan-unreadable' }
                if (($fAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 'claim-task-scan-unreadable' }
                if (($fAttrs -band [IO.FileAttributes]::Directory) -ne 0) { return 'claim-task-scan-unreadable' }
                # nome .json fora do formato de recibo: recusa, nunca ignorar.
                if ($name -cnotmatch '^[a-f0-9]{32}\.json$') { return 'claim-task-scan-unreadable' }
                $fKey = $name.Substring(0, $name.Length - 5)
                # B1/B3: leitura LIMITADA por stream (cap+1 bytes); oversize ou
                # falha de IO recusam. NAO confia no FileInfo.Length e depois
                # le sem limite.
                $rd = Read-NDBoundedFileText -Path $f -MaxBytes 262144
                if (-not [bool](Get-NDValue $rd 'ok' $false)) { return 'claim-task-scan-unreadable' }
                $text = [string](Get-NDValue $rd 'text' '')
                # B1: recibo truncado/vazio/JSON invalido NAO pode ser
                # ignorado: um claimed/pending desta task que ficou ilegivel
                # nao pode liberar um segundo efeito. Fail-closed.
                if ([string]::IsNullOrWhiteSpace($text)) { return 'claim-task-scan-unreadable' }
                # FIX3B: raiz OBJETO obrigatoria antes de parsear. Sem isso
                # `ConvertFrom-Json` desenrolaria `[{...}]` num objeto escalar
                # e um recibo de raiz array passaria pela validacao/atribuicao.
                if (-not (Test-NDJsonObjectRootText -Text $text)) { return 'claim-task-scan-unreadable' }
                $raw = $null
                try { $raw = ConvertFrom-Json $text } catch { $raw = $null }
                if ($null -eq $raw) { return 'claim-task-scan-unreadable' }
                # B1/B4: VALIDACAO ESTRUTURAL FECHADA antes de qualquer
                # atribuicao. So um registro integro - schema (token inteiro,
                # nunca booleano/fracionario/ARRAY), chave contra o nome do
                # arquivo, fase conhecida (token string cru, nunca array de
                # um elemento nem coercao), hash do namespace do goal,
                # identidade minima e (handoff) integridade semantica
                # recalculada - pode ser atribuido a alguma task. JSON
                # invalido/truncado/vazio, task_id AUSENTE/INVALIDO, schema
                # desconhecido/fracionario/booleano, chave divergente, fase
                # desconhecida, namespace divergente ou recibo
                # semanticamente adulterado recusam em modo fail-closed,
                # INCLUSIVE quando o registro parece ser de outra task: sem
                # estrutura valida nao ha como afirmar que nao ha efeito
                # DESTA task ali.
                $phaseTok = Get-NDJsonStringValue -Object $raw -Name 'phase'
                if ($null -eq $phaseTok) { return 'claim-task-scan-unreadable' }
                $recChk = Test-NDReceiptScanRecord -Receipt $raw -Namespace $nsName -FileKey $fKey -Phase ([string]$phaseTok)
                if (-not [bool](Get-NDValue $recChk 'ok' $false)) {
                    return ([string](Get-NDValue $recChk 'reason' 'claim-task-scan-unreadable'))
                }
                # PRA-SETTLE-FIX5: prova COMPLETA do 'settled' do HANDOFF
                # ANTES de qualquer atribuicao de task. A integridade
                # semantica deste registro JA foi recalculada acima
                # (`Test-NDReceiptScanRecord` exige para qualquer registro
                # marcado), entao um task_id trocado por outro id valido
                # com hashes intactos nao chega ate aqui como registro
                # "valido de outra task". Falta a prova ESTRITA da
                # liquidacao: sem ela, o registro NAO pode ser ignorado
                # como efeito de outra task - a reserva continua valendo.
                # Token cru indecidivel recusa a varredura
                # ('claim-task-scan-unreadable'); qualquer outra falha de
                # prova mantem a reserva ('claim-task-already-claimed'),
                # exatamente o mesmo mapeamento da porta pos-atribuicao
                # abaixo. Um 'settled' do handoff VALIDO passa e so
                # entao pode ser ignorado por task divergente.
                $phasePre = ([string](Get-NDValue $recChk 'phase' ''))
                if (($phasePre -ceq 'settled') -and (Test-NDHandoffRecordMarkers -Receipt $raw)) {
                    $preProof = Test-NDSettledHandoffProof -Receipt $raw
                    if (-not [bool](Get-NDValue $preProof 'ok' $false)) {
                        if ([string](Get-NDValue $preProof 'reason' 'settled-shape-invalid') -ceq 'settled-shape-invalid') {
                            return 'claim-task-scan-unreadable'
                        }
                        return 'claim-task-already-claimed'
                    }
                }
                # Identidade VALIDA e recuperavel de OUTRA task: prova que
                # nao ha efeito DESTA task ali => ignorado. A atribuicao
                # nunca acontece antes da validacao acima.
                $rawTask = ([string](Get-NDValue $recChk 'task_id' ''))
                if ($rawTask -cne $tid) { return '' }
                # registro atribuido a ESTA task: 'claimed' (efeito nativo
                # em DISPATCH_UNCERTAIN) e 'pending' (efeito legado
                # incerto) bloqueiam; 'prepared' nao e efeito e nao bloqueia.
                $phase = ([string](Get-NDValue $recChk 'phase' ''))
                if (($phase -ceq 'claimed') -or ($phase -ceq 'pending')) {
                    return 'claim-task-already-claimed'
                }
                if ($phase -ceq 'settled') {
                    # PRA-SETTLE-FIX4: 'settled' NAO e, por si so, permissao
                    # para um segundo efeito. A liquidacao CONHECIDA - SETTLE
                    # do handoff e Invoke legado BEM-SUCEDIDO - grava kernel_ok
                    # booleano EXATAMENTE true e libera a reserva. Um
                    # 'settled' com kernel_ok=false so libera quando e
                    # PROVAVELMENTE uma recusa PRE-efeito fresca (zero chamadas
                    # de Executor, reconciled=false e reason na allowlist de
                    # Test-NDPostLockFencing): nenhum efeito ocorreu naquela
                    # invocacao. QUALQUER outro settled com kernel_ok=false -
                    # inclusive o legado que liquidou DEPOIS de um efeito real
                    # com o TaskKernel recusando (executor_calls>0) - continua
                    # reservando a task (nunca interpretado como permissao).
                    # Token kernel_ok ausente/malformado num settled DESTA task
                    # recusa a varredura de forma indecidivel.
                    #
                    # DOIS SCHEMAS, DUAS PORTAS: o caminho do HANDOFF
                    # (discriminado por `Test-NDHandoffRecordMarkers`) tem
                    # EXIGENTE - a liquidacao e RECONSTRUIDA dos campos
                    # persistidos no PROPRIO registro
                    # (`Test-NDSettledHandoffProof`): kernel conhecido,
                    # evidencia exigida e VINCULADA ao marcador
                    # settle_evidence_*, identidade settled_by/generation,
                    # linhagem settle_* igual aos claim_*, child binding,
                    # marcadores settle_attempt_* e worker_result
                    # correlacionados e integridade semantica recalculada.
                    # Um 'settled' do handoff sem essa prova NAO libera a
                    # reserva: token cru indecidivel recusa a varredura
                    # ('claim-task-scan-unreadable'); semantica adulterada,
                    # correlacao ausente ou qualquer outra falha de prova
                    # mantem a reserva ('claim-task-already-claimed') - e um
                    # campo de MESMO TIPO trocado por outro valor valido
                    # (child session id, evidence_id) cai neste ultimo caso
                    # (PRA-SETTLE-FIX5). O schema LEGADO nao
                    # passa por essa porta (nao tem marcador algum, em
                    # nenhuma combinacao): ele segue a
                    # regra propria abaixo, que e a unica que os recibos
                    # legados - inclusive a recusa PRE-efeito fresca -
                    # conhecem. Um handoff MALFORMADO (marcadores sem
                    # liquidacao valida) NUNCA cai na porta legada: sao os
                    # marcadores, nao a fase, que decidem o schema.
                    if (Test-NDHandoffRecordMarkers -Receipt $raw) {
                        $hProof = Test-NDSettledHandoffProof -Receipt $raw
                        if ([bool](Get-NDValue $hProof 'ok' $false)) { return '' }
                        if ([string](Get-NDValue $hProof 'reason' 'settled-shape-invalid') -ceq 'settled-shape-invalid') {
                            return 'claim-task-scan-unreadable'
                        }
                        return 'claim-task-already-claimed'
                    }
                    $kernelOkTok = Get-NDJsonBoolValue -Object $raw -Name 'kernel_ok'
                    if ($null -eq $kernelOkTok) { return 'claim-task-scan-unreadable' }
                    if ([bool]$kernelOkTok) { return '' }
                    if (Test-NDSettledFreshPreEffectRefusal -Receipt $raw) { return '' }
                    return 'claim-task-already-claimed'
                }
                return ''
            }
            $fWalk = Invoke-NDIncrementalWalk -Source $fEnumerable -Cap 512 -OnItem $fCallback
            if (-not [bool](Get-NDValue $fWalk 'ok' $false)) {
                return (Resolve-NDWalkReason -Reason ([string](Get-NDValue $fWalk 'reason' '')))
            }
            return ''
        }
        $nsWalk = Invoke-NDIncrementalWalk -Source $nsEnumerable -Cap 512 -OnItem $nsCallback
        if (-not [bool](Get-NDValue $nsWalk 'ok' $false)) {
            return [pscustomobject]@{ ok = $false; reason = (Resolve-NDWalkReason -Reason ([string](Get-NDValue $nsWalk 'reason' ''))) }
        }
        return [pscustomobject]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'claim-task-scan-unreadable' }
    }
}

function Convert-NDReceiptToPhase {
    <#
    .SYNOPSIS
        Copia UM recibo persistido para outra fase, preservando campos.
    .DESCRIPTION
        Usado pelo CLAIM para a transicao UNICA 'prepared' -> 'claimed':
        todos os campos do preparo (inclusive os desconhecidos desta
        versao) sao preservados e so a fase/estado + a linhagem do host
        mudam. Nao inventa campo e nao apaga dado do preparo. Devolve
        $null quando o recibo e ilegivel (fail-closed).
    #>
    [CmdletBinding()]
    param($Receipt = $null, [string]$Phase = '', $Extra = $null)
    try {
        if ($null -eq $Receipt) { return $null }
        $phase = ([string]$Phase).Trim().ToLowerInvariant()
        if ($phase -cnotmatch '^[a-z]{1,32}$') { return $null }
        $out = [ordered]@{}
        foreach ($pp in @($Receipt.PSObject.Properties)) { $out[[string]$pp.Name] = $pp.Value }
        if ($null -ne $Extra) {
            if ($Extra -is [System.Collections.IDictionary]) {
                foreach ($k in @($Extra.Keys)) { $out[[string]$k] = $Extra[$k] }
            }
            else {
                foreach ($pp in @($Extra.PSObject.Properties)) { $out[[string]$pp.Name] = $pp.Value }
            }
        }
        $out['phase'] = $phase
        return $out
    }
    catch { return $null }
}

function Test-NDTaskAttemptBudget {
    <#
    .SYNOPSIS
        Budget de tentativas vivo da task, antes de qualquer efeito (PR-A).
    .DESCRIPTION
        Espelha a convencao existente de
        `Test-OrchestrationTaskCompletion` (attempts acima do
        attempt_budget impedem avanco): enquanto a task viva ja estourou o
        budget de tentativas, um novo efeito nao pode ser admitido.
        Fail-closed: task ilegivel, erro do kernel ou budget inconsistente
        recusam em vez de deixar passar. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$TaskId = '', [string]$TasksDir = '', [string]$RepoRoot = '')
    try {
        $tid = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) {
            return [pscustomobject]@{ ok = $false; reason = 'attempt-budget-unknown'; attempts = 0; budget = 0 }
        }
        $tCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $tCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'attempt-budget-unavailable'; attempts = 0; budget = 0 }
        }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot }
        catch { $task = $null }
        if ($null -eq $task) {
            return [pscustomobject]@{ ok = $false; reason = 'attempt-budget-unknown'; attempts = 0; budget = 0 }
        }
        $errCode = ''
        try {
            if ($task -is [System.Collections.IDictionary]) {
                if ($task.Contains('error')) { $errCode = ([string]$task['error']) }
            }
            else {
                $ep = $task.PSObject.Properties['error']
                if ($null -ne $ep) { $errCode = ([string]$ep.Value) }
            }
        }
        catch { $errCode = '' }
        if (-not [string]::IsNullOrWhiteSpace($errCode)) {
            return [pscustomobject]@{ ok = $false; reason = ('attempt-budget-unreadable:' + $errCode); attempts = 0; budget = 0 }
        }
        $budget = 3
        try { $budget = [int](Get-NDValue $task 'attempt_budget' 3) } catch { $budget = 3 }
        if ($budget -lt 1) { $budget = 3 }
        $attempts = @(Get-NDValue $task 'attempts' @())
        if (@($attempts).Count -gt $budget) {
            return [pscustomobject]@{ ok = $false; reason = 'attempt-budget-exceeded'; attempts = @($attempts).Count; budget = $budget }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; attempts = @($attempts).Count; budget = $budget }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'attempt-budget-unknown'; attempts = 0; budget = 0 }
    }
}

function New-NDPrepareEnvelope {
    <#
    .SYNOPSIS
        Envelope compacto do PREPARE (PR-A). Sem worker_result, sem efeito.
    #>
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [bool]$Admitted = $false,
        [bool]$Reused = $false,
        [string]$Phase = '',
        [string]$Reference = '',
        [string]$IntentFingerprint = '',
        [string]$PreparedFingerprint = '',
        [string]$SessionId = '',
        [string]$TaskId = '',
        [string]$Agent = '',
        [int]$ExecutorCalls = 0,
        $Intent = $null
    )
    return [pscustomobject][ordered]@{
        ok                   = [bool]$Ok
        reason               = ([string]$Reason)
        admitted             = [bool]$Admitted
        reused               = [bool]$Reused
        phase                = ([string]$Phase)
        reference            = ([string]$Reference)
        intent_fingerprint   = ([string]$IntentFingerprint)
        prepared_fingerprint = ([string]$PreparedFingerprint)
        session_id           = ([string]$SessionId)
        task_id              = ([string]$TaskId)
        agent                = ([string]$Agent)
        executor_calls       = [int]$ExecutorCalls
        intent               = $Intent
    }
}

function New-NDClaimEnvelope {
    <#
    .SYNOPSIS
        Envelope compacto do CLAIM (PR-A). Nunca carrega worker_result.
    .DESCRIPTION
        `claimed=$true` significa apenas que a transicao duravel
        'prepared' -> 'claimed' (DISPATCH_UNCERTAIN) foi persistida ANTES
        da fronteira do efeito. NAO significa que o efeito ocorreu, que
        houve resultado ou que algo foi verificado.
    #>
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [bool]$Admitted = $false,
        [bool]$Claimed = $false,
        [string]$Phase = '',
        [string]$HandoffState = '',
        [string]$IdempotencyKey = '',
        [string]$Reference = '',
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallerAgent = '',
        [string]$TargetAgent = '',
        [string]$IntentFingerprint = '',
        [string]$PreparedFingerprint = '',
        [int]$ExecutorCalls = 0
    )
    return [pscustomobject][ordered]@{
        ok                   = [bool]$Ok
        reason               = ([string]$Reason)
        admitted             = [bool]$Admitted
        claimed              = [bool]$Claimed
        phase                = ([string]$Phase)
        handoff_state        = ([string]$HandoffState)
        idempotency_key      = ([string]$IdempotencyKey)
        reference            = ([string]$Reference)
        session_id           = ([string]$SessionId)
        message_id           = ([string]$MessageId)
        call_id              = ([string]$CallId)
        caller_agent         = ([string]$CallerAgent)
        target_agent         = ([string]$TargetAgent)
        intent_fingerprint   = ([string]$IntentFingerprint)
        prepared_fingerprint = ([string]$PreparedFingerprint)
        executor_calls       = [int]$ExecutorCalls
    }
}
function New-NDSettleEnvelope {
    <#
    .SYNOPSIS
        Envelope compacto do SETTLE (PR-A, fatia 2). Nunca carrega
        worker_result nem conteudo do kernel em recusa.
    .DESCRIPTION
        `settled=$true` afirma apenas que a liquidacao correlacionada foi
        persistida: evidencia canonica + worker-result no kernel + recibo
        'settled' (com a liberacao da reserva de task). NAO afirma
        'verified', 'done' nem 'aprovado': o worker so pode declarar
        candidate_pass|failed|blocked e a verificacao continua sendo etapa
        independente. `duplicate=$true` e a liquidacao identica repetida.
        `reconciled=$true` NAO existe mais no SETTLE: com o reconciliador
        removido, liquidacao parcial de kernel sem escrita do recibo
        devolve `settle-kernel-commit-ambiguous` e permanece 'claimed' -
        reconciliacao e operacao manual do operador. Recusas nao vazam
        worker_status/evidence_id/kernel_reason do registro.
    #>
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [bool]$Admitted = $false,
        [bool]$Settled = $false,
        [bool]$Duplicate = $false,
        [bool]$Reconciled = $false,
        [string]$Phase = '',
        [string]$HandoffState = '',
        [string]$IdempotencyKey = '',
        [string]$Reference = '',
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallerAgent = '',
        [string]$TargetAgent = '',
        [string]$ChildSessionId = '',
        [string]$IntentFingerprint = '',
        [string]$PreparedFingerprint = '',
        [string]$WorkerStatus = '',
        [bool]$EvidenceCreated = $false,
        [string]$EvidenceId = '',
        [bool]$KernelOk = $false,
        [string]$KernelReason = '',
        [int]$ExecutorCalls = 0
    )
    return [pscustomobject][ordered]@{
        ok                   = [bool]$Ok
        reason               = ([string]$Reason)
        admitted             = [bool]$Admitted
        settled              = [bool]$Settled
        duplicate            = [bool]$Duplicate
        reconciled           = [bool]$Reconciled
        phase                = ([string]$Phase)
        handoff_state        = ([string]$HandoffState)
        idempotency_key      = ([string]$IdempotencyKey)
        reference            = ([string]$Reference)
        session_id           = ([string]$SessionId)
        message_id           = ([string]$MessageId)
        call_id              = ([string]$CallId)
        caller_agent         = ([string]$CallerAgent)
        target_agent         = ([string]$TargetAgent)
        child_session_id     = ([string]$ChildSessionId)
        intent_fingerprint   = ([string]$IntentFingerprint)
        prepared_fingerprint = ([string]$PreparedFingerprint)
        worker_status        = ([string]$WorkerStatus)
        evidence_created     = [bool]$EvidenceCreated
        evidence_id          = ([string]$EvidenceId)
        kernel_ok            = [bool]$KernelOk
        kernel_reason        = ([string]$KernelReason)
        executor_calls       = [int]$ExecutorCalls
    }
}
function Invoke-OrchestrationNativeDispatchPrepare {
    <#
    .SYNOPSIS
        PREPARE (PR-A): persiste DURO a tentativa autorizada antes de
        qualquer efeito. Nao executa worker e nao cria store paralelo.
    .DESCRIPTION
        Ordem fixa, toda fail-closed, sem excecao operacional:
           (a) valida a forma do Intent pelo MESMO construtor do caminho
               legado (`New-OrchestrationNativeDispatchIntent`), que nunca
               carrega prompt - so `prompt_hash`;
           (b) valida a FORMA do descritor do host (`Test-NDHostCallDescriptor`),
               apenas sessao neste ponto (message/call ID ainda nao existem);
           (c) resolve a raiz dos recibos e o subdiretorio do goal
               (`Resolve-NDGoalReceiptDir`) com identidade capturada;
           (d) autorizacao viva (`Test-NativeDispatchAuthorization`):
               `explicit_allow` booleano real, source NUNCA test-callback,
               goal nao-terminal e ownership viva com fencing;
           (e) admissao viva do kernel (`Test-NDLiveTaskAdmission`) +
               budget de tentativas (`Test-NDTaskAttemptBudget`);
           (f) lock do recibo (`Open-NDReceiptLock`) e leitura sob lock
               (`Read-NDReceipt -AllowHandoffPhases`);
           (g) revalidacao VIVA sob o lock, na MESMA ordem para recibo existente e
                para recibo novo: admissao do kernel, budget e
                `Test-NDPostLockFencing` (goal EXATAMENTE ACTIVE +
                owner/generation/lease relidos agora). Uma reentrada
                identica so devolve `prepare-reused` DEPOIS dessas
                checagens (F1): com o goal tomado, a lease expirada ou o
                goal fora de ACTIVE, a referencia NAO e devolvida;
           (h) integridade SEMANTICA do registro existente antes de
                reutilizar (`Test-NDReceiptSemanticIntegrity`): Intent
                reconstruido do proprio recibo e fingerprints/referencia
                recalculados; JSON valido com campo adulterado recusa em
                `receipt-integrity-invalid` (F3);
           (i) preparo novo: persiste `prepared` com
               `handoff_state='PREPARED'` sob a identidade reassertada;
               reentrada identica (mesma key + mesmo prepared_fingerprint +
               mesma sessao) e IDEMPOTENTE: devolve a MESMA referencia sem
               reescrever e sem efeito;
           (j) colisao (key existente com fingerprint/sessao divergente),
               fase estranha ('claimed'/'pending'/'settled'), recibo
               corrompido/nao-arquivo/ilegivel ou namespace trocado
               recusam ANTES de qualquer escrita.

        NAO ha Executor: o efeito nativo acontece fora do PowerShell.
        `executor_calls` e sempre 0 e existe so para o chamador provar.

        O retorno e `BLOCKED`-class por construcao: a referencia opaca
        NAO e permissao de execucao. Ela so vincula uma tentativa
        autorizada e duravel ao CLAIM, que e quem consome sob o gate do
        host.

        Nota de escopo (F2): PREPARE NAO cria efeito, por isso nao passa
        pela exclusao de efeito por task - apenas CLAIM e o Invoke
        legado passam. Um preparo duravel nunca e segundo efeito; quem
        governa a fronteira do efeito e o consumo.
    #>
    [CmdletBinding()]
    param(
        $Intent = $null,
        $Authorization = $null,
        [string]$SessionId = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000
    )
    try {
        # (a) forma do Intent - MESMO construtor do caminho legado.
        $realIntent = Get-NDValue $Intent 'intent' $null
        if ($null -eq $realIntent) { $realIntent = $Intent }
        $check = New-OrchestrationNativeDispatchIntent `
            -TaskId ([string](Get-NDValue $realIntent 'task_id' '')) `
            -TaskExpectedRevision ([long](Get-NDValue $realIntent 'task_expected_revision' 0)) `
            -Agent ([string](Get-NDValue $realIntent 'agent' '')) `
            -PromptHash ([string](Get-NDValue $realIntent 'prompt_hash' '')) `
            -Scope @((Get-NDValue $realIntent 'scope' @())) `
            -AcceptanceCriteria @((Get-NDValue $realIntent 'acceptance_criteria' @())) `
            -IdempotencyKey ([string](Get-NDValue $realIntent 'idempotency_key' '')) `
            -Owner ([string](Get-NDValue $realIntent 'owner' '')) `
            -OwnershipGeneration ([long](Get-NDValue $realIntent 'ownership_generation' 0)) `
            -BaseRevision ([string](Get-NDValue $realIntent 'base_revision' '')) `
            -ExternalIdempotent ([bool](Get-NDValue $realIntent 'external_idempotent' $false)) `
            -ExternalIdempotencyProof ([string](Get-NDValue $realIntent 'external_idempotency_proof' ''))
        if (-not [bool](Get-NDValue $check 'ok' $false)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $check 'reason' 'invalid-intent')))
        }
        $intent = Get-NDValue $check 'intent' $null
        $key = ([string](Get-NDValue $intent 'idempotency_key' '')).Trim().ToLowerInvariant()
        # (b) forma do descritor do host: SOMENTE sessao no preparo.
        $desc = Test-NDHostCallDescriptor -SessionId $SessionId
        if (-not [bool](Get-NDValue $desc 'ok' $false)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $desc 'reason' 'host-descriptor-invalid')) -Intent $intent)
        }
        $sessionId = ([string](Get-NDValue $desc 'session_id' ''))
        # (c) raiz + subdiretorio do goal, com identidade capturada.
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return (New-NDPrepareEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -Intent $intent)
        }
        $ndGoalId = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        # (d) autorizacao viva antes de qualquer IO no namespace do goal.
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -Intent $intent -SessionId $sessionId)
        }
        $rState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId $ndGoalId
        $rDir = [string](Get-NDValue $rState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($rDir)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $rState 'reason' 'receipt-dir-unresolvable')) -Admitted $true -Intent $intent -SessionId $sessionId)
        }
        $rIdent = [string](Get-NDValue $rState 'created_utc' '')
        $idWhyPre = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
        if (-not [string]::IsNullOrWhiteSpace($idWhyPre)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason $idWhyPre -Admitted $true -Intent $intent -SessionId $sessionId)
        }
        # (e) fingerprints canonicos do preparo.
        $fingerprint = Get-NDIntentFingerprint -Intent $intent
        if ([string]::IsNullOrWhiteSpace($fingerprint)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason 'intent-fingerprint-failed' -Admitted $true -Intent $intent -SessionId $sessionId)
        }
        $preparedFp = Get-NDPreparedArgumentFingerprint -Intent $intent -SessionId $sessionId
        if ([string]::IsNullOrWhiteSpace($preparedFp)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason 'prepared-fingerprint-failed' -Admitted $true -Intent $intent -SessionId $sessionId)
        }
        $reference = Get-NDHandoffReference -GoalId $ndGoalId -IdempotencyKey $key -PreparedFingerprint $preparedFp
        if ([string]::IsNullOrWhiteSpace($reference)) {
            return (New-NDPrepareEnvelope -Ok $false -Reason 'prepared-reference-failed' -Admitted $true -Intent $intent -SessionId $sessionId)
        }
        $ndOwnerGen = [long](Get-NDValue $intent 'ownership_generation' 0)
        $ndTaskRev = [long](Get-NDValue $intent 'task_expected_revision' 0)
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        $lockWhy = ''
        $lock = Open-NDReceiptLock -Dir $rDir -LockTimeoutMs $LockTimeoutMs -Expected $rIdent -RefusalReason ([ref]$lockWhy)
        if ($null -eq $lock) {
            return (New-NDPrepareEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $lockWhy -Fallback 'lock-busy') -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
        }
        try {
            $idWhyLock = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyLock)) {
                return (New-NDPrepareEnvelope -Ok $false -Reason $idWhyLock -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            # (f) leitura do recibo existente sob o lock.
            $read = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent -AllowHandoffPhases
            $existing = $null
            if (-not [bool](Get-NDValue $read 'ok' $false)) {
                $readWhy = ([string](Get-NDValue $read 'reason' 'receipt-unreadable'))
                if ($readWhy -cne 'receipt-absent') {
                    # Corrompido / nao-arquivo / chave divergente / schema ou
                    # fase desconhecidos: recusa explicita, sem sobrescrever.
                    return (New-NDPrepareEnvelope -Ok $false -Reason $readWhy -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
            }
            else {
                $existing = Get-NDValue $read 'receipt' $null
            }
            if ($null -ne $existing) {
                $exPhase = ([string](Get-NDValue $existing 'phase' '')).Trim().ToLowerInvariant()
                if ($exPhase -ceq 'claimed') {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-already-claimed' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
                if ($exPhase -cne 'prepared') {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-phase-conflict' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
                # Ja preparado: a identidade do registro e conferida ANTES
                # de qualquer reutilizacao (F3).
                $integ = Test-NDReceiptSemanticIntegrity -Receipt $existing -GoalId $ndGoalId -IdempotencyKey $key
                if (-not [bool](Get-NDValue $integ 'ok' $false)) {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'receipt-integrity-invalid' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
                $storedFp = ([string](Get-NDValue $existing 'prepared_fingerprint' '')).Trim().ToLowerInvariant()
                if (([string]::IsNullOrWhiteSpace($storedFp)) -or ($storedFp -cne $preparedFp)) {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-key-collision' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
                $storedSess = ([string](Get-NDValue $existing 'session_id' ''))
                if ($storedSess -cne $sessionId) {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-session-mismatch' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
                $storedRef = ([string](Get-NDValue $existing 'reference' ''))
                if (([string]::IsNullOrWhiteSpace($storedRef)) -or ($storedRef -cne $reference)) {
                    return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-key-collision' -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
                }
            }
            # (g) revalidacao VIVA sob o lock: admissao do kernel, budget de
            #     tentativas e fencing do goal. Roda ANTES de qualquer
            #     retorno que REUTILIZE um preparo existente e ANTES de
            #     persistir um preparo novo (F1). Sem isso a reentrada
            #     identica devolvia a mesma referencia sem reconferir
            #     goal/task vivos, e um preparo novo era persistido sem a
            #     releitura de fencing pos-lock.
            $liveGoal = $null
            try {
                $gidLive = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
                $gslot = Get-OrchestrationGoal -GoalId $gidLive -StoreDir $GoalStoreDir
                if (($null -ne $gslot) -and [bool](Get-NDValue $gslot 'ok' $false)) {
                    $liveGoal = Get-NDValue $gslot 'goal' $null
                }
            }
            catch { $liveGoal = $null }
            $admit = Test-NDLiveTaskAdmission -Intent $intent -Authorization $Authorization -Goal $liveGoal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $admit 'ok' $false)) {
                return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $admit 'reason' 'admission-denied')) -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            $budget = Test-NDTaskAttemptBudget -TaskId ([string](Get-NDValue $intent 'task_id' '')) -TasksDir $TasksDir -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $budget 'ok' $false)) {
                return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $budget 'reason' 'attempt-budget-unknown')) -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            # F1: fencing pos-lock IMEDIATAMENTE antes de reutilizar ou de
            # persistir. O goal tem de continuar EXATAMENTE ACTIVE, com
            # owner+generation+lease vivos, relidos agora sob o lock do
            # recibo. Takeover, lease expirada ou saida de ACTIVE durante a
            # espera recusam sem devolver referencia e sem escrever.
            $fence = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fence 'ok' $false)) {
                return (New-NDPrepareEnvelope -Ok $false -Reason ([string](Get-NDValue $fence 'reason' 'post-lock-fencing-changed')) -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            if ($null -ne $existing) {
                # Identico e ainda valido: nada a escrever. Mesma referencia,
                # mesmo estado.
                return (New-NDPrepareEnvelope -Ok $true -Reason 'prepare-reused' -Admitted $true -Reused $true -Phase 'prepared' -Reference $reference -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -SessionId $sessionId -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')) -Intent $intent)
            }
            # (h) persistencia duravel do preparo.
            $prepared = [ordered]@{
                schema_version = 1
                idempotency_key = $key
                phase = 'prepared'
                handoff_state = 'PREPARED'
                reference = $reference
                task_id = ([string](Get-NDValue $intent 'task_id' ''))
                agent = ([string](Get-NDValue $intent 'agent' ''))
                owner = ([string](Get-NDValue $intent 'owner' ''))
                goal_id = $ndGoalId
                ownership_generation = $ndOwnerGen
                task_expected_revision = $ndTaskRev
                base_revision = ([string](Get-NDValue $intent 'base_revision' ''))
                prompt_hash = ([string](Get-NDValue $intent 'prompt_hash' ''))
                scope = [string[]]@((Get-NDValue $intent 'scope' @()))
                acceptance_criteria = [string[]]@((Get-NDValue $intent 'acceptance_criteria' @()))
                intent_fingerprint = $fingerprint
                prepared_fingerprint = $preparedFp
                session_id = $sessionId
                external_idempotent = [bool](Get-NDValue $intent 'external_idempotent' $false)
                external_idempotency_proof = ([string](Get-NDValue $intent 'external_idempotency_proof' ''))
                prepared_by = $authOwner
                prepared_generation = $authGen
                prepared_at = ([DateTime]::UtcNow.ToString('o'))
            }
            $idWhyWrite = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyWrite)) {
                return (New-NDPrepareEnvelope -Ok $false -Reason $idWhyWrite -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            $writeWhy = ''
            if (-not (Write-NDReceipt -Dir $rDir -Receipt $prepared -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                return (New-NDPrepareEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -Admitted $true -Intent $intent -SessionId $sessionId -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')))
            }
            return (New-NDPrepareEnvelope -Ok $true -Reason '' -Admitted $true -Phase 'prepared' -Reference $reference -IntentFingerprint $fingerprint -PreparedFingerprint $preparedFp -SessionId $sessionId -TaskId ([string](Get-NDValue $intent 'task_id' '')) -Agent ([string](Get-NDValue $intent 'agent' '')) -Intent $intent)
        }
        finally { try { $lock.Dispose() } catch { } }
    }
    catch {
        return (New-NDPrepareEnvelope -Ok $false -Reason 'prepare-internal-error')
    }
}
function Invoke-OrchestrationNativeDispatchClaim {
    <#
    .SYNOPSIS
        CLAIM (PR-A): consome UMA vez o preparo duravel e persiste
        DISPATCH_UNCERTAIN antes da fronteira do efeito. Nao executa
        worker e nao cria store paralelo.
    .DESCRIPTION
        Ordem fixa, toda fail-closed, sem excecao operacional:
           (a) valida a chave (32 hex) e a FORMA do descritor do host
               (`Test-NDHostCallDescriptor -RequireCallIdentity`:
               sessionID, messageID e callID) e dos agentes
               (`Test-NDHostAgentName` para caller e target);
           (b) autorizacao viva (`Test-NativeDispatchAuthorization`);
           (b2) leitura PREVIA do proprio recibo, usada SOMENTE para
               nomear o lock de task (a ordem estavel de locks e
               task -> recibo): recibo ausente, corrupto ou nao-arquivo
               recusa aqui com a MESMA razao que a leitura sob lock daria,
               sem lock e sem efeito;
           (c) lock de TASK na raiz dos recibos (F2: exclusao de efeito por
               task, compartilhada com o Invoke legado; ordem unica
               task -> recibo) + lock do recibo;
           (d) SO a fase 'prepared' e consumivel. 'claimed' (duplicata ou
               replay com nova identidade de chamada) recusa em
               `claim-already-consumed`; 'pending'/'settled' (legado)
               recusam em `claim-phase-conflict`; ausente recusa em
               `claim-not-prepared`; corrompido/nao-arquivo/ilegivel
               propagam a razao explicita sem sobrescrever. O task_id do
               registro tem de ser o MESMO da leitura previa
               (`claim-task-lock-mismatch`), senao o lock segurado seria
               o de outra task;
           (e0) integridade SEMANTICA do registro
                (`Test-NDReceiptSemanticIntegrity`): o Intent e RECONSTRUIDO
                do proprio recibo, e intent_fingerprint/prepared_fingerprint/
                reference sao RECALCULADOS e comparados campo a campo com o
                persistido. JSON valido com campo semantico adulterado e
                hash intacto recusa em `receipt-integrity-invalid` (F3);
           (e) vinculacao ao registro duravel: prepared_fingerprint,
               sessao, task, agente alvo e identidade
               goal/owner/generation tem de bater EXATAMENTE com o
               preparo. Divergencia recusa sem tocar no recibo;
           (f) admissao viva (`Test-NDLiveTaskAdmission`) sobre a visao de
               Intent reconstruida DO RECIBO (`Get-NDReceiptIntentView`,
               nunca de input do chamador) + budget;
           (f2) exclusao de efeito por task
                (`Test-NDTaskEffectExclusive`): OUTRO recibo da MESMA
                task - em QUALQUER namespace de goal sob a MESMA raiz,
                qualquer chave, qualquer revisao, qualquer generation -
                ainda nao-resolvido ('claimed' do handoff ou 'pending' do
                legado) impede um segundo efeito
                (`claim-task-already-claimed`); varredura incremental,
                limitada e fail-closed, sob o lock de task da raiz e o lock
                do recibo (F2);
           (f3) fencing pos-lock (`Test-NDPostLockFencing`): IMEDIATAMENTE
                antes da escrita do recibo, o goal e relido e tem de
                continuar EXATAMENTE ACTIVE com owner+generation+lease
                vivos. Takeover, lease expirada ou goal fora de ACTIVE
                durante a espera pelo lock recusam sem consumir (F1);
           (g) transicao UNICA 'prepared' -> 'claimed' com
               `handoff_state='DISPATCH_UNCERTAIN'`, preservando todos os
               campos do preparo e registrando a linhagem do host
               (sessao/mensagem/call/caller/target);
           (h) `claimed=$true` no envelope significa apenas que a
               transicao duravel foi persistida ANTES do efeito. NAO
               afirma que o efeito ocorreu, que houve resultado, ou que
               algo foi verificado.

        NAO ha Executor nem replay automatico: um recibo 'claimed' nunca
        e reexecutado por esta operacao. `executor_calls` e sempre 0.

        CONFIANCA NO DESCRITOR: a identidade do evento do host precisa
        ser obtida de forma INDEPENDENTE pelo hospedeiro (plugin/hook da
        sessao real). Este helper NAO consegue autenticar um descritor
        fornecido; a conferencia abaixo e vinculacao de estado, nao
        prova de autoria. Sem provenance independente, o resultado
        continua sendo claim nao verificado.
    #>
    [CmdletBinding()]
    param(
        [string]$IdempotencyKey = '',
        $Authorization = $null,
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallerAgent = '',
        [string]$TargetAgent = '',
        [string]$PreparedFingerprint = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000,
        # G1-B (opt-in): escrever o admission file sob os MESMOS locks. Sem
        # este switch o CLAIM segue EXATAMENTE como antes.
        [switch]$EmitAdmission,
        [int]$AdmissionTtlSeconds = 3600,
        [string]$AdmissionModel = '',
        [string]$AdmissionProvider = ''
    )
    try {
        # (a) chave + forma do descritor do host.
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDClaimEnvelope -Ok $false -Reason 'invalid-idempotency-key')
        }
        $desc = Test-NDHostCallDescriptor -SessionId $SessionId -MessageId $MessageId -CallId $CallId -RequireCallIdentity
        if (-not [bool](Get-NDValue $desc 'ok' $false)) {
            return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $desc 'reason' 'host-descriptor-invalid')) -IdempotencyKey $key)
        }
        $sessionId = ([string](Get-NDValue $desc 'session_id' ''))
        $messageId = ([string](Get-NDValue $desc 'message_id' ''))
        $callId = ([string](Get-NDValue $desc 'call_id' ''))
        $callerChk = Test-NDHostAgentName -Agent $CallerAgent
        if (-not [bool](Get-NDValue $callerChk 'ok' $false)) {
            return (New-NDClaimEnvelope -Ok $false -Reason 'host-caller-agent-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId)
        }
        $callerAgent = ([string](Get-NDValue $callerChk 'agent' ''))
        $targetChk = Test-NDHostAgentName -Agent $TargetAgent
        if (-not [bool](Get-NDValue $targetChk 'ok' $false)) {
            return (New-NDClaimEnvelope -Ok $false -Reason 'host-target-agent-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent)
        }
        $targetAgent = ([string](Get-NDValue $targetChk 'agent' ''))
        $claimFp = ([string]$PreparedFingerprint).Trim().ToLowerInvariant()
        if ($claimFp -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDClaimEnvelope -Ok $false -Reason 'invalid-prepared-fingerprint' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        # (b) raiz + autorizacao viva antes de qualquer IO no namespace.
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDClaimEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return (New-NDClaimEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        # F2: identidade da RAIZ dos recibos, usada pelo lock de task e pela
        # varredura de exclusao. '' (creation time ilegivel) degrada para as
        # checagens de existencia/Container/reparse, nunca para confianca.
        $rootIdent = Get-NDDirCreationTimeUtcTicks -Path $dir
        $ndGoalId = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $rState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId $ndGoalId
        $rDir = [string](Get-NDValue $rState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($rDir)) {
            return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $rState 'reason' 'receipt-dir-unresolvable')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $rIdent = [string](Get-NDValue $rState 'created_utc' '')
        $idWhyPre = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
        if (-not [string]::IsNullOrWhiteSpace($idWhyPre)) {
            return (New-NDClaimEnvelope -Ok $false -Reason $idWhyPre -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        # F2: o CLAIM nao recebe task_id do chamador - ele vem do registro
        # duravel. A ordem estavel de locks (task -> recibo) exige conhecer
        # o task_id ANTES do lock do recibo, entao esta leitura PREVIA
        # existe somente para NOMEAR o lock de task: ela nao decide nada
        # (a leitura autoritativa e a de baixo do lock) e devolve a MESMA
        # recusa que a leitura sob lock daria. Recibo ausente, corrupto ou
        # nao-arquivo recusa aqui sem efeito e sem lock.
        $preRead = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent -AllowHandoffPhases
        $preTaskId = ''
        if (-not [bool](Get-NDValue $preRead 'ok' $false)) {
            $preWhy = ([string](Get-NDValue $preRead 'reason' 'receipt-unreadable'))
            if ($preWhy -ceq 'receipt-absent') { $preWhy = 'claim-not-prepared' }
            return (New-NDClaimEnvelope -Ok $false -Reason $preWhy -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $preReceipt = Get-NDValue $preRead 'receipt' $null
        if ($null -eq $preReceipt) {
            return (New-NDClaimEnvelope -Ok $false -Reason 'claim-not-prepared' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $preTaskId = ([string](Get-NDValue $preReceipt 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($preTaskId)) {
            return (New-NDClaimEnvelope -Ok $false -Reason 'claim-task-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        # F2: lock de task na RAIZ antes do lock do recibo (ordem unica,
        # compartilhada com o Invoke legado). Contencao real devolve
        # 'task-lock-busy'; identidade/reparse devolvem motivo especifico.
        $taskLockWhy = ''
        $taskLock = Open-NDTaskLock -RootDir $dir -TaskId $preTaskId -LockTimeoutMs $LockTimeoutMs -RootExpected $rootIdent -RefusalReason ([ref]$taskLockWhy)
        if ($null -eq $taskLock) {
            return (New-NDClaimEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $taskLockWhy -Fallback 'task-lock-busy') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $lockWhy = ''
        $lock = Open-NDReceiptLock -Dir $rDir -LockTimeoutMs $LockTimeoutMs -Expected $rIdent -RefusalReason ([ref]$lockWhy)
        if ($null -eq $lock) {
            try { $taskLock.Dispose() } catch { }
            return (New-NDClaimEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $lockWhy -Fallback 'lock-busy') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        try {
            $idWhyLock = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyLock)) {
                return (New-NDClaimEnvelope -Ok $false -Reason $idWhyLock -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # (c) leitura do recibo sob o lock.
            $read = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent -AllowHandoffPhases
            if (-not [bool](Get-NDValue $read 'ok' $false)) {
                $readWhy = ([string](Get-NDValue $read 'reason' 'receipt-unreadable'))
                if ($readWhy -ceq 'receipt-absent') { $readWhy = 'claim-not-prepared' }
                return (New-NDClaimEnvelope -Ok $false -Reason $readWhy -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $existing = Get-NDValue $read 'receipt' $null
            if ($null -eq $existing) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-not-prepared' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # (d) SO 'prepared' e consumivel. Sem replay de consumido.
            $exPhase = ([string](Get-NDValue $existing 'phase' '')).Trim().ToLowerInvariant()
            if ($exPhase -ceq 'claimed') {
                # G1-B-FIX reparo idempotente (OPT-IN, round-3 endurecido):
                # um CLAIM anterior pode ter persistido o recibo mas falhado
                # ao gravar o admission pos-commit. O reparo REGENERA o
                # arquivo SOMENTE quando: (a) o admission esta AUSENTE
                # (ausencia comprovada - nunca renova autorizacao existente);
                # (b) o binding e IDENTICO ao gravado (sessao, chamada,
                # agentes, fingerprint); (c) owner+generation ATUAIS conferem
                # com os GRAVADOS no recibo (takeover nao reautoriza claim
                # antigo - 'claim-identity-mismatch'); (d) o escopo de
                # restricao (model/provider/ttl) vem DO RECIBO gravado no
                # CLAIM, nunca dos argumentos do retry (retry nao afrouxa
                # nem troca restricao); (e) o fencing vivo confere. Sem
                # -EmitAdmission este bloco nao existe.
                if ($EmitAdmission) {
                    $repFp = ([string](Get-NDValue $existing 'prepared_fingerprint' '')).Trim().ToLowerInvariant()
                    $repSess = ([string](Get-NDValue $existing 'claim_session_id' ''))
                    $repMsg = ([string](Get-NDValue $existing 'claim_message_id' ''))
                    $repCall = ([string](Get-NDValue $existing 'claim_call_id' ''))
                    $repCaller = ([string](Get-NDValue $existing 'claim_caller_agent' ''))
                    $repTarget = ([string](Get-NDValue $existing 'claim_target_agent' ''))
                    $repTask = ([string](Get-NDValue $existing 'task_id' '')).Trim()
                    $repRef = ([string](Get-NDValue $existing 'reference' ''))
                    $repIntentFp = ([string](Get-NDValue $existing 'intent_fingerprint' '')).Trim().ToLowerInvariant()
                    $repOwner = ([string](Get-NDValue $existing 'owner' '')).Trim()
                    $repGen = [long](Get-NDValue $existing 'ownership_generation' 0)
                    if ((($repFp -ceq $claimFp) -and ($repSess -ceq $sessionId) -and ($repMsg -ceq $messageId) -and ($repCall -ceq $callId) -and ($repCaller -ceq $callerAgent) -and ($repTarget -ceq $targetAgent) -and (-not [string]::IsNullOrWhiteSpace($repTask)) -and ($repOwner -ceq $authOwner) -and ($repGen -eq $authGen))) {
                        $repDirState = Get-NDAdmissionDir -RootDir $dir -GoalId $ndGoalId
                        if ([bool](Get-NDValue $repDirState 'ok' $false)) {
                            $repDir = [string](Get-NDValue $repDirState 'dir' '')
                            $repIdent = [string](Get-NDValue $repDirState 'ident' '')
                            # Ausencia COMPROVADA: o caminho nao pode existir
                            # em nenhuma forma (ausente, malformado, vazio,
                            # ilegivel). Arquivo existente - mesmo invalido -
                            # nunca e "reparado" com novo prazo: retry cai em
                            # claim-already-consumed e a autorizacao gravada
                            # (ou sua ausencia) prevalece.
                            $repPath = Get-NDAdmissionPath -AdmissionDir $repDir -Key $key
                            if (([string]::IsNullOrWhiteSpace($repPath)) -or (Test-Path -LiteralPath $repPath)) {
                                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-already-consumed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
                            }
                                $repFence = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
                                if ([bool](Get-NDValue $repFence 'ok' $false)) {
                                    $repScopeModel = Get-NDValue $existing 'admission_allowed_model' $null
                                    $repScopeProvider = Get-NDValue $existing 'admission_allowed_provider' $null
                                    $repScopeTtl = Get-NDValue $existing 'admission_ttl_seconds' $null
                                    if ((($null -ne $repScopeModel) -and ($null -ne $repScopeProvider) -and ($null -ne $repScopeTtl))) {
                                        $repGoalState = ''
                                        try {
                                            $repG = Get-OrchestrationGoal -GoalId $ndGoalId -StoreDir $GoalStoreDir
                                            if (($null -ne $repG) -and [bool](Get-NDValue $repG 'ok' $false)) {
                                                $repGoalState = ([string](Get-NDValue (Get-NDValue $repG 'goal' $null) 'state' '')).Trim().ToUpperInvariant()
                                            }
                                        }
                                        catch { $repGoalState = '' }
                                        $repRec = New-NDAdmissionRecord -IdempotencyKey $key -GoalId $ndGoalId -TaskId $repTask -SessionId $sessionId -CallId $callId -Agent $targetAgent -Owner $authOwner -Generation $authGen -GoalState $repGoalState -TtlSeconds ([int]$repScopeTtl) -AllowedModel ([string]$repScopeModel) -AllowedProvider ([string]$repScopeProvider)
                                        if (($null -ne $repRec) -and (Write-NDAdmissionRecord -AdmissionDir $repDir -Ident $repIdent -Key $key -Record $repRec -FailIfExists)) {
                                            return (New-NDClaimEnvelope -Ok $true -Reason '' -Admitted $true -Claimed $true -Phase 'claimed' -HandoffState 'DISPATCH_UNCERTAIN' -IdempotencyKey $key -Reference $repRef -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -IntentFingerprint $repIntentFp -PreparedFingerprint $repFp)
                                        }
                                        return (New-NDClaimEnvelope -Ok $false -Reason 'claim-admission-write-failed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $repRef -IntentFingerprint $repIntentFp -PreparedFingerprint $repFp)
                                    }
                                }
                            }
                        }
                    return (New-NDClaimEnvelope -Ok $false -Reason 'claim-already-consumed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
                }
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-already-consumed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            if ($exPhase -cne 'prepared') {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-phase-conflict' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # (e0) integridade SEMANTICA do registro antes de usa-lo (F3):
            #      conferir so os hashes deixa passar JSON valido com campo
            #      semantico adulterado. RECONSTROI o Intent do proprio
            #      recibo e recalcula intent/prepared/reference.
            $integ = Test-NDReceiptSemanticIntegrity -Receipt $existing -GoalId $ndGoalId -IdempotencyKey $key
            if (-not [bool](Get-NDValue $integ 'ok' $false)) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'receipt-integrity-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # (e) vinculacao ao registro duravel do preparo.
            $storedFp = ([string](Get-NDValue $existing 'prepared_fingerprint' '')).Trim().ToLowerInvariant()
            if (([string]::IsNullOrWhiteSpace($storedFp)) -or ($storedFp -cne $claimFp)) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-fingerprint-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $storedSess = ([string](Get-NDValue $existing 'session_id' ''))
            if ($storedSess -cne $sessionId) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-session-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $storedAgent = ([string](Get-NDValue $existing 'agent' ''))
            if (($storedAgent -cne $targetAgent) -or ($callerAgent -ceq $targetAgent)) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-agent-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $storedTask = ([string](Get-NDValue $existing 'task_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($storedTask)) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-task-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # F2: o lock de task foi nomeado pela leitura previa; sob o lock
            # do recibo, o task_id do registro tem de ser o MESMO. Divergencia
            # significa que o registro mudou entre as duas leituras - recusa
            # fail-closed, porque o lock segurado seria o de outra task.
            if ($storedTask -cne $preTaskId) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-task-lock-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $storedOwner = ([string](Get-NDValue $existing 'owner' '')).Trim()
            $storedGen = [long](Get-NDValue $existing 'ownership_generation' 0)
            $storedGoal = ([string](Get-NDValue $existing 'goal_id' '')).Trim()
            if ((($storedGoal -cne $ndGoalId) -or ($storedOwner -cne $authOwner) -or ($storedGen -ne $authGen))) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-identity-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $storedIntentFp = ([string](Get-NDValue $existing 'intent_fingerprint' '')).Trim().ToLowerInvariant()
            $reference = ([string](Get-NDValue $existing 'reference' ''))
            # (f) admissao viva sobre a visao de Intent DO RECIBO.
            $intentView = Get-NDReceiptIntentView -Receipt $existing
            if ($null -eq $intentView) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-receipt-unusable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $liveGoal = $null
            try {
                $gslot = Get-OrchestrationGoal -GoalId $ndGoalId -StoreDir $GoalStoreDir
                if (($null -ne $gslot) -and [bool](Get-NDValue $gslot 'ok' $false)) {
                    $liveGoal = Get-NDValue $gslot 'goal' $null
                }
            }
            catch { $liveGoal = $null }
            $admit = Test-NDLiveTaskAdmission -Intent $intentView -Authorization $Authorization -Goal $liveGoal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $admit 'ok' $false)) {
                return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $admit 'reason' 'admission-denied')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $budget = Test-NDTaskAttemptBudget -TaskId $storedTask -TasksDir $TasksDir -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $budget 'ok' $false)) {
                return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $budget 'reason' 'attempt-budget-unknown')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (f2) exclusao de efeito por task (F2): OUTRO recibo da MESMA
            #      task - em QUALQUER namespace de goal sob a MESMA raiz,
            #      qualquer chave, qualquer revisao, qualquer generation -
            #      ainda nao-resolvido ('claimed' do handoff ou 'pending' do
            #      legado) impede um segundo efeito. Varredura incremental,
            #      limitada e fail-closed, sob o lock de task da raiz e o lock
            #      do recibo; nada de segundo store.
            $slot = Test-NDTaskEffectExclusive -RootDir $dir -TaskId $storedTask -SkipGoalId $ndGoalId -SkipKey $key -RootExpected $rootIdent
            if (-not [bool](Get-NDValue $slot 'ok' $false)) {
                return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $slot 'reason' 'claim-task-already-claimed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (f3) fencing pos-lock (F1): IMEDIATAMENTE antes da escrita do
            #      recibo, o goal e relido e tem de continuar EXATAMENTE
            #      ACTIVE com owner+generation+lease vivos. Takeover, lease
            #      expirada ou goal fora de ACTIVE durante a espera pelo
            #      lock recusam sem consumir o preparo.
            $fence = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fence 'ok' $false)) {
                return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $fence 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (g) transicao UNICA preparado -> claimed (DISPATCH_UNCERTAIN).
            $claimExtra = [ordered]@{
                handoff_state = 'DISPATCH_UNCERTAIN'
                claim_session_id = $sessionId
                claim_message_id = $messageId
                claim_call_id = $callId
                claim_caller_agent = $callerAgent
                claim_target_agent = $targetAgent
                claim_prepared_fingerprint = $storedFp
                claimed_by = $authOwner
                claimed_generation = $authGen
                claimed_at = ([DateTime]::UtcNow.ToString('o'))
            }
            $claimed = Convert-NDReceiptToPhase -Receipt $existing -Phase 'claimed' -Extra $claimExtra
            if ($null -eq $claimed) {
                return (New-NDClaimEnvelope -Ok $false -Reason 'claim-receipt-unusable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            # G1-B-FIX escopo do admission GRAVADO no recibo (OPT-IN): o
            # reparo idempotente do ramo 'claimed' reutiliza EXATAMENTE
            # este escopo - retry nunca afrouxa nem troca restricao.
            if ($EmitAdmission) {
                $claimed['admission_allowed_model'] = ([string]$AdmissionModel)
                $claimed['admission_allowed_provider'] = ([string]$AdmissionProvider)
                $claimed['admission_ttl_seconds'] = [int]$AdmissionTtlSeconds
            }
            # (g2) G1-B (OPT-IN): admission file do despacho. ORDEM
            #      POS-COMMIT (G1-B-FIX): o diretorio e resolvido aqui
            #      (falha recusa ANTES de qualquer escrita duravel), mas o
            #      admission so e GRAVADO DEPOIS do commit do recibo
            #      'claimed'. Admission nunca existe sem CLAIM duravel:
            #      queda entre as escritas deixa 'claimed' sem admission
            #      (plugin nega por ausencia) e o retry com binding
            #      identico regenera via ramo 'claimed' acima. Sem
            #      -EmitAdmission este bloco nao existe e o CLAIM fica
            #      byte-a-byte como era.
            $admDirState = $null
            $admIdent = ''
            $admDir = ''
            if ($EmitAdmission) {
                $admDirState = Get-NDAdmissionDir -RootDir $dir -GoalId $ndGoalId
                if (-not [bool](Get-NDValue $admDirState 'ok' $false)) {
                    return (New-NDClaimEnvelope -Ok $false -Reason ([string](Get-NDValue $admDirState 'reason' 'claim-admission-write-failed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $admDir = [string](Get-NDValue $admDirState 'dir' '')
                $admIdent = [string](Get-NDValue $admDirState 'ident' '')
            }
            $idWhyClaim = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyClaim)) {
                return (New-NDClaimEnvelope -Ok $false -Reason $idWhyClaim -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
            }
            $writeWhy = ''
            if (-not (Write-NDReceipt -Dir $rDir -Receipt $claimed -Expected $rIdent -RefusalReason ([ref]$writeWhy))) {
                return (New-NDClaimEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $writeWhy -Fallback 'receipt-write-failed') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (g3) pos-commit: grava o admission SOMENTE com CLAIM duravel.
            #      Falha aqui nao desfaz o CLAIM (recibo ja 'claimed'):
            #      devolve 'claim-admission-write-failed' e o retry com
            #      binding identico regenera (ramo 'claimed'). O plugin,
            #      com OPENCODE_G1_RECEIPT_FILE, nega de qualquer forma
            #      enquanto o recibo nao estiver 'claimed'.
            if ($EmitAdmission) {
                $admGoalState = ''
                try {
                    $gAdm = Get-OrchestrationGoal -GoalId $ndGoalId -StoreDir $GoalStoreDir
                    if (($null -ne $gAdm) -and [bool](Get-NDValue $gAdm 'ok' $false)) {
                        $admGoalState = ([string](Get-NDValue (Get-NDValue $gAdm 'goal' $null) 'state' '')).Trim().ToUpperInvariant()
                    }
                }
                catch { $admGoalState = '' }
                $admRec = New-NDAdmissionRecord -IdempotencyKey $key -GoalId $ndGoalId -TaskId $storedTask -SessionId $sessionId -CallId $callId -Agent $targetAgent -Owner $authOwner -Generation $authGen -GoalState $admGoalState -TtlSeconds $AdmissionTtlSeconds -AllowedModel $AdmissionModel -AllowedProvider $AdmissionProvider
                if (($null -eq $admRec) -or (-not (Write-NDAdmissionRecord -AdmissionDir $admDir -Ident $admIdent -Key $key -Record $admRec))) {
                    return (New-NDClaimEnvelope -Ok $false -Reason 'claim-admission-write-failed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
            }
            return (New-NDClaimEnvelope -Ok $true -Reason '' -Admitted $true -Claimed $true -Phase 'claimed' -HandoffState 'DISPATCH_UNCERTAIN' -IdempotencyKey $key -Reference $reference -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
        }
        # F2: locks soltos na ordem inversa da aquisicao (recibo -> task).
        finally {
            try { $lock.Dispose() } catch { }
            try { $taskLock.Dispose() } catch { }
        }
    }
    catch {
        return (New-NDClaimEnvelope -Ok $false -Reason 'claim-internal-error')
    }
}
# FRAGMENT BUILD (temporary)
function Write-NDSettleEvidence {
    <#
    .SYNOPSIS
        Escreve (ou reencontra) a evidencia canonica de UM settle de
        handoff nativo (PR-A, fatia 2). Deterministica.
    .DESCRIPTION
        Compartilhada pelo caminho normal e pelo caminho de retentativa
        parcial (prova kernel-side), para que a retentativa rederive o
        MESMO evidence_id e nunca orfe uma linha. O material e derivado de
        (recibo, chamada do host, sessao filha, candidato) e o created_at
        vem do CLAIM persistido - nada de relogio current, nada de dado
        fornecidos pelo modelo alem dos IDs de forma ja validada.

        Provenance + source_fingerprints carregam a chamada do host
        (sessao/mensagem/call/caller/target) e a sessao FILHA, para que a
        evidencia responda "de qual chamada e de qual child session" sem
        consultar o recibo.

        Retorna @{ok, reason, id}. Falha ao criar devolve ok=$false com
        razao explicita; NUNCA lanca.
    #>
    [CmdletBinding()]
    param(
        $Receipt = $null,
        [string]$TaskId = '',
        [string]$Key = '',
        [string]$TargetAgent = '',
        [string]$Status = '',
        [string[]]$ClaimedEvidence = @(),
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallerAgent = '',
        [string]$ChildSession = '',
        [string]$StoreDir = ''
    )
    $out = [pscustomobject]@{ ok = $false; reason = 'settle-evidence-failed'; id = '' }
    try {
        if ($null -eq $Receipt) { return $out }
        $tid = ([string]$TaskId).Trim()
        $k = ([string]$Key).Trim().ToLowerInvariant()
        $agent = ([string]$TargetAgent).Trim()
        if (([string]::IsNullOrWhiteSpace($tid)) -or ($k -cnotmatch '^[a-f0-9]{32}$')) { return $out }
        if ([string]::IsNullOrWhiteSpace($agent)) { return $out }
        $sd = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($sd)) { return $out }
        $evCmd = Get-Command New-OrchestrationEvidenceRecord -ErrorAction SilentlyContinue
        if ($null -eq $evCmd) { return $out }
        $createdAt = ([string](Get-NDValue $Receipt 'claimed_at' ''))
        if ([string]::IsNullOrWhiteSpace($createdAt)) { $createdAt = ([DateTime]::UtcNow.ToString('o')) }
        $evInput = [ordered]@{
            task_id = $tid
            run_id  = $k
            worker_id = $agent
            provenance = @{ created_by = $agent; kernel_task_ref = $tid }
            base_revision = ([string](Get-NDValue $Receipt 'base_revision' ''))
            criteria_hash = (Get-NativeDispatchHash32 ((@($ClaimedEvidence) -join ',')))
            source_fingerprints = @{
                'dispatch-intent' = $k
                'native-handoff-session' = ([string]$SessionId)
                'native-handoff-message' = ([string]$MessageId)
                'native-handoff-call' = ([string]$CallId)
                'native-handoff-caller-agent' = ([string]$CallerAgent)
                'native-handoff-target-agent' = $agent
                'native-handoff-child-session' = ([string]$ChildSession)
            }
            diff_hash = ''
            scope = @((Get-NDValue $Receipt 'scope' @()))
            command = 'native-dispatch-settle'
            environment = @{ runtime = 'native-dispatch'; version = '1' }
            result = @{ summary = ('worker:' + [string]$Status); raw_ref = ('native-handoff:' + $k) }
            assumptions = @()
            invalidation_conditions = @( @{ type = 'base-revision'; require_same = $true } )
            created_at = $createdAt
        }
        $evSlot = New-OrchestrationEvidenceRecord -Evidence $evInput -StoreDir $sd
        if (($null -ne $evSlot) -and [bool](Get-NDValue $evSlot 'created' $false) -and ($null -ne (Get-NDValue $evSlot 'record' $null))) {
            $rid = ([string](Get-NDValue (Get-NDValue $evSlot 'record' $null) 'evidence_id' ''))
            if (-not [string]::IsNullOrWhiteSpace($rid)) {
                return [pscustomobject]@{ ok = $true; reason = ''; id = $rid }
            }
        }
        return [pscustomobject]@{ ok = $false; reason = ([string](Get-NDValue $evSlot 'reason' 'settle-evidence-failed')); id = '' }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'settle-evidence-failed'; id = '' }
    }
}

function Invoke-OrchestrationNativeDispatchSettle {
    <#
    .SYNOPSIS
        SETTLE (PR-A, fatia 2): liquida UM handoff nativo ja CLAIMED com
        resultado candidato correlacionado. Nao executa worker, nao cria
        store paralelo e nao inventa verificacao.
    .DESCRIPTION
        Ordem fixa, toda fail-closed, sem excecao operacional:
          (a) chave (32 hex), FORMA do descritor do host da liquidacao
              (sessao/mensagem/call) e dos agentes (caller/target);
          (b) child session id (forma apenas) e forma do resultado
              candidato (`Test-OrchestrationDispatchResultShape`: somente
              candidate_pass|failed|blocked, refs criterion:<idx>) -
              verified_pass/done/aprovado NUNCA entram por aqui;
          (c) raiz dos recibos + autorizacao viva
              (`Test-NativeDispatchAuthorization`);
          (d) leitura PREVIA do proprio recibo, usada SOMENTE para nomear
              o lock de task (ordem unica task -> recibo);
          (e) lock de TASK na raiz + lock do recibo (a OPERACAO inteira
              segue sob os dois locks, na mesma ordem do CLAIM). Com os
              DOIS locks segurados, a ownership viva e REVALIDADA
              (`Test-NDPostLockFencing`) antes de qualquer decisao de
              liquidacao (F3);
          (f) leitura autoritativa sob lock: SOMENTE 'claimed' e
              liquidavel. 'prepared' => settle-not-claimed; 'pending'
              (legado) => settle-phase-conflict; ausente =>
              settle-not-claimed; 'settled' => caminho de duplicata;
          (g) integridade SEMANTICA do registro
              (`Test-NDReceiptSemanticIntegrity`, F3);
          (h) vinculacao EXATA ao registro duravel: prepared_fingerprint,
              reference (quando fornecida), goal/owner/generation e
              task/agente alvo. A linhagem do host do CLAIM
              (sessao/mensagem/call/caller/target) tem de ser EXATAMENTE a
              mesma chamada que consumiu o preparo: cross-session e
              cross-call recusam. O child session id tem de ser uma
              sessao DISTINTA da sessao pai;
          (i) duplicata 'settled': identidade viva ou turnaround COM prova
              kernel-side (`Test-NDDuplicateReadIdentity`) + worker_result
              persistido identico campo a campo. Identico => idempotente
              (settle-duplicate, 0 escrita); divergente =>
              settle-result-conflict;
          (j) revalidacao VIVA sob o lock: gate de ambiguidade de commit
              (abaixo), admissao do kernel
              (`Test-NDLiveTaskAdmission` sobre a visao de Intent
              RECONSTRUIDA do recibo), budget de tentativas e fencing
              (`Test-NDPostLockFencing`);
          (k) marcador de tentativa no proprio recibo (fase continua
              'claimed'): o candidato apresentado fica registrado ANTES da
              primeira escrita de liquidacao, no mesmo espirito do
              'pending' do caminho legado. Tentativa posterior com
              candidato DIVERGENTE para a mesma claim e conflito, nunca
              sobrescrita silenciosa;
          (l) evidencia canonica (`New-OrchestrationEvidenceRecord`) com
              provenance + source_fingerprints vinculando a chamada do
              host e a sessao filha. O material e deterministico para
              (claim instant, chamada do host, child session, candidato),
              entao a retentativa deriva o MESMO evidence_id e nao orfa
              linha;
          (m) kernel (`Set-OrchestrationTaskWorkerResult`) com CAS na
              revisao esperada do recibo. NAO existe reconciliador dentro
              desta operacao: status/refs iguais e revisao avancada nao
              provam que ESTA chamada escreveu o kernel, e esta fatia nao
              tem marcador atomico de liquidacao do lado do kernel (sem
              mudanca de schema/API do TaskKernel);
          (n) transicao 'claimed' -> 'settled' com handoff_state
              'SETTLED'. Essa escrita E a liberacao da reserva de task
              (F2): nao existe registro de reserva separado - a varredura
              `Test-NDTaskEffectExclusive` deixa de bloquear quando o
              unico recibo nao-resolvido da task passa a 'settled'.
        ESCRITA PARCIAL (honesta, sem retry implicito):
          - evidencia feita e kernel recusando => recibo CONTINUA
            'claimed'/DISPATCH_UNCERTAIN, reserva mantida, motivo
            settle-kernel-refused:*;
          - kernel gravado e escrita do recibo: o retorno de
            Write-NDReceipt NAO decide sozinho, em nenhum dos dois
            sentidos. $false nao prova que nada foi gravado (a prova
            pos-escrita do escritor pode falhar DEPOIS de o arquivo
            'settled' ja ter sido movido para o destino) e $true nao
            prova que o disco contem o registro EXATO (o destino pode ser
            alterado depois do Move e a prova do escritor so confirma que
            o arquivo existe e contem a chave). Em AMBOS os casos o
            registro e RELIDO sob os dois locks e comparado campo a campo
            com o recibo 'settled' EXATO (Test-NDSettledReceiptPersisted,
            que ja embute a forma crua dos campos de liquidacao). Prova
            exata => a liquidacao de fato ocorreu e a resposta e settled;
            sem prova exata => settle-receipt-proof-*, estado
            EXPLICITAMENTE incerto (nao se afirma que o recibo continua
            'claimed' nem que a liquidacao ocorreu) e a reserva NAO e
            liberada. Se o recibo continua 'claimed', a retentativa NAO
            conclui sozinha: com a revisao da task ja avancada alem da
            esperada do recibo, a retentativa cai no COMMIT AMBIGUO abaixo.
            Nunca reexecuta o kernel por adivinhacao e nunca libera a
            reserva sem prova;
          - COMMIT AMBIGUO (F1/F2/PRA-SETTLE-FIX2): um worker_result com
            revisao da task AVANCADA ALEM da revisao esperada do recibo
            (escrita pos-claim) e candidato a commit parcial. Como esta
            fatia nao tem marcador atomico de liquidacao do lado do
            kernel, nao ha prova CAUSAL que amarre a escrita no kernel a
            ESTE claim: status/refs iguais e revisao avancada provam
            coincidencia, nunca autoria. NUNCA se
            cria evidencia para provar escrita anterior e NUNCA se
            reescreve o kernel. O estado devolvido e o tipado
            `settle-kernel-commit-ambiguous`: recibo claimed/reserved
            mantido, sem liquidacao, sem release e sem retry. E um
            bloqueio SEGURO de disponibilidade - a reconciliacao, se
            houver, e operacao manual do operador, nunca automatica.
            Um worker_result com revisao <= esperada e HISTORICO (outra
            tentativa/claim): nao conflita so por status/refs divergentes
            e nao bloqueia tentativa nova - o CAS sobrescreve
            legitimamente. Revisao avancada alem da esperada SEM
            worker_result (transicao/verificacao por outra via) nao e
            commit parcial: a admissao viva recusa deterministicamente
            com task-revision-mismatch;
          - fencing pos-lock (F3): a ownership viva e revalidada LOGO
            depois de adquirir os dois locks (antes de qualquer decisao)
            e IMEDIATAMENTE ANTES de cada escrita de recibo de
            liquidacao (marcador de tentativa, marcador de evidencia,
            'settled') e da escrita do worker-result no kernel. Goal
            EXATAMENTE ACTIVE + owner/generation/lease vivos em todas
            elas; takeover/expiracao/terminalizacao recusa e mantem
            'claimed' com a reserva. LIMITE HONESTO (janela cross-recurso):
            a sequencia revalidacao -> escrita NAO e atomica e o lock do
            recibo NAO serializa mutacao do goal; um takeover que aconteca
            DEPOIS da ultima revalidacao liquida com a ownership ja
            validada. A revalidacao repetida estreita a janela, nao a
            elimina - nao ha alegacao de serializacao cross-recurso;
          - resultado DIVERGENTE para a mesma claim =>
            settle-result-conflict, sem sobrescrever o primeiro.

        CONFIANCA NO DESCRITOR (sem autenticacao): a sessao filha e os IDs
        da chamada do host tem de vir de forma INDEPENDENTE do hospedeiro
        (plugin/hook da sessao real: execute.after + ctx.session.get(child)
        .parentID). Esta funcao so confere FORMA e vinculacao de estado;
        ela NAO consegue autenticar um descritor fornecido e nao trata
        texto do modelo como autorizacao. Sem provenance independente o
        resultado segue sendo claim nao verificado. A AUSENCIA de
        execute.after (child faltando, com erro ou malformado) NUNCA e
        tratada como "sem efeito": o recibo permanece 'claimed' e a reserva
        continua, sem retry.

        NAO ha Executor nem re-despacho: `executor_calls` e sempre 0. Um
        recibo 'claimed' nunca e reexecutado por esta operacao.
    #>
    [CmdletBinding()]
    param(
        [string]$IdempotencyKey = '',
        $Authorization = $null,
        [string]$ChildSessionId = '',
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallerAgent = '',
        [string]$TargetAgent = '',
        [string]$PreparedFingerprint = '',
        [string]$Reference = '',
        [string]$TaskId = '',
        $Result = $null,
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000,
        # G1-A (opt-in): prova de provenance TRANSPORTADA pelo Planner e o
        # modo estrito. Sem -StrictProvenance e sem proof, o SETTLE segue
        # EXATAMENTE como antes (nenhuma recusa nova, nenhum campo novo).
        $ProvenanceProof = $null,
        [switch]$StrictProvenance,
        # G1-B (opt-in): remove o admission file quando a liquidacao fica
        # provada. Sem o switch nada e removido.
        [switch]$EmitAdmission
    )
    try {
        # (a) chave.
        $key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if ($key -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDSettleEnvelope -Ok $false -Reason 'invalid-idempotency-key')
        }
        # (b) descritor do host da liquidacao (sessao/mensagem/call).
        $desc = Test-NDHostCallDescriptor -SessionId $SessionId -MessageId $MessageId -CallId $CallId -RequireCallIdentity
        if (-not [bool](Get-NDValue $desc 'ok' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $desc 'reason' 'host-descriptor-invalid')) -IdempotencyKey $key)
        }
        $sessionId = ([string](Get-NDValue $desc 'session_id' ''))
        $messageId = ([string](Get-NDValue $desc 'message_id' ''))
        $callId = ([string](Get-NDValue $desc 'call_id' ''))
        # (b2) agentes do host (caller != target).
        $callerChk = Test-NDHostAgentName -Agent $CallerAgent
        if (-not [bool](Get-NDValue $callerChk 'ok' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'host-caller-agent-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId)
        }
        $callerAgent = ([string](Get-NDValue $callerChk 'agent' ''))
        $targetChk = Test-NDHostAgentName -Agent $TargetAgent
        if (-not [bool](Get-NDValue $targetChk 'ok' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'host-target-agent-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent)
        }
        $targetAgent = ([string](Get-NDValue $targetChk 'agent' ''))
        if ($callerAgent -ceq $targetAgent) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'host-agent-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        # (b3) child session id: forma apenas, nunca autenticada aqui.
        $childChk = Test-NDChildSessionId -ChildSessionId $ChildSessionId
        if (-not [bool](Get-NDValue $childChk 'ok' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $childChk 'reason' 'child-session-invalid')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent)
        }
        $childSession = ([string](Get-NDValue $childChk 'child_session_id' ''))
        # (b4) prepared fingerprint (32 hex).
        $settleFp = ([string]$PreparedFingerprint).Trim().ToLowerInvariant()
        if ($settleFp -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDSettleEnvelope -Ok $false -Reason 'invalid-prepared-fingerprint' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        # (b5) referencia opaca do preparo, quando informada.
        $settleRef = ([string]$Reference).Trim()
        if (-not [string]::IsNullOrWhiteSpace($settleRef)) {
            if ($settleRef -cnotmatch '^[a-f0-9]{32}$') {
                return (New-NDSettleEnvelope -Ok $false -Reason 'invalid-reference' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
        }
        # (b6) task id apresentado, quando informado (cross-task).
        $presentedTask = ([string]$TaskId).Trim()
        if (-not [string]::IsNullOrWhiteSpace($presentedTask)) {
            if (-not (Test-NDTaskId $presentedTask)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-task-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
        }
        # (b7) resultado candidato do worker: candidate_pass|failed|blocked.
        $shape = Test-OrchestrationDispatchResultShape -Result $Result
        if (-not [bool](Get-NDValue $shape 'ok' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $shape 'reason' 'result-invalid')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $status = ([string](Get-NDValue $shape 'status' ''))
        # F5: canonicaliza as refs do candidato UMA VEZ em ordem ordinal,
        # para que a comparacao, a criacao/geracao de evidencia (o
        # criteria_hash do evidence store E sensivel a ordem), a escrita no
        # kernel e o resultado persistido no recibo usem TODOS a MESMA
        # ordem. Sem isso, uma retentativa com as refs em ordem invertida
        # derivaria um criteria_hash diferente e orfaria uma segunda linha
        # de evidencia para a mesma claim.
        $claimed = [string[]]@(Get-NDSortedOrdinal -Items @((Get-NDValue $shape 'claimed_evidence' @())))
        # (c) raiz dos recibos.
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return (New-NDSettleEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $rootIdent = Get-NDDirCreationTimeUtcTicks -Path $dir
        $ndGoalId = ([string](Get-NDValue $Authorization 'goal_id' '')).Trim()
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        # (c2) autorizacao viva antes de qualquer IO no namespace.
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $auth 'reason' 'authorization-denied')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $rState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId $ndGoalId
        $rDir = [string](Get-NDValue $rState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($rDir)) {
            return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $rState 'reason' 'receipt-dir-unresolvable')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $rIdent = [string](Get-NDValue $rState 'created_utc' '')
        $idWhyPre = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
        if (-not [string]::IsNullOrWhiteSpace($idWhyPre)) {
            return (New-NDSettleEnvelope -Ok $false -Reason $idWhyPre -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        # (d) leitura PREVIA: SOMENTE para nomear o lock de task.
        $preRead = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent -AllowHandoffPhases
        $preTaskId = ''
        if (-not [bool](Get-NDValue $preRead 'ok' $false)) {
            $preWhy = ([string](Get-NDValue $preRead 'reason' 'receipt-unreadable'))
            if ($preWhy -ceq 'receipt-absent') { $preWhy = 'settle-not-claimed' }
            return (New-NDSettleEnvelope -Ok $false -Reason $preWhy -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $preReceipt = Get-NDValue $preRead 'receipt' $null
        if ($null -eq $preReceipt) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'settle-not-claimed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $preTaskId = ([string](Get-NDValue $preReceipt 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($preTaskId)) {
            return (New-NDSettleEnvelope -Ok $false -Reason 'settle-task-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        # (e) locks na ordem unica task -> recibo, segurados por toda a
        #     liquidacao (a separacao acontece no finally, como no CLAIM).
        $taskLockWhy = ''
        $taskLock = Open-NDTaskLock -RootDir $dir -TaskId $preTaskId -LockTimeoutMs $LockTimeoutMs -RootExpected $rootIdent -RefusalReason ([ref]$taskLockWhy)
        if ($null -eq $taskLock) {
            return (New-NDSettleEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $taskLockWhy -Fallback 'task-lock-busy') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        $lockWhy = ''
        $lock = Open-NDReceiptLock -Dir $rDir -LockTimeoutMs $LockTimeoutMs -Expected $rIdent -RefusalReason ([ref]$lockWhy)
        if ($null -eq $lock) {
            try { $taskLock.Dispose() } catch { }
            return (New-NDSettleEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $lockWhy -Fallback 'lock-busy') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
        }
        try {
            $idWhyLock = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyLock)) {
                return (New-NDSettleEnvelope -Ok $false -Reason $idWhyLock -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            # (e2) fencing pos-lock (F3) COM OS DOIS LOCKS SEGURADOS: a
            #      ownership viva e relida antes de qualquer decisao de
            #      liquidacao. Takeover, lease expirada ou goal fora de
            #      ACTIVE durante a espera pelos locks recusam sem tocar em
            #      registro algum - o recibo segue 'claimed' e a reserva de
            #      task continua valendo. O gate de autorizacao rodou ANTES
            #      dos locks (estado nao-terminal + ownership viva), entao
            #      esta recusa so pode vir da releitura feita agora.
            $fenceLock = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fenceLock 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fenceLock 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            # (f) leitura autoritativa sob o lock.
            $read = Read-NDReceipt -Dir $rDir -Key $key -Expected $rIdent -AllowHandoffPhases
            if (-not [bool](Get-NDValue $read 'ok' $false)) {
                $readWhy = ([string](Get-NDValue $read 'reason' 'receipt-unreadable'))
                if ($readWhy -ceq 'receipt-absent') { $readWhy = 'settle-not-claimed' }
                return (New-NDSettleEnvelope -Ok $false -Reason $readWhy -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            $existing = Get-NDValue $read 'receipt' $null
            if ($null -eq $existing) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-not-claimed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            $exPhase = ([string](Get-NDValue $existing 'phase' '')).Trim().ToLowerInvariant()
            if ($exPhase -ceq 'prepared') {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-not-claimed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            if (($exPhase -cne 'claimed') -and ($exPhase -cne 'settled')) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-phase-conflict' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            # (g) integridade SEMANTICA do registro antes de usa-lo (F3).
            $integ = Test-NDReceiptSemanticIntegrity -Receipt $existing -GoalId $ndGoalId -IdempotencyKey $key
            if (-not [bool](Get-NDValue $integ 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'receipt-integrity-invalid' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession)
            }
            $storedFp = ([string](Get-NDValue $existing 'prepared_fingerprint' '')).Trim().ToLowerInvariant()
            $storedIntentFp = ([string](Get-NDValue $existing 'intent_fingerprint' '')).Trim().ToLowerInvariant()
            $reference = ([string](Get-NDValue $existing 'reference' ''))
            # (h) vinculacao EXATA ao registro duravel.
            if (([string]::IsNullOrWhiteSpace($storedFp)) -or ($storedFp -cne $settleFp)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-fingerprint-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            if ((-not [string]::IsNullOrWhiteSpace($settleRef)) -and ($settleRef -cne $reference)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-reference-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $storedTask = ([string](Get-NDValue $existing 'task_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($storedTask)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-task-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            if ($storedTask -cne $preTaskId) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-task-lock-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            if ((-not [string]::IsNullOrWhiteSpace($presentedTask)) -and ($presentedTask -cne $storedTask)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-task-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $storedOwner = ([string](Get-NDValue $existing 'owner' '')).Trim()
            $storedGen = [long](Get-NDValue $existing 'ownership_generation' 0)
            $storedGoal = ([string](Get-NDValue $existing 'goal_id' '')).Trim()
            if ((($storedGoal -cne $ndGoalId) -or ($storedOwner -cne $authOwner) -or ($storedGen -ne $authGen))) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-identity-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # linhagem do host do CLAIM: a MESMA chamada que consumiu.
            $storedAgent = ([string](Get-NDValue $existing 'agent' ''))
            if (($storedAgent -cne $targetAgent) -or ($callerAgent -ceq $targetAgent)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-agent-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $claimSession = ([string](Get-NDValue $existing 'claim_session_id' ''))
            $claimMessage = ([string](Get-NDValue $existing 'claim_message_id' ''))
            $claimCall = ([string](Get-NDValue $existing 'claim_call_id' ''))
            $claimCaller = ([string](Get-NDValue $existing 'claim_caller_agent' ''))
            $claimTarget = ([string](Get-NDValue $existing 'claim_target_agent' ''))
            if ((($claimSession -cne $sessionId) -or ($claimMessage -cne $messageId) -or ($claimCall -cne $callId) -or ($claimCaller -cne $callerAgent) -or ($claimTarget -cne $targetAgent))) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-host-call-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            if ($childSession -ceq $sessionId) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-child-session-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (i) duplicata 'settled': identidade + prova + linhagem +
            #     resultado identico.
            if ($exPhase -ceq 'settled') {
                $dupId = Test-NDDuplicateReadIdentity -Receipt $existing -Authorization $Authorization -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -RepoRoot $RepoRoot
                if (-not [bool](Get-NDValue $dupId 'ok' $false)) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-identity-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                # FIX4 (PRA-SETTLE-FIX4) + FIX5: a duplicata so e
                #      idempotente quando o PROPRIO registro 'settled' prova
                #      a liquidacao que ele afirma, RECONSTRUIDA dos campos
                #      persistidos (`Test-NDSettledHandoffProof`, em TOKENS
                #      CRUS - sem pipeline, sem coercao):
                #        - FORMA CRUA do registro (a prova ja embute
                #          `Test-NDSettledReceiptFieldShape`): um
                #          `kernel_ok:[true]`, um
                #          `settle_child_session_id:["filho"]`, um
                #          `worker_result` escalar ou um campo ausente
                #          chegariam como escalar pela leitura com coercao e a
                #          duplicata responderia sucesso sobre um registro que
                #          nao e o que foi gravado;
                #        - `kernel_ok` EXATAMENTE booleano true e `reconciled`
                #          EXATAMENTE false (liquidacao conhecida; false/
                #          ausente/malformado NAO e duplicata idempotente de
                #          liquidacao);
                #        - evidencia exigida e VINCULADA: `evidence_created`
                #          EXATAMENTE booleano true, `evidence_id` string nao
                #          vazia e IGUAIS ao marcador duravel
                #          `settle_evidence_created`/`settle_evidence_id`;
                #        - identidade do recibo (`settled_by`/`settled_generation`
                #          contra `owner`/`ownership_generation`, `agent`
                #          contra `settle_target_agent`);
                #        - linhagem `settle_*` EXATAMENTE igual aos `claim_*` da
                #          chamada que consumiu o preparo, child binding e
                #          marcadores `settle_attempt_*` correlacionados;
                #        - candidato correlacionado (`worker_result` ==
                #          `settle_status`/`settle_claimed_evidence`);
                #        - integridade semantica RECALCULADA do registro.
                #      Falhou qualquer item => `settle-duplicate-unproven`,
                #      recusa fail-closed, sem reescrever nada. A linhagem
                #      devolvida abaixo e sempre a ARMAZENADA.
                $dupProof = Test-NDSettledHandoffProof -Receipt $existing
                if (-not [bool](Get-NDValue $dupProof 'ok' $false)) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-unproven' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                # F4: a duplicata tem de ser EXATAMENTE a mesma chamada do
                #     host, a MESMA sessao filha e os MESMOS agentes
                #     persistidos. A linhagem apresentada e conferida contra a
                #     ARMAZENADA no recibo - nunca o contrario: uma sessao
                #     filha DIVERGENTE (ou sessao/mensagem/call/caller/target
                #     divergentes) e recusada, nunca reaproveitada como
                #     idempotente. A linhagem DEVOLVIDA tambem e sempre a
                #     armazenada.
                $dupChildTok = Get-NDJsonStringValue -Object $existing -Name 'settle_child_session_id'
                if ($null -eq $dupChildTok) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-unproven' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $dupChild = ([string]$dupChildTok)
                if ($dupChild -cne $childSession) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-child-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $dupLineageBad = $false
                foreach ($lp in @(
                    @{ n = 'settle_session_id'; v = $sessionId },
                    @{ n = 'settle_message_id'; v = $messageId },
                    @{ n = 'settle_call_id'; v = $callId },
                    @{ n = 'settle_caller_agent'; v = $callerAgent },
                    @{ n = 'settle_target_agent'; v = $targetAgent }
                )) {
                    $lpName = [string]$lp.n
                    $lpTok = Get-NDJsonStringValue -Object $existing -Name $lpName
                    if (($null -eq $lpTok) -or (([string]$lpTok) -cne ([string]$lp.v))) { $dupLineageBad = $true; break }
                }
                if ($dupLineageBad) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-host-call-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $swr = Get-NDValue $existing 'worker_result' $null
                if ($null -eq $swr) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-duplicate-unproven' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $dupStatus = ([string](Get-NDValue $swr 'status' '')).Trim().ToLowerInvariant()
                $dupRefs = @((Get-NDValue $swr 'claimed_evidence' @()))
                if (-not (Test-NDCandidateResultMatch -Status $dupStatus -Refs $dupRefs -OtherStatus $status -OtherRefs $claimed)) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-result-conflict' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                # Resposta da duplicata: SOMENTE a linhagem ARMAZENADA -
                # child session, evidencia, kernel e status vem do registro
                # persistido (a prova acima ja garantiu kernel_ok=true,
                # evidence_created=true e evidence_id nao vazio).
                $dupEv = ([string](Get-NDValue $existing 'evidence_id' ''))
                $dupKOk = [bool](Get-NDValue $existing 'kernel_ok' $false)
                $dupEvCreated = [bool](Get-NDValue $existing 'evidence_created' $false)
                $dupReason = 'settle-duplicate'
                if ([bool](Get-NDValue $dupId 'takeover' $false)) { $dupReason = 'settle-duplicate-takeover' }
                # G1-A-FIX replay estrito: a duplicata provada so vale como
                # strict quando o REGISTRO ARMAZENADO ja carrega provenance
                # observada+. Liquidar sem proof e repetir com
                # -StrictProvenance NAO herda sucesso: sem tier gravado,
                # recusa em 'settle-provenance-unproven' (replay nao cria
                # provenance que nunca existiu).
                if ($StrictProvenance) {
                    $dupTier = ([string](Get-NDValue $existing 'settle_provenance_tier' '')).Trim().ToLowerInvariant()
                    if ((($dupTier -cne 'observed') -and ($dupTier -cne 'corroborated'))) {
                        return (New-NDSettleEnvelope -Ok $false -Reason 'settle-provenance-unproven' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                    }
                }
                # G1-B-FIX: duplicata provada tambem invalida admission
                # residual (incondicional, no-op quando ausente). A
                # liquidacao original ja removeu; isto fecha a janela em
                # que o admission sobreviveu a remocao (falha ou caminho
                # sem switch na primeira passagem).
                $dupRelState = Get-NDAdmissionDir -RootDir $dir -GoalId $ndGoalId
                if ([bool](Get-NDValue $dupRelState 'ok' $false)) {
                    [void](Remove-NDAdmissionRecord -AdmissionDir ([string](Get-NDValue $dupRelState 'dir' '')) -Ident ([string](Get-NDValue $dupRelState 'ident' '')) -Key $key)
                }
                return (New-NDSettleEnvelope -Ok $true -Reason $dupReason -Admitted $true -Settled $true -Duplicate $true -Phase 'settled' -HandoffState 'SETTLED' -IdempotencyKey $key -Reference $reference -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $dupChild -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -WorkerStatus $dupStatus -EvidenceCreated $dupEvCreated -EvidenceId $dupEv -KernelOk $dupKOk -KernelReason ([string](Get-NDValue $existing 'kernel_reason' '')))
            }
            # (h2) tentativa anterior registrada no proprio recibo: o
            #      candidato apresentado agora tem de ser EXATAMENTE o
            #      mesmo. Divergencia e conflito, nunca sobrescrita.
            $prevStatus = ([string](Get-NDValue $existing 'settle_attempt_status' '')).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($prevStatus)) {
                $prevRefs = @((Get-NDValue $existing 'settle_attempt_claimed_evidence' @()))
                if (-not (Test-NDCandidateResultMatch -Status $prevStatus -Refs $prevRefs -OtherStatus $status -OtherRefs $claimed)) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-result-conflict' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
                $prevChild = ([string](Get-NDValue $existing 'settle_attempt_child_session_id' ''))
                $prevSession = ([string](Get-NDValue $existing 'settle_attempt_session_id' ''))
                $prevMessage = ([string](Get-NDValue $existing 'settle_attempt_message_id' ''))
                $prevCall = ([string](Get-NDValue $existing 'settle_attempt_call_id' ''))
                $prevCaller = ([string](Get-NDValue $existing 'settle_attempt_caller_agent' ''))
                $prevTarget = ([string](Get-NDValue $existing 'settle_attempt_target_agent' ''))
                if ((($prevChild -cne $childSession) -or ($prevSession -cne $sessionId) -or ($prevMessage -cne $messageId) -or ($prevCall -cne $callId) -or ($prevCaller -cne $callerAgent) -or ($prevTarget -cne $targetAgent))) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-attempt-mismatch' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
            }
            $storedRev = [long](Get-NDValue $existing 'task_expected_revision' 0)
            # (i2) G1-A GATE DE PROVENANCE (OPT-IN): com -StrictProvenance a
            #      liquidacao EXIGE proof transportada e vinculada ANTES de
            #      qualquer escrita de liquidacao (marcador de tentativa,
            #      evidencia, kernel e 'settled'). Sem proof, com binding
            #      divergente ou com resultado adulterado depois da claim a
            #      operacao recusa em 'settle-provenance-unproven' e o
            #      recibo continua 'claimed' com a reserva.
            #      O gate roda DEPOIS do caminho de duplicata 'settled': uma
            #      liquidacao ja provada continua idempotente (o registro
            #      existente e a autoridade), e nao ha nada novo a provar.
            #      Fora do modo estrito o gate so REGISTRA o tier quando a
            #      proof vem valida - nunca recusa e nunca muda o resultado.
            $provTier = ''
            $provSource = ''
            if (($StrictProvenance) -or ($null -ne $ProvenanceProof)) {
                $prov = Test-NDProvenanceBinding -ProvenanceProof $ProvenanceProof -ClaimSessionId $claimSession -ClaimCallId $claimCall -IdempotencyKey $key -ChildSessionId $childSession -ExpectedClaimedEvidence $claimed -Strict:$StrictProvenance
                if ([bool](Get-NDValue $prov 'ok' $false)) {
                    $provTier = ([string](Get-NDValue $prov 'tier' ''))
                    $provSource = ([string](Get-NDValue $prov 'source' ''))
                }
                else {
                    if ($StrictProvenance) {
                        return (New-NDSettleEnvelope -Ok $false -Reason 'settle-provenance-unproven' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                    }
                }
            }
            # (j0) GATE DE COMMIT AMBIGUO (F1/F2/PRA-SETTLE-FIX2), ANTES de
            #      qualquer gate vivo e ANTES de qualquer escrita: se a task
            #      guarda um worker_result e a revisao viva AVANCOU ALEM da
            #      revisao esperada deste recibo, existe escrita pos-claim no
            #      kernel. Esta fatia nao tem marcador atomico de liquidacao
            #      do lado do kernel, portanto nao ha prova CAUSAL de que a
            #      escrita foi DESTE claim - status/refs iguais e revisao
            #      avancada provam coincidencia, nunca autoria
            #      (`Test-NDReconcileKernelProof` nao amarra a escrita do
            #      kernel a chamada do NativeDispatch). NUNCA se cria
            #      evidencia para provar escrita anterior e NUNCA se
            #      reescreve o kernel: devolve o bloqueio SEGURO de
            #      disponibilidade `settle-kernel-commit-ambiguous`, com o
            #      recibo 'claimed' e a reserva de task mantidos. Revisao
            #      avancada SEM worker_result nao e commit parcial (a escrita
            #      do kernel e uma so: resultado + revisao): a admissao viva
            #      recusa deterministicamente com task-revision-mismatch.
            #      Um worker_result com revisao <= esperada e HISTORICO
            #      (outra tentativa/claim): nao chega aqui - a tentativa nova
            #      segue normalmente e o CAS sobrescreve legitimamente.
            $evDirResolved = ([string]$EvidenceStoreDir).Trim()
            if ([string]::IsNullOrWhiteSpace($evDirResolved)) {
                $evDirCmd = Get-Command Get-OrchestrationEvidenceDefaultStoreDir -ErrorAction SilentlyContinue
                if ($null -ne $evDirCmd) { $evDirResolved = ([string](Get-OrchestrationEvidenceDefaultStoreDir)) }
            }
            $kOk = $false
            $kWhy = ''
            $evCreated = $false
            $evId = ''
            $liveTaskNow = $null
            try { $liveTaskNow = Get-OrchestrationTask -TaskId $storedTask -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $liveTaskNow = $null }
            $liveTaskErr = ''
            if ($null -ne $liveTaskNow) {
                try {
                    if ($liveTaskNow -is [System.Collections.IDictionary]) { if ($liveTaskNow.Contains('error')) { $liveTaskErr = ([string]$liveTaskNow['error']) } }
                    else { $ep = $liveTaskNow.PSObject.Properties['error']; if ($null -ne $ep) { $liveTaskErr = ([string]$ep.Value) } }
                }
                catch { $liveTaskErr = '' }
            }
            if (($null -ne $liveTaskNow) -and ([string]::IsNullOrWhiteSpace($liveTaskErr))) {
                $liveRevNow = [long](Get-NDValue $liveTaskNow 'revision' -1)
                $kwrNow = Get-NDValue $liveTaskNow 'worker_result' $null
                if (($null -ne $kwrNow) -and ($liveRevNow -gt $storedRev)) {
                    return (New-NDSettleEnvelope -Ok $false -Reason 'settle-kernel-commit-ambiguous' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
                }
            }
            # (j) revalidacao VIVA sob o lock: admissao do kernel, budget e
            #     fencing. A visao de Intent vem DO RECIBO, nunca do input.
            $intentView = Get-NDReceiptIntentView -Receipt $existing
            if ($null -eq $intentView) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-receipt-unusable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $liveGoal = $null
            try {
                $gslot = Get-OrchestrationGoal -GoalId $ndGoalId -StoreDir $GoalStoreDir
                if (($null -ne $gslot) -and [bool](Get-NDValue $gslot 'ok' $false)) {
                    $liveGoal = Get-NDValue $gslot 'goal' $null
                }
            }
            catch { $liveGoal = $null }
            # F1-S2: revisao do goal observada nesta decisao. O kernel
            # exige liveRev >= observada (fresca por construcao; admite
            # avanco concorrente legitimo entre esta leitura e a escrita).
            $liveGoalRev = [long](Get-NDValue $liveGoal 'revision' -1)
            $admit = Test-NDLiveTaskAdmission -Intent $intentView -Authorization $Authorization -Goal $liveGoal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $admit 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $admit 'reason' 'admission-denied')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $budget = Test-NDTaskAttemptBudget -TaskId $storedTask -TasksDir $TasksDir -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $budget 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $budget 'reason' 'attempt-budget-unknown')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $fence = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fence 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fence 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $storedRev = [long](Get-NDValue $existing 'task_expected_revision' 0)
            # (k) marcador de tentativa no proprio recibo (fase CONTINUA
            #     'claimed'): registra o candidato ANTES da primeira
            #     escrita de liquidacao, no espirito do 'pending' legado.
            $attemptExtra = [ordered]@{
                settle_attempt_status = $status
                settle_attempt_claimed_evidence = [string[]]@($claimed)
                settle_attempt_child_session_id = $childSession
                settle_attempt_session_id = $sessionId
                settle_attempt_message_id = $messageId
                settle_attempt_call_id = $callId
                settle_attempt_caller_agent = $callerAgent
                settle_attempt_target_agent = $targetAgent
                settle_attempt_at = ([DateTime]::UtcNow.ToString('o'))
            }
            $attempted = Convert-NDReceiptToPhase -Receipt $existing -Phase 'claimed' -Extra $attemptExtra
            if ($null -eq $attempted) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-receipt-unusable' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $idWhyAttempt = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhyAttempt)) {
                return (New-NDSettleEnvelope -Ok $false -Reason $idWhyAttempt -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (k2) fencing pos-lock (F3) IMEDIATAMENTE antes da escrita do
            #      marcador de tentativa no recibo.
            $fenceAttempt = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fenceAttempt 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fenceAttempt 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $attemptWhy = ''
            if (-not (Write-NDReceipt -Dir $rDir -Receipt $attempted -Expected $rIdent -RefusalReason ([ref]$attemptWhy))) {
                return (New-NDSettleEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $attemptWhy -Fallback 'settle-receipt-write-failed') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (l) evidencia canonica, ligada a chamada do host e a sessao
            #     filha. O created_at vem do CLAIM (deterministico), entao
            #     uma retentativa deriva o MESMO evidence_id.
            if ([string]::IsNullOrWhiteSpace($evDirResolved)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-evidence-failed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            $evSlot = Write-NDSettleEvidence -Receipt $existing -TaskId $storedTask -Key $key -TargetAgent $targetAgent -Status $status -ClaimedEvidence $claimed -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -ChildSession $childSession -StoreDir $evDirResolved
            $evCreated = [bool](Get-NDValue $evSlot 'ok' $false)
            $evId = ([string](Get-NDValue $evSlot 'id' ''))
            if ((-not $evCreated) -or ([string]::IsNullOrWhiteSpace($evId))) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $evSlot 'reason' 'settle-evidence-failed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp)
            }
            # (l2) o evidence_id grava DURO no recibo (fase continua 'claimed')
            #      ANTES do kernel: se o kernel recusar ou o processo cair
            #      entre a evidencia e o kernel, a trilha fica auditavel sem
            #      recomputar nada e a liquidacao segue NAO-RESOLVIDA.
            $evMarked = Convert-NDReceiptToPhase -Receipt ([pscustomobject]$attempted) -Phase 'claimed' -Extra ([ordered]@{
                settle_evidence_created = [bool]$evCreated
                settle_evidence_id = $evId
            })
            if ($null -ne $evMarked) {
                $idWhyEv = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
                if ([string]::IsNullOrWhiteSpace($idWhyEv)) {
                    # (l2b) fencing pos-lock (F3) IMEDIATAMENTE antes da
                    #       escrita do marcador de evidencia no recibo.
                    $fenceEv = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
                    if (-not [bool](Get-NDValue $fenceEv 'ok' $false)) {
                        return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fenceEv 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason ([string](Get-NDValue $fenceEv 'reason' 'post-lock-fencing-changed')))
                    }
                    $evWhy = ''
                    if (-not (Write-NDReceipt -Dir $rDir -Receipt $evMarked -Expected $rIdent -RefusalReason ([ref]$evWhy))) {
                        return (New-NDSettleEnvelope -Ok $false -Reason (Resolve-NDRefusalReason -Refusal $evWhy -Fallback 'settle-receipt-write-failed') -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason 'settle-receipt-write-failed')
                    }
                    $attempted = [pscustomobject]$evMarked
                }
            }
            # (m) kernel: grava o worker-result. O gate de commit ambiguo
            #     (j0) ja barrou qualquer escrita pos-claim no kernel; a
            #     releitura abaixo reconfirma o estado antes do CAS.
            $liveTask = $null
            try { $liveTask = Get-OrchestrationTask -TaskId $storedTask -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $liveTask = $null }
            $taskErr = ''
            if ($null -ne $liveTask) {
                try {
                    if ($liveTask -is [System.Collections.IDictionary]) { if ($liveTask.Contains('error')) { $taskErr = ([string]$liveTask['error']) } }
                    else { $ep = $liveTask.PSObject.Properties['error']; if ($null -ne $ep) { $taskErr = ([string]$ep.Value) } }
                }
                catch { $taskErr = '' }
            }
            if (($null -eq $liveTask) -or (-not [string]::IsNullOrWhiteSpace($taskErr))) {
                $kWhy = 'settle-task-unreadable'
                if (-not [string]::IsNullOrWhiteSpace($taskErr)) { $kWhy = ('settle-task-unreadable:' + $taskErr) }
                return (New-NDSettleEnvelope -Ok $false -Reason $kWhy -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason $kWhy)
            }
            $kwr = Get-NDValue $liveTask 'worker_result' $null
            $liveRevNow = [long](Get-NDValue $liveTask 'revision' -1)
            # F1: um worker_result com revisao <= esperada e HISTORICO
            # (tentativa/claim anterior) e NAO pode bloquear esta liquidacao -
            # o CAS abaixo sobrescreve legitimamente com o candidato desta
            # claim. Um worker_result com a revisao AVANCADA ALEM da esperada
            # (escrita pos-claim inesperada ou corrida entre o gate j0 e esta
            # releitura) e COMMIT AMBIGUO (F1/F2/PRA-SETTLE-FIX2): nao ha
            # prova causal de que a escrita foi desta claim, entao nao se
            # reconcilia e nao se reescreve o kernel - recusa segura com o
            # recibo 'claimed' e a reserva mantidos.
            if (($null -ne $kwr) -and ($liveRevNow -gt $storedRev)) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-kernel-commit-ambiguous' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason 'settle-kernel-commit-ambiguous')
            }
            # F3: fencing pos-lock IMEDIATAMENTE antes da escrita no kernel.
            #     Goal EXATAMENTE ACTIVE + owner/generation/lease vivos;
            #     takeover, lease expirada ou goal fora de ACTIVE recusam sem
            #     escrever e deixam o recibo 'claimed' com a reserva.
            $fenceKernel = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fenceKernel 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fenceKernel 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason ([string](Get-NDValue $fenceKernel 'reason' 'post-lock-fencing-changed')))
            }
            # F1-S2: o caminho canonico de liquidacao encaminha o contexto
            # nativo correlacionado ao kernel. Tasks sem settlement_policy
            # ignoram o contexto (contrato legado preservado); tasks
            # marcadas 'canonical-native-settle' recusam sem ele. O contexto
            # e construido AQUI, dos locais ja validados - nunca fabricado
            # de SessionId/binding de outro caminho.
            $settleCtx = [ordered]@{
                task_id              = $storedTask
                goal_id              = $ndGoalId
                owner                = $authOwner
                generation           = $authGen
                goal_revision        = $liveGoalRev
                goal_store_dir       = $GoalStoreDir
                receipt_root         = $dir
                evidence_store_dir   = $evDirResolved
                idempotency_key      = $key
                prepared_fingerprint = $settleFp
                parent_session_id    = $sessionId
                message_id           = $messageId
                call_id              = $callId
                caller_agent         = $callerAgent
                target_agent         = $targetAgent
                child_session_id     = $childSession
                status               = $status
                claimed_evidence     = [string[]]@($claimed)
                produced_by          = $targetAgent
            }
            $kSlot = Set-OrchestrationTaskWorkerResult -TaskId $storedTask -Status $status -ClaimedEvidence $claimed -ProducedBy $targetAgent -ExpectedRevision $storedRev -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot -SettlementContext $settleCtx
            if (($null -ne $kSlot) -and [bool](Get-NDValue $kSlot 'ok' $false)) {
                $kOk = $true
                $kWhy = ''
            }
            else {
                $kWhy = ([string](Get-NDValue $kSlot 'error' 'kernel-refused'))
                if ([string]::IsNullOrWhiteSpace($kWhy)) { $kWhy = 'kernel-refused' }
                return (New-NDSettleEnvelope -Ok $false -Reason ('settle-kernel-refused:' + $kWhy) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $false -KernelReason $kWhy)
            }
            # (n) transicao 'claimed' -> 'settled'. Essa escrita E a
            #     liberacao da reserva de task (F2) - nao ha store separado.
            $settleExtra = [ordered]@{
                handoff_state = 'SETTLED'
                settle_status = $status
                settle_claimed_evidence = [string[]]@($claimed)
                settle_child_session_id = $childSession
                settle_session_id = $sessionId
                settle_message_id = $messageId
                settle_call_id = $callId
                settle_caller_agent = $callerAgent
                settle_target_agent = $targetAgent
                worker_result = @{ status = $status; claimed_evidence = @($claimed) }
                kernel_ok = [bool]$kOk
                kernel_reason = $kWhy
                evidence_created = [bool]$evCreated
                evidence_id = $evId
                ok = [bool]$kOk
                reason = ''
                reconciled = $false
                settled_by = $authOwner
                settled_generation = $authGen
                settled_at = ([DateTime]::UtcNow.ToString('o'))
            }
            # G1-A: o tier da provenance so entra no registro quando o gate
            # rodou com proof valida. Sem proof, o recibo fica EXATAMENTE
            # como antes (comportamento default inalterado).
            if (-not [string]::IsNullOrWhiteSpace($provTier)) {
                $settleExtra['settle_provenance_tier'] = $provTier
                $settleExtra['settle_provenance_source'] = $provSource
            }
            $settledReceipt = Convert-NDReceiptToPhase -Receipt ([pscustomobject]$attempted) -Phase 'settled' -Extra $settleExtra
            if ($null -eq $settledReceipt) {
                return (New-NDSettleEnvelope -Ok $false -Reason 'settle-receipt-write-failed' -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $kOk -KernelReason $kWhy)
            }
            $idWhySettled = Test-NDReceiptDirLive -Dir $rDir -Expected $rIdent
            if (-not [string]::IsNullOrWhiteSpace($idWhySettled)) {
                return (New-NDSettleEnvelope -Ok $false -Reason $idWhySettled -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $kOk -KernelReason $kWhy)
            }
            # (n2) fencing pos-lock (F3) IMEDIATAMENTE antes da escrita do
            #      recibo 'settled' - a escrita que libera a reserva de task.
            #      Goal EXATAMENTE ACTIVE + owner/generation/lease vivos;
            #      takeover, lease expirada ou goal fora de ACTIVE recusam e
            #      deixam o recibo 'claimed' com a reserva mantida.
            $fenceSettled = Test-NDPostLockFencing -GoalId $ndGoalId -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-NDValue $fenceSettled 'ok' $false)) {
                return (New-NDSettleEnvelope -Ok $false -Reason ([string](Get-NDValue $fenceSettled 'reason' 'post-lock-fencing-changed')) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $kOk -KernelReason $kWhy)
            }
            $writeWhy = ''
            $writeOk = Write-NDReceipt -Dir $rDir -Receipt $settledReceipt -Expected $rIdent -RefusalReason ([ref]$writeWhy)
            # PRA-SETTLE-FIX4: o retorno do escritor NAO decide NADA sozinho,
            # nos DOIS sentidos.
            #   - `$false` NAO prova que nada foi gravado: a prova pos-escrita
            #     pode falhar DEPOIS de o arquivo 'settled' ja ter sido movido
            #     para o destino (identidade divergente no estado final, alvo
            #     que deixou de ser arquivo regular, leitura de retorno
            #     ilegivel, ou registro substituido por terceiro nesse
            #     intervalo);
            #   - `$true` NAO prova que o disco contem o registro EXATO: o
            #     Move pode ter ocorrido e o destino continuar sendo alterado
            #     depois, e a prova pos-escrita do escritor so confirma que o
            #     arquivo existe e contem a chave - nunca que o conteudo e o
            #     recibo 'settled' EXATO desta liquidacao.
            # A UNICA autoridade e a RELEITURA, ainda SOB OS DOIS LOCKS,
            # comparada campo a campo com o recibo 'settled' EXATO que se
            # tentou escrever (integridade semantica recalculada, forma crua,
            # referencia, linhagem do host, sessao filha, candidato, evidencia
            # e campos do kernel, nenhum campo extra). Por isso a prova
            # (`Test-NDSettledReceiptPersisted`, que ja embute a forma crua)
            # roda DEPOIS da escrita em QUALQUER dos dois retornos.
            #   Prova exata => a liquidacao DE FATO esta persistida e a
            # resposta e o sucesso desta chamada. Sem prova exata =>
            # `settle-receipt-proof-*`: estado EXPLICITAMENTE incerto. Nao se
            # afirma que o recibo continua 'claimed', nao se fabrica escrita,
            # nao se alega liquidacao e a reserva de task NAO e liberada; a
            # retentativa cai no gate de duplicata/commit ambiguo.
            $proof = Test-NDSettledReceiptPersisted -Dir $rDir -Key $key -Expected $rIdent -SettledReceipt $settledReceipt -GoalId $ndGoalId
            $proofOk = Get-NDJsonBoolValue -Object $proof -Name 'ok'
            if (($null -eq $proofOk) -or (-not $proofOk)) {
                $proofWhy = Get-NDJsonStringValue -Object $proof -Name 'reason'
                if ($null -eq $proofWhy) { $proofWhy = 'settle-receipt-proof-unavailable' }
                return (New-NDSettleEnvelope -Ok $false -Reason ([string]$proofWhy) -IdempotencyKey $key -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -Reference $reference -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $kOk -KernelReason $kWhy)
            }
            # Sem reconciliador: o SETTLE so devolve settled quando ELE
            # escreveu kernel + recibo nesta propria chamada (ou provou, por
            # releitura sob lock, que a escrita do recibo 'settled' ocorreu).
            # G1-B (OPT-IN, remocao INCONDICIONAL pos-G1-B-FIX): liquidacao
            # provada INVALIDA o admission file deste despacho, sob os
            # DOIS locks ainda segurados. A remocao nao depende de
            # -EmitAdmission: se o arquivo existir, sai; se nao existir,
            # Remove-NDAdmissionRecord e no-op. Replay pos-SETTLE nega no
            # plugin (recibo phase='settled') e expira pelo expires_at_utc.
            # Falha de remocao NAO desfaz a liquidacao ja provada.
            $relState = Get-NDAdmissionDir -RootDir $dir -GoalId $ndGoalId
            if ([bool](Get-NDValue $relState 'ok' $false)) {
                [void](Remove-NDAdmissionRecord -AdmissionDir ([string](Get-NDValue $relState 'dir' '')) -Ident ([string](Get-NDValue $relState 'ident' '')) -Key $key)
            }
            return (New-NDSettleEnvelope -Ok ([bool]$kOk) -Reason '' -Admitted $true -Settled ([bool]$kOk) -Reconciled $false -Phase 'settled' -HandoffState 'SETTLED' -IdempotencyKey $key -Reference $reference -SessionId $sessionId -MessageId $messageId -CallId $callId -CallerAgent $callerAgent -TargetAgent $targetAgent -ChildSessionId $childSession -IntentFingerprint $storedIntentFp -PreparedFingerprint $storedFp -WorkerStatus $status -EvidenceCreated $evCreated -EvidenceId $evId -KernelOk $kOk -KernelReason $kWhy)
        }
        finally {
            try { $lock.Dispose() } catch { }
            try { $taskLock.Dispose() } catch { }
        }
    }
    catch {
        return (New-NDSettleEnvelope -Ok $false -Reason 'settle-internal-error')
    }
}

# =====================================================================
# G1 trusted-runtime closure (BLOCO ADITIVO)
#
# Nada aqui muda o comportamento default: PREPARE/CLAIM/SETTLE seguem
# exatamente iguais sem os novos parametros opt-in
# (-ProvenanceProof/-StrictProvenance no SETTLE, -EmitAdmission no
# CLAIM/SETTLE). Tudo vive sob os MESMOS locks, no MESMO namespace de
# recibos (nunca um segundo store) e no MESMO vocabulario de recusa
# fail-closed.
# =====================================================================

# ---------------------------------------------------------------------
# (A) Provenance: BINDING da prova transportada + tier
# ---------------------------------------------------------------------
function Test-NDProvenanceBinding {
    <#
    .SYNOPSIS
        Confere o BINDING de uma prova de provenance transportada contra
        a claim que a liquidacao quer fechar (G1-A). Fail-closed.
    .DESCRIPTION
        O proof NAO e assinatura: e um registro TRANSPORTADO pelo Planner
        (nunca texto do modelo) afirmando que a identidade do evento foi
        obtida de forma INDEPENDENTE pelo hospedeiro. Esta funcao so
        confere BINDING: a tupla (child_session_id, parent_session_id,
        call_id, idempotency_key) tem de casar EXATAMENTE com a claim
        sob liquidacao. O tier e derivado das fontes declaradas:

          'plugin-session-get' - o host leu a sessao filha pelo plugin;
          'opencode-db'        - o host leu a sessao no banco do runtime;
          'declared'           - declaracao do Planner, sem testemunho
                                 independente do host.

        Tier: 'corroborated' exige DUAS fontes independentes distintas
        (ex.: plugin-session-get + opencode-db, ambas em `sources`);
        'observed' quando ha EXATAMENTE UMA fonte independente;
        'declared' quando so existe a declaracao. Racional: 'corroborated'
        so e honesto quando ha MATCH em 2 fontes independentes; quando a
        segunda fonte nao esta disponivel, o tier caiba para 'observed' -
        nunca se inventa corroboracao.

        Quando -ExpectedClaimedEvidence vem preenchido, o proof tambem
        tem de concordar com as refs do candidato: resultado adulterado
        depois da claim recusa em 'provenance-result-mismatch' (nunca
        passa com tier alto). Com -Strict a comparacao e OBRIGATORIA
        (refs ausentes/vazias recusam em 'provenance-evidence-required')
        e tier 'declared' recusa em 'provenance-declared-not-proof':
        declaracao do Planner nunca e prova em modo estrito.

        Devolve @{ok, reason, tier, source, sources}. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $ProvenanceProof = $null,
        [string]$ClaimSessionId = '',
        [string]$ClaimCallId = '',
        [string]$IdempotencyKey = '',
        [string]$ChildSessionId = '',
        [string[]]$ExpectedClaimedEvidence = @(),
        [switch]$Strict
    )
    $refuse = {
        param([string]$Why)
        return [pscustomobject]@{ ok = $false; reason = $Why; tier = ''; source = ''; sources = @() }
    }
    try {
        if ($null -eq $ProvenanceProof) { return (& $refuse 'provenance-absent') }
        $allowed = @('plugin-session-get', 'opencode-db', 'declared')
        $srcTok = Get-NDJsonStringValue -Object $ProvenanceProof -Name 'source'
        if ($null -eq $srcTok) { return (& $refuse 'provenance-source-missing') }
        $source = ([string]$srcTok).Trim().ToLowerInvariant()
        if ($allowed -cnotcontains $source) { return (& $refuse 'provenance-source-unknown') }
        # tupla: filho, pai, chamada e chave - todas EXATAS.
        $childTok = Get-NDJsonStringValue -Object $ProvenanceProof -Name 'child_session_id'
        if ($null -eq $childTok) { return (& $refuse 'provenance-child-missing') }
        if (([string]$childTok).Trim() -cne ([string]$ChildSessionId).Trim()) { return (& $refuse 'provenance-child-mismatch') }
        $parentTok = Get-NDJsonStringValue -Object $ProvenanceProof -Name 'parent_session_id'
        if (($null -eq $parentTok) -or (([string]$parentTok).Trim() -cne ([string]$ClaimSessionId).Trim())) { return (& $refuse 'provenance-parent-mismatch') }
        $callTok = Get-NDJsonStringValue -Object $ProvenanceProof -Name 'call_id'
        if (($null -eq $callTok) -or (([string]$callTok).Trim() -cne ([string]$ClaimCallId).Trim())) { return (& $refuse 'provenance-call-mismatch') }
        $keyTok = Get-NDJsonStringValue -Object $ProvenanceProof -Name 'idempotency_key'
        $keyNorm = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
        if (($null -eq $keyTok) -or (([string]$keyTok).Trim().ToLowerInvariant() -cne $keyNorm)) { return (& $refuse 'provenance-key-mismatch') }
        # fontes adicionais (opcional): array JSON de strings do conjunto.
        $sources = @()
        $rawSources = $null
        if (Try-NDRawProperty -Object $ProvenanceProof -Name 'sources' -Value ([ref]$rawSources)) {
            if ($rawSources -is [string]) { return (& $refuse 'provenance-sources-shape-invalid') }
            foreach ($s in @($rawSources)) {
                if ($s -isnot [string]) { return (& $refuse 'provenance-sources-shape-invalid') }
                $sn = ([string]$s).Trim().ToLowerInvariant()
                if ($allowed -cnotcontains $sn) { return (& $refuse 'provenance-source-unknown') }
                if ($sources -cnotcontains $sn) { $sources += $sn }
            }
        }
        if ($sources -cnotcontains $source) { $sources += $source }
        $independent = @()
        foreach ($s in @($sources)) { if ($s -cne 'declared') { $independent += $s } }
        $tier = ''
        if (@($independent).Count -ge 2) { $tier = 'corroborated' }
        elseif (@($independent).Count -eq 1) { $tier = 'observed' }
        else { $tier = 'declared' }
        # resultado adulterado depois da claim: o proof que concordava
        # com as refs antigas nao pode abencoar as novas. Em modo
        # estrito a comparacao e OBRIGATORIA: proof sem refs (ou refs
        # vazias) nunca prova resultado - recusa em vez de pular a
        # comparacao. Fora do modo estrito, a ausencia de refs apenas
        # registra binding sem vinculo de resultado (tier possivel,
        # sem prova de integridade do candidato).
        $proofRefs = @()
        $hasRefsField = $false
        $rawRefs = $null
        if (Try-NDRawProperty -Object $ProvenanceProof -Name 'claimed_evidence' -Value ([ref]$rawRefs)) {
            $hasRefsField = $true
            if ($rawRefs -is [string]) { return (& $refuse 'provenance-result-mismatch') }
            foreach ($r in @($rawRefs)) {
                if ($r -isnot [string]) { return (& $refuse 'provenance-result-mismatch') }
                $proofRefs += ([string]$r).Trim()
            }
        }
        if ($Strict) {
            if ((@($ExpectedClaimedEvidence).Count -eq 0) -or (@($proofRefs).Count -eq 0)) {
                return (& $refuse 'provenance-evidence-required')
            }
            $a = @(Get-NDSortedOrdinal -Items @($proofRefs))
            $b = @(Get-NDSortedOrdinal -Items @($ExpectedClaimedEvidence))
            if (@($a).Count -ne @($b).Count) { return (& $refuse 'provenance-result-mismatch') }
            for ($i = 0; $i -lt @($a).Count; $i++) {
                if (([string]$a[$i]) -cne ([string]$b[$i])) { return (& $refuse 'provenance-result-mismatch') }
            }
            if ($tier -ceq 'declared') { return (& $refuse 'provenance-declared-not-proof') }
        }
        elseif (@($ExpectedClaimedEvidence).Count -gt 0) {
            if (@($proofRefs).Count -gt 0) {
                $a = @(Get-NDSortedOrdinal -Items @($proofRefs))
                $b = @(Get-NDSortedOrdinal -Items @($ExpectedClaimedEvidence))
                if (@($a).Count -ne @($b).Count) { return (& $refuse 'provenance-result-mismatch') }
                for ($i = 0; $i -lt @($a).Count; $i++) {
                    if (([string]$a[$i]) -cne ([string]$b[$i])) { return (& $refuse 'provenance-result-mismatch') }
                }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; tier = $tier; source = $source; sources = [string[]]$sources }
    }
    catch {
        return (& $refuse 'provenance-binding-error')
    }
}

# ---------------------------------------------------------------------
# (B) Admission-file lifecycle + decisao testavel sem host
# ---------------------------------------------------------------------
function Get-NDAdmissionDir {
    <#
    .SYNOPSIS
        Subdiretorio de admission files de UM goal (G1-B). Fail-closed.
    .DESCRIPTION
        O admission file VIVE em `<GoalReceiptDir>/admission/` e NAO
        direto no namespace de recibos. Razao mecanica: a varredura
        `Test-NDTaskEffectExclusive` caminha ENTRADAS do namespace e
        trata QUALQUER nome `.json` fora de `^[a-f0-9]{32}.json$` como
        recusa fail-closed da varredura INTEIRA - um
        `<chave>.admission.json` solto no namespace quebraria todo CLAIM
        posterior. Um subdiretorio chamado `admission` nao termina em
        `.json` e segue ignorado pela varredura, sem excecao nova.
        Reaproveita `Resolve-NDGoalReceiptDir` (namespace + reparse
        point + identidade), nunca um segundo store.
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$GoalId = '')
    try {
        $nsState = Resolve-NDGoalReceiptDir -RootDir $RootDir -GoalId $GoalId
        $nsDir = [string](Get-NDValue $nsState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($nsDir)) {
            return [pscustomobject]@{ ok = $false; reason = ([string](Get-NDValue $nsState 'reason' 'admission-dir-unresolvable')); dir = ''; ident = '' }
        }
        $sub = Join-Path $nsDir 'admission'
        # Cria PRIMEIRO e checa reparse DEPOIS (e recheca): um caminho
        # inexistente devolve $false em Test-NDPathWithoutReparsePoint, que
        # seria lido como rejeicao indevida no primeiro acesso.
        try {
            if (-not (Test-Path -LiteralPath $sub -PathType Container)) { [void][IO.Directory]::CreateDirectory($sub) }
        }
        catch { return [pscustomobject]@{ ok = $false; reason = 'admission-dir-unresolvable'; dir = ''; ident = '' } }
        if (-not (Test-NDPathWithoutReparsePoint -Path $sub)) {
            return [pscustomobject]@{ ok = $false; reason = 'admission-dir-reparse-point'; dir = ''; ident = '' }
        }
        $ident = Get-NDDirCreationTimeUtcTicks -Path $sub
        if ([string]::IsNullOrWhiteSpace($ident)) {
            return [pscustomobject]@{ ok = $false; reason = 'admission-dir-unresolvable'; dir = ''; ident = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; dir = $sub; ident = $ident }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'admission-dir-unresolvable'; dir = ''; ident = '' } }
}

function Get-NDAdmissionPath {
    [CmdletBinding()]
    param([string]$AdmissionDir = '', [string]$Key = '')
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($AdmissionDir)) -or ($k -cnotmatch '^[a-f0-9]{32}$')) { return '' }
        return (Join-Path $AdmissionDir ($k + '.admission.json'))
    }
    catch { return '' }
}

function New-NDAdmissionRecord {
    <#
    .SYNOPSIS
        Forma canonica de UM admission file (G1-B). Somente construcao.
    .DESCRIPTION
        Campos do contrato do admission: idempotency_key, goal_id,
        task_id, session_id, call_id, agent, generation, fencing,
        allowed_model/allowed_provider (vazio = sem restricao),
        created_at_utc e expires_at_utc. `fencing` carrega o
        owner/generation e o estado do goal que autorizou o despacho,
        para que a decisao do host falhe fechada em takeover ou goal
        fora de ACTIVE. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$IdempotencyKey = '',
        [string]$GoalId = '',
        [string]$TaskId = '',
        [string]$SessionId = '',
        [string]$CallId = '',
        [string]$Agent = '',
        [string]$Owner = '',
        [long]$Generation = 0,
        [string]$GoalState = '',
        [int]$TtlSeconds = 3600,
        [string]$AllowedModel = '',
        [string]$AllowedProvider = '',
        [datetime]$NowUtc = ([DateTime]::MinValue)
    )
    try {
        $now = $NowUtc
        if ($now -eq [DateTime]::MinValue) { $now = [DateTime]::UtcNow }
        $ttl = [int]$TtlSeconds
        if ($ttl -lt 1) { $ttl = 3600 }
        return [ordered]@{
            schema_version = 1
            idempotency_key = ([string]$IdempotencyKey).Trim().ToLowerInvariant()
            goal_id = ([string]$GoalId).Trim()
            task_id = ([string]$TaskId).Trim()
            session_id = ([string]$SessionId).Trim()
            call_id = ([string]$CallId).Trim()
            agent = ([string]$Agent).Trim()
            generation = [long]$Generation
            fencing = [ordered]@{
                owner = ([string]$Owner).Trim()
                generation = [long]$Generation
                goal_state = (([string]$GoalState).Trim().ToUpperInvariant())
                ok = $true
            }
            allowed_model = ([string]$AllowedModel).Trim()
            allowed_provider = ([string]$AllowedProvider).Trim()
            created_at_utc = ($now.ToString('o'))
            expires_at_utc = ($now.AddSeconds([double]$ttl).ToString('o'))
        }
    }
    catch { return $null }
}

function Write-NDAdmissionRecord {
    <#
    .SYNOPSIS
        Persiste UM admission file (temp+move com identidade reassertada).
    .DESCRIPTION
        Mesma disciplina de `Write-NDReceipt`: identidade do diretorio
        reassertada antes do temporario e antes do Move, destino EXATO
        tem de ser arquivo regular sem reparse point e prova pos-escrita
        confirma que o arquivo contem a chave. Devolve $true somente
        quando persistiu. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$AdmissionDir = '', [string]$Ident = '', [string]$Key = '', $Record = $null, [switch]$FailIfExists)
    try {
        if ($null -eq $Record) { return $false }
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (($k -cnotmatch '^[a-f0-9]{32}$') -or ([string]::IsNullOrWhiteSpace($AdmissionDir))) { return $false }
        $idPre = Assert-NDDirIdentity -Path $AdmissionDir -Expected $Ident
        if (-not [bool](Get-NDValue $idPre 'ok' $false)) { return $false }
        $path = Get-NDAdmissionPath -AdmissionDir $AdmissionDir -Key $k
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        if (Test-Path -LiteralPath $path) {
            # Sem sobrescrita quando exigido (reparo): quem chegou
            # depois nao renova autorizacao existente - fail-closed.
            if ($FailIfExists) { return $false }
            if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        $json = ConvertTo-Json -InputObject $Record -Depth 12 -Compress
        $tmp = Join-Path $AdmissionDir (('admission-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) } catch { return $false }
        $idMove = Assert-NDDirIdentity -Path $AdmissionDir -Expected $Ident
        if (-not [bool](Get-NDValue $idMove 'ok' $false)) { return $false }
        if ($FailIfExists) {
            # Publicacao sem sobrescrita: o Move SEM -Force falha quando
            # o destino nasceu entre a checagem e a escrita (TOCTOU) -
            # quem chegou depois nao renova. Falha aqui = alguem publicou.
            try { Move-Item -LiteralPath $tmp -Destination $path -ErrorAction Stop }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
                return $false
            }
        }
        else {
            try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            catch { return $false }
        }
        $idPost = Assert-NDDirIdentity -Path $AdmissionDir -Expected $Ident
        if (-not [bool](Get-NDValue $idPost 'ok' $false)) { return $false }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
        try {
            $back = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if (([string]::IsNullOrWhiteSpace($back)) -or ($back.IndexOf($k, [StringComparison]::Ordinal) -lt 0)) { return $false }
        }
        catch { return $false }
        return $true
    }
    catch { return $false }
}

function Read-NDAdmissionRecord {
    <#
    .SYNOPSIS
        Le UM admission file (objeto JSON) ou devolve $null. Somente
        leitura, bounded, fail-closed. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$AdmissionDir = '', [string]$Key = '')
    try {
        $path = Get-NDAdmissionPath -AdmissionDir $AdmissionDir -Key $Key
        if ([string]::IsNullOrWhiteSpace($path)) { return $null }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $null }
        $rd = Read-NDBoundedFileText -Path $path -MaxBytes 65536
        if (-not [bool](Get-NDValue $rd 'ok' $false)) { return $null }
        $text = [string](Get-NDValue $rd 'text' '')
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        if (-not (Test-NDJsonObjectRootText -Text $text)) { return $null }
        try { return (ConvertFrom-Json $text) } catch { return $null }
    }
    catch { return $null }
}

function Remove-NDAdmissionRecord {
    <#
    .SYNOPSIS
        Remove (invalida) UM admission file sob identidade reassertada.
    .DESCRIPTION
        Usado pelo SETTLE no caminho de liquidacao provada e pelo CLAIM
        quando a escrita do recibo claimed falha depois de o admission
        ja ter sido persistido (nada de admission orfao). Somente remove
        arquivo regular sem reparse point, pelo caminho revalidado.
        Devolve $true quando nao ha mais admission. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$AdmissionDir = '', [string]$Ident = '', [string]$Key = '')
    try {
        $path = Get-NDAdmissionPath -AdmissionDir $AdmissionDir -Key $Key
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        if (-not (Test-Path -LiteralPath $path)) { return $true }
        $idChk = Assert-NDDirIdentity -Path $AdmissionDir -Expected $Ident
        if (-not [bool](Get-NDValue $idChk 'ok' $false)) { return $false }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop } catch { return $false }
        return $true
    }
    catch { return $false }
}

function Test-NDAdmissionDecision {
    <#
    .SYNOPSIS
        Decisao de admissao de UM subagent dispatch, sem host (G1-B).
        Fail-closed: DUVIDA = DENY.
    .DESCRIPTION
        Logica PURA, extraida do plugin de permissao para ser testavel
        sem runtime OpenCode. O plugin JS espelha exatamente estas
        regras (paridade documentada no proprio plugin). Ordem:

          1. admission ausente                 -> deny admission-absent;
          2. forma minima invalida            -> deny admission-shape-invalid
             (chave 32 hex, sessao, chamada, agente, generation >= 1,
             expires_at_utc parseavel, fencing.ok booleano true);
          3. expirado (agora > expires_at_utc) -> deny admission-expired;
          4. goal divergente                   -> deny admission-goal-mismatch;
          5. sessao divergente                 -> deny admission-session-mismatch;
          6. chamada divergente                -> deny admission-call-mismatch;
          7. agente divergente                 -> deny admission-agent-mismatch;
          8. generation obsoleta               -> deny admission-generation-stale;
          9. model/provider fora do autorizado -> deny
             admission-model-not-authorized /
             admission-provider-not-authorized;
         10. nada disso                        -> allow.

        Regras adicionais pos-G1-FIX: fencing sem goal ACTIVE
        registrado nega (admission-goal-not-active; snapshot do CLAIM,
        nao leitura viva); owner divergente do ExpectedOwner nega
        (admission-owner-mismatch, so com ExpectedOwner preenchido);
        restricao de model/provider vazia = sem restricao, mas restricao
        preenchida com identidade da invocacao vazia nega (fail-closed).

        generation obsoleta = a admissao foi emitida para um generation
        MENOR do que a viva: houve takeover/renew desde a claim.
        Devolve @{allow, reason}. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $Admission = $null,
        [string]$GoalId = '',
        [string]$SessionId = '',
        [string]$CallId = '',
        [string]$Agent = '',
        [string]$Model = '',
        [string]$Provider = '',
        [long]$ExpectedGeneration = 0,
        [string]$ExpectedOwner = '',
        [datetime]$NowUtc = ([DateTime]::MinValue)
    )
    try {
        $deny = {
            param([string]$Why)
            return [pscustomobject]@{ allow = $false; reason = $Why }
        }
        if ($null -eq $Admission) { return (& $deny 'admission-absent') }
        $keyTok = Get-NDJsonStringValue -Object $Admission -Name 'idempotency_key'
        if (($null -eq $keyTok) -or (([string]$keyTok).Trim().ToLowerInvariant() -cnotmatch '^[a-f0-9]{32}$')) { return (& $deny 'admission-shape-invalid') }
        $sessTok = Get-NDJsonStringValue -Object $Admission -Name 'session_id'
        if (($null -eq $sessTok) -or ([string]::IsNullOrWhiteSpace(([string]$sessTok).Trim()))) { return (& $deny 'admission-shape-invalid') }
        $callTok = Get-NDJsonStringValue -Object $Admission -Name 'call_id'
        if (($null -eq $callTok) -or ([string]::IsNullOrWhiteSpace(([string]$callTok).Trim()))) { return (& $deny 'admission-shape-invalid') }
        $agentTok = Get-NDJsonStringValue -Object $Admission -Name 'agent'
        if (($null -eq $agentTok) -or ([string]::IsNullOrWhiteSpace(([string]$agentTok).Trim()))) { return (& $deny 'admission-shape-invalid') }
        $genTok = Get-NDJsonIntegralLong -Object $Admission -Name 'generation'
        if (($null -eq $genTok) -or ($genTok -lt 1)) { return (& $deny 'admission-shape-invalid') }
        $fence = Get-NDValue $Admission 'fencing' $null
        $fenceOk = $null
        if ($null -ne $fence) { $fenceOk = Get-NDJsonBoolValue -Object $fence -Name 'ok' }
        if (($null -eq $fenceOk) -or (-not [bool]$fenceOk)) { return (& $deny 'admission-fencing-invalid') }
        # Snapshot de goal gravado no CLAIM: fora de ACTIVE a admissao
        # nasceu (ou envelheceu) sem autoridade viva - nega. Residual
        # honesto: isto confere o ESTADO REGISTRADO, nao o goal vivo;
        # takeover apos o CLAIM so e visivel com leitura do kernel no
        # momento do evaluate (fora do alcance desta funcao pura).
        $fenceGoalState = ''
        if ($null -ne $fence) {
            $fgsTok = Get-NDJsonStringValue -Object $fence -Name 'goal_state'
            if ($null -ne $fgsTok) { $fenceGoalState = (([string]$fgsTok).Trim().ToUpperInvariant()) }
        }
        if ($fenceGoalState -cne 'ACTIVE') { return (& $deny 'admission-goal-not-active') }
        $fenceOwner = ''
        if ($null -ne $fence) {
            $fowTok = Get-NDJsonStringValue -Object $fence -Name 'owner'
            if ($null -ne $fowTok) { $fenceOwner = ([string]$fowTok).Trim() }
        }
        if ((-not [string]::IsNullOrWhiteSpace($ExpectedOwner)) -and ($fenceOwner -cne ([string]$ExpectedOwner).Trim())) { return (& $deny 'admission-owner-mismatch') }
        # PS5.1/PS7: o ConvertFrom-Json do PS7 materializa ISO-8601 como
        # [DateTime]; Get-NDJsonInstantString normaliza (ver funcao).
        $expTok = Get-NDJsonInstantString -Object $Admission -Name 'expires_at_utc'
        if ($null -eq $expTok) { return (& $deny 'admission-shape-invalid') }
        $exp = [DateTime]::MinValue
        $parsed = $false
        try { $parsed = [DateTime]::TryParse(([string]$expTok), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$exp) }
        catch { $parsed = $false }
        if ((-not $parsed) -or ($exp -eq [DateTime]::MinValue)) { return (& $deny 'admission-shape-invalid') }
        $now = $NowUtc
        if ($now -eq [DateTime]::MinValue) { $now = [DateTime]::UtcNow }
        if ($now.ToUniversalTime() -gt $exp.ToUniversalTime()) { return (& $deny 'admission-expired') }
        $admGoal = Get-NDJsonStringValue -Object $Admission -Name 'goal_id'
        if (($null -eq $admGoal) -or (([string]$admGoal).Trim() -cne ([string]$GoalId).Trim())) { return (& $deny 'admission-goal-mismatch') }
        if (([string]$sessTok).Trim() -cne ([string]$SessionId).Trim()) { return (& $deny 'admission-session-mismatch') }
        if (([string]$callTok).Trim() -cne ([string]$CallId).Trim()) { return (& $deny 'admission-call-mismatch') }
        if (([string]$agentTok).Trim() -cne ([string]$Agent).Trim()) { return (& $deny 'admission-agent-mismatch') }
        if (([long]$ExpectedGeneration -gt 0) -and ([long]$genTok -lt [long]$ExpectedGeneration)) { return (& $deny 'admission-generation-stale') }
        # Restricao vazia/ausente = sem restricao (paridade com o
        # plugin). Restricao preenchida com identidade da invocacao
        # vazia = deny fail-closed: omitir model/provider nao contorna
        # uma restricao gravada. Residual: a identidade vem dos
        # args/metadata da chamada, nao do modelo efetivamente
        # resolvido pelo host.
        $allowedModel = Get-NDJsonStringValue -Object $Admission -Name 'allowed_model'
        $allowedModelNorm = ''
        if ($null -ne $allowedModel) { $allowedModelNorm = ([string]$allowedModel).Trim() }
        $modelNorm = ([string]$Model).Trim()
        if ($allowedModelNorm -cne '') {
            if ($modelNorm -ceq '') { return (& $deny 'admission-model-not-authorized') }
            if ($allowedModelNorm -cne $modelNorm) { return (& $deny 'admission-model-not-authorized') }
        }
        $allowedProvider = Get-NDJsonStringValue -Object $Admission -Name 'allowed_provider'
        $allowedProviderNorm = ''
        if ($null -ne $allowedProvider) { $allowedProviderNorm = ([string]$allowedProvider).Trim() }
        $providerNorm = ([string]$Provider).Trim()
        if ($allowedProviderNorm -cne '') {
            if ($providerNorm -ceq '') { return (& $deny 'admission-provider-not-authorized') }
            if ($allowedProviderNorm -cne $providerNorm) { return (& $deny 'admission-provider-not-authorized') }
        }
        return [pscustomobject]@{ allow = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ allow = $false; reason = 'admission-internal-error' }
    }
}

# ---------------------------------------------------------------------
# (D) Avanco causal: so CONTINUE/RETRY preparam a proxima task
# ---------------------------------------------------------------------
function Get-NDAdvanceDir {
    <#
    .SYNOPSIS
        Subdiretorio de advance records de UM goal (G1-D). Fail-closed.
    .DESCRIPTION
        Mesmo rationale do admission dir: `<GoalReceiptDir>/advance/`
        mantem o registro FORA do namespace de recibos para nao ser
        confundido com recibo pela varredura de exclusao de efeito.
    #>
    [CmdletBinding()]
    param([string]$RootDir = '', [string]$GoalId = '')
    try {
        $nsState = Resolve-NDGoalReceiptDir -RootDir $RootDir -GoalId $GoalId
        $nsDir = [string](Get-NDValue $nsState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($nsDir)) {
            return [pscustomobject]@{ ok = $false; reason = 'advance-dir-unresolvable'; dir = ''; ident = '' }
        }
        $sub = Join-Path $nsDir 'advance'
        # Mesma ordem do admission dir: criar, depois checar reparse.
        try {
            if (-not (Test-Path -LiteralPath $sub -PathType Container)) { [void][IO.Directory]::CreateDirectory($sub) }
        }
        catch { return [pscustomobject]@{ ok = $false; reason = 'advance-dir-unresolvable'; dir = ''; ident = '' } }
        if (-not (Test-NDPathWithoutReparsePoint -Path $sub)) {
            return [pscustomobject]@{ ok = $false; reason = 'advance-dir-reparse-point'; dir = ''; ident = '' }
        }
        $ident = Get-NDDirCreationTimeUtcTicks -Path $sub
        if ([string]::IsNullOrWhiteSpace($ident)) {
            return [pscustomobject]@{ ok = $false; reason = 'advance-dir-unresolvable'; dir = ''; ident = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; dir = $sub; ident = $ident }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'advance-dir-unresolvable'; dir = ''; ident = '' } }
}

function Write-NDAdvanceRecord {
    <#
    .SYNOPSIS
        Persiste UM advance record (temp+move, identidade reassertada).
    .DESCRIPTION
        Mesma disciplina de `Write-NDAdmissionRecord`: identidade do
        diretorio reassertada antes do temporario e antes do Move,
        destino EXATO arquivo regular sem reparse point, prova
        pos-escrita. Devolve $true somente quando persistiu. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$AdvanceDir = '', [string]$Ident = '', [string]$Key = '', $Record = $null)
    try {
        if ($null -eq $Record) { return $false }
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (($k -cnotmatch '^[a-f0-9]{32}$') -or ([string]::IsNullOrWhiteSpace($AdvanceDir))) { return $false }
        $idPre = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
        if (-not [bool](Get-NDValue $idPre 'ok' $false)) { return $false }
        $path = Join-Path $AdvanceDir ($k + '.advance.json')
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        }
        $json = ConvertTo-Json -InputObject $Record -Depth 12 -Compress
        $tmp = Join-Path $AdvanceDir (('advance-' + [IO.Path]::GetRandomFileName() + '.tmp'))
        try { [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false)) } catch { return $false }
        $idMove = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
        if (-not [bool](Get-NDValue $idMove 'ok' $false)) { return $false }
        try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop } catch { return $false }
        $idPost = Assert-NDDirIdentity -Path $AdvanceDir -Expected $Ident
        if (-not [bool](Get-NDValue $idPost 'ok' $false)) { return $false }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $false }
        try {
            $back = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if (([string]::IsNullOrWhiteSpace($back)) -or ($back.IndexOf($k, [StringComparison]::Ordinal) -lt 0)) { return $false }
        }
        catch { return $false }
        return $true
    }
    catch { return $false }
}

function Read-NDAdvanceRecord {
    <#
    .SYNOPSIS
        Le UM advance record (objeto JSON) ou devolve $null. Somente
        leitura, bounded, fail-closed. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$AdvanceDir = '', [string]$Key = '')
    try {
        $k = ([string]$Key).Trim().ToLowerInvariant()
        if (($k -cnotmatch '^[a-f0-9]{32}$') -or ([string]::IsNullOrWhiteSpace($AdvanceDir))) { return $null }
        $path = Join-Path $AdvanceDir ($k + '.advance.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        if (-not (Test-NDPathWithoutReparsePoint -Path $path)) { return $null }
        $rd = Read-NDBoundedFileText -Path $path -MaxBytes 65536
        if (-not [bool](Get-NDValue $rd 'ok' $false)) { return $null }
        $text = [string](Get-NDValue $rd 'text' '')
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        if (-not (Test-NDJsonObjectRootText -Text $text)) { return $null }
        try { return (ConvertFrom-Json $text) } catch { return $null }
    }
    catch { return $null }
}

function New-NDAdvanceEnvelope {
    <#
    .SYNOPSIS
        Envelope compacto do avanco causal (G1-D).
    .DESCRIPTION
        `prepared=$true` afirma apenas que UM preparo da proxima task
        foi persistido; `ok=$false` com `prepared=$false` e recusa.
        `executor_calls` e sempre 0: nada aqui executa worker.
    #>
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [string]$Move = '',
        [string]$MoveReason = '',
        [string]$StopReason = '',
        [string]$GoalId = '',
        [string]$SettledKey = '',
        [bool]$Prepared = $false,
        [string]$IdempotencyKey = '',
        [string]$Reference = '',
        [string]$TaskId = '',
        [string]$Agent = '',
        [string]$RecordPath = '',
        [int]$ExecutorCalls = 0
    )
    return [pscustomobject][ordered]@{
        ok = [bool]$Ok
        reason = ([string]$Reason)
        move = ([string]$Move)
        move_reason = ([string]$MoveReason)
        stop_reason = ([string]$StopReason)
        goal_id = ([string]$GoalId)
        settled_key = ([string]$SettledKey)
        prepared = [bool]$Prepared
        idempotency_key = ([string]$IdempotencyKey)
        reference = ([string]$Reference)
        task_id = ([string]$TaskId)
        agent = ([string]$Agent)
        record_path = ([string]$RecordPath)
        executor_calls = [int]$ExecutorCalls
    }
}

function Invoke-OrchestrationNativeDispatchAdvance {
    <#
    .SYNOPSIS
        Avanco causal pos-liquidacao (G1-D): consulta o ObjectiveController
        e SOMENTE em CONTINUE/RETRY prepara a proxima task.
    .DESCRIPTION
        Ordem fixa, fail-closed:
          (a) forma do goal e da chave liquidada;
          (b) raiz dos recibos + autorizacao viva
              (`Test-NativeDispatchAuthorization`);
          (c) goal VIVO lido do store e fencing pos-lido
              (`Test-NDPostLockFencing`): goal fora de ACTIVE, ownership
              trocada ou lease expirada recusam em 'advance-stale-goal'
              SEMPRE sem prepare;
          (d) status do objetivo: `-ObjectiveStatus` quando o chamador o
              fornece, senao DERIVADO do goal vivo (estado, tarefas
              ativas, criterios pendentes) - mesma forma que
              `Get-OrchestrationGoalNextMove` usa, sem duplicar a lista
              de moves;
          (e) consulta ao ObjectiveController (`Get-OrchestrationNextMove`,
              lazy dot-source do sibling quando indisponivel) e validacao
              do move contra o conjunto FECHADO
              {CONTINUE, RETRY, REPLAN, BLOCKED, COMPLETE}. Moves fora
              desse conjunto (ROTATE_CONTEXT, DELEGATE, qualquer coisa
              nova) recusam em 'advance-move-unknown' - prepare cego
              nunca acontece;
          (f) revalidacao viva da proxima task quando ela existe
              (admissao do kernel + budget). Falha aqui produz
              move BLOCKED sem prepare;
          (g) decisao persistida em `<GoalReceiptDir>/advance/<chave>.advance.json`;
          (h) SOMENTE CONTINUE/RETRY executam
              `Invoke-OrchestrationNativeDispatchPrepare` e devolvem o
              novo idempotency key. COMPLETE finaliza o goal SOMENTE por
              CAS (`Set-OrchestrationGoalStatePersisted` com
              ExpectedRevision) e somente quando `-FinalizeGoalOnComplete`
              e pedido; REPLAN marca replan sem prepare; BLOCKED nao
              prepara nada.

        NAO ha Executor nem re-despacho: `executor_calls` e sempre 0.
        Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$SettledKey = '',
        $Authorization = $null,
        $ObjectiveStatus = $null,
        $NextIntent = $null,
        [string]$SessionId = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$GoalStoreDir = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [int]$LockTimeoutMs = 60000,
        [switch]$FinalizeGoalOnComplete
    )
    try {
        $gid = ([string]$GoalId).Trim()
        $sk = ([string]$SettledKey).Trim().ToLowerInvariant()
        if (([string]::IsNullOrWhiteSpace($gid)) -or ($gid.Length -gt 128)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-goal-invalid')
        }
        if ($sk -cnotmatch '^[a-f0-9]{32}$') {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-key-invalid' -GoalId $gid)
        }
        $dir = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -GoalId $gid -SettledKey $sk)
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [void][IO.Directory]::CreateDirectory($dir) }
        }
        catch { return (New-NDAdvanceEnvelope -Ok $false -Reason 'receipt-dir-unresolvable' -GoalId $gid -SettledKey $sk) }
        $auth = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir -ActivationLogDir $dir
        if (-not [bool](Get-NDValue $auth 'admitted' $false)) {
            $authWhy = ([string](Get-NDValue $auth 'reason' 'authorization-denied'))
            # Goal terminal / fora de ACTIVE e STALE por definicao: a
            # autorizacao ja recusa antes do fencing, e a razao publica do
            # avanco continua sendo 'advance-stale-goal' (nunca prepare).
            if ((($authWhy.IndexOf('goal-terminal', [StringComparison]::OrdinalIgnoreCase)) -ge 0) -or (($authWhy.IndexOf('goal-not-active', [StringComparison]::OrdinalIgnoreCase)) -ge 0)) {
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-stale-goal' -GoalId $gid -SettledKey $sk)
            }
            return (New-NDAdvanceEnvelope -Ok $false -Reason $authWhy -GoalId $gid -SettledKey $sk)
        }
        $authOwner = ([string](Get-NDValue $Authorization 'owner' '')).Trim()
        $authGen = [long](Get-NDValue $Authorization 'generation' 0)
        $fenceNow = Test-NDPostLockFencing -GoalId $gid -Owner $authOwner -Generation $authGen -GoalStoreDir $GoalStoreDir
        if (-not [bool](Get-NDValue $fenceNow 'ok' $false)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-stale-goal' -GoalId $gid -SettledKey $sk)
        }
        $goalSlot = $null
        try { $goalSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $goalSlot = $null }
        if (($null -eq $goalSlot) -or (-not [bool](Get-NDValue $goalSlot 'ok' $false))) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-goal-unreadable' -GoalId $gid -SettledKey $sk)
        }
        $goal = Get-NDValue $goalSlot 'goal' $null
        if ($null -eq $goal) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-goal-unreadable' -GoalId $gid -SettledKey $sk)
        }
        $goalState = ''
        try { $goalState = (([string](Get-NDValue $goal 'state' '')).Trim().ToUpperInvariant()) } catch { $goalState = '' }
        $goalRevision = 0
        try { $goalRevision = [long](Get-NDValue $goal 'revision' 0) } catch { $goalRevision = 0 }
        # (c2) G1-D-FIX prova de liquidacao: o avanco exige o recibo da
        #      SettledKey em phase 'settled', do MESMO goal, com evidencia
        #      vinculada. Chave inexistente, phase divergente ou evidencia
        #      ausente recusam em 'advance-settlement-unproven' SEMPRE sem
        #      prepare - nenhuma chave fabricada avanca causalidade.
        $advRState = Resolve-NDGoalReceiptDir -RootDir $dir -GoalId $gid
        $advRDir = [string](Get-NDValue $advRState 'dir' '')
        if ([string]::IsNullOrWhiteSpace($advRDir)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-settlement-unproven' -GoalId $gid -SettledKey $sk)
        }
        $advRead = Read-NDReceipt -Dir $advRDir -Key $sk -Expected ([string](Get-NDValue $advRState 'created_utc' '')) -AllowHandoffPhases
        if (-not [bool](Get-NDValue $advRead 'ok' $false)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-settlement-unproven' -GoalId $gid -SettledKey $sk)
        }
        $advSettled = Get-NDValue $advRead 'receipt' $null
        if ($null -eq $advSettled) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-settlement-unproven' -GoalId $gid -SettledKey $sk)
        }
        $advPhase = ([string](Get-NDValue $advSettled 'phase' '')).Trim().ToLowerInvariant()
        $advGoal = ([string](Get-NDValue $advSettled 'goal_id' '')).Trim()
        $advEv = ([string](Get-NDValue $advSettled 'evidence_id' '')).Trim()
        if ((($advPhase -cne 'settled') -or ($advGoal -cne $gid) -or ([string]::IsNullOrWhiteSpace($advEv)))) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-settlement-unproven' -GoalId $gid -SettledKey $sk)
        }
        # (c3-lock) G1-D-FIX exclusao do avanco: o lock do subdiretorio
        #      advance (dir diferente do lock do recibo e do task lock:
        #      sem deadlock com o
        #      PREPARE interno) serializa leitura-decisao-preparo por goal.
        #      Duas chamadas concorrentes para a mesma SettledKey nunca
        #      preparam intents distintos: a segunda encontra o record da
        #      primeira. Contencao real recusa 'advance-lock-busy'.
        $advDirEarly = Get-NDAdvanceDir -RootDir $dir -GoalId $gid
        if (-not [bool](Get-NDValue $advDirEarly 'ok' $false)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason ([string](Get-NDValue $advDirEarly 'reason' 'advance-dir-unresolvable')) -GoalId $gid -SettledKey $sk)
        }
        $advLockWhy = ''
        $advLock = Open-NDReceiptLock -Dir ([string](Get-NDValue $advDirEarly 'dir' '')) -LockTimeoutMs $LockTimeoutMs -Expected ([string](Get-NDValue $advDirEarly 'ident' '')) -RefusalReason ([ref]$advLockWhy)
        if ($null -eq $advLock) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-lock-busy' -GoalId $gid -SettledKey $sk)
        }
        try {
        # (c3) G1-D-FIX idempotencia + vinculo do intent: SOMENTE record
        #      com prepared=true devolve a decisao gravada sem novo
        #      PREPARE. Decisao terminal que nao prepara (BLOCKED/REPLAN/
        #      COMPLETE com ok=false) devolve o stored deterministico.
        #      Record pendente ou falho de CONTINUE/RETRY exige o MESMO
        #      next_idempotency_key do intent corrente
        #      ('advance-intent-mismatch' se divergir,
        #      'advance-intent-unknown' se o pendente nao o registra):
        #      recovery nunca troca a decisao apos o PREPARE, e queda
        #      pos-PREPARE reconcilia exclusivamente o preparo vinculado
        #      (PREPARE do mesmo intent e idempotente na camada de recibos).
        #      Ausencia COMPROVADA vs registro ilegivel: caminho existente
        #      que nao le (truncado, malformado, reparse, ilegivel) recusa
        #      em 'advance-intent-unknown' SEMPRE sem prepare e preserva o
        #      arquivo - nunca se trata corrupcao como ausencia, senao um
        #      segundo sucessor nasceria para a mesma liquidacao.
        $advRecPath = Join-Path ([string](Get-NDValue $advDirEarly 'dir' '')) ($sk + '.advance.json')
        $prior = Read-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $advDirEarly 'dir' '')) -Key $sk
        if (($null -eq $prior) -and (Test-Path -LiteralPath $advRecPath)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-intent-unknown' -GoalId $gid -SettledKey $sk)
        }
        if ($null -ne $prior) {
            $priorGoal = ([string](Get-NDValue $prior 'goal_id' '')).Trim()
            $priorKey = ([string](Get-NDValue $prior 'settled_key' '')).Trim().ToLowerInvariant()
            $priorMove = ([string](Get-NDValue $prior 'move' '')).Trim().ToUpperInvariant()
            $priorOk = [bool](Get-NDValue $prior 'ok' $true)
            $priorPrepared = [bool](Get-NDValue $prior 'prepared' $false)
            if ((($priorGoal -ceq $gid) -and ($priorKey -ceq $sk) -and (@('CONTINUE', 'RETRY', 'REPLAN', 'BLOCKED', 'COMPLETE') -ccontains $priorMove))) {
                if ($priorPrepared) {
                    $advReplay = (New-NDAdvanceEnvelope -Ok $priorOk -Reason ([string](Get-NDValue $prior 'reason' '')) -GoalId $gid -SettledKey $sk -Move $priorMove -MoveReason ([string](Get-NDValue $prior 'move_reason' '')) -StopReason ([string](Get-NDValue $prior 'stop_reason' '')) -Prepared $true -IdempotencyKey ([string](Get-NDValue $prior 'next_idempotency_key' '')) -Reference ([string](Get-NDValue $prior 'next_reference' '')) -TaskId ([string](Get-NDValue $prior 'next_task_id' '')) -Agent ([string](Get-NDValue $prior 'next_agent' '')) -RecordPath (Join-Path ([string](Get-NDValue $advDirEarly 'dir' '')) ($sk + '.advance.json')))
                    return $advReplay
                }
                if ((@('BLOCKED', 'REPLAN', 'COMPLETE') -ccontains $priorMove)) {
                    return (New-NDAdvanceEnvelope -Ok $priorOk -Reason ([string](Get-NDValue $prior 'reason' '')) -GoalId $gid -SettledKey $sk -Move $priorMove -MoveReason ([string](Get-NDValue $prior 'move_reason' '')) -StopReason ([string](Get-NDValue $prior 'stop_reason' '')) -Prepared $false -RecordPath (Join-Path ([string](Get-NDValue $advDirEarly 'dir' '')) ($sk + '.advance.json')))
                }
                $priorNext = ([string](Get-NDValue $prior 'next_idempotency_key' '')).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($priorNext)) {
                    return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-intent-unknown' -GoalId $gid -SettledKey $sk)
                }
                $curNextKey = ''
                if ($null -ne $NextIntent) {
                    $curReal = Get-NDValue $NextIntent 'intent' $null
                    if ($null -eq $curReal) { $curReal = $NextIntent }
                    $curNextKey = ([string](Get-NDValue $curReal 'idempotency_key' '')).Trim().ToLowerInvariant()
                }
                if (([string]::IsNullOrWhiteSpace($curNextKey)) -or ($curNextKey -cne $priorNext)) {
                    return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-intent-mismatch' -GoalId $gid -SettledKey $sk)
                }
            }
        }
        # (d) status do objetivo.
        $status = $ObjectiveStatus
        if ($null -eq $status) {
            $activeTasks = @()
            try { $activeTasks = @((Get-NDValue $goal 'active_tasks' @())) } catch { $activeTasks = @() }
            $criteria = @()
            try { $criteria = @((Get-NDValue $goal 'criteria' @())) } catch { $criteria = @() }
            $satisfied = 0
            try {
                $prog = Get-NDValue $goal 'progress' $null
                if ($null -ne $prog) { $satisfied = [long](Get-NDValue $prog 'satisfied' 0) }
            }
            catch { $satisfied = 0 }
            if ($satisfied -lt 0) { $satisfied = 0 }
            if ($satisfied -gt @($criteria).Count) { $satisfied = @($criteria).Count }
            $remaining = @()
            foreach ($t in @($activeTasks)) { $remaining += ([string]$t) }
            for ($i = $satisfied; $i -lt @($criteria).Count; $i++) { $remaining += ('criterion:' + [string]$criteria[$i]) }
            $terminalBlocker = $null
            if ($goalState -ceq 'EXHAUSTED') { $terminalBlocker = 'GOAL_HARD_BUDGET_EXHAUSTED' }
            elseif ($goalState -ceq 'CANCELLED') { $terminalBlocker = 'CANCELLED' }
            $status = @{
                objective_completed = ($goalState -ceq 'COMPLETED')
                remaining_work = [string[]]$remaining
                authorized = (@('BLOCKED', 'CANCELLED', 'EXHAUSTED', 'BUDGET_LIMITED') -cnotcontains $goalState)
                blocker_kind = ''
                progress_possible = ($goalState -ceq 'ACTIVE')
                strategy_change = $false
                context_degraded = $false
                last_failure = $null
                terminal_blocker = $terminalBlocker
                consecutive_no_progress = [long]0
            }
            if ($goalState -ceq 'BUDGET_LIMITED') { $status['blocker_kind'] = 'policy' }
        }
        $ocCmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
        if ($null -eq $ocCmd) {
            $sibling = Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1'
            if (Test-Path -LiteralPath $sibling -PathType Leaf) { try { . $sibling } catch { } }
            $ocCmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
        }
        if ($null -eq $ocCmd) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-controller-unavailable' -GoalId $gid -SettledKey $sk)
        }
        if (-not (Test-OrchestrationObjectiveStatus -Status $status)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-status-invalid' -GoalId $gid -SettledKey $sk)
        }
        $moveObj = $null
        try { $moveObj = Get-OrchestrationNextMove -Status $status } catch { $moveObj = $null }
        if ($null -eq $moveObj) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-next-move-failed' -GoalId $gid -SettledKey $sk)
        }
        $move = ''
        try { $move = (([string](Get-NDValue $moveObj 'move' '')).Trim().ToUpperInvariant()) } catch { $move = '' }
        $moveReason = ''
        try { $moveReason = ([string](Get-NDValue $moveObj 'reason' '')) } catch { $moveReason = '' }
        $stopReason = ''
        try { $stopReason = ([string](Get-NDValue $moveObj 'stop_reason' '')) } catch { $stopReason = '' }
        # (e) conjunto FECHADO: fora dele nunca ha prepare.
        $accepted = @('CONTINUE', 'RETRY', 'REPLAN', 'BLOCKED', 'COMPLETE')
        if ($accepted -cnotcontains $move) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-move-unknown' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason)
        }
        # (f) revalidacao viva da proxima task (so quando existir).
        $admitReason = ''
        $budgetReason = ''
        $nextPrepared = $false
        if (($move -ceq 'CONTINUE') -or ($move -ceq 'RETRY')) {
            if ($null -eq $NextIntent) {
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-next-intent-missing' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason)
            }
            $realIntent = Get-NDValue $NextIntent 'intent' $null
            if ($null -eq $realIntent) { $realIntent = $NextIntent }
            $nextTask = ([string](Get-NDValue $realIntent 'task_id' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($nextTask)) {
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-next-intent-invalid' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason)
            }
            # Vinculo do intent (M2): a chave do proximo intent e extraida
            # AQUI e reservada no record pendente; recovery so aceita o
            # mesmo intent, e o PREPARE que devolver outra chave recusa.
            $nextKeyPre = ([string](Get-NDValue $realIntent 'idempotency_key' '')).Trim().ToLowerInvariant()
            if (($nextKeyPre -cnotmatch '^[a-f0-9]{32}$')) {
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-next-intent-invalid' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason)
            }
            $admit = Test-NDLiveTaskAdmission -Intent $realIntent -Authorization $Authorization -Goal $goal -TasksDir $TasksDir -FlagsPath $FlagsPath -RepoRoot $RepoRoot
            if (-not [bool](Get-NDValue $admit 'ok' $false)) { $admitReason = ([string](Get-NDValue $admit 'reason' 'admission-denied')) }
            else {
                $budget = Test-NDTaskAttemptBudget -TaskId $nextTask -TasksDir $TasksDir -RepoRoot $RepoRoot
                if (-not [bool](Get-NDValue $budget 'ok' $false)) { $budgetReason = ([string](Get-NDValue $budget 'reason' 'attempt-budget-unknown')) }
            }
            if ((-not [string]::IsNullOrWhiteSpace($admitReason)) -or (-not [string]::IsNullOrWhiteSpace($budgetReason))) {
                $blockedReason = $admitReason
                if ([string]::IsNullOrWhiteSpace($blockedReason)) { $blockedReason = $budgetReason }
                $dirState = Get-NDAdvanceDir -RootDir $dir -GoalId $gid
                $recordPath = ''
                if ([bool](Get-NDValue $dirState 'ok' $false)) {
                    $rec = [ordered]@{
                        schema_version = 1
                        goal_id = $gid
                        settled_key = $sk
                        move = 'BLOCKED'
                        move_reason = $blockedReason
                        prepared = $false
                        goal_state = $goalState
                        goal_revision = $goalRevision
                        admission_reason = $admitReason
                        budget_reason = $budgetReason
                        recorded_at = ([DateTime]::UtcNow.ToString('o'))
                    }
                    $recPath = Join-Path ([string](Get-NDValue $dirState 'dir' '')) ($sk + '.advance.json')
                    if (Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $dirState 'dir' '')) -Ident ([string](Get-NDValue $dirState 'ident' '')) -Key $sk -Record $rec) { $recordPath = $recPath }
                }
                return (New-NDAdvanceEnvelope -Ok $false -Reason ('advance-blocked:' + $blockedReason) -GoalId $gid -SettledKey $sk -Move 'BLOCKED' -MoveReason $blockedReason -RecordPath $recordPath)
            }
        }
        # (g)+(h) decisao persistida e, so em CONTINUE/RETRY, PREPARE.
        $finalizeReason = ''
        if ($move -ceq 'COMPLETE') {
            if ($FinalizeGoalOnComplete) {
                $fin = Set-OrchestrationGoalStatePersisted -GoalId $gid -ToState 'COMPLETED' -ExpectedRevision $goalRevision -StoreDir $GoalStoreDir -OwnerId $authOwner -OwnershipGeneration $authGen
                if (($null -eq $fin) -or (-not [bool](Get-NDValue $fin 'ok' $false))) {
                    $finalizeReason = ([string](Get-NDValue $fin 'reason' 'goal-finalize-refused'))
                }
            }
            else { $finalizeReason = 'goal-finalization-not-requested' }
        }
        $dirState = Get-NDAdvanceDir -RootDir $dir -GoalId $gid
        if (-not [bool](Get-NDValue $dirState 'ok' $false)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason ([string](Get-NDValue $dirState 'reason' 'advance-dir-unresolvable')) -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason)
        }
        $recPath = Join-Path ([string](Get-NDValue $dirState 'dir' '')) ($sk + '.advance.json')
        # (g)+(h) G1-D-FIX decisao pendente primeiro: persiste prepared=false
        #      ANTES do PREPARE e so marca prepared=true (+ next_*) DEPOIS
        #      do PREPARE ok. Falha de PREPARE nunca deixa registro
        #      afirmando preparo inexistente; replay da mesma chave usa (c3)
        #      e nunca prepara duas vezes (PREPARE do mesmo intent e
        #      idempotente na camada de recibos).
        $rec = [ordered]@{
            schema_version = 1
            ok = $true
            reason = ''
            goal_id = $gid
            settled_key = $sk
            move = $move
            move_reason = $moveReason
            stop_reason = $stopReason
            prepared = $false
            next_idempotency_key = $nextKeyPre
            next_reference = ''
            next_task_id = ''
            next_agent = ''
            prepare_reason = ''
            goal_state = $goalState
            goal_revision = $goalRevision
            finalize_reason = $finalizeReason
            recorded_at = ([DateTime]::UtcNow.ToString('o'))
        }
        if (-not (Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $dirState 'dir' '')) -Ident ([string](Get-NDValue $dirState 'ident' '')) -Key $sk -Record $rec)) {
            return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-record-write-failed' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -RecordPath $recPath)
        }
        if (($move -ceq 'CONTINUE') -or ($move -ceq 'RETRY')) {
            $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $NextIntent -Authorization $Authorization -SessionId $SessionId -ReceiptDir $ReceiptDir -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath -LockTimeoutMs $LockTimeoutMs
            if (-not [bool](Get-NDValue $prep 'ok' $false)) {
                $prepWhy = [string](Get-NDValue $prep 'reason' 'prepare-refused')
                $rec['ok'] = $false
                $rec['reason'] = ('advance-prepare-refused:' + $prepWhy)
                $rec['prepare_reason'] = $prepWhy
                [void](Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $dirState 'dir' '')) -Ident ([string](Get-NDValue $dirState 'ident' '')) -Key $sk -Record $rec)
                return (New-NDAdvanceEnvelope -Ok $false -Reason ('advance-prepare-refused:' + $prepWhy) -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -RecordPath $recPath)
            }
            $prepIntent = Get-NDValue $prep 'intent' $null
            $prepKey = ''
            if ($null -ne $prepIntent) { $prepKey = ([string](Get-NDValue $prepIntent 'idempotency_key' '')).Trim().ToLowerInvariant() }
            # O PREPARE do MESMO intent devolve a MESMA chave; divergencia
            # significa que o preparo nao corresponde a decisao reservada -
            # nunca se registra vinculo falso (fail-closed, sem reescrita).
            if (($prepKey -cne $nextKeyPre) -or ([string]::IsNullOrWhiteSpace($prepKey))) {
                $rec['ok'] = $false
                $rec['reason'] = 'advance-key-mismatch'
                $rec['prepare_reason'] = 'advance-key-mismatch'
                [void](Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $dirState 'dir' '')) -Ident ([string](Get-NDValue $dirState 'ident' '')) -Key $sk -Record $rec)
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-key-mismatch' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -RecordPath $recPath)
            }
            $rec['prepared'] = $true
            $rec['next_idempotency_key'] = $prepKey
            $rec['next_reference'] = ([string](Get-NDValue $prep 'reference' ''))
            $rec['next_task_id'] = ([string](Get-NDValue $prep 'task_id' ''))
            $rec['next_agent'] = ([string](Get-NDValue $prep 'agent' ''))
            if (-not (Write-NDAdvanceRecord -AdvanceDir ([string](Get-NDValue $dirState 'dir' '')) -Ident ([string](Get-NDValue $dirState 'ident' '')) -Key $sk -Record $rec)) {
                return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-record-write-failed' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -Prepared $true -IdempotencyKey $prepKey -Reference ([string](Get-NDValue $prep 'reference' '')) -TaskId ([string](Get-NDValue $prep 'task_id' '')) -Agent ([string](Get-NDValue $prep 'agent' '')) -RecordPath $recPath)
            }
            return (New-NDAdvanceEnvelope -Ok $true -Reason '' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -Prepared $true -IdempotencyKey $prepKey -Reference ([string](Get-NDValue $prep 'reference' '')) -TaskId ([string](Get-NDValue $prep 'task_id' '')) -Agent ([string](Get-NDValue $prep 'agent' '')) -RecordPath $recPath)
        }
        return (New-NDAdvanceEnvelope -Ok $true -Reason '' -GoalId $gid -SettledKey $sk -Move $move -MoveReason $moveReason -StopReason $stopReason -Prepared $false -RecordPath $recPath)
        }
        finally {
            try { $advLock.Dispose() } catch { }
        }
    }
    catch {
        return (New-NDAdvanceEnvelope -Ok $false -Reason 'advance-internal-error')
    }
}
