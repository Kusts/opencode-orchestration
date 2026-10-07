# Changelog

Todos os lançamentos relevantes deste pacote são documentados aqui, no
formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/).
Versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Fase 5 v0.1.0 (2026-10-07) — Objective Continuation Kernel

- `OrchestrationObjectiveController.ps1`: next-move puro (CONTINUE/RETRY/
  REPLAN/DELEGATE/ROTATE_CONTEXT/COMPLETE), precedência fail-closed,
  COMPLETE só com stop válido, sem estado user-return; tipos estritos.
- Hook aditivo no DispatchPipeline (record-only); ac5 atualizado para a
  semântica Reuse-First (miss ok count 0 vs bare plan unavailable).
- Suites: controller 67, dispatch 202. Tester PASS; Reviewer APPROVED.

### Fase 4 v0.1.0 (2026-10-07) — Decision Provider + Jev

- `OrchestrationDecisionProvider.ps1`: Rules -> Jev (admission utilitária,
  sem veto por task-class) -> Planner escalation; envelope fechado, Jev
  nunca decide sozinho (gate local descarta overreach/model/done).
- Issue #19: model/provider-override negado (incl. `Muse`); `trivial_local`
  substituído por admission; Jev indisponível nunca bloqueia.
- Reviewer + Security: APPROVED (2 HIGH + 2 MEDIUM + SEC-01 corrigidos).
- Desvio honesto do PLAN: PlannerLoop/JevAdvisory intocados (contratos de
  segurança aprovados); wiring na Fase 5.

### Fase 3 v0.1.0 (2026-10-07) — Reuse-First obrigatório

- **Reuse query obrigatória**: PlannerLoop resolve StoreDir automaticamente
  (`cache/`, local-only) — `evidence-store-not-requested` só com lib
  ausente; falha de consulta => `unavailable` (distinguível de miss via
  `QueryError`), fail-open preservado.
- **Invalidação completa**: hit/miss/stale/provenance/criteria-drift/
  base-drift/env-drift + novo tipo `revoked`; TTL robusto em PS 5.1 e
  pwsh 7 (normalização UTC). Reviewer: APPROVED.
- Residual: hardening provenance/hash mismatch (Fase 11).

### Fase 2 v0.1.0 (2026-10-07) — Autonomy Envelope + Stop Policy

- `autonomy-policy.json`: 19 ações auto-autorizadas, 9 boundaries, 6 stop
  reasons, 6 denied (declarativo; enforcement nas Fases 5/6).
- `OrchestrationAutonomy.ps1`: funções puras fail-closed; suite 69 asserts.
- Jev validou pr_open/rerun_ci/new_session como auto. Reviewer: APPROVED.

### Fase 1 v0.1.0 (2026-10-07) — Universal Orchestration preflight migration

- **Nova taxonomia** (`SINGLE_WORKER`, `MULTI_WORKER`, `PERSISTENT_GOAL`,
  `DETERMINISTIC_FALLBACK`, `BLOCKED`): `TRIVIAL_DIRECT` removido como
  caminho operacional; `SINGLE_WORKER` retorna 1 cheap worker
  (lookup/read → explorer); `DELEGATED` renomeado para `MULTI_WORKER`;
  `PERSISTENT_GOAL` com promoção determinística (explícita + marcadores
  SPEC+PLAN com word-boundary).
- **DONE gate endurecido (review findings REV-01/SEC-01 corrigidos)**:
  compliance trivial exige `Decision=SINGLE_WORKER` + `ExecutionShape`
  + participação observada > 0; tokens `DIRECT_*` legados rejeitados
  fail-closed (`NON_COMPLIANT_DEPRECATED_DIRECT`); classes/decisões
  inválidas rejeitadas. Reviewer + Security Reviewer: APPROVED.
- Residuais: `trivial_direct` em `CapabilityAcceptance:799` /
  `OutcomeValidation:128` (harness, Fase 2 decide); typecheck TS real via CI.

### Epoch v0.1.0 (2026-10-07)

- **Novo epoch SemVer a partir de `0.1.0`** (`VERSION`: `0.1.0-dev`) —
  inicia o programa Universal Autonomous Orchestration; a tag `v1.0`
  existente é preservada como **legacy** (histórico do pacote anterior),
  sem reescrita de histórico.
- **V3/V3.1 como programas históricos** — especificações, planos e
  evidências V3/V3.1 permanecem intactos e consultáveis; o fechamento
  V3.1 (release gate PASS, 2026-10-06) abaixo é preservado sem remoção
  nem reordenação.
- **SPEC/PLAN/ADR v0.1.0 em `docs/specs/`** —
  `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md`,
  `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-PLAN.md` e
  `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-ADR.md` (autoritativos para
  o novo epoch; semântica de preflight/kernel/grants/flags inalterada
  nesta fase).
- **Fase 0 em implementação nesta branch** (`phase-0-baseline.json` em
  `evidence/v0.1.0/`) — versionamento formal + baseline conhecido;
  issues #21/#25 registradas como `to_classify` (sem alegação de
  resolução).

### Fechamento V3.1 (2026-10-06) — prova runtime-real, release gate PASS

