# F1 S4 — Recovery atribuído por sessão substituta (limitada, fixture-only)

Status: PLANEJADO — **S4 limitada**; pending automático e commit ambíguo ficam
manual/HOLD. Flags OFF; sem claim runtime-real.
Base: `master` `e70f96b` (S3a `577951e` mergeada).
Branch/worktree: `feat/f1-s4-settled-recovery` em
`C:/Users/walis/AppData/Local/Temp/opencode/oc-s4-settled-recovery`.
Classificação: `AUTHORITY_CHANGE` residual (limitada) — decisão do Planner
registrada abaixo; reviewer + security obrigatórios.

## 1. Objetivo

Entregar uma interface explícita de **recovery atribuído**: uma sessão
substituta (descritor de host) pode solicitar a recuperação de um settlement
cujo **advance já está preparado ou terminal**, com atribuição durável de
quem pediu, por quê, com qual autorização e sobre quais provas; o replay é
delegado à continuação S3a e o checkpoint ausente pode ser reconstruído a
partir dos registros canônicos. Estados pendentes/ambíguos **nunca são
repetidos automaticamente**: viram `blocked-manual` atribuído (sem mutar
goal/task/receipt/advance) ou recusa.

A S4 **não** altera o comportamento da S3a, do ND, do TaskKernel, do plugin
ou de flags; **não** cria novo PREPARE/CLAIM/SETTLE/worker; **não** adquire ou
transfere owner; **não** promove sessão substituta a autoridade.

## 2. Decisão do Planner (2026-10-20)

Adotado o parecer do architect (`F1-S4-ARCHITECT-MEMO`) com a seguinte
decisão explícita sobre a única questão bloqueante:

1. **"Nenhum novo PREPARE" é interpretação estrita.** A S4 não materializa
   preparo novo em nenhuma circunstância. O ADVANCE pendente não é replayed
   pela S4: mesma chave não prova o mesmo intent (o pending record não guarda
   fingerprint integral nem sessão histórica), e o ADVANCE do ND pode criar
   PREPARE quando o recibo está ausente. Portanto **pending automático =
   HOLD/manual**, não S4.
2. **A S4 limitada entrega**: atribuição durável; replay de advance
   `prepared`/terminal já validado; reconstrução de checkpoint a partir de
   registros canônicos; `blocked-manual` atribuído para pending/ambíguo com
   identidade causal suficiente.
3. **S4 integral (pending auto) não é autorizada** nesta rodada. Reabrir
   somente com decisão explícita sobre: contrato ND `reuse-only` (ou prova
   integral do intent + fingerprint + sessão histórica), tratamento de
   takeover/identidade e decisão de operador; com reviewer + security.
4. **Sessão substituta é descritor**, não capability. Autoridade continua
   `Authorization{goal_id,owner,generation,explicit_allow,source}` +
   ownership/lease viva do GoalKernel. A S4 nunca chama Acquire/Takeover/Renew
   nem altera owner da task.
5. **`blocked-manual` não muta domínio**: escreve somente o registro de
   atribuição; `effects.domain_mutated=false`,
   `effects.attribution_written=true`.
6. **A S4 é aditiva**: a S3a permanece dona de SETTLE/ADVANCE/PREPARE,
   continuação e COMPLETE/CAS; a S4 apenas revalida pré-condições e delega o
   replay permitido.

## 3. Não-objetivos e HOLD

- Recuperar automaticamente advance/receipt pendente; repetir ADVANCE/PREPARE;
  materializar intent; rebindar sessão histórica.
- Chamar CLAIM, SETTLE, verifier, gates de conclusão ou worker.
- Mutar Goal.state/task/receipt/advance em `blocked-manual`; adquirir owner;
  reativar goal.
- Alterar S3a/AL, ND, TaskKernel, plugin, grants ou flags.
- Alegar runtime-real, S6, G3 ou enforcement.
- Confirm automático de recibo `pending` (procedimento existente separado e
  autorizado permanece manual).

## 4. Contrato

### 4.1 `Invoke-OrchestrationSettledRecovery`

Entradas:
- `GoalId`, `SettledKey`, `Authorization` (objeto; nunca autoridade implícita)
- `SubstituteSessionId` (descritor de host; forma validada)
- `ReasonCode` (enumerado e limitado)
- `NextIntent` opcional (apenas referência de comparação; nunca autoridade)
- diretórios canônicos existentes (`GoalStoreDir`, `ReceiptDir`, `TasksDir`,
  advance dir, evidence), `RepoRoot`, `FlagsPath`, `LockTimeoutMs`.

