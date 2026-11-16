# M0 — Comparação do PR #210 com `origin/master`

Data da inspeção: 2026-11-13. Checkout de análise: `feat/install-ownership-agent-config-20261111`, HEAD `8ea738b65152ee0a29db4e0d1436de1ca3ddd94f`; árvore inicialmente limpa. Referências remotas atualizadas por fetch; sem checkout/alteração das branches do PR. PR permanece fora da decisão deste memo: não foi alterado no GitHub.

## 1. O que o PR entrega

Diff da ponta `26c1f83` contra `origin/master`: 12 arquivos, +1887/-46. Commits exclusivos da ponta: `e46e398`, `6737645`, `26c1f83`.

| Commit | Entrega |
|---|---|
| `e46e398` | Porta o rascunho de Planner Haiku para a stack v1.4: política, seleção/roteamento, dispatch, CLI/kernel, wrapper, testes e documentação. |
| `6737645` | Reivindicação exclusiva/atômica de RunId no dispatch, em resposta a finding HIGH; evita concorrência/reuso da mesma execução. |
| `26c1f83` | Encaminha `-VerifierProfiles` pelo wrapper até o CLI do Task Kernel. |

Arquivos e função observável no patch:

| Arquivo | Conteúdo |
|---|---|
| `source/registry/model-routing-policy.json` | Acrescenta Planner Haiku como fallback T2 (com dados/capability gate) e campos de fallback do Planner. |
| `scripts/v3/lib/OrchestrationModelRouter.ps1` | Expande router v1.4, incluindo rota/planner Haiku, gates e resolução de política. |
| `scripts/v3/lib/OrchestrationPlannerHaikuDispatch.ps1` | Novo despacho do turno do Planner: valida/usa seleção, cria sessão/processo e correlaciona execução/estado via Kernel; RunId exclusivo no segundo commit. |
| `scripts/v3/invoke-planner-haiku-session.ps1` | Wrapper para invocar sessão Haiku e encaminhar parâmetros/verificadores ao Task Kernel. |
| `scripts/v3/lib/OrchestrationTaskKernel.ps1`, `scripts/v3/task-kernel.ps1` | Acrescentam integração/saída de fallback do Planner e suporte de chamada CLI necessário ao fluxo. |
| `scripts/v3/lib/OrchestrationModelRouterHaikuPlanner.tests.ps1` | Testes específicos de política/seleção Haiku. |
| `scripts/v3/lib/OrchestrationPlannerHaikuDispatch.tests.ps1` | Testes do dispatch, gates, estado e concorrência. |
| `scripts/v3/lib/OrchestrationModelRouter.tests.ps1`, `OrchestrationModelRouterV14.tests.ps1` | Ajustes das suítes existentes para a rota nova. |
| `source/adapters/opencode-v2.md`, `docs/guides/MODEL-ROUTER-v1.4-OPERATIONS.md` | Documentam Haiku no fluxo e operação/limitações da rota. |

Funcionalmente, “Planner Haiku T2” é uma alternativa de modelo para a sessão raiz do Planner, com seleção governada por política e uma implementação própria de dispatch/sessão ligada ao Kernel; não é apenas adicionar Haiku à lista de candidatos do router. A intenção é executar o turno do Planner em Haiku, incluindo persistência/correlação e verificação do ciclo. O patch não prova por si só uso produtivo/runtime atual; esta análise não executou as suítes nem o fluxo.

## 2. Estado atual e compatibilidade de política

Fontes consultadas em `origin/master` (HEAD `54a9d3c`): `source/registry/model-routing-policy.json`, `scripts/v3/lib/OrchestrationModelRouter.ps1`, `docs/guides/MODEL-ROUTER-v1.4-OPERATIONS.md`, `source/adapters/opencode-v2.md` e SPEC/PLAN `docs/specs/EVOLUTION-INTEGRATED-2026-11-10-*`.

- A cadeia normativa atual é Sonnet (T3) → Opus (T4) → Astra (excepcional, somente com provas/gates); Sol é candidato técnico de mesmo tier T4, não degrau intermediário. O Planner canônico atual é DeepSeek Go T2, sem fallback automático configurado na política; a integração operacional/documentada mais recente mantém build/Planner em Luna T2 fixo, sem fallback automático. A divergência é explicitamente registrada como decisão antiga não a reintegrar: SPEC/PLAN dizem para não integrar configuração anterior ao merge #236. O status corrente precisa ser lido como política + documentação integrada, não inferido de qualquer campo isolado.
- A política ainda lista `claude_haiku` como candidato T2 para papéis elegíveis, mas declara alias/runtime não verificado e não lhe confere papel de Planner/build. A lista estática não é autorização de dispatch/fallback produtivo.
- O novo fluxo do PR sobrepõe-se às primitivas já entregues `task-kernel model-select` e `model-proof`: essas selecionam modelo/provas read-only; `model-select` não despacha/cria sessão. O próprio guia atual diz que a rota canônica é model-select e que o binding produtivo completo segue parcial, com evidência manual. Portanto há uma lacuna real de automação de dispatch, mas não evidência de que deva ser preenchida por segundo dispatch Haiku/Planner.
- Há conflito material de política: Planner Haiku contradiz o Planner/build atual e as decisões de papel/roteamento, mesmo que Haiku permaneça candidato T2 em outros papéis. Haiku também introduz custo/uso que não foi medido nesta inspeção.
- Risco específico de pacote: `scripts/test-package-consistency.ps1` check 17 valida consistência adapter/política e a cadeia Sonnet→Opus→Astra. O próprio código atual contém referências históricas a Planner Haiku (`template: build deve usar MODEL_PLANNER (Haiku)` e mensagem equivalente para `agents.build.model`). Isso torna a porta especialmente sensível a regressão/drift: não foi executada a suíte para confirmar se a versão atual já concilia essas asserções, e o plano reporta 17/17 numa revisão recente. Qualquer reaplicação precisa ajustar os invariantes para a decisão vigente, não recuperar check antigo por cópia.

