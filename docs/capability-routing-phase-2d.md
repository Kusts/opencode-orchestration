# Capability Routing — Phase 2D (Shadow + Advisory-ready)

Data: 2026-10-07. Branch: `feat/capability-routing-phase-2d`. Modo: **SHADOW**.
Flags de routing permanecem OFF (`capability_router.shadow=false`,
`capability_router.active=false`, `skill_routing/mcp_routing/adaptive_ranking=false`).
Nada aqui ativa profile, MCP, skill ou permissão; o resolver **decide**,
o Planner **executa**, o enforcement **autoriza**.

## 1. Capability Resolution

Camada pequena e determinística (`scripts/v3/lib/CapabilityResolver.ps1`):

```text
Task + Project Context + Registry + Skills Catalog + Profiles + Risk Policy
→ Execution Recommendation (shadow, nunca executa)
```

- Config: `source/registry/capability-routing.json` (version 1,
  resolver `2d-shadow-1`): `task_classes` (12), `reason_codes` (14),
  `stack_detectors` (12), `profile_rules` (8), `agent_rules` (9, keyword),
  `skill_rules` (3), `mcp_rules` (5), `risk_model` (LOW/MEDIUM/HIGH/CRITICAL),
  `exclusive_groups` (database-stack), `fallbacks` (8), `deny_rules` (3).
- CLI: `scripts/v3/capability-resolve.ps1 -TaskFile <json> [-ProjectRoot]
  [-OutFile] [-NoTelemetry]`. Fail-safe: exit 0 operacional, exit 2 só
  erro de uso. Sanitização de saídas: `task_id` por regex estrita
  (`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`, inválido → `unknown`); `task_class`
  contra a allowlist das 12 `task_classes` do routing (desconhecida/vazia →
  `unknown` + reason `AMBIGUOUS` preservado). Stdout/OutFile carregam o
  `task_id` validado (correlação efêmera) + enums; a linha JSONL persistida
  carrega o `task_id` como hash SHA256 determinístico (primeiros 16 hex,
  lowercase), nunca o literal. Telemetria sanitizada opcional em
  `cache/v3/telemetry/resolver-YYYYMMDD.jsonl` (só hash + enums, sem
  prompts/secrets); `-TelemetryPath` redireciona a linha para arquivo
  confinado (`cache/v3/telemetry` ou `TEMP`, recusa reparse point, fail-closed).

  `task_id`/`task_class` são identificadores, nunca conteúdo secreto: o `task_id`
  vive em memória/stdout apenas para correlação efêmera (precedente do
  `shadow-route.ps1`), a telemetria persistida registra só o hash do `task_id` +
  enums, e `task_class` fora da allowlist vira `unknown` (com reason `AMBIGUOUS`
  preservado).
- Input: `{task, task_class, project{stack,services,files,repo,environment},
  requested_agent, requested_capabilities, risk_context}` (+ `projectRoot`
  opcional para detecção). Output: `{agents[], skills[] (max 3, só ACTIVE
  do skills-catalog; catálogo ilegível → skills vazio),
  profiles[], pilot_profiles[] (subconjunto PILOT de profiles, array paralelo),
  mcps[], capabilities[], permissions{recommendation,
  enforcement_authority}, risk{level}, fallbacks[], reason_codes[],
  confidence, mode:'shadow'}`.
- Reason codes determinísticos (ex.: `PROJECT_USES_SUPABASE`,
  `TASK_REQUIRES_DATABASE`, `BROWSER_E2E_REQUIRED`, `RISK_PRODUCTION_WRITE`,
  `AMBIGUOUS`); sem textos longos.
- Determinismo: mesma entrada → mesma saída (ordenação Ordinal + regras
  fixas). Skills somente `ACTIVE` do `skills-catalog.json` por construção.
- User override (`requested_agent`/`requested_capabilities`) vence quando
  seguro, mas **nunca** bypassa deny de segurança (financial write segue
  `CRITICAL` + `deny`).

