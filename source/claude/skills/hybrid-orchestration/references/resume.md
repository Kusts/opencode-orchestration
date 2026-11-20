# Retomada e distinção de conclusão

Reconstrua do estado real, não da memória:

```text
orca orchestration run-current            # ou run-list
orca orchestration run-show --run <id>
orca orchestration task-list --run <id>
orca orchestration worker-list --run <id> --include-remote
orca orchestration inbox --terminal run:<id> --limit 50
```

Fontes que já existem (não crie outro banco/memória): Orca (Runs/Tasks/Dispatches),
transcript do worker (`worker-read --source transcript`), `git status/diff`, Task/Goal
Kernel do OpenCode e AI Memory (decisões anteriores, consulta opcional).

Três conclusões distintas:
- **Worker**: `worker_done` — sinal, não prova.
- **Task**: critérios de aceite comprovados por evidência que você leu.
- **Missão**: todas as tasks aceitas + objetivo original atendido + pendências relatadas.

Por task: já `completed` com evidência → não refaça; worker vivo/`unverifiable` → não
reinicie (silêncio/timeout não prova saída); ausente/não iniciado comprovado → despache;
efeito parcial no `git diff` → reconcilie antes de qualquer retry. Nunca crie Run/Task
novo para contornar circuit breaker nem use `reset` sem o usuário abrir mão do estado.
