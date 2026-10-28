# F4 — Matriz de Agent Config e ownership (2026-10-28)

## Issue: #141

## Ownership de configuração

| Campo | Dono | Comportamento |
|---|---|---|
| agents (bloco) | template (merge por chave) | somente agentes do template gerenciados; user-owned intactos |
| experimental.subagent_depth | template | gerenciado |
| model, default_agent, $schema | template | gerenciados |
| mcp, plugin, skills, autoupdate | user-owned | preservados por merge estrutural |
| models.jsonc | local (gitignored) | nunca commitado |

## Testes

- `install-ownership.tests.ps1`: 17/17 PASS.
- `reconcile-ownership.tests.ps1`: 4/4 PASS.
- Config user-owned preservada (merge estrutural).

## Conclusão F4 (fatia pequena)

- Ownership campo-a-campo verificado. Permissões globais preservadas.
- Sem migração native-first ampla (aguarda equivalência funcional demonstrada).
- Sem alteração da config global ativa do usuário.