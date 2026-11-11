# EVOLUTION INTEGRATED — PLAN (2026-11-10)

**Versão:** 1.0
**Data-base:** 2026-11-10
**Baseline de commit:** `54a9d3c`
**SPEC:** [EVOLUTION-INTEGRATED-2026-11-10-SPEC.md](EVOLUTION-INTEGRATED-2026-11-10-SPEC.md)
**Status:** ACTIVE — execução incremental por marco

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

## 13. Estado desta execução (2026-11-10)

**Entregue nesta rodada:**

- SPEC e PLAN canônicos deste programa;
- decisão explícita da cadeia Sonnet → Opus → Astra no adapter V2;
- `scripts/v3/lib/OrchestrationModelChain.ps1` (leitura pura da política e
  verificação política ↔ adapter);
- `scripts/v3/lib/OrchestrationModelChain.tests.ps1` (15 asserts, incluindo
  drift de T3, excepcional, adapter sem cadeia e adapter T3→Sol);
- check 17 em `scripts/test-package-consistency.ps1` (17/17 PASS);
- revalidação da #21: as 6 suítes citadas passaram (53/13/44/9/22/39 asserts;
  2 SKIP ambientais de pin em `profile-isolation`), com evidência em
  `evidence/evolution-2026-11-10/m0-issue21-revalidation.md`;
- prova M1 em runtime real (2026-11-10): Task `evo-m1-proof-20261110` executou
  `model-select → dispatch T3 sonnet → model-attempt → model-proof` sem
  comando humano intermediário; `model-proof` T3/T4 falharam fechado sem prova
  de falha; reviewer T3 retornou `CHANGES_REQUIRED` e os 3 achados foram
  corrigidos com 32 asserts (evidência em
  `evidence/evolution-2026-11-10/m1-planner-chain-runtime.md`);
- M2 (#237/#48) entregue parcialmente: 8 skills-core (BMAD, Pocock e Addy
  como texto original pinado) e tabela de seleção em `hybrid-development`;
  `fresh-install` 53/0, `idempotency` 17/0, `rollback` 33/0 e consistência
  17/17. Evidência em `evidence/evolution-2026-11-10/m2-methodologies-distribution.md`.
  #48 segue PARCIAL (sem roteamento adaptativo por Objective/Goal) e #64
  segue aberto (sem medição de custo de contexto). Falha ambiental registrada:
  `skills-healthcheck` acusa drift user-owned em `hybrid-development`.
- M3 (probes): OpenCode 2.2.6 anuncia `persistentPty=true` mas não prova
  lifecycle; `opencode worktree` não expõe superfície CLI; remoto não foi
  probado neste repo. #143 segue coberto; #139/#140/#203 permanecem HOLD/SPIKE
  e nenhum componente foi removido. Evidência em
  `evidence/evolution-2026-11-10/m3-runtime-probes.md`.
- M4 (#12/#11): virtualização content-addressed com recall verificado
  (18/18) e parser de métricas de cache sem zero inventado (18/18); wiring no
  EvidenceStore/Kernel pendente.
- M5 (#200/#103): finding ancorado em arquivo/linha/commit com drift e owner
  (18/18), decisão local/replan/escalate (13/13) e integração no registro de
  review do Kernel (14/14; findings validados/persistidos, `approved` com
  findings recusado). Suítes do Kernel verdes (114/114, 34/0, 169/169, 8/0).
  Prompt do reviewer e E2E vivo ainda pendentes. Evidência em
  `evidence/evolution-2026-11-10/m5-review-kernel-integration.md`.
- M6 (#183/#185, primeira fatia): envelope + dedup + roteamento
  `ATTACH/OBSERVE/NEW_TASK/IGNORE/ESCALATE` (11/11); transporte GH-WAKE,
  admissão versionada (#184) e ownership de follow-up (#185) pendentes.
  Evidência em `evidence/evolution-2026-11-10/m6-event-correlation.md`.
- M4 (#177/#77): gateway verificado, lição Markdown, receita determinística e
  decisão de reuso (20/20); round-trip real no AI Memory MCP (write→read→delete).
  Uso em segunda sessão e segunda execução da receita pendentes. Evidência em
  `evidence/evolution-2026-11-10/m4-learning-recipes.md`.
- M6 (#183/#185): intake CLI com dedup durável (8/8), entrega real em Task
  com `event_inbox` idempotente (12/12) e comentário real do GitHub (`issue:6`)
  entregue uma única vez. Wiring GH-WAKE e follow-up ao worker pendentes.
  Evidência em `evidence/evolution-2026-11-10/m6-event-correlation.md`.
- README e CHANGELOG atualizados.

**Não entregue / não alegado:**

- automação do encadeamento M1 em um único comando (decisão explícita
  pendente; o Planner executou o fluxo comportamental);
- fechamento de #61/#143/#21/#208/#237 (exige revisão do maintainer);
- M3 funcional (#139/#140/#203), M6 completo (transporte/admissão/follow-up)
  e M7 (T3 Code, HOLD por depender de produto externo e projeto descartável);
- wiring de #12/#11/#200/#103 no Kernel/Planner; #48 completo; #64; #177/#77;
- #192 (comparação de estratégias) e #205 (piloto T3 Code);
- dispatch T4/Astra, qualquer alteração de flag, permissão, credencial ou
  produção.

**Próximo incremento recomendado:** provar #139 (PTY lifecycle) e #140
(paridade de worktree) em runtime; depois ligar #200/#103 ao fluxo de review e
retry sem criar novo controlador. M7 só inicia com acesso ao T3 Code e um
projeto descartável.
