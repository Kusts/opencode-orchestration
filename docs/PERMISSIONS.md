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
| tester | validator-shell | deny | allow-default + denies destrutivos/elevação/git/deploy | runtime-enforced (edit + denies nomeados) + prompt/planner-enforced (escrita via shell não-listada) |
| debugger | diagnostic | deny | deny-default + allowlist de diagnóstico | runtime-enforced + planner-enforced |

Classes: **read-only** = sem escrita, sem shell; **writer-shell** = edita + shell amplo com
negações/confirmações pontuais; **writer-no-shell** = edita, sem shell; **diagnostic** =
sem escrita + shell restrito a allowlist explícita; **validator-shell** = ferramenta de
edição bloqueada (`edit: deny`) + shell allow-default com negações destrutivas (tester) —
escrita via shell não coberta por negações é proibição comportamental
(prompt/planner-enforced), não barreira de runtime.

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

### Camadas de enforcement (matriz)

| Camada | Status |
|---|---|
| Permissões V1 | runtime-enforced (templates + testes do instalador + smoke CI 1.18.x) |
| Permissões V2 | renderizado + validado por checks (consistency 12–15); claim de enforcement aguarda spike V2 real (Phase 5) |
| Policies V2 (`experimental.policies`) | HOLD (Phase 5); nenhum hard-deny enviado |
| Hooks do plugin V1 | runtime-enforced (provado em 1.18.x, testes do plugin) |
| Hooks do plugin V2 | implementado com testes mock; claim live pendente da lane CI V2 (Phase 8) |
| Kernel (CAS/gate/DONE/grants/leases/worktrees) | kernel-enforced; flags OFF por padrão até ativação com evidência (Phase 19) |

Matriz viva em `evidence/v3.1/kernel-hardening/runtime-binding.json` — nenhum
claim além do testado.

## Limitações declaradas (sem capacidades inventadas)

- Globs `bash:` são **matching de string** sobre o texto do comando. Não inspecionam
  conteúdo de scripts, aliases, nem wrappers como `pwsh -Command ...` / `bash -c ...`.
  Contenção real dessas rotas é planner-enforced (contrato + ownership), não do glob.
- `ask` é **controle de confirmação, não bloqueio incondicional**: no modo auto do
  runtime ele é auto-aprovado. `deny` é o único bloqueio no mapa.
- `tester` usa **shell allow-default** (`"*": allow`) com denies de destruição
  (`rm`, `del`, `erase`, `rd`, `rmdir`, `ri`, `Remove-Item`, `truncate`, `shred`,
  `dd`, `format`), elevação (`sudo`, `su`, `runas`, `gsudo`, `doas`), mutação
  Git (`push`, `reset`, `clean`, `rebase`, `merge`, `commit`, `branch -D`),
  `dropdb`/`terraform destroy`/`kubectl delete` e `ask` para deploy/publish/infra
  (modelo validator-shell). A política de não editar é dupla e honesta:
  runtime-enforced para a ferramenta de edição (`edit: deny`) e para as
  rotas de shell nomeadas acima; escrita via shell não coberta por negações
  (`Set-Content`, `Out-File`, redirecionamento, `Copy-Item`, git não-listado)
  é proibição comportamental — prompt-enforced (corpo do agente) +
  planner-enforced (contrato), não barreira de glob.
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
- Para o Tester, `Permission denied` de rota destrutiva/elevação encerra a
  rota: sem reformulação por outro shell, wrapper, interpretador ou elevação
  que produza o mesmo efeito; o corpo define o blocker estruturado
  `VALIDATION_CAPABILITY_UNAVAILABLE`. O matcher é string-matching: conteúdo
  dentro de wrappers não é contido pelo glob (asserção honesta na suíte
  `tester-shell-permissions.tests.ps1`). Sem mudança em parser/allowlist do
  runtime — o contrato é o frontmatter canônico + corpo do agente.

## Camada kernel-enforced (V3.1)

