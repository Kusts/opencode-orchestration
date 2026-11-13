# M6 Agent Teams #2 - fatia 1

## Escopo entregue

Task Kernel registra membros vinculados a um run, com papel canonico e
capacidade de liberacao. O conjunto de papéis corresponde aos basenames de
`source/agents/*.md`. A persistencia e aditiva em `team`, limitada a oito
membros ativos e dezesseis entradas historicas.

## Gate e limites

O coordenador e `active_execution_owner`; quando vazio, e a sessao raiz do
run attached mais recente. `CoordinatorSessionId` e obrigatorio. A identidade
e afirmada pelo chamador, no mesmo modelo de `bind-session`: o gate bloqueia
worker de agir como coordenador, mas nao prova criptograficamente a origem.
Membro nao se torna coordenador (depth 1).
Esta entrega nao faz spawn, execucao, permissao, assentos, reatribuicao,
telemetria nem enforcement no plugin. Bindings e handback permanecem sem
alteracoes contratuais.

## Erros

`TEAM_NOT_COORDINATOR`, `TEAM_ROLE_INVALID`, `TEAM_MEMBER_NOT_BOUND`,
`TEAM_MEMBER_CONFLICT`, `TEAM_LIMIT_EXCEEDED` e `TEAM_MEMBER_NOT_FOUND`.
Persistencia usa CAS, lock, protecao de caminho e recusa estado terminal.

## Validacao

Suite focada: 36 asserts, PASS em Windows PowerShell 5.1 e pwsh. Bindings:
29/29 em ambos. Handback: 24 asserts em Windows PowerShell 5.1. Event:
7 suites PASS. Package-consistency: 17/17; `git diff --check` limpo.
