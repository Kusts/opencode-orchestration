# Auditoria Operacional — Provisionamento de Capabilities OpenCode (2026-10-10)

Veredito: **PARTIAL**. Inventário e healthchecks confirmados (32 capabilities,
19 profiles, 105 skills catalogadas, 110 descobertas brutas); 3 MCPs core
configurados **diretamente no config de usuário/global ativo (machine-global) e
invocados em sessão real**; browser stack comprovada em
**runtime real efêmero** (V2 exato 2.0.23, perfil `testing` temporário);
GitHub MCP e os especializados **não configurados** (deferidos, sem
necessidade/credencial); V1 **NOT_VERIFIED/UNAVAILABLE** (sem binário/perfil
nesta máquina); isolamento de nova sessão sem profile **NOT_VERIFIED**
(porta 49374 ocupada por serviço do usuário). Nenhuma alteração de runtime,
config, registry, permissões, plugins, skills ou credenciais.

Distinção registro-vs-config: os 3 MCPs core estão **diretamente no bloco
`mcp` do config de usuário/global ativo** (machine-global, sempre carregados);
o registro declara **19 named profiles** com **nenhum profile ID nomeado
explicitamente ativo** nesse config — o que **não** implica zero entradas MCP
globais (§5, §11). Finding F1 (drift de policy/config) fica registrado para
decisão do operador (§11, §19): **nenhuma mudança de config é proposta nesta
auditoria**.

## 1. Escopo e objetivo

Auditar operacionalmente o sistema de capabilities (registry V2, MCPs, skills,
runtimes V1/V2, plugin V2) no estado vivo desta máquina, separando **decisão**
(o que o registry determina) de **estado observado por máquina** (o que os
healthchecks retornam hoje) e distinguindo **indisponível/não-verificado** de
**verificado em runtime real**. Entregáveis: este relatório +
`evidence/capabilities-provisioning-2026-10-10/runtime-audit.json` (sanitizado).
Sem mudança de código, config ou política.

## 2. Convenções e estado de paths (confirmado)

- Convenção de docs de auditoria deste repo: pt-BR, veredito no topo, seções
  numeradas, evidência em `evidence/<slug>/….json`, testes referenciados por
  caminho exato (modelo: `docs/audits/opencode-capabilities-phase-2c-closure-2026-10-07.md`,
  `docs/audits/opencode-capability-routing-phase-2f-closure-2026-10-08.md`).
- Paths lidos e existentes: `docs/audits/*` (6 closures), `docs/mcp-profiles.md`,
  `docs/GOVERNANCE.md`, `source/registry/{capabilities-v2,mcp-profiles,skills-catalog,plugin-capabilities,capability-flags,runtime-versions,jev-advisory-policy}.json`,
  `tests/distribution/*`, `evidence/capabilities-phase-2c/`.
- Escrita: apenas este relatório e o JSON de evidência. O diretório cai sob
  `evidence/*` do `.gitignore`; o JSON será incluído explicitamente no PR via
  `git add -f`, sem adicionar exceção geral ou alterar regras de ignore.

## 3. Baseline Git e worktree

- `git fetch origin --prune` executado com sucesso. `origin/master` e base/HEAD
  desta branch no início: `b38c92bc8b3ab334a9dffad609f3515350336061` (`b38c92b`).
- Branch de trabalho isolada: `feat/opencode-capabilities-provisioning-validation`,
  worktree `C:/Users/walis/AppData/Local/Temp/opencode/capabilities-provisioning-b38c92b`.
- Checkout original permanecia **sujo** em
  `acceptance/autonomous-core-v0.1.2-2026-10-09` (7 edições tracked + testes/evidências
  untracked de outra sessão). O diff dos adaptadores altera **apenas** o fallback
  de modelo barato para `step-5-preview-free`; **nenhuma** mudança de
  registry/profile de capabilities. Não foi modificado por esta auditoria.
- Worktrees existentes: original, `opencode-orchestration-2g` em
  `feat/capability-advisory-observability-phase-2g` (`0d6ffa9`) e baseline
  temporário desanexado (detached). Autonomous Core não foi inspecionado além do
  diff de adaptadores.
- PRs independentes (não tocados): **#54** aberto (Phase 2G, advisory
  observability collector, CI 5/5 verde, sem decisão de review) e **#23** aberto
  e atrás do master (auditoria local de 2026-10-06).

## 4. Testes de baseline (pré-existentes; sem escrita pela auditoria)

