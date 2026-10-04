# Changelog

Todos os lançamentos relevantes deste pacote são documentados aqui, no
formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/).
Versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

Programa **V3.1 — Dual-Runtime Kernel Hardening** em andamento
(especificação e plano em `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-*`).
Fases 0–4, 6–7 (dual-runtime) e 9–19 (Task Kernel) **implementadas, revisadas
(Reviewer + Security Reviewer) e corrigidas**; Phase 5 entrega só o harness
(enforcement comportamental V2 pendente), Phase 8 tem o smoke de binário V2
wired no job `ci-smoke-opencode-v2` via lifecycle explícito do serviço
gerenciado (padrão P22, **3/3 PASS local** em 2026-10-03; primeira execução
real no runner pendente do push do operador); evidência completa em
`evidence/v3.1/kernel-hardening/implementation-status.json`.

Programa **V3.1 — Runtime Reliability, Loop Recovery & Jev MCP
(Phases 21–42)** em andamento — **fatias kernel-side/plugin P26–P42
code-complete e commitadas em 2026-10-02/03** (P26 S1, P27 S1, P28
S1+S2, P29 S1, P30 S1, P31 S1+S2, P32, P33 S1, P34, P35, P36, P37,
P38 S1+S2, P39, P40 S1+S2, P41 S1+S2 e P42 fatia 1 — todas com suítes
verdes, Reviewer + Security Reviewer **APPROVED** e HOLDs explícitos;
ver bullets abaixo). As pendências restantes são de **ativação e
evidência do operador** (release gate), não de código faltante
(detalhes em
`evidence/v3.1/runtime-reliability/program-status.json`; rastreio por
critério `PAE-01`–`PAE-40` em
`evidence/v3.1/runtime-reliability/pae-traceability.json`;
especificação e plano em
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md`,
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md` e
`docs/specs/ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md`):
- **P21 done** — baseline congelado (`baseline.json`): pins V1/V2
  presentes, listener `49374` **não é AI Memory** — é o serviço de fundo
  do V2 CLI (`opencode.exe serve --service` do npm global) que o harness
  respawn a cada sessão/restart (stop owned e efêmero por construção),
  nunca mutado aqui; fixtures de watchdog **17/17 PASS** (PS5.1 e PS7),
  record-only, sem enforcement; consistência **16/16 OK**;
  `CapabilityFlags` **20/20**; smokes V1/V2 com FAILED honesto por
  ambiente (sem retry, sem regressão).
- **P22 parcial-HOLD** — preflight determinístico de porta/processo
  (`scripts/runtime/RuntimePortPreflight.ps1`, 6 outcomes, exits
  0/1/2); wrapper V2 com startup condicionado a configuração verificada
  + `PORT_FREE`; E2E nativo alternativo provado em perfil isolado
  (`native-start-contract.json`, 16/16 steps, `candidate_pass`);
  diagnóstico real do `49374` (Docker/ssh por PID, nunca mutado;
  registro do diagnóstico de então — identidade do listener corrigida em
  2026-10-03, ver P21 acima);
  AI Memory **nunca** mutado. HOLDs: `REUSE`, wrapper produtivo
  `UNVERIFIED` (exit 2 sem schema exato), cleanup de descendants entregue
  pela fatia Job Objects (ver bullet próprio), set/start nativo só com
  `RR_P22_RUN_NATIVE=1`.
- **P22 — fatia Job Objects (cleanup de descendants à prova de escape,
  2026-10-04)** — `scripts/runtime/lib/RuntimeJobObject.ps1` (P/Invoke
  compatível com PS5.1): job com **somente** `KILL_ON_JOB_CLOSE` (0x2000),
  breakaway negado por omissão de `BREAKAWAY_OK`/`SILENT_BREAKAWAY_OK`,
  atribuição **exclusivamente** por handle retido do spawn próprio (nunca
  `OpenProcess` por PID; recusa do próprio host), query de membros bounded
  (lista parcial no overflow, contadores reais do SO), settlement por
  deadline absoluto com espera `min(poll, restante)` e falha de API
  devolvendo resultado estruturado (sem exceção); `Invoke-SpikeChild` com
  `-JobObject` opcional (caminho legado inalterado);
  `smoke-opencode-v2-lifecycle.ps1` com contenção fail-closed (job criado
  e validado **antes** do `service start`; PASS exige atribuição
  comprovada; `Finalize-Job` memoizada: observar membros → fechar job →
  stop gracioso gated → snapshot `49374` por último, com backstop
  explícito vs kill-on-close distintos na evidência). Suíte
  `scripts/runtime/runtime-job-object.tests.ps1` **113 asserts**
  (47→73→88→104→113), 5 runs verdes (PS5.1 3x, PS7 2x), discriminantes-
  chave provados por mutação; regressões verdes nas duas engines
  (SpikeProcess 51/51, wrapper 33/33 — PS7 31/31 + 2 SKIP de ambiente,
  watchdog 134/134, enforcement 339/339, consistência 16/16); tester
  independente `candidate_pass`, sem resíduo de processos/probes. Reviewer
  **APPROVED r5** + Security **APPROVED r4/r5** (r1: 9 findings com 3 HIGH;
  r2: 5 MEDIUM; r3: 6 MEDIUM; r4: 3 MEDIUM; r5: fechado). HOLDs honestos:
  (a) janela create→assign (sem `CREATE_SUSPENDED` via .NET) — descendente
  nascido nessa janela fica fora do job; (b) veredito E2E no binário V2
  real pendente da primeira execução no runner (release gate do operador);
  (c) wiring do job no **enforcement** do watchdog = follow-up (P26 segue
  flag off; a árvore CIM ainda não consome o job); (d) `-FaultInject*` são
  parâmetros de teste, não ligados por nenhum caminho de produção; (e)
  prova de breakaway é por query de flags (sem spawn negativo real);
  (f) pré-existente: `taskkill` por PID no timeout de `Invoke-SpikeChild`.
- **P23 done-record-only** — orçamentos canônicos no kernel
  (`phase23.json`): 5 perfis com defaults exatos (worker 45m, planner
  90m, steps 96, soft 3 / hard 5), role defaults, sem ampliação
  (`BUDGET_IMMUTABLE`/`BUDGET_WIDEN_DENIED`), planner-turn por input
  novo, CLI `task-kernel.ps1` (`get-budget/start-attempt/set-budget/
  planner-turn`); kernel pré-existente **75/75** preservado. Sem
  enforcement real (Phases 24–28); native step em HOLD.
- **P24 parcial** — plugin V2 migrado para `event.subscribe`
  abort-safe (`plugins/orchestration-enforcement/v2.ts`); live-hook no
  binário exato 2.0.18 (`phase24-livehook.jsonl`): plugin carrega,
  `session.created` VERIFIED, context VERIFIED, `execute.before` e
  `session.updated` NOT-VERIFIED com causa, interrupt/wait com presença
   verificada; typecheck V1+V2+DUAL, dual-runtime **20/20**, mock V2
   **22/22** (10c + 10c-controle com discriminação), V1 **30/30**,
   live-hook PS5.1 **35/0 HOLD 1** (trigger real com session==trigger,
   match=True) / PS7 **23/0 HOLD 4**; REV-FIX com 3 findings +
    TRIGGER-FIX com 4 findings corrigidos.
