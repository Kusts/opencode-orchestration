# Etapa 6D — preflight e roteiro da certificação Live

**Estado:** preparado; a jornada Live e a ativação do Scheduler **não foram executadas**.

## Resultado do P0 de proveniência

O binário pinado `@opencode/cli@2.0.23` foi executado em diretório e HOME/XDG temporários isolados. Foram criadas uma raiz e uma filha com `parentID` explícito; ambas foram consultadas por `session.get`, além de `session.list` (filtro por `parentID`) e `session.message.list`. Nenhum prompt/modelo foi chamado e nenhum Scheduler foi iniciado.

- A raiz voltou como `SessionInfo` direto, sem propriedade `parentID`.
- A filha voltou com `parentID` igual ao ID da raiz.
- `session.list` encontrou a filha sob a raiz; as duas listas de mensagens estavam vazias.
- `checkPlannerWaitRootProvenance`: raiz aceita; filha recusada como `planner-wait-not-root`; objeto incompleto e pai de tipo inválido recusados como `planner-wait-provenance-unavailable`.
- O contrato exato de `@opencode/plugin@2.0.23` é `ctx.session.get({sessionID}) -> SessionInfo` direto; o adaptador agora passa o objeto, não uma string. O helper valida a forma completa do `Session.Info` pinado, incluindo campos próprios e os contadores de `TokenUsage.Info`, e falha fechado em envelopes/aliases ambíguos.
- Evidência sanitizada: [`ETAPA-6D-PROVENANCE-PROBE-2026-11-03.json`](ETAPA-6D-PROVENANCE-PROBE-2026-11-03.json).

## Preflight integrado

| Item | Resultado | Evidência / limite |
|---|---|---|
| Tool `orchestration_planner_wait` opt-in | **PASS no código** | Registro condicionado a `OPENCODE_PLANNER_WAIT_ENABLED=1`, fixtures bridge/shell válidas e sessão raiz. Não está habilitado no estado atual. |
| Binding Phase 32 persistido | **PASS no código/testes** | `Invoke-OrchestrationPlannerWaitBinding` faz CAS `Task/Run/Session`, relê e verifica o binding canônico, depois registra o GitHub Wait. |
| GitHub Wait ligado ao mesmo Task/Run | **PASS no código/testes** | `TaskId` e `RunId` selecionados são gravados no Wait; replay compara identidade, geração, SHA, policy, lease e dedup key. Divergência é recusada. |
| Task `BLOCKED` com wait tipado | **PASS como operação separada; não é feito pela tool** | `orchestration_planner_wait` não chama `Block-OrchestrationTask`. Após o registro, o roteiro executa a transição existente `task-kernel.ps1 -Action block`, com `external_dependency` e fingerprint que deve corresponder ao Wait. Não houve alteração no Kernel. |
| Resolução pelo Scheduler | **PASS no código/testes** | `Resolve-GHWakeBoundRootSession` resolve exclusivamente `Wait.task_id/run_id -> Task.bindings.runs[].root_session` e valida owner, Goal/Task, geração, lease, checkpoint e sessão nativa. IDs de sessão fornecidos pelo chamador são proibidos no modo Scheduler. |
| `auto_dispatch_enabled` | **OFF efetivo** | Não há config atual para o tick de 31/10 e a tarefa `ETAPA6D-LIVE-TEST-F53A9C61` não está registrada. `New-GitHubWakeConfig` e os parâmetros do Scheduler defaultam para `false`; os testes verificam zero executor quando desabilitado. |
| Uma única firing do Scheduler | **PASS no código/testes (DryRun/pure); ativação NOT RUN** | `Register-GitHubWakeSchedule -OneShot` omite o elemento `<Repetition>` completo (suportado pelo schema; exemplo one-shot oficial omite); start boundary, InteractiveToken/LeastPrivilege, time limit e battery pins retidos. Reuso one-shot exige exatamente UM `<TimeTrigger>` com ZERO `<Repetition>` (`Test-GHWScheduleOneShotCompatible`); XML vazio/ilegível, 0 ou >1 triggers, ou qualquer Repetition => `oneshot-mode-conflict` sem `-Force`. Ownership exige caminho PowerShell + argv exatos, sem extras/reordenação. Nome em conflito não-owned sempre recusa (`task-name-conflict`), mesmo com `-Force`; Force só regenera a tarefa owned exata. Interval/Duration explícitos com `-OneShot` são recusados fail-closed (`oneshot-schedule-conflict`). Validado em `github-wake-scheduler.tests.ps1` (S7-S9, `-DryRun`/pure apenas). Nenhuma tarefa foi registrada; a ativação real segue bloqueada até autorização. |
| APIs necessárias do V2 2.0.23 | **PASS sem modelo** | Prova isolada de `session.create/get/list/message.list`; assinatura do plugin tipada contra `@opencode/plugin@2.0.23`. `opencode run --session` e worker real não foram chamados neste preflight. |
| Evidência e recuperação incerta | **PASS no código/testes** | Falhas/timeout/API ausente após claim resultam em `reconcile`; ausência de prova nativa não liquida o dispatch; não há reenvio cego. Replays exigem nova validação nativa. |
| PR #181 / CI de referência | **PASS para o SHA mergeado** | GitHub confirma PR #181 `MERGED`, merge `d88c960000ec69b12b326d8de08f5629d2a11dc7`; CI #41676472991 está SUCCESS, seis jobs verdes, no head `0b482039feeeae32c0687d9d0b0fdecab9409471`. Esse CI antecede a correção local do P0. |
| CI da correção local / jornada Live | **NOT RUN nesta captura** | No momento deste preflight, a correção ainda não estava publicada em um novo SHA; PR #181 já está merged. A jornada também exige um PR/run aberto, autorizado e com approval não-self. |

