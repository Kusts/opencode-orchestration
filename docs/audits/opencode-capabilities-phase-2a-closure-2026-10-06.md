# Phase 2A closure — OpenCode capabilities (2026-10-06)

Date: 2026-10-06. Runtime observed: OpenCode v2.0.24 (`@opencode/cli` 2.0.24,
compiled Bun binary). Pins in force stay at 2.0.23 / 1.18.34 (§14).

Scope: this checkout owns the registry/policy/healthcheck/report below. The
machine-global runtime state (`~/.config/opencode/`, logs, tokens) is
user-owned: this report cites evidence paths, never secret values.

Branch: `fix/capabilities-phase-2a`. HEAD at closure start: `30e658a`.
This file (`docs/audits/opencode-capabilities-phase-2a-closure-2026-10-06.md`)
is the Phase 2A closure record; it absorbs and supersedes the earlier
incident-report draft of the same filename (§§1–12 + gate + rotation runbook
preserved below in §§4–5, §7, §11–12, §18 and appendices).

P0 verdicts (honest): planning **PASS** as the documented 17+19+19 contract
(§3); enforcement **PASS** via logs + plugin list + telemetry (§5);
permissions **PASS parcial** with an explicit HOLD on force-push/docker-prune
patterns plus the safe ask/deny subset (§6); secret migration **PARTIAL** —
repo clean, but AI Memory token rotation pending operator action (§7, §18).

## 1. Scope

Phase 2A covers OpenCode capability inventory and verification for this
package: planning-agent contract (fatia 1), capability registry V2 + policy
(fatia 2), plugin autoload proof, enforcement proof, permissions hardening,
secret migration, Orca/TUI decisions, cleanup, Node/launcher findings,
healthchecks, skills precedence, version pins, test results, runtime smoke,
and security verification — with explicit residuals and deferrals to
Phase 2B (§19) and Phase 2C (§20).

Out of scope (untouched, recorded only): dynamic routing activation
(`capability_router`, `skill_routing`, `mcp_routing`, `adaptive_ranking` stay
OFF — §11), version pin bumps (§14), `config-format` pre-existing FAILs
(§15), clean-boot strict PASS as optional follow-up (§12).

## 2. Initial State

- Assumption Q1 (disproven, see §4): `"plugin": []` in `opencode.json` ⇒ no
  plugins loaded. The V2 server autodiscovers `~/.config/opencode/plugins/`
  at boot plus watcher-triggered rescan.
- A legacy V1-contract `ai-memory.ts` (from `ai-memory install-hooks
  --agent opencode`) sat in the active plugins root and produced 15
  `LoadError` lines (incident AI-MEM-V1-20261006, §4).
- Planning-agent contract undocumented-in-one-place: 17 template blocks vs
  19 `.md` files vs 19 allowlist entries needed the canonical 17+19+19
  write-up (now `docs/capability-planning-v2.md`, §3).
- No static curated capability registry V2 existed (now
  `source/registry/capabilities-v2.json`, §11).
- Healthchecks were ad hoc (now `scripts/ci/plugin-healthcheck.ps1` and
  `scripts/v3/capability-healthcheck.ps1`, §12).
- A plaintext Bearer token lived in quarantined V1 copies; rotation pending
  operator (§7, §18).

## 3. Planning Agents Fix

**Verdict: PASS** — as the documented contract, not as new blocks.

`docs/capability-planning-v2.md` records the canonical inventory:

- **17 blocks** in `templates/opencode.v2.json.tmpl` under `agents`:
  `build` + `title` + 15 workers with their own block.
- **19 files** in `source/agents/*.md` (one per delegable worker).
- **19 allows** in the `build` allowlist (`agents.build.permissions`:
  1 × `{subagent, *: deny}` broad-first + 19 × narrow `allow` — check 13 of
  `scripts/test-package-consistency.ps1`).

