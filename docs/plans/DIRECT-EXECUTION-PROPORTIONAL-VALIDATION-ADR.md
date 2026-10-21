# ADR — Execução Direta (`DIRECT_VERIFIED`) e Validação Proporcional ao Risco

**Status:** Aprovado / Implementado  
**Data:** 2026-10-21  
**Decisores:** Antigravity / OpenCode Orchestration Team  
**Contexto Técnico:** Universal Autonomous Orchestration v0.1.0 / v0.2.0, Issue #4, Issue #48, PR #151  

---

## 1. Contexto e Problema

No modelo arquitetural anterior (v0.1.0), todas as tarefas — independentemente de sua simplicidade ou impacto — eram obrigadas a despachar subagents:
- Até para renomear uma variável ou corrigir um typo em documentação, o Preflight impunha a decisão `SINGLE_WORKER`, exigindo o spawn de um agente secundário via tool nativa `subagent` (`ActualWorkerParticipation > 0`).
- Caso o Planner realizasse a alteração direta e chamasse o gate de conclusão sem despachar workers, a função `Test-OrchestrationDoneCompliance` retornava imediatamente `ORCHESTRATION_POLICY_BYPASS`, bloqueando o `DONE`.
- Essa imposição gerava um desperdício contínuo de 3.500 a 7.000 tokens de prompt de sistema, leitura repetida de diretrizes, latência de 15 a 45 segundos e custos desnecessários em tarefas simples, localizadas e de baixo risco.

## 2. Decisão Arquitetural

Projetou-se e implementou-se a rota **`DIRECT_VERIFIED`**, permitindo que o Planner (`build`) execute diretamente tarefas triviais sem overhead de subagents, mantendo rigoroso controle de conformidade e segurança:

1. **Condições Estritas de Admissibilidade:**
   - `TaskClass` deve ser categoricamente `trivial`.
   - `Risk` deve ser categoricamente `low`.
   - `ReadWrite` restrito ou mutação puramente localizada e reversível (sem mutações destrutivas ou migrações).
   - Ausência absoluta de exclusões rígidas (`hard_exclusions`: zero toques em credenciais, tokens, autenticação, branch master direta, permissões ou control plane).
   - Escopo delimitado (no máximo 1 domínio secundário).

2. **Contrato de Preflight:**
   - Preflight emite:
     - `orchestration_decision`: `DIRECT_VERIFIED`
     - `task_class`: `trivial`
     - `direct_reason`: `DIRECT_VERIFIED_LOW_RISK_LOCALIZED` (ou correlato `DIRECT_VERIFIED_*`)
     - `selected_agents`: `@()` (nenhum subagent alocado)
     - `bypass_verdict`: `OK`
     - `post_execution_check`: `'Test-OrchestrationDoneCompliance -TaskClass trivial -Decision DIRECT_VERIFIED -ExecutionShape DIRECT_VERIFIED -DirectReason DIRECT_VERIFIED_LOW_RISK_LOCALIZED'`

3. **Governança no Gate de DONE (`Test-OrchestrationDoneCompliance`):**
   - Tarefas com `Decision == 'DIRECT_VERIFIED'` e `ExecutionShape == 'DIRECT_VERIFIED'` acompanhadas de `DirectReason` prefixado por `DIRECT_VERIFIED_*` são aprovadas como `COMPLIANT` mesmo com `ActualWorkerParticipation == 0`.
   - Tokens legados (`DIRECT_TRIVIAL_LOCALIZED`, `DIRECT_CODE_MUTATION`) continuam rejeitados como `NON_COMPLIANT_DEPRECATED_DIRECT` (fail-closed).
   - **Prevenção Inviolável de Bypass:** Tarefas `non_trivial` que tentem utilizar `DIRECT_VERIFIED` com zero workers são sumariamente rejeitadas com `ORCHESTRATION_POLICY_BYPASS`.

4. **Validação Proporcional ao Risco:**
   - Alinhamento com a política declarativa de validação (`source/registry/validation-policy.json`):
     - **Nível L0 / L1:** Tarefas triviais de baixo risco dispensam o pipeline ritual de 3 agentes (`coder -> tester -> reviewer`). A auto-validação pelo Planner e a verificação determinística de testes são suficientes para emissão de evidência válida.
     - **Nível L2 / L3:** Tarefas normais e de alto risco continuam exigindo obrigatoriamente verificação independente por `tester`, `reviewer` e `security-reviewer`.

---

## 3. Consequências e Benefícios

### Positivas
- **Economia Drástica de Tokens:** Eliminação de 3.500 a 7.000 tokens de overhead por turno trivial.
- **Redução de Latência:** Tarefas simples são concluídas em segundos no próprio fluxo do Planner, sem esperas de inicialização de subprocesso de subagent.
- **Eliminação de Falsos Rituais:** Fim do pipeline burocrático de revisão formal para alterações óbvias e cosméticas.
- **Segurança Fail-Closed Preservada:** Tarefas com risco médio/alto, segredos ou escopo amplo continuam impossibilitadas de utilizar a via direta.

### Neutras / Negativas
- Exige que o Planner classifique com precisão o risco e a classe da tarefa antes da execução.
- O Kernel continua exigindo evidência válida de verificação (`all-evidence-fresh` com `head_sha` coincidente) antes de permitir a transição para `DONE`.
