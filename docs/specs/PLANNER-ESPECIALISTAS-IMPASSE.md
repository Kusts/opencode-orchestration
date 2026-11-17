# Planner: especialistas para impasses

## Objetivo e limites

Este documento orienta o Planner a selecionar pareceres quando uma dúvida ou
impasse justificar consulta. O Planner mantém o controle: especialistas e
ferramentas consultivas oferecem evidências e alternativas, mas não escolhem
nem autorizam ações em seu lugar. Consultas são opcionais, proporcionais ao
problema e não substituem contratos de tarefa, verificações ou gates existentes.

## Matriz situação → recurso

| Situação observada | Recurso preferencial | Uso |
|---|---|---|
| Dúvida simples entre alternativas, com evidência suficiente | Decisão direta do Planner | Evitar consulta desnecessária. |
| Dúvida delimitada que se beneficie de parecer rápido | **MCP JEV** (jev_check/jev_classify/jev_decide/jev_gate/jev_score) | Capacidade disponível e verificada neste runtime; parecer advisory, não autoriza ferramenta. |
| Decisão arquitetural complexa | Architect | Examinar limites, alternativas e consequências; Planner decide. |
| Viabilidade técnica, manutenção ou impasse estratégico | Engineering Advisor | Parecer sobre viabilidade, custo de manutenção e opções. |
| Bug persistente ou falha reproduzível | Debugger | Diagnosticar com reprodução e evidências; correção continua sujeita ao fluxo normal. |
| Evidências contraditórias | Engineering Advisor ou JEV, conforme a natureza da divergência | Advisor para análise técnica/estratégica; JEV para parecer delimitado. Não repetir consultas sem evidência nova. |

MCP JEV está disponível e verificado neste runtime (`jev_check`,
`jev_classify`, `jev_decide`, `jev_gate`, `jev_score`). Correção terminológica
(2026-11-17, operador): a denominação incorreta que apareceu no adendo era erro
de digitação; o recurso é o MCP JEV. Seu resultado é advisory: não concede
permissões, não autoriza ferramentas e não substitui a decisão do Planner,
verificação, revisão ou Kernel. A disponibilidade de uma ferramenta não
significa que toda dúvida deva ser encaminhada a ela.

## Regras de consulta

1. O Planner identifica a dúvida e reúne primeiro as evidências existentes.
2. Consulta um especialista apenas quando a dúvida justificar parecer; escolhe
   o recurso mais específico da matriz e faz uma pergunta delimitada.
3. Evita consultas duplicadas sobre a mesma questão. Uma nova consulta requer
   evidência nova ou uma pergunta materialmente diferente.
4. O especialista retorna análise, alternativas, pressupostos e incertezas;
   não assume controle nem amplia o escopo.
5. O Planner avalia o parecer contra as evidências e instruções vigentes,
   escolhe a ação e delega a implementação pelo fluxo autorizado.
6. Falha ou indisponibilidade do consultor não bloqueia por si só: usar as
   evidências disponíveis, outro recurso adequado ou declarar o bloqueio.
7. Um parecer nunca é autorização de ferramenta ou permissão, nem substitui
   validação, Reviewer, Security Reviewer ou decisão do Kernel.

## Teste funcional proposto (não executado nesta fatia)

Simular um impasse controlado e verificar a sequência:

1. Planner identifica e delimita o problema, com evidências disponíveis.
2. Planner seleciona e consulta o recurso apropriado conforme a matriz.
3. O recurso retorna alternativas e incertezas, sem instrução de autoridade.
4. Planner compara o parecer com as evidências e escolhe uma alternativa.
5. Planner delega a correção com escopo e critérios de aceitação explícitos.
6. O resultado é validado pelos verificadores aplicáveis; parecer consultivo
   não conta como validação.
7. Planner continua o fluxo conforme o resultado, sem tratar a consulta como
   autorização ou conclusão.

Critérios observáveis: seleção coerente do recurso; ausência de consultas
redundantes sem evidência nova; decisão atribuída ao Planner; delegação dentro
do escopo; validação independente; e continuação ou bloqueio fundamentado.
Este roteiro é uma proposta de teste, não evidência de execução ou de
integração funcional nova.
