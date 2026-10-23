# OPENCODE ORCHESTRATION — BACKLOG CONSOLIDATION & NATIVE-FIRST SPEC

**Versão:** 1.0  
**Data-base:** 2026-10-21  
**Repositório:** [opencode-orchestration](https://github.com/Kusts/opencode-orchestration)  
**Status:** ACTIVE SPECIFICATION — Documentação e planejamento canônicos aprovados  
**Escopo:** Exclusivamente OpenCode V2; V1 permanece `LEGACY_FROZEN` conforme issue #62.  
**Baseline de Commit:** `2e9c744` (incorporando PRs #129-#136, #144, #150).

---

## 1. Objetivo

Refinar e consolidar o sistema de orquestração existente, priorizando confiabilidade operacional, autonomia, integração nativa com OpenCode V2 e redução de complexidade.

O projeto já possui Planner, 19 workers especializados, Task/Goal Kernel, mecanismos de recibos, evidências, watchdog, controle de execução, políticas e integração inicial com MCPs.

A prioridade não é adicionar indiscriminadamente novas funcionalidades, mas:

1. **Fazer os componentes existentes funcionarem juntos em uma sessão real.**
2. **Eliminar código redundante e implementações que duplicam funcionalidades nativas.**
3. **Resolver lacunas de execução, continuidade, recuperação e coordenação.**
4. **Garantir compatibilidade adaptativa com versões futuras do OpenCode V2.**
5. **Consolidar ou encerrar issues sem benefício independente suficiente.**
6. **Evoluir posteriormente por evidência de qualidade, custo e confiabilidade.**

---

## 2. Princípios Arquiteturais

### 2.1 Native-first

OpenCode V2 é responsável, sempre que comprovadamente suportado, por:

- Execução nativa de ferramentas e subagents.
- Criação, listagem e gerenciamento de sessões.
- Terminal, PTY e lifecycle nativo.
- Ciclo de vida dos Git worktrees.
- Gerenciamento de permissões suportado pelo host.
- APIs, SDK, eventos e capacidades nativas de MCPs e skills.

A Orquestração permanece responsável por:

- Planejamento e decomposição de objetivos.
- Estratégia de delegação e seleção dos agentes.
- Task/Goal Kernel e suas invariantes.
- Ownership, leases, fencing e CAS.
- Gestão de dependências e coordenação.
- Evidências, validação e DONE.
- Políticas de execução por objetivo.
- Retomada causal e reconciliação.
- Decisões sobre retry, replan e escalonamento.

> [!IMPORTANT]
> Não substituir um componente local apenas porque existe uma API parecida. Exigir equivalência comportamental comprovada.

### 2.2 Reuse-first

Antes de qualquer implementação:

- Investigar código e contratos existentes.
- Consultar documentação e decisões anteriores.
- Recuperar aprendizados úteis do AI Memory (`workspace = "ferramentas"`, `project = "opencode-orchestration"`).
- Verificar capacidades nativas e MCPs já disponíveis.
- Identificar callers reais e caminhos não utilizados.
- Preferir adaptar ao invés de duplicar.

### 2.3 Única autoridade por responsabilidade

- O **Agent Config** é proprietário das configurações globais, perfis e permissões declarativas que lhe pertencem.
- O **OpenCode V2** é proprietário da execução e das capacidades nativas mediadas pelo host.
- A **Orquestração** é proprietária das decisões de coordenação, dos estados do Task/Goal Kernel e da execução do objetivo dentro das autorizações concedidas.
- O **AI Memory** é uma fonte de conhecimento e reuso, não a fonte autoritativa do estado da execução.
- O **GitHub** é fonte autoritativa para PRs, commits, reviews e checks.

O sistema não deve criar uma segunda autoridade para nenhuma dessas responsabilidades.

---

## 3. Invariantes Obrigatórias

- **Planner Único:** Existe um único Planner coordenador por objetivo.
- **Kernel como Fonte da Verdade:** Task/Goal Kernel permanece fonte da verdade das tarefas e objetivos.
- **Nenhum DONE por Worker:** Um worker não declara arbitrariamente que um objetivo foi concluído; trabalhadores retornam `candidate_pass`, `failed` ou `blocked`.
- **Diferenciação de DONE:** `TASK_DONE`, `WAVE_DONE` e `PHASE_DONE` não equivalem a `OBJECTIVE_DONE`.
- **Idempotência de Efeitos:** Receipts e settlements devem permanecer idempotentes.
- **Retry Seguro:** Retry não pode repetir efeitos externos ambíguos.
- **Ownership e Generation:** Cancelamento e encerramento respeitam ownership e generation (fencing CAS).
- **Consultoria Sem Autoridade:** Decisões de Jev ou outros modelos auxiliares são estritamente consultivas.
- **Grants Irredutíveis:** Permissões e grants explícitos não podem ser ampliados por modelos, MCPs ou rotas alternativas.
- **Separação de Modos:** Modos advisory e host-enforced são tratados distintamente.
- **Prova Runtime-Real:** Nenhum teste isolado, mock ou harness autoriza alegar funcionamento runtime-real.
- **V1 Congelado:** Evoluções não podem reativar trabalho de desenvolvimento da V1 (`LEGACY_FROZEN`).

---

## 4. Taxonomia do Backlog (74 Issues)

As 74 issues abertas no repositório são distribuídas em cinco grupos operacionais:

### P0 — Prioridade Imediata (13 issues)
**Issues:** #6, #8, #9, #10, #30, #50, #51, #86, #101, #106, #137, #138, #141.  
**Objetivo:** Integração funcional, continuidade, compatibilidade e fechamento do ciclo produtivo Planner → worker → Kernel → continuação.  
A issue #6 funciona como epic/guia arquitetural, sem abrir implementação paralela.

### P1 — Próxima Etapa (14 issues)
**Issues:** #1, #4, #19, #20, #53, #60, #61, #63, #113, #114, #116, #139, #140, #143.  
**Objetivo:** Integração MCP, otimização da execução, observabilidade, ações externas e substituição de componentes redundantes.

### P2 — Evolução Posterior (18 issues)
**Issues:** #2, #3, #5, #11, #12, #14, #15, #17, #48, #49, #52, #77, #99, #102, #103, #104, #105, #115.  
**Objetivo:** Melhorias mensuráveis de eficiência, benchmarks e extensões após a estabilização completa.

### UPSTREAM / HOLD (2 issues)
**Issues:** #69, #70.  
**Objetivo:** Acompanhar requisitos de enforcement e proveniência do host OpenCode V2, sem bloquear operações cooperativas permitidas.

### TRIAGE / CONSOLIDATION / CLOSURE REVIEW (27 issues)
**Issues:** #7, #13, #16, #21, #25, #29, #42, #43, #55, #56, #57, #64, #78, #79, #80, #81, #107, #111, #112, #124, #125, #142, #145, #146, #147, #148, #149.  
**Objetivo:** Avaliar consolidação, transferência, rejeição, implementação pré-existente ou fechamento condicionado com evidência.

---

## 5. Regras de Encerramento e Auditoria

Não encerrar issues somente por idade, ausência de atividade, existência de ADR ou prioridade baixa.

### COMPLETED
Utilizar quando:
- O comportamento exigido foi implementado.
- Os critérios de aceite pertinentes foram comprovados por testes e evidências.
- Não há lacuna significativa oculta.

### DUPLICATE / CONSOLIDATED
Utilizar quando:
- O escopo está inteiramente coberto por outra issue prioritária.
- Os critérios exclusivos foram transferidos e documentados no destino.
- A issue principal está claramente identificada.
- Não há trabalho independente relevante a perder.

### NOT PLANNED
Utilizar quando:
- A solução não é necessária no horizonte atual.
- Existe alternativa nativa melhor.
- O custo ou complexidade não justifica o ganho.
- A proposta pertence a outro repositório.
- A pesquisa está documentada e sua implementação foi conscientemente descartada.

### MANTER ABERTA
Quando faltar:
- Evidência runtime-real exigida.
- Resultado de benchmark solicitado.
- Confirmação de correção sem regressão.
- Capacidade upstream do host.
- Critério de aceite relevante.

---

## 6. Mapeamento de Consolidações Propostas

| Issue(s) | Destino Principal | Decisão Candidata | Justificativa |
|---|---|---|---|
| **#146** | #101 / #138 / #139 | Transferir testes da 2.1.2 | Escopo de concorrência e lifecycle coberto pelo gate de regressão 2.1.x |
| **#148** | #53 / #106 | Integrar cenários de monitoramento | Detecção de alteração de observabilidade funde-se com segurança e refresh de evidência |
| **#145** | #137 / #116 | Integrar avaliação de MCP diferido | Deferred tools do Kimi 2.3 pertencem ao inventário native-first e teste e2e MCP |
| **#7** | #8 | Formalizar contrato de ownership | Separação de supervisão vs execução é parte do ciclo de Task/Run/Session/Generation |
| **#142** | #49 | todowrite como projeção opcional | SPEC entregue no PR #150 (`TODOWRITE-142-SPEC.md`); integrar projeção ao painel |
| **#78** | #4 / #30 | Padrões de traces e graders | ADR entregue no PR #150 (`GHAW-78-ADR.md`); integrar com telemetria e Golden Workflows |
| **#42, #55, #57, #79, #80, #111** | #102 / #99 | Centralizar benchmarks por modelo | SPECs entregues no PR #150; consolidar sob matriz unificada de modelos #102 e Model Router #99 |
| **#56, #64** | #137 / #116 | Descoberta de skills e MCP | ADRs entregues no PR #150 (`SKILLS-MCP-56-ADR.md`, `SKILL-DISCOVERY-64-ADR.md`); integrar discovery nativo |
| **#29, #125** | #1 / #141 | Manter integração pertinente | ADR entregue no PR #150 (`LITELLM-125-ADR.md`); não criar gateway duplicado; integrar autorizações |
| **#147** | AI Memory | Transferir avaliação | SPEC entregue no PR #150 (`NEMOTRON-147-SPEC.md`); escopo de embeddings pertence ao AI Memory |
| **#107, #112** | ADR / pesquisa posterior | Considerar NOT PLANNED | Durable Objects remotos e Beam CLI adicionam acoplamento desnecessário sem ganho nativo comprovado |
| **#43, #81, #124** | ADRs concluídas | Preservar como referência | ADRs entregues no PR #150 (`MXC-PI11-43-ADR.md`, `PAPERCLIP-OPENRIG-81-ADR.md`, `SWARM-24-124-ADR.md`) |
| **#13** | #17 / #15 | Safe Action Fusion | Só preservar se houver benefício mensurável comprovado frente à execução programática |
| **#149** | Backlog futuro / ADR | Piloto concluído com diagnóstico | PR #150 registrou startup_failure no CI com lockfile; ADR preservada em `docs/plans/ACTIONS-LOCK-PILOT-149-ADR.md`; lockfile sem enforcement |

---

## 7. Casos com Tratamento Especial

### #16 — DecisionProvider
Verificar a implementação existente em `scripts/v3/lib/OrchestrationDecisionProvider.ps1` e separar a entrega da interface funcional dos benchmarks futuros. Encerrar somente se a interface tiver seus critérios atendidos; caso contrário, reduzir a issue ao gap comprovado.

### #21 — Distribuição
Reproduzir no HEAD atual com ambiente V2 isolado. Fechar se as falhas históricas não persistirem e os testes pertinentes (`tests/distribution/run-distribution-tests.ps1`) estiverem verdes.

### #25 — ai-memory.ts legado
Não fechar antes de confirmar a origem da regeneração, eliminá-la e cumprir o período de observação definido pela issue (atualmente sete dias sem recorrência).

### #149 — Workflow Lockfiles
O PR #150 registrou problemas de startup do CI durante o piloto (`e216c5c`). Não promover enforcement nem adicionar lockfile à branch principal sem solucionar a incompatibilidade. Documentação entregue não significa rollout aprovado.

---

## 8. Contrato de Evidência

Cada conclusão de trabalho deve registrar:

- Issue e requisito.
- SHA inicial e SHA final.
- Arquivos afetados.
- Runtime/provider/capabilities efetivos.
- Testes executados.
- Resultados observados.
- Tipo de prova: fixture, harness ou runtime real.
- Limitações conhecidas.
- PR, commit ou documento resultante.
- Próxima ação necessária.

Estados recomendados para o relatório:
- `IMPLEMENTED`
- `HARNESS_PASS`
- `RUNTIME_REAL_PASS`
- `PARTIAL`
- `BLOCKED_PROVIDER`
- `BLOCKED_RUNTIME`
- `BLOCKED_UPSTREAM`
- `NOT_RUN`
- `CLOSED_COMPLETED`
- `CLOSED_DUPLICATE`
- `CLOSED_NOT_PLANNED`

---

## 9. Condição de Sucesso

O programa será considerado concluído com sucesso quando:

1. O caminho produtivo Planner → subagent → Kernel → continuação funcionar em OpenCode V2 real.
2. Execuções retomáveis preservarem estado e não duplicarem efeitos externos.
3. Dependências de GitHub puderem produzir continuação efetiva, não apenas notificação.
4. MCPs necessários forem utilizados seletivamente e com fallback seguro.
5. Configuração e permissões tiverem ownership inequívoco sob Agent Config e OpenCode V2.
6. O sistema detectar capacidades dinamicamente em vez de depender de patches hardcoded.
7. Os principais Golden Workflows estiverem validados e auditados.
8. Componentes redundantes tiverem sido eliminados ou justificados.
9. O backlog restante tiver responsáveis, dependências e próximos passos claros.
