# ADR PACK — Universal Autonomous Orchestration v0.1.0

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** `feat/universal-autonomous-orchestration-v0.1.0` @ `414c81e2159faf0e10c4becb2219a368cf44abc7`
**Revision date:** 2026-10-07
**Companion SPEC:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md`
**Companion PLAN:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PLAN.md`
**Status:** Aprovado pelo Planner para implementação — Jev usado como advisory, Planner como decisão final
**Change class:** `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING`

---

## Revisão do Planner (2026-10-07)

- `REV-A-01` — Pack armazenado em `docs/specs/` (ao lado de SPEC/PLAN) porque o repo não possui `docs/adr/`. Quando a Fase 14 (reconciliation) criar o índice SPEC/PLAN/ADR, reavaliar pasta dedicada.
- `REV-A-02` — ADR-002: migração `TRIVIAL_DIRECT` → `SINGLE_WORKER` e cia. é greenfield (grep zero para os novos termos). Lista de superfícies a migrar na Fase 1 incluída no PLAN (`REV-P-03`).
- `REV-A-03` — ADR-007: ordem exata reuse/rules pode variar quando uma regra precisar decidir se evidence é reutilizável — registrado para evitar deadlock de pipeline na Fase 3.
- `REV-A-04` — ADR-013: sem arquivo `VERSION` hoje; epoch `0.1.0` começa com `VERSION=0.1.0-dev` nesta branch. Tag `v1.0`/`[1.0.0]` preservada.
- `REV-A-05` — ADR-015/016: issues #21 e #25 são blockers a classificar na Fase 0, não "provavelmente preexistente".
- `REV-A-06` — Autoreview AR-01…AR-10 preservada na íntegra; veredito mantido. Adicionado AR-11 (colisão execution-modes A/B/C) e AR-12 (Jev advisory vs Planner authority nesta própria sessão).

---

## ADR-001 — Unidade fundamental: Objective

### Decisão

Toda solicitação do usuário cria um Objective.

Nem todo Objective cria um Goal.

### Motivo

Aplicar Goal persistente a toda tarefa adicionaria estado, checkpointing e overhead desnecessários.

Ao mesmo tempo, permitir tarefas não orquestradas contradiz o objetivo do projeto.

### Resultado

`Objective` é universal.

`Goal` é uma promoção durável.

---

## ADR-002 — Universal Orchestration

### Decisão

Toda tarefa passa pelo Planner/control plane e utiliza worker para o trabalho operacional quando houver worker aplicável.

### Mudança em relação ao estado atual

`TRIVIAL_DIRECT` deixa de ser um caminho operacional normal.

### Justificativa

O Planner usa o modelo e contexto mais valiosos da orquestração.

Delegar trabalho simples para cheap workers melhora:

- custo;
- contexto;
- separação de responsabilidades;
- rastreabilidade;
- paralelização futura.

### Importante

Universal orchestration não significa fan-out.

A forma mais simples pode ser:

Planner
→ 1 Coder cheap
→ Planner

---

## ADR-003 — Planner é Control Plane, não Primary Worker

### Responsabilidades do Planner

- entender Objective;
- enquadrar problema;
- decidir estratégia;
- decompor;
- selecionar workers;
- tomar decisões técnicas;
- integrar evidência;
- replanejar;
- decidir continuation;
- decidir completion.

### Trabalho a delegar

- grandes buscas;
- leitura extensa;
- implementação;
- execução mecânica;
- testes;
- logs;
- debugging operacional;
- documentação extensa;
- pesquisa.

### Resultado esperado

Redução significativa de `planner_operational_token_share`.

---

## ADR-004 — Autonomia vem do Envelope, segurança vem do Kernel

### Decisão

Não usar prompts humanos frequentes como principal mecanismo de segurança.

### Modelo

User Intent
∩ Project Policy
∩ Global Policy
∩ Grants
∩ Runtime Capability
=
Authorization Envelope

Planner opera autonomamente dentro do envelope.

