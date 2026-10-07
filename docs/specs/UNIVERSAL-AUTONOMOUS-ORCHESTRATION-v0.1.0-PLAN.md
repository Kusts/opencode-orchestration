# IMPLEMENTATION PLAN — Universal Autonomous Orchestration v0.1.0

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** `feat/universal-autonomous-orchestration-v0.1.0` @ `414c81e2159faf0e10c4becb2219a368cf44abc7`
**Revision date:** 2026-10-07
**Companion SPEC:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md`
**Companion ADR:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-ADR.md`
**Status:** Draft revisado pelo Planner — Fase 0 em implementação nesta branch
**Change class:** `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING`

**Relação com o programa anterior:** este PLAN é continuação explícita autorizada pelo usuário (V3.1 closure PASS em 2026-10-06). O maintenance-mode da V3 continua valendo fora do escopo v0.1.0. Não criar V4.

---

## Revisão do Planner (2026-10-07)

- `REV-P-01` — Header formal adicionado no padrão `ORCHESTRATION-V3.1-KERNEL-HARDENING-PLAN.md` (Repository/Baseline/Companion/Status/Change-class).
- `REV-P-02` — Fase 0 detalhada para a realidade do repo: sem arquivo `VERSION`, `CHANGELOG [Unreleased]` V3.1 ativo, tag `v1.0` legacy. Fase 0 cria `VERSION=0.1.0-dev` + seção de epoch no CHANGELOG/README/ARCHITECTURE, sem tocar na tag histórica.
- `REV-P-03` — Fase 1: lista explícita das superfícies que duplicam `TRIVIAL_DIRECT` (lib + 2 adapters + global + mandato TS + bundle + tests + `validation-policy.json` L0 + `execution-modes-policy.json`). Migração sem cobrir todas quebra `test-package-consistency`.
- `REV-P-04` — Estratégia de PRs mantida (PR-A…PR-L), mas PR-A (versionamento + docs contracts) é o único no escopo desta sessão inicial; demais PRs são o Goal persistente (Jev `promote`, conf. 0.92).
- `REV-P-05` — Issues #21 (distribution tests) e #25 (ai-memory plugin regen) marcadas como blockers a classificar na Fase 0, não como "provavelmente preexistente".
- `REV-P-06` — Cada fase fecha com Reviewer; Security Reviewer obrigatório quando authority/credentials/grants/delivery forem alterados. Nenhum rollout enfraquece DONE/Verifier.

---

## 1. Estratégia de implementação

A v0.1.0 será construída incrementalmente sobre o kernel atual.

Não haverá reescrita total.

Princípios do rollout:

- preservar Task Kernel existente;
- migrar comportamento antes de adicionar estratégias sofisticadas;
- feature flags somente durante rollout;
- capacidades consideradas core ficam ON por padrão na release;
- mudanças começam com testes e record/shadow quando necessário;
- cada fase deve fechar com Reviewer;
- Security Reviewer obrigatório quando authority, credentials, grants ou delivery forem alterados;
- nenhum rollout pode enfraquecer DONE/Verifier.

---

## 2. Fase 0 — Baseline e versionamento (EM IMPLEMENTAÇÃO nesta branch)

### Objetivo

Criar uma base confiável antes de alterar a semântica central.

### Trabalho

Adicionar:

`VERSION`
→ `0.1.0-dev`

Documentar:

- formal versioning epoch;
- tag histórica `v1.0` como legacy/pre-formal-versioning;
- SemVer oficial a partir de 0.1.0;
- V3/V3.1/Pxx como nomes históricos de programas internos, não versões de produto.

Atualizar:

- README;
- CHANGELOG;
- architecture docs;
- release docs.

Resolver ou classificar release blockers existentes, principalmente:

- issue #21 distribution tests;
- issue #25 legacy ai-memory plugin regeneration.

### Gate

Todas as suites consideradas baseline da release devem possuir estado conhecido.