- **Lane real de cross-session (`scripts/ci/session-real-lane-v2.ps1`, novo)** —
  test harness de evidência (não produto), mesmo padrão da lane de watchdog:
  runtime V2 **2.0.23 exato** (pin vigente), home isolado em TEMP, preflight
  P22, Job Object com `KILL_ON_JOB_CLOSE` antes do `service start`, stop
  owned + settlement, password de `service.json` nunca logada, invariante
  49374 preservada, resultados `pass-real | fail | blocked` (falta de
  infraestrutura nunca vira PASS; gates de encerramento obrigatórios).
  Resultado final (após revisão independente — rodada 2, ver abaixo):
  **3 `pass-real` (16, 17, 19) + 4 `blocked`-parciais (18, 20, 21, 22),
  0 fail**, com provas parciais ricas gravadas
  (`evidence/v3.1/runtime-reliability/session-lane-2026-10-06/`):
  RR-E2E-16 (root session fechada de verdade no meio da task; task
  persistida; nenhuma conclusão falsa; recuperação por detach+rebind),
  17 (restart real: stop→settlement→start; task byte-preservada;
  reconciliador consumiu observação REST real), 19 (restart real antes da
  ausência; ausência **provada** por probe conclusivo;
  `mark_SESSION_LOST` exige prova; ausência desconhecida nunca vira
  sucesso — controle negativo incluído), 20 (`blocked`-parcial: envelope
  do estado real → processo fresco consome kernel-side → sessão substituta
  real retoma com rebind; o consumo **PELO Planner substituto** — perna do
  `required_activation` — exige provider de modelo; tentativa de injeção
  runtime-native observada, não materializada no pin), 21
  (`blocked`-parcial: substituição de sessão real + estado/histórico
  preservados e re-lidos kernel-side; a re-leitura **PELO substituto**
  exige provider. O claim anterior "`BUDGET_WIDEN_DENIED` provado em
  runtime" foi corrigido: a lane nunca invoca start-attempt — o invariante
  é provado kernel-side nos testes do kernel).
  **RR-E2E-18 blocked-parcial**: perna "running child reattached" do plano
  §10 provada em runtime real; perna "completed child recovered" bloqueada
  sem provider de modelo (tentativa `/synthetic` gravada; perna completa
  kernel-side nos 156 asserts do reconciler, cujo contrato entregue define
  observações como caller-declared, `probed=false`).
  **RR-E2E-22 blocked-parcial**: V1 1.18.34 real em prefixo isolado,
  versão exata observada; a observação da superfície `--help` fica
  inconclusiva no ambiente bounded (hang caracterizado em 3 variantes,
  mesma classe do flake `debug config` upstream; "nada é inferido") e,
  nesse caminho fail-closed, a perna do plano fresh-session não executa
  (claim anterior de plano "consumido por processo fresco" **corrigido** —
  não executou na corrida registrada; o construtor `native_resume=false`,
  que proíbe resume falso, é provado kernel-side nos testes do reconciler);
  o turn da fresh session exige provider (operator-owned).
- **Probes V2-native em runtime real (2.0.23)** — coleta observacional
  completa (`v2-native-probes.json`): `session-permission-narrowing`
  **unsupported** na superfície `/shell` (deny de config e permissões
  por-sessão NÃO recusaram o comando marcado — fail-open observado nessa
  superfície); demais probes ambiguous honestas (modelo ausente, config de
  política específica do pin, sem arquivos de storage/snapshot/evento sem
  atividade). **Nenhum registro `exact-binary-live` foi escrito**: as 8
  features permanecem `hold-unproven` com coleta real registrada.
- **Decisão formal `runtime_grant_enforcement.v2` = HOLD (OFF)** —
  sustentada por evidência real (fail-open na superfície `/shell` do
  2.0.23 + ausência de prova exact-binary-live; RR-E2E-41 offline segue
  verde). Consulta Jev advisory (jev_decide): HOLD conf. 1.0 — tratada
  como dado, confrontada com a `activation_rule` do registry.
- **Probe HTTPS dedicado do AI Memory (real)** —
  `transport-probe-aimem-https-2026-10-06.json`: TLS 1.3 (369ms), cert
  válido até 2026-12-24, `POST /mcp` ⇒ **401 sem token** (servidor
  fail-closed), `GET /` ⇒ 404. Host sanitizado (config user-owned). Fecha o
  item que restava do transporte (round-trip MCP autenticado já provado em
  2026-10-04).
- **Wirings: provas de execução runtime-real dos componentes** —
  `evidence/v3.1/runtime-reliability/wiring-runtime-2026-10-05/`
  (referência de diretório corrigida na revisão 2):
  P31-S2 (bootstrap executado, envelope com flags vivas; **registro** no
  arranque real segue operator-owned), **P38-S2-SPAWN** (dispatch pipeline
  executado, bundle real coder/tester/reviewer, zero spawn por decisão —
  nomenclatura resolvida: *P38-S2* = wiring do chamador Jev entregue em
  `4cfb26a`; *P38-S2-SPAWN* = spawn real do despacho, record-only),
  P40-S2 (biblioteca de supersessão verde; append/enable segue decisão do
  operador), P41-S2 (produtor executado contra 2 task records reais, JSONL
  observation-only consumido pelo leitor da fatia 1). Classificação:
  CODE-COMPLETE + RUNTIME-PROVEN (componente) + ativação HOLD
  operator-owned com evidência.
- **Revisões integradas** — reviewer (8 achados, 2 HIGH) e
  security-reviewer (3 achados) devolveram CHANGES REQUIRED na lane
  inicial; todos integrados (gates de encerramento, classificador de
  ausência fail-closed, restart real no 19, perna completed honesta no 18,
  fail-closed de pin/help no 22, denylist de ambiente, sanitização de
  caminho/hosts, charset de `-V1NpmSpec`); lane re-executada após a
  integração com o resultado final acima.
- **Revisão independente rodada 2 (closure do PR)** — reviewer (6 achados:
  2 HIGH + 4 MEDIUM) e security-reviewer (2 achados: 1 MEDIUM + 1 LOW)
  devolveram CHANGES REQUIRED sobre o diff de closure; todos tratados:
  (HIGH) 20/21 realinhados aos `required_activation` do registry — a prova
  `envelope-received-by-replacement` gravava `ok=true` hardcoded mesmo sem
  injeção suportada, e a re-leitura do estado era do harness, não do
  substituto; (HIGH) claim de perna não executada no 22 removido;
  (MEDIUM) referência de diretório corrigida
  (`wiring-runtime-2026-10-05/`), claim `BUDGET_WIDEN_DENIED` reescrito
  como invariante kernel-side, handshake TLS com deadline + `finally` no
  probe HTTPS, limite do `ScenarioTimeoutSeconds` por **tempo restante**
  em cada operação pesada do cenário 22 (piso 5s, fail-closed; validado
  em execução filtrada do cenário em runtime real), denylist
  `SensitiveEnvRemove` nas chamadas npm e no
  fallback `--help` do V1; (LOW residual documentado) `mcp-post` do probe
  segue observacional por desenho. A lane foi **corrigida e re-executada**
  no runtime real (2.0.23): os artefatos em `session-lane-2026-10-06/`
  passam a refletir a classificação honesta (**3 `pass-real` + 4
  `blocked`-parcial, 0 fail**; 14/14 checks de infraestrutura ok). Os
  artefatos da rodada 1 permanecem no histórico do git (`19c4501`).
