# Operational Refinement & Functional Stabilization — Plano revisado executável (F0–F7)

**Status:** PARCIAL — fatias locais implementadas e verificadas em 2026-10-14;
gates F1/F3 e fechamento funcional permanecem bloqueados pelas condições documentadas.
Gates funcionais continuam dependentes de suas provas; autorização para implementar não é prova de enforcement.
**Base:** master `3d3ba0eeab8402b519a2edee0177117cc4cc33da` (v0.1.2).
**Data da revisão:** 2026-10-14. **Classificação:** P0 (gates funcionais GW01–GW15,
caminho produtivo, recovery) / P1 (observabilidade, pilotos, docs).
**Idioma:** pt-BR. **Escopo atual:** código, testes e documentação locais; configurações ativas e ambientes externos preservados.
**Pedido de origem:** F0–F7 Operational Refinement & Functional Stabilization (autonomia funcional).

Objetivo do programa: tornar a orquestração **funcionalmente autônoma** no caminho
produtivo real — `PREPARE → CLAIM pré-efeito → tool nativa (Planner) → SETTLE candidato →
verificador → tester/reviewer (policy) → kernel DONE/CAS → ADVANCE` — com continuação
automática multifase e recovery por sessão substituta, sem daemon, sem segundo Planner,
sem novo framework e sem substituir a tool nativa por callback PowerShell.

## 0. Como ler este plano

1. **PLANEJADO vs PROVADO.** Os gates abaixo definem a proposta; execução e resultados atuais estão no
   [relatório operacional](../../evidence/closure/OPERATIONAL-CLOSURE-2026-10-14.md). Nada aqui altera vereditos
   existentes (`PARTIAL CLOSURE`, `HOLD`, `BLOCKED_UPSTREAM`). Quando o texto cita um fato
   já provado, a fonte está linkada; quando é hipótese, está marcado `HIPÓTESE` + gate.
2. **Estado externo não consultado.** Issues GitHub, CI remota e merges fora deste checkout
   não foram consultados na revisão documental inicial. Na execução, consultar o relatório
   operacional para observações remotas datadas; somente as consultas ali registradas estão confirmadas.
3. **Invariantes (§2) vencem.** Em conflito, a invariante vence qualquer atalho de fase.
4. **Mínimo executável.** Cada fase tem: entrada, unidades de trabalho (paths/símbolos reais),
   critérios de saída observáveis e comandos de validação reais. Orçamentos (budgets) devem ser
   definidos **antes** de qualquer execução.
5. **Preflight sempre.** Toda tarefa não trivial passa por
   `scripts/v3/orchestration-preflight.ps1` antes da primeira ação; `SINGLE_WORKER`
   (Planner → 1 cheap worker → Planner) é o **mínimo**, mesmo para trabalho trivial —
   nunca execução solitária do Planner quando houver worker adequado.

## 1. Baseline factual (revisão — o que muda em relação ao pedido original)

| # | Ajuste da revisão | Fonte |
|---|---|---|
| B1 | HEAD confirmado `3d3ba0e` em `master` (v0.1.2); working tree **limpa** no início (`git status --porcelain` vazio) | verificado neste pedido |
| B2 | Onda 2 é **runtime-real Planner-driven, provenance `declared`, modo compatibilidade, SEM atestação estrita de host**: Planner real via `subagent` nativa (V2), goal `o2-goal` → `COMPLETED` via CAS, 3 fases coder→tester→reviewer reais, fault-injection declarado + retry com nova key, setup **fora do repo** (TEMP `onda2-proof/`), driver específico; `settle-result-conflict` (duplicata divergente) coberto **só em harness** (F3 [N7]); o gate opt-in G1-A recusaria tier `declared`, mas não foi acionado | `evidence/closure/onda2-prova-real-2026-10-14.md` |
| B3 | PRs **#74 / #85 / #87 já entregues** segundo `CHANGELOG [Unreleased]`; **#88** confirmado pela mensagem de merge do HEAD local — não replanejar como zero: #74 delegação nativa V2 (Onda 1); #85 instrumentação evidência Jev + #60 útil (Onda 3); #87 envelope correlação objetivo→settlement (Onda 4); #88 consolidação Ondas 1–4 | [CHANGELOG](../../CHANGELOG.md) §[Unreleased]; `git log -1` em `3d3ba0eeab` |
| B4 | **Jev/Advisor já parcialmente demonstrados** — F4 é continuação: `JevAdvisory` 159/159 + chamada real `closure-f0-003` (`JEV_ADVISORY_OK`, conf 0.22) + fail-closed sem credencial; Advisor deadlock consult real sobre impasse Onda 2 (útil). Resta exact-binary-live + pernas model (operator-owned) | `evidence/closure/f1-progress.md`, `evidence/closure/f0-finding-B-wiring.md` |
| B5 | **Pilotos parciais não repetem como zero**: Synkroo docs-only em branch (sem merge); IPTV E1–E3 PASS (sem merge); Ted declinado honestamente (sem SUT). Merges nesses repos = decisão dos donos | `CHANGELOG.md` §[Unreleased] Onda 5 |
| B6 | `2.0.27 instalado` é **histórico do closure F0 (2026-10-12)**, não verificação atual. Pin vigente: consultar `source/registry/runtime-versions.json` (V2 `2.0.23`, V1 `1.18.34`) — sem bump neste programa | `source/registry/runtime-versions.json`, `evidence/closure/f0-baseline-final.md` |
| B7 | "21 blocos / 19 delegáveis" (Onda 1) é **baseline a conferir dinamicamente** no F0 (config viva pode divergir — precedente DE22307F, user-owned) — não congelar número no plano | `CHANGELOG.md` §[Unreleased] Onda 1 |
| B8 | Closure F0–F7 anterior (`evidence/closure/CLOSURE-REPORT.md`, base `ec5c2de`) é **input histórico**, não estado atual: 6 PRs #59/#65/#66/#71/#73/#75 merged, flakes classificados, HOLDs mantidos. Este programa parte dele sem reescrevê-lo | `evidence/closure/CLOSURE-REPORT.md` |
| B9 | SPEC/PLAN `PLANNER-NATIVE-HANDOFF-v0.1.2` continuam autoritativos para o caminho produtivo: G0 concluído, G1 produtivo bloqueado por fronteira de confiança não provada; SETTLE de biblioteca ≠ settlement produtivo no TaskKernel | `docs/specs/PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md`, `docs/specs/PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md` |
| B10 | **Divergência normativa aberta (resolver antes de qualquer wiring):** o PLAN nativo proíbe converter ausência de prova em autorização por protocolo cooperativo (PLAN §1/§3), enquanto a Onda 2 executou em modo compatibilidade `declared` — prova isolada de caminho cooperativo, não autorização. APIs existentes e histórico de execução **não** são autorização; a SPEC histórica **não** é editada neste pedido. G1 estrito permanece bloqueado; a prova compat só vale sob **autorização específica aplicável** (decisão de escopo cooperativo autorizado via revisão de contrato — ver I5 e §4) | PLAN §1, §3; `evidence/closure/onda2-prova-real-2026-10-14.md` §Limites |

