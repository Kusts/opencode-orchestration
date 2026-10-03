# IMPLEMENTATION PLAN — Orchestration V3.1 Dual-Runtime Kernel Hardening

**Repository:** `Kusts/opencode-orchestration`  
**Baseline:** `master` @ `78418e790fd08d3f61e8706e7d534504a0965e8c`  
**Revision date:** 2026-09-28  
**Companion SPEC:** `ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md`

**Status de implementação (2026-09-29):** Phases **0–4, 6–7 concluídas**
(commits `2a0218e`→`47e508c`; baseline em
`evidence/v3.1/kernel-hardening/baseline.json`, isolamento XDG provado em
`runtime-isolation-spike.json`) e **Phases 9–19 concluídas** (Task Kernel
CAS com lock interprocesso, grants com interseção, Evidence Contract,
verifier com allowlist fechada, DONE kernel-authorized só de REVIEWING,
leases fail-closed, worktrees com marker ownership, observabilidade com 29
eventos + dimensão runtime, flags shadow rollout — revisadas por Reviewer +
Security Reviewer com 15 findings corrigidos; suítes 75/75, 56/56, 49/49).
**Pendentes:** Phase 5 (enforcement comportamental V2 — spike real travou
em `debug config/agents`, HOLD honesto), Phase 8 (smoke de binário V2 em
CI) e ativação das flags. Estado vivo no `CHANGELOG.md [Unreleased]` e em
`evidence/v3.1/kernel-hardening/implementation-status.json`.

**Continuação (revisão 2026-10-01):** programa de confiabilidade **Phases 21–42** — P21–P25 implementadas e P26–P42 code-complete kernel-side/plugin em 2026-10-02/03, com release gate pendente de evidência do operador (o addendum revisado substitui o desenho anterior P26–P33); evidência em `evidence/v3.1/runtime-reliability/program-status.json` e rastreio por critério em `evidence/v3.1/runtime-reliability/pae-traceability.json`. Plano em `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md` (SPEC em `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md`, execução em `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md`). Fases 0–20 acima preservadas sem alteração.

## 1. Delivery strategy

This is an incremental compatibility + hardening program.

Do not rewrite V3.

Implement runtime abstraction first, then layer the Task Kernel underneath the existing orchestration.

Every phase must leave the repository reviewable and green.

Required roles for this implementation:

- **Planner:** decomposition/integration.
- **Explorer:** maps current installer/render/plugin/agent coupling before edits.
- **Researcher:** re-checks current OpenCode V2 documentation/API whenever a public runtime contract is implemented.
- **Architect:** reviews runtime boundaries, canonical-vs-adapter split, task state and grant model.
- **Coder:** default implementation.
- **Tester:** deterministic validation.
- **Reviewer:** independent review after each major milestone.
- **Security Reviewer:** mandatory for permissions, V2 policies, plugin hooks, config isolation, grants, verifier, leases and worktrees.
- **Debugger:** after two failed attempts on the same defect.
- **Docs Manager:** after behavior stabilizes.

Do not parallelize writers before explicit file ownership.

---

## 2. Phase 0 — Freeze baseline and revalidate upstream V2

### Goal

Establish exact supported versions and eliminate stale beta assumptions.

### Tasks

1. Record repository HEAD.
2. Run current full baseline:
   - package consistency;
   - V3 suites;
   - distribution suites;
   - plugin typecheck;
   - V1 real OpenCode smoke.
3. Re-check official OpenCode V2 docs on implementation day.
4. Record:
   - V1 exact version;
   - V2 exact stable version;
   - V1 CLI package;
   - V2 CLI package;
   - V1 plugin package;
   - V2 plugin package;
   - command names;
   - config locations;
   - supported plugin dual-entrypoint contract.
5. Pin exact versions in CI constants.
6. Do not use `latest`, `next`, `beta` or `dev` in release validation.
7. Update governance from “V2 unsupported” to “V2 support under controlled implementation”.

### Initial expectation

