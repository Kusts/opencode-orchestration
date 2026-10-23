# PLAN — Incremental Delivery Engine

**Projeto:** opencode-orchestration  
**Base:** SPEC — Incremental Delivery & Evidence-Driven Development  
**Estratégia:** Native-first, reuse-first, TDD e validação incremental  
**Restrição:** OpenCode V2; V1 congelada

## Fase 0 — Auditoria e integração arquitetural

**Prioridade:** P0  
**Objetivo:** compreender o workflow existente antes de adicionar código.

### Atividades

1. Inspecionar HEAD, branch atual, working tree e alterações locais.
2. Examinar o PR #151, ainda não integrado ao master na última consulta, e identificar recursos já implementados.
3. Inspecionar os componentes atuais:
   - `OrchestrationPreflight.ps1`
   - `OrchestrationPlannerLoop.ps1`
   - `OrchestrationTaskKernel.ps1`
   - `OrchestrationGoalKernel.ps1`
   - `OrchestrationGoalProgress.ps1`
   - `OrchestrationObjectiveController.ps1`
   - `OrchestrationEvidenceStore.ps1`
   - `OrchestrationEvidenceRef.ps1`
   - `OrchestrationE2eManifest.ps1`
   - `OrchestrationDelivery.ps1`
   - `OrchestrationAutonomousLoop.ps1`
   - `OrchestrationNativeDispatch.ps1`
4. Examinar `skills-core/hybrid-development/SKILL.md` e suas instruções relacionadas.
5. Examinar issues #6, #30, #48 e os trabalhos existentes de eficiência e routing.
6. Identificar o caminho produtivo de entrada, decisão, dispatch, verificação e conclusão.
7. Distinguir recursos implementados em bibliotecas, conectados ao runtime e realmente comprovados.
8. Identificar quem é o owner de cada contrato antes de modificá-lo.

### Entrega

Uma matriz de integração contendo:

| Capacidade | Implementação atual | Integração produtiva | Lacuna | Alteração proposta |
|---|---|---|---|---|
| Decomposição | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |
| Task state | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |
| Evidence | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |
| DONE gate | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |
| Golden Workflow | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |
| Recovery | Evidência encontrada | Sim/não/parcial | Objetiva | Reuso ou ajuste |

**Critério de saída:** nenhuma nova responsabilidade pode ser atribuída a um componente sem confrontá-la com uma capacidade existente.

Não encerrar a fase somente porque foi produzido um documento: a matriz deve indicar o caminho real no código e as provas disponíveis.

---

## Fase 1 — Contrato de fatia vertical

**Prioridade:** P0  
**Objetivo:** permitir que o Planner produza e mantenha fatias verificáveis.

### Implementação

1. Definir o contrato mínimo e versionado de `DeliverySlice`.
2. Adicionar validação de schema e invariantes.
3. Vincular cada fatia a Objective/Goal/Task existente.
4. Definir contrato de critérios de aceite com oráculo de verificação.
5. Implementar análise de admissibilidade:
   - resultado único;
   - escopo delimitado;
   - dependências conhecidas;
   - validação possível;
   - não objetivos definidos.
6. Criar divisão assistida de fatias grandes, sem adicionar outra hierarquia autoritativa.
7. Preservar decisões e identificadores entre sessões.

### Testes

- Fatia válida.
- Fatia sem resultado observável.
- Fatia com critérios contraditórios.
- Dependência inexistente ou circular.
- Contrato malformado.
- Escopo excessivo que exige subdivisão.
- Reabertura após retomada.
- Compatibilidade com registros existentes.

### Critério de saída

O sistema consegue representar uma fatia com contrato verificável, recuperar seu estado e encaminhá-la ao workflow existente.

**Não criar um novo serviço de planejamento.**

---

## Fase 2 — Primeiro caminho real de entrega

**Prioridade:** P0  
**Objetivo:** validar uma fatia pequena percorrendo o workflow produtivo.

### Implementação

1. Selecionar uma fatia simples com comportamento real.
2. Vincular o contrato ao Planner/preflight existente.
3. Executar usando a estratégia proporcional definida pelo sistema.
4. Registrar as tarefas e resultados nos kernels existentes.
5. Produzir evidências para os critérios de aceite.
6. Verificar as evidências com o mecanismo atual.
7. Impedir conclusão quando critério obrigatório não for comprovado.
8. Permitir conclusão quando todos os requisitos aplicáveis forem satisfeitos.

