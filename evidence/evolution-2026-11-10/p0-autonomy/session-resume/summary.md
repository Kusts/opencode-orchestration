# P0.6 — Retomada real de sessão OpenCode (2026-11-11)

**Sessão experimental:** `ses_e33ea8cdcffeiZrUtkt0puBPS3` (descartável; criada por `opencode run`, não é a sessão do Planner).
**Mecanismo:** `opencode run --session <id> --format json` (recurso nativo; nenhum controlador novo).

## Passos

1. `opencode run --format json "Reply with exactly the token RESUME_STEP1..."` → processo novo, sessão `ses_e33ea8cdcffeiZrUtkt0puBPS3`, resposta `RESUME_STEP1`; tokens input 47313 / output 7 / cache read 512 (step1.json).
2. Processo encerrado. `opencode run --session ses_e33ea8cdcffeiZrUtkt0puBPS3 --format json "Without using tools, reply with only the exact token you sent in your previous message."` → resposta `RESUME_STEP1`; tokens input 108 / output 7 / cache read 47744 (step2.json).

## Conclusão

- A segunda execução foi um processo novo que retomou a mesma sessão nativa e recuperou o contexto da primeira (token exato), sem repetir a tarefa e sem intervenção humana.
- O cache read de 47744 tokens na retomada é evidência observada de reuso de contexto (#11), não um valor inventado.
- Limite: a sessão do Planner não foi encerrada; a prova usa uma sessão descartável e o recurso nativo. O Goal correspondente (`p0-autonomy-session-20261111`) registra T1/T2/T3 e conclui por CAS.