- **P25 done-shadow** — RuntimeWatchdog lib shadow puro
  (`scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1`, `phase25.json`):
  registra execução, fingerprints sanitizados por campo com framing
  `len:valor`, semântica de repetição da policy (soft 3 / hard 5),
  avaliação `HARD_TIMEOUT`/`NO_PROGRESS`/`REPEATED_ACTION`/`CYCLE`/
  `BUDGET_NEAR_LIMIT` em modo shadow (would-interrupt, execução
  intacta, sem task record), telemetria JSONL bounded com lock
  in-process e cap fail-closed, identidade obrigatória, flag
  `watchdog{enabled:false, shadow:true}`; `enabled=true` retorna
  `WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED` (nada armazenado).
  Suítes: watchdog **80/80** (PS5.1 + PS7), kernel **75/75**,
  consistência **16/16 OK**; reviews Reviewer **APPROVED** (REV4) +
  Security **APPROVED** (SEC3). Follow-ups documentados: lock
  cross-process, retenção multi-dia; interrupt real é Phase 26
  (não implementado).
- **P27 slice 1 done-code** — recovery com estrategia, typed waits e
  trabalho idempotente no kernel (`scripts/v3/lib/
  OrchestrationTaskKernel.ps1`, `scripts/v3/task-kernel.ps1`,
  `evidence/v3.1/runtime-reliability/phase27.json`): campos opcionais
  no attempt (strategy_id/fingerprint, failure_class/detail,
  recovery_source, new_evidence_refs, recovery_fingerprint,
  changed_from_previous); fingerprints canonicos SHA-256
  (`sha256:` + hex) para estrategia, falha/recuperacao, wait
  tipado e work unit (rewording lexical nao reseta contagens;
  sinonimos reais nao sao canonicos); gates no start-attempt
  (`STALLED_STRATEGY_REJECTED`, `DEBUGGER_REQUIRED` na 2a falha
  material sem trace do debugger, `EXHAUSTED` na 3a sem novidade;
  com novidade abre); waits tipados com enum fechado
  (`human_decision|external_dependency|worker|review|approval|
  runtime_recovery`) + fingerprint, prose-only declarado rejeitado
  (`WAIT_TYPED_REQUIRED`), re-block idempotente, unblock exige
  referencia (`UNBLOCK_REF_REQUIRED`); dedupe de work ativo por
  projeto (`DUPLICATE_ACTIVE_WORK` com `existing_task_id`, nunca
  funde; sem projeto nao recusa, so registra). Suite nova **29/29**
  (PS5.1 + PS7); regressoes: kernel **75/75** (PS5.1; PS7 74/75 com
  1 falha pre-existente de leases), budget **117/117** (PS5.1 + PS7),
  consistencia **16/16**. Flags inalteradas; dispatch do Debugger e
  wiring de prompt do Planner fora do slice (HOLD honesto).
- **P27 slice 1 FIX1 (review findings F-A..F-G)** — `require_typed_waits`
  sticky por task (opt-in na criacao, imutavel; prose-only =>
  `WAIT_TYPED_REQUIRED` so na task strict, lane legada intacta); dedupe
  atomico sob lock `WORKDEDUPE` do tasks-dir (concorrencia real com 2
  ids => 1 vencedor + `DUPLICATE_ACTIVE_WORK`); framing `len:valor` em
  toda serializacao de fingerprint (colisoes estruturais separadas);
  replay de evidence ref nao conta como novidade; resultado herda a
  strategy do attempt (`STRATEGY_MISMATCH` em divergencia); 3a tentativa
  autorizada consome a novidade sem switches artificiais;
  `active_wait` corrompido falha fechado (`MALFORMED_WAIT`). Suite
  **46/46** (PS5.1 + PS7, cenario 16 sob deadline externo real);
  regressoes inalteradas. Residuais em `phase27.json`: refs atestadas
  (existencia/frescor nao verificados), owner e string declarada,
  fingerprints lexicais.
- **P27 slice 1 FIX2 (re-review convergente: variavel, anti-replay,
  binding)** — gate anti-replay nao reutiliza mais `$sid` (variavel
  exclusiva por ref; `session_id` persistido e sempre o solicitado);
  idempotencia da mesma sessao via fast-path antes dos gates de
  novidade; refs consumidas pelo kernel (`consumed_evidence_refs`,
  sob o mesmo CAS/lock do start que autoriza) entram no seen-set
  junto as declaradas pelo worker (mesma normalizacao trim; replay
  puro rejeitado, misto com 1 ref nova abre); start aware sem
  descritor herda estrategia da ultima falha (`lastFp` + descritor)
  e persiste binding completo nao-vazio (resultado bare registra
  `candidate_pass` sem `ATTEMPT_GATE_FAILED`); em attempts aware a
  hipotese bound vence kernel-owned (divergente do worker vai em
  `worker_hypothesis`; omitida herda a bound). Suite **56/56**
  (PS5.1 + PS7); regressoes: kernel **75/75** (PS5.1; PS7 74/75 com
  1 falha pre-existente de leases), budget **117/117**, consistencia
  **16/16**. Residuais mantidos: evidencia atestada nao verificada,
  owner declarado, fingerprints lexicais, reserve-antecipada possivel
  na fronteira administrativa.
- **P27 slice 1 FIX3 (re-review: equivalencia da requisicao)** —
  idempotencia do start exige requisicao efetiva IDENTICA ao binding
  (`Test-TaskKernelStartRequestEquivalent`: mesma sessao/role/
  attempt_n + fingerprint efetivo com heranca `lastFp`, strategy id,
  hipotese e set de evidence refs, tudo normalizado com trim e o
  mesmo pipeline `Protect` do bind; resolve/parse-fail nunca e
  idempotente). Mesma sessao com estrategia/hipotese/refs
  divergentes cai no fluxo normal do gate (rejeita ou re-autoriza
  com novidade, nunca sucesso ambiguo); fingerprint invalido recebe
  `INVALID_STRATEGY_FINGERPRINT` sem escrita; retry byte-identico
  segue idempotente. Suite **61/61** (PS5.1 + PS7); regressoes:
  kernel **75/75** (PS5.1), budget **117/117**, consistencia
  **16/16**. Residuais mantidos.
