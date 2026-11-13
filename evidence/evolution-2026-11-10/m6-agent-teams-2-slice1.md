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
sao subordinadas e so podem entrar em run ja enraizado. Com owner ativo,
`-ParentSessionId` deve corresponder ao owner, que tambem precisa ser a raiz do
run alvo; bind de worker nao altera o owner. A regra anterior que recusava
worker bind sob owner ativo foi substituida por este gate de parent explicito.
Bind de raiz em run enraizado com outra sessao exige `rebind-session`; rebind
nao toma coordenacao de outro owner ativo. Owner que aponta para worker ou
raiz de run detached nao coordena.
`CoordinatorSessionId` e obrigatorio. A identidade e afirmada pelo chamador,
no mesmo modelo de `bind-session`: o gate bloqueia worker de agir como
coordenador, mas nao prova criptograficamente a origem da sessao. Membro nao
se torna coordenador (depth 1). Quando o owner esta vazio (por exemplo, apos
handback/detach), qualquer chamador pode fazer bind de raiz e tornar-se
coordenador. Essa janela e conhecida: a identidade continua sendo afirmada,
nao autenticada criptograficamente pelo Kernel.
Esta entrega nao faz spawn, execucao, permissao, assentos, reatribuicao,
telemetria nem enforcement no plugin. Bindings e handback seguem seus
contratos atualizados descritos acima.

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
