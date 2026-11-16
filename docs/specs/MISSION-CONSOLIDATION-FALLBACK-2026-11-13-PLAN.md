# Mission Consolidation & Fallback — PLAN (2026-11-13)

Status: Step 1 **PARTIAL** (this slice); Step 2 **DONE** (declared/effective,
OAuth and native Luna/MiMo samples recorded; live-config reinstall remains
Step 5); Step 3 **DONE** (PR reconciliation); Step 4 **DONE for measured T1/T2 fallbacks**
(Planner-mediated; not automatic); Step 5 **DONE** (Agent Config fix and live
sync converged); Step 6 **DONE** para medição, com decisão registrada
(manter carregamento nativo de skills e telemetria de cache existente; #11/#64
permanecem PARTIAL, sem claim causal, critério objetivo para reabrir
investimento: n>=3, ordem randomizada, mesmo modelo/tarefa, custo observável e
métrica de qualidade); Step 7 **PARTIAL** (T3/T4 availability fallback observed,
but provider outage/429/503 and Astra unproven).

| Step | Work | Dependency | Initial status |
|---|---|---|---|
| 1 | Docs/backlog against current code | policy/code and issue evidence | PARTIAL; issue closure/update completed only where directly proven; remaining disposition tracked below |
| 2 | Model policy/quota | policy 1.5.0, OAuth, effective config and native samples | DONE; live configuration still awaits Step 5 reinstall |
| 3 | Consolidate PRs #238/#239/#240 | merge state and focused reconciliation evidence | DONE; #238/#239/#242/#243/#244 MERGED; #240 CLOSED → #243; master evidence `402dbc0`, `f7a233e`, `df74e2a` |
| 4 | Normalize errors + T1/T2 fallback | classification, observed no-start, Kernel gates | DONE for T1/T2 proofs: authorized decisions, native fallback child sessions succeeded and `model-attempt` recorded; Planner-mediated, not automatic |
| 5 | Orchestration/Agent Config/-Clean integration | Steps 1-2; ownership and authorized reinstall | DONE; Agent Config fix applied, Instructions/Settings converged, post-sync install WhatIf reports zero drift |
| 6 | Cache/skills | cache/skills evidence and decision | DONE for measurement/decision: manter skills nativas (catálogo+sob demanda, `skill_routing` OFF) e telemetria de cache existente; NÃO criar plataforma/flag/otimização de cache. #11/#64 PARTIAL (observacional, sem causalidade; `cost_observed=false`); reabrir só com n>=3, ordem randomizada, mesmo modelo/tarefa, custo observável e métrica de qualidade |
| 7 | T2-T4 routing | Steps 3-6; runtime/model proof | PARTIAL; T1/T2 availability fallback real; T3→T4 kernel-proof escalation and DONE real; T3/T4 availability fallback authorized and executed after observed client-side pre-execution model rejection; no real HTTP 429/503 or provider outage proved; Astra not executed |

## Blockers and risks

