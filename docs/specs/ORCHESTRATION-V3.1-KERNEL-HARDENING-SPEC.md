# SPEC — Orchestration V3.1 Dual-Runtime Kernel Hardening

**Repository:** `Kusts/opencode-orchestration`  
**Baseline:** `master` @ `78418e790fd08d3f61e8706e7d534504a0965e8c`  
**Revision date:** 2026-09-28  
**Target release:** preferably `1.1.0` if backward compatibility is preserved  
**Status:** Em implementação — Phases 0–4, 6–7 (dual-runtime) e 9–19 (Task Kernel, grants, Evidence Contract, verifier, DONE kernel, leases, worktrees, binding records, contrato, observabilidade, flags) implementadas, revisadas (Reviewer + Security Reviewer, 15 findings corrigidos) e verdes (2026-09-29). Phase 5: harness pronto; enforcement comportamental V2 pendente (HOLD honesto). Phase 8: lane CI adicionada; smoke de binário V2 pendente. Phase 20: evidência registrada em `evidence/v3.1/kernel-hardening/implementation-status.json`. Flags de rollout OFF por padrão.  
**Change class:** `RUNTIME_COMPATIBILITY` + `FEATURE_REEVALUATION` + `AUTHORITY_HARDENING`

## 0. Primary objective

Evolve the current V3 orchestration into a deterministic task/workflow kernel **while making OpenCode V1 and OpenCode V2 first-class supported runtimes**.

The project MUST preserve the current V1 support and add native V2 support without:

- turning V2 into the only runtime;
- forcing V1 users to migrate;
- sharing incompatible native configuration between V1 and V2;
- duplicating the orchestration logic into two independent implementations;
- weakening security or permissions to obtain compatibility.

The intended architecture is:

```text
                         CANONICAL ORCHESTRATION
                   policies / agents / registry / kernel
                                  |
                    +-------------+-------------+
                    |                           |
                    v                           v
              Runtime Adapter V1          Runtime Adapter V2
                    |                           |
        V1 config / permissions /     V2 config / permissions /
            plugin contract              policies / plugin API
                    |                           |
                    +-------------+-------------+
                                  |
                         Same task semantics
                         Same agent semantics
                         Same DONE semantics
```

The orchestration behavior is canonical. Runtime-specific syntax and hooks are adapters.

---

## 1. Verified runtime facts that shape this SPEC

At the time of this revision:

### OpenCode V1

Current project baseline:

- runtime package: `opencode-ai`;
- validated runtime: `1.18.32`;
- command: `opencode`;
- plugin package: `@opencode-ai/plugin@1.18.32`;
- V1 config uses forms such as:
  - `agent`;
  - `permission`;
  - `bash`;
  - `task`;
  - top-level `subagent_depth`.

V1 remains fully supported.

### OpenCode V2

Current stable V2 line is `2.0.x`.

Initial implementation/CI pin SHOULD be the current validated V2 release at implementation time. At SPEC revision time, `@opencode/plugin` was already in the `2.0.x` line; do not use a moving beta/dev tag.

V2 uses:

- CLI package: `@opencode/cli`;
- command: `opencode`;
- plugin package/API: `@opencode/plugin`;
- configuration still reads `opencode.json(c)` from standard OpenCode locations;
- agent configuration uses native `agents`;
- permissions use native `permissions` ordered rules;
- V2 permission action names include `shell` and `subagent` instead of V1 `bash` and `task`;
- native subagent depth lives under `experimental.subagent_depth`;
- CLI/TUI-only configuration lives in global `cli.json`;
- V2 has `experimental.policies`, which can hard-deny permission resources and only tighten authority;
- V2 plugin API uses `Plugin.define({ id, setup(ctx) })` and domain hooks;
- V1 plugin implementations do not run unchanged under V2.

### Coexistence consequence

V1 and V2 now both use the `opencode` command and the same default configuration locations. They are not safely side-by-side **by default**.

Therefore this project MUST NOT implement “dual support” by pointing both runtimes at one native V2 config or by letting one global installation overwrite the other.

---