- V1 validated: `opencode-ai@1.18.32`.
- V2: stable `@opencode/cli` `2.0.x`, exact pin chosen by current smoke.
- V2 plugin: exact compatible `@opencode/plugin` pin.

### Exit criteria

- baseline green;
- exact V1/V2 test matrix committed;
- no beta-era package naming left as authority unless still current.

### Suggested commit

`test: freeze V1/V2 compatibility baseline`

---

## 3. Phase 1 — Introduce Runtime Adapter model

### Goal

Stop embedding V1-specific assumptions throughout the package.

### Tasks

1. Extend `source/registry/runtimes.json`.
2. Add runtime metadata for:
   - `opencode-v1`;
   - `opencode-v2`.
3. Add a small runtime detection library:
   - binary path;
   - version;
   - generation;
   - package identity when detectable;
   - supported/unsupported reason.
4. Add `-Runtime Auto|V1|V2|Both` parsing to installer in no-op/dry-run form first.
5. Add adapter interfaces/helpers for:
   - template selection;
   - agent renderer;
   - plugin dependency;
   - runtime smoke;
   - config root.
6. Keep existing V1 path behavior unchanged while adapters are not activated.

### Required tests

- V1 detection;
- V2 detection;
- unsupported version;
- malformed version output;
- both runtimes/ambiguous detection;
- explicit runtime always wins over Auto;
- Auto fails closed when ambiguous.

### Exit criteria

No implementation logic outside the adapter layer should need to guess runtime generation from arbitrary strings.

### Suggested commit

`feat: add OpenCode runtime adapter registry`

---

## 4. Phase 2 — Split V1/V2 configuration templates

### Goal

Render native configuration for each generation.

### Tasks

1. Rename/retain current template as V1:
   - `templates/opencode.v1.json.tmpl`.
2. Add:
   - `templates/opencode.v2.json.tmpl`.
3. V1 template preserves:
   - `agent`;
   - `permission`;
   - `task`;
   - `subagent_depth`.
4. V2 template uses native:
   - `agents`;
   - `permissions`;
   - `subagent`;
   - `shell`;
   - `experimental.subagent_depth`.
5. Preserve `default_agent`.
6. Preserve model pools.
7. Add runtime-specific managed-key lists.
8. Ensure V1 renderer never writes V2-only fields.
9. Ensure V2 renderer does not depend on ignored V1-only fields.
10. Do not manage `cli.json`.

### V2 native rules

Treat ordered permission rule order as security-sensitive.

Broad rule first, narrow exception later.

### Required tests

- V1 template schema/shape;
- V2 template schema/shape;
- V2 no top-level `subagent_depth`;
- V1 no native V2 `agents` takeover;
- model tokens resolved;
- Planner model inheritance behavior verified per runtime;
- user-owned keys preserved.

### Suggested commit

`feat: render native OpenCode V1 and V2 configs`

---

## 5. Phase 3 — Add deterministic agent-frontmatter translation

### Goal

Keep one semantic set of 19 agents while producing native permissions for both runtimes.

### Tasks

1. Inventory every current agent permission shape.
2. Implement deterministic translation:
   - V1 `edit` → V2 `edit`;
   - V1 `bash` → V2 ordered `shell` rules;
   - V1 `task` → V2 `subagent`;
   - allow/ask/deny preserved.
3. Preserve deny precedence.
4. Detect unsupported/ambiguous patterns and fail build.
5. Handle per-agent model fields.
6. Re-evaluate legacy fields such as `temperature`.
7. For each field without a verified native V2 equivalent:
   - map/test;
   - or explicitly omit/document;
   - never silently claim parity.
8. Generate V1/V2 agent outputs into separate render roots.

### Required tests

For all 19 agents:

- same ID;
- same role class;
- same model pool;
- same subagent mode intent;
- same edit intent;
- shell policy equivalent;
- worker subdelegation denied;
- Reviewer/Tester invariants preserved.

Add a snapshot/semantic equivalence test rather than only text snapshots.

### Suggested commit