Nenhuma falha pode permanecer simplesmente como "provavelmente preexistente".

### Entregas desta sessão (PR-A parcial)

1. `VERSION` = `0.1.0-dev` (novo).
2. `docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md` (novo, revisado).
3. `docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PLAN.md` (este arquivo).
4. `docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-ADR.md` (novo, revisado).
5. Entrada `[Unreleased]` no CHANGELOG apontando o epoch v0.1.0 (sem remover o fechamento V3.1).
6. Baseline de testes registrado em `evidence/v0.1.0/phase-0-baseline.json` (a produzir pelo Tester).

---

## 3. Fase 1 — Universal Orchestration + Delegation First

### Objetivo

Eliminar trabalho operacional direto do Planner como estratégia normal.

### Alterações principais

Modificar:

`source/global/AGENTS.md`

`docs/ARCHITECTURE.md`

`README.md`

`OrchestrationPreflight.ps1`

`OrchestrationPreflight.tests.ps1`

Remover a semântica normal de:

`TRIVIAL_DIRECT`

Introduzir:

`SINGLE_WORKER`

`MULTI_WORKER`

`PERSISTENT_GOAL`

`DETERMINISTIC_FALLBACK`

`BLOCKED`

Definir uma exceção apenas para ações internas de control plane que não constituem o trabalho solicitado pelo usuário.

Superfícies adicionais obrigatórias (`REV-P-03`):

- `source/adapters/opencode.md` + `source/adapters/opencode-v2.md`;
- `plugins/orchestration-enforcement/shared/mandate.ts` (+ rebuild do bundle distribuído);
- `source/registry/validation-policy.json` (L0 `trivial_direct`);
- `source/registry/execution-modes-policy.json` (reconciliar modos A/B/C com a nova taxonomia).

### Casos de teste

- typo → Coder cheap;
- code lookup → Explorer cheap;
- research → Researcher;
- bug → Coder + Tester conforme validation policy;
- architecture → especialistas adequados;
- nenhuma tarefa fica sem orchestration decision.

### Gate

`planner_operational_work_without_worker = 0`

para os Golden Workflows cobertos.

---

## 4. Fase 2 — Autonomy Envelope + Stop Policy

### Objetivo

Eliminar interrupções humanas desnecessárias mantendo limites fortes.

### Alterações

Evoluir:

`source/policies/AUTONOMY.md`

Criar policy parseável, por exemplo:

`source/registry/autonomy-policy.json`

Registrar:

- ações automaticamente autorizadas;
- authority boundaries;
- stop reasons fechados;
- policy-denied reasons.

Adicionar ao Planner/Kernel:

`AuthorizationEnvelope`

Adicionar stop contract:

`OBJECTIVE_COMPLETED`

`HUMAN_AUTHORITY_REQUIRED`

`EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE`

`GOAL_HARD_BUDGET_EXHAUSTED`

`POLICY_BLOCKED`

`CANCELLED`

Todos os outros resultados retornam ao control plane.

### Gate

Golden Workflow deve comprovar:

- falha técnica não pede usuário;
- replan não pede usuário;
- review finding não pede usuário;
- destructive production action bloqueia corretamente.

---

## 5. Fase 3 — Reuse-First

### Objetivo

Tornar o Evidence Store parte obrigatória do planejamento.

### Alterações

Modificar:

`OrchestrationPlannerLoop.ps1`

`OrchestrationEvidenceStore.ps1`

`OrchestrationEvidenceStore.tests.ps1`

O PlannerLoop não pode mais começar semanticamente com:

`evidence-store-not-requested`

em operação normal.

Resolver automaticamente StoreDir através do contexto/runtime.

Flow:

Frame
→ Reuse
→ remaining delta
→ Decision
→ Dispatch

Implementar explicitamente:

- reuse hit;
- reuse miss;
- stale evidence;
- invalid provenance;
- criteria drift;
- base revision drift;
- environment drift.

