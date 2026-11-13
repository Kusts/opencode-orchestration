# M3 — Probes de runtime nativo (2026-11-10)

**Runtime vivo:** OpenCode `2.2.6` (`opencode api get /api/info`).
**Superfície:** OpenAPI local (`/openapi.json`) + chamadas `opencode api`.

## Resultados

### #139 — PTY e shell nativos (COBERTO)

- **PTY:** `POST /api/pty` criou `pty_1c8521435001saqgoR6HkW0lO2`
  (`command=powershell`, `cwd=repo`, `title=m3-pty-probe`). `GET /api/pty`
  mostrou a sessão `exited` com `exitCode=0`.
- **Shell:** `POST /api/shell` com
  `{command:"Start-Sleep -Seconds 2; Write-Output 'shell-ok'", timeout:30000}`
  criou `sh_1c852c6140015GnkrN8h506g1j`. Após 3s, `GET /api/shell/<id>` =
  `status=exited` e `GET /api/shell/<id>/output` = `shell-ok` (size 10).
- **Gotcha:** o campo `timeout` do shell está em **milissegundos** (30 =
  timeout imediato; 30000 = 30s).
- Conclusão: comando longo continua, retorna resultado e o lifecycle nativo
  funciona; nenhum wrapper próprio é necessário.

### #140 — Worktrees nativos (PARCIAL)

- `GET /api/worktree?projectID=c0a248…` retornou 42 worktrees com
  `directory` + `strategy:"git"` (inventário nativo carregado do projeto).
- `POST`/`DELETE /api/worktree` existem no OpenAPI (`Worktree.CreateInput` /
  `Worktree.RemoveInput`), mas criar/remover dois worktrees isolados não foi
  exercitado nesta rodada.
- Conclusão: a superfície nativa existe e está populada; falta provar
  paridade de criação/remoção antes de remover qualquer gerenciamento local.

### #143 — Sessões (COBERTO)

Contrato nativo de `session list/export/get/archive` já provado em 2026-11-07.

### #203 — Remoto (SPIKE)

SSH/Docker da VPS não foram probados neste repo nesta rodada; perfis externos
permanecem user-owned. Nenhuma dependência nova foi adicionada.

## Decisão

Nenhum componente foi removido. #139 fechado com prova runtime; #140 segue
PARCIAL até provar criação/remoção; #203 permanece SPIKE.