## 2. Invariantes (não negociáveis)

- **I1 — Preflight mínimo.** `SINGLE_WORKER` é orquestração plena (Planner → 1 cheap
  worker → Planner). Tokens `DIRECT_*` legados são rejeitados fail-closed. Sem worker útil
  em tarefa não trivial ⇒ `ORCHESTRATION_POLICY_BYPASS`, sem `DONE` compliant.
- **I2 — Vocabulário de resultado.** Worker retorna **só** `candidate_pass` | `failed` |
  `blocked` com refs de critério. `verified_pass` é do **verificador allowlisted**
  (`source/registry/verification-policy.json`); aprovação é de **reviewer/security-reviewer**;
  `DONE` é só do **kernel** (`Complete-OrchestrationTask` após `Test-OrchestrationTaskCompletion`).
  Mensagem de sucesso de worker nunca é prova.
- **I3 — Ordem do caminho produtivo.** `PREPARE → CLAIM pré-efeito → tool nativa do Planner
   (`subagent` V2) → SETTLE candidato → verificador → tester/reviewer (policy) →
  kernel DONE/CAS → ADVANCE`. Nunca executar a tool primeiro e "autorizar" depois; nunca
  substituir a tool nativa por callback PowerShell/hook observacional/texto do modelo.
- **I4 — Estados reais vs relatórios.** O grafo Goal/Task do kernel (ex.: `ACTIVE → COMPLETED`
  via CAS; `settled`/`settled-failed`; `DISPATCH_UNCERTAIN`; `RECONCILIATION_REQUIRED`) é
  separado de readiness/report/waits. Rótulos propostos como `READY_FOR_RESUME` /
  `BLOCKED_OPERATOR` são **etiquetas de relatório/readiness**, nunca novos estados de kernel
  ad hoc — não introduzir transição de kernel sem SPEC + review + teste.
- **I5 — Cooperativo vs estrito.** Modo cooperativo confiável / supervisionado é permitido
  **somente** onde a policy autoriza **e** sob autorização específica aplicável (a divergência
  B10 deve ser resolvida antes de qualquer wiring: revisão de contrato que delimite o escopo
  cooperativo autorizado — sem editar a SPEC histórica neste programa); modo estrito segue
  **bloqueado** (issues #69/#70, a revalidar, com security track acompanhada — ver §12 —
  sem fabricar host proof). Nunca exigir `StrictProvenance` para gate funcional, nunca alegar
  atestação de host a partir de provenance `declared` (dado, não autoridade).
