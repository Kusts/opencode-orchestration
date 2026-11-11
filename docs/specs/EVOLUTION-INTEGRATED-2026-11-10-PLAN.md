# EVOLUTION INTEGRATED — PLAN (2026-11-10)

**Versão:** 1.0
**Data-base:** 2026-11-10
**Baseline de commit:** `8c9befb` (branch `feat/evolution-integrated-20261110`)
**SPEC:** [EVOLUTION-INTEGRATED-2026-11-10-SPEC.md](EVOLUTION-INTEGRATED-2026-11-10-SPEC.md)
**Status:** PAUSED — implementação interrompida a pedido do usuário em 2026-11-11; estado, evidências e PR preservados

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

## 13. Estado desta execução — pausa de 2026-11-11

**Status:** PAUSED. Implementação interrompida a pedido do usuário; nenhum
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