Kernel/policies impedem cruzar a fronteira.

### Consequência

O sistema pode ser simultaneamente:

mais autônomo

e

mais seguro.

---

## ADR-005 — Incerteza não é aprovação humana

### Decisão

Incerteza técnica deve causar:

- reuse query;
- pesquisa;
- Jev;
- Explorer;
- Debugger;
- Architect;
- Tester;
- Reviewer.

Não uma pergunta automática ao usuário.

Human escalation só ocorre quando a questão é de autoridade ou intenção.

---

## ADR-006 — Reuse-First

### Decisão

Consulta ao Evidence Store passa a ser parte normal do Planner pipeline.

### Justificativa

Reexecutar trabalho já validamente conhecido desperdiça:

- tokens;
- tempo;
- model calls;
- contexto;
- CI;
- testes.

### Segurança

Reuse é permitido apenas com invalidation contract válido.

Reuse não pode transformar evidence antiga em verificação atual sem política que permita isso.

---

## ADR-007 — Decision Ladder

### Decisão

Usar a menor capacidade suficiente para cada decisão.

Ordem conceitual:

1. deterministic state/rules;
2. reusable prior evidence;
3. bounded Decision Provider;
4. Planner reasoning;
5. specialist escalation.

A ordem exata de reuse/rule evaluation pode variar tecnicamente quando uma regra precisar decidir se determinada evidence é reutilizável.

### Jev

Jev é o primeiro model-backed provider.

Adequado para decisões de espaço fechado.

Não adequado para criação de arquitetura aberta.

### Authority

Jev retorna sinal.

O sistema executa a decisão somente após policy/kernel.

---

## ADR-008 — Result-Oriented Continuation

### Decisão

A execução é orientada pelo Objective, não pela unidade interna.

### Portanto

Task complete:
continue se Objective incompleto.

Wave complete:
continue.

Phase complete:
continue.

PR created:
continue.

CI failed:
recover.

Reviewer CHANGES_REQUIRED:
fix.

### Retorno ao usuário

Somente terminal Objective state.

---

## ADR-009 — Persistent Goal Above TaskKernel

### Decisão

Não alterar TaskKernel para fazê-lo representar trabalhos de longa duração.

Adicionar Goal Kernel acima dele.

### Motivo

Task e Goal possuem ciclos de vida diferentes.

Goal pode sobreviver a dezenas de Tasks.

Task continua bounded.

---

## ADR-010 — Event-Driven Continuation

### Decisão

GoalLoop não será um `while(true)` cego.

Continuação ocorre em safe boundaries.

Exemplos:

- Task settled;
- required worker results collected;
- Barrier completed;
- checkpoint committed;
- external event resolved;
- session reconciled.

### Proteções

- watchdog;
- progress delta;
- repeated action guard;
- strategy fingerprint;
- budgets;
- no-progress thresholds.

---

## ADR-011 — Budgets não devem causar parada prematura

### Decisão

Budgets têm escopo.

Worker budget:
encerra/reagenda worker.

Task budget:
replan/escalate.

Goal soft budget:
otimiza/reduz custo.

Goal hard budget:
pode interromper Objective.

### Regra

`BUDGET_LIMITED != COMPLETED`.

---

## ADR-012 — Fresh Context é operação normal

### Decisão

Goal não fica preso à vida de uma sessão.

Context pode ser descartado deliberadamente quando seu custo marginal ficar alto.

A retomada usa:

- Goal state;
- checkpoint;
- Technical Decision Records;
- EvidenceRefs;
- Git state;
- next move.

---

## ADR-013 — Versionamento

### Situação encontrada

Há uma tag histórica `v1.0` (CHANGELOG `## [1.0.0] — 2026-09-25`), mas nenhum GitHub Release formal correspondente. Não há arquivo `VERSION` no repo.

### Decisão

Preservar essa tag intacta.

Documentá-la como:

`legacy / pre-formal-versioning`

Estabelecer novo versioning epoch:

`0.1.0`

