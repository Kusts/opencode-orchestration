# Closure — Capability Routing Phase 2D (2026-10-07)

Branch: `feat/capability-routing-phase-2d`. Veredito: **PASS (SHADOW + Advisory-ready; Active NÃO promovido)**.

## 1. Scope

Transformar o Capability Registry de catálogo/inventory em camada de decisão:
Task → Project Context → Planner → Capability Resolution → Profile Selection →
Agent + Skills + MCPs → Permissions/Risk → Execution → Validation → Evidence →
Profile release. Sem adicionar capabilities (foco em *usar melhor*), sem ativar
routing completo de uma vez (Shadow → Advisory → Active).

## 2. Initial State

- Phase 2A: PASS. Phase 2B: PASS. Phase 2C: PASS (closures em `docs/audits/`).
- `master` = `1bc0e14` (Merge PR #27, Phase 2C). Tree limpa confirmada.
- Registry V2 (~31 capabilities), skills catalog (105), 19 profiles, enforcement,
  AI Memory / Context7 / Jev / Playwright / Chrome DevTools full APPROVED.
- Flags routing OFF: `capability_router.shadow=false/active=false`,
  `skill/mcp/adaptive/telemetry/reconciler=false`. Ao final da fase: **inalteradas**.

## 3. Resolver Architecture

- `source/registry/capability-routing.json` (v1, `2d-shadow-1`): 12 task_classes,
  14 reason_codes, 12 stack_detectors, 8 profile_rules, 9 agent_rules, 3 skill_rules,
  5 mcp_rules, risk_model LOW/MEDIUM/HIGH/CRITICAL, exclusive_group database-stack,
  8 fallbacks, 3 deny_rules.
- `scripts/v3/lib/CapabilityResolver.ps1`: `Get-ProjectContext` (Test-Path only) +
  `Invoke-CapabilityResolve` (determinístico, mesma entrada → mesma saída).
  Nunca executa ferramentas; Planner executa; enforcement autoriza.
- CLI `scripts/v3/capability-resolve.ps1` (fail-safe, exit 0/2) + helper
  `scripts/v3/capability-profile-overlay.ps1` (session-scoped, nunca global).
- PS 5.1, ASCII-only, sem segredos em outputs (só nomes de env, nunca valores).

## 4. Project Detection

File markers concretos (package.json, pnpm-lock.yaml, bun.lock, requirements.txt,
pyproject.toml, docker-compose.yml, supabase/, prisma/, drizzle/, terraform/,
wrangler.toml, vercel.json). README sozinho nunca é evidência. Coberta por
fixtures TEMP na suíte.

## 5. Stack Detection

Marker → stack candidata; PILOT só com prova de projeto (marker OU project.stack;
REV1 separou menção textual de prova). Supabase+Neon sem desempate → AMBIGUOUS +
strip dos dois (fallback backend genérico).

## 6. Agent Routing

migration→database-engineer; API→backend-engineer; E2E→tester; runtime bug→debugger;
UI→frontend-engineer; architecture→architect; ambiguity→requirements-analyst;
research→researcher; trivial→coder. Override do usuário vence quando seguro,
nunca contra deny.

## 7. Skill Routing

Max 3, só ACTIVE do catálogo (validado em runtime, REV1): bug→systematic-debugging;
feature→test-driven-development; validação→verification-before-completion.

## 8. MCP Routing

E2E→playwright-mcp; runtime/perf→chrome-devtools-mcp (só com reason codes de
diagnóstico, nunca só por ter frontend); docs→context7; research→jev (nunca
trivial); memory→ai-memory (read/write/handoff, project scope). Playwright NÃO
para ler CSS (negativo provado).

## 9. Profile Composition

frontend+testing+database-supabase permitido; `testing` já contém
playwright+chrome-devtools sem duplicar (mcps deduplicados). Campo
`pilot_profiles[]` marca PILOT (REV1).

## 10. Profile Lifecycle

inactive→requested→resolved→activated→healthy→used→released. Fase opera até
`resolved` (SHADOW); ativação futura = runtime overlay/session-scoped config,
nunca mutação global. Gate (status+healthcheck+credencial+risco); sem
credencial → unavailable + fallback.

## 11. Session Isolation

Overlays por `session_id`, `expires=session`, `-Release` remove. Teste prova:
Sessão A (testing) vs B (core) sem herança de Playwright/DevTools.

## 12. Risk Model

LOW (docs/edit reversível) / MEDIUM (edit amplo/browser) / HIGH (migration,
deploy prod) / CRITICAL (financial). Financeiro → deny; resolver recomenda,
enforcement decide.

## 13. Permission Resolution

`permissions{recommendation, enforcement_authority:'advisory-shadow'}` projetado
no CLI (REV1). Bypass = 0 (refund mantém deny mesmo com override).

## 14. Deny-before-Ask Investigation

Investigação separada (security-reviewer, só leitura): `git push *=ask` sem deny
para `--force`/`-f`/refspec `+`; `docker system prune` em allow; semântica V2
modelada last-match-wins (não provada no binário). Veredito: **SPEC separada +
HOLD de implantação**; patch de poucas linhas rejeitado (CHANGES_REQUIRED).
Sem patch improvisado nesta fase.

## 15. Shadow Mode

Calcula tudo, altera nada. Corpus 12 casos
(`evidence/capabilities-phase-2d/shadow-corpus-2026-10-07.json`).

## 16. Shadow Results

Agent 12/12, profile 12/12, over-activation 0, under-activation 0,
permission bypass 0. Gate (≥90%, 0 over-crítica, 0 bypass): **PASS**.
Resultados em `shadow-results-2026-10-07.json` (count 12, `2d-shadow-1`).

## 17. Advisory Mode

Contrato pronto (`recommended_profile/agent` + reasons + pilot marks), Planner
segue na política atual. Promoção = decisão do operador. Estado: **ready, não
promovido** (suficiente para PASS §56).

## 18. Active Mode Decision

**NÃO promovido** — correto para a maturidade (exige estabilidade em Advisory +
wirings operator-owned). Fase encerra SHADOW com Advisory-ready = PASS.

## 19. Real Project Pilots (somente leitura)

- Synkroo: stacks node/containers/cloudflare (package.json, docker-compose.yml,
  wrangler.toml); sem markers DB → sem Supabase/Neon (conservador correto).
- IPTV: node/containers; sem marker browser → browser MCPs só sob sinal da tarefa.
- opencode-orchestration: sem markers (projeto PS) → fallback por texto da tarefa.
- Meu Ted: **NOT RUN** (sem checkout local; só `.ted-probe`).
Nenhum projeto externo modificado; nenhuma credencial usada.

## 20. Negative Tests

5 negativos verdes: Stripe↛frontend; DevTools↛docs-only; Supabase↛Neon-only;
Terraform↛iac-para-CSS; Google Ads↛analytics-only.

## 21. Fallbacks

8 MCPs selecionáveis com fallback (Playwright CLI, gh CLI, diagnostics/logs,
Supabase/Neon CLI+SQL, docs oficiais, pesquisa manual, notas locais).

## 22. Telemetry

Opcional, sanitizada (só ids/enums; JSONL com `task_id` = hash SHA256-16,
REV2 R3-APPROVED; task_class por allowlist). Sem prompts/secrets. Linhas
pré-REV2 com literais: limpeza = decisão do operador (residual).

## 23. Tests

`tests/distribution/capability-routing-phase2d.tests.ps1`: **PASS 353/0**
(schema, detection, 12 casos igualdade exata, 5 negativos, conflito,
ambiguidade, isolamento+release, determinismo 2x, sanitização canário exato
com telemetria, schema '{}'/malformado/inexistente, overlay exit 2).
Regressão: registry 48/0, profiles 8/0, skills 18/0, planning 12/0,
package-consistency 16/0. Quirk conhecido: wording do corpus é load-bearing
(prefix-match + ordem de regras) — mudança no resolver quebra a suíte
explicitamente (comportamento desejado).

## 24. Security

Review independente: R1 CHANGES_REQUIRED (7) → REV1 → R2 2 novos →
REV2 → **R3 APPROVED** (sem HIGH/MEDIUM nos deltas). Tester: PASS (R2).
Enforcement autoridade intacta; financeiro CRITICAL+deny; telemetria sem
literais.

## 25. Performance

Resolver offline, sem rede; suíte completa em segundos; sem sistema pesado
(telemetria JSONL bounded, custo zero em `-NoTelemetry`).

## 26. Residuals

Reais e honestos: (a) pin 2.0.23 vs runtime 2.0.24 (sem bump, fora de escopo);
(b) 2 FAILs config-format pré-existentes (issue #21); (c) ORCA junction
(user-owned, fora do repo); (d) issue #25 ai-memory.ts (sem ocorrência);
(e) DE22307F (não-bloqueante); (f) `-RoutingPath` sem confinamento (só parse);
(g) heurística `stripe`→CRITICAL é deny-by-default intencional;
(h) regra research-subsume-docs é julgamento mínimo reversível (3 linhas);
(i) telemetria pré-REV2 com literais (limpeza operator-owned);
(j) Active Mode + promoção Advisory + manifest `.opencode/capabilities.json` =
decisões de operador futuras.

## 27. Git/PR Evidence

- Branch `feat/capability-routing-phase-2d` de `master` limpo (`1bc0e14`).
- Nenhum push em master. Arquivos: 1 modificado (`.gitignore`, +1 exceção
  `!evidence/capabilities-phase-2d/`) + 8 novos (routing.json, 3 PS1, teste,
  docs, 2 evidence). `git diff --check` limpo.
- Ciclo: coder → tester → reviewer, R1(7) → REV1 → R2(2) → REV2 → R3 APPROVED.
- PR/CI/merge: pendente decisão do operador (push/PR não executados nesta sessão).

## 28. Final Verdict

**Phase 2D: PASS.** Resolver determinístico + detection confiável + agent/skill/
MCP/profile routing confiáveis + risco integrado + 0 bypass + isolamento de
sessão + shadow 12/12 + Advisory-ready. Arquitetura final: **ADVISORY**
(contrato pronto e validado; execução permanece Shadow até decisão do operador).
Princípio atendido: menos ativação desnecessária + mais contexto + mais
segurança + mais previsibilidade.

## PR #28 Review Findings Closure

Review Codex (bot `chatgpt-codex-connector`) sobre o HEAD `c354a6e`:
COMPLETED com 4 findings P2, todos endereçados em commit corretivo separado,
sem reescrita de histórico e sem squash.

```text
original reviewed SHA: c354a6e
findings: 4 P2 (todos endereçados, 0 pendentes)
fix commit: 4a1acbe6e2b1e1964c58e7f5396fd55af5fa633d
  ("fix(routing): address PR #28 review findings", 4 arquivos, +125/-9)
CI final: run 37650051106, 5/5 SUCCESS no SHA 4a1acbe
  (ps51, ps7, smoke V1, smoke V2, v2-lane)
review final: 4/4 threads Codex respondidas e resolvidas; 0 unresolved
security: deterministic fallback (ver abaixo) — PASS
merge commit: c6c15d7a21a3f78e8680dd20fa653b61ae68519f
  (2026-10-07 17:02:17 UTC, método merge commit, sem auto-merge)
```

| Finding | Fix | Test | Final |
|---|---|---|---|
| Supabase false proof (dir `supabase/` vazio virava stack/prova) | `Get-ProjectContext` exige evidência concreta (`config.toml`/`config.json`/`migrations`/`seed.sql`/`schema.sql`/`functions`); dir vazio é ignorado | Fixture controle `supabase/` vazio → sem stack, sem `database-supabase`, AMBIGUOUS; com `config.toml`+`migrations/` → stack `supabase` | PASS |
| Partial profile MCP map (mapa hardcoded parcial; `product`→`mcps: []`) | Overlay deriva MCPs de `source/registry/mcp-profiles.json` (`$mcpDoc.profiles`); nenhum mapa hardcoded | `product`→`posthog-mcp`, `core-dev`→`github-mcp`, `testing`→`playwright-mcp`+`chrome-devtools-mcp`, `backend`→`postman-mcp` | PASS |
| Raw task_class (valor bruto fora da allowlist influenciava risk/agent/profile) | `capability-resolve.ps1` sobrescreve `task_class`/`task_type` no `$resolveInput` com o valor sanitizado (vazio se inválido) antes de `Invoke-CapabilityResolve`; publicado segue `unknown` | `task_class: "production"` em tarefa read-docs → publica `unknown`, risk LOW, sem `RISK_PRODUCTION_WRITE`, perm `allow` | PASS |
| release false-prod (`review release notes` virava HIGH/deny) | `$isProd` exige `production`/`producao`/`deploy`; token `release` isolado não conta | `review release notes` → LOW/`allow` sem `RISK_PRODUCTION_WRITE`; `deploy production hotfix` → HIGH + `RISK_PRODUCTION_WRITE` + `deny` | PASS |

Notas de auditoria (sem alterar fatos históricos acima):

- Contagens atualizadas pós-fix: phase2d **372/0** (§23 registra 353/0 do
  baseline c354a6e — fato histórico preservado); registry 48/0, profiles 8/0,
  skills 18/0, planning 12/0, package-consistency 16/0, `git diff --check`
  limpo. Shadow corpus **12/12 agreement, 0 over/under-activation,
  0 critical errors** (`shadow-results-2026-10-07.json` inalterado).
- CI: primeira execução no novo SHA deu 4/5 (v2-lane falhou em 1 assert
  FIX4-2b do `OrchestrationRuntimeWatchdogEnforcement` — teste de kill de
  processo timing-sensível, arquivo fora do delta, flaky pré-existente já
  documentado em `program-status.json`; ps51/ps7/smokes passaram com o
  delta). `gh run rerun --failed` → **5/5 SUCCESS** no mesmo SHA. Nenhum
  resultado do SHA anterior foi reutilizado.
- Review: re-request ao bot Codex indisponível via API (não é collaborator,
  HTTP 422) e nenhum auto re-review foi disparado pelo push; subagents
  reviewer/security-reviewer atingiram limite de uso. Fallback determinístico
  aplicado e registrado: inspeção integral do diff c354a6e..4a1acbe, provas
  explícitas por finding (seção acima), verificação de ausência de scope
  creep (sem Active Mode, sem flags, sem pins, sem permission engine) e
  tester independente PASS. Threads Codex: 4/4 respondidas com evidência e
  marcadas resolved via GraphQL.
- Arquitetura final permanece **SHADOW + ADVISORY-ready**; flags de routing
  continuam OFF; Active Mode segue decisão futura de operador.