Saídas (objeto):
```
ok, action, reason, cause_reason
goal_id, settled_key
recovery_record_ref, assignment_fingerprint
next_idempotency_key, next_reference, prepared
checkpoint_id, checkpoint_ok
effects { domain_mutated, attribution_written, checkpoint_written }
executor_calls = 0
manual_followup_required
```
Nunca aceitar `Outcome`, `approved`, `verified`, `force` como autoridade.
`prepared=true` descreve preparo canônico existente; **não** autoriza consumo
pela sessão substituta.

Códigos: `recovery-request-invalid`, `recovery-authorization-denied`,
`recovery-ownership-stale`, `recovery-assignment-mismatch`,
`recovery-record-uncertain`, `recovery-lock-busy`,
`recovery-intent-unproven`, `recovery-pending-manual-required`,
`recovery-settlement-ambiguous`, `recovery-record-write-failed`,
`recovery-no-continuation`, `recovery-already-completed`,
`recovery-successor-unproven` (nota F1-S4-FIX1, 2026-10-20: recusa honesta
quando o recibo sucessor do replay `prepared` está ausente, ilegível,
divergente ou com fase inesperada; sem PREPARE, sem checkpoint, sem
atribuição de sucesso).
Códigos S3a/ND preservados em `cause_reason`; nunca fabricar COMPLETE.

### 4.2 Registro de recovery

Arquivo separado `<settledKey>.recovery.json` no advance dir existente.
Registro de **atribuição/resultado**, nunca fonte de autorização nem substituto
de recibo.

```
schema_version
goal_id, settled_key, source_task_id
assignment_fingerprint
substitute_session_id
authorization_owner, authorization_generation, authorization_source
reason_code
action (= envelope terminal efetivo: `replay-*` quando ok, `blocked` quando
  recusado, `blocked-manual` na atribuição manual)
intended_action (intenção classificada que o fingerprint vincula;
  F1-S4-FIX3: a transição registrada→terminal é validada)
proof_refs { receipt, advance, evidence_id, candidate_revision,
             next_key, next_intent_fingerprint, original_prepare_session_id }
phase = reserved | recorded
result { ok, reason, cause_reason, prepared, next_idempotency_key,
         next_reference, checkpoint_id, checkpoint_ok, effects }
created_at, recorded_at
```
- `assignment_fingerprint`: hash determinístico de sessão substituta,
  owner/generation/source, ação, motivo, goal/settled key/task e vínculos
  causais; timestamp não participa.
- Mesma atribuição → resultado terminal determinístico; autorização viva
  continua necessária para novas escritas.
- Atribuição divergente → `recovery-assignment-mismatch`; nunca sobrescrever.
- `reserved` após crash não prova ausência de efeito: reler stores canônicos;
  nunca converter interrupção em sucesso presumido.
- Registro ilegível/não-arquivo/reparse → preservar e recusar.
- Não persistir prompt, segredo ou Authorization completo.

### 4.3 Lock e concorrência

- Lock exclusivo específico de recovery, por settled key, em arquivo distinto
  dos locks do ND; timeout limitado (`recovery-lock-busy`).
- Escrita temporária no mesmo diretório, validação, publicação atômica sem
  sobrescrever o primeiro registro; atualização do resultado sob o mesmo lock.
- Não manter lock do ND ao chamar a S3a; o replay S3a não adquire lock do
  advance para o caminho prepared/terminal.
- Reutilizar as defesas de identidade de diretório/reparse do ND quando
  aplicáveis; não criar store paralelo.
- Cobertura multiprocesso com processos externos reais (F1-S4-FIX2,
  2026-10-20): mesma atribuição (determinística), atribuições distintas
  (mismatch sem sobrescrita) e timeout do lock; o que vale é o lock
  exclusivo por settled key, não o processo chamador.

### 4.4 Fluxo

1. Validar pedido, sessão, GoalId/SettledKey e autorização correlacionada
   (`Test-NativeDispatchAuthorization`; goal exatamente igual).
2. Ler goal e registros canônicos (advance, recibo, evidência, task,
   worker_result, sucessor `prepared` quando houver, checkpoint).
3. Classificar o estado **antes** de criar atribuição (tabela §5),
   incluindo a vinculação do sucessor para replay `prepared`.
