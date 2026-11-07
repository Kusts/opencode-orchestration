# GH-WAKE — sessão raiz recuperada por ID (2026-11-07)

**Issues:** #143 (execução) / #137 (tópico)

**Runtime real:** `opencode v2.2.6` (`source/registry/runtime-versions.json` → `@opencode/cli@2.2.6`).

**Escopo:** V2 apenas. Nenhum merge, deploy, execução de modelo, dispatch real de worker ou exclusão/arquivamento de sessão real.

## 1. Defeito corrigido

`Resolve-GHWakeBoundRootSession` já conhecia o `root_session` exato a partir dos bindings da Task, mas provava a existência da sessão com `Get-NativeSessionList -MaxCount 100`. Essa listagem devolve apenas as 100 sessões top-level mais recentes do projeto atual. Uma sessão raiz fora dessa janela era reportada como `session-not-found`, recusando um GH-WAKE legítimo.

`Get-NativeSessionIdentity`, usada pelos checks pré/pós de `Invoke-OrchestrationNativeResume`, tinha a mesma limitação de listagem.

## 2. Mudança

- `scripts/v3/lib/OrchestrationNativeSessionAdapter.ps1`
  - Novo `Get-NativeSessionById`: consulta direta `opencode api session.get --param sessionID=<id>`, read-only, sem lista, sem cache/índice. Normaliza `{data:{id,title,time.created/updated,location.directory,projectID,time.archived}}` para o mesmo envelope `{ok,error,detail,sessions,count}` do adapter existente.
  - Erros explícitos: `INVALID_ID` (sem spawn), `NOT_FOUND` (exit 1 + `SessionNotFoundError`/`HTTP 404`), `LAUNCH_ERROR`, `TIMEOUT`, `EXIT_n`, `PARSE_ERROR`, `FIELD_ERROR` (id divergente, timestamps não inteiros, `data` ausente).
  - `Get-NativeSessionIdentity` passa a usar o lookup direto, mantendo `Test-NativeSessionBinding` para validar id, `directory` e `projectId`. `MaxCount` permanece na assinatura apenas por compatibilidade de chamada e é ignorado.
  - Sessão arquivada (`time.archived` presente e não nulo) é recusada explicitamente.
- `scripts/v3/github-wake-auto-dispatch.ps1`
  - O resolver troca a lista limitada por `Get-NativeSessionById -SessionId $root` quando não há `$NativeSessionsResult` injetado.
  - `Test-NativeSessionBinding` e todos os controles existentes continuam no caminho: status `attached`, `root_session`, `active_execution_owner`, varredura cross-task, Wait/Task/Goal, geração, lease, checkpoint, diretório e projeto.
  - Sessão arquivada retorna `session-archived` antes de qualquer handoff/executor.
  - `session-archived` incluído em `$knownBlocked` para classificar o bloqueio como `not-dispatched`, nunca `reconcile`/sucesso.
- `scripts/v3/lib/OrchestrationNativeResume.ps1`
  - `session-archived` entra no contrato estável de razões e na lista preservada pelo pré-check; o bloqueio continua sem executar.

## 3. Prova em runtime real

Executada no binário pinado, somente leitura, contra a sessão viva do operador:

| Chamada | Resultado |
|---|---|
| `session list -n 1 --format json` | `ses_e49046b23ffeP1lzxlhEJNDvlg` |
| `Get-NativeSessionById -SessionId <id>` | `ok=True`, mesmo `id`, `directory=D:\projetos\opencode-orchestration`, `projectId=c0a248…e888`, `archived=False` |
| `Get-NativeSessionById -SessionId ses_0000000000000000deadbeef` | `ok=False`, `error=NOT_FOUND` |

Isso comprova o parsing de `{data:{…}}`, timestamps, `location.directory` e `projectID` no runtime 2.2.6, sem depender da listagem recente.

## 4. Testes focados

Todas as suítes abaixo passaram com `powershell` (PS 5.1) e `pwsh` (PS 7):

| Suíte | Resultado |
|---|---|
| `scripts/v3/lib/OrchestrationNativeSessionAdapter.tests.ps1` | 23/23 |
| `scripts/v3/lib/OrchestrationNativeSessionBinding.tests.ps1` | 37/37 |
| `scripts/v3/github-wake-scheduler.tests.ps1` | 119 checks PASS |
| `scripts/v3/github-wake-auto-dispatch.tests.ps1` | 143 checks PASS |
| `scripts/v3/github-wake-auto-dispatch-negatives.tests.ps1` | 119 checks PASS |
| `scripts/v3/github-wake-scheduler-tick.tests.ps1` | 41 checks PASS |
| `scripts/v3/lib/OrchestrationNativeResume.tests.ps1` | 65/65 |
| `scripts/v3/lib/OrchestrationNativeResumeP2.tests.ps1` | 62/62 |

Cobertura relevante:

- **Sessão existente independente da lista:** fixture responde `[]` em `session list` e devolve a sessão em `api session.get`; o lookup por ID encontra a sessão. No scheduler, `Get-NativeSessionList` é substituído por um stub que lança se chamado e a recuperação por ID continua funcionando.
- **Sessão ausente:** `NOT_FOUND` no adapter e `auto-session-not-found` no caminho de scheduler, com zero executor.
- **Sessão arquivada:** `session-archived` no adapter/identity, `auto-session-archived` no scheduler, zero executor, zero marker, contagem de receipts inalterada e SHA-256/bytes do arquivo da Task idênticos antes/depois.
- **Kernel:** nenhuma conclusão de Task, alteração de lease/grant, emissão de receipt, retry ou DONE é produzida nos caminhos de recusa; os testes verificam o estado antes/depois.

## 5. Preservação e limitações

- A associação sessão ↔ Task ↔ Run ↔ Generation continua autoritativa nos bindings CAS do Kernel; `session.get` prova apenas existência/diretório/projeto/arquivamento, nunca autoridade de Task, lease, grant, receipt ou DONE.
- A decisão de recusar sessão arquivada é explícita e conservadora: um resume não deve operar sobre sessão arquivada. O comportamento anterior não era coberto por teste e a listagem podia excluí-la silenciosamente; agora a recusa é observável.
- Nenhum dispatch GH-WAKE real de worker foi executado nesta rodada; a prova live é do adapter/CLI e as suítes usam seams offline, sem modelo nem quota.
- Decisões de plugin, MCP, skills, permissões e watchdog permanecem congeladas e não foram reabertas.
- Esta fatia supersede o item **DEFER** da seção 6 de `evidence/native-session-native-contract-2026-11-07.md` (PR de simplificação); o restante daquele contrato permanece válido.
