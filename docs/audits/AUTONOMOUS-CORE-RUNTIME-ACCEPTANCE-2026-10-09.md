# AUTONOMOUS CORE — Runtime Acceptance Report (2026-10-09)

**Branch:** `acceptance/autonomous-core-v0.1.2-2026-10-09`
**Baseline HEAD:** `b38c92bc8b3ab334a9dffad609f3515350336061` (merge do PR #47)
**Veredito:** **PARTIAL CLOSURE** — não FINAL READY, não BLOCKED (§13)
**Natureza deste documento:** auditoria de aceitação, documentation-only. Nenhum
código, script, flag, registry, CI, VERSION, CHANGELOG ou evidence JSON foi
alterado; nenhuma issue/PR/commit/push foi feito. Mudanças user-owned pré-existentes
(`source/adapters/opencode.md`, `source/adapters/opencode-v2.md` — linha de fallback
do cheap pool) foram **preservadas intactas**.

Distinção usada em todo o texto: **evidência do checkout atual** (git, greps na
árvore, `VERSION`, registry) vs. **metadado de corrida histórica** (CI no GitHub,
diretórios de lane datados, `program-status.json`).

---

## 1. Baseline e versionamento

- HEAD atual `b38c92bc8b3ab334a9dffad609f3515350336061` — confere com o
  `mergeCommit` do **PR #47** (`feat(closure): Native Worker Dispatch bridge +
  Autonomous Continuation + evidence store unificado (v0.1.2, PARTIAL)`),
  estado **MERGED** em `2026-10-09T06:24:43Z` (metadado GitHub).
- Tag **`v0.1.2`** existe no checkout; `VERSION` = `0.1.2` (checkout atual).
- Working tree **antes** das alterações documentais desta branch: apenas as 2
  modificações user-owned dos adaptadores
  (fallback `muse-spark-1.3-contributor` → `step-5-preview-free`), fora do
  escopo desta auditoria e intocadas.

## 2. Runtime e provider

- OpenCode instalado no host: **`2.0.26`** (verificado via `opencode --version`).
- Pins do projeto (`source/registry/runtime-versions.json`, checkout atual):
  **V1 `1.18.34`**, **V2 `2.0.23`** (plugin pins idênticos; bun `1.3.14`).
  Atenção: o host **não** é o runtime pinado — as lanes usam o binário do pin.
- Configuração instalada (leitura filtrada, sem credenciais): `default_agent=build`,
  modelo global `opencode-go/muse-spark-1.3-contributor`,
  `experimental.subagent_depth=1`; os agentes `explorer`, `coder`, `tester`,
  `reviewer`, `security-reviewer` e `debugger` estão declarados. O modelo efetivo
  do Planner desta sessão foi `openai/gpt-6-luna` (override de sessão).
  `orchestration-enforcement.js` existe no diretório global
  `~/.config/opencode/plugins/` (autodiscovery); o checkout não contém
  `.opencode/plugins/`. Presença/descoberta não prova que o hook produziu efeito
  nesta sessão; não foi usado como prova de dispatch.
- Sessões desta auditoria (metadado de sessão OpenCode, fornecido pelo Planner;
  provam uso real de sessão/subagente **somente para esta auditoria**):
  - Planner: `ses_ee03e0dd0ffeLPJGqG7Rp7OwTu` — agent `build`, provider
    `openai`, model `gpt-6-luna/high`.
  - Explorer (filho real): `ses_ee03dab99ffe1ra5EL5fHqqUlw` — agent `explorer`,
    provider `opencode-go`, model `step-5-preview-free`, parent = sessão Planner acima.
  - Security Reviewer (filho real): `ses_ee0337173ffeDfXBUAnsdfkO4s` —
    provider `openai`, model `gpt-6.1-sol`.
  - Debugger (filho real): `ses_ee030c1eeffeSZTaVVzMFgGHo1` — model **não
    registrado aqui** (não inferido).
- Custos reportados `0` vêm **apenas** de metadado de sessão do OpenCode; não
  implicam custo de billing do provider.
- Estas sessões **não** são: fixture de Objective, dispatch intent, settlement do
  Task Kernel, auto-avanço de fase, nem consumo por Planner substituto.

## 3. Fixture Objective e protocolo

- A **fixture isolada de Objective de 3 fases** solicitada **NÃO foi executada**.
  Motivo factual: nenhum caminho do repositório invoca o loop autônomo existente
  (§5) — a única fixture que "itera" é `scripts/ci/ObjectiveRunner.harness.ps1`,
  explicitamente `TEST HARNESS — NOT PRODUCT`. Nenhuma fixture foi fabricada
  para preencher a lacuna.

## 4. Evidência de subagentes reais

- Subagentes reais usados nesta auditoria: Explorer, Security Reviewer e
  Debugger (sessões filhas em §2), despachados pelo Planner dentro da sessão
  ativa via ferramenta de delegação do harness OpenCode. `session export`
  confirma sessões filhas reais com `parentID`, agent e provider; não foi
  capturado um evento de chamada da ferramenta runtime `task/subagent`. Isso
  evidencia execução de workers **no nível desta sessão de auditoria**, não o
  wiring produtivo do produto (§5–§6).

## 5. Achado arquitetural (call graph atual, checkout `b38c92b`)

Evidência por grep na árvore atual:

- `Invoke-OrchestrationObjectiveStep` é chamado **apenas** por
  `Invoke-OrchestrationAutonomousObjective` dentro de
  `scripts/v3/lib/OrchestrationAutonomousLoop.ps1` (linha 448) e por testes.
- `Invoke-OrchestrationAutonomousObjective` **não tem caller produtivo**: a lib
  só é dot-sourced por `OrchestrationAutonomousLoop.tests.ps1` e
  `OrchestrationDispatchIntentSymbol.tests.ps1`. Nenhum script `scripts/v3/*.ps1`
  de entrada a carrega.
- `Invoke-OrchestrationGoalAutoPromotion`
  (`scripts/v3/lib/OrchestrationGoalPromotionWiring.ps1`) — somente testes.
- `Invoke-ProductiveObjectiveEvent` / `Invoke-ProductiveObjectiveReconcile`
  (`scripts/v3/lib/OrchestrationProductiveActivation.ps1`) — somente testes.
- Plugin V2 (`plugins/orchestration-enforcement/v2.ts`) injeta mandato +
  observabilidade (`session.hook("context")`, `tool.hook("execute.before")`) e
  **não** invoca task/subagent — a delegação continua sendo ato do Planner LLM.
- Sem `Executor`, o passo do loop retorna `dispatch_intent`
  (`OrchestrationAutonomousLoop.ps1:324`) e o driver retorna
  `outcome='awaits-planner'` (linha 482) — o produto, sozinho, **não spawna**.
- `scripts/v3/lib/OrchestrationRuntimeAdapterContract.ps1` mantém os HOLDs de
  `dispatchWorker`, `waitForSettlement`, `requestPlannerContinuation`,
  `getSessionState`, `cancelAuthorizedExecution` (ops existentes na matriz,
  nenhuma com efeito VERIFIED em runtime).

| Transição | Quem inicia / API | Evento e evidência observada | Falha, persistência e próximo movimento |
|---|---|---|---|
| User Message → Planner | OpenCode `build`; sessão `ses_ee03e0dd0ffeLPJGqG7Rp7OwTu` | Este pedido real chegou ao Planner; provider/model registrados em §2. A fixture SPEC+PLAN não foi executada. | A sessão está ativa; não cria Goal do produto por si só. |
| Planner → Preflight | Nesta auditoria, o Planner executou `orchestration-preflight.ps1` explicitamente (pedido do AGENTS do checkout). | Stdout JSON: `DETERMINISTIC_FALLBACK`, `hard_exclusion_security_sensitive`, sem `selected_agents`; não foi persistido como artifact. | Resultado não aciona promoção/dispatch automaticamente; compliance permanece pós-execução. |
| Preflight → Goal Promotion | API existente `Invoke-OrchestrationGoalAutoPromotion` / `Resume-OrchestrationGoalSession`. | Caller produtivo ausente; referências são somente testes (`GoalPromotionWiring.tests.ps1`). | Não há criação/resume automático de Goal; kernels/checkpoints persistem quando chamados, mas ficam fora deste caminho. |
| Goal → Objective Controller/Loop | `Invoke-OrchestrationObjectiveStep` / `Invoke-OrchestrationAutonomousObjective`. | Controller calcula `next_move`; loop só é chamado por testes; sem executor retorna `dispatch_intent` e `awaits-planner`. | Nenhum evento inicia o próximo step na sessão normal; checkpoints do loop não são produzidos por este caminho. |
| Dispatch Intent → `task/subagent` | `New-OrchestrationNativeDispatchIntent` / `Invoke-OrchestrationNativeDispatch` no Autonomous Loop; executor esperado é o Planner. | Helpers não têm caller produtivo de Objective; chamada nativa de tarefa não foi observada para Objective/Task algum. | Sem executor não passa pelo dispatch/receipt; o loop devolve a intenção e para, sem retry ou settlement automático. |
| Worker → Task Kernel/Evidence | OpenCode nativo pode criar sessão filha quando acionado pelo Planner; a ponte do produto deveria executar NativeDispatch com executor injetado. | Três workers de auditoria retornaram resultados à sessão atual; não houve task de implementação nem vínculo a Task Kernel. | Resultado da auditoria observado na conversa; nenhuma evidence ref do produto/Task foi persistida. |
| Worker Result → Next Movement | `Invoke-OrchestrationAutonomousObjective` deveria reconciliar e iterar. | Nenhum caller produtivo; testes cobrem o driver limitado. | Sem chamada, não há CONTINUE/RETRY/REPLAN automático nem verificação final do Objective. |
| Sessão perdida → Planner substituto | Goal checkpoint/reconciler e lanes RR-E2E. | 16/17/19 `pass-real`; 18/20/21/22 permanecem bloqueados nos critérios descritos em §8. | Estado kernel-side persiste; consumo por turn do Planner substituto não foi comprovado. |

**Causa-raiz:** ausência do **Planner Runtime Wiring** — não há caller produtivo
que injete um Executor (Planner em sessão ativa) no loop. A causa **não** é
provider de modelo. Nenhuma API de bridge nova é inferida aqui; a decisão
arquitetural registrada (`evidence/v3.1/runtime-reliability/native-dispatch-closure-2026-10-09.json`,
`architecture_decision`) é que o único executor real é o Planner LLM via
`subagent` (V2)/`task` (V1) dentro de sessão ativa — a SPEC vigente **não**
exige daemon novo, e nenhum é proposto.

## 6. Transições automáticas

- **Não provadas.** Sem caller produtivo do loop, não existe auto-avanço de
  fase em runtime: `Invoke-OrchestrationObjectiveStep` com `Executor` ausente
  para em `dispatch_intent`; `ObjectiveController` só calcula `next_move` (puro).
  Os gates de continuação do closure record
  (`native-dispatch-closure-2026-10-09.json#gates`) são explícitos:
  `C_autonomous_continuation` = "driver limitado ... provados em testes;
  execução real depende de Executor (Planner)".

## 7. Testes e reviews

- Suítes da entrega v0.1.2 (metadado do closure record + CHANGELOG [0.1.2],
  PS5.1): NativeDispatch 178/178, Receipts 188/188, Envelopes 39/39,
  AutonomousLoop 47/47, ReuseWiring 40/40, StoreUnification 12/12,
  DispatchIntentSymbol 47/47, package-consistency 16 OK/0 FAIL; PS7 100% nas
  mesmas. Adversarial independente 161/161 + RP3a–RP3g.
- Cadeia de review do closure: 8 rodadas REV/SEC documentadas no closure record
  (`REV-BCEF` → `REV8/SEC8` + sign-off tester VAL6).
- Kernel: 75/75 (TaskKernel) — metadado histórico dos registros de fase.
- Watchdog local PS5.1: **421/421 PASS**, incluindo FIX4-2b e FIX5-2
  (`OrchestrationRuntimeWatchdogEnforcement.tests.ps1`); PS7 local também passou
  **421/421**. Isso não apaga a falha intermitente observada no attempt 1 da CI (§10).
- Suíte V3 completa local: **PS5.1 e PS7, cada uma 81 PASS / 3 FAIL / 6 SKIP**,
  exit 1 (§15). Em ambas, os 3 FAILs são asserções do hash da configuração
  global user-owned, não falhas nas outras assertions das capacidades testadas;
  nenhuma configuração foi alterada.

## 8. Recovery (evidência in-checkout)

Diretórios citados existem no checkout:
`evidence/v3.1/runtime-reliability/session-lane-2026-10-06/`,
`session-lane-2026-10-08/`, `session-lane-2026-10-08-rerun1821/`,
`session-lane-2026-10-08-rerun20/`.

Estado mais recente conhecido (metadado das lanes; run principal 2026-10-08
18:00–18:05Z, reruns 18:19Z e 19:23Z):

| Cenário | Estado | Fonte |
|---|---|---|
| RR-E2E-16 | `pass-real` | `session-lane-2026-10-08/rr-e2e-16.json` |
| RR-E2E-17 | `pass-real` | `session-lane-2026-10-08/rr-e2e-17.json` |
| RR-E2E-19 | `pass-real` | `session-lane-2026-10-08/rr-e2e-19.json` |
| RR-E2E-18 | `blocked` (perna completed sem modelo) | `session-lane-2026-10-08/rr-e2e-18.json` + `...-rerun1821/rr-e2e-18.json` |
| RR-E2E-20 | `pass-real` na lane original; **`blocked` sob critério enrijecido** no rerun (consumo pelo Planner substituto exige provider) | `session-lane-2026-10-08/rr-e2e-20.json` + `...-rerun20/rr-e2e-20.json` |
| RR-E2E-21 | `blocked` (re-leitura pelo substituto exige provider) | `...-rerun1821/rr-e2e-21.json` |
| RR-E2E-22 | `blocked` (`--help` do V1 indisponível no ambiente bounded; nada inferido) | `session-lane-2026-10-08/rr-e2e-22.json` |

- Turn de modelo do Planner substituto: **ausente/não provado** nas pernas
  model-dependent de 18/20/21. RR-E2E-22 tem bloqueio distinto: timeout do
  `--help` V1 no ambiente bounded; não houve tentativa de turn substituto.
- Probes V2-native da lane 2026-10-08: 7 `ambiguous` + 1 `unsupported`
  (fail-open `/shell` — §9). Nenhum registro `v2-native-evidence.json` gravado.
- Evidência de closure exata: `lane-summary.json` de cada diretório +
  `evidence/v3.1/runtime-reliability/native-dispatch-closure-2026-10-09.json`
  (`conclusion`: "PARTIAL CLOSURE ... spawn nativo (dispatchWorker) permanece
  HOLD com justificativa arquitetural provada; aceitação runtime-real completa
  depende de provider de modelo").

## 9. Segurança e idempotência

- `source/registry/capability-flags.json` (checkout atual):
  **`runtime_grant_enforcement.v1 = false`, `v2 = false`** — mantidos OFF.
  Nenhuma autorização runtime-real é alegada.
- Fail-open `/shell` no runtime **2.0.23** já foi **observado** na lane
  2026-10-08 (`capability_probes`: `session-permission-narrowing`,
  classificação `unsupported`, "fail-open observado via /shell"). Gate kernel-side
  continua obrigatório.
- Provas **estáticas (harness/teste only)** — não evidência de runtime:
  idempotência, fencing, `pending` ambíguo sem replay automático
  (`OrchestrationNativeDispatch.ps1` + `OrchestrationNativeDispatchReceipts.tests.ps1`);
  guardas de recibo contra symlink/junction/reparse com junction real e
  file symlink reais (RP1/RP2/RP3b/RP3e noReceipts.tests) — labeled **teste**.
- Residual documentado: janela **TOCTOU de reparse** (PS 5.1 sem abertura kernel
  sem-seguir-link); raiz de recibos é **confiável por escolha do caller**
  (`native-dispatch-closure-2026-10-09.json#known_residuals`).
- Kernel: `SETTLEMENT_REQUIRED` bloqueia complete/cancel com interrupção
  pendente (`OrchestrationTaskKernel.ps1`; testes em
  `OrchestrationRuntimeWatchdogEnforcement.tests.ps1`) — teste/suite, não
  alegação de runtime ao vivo.

## 10. Issues e fixes (classificados, sem abrir issue)

- **Watchdog CI (run `37893387670`)**: attempt **1** falhou apenas no job
  `CI (v2 lane, perfil V2 provisionado)`, step `V3 test suite`
  (engine **pwsh/PS7**; o workflow roda a suíte **antes** de provisionar o
  perfil V2 — `.github/workflows/ci.yml:246-251`). 5 assertions `[FAIL]`,
  **todas FIX4-2b** (`2026-10-09T06:43:11Z`):
  `expiry between kills => FAILED/PENDING partial with evidence (root + first child) -- killed=0`;
  `partial settlement PENDING (retryable, F6 intact) -- REFUSED`;
  `partial root is gone`; `later call resumes the remainder to ALREADY_EXITED`;
  `resumed remainder is gone`.
- No **mesmo** run, attempt 1, job `CI (ps51)` passou as assertions de watchdog
  **incluindo FIX5-2** (`2026-10-09T06:41:39Z`) — a falha é do engine PS7 da
  lane V2, não da PS51.
- Attempt **2**: todos os 5 jobs `success`; FIX4-2b `[PASS]` às
  `2026-10-09T07:13:53Z` na mesma lane.
- Histórico: `evidence/v3.1/runtime-reliability/program-status.json:263` já
  registrava "FIX4-2b flaky pré-existente observado 1/4 no PS5.1 em rodada
  anterior, limpo nas demais".
- Hipótese estática do Debugger (subagente real, sessão em §2): preparo real de
  CIM/árvore consumiu o deadline de 9s antes do primeiro kill; o produto
  retornou `REFUSED` corretamente (fail-closed). **Causa-raiz NÃO confirmada**:
  o log de falha não emite o detalhe da recusa; **re-run não é prova de fix**.
  Nada é declarado resolvido; nenhum assert é modificado nesta auditoria.
- Regressões locais PS5.1 e PS7: `CapabilityObservability.tests.ps1`,
  `CapabilitySkillUtility.tests.ps1` e `shadow-route.tests.ps1` falharam somente
  no assert que exige prefixo canônico `DE22307F` para
  `~/.config/opencode/opencode.json`; o hash observado foi `C1BB84F2…` e o
  arquivo tem `LastWriteTimeUtc` anterior à corrida. A divergência é estado
  global user-owned, coerente com o histórico de drift documentado; não alterei
  nem reconciliei esse arquivo. As outras assertions dessas suítes passaram nas
  duas engines; o precondition de config em `skill-bridge.tests.ps1` foi SKIP
  explícito em ambas.
- Issues consultadas no GitHub permanecem abertas e não foram alteradas: #8
  (lifecycle), #9 (exactly-once result delivery), #10 (event-driven runtime
  control), #19 (authorization de overrides de subagent) e #21 (distribution/
  V1-V2 dialeto). #19 e #9/#10 são adjacentes aos gaps; nenhuma foi fechada ou
  criada por esta auditoria.

## 11. CI

- **Run `37893387670`**, attempt **2**: `success`, 5/5 jobs —
  `CI (v2 lane, perfil V2 provisionado)`, `CI (smoke opencode real)`,
  `CI (ps7)`, `CI (smoke opencode v2 real)`, `CI (ps51)`; `headSha` =
  `b38c92bc8b3ab334a9dffad609f3515350336061` (= baseline).
- attempt 1: apenas a lane V2 falhou (§10). Metadado GitHub; não é evidência do
  checkout local.

## 12. Capabilities e HOLDs

- HOLDs preservados (nenhum removido): `dispatchWorker`, `waitForSettlement`,
  `requestPlannerContinuation`, `cancelAuthorizedExecution`, `getSessionState`
  em `OrchestrationRuntimeAdapterContract.ps1`.
- Flags: `runtime_grant_enforcement` OFF (§9); `capability_router`,
  `skill_routing`, `mcp_routing`, `adaptive_ranking` OFF (doutrina) —
  `source/registry/capability-flags.json` intocado.
- Sem daemon novo, sem nova arquitetura, sem inferência de API: a SPEC vigente
  não exige daemon; a recomendação é limitada ao wiring do Executor existente
  (§13).

## 13. Veredito e recomendação delimitada

**PARTIAL CLOSURE.** Provado: bridge produtivo honesto (intent validado,
recibos idempotentes, driver limitado), suites e reviews, CI verde no baseline,
recovery kernel-side 3/7 + bloqueios honestos. **Não provado:** wiring produtivo
ao vivo (essential live product wiring), transições automáticas de fase,
evidência de settlement do Task Kernel em runtime-real e consumo por Planner
substituto. Não há correção somente de prompt que conecte com segurança o
Executor PowerShell ao `task/subagent` nativo. A documentação V2 também descreve
APIs de sessão e custom tools, mas o plugin atual não as usa para executar o
TaskTool; uma chamada direta do plugin ao TaskTool não foi comprovada. A menor
fatia futura é um wiring explícito prepare → subagent nativo → settlement/
reconciliação, via Planner/hooks existentes, com contrato e validação no pin
exato. A lacuna é de integração, não de provider; não implementei uma fronteira
de runtime nova nesta rodada de aceitação.

**Recomendação (delimitada, sem implementar aqui):** implementar/validar o
**Planner Runtime Wiring** como a fatia prepare → ferramenta nativa do Planner
(`subagent` V2 / `task` V1) → settlement/reconciliação, usando o Executor único
e os hooks existentes, somente após admissão. Fechar a prova do contrato e do
binário pinado antes de remover qualquer HOLD. **Não** criar daemon, **não**
inferir chamada direta do plugin ao TaskTool, **não** reescrever asserts para
fabricar verde.

## 14. Tabela de gates G1–G14

| Gate | Critério | Status | Evidência |
|---|---|---|---|
| G1 | Planner recebe Objective real | PARTIAL (esta auditoria) | sessão Planner ativa recebeu este pedido; nenhum Objective da fixture foi executado (§2–§3) |
| G2 | Goal automático quando aplicável | NOT PROVEN | sem caller produtivo de promoção/Objective (§5) |
| G3 | Subagents reais acionados | PARTIAL (audit-only) | sessões filhas Explorer/Security/Debugger; nenhuma ligada a Task/Goal da fixture (§2, §4) |
| G4 | Resultado do worker observado | PARTIAL (audit-only) | resultados dos workers de auditoria chegaram ao Planner; sem settlement de worker de implementação (§2, §4–§5) |
| G5 | Task Kernel recebe evidência | NOT PROVEN | não houve dispatch de implementação/settlement no runtime (§5–§7) |
| G6 | Próxima ação executada automaticamente | FAIL (integration gap) | loop sem caller produtivo; sem `Executor` retorna `dispatch_intent`/`awaits-planner` (§5–§6) |
| G7 | Falha recuperável corrigida | NOT PROVEN | fixture C1–C5 não executada; falha watchdog é de teste e sua causa não foi confirmada (§3, §10) |
| G8 | Review e revalidação no ciclo | NOT PROVEN | review de segurança desta auditoria não é review de uma implementação de worker (§3–§4) |
| G9 | Checkpoint e recovery funcionam | PARTIAL (runtime-real/kernel-side) | RR-E2E-16/17/19 pass-real; 18/20/21/22 blocked (§8) |
| G10 | Planner substituto consome contexto e age | NOT PROVEN | turn substituto model-dependent ausente em 18/20/21; RR-E2E-22 bloqueado separadamente por timeout do `--help` V1, sem tentativa de turn (§8) |
| G11 | Recovery sem efeito duplicado | HARNESS/TEST-ONLY | recibos idempotentes e pending ambíguo cobertos por testes; sem replay/continuation produtiva (§9) |
| G12 | Autorizações e budgets respeitados | HOLD / TEST-ONLY | gates kernel-side em testes; grants runtime OFF e `/shell` fail-open observado (§9, §12) |
| G13 | Objective só termina após verificação | HARNESS/TEST-ONLY | Task/Goal Kernel testado; conclusão de Objective real não executada (§5–§7) |
| G14 | CI e regressões aprovados | PARTIAL | CI attempt2 5/5; attempt1 teve 5 FAIL FIX4-2b; V3 local PS5.1/PS7 = 81/3/6 em ambas, com os 3 FAILs limitados ao hash da config global (§10–§11, §15) |

## 15. Verificação local

- Comandos: `powershell -NoProfile -File scripts\v3\run-v3-tests.ps1` e
  `pwsh -NoProfile -File scripts\v3\run-v3-tests.ps1`.
- Resultado de **cada engine**: exit 1; **81 PASS / 3 FAIL / 6 SKIP /
  0 INTERNAL_ERROR / 90 total** (PS5.1: 1356,1 s; PS7: 1228,4 s). Falhas:
  somente `CapabilityObservability.tests.ps1`,
  `CapabilitySkillUtility.tests.ps1` e `shadow-route.tests.ps1`, todas no
  precondition que exige SHA prefix `DE22307F` da configuração global viva; o
  hash observado foi `C1BB84F2…`. O `LastWriteTimeUtc` da configuração é
  2026-10-08, anterior à corrida local de 2026-10-09. O histórico também
  identifica drift desse arquivo como user-owned. Não atribuir essas falhas a
  regressão no código v0.1.2 nem reconciliar o arquivo global nesta auditoria.
- As 6 suítes `SKIP` permanecem skips explícitos do runner/ambiente; não são
  contabilizadas como PASS.
- Suíte watchdog dentro de cada corrida local: **421/421 PASS** em PS5.1 e
  PS7; a causa do failure CI FIX4-2b segue não confirmada (§10).
- CI attempt2 (PS5.1, PS7, distribution e smokes): 5/5 jobs success no baseline,
  mas não substitui a execução local; attempt1 e seus findings estão preservados
  em §10.

## 16. Revisão da SPEC/PLAN Native Handoff (G0, 2026-10-09)

Documentos criados/revisados:

- `docs/specs/PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md`
- `docs/specs/PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md`

### Estado do checkout nesta revisão

- HEAD continua `b38c92bc8b3ab334a9dffad609f3515350336061`, branch
  `acceptance/autonomous-core-v0.1.2-2026-10-09`, tag `v0.1.2`, igual a
  `origin/master`; não houve fetch/pull nem mudança de refs.
- Working tree já continha modificações em Wiring Matrix, Closure Addendum,
  adapters `opencode.md`/`opencode-v2.md` e este audit untracked. Preservadas;
  adapters não foram editados.
- `opencode` e `opencode2` do PATH = `2.0.26`. Perfil isolado contém binário
  V2 e `@opencode/cli` `2.0.23`; execução `--version` confirmou `2.0.23`.
  `run --help` confirma que CLI escolhe agent da sessão (`--agent`) e não
  oferece operação spawn de subagent. Perfil/binário V1 pinado `1.18.34` não
  encontrado. PS5.1 `5.1.26100.9444` e PS7 `7.6.6` instalados.
- CI consultada: run `37893387670` attempt 2, success 5/5; attempt 1 falhou
  cinco asserts FIX4-2b no job PS7. A causa segue não confirmada. Issues #8,
  #9, #10, #19 e #21 consultadas; nenhuma foi modificada.

### Pareceres independentes e decisão

- **G0 PASS (diagnóstico):** Explorer confirmou que Goal promotion, loop e
  ativação produtiva só aparecem em libs/testes; sem Executor o loop retorna
  `dispatch_intent`/`awaits-planner`. Isso confirma gap de wiring, não provider.
- **Architect:** o Executor PowerShell síncrono não pode ser mantido suspenso
  enquanto o Planner chama a tool; chamar worker primeiro e registrar depois
  inverte a fronteira pré-efeito. Recomenda protocolo Planner-driven só depois
  de provar admissão/correlação, sem novo daemon/API.
- **Security Reviewer — CHANGES_REQUIRED:** `dispatch_intent` não é autorização
  consumível; hoje não há correlação host-originated provada entre intent e
  execução filha/resultado. Prompt, event hook fail-open e resultado do modelo
  não autenticam a chamada. `runtime_grant_enforcement` segue OFF.
- **Researcher:** docs oficiais descrevem tools model-callable `subagent` V2 e
  `task` V1, não spawn por plugin/CLI. Docs vivas não provam o pin. Probes
  históricos do V2 2.0.23 registraram echo de `parentID` ambíguo e deny
  `/shell` fail-open; campos de tool hook não são todos especificados. Fontes:
  https://opencode.ai/v2/docs/tools/ ,
  https://opencode.ai/v2/docs/build/plugins/ ,
  https://opencode.ai/docs/agents/ e https://opencode.ai/docs/server/.

### Gate e consequência

G1 **BLOQUEADO**: não foi realizado PREPARE produtivo, chamada com efeito,
SETTLE ou ADVANCE. Executar tool depois de receber intent permitiria execução
fora de enforcement pré-efeito confiável; chamar callback depois fabricaria
causalidade. Não foi iniciada fixture de implementação nem alterado
provider/model/configuração.

Antes de implementação G1, exige-se prova no runtime pinado de (a) bloqueio
pré-efeito para intent inválida/stale, com zero chamada nativa, e (b) correlation
ID/parent/child/result host-originated, independente de texto do modelo. Se a
superfície não oferece isso sem API não documentada ou mudança de autoridade,
manter HOLD; não diminuir critérios de aceite. G2–G7 ficam sem aprovação e o
veredito permanece **PARTIAL CLOSURE**.

Nenhum teste de aplicação foi executado nesta atualização documental.
`git diff --check` passou sem saída e `scripts/test-package-consistency.ps1`
passou 16/16. Validação focada de link/referência/documentação e review
independente passaram; runtime E2E não foi executado, pois G1 segue bloqueado.
DONE gate de orquestração: `Test-OrchestrationDoneCompliance -TaskClass
non_trivial -Decision DETERMINISTIC_FALLBACK -DeterministicOwnerExecuted $true`
retornou `COMPLIANT` (participação material de workers registrada nesta sessão).

## 17. Probe runtime V2 `execute.before` (2026-10-09)

Depois da autorização do operador para iniciar, executei um probe de capacidade
isolado com o binário do perfil V2 pinado. Evidência sanitizada e evento
correlacionado:
`evidence/v3.1/runtime-reliability/native-handoff-hook-probe-2026-10-09.json`
e os dois arquivos `.jsonl` adjacentes.

- Binário `@opencode/cli` **2.0.23**, SHA-256
  `E8091A74F22A1DF6467134262A55E7DDD215F3C1C8CC4C7988437591A096C974`; o
  plugin observou `ctx.app.version=2.0.23`. Diretório de projeto/configuração e
  plugin temporários; nenhuma alteração na configuração global, credenciais,
  providers, flags ou checkout de aplicação.
- Chamada positiva, provider/model `openai/gpt-6-luna`: Planner `build`
  chamou `subagent` para `explorer`. `execute.before` e `execute.after`
  correlacionaram parent session `ses_edfb2c2f8ffeclhsUu0Sy1vXD7`, message
  `msg_1204d447e001QRwJ5NbKGJVycl`, call
  `call_cc82ac82e5944dd5aaca7e334debc932` e child
  `ses_edfb2b302ffeA8GeTZH5HFwtEC`; resultado `PROBE_CHILD_OK`. A store de
  sessões V2 persistiu o child com `parent_id` correspondente.
- Chamada negativa, mesmo agent/tool: um plugin temporário lançou
  `synthetic-pre-effect-denial` em `execute.before`. Runtime retornou erro na
  tool; não houve `execute.after`, child ID nem row child na store de sessões
  para parent `ses_edfb24797ffeCpG8ZfJZabSfJ6`. Não ocorreu código do corpo do
  subagent na chamada negada observada. O CLI reportou `providerCall.executed=false`.
- O runtime reportou custo `0`; isso não é verificação de custo/billing do
  provider. A store SQLite de sessões existente recebeu as sessões de teste
  positivas/negativas; ela foi consultada em modo somente-leitura depois.
  A credencial existente foi usada pelo runtime; seu valor nunca foi exibido,
  lido pelo agente ou registrado. Nenhuma credencial foi alterada.
- Uma tentativa anterior no mesmo binário com `opencode-go/muse-spark-1.3-contributor`
  falhou antes de chamar tool (`provider.no-route`); prova positiva foi feita
  com o provider OpenAI já configurado, sem modificar a configuração do model.

**Conclusão limitada:** o hook `execute.before` pode, nesta configuração do
V2 `2.0.23`, negar a invocação nativa testada; os eventos expõem correlação
host-originated suficiente para vincular chamada e child observado. Isso
destrava a pesquisa de implementação do gate. **Não** prova PREPARE autorizado
do kernel, consume-CAS, plugin ausente/unload, ordenação/mutação de múltiplos
hooks, settlement no TaskKernel, verificação, ADVANCE, recovery nem contenção
de grants do worker. Portanto G1 produtivo e G2–G7 seguem não aprovados;
  `runtime_grant_enforcement` segue OFF/HOLD.

## 18. Probe `permission.evaluate` e parent lookup (2026-10-10)

Evidence: `evidence/v3.1/runtime-reliability/native-handoff-permission-hook-probe-2026-10-10.json`
e `.jsonl` adjacentes. No binário `@opencode/cli` 2.0.23, plugin Promise de
fixture confirmou que `ctx.permission.hook("evaluate")` existe e que
`ctx.session.get({sessionID: child})` devolve `parentID` antes do
`execute.after` do parent. O contexto Promise **não** oferece
`ctx.permission.rules`.

- Child read: `allowed.txt` permaneceu permitido; `denied.txt` mudou de
  `allow` para `deny` no hook e nenhum conteúdo do arquivo negado retornou.
- Child edit: `allowed-edit.txt` recebeu somente marcador sintético;
  `denied-edit.txt` mudou de `allow` para `deny` e permaneceu byte-original.
- Child shell: um único comando sintético `Write-Output SHELL_PROBE_MARKER_56`
  mudou de `allow` para `deny` e não produziu saída. Isso não comprova a
  cobertura do parser shell inteiro nem de comandos compostos.
- A store de sessão do runtime confirmou parent/child; cada evento permission
  registrou child session, agent, action, resources e source message/call ID.
- Projeto/plugin/configuração em diretório temporário, sem mudança de config,
  provider ou credenciais. Store global de sessões OpenCode recebeu rows de
  teste; o runtime reportou custo 0, sem comprovação de billing.

**Conclusão limitada:** o permission hook é uma primitiva exata para deny-only
de `read`/`edit` e um comando shell sintético no fixture; `ctx.session.get`
expõe o parentID do child. Isto não vincula decisões a grants reais de
TaskKernel nem ao receipt PREPARE/CLAIM; cobertura de shell em geral,
MCP/Code Mode, plugin ausente/unload, order/mutation de hooks e instalação
distribuída não foram exercitados. `runtime_grant_enforcement` continua
OFF/HOLD.

## 19. NativeDispatch PR-A — receipt PREPARE/CLAIM (2026-10-10)

A fatia de biblioteca foi implementada em
`scripts/v3/lib/OrchestrationNativeDispatch.ps1`, com testes em
`OrchestrationNativeDispatchHandoff.tests.ps1` e ajustes de fixture nos testes
legados de NativeDispatch/receipts.

- PREPARE/CLAIM usam receipt store/locks existentes; não chamam Executor nem
  criam store paralelo. Fencing é revalidado pós-lock; receipt contém intent e
  fingerprints verificáveis.
- Reserva de efeito por Task cruza Goal/revision/key e o `Invoke` síncrono
  legado. `pending/claimed` mantém reserva; `settled` sem prova não satisfaz
  takeover. Falha pós-efeito preserva `pending`.
- Scan é global por raiz, incremental e bounded; raiz JSON, tipos crus,
  identidade de namespace/key, semântica handoff, corrupção/reparse e caps
  falham fechado. Residuais TOCTOU permanecem declarados.
- Reviewer e Security Reviewer **APPROVED** para a primitiva synthetic;
  Tester: Handoff 675/675, NativeDispatch 180/180, Receipts 187/187,
  Envelopes 39/39, IntentSymbol 47/47, AutonomousLoop 47/47, ambos PS5.1 e PS7;
  10/10 NativeDispatch no PS5.1; package consistency 16/16; diff-check limpo.

**G1 ainda não passa:** as funções novas são chamadas apenas pelos testes; o
plugin distribuído não as consome, não há SETTLE real/TaskKernel worker-result,
VERIFY, ADVANCE nem recovery. Além disso, o instalador leva somente o bundle JS,
não o script/lib de bridge. O relatório do Explorer sobre instalação/global
path e os pareceres de arquitetura/segurança recomendam manter execução
productiva BLOCKED até definir bridge confiável, fonte de grants não-modelo e
falhas de plugin/unload. PARTIAL CLOSURE permanece o veredito.

## 20. Parent lookup, shell deny e caminho de distribuição (2026-10-10)

O probe permission foi estendido sem tocar o checkout ou a configuração global:

- Com um plugin temporário carregado pelo diretório global XDG isolado, o host
  reportou `ctx.location.project.canonical` como projeto aberto. Um
  `ctx.session.get({sessionID: child})` também expôs `location.directory` e
  `projectID`; parent/child pertenciam ao mesmo projeto temporário. Eventos:
  `native-handoff-permission-hook-probe-2026-10-10-session-get.jsonl`.
- Uma execução V2 `2.0.23` mudou um comando shell literal
  (`Write-Output SHELL_PROBE_MARKER_56`) de `allow` para `deny` via
  `permission.evaluate`; a tool do child reportou denied e não houve output do
  comando. Evidence: `...-shell-deny.jsonl`. Isso comprova **um** recurso shell
  sintético quando o hook estava presente e tinha regra deny; não cobre outra
  sintaxe/ação nem plugin ausente.
- Um experimento anterior, com versão temporária do plugin sem regra shell,
  permitiu o mesmo comando benigno. Isso demonstra que o hook não é barreira
  sozinho: a política por ação precisa estar carregada corretamente.

### Decisão de próxima fatia

Architect recomenda protótipo local V2-only com bridge PowerShell de operações
allowlisted, executável/script absoluto, argv fixo, JSON bounded, timeout e
fail-closed; plugin usa host session/call IDs + `permission.evaluate` deny-only
e valida child→parent via `ctx.session.get`. Security Reviewer mantém
**CHANGES_REQUIRED para ativação** até a origem de grants ser independente do
modelo, o bridge estar fora do write scope, a ausência/unload ser tratada e
ações não testadas (MCP/Code Mode) permanecerem bloqueadas. A API
`ctx.permission.rules` não existe no Promise plugin do pin; não usar.

O instalador atual instala o bundle JS, não as PowerShell libs. Não resolver
isso apontando a scripts via CWD ou um caminho de repo fornecido pelo modelo.
O próximo desenvolvimento pode testar o bridge apenas em fixture local do
checkout, mas **não** pode alegar distribuição ou produção. Não houve instalação
nem alteração global. G1 segue BLOCKED; não iniciar execução de worker do
objective real antes de fechar esse boundary.

## 21. NativeDispatch SETTLE, FIX6C e contagens revisadas (2026-10-11)

Esta seção registra, como atualização datada, uma rodada de **biblioteca e
suíte** ocorrida em 2026-10-11 em
`scripts/v3/lib/OrchestrationNativeDispatch.ps1` e
`scripts/v3/lib/OrchestrationNativeDispatchHandoff.tests.ps1`; ela é distinta
da auditoria read-only descrita no cabeçalho. **Nenhum probe de runtime real
foi reexecutado nesta rodada**: a evidência de probes permanece a registrada
em §17 (2026-10-09) e §18/§20 (2026-10-10). Toda a evidência nova é sintética
(suíte) ou estática (review).

### Estado da biblioteca

- A biblioteca expõe as três APIs candidatas **PREPARE, CLAIM e SETTLE**.
  SETTLE é **API candidata de nível de biblioteca** — não é settlement
  produtivo canônico do TaskKernel: nenhum plugin, CLI ou TaskKernel consome
  essas funções, nenhum worker-result é liquidado no kernel e nenhuma
  proveniência causal de kernel é produzida.
- A varredura cross-task de recibos valida a integridade semântica do handoff
  marcado **antes** da atribuição de task; o gate de `settled` provado é
  estrito. Regressões novas cobrem recibos adulterados do mesmo tipo, com
  `task_id` trocado por outro id válido (hashes intactos), em caixa alterada
  (casing) e híbridos, além de recibos **marker-only** — nomes exclusivos do
  handoff (`base_revision`, `prompt_hash`, `scope`, `acceptance_criteria`,
  `external_idempotency_proof`, `prepared_fingerprint`) como único marcador
  sobrevivente. Em todos os casos a recusa é fechada antes de qualquer
  atribuição de task.
- Recibos legados de verdade (sem marcador algum) passam por um **gate de
  compatibilidade separado** e continuam liberando a reserva; um handoff
  `settled` provado e válido continua liquidando.

### Reviews

- Security Reviewer **APPROVED** o FIX6C com escopo em
  **classificação/reserva**; Reviewer aprovou o escopo estático do FIX6C; o
  proof shape já tinha aprovação de review em rodada anterior. **Nenhuma
  dessas aprovações implica wiring produtivo nem proveniência causal de
  kernel.**

### Evidência de testes (sintética)

- Suíte Handoff no estado funcional pós-FIX6C: **1745/1745 em PS5.1 e em
  PS7**. Após edições de performance no harness de teste, o runner oficial
  PS5.1 passou em **301258 ms** (cap de 420 s específico da suíte) e o PS7
  direto em **138377 ms**. NativeDispatch **180**, Receipts **187** e
  Envelopes **39** passam nas duas engines; package consistency **16/16**;
  `git diff --check` limpo.
- Variância de performance é **residual**: antes das edições de performance o
  Tester observou um timeout em 420 s e um passe em 267423 ms — por isso
  **não** há claim de tempo estável. A nova falha `Wait-Job` é fail-loud.
- Tester reverificou de forma independente o estado pós-performance; Reviewer
  **APPROVED** as edições de performance; Security Reviewer **APPROVED** o
  FIX6C. São testes sintéticos; nenhuma execução em runtime real.

### Correções de contagem (seções históricas permanecem históricas)

- §7 traz NativeDispatch 178/178 e Receipts 188/188 como metadado do closure
  v0.1.2; §19 registrou Handoff 675/675 no estado PREPARE/CLAIM, com
  NativeDispatch 180/180, Receipts 187/187 e Envelopes 39/39 após ajustes de
  fixture. O estado medido agora é **Handoff 1745/1745**, NativeDispatch 180,
  Receipts 187, Envelopes 39. As seções antigas **não** foram reescritas:
  continuam descrevendo fielmente os estados em que foram medidas.

### Fronteira de evidência e veredicto

- Descritores de host persistidos e internamente consistentes nos recibos
  **não provam** que o TaskKernel liquidou de fato o worker-result; a fonte
  confiável de grants, o ciclo de vida do plugin e a ponte causal seguem não
  resolvidos. Portanto **não** há claim de SETTLE produtivo, de G1, de
  runtime enforcement nem de FINAL CLOSURE; `runtime_grant_enforcement`
  permanece OFF/HOLD e nada de configuração, instalação, provider ou
  credencial foi alterado.
- Veredicto inalterado: **PARTIAL CLOSURE** (§13); **G1 produtivo segue
  BLOQUEADO** (§16, §19, §20).
