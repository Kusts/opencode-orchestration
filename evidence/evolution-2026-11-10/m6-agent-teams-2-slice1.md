# M6 Agent Teams #2 - fatia 1

## Escopo entregue

Task Kernel registra membros vinculados a um run, com papel canonico e
capacidade de liberacao. O conjunto de papéis corresponde aos basenames de
`source/agents/*.md`. A persistencia e aditiva em `team`, limitada a oito
membros ativos e dezesseis entradas historicas.

## Gate e limites

O coordenador so existe quando `active_execution_owner` nao esta vazio e
corresponde ao `root_session` de um run attached. Owner vazio nao faz fallback:
handback libera a coordenacao ate uma sessao raiz fazer bind. Worker sessions
sao subordinadas e podem ser vinculadas mesmo enquanto outra raiz e owner;
bind de worker nao altera o owner, e o conflito de owner continua para bind
de raiz. Owner que aponta para worker ou raiz de run detached nao coordena.
`CoordinatorSessionId` e obrigatorio. A identidade e afirmada pelo chamador,
no mesmo modelo de `bind-session`: o gate bloqueia worker de agir como
coordenador, mas nao prova criptograficamente a origem da sessao. Membro nao
se torna coordenador (depth 1).
Esta entrega nao faz spawn, execucao, permissao, assentos, reatribuicao,
telemetria nem enforcement no plugin. Bindings e handback permanecem sem
alteracoes contratuais.

## Erros

`TEAM_NOT_COORDINATOR`, `TEAM_ROLE_INVALID`, `TEAM_MEMBER_NOT_BOUND`,
`TEAM_MEMBER_CONFLICT`, `TEAM_LIMIT_EXCEEDED` e `TEAM_MEMBER_NOT_FOUND`.
Persistencia usa CAS, lock, protecao de caminho e recusa estado terminal.

## Validacao

Suite focada: 48 asserts, PASS em Windows PowerShell 5.1 e pwsh. Bindings:
32/32 em ambos (inclui binding de worker subordinado sem takeover do owner).
Handback: 24 asserts em ambos. Package-consistency: 17/17;
`git diff --check` limpo. Inclui integração pura via CLI:
create -> bind root -> bind worker -> team-add.
