# Inventário Arquitetural e Compatibilidade — Dynamic Model Routing v1.1

**Data:** 26/10/2026
**Fase:** Fase 0 — Baseline e inventário (Gate 0)
**Projeto:** Kusts/opencode-orchestration
**Baseline:** PR #158 (HEAD `f531845`, 6/6 jobs CI PASS no GitHub Actions run 40390828328)

---

## 1. Confirmação do PR #158 e Baseline Integrada

- **Estado e HEAD do PR #158:** Branch `feat/native-first-controlled-pilot`, commit `f531845`.
- **CI do PR #158:** 6/6 jobs aprovados (Linux capability collector, PS 5.1, PS 7, smoke OpenCode real, smoke OpenCode V2 real, V2 lane provisionada).
- **Review:** Security Review APPROVED, reconciliação de fallbacks formalizada.
- **Relação com esta branch:** Criada branch exclusiva `feat/dynamic-model-routing-v1.1` a partir de `f531845`. Nenhuma mutação anterior foi perdida ou corrompida.

---

## 2. Inventário de Componentes e Ciclo de Vida do Modelo

Abaixo mapeamos os 5 marcos do modelo em todo o pipeline da orquestração:

| Componente | Papel Arquitetural | Onde o Modelo é Recomendado | Configurado | Autorizado | Executado | Verificado |
|---|---|---|---|---|---|---|
| `OrchestrationModelRouter.ps1` | Seleção de Tiers, Fallback e Verificação | `Resolve-OrchestrationModelSelection` (baseado em risco/complexidade/falhas) | `Get-OrchestrationUserConfigCatalog` e `source/registry/model-routing-policy.json` | `Resolve-CatalogModel` (separa admissibilidade técnica de autorização de custo T4/Astra) | N/A (lib de decisão, não executa) | `Test-ExecutedModelVerification` (`EXACT_MATCH`, `AUTHORIZED_FALLBACK`, `UNAUTHORIZED_MISMATCH`, `PROOF_ABSENT`) |
| `OrchestrationPlannerLoop.ps1` | Loop de planejamento e coordenação | Recomenda modelo estável `openai/gpt-6-luna` para o Planner `build` | Consome seleção do Router para cada worker do turno | Valida se a tarefa exige worker ou T0/reuso | Delega via ferramenta nativa `subagent` do OpenCode V2 | Inspeciona recibos de execução e eventos do subagent |
| `OrchestrationNativeDispatch.ps1` | Bridge idempotente Native Worker Dispatch | Vincula modelo recomendado na `DispatchIntent` | Passa `selected_model_id` e `selected_provider` no envelope | Valida fence de concessão e idempotência | Executor invocado com `selected_model` nativo | Emite recibos isolados `pending` → `settled` com fingerprint |
| `OrchestrationAdvisorEscalation.ps1` | Escalonamento do Advisor sob demanda | Recomenda Luna (normal), Sol (avançado) ou Astra (excepcional) sob 7 sinais | Cache delimitado de consultas; tokens no Router | Exige autorização explícita de orçamento para T4/Astra | Invocação delimitada como `engineering-advisor` | Resposta estruturada `ConvertTo-StructuredAdvisoryOpinion` |
| `OrchestrationJevAdvisory.ps1` | Decisão consultiva Jev Free | Ferramentas `jev_check`, `jev_gate`, `jev_score`, `jev_decide` | `source/registry/jev-advisory-policy.json`, `JEV_BASE_URL`, `JEV_MODEL` | Nunca concede permissão nem autoriza custo | Chamada HTTP/REST segura via System One (`jev-1.13-free`) | Telemetria `advice_received`, `advice_evaluated`, `advice_accepted`, `advice_applied` |
| `models.example.jsonc` / `models.jsonc` | Configuração local do operador | Referências de compatibilidade legada (`planner`, `cheap`, `strong`) | Editado localmente pelo usuário (`~/.config/opencode/models.jsonc`) | Substitui defaults locais sem commit | Injetado no template compilado | Validado por `Get-OrchestrationUserConfigCatalog` |
| `templates/opencode.v2.json.tmpl` | Template nativo de configuração do OpenCode V2 | Agentes primários e subagents mapeados | Tokens `{{MODEL_PLANNER}}`, `{{MODEL_CHEAP}}`, `{{MODEL_STRONG}}` | Precedência estrita de permissões broad-first | Configuração de boot do agente | Checado no teste de consistência de pacote |
| Agent Config (externo) | Preferências globais | Preferências gerais do usuário | Arquivos de ambiente e flags | Subordinado à política de risco da Orquestração | Não executa diretamente | Validado por contratos de interop |

---

## 3. Matriz de Compatibilidade e Preservação de Contratos

1. **Tokens Legados (`MODEL_PLANNER`, `MODEL_CHEAP`, `MODEL_STRONG`, `MODEL_FRONTIER`):** Mantidos como pontes para templates e ferramentas existentes.
2. **Separação de Providers (ADR-02):**
   - `opencode`: Beam Free (`opencode/beam-free`), DeepSeek V4.1 Flash Free (`opencode/deepseek-v4.1-flash-free`).
   - `opencode-go`: Muse Spark 1.3 Contributor (`opencode-go/muse-spark-1.3-contributor`).
   - `openai`: GPT-6 Luna (`openai/gpt-6-luna`), GPT-6.1 Sol (`openai/gpt-6.1-sol`), GPT-6 Astra (`openai/gpt-6-astra`).
   - `jev`: Jev 1.13 Free (`jev-1.13-free`, System One).
3. **Invariantes Invioláveis:**
   - Modelos OpenAI nunca são roteados silenciosamente para `opencode` ou `opencode-go`.
   - Tier T0 nunca executa LLM.
   - Jev Free nunca concede permissões, não seleciona modelos pagos e nunca emite `DONE`.
   - T4/Astra requer autorização financeira explícita, nunca implícita por repetição de falhas.
   - Recibos pós-execução e verificação de modelo (`EXACT_MATCH`, `AUTHORIZED_FALLBACK`, `UNAUTHORIZED_MISMATCH`, `PROOF_ABSENT`) mantêm conformidade estrita.

**Conclusão do Gate 0:** Baseline aprovada, inventário mapeado e arquitetura alinhada sem duplicações.
