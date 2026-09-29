# Instalação

## Pré-requisitos

- **OpenCode V1.x e/ou V2.x** instalado(s) e funcional(is) (`opencode
  --version` responde `1.x` ou `2.x`; CI validado com **1.18.32**, pacote
  npm `opencode-ai`, e **2.0.18**, pacote `@opencode/cli`). Instalação
  single-runtime usa o dialeto do `-Runtime` pedido (Phase 6); `-Runtime
  Both` exige um binário provado por geração ou `-ProvisionRuntime`
  (Phase 7, abaixo).
- **Windows PowerShell 5.1+** ou `pwsh` recente.
- **`bun` ou `npm`** — somente para a dependência do plugin
  `@opencode-ai/plugin@1.18.32` (best-effort: se ambos faltarem ou a rede
  falhar, o instalador avisa e conclui sem ela; instale depois com
  `cd ~/.config/opencode; bun add @opencode-ai/plugin@1.18.32`).
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
| `-Runtime Auto\|V1\|V2\|Both` | Geração alvo. `Auto` (default) faz probe do `opencode` no PATH e falha fechado em ambiguidade; explícito sempre vence. `Both` cria perfis isolados (ver seção abaixo). |
| `-RepoRoot <caminho>` | Instala a partir de outro diretório do pacote. |
| `-TargetHome <perfil>` | Instala em outro perfil (padrão: `$env:USERPROFILE`). |
| `-NoCoreSkills` | Pula as 5 skills-core em `~/.config/opencode/skills/`. |
| `-ProfileRoot`, `-BinaryV1`, `-BinaryV2`, `-ProvisionRuntime` | Controles do caminho `-Runtime Both` (detalhes na seção "Perfis isolados"). |

## O que cada fase faz

1. **Precheck** — valida tudo antes de qualquer escrita: `models.jsonc`
   (3 chaves), fontes obrigatórias (`source/global/AGENTS.md`,
   `source/adapters/opencode.md`, `source/adapters/opencode-v2.md`,
   `scripts/runtime/lib/AgentTranslator.ps1`,
   `templates/opencode.v1.json.tmpl` + `templates/opencode.v2.json.tmpl`
   conforme o runtime resolvido, bundle
   `plugins/dist/orchestration-enforcement.js` + sidecar sha256),
   19 `.md` em `source/agents/`
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
aplicado) · `5` falha no apply/manifest (rollback tentado) · `6`
fail-closed de runtime (Both sem isolamento provado, ou conflito de
runtime no uninstall) · `7` falha de rede no `-ProvisionRuntime`.

## manifest.json (campos)

