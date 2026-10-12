# Planner Native Handoff & Autonomous Continuation — SPEC

**Projeto:** opencode-orchestration  
**Versão:** 1.0 (revisada após G0, 2026-10-09)  
**Base:** Autonomous Core v0.1.2, `b38c92bc8b3ab334a9dffad609f3515350336061`  
**Tipo:** integração produtiva corretiva  
**Status:** PROPOSED — G0 confirmado; implementação segura bloqueada em G1  
**Plano:** [`PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md`](PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md)  
**Auditoria:** [`../audits/AUTONOMOUS-CORE-RUNTIME-ACCEPTANCE-2026-10-09.md`](../audits/AUTONOMOUS-CORE-RUNTIME-ACCEPTANCE-2026-10-09.md)

## 1. Problema e causa-raiz confirmada

O Autonomous Core v0.1.2 contém kernels, controller, bridge de dispatch,
driver limitado e recuperação. O caminho produtivo entre eles, porém, não está
wireado. No checkout-base, `Invoke-OrchestrationObjectiveStep` é chamado pelo
driver e testes; `Invoke-OrchestrationAutonomousObjective`, promoção de Goal e
ativação produtiva não têm caller de produto. Sem `Executor`, o step produz
`dispatch_intent` e o driver termina em `awaits-planner`.

O `Executor` atual de `Invoke-OrchestrationNativeDispatch` é um scriptblock
síncrono invocado pelo processo PowerShell após admissão e recibo `pending`.
Ele não é um ponto suspenso que permita ao Planner chamar sua ferramenta nativa.
Executar primeiro o worker e depois importar seu resultado por esse callback
inverteria a ordem de segurança. O plugin V2 atual injeta contexto e observa
`execute.before`; ele não cria workers nem fornece enforcement de autorização.

**Causa-raiz:** falta o Planner Runtime Wiring. Não é um problema demonstrado de
provider nem uma justificativa para daemon, API privada ou novo framework.

## 2. Objetivo e critério de sucesso

Concluir, numa sessão real e sem mensagem manual de continuação:

`PREPARE → NATIVE SUBAGENT → SETTLE → VERIFICATION → ADVANCE → NEXT TASK`

Uma Task multifase e recuperação por sessão substituta também precisam ser
comprovadas. Critérios runtime-real permanecem obrigatórios; mocks, callbacks
PowerShell, texto do Planner/worker, documentos, hooks observacionais e
assertions sintéticas não satisfazem esses critérios.

## 3. Escopo e não objetivos

### Incluído

- Caller produtivo do Planner para Goal promotion/resume, NativeDispatch,
  ObjectiveController/Loop, settlement, checkpoint e recovery.
- Contratos separados para preparar, chamar ferramenta nativa, liquidar,
  verificar e avançar; correlação de Goal/Task/intent/session/run.
- Compatibilidade independente para V2 (`subagent`) e V1 (`task`), somente
  quando comprovadas no binário pinado.
- Validação host-real, bounded execution, evidência sanitizada e regressões.

### Fora do escopo

- Reescrever Goal Kernel/Task Kernel ou criar framework/daemon/Swarm/Arena.
- Spawn por endpoint privado, CLI inventada, plugin ou scriptblock PowerShell.
- Ativar `runtime_grant_enforcement` sem prova de deny no binário exato.
- Tratar prompt, hook fail-open, output textual ou autoclassificação do modelo
  como autorização ou provenance confiável.
- Fixtures de teste que alterem projetos de produção, configuração global,
  credenciais ou providers.

## 4. Invariantes

1. **Planner executa a ferramenta nativa.** Só usar a tool model-callable
   realmente exposta na sessão: `subagent` V2 ou `task` V1. Nenhuma chamada
   presumida de TaskTool por plugin/PowerShell.
2. **Kernel é autoridade durável.** Goal, Task, ownership, generation,
   tentativa, grants, recibos, evidências e conclusão vêm do store/kernel; a
   mensagem do modelo é input não confiável.
3. **Autorização precede efeito e é efetiva.** Interseção User ∩ Project ∩
   Runtime ∩ Grants. Uma intenção consultiva ou callback executado depois do
   spawn não autoriza o efeito.
4. **Provenance do host.** Texto retornado pelo worker não prova que uma tool
   ocorreu, qual agente a executou, nem que pertence à intent. Sem vínculo
   independente, o resultado é claim não verificado.
5. **Ambiguidade não faz replay.** Crash/timeout após possível efeito mantém
   estado de reconciliação; ausência de resultado não prova ausência de efeito.
6. **Candidato não é verificação.** `candidate_pass` não implica `VERIFIED`,
   Task concluída ou Goal concluído.
