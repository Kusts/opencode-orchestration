# SPEC — Dynamic Model Routing & Intelligent Advisory v1.1

**Projeto:** Kusts/opencode-orchestration
**Status:** APPROVED FOR IMPLEMENTATION
**Data:** 26/10/2026
**Runtime:** OpenCode V2
**Baseline:** Native-First / Workflow Efficiency — PRs #157 e #158
**Escopo:** Model Router, catálogo de modelos, Native Dispatch, Planner, Advisor e Jev Free

---

## 1. Objetivo

Implementar uma política de roteamento configurável e adaptativa para os agentes do OpenCode Orchestration.

O sistema deverá selecionar modelos considerando capacidade necessária, custo, risco, função do agente, disponibilidade e histórico de execução.

A seleção deverá ser aplicada ao runtime nativo do OpenCode V2 e verificada após a execução.

**Princípio central:** modelos e providers são substituíveis; os contratos da Orquestração permanecem estáveis.

### 1.1 Resultados esperados

1. Catálogo versionado de modelos e providers.
2. Política T0–T4 configurável.
3. Seleção específica por papel e tarefa.
4. Fallback autorizado entre modelos e providers.
5. Planner estável utilizando GPT-6 Luna.
6. Advisor com Luna, Sol e Astra sob demanda.
7. Jev 1.13 Free integrado ao processo de decisão.
8. Verificação do modelo efetivamente executado.
9. Telemetria de qualidade, custo e eficiência.
10. Alterações futuras de modelos sem refatorações.

## 2. Decisões arquiteturais

### ADR-01 — Um único Model Router

Evoluir o componente existente:

`scripts/v3/lib/OrchestrationModelRouter.ps1`

Não criar outro mecanismo de roteamento.

### ADR-02 — Providers independentes

A configuração deverá reconhecer separadamente:

| Provider | Modelos iniciais |
|---|---|
| OpenCode Console (`opencode`) | DeepSeek V4.1 Flash Free |
| OpenCode Go (`opencode-go`) | Muse Spark 1.3 Contributor, Iceman Contributor Free |
| OpenAI (`openai`) | GPT-6 Luna, GPT-6.1 Sol, GPT-6 Astra |
| Jev / System One | Jev 1.13 Free |

**Luna, Sol e Astra devem ser executados pelo provider `openai`, nunca redirecionados silenciosamente para `opencode` ou `opencode-go`.**

A disponibilidade, autenticação, cobrança e os limites devem ser verificados individualmente por provider.

### ADR-03 — Separação de responsabilidades

**Agent Config**
- Preferências globais.
- Referências às credenciais.
- Configurações gerais de providers.
- Preferências de modelos e agentes.

**Orchestration**
- Seleção de papéis.
- Classificação da tarefa.
- Tiers e admissibilidade.
- Fallback, orçamento e escalonamento.
- Evidências e telemetria.

**OpenCode V2**
- Execução nativa.
- Sessões e subagents.
- Identidade efetiva do modelo.
- Operação dos providers.

**Task/Goal Kernel**
- Autoridade sobre estado, verificação e conclusão.

**Jev**
- Apoio consultivo às decisões.
- Nenhuma autoridade de execução ou concessão de permissões.

Agent Config não deverá implementar uma segunda política de roteamento conflitante.

### ADR-04 — Tiers não são providers

Um tier representa um perfil de trabalho e capacidade exigida.

Não representa:
- Um provider específico.
- Um preço fixo.
- Uma classificação universal de qualidade.
- Uma autorização automática de execução.

Um modelo poderá mudar de tier ou prioridade mediante configuração, dados de avaliação e compatibilidade.

### ADR-05 — Não modificar a metodologia de desenvolvimento

A metodologia incremental, os workflows de entrega e os contratos de conclusão continuam em seus componentes existentes.

Esta SPEC trata exclusivamente de roteamento de modelos e integração consultiva.

---

## 3. Catálogo inicial de modelos

| ID lógico | Modelo | Provider/model ID inicial | Tier |
|---|---|---|---|
| iceman | Iceman Contributor Free | `opencode-go/iceman-contributor-free` | T1 |
| deepseek | DeepSeek V4.1 Flash Free (desabilitado/legado) | `opencode/deepseek-v4.1-flash-free` | T2 (disabled) |
| muse | Muse Spark 1.3 Contributor | `opencode-go/muse-spark-1.3-contributor` | T2 |
| terra | GPT-6.1 Terra | `openai/gpt-6.1-terra` | T3 (especializado visual) |
| luna | GPT-6 Luna | `openai/gpt-6-luna` | T3 |
| sol | GPT-6.1 Sol | `openai/gpt-6.1-sol` | T4 |
| astra | GPT-6 Astra | `openai/gpt-6-astra` | T4 excepcional |