## 2. Current repository strengths to preserve

The current repository already has:

- one Planner (`build`) as control plane;
- 19 specialized workers;
- shallow hierarchy;
- mandatory orchestration preflight;
- deterministic fallback;
- `coder → tester → reviewer`;
- Dispatch Contract;
- capability registry;
- deterministic/advisory routing;
- shadow/eval/activation machinery;
- sanitized observability;
- OpenCode permission hardening;
- installer ownership;
- release/distribution suites;
- `CapabilityAuthority` with:
  - explicit state machine;
  - CAS;
  - staleness checks;
  - human approval;
  - verified rollback.

V3.1 MUST reuse these primitives rather than creating a separate framework.

---

## 3. Main problems to solve

### P-01 — Single-runtime packaging

The repository currently rejects V2 and renders only V1 syntax.

### P-02 — Runtime syntax is mixed into canonical source

Agent frontmatter and templates currently contain V1-specific permission/config syntax.

### P-03 — Plugin contract is V1-only

The current plugin imports `@opencode-ai/plugin` and implements the V1 hook model.

### P-04 — Default config paths collide

A native V2 conversion can become unreadable or behaviorally different for V1. Shared global configuration cannot be the basis of simultaneous V1/V2 operation.

### P-05 — Task state is still mostly policy-driven

Normal task lifecycle does not yet have an authoritative persistent task record with CAS.

### P-06 — Worker success is self-reported

Worker `PASS`/`APPROVED`/success is useful evidence but is not deterministic proof.

### P-07 — Concurrent writers lack hard ownership

`WRITE_SCOPE` and `BASE_REVISION` are documented but not backed by leases/worktree ownership.

### P-08 — Routing capability and execution authority are not yet separate enough

A worker being relevant to a task must not automatically grant the ability to perform high-risk operations.

---

## 4. Architecture principles

### A1 — One canonical orchestration model

There is one semantic model for:

- agents;
- role classes;
- task lifecycle;
- capabilities;
- grants;
- retries;
- evidence;
- DONE.

V1/V2 adapters only translate runtime syntax and runtime hooks.

### A2 — Planner is intelligent; Kernel is authoritative

Planner decides strategy. Kernel owns task state and final completion.

### A3 — Candidate result is not verified result

Worker claims are inputs to verification.

### A4 — Routing capability is not execution authority

Capability Router answers “who/what is relevant”. Execution Grants answer “what is authorized”.

### A5 — Native runtime rendering

Do not rely on V2’s legacy V1 normalization as the permanent implementation. V2 MUST receive a native V2 render.

Compatibility translation may be used only as a migration/bootstrap aid.

### A6 — No silent cross-runtime mutation

V1 artifacts and V2 artifacts have explicit ownership and runtime identity.

### A7 — Fail closed on ambiguous runtime

If both runtimes/config profiles are available and the installer cannot safely identify the intended target, require explicit runtime selection.

### A8 — Runtime claims require runtime tests

No hook/permission/policy capability is called “enforced” without a test against the exact supported runtime.

### A9 — V1 remains first-class

V2 work cannot degrade or deprecate V1 in this release.

### A10 — No new daemon/database

Task state remains local and file-based.

---

## 5. Runtime support matrix

The project MUST publish an explicit matrix similar to:

| Runtime | Support | Validation baseline | Config mode | Plugin mode |
|---|---|---:|---|---|
| OpenCode V1 | Supported | `opencode-ai@1.18.32` | native V1 | V1 `server()`/hook adapter |
| OpenCode V2 | Supported | pinned stable `2.0.x` | native V2 | V2 `Plugin.define/setup()` adapter |
| V1 + V2 same machine | Supported through isolated profiles | both baselines | separate managed roots | same canonical plugin logic, runtime adapters |

Rules:

- “Supported” requires real-runtime smoke.
- Exact tested versions are documented in release evidence.
- A newer untested 2.x may be “expected compatible”, never “validated” until CI passes.
- Moving tags such as `latest`, `next`, `beta`, `dev` MUST NOT be used in reproducible CI/release evidence.