The 4 planning roles (`requirements-analyst`, `engineering-advisor`,
`product-designer`, `skeptic`) are **file-based + allowlisted**: present as
`.md` in `source/agents/` and as `allow` in the `build` allowlist, with
**no** `agents.<name>` block in the V2 template (nor `agent.<name>` in V1).
They dispatch as `subagent` via `build` (advisory, read-only,
`task: deny`), no managed model/permissions JSON of their own.

Adding 4 blocks (17 → 21) would be wrong mechanically (breaks checks 3, 11,
12, 14 and the `install.ps1` precheck demanding 17 `agent` blocks) and
semantically (advisory read-only roles need no managed block; `.md`
frontmatter + allowlist already give identity, classification
(`source/registry/capability-policy.json#classification`) and delegability).

Validation: `tests/distribution/capability-planning.tests.ps1` **12/12**;
package-consistency checks 3/11/12/13/14 green (§15).

## 4. Plugin Loading Investigation

### 4.1 Q1 conclusion — plugin autoload is PROVEN

Prior assumption (`"plugin": []` in `opencode.json` ⇒ no plugins loaded) is
**disproven**. The V2 server autodiscovers `~/.config/opencode/plugins/` at
boot (plus watcher-triggered rescan on directory change, observed
2026-10-06T19:42:32Z and 19:45:59Z). Evidence: `opencode.log`
`msg="loading plugin"` lines for `orchestration-enforcement.js`,
`orca-opencode-status.js`, `ai-memory-opencode2.ts` in run `938e8cb0`, and 15
`failed to load plugin` lines for the legacy file. No repo doc change was
needed: `docs/INSTALLATION.md` already states plugins/skills are
autodiscovered. `orchestration-enforcement` was NOT considered validated by
this discovery alone — it was proven separately (§5).

### 4.2 AI Memory Legacy Plugin Incident (AI-MEM-V1-20261006)

- Timestamp: first failure 2026-10-06T18:41:55Z, last 2026-10-06T19:09:31Z
  (incl. ref `err_9e0c9d68`, log line 143877). Total: 15 occurrences, one
  target only.
- Runtime: OpenCode 2.0.24, server role, run `938e8cb0`.
- File: `~/.config/opencode/plugins/ai-memory.ts` (template
  `ai-memory install-hooks --agent opencode`, regenerated 15:41 local).
- Expected contract: default export = object `{ id, effect | setup }`.
- Found contract: default export = bare async function
  (`export const AiMemoryHooks: Plugin = async …`; `export default AiMemoryHooks`).
- Loader error: `PluginModule.LoadError: Plugin must export a default
  definition with an id and an effect or setup function. (cause:
  SchemaError(Expected object at ["default"]))`.
- Root cause: legacy V1 adapter template installed on a V2-only loader. NOT
  an MCP/credential/network/AI-Memory-availability issue (remote MCP stayed
  healthy throughout).
- Remediation: 2026-10-06 the file left the active root. First a reversible
  rename to `ai-memory.ts.v1-disabled-20261006`, then quarantine of all
  inactive ai-memory copies outside the autodiscovered root:
  `~/.config/opencode/archive/plugins-v1/` (3 V1 copies) and
  `~/.config/opencode/archive/plugins-v2/` (1 opencode2 backup). Active root
  keeps only `ai-memory-opencode2.ts`. SHA256 (prefix) at move time:
  `F9A3B0D9…` (2 identical 39953-byte V1 copies), `D2230C61…` (47480-byte
  older V1), `2A761016…` (35685-byte opencode2 backup). Rollback = move back;
  no content deleted.
- Post-remediation smoke (no restart needed — watcher rescans): rescan
  19:42:32Z and 19:45:59Z load `ai-memory-opencode2.ts`,
  `orchestration-enforcement.js`, `orca-opencode-status.js` with **zero** new
  `LoadError`. Full-log count stays at the 15 historical lines, all dated
  before the fix.
- Token rotation: PENDING operator confirmation (P0, see §7).
- Backup scan: see §7.
- Healthcheck: `scripts/ci/plugin-healthcheck.ps1` → `PASS` with
  `-SinceTimestamp "2026-10-06T19:09:32Z"` (strict whole-run mode still
  reports the 15 historical lines, as designed).
