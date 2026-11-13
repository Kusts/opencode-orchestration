# EVOLUTION INTEGRATED — SPEC (2026-11-10)

**Versão:** 1.1
**Data-base:** 2026-11-10 (revisão 2026-11-11)
**Baseline de commit:** `beb0ea4` (branch `feat/evolution-integrated-20261110`)
**Repositório:** `Kusts/opencode-orchestration`
**Status:** PAUSED — missão encerrada pelo orientador em 2026-11-11; a
implementação do backlog residual continua na próxima sessão (handoff no PLAN §14)
**Escopo:** 25 issues + PR #210, organizados em 8 marcos (M0–M7) + P0 transversal
**Runtime-alvo:** OpenCode V2 (V1 permanece `LEGACY_FROZEN`, issue #62)

---

## 1. Objetivo

Evoluir a orquestração existente — sem reconstruí-la — para um sistema que:

1. execute missões completas com o mínimo de intervenção humana;
2. escolha modelo, metodologia e agente conforme a tarefa;
3. reaproveite conhecimento, sessões e procedimentos anteriores;
4. corrija problemas localmente antes de reiniciar trabalho;
5. use capacidades nativas do OpenCode sempre que comprovadamente equivalentes;
6. reduza chamadas de modelo, consumo de contexto e manutenção.

O ativo existente (Planner único, 19 workers, Task/Goal Kernel, preflight,
NativeDispatch, watchdog, GH-WAKE, AI Memory, instalador) é a base. Nenhum
componente é substituído sem paridade comportamental comprovada.

## 2. Não-objetivos

Ficam conscientemente fora desta SPEC:

- Swarm, Arena, Control Center próprio, Thompson Sampling, APSC e RSI;
- reestruturação ampla VNext;
- V4, daemon, banco de dados ou um segundo Planner;
- reativação de desenvolvimento da V1;
- fechamento de issues por idade, ADR ou ausência de atividade;
- alegar prova runtime-real a partir de teste isolado, mock ou harness.

## 3. Princípios

- **Native-first:** o OpenCode V2 é dono de execução, sessões, PTY, worktrees,
  tools e capacidades mediadas pelo host. A Orquestração é dona de
  planejamento, decomposição, Kernel, ownership/leases, evidências e DONE.
- **Reuse-first:** inspecionar código, contratos, evidências e AI Memory antes
  de criar qualquer coisa.
- **Autoridade única:** Agent Config para perfis/permissões declarativas;
  OpenCode V2 para execução; Orquestração para coordenação e estado; AI Memory
  como conhecimento, nunca estado; GitHub como fonte de PR/CI/checks.
- **Prova antes de claim:** worker retorna `candidate_pass` | `failed` |
  `blocked`; `verified_pass` é do verificador allowlisted; `DONE` é do Kernel.
- **Menor incremento funcional:** cada marco entrega algo observável antes do
  próximo. Atividades independentes podem correr em paralelo quando houver
  ganho real.
- **Sem novo controlador por hipótese:** antes de criar qualquer driver,
  provar que o Planner consegue executar o encadeamento com as primitivas
  existentes.

## 3.1 P0 — Contrato de papéis e autonomia por missão (transversal)

Diretriz vigente (#48, 2026-11-10). P0 corrige o contrato de papéis antes de
retomar M2–M7; não substitui marcos nem cria componente novo.

**Papéis.** O Planner é o cérebro da missão: decide, decompõe, delega,
acompanha, replaneja e encerra. Ele **não** edita arquivos, implementa ou roda
teste de implementação. Workers executam no escopo delegado; o Task Kernel
mantém estado, verificação, evidência e `DONE`.

**Roteamento por mutação.** Leitura/análise/planejamento sem mutação pode usar
`DIRECT_VERIFIED` (zero workers), com evidência de consulta no objetivo.
`ReadWrite` deve refletir a intenção real: objetivo com vocabulário de edição e
metadado `read` é tratado como mutação e delegado. Qualquer escrita de arquivo
usa `SINGLE_WORKER` com um worker apropriado e teste focado; o gate trivial
exige participação observada > 0 e rejeita zero-worker como
`ORCHESTRATION_POLICY_BYPASS`. Não há estado, flag ou parâmetro novo: o
classificador passa a usar o ramo `SINGLE_WORKER` já existente.

**Goal e Loop.** Goal é missão persistente multifase, usado quando houver mais
de uma Task. Loop é a política de próxima ação sobre o estado existente
(`Get-OrchestrationGoalNextMove`), nunca daemon, scheduler ou segundo
controlador. Retomada usa NativeResume/GH-WAKE/resume-reconcile existentes.
Task DONE não conclui Goal; Goal conclui por CAS do GoalKernel após todas as
Tasks exigidas verificadas.

**Autonomia.** Uma autorização por missão cobre criar Tasks, branches, commits,
PRs autorizados, reordenar plano, trocar estratégia/modelo/worker, refazer
trabalho falho e retomar. Intervenção humana é excepcional: escopo/produto
material, gasto não autorizado, produção/destruição irreversível,
segredos/dados pessoais ou autorização ausente.

**Advisor/JEV.** Consultoria opcional, read-only, no máximo uma por decisão;
nunca gate, nunca autoridade, indisponibilidade não bloqueia trabalho
reversível.

**Aceite P0.** (a) microedição executada por worker, não pelo Planner;
(b) escrita com participação zero rejeitada pelo DONE gate; (c) Goal com ≥ 3
Tasks, falha real, replan e retomada até DONE do Goal sem intervenção humana;
(d) instruções, adapter, arquitetura e classificador descrevem a mesma regra;
(e) baseline antes/depois registrado ou `UNKNOWN` explícito.

## 4. Decisão de escalonamento de modelos (issue #208)

O texto histórico da issue #208 cita `T3→Sol→Astra`. A política vigente
(`source/registry/model-routing-policy.json`, v1.4.0) e o adapter V2 definem:

| Etapa | Modelo | Papel |
|---|---|---|
| T3 | `claude-agent/sonnet` | primário de capacidade |
| T4 | `claude-agent/opus` | primário de raciocínio profundo, após prova T3 |
| Excepcional | `openai/gpt-6-astra` | somente após prova T4 válida da mesma tarefa |
| Mesmo tier T4 | `openai/gpt-6.1-sol` | candidato alternativo, **não** degrau T3→Astra |
| HOLD | `claude-agent/fable` | exige prova específica de falha do Astra |

**Decisão:** a cadeia canônica é `Sonnet → Opus → Astra`. Sol é candidato de
mesmo tier T4. A divergência textual da issue é histórica e não altera a
política. A consistência entre política e adapter é verificada por
`scripts/test-package-consistency.ps1` (check 17), com testes em
`scripts/v3/lib/OrchestrationModelChain.tests.ps1`.

Mudar o baseline exige alterar política, adapter e contrato de verificação na
mesma decisão explícita; nunca por edição isolada.

## 5. Marcos

**P0 (transversal, prioridade atual)** — definido em §3.1; antecede a retomada
de M2–M7 e não altera os marcos abaixo.

| Marco | Issues | Entrega principal | Prioridade |
|---|---|---|---|
| M0 — Reconciliar pendências | #61, #21, #172 + PR #210 | Backlog reconciliado com evidência; zero duplicação | Alta, rápida |
| M1 — Núcleo de execução autônoma | #208, #50, #141 | Cadeia model-select → dispatch → attempt → proof → decisão sem comando manual entre etapas | Crítica |
| M2 — Planejamento inteligente | #237, #48, #64 | Quatro metodologias instaladas e selecionadas por tarefa | Muito alta |
| M3 — Reutilização nativa | #139, #140, #143, #203 | PTY, worktrees, sessões e remoto usando capacidades existentes | Alta |
| M4 — Memória e eficiência | #12, #11, #177, #77 | Evidência fora do contexto, cache medido, lições e receitas | Muito alta |
| M5 — Qualidade e recuperação | #200, #103, #192 | Feedback ancorado, reparo local e comparação de estratégias | Alta |
| M6 — Autonomia prolongada | #2, #183, #184, #185 | Múltiplas sessões, eventos e follow-ups sob o mesmo objetivo | Muito alta, maior esforço |
| M7 — Acesso remoto | #205 | Piloto T3 Code como console web/mobile | Oportunidade rápida |

## 6. Estado reconciliado por issue

Legenda: **COBERTO** = evidência existente, revisão de fechamento pendente;
**PARCIAL** = parte entregue, critério de aceite não comprovado; **ABERTO** =
sem implementação; **SPIKE** = avaliação/piloto.

| Issue | Marco | Estado | Evidência / observação | Próxima ação |
|---|---|---|---|---|
| #61 | M0 | COBERTO | `evidence/v3.1/runtime-reliability/i61-jev-native-proof-2026-10-12.json`; `jev_advisory` ON | Revisar evidência, comentar e fechar |
| #21 | M0 | COBERTO | 2026-11-10: as 6 suítes citadas passam (53/13/44/9/22/39 asserts; `profile-isolation` cenário d = SKIP ambiental de pin 2.2.6); suítes fixam `runtime=V1` explícito | Revisar evidência e fechar |
| #172 | M0 | ABERTO | flake de ambiente conhecido (`path-unverifiable`, scenario-15, FIX4-1) | Só corrigir se reproduzir; registrar limitação |
| PR #210 | M0 | NÃO MERGEAR COMO ESTÁ | `CONFLICTING`, base `feat/model-router-tier-policy-v14-20261103`, anterior ao estado atual | Comparar com master; descartar ou reabrir contra master |
| #208 | M1 | PARCIAL (encadeamento provado) | 2026-11-10: Task `evo-m1-proof-20261110` percorreu `model-select → dispatch T3 sonnet → attempt → proof` sem comando humano; T3/T4 proof fail-closed; falta automação single-command | Revisão do maintainer e decisão sobre automação |
| #50 | M1 | PARCIAL | Auditoria 2026-11-12: pin vivo em `runtime-versions.json` + loader fail-closed; smokes V2 exigem patch exato (falso negativo em bump compatível) vs V1 por família; descoberta read-only parcial (`cli_core` operacional, 8 features V2-native `hold-unproven`, doctor sintético). [AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md](AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md) | Manter lane pinada + trilha de compatibilidade por família/contrato (probes read-only, sem promoção automática); `exact-binary-live` para features de autoridade |
| #141 | M1 | PARCIAL | Auditoria 2026-11-12: mapa de ownership por superfície; HIGH-1 grants sem enforcement de runtime (`runtime_grant_enforcement` OFF), HIGH-2 precedência topo vs agente não provada, HIGH-3 `/api/session/{id}/shell` sem tool permission (2.0.23); ressalvas documentadas em PERMISSIONS/SECURITY. [AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md](AUTHORITY-AND-CAPABILITY-AUDIT-2026-11-12.md) | Prova de runtime (precedência/`/shell`) e decisão de operador (grants deny nos perfis, `external_directory`, pin de `npx`); sem promover a COBERTO |
| #237 | M2 | COBERTO | 8 skills-core instaladas (5 + BMAD/Pocock/Addy); `fresh-install` 53/0 e `idempotency` 17/0 | Revisar evidência e fechar |
| #48 | M2 | PARCIAL | tabela de seleção por forma da tarefa em `hybrid-development`; sem roteamento adaptativo por Objective/Goal | Evoluir seleção no Kernel |
| #64 | M2 | PARCIAL | Skill discovery existe no core; `skill_routing` off no registry; medição reproduzível de custo executada (2026-11-12, `scripts/v3/skill-discovery-metrics.ps1`: 133 skills válidas, 1 inválida, 109 junctions; metadados 10.174/9.720 tokens ocorrência/únicos, razão corpo/metadados 21,90, seleção lexical top-5 ~348 tokens, `selection_ratio_vs_unique` 0,0358; 8 duplicatas com drift de conteúdo em `hybrid-development`; latência p50 ~196 ms/p95 ~296 ms; determinismo exceto `timing`). Sem seleção seletiva executada nem F1 shadow. | F1 (protótipo shadow, índice local + leitura exata verificada), relevância/recall, falsa seleção, custo-até-DONE e continuidade de cache com Golden Workflows; sem promoção a COBERTO. |
| #139 | M3 | COBERTO | PTY create/list `exited exitCode=0` e shell longo `status=exited` + output `shell-ok` via API 2.2.6 | Revisar evidência e fechar |
| #140 | M3 | COBERTO | `GET /api/worktree?projectID=…` retorna 42 worktrees com `strategy=git`; create/remove não exercitados | Provar criação/remoção |
| #143 | M3 | COBERTO | contrato nativo provado em 2026-11-07 (CHANGELOG); comparador morto removido | Revisar evidência e fechar |
| #203 | M3 | COBERTO (read-only) | perfis remotos/MCP existem fora do pacote; integração no projeto não provada | Teste Planner local → Linux/Docker VPS |
| #12 | M4 | COBERTO | Virtualização de detalhe no `worker_result` do Task Kernel (`Set-OrchestrationTaskWorkerResult`: `-DetailContent`/`-DetailPath`/`-DetailKind`/`-EvidenceStoreDir`/`-DetailPreviewChars`), persistindo `worker_result.detail` aditivo com `preview` (<=2000 chars), `truncated`, `total_chars` e `artifact_ref` content-addressed (SHA-256, com `sha256/path/bytes/kind/created`), com recall por hash; sem tocar DONE/`verified_pass`/settlement/freshness. Evidência: suíte `scripts/v3/lib/OrchestrationTaskKernelEvidenceVirtualization.tests.ps1` 10/10 (PS7/PS5.1), runner `-Name OrchestrationTaskKernel` 5/5 e medição 1.939→4.372 B (artefato 120.003 B) | Revisar evidência e fechar |
| #11 | M4 | PARCIAL | parser de métricas de cache (18/18), sem zero inventado; prefixo estável/medição antes-depois pendentes | Medir cache em execução real |
| #177 | M4 | COBERTO | gateway DONE+kernel-verified, lição Markdown, round-trip real no AI Memory MCP e recall/uso em segunda sessão (20/20) | Revisar evidência e fechar |
| #77 | M4 | COBERTO | receita determinística + decisão de reuso (20/20) + comparação real: 1 chamada de modelo na execução original, 0 no replay duplo | Revisar evidência e fechar |
| #200 | M5 | COBERTO | âncora/drift/owner (24/24), persistência no Kernel (17/17) e E2E vivo coder→reviewer→coder concluído (2026-11-12); schema versionado exposto por `task-kernel -Action review-schema` e incluído no contrato de dispatch do reviewer via mandato V2; findings ancorados persistidos no registro de review; testes `OrchestrationReviewRepairLoop` 17/17 (PS7/PS5.1), `OrchestrationReviewAnchor` 29/29, `OrchestrationReviewIntegration` 17/17, `OrchestrationLocalizedRepair` 13/13, `repair-decision` 10/10, runner `OrchestrationTaskKernel` 5/5. Sem relaxamento de gates nem mudança em `verified_pass`/DONE | Revisar evidência e fechar |
| #103 | M5 | COBERTO | decisão local/replan/escalate (13/13) persistida de forma advisory em `repair_decisions` via `task-kernel -Action record-repair-decision` (CLI com `-TaskId -ExpectedRevision -RepairDecisionJson -RecordedBy`; lock+CAS, recusa terminal, erros tipados, validação de contexto; bound 20; não consumida por DONE); usada no E2E vivo (2026-11-12) na mesma Task; `scripts/v3/repair-decision.ps1` segue expondo a decisão determinística no retry. Sem mudança em `verified_pass`/DONE | Revisar evidência e fechar |
| #192 | M5 | ABERTO | nenhuma medição Single/Cascade/Critique | Comparar em cenários representativos |
| #2 | M6 | ABERTO | Agent Teams não implementado; sessões nativas provadas (#143) | Depende de #143/#183 |
| #183 | M6 | PARCIAL — decisão (b) 2026-11-11 | intake (8/8), entrega+ack idempotentes (12/12), bridge GH-WAKE→Kernel (9/9) e E2E real `issue:6` → worker → ack. Decisão: GH-WAKE permanece retomada/readiness; o envelope de evento pertence ao event-intake/bridge e seu produtor real (webhook/Action) é externo. Sem fabricar `delivery_id` nem novo controlador. Fronteira documentada em `docs/specs/GITHUB-EVENT-ENVELOPE-BOUNDARY-2026-11-12.md`. Risco material: ingress não autenticado (sem verificação `X-Hub-Signature-256`/HMAC-SHA256) — intake/bridge/kernel aceitam envelope bem-formado sem prova criptográfica de origem | Integração automática externa autenticada/persistente segue PARTIAL (ver critérios no doc); não promover |
| #184 | M6 | PARCIAL | admissão desligada por padrão; eventos sem dono viram `OBSERVE`; `NEW_TASK` só com flag explícita | Regras observe→auto |
| #185 | M6 | PARCIAL | ack de consumo/settlement com sessão e resumo; histórico completo de conversa fora do Kernel | Handback completo |
| #205 | M7 | HOLD | T3 Code não avaliado; piloto exige produto/credenciais e projeto descartável | Executar piloto read-only → ação controlada |

Atualização 2026-11-11: #140 provado com `POST/GET/DELETE /api/worktree`
(worktree descartável criado, usado e removido; nenhum existente tocado);
#203 provado em leitura com `ssh contabo-prod "uname -a; docker ps"` (Linux +
5 containers, sem mutação); #12/#11 ganharam CLIs no fluxo
(`evidence-virtualize.ps1` 7/7 com 109.209→2.000 bytes; `cache-metrics.ps1`
com amostras reais 47.313/512 e 108/47.744, custo `UNKNOWN`). Evidência:
`evidence/evolution-2026-11-10/m3-runtime-probes-closure.md` e
`p0-autonomy/session-resume/`.

## 7. Critérios de aceite por marco

**P0.** Leitura/planejamento sem mutação é a única rota `DIRECT_VERIFIED`
(zero workers). Qualquer escrita de arquivo passa por `SINGLE_WORKER` com
participação observada; o gate trivial rejeita zero worker. Goal/Loop usam os
mecanismos existentes e Task DONE não conclui Goal. Instruções canônicas,
adapter, arquitetura e classificador dizem a mesma regra. Prova runtime-real de
microedição/bug por worker e de Goal ≥ 3 Tasks com falha/replan/retomada, ou
`BLOCKED` com a perna exata.

**M0.** Backlog reconciliado; nenhuma evidência perdida; nenhuma
implementação duplicada; PR #210 comparado com a política atual.

**M1.** Uma Task real percorre `model-select → dispatch → attempt → proof →
decisão` sem comandos manuais entre etapas; sucesso T3 não escala; ausência de
prova não autoriza execução adicional; fallback válido usa o mecanismo
existente. Cadeia canônica Sonnet → Opus → Astra preservada.

**M2.** Instalação V2 isolada disponibiliza técnicas das quatro origens; uma
microcorreção usa Direct; uma feature multifase seleciona técnica BMAD quando
pertinente; uma revisão complexa usa técnica Addy. JEV permanece opcional.

**M3.** Comando longo sobrevive e devolve resultado; dois trabalhos isolados
sem perder alterações; Task retomada após reinício sem execução duplicada;
Planner local executa comando Linux/container na VPS. Componente duplicado só
é removido após substituição comprovada.

**M4.** Tarefa repetida reaproveita evidência ou procedimento sem perder a
verificação atual; comparar chamadas, contexto e tempo contra a execução
original.

**M5.** Revisão com problema localizado retorna ao coder correto e passa na
validação sem reiniciar tarefas concluídas; comparação de estratégias mostra
sucesso, custo e latência observados, sem segundo roteador.

**M6.** Em missão com duas Tasks, um comentário de PR chega uma única vez à
Task correta; o Planner continua; o Kernel mantém o estado; comentário apenas
informativo não cria Task.

**M7.** Acompanhar uma sessão e continuar uma interação remotamente sem
instalar outro mecanismo de orquestração; se não atender, registrar e encerrar
o piloto.

## 8. Protocolo de prova runtime-real (M1)

Ordem obrigatória, com evidência por etapa:

1. `task-kernel model-select` para a Task, papel e tier admissível; guardar
   `tier`, `model`, `policy_hash` e refs.
2. Planner informa `model` verbatim na tool nativa `subagent`.
3. Registrar `session:<child>` e `message:<assistant>`.
4. `task-kernel verify-run` (evento `kernel-executed`).
5. `task-kernel model-attempt` com o tier e o modelo efetivos.
6. `task-kernel model-proof`.
7. Decisão: continuar, concluir ou escalar — **somente** com prova sticky;
   sucesso T3 não escala; falta de prova não autoriza novo dispatch.

A prova exige modelo vivo. Sem provider disponível, registrar `BLOCKED` com a
perna faltante; nunca inferir sucesso.

## 9. Riscos e decisões abertas

- **#208 G1:** o encadeamento comportamental foi provado em runtime
  (2026-11-10, Task `evo-m1-proof-20261110`): o Planner executou
  `model-select → dispatch → attempt → proof` a partir de uma única instrução
  humana. O que falta é automação em um único comando — decisão explícita, não
  pré-requisito. Evidência em
  `evidence/evolution-2026-11-10/m1-planner-chain-runtime.md`.
- **PR #210:** conflita com a master e precede o estado atual; não integrar
  configuração antiga.
- **#143/#61:** evidência forte, mas fechamento exige revisão humana do
  maintainer.
- **M2:** conteúdo upstream (BMAD, Superpowers, Matt, Addy) tem licença e
  versionamento próprios; pinar e isolar antes de distribuir.
- **M6:** só começar após #143/#183 funcionais; GitHub como único canal na
  primeira fatia, duas sessões no máximo.
- **Flags:** nascem OFF/shadow; ativação é decisão humana com evidência.
  `skill_routing`, `mcp_routing` e `adaptive_ranking` permanecem OFF.

## 10. Referências

- `docs/specs/BACKLOG-CONSOLIDATION-NATIVE-FIRST-SPEC.md` — princípios
  native-first/reuse-first.
- `docs/specs/DYNAMIC-MODEL-ROUTING-v1.1-SPEC.md` e
  `docs/guides/MODEL-ROUTER-v1.4-OPERATIONS.md` — política de modelos.
- `docs/ARCHITECTURE.md`, `docs/PERMISSIONS.md`, `docs/SECURITY.md`.
- `CHANGELOG.md` `[Unreleased]` — estado vivo.
- `source/registry/model-routing-policy.json` — fonte da verdade da cadeia.
