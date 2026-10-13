# F0 — Finding C: auditoria V2-only/V1-frozen (issue #62)

Fonte: subagent ses_ecf2197c5ffe5L3FXCPQYGFUcZ, STATUS candidate_pass, read-only.
Data: 2026-10-12. Sem escrita, sem segredos.

## Contradições prospectivas (editar em F2, não aqui)

1. docs/INSTALLATION.md:5-10 — "V1.x e/ou V2.x" + pins stale 1.18.32/2.0.18 (vigentes 1.18.34/2.0.23).
2. docs/INSTALLATION.md:37,161-192 — -Runtime Auto|V1|V2|Both como caminho normal; Both como uso corrente.
3. docs/TROUBLESHOOTING.md:191-197 — "linhas V1.x e V2 são suportadas (V3.1)".
4. docs/ARCHITECTURE.md:200-234 + :67 — "Dual-runtime (em andamento)", "V1 ativo; V2 espelha".
5. source/registry/capability-flags.json:26-30 — runtime_support v1+v2+dual_profile ativos; AGENTS.md:206-209 e TROUBLESHOOTING:167-170 repetem.
6. install.ps1:65,1202-1213 — Auto sem binário degrada para V1; mensagens "Passe -Runtime V1 para legado" (default ambíguo).
7. README.md:25-26,48 — "V1 e V2 na mesma máquina via Both" sem marca legado.
8. docs/PERMISSIONS.md:90,93, docs/GOVERNANCE.md:61,69 — V1 como "runtime-enforced (provado em 1.18.x)" sem qualificador histórico.

## V1 legado intacto (preservar)

- source/adapters/opencode.md + opencode-v2.md; templates v1+v2; tests/distribution blocos V1 como regression guard (runtime-install:107-123, profile-isolation, fresh-install/config-preservation/planner-model/uninstall); install/uninstall caminhos V1 + manifest legacy.

## Drift runtime

- Pin: V2 2.0.23, V1 1.18.34 (runtime-versions.json:11-15). Instalado 2.0.27 (verificado pelo Planner via opencode --version + npm global @opencode/cli@2.0.27). Precedentes de drift sem bump: docs 2.0.24 e host 2.0.26 registrados sem bump. Tratar 2.0.27 igual: registrar, sem upgrade/bump automático.

## Testes V2 sem dependência V1 nova

- capability-registry-v2 (só capabilities-v2.json + healthcheck); live-hook-v2 (pin fail-closed, perfil TEMP, porta alternativa, SKIP/HOLD honestos); runtime-install:407-450 (seleção por runtime, asserts em paralelo).

## Edições mínimas propostas para F2 (não aplicadas)

- INSTALLATION.md:5-15,91 — "V1 legado frozen; instalações novas -Runtime V2"; atualizar exemplos com nota histórica.
- TROUBLESHOOTING:191-192 + ARCHITECTURE:200 — "V1 frozen desde #62; dual = manutenção de perfis legados".
- README:25-26 — "(V1 legado, frozen)", "Both = migração/perfils legados".
- capability-flags.json — sem mudar valores; _comment lateral: dual_profile = compat perfis existentes.
- install.ps1:65 — comentário "fallback V1 = compat legado, default prospectivo V2 explícito".

## Incertezas do explorer

- Não executou suites; refs a #62 ausentes no grep (só legado genérico); aceitou 2.0.27 como dado do Planner (ora confirmado pelo Planner).
