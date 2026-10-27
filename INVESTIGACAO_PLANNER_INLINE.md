# Relatório de Investigação — Planner executando inline sem subagents

## Causa raiz comprovada

**Bug em `scripts/v3/lib/OrchestrationPreflight.ps1`, função `Get-OrchestrationPreflight`, bloco de classificação trivial (linhas ~437-458).**

Na linha de cálculo de `$sensitiveHit`:

```powershell
$sensitiveHit = Test-OrchestrationKeyword -Blob $blob -Words @('permission', ..., 'delete', 'drop', 'database', 'migration')
```

a variável `$blob` **não estava definida** no escopo da função `Get-OrchestrationPreflight` nesse ponto (ela só é definida dentro de `Get-OrchestrationHardExclusions`, `Test-OrchestrationVague` e `Get-OrchestrationSelectedAgents`, em escopos separados). Em PowerShell (sem StrictMode), `$blob` resolve para `$null`, que é coagido para string vazia dentro de `Test-OrchestrationKeyword`. A função então retorna `$false` para qualquer entrada.

Consequência: `$sensitiveHit` era **sempre `$false`**, de modo que a condição

```powershell
$isMicroEditWrite = (... -and (-not $sensitiveHit) -and ($dom -in @('docs', ...)))
```

nunca era bloqueada por palavras sensíveis. Qualquer micro edição em docs com palavras como `delete`, `drop`, `database`, `migration`, `auth`, `token`, `kernel`, etc. era classificada como `DIRECT_VERIFIED` (trivial, zero workers), mesmo quando o objetivo mencionava operações sensíveis. Isso violava a regra "DIRECT_VERIFIED proibido para alterações de segurança" e contribuía para a percepção de execução inline excessiva.

### Correção aplicada

Definir `$blob` antes do uso, normalizando objetivo + task type + domínio:

```powershell
$blob = Convert-OrchestrationNormalizedText -Text (([string]$obj) + ' ' + ([string]$tt) + ' ' + ([string]$dom))
$sensitiveHit = Test-OrchestrationKeyword -Blob $blob -Words @(...)
```

Agora `$sensitiveHit` reflete corretamente a presença de palavras sensíveis no objetivo, bloqueando a rota `DIRECT_VERIFIED` para micro edits que as mencionem (elevando-as para `MULTI_WORKER` ou `DETERMINISTIC_FALLBACK` conforme hard exclusions).

### Teste de regressão

Adicionado em `scripts/v3/orchestration-preflight.tests.ps1`:

```powershell
$rsens = Get-OrchestrationPreflight -Objective 'delete old note in guide' -TaskType 'cosmetic' -Domain 'docs' -Risk 'low' -ReadWrite 'write' -ExecutionStrategy 'DIRECT_VERIFIED'
Assert-That ($rsens.orchestration_decision -cne 'DIRECT_VERIFIED') 'preflight DIRECT_VERIFIED rejects micro edit with sensitive keyword' 'expected non-direct'
```

Resultado: 64/64 testes passando (era 63/63).

## Hipóteses H1-H4 — status

### H1 — Classificação excessiva como trivial
**Não comprovada no código de preflight.** A lógica de `isTrivial` exige `risk='low'` + `typeOk` (task_type em {trivial, lookup, read, cosmetic, formatting, typo, micro_edit}) + `localizedOk` + `!archHit`. Uma tarefa com `TaskType='implementation'` nunca passa em `typeOk`. O bug encontrado (H1 parcial) era o sensitiveHit sempre false, que agora está corrigido. A classificação excessiva como trivial depende do Planner passar `TaskType='cosmetic'`/`'trivial'` para tarefas de implementação — isso é comportamental do LLM, não controlável pelo preflight.

### H2 — Uso excessivo de DIRECT_VERIFIED
**Não comprovada como bypass de código.** O preflight só retorna `DIRECT_VERIFIED` quando `isTrivial=$true` **E** `ExecutionStrategy='DIRECT_VERIFIED'`. Para tarefas non-trivial, retorna `MULTI_WORKER` mesmo com `ExecutionStrategy='DIRECT_VERIFIED'` (testado: 'implement database migration' → non-direct). O bug do sensitiveHit permitia bypass parcial (corrigido). O Planner pode estar chamando preflight com `ExecutionStrategy='DIRECT_VERIFIED'` para tarefas non-trivial, mas o preflight não honra isso — retorna MULTI_WORKER.

