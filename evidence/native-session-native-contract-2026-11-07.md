# Sessões native-first — contrato nativo e primeira redução (2026-11-07)

**Issues:** #143 (execução) / #137 (épico)

**Runtime real:** `opencode v2.2.6` (`source/registry/runtime-versions.json` → `@opencode/cli@2.2.6`). O texto da issue cita 2.2.5; o binário instalado e pinado é 2.2.6.

**Escopo:** V2 apenas. V1 congelada. Nenhum merge, deploy ou exclusão irreversível.

## 1. Componentes e callers encontrados

| Componente | Caller produtivo | Dados armazenados | Classificação |
|---|---|---|---|
| `scripts/v3/lib/OrchestrationNativeSessionAdapter.ps1` | `OrchestrationNativeResume.ps1` (`Get-NativeSessionIdentity`), `github-wake-auto-dispatch.ps1` (`Test-NativeSessionBinding`/`Get-NativeSessionList`), prova `full-delivery-etapa6d-resume-proof.ps1` | id, título, timestamps, directory, projectId | wrapper fino de leitura nativa com validação; não é store |
| `scripts/v3/lib/OrchestrationSessionReconciler.ps1` | `OrchestrationDurableResume.ps1`, `session-real-lane-v2.ps1`, testes | Continuation Envelope + observações declaradas (bounded) | estado próprio de retomada; não é catálogo de sessões |
| Bindings de sessão do Task Kernel (`Get-OrchestrationTaskBindings`, `Invoke-OrchestrationTaskSessionBinding`) | `task-kernel.ps1`, `planner-session-binding.ps1`, `OrchestrationPlannerWait.ps1`, `github-wake-auto-dispatch.ps1` | `run_id`, `root_session`, `worker_sessions`, `seat_id`, status, provenance, revision/CAS | registro autoritativo de Run/Seat/ownership |
| `scripts/runtime/SessionBootstrapContext.ps1` + `scripts/v3/lib/OrchestrationBootstrapContext.ps1` | wiring de arranque (registro operator-owned) | contexto computado read-only | não é store de sessões |
| `scripts/v3/lib/OrchestrationSessionShadowComparator.ps1` + testes | **nenhum caller produtivo** (somente o próprio teste) | relatório de comparação catálogo local × lista nativa | caminho redundante/morto |
| `sessionIndex` do plugin (`plugins/orchestration-enforcement/shared/identity.ts`, `v1.ts`, `v2.ts`) | hook de contexto / mandate | cache em memória `{parentID, agent}`, cap 5000 | cache de resolução de papel |
| `session_id` em waits/markers/receipts do GH-WAKE | controller e auto-dispatch | vínculo de dispatch, dedupe e idempotência | estado de negócio |

Não existe catálogo local de sessões do OpenCode. `cache/runtime/tasks` é registro de Task/Goal com bindings CAS (Run/Seat/Session), não um espelho do host. O único binding local com `session_id` na investigação anterior era sintético.

## 2. Capabilities nativas comprovadas

Comandos executados no binário real, somente leitura (exceto o probe descartável da seção 3):

| Capacidade | Comando/rota | Resultado observado |
|---|---|---|
| Listagem | `opencode session list -n 2 --format json` | array de sessões top-level do projeto atual, mais recentes primeiro; campos `id`, `title`, `created`, `updated`, `projectId`, `directory` |
| Listagem API | `opencode api session.list --param limit=2` | objeto `{data, cursor}`; `cursor.previous/next` |
| Paginação | `--param cursor=<next>` | página 2 sem repetir IDs da página 1 |
| Filtro parent/child | `--param parentID=<id>` / `--param parentID=null` | filha exata / somente raízes |
| Busca | `--param search=<tag>` | filtra por título/metadados |
| Arquivadas | `--param archived=true|false` | arquivadas só em `true`; ativas em `false` |
| Busca por ID | `opencode api session.get --param sessionID=<id>` | `id`, `parentID`, `projectID`, `location.directory`, `time.created/updated/archived`, agente/modelo/tokens/custo/outcome |
| Exportação | `opencode session export <id>` | `info.parentID`, `info.location.directory`, modelo/tokens/custo/outcome e `messages`; `--sanitize` disponível |
| Arquivar/restaurar | `PATCH /api/session/{id}` com `{"archived":true|false}` | 204; no-op ao repetir; `time.archived` aparece/desaparece |
| Excluir | `DELETE /api/session/{id}` (`operationId: session.remove`) | 204; exclui a filha em cascata (ambas passam a 404) |
| Persistência | nova invocação CLI/API por comando | a mesma sessão é relida por processos clientes independentes |

Observações de contrato:

- `opencode session list` é **do projeto atual e apenas top-level**. A filha não aparece. A API `session.list` é global e exige filtro explícito (`parentID`, `directory` ou `project`).
- Não há subcomando CLI `archive`/`restore`; arquivamento é API-only (`PATCH`). `session delete` é cascata; arquivar a raiz **não** arquiva a filha.
- Sessão arquivada continua acessível por ID (`session.get`) e por `session.list --param archived=true`.
- Reinício completo do serviço não foi executado nesta rodada (derrubaria a sessão viva do operador). A persistência foi provada entre processos clientes independentes; a evidência de restart real permanece em RR-E2E-18/19.
- `ctx.session.list` (plugin) não foi re-sondado: decisões de plugin estão congeladas nesta issue e `client.session.get` já está ligado ao planner-wait.