Acima das barreiras por runtime/contrato, o Task Kernel (`scripts/v3/task-kernel.ps1`;
núcleo em `scripts/v3/lib/OrchestrationTaskKernel.ps1`) aplica autoridade
determinística, idêntica em V1 e V2:

- **Grants por interseção**: autoridade efetiva = baseline do papel ∩ grants da
  task ∩ capacidade do runtime ∩ autorização de ambiente ∩ aprovação humana
  quando exigida (`source/registry/execution-grants.json`). Nunca união; grants
  sensíveis (`destructive.fs`, `deploy.production`, `secrets.read`, `git.push`)
  não estão em nenhum baseline e exigem grant explícito + aprovação.
- **Evidence Contract**: workers emitem SOMENTE `candidate_pass`/`failed`/`blocked`;
  `verified_pass` vem do verificador (`Set-OrchestrationTaskVerification`,
  allowlist em `source/registry/verification-policy.json`) e `DONE` só do kernel
  (`Complete-OrchestrationTask`, após `Test-OrchestrationTaskCompletion`).
- **Leases/worktrees**: escrita concorrente exige lease (`cache/runtime/locks`);
  writers paralelos exigem worktrees isoladas com cleanup ownership-aware.
- **Flags**: `task_kernel`/`worktree_isolation`/`runtime_grant_enforcement`
  iniciam OFF (shadow rollout, Phase 19) — enforcement de kernel torna-se
  obrigatório somente após ativação com evidência. Estado vivo em
  `evidence/v3.1/kernel-hardening/runtime-binding.json`.

## Status V2 — spike e HOLDs (2026-09-29; revisado em 2026-10-03)

Harness: `scripts/runtime/spike-v2-permissions.ps1` (resolve binário V2 via
`-BinaryPath` → manifest do perfil v2 → probe PATH 2.x; sem binário, registra
`skipped` e sai 0). Evidência: `evidence/v3.1/kernel-hardening/v2-permissions-spike.json`.
Checks automatizados correspondem 1:1 a comandos executados (`--version`,
`debug paths`, `debug config`, `debug agent`); enforcement comportamental
(agente live tentando operação negada) fica como `manual_checklist_pending`
— nenhum claim de enforcement V2 vai além do observado.

HOLDs honestos (sem teste no runtime exato, sem claim): hard-deny via
`experimental.policies`, live-load do plugin V2 em CI e ativação do
`runtime_grant_enforcement`. O enforcement comportamental V2 (Phase 5)
segue pendente do runtime real.

**Camadas de permissão entregues, ainda sem enforcement ativo
(2026-10-02/03).** O programa de confiabilidade entregou envelopes
kernel-side de contenção de autoridade — MCP safety envelope com guard
de autoridade sempre-nega e `MCP_REQUIRED_BLOCKED` fail-closed (P28),
Jev como advisory com authority guard sempre-nega que nunca concede nem
transporta grants (P29) e gating data-driven de capacidades nativas do
V2, cujas 8 features estão todas `hold-unproven` e só podem ser
habilitadas com evidência `exact-binary-live` validada (P40). Isso
**não** é enforcement de permissão no runtime: `mcp_routing`,
`jev_advisory` e o gating V2 seguem desligados
(`source/registry/capability-flags.json`), o transporte MCP no plugin é
shadow por default e qualquer ativação é decisão humana com evidência.

**Mudança de 2026-10-03 (decisão do operador).** As permissões do agente
`tester` trocaram o deny-default + allowlist fechada por shell amplo
(`"*": allow`) com negações explícitas para operações destrutivas,
elevação e mutação Git, `ask` para deploy/publish/infra e
`edit: deny`/`task: deny` mantidos — ver o bullet correspondente em
`CHANGELOG.md` `[Unreleased]` e a suíte
`scripts/runtime/tester-shell-permissions.tests.ps1`. Escrita via shell
não listada continua sendo proibição comportamental (prompt/Planner),
não barreira de runtime.
