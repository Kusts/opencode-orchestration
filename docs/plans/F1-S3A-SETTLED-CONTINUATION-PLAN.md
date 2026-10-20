# F1 S3a — Settled Continuation (fixture-only) — PLANO

Status: **IMPLEMENTADO (fixture-only)** — branch `feat/f1-s3a-settled-continuation`.
Base: memo do architect (F1-S3A-DESIGN) + discovery F1-S3-DISCOVERY.
Escopo: fixture-only; **não** fecha G3/S6 (runtime-real/quota).

## Objetivo

Adicionar ao loop Planner um caminho explícito pós-SETTLE que consome o settlement canônico, aplica verificação/review conforme policy, chama o ADVANCE existente e termina em PREPARED, REPLAN_REQUIRED, BLOCKED ou COMPLETED — sem executar worker e sem duplicar o driver.

## Não-objetivos

- Não tocar plugin/enforcement/flags; nenhuma flag OFF ativada.
- Não criar novo daemon/flag/store/framework/loop.
- Não alegar autonomia runtime-real, Reviewer real, recovery S4 ou G3.
- Não alterar o contrato legado sem `SettledKey`.
- Não usar a PA como autoridade (PA é projeção observacional).

## Decisão de composição

- Nova função `Invoke-OrchestrationSettledContinuation` em `scripts/v3/lib/OrchestrationAutonomousLoop.ps1`.
- `Invoke-OrchestrationObjectiveStep` encaminha para ela quando receber `SettledKey` explícita; sem `SettledKey`, comportamento legado inalterado.
- ND permanece dono de SETTLE, advance record e PREPARE; GoalKernel é autoridade de estado/CAS; Verifier/TaskKernel de verificação/review/DONE; AL compõe e persiste checkpoint.

## Contrato

### Entradas (referências, não provas)

`GoalId`, `SettledKey`, `Authorization`, `SessionId`, diretórios de goal/task/receipt/evidence/checkpoint, `NextIntent` apenas quando houver sucessor autorizado, descritor de validação/perfis allowlisted, contexto de decisão do Planner correlacionado à revisão viva.

Não aceitar `verified=true`/`approved=true`/`task_done=true` do chamador como substitutos da leitura canônica.

### Saída (envelope compacto)

`ok, action, reason, cause_reason, goal_id, settled_key, evidence_id, candidate_revision, move, stop_reason, advance_record_ref, next_idempotency_key, next_reference, prepared, checkpoint_id, checkpoint_ok, executor_calls=0`.

`ok` = processamento válido; **não** significa objetivo concluído. Só `action=completed` confirmado no GoalKernel permite essa afirmação.

### Pré-condições

- Goal vivo `ACTIVE`, ownership/generation/lease válidos; `PAUSED/BLOCKED/BUDGET_LIMITED` não autoriza continuar (não reativar).
- Recibo legível, semanticamente íntegro, `phase=settled`, mesmo goal/task. **Não** reutilizar a prova `claimed` do SETTLE.
- Evidência existente e correlacionada; `worker_result` persistido compatível com o recibo.
- Estado vivo da task + verificação/review atuais.
- `Test-OrchestrationNativeDispatchSettlementProof` valida `claimed` no SETTLE; aqui usar leitores/integridade de recibo `settled` e evidência.

### Códigos estáveis

`continuation-settlement-unproven`, `continuation-settlement-uncertain`, `continuation-task-result-mismatch`, `continuation-policy-unavailable`, `continuation-verification-required`, `continuation-review-required`, `continuation-changes-required`, `continuation-completion-unproven`, `continuation-checkpoint-required`.

Preservar códigos ND (`advance-stale-goal`, `advance-intent-unknown`, `advance-intent-mismatch`, `advance-lock-busy`, `advance-move-unknown`) e expor a causa em campo separado.

Zero-efeito: recusa antes do ADVANCE = zero PREPARE/CLAIM/SETTLE/execução/finalização. Depois de PREPARE confirmado, falha de checkpoint não é zero-efeito: devolver `prepared=true` + chave vinculada.

## State machine

```
SETTLED → reler/correlacionar stores → verificar resultado/policy
        → decisão do Controller → gates → ND-ADVANCE → checkpoint
```

| Move | Tratamento |
|---|---|
| CONTINUE | Resultado aceito; verificação/review atuais; DONE da task quando necessário; ND reserva exatamente um PREPARE sucessor. |
| RETRY | Resultado `failed`/verificação negativa pode originar correção; **não** exigir `verified_pass`/DONE da tentativa falha; exigir estratégia corretiva + admissão + budget; nunca reutilizar cegamente candidato rejeitado. |
| REPLAN | Persistir decisão causal no advance record + referência no checkpoint; retornar `replan_required`, sem PREPARE imediato. |
| BLOCKED | Sem PREPARE; registrar causa; não mutar goal automaticamente. Normalizar stops sem sucesso do Controller para BLOCKED. |
| COMPLETE | Só `COMPLETED` se `stop_reason=OBJECTIVE_COMPLETED` + `Test-ObjectiveCompletionAllowed` + CAS do GoalKernel. Demais stops → BLOCKED, nunca COMPLETED. |

No-progress: não inventar contador; RETRY exige budget canônico; repetição sem estratégia/evidência nova → REPLAN/BLOCKED.

Finalização: fatorar o helper existente do AL (leitura viva → gate global → CAS); chamar ADVANCE **sem** `FinalizeGoalOnComplete`; endurecer o switch do ND para não completar por stop de política.

## Idempotência/recovery

