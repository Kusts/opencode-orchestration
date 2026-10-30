# AUTONOMY-FULL-DELIVERY-vNEXT — Plano de evolução para autonomia integral

**Repositório:** `Kusts/opencode-orchestration`
**Data-base:** 2026-10-30
**Status:** ETAPA 0 — planejamento mínimo (sem implementação)
**Change class:** `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING` (reusa o epoch v0.1.x; não cria V4)
**Companions (não duplicados aqui):** `docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md`,
`docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PLAN.md`,
`docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-CORRECTIVE-PLAN.md`,
`docs/specs/UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-WIRING-MATRIX.md`,
`docs/audits/ISSUE-TRIAGE-MATRIX-2026-10-21.md`,
`docs/specs/OPENCODE-RUNTIME-ADAPTIVE-COMPATIBILITY-SPEC.md`,
`source/policies/AUTONOMY.md`, `source/registry/autonomy-policy.json`,
`source/registry/delivery-policy.json`, `docs/github-lifecycle-policy.md`.

**Objetivo:** transformar a Orquestração OpenCode V2 em sistema capaz de receber um objetivo e conduzir
autonomamente planejamento, implementação, testes, correções, revisão, CI, integração e deployment autorizado
até a entrega verificável. **Sem reescrever a arquitetura nem criar outra orquestração.**

---

## 0. Premissas vinculantes (regras, não sugestões)

1. Não reescrever o projeto nem criar outra arquitetura de orquestração (reusar o existente).
2. Reutilizar TaskKernel (âncora runtime-proven), GoalKernel, AutonomousLoop/ObjectiveStep, PlannerLoop,
   Model Router, JevAdvisory, Advisor, Delivery, EvidenceStore, políticas.
3. OpenCode V2 é o runtime principal e muda com frequência → toda equivalência nativa deve ser **provada no
   runtime exato** antes de simplificar/remover componente local.
4. Verificar recurso nativo do OpenCode V2 antes de implementar equivalente local.
5. Agent Config é o proprietário da configuração global; este plano não cria fonte concorrente de config.
6. Intervenção humana = último recurso, apenas para autoridade/intenção (autorizações, irreversíveis,
   orçamento, produção).
7. Resultado intermediário, relatório de progresso ou erro recuperável **não** interrompem o Goal.
8. Respeitar restrições explícitas, autorizações efetivas, limites de orçamento e ações irreversíveis.
9. Não usar Meu TED como piloto.
10. Não promover resultado de harness/fixture a prova de autonomia produtiva (prova exige runtime real).
11. Manter o maintenance-mode da V3 (nenhum V4, nova phase, novo Router, novo agente, novo framework, nova
    telemetria por hipótese) fora do escopo V3.1; flags nascem OFF/shadow e ativação é decisão humana com
    evidência.

## 1. Estado real (consumidores) — por que a autonomia não acontece hoje

Mapeamento dos consumidores reais (detalhe em `OrchestrationAutonomousLoop.ps1`, `OrchestrationGoalKernel.ps1`,
`OrchestrationObjectiveController.ps1`, `OrchestrationDispatchPipeline.ps1`, `OrchestrationPlannerLoop.ps1`):

- `Invoke-OrchestrationAutonomousObjective` — **nenhum caller produtivo** (só testes dot-sourced). O driver
  interno retorna `awaits-planner` quando não há Executor.
- `Invoke-OrchestrationDispatchPipeline` — **nenhum caller produtivo**.
- `Invoke-OrchestrationPlannerLoop` — callers apenas de benchmark (`measure-workflow-efficiency.ps1`) e
  `OrchestrationE2eManifest.ps1` (lib de teste); nunca CI.
- `Invoke-OrchestrationObjectiveStep` — chamado apenas por `objective-step.ps1` (CLI manual/agent-driven) e por
  libs internas (`ProductiveActivation`, driver).
- `Get-OrchestrationGoalNextMove` / `Set-OrchestrationGoalStatePersisted` — chamados por libs internas e
  `objective-step.ps1`; nenhum disparo automático por runtime/CI.
- `ObjectiveRunner.harness.ps1` e `productive-*-harness.tests.ps1` — **nunca invocados por CI**; são
  test-harness, não produto. Promovê-los a "prova" é proibido (regra 10).
- CI (`.github/workflows/ci.yml`) roda suites de teste, smoke V1/V2 e watchdog lane, mas **não** invoca o
  loop autônomo nem o harness de objetivo. Ou seja: a autonomia é exercida apenas por testes e libs internas;
  não há caller produtivo real.

**Conclusão operacional:** a causa-raiz da interrupção entre tasks não é falta de código de loop — é a ausência
de um **caller produtivo** que, ao concluir uma Task, re invoque o Planner/Controller e persista o progresso no
GoalKernel. Isso define a Etapa 1.

## 2. Matriz de gaps (G1–G16)

Colunas: componente | estágio atual (do wiring matrix) | gap para FULL_DELIVERY | etapa que resolve | issues
candidatas (confirmar conteúdo — ver §6 U1).