### Telemetria

- reuse queries;
- hits;
- misses;
- miss reasons;
- estimated work avoided.

### Gate

Tarefa repetida com estado idêntico deve reduzir trabalho duplicado sem falsificar verification.

---

## 6. Fase 4 — Decision Provider + Jev

### Objetivo

Transformar a integração Jev existente em Decision Layer provider-neutral.

### Base

Issue #16.

### Criar

`OrchestrationDecisionProvider.ps1`

`DecisionProvider` contract

Adapters:

`RulesProvider`

`JevProvider`

### Ordem

Deterministic Rules
→ Jev when eligible
→ Planner escalation

### Alterar

`OrchestrationJevAdvisory.ps1`

`OrchestrationPlannerLoop.ps1`

`jev-advisory-policy.json`

Remover `trivial_local` como exclusão conceitual absoluta.

Substituir por admission baseado em:

- question is bounded;
- allowed answers can be enumerated;
- useful state exists;
- expected value > call cost;
- risk permits advisory automation.

### Failures

Jev unavailable:

→ deterministic fallback or Planner

Nunca:

→ block whole Objective apenas porque Jev caiu.

### Gate

- typed decisions;
- malformed Jev response;
- timeout;
- low confidence;
- unavailable provider;
- conflicting deterministic rule;
- attempts to grant authority;
- model/provider override protection.

Issue #19 deve ser validada nesta fase.

---

## 7. Fase 5 — Objective Continuation Kernel

### Objetivo

Tornar "continue até entregar resultado" uma regra executável.

### Criar

`OrchestrationObjectiveController.ps1`

ou equivalente.

Responsabilidades:

- receber resultado da Task/Wave;
- verificar Objective;
- calcular remaining work;
- escolher CONTINUE/REPLAN/COMPLETE/etc;
- nunca mapear Task DONE diretamente para user return.

Modificar:

`OrchestrationDispatchPipeline`

`OrchestrationPlannerLoop`

`TaskKernel completion integration`

### Estados internos

`CONTINUE`

`RETRY`

`REPLAN`

`DELEGATE`

`ESCALATE_AGENT`

`ROTATE_CONTEXT`

`WAIT_EXTERNAL`

`COMPLETE`

### Gate

SPEC com múltiplas phases deve atravessar todas sem intervenção humana artificial.

---

## 8. Fase 6 — Goal Kernel

### Objetivo

Adicionar persistência acima do Task Kernel.

### Criar

`OrchestrationGoalKernel.ps1`

`OrchestrationGoalKernel.tests.ps1`

`goal-policy.json`

Campos principais:

- goal_id;
- objective;
- criteria;
- verification surfaces;
- state;
- revision;
- budget;
- progress;
- plan progress;
- evidence refs;
- decisions;
- active tasks;
- blockers;
- next move.

Task Kernel ganha:

`goal_id`

`goal_iteration`

`work_item_id`

`decision_ref`

### Regras

Goal é pai lógico de Tasks.

Task Kernel permanece autoridade sobre Task execution.

Goal Kernel não duplica grants, leases ou verification.

### Gate

Goal deve sobreviver a:

- Task failure;
- Planner turn ending;
- session replacement;
- process restart;
- context rotation.

---

## 9. Fase 7 — Auto Goal Promotion

### Objetivo

Eliminar necessidade de `/goal`.

### Criar

`Test-OrchestrationGoalPromotion`

ou componente equivalente.

Inputs:

- SPEC/PLAN markers;
- estimated work breadth;
- phase count;
- expected waves;
- acceptance criteria;
- likely context span;
- iterative verification requirement;
- explicit user continuation intent.

Output:

`task`
ou
`persistent-goal`

A decisão deve ser explicável e registrada.

### Regra especial

SPEC + PLAN destinada a implementação completa deve receber forte preferência para Goal.

