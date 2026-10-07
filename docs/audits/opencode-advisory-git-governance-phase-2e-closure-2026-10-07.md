# Closure — Advisory Git Governance Phase 2E (2026-10-07)

Branch: `feat/advisory-validation-git-governance-phase-2e`. Veredito: **PASS (SHADOW + ADVISORY; Active NÃO promovido)**.

## 1. Scope

Fase 2E: Real-World Advisory Validation + Git Governance Hardening. Validar o Capability Resolver (`2d-shadow-1`, via `scripts/v3/capability-resolve.ps1`, mode shadow) contra 13 pilots em projetos reais, sem ativar nenhum MCP, e endurecer a governança Git após o incidente de commit direto em `master`. Sem adicionar capabilities, sem promover ACTIVE, sem alterar flags, sem tocar em issues fora de escopo (#25, PIN drift, #21, CI-flake).

## 2. Initial State

- Fases 2A–2D: PASS (closures em `docs/audits/`).
- HEAD inicial `master` = `226248e` (commit docs direto pós-merge `c6c15d7` do PR #28).
- Resolver `2d-shadow-1`, registry V2, 19 profiles, skills catalog, enforcement intacto.
- Flags routing OFF (`capability_router.shadow=false/active=false`, `skill/mcp/adaptive/telemetry/reconciler=false`); ao final da fase: **inalteradas**.

## 3. Advisory Mode

Modo vigente: **SHADOW + ADVISORY**. O resolver calcula tudo e altera nada; o Planner decide na política atual e pode reter ou divergir das recomendações com registro. Nenhum MCP foi ativado, nenhum enforcement executado, nenhum segredo usado, nenhum prompt completo persistido. Promoção a Active = decisão futura do operador.

## 4. Real Project Pilots

13 pilots, todos via `scripts/v3/capability-resolve.ps1` (mode shadow, resolver `2d-shadow-1`): P1-docs, P2-research, P3-debug, P4-frontend-analysis, P5-backend, P6-trivial, P7-migration, P8-E2E, P9-runtime-debug, P10-perf, P11-docs-setup, P12-review, P13-CSS-read. Projetos: opencode-orchestration RUN (P1, P3, P6, P12), Synkroo RUN (P2, P4, P8, P9, P10, P13), IPTV RUN (P5, P7, P11), Meu Ted NOT RUN (só probe em `ted-probe-temp/pwa`, sem checkout completo — não inventado). Nenhum projeto externo modificado.

## 5. Resolver Recommendations

- P1-docs (opencode-orchestration): researcher / core / context7 / LOW.
- P2-research (synkroo): researcher / research / jev / LOW.
- P3-debug (opencode): coder / systematic-debugging+tdd / LOW.
- P4-frontend-analysis (synkroo): frontend-engineer / no-mcp / LOW.
- P5-backend (iptv): backend-engineer / no-mcp / LOW.
- P6-trivial: coder / LOW.
- P7-migration (iptv, sem markers supabase/neon): database-engineer / HIGH / no-mcp.
- P8-E2E (synkroo): tester / testing / playwright / MEDIUM.
- P9-runtime-debug (synkroo): debugger / testing / devtools / MEDIUM.
- P10-perf (synkroo): coder / testing / devtools / MEDIUM.
- P11-docs-setup (iptv): researcher / core / context7 / LOW.
- P12-review (opencode): coder / LOW.
- P13-CSS-read (synkroo): frontend-engineer / no-mcp / LOW.
Skills por task: 0–3, sem over-selection. Agents: 1 por task, sem fan-out.

## 6. Planner Decisions

- P1: divergência — Planner = docs-manager (AMBI GUOUS registrado; profile core do resolver permanece seguro: LOW, docs-only MCP).
- P2: acordo — researcher mantido.
- P3: divergência honesta — Planner = debugger (resolver coder+systematic-debugging mantido como skill; AMBIGUOUS).
- P4: acordo — frontend-engineer sem MCP.
- P5: acordo — backend-engineer sem database profile.
- P6: acordo — coder.
- P7: acordo em confidence (AMBIGUOUS honesto, sem falso positivo de stack).
- P8: acordo — tester+playwright.
- P9: acordo — debugger+devtools.
- P10: acordo — coder+devtools.
- P11: divergência — Planner = docs-manager (AMBIGUOUS).
- P12: divergência — Planner = reviewer (resolver coder; skill verification-before-completion retida).
- P13: acordo — frontend-engineer sem playwright (negativo real-world).

## 7. Routing Agreement

Agent agreement 9/13 = 69% (divergem P1, P3, P11, P12). Profile agreement 11/13 = 85% (divergem P1, P11 — eixo agent researcher-vs-docs; profile core seguro). Skill agreement 13/13 = 100% (Planner reteve skills do resolver em todos os pilots, inclusive divergências: systematic-debugging em P3, verification-before-completion em P12). Threshold 90% agent/profile NÃO atingido → classificação **INSUFFICIENT_REAL_WORLD_DATA** para estabilidade estatística; porém seguro (0 críticos). Ver §15.

## 8. Over/Under Activation

Over-activation: 0. Under-activation insegura: 0. Critical routing mistakes: 0. Unsafe capability activation: 0. Permission bypass: 0. Nenhum fallback transformou failure local em regra geral. Nenhuma ativação insegura em nenhum dos 13 pilots.

## 9. Browser Routing

Playwright: 1 ativação correta (P8 E2E) + fallback CLI provado; 0 ativações desnecessárias — P4 (frontend-analysis) e P13 (CSS-read) provam contenção (resolver recomendou no-mcp e o Planner concordou; ler CSS não ativa browser). Chrome DevTools full: 2 ativações corretas (P9 runtime-debug, P10 perf — diagnóstico-gated) + 0 desnecessárias. Decisão vigente mantida: DevTools full APPROVED, profile-only, não global.

## 10. Skill Routing

Skill agreement 13/13 = 100%, 0–3 skills por task efetivo 1–2, sem over-selection. P3: systematic-debugging retida mesmo com divergência de agente. P12: verification-before-completion retida mesmo com Planner=reviewer. Nenhuma skill fora do catálogo ACTIVE. Nenhuma ativação desnecessária de skill de alto custo.

## 11. Agent Routing

1 agente por task, sem fan-out, em todos os 13 pilots. Sem paralelismo injustificado. Divergências P1/P3/P11/P12 registradas como AMBIGUOUS honestas, não como erro crítico: todas LOW risk, nenhuma com ativação insegura. Acordos P2/P4/P5/P6/P7/P8/P9/P10/P13 cobrem research, frontend, backend, trivial, migration, E2E, runtime, perf e leitura CSS.

## 12. Profile Lifecycle

Ciclo inactive→resolved→activated→used→released provado via overlay sessions: 2E-SESS-A (testing→playwright+devtools) e 2E-SESS-B (research→context7+jev). Release de A não afetou B. Ativação futura = overlay session-scoped, nunca mutação global. Gate (status+healthcheck+credencial+risco) preservado; sem credencial → unavailable + fallback.

## 13. Session Isolation

Session isolation PASS: sessão B (research) sem Playwright/DevTools herdados de A (testing). Overlays por `session_id`, `expires=session`, `-Release` remove. Nenhum vazamento de MCP entre sessões observado.

## 14. Fallbacks

Fallbacks registrados em P2 (docs oficiais + pesquisa manual), P8 (Playwright CLI) e P11 (docs oficiais + notas locais). P7 AMBIGUOUS honesto sem forçar ativação de stack (sem markers supabase/neon → sem falso positivo, fallback backend genérico). Nenhum fallback mascarou failure sistêmico.

## 15. Active Promotion Decision

**PROMOTE_ACTIVE = NO.** Recomendação: **CONTINUE_ADVISORY**. Fundamento: threshold 90% agent/profile não atingido (69%/85% = INSUFFICIENT_REAL_WORLD_DATA para estabilidade estatística), porém 0 erros críticos, 0 ativações inseguras, isolamento e fallbacks provados. Arquitetura final permanece SHADOW + ADVISORY; Active segue decisão futura do operador com mais dados.

## 16. Git Governance Initial State

Pré-fase: proibição de commit direto em `master` era prática informal, sem documento normativo, sem guard local, sem workflow de closure formalizado. PR #28 (Phase 2D) seguiu merge commit `c6c15d7` com fix separado `4a1acbe`, mas o registro pós-merge abriu a brecha do §17.

## 17. Direct Master Commit Incident

Commit `226248e` (`docs: record PR #28 review findings closure`): parent único de `c6c15d7`, 1 arquivo docs, aplicado direto em `master`, fora de qualquer PR. Conteúdo correto, procedimento errado. Documentado como evidência motivadora em `docs/github-lifecycle-policy.md` §10, sem reescrever histórico. É exatamente o caso que a policy agora proíbe (§18, seções 1 e 8).

## 18. Git Lifecycle Policy

Criada `docs/github-lifecycle-policy.md` (12 seções, source of truth; em divergência com prática informal anterior, este documento vence): 1) nenhum commit direto em `master`; 2) branch/worktree obrigatório; 3) PR obrigatório; 4) CI obrigatório (5 checks reais: `CI (ps51)`, `CI (ps7)`, `CI (smoke opencode real)`, `CI (v2 lane, perfil V2 provisionado)`, `CI (smoke opencode v2 real)`); 5) política de review (4 camadas); 6) merge commit padrão, sem squash/rewrite; 7) force-push e deleção proibidos; 8) workflow de closure; 9) break-glass; 10) incidente `226248e`; 11) branch protection recomendado; 12) capability `github-lifecycle` por referência (sem entry no registry — verificado, sem redundância). Seção correspondente adicionada em `docs/GOVERNANCE.md`.

