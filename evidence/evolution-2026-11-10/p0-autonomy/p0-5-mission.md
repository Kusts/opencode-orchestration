# P0.5 — Missão real com Goal de 3 Tasks (2026-11-11)

**Goal:** `p0-autonomy-20261111` — store `evidence/evolution-2026-11-10/p0-autonomy/goals/`.
**Estado final:** `COMPLETED` (revision 16, CAS), `satisfied=3/3`, Tasks `T1,T2,T3`.
**Harness de estado:** `scripts/v3/p0-autonomy-proof.ps1` (GoalKernel read/write; sem scheduler/controlador).

## Critérios e resultado

| Critério | Evidência |
|---|---|
| Task 1 delegada ao Coder e validada | coder criou `artifacts/task1/*`; teste focado `3/0`; Goal registrou T1 (rev 8) |
| Task 2 com falha real + decisão | tentativa 1: `3 pass / 1 fail` (`2*3=7` esperado, `6` obtido); `repair-decision` retornou `LOCAL_REPAIR`; falha persistida em `failed_strategies` |
| Replan preservando Tasks concluídas | T1 permaneceu concluída; T2 foi reparada na mesma Task (expectativa de aceite corrigida para `2*3=6`); teste `4/0` |
| Retomada por processo novo | `resume` recarregou o Goal do disco (rev 12): `completed=[T1,T2]`, `active=[T3]`, `next_move=CONTINUE`, `resume_source=goal-store` |
| Task 3 validação independente | tester (sessão nova, read-only): task1 `3/0`, task2 `4/0`, implementações corretas e não tautológicas |
| Goal DONE ≠ Task DONE | `complete` com T1+T2 foi recusado (exit 1); só concluiu após T3 (`COMPLETED`, rev 16) |
| Planner não implementa/testa | o Planner só orquestrou: dispatch, `repair-decision`, registro de estado e leitura de evidência |
| Sem intervenção humana | 0 solicitações após a autorização da missão |

## Chamadas e custo

- Dispatches de worker: `coder` T1, `coder` T2 tentativa 1, `coder` T2 reparo, `tester` T3 = **4**.
- Duração observada no Goal: `2026-11-11T18:29:28Z` → `2026-11-11T18:31:58Z` (**~2m30s** para as 3 Tasks; não inclui a criação do harness).
- Tokens/custo por DONE: **UNKNOWN** (nenhum valor inventado).
- Intervenções humanas: **0** dentro da missão.

## Limites honestos

- A “interrupção recuperável” foi exercitada como **fronteira de processo/sessão de worker**: a sessão anterior terminou e um processo novo recarregou o Goal do disco. Não houve reinício do processo OpenCode nem do Planner LLM nesta rodada.
- O GoalKernel é a fonte de estado; o harness não replica um scheduler. `OrchestrationDurableResume` continua coberto pela suíte 22/22, mas não foi o transporte desta prova.
- Cobertura funcional dos artefatos é mínima (inteiros simples); o objetivo era a condução da missão, não a feature.
- Nenhuma flag, permissão, credencial ou produção alterada.
