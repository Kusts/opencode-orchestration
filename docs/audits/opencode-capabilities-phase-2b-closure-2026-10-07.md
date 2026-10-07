# Closure — OpenCode Capabilities Phase 2B (2026-10-07)

## 1. Scope

Curadoria das ~103 skills + pilots MCP (GitHub, Playwright, Chrome DevTools),
integração ao Capability Registry V2, profiles validados, healthchecks e
evidência. Sem instalar Phase 2C. Sem reabrir 2A (nenhuma regressão encontrada;
2 FAILs config-format preexistentes intactos e fora de escopo).

## 2. Initial State

- `master` em `d3f2d24` (PR #24 MERGED); branch `feat/capabilities-phase-2b`
  a partir do HEAD; tree limpa.
- Baseline: package-consistency 16/16 OK; capability-healthcheck com 2 MISS
  honestos (ai-memory por probe stale `mcp.ai-memory`; jev por env names
  stale); plugin-healthcheck com LoadErrors históricos do `ai-memory.ts`
  (issue #25); opencode v2.0.24 vs pin 2.0.23 (drift conhecido, sem bump).
- Skills: 103 dirs em `~/.agents/skills` (93 junctions → agent-config global,
  10 real dirs) + 7 em `~/.config/opencode/skills` (5 shadowed + autoresearch +
  jev-ultrafast) + 5 skills-core no repo.

## 3. Skills Inventory

`evidence/capabilities-phase-2b/skills-inventory-2026-10-07.json` (110 linhas,
sha256 + kind junction/real + SKILL.md presente). Inventário semântico via 3
explorers (39 + 16 + 38 skills) + gaps pelo Planner (8: frontend-design,
orchestration, maestri ×6) + leitura direta das especiais
(autoresearch, jev-ultrafast, ai-memory-messaging, computer-use).

## 4. Skills Taxonomy

`source/registry/skills-catalog.json` (schema 1, 105 entradas = 103 + 2
opencode-only): CORE 9, RECOMMENDED 24, DOMAIN 44, PERSONAL 20,
PROJECT_SPECIFIC 1, EXPERIMENTAL 4, REDUNDANT 1, DEPRECATED 1,
REMOVE_CANDIDATE 1. Prioridades P0 (3) → P4. Domínios cobrem Engineering,
Frontend, Backend, Testing, Debugging, Security, Infra/DevOps, AI/Agents,
Memory, Automation, Product, UX/UI, Documentation, Git/GitHub, Research,
Paid Traffic, Marketing, Sales, Content.

## 5. Duplications

- Exata: nenhuma (4 shadows identical = mesmo conteúdo, não duplicata;
  precedência resolve).
- Parcial/semântica: trio hybrid/dispatching/subagent-driven = camadas
  distintas (método/fan-out/plano) + orca-team (runtime Orca); systematic vs
  tight-feedback = par complementar; triage vs github-triage = escopos
  distintos; família brainstorming (dono + apêndices); Cloudflare umbrella vs
  standalone (profundidade decide). Todas com `conflicts[]` no catálogo.
- Ferramenta: playwright-cli skill vs Playwright MCP = complementares
  (custo vs exploração); documentado, não redundante.
- REDUNDANT real: `internal-comms` → `doc-coauthoring` (com `replaced_by`).

## 6. Shadowing

5 ids nos dois roots; winner `~/.config/opencode/skills` (later-wins V2).
4 identical, 1 diverged-benign (`hybrid-development`: só o path do entrypoint).
`shadow_table` com sha256 integral no catálogo; `skills-healthcheck.ps1` sonda e o gate
Core falha em divergência não documentada. Exceção vinculada ao par exato de
hashes (prova negativa: 1 char adulterado no par registrado → verdict FAIL
`diverged-undocumented`). Hashes integrais na evidência.

## 7. Skills Removed/Archived

Nenhum arquivo movido ou removido (migração segura). `orca-autonomous-development`
(REMOVE_CANDIDATE, junction quebrada) sai do discovery path após correção no
agent-config; healthcheck a lista como `invalid`. EXPERIMENTAL fora do
discovery gerenciado (no disco, sem owner).

## 8. Skills Adopted

Adoção seletiva Superpowers (pacote NÃO instalado): systematic-debugging (CORE),
test-driven-development (CORE), verification-before-completion, writing-plans,
executing-plans (CORE), família code-review (RECOMMENDED). `using-superpowers`
só como stub DEPRECATED de encaminhamento.

## 9. Skills Catalog

`source/registry/skills-catalog.json`: cada entrada com id, category, priority,
classification, managed_by, activation, agents, conflicts, replaces/replaced_by,
source, version_policy, status. CORE pequeno (9 ≤ 12, com teste).

## 10. Skills Healthcheck

`scripts/v3/skills-healthcheck.ps1`: total_discovered 110, managed 77,
personal 20, project 1, duplicate_ids 0, shadowed 5, invalid 1, deprecated 2,
core_gate 9/9, verdict PASS. Evidência:
`evidence/capabilities-phase-2b/skills-healthcheck-2026-10-07.json`.

## 11. Capability Registry Integration

`capabilities-v2.json`: 13 → 17 capabilities. Novo: `skills-catalog` (ACTIVE,
repo-file) + 3 pilotos CANDIDATE. Correções honestas: ai-memory via probe novo
`mcp-path` (`servers.ai-memory` — MISS virou OK); jev via
`OPENCODE_ZEN_API_KEY` (MISS virou OK). `capability-healthcheck.ps1` ganhou o
probe `mcp-path` (leitura, sem rede, sem secrets). Teste do registry atualizado
(32/32).

## 12. GitHub MCP Pilot

Pacote `github/github-mcp-server`, remoto read-only, toolsets
repos/issues/pull_requests. NÃO instalado/conectado (sem PAT no env; nenhum
secret extraído). Evidência equivalente: `gh` auth (scopes
gist/read:org/repo/workflow) + reads reais (10 issues incl #25, PRs #24/#23,
runs CI). Custo oficial: 52 tools/~30,3k default; all ~101–102/~64,6k (NÃO usar).

## 13. GitHub MCP Verdict

PILOT-APPROVED: profile `core-dev` opt-in (reviewer/tester/coder,
`github_*:false` global). MCP agrega em triagem multi-passo e CI sem montar
comandos; `gh` CLI continua o default pontual. Ativação pendente do operador
(PAT). Não promovido a CORE.

## 14. Playwright MCP Pilot

`@playwright/mcp` — probe real: `--help` exit 0, `--version` 0.0.83 (npx,
sem browser lançado). Baseline: Playwright CLI saudável + skill
playwright-cli RECOMMENDED P1. Custo: 70+ tools, tokens UNVERIFIED (maior que
CLI+skill por design — a própria doc oficial recomenda CLI+skills para coding
agents).

## 15. Playwright Verdict

PILOT-APPROVED: profile `testing` opt-in (tester/frontend-engineer/debugger,
headless, caps mínimas). Medir tokens vs CLI+skill antes de qualquer default.

## 16. Chrome DevTools MCP Pilot

`chrome-devtools-mcp` — probe real: `--help` exit 0, `--version` 1.10.1,
category flags confirmam filtragem. 59 tools (slim: 3); telemetria
on-by-default; sobreposição grande com Playwright em automação.

## 17. Chrome DevTools Verdict

HOLD: sem instalação; revisitar via `--slim` + `--no-usage-statistics` sob
debugger somente se gap de perf/memória se confirmar. Divisão mantida:
Playwright = comportamento/E2E; DevTools = diagnóstico runtime.

## 18. MCP Profiles

`source/registry/mcp-profiles.json`: core, research, memory (APPROVED);
core-dev, testing (PILOT opt-in). Teste impõe APPROVED restrito a
context7/jev/ai-memory (7/7). Nenhum MCP global desnecessário.

## 19. Context/Tool Cost

Tabela em `docs/mcp-profiles.md` (oficial quando publicado, UNVERIFIED quando
não). Regra: dezenas de tools sem filtro não entram em default.

## 20. Permission Model Residual

Proposta deny-before-ask documentada em
`docs/capabilities-phase2b-decisions.md` (force-push + docker prune). NÃO
implementada (mudança de autoridade exige security review + rodada própria;
estado atual é fail-ask no interativo, sem garantia em modo auto — contenção
real via contrato + ownership).

## 21. Issue #25 Status

Evidência nova coletada (LoadErrors históricos do `ai-memory.ts` +
`.bak-1791360135` na raiz de plugins; legado ausente no disco; fail-closed OK).
Comentário com evidência postado na issue; issue permanece ABERTA; fix sugerido
de baixo risco para rodada própria. Sem mudança de comportamento na 2B.

## 22. Tests

| Suite | Resultado |
|---|---|
| skills-catalog (nova) | 18/18 (incl. cobertura exata vs inventário + vínculo de hashes) |
| mcp-profiles (nova) | 7/7 |
| capability-registry-v2 (atualizada p/ 17 + mcp-path + leak names) | 32/32 |
| package-consistency | 16/16 (inalterado) |
| config-format | 51/1 com 2 FAILs preexistentes (fora de escopo, §20 item 3 das decisions) |

## 23. Security

Nenhum secret em Git/logs/relatórios/telemetria (nomes de env apenas);
healthchecks com assert anti-vazamento (incl. `OPENCODE_ZEN_API_KEY` e
`GITHUB_PERSONAL_ACCESS_TOKEN`); pilotos sem credenciais instaladas;
`orca-per-workspace-env` marcado HIGH; wizard/turnstile/wrangler explicit-only.

## 24. Residuals

1. Permissões force-push/docker (proposta pronta, rodada própria + security review).
2. Pins 2.0.23 vs 2.0.24 (manter; smoke dedicado antes de bump).
3. config-format 2 FAILs (dono: issue #21).
4. Issue #25 aberta (fix sugerido de baixo risco).
5. `resolving-merge-conflicts` com boilerplate (limpeza pendente).
6. `ui-libraries-curator` over-trigger (lido como on-demand).
7. `vendas-br` divergência 745 vs 741 na descrição (cosmético).
8. Junction `orca-autonomous-development` quebrada no agent-config (fora deste repo).
9. Tokens Playwright/DevTools MCP UNVERIFIED (sem número oficial).
10. GitHub MCP não conectado (aguarda PAT do operador).

## 25. Deferred to Phase 2C

Supabase, Neon, Postman, Figma, Docker MCP Gateway, PostHog, Stripe, n8n,
Google Analytics/Ads, DataForSEO, HubSpot, Cloudflare (MCP), Terraform,
Grafana, Jina, Composio, Pipedream. Ativações de wiring pendentes do operador
(fora do gate 2B). Nenhum item 2C iniciado.

## 26. Git/PR Evidence

Branch `feat/capabilities-phase-2b` ← `d3f2d24`; commits por responsabilidade;
PR + CI + review registrados ao fechar (seção preenchida no merge).

## 27. Final Verdict

Phase 2B verdict: PASS (curadoria completa e governada; pilotos com evidência;
nenhum MCP global; security e testes verdes no escopo).
Phase 2C readiness: READY (fundação validada; pendências só decisões do operador).
