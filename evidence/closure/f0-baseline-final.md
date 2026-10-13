# F0 — Baseline FINAL (Gate F0)

Data: 2026-10-12. Owner: Planner (DETERMINISTIC_FALLBACK).
Participação observada: 3 explorers (ses_ecf22a10/A, ses_ecf21e6c/B, ses_ecf2197c/C) — todos candidate_pass, read-only.
Jev: JEV_ADVISORY_OK consulted=True, route=sequential conf 0.22 → tratado como dado; discovery paralela read-only + integração sequencial.

## 1. Baseline consistente

- HEAD master 6a7bb9d2ec94, tree LIMPO, sem perda de trabalho local.
- CI master verde (38266794399 success 2026-10-12T14:58Z + 2 anteriores).
- Runtime: opencode 2.0.27 instalado vs pin 2.0.23 (drift +4 patch, sem bump/upgrade); bun 1.3.14 = pin.
- Flags intocadas: task_kernel/bounded/watchdog/jev_advisory/worktree ON; router shadow+active OFF; skill/mcp/adaptive/routing_telemetry/reconciler OFF; enforcement v1+v2 OFF; runtime_support v1+v2+dual ON.
- 11 worktrees preservadas. Issues de escopo: #51, #60, #61, #62, #69, #70, #21 (+ #59/#65/#66/#71). Backlog: #50, #48.

## 2. Matriz única de pendências

| PR | Branch @ head | Arquivos | CI no HEAD | Causa (FATO vs HIPÓTESE) | Bloqueio | Aceite |
|---|---|---|---|---|---|---|
| #59 telemetry confinement | feat/opencode-capabilities-runtime-validation @ 3fb4f48 | phase2d.tests.ps1 M(+25/-4), docs audit A(+134), evidence runtime-audit.json A(+131) | 4/5: ps7 FAIL (run 38102967919); ps51/v2-lane/smokes PASS | FATO: fixture quebra sob TEMP aninhado; ps51 verde + ps7 vermelho no mesmo HEAD. HIPÓTESE: flake engine/runner ou ambiente, não regressão. Sem logs autenticados, não classificável | Gate: logs autenticados do job ps7; rerun negativo em worktree sob TEMP; sem merge com vermelho | Teste negativo de contenção verde PS5.1+PS7, fail-closed preservado, sem regressão distribuição/telemetria, review independente |
| #65 CAS diagnostics | fix/pr59-cas-diagnostics @ aa3ba84 (commits 1af3dbc5 instrumentação, bf003f80 redação, aa3ba84 merge master) | OrchestrationTaskKernel.tests.ps1 M(+323/-7), só instrumentação failure-only | 3/5: ps51 FAIL + v2-lane FAIL (run 38149341433); ps7/smokes PASS | FATO: mudança test-only, não altera Kernel/outcome/lock/state machine; alvo race-001 (2 child mesma revisão, espera 0,3). HIPÓTESE: timing/race/runner-lento. Sem logs, teste-desatualizado vs ambiente indistinguível | Gate: logs autenticados ps51 + v2-lane; coletar exit codes/revisões/estado com a instrumentação; sem aumentar timeout sem justificativa; sem alterar semântica Kernel | Concorrência same-revision + CAS + invariantes verdes; só defeitos comprovados corrigidos; checks+review |
| #66 CI policy | docs/ci-check-policy-2026-10 @ a883dae (1 commit) | ci.yml M(+15/-2, só comentários), GOVERNANCE.md M(+12/-3), github-lifecycle-policy.md M(+46/-7) | 5/6: v2-lane FAIL (run 38158278853); demais PASS | FATO: diff ci.yml só comentários (jobs-vs-checks), sem steps/comandos; docs não afetam runtime. HIPÓTESE forte: falha v2-lane é V3/distribution pré-existente (phase2d) ou ambiente, não este PR | Gate: confirmar merge policy + branch protection intactos; vincular falha v2-lane a causa externa com evidência | Docs refletem 6 jobs vs 5 required checks; sem alteração não autorizada em protection; CI/review |
| #71 browser MCPs | feat/opencode-v2-agent-mcp-integration @ 1101d28 (1 commit) | lane agent-mcp-integration-lane-v2.ps1 A(+1566), agent-mcp-integration.tests.ps1 A(+165), fixtures index/error.html, mcp-profiles.md M(+35), 3 evidências lane-*.json, .gitignore M(+1) | 6/6 PASS (run 38238620561) | FATO: PARTIAL — S1-S4 pass-real em V2 2.0.26 (pin_drift documentado), S5-S7 blocked OPERATOR_ACTION_REQUIRED (sem OPENCODE_GO_API_KEY); suite estática 47/47; distribuição 20/22 com phase2d FAIL pré-existente coberto pelo #59 | Gate: revalidar S1-S4 pós-master atual; S5-S7 só com credencial existente autorizada; revisão técnica+segurança | Tester→Playwright e debugger→DevTools no perfil testing, acesso indevido negado, isolamento processo/perfil, cleanup, sem mutação global |

Conflitos: FATO — zero sobreposição de arquivos entre os 4 PRs (conjuntos disjuntos via files API). Dependência conceitual: 65 nomeado fix/pr59-cas (origem no contexto 59) sem tocar mesmos arquivos; 71 declara gate com #59/#65/#66 intactos e phase2d FAIL coberto pelo #59. Mergeable=true nos 4; 59/65/66 unstable (checks vermelhos), 71 clean. Risco textual de merge: baixo.

## 3. Registro de ambiente e CI

- Runs: master 38266794399/38266335136/38245310121 success; PRs: 38102967919 (59), 38149341433 (65), 38158278853 (66), 38238620561 (71).
- Limitação honesta: annotations API genéricas ("exit code 1"); logs de job exigem auth — causas acima marcadas HIPÓTESE por exigência do plano (regra 9).
- F0-C (V2-only): 8 contradições prospectivas p/ F2; V1 legado intacto; drift 2.0.27 com precedente de não-bump; testes V2 sem dependência V1 nova.
- F0-B (wiring): F3 harness+HOLD; Jev grant-gate nega sempre; Advisor read-only; Browser capability APPROVED opt-in; F6 sem eventos canônicos seleção→execução→settlement.

## 4. Plano de integração seguro

1. F1: reconciliar cada branch com master em sua worktree existente (fetch + merge master, sem rebase destrutivo, sem force-push); baixar logs autenticados dos 4 jobs falhos antes de qualquer re-run.
2. F1.1 (#59): rerun negativo de contenção em worktree sob TEMP, PS5.1+PS7; preservar fail-closed; só então review+merge.
3. F1.2 (#65): usar a instrumentação para coletar exit codes/revisões/estado; classificar CAS-real vs contenção vs corrida vs timeout; corrigir só defeito provado; sem relaxar segurança/timeout.
4. F1.3 (#66): validar que v2-lane FAIL é externo (vincular ao mesmo phase2d/ambiente); checar protection; merge docs após verde.
5. F2: aplicar edições mínimas V2-only (lista F0-C) sem tocar valores de flags nem config instalada.
6. F3–F6: fixtures isoladas + evals reais; manter HOLDs/enforcement OFF; #69/#70 só fecham com mediação/atestação provadas.
7. F7: suites integradas + Golden mínimo + revisões independentes; sem bypass/force-push; relatório com READY vs BLOCKED_UPSTREAM/HOLD separados.

**Gate F0: PASS** — baseline consistente, nenhum trabalho perdido, divergências mapeadas, matriz com evidência/responsável/bloqueio/aceite, plano seguro. Fato vs hipótese separados em todo o relatório.