- **DE22307F classificado** — divergência user-owned do config vivo
  (pré-existente no baseline congelado, documentada em TROUBLESHOOTING),
  não-regressão, não-bloqueante (CI verde sem config vivo). Re-run
  sequencial final: PS5.1 e PS7 **50 PASS / 3 FAIL** cada — as 3 falhas em
  ambos são exatamente o grupo DE22307F; `OrchestrationE2eManifest` (254
  asserts) verde com os novos `evidence_ref`. Falhas de
  `CapabilityShadow`/`CapabilityShadowSample` observadas na primeira
  medição eram artefatos de execução PS5.1+PS7 **em paralelo** (re-run
  sequencial: verdes).
- **Smoke implícito V2 validado** — run 37380530324 (HEAD): 5/5 jobs
  verdes; o erro do smoke implícito continua **visível** (annotation) com
  `continue-on-error: true`; a lane real segue sendo o gate. Mantido
  observacional.
- **Release gate V3.1: `PASS`** — critério: todo item está (a)
  runtime-real provado, (b) HOLD explícito do desenho **com** evidência
  que o sustenta, ou (c) decisão humana/externa que o contrato permite fora
  do gate (ativação dos wirings, RR-E2E-32/33, DE22307F, provider de
  modelo do operador). **Julgamento divulgado (atualizado na revisão 2)**:
  os 4 blocked-parcial (perna completed do 18; consumo pelo Planner
  substituto do 20; re-leitura pelo substituto do 21; turn da fresh
  session do 22) dependem de provider de modelo — o desenho entregue
  sustenta o HOLD (contrato caller-declared do reconciler; fresh-session
  por construção; cadeias kernel-side de 20/21 com sessão substituta real
  e rebind) e as pernas alternativas do plano foram provadas em runtime;
  se o operador julgar essas pernas gate-blocking, o gate vira `PENDING`
  com flip dessas linhas. Resíduos são exclusivamente decisões de
  operador — ver `program-status.json#closure_2026_10_06`.

### Adicionado

- **Wiring do chamador Jev no Planner loop (P38-S2 caller wiring,
  2026-10-05, commit `4cfb26a`)** — fecha a fatia de integração do Jev no
  fluxo do Planner: quando `Test-JevAdvisoryTrigger` responde
  `should_consult=true` **e** a flag `jev_advisory` existe, o loop faz
  **uma** chamada `Invoke-JevAdvisoryCall` (tool `jev_decide`, policy e
  flags canônicos, `TurnId` por hash, pass-through opcional de `-Probe` e
  budget) e anexa `jev_advisory_result` tipado ao plan record com
  `authoritative=false` / `recommendation_only=true`. Falha em qualquer
  ramo (credencial ausente, timeout, circuito aberto, shadow, disabled) ⇒
  **fallback determinístico**, sem exceção, sem retry, sem inventar
  recommendation; o resultado nunca altera rota/decisão nem escreve `DONE`
  — a consulta acontece **após** a construção do dispatch e a não-efetividade
  é provada por comparação byte-a-byte com/sem advisory. Sanitização de
  egress (review r1/r2/r3): redação de `Authorization: Bearer` e de
  `sk-`/`token`/`secret`/`password`/`key` **antes** de qualquer corte,
  remoção do **home real** do processo (replace literal case-insensitive
  com espaços, dedupe `USERPROFILE`/`HOME`/`$HOME`, skip de drive root;
  fallback genérico consome nome com espaços) antes do cap, e `-State`
  derivado do objetivo **bruto** (o cap de 500 do record nunca fragmenta
  paths no egress); caps documentados (100k guard DoS / 600 egresso);
  contrato C1–C4 com decisão do security (paths custom = texto do
  operador, sem garantia de forma; proibido: segredo e home real,
  inteiros ou fragmentados). Testes: 21 baseline + 9 de wiring
  (T1–T7 + advisory-only/no-DONE) + NT1/NT2a/NT2b/NT3a/NT3b/NT3c de
  fronteira com auto-check de straddle e prova de mutação (ordem
  invertida falha em NT2b; strip depois do cap falha em NT3a). Suítes:
  `OrchestrationPlannerLoop` **36**, `OrchestrationJevAdvisory`
  **159/159**, `OrchestrationDispatchPipeline` **201**,
  `OrchestrationE2eManifest` **197**, `OrchestrationTaskKernel`
  **75/75**, consistency **16/16**. Flag `jev_advisory` já ATIVA desde
  2026-10-04 (nada foi ativado por esta fatia); `runtime_grant_enforcement`
  segue OFF (Phase 5).

