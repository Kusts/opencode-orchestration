# Mission Consolidation & Fallback — PLAN (2026-11-13)

Status: Step 1 **PARTIAL** (this slice); Step 2 **DONE** (declared/effective,
OAuth and native Luna/MiMo samples recorded; live-config reinstall remains
Step 5); Step 3 **DONE** (PR reconciliation); Step 4 **DONE for measured T1/T2 fallbacks**
(Planner-mediated; not automatic); Step 5 **DONE** (Agent Config fix and live
sync converged); Step 6 **DONE**
(measurement, including one skill-invocation journey reaching DONE; #11/#64
remain PARTIAL); Step 7 **PARTIAL** (T3/T4 availability fallback observed,
but provider outage/429/503 and Astra unproven).

| Step | Work | Dependency | Initial status |
|---|---|---|---|
| 1 | Docs/backlog against current code | policy/code and issue evidence | PARTIAL; issue closure/update completed only where directly proven; remaining disposition tracked below |
| 2 | Model policy/quota | policy 1.5.0, OAuth, effective config and native samples | DONE; live configuration still awaits Step 5 reinstall |
| 3 | Consolidate PRs #238/#239/#240 | merge state and focused reconciliation evidence | DONE; #238/#239/#242/#243/#244 MERGED; #240 CLOSED → #243; master evidence `402dbc0`, `f7a233e`, `df74e2a` |
| 4 | Normalize errors + T1/T2 fallback | classification, observed no-start, Kernel gates | DONE for T1/T2 proofs: authorized decisions, native fallback child sessions succeeded and `model-attempt` recorded; Planner-mediated, not automatic |
| 5 | Orchestration/Agent Config/-Clean integration | Steps 1-2; ownership and authorized reinstall | DONE; Agent Config fix applied, Instructions/Settings converged, post-sync install WhatIf reports zero drift |
| 6 | Cache/skills | cache and skill A/B measurements | DONE for measurement; skills-assisted journey reached DONE (n=1, non-randomized, `executed=false`); #11/#64 remain PARTIAL |
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

## Etapa 7 — cadeias observadas

| Role / tier | Modelo observado em ordem | Estado / limite |
|---|---|---|
| explorer T1 | `openai/gpt-6-luna` → `opencode/mimo-v2.6-flash-free` | Transição real executada; evidência T1 |
| coder T2 | Luna T2 selection → `opencode-go/deepseek-v4.1-flash` | Decision + child execution real; failed model was synthetic `openai/does-not-exist`, not a real Luna provider failure; prompt trivial não-sensível |
| coder T3→T4 | `claude-agent/sonnet` → `claude-agent/opus` | Escalonamento real com prova Kernel-owned T3; controlled prompt failure, Opus succeeded, review approved, Task DONE |
| T3 availability fallback | Sonnet → Terra | Rejeição client-side pré-execução de modelo não listado (sem sessão); `MODEL_UNAVAILABLE` → `FALLBACK_AUTHORIZED`; Planner reportou Terra executado; tentativa registrada (`observed_model=UNKNOWN`, sessão `ses_e2857aea9ffeBN8x6nE16QeLoR`). Não prova indisponibilidade real do provider nem HTTP 429/503; candidato do resolver é audit-only |
| T4 availability fallback | Opus → Sol | Prova kernel-owned `modelproof:fallback-avail-t4-20261113:T3:2:7` (digest `sha256:ea18967593d40242503a2b5a2460cb1fcfa6e566f15553c444a835c379a8e2d3`); Opus selecionado, client-side indisponível pré-execução, `FALLBACK_AUTHORIZED`; Planner reportou Sol executado; tentativa registrada (`observed_model=UNKNOWN`, sessão `ses_e284d5e49ffenBXX35BVr1LWaC`). Não prova HTTP 429/503; candidato do resolver é audit-only |
| Astra | Excepcional proof-gated | Não alegado como executado |

As evidências/medições estão limitadas às execuções relatadas; não implicam
autorização geral de fallback, execução de Astra, nem conclusão dos turns
18/20/21/22.

Provas detalhadas: `evidence/mission-2026-11-13/fallback-t2-proof.json`,
`evidence/mission-2026-11-13/g1-t4-done-proof.json` e
`evidence/fallback-availability-2026-11-13/`.
DeepSeek Go tem `sensitive_data_allowed=false` e ZDR
`expired-unconfirmed`; a execução foi somente um prompt trivial não-sensível.
Não enviar dados sensíveis.

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

## Etapa 6 — medição A/B de skill (#64)

`evidence/mission-2026-11-13/skill-load-ab.json` registra dois subagents
MiMo/explorer (uma amostra por braço): A carregou
`verification-before-completion` e B não carregou skill. O corpo é ~2.184
bytes (~546 tokens), mas o round-trip da tool adiciona uma inferência com
reenvio/cache de contexto; a diferença de ~34k tokens de prompt não é o
tamanho da skill. Lazy loading evita preload dos ~228k tokens estimados de
corpos, mas uma skill carregada custa um round-trip. Não criar plataforma/flag;
`skill_routing` permanece OFF.

A jornada `skill-bench2-2026-11-13` chegou a DONE (verify Kernel rev 14,
review approved rev 13, DONE rev 15); a chamada da skill ficou registrada
como `completed`, `executed=false`. A comparação segue n=1 e não randomizada,
com controle G1 diferente; não demonstra uso/benefício causal. #64 segue
PARTIAL; #11 segue PARTIAL apesar da evidência de cache na jornada DONE.

## Issue / PR triage

| Item | Disposition | Evidence / remaining work |
|---|---|---|
| PR #210 | Recommend closing as obsolete/conflicting; do not close here | Superseded by #238/#239; retain useful planner/Haiku components only where already absorbed |
| #208 | Update with evidence and actual remaining blockers | Do not claim complete; cite runtime and proof gaps |
| #11 / #64 | Partial | Existing implementation is not full acceptance; document remaining requirements and require proof |
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
