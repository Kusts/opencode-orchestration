# Plano — Orchestration Operational Maturity

**Baseline:** branch `feat/operational-maturity-20261118`, base local `a55ed71`, `origin/master` `8158b51` (contexto verificado em 2026-11-18). **Data:** 2026-11-18.  
**Classificação:** programa de certificação operacional, não novo framework.  
**Princípio:** menor solução funcional; reutilizar primitivas, contratos e evidências existentes.

Este documento planeja a certificação incremental. Estados descrevem evidência existente, não promessa de conclusão.

## Estado atual por marco

| Marco do pedido | Estado | Evidência | Próxima ação |
|---|---|---|---|
| M1 — Confiabilidade de instalação e permissões: 1.1 isolamento | PARCIAL | `evidence/confiabilidade-operacional-2026-11-17/RELATORIO.md:46-62` (`ISOLATION_DESIGN_READY`, não validado); `install.ps1:182`, `uninstall.ps1:29`, `scripts/reconcile-opencode-config.ps1:33,162`, `New-OrchestrationProfile.ps1:105` usam `$env:USERPROFILE` em defaults. | Guardrail contra destino fora do HOME temporário e prova independente de hashes externos; resolver a causa provável sem assumir autoria definitiva do incidente. |
| M1 — Confiabilidade de instalação e permissões: 1.2 permissões | PARCIAL | `evidence/permissions-runtime-2026-11-15/` comprova 5/5 denies em runtime 2.3.0; `evidence/confiabilidade-operacional-2026-11-17/RELATORIO.md:41-45` registra `POLICY_VERIFIED` não comprovado. | Após F1/F2, comprovar allow/ask/deny isoladamente e observar eventos de permissão; não testar configuração ativa. |
| M1 — Confiabilidade de instalação e permissões: 1.3 instalador | AUSENTE | A receita em `evidence/confiabilidade-operacional-2026-11-17/RELATORIO.md:54-60` não foi executada; incidente de 18/11 descrito em `:46`. | Certificar dois ciclos de instalação usando HOME temporário após F1. |
| M2 — GitHub nativo e higiene automática (pós-merge) | AUSENTE | Não há rotina integrada. Primitivas existentes: `scripts/v3/lib/OrchestrationWorktree.ps1` (ownership/dirty, sem force implícito), `OrchestrationMergeMediated.ps1` (confirmação, sem rede) e `OrchestrationDelivery.ps1` (snapshot). | Compor fluxo explícito e idempotente com essas primitivas; certificar merge normal, squash e worktree suja. |
| M3 — Certificação de autonomia ponta a ponta (cenários A–E) | PARCIAL | Primitivas A–E presentes: NativeDispatch PREPARE/CLAIM/SETTLE, NativeResume, SettledRecovery/Continuation, repair-decision, model-fallback, cache-metrics e evidence-virtualize. `CHANGELOG.md` e evidências específicas documentam provas delimitadas, não uma certificação integrada A–E. | Executar matriz A–E e medir eficiência antes de qualquer claim. |
| M4 — Saneamento das 90 issues e documentação | PARCIAL | `CHANGELOG.md` registra status e correções; contexto de execução: 90 issues abertas, 0 PRs abertas, PRs #272/#274/#275/#276/#277 mescladas. | Classificar backlog e atualizar documentação com evidência; sem fechamento em massa. |
| M5 — Handoff dinâmico entre workers (#241) | HOLD | `CHANGELOG.md` registra spikes depth 1 e 2 NOT_SUPPORTED; relay via Planner segue suportado. | Reavaliar apenas com capability nativa observável e spike isolado que demonstre transferência sem segundo Planner/controlador. |
| M6 — Continuidade e eficiência | PARCIAL | `evidence/confiabilidade-operacional-2026-11-17/RELATORIO.md:29-31` mantém HOLD de retomada automática; telemetria e métricas não constituem medição integrada de eficiência. | Reavaliar continuidade conforme critérios de HOLD; medir eficiência com baseline comparável e dados observados. |

## Correções ao diagnóstico recebido

- PRs #272, #274, #275, #276 e #277 já estão mergeadas; o handoff que dizia #272 aberta está desatualizado.
- Evidências anteriormente chamadas ausentes existem: `evidence/orchestration-autonomy-2026-11-17/` (1 arquivo), `evidence/planner-autonomy-e2e/` (8), `evidence/handoff-depth2-spike-2026-11-15/` (11), `evidence/mission-2026-11-13/` (12) e `cache/v3/telemetry/` (93). A existência não implica que provem todos os critérios deste plano.
- A política canônica em `source/registry/model-routing-policy.json:754-764` define Sol como candidato same-tier T4, não como degrau T3→Astra. O texto da #208 é histórico; `scripts/test-package-consistency.ps1:560` verifica a consistência.
- Handoff direto worker→worker (#241) é HOLD fundamentado por evidência negativa, não falta de vontade: `CHANGELOG.md` registra spikes depth 1 e 2 NOT_SUPPORTED. Relay via Planner segue suportado.

## Resequenciamento por dependências

**F0 plano (este documento) → F1 guardrail de isolamento + prova de hash → F2 certificação do instalador em HOME temporário → F3 prova de permissões → F4 pós-merge → F5 saneamento de issues/docs → F6 certificação A–E e eficiência.**

F3 depende de F1 e F2 porque a prova anterior alterou o perfil real (config de 33278 para 390 bytes, depois restaurada por hash) e não distinguiu `ask` de `allow`; executar nova prova antes de demonstrar contenção e isolamento repetiria risco de escrita fora do sandbox e produziria resultado não confiável. A causa exata do incidente não foi provada; o relatório aponta preparação do ensaio como hipótese provável. F4 reutiliza as primitivas existentes. F5 registra o estado produzido pelas certificações; F6 mede o fluxo integrado sem mascarar HOLDs.

## Critérios de aceite e teste mínimo

- **F0:** plano revisado, dependências explícitas, afirmações ancoradas ou marcadas como HOLD/não certificadas.
- **F1:** tentativa de destino fora do HOME temporário falha fechada; hashes independentes antes/depois confirmam que nenhum arquivo externo mudou. Não alterar a configuração ativa.
- **F2:** dois ciclos completos de instalação em HOME temporário, com hash externo antes/depois de cada ciclo e smoke leve Planner→worker. O pesado `prove-native-subagents.ps1` não substitui esse smoke, pois é provider-dependent.
- **F3:** em runtime descartável, demonstrar allow, ask (gate/evento observável) e deny com comandos que casem exatamente os padrões; registrar eventos de permissão e comprovar hashes externos inalterados. Apenas após aceite de F1 e F2.
- **F4:** fluxo pós-merge exercitado com merge normal e squash; worktree suja deve ser preservada/recusada, sem remoção forçada. Confirmar ownership e resultado por snapshot.
- **F5:** cada issue considerada recebe classificação revisada e evidência; documentos refletem status atual. Não fechar itens por lote sem revisão individual.
- **F6:** executar e registrar cenários A–E, incluindo Coder→Tester→Reviewer sem turno do Planner. Esse último permanece HOLD até existir suporte/runtime observável; critério de reavaliação: prova no binário exato, correlação das sessões e resultado verificável sem duplicar execução. Eficiência requer baseline e medições observadas de tempo/custo/turnos; sem isso, reportar não mensurada.

## HOLDs com critério de reavaliação

- **Retomada automática do Planner:** HOLD; reavaliar com primitiva nativa no binário exato, prova correlacionada de não-início, CAS/fencing ponta a ponta e wiring PREPARE→SUBAGENT→SETTLE→VERIFY→ADVANCE em runtime real (`evidence/confiabilidade-operacional-2026-11-17/RELATORIO.md:29-31`).
- **Handoff direto worker→worker (#241):** HOLD/NOT_SUPPORTED nos spikes realizados; reavaliar somente após capability nativa observável que permita transferência sem segundo Planner/controlador, seguida de spike isolado com sessão filha e configuração íntegra.
- **Permissões ask/deny em runtime ativo:** HOLD; não modificar configuração ativa. Reavaliar apenas após F1/F2 e prova descartável de allow/ask/deny, eventos e hashes externos íntegros.
- **Fallback real 429/quota/503:** HOLD; cobertura atual sintética. Reavaliar quando uma falha real, correlacionada e comprovadamente pré-início permitir validar a cadeia sem replay ambíguo.
- **Issues #69/#70:** não certificadas neste plano; reavaliar após localizar escopo e critério de aceite vigentes e produzir evidência específica para cada uma.
- **Telemetria de eficiência:** HOLD/não mensurada; reavaliar com baseline comparável e observações reais de latência, turnos e custo, sem inferir ganhos de métricas incompletas.

## Fora de escopo / não fazer

- Não criar daemon, scheduler, segundo Planner ou motor de workflow novo.
- Não fazer force-push, reset destrutivo nem remoção forçada de worktree.
- Não fechar issues em massa sem classificação revisada.
- Nenhum experimento ou teste na configuração ativa.
- Não editar política de modelos para transformar Sol em etapa T3→Astra; a fonte canônica prevalece sobre texto histórico.

## Riscos e mitigação

- **Escrita fora do sandbox:** guardrail de caminho e hashes independentes antes/depois; interromper se qualquer hash externo mudar.
- **Falso claim de permissão:** distinguir resposta HTTP de evento/gate efetivo; comandos devem casar exatamente as regras.
- **Automação duplicar efeitos:** preservar HOLD em execução ambígua e usar somente primitivas existentes com ownership explícito.
- **Prova parcial ser generalizada:** registrar versão do runtime, escopo, limitações e evidências por cenário; ausência de evidência não equivale a sucesso.