### Gate

Usuário fornece SPEC + PLAN + "implemente".

Nenhum `/goal` manual é necessário.

---

## 10. Fase 8 — Progress Delta + Strategy Change

### Objetivo

Impedir loops improdutivos.

### Criar

`OrchestrationGoalProgress.ps1`

Representar:

- previous state;
- current state;
- meaningful delta;
- stagnation count.

Integrar com strategy fingerprints já existentes.

Quando no-progress exceder threshold:

`STRATEGY_CHANGE_REQUIRED`

Segundo stall:

Debugger obrigatório quando aplicável.

Incerteza arquitetural:

Architect.

Nova tentativa só com:

- evidência nova;
- hipótese nova;
- estratégia nova;
- condição externa alterada.

### Gate

Loop repetindo a mesma ação deve ser interrompido sem encerrar prematuramente o Goal.

---

## 11. Fase 9 — Technical Decision Records

### Objetivo

Permitir decisões duráveis entre waves e sessões.

### Criar

`OrchestrationTechnicalDecision.ps1`

Armazenar:

- pergunta;
- opções;
- decisão;
- rationale;
- evidence refs;
- reversibility;
- scope.

TDR deve ser incluído nos checkpoints e hydrations.

### Gate

Nova sessão não deve rediscutir decisão válida já registrada sem evidência de invalidação.

---

## 12. Fase 10 — Goal Checkpoint + Session Recovery

### Objetivo

Desacoplar Goal de contexto.

### Evoluir

`OrchestrationSessionReconciler.ps1`

`ContinuationEnvelope`

Adicionar Goal-aware checkpoint.

Integração:

Goal
→ checkpoint
→ session retirement
→ fresh session
→ hydrate
→ continue

### Issue alignment

Esta fase incorpora a parte estrutural da issue #8.

A parte avançada de runtime control da #10 pode ser dividida:

v0.1.0:

- durable identity;
- resume;
- loss reconciliation;
- continuation.

posterior:

- STEER/INTERRUPT/CLOSE completos quando dependentes de capacidades nativas específicas.

---

## 13. Fase 11 — EvidenceRef e compact handoffs

### Objetivo

Preservar contexto do Planner.

### Base

Issue #9.

Implementar contrato mínimo de EvidenceRef:

- evidence_id;
- goal/task/run;
- producer;
- artifact ref;
- hash;
- verification state;
- provenance.

O Planner recebe referências + resumo bounded.

Payload bruto permanece recuperável.

### Gate

Workers com logs grandes não devem inflar o Planner context desnecessariamente.

Full Observation Virtualization da issue #12 pode ser posterior se o contrato mínimo for suficiente para 0.1.

---

## 14. Fase 12 — GitHub Delivery Continuation

### Objetivo

Integrar resultado técnico ao delivery definido pelo projeto.

### Base

Issue #1.

Implementar inicialmente:

- project delivery policy;
- require PR;
- direct push policy;
- CI status;
- review findings;
- merge eligibility;
- terminal delivery state.

Não implementar autoridade irrestrita.

PR creation/CI/review devem participar do mesmo Objective.

### Gate

CI failure deve retornar ao Planner.

Review finding deve retornar ao Planner.

Merge ocorre somente se project policy autorizar.

---

## 15. Fase 13 — Telemetry + Golden Workflows

### Base

Issues #4 e #30.

### Golden Workflows obrigatórios

GW-01:
single-worker trivial task.

GW-02:
small bug with validation.

GW-03:
reuse hit.

GW-04:
reuse invalidated.

GW-05:
Jev bounded routing.

GW-06:
Jev unavailable fallback.

GW-07:
SPEC + PLAN long-running Goal.

GW-08:
wave completion continues automatically.

GW-09:
review finding → repair → re-review.

GW-10:
repeated failure → Debugger → new strategy.

GW-11:
context rotation/resume.

GW-12:
authority-boundary human escalation.

