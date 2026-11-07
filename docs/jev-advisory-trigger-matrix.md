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

## Caminho MCP nativo (OpenCode V2) — Planner e subagentes

Camada distinta da matriz acima: aqui o agente chama o servidor MCP `jev`
configurado no `opencode.json` (ferramentas `jev_check`, `jev_classify`,
`jev_decide`, `jev_gate`, `jev_score`). `mcp_routing` continua OFF/HOLD:
a invocacao e explicita e advisory, nao roteamento automatico.

- **Quando usar:** decisao ambigua ou com trade-off material, impasse sem
  progresso, confronto de hipotese, escolha entre alternativas com evidencia
  insuficiente. No maximo uma consulta por decisao.
- **Quando nao usar:** tarefa trivial, resposta ja determinada por evidencia
  local, loop de retry, ou para cumprir ritual.
- **Indisponibilidade:** registrar `UNAVAILABLE`, seguir com a evidencia
  local; sem retry loop, sem gate e sem bloqueio.
- **Autoridade:** identica ao caminho kernel-side. A resposta e dado
  consultivo: nunca concede permissao, nunca altera policy/flag, nunca
  escreve DONE.
- **Propagacao:** comprovada em sessao filha T1 real; o worker chama a
  ferramenta dentro da propria sessao e nao reorquestra.
- **Trigger canonico:** regra curta em
  `agent-config/source/global/AGENTS.md`, distribuida pelo reconciliador
  existente do Agent Config; sem policy, registry, skill, agente ou servico
  novo.

Prova runtime-real: `evidence/v3.1/runtime-reliability/i61-jev-native-integration-2026-11-06.json`
(cenarios A/B/C/D).
