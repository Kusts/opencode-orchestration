# External executor governance

The CLI currently performs bounded request and registry validation only. Requests are inline JSON (maximum 8192 characters); registry and grants paths are fixed by the CLI and cannot be overridden by caller parameters. Duplicate top-level JSON keys are rejected.

`-DryRun` returns `WAIT` with `DRY_RUN_VALIDATED_NO_EFFECT` and exit 0. This means only that the request is valid: authority has **not** been verified and no execution occurs. A live request fails closed with `EFFECTIVE_GRANT_SOURCE_UNAVAILABLE` because no trusted effective-grant source is wired to this route.

The registered executor map contains inert stubs; it does not spawn Python or perform Telegran operations. External grants remain outside role baselines. If a future implementation is proposed, sensitive external grants must require the intersection of task grant, runtime grant, environment authorization, and explicit human approval. `SOFT_ADVISORY` is not hard enforcement or a sandbox.

No executor action or receipt is produced by the current validation-only path.
