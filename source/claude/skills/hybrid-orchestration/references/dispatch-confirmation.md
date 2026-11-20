# Confirmação de execução após `worker-start` (P0)

Aceitação de input (`ready`, `input_accepted`, `activity=working`) **não** prova que o
OpenCode iniciou o turno da task certa. Faça uma verificação curta e delimitada (sem
polling permanente), depois espere o evento nativo (`worker_done`, `ask`, `escalation`).

## Verificação (uma rodada)

```text
orca orchestration worker-show --dispatch <ID> --json
orca orchestration worker-read --dispatch <ID> --limit 50 --json
orca terminal read --terminal <HANDLE> --json      # só se faltar evidência: draft/TUI
```

Evidência de início = turno ligado à task/dispatch correta: tool em execução, resposta do
agente, linha de transcript com o objetivo da task. `worker-show` traz
`observation.agentWait`: worker parado em prompt humano está saudável, não falho — responda
ou use `deny`. Ausência do campo ≠ "não está esperando".

## Casos

| # | Observação | Ação |
|---|---|---|
| 1 | Turno da task correta em andamento | Seguir; aguardar o evento nativo. |
| 2 | Texto correto parado no draft da TUI, nenhum turno | Um único `orca terminal send --terminal <H> --enter --json` (Enter-only; `--wait-submit` só com `--text`). Reverificar início. Nunca Enter às cegas nem reenviar o texto. |
| 3 | Terminal/transcript sem prompt inicial, Dispatch ativo, nenhuma atividade | Conferir `git status/diff` e transcript. Provado não iniciado: `worker-stop` (ou `worker-abandon` se o processo for incerto) e `worker-start --task <id> --retry-of <dispatch> --agent … --worktree …` **sem `--spec`**. Não use `send` como recuperação universal (o preâmbulo pode carregar a capability do protocolo de conclusão). |
| 4 | Dispatch criado/`running`, mas sem execução observável (nem draft, nem transcript, sem diff) após a janela curta | Mesmo que 3: só redespache após provar ausência de efeito; `--retry-of` vincula ao dispatch anterior. |
| 5 | Resposta perdida/timeout do próprio `orca` (estado ambíguo) | `orca orchestration request-show --request <id>` (read-only): `completed` → `--retry-request <id>` reproduz o resultado sem 2ª execução; `pending` → aguardar/reemitir com `--retry-request`; `absent` **não** prova que nada aconteceu → reconciliar (`worker-list`, `worker-show`, transcript, `git diff`) antes de qualquer novo `worker-start`. |

Regra de ouro: **estado desconhecido ⇒ HOLD e reconciliar, nunca duplicar**. Só recupere
automaticamente casos comprovadamente não iniciados.

Registre no relato da task qual caso ocorreu e a evidência (campos de `worker-show`,
trecho de transcript, ausência de diff).
