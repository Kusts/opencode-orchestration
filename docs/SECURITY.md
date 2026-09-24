# Segurança

## Permission boundaries

Classes e barreiras por agente (tabela 19 agentes × classe × barreira) são
normativas em [PERMISSIONS.md](PERMISSIONS.md). Resumo:

- **read-only** (explorer, researcher, reviewer, architect,
  security-reviewer + 4 advisors de planning): `edit: deny`, `bash: deny` —
  sem escrita, sem shell.
- **writer-shell** (coder + 6 engineers): edita, shell amplo com
  negações/`ask` pontuais.
- **writer-no-shell** (docs-manager): edita, sem shell.
- **diagnostic** (tester, debugger): sem escrita, shell restrito a
  allowlist explícita de teste/diagnóstico.
- Barreiras: **runtime-enforced** (`edit`, mapas `bash:`,
  `subagent_depth: 1`, `permission.task: deny` — workers não delegam),
  **prompt-enforced** (instruções no corpo do agente) e
  **planner-enforced** (Dispatch Contract + confirmação separada do Planner
  para destruição irreversível e credenciais).

## Credenciais

- O repo contém só **nomes** de chaves, propósito e consumidores — **nunca
  valores**. `models.jsonc` tem só nomes de modelos (e é gitignored).
- Segredos nunca entram em git, instruções geradas, logs, relatórios,
  backups plaintext ou telemetria.
- Em uso, credenciais vêm do **ambiente do runtime** (variáveis de
  ambiente). Perfis externos de launcher são opcionais/legado: sem eles,
  nada quebra.
- `CREDENTIAL_SCOPE` no Dispatch Contract carrega só
  identificadores/perfis, nunca valores. O worker nunca amplia escopo por
  inferência; criação/revogação/rotação de credenciais exige confirmação
  separada do Planner.

## Regras de produção

- `PRODUCTION_AUTHORIZED` ausente equivale a `false`.
- `true` autoriza **só** aquele ambiente nomeado — e **não** autoriza por si
  só ações destrutivas irreversíveis nem operações com credenciais (essas
  exigem confirmação separada).
- Expansão material de escopo, pagamento/compra/assinatura e comunicação
  externa como o usuário também exigem confirmação (`source/policies/AUTONOMY.md`,
  `source/policies/CREDENTIALS.md`).

## Telemetria local

O plugin grava em `~/.opencode-orchestration/evidence/v3/orchestration/session-injections.jsonl`
(uma linha por sessão/marker):

- **Grava**: timestamp, tipo de sessão (`planner`/`worker`/`unknown`),
  tipo de mandato, marker usado, e — só se em charset seguro e ≤64 chars
  — nome do agente e id da sessão.
- **NUNCA grava**: conteúdo de mensagens, arquivos, segredos, histórico ou
  dumps. Sanitização remove segredos e limita tamanho; falha de telemetria
  nunca quebra a sessão (fail-open).

Decisões de preflight/roteamento geram evidência em
`evidence/v3/orchestration/` e `cache/v3/telemetry/` com o mesmo princípio
(ids canônicos, hashes, enums — sem texto livre nem segredos).

## Arquivos locais criados

| Caminho | O quê |
|---|---|
| `~/.config/opencode/` | `AGENTS.md` (bloco markered), `agents/`, `plugins/`, `skills/`, `opencode.json` (merge), `backups/oo-*` |
| `~/.opencode-orchestration/` | `manifest.json` (ownership), `evidence/` (telemetria — **seus dados**, o uninstall preserva) |
| `<repo>/cache/` | Registry derivada opt-in (criada sob demanda; gitignored) |
| Saída do render | Preview em `generated/` (criado sob demanda pelo script; gitignored, nunca ativo por si só) |

## Limitações conhecidas do runtime

- **Hook sem identidade de agente → mandato neutro**: o plugin sonda o
  campo de agente no input do hook; ausente ou irreconhecível, injeta o
  mandato neutro conservador (nunca adivinha um papel).
- **`ask` é confirmação, não bloqueio**: no modo auto do runtime ele é
  auto-aprovado; só `deny` bloqueia de verdade.
- **Globs `bash:` são matching de string** sobre o texto do comando — não
  inspecionam conteúdo de scripts, aliases nem wrappers (`pwsh -Command
  ...`, `bash -c ...`). A contenção dessas rotas é planner-enforced.
- **`tester` tem allowlist ampla** (`npm *`, `npx *` etc.) — amplitude de
  leitura/execução de teste, não permissão de escrita (`edit: deny`
  permanece).

## Canários sintéticos

Os `*.tests.ps1` e `tests/distribution/` contêm **canários sintéticos**
(ex. `sk-SYNTHETICSECRET`, `ghp_EVALCANARY`) como fixtures para testar
sanitização. Não são segredos reais — mantenha-os como estão e nunca os
troque por valores verdadeiros.
