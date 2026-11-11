# P0 — Reformulação do Planner: evidência (2026-11-11)

**Missão:** EVOLUTION INTEGRATED M0–M7, diretriz de 2026-11-10 (issue #48).
**Branch:** `feat/evolution-integrated-20261110` (baseline `beb0ea4`).
**Escopo:** contrato de papéis, rota `DIRECT_VERIFIED` sem escrita, Goal/Loop,
autonomia por missão. Sem flag, permissão, credencial, allowlist ou produção.

## 1. Diagnóstico aplicado

| Achado | Correção |
|---|---|
| `source/global/AGENTS.md` autorizava execução direta em mudança pequena | contrato de papéis + rota por mutação |
| `source/adapters/opencode-v2.md` dava `DIRECT_VERIFIED` zero-worker para escrita | separação leitura (direct) x qualquer mutação (worker) |
| `OrchestrationPreflight.ps1` emitia `DIRECT_VERIFIED` em `isMicroEditWrite`/`isCodeMicroEditWrite` | escrita cai no ramo `SINGLE_WORKER` trivial existente |
| `ReadWrite=read` com objetivo de edição escapava (achado F1 da revisão) | leitura direta exige evidência de consulta; edição declarada `read` delega |
| Dois scripts de evidência mediam escrita direta (F2) | WL-01 e SCENARIO-01 passaram a medir lookup read-only |
| `AGENTS.md` do checkout e `docs/ARCHITECTURE.md` repetiam a permissão | alinhados (6 estados, papéis, Goal/Loop) |
| Mandato V2 injetado pelo plugin (`plugins/orchestration-enforcement/shared/mandate.ts`) ainda autorizava "one micro-fix" direto; o bundle `plugins/dist` é derivado | V2_PLANNER_LINES reescrito para o contrato P0 (V1 intocado), harness do plugin atualizado e bundle + sha256 regenerados |

`Test-OrchestrationDoneCompliance` não mudou: o gate trivial já exigia
`ExecutionShape=SINGLE_WORKER` + participação observada > 0.

## 2. Delegação real nesta rodada

O Planner (sessão `build`) não editou código nem rodou teste de implementação.
Toda alteração funcional foi executada por workers:

| Worker | Sessão | Entrega |
|---|---|---|
| coder | `ses_e35b9f0b3ffeUSquEPdKPoTzij` | classificador + testes de preflight + GW + consumidores de evidência |
| reviewer | `ses_e35b0c31dffe1q6iJU8TLX7Npe` | revisão independente: 2 findings reais (F1 HIGH, F2 MEDIUM) + F3 LOW |
| coder (follow-up) | `ses_e35b9f0b3ffeUSquEPdKPoTzij` | F1/F2/F3 corrigidos e revalidados |

O Planner fez diagnóstico read-only, atualizou plano/SPEC/instruções e coletou
evidência de aceite. Nenhuma pergunta humana intermediária foi feita para as
subtarefas cobertas pela missão.

## 3. Validação observada

| Checagem | Resultado |
|---|---|
| `orchestration-preflight.tests.ps1` | 286/286 |
| `OrchestrationAdvisorEfficiencyGW.tests.ps1` | 145/145 |
| `test-package-consistency.ps1` | 17/17 |
| WL-01 (`measure-workflow-efficiency.ps1`) | `DIRECT_VERIFIED`, `COMPLIANT`, 0 subagents, lookup read-only |
| `productive-three-phase-harness.tests.ps1` | `HARNESS_PASS`, 34 checks |
| `OrchestrationGoalKernel.tests.ps1` | 103 asserts |
| `OrchestrationDurableResume.tests.ps1` | 22/22 (inclui "task DONE não completa goal") |
| `git diff --check` | limpo |
| `tests/distribution/run-distribution-tests.ps1` | 22/24 suítes; 2 falhas ambientais (`profile-isolation` timeout do binário V2 2.0.18 em cache; `skills-catalog` drift user-owned em `hybrid-development`), nenhuma relacionada à mudança |

Novos testes relevantes: seção `15z P0` (leitura direta, escrita com worker,
participação zero ⇒ `ORCHESTRATION_POLICY_BYPASS`, sensível/arquitetura fora da
rota trivial), matriz de 12 combinações de escrita e casos `read` com intenção
de edição.

## 4. Autonomia longa (P0.5)

**Provado (determinístico, mesmo processo):** GoalKernel com Tasks, Loop
(`Get-OrchestrationGoalNextMove`), continuação por `SettledKey`, bloqueio de
`CONTINUE` sem verificação, review `changes_required` bloqueando DONE,
re-execução automática após correção, retomada por `DurableResume` e regra
Task DONE ≠ Goal DONE.

**Não alegado (perna faltante):** uma missão contínua de 3 Tasks com modelo
vivo, falha real e replan dentro de um único Goal, sem intervenção humana, não
foi executada nesta rodada. Motivo concreto: o Planner LLM é o único ponto de
efeito externo e não pode ser dirigido por script; provar isso exige uma sessão
interativa multi-turn com provider vivo, e um daemon/scheduler é proibido pelo
escopo. O harness determinístico cobre o mecanismo, não o transporte multi-turn.

## 5. Baseline P0.6

| Métrica | Resultado |
|---|---|
| DONE correto | testes de gate e harness; nenhuma Task de produção criada nesta fatia |
| Intervenções humanas por subtarefa | 0 (todas cobertas pela missão) |
| Tempo até DONE | `UNKNOWN` (não medido de forma comparável) |
| Tokens/custo por DONE | `UNKNOWN` (nenhum custo inventado) |
| Retrabalho/retomadas | 1 rodada de review com 2 findings reais corrigidos (F1/F2) |

## 6. Autoridade

Nenhuma alteração de `source/registry/*`, flags, permissões, allowlist,
credenciais, agentes ou produção. `runtime_grant_enforcement`, `skill_routing`,
`mcp_routing` e `adaptive_ranking` permanecem como estavam.
