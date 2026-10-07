# Auditoria — Capabilities Fase 2C (2026-10-07)

Veredito: **2C READY (PASS com PILOTs honestos)** — browser stack APPROVED com
tarefa real; 15 capabilities de domínio decididas (PROJECT_ONLY/CANDIDATE);
nenhum MCP instalado por catálogo; ativação sempre opt-in.

## 1. Scope

Expandir o sistema de capabilities por domínio em 5 blocos (2C.1–2C.5) sob a
regra necessidade → avaliação → pilot → validação → profile → healthcheck →
APPROVED/PILOT/PROJECT_ONLY/CANDIDATE/REJECTED, mais a reversão da decisão
HOLD do Chrome DevTools para APPROVED full (decisão do operador 2026-10-07).

## 2. Initial State

Phase 2B PASS, master `e8e6876`, PR #26 MERGED, CI 5/5. Registry V2 com 17
capabilities; profiles core/research/memory APPROVED, core-dev/testing PILOT;
skills catalog operacional (105). Branch isolada `feat/capabilities-phase-2c`;
working tree limpa; baseline revalidado sem regressão (§28).

## 3. Chrome DevTools Decision

HOLD (2B) → **APPROVED** (2C, decisão explícita do operador): servidor
**completo** (`chrome-devtools-mcp@latest`, sem `--slim` como default), ~59
tools aceitas **sob profile**, nunca global. Registry e este documento
refletem a decisão; `--slim` (3 tools) reservado a tarefas básicas.

## 4. Browser Testing Stack

Contrato: **Playwright = comportamento/automação/E2E** (@playwright/mcp
0.0.83, 25 tools default, `--headless --isolated`); **Chrome DevTools =
diagnóstico/observabilidade/runtime** (1.10.1, 30 tools default full +
opt-ins memory/extensions/third-party/WebMCP/PWA). Complementares, não
substitutos. Evidência:
`evidence/capabilities-phase-2c/browser-real-tasks-2026-10-07.json`.

## 5. Backend/Database

Bloco 2C.1 avaliado via fontes oficiais (repo + docs primárias), sem
projeto de teste/credencial nesta máquina: nenhuma aprovação inventada.
Gates no §8.

## 6. Supabase

**PROJECT_ONLY** (prioridade alta, stack recorrente). Oficial first-party:
remoto `https://mcp.supabase.com/mcp` (OAuth) ou dev local via CLI; escopo
nativo `?project_ref + ?read_only=true + ?features`; nunca
`?skip_elicitations`. Skills: **nenhuma no catálogo 105** — avaliar upstream
antes de adotar (Postgres/RLS/auth/storage/migrations/edge functions).
Pilot em ambiente não-produtivo antes de qualquer write.

## 7. Neon

**PROJECT_ONLY**. Oficial first-party: remoto `https://mcp.neon.tech/mcp`
(OAuth/API key; SSE e stdio deprecados); `?readonly=true + ?projectId +
?category`; "somente dev/IDE, nunca produção". Branching (prepare_* em
branch temporária) é o valor diferencial para testes/migrations/previews.
Nunca com Supabase no mesmo projeto.

## 8. Postman

**CANDIDATE**. Oficial first-party (remoto US/EU ou stdio, configs
Minimal/Code/Full/Learn). A própria Postman recomenda CLI+skills como
caminho primário para coding agents. Benchmark vs curl/OpenAPI pendente;
Full (100+ tools) nunca default.

## 9. Frontend/Product

Bloco 2C.2: Figma (design context/handoff) e PostHog (analytics/flags/
experiments), Chrome DevTools já aprovado e referenciado. PostHog em
profile `product` separado para não misturar responsabilidades.

## 10. Figma

**CANDIDATE**. Oficial (remoto + Desktop Dev Mode). Leitura/codegen seguras;
write-to-canvas sob ask. Agents: product-designer, frontend-engineer,
reviewer. Profile `frontend` (PILOT).

## 11. PostHog

**CANDIDATE**. Oficial hospedado (OAuth US/EU; AI spend em algumas tools).
Leitura default; flag/experimento sob ask. Profile `product` (PILOT).

## 12. Infra

Bloco 2C.3: Docker Gateway (atenção arquitetural), Terraform (só com IaC
real), Cloudflare (só com ganho; skills já no catálogo), Grafana
(observabilidade). Writes de infra protegidos em todos.