`feat: translate canonical agents for V1 and V2`

---

## 6. Phase 4 — Port plugin to dual-runtime architecture

### Goal

One logical orchestration-enforcement plugin supports both plugin APIs.

### Tasks

1. Refactor current plugin into shared pure logic:
   - mandate text;
   - identity normalization;
   - sanitization;
   - bounded caches;
   - telemetry normalization.
2. Implement V1 adapter:
   - current V1 hooks;
   - current session lifecycle behavior.
3. Implement V2 adapter:
   - `Plugin.define`;
   - `setup(ctx)`;
   - session context hook for mandate injection;
   - tool hooks;
   - shell hook only where required.
4. Evaluate official dual-export pattern:
   - default export containing V2 `setup()` plus V1 `server()`.
5. Prove V1 module loading when V2 plugin dependency exists.
6. If that packaging is unreliable, use runtime-specific built artifacts with shared pure source.
7. Do not keep two independent copies of mandate/security rules.

### Mandatory runtime tests

V1:

- plugin loads;
- Planner mandate injected;
- worker mandate injected;
- session identity source recorded;
- no duplicate injection.

V2:

- plugin loads;
- context hook injects mandate;
- worker/Planner identity correlated;
- tool hook fires;
- failure does not crash runtime.

### Suggested commit

`feat: make orchestration plugin dual-runtime`

---

## 7. Phase 5 — V2 permissions and hard-policy spike

### Goal

Use V2’s stronger permission/policy primitives correctly.

### Tasks

1. Build fixture agents for:
   - read-only;
   - writer-shell;
   - diagnostic.
2. Test actual V2 resource strings for:
   - `edit`;
   - `shell`;
   - `subagent`;
   - external directory;
   - relevant MCP actions if only observed, not enabled.
3. Test ordered rule precedence.
4. Test saved approval interaction.
5. Test `experimental.policies` hard-deny behavior.
6. Decide which package invariants should receive V2 hard-denies.
7. Keep normal role-specific behavior in agent permissions.
8. Do not add a hard policy without an exact-runtime test.

### Candidate hard-denies

- worker subdelegation;
- force push;
- selected destructive commands;
- control-plane mutation.

### Exit criteria

`docs/PERMISSIONS.md` can accurately distinguish:

- V1 runtime-enforced;
- V2 permission-enforced;
- V2 policy-enforced;
- kernel-enforced;
- planner/prompt-enforced.

### Suggested commit

`test: validate V2 permission and policy enforcement`

---

## 8. Phase 6 — Runtime-aware installer/reconciler

### Goal

Install either runtime safely without breaking ownership.

### Tasks

1. Update `install.ps1` for:
   - `-Runtime V1`;
   - `-Runtime V2`;
   - `-Runtime Auto`.
2. Runtime-specific:
   - config template;
   - agent render;
   - plugin dependency;
   - plugin output;
   - managed-key set;
   - smoke validation.
3. Preserve JSON/JSONC behavior.
4. Preserve backup/rollback.
5. Extend manifest with runtime/profile identity.
6. Update uninstall to target a runtime/profile.
7. Ensure legacy 1.0.0 manifests still uninstall safely.
8. Installer must not replace global OpenCode CLI automatically.

### Required tests

- fresh V1;
- fresh V2;
- repeat V1;
- repeat V2;
- V1 update;
- V2 update;
- V1 uninstall;
- V2 uninstall;
- legacy manifest compatibility;
- user config preservation;
- JSON/JSONC both generations.

### Suggested commit

`feat: make installer runtime-aware`

---

## 9. Phase 7 — Side-by-side isolated profiles

### Goal

Support V1 and V2 on the same machine without config or binary collision.

### Tasks

1. Prove config-home isolation on Windows.
2. Prefer per-process `XDG_CONFIG_HOME` when both exact runtimes honor it.
3. If not, identify another documented/proven per-process mechanism.
4. Create managed profile layout:
   - V1 config root;
   - V2 config root;
   - profile manifests.
