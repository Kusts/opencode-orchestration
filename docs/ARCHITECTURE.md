# Arquitetura

Fonte canônica da política: `source/global/AGENTS.md` (global) +
`source/adapters/opencode.md` (runtime). Este documento resume; em caso de
divergência, o `source/` vence.

## Visão geral

```
                    ┌─────────────────────────┐
                    │   Planner `build`       │  único control plane;
                    │   (modelo da sessão)    │  decide, decompõe, integra
                    └────────────┬────────────┘
                                 │ preflight obrigatório
                    ┌────────────┴────────────┐
                    │  TRIVIAL_DIRECT /       │
                    │  DELEGATED /            │
                    │  DETERMINISTIC_FALLBACK │
                    │  / BLOCKED              │
                    └────────────┬────────────┘
              ┌────────┬─────────┴──────────┬──────────┐
              │        │                    │          │
     ┌────────┴───┐ ┌──┴───────┐ ┌───────────┴──┐ ┌───┴────────┐
     │ CHEAP pool │ │ STRONG   │ │ PLANNING     │ │ DIAGNOSTIC │
     │ (execução) │ │ pool     │ │ (advisory,   │ │ (validam,  │
     │            │ │ (juízo)  │ │ read-only)   │ │ não editam)│
     └────────────┘ └──────────┘ └──────────────┘ └────────────┘
                                 │ enforcement por sessão
                     ┌────────────┴────────────┐
                     │ plugins/                │
                     │ orchestration-          │  mandato + telemetria
                     │ enforcement (dual v1/v2)│  sanitizada local
                     └─────────────────────────┘
```

O Planner mantém no próprio contexto só objetivo, plano, decisões, estado
e critérios de aceite. Buscas extensas, logs e hipóteses descartadas ficam
nos contextos dos workers. Workers nunca criam subagentes
(`subagent_depth: 1` + `permission.task: deny`).

## Planner único + pools

O Planner `build` é o único control plane: decide arquitetura, decompõe,
seleciona o menor conjunto útil, define ownership, integra evidências e
encerra. `coder` é o implementador padrão; especialistas de domínio só com
profundidade, risco, workstream independente ou paralelização segura.

**Cheap pool** (`{{MODEL_CHEAP}}`, escala horizontal — evidência e volume),
11 workers de execução:

`explorer`, `researcher`, `coder`, `tester`, `docs-manager`,
`frontend-engineer`, `backend-engineer`, `database-engineer`,
`ai-agent-engineer`, `automation-engineer`, `infra-engineer`.

**Strong pool** (`{{MODEL_STRONG}}`, escala vertical — decisões difíceis),
4 workers de juízo:

`reviewer`, `debugger`, `security-reviewer`, `architect`.

**Planning layer** (advisory, read-only, `permission.task: deny`), 4 papéis:

`requirements-analyst`, `engineering-advisor`, `product-designer`,
`skeptic` — no máximo 1 por subtarefa, sem rito obrigatório.

Total: 11 + 4 + 4 = **19 workers delegáveis** (`source/agents/*.md`).
No `templates/opencode.v1.json.tmpl` (V1 ativo; `templates/opencode.v2.json.tmpl` espelha a mesma semantica no shape nativo V2), 15 têm bloco `agent.*`; os 4 de planning
vivem só nos `.md` + allowlist do `build` (by design — ver check 3 de
`scripts/test-package-consistency.ps1`). `agent.build.model` nunca existe:
o Planner herda o modelo da sessão.

## Mandatory Preflight (4 estados)

Toda tarefa passa pelo preflight **antes** da primeira ação
(`scripts/v3/orchestration-preflight.ps1`, lib em `scripts/v3/lib/`):

| Estado | Significado |
|---|---|
| `TRIVIAL_DIRECT` | Só com reason token fechado (`DIRECT_TRIVIAL_LOCALIZED`, `DIRECT_READ_ONLY_POINT_LOOKUP`, `DIRECT_COSMETIC_NO_LOGIC`, `DIRECT_FORMATTING_ONLY`). Texto livre não é bypass válido. |
| `DELEGATED` | Pré-decisão que planeja (`UNVERIFIED_POST_EXECUTION_REQUIRED`); compliance só no DONE gate. |
| `DETERMINISTIC_FALLBACK` | Router/registry indisponível, stale, exceção, timeout ou resposta malformada — nunca execução solitária. |
| `BLOCKED` | Não prosseguir; devolver ao usuário. |

Tarefa não trivial exige participação material de ao menos 1 subagent
adequado. `non-trivial + participação = 0` produz
`ORCHESTRATION_POLICY_BYPASS`: sem `DONE` compliant.

## DONE gate

`DONE` = requisitos atendidos, critérios verificados, comportamento
validado, checks executados, integração verificada, findings resolvidos ou
conscientemente aceitos, review encerrado, riscos residuais conhecidos,
nenhuma unidade essencial esquecida. Atestação via participação observada
(`Test-OrchestrationDoneCompliance`); mensagem de sucesso de worker nunca é
prova. Ciclo padrão: `coder → tester → reviewer` (+ `security-reviewer`
quando a policy disparar). Após 2 tentativas sem êxito: `debugger` com
evidência nova; se incerteza estrutural, `architect`. 3ª tentativa só com
hipótese, informação ou estratégia nova.

