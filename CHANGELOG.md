# Changelog

Todos os lançamentos relevantes deste pacote são documentados aqui, no
formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/).
Versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

Programa **V3.1 — Dual-Runtime Kernel Hardening** em andamento
(especificação e plano em `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-*`).
Fases 0–4, 6–7 (dual-runtime) e 9–19 (Task Kernel) **implementadas, revisadas
(Reviewer + Security Reviewer) e corrigidas**; Phase 5 entrega só o harness
(enforcement comportamental V2 pendente), Phase 8 tem lane CI sem smoke de
binário V2; evidência completa em
`evidence/v3.1/kernel-hardening/implementation-status.json`.

Programa **V3.1 — Runtime Reliability, Loop Recovery & Jev MCP
(Phases 21–33)** em andamento — **Phases 21–25 com estado consolidado
(2026-10-01)**, Phases 26–33 não iniciadas (detalhes em
`evidence/v3.1/runtime-reliability/program-status.json`; especificação e
plano em
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md`,
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md` e
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md`):
- **P21 done** — baseline congelado (`baseline.json`): pins V1/V2
  presentes, listener `49374` identificado como AI Memory local (Docker,
  saudável); fixtures de watchdog **17/17 PASS** (PS5.1 e PS7),
  record-only, sem enforcement; consistência **16/16 OK**;
  `CapabilityFlags` **20/20**; smokes V1/V2 com FAILED honesto por
  ambiente (sem retry, sem regressão).
- **P22 parcial-HOLD** — preflight determinístico de porta/processo
  (`scripts/runtime/RuntimePortPreflight.ps1`, 6 outcomes, exits
  0/1/2); wrapper V2 com startup condicionado a configuração verificada
  + `PORT_FREE`; E2E nativo alternativo provado em perfil isolado
  (`native-start-contract.json`, 16/16 steps, `candidate_pass`);
  diagnóstico real do `49374` (Docker/ssh por PID, nunca mutado);
  AI Memory **nunca** mutado. HOLDs: `REUSE`, wrapper produtivo
  `UNVERIFIED` (exit 2 sem schema exato), cleanup de descendants sem
  prova, set/start nativo só com `RR_P22_RUN_NATIVE=1`.
- **P23 done-record-only** — orçamentos canônicos no kernel
  (`phase23.json`): 5 perfis com defaults exatos (worker 45m, planner
  90m, steps 96, soft 3 / hard 5), role defaults, sem ampliação
  (`BUDGET_IMMUTABLE`/`BUDGET_WIDEN_DENIED`), planner-turn por input
  novo, CLI `task-kernel.ps1` (`get-budget/start-attempt/set-budget/
  planner-turn`); kernel pré-existente **75/75** preservado. Sem
  enforcement real (Phases 24–28); native step em HOLD.
- **P24 parcial** — plugin V2 migrado para `event.subscribe`
  abort-safe (`plugins/orchestration-enforcement/v2.ts`); live-hook no
  binário exato 2.0.18 (`phase24-livehook.jsonl`): plugin carrega,
  `session.created` VERIFIED, context VERIFIED, `execute.before` e
  `session.updated` NOT-VERIFIED com causa, interrupt/wait com presença
   verificada; typecheck V1+V2+DUAL, dual-runtime **20/20**, mock V2
   **22/22** (10c + 10c-controle com discriminação), V1 **30/30**,
   live-hook PS5.1 **35/0 HOLD 1** (trigger real com session==trigger,
   match=True) / PS7 **23/0 HOLD 4**; REV-FIX com 3 findings +
    TRIGGER-FIX com 4 findings corrigidos.
- **P25 done-shadow** — RuntimeWatchdog lib shadow puro
  (`scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1`, `phase25.json`):
  registra execução, fingerprints sanitizados por campo com framing
  `len:valor`, semântica de repetição da policy (soft 3 / hard 5),
  avaliação `HARD_TIMEOUT`/`NO_PROGRESS`/`REPEATED_ACTION`/`CYCLE`/
  `BUDGET_NEAR_LIMIT` em modo shadow (would-interrupt, execução
  intacta, sem task record), telemetria JSONL bounded com lock
  in-process e cap fail-closed, identidade obrigatória, flag
  `watchdog{enabled:false, shadow:true}`; `enabled=true` retorna
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED` (nada armazenado).
  Suítes: watchdog **80/80** (PS5.1 + PS7), kernel **75/75**,
  consistência **16/16 OK**; reviews Reviewer **APPROVED** (REV4) +
  Security **APPROVED** (SEC3). Follow-ups documentados: lock
  cross-process, retenção multi-dia; interrupt real é Phase 26
  (não implementado).
Revisões Reviewer + Security Reviewer encerradas com **APPROVED parcial
por fase** (HOLDs registrados). Todas as flags seguem **OFF**
(`source/registry/capability-flags.json`); nenhuma flag nova criada;
roteamento MCP genérico segue desligado; critérios `RR-01`–`RR-20`
seguem pendentes onde não cobertos acima. Programa **não** concluído.

### Added

- **Suporte dual-runtime**: OpenCode **V1** (`opencode-ai`, validado
  **1.18.32**) e OpenCode **V2** (`@opencode/cli`, validado **2.0.18**),
  ambos com comando `opencode`.
  - Registry de runtimes (`source/registry/runtimes.json`: descritores v1/v2
    com dialeto de config/permissões, pacote de plugin, chaves geridas e
    raiz de render) + detecção determinística
    (`scripts/runtime/detect-opencode-runtime.ps1`,
    `scripts/runtime/lib/RuntimeAdapters.ps1`: probe de versão/geração,
    fail-closed em ambiguidade).
  - Templates nativos por geração: `templates/opencode.v1.json.tmpl`
    (`agent`/`permission`/`task`/`subagent_depth`) e
    `templates/opencode.v2.json.tmpl` (`agents`/`permissions`/`subagent`/
    `experimental.subagent_depth`), com paridade semântica validada
    (checks 12–15 de `scripts/test-package-consistency.ps1`).
  - Tradução determinística das permissões dos 19 agents
    (`scripts/runtime/lib/AgentTranslator.ps1`: `edit→edit`, `bash→shell`
    broad-first last-match-wins, `task→subagent`, allow/ask/deny
    preservados, fail-closed em padrão ambíguo); testes de paridade em
    `scripts/runtime/agent-translation.tests.ps1`.
  - Plugin dual-runtime: fonte única (`plugins/orchestration-enforcement.ts`
    com `v1.ts`/`v2.ts`/`shared/`), dual-export `{id, setup, server}`,
    bundle autocontido `plugins/dist/orchestration-enforcement.js` +
    sidecar sha256 (o `.ts` legado no destino é adotado para backup) e
    typecheck V1/V2/dual (`scripts/ci/typecheck-plugin.ps1`).
  - `install.ps1 -Runtime Auto|V1|V2|Both` — Auto com probe e fail-closed;
    manifest grava `runtime` + `plugin_dependency` do runtime escolhido;
    `uninstall.ps1 -Runtime Auto|V1|V2` com conflito explícito (exit 6).
  - Perfis isolados V1+V2 na mesma máquina
    (`scripts/runtime/new-opencode-profile.ps1`): config root por perfil via
    `XDG_CONFIG_HOME` por processo (mecanismo provado com binários reais em
    `evidence/v3.1/kernel-hardening/runtime-isolation-spike.json` e
    re-verificado pelo installer com `debug paths`), wrappers
    `bin/opencode-v1.ps1`/`opencode-v2.ps1`, `-ProvisionRuntime` opt-in;
    `-Runtime Both` é fail-closed (exit 6) sem binários provados.
- Versão do pacote: `1.1.0` (era `1.0.0`); dependência V2 do plugin:
  `@opencode/plugin@2.0.18`.
- Spec e plano V3.1 documentados em `docs/specs/`.

- **Task Kernel (Phases 9–19)** — estado de tarefa persistente e
  determinístico, todos com suítes próprias:
  - `scripts/v3/lib/OrchestrationTaskKernel.ps1` + CLI
    `scripts/v3/task-kernel.ps1`: registros em `cache/runtime/tasks/` com
    CAS (lock interprocesso + re-checagem na seção crítica), transições
    legais, estados terminais imutáveis, `DONE` só via
    `Complete-OrchestrationTask` (gate de 12+ cheques; só de `REVIEWING`),
    orçamento de retry (2ª falha exige debugger, 3ª exige evidência nova,
    senão `EXHAUSTED`), identidade de ator com fontes confiáveis e
    redação de segredos em todo texto persistido.
  - `source/registry/execution-grants.json` + interseção de autoridade
    efetiva (baseline ∩ task ∩ runtime ∩ ambiente ∩ aprovação — nunca
    união); grants sensíveis (`destructive.fs`, `deploy.production`,
    `secrets.read`, `git.push`) fora de todo baseline.
  - Evidence Contract: worker só emite `candidate_pass|failed|blocked`;
    `verified_pass`/aprovação vêm só de verifier/reviewer; verificação
    obsoleta após novo trabalho (`verification_stale`/`review_stale`).
  - `scripts/v3/lib/OrchestrationVerifier.ps1` +
    `source/registry/verification-policy.json`: allowlist fechada de
    comandos, checagem de escopo git antes de executar qualquer comando,
    base revision obrigatória, output limitado e com segredos redigidos,
    evidência por critério (`criterion:<idx>:`) gerada pelo próprio
    verifier.
  - `scripts/v3/lib/OrchestrationOwnership.ps1`: write leases em
    `cache/runtime/locks/` com lock de diretório, conflito
    cross-generation (V1 vs V2 no mesmo escopo) e fail-closed em lease
    malformado recente.
  - `scripts/v3/lib/OrchestrationWorktree.ps1`: worktrees por tarefa com
    marker de ownership, nunca `--force` implícito, registro git
    conferido antes de remover.
  - Observabilidade: 14 tipos de evento novos (29 total) e dimensão
    runtime (`runtime_id/generation/version/profile`) opcional e
    sanitizada; flags de rollout conservadoras
    (`task_kernel` desligado+shadow, `worktree_isolation` e
    `runtime_grant_enforcement` desligados, `runtime_support.v2` off até
    ativação com evidência).
- **Revisões independentes**: Reviewer + Security Reviewer emitiram
  `CHANGES_REQUIRED` com 15 findings válidos (concorrência CAS/lease,
  auto-atestação de DONE, evidência claimed, `--force` implícito, união
  de grants, segredos) — todos corrigidos e revalidados (75/75,
  56/56, 49/49).
- **Spike V2 honesto** (`scripts/runtime/spike-v2-permissions.ps1`): com
  V2 2.0.18 provisionado no perfil, `version` e isolamento XDG passam;
  `debug config/agents` travam (2× timeout) — status `failed` registrado
  sem claim de enforcement; checklist comportamental pendente.
- **Lane CI V2** (`ci-v2-lane`): consistência + suítes V3 + distribuição +
  typecheck V1/V2/dual; smoke de binário V2 real no CI segue sem path
  comprovado no Windows.

### Pendente (não implementado)

- **Phases 26–33 (runtime reliability)** — não iniciadas: loop guard,
  enforcement de budgets, circuit breaker, Jev advisory,
  AI Memory remoto e E2E de stall/recovery. HOLDs explícitos: (d)
  `execute.before` sem via sem-modelo provada, evento `updated` não
  observado, `REUSE` de porta em produção e ativação de qualquer flag.
- **Phase 5 (comportamental)** — validar precedência de regras ordenadas,
  saved approvals e `experimental.policies` contra o runtime V2 real
  (requer resolver o travamento do `debug` V2 e/ou lane de CI com binário
  real). Nenhum hard-deny é shipado antes disso.
- **Phase 8 (smoke V2 em CI)** — mecanismo oficial de instalação V2 no
  Windows ainda não provado para uso em CI.
- **Ativação** — flags `task_kernel`/`worktree_isolation`/
  `runtime_grant_enforcement`/`runtime_support.v2` permanecem OFF; ativar
  é decisão humana com evidência (shadow rollout, Phase 19).

### Known issues (pré-existentes, dependentes de ambiente)

- 4 suítes V3 (`CapabilityDeferred`, `CapabilityObservability`,
  `CapabilitySkillUtility`, `shadow-route`) falham no invariante
  "opencode.json vivo inalterado (prefixo DE22307F)" quando o config vivo
  da máquina diverge do baseline canônico do control plane. Já falhavam no
  baseline congelado (`evidence/v3.1/kernel-hardening/baseline.json`) —
  não são regressão do V3.1. As demais suítes (incluindo as novas de
  runtime/adapters/plugin/perfis) passam; ver [TROUBLESHOOTING](docs/TROUBLESHOOTING.md).

## [1.0.0] — 2026-09-25

Primeira release estável do pacote `opencode-orchestration`.

### Added

- Suporte explícito à linha **OpenCode V1.x** (pacote npm `opencode-ai`),
  validado com **1.18.32**.
- Respeito a `opencode.json` **e** `opencode.jsonc`: jsonc vence quando
  ambos existem (igual ao runtime); cria `opencode.json` só se nada
  existir; jsonc com comentários é normalizado para JSON puro na escrita
  (aviso + backup byte-exato do original).
- Job de CI `ci-smoke-opencode`: instala o OpenCode V1 real 1.18.32, roda
  o install num home isolado e valida com
  `opencode debug config/agent/skill` (falha se a versão for 2.x).
- Typecheck estrito do plugin contra a API real
  `@opencode-ai/plugin@1.18.32` no CI
  (`scripts/ci/typecheck-plugin.ps1`).
- Identidade Planner/Worker do plugin resolvida por sessão (mapa `event`
  → `parentID` presente = worker).
- 11 checks de consistência (`scripts/test-package-consistency.ps1`),
  suítes V3 (`scripts/v3/run-v3-tests.ps1`) e 10 suítes de distribuição
  (`tests/distribution/run-distribution-tests.ps1`).
- Esta documentação de governança: `docs/GOVERNANCE.md`, `CHANGELOG.md`,
  `SECURITY.md`.

### Changed

- Versão do pacote: `1.0.0` (era `1.0.0-hardening`).
- Dependência do plugin: `@opencode-ai/plugin@1.18.32` (era 1.18.31).
- CI: `actions/checkout` pinado por SHA (v4.2.2); `bun@1.3.14` e
  `opencode-ai@1.18.32` pinados por versão exata.

### Removed

- Ownership do instalador sobre `autoupdate`, `skills.paths` e `plugin`:
  todas opcionais no schema V1; skills (`~/.config/opencode/skills`) e
  plugins (`~/.config/opencode/plugins`) têm auto-discovery. O usuário
  mantém controle total dessas chaves (install preserva, uninstall nunca
  remove).

### Security

- Sem segredos no repo nem no CI (só canários sintéticos como fixtures).
- Telemetria do plugin sanitizada e local; credenciais só via ambiente do
  runtime, nunca em git/logs/backups.

## Suporte de runtime

- OpenCode **V1.x** (`opencode-ai`): suportado — validado com **1.18.32**.
- OpenCode **V2** (`@opencode/cli`, comando `opencode`): suportado desde o
  programa V3.1 (render/config/permissões nativos, plugin dual-runtime) —
  validado com **2.0.18**; suporte a `experimental.policies` e lane de CI
  própria ainda pendentes (ver [Unreleased]).
- **V1 + V2 na mesma máquina**: via perfis isolados
  (`install.ps1 -Runtime Both` / `scripts/runtime/new-opencode-profile.ps1`).

Status da release **1.0.0** (histórico): V2 não suportado naquela data.
