# F0 — Finding B: wiring F3/F4/F5/F6 (issue #51, #60, #61, PR #71, 2G)

Fonte: subagent ses_ecf21e6c2ffeG0aNWExxzGRmjd, STATUS candidate_pass, read-only.
Data: 2026-10-12. Sem escrita/ativação, sem segredos (só nomes de env).

## F3 — Autonomous Core Planner→Kernel

- Intent: OrchestrationObjectiveRuntime.ps1:New-OrchestrationDispatchIntent (goal+work_item+revision → key idempotente, state intended); ConvertTo-ORDispatchRecord / Get-ORIntentFilePath (intended→dispatched-unknown→pending→settled→checkpointed→advanced + held/reconciled).
- Executor de 1 evento: Invoke-OrchestrationObjectiveStep / driver Invoke-OrchestrationAutonomousObjective em OrchestrationAutonomousLoop.ps1; finalização só via Set-OrchestrationGoalStatePersisted com Test-ObjectiveCompletionAllowed.
- Sem Executor → AutonomousLoop retorna dispatch_intent ao Planner (subagent nativo V2 / task V1); com Executor → recibos idempotentes + AdapterContract + TaskKernel.
- Nativa: OrchestrationNativeDispatch.ps1:Invoke-OrchestrationNativeDispatch (envelope New-NDDispatchEnvelope); fases Prepare/Claim/Settle/Advance; host validado por Test-NDHostCallDescriptor (+ Test-NDHostAgentName, Test-NDChildSessionId) — claim não-verificado por construção.
- Settlement: Invoke-OrchestrationNativeDispatchSettle + gates Test-NDSettledReceiptFieldShape/Persisted/HandoffProof/HandoffSettledMarker; worker declara candidate_pass|failed|blocked; verified_pass/done/approved rejeitados. TaskKernel: Set-OrchestrationTaskWorkerResult → Verification → Review → Test-OrchestrationTaskCompletion → Complete-OrchestrationTask. Grants: Get-OrchestrationEffectiveGrants (interseção baseline∩grants∩runtime∩ambiente).
- Planning puro: OrchestrationPlannerLoop.ps1 (planning only, never dispatches) → OrchestrationDispatchPipeline.ps1 (record-only, sem spawn/rede/mutação).
- Estado: harness + HOLD honesto. ObjectiveRuntime D1 HOLD; ObjectiveTelemetry TEST HARNESS (harness_level=true, runtime_real=false); runtime-real com live OpenCode HOLD/BLOCKED. TaskKernel enabled:true + 8 features V2-native hold-unproven; runtime_grant_enforcement.v2=OFF.

## F4 — Jev + Advisor

- Duas vias: (a) MCP nativo consultivo via mcp-profiles.json:research (context7+jev; researcher/architect/engineering-advisor); resolução shadow Phase2F. (b) Advisory kernel-side OrchestrationJevAdvisory.ps1 (flag jev_advisory; policy v1: 4 tools, budget 30s, circuit 2/300s, credential só nome JEV_API_KEY, transport só nomes, advisory-only + cannot[8]).
- Wiring: OrchestrationDecisionWiring.ps1:Invoke-OrchestrationDecisionWiring (Rules → JevAdvisory → Planner envelope fechado); mapa pergunta→tool; PlannerLoop caller P38-S2.
- Trigger: Test-JevAdvisoryTrigger (trivial_local never consults; primeiro boundary flag vence). Fallback JEV_UNAVAILABLE → determinístico (fallback_continue=true, blocked=false); policy divergente → JEV_POLICY_INVALID fail-closed. Envelope: OrchestrationMcpSafety.ps1:Invoke-McpSafetyCall (advisory 30s, runspace fresco, cap 8, circuit per server/capability/turn).
- Grant gate: Invoke-JevAdvisoryGrantGate sempre nega; Get-JevAdvisoryEffectiveDecision dobra Jev sob kernel/verifier; envelopes com grants_authority=false, done_approved=false, verified_pass=false.
- Advisor: source/agents/engineering-advisor.md (edit/bash/task deny; forbidden code.bounded-edit/database.migration/infra.deployment; não coordena, não cria subagentes). Deadlock #60 F2: entrada mínima senão BLOCKED; saída diagnóstico + 1 próxima ação + rollback; Jev auxiliar opcional.
- Estado: flag enabled:true shadow:false (lote operador 2026-10-04); transporte real user-owned fail-closed, sem exact-binary-live; evidência parcial: healthcheck installed+configured + probe HTTPS TLS1.3 401 fail-closed (2026-10-06). Advisor: prova harness + contrato ativo.

## F5 — Browser MCPs

- Perfil mcp-profiles.json:testing APPROVED opt-in (nunca global): playwright-mcp + chrome-devtools-mcp; agents tester/frontend-engineer/debugger/reviewer/backend-engineer; risk medium; --isolated+--headless+opt-outs.
- Isolamento: Playwright local stdio --headless --isolated; DevTools local stdio --headless --isolated --no-usage-statistics --no-performance-crux, full sem --slim; isolamento perfis V1/V2 e worktrees p/ writers paralelos.
- Schemas reais (npx stdio 2026-10-07): Playwright 0.0.83, 25 tools (browser_run_code_unsafe + browser_evaluate restritos); DevTools 1.10.1 full, 30 default (+14 memory/+5 extensions/+2 third-party/+2 WebMCP/+4 PWA).
- Agents: tester.md (edit deny, bash allow-default com denies + ask deploy/publish; PASS/FAIL); debugger.md (edit deny, bash deny-by-default; read-only root-cause).
- Estado: capability APPROVED opt-in (prova real sem credenciais); ativação opt-in operador; pilots 2E advisory-only shadow.

## F6 — Coletor 2G

- Coletor: OrchestrationEvolutionTelemetryProducer.ps1:Invoke-OrchestrationTelemetryProduction (Phase 41 S1) — max 64 arquivos, ordenação ordinal, reasons sanitizadas, contadores declarados, fingerprints, gate attempt_n; record_type=EVOLUTION_TELEMETRY bounded.
- Contratos: CapabilitySkillUtility.ps1 (explicit-only, NOT_OBSERVED default; skill_routing OFF); CapabilityOutcomeValidation.ps1 (GOOD/ACCEPTABLE/SUBOPTIMAL/WRONG/NOT_ENOUGH_EVIDENCE; NOT_MEASURABLE); OrchestrationTelemetry.ps1 / OrchestrationEvolutionLoop.ps1.
- Lacuna: ObjectiveTelemetry só tem agregados, sem evento por-decisão de seleção nem por-execução (prepare/claim/settle, child-session, attempt_n, verificação). Kernel nunca escreve alguns campos lidos pelo producer; skill accepted/used/helpful exige evento nativo ausente → NOT_OBSERVED. Telemetria fragmentada (McpSafety/Watchdog/Jev JSONLs próprios) sem junção canônica seleção→execução→settlement.
- Estado: harness + HOLD (skill/mcp/adaptive/routing_telemetry OFF).

## Riscos (não confundir)

1. intent/dispatch_intent/diary ≠ autoridade DONE (só kernel/verifier/reviewer/security).
2. Prova de capability browser ≠ ativação (opt-in operador; pilots shadow).
3. Jev enabled ≠ transporte provado (operator-owned, sem exact-binary-live).
4. Telemetria fragmentada + campos nunca escritos induzem leitura errada.

## Recomendação

Manter HOLDs; eventual F6 exige contrato canônico seleção→execução→settlement (issue separada, sem ativar flags aqui).
