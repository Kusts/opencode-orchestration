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

### 8.1 Entrega determinística #200/#103 (2026-11-12)

- Contrato role `reviewer` inclui schema da fonte canônica; demais roles não.
- `retry-decision` persiste resultado da política pura sob lock/CAS; advisory,
  sem dispatch, gate ou mudança de autoridade.
- Harness TEMP cobre LOCAL_REPAIR/REPLAN/ESCALATE, input inválido fail-closed,
  review bloqueante, re-review e DONE pelo verifier-executed existente.
- A prova não inclui chamada de modelo nem valida adesão do Planner em runtime.

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

**M5 wiring entregue em 2026-11-12 (prova determinística sintética; sem LLM):**

- O contrato `reviewer` injeta `REVIEW_FINDINGS_SCHEMA` da fonte canônica;
  outros roles não recebem o campo. `review-schema` segue read-only. #200
  coberto em contrato determinístico; consumo do schema pelo LLM não provado.
- `task-kernel -Action retry-decision` consulta a política canônica sob lock e
  persiste decisão advisory com sinais e motivo. Não despacha nem adiciona gate.
  #103 coberto no ponto de decisão; execução de reparo pelo Planner/LLM não provada.
- Harness TEMP: cadeia Kernel até review `changes_required`, retry LOCAL_REPAIR,
  re-review aprovada e DONE pelo verifier-executed existente; negativos REPLAN
  e argumentos inválidos. Nenhum `pass-real` alegado.
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
documentada, integração automática externa pendente.

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
- **M5 (snapshot anterior, 2026-11-11):** #200/#103 ainda descritos como
  PARCIAL; ver a entrega determinística de 2026-11-12 em §8.1 para o estado
  atualizado. A prova LLM/runtime real permanece fora do E2E sintético.
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

## 14. Handoff para a próxima sessão (2026-11-12)

### 14.1 Estado atual (reconciliar antes de agir)

