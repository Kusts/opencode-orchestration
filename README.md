# opencode-orchestration

> Short intro in English: autonomous subagent orchestration for OpenCode.
> One Planner (`build`) plus 19 delegated workers, mandatory preflight
> and a `coder → tester → reviewer` cycle — packaged for install on any machine.

Orquestração autônoma de subagents para o OpenCode, empacotada para
instalação em qualquer máquina. O agente principal atua como Planner e
delega a workers especializados sem pedir permissão a cada passo.

## O que é

Um único Planner (`build`, herda o modelo da sessão) + 19 workers delegáveis
em pools cheap/strong, com preflight obrigatório de orquestração
(`SINGLE_WORKER`, `MULTI_WORKER`, `PERSISTENT_GOAL`, `DETERMINISTIC_FALLBACK` ou `BLOCKED` antes
da primeira ação), ciclo `coder → tester → reviewer` e um plugin de
enforcement que injeta o mandato de orquestração em toda sessão e grava
telemetria local sanitizada. Detalhes em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requisitos

| Requisito | Suporte |
|---|---|
| OpenCode **V1.x** (pacote npm `opencode-ai`) | ⚠️ Legado, frozen (issue #62) — funcional para perfis existentes; CI legado validou com **1.18.34** (`opencode --version` responde `1.x`). Sem certificação de features novas. |
| OpenCode **V2** (pacote `@opencode/cli`) | ⚠️ Pin atual **2.3.0**; o smoke de ciclo explícito no binário exato 2.3.0 será reexecutado no CI, e a certificação depende dele. Probes de capacidades nativas disponíveis são históricos e permanecem em HOLD. Ver [docs/INSTALLATION.md](docs/INSTALLATION.md) e [CHANGELOG](CHANGELOG.md). |
| V1 **e** V2 na mesma máquina | ✅ Via perfis isolados (`.\install.ps1 -Runtime Both`) — migração/manutenção de perfis legados; fail-closed sem binários provados. |
| Windows PowerShell 5.1+ ou `pwsh` recente | ✅ Obrigatório. |
| `bun` ou `npm` — dependência do plugin (`@opencode/plugin@2.3.0` no V2, recomendado; `@opencode-ai/plugin@1.18.34` no V1 legado) | ⚠️ Best-effort: o instalador avisa e segue sem abortar se falhar. |

## Versionamento

- Versão atual: `0.2.0` (ver `VERSION`); tag `v0.2.0` publicada em 2026-10-19 (merge #128) marca esta release.
- Tags `v0.1.2`, `v0.1.1` e `v1.0` (legada, anterior ao versionamento formal) marcam releases anteriores e são preservadas como histórico.
- `V3` / `V3.1` / `Pxx` são programas internos históricos, não versões do pacote.
- Índice SPEC/PLAN/ADR em [docs/specs/INDEX.md](docs/specs/INDEX.md); histórico de mudanças em [CHANGELOG.md](CHANGELOG.md).

## Instalar

```powershell
git clone <este-repo>
cd opencode-orchestration
copy models.example.jsonc models.jsonc
# planner, cheap e strong sao obrigatorios; free e frontier sao opcionais
.\install.ps1 -Runtime V2 -Clean -WhatIf  # reinstalação limpa: plano, nenhuma escrita
.\install.ps1 -Runtime V2 -Clean          # reinstalação limpa transacional (V2)
.\install.ps1 -Runtime V2 -WhatIf         # instalação/atualização normal: plano
.\install.ps1 -Runtime V2                 # V2: instalações novas/atualização
.\install.ps1 -Runtime V1                 # legado frozen (dialeto agent/permission/task) — só perfis existentes
.\install.ps1 -Runtime Both               # perfis isolados V1+V2 = migração/perfis legados (fail-closed sem binários provados)
```

Divisão de responsabilidades (OpenCode V2): a **Orquestração** é dona dos 19 perfis worker e do bloco `agents` (execução/delegação/modelos de perfil); o **Agent Config** compartilha texto global/instruções, `permissions` de topo, skills centrais, MCP e demais runtimes. `models.jsonc` e credenciais permanecem do usuário.

Detalhes passo a passo em [docs/INSTALLATION.md](docs/INSTALLATION.md)
(inclui perfis isolados e `-ProvisionRuntime`).
`models.jsonc` está no `.gitignore` — nunca é commitado.

## O que é instalado

- `~/.config/opencode/AGENTS.md` — `source/global/AGENTS.md` +
  `source/adapters/opencode.md` com modelos resolvidos, dentro dos
  marcadores `<!-- opencode-orchestration:start -->` /
  `<!-- opencode-orchestration:end -->`. O resto do arquivo é preservado.
- `~/.config/opencode/agents/*.md` — 19 perfis worker canônicos da Orquestração (bloco `orchestration:` do frontmatter removido na instalação; o canônico com o bloco vive no repo). Com marcador completo `agent-config:global`, o texto global permanece do Agent Config, mas a Orquestração instala os perfis e o bloco `agents`; `permissions` de topo, `mcp` e demais chaves user/Agent Config são preservadas.
- `~/.config/opencode/plugins/orchestration-enforcement.js` — bundle
  autocontido do plugin dual-runtime (fonte única com adaptadores V1/V2 e
  lógica compartilhada); enforcement por sessão; telemetria em
  `~/.opencode-orchestration/evidence/...`. Um `.ts` legado pré-bundle é
  adotado para backup e removido.
- `~/.config/opencode/skills/*` — as 8 skills-core (a menos que
  `-NoCoreSkills`: `hybrid-development`, `bmad-structured-delivery`,
  `pocock-technical-decisions`, `addy-incremental-delivery`,
  `dispatching-parallel-agents`, `subagent-driven-development`,
  `verification-before-completion`, `using-superpowers`).
- `~/.config/opencode/opencode.json` — **merge estrutural**, no dialeto do
  `-Runtime` escolhido: V1 gerencia `$schema`, `model`, `default_agent`,
  `subagent_depth`, `agent.*`; V2 gerencia `$schema`, `model`,
  `default_agent`, `experimental.subagent_depth`, `agents.*` (regras
  `permissions` ordenadas, broad-first). `opencode.jsonc` é respeitado
  (jsonc vence quando ambos existem, igual ao runtime; criado
  `opencode.json` só se nada existir).
  `autoupdate`, `skills.paths`, `plugin`, `mcp.*` e chaves desconhecidas do
  usuário **nunca** são tocados. Jsonc com comentários é normalizado para
  JSON puro na escrita (aviso + backup byte-exato do original).
- Backup automático do que já existia em
  `~/.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/`, mais
  `~/.opencode-orchestration/manifest.json` (ownership do pacote).

## Configurar modelos

O exemplo `models.example.jsonc` possui **cinco chaves**, das quais três
são obrigatórias no precheck do instalador (`install.ps1:Validate-Models`):

| Chave | Obrigatória | Uso |
|---|---|---|
| `planner` | Sim | Modelo default global (`model` no `opencode.json`); o agente `build` herda o modelo da sessão, sem modelo fixado. |
| `cheap` | Sim | Pool barato de execução e engenharia. |
| `strong` | Sim | Pool forte para revisão, arquitetura e diagnóstico. |
| `free` | Não | Pool T1 de exploração; se ausente, usa o modelo T1 da política canônica (`source/registry/model-routing-policy.json`). |
| `frontier` | Não | Override local do tier T4 no Model Router; **não** é token aplicado pelo instalador e não autoriza gasto T4. |

Após editar `models.jsonc`, execute `.\install.ps1 -WhatIf` e,
quando o preview for correto, reinstale. Os tokens
`{{MODEL_PLANNER}}`, `{{MODEL_CHEAP}}`, `{{MODEL_STRONG}}` e
`{{MODEL_FREE}}` (além de `{{HOME}}`, `{{REPO_DIR}}`) são resolvidos
na instalação. A autorização efetiva de uso de T4 depende da política e
dos gates financeiros do roteador, não de declarar `frontier` no arquivo.

## Validar

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1
```

O primeiro checa consistência interna do pacote (17 checks, exit 0/1 —
incluindo shape/paridade dos templates V1 e V2, integridade do bundle do
plugin e a cadeia canônica de escalonamento Sonnet → Opus → Astra); o
segundo roda as suítes `*.tests.ps1` de `scripts/v3/` e `scripts/runtime/`;
o terceiro roda as validações de distribuição
(fresh-install, idempotência, rollback, uninstall, runtime V1/V2, perfis
isolados — 23 suítes) de `tests/distribution/`. Gate vigente = lane V2
real; o smoke com OpenCode V1 real 1.18.34 num home isolado (`opencode
debug config/agent/skill`) é legado (linha V1 frozen desde a issue #62 —
só regressão/manutenção de perfis existentes, sem certificação de features
novas).

Condição conhecida: se o `opencode.json` vivo da máquina divergiu do
baseline canônico do control plane, 4 suítes V3 falham no invariante de
origem (hash prefixo `DE22307F`) — não é regressão do pacote; ver
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md).

Esperas externas de CI e interrupções do watchdog seguem contratos
fechados (sem daemon, sem auto-avanço): ver
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (caller de resume GitHub
P0-05 e STEER advisory opt-in + CLOSE-vs-RETRY fail-closed S5) — o
contrato vive lá, sem duplicação aqui.

## Atualizar

```powershell
git pull
.\install.ps1 -WhatIf
.\install.ps1
```

O instalador é idempotente e ownership-aware: só atualiza o que pertence ao
pacote; customização sua com hash divergente é mantida (o uninstall avisa
com `KEEP` em vez de remover). Interop Agent Config (2026-10-19, gates O0–O6
fechados): com marker `agent-config:global` presente, o instalador não
escreve texto global, perfis `agents/*` nem `agents.*.permissions`
(dono agent-config); o manifest registra `config_ownership` + proveniência.
V1 permanece frozen. Cutover (desligar cópia global) pendente de decisão P1.

## Remover

```powershell
.\uninstall.ps1 -WhatIf
.\uninstall.ps1
```

Remove só o ownership do pacote (agents, bloco markered, chaves managed,
skills, plugin, manifest). `mcp.*`, agents/chaves desconhecidas, arquivos
alterados por você após o install e
`~/.opencode-orchestration/evidence/` (seus dados) são preservados.
Com `-Runtime V1`/`-Runtime V2` o uninstall mira o runtime do manifest
(conflito explícito, exit 6); perfis criados por `-Runtime Both` são
removidos perfil a perfil (ver [docs/INSTALLATION.md](docs/INSTALLATION.md)).

## Scripts avançados

- `scripts/render-opencode-config.ps1` — renderiza `source/` para
  `generated/opencode/` (preview, não toca o destino ativo).
- `scripts/reconcile-opencode-config.ps1` — aplica o gerado no destino com
  backup e rollback (`-Apply` executa; sem flag é preview).
- `scripts/v3/build-capability-registry.ps1` — gera o registry derivado
  (opt-in, escreve em `cache/v3/`; sem ele o sistema usa fallback
  determinístico).

Ver [docs/](docs/) para arquitetura, instalação, segurança e troubleshooting.

## Notas

- Este repo não contém segredos. Os `*.tests.ps1` usam **canários
  sintéticos** (ex. `sk-SYNTHETICSECRET`) como fixtures de sanitização —
  não são credenciais reais.
- Integração com [ai-memory](https://github.com/akitaonrails/ai-memory) é
  opcional e propositalmente omitida do pacote; configure à parte pela
  documentação oficial.


## Metodologias híbridas (Superpowers, BMAD, Matt e Addy)

O Planner usa o roteador único `hybrid-development` e pode combinar técnicas de **Superpowers**, **BMAD Method**, **Matt Pocock Skills** e **Addy Osmani Agent Skills** por tarefa, sem instalar quatro frameworks concorrentes. O pacote atual já inclui adaptações de Superpowers e Matt; a inclusão automática offline de técnicas BMAD/Addy está em desenvolvimento na [issue #237](https://github.com/Kusts/opencode-orchestration/issues/237).

Fontes oficiais, comandos de instalação no OpenCode, estado real do pacote, atualização e teste rápido: **[docs/PLANNING-METHODS.md](docs/PLANNING-METHODS.md)**. Seleção adaptativa: [issue #48](https://github.com/Kusts/opencode-orchestration/issues/48). A instalação padrão continua `.\install.ps1 -Runtime V2`.