- **P26 slice 1 done-code-flag-off (hardened P26-FIX1 + P26-FIX2
  + P26-FIX3 + P26-FIX4 + P26-FIX5 + P26-FIX6 re-review)** — caminho de ENFORCEMENT real do
  RuntimeWatchdog com processos proprios no Windows
  (`scripts/v3/lib/OrchestrationRuntimeWatchdog.ps1`,
  `evidence/v3.1/runtime-reliability/phase26.json`): binding opcional
  de processo validado no registro com identidade EXATA de creation
  time (tick equality, sem janela de tolerancia) e parentage
  CIM-provada (CIM precisa suceder e o parent vivo precisa ser o
  supervisor; valores declarados nunca sao prova; CIM
  indisponivel/divergente registra SEM binding, advisory
  `WATCHDOG_NO_PROCESS_IDENTITY`); o registro tambem captura
  last_alive_proof e o conjunto vazio last_verified_tree: a prova e
  o instante UTC coletado DURANTE a validacao — timestamp capturado
  ANTES, vida confirmada DEPOIS com checagem explicita na mesma
  instancia pinada (`HasExited -eq $false`; vivo-depois implica
  vivo-na-captura); sem vida confirmada nao ha prova e a validacao
  falha fechado (devolvido como `proof_at` so com vida confirmada,
  sem fallback now() em nenhum ponto: registro sem prova =>
  INVALID, ownership sem prova => REFUSED `proof-unavailable` mesmo
  com identidade e parentesco ok, gone-path sem prova => REFUSED);
  o refresh no Invoke usa o `proof_at` do ownership bem-sucedido;
  o conjunto atualiza a cada arvore bem-sucedida;
  interrupcao segura com ownership
  re-verificada imediatamente antes de qualquer kill (divergencia ou
  fato nao-provavel => `WATCHDOG_INTERRUPT_REFUSED`, PIDs
  desconhecidos nunca mortos); pre-checagem, Kill e WaitForExit
  operam SEMPRE no HANDLE PINADO da instancia verificada (fixado no
  primeiro acesso; PS5.1 e PS7 cacheiam o handle, sem re-resolucao
  por PID em nenhum ponto; acesso negado ao handle => falha de
  inspecao, nunca kill); ownership explicito de handles: toda
  instancia fixada e nao transferida ao caller e descartada
  deterministicamente (choke de dispose com contador diagnostico:
  excluidos, recusas, preparacao abortada, registro/ownership
  recusados);
  ausencia provada vs falha de inspecao distinguidas
  (falha de inspecao => `WATCHDOG_INTERRUPT_FAILED` com settlement
  PENDING, nunca SETTLED); kill em duas fases cobre raiz +
  descendentes verificados via snapshot CIM com identidade por
  geracao (fronteira pid+ticks, nunca PID nu; linha CIM do ancestral
  correlacionada com a instancia fixada; filho claramente mais velho
  que o ancestral e prova de NAO-descendencia => excluido do kill
  set, transitivo, contado em `tree_excluded` com o token fechado
  `WATCHDOG_TREE_EXCLUDED`, nunca falha da op; faixa ambigua falha
  fechado sem matar); no gone-path, liquidacao restrita a atribuicao
  PROVAVEL a geracao registrada (identidades exatas do ultimo
  conjunto verificado, ou criacao <= lastAliveProof; mais novo =>
  EXCLUDED, nunca morto — fecha a janela PID-reutilizado entre a
  ausencia observada e o snapshot); caps fail-closed de
  profundidade (32) e nos (64) com fronteira pendente =>
  `WATCHDOG_TREE_LIMIT_EXCEEDED`, nada morto, nunca settled,
  settlement REFUSED; raiz ja salida nao abandona o conjunto
  verificado/atribuido (mata/aguarda todos; `ALREADY_EXITED`
  so apos o exit do conjunto inteiro; falha => FAILED com PENDING);
  deadline compartilhado cobre a preparacao, e transportado a cada
  stop e re-checado antes de QUALQUER terminalizacao nos DOIS caminhos
  (inclusive o ramo vazio do gone-path): checagem na entrada do nivel,
  apos cada enumeracao, a cada candidato, antes do primeiro kill, antes
  de cada stop, antes de terminalizar e revalidado imediatamente antes
  de qualquer persistencia terminal, inclusive apos a escrita
  (bloqueante) de telemetria; pos-prazo com kills => FAILED
  com settlement PENDING parcial e evidencia preservada (`partial`,
  `killed_count`, nunca terminal — chamada posterior retoma o restante);
  pos-prazo sem kills => `WATCHDOG_DEADLINE_EXCEEDED`; sem Job Objects
  (BLOCKER conhecido da P22, follow-up); settlements terminais
  (SETTLED/ALREADY_EXITED) centralizados e idempotentes por qualquer
  entrada (sem degradacao); seam `-FaultInject` de enum fechado, default ausente,
  test-only (+ overrides test-only de snapshot/parentesco/atraso/
  ambiguidade, `null` em producao); kernel fail-closed (transicao
  generica para CANCELLED/EXHAUSTED e auto-exaustao via worker-result
  exigem settlement; helper malformado/excecao nunca le como livre);
  seam minimo no kernel (`Set-/Confirm-OrchestrationTaskWatchdogSettlement`,
  `SETTLEMENT_REQUIRED` em complete/cancel, CLI
  `watchdog-interrupt`/`watchdog-settle`); flag
  `watchdog{enabled:false, shadow:true}` **inalterada**; registro sem
  binding em ENFORCE mantem o HOLD honesto P25. Suite nova **339/339**
  (PS5.1 + PS7, so filhos efemeros proprios; TODOS os cenarios de
  risco sob harness de deadline real via Start-Job/Wait-Job-Timeout
  — hung, CLI, arvore, fail-closed — com aborto provado; cenarios
  rapidos com Stopwatch; refusal/injecao de falha via seam;
  readiness-wait anti-race .NET Core); regressoes:
  watchdog **80/80** (PS5.1 + PS7), kernel **75/75** (PS5.1; PS7 74/75
  com 1 falha pre-existente, caminho so de leases, sem codigo
  watchdog envolvido), consistencia **16/16**.
  Residuais honestos: spawn pos-snapshot escapa; orfao de filho
  morto antes do snapshot escapa; over-exclusao conservadora no
  gone-path (nascido entre a ultima prova e a morte escapa);
  UMA chamada CIM individual fica sob os timeouts do WMI;
  transiente CIM/WMI sob carga falha fechado (REFUSED/
  DEADLINE_EXCEEDED, direcao segura) sem retry — 1 ocorrencia
  observada no cenario 25 do FIX2 sob carga paralela, verde no
  re-run solo e no PS7; conhost transitorio sob pwsh drenado nos
  testes gone-empty (somente imagem conhost, limitado); lock
  in-process; ator/fonte sao strings do chamador, sem autenticacao
  de processo. Variante substituto-PID da janela validacao→gravacao:
  coberta indiretamente (fail-closed de prova ausente + identidades
  exatas do conjunto verificado); sem teste direto do substituto.
  HOLDs: ativacao da flag e decisao humana; interrupt de sessao V2
  nativa e step budget nativo seguem HOLD.
- **P28 slice 1 done-code-fix10** — MCP safety envelope e circuit
  breaker kernel-side (`scripts/v3/lib/OrchestrationMcpSafety.ps1`,
  `source/registry/mcp-request-policy.json`,
  `evidence/v3.1/runtime-reliability/phase28.json`): policy canônica
  validada fail-closed (`MCP_POLICY_INVALID`) com budgets por classe —
  advisory/Jev 30s, memory 60s, general remote 120s, long-running só
  com contract explícito (connect sempre pelo budget da policy);
  circuito por (server, capability, planner-turn) abre com 2 falhas
  consecutivas timeout/rede, cooldown contado da CONCLUSÃO da falha,
  half-open com probe único sob lock por chave, rearm por sucesso;
  fast-fails estruturados sem exceção na fronteira (`MCP_TIMEOUT`,
  `MCP_CIRCUIT_OPEN`, `MCP_LOCK_BUSY`, `MCP_BUSY_GLOBAL`,
  `MCP_ABANDON_LIMIT_REACHED`, `MCP_CAPACITY_CELL_UNAVAILABLE`);
  criticidade optional => `MCP_UNAVAILABLE` + fallback_continue,
  required => `MCP_REQUIRED_BLOCKED` fail-closed em todos os ramos
  (timeout/rede/circuito/erro comum/lock-busy/guard-busy/cap/
  cell-unavailable); guard de autoridade sempre-nega (nenhum
  resultado concede ou transporta grants); telemetria JSONL
  sanitizada bounded (allowlists fechadas, redação por campo,
  framing `len:valor`, cap com rotação fail-closed, skip `lock-busy`
  sob contenção); reserva atômica de capacidade via célula C#
  compartilhada (in-flight + abandonados ≤ 8; abandono consome a
  unidade permanentemente; sem célula => fail-closed); timeout da
  probe com `BeginStop` + margem de settle bounded e abandono
  deliberado de runspace sem dispose (`settled=false`, sem rollback —
  retry automático de efeitos colaterais proibido); todos os locks
  com aquisição bounded (zero `Monitor.Enter` sem timeout; ordem
  global→chave documentada). Fechamento **FIX6–FIX10** (2026-10-02,
  5 rounds Reviewer + 2 Security): estado do circuito e locks por
  chave compartilhados **no processo** (dicionários privados em C#,
  `TryEnter` bounded, ordem global→chave), validação estrita do wire
  com **UNKNOWN fail-closed** (ausência ≠ falha de leitura; wire
  malformado nunca vira CLOSED), normalização
  `MCP_REQUIRED_BLOCKED`/`blocked=true` em **todos** os ramos
  `required`, recursão de policy bounded (profundidade/nós/ciclo),
  falha de leitura pós-admissão sem escrita, cap de wire 4096 antes
  do split. Suíte **202/202** (PS5.1 + PS7, runner oficial; 123 base
  + 79 asserts novos); regressões: watchdog **80/80**, kernel
  **75/75** (PS5.1), McpRouter **58/58**, flags **20/20**,
  consistência **16/16**;
  `capability-flags.json` byte-idêntico (`mcp_routing` segue OFF),
  nenhum arquivo de plugin tocado. Reviews: Reviewer **APPROVED**
  (round 10; 10 rounds no total) + Security **APPROVED** (sem
  HIGH/CRITICAL; 2 LOW resolvidos — store em campos C# privados e
  cap de wire antes do split; fixture não-cooperativa determinística
  prova retorno bounded do chamador).
  HOLDs honestos: TurnId declarado sem autenticação; runspace não é
  sandbox (só scriptblocks confiáveis do kernel); locks in-process
  (cross-process follow-up); ocupação por abandono não-reclaimable;
  enforcement em transporte real (plugin/integração TS) é slice 2;
  falha pré-existente/ambiental da suíte `WatchdogEnforcement`
  provada por A/B sem os arquivos do slice.
