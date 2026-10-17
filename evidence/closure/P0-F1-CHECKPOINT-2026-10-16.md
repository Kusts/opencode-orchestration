# P0 Checkpoint F1 — 2026-10-16 (sanitizado, sem segredos)

## Estado Git
- Branch: `fix/lane-scenario-isolation-f1` (criada nesta rodada, sem push/merge).
- Base: `master` HEAD `7a3d69898e25a66566ebe4660e79512f2f6959cf` (paridade `origin/master` 0/0, verificado por F0-INFRA-01).
- Tree suja herdada + fatia desta rodada:
  - `M .gitignore` (2 linhas `.env/` — de outra sessão, NÃO parte do F1, não commitar junto).
  - `M scripts/ci/session-real-lane-v2.ps1` (+197/-31 no diff total; inclui F1-FIX-01/02 pré-existentes + fatia nova desta rodada).
  - `?? scripts/ci/session-real-lane-f1fix01.tests.ps1` (suite F1, untracked).
  - `?? tests/f3/OrchestrationF3CorrectiveDrillsFG.tests.ps1` (de outra frente, não tocado).
  - `?? evidence/...` lanes S1–S7, closures, model1821-f1fix02/rerun (não tocados).

## Diagnóstico F1 (explorer + verificação Planner)
- Bug original pré-19 incondicional: AUSENTE/corrigido (`Test-LaneNeedsPre19Gate` 448–458 + uso 2267).
- Residual confirmado: gate pós-16/17 (2071–2078) incondicional — mesmo padrão, podia dar `Fail-Lane 'apos cenarios 16/17'` em run filtrada `@('21')`/`@('18')` com serviço caído.
- Dependências reais 16–22: serviço compartilhado (17/18/19 mutam liveness; 16/20/21/22 consomem), `$script:OpenApiPaths`, `KernelTasksDir` (TaskIds disjuntos), `EnvelopeDir` (arquivos disjuntos), probes V2-native incondicionais quanto a filtro (criam sessões reais — residual fora desta fatia).

## Correção (F1-CODER-01, branch acima, sem push)
- `Test-LaneNeedsPost17Gate` (puro, fail-closed: vazio→true; 18/19/20/21/22→true; só-16/17→false; erro→true).
- Bloco 2071–2078 envolvido em `if (Test-LaneNeedsPost17Gate ...)`; start/stop, timeouts, portas, credenciais inalterados.
- Suite `session-real-lane-f1fix01.tests.ps1`: +10 asserts predicado +2 estáticos (wrap + Fail-Lane preservada).

## Validação
- F1-TESTER-01: `70/70 PASS` PS5.1 e PS7, exit 0; `git diff --check` limpo; critérios (1)–(6) PASS sem serviço/modelo.
- F1-REVIEWER-01: APPROVED escopo fatia pós-16/17; recomendou separar commits (F1-FIX-02/03 embutidos no mesmo arquivo não integram esta aprovação).
- Gate F1: ATENDIDO para os dois gates de serviço (pré-19 + pós-16/17). Residual conhecido: probes V2-native ainda sem guarda de `ScenarioFilter` (linha 2836, só `-SkipCapabilityProbes`).

## Baseline F0 (F0-INFRA-01, read-only, nada parado/morto)
- Instalado usuário `v2.0.29` (shim `C:\Users\walis\bin\opencode.ps1` → launcher) vs harness/pin `v2.0.23` — DRIFT tolerado, lane usa binário isolado (hipótese, não re-validada).
- 4× `opencode.exe` owner `PC-JUNIO\walis`: 3628 TUI, 8208 `serve --service` global 2.0.29 filho de 3628 (:4096), 7556 `serve --service` harness V2 PPID extinto (:47615), 8348 TUI. 8208 WS ~761MB/Priv ~1261MB; sistema 15,39GB, livre 3,11GB (~1,4d uptime).
- Correlação temporal run18-go↔8208 NÃO é causalidade. Nenhum segredo exposto.

## Próximo (F2, não iniciado)
- Instrumentar trilha sanitizada de eventos (reutilizar telemetria existente) e classificar restarts (EXPECTED_TEST_RESTART / HARNESS_INDUCED / OPENCODE_RUNTIME / EXTERNAL_SUPERVISOR / RESOURCE_PRESSURE / UNKNOWN).
- Investigar `serve --service` fora de JobObject, colisão global×isolado, `opencode run --session`, supervisor externo, heartbeat/event-stream, MCP recriados, com/sem modelo.
- Não executar lanes pesadas indiscriminadamente; F5 progressiva (estática → isolado sem modelo → turno mínimo → 18/21 separados → combinado → CI).

