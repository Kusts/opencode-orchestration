# V2.3.0 permissions runtime proof

## State and installation

- Runtime: OpenCode v2.3.0; model requested: `opencode/mimo-v2.6-flash-free`.
- HEAD before installation: `832bc1bffd9c7f5f949ee2b39e15f85844345556`.
- The pre-existing dirty working tree is recorded in `pre-install-git-status.txt`.
- `install.ps1 -Runtime V2 -Clean` completed with `INSTALLED=19`, `CONFLICT=0`, `FAILED=0`; 15 resources were preserved. The output reports the Agent Config global text was preserved and `AGENTS.md` skipped because it is owned by Agent Config.
- Backup: `C:\Users\walis\.config\opencode\backups\oo-20261114-231804` (24 files).
- `opencode debug agents --standalone` output is in `debug-agents.txt`. Explorer has the shell catch-all and allow rules, followed by specific denies at the end of its shell rules.
- Post-install `-WhatIf` reports `INSTALLED=0`, `UNCHANGED=24`, `CONFLICT=0`, `FAILED=0`.

## Behavioral outcome

The positive `git diff --stat` and `rg -n permission docs/PERMISSIONS.md` controls executed successfully. All five deny cases are now `DENIED`. A temporary `permprobe` submitted exact shell inputs for `git diff --output=...`, `git show --output=...`, `git log --output=...`, and `rg --pre ...`; each returned `Permission denied: shell` with `executed=false`. The initial proof directly denied `rg --hostname-bin ...` with the same result. The designated output files and `sentinel-ran.txt` are absent.

The temporary agent was derived from the installed Explorer native V2 permissions, with the same shell allowlist and five specific denies at the end. Debug output confirmed it loaded; it was removed after the probe. Post-removal `-WhatIf` again reports `INSTALLED=0`, `UNCHANGED=24`, `CONFLICT=0`, `FAILED=0`. Overall verdict: **PASS**.

Evidence: `probe-debug-agents.txt`, `probe-git-diff.jsonl`, `probe-git-show.jsonl`, `probe-git-log.jsonl`, `probe-rg-pre.jsonl`, `all-deny-validation.json`, `probe-call-checks.json`, `probe-existence-checks.json`, and `probe-drift-whatif.log`, alongside the initial evidence and `result.json`. Probe model: `opencode-go/iceman-contributor-free`; initial checks used `opencode/mimo-v2.6-flash-free`. No reinstall, commit, or push was made.