## 13. Docker MCP Gateway

**CANDIDATE**. Oficial (gateway + catálogo 200–300+ servers). Arquitetura:
`Planner → Registry → Profile → Policy → Gateway → server` — o Gateway é
**infra de execução**, nunca decide. Ativar no catálogo ≠ autorizar uso.
Pilot comparativo antes de qualquer migração.

## 14. Terraform

**CANDIDATE**. Oficial HashiCorp; default só toolset registry (leitura);
`ENABLE_TF_OPERATIONS=false` até tarefa explícita. plan/validate allow,
apply ask, destroy deny. Profile `iac` (PILOT).

## 15. Cloudflare

**CANDIDATE**. Oficial (por produto + Code Mode). Ganho avaliado contra
projetos atuais; skills `cloudflare*` já cobrem conhecimento. Token escopo
mínimo. Profile `cloud` (PILOT).

## 16. Grafana

**CANDIDATE**. Oficial OSS + Cloud. Leitura primeiro; alerting/incidents
sob ask. Profile `observability` (PILOT).

## 17. Automation

Bloco 2C.4: n8n (prioridade, stack recorrente) PROJECT_ONLY; Stripe
PROJECT_ONLY (pagamentos); HubSpot CANDIDATE (CRM).

## 18. n8n

**PROJECT_ONLY**. Instance-level BETA (search/get/execute; build/edição por
versão) + community builder só CANDIDATE. `execute_workflow` tem efeito
real → ask/deny. Profile `automation` (PILOT); agent automation-engineer.

## 19. Payments

Profile `payments` (PILOT): Stripe somente em projetos com pagamentos,
read-only default, sandbox primeiro.

## 20. Stripe

**PROJECT_ONLY**, risco **critical**. Oficial remoto; Agent API key com
rejeição de secrets sem tag (401 após 2026-10-31); refunds/pagamentos com
aprovação humana (token 24h). Nenhuma ação financeira silenciosa.

## 21. Sales

Profile `sales` (PILOT): HubSpot com scopes read-only default, bulk deny.

## 22. HubSpot

**CANDIDATE**. Oficial duplo (CRM remoto + Developer MCP local). Escrita
polui funil → ask. Sem conta nesta máquina.

## 23. Growth

Bloco 2C.5: GA (experimental read-only) + Google Ads (read-only, 3 tools) no
profile `growth-google`; DataForSEO (preferência sobre Ahrefs) no
`growth-seo`. Todos CANDIDATE; mídia paga e créditos sob policy.

## 24. Google Analytics

**CANDIDATE**. Oficial experimental, 7 tools read-only. PII + quota sob
atenção. Sem propriedade nesta máquina.

## 25. Google Ads

**CANDIDATE**. Oficial, read-only nesta release (sem escrita para aprovar).
Skills = estratégia, MCP = dados. Budget/campaign change ask, pause/delete
ask/deny. Sem conta nesta máquina.

## 26. DataForSEO

**CANDIDATE**. Oficial; pay-per-call (top-up mín. $50) → budgets + ask para
bulk. Fork community preterido. Ahrefs não instalado (sem necessidade).

## 27. Profiles

19 profiles: core/research/memory APPROVED (inalterados), testing
**APPROVED** (browser stack), core-dev PILOT (GitHub, sem PAT — inalterado),
14 novos PILOT por domínio (ativação pendente de projeto/credencial).
Regra preservada: PILOT ≤ 2 MCPs; APPROVED nunca referencia CANDIDATE;
nenhum profile global.

## 28. Registry

`capabilities-v2.json`: 17 → **32 capabilities** (2 browser atualizadas +
15 novas com profiles/agents/skills/tools/permissions/conflicts/fallback).
`status_values` + `PROJECT_ONLY`. Flags de routing inalteradas (OFF).
Healthcheck: 32 resultados, sem vazamento de secrets; MISS honesto para o
não-instalado (verdade por máquina).

## 29. Context Cost

Medido via tools/list: Playwright 25, DevTools full 30 default (~59 com
opt-ins). Tokens UNVERIFIED; custo aceito **somente com testing ativo**.
Demais 2C não medidos (sem ativação). Regra: dezenas de tools → só via
profile on-demand.

## 30. Security

