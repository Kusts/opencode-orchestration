---
name: subagent-driven-development
description: Use to execute a bounded implementation plan when supported delegation adds useful specialization or independent review. Skip routine solo work and plans without separable ownership.
license: MIT
---

# Subagent-Driven Development

Delegation is optional within [hybrid-development](../hybrid-development/SKILL.md), the sole method router. The coordinator retains the objective, shared decisions, integration, and final verification.

## Execute Bounded Units

Use the task, ownership, capability, and integration contract in [dispatching-parallel-agents](../dispatching-parallel-agents/SKILL.md), even when workers execute sequentially. Do not reload it if already available. This skill adds only plan scheduling:

1. Read the established plan and identify its dependency graph and acceptance criteria. Do not repeat discovery or assume every plan step needs a separate worker.
2. Dispatch ready units only. A dependent unit receives the confirmed contract from its completed prerequisite, not a guessed interface.
3. Compare each delivery to its plan criteria before marking the unit complete. Record blocked, partial, and verified states separately in the existing progress record.
4. Replan remaining units when integration changes an interface or invalidates assumptions. Do not dispatch downstream work against stale contracts.
5. Close the plan only when the integrated evidence covers its acceptance criteria, not when every worker has sent a completion message.

## Handle Gaps

Resolve blockers by clarifying context, narrowing scope, or taking over sequentially. Do not repeat identical dispatches indefinitely or require approval between authorized tasks. Preserve prior work and report unresolved criteria honestly through [verification](../verification-before-completion/SKILL.md).

## Attribution

MIT adaptation; upstream pins: Matt `3cca18b368ae95cdbdebbff572ccafa662551015`, obra `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`. See [provenance](../hybrid-development/references/provenance.md).
