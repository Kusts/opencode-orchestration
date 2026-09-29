# Changelog

Todos os lançamentos relevantes deste pacote são documentados aqui, no
formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/).
Versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

Programa **V3.1 — Dual-Runtime Kernel Hardening** em andamento
(especificação e plano em `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-*`).
Fases 0–4 e 6–7 implementadas e verificadas; fases 5 e 8–20 pendentes.

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

### Pendente (não implementado)

- **Phase 5** — spike de enforcement V2: fixture de resource strings,
  precedência de regras em runtime real e `experimental.policies`
  (hard-deny). `docs/PERMISSIONS.md` descreve o render nativo, mas o
  enforcement V2 ainda não foi validado contra o runtime.
- **Phase 8** — lanes de CI para V2 e dual-perfil (o CI atual valida só V1
  1.18.32; V2 é validado por suítes locais + spike de isolamento).
- **Phases 9–19** — Task Kernel: estado persistente com CAS, execution
  grants, Evidence Contract, verifier determinístico, DONE
  kernel-authorized, leases, worktrees, observabilidade com dimensão de
  runtime e shadow rollout. Nenhuma flag `runtime_support`/`task_kernel`
  existe ainda em `source/registry/capability-flags.json`.

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
