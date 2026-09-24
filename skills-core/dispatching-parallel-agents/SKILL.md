---
name: dispatching-parallel-agents
description: Use for two or more independent tasks when supported parallel delegation saves time without shared-state conflicts. Skip dependent steps, overlapping edits, and simple inspections.
license: MIT
---

# Dispatching Parallel Agents

An optional execution technique under [hybrid-development](../hybrid-development/SKILL.md), the sole method router. Parallelism is useful only when coordination costs are smaller than its benefit.

## Check Capabilities and Independence

Confirm the runtime actually provides agent launch, result collection, and appropriate isolation. Do not invent tool names or assume subagents exist. Without those capabilities, execute the same bounded tasks sequentially in the current agent and report that choice plainly.

Separate work by independent inputs, outputs, and ownership. A task needing another task's unresolved interface or result must wait. Shared configuration, generated artifacts, index operations, services, and test fixtures count as shared state, not just source files.

## Dispatch and Integrate

1. Assign each worker a bounded objective, acceptance criteria, confirmed context, allowed files or resources, prohibited operations, required evidence, and escalation conditions.
2. Establish one writer per resource. The coordinator must not edit worker-owned files concurrently. Serialize shared mutations and ownership transfers; isolation does not remove the need to reconcile integration conflicts.
3. Collect the actual diff or artifact, commands and outcomes, limitations, and unresolved questions. On a blocker, adjust scope or execute sequentially instead of spawning repeated attempts.
4. Inspect each delivery against requirements and the local quality contract. A worker's success report is input, not proof.
5. Integrate deliberately, preserving preexisting changes, then have the coordinator run relevant checks on the combined state using [verification](../verification-before-completion/SKILL.md).

Do not force a team size, redundant reviewer roles, new worktrees, or approval between already authorized tasks.

## Attribution

MIT adaptation; upstream pins: Matt `3cca18b368ae95cdbdebbff572ccafa662551015`, obra `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`. See [provenance](../hybrid-development/references/provenance.md).
