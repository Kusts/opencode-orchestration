# Permissões dos agentes (P4 — hardening)

Fonte canônica: `source/agents/*.md` (frontmatter `permission:`) + templates por geração
(`templates/opencode.v1.json.tmpl` e `templates/opencode.v2.json.tmpl`, escolhidos pelo
`-Runtime` do instalador). O instalador (`install.ps1`) faz strip do bloco
`orchestration:` e substitui tokens `{{MODEL_*}}`/`{{REPO_DIR}}`/`{{HOME}}`; mapas `bash:`
sobrevivem intactos. Permissões `bash:`/`shell` vivem nos `.md`/template, não só no
`opencode.json`.

## Tabela 19 agentes × classe × barreira

| Agente | Classe | edit | bash | Barreira |
|---|---|---|---|---|
| explorer | read-only | deny | deny | runtime-enforced + prompt-enforced |
| researcher | read-only | deny | deny | runtime-enforced + prompt-enforced |
| reviewer | read-only | deny | deny | runtime-enforced + prompt-enforced |
| architect | read-only | deny | deny | runtime-enforced + prompt-enforced |
| security-reviewer | read-only | deny | deny | runtime-enforced + prompt-enforced |
| requirements-analyst | read-only | deny | deny | runtime-enforced + prompt-enforced |
| engineering-advisor | read-only | deny | deny | runtime-enforced + prompt-enforced |
| product-designer | read-only | deny | deny | runtime-enforced + prompt-enforced |
| skeptic | read-only | deny | deny | runtime-enforced + prompt-enforced |
| coder | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| frontend-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| backend-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| database-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| ai-agent-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| automation-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| infra-engineer | writer-shell | allow | allow-default + denies/`ask` | runtime-enforced + planner-enforced |
| docs-manager | writer-no-shell | allow | deny | runtime-enforced + prompt-enforced |
| tester | diagnostic | deny | deny-default + allowlist de teste/leitura | runtime-enforced + planner-enforced |
| debugger | diagnostic | deny | deny-default + allowlist de diagnóstico | runtime-enforced + planner-enforced |

Classes: **read-only** = sem escrita, sem shell; **writer-shell** = edita + shell amplo com
negações/confirmações pontuais; **writer-no-shell** = edita, sem shell; **diagnostic** =
sem escrita + shell restrito a allowlist explícita.

Barreiras: **runtime-enforced** = aplicado pelo runtime (`edit`, mapas `bash:`,
`subagent_depth: 1` + `permission.task: deny` no `opencode.json` — hierarquia rasa, workers
não delegam); **prompt-enforced** = instrução no corpo do agente (ex.: tester nunca usa
shell para editar; seletividade do docs-manager; triggers do planning layer); **planner-enforced**
= campos do Dispatch Contract (`ALLOWED_ENVIRONMENT`, `PRODUCTION_AUTHORIZED`,
`CREDENTIAL_SCOPE`, `PROHIBITED_OPERATIONS` concretas) + confirmação separada do Planner
para ações destrutivas irreversíveis e criação/revogação/rotação de credenciais.

## V2 — dialeto nativo (V3.1)

O mesmo frontmatter canônico dos 19 agentes produz o shape nativo V2 via
`scripts/runtime/lib/AgentTranslator.ps1` (determinístico, fail-closed):

| Conceito | V1 | V2 |
|---|---|---|
| Mapa de agentes | `agent` | `agents` |
| Permissões por agente | `permission` | `permissions` (array de regras ordenadas) |
| Ação shell | `bash` | `shell` |
| Ação subagente | `task` | `subagent` |
| Profundidade de subagente | `subagent_depth` | `experimental.subagent_depth` |

Regras da tradução:

- `edit→edit`, `bash→shell`, `task→subagent`; `allow`/`ask`/`deny`
  preservados — **nenhuma regra é ampliada** (nunca `deny`→`ask`/`allow`)
  para compatibilidade.
- A ordem de regras V2 é **security-sensitive**: em V2 vence a **última**
  regra que casa (last-match-wins), então a tradução emite broad-first
  (deny geral primeiro, allows estreitos depois). Validado pelo check 13 de
  consistência.
- Paridade semântica V1↔V2 (mesmos 19 allows, mesmos pools de modelo,
  workers sem subdelegação, `default_agent`/`build`/`title` iguais) é
  validada pelo check 14.
- Padrão ambíguo (sobreposição de regras sem precedência clara) quebra o
  build com `ambiguous-permission-overlap` — nada é renderizado por
  suposição.

Status de enforcement (honesto): as permissões V2 nativas são renderizadas,
instaladas (dialeto `agents`/`permissions`) e validadas por shape, ordem e
paridade. A camada `experimental.policies` (hard-deny global) e a validação
de enforcement contra o runtime V2 real **ainda não foram implementadas**
(Phase 5 do plano V3.1 pendente) — hoje não existe hard-deny além das
permissões nativas, e nenhum claim de enforcement V2 vai além do que os
checks cobrem.

## Limitações declaradas (sem capacidades inventadas)

- Globs `bash:` são **matching de string** sobre o texto do comando. Não inspecionam
  conteúdo de scripts, aliases, nem wrappers como `pwsh -Command ...` / `bash -c ...`.
  Contenção real dessas rotas é planner-enforced (contrato + ownership), não do glob.
- `ask` é **controle de confirmação, não bloqueio incondicional**: no modo auto do
  runtime ele é auto-aprovado. `deny` é o único bloqueio no mapa.
- `tester` mantém **allowlist ampla nesta fase** (`npm *`, `npx *`, `bun *`,
  `python -m *` etc.) — revisão futura registrada; não confundir amplitude com
  permissão de escrita (`edit: deny` permanece).
- `read-only` depende de **`bash: deny` no runtime + prompt**. Sem shell, a barreira é
  total no runtime; o prompt cobre o que o runtime não vê (ex.: instruções via contrato).
- `PRODUCTION_AUTHORIZED` ausente equivale a `false`, e `true` **não autoriza por si só**
  ações destrutivas irreversíveis nem operações com credenciais — essas exigem
  confirmação separada do Planner. `CREDENTIAL_SCOPE` carrega apenas
  identificadores/perfis, nunca valores de segredos.
- O worker **não amplia** `ALLOWED_ENVIRONMENT` / `PRODUCTION_AUTHORIZED` /
  `CREDENTIAL_SCOPE` por inferência de papel, aprovação `ask` ou credenciais
  disponíveis; diante de operação não coberta, interrompe e devolve ao Planner.
- Nenhuma capacidade nova é criada por este documento: ele descreve o que está nos
  frontmatters, no template e no Dispatch Contract.
