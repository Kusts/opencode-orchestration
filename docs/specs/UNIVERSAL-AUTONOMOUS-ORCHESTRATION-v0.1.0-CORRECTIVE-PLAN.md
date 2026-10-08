# CORRECTIVE PLAN — Universal Autonomous Orchestration v0.1.0 (Autonomous Core Runtime Closure)

**Repository:** `Kusts/opencode-orchestration`
**Baseline:** branch `closure/v0.1.1-job44-stable-core` @ `dea2b40` + base `b945d40` (merge PR #34)
**Revision date:** 2026-10-08
**Status:** REVISED-BY-PLANNER
**Change class:** `CORRECTIVE` + `AUTHORITY_HARDENING`
**Companions:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md` / `-PLAN.md` / `-ADR.md`
**Closure addendum:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-CLOSURE-ADDENDUM.md` (2026-10-08, **PARTIAL**)
**Runtime contract:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-OBJECTIVE-RUNTIME-CONTRACT.md`
**Wiring matrix:** `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-WIRING-MATRIX.md`

Este plano **não duplica** SPEC/PLAN/ADR, `docs/ARCHITECTURE.md` nem o
CLOSURE-ADDENDUM — apenas os referencia e corrige o que o addendum declarou
PARTIAL. Leitura normativa continua nos companions; aqui vive só o corretivo.

---

## 1. Objetivo e resultado esperado (preservados do plano original)

**Objetivo** (PLAN §1, inalterado): construir a v0.1.0 incrementalmente sobre
o kernel atual, sem reescrita total — preservar o Task Kernel, migrar
comportamento antes de adicionar sofisticação, fechar cada fase com Reviewer
(+ Security quando authority/credentials/grants/delivery mudarem), sem nunca
enfraquecer DONE/Verifier.

**Resultado esperado** (PLAN §17, inalterado): `VERSION = 0.1.0`, tag `v0.1.0`
(sem tocar a tag histórica `v1.0`), full suite + distribution + smokes V1/V2
exact-runtime + recovery/Jev/reuse/security + Golden Workflows + docs
reconciliadas + worktree limpo + zero P0/P1 + release evidence bundle.

**Versionamento:** `VERSION = 0.1.0` e tag `v0.1.0` (`2daa6af`,
CLOSURE-ADDENDUM §1/§8) são histórico publicado e intocável — nunca
reescritos. O fechamento corretivo sai em versão corretiva NOVA: patch
`v0.1.1` para o JOB44 isolado; a versão de integração do executor (B) é
definida após avaliar compatibilidade, sem reescrever a `v0.1.0`.

**Diagrama** (ARCHITECTURE.md, inalterado):

```
Planner `build` (único control plane)
  │ preflight obrigatório (SINGLE_WORKER / MULTI_WORKER / PERSISTENT_GOAL / DETERMINISTIC_FALLBACK / BLOCKED)
  ├─ CHEAP pool (execução) ── STRONG pool (juízo) ── PLANNING advisory ── DIAGNOSTIC
  └─ plugins orchestration-enforcement (mandato + telemetria sanitizada)
```

O corretivo acrescenta **um executor produtivo mínimo** (opção B do architect,
detalhado no OBJECTIVE-RUNTIME-CONTRACT): caller do Planner em safe
boundaries que CONECTA Kernel/Controller/adapters — composição, não
duplicação. Sem ele, auto-promotion/continuação/checkpoint-resume seguem HOLD.

---

## 2. Matriz diagnóstica revalidada (estágios + notas do addendum §2)

Estágios: `IMPLEMENTED` < `WIRED` < `ACTIVE` < `RUNTIME-PROVEN`; `HOLD` =
decisão explícita com evidência, não pendência esquecida. Detalhe por arquivo
em WIRING-MATRIX.md.

| Componente | Estágio revalidado | Nota do addendum §2 |
|---|---|---|
| Preflight | RUNTIME-PROVEN | CLI + DONE gate, usado por policy/lanes |
| PlannerLoop | ACTIVE-parcial | planning-only, never dispatches; único caller Jev P38-S2 advisory-only |
| DispatchPipeline | ACTIVE record-only | consome plan record; `spawned=false`; não faz spawn |
| ObjectiveController | ACTIVE-cálculo | função pura `next_move`; não loopea/não executa |
| ObjectiveRunner.harness | TEST-HARNESS-NOT-PRODUCT | único loop que itera (bounded 20, outcomes sintéticos) |
| DecisionProvider | NÃO-CONECTADO / test-only | seam `-JevProbe`; não toca Loop/JevAdvisory |
| JevAdvisory | ADVISORY-ONLY | born-OFF/shadow, agora `enabled:true shadow:false`; transporte env user-owned fail-closed; nunca roteia/concede/DONE |
| EvidenceStore | ACTIVE | reuse automático no PlannerLoop; **TTL só se condição presente** (risco reuse indefinido sem ttl — ver AR-10) |
| GoalPromotion | SCORE-ONLY | só pontua; wiring em fase posterior |
| GoalKernel | ACTIVE | CRUD+CAS, store `cache/goal-store`; provado em harness/testes |
| GoalProgress | SCORE-ONLY | delta/estagnação; loop-guard posterior |
| GoalCheckpoint | IMPLEMENTED | store atômico; consumido pelo harness; nunca toca sessões reais |
| SessionReconciler | READ-ONLY | nunca proba/controla sessões; V2 probing HOLD |
| TaskKernel | RUNTIME-PROVEN | o mais forte: CAS+lock, DONE só via `Complete-OrchestrationTask`; provado em lanes reais |
| Delivery | DECISÓRIO-ONLY | elegibilidade + state machine; merge/checks com chamador externo |
| `runtime_grant_enforcement.v1/v2` | OFF HOLD | fail-open observado na superfície `/shell` do 2.0.23; autorização declarada sem deny runtime; DONE não falsificável pelo worker (gate kernel) — ver AR-09 |
| Watchdog | ATIVO com HOLD residual | ativado pelo operador em 2026-10-04 (`{enabled:true,shadow:false}`) + Job Object backstop ligado ao enforcement em 2026-10-05; HOLDs residuais honestos: janela gate→`TerminateJobObject` nativo, preempção entre checagem e chamada, descendentes pré-attach cobertos só pelo kill CIM |

Contrato `TASK_DONE≠OBJECTIVE_DONE` (SPEC INV-006) existe como texto de
plano/contrato; **nenhum loop produtivo consome CONTINUE/RETRY/REPLAN até
COMPLETE fora do harness** — fechar esse gap é o objeto das Fases 1–8 abaixo.

---

## 3. Regras transversais

### 3.1 Reuso obrigatório

Reuso do kernel, libs, policies e evidências existentes é obrigatório;
nenhuma reimplementação paralela de CAS, locks, DONE gate, verifier
allowlisted ou fingerprint `len:valor`. Novo código CONECTA o existente.

### 3.2 Delegation-first

Trabalho operacional vai a cheap workers via contrato limitado
(`TASK_ID/OBJECTIVE/READ_SCOPE/WRITE_SCOPE/ACCEPTANCE_CRITERIA/VALIDATION/
PROHIBITED_OPERATIONS/RETURN_FORMAT/ESCALATION_CONDITIONS` + ambiente/
`PRODUCTION_AUTHORIZED`/`CREDENTIAL_SCOPE` quando houver escrita/shell
sensível). Planner nunca executa diretamente havendo worker adequado.

### 3.3 Limites de segurança

Reviewer read-only independente em toda fase; Security Reviewer obrigatório
quando authority/credentials/grants/delivery forem tocados. Nenhum rollout
enfraquece DONE/Verifier. Flags nascem OFF/shadow; ativação é decisão humana
com evidência. `runtime_grant_enforcement` segue HOLD até prova
exact-binary-live. Segredos nunca em git/logs/telemetria.

### 3.4 Compatibilidade V1/V2/PS5.1/PS7

Toda lib roda em PS 5.1 e PS7. Pins de runtime via
`source/registry/runtime-versions.json` (loader fail-closed, sem literal).
Não assumir equivalência V1/V2 — cada op do RuntimeAdapter declara matriz
SUPPORTED/VERIFIED/UNSUPPORTED/HOLD por runtime.

---

## 4. Fases corretivas 0–8 (Gates G0–G8, PRs PR-0–PR-7)

Fora de escopo (pós-v0.1.0, sem mudança): Agent Teams, Swarm, Arena, Harness
Profiles, Programmatic Execution (PLAN §18, companions).

### Fase 0 — Base estável (G0) · PR-0

**Trabalho:** tree clean verificado em 2026-10-08; commits `dea2b40` +
`0f91679` sobre `b945d40`. JOB44: causa-raiz no comparador
`Get-EnforceSettlementShape` (denylist só de `job_*` + concatenação do resto)
→ convertido em **allowlist do núcleo estável**
(`engaged/interrupted/settlement/classification`); `job_*` excluído como
diferença intencional; `tree_excluded/exclusion/telemetry_file/
telemetry_written` excluídos como observações voláteis (snapshot CIM e writer
divergem entre runs sem mudar o que foi morto; segurança pinada per-run).

**Gate G0:** re-review independente (reviewer + security-reviewer) da mudança
JOB44 + full 74 suites + distribution + CI verde no HEAD final + PR #41
(merge da branch corretiva; **não detectável localmente — sem refs/pull/\***)
antes do merge + tag `v0.1.1` (**patch isolado: só fix de teste + addendum;
NÃO fecha o Autonomous Core**).

### Fase 1 — RuntimeAdapter contract (G1) · PR-1

**Trabalho:** especificar o contrato do adapter (nomes = proposta, não API
existente). Ops: `detectCapabilities`, `identifySession`, `getSessionState`,
`dispatchWorker`, `observeWorkerResult`, `waitForSettlement`,
`requestPlannerContinuation`, `restoreContext`,
`cancelAuthorizedExecution`, `recordRuntimeEvidence`. Cada op declara:
entrada tipada, identidade (pid+creation-ticks por geração),
autorização (envelope §3.3), resultado, timeout, erro, fallback e prova
exigida. V1 pin `opencode-ai@1.18.34`; V2 pin `@opencode/cli@2.0.23`
(`source/registry/runtime-versions.json`, loader fail-closed, sem literal).

**Regra de prova:** primeiro provar API→efeito→observável em runtime exato;
depois declarar matriz SUPPORTED/VERIFIED/UNSUPPORTED/HOLD por op × runtime.
Não assumir equivalência V1/V2.

**Gate G1:** contrato revisado (reviewer + security) + matriz preenchida com
evidência, sem claims VERIFIED sem prova.

### Fase 2 — Executor mínimo B + ownership/idempotência (G2) · PR-2

Caller produtivo do Planner em safe boundaries (OBJECTIVE-RUNTIME-CONTRACT):
ownership CAS+lease+fencing por geração (um mutador por Goal, rejeita owner
obsoleto, atômico, crash entre dispatch-settlement declarado);
DispatchIntent persistida + idempotency key
`goal_id+work_item_id+action_revision`; efeitos externos exigem reconciliação,
nunca exactly-once presumido.

**Gate G2:** ciclo promoção→Goal→TaskKernel→dispatch real→barrier→evidência
verificada→progress→checkpoint→next_move executado contra runtime exato, DONE
só via kernel. Orçamento persistido por Goal (contrato §8): consumo acumulado
Worker/Task/Goal no Goal record (base `phase23.json`, sem números novos); sem
reset silencioso na retomada, revalidado; exhaustion terminal recusa novos
efeitos em runtime, sem falso DONE; ligado ao watchdog.

### Fase 3 — Recovery/session-reconciler produtivo (G3) · PR-3

Reabrir/revalidar/reconciliar/verificar efeitos/restaurar mínimo/continuar;
sessão sumida ≠ Task falha. `mark_SESSION_LOST` só com prova.

**Gate G3:** cenários 16/17/19 (kill/restart/ausência) verdes em runtime real.

### Fase 4 — Decision/continuation wiring (G4) · PR-4

Decidir wiring DecisionProvider vs JevAdvisory (uma autoridade consultiva);
conectar Controller/CONTINUE ao executor; Jev indisponível ⇒ determinístico.

**Gate G4:** SPEC+PLAN longa atravessa phases sem intervenção artificial;
`trivial` nunca consulta Jev.

### Fase 5 — Promotion/progress/loop-guard (G5) · PR-5

Auto-promotion explicável conectada; `STRATEGY_CHANGE_REQUIRED` + Debugger
obrigatório no 2º stall aplicam-se ao executor real.

**Gate G5:** GW-07/GW-10 verdes em runtime, não só harness.

### Fase 6 — Checkpoint/resume + `ttl` default (G6) · PR-5 (mesmo PR)

`ttl` default na produção de evidências (fecha AR-10); `store_dir` default
padronizado em operação real; resume fail-closed com store inverificável
recusando.

**Gate G6:** GW-11 verde cross-session real; reuse indefinido sem ttl
impossível.

### Fase 7 — Golden Workflows runtime-real 1–5 (G7) · PR-6

Cenários com OpenCode instalado (não executados na rodada do addendum por
tempo/orçamento): single-worker, bug, reuse, Jev fallback, delivery loop.

**Gate G7:** GW-01–05, 08–09, 12–15 verdes em binário exato.

### Fase 8 — Release closure v0.1.x (G8) · PR-7

Full suite + distribution + smokes exact-runtime + security + reviewer final +
evidence bundle. Issues (#6 umbrella; #8/#9/#10, #16, #19, #1, #21, #25, #30)
só fecham com prova completa — reconciliar como parcialmente implementadas ou
bloqueadas por runtime, nunca como concluídas sem prova.

**Gate G8:** critérios do PLAN §17 + veredito abaixo. Release em versão
corretiva NOVA (ver §1 — Versionamento); `v0.1.0`/tag `v0.1.0` preservadas.

---

## 5. Autorevisão AR-01–AR-10 (preservada do ADR; AR-09/AR-10 reforçadas)

AR-01 (Goal universal ≠ overengineering) a AR-08 (tag `v1.0` legacy) mantidas
conforme ADR §§AR-01–AR-08. Reforços corretivos:

- **AR-09 — fail-open do enforcement:** `runtime_grant_enforcement.v1/v2` OFF
  HOLD com mitigação (gates kernel + watchdog + review). Nenhuma fase deste
  plano alega deny runtime sem prova exact-binary-live; `auto_authorized`
  amplo permanece declarativo até lá (issue #19 aberta).
- **AR-10 — TTL/invalidação:** EvidenceStore ACTIVE com TTL condicional é
  risco de reuse indefinido; Fase 6 impõe `ttl` default + `store_dir` padrão.
  Até lá, evidências sem ttl são marcadas e revisáveis.

(AR-11/AR-12 do ADR — colisão execution-modes A/B/C e Jev advisory vs Planner
authority — seguem vigentes e são consumidas nas Fases 1/4.)

---

## 6. Critérios finais de aceite

1. G0–G8 verdes com evidência citada (arquivo + suite + run).
2. Executor B operando o ciclo completo em runtime exato, DONE só via kernel.
3. `TASK_DONE≠OBJECTIVE_DONE` válido fora do harness.
4. Zero P0/P1 abertos; issues só fechadas com prova.
5. Nenhuma flag ativada sem decisão humana com evidência.
6. Nenhum claim runtime-real sem prova exact-binary-live.

## 7. Veredito

- **FINAL:** todos os critérios acima atendidos → release fecha.
- **PARTIAL:** base/contrato/matriz avançam, wiring produtivo segue HOLD
  honesto (estado atual 2026-10-08) → nova rodada corretiva rastreável.
- **BLOCKED:** G0 vermelho (CI/HEAD/re-review) ou fail-open de segurança sem
  mitigação → nada acima de G0 prossegue.

---

## 8. Status de execução PR-0–PR-7 (adendo PR-7, 2026-10-08 — sem behavior change)

Fotografia do que foi entregue nas fatias PR-1–PR-6 (libs + suites, sem
ativação de flag, sem claim runtime-real) e do que permanece pendente.
Nenhum número abaixo é runtime-real: são asserts de suite lib/harness.

| PR | Fase(s) | Entrega | Status | Evidência |
|---|---|---|---|---|
| PR-0 | Fase 0 | JOB44 fix + addendum PARTIAL | EM VALIDAÇÃO | commits `dea2b40` + `0f91679`; pendentes: CI HEAD, PR #41, full-74, distribution |
| PR-1 | Fase 1 | AdapterContract | ACTIVE-lib | `scripts/v3/lib/OrchestrationRuntimeAdapterContract.ps1` + tests — **148 PASS**; matriz sem VERIFIED |
| PR-2 | Fase 2 | Executor restrito v6 (ObjectiveRuntime) | ACTIVE-restrito / HOLD-produtivo até gate GoalKernel | `scripts/v3/lib/OrchestrationObjectiveRuntime.ps1` + tests — **175 PASS**; 5 rounds review + security |
| PR-3 | Fases 5–6 | Promotion wiring | ACTIVE | `scripts/v3/lib/OrchestrationGoalPromotionWiring.ps1` + tests — **29 PASS** |
| PR-4 | Fases 4/6 | Decision + Reuse wiring | ACTIVE | `scripts/v3/lib/OrchestrationDecisionWiring.ps1` (**28 PASS**) + `scripts/v3/lib/OrchestrationReuseWiring.ps1` (**31 PASS**, ttl default por classe) |
| PR-5 | Fases 5–6 | Autonomy wiring | ACTIVE | `scripts/v3/lib/OrchestrationAutonomyWiring.ps1` + tests — **54 PASS** |
| PR-6 | Fase 7 | E2E harness + telemetry | TEST-HARNESS | `scripts/v3/lib/OrchestrationCorrectiveE2E.tests.ps1` — **119 PASS** (E2E-01..E2E-15, harness-level, gates G1–G8) + `scripts/v3/lib/OrchestrationObjectiveTelemetry.ps1` (TEST-HARNESS-SUPPORT, sem suite própria; não é ACTIVE produtivo) |
| PR-7 | Fase 8 | Este adendo documental | EM CURSO | plano + matriz + changelog; veredito final é do Planner |

### Gates G0–G8 (evidência + pendências)

- **G0 — PENDENTE:** JOB44 fix local + addendum PARTIAL gravados; pendentes
  full-74, distribution, CI HEAD, PR #41.
- **G1 — LIB-VERDE:** contrato + matriz (PR-1, 148 PASS), nenhum VERIFIED sem
  prova; runtime-real BLOCKED sem provider.
- **G2 — RESTRITO:** executor (PR-2, 175 PASS, 5 rounds + security);
  produtivo HOLD até gate GoalKernel.
- **G3 — PARCIAL:** recovery kernel-side existente (cenários 16/17/19 da lane
  V3.1 2026-10-06); reconciler produtivo segue HOLD.
- **G4 — LIB-VERDE:** decision (28) + reuse (31); autoridade consultiva única
  sem spawn/rede próprios.
- **G5 — LIB-VERDE:** promotion (29) + autonomy (54); loop-guard no executor
  segue no gate G2.
- **G6 — PARCIAL:** checkpoint lib existente + ttl default por classe
  (ReuseWiring); resume cross-session real BLOCKED sem provider.
- **G7 — HARNESS:** E2E 119 PASS harness-level; runtime-real (V1/V2/dual/
  PS5.1/PS7 com OpenCode vivo) BLOCKED sem provider.
- **G8 — ABERTO:** este PR-7 registra o estado; veredito (FINAL/PARTIAL/
  BLOCKED) é do Planner. Pendências consolidadas: full-74, distribution,
  CI HEAD, PR #41, runtime-real BLOCKED sem provider, gate GoalKernel,
  ativações operator-owned. Flags intocadas; tag `v0.1.0` preservada.

### Encerramento PARTIAL (2026-10-08, PR-7 documental — sem behavior change)

- **Veredito: PARTIAL CLOSURE.** Base/contrato/matriz avançam em nível
  lib/harness; wiring produtivo segue HOLD honesto. Não é FINAL nem
  runtime-real: nenhum número abaixo é prova exact-binary-live.
- **Evidência lib/harness (PS5.1+PS7):** suites novas **175 / 148 / 65 /
  28 / 31 / 54 / 29 / 119** PASS; Enforcement **421**; full-V3 **72 PASS
  + 3 DE22307F + 6 SKIP**.
- **Reviews:** PR-2 com 5 rounds; PR-3..PR-6 com reviews finais
  **APPROVED-WITH-HOLD-RESIDUALS**; security finais idem; **zero HIGH
  efetivo** (nenhum HIGH aberto ao encerrar).
- **Gates NO-GO:** distribution **14/21 NO-GO** — 6 FAILs triados
  (5 PRE-EXISTENTE dialeto V1-vs-Auto→V2 de `a445202`/2026-09-28 + 1
  INCONCLUSIVO/ambiental profile-isolation; diff não toca installer —
  `git diff --name-only` vazio nesses paths). CI HEAD + PR #41
  **pendentes**. Runtime-real **BLOCKED sem provider**. Aquisição
  produtiva **HOLD até gate GoalKernel**. Flags intocadas; tag `v0.1.0`
  preservada.
- **HOLDs residuais:** budget cross-process; telemetria
  concorrente/inputs não-controlados; seams caller-provided
  (não-autoridade); redactor heurístico; `runtime_grant_enforcement` OFF.
- **Próximos passos (operador):** corrigir fixtures V1 (`-Runtime V1`) +
  profile-isolation; CI HEAD; PR #41 + merge; gate GoalKernel; ativações
  somente com evidência.