## Wave + Barrier

`DISPATCH WAVE` → workers independentes → aguardar resultados necessários
→ `BARRIER` → uma síntese do Planner → próxima decisão. Limites padrão:
até 3 cheap simultâneos (burst 4 se genuinamente independentes); até 2
Coders só com ownership explícita de arquivos diferentes; até 3 Testers sem
fixtures/portas/banco compartilhados incompatíveis; 1 strong por decisão
(exceção: Reviewer + Security Reviewer read-only em paralelo).
Discovery (Explorer/Researcher) é o melhor candidato a fan-out, dividido
por domínios reais.

## Dispatch Contract

Toda delegação não trivial carrega: `TASK_ID`, `OBJECTIVE`,
`DEPENDENCIES`, `BASE_REVISION` (quando Git concorrente importar),
`READ_SCOPE`, `WRITE_SCOPE` (vazio para read-only),
`ACCEPTANCE_CRITERIA`, `VALIDATION`, `PROHIBITED_OPERATIONS`,
`RETURN_FORMAT`, `ESCALATION_CONDITIONS`. Com escrita ou shell sensível,
inclua `ALLOWED_ENVIRONMENT`, `PRODUCTION_AUTHORIZED` (ausência = `false`;
`true` sozinho não autoriza destruição nem credenciais) e
`CREDENTIAL_SCOPE` (só identificadores/perfis, nunca segredos). O worker
não amplia esses campos por inferência; diante do não coberto, interrompe
e devolve ao Planner. Retorno compacto (`TASK_ID`, `STATUS`,
`KEY_FINDINGS`, `EVIDENCE`, `VALIDATION`, `BLOCKERS`, `RISKS`,
`RECOMMENDATION`); Reviewer termina `APPROVED`/`CHANGES_REQUIRED`, Tester
`PASS`/`FAIL`.

## V3 (router, registry, flags)

- **Router shadow/off por padrão**: `source/registry/capability-flags.json`
  tem `capability_router.shadow=false`, `active=false`,
  `skill_routing`/`mcp_routing`/`adaptive_ranking=false`. A política
  determinística decide; o Router (`scripts/v3/route-accept.ps1`,
  `scripts/v3/shadow-route.ps1`, bridge `scripts/v3/skill-bridge.ps1`) só
  observa/propõe como **dado**, nunca como instrução — sem autoridade,
  sem carregar skills, sem habilitar MCPs.
- **Registry distribuída**: `source/registry/` (`capability-flags.json`,
  `capability-policy.json`, `runtimes.json`) — curada, versionada, parseável.
  Trust/risco vêm **exclusivamente** da policy; frontmatter contribui só
  descrição/capacidades candidatas.
- **`build-capability-registry` → cache opt-in**:
  `scripts/v3/build-capability-registry.ps1` faz probe de
  `source/agents/*.md` + policy e escreve `cache/v3/capability-registry.json`
  (ignorado pelo git). Sem registry gerada, o sistema usa fallback
  determinístico — nada quebra.
- **Safe-by-default**: toda flag de roteamento nasce `false`; ativação é
  decisão humana explícita com registro (gate-closure), nunca inferência.
  A mesma doutrina vale para as flags de rollout do V3.1 (nascem
  OFF/shadow); o que existe hoje é o **lote autorizado pelo operador em
  2026-10-04** — 6 flags ativadas com evidência registrada
  (`evidence/v3.1/runtime-reliability/flag-activation-batch-2026-10-04.json`),
  com `runtime_grant_enforcement{v1,v2}` deliberadamente OFF (Phase 5).
- **V3 em maintenance mode**: sem V4, sem novas phases/flags/frameworks.
  Reabre só por bug observado, capability nova do runtime, telemetria
  recorrente `WRONG`/`SUBOPTIMAL`/`BYPASS`, mudança de modelo/runtime ou
  evidência que retire um HOLD/BLOCKED. **Exceção ativa**: o programa
  V3.1 (abaixo) — classes `RUNTIME_COMPATIBILITY` +
  `FEATURE_REEVALUATION` — não reabre o router/flags da V3.

## Dual-runtime (V3.1, em andamento)

A orquestração é canônica; a sintaxe de cada geração é adaptação
(`docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md`):

- **Registry de runtimes** (`source/registry/runtimes.json`): descritores
  `opencode-v1` e `opencode-v2` com dialeto de config/permissões, pacote de
  plugin, chaves geridas e raiz de render. Detecção determinística
  (`scripts/runtime/`):
  `RuntimeAdapters.ps1` (probe, geração, fail-closed) +
  `detect-opencode-runtime.ps1`.
- **Pins de runtime/tool — fonte única canônica**:
  `source/registry/runtime-versions.json` (`runtimes.v1/v2`,
  `plugins.v1/v2`, `tools.bun`) com loader fail-closed
  `scripts/runtime/lib/RuntimeVersions.ps1`
  (`Get-OrchestrationRuntimeVersion`, sem fallback para literal: registry
  ausente/ilegível/inválido ⇒ throw). Bump de versão = editar **só** esse
  arquivo + revalidação no runtime exato; smokes, perfis, typecheck e o
  workflow de CI resolvem os pins por ele. `runtimes.json` guarda os
  descritores (e a história), não o pin.