---

## 6. Runtime Adapter layer

Add a runtime abstraction.

Suggested canonical files:

```text
source/
  adapters/
    opencode-v1.md
    opencode-v2.md
  registry/
    runtimes.json
    runtime-mapping.json
```

Suggested renderer outputs:

```text
generated/
  opencode/
    v1/
      opencode.json
      AGENTS.md
      agents/
      skills/
      plugins/
    v2/
      opencode.json
      AGENTS.md
      agents/
      skills/
      plugins/
```

Runtime adapter responsibilities:

- config field translation;
- permission translation;
- agent frontmatter translation;
- plugin installation/runtime contract;
- runtime-specific smoke commands;
- feature detection;
- config root;
- CLI package/binary identity;
- supported hard-enforcement primitives.

Kernel/business logic MUST NOT branch on arbitrary version checks everywhere. Runtime differences go through the adapter.

---

## 7. Runtime descriptor

Extend `source/registry/runtimes.json` or introduce an equivalent canonical structure.

Minimum logical shape:

```json
{
  "opencode-v1": {
    "generation": 1,
    "supported": true,
    "validated_version": "1.18.32",
    "cli_package": "opencode-ai",
    "plugin_package": "@opencode-ai/plugin",
    "config_dialect": "v1",
    "permission_dialect": "v1",
    "plugin_api": "v1",
    "command": "opencode"
  },
  "opencode-v2": {
    "generation": 2,
    "supported": true,
    "validated_version": "2.0.x-pinned",
    "cli_package": "@opencode/cli",
    "plugin_package": "@opencode/plugin",
    "config_dialect": "v2",
    "permission_dialect": "v2",
    "plugin_api": "v2",
    "command": "opencode"
  }
}
```

The exact V2 pin is updated by implementation after a real smoke test.

---

## 8. Canonical agent representation

The semantic definition of an agent must remain single-source.

Do NOT maintain two manually duplicated sets of 19 agents.

The renderer MUST derive V1/V2 runtime frontmatter from one canonical definition.

A canonical agent needs at least:

- id;
- description;
- mode;
- model pool;
- role class;
- routing capabilities;
- forbidden capabilities;
- edit authority;
- shell policy;
- subagent authority;
- risk class;
- body/system instructions.

Existing `source/agents/*.md` may remain the semantic source if the renderer can deterministically extract the V1 permission intent and produce V2 rules. A later cleanup MAY move permission semantics into a separate registry, but the implementation must avoid a large unrelated rewrite.

---

## 9. V1 ↔ V2 config mapping

The runtime renderer MUST explicitly handle at least:

| Semantic concept | V1 | V2 |
|---|---|---|
| agent map | `agent` | `agents` |
| agent permissions | `permission` | `permissions` |
| shell action | `bash` | `shell` |
| subagent action | `task` | `subagent` |
| subagent depth | `subagent_depth` | `experimental.subagent_depth` |
| plugin package/API | `@opencode-ai/plugin` | `@opencode/plugin` |
| plugin contract | returned hook object / V1 adapter | `Plugin.define` + `setup` |
| CLI/TUI config | V1 TUI files where applicable | global `cli.json` |
| hard policy layer | no V2 policy equivalent | `experimental.policies` |

### Sampling/options caveat

V2 does not accept every legacy per-agent field as native configuration in the same way.

The renderer MUST NOT silently claim behavioral parity for fields such as legacy agent-level sampling options unless verified.

For each such field:

1. map to a supported V2 equivalent and test it; or
2. omit it with an explicit compatibility note; or
3. preserve legacy syntax only if V2’s documented compatibility path is intentionally selected and tested.

No silent semantic loss.

---

## 10. Permission translation

### V1 source semantics

Current V1 examples:

```yaml
permission:
  edit: deny
  bash:
    "*": deny
    "git status *": allow
  task: deny
```

### Native V2 output

Equivalent semantic form:

```yaml
permissions:
  - action: edit
    resource: "*"
    effect: deny
  - action: shell
    resource: "*"
    effect: deny
  - action: shell
    resource: "git status *"
    effect: allow
  - action: subagent
    resource: "*"
    effect: deny
```