## 2. Project Detection

`Get-ProjectContext -ProjectRoot`: só `Test-Path` sobre os markers do
`stack_detectors` (package.json, pnpm-lock.yaml, bun.lock, requirements.txt,
pyproject.toml, docker-compose.yml, supabase/, prisma/, drizzle/,
terraform/, wrangler.toml, vercel.json). Sem rede, sem secrets, sem
inferência agressiva: **string em README sozinha nunca é evidência**.
`supabase/` exige referência concreta adicional; conflito Supabase+Neon sem
desempate → `AMBIGUOUS` + strip dos dois (fallback seguro, backend genérico).

## 3. Stack Detection

Regra: marker concreto → stack candidata; profile PILOT só com evidência de
projeto + marca `pilot` na saída. Forma da marca: array paralelo
`pilot_profiles[]` (subconjunto de `profiles[]`; `profiles` segue string[]).
Menção textual na task SEM prova (marker filesystem ou `project.stack`
declarado) NÃO sugere profile PILOT: mantém reason informativo
(`TASK_REQUIRES_DATABASE`) mas sem profile/MCP PILOT; DB necessário sem
provedor provado → `AMBIGUOUS` + sem supabase/neon. Exemplos validados no corpus:
Supabase marker + migration → `database-supabase` (PILOT);
E2E/playwright → `testing` (APPROVED); frontend app sem marker browser →
**sem** MCP browser (só sobe com sinal da tarefa); Terraform marker →
`iac` **não** é sugerido para bug CSS (negativo N4).

## 4. Profile Lifecycle

Estados: `inactive → requested → resolved → activated → healthy → used →
released`. Nesta fase o resolver opera até `resolved` (SHADOW); `activated`
em diante é desenho + helper, sem wiring automático:

- Ativação futura: **runtime overlay / session-scoped config**
  (`scripts/v3/capability-profile-overlay.ps1`), nunca mutação do global
  `~/.config/opencode`. Overlay = JSON `{session_id, profiles, mcps,
  generated_at, expires:'session'}` em dir temporário; `-Release` remove.
  O overlay valida exclusividade (ex.: database-supabase + database-neon
  juntos → exit 2) e recusa profile id desconhecido (validado contra
  mcp-profiles.json + profile_rules do routing; registry ilegível →
  recusa fail-closed).
- Gate antes de ativar (quando Advisory/Active um dia ligarem): registry
  status + healthcheck + credencial requerida + risco; sem credencial →
  `profile unavailable` + fallback, nunca falha da tarefa.
- CANDIDATE (Figma, PostHog, Grafana, HubSpot, Google Ads, DataForSEO, …)
  segue sem ativação; o resolver reconhece `capability relevant but
  unavailable` e sugere fallback.

## 5. Session Isolation

Ativação = session scoped. Teste prova: Session A (`testing` + playwright)
e Session B (`core`, sem testing) geram overlays em paths por `session_id`;
B **não** herda Playwright/Chrome DevTools; `expires=session`; release
remove os arquivos. Sem vazamento entre sessões.

## 6. Agent / Skill / MCP Routing

- Agents: migration→`database-engineer`, API→`backend-engineer`,
  E2E→`tester`, runtime browser bug→`debugger`, UI→`frontend-engineer`,
  architecture→`architect`, ambiguity→`requirements-analyst`,
  research→`researcher`, trivial→`coder`. Sem inflar contagem.
- Skills (curado, poucas, max 3): bug→`systematic-debugging`,
  feature→`test-driven-development`, validação final→
  `verification-before-completion`. Nunca 10 skills numa tarefa simples.