- **P28 slice 2 done-code-fix3-shadow** — envelope bounded de
  transporte MCP no plugin TS (`plugins/orchestration-enforcement/
  shared/mcp-transport.ts`, `shared/telemetry.ts`, `v2.ts`,
  `tests/distribution/plugin-mcp-transport.tests.ps1` + harness):
  classificação conservadora por allowlist fechada (sem descoberta
  automática; `mcp_routing` segue OFF), budgets por classe
  30/60/120s (long-running só com contrato explícito), timeout
  enforced via race com cleanup em `finally` (zero timers órfãos,
  `unref`), circuito por `(server, classe, turn)` com 2 falhas ⇒
  `OPEN`, cooldown contado da conclusão, half-open com probe único e
  release garantida em abort (abort não conta como falha do server),
  parser estrito exigindo os valores canônicos do policy
  (30/60/120, connect 10/15/20, cooldown 300), cache por conteúdo
  integral, `MCP_REQUIRED_BLOCKED` em todos os ramos `required`,
  **shadow default** (observa, nunca altera admissão — inclusive
  pré-aborto), enforced só com opt-in explícito
  (`OO_MCP_TRANSPORT_ENFORCED=1`), telemetria sanitizada
  allowlisted, wiring V2 abort-safe sem bloquear, V1 observe-only.
  Suíte **142/142** (pwsh + powershell), dual-runtime **20/20**,
  mock V2 **22/22**, plugin V1 **30/30**, consistência **16/16**;
  typecheck V1+V2+DUAL com bundle/sidecar regenerados. Reviews:
  Reviewer **APPROVED** (round 3; abort no probe half-open
  resolvido) + Security **APPROVED** (sem HIGH/CRITICAL). HOLDs:
  enforcement em binário real V2 **não validado** (`execute.before`
  é observação; `runMcpGuarded` exige integração explícita), V1
  observe-only, eviction do circuito fail-open documentado,
  abandono sem rollback.
- **P29 slice 1 done-code-fix2** — integração advisory do Jev
  kernel-side (`scripts/v3/lib/OrchestrationJevAdvisory.ps1`,
  `source/registry/jev-advisory-policy.json`): flag
  `jev_advisory {enabled:false, shadow:true}` nasce **OFF** (sanção
  do plan §6.1); policy canônica com tool set fechado
  (check/gate/score/decide), budget 30s, probe 10s, circuito
  2/300s, criticality optional (`JEV_UNAVAILABLE` ⇒ fallback
  determinístico, nunca bloqueia), credencial só como **nome de
  env** (`JEV_API_KEY`, sem valor em registry/git); bounded invoke
  **reusando o envelope P28** (classe advisory, seam sintética,
  zero rede); trigger policy determinística (trivial nunca
  consulta; 6 razões estáveis); authority guard sempre-nega
  (kernel deny vence Jev allow; verifier fail vence Jev complete);
  evidência advisory JSONL sanitizada com cap fail-closed. Suíte
  nova **73/73** (PS5.1 + pwsh); McpSafety **203/203** (AC10
  atualizado ao shape canônico com `jev_advisory`), CapabilityFlags
  **22/22**, consistência **16/16**; kernel **75/75** intocado.
  Reviews: Reviewer **APPROVED** (round 3) + Security
  **APPROVED**. HOLDs: transporte real (rede) não ativado;
  ativação da flag é decisão humana com evidência; integração no
  fluxo do Planner é fatia 2 (P31/P38).
- **P30 slice 1 done-code-fix2** — dependência remota bounded do
  AI Memory kernel-side (`scripts/v3/lib/
  OrchestrationAiMemoryRemote.ps1`,
  `source/registry/ai-memory-remote-policy.json`): policy com
  endpoint **user-owned** (vazio/placeholder, auth só nome de env
  `AIMEMORY_REMOTE_TOKEN`, `tls_verify` fixo true), retrieval 60s /
  health 10s, circuito 2/300s **reusando o envelope P28** (classe
  memory), **remote-only por config** — ausência de config ⇒
  `AIMEMORY_UNCONFIGURED` (optional continua / required bloqueia
  tipado), **nunca fallback silencioso** para o listener local
  `49374`, que permanece intocado; `POLICY_INVALID` fail-closed
  bloqueante nas duas criticalities (matriz de testes **8/8**);
  telemetria sanitizada (host+len:port, escopo hasheado, redação
  nominal do token). Suíte **111/111** (PS5.1 + pwsh);
  consistência **16/16**; regressões verdes. Reviews: Reviewer
  aprovou o código (round 2) + Security **APPROVED**. HOLDs:
  deploy real do VPS é infra do operador; re-preflight de porta V2
  e fechamento de HOLDs de REUSE só com evidência pós-migração;
  transporte real exige HTTPS.
- **P31 slice 1 done-code-fix3** — bootstrap context builder
  kernel-side (`scripts/v3/lib/OrchestrationBootstrapContext.ps1`):
  read-only e **parse-only** (nunca executa processo/scripts;
  runtime via `RuntimeInfo` injetado ou `unknown/not-probed`),
  seções project/runtime/capability_health/tasks/pending_waits/
  jev_status/aimemory_status, **não-bloqueante** (fonte
  ausente/corrompida ⇒ seção `unavailable`), byte budget com
  **sequência única de descarte** (refs → waits.refs → jev →
  aimemory → counts → capability_health por último, provada por
  teste de snapshots sucessivos), sanitizado (hostname/token/`sk-`),
  determinístico com clock injetável. Suíte **16/16** (PS5.1 +
  pwsh); consistência **16/16**; kernel **75/75** intocado.
  Reviews: Reviewer **APPROVED** (round 4) + Security
  **APPROVED**. HOLDs: ativação de runtime (auto-start, AGENTS.md
  global, default_agent) é estado do operador; wiring no início de
  sessão é fatia 2.
