# M3 — Probes de runtime nativo (2026-11-10)

**Runtime vivo:** OpenCode `2.2.6` (`opencode api get /api/info` → `pid=11836`,
`urls=["http://127.0.0.1:4096"]`).
**Objetivo:** determinar o que pode ser adotado sem duplicação, sem substituir
componentes por paridade presumida.

## Observado

| Capacidade | Observação | Status para M3 |
|---|---|---|
| PTY persistente | `/api/info` anuncia `capabilities.persistentPty=true` | **Advertised, não provado**: falta prova de lifecycle (comando longo sobrevive, devolve resultado, cleanup). #139 permanece HOLD. |
| Sessões nativas | `session list/export/delete`, `session.get`, arquivamento via PATCH | **Provado** em 2026-11-07 (`#143`); coberto. |
| Worktrees | `opencode --help` não expõe subcomando `worktree`; o help de `opencode worktree` cai no help geral | **Sem superfície CLI observada** em 2.2.6. #140 permanece SPIKE; não remover o gerenciamento atual. |
| Remoto SSH/Docker | Perfis `contabo-prod`/`contabo-dev-exec` e MCP `remote-exec` existem fora deste pacote | **Não probado neste repo** nesta rodada. #203 permanece SPIKE; nenhuma dependência nova adicionada. |
| Background subagents | Não probado | Fora do escopo desta rodada. |

## Decisão

Nenhum componente foi removido ou substituído. O M3 fica em **HOLD honesto**
até existir prova exato-binário dos fluxos exigidos (PTY lifecycle, paridade de
worktree, execução remota autorizada). A única capacidade já coberta é #143.

## Próximo teste exigido

1. #139: executar comando longo por PTY persistente, matar/restaurar o serviço
   e provar que o processo sobrevive e devolve resultado com cleanup.
2. #140: criar dois trabalhos isolados com a superfície nativa (quando
   descoberta) e provar que nenhuma alteração é perdida.
3. #203: a partir do Planner local, executar um comando Linux/container na VPS
   sob autorização explícita e registrar a evidência.
