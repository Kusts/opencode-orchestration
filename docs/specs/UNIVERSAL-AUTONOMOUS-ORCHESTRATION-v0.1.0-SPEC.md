# SPEC — Universal Autonomous Orchestration v0.1.0

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** `feat/universal-autonomous-orchestration-v0.1.0` @ `414c81e2159faf0e10c4becb2219a368cf44abc7`
**Revision date:** 2026-10-07
**Target release:** `0.1.0` (novo epoch SemVer; tag histórica `v1.0` preservada como legacy/pre-formal-versioning)
**Status:** Draft revisado pelo Planner — pronto para implementação Fase 0
**Change class:** `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING`
**Companion PLAN:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PLAN.md`
**Companion ADR:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-ADR.md`

**Documentos relacionados:**

- `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md` — kernel atual (base incremental, sem reescrita).
- `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-PLAN.md` — convenção de Phases seguida por este PLAN.
- `source/global/AGENTS.md`, `source/adapters/opencode.md`, `source/adapters/opencode-v2.md` — superfícies onde `TRIVIAL_DIRECT` será migrado (Fase 1).
- `scripts/v3/lib/OrchestrationPreflight.ps1` — seam da migração `TRIVIAL_DIRECT` → `SINGLE_WORKER`/`MULTI_WORKER`/`PERSISTENT_GOAL`.

---

## Revisão do Planner (2026-10-07)

Branch: `feat/universal-autonomous-orchestration-v0.1.0` (criada nesta sessão a partir de `docs/phase-2e-merge-record` @ `414c81e`).

Decisões Jev registradas nesta sessão (advisory-only, Planner decide):

- `jev_classify` execution shape → `sequential_multi` (conf. 0.91): docs → implementação → validação, com frentes paralelas apenas onde houver independência real.
- `jev_decide` doc order → `spec_first` (conf. 0.98); promotion → `promote` (conf. 0.92, SPEC+PLAN+implementação completa justifica Goal); `continue_policy` → `ask_user` (conf. baixa 0.44) — **não seguida**: o usuário ordenou explicitamente "após isso inicie a implementação completa", que prevalece sobre advisory de baixa confiança.

Revisões aplicadas ao draft original (conteúdo das §1–§25 preservado; mudanças marcadas com `REV`):

- `REV-01` — Adicionado header formal no padrão das SPECs V3.1 (Repository/Baseline/Status/Change-class/relacionados). Sem header, o doc divergia da convenção do repo.
- `REV-02` — §7: migração `TRIVIAL_DIRECT` → novos estados é **semântica**, não apenas renomeação. Mapeamento normativo para a Fase 1 registrado no PLAN. Nenhum vestígio de `SINGLE_WORKER` existe hoje no repo (grep zero) — é vocabulário greenfield.
- `REV-03` — Versionamento (§24 item 27, §25): não existe arquivo `VERSION` no repo; `CHANGELOG.md` tem `[Unreleased]` V3.1 ativo + tag histórica `[1.0.0]`. A Fase 0 cria `VERSION=0.1.0-dev` e documenta o epoch sem reescrever history.
- `REV-04` — ADR pack vive ao lado da SPEC (`docs/specs/`) porque o repo não possui pasta `docs/adr/`; decisões hoje estão espalhadas em `docs/capability-*-decisions.md` e `docs/audits/`. Evita replicar o espalhamento.
- `REV-05` — Colisão de vocabulário sinalizada: `source/registry/execution-modes-policy.json` modos A/B/C (B=persistent specialist, OFF) vs nova taxonomia `SINGLE`/`MULTI`/`PERSISTENT_GOAL`. Reconciliação obrigatória na Fase 1, sem behavior change silencioso.
- `REV-06` — §9: critério Jev `expected_decision_value > decision_cost` mantido; `trivial_local` como exclusão absoluta sai na Fase 4. Jev indisponível nunca bloqueia o Objective (fallback determinístico ou Planner).
- `REV-07` — §13: worker/run/task budget exhaustion nunca encerra Objective; somente Goal hard budget é terminal. Alinha com ADR-011.

---

# 1. Visão

O sistema deve receber um objetivo do usuário e entregar o resultado solicitado utilizando a estratégia de orquestração mais eficiente, segura e adequada disponível.