### Testes

- Implementação sem integração não satisfaz a fatia.
- Integração sem validação não satisfaz a fatia.
- Evidência correta autoriza progressão.
- Evidência falsa, ausente ou desatualizada não autoriza conclusão.
- Conclusão indevida do Coder não altera o estado autoritativo.
- Retomada mantém o progresso já comprovado.

### Critério de saída

Pelo menos uma execução real do Planner no OpenCode V2 deve percorrer o caminho de entrega, com resultado observado e prova verificável.

Harness sintético pode apoiar os testes, mas não substitui essa prova.

---

## Fase 3 — Validation Profiles e rastreabilidade

**Prioridade:** P0  
**Objetivo:** provar o comportamento certo sem aumentar desnecessariamente o custo dos testes.

### Implementação

1. Mapear `DIRECT`, `STANDARD` e `HIGH_RISK` ao preflight e às políticas existentes.
2. Associar critérios de aceite às evidências produzidas.
3. Diferenciar evidências de:
   - teste unitário;
   - contrato;
   - integração;
   - E2E;
   - eval com modelo real;
   - CI;
   - revisão.
4. Aplicar regras de invalidação de evidência conforme alterações.
5. Integrar o resultado ao verificador e ao DONE gate existentes.
6. Estender Golden Workflows para verificar o contrato de fatia.
7. Permitir que projetos consumidores definam seus próprios oráculos, sem permissões adicionais implícitas.

### Testes

- Mudança trivial não dispara validações desnecessárias.
- Mudança funcional exige comprovação de comportamento.
- Mudança de alto risco exige as evidências adicionais configuradas.
- Mock não é classificado como integração real.
- Harness não é classificado como execução produtiva.
- CI verde com aceite funcional ausente não permite falso DONE.
- Evidência invalidada exige revalidação aplicável.
- Ausência de recurso externo gera bloqueio honesto.

### Critério de saída

O sistema escolhe o nível de verificação apropriado e distingue corretamente resultados comprovados de resultados apenas simulados.

---

## Fase 4 — Controle de convergência

**Prioridade:** P1  
**Objetivo:** reduzir ciclos repetitivos de implementação e correção.

### Implementação

1. Reutilizar os mecanismos existentes de progress, stall, retry, debugger e advisor.
2. Associar tentativas de correção ao defeito e à fatia.
3. Registrar hipótese e evidência nova quando uma tentativa falhar.
4. Identificar ausência de progresso verificável.
5. Após duas tentativas sem progresso, trocar de estratégia.
6. Acionar debugger ou advisor apenas quando houver justificativa.
7. Evitar replanejamento global por erros localizados.
8. Preservar a continuidade da fatia e do Goal durante recuperação.

### Testes

- Correção bem-sucedida encerra a tentativa.
- Duas tentativas repetidas sem progresso geram diagnóstico.
- Uma terceira tentativa sem hipótese nova é rejeitada ou redirecionada.
- Progresso real não sofre bloqueio arbitrário.
- Impasse de arquitetura aciona especialista adequado.
- Quota, indisponibilidade de provider e erro de código são classificados separadamente.
- Objetivo persistente não perde contexto após recuperação.

### Critério de saída

Demonstrar um Golden Workflow em que uma falha é detectada, diagnosticada, corrigida e revalidada, sem loop infinito.

---

## Fase 5 — Piloto no Meu Ted

**Prioridade:** P0 para aceitação funcional do programa  
**Objetivo:** comprovar que o processo funciona em um produto consumidor.

### Jornada selecionada

**Registrar uma despesa pelo chat.**

Entrada representativa:

"Gastei 50 de carne."

### Condições

- Utilizar a base local atual do Meu Ted.
- Não sobrescrever alterações em andamento.
- Não refazer sua arquitetura por conveniência.
- Não copiar lógica de negócio para a orquestração.
- Utilizar ambiente e dados de teste.
- Manter backend autoritativo e idempotência.
- Exigir confirmação somente onde a política do produto determinar.

### Execução

1. Verificar estado atual da jornada e falhas ainda existentes.
2. Registrar critérios de aceite independentes.
3. Separar dependências em fatias menores caso necessário.
4. Executar uma fatia de cada vez.
5. Validar interface, Agent, tool, API e persistência.
6. Verificar resultado no estado autoritativo.
7. Cobrir cancelamento, retry e persistência da conversa quando aplicável.
8. Capturar custo, tentativas, tempo e regressões.

