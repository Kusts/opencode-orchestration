# OPENCODE ORCHESTRATION — BACKLOG REFINEMENT & CONSOLIDATION PLAN

**Data:** 2026-10-21  
**Status:** APPROVED & ACTIVE  
**Referência:** `docs/specs/BACKLOG-CONSOLIDATION-NATIVE-FIRST-SPEC.md`  
**Estratégia:** Baseline → Inventário → Correção → Teste → Integração → Simplificação → Fechamento  

---

## 1. Visão Geral e Estado Atual do Repositório

A baseline no commit `2e9c744` (origin/master) consolida:
1. **F1 Slices (S1–S5)**:
   - S1: Bridge de claim nativo + hook deny-only (`native-dispatch-claim.ps1`, `g1-dispatch-admission`) via PR #131.
   - S2: SETTLE canônico, política opt-in e prova durável via PR #132.
   - S3a: Settled continuation via PR #133.
   - S4: Settled recovery limitada com atribuição durável via PR #134 e PR #135.
   - S5: Debugger validator-shell e projeção de grants via PR #134 e PR #144.
2. **Harness Funcional e Fechamento**:
   - S6 wiring + reconcile + O5 link + watchdog fixture (`HARNESS_PASS` only) via PR #136.
3. **Compilação de ADRs e SPECs (PR #150)**:
   - 16 SPECs e ADRs para issues de avaliação, pesquisa e modelos (#43, #55, #56, #57, #64, #78, #79, #81, #99, #102, #111, #124, #125, #142, #147, #149).
   - Diagnóstico do piloto actions.lock (#149) documentado, sem enforcement na branch principal devido a startup_failure no CI.

O repositório possui exatamente **74 issues abertas** no GitHub, todas mapeadas nesta refinaria.

---

## 2. Metodologia de Execução por Etapas

### Etapa A — Reconciliação do Backlog e Matriz de Triagem
1. Atualizar e manter a matriz de triagem em `docs/audits/ISSUE-TRIAGE-MATRIX-2026-10-21.md`.
2. Registrar candidatos a consolidação imediata e fechamento condicionado.
3. Transferir formalmente critérios de aceite e requisitos úteis antes de fechar qualquer issue.
4. Manter estrito rastreamento de issues em HOLD e Upstream (#69, #70).

### Etapa B — Compatibilidade e Native-First
**Issues Prioritárias:** #137 (Epic), #50, #101, #138.
1. Produzir o inventário técnico detalhado dos 11 subsistemas em `docs/audits/RUNTIME-CAPABILITY-MATRIX-2026-10-21.md`.
2. Aprimorar a detecção dinâmica de capacidades no Compatibility Doctor V2:
   - Identidade e versão do runtime efetivo.
   - Presença e integridade de SDK/plugins.
   - Suporte e comportamento de permissões nativas.
   - Fallback determinístico sem dependência de regras rígidas por patch.
3. Auditar contratos de replay, provider metadata e compactação da versão OpenCode 2.1.x sem breaking changes.

### Etapa C — Fechamento do Fluxo Produtivo em Sessão Real
**Issues Prioritárias:** #51 (Crítica), #8, #9, #10.
1. Reconciliar `OrchestrationNativeDispatch`, `OrchestrationAutonomousLoop`, `OrchestrationProductiveActivation`, `OrchestrationTaskKernel` e `OrchestrationGoalKernel`.
2. Validar o ciclo produtivo completo:
   `Planner -> preflight -> worker nativo -> resultado correlacionado -> SETTLE canônico -> verificação -> continuação autônoma -> OBJECTIVE_DONE`.
3. Cobrir recuperação de interrupções, receipts idempotentes e liveness.
4. Resolver as pernas pendentes de runtime do cenário `RR-E2E-21`.

### Etapa D — Continuação Autônoma do GitHub
**Issues Prioritárias:** #86, #106, #1.
1. Separar formalmente os 3 contratos:
   - **OBSERVE:** Detecção durável de CI, PRs e checks com rate-limiting seguro.
   - **WAIT:** Registro persistente de pendência, lease, deadline e cursor.
   - **WAKE / RESUME:** Gatilho de retomada efetiva sem dependência de comando manual do usuário.
2. Evitar loop infinito do modelo LLM para polling; utilizar agendamento/scheduler ou timers duráveis.
3. Exigir refresh de evidências obsoletas antes de transições consequenciais (#106).

### Etapa E — MCPs, Skills e Decisões Auxiliares
**Issues Prioritárias:** #116, #61, #63, #114, #60.
1. Descoberta dinâmica de integrações presentes no ambiente (Jev, AI Memory, REA, Context7, Playwright, Chrome DevTools, Docker, Asaas).
2. Diferenciação rigorosa: `INSTALLED -> CONFIGURED -> DISCOVERED -> REACHABLE -> CALLED -> WORKING`.
3. Integração do Advisor (reutilizando `engineering-advisor`, `debugger` e `architect`) para situações de impasse real, mantendo Planner como decisor e Kernel como validador.

### Etapa F — Simplificação e Eliminação de Código Redundante
**Issues Prioritárias:** #139, #140, #143.
1. Comparar PTY persistente Windows e lifecycle nativo com watchdog local, preservando apenas garantias de isolamento não supridas pelo host.
2. Reutilizar ciclo de vida de worktrees nativos do Code Mode, garantindo que o Kernel retenha CAS, fencing e proteção de conflitos.
3. Adotar listagem e arquivamento de sessões nativas nos Agent Teams, preservando entidades próprias de Run e Receipt.

### Etapa G — Golden Workflows e Prova Ponta a Ponta
**Issues Prioritárias:** #30, #4, #6.
1. Executar a matriz mínima de validação:
   - `GW-TRIVIAL`: Planner → 1 worker → validação → DONE.
   - `GW-MULTI`: Planner → coder → tester → reviewer → próxima etapa.
   - `GW-RECOVERY`: Interrupção de sessão/processo → reconciliação → retomada.
   - `GW-GITHUB`: PR → CI → await → wake → retomada.
   - `GW-MCP`: Seleção de ferramenta → chamada real → resposta → continuação.
   - `GW-ADVISORY`: Impasse → Advisor → decisão consultiva → ação.
   - `GW-NATIVE`: Uso de sessões/worktree/PTY nativos sem perda de autoridade.
2. Coletar métricas operacionais: Success-to-DONE, False-DONE rate, Cost-to-DONE, Time-to-DONE, contagem de retries e intervenções humanas.

### Etapa H — Higienização e Fechamento Contínuo
1. Aplicar regras estritas de fechamento com comprovação documental e de testes.
2. Fechar duplicações transferindo requisitos para a issue mãe.
3. Descartar formalmente pesquisas inviáveis como `NOT_PLANNED`.
4. Manter backlog futuro organizado com critérios de reativação claros.

---

## 3. Comandos de Validação e Regressão

Durante o ciclo de desenvolvimento:
```powershell
# 1. Checagem de integridade e consistência estática de templates, agentes e configs
powershell -NoProfile -File scripts\test-package-consistency.ps1

# 2. Testes unitários direcionados por componente alterado
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name <NomeDaSuite>

# 3. Testes de distribuição e compatibilidade de empacotamento
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1
```

A aprovação exige conformidade com as regras de preflight, participation compliance e contratos de evidência.
