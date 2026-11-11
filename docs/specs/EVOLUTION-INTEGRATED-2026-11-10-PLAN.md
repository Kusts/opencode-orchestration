# EVOLUTION INTEGRATED — PLAN (2026-11-10)

**Versão:** 1.1
**Data-base:** 2026-11-10 (revisão 2026-11-11)
**Baseline de commit:** `beb0ea4` (branch `feat/evolution-integrated-20261110`)
**SPEC:** [EVOLUTION-INTEGRATED-2026-11-10-SPEC.md](EVOLUTION-INTEGRATED-2026-11-10-SPEC.md)
**Status:** ACTIVE — P0 (reformulação do Planner) é a prioridade atual; M0–M7
preservados e retomados depois da fatia P0.

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
| DONE correto | M5 `m5-done-proof6` (kernel-executed) | medir nas Tasks P0 |
| Intervenções humanas por missão | 1 por checkpoint (pausa 2026-11-11) | 0 em subtarefas cobertas |
| Tempo até DONE | não medido de forma comparável | registrar início/fim por Task |
| Tokens/custo por DONE | `model_attempts` e cache metrics existentes | registrar por Task |
| Retrabalho / retomadas | E2E M5 (2 findings, 1 rodada) | registrar replans e retomadas |

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

**Achado M6 (2026-11-11):** o tick do GH-WAKE produz `github-wake-v1` +
`next_action` (CI/wait), não o envelope `source/trigger/thread/delivery_id`
consumido pelo bridge. Ligar o tick ao bridge exige um contrato de derivação
ou um produtor webhook/Action; não foi implementado por hipótese. #183 segue
PARCIAL com essa perna registrada.
- P0.2/P0.3: instruções canônicas (global, adapter V2, `AGENTS.md` do
  checkout), `docs/ARCHITECTURE.md` e o mandato V2 injetado pelo plugin
  (`plugins/orchestration-enforcement/shared/mandate.ts`, bundle regenerado)
  alinhadas ao contrato de papéis, à rota
  por mutação e ao contrato Goal/Loop.

**Pendente em P0:** P0.4/P0.5 com uma missão contínua de 3 Tasks em modelo vivo
(a perna determinística está provada; o transporte multi-turn exige sessão
interativa e não foi executado — ver
`evidence/evolution-2026-11-10/p0-planner-roles.md` §4) e P0.6 com tempo/tokens
medidos. Evidência da fatia em `p0-planner-roles.md`.

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

**Pendências para retomar:**

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
