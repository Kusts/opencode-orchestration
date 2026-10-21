# OPENCODE ORCHESTRATION — RUNTIME CAPABILITY & NATIVE-FIRST AUDIT MATRIX

**Data-base:** 2026-10-21  
**Status:** ACTIVE AUDIT  
**Baseline Git:** Commit `2e9c744` (origin/master)  
**Referência:** `docs/specs/BACKLOG-CONSOLIDATION-NATIVE-FIRST-SPEC.md` e `docs/plans/NATIVE-FIRST-IMPLEMENTATION-2026-10-21.md`  
**Objetivo:** Mapeamento técnico detalhado de todos os 11 subsistemas locais versus capacidades nativas do OpenCode V2 para eliminação de redundâncias e adoção native-first.

---

## 1. Princípios de Decisão

- **KEEP:** O subsistema local provê garantias fundamentais de governança, integridade, fencing ou CAS que o host OpenCode V2 não provê por si só.
- **ADAPT:** O subsistema local deve ser ajustado para delegar a execução operacional à API nativa do host, retendo o contrato de validação e receipts.
- **REPLACE:** O componente local pode ser substituído inteiramente pela funcionalidade nativa do OpenCode V2 após equivalência comportamental comprovada.
- **REMOVE:** Código legado, duplicado ou que tenta reimplementar controle de processos já exercido pelo host.
- **DEFER (HOLD):** Capacidade depende de suporte de enforcement upstream ainda ausente no host OpenCode V2 (#69, #70).

---

## 2. Matriz dos 11 Subsistemas Técnicos

### 2.1 Subagents e Dispatch
- **Responsabilidade:** Delegação de tarefas a agentes especializados, controle de escopo e limites de execução.
- **Implementação Local:** `scripts/v3/native-dispatch-claim.ps1`, `scripts/v3/lib/OrchestrationNativeDispatch.ps1`, `plugins/g1-dispatch-admission/index.js`.
- **Caller Efetivo:** `scripts/v3/lib/OrchestrationAutonomousLoop.ps1`, `scripts/v3/objective-step.ps1`.
- **Estado Atual:** `HARNESS_PASS` (S1..S5 concluídos; teste real em sessão interativa V2 pendente).
- **Equivalente Nativo V2:** Subagents nativos do OpenCode V2 (`experimental.subagent_depth = 1`, tool `call_subagent`).
- **Capabilities Necessárias:** Invocação estruturada de subagentes com passagem de prompt e restrição de ferramentas por perfil.
- **Contrato de Compatibilidade:** O host despacha o agente; o plugin intercepta pré-execução para validar permissões; o script local emite o envelope de `claim` com recibo durável.
- **Risco / Duplicação:** Duplicação se o orquestrador tentar gerenciar o ciclo de vida do processo filho via subprocessos diretos em vez do host.
- **Decisão:** **ADAPT** (Manter geração de recibos canônicos e envelopes de claim; delegar o spawn e terminal estritamente ao mecanismo de subagente nativo do V2).

---

### 2.2 Sessões e Hierarquias Parent/Child
- **Responsabilidade:** Rastreamento da sessão do Planner e das sessões filhas criadas para os workers delegados.
- **Implementação Local:** `scripts/runtime/SessionBootstrapContext.ps1`, `scripts/v3/lib/OrchestrationSessionReconciler.ps1`.
- **Caller Efetivo:** Bootstrap de sessão, Task Kernel e reconciliador de retomada.
- **Estado Atual:** `PROVEN_LIVE` (contexto de bootstrap com hash determinístico e persistência auditada).
- **Equivalente Nativo V2:** Sessões nativas do OpenCode V2 (`opencode session list`, `opencode session view`, hierarquia de sessões filhas).
- **Capabilities Necessárias:** APIs de listagem, arquivamento e inspeção de status de sessões.
- **Contrato de Compatibilidade:** O Task/Goal Kernel mapeia `SessionId` nativo para `GoalId`/`TaskId`/`RunId` sem substituir o armazenamento de sessões do host.
- **Risco / Duplicação:** Manter bancos de dados próprios de histórico de chat quando o host já armazena as sessões.
- **Decisão:** **ADAPT** (Utilizar as APIs nativas de sessão para histórico e listagem; reter no Kernel exclusivamente os contratos de Run, Receipt e CAS de conclusão).

---

### 2.3 Lifecycle e Eventos do Host
- **Responsabilidade:** Detecção de início de turno, término de ferramentas, erros de execução e encerramento.
- **Implementação Local:** `plugins/g1-dispatch-admission/index.js` (hook `execute.before`, eventos de dispatch).
- **Caller Efetivo:** OpenCode runtime host via plugin SDK.
- **Estado Atual:** `HARNESS_PASS` (integração via plugin testada com fixture mock e 41 testes Node).
- **Equivalente Nativo V2:** Sistema de hooks e eventos do OpenCode V2 (`event.subscribe`, `execute.before`, `execute.after`).
- **Capabilities Necessárias:** Subscrição síncrona/assíncrona a eventos do ciclo de vida da execução.
- **Contrato de Compatibilidade:** Hook síncrono deny-only: caso a intenção de execução não satisfaça a política, abortar imediatamente fail-closed.
- **Risco / Duplicação:** Tentar inspecionar buffers de saída por polling quando eventos estruturados estão disponíveis.
- **Decisão:** **KEEP** (O plugin de admissão é o componente chave para integridade e contenção; deve permanecer estritamente deny-only).

---

### 2.4 Git Worktrees
- **Responsabilidade:** Isolamento de alterações de código entre múltiplos workers simultâneos ou entre branches experimentais.
- **Implementação Local:** `scripts/v3/lib/OrchestrationWorktree.ps1` (criação e remoção manual de worktrees via comandos git diretos).
- **Caller Efetivo:** Planner e workers coder/tester quando a flag `worktree_isolation` está ativa.
- **Estado Atual:** `PROVEN_LIVE` (flag ativada com lote de 2026-10-04; testes de isolamento com CAS verdes).
- **Equivalente Nativo V2:** Code Mode nativo com worktrees automáticos por tarefa.
- **Capabilities Necessárias:** Criação nativa de branches isoladas e merge seguro pelo host.
- **Contrato de Compatibilidade:** O host gerencia o diretório físico; a orquestração valida que nenhum commit seja feito diretamente na branch principal (`protect-master.ps1`).
- **Risco / Duplicação:** Conflitos de paths e locks órfãos se houver dois sistemas gerenciando os mesmos diretórios de worktree.
- **Decisão:** **ADAPT** (Aproveitar os worktrees gerenciados pelo host quando operando em Code Mode; reter a guarda local fail-closed contra mutação em branch protegida).

---

### 2.5 Terminal e PTY
- **Responsabilidade:** Execução de comandos no shell, captura de saída padrão/erro e tratamento de timeout.
- **Implementação Local:** `scripts/runtime/lib/SpikeProcess.ps1`, `scripts/runtime/lib/RuntimeJobObject.ps1`, watchdog de timeout.
- **Caller Efetivo:** Scripts de teste, runners de preflight e scripts de validação.
- **Estado Atual:** `PROVEN_LIVE` (Windows Job Objects reais provados; mitigação de processos zumbis entregue na P22/P26).
- **Equivalente Nativo V2:** PTY persistente nativo do OpenCode V2 com isolamento de terminal Windows.
- **Capabilities Necessárias:** Terminal streaming, PTY durável, cancelamento de processo por sinal nativo.
- **Contrato de Compatibilidade:** Comandos iniciados pelo agente no chat devem rodar no PTY do host; comandos de infraestrutura do orquestrador continuam usando subprocessos isolados PowerShell com Job Object.
- **Risco / Duplicação:** Manter dois wrappers de emulação de terminal.
- **Decisão:** **ADAPT** (Não substituir o Job Object interno de contenção da orquestração para scripts do orquestrador; adotar o PTY nativo do V2 para as tools interativas do worker).

---

### 2.6 Permissões e Governança
- **Responsabilidade:** Concessão e restrição de acesso a ferramentas, arquivos e comandos bash.
- **Implementação Local:** `docs/PERMISSIONS.md`, `source/agents/*.md`, templates `opencode.v2.json.tmpl`, projeções de grants em `OrchestrationNativeDispatchGrantProjection.ps1`.
- **Caller Efetivo:** Instalador (`scripts/runtime/new-opencode-profile.ps1`), renderizador e plugin de admissão.
- **Estado Atual:** `PROVEN_LIVE` (ordem broad-first/deny-* com allows estreitos validada em 16/16 checks de consistência).
- **Equivalente Nativo V2:** Configuração declarativa `permissions` com regras `allow`, `ask`, `deny`.
- **Capabilities Necessárias:** Avaliação estrita de permissões pelo host antes de invocar a tool.
- **Contrato de Compatibilidade:** A autoridade canônica das regras declarativas pertence ao `Agent Config`; a Orquestração consome e projeta sem criar uma segunda autoridade.
- **Risco / Duplicação:** Divergência entre arquivos locais e configuração do host.
- **Decisão:** **KEEP** (Manter como autoridade única sob Agent Config; modo host-enforced permanece em HOLD para a issue #69).

---

### 2.7 Model Context Protocol (MCPs)
- **Responsabilidade:** Extensão de ferramentas (Jev, AI Memory, REA, Context7, Docker, Asaas).
- **Implementação Local:** `scripts/v3/lib/CapabilityMcpRouter.ps1`, `scripts/v3/lib/OrchestrationAiMemoryRemote.ps1`, `scripts/v3/lib/OrchestrationJevAdvisory.ps1`.
- **Caller Efetivo:** Planner, subagents e ferramentas especializadas.
- **Estado Atual:** `PROVEN_LIVE` para AI Memory (HTTPS autenticado com TLS 1.3 provado) e Jev Advisory (consultivo com logging); router avançado mantido OFF por política.
- **Equivalente Nativo V2:** Suporte nativo a servidores MCP configurados no `opencode.json` / `agents.json`.
- **Capabilities Necessárias:** Descoberta dinâmica de tools, passagem de parâmetros tipados e isolamento por sessão.
- **Contrato de Compatibilidade:** O host conecta aos MCPs; a Orquestração decide estrategicamente quais ferramentas acionar e aplica fallbacks seguros em caso de falha.
- **Risco / Duplicação:** Construir um servidor gateway proxy MCP intermediário redundante (conforme rejeitado na ADR #125).
- **Decisão:** **ADAPT** (Utilizar os transports nativos V2; manter apenas a lógica de decisão estratégica, timeouts e sanitização de dados no Planner).

---

### 2.8 Skills
- **Responsabilidade:** Conjuntos reutilizáveis de instruções operacionais e scripts auxiliares para agentes.
- **Implementação Local:** Diretório `skills/` (`skills-core`, `hybrid-development`), `scripts/v3/skill-bridge.ps1`.
- **Caller Efetivo:** Workers e subagents quando acionados com skills específicas.
- **Estado Atual:** `PROVEN_LIVE` (5 skills com `SKILL.md` verificadas e validadas no package consistency).
- **Equivalente Nativo V2:** Suporte nativo a skills/plugins em diretórios convencionados pelo OpenCode V2.
- **Capabilities Necessárias:** Descoberta automática de frontmatter de skills pelo host.
- **Contrato de Compatibilidade:** Skills fornecem conhecimento e instruções reutilizáveis sem ampliar privilégios concedidos pela política.
- **Risco / Duplicação:** Duplicação de registry de discovery (rejeitada na ADR #56 e #64).
- **Decisão:** **KEEP** (Preservar o catálogo de skills; descoberta de skills delegada ao host sem segundo catálogo concorrente).

---

### 2.9 SDK e Plugin
- **Responsabilidade:** Interceptação em tempo real de ações dos agentes para validação de segurança e enriquecimento de contexto.
- **Implementação Local:** `plugins/g1-dispatch-admission/` (bundle compilado + sidecar SHA-256).
- **Caller Efetivo:** Runtime do OpenCode V2 durante a inicialização do host.
- **Estado Atual:** `PROVEN_LIVE` (bundle autocontido, sem dependências externas runtime, verificado em 16/16 checks).
- **Equivalente Nativo V2:** Sistema de plugins JavaScript/TypeScript do OpenCode V2.
- **Capabilities Necessárias:** APIs de extensão do runtime V2 com integridade via sidecar.
- **Contrato de Compatibilidade:** Fail-closed: se o plugin não carregar ou houver divergência de hash, a execução de subagentes não autorizados é bloqueada.
- **Risco / Duplicação:** Quebra de contrato por alterações no SDK em versões 2.1.x (#138).
- **Decisão:** **KEEP** (Componente essencial da orquestração; manter alinhado às APIs do host).

---

### 2.10 Replay e Compactação de Contexto
- **Responsabilidade:** Continuidade de raciocínio em tarefas longas sem estouro de contexto ou perda de decisões anteriores.
- **Implementação Local:** `scripts/v3/lib/OrchestrationGoalCheckpoint.ps1`, checkpoints canônicos de objetivo e receipts.
- **Caller Efetivo:** `OrchestrationAutonomousLoop.ps1` a cada transição de passo.
- **Estado Atual:** `PROVEN_LIVE` (checkpoints transacionais gravados em disco e verificados no loop).
- **Equivalente Nativo V2:** Compactação automática de mensagens e mecanismo de replay do OpenCode V2.1+.
- **Capabilities Necessárias:** Preservação de mensagens de sistema e tool results em janelas compactadas.
- **Contrato de Compatibilidade:** A compactação do host reduz o consumo de tokens na sessão do LLM; os checkpoints do Kernel preservam a integridade transacional de estado.
- **Risco / Duplicação:** Duplicação se a orquestração tentar gerenciar janelas de contexto token a token no lugar do host.
- **Decisão:** **ADAPT** (Permitir a compactação nativa do host no histórico de conversa; o Kernel retém de forma independente os checkpoints e receipts estruturados).

---

### 2.11 Watchdog e Controle de Processos
- **Responsabilidade:** Prevenção de execução infinita, detecção de loops sem progresso e encerramento determinístico de processos descontrolados.
- **Implementação Local:** `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1`, `RuntimeJobObject.ps1`, `scripts/runtime/detect-opencode-runtime.ps1`.
- **Caller Efetivo:** Kernel e Autonomous Loop durante execuções não triviais.
- **Estado Atual:** `PROVEN_LIVE` (ativado pelo operador em 2026-10-04, 134/134 testes de watchdog verdes, binding seguro por criação e ticks).
- **Equivalente Nativo V2:** Timeouts nativos de tool calls e cancelamento de processos via UI/API do host.
- **Capabilities Necessárias:** Encerramento limpo de árvores de processos no Windows.
- **Contrato de Compatibilidade:** O host controla o timeout da chamada da ferramenta; o Watchdog orquestrador atua como backstop de segurança no nível do objetivo e das tarefas do Kernel.
- **Risco / Duplicação:** Dois mecanismos tentando encerrar o mesmo PID simultaneamente com sinais concorrentes.
- **Decisão:** **KEEP** (O watchdog local com Job Objects é indispensável como backstop fail-closed contra travamentos que o host não consiga interromper).

---

## 3. Resumo das Decisões de Arquitetura

| Subsistema | Decisão | Racional Resumido |
|---|---|---|
| **Subagents e Dispatch** | **ADAPT** | Delegar spawn ao host V2; reter contratos de claim e receipts canônicos |
| **Sessões e Hierarquia** | **ADAPT** | Usar APIs nativas de sessão para histórico; reter Runs e CAS no Kernel |
| **Lifecycle e Eventos** | **KEEP** | Plugin deny-only essencial para contenção e integridade |
| **Git Worktrees** | **ADAPT** | Reutilizar worktrees do Code Mode; preservar guarda em branch protegida |
| **Terminal e PTY** | **ADAPT** | Adotar PTY nativo para tools interativas; reter Job Objects para infra |
| **Permissões** | **KEEP** | Autoridade única sob Agent Config; compatibilidade estrita |
| **MCPs** | **ADAPT** | Transports nativos do host; decisão estratégica e timeouts locais |
| **Skills** | **KEEP** | Catálogo unificado sem segundo registry de discovery concorrente |
| **SDK / Plugin** | **KEEP** | Extensão nativa V2 com sidecar SHA-256 e fail-closed |
| **Replay / Compactação**| **ADAPT** | Compactação de mensagens no host; transações e recibos no Kernel |
| **Watchdog / Processos**| **KEEP** | Backstop de segurança essencial no nível do objetivo |