O usuário não deve precisar instruir o Planner a:

- usar subagents;
- usar Jev;
- buscar evidência reutilizável;
- continuar para a próxima task;
- continuar depois de uma wave;
- corrigir findings;
- executar a próxima fase;
- criar um Goal;
- replanejar;
- chamar Debugger ou Architect;
- retomar depois de uma troca de sessão.

Essas decisões pertencem ao sistema de orquestração.

Princípio central:

> Se o objetivo do usuário ainda não foi satisfeito e existe trabalho útil, autorizado e seguro que pode fazê-lo avançar, a execução deve continuar autonomamente.

---

# 2. Problemas que esta versão resolve

O sistema atual possui um núcleo avançado de Task Kernel, workers, watchdog, budgets, Evidence Store, Jev, validation e review, mas ainda apresenta problemas comportamentais importantes:

1. `TRIVIAL_DIRECT` permite ao Planner executar trabalho operacional que poderia ser realizado por cheap workers.
2. O Planner pode consumir contexto caro com exploração, edição e tarefas mecânicas.
3. Task/Wave/Phase completion pode resultar em retorno prematuro ao usuário.
4. SPEC + PLAN não possui uma unidade persistente de conclusão correspondente à SPEC inteira.
5. Evidence reuse não é obrigatoriamente consultado.
6. Jev ainda possui gatilhos excessivamente baseados em classe de tarefa.
7. Incerteza técnica pode acabar sendo tratada como motivo para perguntar ao usuário.
8. Execuções longas permanecem excessivamente associadas a uma sessão/contexto.
9. As fases internas V3/V3.1 passaram a funcionar informalmente como versionamento do produto.
10. Algumas issues abertas presumem `DIRECT` como estratégia válida e precisam ser reconciliadas.

---

# 3. Objetivos da v0.1.0

A v0.1.0 DEVE estabelecer:

1. Orquestração obrigatória para toda solicitação do usuário.
2. Planner como Control Plane e Technical Decision Lead.
3. Delegation-First como comportamento padrão.
4. Cheap workers como caminho normal para trabalho operacional.
5. Reuse-First obrigatório no pipeline.
6. Decision Layer: deterministic rules → decision provider/Jev → Planner.
7. Autonomia segura baseada em authority boundaries, não em prompts frequentes.
8. Continuação automática até o objetivo do usuário.
9. Persistent Goals para trabalho de longa duração.
10. Auto-promotion de Objective para Goal.
11. Progress baseado em evidência, não em quantidade de atividade.
12. Checkpoints e retomada entre sessões/contextos.
13. Distinção explícita entre Task completion e User Objective completion.
14. EvidenceRef e handoffs compactos.
15. Telemetria de eficiência e intervenção humana.
16. Evals end-to-end para verificar o novo comportamento.
17. SemVer formal iniciando em `0.1.0`.

---

# 4. Não objetivos da v0.1.0

Não é necessário entregar nesta release:

- Swarm completo;
- Arena/Best-of-N;
- Agent Teams completo;
- DAG scheduler genérico;
- Programmatic Execution;
- Safe Action Fusion;
- Harness Profiles adaptativos;
- Agent Gateway;
- auto-otimização de policies;
- self-modification;
- substituição do Task Kernel;
- dependência obrigatória do `/goal` de qualquer runtime.

Essas capacidades devem poder ser adicionadas posteriormente sobre o núcleo da v0.1.0.

---

# 5. Modelo conceitual

Toda solicitação possui um:

`User Objective`

O Objective é universal.

Ele pode ser executado como:

`SINGLE_WORKER`

`SEQUENTIAL_MULTI_WORKER`

`PARALLEL_MULTI_WORKER`

ou promovido para:

`PERSISTENT_GOAL`

Goal não é sinônimo de tarefa longa em wall-clock. Goal é um Objective que necessita persistência, múltiplas iterações, múltiplas tasks, retomada ou progresso incremental verificável.

Modelo de identidade:

`Objective`
→ opcional `Goal`
→ `Task`
→ `Run`
→ `Session`
→ `Generation`

Definições:

**Objective:** resultado solicitado pelo usuário.