- **Transporte HTTP real do Jev advisory (P29-S2, kernel-side)** —
  `OrchestrationJevAdvisory.ps1` ganha o probe HTTP real (`New-JevAdvisoryHttpProbe`,
  scriptblock autocontido para o envelope P28): `POST {JEV_BASE_URL}` com
  `Bearer {JEV_API_KEY}` e body `{model,state,questions}` no mapeamento exato do
  jev-mcp (`jev_check`/`jev_score`/`jev_decide`/`jev_gate`). Config user-owned
  fail-closed por env (`JEV_BASE_URL` obrigatória — ausente ⇒
  `JEV_TRANSPORT_NOT_CONFIGURED` determinístico; `JEV_MODEL` default
  `jev-latest`; só os **nomes** no registry, node `transport` com validação
  fail-closed), https obrigatório com http apenas loopback (resolver **e**
  probe), `AllowAutoRedirect=false`, cap de leitura 262144 sobre comprimento
  declarado **ou** acumulado, tokens fechados de falha
  (`jev-transport-*`) — **falha nunca vira advisory OK**: status fora de
  200-299, 401/403/5xx, JSON malformado, corpo truncado e timeout resultam em
  `JEV_UNAVAILABLE` com `fallback_continue=true` (401/403 ⇒
  `JEV_AUTH_REJECTED` no branch existente do envelope). Projeção tipada
  fechada por tool: decide ancorado na pergunta **enviada** (type igual,
  case-sensitive; `choice` restrita às criteria enviadas), gate restrito a
  `allow|confirm|block`, `usage` só numérico, `model` da API descartado;
  `OutputSummary` tipado com fallback legado byte-idêntico. Probe explícito
  do chamador continua vencendo; sem `State` ⇒ `INVALID_REQUEST` estruturado
  (wiring do Planner é a fatia P38-S2). Probe contra endpoint REAL com chave
  real segue evidência operator-owned (exact-runtime). Task kernel
  `rr-p29-jev-transport-s2b` DONE (rev 32): verification `verified_pass`,
  reviewer APPROVED r3+r4, security APPROVED r3, residuals registrados.
  Suítes: `OrchestrationJevAdvisory` **159/159** (PS 5.1 + pwsh; 73 asserts
  slice-1 preservados, insert-only), McpSafety 203/203, CapabilityFlags
  26/26, consistency 16/16. Evidência:
  `evidence/v3.1/runtime-reliability/phase29-transport-s2.json`.

- **Registry único de pins de runtime/tool** `source/registry/runtime-versions.json`
  (`runtimes.v1/v2`, `plugins.v1/v2`, `tools.bun`, campos `package`/`version`/`spec`)
  + loader fail-closed `scripts/runtime/lib/RuntimeVersions.ps1`
  (`Get-OrchestrationRuntimeVersion -Name v1|v2|plugin_v1|plugin_v2|bun`; resolve o
  repo root pela própria localização, funciona de qualquer cwd; **sem fallback para
  literal** — registry ausente/ilegível/JSON inválido/entrada vazia ou `spec`
  divergente de `package@version` ⇒ `throw` com motivo). Bump de versão passa a ser
  edição de **um** arquivo (+ re-validação no runtime exato).

### Changed

- **Teto anti-hang do job `ps51` no CI elevado de 50m para 60m**
  (2026-10-05, commit `2c4a7cb`): o run `37366406568` estourou *"The job
  has exceeded the maximum execution time of 50m0s"* com a suíte V3 em
  PS 5.1 em runner lento (o job `ps7`, idêntico, passou em 21m55s no mesmo
  push). Bump **defensivo** do teto; nenhum step, ordem ou timeout de step
  foi alterado.

- **Contaminação do working tree quebrava o RR-E2E-04 no CI**
  (`COMPLETION_GATE_FAILED`) — *root cause*: o job `ci-smoke-opencode-v2` roda
  `smoke-opencode-v2-lifecycle.ps1` **antes** da lane real, e esse smoke gravava
  por default em `evidence/v3.1/kernel-hardening/v2-ci-smoke-lifecycle.json`
  (+ sidecar `.cleanup.json`), arquivos **TRACKED**. A modificação ficava fora dos
  write scopes do cenário 04, então `Test-OrchestrationWriteScope` respondia com
  paths fora de escopo, o verificador allowlisted era pulado
  (`skipped-out-of-scope`), `verified_pass=false` e o kernel recusava o
  `complete` do gate de DONE. *Correção*: (1) a evidência do smoke de lifecycle
  passou a ser **efêmera por default**, fora do checkout
  (`$RUNNER_TEMP\oo-v2lifecycle-evidence\...`, com `$env:TEMP` e
  `[IO.Path]::GetTempPath()` como fallbacks); `-EvidencePath` explícito continua
  vencendo para quem quiser coletar evidência persistente no repo, e nenhum
  outro comportamento do smoke mudou (gates, Job Object, ciclo de vida, exit
  codes); (2) a lane real ganhou o gate **inicial**
  `clean_tree_within_lane_scopes`, fail-closed, que reusa
  `Test-OrchestrationWriteScope` com **os mesmos** write scopes do cenário 04
  (untracked contando, como o verificador) e bloqueia **antes de qualquer
  cenário**, listando no artefato os paths contaminantes, quando um step anterior
  suja o checkout — ou quando o scope check não é comprovável. A lista de write
  scopes virou variável única (`$script:laneWriteScopes`) consumida pelo gate e
  pelo cenário 04, sem mudança de contrato no cenário; nada de retry, nada de
  assertion removida, **write scopes não ampliados** e **nenhuma action nova no
  workflow** (steps, ordem e timeouts intactos).
- Consumidores passaram a ler o pin do registry (override explícito por parâmetro
  preservado: `-OpenCodeSpec`/`-ExpectedVersion`): smokes `smoke-opencode.ps1`,
  `smoke-opencode-v2.ps1`, `smoke-opencode-v2-lifecycle.ps1`,
  `watchdog-real-lane-v2.ps1`, `typecheck-plugin.ps1` (`plugin_v1`/`plugin_v2`),
  `spike-v2-permissions.ps1` (gate de versão exata), `RuntimeAdapters.ps1`
  (`plugin_dependency_spec`/`PluginDependencySpec`) e
  `New-OrchestrationProfile.ps1` (spec de provisionamento e pin do wrapper gerado).
  `RuntimePortPreflight.ps1` permanece **standalone** (é copiada para os perfis):
  perdeu o default `'2.0.18'` de `-ExpectedVersion` e agora **recusa valor vazio**
  (fail-closed), com mensagem genérica e sem pin literal.
- Pins atuais refletem o uso real: **V2 = `@opencode/cli@2.0.23`**, **V1 =
  `opencode-ai@1.18.34`**, plugins `@opencode-ai/plugin@1.18.34` /
  `@opencode/plugin@2.0.23` (versões confirmadas no npm em 2026-10-05),
  `bun@1.3.14` (mantido). `.github/workflows/ci.yml` resolve os pins do registry
  (`GITHUB_ENV`: `V1_SPEC`, `V2_SPEC`, `PLUGIN_V1_SPEC`, `PLUGIN_V2_SPEC`,
  `BUN_VERSION`) e instala por eles — nenhuma versão de pacote digitada no workflow.