Os IDs são os identificadores inicialmente escolhidos e devem ser confirmados contra o catálogo realmente disponível no OpenCode e na conta OpenAI durante a implementação.

Não substituir IDs indisponíveis por variantes de outro provider sem autorização expressa da política.

### 3.1 Jev

Jev não participa dos tiers de programação.

Configuração desejada:

- Modelo: `jev-1.13-free`
- Endpoint: `https://opencode.ai/inference/systemone/v1/systemone`
- Serviço: OpenCode / System One
- Papel: decisões estruturadas e consultivas

### 3.2 Propriedades do modelo

Cada entrada do catálogo deverá possuir:

- `id`: identificador lógico.
- `provider`: provider efetivo.
- `model_id`: identificador do modelo.
- `enabled`: disponibilidade administrativa.
- `tier_profiles`: tiers permitidos.
- `eligible_roles`: agentes autorizados.
- `capabilities`: capacidades necessárias comprovadas.
- `priority`: preferência operacional.
- `cost_profile`: referência de preços e orçamento.
- `context_limits`: limites conhecidos.
- `data_policy`: restrições de tratamento de dados.
- `availability_status`: situação observada.
- `last_verified_at`: última verificação.
- `fallback_candidates`: alternativas elegíveis, por referência lógica.

Credenciais nunca deverão ser persistidas nesse catálogo.

## 4. Política dos tiers

### T0 — Determinístico

**Modelo:** nenhum.

Executa:
- AST, lint e verificações locais.
- Suítes de testes existentes.
- Comparação de hashes.
- Reuso comprovado de evidências.
- Operações determinísticas.

O uso de T0 não significa autorização para dispensar um worker exigido pelo contrato de orquestração.

### T1 — Gratuito e ultraleve

**Primário:** Iceman Contributor Free (`opencode-go`).

Tarefas:
- Exploração.
- Localização de arquivos.
- Classificação simples.
- Extração de informação.
- Triagem de baixo risco.

Em caso de indisponibilidade, o Router poderá solicitar T2 quando o trabalho justificar essa elevação.

Não tratar DeepSeek T2 como se fosse um T1 somente porque ambos são gratuitos.

### T2 — Execução econômica

**Primário:** DeepSeek V4.1 Flash Free (`opencode`).
**Alternativo:** Muse Spark 1.3 Contributor (`opencode-go`).

Tarefas:
- Implementação rotineira.
- Alterações pequenas ou médias.
- Criação de testes.
- Análise técnica comum.
- Desenvolvimento por especialistas.
- Revisões simples permitidas.

Uma falha de provider deverá priorizar alternativas T2 antes de escalonar cognitivamente.

### T3 — Raciocínio avançado

**Primário:** GPT-6 Luna (`openai`).

Tarefas:
- Programação complexa.
- Debugging lógico.
- Integração entre componentes.
- Revisão técnica relevante.
- Coordenação de objetivos.
- Advisor normal.

Não rebaixar automaticamente tarefas T3 para T2 quando houver requisito de capacidade ou risco incompatível.

### T4 — Raciocínio crítico

**Primário:** GPT-6.1 Sol (`openai`).
**Excepcional:** GPT-6 Astra (`openai`).

Tarefas:
- Arquitetura crítica.
- Segurança complexa.
- Concorrência e consistência distribuída.
- Impasses persistentes.
- Análises amplas com elevada interdependência.
- Consultas excepcionais do Advisor.

Astra deverá ser acionado somente quando:

1. Existir uma justificativa técnica.
2. A capacidade adicional for necessária.
3. O provider estiver disponível.
4. O orçamento estiver autorizado.
5. O escopo da consulta estiver delimitado.

Uma autorização de T4 não autoriza automaticamente qualquer utilização do Astra: o orçamento excepcional poderá ter limite próprio.

---

## 5. Modelos por função