## Veredito parcial
- F1 fatia pós-16/17: LOCAL_FIX_COMPLETE (aguarda commit separado + PR, sem merge automático).
- F2 trilha mínima: LOCAL_FIX_COMPLETE (reviewer F2-REVIEWER-04 APPROVED; tester F2-TESTER-03 PASS 88/88 + 70/70 PS5.1/PS7; follow-up LOW CONCLUÍDO nesta continuação: bloco 3c agora extrai o guard real via brace matching e o executa via ScriptBlock com settled=false/true — F2 90/90 PS5.1+PS7, F1 70/70 sem regressão).
- P0 geral: PARTIAL (F3 turno-modelo, F4 contenção e F5 runtime-real pendentes; 18/21 seguem sem RUNTIME_REAL_PASS).

## F5 Etapa B — runtime isolado sem modelo (2026-10-16, executado)
- 16: `pass-real` em 18s (12:40:18–12:40:36Z), 12/12 proofs, checks de encerramento verdes, 49374 FREE/FREE. Trilha: START→STOP→EXPECTED_TEST_STOP→FINISHED→CLEANUP, zero anomalias.
- 17: `pass-real` (stop owned + settlement + start + estado preservado). Trilha prova o restart: start PID 14516 → stop → start PID 13952 (`PID_CHANGED` + `EXPECTED_TEST_RESTART` com pid_before/pid_after) → stop final (`EXPECTED_TEST_STOP`).
- 19: `pass-real` (ausência real provada). Trilha com o mesmo padrão de restart (PID_CHANGED + EXPECTED_TEST_RESTART).
- Processos após as 3 runs: mesmos 4 PIDs do baseline F0, sem órfãos; serviço global intacto; sessão do agente sem interrupção.
- Evidência: `evidence/v3.1/runtime-reliability/session-lane-2026-10-16-p0b{16,17,19}/` (lane-summary.json + rr-e2e-*.json + lane-lifecycle-trail.jsonl).
- Pendente: Etapa C (turno mínimo com modelo) e D (18/21) exigem opt-in `-ModelKeyEnvName` com `OPENCODE_GO_API_KEY` — decisão do operador.
- D-18 CONCLUÍDO (2026-10-16, com opt-in via launcher em TEMP lendo `.env`, valor nunca logado): `RR-E2E-18 => pass-real` — child reconciliado após restart + `completed-leg-recovered` via stdout do turno (`rc=0 timedout=False job=True`, resposta "Probe acknowledged — lane18 child alive"). Trilha: restart (EXPECTED_TEST_RESTART + PID_CHANGED) → MODEL_TURN_STARTED/FINISHED → STOP final. Evidência: `session-lane-2026-10-16-p0d18/`. Nota: `rr-e2e-18.json`/`lane-summary.json` exigem leitura UTF-8 explícita (Get-Content ANSI gera `�` e quebra o parse — artefato do consumidor, não corrupção). O shell de background morreu no restart do servidor global (8208→12308) APÓS a lane gravar FINISHED+CLEANUP — sessão do agente intacta.
- D-21: 5 tentativas com modelo, todas `blocked` (veredito fail-closed correto). r1 muse-spark/180s: 1 texto + stall. r2 (prompt sem delegação): reads diretos, timeout na navegação. r3 (300s): 1 texto + 0 tool calls — timeout maior REVERTIDO (não ajuda). zai/glm-5.3-flash: 429 quota sem saldo (provider-side, credencial expirada confirmada pelo operador). gpt-6-luna: 0 texto, stall. deepseek-v4.1-flash (mesmo provider do 18-pass): 0 texto, stall. Conclusão: gargalo é o task-shape do 21 (turno na substituta nunca converge), não modelo/provider/timeout/harness. `-TurnModel` adicionado à lane (default baseline, validado offline) para futuros experimentos. Sem novas tentativas de modelo nesta frente.
- Padrão de restarts 2026-10-16: 3 restarts do servidor global coincidindo com lanes com turno de modelo (18, 21, 21r2); serviço isolado da lane NUNCA afetado (trilhas limpas, cleanups ok). Causa segue UNKNOWN (correlação, não causalidade).
- Diagnóstico final 17/10 (evidência convergente, 7 shells mortos): NÃO é restart do servidor — todas as lanes concluíram (FINISHED), o kill atinge só o shell observador. (a) Zero boots no opencode.log em 3 dias; (b) zero erros Application em 48h; (c) zero warnings Resource-Exhaustion em 48h (memória 3.11→1.5GB sem flag do Windows); (d) event-stream connecting(attempt=1)+connected em pares, DEZENAS de vezes/dia, com e sem lanes; (e) 15/10 01:09: 4 MCPs mortos em 5s e relançados; (f) PIDs serve giram entre dias sob TUIs (8208→8980 em 17/10 08:37 — ciclo normal). Classificação: EXTERNAL_TRANSPORT. Correção: alegação "8208→12308" anterior nunca foi observada com ownership — retirada. Mitigação futura: spawn destacado + pickup por arquivo.
- Branch limpa PR-ready `pr/f1f2-lane-isolation-trail` (05b6db2, sem push): master + SOMENTE hunks P0 desta rodada (16 MINHA + Post17Gate + pre19-trail adaptado + turn-trails + lane-final guard + prompt-21-no-delegation), verificada em worktree scratch (f2trail 90/90 PS5.1+PS7, post17gate 17/17, diff-check limpo). Nota honesta: 18-pass-real usou matcher cli_bound de outra sessão (fora desta branch); esta branch precisa daquele merge para reproduzir o 18.
- PR #97 ABERTO (2026-10-16, sem merge): push de `pr/f1f2-lane-isolation-trail`, base master, com notas honestas no corpo. Aguardando review/merge do operador.
- PR #97 MERGED (2026-10-16T21:41:45Z, CI 6/6 verde): F1+F2 no master. Worktree scratch removido.
- PR #98 MERGED (2026-10-17, CI 6/6 após update-branch; autorizado pelo operador): hunks F1-FIX-01/02/03 (framing, cli_bound, Pre19Gate) no master. Com isso, o master contém matcher cli_bound + framing + Pre19Gate + F1/F2 + TurnModel + evidências — 18 reproduzível a partir do master.
- PR #100 MERGED (2026-10-17, CI 6/6 após re-run do smoke v2 — falha inicial era RR-E2E-08 flaky, sem relação com o diff): TurnModel + 10 dirs de evidência + docs de fechamento no master. (Worktree scratch p0-publish mantida em TEMP por remoção exigir --force; conteúdo já publicado, descarte seguro posterior.)
- Limpeza 17/10 (branch P0, commit d56dc46): lane restaurada ao master (suites 90/90 re-validadas) — hunks alheios vivem no PR #98; `.gitignore` alheio guardado em `stash@{0}` (reversível); untracked restantes (lanes S1-S7, closures, model1821-*, f1fix01, drills FG, `.env`) são de outras sessões — não tocados.
- Nota histórica (lado origin/master, superada): PR #98 DRAFT (2026-10-17) — hunks alheios F1-FIX-01/02/03 montados sobre master pós-97, suites verdes; NÃO mergear sem o autor. (Resolvido: PR #98 foi MERGED acima.)

