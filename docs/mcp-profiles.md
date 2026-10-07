# MCP profiles — Fase 2B

Fonte canônica: `source/registry/mcp-profiles.json` (schema 1, 5 profiles).
Pilotos: `evidence/capabilities-phase-2b/mcp-pilots-2026-10-07.json`.
Testes: `tests/distribution/mcp-profiles.tests.ps1` (7/7).
Probes: `evidence/capabilities-phase-2b/playwright-mcp-help-0.0.83.log`,
`chrome-devtools-mcp-help.log`.

## Profiles

| Profile | MCPs | Agents | Status |
|---|---|---|---|
| `core` | context7 | build, coder, researcher, frontend/backend-engineer, docs-manager | APPROVED |
| `research` | context7, jev | researcher, architect, engineering-advisor | APPROVED |
| `memory` | ai-memory | build (transversal) | APPROVED |
| `core-dev` | github-mcp | reviewer, tester, coder | PILOT (opt-in; requer PAT do operador) |
| `testing` | playwright-mcp | tester, frontend-engineer, debugger | PILOT (opt-in; headless, caps mínimas) |

Chrome DevTools MCP: HOLD (fora de profile; revisitar via `--slim`).

## Quando ativar / quando NÃO ativar

- Ativar `core-dev` quando: triagem multi-passo de issues, review com CI/diffs,
  leitura de Actions sem montar comandos — e o custo (~30k tokens default)
  couber no orçamento. `gh` CLI continua o default pontual (custo zero até invocar).
- Ativar `testing` quando: E2E comportamental exploratório. CLI+skill
  (`playwright-cli` 1.60 + skill RECOMMENDED P1) continua a alternativa de
  menor custo; medir tokens antes de qualquer default.
- NÃO ativar globalmente: `github_*:false` por default + allow por agente;
  Playwright fora do profile `testing`; DevTools sem gap concreto de perf/memória.
- Fallback: sem MCP, o fluxo equivalente é `gh` CLI (GitHub), Playwright CLI +
  skill (browser), medidas manuais (perf). Nenhum fluxo da Fase 2B depende de MCP piloto.

## Permission model dos pilotos

```text
GitHub MCP remoto: /readonly + toolsets repos,issues,pull_requests; writes (issues/PRs)
  somente sob fluxo com pedido explícito; admin settings fora de escopo.
Playwright MCP: headless, caps core (+testing sob demanda); evaluate/run_code_unsafe
  restritos a páginas do escopo da tarefa; sem credenciais (nenhum env de auth).
```

## Context/tool cost (medido ou oficial)

| MCP | Tools | Custo |
|---|---|---|
| GitHub default (5 toolsets) | 52 | ~30,3k tokens (oficial) |
| GitHub all | ~101–102 | ~64,6k tokens (oficial) — NÃO usar |
| GitHub piloto (3 toolsets + readonly) | < 52 | menor que default (filtro por URL/header) |
| Playwright MCP | 70+ (core 24 + caps) | UNVERIFIED em tokens; maior que CLI+skill por design |
| Chrome DevTools | 59 (slim: 3) | UNVERIFIED; HOLD |

Regra: MCP que adicionar dezenas de tools sem filtro não entra em default;
reduzir via toolsets/caps/profile antes de aprovar.
