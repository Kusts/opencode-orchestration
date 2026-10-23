# SPEC — Incremental Delivery & Evidence-Driven Development

**Projeto:** opencode-orchestration  
**Versão da proposta:** 1.0  
**Data:** 23/10/2026  
**Status:** PROPOSTA PARA IMPLEMENTAÇÃO  
**Runtime-alvo:** OpenCode V2  
**Prioridade:** P0 para fundação; P1 para otimizações posteriores

## 1. Problema

O workflow atual permite implementar, revisar e testar grandes conjuntos de funcionalidades sem comprovar suficientemente que o usuário consegue completar a jornada prometida.

Sintomas observados:

- Grandes planos executados em muitas ondas antes da validação funcional.
- Componentes implementados sem integração efetiva.
- Testes unitários e de harness aprovados, mas jornadas reais com falhas.
- Repetição de planejamento, correção e review sem convergência.
- Declarações de conclusão incompatíveis com o estado efetivo do produto.
- Retrabalho elevado e utilização desnecessária de modelos e subagentes.

O objetivo não é aumentar a quantidade de verificações, mas aproximar a implementação da prova de funcionamento.

## 2. Objetivo

Estabelecer um processo reutilizável no qual:

1. Um Objective é decomposto em resultados verificáveis.
2. Cada resultado é entregue como uma fatia vertical.
3. O Planner prioriza uma fatia principal por vez.
4. O Coder implementa o menor comportamento completo.
5. A validação utiliza critérios previamente definidos.
6. As evidências representam o ambiente e o código efetivamente entregues.
7. O Kernel autoriza a conclusão somente quando os requisitos aplicáveis forem comprovados.
8. Defeitos produzem diagnósticos e testes de regressão, não ciclos indefinidos.
9. O modelo e os especialistas utilizados são proporcionais ao risco e à complexidade.

## 3. Princípios normativos

### P-01 — Outcome-first

A unidade de entrega para trabalho de produto é um resultado observável do usuário, não apenas arquivos alterados, funções criadas ou tools registradas.

### P-02 — Vertical slices

Cada fatia deve ser pequena o suficiente para implementar, integrar e validar em um ciclo curto.

Uma fatia pode atravessar múltiplas camadas, mas deve possuir um resultado principal claramente verificável.

Como orientação inicial, preferir fatias com duração estimada de até 1–3 dias de execução; não usar a estimativa como regra rígida nem como condição automática de bloqueio.

### P-03 — Reuse-first

Reutilizar os kernels, verificadores, contratos, skills, adapters e mecanismos de telemetria existentes.

Não criar uma segunda state machine, scheduler, control plane ou sistema de permissões.

### P-04 — Proof before DONE

Compilação, CI verde, aprovação do Reviewer, relatório do Coder ou quantidade de testes executados são sinais necessários em alguns contextos, mas não comprovam isoladamente o sucesso funcional.

O resultado deve ser confrontado com um oráculo independente e com as evidências exigidas.

### P-05 — Proporcionalidade

Uma alteração trivial não deve precisar de E2E, PRD, cinco subagentes e review completo.

Uma mudança de comportamento relevante deve comprovar seu efeito. Uma mudança de alto risco exige validações adicionais.

### P-06 — Convergência

Repetir uma tentativa sem nova hipótese, nova evidência ou nova estratégia não constitui progresso.

### P-07 — Autonomia responsável

Operações locais, reversíveis e autorizadas devem avançar sem confirmações repetitivas.

Ações externas devem continuar respeitando grants, ownership, políticas e os mecanismos de review/testes já existentes.

## 4. Escopo

### Incluído

- Contrato de fatia vertical.
- Decomposição de objetivos em entregas verificáveis.
- Critérios de aceitação comportamentais.
- Mapeamento entre requisitos, código e evidências.
- Verificação funcional proporcional ao risco.
- Estados de maturidade da entrega.
- Detecção de retrabalho e ausência de progresso.
- Integração com TaskKernel, GoalKernel, EvidenceStore e Planner.
- Aproveitamento de Golden Workflows.
- Medição de custo e tempo por entrega validada.
- Compatibilidade com o roteador de modelos existente.

### Excluído nesta implementação

- Novo framework genérico de agentes.
- Segundo runtime ou scheduler.
- Novo banco de dados de orquestração.
- Novo motor de políticas ou permissões.
- Alterações evolutivas no OpenCode V1.
- Desenvolvimento de uma interface gráfica.
- Sistema completo de gestão de projetos.
- Redesenho generalizado de todos os agentes.
- Obrigatoriedade de CI remoto ou E2E para tarefas triviais.
- Alterações na lógica de negócios dos projetos consumidores.