| Suíte | Resultado | Leitura |
|---|---|---|
| `scripts/test-package-consistency.ps1` | **PASS 16/16** | baseline íntegro |
| `scripts/v3/run-v3-tests.ps1` | 80 PASS / **4 FAIL** / 6 SKIP (total 90) | 2 asserts de identidade de observabilidade (`w1c`, `w14` — comportamento worktree-id/runtime indisponível) + 2 testes que esperam prefixo DE22307F do `opencode.json` vivo (SHA real inicia `C1BB84F2`) |
| `tests/distribution/run-distribution-tests.ps1` | 19 PASS / **1 FAIL** / 1 SKIP | saída real inclui smoke V2 **skipped** (`opencode` ausente no PATH de um fixture) e mismatch de ambiente V1/V2; a suíte que falhou **não foi extraída individualmente** — não afirmar causa |

Classificação honesta: as falhas de **baseline** foram **observadas antes de
qualquer edição desta auditoria**; os sintomas envolvem identidade de
worktree/runtime e divergência de hash do `opencode.json` vivo, mas a
**causa-raiz não foi estabelecida** — não se afirma que sejam derivadas de
ambiente/worktree/config. Nenhuma escrita foi feita para "consertar" o baseline.

## 5. Inventário machine-observed (healthchecks de hoje)

- `scripts/v3/capability-healthcheck.ps1 -Json`: **32/32** capabilities no
  registry; saúde por máquina verídica — repo-managed saudáveis; **AI Memory,
  Context7 e Jev installed/configured/healthy**. GitHub MCP, MCPs
  especializados, Playwright MCP e Chrome DevTools MCP **não configurados** no
  config ativo. CLIs presentes: OpenCode, Git, GitHub CLI, Playwright CLI,
  Docker CLI. Nenhuma entrada de browser MCP em config ativo/global.
- `scripts/v3/skills-healthcheck.ps1 -Json`: **PASS**.
- Chaves MCP do config V2 ativo (resumo de nomes/presença; ver §14 sobre
  exposição de valores de segredo):
  `context7`, `jev`, `servers.ai-memory`; `mcp.playwright`,
  `mcp.chrome-devtools` e `mcp.github` **ausentes**.
- **Escopo dessas 3 chaves:** estão **diretamente no bloco `mcp` do config de
  usuário/global ativo** (machine-global configuradas/conectadas e carregadas
  diretamente), **não** provadas como session-scoped por named profile. O fato
  de o registro ter 19 named profiles e **nenhum** profile ID explicitamente
  ativo nesse config **não** significa zero entradas MCP globais (ver §11).

## 6. Decisão vs estado observado (dimensões separadas)

Os campos `desired`/`observed` do registry têm data própria (2026-10-06/07) e
**podem estar defasados**; a coluna "máquina hoje" é a verdade observável desta
auditoria (2026-10-10). Nenhuma das duas dimensões foi reescrita.

| Recurso | Registry desired | Registry observed (datado) | Máquina hoje (healthcheck) | Situação |
|---|---|---|---|---|
| AI Memory | ACTIVE | ACTIVE (2026-10-06) | installed+configured+healthy; `memory_status` real | **verificado em runtime real** |
| Context7 | ACTIVE | INSTALLED (2026-10-06) | healthy; `resolve-library-id` + `query-docs` ok | **verificado em runtime real** |
| Jev | ACTIVE | INSTALLED (2026-10-06) | healthy; `jev_check` ok | **verificado em runtime real** |
| GitHub MCP | CANDIDATE | CANDIDATE (2026-10-07) | **não configurado**; gh CLI presente e funcional | deferido (§8) |
| Playwright MCP | ACTIVE | CANDIDATE (2026-10-07) | não configurado no config ativo | aprovado por decisão 2C; prova **efêmera** (§9) |
| Chrome DevTools MCP | ACTIVE | CANDIDATE (2026-10-07) | não configurado no config ativo | idem (§9) |
| 14 especializados + Docker Gateway | CANDIDATE/PROJECT_ONLY | CANDIDATE (2026-10-07) | **não configurados**, healthcheck false | deferidos (§10) |

## 7. MCPs core — invocados na sessão real

Operações reais na sessão OpenCode atual (executadas pelo Planner/sessão, **não**
por um worker `researcher`/`coder`):

- `ai-memory.memory_status` → contagens reais do projeto retornadas.
- `context7.resolve-library-id` + `context7.query-docs` (docs oficiais
  Playwright) → resultados retornados.
