# Planner Native Handoff & Autonomous Continuation — PLAN

**Projeto:** opencode-orchestration  
**Base:** v0.1.2, HEAD inicial `b38c92bc8b3ab334a9dffad609f3515350336061`  
**SPEC:** [`PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md`](PLANNER-NATIVE-HANDOFF-v0.1.2-SPEC.md)  
**Status:** G0 concluído; execução produtiva BLOQUEADA em G1 por fronteira de confiança não provada  
**Revisão:** 2026-10-09; atualização 2026-10-11 (PR-A: SETTLE candidato de biblioteca + FIX6C)

## 1. Estratégia e decisão

Manter o Planner como único invocador da tool nativa; reutilizar GoalKernel,
TaskKernel, ObjectiveController, NativeDispatch, ProductiveActivation,
EvidenceStore, Checkpoint e SessionReconciler. Não adicionar daemon, API privada,
spawn em PowerShell/plugin, sistema concorrente de receipts, nem retirar HOLDs.

O contrato lógico será `PREPARE → NATIVE TOOL → SETTLE → VERIFY → ADVANCE`,
mas somente poderá ser implementado como caminho autorizado quando houver
controle confiável pré-efeito e provenance de execução do host. Instrução de
prompt + callback do modelo não é enforcement. A ausência dessa prova interrompe
G1; não se converte em autorização por protocolo cooperativo.

### Fatos que orientam o plano

- `Invoke-OrchestrationAutonomousObjective` não tem caller produtivo; sem
  Executor o loop termina em `awaits-planner`.
- Executor atual de NativeDispatch é síncrono e executado depois da admissão;
  não pode suspender a stack para o Planner invocar `subagent`/`task`.
- Executar a tool primeiro e liquidar depois viola PREPARE pré-efeito.
- Plugin atual observa/falha aberto; `runtime_grant_enforcement` V1/V2 OFF.
- Security review: não existe correlação independente provada entre intent e
  child/tool result nos eventos conhecidos; texto do modelo é claim.
- Architect review recomenda protocolo explícito Planner-driven, mas mantém
  Executor como seam de teste, nunca como evidência de native dispatch.

## 2. Fase 0 — Baseline, diagnóstico e proposta (CONCLUÍDA)

### Evidência

- Checkout: branch `acceptance/autonomous-core-v0.1.2-2026-10-09`, HEAD
  `b38c92bc8b3ab334a9dffad609f3515350336061`, tag `v0.1.2`, alinhado a
  `origin/master`; sem commits locais. Working tree já continha mudanças em
  wiring matrix, closure addendum, adapters V1/V2 e audit novo; todas
  preservadas.
- Runtime do PATH: V2 `2.0.26`; perfil V2 package/binário `2.0.23` presente;
  perfil V1 `1.18.34` ausente. PS5.1 `5.1.26100.9444`, PS7 `7.6.6`.
- Probe runtime-real isolado do hook V2 `2.0.23`: chamada permitida gerou
  before/after com IDs correlacionados e child ID; hook `execute.before` que
  lançou erro bloqueou a chamada e não gerou after/child. Binário e eventos
  sanitizados: `evidence/v3.1/runtime-reliability/native-handoff-hook-probe-2026-10-09*`.
- O probe usou uma sessão pai/child real e provider OpenAI já configurado, sem
  alterar config/credenciais; tarefa do child foi read-only e retornou literal.
  O modelo/provider opencode-go configurado no host retornou `provider.no-route`
  quando testado no pin 2.0.23; a validação passou com `openai/gpt-6-luna`.
- Auditoria anterior: CI run `37893387670` attempt 2 = 5/5 success; attempt 1
  teve 5 falhas FIX4-2b no job PS7. Causa não confirmada; rerun não conta como
  correção. Issues #8/#9/#10/#19/#21 consultadas; nenhuma alteração externa.
- G0 root cause e matriz constam no audit e na Wiring Matrix/Closure Addendum.

### Parecer independente

- Architect: callback PowerShell não representa chamada nativa suspensa; a
  ordem pós-execução seria insegura. Recomenda separar operações somente após
  contrato e prova do runtime.
- Security Reviewer: `dispatch_intent` não é autorização consumível; sem
  gate host confiável antes do efeito, execução permanece bloqueada. Exige
  fencing/reconciliação fail-closed e não replay em estado ambíguo.
- Researcher: documentação oficial confirma apenas que V2 `subagent` e V1
  `task` são tools model-callable; docs vivas não provam pins. Runtime exato
  V2 tem probe de `parentID` ambíguo e deny `/shell` fail-open; V1 não instalado.

