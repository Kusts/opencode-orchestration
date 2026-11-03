# ADR-201 — Rota direta padrão para trivial elegível (functional-first)

**Status:** Aprovado (piloto #201, escopo mínimo).
**Data:** 2026-11-03.
**Dono da política global:** Agent Config #21 — este ADR decide só o comportamento
do preflight/orquestração e referencia a política global em vez de duplicá-la.

## Contexto

O classificador `isTrivial` e o gate `DIRECT_VERIFIED` já existiam e já eram
seguros (low risk, localizado, tipo conhecido, sem decisão arquitetural, leitura
ou microedição docs-only sem palavra sensível; `Test-OrchestrationDoneCompliance`
já aprovava `DIRECT_VERIFIED` com zero workers). Mas o preflight só retornava
`DIRECT_VERIFIED` com `ExecutionStrategy=DIRECT_VERIFIED` explícito e, por padrão,
despachava 1 worker (`SINGLE_WORKER` → `coder`) até para o caso já classificado
como trivial — observado no CLI antes da mudança:

`fix typo in README` (cosmetic/docs/low/write) → `SINGLE_WORKER`, `selected_agents=[coder]`.

## Decisão

Trivial elegível segue `DIRECT_VERIFIED` por padrão (zero workers, mesmo
`direct_reason` e mesmo gate de DONE existentes). `SINGLE_WORKER` explícito
permanece disponível quando a delegação trouxer benefício concreto. Nenhum
estado, flag, gate, permissão ou invariante do Kernel foi alterado.

## Fatia 2 — rota direta independe do router (bloqueador falso observado)

Observado pós-fatia 1 (reproduzível via CLI):

`fix typo in README` (cosmetic/docs/low/write) + `-RouterHealthy false` →
`DETERMINISTIC_FALLBACK` / `router_unavailable` (`task_class` non_trivial,
sem `direct_reason`) — mesmo com o classificador `isTrivial` atendido.

Causa: o bloco de saúde do router/registry ficava antes da seleção direta e
barrava até o caminho direto, que é 100% local (classificador fail-closed +
gate de DONE existentes) e não usa o router. Correção limitada: o retorno
`DIRECT_VERIFIED` (estratégia omitida ou exatamente `DIRECT_VERIFIED`) agora
ocorre antes da checagem de saúde; a checagem continua valendo para
`SINGLE_WORKER` explícito e para todo roteamento não trivial com workers.
Ordem preservada: exclusões rígidas → tarefa vaga → promoção de goal →
seleção direta → saúde router/registry → delegação. Compatibilidade de
`ExecutionStrategy` (input do chamador): direta só com estratégia omitida/vazia
ou exatamente `DIRECT_VERIFIED`; `SINGLE_WORKER` explícito continua delegado;
valor não reconhecido e não vazio permanece delegado (fallback seguro anterior),
nunca vira direta.

## Fatia 3 — correção: goal continua gated pelo router (sem enfraquecer rota delegada)

A ordem documentada na fatia 2 permitia que `PERSISTENT_GOAL` (não trivial, com
workers) passasse com router/registry unhealthy — risco real de aceitação:
só trabalho direto-seguro pode dispensar o router. Correção mínima: o ramo de
promoção de goal (explícita e spec+plan) honra a saúde router/registry com gate
inline (mesmo mapeamento de reason, sem helper novo) e preserva decision/reason
originais (`router_unavailable` / `registry_stale` / `router_unhealthy`). Nada
mais mudou: só trivial elegível com estratégia omitida ou `DIRECT_VERIFIED`
exata dispensa a checagem; `SINGLE_WORKER` explícito, estratégia inválida não
vazia, goal e todo roteamento não trivial seguem gated.

## Tabela KEEP / SIMPLIFY / REUSE / DEFER / REMOVE

| Item | Veredito | Evidência |
|---|---|---|
| Default worker-para-trivial (`SINGLE_WORKER` implícito) | SIMPLIFY | Removida a exigência de opt-in explícito; 1 chamada de worker → 0 no caso elegível (sem alegar segundos/custo). |
| Classificador `isTrivial` + `direct_reason` + gate `DIRECT_VERIFIED` | REUSE | Inalterados; ver `docs/plans/DIRECT-EXECUTION-PROPORTIONAL-VALIDATION-ADR.md` e `Test-OrchestrationDoneCompliance` (casos 15b). |
| Kernel CAS, evidência, grants, review, proteções high-risk/produção | KEEP | `OrchestrationTaskKernel.ps1` intocado; non-trivial/high-risk/arquitetura/segurança/credencial/database/migration/delete continuam fora da rota direta (fail-closed). |
| Prova Kernel E2E (coder→tester→reviewer, DONE COMPLIANT) | REUSE (#51) | `evidence/v3.1/runtime-reliability/subagents-native-execution-proof.json`; não reexecutada neste piloto. |
| Inventário de capabilities nativas | DEFER (#137) | Dono existente; nenhum artefato novo aqui. |
| Golden Workflows | DEFER (#30) | Dono existente; `OrchestrationAdvisorEfficiencyGW.tests.ps1` intocado (usa estratégia explícita, comportamento idêntico). |
| Segunda política global / novo framework | REMOVE (não criar) | Blocos V2 atualizados por referência curta; canônico global segue Agent Config #21. |
| Checagem router/registry antes da direta (falso bloqueador) | SIMPLIFY | Retorno direto ocorre antes da checagem; delegação e não trivial seguem gated (casos 7/8/16, controles 15d). |
| `ExecutionStrategy` inválida virando direta | KEEP (seguro anterior) | Só omitida/vazia ou `DIRECT_VERIFIED` exata libera direta; demais valores seguem delegados. |

## Validação

- TDD fatia 1: novo caso 15c falhou antes (`SINGLE_WORKER`+`coder`) e passou depois
  (`DIRECT_VERIFIED`, zero workers, DONE `COMPLIANT` com participação 0).
- TDD fatia 2: novos casos 15d falharam antes (`router_unavailable`/`registry_stale`)
  e passam depois; controles (`SINGLE_WORKER` explícito + router unhealthy →
  fallback; nontrivial + router unhealthy → fallback inalterado; estratégia
  inválida → delegada, não direta) verdes.
- TDD fatia 3: novos casos 15e falharam antes (`PERSISTENT_GOAL` com workers e
  router unhealthy) e passam depois (fallback `router_unavailable` /
  `registry_stale` idênticos aos originais); direta + unhealthy segue direta.
- `scripts/v3/orchestration-preflight.tests.ps1`: 83/83, exit 0.
- CLI: caso-base agora `DIRECT_VERIFIED` (`DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK`,
  `selected_agents=[]`); `SINGLE_WORKER` explícito preserva delegação;
  migração database/high-risk segue `DETERMINISTIC_FALLBACK`; direta elegível +
  `-RouterHealthy false` → `DIRECT_VERIFIED` (bloqueador eliminado).
- Fluxo funcional direto real no OpenCode (2026-11-03): o preflight CLI para
  `Find the direct route selection branch` retornou `DIRECT_VERIFIED`,
  `selected_agents=[]`; o Planner leu o ramo ativo (`OrchestrationPreflight.ps1`,
  linhas 465–494) pela ferramenta nativa `read`; a verificação existente
  `Test-OrchestrationDoneCompliance` retornou `COMPLIANT` com zero workers.
  Em seguida, o resultado foi registrado aqui por uma microedição direta,
  também classificada `DIRECT_VERIFIED` (`Record the direct read result in
  pilot notes`, `selected_agents=[]`); `git diff --check` passou.
- Esta é prova funcional real do caminho local de leitura/documentação, não
  prova E2E de delegação/Task Kernel. A prova de Kernel da #51 foi reutilizada
  sem nova execução.

## Correção — intento substantivo com metadados triviais (2026-11-03)

Misclassificação confirmada via CLI antes da correção:

`Implement new workflow` (`trivial`/`docs`/`low`/`read`) →
`DIRECT_VERIFIED` (`DIRECT_VERIFIED_LOW_RISK_LOCALIZED`, zero workers).

Causa: o classificador `isTrivial` confiava nos metadados (`TaskType`/`Risk`/
`ReadWrite`/`Domain`) e não rejeitava intento substantivo no `Objective`
(verbo de criação/expansão). Correção mínima, sem classificador/framework/gate
novo: o ramo direto passa a exigir `(-not $substantiveHit)`, onde
`$substantiveHit` usa o predicado existente `Test-OrchestrationKeyword` sobre
o `Objective` normalizado (verbos `implement`/`build`/`creat`/`develop`/
`design`/`refactor`/`rewrit`/`rework`/`extend`/`integrat`/`migrat`/`overhaul`
+ frases `new workflow|feature|module|endpoint|service|pipeline|system` e
`add new|feature|module|endpoint|service|workflow`). Vale para leitura e para
microedição docs-only; ordem preservada (exclusões → vaga → goal → direta →
saúde → delegação); direta continua independente do router; `SINGLE_WORKER`
explícito, DONE, Kernel/CAS/grants/evidência e fail-closed inalterados.

Validação: novos casos 15f falharam antes (2 falhas) e passam depois; controles
typo (`fix typo in label`) e point lookup (`where is retry flag defined`)
seguem `DIRECT_VERIFIED`; adversário agora `MULTI_WORKER` (`coder`,
`UNVERIFIED_POST_EXECUTION_REQUIRED`, rota com worker pelo contrato
existente). `scripts/v3/orchestration-preflight.tests.ps1`: 87/87, exit 0.

## Segunda revisão — evidência limitada + rejeição de escopo amplo (2026-11-03)

Contraexemplos confirmados via CLI antes da correção (ambos com
`trivial`/`docs`/`low`/`read` ainda `DIRECT_VERIFIED`):

- `what should change across these modules?` → `DIRECT_VERIFIED`
  (`DIRECT_VERIFIED_LOW_RISK_LOCALIZED`, zero workers).
- `Find all usages of retry policy across the repository` → `DIRECT_VERIFIED`
  (mesmo `direct_reason`, zero workers).

Causa: o ramo direto exigia apenas ausência de intento substantivo; metadados
sozinhos autorizavam a direta quando o intento/escopo era substantivo mas sem
verbo da lista (`change`, `find`, `usages` não constavam). Correção mínima, sem
classificador/função/framework/gate novo: o ramo direto passa a exigir,
via o predicado existente `Test-OrchestrationKeyword` sobre o `Objective`
normalizado, evidência objetiva de leitura pontual/microedição (`$boundedHit`:
`typo|fix|corrig|correct|where|defined|defin|lookup|inspect|inspec|label|flag|
readme|header|button|planilha|custo|onde|qual`) **e** ausência de sinal de
escopo amplo (`$broadScopeHit`: `across|throughout|all|every|entire|whole|
multiple|several|various|codebase|repository|repositorio|modules|modulos|
usages|usage|todos|todas|inteir|varios|varias`), mesmo com verbo de consulta
presente. Vale para leitura e para microedição docs-only; ordem preservada
(exclusões → vaga → goal → direta → saúde → delegação); direta continua
independente do router; `SINGLE_WORKER` explícito, DONE,
Kernel/CAS/grants/evidência e fail-closed inalterados.

Evidência limitada usada (observada, não alegada): ambos os contraexemplos
agora `MULTI_WORKER` (`coder`, `UNVERIFIED_POST_EXECUTION_REQUIRED`); variantes
de quantificador (`list every handler in the entire service`,
`summarize changes across multiple modules`) também delegadas;
`fix typo in all labels` delegado pelo `all` mesmo com evidência `typo`
(escopo amplo vence evidência limitada). Controles conservados:
`fix typo in label`, `where is retry flag defined`, `fix typo in README`
(docs/write) seguem `DIRECT_VERIFIED`; `SINGLE_WORKER` explícito segue
delegado; singular pontual (`Find retry flag in billing module`) segue direto
— o bloquieo de plural usa `modules|modulos` (prefixo só casa plural), e
`Find ... in auth module` cai no `DETERMINISTIC_FALLBACK` preexistente de
hard-exclusion (`auth`), não nesta mudança.

Limites heurísticos restantes: casamento por prefixo (`all` casa
`allocate|allow`, `qual` casa `qualquer|qualidade`) pode super- ou
sub-rejeitar; a direção é fail-closed para delegação (nunca bypass), e a
precisão continua dependendo do chamador em `Risk`/`TaskType`/`Objective`.

Validação: novos casos 15h falharam antes (6 falhas, 94/100) e passam depois;
`scripts/v3/orchestration-preflight.tests.ps1`: 100/100.

## Terceira revisão — verbo genérico `fix` não estabelece trivialidade (2026-11-03)

Causa raiz confirmada pelo Debugger e reproduzida via CLI antes da correção
(ambos com `trivial`/`docs`/`low`, `read` e `docs`/`write` ainda
`DIRECT_VERIFIED`, zero workers):

- `Fix system behavior` → `DIRECT_VERIFIED`.
- `Fix error handling in the workflow` → `DIRECT_VERIFIED`.

Causa: o `$boundedHit` genérico aceitava `fix`/`corrig`/`correct` sozinho (mais
substantivos genéricos como `label`/`flag`/`readme`/`header`/`button`/
`planilha`/`custo`) como evidência suficiente. Qualquer objetivo com a palavra
`fix` passava na direta com metadados triviais, sem evidência objetiva de
leitura pontual ou microedição específica; substantivos como
`system`/`error`/`workflow` não bloqueavam nada.

Correção mínima, sem função/classificador/framework/gate novo, só com o
predicado existente `Test-OrchestrationKeyword` e um ou dois booleanos locais
nas condições existentes `isReadTrivial`/`isMicroEditWrite`:

- `$pointLookupHit` (leituras pontuais): `where|defined|defin|lookup|inspect|
  inspec|locate|localiz|point lookup|specific symbol|onde|qual`.
- `$microEditHit` (microedição específica): `typo|spelling|grammar|
  punctuation|comma|period|whitespace|spacing|heading|label text|one-word|
  one word|single-line|single line|comment|virgula|ortograf|gramat`.
- Leitura trivial exige (`$pointLookupHit` ou `$microEditHit`); microedição
  `docs`-only em escrita exige `$microEditHit`. `fix`/`correct` sozinho e
  substantivos (`system`/`error`/`workflow`) não autorizam mais nada; `typo`
  segue autorizando microedição em leitura e escrita.
- Escopo amplo continua negando: quantificadores exatos (`all`/`every`/
  `multiple`/`several`/`various`/`todos`/`todas`) via `-Exact` — o modo
  `-Words` usa starts-with e `all` casava `allow`/`allocate` — e frases de
  escopo repo-wide (`across|throughout|entire|whole|codebase|repository|
  repositorio|modules|modulos|usages|usage|inteir|varios|varias`) via
  `-Words`. Verbos substantivos/análise/review como deny cues inalterados.
- Ordem preservada (exclusões → vaga → goal → direta → saúde → delegação);
  direta continua independente do router; `SINGLE_WORKER` explícito, DONE,
  Kernel/CAS/grants/evidência e fail-closed inalterados.

Nota honesta de comportamento: `Find retry flag in billing module` (citado na
revisão anterior como direto por ser singular) agora delega — `find` puro sem
`where`/`defined`/`lookup`/`inspect`/`locate` não é mais evidência pontual.
Direção fail-closed para delegação (nunca bypass); nenhum caso da suite
afirmava direta para esse objetivo, sem regressão.

Controles conservados e verificados: `fix typo in label` (read),
`fix typo in README` (docs/write), `where is retry flag defined`,
`point lookup: where ...`, `inspect plant labels`,
`inspecionar planilha de custos` seguem `DIRECT_VERIFIED`; `fix typo in allow
list` volta a `DIRECT_VERIFIED` (prova do `-Exact` contra o overmatch `all`/
`allow`); `SINGLE_WORKER` explícito segue delegado; direta elegível +
router unhealthy segue direta; `delete` sensível e migração high-risk seguem
fora da direta; gate DONE/Kernel inalterado.

Validação (observada, não alegada): novos casos 15i falharam antes (7 falhas,
108/115 — os 4 genéricos `fix` em read+write mais o overmatch `allow`; a frase
ampla `Fix the workflow behavior across modules` já delegava e entrou como
regressão) e passam depois;
`scripts/v3/orchestration-preflight.tests.ps1`: 115/115, exit 0;
`scripts/test-package-consistency.ps1`: 16/16; `git diff --check` limpo nos
arquivos tocados.

## Correcao limitada — pista PT `pontuac` + escopo amplo `everywhere/globally` (2026-11-03)

Dois contraexemplos confirmados antes da correcao:

- `corrigir pontuacao no guia de instalacao` (`cosmetic`/`docs`/`low`/`write`)
  caia em `MULTI_WORKER` (INT-01 `INT-01-DIRECT` falhava): a lista de
  microedicao tinha `punctuation`/`virgula`/`ortograf`/`gramat` mas nao o
  radical PT `pontuac` (o helper existente ja normaliza `pontuacao` sem
  acento). Correcao minima: acrescentar `pontuac` a `$microEditHit` via o
  predicado existente — sem `corrigir`/`fix` generico, que reabriria o
  bypass substantivo.
- `Where is this symbol defined everywhere?` (`trivial`/`docs`/`low`/`read`,
  com pista pontual `where`/`defined`) seguia `DIRECT_VERIFIED`: a lista de
  escopo amplo nao cobria `everywhere`/`globally`/`globalmente` nem formas
  `repo-wide`. Correcao minima, mesmo predicado existente:
  `$broadScopeHit` ganha `-Exact` `everywhere|globally|globalmente`
  (token cheio, sem overmatch por prefixo) e frases `repo-wide|repo wide|
  throughout the repository|codebase|repo` em `-Words`.

Validação: novos casos 15j falharam antes (7 falhas, 116/123) e passam
depois; `scripts/v3/orchestration-preflight.tests.ps1`: 123/123;
`scripts/v3/lib/OrchestrationAdvisorEfficiencyGW.tests.ps1`: 146/146
(via `pwsh`); `scripts/test-package-consistency.ps1`: 16/16;
`git diff --check` limpo. Controles conservados: typo EN, point lookup,
`inspect`/`planilha`, `SINGLE_WORKER` explicito, direta elegivel
independente do router, rejeitos de analise/investigacao/multi-file e de
`fix` generico, contratos de risco/seguranca/DONE.

## Riscos

- Classificação errada de trivial é contida pelo gate existente (fail-closed),
  mas continua dependendo da precisão do chamador em `Risk`/`TaskType`.
- Sem telemetria nova neste piloto; recorrência de bypass segue observável nos
  canais existentes.

## Nota de honestidade de medição (2026-11-03)

- Custo real, contexto e qualidade de tarefa direta integral (Planner LLM
  executando até DONE) são NOT_PROVEN: nenhum trace de ponta a ponta com
  tokens/custo/qualidade foi coletado neste piloto.
- A evidência E2E da #51
  (`evidence/v3.1/runtime-reliability/subagents-native-execution-proof.json`)
  é multi-agente e pode ser reutilizada como prova de Kernel delegada, mas
  não é comparação pareada com tarefa direta integral.
- Nenhuma nova execução E2E foi realizada para este ajuste.
