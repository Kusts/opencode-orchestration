# Depth-2 handoff spike (OpenCode 2.3.0)

Verdict: NOT_SUPPORTED for the tested standalone coder invocation. The effective config reported an allow for coder -> tester after its deny and requested depth 2. The run created coder session `ses_e1f422a21ffee4c7zy4gFU4UpS`, but emitted no `subagent` tool call and no child session. Instead it emitted Code Mode `execute` calls invoking catalog search; the final response stated no subagent/task creation tool was available. `session.list` filtered by the coder session returned an empty list.

Limitations: this establishes that the tested standalone `opencode run` tool surface did not produce a child; it does not prove all OpenCode frontends/providers/tool contexts reject depth 2. The attempted first CLI syntax used unsupported `--prompt`; the corrected run supplied the prompt positionally and completed successfully. API tree query was successful and empty.

Runtime: OpenCode v2.3.0; model `opencode/mimo-v2.6-flash-free`; config copied to an isolated XDG config root with top-level `mcp` and `skills` removed. Active config SHA-256 was checked before and after and remained identical. Temporary config folder removed after the run.