- The explicit `subagent.model` override was observed in Luna/MiMo; the
  allowlist accepts 2.2.5/2.2.6/2.0.23/2.3.0 (PR #244), while the canonical
  pin remains 2.2.6 and any bump is separate work.
- Model-dependent full turns 18/20/21/22 are blocked; no model provider is
  available for their full-turn proofs.
- DeepSeek Go ZDR is `expired-unconfirmed`; do not send data requiring ZDR.
- `models.jsonc` is declared local configuration only. Live configuration
  changes require the separate Step 5 reinstall.
- Worktree `opencode models` failed during plugin activation; the Planner-
  verified main-environment inventory is recorded separately.
- The measured primary failure was synthetic `openai/does-not-exist`, not a
  real Luna 429. 429/quota/503 are covered by synthetic tests only.
- DeepSeek Go T2 proof and G1/T4 proof are bounded to their recorded prompts
  and task fixtures; neither establishes a general provider-failure rate.
- Agent Config reconciliation blocker is fixed and live sync converged.
  Agent Config PR #51 (`54f3b9c`) contains the `$lineText` trim fix. Suites:
  pwsh 95/95; PS5.1 91/95 with four pre-existing failures (base 87/91);
  OpenCodeSettingsReconciler 36/36.
- CI V3 suite step timeout raised 60→110 minutes and its three job timeouts
  75→140 minutes after runner cancellations near 60 minutes despite suite
  runtimes of approximately 48–57 minutes.

## Etapa 4 — sequência operacional do Planner

1. `model-select` obtains the Kernel-authorized model selection.
2. Planner dispatches exactly one native `subagent` with that model.
3. On `tool.execution` without `sessionID`/child session, classify and require
   observed no-start, then `model-fallback.ps1 -Action next` selected MiMo T1.
4. Planner dispatched the next native `subagent`; MiMo succeeded in child
   session `ses_e29808f9dffeyyU67grp62rgFD`.
5. `model-fallback.ps1 -Action record` appended `stage=post_dispatch`,
   `success=true`, observed model and session to `model-attempts.jsonl`.
6. If a `sessionID` exists on a failed/ambiguous dispatch, HOLD and never
   duplicate execution. Kernel remains owner of `model-proof`.

This measured fallback is Planner-mediated, not automatic. Helper suites
passed 39/39, 70/70 and 8/8 in Windows PowerShell 5.1 and pwsh. No parallel
`opencode run` executor is allowed.

## Etapa 7 — cadeias observadas e consolidação T3/T4 (evidência verificável)

**PASS / verificado (com prova):**
- **G1 T3→T4 (Task `proof-g1-20261113`):** `model-select` T3 = `claude-agent/sonnet` (coder, medium, complex); `model-attempt` registrado com sessão filha (`ses_e293f74bcffeG5cNj9f7N8OSNo`, `parentSessionID=ses_e29b0ad23ffeG1hVvNxGf05KYr`, `assistantMessageID=msg_1d6c0a0090010aF8ixEb1WyRN1`); `model-proof` Kernel-owned T3 (`modelproof:proof-g1-20261113:T3:2:9`, digest `sha256:df06d9f728227a510c890f2e9d55ac58f663ad752fd69b3588c7daa6afa77c8e`); escalonamento `model-select` T4 = `claude-agent/opus` no mesmo `TaskId` com referência/digest da prova T3; `observed_model` igual ao selecionado em T3 e T4; `verify-run` `verified_pass` (kernel-executed); review `approved`; Task `DONE` (rev 18, `worker_attempts=2`, `model_attempts=2`). Fonte: `evidence/mission-2026-11-13/g1-t4-done-proof.json`.
- **T1/T2 (wiring nativo e fallback mediado pelo Planner):** em T1 e T2, tentativa primária com modelo sintético indisponível (`openai/does-not-exist`) produziu erro nativo `tool.execution` sem `sessionID`/sessão filha; decisão `model-fallback.ps1 -Action next` autorizou fallback de mesmo tier e houve sessão filha subsequente com `observed_model` igual ao modelo solicitado/autorizado (T1: MiMo `ses_e29808f9dffeyyU67grp62rgFD`; T2: DeepSeek Go `ses_e295a469effeMUnrmkh0CrTgXn`, prompt trivial não-sensível, `sensitive_data_allowed=false`, ZDR `expired-unconfirmed`). O primário falho foi sintético (`openai/does-not-exist`), não falha real de Luna. Fontes: `evidence/mission-2026-11-13/fallback-t1-proof.json`, `fallback-t2-proof.json`, `native-override-2.3.0.json`.
- **Política/routing (confirmado em registry/código):** T1 Luna→MiMo; T2 Luna→DeepSeek/Muse/Haiku (ordem/candidatos conforme policy 1.5.0); T3 Sonnet→Terra; T4 Opus→Sol; Astra excepcional/proof-gated (`fable-requires-astra-failure`, prova/ordem audit-only conforme policy/router). `fallback_policy.prevent_cycles=true` (`source/registry/model-routing-policy.json`) e exclusão/rastreamento `ALREADY_ATTEMPTED` de modelos já tentados (`scripts/v3/lib/OrchestrationModelRouter.ps1`). Fallback é **Planner-mediated, não automático**; sem alegação de execução duplicada.

| Cadeia / observação | Estado verificável | Limite objetivo |
|---|---|---|
| explorer T1: `openai/gpt-6-luna` → `opencode/mimo-v2.6-flash-free` | Transição/execução filha real (Planner-mediated) | Primário falho sintético `openai/does-not-exist`; não prova 429/quota/503 real |
| coder T2: seleção T2 → `opencode-go/deepseek-v4.1-flash` | Decisão + sessão filha real | Primário falho sintético; prompt trivial não-sensível; ZDR `expired-unconfirmed` |
| coder T3→T4: `claude-agent/sonnet` → `claude-agent/opus` (mesmo TaskId) | Escalonamento com prova Kernel-owned, verify/review/DONE reais | Falha funcional de T3 induzida por prompt (controlada), não incapacidade natural |
| T3 availability fallback (Terra) | ID deliberadamente inexistente `claude-agent/sonnet-availability-probe-nonexistent` rejeitado client-side antes da execução, sem sessão; `MODEL_UNAVAILABLE`→`FALLBACK_AUTHORIZED`; execução Terra relatada/registrada (`observed_model=UNKNOWN`, `ses_e2857aea9ffeBN8x6nE16QeLoR`, evidência `fallback-availability-2026-11-13/` se presente) | Não é falha do Sonnet real nem outage/429/503 real; candidato do resolver audit-only |
| T4 availability fallback (Sol) | Prova kernel-owned `modelproof:fallback-avail-t4-20261113:T3:2:7` (digest `sha256:ea18967593d40242503a2b5a2460cb1fcfa6e566f15553c444a835c379a8e2d3`); ID inexistente `claude-agent/opus-availability-probe-nonexistent` rejeitado client-side antes da execução; `FALLBACK_AUTHORIZED`; execução Sol relatada/registrada (`observed_model=UNKNOWN`, `ses_e284d5e49ffenBXX35BVr1LWaC`) | Não é falha do Opus real nem HTTP 429/503 real; candidato do resolver audit-only |
| Astra | Excepcional, proof-gated | Não executado |

**PARTIAL / HOLD (critérios objetivos):**
- **429/quota/503/outage real de provider:** **não observado**. Probe com ID/modelo inexistente é rejeição client-side pré-execução (sem sessão), não indisponibilidade real. **Retomar quando** um evento real de provider for observado com prova de não-início (no-start) independente/aceita pelo Kernel antes de qualquer retry/fallback.
- **Falha natural de T3:** a prova G1 foi **induzida por prompt** (controlada), não estabelece incapacidade natural do modelo. **Retomar quando** uma falha funcional espontânea de T3 for verificada pelo Kernel (prova Kernel-owned) em cenário não induzido artificialmente.
- **Astra:** **não executado**. **Retomar apenas** se Sol não resolver, com prova Kernel-owned conforme gates de policy (excepcional/proof-gated); nunca automático.
- **Timeout/resultado ambíguo:** **HOLD**, sem retry e sem execução duplicada (aguardar prova de estado/no-start antes de qualquer ação).

Provas detalhadas: `evidence/mission-2026-11-13/fallback-t1-proof.json`, `fallback-t2-proof.json`, `g1-t4-done-proof.json`, `native-override-2.3.0.json`; observações T3/T4 availability em `evidence/fallback-availability-2026-11-13/` (quando presentes). Medições limitadas às execuções relatadas; sem claim de 429/503/outage real, sem claim de falha natural de T3, sem claim de Astra e sem claim de automação total. Não implica conclusão dos turns 18/20/21/22. DeepSeek Go: execução T2 limitada a prompt trivial não-sensível (`sensitive_data_allowed=false`, ZDR `expired-unconfirmed`).

## Etapa 5 — instalação e ownership

Install evidence: `evidence/mission-2026-11-13/install-agent-config-validation.json`.
Temporary `-TargetHome` install created 30 resources with 0 conflicts and
validated 19 profiles; explorer/tester/coder resolved to Luna and the plugin
was present. The live `install.ps1 -Runtime V2 -Clean` made backup
`~/.config/opencode/backups/oo-20261113-170209` (24 files), updated
explorer/researcher/tester/docs-manager to Luna, preserved MCP (`servers`,
`reason-network`), 24 top-level permissions, skills roots and the enforcement
plugin, with 19 profiles. Manifest ownership was
`agent-config` for config/global text, `orchestration` for worker profiles
and skills.

**Step 5 closure:** Agent Config PR #51 (`54f3b9c`) fixes the previous
`Substring`/`ArgumentOutOfRange` error at approximately line 886 by using
trimmed `$lineText`. Preview exited 0 with the 105-vs-301-line marker diff and
no exception. Instructions apply used the canonical repo root and applied
global + OpenCode, with rollback at
`C:\Users\walis\.agents\reconciliation-backups\reconcile-20261113-182722\rollback.json`.
Settings `-Apply -Force` applied permissions 24→25 while preserving extras;
backup `opencode.json.20261113-182740...bak`. Instructions and Settings
previews converged (`SAME`, hashes `3784D3AD9BFB` and `80E3767353D8`).
Post-sync install `-WhatIf`: `INSTALLED=0 UNCHANGED=24 PRESERVED=15
CONFLICT=0 FAILED=0`. Full evidence:
`evidence/mission-2026-11-13/agent-config-sync-2026-11-13.json`.

## Etapa 6 — decisão cache (#11) e skills (#64)

Decisão registrada com base em evidências existentes, sem repetir experimento caro e sem claim causal.

**Evidências (números e limitações):**
- `evidence/skill-ab-2026-11-13/comparison.json`/`README.md`: mesmo modelo `openai/gpt-6-luna` T2, runtime 2.3.0, tarefa/perfil/escopo iguais, `verified_pass`/DONE em ambos, n=1, ordem A→B não randomizada, `cost_observed=false`. A (com `verification-before-completion`): 3.815 input / 231.680 cache-read / 498 output / 21 reasoning. B (sem `verification-before-completion`, com `ai-memory-retrieval` e `systematic-debugging`): 19.741 input / 448.256 cache-read / 784 output / 194 reasoning (~5,2× input e ~1,9× cache-read vs A). Limitações: arm B não é controle sem skills; observacional; possível aprendizado/cache; mesma máquina.
- `evidence/abba-2026-11-13/comparison.json`: ABBA, n=2 por braço, mesmo modelo/máquina. Médias A 3.655 input / 269.312 cache-read / 25.606,5 ms; B 2.772,5 input / 218.112 cache-read / 22.172 ms (amplitudes/ranges relevantes). `control_valid=true` apenas indica 0 `skill` calls em B (controle instruído/auditado, sem bloqueio mecânico). Limitações: n=2, contaminação cruzada em b1 (leitura de correção pronta de a1; write out-of-scope motivou rescope), carryover aprendizado/cache, custo não observado. Piloto de procedimento, não teste de superioridade.
- `docs/specs/SKILL-BENCH-JOURNEY-2026-11-13.md`: invocação `completed` com `executed=false` em jornada DONE n=1 não randomizada — registro de invocação, não uso/benefício.
- Medição prévia `evidence/mission-2026-11-13/skill-load-ab.json`: corpo ~2.184 bytes (~546 tokens estimados) para `verification-before-completion`; round-trip de tool adiciona reenvio/cache de contexto; lazy loading nativo evita preload (~228k tokens estimados de corpos no lote medido), mas carregar uma skill custa um round-trip.

**Decisões:**
1. **Skills:** manter carregamento nativo (catálogo + invocação sob demanda). NÃO construir plataforma/flag de descoberta seletiva; `skill_routing` permanece OFF. O corpo custa round-trip quando carregada; lazy loading já evita preload — manter.
2. **Cache (#11, PARTIAL):** manter telemetria de cache existente. NÃO adicionar otimização de cache agora. #11 permanece PARTIAL porque custo/cache provider-neutral e custo-to-DONE ajustado por cache não estão observáveis (`cost_observed=false`), apesar de leituras de cache observadas.
3. **#64, PARTIAL:** comparação observacional (n=1 no A/B principal; ABBA piloto contaminado), sem inferência causal. O braço com skill usou menos tokens no A/B principal, mas a diferença não prova benefício nem generaliza.
4. **Critério objetivo para reabrir investimento:** repetição com n>=3, ordem randomizada, mesmo modelo/tarefa, custo observável e métrica de qualidade; sem isso, não há base para plataforma nova.
5. **Interpretação:** "manter nativo" é decisão baseada em evidência insuficiente para justificar plataforma nova, não prova de que a otimização funciona. Nenhum claim causal.

## Issue / PR triage

| Item | Disposition | Evidence / remaining work |
|---|---|---|
| PR #210 | Recommend closing as obsolete/conflicting; do not close here | Superseded by #238/#239; retain useful planner/Haiku components only where already absorbed |
| #208 | Update with evidence and actual remaining blockers | Do not claim complete; cite runtime and proof gaps |
| #11 / #64 | Partial (decisão registrada) | **#11:** manter telemetria de cache existente, sem otimização agora; permanece PARTIAL porque custo/cache provider-neutral e custo-to-DONE ajustado por cache não são observáveis (`cost_observed=false`). **#64:** manter carregamento nativo de skills (catálogo+sob demanda, `skill_routing` OFF, sem plataforma/flag); permanece PARTIAL — comparações observacionais (A/B n=1; ABBA n=2 contaminado), sem causalidade, diferença de tokens não prova benefício nem generaliza. "Manter nativo" = evidência insuficiente para plataforma nova, não prova de otimização. **Reabrir só com:** n>=3, ordem randomizada, mesmo modelo/tarefa, custo observável e métrica de qualidade. |
| #238 | MERGED | Merge confirmado |
| #239 | MERGED | Merge confirmado |
| #240 | CLOSED → #243 | Substituído pelo follow-up #243 |
| #242 / #243 / #244 | MERGED | Merge confirmado; commits de master `402dbc0`, `f7a233e`, `df74e2a` |
| #245 | MERGED | `5933b9d`; smoke n8n-Syncthing com correções de segurança |
| #246 | MERGED | `693ab07`; CI step/job timeouts 110/140 |
| #247 | MERGED | `1b9c66b`; pin V2 2.3.0 |
| #248 | MERGED | `fdaa6ae`; provas T3/T4 availability com limites documentados |
| #249 | MERGED | `a9c60fa`; jornada DONE com skill, n=1; #11/#64 seguem PARTIAL |

No issue is declared complete in this plan without direct proof and maintainer
disposition.