Rule order matters in V2 because the last matching rule wins.

The translator MUST preserve the intended precedence.

### Non-negotiable invariants

Across both runtimes:

- workers cannot create subagents;
- read-only agents cannot edit;
- Tester cannot edit application code;
- Reviewer and Security Reviewer stay independent/read-only;
- high-risk writer shell operations remain denied/ask according to policy;
- no compatibility fallback may replace a `deny` with an `ask`.

---

## 11. V2 hard policies

V2 supports `experimental.policies` that can hard-deny permission checks after ordinary agent permissions and saved approvals.

Use this only for **global invariants**, not ordinary role routing.

Candidate invariants:

- worker subdelegation;
- force-push;
- selected destructive filesystem actions where resource matching is reliable;
- secret-sensitive resources where safe matching exists;
- control-plane mutation.

Rules:

- V2 policies only tighten authority.
- The canonical policy must still have a V1 equivalent through permission denies/kernel/plugin enforcement.
- The V2 adapter may be stricter than V1 when the runtime provides stronger primitives, but this difference must be documented.
- Do not invent policy matches that have not been tested against V2’s actual resource strings.

---

## 12. Dual-runtime plugin architecture

Prefer **one logical plugin package/source** with separate runtime implementations and shared pure logic.

Official V2 guidance supports a default export containing:

- V2 `setup()` / `Plugin.define(...)`;
- V1 `server()`.

Our implementation SHOULD follow that pattern because V1 baseline `1.18.32` is new enough for the dual-entrypoint model.

Suggested layout:

```text
plugins/
  orchestration-enforcement/
    index.ts
    shared/
      identity.ts
      mandate.ts
      sanitize.ts
      task-policy.ts
    v1.ts
    v2.ts
```

If the local plugin loader requires a single file in one runtime, the build/renderer may emit the proper entry file. The canonical implementation remains shared.

### V1 adapter

Responsible for current V1 behavior:

- session identity/event tracking;
- system mandate injection;
- telemetry;
- V1 `tool.execute.before` where supported;
- V1 hook shape.

### V2 adapter

Use native V2 APIs:

- `Plugin.define({ id, setup(ctx) })`;
- session/context hook for mandate injection;
- `ctx.tool.hook("execute.before", ...)`;
- `ctx.tool.hook("execute.after", ...)` as needed;
- `ctx.shell.hook("create.before", ...)` only when needed;
- permission/policy hooks only when the public V2 API explicitly supports the required contract.

### Shared logic

Must contain no V1/V2 API objects. It operates on normalized internal events.

---

## 13. Plugin compatibility rule

Do not import V1-only APIs in the V2 execution path.

Do not import V2-only APIs in a way that causes V1 runtime module-load failure.

The implementation must choose one of these proven packaging strategies:

1. official dual-export pattern with dependencies available to both runtimes; or
2. build-time/runtime-specific entrypoints sharing pure internal modules.

The decision is made by real V1/V2 load tests, not preference.

---

## 14. Side-by-side support

The project MUST support users who want V1 and V2 on the same machine.

Because both runtimes use the same command and default config location, side-by-side support requires **isolated runtime profiles**.

Suggested managed area:

```text
~/.opencode-orchestration/
  profiles/
    v1/
      config/
      runtime/
      manifest.json
    v2/
      config/
      runtime/
      manifest.json
  bin/
    opencode-v1.ps1
    opencode-v2.ps1
```

### Required behavior

`opencode-v1.ps1`:

- selects the V1 exact executable;
- points it at the V1 isolated config root;
- never loads native V2-only config.

`opencode-v2.ps1`:

- selects the V2 exact executable;
- points it at the V2 isolated config root;
- never mutates V1 profile files.

### Isolation mechanism

Implementation MUST first prove the supported config-root isolation mechanism on Windows and in CI.

Preferred mechanism:

- `XDG_CONFIG_HOME` if both runtimes honor it correctly.

Allowed fallback:

- another documented/proven per-process config-home mechanism.

Do not globally rewrite `USERPROFILE` or machine environment variables.

If safe isolation cannot be proven for a platform, `-Runtime Both` MUST fail with a clear diagnostic rather than sharing incompatible config.

---

## 15. Installer interface

Evolve `install.ps1` to support:

```powershell
.\install.ps1 -Runtime Auto
.\install.ps1 -Runtime V1
.\install.ps1 -Runtime V2
.\install.ps1 -Runtime Both
```

Optional explicit profile/root controls may be added if needed.

### `Auto`

- detects a single unambiguous runtime and targets it;
- if runtime is ambiguous, fail closed and request `-Runtime`.

### `V1`

- render/apply V1-native artifacts;
- install/validate V1 plugin dependency;
- preserve current behavior.

### `V2`

- render/apply V2-native artifacts;
- install/validate V2 plugin dependency;
- use V2 permissions/config semantics.

### `Both`

- uses isolated managed profiles;
- never overlays V1 and V2 native config into the same file;
- may provision private runtime binaries only with explicit opt-in.

The installer SHOULD configure existing runtimes by default rather than unexpectedly replacing the user’s global OpenCode binary.

---

## 16. Uninstall/upgrade ownership

Manifest schema must become runtime-aware.

Example:

```json
{
  "package_version": "1.1.0",
  "profiles": {
    "v1": {
      "runtime": "opencode-v1",
      "managed_paths": [],
      "config_snapshot": {}
    },
    "v2": {
      "runtime": "opencode-v2",
      "managed_paths": [],
      "config_snapshot": {}
    }
  }
}
```

Requirements:

- uninstall V1 does not touch V2;
- uninstall V2 does not touch V1;
- uninstall Both removes only package-owned artifacts in both profiles;
- user-owned files remain preserved;
- upgrades are idempotent per runtime;
- config-format switching remains safe.

---

## 17. CLI configuration ownership

V2 `cli.json` is terminal-client configuration, not normal server/project configuration.

The package MUST NOT take ownership of `cli.json` unless a concrete orchestration requirement exists.

Default:

- preserve it entirely;
- do not create/modify it merely because V2 exists.

If a future feature requires CLI-only config, manage only explicit owned fields with backup/rollback semantics.

---

## 18. Task Kernel

Canonical runtime state lives outside V1/V2 config.

Path:

`cache/runtime/tasks/<TASK_ID>.json`

Minimum task semantics remain runtime-neutral.

The record includes:

- schema version;
- task id;
- parent task id;
- trace id;
- objective/type/risk;
- state;
- revision;
- orchestration decision;
- actor/current owner;
- runtime generation/profile;
- base revision;
- read/write scopes;
- grants;
- environment authorization;
- acceptance criteria;
- expected artifacts;
- attempt budget;
- worker result;
- deterministic verification;
- review/security review;
- workspace/worktree;
- history.

Example runtime block:

```json
{
  "runtime": {
    "id": "opencode-v2",
    "generation": 2,
    "profile": "v2",
    "version": "2.0.x"
  }
}
```

Task semantics must not change based on generation.

---

## 19. Task states

Canonical states:

- `DISCOVERING`
- `PLANNING`
- `IMPLEMENTING`
- `VALIDATING`
- `REVIEWING`
- `FIXING`
- `BLOCKED`
- `EXHAUSTED`
- `DONE`
- `CANCELLED`

Only the Task Kernel persists transitions.

Every mutation requires `expected_revision`.

Stale writes produce `CAS_CONFLICT`.

Illegal transitions produce `ILLEGAL_TRANSITION`.

`DONE` cannot be written by a generic transition call.

---

## 20. Actor identity

Normalized identity sources:

- `runtime-v1-session-map`;
- `runtime-v1-input-probe`;
- `runtime-v2-session-context`;
- `runtime-v2-tool-event`;
- `explicit-cli`;
- `unknown`.

Privileged claims require a trusted identity source.

The identity layer normalizes runtime-specific session structures before they reach kernel logic.

---

## 21. Execution Grants

