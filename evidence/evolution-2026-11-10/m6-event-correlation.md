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

## Intake CLI e prova real (2026-11-10)

`scripts/v3/event-intake.ps1` é a camada fina sobre a lib: valida envelope,
lê rotas, aplica dedup com ledger limitado e, com `-Record`, grava a chave de
entrega. Não cria Task nem dispara worker.

Prova com um comentário **real** do GitHub (read-only):

- issue `#6`, comment `5993719807`, thread `issue:6`;
- rota sintética `task-e2e-event` (estado `IMPLEMENTING`);
- 1ª execução: `ATTACH`, `task_id=task-e2e-event`, `recorded=true`;
- 2ª execução: `IGNORE`, `reason=duplicate-delivery`, sem duplicar.

Testes: `OrchestrationEventIntake.tests.ps1` — 8/8 PASS (ATTACH, dedup,
informativo, OBSERVE, NEW_TASK, fonte inválida, entradas ambíguas).

## Entrega em Task real (event-attach)

`task-kernel.ps1 -Action event-attach` adiciona `Add-OrchestrationTaskEvent`
ao Kernel: valida o envelope, grava em `event_inbox` (bounded 50), deduplica
por `dedup_key` e respeita CAS/estado terminal.

Prova com a Task real `m6-event-proof-20261110`:

- 1ª entrega: revision 2, `duplicate=false`, thread `issue:6`, delivery
  `comment-5993719807`;
- 2ª entrega: `duplicate=true`, revision permanece 2;
- leitura da Task: `event_inbox` com **1** evento.

Isso prova que um evento real do GitHub chega uma única vez à Task correta,
sem duplicar estado. O dispatch/follow-up ao worker ainda é decisão do Planner.

## Limites

- O destino do `ATTACH` na prova real é uma rota sintética; a entrega na Task
  real foi provada com `event-attach`, mas a criação automática da Task e o
  follow-up ao worker ainda não estão ligados ao GH-WAKE.
- Não há wiring com webhook; a intake é chamada explicitamente.
- Admissão proativa (#184) e ownership/handback (#185) continuam pendentes.
- Nenhuma flag, permissão, credencial ou produção foi alterada.