### Critério de saída

A jornada deve estar comprovadamente funcional com evidências do ambiente de teste, e a orquestração deve registrar corretamente todos os estados e custos relevantes.

**Se o Meu Ted permanecer com um defeito real, não considerar o piloto aprovado apenas porque o contrato do orquestrador passou.**

---

## Fase 6 — Otimização e rollout

**Prioridade:** P1  
**Objetivo:** consolidar o novo processo sem regressões ou custos excessivos.

### Implementação

1. Comparar custo e tempo com a baseline.
2. Analisar quantidade de tentativas corretivas.
3. Verificar se o Planner faz menos replanejamentos desnecessários.
4. Integrar telemetria à capacidade atual, quando disponível.
5. Ajustar roteamento de modelos e uso de especialistas com base em dados.
6. Testar a metodologia em uma segunda categoria de tarefa.
7. Consolidar documentação e instruções do Planner.
8. Estabelecer caminho de ativação gradual e rollback.

### Critério de saída

O novo processo demonstra funcionamento real, não aumenta injustificadamente o custo de tarefas simples e preserva o comportamento anterior.

---

## Estratégia de PRs

Preferir PRs pequenos, por incremento validado.

Sequência lógica sugerida:

- **PR A:** contrato + schemas + testes.
- **PR B:** ligação com Planner/TaskKernel + Golden Workflow.
- **PR C:** validação funcional, perfis e evidências.
- **PR D:** convergência e integração de recovery.
- **PR E:** piloto, telemetria e ajustes.

Essa divisão é indicativa. Antes de criar branches ou PRs, verificar o estado do PR #151, os arquivos compartilhados e a estratégia de integração escolhida.

Evitar PR gigante reunindo todas as fases.

## Estratégia de testes e CI

Durante implementação:

- Executar os testes focados do componente alterado.
- Executar contratos/integradores impactados.
- Reutilizar resultados válidos quando a evidência continuar atual.
- Não executar a suíte completa repetidamente sem mudança relevante.

Antes de integração:

- Executar suíte completa correspondente à alteração.
- Verificar regressões de pacote e distribuição quando afetadas.
- Executar Golden Workflows exigidos.
- Confirmar comportamento real nos casos definidos.
- Registrar limitações ambientais e dependências externas.

Comandos existentes a descobrir e confirmar no checkout:

- `scripts/test-package-consistency.ps1`
- `scripts/v3/run-v3-tests.ps1`
- `tests/distribution/run-distribution-tests.ps1`

Usar o executor PowerShell e a configuração reais do repositório, sem presumir que todo teste disponível é necessário em cada alteração.

## Regras de não regressão

- Preservar contratos e estado persistente.
- Não duplicar GoalKernel/TaskKernel.
- Não sobrescrever alterações locais sem reconciliação.
- Não alterar policy, grants ou permissões para facilitar testes.
- Não tocar no OpenCode V1.
- Não desabilitar testes que falham.
- Não classificar casos bloqueados como PASS.
- Não criar flags globais adicionais sem necessidade comprovada.
- Não alterar requisitos de aceite depois da implementação apenas para gerar sucesso.
- Não ampliar a fatia por melhorias opcionais.

## Relatório esperado por fase

Cada entrega deve registrar:

1. Objetivo e fatia realizada.
2. Baseline/HEAD usado.
3. Alterações e contratos impactados.
4. Critérios de aceite.
5. Testes executados e resultados.
6. Evidências reais versus sintéticas.
7. Impedimentos e riscos.
8. Custo/tempo, quando disponível.
9. Estado: implementado, integrado, validado ou concluído.
10. Próxima fatia elegível.

O Planner deve continuar automaticamente com a próxima fatia autorizada e pronta, respeitando budgets, dependências e mecanismos de autorização.

Não reiniciar a SPEC ou o plano completo após cada correção.

## Condição final de encerramento

O programa estará concluído somente com:

- Contrato incorporado ao workflow existente.
- Critérios de aceite comprovados.
- Execução real OpenCode V2.
- Golden Workflows de integração e recuperação.
- Piloto funcional no Meu Ted.
- Sem regressões impeditivas conhecidas.
- Métricas básicas registradas.
- Documentação consistente com a implementação.

**Nunca declarar COMPLETE por quantidade de PRs, arquivos, commits ou testes isolados.**