1. `(goal_id, settled_key)` tem no máximo um sucessor; `next_idempotency_key` pertence ao advance record.
2. Nunca gerar nova chave na recuperação; registro pendente aceita só o mesmo intent; ilegível = bloqueio.
3. Fix no replay CONTINUE/RETRY pendente: preservar a **decisão registrada** (hoje o ND reconsulta o Controller e permite drift).
4. Checkpoint é projeção: correlacionar `settled_key`, ref do advance record e sucessor em `next_move`/`decision_refs`.
5. Queda pós-PREPARE: reconciliar o mesmo preparo; checkpoint ausente não autoriza outro.
6. Pending/uncertain: parar antes de verificação/advance; S4 reconcilia.
7. Goal já COMPLETED: reconhecer por leitura canônica antes da admissão ACTIVE; sem novo CAS/PREPARE.

## Review gating

- L0/L1: validação focada, mas preservar o reviewer exigido pelo DONE atual.
- L2: tester + reviewer. L3: tester + reviewer + security-reviewer.
- Calcular roles das políticas/registros atuais; não confiar em `CompletedRoles` do worker.
- `manual_verification_required` = falta de prova (não substituir por review).
- Verificação negativa comprovada pode autorizar RETRY; desconhecida não.
- Fixture: double de Reviewer controlado pelo harness, persistido por `Set-OrchestrationTaskReview`; sem modelo. Prova consumo/freshness, não independência real.

## Test plan (fixture)

1. CONTINUE: candidato válido → verify/review → task concluída → 1 PREPARE.
2. RETRY: falha controlada → correção autorizada → 1 nova preparação; tentativa falha não vira DONE.
3. REPLAN: registro/checkpoint persistidos, 0 PREPARE.
4. BLOCKED: admissão/budget negados; motivo estável.
5. COMPLETE válido: critério global + CAS.
6. COMPLETE recusado: task DONE sem critério global; stop de política nunca completa goal.
7. Review ausente/stale/negativo; security ausente em L3.
8. Verificação manual/unknown profile: 0 preparação.
9. Replay sequencial/concorrente: mesmo sucessor; intent divergente recusado.
10. Queda após registro pendente, após PREPARE e antes do checkpoint.
11. Registro corrompido/receipt uncertain: nenhum novo efeito.
12. Ownership/generation/revision stale; goal held; CAS conflitante.
13. Checkpoint perdido: reconstrução por registros canônicos, sem duplicar PREPARE.
14. Replay pendente com Controller alterado: decisão reservada não muda.
15. Compatibilidade: sem `SettledKey` inalterado.

Não prova: despacho real, consumo autônomo pelo LLM, Reviewer real, cross-session, recovery, enforcement, quota.

## Arquivos prováveis

- `scripts/v3/lib/OrchestrationAutonomousLoop.ps1`
- `scripts/v3/lib/OrchestrationNativeDispatch.ps1` (ajustes de replay/finalização)
- Fixtures/testes AL e Handoff
- Wrapper CLI existente, se necessário
- Plano/doc: registrar S3a fixture-only; G3/S6 abertos

Evitar alterar TaskKernel/validation-policy para resolver a divergência L0/L1 nesta fatia.

## DONE de S3a

Fixtures provam uma única sucessão causal, bloqueios seguros, correção sem falso DONE e conclusão global só com gate+CAS; regressões afetadas verdes; reviews independentes encerrados. **Sem claim de G3/autonomia runtime-real/recovery S4.**

## Notas de implementação (fatia entregue)

- `Invoke-OrchestrationSettledContinuation` em
  `scripts/v3/lib/OrchestrationAutonomousLoop.ps1` + suite
  `scripts/v3/lib/OrchestrationSettledContinuation.tests.ps1`
  (458 asserts PS 5.1+pwsh, 12 cenários + ND hardening + compat).
- `Invoke-OrchestrationObjectiveStep` ganha `-SettledKey`/`-NextIntent`
  (+`-SessionId`); com `SettledKey` encaminha UMA vez e retorna o envelope
  da continuação; sem ela, legado intacto (provado em S12 + suite AL 47/47).
- Ramo COMPLETE do step fatorado em `Invoke-ALObjectiveCompletion`
  (releitura viva → gate → CAS); S3a reutiliza (COMPLETE válido e replay
  terminal); nenhuma duplicação do driver.
- ND endurecimento 1 (replay preserva decisão gravada, sem reconsulta ao
  Controller) + endurecimento 2 (finalize com `-FinalizeGoalOnComplete`
  só com `stop_reason=OBJECTIVE_COMPLETED` E critérios verificados no
  goal vivo; stop de política registra
  `goal-finalize-refused:policy-stop`, nunca completa). D5b do Handoff
  marca `progress=1/1` antes do finalize (caso legítimo preservado) +
  D5d prova a recusa por stop de política.
- Checkpoint: schema existente intacto; correlação via sidecar
  `<checkpoint_id>.settled-continuation.json` (retrocompatível, aditivo).
- Nível efetivo via policy real (`Get-OrchestrationValidationLevel`
  sobre o risco vivo; default conservador L2; desconhecido/ilegível =>
  `continuation-policy-unavailable`); L0/L1/L2 exigem verificação passada
  e fresca + review aprovado e fresco; L3 exige ainda security-review.
- S3a nunca recupera pendente sozinha (`advance-record-pending` =>
  `continuation-settlement-uncertain`, zero efeito); S4/manual reconcilia.
  Descoberta de fixture: o scan do claim varre a raiz inteira e recusa
  fail-closed em registro ilegível — o cenário de recibo corrompido usa
  raiz de recibos isolada para não vazar para outros cenários.
- Limites honestos: evidência é existência+correlação de arquivo/ids
  (sem recomputo do hash canônico); sem prova de consumo autônomo pelo
  LLM, Reviewer real, cross-session, recovery S4, enforcement ou quota.
