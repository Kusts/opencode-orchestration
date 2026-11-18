# F1 — Guardrail contra escrita implícita em configuração ativa

## Objetivo e contexto

Impedir escrita implícita na configuração ativa do operador. Em 18/11, o
arquivo `~\.config\opencode\opencode.json` foi sobrescrito: seu tamanho passou
de 33.278 para 390 bytes. A autoria exata não foi comprovada.

Causa provável nos entrypoints: defaults para `$env:USERPROFILE` em
`install.ps1:182`, `uninstall.ps1:29`,
`reconcile-opencode-config.ps1:33-34,162` e
`New-OrchestrationProfile.ps1:105`.

## Entrega

- `scripts/runtime/lib/OrchestrationTargetGuard.ps1`: protege raízes
  derivadas de `USERPROFILE`, `GetFolderPath`, `HOME` e
  `HOMEDRIVE+HOMEPATH`; falha fechada com
  `MUTATING_TARGET_PROFILE_ROOT_UNKNOWN`; recusa UNC e namespaces de
  dispositivo inválidos e reparse não verificado
  (`MUTATING_TARGET_REPARSE_UNVERIFIED`). O carve-out de TEMP é restrito a
  destinos fora de `.config\opencode` e `.opencode-orchestration`. Preserva o
  token legado `MUTATING_TARGET_REQUIRES_EXPLICIT_PATH`.
- `-AllowUserProfileTarget` em install, uninstall, reconcile e
  `New-OrchestrationProfile`, com repasse pelo wrapper.
- `scripts/v3/assert-active-paths-unchanged.ps1`: Capture/Verify com SHA-256
  e tamanho em bytes; recusa diretórios, colisão de `-Output` e `-Output`
  sob raiz protegida.

## Validação e revisão

- `powershell -NoProfile -File .\scripts\v3\target-guard.tests.ps1` —
  PASS=14, FAIL=0, EXIT=0; 1 SKIP (symlink requer privilégio de administrador).
- `powershell -NoProfile -File .\scripts\v3\active-path-integrity.tests.ps1`
  — PASS (6 checks), EXIT=0.
- `pwsh -NoProfile -File .\scripts\v3\install-ownership.tests.ps1` —
  TOTAL=17, PASS=17, FAIL=0, EXIT=0.
- `pwsh -NoProfile -File .\tests\distribution\uninstall.tests.ps1` —
  PASS: 22, FAIL: 0, EXIT=0.
- `powershell -NoProfile -File .\scripts\test-package-consistency.ps1` —
  CHECKS: 17 OK / 0 FAIL.
- `git diff --check` — limpo, EXIT=0.

Tester `OM-F1-TEST-FINAL`: PASS, sem regressões. Security-reviewer
`OM-F1-SEC-FINAL`: APPROVED. Três rodadas corrigiram: (1) HIGH fail-open em
agente interativo; (2) MEDIUM, alvo explícito contornava o guard, e MEDIUM,
`USERPROFILE` vazio/divergente e TEMP igual ao perfil; (3) revisão final sem
achados bloqueantes.

## Limitações e residuais aceitos

Symlink/junction não foram exercitados (SKIP por privilégio; lógica fail-closed).
Nomes 8.3 e drives subst/mapeados não são expandidos. O opt-in
`-AllowUserProfileTarget` é um escape amplo intencional. `uninstall.ps1
-ManifestPath` guiando remoções fora do guard é risco pré-existente.
`-ProtectedRootsOverride` substitui raízes reais como seam de teste.
Não houve ensaio contra a configuração ativa: por política do projeto, a
validação usou fixtures temporárias.

Plano relacionado:
`docs/plans/ORCHESTRATION-OPERATIONAL-MATURITY-PLAN.md`.
