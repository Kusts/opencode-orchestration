# OPENCODE ORCHESTRATION — ISSUE TRIAGE & CONSOLIDATION MATRIX

**Data-base:** 2026-10-21  
**Status:** ACTIVE AUDIT  
**Baseline Git:** Commit `2e9c744` (origin/master)  
**Total de Issues Analisadas:** 74 (100% do backlog aberto)  
**Referência:** `docs/specs/BACKLOG-CONSOLIDATION-NATIVE-FIRST-SPEC.md` e `docs/plans/BACKLOG-REFINEMENT-2026-10-21.md`

---

## 1. Resumo Executivo da Triagem

| Categoria | Quantidade | Foco Principal | Status Geral |
|---|---|---|---|
| **P0 — Prioridade Imediata** | 13 | Ciclo produtivo, continuidade, compatibilidade V2, kernel e doctor | Em execução ativa |
| **P1 — Próxima Etapa** | 14 | MCPs, sessões nativas, worktrees nativos, PTY, segurança de overrides | Dependente da estabilização P0 |
| **P2 — Evolução Posterior** | 18 | Otimizações de custo/tokens, benchmarks comparativos e novos modos | Backlog futuro ordenado por valor |
| **UPSTREAM / HOLD** | 2 | Garantias de proveniência e mediação host-side do OpenCode V2 | HOLD honesto (sem bloquear o desenvolvimento) |
| **TRIAGE / CONSOLIDATION** | 27 | Consolidações sob epics, SPECs do PR #150 e encerramentos justificados | Triagem e auditoria detalhadas abaixo |
| **Total** | **74** | | |

---

## 2. P0 — Prioridade Imediata (13 Issues)

| ID | Título | Subsistema | Estado na Baseline (`2e9c744`) | Decisão | Destino / Epic | Critério de Aceite / Evidência Necessária |
|---|---|---|---|---|---|---|
| **#6** | VNext: arquitetura em camadas para orquestração segura, mensurável e adaptativa | Arquitetura | Base documental consolidada (`docs/ARCHITECTURE.md`) | **KEEP (Epic)** | Epic Geral V2 | Manter como documento de referência e alinhamento arquitetural. |
| **#8** | feat: formalize Task / Run / Session / Generation lifecycle and safe-control states | Kernel / Lifecycle | S1/S2 entregues nos PRs #131-#132; transições de estado formalizadas | **KEEP (Core)** | Core Kernel | Testes de transição de estado completos com CAS e fencing. |
| **#9** | feat: exactly-once result delivery and EvidenceRef handoff with provenance | Kernel / Receipts | S2 SETTLE canônico entregue no PR #132; idempotência comprovada | **KEEP (Core)** | Core Kernel | Prova de deduplicação estrita de recibos em execução real. |
| **#10** | feat: add event-driven runtime control with steer, interrupt, close and fail-closed reconciliation | Runtime / Control | Watchdog e job objects entregues; controle event-driven em andamento | **KEEP (Core)** | Core Runtime | Interrupção e retomada com reconciliação fail-closed. |
| **#30** | feat: add project-level Golden Workflows for end-to-end agent evaluation | E2E / Validação | Cenários 04..10 e 16..22 instrumentados | **KEEP (Core)** | Golden Workflows | Execução real da matriz GW (trivial, multi, recovery, github, mcp). |
| **#50** | feat(runtime,v2): compatibilidade adaptativa com atualizações do OpenCode V2 (capability-first) | Runtime / Doctor | `OrchestrationCapabilityDoctor.ps1` inicial implementado | **KEEP (Core)** | Compatibility Doctor | Detecção dinâmica de capabilities sem depender de hardcoded patch. |
| **#51** | test(runtime): provar ciclo Planner → subagent/task → Kernel → continuação em sessão OpenCode real | Runtime / E2E | S1–S5 entregues como `HARNESS_PASS`; runtime real pendente | **KEEP (P0 Crítico)** | Fluxo Produtivo V2 | Provar ciclo completo em sessão OpenCode V2 nativa real. |
| **#86** | feat(github,v2): monitoramento durável de CI/PR e retomada automática do Planner | GitHub / Autonomia | `github-watch`, `github-await`, `github-resume-reconcile` implementados | **KEEP (Core)** | GitHub Continuation | Retomada autônoma após conclusão de CI/PR sem intervenção humana. |
| **#101** | test(v2): regression gate for OpenCode 2.0.28–2.0.32 service, MCP, snapshots and permissions | Testes / Gate | Probes V2 existentes; suíte de regressão precisa de unificação | **KEEP (Core)** | Regression Gate | Gate de regressão para 2.0.28-2.0.32 e absorção de testes da #146. |
| **#106** | feat(evidence,v2): refresh stale evidence before DONE, replan and consequential transitions | Validação | Mecanismos de lease e timestamp existentes | **KEEP (Core)** | Fresh Evidence | Invalidação automática de evidências desatualizadas antes de DONE. |
| **#137** | epic(v2,native-first): inventariar e substituir duplicações por recursos nativos do OpenCode | Native-First | Matriz de capabilities criada; plano ativo | **KEEP (Epic)** | Native-First Epic | Inventário e substituição segura de duplicações por APIs nativas. |
| **#138** | fix(compat,v2.1): adaptar replay nativo, SDK/plugin e eventos de compactação sem breaking changes | Compatibilidade | Plugin `g1-dispatch-admission` ativo | **KEEP (Core)** | OpenCode 2.1.x | Compatibilidade com replay, eventos de compactação e SDK da 2.1.x. |
| **#141** | feat(policy,v2): consolidar permissões/policies nativas sob Agent Config sem duplicar autoridade | Config / Permissões | ADR e contratos O0–O7 documentados | **KEEP (Core)** | Agent Config Interop | Unificação da autoridade declarativa sob Agent Config. |

