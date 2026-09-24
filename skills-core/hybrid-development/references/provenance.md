# Provenance and Deduplication

Reviewed 2026-09-08. These are curated adaptations, not automatic mirrors or installations of either full plugin. Upstream content is reference material; installed runtime and local policy remain authoritative.

| Source | Immutable revision | License |
| --- | --- | --- |
| [mattpocock/skills](https://github.com/mattpocock/skills/tree/3cca18b368ae95cdbdebbff572ccafa662551015) | `3cca18b368ae95cdbdebbff572ccafa662551015` | MIT, Matt Pocock, 2026 |
| [obra/superpowers](https://github.com/obra/superpowers/tree/b36e0829c6d0140e93cfef2ca599b1b07d4a7797) | `b36e0829c6d0140e93cfef2ca599b1b07d4a7797` | MIT, Jesse Vincent, 2025 |

## Single Owners

Paths in the Matt column are under `skills/` at its pinned revision; Superpowers paths are under `skills/` at its pinned revision. Existing local skill names are kept because installed agents and other skills already reference them.

| Concern | Matt source | Superpowers source | Local owner / boundary |
| --- | --- | --- | --- |
| Routing | `engineering/implement` | `using-superpowers` | `hybrid-development`; legacy router is a pointer |
| Discovery | `productivity/grilling` | `brainstorming` | `brainstorming`; ask only material unknowns |
| Product spec | `engineering/to-spec` | brainstorm spec discipline | `to-prd`; outcomes, not implementation steps |
| Tickets | `engineering/to-tickets` | planning task contracts | `to-issues`; vertical slices, no automatic publication |
| Technical plan | spec/ticket boundaries | `writing-plans`, `executing-plans` | same local names; authoring versus execution |
| Interfaces | `engineering/codebase-design`, `engineering/codebase-design/DESIGN-IT-TWICE.md` | scoped design trade-offs | `codebase-design`; `design-an-interface` only adds comparison |
| Testing | `engineering/tdd` | `test-driven-development`, `test-driven-development/writing-good-tests.md` | `test-driven-development`; one behavioral slice |
| Debugging | `engineering/diagnosing-bugs` | `systematic-debugging` | `systematic-debugging`; tight-feedback is a difficult-bug supplement |
| Review | `engineering/code-review` | `requesting-code-review`, `receiving-code-review` | request/reception are distinct operations; standards-spec is an explicit report format |
| Delegation | experimental `in-progress/implement-spec` | `dispatching-parallel-agents`, `subagent-driven-development` | bounded task contract; delegated execution adds integration, not another router |
| Completion | focused implementation checks | `verification-before-completion` | evidence tied to the delivered state |
| Agent documents | writing-for-agents lineage in local adaptation | `writing-skills` | instruction routing versus reusable technique authoring |

Matt's current names `to-spec` and `to-tickets` replace older upstream names, but local `to-prd` and `to-issues` remain stable. Experimental `implement-spec` is not promoted into a mandatory orchestrator. Existing project-specific, domain, UI, security, and orchestration skills are not removed or automatically loaded.

## Deliberate Rejections

- No one-percent-chance invocation rule, full-plugin bootstrap, or repeated router loading.
- No design approval for every already-clear, authorized task; no approval for each test.
- No deleting working implementation to manufacture TDD history or deleting tests before proving their coverage redundant.
- No fixed number of subagents, required worktrees, model names, Bash commands, or tool-specific choreography.
- No automatic commits, issue publication, deployments, credential changes, or cleanup authority inferred from a checklist.
- No universal vocabulary bans, implementation-sized plans, speculative interfaces, or mandatory documentation for tiny edits.
- No padding to reach word/character/heading counts. Validate behavior and links instead.

## License Notices

The following upstream MIT notices apply to adapted portions of this method and its techniques. Preserve this file with distributions; each entrypoint links here.

### Matt Pocock

MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Jesse Vincent

MIT License

Copyright (c) 2025 Jesse Vincent

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