### Gate G0

**PASS — diagnóstico**, não aprovação de implementação: root cause confirmada e
proposta mínima registrada. A capacidade de veto/correlação nativa foi
comprovada no probe V2 pinado, mas **G1 produtivo continua BLOQUEADO** até o
contrato PREPARE/kernel ser conectado e adversarialmente validado.

### Subfatia PR-A — contrato NativeDispatch (IMPLEMENTADA, primitive-only: PREPARE/CLAIM/SETTLE candidatos, sem wiring)

- Adicionadas `Invoke-OrchestrationNativeDispatchPrepare` e
  `Invoke-OrchestrationNativeDispatchClaim` em
  `scripts/v3/lib/OrchestrationNativeDispatch.ps1`. Reusam o mesmo receipt
  store/locks, sem `Executor` e sem store paralelo.
- PREPARE persiste `prepared`; CLAIM consome por transição única para
  `claimed`/`DISPATCH_UNCERTAIN`, com intent fingerprint, host call identity,
  fencing após lock, scan/exclusão por Task em todos os Goals/revisões/keys,
  validação estrita de forma/tipos e receipt semântico.
- Exceção/resultado inválido após possível efeito deixa receipt `pending`; replay
  não liquida nem libera reserva. `settled` duplicado sem prova continua
  recusado. Legacy `Invoke` mantém seu contrato, agora compartilha a reserva.
- Reviews independentes Reviewer/Security: **APPROVED** para a primitiva
  sintética; não é aprovação de wiring. Tester: 6 suítes, **1175/1175** em
  PS5.1 e **1175/1175** em PS7; NativeDispatch PS5.1 **10/10** repetido;
  package consistency 16/16; `git diff --check` limpo.
- Cobertura é sintética. Nenhuma chamada nativa, settlement ou worker foi
  executado por essa biblioteca. O hook probe V2 é evidência separada.

#### Atualização 2026-10-11 — SETTLE candidato e FIX6C

- A biblioteca expõe agora **PREPARE, CLAIM e SETTLE** como APIs candidatas
  em `scripts/v3/lib/OrchestrationNativeDispatch.ps1`. **SETTLE de
  biblioteca não é settlement produtivo canônico do TaskKernel**: nenhum
  plugin, CLI ou TaskKernel consome essas funções, nenhum worker-result é
  liquidado no kernel e nenhuma proveniência causal de kernel é produzida.
  A distinção é contratual e não pode ser colapsada em documento ou review.
- A varredura cross-task de recibos passou a validar a integridade semântica
  do handoff marcado **antes** da atribuição de task, com gate estrito de
  `settled` provado. Regressões novas cobrem recibos adulterados do mesmo
  tipo, com `task_id` trocado por outro id válido (hashes intactos), em caixa
  alterada (casing) e híbridos, e recibos **marker-only** (nome exclusivo do
  handoff como único marcador sobrevivente); em todos os casos a recusa é
  fechada antes de qualquer atribuição. Recibos legados de verdade usam um
  gate de compatibilidade separado e seguem liberando reserva; handoff
  `settled` provado e válido segue liquidando.
- Reviews do FIX6C: Security Reviewer **APPROVED**, com escopo em
  classificação/reserva; Reviewer aprovou o escopo estático do FIX6C; o proof
  shape já tinha aprovação de review em rodada anterior. **Nenhuma dessas
  aprovações implica wiring produtivo nem proveniência causal de kernel.**
- Testes sintéticos pós-FIX6C: suíte Handoff **1745/1745 em PS5.1 e em PS7**;
  após edições de performance no harness de teste, o runner oficial PS5.1
  passou em **301258 ms** (cap de 420 s específico da suíte) e o PS7 direto
  em **138377 ms**; NativeDispatch **180**, Receipts **187** e Envelopes
  **39** passam nas duas engines; package consistency **16/16**;
  `git diff --check` limpo. Antes dessas edições o Tester observou um timeout
  em 420 s e um passe em 267423 ms — variância residual, **sem** claim de
  tempo estável; a nova falha `Wait-Job` é fail-loud. Tester reverificou de
  forma independente o estado pós-performance e Reviewer **APPROVED** as
  edições de performance. Evidência é sintética, não execução em runtime
  real.
- Fronteira de evidência: recibos com descritores de host persistidos e
  internamente consistentes **não provam** que o TaskKernel liquidou de fato
  o worker-result; fonte confiável de grants, ciclo de vida do plugin e ponte
  causal seguem não resolvidos. Portanto não há claim de SETTLE produtivo,
  G1, runtime enforcement ou FINAL CLOSURE; `runtime_grant_enforcement`
  segue OFF/HOLD; nenhuma alteração de flag/configuração, instalação,
  provider ou credencial.