- RECURRENCE 20:03Z (recorded Phase 2A closeout): an identical V1 copy
  (`ai-memory.ts`, 39953 bytes, SHA256 `F9A3B0D9…` — same as the 2
  quarantined copies) reappeared in the active root (created 17:03 local =
  20:03Z); watcher rescan at 20:03:21Z produced 5 new `LoadError` for the
  same target (`err_d9bb5349`, `err_7f88f111`, `err_68b17e2c`,
  `err_75667960`, `err_da80387f`). Provenance of the rewrite is UNKNOWN
  (no `install-hooks` line in scope; suspects: a hook/task regenerating V1
  — to triage separately). Re-quarantined reversibly to
  `archive/plugins-v1/ai-memory.ts.regen-20261006-2003Z` (same hash,
  rollback = move back; nothing deleted). Post-re-quarantine:
  `plugin-healthcheck.ps1 -SinceTimestamp "2026-10-06T20:04:38Z"` → `PASS`
  (`load_errors: 0`). Lesson: quarantine alone does not prevent
  regeneration — a guard/watch (healthcheck in CI/scheduled + `deprecated
  absent` assertion) is REQUIRED until the producer is found and stopped;
  deletion remains gated on token rotation (§7).

### 4.3 V1 regeneration: OBSERVED once (contained)

A V1 copy was regenerated/re-copied into the active root at 20:03Z
(see RECURRENCE note in §4.2) and re-quarantined the same session.
Policy recorded in
`source/registry/plugin-capabilities.json` (`regeneration_policy`): never use
`--agent opencode`; V2-only `--agent opencode2 --apply` and only when needed.
The current `ai-memory-opencode2.ts` (`TOKEN: null`, env/file-resolved auth)
was left untouched.

### 4.4 V2 plugin smoke — DONE (restart-equivalent via watcher rescan)

- `ai-memory-opencode2.ts` loads (19:37:59Z, 19:45:59Z), shape `v2_object`,
  zero `LoadError` for this target across the whole log.
- Hooks deliver (spool dir empty, no 5xx backlog signals); MCP remote healthy
  (ai-memory tools live in-session).
- Remaining: optional clean-boot for a strict whole-run PASS (watcher-rescan
  evidence already satisfies the incident smoke).

## 5. Enforcement Proof

**Verdict: PASS** — via server logs + plugin list + telemetry, not via
discovery alone.

| field | value | evidence |
|---|---|---|
| installed | true | file present, PACKAGE-owned (GOVERNANCE.md) |
| discovered | true | `loading plugin` + `watcher subscribe` lines |
| schema_valid | true | default export `DualExport = { id, setup, server }`, id `orchestration-enforcement` |
| initialized | true | load with zero `LoadError`, rescan-safe |
| hook_executed | true | signal 1: `session-injections.jsonl` tool-event rows from live subagent sessions (19:39Z); signal 2: load + watcher lines with no subsequent failure |
| healthy | true | — |

Registry mirror: `source/registry/capabilities-v2.json#orchestration-enforcement`
(status ACTIVE, bundle + `.sha256` sidecar integrity probe) and
`source/registry/plugin-capabilities.json#orchestration-enforcement`
(same five-field status + evidence pointers).

## 6. Permissions Hardening

**Verdict: PASS parcial** — safe subset enforced; explicit HOLD below.

Observed in `source/agents/coder.md` (representative; same pattern across
workers):

- Hard `deny`: `git reset --hard*`, `git reset *--hard*`, `git clean *`,
  `git branch -D*`, `terraform destroy*`, `kubectl delete *`,
  `ssh-keygen *`, `dropdb *`, `Format-Volume*`, `diskpart*`.