| Agente | Padrão | Alternativa / escalonamento |
|---|---|---|
| Planner (`build`) | Luna | Advisor sob demanda |
| Explorer | Iceman | DeepSeek |
| Researcher | DeepSeek | Muse → Luna |
| Coder | DeepSeek | Muse → Luna |
| Tester com LLM | DeepSeek | Muse |
| Docs Manager | Iceman | DeepSeek |
| Frontend Engineer | Muse | Luna |
| Backend Engineer | Muse | Luna |
| Database Engineer | Muse | Luna |
| AI Agent Engineer | Muse | Luna |
| Automation Engineer | Muse | Luna |
| Infra Engineer | Muse | Luna |
| Reviewer | Luna | Sol |
| Debugger | Luna | Sol |
| Architect | Luna | Sol → Astra |
| Security Reviewer | Sol | Astra excepcional |
| Requirements Analyst | DeepSeek | Luna |
| Product Designer | DeepSeek | Luna |
| Skeptic | Luna | Sol |
| Engineering Advisor | Luna | Sol → Astra |

Essa matriz é a configuração inicial, e não uma lista de modelos permanentemente embutida nos agentes.

Os papéis existentes não devem ser reimplementados.

---

## 6. Configuração dinâmica

### 6.1 Manifesto

Criar ou estender um manifesto canônico de roteamento, caso não exista equivalente funcional.

Caminho candidato:

`source/registry/model-routing-policy.json`

O arquivo deverá conter referências lógicas, e não replicar implementações de seleção.

### 6.2 Estrutura conceitual

**Schema:** `model-routing-policy/v1`

Seções:

- `schema_version`
- `policy_version`
- `models`
- `tiers`
- `role_profiles`
- `planner`
- `advisor`
- `jev`
- `fallback_policy`
- `cost_policy`
- `runtime_verification`

A estrutura final deverá ser validada contra os consumidores existentes antes da implementação.

### 6.3 Configuração inicial

Exemplo conceitual:

**Models**

- `iceman`: provider `opencode-go`, model `iceman-contributor-free`.
- `deepseek`: provider `opencode`, model `deepseek-v4.1-flash-free`.
- `muse`: provider `opencode-go`, model `muse-spark-1.3-contributor`.
- `luna`: provider `openai`, model `gpt-6-luna`.
- `sol`: provider `openai`, model `gpt-6.1-sol`.
- `astra`: provider `openai`, model `gpt-6-astra`.

**Tiers**

- `T0`: deterministic.
- `T1`: primary `iceman`.
- `T2`: primary `deepseek`, fallback `muse`.
- `T3`: primary `luna`.
- `T4`: primary `sol`, exceptional `astra`.

**Planner**

- Primary: `luna`.
- Stable during objective: true.

**Advisor**

- Default: `luna`.
- Advanced: `sol`.
- Exceptional: `astra`.

**Jev**

- Model: `jev-1.13-free`.
- Mode: advisory.
- Transport: System One.

### 6.4 Precedência

1. Restrições e autorizações efetivas.
2. Override explícito autorizado para a tarefa.
3. Política de roteamento da Orquestração.
4. Preferências globais fornecidas pelo Agent Config.
5. Defaults versionados.

Preferências globais não podem sobrescrever proibições de risco ou custo.

### 6.5 Alterações futuras

Deve ser possível:

- Trocar Iceman por outro gratuito.
- Mudar DeepSeek para outro provider.
- Substituir Muse por outro modelo econômico.
- Alterar o modelo do Planner.
- Introduzir novos T3.
- Modificar o Advisor.
- Desabilitar Sol ou Astra.
- Adicionar novos providers.
- Atualizar Jev.

Sem modificar a lógica interna de cada subagent.

### 6.6 Versionamento

Cada decisão deverá referenciar o hash da política utilizada.

Alterações de configuração não deverão reinterpretar retroativamente execuções históricas.

Novas sessões utilizarão a configuração aplicável no momento de sua criação.

---

## 7. Contrato do Model Router

### Entrada

`ModelSelectionRequest`:

- task_id
- goal_id
- agent_role
- task_type
- risk
- complexity
- required_capabilities
- context_requirement
- data_classification
- budget
- failure_history
- allowed_providers
- policy_version

### Saída

`ModelSelectionDecision`:

- status
- requested_role
- selected_model_id
- selected_provider
- selected_tier
- selection_reason
- authorized
- authorization_source
- policy_version
- policy_hash
- fallback_candidates
- runtime_override_status

O resultado de seleção não representa execução realizada.

### Estados de decisão

- `SELECTED`
- `NO_ELIGIBLE_MODEL`
- `PROVIDER_UNAVAILABLE`
- `COST_AUTHORIZATION_REQUIRED`
- `POLICY_INVALID`
- `CAPABILITY_UNSUPPORTED`