- MCPs: E2E→Playwright; runtime/perf→Chrome DevTools full (só com reason
  codes `BROWSER_RUNTIME_DEBUG`/`NETWORK_DEBUG`/`PERFORMANCE_TRACE`/
  `CONSOLE_DIAGNOSTICS`/`DOM_INSPECTION`, nunca só por ter frontend);
  docs→Context7 (`LIBRARY_DOCS_REQUIRED`/`VERSION_SPECIFIC_API`/
  `UNKNOWN_FRAMEWORK_BEHAVIOR`); research→Jev (incerteza alta, nunca
  trivial); memory→AI Memory diferenciando read/write/handoff, com
  project scope preservado.
- Playwright **não** sobe para ler CSS (negativo N2); Context7/AI Memory
  transversais mas só sob sinal.

## 7. Risk Resolution

`LOW` (read docs, edit reversível) / `MEDIUM` (edit amplo, browser
automation) / `HIGH` (DB migration, production deploy) / `CRITICAL`
(financial mutation). Fluxo: resolver recomenda → policy valida →
enforcement permite/pergunta/nega. Resolver **nunca** bypassa enforcement.

## 8. Fallbacks

Toda decisão com MCP carrega fallback: Playwright MCP→Playwright CLI +
skill; GitHub MCP→gh CLI; DevTools→Playwright diagnostics/browser logs;
Supabase/Neon MCP→CLI/SQL/API; Context7→docs oficiais via fetch direto +
pinned version guide; Jev→pesquisa manual via docs oficiais + advisory note;
AI Memory→notas locais + handoff em arquivo. Sem credencial ou MCP indisponível →
fallback, sem derrubar a tarefa.

## 9. Shadow Mode (ativo)

Calcula tudo, altera nada. Corpus: 12 casos (5 positivos, 5 negativos,
1 conflito, 1 ambiguidade) em
`evidence/capabilities-phase-2d/shadow-corpus-2026-10-07.json`; resultados em
`shadow-results-2026-10-07.json`. Métricas: agent 12/12, profile 12/12,
over-activation 0, under-activation 0, fallbacks informativos 4/12,
permission bypass 0. Gate (≥90%, 0 over-activation crítica, 0 bypass):
**PASS** → elegível a Advisory.

## 10. Advisory Mode (ready, não promovido)

Formato de recommendation já é consumível pelo Planner
(`recommended_profile/agent` + reasons), mas o Planner desta fase continua
decidindo pela política atual; nenhuma ativação automática foi ligada.
Promoção a Advisory é decisão do operador com esta evidência.

## 11. Active Mode (fora de escopo — NÃO promovido)

Requereria enforcement autoridade + activation session-scoped + evidence +
fallback obrigatórios, com estabilidade demonstrada em Advisory. Fase 2D
encerra em **SHADOW com Advisory-ready** (arquitetura `ADVISORY` atingida
como desenho + contrato, execução permanece Shadow). É o sucesso definido
na seção 56: terminar em ADVISORY é PASS; terminar em SHADOW sólido com
Advisory pronto também atende o critério (sem forçar Active imaturo).

## 12. Deny-before-Ask (investigação separada)

Residual Fase 2A/B confirmado: `git push * = ask` sem `deny` para
`--force`/`-f`/refspec `+`; `docker system prune` cai em allow. Semântica
V2 modelada como last-match-wins (não provada no binário exato). Veredito:
**SPEC separada + HOLD de implantação** (nenhum patch improvisado).
Detalhes no closure §14.

## 13. Manifest por projeto e overrides

`.opencode/capabilities.json` (preferred/disabled/risk_overrides) é
**opcional** e posterior; auto-detection segue fallback. Override explícito
do usuário vence auto-routing quando seguro, nunca contra deny de segurança.

## Referências

- `source/registry/capability-routing.json`
- `scripts/v3/lib/CapabilityResolver.ps1`
- `scripts/v3/capability-resolve.ps1`
- `scripts/v3/capability-profile-overlay.ps1`
- `tests/distribution/capability-routing-phase2d.tests.ps1`
- `docs/audits/opencode-capability-routing-phase-2d-closure-2026-10-07.md`
