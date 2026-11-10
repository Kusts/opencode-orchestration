# M6 — Correlação e dedup de eventos (#183/#185, primeira fatia)

**Data:** 2026-11-10
**Runtime de teste:** Windows PowerShell 5.1, sem rede.

## Entregue

`scripts/v3/lib/OrchestrationEventCorrelation.ps1`:

- `New-OrchestrationEventEnvelope` valida fonte (`github`), trigger
  (`issue_comment`, `pull_request_review`, `ci_status`, `push`), thread
  (`pr:`, `issue:` ou `branch:`), delivery id, repo e resumo limitado;
- `dedup_key = sha256(source|repo|delivery_id)`;
- `Resolve-OrchestrationEventRoute`:
  - entrega duplicada → `IGNORE`;
  - evento informativo → `IGNORE`;
  - exatamente um dono não-terminal → `ATTACH` com o Task ID;
  - dois ou mais donos → `ESCALATE` (nunca escolhe em silêncio);
  - dono terminal → não recebe;
  - sem dono e admission desligada → `OBSERVE`;
  - sem dono e admission ligada → `NEW_TASK`.

Testes: `OrchestrationEventCorrelation.tests.ps1` — 11/11 PASS.

## Por que esta fatia

O aceite do M6 exige que um comentário de PR chegue **uma vez** à Task certa e
que comentário informativo não crie Task. A decisão pura acima resolve os dois
pontos sem criar transporte, polling ou segundo Planner. GH-WAKE e o Kernel
continuam donos da execução e do estado.

## Limites

- Não há wiring com GitHub webhooks/GH-WAKE nesta rodada; a lib é a camada de
  decisão.
- Admissão proativa (#184) ainda não tem regras versionadas; o parâmetro
  `AdmissionEnabled` é a costura, desligado por padrão.
- Ownership de conversa e handback (#185) ainda não persistem no Kernel; o
  `ATTACH` é o primeiro passo.
- Agent Teams (#2) dependem de #143 (coberto) e #183 (esta fatia) antes de
  qualquer múltipla sessão.
- Nenhuma flag, permissão, credencial ou produção foi alterada.
