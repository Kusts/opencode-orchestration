# Prova runtime-real Onda 2 — objetivo o2-goal COMPLETED (issue #51)

Data: 2026-10-13/14. Executor: Planner em sessão OpenCode interativa real
via ferramenta nativa `subagent` (V2). Kernel: libs do repo no commit
`09781f3` (pós-PR #74). Ambiente isolado (fora do repo):
`C:\Users\walis\AppData\Local\Temp\opencode\onda2-proof\run-real1-266ab43e04c54d219d9fee522c3ef243\`
(driver + scripts de passo em `...\onda2-proof\`, padrões F3 verbatim).
Nada foi escrito no repo ou no destino ativo durante a prova.

## Resultado

- Goal `o2-goal`: `ACTIVE` → `COMPLETED` via CAS (`Invoke-F3ObjectiveCasComplete`),
  `progress.satisfied=3/total=3`, `completed_tasks=[f3-p1,f3-p2,f3-p3]`, rev 24.
- Cadeia de artefatos (recomputada por tester independente via `Get-FileHash`):
  - `phase1.txt` sha256 `7efc983ad55759097d4bd903a5b6fd1b268a00b6a75e2f5aa3d5146f215147a2`
  - `phase2.txt` sha256 `9cd5c059a1414c1581c8b6a8bc1991d19c98e9b287120a86223b7608b67f658a`, `prev`=sha256(phase1)
  - `phase3.txt` sha256 `f93f39cae7a13c3677f35bdc0ab113259940749f2b8e080d9030a2579eedd0f6c`, `prev`=sha256(phase2)

## Sequência por fase (todas com coder → tester → reviewer reais)

| Fase | Keys (tentativas) | Worker results | Ordem temporal |
|---|---|---|---|
| 1 | `c4c1b37e` (a1) | candidate_pass | settle < verification.passed < review.approved < DONE |
| 2a1 | `8fe0b078` (fault-injection declarado: prev 64 zeros) | tester FAIL → settled-failed honesto | sem DONE |
| 2a2 | `e3251a02` (retry admitido, nova key, sem replay) | candidate_pass | settle < verify < review < DONE |
| 3 | `09d4ef68` | candidate_pass | settle < verify < review < DONE |

- 4 recibos (1 claim + 1 settle por key), mesma linhagem sessão/mensagem/chamada.
- Grep `verified_pass` em goals/tasks/evidence/checkpoints = 0: nenhum worker
  declarou prova ou DONE; DONE somente via `Complete-OrchestrationTask` + CAS.
- Continuação automática entre fases pelo Planner (advance causal + barreira:
  sucessor só anexado após DONE+progresso do predecessor), sem nova instrução humana.

## Provas negativas observadas (recusas reais do kernel)

- `prepare-already-claimed` com claim aberto; `evidence-refs-missing` sem refs;
  `duplicate-task` no re-attach; forma inválida recusada (`evidence-ref-invalid`);
  fencing `terminal-goal` pós-conclusão; resume antigo recusado
  (`stale-goal-revision`); scratch `o2-scratch` CANCELLED com dispatch recusado
  (`goal-terminal`); checkpoints ×2 salvos.
- Observação honesta: attach registrou task fantasma sem checar existência
  (contido pelo gate `task-unreadable` no prepare — sem efeito possível).
- Caminho `settle-result-conflict` (duplicata divergente) coberto em nível
  harness (F3 [N7], 152/152 verde no master em 2026-10-14); não re-produzido
  em runtime-real (janela fecha com o goal terminal, por desenho).
- `f3-p8` = task do drill de cancel (PhaseIndex 8, goal `o2-scratch`), fora do
  `o2-goal`, sem contaminação.

## Vereditos independentes

- Tester final: PASS (hashes, estados, ordenação settle<verify<review<DONE).
- Reviewers por fase: APPROVED (1ª rodada p1 com 1 MEDIUM válido sobre critério
  mal formulado → evidência complementada → APPROVED).
- Fixture F3 baseline no master: 152/152 PASS (~34s).

## Limites

- Provenance das chamadas é `declared` (ids `ses_o2_*`), não prova de autoria —
  conforme doutrina do repo (dado, não autoridade).
- Pernas model-dependent da lane (18/20/21/22) seguem operator-owned; fora desta prova.