- **P31 slice 2 done-code-fix1** — startup wiring (`scripts/runtime/
  SessionBootstrapContext.ps1`, CLI hook-style sobre o builder S1):
  **fail-open total** (arranque nunca bloqueia — qualquer falha
  interna emite envelope mínimo válido com exit 0; exit 1 só uso
  estrutural), saída JSON **bounded** com LF reservado no budget,
  determinismo com timestamp injetável, **parse-only** (zero
  spawn/rede), telemetria de compliance **metadata-only** (task 8 do
  plano) com cap 1MB atômico entre processos (handle exclusivo
  measure+append), contenção ⇒ skip silencioso, falha operacional ⇒
  nota honesta no stderr sem bloquear. Suíte **43/43** (PS5.1 +
  pwsh). Reviews: Reviewer **APPROVED** (round 2) + Security
  **APPROVED** (round 2). **Nada é registrado/instalado** — a
  ativação do wiring no arranque real permanece decisão do operador.
- **P33 slice 1 done-code-fix3** — Continuation Envelope +
  reconciler kernel-side (`scripts/v3/lib/
  OrchestrationSessionReconciler.ps1`): envelope bounded 8KB
  (objective, intent, decisões, evidências, estratégias falhadas
  **sem transcripts**, riscos, typed waits, next move) com redator
  **compartilhado** em todos os campos (padrões hostname/TLD,
  transcript, token=valor, `sk-proj-` promovidos ao
  `CapabilitySanitize`), timestamp injetável como **valor** (sem
  scriptblock); **SESSION_LOST** tipado (declared missing + proof,
  sem mutar task); reconciler determinístico sobre bindings P32 +
  observações declaradas com ações **recomendadas** (reattach via
  CLI, recover-output, inspect-interrupted) — nunca probe/kill;
  caps 200/500 fail-closed; V1 fresh-session sem fake resume.
  Suíte **156/156** (PS5.1 + pwsh; matriz adversarial 15×9);
  regressões completas verdes. Reviews: Reviewer + Security
  **APPROVED** (4 rondas). HOLDs: reconciler V2 nativo, probe
  real, registro kernel-side de SESSION_LOST.
- **P34 slice 1 done-code-fix3** — execution modes kernel-side
  (`scripts/v3/lib/OrchestrationExecutionModes.ps1`,
  `source/registry/execution-modes-policy.json`): decisão pura
  determinística **A** (deterministic workflow) / **B** (persistent
  specialist) / **C** (one-shot); B duplamente gated (policy
  `specialist_enabled: false` default + `runtime_caps` OFF — HOLD
  de primitiva) com elegibilidade explícita e `fallback_from`
  distinguindo `policy-off`/`runtime-unsupported`; **team_size
  sozinho nunca decide** (teste de controle); descriptor hostil ⇒
  C conservador; evidência sanitizada com timestamp validado
  semanticamente (DateTimeOffset RoundtripKind, offset
  normalizado). Suíte **35/35** (PS5.1 + pwsh). Reviews: Reviewer
  **APPROVED** (round 4) + Security **APPROVED**. HOLDs: wiring no
  Planner é fatia 2 (P38); primitiva runtime de specialist.
  
  **Wave B concluída** (P31–P34 kernel-side, 2026-10-02).
- **P32 done-code-fix5** — bindings Task/Run/Seat/Session no kernel
  (CAS, single-owner por task, rebind somente detached, IDs 128/charset,
  CLI com exits e resolução de RunId; 29/29; kernel 75/75 preservado).
- **P35 done-code-fix3** — evidence reuse store (schema reutilizável
  com identidade/provenance, validade por fingerprints/criteria/
  revision-policy/ttl invariante, query compacta sem raw, retrieval
  com containment + reparse-point walk + streaming cap, métricas;
  38/38).
- **P36 done-code-fix2** — validação adaptativa L0–L3 (policy como
  autoridade fail-closed, triggers duros incontornáveis, completion
  gate com effective_level = max — risk desconhecido ⇒ L3, cobertura
  completa de fingerprints com TTL default; 35/35).
- **P37 done-code-fix2** — disciplina de simplicidade (contrato
  MSC/NBW/RBC/ABE/stop-condition, ChangeBudget soft 1x/hard 2x com
  rationale, checklist assistida do Reviewer; 31/31).
- **P38 done-code-fix2** — planner adaptive loop (Frame→Reuse→
  Simplicity→Risk→mode→budget→dispatch→gaps→complete reusando
  P29/P34–P37; PLAN RECORD com cap 8KB garantido via envelope mínimo
  válido; Jev não-autoritativo; 21/21).
- **P38 fatia 2 done-code-fix3** — dispatch integration kernel-side
  (`OrchestrationDispatchPipeline.ps1`): pipeline **record-only** que
  consome o PLAN RECORD e produz bundle de despacho — contratos de
  worker com os 9 campos do contrato de delegação derivados só de
  plan+descriptor declarado; no-widen (budget não reservado ⇒ rota
  mínima; workers vazio declarado ⇒ 0 contratos; cap com contador de
  consumo independente); gate de completion P36 fail-closed
  (unknown-required-role/gate-unverifiable/gate-unavailable/
  validation-stage-unavailable); persistência P35 só com `store_dir`
  explícito (path original verbatim) e ≥1 invalidation_condition;
  truncagem UTF-8 com surrogate pairs atômicos; determinismo
  byte-idêntico. Suíte **201/201** (PS5.1 + pwsh, roda concorrente).
  Reviews: Reviewer **APPROVED** (round 4) + Security **APPROVED**
  (round 4). Ativação operacional do despacho = decisão do operador.
- **P39 done-code-fix2** — capability doctor (descriptores com bool
  estrito pós-bug de coerção, fallback valida destino, risk_class
  execution/authority bloqueia, jevgrep opcional com
  Windows-unsupported honesto; 38/38).
- **P40 done-code-fix1** — V2 native gating data-driven (8 features
  hold-unproven; enabled só com evidência exact-binary validada —
  pin/scenario exact-match + SHA-256; 114/114).
- **P41 done-code-fix5** — evolution loop observacional (candidates
  com threshold+refs distintos, eval offline com cobertura
  incompleta ⇒ inconclusive, promoção explícita one-at-a-time com
  enumeração fail-closed, leituras bounded 32KB nos 3 caminhos,
  TOCTOU removido; 147/147 mutation-tested).
- **P42 fatia 1 done-code-fix2** — E2E manifest + rollout checklist
  (`scripts/v3/lib/OrchestrationE2eManifest.ps1`,
  `source/registry/e2e-scenarios.json`): **41 cenários** (40 do plan
  + invariante sintética separada do policy-deny) com classificação
  honesta - **18 runnable-synthetic pass** (checagens reais contra
  as libs P28-P41) e **23 blocked honestos** (19 operator-runtime,
  1 flag-activation, 3 real-transport - nunca fake-pass; aritmética
  reconciliada com `phase42.json#honest_counts` em 2026-10-03, o texto
  anterior dizia 22 por erro de soma); rollout
  checklist de 19 passos com promote fail-closed. Suíte **194/194**
  (PS5.1 + pwsh; mutação 7/7). Reviews: Reviewer **APPROVED**
  (round 3) + Security **APPROVED**. **Release gate real pendente
  do ambiente V2 do operador — sem fake-close.**
