# Jev trigger x advisor/debugger — matriz de cobertura (P1-02 slice 2)

Origem dos 6 motivos Jev: `Test-JevAdvisoryTrigger`
(`scripts/v3/lib/OrchestrationJevAdvisory.ps1`). `trivial_local` nunca
consulta; sem flag setada, `no-trigger` (sem consulta). Jev e sempre
advisory-only: nao concede, nao amplia escopo, nao escolhe modelo, nao
escreve DONE (`Invoke-JevAdvisoryGrantGate` sempre nega).

Colunas advisor: `engineering-advisor` (viabilidade) e seu modo
deadlock-consult (#60 F2, plano travado), `debugger` (causa raiz apos
falha). Planner decide; workers nao reorquestram.

| # | Trigger Jev | Advisor correspondente | Cobertura | Nota |
|---|-------------|------------------------|-----------|------|
| 1 | `route-uncertain` | engineering-advisor (viabilidade) | coberto | Rota incerta: advisor confronta proposta x repo antes de delegar. |
| 2 | `model-route-uncertain` | engineering-advisor (viabilidade) | coberto | Escolha de modelo/capacidade incerta: mesma via, sem Jev obrigatorio. |
| 3 | `consequential-tool-call` | engineering-advisor (viabilidade) | coberto | Acao consequente: advisor avalia reversibilidade/custo; Jev opcional. |
| 4 | `conflicting-evidence` | engineering-advisor ou debugger | coberto | Evidencias contraditorias: advisor (proposta) ou debugger (falha observada). |
| 5 | `completion-uncertainty-substantial` | engineering-advisor deadlock-consult | coberto | Incerteza de conclusao: modo deadlock (proxima acao pequena e verificavel). |
| 6 | `recovery-comparison-bounded` | engineering-advisor deadlock-consult | coberto | Comparar recuperacoes: modo deadlock com alternativas e trade-offs. |

## Lacunas declaradas (honestas, sem wiring novo)

- L1 — falha repetida (2a falha sem evidencia nova) vai para `debugger`,
  nao para Jev: Jev pode ser auxiliar opcional, nunca autoridade e nunca
  substitui o debugger. Nao ha trigger Jev dedicado a "falha repetida";
  `conflicting-evidence` cobre apenas parcialmente.
- L2 — deadlock vai para o `engineering-advisor` **sem Jev obrigatorio**:
  o modo deadlock-consult funciona offline e deterministico; Jev e
  ferramenta auxiliar opcional (se disponivel e autorizado), nunca
  requisito. Nenhum trigger Jev e pre-requisito do advisor.
- L3 — `trivial_local` / `no-trigger` nunca consultam: por desenho, sem
  cobertura Jev nem advisor (tarefa trivial/local nao justifica custo).

Evidencia: contagens por event x trigger_reason x mode via
`scripts/v3/jev-advisory-summary.ps1` sobre `cache/v3/jev-advisory/*.jsonl`.
