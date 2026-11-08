# Consolidação Native-First — Épico #137 (2026-11-07)

## Decisões comprovadas

| Issue | Componente | Decisão | Evidência |
|---|---|---|---|
| #143 | Sessões | KEEP (adapter fino); 326 linhas e 2 arquivos removidos; consulta GH-WAKE por ID integrada | Comentários #143/#137 |
| #140 | Worktrees | KEEP/DEFER; sem duplicação produtiva | Comentários #140/#137 |
| #139 | PTY/lifecycle | KEEP; prova PTY Windows pendente na #191 | Comentários #139/#137 |
| #141 | Permissões | Ownership consolidado; regra read * allow redundante removida | Comentários #141/#137 |
| MCP/Skills | Discovery nativo | KEEP; routers dormentes em DEFER | Comentários #137 |
| NativeDispatch + Task Kernel | Planejamento/ownership/CAS/leases/receipts/verificação/DONE | KEEP por responsabilidades próprias | ADR-137, docs/ARCHITECTURE.md |
| #142 | todowrite | DEFER; não criar segundo estado de tarefas | Comentários #142/#137 |

## Fronteira de responsabilidades

Ver `docs/decisions/ADR-137-native-first-boundary.md`:
- OpenCode: sessões, ferramentas, execução nativa, PTY, UI, APIs.
- Agent Config: modelos, agentes e permissões declaradas.
- Orquestração: planejamento, Task/Goal Kernel, ownership, CAS, leases, receipts, verificação e DONE.

## Ganhos comprovados

- 326 linhas e 2 arquivos removidos.
- Um caminho redundante eliminado (consulta GH-WAKE limitada a 100 sessões).
- Nenhum novo catálogo de sessões.
- Nenhum novo router ou adapter desnecessário.
- Nenhuma métrica de velocidade/tokens/taxa de DONE inventada (sem medição).

## Pendências restantes

| Issue | Natureza | Bloqueia encerramento do épico? | Responsável |
|---|---|---|---|
| #191 | Prova PTY Windows e capacidades nativas ainda não verificadas | Não (independente) | #191 |
| #101 | Compatibilidade por capability no runtime atual | Não (independente) | #101 |
| #138 | Contratos SDK/eventos efetivamente consumidos | Não (independente) | #138 |
| #142 | Confirmar DEFER sem implementação | Não (já DEFER) | #142 |

## Critérios da #137 atendidos

- [x] Inventário versionado e auditável cobrindo todos os itens.
- [x] Nenhum segundo Planner, store autoritativo de tarefas nem sistema paralelo de permissões.
- [x] Cada remoção de wrapper tem equivalência semântica (comprovada) e rollback.
- [x] Nenhuma feature experimental virou requisito global.
- [x] Gates de Kernel, CAS/idempotência, isolamento de escrita e evidências preservados.
- [x] ADR de fronteira de responsabilidades publicado.
- [x] Plano ordenado por compatibilidade, avaliação nativa, canary e remoção.

## Critérios ainda pendentes

- Prova em runtime real de PTY Windows (#191) — independente, não bloqueia o épico.
- Compatibilidade SDK/eventos (#101, #138) — independente.
- #142 confirmado DEFER sem implementação — já atendido.

## Recomendação fundamentada

Fechar #137 como épico de inventário/decisão arquitetural: a fronteira está definida,
os ganhos comprovados estão registrados, e as pendências restantes são issues
independentes (não bloqueiam o encerramento). Nenhum código produtivo foi alterado
nesta consolidação.

## Próxima ação funcional com maior benefício

Vincular #139 à #191 para provar PTY persistente Windows em runtime real; só então
reavaliar remoção de caminho redundante com rollback. Manter matriz native vs local
atualizada.