Os estados precisam ser recuperáveis pelo Planner quando possível.

---

## 8. Integração com OpenCode V2

A execução deverá permanecer Native-First.

O Planner utilizará os mecanismos nativos de delegação do OpenCode V2.

O Router não poderá criar um executor concorrente somente para contornar limitações do host.

### 8.1 Aplicação da seleção

Verificar a capacidade efetiva do runtime:

- Override de modelo por chamada.
- Configuração nativa por agente.
- Identidade de provider.
- Herança de modelo.
- Export de sessão.
- Compatibilidade com fallback.

Usar somente mecanismos suportados e comprovados.

### 8.2 Verificação após execução

Preservar:

- `EXACT_MATCH`
- `AUTHORIZED_FALLBACK`
- `UNAUTHORIZED_MISMATCH`
- `PROOF_ABSENT`

Confirmar provider e modelo efetivos.

A troca entre `opencode` e `openai` deverá ser explicitamente registrada.

### 8.3 Recibos

Registrar:

- Task/Goal/Run/Session IDs.
- Papel executado.
- Provider solicitado e efetivo.
- Modelo solicitado e efetivo.
- Tier.
- Política utilizada.
- Fallback autorizado.
- Resultado da execução.
- Tokens e custo conhecido.
- Origem e integridade da evidência.

Preservar a separação:

- `CANONICAL_PROTOCOL`
- `POST_EXECUTION_AUDIT`

---

## 9. Política de fallback

### 9.1 Falha de provider

Exemplos:
- Rate limit.
- Provider temporariamente indisponível.
- Quota esgotada.
- Timeout de transporte.

Ações:

1. Identificar a falha.
2. Consultar alternativas configuradas.
3. Preferir o mesmo tier.
4. Verificar autorização do provider alternativo.
5. Respeitar tentativas e orçamento.
6. Registrar a decisão.
7. Executar ou devolver estado recuperável.

### 9.2 Falha de capacidade

Uma implementação incorreta não implica necessariamente trocar de modelo.

Antes de escalonar, avaliar:
- Erro de especificação.
- Informação ausente.
- Teste incorreto.
- Defeito reproduzível.
- Estratégia inadequada.
- Capacidade insuficiente do modelo.

Escalonar somente quando houver justificativa.

### 9.3 Proibições

- Loops de fallback.
- Fallback para modelo desconhecido.
- Rebaixamento incompatível com o risco.
- Uso não autorizado de Astra.
- Troca silenciosa de provider.
- Execução duplicada após efeito ambíguo.
- Declaração de custo zero quando o custo for desconhecido.

---

## 10. Planner

### Modelo inicial

`openai/gpt-6-luna`

O Planner deverá:

- Preservar contexto estratégico.
- Decompor objetivos.
- Escolher especialistas.
- Utilizar o Router.
- Delegar execução.
- Consumir resultados.
- Consultar Advisor quando necessário.
- Continuar até o objetivo estar concluído.

Evitar executar tarefas triviais que podem ser resolvidas deterministicamente ou por um worker econômico.

O Planner não deverá mudar de modelo a cada subtarefa.

---

## 11. Engineering Advisor

### Modelo normal

`openai/gpt-6-luna`

### Modelo avançado

`openai/gpt-6.1-sol`

### Modelo excepcional

`openai/gpt-6-astra`

### Sinais de acionamento

- Impasse técnico.
- Falhas persistentes.
- Divergência de diagnóstico.
- Dificuldade arquitetural.
- Incerteza estrutural.
- Risco elevado.
- Necessidade comprovada de raciocínio adicional.

### Saída exigida

- Diagnóstico.
- Evidências.
- Opções.
- Recomendação.
- Justificativa.
- Riscos.
- Próxima ação recomendada.

O Advisor permanece consultivo.

### Política de custo

Preferir consultas delimitadas e reutilizar evidências.

Sol e Astra não devem ser acionados por rotina.

Após resolver o impasse, a execução deverá retornar ao worker econômico adequado.

---

## 12. Jev Free

### Configuração

**Provider:** OpenCode / System One
**Modelo:** `jev-1.13-free`
**Endpoint:** `https://opencode.ai/inference/systemone/v1/systemone`

Reutilizar:

`scripts/v3/lib/OrchestrationJevAdvisory.ps1`

### Variáveis

- `JEV_BASE_URL`
- `JEV_MODEL`
- `JEV_API_KEY`