- **Registros históricos de evidência permanecem intactos** (`2.0.18`/`1.18.32` em
  `evidence/`, `source/registry/runtimes.json` e notas datadas que citam o binário
  histórico continuam citando-o como histórico). Sem reescrita de histórico.
- Testes alinhados ao registry (asserts de spec e de binário real sem literal);
  fixtures sintéticas de versão continuam intactas e, com o host local em `2.0.18`,
  os pontos que exigem o pin `2.0.23` seguem como **SKIP honesto** (nunca FAIL).

Programa **V3.1 — Dual-Runtime Kernel Hardening** em andamento
(especificação e plano em `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-*`).
Fases 0–4, 6–7 (dual-runtime) e 9–19 (Task Kernel) **implementadas, revisadas
(Reviewer + Security Reviewer) e corrigidas**; Phase 5 entrega só o harness
(enforcement comportamental V2 pendente), Phase 8 tem o smoke de binário V2
wired no job `ci-smoke-opencode-v2` via lifecycle explícito do serviço
gerenciado (padrão P22; **3/3 PASS local** em 2026-10-03 e **PASS no
runner** em 2026-10-04 — GitHub Actions run 37193122170; smoke implícito
segue flaky upstream); evidência completa em
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
  real **executado no runner em 2026-10-04** (run 37193122170: PASS do
  ciclo com atribuição comprovada no start; serviço encerrou antes do
  fechamento — backstop não exercitado sob carga); (c) wiring do job no
  **enforcement** do watchdog = follow-up (P26 segue
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
    TRIGGER-FIX com 4 findings corrigidos. Follow-up 2026-10-04: o JSONL
   de evidência do live-hook (`phase24-livehook.jsonl`) é **reescrito a
   cada execução da suite** (cópia sanitizada do run) e passou a ser
   **untracked** (estado local de runtime; o snapshot histórico de 8
   linhas de 2026-10-01 permanece atestado em `phase24.json` e
   `docs/ARCHITECTURE.md`).
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
  `watchdog{enabled:false, shadow:true}` **inalterada** *[estado da fatia;
  ATUALIZADO 2026-10-04: o operador ativou a flag
  (`{enabled:true,shadow:false}`, `cca566f`) e em 2026-10-05 o enforcement
  passou a consumir o Job Object — ver bullets próprios. O registro sem
  binding em ENFORCE mantém o HOLD honesto (`WATCHDOG_ENFORCEMENT_
  NOT_IMPLEMENTED` como token dessa condição, não da flag)]*; registro sem
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
  do plan §6.1) *[estado da fatia; ATUALIZADO 2026-10-04: flag ATIVA
  `{enabled:true,shadow:false}` — `68a977b`/`cca566f`; transporte real em
  P29-S2 e wiring do chamador em P38-S2 entregues em 2026-10-05, ver
  bullets no topo]*; policy canônica com tool set fechado
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
  config) segue flaky upstream e fora deste path; o passo roda no job CI e
  deu **PASS no runner** em 2026-10-04 (run 37193122170).
