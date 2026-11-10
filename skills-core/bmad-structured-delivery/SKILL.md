---
name: bmad-structured-delivery
description: Use for ambiguous or multi-phase features, requirements that mix product and implementation, or work that needs decomposition into vertical slices with observable acceptance. Skip clear single edits, cosmetic changes, and pure bug diagnosis.
license: MIT
---

# BMAD Structured Delivery

Técnica inspirada no BMAD Method (linha estável v6.12). Texto original; nenhum
conteúdo upstream foi copiado. Não cria um segundo Planner nem concede
autoridade: estrutura o trabalho para o Planner existente.

## Quando carregar

- o pedido mistura produto e implementação;
- o requisito é ambíguo ou tem múltiplas interpretações materiais;
- a entrega tem fases dependentes e o caminho até o resultado não está claro;
- é preciso decompor uma feature em fatias verificáveis.

Não carregue para edição clara de um arquivo, ajuste cosmético ou diagnóstico
de bug já localizado.

## 1. Contrato antes da decomposição

Declare, em poucas linhas:

- resultado observável e para quem;
- não-objetivos explícitos;
- critérios de aceite testáveis;
- restrições (prazo, ambiente, compatibilidade, dados);
- incógnitas materiais e como resolvê-las.

Não invente requisito para preencher lacuna. Se uma decisão mudar o aceite, o
escopo ou o risco, ela é do usuário; continue o trabalho independente enquanto
ela não bloqueia.

## 2. Decomposição em fatias verticais

Cada fatia deve atravessar o caminho necessário para produzir comportamento
observável — não uma camada isolada. Para cada fatia, registre:

| Campo | Conteúdo |
| --- | --- |
| Resultado | comportamento que passa a existir |
| Aceite | verificação objetiva |
| Dependências | fatias, contratos ou dados necessários |
| Risco | impacto e reversibilidade |
| Evidência | teste, medição ou artefato que prova o aceite |

Prefira poucas fatias reais a um backlog inflado. Uma fatia sem aceite
observável é uma tarefa, não uma entrega.

## 3. Sequenciamento

- Dependência dura primeiro; valor independente em paralelo quando houver
  ganho real.
- Contratos compartilhados antes dos consumidores.
- Migrações e mudanças irreversíveis exigem plano de recuperação.
- A primeira fatia deve provar o caminho feliz ponta a ponta; endurecimento
  vem depois, guiado por risco.

## 4. Guardrails

- Não crie PRD, ticket ou cerimônia quando o pedido já está claro.
- Não transforme a decomposição em novas autoridades, agentes ou estado.
- Não marque uma fase como concluída sem a evidência do aceite.
- Não reinicie a descoberta quando a especificação vigente já responde.
- Preserve trabalho existente e decisões já tomadas.

## 5. Saída mínima

Objetivo, não-objetivos, fatias ordenadas com aceite/evidência, riscos e a
próxima ação. Se o trabalho couber em uma fatia direta, diga isso e devolva a
execução ao método principal.