## 3. Conflito concreto

`git merge-tree $(git merge-base origin/master origin/feat/planner-haiku-router-stack-20261104) origin/master origin/feat/planner-haiku-router-stack-20261104` foi executado sem mexer no working tree. Conflitos “changed in both” identificados:

- `docs/guides/MODEL-ROUTER-v1.4-OPERATIONS.md`: documentação v1.4 mudou para refletir operação e limites atuais; patch tenta documentar/operar Planner Haiku.
- `scripts/v3/lib/OrchestrationModelRouter.ps1`: ambos alteram o router; master incorpora política/provas de seleção e limites recentes; PR insere dispatch/rota de Planner anterior. Resolver por merge mecânico arrisca recuperar bypass/semântica obsoleta.
- `scripts/v3/lib/OrchestrationModelRouter.tests.ps1` e `OrchestrationModelRouterV14.tests.ps1`: expectativas evoluíram junto da política e gates.
- `scripts/v3/lib/OrchestrationTaskKernel.ps1`: master adiciona regras/contratos Kernel que a fatia antiga não conhece; não se deve sobrescrever.
- `source/adapters/opencode-v2.md`: contrato do Planner e cadeia canônica foram atualizados, incompatíveis com texto do PR.
- `source/registry/model-routing-policy.json`: atualizações de roles, candidatos, gates e modelo Planner divergem diretamente.

Arquivos só adicionados pelo PR (não conflito textual, mas requerem integração deliberada): wrapper, `OrchestrationPlannerHaikuDispatch.ps1` e seus testes, teste Haiku dedicado. `scripts/v3/task-kernel.ps1` é alterado pela ponta e deve ser revisado por hunks: merge-tree não o marcou changed-in-both, mas o patch acrescenta interface/saída e sua integração com CLI/contrato atual deve ser revalidada. O conflito estrutural implica resolução cuidadosa adicional; não foi medido número de hunk/manual merge.

Aplicabilidade dos testes PR: `OrchestrationPlannerHaikuDispatch.tests.ps1` é útil como ponto de partida para invariantes genéricos de dispatch/RunId, mas seus contratos e fixtures precisam ser adaptados ao Planner/Kernel atual. `OrchestrationModelRouterHaikuPlanner.tests.ps1` não deve ser aplicado como prova de autorização Haiku para Planner; só vale preservar testes negativos de alias/prova/recusa. `OrchestrationModelRouterV14.tests.ps1` permanece relevante como regressão, mas expectativas antigas de rota precisam ser reescritas conforme política atual. Nenhum desses três foi executado.

## 4. Valor, custo e riscos

Descartar perde a implementação de dispatch de sessão, proteção de RunId, wrapper e testes que podem servir de referência caso a automação de sessão seja aprovada. Não se perde a política geral de Haiku como candidato T2 já presente em master, nem as primitivas `model-select`/`model-proof`.

Reabrir exige, no mínimo, portar seletivamente dispatch/RunId/wrapper e testes; redesenhar a interface em torno do fluxo canônico de Planner e kernel atual; resolver manualmente os seis arquivos conflitados listados, além da revisão de integração CLI. Estimativa quantitativa de horas/hunks não medida. Risco de regressão é maior em router, policy, adapter e Kernel/CLI, porque são superfícies de autoridade/prova, não código isolado.

Riscos: (1) custo de Planner Haiku não medido e adequação/custo por DONE não demonstrados; (2) política antiga permite drift da cadeia e do papel do build; (3) check 17 pode denunciar ou sofrer regressão se adapter/policy reintroduzirem Haiku Planner; (4) dispatch paralelo duplica responsabilidade de `model-select` e bindings do Planner, com risco de divergência de evidência/identidade e enforcement. Não foi feita medição de custo nem teste de regressão.

## 5. Recomendação

**Recomendação técnica: DISCARD como proposta de integração funcional na forma atual; preservar apenas como referência histórica.** Não é recomendação para fechar o PR: decisão/ação no GitHub pertence ao usuário/maintainer e não foi tomada.

Critério objetivo para o usuário decidir eventual reabertura: só reabrir se houver decisão explícita de produto que substitua a política atual e aceite Planner Haiku (incluindo privacidade, custo medido e papel de execução), mais lacuna demonstrada que `model-select`/dispatch canônico não atende. Nesse caso, portar seletivamente a proteção RunId, wrapper e testes genéricos de dispatch, sem cherry-pick da política/adapter/router/kernel antigos; especificar um único ponto de dispatch e provar compatibilidade com `model-select`/`model-proof` e check 17. Sem esses critérios, descartar a feature antiga evita bifurcação de autoridade.

## 6. Limitações

Não houve execução de código, testes do PR, suíte do master, teste-package-consistency, dispatch real, medição de custo nem verificação de credenciais/runtime. Não houve consulta/ação na API do GitHub; estado OPEN/CONFLICTING e metadados do PR são os fornecidos na tarefa, enquanto comparação Git foi feita com as refs fetchadas. O merge-tree é uma comparação estrutural, não resolução nem validação de merge. O working tree permaneceu sem alterações até a criação deste memo.