## 19. Closure Workflow

Padrão: closure (ou atualização pós-review) entra **dentro do próprio PR, antes do merge**, como commit normal da branch. Fatos pós-merge (fechamento de review, CI final, hash do merge) entram exclusivamente via **follow-up docs PR** — nunca via commit direto em `master`. Este closure está preparado na branch 2E para entrar no PR antes do merge (padrão §19).

## 20. Branch Protection

Ruleset de `master` = **RECOMENDADO, não aplicado** (sem autorização admin): `direct_push: deny`, `force_push: deny`, `deletion: deny`, `require_pull_request: true`, `required_checks` (os 5 CIs reais), `require_conversation_resolution: true`. Nenhuma proteção foi aplicada por esta fase; a lista é especificação para decisão do operador.

## 21. Review Policy

Quatro camadas, sem confusão: GitHub required review (aprovação humana/ruleset — gate externo, nenhum subagente substitui); internal subagent review (`reviewer` + `security-reviewer` quando a policy disparar — independentes, read-only, `APPROVED`/`CHANGES_REQUIRED`); Codex bot (sinal consultivo; P1/P2 em commit separado, sem rewrite); deterministic fallback (inspeção integral + provas por finding + verificação de scope creep + tester independente, tudo registrado).

## 22. Review Fallback

