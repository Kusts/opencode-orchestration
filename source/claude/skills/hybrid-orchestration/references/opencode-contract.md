# Contrato Claude → OpenCode (spec e placement do Dispatch)

## 1. Spec do worker

Delegue **um objetivo completo** por worker; o planejamento técnico interno é do
OpenCode. O spec é autocontido (o worker não vê esta conversa) e usa os campos do
contrato do repositório de orquestração (não inventar outro schema):

```text
TASK_ID: <id da task Orca>
OBJECTIVE: <resultado esperado, não o passo a passo>
READ_SCOPE: <caminhos/áreas que pode ler>
WRITE_SCOPE: <caminhos que pode alterar; vazio = somente leitura>
ACCEPTANCE_CRITERIA: <critérios objetivos: comando + saída esperada; exit != 0 = falha>
VALIDATION: <como provar (testes focados, git diff --check)>
PROHIBITED_OPERATIONS: <ex.: padrão do build despachado abaixo>
RETURN_FORMAT: candidate_pass | failed | blocked + refs de critério + evidência
ESCALATION_CONDITIONS: <quando parar e perguntar: ambiguidade, credencial, ação irreversível>
ALLOWED_ENVIRONMENT / PRODUCTION_AUTHORIZED / CREDENTIAL_SCOPE: <opcionais; ausência = false/vazio>
```

PROHIBITED_OPERATIONS padrão para o `build` despachado (preâmbulo Orca com
`TASK_ID`/Dispatch IDs): `worker-start`, `task-create`, `dispatch`, skill
`hybrid-orchestration`, escrita direta de arquivos (use `subagent`, inclusive
em edição trivial), push/PR/merge, install no perfil real, alteração de
flags/pins e segredos. Do Orca, somente `check`, `ask` e `worker_done`.

## 2. Papéis e modelo

Dentro de missão híbrida o Claude não implementa: o Orca inicia o primário `build`
(`--agent opencode2` ou `opencode`, conforme `worker-start --help`), e o `build`
escolhe especialistas e delega toda escrita. **Sem `--model`**: a policy do OpenCode
decide (T1/T2 vigentes, T3 Terra, T4 Sol proof-gated; fonte
`source/registry/model-routing-policy.json`). Prova de delegação e de modelo: consulta SOMENTE LEITURA às tabelas `session_v2` (`parent_id`, `agent`) e `session_message` (`model`) do banco `%APPDATA%\orca\managed-data-accounts\opencode\<conta>\data\opencode\opencode.db`, sem imprimir conteúdo de mensagens nem tocar nas tabelas de conta ou credencial.


## 3. Placement (explícito em todo Dispatch)

| Situação | Placement |
|---|---|
| Leitura, ou único escritor em checkout exclusivo | `current` |
| Escritores concorrentes, ou checkout do coordenador compartilhado | `new-child --name <curto>` |
| Trabalho independente que não volta ao coordenador | `new-top-level --repo id:<repoId> --name <curto>` |

- Fases dependentes reutilizam o mesmo worktree e branch; não crie outro para a fase
  seguinte.
- Retry (`--task <id> --retry-of <dispatch>`) **não herda placement**: repita
  `--worktree`/`--agent` (e `--on`, se remoto).
- Após cada Dispatch e retry, verifique repo, caminho, branch e base Git reais
  (`orca worktree list`, `git -C <path> rev-parse --abbrev-ref HEAD`, `git status`).
  Parentesco na UI do Orca não prova ancestralidade Git.
- Worktrees novos são criados pelo `worker-start`; worker em worktree novo fica aberto
  — libere após integração (`worker-release --dispatch <id>`), sem `--force` na limpeza.

## 4. Comunicação e evidência

Worker retorna `candidate_pass | failed | blocked` com refs de critério; **quem
verifica é você** (evidência vs cada critério). `worker_done` e mensagem de sucesso
não são prova. Comunicação do worker: `orca orchestration ask/send/worker_done` pelo
próprio terminal; você responde `ask` por `reply` quando a resposta decorre do
objetivo. Não microgerencie. Segredos nunca no spec; use identificadores.
Neste repo, `AGENTS.md` prevalece: quem coordena não edita; escrita vai a worker com
teste focado. Falha 2x ⇒ nova hipótese ou outro papel (debugger/reviewer).