Execution Grants are runtime-neutral.

Initial set:

- `fs.read`
- `fs.write`
- `shell.validation`
- `shell.diagnostic`
- `git.diff`
- `git.commit`
- `git.branch`
- `git.worktree`
- `git.push`
- `docs.write`
- `db.migration.create`
- `deploy.staging`
- `deploy.production`
- `secrets.reference`
- `secrets.read`
- `destructive.fs`

Effective authority:

```text
role baseline
INTERSECT task grants
INTERSECT runtime adapter capability
INTERSECT runtime permission/policy result
INTERSECT environment authorization
INTERSECT human approval when required
```

Never union.

---

## 22. Evidence Contract

Writer status vocabulary:

- `candidate_pass`
- `failed`
- `blocked`

Writers MUST NOT authoritatively emit:

- `verified_pass`;
- final `done`;
- final approval.

Claimed evidence is distinct from verified evidence.

---

## 23. Deterministic verifier

Add `OrchestrationVerifier.ps1`.

Responsibilities:

- actual Git diff;
- scope verification;
- base/workspace freshness;
- allowlisted tests/lint/typecheck/build;
- sanitized evidence;
- acceptance evidence mapping;
- verification status.

Verifier commands are selected through `verification-policy.json`, not arbitrary worker-supplied shell.

Unknown command classes fail closed.

---

## 24. Runtime-specific verification

The verifier itself is runtime-neutral for project code.

Runtime compatibility checks are separate profiles:

### V1 smoke

Must validate:

- version;
- config load;
- default Planner;
- agent discovery;
- permission behavior;
- skill discovery;
- plugin load;
- mandate injection;
- worker subdelegation denial;
- task kernel integration where active.

### V2 smoke

Must validate:

- exact V2 version;
- native V2 config;
- `agents` load;
- native `permissions`;
- `experimental.subagent_depth`;
- skills;
- dual-runtime plugin V2 path;
- context/mandate injection;
- subagent permissions;
- hard policies where enabled;
- task kernel integration.

---

## 25. DONE gate

`Test-OrchestrationDoneCompliance` remains a participation subcheck.

Add a higher-level `Test-OrchestrationTaskCompletion`.

DONE requires:

1. orchestration compliance;
2. valid runtime/profile;
3. worker participation when required;
4. legal state history;
5. no CAS conflict;
6. no ownership conflict;
7. candidate result recorded;
8. deterministic verification passed;
9. acceptance criteria evidenced;
10. Reviewer approved;
11. Security Reviewer approved when triggered;
12. no unresolved blockers;
13. retry budget valid;
14. base/workspace fresh;
15. residual risks recorded.

Only `Complete-OrchestrationTask` writes DONE.

---

## 26. Retry/escalation

Preserve current semantics:

- first failure: reassess/narrow;
- second failure: Debugger required;
- architectural uncertainty: Architect;
- third attempt only with new evidence/hypothesis/strategy;
- otherwise `EXHAUSTED`.

Same policy on V1 and V2.

---

## 27. Ownership and leases

Add task write leases under:

`cache/runtime/locks/`

Lease includes runtime/profile because two isolated runtime profiles may work on the same repository.

Overlapping write scopes conflict regardless of runtime generation.

Two runtimes MUST NOT concurrently write the same scope just because they use separate config profiles.

---

## 28. Worktree isolation

Worktree isolation is canonical and independent of OpenCode generation.

Required for parallel writers.

Recommended for medium/high-risk code-writing tasks.

Runtime adapter receives the selected task worktree as execution directory.

Cleanup is task-owned and never broad/destructive.

---

## 29. V1/V2 runtime enforcement

### V1

Use:

- V1 permission model;
- V1 plugin hooks proven on 1.18.32;
- kernel checks.

### V2

Use:

- native `permissions`;
- optional `experimental.policies` for proven hard-denies;
- V2 plugin hooks;
- kernel checks.

### Parity principle

Security posture should be expressed as semantic invariants.

If V2 can enforce one invariant more strongly than V1, use the stronger V2 primitive while maintaining the best available V1 enforcement.