7. **Bounded e recuperável.** Budgets, ownership, generation, fencing, CAS,
   watchdog, checkpoint e stop conditions existentes permanecem obrigatórios.
8. **Sem garantia filesystem excessiva.** Documentar TOCTOU residual de PS 5.1;
   não alegar atomicidade que o mecanismo não fornece.

## 5. Contrato funcional desejado

### PREPARE

Uma operação de kernel/bridge valida schema, identidade, Goal/Task vivos,
revisão, ownership/generation/fencing, autorização/grants, agente e escopo,
budget, idempotency key e ausência de tentativa conflitante. Persiste a
tentativa e recibo antes de emitir um contrato imutável, de uso único e
expirável, vinculado a prompt hash, sessão Planner, autorização e revisão.

PREPARE não executa worker. Até que um consumidor confiável possa aplicar a
autorização imediatamente antes do efeito, o retorno não pode ser apresentado
como permissão de execução: deve ser `BLOCKED` ou explicitamente consultivo.

### NATIVE HANDOFF

O Planner consome somente uma PREPARE válida e chama o agente/tool autorizado
com o escopo e critérios preparados. O contrato deve chegar à chamada sem
alteração material. Falta da tool ou de capacidade de enforcement resulta em
`NATIVE_TOOL_UNAVAILABLE`/`BLOCKED`, sem fallback não governado.

### SETTLE

SETTLE revalida intent, Goal/Task, ownership/generation/revision e correlação;
registra resultado permitido (`candidate_pass`, `failed`, `blocked`), EvidenceRef
e provenance no store canônico; atualiza Task Kernel e receipt de forma
idempotente. Um único componente é dono da escrita do worker result; não
duplicar `ProductiveActivation` e `NativeDispatch`.

Se a execução não puder ser correlacionada por dado host-originated, aceitar no
máximo um claim não verificado para investigação, sem evidência de execução,
sem verificação e sem avanço que dependa dela. Um resultado divergente/atrasado
ou de outra sessão/geração é recusado.

### VERIFY / ADVANCE

O Verifier autorizado valida critérios da Task. Depois de settlement e
verificação, ObjectiveController relê estado canônico, persiste movimento e
checkpoint. Planner executa `CONTINUE`, `RETRY` ou `REPLAN` apenas sob budget e
autorização atuais; `ROTATE_CONTEXT`/recovery exige retomada autorizada;
`BLOCKED` para; `COMPLETE` requer critérios globais verificados e estado
persistido. Um movimento serializado mas não consumido não conta como avanço.

### RECOVERY

Nova sessão localiza Goal/checkpoint, revalida ownership e reconcilia toda
tentativa pendente. Uma tentativa ambígua não é repetida. O novo Planner só
executa a próxima ação após evidência suficiente e autorização atual; prova
exige ação atribuída à sessão substituta, não apenas leitura de canário.

## 6. Máquina de estados

`PREPARED → DISPATCH_UNCERTAIN → RUNNING → RESULT_RECEIVED → SETTLED → VERIFIED → ADVANCED`

Terminais/alternativos: `BLOCKED`, `RECONCILIATION_REQUIRED`. Transições
duráveis são CAS/idempotentes. `DISPATCH_UNCERTAIN` deve ser persistido antes
da fronteira do efeito. Nenhuma transição inferida apenas de texto; `ADVANCED`
exige consumo da ação ou bloqueio estruturado.

## 7. Requisitos e aceite

| ID | Critério de aceite runtime-real |
|---|---|
| AC-01 | Planner recebe Objective na sessão real. |
| AC-02 | Goal é criado/recuperado sem comando especial. |
| AC-03 | PREPARE persiste intenção autorizada. |
| AC-04 | Ferramenta nativa de subagent é chamada. |
| AC-05 | Chamada é correlacionada à intenção. |
| AC-06 | Worker executa trabalho real. |
| AC-07 | Resultado é reconciliado no Task Kernel. |
| AC-08 | Evidência é persistida no store canônico. |
| AC-09 | Planner executa próxima ação automaticamente. |
| AC-10 | Uma falha recuperável gera correção e revalidação. |
| AC-11 | Reviewer participa quando requerido. |
| AC-12 | Duplicata não produz novo efeito indevido. |
| AC-13 | Retomada de sessão consome estado persistido. |
| AC-14 | Operação não autorizada é recusada. |
| AC-15 | Goal termina somente após critérios verificados. |
| AC-16 | CI, distribuição e testes de regressão aprovados. |

### Critério de conclusão (inalterado)