4. Para ação mutante permitida: adquirir lock, **revalidar autorização/
   ownership/lease e estado vivo do goal** (F1-S4-FIX1, 2026-10-20: a
   espera pode exceder o lease ou um takeover; COMPLETED na espera é
   reconhecido sem mutação), reler advance + sucessor, resolver o
   registro existente (mesma atribuição → replay/terminal; divergente →
   mismatch; `reserved` → reler efeitos) e reservar.
5. Executar somente a ação permitida: replay S3a `prepared`/terminal já
   validado; reconstrução de checkpoint a partir de registros canônicos;
   `blocked-manual` (somente registro).
6. Persistir `recorded` com resultado honesto; liberar lock.
7. Recusas de entrada/cross-goal/estado não suportado/sucessor não
   vinculado: sem escritura de domínio e sem atribuição (quando
   inválidas; o pós-lock também não escreve).

## 5. Tabela de estados

| Estado | Ação permitida / prova | Recusa e efeitos |
|---|---|---|
| Advance `prepared=true` | Auth viva, settlement válido, correlação e integridade do sucessor (recibo `prepared` com goal/key/task/agent/reference vinculados); replay S3a/checkpoint | Sucessor ausente/divergente: recusa `recovery-successor-unproven`, sem PREPARE; não rebindar sessão |
| Advance terminal COMPLETE, goal ACTIVE | Settlement válido, stop `OBJECTIVE_COMPLETED`, auth viva; S3a valida conclusão e CAS | Sem gate/CAS válido: bloqueio, nunca sucesso presumido |
| Goal já COMPLETED | Reconhecer por leitura canônica; sem novo CAS | Sem nova atribuição mutante |
| Advance BLOCKED/REPLAN | Replay atribuído com vínculos válidos | Nenhuma mutação do goal |
| Advance pending CONTINUE/RETRY | Classificar; atribuir `blocked-manual` | Replay ND automático HOLD |
| Pending mesma chave, conteúdo diferente | Recusa `recovery-intent-unproven` | Zero efeito de domínio; chave não prova intent |
| Receipt `pending` | Apontar Confirm existente, separado e autorizado | Não chamar Confirm automaticamente |
| Receipt claimed, commit ambíguo | `blocked-manual` | Sem retry/release/evidência fabricada |
| Evidência ilegível/ausente | `blocked-manual` com causa precisa | Sem ND/S3a com efeitos |
| `worker_result` divergente/superseded | Recusa causal | Sem herdar aprovação posterior |
| Checkpoint ausente | Reconstruir apenas de registros canônicos válidos | Ausência não autoriza novo sucessor |
| Advance ausente | Retornar ao caminho normal; `recovery-no-continuation` | Zero PREPARE |
| Registro ilegível/não-arquivo/reparse | Preservar e recusar | Nunca tratar como ausente |
| Cross-goal/task | Recusa antes da atribuição | Sem escrita em domínio alheio |
| Auth inválida / ownership perdida | Recusa; revalidar após espera | Sem novo efeito de domínio |
| Estado desconhecido | Recusa | Desconhecido ≠ ausente |

## 6. Invariantes

1. Autorização explícita e ownership viva para operações mutantes.
2. Sessão é descritor, não capability.
3. Recovery não adquire/transfere owner nem reativa goal.
4. `blocked-manual` não muda goal/task/receipt/advance.
5. Nenhum novo PREPARE, worker, CLAIM ou SETTLE.
6. Nenhuma segunda sucessão por `(goal_id, settled_key)`.
7. COMPLETE somente com autorização e CAS vivos.
8. Correlação cross-goal/task obrigatória.
9. Checkpoint/recovery record não concedem autoridade.
10. Refusal pré-ação não muda domínio; auditoria/projeção explicitamente
    contabilizadas (`attribution_written`/`checkpoint_written`).
11. Resultado `reserved` ou transporte interrompido nunca significa
    “não executou”.
12. Referência preparada histórica não é autorização da sessão substituta.

## 7. Arquivos

Novos:
- `scripts/v3/lib/OrchestrationSettledRecovery.ps1`
- `scripts/v3/lib/OrchestrationSettledRecovery.tests.ps1`
- este plano.

Alterados: `CHANGELOG.md` (`[Unreleased]`), evidência/documentação viva conforme
convenção. **Sem alterações** em S5, S3a/AL, ND, TaskKernel, plugin, grants ou
flags.