Regra anti-fabricação: nunca inventar `PASS`/`APPROVED`. Resultado sem evidência observável = `REVIEW_FALLBACK` (procedimento aplicado e registrado, autoridade limitada), nunca `REVIEW_APPROVED`. Mensagem de sucesso de worker nunca é prova. Função `Get-GitGovernanceReviewClassification` em `scripts/v3/protect-master.ps1` distingue as duas classificações (3 sinais exigidos para APPROVED).

## 23. Break Glass

Incident, outage ou emergência de segurança podem furar as seções 1–7 da policy somente com, cumulativamente: motivo explícito, evidência do incidente, PR ou issue post-hoc, trilha de auditoria (quem/quando/por quê). "Pequeno", "só docs" ou "fora do horário" não qualificam. Sem uso de break-glass nesta fase.

## 24. Local Enforcement

`scripts/v3/protect-master.ps1`: classificador blocklist de linhas de comando git (nunca executa escrita; só `git branch --show-current` em modo CLI). Nega fail-closed: DIRECT_MASTER_COMMIT (sem exceção docs-only), DIRECT_MASTER_PUSH, FORCE_PUSH com master, DELETE_PROTECTED, UNKNOWN_OPERATION/UNKNOWN_BRANCH. Permite: OK_READONLY, OK_FEATURE_BRANCH. Dot-sourceable como biblioteca + modo CLI (exit 0 ALLOW / 1 DENY). PS 5.1, ASCII-only, sem segredos.

