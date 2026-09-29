# Governança do pacote

## Ownership: PACKAGE vs USER

O instalador é ownership-aware: só gerencia o que pertence ao pacote
(**PACKAGE**); todo o resto pertence ao usuário (**USER**) e nunca é
escrito nem removido.

| Recurso | Dono | Regra |
|---|---|---|
| Bloco markered do `AGENTS.md` | PACKAGE | Atualizado; resto do arquivo preservado. |
| 19 `agents/*.md` | PACKAGE | Gerenciados por hash; edição sua após o install recebe `KEEP` no uninstall. |
| `plugins/orchestration-enforcement.js` (bundle; fonte em `plugins/orchestration-enforcement.ts`) | PACKAGE | Instalado/removido com o pacote (`.ts` legado no destino é adotado para backup). |
| Skills-core em `skills/` | PACKAGE | Salvo `-NoCoreSkills`. |
| Chaves do sistema no config (`$schema`, `model`, `default_agent`, `subagent_depth`, `agent.*`) | PACKAGE | Merge estrutural (json ou jsonc, ver [INSTALLATION](INSTALLATION.md)). |
| `autoupdate`, `skills.paths`, `plugin`, `mcp.*`, agents/chaves desconhecidas, conteúdo fora dos markers | USER | **Nunca tocados** — install preserva, uninstall nunca remove. |
| `~/.opencode-orchestration/evidence/` (telemetria) | USER | Seus dados; o uninstall preserva. |

`~/.opencode-orchestration/manifest.json` registra hashes, snapshot do
config e modelos usados — é a fonte de ownership para upgrades e
uninstall. `adopted_paths[]` é mantido no manifest (sempre vazio hoje)
só por compatibilidade com manifests antigos.

## Processo de mudança

1. **`source/` é o canônico** — `source/global/AGENTS.md` (política
   global) + `source/adapters/opencode.md` (runtime) + `source/agents/`
   (19 workers) + `source/registry/` (flags/policy/runtimes). Em
   divergência, o `source/` vence.
2. **`render`** (`scripts/render-opencode-config.ps1`) gera preview em
   `generated/` — nunca toca o destino ativo.
3. **`reconcile`** (`scripts/reconcile-opencode-config.ps1`) aplica no
   destino com backup byte-exato e rollback.
4. Mudanças nos 19 agents, nos templates (`templates/opencode.v1.json.tmpl`, `templates/opencode.v2.json.tmpl`),
   no plugin (`plugins/`) ou no registry passam pelos checks de
   consistência antes de qualquer release.

## Versão e SemVer

O pacote segue SemVer (`MAJOR.MINOR.PATCH`, versão atual **1.1.0**,
registrada em `install.ps1:$PackageVersion` e no manifest):

- **PATCH**: correções de docs, mensagens, testes — sem mudança de
  comportamento do instalador.
- **MINOR**: recursos novos compatíveis (novo check, nova suite, chave
  gerida adicional documentada).
- **MAJOR**: quebra de compatibilidade (mudança de ownership, remoção de
  chave gerida, troca de linha de runtime suportada).

Toda release atualiza o [CHANGELOG](../CHANGELOG.md) (Keep a Changelog).

## Critérios de release

Uma versão só é publicada com, cumulativamente:

1. **Suítes verdes**: 16 checks de consistência
   (`scripts/test-package-consistency.ps1`), suítes V3
   (`scripts/v3/run-v3-tests.ps1`, incluindo as de `scripts/runtime/`) e
   13 suítes de distribuição
   (`tests/distribution/run-distribution-tests.ps1`, incluindo runtime
   V1/V2 e perfis isolados). Exceção documentada: 4 suítes falham quando o
   `opencode.json` vivo diverge do baseline canônico — invariante de
   ambiente, não do pacote (ver [TROUBLESHOOTING](TROUBLESHOOTING.md)).
2. **Smoke com OpenCode real**: job `ci-smoke-opencode` verde
   (install num home isolado + `opencode debug config/agent/skill`).
   Lane de CI para V2/dual-perfil pendente (Phase 8 do V3.1); smoke V2
   atual é via suítes locais e spike de isolamento.
3. **Typecheck do plugin** contra as APIs reais pinadas V1 e V2
   (`scripts/ci/typecheck-plugin.ps1`, trilhas V1/V2/dual).
4. **Evidência**: logs das suítes e CHANGELOG atualizado.

## Maintenance mode da orquestração V3

A orquestração V3 está em **maintenance mode**: sem V4, sem novas phases
de roteamento, flags de router, routers ou frameworks. Estados
`HOLD`/`BLOCKED`/`DEFERRED` são
finais válidos, não pendências. Reabertura **só** por trigger observado:

1. Bug/regressão em produção ou uso real.
2. Nova capability relevante do OpenCode.
3. Telemetria recorrente `WRONG`/`SUBOPTIMAL`/`ORCHESTRATION_POLICY_BYPASS`,
   fallback inadequado ou retry excessivo.
4. Mudança de modelo/runtime exigindo compatibilidade.
5. Nova evidência permitindo retirar um `HOLD`/`BLOCKED`/`DEFERRED`.

**Exceção ativa (trigger 4)**: o programa **V3.1 — Dual-Runtime Kernel
Hardening** (`docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-*`, classes
`RUNTIME_COMPATIBILITY` + `FEATURE_REEVALUATION`) adiciona suporte nativo
V2 e o Task Kernel sob controle de evidência e flags conservadoras. Ele
**não** reabre o router/flags da V3: `skill_routing`, `mcp_routing` e
`adaptive_ranking` seguem desligados.

Detalhes e classes de mudança (`BUGFIX`, `RUNTIME_COMPATIBILITY`,
`MODEL_POLICY_CHANGE`, `ROUTING_POLICY_CHANGE`, `AUTHORITY_CHANGE`,
`FEATURE_REEVALUATION`) em [ARCHITECTURE](ARCHITECTURE.md). Nunca
implementar por hipótese.