## 5. Modelo operacional

Fluxo pretendido:

**Objective → Outcome → Vertical Slice → Technical Tasks → Implementation → Integration → Validation → DONE**

### 5.1 Objective

Representa a meta do usuário ou projeto.

Exemplo: "Entregar a V1 funcional do assistente financeiro".

### 5.2 Outcome

Representa uma capacidade utilizável.

Exemplo: "O usuário consegue registrar uma despesa conversando com o agente".

### 5.3 Vertical Slice

Representa uma entrega limitada que contribui diretamente para o Outcome.

Exemplo: "Interpretar uma despesa, selecionar a conta, executar a gravação autorizada e exibir a confirmação".

### 5.4 Technical Task

Representa uma alteração concreta de implementação ou validação.

Exemplo: "Conectar a operação selecionada pelo Agent à rota real de criação de despesas".

Não é necessário alterar a hierarquia persistida do GoalKernel se a relação puder ser representada por metadados compatíveis com o contrato atual.

## 6. Contrato de Vertical Slice

Proposta de estrutura lógica, sujeita à auditoria de schemas existentes:

| Campo | Significado |
|---|---|
| `schema_version` | Versão do contrato |
| `slice_id` | Identificador estável |
| `objective_id` | Objetivo de origem |
| `goal_id` | Goal existente, quando aplicável |
| `task_ids` | Tarefas técnicas vinculadas |
| `outcome` | Resultado esperado pelo usuário |
| `scope` | O que será entregue |
| `non_goals` | O que não será desenvolvido |
| `dependencies` | Dependências essenciais |
| `acceptance_criteria` | Critérios de aceite |
| `risk_level` | Risco da alteração |
| `validation_profile` | Verificações requeridas |
| `expected_evidence` | Evidências necessárias |
| `baseline_revision` | Revisão inicial do código |
| `target_environment` | Ambiente de validação/entrega |
| `budget` | Limites de execução |
| `evidence_refs` | Referências às provas obtidas |

Esse contrato deve ser implementado como uma extensão compatível do modelo existente, não como um segundo registro autoritativo de Goal/Task.

### 6.1 Critérios de aceitação

Cada critério deve definir:

- Identificador único.
- Pré-condições.
- Entrada ou ação do usuário.
- Resultado observável esperado.
- Oráculo ou fonte da verdade.
- Tipo de verificação.
- Obrigatoriedade para conclusão.
- Evidência associada.

Exemplo:

**AC-EXPENSE-01**

DADO que existe uma conta válida no banco de teste.

QUANDO o usuário enviar "gastei 50 de carne".

ENTÃO o agente deve interpretar a intenção de registrar despesa, obter ou inferir uma categoria compatível e preparar/executar a operação conforme a política do produto.

E a validação deve comprovar que exatamente uma despesa correta foi persistida.

O oráculo de persistência é o estado autoritativo da API/banco, não apenas o texto da resposta.

## 7. Admissão e decomposição

Antes de implementar uma fatia não trivial, o Planner deve verificar:

1. Existe um único resultado principal?
2. Os critérios de aceitação são observáveis?
3. Os contratos e dependências essenciais são conhecidos?
4. A fatia pode ser validada isoladamente?
5. Existem incertezas que exigem uma investigação delimitada?
6. O escopo inclui funcionalidades independentes que deveriam ser separadas?
7. Há infraestrutura ou funcionalidade existente que pode ser reutilizada?

Se a fatia for excessiva, o Planner deve subdividi-la preservando a rastreabilidade.

**A subdivisão não pode produzir tarefas exclusivamente horizontais que deixem toda a integração para o final.**

Exceção: uma tarefa técnica de suporte pode ser horizontal quando for uma dependência real de uma fatia e tiver seus próprios critérios verificáveis.

Definir limite inicial de WIP de uma fatia principal de produto por Goal, permitindo trabalho paralelo independente e autorizado.

## 8. Perfis de validação

### DIRECT

Para alterações triviais e reversíveis.

Requer:

- Inspeção do contexto.
- Mudança mínima.
- Verificação focada.
- Evidência honesta do resultado.

Não exige E2E por padrão.

### STANDARD

Para comportamento funcional comum.

Requer, quando aplicável:

- Teste de comportamento independente.
- Testes de unidade.
- Teste de contrato das integrações modificadas.
- Teste de integração com dependências de teste.
- Validação da jornada principal.
- Regressão proporcional ao impacto.