### Classificação dos gates

- `P0_ROOT_PROVENANCE`: **PASS** (evidência real do pin 2.0.23, sem modelo).
- `AUTO_DISPATCH_OFF`: **PASS** (sem tarefa/config ativa; defaults e testes false).
- `PLANNER_WAIT_PERSISTENCE`, `SCHEDULER_RESOLUTION`, `UNCERTAIN_RESULT_RECOVERY`: **PASS por código/testes**, ainda sem prova integrada Live.
- `GH_WAKE_SCHEDULED`: **gate de código/testes PASS (DryRun); ativação NOT RUN / authorization-gated** — a rota one-shot sem `<Repetition>` existe (`-OneShot`) e está validada DryRun; nenhuma tarefa foi registrada e a ativação segue bloqueada até autorização explícita. Autorização, sozinha, não executa nada.
- `NATIVE_RESUME` nesta jornada e `WORKER_DISPATCH_SETTLED`: **NOT RUN / dependem de autorização e do gate do Scheduler**.
- `ETAPA_6D_READY`: **BLOCKED**. A prova P0 não substitui a mesma jornada com CI/approval, Scheduler, NativeResume e settlement nativo.

Checks locais deste estado: harness Bun `237/237`; plugin enforcement `30/30`; planner-wait binding `120/120`; Scheduler `115`; Scheduler tick `41`; wake `232`; auto-dispatch `143`; auto-dispatch negatives `119`; controller settlement `253`; package consistency `16/16`; typecheck plugin V1/V2/DUAL PASS e bundle regenerado. A sonda nativa 2.0.23 passou para create/get/list/message.list. Esses checks não executaram a jornada Live.

## Plano de uma única execução Live — NÃO EXECUTAR AINDA

### Limites definidos antes da autorização