- **Render nativo por geração**: `templates/opencode.v1.json.tmpl`
  (`agent`/`permission`/`task`/`subagent_depth`) e
  `templates/opencode.v2.json.tmpl` (`agents`/`permissions` ordenadas
  broad-first/`subagent`/`experimental.subagent_depth`); tradução dos 19
  agents por `AgentTranslator.ps1` (paridade validada pelos checks 12–15).
- **Installer runtime-aware**: `install.ps1 -Runtime Auto|V1|V2|Both`
  (Auto faz probe e falha fechado; manifest grava o runtime) e
  `uninstall.ps1 -Runtime Auto|V1|V2` (conflito explícito, exit 6).
- **Perfis isolados**: V1+V2 na mesma máquina com config root por perfil
  (`XDG_CONFIG_HOME` por processo, provado em
  `evidence/v3.1/kernel-hardening/runtime-isolation-spike.json`) e
  wrappers `opencode-v1.ps1`/`opencode-v2.ps1`.
- **Plugin dual-runtime**: fonte única (`v1.ts`/`v2.ts`/`shared/`,
  dual-export `{id, setup, server}`), bundle `plugins/dist/`
  `orchestration-enforcement.js` + sidecar sha256.
- **Task Kernel (Phases 9–19, implementado)**: estado de tarefa
  persistente em `cache/runtime/tasks/` com CAS (lock interprocesso),
  transições legais e terminais imutáveis; grants por interseção
  (`source/registry/execution-grants.json`); Evidence Contract
  (`candidate_pass|failed|blocked` — worker nunca atesta verificação);
  verifier com allowlist fechada (`OrchestrationVerifier.ps1` +
  `verification-policy.json`); `DONE` só via `Complete-OrchestrationTask`
  (gate próprio, só de `REVIEWING`, retry com debugger/evidência nova);
  write leases (`cache/runtime/locks/`) e worktrees por tarefa com marker
  de ownership. Eventos TASK_*/LEASE_*/VERIFICATION_*/REVIEW_* na
  telemetria (29 tipos) com dimensão runtime.
- **Pendente** (honesto): enforcement **comportamental** V2
  (`experimental.policies`, precedência de regras no runtime real) —
  spike travou em `debug config/agents` do V2 (HOLD registrado em
  `evidence/v3.1/kernel-hardening/runtime-binding.json`; binário histórico
  do spike citado como `2.0.18` no próprio spike); smoke de
  binário V2 na lane CI — lifecycle **PASS no runner** em 2026-10-04
  (run 37193122170), lane real de watchdog **7/7 `pass-real` no runner**
  em 2026-10-05 (run `37376248759`); o smoke implícito (`debug config`,
  flake upstream) virou observação `continue-on-error` e o job V2 segue
  com esse probe observacional, não "totalmente verde"; flags:
  `task_kernel`, `watchdog`, `bounded_execution`, `worktree_isolation`,
  `runtime_support.v2/dual_profile` e `jev_advisory` **ativadas** em
  2026-10-04 com evidência, enquanto `runtime_grant_enforcement{v1,v2}`
  segue OFF (Phase 5 — nenhum hard-deny antes da validação
  comportamental).

## Confiabilidade de runtime (V3.1 Phases 21-42 (revisão 2026-10-01, reconciliada em 2026-10-05; closure 2026-10-06: release gate PASS com residuais operator-owned) - P21-P25 consolidadas, P26-P42 code-complete kernel-side/plugin com provas runtime-real nas lanes 04..10 e 16..22)

**Status 2026-10-02/03:** programa **code-complete** nas fatias
kernel-side/plugin — Waves A–E implementadas via ciclo
coder → tester → reviewer (+ security) com APPROVED por slice.
**Atualização 2026-10-05 (reconciliação documental):** flags de rollout
ativadas pelo operador em 2026-10-04; transporte HTTP real do Jev (P29-S2)
e wiring do chamador no Planner loop (P38-S2) entregues; backstop de Job
Object ligado ao enforcement do watchdog (P26-JOB-WIRING); lane real
RR-E2E-04..10 **7/7 `pass-real` no runner** (run `37376248759`, 2026-10-05)
e no mesmo run o smoke implícito falhou com `debug config: TIMEOUT 30s`
(flake upstream) e foi formalizado como observação
`continue-on-error: true`; pins migrados para o registry
canônico `source/registry/runtime-versions.json`; o que resta é evidência
do operador (release gate), não código.
Bibliotecas novas em `scripts/v3/lib/`:
`OrchestrationMcpSafety` (envelope bounded + circuit breaker),
`OrchestrationJevAdvisory` (Jev como advisory, flag `jev_advisory` — ativa
desde 2026-10-04),
`OrchestrationAiMemoryRemote` (dependência remota bounded),
`OrchestrationBootstrapContext`, bindings CAS dentro de
`OrchestrationTaskKernel` (sem lib própria), `OrchestrationSessionReconciler`
(Continuation Envelope), `OrchestrationExecutionModes`,
`OrchestrationEvidenceStore` (reuse), `OrchestrationValidationPolicy`
(L0–L3), `OrchestrationSimplicityPolicy`, `OrchestrationPlannerLoop`,
`OrchestrationDispatchPipeline` (record-only), `OrchestrationCapabilityDoctor`,
`OrchestrationV2NativeGating`
(todas as features hold-unproven), `OrchestrationV2EvidenceSupersession`
(decision-record only), `OrchestrationEvolutionLoop`
(observacional), `OrchestrationE2eManifest` e o transporte MCP no plugin
(`plugins/orchestration-enforcement/shared/mcp-transport.ts`,
shadow default). E2E manifest com 41 cenários classificados
(18 sintéticos pass, 23 blocked honestos — aritmética reconciliada com
`phase42.json#honest_counts`).