Zero credenciais no repo/docs/evidence/logs (só nomes de env; teste
anti-leak estendido a 15 novos envs). OAuth preferencial; tokens escopo
mínimo; writes financeiros/destrutivos sob deny (exceção só via contrato separado
+ aprovação humana); `skip_elicitations`
proibido; Telemetria/CrUX do DevTools sempre opt-out.

## 31. Fallbacks

GitHub→gh CLI; Playwright→CLI+skill; DevTools→logs/ferramentas manuais;
Supabase→CLI+psql; Neon→neonctl/SQL; Postman→curl/OpenAPI/Newman;
n8n→API/UI; Stripe→CLI/SDK; HubSpot/PostHog/Grafana/DataForSEO→API direta;
Terraform→CLI/docs-only; Cloudflare→REST + skills; GA/Ads→APIs/libs;
Gateway→servidor avulso.

## 32. Tests

- `capability-registry-v2.tests.ps1`: **48/48 PASS** (32 ids, PROJECT_ONLY,
  honestidade estendida aos 20 opcionais, deny-default SEC1, anti-leak 15 envs).
- `mcp-profiles.tests.ps1`: **8/8 PASS** (19 profiles, contrato
  profile-agents ⊆ capability-agents (REV1), APPROVED =
  núcleo + browser stack).
- `capability-healthcheck.ps1`: 32 resultados (14 OK + 18 MISS honestos).
- `skills-healthcheck.ps1`: PASS (110 discoverable; sem skills novas — nada
  a integrar; Supabase skills = upstream a avaliar).
- Tarefas reais browser: DevTools 7/7 (navigate, console warn+error, DOM,
  runtime eval, network, perf), Playwright 5/6 (navigate, snapshot,
  screenshot, console, network; form-fill com arg-shape do snapshot —
  residual menor, não gap).
- Full suites (`run-v3-tests`, distribution, consistency): a executar no CI
  do PR; locais das suites 2C acima verdes.

## 33. Residuals

1. Ativação opt-in dos browser MCPs no user-config (operador).
2. Medição de tokens Playwright/DevTools vs CLI+skill antes de default.
3. Pilots 2C.1–2C.5 aguardando projeto/credencial (gates §§5–26).
4. Pin runtime 2.0.23 vs binário vivo 2.0.24 (drift pré-existente, decisão
   do operador com revalidação; fora do escopo 2C).
5. Form-fill Playwright via snapshot-ref (documentado; revalidar no pilot).
6. Proposta `deny-before-ask` (force-push/docker prune): issue/plan
   separado com SPEC + testes adversariais (sem alteração nesta fase).

## 34. Deferred

- GitHub MCP segue PILOT (sem PAT; gh CLI default) — sem mudança nesta fase.
- Orca `orca-autonomous-development`: junction quebrada vive no
  `agent-config` (fora deste repo, user-owned); entrada já marcada
  REMOVE_CANDIDATE/INVALID no catálogo; limpeza com o operador.
- Probe 2.0.18: referências são histórico/fixtures de teste, não
  healthcheck vivo — nenhum uso obsoleto em produção.
- `ai-memory.ts` (issue #25): nenhuma ocorrência nesta fase — sem regressão.

## 35. Git/PR Evidence

Branch `feat/capabilities-phase-2c` (de `e8e6876`); commits fatiados
(registry, evidence, docs); sem push direto em master. PR/CI/review/merge:
a preencher após abertura do PR.

- branch: `feat/capabilities-phase-2c`
- HEAD: (preencher no merge)
- PR: (a abrir)
- CI: suites 2C verdes localmente; CI completo no PR
- review: reviewer + security-reviewer (ciclo planner) — rodada 1 retornou
  CHANGES_REQUIRED (4 achados: contrato profile-agents, Supabase prod-write,
  run_code_unsafe=RCE, deny-default financeiro); todos integrados (REV1) com
  novos asserts; revalidação 48/48 + 8/8; rodada 2 pendente no PR
- merge: após CI verde + review final

## 36. Final Verdict

**2C READY (PASS com PILOTs honestos).** Cada capability tem decisão
confiável (APPROVED/PILOT/PROJECT_ONLY/CANDIDATE; nenhum REJECTED — nada
foi refutado, apenas não-testado). O sistema decide qual capability, para
qual tarefa, qual agent, qual profile, qual risco e qual fallback — sem
carregar nada globalmente. Decisão da fase cumprida: **Chrome DevTools full
= APPROVED sob profile, sem `--slim` default, não global**.
