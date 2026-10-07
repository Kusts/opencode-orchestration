# MCP profiles — Fase 2C

Fonte canônica: `source/registry/mcp-profiles.json` (schema 1, 19 profiles).
Evidência browser: `evidence/capabilities-phase-2c/browser-real-tasks-2026-10-07.json`.
Testes: `tests/distribution/mcp-profiles.tests.ps1` (8/8),
`tests/distribution/capability-registry-v2.tests.ps1` (48/48).

## Profiles

| Profile | MCPs | Agents | Status |
|---|---|---|---|
| `core` | context7 | build, coder, researcher, frontend/backend-engineer, docs-manager | APPROVED |
| `research` | context7, jev | researcher, architect, engineering-advisor | APPROVED |
| `memory` | ai-memory | build (transversal) | APPROVED |
| `core-dev` | github-mcp | reviewer, tester, coder | PILOT (opt-in; requer PAT do operador) |
| `testing` | playwright-mcp, chrome-devtools-mcp full | tester, frontend-engineer, debugger, reviewer, backend-engineer | APPROVED (opt-in; tarefa real 2026-10-07) |
| `database-supabase` | supabase-mcp | database-engineer, backend-engineer, security-reviewer, debugger | PILOT (project-only) |
| `database-neon` | neon-mcp | database-engineer, backend-engineer, debugger | PILOT (project-only) |
| `backend` | postman-mcp | backend-engineer, tester | PILOT (benchmark vs curl pendente) |
| `frontend` | figma-mcp | product-designer, frontend-engineer, reviewer | PILOT |
| `product` | posthog-mcp | product-designer, frontend-engineer, backend-engineer | PILOT |
| `infra` | docker-mcp-gateway | infra-engineer, debugger | PILOT (infra de execução; não substitui Registry/policy) |
| `iac` | terraform-mcp | infra-engineer, reviewer | PILOT (só com IaC real) |
| `cloud` | cloudflare-mcp | infra-engineer, backend-engineer | PILOT |
| `observability` | grafana-mcp | infra-engineer, debugger, tester | PILOT |
| `automation` | n8n-mcp | automation-engineer, reviewer | PILOT (project-only) |
| `payments` | stripe-mcp | backend-engineer, reviewer, security-reviewer | PILOT (project-only; read-only default) |
| `sales` | hubspot-mcp | backend-engineer, automation-engineer | PILOT |
| `growth-google` | ga-mcp, google-ads-mcp | requirements-analyst, frontend-engineer, researcher | PILOT (read-only) |
| `growth-seo` | dataforseo-mcp | requirements-analyst, researcher | PILOT (com budgets) |

Decisão 2C do operador (2026-10-07): Chrome DevTools MCP **completo**
APPROVED sob profile `testing` (nunca global, nunca `--slim` como default).
Custo de ~59 tools aceito somente com o profile ativo.

## Quando ativar / quando NÃO ativar

- Ativar `core-dev` quando: triagem multi-passo de issues, review com CI/diffs,
  leitura de Actions sem montar comandos — e o custo (~30k tokens default)
  couber no orçamento. `gh` CLI continua o default pontual.
- Ativar `testing` quando: E2E comportamental (Playwright) ou diagnóstico
  runtime (DevTools: console/network/DOM/perf). CLI+skill continua a
  alternativa de menor custo para navegação simples.
- Ativar profiles de domínio quando: o projeto usa o serviço **e** há
  credencial de projeto do operador. Sem projeto/credencial: CANDIDATE.
- Supabase e Neon nunca no mesmo projeto (usar somente o do projeto).
- NÃO ativar globalmente: nenhum MCP novo nasce `global always-on`;
  `github_*:false` por default + allow por agente; DevTools full só com
  `testing` ativo.
- Fallbacks: `gh` CLI (GitHub), Playwright CLI + skill (browser),
  Supabase/Neon CLI + SQL, curl/OpenAPI + Newman (APIs), API direta (n8n,
  PostHog, HubSpot, Grafana, DataForSEO), Stripe CLI/SDK, Terraform CLI,
  `api.cloudflare.com` + skills (Cloudflare).

## Permission model

```text
GitHub MCP remoto: /readonly + toolsets repos,issues,pull_requests; writes
  somente sob fluxo com pedido explícito; admin settings fora de escopo.
Playwright MCP: headless + isolated; evaluate restrito às páginas do escopo (ask);
  run_code_unsafe deny (RCE no servidor; exceção só explícita, descartável, sem
  credenciais); sem sessão autenticada pessoal.
Chrome DevTools full: isolated + headless + --no-usage-statistics +
  --no-performance-crux sempre; evaluate_script sob ask; autoConnect/browserUrl
  negados (sessão pessoal).
Supabase/Neon: read allow (read_only/readonly + escopo de projeto);
  migration/prepare sob ask (não-produtivo); execute_sql/run_sql, prod write e
  destrutivos sob deny; nunca skip_elicitations.
Terraform: plan/validate/registry-read allow; apply dev/prod ask; destroy deny.
Stripe: read allow; test-data allow (sandbox)/ask; subscription/refund/payout deny
  (exceção só via contrato separado + aprovação humana). Sandbox primeiro.
Google Ads: read/analysis allow; qualquer alteração de mídia paga sob deny.
DataForSEO: leitura com teto; bulk ilimitado deny.
n8n: discovery/logs allow; execute/edit sob ask (efeito real).
```

## Context/tool cost (medido)

| MCP | Tools | Custo |
|---|---|---|
| GitHub default (5 toolsets) | 52 | ~30,3k tokens (oficial) |
| GitHub piloto (3 toolsets + readonly) | < 52 | menor que default |
| Playwright MCP 0.0.83 | 25 (default) | medido tools/list 2026-10-07; tokens UNVERIFIED |
| Chrome DevTools 1.10.1 full | 30 default (~59 com opt-ins) | medido tools/list 2026-10-07; custo aceito sob profile |
| Demais 2C | conforme servidor | não medidos (CANDIDATE/PROJECT_ONLY, sem ativação) |

Regra: MCP com dezenas de tools entra somente via profile on-demand;
medir tokens antes de qualquer default.