**Goal:** contrato durável de conclusão para um Objective.

**Task:** unidade delimitada de trabalho.

**Run:** tentativa limitada de executar uma Task.

**Session:** recipiente de contexto de um agente.

**Generation:** instância concreta do runtime/processo correspondente à sessão.

---

# 6. Invariantes fundamentais

## INV-001 — Universal Orchestration

Toda solicitação passa pelo control plane.

Não existe caminho implícito onde o Planner simplesmente decide executar o pedido sozinho.

## INV-002 — Delegation First

O Planner deve delegar trabalho operacional a um worker adequado.

O menor conjunto útil de workers pode ser um único cheap worker.

## INV-003 — Planner Context Conservation

O contexto do Planner deve conter principalmente:

- objetivo;
- estado;
- decisões;
- plano;
- evidence refs;
- progress;
- blockers;
- riscos;
- next move.

Logs extensos, buscas, diffs grandes, hipóteses descartadas e execução mecânica permanecem nos workers/evidence store.

## INV-004 — Planner as Technical Decision Lead

O Planner é a autoridade semântica para decisões técnicas dentro do escopo autorizado.

Architect, Jev, Reviewer, Researcher e demais agentes fornecem evidência ou recomendação.

Eles não substituem o Planner como control plane.

## INV-005 — Kernel as Authority Boundary

O Planner não pode sobrescrever:

- grants;
- ownership;
- leases;
- scope;
- production policy;
- secrets policy;
- Verifier;
- mandatory Reviewer;
- Security Reviewer;
- DONE gate.

## INV-006 — Task Done Is Not Objective Done

Nenhum dos estados abaixo implica retorno ao usuário:

- TASK_DONE;
- WAVE_DONE;
- PHASE_DONE;
- PR_CREATED;
- PR_MERGED;
- CI_PASS;
- REVIEW_COMPLETE;
- CHECKPOINT_CREATED;
- TECHNICAL_DECISION_RECORDED.

Somente Objective/Goal completion ou um terminal blocker válido encerra a execução.

## INV-007 — Decision Does Not Mean Pause

Uma decisão técnica é uma transição interna.

O Planner deve decidir e continuar.

## INV-008 — Barrier Does Not Mean Stop

Barrier significa:

synchronize
→ inspect evidence
→ calculate progress
→ decide next move

e não retorno ao usuário.

## INV-009 — Failure Does Not Mean Stop

Falha recuperável deve resultar em:

retry
→ evidence
→ new strategy
→ Debugger
→ Architect
→ replan

conforme necessário.

## INV-010 — Evidence Decides Completion

Nenhum agente pode concluir uma tarefa apenas declarando que terminou.

---

# 7. Universal Orchestration Preflight

Os estados existentes:

`TRIVIAL_DIRECT`
`DELEGATED`
`DETERMINISTIC_FALLBACK`
`BLOCKED`

devem ser substituídos ou semanticamente migrados para: (`REV-02`: migração semântica, Fase 1 do PLAN)

`SINGLE_WORKER`
`MULTI_WORKER`
`PERSISTENT_GOAL`
`DETERMINISTIC_FALLBACK`
`BLOCKED`

`SINGLE_WORKER` continua sendo orquestração.

Exemplo:

pedido: corrigir typo

Planner
→ Coder cheap
→ evidence
→ Planner synthesis
→ Objective complete

Não:

Planner
→ edição direta

O Planner pode executar operações mínimas do próprio control plane, mas não deve realizar o trabalho operacional principal do usuário quando existe worker adequado.

---

# 8. Reuse-First

Antes de iniciar nova investigação ou execução, o pipeline deve consultar evidência reutilizável.

Fluxo:

Objective
→ Reuse Query
→ validity check
→ reusable evidence
→ determine remaining delta
→ dispatch somente o necessário

Reuse deve funcionar por padrão.

Não deve depender de `store_dir` explicitamente fornecido pelo Planner.

O runtime/control plane deve resolver o Evidence Store automaticamente.

Evidência só pode ser reutilizada se suas invalidation conditions continuarem válidas.

Podem invalidar reuse:

- source change;
- acceptance criteria change;
- incompatible base revision;
- runtime/environment change;
- TTL;
- explicit invalidation;
- provenance/hash mismatch.

