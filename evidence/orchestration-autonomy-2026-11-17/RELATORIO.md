# Consolidação da autonomia — 2026-11-17

## Objetivo e baseline

Consolidar os resultados da missão de autonomia, com baseline `master@ef61761`,
PR #272, em 2026-11-17. O CI final do HEAD integrado ainda deve ser confirmado
pelo Planner; este relatório não declara CI verde.

## Marco 1 — desacoplamento do Agent Config

O defeito real foi a remoção de `$sharedSkillNames` enquanto quatro pontos
continuavam usando a variável. A correção está no commit `b7eea020`. As
referências de skills-core passaram de 5 para 8 e foram corrigidas em
`source/adapters/opencode-v2.md` e `source/registry/capabilities-v2.json`.
O teste `SHARED_SKILL_JUNCTION` está em
`tests/distribution/clean-reinstall.tests.ps1:111-136`.

Resultados reais: install-ownership 17/17; clean-reinstall 12/12; fresh-install
53/53; idempotency 17/17; package-consistency 17/17; `git diff --check` limpo.
Aceite: instalador nativo independente, 19 agents/permissões e preservação de
MCP, plugins, skills e terceiros em instalação, reinstalação e execução
idempotente. Verificação independente: PASS.

## Marco 2 — certificações em dois projetos reais

- **telegran (Python):** `tests/test_cwd_arbitrary.py` reproduzia quatro falhas
  ao exigir a ausência de `manifest.sqlite-wal/-shm` já existentes. `92db449`
  compara snapshots de existência, tamanho e `mtime_ns` antes/depois, mantendo
  a detecção de toque indevido. `pytest tests/test_cwd_arbitrary.py`: 4/4;
  `test_auto_learn.py`: 15/15; sidecars reais intocados. Verificação
  independente: PASS.
- **jev-mcp (Node):** o roteamento de chave `jv_live_` de `6cfb78d` não tinha
  testes. `2dfac3e` extrai `src/endpoint.js` puro, adiciona
  `tests/endpoint.test.js` com seis casos e o script `npm test`. Resultado:
  `npm test` 6/6 e `node --check` OK. Paridade de produção preservada; única
  mudança intencional: trim de `JEV_BASE_URL`, coberta por teste. Verificação
  independente: PASS.

Ambos são projetos de terceiros com commits locais, sem push ou PR. O Planner
escolheu autonomamente os repositórios, Direct/verificação focada; não fez
perguntas técnicas, não apagou dados nem causou efeitos externos nesses
projetos.

## Marco 3 — issue #48

- **Simples:** `orchestration-preflight.ps1` classificou point lookup como
  `DIRECT_VERIFIED` / `trivial` / `selected_agents=[]` /
  `DIRECT_VERIFIED_LOW_RISK_LOCALIZED`; micro-edição `typo` como
  `SINGLE_WORKER` / `trivial` / `coder`; contrato não trivial como
  `MULTI_WORKER`.
- **Multifase:** `p0-autonomy-proof.tests.ps1` 14/14: Goal com três Tasks,
  ordem T1→T2→T3, falha e replanejamento em T2, evidência/progresso e DONE
  do Goal.
- **Falha/replano:** `retry-decision-e2e.tests.ps1` 6/6: LOCAL_REPAIR, REPLAN,
  ESCALATE após duas tentativas, bloqueio por review e fail-closed.
- **Referências:** `skills-core/hybrid-development/SKILL.md:17-22,28-33`;
  `OrchestrationPreflight.ps1:429-452,456-460,586-607,623-633`;
  `OrchestrationPlannerLoop.ps1:171,188-207,250,374`;
  `OrchestrationGoalKernel.ps1:1215-1277`;
  `OrchestrationObjectiveController.ps1:319-343`.

Conclusão: roteamento adaptativo distribuído implementado e funcional. Um
roteador único e autoritativo no Kernel seria um novo motor/gate, fora do
escopo da issue #48 e desta missão; é não-goal, não pendência.

## Pendências

A retomada automática do próprio Planner permanece BLOCKED pela limitação de
runtime conhecida e está fora de escopo. CI final do HEAD integrado: confirmação
pendente do Planner.
