# OPENCODE ORCHESTRATION — NATIVE-FIRST IMPLEMENTATION PLAN

**Data:** 2026-10-21  
**Status:** APPROVED & ACTIVE  
**Referência:** `docs/specs/BACKLOG-CONSOLIDATION-NATIVE-FIRST-SPEC.md` e `docs/plans/BACKLOG-REFINEMENT-2026-10-21.md`  
**Escopo:** Implementação técnica native-first, compatibilidade adaptativa com OpenCode V2 e ciclo de autoreview  

---

## 1. Princípios de Execução e Autonomia

1. **Autoreview Obrigatório:** Toda implementação segue o ciclo de qualidade:
   `Coder -> Tester -> Reviewer` (+ `Security-Reviewer` para permissões, auth, external boundaries).
2. **Menor Mudança Correta:** Evitar refatorações amplas sem teste prévio; diagnósticos devem preceder qualquer escrita.
3. **Sem Duplicação de Autoridade:** OpenCode V2 governa a execução nativa e tools; Task/Goal Kernel governa o ciclo de vida do objetivo; Agent Config governa as configurações e perfis globais declarativos.
4. **Evidência Obrigatória:** Nenhum claim de conclusão sem teste correspondente (`HARNESS_PASS` ou `RUNTIME_REAL_PASS`).

---

## 2. Detalhamento das Fases de Implementação

### Fase 1 — Inventário Native-First e Compatibilidade V2
**Issues:** #137, #50, #101, #138

#### 1.1 Inventário Técnico
Mapear em `docs/audits/RUNTIME-CAPABILITY-MATRIX-2026-10-21.md` cada um dos 11 subsistemas:
- Subagents e dispatch.
- Sessões e hierarquias parent/child.
- Lifecycle e eventos do host.
- Worktrees do Code Mode.
- Terminal e PTY.
- Permissões nativas (allow/ask/deny).
- MCPs e Skills.
- SDK/plugin.
- Replay e compactação de contexto.
- Watchdog e controle de processos.
- Metadados de modelos e providers.

#### 1.2 Compatibility Doctor V2 Aprimorado
Aprimorar `scripts/v3/lib/OrchestrationCapabilityDoctor.ps1` para:
- Detectar runtime ativo (versão, caminho, executável exato).
- Validar contratos de API disponíveis sem hardcoding cego por número de versão.
- Fornecer relatório estruturado: `CAPABILITY_STATUS { SUPPORTED, AMBIGUOUS, UNSUPPORTED, DEGRADED }`.
- Integrar com fallbacks determinísticos quando a capacidade nativa estiver ausente ou degradada.

#### 1.3 Suporte Adaptativo OpenCode 2.1.x
- Compatibilidade de formatos de tool call e tool result no plugin `g1-dispatch-admission`.
- Preservação de contexto e idempotência em eventos de replay e reconexão.
- Adaptação a rate-limiting do host sem gerar falso DONE ou falso abort.

---

### Fase 2 — Fechamento do Fluxo Produtivo em Sessão Real
**Issues:** #51, #8, #9, #10

#### 2.1 Reconciliação dos Componentes Existentes
- Integrar o bridge de claim (`scripts/v3/native-dispatch-claim.ps1`) com o loop autônomo (`scripts/v3/lib/OrchestrationAutonomousLoop.ps1`).
- Garantir que o `OrchestrationNativeDispatch` gere receipts duráveis com hashing canônico.
- Assegurar que o `OrchestrationProductiveActivation` promova o próximo passo sem intervenção do usuário.

#### 2.2 Invariantes de Liveness e Recuperação
- Cobrir timeout de workers com registro de causa typed (`TASK_TIMEOUT`, `NO_PROGRESS`, `HOST_KILLED`).
- Impedir que receipts duplicados gerem efeitos colaterais repetidos.
- Suportar cancelamento gracioso pelo Planner preservando integridade das transações do Kernel.
- Resolver os blockers identificados na análise do cenário `RR-E2E-21`.