- Gated `ask` (confirmation, auto-approved only in auto mode): `git push *`,
  `git rebase *`, `docker rm *`, `npm publish*`, `gh release *`,
  `wrangler deploy*`, `npm run deploy*`, `rm -rf *`,
  `Remove-Item *-Recurse*`, `kubectl apply *`, `gh auth *`,
  `curl *-X POST*`, `Invoke-RestMethod *-Method Post*`.
- `task: deny` on workers (no sub-delegation); tester ships without `edit`.

Validation: `coder-perms` suite **27/27** (§15).

**HOLD (honest residual):** no literal `force-push` / `docker prune` rule
exists in the worker permission blocks — those patterns are covered only
indirectly (`git push *` → `ask`, `docker rm *` → `ask`). An explicit
`force-push`/`prune` deny (or a documented decision that `ask` suffices) is
deferred to Phase 2B (§19). This HOLD does not reopen the PASS above: no
worker can push, publish, deploy, or destroy without confirmation.

## 7. Secret Migration

**Verdict: PARTIAL** — repo clean; rotation of the live AI Memory token is a
pending operator action.

- The quarantined V1 files embed a static Bearer token in plaintext (value
  never printed, logged, or stored by this investigation; all comparisons were
  in-memory containment checks).
- Fingerprint comparison: the embedded value **equals** the credential
  currently injected as `AI_MEMORY_AUTH_TOKEN` — rotation must cover the
  injection point as well. Treat the old value as compromised.
- Rotation mechanism: the `ai-memory` wrapper CLI needs bash + a running
  container engine; in this Windows session `bash` resolves to WSL whose
  docker daemon is down, so CLI-driven rotation is BLOCKED here. Rotation is
  an operator action (server-side revoke/reissue → update the injection
  point → verify). It additionally requires the operator's explicit
  confirmation per credential-action policy — requested, not yet granted.
- After rotation: delete the 3 quarantined V1 copies + the pre-merge backup
  (§9), and redact/remove the single merged-log line (§9, mechanism below).

Secret fossil scan (hash/comparison only, no values). Method: token extracted
via regex into process memory, `.Contains()` checks, output = paths +
booleans. Result:

| location | secret_candidate | action |
|---|---|---|
| `archive/plugins-v1/` ×4 (3 quarantined V1 copies + 1 regen-20261006-2003Z copy, same hash family) | true | delete after rotation |
| `~/.config/opencode/backups/merge-20261006/plugins/ai-memory.ts.pre-merge` | true | delete after rotation |
| `opencode2-merged-20261006.log` line 69335 (1 line) | true | redact/remove file or line after rotation |
| live `opencode.log` | false (0 lines) | — |
| repo (416 files <2MB, `.git` excluded) | false | — |
| launcher `invoke-agent.ps1` + 245 backup files | false (launcher clean) | — |

Leak mechanism for the merged-log line (prefix only, secret never shown):
a `spawning process … rg.exe` line — an earlier session passed the token
value as a ripgrep search argument and the server logged the full argv.
Lesson: never pass secret values as CLI arguments on this machine; they land
in `opencode.log`.

Policy (recorded in `docs/capability-phase2a-decisions.md` §1): secrets
migrate to environment variables + rotation; no secret value ever enters Git,
generated instructions, logs, reports, or telemetry; credential
create/revoke/rotate needs separate operator confirmation; healthchecks report
`configured: true/false` only. Contract note: machine-side MCP transport uses
`AI_MEMORY_AUTH_TOKEN` (verified in `opencode.json:mcp.ai-memory`) while the
kernel-side policy (`ai-memory-remote-policy.json` +
`OrchestrationAiMemoryRemote.ps1`) names `AIMEMORY_REMOTE_TOKEN` — distinct
contracts, no unification in this phase; the registry V2 probe covers the MCP
transport.

## 8. Orca/TUI Decision

Recorded in `docs/capability-phase2a-decisions.md` (§§2–3); no repo change:

- **Orca**: machine-only, no versioned integration (no template, agent,
  plugin, or script depends on it). Keep-or-disable is an explicit operator
  decision (`KEEP`/`DISABLE` machine-side); this package writes, removes, or
  configures nothing of Orca.