- **Worktree/branch/HEAD:** `D:\projetos\opencode-orchestration-wt-evidence`, branch `feat/kernel-evidence-store-20261111`; base atual `d59c59d` (contrato #183) + commit local deste fix. Commits anteriores de código: `3909600` (wiring #200/#103 + E2E), `cbae9d7` (confinement), `de0d26c` (schema cap ladder + fail-closed), `589cce4` (write-refusal tests).
- **Publicado:** branch `feat/kernel-evidence-store-20261111` publicada em `origin`; PR #240 aberto contra `master` (não-draft, MERGEABLE). Nada foi mergeado ou deployado. O CI do PR tem 6 jobs: `linux capability collector`, `smoke opencode real` e `smoke opencode v2 real` passaram; `ps51`, `ps7` e `v2 lane` estavam pending no momento deste registro. Resultado final do CI não afirmado.
- **Checkout principal (outro fluxo, não tocar):** branch `feat/install-ownership-agent-config-20261111` avança em outro fluxo (HEAD `4f1aa65` no momento desta rodada); checkout limpo.
- **Entrega #12/#11:** `-EvidenceStoreDir` opt-in (vazio = legado byte-idêntico) + `-VirtualizeThresholdBytes`; conteúdo redigido persistido content-addressed; `evidence_artifacts` com `sha256`/`bytes`/`kind`/`preview<=2000`/`field=failure_detail`/`store_rel`; fail-closed `EVIDENCE_REDACTION_UNAVAILABLE`; escrita dentro do lock; confinamento de store + reparse point; ação CLI `get-evidence` com recall verificado; `verified_pass`/`DONE` intocados.
- **Decisão:** ADOTAR (opt-in) com medição `evidence/evolution-2026-11-10/evidence-store-integration/measurement.json`: detalhe 200.013 B; record 4.633/6.880 B; artifact 200.013 B; preview 2.000 B; recall 815 ms; hash e byte-idêntico `true`; tokens (estimativa `chars/4`) 50.004.
- **Validação #12/#11 (commit `8b9a22e`):** kernel 125/125 e CLI 20/20 em pwsh e PS 5.1; virtualização 18/18; runner V3 173 PASS / 0 FAIL / 10 SKIP (183, exit 0); `package-consistency` 17/17; `git diff --check` limpo; DONE compliance COMPLIANT.
- **Validação #200/#103:** reviewer rodada 2 APPROVED; security APPROVED. PS 5.1 pós-reparo: DispatchPipeline 206, retry-decision-e2e 9, TaskKernel 126, ReviewAnchor 29, ReviewIntegration 17, LocalizedRepair 13, repair-decision 10; package-consistency 17/17. Em pwsh, conjunto equivalente verde antes do reparo (204/6/125/29/17/13/10); reexecução pós-reparo não observada nesta rodada. Runner amplo NÃO verde: 172 PASS / 1 FAIL / 10 SKIP / 1 INTERNAL_ERROR / 184. Falhas ambientais sem overlap: `OrchestrationCapabilityDoctor` (“doctor does not mutate filesystem state”; assert compara listing de `$env:TEMP` linhas 9 e 35-36, sensível a atividade externa; 46 asserts em 3/3 execuções isoladas) e `OrchestrationRuntimeWatchdogEnforcement` (log ilegível/ausente, condição de captura do runner; 459 asserts em 2/2 execuções isoladas).
- **Revisões:** reviewer rodada 2 APPROVED; security APPROVED.
- **Evidências:** `evidence/evolution-2026-11-10/evidence-store-integration/` (inclui `measurement.json`), além de `evidence/evolution-2026-11-10/` e `evidence/evolution-2026-11-10/p0-autonomy/`.
- **Ressalva honesta:** #11 marcada COBERTA no escopo medido; "prefixo estável/cache antes-depois" continua dependente de métricas do provedor.

### 14.2 Ordem recomendada

1. **CONCLUÍDO (2026-11-12) — #200/#103 — E2E com fluxo real.** Contrato reviewer/schema, decisão advisory persistida, bloqueio por changes_required, re-review e DONE validado em harness TEMP; o consumo do schema e a execução da correção pelo Planner/LLM real ainda exigem prova runtime e não são declarados COBERTOS.
2. **#183 — contrato do produtor codificado e testado; PARCIAL.** Commits `d59c59d` + este fix cobrem envelope, validação/replay e documentação de consumo; produtor externo não existe e `delivery_id` real não pode ser fabricado. Próximo passo é decisão de operador: construir produtor externo (webhook/Action) ou seguir para #64/#192.
3. **#64 PARCIAL, #192 PARCIAL, #50 COBERTA (com residual), #141 COBERTA, #2/#184/#185, #172.** #50: 3 literais distintos, 62 path:line deduplicados: 25 registros de registry (10 `SOURCE_OF_TRUTH` + 15 outros), 26 fixtures, 9 comentários/docs e 2 revisados como `PRODUCT_CODE`; comparadores 0. O gate `OrchestrationModelRouter.ps1:2661` tem allowlist hardcoded de runtime; proposta de conjunto suportado explícito ou probe fail-closed ainda não executada. #141 usa JSON e parser de frontmatter estruturados, encontra 0 tokens em superfícies distintas; Agent Config não declara permissões estruturadas. R4 mapeia `enforced_by` por token; `hard` somente com guard+teste, demais advisory/documented-only. Nenhuma permissão alterada; remoção não aplicável. Correção: números R1/R2 (126/108/536/4) vinham de scanners regex/prosa imprecisos e foram substituídos por este método estruturado.
4. **PR #210.** Aceite: comparar com a master; descartar ou reabrir contra a master; não integrar configuração anterior ao merge #236.
5. **M7/#205.** Aceite: piloto somente com produto/credenciais; sem acesso/produto, manter HOLD com resultado registrado.
6. **Reconciliação do config ativo.** Aceite: somente após pedido explícito de install/reconcile, usando `scripts/reconcile-opencode-config.ps1` com backup.

### 14.3 Restrições que continuam valendo

Residuais LOW aceitos: `repair_decision` last-write-wins sem histórico; caller da biblioteca sem bound de `ChangedFiles`; E2E usa o store default real com cleanup em `finally` (crash pode deixar resíduo); comportamento mediado por LLM/provider fora da prova.

- Sem novo controlador, scheduler, banco ou framework.
- Sem alterar flags, permissões, allowlist, credenciais ou produção.
- Sem merge/deploy sem autorização explícita.
- Preservar evidências; não refazer etapas já provadas.
- Worker executa implementação/teste; Planner decide e delega; Kernel verifica.

### 14.4 Comandos de retomada

```powershell
cd D:\projetos\opencode-orchestration-wt-evidence
git log --oneline -3
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
powershell -NoProfile -File scripts\test-package-consistency.ps1
```

Nota: push/PR desta branch exige pedido explícito; não assumir CI verde nem realizar merge/deploy.

### 14.5 Handoff compacto (5 campos)

- **Objetivo/estado:** base `1559483` + commit de handoff `289e960`; o backlog avançou em quatro fatias: #200/#103 entregue, revisado e com E2E determinístico; #183 PARCIAL (contrato codificado/testado, produtor externo ausente); #64 PARCIAL (medição local de descoberta de skills); #192 PARCIAL (comparação pré-execução, Cascade/Critique NOT_IMPLEMENTED); #50/#141 COBERTAS com residuais. PR #240 aberto contra `master`.
- **Alterações:** `retry-decision` + schema no contrato `reviewer`; `GITHUB-EVENT-PRODUCER-CONTRACT.md` + casos de contrato; `measure-skills-discovery-cost.ps1` + evidência; `compare-execution-strategies.ps1` + evidência; `audit-pinned-versions.ps1`/`audit-authority-surfaces.ps1` + evidências. Nenhuma permissão/flag/credencial alterada.
- **Validação:** suítes focadas PS 5.1 pós-reparo 206/9/126/29/17/13/10 e package-consistency 17/17; pwsh pré-reparo 204/6/125/29/17/13/10 (pós-reparo não observado). Runner amplo NÃO verde: 172 PASS / 1 FAIL / 10 SKIP / 1 INTERNAL_ERROR / 184; as duas falhas ambientais — CapabilityDoctor (listing de `$env:TEMP` sensível a atividade externa) e RuntimeWatchdogEnforcement (log ilegível/ausente) — estão caracterizadas no CHANGELOG.
- **Decisões/pendências:** LOWs aceitos conforme registro. #50 mantém allowlist `OrchestrationModelRouter.ps1:2661` sem substituição; #141 não encontrou duplicação real; #183 aguarda produtor externo; #192 só poderá medir desempenho após implementar Cascade/Critique e executar cenários. PR #210 e M7/#205 permanecem HOLD. Branch publicada; PR #240 aberto contra `master`, não-draft e MERGEABLE; nada mergeado nem deployado. CI do HEAD final estava em andamento no encerramento; resultado ainda não observado. Retomada nesta worktree `D:\projetos\opencode-orchestration-wt-evidence`, branch `feat/kernel-evidence-store-20261111`; o checkout principal `D:\projetos\opencode-orchestration` pertence a outro fluxo e não deve ser tocado.
- **Próximo passo:** #2/#184/#185; depois #172, PR #210 e M7/#205 (HOLD).
