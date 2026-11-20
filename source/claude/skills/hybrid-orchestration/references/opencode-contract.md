# Contrato Claude → OpenCode (spec do worker)

Delegue **um objetivo completo** por worker; o planejamento técnico interno é do OpenCode.
O spec é autocontido (o worker não vê esta conversa) e usa os campos do contrato do
repositório de orquestração (não inventar outro schema):

```text
TASK_ID: <id da task Orca>
OBJECTIVE: <resultado esperado, não o passo a passo>
READ_SCOPE: <caminhos/áreas que pode ler>
WRITE_SCOPE: <caminhos que pode alterar; vazio = somente leitura>
ACCEPTANCE_CRITERIA: <critérios objetivos: comando + saída esperada; exit != 0 = falha>
VALIDATION: <como provar (testes focados, git diff --check)>
PROHIBITED_OPERATIONS: <ex.: commit, push, instalar, escrita global, segredos>
RETURN_FORMAT: candidate_pass | failed | blocked + refs de critério + evidência
ESCALATION_CONDITIONS: <quando parar e perguntar: ambiguidade, credencial, ação irreversível>
ALLOWED_ENVIRONMENT / PRODUCTION_AUTHORIZED / CREDENTIAL_SCOPE: <opcionais; ausência = false/vazio>
```

Regras:
- Worker retorna `candidate_pass | failed | blocked`; **quem verifica é você** (evidência vs
  cada critério). `worker_done` e mensagem de sucesso não são prova.
- Agente: `--agent opencode2` (ou `opencode`, conforme `worker-start --help`), `--worktree
  current`; **sem `--model`** — a policy de modelos do OpenCode decide (T1/T2 vigentes,
  T3 = Terra, T4 = Sol, Astra excepcional e proof-gated; fonte:
  `source/registry/model-routing-policy.json`).
- Comunicação do worker: `orca orchestration ask/send/worker_done` pelo próprio terminal;
  você responde `ask` por `reply` quando a resposta decorre do objetivo.
- Não microgerencie: nada de listar comandos internos nem repetir o plano técnico.
- Segredos nunca no spec; use identificadores.
- Neste repo, `AGENTS.md` prevalece: quem coordena não edita; escrita vai a worker com
  teste focado. Falha 2x ⇒ nova hipótese ou outro papel (debugger/reviewer).

Prova de modelo efetivo: `opencode session export <id>` → `model.id`/`providerID`.