## F2/F3 static mapping (2026-10-16, sem execução, sem escrita)
- F2-INFRA-01 candidate_pass: lifecycle isolado explícito (svcJob único KILL_ON_JOB_CLOSE, set port 1x, start com job, stop sem job + settlement absence + start com job, final stop+settle+backstop+Close+finally). Sem supervisor/daemon/heartbeat/auto-restart no código. Escape limitado e honesto: só `service start` e `opencode run` levam JobObject; `service stop`/set port/api/kernel/npm/V1 sem job (timeout sem job = root-only). Tracking hoje é booleano (`Wait-LaneListener` Seen/Absent/Inconclusive, sem captura de PID). Colisão: 49374 nunca usada + invariante, porta livre, TargetHome exclusivo. Todos os restarts no código = EXPECTED_TEST_RESTART (17:2030/2035, pós-17:2093, 18:2147/2149, pré-19:2290, 19:2324/2326; final 3039 = EXPECTED_TEST_STOP). Proposta: trilha JSONL mínima reutilizando padrão `Write-AcceptanceTelemetry` (advisory-only, sanitizada) + captura OwningPID em `Wait-LaneListener` + snapshot `Get-RuntimeJobMemberPids` (~10 linhas novas); até lá, PID_CHANGED/UNEXPECTED_EXIT = NOT_OBSERVED.
- F3-EXPLORER-01 mapped-static-only: turno CLI `Invoke-LaneModelTurn` (model-key opt-in, sem ela blocked), decisão pura `New-LaneModelTurnOutcome` (--format json, retry só `Model unavailable` + JobAssigned), nativa REST `Invoke-LaneNativeTurn` (before/post/wait/after, cursor tri-state, cap 5 págs), matcher `Test-LaneTurnEvidence` (só assistant/tool sem erro, cli_bound duplo vínculo, canário+state mesma unidade), substantivo = ok + (role OU cli_bound) janela 1200 (hollow abre nativa, sem nativa prevalece CLI), limpeza com job próprio por turno. Evidências model1821: 18 hollow-ok + messages-before-invalid = blocked; 21 TIMEOUT rc=-1 + messages-before-invalid = blocked. Prompts atuais mínimos (18 completion-probe, 21 read-file + CHAL21 fora do prompt). Recomendação: não afrouxar matcher/caps/timeout; refino F3.4 só no texto do prompt.