## 3. Fase 1 — PREPARE/CLAIM integrado ao hook (PENDENTE)

1. Expor um bridge CLI fechado para chamar PREPARE/CLAIM sem strings de shell
   interpoladas; autenticação/Authorization vem de fonte canônica confiável,
   nunca de campos enviados pelo modelo.
2. No plugin V2, a tool hook antes do efeito chama CLAIM com IDs/argumentos
   host-originated e recusa ausência/divergência/falha. `permission.evaluate`
   usa uma projeção derivada do TaskKernel para negar `read`/`edit` fora do
   escopo, deny-only; ações não provadas (shell, MCP, Code Mode, etc.) são
   negadas ou ficam fora da lane controlada.
3. Capturar `execute.after` e associar child ao parent via IDs do host e
   `ctx.session.get(child).parentID`; não usar o texto do worker para inferir
   lineage. Resultado ausente mantém CLAIM incerto, sem retry automático.
4. Definir a localização/confiabilidade do script bridge na instalação. Hoje o
   instalador distribui o bundle, mas não as `scripts/v3` necessárias; não
   inferir caminho pelo CWD nem recorrer a script do projeto não verificado.
5. Integrar somente ao bundle de teste isolado até existirem testes de plugin
   ausente/unload, ordenação/mutação de hooks, correlação e fonte de autorização.
   Não alterar config global nem ativar `runtime_grant_enforcement`.

**G1 — parcialmente provado:** contrato NativeDispatch passou suítes sintéticas;
probes exatos V2 provaram veto do spawn e gate de read/edit no fixture. G1
completo exige que o plugin/bridge distribuído consuma PREPARE/CLAIM, use grants
de fonte confiável, bloqueie quando plugin/bridge estiver indisponível, associe
child antes da primeira operação protegida e persista SETTLE no kernel. Isso
ainda não foi executado. Manter V1 e ações de worker não cobertas em HOLD.

## 4. Fase 2 — SETTLE e EvidenceRef (condicionada a G1)

- Definir um único owner para escrever worker-result entre NativeDispatch e
  ProductiveActivation.
- Persistir intent, provenance host, refs e resultado candidato; revalidar
  ownership/generation/revision no settlement.
- Tornar partial writes recuperáveis; receipt `pending/uncertain` nunca sofre
  retry implícito; duplicata idêntica é idempotente e divergência é conflito.
- Manter candidate, persisted, verified e advanced como estados separados.
- **Atualização 2026-10-11:** existe SETTLE candidato na biblioteca
  (PREPARE → CLAIM → SETTLE), mas a Fase 2 segue pendente: o owner produtivo
  do worker-result entre NativeDispatch e ProductiveActivation continua
  indefinido e o settlement canônico no TaskKernel — com revalidação de
  ownership/generation/revision e separação candidate/persisted/verified/
  advanced — não foi implementado. API candidata de biblioteca não é
  settlement produtivo.

**G2:** execução nativa real e vinculada gera EvidenceRef e settlement
canônico no TaskKernel; testes de falhas entre cada escrita + runtime exato.

## 5. Fase 3 — ADVANCE e execução de continuação (condicionada a G2)

- Após settlement, reler store/kernel, chamar ObjectiveController e persistir
  movimento/checkpoint.
- Planner deve consumir movimento: nova PREPARE para CONTINUE/RETRY/REPLAN;
  review por Reviewer quando a policy exigir; bloqueio explícito em budget,
  estado desconhecido ou ação não autorizada.
- Goal só termina com critérios globais verificados pelo mecanismo allowlisted.

**G3:** fixture runtime-real de três fases executa primeira chamada, encontra e
corrige falha controlada, chama Reviewer e inicia fase seguinte sem prompt
manual. Tool call seguinte precisa ser observável no runtime, não apenas JSON.

## 6. Fase 4 — Recovery (condicionada a G3)

- Interromper sessão controlada em boundary especificado; reabrir sessão
  substituta; revalidar ownership; carregar checkpoint e reconciliar recibos.
- Nunca repetir tentativa cujo efeito seja incerto. A substituta deve executar
  ação nova autorizada e atribuir ação/result ao seu próprio session ID.

**G4:** prova runtime-real de consumo e ação; canário/leitura/contexto isolados
não bastam. V1 e V2 têm gates independentes.

## 7. Fase 5 — Segurança, estabilidade e compatibilidade

