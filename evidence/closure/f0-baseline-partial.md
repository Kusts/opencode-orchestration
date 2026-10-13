# F0 — Baseline parcial (PLANNED → IN_PROGRESS)

Data: 2026-10-12T16:08Z (America/Sao_Paulo 13:08)
Owner: Planner (DETERMINISTIC_FALLBACK, hard_exclusion_security_sensitive)
Preflight: DETERMINISTIC_FALLBACK, task_class=non_trivial, fallback_reason=hard_exclusion_security_sensitive
Jev advisory (transporte HTTP, mesmo endpoint/modelo do MCP — MCP stdio indisponível no host):
- TurnId turn-closure-f0-003, descriptor route_uncertain=true
- status=JEV_ADVISORY_OK, consulted=True, elapsed_ms=1028
- answers.route.choice=sequential, confidence=0.22 (baixa)
- Decisão do Planner: tratar como dado; discovery read-only em paralelo (3 explorers, worktrees/arquivos distintos, sem escrita), integração sequencial. Sem ampliação de autoridade.

## Fatos observados

- HEAD: master @ 6a7bb9d2ec9413efab39ae5e474145336667be3e (confere com o plano). Working tree LIMPO (git status porcelain vazio).
- CI master: últimos runs success — 38266794399 (2026-10-12T14:58Z), 38266335136, 38245310121 (merge PR #68). Gate F0 parcial: sem divergência oculta no checkout principal.
- Runtime instalado: opencode v2.0.27 (bin C:\Users\walis\bin\opencode.ps1; npm global @opencode/cli@2.0.27) vs pin CI 2.0.23 → DRIFT +4 patch, registrado, sem upgrade automático (regra F2).
- Bun 1.3.14 = pin. V1 legado: não instalado neste host (stream F2 deve confirmar; sem novos desenvolvimentos).
- Flags vivas (source/registry/capability-flags.json): task_kernel ON, bounded_execution ON, watchdog ON (shadow:false), jev_advisory ON, worktree_isolation ON; capability_router shadow:false/active:false; skill_routing/mcp_routing/adaptive_ranking/routing_telemetry/reconciler OFF; runtime_grant_enforcement v1+v2 OFF; runtime_support v1+v2+dual ON. Nenhuma flag alterada nesta sessão.
- PRs abertos (4, conferem com o plano): #59 (feat/opencode-capabilities-runtime-validation @ 3fb4f48, telemetry confinement), #65 (fix/pr59-cas-diagnostics @ aa3ba84, CAS diagnostics), #66 (docs/ci-check-policy-2026-10 @ a883dae, CI policy), #71 (feat/opencode-v2-agent-mcp-integration @ 1101d28, browser MCPs PARTIAL).
- Worktrees ativas (11): principal + agent-mcp-integration(1101d28) + capabilities-provisioning(6b9fba3) + capabilities-runtime-validation(3fb4f48) + docs-ci-policy(a883dae) + planner-native-handoff(b38c92b detached) + pr59-cas-diagnostics(aa3ba84) + watchdog-diagnostics(3dfe1f6) + watchdog-master(4f29f68) + watchdog-pr65-aa3ba84 + watchdog-pr65-base(4f1cf7) + D:/projetos/opencode-orchestration-2g (9129e0b). Nenhum trabalho local perdido (tree limpo).
- Issues de escopo abertas: #51 (Autonomous Core E2E), #60 (Advisor), #61 (Jev), #62 (V2-only), #69/#70 (security G1), #21 (distribuição V1-dialeto). Backlog explícito: #50, #48.

## Hipóteses (não fatos)

- Causas das falhas de CI nos PRs (PS7/PR59, PS5.1+V2-lane/PR65, V2-lane/PR66?) — aguardar explorer A + logs dos runs 38102967919 / 38149341433 / 38158278853.
- Mapeamento exato dos runs aos PRs — pendente (gh pr checks agregado sem rótulo; vincular por head SHA).
- Conteúdo dos diffs e sobreposição entre PRs — explorer A.
- Wiring F3/F4/F5/F6 — explorer B. Contradições V2-only — explorer C.

## Próximo passo

BARRIER dos 3 explorers → matriz única de pendências (evidência, responsável, bloqueio, aceite) → plano de integração seguro → fechar Gate F0.