- **P41 fatia 2 done-code-fix2** — produtor de telemetria
  observacional (`OrchestrationEvolutionTelemetryProducer.ps1`):
  deriva os contadores declarados na policy real a partir de fontes
  **REAIS** (task records do kernel, watchdog JSONL, reuse-metrics
  P35); contador sem fonte real ⇒ **ausente com razão** (nunca
  fabricado); identidade de tentativa via `execution_runtime.attempt_n`
  (schema real do kernel); leitura bounded (scanner sem materializar
  linha acima do cap, snapshot de comprimento contra crescimento
  concorrente); watchdog ilegível ⇒ indisponível sem zeros; escrita só
  com `OutDir` explícito. Suíte **148/148** (PS5.1 + pwsh).
  Reviews: Reviewer **APPROVED** (round 3) + Security **APPROVED**
  (round 3). Wiring de chamador em produção = decisão do operador.
- **P40 fatia 2 done-code-fix2** — revisor de supersessão de
  evidências (`OrchestrationV2EvidenceSupersession.ps1`):
  avaliação determinística fail-closed entre registro existente e
  candidato do gating V2 — vereditos fechados (duplicate /
  supersede-recommended / stale / ambiguous / invalid-* /
  identity-mismatch), identidade **Ordinal** nos 5 campos, agregação
  com precedência (impeditivos ⇒ review-required; duplicate ⇒
  no-op), digest ecoado só com forma `\A[0-9a-fA-F]{64}\z`, Now
  explícito inutilizável ⇒ fail-closed. **Decision-record only**:
  zero escrita, zero habilitação. Suíte **238/238** (PS5.1 + pwsh).
  Reviews: Reviewer **APPROVED** (round 2) + Security **APPROVED**
  (round 3). Append/enable permanece decisão do operador.
- **P25 follow-up done-code-fix8 (2026-10-03)** — telemetria do
  watchdog endurecida (follow-ups documentados do phase25):
  **gate cross-process** na escrita JSONL (mutex nomeado determinístico,
  wait bounded 300 ms, skip razoado `lock-busy`/`mutex-abandoned`/
  `mutex-unavailable`, nunca bloqueia nem lança), **tail-check** sob o
  gate (append recusado com `tail-incomplete` sobre cauda fragmentada,
  fragmento preservado), **retenção multi-dia bounded**
  (`watchdog-YYYYMMDD.jsonl` estritamente anterior a 7 d; orçamento por
  entrada visitada ANTES de qualquer filtragem, caps 64/32, cap=0 não
  enumera `cap-zero`, truncamento conservador sem peek, starvation
  observável via `no_progress`), guard de reparse no diretório (junction
  real testada, canário intacto), canonicalização única de path
  compartilhada por writer/gate/retenção (FIX8: retenção nunca
  re-resolve CWD mutável). Suíte 80→**134** asserts (PS5.1 + pwsh);
  regressões enforcement 339/339, McpSafety 203/203, CapabilityFlags
  22/22, consistência 16/16. Reviews: Reviewer **APPROVED** (r4) +
  Security **APPROVED** (r3). Residuais documentados: squatting do
  mutex (telemetria best-effort, nunca prova de execução/autorização),
  retenção sem cursor (`no_progress` observável; cursor é follow-up se
  enforcement ativar), reparse em ancestral e aliases junction/subst
  não resolvidos. Flag watchdog segue `{enabled:false, shadow:true}`.
- **Honestidade de evidência (2026-10-03)** — campo `date` do
  `smoke-opencode-v2.ps1` agora carimbado do relógio na escrita
  (era hardcoded `2026-09-30`; artefatos históricos permanecem como
  registro do que rodou) e paridade EOF com/sem LF final no leitor do
  produtor de telemetria P41-S2 (follow-up LOW fechado; ramo EOF
  unificado: MaxLines → over-cap → blank → parse, sem schema novo).
  Suíte 148→**164** asserts (PS5.1 + pwsh); EvolutionLoop 147/147;
  mutation check provou não-vacuidade (7 asserts caem sem o fix).
  Reviewer **APPROVED** (r2) + Security **APPROVED**.
- **Phase 8 follow-up done-code (2026-10-03)** — smoke de binário V2
  real via **ciclo de vida explícito** do serviço gerenciado
  (`scripts/ci/smoke-opencode-v2-lifecycle.ps1`, padrão P22): resolve
  binário com **versão exata pinada** (`Test-SpikeExactVersion`, shims
  resolvidos para `.exe`, pin imutável 2.0.18), home isolado **exclusivo
  por execução**, filhos com **`-CleanEnvironment`** (só
  PATH/SystemRoot/ComSpec/PATHEXT/TEMP/TMP/PSModulePath), preflight de
  porta **PORT_FREE && ShouldStart** (49374 recusada na seleção),
  `service set/start/status/stop` owned com listener observado como FATO
  (contrato exato da lib P22: `QuerySucceeded`/`Exists`/`OwningPID`;
  janelas por deadline com modos presence/absence; consulta inconclusiva
  nunca decide), settlement por **ausência conclusiva** (sem claim de
  terminação), invariante 49374 antes/depois, cleanup gated por
  `Invoke-SpikeServiceStopIfOwned` (recusa não-owned provada em execução),
  exceções e bootstrap com evidência failed + exit 1. **3/3 PASS** no
  binário exato 2.0.18 (portas 49339/49635/57173; 49374 owner 1872
  estável). Reviews: Reviewer **APPROVED** (r3) + Security **APPROVED**
  (r3). Evidência: `evidence/v3.1/kernel-hardening/
  v2-ci-smoke-lifecycle*.json` (inclui sumário honesto das 5 execuções,
  2 falhas iniciais por bugs do PRÓPRIO script — contrato de observação e
  semântica inconclusive — sem fake-close). O caminho implícito (debug
  config) segue flaky upstream e fora deste path; wiring do passo no job
  CI aguarda primeira execução no runner.
- **Correção de registro (2026-10-03): AI Memory do operador já remoto**
  — a migração do AI Memory PROD do operador para servidor próprio foi
  **executada** antes de 2026-10-01 (registros anteriores diziam
  "planejada, não executada" — desatualizados). Endpoint é
  **user-owned por design**: cada usuário do pacote aponta o SEU próprio
  AI Memory em arquivo de policy local FORA do repo (override
  `-PolicyPath`); o placeholder público permanece vazio e **nenhum
  endpoint, IP, domínio ou token pessoal entra neste repo público**.
  O listener local `49374` **NÃO é AI Memory**: é o serviço de fundo do
  V2 CLI (`opencode.exe serve --service` do npm global), respawnado a
  cada sessão/restart; segue intocado, e qualquer desativação durável
  é decisão do operador via configuração (não é "resto obsoleto"
  removível). Pendências P22/P30 restantes:
  config local + evidência de health/transporte registrando apenas o
  resultado (nunca a identidade do servidor).
- **Waves A–E code-complete kernel-side/plugin (2026-10-02/03)**;
  pendências de ativação/evidência do operador listadas em
  `evidence/v3.1/runtime-reliability/program-status.json`; rastreio por
  critério em
  `evidence/v3.1/runtime-reliability/pae-traceability.json`.