- **I6 — V1 LEGACY_FROZEN.** V1 é regression guard (issue #62, a revalidar); testes legacy
  preservados; instalações novas = V2. Sem dependência V1 nova em testes V2.
- **I7 — Flags fora de escopo.** `runtime_grant_enforcement{v1,v2}` OFF,
  `capability_router` shadow+active OFF, `skill`/`mcp`/`adaptive`/`routing_telemetry`/
  `reconciler` OFF, Active Routing 2G OFF. Nenhuma ativação neste programa sem gate humano
  + prova em runtime exato. Fora de escopo também: swarm/team/arena/daemon/segundo Planner.

## 3. F0 — Inventário e baseline (gate: PASS/FAIL explícito)

**Objetivo:** baseline consistente, matriz de pendências fato-vs-hipótese, definição Golden,
observabilidade mínima ligada desde já. **Duração proposta:** curta, read-only primeiro.

- **Entrada:** HEAD `3d3ba0eeab8402b519a2edee0177117cc4cc33da`, tree limpa; registry vivo;
  `evidence/closure/` como input.
- **UT-F0.1 — Inventário dinâmico (não congelar números):** contar blocos vivos de
  `templates/opencode.v2.json.tmpl` + `source/agents/*.md` + `source/registry/capabilities-v2.json`;
  registrar divergências tipo DE22307F como machine-local/user-owned sem tocar.
- **UT-F0.2 — Matriz fato-vs-hipótese:** para cada frente F1–F6, colunas
  `estado | evidência (link) | bloqueio | gate de aceite`. Marcar `HIPÓTESE` tudo que exigir
  remoto não consultado (issues, runs CI).
- **UT-F0.3 — Definição Golden (GWs do usuário, §9):** congelar a lista exata GW01..GW15
  do pedido como critério funcional; mapear a suite antiga
  (`scripts/v3/lib/OrchestrationGoldenWorkflows.tests.ps1`) **em separado** por caso real
  (§9.2) — sem reescrever a suite aqui e sem fundir numerações.
- **UT-F0.4 — Observabilidade mínima desde F0:** ligar coleta read-only existente
  (`OrchestrationEvolutionTelemetryProducer.ps1`, `OrchestrationTelemetry.ps1`,
  `CapabilityOutcomeValidation.ps1`, `CapabilitySkillUtility.ps1`) em modo observação;
  registrar o que é join canônico ausente (seleção→execução→settlement) como lacuna F6.
- **UT-F0.5 — Descoberta F5 inicia aqui:** levantar perfis `source/registry/mcp-profiles.json`
  (testing opt-in: playwright + chrome-devtools) e suites
  (`agent-mcp-integration.tests.ps1`, lane `agent-mcp-integration-lane-v2.ps1`) — sem ativar nada.
- **UT-F0.6 — Checks de ambiente (registrar, sem mutar):** binário exato (hash SHA-256 +
  path do `opencode --version` vs pin do registry), plugin instalado, env/profile efetivos,
  agentes carregados, providers/quotas, permissões, skills, MCPs, flags
  (`source/registry/capability-flags.json`), worktrees, git branches, PRs e status CI
  remoto — remoto **a consultar futuramente, sem overwrite** de registros históricos.
  Install/reinstall/update/rollback só em perfil **isolado** (TEMP), com configuração
  user-owned preservada; baseline inclui suites (não só doc-diff).
- **UT-F0.7 — Mapa produtivo + classificação:** call graph do caminho
  PREPARE→…→ADVANCE (libs §4) e mapa de flags; classificar cada pendência em
  `FIX` (defeito provado) / `WIRING` (integração faltante) / `TEST` (cobertura) /
  `DOC` (documentação) / `UPSTREAM_BLOCKED` / `DEFERRED` — sem converter ausência em PASS.
- **Saída:** `evidence/<programa>/f0-baseline.md` com gate `PASS`/`FAIL` + matriz + Golden
  congelado + lacunas + mapa produtivo. **Sem código produtivo.**
- **Validação da futura F0:** consistência do pacote + baseline das suítes afetadas (§13),
  com orçamento definido; registrar falhas preexistentes sem ocultá-las. A revisão deste
  documento, por ser docs-only, não executa esse baseline nem declara F0 entregue.

## 4. F1 — Planner → workers → kernel + continuação (paralela com F2 após F0)

**Objetivo:** fechar o caminho Planner-driven cooperativo multifase com fault-recovery,
sobre os contratos já existentes — sem wiring novo de autoridade e sem atalhos de driver.

- **Entrada:** F0 PASS (incluindo B10 resolvida: escopo cooperativo autorizado delimitado
  por revisão de contrato); contratos F1 declarados em `f0-finding-B-wiring.md` §F3.
- **UT-F1.1 — Contratos (reusar, não reescrever):**
  `scripts/v3/lib/OrchestrationObjectiveRuntime.ps1` (`New-OrchestrationDispatchIntent`),
  `scripts/v3/lib/OrchestrationNativeDispatch.ps1` (PREPARE/CLAIM/SETTLE candidatos +
  `New-NDDispatchEnvelope`), `scripts/v3/lib/OrchestrationAutonomousLoop.ps1`
  (`Invoke-OrchestrationAutonomousObjective`, `Invoke-OrchestrationObjectiveStep`),
  `scripts/v3/lib/OrchestrationObjectiveController.ps1` (next-move),
  `scripts/v3/lib/OrchestrationGoalKernel.ps1` + `OrchestrationTaskKernel.ps1`
  (`Set-OrchestrationTaskWorkerResult`, `Test-OrchestrationTaskCompletion`,
  `Complete-OrchestrationTask`), `scripts/v3/lib/OrchestrationGoalCheckpoint.ps1`,
  `scripts/v3/lib/OrchestrationEvidenceRef.ps1`.
- **UT-F1.2 — Prova funcional (runtime-real, sessão nova, solicitação ordinária):**
  em **sessão nova**, com solicitação ordinária (sem prompt manual de continuação), executar o
  **fluxo normal**: Planner prepara (PREPARE/CLAIM) → chama a tool nativa → SETTLE → verifica →
  avança, em **≥3 fases** com coder→tester→reviewer reais, 1 fault-injection declarado
  (prev inválido → `settled-failed` honesto → retry com nova key → PASS), fora do repo
  (TEMP isolado), **sem drivers/scripts manuais substituindo a preparação do Planner e sem
  `continue` humano** entre fases (advance causal + barreira: sucessor só após DONE+progresso),
  `grep verified_pass = 0` em artefatos de worker. A Onda 2 (`o2-goal`) é **histórico de
  referência, não gate cumprido**: usou driver específico e setup manual — a prova F1 deve
  passar pelo fluxo normal. **Proposta, não prova** — executar só com provider/orçamento
  autorizados (§11), runs críticos em ≥2 sessões independentes.
- **UT-F1.3 — Gap a descobrir (não assumir):** Caller produtivo do Planner, install path das
  `scripts/v3` no destino distribuído e support do bundle distribuído são **gaps explícitos**
  (PLAN §3 Fase 1.4 já os lista: bridge CLI fechado, localização/confiabilidade do script,
  integração só em bundle de teste isolado). Descobrir e registrar antes de qualquer wiring;
  sem inferir caminho por CWD nem recorrer a script de projeto não verificado.
- **UT-F1.4 — Recusas negativas:** reproduzir `prepare-already-claimed`,
  `evidence-refs-missing`, `duplicate-task`, `terminal-goal`, `stale-goal-revision`
  (lista observada na Onda 2) como asserts de comportamento — sem inventar APIs.
- **Saída:** objetivo COMPLETED via CAS + cadeia de artefatos com hashes + ordem
  `settle < verify < review < DONE` + tester PASS + reviewers APPROVED por fase.
- **Validação:** comandos §13 (run-v3-tests `-Name` por suite afetada, dois hosts) +
  `git diff --check`. Testes novos são proposta (sem nome falso, sem harness universal novo).

## 5. F2 — Watchdog / CAS / recovery (paralela com F1 após F0)

**Objetivo:** endurecer execução limitada e recuperação, com refusal honesto e sem
alegar enforcement inexistente.

- **Entrada:** F0 PASS; `source/registry/execution-budget-policy.json`,
  `source/registry/execution-grants.json`, `source/registry/goal-policy.json`.
- **UT-F2.1 — CAS fisicalista:** `OrchestrationTaskKernel.ps1` /
  `OrchestrationGoalKernel.ps1` (lock→read→check→write; `FileShare.None`);
  instrumentação failure-only do race-001 preservada; causa da corrida segue
  `UNKNOWN` até diagnóstico (ver §12/§14 R5) — sem relaxar timeout/invariante para obter verde.
- **UT-F2.2 — Watchdog (ON onde há binding provado, observação onde não há):**
  `scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1` + suites F1/JOB46/JOB48 +
  `OrchestrationRuntimeWatchdogEnforcement.tests.ps1`; enforcement (Job Object
  `KILL_ON_JOB_CLOSE`, ownership, budget ledger) vale **quando o binding de processo é
  provado** — sem binding provável em ENFORCE, o token continua
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED`: recusa, nunca kill de PID desconhecido.
  Cobrir nos testes: ownership de instâncias externas, pid-reuse, healthy/slow child,
  escape de descendentes, cancel, locks, `pending` settlement. **FIX3-2 a diagnosticar**
  (gone-path attribution: child nascido após `lastAliveProof` é excluído, nunca morto —
  `WATCHDOG_TREE_EXCLUDED`; próxima ocorrência com diagnóstico failure-only antes de
  qualquer classificação).
- **UT-F2.3 — Recovery runtime-real por sessão substituta (saída obrigatória):**
  lane `scripts/ci/session-real-lane-v2.ps1` + `Save-OrchestrationGoalCheckpoint` /
  `Load-OrchestrationGoalCheckpoint` (`OrchestrationGoalCheckpoint.ps1`) +
  `Get-OrchestrationSessionReconciliation` / `New-OrchestrationContinuationPlan` /
  `New-OrchestrationContinuationEnvelope` (`OrchestrationSessionReconciler.ps1`) +
  `Invoke-OrchestrationObjectiveReconcile` (`OrchestrationObjectiveRuntime.ps1`) /
  `Invoke-ProductiveObjectiveReconcile` (`OrchestrationProductiveActivation.ps1`).
  Tentativa ambígua (`DISPATCH_UNCERTAIN`/`pending`) nunca sofre replay; a substituta só age
  após revalidar ownership + reconciliar pendências, e a prova exige **ação atribuída à
  substituta executada em runtime real**, não só leitura de canário. As pernas 18/20/21/22
  da lane histórica são **partial-legs históricas** (consumo/re-leitura/turn pelo substituto
  como operator-owned) — **não assumir como complete**: re-provar o que for gate deste programa.
- **Saída:** suites verdes nos dois hosts + **recovery demonstrado em runtime real por
  substituta com ação atribuída**; HOLDs de enforcement intactos onde não há binding provado.
- **Validação:** comandos §13 (suites afetadas via `-Name`, dois hosts) + distribuição
  quando tocar em runtime; `git diff --check`.

## 6. F3 — Waits GitHub #86 + spike bounded de sobrevivência (spike antes de watcher)

**Objetivo:** decidir waits/retomada externos com spike limitado — **sem** novo
daemon/kernel/segundo Planner/framework. Issue #86 com status **a revalidar no remoto**.

- **Entrada:** F1/F2 em curso; infra de scheduling existente identificada.
- **UT-F3.1 — Spike exploratório (gate separado, NÃO passa F3 nem GW09):** medir no host,
  com orçamento explícito: persistência do wait (CI checks / head SHA / run id / generation /
  lease), encerramento da sessão iniciadora → wake em infra **existente e autorizada** →
   sessão substituta revalida SHA + ownership + cancelamento + autorização atual, consome o
  resultado e continua **sem `continue` humano**. Provider, orçamento e uso de
  scheduling/infra existente **explicitamente autorizados antes** (§11) — sem isso, o spike
  não executa. Resultado do spike: `SPIKE_PASS` (caminho medido) | `PARTIAL` |
  `HONEST_BLOCK` — spike nunca conta como gate funcional.
- **UT-F3.2 — Gate funcional F3 (só após spike + autorização):** execução real cobrindo
  duplicata, out-of-order, GitHub outage, head change, conflict e reviews
  (**no-automerge**); `SHA`/head checks, reviews stale, rate-limit com backoff,
  cancellation; polling bounded sem credenciais novas; webhook **só** se infra disponível
  + autorizada.
- **UT-F3.3 — Semântica honesta:** `READY_FOR_RESUME` é etiqueta de readiness — **não passa
  GW09 (autonomia)**: retomada exige revalidação + autorização atual + consumo real (I4, §2).
  Capability `unsupported` ⇒ `BLOCKED`/`DEFERRED` estruturado, sem ampliar escopo.
- **Saída exploratória:** relatório spike + escolha do mecanismo existente autorizado
   (evento/webhook ou polling bounded). Essa decisão não entrega o gate funcional.
- **Saída funcional F3:** evidência real de wait persistido → encerramento da sessão
   iniciadora → wake supervisionado → substituta revalida SHA, geração, lease, ownership,
   cancelamento e autorização → consome a conclusão do CI → executa a próxima ação
   autorizada automaticamente, sem mensagem humana de continuação. Cobrir também os
   negativos de UT-F3.2. Sem essa cadeia, F3/GW09 ficam `PARTIAL` ou `BLOCKED_*`, nunca PASS.
- **Validação:** revisão do desenho + `git diff --check`; nenhuma suite nova universal.

## 7. F4 — Jev / Advisor / MCP / memory (depende de F1, não de F3)

**Objetivo:** completar a assessoria consultiva sobre o caminho F1 — Jev nunca decide
sozinho, Advisor nunca coordena, MCP/memory nunca viram autoridade.

- **Entrada:** contratos F1; `source/registry/jev-advisory-policy.json`,
  `source/registry/mcp-profiles.json`, `source/registry/ai-memory-remote-policy.json`.
- **UT-F4.1 — Jev consultivo (influência registrada, nunca autoridade):** Jev **pode
  influenciar a deliberação do Planner** — cada consulta registra `adoption`/`rejection`
  com motivo (`decision_adopted`/`decision_note`, omitidos quando ausentes, pós-#85);
  `scripts/v3/lib/OrchestrationJevAdvisory.ps1` (`Test-JevAdvisoryTrigger`,
  `Invoke-JevAdvisoryCall`) + caller P38-S2 no PlannerLoop +
  `OrchestrationDecisionWiring.ps1` + grant-gate que sempre nega +
  `OrchestrationMcpSafety.ps1` (`Invoke-McpSafetyCall`, caps fail-closed). Jev nunca é
  autoridade direta sobre grants, verificação ou DONE (envelopes com
  `grants_authority=false`, `done_approved=false`, `verified_pass=false`). Falha qualquer
  ramo ⇒ fallback determinístico, sem retry, sem inventar recommendation. Resta:
  exact-binary-live com chave real (operator-owned, issue #61 a revalidar).
- **UT-F4.2 — Advisor deadlock (#60, a revalidar):** `source/agents/engineering-advisor.md`
  (read-only, sem coordenação/subagentes); entrada mínima senão BLOCKED; saída diagnóstico +
  1 próxima ação + rollback; Jev auxiliar opcional, nunca autoridade.
- **UT-F4.3 — MCP/memory:** perfis testing opt-in, isolamento por perfil/worktree, cleanup;
  S5–S7 só com credencial existente autorizada (`OPERATOR_ACTION_REQUIRED` caso contrário);
  AI Memory como continuidade operacional (round-trip + probe 401 fail-closed já provados;
  `REUSE` HOLD) — sem escrita de memória sem pedido explícito.
- **Saída:** cadeias consultivas com `model/usage_in/usage_out/decision_adopted/decision_note`
  (omitidos quando ausentes, pós-#85) + fail-closed demonstrado; pernas model-dependent como
  operator-owned.
- **Validação:** suites `JevAdvisory` + `DecisionWiring` + `McpSafety` + `PlannerLoop` nos dois
  hosts; `git diff --check`.

## 8. F5 — Compatibilidade e observabilidade (descoberta desde F0; sem dependência circular)

**Objetivo:** compatibilidade V2 por capacidades + observabilidade correlacionada — F5 **consome**
contratos F1, não o contrário (F1–F4 não esperam F5 fechar).

- **Entrada:** descoberta F0 (UT-F0.5); `source/registry/runtimes.json` (histórico),
  `source/registry/v2-native-capabilities.json`, `source/registry/plugin-capabilities.json`.
- **UT-F5.1 — Compat escopo V2 (não é matriz-objetivo V1/V2/dual):** V1 frozen como
  regression guard, sem dependência V1 nova em testes V2; probes de capability detectam
  **instalado real vs pin** (`source/registry/runtime-versions.json`, loader fail-closed,
  sem literal) e registram drift **sem upgrade/bump**; decisão por capability em
  `authorised` vs `available` vs `tested` (nunca fundir); invalidação registrada em mudança
  de runtime/plugin/config; comandos de diagnóstico existentes propostos
  (`scripts/runtime/spike-v2-permissions.ps1`, `scripts/runtime/RuntimePortPreflight.ps1`,
  `scripts/ci/plugin-healthcheck.ps1`); `DE22307F`-classe nunca "corrigida" tocando config
  user-owned.
- **UT-F5.2 — Observabilidade (coletor íntegro, join ausente):** producer 164/164,
  EvolutionLoop 147/147 e OutcomeValidation/SkillUtility como referência; documentar
  suficientes (suites, runs, lanes, fixtures) vs insuficientes (join canônico
  seleção→execução→settlement, outcomes labelados) vs não observáveis (turns sem provider).
  `NOT_OBSERVED`/`NOT_MEASURABLE` nunca viram zero/sucesso; custo desconhecido nunca é zero.
- **Saída:** matriz compat + relatório de lacunas F6 (input da F6, não gate de F1).
- **Validação:** suites afetadas nos dois hosts + `git diff --check`.

## 9. F6 — GW01..GW15 (gates do usuário) + pilotos (integra gates anteriores, não os repete)

**Objetivo:** provar os 15 gates funcionais do usuário em runtime-real + pilotos externos
delimitados. A numeração GW01..GW15 abaixo é a do pedido — **não** a da suite Golden antiga
(mapeada em separado no §9.2).

- **Entrada:** F1–F5 com evidências.
- **UT-F6.1 — Gates runtime-real (mandatory):** GW01..GW15 executados no runtime exato do
  registry, PS5.1 + PS7, sem relaxar invariante/timeout. Qualquer GW sem prova runtime-real
  ⇒ programa **não** é `functional complete` (ver §10) — blocker nunca conta como pass.
- **UT-F6.2 — GW12 (refusals) com nota de escopo:** refusals de kernel (gates, CAS, fencing,
  budget) ≠ deny de host (superfície `/shell` fail-open observado) até prova upstream;
  reportar modo **supervisionado/cooperativo** separadamente de **estrito** (bloqueado #69/#70,
  security track acompanhada sem fabricar host proof — ver §12).
- **UT-F6.3 — Pilotos (decisão dos donos, não deste programa):** Synkroo (docs-only, branch
  sem merge), IPTV E1–E3 (PASS sem merge), Ted (declinado sem SUT) como precedentes de
  "piloto parcial honesto"; novos pilotos só com autorização própria (§11), sem repetir o
  já provado como zero.
- **Saída:** matriz GW01..GW15 nas categorias originais (§10) + artefatos por GW.
- **Validação:** comandos §13 + distribuição quando aplicável.

### 9.1 Gates GW01..GW15 (lista exata do usuário — normativa neste programa)

| GW | Gate | Prova |
|---|---|---|
| GW01 | trivial SINGLE_WORKER | 1 cheap worker fim-a-fim, preflight + DONE gate (I1, §2) |
| GW02 | complexa: planejar / delegar / verificar / finalizar | ciclo coder→tester→reviewer com DONE kernel |
| GW03 | worker fail → retry / bloqueio | `failed` honesto → retry admitido ou `blocked` estruturado, sem replay |
| GW04 | reviewer reject → fix + reverify | CHANGES_REQUIRED → correção → revalidação afetada |
| GW05 | impasse → Advisor | deadlock consult com diagnóstico + 1 ação + rollback |
| GW06 | Jev indisponível → fallback | `JEV_UNAVAILABLE` → determinístico, sem bloqueio nem invenção |
| GW07 | cancel sem nova execução | CANCELLED recusa dispatch posterior (`goal-terminal`) sem efeito |
| GW08 | sessão interrompida → recovery | substituta revalida + ação atribuída (§5 UT-F2.3) |
| GW09 | CI pendente → espera persistente + resume | wait persistido (CI/head/run/generation/lease) + resume consumido (§6) |
| GW10 | CI vermelho → logs / diagnóstico + correção autorizada | causa com logs autenticados; correção só de defeito provado |
| GW11 | concurrency sem duplicação/corrupção | corrida mesma-revisão: 1 vence, demais recusadas; sem corrupção de store |
| GW12 | permissão negada → kernel refusals | refusals negam sem efeito; ≠ host deny até proof upstream (UT-F6.2) |
| GW13 | budget | budget exaurido bloqueia; custo desconhecido nunca é zero |
| GW14 | update V2 capabilities | capability nova só via registry + prova no runtime exato; sem auto-adoção |
| GW15 | DONE kernel | conclusão só via CAS/verificador + `Complete-OrchestrationTask` |

Cada GW registra uma das categorias originais (§10):
`RUNTIME_REAL_PASS` | `HARNESS_PASS` | `PARTIAL` | `BLOCKED_OPERATOR` |
`BLOCKED_UPSTREAM` | `HOLD` | `FAIL`. Sem segunda taxonomia paralela.

### 9.2 Suite Golden antiga — mapeamento separado por caso real (não mesma numeração)

A suite `scripts/v3/lib/OrchestrationGoldenWorkflows.tests.ps1` (15/15 na base) é
**regressão harness-level**, não gate funcional. Mapear cada caso antigo ao GW real que o
cobre, com estado honesto (casos sem cobertura runtime-real ficam `ausente`/`partial`,
nunca renumerados como GW):

| ID na suíte existente | Caso efetivamente testado | Relação com o programa (somente harness) |
|---|---|---|
| GW-01 | preflight de typo → SINGLE_WORKER | auxiliar de GW01; não executa worker |
| GW-02 | preflight de bug → MULTI_WORKER | auxiliar de GW02; não implementa nem revisa |
| GW-03 | reuse hit | auxiliar de reutilização; não cobre falha/retry de GW03 |
| GW-04 | reuse miss por fingerprint | auxiliar de invalidação; não cobre GW04 |
| GW-05 | advice Jev com probe sintético saudável | auxiliar F4; não cobre indisponibilidade |
| GW-06 | probe Jev falha/ausente → escalation | cobertura parcial de GW06; falta serviço/runtime real |
| GW-07 | promoção, tasks e progresso do Goal | auxiliar de GW02/GW15; não prova TaskKernel DONE completo |
| GW-08 | trabalho restante → CONTINUE | auxiliar F1; não cobre concorrência GW11 |
| GW-09 | sequência sintética review/fix/re-review | cobertura parcial de GW04; sem agentes reais |
| GW-10 | stalls → mudança de estratégia | auxiliar de diagnóstico; não cobre Advisor GW05 ou CI GW09 |
| GW-11 | checkpoint save/load/resume | cobertura parcial de GW08; sem substituta executando |
| GW-12 | limite de autoridade → parada | auxiliar GW12; não prova mediação/deny host |
| GW-13 | recusa de seleção de modelo | auxiliar de policy; não cobre permissão de ferramenta GW12 |
| GW-14 | entrega verde elegível, eventos sintéticos | auxiliar de delivery; não cobre diagnóstico CI vermelho GW10 |
| GW-15 | budget → EXHAUSTED, não COMPLETED | cobertura parcial GW13; não prova limite em execução real |

Esta suíte não fornece cobertura direta de GW03, GW05, GW07, GW09, GW10, GW11 ou GW14.
F0 deve localizar provas específicas nas outras suítes/lanes ou registrar cobertura ausente.
Nenhuma correspondência acima dispensa a prova runtime-real normativa de §9.1.

E2E harness `OrchestrationCorrectiveE2E.tests.ps1` (E2E-01..E2E-15, gates G1–G8) segue como
cobertura complementar harness-level, sem numeração GW.

### 9.3 Pilotos — protocolo delimitado (proposta)

1. Piloto só em repo alheio com **dono explícito** e branch própria; docs-only por default.
2. Critérios de aceite do piloto escritos **antes** (o que é PASS, o que é BLOCKED_UPSTREAM).
3. Merge/publicação no repo piloto = decisão do dono, fora do gate funcional deste programa.
4. Precedentes a reutilizar sem re-provar: Synkroo (docs-only sem merge), IPTV E1–E3
   (headers + kill + retomada, sem merge), Ted (declinado sem SUT — honestidade como resultado).

## 10. F7 — Release e closure report

**Objetivo:** fechar com veredito honesto e relatório navegável.

- **Entrada:** matrizes F0–F6.
- **UT-F7.1 — Gate funcional:** `FUNCTIONAL_COMPLETE` **só** se todos os GW mandatory
  forem `RUNTIME_REAL_PASS` + caminho F1 + recovery F2 demonstrados em runtime-real.
  Caso contrário o programa publica `PARTIAL` (completo no que foi provado) ou `HOLD`
  (aguardando operador/upstream) — com bloqueios nomeados, nunca mascarados.
- **UT-F7.2 — Closure report:** `evidence/<programa>/CLOSURE-REPORT.md` + CHANGELOG
  `[Unreleased]` com: SHA inicial e final, PRs/issues, CI do HEAD definitivo (**só após
  merge autorizado** — CI de branch não fecha HEAD), capabilities, automatic recovery,
  permissions limits, upstream release/HOLD; métricas por frente (§12); HOLDs/BLOCKEDs
  residuais; decisões de operador pendentes. Rerun que limpa sem código prova apenas
  **intermitência** — causa classificada `UNKNOWN` até diagnóstico (ver §12); nunca
  `FLAKY-TIMING` como veredito sem captura failure-only.
- **UT-F7.3 — Docs incrementais (ao longo, não só no fim):** ARCHITECTURE (call graph +
  limitações), TROUBLESHOOTING/INSTALLATION tocados só no mínimo V2-only já decidido;
  docs históricas (`evidence/closure/*`, CHANGELOG lançado) **nunca reescritas**.
- **UT-F7.4 — Review independente sensível:** reviewer + security-reviewer quando a policy
  disparar; track #69/#70 acompanhada (estrito) **sem fabricar host proof** — ausência de
  prova registrada como ausência.
- **Saída:** tag/versão só por decisão de release separada (§11); relatório + review
  independente.
- **Validação:** `git diff --check` + conferência de links relativos/paths.

**Categorias de resultado (originais, únicas — sem segunda taxonomia):**
`RUNTIME_REAL_PASS` | `HARNESS_PASS` | `PARTIAL` | `BLOCKED_OPERATOR` |
`BLOCKED_UPSTREAM` | `HOLD` | `FAIL`.
`HARNESS_PASS` nunca é reportado como prova runtime-real; `PARTIAL`/`BLOCKED_*`/`HOLD`
nunca contam como pass de gate mandatory.

## 11. Autorizações futuras (separadas — este plano não autoriza nenhuma)

Cada item exige pedido/decisão próprios antes de executar: PRs e publicação; pilotos em
repos alheios (env/project); paid provider / modelo externo; merge/deploy; issues/credentials
(criar/revogar/rodar); uso de scheduling/infra e webhook do F3; qualquer ativação de flag ou
bump de pin; escrita em memória (ai-memory/vault) sem pedido explícito do usuário.
O pedido posterior de implementação autoriza desenvolvimento e validação locais; não libera
por inferência as operações externas acima. V1 segue `LEGACY_FROZEN`; enforcement v2 OFF.

### 11.1 Matriz entrada→saída por fase (critérios observáveis)

| Fase | Entrada (gate de início) | Saída (gate de fim) | Quem atesta |
|---|---|---|---|
| F0 | HEAD + tree limpa | `f0-baseline.md` + gate PASS/FAIL + Golden congelado | Planner + 1+ explorer read-only |
| F1 | F0 PASS | objetivo COMPLETED via CAS + cadeia hash + ordem settle<verify<review<DONE | tester PASS + reviewers APPROVED/fase |
| F2 | F0 PASS | suites 2 hosts + recovery runtime-real por substituta | tester + reviewer (policy) |
| F3 | spike aprovado + contratos F1/F2 + infra autorizada | wait sobrevive à sessão; wake e consumo pela substituta; próxima ação automática com negativos UT-F3.2 (ou bloqueio explícito, não PASS) | tester + reviewer (+ security para trust boundary) |
| F4 | F1 contratos | cadeias consultivas + fail-closed demonstrado | suites Jev/Decision/McpSafety/PlannerLoop |
| F5 | descoberta F0 | matriz compat + relatório lacunas F6 | suites afetadas 2 hosts |
| F6 | F1–F5 evidências | matriz GW01..GW15 nas categorias §10 + artefatos/GW | tester + reviewer (+ security se policy) |
| F7 | matrizes F0–F6 | CLOSURE-REPORT + CHANGELOG + veredito COMPLETE/PARTIAL/HOLD | review independente |

## 12. Métricas mínimas e rastreabilidade

- **Métricas originais por frente/gate:** `objective_success`, `abandon` (com motivo),
  estados (sem `estado=0` inventado), `unnecessary_intervention`, `duplicates`,
  `unauthorized_retries`, `costs` (tempo/tokens/provider; `unknown` nunca é 0),
  `CI→resume` (waits→consumo), `MCP_unnecessary`, `regressions_before/after`.
- Por fase também: suites (nome + asserts + host), runs CI (id + conclusão), lanes/fixtures,
  reviewers (APPROVED / CHANGES_REQUIRED + achados), budgets consumidos.
- Regra de honestidade: `blocked`/`NOT_OBSERVED`/`NOT_MEASURABLE`/`unknown` documentados
  como tal; **rerun verde sem código prova só intermitência** — causa `UNKNOWN` até
  diagnóstico failure-only; nenhum gate passa com critério rebaixado.
- Orçamentos: definir **antes** de rodar (tempo, tokens/provider, sessões); runs críticos
  (F1 multifase, recovery F2, gates F6) em **≥2 sessões independentes** — proposta aqui,
  prova só após execução autorizada.

## 13. Ordem, dependências e comandos de validação

```text
F0 (inventário + Golden + observabilidade mínima + descoberta F5)
 ├─► F1 (Planner→workers→kernel)  ═══ parallels ═══  F2 (watchdog/CAS/recovery)
 │                                        │
 ├─► F4 (Jev/Advisor/MCP) depende F1 ─────┘   (não de F3)
 ├─► F5 (compat/observabilidade) consome F1, não o contrário (sem ciclo F1–F4/F5)
 ├─► F3 (waits #86 + spike) só após spike bounded autorizado; watcher por último
 └─► F6 integra gates F1–F5  →  F7 fecha (PARTIAL/HOLD publicável; COMPLETE só com tudo mandatory)
Docs incrementais ao longo (F7.3); F7 não é "fase de documentação isolada".
```

Comandos por fase (chamada direta, sem wrappers inventados — PS5.1 via `powershell`,
PS7 via `pwsh`; o runner `run-v3-tests.ps1 -Name` seleciona suites já descobertas e
executa cada filha via `powershell -NoProfile -File`, ou seja, **filhas sempre PS5.1**:
trocar o host do runner **não** converte a execução em PS7):

```powershell
# Preflight obrigatório (toda tarefa não trivial, antes da 1ª ação)
powershell -NoProfile -File scripts\v3\orchestration-preflight.ps1 -Objective "<objetivo real>" -TaskType <tipo> -Domain <dominio> -Risk <risco> -ReadWrite <read|write>
# Consistência do pacote + diff limpo (toda fase)
powershell -NoProfile -File scripts\test-package-consistency.ps1
git diff --check
# F1/F2/F6 — suites afetadas pelo nome (exemplos reais; ajustar -Name ao escopo)
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskKernel'
pwsh -NoProfile -File scripts\v3\lib\OrchestrationTaskKernel.tests.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationRuntimeWatchdogEnforcement'
pwsh -NoProfile -File scripts\v3\lib\OrchestrationRuntimeWatchdogEnforcement.tests.ps1
# F4 — Jev/Decision/McpSafety/PlannerLoop (nomes reais das suites, via -Name)
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationJevAdvisory'
pwsh -NoProfile -File scripts\v3\lib\OrchestrationJevAdvisory.tests.ps1
# F4: repetir diretamente por engine nas outras suítes customizadas afetadas
pwsh -NoProfile -File scripts\v3\lib\OrchestrationDecisionWiring.tests.ps1
pwsh -NoProfile -File scripts\v3\lib\OrchestrationMcpSafety.tests.ps1
pwsh -NoProfile -File scripts\v3\lib\OrchestrationPlannerLoop.tests.ps1
# F6: regressão Golden harness (não equivale aos gates runtime-real GW01..15)
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationGoldenWorkflows'
pwsh -NoProfile -File scripts\v3\lib\OrchestrationGoldenWorkflows.tests.ps1
# F2 lane real (recovery) + F5 smokes/diagnóstico (quando aplicável)
powershell -NoProfile -File scripts\ci\session-real-lane-v2.ps1
powershell -NoProfile -File scripts\ci\smoke-opencode-v2.ps1
powershell -NoProfile -File scripts\ci\smoke-opencode-v2-lifecycle.ps1
powershell -NoProfile -File scripts\ci\plugin-healthcheck.ps1
# Distribuição (quando tocar runtime/install/perfil)
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1
```

Sem `Invoke-Pester`: estas suítes são scripts com assertions próprias. O runner oficial
seleciona/isola as execuções PS5.1; para PS7 usar os scripts diretamente com `pwsh -File`,
respeitando os pré-requisitos e o cleanup owned de cada suíte. Registrar a engine real.
Testes novos são **proposta sem nome falso** (nomes só após criação autorizada); nenhum
harness universal novo neste programa.

Suites caras de engenharia **não** rodam para validar este documento (docs-only);
rodam nas fases, com budgets definidos antes (modelo abaixo, preencher por fase):

```text
Budget <FASE>: tempo-wall ___ | provider/modelo ___ | sessões ___ (≥2 independentes p/ crítico)
capex de evidência: paths de artefato ___ | retenção ___ | sanitização (sem segredo) ___
```

## 14. Riscos e bloqueios (comportamento fail-closed por item)

| # | Risco/bloqueio | Resposta planejada |
|---|---|---|
| R1 | Provider/modelo ausente (pernas 18/20/21/22-classe) | `PARTIAL`/`BLOCKED_OPERATOR` com perna kernel-side provada; perna model como operator-owned; nunca PASS por ausência |
| R2 | Issues #69/#70 (strict) sem mediação/atestação | estrito segue BLOQUEADO; programa prova supervisionado/cooperativo e reporta a diferença |
| R3 | F3 sem infra/scheduling autorizado | spike não executa; waits viram `BLOCKED_UPSTREAM`; webhook fora de questão |
| R4 | Credenciais (S5–S7-classe, Jev live, AI Memory) | só com credencial existente autorizada; sem credencial nova neste programa |
| R5 | Intermitência de runner (precedente race-001/watchdog/recibos) | rerun verde sem código prova só intermitência — causa `UNKNOWN` até diagnóstico failure-only (FIX3-2 incluído); sem relaxar invariante/timeout |
| R6 | Divergência machine-local tipo DE22307F | registrar, não tocar config user-owned; nunca "corrigir" para obter verde |
| R7 | Tentação de ativar flags/enforcement para "fechar" gate | proibido: gate fecha com HOLD honesto + evidência, nunca com ativação sem prova |
| R8 | Duplicata conflitante em runtime-real | janela fecha com goal terminal por desenho; cobertura harness preservada; sem replay de `pending` |

## 15. Links (relativos a `docs/plans/` — clicáveis no checkout)

- [CHANGELOG](../../CHANGELOG.md) (§[Unreleased] Ondas 1–5; §§[0.1.2]/[0.1.1]/[0.1.0])
- [CLOSURE-REPORT](../../evidence/closure/CLOSURE-REPORT.md),
  [onda2-prova-real-2026-10-14](../../evidence/closure/onda2-prova-real-2026-10-14.md)
- [f0-baseline-final](../../evidence/closure/f0-baseline-final.md),
  [f0-finding-B-wiring](../../evidence/closure/f0-finding-B-wiring.md)
- [f0-finding-C-v2-policy](../../evidence/closure/f0-finding-C-v2-policy.md),
  [f1-progress](../../evidence/closure/f1-progress.md)
- [f6-observability-closure](../../evidence/closure/f6-observability-closure.md)
- [SPEC](../specs/PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md),
  [PLAN](../specs/PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md)
- [orchestration-preflight](../../scripts/v3/orchestration-preflight.ps1),
  [task-kernel](../../scripts/v3/task-kernel.ps1),
  [run-v3-tests](../../scripts/v3/run-v3-tests.ps1)
- [NativeDispatch](../../scripts/v3/lib/OrchestrationNativeDispatch.ps1),
  [AutonomousLoop](../../scripts/v3/lib/OrchestrationAutonomousLoop.ps1)
- [ObjectiveRuntime](../../scripts/v3/lib/OrchestrationObjectiveRuntime.ps1),
  [ObjectiveController](../../scripts/v3/lib/OrchestrationObjectiveController.ps1)
- [GoalKernel](../../scripts/v3/lib/OrchestrationGoalKernel.ps1),
  [TaskKernel](../../scripts/v3/lib/OrchestrationTaskKernel.ps1)
- [PlannerLoop](../../scripts/v3/lib/OrchestrationPlannerLoop.ps1),
  [DispatchPipeline](../../scripts/v3/lib/OrchestrationDispatchPipeline.ps1)
- [JevAdvisory](../../scripts/v3/lib/OrchestrationJevAdvisory.ps1),
  [DecisionWiring](../../scripts/v3/lib/OrchestrationDecisionWiring.ps1)
- [McpSafety](../../scripts/v3/lib/OrchestrationMcpSafety.ps1),
  [GoalCheckpoint](../../scripts/v3/lib/OrchestrationGoalCheckpoint.ps1)
- [EvidenceRef](../../scripts/v3/lib/OrchestrationEvidenceRef.ps1),
  [SessionReconciler](../../scripts/v3/lib/OrchestrationSessionReconciler.ps1)
- [Watchdog](../../scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1),
  [GoldenWorkflows-tests](../../scripts/v3/lib/OrchestrationGoldenWorkflows.tests.ps1),
  [CorrectiveE2E-tests](../../scripts/v3/lib/OrchestrationCorrectiveE2E.tests.ps1)
- [session-real-lane-v2](../../scripts/ci/session-real-lane-v2.ps1),
  [smoke-v2](../../scripts/ci/smoke-opencode-v2.ps1),
  [smoke-v2-lifecycle](../../scripts/ci/smoke-opencode-v2-lifecycle.ps1),
  [plugin-healthcheck](../../scripts/ci/plugin-healthcheck.ps1),
  [agent-mcp-lane-v2](../../scripts/ci/agent-mcp-integration-lane-v2.ps1)
- [spike-v2-permissions](../../scripts/runtime/spike-v2-permissions.ps1),
  [RuntimePortPreflight](../../scripts/runtime/RuntimePortPreflight.ps1)
- [tests/f3](../../tests/f3/),
  [run-distribution-tests](../../tests/distribution/run-distribution-tests.ps1),
  [test-package-consistency](../../scripts/test-package-consistency.ps1)
- [runtime-versions](../../source/registry/runtime-versions.json),
  [capability-flags](../../source/registry/capability-flags.json)
- [verification-policy](../../source/registry/verification-policy.json),
  [jev-advisory-policy](../../source/registry/jev-advisory-policy.json)
- [mcp-profiles](../../source/registry/mcp-profiles.json),
  [execution-budget-policy](../../source/registry/execution-budget-policy.json),
  [execution-grants](../../source/registry/execution-grants.json),
  [goal-policy](../../source/registry/goal-policy.json)
- [engineering-advisor](../../source/agents/engineering-advisor.md)
