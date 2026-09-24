---
name: hybrid-development
description: Use to route non-trivial implementation, refactoring, debugging, or engineering review through the shared development method. Also use when explicitly requested. Skip casual questions, simple edits, and tasks already executing a selected technique; do not reload at every phase.
license: MIT
---

# Hybrid Development

One method, selectively loaded techniques. Combine Matt Pocock's decision and interface design with Superpowers' feedback and verification discipline. Runtime and project instructions take precedence; this method grants no additional authority.

## 1. Establish the Contract

Inspect the actual working directory, instructions, relevant implementation, tests, and existing changes. Recover relevant project decisions when memory is available; do not treat a foreign project's rules as local policy. State the outcome, scope, observable acceptance criteria, and material unknowns. A review or plan request is not permission to implement.

Choose the lightest sufficient track by uncertainty, impact, and reversibility, not lines of code:

| Track | Observable trigger | Minimum useful evidence |
| --- | --- | --- |
| Direct | Clear, low-risk, reversible change | Inspect, smallest correct edit, focused check |
| Structured | Multiple dependent steps, meaningful behavior, or session boundaries | Short plan, verified vertical slices, relevant regression checks |
| High-risk | Auth, money, sensitive data, migrations, public contracts, irreversible operations | Explicit invariants and failure paths, recovery strategy, targeted adversarial/security review, integration evidence |
| Discovery | A material product or technical choice is unresolved | Resolve the question or run a bounded experiment, then choose an execution track |

Do not create a PRD, branch, worktree, subagent, or approval ceremony merely because a track exists. A small auth change is still high-risk. A large mechanical change may only need structured verification. Honor an explicitly requested plan even for a small task.

## 2. Resolve Only Material Uncertainty

Inspect facts rather than asking the user to inspect them. Ask for decisions that change acceptance, safety, authority, or substantial scope; batch independent questions and recommend a choice with reasons. Continue safe independent work when blocked. Do not restart discovery when a specification already answers the questions.

Load [brainstorming](../brainstorming/SKILL.md) for genuine ambiguity. Load [codebase-design](../codebase-design/SKILL.md) when interface boundaries matter; [design-an-interface](../design-an-interface/SKILL.md) adds alternative designs only when comparison could change the decision. Use a bounded prototype for empirical uncertainty, not speculative production architecture.

## 3. Implement Verifiable Slices

Reuse the project's stack, language, interfaces, and commands. Prefer the smallest coherent change and vertical slices that expose useful behavior. Avoid hypothetical abstractions and compatibility layers without real consumers or persisted data. Preserve preexisting work.

For meaningful testable behavior, use [test-driven-development](../test-driven-development/SKILL.md): one independently specified expectation, relevant failure, minimal implementation, green checks, then safe refactoring. If test-first execution is impractical, document the alternative and its limits; do not fabricate a red phase or delete existing code to recreate it.

For bugs, load [systematic-debugging](../systematic-debugging/SKILL.md) before speculative fixes. Reproduce the symptom, test one hypothesis per experiment, and verify the original failure. Difficult, intermittent, or performance failures can add [tight-feedback-debugging](../tight-feedback-debugging/SKILL.md).

Use [writing-plans](../writing-plans/SKILL.md) when a written execution plan is useful, and [executing-plans](../executing-plans/SKILL.md) to follow an existing one. Update a plan invalidated by evidence rather than blindly completing its checkboxes.

## 4. Review and Verify the Actual State

Check requirements and engineering quality as separate judgments. Review changes, not the author's confidence. Include dirty worktree/index changes when they belong to the task; fix the reviewed scope so concurrent work cannot silently enter the review.

Use [requesting-code-review](../requesting-code-review/SKILL.md) for a substantial review and [receiving-code-review](../receiving-code-review/SKILL.md) to assess feedback. [standards-spec-review](../standards-spec-review/SKILL.md) is only the explicit standards-plus-approved-spec report, not an extra mandatory review.

For high-risk work, test plausible failure/abuse cases and use a relevant security or adversarial technique if available. Independent review is preferred when supported and useful. If reviewing your own implementation without another reviewer, perform a separate self-review and state that limitation. Independence concerns authorship, not the availability of subagents; do not call a self-review independent.

Use [verification-before-completion](../verification-before-completion/SKILL.md) for completion claims. Evidence must cover the delivered state: commands, results, untested conditions, and residual risks. A later relevant edit invalidates earlier checks; rerun affected checks, not necessarily every unrelated check.

## 5. Deliver and Preserve Continuity

Report the result, important decisions, verification, and limitations. Never imply deployment, test success, or approval that did not occur. Commit, publish, deploy, and clean up only with the authority required by the current runtime and user; a technique never grants it.

For work spanning sessions, update one existing project plan or handoff with objective, decisions, changed paths, verified state, blockers, and next concrete step. Prefer project-native state; use memory when available and appropriate. Do not require an MCP service to complete local work, copy transcripts into permanent rules, or create several competing progress documents.

## Optional Artifacts and Delegation

- [to-prd](../to-prd/SKILL.md): product outcomes, acceptance, and non-goals when a specification is requested or needed. Not a second technical plan.
- [to-issues](../to-issues/SKILL.md): independently verifiable tickets and dependencies; drafting is distinct from external publication.
- [dispatching-parallel-agents](../dispatching-parallel-agents/SKILL.md): independent bounded investigations or tasks with exclusive ownership.
- [subagent-driven-development](../subagent-driven-development/SKILL.md): delegated execution of an established plan; reuse the delegation contract instead of inventing another orchestration system.
- [agent-instructions-writing](../agent-instructions-writing/SKILL.md) and [writing-skills](../writing-skills/SKILL.md): change the method's instructions or techniques without duplicating routing.

## Runtime Contract

Load named skills with the native loader when available; otherwise read their `SKILL.md` with the available file reader. Resolve relative links from this skill directory, not the current project. If discovery fails, the canonical entrypoint on this installation is `<control-plane-root>/skills/global/hybrid-development/SKILL.md`; on another machine use its configured control-plane root.

Use the actual shell, test runner, editing tools, and permission model. No dependency on Bash, a specific model, tool names, hooks, or subagents. Without parallel agents, execute the same decomposition sequentially. Without execution capability, provide inspected reasoning and explicitly unverified checks, not an invented pass. Do not install a capability or bypass permissions solely to satisfy this method.

Do not load every linked skill. Load the smallest set that changes the next decision, once per relevant phase. Legacy `using-superpowers` forwards here only when explicitly invoked. Specialized project techniques may refine this method but must not turn their own checklists into another global workflow.

## Maintenance

Optimize for correct routing, useful decisions, and observable results, never skill length or section-count scores. Keep one owner per technique and retain upstream attribution. See [provenance](references/provenance.md), [routing scenarios](references/scenarios.md), and [runtime portability](references/runtimes.md).
