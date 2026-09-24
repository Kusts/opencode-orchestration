# Runtime Portability

The same source is used by every runtime; this is not six independent method copies. Generated global instructions contain a brief method contract and an absolute canonical fallback. This file describes the installation contract, not proof of successful runtime inference.

| Runtime | Global instruction destination | Skill discovery on this installation |
| --- | --- | --- |
| Shared / new agents | `~/.agents/AGENTS.md` | `~/.agents/skills` or explicit canonical file read |
| Codex | `~/.codex/AGENTS.md` | shared skills root |
| Claude Code | `~/.claude/CLAUDE.md` | `~/.claude/skills` junctions |
| OpenCode | `~/.config/opencode/AGENTS.md` | shared skills root; native loader when present |
| Pi Dev | `~/.pi/AGENTS.md` plus `~/.pi/agent/AGENTS.md` adapter | `~/.pi/agent/skills` junctions |
| Antigravity CLI | `~/.antigravitycli/AGENTS.md` | existing `.gemini/config/skills` projection if supported; otherwise explicit canonical read |
| Antigravity IDE | `~/.antigravity-ide/AGENTS.md` | existing `.gemini/config/skills` projection if supported; otherwise explicit canonical read |

On Windows, `~` denotes the user profile. Canonical root: `<control-plane-root>/skills/global`. Relative Markdown links resolve against the containing skill file, not the current workspace.

If a runtime does not automatically consume its registered instruction destination, configure its supported instruction mechanism before claiming automatic activation. A file existing on disk is not proof it was loaded. Keep the short method contract available in a supported instruction source; do not invent an unsupported setting or hook. New agents need an instruction adapter and either skill discovery or file access, not a fork of this method.

Use native permissions, editing and process APIs. Shell examples must match the actual host; Windows PowerShell 5.1 does not support `&&`. Subagents, MCP memory, Git, and browser automation are optional capabilities, not prerequisites. Use sequential work, a project-local handoff, explicit file reading, or inspected reasoning as applicable. Report the resulting verification limits.

Restart sessions after global configuration changes when the runtime caches discovery or instructions. Existing sessions may retain old skill descriptions. Live discovery and behavior checks belong in release evidence, separately from static projection checks.
