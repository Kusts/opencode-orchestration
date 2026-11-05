# ETAPA-6D GH-WAKE SPEC (short)

Real scheduled wake for GitHub CI waits. Single-shot per scheduler tick,
no daemon, no second Planner/Kernel/watchdog, no LLM in the loop.

## Contracts

- GH-OBSERVE (github-await.ps1): read-only `gh api graphql`, fixed query,
  bounded raw-to-snapshot normalizer (Convert-GHARawToSnapshot). Wake reuses
  it via dot-source; fixture file is test-only.
- GH-WAIT (ghwait-*.json via OrchestrationGitHubResume.ps1): durable wait
  with dedup_key (repo+pr+sha+generation), lease, retry budget,
  applied_events idempotency log. Wake never reimplements readiness.
- GH-WAKE (scripts/v3/github-wake.ps1): one pass over WaitsDir per
  invocation. Per wait, in order: task DONE check, duplicate check,
  checkpoint gate, kernel binding gate, live fetch (bounded retry),
  resume decision, and ONLY on RESUME a CAS confirm plus a Kernel
  BLOCKED->IMPLEMENTING unblock referencing the active-wait fingerprint.
  Announces only the next authorized action (task_id + checkpoint_id).
  Never merges, pushes, deploys, completes tasks, issues grants, or stores
  tokens. Authority pins always false except resume_authorized on RESUME.

## Decision table (per wait)

- Task DONE -> HOLD already-done (DONE never reexecuted).
- Event already applied, task still BLOCKED, binding valid, fresh
  observe still RESUME -> RESUME reconciled-pending-unblock (recovers a
  prior tick that confirmed CAS but failed the unblock; exactly one
  BLOCKED->IMPLEMENTING transition, no duplicate Confirm). Event applied
  and revalidation not RESUME (or task left BLOCKED state) ->
  DUPLICATE_NOOP (no kernel write).
- No checkpoint / checkpoint not resumable -> HOLD (no unblock).
- Kernel not BLOCKED or fingerprint diverged -> HOLD (no unblock).
- Transport exhausted (MaxApiAttempts, default 3, linear backoff) or
  schema failure -> HOLD api-failure (no unblock).
- CI green + executor + authz -> RESUME + confirm + unblock + next_action.
- CI green, no executor -> READY (durable observable, no unblock).
- CI red -> TERMINAL diagnostic (no unblock, no confirm).
- CI pending -> KEEP_WAITING. Stale SHA -> TERMINAL head-superseded.
  Closed PR -> TERMINAL pr-terminal. Revoked authz -> TERMINAL.

## Controller handoff (scripts/v3/github-wake-controller.ps1)

The wake tick only unblocks (BLOCKED->IMPLEMENTING) and announces. The
hand to the real controller is a separate single-shot step that never
reimplements dispatch and never synthesizes execution:

- Extended next_action (announce preserved for existing consumers):
  task_id, checkpoint_id, goal_id, wait_dedup_key, generation,
  lease_owner, lease_expires_utc, event_id, kernel_state=IMPLEMENTING,
  idempotency_key (first 32 hex chars of SHA256 over
  "wait_dedup_key:event_id"), announce ("next-action task=<id>
  checkpoint=<id>"). The same idempotency_key gates the whole handoff:
  claim-once marker (`ghw-handoff-<key>.json`), NativeDispatch Intent,
  and receipt (Prepare/Claim/Settle).
- Intent (productive, no worker effect): `New-GHWakeDispatchIntent`
  wraps the supported `New-OrchestrationNativeDispatchIntent`
  constructor with `ExternalIdempotent=true` and the claim-once marker
  path as `ExternalIdempotencyProof`; a divergent Intent for the same
  key is a collision, never a merge. Built from the LIVE task/goal
  (revision, base_revision, read/write scopes, acceptance_criteria,
  owner+generation); unreadable task/goal, missing scopes/criteria, or
  unknown ownership refuses fail-closed (`dispatch-*-unreadable`,
  `dispatch-no-scopes`, `dispatch-no-criteria`,
  `dispatch-ownership-unknown`, `dispatch-intent-invalid`).
- Prepare (pending receipt, zero worker effect):
  `Invoke-OrchestrationNativeDispatchPrepare` persists the Intent via
  the supported Prepare path under the deterministic pre-effect
  session token `ghw-handoff-<key>` (Prepare and Claim bind this exact
  token; the REAL worker session only appears at Settle time as
  `ChildSessionId`). Result view carries admitted/reused, phase
  (`prepared`), reference, fingerprints, session_id, task_id, agent
  (documented default `coder`: the goal next-move carries no agent
  field). Any refusal is fail-closed (`prepare-refused:<reason>`) with
  the marker claim released for a later tick — no probe runs without
  a prepared receipt.
- Claim (exactly-once gate): `New-GHWakeHandoffClaim` with
  `FileShare.None` (CreateNew) plus revalidation under the collision
  path (`duplicate-noop` on same task/ddk/event/key/goal,
  `idempotency-collision` on divergence). Duplicates never replay and
  the task is never auto-completed.
- Probes (read-only controller consult): `Invoke-GHWakeControllerHandoff`
  validates shape + idempotency binding, finds the wait by dedup_key,
  checks generation/lease-owner, the Kernel binding/fingerprint
  (post-unblock: task IMPLEMENTING plus wait_history fingerprint
  match), the checkpoint resumable gate, and the live lease; then
  consults the existing controller contract only (AutonomousLoop
  objective step via injected probe, the read-only GoalKernel
  next-move, or the plain `intent-ready` path). A POSITIVE probe is a
  `controller-responded` signal, never execution: the marker stays
  `claimed`, `dispatched=false`, `executed=false`. A prepared receipt
  without settle params is `intent-ready`
  (`prepared-awaits-planner-dispatch`). Never merges, pushes, deploys,
  completes tasks, issues grants, or reads secrets.
- Settlement (the ONLY path to dispatched=true):
  `Set-GHWakeDispatchSettlement` validates the marker (claimed, same
  idempotency key) plus the NativeDispatch receipt for the same key,
  then runs the supported Claim (handoff session token) + Settle
  (native API-proven NATIVE WORKER child session + structured result)
  chain. Only a settled receipt flips the marker to `dispatched` with
  the REAL NATIVE WORKER session id
  (`session_id == settle_child_session_id == worker_session_id`,
  distinct from `resume_session_id`); `ok/dispatched/duplicate/executed` mirror the settlement outcome and
  all authority pins stay false (no grants, no DONE, no merge).
  Without a native-proven worker id — or on any refusal
  (`settle-not-claimed`, `settle-not-prepared`,
  `settle-session-invalid/mismatch`, `settle-identity-diverged`,
  `settle-claim-refused`, `settle-refused`) — nothing is marked
  dispatched (fail-closed). IMPLEMENTING alone is never execution.
  NATIVE_SESSION_RESUMED alone is never execution either.
- Worker proof (P0 native gate, auto-dispatcher only):
  `Find-GHWADNativeWorkerProof` (pure validator, no IO) binds ONE new
  child session to ONE new completed subagent tool invocation and to
  the CURRENT operation, over native-shaped evidence only. No
  caller-supplied worker fields exist anywhere: there are no
  worker-identity CLI inputs, and the RunExecutor mock cannot generate
  proof or a worker id. Stable reasons: `auto-worker-unproven` (no new
  child, no new completed subagent part, or pre/post snapshot empty),
  `auto-worker-parent-mismatch` (child parentID != resume),
  `auto-worker-operation-mismatch` (project divergence, stale child
  created before the run, tool prompt lacking the EXACT operation
  marker, or child without operation binding),
  `auto-worker-result-unproven` (no parseable STRUCTURED result
  object, non-worker status, refs missing/invalid, missing/
  interrupted outcome, or outcome/status disagreement),
  `auto-worker-api-unavailable` (native transport failure pre/post run
  or on message read), `auto-worker-non-native` (an injected,
  non-native transport or a mocked resume never settles productive
  state, even when the payload fully validates; a mocked resume without
  injected API is gated before any query with zero executor effect),
  `auto-prompt-unfittable` (operation marker or final prompt cannot
  travel the NativeResume prompt gate: refused before any run),
  `auto-replay-unproven` (a stored dispatched marker without CURRENT
  native proof never replays: no Settle call, marker untouched).
  All refuse as reconcile (claim kept for operator reconciliation,
  never dispatched). Only `succeeded` + `candidate_pass` settles ok
  (ResultOk true) and `failed` + `failed` settles failed (ResultOk
  false, `blocked` collapses to the legacy failed receipt while the
  native child outcome keeps the precise verdict); both require a fully
  validated native proof over the REAL transport.
- Operation marker and structured result (no substring matching): the
  driver embeds an EXACT textual marker (`New-GHWADOperationMarker`:
  `ghw-op goal=<gid> task=<tid> gen=<gen> key=<key>`, strict charsets)
  in the resume prompt, FOLLOWED BY a short delegation directive
  (`Get-GHWADWorkerDirective`: delegate via the native subagent tool,
  forward the marker exactly, require the worker JSON result object
  with the accepted fields/status/criterion refs, never substitute
  your own result), and refuses before any run when the marker, the
  directive, or the final prompt cannot fit the NativeResume prompt
  gate (`Test-GHWADPromptFits`: <=2000 chars, no shell metacharacters).
  Without this instruction the positive gate would be unreachable by
  construction (no implicit premise: the Planner is told what to
  forward and what to require). The worker's structured result is a
  JSON object parsed from native tool content
  (`Find-GHWADWorkerResultObject`: full-text, ```json fences, then
  brace-balanced spans): task_id/goal_id/generation/idempotency_key
  compared EXACTLY (never via substring), status in
  candidate_pass/failed/blocked, claimed_evidence refs
  `criterion:<idx>`; verified_pass/done/approved or any adulterated
  field never validates. The prompt side requires the EXACT marker
  token; the result side requires EXACT identity equality plus native
  outcome/status agreement.
- Native 2.2.5 proof surface (probed 2026-11-02, read-only, no model
  quota spent): `opencode --version` = v2.2.5; `opencode api get
  /api/info` confirms the version; `opencode api get /openapi.json`
  (authenticated by the CLI) documents the session operations used.
  PROVEN live shapes —
  `opencode api session.list --param parentID=<ses> --param limit=N`
  returns `{data:[Session.Info...]}` with children carrying id,
  parentID, agent, projectID, outcome (succeeded/failed/interrupted),
  time.created/updated; `opencode api session.get --param
  sessionID=<ses>` returns `{data: Session.Info}` with parentID,
  agent, projectID, outcome, time.created; `opencode api
  session.message.list --param sessionID=<ses> --param limit=N --param
  order=desc` returns assistant messages whose tool parts carry
  `{type:tool, name:subagent, id:call_..., state:{status,
  input:{agent,description,prompt,sessionID},
  metadata:{sessionID,status,completed}, content:[...]},
  time:{created,ran,completed}}`. Transport notes: the operation-ID
  form (`opencode api session.list ...`) filters server-side; the
  `api get <path>` form IGNORES query params and must not be used;
  `&` never appears in arguments (params travel as `--param k=v`
  pairs with a strict `[A-Za-z0-9_.-]` charset, so the cmd shim is
  safe). NOT native evidence: `opencode session list` (top-level
  only, no parentID) and `opencode run --format json` stdout (binds
  only the resumed session, never a child). The v2.0.23 hook probe
  (`evidence/v3.1/runtime-reliability/native-handoff-hook-probe-2026-10-09-positive.jsonl`)
  is historical context only, not 2.2.5 proof.
  No live worker run was spent for this P0: the productive
  `WORKER_DISPATCH_SETTLED` claim still requires a live run with a
  real worker in the same journey.
- Planner execution (proven native resume interface): the proven
  interface is `opencode run --session <id> --format json <prompt>`
  via `Invoke-OrchestrationNativeResume` (P1), with pre-checks
  (ses_ format, list pre/post, canonical directory, projectId,
  fencing Generation/LeaseOwner via Authorization, resumable
  checkpoint, task BLOCKED/IMPLEMENTING; DONE => already-done),
  exactly ONE run without --continue/--fork, no cmd.exe, hardened
  native evidence (`Test-NativeResumeEvidence`), reconcile without
  blind resend. `proceed` is never dispatch by itself: only a NATIVE
  worker proof settles via `Set-GHWakeDispatchSettlement` with the
  NATIVE child id (P0 gate `Find-GHWADNativeWorkerProof` over
  read-only `opencode api` evidence: new child with parentID == resume,
  new completed subagent tool invocation in the same session, EXACT
  operation marker in the prompt, STRUCTURED worker result object with
  EXACT identities + criterion refs, child outcome in agreement).
  `NATIVE_SESSION_RESUMED` alone reconciles as `auto-worker-unproven`
  (claim kept, never dispatched). An injected (non-native) transport or
  a mocked resume never settles productive state even when the payload
  fully validates (`auto-worker-non-native`, gated before any query
  when no API transport is injected); the RunExecutor mock cannot
  generate proof or a worker id. Single vigente flow (no parallel
  drivers, no second Planner/Kernel): the scheduled tick only produces
  next_action; the single-shot wiring `Invoke-GHWakeAutoDispatch`
  (scripts/v3/github-wake-auto-dispatch.ps1) consumes the
  envelope/next_action, runs handoff prepare/claim/probe, snapshots the
  native children (pre, BEFORE any run — a pre failure reconciles with
  zero executor effect), builds the resume prompt with the EXACT
  operation marker plus the delegation directive (fail-closed when it
  cannot fit), invokes the resume via `opencode run --session`,
  re-reads children + messages (post), checks the P0 native proof,
  and settles with the NATIVE child id. There are no
  caller-supplied worker identity inputs; a dispatched marker replays
  ONLY after CURRENT native revalidation (stored session + parent +
  completed tool + exact operation binding + structured result via the
  live API; old markers without current proof reconcile as
  `auto-replay-unproven` with zero Settle calls and the marker
  untouched; injected transports never replay). The wiring also settles
  the duplicate-noop replay path (claimed marker + pending receipt
  still settleable). Single-shot (no loop/sleep/daemon/spawn, no
  autonomous supervisor), fail-closed (missing checkpoint/binding/lease
  => HOLD, no spawn). The manual `-SettleSessionId` re-invoke on
  `github-wake-controller.ps1` is not a parallel flow: the vigente
  production path is the AutoDispatch wiring above. `ETAPA_6D_READY`
  stays BLOCKED (see Gates).
- Suite: scripts/v3/github-wake-controller.tests.ps1 (offline).

## Scheduler

Register/Unregister-GitHubWakeSchedule manage one Windows Scheduled Task
via schtasks.exe with an explicit XML definition: TimeTrigger with
StartBoundary in local time (Now+2min, format yyyy-MM-ddTHH:mm:ss, no Z
suffix; Scheduler parses StartBoundary as local, UtcNow fired ~3h late on
a UTC-3 host) and bounded Repetition (Interval default 5min, Duration
default 12h), ExecutionTimeLimit (default 5min),
DisallowStartIfOnBatteries=false, StopIfGoingOnBatteries=false,
InteractiveToken/LeastPrivilege. AllowStartIfOnBatteries is absent on
purpose: it is not part of the schtasks XML schema and was rejected on
import (error 29,7), so it was removed; Disallow/StopIfGoing stay as the
correct battery settings. Registration is ownership-checked: owned means
the single Exec Command is exactly the generated
%windir%\System32\WindowsPowerShell\v1.0\powershell.exe path (quoted or
unquoted, Windows case/separator normalization allowed) AND Arguments is
exactly the generated 7-token sequence `-NoProfile -ExecutionPolicy
Bypass -File <wake> -ConfigFile <cfg>` (exact flags, no aliases,
reordering, duplicates, extras, or residual tokens; path values
case/separator normalized). Anything else returns task-name-conflict
(fail-closed), even with -Force; -Force replaces only the exact owned
task (replaced-owned). The old replaced-conflict outcome (Force replacing
an unowned name) no longer exists. Unregister is fail-closed
too: deleting an existing task requires explicit -Force, otherwise
confirmation-required; absent tasks stay idempotent not-found. Battery/location
settings not expressible via schtasks.exe CLI are fixed in the imported XML,
not via the ScheduledTasks module (unavailable on Server Core). Action runs
`powershell -NoProfile -File github-wake.ps1 -ConfigFile <json>` as a
separate process; args persist in the JSON config written by
New-GitHubWakeConfig. No in-memory state crosses ticks. Single-shot
opt-in: `Register-GitHubWakeSchedule -OneShot` (and the underlying
`Get-GHWSchtasksXml -OneShot`) omit the complete `<Repetition>` element,
which the Task Scheduler schema documents as optional (the official
TimeTrigger one-shot example carries no `<Repetition>`). All other pins
are retained: StartBoundary, InteractiveToken/LeastPrivilege,
ExecutionTimeLimit, Disallow/StopIfGoingOnBatteries=false. Explicit
`-IntervalMinutes`/`-DurationHours` combined with `-OneShot` are rejected
fail-closed (`oneshot-schedule-conflict`; the raw helper returns empty
XML); omitting them (defaults apply to the repeating path only) does not
conflict. Reuse additionally requires the exact one-shot shape: the
existing XML must carry exactly ONE `<TimeTrigger>` with ZERO
`<Repetition>` inside it (`Test-GHWScheduleOneShotCompatible`); empty or
unparseable XML, zero or multiple TimeTriggers, or any Repetition is
incompatible and returns oneshot-mode-conflict without -Force (Force on
an owned task regenerates without repetition). Default behavior without
`-OneShot` is unchanged (bounded
Repetition as before). Validated DryRun-only/pure in
scripts/v3/github-wake-scheduler.tests.ps1 (S7-S9); no task registration,
activation, or Live is implied by this option.

## Authority and limits

- Kernel is the authority for task state; ghwait files are transport;
  checkpoint + Goal store are the authority for resume context.
- Wake writes at most: wait applied_events (CAS, RESUME only) and one
  Kernel BLOCKED->IMPLEMENTING transition (CAS + fingerprint + trusted
  identity source explicit-cli). Everything else is observation.
- No auto-merge/deploy/DONE; no grant issuance; no secret handling; no
  polling/busy-loop; retry is bounded (max 3 attempts per wait per tick).
- Proof: scripts/v3/full-delivery-etapa6d-proof.ps1 (two real processes,
  normalizer-real fixtures, live transport probe, no fabricated live PR).
  Suite: scripts/v3/github-wake.tests.ps1 (offline, PS 5.1 + pwsh).

## Gates (policy, sem excecao docs-only)

- Os gates abaixo sao os gates do perfil default (`github_approval`
  exigido) e sua evidencia historica pertence ao default: o tick vivo de
  2026-10-31 (PR 181, `KEEP_WAITING`/`REVIEW_PENDING`), as provas offline
  (`AUTO_DISPATCH_OFFLINE_PASS`, matriz P2, harness P3) e as certificacoes
  ja registradas permanecem validas e inalteradas para o default. O
  perfil solo nao reabre, revalida nem substitui nenhuma delas; ele
  troca, somente no caminho opt-in, o passo de approval GitHub nao-self
  por um registro de review de agente interno validado (ver Gates do
  perfil solo). Revisao tecnica (prontidao) e autorizacao operacional
  (merge, scheduler, Live, deploy) sao independentes: prontidao tecnica
  nunca cria autorizacao operacional.
- `READY_FOR_RESUME` (observacao) exige review humana legitima
  nao-self pela policy: o external-action gate recusa self-review
  (`SELF_REVIEW => POLICY_BLOCKED`, case-insensitive); sem approval
  de terceiro a readiness fica em `REVIEW_PENDING` (observado no tick
  vivo do PR 181) e nenhum RESUME/unblock/handoff avanca. Nao ha
  excecao docs-only: documentacao nao substitui approval.
- `AUTO_DISPATCH_OFFLINE_PASS` prova somente o controlador offline e seus
  refusos; nao prova execucao de worker.
- `WORKER_DISPATCH_SETTLED` exige, na mesma operacao, um worker nativo
  distinto da sessao retomada, `parentID` nativo correspondente, chamada
  subagent concluida, marcador exato de task/goal/generation/key e resultado
  estruturado do worker, tudo corroborado pela API local do OpenCode. Mocks
  nao satisfazem este gate.
- `AUTO_DISPATCH_SCHEDULED` exige que o caminho agendado invoque efetivamente
  o auto-dispatcher; registro ou `DRY_RUN` isolado nao basta. A ativacao do
  Task Scheduler permanece desabilitada ate o teste controlado.
- `ETAPA_6D_READY` segue BLOQUEADO ate a mesma jornada viva completar
  `GH_WAKE_SCHEDULED` + `RESUMED` (RESUME live + unblock Kernel
  BLOCKED->IMPLEMENTING no tick agendado) + `WORKER_DISPATCH_SETTLED` e
  `AUTO_DISPATCH_SCHEDULED`, com approval nao-self e CI verde. Os gates
  precisam pertencer a mesma jornada; `AUTO_DISPATCH_OFFLINE_PASS` ou
  `SCHEDULED` isolado (tick KEEP_WAITING) nao libera READY.
- `NATIVE_RESUME_AVAILABLE` (prova Offline, sem Live, sem jornada
  GitHub): provado quando o adaptador `Invoke-OrchestrationNativeResume`
  (P1) passa a prova harness Offline `full-delivery-etapa6d-resume-proof.ps1`
  (projeto descartavel, 2 fases, `proceed` + `already-done`, JSONL gitignored,
  README versionado) 2x exit 0. Nao alega execucao viva, worker real,
  approval ou jornada GitHub.
- `NATIVE_RESUME_INTEGRATED` segue PENDENTE como jornada unica: exige
  Live com worker real (`-Mode Live`, `opencode run --session` real) +
  settlement session-bound (Claim session token + Settle com session id
  real) NA MESMA jornada. Separacao honesta ja provada: (i)
  `NATIVE_SESSION_RESUMED` provado no Live de 2026-10-31 (sessao
  descartavel `ses_e6c043e07ffeJAQa740XQ5x8IZ`, `proceed` +
  `already-done`, settlement KERNEL-ONLY, claim `NATIVE_SESSION_RESUMED`);
  (ii) mecanica `WORKER_DISPATCH_SETTLED` do controller em
  `scripts/v3/github-wake-controller.tests.ps1` (marker claimed ->
  dispatched, refusos settle-session-invalid/mismatch, replay
  settle-duplicate) — mecanica de recibos do controller, SEM worker
  vivo na mesma jornada e SEM valor de prova para o auto-dispatcher:
  no auto-dispatcher (`github-wake-auto-dispatch*.tests.ps1`) NENHUM
  caso offline liquida (todos `dispatched=false`; payload injetado
  valido reconcilia como `auto-worker-non-native`; marker antigo sem
  prova atual reconcilia como `auto-replay-unproven` sem Settle), e
  somente evidencia nativa `opencode api` (filho novo + tool subagent
  completed + marcador exato + resultado JSON estruturado com
  identidades exatas + outcome/status em acordo) alimenta settlement.
  O N5 estrutural offline e parser puro sobre fixture sintetica
  (valida worker/resume distintos, parent, resultado da operacao e
  status) e nao liquida nada; a presenca do marcador + diretiva no
  prompt efetivo e conferida via spec capturada do RunExecutor
  injetado (T12, sem live); nao existe N5 de settlement produtivo
  sem live API + worker vivo. INTEGRATED so sai de PENDENTE com ambos na
  mesma jornada viva — e mesmo com INTEGRATED, `ETAPA_6D_READY` continua BLOQUEADO
  ate a jornada GitHub real (approval nao-self + CI verde +
  SCHEDULED+RESUMED+DISPATCHED na mesma jornada).
- Sem excecao docs-only, sem self-review (`SELF_REVIEW => POLICY_BLOCKED`),
  sem merge/deploy/piloto nesta SPEC.

## Gates — perfil solo-maintainer (2026-11-04, sem atestação)

- O perfil `solo-maintainer` (`source/registry/delivery-policy.json`,
  `review.github_approval=not_required`, ativacao explicita por chamada)
  remove o pre-requisito de approval GitHub nao-self e NAO exige
  atestacao assinada. Um registro de review de agente interno valido
  (`approved: true`, `head_sha` do SHA esperado, `reviewer_identity` e
  `author_identity` presentes e distintos), com todos os checks requeridos verdes no SHA esperado e
  `head_sha`/`commit_sha` coincidentes, satisfaz a prontidao TECNICA
  (`READY_FOR_RESUME`, `review_basis: internal-agent`). Evidencia
  ausente/invalida/divergente ou self-review nunca gera READY
  (`REVIEW_PENDING`/`INCONCLUSIVE` fail-closed); `CHANGES_REQUESTED`
  explicito sempre repara, mesmo com approval dispensado. O registro de
  agente e controle de qualidade apenas — nunca identidade autenticada,
  assinatura independente, aprovacao humana ou aprovacao GitHub — e sua
  origem/limites ficam gravados em `review_basis`/`review_detail`.
- Sem afrouxamento compensatorio: CI pendente espera, CI falho bloqueia,
  SHA divergente bloqueia, perfil default inalterado (`github_approval`
  exigido). A decisao operacional do maintainer (merge, scheduler,
  Live) nao decorre da prontidao tecnica e segue pendente.
- Waits registradas sob a expectativa antiga (`APPROVED`) divergem da
  expectativa efetiva solo (`ANY`) e retornam `INVALID`
  (`policy-diverged`); re-registro e explicito, nunca migracao silenciosa.
- Requisitos de autorizacao (CI/Scheduler/modelo), limites de
  custo/request e todos os demais blockers seguem inalterados;
  `ETAPA_6D_READY` operacional continua BLOQUEADO (sem merge, sem Live,
  sem scheduler).
- Integracao ao wake agendado (2026-11-05, sem nova arquitetura):
  o tick seleciona o perfil somente por opt-in explicito do operador
  (`-DeliveryProfile` na CLI ou `delivery_profile` no JSON de config,
  mais o diretorio operado `solo_internal_reviews_dir` com um
  `<task_id>.json` por task); documentos de wait nunca selecionam
  perfil, mesmo quando carregam um campo `delivery_profile` (ignorado).
  O caminho normal e o caminho de recuperacao de tick parcial usam os
  mesmos gates sem duplicacao (`Invoke-GHWResumeDecision` alimenta o
  mesmo `Test-OrchestrationGitHubResume` e os mesmos validadores de
  readiness). Prontidao sem autorizacao/executor nao chama NativeResume
  nem settlement: sem RESUME nao ha next_action, e sem next_action o
  handoff opt-in nao executa. Task Kernel, NativeDispatch e
  ExternalActionGate nao foram modificados.
- Atestacao RSA segue experimental e BLOCKED: desconectada do caminho
  de readiness, nunca pre-requisito, sem emissores confiaveis e sem
  material de chave (`source/registry/solo-attestation-policy.json`).

### Contrato criptográfico offline — experimental, sem pré-requisito

- `scripts/v3/lib/OrchestrationSoloAttestation.ps1` define um envelope
  fechado, canônico e versionado, assinado por RSA-PSS-SHA256. O payload
  vincula repositório/PR/SHA, Task/Run/operação, perfil, `policy_id` + digest,
  emissor, `issued_at`/`expires_at`, `jti` e os dois reviews (`reviewer` e
  `security-reviewer`), cada um com session id declarado, veredito, SHA
  candidato, lista não vazia de hashes de evidência e hash do registro Kernel.
  O envelope fora do perfil solo, desconhecido, expirado, revogado, inválido
  ou divergente falha fechado. O binding impede reutilização em outra
  operação; revalidação da mesma operação não consome estado e continua
  idempotente.
- O código é somente verificador de documento, retorna `{ok, reason}` e não
  faz emissão, não assina JSON arbitrário e não participa do caminho de
  readiness. A política `solo-attestation-policy.json` está `BLOCKED` sem
  emissores. As 54 asserções offline usam chave sintética temporária em memória;
  o verificador exige expoente público RSA exatamente 65537 e `revoked_jtis`
  estrita (qualquer entrada malformada invalida a política); chaves
  duplicadas na política (`status`/`trusted_issuers` na raiz ou
  `issuer_id`/`revoked` no emissor) falham fechado como `policy-invalid`;
  aceitação criptográfica do fixture não é prova de que o review real veio do
  agente/session indicado.
- Gap de proveniência (contexto do experimento, não bloqueador de
  readiness): `Set-OrchestrationTaskReview` persiste `by` como texto
  e a revisão candidata, sem identidade/session lineage autenticada nem hash
  verificável do conteúdo de review. Gap de isolamento: o shell do
  agente compartilha o principal Windows do operador. Por isso a atestação
  permanece experimental e desconectada — jamais pré-requisito.
- Nenhum provisionamento, ajuste de ACL,
  geração de chave/certificado, wiring ou Live ocorreu nesta etapa.

## Prova viva (live tick honesto, REVIEW_PENDING, sem cadeia completa)

- Real tick fired via schtasks.exe on 2026-10-31: task
  ETAPA6D-LIVE-TEST-F53A9C61, tick 2026-10-31T15:59:12Z (LastResult 0),
  transport gh-query live, b_decision KEEP_WAITING (pending),
  b_readiness REVIEW_PENDING (review-required, no approval on PR 181),
  b_attempts 1, b_confirmed false, kernel not-attempted, resumed 0,
  evaluated 1, resume_authorized false, next_action none. Reinvoke in a
  fresh process reproduced the same KEEP_WAITING/REVIEW_PENDING with
  kernel intact (B still BLOCKED rev 3, A still DONE rev 9).
- Correlated IDs: PR 181, HEAD ece501ed0815616902bb57b2050f280d8ee40fbb,
  run 41200510501 (success, headSha match), goal live6d-20261031-155642,
  checkpoint 351e3c0637f4960c,
  dedup_key github-resume:v1:kusts/opencode-orchestration:181:ece501ed0815616902bb57b2050f280d8ee40fbb:1.
  Out files: tick-out.json (scheduled tick) + reinvoke-out.json
  (fresh-process revalidation); raw trail in
  evidence/v3/etapa6d-live/etapa6d-live-proof.jsonl (60 lines).
- No RESUME was fabricated and no full chain is claimed: KEEP_WAITING
  announces no unblock and performs no handoff. ETAPA_6D_READY stays
  BLOCKED until PR 181 gets the required approval plus a re-execution
  that observes RESUME on live transport.

## Objetivo 4 (recuperacao e limites) — cobertura offline

- (a) Sem usuario interativo: XML fixa InteractiveToken/LeastPrivilege, sem
  segredo S4S simulado. HOLD honesto: sem sessao interativa no host, o
  registro real exige logon interativo; DryRun nunca e prova viva.
  Principal divergente recusado pelo owner check (mesmo arquivo de suite).
- (b) Duracao e renovacao: Interval PT5M + Duration PT12H +
  ExecutionTimeLimit PT5M + StopAtDurationEnd + IgnoreNew (sem estados
  paralelos) pinados no XML; renovacao via re-registro idempotente
  (already-registered sem duplicar, replaced-owned apos Force).
- (c) Falha do executor (proof ausente/invalida/futura) => READY
  ready-no-executor, nunca TERMINAL nem RESUME, kernel intacto.
- (d)-(h) ja cobertos, nao duplicados: cancelled, DUPLICATE_NOOP sem
  mutacao, head-superseded, lease-expired, api-failure (ver assert labels
  em github-wake.tests.ps1 e github-wake-controller.tests.ps1).

## Retomada nativa (P0/P1/P2/P3) — adapter + harness, resume via run --session

Interface comprovada: `opencode run --session <id> --format json
<prompt>` via `Invoke-OrchestrationNativeResume` (P1), never
--continue/--fork. Este bloco documenta o adaptador nativo
(`scripts/v3/lib/OrchestrationNativeResume.ps1`) e sua prova harness
(`scripts/v3/full-delivery-etapa6d-resume-proof.ps1`), sem alegar READY,
sem tocar PR/CI/scheduler. Live executado em 2026-10-31 (prova
`NATIVE_SESSION_RESUMED`, settlement KERNEL-ONLY); `WORKER_DISPATCH_SETTLED`
e `INTEGRATED` seguem fora deste bloco (ver Gates).

- (a) P0 contrato autenticado (`Get-NativeSessionIdentity`): SessionId no
  formato `^ses_` (sem `--continue`, sem criacao implicita — `run --session`
  no 2.2.5 cria se inexistente, por isso o pre-check list pre/post e
  obrigatorio); `directory` canonico Windows; `projectId` confrontado;
  fencing por `Generation`/`LeaseOwner` via `Authorization`
  (`explicit_allow=true` + campos correspondentes; caminho legacy so com
  ambos vazios + Auth null); checkpoint (`Load` + plano resumivel) e gates
  de task (BLOCKED/IMPLEMENTING; DONE => `already-done`, nunca reexecuta).
  Falha de pre-check nunca invoca o run.
- (b) P1 adaptador (`Invoke-OrchestrationNativeResume`): no maximo 1 run
  (`opencode run --session <id> --format json <prompt>` com o working
  directory do filho em <canon>; run nao tem --dir na v2.2.5),
  prompt Kernel-only com charset fail-closed (`invalid-prompt`, sem run);
  sem `cmd.exe` no run (prompt e texto livre e nao cruza shell: shim
  `.cmd/.bat` trocado por irmao `.ps1` via host powershell, ou falha
  fechada `LAUNCH_ERROR`); evidencia nativa endurecida
  (`Test-NativeResumeEvidence -SessionId <id>`: cada linha JSONL/doc e
  parseada de verdade; exige um objeto-evento com chave de sessao
  sessionId|sessionID|session_id|id -ceq a sessao esperada E ponteiro
  role|type nao-vazio no MESMO objeto; decoy so-com-nomes, evento de
  outra sessao, sessao sem pointer e texto puro nunca sao prova; stderr
  com session-missing falha fechado); nunca `dispatched`/`executed` aqui
  (settlement e do caller via Claim+Settle); exit 0 sozinho nunca prova
  dispatch; `timeout-unknown`/`resume-unproven`/`identity-diverged`
  => RECONCILE, sem resend cego.
- (c) P2 matriz 10 casos (reasons estaveis, fail-closed): `session-id-invalid`,
  `invalid-idempotency-key`, `invalid-prompt`, `session-not-found`,
  `project-mismatch`, `directory-mismatch`, `authorization-denied`,
  `checkpoint-not-found`, `resume-not-resumable`, `kernel-not-ready`
  (todos blocked, run nunca invocado) + `already-done` (DONE, sem
  reexecutar) + `session-not-found-post` / `timeout-unknown` /
  `resume-unproven` / `identity-diverged` (reconcile).
- (d) P3 prova Offline (harness, projeto descartavel, 2 fases): Fase A
  constroi goal+task A ate DONE + task B BLOCKED com wait/checkpoint/marker
  em diretorios Temp; Fase B rele do disco, confirma A DONE sem reexecutar,
  `proceed` com RunExecutor MOCK (1 run), settlement Kernel, segunda
  invocacao com mesma idempotency key => `already-done` (`runs_count` 1->1).
  JSONL gitignored (`resume-proof.jsonl`), README versionado em
  `evidence/v3/etapa6d-resume/README.md`. Claim Offline: apenas
  `NATIVE_RESUME_AVAILABLE`. Live (`-Mode Live`, run real, timeout 60s, sem
  `--continue`/`--fork`) executado em 2026-10-31 (prova
  `NATIVE_SESSION_RESUMED`, settlement KERNEL-ONLY — ver Gates e README
  do harness para limites).
- (e) Limites (sem alegar alem do provado): `run` na v2.2.5 nao tem
  --dir — o working directory do filho e fixado no processo filho
  (<canon>); prompt e Kernel-only com charset fail-closed
  (`invalid-prompt`, sem run); `proceed` != `dispatched` (dispatched so
  via settlement com NATIVE child id comprovado e distinto do resume);
  prova Offline declara apenas refusos (fail-closed, dispatched=false em
  todos os casos de driver: `auto-worker-unproven`,
  `auto-worker-operation-/parent-/result-*`,
  `auto-worker-api-unavailable`, `auto-worker-non-native` mesmo com
  payload injetado valido, `auto-prompt-unfittable`,
  `auto-replay-unproven`) mais a logica do validador/parser puros —
  incluindo o N5 estrutural (shape completo com marcador exato +
  resultado JSON exato, worker/resume distintos, parent e status),
  que testa SOMENTE o parser sobre fixture sintetica e nunca liquida;
  nenhum N5 de settlement produtivo existe sem live API + worker vivo.
  Live declara `NATIVE_SESSION_RESUMED` (settlement KERNEL-ONLY),
  `NATIVE_RESUME_INTEGRATED` segue PENDENTE (exige Live + settlement
  session-bound com worker distinto NA MESMA jornada), e
  `WORKER_DISPATCH_SETTLED` produtivo segue nao alegado (exige worker
  nativo vivo + settlement com worker id na mesma jornada). Se a
  jornada de replay/resultado nao tiver shape nativo verificavel sem
  modelo, o gate fica BLOCKED com fail-closed em vez de inferir.
