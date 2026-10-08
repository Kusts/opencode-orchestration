# OBJECTIVE RUNTIME CONTRACT — Universal Autonomous Orchestration v0.1.0

**Repository:** `Kusts/opencode-orchestration`
**Revision date:** 2026-10-08
**Status:** REVISED-BY-PLANNER (proposta normativa; implementação nas Fases 1–6 do CORRECTIVE-PLAN)
**Companions:** SPEC (`UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md` §§9–15),
PLAN (`…-PLAN.md` Fases 5/6/10), CORRECTIVE-PLAN (`…-CORRECTIVE-PLAN.md`).

Este contrato especifica o **executor produtivo mínimo (opção B)** que fecha o
gap do addendum §2/§9.3: compor Kernel/Controller/adapters em operação real.
Não duplica SPEC/PLAN/ADR/ARCHITECTURE — apenas os amarra em obrigações
executáveis.

---

## 1. Adapter (RuntimeAdapter)

Superfície mínima por runtime (matriz SUPPORTED/VERIFIED/UNSUPPORTED/HOLD por
op × V1 `opencode-ai@1.18.34` × V2 `@opencode/cli@2.0.23`; primeiro provar
API→efeito→observável, nunca presumir equivalência V1/V2):

`detectCapabilities`, `identifySession`, `getSessionState`, `dispatchWorker`,
`observeWorkerResult`, `waitForSettlement`, `requestPlannerContinuation`,
`restoreContext`, `cancelAuthorizedExecution`, `recordRuntimeEvidence`.

Cada op declara: entrada tipada, identidade exigida, autorização
(envelope §7), resultado, timeout, erro fechado, fallback e prova exigida.

## 2. Eventos (sem busy polling)

O executor é **event-driven**: `Task settled`, `wave barrier`,
`worker result`, `checkpoint`, `external reconciled`, `session reconciled`.
Espera via `waitForSettlement`/typed waits com deadline; polling ocupado é
proibido (watchdog sinaliza `NO_PROGRESS`/`HARD_TIMEOUT` em shadow/enforce).

## 3. Ownership (CAS + lease + fencing por geração)

Um mutador por Goal por vez. Toda mutação exige CAS sobre `revision` +
lease viva + fencing token da geração (identidade pid+creation-ticks).
Owner obsoleto é rejeitado fail-closed; operações atômicas sob o lock do
store; crash entre dispatch e settlement é estado declarado (`PENDING` +
reconciliação obrigatória na retomada, nunca conclusão presumida).

## 4. Dispatch (DispatchIntent + idempotency key)

Nenhum dispatch sem `DispatchIntent` persistida antes do efeito. Chave de
idempotência estável: `goal_id + work_item_id + action_revision`.
Na retomada/duplicata: checar existe → ativa? → resultado? → repetição segura?
Efeitos externos exigem reconciliação com a fonte; **exactly-once nunca é
presumido** (no máximo once + reconciliação declarada).

## 5. Recovery

Sequência obrigatória: reabrir → revalidar (identidade + geração) →
reconciliar (observações caller-declared, `probed=false` salvo probe
conclusivo) → verificar efeitos → restaurar mínimo → continuar.
Sessão sumida ≠ Task falha; `mark_SESSION_LOST` exige prova conclusiva;
ausência desconhecida nunca vira sucesso.

## 6. Checkpoints

Checkpoint Goal-aware atômico (save/load, resume fail-closed; store
inverificável recusa). Inclui TDRs, evidence refs, decisions e next_move
consumido — retomada nunca rediscute decisão válida sem evidência de
invalidação.

## 7. Authorization envelope

Toda ação produtiva é admitida pela interseção
`User ∩ Project ∩ Runtime ∩ Grants`. Fora da interseção: negar fail-closed
com reason (`POLICY_BLOCKED`/deny específico). `PRODUCTION_AUTHORIZED=true`
só com autorização explícita para aquele ambiente — nunca autoriza por si só
dano irreversível nem credenciais. `runtime_grant_enforcement` HOLD ⇒ sem
deny runtime: o executor **bloqueia ou restringe** a ação afetada (fallback
§9), nunca a libera silenciosamente.

## 8. Stop reasons (contrato fechado)

`OBJECTIVE_COMPLETED`, `HUMAN_AUTHORITY_REQUIRED`,
`EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE`, `GOAL_HARD_BUDGET_EXHAUSTED`,
`POLICY_BLOCKED`, `CANCELLED`. Qualquer outro resultado retorna ao control
plane (CONTINUE/RETRY/REPLAN/DELEGATE/ROTATE_CONTEXT); worker/task budget
exhaustion nunca encerra Objective — só Goal hard budget é terminal.

Orçamento persistido por Goal (obrigação): consumo acumulado Worker/Task/Goal
persistido no Goal record (base: `evidence/v3.1/runtime-reliability/phase23.json`,
record-only, sem números novos); continuidade após retomada/recovery sem reset
silencioso, com revalidação na retomada; ligado ao watchdog
(`NO_PROGRESS`/`HARD_TIMEOUT`); exhaustion terminal
(`GOAL_HARD_BUDGET_EXHAUSTED`) validada em runtime recusando novos efeitos,
sem falso DONE.

## 9. Fallback

- Jev indisponível ⇒ determinístico (Rules → Planner); nunca bloqueia o
  Objective.
- Enforcement HOLD ⇒ bloquear/restringir a ação sem deny provado; registrar
  e escalar ao Planner/operador.
- Credencial/transporte ausente ⇒ fail-closed com token estruturado
  (`*_NOT_CONFIGURED`/`*_UNAVAILABLE` + `fallback_continue` quando opcional).

## 10. Executor: pequeno, model-independent, conector

O executor é um loop pequeno e independente de modelo que **CONECTA**
GoalKernel/TaskKernel, ObjectiveController, adapters e EvidenceStore — e
**NÃO duplica o raciocínio do Planner**: nunca produz `next_move` sem consumir
o anterior via Controller; nunca decide conteúdo, só avança o ciclo
(dispatch real → barrier → evidência verificada → progress → checkpoint →
next_move) até stop contratual ou COMPLETE verificado pelo kernel.
