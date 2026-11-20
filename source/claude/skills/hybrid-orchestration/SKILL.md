---
name: hybrid-orchestration
description: >-
  Coordena missões de desenvolvimento de várias etapas com Claude como coordenador,
  Orca como supervisor e OpenCode como executor técnico. Use quando o pedido for uma
  missão ou objetivo com múltiplas etapas (implementar + testar + revisar + entregar),
  trabalho que exige delegar ao OpenCode / "opencode-orchestration", workers
  supervisionados, tarefas paralelas ou longas, retomar uma missão interrompida, ou
  quando o usuário disser "missão", "delegue", "coordene", "hybrid", "worker_done".
  Multi-step development mission, delegate to OpenCode via Orca, resume a mission.
  NÃO use para tarefa simples de um passo (edição pequena, pergunta, leitura): resolva
  direto ou rode o OpenCode diretamente.
---

# Orquestração híbrida: Claude + Orca + OpenCode

Divisão de papéis (não duplicar estado, planejamento nem verificação):

- **Claude (você)**: entende o objetivo, planeja, decide o que delegar, verifica
  evidências, replaneja, conclui.
- **Orca**: Runs/Tasks/Dispatches, inicia workers, entrega `worker_done`, desperta você.
  O estado vive no Orca, não em notas suas.
- **OpenCode**: executa o objetivo técnico com seus próprios agentes, skills e MCPs
  (planejamento técnico interno é dele; não o repita).

## 0. Escolha o modo (antes de tudo)

| Situação | Modo |
|---|---|
| Pergunta, leitura, edição trivial | Direto, sem worker |
| Tarefa simples e autocontida de código | OpenCode direto (`opencode run`) ou 1 worker |
| Missão multi-etapa, paralela, longa ou que precisa de revisão independente | **Híbrido** (abaixo) |

Na dúvida entre direto e híbrido, escolha o mais barato que ainda comprove o resultado.

## 1. Carregue o guia oficial do Orca (não o copie)

O guia muda com a versão instalada. Leia no início da missão, uma vez:

```text
orca skills get orchestration --full
orca orchestration worker-start --help
```

Contrato do spec para o OpenCode: `references/opencode-contract.md`. Siga o guia do Orca como fonte de verdade para comandos, `next` dos recibos e recuperação.
Esta skill só acrescenta o laço e as regras de decisão.

## 2. Laço: PLANEJAR → DELEGAR → ACOMPANHAR → VERIFICAR → DECIDIR → CONTINUAR → CONCLUIR

**PLANEJAR** — Defina objetivo, critérios de aceite objetivos e verificáveis (comando +
saída esperada) e o recorte em tasks. Planeje o *quê* e o *aceite*, não o *como* técnico.
Crie `run-create --objective` e `task-create` (use `--deps` para DAG).

**DELEGAR** — Um objetivo completo por worker, com spec autocontido: alvo, mudança,
escopo de escrita, restrições, evidência exigida, o que é proibido, e se exit ≠ 0 é
falha. Agente OpenCode: `--agent opencode2` (ou `opencode`, conforme `worker-start --help`),
`--worktree current`, sem `--model` (o roteamento de modelos é do OpenCode). Tarefas
independentes iniciam juntas; depois **encerre o turno**.

**Confirme a EXECUÇÃO (P0, após cada `worker-start`)** — `ready`, `input_accepted` e
`activity=working` NÃO provam que o OpenCode submeteu a tarefa. Faça uma verificação curta
(`worker-show --json`, `worker-read --limit 50 --json`, `orca terminal read` só se faltar
evidência) e só então aguarde o `worker_done`. Os 5 casos (executou / digitado e não
submetido / prompt ausente / Dispatch sem execução / estado ambíguo) e a recuperação
estão em `references/dispatch-confirmation.md` — leia antes de agir. Regra: comprovadamente
não iniciado ⇒ recupere; estado desconhecido ⇒ HOLD e reconcilie, **nunca duplique**.

**ACOMPANHAR** — Não faça polling nem scripts de espera. O Orca desperta você com
`worker_done`, `ask` ou `escalation`. Responda `ask` por `reply` quando a resposta decorre
do objetivo; senão pergunte ao usuário.

**VERIFICAR** — `worker_done` e mensagens de sucesso **não são prova**. Leia a evidência
(`worker-read`, diff, saída de testes) e confronte com cada critério de aceite. Reexecute
checagens só diante de lacuna ou contradição. Ações irreversíveis ou fora do escopo
autorizado exigem confirmação específica do usuário.

**DECIDIR / CONTINUAR** — Critério atendido: aceite. Falhou: envie a correção ao mesmo
worker por `send` (com a evidência da falha). 2ª falha: nova hipótese ou outro worker
(debugger/reviewer). Incerteza estrutural: replaneje. Continue sem pedir confirmação por
subtarefa até o aceite ou até um bloqueio real (credencial, decisão humana, ação destrutiva).

**CONCLUIR** — Só com todos os critérios comprovados. Relate por task: resultado,
evidência, pendências. Preserve evidências relevantes no repositório/registro existente.
Checklist de encerramento (responsabilidade do coordenador, ao longo e ao fim da missão):

1. **Fechar os workers que criou:** após aceitar a evidência de cada worker, rode
   `orca orchestration worker-release --dispatch <id>` e confirme com `worker-list`
   (`terminalState=released`, `liveness=exited`). Somente workers iniciados com
   `--worktree current` fecham sozinhos; os de `--worktree new-child`/`new-top-level`
   ficam abertos por padrão. Use `worker-keep-open` só se o usuário for usar o chat.
   Não libere worker não-concluído; falha/estado ambíguo ⇒ `worker-stop`/reconciliação
   conforme `references/resume.md`, sem duplicar.
2. **Merge:** faça o merge das PRs/branches criadas pela missão somente com CI verde
   completo e critérios de aceite comprovados — nunca com CI pendente/vermelho.
   `gh pr checks` é pontual, sem laço de espera/polling.
3. **Higiene:** após o merge, remova worktrees filhos (Orca ou `git worktree remove`
   sem `--force`, só se limpos e totalmente mesclados) e branches locais/remotas
   mescladas que a missão criou. Nunca apague trabalho não mesclado, stashes, branches
   ou worktrees pré-existentes/de terceiros. Relate o que foi removido e o que ficou
   (e por quê) no relatório final. Ações irreversíveis fora do que a missão criou
   exigem confirmação.

## 3. Retomada após interrupção

Reconstrua do Orca (`run-current`/`run-list`, `task-list`, `worker-list`, `inbox`), transcript
e `git diff`, nunca da memória; distinga conclusão de worker, de Task e de missão. Detalhes e
regras em `references/resume.md`. Worker vivo/`unverifiable` não autoriza reinício.

## 4. Limites

- Sem daemon, polling, fila própria, segundo kernel de tasks ou hooks novos: o despertar
  por `worker_done` e os hooks nativos do Orca já existem.
- JEV é opcional, consultivo, apenas para decisões complexas.
- Neste repo (`opencode-orchestration`), respeite o `AGENTS.md`: quem coordena não edita;
  escrita vai a worker com teste focado.
- Segredos nunca em spec, log ou relatório.
- Encerrar workers concluídos, mesclar e limpar worktrees/branches criados pela missão
  é dever do coordenador no CONCLUIR: nunca liberar worker não-concluído, mesclar com
  CI pendente/vermelho ou apagar trabalho pré-existente/de terceiros.
