# Mission Consolidation & Fallback — PLAN (2026-11-13)

Status: Step 1 **PARTIAL** (this slice); Step 2 **DONE** (declared/effective,
OAuth and native Luna/MiMo samples recorded; live-config reinstall remains
Step 5); Step 3 **IN PROGRESS**; Step 4 **DONE for the measured T1 fallback**
(Planner-mediated; not automatic); Step 5 **PARTIAL** (install/ownership
proved; Agent Config full sync blocked upstream); Step 6 **DONE**
(cache/skills measurements; #11/#64 remain PARTIAL); Step 7 **PARTIAL**.

| Step | Work | Dependency | Initial status |
|---|---|---|---|
| 1 | Docs/backlog against current code | policy/code and issue evidence | PARTIAL; issue closure/update completed only where directly proven; remaining disposition tracked below |
| 2 | Model policy/quota | policy 1.5.0, OAuth, effective config and native samples | DONE; live configuration still awaits Step 5 reinstall |
| 3 | Consolidate PRs #238/#239/#240 | #238 merged; #239/#240 update-branch CI | IN PROGRESS; #239/#240 awaiting CI |
| 4 | Normalize errors + T1 fallback | classification, observed no-start, Kernel gates | DONE for T1 proof: normalized error, observed non-start, authorized same-tier decision, native MiMo succeeded and `model-attempt` recorded; Planner-mediated, not automatic |
| 5 | Orchestration/Agent Config/-Clean integration | Steps 1-2; ownership and authorized reinstall | PARTIAL; clean installs and ownership verified, full Agent Config reconciliation blocked by upstream AGENTS.md substring error |
| 6 | Cache/skills | same-session cache observations + metrics | DONE for measurement; #11/#64 PARTIAL (no real completion journey/latency) |
| 7 | T2–T4 routing | Steps 3–6; runtime/model proof | PARTIAL; bounded routing chains measured, T4 remains policy/test-only |

## Blockers and risks

- Installed OpenCode is 2.3.0, outside the native override proof allowlist
  (`Test-OrchestrationNativeModelOverrideProof` accepts 2.2.5, 2.2.6, 2.0.23).
- Explicit `subagent.model` override was empirically observed in Luna/MiMo
  calls, but the allowlist was not changed; runtime pin/allowlist remains a
  human decision.
- Model-dependent full turns 18/20/21/22 are blocked; no model provider is
  available for their full-turn proofs.
- DeepSeek Go ZDR is `expired-unconfirmed`; do not send data requiring ZDR.
- `models.jsonc` is declared local configuration only. Live configuration
  changes require the separate Step 5 reinstall.
- Worktree `opencode models` failed during plugin activation; the Planner-
  verified main-environment inventory is recorded separately.
- The measured primary failure was synthetic `openai/does-not-exist`, not a
  real Luna 429. 429/quota/503 are covered by synthetic tests only.
- Agent Config Settings tests passed 36/36. Preview shows only top-level
  permission drift (`read|* allow`) and preserves extra settings. Full
  `-Component All -Runtime OpenCode` reconcile (without `-Apply`) is BLOCKED
  upstream: `Substring` / `ArgumentOutOfRangeException` while processing
  AGENTS.md (105 current lines versus 301 desired). No changes were made in
  Agent Config; recommend fixing the parser there.

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
| explorer T1 | `openai/gpt-6-luna` → `opencode/mimo-v2.6-flash-free` | Cadeia real medida |
| coder complex T3 | `claude-agent/sonnet` → `openai/gpt-6.1-terra` → `opencode-go/deepseek-v4.1-flash` → `opencode-go/muse-spark-1.3-contributor` | Cadeia real medida |
| reviewer high T3 | `claude-agent/sonnet` → `openai/gpt-6.1-terra` | Cadeia real medida |
| security-reviewer critical T3 | `claude-agent/sonnet` → `openai/gpt-6.1-terra` | Cadeia real medida |
| architect high T3 | `claude-agent/sonnet` → `openai/gpt-6.1-terra` | Cadeia real medida |
| T4 | Opus → Sol | Candidato de policy coberto por testes do Router; sem transição real. Requer seleção T4 e prova Kernel-owned. |
| Astra | Excepcional proof-gated | Não alegado como executado |

As evidências/medições estão limitadas às execuções relatadas; não implicam
autorização geral de fallback, execução de Astra, nem conclusão dos turns
18/20/21/22.

## Etapa 5 — instalação e ownership

Evidence: `evidence/mission-2026-11-13/install-agent-config-validation.json`.
Temporary `-TargetHome` install created 30 resources with 0 conflicts and
validated 19 profiles; explorer/tester/coder resolved to Luna and the plugin
was present. The live `install.ps1 -Runtime V2 -Clean` made backup
`~/.config/opencode/backups/oo-20261113-170209` (24 files), updated
explorer/researcher/tester/docs-manager to Luna, preserved MCP (`servers`,
`reason-network`), 24 top-level permissions, skills roots and the enforcement
plugin, with 19 profiles. Manifest ownership was
`agent-config` for config/global text, `orchestration` for worker profiles
and skills. This does not close Step 5: full Agent Config sync remains blocked
by the upstream reconciler error above.

## Issue / PR triage

| Item | Disposition | Evidence / remaining work |
|---|---|---|
| PR #210 | Recommend closing as obsolete/conflicting; do not close here | Superseded by #238/#239; retain useful planner/Haiku components only where already absorbed |
| #208 | Update with evidence and actual remaining blockers | Do not claim complete; cite runtime and proof gaps |
| #11 / #64 | Partial | Existing implementation is not full acceptance; document remaining requirements and require proof |
| #238 / #239 / #240 | Consolidation track | Coordinate as successor work; no item is complete without its acceptance evidence |

No issue is declared complete in this plan without direct proof and maintainer
disposition.
