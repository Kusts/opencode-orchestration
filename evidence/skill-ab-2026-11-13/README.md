# A/B: `verification-before-completion`

## Desenho

Uma mesma tarefa de correção foi executada sequencialmente nos arms A e B,
com o mesmo modelo observado (`openai/gpt-6-luna`, T2), no mesmo runtime
OpenCode V2. O arm A recebeu a instrução de carregar
`verification-before-completion`; o arm B não recebeu essa instrução, mas
invocou `ai-memory-retrieval` e `systematic-debugging`. Portanto, o contraste
é **com vs. sem `verification-before-completion`**, não com vs. sem skills.

As tasks `skillab-a-20261113` e `skillab-b-20261113` usaram o mesmo perfil de
verificação `skill-ab-fixture`, critérios, risco, runtime, versão e write
scope. O kernel registrou `verified_pass` em ambas e as duas chegaram a
`DONE` (revision 12).

## Fixture

Os arquivos em `scratchpad/skillab/` são ignorados pelo Git e não fazem parte
desta publicação:

- `lib/calc.ps1`
- `tests/calc.tests.ps1`
- `run-tests.ps1`
- `lib/calc.buggy.ps1` (cópia do original defeituoso)

O bug original reduzia em um o limite de iteração para arrays de tamanho
ímpar, ignorando o último item. Os quatro casos de teste cobrem array vazio,
um item, dois itens e três itens. Recrie `calc.ps1` com `Get-Total` somando os
itens do índice `0` até `Items.Count - 1`; o baseline deve falhar e a
correção deve passar `powershell -NoProfile -File
scratchpad/skillab/run-tests.ps1`, imprimindo `criterion:0:PASS` ao passar.
O perfil foi registrado no `source/registry/verification-policy.json` do
worktree de experimento; esse arquivo deliberadamente não está neste pacote
de evidências.

## Resultados observados

| Métrica | Arm A | Arm B |
| --- | ---: | ---: |
| Mensagens de assistant agregadas | 7 | 11 |
| Modelo / tier | Luna / T2 | Luna / T2 |
| Input tokens | 3.815 | 19.741 |
| Output tokens | 498 | 784 |
| Reasoning tokens | 21 | 194 |
| Cache read tokens | 231.680 | 448.256 |
| Cache write tokens | 0 | 0 |
| Custo observado | não | não |
| Busy observado | não | não |
| `verification-before-completion` carregada | sim | não |
| Verificação kernel | `verified_pass` | `verified_pass` |
| Task | `DONE`, revision 12 | `DONE`, revision 12 |

Os registros de sessão, patches e métricas agregadas estão nos arquivos
`arm-a/`, `arm-b/` e `comparison.json`.

## Limitações e interpretação

- Apenas uma execução por arm (`n=1`); não há réplicas nem estimativa de
  variância.
- Ordem A→B não randomizada; pode haver aprendizado ou efeitos de cache entre
  execuções.
- B usou outras duas skills (`ai-memory-retrieval` e
  `systematic-debugging`).
- Mesma máquina para os dois arms.
- Custo e busy não foram observados nos registros consultados; não devem ser
  interpretados como zero.
- B teve aproximadamente 5,2× os input tokens e 1,9× os cache-read tokens
  de A. A diferença é observacional, sem inferência causal.

Este experimento não demonstra que carregar a skill causou diferença em
qualidade, velocidade, tokens ou custo, nem generaliza para outras tarefas,
modelos ou execuções.
