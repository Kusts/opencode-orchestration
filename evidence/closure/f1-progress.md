# F1 — Progresso (IN_PROGRESS)

## Logs autenticados baixados (FATO)

- evidence/closure/ci-logs/pr59-ps7-full.txt (931KB): 80/90 PASS, 1 FAIL, 9 SKIP. FAIL único: `[FAIL] concurrent same-revision transitions: exactly one wins (0) and one CAS_CONFLICT (3)` — TaskKernel 74/75, suite exit 1 após 47.6s. Ou seja: o FAIL do PR59-ps7 é o teste CAS race-001, o mesmo objeto do PR65. A fixture do PR59 (contenção de telemetria) passou; o que quebrou foi a corrida CAS pré-existente.
- evidence/closure/ci-logs/pr65-ps51-full.txt: 4 FAILs watchdog F1 (single-resolution register bound; interrupt settles SETTLED; interrupted child gone; one root + one per descendant). Não é CAS — é timing do watchdog no runner ps51.
- evidence/closure/ci-logs/pr65-v2lane-full.txt: 7 FAILs JOB48 (raiz atribuída, ALREADY_EXITED, FIX2 interrupted/TerminateJobObject/skip, tardio, registro persistido). Watchdog JOB48 na v2 lane.
- evidence/closure/ci-logs/pr66-v2lane-full.txt: 1 FAIL (F1 child exited externally). Watchdog F1 na v2 lane.
- evidence/closure/ci-logs/pr66-diff.txt: diff confirma comment-only em ci.yml (só cabeçalho: 3→6 jobs, jobs-vs-checks) + GOVERNANCE + lifecycle-policy. Sem steps/comandos alterados.

## Classificação atualizada (FATO vs HIPÓTESE)

- PR59-ps7: FATO que o FAIL é race-001 (74/75). HIPÓTESE restante: classe da corrida (CAS-real vs contenção vs spawn vs timeout) → TASK CLOSURE-F1-RACE (debugger) em andamento.
- PR65-ps51 e v2lane: FATO que os FAILs são watchdog F1/JOB48, não CAS; a mudança do PR65 é test-only no TaskKernel e não toca watchdog. HIPÓTESE: flake de timing de runner → confirmar via reconcile + rerun.
- PR66-v2lane: FATO que o FAIL é watchdog F1 externo à mudança docs-only. HIPÓTESE: flake → reconcile + rerun.
- Branch protection: FATO — 5 required checks (ps51, ps7, smoke-v1, v2-lane, smoke-v2), strict:true, sem alteração não autorizada. Confere com o texto do PR66.

## Workers em andamento

- ses_ecf1adb00 (coder CLOSURE-F1-PR59): merge origin/master na worktree capabilities-runtime-validation + teste negativo de contenção sob TEMP PS5.1/PS7. Ownership exclusiva daquela worktree.
- ses_ecf1af8f3 (debugger CLOSURE-F1-RACE): causa raiz race-001, read-only + repro sob TEMP. Sem sobreposição de escrita.

## Pendente

- Reconcile PR65/PR66/PR71 (após resultado dos dois workers; PR66 via docs-manager).
- F1.4 watchdog FIX4-2b: consolidar com estes 3 FAILs novos (F1 ps51, JOB48 v2lane, F1 v2lane) — evidência de flake de timing em 3 runs distintos.

## PR59 (update)
- Review independente: APPROVED (ses_ecf177267, sem findings; limitação: 372/372 não reproduzidos pelo reviewer).
- Push fast-forward 3fb4f48..bdd0e3b executado; CI nova aguardando trigger (última lista ainda só mostra runs 38102967919/38098269922).

## Race-001 experimento local (10 reps, branch PR65 instrumentada, PS5.1)
- Resultado: 10/10 PASS (94/94), zero DIAG, evidence/closure/ci-logs/race-reps-ps51.txt.
- Combinado com CI (1 falha em N runs; race passou no run pr65-ps51): veredito honesto FLAKY-TIMING não classificado em definitivo; CAS protegido por FileShare.None sem janela encontrada; timeout de runner eliminado no incidente (waits True, suite 47.6s). Nenhuma alteração de Kernel justificada; instrumentação do PR65 capturará a próxima ocorrência.
- CI novas em curso: PR59 run 38276542848 (in_progress), PR73 run 38277006900 (in_progress).

## PR66 merged (3b58d82); PR65 run2 (38314536224)
- PR66: 6/6 verde + review APPROVED => MERGED 2026-10-12T22:36Z. Master em 3b58d82.
- PR65 run2 ps51: TaskKernel 94/94 (race-001 com fix passou); 1 FAIL em OrchestrationNativeDispatchReceipts harness-exception (contenção de arquivos em GetFiles de recibo, suite fora do escopo do PR65). v2lane passou (JOB48 verde desta vez). Veredito: flake de contenção de harness, sem defeito de produto; rerun do job falho disparado (gh run rerun --failed), sem mascaramento.

## F1.4 watchdog consolidation (5 instâncias)
- pr65-ps51 run1: 4 FAILs F1 (single-resolution/interrupt-settles/child-gone/root+descendant).
- pr65-v2lane run1: 7 FAILs JOB48.
- pr66-v2lane: 1 FAIL F1 (child exited externally).
- pr65-ps51 run2: 1 FAIL receipts harness-exception (contenção GetFiles) + TaskKernel 94/94 + v2lane verde.
- master-pr59merge v2lane (38313853724): 4 FAILs JOB46 negative (attach recusado; settlement REFUSED vs SETTLED esperado idêntico; raiz/árvore não mortas via CIM; stable core divergente pos vs neg). Rerun --failed disparado: se verde => flake; se vermelho idêntico => regressão real dos 31 commits do merge, exige bissecção. Deadline e expectativas de segurança preservados; nenhuma correção sem classificação.