Programa em andamento, com estado vivo em
`evidence/v3.1/runtime-reliability/program-status.json`; especificado em
[Runtime Reliability SPEC addendum](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md),
planejado em [Plan addendum](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md),
com execução descrita em [Implementation prompt](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md):

- **P21 done (baseline)**: pins V1/V2 presentes, listener `49374`
  diagnosticado por PID (Docker/ssh; registro da então — **identidade
  corrigida em 2026-10-03**: `49374` **não é AI Memory**, é o serviço de
  fundo do V2 CLI, `opencode.exe serve --service` do npm global, respawnado
  a cada sessão/restart; nunca mutado aqui); fixtures de
  watchdog **17/17 PASS** (PS5.1 e PS7), record-only, sem enforcement
  (`evidence/v3.1/runtime-reliability/baseline.json` + `fixtures/`).
- **P22 parcial-HOLD (port/process preflight)**: preflight
  determinístico (`scripts/runtime/RuntimePortPreflight.ps1`, 6
  outcomes, exits 0/1/2) + wrapper V2 com startup condicionado a
  configuração verificada + `PORT_FREE`; E2E nativo alternativo provado
  em perfil isolado (16/16 steps, `candidate_pass`,
  `native-start-contract.json`); diagnóstico real do `49374`
  (Docker/ssh por PID, nunca mutado). HOLDs: `REUSE`, wrapper
  produtivo `UNVERIFIED`, cleanup de descendants sem prova, set/start
  nativo só com `RR_P22_RUN_NATIVE=1`.
- **P23 done-record-only (budgets)**: orçamentos canônicos no kernel
  (5 perfis: worker 45m, planner 90m, steps 96, soft 3 / hard 5),
  sem ampliação pelo worker, planner-turn por input novo, CLI
   `scripts/v3/task-kernel.ps1`; kernel pré-existente **75/75**
   preservado. Sem enforcement (P26+); native step em HOLD.
- **P24 parcial (plugin/session lifecycle)**: plugin V2 migrado para
  `event.subscribe` abort-safe
  (`plugins/orchestration-enforcement/v2.ts`); live-hook no binário
   exato 2.0.18 (`phase24-livehook.jsonl`, 8 linhas): plugin carrega,
  `session.created` VERIFIED, context VERIFIED, `execute.before` e
  `session.updated` NOT-VERIFIED com causa, interrupt/wait com presença
  verificada e semântica intacta para a Phase 25. Suítes: typecheck
   V1+V2+DUAL, dual-runtime **20/20**, mock V2 **22/22** (10c +
   10c-controle com discriminação), V1 **30/30**,
   live-hook PS5.1 **35/0 HOLD 1** (trigger real com session==trigger,
    match=True) / PS7 **23/0 HOLD 4**; REV-FIX com 3
    findings + TRIGGER-FIX com 4 findings corrigidos.
