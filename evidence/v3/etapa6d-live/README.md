# ETAPA-6D prova viva — resumo honesto (2026-10-31, rodada controller produtivo)

Resultado: tick real disparou via schtasks.exe, mas SEM RESUME.
Readiness live = REVIEW_PENDING (PR 181 sem approval). SCHEDULED provado
no tick anterior; RESUMED/DISPATCHED pendentes de approval + CI do novo
SHA. Nenhuma cadeia completa alegada. ETAPA_6D_READY segue BLOQUEADO
ate approval + re-execucao com GH_WAKE_SCHEDULED+RESUMED+DISPATCHED na
mesma jornada.

## Lacunas corrigidas nesta rodada (docs + produto ja diffado, sem READY)

- (A) Executor `observed_at` obrigatorio: `executor_present:true` sem
  `observed_at` valido/fresco (dentro de MaxAgeSeconds, sem futuro
  além de 60s) => `no-executor`, nunca RESUME. Scheduler sozinho
  nunca conta como executor.
- (B) Settlement session-bound: `Set-GHWakeDispatchSettlement`
  (Claim session token + Settle com session id real do Planner);
  sem session id real nunca `dispatched`/`executed=true`.
  Probe-positivo => `controller-responded` (não execução);
  `intent-ready` => `prepared-awaits-planner-dispatch`.
  Sem API de resume externa: retomada = intent + Planner em sessao
  ativa via `-SettleSessionId` no driver single-shot.
- Suites atuais: wake 226, controller 253, resume 107,
  reconcile 116, package 16/16.

## Gates pendentes

- Approval humano legitimo nao-self no PR 181
  (`SELF_REVIEW => POLICY_BLOCKED`; sem excecao docs-only).
- CI verde no novo SHA + re-execucao do tick agendado observando
  RESUME live (unblock Kernel BLOCKED->IMPLEMENTING).
- Planner executa via subagent e settle com session id real
  (DISPATCHED). Só então ETAPA_6D_READY sai de BLOQUEADO.

## IDs correlacionados

- PR: 181 (`Kusts/opencode-orchestration`, branch `feat/full-delivery-etapa-6d`)
- HEAD: `ece501ed0815616902bb57b2050f280d8ee40fbb`
- Run: `41200510501` (conclusion success, headSha confere, updatedAt 2026-10-31T14:00:20Z)
- Goal: `live6d-20261031-155642` | checkpoint: `351e3c0637f4960c`
- dedup_key: `github-resume:v1:kusts/opencode-orchestration:181:ece501ed0815616902bb57b2050f280d8ee40fbb:1`
- Tasks: A `live6d-task-a` DONE rev 9 | B `live6d-task-b` BLOCKED rev 3 (inalterada pos-tick)
- Scheduled task: `ETAPA6D-LIVE-TEST-F53A9C61`
- Tick: `2026-10-31T15:59:12.2102915Z` (SCHEDULER_POST fired=true, LastResult 0)

## O que o tick observou (tick-out.json)

- `b_decision=KEEP_WAITING`, `b_reason=pending`, `b_readiness=REVIEW_PENDING`
- `b_transport=gh-query`, `b_attempts=1`, `b_confirmed=false`, `b_kernel=not-attempted`
- `resumed=0`, `evaluated=1`, `resume_authorized=false`, `next_action=null`
- Reinvoke em processo fresco: mesmo KEEP_WAITING/REVIEW_PENDING, kernel intacto.

## Arquivos

- `etapa6d-live-proof.jsonl` (60 linhas): trilha bruta completa (SETUP, GOAL_CREATED,
  TRANSPORT_PROBE, LIVE_SNAPSHOT, RUN_CORROBORATION, CONFIG, SCHEDULE_REGISTER,
  SCHEDULER_PRE/POST, SCHEDULED_TICK, KERNEL_POST_TICK, STEP8_BLOCKED, REINVOKE, UNREGISTER).
- `tick-out.json`: out do tick agendado (wake-out.json do run F53A9C61).
- `reinvoke-out.json`: revalidacao em processo fresco (mesmo veredito).
- `tick-scheduled-task.xml`: XML efetivamente importado (StartBoundary local 12:58:51
  America/Sao_Paulo (UTC-3) = 15:58:51Z; tick 15:59:12Z = +21s apos a janela,
  dentro do Interval 1min; sem AllowStartIfOnBatteries; Disallow/StopIfGoing
  false; InteractiveToken/LeastPrivilege).
- `tick-scheduled-task.orig.xml`: XML original para comparacao.

## Desvios HISTORICOS do XML de repo documentados (nao ocultados, ja corrigidos no repo)

> HISTORICOS: observados no tick, ja corrigidos no repo — ver scheduler
> corrigido em `docs/specs/ETAPA-6D-GH-WAKE-SPEC.md` (linhas 76-96).

- DEVIATION-1 (HISTORICO): `Register-GitHubWakeSchedule` emitia `AllowStartIfOnBatteries`
  (rejeitado pelo schema do schtasks, erro 29,7); o registro real usou o XML do
  DryRun do repo menos essa uma linha. Wake CLI + config + action identicos.
- DEVIATION-2 (HISTORICO): `StartBoundary` do repo usava UtcNow mas o Scheduler interpreta
  como hora local (host UTC-3 => +3h de atraso); o XML importado usa local now+2min.
- Tentativas anteriores falharam honestamente e estao na trilha:
  `00954AAC` (trigger-missed, StartBoundary UTC), `28861C7E` (fired fora da janela
  de poll), `505BB126` (schtasks-create-failed pelo elemento invalido).

## O que NAO e alegado

- Sem RESUME fabricado, sem unblock, sem handoff, sem DONE, sem merge.
- ETAPA_6D_READY bloqueado: falta approval no PR 181 + re-execucao com RESUME live + settlement DISPATCHED (GH_WAKE_SCHEDULED+RESUMED+DISPATCHED na mesma jornada). Sem READY alegado.