- **`tui.json`**: absent from the repo = **NOT-APPLICABLE** — any TUI config
  is machine-side in the operator's local profile; no suite covers it.
- **Herdr**: regex/name recognition pattern only, no execution path =
  **REMOVED/DEPRECATED** in-repo; any real activation is a future authority
  change, out of Phase 2A.
- **R1–R7** (external machine-side plan refs): no versioned counterpart =
  **NOT-APPLICABLE**.

## 9. Cleanup

Done 2026-10-06 (machine-side, reversible, nothing deleted):

1. Legacy `ai-memory.ts` renamed out of the active plugins root
   (`ai-memory.ts.v1-disabled-20261006`), then all inactive ai-memory copies
   quarantined outside the autodiscovered root:
   `~/.config/opencode/archive/plugins-v1/` (3 V1 copies) and
   `~/.config/opencode/archive/plugins-v2/` (1 opencode2 backup).
2. Active root keeps only contract-compatible files, headed by
   `ai-memory-opencode2.ts` and `orchestration-enforcement.js`.

Gated on rotation (§7): delete `archive/plugins-v1/` ×3,
`backups/merge-20261006/plugins/ai-memory.ts.pre-merge`, and redact/remove
`opencode2-merged-20261006.log` line 69335; then re-run the hash scan →
`hits: 0`.

Residual (out of Phase 2A scope, untouched): `herdr-agent-state*.disabled`
files remain in the active root; the healthcheck reports them as warnings
(§12).

## 10. Node/Launcher Findings

- Launcher `invoke-agent.ps1` verified **clean**: no embedded secret value
  (245 backup files scanned, all `false` — §7 table).
- `ai-memory` wrapper CLI rotation path BLOCKED in this Windows session:
  `bash` resolves to WSL whose docker daemon is down (§7). Operator-side
  rotation, not a repo fix.
- No Node/npm findings in Phase 2A scope beyond the pins (§14); no launcher
  change was needed.

## 11. Capability Registry V2

**DONE.** `source/registry/capabilities-v2.json` (schema 1, curated static,
declarative only): 13 capabilities with `status.desired` (intent),
`status.observed` (2026-10-06 audit snapshot), per-capability `healthcheck`
probe, risk, and activation mode. It never enables dynamic routing
(`capability-flags.json` keeps router/skill/mcp/adaptive OFF) and never adds
MCPs; new/optional MCPs never start as installed.

Complementary file: `source/registry/plugin-capabilities.json` adds the
machine-live plugin-autoload layer — V2 contract proof, V1-vs-V2 adapter
split (`ai-memory-mcp` vs `ai-memory-hooks`, legacy V1
`DEPRECATED_REMOVED`), `active_root_policy` (active root holds ONLY active
contract-compatible plugins; quarantine lives outside it), and
`regeneration_policy` (never `--agent opencode`; V2-only
`--agent opencode2 --apply` when needed).

Flags observed (`source/registry/capability-flags.json`): ON =
`capability_registry`, `runtime_support.v1/v2/dual_profile`, `task_kernel`,
`bounded_execution`, `watchdog`, `jev_advisory`, `worktree_isolation`; OFF =
`capability_reconciler`, `capability_router.shadow/active`,
`skill_routing`, `mcp_routing`, `routing_telemetry`, `adaptive_ranking`,
`runtime_grant_enforcement.v1/v2`. Dynamic routing stays OFF — no Phase 2A
activation, no claim otherwise.

Validation: `registry-v2` suite **28/28** (§15).

## 12. Healthchecks

**DONE** — two read-only scripts, both secret-safe (names/booleans only,
values never read into output):

- `scripts/ci/plugin-healthcheck.ps1` (JSON; exit 0/1; expected/deprecated
  plugin names are parameters): **PASS** in since-remediation mode
  (`-SinceTimestamp "2026-10-06T19:09:32Z"`, exit 0). Strict whole-run mode
  still reports the 15 historical lines, as designed. Policy: no run id in
  the log tail = FAILURE; any LoadError matching an expected plugin =
  FAILURE; LoadErrors for non-expected plugins = warnings only.
  `herdr-agent-state*.disabled` leftovers surface as warnings (out of
  Phase 2A scope).
