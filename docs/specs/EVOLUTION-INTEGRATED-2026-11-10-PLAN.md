# EVOLUTION INTEGRATED — PLAN (2026-11-10)

**Versão:** 1.2
**Data-base:** 2026-11-10 (revisão 2026-11-11)
**Baseline de commit:** `beb0ea4` (branch `feat/evolution-integrated-20261110`)
**SPEC:** [EVOLUTION-INTEGRATED-2026-11-10-SPEC.md](EVOLUTION-INTEGRATED-2026-11-10-SPEC.md)
**Status:** PAUSED — missão encerrada pelo orientador; implementação do backlog residual continua na próxima sessão (handoff em §14).

---

## 1. Estratégia

Uma missão autorizada pode abranger vários marcos e subtarefas. O Planner:

1. inspeciona o estado real (código, evidências, issues, flags);
2. escolhe o menor incremento funcional que reduz uma lacuna comprovada;
3. implementa com os componentes existentes;
4. valida com o teste focado e as checagens proporcionais ao risco;
5. registra o resultado e segue para o próximo incremento, ou encerra a issue
   com evidência em vez de recriá-la.

Sem novo agente, controlador, framework, banco, painel ou mecanismo de
permissão quando o recurso nativo já atende. Ações destrutivas, produção,
credenciais e comunicação externa continuam sujeitas à autorização aplicável.

## 2. Sequência e dependências

```
M0 + M1  (limpar pendências e fechar o núcleo de execução)
   |
   +--> M2 + M3  (planejamento adaptativo e infraestrutura nativa)
   |        |
   |        +--> M4  (memória e eficiência)  --+
   |        |                                 |
   |        +--> M5  (qualidade e reparos)  ---+--> M6 (autonomia prolongada)
   |
   +--> M7  (piloto independente, baixo escopo)
```

Regras de dependência:

- **M4:** #177 (lições verificadas) antecede #77 (receitas determinísticas).
- **M6:** #143 (sessões) e #183 (eventos) funcionais antes de #2 e #185.
- **M5** pode correr em paralelo com **M4**.
- **M7** é independente e pode ser executado a qualquer momento.
- Nenhum marco posterior bloqueia M0/M1; impedimento real em um marco não
  interrompe entregas independentes.

## 2.1 P0 — Reformulação do Planner (transversal, prioridade atual)

**Origem:** diretriz de 2026-11-10 na issue #48 (Kusts/opencode-orchestration),
relacionadas #8/#10/#60/#141/#237 e política global `kust-projetos/agent-config#21/#4`.
**Regra:** P0 não é um marco novo nem um segundo sistema; é uma correção de
contrato de papéis aplicada às peças existentes antes de retomar M2–M7.
M0/M1 e as entregas já commitadas permanecem válidos.

### 2.1.1 Diagnóstico (estado real, não hipótese)

| # | Achado | Evidência |
|---|---|---|
| D1 | O texto global descrevia o Planner como coordenador, mas autorizava execução direta em mudanças pequenas, sem worker. | `source/global/AGENTS.md` §Método de desenvolvimento (bullets 1 e 7) e §Orquestração (apontador) |
| D2 | O adapter V2 tratava `DIRECT_VERIFIED` como rota zero-worker para micro-edição **com escrita** (docs e código funcional). | `source/adapters/opencode-v2.md` §Workflow Adaptativo (142-146), §Runtime Wiring (202-205), §Controlled Routing (339), §Ciclo/DONE (513-515) |
| D3 | O classificador confirmava o comportamento: `isMicroEditWrite` e `isCodeMicroEditWrite` retornavam `DIRECT_VERIFIED` com `selected_agents=[]`. | `scripts/v3/lib/OrchestrationPreflight.ps1` (556-573, 583-585) |
| D4 | O DONE gate já sabia exigir worker no trivial (`SINGLE_WORKER` + participação > 0); faltava o roteamento, não um gate novo. | `Test-OrchestrationDoneCompliance` (113-186) |
| D5 | As instruções deste checkout repetiam a mesma permissão (“trabalho local… segue direto”). | `AGENTS.md` §Orquestração |
| D6 | `docs/ARCHITECTURE.md` não listava `DIRECT_VERIFIED` na tabela de estados nem documentava Goal/Loop; a tabela ainda dizia “preflight obrigatório”, divergindo do adapter condicional. | `docs/ARCHITECTURE.md` 75-90 |
| D7 | Goal/Loop existem e estão provados em testes, mas o plano não fixava o contrato de uso nem a regra Task DONE ≠ Goal DONE no texto de papéis. | `OrchestrationGoalKernel.ps1`, `Get-OrchestrationGoalNextMove`, `OrchestrationAutonomousLoop.ps1`, `OrchestrationPlannerLoop.ps1`, `OrchestrationNativeResume.ps1`; evidência de #234 no `CHANGELOG.md` |
| D8 | Bloqueios reais observados: CI do PR #238 estava pendente na pausa; provider de modelo limita turnos vivos; M7 depende de produto/credenciais. | PR #238 (agora 6/6 verde), `evidence/evolution-2026-11-10/m7-t3code-hold.md` |

### 2.1.2 Contrato de papéis (P0-R1)

- **Planner (`build`):** interpreta objetivo, escolhe estratégia, metodologia,
  modelo e worker, decompõe Goal em Tasks, acompanha evidência, decide replan,
  espera/retomada, prioriza e encerra. Pode ler, planejar e consultar estado.
  **Não edita arquivos, não implementa, não roda teste de implementação.**
- **Workers:** cada um executa sua função no escopo delegado. Coder implementa e
  roda o teste focado; Tester valida independentemente quando útil; Reviewer
  julga; Debugger investiga; Docs Manager cuida de documentação afetada por
  contrato/API. Nenhum é convocado por ritual.
- **Task Kernel:** estado, grants/leases, verificação allowlisted, evidências e
  `DONE`. Worker nunca emite `verified_pass`/`DONE`.
- **Advisor/JEV:** consultoria opcional e read-only em decisão difícil; nunca
  gate, nunca autoridade, no máximo uma consulta por decisão.

### 2.1.3 Roteamento (P0-R2)

| Situação | Rota | Gate |
|---|---|---|
| Leitura, análise, ponto de código, planejamento sem mutação | `DIRECT_VERIFIED` (zero workers) | `-Decision DIRECT_VERIFIED -ExecutionShape DIRECT_VERIFIED -DirectReason DIRECT_VERIFIED_*` |
| Escrita de qualquer arquivo (docs, comentário, código) | `SINGLE_WORKER` com um worker apropriado + teste focado | trivial exige `ExecutionShape=SINGLE_WORKER` e participação observada > 0; zero participação ⇒ `ORCHESTRATION_POLICY_BYPASS` |
| Não trivial, multi-arquivo, risco, Kernel | `MULTI_WORKER` / `PERSISTENT_GOAL` / `BLOCKED` | regras existentes |
| Router/registry indisponível em rota delegada | `DETERMINISTIC_FALLBACK` | owner determinístico observado |

Sem novo estado, flag, parâmetro ou gate: a mudança é o classificador deixar de
emitir `DIRECT_VERIFIED` para escrita e usar o ramo `SINGLE_WORKER` já existente.

### 2.1.4 Goal, Loop e continuidade (P0-R3)

