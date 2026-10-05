# Diagnostico pos-execucao (RR-E2E-LANE-04-10) — log de execucoes

Lane: `scripts/ci/watchdog-real-lane-v2.ps1` | cenarios RR-E2E-04..10 |
diretorio datado contratado: `2026-10-04` (carimbo real do relogio no campo
`date` de `lane-summary.json`). Disciplina: 1 tentativa por cenario por
execucao; artefatos de `watchdog/` sao saida real da ultima execucao, nunca
editados a mao. Este arquivo e log cronológico das execucoes; a ultima secao
descreve o estado vigente.

## Execucao 1 (2026-10-05 ~00:26, codigo do harness v1)

Veredito: pass-real 05,06,07,08,10 | partial 04 | failed 09 | `lane_status`
incompleta, `no_fake_close` true.

Causa raiz das duas nao-conversoes (defeitos do HARNESS, nao da lib):

- **04 (partial) — leitura de revisao zerada por deadlock de pipe.**
  `Get-KernelRevision` usava `-Action get`, cuja saida passa de 4 KB apos
  `start-attempt`; `Invoke-SpikeChild` so drena stdout depois de
  `WaitForExit` => filho travava no pipe ate o timeout e a revisao vinha
  zerada (`-ExpectedRevision 0` => CAS_CONFLICT no `record-result`).
  Adicionalmente `Invoke-KernelCli` so parseava stdout com `rc=0` e escondia
  o erro de dominio. Corrigido no v2 (`-Action status`; parse sempre).
  Blocker externo honesto: o gate de escopo do verifier allowlisted le a
  arvore inteira e fail-closed (`skipped-out-of-scope`) com a arvore suja de
  outro worker — em arvore limpa (CI) o verifier real roda.
- **09 (failed) — interrupt real consumido antes da injecao.** O cenario
  chamava o avaliador ENFORCE para conferir o deadline ANTES do interrupt
  injetado; sob gate ENFORCE isso ja executa o interrupt real e grava
  resultado terminal sticky. Corrigido no v2: o cenario le o relogio do
  registro da execucao e afirma precondicao
  `no_enforcement_before_injected_interrupt` antes de injetar.

## Execucao 2 (2026-10-05 ~00:41, harness v2 — fixes acima validados)

Veredito: **pass-real 05,06,07,08,09,10** | partial 04 |
`converted_to_real_evidence = [05,06,07,08,09,10]`, `no_fake_close` true.

- 09 agora pass-real com rotulamento explicito da injecao:
  `injection="nao-settlement injetado (seam de teste); interrupt e deadline
  reais"`, precondicao `no_enforcement_before_injected_interrupt` verde,
  settlement `FAILED` honesto.
- 04 partial com causa ambiental (nao defeito): verifier allowlisted
  `skipped-out-of-scope` — a arvore tinha as mudancas da fatia de wiring de
  Job Objects (enforcement) fora do write scope da lane. O caminho do kernel
  funcionou (task real, attempt real, worker real exit 0 na 2a execucao).

## Estado vigente apos review (v3 do harness, sem nova execucao)

O review independente exigiu e obteve correções no harness (`ok` = exit 0 E
sem erro de dominio; `candidate_pass` do 04 condicionado a worker exit 0;
`pass-real` exige todas as assertions obrigatorias; `-EvidenceRoot` efetivo;
sanitizacao de paths/excecoes na evidencia; ambiente minimo nos workers).
Consequencia honesta: **os artefatos da execucao 2 foram produzidos pelo
codigo v2 e nao provam o v3.** A execucao 3 (autorizada, pos-commit, arvore
limpa) revalida os 7 cenarios com o codigo final e deve converter 04 (o
blocker do verifier some em arvore limpa); seus artefatos substituem os
atuais neste diretorio e a secao abaixo sera atualizada.

## Execucao 3 (pos-commit, arvore limpa) — PENDENTE