A credencial deverá ser obtida do ambiente/gerenciador existente, sem persistência em arquivos versionados.

### Funções consultivas

- `jev_check`
- `jev_gate`
- `jev_score`
- `jev_decide`

### Aplicação de decisões

Jev poderá recomendar:

- Especialista.
- Estratégia.
- Paralelismo.
- Investigação.
- Alternativa.
- Próxima ação.

A recomendação só poderá ser aplicada quando compatível com as opções permitidas pelo Planner e pela política.

### Telemetria

Preservar estados separados:

- advice_received
- advice_evaluated
- advice_accepted
- advice_applied

`advice_applied` requer mudança real e comprovada de decisão.

Jev não concede permissões, não seleciona sozinho providers pagos e não marca tarefas como DONE.

Quando indisponível, retornar à decisão determinística sem bloquear desnecessariamente a execução.

---

## 13. Segurança, orçamento e autonomia

O Router deve preservar autonomia operacional.

Ações internas autorizadas não devem depender de aprovações humanas repetitivas.

Operações externas continuam submetidas aos procedimentos existentes de teste e review.

### Custos

Distinguir:
- Gratuito.
- Incluído em plano.
- Cobrado por utilização.
- Preço desconhecido.

Não presumir que modelos OpenAI estejam incluídos na assinatura do ChatGPT ou em quotas de outro provider.

Astra exige autorização de orçamento excepcional.

### Tratamento de dados

Não enviar dados sensíveis para providers sem elegibilidade configurada.

As restrições específicas do Muse Spark Contributor devem ser consideradas.

---

## 14. Observabilidade

Registrar por execução:

- Modelo e provider selecionados.
- Modelo e provider efetivos.
- Tier.
- Latência.
- Tokens.
- Custo observado ou UNKNOWN.
- Quantidade de tentativas.
- Taxa de sucesso.
- Falhas e fallback.
- Consulta ao Advisor.
- Recomendação do Jev.
- Resultado dos testes.
- Estado final da Task/Goal.

### Métricas principais

- Cost-to-DONE.
- Latência até DONE.
- Taxa de execução correta.
- Taxa de retrabalho.
- Fallbacks por provider.
- Escalonamentos T3/T4.
- Utilização do Astra.
- Benefício operacional do Advisor/Jev.

---

## 15. Compatibilidade

Preservar os consumidores existentes:

- `models.jsonc`
- Variáveis `MODEL_*`
- Template OpenCode V2
- PlannerLoop
- Native Dispatch
- AdvisorEscalation
- JevAdvisory
- Task/Goal Kernel

Não atualizar contratos públicos de forma incompatível sem adaptador e testes.

Não reinstalar MCPs ou substituir infraestrutura já funcional.

---

## 16. Critérios de aceite

- [ ] Catálogo configurável implantado.
- [ ] OpenCode, OpenCode Go e OpenAI separados corretamente.
- [ ] Luna, Sol e Astra usam provider `openai`.
- [ ] Iceman, DeepSeek e Muse usam os respectivos providers definidos.
- [ ] T0 não executa LLM.
- [ ] Modelo pode ser substituído por configuração.
- [ ] Provider pode ser substituído por configuração autorizada.
- [ ] Router aplica risco, capacidade e orçamento.
- [ ] Fallbacks são limitados e rastreáveis.
- [ ] Native Dispatch utiliza e verifica a seleção.
- [ ] Planner permanece estável em Luna.
- [ ] Advisor utiliza Luna/Sol/Astra conforme gatilhos.
- [ ] Jev Free funciona e permanece consultivo.
- [ ] Task/Goal Kernel preserva seus contratos.
- [ ] Testes e CI aprovados.
- [ ] Pelo menos um E2E produtivo comprovado.
- [ ] Rollback da configuração validado.

## 17. Fora de escopo

- Novo orquestrador.
- Novo Model Router paralelo.
- Reescrever os 19 agentes.
- Alterar a metodologia incremental.
- Novo sistema de credenciais.
- Reinstalação de MCPs.
- Deploy automático.
- Uso rotineiro de Astra.
- Benchmark extensivo como bloqueio obrigatório.

## 18. Definição de pronto

O sistema deverá permitir alterar modelos e providers por configuração e comprovar que o subagent executou o modelo autorizado, preservando custo, segurança, autonomia e integridade do Kernel.

**Resultado esperado:** CONFIGURABLE_MODEL_ROUTING_READY_FOR_CONTROLLED_PILOT.
