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
  `opencode-v1` (validado 1.18.32) e `opencode-v2` (validado 2.0.18) com
  dialeto de config/permissões, pacote de plugin, chaves geridas e raiz de
  render. Detecção determinística (`scripts/runtime/`):
  `RuntimeAdapters.ps1` (probe, geração, fail-closed) +
  `detect-opencode-runtime.ps1`.
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
  spike travou em `debug config/agents` do V2 2.0.18 (HOLD registrado em
  `evidence/v3.1/kernel-hardening/runtime-binding.json`); smoke de
  binário V2 na lane CI `ci-v2-lane`; ativação das flags
  (`task_kernel`/`worktree_isolation`/`runtime_grant_enforcement`
  nascem OFF — shadow rollout, ativação é decisão humana com evidência).

## Confiabilidade de runtime (V3.1 Phases 21–33 — P21–P25 consolidadas, P26+ pendentes)

Programa em andamento, com estado vivo em
`evidence/v3.1/runtime-reliability/program-status.json`; especificado em
[Runtime Reliability SPEC addendum](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md),
planejado em [Plan addendum](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md),
com execução descrita em [Implementation prompt](specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md):

- **P21 done (baseline)**: pins V1/V2 presentes, listener `49374`
  identificado como AI Memory local (Docker, saudável); fixtures de
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
  preservado. Sem enforcement (Phases 24–28); native step em HOLD.
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
  `watchdog{enabled:false, shadow:true}`; `enabled=true` retorna
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED`. Suítes: watchdog
  **80/80** (PS5.1 + PS7), kernel **75/75**, consistência **16/16**;
  reviews Reviewer **APPROVED** (REV4) + Security **APPROVED**
  (SEC3). Follow-ups documentados: lock cross-process, retenção
  multi-dia; interrupt real é Phase 26 (não implementado).

Mecanismos-alvo do programa (desenho vigente; só o acima está
implementado):

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
  limitado e `MEMORY_UNAVAILABLE` limitado — migração do listener local
  `127.0.0.1:49374` para VPS planejada, **não executada**.
- **Jev MCP**: somente consultivo e opt-in (`jev_advisory` OFF), nunca
  autoriza ações, concede permissões, sobrescreve Reviewer/Security
  Reviewer/verificação/DONE; indisponibilidade retorna `JEV_UNAVAILABLE`
  limitado sem retry infinito.

Limites honestos: o acima é o que existe — sem enforcement de
watchdog/loop-guard/budgets/circuit breaker (Phases 26+ não iniciadas);
todas as flags seguem OFF em
`source/registry/capability-flags.json` (nenhuma flag nova); AI Memory
nunca mutado (listener local mantido); roteamento MCP genérico
desligado; revisões Reviewer + Security Reviewer com APPROVED parcial
por fase (HOLDs registrados); critérios `RR-01`–`RR-20` pendentes onde
não cobertos. Programa **não** concluído.

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