5. Add launch wrappers:
   - `opencode-v1.ps1`;
   - `opencode-v2.ps1`.
6. Wrapper chooses exact binary + exact profile.
7. Add `-Runtime Both` to installer only after isolation tests pass.
8. Do not rewrite global environment variables.
9. Do not point V1 at V2-native config.

### Optional runtime provisioning

If desired, add `-ProvisionRuntime` as explicit opt-in.

Private runtime installations must use separate prefixes/paths.

Never overwrite the user’s global `opencode` executable silently.

### Required tests

- launch V1 profile;
- launch V2 profile;
- profile files do not overlap;
- update V1 leaves V2 byte-identical outside shared canonical package state;
- uninstall V1 leaves V2;
- concurrent read-only sessions okay;
- cross-profile config leak test;
- Windows path behavior.

### Suggested commit

`feat: add isolated V1 and V2 runtime profiles`

---

## 10. Phase 8 — Dual-runtime CI lanes

### Goal

Make support claims reproducible.

### CI matrix

#### V1 lane

- pinned `opencode-ai@1.18.32`;
- real CLI smoke;
- V1 plugin typecheck;
- V1 plugin load;
- config/agent/skill validation.

#### V2 lane

- exact stable `@opencode/cli` pin;
- exact compatible `@opencode/plugin` pin;
- real CLI smoke;
- V2 plugin typecheck;
- V2 plugin load;
- V2 config/agent/skill validation;
- permission/policy fixture tests.

#### Dual-profile lane

- install/render Both;
- launch each isolated profile;
- verify no cross-mutation.

### Windows note

Use a proven official V2 installation/standalone-binary mechanism in CI.

Do not assume global npm installation works on Windows merely because it works on Linux.

### Suggested commit

`ci: validate OpenCode V1 V2 and dual profiles`

---

## 11. Phase 9 — Add generic Task Kernel

### Goal

Now that runtime concerns are separated, introduce runtime-neutral persistent task state.

### Tasks

1. Reuse patterns from `CapabilityAuthority`:
   - transition map;
   - CAS;
   - staleness;
   - path confinement;
   - atomic writes.
2. Add:
   - `OrchestrationTaskKernel.ps1`;
   - `task-kernel.ps1`.
3. Operations:
   - create;
   - get;
   - transition;
   - record-result;
   - block;
   - cancel;
   - status.
4. Task records include runtime/profile metadata, but state semantics stay identical.
5. Every mutation requires expected revision.
6. Add terminal state enforcement.

### Required tests

- roundtrip;
- legal/illegal transitions;
- CAS conflict;
- malformed file;
- atomic failure;
- V1 task record;
- V2 task record;
- same transition semantics across generations.

### Suggested commit

`feat: add runtime-neutral CAS-backed task kernel`

---

## 12. Phase 10 — Execution Grants and actor binding

### Goal

Separate routing relevance from execution authority.

### Tasks

1. Add `execution-grants.json`.
2. Define baseline grants per role.
3. Implement effective grant intersection.
4. Normalize V1/V2 identity sources.
5. Bind stages to allowed actors.
6. Unknown identity cannot claim privileged transitions.
7. V1 adapter maps grants to available V1 primitives.
8. V2 adapter maps grants to permissions/policies/plugin checks.
9. No runtime may widen canonical grants.

### Security review checkpoint

Mandatory Security Reviewer approval.

### Suggested commit

`feat: add cross-runtime execution grants`

---

## 13. Phase 11 — Evidence Contract

### Goal

Make worker success non-authoritative.

### Tasks

1. Add candidate result schema.
2. Status:
   - `candidate_pass`;
   - `failed`;
   - `blocked`.
3. Separate claimed and verified evidence.
4. Require task/revision identity.
5. Reject writer-side final completion claims.
6. Update all writer agents through canonical source, then render both runtimes.

### Required tests

Same evidence semantics under V1 and V2.

### Suggested commit

`feat: add candidate evidence contract`

---