- **Permissões do tester: shell amplo com negações destrutivas
  (2026-10-03)** — `source/agents/tester.md` troca o deny-default +
  allowlist fechada por `"*": allow` + denies de destruição (`rm`, `del`,
  `erase`, `rd`, `rmdir`, `ri`, `Remove-Item`, `truncate`, `shred`, `dd`,
  `format`), elevação (`sudo`, `su`, `runas`, `gsudo`, `doas`), mutação Git
  (`push`, `reset`, `clean`, `rebase`, `merge`, `commit`, `branch -D`),
  `dropdb`, `terraform destroy`, `kubectl delete`, com `ask` para
  deploy/publish/infra; `edit: deny` e `task: deny` permanecem. Contrato
  reescrito: suíte `scripts/runtime/tester-shell-permissions.tests.ps1`
  (renomeada de `tester-gateway-permissions.tests.ps1`) valida allow de
  validação, deny de rotas destrutivas, ask de deploy, estrutura
  (catch-all allow, wildcard no fim, guard V2), paridade V1=V2 e corpo do
  agente; `agent-translation.tests.ps1` ajustado (catch-all allow; F3 com
  canonical sintético). Suítes 236/236 e 116/116 (PS 5.1). Security review
  (CHANGES REQUIRED → integrado): formas bare de git/sudo/su adicionadas
  como deny exato e claims de docs corrigidos — escrita via shell
  não-listada é proibição comportamental (prompt/planner), não barreira de
  runtime. Decisão explícita do operador; owner determinístico (hard
  exclusion `permission_change` — mudança de permissão não é delegada a
  workers).
Revisões Reviewer + Security Reviewer encerradas com **APPROVED parcial
por fase** (HOLDs registrados). Todas as flags de rollout seguem
**OFF/shadow** (`source/registry/capability-flags.json`; única exceção,
pré-existente do V3: `capability_registry.enabled=true`); nenhuma flag de
rollout nova além de `jev_advisory` (P29, com sanção explícita do plan
addendum §6.1, OFF/shadow);
roteamento MCP genérico segue desligado; critérios `PAE-01`–`PAE-40`
rastreados na matriz
`evidence/v3.1/runtime-reliability/pae-traceability.json`, pendentes
de evidência do operador onde marcados `activation-pending`/
`blocked-operator-evidence`. Programa **não** concluído (release gate
pendente do operador).

### Added

- **Suporte dual-runtime**: OpenCode **V1** (`opencode-ai`, validado
  **1.18.32**) e OpenCode **V2** (`@opencode/cli`, validado **2.0.18**),
  ambos com comando `opencode`.
  - Registry de runtimes (`source/registry/runtimes.json`: descritores v1/v2
    com dialeto de config/permissões, pacote de plugin, chaves geridas e
    raiz de render) + detecção determinística
    (`scripts/runtime/detect-opencode-runtime.ps1`,
    `scripts/runtime/lib/RuntimeAdapters.ps1`: probe de versão/geração,
    fail-closed em ambiguidade).
  - Templates nativos por geração: `templates/opencode.v1.json.tmpl`
    (`agent`/`permission`/`task`/`subagent_depth`) e
    `templates/opencode.v2.json.tmpl` (`agents`/`permissions`/`subagent`/
    `experimental.subagent_depth`), com paridade semântica validada
    (checks 12–15 de `scripts/test-package-consistency.ps1`).
  - Tradução determinística das permissões dos 19 agents
    (`scripts/runtime/lib/AgentTranslator.ps1`: `edit→edit`, `bash→shell`
    broad-first last-match-wins, `task→subagent`, allow/ask/deny
    preservados, fail-closed em padrão ambíguo); testes de paridade em
    `scripts/runtime/agent-translation.tests.ps1`.
  - Plugin dual-runtime: fonte única (`plugins/orchestration-enforcement.ts`
    com `v1.ts`/`v2.ts`/`shared/`), dual-export `{id, setup, server}`,
    bundle autocontido `plugins/dist/orchestration-enforcement.js` +
    sidecar sha256 (o `.ts` legado no destino é adotado para backup) e
    typecheck V1/V2/dual (`scripts/ci/typecheck-plugin.ps1`).
  - `install.ps1 -Runtime Auto|V1|V2|Both` — Auto com probe e fail-closed;
    manifest grava `runtime` + `plugin_dependency` do runtime escolhido;
    `uninstall.ps1 -Runtime Auto|V1|V2` com conflito explícito (exit 6).
  - Perfis isolados V1+V2 na mesma máquina
    (`scripts/runtime/new-opencode-profile.ps1`): config root por perfil via
    `XDG_CONFIG_HOME` por processo (mecanismo provado com binários reais em
    `evidence/v3.1/kernel-hardening/runtime-isolation-spike.json` e
    re-verificado pelo installer com `debug paths`), wrappers
    `bin/opencode-v1.ps1`/`opencode-v2.ps1`, `-ProvisionRuntime` opt-in;
    `-Runtime Both` é fail-closed (exit 6) sem binários provados.
- Versão do pacote: `1.1.0` (era `1.0.0`); dependência V2 do plugin:
  `@opencode/plugin@2.0.18`.
- Spec e plano V3.1 documentados em `docs/specs/`.

- **Task Kernel (Phases 9–19)** — estado de tarefa persistente e
  determinístico, todos com suítes próprias:
  - `scripts/v3/lib/OrchestrationTaskKernel.ps1` + CLI
    `scripts/v3/task-kernel.ps1`: registros em `cache/runtime/tasks/` com
    CAS (lock interprocesso + re-checagem na seção crítica), transições
    legais, estados terminais imutáveis, `DONE` só via
    `Complete-OrchestrationTask` (gate de 12+ cheques; só de `REVIEWING`),
    orçamento de retry (2ª falha exige debugger, 3ª exige evidência nova,
    senão `EXHAUSTED`), identidade de ator com fontes confiáveis e
    redação de segredos em todo texto persistido.
  - `source/registry/execution-grants.json` + interseção de autoridade
    efetiva (baseline ∩ task ∩ runtime ∩ ambiente ∩ aprovação — nunca
    união); grants sensíveis (`destructive.fs`, `deploy.production`,
    `secrets.read`, `git.push`) fora de todo baseline.
  - Evidence Contract: worker só emite `candidate_pass|failed|blocked`;
    `verified_pass`/aprovação vêm só de verifier/reviewer; verificação
    obsoleta após novo trabalho (`verification_stale`/`review_stale`).
  - `scripts/v3/lib/OrchestrationVerifier.ps1` +
    `source/registry/verification-policy.json`: allowlist fechada de
    comandos, checagem de escopo git antes de executar qualquer comando,
    base revision obrigatória, output limitado e com segredos redigidos,
    evidência por critério (`criterion:<idx>:`) gerada pelo próprio
    verifier.
  - `scripts/v3/lib/OrchestrationOwnership.ps1`: write leases em
    `cache/runtime/locks/` com lock de diretório, conflito
    cross-generation (V1 vs V2 no mesmo escopo) e fail-closed em lease
    malformado recente.
  - `scripts/v3/lib/OrchestrationWorktree.ps1`: worktrees por tarefa com
    marker de ownership, nunca `--force` implícito, registro git
    conferido antes de remover.
  - Observabilidade: 14 tipos de evento novos (29 total) e dimensão
    runtime (`runtime_id/generation/version/profile`) opcional e
    sanitizada; flags de rollout conservadoras
    (`task_kernel` desligado+shadow, `worktree_isolation` e
    `runtime_grant_enforcement` desligados, `runtime_support.v2` off até
    ativação com evidência).
- **Revisões independentes**: Reviewer + Security Reviewer emitiram
  `CHANGES_REQUIRED` com 15 findings válidos (concorrência CAS/lease,
  auto-atestação de DONE, evidência claimed, `--force` implícito, união
  de grants, segredos) — todos corrigidos e revalidados (75/75,
  56/56, 49/49).
- **Spike V2 honesto** (`scripts/runtime/spike-v2-permissions.ps1`): com
  V2 2.0.18 provisionado no perfil, `version` e isolamento XDG passam;
  `debug config/agents` travam (2× timeout) — status `failed` registrado
  sem claim de enforcement; checklist comportamental pendente.
