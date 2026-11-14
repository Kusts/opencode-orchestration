# Jornada do skill bench — 2026-11-13

## Contexto

Objetivo desta jornada: fechar a lacuna #64 e produzir evidência relacionada à #11. Este registro documenta somente os fatos observados nesta etapa; não é uma declaração de conclusão do benchmark.

O controle é a jornada G1 sem skill. A comparação não foi randomizada (n=1) e usou modelo e task diferentes; estas métricas não permitem inferir efeito causal da skill.

## Mudança

Carga da skill observada na API (ver Verificação). Sequência observada até aqui: task Kernel `skill-bench-2026-11-13`; seleção T2 Luna; dispatch deste worker para registrar a jornada.

## Verificação

O worker foi instruído a carregar `verification-before-completion`. A chamada à ferramenta `skill` é observável na API local: mensagem `msg_1d7b673430011FSFdEpSTW2m7u`, chamada `call_2b94847fce514d2aa6eff3cc12bb1740`, input `{"id":"verification-before-completion"}`. O registro traz `state.status=completed`, conteúdo da skill e também `executed=false`; portanto, há evidência da invocação registrada, não uma medida de uso ou benefício da skill.

Perfil `skill-journey-fixture`: `verified_pass` via `verify-run`, saída kernel `verification_source=kernel-executed`. Task `skill-bench2-2026-11-13`: revisão 1 criada em `DISCOVERING`, revisão 2 `PLANNING`, revisão 3 `IMPLEMENTING`, revisão 4 start-attempt, revisões 5–6 bindings, revisão 7 `candidate_pass`; `verified_pass` nas revisões 8, 9 (reexecução), 10 e 14. A sessão medida `ses_e28498d25ffeWUzpKxTkuCE0Yo` é a mesma sessão que escreveu este documento; a API registra a chamada patch `call_e52e3be4fec943efa6b58a6cc0cafce9` na mensagem `msg_1d7b6d58a0015R6ll8VdVTjvp` para criar o arquivo. Acceptance criterion única corresponde ao índice 0; o perfil emite `criterion:0:PASS`. Esse resultado prova apenas que o documento está conforme o fixture; não prova que a skill foi usada ou ajudou. Após a task tornar-se terminal, a execução direta do fixture neste documento também emitiu `criterion:0:PASS`; novo `verify-run` foi recusado porque task terminal é imutável.

A primeira task (`skill-bench-2026-11-13`, revisão 8) falhou com `out_of_scope_write`: o commit do perfil de verificação em `source/registry/verification-policy.json` estava fora de `docs/specs`. A task seguinte usou como base a HEAD `da69ff6`, que já continha esse commit; o diff examinado tinha somente o documento e o verifier reportou `1 in scope, 0 out`. O escopo persistido da task nova foi `docs/specs`; o gate não foi afrouxado nem foi necessário incluir o perfil no diff verificado.

Métricas observadas para a sessão `ses_e28498d25ffeWUzpKxTkuCE0Yo`, modelo `openai/gpt-6-luna`, pela API local: input 15765 tokens; output 1486; reasoning 133; cache_read 248320; cache_write 0; busy 37549 ms. A API retornou `cost: 0`; custo é **não observado**, não grátis. Estes são os valores reportados, sem estimativas.

`input`, `cache_read` e `cache_write` têm semânticas próprias na API local; não devem ser somados ou comparados diretamente. `cost: 0` pode refletir ausência de preço configurado no provider.

## Resultado

O documento e a criterion única passaram no verifier do Kernel nas revisões 8, 9, 10 e 14 da task `skill-bench2-2026-11-13`; o reviewer independente aprovou a jornada com 2 observações LOW (registro Kernel na revisão 13), e a task chegou a `DONE` na revisão 15. Este registro NÃO fecha #64 nem conclui #11: é uma observação n=1 de métricas de uma sessão.
