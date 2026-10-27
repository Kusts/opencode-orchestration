# PLAN — Dynamic Model Routing v1.1

**Projeto:** Kusts/opencode-orchestration
**Status:** READY_FOR_IMPLEMENTATION
**SPEC:** Dynamic Model Routing & Intelligent Advisory v1.1
**Runtime:** OpenCode V2
**Estratégia:** Implementação incremental com validação focalizada.

---

## Fase 0 — Baseline e inventário

### 0.1 Confirmar o PR #158

Verificar:
- Estado e HEAD do PR.
- CI.
- Review.
- Alterações pendentes.
- Baseline final integrada.

O último resultado consultado do CI do PR #158 foi 6/6 jobs aprovados. Confirmar o estado final antes de iniciar esta evolução.

Não misturar as correções do PR #158 com o novo catálogo.

### 0.2 Inventariar os componentes

Analisar:

- `OrchestrationModelRouter.ps1`
- `OrchestrationPlannerLoop.ps1`
- `OrchestrationNativeDispatch.ps1`
- `OrchestrationAdvisorEscalation.ps1`
- `OrchestrationJevAdvisory.ps1`
- `models.example.jsonc`
- `templates/opencode.v2.json.tmpl`
- Configurações globais do Agent Config.

Identificar onde o modelo é:
- Recomendado.
- Configurado.
- Autorizado.
- Executado.
- Verificado.

### Entrega

Documento curto de inventário arquitetural e compatibilidade.

**Gate 0:** baseline definida e nenhuma duplicação desnecessária planejada.

---

## Fase 1 — Catálogo configurável

### 1.1 Formalizar o schema

Criar ou estender o manifesto central de roteamento.

Campos obrigatórios:
- Provider.
- Model ID.
- Tier.
- Capacidades.
- Papéis.
- Prioridade.
- Disponibilidade.
- Custo.
- Autorização.
- Fallback.
- Versão da política.

### 1.2 Configurar providers

**OpenCode**
- Beam Free.
- DeepSeek V4.1 Flash Free.

**OpenCode Go**
- Muse Spark 1.3 Contributor.

**OpenAI**
- GPT-6 Luna.
- GPT-6.1 Sol.
- GPT-6 Astra.

**Jev**
- Jev 1.13 Free, via System One.

Validar cada ID no provider real.

Não registrar senhas, tokens ou chaves na configuração.

### 1.3 Mapear tiers

- T0: deterministic.
- T1: Beam.
- T2: DeepSeek, Muse.
- T3: Luna.
- T4: Sol, Astra excepcional.

### 1.4 Definir prioridades

Permitir alterar:
- Modelo primário.
- Alternativas.
- Prioridade.
- Provider.
- Limite de custo.
- Elegibilidade por papel.

### Testes

- Substituir Beam por outro modelo.
- Trocar o provider de um modelo lógico.
- Desabilitar um modelo.
- Desabilitar um provider.
- Recusar configuração inválida.
- Recusar ausência de autorização de custo.
- Preservar compatibilidade com modelos antigos.
- Não expor credenciais.

**Gate 1:** modelos e providers substituíveis por configuração.

---

## Fase 2 — Evolução do Model Router

### 2.1 Consumir a nova política

Atualizar:

`Resolve-OrchestrationModelSelection`

Substituir referências fixas aos modelos pelo catálogo versionado.

### 2.2 Aplicar critérios

Considerar:
- Papel.
- Risco.
- Complexidade.
- Capacidade.
- Disponibilidade.
- Histórico de falhas.
- Custo esperado.
- Restrições de dados.

### 2.3 Fallback

Atualizar:

`Resolve-OrchestrationModelFallback`

A função deverá:
- Consultar candidatos da configuração.
- Priorizar mesmo tier quando permitido.
- Evitar ciclos.
- Respeitar orçamento.
- Impedir downgrade proibido.
- Registrar o provider de origem e destino.

### 2.4 Verificação

Preservar:

`Test-ExecutedModelVerification`

Testar:
- EXACT_MATCH.
- AUTHORIZED_FALLBACK.
- UNAUTHORIZED_MISMATCH.
- PROOF_ABSENT.