## 8. Testes (PS5.1 e PS7)

- prepared replay, terminal replay e checkpoint reconstruído.
- Sessão substituta diferente, sessão inválida, auth ausente/falsa/
  `test-callback`, owner/generation stale, lease expirada.
- Takeover externo válido: atribuição permitida; nenhuma transferência
  implícita de intent/task.
- Pending: mesma chave+mesmo conteúdo; mesma chave+conteúdo diferente; chave
  diferente; ausência de fingerprint/sessão histórica → manual/recusa.
- Receipt pending, claimed ambíguo, evidência ilegível, resultado superseded.
- COMPLETE sem critérios/stop/auth; CAS conflitante.
- `blocked-manual` com hashes/revisões de domínio inalterados.
- Registro corrompido, atribuição divergente, crash antes/depois da reserva e
  do checkpoint.
- Dois processos: mesma atribuição, atribuições distintas, timeout do lock.
- Adversarial: remover/trocar recibo entre inspeções; nenhum fallback para
  criação.
- Sentinela: zero worker/CLAIM/SETTLE/PREPARE nos caminhos da S4 estrita.
- Regressões `OrchestrationSettledContinuation.tests.ps1`, ND handoff/advance
  e compatibilidade sem `SettledKey`.

## 9. Aceite

Suíte nova verde em PS5.1 e PS7; regressões S3a/ND verdes; reviewer APPROVED +
security APPROVED (autoridade residual); nenhum PREPARE/CLAIM/SETTLE/worker;
ND/AL/TaskKernel/plugin/flags intocados; `git diff --check` limpo; CHANGELOG/
plano atualizados; PR separado, merge commit, sem squash.

## 10. Residual/HOLD honesto

- Pending automático, ADVANCE replay e commit ambíguo continuam
  manual/HOLD; a S4 limitada não os resolve.
- Sem prova de autenticação da sessão substituta (descritor), sem transação
  atômica entre stores e sem runtime-real.
- A S4 integral só reabre com contrato ND `reuse-only`/prova integral de
  intent + decisão de operador + reviewer/security.

## 11. Nota F1-S4-FIX3 (2026-10-20) — endurecimento pós-lock e de registro

- Revalidação do settlement sob o lock (recibo + `worker_result` +
  evidência idênticos à classificação; divergência → recusa sem escrita
  nem checkpoint). A S3a delegada continua sem revalidar auth após o
  despacho — janela residual declarada (§10).
- Sucessor com integridade semântica recalculada + fingerprint integral
  do NextIntent quando fornecido.
- Publicação com desambiguação (written/published/absent/uncertain);
  falha parcial preserva efeitos/referências conhecidos + followup manual.
- `intended_action` persistido e vinculado ao fingerprint (sem varredura
  de candidatos); transição intenção→terminal validada; `result`
  carrega o envelope terminal efetivo, reproduzido verbatim na reentrada.
- Cobertura multiprocesso com barreira observável (mesma atribuição,
  atribuições distintas, timeout do lock); F1b força o takeover, F1c o
  recibo adulterado e F2d o sucessor removido durante a espera do lock.
  F2g fixa o tamper de scope com nominais intactos
  (`successor-integrity-invalid`); S13f fixa a desambiguação
  `published`/`uncertain`/`absent` do `Publish-SRRecoveryRecord`.
- F1-S4-FIX4 F3 (2026-10-20): `published` exige a publicação solicitada
  comprovada (fase/intenção/ação/resultado); reserva anterior com o mesmo
  fingerprint → `uncertain` com efeitos/referências conhecidos +
  follow-up manual (S13g; sentinela S17).
- F1-S4-FIX5 (2026-10-20): terminais `blocked` exigem `result.ok=false`
  (e `prepared=true` exige `next_key`); a troca apenas de `action`
  `prepared`→`blocked` mantendo o resultado de sucesso é recusada na
  validação de forma antes da reentrada verbatim (variante 9 de S13e
  `action-to-blocked-with-ok-result`, assert de checkpoint e sentinela
  S17); suíte 1083 asserts em PS5.1 e pwsh.
- CI (2026-10-20): a suíte é descoberta pelo runner V3
  (`scripts/v3/lib/*.tests.ps1`); o step V3 do ps7/v2 lane passou de 40
  para 60 min e os jobs de 50 para 75 min para absorver a suíte
  multiprocesso. Nenhum skip/continue-on-error; os testes continuam
  integralmente executados.
