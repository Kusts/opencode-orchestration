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
(`TRIVIAL_DIRECT`, `DELEGATED`, `DETERMINISTIC_FALLBACK` ou `BLOCKED` antes
da primeira ação), ciclo `coder → tester → reviewer` e um plugin de
enforcement que injeta o mandato de orquestração em toda sessão e grava
telemetria local sanitizada. Detalhes em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requisitos

- OpenCode instalado e funcional.
- Windows PowerShell 5.1+ ou `pwsh` recente.
- `bun` ou `npm` — somente para a dependência `@opencode-ai/plugin@1.18.31`
  do plugin (best-effort: o instalador avisa e segue sem abortar se falhar).

## Instalar

```powershell
git clone <este-repo>
cd opencode-orchestration
copy models.example.jsonc models.jsonc
# edite models.jsonc: planner, cheap, strong (ver "Configurar modelos")
.\install.ps1 -WhatIf
.\install.ps1
```

Detalhes passo a passo em [docs/INSTALLATION.md](docs/INSTALLATION.md).
`models.jsonc` está no `.gitignore` — nunca é commitado.

## O que é instalado

- `~/.config/opencode/AGENTS.md` — `source/global/AGENTS.md` +
  `source/adapters/opencode.md` com modelos resolvidos, dentro dos
  marcadores `<!-- opencode-orchestration:start -->` /
  `<!-- opencode-orchestration:end -->`. O resto do arquivo é preservado.
- `~/.config/opencode/agents/*.md` — 19 agents (bloco `orchestration:` do
  frontmatter removido na instalação; o canônico com o bloco vive no repo).
- `~/.config/opencode/plugins/orchestration-enforcement.ts` — enforcement
  por sessão; telemetria em `~/.opencode-orchestration/evidence/...`.
- `~/.config/opencode/skills/*` — as 5 skills-core (a menos que
  `-NoCoreSkills`: `hybrid-development`, `dispatching-parallel-agents`,
  `subagent-driven-development`, `verification-before-completion`,
  `using-superpowers`).
- `~/.config/opencode/opencode.json` — **merge estrutural**: atualiza só as
  chaves do sistema; MCPs, `plugin` preenchido, agents e chaves
  desconhecidas do usuário são preservados, nunca sobrescritos.
- Backup automático do que já existia em
  `~/.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/`, mais
  `~/.opencode-orchestration/manifest.json` (ownership do pacote).

## Configurar modelos

Três chaves em `models.jsonc` (copiado de `models.example.jsonc`):

| Chave | Uso |
|---|---|
| `planner` | Modelo default global (`model` no `opencode.json`); o agente `build` **herda o modelo da sessão** — `agent.build.model` é removido e nunca fixado. |
| `cheap` | Pool barato: explorer, researcher, coder, tester, docs-manager, engineers, advisors de planning. |
| `strong` | Pool forte: reviewer, debugger, security-reviewer, architect. |

Trocar modelos: edite `models.jsonc` e rode `.\install.ps1` de novo. Os
tokens `{{MODEL_PLANNER}}`, `{{MODEL_CHEAP}}`, `{{MODEL_STRONG}}`
(`+ {{HOME}}`, `{{REPO_DIR}}`) são resolvidos a cada instalação.

## Validar

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
```

O primeiro checa consistência interna do pacote (10 checks, exit 0/1); o
segundo roda as suítes `*.tests.ps1` de `scripts/v3/`. Validações de
distribuição (fresh-install, idempotência, rollback, uninstall) vivem em
`tests/distribution/`.

## Atualizar

```powershell
git pull
.\install.ps1 -WhatIf
.\install.ps1
```

O instalador é idempotente e ownership-aware: só atualiza o que pertence ao
pacote; customização sua com hash divergente é mantida (o uninstall avisa
com `KEEP` em vez de remover).

## Remover

```powershell
.\uninstall.ps1 -WhatIf
.\uninstall.ps1
```

Remove só o ownership do pacote (agents, bloco markered, chaves managed,
skills, plugin, manifest). `mcp.*`, agents/chaves desconhecidas, arquivos
alterados por você após o install e
`~/.opencode-orchestration/evidence/` (seus dados) são preservados.
Detalhes em [docs/INSTALLATION.md](docs/INSTALLATION.md).

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