- **Fix CI CHECK 16 (2026-10-04)** — `.gitattributes` passa a marcar
  `plugins/dist/**` como `-text`: o sidecar `.sha256` verifica os bytes do
  blob, e a tradução de EOL no checkout do runner (autocrlf) quebrava o
  hash em CI (15/16) apesar de 16/16 local. Sem mudança de conteúdo no
  bundle.
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
por fase** (HOLDs registrados). **Estado atual das flags** (fonte
canônica `source/registry/capability-flags.json`): **ATIVAS** por decisão
do operador com evidência — `runtime_support.v1/v2/dual_profile`,
`task_kernel`, `bounded_execution`, `watchdog`, `jev_advisory` e
`worktree_isolation` (lote de 2026-10-04, ver bullets acima;
`capability_registry.enabled=true` é pré-existente do V3);
**OFF/shadow** — `capability_router.shadow/active`, `skill_routing`,
`mcp_routing`, `adaptive_ranking`, `routing_telemetry`,
`capability_reconciler` e `runtime_grant_enforcement{v1,v2}` (doutrina
Phase 5: nenhum hard-deny antes da validação comportamental no runtime
V2 real). A frase original desta seção ("todas as flags de rollout seguem
OFF/shadow") descrevia o estado até 2026-10-04 e foi substituída pelo
estado vivo; nenhuma flag de rollout **nova** foi criada além de
`jev_advisory` (P29, com sanção explícita do plan addendum §6.1);
roteamento MCP genérico segue desligado; critérios `PAE-01`–`PAE-40`
rastreados na matriz
`evidence/v3.1/runtime-reliability/pae-traceability.json`, pendentes
de evidência do operador onde marcados `activation-pending`/
`blocked-operator-evidence`. Programa **não** concluído (release gate
pendente do operador).

### Added

- **Suporte dual-runtime**: OpenCode **V1** (pacote npm `opencode-ai`) e
  OpenCode **V2** (pacote `@opencode/cli`), ambos com comando `opencode`.
  Os pins exatos são lidos do **registry canônico**
  `source/registry/runtime-versions.json` (loader fail-closed
  `scripts/runtime/lib/RuntimeVersions.ps1`) — este changelog não fixa
  números; `1.18.32`/`2.0.18` abaixo são os pins do congelamento
  histórico e da evidência que os citam.
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
    sanitizada; flags de rollout conservadoras por **política** (nascem
    OFF/shadow; ativação é decisão humana com evidência — nesse
    congelamento `task_kernel` desligado+shadow, `worktree_isolation` e
    `runtime_grant_enforcement` desligados, `runtime_support.v2` off até
    ativação com evidência; **estado vigente**: ver
    `source/registry/capability-flags.json` e o lote de 2026-10-04).
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
  **PASS no runner em 2026-10-04** (run 37193122170); o smoke implícito
  falhou no runner (flaky upstream conhecido).

- **jev_advisory ativada (2026-10-04, decisão do operador)** — primeiro
  rollout flag do V3.1 a sair de OFF: `enabled:true, shadow:false`;
  consultas advisory reais pelo envelope P28 (30s, circuito 2/300s,
  telemetria sanitizada) com autoridade **sempre não-autoritativa**
  (guard sempre-nega: deny do kernel vence, falha do verifier vence
  "complete"; Jev nunca concede/widening/modelo/DONE — estrutural).
  Guardas atualizadas para o novo estado canônico (CapabilityFlags,
  McpSafety AC10, JevAdvisory R1/T-active/R6, bootstrap w1e); bateria
  verde nas duas engines (22/22, 73/73, 16/16, 43/43, 203/203,
  consistência 16/16); transporte real provado (jev_check 831ms via
  MCP). Reviewer + Security APPROVED. skill_routing/mcp_routing/
  adaptive_ranking permanecem OFF (doutrina); demais flags seguem
  conservadoras.

- **Lote de ativação de flags (2026-10-04, decisão do operador)** —
  `watchdog{enabled:true,shadow:false}` (enforcement real P26-S1),
  `task_kernel{enabled:true,shadow:false}`
  (DONE só via kernel, 75/75), `bounded_execution{enabled:true}`
  (budgets 45m/90m), `worktree_isolation{enabled:true}`,
  `runtime_support.v2/dual_profile:true`. Bateria verde nas duas
  engines para as suítes afetadas pela ativação (25/25 guarda,
  134/134, 339/339, consistência 16/16); kernel 75/75 no PS5.1 e
  ownership 56/56 no PS5.1 — no pwsh, kernel 74/75 e ownership 52/56
  por `ownership_conflict` **pré-existente documentado** (a suíte usa
  fixtures próprias de flags; não atribuível à ativação). Guardas
  exigem o novo estado exato (drift qualquer lado falha), incluindo
  `bounded_execution.shadow==false`. **Contrato honesto do watchdog
  ativado**: supervisão kernel-side only; a captura da árvore é por
  snapshot CIM — descendente criado após o snapshot pode escapar
  (wiring de Job Objects no enforcement = follow-up; a contenção por
  job hoje cobre o spawn do smoke lifecycle, não o enforcement);
  identidade exata, caps fail-closed e recusa de PIDs
  desconhecidos/49374 inalterados.
  `runtime_grant_enforcement{v1,v2}` **permanece OFF** (Phase 5:
  nenhum hard-deny antes da validação comportamental);
  skill_routing/mcp_routing/adaptive_ranking OFF (doutrina).

- **Wiring de Job Objects no enforcement do watchdog (Tarefa 5a, contrato
  A, 2026-10-05)** — decisão de contrato fechada (consulta Jev consultiva;
  alternativa token-crossing do spawner descartada: o "spawner" de
  produção é o runtime, não código kernel). Job anônimo
  `-NoKillOnClose` criado **após** os gates de identidade/ownership e
  atribuído à raiz verificada **antes** do snapshot (novo seam
  `Attach-RuntimeJobVerifiedProcess` na lib P22: handle caller-proven com
  identidade re-verificada, nunca `OpenProcess` por PID, recusa
  host-self; `Add-RuntimeJobProcess` original intacto). Kill CIM de
  descendentes verificados seguido de `TerminateJobObject` **backstop** —
  fecha o escape documentado de descendente pós-snapshot (qualquer filho
  nascido pós-attach é membro). Revalidação de deadline **imediatamente
  antes** do ato letal (expirado ⇒ skip + close inerte +
  `job_skip='deadline-expired'`); attach recusado ⇒ fallback CIM-only
  fail-closed com `job_attach=refused:*` (settlement byte-idêntico ao
  caminho sem job, JOB44); decisão terminal separa **ato letal aplicado**
  (booleano `-LethalApplied`) de **contagem de mortos** (só contador CIM;
  `job_members_reduction` é observação sem causalidade — kills CIM
  assíncronos entram no delta). Testes adversariais JOB43 (escape
  fechado, tardio fora do snapshot morto) + JOB46 (controle negativo:
  attach recusado ⇒ tardio **sobrevive** — discriminante provado) +
  JOB47 (deadline expira entre CIM e backstop ⇒ nenhum Terminate, tardio
  vivo, PENDING nunca terminal) + JOB48 (raiz sai pós-snapshot ⇒
  `interrupted=true` sem REFUSED falso). **HOLDs residuais honestos**:
  janela gate→`TerminateJobObject` (API nativa sem deadline), preempção
  entre checagem e chamada, descendentes pré-attach cobertos só pelo kill
  CIM, dependência opcional da lib (ausente ⇒ `refused:job-lib-unavailable`).
  Suítes nas duas engines: enforcement **421/421** (era 339), job-object
  **132/132** (era 113), watchdog **134/134** intacto, consistência
  **16/16**. Reviewer **APPROVED** (3 rodadas) + Security **APPROVED**
  (3 rodadas; r1: 2 HIGH — ato letal pós-deadline e kills do job fora da
  decisão terminal — corrigidos e provados).
- **Lane real RR-E2E-04..10 (Tarefa 3, 2026-10-05)** — novo harness
  `scripts/ci/watchdog-real-lane-v2.ps1` (padrão lifecycle-smoke): gate
  de binário exato 2.0.18, home isolado TEMP, ciclo de vida explícito do
  serviço (set/start/status/stop owned, **49374 intocado** antes/depois),
  spawns próprios contidos por Job Object, ambiente mínimo nos workers,
  tasks reais do kernel (`task-kernel.ps1`; flag `task_kernel` ativa),
  workers = processos reais com comportamento controlado, **1 tentativa
  por cenário**, deadlines curtos fornecidos pelo chamador (budgets
  `BUDGET_IMMUTABLE` do kernel intocados). Resultado final (execução 3,
  árvore limpa): **7/7 `pass-real`** — 04 completion normal com terminal
  DONE real do kernel (verifier allowlisted in-scope), 05 HARD_TIMEOUT,
  06 NO_PROGRESS, 07 REPEATED_ACTION, 08 REPEATED_CYCLE, 09 interrupt
  real + não-settlement injetado via seam test-only documentado (rotulo
  explícito na evidência; decisão de contrato Jev X), 10 sibling ileso
  com hang morto. Wired no job `ci-smoke-opencode-v2` após o smoke de
  lifecycle (passo 10 min; job 15→25 min; vermelho honesto, sem
  continue-on-error **na lane** — o smoke implícito do mesmo job passou a
  ser observação com `continue-on-error: true` depois, ver *Fixed*;
  lane 7/7 `pass-real` verde no runner em 2026-10-05, run
  `37376248759`). Evidência: `evidence/v3.1/runtime-reliability/
  v2-lane-2026-10-04/` (lane-summary `no_fake_close:true`; log de
  diagnóstico com as 3 execuções). Classificações do registry
  **inalteradas** (descrevem o que a prova exige; a lane forneceu a
  execução real). Seguem fora do escopo desta lane, honestos:
  RR-E2E-01..03 (portas — lane 2026-10-03), RR-E2E-16..22 (sessão real +
  restart), RR-E2E-32 (flag, decisão do operador).

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
  `debugcfg-hang-investigation.json`); os cenários de **watchdog
  RR-E2E-04..10 foram convertidos para evidência real em 2026-10-05**
  (lane dedicada, 7/7 pass-real — ver bullet próprio acima) e os cenários
  de sessão/restart (16..22) continuam exigindo integração de sessão
  real; evidência em
  `evidence/v3.1/runtime-reliability/v2-lane-2026-10-03/` e
  `evidence/v3.1/runtime-reliability/v2-lane-2026-10-04/` — o **re-run em
  runner limpo foi OBSERVADO em 2026-10-05** (run `37376248759`, push
  `4cfb26a`): step `Smoke lifecycle explicito` verde e step `Lane real
  dos cenarios RR-E2E-04..10` verde, 7/7 `pass-real` **no runner**; o
  `COMPLETION_GATE_FAILED` anterior era contaminação do checkout (fix
  `7b527d8`, ver *Fixed*). No mesmo run o step final `Smoke test with
  real OpenCode V2` (smoke implícito) falhou com `debug config: TIMEOUT
  30s` — flake upstream documentado
  (`debugcfg-hang-investigation.json`), formalizado como observação
  `continue-on-error: true`; portanto o job V2 **não é "totalmente
  verde"**, ele carrega um probe observacional), config
  user-owned local do endpoint de AI Memory **remota já em PROD** (deploy
  do VPS de AI Memory executado pelo operador; a config user-owned foi
  **confirmada em 2026-10-04** e o round-trip remoto autenticado
  comprovado em `aimem-health-repreflight-2026-10-04.json`; resta apenas
  o probe HTTPS dedicado, separado do round-trip MCP, e nenhuma
  identidade do servidor no repo) e o re-preflight de porta P22,
  **evidência V2-native no pin
  vigente** (o gating P40 exige `exact-binary-live` do binário do pin
  atual; as 8 features seguem `hold-unproven`) e probes reais contra
  endpoint real (JEV com chave real é operator-owned). **Fechados desde
  2026-10-04 e portanto fora desta lista**: ativações de flag com
  evidência, `jevgrep` real (instalado + consult semântico; o flip de
  policy `platform_support.windows=true` e as asserts do doctor já estão
  na base — resta só probe real contra endpoint real, já listado acima) e
  a config + o round-trip do AI Memory; **fechado em 2026-10-05**: a lane
  RR-E2E-04..10 no runner e o wiring do
  chamador Jev no Planner loop (P38-S2) — restam os wirings de P31-S2
  (registro no arranque real), P38-S2 (spawn real do despacho, record-only
  por decisão), P41-S2 (produtor em produção) e P40-S2 (append/enable,
  decisão do operador).
  Checklist em `evidence/v3.1/runtime-reliability/phase42.json`;
  estado por fase em `program-status.json`; rastreio por critério em
  `pae-traceability.json`.