- **Task** = unidade de execução. **Goal** = missão persistente multifase,
  somente quando houver mais de uma Task; criado/atualizado no GoalKernel com
  CAS persistido.
- **Loop** = `Get-OrchestrationGoalNextMove` + `Invoke-OrchestrationAutonomousObjective`
  sobre estado existente. Não é daemon, scheduler novo, polling intenso nem
  segundo controlador.
- **Retomada** = `OrchestrationNativeResume` / `github-resume-reconcile` /
  GH-WAKE já existentes; nunca reexecutar efeito ambíguo.
- **Conclusão:** Task DONE não conclui Goal. Goal só conclui por CAS do
  GoalKernel quando todas as Tasks exigidas estiverem verificadas.
- **Intervenção humana:** só em mudança material de escopo/produto, gasto não
  autorizado, produção/destruição irreversível, segredos/dados pessoais ou
  ausência real de autorização. Espera de CI, falha de provider, review
  rotineiro e subtarefa falha não viram pergunta ao usuário.

### 2.1.5 Entregas P0

| ID | Entrega | Owner | Aceite |
|---|---|---|---|
| P0.1 | Classificador: escrita deixa de ser `DIRECT_VERIFIED` e passa a `SINGLE_WORKER`; leitura direta exige evidência de consulta e `read` com intenção de edição também delega; leitura continua direta | coder | suíte de preflight + GW verdes; regressão 15z + matriz de escrita |
| P0.2 | Instruções canônicas: `source/global/AGENTS.md`, `source/adapters/opencode-v2.md`, `AGENTS.md` do checkout | Planner | contrato de papéis, rota por mutação, Goal/Loop, autonomia por missão |
| P0.3 | `docs/ARCHITECTURE.md`: estados reais, contrato de papéis, Goal/Loop | Planner | doc consistente com `source/` |
| P0.4 | Prova runtime-real curta: microedição por worker (A) e correção de bug por worker (B) | worker + Planner | evidência com sessão/dispatch; Planner não edita |
| P0.5 | Prova de autonomia longa: Goal ≥ 3 Tasks, falha real, replan, retomada, DONE do Goal sem intervenção | Planner + workers | evidência; se provider bloquear, `BLOCKED` com perna exata |
| P0.6 | Baseline antes/depois (DONE correto, prompts humanos, tempo, tokens/custo, retrabalho) | Planner | tabela com medição observada ou `UNKNOWN` |

### 2.1.6 Baseline a coletar (P0.6)

| Métrica | Antes (baseline documentado) | Depois |
|---|---|---|
| DONE correto | M5 `m5-done-proof6` (kernel-executed) | Goal `p0-autonomy-20261111` `COMPLETED` rev 16 com 3/3 Tasks; `complete` recusado antes de T3 |
| Intervenções humanas por missão | 1 por checkpoint (pausa 2026-11-11) | 0 dentro da missão P0.5 |
| Tempo até DONE | não medido de forma comparável | ~2m30s para as 3 Tasks (Goal 18:29:28Z→18:31:58Z); harness à parte |
| Tokens/custo por DONE | `model_attempts` e cache metrics existentes | `UNKNOWN` (4 dispatches de worker; nenhum token inventado) |
| Retrabalho / retomadas | E2E M5 (2 findings, 1 rodada) | 1 falha real (teste `3/1`) + 1 `LOCAL_REPAIR`; retomada por processo novo (rev 12) |

Nenhum valor é inventado: sem medição, `UNKNOWN`.

### 2.1.7 Sequência

1. P0.1 → P0.2 → P0.3 (contrato e roteamento consistentes).
2. P0.4 e P0.5 com evidência runtime; P0.6 preenchido com o que for observado.
3. Só então retomar as pendências de M2/M4/M6 listadas na seção 13.
4. Nenhuma entrega de M0–M7 é descartada; entregas já provadas não são refeitas.

## 3. M0 — Reconciliar pendências

**Objetivo:** comparar evidência histórica com o estado atual e encerrar o que
já está comprovado. Não implementar funcionalidade nova.

Passos:

1. **#61 (Jev):** conferir `i61-jev-native-proof-2026-10-12.json`, flag
   `jev_advisory`, testes de fallback e consumo advisory-only; preparar
   comentário de fechamento com refs.
2. **#21 (distribuição):** executar
   `tests/distribution/run-distribution-tests.ps1`; comparar falhas com o
   título da issue (dialeto V1 vs V2, pin 2.0.23); atualizar a issue se o
   cenário mudou.
3. **#172 (flake watchdog):** tentar reprodução focada; se não reproduzir,
   registrar limitação de ambiente e manter aberta apenas se houver sinal
   recorrente.
4. **PR #210:** comparar diff com a política atual; não integrar configuração
   anterior ao merge #236; decidir entre descartar, reabrir contra a master ou
   extrair apenas o que ainda falta.

Validação: `scripts/test-package-consistency.ps1`; leitura das evidências
citadas; nenhuma issue fechada sem revisão do maintainer.

Saída: matriz de reconciliação atualizada na SPEC; issues candidatas a
fechamento com comentário de evidência.

## 4. M1 — Núcleo de execução autônoma

**Objetivo:** provar o encadeamento integral e só então decidir sobre
automação.

Fatia 1 (já implementada nesta rodada — ver seção 10):

- cadeia canônica Sonnet → Opus → Astra codificada e verificada;
- Sol fixado como candidato de mesmo tier T4;
- guarda de consistência política ↔ adapter (check 17);
- testes negativos para drift de política e de adapter.

Fatia 2 (próxima):

1. preparar uma Task real com critério verificável e papel admissível a T3;
2. executar o protocolo da SPEC §8 usando as primitivas existentes;
3. registrar cada artefato (`model-select`, `session`, `message`,
   `verify-run`, `model-attempt`, `model-proof`);
4. provar que sucesso T3 **não** autoriza T4;
5. provar que ausência de prova **não** autoriza novo dispatch;
6. provar fallback válido pelo mecanismo existente, quando aplicável.

Fatia 3 (somente após a prova):

- se o Planner executou o encadeamento a partir de uma única instrução,
  documentar o protocolo e não criar controlador;
- se falhou por lacuna de ferramenta, corrigir a menor lacuna nas primitivas
  existentes (nunca um segundo Planner).

**#50:** levantar onde o código depende de versão fixa e onde bastaria uma
capacidade observável; propor substituição por checks de capacidade com
fail-closed. **#141:** auditar as três superfícies (OpenCode, Agent Config,
Task Kernel) e registrar quem controla cada permissão; remover duplicação
apenas com paridade comprovada.

Validação: suíte do Kernel/model router; protocolo runtime-real; nenhum claim
sem provider vivo.

## 5. M2 — Planejamento híbrido

**Objetivo:** instalar e selecionar quatro origens de técnica sem criar um
novo Planner.

| Origem | Uso | Primeira técnica |
|---|---|---|
| Superpowers | depuração, planejamento de implementação, verificação | `systematic-debugging`, `writing-plans`, `verification-before-completion` |
| BMAD v6.12 | requisitos, divisão de features, planejamento multifase | análise de requisitos + decomposição |
| Matt Pocock | decisões técnicas e qualidade de interface | revisão de API/tipos |
| Addy Osmani | implementação incremental, revisão, performance, arquitetura | revisão incremental/performance |

