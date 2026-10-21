# PLAN-ORCH — Consumir Agent Config e assumir execução de Quality Gates

**Data:** 2026-10-19
**Status:** READY_FOR_IMPLEMENTATION_PLANNING (sem runtime alterado)
**Repo executor:** `Kusts/opencode-orchestration`
**Base revisada:** `master @ 85e3b80faeabe00689f9cab22ab788ebe155fe52` (revalidar HEAD antes de codificar)
**Contrato normativo (não duplicar):** [SPEC — Agent Config ↔ Orquestração](https://github.com/kust-projetos/agent-config/blob/docs/interop-config-orchestration-20261019/docs/agent/AGENT-CONFIG-ORCHESTRATION-INTEROP-SPEC.md)
**ADR:** [ADR-INTEROP-001](https://github.com/kust-projetos/agent-config/blob/docs/interop-config-orchestration-20261019/docs/governance/ADR-INTEROP-001-SINGLE-OWNER-CONFIG-EXECUTION.md)
**Plano produtor:** [PLAN-AC](https://github.com/kust-projetos/agent-config/blob/docs/interop-config-orchestration-20261019/docs/agent/AGENT-CONFIG-INTEROP-PLAN.md)
**Prioridade:** OpenCode V2 somente; V1 congelado como legado.

## 0. Missão e arquitetura de responsabilidade

Consumir o `agent-profile-bundle/v1` produzido pelo Agent Config sem manter cópias **editáveis** dos 19 agentes globais; preservar execução/autonomia já existente. Incorporar a classificação de risco/gates/mediador implementados no Config aos componentes reais de Objective/Delivery, evitando duas autoridades e dois loops.

**NÃO** portar os sete arquivos com cópia literal e novos chamadores concorrentes. Usar os testes/fixtures como contrato, absorvendo a lógica no kernel e rotas já presentes. A Orquestração continua responsável por:
- Objetivo, Task/Goal Kernel, lease/fencing, idempotency, dispatch, modelos, retries, watchdog e continuidade.
- Reviewer independente e Advisor/Jev consultivo sob trigger.
- CI watch/wait/resume e políticas de PR/merge reais, ligados a commit SHA.
- Boundary de ação externa com preflight, execução autorizada e recibos verificados.
- Sem writer de instruções **globais** ou `agents.*.permissions` quando Agent Config é o dono.
- Sem grants concedidos por memória, Jev ou presença de ferramenta.

**Caminhos atuais de referência:** `install.ps1`, `scripts/render-opencode-config.ps1`, `scripts/reconcile-opencode-config.ps1`, `scripts/runtime/lib/AgentTranslator.ps1`, `scripts/v3/lib/OrchestrationObjectiveRuntime.ps1`, `OrchestrationValidationPolicy.ps1`, `OrchestrationDelivery.ps1`, `OrchestrationGitHubResume.ps1`, `OrchestrationJevAdvisory.ps1`, `plugins/orchestration-enforcement.ts`. Manter os nomes definitivos no padrão real após inspeção.

## 1. Transferência funcional dos sete módulos

| Origem no `agent-config` | Destino/integração nesta base | O que não duplicar |
|---|---|---|
| `ExternalActionRisk.ps1` | Resolver policy risk por intenção do Objective | Não duplicar `Get-ExternalActionRiskDefaults` em 2 libs sincronizadas manualmente |
| `ExternalActionGate.ps1` | Validar evidência externa + reviewer via ValidationPolicy e Kernel | Não substituir `verified_pass`/DONE do kernel |
| `ExternalActionPreflight.ps1` | Adaptar pré-condições por operação em Delivery/GitHub | Reusar `Get-OrchestrationGitHubReadiness` |
| `DeployPreflight.ps1` | Adapter de efeito/ambiente existente ou pequeno módulo sob Kernel | Não criar motor de deploy nem adicionar provider para projeto local |
| `MediatedExecutor.ps1` | Boundary/adapter de efeito chamado pelo ObjectiveRuntime | Não criar outro ObjectiveLoop/worker/Watchdog |
| `ObjectiveProfiles.ps1` | Hints opcionais de Planner/dispatch (P2/HOLD) | Não promover roteamento dinâmico antes da validação |
| `GateMetrics.ps1` | Telemetria agregada em eventos/execution ledger | Não criar segunda store persistente |

Preservar exemplos testados de Risk/Gate/Preflight/Deploy, erros fechados, reason codes e snapshots de recibo. Onde a implementação atual da Orquestração é superior (CI resume, CAS/lease, delivery, rollback), reutilizar a nativa e verificar paridade.

## O0 — Baseline e mapa de call-sites (P0)

- [ ] O0.1 Pin no HEAD real, revisar working trees/sessões concorrentes e estado do CI da branch principal. Não declarar PASS com check ainda PENDING.
- [ ] O0.2 Calcular diff de `source/agents/*.md`, `source/global/AGENTS.md`, `source/registry/{autonomy-policy,capability-flags,verification-policy}.json` e templates V2 contra Config; identificar dialeto intencional (V1→V2) versus comportamento divergente.
- [ ] O0.3 Mapear todos os escritores de `~/.config/opencode/AGENTS.md`, `opencode.json(.c)`, `agents/` e skill/MCP. Inspecionar `install.ps1`, `scripts/reconcile-opencode-config.ps1`, `render-opencode-config.ps1`; o marcador `opencode-orchestration` é compartilhado e deve ser migrado.
- [ ] O0.4 Identificar ponto **produtivo** que chama executores de GitHub/deploy/API e o caminho real de `git push`/`gh pr merge`/shell; separar handlers de CI que somente observam.
- [ ] O0.5 Auditoria de kernel/flags: Gate/Task/Objective grants, Fencing, `dispatch` real, versionamento, hooks do plugin V2, Advisor/Jev, CI resume e estados HOLD. Não ativar flags porque o PLAN exige "verde".
- [ ] O0.6 Baseline de `scripts/v3/run-v3-tests.ps1`, `scripts/test-package-consistency.ps1`, lint/typecheck plugin e smoke V2 quando acessível. O runner **deste repo** suporta `-Name`; não importar o profile corrigido do Config que tem runner diferente.
- [ ] O0.7 Criar matriz de ownership campo-a-campo, com precondições e rollback; registrar fixture de usuário com plugin e MCP instalado.

**Gate O0:** source/call-sites e evidências; sem escrita ativa, sem alteração de kernel.

## O1 — Consumidor de bundle versionado e pinning por Objective (P0)

**Depende de C1/C2; iniciar com fixture de contrato.**

- [ ] O1.1 Implementar pequeno `Read-AgentProfileBundle`/validator (ou equivalente) sob `scripts/v3/lib` ou runtime loader existente. Consumir schema canônico com file manifest/digest; sem fetch remota automática, sem runtime service novo.
- [ ] O1.2 Validar `source_commit_sha`, digest do payload, schema major, capabilities e runtime `opencode-v2`; fallback `DEGRADED_PINNED` somente para último bundle válido e compatível.
- [ ] O1.3 Resolver 19 agents + papéis nativos + grants basais e export do Config, mas permitir `orchestration-role-overlay` apenas com metadados de dispatch/pools, não permissions/prompt duplicados.
- [ ] O1.4 Novo Objective captura `bundle_digest`/versão no checkpoint/envelope; bundle atualizado no disco durante execução não muda policy de um efeito já aprovado. Upgrade do goal só em checkpoint com revalidação.
- [ ] O1.5 Ausência de bundle/policy incompatível não cria `Authorized=true` nem degrada HIGH para LOW. O consumer mostra `BUNDLE_UNAVAILABLE/INCOMPATIBLE_BUNDLE/STALE_POLICY` e alternativas seguras.
- [ ] O1.6 Tests RED→GREEN de hash tamper, payload drift, two manifest revisions, missing capability, unknown agent, untrusted instruction injection no bundle e tipo inválido.

**Gate O1:** INT-01, INT-08, INT-09, INT-19, INT-20, INT-22; loader puro sem mutar runtime, pin demonstrado.

## O2 — Installer, marker e ownership sem colisão (P0)

**Depende de C3.**

- [ ] O2.1 Alterar instalador `install.ps1` para reconhecer owner do Config; deixar de aplicar texto global, `agents.*.permissions` e top-level `permissions` ao mesmo tempo que o Config. Não apagar recurso legado até cutover.
- [ ] O2.2 Alterar `scripts/render-opencode-config.ps1`/`reconcile-opencode-config.ps1`: fontes do Config são **lidas**, não reescritas pelo repo de Orquestração; plugin mantém instructions operacionais via namespace privado. Marcar generated legacy como `SNAPSHOT_COMPAT` quando indispensável standalone, jamais source editável.
- [ ] O2.3 Migrar `<!-- opencode-orchestration:start -->` para blocos sem overlap em fixture: novo bloco global do Config e plugin Orchestration independente. Se não for possível migrar sem ambiguidades, fail-closed com preview e plano de recuperação.
- [ ] O2.4 Snapshot standalone: se Config não está instalado, usar bundle imutável pinado aprovado no pacote; fazer instalador reconhecer owner já existente e não sobrescrever. Caso Config seja instalado depois, passar a tratar Config como dono sem perder configurações da Orquestração.
- [ ] O2.5 Preservar configuração user/plugins/AI Memory/Orca/Herdr, outras agents e JSONC; aplicar CAS, backup, atomicidade e uninstall apenas de namespaces próprios.
- [ ] O2.6 Testes fixture de Config→Orch, Orch→Config, update ambos, rollback, duas sessões concorrentes, HOME alternativo; evitar `-Force` cego.

**Gate O2:** INT-02–07, INT-20, INT-24, INT-26, dois instaladores convergentes. V1 permanece frozen sem alteração de dialeto.

## O3 — Migrar classificador e Quality Gate para o Kernel (P0)

**Depende de C1/C4; preservar `OrchestrationValidationPolicy` e `OrchestrationDelivery`.**

- [ ] O3.1 Definir o pipeline único: `ObjectiveAuthority + ExternalActionIntent + resolved risk policy → required checks → verified evidence → decision`.
- [ ] O3.2 Reaproveitar de Config as fixtures de `ExternalActionRisk` e `ExternalActionGate`; unificar risk levels e mapping de L0–L3 desta Orquestração, sem manter 2 tabelas hardcoded de defaults/aliases.
- [ ] O3.3 `reviewer` = independente do autor; `security-reviewer` por triggers reais; `engineering-advisor`/Jev somente para incerteza significativa/migração complexa/conflito de parecer/repetidas tentativas. Unificar com `OrchestrationJevAdvisory`, sem segundo circuit/budget.
- [ ] O3.4 Read-only/LOW sem fanout artificial. MEDIUM material requer teste e review se aplicável; HIGH CI/review/rollback atual no SHA exato. Checks N/A só com razão válida; FAIL/PENDING/UNKNOWN nunca equivalem PASS.
- [ ] O3.5 Garantir que gate de **ação externa** não assine `Task DONE`/`Goal DONE`; Kernel/verifier continuam únicos donos de conclusão. O resultado do gate é pré-condição, não certificado de entrega.
- [ ] O3.6 Testes RED→GREEN: low não chama reviewer, high sem review rejeita, self-review rejeita, SHA/policy drift rejeita, N/A sem reason bloqueia, provider evidence untrusted, parser com strings false e status invalid.
- [ ] O3.7 Deixar `AUTONOMY` global do Config apenas como declarações de grant/perfil; `source/registry/autonomy-policy.json` local renomeado ou classificado `objective-autonomy-policy` se isso reduzir ambiguidade (migração aditiva e testada, sem destruir callers).

**Gate O3:** INT-09–12, INT-18, INT-19, INT-27; decisão determinística com prova, sem chamada externa.

## O4 — Action executor realmente ligado ao objetivo (P0)

**Depende de O3. Pode começar em modo shadow com fixture.**

- [ ] O4.1 Localizar boundary entre `OrchestrationObjectiveRuntime`/`DispatchIntent`/adapter e ações externas. Integrar ali o preflight, não como helper que o agente *pode* optar por chamar. Gate e executor não criam outro loop, store ou watchdog.
- [ ] O4.2 **Eliminar autoridade presumida:** migrar o comportamento de `MediatedExecutor` com `Authorized` ausente → `NEEDS_USER_AUTHORITY`; `HumanApproved` não substitui scope assinado/objetivo persistido.
- [ ] O4.3 Alterar `PreflightExternalAction`/delivery para que merge/release dentro do objetivo autorizado não exijam nova confirmação humana. Verificar sempre os required reviews/checks da branch e restrições do provedor.
- [ ] O4.4 Guardar `intent` (goal, action, immutable target, SHA/digest, payload hash, idempotency key) no Objective store antes do primeiro efeito; revalidar `policy_digest`/SHA/grants/environment imediatamente antes do ato.
- [ ] O4.5 `PASS` gate não pode ser preenchido pelo modelo. Fonte de CI/PR, Reviewer identity e artefato diff têm provenance verificável. Não confiar em strings `CI=PASS` fornecidas pela própria task.
- [ ] O4.6 `PENDING` registra wait; `FAIL` retorna remediação; retorno pós-mutation `UNKNOWN` solicita reconcile de estado remoto antes de qualquer repetição. Respeitar CAS/lease/fencing/budget existentes.
- [ ] O4.7 Testar executor malicioso/fora de rota e anti-bypass. Shell direto com acesso irrestrito ainda não é `MEDIATED_ENFORCED` universal; usar credenciais escopadas/proteções do provider para HIGH quando efetivamente disponível, ou reportar `SOFT_ADVISORY`.
- [ ] O4.8 Permitir `deploy.staging` apenas quando o objetivo prevê deploy. Para este projeto **local** não existe produção externa; não inventar provedor de produção nem marcar item não aplicável como falha.

**Gate O4:** INT-13–17, INT-27 e receipts `CONFIRMED/FAILED/UNKNOWN` demonstrados em fixture. Rollback de adaptação documentado.

## O5 — GitHub CI/PR/review/resume em execução (P0)

**Depende de O3/O4, reusar código já existente.**

- [ ] O5.1 Ligar `OrchestrationDelivery.ps1` e `OrchestrationGitHubResume.ps1` ao novo gate externo; não criar watcher/poller paralelo. Required CI checks exatos por repo, sem hardcode global inválido.
- [ ] O5.2 Executor cria/atualiza PR conforme objetivo, verifica target, branch protection, status no SHA atual, reviewer independente + security trigger e unresolved findings. HEAD mudou → provas anteriores expiram.
- [ ] O5.3 CI pending → wait/resume durável com budget da Orquestração e nenhuma conclusão `OBJECTIVE_COMPLETED` prematura. CI FAIL → diagnosticar, corrigir e re-testar antes de nova avaliação.
- [ ] O5.4 Merge pode ocorrer automaticamente **se** objetivo atual o autorizar, os gates passarem e provider permitir; não remover regras de branch nem falsificar aprovação humana requerida por GitHub.
- [ ] O5.5 Rerun/snapshot duplicado/timeout: idempotência de intenção, não da tentativa. Erro após solicitação não implica que efeito não ocorreu.
- [ ] O5.6 Testes com bare repo + fixture de API/CI e, depois, repo sandbox autorizado (push/PR/review/CI) sem afetar repos de produção.

**Gate O5:** INT-10–12, INT-14, INT-17, INT-28 com evidência sintética e live separado.

## O6 — E2E inter-repo, CI, regressão e readiness (P0)

- [ ] O6.1 Rodar todas INT-01..INT-28 da SPEC, reportar `PASS/FAIL/PARTIAL/BLOCKED_EXTERNAL/NOT_APPLICABLE` com prova por caso. O executor não usa E2E simulado para certificar enforcement live.
- [ ] O6.2 Pipeline em fixture: carregar bundle Config→criar Objective→selecionar subagente→Coder→Tester→Reviewer→CI WAIT/Resume→gate→mutation→recibo→continuar→DONE com verified pass.
- [ ] O6.3 Testar na máquina isolada OpenCode V2 instalada, inclusive reload da config; configs do usuário real ficam intactas até cutover autorizado.
- [ ] O6.4 Rodar `scripts/v3/run-v3-tests.ps1`, testes de release/install, tester-permission, plugin typecheck e smoke real pertinente, registrando exit code, run URL, SHA exato. Quais suites de V1 frozen continuam como compat devem permanecer visíveis.
- [ ] O6.5 Testar política risk/permission drift entre dois commits; bundle antigo pinado, novo só no checkpoint; reviewer/advisor independence; prompt-injection de web/issue/MCP/AI Memory.
- [ ] O6.6 Testar ferramentas externas indisponíveis, Jev opcional e timer do watchdog; fallback sem perda de progresso nem fake SUCCESS.
- [ ] O6.7 Revisão independente do PR focado + verificação de owner e secrets; CI inconclusivo não vira merge green.
- [ ] O6.8 Manter regressão antiga em HOLD quando realmente decisão de capability, sem alterar flags para mascarar. Separar `blocked-by-environment`, `functionally-failing`, `expected-hold`.

**Gate O6:** sucesso em fixture e prova live de pelo menos um percurso GitHub autorizado; limites globais honestos quanto a shell direto. Qualquer HIGH live sem proteção comprovada permanece PARTIAL.

## O7 — Cutover produtivo e desativar cópias (P1 após O6)

- [ ] O7.1 Usar feature flag de import do bundle em `shadow`, `canary`, `active` com owner/snapshot registrados. Alteração de policy de execução não é autoativada por update de perfil.
- [ ] O7.2 Desligar a instalação da cópia global dos agentes e dos writers de `AGENTS.md`/permissões **somente** após paridade e migração CAS aprovada.
- [ ] O7.3 Atualizar `docs/ARCHITECTURE.md`, `docs/PERMISSIONS.md`, `README.md`, `docs/specs/INDEX.md` e manifests com o novo owner; V1 histórico marcado frozen, não apagado.
- [ ] O7.4 Reconciliar descontinuação dos sete módulos no Config apenas após comprovado que não há consumidores; Config mantém source of truth do bundle.
- [ ] O7.5 Manter versão/digest pinado na release/Objective e rollback testado; suporte standalone por snapshot verificado, sem fork editável.
- [ ] O7.6 Monitorar variações de prompts de permissão, falha de permission dialect, gate latency, CI waits, reviewer churn, duplicação de ações e alterações inesperadas nas configs.
- [ ] O7.7 Não bloquear rollout P0 por painel, multi-device, auto-profile, deep model router ou ativação opcional Jev. São roadmap futuro.

**Gate O7:** uma política global, um autor de arquivo por namespace, um executor externo produtivo, CI/review/rollback demonstrados, nenhuma regressão V2.

## 2. Critérios de aceite e riscos específicos

| Risco | Medida de prova exigida |
|---|---|
| Manual duplication (cópia de 19 agents) | Teste de manifest único + diff semântico e hashes |
| Writer last-wins | Aplicar duas ordens de instalação e update; nenhum drift sem causa |
| Permission escalation | Baseline grant ∩ objective env, N/A e unknown-denied; self-review recusado |
| Excessive blocking | READ_ONLY/LOW sem revisão artificial, autonomia por objetivo |
| Bypass de shell direto | Não alegar hard enforcement sem restrição real no caminho de alto risco |
| CI stale | PR current head SHA, policy digest, required checks atuais e reviewer |
| Retry duplicando efeito | Durable intent/receipt, idempotency key, reconcile do UNKNOWN |
| Dois kernels | Nenhuma nova store/loop de Objective, nenhum segundo GithubResume/Reviewer |
| Version churn | Capability detection em runtime V2 instalado, policy schema versionado |
| Usabilidade de outros runtimes | Agent Config funciona sozinho, Orquestração não escreve configs alheias |
| Driver não disponível | HOLD/BLOCKED_EXTERNAL específico, sem travar trabalho local comprovado |

## 3. Estrutura de PRs sugerida (reduzir conflitos)

1. **PR O0+O1 — Schema consumer + shadow loader:** sem mudança ativa.
2. **PR O2 — Installer ownership e coexistência:** fixtures/rollback, separadamente dos gates.
3. **PR O3+O4 — Gateway no ObjectiveRuntime:** suites unitárias, integração fake adapter e evidência de autoridade.
4. **PR O5 — GitHub delivery end-to-end:** integra CI wait/resume, reviewer e revalidação.
5. **PR O6+O7 — E2E, rollout/cutover:** aprova somente com gate real e regressão.

Se dois cortes couberem com segurança no mesmo PR, consolidar em vez de produzir PRs artificiais. Não criar novas implementações paralelas para completar uma lista.

## 4. Relatório de cada execução/integração

```text
PHASE O# | OBJECTIVE ID:
BRANCH/HEAD INIT→END:
CONFIG BUNDLE DIGEST / SOURCE SHA:
NAMESPACE OWNERSHIP CHANGES:
FUNCTIONAL DIFF vs previous behavior:
TESTS RED/GREEN: command, exit, evidence ref:
CI CURRENT SHA/status:
GATE: risk, authority source, reviewer identity/status, required checks:
NATIVE RUNTIME: version, capability status, smoke (fixture/live):
EXTERNAL MUTATION: not run | mediated fixture | live authorized:
EFFECT RECEIPT: confirmed | failed | unknown | not-applicable:
CONTINUATION/RECOVERY:
ROLLBACK PROOF:
RESULT: PASS | PARTIAL | BLOCKED
NEXT STEP O#:
```

**Não inventar SHA/digest, nem preencher `CI PASS` com texto não verificável.**

## 5. Prompt para o Planner da Orquestração

> Implementar O0→O7 conforme este PLAN e a SPEC/ADR canônicas do Agent Config. Use HEAD real, preserve sessões/branches e faça TDD nas mudanças de comportamento. Não copie os sete módulos como um segundo kernel: integre risco/gate/preflight/mediator ao OrchestrationObjectiveRuntime, Delivery, ValidationPolicy e GitHubResume já existentes. Receba bundle `agent-profile-bundle/v1` imutável, com digest/proveniência e snapshot offline; não mantenha forks editáveis dos 19 agentes. Faça writer único por namespace e testes nas duas ordens de instalação. Autoridade vem do Goal/Task, nunca é `true` por omissão; baixa complexidade roda sem burocracia; HIGH exige evidência atual e revisor independente. CI PENDING aguarda e retoma, falha corrige, timeout pós-mutation reconcilia. Não declarar hard enforcement se shell direto contornar. OpenCode V2 ativo, V1 congelado. Produzir evidências por fase, handoff C#→O# e PRs pequenos sem mexer no ambiente ativo até corte aprovado.
