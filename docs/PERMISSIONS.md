# Permissões dos agentes

## Fonte canônica e propriedade

As permissões dos 19 workers têm fonte canônica em `source/agents/*.md`.
Os templates V1/V2 preservam a hierarquia rasa e as permissões do Planner;
o instalador traduz o frontmatter canônico para o dialeto do runtime.
Configurações ativas do usuário são fora do escopo desta mudança.

## Modelo vigente: shell livre, edit preservado

Por decisão explícita do usuário, todas as regras específicas `deny` e `ask`
de shell foram removidas. Cada worker usa somente `bash: "*": allow`; não há
allowlist nominal nem bloqueio de shell por comando. Isso é uma ampliação
deliberada de autoridade no shell, não uma afirmação de isolamento ou de
contenção runtime de comandos.

| Papel | `edit` | `bash` | `task` |
|---|---|---|---|
| ai-agent-engineer, automation-engineer, backend-engineer, coder, database-engineer, docs-manager, frontend-engineer, infra-engineer | allow | `*`: allow | deny |
| architect, debugger, engineering-advisor, explorer, product-designer, requirements-analyst, researcher, reviewer, security-reviewer, skeptic, tester | deny | `*`: allow | deny |

`edit: allow` continua nos oito papéis de implementação; `edit: deny` nos
outros onze bloqueia a ferramenta de edição conforme o papel. Para papéis
read-only, instruções comportamentais continuam proibindo
alterações, embora shell irrestrito não constitua barreira técnica contra
escrita por comando. `task: deny` mantém workers sem subdelegação.
No V2, `subagent: * deny` nos workers permanece no template para garantir
hierarquia rasa; os 19 `allow` de `build` também permanecem.

## Decisão e limites

As antigas allowlists de leitura, negações nomeadas e confirmações `ask` para
shell foram removidas por decisão do usuário. Não as descreva como proteção
runtime ou como restrições vigentes. As instruções dos agentes, o Dispatch
Contract, a autorização do Planner e as confirmações separadas para efeitos
destrutivos, credenciais e produção continuam aplicáveis, mas não substituem
uma negação de shell no runtime.

Permissão de ferramenta não concede autoridade para ampliar o escopo delegado,
alterar produção, operar credenciais, enviar comunicações externas ou ignorar
gates do Task Kernel. `PRODUCTION_AUTHORIZED` ausente equivale a `false`;
mesmo `true` não autoriza por si só ação destrutiva irreversível nem gestão de
credenciais. `CREDENTIAL_SCOPE` contém identificadores, nunca segredos.

## Tradução V1/V2

O frontmatter traduz `edit` para `edit`, `bash` para `shell` e `task` para
`subagent`. Em ambos os dialetos, o catch-all de shell é `allow`; `task: deny`
é mantido nos workers. Os modelos e tokens dos perfis não são alterados por
esta mudança.

Templates V1/V2 mantêm a profundidade de subagentes em 1, os denies de
subdelegação para workers e os allows do Planner para os agentes previstos.
Esta decisão não altera permissões de topo, MCP, plugins nem a configuração
ativa do runtime.

## Enforcement e ressalvas

Permissões de ferramenta descrevem o controle do runtime sobre a rota de tool;
não se deve inferir contenção de outras superfícies, como APIs REST, nem
atribuir ao Kernel enforcement de runtime quando a flag correspondente está
desligada. Grants do Kernel são registro/decisão de autoridade e não substituem
permissões do runtime.

O Task Kernel mantém os controles de autoridade existentes:

- Grants efetivos resultam da interseção entre baseline do papel, grants da
  task, capacidade do runtime e autorização de ambiente.
- Workers retornam `candidate_pass`, `failed` ou `blocked`; somente o
  verificador emite `verified_pass` e somente o Kernel conclui `DONE`.
- Ações destrutivas irreversíveis e criação, revogação ou rotação de
  credenciais exigem confirmação separada do Planner.

Estado e evidências de runtime permanecem em
`evidence/v3.1/kernel-hardening/runtime-binding.json` e nos registros de
confiabilidade. Nenhuma capacidade ou garantia adicional é alegada aqui.