| Campo | Conteúdo |
|---|---|
| `package_version` | Versão do pacote (ex. `1.1.0`). |
| `installed_at` | Timestamp ISO da instalação. |
| `source_revision` | `git rev-parse --short HEAD` do repo (`unknown` fora de git). |
| `target_home` | Perfil onde instalou. |
| `runtime` | Runtime/gravação instalada (`opencode-v1` ou `opencode-v2`; manifest legado sem esta seção é tratado como v1). |
| `managed_files[]` | `{relative, sha256}` de cada arquivo do pacote. |
| `managed_config_paths[]` | Caminhos gerenciados no config, no dialeto do runtime (V1: `$schema`, `model`, `default_agent`, `subagent_depth`, `agent.*`; V2: `$schema`, `model`, `default_agent`, `experimental.subagent_depth`, `agents.*`). |
| `adopted_paths[]` | Lista legada mantida por compatibilidade (hoje sempre vazia — nenhuma chave é mais adotada). |
| `config_snapshot{}` | Valores canônicos instalados das chaves geridas (para o uninstall comparar). |
| `models{}` | `planner`/`cheap`/`strong` usados. |
| `plugin_dependency` | Spec do runtime instalado (`@opencode-ai/plugin@1.18.32` no V1; `@opencode/plugin@2.0.18` no V2). |

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
.\uninstall.ps1                    # Auto: usa o runtime do manifest
.\uninstall.ps1 -Runtime V2        # exige que o manifest seja V2 (conflito => exit 6)
```

Remove **só** o ownership do pacote: os 19 `agents/*.md`, o bloco markered
do `AGENTS.md` (resto preservado), as chaves managed do `opencode.json`
(no dialeto do runtime do manifest), as skills instaladas, o plugin e o
manifest. Perfis criados por `-Runtime Both` são removidos um a um
(uninstall no home do perfil + `Remove-P7Profile`). Regras:

- Arquivo com hash divergente do manifest (você editou após o install) é
  **mantido** com `KEEP` + aviso — nunca apagado por suposição.
- `mcp.*`, `autoupdate`, `skills.paths`, `plugin`, agents/chaves de topo
  desconhecidas e arquivos seus nunca são tocados (o instalador não os
  escreve; o uninstall nunca os remove).
- `~/.opencode-orchestration/evidence/` (seus dados de telemetria)
  permanece.
- Sem manifest legível, heurística conservadora: só remove o reconhecido
  como do pacote e lista o resto.
- Backup pré-uninstall em `.config/opencode/backups/oo-uninstall-*`.

## Formato de config (json/jsonc)

O instalador respeita `opencode.json` **e** `opencode.jsonc`, com a mesma
precedência do runtime OpenCode V1:

- Só existe `opencode.json` → ele é o alvo.
- Só existe `opencode.jsonc` → ele é o alvo.
- Ambos existem → **só o jsonc é operado** (jsonc vence conflitos, igual ao
  runtime); o `opencode.json` recebe `PRESERVE` no plano.
- Nenhum existe → cria `opencode.json` com as chaves do sistema.

Jsonc com comentários (ou trailing commas) é normalizado para JSON puro na
escrita: o instalador avisa (`AVISO: comentarios do seu opencode.jsonc
foram normalizados`) e o backup byte-exato em
`.config/opencode/backups/oo-<yyyyMMdd-HHmmss>/` preserva o original para
restauração manual.

Skills (`~/.config/opencode/skills`) e plugins
(`~/.config/opencode/plugins`) têm auto-discovery no runtime — por isso o
instalador **não** escreve `skills.paths`, `plugin` nem `autoupdate`
(todas opcionais no schema V1). Você mantém controle total dessas chaves:
o install as preserva, o uninstall nunca as remove.

## Integração opcional: ai-memory

O pacote **não** inclui bloco de memória de longo prazo (integração de
terceiros omitida de propósito). Para continuidade entre sessões, instale o
[ai-memory](https://github.com/akitaonrails/ai-memory) à parte e siga a
documentação oficial dele. Sem memória externa, o sistema trabalha
normalmente com o estado do projeto atual.

## Perfis isolados V1/V2 (Phase 7)

V1 e V2 lado a lado na mesma maquina, isolados por `XDG_CONFIG_HOME` por
processo (ambas as geracoes honram `XDG_CONFIG_HOME` para o config root do
server — prova em `evidence/v3.1/kernel-hardening/runtime-isolation-spike.json`;
o installer re-verifica em runtime com `debug paths`, nunca confia cegamente).

Layout (default `~/.opencode-orchestration/profiles/`):

| Caminho | Conteudo |
|---|---|
| `<profiles>/v1/home/` | `TargetHome` do install V1 (`.config/opencode` + manifest) |
| `<profiles>/v2/home/` | `TargetHome` do install V2 (idem, dialeto nativo) |
| `<profiles>/v1|v2/manifest.json` | manifest do perfil (`profile`, `runtime_id`, `generation`, `config_root`, `runtime_dir`, `provisioned`) |
| `<profiles>/v1|v2/runtime/` | binario provisionado via npm (so com `-ProvisionRuntime`) |
| `<profiles>/bin/opencode-v1.ps1` | wrapper V1 (XDG do perfil, so no processo) |
| `<profiles>/bin/opencode-v2.ps1` | wrapper V2 (idem) |

Comandos:

```powershell
# Perfil individual (offline; usa o PATH quando a geracao bate)
powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v1
powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2

# Com binario provisionado dentro do perfil (requer rede + npm, opt-in)
powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime

# Ambos de uma vez (sem -ProvisionRuntime: prova isolamento ANTES de escrever; com -ProvisionRuntime: perfis provisionados permanecem mesmo se a prova falhar; fail-closed exit 6)
.\install.ps1 -Runtime Both
.\install.ps1 -Runtime Both -ProvisionRuntime
.\install.ps1 -Runtime Both -ProfileRoot "D:\perfis" -BinaryV1 C:\...\opencode.cmd -BinaryV2 D:\...\opencode.cmd

# Uso diario (o wrapper escolhe o binario exato do perfil ou o do PATH
# quando a geracao bate; repassa argumentos e o exit code)
<ProfileRoot>\bin\opencode-v1.ps1 --version
<ProfileRoot>\bin\opencode-v2.ps1 --version
<ProfileRoot>\bin\opencode-v2.ps1 -BinaryPath D:\bin\opencode.cmd --version
```

Override de binário: `new-opencode-profile.ps1 -BinaryPath <bin>` (e as
flags `-BinaryV1`/`-BinaryV2` do `install.ps1 -Runtime Both`) informam um
binário já provado para reusar — validado por geração (`--version`), sem
`npm`, e gravado no `manifest.json` do perfil como
`provisioned = { binary_path, version, provenance = 'override' }`. No
caminho Both sem binários faltantes, o `install.ps1` repassa os candidatos
provados via override para que o wrapper resolva o MESMO binário provado.

Exit codes do Both: `0` ok (isolamento provado) · `6` fail-closed
(`isolation unproven` sem binario para provar, ou `proof-failed`) ·
`7` falha de rede no `-ProvisionRuntime` (opt-in; o perfil de arquivos fica,
sem binario).
Contrato Both: "nada escrito" vale só para o caminho sem provisionamento.
No caminho com `-ProvisionRuntime`, se a prova falhar a saída é exit 6 e
os perfis provisionados PERMANECEM (usáveis pelos wrappers individuais,
removíveis por `Remove-P7Profile`).

Limitacoes:

- So o **config root** (`<XDG>/opencode`) e isolado; `data`/`cache`/`state`
  permanecem por-usuario e nao colidem para config.
- O wrapper nunca persiste env global (USERPROFILE/machine) e nunca
  reescreve o `opencode` global; `-ProvisionRuntime` nunca toca o global.
- V1 nunca aponta para config V2-native (cada perfil instala seu dialeto).
- `install.ps1 -WhatIf -Runtime Both` imprime o plano sem escrever.
- Remover um perfil: `Remove-P7Profile` (uninstall no home do perfil +
  remocao do diretorio); o outro perfil fica intacto.

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