### HIGH_RISK

Para autorização, dinheiro, dados sensíveis, migrações, concorrência, efeitos externos e mudanças críticas.

Acrescenta:

- Invariantes e cenários de falha.
- Oráculo autoritativo dos efeitos.
- Testes de retry/idempotência quando necessários.
- Rollback ou recuperação.
- Review independente e análise de risco.
- Evidência do ambiente-alvo ou equivalente confiável.
- Proibição de tratar ausência de prova como sucesso.

A seleção de perfil deve usar a análise de risco já existente e preservar políticas de segurança vigentes.

## 9. Validação de produtos com LLM

Quando a fatia altera interpretação, raciocínio, seleção de tools ou comportamento probabilístico, adicionar avaliação específica.

Separar:

**9.1 Teste determinístico:** contratos, permissões, validação, persistência e invariantes.

**9.2 Eval de modelo:** entradas em linguagem natural, variações semânticas, erros comuns, ambiguidades e resultado esperado.

**9.3 Teste integrado:** modelo → tools → API → estado final → interface.

Evals simuladas não substituem testes com modelo real quando o comportamento real da LLM é parte crítica do aceite.

As avaliações devem registrar modelo, provider, configuração e ambiente.

Falta de credenciais/quota deve produzir `BLOCKED_EXTERNAL` ou classificação equivalente, nunca PASS.

Para jornadas críticas, todos os cenários determinísticos obrigatórios devem passar. Para comportamento probabilístico, critérios quantitativos devem ser estabelecidos antes da execução, conforme risco e tolerância do produto.

## 10. Estados de maturidade

Implementar ou projetar os seguintes estados de entrega:

- `IMPLEMENTED`: código e verificações locais concluídos.
- `INTEGRATED`: dependências e interfaces necessárias conectadas.
- `VALIDATED`: critérios de aceite obrigatórios comprovados.
- `DONE`: resultado concluído no escopo e ambiente de entrega autorizados.
- `BLOCKED`: uma dependência real impede avançar.
- `FAILED`: não foi possível concluir com os recursos/estratégias atuais.

Esses estados são **uma projeção de maturidade da fatia**.

Eles não substituem os estados persistidos do TaskKernel ou GoalKernel e não devem criar uma nova máquina de estados concorrente.

O Kernel existente continua sendo a autoridade final sobre transições de Task/Goal.

A implementação deve mapear a maturidade da fatia ao contrato atual, respeitando as condições de término já existentes.

Quando o deploy estiver fora do escopo autorizado, distinguir `VALIDATED/READY_FOR_DELIVERY` de `DEPLOYED`. Não inventar uma implantação para obter `DONE`.

## 11. Evidence Contract

Cada evidência relevante deve incluir, diretamente ou por referência ao registro existente:

- Critério de aceite.
- Tipo de teste.
- Resultado.
- Comando ou procedimento executado.
- Revisão do código.
- Ambiente e dependências importantes.
- Data da execução.
- Origem/proveniência.
- Referência a logs ou artefatos.
- Condições de invalidação.
- Identidade do validador quando relevante.

Reutilizar EvidenceStore, EvidenceRef, EvidenceFreshness, verifier e verificações já existentes.

Não construir outro EvidenceStore.

### 11.1 Regras de integridade

- Evidência de código antigo não prova o código atual.
- Evidência de harness não pode ser classificada como E2E produtivo.
- Teste com mock não prova integração real.
- Resposta textual de LLM não prova efeito no banco.
- CI verde não substitui aceite funcional.
- Critério obrigatório sem evidência não pode ser marcado como validado.
- Mudanças relevantes invalidam as evidências impactadas.
- Testes independentes não devem usar como resultado esperado aquilo que o próprio Coder acabou de produzir.

## 12. Controle de convergência

O primeiro reparo deve partir da reprodução e da causa provável.

Uma segunda tentativa deve utilizar evidência adicional ou uma hipótese distinta.

Duas tentativas sem progresso demonstrável exigem mudança de estratégia: diagnóstico estruturado, debugger, revisão de contrato ou advisor.

Uma terceira tentativa não deve ser mera repetição. Deve existir hipótese nova, teste discriminante e justificativa.

Reutilizar `OrchestrationGoalProgress`, mecanismos de stall/recovery, budgets e watchdog existentes.

O limite de tentativas não deve bloquear uma correção que está demonstrando progresso real nem transformar automaticamente um defeito localizado em replanejamento geral.