### Testes obrigatórios

- Beam T1.
- DeepSeek T2.
- Muse T2.
- Luna T3.
- Sol T4.
- Astra excepcional.
- Provider indisponível.
- Modelo sem autorização.
- Modelo efetivo divergente.
- Fallback cross-provider permitido.
- Fallback cross-provider proibido.

**Gate 2:** o Router seleciona e autoriza corretamente sem depender de modelos escritos diretamente no código.

---

## Fase 3 — Integração com Native Dispatch

### 3.1 Identificar a superfície executável

Confirmar o mecanismo suportado pelo OpenCode V2 para aplicar o modelo selecionado a cada agente.

Não assumir que um campo de planejamento muda automaticamente o modelo do subagent.

### 3.2 Conectar Router ao executor

A seleção deverá chegar ao dispatch.

Confirmar:
- Modelo solicitado.
- Provider solicitado.
- Modelo efetivamente usado.
- Provider efetivamente usado.
- Session ID.
- Tier.
- Autorização de fallback.

### 3.3 Compatibilidade

Se o runtime não suportar override por chamada, utilizar uma configuração nativa comprovada para sessões novas.

Não criar segundo executor paralelo.

### 3.4 Rastreabilidade

Registrar versão/hash da política em cada execução.

Preservar recibos idempotentes e integridade dos resultados.

### Testes

- Seleção T2 com execução real.
- Sessão nativa com modelo esperado.
- Provider trocado por configuração.
- Modelo divergente rejeitado.
- Execução sem prova classificada corretamente.

**Gate 3:** roteamento efetivamente aplicado e comprovado no runtime.

---

## Fase 4 — Planner e Advisor

### 4.1 Planner

Configurar:

`openai/gpt-6-luna`

Manter modelo estável durante o objetivo normal.

O Planner deve continuar usando trabalhadores econômicos quando apropriado.

### 4.2 Advisor

Configuração:

- Normal: `openai/gpt-6-luna`.
- Avançado: `openai/gpt-6.1-sol`.
- Excepcional: `openai/gpt-6-astra`.

### 4.3 Política de consulta

Acionar Advisor por:
- Impasse.
- Incerteza relevante.
- Falha persistente.
- Questão arquitetural.
- Segurança.
- Necessidade comprovada de capacidade adicional.

### 4.4 Astra

Exigir:
- Justificativa.
- Orçamento autorizado.
- Contexto delimitado.
- Evidência da consulta.
- Registro do custo efetivo.

Não manter Astra permanentemente ativo.

### Testes

- Planner usa Luna.
- Advisor normal utiliza Luna.
- Advisor avançado utiliza Sol.
- Astra sem autorização não executa.
- Astra autorizado é selecionado.
- Advisor indisponível não gera loop.
- Consulta repetida pode reutilizar evidência válida.

**Gate 4:** Planner estável e Advisor escalonável por configuração.

---

## Fase 5 — Integração Jev Free

### 5.1 Configurar transporte

Usar:

`OrchestrationJevAdvisory.ps1`

Valores desejados:

`JEV_BASE_URL=https://opencode.ai/inference/systemone/v1/systemone`

`JEV_MODEL=jev-1.13-free`

`JEV_API_KEY`: referência à credencial existente do OpenCode.

Não instalar novamente o MCP Jev.

### 5.2 Prova real

Executar uma chamada curta de decisão estruturada.

Confirmar:
- Autenticação.
- Endpoint.
- Modelo.
- Resposta.
- Formato.
- Latência.
- Tratamento de erros.

### 5.3 Integração com Planner

Validar inicialmente em modo observação.

Permitir aplicação de decisões consultivas quando:
- As alternativas forem permitidas.
- A política concordar.
- O Planner aceitar.
- A alteração de estratégia for registrada.

### 5.4 Fallback

Em indisponibilidade, manter o planejamento determinístico existente.

### Testes

- Decisão válida.
- Decisão inválida.
- Resposta fora do conjunto permitido.
- Timeout.
- Circuit breaker.
- Estratégia alterada.
- Estratégia preservada.
- Nenhuma ampliação de permissões.