- **Modelo fixo:** `opencode-go/muse-spark-1.3-contributor` para Planner `build` e um único worker `tester`, via configuração **temporária do projeto**. Sem fallback/rotação; se o modelo não estiver disponível ou a sessão indicar outro modelo, parar.
- **Teto de custo:** **US$ 1,00 total** para toda a jornada. Este repo não impõe hard cap por execução de modelo; antes de autorizar, o operador precisa confirmar um limite efetivo no provider/conta ou em um broker de execução isolado. Sem hard cap verificável, não iniciar.
- **Máximo de requisições de geração do modelo:** **6** no total, somadas entre Planner e o único worker (planejamento: 1 registro inicial + até 2 requisições na única retomada; worker: até 3 para inspecionar e retornar). O limite deve ser aplicado pelo provider/broker; a 7ª requisição é proibida. Sem retries, segundo worker ou segundo NativeResume; se precisar de mais, parar e reconciliar sem reenvio cego.
- **Máximo de efeitos desejado:** 1 Task/Run/Wait, 1 evento CI autorizado, 1 firing do Scheduler, 1 processo NativeResume, 1 worker nativo e 1 tentativa de NativeDispatch settlement. `MaxApiAttempts=1` para o wake. Nenhuma conclusão `DONE`, merge ou deploy. O firing único usa a rota `-OneShot` validada DryRun/pure (S7-S9); o registro/ativação real continua **gated até autorização explícita**.
- **Evidências obrigatórias:** `run-manifest.json` (IDs/SHA/modelo/limites/autorizações); `planner-wait.json`; snapshots Task antes/depois; `wake-out.json`; XML e pré/pós do Scheduled Task; snapshots nativos pré/pós (sessões/mensagens/tool-call/parentID); `native-resume.json`; `worker-proof.json`; `dispatch-settlement.json`; `model-usage.json`; e `reconcile.json` se qualquer resultado ficar incerto. Sanitizar prompts/transcripts, dados pessoais e credenciais; nunca registrar tokens ou senhas.

### Sequência autorizada futura

1. Preparar um diretório de projeto e HOME/XDG descartáveis; instalar/configurar somente ali OpenCode V2 2.0.23 e o plugin pinado. Configurar `build` e `tester` para o modelo fixo acima. Habilitar `OPENCODE_PLANNER_WAIT_ENABLED=1` somente nesse processo e apontar `OPENCODE_PLANNER_WAIT_BRIDGE`/`OPENCODE_PLANNER_WAIT_SHELL` para os fixtures verificados. Não editar config global.
2. Exigir um **PR aberto** com SHA fixo, CI autorizado e todos os checks requeridos verdes, além de approval não-self. Os checks requeridos são `CI (ps51)`, `CI (ps7)`, `CI (smoke opencode real)`, `CI (v2 lane, perfil V2 provisionado)` e `CI (smoke opencode v2 real)`. PR #181 está merged e não serve como novo alvo da jornada. Obter autorização explícita para o evento GitHub/CI e registrar repo, PR, SHA e Run no manifest.
3. Criar Goal, Task, Run, checkpoint e stores descartáveis. Iniciar uma sessão raiz real com o modelo fixo e pedir ao Planner para chamar `orchestration_planner_wait` com o mesmo Task/Run/PR/SHA.
4. Após a tool persistir o binding Phase 32 e o Wait, bloquear a Task pela CLI existente com o wait tipado que corresponde exatamente ao Wait: `WaitType=external_dependency`, `WaitOwner=<Goal owner>`, `WaitAction=revalidate-github-ci`, `WaitDependencyId=github-ci:v1:<repo em minúsculas>:<PR>:<SHA em minúsculas>`. Confirmar `state=BLOCKED` e o fingerprint antes de prosseguir.
5. **One-shot validado DryRun, ativação ainda gated:** o helper agora suporta `-OneShot` (omite `<Repetition>`; Microsoft documenta esse elemento como opcional e o exemplo one-shot oficial o omite), validado em `github-wake-scheduler.tests.ps1` (S7-S9, `-DryRun`/pure apenas). Não registrar tarefa repetitiva como se fosse single-shot e não usar `Interval=24h/Duration=1h` como garantia (recusado fail-closed com `-OneShot`). A ativação real de tarefa continua proibida sem autorização explícita; este preflight não fez nenhuma alteração de Scheduler ativa nem criou tarefa.
6. Com a rota one-shot validada e autorizada, gerar a config `auto_dispatch_enabled=true` somente em diretório temporário. Autorizar/disparar o CI do SHA registrado e exigir todos os checks verdes + approval não-self. Antes do firing, confirmar de novo Task `BLOCKED`, Wait/Run/SHA e Session binding.
7. Ativar exatamente um Scheduler firing **somente após autorização explícita**. O wake faz uma única passagem; se a policy produzir `RESUME`, resolve o root pelo binding canônico, faz um NativeResume (`opencode run --session`) e o Planner real delega uma tarefa read-only ao `tester` com o marcador operacional exato.
8. O AutoDispatch só liquida com prova nativa: filho novo com `parentID` igual ao Planner retomado, chamada `subagent` concluída, marcador/identidades exatos e resultado estruturado (`candidate_pass|failed|blocked` + refs `criterion:<n>`). Então faz uma tentativa de NativeDispatch settlement com o ID do worker. `proceed`, sessão retomada ou resultado injetado isoladamente não são settlement.
9. Capturar as evidências listadas, remover apenas o Scheduled Task criado nesta execução e verificar que não restou tarefa ativa. Se a futura rota aprovada usar `Register-GitHubWakeSchedule`, a remoção é `Unregister-GitHubWakeSchedule -TaskName $UniqueTaskName -Force`. Resultado incerto => `RECONCILE`, manter recibo/claim para recuperação; não repetir NativeResume nem settlement às cegas.