---

## 3. P1 — Próxima Etapa (14 Issues)

| ID | Título | Subsistema | Decisão Proposta | Destino / Ação |
|---|---|---|---|---|
| **#1** | feat: política GitHub de delivery integrada à orquestração | GitHub / Governança | **KEEP** | Integrar com as rotinas de release e delivery gate. |
| **#4** | feat: add execution-strategy telemetry and evidence-driven routing | Telemetria | **KEEP** | Consolidar métricas de estratégia de execução. |
| **#19** | security(v2): enforce authorization for subagent model/provider/variant overrides | Segurança / Permissões | **KEEP** | Garantir que overrides de modelos respeitem grants do host. |
| **#20** | eval: add Tool/MCP Schema Robustness suite against schema bias | MCP / Robustez | **KEEP** | Suíte de validação de schemas MCP contra viés. |
| **#53** | eval(security): benchmark alternate execution paths and proportional risk treatment | Segurança | **KEEP** | Avaliar caminhos alternativos de execução com risco proporcional. |
| **#60** | feat(planner): advisor para destravar tarefas difíceis com diagnóstico de impasses e estratégias alternativas | Advisor / Planner | **KEEP** | Integrar advisor consultivo em impasses do Planner. |
| **#61** | fix(mcp): diagnosticar e habilitar uso efetivo do Jev no Planner e subagents (OpenCode V2) | MCP / Jev | **KEEP** | Diagnosticar e habilitar comunicação e fallback do Jev. |
| **#63** | test(mcp,v2): conformance suite for session isolation, concurrency and authorization | MCP / Concorrência | **KEEP** | Testar isolamento de sessão e concorrência de MCPs. |
| **#113** | test(v2): fault injection para cancelamento durável e retomada sem duplo efeito | Resiliência | **KEEP** | Injeção de falhas para testar cancelamento e retomada limpa. |
| **#114** | feat(mcp,rea,v2): discovery e uso seletivo do REA pelo Planner/subagents | MCP / REA | **KEEP** | Descoberta dinâmica e consumo seguro do REA. |
| **#116** | test(e2e,mcp,v2): seleção e uso real dos MCPs pelo Planner/subagents | MCP / E2E | **KEEP** | Validação E2E da seleção e chamada de MCPs. |
| **#139** | feat(runtime,v2): adotar PTY persistente Windows e lifecycle nativo para comandos longos | Runtime / PTY | **KEEP** | Utilizar terminal nativo PTY para comandos longos sem watchdog redundante. |
| **#140** | refactor(git,v2): usar worktrees nativos do Code Mode no lugar de gerenciamento duplicado | Git / Worktrees | **KEEP** | Delegar worktrees ao Code Mode mantendo CAS no Kernel. |
| **#143** | feat(session,v2): reutilizar APIs nativas de sessões, arquivamento e listagem nos Agent Teams | Sessões | **KEEP** | Reutilizar APIs nativas de sessão preservando Runs e Receipts. |

