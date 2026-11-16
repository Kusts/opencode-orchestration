# EXP controlado — Resultados (Beam vs baseline) — issue #99

- **TASK_ID:** EXP-RESULT-99
- **Data:** 2026-10-21
- **Protocolo-fonte (não editar):** `evidence/v3.1/model-router/EXP-controlled-protocol-2026-10-21.md` (oráculo + regras em §2/§5)
- **Status:** RESULTADOS — 6 runs executados pelo Planner; este arquivo registra métricas e veredito. Protocolo permanece intacto.

## 1. Oráculo (cópia de referência — autoridade permanece no protocolo §2)

1. `OrchestrationNativeDispatch.ps1` — 8510 linhas
2. `OrchestrationNativeDispatchHandoff.tests.ps1` — 4992 linhas
3. `OrchestrationTaskKernel.ps1` — 4778 linhas

Critério de `success exato`: exatamente estes 3 nomes + 3 números, nesta ordem. Qualquer divergência = `failed`.

## 2. Resultados por run

| run_id | session_id | model_requested | model_observed (session_v2) | ANSWER verbatim | tokens_in | tokens_out | cost | wall_latency_s |
|---|---|---|---|---|---|---|---|---|
| EXP-RUN-BASE-1 | ses_ea01376daffeElf1VviCmZXaZU (prefixo verificado) | default cheap | muse-spark-1.3-contributor/opencode-go | OrchestrationNativeDispatch.ps1 8510 / OrchestrationNativeDispatchHandoff.tests.ps1 4992 / OrchestrationTaskKernel.ps1 4778 | 86320 | 24998 | 0.021657301999999996 | NÃO medida |
| EXP-RUN-BASE-2 | ses_ea01376d6ffexiX316TuniqOLN (prefixo verificado) | default cheap | muse-spark-1.3-contributor/opencode-go | OrchestrationNativeDispatch.ps1 8510 / OrchestrationNativeDispatchHandoff.tests.ps1 4992 / OrchestrationTaskKernel.ps1 4778 | 100564 | 24129 | 0.021613896 | NÃO medida |
| EXP-RUN-BASE-3 | ses_ea01376d4ffeULFbi2BoizJfSX (prefixo verificado) | default cheap | muse-spark-1.3-contributor/opencode-go | OrchestrationNativeDispatch.ps1 7800 / OrchestrationTaskKernel.ps1 4778 / OrchestrationRuntimeWatchdog.ps1 4231 | 68011 | 28376 | 0.01988928 | NÃO medida |
| EXP-RUN-BEAM-1 | ses_ea00e2646ffeHzvlmAWJAuR9Iv (prefixo verificado) | opencode-go/beam-free | beam-free/opencode-go | OrchestrationNativeDispatch.ps1 — 8510 / OrchestrationTaskKernel.ps1 — 4778 / OrchestrationRuntimeWatchdog.ps1 — 4231 | 637320 | 1126 | 0.0 | NÃO medida |
| EXP-RUN-BEAM-2 | ses_ea00e263bffeISRPEm4xk6YMDV (prefixo verificado) | opencode-go/beam-free | beam-free/opencode-go | OrchestrationNativeDispatch.ps1 — 8510 lines / OrchestrationNativeDispatchHandoff.tests.ps1 — 4992 lines / OrchestrationTaskKernel.ps1 — 4778 lines | 179581 | 10844 | 0.0 | NÃO medida |
| EXP-RUN-BEAM-3 | ses_ea00e2635ffeF3h3DCqEwfEpGS (prefixo verificado) | opencode-go/beam-free | beam-free/opencode-go | STATUS: COMPLETE<br><br>KEY_FINDINGS:<br>- Largest `.ps1` under `scripts/v3/lib` by line count (including blank lines, `grep ^`):<br>  1. `OrchestrationNativeDispatch.ps1` — 8510 lines<br>  2. `OrchestrationTaskKernel.ps1` — 4778 lines<br>  3. `OrchestrationRuntimeWatchdog.ps1` — 4231 lines<br>- Spot-checked other large candidates (e.g., `OrchestrationAutonomousLoop.ps1` = 1323 lines) to confirm no larger file was missed; consistent with prior investigation.<br><br>EVIDENCE:<br>- `D:\projetos\opencode-orchestration\scripts\v3\lib\OrchestrationNativeDispatch.ps1` → "Found 8510 matches"<br>- `D:\projetos\opencode-orchestration\scripts\v3\lib\OrchestrationTaskKernel.ps1` → "Found 4778 matches"<br>- `D:\projetos\opencode-orchestration\scripts\v3\lib\OrchestrationRuntimeWatchdog.ps1` → "Found 4231 matches"<br><br>VALIDATION:<br>- Counts obtained via `grep ^` per file with limit above file size; reported "Found N matches" equals total lines.<br>- No repository files modified (read-only investigation).<br><br>RISKS:<br>- None; counts include blank lines and reflect total physical lines.<br><br>RECOMMENDATION:<br>- Return the three-line answer as requested: file name + line count, largest to smallest. | 2277492 | 3134 | 0.0 | NÃO medida |