- `jev.jev_check` → `{likely: true, probability: 0.62}`.

Consequência: os 3 MCPs do núcleo não são apenas "instalados" — têm **caminho de
invocação comprovado** nesta sessão. Escopo: são machine-global (diretos no
`mcp` do config de usuário/global); a invocação em sessão real comprova o
caminho, **não** que sejam session-scoped por named profile. Nenhum valor de
segredo foi exposto ao agente, impresso ou persistido (detalhe em §14).

## 8. GitHub MCP + gh CLI

**Decisão: PILOT-APPROVED (registry CANDIDATE) — deferido.**

- Não configurado no config ativo; healthcheck false; nenhum PAT solicitado ou
  impresso.
- Caminho de menor custo hoje: `gh` CLI **instalado**; leituras reais
  bem-sucedidas (lista de PRs, issue #25).
- Fallback preservado: `gh` CLI é o default pontual; GitHub MCP remoto
  (`/readonly`, toolsets `repos,issues,pull_requests`) permanece opt-in do
  profile `core-dev` — ver `docs/mcp-profiles.md`.

## 9. Browser MCPs (Playwright + Chrome DevTools) — verificação efêmera 2026-10-10

**Decisão: APPROVED (Phase 2C, decisão do operador 2026-10-07) sob profile
`testing`, nunca global; hoje comprovado em runtime real efêmero, sem
instalação persistida.**

- Pacotes obtidos apenas pelo **cache local persistente do npx** (não instalados globalmente; o cache permanece até expurgo próprio).
- Em config MCP `testing` temporário, o binário V2 **exato 2.0.23** foi
  lançado; **uma** execução de `opencode mcp list` conectou `chrome-devtools` e
  `playwright`.
- Probe stdio JSON-RPC independente — `@playwright/mcp@0.0.83`, headless +
  Chrome isolado: **25 tools**; navegou fixture local, snapshot do H1, clique no
  botão de teste, **H1 alterado verificado**, warning de console, request local
  `/api`, screenshot; `browser_close` e saída de processo 0.
- `chrome-devtools-mcp@1.10.1` **FULL** (sem `--slim`) com
  `--headless --isolated --no-usage-statistics --no-performance-crux`: **30
  tools**; navegação do fixture, snapshot do DOM, warning de console, request
  `/api`, início/parada de trace de performance — todos OK; `close_page` e
  saída 0.
- Artefatos temporários de browser foram movidos **para fora do worktree**
  (`C:/Users/walis/AppData/Local/Temp/opencode/capability-audit/playwright-artifacts`).
- Ressalva: o `desired=ACTIVE` do registry para esses dois MCPs continua sem
  correspondência no config ativo — a ativação opt-in é **decisão do operador**
  e não foi feita aqui.

## 10. MCPs especializados (14 de domínio + Docker Gateway)

**Decisão para todos: DEFER (manter CANDIDATE/PROJECT_ONLY) — sem configuração,
sem credencial, sem necessidade atual de projeto; política e fallbacks
preservados.**

Healthcheck false para todos; registry `observed=CANDIDATE` (2026-10-07)

| Recurso | Registry desired | Decisão desta auditoria | Razão / fallback |
|---|---|---|---|
| Supabase MCP | PROJECT_ONLY | **DEFER** | sem projeto/credencial; fallback Supabase CLI + SQL |
| Neon MCP | PROJECT_ONLY | **DEFER** | idem; fallback neonctl/SQL |
| Stripe MCP | PROJECT_ONLY (risco critical) | **DEFER** | sem projeto com pagamentos; fallback CLI/SDK |
| n8n MCP | PROJECT_ONLY | **DEFER** | sem instância/credencial; fallback API/UI |
| Postman MCP | CANDIDATE | **DEFER** | benchmark vs curl/OpenAPI pendente; CLI + skill é o primário |
| Figma MCP | CANDIDATE | **DEFER** | sem projeto de design; leitura/codegen quando houver |
| PostHog MCP | CANDIDATE | **DEFER** | sem projeto/credencial; API direta |
| HubSpot MCP | CANDIDATE | **DEFER** | sem conta; escrita polui funil (ask) |
| Grafana MCP | CANDIDATE | **DEFER** | sem instância; leitura primeiro |
| Terraform MCP | CANDIDATE | **DEFER** | sem IaC real validado; operações OFF |
| Cloudflare MCP | CANDIDATE | **DEFER** | skills `cloudflare*` já cobrem conhecimento; MCP sem ganho medido |
| Google Analytics MCP | CANDIDATE | **DEFER** | oferta experimental; sem propriedade |
| Google Ads MCP | CANDIDATE | **DEFER** | release sem escrita; sem conta |
| DataForSEO MCP | CANDIDATE | **DEFER** | pay-per-call; sem conta/necessidade |
| Docker MCP Gateway | CANDIDATE | **DEFER** | infra de execução; nunca decide; sem pilot comparativo |

Nota de contagem: são **15 entradas especializadas** no registry (14 de
serviço/domínio + 1 Gateway de execução); o healthcheck de hoje tratou todas
como não configuradas, coerente com o `observed=CANDIDATE`.

## 11. Profiles (19)

Fonte: `source/registry/mcp-profiles.json` — **19 profiles** confirmados.
APPROVED: `core` (context7), `research` (context7+jev), `memory` (ai-memory) e
`testing` (playwright + chrome-devtools, opt-in com tarefa real). PILOT:
`core-dev` (github-mcp, sem PAT) e 14 de domínio (`database-supabase`,
`database-neon`, `backend`, `frontend`, `product`, `infra`, `iac`, `cloud`,
`observability`, `automation`, `payments`, `sales`, `growth-google`,
`growth-seo`). **Nenhum named profile ID explicitamente ativo** no config de
usuário/global — ativação de profile é sempre opt-in por tarefa/projeto,
conforme `docs/mcp-profiles.md`.

**Distinção (perfis ≠ entradas MCP):** a afirmação acima refere-se aos 19 named
profiles, **não** às entradas MCP. O config global ativo **já inclui e carrega
diretamente** 3 MCPs core (`context7`, `jev`, `servers.ai-memory`) no bloco
`mcp` — machine-global configurados/conectados, **não** provados como
session-scoped por named profile; portanto o config global **não** tem "zero
MCPs globais" (ver §5).

**Finding F1 — drift de policy/config (decisão do operador):** os 3 MCPs core
estão no config global de forma always-on (machine-global), enquanto o modelo
de profiles é opt-in session-scoped por tarefa. É um **finding observado de
drift**, não falha de verificação. Fica registrada a decisão ao operador de
manter os 3 MCPs core globais **ou** migrá-los para um **mecanismo
session-scoped seguro** (ex.: ativação opt-in via named profile) — **sem
propor mudança de config nesta auditoria** (ação em §19). Nenhuma mutação foi
feita em profiles, flags, config, permissões ou credenciais.

## 12. Skills (105 catálogo / 110 descobertas)

- Catálogo: **105** entradas (`skills-catalog.json`).
- Descobertas brutas: **110** (103 na raiz `agents`, 7 na raiz `opencode`);
  **5 IDs sombreados** (4 idênticos + par divergente documentado de
  `hybrid-development`; vencedor `~/.config/opencode/skills`, later-wins);
  `duplicate_ids=0`; **1 inválida** (`orca-autonomous-development`, junction
  quebrada — user-owned, não removida); `using-superpowers` deprecated.
- CORE gate **9/9 PASS**; skills CORE intactas (nenhuma remoção).
- Contagens do healthcheck (esquema do catálogo, não soma livre):
  CORE 9, RECOMMENDED 24, DOMAIN 44, PERSONAL 20, EXPERIMENTAL 4,
  PROJECT_SPECIFIC 1, REDUNDANT 1, DEPRECATED 1. `REMOVE_CANDIDATE` é
  classificação adicional do catálogo — não somar sem considerar o esquema.
- Arquivos pessoais/do usuário preservados (nenhuma remoção ou move).

## 13. Runtime V1/V2 e plugin V2

- **V2**: binários globais `opencode` e `opencode2` respondem **2.0.26**
  (drift vs pin `2.0.23` de `runtime-versions.json`). Existe um binário de
  **perfil V2 privado** que retorna exatamente `opencode v2.0.23`. Lifecycle
  smoke V2 (`scripts/ci/smoke-opencode-v2-lifecycle.ps1 -BinaryPath <exe
  exato 2.0.23>`) **PASS** — home temporário isolado, porta livre 63016,
  serviço existente em 49374 e config global **intocados**, cleanup ok.
- **V1**: nenhum binário/perfil encontrado sob
  `.opencode-orchestration/profiles` → **NOT_VERIFIED/UNAVAILABLE**. Nenhum
  claim de smoke V1.
- **Plugin V2** (`scripts/ci/plugin-healthcheck.ps1`): **FAIL** do conjunto
  causado **única e exclusivamente** pelo backup proibido/inativo
  `ai-memory-opencode2.ts.bak-1791360135` presente na raiz de plugins ativa.
  `ai-memory-opencode2.ts` e `orchestration-enforcement.js` presentes,
  carregados e saudáveis (shape `v2_object`), **0 erros de carga**; legado
  `ai-memory.ts` ausente. Issue **#25** segue aberta; último comentário
  (2026-10-09) sem repro de regeneração; regeneração recorrente anterior não
  resolvida. Backup **não** foi apagado; arquivos do usuário no diretório
  (`orca-opencode-status.js`, README) intactos.

## 14. Segurança

- Nenhum valor de segredo foi **exposto ao agente**, **impresso** ou
  **persistido** neste relatório nem no JSON de evidência (o resumo de chaves
  MCP trouxe apenas nomes/presenças). O healthcheck de capabilities lê o config
  ativo e verifica internamente a presença de variáveis de ambiente; sua saída
  observada continha apenas nomes/presença, sem valores. **Não** se afirma que
  nenhum valor de segredo foi lido internamente pelas ferramentas. Nenhuma
  credencial criada, rotacionada ou requisitada; nenhum PAT.
- Nenhuma mudança em permissões, config global, registry, plugins, skills ou
  profiles.
- Efeitos de rede/produção: nenhum além de chamadas públicas de docs/MCP e do
  fixture de browser em **loopback**. Os pacotes de teste foram baixados pelo
  npx para o cache local persistente; não houve instalação global.
- `run_code_unsafe`/avaliação de página restritos ao fixture local; sem sessão
  autenticada pessoal.

## 15. Custo de contexto

- Contagem de tools observada: Playwright **25**, Chrome DevTools full **30**
  (opt-ins até ~59). Tokens **UNVERIFIED** (não medidos nesta auditoria).
- Regime preservado: dezenas de tools entram apenas via profile `testing`
  on-demand; Playwright CLI + skill seguem como alternativa de menor custo para
  navegação simples; os dois MCPs são complementares (comportamento/E2E vs
  diagnóstico/observabilidade).

## 16. Testes executados nesta auditoria

| Suíte | Resultado |
|---|---|
| `tests/distribution/mcp-profiles.tests.ps1` | **8/8 PASS** |
| `tests/distribution/capability-registry-v2.tests.ps1` | **48/48 PASS** |
| `tests/distribution/capability-planning.tests.ps1` | **12/12 PASS** |
| suite de skills-catalog (dentro de distribution) | **18/18 PASS** |
| `scripts/test-package-consistency.ps1` | **16/16 PASS** |
| `scripts/v3/capability-healthcheck.ps1 -Json` | 32/32 resultados; saúde verídica por máquina |
| `scripts/v3/skills-healthcheck.ps1` | **PASS** |
| `scripts/ci/plugin-healthcheck.ps1` (V2 ativo) | **FAIL** — apenas o backup `.bak-1791360135` (§13) |
| `scripts/ci/smoke-opencode-v2-lifecycle.ps1 -BinaryPath <2.0.23 exato>` | **PASS** (isolado) |
| Tasks reais de browser (probe stdio JSON-RPC) | Playwright e Chrome DevTools: navegação/snapshot/console/rede/(perf) OK; saída 0 |

Baseline (recapitulado em §4) **não** foi reescrito: consistency 16/16,
distribution 19/1 FAIL/1 SKIP, v3-tests 80/4 FAIL/6 SKIP.

## 17. Unavailable / Unverified vs Runtime Verified

**Runtime Verified (2026-10-10):** 3 MCPs core invocados; gh CLI (leituras
reais); binário V2 exato 2.0.23 + lifecycle smoke; Playwright MCP 0.0.83 e
Chrome DevTools 1.10.1 full em probe real com tarefas; healthchecks de
registry/skills/plugin; suites 8/8, 48/48, 12/12, 18/18, 16/16.

**NOT_VERIFIED / UNAVAILABLE (não afirmar):**

- V1 (sem binário/perfil nesta máquina).
- Isolamento de **nova sessão sem profile** e o par "oferecido-ao-agente" vs
  "invocado-pelo-agente" (ver §18).
- Custo em tokens (tools contadas, tokens não).
- Ativação opt-in por operador de `testing`/`core-dev` no user-config.

## 18. Bloqueios e limitações

1. **Porta 49374** do serviço gerenciado V2 atual ocupada por serviço do
   usuário: uma segunda execução de `opencode mcp list` (sessão sem profile)
   colidiu/reutilizou estado de serviço; nova tentativa limpa não conseguiu
   subir o managed server. `mcp list` do CLI pinado não aceita `--standalone`.
   Consequência: isolamento real de segunda sessão sem profile **não
   verificado**; a atribuição de papel de agente no registry de profiles é
   **declarativa**. As evidências parciais disponíveis (isolamento por fixture
   em `capability-routing-phase2d.tests.ps1` e ausência de browser MCP no
   config ativo) **não** equivalem à prova de segunda sessão real.
2. Nenhum **named profile** persistido/ativo no config de usuário/global (o
  perfil `testing` de browser foi efêmero); pacotes baixados permanecem no
  cache local do npx, sem instalação global. Nota: isto refere-se a **profiles** — os 3 MCPs core continuam
   presentes diretamente no bloco `mcp` global (§5, §11; Finding F1).
3. Baseline com 4 FAILs (v3-tests) e 1 FAIL (distribution), observados **antes**
   das edições desta auditoria; causa-raiz **não estabelecida** (sintomas:
   identidade de worktree/runtime e hash divergente do config ativo); a suíte
   exata do FAIL de distribution não foi isolada.
4. Plugin V2 com FAIL de saúde por backup inativo (issue #25, sem repro).
5. Drift de runtime: global 2.0.26 vs pin 2.0.23.

## 19. Próximas ações

1. Manter o JSON de evidência versionado explicitamente (`git add -f`), pois o
   padrão `evidence/*` o ignora; futuras alterações podem continuar usando
   force-add ou propor exceção específica em mudança separada.
2. Operador: prova de isolamento de nova sessão em **serviço isolado com porta
   própria**, após mecanismo seguro, **sem alterar config global** — só então
   afirmar new-session no-profile isolation e offered/invoked-by-role.
3. Operador: ativação opt-in de `testing` (browser) e `core-dev` (GitHub, com
   PAT) por decisão explícita, com medição de tokens antes de qualquer default.
4. Issue #25: investigar regeneração do backup `ai-memory-opencode2.ts.bak-*`
   com repro dedicado (não apagar às cegas).
5. Decidir sobre o drift 2.0.26 vs pin 2.0.23 (bump de pin + revalidação no
   runtime exato, ou alinhamento do binário global).
6. Investigar os 4 FAILs de baseline (`w1c`/`w14`; prefixo DE22307F vs
   `C1BB84F2`) e isolar a suíte com FAIL em distribution, em trabalho próprio.
7. Gate permanente preservado: nenhuma capability especializada é ativada sem
   projeto + credencial + pilot; fallbacks permanecem (§31 do closure 2C).
8. Operador (Finding F1, §11): decidir se os 3 MCPs core (`context7`, `jev`,
   `servers.ai-memory`), hoje machine-global always-on no config de
   usuário/global, podem **permanecer globais** ou devem migrar para um
   **mecanismo session-scoped seguro** (ex.: ativação opt-in via named
   profile). **Nenhuma mudança de config é proposta nesta auditoria** — apenas
   a decisão fica registrada para o operador.

## 20. Veredito final

**PARTIAL.** O provisionamento de capabilities está **inventariado e verificado
onde era verificável**: registry 32/32, profiles 19, skills 105/110 com CORE
9/9, MCPs core saudáveis e realmente invocados, browser stack aprovada e
comprovada em runtime real efêmero (V2 2.0.23 isolado, 25 + 30 tools). Os MCPs
core são machine-global always-on, distintos do estado de named profiles (19
perfis, 0 IDs ativos); o drift de escopo global-vs-session-scoped fica
registrado como Finding F1 (§11) para decisão do operador (§19), sem proposta
de mudança de config. Faltam
provas reais em dimensões hoje **indisponíveis ou não verificadas**: V1 sem
binário/perfil, isolamento de nova sessão sem profile (porta 49374 ocupada),
medição de tokens, ativações opt-in do operador e o FAIL do plugin V2 por
backup inativo. GitHub MCP e os especializados seguem **deferidos** — não
configurados, sem necessidade/credencial, com fallbacks preservados. Nenhuma
mudança de runtime, config, registry, permissões, plugins, skills ou
credenciais foi feita por esta auditoria; PRs #54 e #23 permanecem
independentes e intactos.
