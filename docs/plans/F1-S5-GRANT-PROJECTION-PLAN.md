# F1 S5 — Projeção deny-only de grants de origem (fixture-only)

Status: PLANEJADO (fixture-only; flags permanecem OFF; sem claim runtime-real).
Base: `master` `e70f96b` (S1 #131, S2 #132, S3a #133 mergeados).
Fatia: F1-S5 do plano `docs/plans/PENDING-IMPLEMENTATION-PLAN-2026-10-19.md`
("grants de origem + projeção deny-only + fail-closed sem bridge"; paralela a S1-S2).

## 1. Objetivo

Adicionar à bridge de CLAIM já existente uma leitura canônica dos **grants de
origem** e uma **projeção pura deny-only** desses grants para a invocação
isolada, de modo que o hook `execute.before` do plugin `g1-dispatch-admission`
recuse a invocação quando os grants pedidos pela origem não estiverem no
conjunto efetivo — sempre falhando fechado quando a bridge, a projeção ou a
fonte estiverem ausentes, inválidas ou ilegíveis.

A S5 **não** ativa `runtime_grant_enforcement`, **não** muda o schema de
admissão `Test-NDAdmissionDecision`, **não** altera o TaskKernel, o ND, o
registry de grants, os flags ou o plugin TypeScript `orchestration-enforcement`.
Ela entrega a projeção e o consumo no caminho isolado da S1; a ativação e o
runtime-real continuam decisão de operador (S6/enforcement).

## 2. Contexto e evidência da descoberta

- A S1 (`scripts/v3/native-dispatch-claim.ps1` + `plugins/g1-dispatch-admission`)
  já consome UM preparo durável e devolve `grants_authority/verified_pass/
  done_approved=false`; o hook isolado é deny-only, tool-first, spawn
  `shell:false`, e já falha fechado sem bridge.
- Os grants de origem hoje são quatro fontes sem autoridade de runtime:
  `source/registry/execution-grants.json` (universo + baselines), o
  TaskKernel (`Get-OrchestrationEffectiveGrants` = interseção baseline ∩ task ∩
  runtime-capability ∩ environment; sensíveis só com as três listas +
  `HumanApproved`), o envelope de Authorization (observação, sem authority) e
  o admission record do ND (tupla de admissão; não é grant).
- Não existe hoje projeção de grants: o hook só decide admissão. A S5 cria a
  projeção sem duplicar a interseção do kernel.

## 3. Não-objetivos

- Ativar/alterar qualquer flag (`runtime_grant_enforcement`, `task_kernel`,
  `capability_router`, `skill_routing`, `mcp_routing`, `adaptive_ranking`).
- Alterar `OrchestrationNativeDispatch.ps1`, `OrchestrationTaskKernel.ps1`,
  `source/registry/execution-grants.json`, `source/registry/capability-flags.json`
  ou o plugin TypeScript `orchestration-enforcement`.
- Alterar o schema/record de admissão do ND ou o `decide()` canônico do plugin
  `g1-dispatch-admission` (a projeção é aditiva no caminho isolado).
- Alegar runtime-real, enforcement, G3/S6 ou autoridade de grant.
- Provar o `permission.evaluate` canônico (segue deny-by-default/admission-only;
  residual documentado, não resolvido aqui).

## 4. Decisões de desenho

D1. **Snapshot canônico, sem reimplementar a interseção.** A nova lib
`OrchestrationNativeDispatchGrantProjection.ps1` expõe
`Get-NDGrantSourceSnapshot`, que lê a task canônica (`tasks_dir` +
`receipt.task_id`), o papel (`receipt.agent`) e chama
`Get-OrchestrationEffectiveGrants` com:
`-Role <receipt.agent>`, `-TaskGrants <task.grants>`,
`-RuntimeCapabilityGrants <context.runtime_capability_grants>`,
`-EnvironmentAuthorizationGrants <context.environment_grants>`,
`-HumanApproved:<context.human_approved>`, `-GrantsPath` e `-RepoRoot`.
O `GrantsPath` é o registry canônico do repo (`Get-TaskKernelDefaultGrantsPath`
a partir do `RepoRoot` da própria bridge); a ausência/invalidade do registry →
snapshot inválido (fail-closed). O `flags_path` do contexto continua sendo o
arquivo de flags (revisão/source_revision), não o registry de grants.

D2. **Projeção pura deny-only.** `Test-NDGrantProjection` recebe o snapshot e
os grants pedidos pela origem (os `task.grants`, a origem do pedido) e devolve
apenas `denied` (grant + reason) — nunca `allow`, nunca `authority`. A
comparação é ordinal (case-sensitive), com universo fechado; grant pedido fora
do efetivo, desconhecido ou inválido → `denied`; lista pedida vazia → clear
(abstenção, jamais allow).

D3. **Contexto da bridge aditivo e estrito.** O schema do arquivo de contexto
da S1 ganha três campos estritos, com defaults fail-closed:
`runtime_capability_grants` (array de strings, default `[]`),
`environment_grants` (array de strings, default `[]`),
`human_approved` (bool, default `false`). Campos desconhecidos continuam
rejeitados. As fixtures S1 são atualizadas para declarar os conjuntos que
reproduzem o comportamento atual (mesmos grants da task), sem ampliar nada.

D4. **Envelope da bridge aditivo.** O envelope de CLAIM ganha
`grant_projection` (objeto), sempre presente:
`{ ok, source_revision, denied: [{grant, reason}], reason, authority: false }`.
`source_revision` é o hash determinístico (`Get-NativeDispatchHash32`) da
revisão da task + revisão dos flags + lista efetiva ordenada. Em refusal de
claim a projeção vem `ok=false`, `reason=grant-source-not-evaluated`,
`denied=[]` — o hook usa primeiro a recusa do claim. Os pins
`grants_authority/verified_pass/done_approved=false` permanecem.

D5. **Consumo no hook isolado (nunca allow).** `parseIsolatedClaimResponse`
valida o shape exato do `grant_projection` (`keys` exatas, `authority===false`,
`source_revision` 32 hex, `denied` array de `{grant,reason}` strings,
comprimentos limitados). O handler:
1. mantém a recusa do claim quando `ok/claimed` não são `true`;
2. `grant_projection.ok !== true` → deny `isolated-grant-projection-<reason>`;
3. `denied.length > 0` → deny `isolated-grant-denied` (reason sanitizada);
4. projeção clear → comportamento S1 existente (retorna `undefined`; a
   política de permissão do host decide; o hook nunca retorna allow).
Bridge ausente/timeout/erro/forma inválida → deny (fail-closed já existente,
estendido à projeção).

D6. **CI dos testes node do plugin isolado.** `scripts/ci/typecheck-plugin.ps1`
passa a executar também os testes node de `plugins/g1-dispatch-admission`
(fechando o follow-up conhecido), sem alterar o typecheck do
`orchestration-enforcement`.

D7. **Escopo do hook.** A projeção é aplicada ao caminho isolado da S1
(`execute.before` + bridge claim). O `permission.evaluate` canônico e o plugin
TS `orchestration-enforcement` ficam fora; o residual é declarado na seção 9.

## 5. Contrato

### 5.1 `Get-NDGrantSourceSnapshot`

Entrada: `-Role`, `-Task` (objeto canônico já lido), `-RuntimeCapabilityGrants`,
`-EnvironmentGrants`, `-HumanApproved`, `-GrantsPath`, `-RepoRoot`.

Saída (objeto): `ok`, `reason`, `source_revision`, `grants` (array ordenado
ordinal), `denied_by_default=true`, `authority=false`.
Erros fail-closed: `grant-source-task-missing`, `grant-source-role-missing`,
`grant-source-registry-missing`, `grant-source-invalid`, `grant-source-unavailable`.

### 5.2 `Test-NDGrantProjection`

Entrada: `-Snapshot`, `-RequestedGrants` (origem; `task.grants`),
`-InvocationGrants` (opcional; grants extras da invocação, se houver).

Saída: `ok`, `denied` (array de `{grant, reason}`), `reason`
(`grant-projection-clear` | `grant-projection-denied` | `grant-projection-invalid`),
`authority=false`. Nunca emite allow/autorização. Comparação ordinal, sem
case-folding, sem substring, sem união.

### 5.3 Bridge `native-dispatch-claim.ps1`

- Contexto: três campos novos (D3), validação estrita (arrays de strings,
  bool exato, sem coerção).
- Após o claim `ok=true/claimed=true`: lê a task pelo `receipt.task_id` em
  `tasks_dir`, chama o snapshot/projeção e acrescenta `grant_projection`.
- Em refusal/erro de claim: `grant_projection.ok=false`,
  `reason=grant-source-not-evaluated`, `denied=[]`, `authority=false`.
- Sem novo action; exit codes 0/1/2 inalterados; envelope ≤ 64 KiB.

### 5.4 Hook `plugins/g1-dispatch-admission`

- `parseIsolatedClaimResponse`: `want` inclui `grant_projection`; valida as
  chaves exatas, tipos, limites e `authority===false`.
- `makeIsolatedClaimHandler`: recusa do claim primeiro; depois projeção
  `!ok`/`denied` → deny; clear → `undefined` (nunca allow).
- Falha de bridge/shape/projeção → deny com código sanitizado.

### 5.5 CI

`typecheck-plugin.ps1` executa `node --test plugins/g1-dispatch-admission`
(os testes existentes + os novos), além do typecheck atual.

## 6. Invariantes

1. Nenhum caminho produz `allow:true` ou autoridade de grant; a projeção é
   observação e o hook é deny-only.
2. Nenhuma flag é ativada; `runtime_grant_enforcement` continua OFF.
3. A interseção de grants é a do kernel; a S5 não a reimplementa nem a amplia.
4. A projeção é ordinal e fechada; desconhecido/extra → deny.
5. Ausência/invalidade de bridge, contexto, task, registry, snapshot ou
   projeção → deny (fail-closed).
6. Nenhum store novo, nenhum arquivo de admissão escrito pela S5; o bridge
   continua sem escrever admission.
7. Fixture-only: nenhum claim de runtime-real, G3/S6 ou enforcement.
8. ND, TaskKernel, registry de grants, flags e plugin TS intocados.

## 7. Arquivos

Novos:
- `scripts/v3/lib/OrchestrationNativeDispatchGrantProjection.ps1`
- `scripts/v3/lib/OrchestrationNativeDispatchGrantProjection.tests.ps1`
- este plano.

Alterados:
- `scripts/v3/native-dispatch-claim.ps1` (contexto + envelope + projeção)
- testes S1 da bridge (fixtures/contexto + shape do envelope)
- `plugins/g1-dispatch-admission/index.js` (parse + handler)
- `plugins/g1-dispatch-admission/index.tests.js` (casos S5)
- `scripts/ci/typecheck-plugin.ps1` (node tests)
- `CHANGELOG.md` (`[Unreleased]`).

Intocados: `OrchestrationNativeDispatch.ps1`, `OrchestrationTaskKernel.ps1`,
`source/registry/execution-grants.json`, `source/registry/capability-flags.json`,
`plugins/orchestration-enforcement/**`, `source/agents/**`.

## 8. Testes

### 8.1 Suite PS nova (`OrchestrationNativeDispatchGrantProjection.tests.ps1`)

- snapshot: role válido/desconhecido; task ausente; registry ausente/inválido;
  runtime/env vazios → efetivo vazio; sensível sem `HumanApproved` → fora;
  sensível com as três listas + aprovação → dentro; task grant fora do baseline
  → fora; `source_revision` determinístico e sensível a mudança de fonte.
- projeção: clear; grant fora do efetivo → denied; grant desconhecido → denied;
  extra na invocação → denied; case/ordem divergentes → denied (ordinal);
  duplicatas; tipos inválidos (número/array/objeto/booleano) → inválido;
  `authority=false` sempre; nunca allow.
- adversarial: contexto com campo desconhecido; `human_approved` number/string;
  arrays com objeto; path traversal no `tasks_dir`/receipt (quando aplicável);
  task de outro goal/task; envelope > 64 KiB; projeção forjada.

### 8.2 Bridge (`native-dispatch-claim` suite S1 atualizada)

- claim feliz com projeção clear;
- claim com grant extra na origem → `grant_projection.ok=true/denied` e o hook
  nega;
- refusal de claim → projeção `ok=false/grant-source-not-evaluated`;
- contexto sem os campos novos → defaults fail-closed (projeção vazia/deny);
- shape/limites do novo campo; pins de autoridade intactos.

### 8.3 Node (`index.tests.js`)

- parse: shape exato, `authority=false`, 32 hex, denied array, limites,
  extra/missing key, tipos, `__proto__`, one-element array;
- handler: clear → `undefined`; denied → deny; `ok=false` → deny;
  projeção ausente/inválida → deny; bridge ausente/timeout → deny; nunca allow;
- regressão S1 completa.

### 8.4 Regressão e CI

- `scripts/v3/run-v3-tests.ps1` (suite nova + S1/S2/S3a + kernel/ND);
- `scripts/ci/typecheck-plugin.ps1` (node tests);
- `scripts/test-package-consistency.ps1` (pwsh; o check 16 já é ambiental no
  PS5.1 deste host);
- `git diff --check`.

## 9. Aceite e riscos

Aceite: suítes verdes em PS 5.1 e PS7; node tests verdes no CI; nenhum
`allow:true`/authority; flags OFF; ND/TaskKernel/registry/TS intocados;
reviewer APPROVED + security APPROVED (fatia toca grants/authority de
observação); CHANGELOG/plano atualizados; PR com merge commit, sem squash.

Riscos/residual:
- S1 segue isolada; hook order/unload e confiança na bridge/contexto/stores
  continuam ownership do operador (SEC1/SEC7).
- A projeção é observação da bridge; um processo que forje a bridge/contexto
  pode mentir sobre o snapshot — o hook valida shape/authority, não autentica
  o produtor (residual declarado, igual à S1).
- `permission.evaluate` canônico segue admission-only; a S5 não o corrige.
- Nenhuma prova runtime-real; S6/enforcement exigem operador.
- S4 é independente (não consome grants nesta fatia); sem sobreposição de
  arquivos.

## 10. Evidência

- Saída das suítes PS5.1/PS7 (contagens, 0 fail) e dos node tests no CI.
- `git diff --stat` e `git diff --check`.
- Revisões reviewer/security e seus achados resolvidos.
- Nenhuma flag/registry/ND/kernel alterados (diff restrito à lista da seção 7).

## 11. Nota de implementação (2026-10-20, sem reescrever o histórico)

- `Get-NDGrantSourceSnapshot` ganhou o parâmetro opcional `-FlagsPath`
  (a entrada da seção 5.1 não o listava): a bridge sempre passa o
  `flags_path` do contexto; vazio/relativo → `grant-source-invalid`,
  ilegível → `grant-source-unavailable`. A "revisão dos flags" é o hash32
  do texto cru do arquivo (`ndgrant1;taskrev=<rev>;flags=<hash>;grants=<..>`).
- Contexto: os 3 campos novos são OPCIONAIS (12 obrigatórios + 3
  opcionais); ausente/null = defaults fail-closed (`[]`/`[]`/`false`),
  o que projeta deny (efetivo vazio) sem impedir o claim.
- A projeção avalia SOMENTE em claim `ok=true/claimed=true` (inclusive
  quando a lib de claim recusou mas o envelope existe); qualquer refusal
  ou erro mantém `grant-source-not-evaluated`.
- Verificado empiricamente no host: arrays JSON ANINHADOS (incl. 1
  elemento e `[]`) são preservados pelo `ConvertFrom-Json` em PS 5.1 e
  PS7; o achatamento a escalar só ocorre no nível raiz e no pipeline
  (coberto pelos holders crus). A rejeição estrita continua valendo para
  escalares (sem coerção).
- Fixtures S1: defaults de contexto cobrem os grants da task com 2
  elementos (`fs.read,git.diff`; interseção mantém o efetivo = task).
