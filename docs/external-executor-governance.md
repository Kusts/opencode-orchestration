# External executor governance

The CLI adds a narrow, task-grant-authorized route for two Telegran operations. It does not authorize arbitrary commands, paths, environment overrides, or projects. Task authority is read from the Task Kernel and the executor allowlist; grants are not added to any role baseline.

Enforcement remains `SOFT_ADVISORY`: this boundary records intent and evidence but is not a hard sandbox. Both executors declare high risk, so the external-action gate may require trusted evidence and human review. Missing evidence is blocked; the CLI does not force an allow decision.

The CLI derives authority from the `grants` explicitly recorded on the task, not from `Get-OrchestrationEffectiveGrants`. That function projects native dispatch permissions by intersecting role baseline, task grants, runtime capability grants, and environment authorization. It is not used by `start-attempt`; because `external.telegran.*` is intentionally absent from every role baseline, that intersection would exclude these grants by construction. This is a conscious operator choice and an assumed risk, not equivalence to Kernel effective-grant enforcement. Receipts remain `SOFT_ADVISORY`; security review should assess this boundary.

Rollback: revert the change that adds these grants and registry/wiring. Removing the grant entries disables authorization; reverting the commit removes the executors and their declarations.
