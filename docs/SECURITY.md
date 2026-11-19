# Segurança

## Permission boundaries

Classes e barreiras por agente (tabela 19 agentes × classe × barreira) são
normativas em [PERMISSIONS.md](PERMISSIONS.md). Resumo:

- **Todos os workers** têm shell irrestrito (`bash: "*": allow`), sem regras
  específicas `deny` ou `ask`, conforme decisão explícita do usuário.
- **Limite de edição por papel**: oito implementadores mantêm `edit: allow`;
  os outros onze mantêm `edit: deny`. Para papéis read-only, isso bloqueia a
  ferramenta de edição, mas não contém escrita feita via shell.
- `task: deny` e `subagent: * deny` nos workers permanecem como limite de
  hierarquia rasa.
- Barreiras: **runtime-enforced** (`edit`, `subagent_depth: 1`,
  `permission.task: deny` — workers não delegam),
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
- Regras anteriores de allowlist, `deny` e `ask` de shell foram removidas por
  decisão explícita do usuário. Instruções de papel e contratos continuam
  orientando o comportamento, mas não são barreiras técnicas de shell.

## Canários sintéticos

Os `*.tests.ps1` e `tests/distribution/` contêm **canários sintéticos**
(ex. `sk-SYNTHETICSECRET`, `ghp_EVALCANARY`) como fixtures para testar
sanitização. Não são segredos reais — mantenha-os como estão e nunca os
troque por valores verdadeiros.
