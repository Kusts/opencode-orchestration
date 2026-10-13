# Contrato planning + discovery V2 (Fase 2A, fatia 1)

Nota de escopo: este documento **descreve** contratos existentes; ele não
altera nenhum template, agent ou flag. Em divergência, `source/` vence
(ver [ARCHITECTURE.md](ARCHITECTURE.md)). Validação viva em
`scripts/test-package-consistency.ps1` (checks 3/11/12/13/14) e na suite
`tests/distribution/capability-planning.tests.ps1`.

## 1. Contrato canônico planning (21 + 19 + 19)

O inventário canônico de agentes é:

- **21 blocos** em `templates/opencode.v2.json.tmpl` sob `agents`:
  `build` + `title` + 19 workers com bloco próprio (15 de execução +
  4 de planning).
- **19 arquivos** em `source/agents/*.md` (um por worker delegável).
- **19 allows** na allowlist do `build`
  (`agents.build.permissions`: 1 × `{subagent, *: deny}` broad-first + 19
  × `allow` estreitos — check 13 de `scripts/test-package-consistency.ps1`).

Os 4 papéis de planning — `requirements-analyst`,
`engineering-advisor`, `product-designer`, `skeptic` — são **allowlisted +
com bloco cheap**: existem como `.md` em `source/agents/`, como `allow` na
allowlist do `build` e como bloco `agents.<nome>` no template V2
(`mode: subagent`, `model: {{MODEL_CHEAP}}`, sem delegação própria).
Eles são despachados pelo Planner como `subagent` via `build` (advisory,
read-only), com delegação nativa no JSON gerenciado.

### Por que 17 blocos ficou obsoleto

O contrato anterior (17 blocos: `build` + `title` + 15 workers, planning
file-based sem bloco) impedia delegação nativa V2 dos papéis advisory:
todo `allow` do `build` deve ter bloco `agents.*` correspondente. Manter
17 blocos com 19 allows quebraria:

- **preflight de delegação V2**
  (`tests/distribution/v2-delegation-preflight.tests.ps1`): exige 21
  blocos e todo `allow` com bloco `agents.*`;
- **check 12** (`template V2 shape nativo`): exige exatamente 21 blocos
  `agents`;
- **precheck do `install.ps1`** (`Validate-TemplateV2`): exige template
  resolvido com 21 blocos `agents`, `build` sem `model` e zero tokens
  pendentes (ver [INSTALLATION.md](INSTALLATION.md), fase Precheck).

O V1 permanece com 17 blocos `agent` (checks 3/11 + precheck
`Validate-Template` inalterados): os 4 planning seguem file-based no
dialeto legado. A paridade V2↔V1 (check 14) compara allowlists (19 = 19)
e os 15 workers comuns; os 4 blocos de planning são adição V2-only.

## 2. Plugin discovery global no V2 (sem `plugins[]`)

Fonte: <https://opencode.ai/v2/docs/plugins> (seções Configure/Discover).

O V2 carrega plugins por dois mecanismos independentes:

1. **Declarado**: array `plugins` em `opencode.json(c)` (pacotes npm,
   paths locais, `file:`) — mesclado por precedência entre configs,
   nunca substituído.
2. **Discovery**: arquivos diretos `.ts`/`.js` (e diretórios imediatos
   de pacote) em todo diretório `.opencode/plugins/` descoberto; os
   **plugins globais usam o mesmo layout sob `~/.config/opencode/plugins/`**
   — nenhum `plugins[]` precisa citá-los para carregarem.

Por isso o template V2 gerenciado **não contém chave `plugin`/`plugins`**
(check 12 proíbe chaves legadas/estranhas no topo): o instalador posiciona
arquivos (bundle em `plugins/dist/`, instalado no perfil do usuário) e o
runtime descobre; entradas `plugins[]` user-owned permanecem fora do
merge gerenciado (preservadas, nunca escritas nem removidas — ver seção
Ownership em [ARCHITECTURE.md](ARCHITECTURE.md)).

## 3. Skills precedence no V2 (later-wins)

Fonte: <https://opencode.ai/v2/docs/skills> (seções Discovery/Sources/
Precedence).

Skills resolvem por **ID** (derivado do path, case-sensitive); em
duplicata, **a fonte registrada por último vence** (later-wins). Ordem de
registro, da menor para a maior precedência:

1. built-in;
2. `.claude/skills` (global → ancestral mais distante → cwd);
3. `.agents/skills` (idem);
4. **`~/.config/opencode/skills`**;
5. `.opencode/skills` de projeto (root → cwd);
6. entradas explícitas `skills[]` (ordem de precedência de config + array).

Consequência operacional: **`~/.config/opencode/skills` vence
`~/.agents/skills`** (item 4 registrado depois do item 3). As 5
skills-core do pacote são instaladas em `~/.config/opencode/skills/`
(ver [INSTALLATION.md](INSTALLATION.md)); um override intencional deve
usar um ID duplicado numa fonte posterior (projeto ou `skills[]`), nunca
editar o arquivo instalado — o uninstall/manifest compara por hash
(`KEEP` + aviso em divergência).

## 4. `OPENCODE_CONFIG_CONTENT`: unsupported/unproven no V2 gerenciado

Status neste pacote: **unsupported e unproven**. O instalador e as
verificações operam sobre **arquivos em disco** (`opencode.json/jsonc`
no config root do perfil, manifest com hashes, CAS pré-apply). Um
override via variável de ambiente, se existir no runtime, é invisível
para esse caminho: hashes conferem, mas o comportamento efetivo pode
divergir do verificado.

**Detecção** (regra de package policy, não claim de runtime): antes de
qualquer verificação que ateste "config gerenciado íntegro", checar
`$env:OPENCODE_CONFIG_CONTENT`. Se **não-vazio**, o resultado máximo
honesto é `unproven/blocked` — registrar `config_source=env-override`,
não atestar integridade, e devolver ao operador (qual entrada prevalece
é decisão do runtime real, fora do escopo verificado aqui). Com a
variável **ausente/vazia**, vale o caminho normal em disco
(manifest + CAS + checks 11–15).