### H3 — Despacho decidido, mas não executado
**Comportamental, não de código.** O `OrchestrationNativeDispatch.ps1` é honesto: "NENHUM script PowerShell pode iniciar um worker nativo. O único executor real é o Planner LLM via ferramenta `subagent`." O código produz `DispatchIntent` + recibos; a chamada real de `subagent` é responsabilidade do LLM Planner. O kernel exige `ActualWorkerParticipation > 0` para `DONE` em tarefas non-trivial. Não há mecanismo de código que force a chamada de subagent — isso depende das instruções do agente e do comportamento do LLM.

### H4 — DONE sem delegação necessária
**Não comprovada como bypass de código.** `Test-OrchestrationDoneCompliance` exige `ActualWorkerParticipation > 0` para `non_trivial` (retorna `ORCHESTRATION_POLICY_BYPASS` se zero). Para `trivial` com `SINGLE_WORKER`, também exige participation > 0. `DIRECT_VERIFIED` só é COMPLIANT para `trivial` com `ExecutionShape='DIRECT_VERIFIED'` e `DirectReason` prefixado por `DIRECT_VERIFIED_*`. O kernel `Test-OrchestrationTaskCompletion` exige `OrchestrationCompliance='COMPLIANT'` + `worker_result.status='candidate_pass'` + verificação. Não há bypass de código identificado.

## Sessões analisadas

Não foram encontradas sessões reais do Planner com telemetria de `orchestration_decision`/`ExecutionStrategy`/`ActualWorkerParticipation` no repositório (o arquivo `evidence/v3/orchestration/preflight-decisions.jsonl` contém registros históricos de desenvolvimento, não execuções do Planner em produção). A investigação focou na análise estática da cadeia de decisão.

## Comparação decisão planejada vs execução observada

| Componente | Decisão planejada (código) | Execução observada |
|---|---|---|
| Preflight | Classifica trivial/non-trivial por risk+type+scope | Bug sensitiveHit sempre false (corrigido) |
| ModelRouter | DIRECT_VERIFIED → T0 zero-cost | OK |
| NativeDispatch | Planner LLM é o executor (subagent) | Comportamental |
| DONE gate | Exige worker participation para non-trivial | OK (fail-closed) |

## Casos em que delegação era obrigatória mas não ocorreu

Não identificados no código. A delegação real depende do Planner LLM chamar `subagent`, o que é governado pelas instruções do agente (`source/adapters/opencode-v2.md`) e pelo comportamento do modelo. O código (kernel) já bloqueia `DONE` sem worker participation para tarefas non-trivial.

## Correção mínima aplicada

1. **Bug fix:** Definição de `$blob` antes de `$sensitiveHit` em `Get-OrchestrationPreflight` (1 linha adicionada).
2. **Teste de regressão:** 1 caso adicionado em `orchestration-preflight.tests.ps1`.

Não foi feita refatoração geral, não foram removidos T0/DIRECT_VERIFIED, não foi reconstruído o Native Dispatch.

## Impacto na autonomia, custo e latência

- **Autonomia:** Preservada. Tarefas triviais (typo, cosmetic em docs sem palavras sensíveis) continuam usando `DIRECT_VERIFIED` com zero workers.
- **Custo:** Levemente aumentado para micro edits em docs que mencionam palavras sensíveis (agora elevados para MULTI_WORKER com coder). Isso é o comportamento correto — essas tarefas não deveriam ser diretas.
- **Latência:** Levemente aumentada para os casos afetados (agora requerem delegação). Casos triviais legítimos inalterados.

## Validação

- `orchestration-preflight.tests.ps1`: 64/64 PASS
- `test-package-consistency.ps1`: 16/16 OK
- Teste manual: micro edit com palavra sensível agora retorna MULTI_WORKER (antes retornava DIRECT_VERIFIED)

## Recomendações adicionais (não aplicadas)

1. **H3/H4 são comportamentais:** Para comprovar que o Planner não está delegando, seria necessário instrumentar as sessões reais (telemetria de chamadas `subagent` e `ActualWorkerParticipation`). O código já tem os guards; a lacuna é observabilidade.
2. **Instruções do agente:** Revisar se `source/adapters/opencode-v2.md` deixa claro que `DIRECT_VERIFIED` é para tarefas *comprovadamente* triviais, e que o Planner deve registrar o `ExecutionStrategy` e `TaskClass` reais (não inferidos).
3. **Preflight CLI:** Considerar adicionar um campo `sensitive_hit` ao output do preflight para facilitar diagnóstico.