## 14. Phase 12 — Deterministic verifier

### Goal

Verify work independently of worker claims.

### Tasks

1. Add `verification-policy.json`.
2. Implement verifier.
3. Validate:
   - actual Git diff;
   - write scope;
   - base revision;
   - tests;
   - lint;
   - typecheck;
   - build.
4. Closed allowlist for executable validations.
5. Unknown/unsafe command returns manual/agent verification required.
6. No arbitrary shell from task JSON.
7. Same verifier behavior regardless of V1/V2.

### Required tests

- false worker pass;
- out-of-scope write;
- denied shell;
- timeout;
- sanitized evidence;
- V1/V2 parity.

### Suggested commit

`feat: add cross-runtime deterministic verification`

---

## 15. Phase 13 — Kernel-owned DONE and retry budget

### Goal

Make completion deterministic.

### Tasks

1. Keep `Test-OrchestrationDoneCompliance`.
2. Add `Test-OrchestrationTaskCompletion`.
3. Only `Complete-OrchestrationTask` may persist DONE.
4. Add attempt history.
5. Second failure requires Debugger.
6. Third attempt requires new evidence/hypothesis/strategy.
7. Else EXHAUSTED.
8. Same behavior V1/V2.

### Suggested commit

`feat: make DONE kernel-authorized`

---

## 16. Phase 14 — Write leases

### Goal

Prevent concurrent writer conflicts, including across runtime generations.

### Tasks

1. Add `OrchestrationOwnership.ps1`.
2. Leases under `cache/runtime/locks`.
3. Include runtime/profile/task/base SHA.
4. Overlap detection is runtime-independent.
5. V1 and V2 tasks conflict when scopes overlap.
6. Add acquire/release/recovery.

### Required tests

- V1 writer vs V2 writer same scope → conflict;
- disjoint scopes → allowed;
- stale/expired recovery;
- ownership-protected release.

### Suggested commit

`feat: add cross-runtime write leases`

---

## 17. Phase 15 — Worktree isolation

### Goal

Safely enable parallel writers.

### Tasks

1. Add `OrchestrationWorktree.ps1`.
2. Task-scoped deterministic branch/path.
3. Parallel writers require isolated worktrees.
4. Runtime adapter launches task session in selected worktree.
5. Cleanup is ownership-aware.
6. Windows path constraints tested.
7. Never use broad destructive cleanup.

### Suggested commit

`feat: isolate parallel writers with task-owned worktrees`

---

## 18. Phase 16 — Bind kernel to V1/V2 runtime hooks

### Goal

Use each runtime’s strongest proven enforcement primitives.

### V1

Validate and use:

- current permission maps;
- plugin tool hook if reliable;
- session identity;
- kernel state.

### V2

Validate and use:

- native permissions;
- hard policies where proven;
- `ctx.tool.hook("execute.before")`;
- session/context identity;
- kernel state.

### Rule

If a runtime hook cannot reliably block an operation, do not claim it does.

Record HOLD and rely on the next strongest layer.

### Required tests

- missing task;
- wrong actor;
- out-of-scope write;
- read-only write;
- denied high-risk operation;
- telemetry failure;
- malformed identity.

### Suggested commit

`feat: bind task grants to V1 and V2 runtime enforcement`

---

## 19. Phase 17 — Planner/worker contract integration

### Goal

Make the same orchestration protocol active on both generations.

Canonical flow:

```text
preflight
 -> create task
 -> plan scope/grants
 -> acquire lease/worktree
 -> dispatch
 -> candidate result
 -> deterministic verify
 -> tester
 -> reviewer
 -> security review when triggered
 -> completion gate
 -> cleanup
 -> DONE
```

Tasks:

- update canonical Planner policy;
- update canonical worker result contract;
- render V1/V2 forms;
- package consistency checks compare semantic invariants.

### Suggested commit

`docs: integrate dual-runtime task kernel contracts`

---

## 20. Phase 18 — Observability

### Goal

One telemetry model, runtime dimension included.