- **HOLDs estruturais mantidos em P22–P41** — (d) `execute.before` sem
  via sem-modelo provada; evento `session.updated` não observado;
  `REUSE` de porta em produção; reconciler V2 nativo; interrupt de
  sessão V2 nativa; janela create→assign do job (spawn path do smoke) e
  janelas residuais do backstop no enforcement (gate→terminate nativo e
  preempção — documentadas; wiring **entregue** em 2026-10-05, ver
  bullet próprio). `program-status.json` mantém o detalhamento por fase.
- **Phase 5 (comportamental)** — validar precedência de regras ordenadas,
  saved approvals e `experimental.policies` contra o runtime V2 real
  (requer resolver o travamento do `debug` V2; evidência de runner existe
  desde 2026-10-04 — o caminho de lifecycle é estável, o implícito segue
  flaky)). Nenhum hard-deny é shipado antes disso.
- **Phase 8 (smoke V2 em CI)** — instalação oficial do V2 no Windows
  (spec resolvida do registry `source/registry/runtime-versions.json`; a
  prova local de 2026-10-03/04 usou o pin histórico `@opencode/cli@2.0.18`)
  provada localmente e
  smoke de lifecycle wired no job `ci-smoke-opencode-v2`; **executado no
  runner em 2026-10-04 com PASS** (run 37193122170); o flakiness upstream
  do `debug config` permanece (flake documentado em
  `debugcfg-hang-investigation.json`) e o smoke implícito foi formalizado
  como **observação com `continue-on-error: true`** (HOLD explícito: a
  falha continua visível em log/anotação, mas não derruba o gate).
- **Ativação** — em 2026-10-04 o operador ativou `watchdog`/
  `task_kernel`/`bounded_execution`/`worktree_isolation`/
  `runtime_support.v2`+`dual_profile`/`jev_advisory` (commit `cca566f`,
  guards atualizados, holds honestos registrados em
  `evidence/v3.1/runtime-reliability/flag-activation-batch-2026-10-04.json`);
  `runtime_grant_enforcement{v1,v2}` permanece OFF (doctrine Phase 5:
  nenhum hard-deny antes de validação comportamental no runtime V2 real);
  `skill_routing`/`mcp_routing`/`adaptive_ranking` permanecem OFF
  (doutrina). Ativação continua sendo decisão humana com evidência
  (shadow rollout, Phase 19).

