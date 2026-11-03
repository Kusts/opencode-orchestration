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

## Riscos

- Classificação errada de trivial é contida pelo gate existente (fail-closed),
  mas continua dependendo da precisão do chamador em `Risk`/`TaskType`.
- Sem telemetria nova neste piloto; recorrência de bypass segue observável nos
  canais existentes.