**Gate 5:** Jev Free operacional e consultivo.

---

## Fase 6 — Teste integrado controlado

Executar cenários curtos e representativos.

| Cenário | Objetivo |
|---|---|
| 1 | Tarefa leve com Beam |
| 2 | Codificação com DeepSeek |
| 3 | Codificação com Muse |
| 4 | Tarefa complexa com Luna |
| 5 | Revisão avançada com Sol |
| 6 | Simulação de autorização do Astra |
| 7 | Fallback entre providers |
| 8 | Consulta ao Advisor |
| 9 | Decisão estruturada pelo Jev |
| 10 | Conclusão integrada pelo Task/Goal Kernel |

Não executar todos os cenários com modelos pagos se fixtures comprovarem adequadamente o contrato.

Ao menos um cenário deverá utilizar sessões reais do OpenCode com verificação do modelo efetivo.

### Métricas

Registrar:
- Modelo solicitado.
- Modelo efetivo.
- Provider.
- Tokens.
- Custo.
- Tempo.
- Resultado.
- Retrabalho.
- Fallback.
- Advisor/Jev.
- Estado final do Goal.

Evitar comparações econômicas entre tarefas não equivalentes.

**Gate 6:** execução integrada comprovada.

---

## Fase 7 — Documentação operacional

Criar instruções para:

1. Adicionar um modelo.
2. Substituir um modelo.
3. Mudar o provider.
4. Alterar prioridades dos tiers.
5. Configurar o Planner.
6. Configurar o Advisor.
7. Autorizar o Astra.
8. Configurar o Jev Free.
9. Investigar divergências entre modelos solicitados e efetivos.
10. Restaurar a configuração anterior.

A operação deve ser simples o suficiente para não exigir alterações de código a cada atualização do catálogo.

---

## Fase 8 — Review e publicação

### 8.1 Review independente

Conferir:
- Compatibilidade.
- Provider correto.
- Regras de custo.
- Fallback.
- Integridade de recibos.
- Autonomia do Planner.
- Limites do Jev.
- Comportamento do Kernel.

### 8.2 GitHub

Criar branch exclusiva para essa evolução.

Organizar commits por fase funcional.

Executar testes e CI.

Abrir PR com evidências objetivas.

Não modificar a master diretamente.

Não executar deploy automaticamente.

### 8.3 Fechamento

Relatório final:

| Entrega | Status | Evidência |
|---|---|---|
| Catálogo configurável | PASS/FAIL | Schema e testes |
| Providers corretos | PASS/FAIL | Configuração e runtime |
| Router | PASS/FAIL | Testes |
| Fallback | PASS/FAIL | Testes |
| Native Dispatch | PASS/FAIL | Sessões |
| Planner | PASS/FAIL | Sessão efetiva |
| Advisor | PASS/FAIL | Parecer e modelo |
| Jev Free | PASS/FAIL | Resposta estruturada |
| Task/Goal Kernel | PASS/FAIL | Recibos |
| CI | PASS/FAIL | GitHub Actions |

Informar SHA, PR, testes e riscos residuais.

---

## Ordem de execução

**Primeira entrega**
- Fase 0: baseline.
- Fase 1: catálogo.
- Fase 2: Router.

**Segunda entrega**
- Fase 3: Native Dispatch.
- Fase 4: Planner e Advisor.

**Terceira entrega**
- Fase 5: Jev Free.
- Fase 6: prova integrada.

**Fechamento**
- Fases 7 e 8: documentação, review e PR.

Não realizar grandes refatorações nem aumentar o escopo em caso de falha isolada.

## Definição de pronto

A evolução estará concluída quando:

1. Modelos e providers puderem ser modificados por configuração.
2. Os agentes utilizarem modelos autorizados.
3. A seleção for verificada no OpenCode V2.
4. Planner e Advisor operarem com os perfis previstos.
5. Jev Free funcionar como serviço consultivo.
6. Fallbacks forem recuperáveis e rastreáveis.
7. O Kernel permanecer funcional.
8. O CI e a validação integrada passarem.

**Veredito esperado:** CONFIGURABLE_MODEL_ROUTING_READY_FOR_CONTROLLED_PILOT.