### Fixed

- **4 suítes alinhadas às flags ativadas (2026-10-04, batch `cca566f`)** —
  `OrchestrationExecutionBudget`, `OrchestrationV2NativeGating`,
  `OrchestrationV2EvidenceSupersession` e `OrchestrationE2eManifest` ainda
  afirmavam o estado anterior ao batch (`bounded_execution`/`watchdog`/
  `runtime_support.v2` OFF) e quebravam no runner. Mesma doutrina do commit
  `cca566f`: os asserts de **estado** passam a afirmar o estado exato e
  atual (drift para qualquer lado falha) e os asserts de **invariante** foram
  preservados, provados em fixture com registry **controlado** (toda ativação
  OFF) em vez de leitura do registry vivo — nenhum invariante foi removido e o
  total de asserts subiu.

- **RR-E2E-04 no runner: `COMPLETION_GATE_FAILED` por contaminação do
  checkout (2026-10-05, commit `7b527d8`)** — causa-raiz e correção estão
  descritas em *Changed* acima (evidência do lifecycle smoke passou a ser
  efêmera em `RUNNER_TEMP`/`TEMP`/`GetTempPath()` e a lane real ganhou o
  gate fail-closed `clean_tree_within_lane_scopes` antes de qualquer
  cenário). Nenhum scope foi ampliado, nenhuma assertion removida, nenhum
  retry e nenhuma action nova no workflow. **Estado atual desta
  pendência**: FECHADA — o re-run em runner limpo foi observado no run
  `37376248759` (2026-10-05, push `4cfb26a`): `Smoke lifecycle explicito`
  e `Lane real dos cenarios RR-E2E-04..10` verdes, 7/7 `pass-real` no
  runner; os outros 4 jobs (ps51 com o teto novo de 60m, ps7, lane v2,
  smoke v1) passaram. A única falha do job `ci-smoke-opencode-v2` foi o
  step final `Smoke test with real OpenCode V2` (smoke implícito) com
  `debug config: TIMEOUT 30s` — flake upstream, tratado abaixo.

- **Smoke implícito (`debug config`) do job `ci-smoke-opencode-v2` vira
  observação (2026-10-05, commit "ci: smoke implicito V2 vira
  observacional")** — o step `Smoke test with real OpenCode V2` passou a
  rodar com `continue-on-error: true`, formalizando o HOLD explícito da
  Etapa I: a intermitência do `debug config` é flake **upstream** do
  binário (7 hangs vs 5 passes no mesmo dia/binário/máquina —
  `debugcfg-hang-investigation.json`; stdin, conteúdo da config e estado
  do serviço refutados como gatilho determinístico), não regressão deste
  pacote. A falha continua **visível** em log e anotação do run — só não
  derruba mais o gate. Nenhum outro step, ordem, timeout, escopo ou
  verificador foi alterado, e a prova do caminho estável segue sendo o
  smoke de lifecycle explícito + a lane real RR-E2E-04..10 (verde no
  runner em 2026-10-05). **Não descrever o CI como "totalmente verde"**:
  o job V2 segue carregando esse probe observacional.

### Known issues (pré-existentes, dependentes de ambiente)

- **V3 suite em runner limpo (2026-10-04, primeira execução em CI da
  história — o CHECK 16 a bloqueava)**: causa-raiz corrigida por causa, não por
  atribuição ambiental (run `37206287499`):
  - **PRECHECK exit 3 (`models.jsonc` ausente)** — o arquivo é gerado e
    gitignored, então checkout limpo não o traz, e o precheck do installer
    exige a presença dele no repo — isso derrubava as suítes
    `Installer -Runtime V2
    -WhatIf`, `perfil v2/wrapper não criado` e as de runtime-adapters. **Fix:**
    bootstrap idêntico ao precedente do runner de distribution
    (`tests/distribution/run-distribution-tests.ps1`, run `36083266782`) em
    `scripts/v3/run-v3-tests.ps1` — cria o arquivo a partir de
    `models.example.jsonc` **só quando ausente**, com criação **exclusiva à
    prova de corrida** (`[IO.File]::Copy` com `overwrite=$false`): um
    `models.jsonc` existente — ou que surja entre o check e a cópia — nunca é
    sobrescrito e é preservado; sem o example, `RUNNER FAILED` + exit 2. Não é
    dependência do ambiente do operador nem das ativações de flag.
  - **TIMEOUT 300s em `runtime-port-preflight` e `-wrapper`** — a causa real
    não é o `Remove-Item -Recurse` do `finally`: com o `finally` instrumentado
    ele nunca chega a ser executado. O processo morre na remoção **inline** da
    junction, o statement logo após o último PASS (`FINAL: PAI helper…` /
    `w14: marker de ausência…`): `Remove-Item -LiteralPath <junction> -Force`
    num alvo com filhos **trava** sob console oculto com saída redirecionada
    (`ShouldContinue` sem resposta; `-ErrorAction` não suprime). Medido em
    PS 5.1: hang > 60s contra 4ms de `[IO.Directory]::Delete(path, $false)`,
    que remove só o reparse point, sem seguir o alvo e sem prompt. **Fix:**
    helper `Remove-TestReparse` nos dois harnesses, nos 4 sites inline, mais um
    sweep de reparse points antes do `Remove-Item -Recurse` do `finally`
    (remanescente cai no sweep).
  - **`clean-env PATH`** — o filho `Get-ChildItem Env:` sob `-CleanEnvironment`
    não produziu saída alguma no runner: `rc=-1` significa `timedOut=true`
    (budget de 30s), não filho quebrado. **Fix:** budget 120s + `TimedOut`/
    `ElapsedMs` no detalhe dos asserts (diagnóstico futuro). Sem mudança de
    allowlist em `SpikeProcess.ps1` e sem mudança nas condições asseridas.

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
