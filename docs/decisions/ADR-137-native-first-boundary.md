# ADR-137 - Fronteira de responsabilidades Native-First

**Status:** Aprovado (consolidação do épico #137, 2026-11-07).
**Escopo:** V2 exclusivamente. V1 = LEGACY_FROZEN.
**Relacionados:** #137, #138, #139, #140, #141, #142, #143, #191, #101.

## Contexto

O épico #137 (native-first) inventariou duplicações comprovadas entre recursos
nativos do OpenCode V2 e componentes locais da orquestração. As auditorias
concluídas (#138–#143, MCP/Skills, NativeDispatch/Task Kernel) já produziram
decisões e evidências. Faltava apenas tornar explícita a fronteira de
responsabilidades para o aceite final.

## Decisão

### OpenCode (runtime host)
- Sessões, ferramentas, execução nativa, PTY, UI, APIs de sessão/listagem/arquivamento.
- Responsável por liveness do serviço, terminal e eventos de estado.
- A orquestração consome via adaptadores finos (native-preferred / tested-fallback).

### Agent Config
- Modelos, agentes e permissões declaradas (owner de configuração global).
- Interop O0–O6 documentada; a orquestração não duplica autoridade declarativa.

### Orquestração (este repositório)
- Planejamento, Task/Goal Kernel, ownership, CAS, leases, receipts, verificação e DONE.
- Invariantes de negócio, evidências, retomada causal e controle de autoridade.
- Preserva diferenciais (Planner, Kernel, ownership) mesmo quando delega execução ao host.

## Regra de remoção

Nenhum wrapper local é removido sem equivalência semântica comprovada em
runtime real e rollback pronto. Routers dormentes e adapters sem caller
produtivo permanecem em DEFER (não removidos por inferência).

## Consequências

- Nenhum segundo Planner, store autoritativo de tarefas ou sistema paralelo de
  permissões é criado.
- Gates de Kernel, CAS/idempotência, isolamento de escrita e evidências
  permanecem preservados.
- Pendências de prova em runtime real (#191) e compatibilidade (#101, #138)
  permanecem como issues independentes, não bloqueando a fronteira definida.