| # | Componente | Estágio atual | Gap para FULL_DELIVERY | Etapa | Issues candidatas |
|---|---|---|---|---|---|
| G1 | AutonomousLoop / ObjectiveStep | ACTIVE, 1 passo/chamada; sem Executor retorna `dispatch_intent` (awaits-planner) | Falta autoridade de continuação: quem decide próxima ação, quem chama o Planner, quem persiste progresso, como a continuação executa no OpenCode V2 real | 1 | #6 (epic), #30, #141, #137, #138 (confirmar) |
| G2 | PlannerLoop | ACTIVE-parcial (planning only, never dispatches) | Planeja mas não despacha; quebra a cadeia autônoma | 1 | #8, #9, #10 (confirmar) |
| G3 | DispatchPipeline | ACTIVE record-only (`spawned=false`) | Registra mas não executa dispatch real | 1 | #30, #141 (confirmar) |
| G4 | ObjectiveController | ACTIVE-cálculo (`next_move` puro, não loopa) | Decide mas não itera; sem loop não há avanço automático | 1 | #6 (confirmar) |
| G5 | Políticas autonomia + Delivery | Delivery DECISÓRIO-ONLY (elegibilidade + state machine); políticas dispersas | Falta regra única e auditável: avançar / pausar-legítimo / pedir-humano / declarar-DONE | 2 | #1, #4, #60, #61, #63 (confirmar) |
| G6 | DecisionProvider | NÃO-CONECTADO / test-only | Sem fonte de decisão ligada, impasse não gera ação | 3 | #60 (confirmar) |
| G7 | JevAdvisory + Advisor | ADVISORY-ONLY | Sinais de impasse não são gerados automaticamente nem integrados ao loop | 3 | #60, #86, #101 (confirmar) |
| G8 | Model Router adaptativo | Política/pools definidos; sem prova de roteamento adaptativo em produção | Roteamento existe no papel; falta prova de adaptação real (severidade → tier) e cotas | 4 | #19, #20, #113, #114 (confirmar) |
| G9 | GoalCheckpoint / GoalProgress / GoalPromotion | Checkpoint IMPLEMENTED (nunca tocou sessões reais); Progress/Promotion SCORE-ONLY | Retomada após CI/PR não provada em sessões reais | 5 | #106, #116, #139, #140 (confirmar) |
| G10 | SessionReconciler | READ-ONLY | Lê, mas não reconcilia/retoma estado executivo | 5 | #106 (confirmar) |
| G11 | Merge/Deploy autorizado | Fora do loop (autorização manual; `PRODUCTION_AUTHORIZED` ausente = false) | Falta caminho autorizado e verificável de entrega em ambiente pré-aprovado | 6 | #50, #51, #143 (confirmar) |
| G12 | `runtime_grant_enforcement` (v1/v2) | OFF-HOLD (fail-open /shell) | Sem enforcement, autonomia com escrita é insegura; gate para Etapas 1 e 6 | 1 (reconhecer) + 6 (exigir) | HOLD #69, #70; P0 a confirmar |
| G13 | Watchdog | ATIVO com HOLD residual | Backstop existe; resíduos (janela gate→kill, preempção) precisam de tratamento no loop autônomo | 1, 7 | #19, #20 (confirmar) |
| G14 | ObjectiveRunner.harness | TEST-HARNESS-NOT-PRODUCT | Risco de promover evidência de harness a "prova" | Transversal (regra 10) + 7 | #6 (confirmar) |
| G15 | AdapterContract | ACTIVE-lib (10 ops × V1/V2, sem VERIFIED) | Sem VERIFIED por op/runtime, a continuação no V2 real é aposta | 1, 7 | #61, #63 (confirmar) |
| G16 | EvidenceStore (TTL AR-10) + GoalKernel (CAS+lock) | ACTIVE / ACTIVE | Base pronta; gap é **usar** (reuso automático + persistência de progresso) em vez de reconstruir | Reuso em todas; provar na Etapa 1 | — (infra reutilizada) |

## 3. As sete etapas de implementação

Cada etapa é uma fatia delimitada: implementada, testada, revisada e integrada antes de expandir o escopo.
Nenhuma etapa pode ser declarada concluída só por harness (regra 10).

### Etapa 1 — Primeira fatia funcional (desbloqueia tudo)

- **Escopo:** menor correção para que a conclusão de uma Task dispare automaticamente a próxima ação do Goal no
  OpenCode V2 real, sem humano e sem falso DONE. Inclui: quem decide (Controller→Loop), quem chama o Planner,
  onde persiste progresso (GoalKernel/EvidenceStore), por que resultado intermediário não para, limites
  host/orçamento.
- **Entregáveis:** teste que reproduz a interrupção indevida (falha antes, passa depois); fix mínimo; validação
  em fixture **e** runtime real; PR + review + CI + integração.
- **Dependências:** nenhuma (é a primeira); registra HOLD de `runtime_grant_enforcement` como risco (G12).
- **Issues:** G1–G4, G13-parcial, G15-parcial.
- **Aceite (testável):** ver §4 (AC1.1–AC1.4).

### Etapa 2 — Harmonização das políticas de autonomia e delivery

- **Escopo:** unificar em uma regra auditável: avançar / pausar-legítimo / pedir-humano / declarar-DONE;
  eliminar divergências entre políticas de autonomia e state machine do Delivery.
