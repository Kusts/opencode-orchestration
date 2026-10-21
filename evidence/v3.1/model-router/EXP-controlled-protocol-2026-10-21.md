# EXP controlado — Protocolo + Oráculo (Beam vs baseline) — issue #99

- **TASK_ID:** EXP-PROTO-99
- **Data:** 2026-10-21
- **Status:** PROTOCOL-ONLY — as 6 delegações NÃO foram executadas neste doc; serão executadas pelo Planner em seguida.
- **Desenho:** Beam vs baseline, 1 workflow × 3 runs por braço, `max_paid_calls=0`.
- **Fonte de verdade deste protocolo:** somente este arquivo. Oráculo congelado no §2.

## 1. Desenho

| Braço | Runs | Modelo | Agente | Escopo |
|---|---|---|---|---|
| BASE (baseline) | BASE-1, BASE-2, BASE-3 | default cheap, SEM override (`opencode-go/muse-spark-1.3-contributor` esperado) | `explorer`, sessão nova, read-only | `scripts/v3/lib` leitura |
| BEAM (candidato) | BEAM-1, BEAM-2, BEAM-3 | `opencode-go/beam-free` (override explícito) | `explorer`, sessão nova, read-only | `scripts/v3/lib` leitura |

- **Restrições:** `max_paid_calls=0`. Nenhum run pode fazer chamada paga extra. Qualquer `cost > 0` no braço BEAM viola "sem paid extra" e barra promoção (§5). Custo do braço BASE é registrado como referência, sem barra.
- **Isolamento:** 1 sessão nova por run (sem `sessionID` reutilizado). Sem estado compartilhado entre runs. Sem escrita, sem commit, sem mutação fora do template de resultados (§4 publica em arquivo separado pelo Planner).
- **Ordem sugerida ao Planner:** intercalar (BASE-1, BEAM-1, BASE-2, BEAM-2, BASE-3, BEAM-3) para diluir deriva temporal; ordem exata deve ser registrada no doc de resultados.

## 2. Oráculo (congelado — computado AGORA via shell, não chutado)

**Comando executado (2026-10-21, neste checkout):**

```powershell
Get-ChildItem -Path scripts/v3/lib -Filter *.ps1 | ForEach-Object { $c=(Get-Content $_.FullName).Count; [pscustomobject]@{Name=$_.Name; Lines=$c} } | Sort-Object Lines -Descending | Select-Object -First 5 | Format-Table -AutoSize | Out-String
```

**Saída (top 5, para amarrar o top 3 contra o 4º colocado):**

```text
Name                                              Lines
----                                              -----
OrchestrationNativeDispatch.ps1                    8510
OrchestrationNativeDispatchHandoff.tests.ps1       4992
OrchestrationTaskKernel.ps1                        4778
OrchestrationRuntimeWatchdog.ps1                   4231
OrchestrationRuntimeWatchdogEnforcement.tests.ps1  3746
```

**Oráculo (resposta correta — ordem decrescente obrigatória):**

1. `OrchestrationNativeDispatch.ps1` — 8510 linhas
2. `OrchestrationNativeDispatchHandoff.tests.ps1` — 4992 linhas
3. `OrchestrationTaskKernel.ps1` — 4778 linhas

- **Método de contagem:** `(Get-Content $_.FullName).Count` por arquivo (todas as linhas, incluindo brancas). Margem do 3º sobre o 4º: 4778 − 4231 = 547 linhas — sem empate nem ambiguidade.
- **Critério de `success exato`:** o run só conta como sucesso se retornar exatamente estes 3 nomes + estes 3 números, nesta ordem. Qualquer divergência (nome trocado, número diferente, ordem diferente, arquivo a mais/a menos) = `failed`, sem julgamento parcial.
- **Congelamento:** se `scripts/v3/lib` mudar antes/durante os runs, o oráculo NÃO muda; divergência vira `failed` + nota `ORACLE-DRIFT-SUSPECT` com `git status` anexado — nunca reescrever o oráculo retroativamente.

## 3. Prompt idêntico (word-for-word para os 6 runs)

O Planner deve enviar EXATAMENTE o texto abaixo como OBJECTIVE de cada uma das 6 delegações, mudando apenas `model` (override só no braço BEAM) e o TASK_ID do run. Nenhuma palavra a mais, a menos no corpo da tarefa:

```text
Liste os 3 maiores arquivos .ps1 sob scripts/v3/lib por número de linhas (nome + linhas). Retorne apenas: nome do arquivo + número de linhas, ordenado do maior para o menor, sem texto extra.
```

**Contrato de delegação (igual nos 6 runs, exceto TASK_ID/model):**

- `TASK_ID`: `EXP-RUN-BASE-1|2|3` ou `EXP-RUN-BEAM-1|2|3`
- `OBJECTIVE`: bloco word-for-word acima
- `READ_SCOPE`: `scripts/v3/lib` (leitura)
- `WRITE_SCOPE`: vazio (read-only; worker não escreve arquivos, não commita)
- `ACCEPTANCE_CRITERIA`: retornar os 3 nomes + 3 números em ordem decrescente
- `RETURN_FORMAT`: `TASK_ID, STATUS, ANSWER (verbatim dos 3 itens), EVIDENCE (comando usado pelo worker)`
- `PROHIBITED_OPERATIONS`: sem escrita, sem commit, sem chamadas pagas, sem carregar outros escopos
- Braço BASE: sem campo `model` (default cheap). Braço BEAM: `model=opencode-go/beam-free`.

## 4. Métricas por run (a medir pelo Planner — template VAZIO, não preencher aqui)

Para cada run registrar: `success exato` (1/0 vs §2), `tokens_input`, `tokens_output`, `cost` (de `session_v2`), `latência wall` (cronometrada pelo Planner ao redor do dispatch), `session_id`, ANSWER verbatim.

| run_id | session_id | model_requested | ANSWER verbatim | success_exato (1/0) | tokens_in | tokens_out | cost | wall_latency_s |
|---|---|---|---|---|---|---|---|---|
| EXP-RUN-BASE-1 | _vazio_ | (default cheap) | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |
| EXP-RUN-BASE-2 | _vazio_ | (default cheap) | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |
| EXP-RUN-BASE-3 | _vazio_ | (default cheap) | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |
| EXP-RUN-BEAM-1 | _vazio_ | opencode-go/beam-free | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |
| EXP-RUN-BEAM-2 | _vazio_ | opencode-go/beam-free | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |
| EXP-RUN-BEAM-3 | _vazio_ | opencode-go/beam-free | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ | _vazio_ |

- `verified-success` por braço = soma de `success_exato` / 3.
- `cost-to-DONE` por braço = soma de `cost` dos 3 runs + wall total (reportado separado, sem somar tempo + dinheiro). Falhas contam com custo incorrido; nenhum run desfavorável é excluído.
- Fontes: contabilidade de `session_v2` (`tokens_input/tokens_output/cost`); latência = cronômetro do Planner (não auto-relato do worker).

## 5. Regras de veredito (PLAN §4 — sem paid extra)

Fonte: `docs/specs/MODEL-ROUTER-vNext-PLAN.md` (promoção F2→F3 somente com ganho medido; ganho estimado de shadow nunca promove) + SPEC §7 / PLAN §4 (primária `cost-to-DONE`, secundárias `verified-success-rate` etc.).

- **Promoção (BEAM sobre BASE) SOMENTE se, cumulativamente:**
  1. `cost-to-DONE` do BEAM < `cost-to-DONE` do BASE;
  2. `verified-success` do BEAM não inferior ao do BASE em ≥ 2/3 (na prática n=3 por braço: BEAM_successes ≥ BASE_successes);
  3. Zero violação de cota/authority/DONE em todos os 6 runs;
  4. **Sem paid extra:** todo run BEAM com `cost == 0`; qualquer `cost > 0` no BEAM = promoção barrada, independente de 1–3.
- **Casos contrário:** `HOLD` (sem promoção, sem regressão alegada) ou `INCONCLUSIVO` com motivo (ex. drift de checkout, falha de infra, paid detectado).
- **Escopo do veredito:** este workflow apenas (listagem determinística read-only); não generaliza para outros papéis/workflows; não autoriza F3 sozinho — promoção exige gate humano explícito (issue #99).

## 6. O que este doc NÃO fez

- Nenhuma das 6 delegações foi executada aqui (só protocolo).
- Nenhum outro arquivo foi tocado; nenhum commit feito. Resultados irão para arquivo separado a ser criado pelo Planner.