- `scripts/v3/capability-healthcheck.ps1` (reads `capabilities-v2.json`;
  exit 0 = probed, 2 = fail-closed on missing/unreadable registry; PS 5.1
  compatible): **13 results — 11 healthy**, plus `ai-memory`/`jev`
  `configured: False` because the env names (`AI_MEMORY_AUTH_TOKEN`,
  `JEV_BASE_URL`/`JEV_API_KEY`) are absent in the probing shell. That is a
  per-machine env observation, not a repo failure; presence is checked by
  name only, values never printed (anti-leak assert in the fatia-2 suite).

Optional follow-up (not Phase 2A): clean-boot for a strict whole-run PASS.

## 13. Skills Precedence

Documented in `docs/capability-planning-v2.md` §3 (source:
<https://opencode.ai/v2/docs/skills>); no repo change.

Skills resolve by **ID** (path-derived, case-sensitive); on duplicate, the
**last-registered source wins**. Registration order, lowest → highest
precedence: built-in → `.claude/skills` → `.agents/skills` →
**`~/.config/opencode/skills`** → project `.opencode/skills` (root → cwd) →
explicit `skills[]` entries.

Operational consequence: **`~/.config/opencode/skills` beats
`~/.agents/skills`**; the 5 skills-core are installed there (see
`docs/INSTALLATION.md`). Intentional override = duplicate ID in a later
source (project or `skills[]`), never editing the installed file
(uninstall/manifest compares by hash: `KEEP` + warning on divergence).

Related rule: `OPENCODE_CONFIG_CONTENT` is **unsupported/unproven** in the
managed V2 path — file-on-disk (manifest + CAS + checks) is the verified
source; a non-empty env override caps any integrity verdict at
`unproven/blocked` with `config_source=env-override` (planning doc §4,
decisions doc §7).

## 14. Version Pins

**KEEP, no bump.** Single source: `source/registry/runtime-versions.json`
(loader fail-closed `scripts/runtime/lib/RuntimeVersions.ps1`, no literal
fallback):

- V2 `@opencode/cli@2.0.23` (+ `@opencode/plugin@2.0.23`);
  V1 `opencode-ai@1.18.34` (+ `@opencode-ai/plugin@1.18.34`); `bun@1.3.14`.

The observed `2.0.24` runtime in the wild is documented drift, **not** an
auto-bump trigger. Bump = edit only that file **after** smoke/validation on
the exact runtime + human decision with evidence (conservative-flags policy:
flags are born OFF/shadow). Recorded in
`docs/capability-phase2a-decisions.md` §6.

## 15. Test Results

| suite | result |
|---|---|
| package-consistency | **16/16** |
| planning (`capability-planning.tests.ps1`) | **12/12** |
| registry-v2 (`capability-registry-v2.tests.ps1`) | **28/28** |
| coder-perms | **27/27** |
| agent-translation | **116/116** |
| config-format | **51 pass / 2 FAIL — pre-existing, out of scope** (not Phase 2A; no claim otherwise) |

`git diff --check` on this report: clean (§21). No commit from this task.

## 16. Runtime Smoke

- `opencode --version` on the observed machine: **v2.0.24** (drift vs the
  2.0.23 pin, per §14 — smoke evidence, not a pin change).
- `plugin list`: `orchestration-enforcement` present as a local plugin;
  server log shows `loading plugin` + watcher resubscribe with zero new
  `LoadError` after remediation (§4).
- AI Memory MCP healthy throughout the incident window (tools live
  in-session); hooks deliver (spool empty, no 5xx backlog).
- Capability healthcheck: 13 results, 11 healthy (§12).

## 17. Security Verification

- Repo-wide secret scan: **416 files <2MB (`.git` excluded) → false** (no
  secret candidates); launcher + 245 backups → false (§7 table).
- Live `opencode.log` → false (0 lines with the token).
- Healthchecks assert by **name only** (`AI_MEMORY_AUTH_TOKEN`,
  `JEV_API_KEY`/`JEV_BASE_URL`); values never enter output, logs, reports,
  or telemetry. The fatia-2 suite carries the anti-leak assert.
- No secret values appear in this report or in any cited evidence; SHA
  prefixes (§4.2) and boolean tables are the only fingerprints.
- Credential-action policy honored: rotation requested, not self-executed;
  deletion of the 5 documented plaintext locations gated on confirmed
  rotation (§7, Appendix B).

## 18. Residual Risks

1. **Token rotation pending (P0).** Old Bearer treated as compromised until
   the operator revokes/reissues and updates the injection point; 5
   documented plaintext locations await deletion afterwards (§7, §9).
2. **HOLD force-push/docker-prune.** No literal deny rules; covered only by
   broad `ask` on `git push *` / `docker rm *`. Needs explicit rule or a
   recorded accept-`ask` decision (§6, §19).
3. **`config-format` 2 FAILs.** Pre-existing, outside Phase 2A scope; left
   failing honestly, no masking (§15).
4. **Pins without bump.** 2.0.24 observed vs 2.0.23 pinned; bump requires
   exact-runtime validation + human decision (§14).
5. **Dynamic routing not activated.** Router/skill/MCP/adaptive all OFF by
   doctrine; any activation is a future human decision with evidence (§11,
   §20).
6. **`OPENCODE_CONFIG_CONTENT` override.** If ever non-empty, managed-config
   integrity verdicts cap at `unproven/blocked` (§13).
7. **CLI-argv secret leak pattern.** Tokens must never pass as CLI arguments
   (the merged-log line mechanism, §7).
8. **Strict whole-run healthcheck.** Still shows the 15 historical lines;
   optional clean-boot PASS outstanding (§12).

## 19. Deferred to Phase 2B

- Explicit `force-push` / `docker prune` deny rules (or a recorded decision
  that broad `ask` suffices) — closes the §6 HOLD.
- Post-rotation deletion of the 5 plaintext locations + hash re-scan
  (`hits: 0`) + closure annotation with the rotation date (no values) —
  closes P0 residual 1.
- `config-format` 2 FAILs triage (pre-existing; fix or formally accept).
- Optional clean-boot strict whole-run plugin-healthcheck PASS.
- `herdr-agent-state*.disabled` leftovers disposition (currently warnings).

## 20. Deferred to Phase 2C

- Pin bump evaluation for 2.0.24 (exact-runtime smoke/validation + human
  decision; file-only change in `runtime-versions.json`).
- Any dynamic-routing activation (`capability_router` shadow → active,
  `skill_routing`, `mcp_routing`, `adaptive_ranking`) — each a separate
  human decision with evidence; never by inference.
- `MCP tool exposure`/execution enablement (advisory-only status quo holds;
  enforcement belongs to the runtime).
- AI-Memory/MCP contract unification (`AI_MEMORY_AUTH_TOKEN` vs
  `AIMEMORY_REMOTE_TOKEN`) if ever proposed — separate authority decision.
- Upstream issue filing (draft in Appendix A — do NOT open without operator
  authorization).

## 21. Git/PR Evidence

- Branch: `fix/capabilities-phase-2a`; HEAD at closure start: `30e658a`.
  (Working-tree `status`/`diff --stat` were not re-captured inside this
  docs-only task; the owning Planner owns the pre-commit review.)
- This task's write scope: **only**
  `docs/audits/opencode-capabilities-phase-2a-closure-2026-10-06.md`
  (full rewrite absorbing the incident draft). No code, template, agent,
  pin, flag, or registry change.
- `git diff --check`: clean (no whitespace errors introduced).
- No commit performed by this task (per contract — commit/PR is the
  Planner's decision).

## 22. Final Verdict

Phase 2A is **CLOSED with one P0 follow-up owned by the operator**:

- Planning contract documented and tested (17+19+19, 12/12) — PASS.
- Plugin autoload proven; legacy V1 ejected and quarantined; V2 hooks and
  enforcement load clean — PASS.
- Enforcement proven via logs + plugin list + telemetry — PASS.
- Permissions hardened to the safe subset; force-push/docker-prune HOLD
  recorded and deferred — PASS parcial.
- Secrets: repo and launcher clean; live log clean; **token rotation
  PENDING** — PARTIAL, gate opens after rotation + deletion + re-scan.

Gate (same as incident draft, restated): legacy V1 out of the active root
[x]; old token rotated [ ] (operator confirmation pending); zero plaintext
copies [ ] (5 locations documented; deletion gated on rotation);
ai-memory-opencode2 healthy [x]; AI Memory MCP healthy [x]; no new LoadError
[x]; plugin healthcheck PASS since-remediation [x]. Gate opens after
rotation + copy deletion + (optional) clean-boot PASS. Then normal Phase 2B
work (§19) followed by Phase 2C evaluations (§20).

## Appendix A. Upstream (DRAFT — do NOT open without operator authorization)

> Subject: `install-hooks --agent opencode` emits a V1-contract plugin that
> OpenCode >= 2.x refuses to load.
>
> - OpenCode version: 2.0.24 (V2 server).
> - Expected contract: module default export is an object `{ id,
>   effect | setup }`.
> - Generated contract (`--agent opencode`): default export is a bare async
>   function (`Plugin` type from `@opencode-ai/plugin` v1), i.e. the legacy
>   contract.
> - Sanitized loader error: `PluginModule.LoadError: Plugin must export a
>   default definition with an id and an effect or setup function. (cause:
>   SchemaError(Expected object at ["default"]))`.
> - Reproduction: run `install-hooks --agent opencode --apply` with OpenCode
>   2.x, start the server, observe `failed to load plugin` WARNs referencing
>   the file; `plugin: []` does not prevent autodiscovery of `plugins/`.
> - Suggested correction: make `--agent opencode` emit the V2 object shape
>   (as `--agent opencode2` already does), or deprecate/redirect the
>   `opencode` agent target on OpenCode >= 2.x.
>
> No tokens, no personal paths, no private data included above.

## Appendix B. GATE — runbook de rotacao/limpeza (pendente, opcao do operador: detalhar)

Nenhum valor de segredo aparece abaixo nem deve aparecer na execucao:
comparacoes sempre por hash/fingerprint em memoria.

1. Anotar o fingerprint atual (hash apenas, sem imprimir o valor):
   extrair a linha `const TOKEN` da copia em quarentena para memoria,
   computar SHA256 do valor, imprimir SÓ o hash. Guardar como `OLD_HASH`.
2. No servidor AI Memory (operador, via admin do servidor): revogar o
   bearer antigo e emitir um novo. Tratar o antigo como comprometido.
3. Atualizar o ponto de injecao de `AI_MEMORY_AUTH_TOKEN` onde ele
   persiste nesta maquina (env de usuario/maquina ou store do launcher;
   o `invoke-agent.ps1` foi verificado limpo — nao embute valor).
   Nunca colar o valor em chat, log ou arquivo fora do store seguro.
4. (Opcional, recomendado) Restart limpo do servidor OpenCode.
5. Na proxima sessao (agente): revalidar — `plugin-healthcheck.ps1` em
   modo estrito (sem `-Since`, espera-se `PASS` com `load_errors: 0` no
   run novo); fingerprint do token em uso != `OLD_HASH`; MCP e hooks
   saudaveis.
6. Limpeza (apos rotacao confirmada): apagar `archive/plugins-v1/` ×3,
   `backups/merge-20261006/plugins/ai-memory.ts.pre-merge`, e o
   `opencode2-merged-20261006.log` (ou redigir sua linha 69335);
   reexecutar a varredura por hash → `hits: 0`.
7. Anotar neste relatorio a data da rotacao (sem valores) e marcar o
   GATE como aberto.
