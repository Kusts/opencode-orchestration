# Instalação

## Pré-requisitos

- **OpenCode** instalado e funcional (`opencode --version` responde).
- **Windows PowerShell 5.1+** ou `pwsh` recente.
- **`bun` ou `npm`** — somente para a dependência do plugin
  `@opencode-ai/plugin@1.18.31` (best-effort: se ambos faltarem ou a rede
  falhar, o instalador avisa e conclui sem ela; instale depois com
  `cd ~/.config/opencode; bun add @opencode-ai/plugin@1.18.31`).
- Este repo clonado + `models.jsonc` criado (copiado de
  `models.example.jsonc`, com `planner`/`cheap`/`strong` preenchidos).
  Sem `models.jsonc` válido o instalador falha no precheck (exit 3) sem
  escrever nada. `models.jsonc` está no `.gitignore`.

## Passo a passo

```powershell
git clone <este-repo>
cd opencode-orchestration
copy models.example.jsonc models.jsonc
# edite models.jsonc com seus modelos
.\install.ps1 -WhatIf     # plano por recurso, nenhuma escrita
.\install.ps1             # instalação real
```

Flags reais do `install.ps1`:

| Flag | Efeito |
|---|---|
| `-WhatIf` | Imprime o plano (`CREATE`/`UPDATE`/`SKIP`/`PRESERVE` por recurso) e sai sem escrever. |
| `-RepoRoot <caminho>` | Instala a partir de outro diretório do pacote. |
| `-TargetHome <perfil>` | Instala em outro perfil (padrão: `$env:USERPROFILE`). |
| `-NoCoreSkills` | Pula as 5 skills-core em `~/.config/opencode/skills/`. |

## O que cada fase faz

1. **Precheck** — valida tudo antes de qualquer escrita: `models.jsonc`
   (3 chaves), fontes obrigatórias (`source/global/AGENTS.md`,
   `source/adapters/opencode.md`, `templates/opencode.json.tmpl`,
   `plugins/orchestration-enforcement.ts`), 19 `.md` em `source/agents/`
   com frontmatter/model-token válidos, template resolvido (17 blocos
   `agent`, `build` sem `model`, zero tokens pendentes), plugin e skills.
   Falha → exit 3, **nada escrito**.
2. **Stage** — monta o resultado em diretório temporário e valida:
   `opencode.json` parseia, nenhum token `{{...}}` restante, markers do
   `AGENTS.md` exatamente 1 par. Stage inválido → exit 5.
3. **CAS** — compara o hash atual de cada destino com o hash do preview;
   se algo mudou no meio tempo → `CAS_CONFLICT`, exit 4, **nada aplicado,
   sem rollback** (nada foi tocado).
4. **Apply** — escrita atômica arquivo a arquivo (`.tmp` + verificação de
   hash pós-escrita). Falha no meio → rollback a partir do backup, exit 5
   (`ROLLBACK_COMPLETED` ou `ROLLBACK_REQUIRED` + lista do que não
   restaurou).
5. **Rollback** — restaura backups na ordem reversa; arquivos novos do
   pacote são removidos. Manifest entra na transação: falha ao gravá-lo
   também dispara rollback completo.
6. **Manifest** — grava `~/.opencode-orchestration/manifest.json` e só
   então instala a dependência do plugin (best-effort, fora da transação).

Exit codes: `0` ok · `3` precheck (nada escrito) · `4` CAS_CONFLICT (nada
aplicado) · `5` falha no apply/manifest (rollback tentado).

## manifest.json (campos)

| Campo | Conteúdo |
|---|---|
| `package_version` | Versão do pacote (ex. `1.0.0-hardening`). |
| `installed_at` | Timestamp ISO da instalação. |
| `source_revision` | `git rev-parse --short HEAD` do repo (`unknown` fora de git). |
| `target_home` | Perfil onde instalou. |
| `managed_files[]` | `{relative, sha256}` de cada arquivo do pacote. |
| `managed_config_paths[]` | Caminhos gerenciados no `opencode.json`. |
| `adopted_paths[]` | Chaves adotadas por estarem ausentes (`skills.paths`, `autoupdate`, `plugin`). |
| `config_snapshot{}` | Valores canônicos instalados (para o uninstall comparar). |
| `models{}` | `planner`/`cheap`/`strong` usados. |
| `plugin_dependency` | Spec fixada (`@opencode-ai/plugin@1.18.31`). |

## Upgrade

```powershell
git pull
.\install.ps1 -WhatIf
.\install.ps1
```

Idempotente: rodar duas vezes não duplica nem quebra (`SKIP` no que está
inalterado). Ownership-aware: o merge só toca caminhos do pacote; o que é
seu permanece. Para trocar modelos, edite `models.jsonc` e reinstale.

## Uninstall

```powershell
.\uninstall.ps1 -WhatIf
.\uninstall.ps1
```

Remove **só** o ownership do pacote: os 19 `agents/*.md`, o bloco markered
do `AGENTS.md` (resto preservado), as chaves managed do `opencode.json`,
as skills instaladas, o plugin e o manifest. Regras:

- Arquivo com hash divergente do manifest (você editou após o install) é
  **mantido** com `KEEP` + aviso — nunca apagado por suposição.
- `mcp.*`, agents/chaves de topo desconhecidas e `plugin` com conteúdo seu
  nunca são tocados.
- `~/.opencode-orchestration/evidence/` (seus dados de telemetria)
  permanece.
- Sem manifest legível, heurística conservadora: só remove o reconhecido
  como do pacote e lista o resto.
- Backup pré-uninstall em `.config/opencode/backups/oo-uninstall-*`.

## Integração opcional: ai-memory

O pacote **não** inclui bloco de memória de longo prazo (integração de
terceiros omitida de propósito). Para continuidade entre sessões, instale o
[ai-memory](https://github.com/akitaonrails/ai-memory) à parte e siga a
documentação oficial dele. Sem memória externa, o sistema trabalha
normalmente com o estado do projeto atual.

## Fluxo opt-in do registry V3

A registry derivada é opcional. Para gerar:

```powershell
powershell -NoProfile -File scripts\v3\build-capability-registry.ps1 -Preview
powershell -NoProfile -File scripts\v3\build-capability-registry.ps1
```

Lê `source/agents/*.md` + `source/registry/capability-policy.json` e
escreve o registry em `cache/v3/` (`capability-registry.json`, ignorado pelo
git; nunca toca alvos live). Sem esse cache, roteamento usa fallback determinístico.
Flags em `source/registry/capability-flags.json` nascem todas `false`.