---

### Fase 3 — Continuação Autônoma do GitHub
**Issues:** #86, #106, #1

#### 3.1 Contratos Desacoplados
- **OBSERVE (`scripts/v3/github-watch.ps1`):** Coleta periódica de status de CI, checks de PR e revisões sem chamadas excessivas.
- **WAIT (`scripts/v3/github-await.ps1`):** Persistência durável da condição esperada, identificador do PR, commit SHA e lease.
- **WAKE / RESUME (`scripts/v3/github-resume-reconcile.ps1`):** Despacho da continuação autônoma quando a condição for satisfeita.

#### 3.2 Refresh de Evidências Obsoletas (#106)
- Validar se artefatos de teste e evidências coletadas continuam válidos antes de avançar de fase ou declarar DONE.
- Re-execução automática de verificação se commits novos foram submetidos durante a espera.

---

### Fase 4 — Ownership de Configuração e Permissões
**Issues:** #141, #19 (referência #69/#70)

#### 4.1 Fronteiras Inequívocas
- `Agent Config` possui a autoridade das políticas globais, regras do usuário e perfis declarativos.
- A Orquestração gera apenas projeções temporárias e leases específicas para o escopo do objetivo.
- Permissões denegadas pelo host (`deny`) são invioláveis.
- Separação rigorosa entre regras advisory e host-enforced.

---

### Fase 5 — MCPs, Skills e Decisões Auxiliares
**Issues:** #116, #61, #63, #114, #60

#### 5.1 Descoberta Dinâmica de Integrações
- Descoberta seletiva de MCPs instalados sem dependência obrigatória de ambiente fechado.
- Fallback determinístico para execução direta quando ferramentas externas não estiverem acessíveis.

#### 5.2 Papel Consultivo do Advisor
- Acionamento do `engineering-advisor`, `debugger` ou `architect` apenas sob impasse ou falha consecutiva.
- Sugestões consultivas são traduzidas em hipóteses testáveis pelo Planner antes da aplicação.

---

### Fase 6 — Simplificação e Eliminação de Código Redundante
**Issues:** #139, #140, #143

#### 6.1 Adoção de PTY e Sessões Nativas
- Avaliar a redução de código local no watchdog onde o OpenCode V2 já provê isolamento de terminal e cancelamento gracioso.
- Reutilizar APIs de sessões para listagem e histórico, mantendo Task/Goal Kernel como autoridade do estado de orquestração.

#### 6.2 Worktrees do Code Mode
- Delegar a criação de worktrees para o host quando suportado, retendo o Kernel para resolução de conflitos e validação de gates.

---

### Fase 7 — Golden Workflows e Validação Ponta a Ponta
**Issues:** #30, #4, #6

#### 7.1 Execução da Matriz Canônica
- `GW-TRIVIAL`: 1 tarefa direta via cheap worker com verificação canônica.
- `GW-MULTI`: Coordenação padrão coder → tester → reviewer.
- `GW-RECOVERY`: Recuperação de worker interrompido com idempotência comprovada.
- `GW-GITHUB`: Observação de PR/CI com retomada automática autorizada.
- `GW-MCP`: Seleção dinâmica de tool externa com fallback gracioso.
- `GW-ADVISORY`: Resolução de impasse com Advisor.
- `GW-NATIVE`: Execução via APIs nativas V2 com garantias do Kernel mantidas.

---

### Fase 8 — Fechamento Contínuo e Higienização do Backlog
- Auditoria contínua das 74 issues contra a matriz em `docs/audits/ISSUE-TRIAGE-MATRIX-2026-10-21.md`.
- Execução de encerramentos justificados (`COMPLETED`, `DUPLICATE`, `NOT_PLANNED`) com registro transparente.
- Publicação de evidências rastreáveis a cada entrega.