Reuse nunca equivale automaticamente a verification atual.

O Planner deve decidir se a evidência antiga ainda satisfaz o requisito atual de prova.

---

# 9. Decision Layer

Pipeline conceitual:

Reuse
→ deterministic rules
→ Decision Provider
→ Planner

Deterministic rules devem resolver decisões totalmente codificáveis.

Jev é o model-backed Decision Provider inicial recomendado.

Jev deve ser usado para decisões delimitadas e tipadas, como:

- routing;
- specialist choice;
- continue/retry/replan/escalate;
- sequential vs parallel;
- evidence sufficiency advisory;
- uncertainty/risk classification;
- escolha entre alternativas conhecidas;
- seleção da próxima hipótese entre opções explícitas.

Jev NÃO deve:

- conceder grants;
- ampliar escopo;
- selecionar provider/model fora da policy;
- autorizar produção;
- autorizar ações destrutivas;
- sobrescrever Verifier;
- sobrescrever Reviewer;
- sobrescrever Security Reviewer;
- escrever DONE.

O critério para chamar Jev não deve ser `task == trivial`.

Deve ser aproximadamente: (`REV-06`)

`expected_decision_value > decision_cost`

Decisões determinísticas não precisam de Jev.

Decisões abertas de arquitetura pertencem ao Planner, com Architect quando necessário.

---

# 10. Safe Autonomy

Cada Objective recebe um `Authorization Envelope`.

O envelope é derivado da interseção de:

- pedido do usuário;
- project policy;
- global autonomy policy;
- task grants;
- environment policy;
- runtime capabilities.

Dentro desse envelope, o Planner pode autonomamente:

- delegar;
- pesquisar;
- consultar memória/evidence;
- usar Jev;
- editar;
- refatorar;
- testar;
- buildar;
- depurar;
- criar branch;
- criar worktree;
- fazer commit;
- abrir PR;
- responder findings;
- rerodar CI;
- replanejar;
- trocar estratégia;
- executar próxima wave;
- criar checkpoint;
- iniciar nova sessão;
- retomar Goal.

Não deve solicitar confirmação meramente porque:

- está incerto;
- existe decisão técnica;
- um teste falhou;
- houve finding;
- uma wave terminou;
- o plano precisa mudar;
- precisa usar outro worker.

Incerteza gera coleta de evidência.

Não gera automaticamente human escalation.

---

# 11. Human Escalation Boundary

Intervenção humana deve ser reservada a authority boundaries reais.

Motivos válidos incluem:

`PRODUCT_INTENT_AMBIGUITY`

`IRREVERSIBLE_REAL_DATA_ACTION`

`UNAUTHORIZED_PRODUCTION_ACTION`

`EXTERNAL_COST_OR_PURCHASE`

`CREATE_ROTATE_REVOKE_CREDENTIAL`

`EXTERNAL_COMMUNICATION_AS_USER`

`MATERIAL_SCOPE_EXPANSION`

`POLICY_DENIED`

`REQUIRED_EXTERNAL_INPUT_UNAVAILABLE`

Credencial existente, configurada e autorizada pode ser usada através do mecanismo seguro correspondente sem pedir nova permissão a cada ação.

---

# 12. Autonomous Continuation

O estado padrão é:

`CONTINUE`

Após toda Task/Wave/Barrier o sistema deve avaliar:

1. O Objective foi satisfeito?
2. Existe trabalho restante?
3. Existe caminho autorizado?
4. Existe progresso possível?
5. É necessário mudar estratégia?
6. Existe um terminal blocker?

Se Objective não foi satisfeito e existe trabalho útil autorizado:

`CONTINUE`

Possíveis transições internas:

`CONTINUE`
`RETRY`
`REPLAN`
`DELEGATE`
`ESCALATE_AGENT`
`ROTATE_CONTEXT`
`WAIT_EXTERNAL`
`COMPLETE`

---

# 13. Stop Policy

O Planner só deve devolver controle ao usuário como encerramento da execução quando ocorrer: (`REV-07`: exaustão local nunca encerra Objective)

`OBJECTIVE_COMPLETED`

`HUMAN_AUTHORITY_REQUIRED`

`EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE`

`GOAL_HARD_BUDGET_EXHAUSTED`

`POLICY_BLOCKED`

`CANCELLED`

Worker timeout, worker budget, provider error ou attempt exhaustion NÃO encerram automaticamente o Objective.

Eles retornam ao control plane para recuperação/replanejamento.

---

# 14. Persistent Goal

Um Goal possui pelo menos:

- goal_id;
- objective;
- lifecycle state;
- success criteria;
- verification surfaces;
- constraints;
- authorization envelope reference;
- plan progress;
- evidence refs;
- technical decision refs;
- failed strategy refs;
- active tasks;
- completed tasks;
- blockers;
- risks;
- progress state;
- budget;
- checkpoint revision;
- next move.

Estados:

`DRAFT`
`ACTIVE`
`PAUSED`
`BLOCKED`
`BUDGET_LIMITED`
`COMPLETED`
`EXHAUSTED`
`CANCELLED`

`COMPLETED`, `EXHAUSTED` e `CANCELLED` são terminais.

`BLOCKED` e `BUDGET_LIMITED` podem ser retomados quando o motivo for resolvido ou houver novo budget autorizado pela policy.

---

# 15. Auto Goal Promotion

O usuário não precisa usar `/goal`.

O Planner/control plane promove automaticamente Objective para Goal quando houver evidência de que isso traz benefício.

Sinais fortes incluem:

- SPEC + PLAN;
- múltiplas fases;
- múltiplas waves;
- vários PRs esperados;
- trabalho que pode ultrapassar sessão/contexto;
- múltiplos acceptance criteria independentes;
- investigação iterativa;
- benchmark/repair loop;
- migration;
- release/closure;
- implementação de plano completo;
- necessidade provável de checkpoint/resume.

A promoção deve ser automática e registrada.

`/goal` ou equivalente pode existir apenas como override explícito/debug/manual.

---

# 16. SPEC + PLAN Execution Contract

Quando o pedido do usuário for implementar uma SPEC + PLAN:

- a SPEC define o contrato;
- o PLAN define a estratégia inicial;
- o Goal representa a conclusão da SPEC;
- phases são milestones;
- tasks são unidades de execução;
- o Planner pode alterar o PLAN quando evidência justificar;
- o Planner não pode silenciosamente alterar requisitos da SPEC.

Plano pode mudar.

Objetivo não pode ser redefinido unilateralmente.

---

# 17. Progress Model

Atividade não equivale a progresso.

Não são sinais suficientes:

- número de tool calls;
- quantidade de agentes;
- número de arquivos lidos;
- tempo consumido;
- número de retries.

Progress deve ser calculado principalmente por mudança observável em relação ao Objective.

Exemplos:

- criteria satisfied 3/8 → 5/8;
- failed tests 20 → 4;
- open P1 findings 3 → 1;
- blockers 2 → 0;
- benchmark p95 220ms → 160ms.

Cada Goal Iteration deve produzir `ProgressDelta`.

Após iterações consecutivas sem meaningful progress:

`STRATEGY_CHANGE_REQUIRED`

Repetir a mesma estratégia sem evidência nova deve ser bloqueado pelo loop guard.

---

# 18. Checkpoint e Context Rotation

Goal deve sobreviver à sessão.

Checkpoint deve persistir:

- objective;
- goal revision;
- progress;
- plan progress;
- decisions;
- evidence refs;
- failed strategies;
- blockers;
- active risks;
- waits;
- next move;
- resume preconditions;
- current base revision.

Quando contexto estiver degradando:

finish coherent unit
→ checkpoint
→ retire session/generation
→ start fresh context
→ hydrate Goal
→ continue

Context reset não é failure.

---

# 19. Technical Decision Record

Decisões técnicas relevantes devem ser persistidas.

Campos mínimos:

- decision_id;
- goal_id/task_id;
- question;
- alternatives considered;
- selected option;
- rationale;
- evidence refs;
- risk;
- reversibility;
- timestamp;
- decided_by.

O objetivo é evitar rediscutir decisões já tomadas e permitir retomada entre sessões.

---

# 20. Evidence Handoff

Workers não devem enviar conversações completas ao Planner.