### 2.1 Comparação item-a-item com o oráculo (nome+número+ordem → success/failed derivado)

Oráculo: [1] OrchestrationNativeDispatch.ps1=8510, [2] OrchestrationNativeDispatchHandoff.tests.ps1=4992, [3] OrchestrationTaskKernel.ps1=4778.

- **BASE-1:** [1] nome OK + 8510 OK + ordem OK; [2] nome OK + 4992 OK + ordem OK; [3] nome OK + 4778 OK + ordem OK → **success=1 (derivado)**.
- **BASE-2:** idêntico ao BASE-1 item-a-item → **success=1 (derivado)**.
- **BASE-3:** [1] nome OK mas 7800 ≠ 8510 → fail; [2] esperado Handoff.tests=4992, observado TaskKernel=4778 → fail (nome+número+ordem); [3] esperado TaskKernel=4778, observado Watchdog=4231 → fail → **success=0 (derivado)**.
- **BEAM-1:** formato com em-dashes, sem "lines"; [1] nome OK + 8510 OK; [2] esperado Handoff.tests=4992, observado TaskKernel=4778 → fail; [3] esperado TaskKernel=4778, observado Watchdog=4231 → fail → **success=0 (derivado)**.
- **BEAM-2:** formato com em-dashes + "lines" (formato tolerado; critério avalia nome+número+ordem); [1] nome OK + 8510 OK; [2] nome OK + 4992 OK; [3] nome OK + 4778 OK → **success=1 (derivado)**.
- **BEAM-3:** transcrição literal = `STATUS: COMPLETE` + KEY_FINDINGS com o conjunto `OrchestrationNativeDispatch.ps1` — 8510 / `OrchestrationTaskKernel.ps1` — 4778 / `OrchestrationRuntimeWatchdog.ps1` — 4231 (+ spot-check `OrchestrationAutonomousLoop.ps1` = 1323) + EVIDENCE com paths `D:\projetos\opencode-orchestration\scripts\v3\lib\...` → "Found N matches" + VALIDATION `grep ^` sem modificação + RISKS None + RECOMMENDATION three-line answer → fail por formato (prosa extra STATUS/KEY_FINDINGS/EVIDENCE/VALIDATION/RISKS/RECOMMENDATION em vez de resposta tabular exata); conteúdo traz o conjunto 8510/4778/4231 (Watchdog no lugar de Handoff.tests) → fail por conjunto → **success=0 (derivado por formato+conjunto)**.

- **Fonte das métricas:** `session_v2` (metadados; sem conteúdo de mensagens).
- **Latência wall-clock:** NÃO medida — declarada ausente; nenhum valor inventado.
- **Session IDs:** prefixos acima verificados; sufixos completos omitidos por segurança/privacidade de sessão.

## 3. Agregados por braço

- **Baseline (BASE):** verified-success 2/3 (BASE-1 success, BASE-2 success, BASE-3 failed — ver §2.1). Custo total = 0.021657301999999996 + 0.021613896 + 0.01988928 ≈ 0.063160478 (~$0.02/run × 3, referência dentro do baseline).
- **Candidato (BEAM):** verified-success 1/3 (BEAM-1 failed, BEAM-2 success, BEAM-3 failed — ver §2.1). Custo total = 0.0.
- **max_paid_calls=0:** modelos observados: muse-spark (BASE) e beam-free (BEAM); custo registrado BEAM=0.0; nenhuma chamada fora desses modelos nos metadados; paid adicional além do baseline = 0 (afirmação limitada aos metadados `session_v2`; não alega prova de ausência além deles).

| run_id | modelo_observado | provider_observado | cost_registrado |
|---|---|---|---|
| EXP-RUN-BASE-1 | muse-spark-1.3-contributor | opencode-go | 0.021657301999999996 |
| EXP-RUN-BASE-2 | muse-spark-1.3-contributor | opencode-go | 0.021613896 |
| EXP-RUN-BASE-3 | muse-spark-1.3-contributor | opencode-go | 0.01988928 |
| EXP-RUN-BEAM-1 | beam-free | opencode-go | 0.0 |
| EXP-RUN-BEAM-2 | beam-free | opencode-go | 0.0 |
| EXP-RUN-BEAM-3 | beam-free | opencode-go | 0.0 |

## 4. Veredito (aplicando protocolo §5 / PLAN §4, sem extrapolar)

- **Condição 2 do protocolo (verified-success não inferior):** NÃO atendida — BEAM 1/3 < BASE 2/3.
- **Decisão:** **SEM promoção** (HOLD). O candidato não supera o baseline neste workflow; nenhuma mudança de roteamento autorizada por este experimento.
- **Escopo:** n=3 por braço é descritivo; sem intervalo de confiança alegado. Veredito vale somente para este workflow (listagem determinística read-only); não generaliza para outros papéis/workflows; não autoriza F3 — promoção exigiria gate humano explícito (issue #99).
- **Modo de falha observado:** arquivo `Handoff.tests.ps1` ausente nas respostas divergentes de ambos os braços — sugere dificuldade da tarefa (nomes longos/similares, contagem exata), não diferença de modelo. Registrado como **hipótese, não conclusão**.
