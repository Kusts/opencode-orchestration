# Confirmação de execução após `worker-start` (P0)

Aceitação de input (`ready`, `input_accepted`, `activity=working`) **não** prova que o
turno da task certa começou. Pelo `--help`, na visão concisa o exit 0 também cobre start
cujo turno ainda não foi observado; só `--full` sai com 1 para tudo que não seja `ready`.
Portanto exit 0 do `worker-start` não prova turno iniciado. Faça uma rodada curta e
delimitada (sem polling), depois espere o evento nativo (`worker_done`, `ask`,
`escalation`).

## Verificação (uma rodada)

```text
orca orchestration worker-show --dispatch <ID> --json
orca orchestration worker-read --dispatch <ID> --limit 50 --json
# Para opencode2 não há transcript estruturado: use `worker-read --limit 50 --json` (fonte auto, saída rotulada do terminal) e, se precisar de mais, `orca terminal read` somente leitura; `transcript_required` = ausência de transcript, não falha do worker.
```

Evidência de início = turno ligado à task/dispatch correta: tool em execução, resposta
do agente, linha de transcript com o objetivo. `worker-show` traz
`observation.agentWait`: worker parado em prompt humano está saudável — responda ou
use `deny`. Ausência do campo ≠ "não está esperando".

## Casos

| # | Observação | Ação |
|---|---|---|
| 1 | Turno da task correta em andamento | Seguir; aguardar evento nativo. |
| 2 | Texto correto parado no draft da TUI, nenhum turno | Exceção DESTE projeto, fora do guia do Orca, para um defeito observado de entrega (prompt aceito mas não submetido): somente com saída rotulada do terminal (`worker-read --limit 50 --json` ou `orca terminal read`) ou transcript, quando existir, mostrando o texto correto parado no campo de entrada e nenhum turno iniciado, e worker local não pareado; um único `orca terminal send --terminal <H> --enter --json` (Enter-only, sem `--text`). Reverificar início; nunca reenviar texto nem usar para steer. |
| 3 | Sem prompt inicial, Dispatch ativo, nenhuma atividade | Conferir `git status/diff` e transcript ou saída do terminal. Provado não iniciado: `worker-stop` (ou `worker-abandon` se o processo for incerto) e `worker-start --task <id> --retry-of <dispatch>` **sem `--spec`**, repetindo placement e agente. |
| 4 | Dispatch criado/`running`, sem execução observável após janela curta | Como 3: só redespache após provar ausência de efeito; `--retry-of` vincula ao anterior. |
| 5 | Timeout/resposta perdida do `orca` (estado ambíguo) | `orca orchestration request-show --request <id>` (read-only): `completed` → `--retry-request <id>` (reproduz, sem 2ª execução); `pending` → aguardar/reemitir com `--retry-request`; `absent` não prova não-execução → reconciliar (`worker-list`, `worker-show`, transcript ou saída do terminal, `git diff`). |

Regra de ouro: **estado desconhecido ⇒ HOLD e reconciliar, nunca duplicar**. Só
recupere automaticamente casos comprovadamente não iniciados. Registre no relato qual
caso ocorreu e a evidência (campos de `worker-show`, trecho de transcript ou saída do terminal, diff).
