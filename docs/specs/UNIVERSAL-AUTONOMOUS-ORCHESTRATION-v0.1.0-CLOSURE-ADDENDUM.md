# Universal Autonomous Orchestration v0.1.0 — Closure Addendum (v0.1.1 corretiva)

Data: 2026-10-08. HEAD inicial `b945d40ce0` (master, merge PR #34). Branch: `closure/v0.1.1-job44-stable-core`.
CI de referência: master push `37709923028` FAIL (ps51, 1 assertion); PR `37707618318` SUCCESS.
Veredito desta rodada: **PARTIAL CLOSURE** (CI pós-merge corrigida + gaps mapeados; wiring produtivo permanece HOLD honesto).

## 1. Estado inicial
- `VERSION=0.1.0`, tag `v0.1.0` → `2daa6af` (anterior ao merge final `b945d40`). Não reescrever tag publicada.
- PR #34 merged; CI do PR verde; CI da master após merge vermelha em `OrchestrationRuntimeWatchdogEnforcement.tests.ps1` cenário JOB44.
- Issues abertas relevantes: #1, #6, #8/#9/#10, #16, #19, #21, #25, #30 (nenhuma fechada nesta rodada por falta de prova completa).

## 2. Auditoria produtiva — matriz IMPLEMENTED → WIRED → ACTIVE → RUNTIME-PROVEN
| Componente | Estágio | Nota |
|---|---|---|
| Preflight | RUNTIME-PROVEN | CLI + DONE gate, usado por policy/lanes |
| PlannerLoop | ACTIVE (lib) / parcial | planning-only, never dispatches; único caller Jev P38-S2 advisory-only |
| DispatchPipeline | ACTIVE (lib) / parcial | consome plan record; record-only (`spawned=false`); não faz spawn |
| ObjectiveController | ACTIVE como cálculo | função pura `next_move`; não loopea/não executa |
| ObjectiveRunner.harness | TEST HARNESS — NOT PRODUCT | único loop que itera (bounded 20, outcomes sintéticos) |
| DecisionProvider | NÃO-CONECTADO / test-only | seam `-JevProbe`; não toca Loop/JevAdvisory |
| JevAdvisory | ADVISORY-ONLY | flag born-OFF/shadow; transporte env user-owned fail-closed; nunca roteia/concede/DONE |
| EvidenceStore | ACTIVE / provado em lanes | reuse automático no PlannerLoop; TTL só se condição presente (risco reuse indefinido sem ttl) |
| GoalPromotion | SCORE-ONLY, NÃO-CONECTADO | só pontua; wiring pertence a fase posterior |
| GoalKernel | ACTIVE (lib) | CRUD+CAS, store `cache/goal-store`; provado em harness/testes |
| GoalProgress | SCORE-ONLY | delta/estagnação; loop-guard posterior |
| GoalCheckpoint | IMPLEMENTED (store atômico) | consumido pelo harness; nunca toca sessões reais |
| SessionReconciler | READ-ONLY/ADVISORY | nunca proba/controla sessões; V2 probing HOLD |
| TaskKernel | RUNTIME-PROVEN (mais forte) | CAS+lock, DONE só via `Complete-OrchestrationTask`; provado em lanes reais |
| Delivery | DECISÓRIO-ONLY | elegibilidade + state machine; merge/checks com chamador externo |
| Enforcement plugin/adapters V1/V2 | gates kernel+flags+watchdog; adapters = doutrina/policy | sem plugin dedicado; executor vivo é o Planner (caller manual) |
| `runtime_grant_enforcement.v1/v2` | OFF (HOLD Phase 5, fail-open `/shell` 2.0.23) | autorização declarada sem deny runtime; DONE não falsificável pelo worker (gate kernel) |

Contrato `TASK_DONE≠OBJECTIVE_DONE` (SPEC INV-006) existe como texto de plano/contrato; **nenhum loop produtivo consome CONTINUE/RETRY/REPLAN até COMPLETE fora do harness**.

## 3. Causas-raiz
- **JOB44 (Fase F):** `Get-EnforceSettlementShape` era denylist só de `job_*` e concatenava resto `k=v;`. Campos voláteis de observação (`tree_excluded`/`exclusion` do snapshot CIM, `telemetry_file`/`telemetry_written` do writer) divergiram entre runs sequenciais (attach 2 vs refused 0, CI ps51 2026-10-08) sem mudança no que foi morto. Segurança preservada nos asserts per-run (child killed, sentinel intact, refused sem job kill). Não é regressão do fallback CIM-only; é asserção excessivamente estrita sobre observação ambiental nondeterminística. JOB46 passou no mesmo run, confirmando nondeterminismo ambiental.
- **Gaps B/C:** Controller puro + Dispatch record-only + PlannerLoop planning-only + Promotion score-only por construção (fases entregaram libs + harness S1-S8, não executor vivo). SPEC prometeu continuação produtiva e auto-promotion (SPEC §9-15, PLAN Fase 5, ADR GoalLoop event-driven); executor concreto (caller produtivo do Planner em safe boundaries) nunca foi especificado — sem daemon como requisito, mas sem ownership/idempotência/budget verificáveis.
- **D:** DecisionProvider sem transporte real (só `-JevProbe`); JevAdvisory é a camada com probe real mas advisory-only e single-caller. Reuse funciona no PlannerLoop, mas persistência depende de `store_dir` do caller e TTL condicional.
- **E:** Envelope/Stop declarativos; `auto_authorized` amplo sem deny runtime enquanto enforcement for HOLD. Issue #19 permanece aberta.

## 4. Alterações executadas (esta rodada)
- Só `scripts/v3/lib/OrchestrationRuntimeWatchdogEnforcement.tests.ps1`: `Get-EnforceSettlementShape` vira allowlist do núcleo estável (`engaged/interrupted/settlement/classification`); `job_*` segue fora como diferença intencional; `tree_excluded/exclusion/telemetry_file/telemetry_written` fora como observações voláteis documentadas; asserts JOB44/JOB46 renomeados para "stable settlement core identical" + comentários atualizados. Nenhum produtivo, deny, flag ou verifier tocado.
- Validação: `run-v3-tests -Name *Enforcement*` 421/421 fail 0 (184s); `*RuntimeWatchdog.tests*` 134/134; `git diff --check` limpo; `git diff --stat` 1 arquivo. Full 74 suites não rodada (tempo); declarado como residual.
- Review independente: ** indisponível nesta rodada (limite de subagents atingido após 6 delegações: 3 explorers + coder + architect + tester)**. Planner executou review determinístico direto (diff + guards JOB45/46 + grep taskkill/49374). Residual registrado; re-review independente recomendado antes do merge final.

## 5. Diferenças em relação ao PLAN
- PLAN previa harness S1-S8 como fechamento de Fase 15; confirmado como parcial/test-only, não produto.
- Correção JOB44 estreita o comparador cross-run em vez de fixar fixture temporal — decisão documentada: contagem ambiental não é decisão de settlement; segurança segue pinada per-run.

## 6. Segurança
- Nenhum taskkill nas libs; enforcement nunca toca 49374; PID desconhecido recusa sem engajar job; job não amplia autoridade; DONE só via kernel com verification allowlisted. `runtime_grant_enforcement` permanece HOLD explícito com mitigação (gates kernel + watchdog + review). Não ativar flag sem prova runtime-real.

## 7. Testes e provas runtime-real
- Provas executadas: Enforcement isolada + Watchdog base (ambientes Windows PS5.1 local). Golden Workflows e cenários Cenário 1-5 com OpenCode real **não executados nesta rodada** (tempo/orçamento sessão + limite subagents); gates permanecem abertos.
- CI: aguardando run do PR desta branch; critério é verde no HEAD final, não só no PR anterior.

## 8. Issues e versionamento
- Nenhuma issue fechada; #19/#16/#21/#25/#30/#6/#1/#8/#9/#10 reconciliadas como implementadas-parcialmente ou bloqueadas por runtime, nunca como concluídas sem prova.
- Tag `v0.1.0` intocada. Se CI verde + re-review independente aprovar, preparar release corretiva `v0.1.1` (SemVer patch, só fix de teste + addendum).

## 9. Residuais (gates abertos)
1. Re-review independente (reviewer + security-reviewer) da mudança JOB44.
2. Full `run-v3-tests` (74 suites) + distribution + CI verde no HEAD final.
3. Executor produtivo mínimo (opção B do architect): caller do Planner em safe boundaries, ownership CAS por Goal, idempotência (intenção antes do dispatch, chave estável), hard budget persistido + watchdog, ciclo promoção→Goal→TaskKernel→dispatch real→barrier→evidência verificada→progress→checkpoint→next_move, DONE só via kernel. Sem isso, auto-promotion/continuação/checkpoint-resume seguem HOLD.
4. `ttl` default na produção de evidências; padronizar `store_dir` default em operação real; decidir wiring DecisionProvider vs JevAdvisory (uma autoridade consultiva).
5. Cenários runtime-real 1-5 com OpenCode instalado; `runtime_grant_enforcement` segue HOLD até prova exact-binary-live.

## 10. Veredito
**PARTIAL CLOSURE**: CI pós-merge endereçada com causa-raiz e fix validado isoladamente; matriz honesta IMPLEMENTED→RUNTIME-PROVEN produzida; wiring produtivo e auto-promotion documentados como HOLD (não alegar FINAL). Próximo passo: re-review + CI verde + decisão operador sobre executor mínimo (B) ou manter HOLD com follow-ups rastreáveis.

## 11. Adendo de aceitação (2026-10-09)

Rodada de aceitação do Autonomous Core na branch
`acceptance/autonomous-core-v0.1.2-2026-10-09` (baseline `b38c92b`, merge do
PR #47, tag/`VERSION` v0.1.2; documentation-only, nenhum código/flag/registry/CI
tocado). Relatório completo:
`docs/audits/AUTONOMOUS-CORE-RUNTIME-ACCEPTANCE-2026-10-09.md`.

- Achado arquitetural (checkout atual): `Invoke-OrchestrationObjectiveStep` só é
  chamado por `Invoke-OrchestrationAutonomousObjective` (lib
  `OrchestrationAutonomousLoop.ps1`) e testes; a lib não tem caller produtivo;
  `GoalAutoPromotion`/`Resume` e `ProductiveObjective` event/reconcile só em
  testes; plugin V2 injeta mandato + observabilidade sem invocar task/subagent;
  sem `Executor` o passo retorna `dispatch_intent` e o driver
  `awaits-planner`. Causa-raiz: **Planner Runtime Wiring ausente** — não é
  provider; a SPEC vigente não exige daemon novo e nenhum é proposto.
- Recovery: lanes `session-lane-2026-10-06`/`-08` (+ reruns 1821/20) mantêm
  16/17/19 `pass-real`; 18/20/21/22 `blocked` ou blocked sob critério
  enrijecido; turn de modelo do Planner substituto ausente/não provado.
- Segurança: `runtime_grant_enforcement` V1/V2 OFF (registry atual); fail-open
  `/shell` 2.0.23 observado; guardas de recibo (junction/symlink/reparse),
  idempotência, fencing e `pending` ambíguo provados **em teste/harness**;
  TOCTOU de reparse residual documentado; raiz de recibos confiável por escolha
  do caller.
- Watchdog CI: run `37893387670` attempt1 falhou só no job PS7 da lane V2 com
  5 assertions FIX4-2b (`killed=0`, settlement `REFUSED`, root vivo, asserts de
  resume); attempt2 5/5 sucesso. PS51 attempt1 passou watchdog (incl. FIX5-2).
  Hipótese estática (preparo CIM/árvore consumindo deadline de 9s → `REFUSED`
  correto) **não confirmada** — log não emite detalhe da recusa; re-run não é
  prova de fix; asserts não modificados. Classificado sem abrir issue.
- Veredito desta rodada: **PARTIAL CLOSURE** — wiring produtivo ao vivo,
  transições automáticas, settlement do Task Kernel em runtime-real e consumo
  por Planner substituto **não provados**. Suíte V3 completa local PS5.1 e PS7:
  cada engine 81 PASS/3 FAIL/6 SKIP; os 3 FAILs são os checks de hash canônico `DE22307F`
  contra a configuração global user-owned `C1BB84F2…`
  (`CapabilityObservability`, `CapabilitySkillUtility`, `shadow-route`),
  preservada sem reconciliação. Watchdog local 421/421 PASS, incluindo
  FIX4-2b/FIX5-2 em ambas engines. Evidência verde completa da CI attempt2 permanece 5/5; attempt1
  teve 5 FAIL FIX4-2b conforme acima. Próximo passo
  delimitado: implementar/validar o Planner Runtime Wiring com a ferramenta
  nativa existente (subagent V2/task V1 via Planner em sessão ativa), sem novo
  daemon e sem inferência de API.

## 12. Revisão do plano Native Handoff (2026-10-09)

Documentos produzidos: `PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md` e
`PLANNER-NATIVE-HANDOFF-v0.1.2-PLAN.md`. A investigação e revisão independente
confirmaram G0 (causa-raiz = ausência de caller/wiring produtivo), mas
identificaram bloqueio de segurança antes de G1: o callback PowerShell atual é
síncrono, e a chamada nativa do Planner não pode ocorrer dentro dessa stack;
executar primeiro a tool e depois chamar o bridge não satisfaz autorização
pré-efeito. Hooks observacionais/fail-open e output textual não comprovam
enforcement nem correlation de host.

G1 exige prova no runtime exato de autorização pré-efeito para a tool nativa e
identidade/correlação host-originated da execução. Sem essa capacidade, manter
HOLD, preservar `runtime_grant_enforcement` OFF e não iniciar uma fixture que
crie efeitos sem admissão. G2–G7 permanecem não aprovados; veredito permanece
**PARTIAL CLOSURE**. Detalhes no audit de aceitação §16. Nenhuma alteração de
código/flags/configuração foi feita; as mudanças user-owned dos adapters V1/V2
permanecem intactas.

## 13. Evidência de hook nativo V2 (2026-10-09)

Após autorização do operador para iniciar, probe isolado no binário `2.0.23`
comprovou que `execute.before` consegue recusar a chamada `subagent` testada
antes do retorno/criação observada de child; a chamada positiva correlacionou
parent/message/call e child session ID por eventos do host, com confirmação na
store de sessões. Evidência, SHA-256 do binário e eventos sanitizados:
`evidence/v3.1/runtime-reliability/native-handoff-hook-probe-2026-10-09.json`.

Isso avança o diagnóstico da capacidade de veto do runtime, não o fechamento da
feature. Não há ainda PREPARE durável/consumido, settlement no TaskKernel,
verification, ADVANCE, recovery, prova V1 nem contenção de grants do worker.
G1 produtivo segue bloqueado; `runtime_grant_enforcement` continua OFF/HOLD.

## 14. PR-A — NativeDispatch PREPARE/CLAIM (2026-10-10)

Fatia de biblioteca NativeDispatch implementada com `prepared → claimed /
DISPATCH_UNCERTAIN`, receipt store único, fencing/revalidação, exclusão de
efeito por Task entre Goals/revisões/keys e caminho síncrono legado; corrupção,
tipos JSON malformados e reparse falham fechado. Exceção/resultado inválido
pós-efeito preserva `pending`, sem retry implícito. Takeover de `settled` exige
prova kernel-side.

Reviewer e Security Reviewer aprovaram **somente a primitiva sintética**. Tester
passou 6 suites PS5.1+PS7 (Handoff 675, NativeDispatch 180, Receipts 187,
Envelopes 39, IntentSymbol 47, AutonomousLoop 47 por engine), 10/10 repetidas
PS5.1 NativeDispatch, package consistency 16/16 e `git diff --check`.

Probes exact-binary V2 2.0.23 comprovam `execute.before` veto, correlation
parent/message/call/child, `permission.evaluate` deny de read/edit e de um
comando shell literal sintéticos, e `ctx.session.get(child).parentID`. O
Promise plugin não expõe `ctx.permission.rules`. Isso não conecta o plugin às
funções NativeDispatch: nenhuma chamada PREPARE/CLAIM/SETTLE productiva foi executada;
nenhum TaskKernel result, VERIFY, ADVANCE ou recovery. O instalador só leva o
bundle JS, sem as libs/scripts bridge, e a fonte de autorização deve ser
independente do modelo. G1 produtivo permanece **BLOCKED**, G2–G7 não aprovados,
V1 e enforcement geral em HOLD; ver audit §§17–19.