---

## 4. P2 — Evolução Posterior (18 Issues)

| ID | Título | Decisão Proposta | Observação |
|---|---|---|---|
| **#2** | feat: add cross-session Agent Teams for OpenCode V2 | **KEEP (Backlog P2)** | Evolução para colaboração cross-session após estabilização V2. |
| **#3** | feat: add bounded Swarm execution mode with adaptive fan-out | **KEEP (Backlog P2)** | Modo swarm bounded; ativar apenas com métricas de custo. |
| **#5** | feat: add gated experimental Arena / Best-of-N execution | **KEEP (Backlog P2)** | Execução Best-of-N para tarefas de alto risco. |
| **#11** | feat: preserve prompt-cache continuity and measure cache-aware cost-to-DONE | **KEEP (Backlog P2)** | Otimização de prompt cache e custo por objetivo. |
| **#12** | feat: add Observation Virtualization with durable ArtifactRef and exact recall | **KEEP (Backlog P2)** | Virtualização de observações para reduzir overhead de contexto. |
| **#14** | feat: add verified Evidence Reduction for large diagnostic outputs | **KEEP (Backlog P2)** | Redução de evidências extensas preservando prova. |
| **#15** | feat: add Harness Profiles and benchmarked efficiency routing | **KEEP (Backlog P2)** | Perfis de harness para testes eficientes. |
| **#17** | feat: add Programmatic Execution strategy for repetitive deterministic tool sequences | **KEEP (Backlog P2)** | Execução determinística em lote de ferramentas. |
| **#48** | feat(vNext): planejamento estruturado e adaptativo de subagents por Objective/Goal | **KEEP (Backlog P2)** | Decomposição adaptativa de subagents. |
| **#49** | feat(vNext): painel local de orquestração para agentes, planos e execução (Control Center) | **KEEP (Backlog P2)** | Painel de controle local da orquestração. |
| **#52** | research(vNext): benchmark DeOrch + WorkflowOps for capability-first planning | **KEEP (Backlog P2)** | Pesquisa de modelos de planejamento. |
| **#77** | research(v2): promote verified agent traces into deterministic recipes | **KEEP (Backlog P2)** | Promoção de traces bem-sucedidos em receitas reutilizáveis. |
| **#99** | roadmap(v2): planejar Model Router adaptativo com Jev advisory (Beam/Muse/strong) | **KEEP (Backlog P2)** | SPEC/PLAN entregues no PR #150 (`MODEL-ROUTER-vNext-SPEC.md`); piloto F0-F2 em validação. |
| **#102** | eval(models): Muse Spark Open, Nemotron Bolt and LFM2.5 role-based cost-to-DONE | **KEEP (Backlog P2)** | SPEC entregue no PR #150 (`MODELS-102-SPEC.md`); benchmark posterior. |
| **#103** | research(runtime,v2): evaluate localized runtime repair before retry/replan | **KEEP (Backlog P2)** | Reparo localizado de runtime antes de replan. |
| **#104** | eval(skills,v2): add skill drift, compatibility and corruption regression suite | **KEEP (Backlog P2)** | Regressão e integridade de skills. |
| **#105** | eval(context,v2): benchmark whole-file selection vs chunk retrieval/compression | **KEEP (Backlog P2)** | Benchmark de seleção de arquivos vs chunks. |
| **#115** | feat(workflow,v2): investigação REA + browser → evidências → SPEC → implementação | **KEEP (Backlog P2)** | Workflow de investigação web com REA. |

---

## 5. UPSTREAM / HOLD (2 Issues)

| ID | Título | Razão do HOLD | Condição de Reativação |
|---|---|---|---|
| **#69** | security(g1): SEC-HIGH-01 — enforced admission exige mediação obrigatória host-side | Depende de enforcement upstream no host OpenCode V2. No runtime atual (2.0.23/2.0.28), a superfície `/shell` tem comportamento fail-open para deny. | Manter em HOLD com monitoramento; não tentar reimplementar bypass local; reavaliar quando nova versão do host entregar mediação host-side garantida. |
| **#70** | security(g1): HOST-PROVENANCE — independent execution attestation (Intent para Settlement) | Prova criptográfica/atestação independente de execução gerada diretamente pelo host OpenCode V2. | Manter em HOLD; utilizar enquanto isso receipts canônicos in-process com CAS e hashes SHA-256 no Kernel local. |