Extend current observability with:

- `runtime_id`;
- `runtime_generation`;
- `runtime_version`;
- `profile`.

Events:

- TASK_CREATED;
- TASK_STATE_CHANGED;
- LEASE_ACQUIRED;
- LEASE_CONFLICT;
- WORKTREE_CREATED;
- CANDIDATE_RESULT_RECORDED;
- VERIFICATION_STARTED;
- VERIFICATION_PASSED;
- VERIFICATION_FAILED;
- REVIEW_APPROVED;
- REVIEW_CHANGES_REQUIRED;
- TASK_EXHAUSTED;
- TASK_DONE.

No second telemetry framework.

### Suggested commit

`feat: add runtime-aware task observability`

---

## 21. Phase 19 — Shadow rollout

### Goal

Validate new behavior before default enforcement.

Initial flags:

```json
{
  "runtime_support": {
    "v1": true,
    "v2": false,
    "dual_profile": false
  },
  "task_kernel": {
    "enabled": false,
    "shadow": true
  },
  "worktree_isolation": {
    "enabled": false
  },
  "runtime_grant_enforcement": {
    "v1": false,
    "v2": false
  }
}
```

Activation sequence:

1. V2 renderer + smoke;
2. V2 plugin;
3. V2 installer profile;
4. dual profile;
5. Task Kernel;
6. verifier/DONE;
7. leases/worktrees;
8. runtime grant enforcement.

Each activation requires evidence.

### Suggested commit

`feat: add dual-runtime shadow rollout gates`

---

## 22. Phase 20 — Release hardening