Passos:

1. **#237:** inventariar o que já está disponível no catálogo; selecionar o
   menor conjunto estável; pinar versão e licença; estender o instalador
   (`skills-core` → destino V2) sem duplicar conteúdo; validar instalação
   isolada.
2. **#48:** escrever a matriz de seleção a partir de `hybrid-development`
   (Direct, Structured, High-risk, Discovery) acrescentando os gatilhos das
   quatro origens; nada de motor concorrente.
3. **#64:** medir custo de contexto da descoberta; carregar por gatilho;
   registrar quando uma skill foi sugerida, carregada e usada.

Validação: instalação V2 isolada; microcorreção Direct; feature multifase com
técnica BMAD; revisão complexa com técnica Addy; JEV opcional.

## 6. M3 — Infraestrutura nativa e remoto

| Issue | Incremento mínimo | Teste |
|---|---|---|
| #139 | PTY/lifecycle nativo para comando longo | comando longo continua e devolve resultado |
| #140 | worktree nativo onde houver paridade | dois trabalhos isolados sem perder alterações |
| #143 | API nativa de sessões/arquivamento/listagem | retomar Task após reinício sem duplicar execução |
| #203 | SSH/Docker context/MCP remoto existente | Planner local executa Linux/container na VPS |

Regra: remover componente duplicado somente após substituição comprovada. Se
#203 já estiver atendida pelos recursos atuais, encerrar com evidência e zero
alteração de código.

## 7. M4 — Memória, contexto e aprendizado

1. **#12:** usar `EvidenceStore`/`ArtifactRef` existentes para manter logs
   completos fora do contexto principal, com recall exato.
2. **#11:** preservar prefixos estáveis e medir cache quando o provedor expuser
   métricas; nunca inventar valor de custo.
3. **#177:** conectar outcomes aprovados pelo Kernel ao AI Memory existente,
   com anti-gaming (somente `verified_pass`/`DONE`; nunca claim de worker).
4. **#77:** promover procedimento verificado a receita determinística somente
   quando ambiente e condições continuarem compatíveis; divergência devolve a
   decisão ao Planner.

Validação: tarefa repetida reaproveita evidência/procedimento sem perder a
verificação atual; comparar chamadas, contexto e tempo com a execução
original.

## 8. M5 — Qualidade e recuperação

1. **#200:** ancorar feedback do Reviewer em arquivo + trecho + commit
   revisados; detectar drift; encaminhar ao worker responsável.
2. **#103:** avaliar reparo localizado dentro da mesma Task antes de
   retry/replan; não repetir efeitos externos ambíguos.
3. **#192:** comparar Direct/Single, Cascade e Critique em poucos cenários
   verificáveis, reutilizando métricas e Golden Workflows existentes; sem
   segundo roteador.

Validação: revisão localizada retorna ao coder correto e passa sem reiniciar
tarefas concluídas; comparação apresenta sucesso, custo e latência observados.

## 9. M6 — Autonomia prolongada

Primeira fatia pequena: GitHub como único canal, no máximo duas sessões.

1. **#143** e **#183** funcionais.
2. **#2:** múltiplas sessões subordinadas ao mesmo objetivo, sem segundo
   Planner.
3. **#183:** Source/Trigger/Thread e subscriptions duráveis integradas ao
   Kernel, reutilizando GH-WAKE.
4. **#184:** admissão proativa por regras versionadas em `observe→auto`.
5. **#185:** ownership de conversa por Task, handback e context-only.

Validação: comentário pertinente chega uma vez à Task correta; comentário
informativo não cria Task; Kernel mantém o estado.

## 10. M7 — Piloto T3 Code

1. leitura e acompanhamento de sessão;
2. ação controlada em projeto descartável;
3. confirmar que o Task Kernel continua responsável pelas conclusões.

Se não atender, registrar o resultado e encerrar o piloto.

## 11. Validação padrão