Fase 0 cria `VERSION=0.1.0-dev` nesta branch.

### SemVer

Durante `0.x`:

breaking architectural changes continuam permitidas entre minor versions.

Exemplo:

0.1.x:
bugfixes.

0.2.0:
nova capability relevante ou breaking evolution permitida no período experimental.

1.0.0:
contratos públicos/arquiteturais considerados estáveis.

### Regra

V3, V3.1, P26, P38 etc. deixam de ser apresentados como versão do produto.

Continuam apenas como identificadores históricos de programas de implementação.

---

## ADR-014 — Issue #6 vira umbrella da v0.1

### Decisão

A VNext descrita na #6 é conceitualmente compatível.

Porém deve ser atualizada com decisões novas:

- Universal Orchestration;
- Delegation First;
- Objective/Goal distinction;
- Autonomous Continuation;
- safe autonomy;
- Reuse First obrigatório;
- Planner Technical Decision Lead;
- formal v0.1.0.

Subissues devem carregar a implementação concreta.

---

## ADR-015 — Issues que precisam de alteração semântica

### #4 e #30

Remover comparação baseada em `DIRECT` como Planner-primary-work.

Substituir por:

- SINGLE_WORKER;
- MULTI_WORKER;
- GOAL;
- TEAM;
- SWARM;
- ARENA;
- PROGRAMMATIC.

### #3

Onde disser que Swarm não deve substituir "direct execution for trivial tasks", alterar para:

Swarm não deve substituir `SINGLE_WORKER` para tarefas simples/lineares.

### #8

Modelo:

Task
→ Run
→ Session
→ Generation

passa a fazer parte de:

Goal
→ Task
→ Run
→ Session
→ Generation

Goal só aparece quando houver promoção.

### #16

Deve ser incorporada cedo.

Jev vira provider model-backed inicial.

### #1

Precisa refletir a nova autonomia:

human approval deve estar ligado a authority/risk boundaries, não simplesmente a uma classificação ampla de mudança.

---

## ADR-016 — Issues explicitamente adiadas

Não colocar no critical path da 0.1:

- Agent Teams completos;
- Swarm;
- Arena;
- Prompt Cache Optimization;
- Full Observation Virtualization;
- Safe Action Fusion;
- Full Evidence Reduction;
- Harness Profiles;
- Programmatic Execution;
- Agent Gateway.

### Motivo

Todos eles podem aumentar eficiência ou escala, mas nenhum corrige sozinho a falha principal:

`pedido → execução → interrupções desnecessárias → usuário precisa mandar continuar`

Primeiro corrigir o contrato base.

---

## ADR-017 — Roadmap inicial

### v0.1.0 — Autonomous Core

- Universal Orchestration;
- Delegation First;
- Reuse First;
- Decision Layer/Jev;
- Safe Autonomy;
- Result-Oriented Continuation;
- Goal Kernel;
- checkpoints;
- minimum EvidenceRef;
- telemetry;
- Golden Workflows;
- basic delivery integration.

### v0.2.0 — Context & Execution Efficiency

Candidatos:

- #11 Prompt Cache;
- #12 Observation Virtualization;
- #13 Safe Action Fusion;
- #14 Evidence Reduction;
- #15 Harness Profiles;
- #17 Programmatic Execution.

A composição final deve depender dos dados da v0.1.

### v0.3.0 — Multi-session Scale

Candidatos:

- #2 Agent Teams;
- #7 supervision/ownership graph;
- advanced #10 runtime control.

### Depois

Swarm e Arena só após telemetry demonstrar onde geram ganho real.

Gateway permanece research-gated.

---

## AUTOREVIEW

### Finding AR-01 — Goal universal seria overengineering

**Problema:** Aplicar GoalKernel a um typo adicionaria custo sem valor.

**Correção:** Objective universal. Goal automático apenas quando útil.

**Status:** resolvido no desenho.

### Finding AR-02 — Universal orchestration poderia ser confundida com muitos agents

**Risco:** Aumentar custo para tarefas simples.