### Run all existing suites

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1
```

Plus:

- V1 renderer suite;
- V2 renderer suite;
- semantic agent parity suite;
- V1 plugin typecheck/load;
- V2 plugin typecheck/load;
- V1 real smoke;
- V2 real smoke;
- dual profile isolation;
- Task Kernel;
- verifier;
- grants;
- lease;
- worktree;
- installer upgrade/uninstall matrix.

### Independent reviews

Reviewer:

- correctness;
- compatibility;
- duplicated logic;
- overengineering;
- state transitions;
- error handling.

Security Reviewer:

- permission translation;
- V2 policy precedence;
- plugin module loading;
- config isolation;
- shell verifier;
- grants;
- identity;
- leases;
- worktrees;
- secret handling.

### Release evidence

Record exact:

- repository implementation SHA;
- V1 runtime version/package;
- V2 runtime version/package;
- V1 plugin package;
- V2 plugin package;
- OS/PowerShell matrix;
- test counts;
- side-by-side mechanism;
- known parity deviations;
- runtime hooks actually enforced;
- feature flag state.

### Suggested release

`1.1.0` if all changes remain backward-compatible.

---

## 23. Recommended commit sequence

1. `test: freeze V1/V2 compatibility baseline`
2. `feat: add OpenCode runtime adapter registry`
3. `feat: render native OpenCode V1 and V2 configs`
4. `feat: translate canonical agents for V1 and V2`
5. `feat: make orchestration plugin dual-runtime`
6. `test: validate V2 permission and policy enforcement`
7. `feat: make installer runtime-aware`
8. `feat: add isolated V1 and V2 runtime profiles`
9. `ci: validate OpenCode V1 V2 and dual profiles`
10. `feat: add runtime-neutral CAS-backed task kernel`
11. `feat: add cross-runtime execution grants`
12. `feat: add candidate evidence contract`
13. `feat: add cross-runtime deterministic verification`
14. `feat: make DONE kernel-authorized`
15. `feat: add cross-runtime write leases`
16. `feat: isolate parallel writers with task-owned worktrees`
17. `feat: bind task grants to V1 and V2 runtime enforcement`
18. `docs: integrate dual-runtime task kernel contracts`
19. `feat: add runtime-aware task observability`
20. `feat: add dual-runtime shadow rollout gates`
21. `docs: close V3.1 dual-runtime release evidence`

Keep commits separable during implementation. Final merge strategy can squash later.

---

## 24. Agent implementation constraints

- Inspect before editing.
- Re-check official V2 docs before coding runtime contracts.
- Treat the current SPEC version pins as baseline, not permission to use stale package names.
- Preserve PS 5.1 compatibility for package scripts unless a specific V2-only helper is isolated and documented.
- Do not make the canonical orchestration V2-specific.
- Do not duplicate 19 agents manually.
- Do not rely on V2 legacy-normalization as the final native V2 implementation.
- Do not convert shared V1 user config to V2 native format.
- Do not modify `cli.json` by default.
- Do not replace the user’s global `opencode` binary automatically.
- Do not broaden `deny` to `ask` or `allow` for compatibility.
- Do not activate MCP routing/adaptive ranking.
- Do not introduce V4.
- Do not add a daemon/database.
- Do not invent runtime hook behavior.
- Any runtime-enforcement claim requires an exact-runtime integration test.
- Any file mutation needs failure-path tests.
- Any state mutation needs CAS/staleness tests.
- Any permission translator needs semantic parity tests.
- After two failed fixes on the same issue, use Debugger with new evidence.
- Architectural uncertainty goes to Architect.

---

## 25. Final Definition of Done

The implementation is complete only when:

- V1 is still green on the pinned baseline;
- V2 is green on an exact stable 2.x pin;
- native runtime renderers are in place;
- all 19 agents preserve semantic role/permission invariants;
- dual plugin loads on both generations;
- installer supports V1 and V2 explicitly;
- dual profiles safely isolate V1 and V2 where `Both` is advertised;
- uninstall/upgrade is runtime-aware;
- Task Kernel is CAS-backed;
- DONE is kernel-authorized;
- verifier is allowlisted;
- write leases and worktrees control concurrency;
- runtime enforcement is accurately documented per generation;
- all old V3/distribution tests remain green;
- Reviewer approves;
- Security Reviewer has no unresolved high/critical finding;
- release evidence lists exact tested versions and limitations.

---

## 26. Continuação — Reliability Phases 21–42 (revisão 2026-10-01; P21–P25 implementadas)

O programa de confiabilidade (bounded execution, watchdog, loop guard, Planner/subagent supervision, port preflight V2, MCP safety/circuit breaker, AI Memory remoto, Jev consultivo, bootstrap persistente, Task/Run/Seat/Session, reconciler + continuation envelope, execution modes, evidence reuse, validação adaptativa, capability doctor, V2 native, evolution, lane E2E Windows V2, rollout) está especificado e planejado **fora deste plano**, sem reabrir as Phases 0–20:

- SPEC: `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-SPEC-ADDENDUM.md` (critérios `PAE-01`–`PAE-40`, que substituem os `RR-01`–`RR-20` do desenho anterior; Definition of Done — evidência dos critérios rastreada em `evidence/v3.1/runtime-reliability/pae-traceability.json`, com itens ainda `activation-pending`/`blocked-operator-evidence` no release gate).
- Plano: `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-PLAN-ADDENDUM.md` (Phases 26–42 + constraints + Definition of Done final; o desenho anterior P26–P33 foi substituído pela revisão 2026-10-01).
- Execução: `ORCHESTRATION-V3.1-RUNTIME-RELIABILITY-IMPLEMENTATION-PROMPT.md` (ordem de implementação, gates de Reviewer/Security Reviewer).

Estado: P21–P25 implementadas e P26–P42 code-complete kernel-side/plugin em 2026-10-02/03 (evidência em `evidence/v3.1/runtime-reliability/program-status.json`, matriz `PAE-01`–`PAE-40` em `evidence/v3.1/runtime-reliability/pae-traceability.json`); release gate pendente de evidência do operador, sem ativação de flag; critérios PAE-01–PAE-40 substituem RR-01–RR-20.

Limites honestos: nenhum enforcement de watchdog/loop guard existe; AI Memory permanece com listener local (migração para VPS planejada, não executada); roteamento MCP genérico segue desligado.