### Comandos preparados (placeholders; não executados)

```powershell
# Stores e config devem apontar somente para o diretório descartável desta execução.
. "$RepoRoot\scripts\v3\github-wake.ps1"
$config = New-GitHubWakeConfig -Path $ConfigPath `
  -WaitsDir $WaitsDir -TasksDir $TasksDir -GoalStoreDir $GoalStoreDir `
  -CheckpointDir $CheckpointDir -FlagsPath $FlagsPath `
  -AutoDispatchEnabled $true `
  -AutoDispatchExpectedDirectory $ExpectedDirectory `
  -AutoDispatchExpectedProjectId $ExpectedProjectId `
  -MaxApiAttempts 1 -TimeoutMs 10000

$block = powershell -NoProfile -File "$RepoRoot\scripts\v3\task-kernel.ps1" `
  -Action block -TaskId $TaskId -Actor planner `
  -Reason "Waiting for authorized GitHub CI" -ExpectedRevision $TaskRevision `
  -WaitType external_dependency -WaitOwner $GoalOwner `
  -WaitAction revalidate-github-ci -WaitDependencyId $DependencyId `
  -TasksDir $TasksDir -FlagsPath $FlagsPath

# O comando de registro one-shot existe mas segue gated (não executar sem
# autorização explícita de ativação; DryRun abaixo é só forma, sem efeito):
# Register-GitHubWakeSchedule -TaskName $UniqueTaskName -WakeScript $WakeCli `
#   -ConfigFile $ConfigPath -OneShot -DryRun
# Sem -DryRun, sem ativação, sem Live: NÃO executar até autorizar.

# On the isolated project, create the Planner session with the model pinned.
opencode run --standalone --model opencode-go/muse-spark-1.3-contributor `
  --agent build --format json "<objective from the approved run manifest>"
```

`task-kernel.ps1 -Action block`, `New-GitHubWakeConfig`, Scheduler registration, Planner `run`, CI triggering, and NativeResume are all **preparations only** in this record. Do not execute them until the user authorizes the target PR/CI, provider hard cap, and single Scheduler activation. This document records the pre-publication preflight snapshot; any later follow-up SHA/CI is separate evidence and does not authorize the Live journey.

## Referência normativa do Scheduler one-shot

Microsoft documenta `<Repetition>` como opcional e o exemplo oficial de TimeTrigger one-shot omite esse elemento: [Time Trigger Example (XML)](https://learn.microsoft.com/en-us/windows/win32/taskschd/time-trigger-example--xml-) e [TriggerBaseType/Repetition](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-repetition-triggerbasetype-element). A opção local `-OneShot` omite a repetição e foi validada via DryRun; o XML ainda não foi importado no Scheduler do host. Ativação real permanece não executada e depende de autorização explícita.