**Correção:** `SINGLE_WORKER` é uma forma completa de orquestração. Workers adicionais somente com justificativa.

**Status:** resolvido.

### Finding AR-03 — "Jev sempre" seria outro ritual caro

**Risco:** Substituir desperdício do Planner por desperdício de decision calls.

**Correção:** Jev universalmente disponível, seletivamente chamado. Admission por utilidade da decisão.

**Status:** resolvido.

### Finding AR-04 — Reuse automático pode propagar state stale

**Risco:** Usar conclusão antiga como verdade atual.

**Correção:** Fingerprint + invalidation + provenance + verification policy.

**Status:** resolvido.

### Finding AR-05 — Autonomia excessiva poderia ampliar blast radius

**Risco:** Planner interpretar objetivo como autorização irrestrita.

**Correção:** Authorization Envelope é interseção, nunca união. Kernel continua autoridade. Irreversibilidade, produção, external cost, credentials e communication possuem boundaries.

**Status:** resolvido.

### Finding AR-06 — Budgets atuais poderiam continuar causando interrupções

**Correção:** Distinguir budget de Worker, Task e Goal. Exaustão local volta ao Planner.

**Status:** resolvido no contrato; requer implementação.

### Finding AR-07 — Scope inicial estava grande demais

**Problema:** Implementar todas as 23 issues simultaneamente aumentaria complexidade e risco.

**Correção:** v0.1 reduzida ao Autonomous Core. Otimizações ficam versionadas posteriormente.

**Status:** resolvido.

### Finding AR-08 — Tag histórica v1.0 conflita visualmente com 0.1.0

**Correção:** Não reescrever Git history. Declarar formal versioning epoch. VERSION/README/CHANGELOG passam a ser fontes de versão oficial.

**Status:** decisão documentada.

### Finding AR-09 — Planner Technical Lead poderia conflitar com Reviewer

**Correção:** Planner decide estratégia técnica. Reviewer decide aprovação segundo review contract. Verifier decide prova determinística. Security Reviewer decide findings de segurança segundo policy. Nenhuma dessas responsabilidades se sobrepõe.

**Status:** resolvido.

### Finding AR-10 — SPEC + PLAN poderia impedir adaptação

**Correção:** SPEC = contract. PLAN = mutable strategy. Planner pode replanejar sem solicitar autorização desde que não altere intenção/requisitos.

**Status:** resolvido.

### Finding AR-11 — Colisão execution-modes A/B/C vs nova taxonomia (novo nesta revisão)

**Problema:** `source/registry/execution-modes-policy.json` modos A/B/C (B = persistent specialist, OFF) competem com `SINGLE`/`MULTI`/`PERSISTENT_GOAL`.

**Correção:** Reconciliação obrigatória na Fase 1; sem behavior change silencioso; sem dois vocabulários concorrentes.

**Status:** registrado; requer implementação Fase 1.

### Finding AR-12 — Jev advisory vs Planner authority nesta sessão (novo nesta revisão)

**Problema:** `jev_decide` sugeriu `ask_user` após docs (conf. baixa 0.44) enquanto o usuário ordenou "inicie a implementação completa".

**Correção:** Planner prevalece sobre advisory; registrado como evidência de que Jev é sinal, não autoridade (ADR-007). Implementação Fase 0 iniciada nesta sessão.

**Status:** resolvido com evidência runtime.

---

## VEREDITO DA AUTOREVISÃO

A arquitetura proposta é coerente com o kernel atual e não exige recomeçar o projeto.

A maior mudança não é tecnológica.

É semântica:

**o sistema deixa de otimizar por término de turn/task e passa a otimizar por entrega verificável do Objective.**

Os elementos existentes — workers baratos, Task Kernel, Evidence Store, watchdog, budgets, Jev, Reviewer, Verifier, grants e worktrees — tornam essa evolução muito mais incremental do que inicialmente parecia.

O trabalho principal da v0.1 é conectá-los sob um contrato de execução contínua, eficiente e segura.