A funcionalidade só será aceita quando uma sessão real executar
`PREPARE → SUBAGENT NATIVO → SETTLE → VERIFICATION → CONTINUE` sem intervenção
humana entre etapas, e uma Task multifase avançar automaticamente após a
primeira entrega. Recovery precisa provar consumo independente do contexto e
execução pela sessão substituta. Critério central sem prova mantém o veredito
`PARTIAL CLOSURE`; não se substitui por mock, callback, simulação ou evidência
textual do modelo.

Os requisitos detalhados RF-01..RF-12 acima complementam AC-01..AC-16; nenhum
critério original foi rebaixado para obter closure.

## 8. Segurança e modos de falha

Cobrir: PREPARE negado/expirado, Goal/Task terminal, revision stale, owner e
generation stale, duas sessões consumindo mesma intent, colisão/duplicata,
crash antes/depois de spawn/resultado/evidence/kernel/receipt, output forjado,
cross-session/cross-task/late result, falta de provenance, grant negado,
budget zero/exaurido, Task DONE sem verifier, plugin ausente/falhando,
reparse/junction/symlink e tentativas de replay. Nenhum teste pode transformar
`runtime_grant_enforcement` OFF em autorização.

## 9. Baseline de runtime e limitações observadas

- Pins do projeto: OpenCode V2 `2.0.23`, V1 `1.18.34`; engines PS5.1 e PS7.
- Host nesta revisão: `opencode --version` e `opencode2 --version` retornam
  `2.0.26`; perfil local V2 contém package/binário `2.0.23`. Perfil V1 pinado
  não foi encontrado neste host.
- Docs oficiais descrevem tool `subagent` (V2) e `task` (V1) como chamada pelo
  modelo. Isso não comprova comportamento do binário exato.
- Probe isolado no V2 `2.0.23` (binário SHA-256 registrado em
  `evidence/v3.1/runtime-reliability/native-handoff-hook-probe-2026-10-09.json`)
  comprovou `execute.before`/`execute.after` na chamada nativa `subagent` e
  que `throw` em `execute.before` recusou a chamada testada antes de retornar
  resultado/ID de child. A correlação observada inclui parent session,
  message ID, tool call ID, caller/target agent e child session ID no resultado.
  Isso valida a primitiva no fixture; não valida PREPARE/kernel, plugin ausente,
  mutation/order de hooks, grants do worker, V1 ou settlement produtivo.
- Probe isolado adicional no mesmo V2 pin (`native-handoff-permission-hook-probe-2026-10-10.json`)
  demonstrou `permission.evaluate` deny-only em chamadas nativas do child:
  `read`/`edit` sintéticos in-scope passaram; out-of-scope mudaram de `allow`
  para `deny`, sem conteúdo ou escrita negados; um comando shell literal e
  inofensivo também foi negado. O evento do child contém `sessionID`, `agent`,
  `action`, `resources` e source message/call; o API público
  `ctx.session.get(childSessionID)` devolveu `parentID` e a localização do
  projeto no fixture global.
  `ctx.permission.rules` **não** estava disponível no contexto Promise do pin.
  Isso é evidência de fixture para as ações testadas, não prova de integração
  kernel, cobertura geral de shell/MCP/Code Mode ou resiliência a unload.
- Evidência histórica 2.0.23: `parentID` em resposta GET ambíguo e deny em
  `/shell` fail-open. `runtime_grant_enforcement` permanece OFF.
- O plugin V2 distribuído ainda é observacional/fail-open; os novos probes
  usaram plugins temporários isolados, não o bundle integrado. Nenhum hook de
  resultado é autoridade por si só.
- Questões/limitações e fonte da evidência estão no audit de aceite ligado acima.

## 10. Classe e decisão de escopo

Classe: `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING`. Mudança de autoridade,
flag, runtime, grant ou pin exige gate humano e prova específica; esta SPEC não
autoriza essas alterações. Não criar ADR até haver uma decisão durável nova
que não esteja coberta pelo ADR vigente.

**Decisão de G0/G1:** causa-raiz confirmada. NativeDispatch agora contém
PREPARE e CLAIM duráveis no receipt store canônico, revisados e testados
hermeticamente; os probes V2 2.0.23 comprovam veto pre-effect, lineage do child
e negação fixture de `read`/`edit` e um shell command literal via
`permission.evaluate`. **G1
produtivo permanece bloqueado**: não há caller/bridge ligando esses contratos
ao bundle distribuído, settlement/TaskKernel/VERIFY/ADVANCE, nem fonte
independente de autorização configurada para a integração. O plugin atual é
fail-open e `runtime_grant_enforcement` permanece OFF; ausência/unload do gate,
linguagem shell além do comando sintético, MCP/Code Mode e proteção contra
mutação/ordem de hooks não foram comprovados. V1 segue sem prova. Não alegar
PASS nem alterar o critério de conclusão.
