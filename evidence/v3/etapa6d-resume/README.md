# Etapa 6D — Native Resume Proof (harness)

Script: `scripts/v3/full-delivery-etapa6d-resume-proof.ps1`
Evidencia runtime (gitignored): `evidence/v3/etapa6d-resume/resume-proof.jsonl`

## O que foi provado (Offline, sem LLM, sem rede)

- Fase A constroi em diretorios descartaveis (Temp): goal + task A ate
  DONE pela cadeia canonica do kernel + task B BLOCKED com typed wait +
  checkpoint + marker. Ao retornar, as variaveis da fase somem; o unico
  canal entre fases e o marker em disco (documentado como A-logico/B).
- Fase B rele do disco, confirma A DONE sem reexecutar, chama
  `Invoke-OrchestrationNativeResume` com RunExecutor MOCK (JSON nativo
  minimo com `role`+`sessionId` vinculado a sessao esperada, contador de
  invocacoes): `proceed`.
- Settlement KERNEL-ONLY (B BLOCKED -> IMPLEMENTING -> DONE pelo kernel;
  status JSONL `KERNEL_SETTLED` com `settle_scope=kernel-only`): NAO e
  settlement NativeDispatch, nunca marca `dispatched`/`executed`. A
  segunda invocacao com a mesma idempotency key cai em `already-done`
  sem novo run (`runs_count` inalterado: 1 -> 1).
- Binding: primeira sessao de `session list` local, read-only; nenhuma
  sessao nova e criada em Offline. Fallback sintetico so se a lista
  falhar (registrado em `binding_source`); Live exige sessao listada.
- Sanitizacao: JSONL guarda apenas ids, estados, reasons, lens,
  `stderr_code` (none|session-missing|timeout|model-unavailable|other) e
  `stderr_len`. Nenhum prompt, nenhum stdout completo e nenhum `stderr`
  bruto (`stderr_diag` nunca e persistido na prova; o adapter pode manter
  o diag truncado em memoria para o caller, mas a prova so persiste
  codigo + tamanho).
- Prompt fail-closed: o adapter rejeita (`invalid-prompt`, sem run) qualquer
  PromptText com `& | < > ( ) ^ % ! ; $ "` backtick, CR ou LF. O prompt da
  prova e Kernel-built (palavras fixas + session id `ses_[A-Za-z0-9]+`).
- Sem cmd.exe no run: o adapter de listagem (`Get-NativeSessionList`)
  mantem seu shim `cmd.exe` porque seus args sao fixos sem texto livre;
  o run de resume NUNCA usa `cmd.exe` (prompt e texto livre e nao pode
  cruzar shell): shim `.cmd/.bat` e trocado por irmao `.ps1` sob host
  PowerShell, ou falha fechada (`LAUNCH_ERROR`) sem spawn.
- Fencing obrigatorio: quando `Generation` ou `LeaseOwner` nao-vazios, a
  prova passa `Authorization` com `explicit_allow=true` + campos
  correspondentes (`generation`/`lease_owner`); sem token ou sem campo,
  o adapter nega (`authorization-denied`, sem run). Caminho legacy (ambos
  vazios + Auth null) continua permitido.

Claim Offline: apenas `NATIVE_RESUME_AVAILABLE` (o que o adapter ja
declara). NUNCA `ETAPA_6D_READY`, nunca `NATIVE_SESSION_RESUMED`,
nunca `WORKER_DISPATCH_SETTLED` em Offline.

Taxonomia (nunca confundir):

- `NATIVE_SESSION_RESUMED`: sessao existente retomada por processo novo
  com resposta nativa vinculada observada. Provado no Live de
  2026-10-31 (sessao descartavel `ses_e6c043e07ffeJAQa740XQ5x8IZ`,
  `proceed` + `already-done`, `runs_count` 1->1, claim
  `NATIVE_SESSION_RESUMED`). O settlement desse Live foi KERNEL-ONLY
  (task kernel), nao NativeDispatch.
- `WORKER_DISPATCH_SETTLED`: subagente real identificado, com evidencia
  de execucao e recibo NativeDispatch liquidado via
  `Set-GHWakeDispatchSettlement`. Mecanica provada em
  `scripts/v3/github-wake-controller.tests.ps1` (marker `claimed` ->
  `dispatched` com session id real atestada, refusos
  `settle-session-invalid`/`settle-session-mismatch`, replay
  `settle-duplicate`); nenhum worker vivo foi despachado e liquidado na
  mesma jornada do Live.
- `INTEGRATED` (ambos na mesma jornada viva): NAO alegado. `ETAPA_6D_READY`
  segue BLOQUEADO.

## Live (registro historico — executado em 2026-10-31, nao pendente)

Comando usado (opt-in do operador; consome quota):

```powershell
powershell -NoProfile -File scripts/v3/full-delivery-etapa6d-resume-proof.ps1 -Mode Live
```

- Live usa run REAL `opencode run --model <OPENCODE_RESUME_MODEL>
  --session <id> --format json <prompt>` com o working directory do
  filho em <dir> (default do env:
  `opencode-go/muse-spark-1.3-contributor`), timeout 60000 ms, sem
  `--continue`/`--fork`. Se modelo/credencial ausente ou timeout, registra
  `resume-unproven`/`timeout-unknown` honesto, exit 2, sem alegar nada.
- Com `proceed` + settlement + `already-done` o claim e
  `NATIVE_SESSION_RESUMED` (sessao retomada por processo novo com
  resposta nativa vinculada). O settlement desse harness continua
  KERNEL-ONLY e nunca conta como `WORKER_DISPATCH_SETTLED`. Mesmo com
  `NATIVE_SESSION_RESUMED`, a jornada GitHub (approval) continua
  BLOQUEADA sem excecao: este harness nao toca PR/CI/scheduler,
  nao simula approval, nao faz merge/deploy.

## Status

- Offline: PROVADO (2x+ exit 0, runs 1->1, already-done na repeticao,
  claim `NATIVE_RESUME_AVAILABLE`).
- Live: `NATIVE_SESSION_RESUMED` PROVADO em 2026-10-31 com opt-in
  (sessao descartavel em projeto Temp, `proceed` + settlement
  KERNEL-ONLY + `already-done`, `runs_count` 1->1). Limites: o run real
  prova a retomada da sessao, nao um dispatch de worker; o settlement
  foi pelo task kernel, nao via `Set-GHWakeDispatchSettlement`, e por
  isso nao conta como `WORKER_DISPATCH_SETTLED`. `INTEGRATED` (ambos na
  mesma jornada viva) segue NAO alegado.
- Jornada GitHub com approval: BLOQUEADA (fora deste escopo).