---

## 6. TRIAGE / CONSOLIDATION / CLOSURE REVIEW (27 Issues)

| ID | Título | Situação Atual em `2e9c744` | Decisão Proposta | Destino / Justificativa |
|---|---|---|---|---|
| **#7** | feat: separate supervision graph from execution ownership graph | Escopo coincide com o Kernel de Ownership formalizado na #8 | **CONSOLIDATE** | Consolidar em **#8**. A separação entre grafo de supervisão e ownership é tratada na formalização de Task/Run/Session. |
| **#13** | feat: add Safe Action Fusion for mutation + bounded validation | Ações fusionadas podem violar isolamento do Kernel se não forem estritamente determinísticas | **CONSOLIDATE** | Avaliar consolidação em **#17** (Programmatic Execution). Não manter como mecanismo independente. |
| **#16** | feat: add pluggable Decision Provider interface with confidence-gated fallback | `OrchestrationDecisionProvider.ps1` já existe e está coberto por testes unitários | **AUDIT & CLOSE** | Fechar a interface funcional como **COMPLETED** caso testes passem; mover benchmarks comparativos para **#99**. |
| **#21** | distribution: 6 suites falham por dialeto V1 presumido vs install Auto->V2 | Problema histórico de transição V1->V2; base atual já opera V2-first | **REPRODUCE & CLOSE** | Executar suíte de distribuição. Se verde na base V2 atual, fechar como **COMPLETED**. |
| **#25** | Investigate recurring regeneration of legacy ai-memory.ts on OpenCode V2 | Investigação de resíduo legado de arquivo TypeScript gerado em diretório de config | **MONITOR & CLOSE** | Confirmar ausência de regeneração por 7 dias; após confirmação, fechar como **COMPLETED**. |
| **#29** | research: evaluate Agent Gateway pattern for centralized MCP, secrets, policy and audit | Pesquisa de gateway centralizado; ADR coberta no PR #150 (`LITELLM-125-ADR.md`) | **CONSOLIDATE** | Consolidar em **#141** (Agent Config Ownership) e **#1**. Não criar gateway paralelo. |
| **#42** | eval(models): benchmark Claude Haiku 5.5 for low-cost specialist routing | Avaliação de modelo de baixo custo para papéis especialistas | **CONSOLIDATE** | Consolidar na matriz de modelos **#102** e Model Router **#99**. |
| **#43** | research(runtime): evaluate MXC sandbox and Pi 1.1 control telemetry | ADR entregue e aprovada no PR #150 (`MXC-PI11-43-ADR.md`) | **CLOSE COMPLETED (ADR)** | Fechar como **COMPLETED** (ADR de pesquisa concluída; sem necessidade de código adicional). |
| **#55** | eval(decision): benchmark Clef-flash/Clef-omni vs Jev with calibrated fallback | SPEC de benchmark entregue no PR #150 (`CLEF-BENCHMARK-55-SPEC.md`) | **CONSOLIDATE** | Consolidar na suíte de benchmarks de modelos **#102** / **#99**. |
| **#56** | research(mcp): evaluate Skills over MCP discovery with trust and version pinning | ADR entregue e aprovada no PR #150 (`SKILLS-MCP-56-ADR.md`) | **CONSOLIDATE** | Consolidar requisitos de discovery nativo em **#137** e **#116**. |
| **#57** | eval(models): benchmark JetBrains Mellum 2.1 as local coding subagent | SPEC de benchmark entregue no PR #150 (`MELLUM-21-BENCHMARK-57-SPEC.md`) | **CONSOLIDATE** | Consolidar no backlog de avaliação de modelos **#102**. |
| **#64** | research(v2): selective skill discovery and context-cost evaluation | ADR entregue e aprovada no PR #150 (`SKILL-DISCOVERY-64-ADR.md`) | **CONSOLIDATE** | Consolidar em **#137** e **#116** (descoberta nativa). |
| **#78** | eval(observability,v2): benchmark gh-aw unified traces, graders and model-routing evidence | ADR entregue e aprovada no PR #150 (`GHAW-78-ADR.md`) | **CONSOLIDATE** | Consolidar em **#4** (Telemetria) e **#30** (Golden Workflows). |
| **#79** | eval(decision): add Microsoft-Decision-1 as candidate to provider benchmark | SPEC de benchmark entregue no PR #150 (`DECISION-1-BENCHMARK-79-SPEC.md`) | **CONSOLIDATE** | Consolidar em **#102** e **#99**. |
| **#80** | eval(models,v2): benchmark Meta Muse Wonder for long-horizon Planner and recovery | Avaliação de modelo de longo horizonte | **CONSOLIDATE** | Consolidar na matriz de modelos **#102**. |
| **#81** | research(v2): benchmark Paperclip external-agent MCP and OpenRig recovery patterns | ADR entregue e aprovada no PR #150 (`PAPERCLIP-OPENRIG-81-ADR.md`) | **CLOSE COMPLETED (ADR)** | Fechar como **COMPLETED** (ADR de pesquisa concluída). |
| **#107** | research(v2,post-closure): avaliar OpenCodeHarness remoto em Cloudflare Durable Objects | Pesquisa de harness remoto; viola preceito native-first de simplicidade | **NOT_PLANNED** | Fechar como **NOT_PLANNED** (custo e complexidade não justificam o ganho frente ao runtime local nativo). |
| **#111** | eval(models,v2): DeepSeek V4.1 Flash 1017 vs baseline por papel | SPEC de benchmark entregue no PR #150 (`DEEPSEEK-111-SPEC.md`) | **CONSOLIDATE** | Consolidar em **#102** e **#99**. |
| **#112** | research(v2): estudar Beam + Mirror CLI como referências de harness recuperável | Pesquisa de ferramentas externas para harness recuperável | **NOT_PLANNED** | Fechar como **NOT_PLANNED** (recuperação já implementada no Task/Goal Kernel sem ferramentas de terceiros). |
| **#124** | research(v2): Agent Swarm 2.4 — avaliar Jev checklist, mailbox e presença | ADR entregue e aprovada no PR #150 (`SWARM-24-124-ADR.md`) | **CLOSE COMPLETED (ADR)** | Fechar como **COMPLETED** (pesquisa concluída; rejeição expressa de segundo orquestrador documentada). |
| **#125** | research(gateway): avaliar LiteLLM virtual keys e OAuth MCP para gateway compartilhado | ADR entregue e aprovada no PR #150 (`LITELLM-125-ADR.md`) | **CLOSE COMPLETED (ADR)** | Fechar como **COMPLETED** (pesquisa concluída; autoridade de credenciais delegada ao host/Agent Config). |
| **#142** | feat(planner,v2): integrar todowrite nativo como projeção do plano, sem duplicar Task Kernel | SPEC entregue no PR #150 (`TODOWRITE-142-SPEC.md`) | **CONSOLIDATE** | Consolidar em **#49** (painel) como projeção opcional read-only. |
| **#145** | eval(mcp,v2): Kimi 2.3 deferred tools e namespaces de skills sem duplicar registry | Avaliação de ferramentas diferidas | **CONSOLIDATE** | Consolidar em **#137** e **#116** (avaliação de MCP diferido no inventário native-first). |
| **#146** | test(runtime,v2): OpenCode 2.1.2 concorrência, rate limit e lifecycle de serviços | Testes de runtime para 2.1.2 | **CONSOLIDATE** | Transferir casos de teste para o gate de regressão **#101** e compatibilidade **#138**. |
| **#147** | eval(retrieval): Nemotron Embed/Rerank/Parse para AI Memory e evidências dos agentes | SPEC entregue no PR #150 (`NEMOTRON-147-SPEC.md`) | **CONSOLIDATE / TRANSFER** | Transferir escopo de embedding/reranking para o repositório/projeto AI Memory. |
| **#148** | test(monitoring,v2): detectar alteração indevida de observabilidade e autorizações | Detecção de alteração de observabilidade por agentes | **CONSOLIDATE** | Consolidar em **#53** (segurança) e **#106** (refresh de evidência). |
| **#149** | test(ci,v2): pilotar GitHub Actions workflow lockfiles sem bloquear o delivery | Piloto concluído no PR #150; registrou `startup_failure` no CI (`e216c5c`); ADR arquivada (`ACTIONS-LOCK-PILOT-149-ADR.md`) | **CLOSE COMPLETED (PILOTO)** | Fechar como **COMPLETED** (piloto executado e diagnosticado com evidência de incompatibilidade; sem lockfile na master). |
