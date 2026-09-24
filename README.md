# opencode-orchestration

> Short intro in English: autonomous subagent orchestration for OpenCode —
> a Planner plus cheap/strong worker pools, mandatory preflight, and a
> `coder → tester → reviewer` cycle — packaged for install on any machine.

Sistema de orquestração autônoma de subagents para o OpenCode, empacotado para
instalação em outras máquinas. O agente principal atua como Planner e delega a
workers especializados sem precisar de permissão a cada passo.

## O que é

- **Planner + pools cheap/strong**: o agente primário `build` herda o modelo da
  sessão; workers baratos fazem exploração, implementação e testes; workers
  fortes fazem review crítico, debugging, segurança e arquitetura.
- **Preflight obrigatório**: toda tarefa passa por `TRIVIAL_DIRECT`,
  `DELEGATED`, `DETERMINISTIC_FALLBACK` ou `BLOCKED` antes da primeira ação.
- **Ciclo coder → tester → reviewer**: correção delimitada a cada finding,
  com Debugger/Architect após duas tentativas sem êxito.
- **Plugin de enforcement**: injeta o bloco de orquestração em toda sessão e
  registra telemetria local sanitizada.

## Estrutura do repo

```
source/agents/*.md            19 definições de subagents (tokens de modelo)
source/global/AGENTS.md       política global (tokens)
source/adapters/opencode.md   adaptador OpenCode (sem bloco de terceiros)
source/policies/*.md          autonomia, credenciais, roteamento de conhecimento
scripts/render-opencode-config.ps1, reconcile-opencode-config.ps1
scripts/v3/...                preflight, route-accept, shadow-route, skill-bridge,
                              suítes *.tests.ps1 e lib/* (cerca de 42 arquivos)
skills-core/{5 pastas}        hybrid-development, dispatching-parallel-agents,
                              subagent-driven-development,
                              verification-before-completion, using-superpowers
plugins/orchestration-enforcement.ts
templates/opencode.json.tmpl  config base do OpenCode (só seções do sistema)
models.example.jsonc          exemplo de configuração de modelos
install.ps1                   instalador idempotente (PowerShell 5.1)
```

## Requisitos

- OpenCode instalado e funcional.
- Windows PowerShell 5.1 ou `pwsh` recente.
- `bun` ou `npm` (para a dependência `@opencode-ai/plugin` do plugin;
  best-effort — o instalador avisa se falhar, sem abortar).

> **Rede:** o instalador pode acessar a rede para instalar a dependência
> fixada `@opencode-ai/plugin@1.18.31` (via `bun add` ou
> `npm install --prefix`). Para pular, instale sem rede com
> `.\install.ps1` em máquina que já tenha a pasta
> `.config\opencode\node_modules\@opencode-ai\plugin`, ou instale
> manualmente depois com
> `cd ~/.config/opencode; bun add @opencode-ai/plugin@1.18.31`.

## Instalação

```powershell
git clone <este-repo>
cd opencode-orchestration
copy models.example.jsonc models.jsonc
# edite models.jsonc com seus modelos:
#   planner — ex. zai-coding-plan/glm-5.3-flash
#   cheap   — ex. opencode-go/muse-spark-1.3-contributor
#   strong  — ex. openai/gpt-6-sol
.\install.ps1 -WhatIf
.\install.ps1
```

Para instalar sem as skills embutidas: `.\install.ps1 -NoCoreSkills`. Para
instalar a partir de outro diretório ou em outro perfil:
`.\install.ps1 -RepoRoot <caminho> -TargetHome <perfil>`. Rodar duas vezes não
duplica nem quebra (idempotente).

## O que é instalado

- `~/.config/opencode/AGENTS.md` — concatenação de `source/global` +
  `source/adapters/opencode.md` com modelos resolvidos, dentro dos marcadores
  `<!-- opencode-orchestration:start -->` / `<!-- opencode-orchestration:end -->`.
  Conteúdo pré-existente fora dos marcadores é preservado.
- `~/.config/opencode/agents/*.md` — 19 agents, com o bloco `orchestration:` do
  frontmatter removido na instalação (o canonical com o bloco vive neste repo).
- `~/.config/opencode/plugins/orchestration-enforcement.ts` — enforcement por
  sessão; telemetria em `~/.opencode-orchestration/evidence/...`.
- `~/.config/opencode/skills/*` — as 5 skills-core (a menos que `-NoCoreSkills`).
- `~/.config/opencode/opencode.json` — **merge estrutural**: atualiza só as
  chaves do sistema (`$schema`, `model`, `default_agent`, `subagent_depth`,
  `agent`; `skills.paths` e `autoupdate` só quando ausentes). MCPs, `plugin`
  preenchido e chaves desconhecidas do usuário são preservados — nunca
  sobrescritos.
- Backup automático do que já existia em
  `~/.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/`.

## Troca de modelos

Edite `models.jsonc` (`planner`, `cheap`, `strong`) e rode `.\install.ps1` de
novo. Os tokens `{{MODEL_PLANNER}}`, `{{MODEL_CHEAP}}` e `{{MODEL_STRONG}}` nas
fontes são resolvidos a cada instalação; `{{HOME}}` e `{{REPO_DIR}}` viram os
caminhos da máquina destino.

## Scripts v3

Os scripts em `scripts/v3/` (preflight, route-accept, shadow-route) rodam a
partir do clone — aponte `-RepoRoot` do instalador ou execute diretamente, ex.:

```powershell
powershell -NoProfile -File scripts\v3\orchestration-preflight.ps1 `
  -Objective "corrigir bug X" -TaskType implementation `
  -Domain backend -Risk low -ReadWrite write
```

As suítes `*.tests.ps1` validam o comportamento determinístico sem rede, sem
MCP e sem mudança de autoridade.

## Desinstalação

- Restaure o backup em `.config\opencode\backups\oo-*` por cima dos arquivos, ou
- apague o bloco entre `<!-- opencode-orchestration:start -->` e
  `<!-- opencode-orchestration:end -->` no `AGENTS.md` e remova os arquivos de
  `agents/`, `plugins/orchestration-enforcement.ts` e as pastas de `skills/`
  instaladas por este pacote.

## Aviso de privacidade

Este repo não contém segredos, tokens, URLs internas nem dados de usuário. Os
arquivos `*.tests.ps1` contêm **canários sintéticos** (ex. `sk-SYNTHETICSECRET`,
`ghp_EVALCANARY`, `Bearer abcdef`) usados como fixtures para testar
sanitização — não são credenciais reais e devem ser mantidos como estão.

## Memória de longo prazo (opcional)

O bloco de integração com [ai-memory](https://github.com/akitaonrails/ai-memory)
foi propositalmente omitido deste pacote (é uma integração de terceiros). Para
continuidade entre sessões, instale e configure o ai-memory à parte seguindo a
documentação oficial do projeto.