- **Lane CI V2** (`ci-v2-lane`): consistência + suítes V3 + distribuição +
  typecheck V1/V2/dual; smoke de binário V2 real tem path comprovado
  localmente (`scripts/ci/smoke-opencode-v2-lifecycle.ps1`, lifecycle
  explícito do serviço gerenciado no padrão P22, **3/3 PASS** no binário
  2.0.18 em 2026-10-03) e está wired como step do job
  `ci-smoke-opencode-v2`, **antes** do smoke implícito (`debug
  paths/config/agents`), que segue flaky upstream
  (`debugcfg-hang-investigation.json`) e foi mantido como probe honesto;
  primeira execução real no runner pendente do push do operador.

### Pendente (não implementado)

- **Release gate de P26-P42 (runtime reliability)** - o código
  kernel-side/plugin está code-complete (2026-10-02/03); o que falta é
  evidência do ambiente do operador, não implementação: lane V2 Windows
  real - **executada parcialmente em 2026-10-03** (preflights reais de
  porta 3/3 verdes, RR-E2E-01/02/03 convertidos com evidência real; ciclo
  de vida explícito do serviço verde - set/start/status/stop owned,
  49374 intocado; porém o startup implícito via `debug config` apresenta
  **intermitência caracterizada experimentalmente** (2026-10-03: 7
  travamentos vs 5 passes no mesmo dia/binário/máquina; stdin, conteúdo
  da config e estado do serviço refutados como gatilhos determinísticos
  nas condições testadas; suspeita principal: caminho interno do binário
  2.0.18, **não comprovada** -
  `debugcfg-hang-investigation.json`) e os cenários de
  watchdog/sessão/
  restart exigem integração de sessão real; evidência em
  `evidence/v3.1/runtime-reliability/v2-lane-2026-10-03/`), config
  user-owned local do endpoint de AI Memory **remota já em PROD** (deploy
  do VPS de AI Memory executado pelo operador; restam a configuração fora
  do repo e a evidência de health/transporte sem registrar identidade no
  repo) e o re-preflight de porta P22, ativações de flag com evidência
  (decisão humana), probes reais de health/transporte, jevgrep real e
  wirings de chamador em
  produção (produtor de telemetria P41, append/enable do revisor de
  supersessão P40-S2, spawn real do despacho P38, hooks de arranque
  P31). Checklist em `evidence/v3.1/runtime-reliability/phase42.json`;
  estado por fase em `program-status.json`; rastreio por critério em
  `pae-traceability.json`.
- **HOLDs estruturais mantidos em P22–P41** — (d) `execute.before` sem
  via sem-modelo provada; evento `session.updated` não observado;
  `REUSE` de porta em produção; reconciler V2 nativo; interrupt de
  sessão V2 nativa; janela create→assign do job e wiring do job no
  enforcement do watchdog (follow-up P26, flag off). Nenhuma flag
  ativada; `program-status.json` mantém o detalhamento por fase.
- **Phase 5 (comportamental)** — validar precedência de regras ordenadas,
  saved approvals e `experimental.policies` contra o runtime V2 real
  (requer resolver o travamento do `debug` V2 e/ou evidência do job
  `ci-smoke-opencode-v2` já wired (primeira execução no runner, pendente
  de push)). Nenhum hard-deny é shipado antes disso.
- **Phase 8 (smoke V2 em CI)** — instalação oficial do V2 no Windows
  (`@opencode/cli@2.0.18` via npm + postinstall) provada localmente e
  smoke de lifecycle wired no job `ci-smoke-opencode-v2`; pendente apenas a
  primeira execução real no runner (push do operador) e a resolução do
  flakiness upstream do `debug config`.
- **Ativação** — flags `task_kernel`/`worktree_isolation`/
  `runtime_grant_enforcement`/`runtime_support.v2`/`watchdog`/
  `jev_advisory` permanecem OFF; ativar é decisão humana com evidência
  (shadow rollout, Phase 19).

### Known issues (pré-existentes, dependentes de ambiente)

- 4 suítes V3 (`CapabilityDeferred`, `CapabilityObservability`,
  `CapabilitySkillUtility`, `shadow-route`) falham no invariante
  "opencode.json vivo inalterado (prefixo DE22307F)" quando o config vivo
  da máquina diverge do baseline canônico do control plane. Já falhavam no
  baseline congelado (`evidence/v3.1/kernel-hardening/baseline.json`) —
  não são regressão do V3.1. As demais suítes (incluindo as novas de
  runtime/adapters/plugin/perfis) passam; ver [TROUBLESHOOTING](docs/TROUBLESHOOTING.md).

## [1.0.0] — 2026-09-25

Primeira release estável do pacote `opencode-orchestration`.

### Added

- Suporte explícito à linha **OpenCode V1.x** (pacote npm `opencode-ai`),
  validado com **1.18.32**.
- Respeito a `opencode.json` **e** `opencode.jsonc`: jsonc vence quando
  ambos existem (igual ao runtime); cria `opencode.json` só se nada
  existir; jsonc com comentários é normalizado para JSON puro na escrita
  (aviso + backup byte-exato do original).
- Job de CI `ci-smoke-opencode`: instala o OpenCode V1 real 1.18.32, roda
  o install num home isolado e valida com
  `opencode debug config/agent/skill` (falha se a versão for 2.x).
- Typecheck estrito do plugin contra a API real
  `@opencode-ai/plugin@1.18.32` no CI
  (`scripts/ci/typecheck-plugin.ps1`).
- Identidade Planner/Worker do plugin resolvida por sessão (mapa `event`
  → `parentID` presente = worker).
- 11 checks de consistência (`scripts/test-package-consistency.ps1`),
  suítes V3 (`scripts/v3/run-v3-tests.ps1`) e 10 suítes de distribuição
  (`tests/distribution/run-distribution-tests.ps1`).
- Esta documentação de governança: `docs/GOVERNANCE.md`, `CHANGELOG.md`,
  `SECURITY.md`.

### Changed

- Versão do pacote: `1.0.0` (era `1.0.0-hardening`).
- Dependência do plugin: `@opencode-ai/plugin@1.18.32` (era 1.18.31).
- CI: `actions/checkout` pinado por SHA (v4.2.2); `bun@1.3.14` e
  `opencode-ai@1.18.32` pinados por versão exata.

### Removed

- Ownership do instalador sobre `autoupdate`, `skills.paths` e `plugin`:
  todas opcionais no schema V1; skills (`~/.config/opencode/skills`) e
  plugins (`~/.config/opencode/plugins`) têm auto-discovery. O usuário
  mantém controle total dessas chaves (install preserva, uninstall nunca
  remove).

### Security

- Sem segredos no repo nem no CI (só canários sintéticos como fixtures).
- Telemetria do plugin sanitizada e local; credenciais só via ambiente do
  runtime, nunca em git/logs/backups.

## Suporte de runtime

- OpenCode **V1.x** (`opencode-ai`): suportado — validado com **1.18.32**.
- OpenCode **V2** (`@opencode/cli`, comando `opencode`): suportado desde o
  programa V3.1 (render/config/permissões nativos, plugin dual-runtime) —
  validado com **2.0.18**; suporte a `experimental.policies` e lane de CI
  própria ainda pendentes (ver [Unreleased]).
- **V1 + V2 na mesma máquina**: via perfis isolados
  (`install.ps1 -Runtime Both` / `scripts/runtime/new-opencode-profile.ps1`).

Status da release **1.0.0** (histórico): V2 não suportado naquela data.