## PR74 (terceiros, fora do escopo — sem toque)
- Arquivos: AGENTS.md, capability-planning-v2.md, install.ps1, test-package-consistency, adapters/opencode-v2.md, templates/opencode.v2.json.tmpl, distribution tests, uninstall.ps1.
- Colisão funcional com F3: baixa (sem scripts/v3/lib). Colisão textual possível em install.ps1 (3+/2- no PR74 vs meu comentário #62) e AGENTS.md. Decisão de escopo/merge com o autor do PR74 pendente do operador.

## PR71 reviews
- Técnico (ses_ecdb589e): CHANGES_REQUIRED REFUTADO pelo Planner — New-LaneApiSession DEFINIDA em :1337, usos em :1366/:1538/:1633 no mesmo escopo externo e posteriores; relato do reviewer truncado/garbled + STATUS failed. Sem defeito.
- Segurança (ses_ecdb571c): CHANGES_REQUIRED VÁLIDO — cópia auth.json/account.json (:543-574) antes do gate (:1245-1249). Coder corrigindo (cópia pós-gate + teste negativo).

## PR71 gates2 + push
- GATES2: ancoragem ^ + corte out=[...] + close-falha/proc-desconhecido em stopFailures; suite 78/78 VERIFICADA EM EXECUÇÃO pelo Planner (exit 0) + diff --check limpo. Commit 498188c + push 1101d28..498188c. Reviews: security APPROVED; técnico com 3 MEDIUMs endereçados em 3 rodadas (1 refutado, 5 corrigidos com prova comportamental). CI nova aguardando.

## F1 fechamento (PRs 59/65/66/71 merged)
- PR65: rerun ps51 SUCCESS (flake de harness de recibos limpo) => MERGED 23:35:01Z. TaskKernel 94/94 com instrumentação failure-only.
- PR71: CI SUCCESS (run 38319742324) => MERGED 23:35:29Z. Security APPROVED; técnico: 1 refutado + 5 corrigidos com prova comportamental (suite 78/78 verificada em execução pelo Planner).
- Master 3d7b88a; CI pós-merge em curso (runs 38322895579 + 38322941042).
- F1.4: todos os flakes watchdog (F1/JOB48/JOB46/receipts) limparam no rerun sem mudança de código — flake de timing de runner, não defeito. Deadline/expectativas preservados.

## F3 tester sem shell
- Tester ses_ecd47131: shell negado no runtime worker; validação estática apenas (111 asserts conferem, N1-N7 presentes, hermeticidade TEMP, sem spawn/rede). Re-execução pelo Planner após o fix do coder.

## Advisor F4 real (JOB46) + desfecho
- Consult deadlock completo sobre caso real: diagnóstico flake-timing (positive irmãos verdes, série F1.4), 1 ação (ler rerun), antirreconsulta e falso-trigger declarados, Jev dispensado com justificativa, métricas ~2-3min/~5k tokens.
- DESFECHO: rerun 38313853724 => SUCCESS (v2lane verde) — critério de falsificação resolvido a favor de flake. F1.4 consolidado como flake de timing de runner.

## F4 Jev suites (execução Planner, master 3d7b88a limpo)
- JevAdvisory 159/159 exit 0; DecisionWiring 28/28 exit 0; McpSafety 203/203 exit 0; PlannerLoop 41 checks PASS (R2 dirimido: 41 é a contagem vigente, 36 era número histórico).
- Chamada real Jev (transporte HTTP, turno closure-f0-003): JEV_ADVISORY_OK consulted=True 1028ms, decide route=sequential conf 0.22, usage input 355/output 35. Fail-closed sem credencial em código (JEV_UNAVAILABLE). Restante #61 (exact-binary-live, pernas model) operator-owned.

## PR75 ps51: watchdog enforcement 88/89
- FAIL único: [FAIL] unexpected error: Cannot convert value to type System.String após 'F1 stale-instance ownership verified' (OrchestrationRuntimeWatchdogEnforcement.tests.ps1). Suite fora do escopo do PR75 (só adiciona tests/f3/); master verde nos mesmos testes. Hipótese: flake de forma CIM no runner. Rerun --failed para confirmar.

## PR75 run2: F3 no runner oficial + receipts flake repetido
- F3ThreePhaseFixture executou no runner V3 oficial e PASSOU (exit 0) — discovery P1 resolvido e provado em CI.
- FAIL único: receipts harness-exception GetFiles (mesma classe do PR65-run2, até mesmo receipt id 84c13c00). Flake de contenção recorrente do harness de recibos — candidato a item próprio (retry ou varredura tolerante), sem bloquear este PR. Rerun --failed disparado.

## Master pós-#76 (38391699516): 2 FAILs ambientais
- ps51: watchdog enforcement F-B orphan-exclusion (4 FAILs) — mesma família timing F1/JOB46/JOB48; PR76 é docs-only.
- smoke-v2: preflight porta 54133 PORT_STALE_OR_UNKNOWN (fail-closed correto) — ambiente do runner, sem relação com o merge.

## Master pós-#76 rerun: 6/6 SUCCESS
- F-B orphan + porta 54133 limparam sem código — flakes ambientais confirmados. Master verde. Ajuste estrutural (diagnóstico F-B failure-only, PR82) em curso como item próprio.
