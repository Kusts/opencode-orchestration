# F2 — Matriz de segurança e autorização (2026-10-28)

## Issues: #69, #70, #19, #148

## Rotas de execução

| Rota | O que a política declara | O que o host aplica | Contornável? | Evidência confiável? | Depende de upstream? |
|---|---|---|---|---|---|
| Shell (bash/shell) | allow/ask/deny por glob string-matching | Runtime V1: sim; V2: renderizado+validado por shape/ordem/paridade (Phase 5 pendente) | Sim — wrappers (`pwsh -Command`, `bash -c`) não são inspecionados pelo glob | Parcial — glob matching é string, não AST | Sim (runtime enforcement real) |
| Edit | deny para read-only; allow para writers | Runtime-enforced (edit: deny/allow) | Não via glob (ferramenta dedicada) | Sim | Sim |
| Subagent dispatch | subagent_depth: 1 + permission.task/subagent: deny | Runtime-enforced (hierarquia rasa) | Não — workers não delegam | Sim | Sim |
| REST/MCP | advisory (sem hard-deny V2) | Não implementado (experimental.policies HOLD) | Sim — sem hard-deny | Não (sem proveniência) | Sim |
| Deploy/publish | ask (confirmação) | ask = auto-aprovado em modo auto | Sim — modo auto bypassa | Não (confirmação, não bloqueio) | Sim |

## Achados

1. `deny` é o único bloqueio real no mapa. `ask` é confirmação, não bloqueio incondicional (auto-aprovado em modo auto).
2. Globs `bash:` são matching de string — não inspecionam conteúdo de scripts, aliases ou wrappers.
3. V2 permissions: renderizadas, validadas por shape/ordem/paridade (consistency checks 12–15), mas enforcement real (Phase 5) não implementado. Spike V2 permissions falhou (`agents_load_fixture`).
4. `experimental.policies` (hard-deny global) = HOLD — nenhum hard-deny enviado.
5. `PRODUCTION_AUTHORIZED=true` não autoriza por si só ações destrutivas nem operações com credenciais — exige confirmação separada do Planner.
6. Worker não amplia `ALLOWED_ENVIRONMENT`/`PRODUCTION_AUTHORIZED`/`CREDENTIAL_SCOPE` por inferência.

## Conclusão F2 (fatia pequena)

- Matriz documentada. Sem nova camada de enforcement implementada (conforme regra: só implementar após comprovar controle de todas as rotas).
- F2 permanece P0 para modo host-enforced; advisory/opt-in delimitado é viável.
- Próxima fatia: teste adversarial hermético de allow/ask/deny (glob matching) para as rotas shell — já coberto parcialmente por `tester-shell-permissions.tests.ps1` (260/260) e `debugger-shell-permissions.tests.ps1`.