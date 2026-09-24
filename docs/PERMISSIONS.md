# Permissões dos agentes (P4 — hardening)

Fonte canônica: `source/agents/*.md` (frontmatter `permission:`) + `templates/opencode.json.tmpl`
(`mode`/`model`/`permission.task`). O instalador (`install.ps1`) faz strip do bloco
`orchestration:` e substitui tokens `{{MODEL_*}}`/`{{REPO_DIR}}`/`{{HOME}}`; mapas `bash:`
sobrevivem intactos. Permissões `bash:` vivem nos `.md`, não no `opencode.json`.

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