Para cada entrega:

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
```

- teste focado da mudança (suíte `*.tests.ps1` afetada);
- smoke real do OpenCode V2 quando a mudança tocar runtime/instalação;
- suíte ampla (`scripts\v3\run-v3-tests.ps1`,
  `tests\distribution\run-distribution-tests.ps1`) quando o alcance justificar;
- `git diff --check` após edição.

Nenhuma ferramenta de teste disponível ⇒ não alegar que passou.

## 12. Protocolo de handoff

Ao concluir ou interromper um marco, registrar em um único registro primário
(commit, issue/PR ou memória operacional) os cinco campos: objetivo/estado,
alterações, validação, decisões/pendências e próximo passo. Para microtarefas,
uma linha nesse registro; não criar arquivo ou relatório novo.

## 13. Estado desta execução — retomada P0 (2026-11-11)

**Status:** ACTIVE. A missão foi retomada com a diretriz P0 (§2.1). O PR #238
está com CI 6/6 verde e permanece aberto; nenhum merge/deploy.

**P0 executado nesta retomada:**

- Diagnóstico D1–D8 consolidado (§2.1.1), incluindo o ponto exato do
  classificador que autorizava escrita direta.
- P0.1: `Get-OrchestrationPreflight` deixou de emitir `DIRECT_VERIFIED` para
  `isMicroEditWrite`/`isCodeMicroEditWrite`; essas rotas caem no ramo
  `SINGLE_WORKER` trivial já existente. `Test-OrchestrationDoneCompliance`
  permaneceu intocado.
- Testes: `orchestration-preflight.tests.ps1` 286/286 (novos casos 15z:
  leitura direta, escrita com worker, participação zero ⇒ bypass, escrita
  sensível/arquitetura fora da rota trivial, matriz de 12 combinações de
  escrita); `OrchestrationAdvisorEfficiencyGW.tests.ps1` 145/145;
  `test-package-consistency.ps1` 17/17.
- Revisão independente: F1 (`ReadWrite=read` com intenção de edição) e F2
  (consumidores de evidência com escrita direta) corrigidos; WL-01 agora mede
  lookup read-only e retorna `COMPLIANT`.

**M5 wiring entregue em 2026-11-11:**

- `task-kernel.ps1 -Action review-schema` publica o schema versionado de
  findings ancorados (read-only, sem `-TaskId`); `Get-OrchestrationReviewFindingsSchema`
  é puro e determinístico. #200 segue PARCIAL: falta injetar o schema no
  contrato de dispatch do reviewer.
- `scripts/v3/repair-decision.ps1` expõe `LOCAL_REPAIR`/`REPLAN`/`ESCALATE`
  deterministicamente para o Planner consultar antes do retry; nenhum dispatch,
  nenhuma decisão automática pelo Kernel. #103 segue PARCIAL.
- Testes: ReviewAnchor 29/29 (PS5.1 e PS7), repair-decision 10/10 (PS5.1 e
  PS7), TaskKernel 117/117 (PS5.1 e PS7, após tornar o spawn do CLI portátil),
  package-consistency 17/17. Revisão independente: F1 MEDIUM + LOWs corrigidos;
  re-revisão **APPROVED** com 5 LOW residuais não bloqueantes (strictness de
  parâmetros, fronteiras de finding_id/file/line/commit, line fracionária,
  nomes derivados).

**P0.6 executado em 2026-11-11:** sessão OpenCode descartável
`ses_e33ea8cdcffeiZrUtkt0puBPS3` criada por `opencode run`; processo encerrado e
retomado com `opencode run --session`, recuperando o token exato da primeira
mensagem (input 108, cache read 47.744) sem repetir a tarefa. Goal
`p0-autonomy-session-20261111` `COMPLETED` (rev 13). Evidência em
`p0-autonomy/session-resume/`.

**#12/#11 e M3 (2026-11-11):** CLIs `evidence-virtualize.ps1` (7/7;
109.209 bytes → preview 2.000; recall com SHA) e `cache-metrics.ps1`
(amostras reais, custo `UNKNOWN`) integradas ao mandato. #140 provado com
`POST/GET/DELETE /api/worktree`; #203 provado em leitura com
`ssh contabo-prod "uname -a; docker ps"`. M7/#205 permanece HOLD.
**Retomada 2026-11-12 (#12):** wiring do `worker_result.detail` no Task Kernel
concluído (`Set-OrchestrationTaskWorkerResult`, preview+artifact_ref
content-addressed, confinamento/redação, erros tipados); testes
`OrchestrationTaskKernelEvidenceVirtualization.tests.ps1` 10/10 e runner
`OrchestrationTaskKernel` 5/5 em PS7/PS5.1; medição 1.939→4.372 B (artefato
120.003 B, store 326/369 ms, recall 1/8 ms). #11 segue PARCIAL.
**Atualização 2026-11-12 (#200/#103):** E2E vivo concluído na task `e2e-review-repair-001` (2 findings ancorados CHANGES_REQUIRED → decisão advisory LOCAL_REPAIR persistida em `repair_decisions` → correção → re-review APPROVED → `verified_pass` kernel-executed → DONE rev 12); #200/#103 COBERTOS, sem relaxamento de gates nem mudança em `verified_pass`/DONE.

**M3 fechado em 2026-11-11:** #140 provado com `POST/GET/DELETE /api/worktree`
(worktree descartável criado, usado e removido; nenhum existente tocado).
#203 provado em leitura: `ssh contabo-prod "uname -a; docker ps"` a partir do
PC (Linux + 5 containers), sem mutação. #139 já estava coberto. M7/#205 segue
HOLD (produto/credenciais externos).
`next_action` (CI/wait), não o envelope `source/trigger/thread/delivery_id`
consumido pelo bridge. **Decisão do orientador (opção b):** GH-WAKE permanece
retomada/readiness; o envelope pertence ao event-intake/bridge, cujo produtor
real é webhook/Action externo. Não fabricar `delivery_id` nem criar
webhook/Action/scheduler/controlador. #183 segue PARCIAL — fronteira
documentada em `docs/specs/GITHUB-EVENT-ENVELOPE-BOUNDARY-2026-11-12.md`
(2026-11-12); integração automática externa autenticada/persistente pendente
(risco material: ingress não autenticado, sem prova criptográfica de origem).

**Wiring #200/#103 (fluxo real):**

- #200: `source/agents/reviewer.md` exige findings ancorados no schema e
  referencia `task-kernel -Action review-schema`; o adapter fixa que o Planner
  inclui o schema no dispatch e registra os findings com `-FindingsJson`.
- #103: o mandato V2 injetado instrui o Planner a rodar
  `scripts/v3/repair-decision.ps1` após falha comprovada antes de escolher
  retry (`LOCAL_REPAIR`/`REPLAN`/`ESCALATE`), como decisão advisory, sem novo
  gate. Harness V2 247/0; plugin-dual-runtime 20/20; typecheck PASS.
- P0.2/P0.3: instruções canônicas (global, adapter V2, `AGENTS.md` do
  checkout), `docs/ARCHITECTURE.md` e o mandato V2 injetado pelo plugin
  (`plugins/orchestration-enforcement/shared/mandate.ts`, bundle regenerado)
  alinhadas ao contrato de papéis, à rota
  por mutação e ao contrato Goal/Loop.

**Pendente em P0:** P0.6 com tempo/tokens medidos além da amostra P0.5. Evidência
da fatia em `p0-planner-roles.md`; a missão real está em
`p0-autonomy/p0-5-mission.md`.

**P0.5 executado em 2026-11-11:** Goal `p0-autonomy-20261111` com 3 Tasks
dependentes, delegadas a coder/tester. T2 falhou de forma real (`3/1`,
`2*3=7` vs `6`); `repair-decision` retornou `LOCAL_REPAIR`; o Planner mudou a
estratégia (defeito na expectativa de aceite), o coder corrigiu e o teste
passou (`4/0`). O estado foi recarregado por processo novo (`resume`, rev 12),
`complete` foi recusado com T1+T2 e o Goal concluiu `COMPLETED` (rev 16) só
após a validação independente de T3. 0 intervenções humanas; 4 dispatches;
~2m30s; tokens `UNKNOWN`. A interrupção foi de processo/sessão de worker, não
reinício do OpenCode.

**Encerramento (2026-11-11):** decisão `ENCERRAR` do orientador após o
checkpoint de P0.6/#12/#11/M3. Critérios cobertos: plano atualizado, papéis
corrigidos, autonomia longa validada (P0.5) e retomada nativa (P0.6), PR #238
com CI 6/6, próxima etapa definida. Pendências residuais preservadas:
#12/#11 no `EvidenceStore` do Kernel, produtor externo do #183, #64/#192,
M7/#205 (HOLD) e reconciliação do config ativo. Nenhum novo ciclo de
implementação, merge ou instalação nesta missão.

**Registro da pausa anterior (preservado):**

**Status anterior:** PAUSED. Implementação interrompida a pedido do usuário; nenhum
trabalho em andamento. Branch, commits e PR preservados.

**Publicação:**
- Branch `feat/evolution-integrated-20261110`
- PR #238: https://github.com/Kusts/opencode-orchestration/pull/238
- Últimos commits: `dd3f5e8` (bridge/ack M6), `408a112` (#77 custo),
  `8c9befb` (probes M3).
- CI do run `42943040689` no momento da pausa: linux collector e smokes
  V1/V2 **PASS**; ps51, ps7 e v2 lane **pending**. Nenhum merge/deploy.

**Entregue e verificado:**

- **M0:** #21 revalidada (6/6 suítes), #61/#143 mapeadas, PR #210 não
  mergeável; evidência em `evidence/evolution-2026-11-10/m0-issue21-revalidation.md`.
- **M1:** cadeia canônica Sonnet→Opus→Astra + check 17 (32 asserts); prova
  runtime real `model-select → dispatch T3 → model-attempt → model-proof`
  (T3/T4 fail-closed); evidência em `m1-planner-chain-runtime.md`.
- **M2:** 8 skills-core (BMAD/Pocock/Addy em texto original) e seleção por
  forma da tarefa; `fresh-install` 53/0, `idempotency` 17/0, `rollback` 33/0.
- **M3:** PTY nativo (`exited exitCode=0`) e shell longo (`status=exited`,
  output `shell-ok`) provados; 42 worktrees nativos listados. #139 COBERTO;
  #140 PARCIAL (create/remove não exercitados); #203 SPIKE.
- **M4:** #12/#11 PARCIAL (libs 18/18, wiring pendente); #177 COBERTO
  (lição durável + recall em segunda sessão); #77 COBERTO (receita
  determinística, custo 1 chamada original → 0 no replay duplo).
- **M5:** #200/#103 PARCIAL (âncora/drift/owner 18/18, reparo 13/13,
  integração no Kernel 17/17); E2E vivo coder→reviewer→coder com 2 findings
  reais corrigidos; `DONE` kernel-executed provado na Task
  `m5-done-proof6-20261110`.
- **M6:** intake (8/8), entrega+ack idempotentes (12/12), bridge
  GH-WAKE→Kernel (9/9) e E2E real `issue:6`/`comment-5993719807` →
  worker → ack. #183/#184/#185 PARCIAL: call-site automático do GH-WAKE,
  regras observe→auto e handback completo pendentes.
- **M7:** HOLD — depende de acesso ao T3 Code e projeto descartável.

**Validação final executada:**

- `package-consistency` 17/17
- `TaskKernel` 114/114; `ModelProof` 169/169; `Correlation` 34/0;
  `TrustedPaths` 8/0
- `ModelChain` 32/32; `Observation` 18/18; `CacheMetrics` 18/18;
  `ReviewAnchor` 18/18; `LocalizedRepair` 13/13; `Learning` 20/20
- `EventIntake` 8/8; `TaskEvent` 12/12; `EventBridge` 9/9
- `ReviewIntegration` 17/17; `fresh-install` 53/0; `idempotency` 17/0;
  `rollback` 33/0

**Pendências para retomar (histórico da pausa anterior — superado por §14):**

1. Confirmar o CI final do PR #238 (ps51/ps7/v2 lane).
2. #140: provar criação/remoção de dois worktrees nativos.
3. #203: provar SSH/Docker real a partir do Planner local.
4. M6: ligar o tick do GH-WAKE à bridge, regras observe→auto (#184) e
   handback completo (#185).
5. M7 (#205): piloto T3 Code quando houver acesso/produto.
6. #64 (custo de descoberta), #48 completo e #192 (estratégias).
7. Wiring de #12/#11/#200/#103 no Kernel/Planner.
8. Revisão do maintainer para fechar #21/#61/#139/#143/#177/#77/#237/#208.

**Não alegado:** automação M1 em um único comando; M3 remoto; M6 totalmente
automático; M7; dispatch T4/Astra; qualquer alteração de flag, permissão,
credencial ou produção.

## 14. Handoff para a próxima sessão (2026-11-11)

**Objetivo:** continuar a implementação do backlog residual M0–M7 na próxima
sessão, sem refazer o que já está provado.

### 14.1 Estado atual (reconciliar antes de agir)

- Branch `feat/evolution-integrated-20261110`; HEAD `16a1c84`; PR #238 aberto e
  mergeable; CI do HEAD **6/6 SUCCESS** (linux collector, ps51, ps7, v2 lane,
  smokes V1/V2). Nenhum merge/deploy.
- Missão integrada encerrada pelo orientador em 2026-11-11. O encerramento vale
  para os critérios da missão, **não** para todo o backlog: 9 issues COBERTAS,
  9 PARCIAIS, 6 ABERTAS, 1 HOLD e PR #210 não integrado.
- Config ativo `~/.config/opencode` **não** foi reconciliado; as mudanças estão
  em `source/`, `generated/` e no bundle do plugin. Reconciliar só com pedido
  explícito.
- Evidências: `evidence/evolution-2026-11-10/` (P0, P0.5, P0.6, M3, M5, M6,
  M7) e `evidence/evolution-2026-11-10/p0-autonomy/`.

### 14.2 Ordem recomendada

1. **#12/#11 — wiring no EvidenceStore do Kernel (prioridade).** — **concluído em 2026-11-12 (#12).**
   - Inspecionar `Set-OrchestrationTaskWorkerResult` e `evidence_refs` em
     `OrchestrationTaskKernel.ps1`; integrar `New-OrchestrationArtifactRef`
     para detalhes/logs grandes, persistindo ref + preview e recuperando por
     hash. Não alterar o significado de `verified_pass`/`DONE`.
   - Aceite: Task real com log grande; ref e preview persistidos; recall
     íntegro; comparação de bytes/contexto/tokens/tempo com e sem
     virtualização. Se não houver benefício medido, manter apenas os helpers
     atuais e registrar a decisão.
   - Base existente: `scripts/v3/evidence-virtualize.ps1` (7/7),
     `scripts/v3/cache-metrics.ps1` (4/4), `OrchestrationObservationVirtualization.ps1`,
     `OrchestrationCacheMetrics.ps1`.
   - **Resultado (2026-11-12):** `Set-OrchestrationTaskWorkerResult` passou a aceitar `-DetailContent`/`-DetailPath`/`-DetailKind`/`-EvidenceStoreDir`/`-DetailPreviewChars` e persiste `worker_result.detail` aditivo com `preview` (<=2000 chars), `truncated`, `total_chars` e `artifact_ref` content-addressed ordenado (`sha256/path/bytes/kind/created`). Artefato redigido antes de persistir (`DETAIL_REDACTION_UNAVAILABLE` se indisponível); erros tipados/fail-closed `DETAIL_INPUT_CONFLICT`, `DETAIL_PATH_INVALID`, `DETAIL_PATH_NOT_ALLOWED`, `DETAIL_TOO_LARGE`, `DETAIL_ARTIFACT_FAILED`; `DetailPath`/`EvidenceStoreDir` confinados a `RepoRoot\cache` (boundary case-insensitive, sem `.git`/`models.jsonc`/`.env*`/`TasksDir`/segmentos com `:`/`~`/UNC/`\\?\`/>1 MiB/reparse-junction). Virtualização antes de `Write-TaskKernelRecord` e após todos os gates; sem `evidence_refs` top-level; `claimed_evidence/status/revision/produced_by` e `schema_version=1` intocados; DONE/`verified_pass`/settlement/freshness inalterados. Medição: task JSON 1.939 B sem detalhe → 4.372 B com detalhe 120 KB (delta 2.433 B), artefato 120.003 B; store 326/369 ms e recall 1/8 ms (PS7/PS5.1). Gate feliz: `wr.ok=True verify.ok=True done.ok=True state=DONE detail.sha256=f14668a90eed4e404e6366a6eda7b474a8cb91dd1f6b20c1958e5aa684538455`. Testes: `OrchestrationTaskKernelEvidenceVirtualization.tests.ps1` 10/10 e runner `-Name OrchestrationTaskKernel` 5/5 em PS7/PS5.1; `test-package-consistency.ps1` 17/17; `git diff --check` 0. Revisão independente APPROVED (rodada 4), LOWs aceitos (artefato órfão se write do record falhar; TOCTOU residual reparse→gravação; nomes com `~`/`:` em `cache` recusados). #11 permanece PARCIAL (medição de cache em execução real pendente).
2. **#200/#103 — E2E com o fluxo real.** — **concluído em 2026-11-12.**
   - Reviewer recebe o schema por padrão (`reviewer.md` + `review-schema`);
     Planner interpreta findings, roda `repair-decision`, persiste a decisão
     advisory e delega a correção.
   - **Resultado (2026-11-12):** código: `Add-OrchestrationTaskRepairDecision` no Task Kernel persiste `repair_decisions` (array aditivo, bound 20) com `decision/reason/constraints/severity/changed_files/scope_overlap/external_effects_ambiguous/evidence_current/attempts/failure_class/recorded_by/at/revision` (lock+CAS, recusa terminal, erros tipados `REPAIR_DECISION_INVALID`/`REPAIR_DECISION_NOT_ALLOWED`/`REPAIR_DECISION_TOO_LARGE`/`CAS_CONFLICT`, validação de contexto; advisory, sem gate — nenhum consumidor de DONE lê `repair_decisions`). CLI: `task-kernel.ps1 -Action record-repair-decision` (`-TaskId -ExpectedRevision -RepairDecisionJson -RecordedBy`). Mandato V2: Planner roda `review-schema`, inclui schema no dispatch do reviewer, registra findings com `-FindingsJson/-FindingsFile` e persiste a decisão com `record-repair-decision` (bundle regenerado; sidecar confere; typecheck v1/v2/dual PASS). Testes: `OrchestrationReviewRepairLoop` 17/17 (PS7/PS5.1), `OrchestrationReviewAnchor` 29/29, `OrchestrationReviewIntegration` 17/17, `OrchestrationLocalizedRepair` 13/13, `repair-decision` 10/10, runner `-Name OrchestrationTaskKernel` 5/5; `package-consistency` 17/17; `git diff --check` 0. E2E vivo (fixture `cache/e2e-review-repair-6ee1a9eb`, git real, task `e2e-review-repair-001`): implementação inicial `74847a6`; reviewer real com schema retornou CHANGES_REQUIRED com 2 findings ancorados (F1-no-input-validation, F2-missing-nonnumeric-test) persistidos na revisão 6 (âncoras `4016527d...`, `866a2762...`); `repair-decision` retornou LOCAL_REPAIR/localized-finding e decisão persistida na revisão 7; correção `42b2d22` (validação de inteiros e teste negativo); re-review APPROVED; verificação kernel-executed `verified_pass` (revisão 10); REVIEWING (11) e DONE (revisão 12). `review_history` preserva a rodada CHANGES_REQUIRED; `repair_decisions` preserva a decisão. Persistência no E2E feita via libs (as mesmas dos testes); CLI `record-repair-decision` com smoke próprio. Nenhum gate relaxado; sem mudança em `verified_pass`/DONE.
3. **#183 — produtor externo de eventos.** — **concluído em 2026-11-12 (documentação).**
   - Resultado: fronteira operacional/honesta documentada em `docs/specs/GITHUB-EVENT-ENVELOPE-BOUNDARY-2026-11-12.md` (contrato do envelope, mapeamento trigger→thread, `dedup_key`/`X-GitHub-Delivery`, fluxo, idempotência em três camadas, modelo de confiança com ingress devendo validar `X-Hub-Signature-256`/HMAC-SHA256, exemplos de referência não ativados, critérios para sair de PARTIAL).
   - Nota: integração automática externa autenticada/persistente segue **PARTIAL**; sem webhook/Action instalado/ativo, sem scheduler/daemon/controlador e sem fabricação de `delivery_id`.
4. **#64/#192, #50/#141, #2/#184/#185, #172.**
   - [x] #64: medição de custo reproduzível concluída em 2026-11-12 (`scripts/v3/skill-discovery-metrics.ps1`, 17/17 PS7+PS5.1): 133 skills válidas/1 inválida/109 junctions; metadados 10.174/9.720 tokens (ocorrência/únicos, `chars/4`), razão corpo/metadados 21,90, latência p50 ~196 ms/p95 ~296 ms (não determinística), seleção lexical top-5 ~348 tokens (`selection_ratio_vs_unique` 0,0358), 8 duplicatas com drift de conteúdo em `hybrid-development` (`differs=true`). Protótipo seletivo (F1 shadow) segue pendente: relevância/recall, falsa seleção, custo-até-DONE e continuidade de cache (Golden Workflows); status PARCIAL, sem promoção a COBERTO.
   - [x] #192 (2026-11-12, desenho + harness): corpus/design/harness concluídos (`docs/specs/STRATEGY-BENCHMARK-192-DESIGN-2026-11-12.md`, `source/registry/strategy-benchmark-corpus.json`, `scripts/v3/strategy-benchmark.ps1`/`strategy-benchmark.tests.ps1`, 74/74 PS7/PS5.1). Execução/piloto segue pendente (fixtures/verificadores e teto numérico > 0 aprovados).
   - [x] #50/#141: auditoria capability-first e de autoridade concluída em 2026-11-12 — [AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md](AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md) (pin inventory, achado do patch-exato nos smokes V2, mapa de ownership por superfície, HIGH-1/2/3 e MEDIUM/LOW, recomendações); ressalvas factuais aplicadas em `docs/PERMISSIONS.md` e `SECURITY.md`; #50/#141 promovidos a PARCIAL na SPEC. Correções de runtime/perfis dependem de operador; provas de runtime (precedência topo vs agente, `/api/session/{id}/shell`) pendentes.
   - #2/#184/#185: sessões subordinadas e handback completo. **#184 (fatia 1 concluída em 2026-11-12, fast path):** admissão determinística/shadow em `scripts/v3/lib/OrchestrationEventAdmissionIntent.ps1`, `scripts/v3/event-admission-intent.ps1` e `scripts/v3/lib/OrchestrationEventAdmissionIntent.tests.ps1` (`explicit|candidate|context_only|ignore`, modos `off|observe|auto` com `auto` `shadow=true`/`executable=false` sempre, fail-closed, sem Task/intake/bridge/kernel/LLM/flag nova). **Faltam (fatias 2-6):** regras de operador de baixo risco, slow path seletivo (LLM), auto executável com policy/grant, criação de Task e ingest autenticado.
   - #172: só reproduzir o flake com sinal real.
5. **PR #210:** comparar com a master atual; descartar ou reabrir contra a
   master. Não integrar configuração anterior ao merge #236.
6. **M7/#205:** piloto somente com produto/credenciais; caso contrário, HOLD.
7. **Reconciliação do config ativo:** somente após pedido explícito de
   install/reconcile; usar `scripts/reconcile-opencode-config.ps1` com backup.

### 14.3 Restrições que continuam valendo

- Sem novo controlador, scheduler, banco ou framework.
- Sem alterar flags, permissões, allowlist, credenciais ou produção.
- Sem merge/deploy fora de autorização explícita.
- Preservar evidências e não refazer etapas já provadas.
- Worker executa implementação/teste; Planner decide e delega; Kernel verifica.

### 14.4 Comandos de retomada

```powershell
git status --short
gh pr view 238 --json state,mergeable,statusCheckRollup
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
```

Primeira ação da próxima sessão: reconciliar HEAD/PR/CI e iniciar pelo item 1
(#12/#11), registrando a decisão de adotar ou não a integração com base em
benefício medido.

### 14.5 Handoff compacto (5 campos)

- **Objetivo/estado:** continuar M0–M7; P0, P0.5 e P0.6 provados; missão
  encerrada com residuais.
- **Alterações:** P0 (papéis/roteamento/instruções/mandato), M5 wiring, P0.5
  (Goal 3 Tasks), P0.6 (resume nativo), #12/#11 helpers, M3 (#140/#203).
- **Validação:** CI 6/6; V3 168/179; preflight 286/286; GW 145/145;
  TaskKernel 117/117; P0.5 14/14; evidence-virtualize 7/7; cache-metrics 4/4;
  typecheck PASS; package-consistency 17/17.
- **Decisões/pendências:** #183 opção (b); M7 HOLD; #12/#11 no EvidenceStore;
  #200/#103 E2E; #64/#192/#50/#141/#2/#184/#185/#172; PR #210; config ativo.
- **Próximo passo:** item 1 de §14.2.

## 15. Handoff para a próxima sessão (2026-11-13)

### 15.1 Estado

- Branch `feat/install-ownership-agent-config-20261111`, HEAD `3dbd000` (pushado).
- PR #239 **MERGEABLE**. No momento do handoff: 4 checks **SUCCESS** + 2 **IN_PROGRESS** (`ps7`, `v2 lane`). Reconciliar o estado final de CI antes de agir.
- **Sem merge/deploy.**

### 15.2 O que foi entregue desde o §14

- `c0fdfdc` — fechar M6 (docs). Evidência: registro documental de fechamento M6.
- `0ac82b8` — kernel #12/#11 + #200/#103. Evidência: `worker_result.detail` + `artifact_ref` (suíte 10/10) e `repair_decisions` advisory com mandato/E2E vivo DONE rev. 12.
- `2865de7` — docs. Evidência: atualização documental associada ao avanço do kernel/review-repair.
- `2ef9aa8` — #183 boundary. Evidência: fronteira de eventos GitHub documentada; integração automática externa autenticada/persistente pendente.
- `ca2291e` — #64 medição. Evidência: 133 skills, 10.174 tokens (metadados, ocorrência), razão corpo/metadados 21,90x, seleção lexical top-5 3,58%; F1 não executado.
- `2499838` — #50/#141 auditoria. Evidência: auditoria capability-first/autoridade com 3 HIGH (grants sem runtime, precedência não provada, `/shell` REST sem deny) e ressalvas em `PERMISSIONS/SECURITY`.
- `48ee518` — #192 harness. Evidência: desenho + corpus + harness; piloto bloqueado, sem modelo.
- `3dbd000` — #184 fatia 1. Evidência: fast path determinístico de admissão de eventos em shadow (`executable=false`).

**Estados atuais:** #12 **COBERTO**; #200/#103 **COBERTOS**; #183 **PARCIAL** (produtor/ingress autenticado pendente; risco de origem não autenticada); #64 **PARCIAL** (medição concluída, F1 pendente); #50/#141 **PARCIAL** (auditoria concluída, correções/provas runtime pendentes); #192 **PARCIAL** (piloto bloqueado, sem modelo); #184 **PARCIAL** (fatia 1); #11 **PARCIAL** (medição de cache em execução real pendente); #2/#185 **abertos**; #172 **flake** (aguarda sinal real); PR #210 **CONFLICTING**; M7/#205 **HOLD**.

**Agent Config:** ADR/SPEC alinhados ao ownership v2 (commit `4f0fd88` no repo `agent-config`, local `main`, **sem push**).

### 15.3 Pendências ordenadas

1. **#185** — handback/context_only.
2. **#184** fatias 2–6 — regras de operador, slow path LLM, auto com policy/grant, criação de Task, ingest autenticado.
3. **#2** — Agent Teams.
4. **#172** — reproduzir somente com sinal real.
5. **PR #210** — comparar com `master`; descartar ou reabrir contra `master` conforme o estado real.
6. **M7/#205** — **HOLD** (piloto somente com produto/credenciais).
7. **#11** — medição de cache em execução real.
8. **M6** — já fechado.

### 15.4 Restrições

- Sem merge/deploy.
- Sem alteração de flags ou permissões.
- Sem reconciliar config ativo (`~/.config/opencode`) sem pedido explícito.
- Sem LLM no #192 até teto aprovado.
- Fixtures do #192 ainda **design-only**.

### 15.5 Comandos de retomada

```powershell
git status --short
gh pr view 239 --json state,mergeable,statusCheckRollup
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
```

**Nota:** `.git/config` local foi reconstruído após corrupção por teste; backup em `.git/config.corrupt-20261112-194205`. Remote/identidade/`autocrlf` restaurados; a suíte deve usar `.git` de fixture.

### 15.6 Handoff compacto (5 campos)

- **Objetivo/estado:** continuar backlog residual M0–M7 em `feat/install-ownership-agent-config-20261111` (HEAD `3dbd000`, PR #239 MERGEABLE, CI parcial no handoff); sem merge/deploy.
- **Alterações desde §14:** `c0fdfdc` (M6 docs), `0ac82b8` (#12/#11+#200/#103), `2865de7` (docs), `2ef9aa8` (#183 boundary), `ca2291e` (#64 medição), `2499838` (#50/#141 auditoria), `48ee518` (#192 harness), `3dbd000` (#184 fatia 1). Agent Config `4f0fd88` local sem push.
- **Validação/evidência:** #12 e #200/#103 cobertos (suíte 10/10, E2E DONE rev. 12); #183/#64/#50/#141/#192/#184/#11 parciais com evidências curtas registradas; #172 flake; PR #210 CONFLICTING. CI de PR #239 a reconciliar (4 SUCCESS + 2 IN_PROGRESS no handoff).
- **Decisões/pendências:** #185; #184 fatias 2–6; #2; #172 com sinal real; PR #210 vs `master`; M7/#205 HOLD; #11 cache real; M6 fechado. Sem flags/permissões/config ativo/LLM #192 sem teto/fixtures #192 design-only.
- **Próximo passo:** reconciliar HEAD/PR/CI e iniciar por #185 (handback/context_only), depois #184 fatias 2-6.

## 16. Handoff para a próxima sessão (2026-11-13, segunda rodada)

### 16.1 Estado

- Branch `feat/install-ownership-agent-config-20261111`, HEAD de código `430c8ca`; PR #239 OPEN/MERGEABLE.
- A última rodada COMPLETA verde é `5b58f06` (**6/6**). `8ea738b` estava parcial (**3/6**) quando foi substituída. O HEAD final desta rodada precisa de reconciliação; jobs ps51/ps7/v2 lane levam ~1h.
- Sem merge/deploy; sem alteração de flags/permissões/config ativo.

### 16.2 Entregue nesta rodada (com evidência)

- **#185 fatia 1 (handback/context-only):** `bdab362` (feature) + `547cce8` (hardening pós-review) + `83df402` (docs/teste). Kernel `Set-OrchestrationTaskHandback` e `event-ack -ContextOnly`; CLI `-Action handback`. Evidência: `scripts/v3/lib/OrchestrationTaskHandback.tests.ps1` 24/24, `OrchestrationTaskEvent.tests.ps1` 16/16 (PS 5.1 e pwsh), CLI 0/1/2/3, `package-consistency` 17/17; `evidence/evolution-2026-11-10/m6-handback-185.md`. Reviewer APPROVED; security APPROVED (sem CRITICAL/HIGH/MEDIUM).
- **#184 fatia 2 (regras de operador):** `e2c9ee2` (registry/loader/CLI) + `f65c9b8` e `baa096f` (hardening pós-review). `source/registry/event-admission-rules.json` com regra de exemplo `enabled=false`; `scripts/v3/lib/OrchestrationEventAdmissionRules.ps1`; `-RulesRegistry` no CLI. Evidência: `OrchestrationEventAdmissionRules.tests.ps1` 40 asserts, `OrchestrationEventAdmission*` 2/2 e `OrchestrationEvent*` 5/5 (PS 5.1 e pwsh), `package-consistency` 17/17; `evidence/evolution-2026-11-10/m6-admission-rules-184-f2.md`. Reviewer APPROVED (2 rodadas); security APPROVED com LOW residuais (caminho UNC/device e ancestors reparse agora fail-closed).
- **Testes executados pelo Planner/tester:** tester deu `verified_pass` em ambas as fatias (matriz CLI manual incluída).
- **#183 — verificação de assinatura do ingress (opt-in):** `399241d` + `430c8ca`. `scripts/v3/lib/OrchestrationEventSignature.ps1` (HMAC-SHA256 sobre bytes crus, comparação em tempo constante), CLI `scripts/v3/github-webhook-verify.ps1`, integração opt-in em `scripts/v3/event-intake.ps1` (verifica antes do parse/ledger; sem segredo = legado com `signature_status='not-configured'`; com segredo e header ausente/inválido = falha fechada, ledger intocado). Evidência: `OrchestrationEventSignature.tests.ps1` 31 asserts, intake 18/18, `OrchestrationEvent*` 7/7 em PS 5.1 e pwsh, `package-consistency` 17/17; `evidence/evolution-2026-11-10/m6-ingress-signature-183.md`. Reviewer APPROVED, security APPROVED, tester `verified_pass` (BOM, limites pré-leitura, trim de segredo, não-vazamento). #183 segue PARCIAL (sem receiver real, rotação ou replay).
- **M0 — comparação do PR #210:** `8657a5d`, memo em `evidence/evolution-2026-11-10/m0-pr210-comparison.md`. Recomendação técnica **DISCARD como proposta atual** (conflita com a política vigente Sonnet→Opus→Astra/Planner atual; 6 arquivos changed-in-both), preservando dispatch/RunId como referência caso o produto mude. **Decisão de fechar/reabrir no GitHub é do usuário** — não executada.
- **#184 fatia 3 (slow path seletivo — contrato e gate, sem chamada de modelo):** `b84122e` (feature) + `b6c63ea` (cobertura) + `c095b4b` (contrato canônico/fail-closed) + `c44401d` (redação completa, erros tipados, vetor golden). `source/registry/event-admission-slow-path-policy.json` (`enabled=false`), `scripts/v3/lib/OrchestrationEventAdmissionSlowPath.ps1` (loader, gate, validador de resposta), CLI `scripts/v3/event-admission-slow-path.ps1` (`request|evaluate`). Digest SHA-256 canônico (integridade, **não** autenticidade) com vetor golden cross-engine PS 5.1 ↔ pwsh; redação de credenciais/PEM/JWT com timeout e fallback fail-closed. Evidência: `OrchestrationEventAdmissionSlowPath.tests.ps1` **146 asserts**, `OrchestrationEventAdmission*` 3/3, `OrchestrationEvent*` 6/6 (PS 5.1 e pwsh), `package-consistency` 17/17; `evidence/evolution-2026-11-10/m6-admission-slowpath-184-f3.md`. Reviewer APPROVED (3 rodadas), security APPROVED (3 rodadas), tester `verified_pass` (cross-engine e spot-check de redação). Custo de LLM **não** incorrido; chamada real depende de teto aprovado.

### 16.3 Estados atualizados

- #185 **PARCIAL (fatia 1)**; #184 **PARCIAL (fatias 1-3)**; #183 **PARCIAL (verificação opt-in entregue; falta produtor/receiver real, rotação e replay)**. Nenhuma promoção a COBERTO.
- Pendentes: #184 fatias 4-6 (auto executável com policy/grant, criação de Task, ingest autenticado — exigem decisão de operador); #2; #183 (ponta a ponta com receiver real/rotação/replay); #11 (cache real); #192 (fixtures/teto); #50/#141 (correções/provas); #172 (só com sinal real); PR #210 (decisão do usuário); M7/#205 HOLD.

### 16.4 Decisões desta rodada

- Handback no Kernel guarda apenas sessão, resumo/next_steps limitados e referência opcional de evento; histórico completo de conversa permanece FORA do Kernel.
- `-ContextOnly` no handback exige `-DedupKey` de evento `informational_only`; no ack também. Sessão precisa estar em run `attached`.
- Regras de operador nascem `enabled=false` e apenas `risk=low` é aceito nesta fatia; loader é mais estrito que o classificador; nada executável.
- Slow path entregue como **gate + contrato determinístico** (sem LLM/rede/custo): a chamada real a modelo exige teto aprovado; o digest canônico prova integridade, não origem (HMAC/nonce ficam para a integração externa). Redação falha fechada e pode reduzir contexto (`token:` em prosa), o que é aceito nesta fase shadow.
- `repair-decision` sugeriu REPLAN por "escopo amplo" no hardening do loader; foi tratado como reparo coeso do MESMO módulo (decisão advisory, registrada na evidência).
- Ingress: verificação HMAC é **opt-in e fail-closed**; sem segredo o comportamento legado permanece e o JSON declara `not-configured` (nunca alega autenticação). Enviar header sem segredo marca `signature_header_ignored=true`. Segredo é lido de arquivo/env, nunca ecoado.
- PR #210: recomendação técnica de descarte da proposta funcional atual; nenhuma ação no GitHub foi tomada.
- Residuais conhecidos e aceitos: qualquer sessão `attached` pode sobrescrever o slot `handback` (histórico preserva); identidade de sessão e `informational_only` seguem sem prova criptográfica até o ingest autenticado (#183/#184 fatia 6); checkout sob junction/symlink ou OneDrive-placeholder é rejeitado como `RULES_PATH_INVALID`.

### 16.5 Comandos de retomada

```powershell
git status --short
gh pr view 239 --json state,mergeable,statusCheckRollup
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationTaskHandback*'
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1 -Name 'OrchestrationEventAdmission*'
```

### 16.6 Handoff compacto (5 campos)

- **Objetivo/estado:** continuar backlog M0-M7 na branch `feat/install-ownership-agent-config-20261111` (HEAD de código `430c8ca`; última rodada COMPLETA verde `5b58f06` 6/6; HEAD final a reconciliar); sem merge/deploy.
- **Alterações:** #185 fatia 1 (`bdab362`, `547cce8`, `83df402`); #184 fatia 2 (`e2c9ee2`, `f65c9b8`, `baa096f`) e fatia 3 (`b84122e`, `b6c63ea`, `c095b4b`, `c44401d`); #183 HMAC (`399241d`, `430c8ca`); PR #210 comparação (`8657a5d`).
- **Validação:** handback 24/24 + eventos 16/16; admission 40 asserts + 5/5 suites; slow path 146 asserts; assinatura 31 asserts, intake 18/18, `OrchestrationEvent*` 7/7; package-consistency 17/17; tester `verified_pass`; reviews APPROVED (code+security) nas fatias indicadas.
- **Decisões/pendências:** #184 fatias 4-6, #2, #183 ponta a ponta com receiver real/rotação/replay, #11, #192, #50/#141, #172, decisão do usuário sobre PR #210, M7 HOLD; resíduos aceitos listados em 16.4.
- **Próximo passo:** reconciliar CI do HEAD final; decisão do usuário sobre PR #210; #184 fatias 4-6 mediante autorização; #2 (Agent Teams) como próximo item sem dependência externa.
