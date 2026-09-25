# Troubleshooting

## Plugin não carrega

Sintoma: nenhum mandato `[orchestration-enforcement:v1]` na sessão.

1. Dependência ausente é a causa mais comum: confira
   `.config/opencode/node_modules/@opencode-ai/plugin`. Se faltar,
   instale manualmente e reinicie o OpenCode:
   ```powershell
   cd ~/.config/opencode
    bun add @opencode-ai/plugin@1.18.32
    # ou: npm install @opencode-ai/plugin@1.18.32 --prefix ~/.config/opencode
   ```
2. Confira que `.config/opencode/plugins/orchestration-enforcement.ts`
   existe (é o que o `install.ps1` instala).
3. Reinicie o OpenCode após instalar dependência ou plugin — carrega no boot.

## Provider rejeita o system prompt (prompt muito longo)

O que o plugin faz: injeta **um** mandato curto (Planner, worker ou neutro)
fundido à primeira entrada do system (`system[0]`), com idempotência por
marker (se o marker já está lá, não injeta de novo) e fail-safe silencioso
(input malformado → sem injeção, sem crash). Ele não duplica nem cresce a
cada turno.

Se mesmo assim o provider reclamar de tamanho:

1. Rode com `-NoCoreSkills` na próxima instalação para reduzir skills.
2. Para remover **só o plugin** (mantendo agents e `AGENTS.md`): apague
   `.config/opencode/plugins/orchestration-enforcement.ts` e reinicie.
   Sem o plugin, o sistema continua valendo por `AGENTS.md` + preflight —
   você só perde o mandato automático e a telemetria.

## Registry ausente ("registry missing")

Comportamento esperado: **fallback determinístico**. A registry derivada
(`cache/v3/capability-registry.json`) é opt-in; sem ela, o preflight e o
roteamento seguem a política determinística normalmente.

Para gerar (opt-in):

```powershell
powershell -NoProfile -File scripts\v3\build-capability-registry.ps1
```

Flags em `source/registry/capability-flags.json` nascem todas `false` —
roteamento assistido só com ativação humana explícita.

## models.jsonc inválido

O `install.ps1` aborta no precheck com **exit 3** e mensagem do motivo,
sem escrever nada. Causas comuns:

- Arquivo ausente (copie de `models.example.jsonc` — o instalador não
  cria sozinho de propósito).
- JSONC que não parseia (vírgula, chave ou comentário malformado).
- Chave `planner`, `cheap` ou `strong` ausente ou vazia.

Corrija, rode `.\install.ps1 -WhatIf` e depois `.\install.ps1`.

## OpenCode atualizou — e agora?

Política de suporte: a linha **OpenCode V1.x** é suportada (CI valida com
**1.18.32**, pacote npm `opencode-ai`). OpenCode **V2** (pacote
`@opencode-ai/cli`, comando `opencode2`) **não é suportado** — migração
futura é decisão explícita.

Colisão V1/V2 (os dois comandos instalados): confira qual responde —

```powershell
opencode --version   # deve ser 1.x
opencode2 --version  # se existir, é a V2 — não suportada por este pacote
```

Após atualizar o runtime **dentro da linha V1**, revalide com a suíte:

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
```

Tudo verde → compatível. Falha em suite → abra o log da suite indicada
pelo runner antes de reinstalar ou mudar config.

## Rollback necessário

- Instalações guardam backup em `.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/`.
- Falha no apply/manifest faz rollback automático: `ROLLBACK_COMPLETED`
  (tudo restaurado) ou `ROLLBACK_REQUIRED` + lista do que **não** restaurou
  (restaure manualmente a partir do backup).
- `CAS_CONFLICT` (exit 4) significa que o destino mudou entre preview e
  apply — **nada foi aplicado**; inspecione, descarte a mudança externa ou
  rode de novo.
- Uninstalls guardam backup em
  `.config/opencode/backups/oo-uninstall-<yyyyMMdd-HHmmss>/`.

## Conflito com config custom

O merge é ownership-aware: o pacote só escreve caminhos do sistema
(`$schema`, `model`, `default_agent`, `subagent_depth`, `agent.*.mode/
model/permission.task`). Nunca tocados: `mcp.*`, `autoupdate`,
`skills.paths`, `plugin`, agents custom, chaves de topo desconhecidas e
tudo fora dos markers do `AGENTS.md`.

Nota sobre jsonc: se o install avisou que normalizou comentários do seu
`opencode.jsonc`, o original byte-exato está no backup em
`.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/` — restaure manualmente
se preferir manter os comentários (o conteúdo funcional é idêntico).

- No install, o `-WhatIf` mostra `PRESERVE` para cada item seu intocado.
- No uninstall, item alterado por você após o install recebe `KEEP` +
  aviso e **não** é removido. Sem manifest, a heurística é conservadora:
  só sai o reconhecido como do pacote.