- **P25 done-shadow (watchdog)**: RuntimeWatchdog lib shadow puro
  (`scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1`): registra
  execução, fingerprints sanitizados por campo com framing
  `len:valor`, semântica de repetição da policy, avaliação
  `HARD_TIMEOUT`/`NO_PROGRESS`/`REPEATED_ACTION`/`CYCLE`/
  `BUDGET_NEAR_LIMIT` em modo shadow (would-interrupt, execução
  intacta, sem task record), telemetria JSONL bounded com lock
  in-process e cap fail-closed, identidade obrigatória, flag
  `watchdog{enabled:false, shadow:true}` **naquela fatia**; `enabled=true`
  sem binding de processo provado retorna
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED` (esse é o token do registro sem
  binding, não o estado atual da flag — ver subsection seguinte).
  Suítes: watchdog
  **80/80** (PS5.1 + PS7), kernel **75/75**, consistência **16/16**;
  reviews Reviewer **APPROVED** (REV4) + Security **APPROVED**
  (SEC3). Follow-ups documentados: lock cross-process, retenção
  multi-dia; o caminho de interrupt real está na subsection de P26
  abaixo.

### Capacidades entregues em P26–P42 (kernel-side/plugin, 2026-10-02/03)

As subseções abaixo registram o que existe no código e seus limites
honestos. O que elas descrevem é **capacidade entregue**, não autorização:
as flags de rollout do programa foram **ativadas em 2026-10-04** pelo
operador com evidência registrada (exceto
`runtime_grant_enforcement{v1,v2}`, que segue OFF — HOLD sustentado por
evidência real na closure 2026-10-06: deny não enforceado na superfície
`/shell` do 2.0.23), e o release gate foi decidido `PASS` em 2026-10-06
com residuais exclusivamente operator-owned.

#### Watchdog: shadow + caminho de enforcement (P25/P26)

P25 entrega a biblioteca em modo shadow puro; P26 entrega o caminho de
interrupção real (identidade exata `pid`+creation-ticks, prova de vida
coletada na validação, kill pelo handle pinado da instância verificada,
árvore via snapshot CIM com caps fail-closed e seam `SETTLEMENT_REQUIRED`
no kernel). **Atualização 2026-10-04/05:** a flag `watchdog` foi ativada
pelo operador (lote 2026-10-04, `enabled:true, shadow:false`); o
enforcement consumiu o Job Object da P22 (contrato A, "attach-side"):
job anônimo `-NoKillOnClose` criado após os gates de identidade e
atribuído à raiz verificada ANTES do snapshot (seam
`Attach-RuntimeJobVerifiedProcess` — handle caller-proven, nunca
`OpenProcess` por PID), kill CIM de descendentes verificados seguido de
`TerminateJobObject` como backstop (fecha o escape de spawn
pós-snapshot), revalidação de deadline imediatamente antes do ato letal,
fallback CIM-only fail-closed com `job_attach=refused:*` quando o attach
é recusado, e decisão terminal que separa ato letal aplicado (booleano)
de contagem de mortos (só CIM). Limites residuais (HOLDs honestos):
janela gate→`TerminateJobObject` nativo (API sem deadline), preempção
entre checagem e chamada, descendentes pré-attach cobertos só pelo kill
CIM, interrupt de sessão V2 nativa (runtime API) não implementado, e
ator/fonte seguem strings declaradas pelo chamador. Cenários reais
RR-E2E-04..10 provados 7/7 `pass-real` na lane
`evidence/v3.1/runtime-reliability/v2-lane-2026-10-04/`. Evidência:
`evidence/v3.1/runtime-reliability/phase25.json`, `phase26.json`.

#### MCP safety e transporte (P28)

Envelope bounded + circuit breaker kernel-side com policy canônica
fail-closed (`source/registry/mcp-request-policy.json`) e envelope de
transporte no plugin TS (`shared/mcp-transport.ts`) em **shadow
default** — observa, nunca altera admissão sem opt-in explícito.
`mcp_routing` segue OFF. Limites: enforcement em binário real V2 não
validado, V1 observe-only e locks in-process. Evidência:
`evidence/v3.1/runtime-reliability/phase28.json`.

#### Jev advisory kernel-side + guard de autoridade (P29)

Jev entra como **consultivo** com tool set fechado, budget 30s, probe
10s, circuito 2/300s e criticality `optional` (`JEV_UNAVAILABLE` ⇒
fallback determinístico). O guard de autoridade é sempre-nega: deny do
kernel vence allow do Jev e falha do verifier vence "complete" do Jev.
A flag nasceu OFF/shadow e foi **ativada pelo operador em 2026-10-04**
(`{enabled:true, shadow:false}`, decisão com evidência). **Atualização
2026-10-05:** o transporte **HTTP real** kernel-side foi entregue na
fatia 2 (P29-S2 — `POST` no endpoint user-owned por env, https ou
loopback, cap de leitura, tokens fechados de falha, **falha nunca vira
advisory OK**) e o **wiring do chamador no Planner loop** foi entregue
em P38-S2 (commit `4cfb26a`: uma chamada quando o trigger diz
`should_consult=true`, resultado anexado como
`authoritative=false`/`recommendation_only=true`, falha ⇒ fallback
determinístico). Limites restantes: probe contra endpoint real com chave
real é evidência operator-owned (exact-runtime), e o Jev nunca concede
autoridade (guard sempre-nega). Evidência: `phase29.json`,
`phase29-transport-s2.json`.

#### AI Memory remoto como dependência (P30)

Policy com endpoint **user-owned**
(`source/registry/ai-memory-remote-policy.json`), `tls_verify` fixo e
HTTPS obrigatório antes de transporte real, retrieval 60s / health 10s,
circuito reusando o envelope P28 e modo **remote-only por config**.
Limites: ausência de config ⇒ `AIMEMORY_UNCONFIGURED` (optional
continua, required bloqueia tipado) e **nunca** fallback silencioso para
o listener local `49374` (que **não é AI Memory**: é o serviço de fundo
do V2 CLI). Estado real: o AI Memory PROD do operador **já roda em
servidor remoto próprio** (deploy executado pelo operador antes de
2026-10-01; config user-owned fora do repo **confirmada** em 2026-10-04
e round-trip remoto autenticado comprovado com serviço saudável,
97 ms — `aimem-health-repreflight-2026-10-04.json`, sem
identidade do servidor no repo). Pendência honesta restante: apenas o
probe HTTPS dedicado contra o endpoint, separado do round-trip MCP
(`aimem-health-repreflight-2026-10-04.json`: `tls_note`);
`REUSE` da P22 continua HOLD. Evidência:
`evidence/v3.1/runtime-reliability/phase30.json`.

#### Bootstrap context e wiring de arranque (P31)

Builder read-only e parse-only (nunca executa processo/scripts) com
seções project/runtime/capability_health/tasks/pending_waits/jev_status/
aimemory_status, byte budget com sequência única de descarte e clock
injetável; `scripts/runtime/SessionBootstrapContext.ps1` expõe o
componente como CLI hook-style **fail-open total**. Limites: nada é
registrado nem instalado — auto-start do plugin, AGENTS.md global,
`default_agent` e o registro do hook no arranque real são decisão do
operador. Evidência: `evidence/v3.1/runtime-reliability/phase31.json`.

#### Bindings Task/Run/Seat/Session (P32)

Seção `bindings` opcional e backward-compatible no kernel, com
`bind`/`rebind`/`detach` sob o lock CAS existente, um único
`active_execution_owner` por task, rebind só em sessão equivalente ou run
detached e CLI com 4 subcomandos (ambiguidade ⇒ exit 2 fail-closed). O
kernel permanece única fonte de verdade. Limites: coordenação
cross-process em HOLD (single-writer in-process) e integração com
plugin/runtime real fora do slice. Evidência:
`evidence/v3.1/runtime-reliability/phase32.json`.

#### Reconciler de sessão + Continuation Envelope (P33)

Continuation Envelope bounded em 8KB (objective, intent, decisões,
evidências, estratégias falhadas sem transcripts, riscos, typed waits,
next move) com redator compartilhado em todos os campos string, e
`SESSION_LOST` tipado por declared missing + proof sem mutar task. O
reconciler é determinístico sobre os bindings P32 e produz ações
**recomendadas** (reattach via CLI, recover-output, inspect-interrupted)
— nunca faz probe nem kill. Limites: reconciler V2 nativo e probe real de
sessão em HOLD (estados declarados pelo caller confiável). Evidência:
`evidence/v3.1/runtime-reliability/phase33.json`.

#### Execution modes A/B/C (P34)

Decisão pura e determinística entre **A** (deterministic workflow), **B**
(persistent specialist) e **C** (one-shot). O modo B é duplamente gated
(policy `specialist_enabled: false` por default + `runtime_caps` OFF) e o
resultado distingue `fallback_from` `policy-off` de
`runtime-unsupported`; `team_size` sozinho nunca decide. Limites:
primitiva runtime de specialist em HOLD e wiring no Planner fora do slice
(P38). Evidência: `evidence/v3.1/runtime-reliability/phase34.json`.

#### Evidence reuse store (P35)

Store file-based de reuso de evidência com identidade/provenance
obrigatórios, fingerprints SHA-256, validade por
fingerprints/criteria/revision-policy/ttl invariante, query compacta sem
raw, retrieval com containment do store-root + reparse-point walk +
streaming cap e métricas consultáveis. Limites: sem daemon nem database,
e a integração com o dispatch real é do fluxo P38. Evidência:
`evidence/v3.1/runtime-reliability/phase35.json`.

#### Validação adaptativa L0–L3 (P36)

Policy como autoridade fail-closed: hard triggers incontornáveis
varrendo domain/operation/summary e completion gate com
`effective_level = max` (risco desconhecido ⇒ L3), cobertura exigindo o
conjunto completo de fingerprints com a semântica de validade do P35 e
ledger de cobertura de segurança (`confirmed`/`needs-validation`).
Limites: wiring no fluxo de dispatch/completion é do P38 e a allowlist de
`verified_pass` permanece a do kernel. Evidência:
`evidence/v3.1/runtime-reliability/phase36.json`.

#### Disciplina de simplicidade (P37)

Builder de campos de contrato (MSC/NBW/RBC/ABE/stop-condition/NON_GOALS/
PRESERVE/blast-radius) com budget normalizado e sanitizado,
`ChangeBudget` soft 1x / hard 2x com rationale obrigatório
(`CHANGE_BUDGET_EXCEEDED`) e checklist de Reviewer **assistida** e
determinística. Limites: a edição dos prompts canônicos em
`source/agents/*.md` é decisão do operador (este pacote não a faz) e o
wiring no dispatch é do P38. Evidência:
`evidence/v3.1/runtime-reliability/phase37.json`.

#### Planner loop e dispatch pipeline record-only (P38)

O planner loop adaptativo encadeia Frame → Reuse → Simplicity → Risk →
mode → budget → dispatch → gaps → complete reusando P29/P34–P37 e
produz um `PLAN RECORD` com cap 8KB garantido (descarte ordenado,
envelope mínimo sempre válido, nunca substring-cut). O dispatch pipeline
kernel-side consome esse record e produz o bundle de despacho: contratos
de worker derivados só de plan+descriptor declarado, no-widen,
sequenciamento parallel apenas com booleano real e gate de completion do
P36 fail-closed. Limites: **record-only** — o gate valida shape, não
autenticidade de proveniência, e `DONE`/`verified_pass` permanece
kernel-side; spawn real de workers é decisão do operador. Evidência:
`evidence/v3.1/runtime-reliability/phase38.json`.

#### Capability doctor (P39)

Descritores de capacidade com schema validation tipada (booleano
estrito) e doctor **read-only** com probes sintéticos injetáveis (budget
é metadado honesto, não medição real), fallback que valida o destino e
`risk_class` execution/authority sem health ⇒ typed blocker.
**Atualização 2026-10-04:** o **jevgrep real** foi instalado e executado
com consult semântico comprovado (`jg` sobre OpenCode Zen;
`evidence/v3.1/runtime-reliability/jevgrep-install-2026-10-04.json`).
Limites: o **flip de policy** `platform_support.windows=true` e as
asserts do doctor já estão na base (`capability-doctor-policy.json`;
`OrchestrationE2eManifest.tests.ps1` exige fallback com probe unhealthy) —
resta apenas probe real de transporte contra endpoint real
(operator-owned) e instalação automática fora de escopo.
Evidência: `evidence/v3.1/runtime-reliability/phase39.json`.

#### Gating de capacidades nativas do V2 (P40)

Registry data-driven das 8 features candidatas, **todas hold-unproven**,
com `required_evidence` e `v1_fallback`; gating estritamente fail-closed
(`enabled` só com evidência `exact-binary-live` validada: feature, pin
exato do registry canônico `source/registry/runtime-versions.json`
(`2.0.18` na fatia original), scenario exact-match + SHA-256 e timestamp
RFC3339 com offset). A
fatia 2 acrescenta o revisor de supersessão de evidências
(`OrchestrationV2EvidenceSupersession.ps1`), **decision-record only** (zero
escrita, zero habilitação). Limites: toda ativação exige prova no binário
do pin vigente no ambiente do operador, e o append/enable do registro é
decisão dele. Evidência:
`evidence/v3.1/runtime-reliability/phase40.json`.

#### Evolution loop e telemetria observacional (P41)

Loop observacional com sinais de leitura incremental orçada,
`EVOLUTION_CANDIDATE` content-addressed (threshold + refs distintos), eval
offline que retorna inconclusivo com cobertura incompleta e promoção
explícita one-at-a-time com enumeração fail-closed. A fatia 2 entrega o
produtor de telemetria, que deriva os contadores declarados na policy real
a partir de fontes reais (task records do kernel, JSONL do watchdog,
reuse-metrics do P35) e marca **ausente com razão** o que não tem fonte —
nunca fabrica número. Limites: wiring de chamador em produção e o `apply`
de mudança promovida (fluxo revisado) são do operador. Evidência:
`evidence/v3.1/runtime-reliability/phase41.json`.

### Mecanismos-alvo do programa (desenho vigente; as capacidades P26–P42
já existem em código e foram ativadas em 2026-10-04 com evidência, exceto
`runtime_grant_enforcement`)

- **Execução limitada (bounded execution)**: todo attempt ativo passa a
  ter orçamento canônico (`execution_budget`: steps, wall-clock,
  no-progress) por perfil (`fast`, `standard-read`, `standard-write`,
  `deep`, `planner-turn`); worker nunca amplia o próprio orçamento.
- **Watchdog + Loop Guard**: supervisão de progresso significativo,
  deadlines, detecção de ação repetida (soft 3 / hard 5) e ciclos curtos
  (2–4 ações, 3 repetições), interrupção com evidência parcial preservada
  e `Recovery Context` exigindo estratégia nova (Debugger na 2ª
  falha Stall, `EXHAUSTED` na 3ª sem novidade). Semáforos atuais de
  retry/escalation permanecem autoritativos.
- **Port/process preflight V2** (`PORT_FREE`, `PORT_OCCUPIED_OTHER_PROCESS`,
  `PORT_WINDOWS_EXCLUDED`, etc.): diagnóstico determinístico de
  propriedade de porta antes do hang opaco de startup; nunca mata PID
  desconhecido automaticamente.
- **MCP safety**: budgets por classe (advisory 30s, memory 60s, remoto
  geral 120s) + circuit breaker (2 falhas consecutivas abrem o circuito);
  roteamento MCP genérico segue desligado.
- **AI Memory remoto**: tratado como dependência remota com health check
  limitado e `MEMORY_UNAVAILABLE` limitado. A migração para servidor
  próprio do operador foi **executada** (AI Memory PROD remoto; o
  `127.0.0.1:49374` local **não é AI Memory** — é o serviço de fundo do
  V2 CLI, respawnado a cada sessão/restart, nunca mutado aqui); a config
  user-owned fora do repo está **confirmada** (2026-10-04) e o
  round-trip remoto autenticado foi comprovado
  (`aimem-health-repreflight-2026-10-04.json`); resta só o probe HTTPS
  dedicado, separado do round-trip MCP, e nenhuma identidade no repo.
- **Jev advisory**: somente consultivo (`jev_advisory` ATIVA em
  2026-10-04, decisão do operador, commit `cca566f`), nunca autoriza
  ações, concede permissões, sobrescreve Reviewer/Security
  Reviewer/verificação/DONE; indisponibilidade retorna `JEV_UNAVAILABLE`
  limitado sem retry infinito. Transporte HTTP real kernel-side
  (P29-S2, 2026-10-05): https-ou-loopback obrigatório, endpoint/modelo
  user-owned por env (`JEV_BASE_URL`/`JEV_MODEL` — só nomes no
  registry), projeção tipada fechada por tool (decide ancorado na
  pergunta enviada: type igual e choice dentro das criteria; gate
  limitado a allow|confirm|block), tokens fechados de falha (nenhum
  advisory OK em 3xx/5xx/401/malformed/truncado), budget/circuito pelo
  envelope P28 (advisory 30s, circuito 2/300s); wiring do chamador no
  Planner loop entregue em 2026-10-05 (P38-S2, commit `4cfb26a`) — uma
  chamada quando o trigger é determinístico, resultado
  `recommendation_only`, falha ⇒ fallback determinístico; probe contra
  endpoint REAL com chave real segue evidência operator-owned
  (exact-runtime, mesma doutrina da ativação de flags).
- **Programa P26–P42 (revisão 2026-10-01)**: as capacidades listadas
  acima (persistent bootstrap, reconciler + continuation envelope,
  execution modes, evidence reuse, validação adaptativa, capability
  doctor, evolution e E2E/release) existem em código desde 2026-10-02/03.

Limites honestos: flags de rollout ativadas pelo operador em 2026-10-04
(commit `cca566f`, evidência e holds em
`evidence/v3.1/runtime-reliability/flag-activation-batch-2026-10-04.json`):
`jev_advisory`, `watchdog`, `task_kernel`, `bounded_execution`,
`worktree_isolation` e `runtime_support.v2`+`dual_profile`.
`runtime_grant_enforcement{v1,v2}` segue OFF (doutrina Phase 5: nenhum
hard-deny antes de validação comportamental no runtime V2 real);
`skill_routing`/`mcp_routing`/`adaptive_ranking` seguem OFF (doutrina);
o enforcement
comportamental V2 (Phase 5) depende do runtime real; AI Memory remoto
em PROD (deploy do operador) com config user-owned fora do repo
confirmada em 2026-10-04 e round-trip remoto autenticado comprovado
(`aimem-health-repreflight-2026-10-04.json`) **e probe HTTPS dedicado
real** (`transport-probe-aimem-https-2026-10-06.json`: TLS 1.3, 401
fail-closed sem token, host sanitizado); o
release gate foi **fechado como `PASS` em 2026-10-06** (closure V3.1,
`program-status.json#closure_2026_10_06`): **RR-E2E-04..10 7/7
`pass-real` no runner** em 2026-10-05 (run `37376248759`, lane fechada
após o fix de contaminação `7b527d8`) e **RR-E2E-16..22: 5 `pass-real`
(16, 17, 19, 20, 21) + 2 `blocked`-parciais (18, 22, model-dependent com
pernas alternativas provadas em runtime)** em runtime real 2.0.23 (lane
`scripts/ci/session-real-lane-v2.ps1`, evidência em
`session-lane-2026-10-06/`); `debug config` com
intermitência caracterizada experimentalmente (7 hangs vs 5 passes no
mesmo dia; suspeita principal interna ao binário histórico 2.0.18, não
comprovada; `debugcfg-hang-investigation.json`) — no run de 2026-10-05 ele
falhou com `TIMEOUT 30s` e foi formalizado como observação
`continue-on-error: true` (validado: o erro segue visível e a lane real
segue sendo o gate; run `37380530324` 5/5 verde); probes V2-native
coletados em runtime real (`v2-native-probes.json`: narrowing fail-open
na superfície `/shell`, demais ambiguous) ⇒ **decisão formal
`runtime_grant_enforcement.v2` = HOLD (OFF)** e as 8 features permanecem
`hold-unproven` COM coleta real; wirings com componente runtime-proven e
ativação operator-owned — P31-S2 (registro no arranque real),
P38-S2-SPAWN (spawn real do despacho, record-only por decisão; o ID
P38-S2 designa o wiring do chamador Jev, entregue em `4cfb26a`), P41-S2
(produtor em produção) e P40-S2 (append/enable, decisão do operador).
Residuais exclusivamente decisões do operador (ver
`program-status.json#closure_2026_10_06.release_gate.residual_operator_decisions`).
Revisões Reviewer + Security Reviewer com APPROVED
por slice (HOLDs registrados); critérios `PAE-01`–`PAE-40` rastreados em
`evidence/v3.1/runtime-reliability/pae-traceability.json` (linhas com
`activation-pending`/`blocked-operator-evidence` históricas foram
superseded pelo closure de 2026-10-06 onde o item virou prova real ou
HOLD sustentado — status vivo é `program-status.json`).

## Ownership model do installer (PACKAGE/USER)

O instalador (`install.ps1`) só gerencia o que é do pacote: bloco markered
do `AGENTS.md`, 19 `.md` de agents, plugin, skills-core e as chaves do
sistema no config (`$schema`, `model`, `default_agent`, `subagent_depth`,
`agent.*` — em `opencode.json` ou `opencode.jsonc`, respeitando a
precedência do runtime: jsonc vence quando ambos existem, igual ao
OpenCode V1). Tudo do usuário fora disso (`mcp.*`, `autoupdate`,
`skills.paths`, `plugin`, agents custom, chaves desconhecidas, conteúdo
fora dos markers) é preservado por merge estrutural — essas chaves nunca
são escritas nem removidas. `~/.opencode-orchestration/manifest.json`
registra hashes e snapshot do que foi instalado; o `uninstall.ps1` só
remove o que está intacto (hash confere) e mantém o resto com `KEEP` +
aviso. Ver [INSTALLATION.md](INSTALLATION.md).

## Permissões e shell

Classes (read-only / writer-shell / writer-no-shell / diagnostic),
barreiras (runtime / prompt / planner) e limitações declaradas do matching
`bash:` vivem em [PERMISSIONS.md](PERMISSIONS.md) — referência normativa
para tudo que envolve shell.