GW-13:
unauthorized model/provider override denied.

GW-14:
GitHub delivery loop.

GW-15:
hard Goal budget stops honestly without claiming completion.

### Metrics

Compare current baseline against v0.1 candidate.

Critical targets:

- premature-stop-rate ↓;
- planner operational tokens ↓;
- evidence reuse ↑;
- human intervention rate ↓;
- verified success no regression;
- security policy violations = 0.

---

## 16. Fase 14 — Documentation Reconciliation

Atualizar integralmente:

README

ARCHITECTURE

AUTONOMY

PERMISSIONS

CHANGELOG

install/runtime documentation

SPEC/PLAN index

Remover documentação ativa que ainda descreve:

`TRIVIAL_DIRECT`

como caminho normal.

Marcar V3/V3.1 como histórico arquitetural.

---

## 17. Fase 15 — Release Closure

Antes de `0.1.0`:

- full suite;
- distribution suite;
- V1 exact-runtime smoke;
- V2 exact-runtime smoke;
- dual-profile;
- Goal recovery test;
- Jev failure tests;
- reuse invalidation tests;
- security review;
- Reviewer final;
- Golden Workflows;
- docs reconciliation;
- clean worktree;
- no unresolved P0/P1;
- release evidence bundle.

Atualizar:

`VERSION = 0.1.0`

Criar tag:

`v0.1.0`

Não apagar nem reescrever a tag histórica `v1.0`.

---

## 18. Ordem recomendada das issues existentes

### v0.1.0 core

#6 — usar como umbrella/epic arquitetural, atualizada para refletir v0.1.

#4 — telemetry/evidence-driven routing, subset necessário.

#8 — Goal/Task/Run/Session/Generation identity.

#9 — EvidenceRef.

#16 — DecisionProvider/Jev.

#19 — model/provider/variant authorization.

#30 — Golden Workflows.

#1 — GitHub Delivery, subset essencial.

#10 — durable continuation/reconciliation subset.

#20 — focused schema/conformance tests onde contratos mudarem.

#21 — baseline/release blocker.

#25 — runtime/plugin hardening antes da release quando V2 estiver no suporte formal.

### Compatíveis, mas posteriores ao core

#2 — Agent Teams.

#7 — Supervision vs Ownership.

#3 — Swarm.

#5 — Arena.

#11 — prompt-cache optimization.

#12 — full Observation Virtualization.

#13 — Safe Action Fusion.

#14 — full Evidence Reduction.

#15 — Harness Profiles.

#17 — Programmatic Execution.

#29 — Agent Gateway research.

---

## 19. Novas issues necessárias

Criar subissues específicas para evitar sobrecarregar #6:

1. `feat(core): universal orchestration and delegation-first Planner`
2. `feat(core): autonomous continuation and terminal stop policy`
3. `feat(goal): persistent Goal Kernel and automatic goal promotion`
4. `feat(efficiency): mandatory reuse-first orchestration`
5. `policy: authorization envelope and human escalation boundaries`
6. `release: formal SemVer epoch starting at v0.1.0`

Relacioná-las à #6.

---

## 20. Estratégia de PRs

Não implementar a v0.1 em um único PR.

Sugestão:

PR-A:
versioning + docs contracts.

PR-B:
Universal Orchestration.

PR-C:
Autonomy Envelope.

PR-D:
Reuse First.

PR-E:
DecisionProvider/Jev.

PR-F:
Objective Continuation.

PR-G:
Goal Kernel.

PR-H:
Goal promotion + progress.

PR-I:
checkpoint/recovery/EvidenceRef.

PR-J:
delivery integration.

PR-K:
telemetry/evals/reconciliation.

PR-L:
release closure.

Cada PR deve fechar seus próprios tests e possuir review independente.

O Goal de implementação da v0.1 engloba todos esses PRs e só termina quando a release inteira passa nos critérios de aceite.
