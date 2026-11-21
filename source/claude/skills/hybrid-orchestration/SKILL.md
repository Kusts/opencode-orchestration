---
name: hybrid-orchestration
description: >-
  Coordena missões de desenvolvimento de várias etapas com Claude como coordenador,
  Orca como supervisor e OpenCode como executor técnico. Use quando o pedido for uma
  missão ou objetivo com múltiplas etapas (implementar + testar + revisar + entregar),
  trabalho que exige delegar ao OpenCode / "opencode-orchestration", workers
  supervisionados, tarefas paralelas ou longas, retomar uma missão interrompida, ou
  quando o usuário disser "missão", "delegue", "coordene", "hybrid", "worker_done".
  É somente para o coordenador Claude; um worker despachado (prompt com Task e Dispatch
  IDs) não usa esta skill — ele segue o próprio preamble e o contrato do spec.
  Multi-step development mission, delegate to OpenCode via Orca, resume a mission.
  NÃO use para tarefa simples de um passo (edição pequena, pergunta, leitura): resolva
  direto ou rode o OpenCode diretamente.
---

# Orquestração híbrida: Claude + Orca + OpenCode

Escopo: instrução operacional do **coordenador Claude**. Um worker despachado tem
Task/Dispatch IDs no prompt e segue o preamble do Orca; não carrega esta skill.

Divisão de papéis (não duplicar estado, planejamento nem verificação):

- **Claude (você)**: entende o objetivo, planeja, decide o que delegar, verifica
  evidências, replaneja, conclui. Em missão híbrida **não implementa**.
- **Orca**: Runs/Tasks/Dispatches, inicia o primário `build`, entrega `worker_done`,
  desperta você. O estado vive no Orca, não em notas suas.
- **OpenCode**: o `build` escolhe especialistas e delega toda escrita; planejamento
  técnico interno, modelos e verificações são dele — não os repita.

## 0. Escolha o modo

| Situação | Modo |
|---|---|
| Pergunta/leitura, ou edição trivial em repo sem política de worker | Direto (sem worker) |
| Tarefa simples e autocontida | OpenCode direto ou 1 worker via Orca |
| Missão multi-etapa, paralela, longa ou com revisão independente | **Híbrido** |

Neste repo (`opencode-orchestration`) toda escrita vai a worker.
Na dúvida, escolha o modo mais barato que ainda comprove o resultado.

## 1. Carregue o guia do Orca (uma vez)

```text
orca skills get orchestration --full
orca orchestration worker-start --help
```

O guia instalado é fonte de verdade para comandos, recibos (`next`, `failedStage`),
encerramento de workers e recuperação. Esta skill só acrescenta o laço e as regras de
decisão. Contrato do Dispatch (spec + placement): `references/opencode-contract.md`.

## 2. Laço: PLANEJAR → DELEGAR → ACOMPANHAR → VERIFICAR → DECIDIR → CONCLUIR

**PLANEJAR** — Objetivo, critérios verificáveis (comando + saída) e recorte em Tasks
com `run-create --objective` e `task-create --deps`. Planeje o *quê* e o *aceite*.

**DELEGAR** — Um objetivo completo por worker, spec autocontido (contrato em
`references/opencode-contract.md`). Placement explícito: `current` só para leitura ou
escritor único em checkout exclusivo; `new-child` para escritores concorrentes ou
checkout compartilhado; `new-top-level` para trabalho independente. Fases dependentes
reutilizam o mesmo worktree e branch. Inicie o primário `build` com `--agent opencode2`
(ou `opencode`, conforme `--help`), **sem `--model`**. Workers independentes iniciam
juntos; depois **encerre o turno**.

**CONFIRMAR A EXECUÇÃO** — Uma rodada curta após cada `worker-start` e cada retry:
`worker-show --json` e `worker-read --limit 50 --json` (`--source transcript` quando
faltar evidência). `ready`/`input_accepted`/`activity=working` não provam turno
iniciado. Os 5 casos e a regra de HOLD estão em `references/dispatch-confirmation.md`.

**CONFIRMAR O PLACEMENT** — Após cada Dispatch e retry, verifique repo, caminho,
branch e base Git reais. `--retry-of` não herda placement. Parentesco na UI do Orca
não prova ancestralidade Git. Detalhes em `references/opencode-contract.md`.

**ACOMPANHAR** — Sem polling. O Orca acorda você com `worker_done`, `ask` ou
`escalation`. Responda `ask` por `reply` quando a resposta decorre do objetivo; senão
pergunte ao usuário.

**VERIFICAR** — `worker_done` e mensagens de sucesso **não são prova**. Leia evidência
(diff, saída de testes) e confronte cada critério. Reexecute checagens só diante de
lacuna ou contradição.

**DECIDIR / CONTINUAR** — Critério atendido: aceite e integre. Falha: `send` ao mesmo
worker com a evidência. 2ª falha: nova hipótese ou outro papel. Continue sem pedir
confirmação por subtarefa até o aceite ou bloqueio real.

**CONCLUIR** — Só com todos os critérios comprovados. Checklist do coordenador:

1. **Worker liberado após integração**: siga `next` do `worker-list`; workers em
   `current` fecham sozinhos após `worker_done` aceito (auto-release ~2 min quando o
   runtime o anuncia); `new-child`/`new-top-level` ficam abertos — rode
   `worker-release --dispatch <id>` e confirme no `worker-list`. `worker-release`
   **não** remove worktree. Não libere worker não-concluído; estado ambíguo ⇒
   reconcilie conforme `references/resume.md`, sem duplicar.
2. **Integração verificada**: PR/checks/merge confirmado, `git pull --ff-only` na base,
   worktree e branch limpos. Squash merge não aparece como ancestral: prove pelo
   estado da PR e pela ausência de commits locais inéditos. CI verde não é merge.
3. **Higiene**: remova só worktrees e branches da missão (`git worktree remove` sem
   `--force`, se limpos e mesclados). Preserve stashes e trabalho pré-existente ou de
   terceiros; relate removidos e preservados no relatório final.

## 3. Retomada

Reconstrua do Orca (`run-current`/`run-list`, `task-list`, `worker-list`, `inbox`),
transcript e `git diff` — nunca da memória. Detalhes em `references/resume.md`.

## 4. Limites

- Sem daemon, polling, fila própria, segundo kernel ou hooks novos.
- JEV é opcional e consultivo.
- Neste repo, `AGENTS.md` prevalece: quem coordena não edita; escrita vai a worker com
  teste focado.
- Segredos nunca em spec, log ou relatório.