- **Entregáveis:** matriz decisão×estado; testes de transição (incluindo "não declarar DONE com task pendente").
- **Dependências:** Etapa 1 (comportamento real observado).
- **Issues:** G5.

### Etapa 3 — Sinais automáticos de impasse + consultores

- **Escopo:** gerar sinal de impasse por evidência (N tentativas sem progresso, ciclo, bloqueio) e integrar
  DecisionProvider + JevAdvisory + Advisor ao loop sem parar o Goal.
- **Entregáveis:** gerador de sinal + teste de disparo/não-disparo; consulta consultiva com retorno ao loop.
- **Dependências:** Etapas 1–2.
- **Issues:** G6–G7.

### Etapa 4 — Roteamento adaptativo comprovado de modelos

- **Escopo:** provar em runtime que severidade → tier (T2/T3/T4) funciona e respeita cotas; sem fan-out ritual.
- **Entregáveis:** casos com escalation justificada vs. negada (falta informação → Explorer, não modelo maior).
- **Dependências:** Etapa 3 (impasse real como gatilho).
- **Issues:** G8.

### Etapa 5 — Retomada durável após CI/PR

- **Escopo:** GoalCheckpoint + SessionReconciler retomam o Goal após CI/PR com estado persistido; provar em
  sessões reais.
- **Entregáveis:** teste de retomada (mata sessão no meio, retoma sem perda/duplicação).
- **Dependências:** Etapas 1–2.
- **Issues:** G9–G10.

### Etapa 6 — Merge e deploy em ambientes previamente autorizados

- **Escopo:** caminho autorizado (ambiente nomeado + `PRODUCTION_AUTHORIZED` + `CREDENTIAL_SCOPE`) até entrega
  verificável; irreversíveis com confirmação separada.