Do not weaken V2 to match V1.

Do not claim V1 has a V2 policy primitive when it does not.

---

## 30. Feature flags

Extend flags with:

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

Activation order is explicit and evidence-backed.

Runtime support flags do not automatically enable capability router, skill routing or MCP routing.

---

## 31. Expected repository changes

Likely additions:

```text
source/adapters/opencode-v1.md
source/adapters/opencode-v2.md
source/registry/runtime-mapping.json
source/registry/execution-grants.json
source/registry/verification-policy.json

templates/opencode.v1.json.tmpl
templates/opencode.v2.json.tmpl

plugins/orchestration-enforcement/
  index.ts
  v1.ts
  v2.ts
  shared/*

scripts/runtime/
  detect-opencode-runtime.ps1
  render-runtime-profile.ps1
  invoke-opencode-profile.ps1

scripts/v3/task-kernel.ps1
scripts/v3/lib/OrchestrationTaskKernel.ps1
scripts/v3/lib/OrchestrationVerifier.ps1
scripts/v3/lib/OrchestrationOwnership.ps1
scripts/v3/lib/OrchestrationWorktree.ps1
```

Likely modifications:

- `install.ps1`;
- `uninstall.ps1`;
- `scripts/render-opencode-config.ps1`;
- `scripts/reconcile-opencode-config.ps1`;
- `scripts/test-package-consistency.ps1`;
- `scripts/v3/run-v3-tests.ps1`;
- `source/global/AGENTS.md`;
- `source/agents/*.md` only as needed for canonical/runtime-neutral metadata;
- `source/registry/runtimes.json`;
- `source/registry/capability-flags.json`;
- CI;
- README/docs/CHANGELOG/SECURITY/GOVERNANCE.

Exact paths may be adjusted after Explorer review.

---

## 32. Backward compatibility

V3.1 MUST preserve:

- current V1 behavior with `-Runtime V1`;
- current installer ownership model;
- current models configuration;
- 19 agent roles;
- shallow hierarchy;
- V3 router/fallback behavior;
- user-owned MCP/skills/plugins/config keys;
- JSON/JSONC preservation behavior;
- uninstall safety.

Kernel disabled + V1 selected should be behaviorally equivalent to release 1.0.0 except for deliberate bug fixes.

---

## 33. CI matrix

Minimum release matrix:

### Static/hermetic

- PowerShell 5.1;
- PowerShell 7;
- package consistency;
- V3 suites;
- distribution suites;
- runtime renderer tests;
- V1 permission translation tests;
- V2 permission translation/order tests;
- dual manifest/uninstall tests;
- Task Kernel tests;
- verifier/leases/worktree tests.

### Real runtime

- OpenCode V1 `1.18.32`;
- pinned OpenCode V2 stable `2.0.x`;
- plugin load V1;
- plugin load V2;
- config/agent/skill smoke V1;
- config/agent/skill smoke V2;
- subagent delegation V1;
- subagent delegation V2;
- worker no-subdelegation V1/V2;
- isolated-profile smoke when `Both` is supported.

For Windows V2, use the official/proven installation or standalone-binary path. Do not assume a package-manager path works until CI proves it.

---

## 34. Acceptance criteria — dual runtime

### DR-01
V1 remains supported and real-runtime CI passes.

### DR-02
V2 native configuration is generated and real-runtime CI passes.

### DR-03
V2 output uses `agents`, `permissions`, `shell`, `subagent`, and `experimental.subagent_depth` where applicable.

### DR-04
V1 output does not receive V2-only configuration that breaks V1.

### DR-05
One canonical set of agent semantics produces both runtime representations.

### DR-06
All 19 workers exist with equivalent role intent on V1 and V2.

### DR-07
Planner can delegate to the expected worker set on both runtimes.

### DR-08
Workers cannot subdelegate on both runtimes.

### DR-09
Reviewer/Tester read/write invariants are maintained on both runtimes.

### DR-10
The orchestration enforcement plugin loads and injects the correct mandate on both runtimes.