O retorno deve ser estruturado e compacto.

Contrato base:

`TASK_ID`
`STATUS`
`KEY_FINDINGS`
`EVIDENCE_REFS`
`CHANGES`
`VALIDATION`
`BLOCKERS`
`RISKS`
`RECOMMENDATION`

EvidenceRef deve preservar:

- producer;
- task/run;
- hash;
- provenance;
- verification state;
- artifact/raw ref.

---

# 21. Budget Model

Existem budgets em níveis diferentes.

Worker/Run budget controla uma execução local.

Task budget controla tentativas de uma Task.

Goal budget controla o Objective persistente.

Esgotar worker ou Task budget deve resultar em replanejamento, não em interrupção automática do usuário.

Somente Goal hard budget pode se tornar terminal.

Soft budgets devem orientar:

- redução de fan-out;
- reutilização;
- troca de estratégia;
- cheaper model;
- redução de contexto;
- evidence reuse.

Workers nunca ampliam seu próprio budget.

---

# 22. GitHub Delivery

Delivery é parte do Objective quando a policy do projeto assim determinar.

O fluxo pode ser:

branch/worktree
→ implementation
→ tests
→ review
→ PR
→ CI
→ findings
→ repair
→ merge gate
→ closure

Criar PR não significa concluir Objective.

CI failure não significa pedir ajuda ao usuário.

Review finding não significa pedir ajuda ao usuário.

Auto-merge deve seguir project policy + risk + checks.

---

# 23. Telemetria obrigatória

Registrar pelo menos:

- objective/goal id;
- execution shape;
- workers utilizados;
- model/provider;
- reuse query/hit/miss;
- Jev calls/useful calls/fallbacks;
- Planner escalations;
- tokens/cost proxy;
- context size;
- wall-clock;
- retries;
- strategy changes;
- progress deltas;
- validation result;
- reviewer findings;
- security findings;
- human interventions;
- stop reason;
- final result.

Métricas primárias:

`verified-success-rate`

`cost-to-DONE`

`tokens-to-DONE`

`time-to-DONE`

`human-intervention-rate`

`planner-operational-token-share`

`evidence-reuse-rate`

`jev-useful-call-rate`

`premature-stop-rate`

---

# 24. Critérios de aceite da v0.1.0

A release só pode ser considerada pronta quando:

1. Toda task passa por Universal Orchestration.
2. O caminho normal simples é Planner → single cheap worker → Planner.
3. `TRIVIAL_DIRECT` não executa mais trabalho operacional do usuário.
4. Reuse query ocorre automaticamente.
5. Evidência stale não é reutilizada silenciosamente.
6. Jev pode participar de decisões bounded sem ganhar autoridade.
7. Planner continua após Task/Wave/Phase completion.
8. Planner corrige findings recuperáveis autonomamente.
9. SPEC + PLAN pode ser executado até conclusão sem prompts de "continue".
10. Goal persiste entre sessões.
11. Context rotation preserva progresso.
12. Task/Run/Session loss não perde Goal.
13. Worker failure não encerra Goal automaticamente.
14. Technical decisions podem ser registradas e retomadas.
15. Human prompt só ocorre para authority boundary válida.
16. DONE continua protegido por evidence + validation + review policy.
17. V1 não sofre regressão.
18. V2 não sofre regressão.
19. Golden Workflow demonstra um trabalho curto.
20. Golden Workflow demonstra SPEC + PLAN longo.
21. Golden Workflow demonstra failure → debugger/replan → recovery.
22. Golden Workflow demonstra context/session rotation.
23. Golden Workflow demonstra reuse.
24. Golden Workflow demonstra Jev fallback.
25. Golden Workflow demonstra bloqueio seguro de ação não autorizada.
26. Distribution baseline está verde ou todo residual está explicitamente classificado e não compromete a release.
27. Versão formal reportada é `0.1.0`.

---

# 25. Resultado esperado

Do ponto de vista do usuário:

`pedido`
→ `orquestração interna`
→ `resultado`

e não:

`pedido`
→ `wave`
→ "continue?"
→ `wave`
→ "continue?"
→ `finding`
→ "posso corrigir?"
→ `resultado`

A complexidade permanece dentro do sistema.