## 13. Responsabilidades

### Planner

- Define Outcomes e próximas fatias.
- Delimita escopo e não objetivos.
- Identifica dependências.
- Seleciona execução proporcional.
- Mantém continuidade entre sessões.
- Não declara DONE a partir de atestação do Coder.

### Coder

- Implementa a alteração mínima completa.
- Preserva os contratos existentes.
- Inclui testes adequados.
- Retorna referências e limitações verificáveis.

### Tester

- Verifica critérios de aceitação e efeitos.
- Distingue testes simulados, integrados e reais.
- Identifica regressões.
- Não altera expectativas para acomodar o código.

### Reviewer

- Examina qualidade, contratos, regressões e riscos.
- Classifica defeitos impeditivos separadamente de melhorias futuras.
- Não amplia o escopo sem justificativa.

### Advisor/Architect/Debugger

- São consultados quando a complexidade, o impasse ou o risco justificar.
- Não são etapas obrigatórias em todo workflow.

### Kernel/Verifier

- São as autoridades para verificação e conclusão.
- Consomem evidências, políticas e estados existentes.
- Não delegam essa autoridade à LLM.

## 14. Integração com projetos consumidores

Os projetos devem fornecer:

- Contexto do produto.
- Jornada e resultado esperado.
- Contratos técnicos existentes.
- Comandos de validação.
- Configuração de ambiente de teste.
- Cenários Golden Workflow.
- Oráculos para verificar efeitos.

Não exigir que cada projeto instale novos serviços, replique o Kernel ou mantenha cópias da política global.

Começar com integração opcional e retrocompatível, preservando o workflow já funcional.

## 15. Métricas

Coletar preferencialmente a partir da telemetria atual:

- `slice_lead_time`: tempo entre início e aceite.
- `first_pass_acceptance_rate`: fatias aceitas sem retrabalho.
- `rework_attempts`: tentativas corretivas por fatia.
- `escaped_defects`: defeitos detectados após DONE.
- `evidence_coverage`: critérios obrigatórios comprovados.
- `cost_to_validated_slice`: custo total de uma fatia validada.
- `time_to_validated_slice`: duração até validação.
- `blocked_time`: espera por dependência externa.
- `false_done_count`: casos de conclusão alegada sem requisitos atendidos.

Não registrar prompts, dados financeiros, segredos ou informações sensíveis desnecessárias na telemetria.

## 16. Critérios de aceitação desta SPEC

**AC-01:** Objective grande é subdividido em fatias com resultado e aceitação definidos.

**AC-02:** Fatia que contém somente alterações de backend sem comprovação da jornada completa não é aceita como produto integrado.

**AC-03:** Tool existente no catálogo, mas sem conexão executável, não satisfaz o critério de integração.

**AC-04:** Um teste unitário verde não substitui E2E obrigatório.

**AC-05:** Ausência de provider/modelo real não é tratada como PASS em eval obrigatória.

**AC-06:** Evidência desatualizada impede conclusão do critério afetado.

**AC-07:** Dois reparos sem progresso provocam diagnóstico, sem loop infinito.

**AC-08:** Falhas localizadas não geram automaticamente replanejamento total do Objective.

**AC-09:** Alteração trivial utiliza execução e validação proporcionais.

**AC-10:** Reviewer identifica falha real, mas melhorias opcionais não bloqueiam o MVP.

**AC-11:** Retomada após interrupção preserva fatia, decisões, evidências e próxima ação.

**AC-12:** DONE é autorizado pelo mecanismo existente, com critérios comprovados.

**AC-13:** Políticas e grants existentes continuam respeitados.

**AC-14:** Há pelo menos uma validação real em OpenCode V2 e uma integração demonstrada com um projeto consumidor.

**AC-15:** O novo workflow não cria autoridade paralela ao TaskKernel/GoalKernel.

## 17. Definition of Done do programa

O programa só está concluído quando:

- Os contratos estiverem implementados e integrados.
- Os critérios AC-01 a AC-15 estiverem rastreados.
- Os testes determinísticos exigidos estiverem aprovados.
- Os Golden Workflows relevantes estiverem validados.
- A integração com o caminho real do Planner estiver comprovada.
- Uma fatia de produto tiver sido entregue e validada pelo novo fluxo.
- O comportamento anterior continuar funcional.
- A documentação refletir o estado real.
- As evidências distinguirem claramente código implementado, integrado e comprovado em runtime.

**Princípio final:** DONE é um resultado comprovado, não uma declaração do agente.