### DR-11
Plugin V1 and V2 implementations share normalized logic rather than independent duplicated policies.

### DR-12
Installer supports explicit `-Runtime V1` and `-Runtime V2`.

### DR-13
`-Runtime Auto` fails closed on ambiguity.

### DR-14
`-Runtime Both` uses isolated profiles and cannot overwrite one runtime’s native config with the other runtime’s config.

### DR-15
Uninstalling V1 profile leaves V2 intact, and vice versa.

### DR-16
Updating V1 does not modify V2-owned artifacts, and vice versa.

### DR-17
User-owned `cli.json` remains untouched by default.

### DR-18
V2 policy hard-denies, if used, are backed by runtime tests.

### DR-19
No moving V2 tag is used as release evidence.

### DR-20
The release documentation states exact V1 and V2 versions actually tested.

---

## 35. Acceptance criteria — kernel hardening

### KH-01
Persistent task records exist.

### KH-02
All state mutations use CAS/revision.

### KH-03
Illegal transitions fail without disk mutation.

### KH-04
Wrong actor cannot advance a privileged stage.

### KH-05
`candidate_pass` alone cannot reach DONE.

### KH-06
Verifier evidence is independent from worker claims.

### KH-07
Writes outside `WRITE_SCOPE` fail verification.

### KH-08
DONE is only kernel-authorized.

### KH-09
Two failed attempts require Debugger escalation.

### KH-10
Invalid third attempt transitions to EXHAUSTED.

### KH-11
Overlapping write leases cannot coexist.

### KH-12
Parallel writers use isolated worktrees.

### KH-13
Worktree cleanup cannot remove unowned workspace/branch.

### KH-14
Read-only agents cannot obtain write grants.

### KH-15
Tester cannot obtain application-write authority.

### KH-16
Verifier cannot execute arbitrary unclassified shell.

### KH-17
Observability reuses the existing sanitized subsystem.

### KH-18
Existing capability-router behavior does not regress.

### KH-19
Installer USER/PACKAGE ownership does not regress.

### KH-20
Task semantics behave the same on V1 and V2.

---

## 36. Security requirements

- no secrets in task state/evidence/telemetry;
- path traversal rejected;
- task/runtime/profile IDs sanitized;
- runtime state confined to package-owned state roots;
- atomic write + post-write validation;
- CAS for task mutations;
- no arbitrary JSON-to-shell execution;
- no permission widening to achieve V2 compatibility;
- `ask` is not treated as a hard deny;
- V2 saved approvals cannot override package hard-denies where V2 policies are used;
- unknown runtime identity never gets privileged authority;
- runtime/profile mismatch blocks privileged task continuation;
- plugin failure never becomes permission escalation.

---

## 37. Non-goals

This initiative MUST NOT:

- remove V1;
- make V2 the only default;
- add OpenCode server/client integrations unless required by the plugin/kernel;
- enable MCP routing;
- enable adaptive ranking;
- redesign model pools;
- redesign Capability Router;
- create a V4;
- introduce deep subagents;
- introduce a persistent database/server;
- automatically replace the user’s global OpenCode installation;
- silently convert a shared V1 config to V2-native format.

---

## 38. Definition of Done

V3.1 Dual-Runtime Kernel Hardening is complete only when:

1. V1 real-runtime lane passes.
2. V2 real-runtime lane passes.
3. Side-by-side isolated profiles pass where advertised.
4. Runtime-specific configs are native and ownership-safe.
5. Plugin works through both runtime contracts.
6. Agent permission semantics are equivalent and tested.
7. Task state is persistent/CAS-backed.
8. Workers cannot self-declare verified completion.
9. DONE is kernel-authorized.
10. Verifier is closed/allowlisted.
11. Leases/worktrees control writer concurrency.
12. Reviewer has no unresolved finding.
13. Security Reviewer has no unresolved high/critical finding.
14. Existing V3/distribution suites remain green.
15. User-owned config remains preserved.
16. Documentation records exact tested runtime versions and known deviations.
17. Feature flags stay conservative by default.
18. No unrelated router/model/MCP redesign is included.