- Testar adversarialmente owner/generation stale, corrida de intent,
  cross-session, replay, output forjado, provenance ausente, grants negados,
  recibo pendente, crash/partial settlement, reparse/junction, budget e DONE
  sem verificação.
- Manter enforcement OFF sem prova exata; medir o caminho autorizado, não
  somente o hook fail-open.
- FIX4-2b: reproduzir/registrar telemetria causal e identificar por que o
  primeiro kill não ocorreu; preservar asserts. Hipótese de deadline/CIM não
  confirmada não autoriza classificar flake nem alterar timeout.
- Hash user-owned `DE22307F`/`C1BB84F2…`: preservar configuração; investigar
  contratos do teste sem forçar snapshot pessoal.
- Rodar PS5.1/PS7, runtime V2 2.0.23 e V1 1.18.34 quando binários disponíveis;
  resultados em 2.0.26 são adicionais. Não instalar provider nem trocar modelo.

**G5:** zero P0/P1 sem tratamento, sem regressões de segurança, falhas
ambientais claramente separadas. **G6:** suítes e reviewers aprovados.

## 8. Fase 6 — Aceitação e fechamento (condicionada a G1–G6)

Uma sessão do Planner recebe apenas o Objective inicial, faz PREPARE, executa
worker nativo, liquida, verifica, avança e inicia outra Task; executar também
recovery por sessão substituta. Registrar runtime exato, provider/model (sem
segredos), sessão/children, Goal/Task/intent, chamadas, settlement, evidence,
next move, checkpoint e resultados de validação.

**G7:** FINAL CLOSURE READY somente com todos os critérios de execução e
recovery provados no runtime real. Caso provider/runtime/capacidade esteja
indisponível, PARTIAL CLOSURE/BLOCKED com consequência funcional explícita.

## 9. Ordem de entrega e rollback

1. G0/documentos (entregue neste change).
2. PR-A: biblioteca PREPARE/CLAIM/SETTLE candidata entregue sem wiring;
   chamada nativa e SETTLE produtivo permanecem apenas após desbloquear G1.
3. PR-B: ADVANCE + recovery, após G2/G3.
4. PR-C: aceite runtime-real, regressões, docs/evidência.

Revisão independente e security review antes de merge; CI por PR. Nada de push
direto em master, bypass de branch protection, tag rewrite ou merge implícito.
Rollback de código deve parar novos PREPAREs e preservar receipts/evidências
pendentes; nunca apagar efeitos/recibos para “limpar” o estado.

## 10. Estado atual e próximos passos

- G0: **concluído**. G1: **primitiva parcial aprovada; wiring produtivo pendente**.
  O V2 2.0.23 provou hooks pre/after, `permission.evaluate` deny em read/edit e
  um shell command literal, `ctx.session.get(child).parentID` e localização do
  projeto no fixture global. `ctx.permission.rules` não existe no contexto
  Promise deste pin. NativeDispatch PREPARE/CLAIM/SETTLE candidatos foram
  implementados e revisados apenas como biblioteca (atualização 2026-10-11
  em §2).
- Ainda não há CLI caller, integração com o bundle V2, SETTLE produtivo no
  TaskKernel, VERIFY, ADVANCE ou recovery produtivos — o SETTLE existente é
  API candidata de biblioteca, sem consumidor em plugin/CLI/kernel. G1–G7 não
  estão aprovados; verdict permanece `PARTIAL CLOSURE`.
- Não houve alteração de flag/configuração, instalação, provider change, PR,
  commit ou merge. A config e os adapters user-owned permanecem intactos.
- Próximo desenvolvimento possível: protótipo V2-only, limitado a Goal/Task
  pré-admitidos no checkout, bridge PowerShell local por argv/JSON fixos e hook
  deny-only. Não usar `ctx.permission.rules` (ausente no pin); não instalar
  scripts nem alterar config global. Antes de execução real de worker, fechar
  a origem de grants, proteger bridge/receipt contra escrita do child e testar
  plugin ausente/unload + ações shell/MCP/CodeMode. V1 e enforcement geral HOLD.
- Estado da atualização 2026-10-11: biblioteca com PREPARE/CLAIM/SETTLE
  candidatos e FIX6C fechado em classificação/reserva; suíte Handoff sintética
  1745/1745 em PS5.1 e PS7 (detalhes e reviews em §2). Nenhum probe de
  runtime foi reexecutado; recibos internamente consistentes não provam
  liquidação do TaskKernel; `runtime_grant_enforcement` segue OFF/HOLD;
  nenhuma alteração de flag/configuração, instalação, provider ou credencial.
