# Strategy benchmark #192 — design

## Pergunta e limites

Medir quando Single, Cascade e Critique reduzem custo até DONE e intervenção humana. O harness valida corpus, registra dados fornecidos pelo operador e resume corridas. Não despacha modelos, não usa provider/rede, não cria Task/Goal e não altera o estado autoritativo: Task/Goal Kernel mantém decisões, evidências, verificação e conclusão.

## Estratégias operacionais

- **Single:** um dispatch no tier padrão T2; sem escalonamento automático.
- **Cascade:** inicia em T1 e escala para T2 somente após falha de verificação/review; no máximo um escalonamento. T1 representa tiers baratos T0/T1; T2 é o tier padrão/planner. Os nomes correspondem aos perfis `tier_profiles` e tiers declarados em `source/registry/model-routing-policy.json`, sem fixar um provider/modelo no harness.
- **Critique:** implementador T2 + crítico T2 independente e no máximo uma rodada de correção. O run registra `critic_model` e `critic_session`; sessão do crítico deve ser diferente da sessão do implementador.

Todos os dispatches fazem parte do custo da estratégia. O corpus continua design-only: `pilot_ready=false`; não há fixtures/verificadores implementados. O piloto escolhe duas tarefas de cada categoria principal: small-edit (`sb-01`, `sb-07`), multi-file bug (`sb-02`, `sb-08`) e research (`sb-03`, `sb-09`). Piloto = 6 tarefas × 3 estratégias × 1 repetição = 18 corridas. Benchmark completo = 12 tarefas × 3 estratégias × 3 repetições = 108 corridas. Cada run registra `seed` e `order_index`; ordem randomizada deve ser gerada previamente e registrada. Teto exige valor numérico > 0 aprovado pelo operador; 0, negativo ou UNKNOWN mantém piloto fechado. O gate de parada após três verificações falhas consecutivas OU três runs inválidos consecutivos é protocolo do operador, não é imposto pelo harness; operador monitora contadores consecutivos e reinicia o contador de falhas de verificação após uma verificação não falha, e o contador de runs inválidos após run válido.

O nome da estratégia identifica a condição experimental, não um campo canônico do Kernel. Corridas devem preservar ligação a Task/Goal/evidências quando disponível sem substituir seus registros.

## Corpus

`source/registry/strategy-benchmark-corpus.json` contém 12 tarefas `sb-01..sb-12`, balanceadas entre small-edit, multi-file bug, research, replan, refactor com teste e operação externa mockada. Cada linha define objetivo, critério verificável, profile/comando de verificação, fixture, outcome esperado, risco e tier estimado. Não há mapeamento GW: todo `source_gw=null`, pois GW existente prova invariantes/fluxos distintos e não contém estas tarefas/fixtures equivalentes; números com semelhança superficial não são mapeamentos válidos. Operações externas são exclusivamente mockadas.

## Métricas e interpretação

DONE só conta como sucesso junto de `verification.status=verified_pass` e referência kernel/evidence. Medir custo total (`cost_total`) e custo por DONE verificado (`cost_per_verified_done`), este último UNKNOWN se DONE=0 ou custo não totalmente observado; não há campo `cost_to_done`. `cost=UNKNOWN` nunca vira zero; soma só é observada quando todos os runs incluídos têm custo reportado. Tokens UNKNOWN/ausentes tornam desconhecido o total daquele campo e são acompanhados de `token_known_runs`. Corridas `design_only` são excluídas por padrão; `-IncludeDesignOnly` as inclui explicitamente e o resumo informa `excluded_design_only`. Projeções, se feitas fora do harness, devem ser rotuladas separadamente e nunca misturadas ao observado.

## Protocolo

Usar mesma fixture, seed e prompt por tarefa e isolamento entre corridas. Piloto exploratório: 6 tarefas × 3 estratégias × 1 repetição = 18 corridas. Benchmark completo: 12 tarefas × 3 estratégias × pelo menos 3 repetições = 108 corridas, fora do piloto. O teto monetário deve ser numérico e > 0, aprovado pelo operador; UNKNOWN significa `pilot_ready=false` e bloqueia execuções do piloto. Critérios de parada incluem teto atingido, dados inválidos, fixture contaminada, violação de isolamento, 3 verificações falhas consecutivas ou 3 runs inválidos consecutivos.

Confounders: variância de provider/modelo, aquecimento e cache, contexto residual, ordem, latência externa, diferentes revisões da fixture, julgamento do crítico e intervenções humanas. Registrar metadados suficientes para estratificar, repetir em ordem balanceada e reportar amostra/UNKNOWN; não atribuir causalidade a diferenças pequenas sem repetição.

## Harness

`scripts/v3/strategy-benchmark.ps1` fornece `validate-corpus`, `list-corpus`, `record-run` e `summarize`. Runs são append-only no arquivo explicitamente indicado, com limite de 5.000. `record-run` é estritamente serial: não suporta concorrência nem mutex; apenas um escritor pode usar o RunsFile. `-AllowDesignOnly` permite corridas sintéticas de teste, nunca habilita o piloto. JSON de resumo não inclui timestamp e tem ordenação estável. Custo total e custo por DONE verificado são métricas distintas; custo por DONE é UNKNOWN se DONE=0 ou custo não integralmente observado. Runs self-reported não são contados como verified sem `kernel_ref`/`evidence_ref`. O harness observa/correlaciona dados; não é gate, roteador nem controlador novo.
