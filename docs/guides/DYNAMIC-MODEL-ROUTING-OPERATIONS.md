# Guia Operacional — Dynamic Model Routing & Intelligent Advisory v1.1

**Arquivo canônico de política:** [`source/registry/model-routing-policy.json`](file:///source/registry/model-routing-policy.json)
**Biblioteca do Router:** [`scripts/v3/lib/OrchestrationModelRouter.ps1`](file:///scripts/v3/lib/OrchestrationModelRouter.ps1)
**Especificação canônica:** [`docs/specs/DYNAMIC-MODEL-ROUTING-v1.1-SPEC.md`](file:///docs/specs/DYNAMIC-MODEL-ROUTING-v1.1-SPEC.md)
**Plano de implementação:** [`docs/specs/DYNAMIC-MODEL-ROUTING-v1.1-PLAN.md`](file:///docs/specs/DYNAMIC-MODEL-ROUTING-v1.1-PLAN.md)

---

## 1. Visão Geral

O OpenCode Orchestration utiliza uma política de roteamento dinâmico e adaptativo para selecionar modelos com base em capacidade necessária, custo, risco, histórico de falhas e papel do agente.

A autoridade canônica de configuração reside em [`source/registry/model-routing-policy.json`](file:///source/registry/model-routing-policy.json), versão `1.1.0`. Todas as decisões tomadas pelo Model Router vinculam o SHA-256 (`policy_hash`) desta política e geram recibos estruturados no Kernel.

### Princípios Operacionais Fundamentais

1. **ADR-01 — Um único Model Router:** Toda seleção passa por [`scripts/v3/lib/OrchestrationModelRouter.ps1`](file:///scripts/v3/lib/OrchestrationModelRouter.ps1). Não crie seletores paralelos.
2. **ADR-02 — Providers Independentes:**
   - `opencode` (Console): Beam Free, DeepSeek V4.1 Flash Free.
   - `opencode-go`: Muse Spark 1.3 Contributor.
   - `openai`: GPT-6 Luna, GPT-6.1 Sol, GPT-6 Astra.
   - `jev`: Jev 1.13 Free (System One).
   - **Regra inviolável:** Modelos OpenAI (Luna, Sol, Astra) devem ser despachados estritamente pelo provider `openai`, nunca convertidos silenciosamente para `opencode` ou `opencode-go`.
3. **ADR-03 — Separação de Responsabilidades:** Configuração não executa; Router seleciona e restringe; OpenCode V2 executa nativamente; Kernel audita e emite `DONE`; Jev é estritamente consultivo.
4. **ADR-04 — Tiers não são Providers:** Um tier (T0..T4) representa um perfil de trabalho e capacidade exigida, não uma empresa ou cobrança fixa.
5. **ADR-05 — Estabilidade Metodológica:** Não altere contratos do Kernel ou metodologia incremental ao mudar modelos.

---

## 2. Procedimentos Operacionais

### Procedimento 1: Adicionar um novo modelo ao catálogo

Para registrar um novo modelo sem alterar código:

1. Abra [`source/registry/model-routing-policy.json`](file:///source/registry/model-routing-policy.json).
2. Na seção `"models"`, adicione o novo identificador lógico:
   ```json
   "novo-modelo": {
     "id": "novo-modelo",
     "provider": "openai",
     "model_id": "openai/novo-modelo-v1",
     "display_name": "Novo Modelo V1",
     "enabled": true,
     "tier_profiles": ["T3"],
     "eligible_roles": ["coder", "debugger", "reviewer"],
     "capabilities": ["code_generation", "tool_calling"],
     "priority": 2,
     "cost_profile": {
       "input_cost_per_m": 1.5,
       "output_cost_per_m": 6.0,
       "cost_ceiling_multiplier": 1.0
     },
     "context_limits": { "max_tokens": 128000 },
     "data_policy": { "zero_data_retention": true },
     "availability_status": "available",
     "last_verified_at": "2026-10-26T00:00:00Z",
     "fallback_candidates": ["luna"]
   }
   ```
3. Se o modelo pertencer a um novo provider, adicione o provider à seção `"providers"`.
4. Valide a integridade do pacote:
   ```powershell
   powershell -NoProfile -File scripts\test-package-consistency.ps1
   powershell -NoProfile -File tests\v3\OrchestrationDynamicModelRoutingV11.tests.ps1
   ```

---

### Procedimento 2: Substituir um modelo existente

Para substituir um modelo que foi descontinuado ou superado por uma versão mais recente:

1. No arquivo [`source/registry/model-routing-policy.json`](file:///source/registry/model-routing-policy.json), localize o objeto do modelo na seção `"models"`.
2. Atualize o `"model_id"`, `"display_name"` e `"last_verified_at"`.
3. Caso queira manter o ID lógico estável (exemplo: `luna` apontando para `gpt-6-luna-v2`), altere apenas `model_id`:
   ```json
   "luna": {
     "model_id": "openai/gpt-6-luna-20261026",
     "last_verified_at": "2026-10-26T12:00:00Z"
   }
   ```
4. Se o modelo antigo deve ser mantido como fallback, configure `"fallback_candidates"` no novo modelo.

---

### Procedimento 3: Mudar o provider de um modelo

Caso um modelo esteja disponível em um novo provider (ex: migração de endpoint ou troca de gateway):

1. Atualize a propriedade `"provider"` e o `"model_id"` correspondente no catálogo:
   ```json
   "provider": "novo-provider",
   "model_id": "novo-provider/modelo-especifico"
   ```
2. Certifique-se de que o novo provider possui bloco configurado em `"providers"` com seus headers, endpoint e tipo de autenticação.
3. **Atenção:** Nunca reatribua modelos Luna, Sol ou Astra para providers que não sejam `openai` sem uma atualização formal de arquitetura aprovada.

---

### Procedimento 4: Alterar prioridades dos tiers

As prioridades de seleção primária e secundária de cada tier são governadas na seção `"tiers"`:

```json
"tiers": {
  "T1": {
    "name": "Gratuito e Ultraleve",
    "primary": "beam",
    "fallback": null,
    "cost_ceiling_multiplier": 0.01
  },
  "T2": {
    "name": "Execucao Economica",
    "primary": "deepseek",
    "fallback": "muse",
    "cost_ceiling_multiplier": 0.10
  },
  "T3": {
    "name": "Raciocinio Avancado",
    "primary": "luna",
    "fallback": null,
    "cost_ceiling_multiplier": 1.00
  },
  "T4": {
    "name": "Raciocinio Critico",
    "primary": "sol",
    "exceptional": "astra",
    "cost_ceiling_multiplier": 8.00
  }
}
```

- Para alternar o modelo primário do T2 para Muse Spark:
  Altere `"primary": "muse"` e `"fallback": "deepseek"`.
- As alterações entram em vigor imediatamente após salvar o arquivo (o cache do Router recalcula automaticamente o `policy_hash`).

---

### Procedimento 5: Configurar o Planner (`build`)

O Planner coordena o objetivo geral e exige estabilidade contextual durante todo o ciclo:

1. Na seção `"planner"` da política:
   ```json
   "planner": {
     "primary_model": "luna",
     "stable_during_objective": true,
     "rotation_prohibited": true,
     "on_demand_advisor_enabled": true
   }
   ```
2. **Diretrizes de Operação:**
   - `primary_model`: Sempre deve apontar para modelo de alta estabilidade e capacidade de raciocínio intermediário (`luna` / GPT-6 Luna).
   - `stable_during_objective: true`: Proíbe rotação oportunista de modelo no meio de uma sessão de planejamento para não degradar a janela de contexto.
   - `rotation_prohibited: true`: Proíbe rebaixar o Planner para T2 ou T1.

---

### Procedimento 6: Configurar o Advisor (`engineering-advisor`)

O Advisor presta consultoria técnica sob demanda em impasses ou revisões de arquitetura:

1. Na seção `"advisor"` da política:
   ```json
   "advisor": {
     "default_model": "luna",
     "advanced_model": "sol",
     "exceptional_model": "astra",
     "caching_enabled": true
   }
   ```
2. **Níveis de Acionamento:**
   - **Consulta regular (análise de tradeoffs):** Executa com `luna` (Tier T3).
   - **Deadlock comprovado com 2+ falhas e risco elevado:** Escala para `sol` (Tier T4).
   - **Deadlock de concorrência/segurança crítica:** Pode escalar para `astra` mediante autorização de orçamento.

---

### Procedimento 7: Autorizar o uso excepcional de GPT-6 Astra

O modelo GPT-6 Astra (`openai/gpt-6-astra`) é classificado como **T4 Excepcional** e possui custo de 40x. Ele é bloqueado por padrão (*fail-closed*).

Para autorizar uma consulta com Astra:

#### Opção A: Autorização por Variável de Ambiente (sessão pontual)
Defina a variável no ambiente PowerShell antes de iniciar a sessão ou o script de orquestração:
```powershell
$env:OPENCODE_ASTRA_AUTHORIZED = "true"
```

#### Opção B: Autorização Explícita na Chamada do Router
Passe o parâmetro `-ProviderCostAuthorized $true` ao invocar a seleção ou dispatch:
```powershell
$decision = Resolve-OrchestrationModelSelection -AgentName 'architect' -Complexity 'high' -Risk 'critical' -FailureCount 2 -ProviderCostAuthorized $true
```

#### Opção C: Inclusão na Política Local (`models.jsonc`)
No arquivo local de operador (`models.jsonc`), configure:
```jsonc
{
  "frontier": "openai/gpt-6-astra",
  "provider_cost_authorized": true
}
```

> [!WARNING]
> Nunca comite `models.jsonc` no repositório. O arquivo está adicionado ao `.gitignore` e pertence exclusivamente ao operador local.

---

### Procedimento 8: Configurar o Jev 1.13 Free (System One)

O Jev participa exclusivamente em modo consultivo e analítico:

1. Na seção `"jev"` de [`source/registry/model-routing-policy.json`](file:///source/registry/model-routing-policy.json):
   ```json
   "jev": {
     "model_id": "jev-1.13-free",
     "endpoint": "https://opencode.ai/inference/systemone/v1/systemone",
     "service": "OpenCode / System One",
     "mode": "advisory",
     "execution_authority": false,
     "permission_grant_authority": false
   }
   ```
2. **Garantias de Segurança:**
   - O Jev **nunca** concede permissões de escrita ou execução de shell.
   - O Jev **nunca** decide modelos pagos.
   - O Jev **nunca** emite status `DONE` no Task Kernel.
   - Se o Jev estiver inacessível, o Planner continua o workflow por fallback gracioso sem interrupção.

---

### Procedimento 9: Investigar divergências entre modelos solicitados e efetivos

Após a execução de um worker nativo, a função `Test-ExecutedModelVerification` analisa a telemetria do OpenCode V2.

Os quatro status normativos são:

| Status de Auditoria | Descrição | Causa Típica | Ação Operacional |
|---|---|---|---|
| `EXACT_MATCH` | Modelo executado é idêntico ao solicitado. | Operação normal. | Nenhuma ação requerida. |
| `AUTHORIZED_FALLBACK` | Modelo executado difere do solicitado, mas corresponde a um fallback aprovado pelo Router. | Rate limit ou indisponibilidade temporária do provider primário. | Verificar se o provider primário restabeleceu a quota. |
| `UNAUTHORIZED_MISMATCH` | Modelo executado difere do solicitado sem autorização do Router, ou LLM executou em Tier T0 determinístico. | Desvio de configuração do OpenCode V2, override indevido, ou tentativa de bypass de política. | **Investigar imediatamente.** Recibo do Kernel marcará conformidade como rejeitada. |
| `PROOF_ABSENT` | Telemetria vazia ou ausência de prova de suporte a subagents nativos. | Subagent executou sem registrar identificador de modelo no log de sessão. | Configurar telemetria e verificar a versão do binário OpenCode V2 (`2.0.23`+). |

Comando de auditoria pós-execução para diagnóstico:
```powershell
. scripts\v3\lib\OrchestrationModelRouter.ps1
$sel = Resolve-OrchestrationModelSelection -AgentName 'coder'
$telemetria = @{ Model = 'opencode/deepseek-v4.1-flash-free' }
Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $telemetria -NativeModelOverrideProven $true
```

---

### Procedimento 10: Restaurar a configuração anterior (Rollback)

Se uma alteração no catálogo causar falhas ou indisponibilidade inesperada:

1. Restaure o arquivo canônico via Git:
   ```powershell
   git checkout HEAD -- source/registry/model-routing-policy.json
   ```
2. Se houver divergência no arquivo local do usuário (`models.jsonc`), restaure a partir do exemplo canônico:
   ```powershell
   Copy-Item models.example.jsonc models.jsonc -Force
   ```
3. Execute os testes para certificar restauração integral:
   ```powershell
   powershell -NoProfile -File scripts\test-package-consistency.ps1
   powershell -NoProfile -File tests\v3\OrchestrationDynamicModelRoutingV11.tests.ps1
   powershell -NoProfile -File scripts\v3\lib\OrchestrationModelRouter.tests.ps1
   ```

---

## 3. Matriz de Agentes e Modelos Canônicos

| Agente | Tier Padrão | Modelo Primário | Alternativa / Escalonamento | Provider |
|---|---|---|---|---|
| **Planner (`build`)** | T3 | GPT-6 Luna | Advisor sob demanda | `openai` |
| **Explorer** | T1 | Beam Free | DeepSeek V4.1 Flash Free | `opencode` |
| **Researcher** | T2 | DeepSeek V4.1 Flash Free | Muse Spark → GPT-6 Luna | `opencode` |
| **Coder** | T2 | DeepSeek V4.1 Flash Free | Muse Spark → GPT-6 Luna | `opencode` |
| **Tester (com LLM)** | T2 | DeepSeek V4.1 Flash Free | Muse Spark | `opencode` |
| **Tester (T0 deterministic)** | T0 | *Nenhum (código/AST)* | Proibido LLM | `none` |
| **Docs Manager** | T1 | Beam Free | DeepSeek V4.1 Flash Free | `opencode` |
| **Frontend Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **Backend Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **Database Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **AI Agent Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **Automation Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **Infra Engineer** | T2 | Muse Spark 1.3 Contributor | GPT-6 Luna | `opencode-go` |
| **Reviewer** | T3 | GPT-6 Luna | GPT-6.1 Sol *(downgrade T2 proibido)* | `openai` |
| **Debugger** | T3 | GPT-6 Luna | GPT-6.1 Sol | `openai` |
| **Architect** | T3 | GPT-6 Luna | GPT-6.1 Sol → Astra excepcional | `openai` |
| **Security Reviewer** | T3 | GPT-6 Luna / Sol | Astra excepcional *(downgrade T1/T2 proibido)* | `openai` |
| **Requirements Analyst** | T2 | DeepSeek V4.1 Flash Free | GPT-6 Luna | `opencode` |
| **Product Designer** | T2 | DeepSeek V4.1 Flash Free | GPT-6 Luna | `opencode` |
| **Skeptic** | T3 | GPT-6 Luna | GPT-6.1 Sol | `openai` |
| **Engineering Advisor** | T3 | GPT-6 Luna | GPT-6.1 Sol → Astra excepcional | `openai` |

---

## 4. Auditoria de Recibos no Kernel

Toda seleção de modelo despachada gera um recibo com a seguinte estrutura:

```json
{
  "stage": "model_routing",
  "agent": "coder",
  "tier": "T2",
  "catalog_model": "opencode/deepseek-v4.1-flash-free",
  "model_token": "MODEL_CHEAP",
  "provider_cost_authorized": false,
  "authorization_source": "STANDARD_CATALOG",
  "authorization_evidence": "catalog:default",
  "budget": "standard_tier_budget",
  "policy_version": "1.1.0",
  "policy_hash": "245a58695bf714670f6c44782468c36a04db4b9e2b371e74de084b35f95d7e68",
  "timestamp": "2026-10-26T22:00:00.0000000Z"
}
```

O Kernel valida este recibo no fechamento do objetivo. Inconsistências (como Tier T4 desprovido de autorização financeira ou incompatibilidade com a matriz de admissibilidade) resultam em recusa de fechamento (`POLICY_BYPASS_DETECTED`).
