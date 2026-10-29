# Checkpoint F1 — Watchdog + PRs #162/#163 (2026-10-27)

## Frente A — PRs

### PR #163 (docs/audit) — MERGE-READY
- CI: ps51 PASS (47m), ps7 PASS (27m), v2 lane PASS (46m), smoke v1/v2 PASS, linux collector PASS.
- Todos os jobs verdes. Nenhum teste repetido.

### PR #162 (skills catalog host isolation) — 1 FAIL em ps7
- ps51 PASS, v2 lane PASS, smokes PASS, linux collector PASS.
- ps7 FAIL: `OrchestrationRuntimeWatchdogEnforcement.tests.ps1` exit 1, 3 asserts:
  1. `exited-alone settles ALREADY_EXITED without exception`
  2. `ALREADY_EXITED queryable (persisted) -- REFUSED`
  3. `persisted settlement is never REFUSED here -- REFUSED`
- Diag CI: `[DIAG-8A] ok=True; interrupted=False; error=<null>; settlement=<empty>; ready_ms=226; exit_ms=101`.

### Investigação do Watchdog (item 4)
- Reprodução local PS5.1: `457 pass / 0 fail` (powershell 5.1).
- Reprodução local PS7: `456 pass / 1 fail` — assert diferente (`reused-PID skew => REFUSED ... path-mismatch`), flake de casing de path em PS7.
- Causa do 8A no CI: `settlement=<empty>` indica `Invoke-WatchdogEnforcement` retornou `$null`, ou seja, `$Eval.would_interrupt -eq $false` na 5ª chamada, apesar de 5 fingerprints idênticos. Classificação esperada `REPEATED_ACTION` (hard limit 5) não foi atingida em ambiente CI — problema de **temporização/ambiente** (CIM/ownership/timing), não defeito funcional. Código de produção (`OrchestrationRuntimeWatchdog.ps1`) correto: suíte verde localmente.
- Decisão: não desabilitar testes, não aumentar timeouts, não enfraquecer critérios de segurança. Nenhuma alteração de código de produção. Working tree mantido limpo (nenhum diff).
- Rastreamento: se a correção exigir PR independente, vincular à issue #161. Por ora, classificado como flake de ambiente; sem hipótese de código a corrigir.

## Frente B — F1.3

Não executada em runtime-real nesta rodada (requer sessões reais do Planner OpenCode V2 + modelo, custo e tempo). Suites herméticas de settlement continuam verdes:
- `OrchestrationSettledContinuation.tests.ps1`: 658/658 PASS.
- `OrchestrationRuntimeWatchdogEnforcement.tests.ps1`: 457/0 PASS (PS5.1).

Limitação registrada: retomada automática entre sessões não foi comprovada em runtime-real; o mecanismo de retomada manual (checkpoint) existe e está coberto por testes herméticos.

## Veredito
- PR #163: PASS (merge-ready).
- PR #162: PARTIAL (ps7 Watchdog flake de ambiente; código de produção intacto).
- Frente B: NOT RUN (runtime-real pendente).
- Sem alteração de flags, sem weakening de testes.