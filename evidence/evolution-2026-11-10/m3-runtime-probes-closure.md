# M3 — Worktrees nativos e execução remota (2026-11-11)

## #140 — create → uso → remove (capacidade nativa)

**API:** OpenCode V2 `POST/GET/DELETE /api/worktree` (projectID `c0a24813568bcf09ed921d540d4ee1229ec0e888`).

| Passo | Resultado |
|---|---|
| `POST /api/worktree` com `name=p0-m3-probe`, `directory=...\Temp\p0-m3-probe-20261111` | criado em `...\p0-m3-probe-20261111\p0-m3-probe` |
| Uso: `Set-Content probe.txt` + `Get-Content` | `P0-M3-PROBE-OK` |
| `GET /api/worktree` | worktree listado (1 correspondência) |
| `DELETE /api/worktree` com `force=true` | exit 0; diretório removido (`dir_exists=False`); lista após remoção = 0 |

Nenhum worktree existente foi alterado ou limpo. O probe usou apenas um diretório descartável em TEMP.

## #203 — Linux/Docker remoto a partir do PC

Comando executado localmente pelo Planner:

```text
ssh -o BatchMode=yes contabo-prod "uname -a; docker ps --format '{{.Names}}' | head -5"
```

Resultado: `Linux vmi3630510 7.0.0-42-generic ... x86_64 GNU/Linux` e containers `pi-finance-api`, `credencial-hub-vaultwarden-dev`, `ted-runtime`, `traefik`, `freelingo-backend`.

- Somente leitura (`uname`, `docker ps`); nenhuma mutação de produção.
- Prova que o Planner local executa Linux/container na VPS via capacidade existente (SSH/Docker context), sem instalar mecanismo novo.
- A perna de mutação/Compose permanece fora deste probe por política de produção.