## 25. Tests

Suíte advisory `scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1`: **379/379**. Guard `scripts/v3/protect-master.tests.ps1`: **30/30** (commit direto, push master, force, delete, refspec `+`, fallback UNKNOWN, classificação REVIEW_FALLBACK≠REVIEW_APPROVED, CLI exit codes). `.gitignore` editado com exceção `evidence/capabilities-phase-2e/`. `git diff --check` limpo.

## 26. CI

CI do PR 2E: pendente decisão do operador (push/PR não executados nesta sessão). Nomes reais dos 5 checks documentados na policy §4; resultado de SHA anterior nunca reutilizado como prova do SHA atual; rerun de flaky documentado permitido no mesmo SHA. Issues #25, PIN drift, #21 e CI-flake intocados conforme escopo.

## 27. Security

Nenhum segredo em outputs do resolver (só nomes de env, nunca valores), nenhuma credencial usada nos pilots, nenhuma ativação real de MCP, nenhum bypass de permissão, financeiro CRITICAL+deny preservado, telemetria sem literais/prompts. Review/security-reviewer da fase: aplicar conforme policy quando a superfície disparar; findings endereçados em commit separado, sem rewrite.

## 28. Residuals

Reais e honestos: (a) threshold 90% não atingido = INSUFFICIENT_REAL_WORLD_DATA (mais pilots reais necessários antes de Active); (b) branch protection RECOMENDADO não aplicado (decisão admin do operador); (c) issues #25 / PIN drift / #21 / CI-flake intocados (fora de escopo); (d) Meu Ted NOT RUN (sem checkout completo); (e) Active Mode + promoção Advisory + manifest `.opencode/capabilities.json` = decisões futuras do operador; (f) divergências P1/P3/P11/P12 como AMBIGUOUS honestas, não erros — monitorar em Advisory contínuo.

## 29. Git/PR Evidence

- Branch `feat/advisory-validation-git-governance-phase-2e` de `master` (`226248e`).
- Nenhum push em `master` nesta fase. Arquivos: `docs/github-lifecycle-policy.md` (novo), `docs/GOVERNANCE.md` (edit, seção), `scripts/v3/protect-master.ps1` (novo), `scripts/v3/protect-master.tests.ps1` (novo), `scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1` (novo), `evidence/capabilities-phase-2e/` (13 resolver JSONs + ledger `real-world-pilots-2026-10-07.json`), `.gitignore` (edit, exceção), este closure (novo).
- `git diff --check` limpo. Contagem de seções: 30 `##` + título.
- PR/CI/merge: pendente decisão do operador (push/PR não executados nesta sessão); closure preparado na branch para inclusão no PR antes do merge, conforme §19 (PR ainda não aberto nesta sessão).

## 30. Final Verdict

**Phase 2E: PASS.** Critérios atendidos: 13 pilots executados em projetos reais (todos shadow, resolver `2d-shadow-1`) + 0 erros críticos/ativações inseguras/bypass + session isolation provada (A/B) + fallbacks registrados sem generalização indevida + Active NÃO promovido (CONTINUE_ADVISORY, INSUFFICIENT_REAL_WORLD_DATA explícito) + governança documentada (policy 12 seções + GOVERNANCE) + direct-master coberto por policy + guard processual (classifier + suite; hook remoto/branch protection pendente de autorização do operador) + review fallback distinguido (FALLBACK≠APPROVED) + closure preparado na branch para inclusão no PR antes do merge (§19, PR pendente de abertura). Arquitetura final: **SHADOW + ADVISORY** (flags OFF inalteradas). Princípio atendido: validação real sem ativação real + governança que proíbe por processo o próximo `226248e` (enforcement remoto pendente).