Referências upstream:

- CLI/commands: <https://opencode.ai/v2/docs/cli/commands/>
- API/OpenAPI (170 operações): <https://opencode.ai/v2/docs/api> e <https://opencode.ai/docs/openapi.json>
- Eventos `session.archived` / `session.unarchived` e `Session.Info`: OpenAPI do runtime pinado.

## 3. Arquivamento isolado (projeto descartável)

Probe executado em `%TEMP%\native-session-archive-<guid>` com sessões criadas pela API e removidas ao final. Nenhuma sessão real do usuário foi arquivada, restaurada ou excluída. Evidência bruta: `evidence/native-session-archive-probe-2026-11-07.json`.

| Passo | Resultado |
|---|---|
| Criar raiz no diretório descartável | `location.directory` = diretório do probe; `projectID` novo |
| Criar filha com `parentID` | `parentID` da raiz preservado |
| `session.get` da raiz em processo novo | mesmo `directory`/`projectID` |
| `session.list --param parentID=<raiz>` | 1 filha |
| `session.list --param parentID=null --param search=<tag>` | apenas a raiz |
| Arquivar filha | `time.archived` presente; filha sai de `archived=false` e entra em `archived=true`; `session.get` continua retornando `parentID` |
| Restaurar filha | `time.archived` some; filha volta a `archived=false` |
| Arquivar raiz | filha **não** é arquivada (sem cascata) |
| `session list` na CLI, cwd = probe | apenas a raiz (top-level, projeto atual) |
| Excluir raiz | raiz e filha passam a 404 (`SessionNotFoundError`) |

Snapshot do estado do Kernel antes/depois (SHA-256 do conteúdo de cada árvore):

| Árvore | Antes | Depois |
|---|---|---|
| `cache/runtime/tasks` | `687798256ef122ad33f0a5613ddbf9d023e97ac85785869929476233ae6cca77` | idêntico |
| `cache/runtime/receipts` | `1c587dde4e47eb12bf921fd88d5cd5d7bb48b7eaf55239f82305ef6a2223fba0` | idêntico |
| `cache/runtime/evidence` | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | idêntico |

Conclusão do probe: arquivar/restaurar não concluiu Task, não liberou lease, não alterou grants, não produziu receipts, não disparou retry/execução e não alterou decisão DONE. Nenhuma Task estava vinculada à sessão de probe; a prova forte é a ausência de qualquer mutação nas três árvores de estado do Kernel, combinada com a semântica nativa observada (update de metadado da sessão).

## 4. Primeira redução de código

**Removido:** `scripts/v3/lib/OrchestrationSessionShadowComparator.ps1` e `scripts/v3/lib/OrchestrationSessionShadowComparator.tests.ps1` — 326 linhas, 2 arquivos, 1 caminho redundante.

- Teste do comportamento atual antes da remoção: 16/16 PASS.
- Nenhum caller produtivo: `git grep` fora dos próprios arquivos retornou zero referências; nenhum workflow/CI o referencia.
- Motivo: o comparador pressupõe um catálogo local de sessões que não existe (refutado pela evidência de 2026-10-28). Sem caller, era um segundo caminho de comparação mantido apenas pelo teste. O que ele tentava medir já é coberto por `session.list`/`session.get` (nativo) e pelos bindings CAS do Kernel.
- O que **não** foi removido: adapter nativo (tem callers), reconciler, bindings do Kernel, bootstrap, cache de papel do plugin e estado durável do GH-WAKE.

## 5. Testes reais e resultado

- Comparador removido: `OrchestrationSessionShadowComparator.tests.ps1` 16/16 PASS antes da remoção.
- Probe nativo: `ok=true`, `kernel_state.unchanged=true` (arquivo bruto citado acima).
- Suítes focadas após a remoção: ver corpo do handoff/issue; `git diff --check` limpo.

## 6. Limitações e próxima ação

- Runtime 2.2.6 (não 2.2.5, citado na issue). Nenhuma conclusão foi inferida de docs; os comandos foram executados no binário pinado.
- Reinício completo do serviço e `ctx.session.list` do plugin não foram re-sondados nesta fatia.
- O scheduler do GH-WAKE ainda usa `Get-NativeSessionList -MaxCount 100` para validar a raiz; essa lista é top-level e limitada às 100 mais recentes. Trocar por `session.get` por ID elimina a limitação, mas exige seam de API no resolver e revalidação das suítes — **DEFER** (fora da menor redução segura desta rodada).
- Próxima ação recomendada: manter #143 aberta apenas para a fatia plugin-side (`ctx.session.list`), se/quando as decisões de plugin forem reabertas; caso contrário, encerrar a parte de “catálogo local de sessões” como no-op comprovado.