- **Entregáveis:** pipeline autorizado + verificação pós-deploy + rollback documentado.
- **Dependências:** Etapas 1, 2, 5 + decisão sobre `runtime_grant_enforcement` (HOLD #69/#70).
- **Issues:** G11–G12.

### Etapa 7 — Certificação da jornada completa + simplificação

- **Escopo:** certificar UMA jornada completa (objetivo → entrega verificável) em runtime real; só então
  simplificar componentes duplicados pelo OpenCode V2 **com equivalência comprovada**.
- **Entregáveis:** relatório de certificação (evidências por estágio); lista de simplificações aprovadas vs.
  rejeitadas.
- **Dependências:** Etapas 1–6.
- **Issues:** G13–G15 + P2 backlog como varredura final.

## 4. Critérios de aceite

### Etapa 1 (bloqueante)

- **AC1.1:** existe teste que reproduz a interrupção (Goal com 2 tasks dependentes para após a 1ª) — verificado
  por `FAIL antes / PASS depois` no CI.
- **AC1.2:** em runtime OpenCode V2 real, o log/telemetria mostra `task[0]=concluída → next_move →
  task[1]=iniciada` sem evento de intervenção humana entre elas.
- **AC1.3:** nenhum `DONE` é emitido com task pendente (verificação: `DONE` só após última task verificada).
- **AC1.4:** PR com o fix mínimo + review APPROVED + CI verde + integração registrada.

### Globais (Etapa 7)

- **ACG.1:** uma jornada completa executa objetivo → plano → implementação → teste → correção → review → CI →
  integração → deploy autorizado → entrega verificável, sem parada indevida (evidência: log ponta a ponta +
  artefatos por estágio).
- **ACG.2:** pausa só ocorre por motivo legítimo (orçamento/autorização/irreversível sem confirmação) com estado
  persistido e retomável (verificado matando/retomando).
- **ACG.3:** nenhuma prova vem exclusivamente de harness (toda claim de autonomia cita run no runtime V2 exato).
- **ACG.4:** Meu TED não aparece como ambiente de prova em nenhum relatório.
- **ACG.5:** simplificações de componentes têm prova de equivalência nativa anexada; sem prova, componente
  permanece.

## 5. Seção de não-duplicação (o que é reutilizado por referência)

**Não reescrever (reusar):** TaskKernel (âncora runtime-proven), GoalKernel (CAS+lock+store), AutonomousLoop/
ObjectiveStep (1 passo + checkpoint), PlannerLoop (planning-only + Jev advisory), DispatchPipeline, ObjectiveController
(`next_move` puro), Model Router (pools T0–T4 + cotas), JevAdvisory, Advisor (engineering-advisor), Delivery
(elegibilidade + state machine), EvidenceStore (reuse + TTL), SessionReconciler, GoalCheckpoint/Progress/Promotion,
AdapterContract, Watchdog, políticas (`AUTONOMY.md`, `autonomy-policy.json`, `delivery-policy.json`), GitHub
lifecycle policy.

**Não duplicar conteúdo de SPECs antigas:** este plano referencia por nome as SPECs/PLANs v0.1.0, o wiring matrix
e o issue triage matrix; não repete seus textos. Detalhes normativos vivem lá.

**Non-goals explícitos (o plano vNEXT NÃO deve):**

- N1: reescrever a arquitetura de orquestração ou criar V4/novo framework.
- N2: reespecificar TaskKernel, GoalKernel, Delivery, Model Router, Jev — apenas referenciar as SPECs existentes.
- N3: reescrever wiring matrix, issue triage matrix, SPEC/PLAN/CORRECTIVE-PLAN v0.1.0 — apenas apontar.
- N4: implementar equivalentes locais de recursos nativos do OpenCode V2 sem antes verificar o nativo.
- N5: criar fonte de configuração concorrente com o Agent Config.
- N6: usar Meu TED como piloto ou promover harness a prova.
- N7: ativar `skill_routing` / `mcp_routing` / `adaptive_ranking` / novos flags (fora do escopo).
- N8: declarar DONE por relatório de progresso ou conclusão intermediária.

## 6. Edge cases e unknowns

**Edge cases a cobrir nos testes:**

- E1: falso DONE — Controller emite DONE com task pendente (causa provável: `next_move` tratando "sem próxima
  ação conhecida" como "concluído"). AC1.3 deve capturar.
- E2: budget esgotado no meio — parada legítima; exigir estado persistido + motivo `BUDGET` (não confundir com
  bug de continuação).
- E3: autorização ausente (`PRODUCTION_AUTHORIZED` ausente = false) — merge/deploy bloqueia e devolve ao Planner;
  não é falha da autonomia.
- E4: fail-open /shell (`runtime_grant_enforcement` OFF) — autonomia com escrita sem enforcement é risco; Etapa 1
  deve documentar o perímetro permitido.
- E5: OpenCode V2 atualiza no meio do programa — AdapterContract sem VERIFIED quebra; exigir pin de runtime por
  evidência (`runtime-versions.json`).
- E6: CI/PR demora ou falha de forma recuperável — não aborta o Goal; Etapa 5 cobre retomada.
- E7: sinal de impasse ruidoso — dispara consultor sem necessidade e encarece (Etapa 4 sem Etapa 3 calibrada).
- E8: duas tasks "dependentes" sem dependência real — o teste da Etapa 1 deve usar dependência genuína (a 2ª
  consome artefato da 1ª), senão o teste é fraco.

**Unknowns — resolvidos para o escopo atual (autorização de continuidade, 2026-10-30):**

- U1: resolvido — issues consultadas diretamente no GitHub. Nota: #51 e #106 **não existem** (fechadas/renomeadas);
  a triage matrix os listava, mas eles não podem ser dependência. Substituir por #30 (Golden Workflows) e
  #103 (runtime repair) onde fizer sentido. #8/#9/#10/#30/#50/#86/#101/#137/#138/#141/#69/#70 confirmados abertos.
- U2: resolvido — OpenCode V2 instalado: `opencode v2.2.3`, binário `C:\Users\walis\bin\opencode.cmd`,
  SHA-256 `6E616082614B60E679E632BE29F6213C2D07B2C9F029F1629B0E6DC2F607755F`. O pin do CI (2.0.23) permanece
  como baseline distinta; a prova da Etapa 1 usa a instalação real (2.2.3), registrando ambos.
- U3: resolvido — piloto usa fixture descartável própria da Orquestração (diretório temporário isolado), sem
  dependência de Meu TED ou de projeto externo.
- U4: resolvido — escrita normal no repositório via branch/PR; efeitos de teste somente na fixture; nenhum
  ambiente produtivo tocado. O enforcement host-side (`runtime_grant_enforcement`) permanece OFF-HOLD; a Etapa 1
  documenta o perímetro permitido e não depende de habilitá-lo.
- U5: resolvido (adiado) — autorização de deploy fica para a Etapa 6; a Etapa 1 não executa deploy.
- U6: resolvido — conferir código, histórico e issues atuais antes de confiar em matrizes antigas; a matriz de
  gaps deste plano é hipótese a validar por reprodução, não fato consumado.

## 7. Status de execução

- ETAPA 0 — **concluída** (este documento).
- ETAPA 1 — **ETAPA_1_ACCEPTED** (gate final 2026-10-30, commit 7d0b96b).
- ETAPA 2 — **concluída** (harmonização verificada 2026-10-30).
- ETAPA 3 — **ETAPA_3_INTEGRATED** (consumo integrado 2026-10-30, ver §9.1).
- ETAPA 4 — **ETAPA_4_INTEGRATED** (execucao real 2026-10-30, ver §10.1).
- ETAPA 5 — **ETAPA_5_INTEGRATED** (retomada integrada 2026-10-30, ver §11.1).

### 7.1 Etapa 1 — causa-raiz reproduzida (RED)

Hipótese validada por reprodução (não mais mera suspeita):
- **Causa-raiz:** não existe caller produtivo que, ao concluir uma Task, re-invoque o Planner/Controller e
  persista o progresso no GoalKernel. Os componentes de loop (`Invoke-OrchestrationAutonomousObjective`,
  `Invoke-OrchestrationObjectiveStep`, `Get-OrchestrationGoalNextMove`) existem e funcionam, mas são exercidos
  apenas por testes e por `objective-step.ps1` (CLI manual/agent-driven). Em produção, o Planner (LLM) é o
  caller natural via `subagent` (V2) / `task` (V1), e não há instrução/automação que o obrigue a continuar.
- **Evidência RED:** `scripts/v3/lib/OrchestrationFullDeliveryEtapa1.tests.ps1` — cenário sem Executor (análogo
  ao OpenCode V2 real) para após o primeiro `dispatch_intent` e não avança sozinho para a Task B
  (`[RED] re-invocacao sem Executor nao avanca (gap)`). Reproduzido e registrado.
- **Causa secundária encontrada durante o RED:** o `DispatchSpec` precisa de `acceptance_criteria` no formato
  `criterion:<idx>` (validado por `Test-NDCriterionRef`) e `task_id` com ≥3 chars minúsculos. Um spec com
  critério textual livre falha em `invalid-acceptance-criteria`/`invalid-taskid` — armadilha de integração
  documentada.
- **Correção adicional (PR corretiva):** progresso removido do Executor. O Executor retorna apenas
  `candidate_pass`. Cadeia canonica por Task: dispatch -> settlement canonico -> verificacao de conteudo ->
  Set-OrchestrationTaskVerification (verified_pass) -> Set-OrchestrationTaskReview (approved) ->
  Test-OrchestrationTaskCompletion (gate) -> Complete-OrchestrationTask (DONE) -> progresso por CAS.
  Task A completa (DONE) ANTES de Task B iniciar. Testes negativos comprovam que progresso NAO avanca
  quando worker retorna erro ou arquivo nao satisfaz criterio.

### 7.2 Etapa 1 — menor correção (GREEN) — reuso, sem nova máquina de estados

- **Decisão:** não criar nova máquina de estados nem loop concorrente. Reutilizar o driver existente
  `Invoke-OrchestrationAutonomousObjective`, conectando-o a um Executor real que chama `opencode run` para
  executar o subagent. A auto-continuação já é suportada pelo código quando o Executor avança o progresso
  persistido após execução e verificação.
- **Evidência HARNESS_PASS:** `scripts/v3/lib/OrchestrationFullDeliveryEtapa1.tests.ps1` (23/23 PASS) — com
  Executor injetado, o driver executa Task A e Task B em sequência, sem intervenção humana, sem falso DONE,
  com resume idempotente.
- **Evidência RUNTIME_REAL_PASS:** `scripts/v3/full-delivery-pilot-driver.ps1` executado em OpenCode V2.2.3
  (SHA-256 `6E616082614B60E679E632BE29F6213C2D07B2C9F029F1629B0E6DC2F607755F`), modelo default do host.
  - Goal `fd-pilot-goal`, tasks `fd-task-a` / `fd-task-b`, owner `planner-1`, generation 1.
  - Task A: subagent executado via `opencode run` (~8s), criou `output-a.json` = `{"value":42,"from":"task-a"}`.
  - Task B: subagent executado via `opencode run` (~8s), consumiu `output-a.json`, criou `output-b.json` =
    `{"derived":84,"source":"{value:42,from:task-a}"}`.
  - Progresso: 0/2 → 1/2 → 2/2; fase 0 → 1 → 2 (atualizado APOS settlement canonico + verificacao + review + DONE, nao no Executor).
  - Correcao (PR corretiva): progresso movido do Executor para cadeia canonica. Executor retorna apenas
    candidate_pass. Cadeia por Task: dispatch → settlement canonico → verificacao de conteudo →
    Set-OrchestrationTaskVerification (verified_pass) → Set-OrchestrationTaskReview (approved) →
    Test-OrchestrationTaskCompletion (gate) → Complete-OrchestrationTask (DONE) → progresso por CAS.
    Task A completa (DONE) ANTES de Task B iniciar. Testes negativos comprovam que progresso NAO avanca
    quando worker retorna erro ou arquivo nao satisfaz criterio.
  - Goal finalizado via CAS: state = `COMPLETED`, progress = 2/2, phase = 2.
  - Nenhum comando humano entre as tarefas (log: `pilot-log.txt`).
  - Idempotência: receipts com idempotency key garantem que re-execução do mesmo dispatch não duplica efeito.
- **Caller produtivo identificado:** o driver `full-delivery-pilot-driver.ps1` fornece o Executor real
  (chamando `opencode run`), reusando `Invoke-OrchestrationAutonomousObjective` (driver existente). O estado
  (Goal/Task Kernel) permanece a autoridade. Nenhum novo loop concorrente foi criado.
- **Limitações residuais:** (a) `runtime_grant_enforcement` permanece OFF-HOLD (fail-open /shell) — perímetro
  de escrita restrito à fixture, sem tocar ambientes produtivos; (b) o deploy (Etapa 6) não foi tentado
  (adiado por autorização); (c) a prova usa o modelo default do host, não um modelo específico do pool.

### 7.3 Etapa 1 — fechamento funcional (AUDIT + RUNTIME REAL)

**Auditoria do Executor real (`full-delivery-pilot-driver.ps1`):**
- Como o OpenCode e chamado: `opencode run --format json <prompt>` (CLI independente por tarefa).
- Agente/modelo efetivos: agente default do host (sem `--agent`/`--model`), modelo default do host (sem override
  pago). Tempo: ~8s por tarefa.
- Sessao filha nativa ou execucao CLI independente: execucao CLI independente (processo separado via
  `opencode run`). Nao e sessao filha nativa do Planner (o plugin V2 nao expoe `execute.after` nem auto-advance
  hook). Classificacao: `RUNTIME_CLI_PILOT_PASS`.
- Ordem cronologica: PREPARE (receipt 'prepared') -> subagent execucao (opencode run) -> SETTLE (candidate
  validation) -> progress update (goal kernel) -> (repete para Task B) -> COMPLETION (CAS, state=COMPLETED).
- Quem atualiza `progress.satisfied`: o Executor (driver), apos execucao e verificacao do artefato, via
  `Update-OrchestrationGoal` (CAS com ownership). Somente apos `dispatch.ok`.
- Idempotencia apos interrupcoes: receipts com idempotency key (32 hex) garantem que re-execucao do mesmo
  dispatch retorna o resultado cacheado sem re-executar o subagent. Harness test (23/23) prova resume idempotente.

**Integracao produtiva (caminho normal):**
- O driver `full-delivery-pilot-driver.ps1` e o caminho normal (invocavel como comando unico, sem piloto manual).
- Reutiliza `Invoke-OrchestrationAutonomousObjective` (driver existente) + Executor real.
- Nenhum novo loop concorrente ou maquina de estados criado.
- O OpenCode V2 nao oferece hook de auto-advance deterministico (`execute.after` nao existe; plugin e
  observability + mandate injection). A integracao minima e o driver + mandate injection (ja no plugin).

**Teste de regressao:**
- `OrchestrationFullDeliveryEtapa1Runtime.tests.ps1`: 7/7 PASS (invoca o driver, verifica auto-advance 2 tasks,
  COMPLETED, artefatos A/B com dependencia real).

**Classificacao final da Etapa 1:**
- `RUNTIME_CLI_PILOT_PASS` (prova real de LLM em 2 tarefas dependentes, COMPLETED via CAS).
- `PRODUCTIVE_AUTONOMY_PARTIAL` (o driver e o caminho normal e nao requer piloto manual; o trigger e mediado
  pela invocacao do driver, nao por hook nativo do OpenCode, pois o host nao oferece auto-advance deterministico).
- Idempotencia e persistencia real do Task/GoalKernel comprovadas.

**Gate final (commit 7d0b96b, 2026-10-30) — ETAPA_1_ACCEPTED:**
- Review independente: CHANGES_REQUIRED atendidos (3 findings corrigidos):
  1. Harness GREEN reconcilia progresso por IDs mandatory em DONE (nao por dispatch count).
  2. Artefatos exigem strict JSON; fallback permissivo removido (verificacao e review rejeitam nao-JSON).
  3. Runtime test verifica exit code, ordem A.DONE antes de B, e falha se driver ausente na lane.
- Suites: harness 25/25, negativos 16/16, impasse 15/15, model-router 13/13, runtime 10/10 (lane FULL_DELIVERY_RUNTIME=1), package consistency 16/16, diff limpo.
- CI: lane deterministica (SKIP runtime sem provider); lane LLM explicita (FULL_DELIVERY_RUNTIME=1).
- Sem merge/deploy nesta rodada (bloqueadores de integracao externa fora do escopo da Etapa 1).

**Reviewer/security:** nao tocaram authority/grants/delivery/permissoes — review proporcional aplicado
(consistencia de pacote 16/16 OK + diff check limpo + testes focados + review independente).

**Integracao:** branch `feat/full-delivery-etapas-1-5`, PR #173.

**Proximo passo:** continuar implementacao funcional das Etapas 3-5 (impasses, model router aplicado, retomada apos CI/PR).

## 8. Etapa 2 — Harmonização de políticas (verificada)

**Escopo:** reconciliar `source/policies/AUTONOMY.md`, `source/registry/autonomy-policy.json`,
`source/registry/delivery-policy.json`, `scripts/v3/lib/OrchestrationAutonomy.ps1`,
`OrchestrationAutonomyWiring.ps1`, `OrchestrationExternalActionGate.ps1`,
`docs/github-lifecycle-policy.md` e integração com Agent Config.

**Divergências identificadas:** nenhuma material. A policy e o código listam os mesmos 19 auto-authorized
actions (verificado por comparação direta). A external action gate diferencia corretamente ALLOW /
NEEDS_USER_AUTHORITY / POLICY_BLOCKED. O delivery step trata CI failure → repair + revalidate (não terminal).

**Comportamentos verificados (testes existentes, todos verdes):**
- `OrchestrationAutonomy.tests.ps1`: 69 assertions PASS.
- `OrchestrationAutonomyWiring.tests.ps1`: 78 assertions PASS.
- `OrchestrationDelivery.tests.ps1`: 112 assertions PASS.
- `external-action-gate.tests.ps1`: 30 assertions PASS.
- `test-package-consistency.ps1`: 16/16 OK.

**Casos de aceitação da Etapa 2 (todos cobertos por testes existentes):**
1. Edição, teste e correção em escopo avançam sem confirmação humana — auto-authorized list inclui
   `edit_refactor`, `test_build`, `findings_repair`. ✓
2. CI com falha recuperável retorna para diagnóstico (repair), não para interrupção terminal — D3. ✓
3. Operação externa previamente autorizada não recebe bloqueio humano redundante — ExternalActionGate ALLOW. ✓
4. Ausência de autorização para ação irreversível continua impedindo o efeito — NEEDS_USER_AUTHORITY. ✓
5. Falha de provider não amplia permissões nem autoriza fallback pago — fail-closed, sem flag nova. ✓
6. Task concluída não encerra Goal com trabalho pendente — INV-006, testado em AutonomousLoop. ✓
7. Restrições explícitas do operador prevalecem sobre preferências padrão — Boundaries + Denied. ✓

**Conclusão:** a harmonização já estava implementada (PR-5 e fases anteriores). A verificação confirma
consistência entre policy, código e testes. Nenhuma mudança de código necessária para Etapa 2.

**Limitações residuais:** nenhuma nova — as da Etapa 1 persistem (runtime_grant_enforcement OFF-HOLD, deploy
adiado para Etapa 6).

**Próximo passo:** avançar para a Etapa 3 (escalonamento automático de impasses com Debugger, Jev, Advisor e
Model Router).

## 9. Etapa 3 — Sinal de impasse e escalonamento (implementado)

**Escopo:** geração automática de sinais de impasse e integração dos consultores (Debugger, Jev, Advisor, Model
Router) ao fluxo produtivo.

**Implementação:** `scripts/v3/lib/OrchestrationImpasseEscalation.ps1` — módulo puro que, dado um delta de
progresso (GoalProgress) e o estado da tarefa, gera um sinal de impasse estruturado com recomendações de
escalonamento (debugger, Jev, Advisor, Model Router). Nenhum efeito colateral, nenhuma autoridade concedida.

**Critérios de impasse:**
- stagnation_count >= threshold (default 3), OU
- última falha terminal, OU
- regressão (meaningful=false com reason 'regressed').

**Recomendações (advisory, não autoridade):**
- debugger_recommended: true se impasse.
- jev_recommended: true se impasse.
- advisor_recommended: true se impasse E risco medium/high/critical.
- model_router_action: 'escalate-tier' se impasse E risco high/critical; senão 'hold-tier'.

**Testes:** `OrchestrationImpasseEscalation.tests.ps1` — 15/15 PASS.

**Limitações:** o módulo produz o sinal; a integração ao loop (consumo do sinal pelo Planner) é a próxima
fatia. Os componentes Jev/Advisor/ModelRouter já existem e são testados.

**Próximo passo:** avançar para a Etapa 4 (roteamento adaptativo comprovado de modelos).

### 9.1 Etapa 3 — INTEGRADA (2026-10-30, branch feat/full-delivery-etapas-1-5)

**Novo:** `scripts/v3/lib/OrchestrationImpasseConsumption.ps1` — consome `Test-IEImpasseSignal`
sem nova maquina de estados. Uma invocacao = UMA intervencao (nunca fan-out):
missing-context -> explorer/gather-context; technical-reproducible -> debugger/debug-reproduce;
model-limitation -> jev/advisor (escalate se high/critical); legit-block -> wait-legit sem consultor.
Dedup por (failure_kind+consultant) em History; orcamento MaxInterventions (default 3);
consultores retornam evidencia/recomendacao, grants_authority=false sempre.

**Prova:** `OrchestrationImpasseConsumption.tests.ps1` 14/14 PASS — falha induzida em fixture
(stagnation 3, missing-context) => explorer acionado 1x, retorno incorporado, retry com dedup
sem repetir consultor; tecnico=>debugger; model-high=>advisor; legit=>wait; budget esgotado=>blocked;
sem impasse=>sem consultor.

**Limites:** classificacao depende de FailureKind informado pelo caller; sem telemetria de
progresso real o sinal nao dispara sozinho (integracao ao PlannerLoop via probe permanece
advisory-only por design).

## 10. Etapa 4 — Roteamento adaptativo (verificado)

**Escopo:** comprovar que o Model Router seleciona modelo admissível considerando papel, risco, complexidade,
falhas, quota, autorização e fallback.

**Implementação:** reutiliza `OrchestrationModelRouter.ps1` (existente, 291 linhas, bem testado). Nenhuma
mudança de código necessária — os testes existentes + novos cenários de aceitação cobrem todos os casos.

**Cenários de aceitação (todos cobertos):**
1. Tarefa simples sem escalonamento: coder trivial → T1/T2. ✓
2. Falha por falta de contexto: explorer → T0-T2 (nunca T3/T4). ✓
3. Impasse técnico: engineering-advisor high risk → T2+. ✓
4. Falha comprovada por capacidade do modelo: coder com FailureCount > 0 resolve. ✓
5. Modelo indisponível: agente desconhecido → REJECTED (fail-closed). ✓
6. Escalonamento pago não autorizado: T4 não selecionado sem cost auth. ✓
7. Repetição sem progresso: determinístico (mesmos inputs → mesmo tier). ✓
8. build (Planner) nunca usa T4. ✓
9. explorer nunca usa T3/T4. ✓

**Testes:** `OrchestrationModelRoutingEtapa4.tests.ps1` — 13/13 PASS + `OrchestrationModelRouter.tests.ps1` PASS.

**Limitações:** a prova é determinística (sem LLM). A aplicação real do tier selecionado ao processo depende
do runtime (OpenCode usa o modelo default do host, não o tier selecionado pelo router). A integração do tier
selecionado ao `opencode run --model` é a próxima fatia.

**Próximo passo:** avançar para a Etapa 5 (retomada durável após CI/PR).

### 10.1 Etapa 4 — INTEGRADA (2026-10-30)

**Novo:** `scripts/v3/lib/OrchestrationModelExecution.ps1` — `Invoke-OrchestrationModelExecution`
resolve via Router, emite recibo (`Get-OrchestrationModelRouterReceipt`: agente, tarefa,
solicitado/efetivo, tier, motivo, fallback), projeta `subagent_model_param` (interface
oficialmente suportada pelo subagent OpenCode V2) e verifica via
`Test-ExecutedModelVerification`. Barato por padrao; escala so com FailureCount>=2 + custo
autorizado; falha de contexto (IsContextFailure) zera FailureCount (nunca confunde contexto
com incapacidade); override de modelo desabilitado (ex. deepseek) recusado; sem prova de
override nativo o efetivo e fallback conservador (PROOF_ABSENT, fail-closed). Nenhuma escrita
em models.json / Agent Config.

**Prova:** `OrchestrationModelExecution.tests.ps1` 10/10 PASS — simples=>T1/T2 + log efetivo;
impasse justificado muda rota; nao-autorizado recusado/degradado; contexto nao escala;
desabilitado recusado; sem prova=>PROOF_ABSENT; sem config concorrente.

**Limites:** `NativeModelOverrideProven=false` no runtime atual (host usa modelo default);
o parametro `model` e projetado e verificado, mas a execucao real via `opencode run --model`
depende de provider/modelo provisionado. T4 exige OPENCODE_T4_AUTHORIZED; Astra exige
OPENCODE_ASTRA_AUTHORIZED.

## 11. Etapa 5 — Retomada durável (verificada)

**Escopo:** GoalCheckpoint + SessionReconciler retomam o Goal após CI/PR com estado persistido.

**Componentes (existentes e testados):**
- `OrchestrationGoalCheckpoint.ps1`: store atômico, 36 assertions PASS.
- `OrchestrationSessionReconciler.ps1`: read-only, 156 assertions PASS.
- `github-resume-reconcile.ps1`: reconciliação após CI/PR, 116 assertions PASS.
- `github-watch.ps1` / `github-await.ps1`: monitoramento de CI/PR.

**Testes:** github-resume-reconcile 116/116 PASS; GoalCheckpoint 36 PASS; SessionReconciler 156 PASS.

**Limitações:** a prova end-to-end (goal que sobrevive a um ciclo real de CI/PR) não foi executada. Os componentes
são testados isoladamente. A integração end-to-end é a próxima fatia.

**Próximo passo:** avançar para a Etapa 6 (merge e deploy em ambientes autorizados) ou Etapa 7 (certificação).

### 11.1 Etapa 5 — INTEGRADA (2026-10-30)

**Novo:** `scripts/v3/lib/OrchestrationDurableResume.ps1` — `Invoke-OrchestrationDurableResume`
integra checkpoint + reconciliacao + CI/PR + kernels em single-shot (sem daemon):
1. Load + Test-OrchestrationCheckpointResume (fail-closed, CAS stale detectado);
2. Get-OrchestrationSessionReconciliation (bindings/observacoes declaradas);
3. Test-OrchestrationGitHubResume (RESUME/READY/KEEP_WAITING/TERMINAL/DUPLICATE/OUT_OF_ORDER);
4. proxima Task nao-DONE (nunca reexecuta DONE; recibo idempotente impede duplicar efeito);
5. Goal so COMPLETED com criterios verificados.

**Prova:** `OrchestrationDurableResume.tests.ps1` 14/14 PASS em fixture isolada —
Goal inicia, Task A DONE canonico, checkpoint + wait CI/PR, "interrupcao" (nova leitura do
estado persistido), reconciliacao: CI verde=>advance em B sem duplicar A; vermelho
recuperavel=>TERMINAL diagnostic; atrasado=>KEEP_WAITING; CAS stale=>blocked; task DONE
isolada nao completa goal.

**Limites:** sessoes e snapshots sao declarados (caller-provided); V2 probing nativo segue
HOLD; sem turno real de CI (gh) nesta rodada — decisao e single-shot sobre snapshot.

**Classificacao de autonomia (evidencia real 2026-10-30):**
`ETAPA_3_INTEGRATED` + `ETAPA_4_INTEGRATED` + `ETAPA_5_INTEGRATED`;
Etapa 1 preservada (`ETAPA_1_ACCEPTED` / `RUNTIME_CLI_PILOT_PASS`, sem reabertura);
`PRODUCTIVE_AUTONOMY_PARTIAL` mantida (driver mediado, sem hook nativo de auto-advance);
Etapas 6-7 NAO marcadas (sem deploy/merge nesta rodada).

**Regra de evidência:** toda claim de "autônoma" cita run no runtime V2 exato (versão + pin + comando). Harness
sozinho nunca sustenta claim de autonomia produtiva.
