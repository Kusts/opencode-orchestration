---
name: verification-before-completion
description: Use before claiming work complete, fixed, passing, or ready to integrate. Skip unrelated check suites and ceremonial verification for conversational answers.
license: MIT
---

# Verification Before Completion

This evidence technique serves [hybrid-development](../hybrid-development/SKILL.md), the sole method router. Match each claim to an observation that actually supports it.

## Verify the Relevant State

1. Identify the acceptance criteria, local verification contract, and changed behavior. Choose focused tests, type checks, builds, inspections, or operational observations according to actual risk.
2. Identify the state under examination: revision plus relevant index, working-tree, untracked-file, dependency, and configuration changes. A commit identifier alone does not describe a dirty checkout.
3. Run the selected checks. Read their exit status, failures, skipped cases, and tested scope; successful command startup is not successful completion.
4. Inspect the final diff and confirm the evidence still applies. Later edits, integration, dependency changes, or concurrent modifications can invalidate results. Rerun affected checks when they do; unchanged relevant state does not require ritual repetition.
5. Report what passed, failed, was skipped, or could not run, with the state and material limitations.

## Claim Boundaries

Do not infer runtime correctness from compilation, security from lint, or integration success from an isolated unit test. Do not claim coverage from checks that were not executed. Static inspection is valid evidence for suitable changes, but label it as inspection, not a test run.

A worker's summary is not integrated verification. The coordinator inspects delivered changes and verifies the combined state. When tools or environment are unavailable, state the unverified criteria and blocker rather than converting confidence into proof. Redact sensitive evidence.

## Attribution

MIT adaptation; upstream pins: Matt `3cca18b368ae95cdbdebbff572ccafa662551015`, obra `b36e0829c6d0140e93cfef2ca599b1b07d4a7797`. See [provenance](../hybrid-development/references/provenance.md).
