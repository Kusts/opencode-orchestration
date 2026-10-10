# OpenCode Capabilities & Local Environment Audit

- **Data:** 2026-10-06
- **Branch:** `docs/audit-opencode-capabilities-2026-10-06`
- **Escopo:** investigação e planejamento. Nenhuma instalação, remoção ou alteração de config foi feita nesta rodada.
- **Repos/paths auditados:**
  - `D:/projetos/opencode-orchestration` (fonte versionada, branch `master`, remote `origin https://github.com/Kusts/opencode-orchestration.git`)
  - `C:\Users\walis\.config\opencode\` (estado ativo)
  - `C:\Users\walis\.agents\skills\` (segundo `skills.paths`)
  - `C:\Users\walis\.opencode-orchestration\manifest.json` (manifesto do instalador)
  - `C:\Users\walis\bin\` (wrappers `opencode`/`opencode2`)
  - `C:\Users\walis\agent-config\` (launcher canônico legado)
- **Higiene de secrets:** valores sensíveis aparecem apenas como `configurado` / `ausente` / `inválido` / `não verificado`. Nenhum valor real foi gravado neste relatório.

---

## 1. Executive Summary

O ecossistema está **funcional e coerente no núcleo**, mas com **deriva relevante nas bordas**:

- **Núcleo saudável:** OpenCode V2 ativo (`@opencode/cli@2.0.24`), 15 dos 19 subagents registrados + `build`/`title`, 5 skills-core instaladas, plugin `orchestration-enforcement.js` presente, 3 MCPs enxutos (ai-memory remoto, context7, jev), manifesto do instalador íntegro (`package_version 1.1.0`, `runtime.id opencode-v2`).
- **4 achados altos:**
  1. **4 agents de planning órfãos:** `engineering-advisor`, `product-designer`, `requirements-analyst`, `skeptic` existem como `.md` (19 arquivos) e estão na allowlist do `build`, mas **não têm entrada em `opencode.json:agents{}`** (só 17 chaves). Na prática, a Planning Layer documentada no AGENTS.md **não é despachável** pelo runtime atual.
  2. **Catálogo shadow de skills:** `~/.agents/skills` contém **103 skills** e é o **primeiro** `skills.paths`; o instalador só gerencia 5. Superfície de descoberta ~15x maior que o pretendido, com risco de roteamento ambíguo e custo de contexto.
  3. **`plugin: []` vazio:** o bundle `orchestration-enforcement.js` está no diretório mas **não referenciado** em `opencode.json:plugin`. Se o runtime V2 exigir registro explícito, o enforcement está **inoperante**; se houver autoload por diretório, arquivos `.disabled`/`.bak` no mesmo dir viram risco de reativação acidental.
  4. **Permissões amplas + segredo em plaintext:** `permission.bash.*: allow`, `external_directory.*: allow`, `edit: allow` no config global; `service.json` contém `password` em plaintext no config dir.
- **Drift de versão pequeno:** instalado `@opencode/cli@2.0.24` vs pin `2.0.23`; `@opencode-ai/plugin 1.18.31` vs pin `1.18.34`. Bun `1.3.14` = pin. Nada quebrado por isso, mas o registry declara-se "fonte única" e já está 1 patch atrás do instalado.
- **Repo sujo:** 2 arquivos modificados e não commitados (`scripts/reconcile-opencode-config.ps1`, `tests/distribution/runtime-install.tests.ps1`).
- **Recomendação geral:** fase 2 deve (a) registrar ou remover os 4 planning agents, (b) decidir o destino das 103 skills shadow (curadoria + `skills.paths`), (c) confirmar o mecanismo de carregamento de plugins e limpar órfãos, (d) endurecer permissões/`service.json`, (e) alinhar pins de versão. Detalhes e matriz completa nas seções abaixo.

---

## 2. Current Architecture

```text
D:/projetos/opencode-orchestration        (fonte versionada, package v1.1.0)
  source/          global, adapters (opencode.md, opencode-v2.md),
                   agents (19 .md, placeholders {{MODEL_*}}),
                   policies (3), registry (17 JSON)
  skills-core/     5 skills (hybrid, dispatching-parallel,
                   subagent-driven, verification-before-completion,
                   using-superpowers)
  plugins/         orchestration-enforcement (ts fonte + dist bundle + .sha256)
  templates/       opencode.v1.json.tmpl, opencode.v2.json.tmpl
  scripts/         render, reconcile, build-plugin + scripts/v3/*
                   + scripts/runtime/* + scripts/ci/*
  docs/, generated/, evidence/, cache/, tests/distribution (15)
        |
        |  install.ps1 (-Runtime Auto|V1|V2|Both, merge estrutural,
        |               manifest + backup + hash)
        v
C:\Users\walis\.config\opencode\          (estado ativo, dialeto V2)
  opencode.json, AGENTS.md (markered), cli.json (schema v2),
  tui.json (schema v1 remanescente), service.json (porta 4096),
  agents/ (19 .md, modelos resolvidos), skills/ (7),
  plugins/ (1 bundle ativo + órfãos), commands/ (14 autoresearch*),
  backups/, node_modules/ (@opencode-ai/plugin 1.18.31)
        +
C:\Users\walis\.agents\skills\            (103 skills, primeiro skills.paths)
        +
C:\Users\walis\bin\opencode{,2}.cmd/ps1   (shims -> invoke-agent.ps1 ->
                                           APPDATA npm @opencode/cli)
```

- **Runtime efetivo:** V2 único. V1 preservado apenas como backups (`*.bak-v1*`, `opencode-v1-backup-2026-09-14/`). `Both`/perfis isolados XDG documentados mas **não observados** nesta máquina (sem `~/.opencode-orchestration/profiles/{v1,v2}` listado).
- **Fluxo pretendido:** `Task -> Planner(build) -> Capability Registry -> Agents + Skills + MCP Profile + Plugins + Permissions -> Execution -> Validation -> Evidence`. Registry existe como JSONs (`source/registry/*`, 17 arquivos) com flags majoritariamente OFF (router shadow/active, skill/mcp routing, adaptive ranking), ou seja: **roteamento ainda é determinístico via AGENTS.md + allowlist**, não via registry ativo.

---

## 3. Local Environment Inventory

| Item | Valor observado | Evidência |
|---|---|---|
| OS / shell | Windows, pwsh 7.6.6 | `$PSVersionTable` |
| OpenCode que responde no PATH | `opencode v2.0.24` | `opencode --version` |
| Binários no PATH | `C:\Users\walis\bin\opencode(.cmd)`, `C:\Users\walis\AppData\Roaming\npm\opencode(.cmd)` | `where.exe opencode` |
| Instalação npm global | `@opencode/cli@2.0.24` | `npm ls -g` |
| Shims | `bin\opencode{,2}.cmd/.ps1` (+ `opencode2.ps1.bak-20261001`) -> launcher `agent-config\scripts\invoke-agent.ps1` -> `APPDATA\npm\node_modules\@opencode\cli\bin\opencode.exe` | `bin\opencode.ps1:1-12` |
| node / npm | v26.7.0 / 11.19.0 | `node/npm --version` |
| bun | 1.3.14 (= pin do registry) | `bun --version`, `runtime-versions.json:29-34` |
| pnpm | 10.34.1 | `pnpm --version` |
| git / gh | 2.54.0.windows.1 / 2.93.0 | `--version` |
| python / uv | 3.14.7 / 0.12.19 | `--version` |
| docker / compose | 29.8.1 / v5.5.1, engine rodando, **0 containers** | `docker ps` (vazio), processos `com.docker.backend`, `Docker Desktop` |
| wrangler / supabase / terraform | **ausentes** | `where`-style: termo não reconhecido |
| playwright | `playwright@1.60.0` + `@playwright/cli@0.1.13` (npm global) | `npm ls -g` |
| browsers | Chrome (processos ativos) e Edge (binários presentes) | `Get-Process chrome`, `Test-Path chrome.exe/msedge.exe = True` |
| ai-memory wrapper | `C:\Users\walis\.local\bin\ai-memory` (bash wrapper p/ container) + `C:\Users\walis\bin\ai-memory.cmd`; CLI direta não executável via pipeline pwsh (documento bash) | `Get-Item`, `Get-Content -TotalCount 5` |
| ai-memory remoto | `https://aimem.synkroo.com.br/mcp`, auth: **configurado** (via env), `memory_status` OK: 327 `pages_latest` | `opencode.json:mcp.ai-memory`, `memory_status` (subagente) |
| jev-ultrafast repo | `D:\projetos\jev-ultrafast` (`.venv`, `jev_ultrafast/`, `AGENTS.md`, `.env`/`.env.example` sem segredos lidos) | listagem top-level |
| OpenCode processes | 6 processos `opencode` (PIDs 5704, 6056, 6304, 7260, 10124, 15776); PID 5704 = `opencode.exe` servindo `127.0.0.1:4096` | `Get-Process`, `netstat LISTENING` |
| Scheduled tasks | `AI-Memory-Backup-Local` (Pronto, 07/10/2026 04:30); 394 tasks totais | `schtasks /query` |
| Env (nomes/status) | `AI_MEMORY_AUTH_TOKEN`: configurado; `OPENCODE_ZEN_API_KEY`: configurado; `OPENCODE_GO_API_KEY`: configurado; `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`: configurado; `OPENCODE`, `OPENCODE_SESSION_ID`, `OPENCODE_TERMINAL`, `ORCA_*`: configurado | `Get-ChildItem Env:` (nomes apenas) |

---

## 4. OpenCode V1

- **Status:** inativo. Preservado como referência/backup.
- **Evidências:**
  - `C:\Users\walis\.config\opencode\opencode.json.bak-v1-20260914` — dialeto V1 (`agent` singular, `permission` singular, `subagent_depth` top-level, `instructions: [orchestration.md]`, `small_model`).
  - `C:\Users\walis\opencode-v1-backup-2026-09-14\config-opencode\opencode.json` — V1 idêntico ao bak.
  - `C:\Users\walis\.config\opencode\orchestration.md` — legado V1 inativo (AGENTS.md declara substituído, sem efeito).
  - `C:\Users\walis\opencode\` — diretório **vazio**.
  - Plugins `*.v1-disabled`, subdir `_v1-herdr/` — vestígios V1 no dir de plugins ativo.
- **Compartilhamento de dir:** V1 e V2 honram o mesmo config root via `XDG_CONFIG_HOME` por design (declarado em `AGENTS.md:235`). Risco de regressão V1 somente se launcher/`XDG_CONFIG_HOME` apontar para backup — mitigado por manifest + baks, mas execução **fora do launcher** perde o isolamento (`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` é aplicado só no processo-filho em `agent-config/scripts/invoke-agent.ps1:121`).
- **Classificação:** V1 = histórico/rollback. Nenhuma ação além de manter 1 backup íntegro e arquivar o resto (fase 2).

---

## 5. OpenCode V2

- **Status:** ativo e íntegro no núcleo.
- **Evidências:**
  - `opencode --version` = `v2.0.24`; `npm ls -g` = `@opencode/cli@2.0.24`.
  - `opencode.json:$schema https://opencode.ai/config.json` + blocos `agents` + `permissions[]` + `experimental.subagent_depth: 1` + `model: zai-coding-plan/glm-5.3-flash` + `default_agent: build` — dialeto V2 confirmado (`opencode.json:1-82`).
  - `agents{}` = **17 chaves**: `build`, `title` + 15 subagents (ver §6 — faltam os 4 de planning).
  - `build.mode: primary` + allowlist `subagent * deny` primeiro + 19 `allow` nominais.
  - `cli.json:$schema https://opencode.ai/v2/cli.json` — schema V2 OK.
  - `tui.json:$schema https://opencode.ai/tui.json` + `plugin: [file:///.../orca-opencode-status-tui/tui.js]` — **schema V1 remanescente** e plugin de status Orca fora da governança.
  - `service.json` — `port: 4096` (ouvindo em `127.0.0.1:4096`, PID 5704 = `opencode.exe`); `password`: **configurado** (plaintext — ver §17).
  - `package.json: dependencies.@opencode-ai/plugin = 1.18.31` + `node_modules/@opencode-ai/sdk` com `OPENCODE_CONFIG_CONTENT` (vetor de injeção de config por conteúdo — ver §15).
  - `manifest.json: package_version 1.1.0, runtime.id opencode-v2, installed_at 2026-10-06T08:24:12-03:00, source_revision de4eaa0` — instalador V2 recente e rastreável.
  - `skills.paths: ["~/.agents/skills", "~/.config/opencode/skills"]`, `urls: []`.
  - `plugin: []`, `plugins: ["-herdr-agent-state"]` (só uma negação).
  - `autoupdate: false`.
- **Drift vs registry:** pin declara `@opencode/cli@2.0.23` e `@opencode/plugin@2.0.23` / `@opencode-ai/plugin@1.18.34` (`runtime-versions.json:5-28`); instalado `2.0.24` e `1.18.31`. Divergência de 1 patch em cada direção (ver §16).

---

## 6. Agents

### 6.1 Inventário

| # | Agent | `.md` local | `agents{}` JSON | Modelo efetivo | Permissões `.md` | Classificação |
|---|---|---|---|---|---|---|
| 1 | explorer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 2 | researcher | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 3 | coder | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 4 | tester | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 5 | reviewer | sim | sim | **strong** | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 6 | debugger | sim | sim | **strong** | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 7 | security-reviewer | sim | sim | **strong** | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 8 | architect | sim | sim | **strong** | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 9 | frontend-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 10 | backend-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 11 | database-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 12 | ai-agent-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 13 | automation-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 14 | infra-engineer | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 15 | docs-manager | sim | sim | cheap | `subagent * deny` | ORCHESTRATION_MANAGED / KEEP |
| 16 | requirements-analyst | sim | **NÃO** | cheap (só `.md`) | `subagent * deny` | **UPDATE (registrar ou remover)** |
| 17 | engineering-advisor | sim | **NÃO** | cheap (só `.md`) | `subagent * deny` | **UPDATE (registrar ou remover)** |
| 18 | product-designer | sim | **NÃO** | cheap (só `.md`) | `subagent * deny` | **UPDATE (registrar ou remover)** |
| 19 | skeptic | sim | **NÃO** | cheap (só `.md`) | `subagent * deny` | **UPDATE (registrar ou remover)** |
| — | build (primary) | n/a (só JSON) | sim | herda sessão | allowlist 19 allows + `* deny` | ORCHESTRATION_MANAGED / KEEP |
| — | title | n/a (só JSON) | sim | `zai-coding-plan/glm-5.3-flash` | — | ORCHESTRATION_MANAGED / KEEP |
| — | opencode-loop-local | só snapshot `agents-v2-20260915/` | não | — | — | REMOVE_CANDIDATE (arquivar) |

- **Modelos:** cheap = `opencode-go/muse-spark-1.3-contributor` (15), strong = `openai/gpt-6.1-sol` (4). `build` sem modelo fixo (herança de sessão) por design.
- **Comparação canônico × local:** `source/agents/` (19 `.md`, placeholders `{{MODEL_*}}`) × `agents/` (19 `.md`, resolvidos) — nomes 1:1, sem fork aparente. Porém o **template só renderiza 15 subagents** no JSON (achado do explorer de orchestration) — consistente com os 4 ausentes acima.
- **Evidências:** `agents/*.md` (19 arquivos), `opencode.json:83-...` (`agents` 17 chaves via `python -c`), `source/agents/*.md: model {{MODEL_*}}`, `manifest.json: managed_files` (hashes de `AGENTS.md` + `agents\*.md`).

### 6.2 Achado A1 (alto): planning layer não despachável

- **Finding:** os 4 papéis advisory (`requirements-analyst`, `engineering-advisor`, `product-designer`, `skeptic`) têm `.md` + allowlist no `build`, mas **sem bloco em `agents{}`**.
- **Evidence:** `opencode.json:agents` 17 chaves (listadas em §5); `agents/requirements-analyst.md` etc. presentes; `agents:build:permissions[]` contém os 4 allows.
- **Risk:** alto — documento (AGENTS.md Planning Layer) promete comportamento que o runtime não consegue cumprir; Planner pode tentar delegar e falhar.
- **Recommendation:** fase 2 — ou registrar os 4 no template + JSON (preferido, pois o adapter os especifica), ou remover `.md` + allows + trechos do AGENTS.md. Não manter estado intermediário.

---

## 7. Skills

### 7.1 Inventário

| Origem | Qtd | Conteúdo |
|---|---|---|
| `skills-core/` (fonte versionada) | 5 | `dispatching-parallel-agents`, `hybrid-development`, `subagent-driven-development`, `using-superpowers`, `verification-before-completion` |
| `~/.config/opencode/skills/` | 7 | as 5 core + `autoresearch` (v2.2.2) + `jev-ultrafast` (path absoluto `D:\projetos\jev-ultrafast`) |
| `~/.agents/skills/` (primeiro `skills.paths`) | **103** | catálogo shadow: inclui as 5 core (overlap) + ~98 outras (ai-memory-*, orca-*, cloudflare*, second-brain/sb-*, vendas/trafego/copy-br, ui-libraries, playwright-cli, etc.) |
| `commands/` (14) | 14 | `autoresearch*.md` — comandos do loop `autoresearch`, sem par em `skills-core/` |

- **Overlap:** 5 skills existem nos dois paths (`dispatching-parallel-agents`, `hybrid-development`, `subagent-driven-development`, `using-superpowers`, `verification-before-completion`). Precedência de resolução entre paths **não verificada** — risco de versão shadow vencer a gerenciada.
- **Duplicação funcional (parcial):** `hybrid-development` ≈ `subagent-driven-development` ≈ `dispatching-parallel-agents` (orquestração; gatilhos distintos, escolha ambígua possível). `jev-ultrafast` (skill) × MCP `jev` (duas superfícies p/ mesmo domínio). `using-superpowers` × plugin Superpowers (adapter veda carregar em paralelo).
- **Classificação:**
  - CORE: as 5 `skills-core` (manter gerenciadas).
  - RECOMMENDED (avaliar adoção): `ai-memory-*` (5 skills de routing/handoff em `~/.agents/skills`), `playwright-cli`, `systematic-debugging`/`tight-feedback-debugging`, `test-driven-development`.
  - PROJECT_SPECIFIC: `cloudflare*`, `ui-libraries-curator`, `trafego/vendas/copy-br`, `maestri*`, `orca-*`.
  - REDUNDANT/INVESTIGATE: `autoresearch` + 14 commands (fork local fora da governança; decidir: adotar, arquivar ou manter local com owner).
  - REMOVE_CANDIDATE de raízes ativas: duplicatas exatas entre os dois paths (resolver precedência primeiro).
- **Evidências:** contagens via `Get-ChildItem` (103 vs 7 vs 5); `skills/jev-ultrafast/SKILL.md:description(D:\projetos\jev-ultrafast)`; `skills/autoresearch/SKILL.md:version 2.2.2`; `source/adapters/opencode.md` (vedação Superpowers).

---

## 8. MCP Servers

### 8.1 Ativos (`opencode.json:mcp`, global, V2)

| Nome | Transporte | Comando/endpoint (sem secrets) | Auth | Status auth | Tools aproximadas | Classificação |
|---|---|---|---|---|---|---|
| ai-memory | remote | `https://aimem.synkroo.com.br/mcp` + `Authorization: Bearer {env:...}` | token via env | **configurado** | memória/projetos/sessions (327 `pages_latest` verificado) | CORE |
| context7 | local stdio | `cmd /c npx -y @upstash/context7-mcp` | sem auth | n/a (configurado / não verificado em runtime) | docs de libs | CORE |
| jev | local stdio | `cmd /c npx -y github:codaaiteam/jev-mcp` + `JEV_API_KEY:{env:...}`, `JEV_BASE_URL:https://opencode.ai/zen/v1/systemone`, `JEV_MODEL:jev-1.13-free` | API key via env | **configurado** (não verificado em runtime) | advisory/gate/decide (advisory-only por policy) | PROFILE_BASED (research) |

- `list_mcp_resources` retornou `resources: []`, `templates: []` (sem recursos raiz expostos — esperado para estes servidores).
- Histórico: `opencode.json.bak-remove-obscura-20261005:mcp.obscura` (`obscura.exe mcp`) foi **removido** do atual — único delta histórico; superfície reduzida corretamente.

### 8.2 Catálogo avaliado (todos ausentes no `mcp` atual)

GitHub, Playwright, Chrome DevTools, Supabase, Neon, Postman, Figma, n8n, Stripe, Docker Gateway, Terraform, Cloudflare, Grafana, PostHog, GA, Ads, Ahrefs, DataForSEO, HubSpot, Composio, Pipedream, Jina, Browserbase — **nenhum configurado**. Ver §21 (profiles propostos) e §22/§28 (prioridades) para o que adicionar e quando.

### 8.3 Notas

- `mcp.*` é **unmanaged por design** (merge estrutural preserva; `uninstall.ps1` nunca toca). Correto — credenciais e endpoints permanecem na máquina.
- Risco atual **baixo**: 3 MCPs sempre carregados, todos de leitura/advisory. Nenhum MCP de escrita em produção ativo.

---

## 9. Plugins

| Plugin (em `plugins/`) | Estado | Observação |
|---|---|---|
| `orchestration-enforcement.js` (~53 KB bundle) | presente, **referência ausente** (`plugin: []`) | fonte `plugins/orchestration-enforcement{,.ts,/v1.ts,/v2.ts,/shared/}` + `dist/*.js` + `.sha256`; hooks `event`, `chat.system.transform` (V1) / `session context` + `tool.hook` (V2); telemetria em `~/.opencode-orchestration/evidence/...` |
| `orca-opencode-status.js` + `orca-opencode-status-tui/` | presente, referenciado só em `tui.json` | fora da governança do orchestration; injeta system/status — **colisão conceitual** com enforcement |
| `ai-memory-opencode2.ts` | presente, sem referência | duplicata funcional parcial com MCP remoto ai-memory |
| `ai-memory-opencode2.v2-disabled`, `ai-memory.ts.v1-disabled`, `ai-memory.ts.bak-20261001-101126`, `herdr-agent-state-v2.v2-disabled`, `herdr-agent-state.js.disabled` | desabilitados mas **no dir ativo** | risco de reativação por glob; arquivar fora da raiz |
| `_v1-herdr/`, `rollback-v2/`, `rollback-20260914-audit/`, `plugins-backup-20260928-124326/`, `reconciliation-backups/`, `backups/` (10+ snapshots) | backups dentro/ao lado da raiz ativa | proliferação; manter 1 backup íntegro, arquivar resto |

- **Achado A2 (alto):** `plugin: []` vazio. Duas hipóteses: (a) V2 exige registro e o enforcement está **inoperante**; (b) há autoload por diretório e está ativo. Nenhuma das duas foi provada sem doc de runtime. **INVESTIGATE obrigatório na fase 2** (ver §30 Q1).
- **Evidências:** listagem `plugins/` (11 entradas); `opencode.json:71-76` (`plugin: []`, `plugins: ["-herdr-agent-state"]`); `plugins/orchestration-enforcement.js: mandateFor/markerFor`.

---

## 10. External Tooling

| Ferramenta | Versão | PATH/obs | Gap |
|---|---|---|---|
| Git | 2.54.0.windows.1 | ok | — |
| GitHub CLI | 2.93.0 | ok | MCP GitHub ausente (profile) |
| Node | v26.7.0 | `C:\Program Files\nodejs`, `~/.bun/bin`, pnpm, `AppData\Roaming\npm` no PATH | múltiplos Node (Program Files + pnpm + bun) — verificar precedência |
| npm | 11.19.0 | ok | — |
| Bun | 1.3.14 (= pin) | ok | — |
| pnpm | 10.34.1 | `AppData\Local\pnpm` | — |
| Python | 3.14.7 | ok | — |
| uv | 0.12.19 | ok | — |
| Docker + Compose | 29.8.1 / v5.5.1 | engine rodando, 0 containers | sem compose ativo p/ MCP gateway local |
| PowerShell | 7.6.6 (`pwsh`) | ok | — |
| Playwright | 1.60.0 + `@playwright/cli@0.1.13` global | browsers Chrome/Edge presentes | sem MCP Playwright/DevTools (profile testing/frontend) |
| Wrangler | ausente | — | profile infra (quando necessário) |
| Supabase/Neon CLI | ausentes | — | profiles database (quando necessário) |
| Terraform | ausente | — | profile infra (quando necessário) |
| n8n | não detectado | — | profile automation (quando necessário) |

---

## 11. Local Services

| Serviço | Estado | Obs |
|---|---|---|
| opencode serve | `127.0.0.1:4096` LISTENING, PID 5704 = `opencode.exe` | + 5 processos `opencode` auxiliares; `service.json:password` **configurado** (plaintext) |
| Docker Desktop + backend | rodando, 0 containers | sem conflito de portas detectado |
| AI-Memory-Backup-Local (sched task) | Pronto | única task relacionada encontrada (de 394) |
| Portas LISTEN | 22, 135, 445, 5040, 6768, 7680, 49xxx (sistema), 127.0.0.1:4096/20241/62928/63621 | nada colidindo com 4096; sem MCP local em porta fixa |
| ai-memory servidor | remoto (`aimem.synkroo.com.br`); sem listener local 49374 observado | policy: nunca fallback p/ listener local — correto |

---

## 12. AI Memory

- **Integração:** MCP remoto `ai-memory` (`type: remote`, `enabled: true`), auth via env: **configurado**. `memory_status`: 327 `pages_latest` (scope pessoal via sessão) — operacional.
- **Projeto:** `.ai-memory.toml` do orchestration = `workspace "ferramentas" / project "opencode-orchestration"`; ausente em `C:\Users\walis` (correto — config por projeto).
- **Posição arquitetural:** opcional, fora do pacote, cliente estático (workspace+project explícitos). Skills `ai-memory-*` existem no catálogo shadow (`~/.agents/skills`) mas **não instaladas** no path gerenciado — candidatas a RECOMMENDED (ver §22).
- **Evidências:** `opencode.json:34-42`; `.ai-memory.toml` (orchestration); `source/registry/ai-memory-remote-policy.json`; `memory_status` via MCP.

---

## 13. Jev

- **Duas superfícies:** (1) MCP `jev` local (`github:codaaiteam/jev-mcp`, `JEV_MODEL jev-1.13-free`, auth via env: **configurado**); (2) skill `jev-ultrafast` apontando para `D:\projetos\jev-ultrafast` (repo com `.venv`, `jev_ultrafast/`, `AGENTS.md`) + 14 skills? não — 1 skill + MCP.
- **Posição arquitetural:** advisory-only, kernel-side (`OrchestrationJevAdvisory.ps1`, budget 30s, `JEV_API_KEY` só nome). Skill descreve browser-agent (Browser Use × TypeSafe), MCP descreve gate/decide — **sobreposição parcial, propósitos distintos**; documentar quando usar cada um.
- **Evidências:** `opencode.json:54-69`; `skills/jev-ultrafast/SKILL.md`; `source/registry/jev-advisory-policy.json`; listagem `D:\projetos\jev-ultrafast`.

---

## 14. Duplications

| # | Duplicação | Onde | Ação |
|---|---|---|---|
| D1 | 5 skills nos dois `skills.paths` | `~/.agents/skills` × `~/.config/opencode/skills` | RECONFIGURE (definir precedência ou remover de um lado) |
| D2 | 3 skills de orquestração sobrepostas | `hybrid` × `subagent-driven` × `dispatching-parallel` | MERGE docs (gatilhos) — sem código |
| D3 | Jev em 2 superfícies | skill `jev-ultrafast` × MCP `jev` | KEEP ambos + documentar uso (research vs gate) |
| D4 | ai-memory em 2 superfícies | MCP remoto × `ai-memory-opencode2.ts` (plugin órfão) | REMOVE plugin órfão (MCP vence) |
| D5 | Backups no dir ativo | 10+ snapshots + `*.bak*` + `agents-v2-20260915` + `opencode-v1-backup-*` | arquivar fora da raiz; manter 1 |
| D6 | Plugins disabled no dir ativo | 4 `*.disabled`/`*.bak` + 2 subdirs | mover p/ arquivo |
| D7 | Node múltiplo | Program Files × pnpm × bun × AppData npm | INVESTIGATE precedência |
| D8 | `opencode` × `opencode2` shims | `bin\` (+ `opencode2.ps1.bak-20261001`) | KEEP se intencionais; documentar |
| D9 | V1 preservado 2x | `*.bak-v1*` + `opencode-v1-backup-2026-09-14/` | manter 1, arquivar 1 |

---

## 15. Conflicts

| # | Conflito | Evidência | Risco | Ação |
|---|---|---|---|---|
| C1 | Planning agents na allowlist sem registro | `build.permissions[]` (19 allows) × `agents{}` (15 subagents) | alto | RECONFIGURE (registrar ou remover) |
| C2 | Enforcement sem referência | `plugin: []` × bundle presente | alto | INVESTIGATE (Q1 §30) |
| C3 | `tui.json` schema V1 + plugin orca | `tui.json:$schema .../tui.json` | médio | UPDATE/REMOVE |
| C4 | Skills shadow podem vencer gerenciadas | ordem `skills.paths` + overlap D1 | médio | RECONFIGURE |
| C5 | orca status × enforcement (system inject) | `tui.json:plugin` + `orchestration-enforcement.js` | médio | INVESTIGATE |
| C6 | `OPENCODE_CONFIG_CONTENT` (SDK) bypassa arquivo | `node_modules/@opencode-ai/sdk/dist/v2/server.js` | médio | documentar; nunca usar p/ prod local |
| C7 | Execução fora do launcher perde isolamento skills | `invoke-agent.ps1:121` (só filho) | médio | documentar; usar shims sempre |
| C8 | Repo sujo (2 arquivos) | `git status` | baixo | REVIEW + commit separado |
| C9 | Pins desatualizados (2.0.23 vs 2.0.24; 1.18.34 vs 1.18.31) | `runtime-versions.json` × instalado | baixo | UPDATE pins após validação |

---

## 16. Outdated Components

| Componente | Instalado | Pin/declarado | Veredito |
|---|---|---|---|
| `@opencode/cli` | 2.0.24 | pin 2.0.23 (`runtime-versions.json:11-15`) | máquina 1 patch **à frente** — bump do pin após smoke |
| `@opencode-ai/plugin` | 1.18.31 (`package.json`) | pin 1.18.34 (`runtime-versions.json:17-22`) | máquina **atrás** — UPDATE após smoke |
| `tui.json` schema | `opencode.ai/tui.json` | `cli.json` já em `/v2/cli.json` | desatualizado — migrar ou remover |
| `orchestration.md` | presente | AGENTS.md declara sem efeito | relíquia — arquivar |
| `agents-v2-20260915/opencode-loop-local.md` | só snapshot | sem par ativo | órfão — arquivar |
| `obscura` MCP | removido do atual | só em bak | corretamente removido — nada a fazer |

---

## 17. Security Findings

| # | Finding | Evidência (sanitizada) | Severidade | Recomendação (fase 2) |
|---|---|---|---|---|
| S1 | `service.json:password` em plaintext no config dir | `service.json` (keys `port`, `password`: **configurado**) | **alta** | mover p/ env/secret store; chmod restrito; nunca backup em plaintext |
| S2 | `permission.bash.*: allow` global | `opencode.json:10-22` | **alta** | restringir p/ allowlist; manter `ask` em destrutivos (já há) + adicionar `del/rm -Recurse`, `docker rm/prune`, `git push --force` |
| S3 | `external_directory.*: allow` + `edit: allow` globais | `opencode.json:3-9` | média | escopar por projeto quando possível |
| S4 | 6 processos `opencode` + serve com senha fraca? (não verificado) | `Get-Process`, `netstat` | média | auditar origem dos PIDs; rotacionar `password` ao mover p/ env |
| S5 | Segredos via `{env:VAR}` — correto, mas `service.json` foge ao padrão | `opencode.json:mcp.*` vs `service.json` | média | unificar padrão env-only |
| S6 | `.env` do jev-ultrafast não inspecionado (proposital) | `D:\projetos\jev-ultrafast/.env` existe | baixa | garantir `.env` fora de backup/commit (`gitignore` + `gitleaks`) |
| S7 | Backups contêm configs históricas (possível secret fossilizado) | `backups/` 10+ snapshots | baixa | varrer com `gitleaks` antes de arquivar; expurgar secrets |

Nenhum valor de secret foi lido ou gravado nesta auditoria.

---

## 18. Context/Token Efficiency Findings

| # | Finding | Impacto |
|---|---|---|
| T1 | 103 skills descobríveis (primeiro path) | descoberta/routing paga custo de contexto; risk de skill errada |
| T2 | 3 MCPs sempre carregados (ai-memory remoto = maior superfície de contexto) | avaliar `enabled`/lazy por profile; ai-memory já é o mais caro |
| T3 | 19 allows no `build` + 15 subagents registrados | allowlist ampla é correta p/ Planner, mas cada worker carrega prompt próprio — manter, não ampliar |
| T4 | 14 `commands/autoresearch*` sempre visíveis | slash-commands competem em completion; mover p/ profile ou plugin |
| T5 | Telemetria `session-injections.jsonl` por turno (plugin) | I/O por turno; falha não quebra sessão (correto) — monitorar tamanho |
| T6 | Princípio: nada de "dezenas de MCPs permanentes" — hoje compliant (3) | **manter**; novos MCPs entram via profiles sob demanda (§21) |

---

## 19. Machine vs Orchestration Matrix

| Capability | Máquina | Orchestration | Estado desejado | Gap | Ação |
|---|---|---|---|---|---|
| Agents core (15) | registrados + `.md` | `source/agents` + templates + manifest hash | parity | ok | KEEP_LOCAL + MANAGED (manter) |
| Agents planning (4) | `.md` sem registro | `source/agents` + AGENTS.md Planning Layer | registrados | **registro ausente** | RECONFIGURE |
| Skills core (5) | instaladas | `skills-core/` + manifest | parity (precedência?) | overlap D1 | RECONFIGURE |
| autoresearch + 14 cmds | local, sem par | ausente | decisão owner | sem owner | INVESTIGATE |
| jev-ultrafast skill | local (path absoluto) | ausente (só policy advisory) | documentar | sem owner | PROFILE_ONLY / PROJECT_ONLY |
| ~98 skills shadow | `~/.agents/skills` | ausentes | curadoria | sem catálogo | INVESTIGATE → curar |
| MCP ai-memory/context7/jev | configurados | policies (sem config) | como está | ok | KEEP_LOCAL |
| MCPs profiles (github, playwright...) | ausentes | ausentes | recipes + profiles | tudo | INSTALL (fase 2, por profile) |
| enforcement plugin | bundle sem referência | fonte + dist + sha | carregamento provado | prova ausente | INVESTIGATE |
| orca/ai-memory plugins órfãos | presentes | ausentes | removidos da raiz | lixo ativo | REMOVE |
| models/pins | 2.0.24 / 1.18.31 | pins 2.0.23 / 1.18.34 | alinhados | drift | UPDATE |
| permissions | amplas (máquina) | matriz 19×classe (docs) | endurecidas | gap | RECONFIGURE |
| service.json senha | plaintext (máquina) | n/a (local por princípio) | env-only | gap | RECONFIGURE |
| telemetria/evidence | `evidence/` + `cache/` locais | schemas + retention | como está | ok | KEEP_LOCAL |
| binaries/tools | máquina | `runtime-versions.json` pins | pins vigentes | 2 pins | UPDATE |

Princípio aplicado: orchestration possui regras/catálogo/manifests/registry/profiles/recipes/health-checks/constraints/routing/permissions/desired-state; máquina possui binaries/credentials/OAuth/secrets/caches/estado/containers/browser-profiles/config pessoal.

---

## 20. Proposed Capability Registry V2

Evolução **documental** (sem mudança arquitetural nesta fase). Estender `source/registry/` com um índice por capability que referencie os JSONs existentes:

```yaml
capability:
  id: github-pr                    # ex.
  description: "Operar PRs/issues via gh + MCP GitHub"

  agents: [coder, reviewer]         # subset dos 19; planning advisors só após A1
  skills: [github-triage]           # id do catálogo curado (§7); ausente hoje -> curar de ~/.agents/skills
  mcps: [github]                    # profile backend/core (§21)
  plugins: []                       # vazio por default
  tools: [gh, git]                  # binários externos (§10)

  dependencies: [docker: ausente]   # runtime externo necessário
  profiles: [core, backend]          # §21

  runtime:
    v1: unsupported                 # V1 = legado/rollback
    v2: supported

  permissions:
    bash: ["gh pr *", "gh issue *"]
    edit: allow-scope-repo

  risk:
    level: medium                    # low|medium|high|critical
    notes: "escrita em repo remoto; nunca --force sem approval"

  activation:
    mode: profile                   # always|profile|project|manual

  installation:
    managed: false                   # recipe no orchestration, secret na máquina
    scope: machine

  healthcheck: "gh auth status && gh repo view --json name"
  version_policy: "gh >= 2.90 (pin em runtime-versions.json:tools)"

  conflicts: [mcp-composio-github]  # se ambos um dia existirem
  fallback: [cli-gh, skill-github-triage]
```

- **Primeiras capabilities a registrar (fase 2):** `core-docs` (context7), `core-memory` (ai-memory), `research-browser` (jev), `testing-e2e` (playwright), `vcs-github` (gh+MCP), `db-supabase`, `db-neon`, `infra-docker`, `obs-posthog`, `pay-stripe`, `auto-n8n`, `seo-dataforseo`.
- **Regra:** capability nova entra como `activation: manual` + `risk` declarada; promoção a `profile`/`always` exige evidência de uso (2+ projetos) — anti-"dezenas de MCPs permanentes".

---

## 21. Proposed MCP Profiles

Composição inicial (esta auditoria **reduz** a lista pedida onde há sobreposição):

| Profile | MCPs | Nota da auditoria |
|---|---|---|
| `core` | GitHub, Context7 | ai-memory é transversal (fora de profile — sempre via env quando configurado) |
| `frontend` | Context7, Playwright, Chrome DevTools, Figma | Playwright CLI já instalado; Figma só com projeto real |
| `backend` | Context7, Postman | Postman só se API-testing recorrente; senão `cli-curl` basta |
| `database-supabase` | Supabase | CLI ausente — instalar sob demanda |
| `database-neon` | Neon | idem; **um por projeto** (supabase × neon = PROJECT_ONLY) |
| `testing` | Playwright, Chrome DevTools, Postman | reaproveita frontend/backend |
| `infra` | Docker (gateway), Terraform, Cloudflare, Grafana | nada instalado — fase 2 só com necessidade |
| `product` | PostHog, Figma | — |
| `automation` | n8n | n8n não detectado — avaliar vs `autoresearch` local antes |
| `payments` | Stripe | só com projeto de pagamento; risk high |
| `growth-google` | GA, Google Ads | — |
| `growth-seo` | DataForSEO (**preferido**) | Ahrefs **ou** DataForSEO — não ambos (custo) |
| `sales` | HubSpot | — |
| `research` | Context7, Jev, Jina (quando aplicável) | Jina só se web-fetch nativo insuficiente |

- **Alterações vs lista pedida:** (1) ai-memory fora de profiles (transversal opt-in); (2) DataForSEO preferido over Ahrefs (custo/API); (3) Composio/Pipedream **não recomendados** por default (agregadores ampliam superfície; preferir MCPs diretos) — P3.
- **Mecanismo:** profiles como recipes + `healthcheck` no registry (fase 2); ativação por projeto/tarefa, nunca global permanente.

---

## 22. Recommended Additions

| # | Capability | Por quê (valor) | Sobreposição checada | P |
|---|---|---|---|---|
| +1 | Registrar os 4 planning agents | AGENTS.md promete; custo zero | nenhuma | P0 (fix) |
| +2 | MCP GitHub (profile core) | PRs/issues recorrentes; `gh` já instalado | `github-triage` skill cobre parcial | P1 |
| +3 | MCP Playwright + Chrome DevTools (profiles testing/frontend) | E2E/evidência visual; CLI já instalado | `playwright-cli` skill cobre parcial | P1 |
| +4 | Curar `ai-memory-*` skills p/ path gerenciado | handoff/consolidação disciplinados | MCP cobre dados, skill cobre ritual — complementares | P1 |
| +5 | `systematic-debugging` (+ `tight-feedback` quando flaky) | método de debugging repetível | `debugger` agent cobre execução | P2 |
| +6 | MCP Supabase **ou** Neon por projeto | DB managed recorrente | CLI ausente — instalar sob demanda | P2 |
| +7 | MCP Postman (backend/testing) | coleções de API | curl cobre parcial | P2 |
| +8 | MCP Figma (frontend/product) | design→código | só com projeto real | P2 |
| +9 | MCP Docker Gateway (infra) | containers como tools | engine já roda | P2 |
| +10 | PostHog / Stripe / n8n / GA / DataForSEO / HubSpot | conforme projeto | nenhum instalado | P2 (cada) |
| +11 | Cloudflare/Terraform/Grafana | só com infra real | wrangler/tf ausentes | P3 |
| +12 | Composio/Pipedream | agregadores | sobrepõem MCPs diretos | P4 (não) |

---

## 23. Recommended Updates

| # | Item | De | Para | Como (fase 2) |
|---|---|---|---|---|
| U1 | `agents{}` | 17 chaves | 21 (build+title+19) ou 17 + remoção dos 4 `.md`/allows | template + render + smoke |
| U2 | `@opencode/cli` pin | 2.0.23 | 2.0.24 (após smoke) | `runtime-versions.json` + revalidação |
| U3 | `@opencode-ai/plugin` | 1.18.31 instalado | 1.18.34 (após smoke) | update + teste |
| U4 | `tui.json` | schema V1 + orca plugin | schema V2 ou remoção | decidir owner orca |
| U5 | Permissões bash/edit | `* allow` | allowlist + `ask` ampliado | `opencode.json` + docs |
| U6 | `service.json` | senha plaintext | env/secret store | migração + rotação |
| U7 | `skills.paths` | 2 paths (103+7) | curadoria + precedência documentada | config + docs |

---

## 24. Recommended Removals

| # | Item | Destino |
|---|---|---|
| R1 | `orchestration.md` (legado V1) | arquivo morto fora da raiz |
| R2 | `agents-v2-20260915/` (snapshot c/ `opencode-loop-local.md`) | arquivo |
| R3 | `*.disabled`, `*.bak*`, `rollback-*`, `*-backup-*` dentro de `plugins/` e raiz do config | arquivo (manter 1 backup íntegro fora da raiz) |
| R4 | `ai-memory-opencode2.ts` + variantes disabled (duplicata do MCP) | arquivo |
| R5 | `herdr-agent-state*.disabled` (se Herdr não for usado) | arquivo; se usado, reinstalar versão vigente |
| R6 | `obscura` (já removido do ativo; só resta em bak) | nenhuma ação — confirmar que nenhum launcher o referencia |
| R7 | Backups redundantes (`backups/` 10+, `opencode-v1-backup-*` duplicado) | 1 íntegro; resto p/ arquivo frio |

Nada removido nesta fase.

---

## 25. Recommended Local-Only Components

Binaries (`node/bun/python/docker`, shims `bin\`), credentials/OAuth/secrets (`AI_MEMORY_AUTH_TOKEN`, `OPENCODE_ZEN_API_KEY`, `service.json:password` pós-migração), caches (`node_modules/`, `.venv/`), estado (`evidence/`, `cache/`, `manifest.json`), containers, browser profiles (Chrome/Edge/Playwright), `models.jsonc` local, `mcp.*` endpoints + auth, launcher `agent-config/` (legado, user-owned), skills pessoais inevitáveis (ex.: `vendas-br`, `trafego-pago-br` se uso individual).

---

## 26. Recommended Orchestration-Managed Components

`AGENTS.md` markered, `agents/*.md` + `agents{}` (pós-U1), 5 `skills-core`, `orchestration-enforcement` (fonte+dist+sha, pós-Q1), `templates/*.tmpl`, `scripts/{render,reconcile,build-plugin}`, `scripts/v3/*`, `source/registry/*` (+ índice de capabilities §20), `source/policies/*`, `docs/` (ARCHITECTURE/INSTALLATION/GOVERNANCE/PERMISSIONS/SECURITY/TROUBLESHOOTING), `models.example.jsonc`, pins em `runtime-versions.json`, profiles/recipes/healthchecks (§21), `tests/distribution/*`, `evidence/` como autoridade de prova (conteúdo local, schema gerenciado).

---

## 27. Migration Plan

**Fase 2A — Correções (semana 1, baixo risco):**
1. Q1: provar mecanismo de plugins (registro vs autoload) — decide destino do enforcement.
2. U1: registrar ou remover os 4 planning agents (template + render + smoke V2).
3. U5/U6: endurecer permissões; migrar `service.json:password` p/ env + rotação.
4. U4: resolver `tui.json`/orca. R1–R7: arquivar órfãos (1 commit de limpeza, rollback via backup único).
5. U2/U3: alinhar pins (smoke V2 antes de cada bump). Commitar as 2 mudanças sujas atuais em PR separado.

**Fase 2B — Curadoria (semana 2):**
6. Auditar as 103 skills shadow → catálogo curado (CORE/RECOMMENDED/PROJECT_SPECIFIC); definir `skills.paths` final + precedência.
7. Decidir `autoresearch` (adotar/arquivar/maneter local).
8. Instalar profiles `core` (MCP GitHub) + `testing` (Playwright/DevTools) — pilotos com `healthcheck`.

**Fase 2C — Expansão (sob demanda):**
9. Registry V2 (§20) + profiles restantes (§21) conforme projetos reais. Nenhum MCP novo global permanente.

**Gates:** cada passo com backup prévio + `manifest` + smoke; PR com review (política do repo); sem merge automático.

---

## 28. Priority Matrix

| Prioridade | Itens |
|---|---|
| **P0 core obrigatório** | U1 (planning agents), Q1 (plugins), U5+U6 (perms/secret), MCP ai-memory + context7 (manter), 15 agents + build + 5 skills-core (manter) |
| **P1 muito recomendado** | MCP GitHub, MCP Playwright/DevTools, skills `ai-memory-*` curadas, pins U2/U3 |
| **P2 profile/domain** | Supabase/Neon, Postman, Figma, Docker GW, PostHog, Stripe, n8n, GA/Ads, DataForSEO, HubSpot, `systematic-debugging` |
| **P3 experimental** | Cloudflare/Terraform/Grafana, Jina, `autoresearch` (se adotado) |
| **P4 não recomendado** | Composio/Pipedream por default, Ahrefs+DataForSEO juntos, MCPs globais permanentes, segundo backup V1 na raiz ativa |

---

## 29. Risks

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|---|
| 1 | Enforcement inoperante sem ninguém notar | média | alto | Q1 imediato + healthcheck de plugin na fase 2 |
| 2 | Delegação p/ planning agent inexistente | média | alto | U1 imediato |
| 3 | Skill shadow errada vence a gerenciada | média | médio | curadoria + precedência |
| 4 | `service.json` vaza em backup/dotfiles | baixa | alto | U6 + varredura `gitleaks` (S7) |
| 5 | Permissão `bash * allow` executa destrutivo | baixa | alto | U5 |
| 6 | Bump de versão quebra render/reconcile | baixa | médio | pins + smoke por bump |
| 7 | Repo sujo contamina PR de docs | alta | baixo | este relatório vai em branch isolada, sem tocar os 2 arquivos sujos |

---

## 30. Open Questions

1. **Q1:** `plugins/orchestration-enforcement.js` carrega sem entrada em `plugin: []` (autoload) ou está inoperante? (exige doc/teste de runtime V2)
2. **Q2:** Precedência entre `~/.agents/skills` × `~/.config/opencode/skills` em colisão de nome?
3. **Q3:** `orca-opencode-status` (TUI) é necessário? Owner? Aceita migrar p/ schema V2?
4. **Q4:** `autoresearch` (v2.2.2 + 14 commands) será produto oficial, local-only ou arquivado?
5. **Q5:** Herdr em uso? (`-herdr-agent-state` negado + vestígios `_v1-herdr/`)
6. **Q6:** Origem dos 6 processos `opencode` (todos legítimos? algum `serve` órfão?)
7. **Q7:** `OPENCODE_CONFIG_CONTENT` já foi usado alguma vez neste host? (bypass de arquivo)
8. **Q8:** Node canônico: Program Files × pnpm × bun — qual deve vencer no PATH?

---

## 31. Evidence

- `opencode --version` → `opencode v2.0.24`
- `where.exe opencode` → `C:\Users\walis\bin\opencode{,.cmd}` + `AppData\Roaming\npm\opencode{,.cmd}`
- `npm ls -g --depth=0` → `@opencode/cli@2.0.24`, `@playwright/cli@0.1.13`, `playwright@1.60.0`, 20+ pacotes (lista completa em §3/§10)
- `node/npm/bun/pnpm` → `v26.7.0` / `11.19.0` / `1.3.14` / `10.34.1`
- `git/gh` → `2.54.0.windows.1` / `2.93.0`; `python/uv` → `3.14.7` / `0.12.19`; `docker` → `29.8.1` + compose `v5.5.1`; `pwsh` → `7.6.6`
- `C:\Users\walis\.config\opencode\opencode.json:1-82` (schema/permissions/skills.paths/mcp/plugin/model/agents.build), `:83-...` (`agents` 17 chaves — contagem via `python -c`), tail (limits `gpt-6*`)
- `agents/*.md` → 19 arquivos; `skills/` → 7 dirs; `plugins/` → 11 entradas; `commands/` → 14 `autoresearch*`
- `C:\Users\walis\.agents\skills` → **103** dirs; overlap 5 com config
- `cli.json:$schema .../v2/cli.json`; `tui.json:$schema .../tui.json` + orca TUI plugin
- `service.json` → keys (`port: 4096`, `password`: configurado)
- `manifest.json` → `package_version 1.1.0`, `runtime.id opencode-v2`, `installed_at 2026-10-06T08:24:12-03:00`, `source_revision de4eaa0`
- `bin\opencode.ps1:1-12` (shim → `invoke-agent.ps1` → `APPDATA...opencode.exe`); `bin\opencode2.ps1.bak-20261001`
- `agent-config/scripts/invoke-agent.ps1:121` (`OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` filho)
- `netstat` → `127.0.0.1:4096 LISTENING PID 5704`; `Get-Process` → 6 `opencode`, `chrome` ×N, `docker` ×N, `node` ×N
- `docker ps` → vazio; `schtasks` → `AI-Memory-Backup-Local` (de 394)
- `D:/projetos/opencode-orchestration` → `git status`: `M scripts/reconcile-opencode-config.ps1`, `M tests/distribution/runtime-install.tests.ps1`; `log -5` closure V3.1; `source/registry/` 17 JSONs; `runtime-versions.json:5-28` pins; `skills-core/` 5; `templates/` 2; `.ai-memory.toml` (`ferramentas/opencode-orchestration`)
- MCP: `list_mcp_resources` → `{resources:[],templates:[]}`; `memory_status` → 327 `pages_latest`
- Subagentes (4 waves, read-only): orchestration-map, local-V1/V2, agents/skills/plugins, MCPs/services — sínteses integradas acima
- **Não verificado** (sem shell no worker / fora do escopo read-only): diff byte-a-byte `skills-core` × global; symlinks/junctions; `OPENCODE_CONFIG_CONTENT` em uso; conteúdo `~/.agents/skills` além de nomes; `.env` reais; `service.json:password` (nunca lido)

---

## 32. Final Recommendation

**Manter o núcleo, corrigir 4 highs, curar as bordas, expandir por profiles.**

1. **Não instalar nada novo** antes de U1 (planning), Q1 (plugins), U5/U6 (perms/secret).
2. **Primeiro pacote (2A):** registrar/remover planning agents; provar enforcement; endurecer permissões; migrar `service.json`; arquivar órfãos; alinhar pins.
3. **Segundo pacote (2B):** curar 103→catálogo; decidir `autoresearch`; pilotos `core` (GitHub) + `testing` (Playwright/DevTools).
4. **Depois (2C):** registry V2 + profiles sob demanda real, nunca global permanente.
5. **Guardião permanente:** `Task → Planner → Registry → Agents+Skills+MCP Profile+Plugins+Permissions → Execution → Validation → Evidence`, com capabilities `manual`-first e promoção só com evidência de uso.

Relatório produzido em branch isolada `docs/audit-opencode-capabilities-2026-10-06`, sem tocar `main` nem os 2 arquivos sujos. PR e merge seguem a política do repo (review obrigatório).
