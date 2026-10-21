# PLAN — Workflow Efficiency & Adaptive Model Routing (v0.2.0)

> **HEADER NORMATIVO: COMPANION PLAN PARA `WORKFLOW-EFFICIENCY-v0.2.0-SPEC.md`.**
> Plano de execução em fatias testáveis para implementar a rota direta, governança de evidências, tiers de modelos e integração Advisor/Jev.
> V2-only. V1 é `LEGACY_FROZEN`.

---

## 1. Estrutura de Decomposição do Trabalho (WBS)

### Fatia 1 — P0-A: Correção dos Testes e Certificação (Entregue)
- [x] Corrigir `detect-opencode-capabilities.ps1` separando `CLI_SURFACE_DETECTED` de `RUNTIME_OPERATIONAL_VERIFIED`.
- [x] Corrigir `opencode-v2-regression-gate.ps1` com testes operacionais reais de concorrência (`FileShare.None`) e isolamento do master (`protect-master.ps1`).
- [x] Corrigir `OrchestrationEvidenceFreshness.ps1` com validação fail-closed para campos obrigatórios (`head_sha`, `timestamp`).
- [x] Conectar `OrchestrationEvidenceFreshness.ps1` no caminho produtivo do Task Kernel (`Complete-OrchestrationTask`).

### Fatia 2 — P1: Workflow Adaptativo e Rota `DIRECT_VERIFIED` (Entregue)
- [x] Implementar a rota `DIRECT_VERIFIED` em `scripts/v3/lib/OrchestrationPreflight.ps1` e `scripts/v3/orchestration-preflight.ps1`.
- [x] Atualizar o gate `Test-OrchestrationDoneCompliance` para aprovar tarefas comprovadamente triviais e de baixo risco sem exigir workers (`ActualWorkerParticipation = 0`).
- [x] Garantir bloqueio fail-closed de tarefas não triviais que tentem bypass (`ORCHESTRATION_POLICY_BYPASS`).
- [x] Validar suíte completa de testes de preflight (63/63 aprovados).

### Fatia 3 — P2: Reuse-First Arquitetural (Em Andamento)
- [ ] Formalizar a Matriz de Reuso e Invalidação de Evidências (`docs/audits/REUSE-EVIDENCE-INVALIDATION-MATRIX-2026-10-21.md`).
- [ ] Especificar critérios de match exato por hash do Git, `ArtifactRef` e escopo antes de qualquer busca semântica.

### Fatia 4 — P3 & P4: Model Router vNext & Intelligent Advisor Escalation (Documentado)
- [x] Atualizar `MODEL-ROUTER-vNext-SPEC.md` com arquitetura de Planner estável (T2/T3) e Advisor sob demanda (T2/T3/T4).
- [x] Incorporar os 7 Sinais Objetivos de Escalonamento e o contrato estruturado de consulta.
- [x] Definir ADR de integração tríplice (Jev + Advisor + Router).
- [x] Definir os 8 Golden Workflows (GW-ADVISOR-01 a GW-ADVISOR-08).

### Fatia 5 — P5 & P6: Piloto Controlado e Rollout Seguro
- [ ] Executar benchmark comparativo antes/depois documentando métricas de tokens e custo.
- [ ] Atualizar issue-tracker com as referências cruzadas (#4, #60, #61, #99, #101, #106, #146).

---

## 2. Matriz de Rastreabilidade de Testes

| Componente | Arquivo de Teste | Status Local | Asserções |
|---|---|---|---|
| **Capability Doctor** | `scripts/runtime/detect-opencode-capabilities.tests.ps1` | `PASS` | 33 / 33 |
| **Evidence Freshness**| `scripts/v3/lib/OrchestrationEvidenceFreshness.tests.ps1` | `PASS` | 21 / 21 |
| **Regression Gate** | `scripts/v3/opencode-v2-regression-gate.tests.ps1` | `PASS` | 13 / 13 |
| **Orchestration Preflight** | `scripts/v3/orchestration-preflight.tests.ps1` | `PASS` | 63 / 63 |
| **Package Consistency** | `scripts/test-package-consistency.ps1` | `PASS` | 16 / 16 |

---

## 3. Plano de Rollout e Rollback

### Rollout em 3 Etapas
1. **Etapa I — Validação Hermética e Contratos (Atual):** Testes unitários e gates de regressão ativos e verdes no branch `feat/workflow-efficiency-adaptive-routing`.
2. **Etapa II — Piloto em Tarefas Triviais:** Aplicação da rota `DIRECT_VERIFIED` para tarefas de documentação, typos e ajustes cosméticos.
3. **Etapa III — Ativação Gradual do Advisor:** Disponibilização do `engineering-advisor` com cota máxima de 2 consultas por objetivo sob monitoramento de telemetria.

### Critério de Rollback
- Qualquer erro de validação de compliance no Kernel, falha em testes de regressão ou detecção de loop de subagent reverte imediatamente as configurações para o baseline estático da v0.1.0 sem necessidade de reconfiguração de banco ou serviços.
